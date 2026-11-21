#!/usr/bin/env python3
"""Offline signing and verification for Eye Break Reminder update metadata.

Production private keys must be encrypted and stored outside the checkout,
OneDrive, and temporary directories. On Windows, key generation creates a new
dedicated directory whose DACL grants access only to the current user. This
tool never generates a key unless `generate` is explicitly invoked.
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = "Eye Break Reminder"
REPOSITORY = "REMEDIOSSAMUEL/EYE-BREAK-REMINDER"
MANIFEST_LIMIT = 16 * 1024
MAX_PAYLOAD = 100 * 1024 * 1024
SPKI_P256_PREFIX = bytes.fromhex("3059301306072a8648ce3d020106082a8648ce3d03010703420004")


def run_openssl(*args: str) -> bytes:
    proc = subprocess.run(["openssl", *args], check=False, stdout=subprocess.PIPE)
    if proc.returncode:
        raise RuntimeError(f"OpenSSL command failed ({proc.returncode}): {args[0]}")
    return proc.stdout


def ensure_outside_checkout(path: Path) -> None:
    resolved = path.resolve()
    try:
        resolved.relative_to(ROOT.resolve())
    except ValueError:
        return
    raise ValueError("The production private key must be stored outside the project checkout.")


def path_is_within(path: Path, parent: Path) -> bool:
    candidate = os.path.normcase(str(path.resolve(strict=False)))
    root = os.path.normcase(str(parent.resolve(strict=False)))
    try:
        return os.path.commonpath((candidate, root)) == root
    except ValueError:
        return False


def synchronized_roots(project_root: Path = ROOT) -> list[Path]:
    roots: list[Path] = []
    for name in ("OneDrive", "OneDriveCommercial", "OneDriveConsumer"):
        value = os.environ.get(name)
        if value:
            roots.append(Path(value))
    try:
        roots.extend(candidate for candidate in Path.home().glob("OneDrive*") if candidate.is_dir())
    except OSError:
        pass
    # Also discover the sync root from the checkout path. This remains effective
    # when an interactive shell has not exported the OneDrive environment vars.
    project = project_root.resolve(strict=False)
    for parent in (project, *project.parents):
        folded = parent.name.casefold()
        if folded == "onedrive" or folded.startswith("onedrive -"):
            roots.append(parent)
    return roots


def validate_private_key_path(
    path: Path,
    *,
    project_root: Path = ROOT,
    sync_roots: list[Path] | None = None,
    temp_root: Path | None = None,
) -> Path:
    resolved = path.resolve(strict=False)
    if path_is_within(resolved, project_root):
        raise ValueError("The production private key must be stored outside the project checkout.")
    roots = synchronized_roots(project_root) if sync_roots is None else sync_roots
    if any(path_is_within(resolved, root) for root in roots):
        raise ValueError("The production private key must not be stored in a synchronized OneDrive folder.")
    temporary = Path(tempfile.gettempdir()) if temp_root is None else temp_root
    if path_is_within(resolved, temporary):
        raise ValueError("The production private key must not be stored in a temporary directory.")
    return resolved


def current_windows_user() -> tuple[str, str]:
    if os.name != "nt":
        raise RuntimeError("Production private-key provisioning requires Windows ACL support.")
    result = subprocess.run(
        ["whoami", "/user", "/fo", "csv", "/nh"],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    rows = list(csv.reader(result.stdout.splitlines())) if result.returncode == 0 else []
    identity = rows[0][0].strip() if rows and len(rows[0]) == 2 else ""
    sid = rows[0][1].strip() if rows and len(rows[0]) == 2 else ""
    if not identity:
        raise RuntimeError("Could not determine the current Windows user for key-directory protection.")
    if not re.fullmatch(r"S-1-\d+(?:-\d+)+", sid):
        raise RuntimeError("Could not determine the current Windows user's SID for key-directory protection.")
    return identity, sid


def has_only_current_user_acl(acl_output: str, identity: str) -> bool:
    # icacls prints the file path and its first ACE on the same line. A drive
    # colon is not followed by an ACE parenthesis, so count only the latter.
    # Require an allow-full-control ACE; a read-only grant or a DENY ACE must
    # not be mistaken for a usable, user-owned signing directory.
    ace_count = len(re.findall(r":\((?=[A-Z])", acl_output, flags=re.IGNORECASE))
    full_control = re.compile(
        rf"{re.escape(identity)}:((?:\((?:OI|CI|IO|NP|I)\))*)\(F\)(?=\s|$)",
        flags=re.IGNORECASE,
    )
    return ace_count == 1 and full_control.search(acl_output) is not None


def verify_private_key_acl(path: Path) -> None:
    identity, _ = current_windows_user()
    result = subprocess.run(
        ["icacls", str(path)],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode or not has_only_current_user_acl(result.stdout, identity):
        raise RuntimeError("The production private key ACL is not limited to the current Windows user.")


def restrict_private_key_directory(
    directory: Path,
    *,
    project_root: Path = ROOT,
    sync_roots: list[Path] | None = None,
    temp_root: Path | None = None,
) -> str:
    """Create a new dedicated key directory with an explicit current-user-only DACL."""
    validate_private_key_path(
        directory / "production-private.pem",
        project_root=project_root,
        sync_roots=sync_roots,
        temp_root=temp_root,
    )
    if directory.exists():
        raise ValueError("Refusing an existing key directory; use a new dedicated directory.")
    if not directory.parent.is_dir():
        raise ValueError("The selected key-volume parent must already exist.")
    identity, sid = current_windows_user()
    directory.mkdir()
    try:
        result = subprocess.run(
            ["icacls", str(directory), "/inheritance:r", "/grant:r", f"*{sid}:(OI)(CI)F"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        if result.returncode:
            raise RuntimeError("Windows could not restrict the new production-key directory ACL.")
        verified = subprocess.run(
            ["icacls", str(directory)],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        if verified.returncode:
            raise RuntimeError("Windows could not verify the production-key directory ACL.")
        if not has_only_current_user_acl(verified.stdout, identity):
            raise RuntimeError("The production-key directory ACL is not limited to the current Windows user.")
        return sid
    except Exception:
        try:
            directory.rmdir()
        except OSError:
            pass
        raise


def point_from_public_pem(path: Path) -> bytes:
    der = run_openssl("pkey", "-pubin", "-in", str(path), "-outform", "DER")
    if len(der) != len(SPKI_P256_PREFIX) + 64 or not der.startswith(SPKI_P256_PREFIX) or der[-65] != 4:
        raise ValueError("The public key must be an uncompressed P-256 SubjectPublicKeyInfo PEM key.")
    return der[-64:]


def key_id(point: bytes) -> str:
    if len(point) != 64:
        raise ValueError("Expected a 64-byte P-256 public point.")
    return "p256-" + hashlib.sha256(point).hexdigest()[:16]


def der_signature_to_raw(der: bytes) -> bytes:
    # Parse the bounded ASN.1 ECDSA SEQUENCE from OpenSSL; no crypto is done here.
    if len(der) < 8 or der[0] != 0x30 or der[1] & 0x80:
        raise ValueError("OpenSSL returned a malformed ECDSA signature.")
    seq_len = der[1]
    if seq_len != len(der) - 2:
        raise ValueError("OpenSSL returned a noncanonical ECDSA signature length.")
    at = 2
    values = []
    for _ in range(2):
        if at + 2 > len(der) or der[at] != 0x02:
            raise ValueError("OpenSSL returned a malformed ECDSA integer.")
        size = der[at + 1]
        at += 2
        if not 1 <= size <= 33 or at + size > len(der):
            raise ValueError("OpenSSL returned an out-of-range ECDSA integer.")
        value = der[at:at + size]
        at += size
        if value[0] & 0x80 or (len(value) > 1 and value[0] == 0 and not value[1] & 0x80):
            raise ValueError("OpenSSL returned a noncanonical ECDSA integer.")
        value = value.lstrip(b"\0")
        if not value or len(value) > 32:
            raise ValueError("OpenSSL returned an invalid ECDSA integer.")
        values.append(value.rjust(32, b"\0"))
    if at != len(der):
        raise ValueError("OpenSSL returned trailing ECDSA signature data.")
    return values[0] + values[1]


def raw_signature_to_der(raw: bytes) -> bytes:
    if len(raw) != 64:
        raise ValueError("ECDSA P-256 signatures must be exactly 64 raw P1363 bytes.")

    def integer(value: bytes) -> bytes:
        value = value.lstrip(b"\0") or b"\0"
        if value[0] & 0x80:
            value = b"\0" + value
        return b"\x02" + bytes([len(value)]) + value

    body = integer(raw[:32]) + integer(raw[32:])
    return b"\x30" + bytes([len(body)]) + body


def duplicate_rejecting_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate JSON key: {key}")
        result[key] = value
    return result


def canonical_json(value: dict[str, object]) -> bytes:
    return json.dumps(value, ensure_ascii=True, separators=(",", ":"), allow_nan=False).encode("ascii")


def semver(value: str) -> bool:
    pieces = value.split(".")
    return len(pieces) == 3 and all(p.isascii() and p.isdecimal() and (p == "0" or not p.startswith("0")) for p in pieces)


def utc(value: str) -> dt.datetime:
    parsed = dt.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
    if parsed.strftime("%Y-%m-%dT%H:%M:%SZ") != value:
        raise ValueError("Timestamp is not canonical UTC RFC 3339.")
    return parsed


def load_manifest(path: Path) -> tuple[bytes, dict[str, object]]:
    raw = path.read_bytes()
    if not 0 < len(raw) <= MANIFEST_LIMIT:
        raise ValueError("Manifest is empty or exceeds 16 KiB.")
    value = json.loads(raw.decode("ascii"), object_pairs_hook=duplicate_rejecting_object,
                       parse_constant=lambda _: (_ for _ in ()).throw(ValueError("Nonfinite JSON number")))
    if not isinstance(value, dict) or canonical_json(value) != raw:
        raise ValueError("Manifest is not the exact compact canonical JSON format.")
    validate_manifest(value)
    return raw, value


def validate_manifest(value: dict[str, object]) -> None:
    fields = ["schema_version", "application", "repository", "version", "channel", "architecture",
              "key_id", "issued_at", "expires_at", "assets"]
    if list(value) != fields or value.get("schema_version") != 1 or type(value.get("schema_version")) is not int:
        raise ValueError("Unsupported manifest schema or property order.")
    if (value.get("application") != APP or value.get("repository") != REPOSITORY or
            value.get("channel") != "stable" or value.get("architecture") != "x64"):
        raise ValueError("Manifest application, repository, channel, or architecture is invalid.")
    version = value.get("version")
    if not isinstance(version, str) or not semver(version):
        raise ValueError("Manifest version must be stable X.Y.Z without aliases or prerelease text.")
    kid = value.get("key_id")
    if not isinstance(kid, str) or len(kid) != 21 or not kid.startswith("p256-") or any(c not in "0123456789abcdef" for c in kid[5:]):
        raise ValueError("Manifest signing key identifier is invalid.")
    issued, expires = utc(str(value.get("issued_at"))), utc(str(value.get("expires_at")))
    now = dt.datetime.now(dt.timezone.utc)
    if issued > now + dt.timedelta(minutes=5) or expires <= now or expires <= issued or expires - issued > dt.timedelta(days=90):
        raise ValueError("Manifest is expired, future dated, or has an excessive validity period.")
    assets = value.get("assets")
    if not isinstance(assets, list) or len(assets) != 2:
        raise ValueError("Manifest must contain exactly the two installable x64 payloads.")
    expected = [("EyeBreakReminder-Setup-x64.exe", "installer", "installed"),
                ("EyeBreakReminder.exe", "portable-update", "portable")]
    for asset, (name, role, install_type) in zip(assets, expected):
        if not isinstance(asset, dict) or list(asset) != ["name", "role", "installation_type", "architecture", "size", "sha256"]:
            raise ValueError("Manifest payload has unknown, missing, or reordered fields.")
        if (asset.get("name"), asset.get("role"), asset.get("installation_type"), asset.get("architecture")) != (name, role, install_type, "x64"):
            raise ValueError("Manifest payload role or identity is invalid.")
        size, digest = asset.get("size"), asset.get("sha256")
        if type(size) is not int or not 0 < size <= MAX_PAYLOAD or not isinstance(digest, str) or len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
            raise ValueError("Manifest payload size or SHA-256 is invalid.")


def verify_signature(public_key: Path, manifest: Path, signature: Path) -> None:
    raw, value = load_manifest(manifest)
    point = point_from_public_pem(public_key)
    if value["key_id"] != key_id(point):
        raise ValueError("Manifest key identifier does not match the verification key.")
    sig = signature.read_bytes()
    der = raw_signature_to_der(sig)
    with tempfile.TemporaryDirectory(prefix="ebr-update-signature-") as tmp:
        sig_path = Path(tmp) / "signature.der"
        sig_path.write_bytes(der)
        verified = subprocess.run(["openssl", "dgst", "-sha256", "-verify", str(public_key), "-signature", str(sig_path), str(manifest)],
                                  check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if verified.returncode:
            raise RuntimeError("OpenSSL rejected the update manifest signature.")
    if not raw:
        raise ValueError("Manifest verification failed.")
    print(f"PASS: authenticated {value['repository']} v{value['version']} with key {value['key_id']}")


def public_key_from_trust_header(path: Path) -> tuple[str, bytes]:
    text = path.read_text(encoding="ascii")
    provisioned = re.search(r"ProductionUpdateKeyProvisioned\s*=\s*(true|false)\s*;", text)
    key_identifier = re.search(r'ProductionUpdateKeyId\s*=\s*"(p256-[0-9a-f]{16})"', text)
    public_array = re.search(r"ProductionUpdatePublicKey\s*\{\{([\s\S]*?)\}\}\s*;", text)
    if not provisioned or provisioned.group(1) != "true" or not key_identifier or not public_array:
        raise ValueError("The production trust header does not contain a provisioned public key.")
    encoded = public_array.group(1)
    values = re.findall(r"0x([0-9a-fA-F]{2})", encoded)
    remainder = re.sub(r"0x[0-9a-fA-F]{2}|[\s,]", "", encoded)
    point = bytes.fromhex("".join(values))
    if remainder or len(point) != 64:
        raise ValueError("The embedded production P-256 public point is malformed.")
    identifier = key_identifier.group(1)
    if key_id(point) != identifier:
        raise ValueError("The embedded production public-key identifier does not match its public point.")
    return identifier, point


def verify_embedded_signature(trust_header: Path, manifest: Path, signature: Path) -> None:
    _, value = load_manifest(manifest)
    identifier, point = public_key_from_trust_header(trust_header)
    if value["key_id"] != identifier:
        raise ValueError("The manifest signing key identifier is not the embedded production key.")
    public_der = SPKI_P256_PREFIX + point
    import base64

    encoded = base64.encodebytes(public_der).decode("ascii")
    public_pem = "-----BEGIN PUBLIC KEY-----\n" + encoded + "-----END PUBLIC KEY-----\n"
    with tempfile.TemporaryDirectory(prefix="ebr-embedded-public-key-") as folder:
        public_path = Path(folder) / "production-public.pem"
        public_path.write_text(public_pem, encoding="ascii", newline="\n")
        verify_signature(public_path, manifest, signature)


def write_trust_header(public_key: Path, output: Path) -> None:
    point = point_from_public_pem(public_key)
    kid = key_id(point)
    chunks = [", ".join(f"0x{b:02x}" for b in point[i:i + 8]) for i in range(0, 64, 8)]
    array = ",\n    ".join(chunks)
    text = f'''#pragma once

#include <array>
#include <string_view>

namespace eye::updates {{

// Generated from the owner-provisioned public key. Never replace this with a test key.
inline constexpr bool ProductionUpdateKeyProvisioned=true;
inline constexpr std::string_view ProductionUpdateKeyId="{kid}";
inline constexpr std::array<unsigned char,64> ProductionUpdatePublicKey{{{{
    {array}
}}}};

}} // namespace eye::updates
'''
    output.write_text(text, encoding="ascii", newline="\n")
    print(f"Embedded public trust key {kid} in {output}; no private key was read or written.")


def build_manifest(args: argparse.Namespace, point: bytes) -> dict[str, object]:
    if not semver(args.version):
        raise ValueError("Version must be stable X.Y.Z without a leading v, build, or prerelease.")
    expires = utc(args.expires_at)
    issued = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    if expires <= issued or expires - issued > dt.timedelta(days=90):
        raise ValueError("Expiry must be in the next 90 days.")
    assets = []
    for path, name, role, install_type in [
        (args.installer, "EyeBreakReminder-Setup-x64.exe", "installer", "installed"),
        (args.portable, "EyeBreakReminder.exe", "portable-update", "portable"),
    ]:
        if path.name != name:
            raise ValueError(f"Expected {name}, got {path.name}.")
        digest = hashlib.sha256()
        size = 0
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                size += len(block)
                if size > MAX_PAYLOAD:
                    raise ValueError(f"Payload exceeds {MAX_PAYLOAD} bytes: {path}")
                digest.update(block)
        if size == 0:
            raise ValueError(f"Payload is empty: {path}")
        assets.append({"name": name, "role": role, "installation_type": install_type,
                       "architecture": "x64", "size": size, "sha256": digest.hexdigest()})
    return {"schema_version": 1, "application": APP, "repository": REPOSITORY,
            "version": args.version, "channel": "stable", "architecture": "x64",
            "key_id": key_id(point), "issued_at": issued.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "expires_at": expires.strftime("%Y-%m-%dT%H:%M:%SZ"), "assets": assets}


def generate_key(args: argparse.Namespace) -> None:
    if args.private_key.resolve() == args.public_key.resolve():
        raise ValueError("Private and public key paths must be different.")
    private_path = validate_private_key_path(args.private_key)
    ensure_outside_checkout(args.public_key)
    if args.private_key.exists() or args.public_key.exists():
        raise ValueError("Refusing to overwrite an existing key file.")
    restrict_private_key_directory(args.private_key.parent)
    args.public_key.parent.mkdir(parents=True, exist_ok=True)
    try:
        run_openssl("genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256",
                    "-aes-256-cbc", "-out", str(private_path))
        run_openssl("pkey", "-in", str(args.private_key), "-pubout", "-out", str(args.public_key))
        verify_private_key_acl(private_path)
        point = point_from_public_pem(args.public_key)
    except Exception:
        # Remove only the files this invocation may have created; never touch
        # pre-existing paths, which were rejected above.
        for path in (args.public_key, args.private_key):
            try:
                path.unlink(missing_ok=True)
            except OSError:
                pass
        try:
            args.private_key.parent.rmdir()
        except OSError:
            pass
        raise
    print(f"Created encrypted P-256 key. Public key id: {key_id(point)}")
    print("The private key contents were not displayed. Keep the encrypted key in protected storage, back it up to the owner-approved recovery location, and store its passphrase separately.")


def sign(args: argparse.Namespace) -> None:
    inputs = [args.private_key.resolve(), args.public_key.resolve(), args.installer.resolve(), args.portable.resolve()]
    outputs = [args.manifest.resolve(), args.signature.resolve()]
    if outputs[0] == outputs[1] or any(output in inputs for output in outputs):
        raise ValueError("Manifest and signature output paths must be distinct from each other, keys, and payloads.")
    if args.manifest.exists() or args.signature.exists():
        raise ValueError("Refusing to overwrite existing signed metadata; choose new output paths.")
    private_path = validate_private_key_path(args.private_key)
    verify_private_key_acl(private_path)
    point = point_from_public_pem(args.public_key)
    value = build_manifest(args, point)
    raw = canonical_json(value)
    if len(raw) > MANIFEST_LIMIT:
        raise ValueError("Manifest exceeds 16 KiB.")
    args.manifest.parent.mkdir(parents=True, exist_ok=True)
    args.signature.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="ebr-update-signature-") as tmp:
        tmp_root = Path(tmp)
        tmp_manifest = tmp_root / "manifest.json"
        der_path = tmp_root / "signature.der"
        raw_sig_path = tmp_root / "manifest.sig"
        tmp_manifest.write_bytes(raw)
        run_openssl("dgst", "-sha256", "-sign", str(args.private_key), "-out", str(der_path), str(tmp_manifest))
        raw_signature = der_signature_to_raw(der_path.read_bytes())
        raw_sig_path.write_bytes(raw_signature)
        verify_signature(args.public_key, tmp_manifest, raw_sig_path)
        if raw != tmp_manifest.read_bytes():
            raise ValueError("The manifest changed while it was being signed.")
        # Re-hash payloads before committing either metadata output, guarding
        # against a package mutation after manifest construction.
        for asset, payload in zip(value["assets"], (args.installer, args.portable)):
            if not isinstance(asset, dict) or asset["size"] != payload.stat().st_size or asset["sha256"] != hashlib.sha256(payload.read_bytes()).hexdigest():
                raise ValueError(f"Payload changed while it was being signed: {payload.name}")
        args.manifest.write_bytes(raw)
        args.signature.write_bytes(raw_signature)
    print(f"Wrote authenticated metadata for v{args.version}; signature is raw 64-byte P1363 ECDSA.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    keygen = commands.add_parser("generate", help="create a passphrase-encrypted P-256 key outside the checkout, OneDrive, and temporary directories")
    keygen.add_argument("--private-key", type=Path, required=True)
    keygen.add_argument("--public-key", type=Path, required=True)
    keygen.set_defaults(func=generate_key)
    embed = commands.add_parser("embed-public", help="embed an owner-provisioned public key in the production trust header")
    embed.add_argument("--public-key", type=Path, required=True)
    embed.add_argument("--output", type=Path, default=ROOT / "src" / "update_trust.hpp")
    embed.set_defaults(func=lambda args: write_trust_header(args.public_key, args.output))
    signing = commands.add_parser("sign", help="create and sign the two authenticated update payload entries")
    signing.add_argument("--private-key", type=Path, required=True)
    signing.add_argument("--public-key", type=Path, required=True)
    signing.add_argument("--version", required=True)
    signing.add_argument("--expires-at", required=True, help="UTC YYYY-MM-DDTHH:MM:SSZ, at most 90 days out")
    signing.add_argument("--installer", type=Path, required=True)
    signing.add_argument("--portable", type=Path, required=True, help="standalone EyeBreakReminder.exe update payload")
    signing.add_argument("--manifest", type=Path, required=True)
    signing.add_argument("--signature", type=Path, required=True)
    signing.set_defaults(func=sign)
    verification = commands.add_parser("verify", help="verify an existing manifest using a supplied public PEM key")
    verification.add_argument("--public-key", type=Path, required=True)
    verification.add_argument("--manifest", type=Path, required=True)
    verification.add_argument("--signature", type=Path, required=True)
    verification.set_defaults(func=lambda args: verify_signature(args.public_key, args.manifest, args.signature))
    embedded = commands.add_parser("verify-embedded", help="verify a manifest against the production key embedded in update_trust.hpp")
    embedded.add_argument("--trust-header", type=Path, default=ROOT / "src" / "update_trust.hpp")
    embedded.add_argument("--manifest", type=Path, required=True)
    embedded.add_argument("--signature", type=Path, required=True)
    embedded.set_defaults(func=lambda args: verify_embedded_signature(args.trust_header, args.manifest, args.signature))
    args = parser.parse_args()
    try:
        args.func(args)
        return 0
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
