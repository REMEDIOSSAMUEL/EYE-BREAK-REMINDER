#!/usr/bin/env python3
"""Assemble and verify a signed v1.4.0 candidate without accessing private keys."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import update_signing as signing

RELEASE_FILES = (
    "EyeBreakReminder.exe",
    "EyeBreakReminder-Setup-x64.exe",
    "EyeBreakReminder-Portable-x64.zip",
    "EyeBreakReminder-Source.zip",
    "EyeBreakReminder-SHA256.txt",
    "EyeBreakReminder-UpdateManifest.json",
    "EyeBreakReminder-UpdateManifest.sig",
)
UNSIGNED_CANDIDATE_FILES = RELEASE_FILES[:5]
CHECKSUM_FILES = RELEASE_FILES[:4]
PRIVATE_KEY_MARKERS = (
    b"-----BEGIN PRIVATE KEY-----",
    b"-----BEGIN ENCRYPTED PRIVATE KEY-----",
    b"-----BEGIN EC PRIVATE KEY-----",
    b"-----BEGIN RSA PRIVATE KEY-----",
)
TOKEN_PATTERNS = (
    re.compile(rb"gh[pousr]_[A-Za-z0-9_]{20,}"),
    re.compile(rb"github_pat_[A-Za-z0-9_]{20,}"),
    re.compile(rb"AKIA[0-9A-Z]{16}"),
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def audit_source_archive(path: Path) -> None:
    with zipfile.ZipFile(path, "r") as source:
        for entry in source.infolist():
            name = entry.filename
            is_directory = entry.is_dir()
            normalized = name.replace("\\", "/").rstrip("/") if is_directory else name.replace("\\", "/")
            parts = normalized.split("/")
            if not normalized or normalized.startswith("/") or any(part in ("", ".", "..") for part in parts):
                raise ValueError("Source archive contains an unsafe or ambiguous path.")
            if is_directory:
                continue
            if entry.file_size > 100 * 1024 * 1024:
                raise ValueError("Source archive contains an unexpectedly large entry.")
            mode = (entry.external_attr >> 16) & 0xFFFF
            if mode and (mode & 0o170000) == 0o120000:
                raise ValueError("Source archive must not contain symbolic links.")
            lowered = name.casefold()
            if lowered.endswith((".pem", ".pfx", ".p12", ".p7b", ".key", ".p8", ".env")) or any(
                marker in parts[-1].casefold() for marker in ("id_rsa", "id_ecdsa", "credentials", "secrets")
            ):
                raise ValueError("Source archive contains a private-key or credential-related file.")
            content = source.read(entry)
            if any(marker in content for marker in PRIVATE_KEY_MARKERS) or any(pattern.search(content) for pattern in TOKEN_PATTERNS):
                raise ValueError("Source archive contains private-key material or a credential-shaped token.")


def verify_candidate(release: Path, trust_header: Path) -> dict[str, object]:
    release = release.resolve(strict=True)
    entries = list(release.iterdir())
    if any(entry.is_symlink() or not entry.is_file() for entry in entries):
        raise ValueError("Candidate release directory must contain only regular files, with no links or subdirectories.")
    if sorted(entry.name for entry in entries) != sorted(RELEASE_FILES):
        raise ValueError("Final release directory does not contain exactly the seven documented files.")

    manifest_path = release / "EyeBreakReminder-UpdateManifest.json"
    signature_path = release / "EyeBreakReminder-UpdateManifest.sig"
    _, manifest = signing.load_manifest(manifest_path)
    if manifest["version"] != "1.4.0":
        raise ValueError("The final candidate manifest must identify v1.4.0.")
    signing.verify_embedded_signature(trust_header, manifest_path, signature_path)

    signed_by_name = {asset["name"]: asset for asset in manifest["assets"]}
    for name in ("EyeBreakReminder-Setup-x64.exe", "EyeBreakReminder.exe"):
        asset = signed_by_name[name]
        path = release / name
        if path.stat().st_size != asset["size"] or sha256(path) != asset["sha256"]:
            raise ValueError(f"Signed manifest does not match final payload bytes: {name}")

    checksum_path = release / "EyeBreakReminder-SHA256.txt"
    expected_checksum_lines = [f"{sha256(release / name)}  {name}" for name in CHECKSUM_FILES]
    actual_checksum_lines = checksum_path.read_text(encoding="ascii").splitlines()
    if actual_checksum_lines != expected_checksum_lines:
        raise ValueError("The SHA-256 file must list exactly the four release payload/archive files in canonical order.")

    portable_path = release / "EyeBreakReminder-Portable-x64.zip"
    with zipfile.ZipFile(portable_path, "r") as portable:
        matching_entries = [entry for entry in portable.infolist() if entry.filename == "EyeBreakReminder.exe"]
        if len(matching_entries) != 1:
            raise ValueError("Portable archive must contain exactly one root EyeBreakReminder.exe entry.")
        with portable.open(matching_entries[0]) as stream:
            portable_digest = hashlib.sha256()
            portable_size = 0
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                portable_size += len(block)
                portable_digest.update(block)
    standalone = release / "EyeBreakReminder.exe"
    if portable_size != standalone.stat().st_size or portable_digest.hexdigest() != sha256(standalone):
        raise ValueError("The portable ZIP executable differs from the signed standalone executable.")
    audit_source_archive(release / "EyeBreakReminder-Source.zip")

    identifier, _ = signing.public_key_from_trust_header(trust_header)
    files = {
        path.name: {"bytes": path.stat().st_size, "sha256": sha256(path)}
        for path in sorted(entries, key=lambda item: item.name)
    }
    return {
        "status": "PASS",
        "application": signing.APP,
        "repository": signing.REPOSITORY,
        "version": manifest["version"],
        "production_key_id": identifier,
        "manifest_signature_format": "64-byte raw ECDSA P-256 P1363",
        "manifest_signature_verified_against_embedded_key": True,
        "signed_payloads_verified": ["EyeBreakReminder-Setup-x64.exe", "EyeBreakReminder.exe"],
        "portable_executable_matches_standalone": True,
        "source_archive_sensitive_material_scan": "PASS",
        "release_files": files,
    }


def finalize_candidate(release: Path, manifest: Path, signature: Path, trust_header: Path) -> dict[str, object]:
    release = release.resolve(strict=True)
    entries = list(release.iterdir())
    if any(entry.is_symlink() or not entry.is_file() for entry in entries):
        raise ValueError("Unsigned candidate directory must contain only regular files, with no links or subdirectories.")
    if sorted(entry.name for entry in entries) != sorted(UNSIGNED_CANDIDATE_FILES):
        raise ValueError("Unsigned candidate directory has an unexpected file set: " + ", ".join(sorted(entry.name for entry in entries)))
    manifest = manifest.resolve(strict=True)
    signature = signature.resolve(strict=True)
    for source, name in ((manifest, "EyeBreakReminder-UpdateManifest.json"),
                         (signature, "EyeBreakReminder-UpdateManifest.sig")):
        if source == release / name or (release / name).exists():
            raise ValueError(f"Refusing to overwrite candidate metadata: {name}")
    _, signed_manifest = signing.load_manifest(manifest)
    if signed_manifest["version"] != "1.4.0":
        raise ValueError("The final candidate manifest must identify v1.4.0.")
    signing.verify_embedded_signature(trust_header, manifest, signature)
    signed_by_name = {asset["name"]: asset for asset in signed_manifest["assets"]}
    for name in ("EyeBreakReminder-Setup-x64.exe", "EyeBreakReminder.exe"):
        asset = signed_by_name[name]
        path = release / name
        if path.stat().st_size != asset["size"] or sha256(path) != asset["sha256"]:
            raise ValueError(f"Signed manifest does not match final payload bytes: {name}")

    created: list[Path] = []
    try:
        for source, name in ((manifest, "EyeBreakReminder-UpdateManifest.json"),
                             (signature, "EyeBreakReminder-UpdateManifest.sig")):
            destination = release / name
            try:
                with source.open("rb") as source_stream, destination.open("xb") as destination_stream:
                    shutil.copyfileobj(source_stream, destination_stream)
                created.append(destination)
            except Exception:
                if destination.exists():
                    destination.unlink()
                raise
        return verify_candidate(release, trust_header)
    except Exception:
        for path in created:
            path.unlink(missing_ok=True)
        raise


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--assemble", action="store_true", help="add signed public metadata to a five-file candidate")
    mode.add_argument("--verify-existing", action="store_true", help="verify an already assembled seven-file candidate")
    parser.add_argument("--release-dir", type=Path, required=True)
    parser.add_argument("--trust-header", type=Path, default=ROOT / "src" / "update_trust.hpp")
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--signature", type=Path)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.assemble:
            if args.manifest is None or args.signature is None:
                raise ValueError("Assembly requires both the signed manifest and signature files.")
            report = finalize_candidate(args.release_dir, args.manifest, args.signature, args.trust_header)
        else:
            if args.manifest is not None or args.signature is not None:
                raise ValueError("Existing-candidate verification reads metadata from the release directory.")
            report = verify_candidate(args.release_dir, args.trust_header)
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8", newline="\n")
        print(f"PASS: verified {report['application']} v{report['version']} production candidate; {len(report['release_files'])} release files.")
        return 0
    except (OSError, ValueError, RuntimeError, zipfile.BadZipFile) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
