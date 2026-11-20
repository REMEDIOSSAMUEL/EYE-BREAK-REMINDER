"""Focused tests for offline manifest signing-tool formats and OpenSSL interop."""
from __future__ import annotations

import datetime as dt
import hashlib
import json
from argparse import Namespace
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import update_signing as signing
import finalize_candidate as candidate


def valid_manifest(key_id: str) -> dict[str, object]:
    now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    expires = now + dt.timedelta(days=7)
    return {
        "schema_version": 1,
        "application": signing.APP,
        "repository": signing.REPOSITORY,
        "version": "1.4.1",
        "channel": "stable",
        "architecture": "x64",
        "key_id": key_id,
        "issued_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "expires_at": expires.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "assets": [
            {"name": "EyeBreakReminder-Setup-x64.exe", "role": "installer", "installation_type": "installed",
             "architecture": "x64", "size": 1024, "sha256": "a" * 64},
            {"name": "EyeBreakReminder.exe", "role": "portable-update", "installation_type": "portable",
             "architecture": "x64", "size": 2048, "sha256": "b" * 64},
        ],
    }


class SigningToolTests(unittest.TestCase):
    def test_key_acl_parser_requires_one_current_user_full_control_allow(self) -> None:
        identity = r"MACHINE\remed"
        self.assertTrue(signing.has_only_current_user_acl(
            rf"C:\signing-key {identity}:(OI)(CI)(F)", identity
        ))
        self.assertTrue(signing.has_only_current_user_acl(
            rf"C:\signing-key\private.pem {identity}:(I)(F)", identity
        ))
        self.assertFalse(signing.has_only_current_user_acl(
            rf"C:\signing-key {identity}:(R)", identity
        ))
        self.assertFalse(signing.has_only_current_user_acl(
            rf"C:\signing-key {identity}:(DENY)(F)", identity
        ))
        self.assertFalse(signing.has_only_current_user_acl(
            rf"C:\signing-key {identity}:(F)\nBUILTIN\Administrators:(F)", identity
        ))

    def test_raw_signature_encoding_round_trip(self) -> None:
        raw = bytes.fromhex("80" + "01" * 31 + "00" + "02" * 31)
        self.assertEqual(signing.der_signature_to_raw(signing.raw_signature_to_der(raw)), raw)
        with self.assertRaises(ValueError):
            signing.raw_signature_to_der(b"short")
        with self.assertRaises(ValueError):
            signing.der_signature_to_raw(b"\x30\x00")

    def test_manifest_duplicate_and_noncanonical_json_rejected(self) -> None:
        manifest = valid_manifest("p256-0123456789abcdef")
        encoded = signing.canonical_json(manifest)
        with tempfile.TemporaryDirectory(prefix="ebr-sign-tool-tests-") as folder:
            path = Path(folder) / "manifest.json"
            path.write_bytes(encoded)
            self.assertEqual(signing.load_manifest(path)[1], manifest)
            path.write_bytes(encoded.replace(b"\"version\":\"1.4.1\"", b"\"version\":\"1.4.1\",\"version\":\"1.4.2\""))
            with self.assertRaises((ValueError, json.JSONDecodeError)):
                signing.load_manifest(path)
            path.write_bytes(b" " + encoded)
            with self.assertRaises(ValueError):
                signing.load_manifest(path)

    def test_key_and_metadata_output_paths_are_protected(self) -> None:
        with tempfile.TemporaryDirectory(prefix="ebr-sign-tool-paths-") as folder:
            root = Path(folder)
            same_key_path = root / "same-key.pem"
            with self.assertRaises(ValueError):
                signing.generate_key(Namespace(private_key=same_key_path, public_key=same_key_path))
            with self.assertRaises(ValueError):
                signing.generate_key(Namespace(private_key=root / "private.pem", public_key=root / "public.pem"))
            self.assertFalse((root / "private.pem").exists())

            args = Namespace(
                private_key=root / "private.pem", public_key=root / "public.pem",
                installer=root / "EyeBreakReminder-Setup-x64.exe", portable=root / "EyeBreakReminder.exe",
                manifest=root / "manifest.json", signature=root / "manifest.sig",
                version="1.4.1", expires_at="2026-12-01T00:00:00Z",
            )
            args.manifest = args.installer
            with self.assertRaises(ValueError):
                signing.sign(args)
            args.manifest = root / "manifest.json"
            args.signature = args.manifest
            with self.assertRaises(ValueError):
                signing.sign(args)
            args.signature = root / "manifest.sig"
            args.manifest.write_bytes(b"existing metadata")
            with self.assertRaises(ValueError):
                signing.sign(args)
            args.manifest = root / "fresh-manifest.json"
            args.signature = root / "fresh-manifest.sig"
            with self.assertRaises(ValueError):
                signing.sign(args)

    def test_private_key_path_rejects_checkout_onedrive_and_temp(self) -> None:
        with tempfile.TemporaryDirectory(prefix="ebr-key-location-policy-") as folder:
            root = Path(folder)
            checkout = root / "checkout"
            sync = root / "OneDrive"
            temp_root = root / "tmp"
            safe = root / "offline-key-media"
            for directory in (checkout, sync, temp_root, safe):
                directory.mkdir()
            self.assertEqual(
                signing.validate_private_key_path(
                    safe / "production-private.pem",
                    project_root=checkout,
                    sync_roots=[sync],
                    temp_root=temp_root,
                ),
                (safe / "production-private.pem").resolve(),
            )
            for unsafe in (
                checkout / "production-private.pem",
                sync / "production-private.pem",
                temp_root / "production-private.pem",
            ):
                with self.subTest(path=unsafe), self.assertRaises(ValueError):
                    signing.validate_private_key_path(
                        unsafe,
                        project_root=checkout,
                        sync_roots=[sync],
                        temp_root=temp_root,
                    )

            # The checkout's path ancestry should identify its sync root even
            # when the caller does not inject a test-only root list.
            nested_sync = root / "OneDrive - Personal"
            nested_project = nested_sync / "project"
            nested_project.mkdir(parents=True)
            with self.assertRaises(ValueError):
                signing.validate_private_key_path(
                    nested_sync / "production-private.pem",
                    project_root=nested_project,
                    temp_root=temp_root,
                )

    @unittest.skipUnless(os.name == "nt" and shutil.which("icacls"), "Windows ACL verification only")
    def test_new_key_directory_acl_is_limited_to_current_user(self) -> None:
        with tempfile.TemporaryDirectory(prefix="ebr-key-acl-policy-") as folder:
            root = Path(folder)
            directory = root / "signing-key"
            sid = signing.restrict_private_key_directory(
                directory,
                project_root=root / "checkout",
                sync_roots=[],
                temp_root=root / "not-a-temp-root",
            )
            self.assertTrue(directory.is_dir())
            self.assertRegex(sid, r"^S-1-\d+(?:-\d+)+$")
            identity, _ = signing.current_windows_user()
            acl_probe = directory / "non-secret-acl-probe.txt"
            acl_probe.write_text("acl verification only", encoding="ascii")
            acl = subprocess.run(["icacls", str(acl_probe)], check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            self.assertEqual(acl.returncode, 0)
            self.assertTrue(signing.has_only_current_user_acl(acl.stdout, identity))
            signing.verify_private_key_acl(acl_probe)
            with self.assertRaises(ValueError):
                signing.restrict_private_key_directory(
                    directory,
                    project_root=root / "checkout",
                    sync_roots=[],
                    temp_root=root / "not-a-temp-root",
                )

    def test_openssl_signature_and_embedded_public_key(self) -> None:
        with tempfile.TemporaryDirectory(prefix="ebr-disposable-sign-tool-key-") as folder:
            root = Path(folder)
            private = root / "disposable-test-private.pem"
            public = root / "disposable-test-public.pem"
            manifest_path = root / "manifest.json"
            signature_path = root / "manifest.sig"
            der_path = root / "signature.der"
            header = root / "test-trust.hpp"
            subprocess.run(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", str(private)], check=True, stdout=subprocess.DEVNULL)
            subprocess.run(["openssl", "pkey", "-in", str(private), "-pubout", "-out", str(public)], check=True, stdout=subprocess.DEVNULL)
            point = signing.point_from_public_pem(public)
            manifest_path.write_bytes(signing.canonical_json(valid_manifest(signing.key_id(point))))
            signing.run_openssl("dgst", "-sha256", "-sign", str(private), "-out", str(der_path), str(manifest_path))
            signature_path.write_bytes(signing.der_signature_to_raw(der_path.read_bytes()))
            signing.verify_signature(public, manifest_path, signature_path)
            signing.write_trust_header(public, header)
            self.assertIn(signing.key_id(point), header.read_text(encoding="ascii"))
            self.assertIn("ProductionUpdateKeyProvisioned=true", header.read_text(encoding="ascii"))
            self.assertEqual(signing.public_key_from_trust_header(header), (signing.key_id(point), point))
            signing.verify_embedded_signature(header, manifest_path, signature_path)
            changed = bytearray(manifest_path.read_bytes())
            changed[changed.index(b"1.4.1")] = ord("9")
            manifest_path.write_bytes(changed)
            with self.assertRaises((ValueError, RuntimeError)):
                signing.verify_signature(public, manifest_path, signature_path)
            with self.assertRaises((ValueError, RuntimeError)):
                signing.verify_embedded_signature(header, manifest_path, signature_path)

    def test_embedded_signature_requires_exact_provisioned_trust_root(self) -> None:
        with tempfile.TemporaryDirectory(prefix="ebr-embedded-root-test-") as folder:
            root = Path(folder)
            unprovisioned = root / "unprovisioned.hpp"
            unprovisioned.write_text(
                "inline constexpr bool ProductionUpdateKeyProvisioned=false;\n"
                'inline constexpr std::string_view ProductionUpdateKeyId="";\n'
                "inline constexpr std::array<unsigned char,64> ProductionUpdatePublicKey{};\n",
                encoding="ascii",
            )
            with self.assertRaises(ValueError):
                signing.public_key_from_trust_header(unprovisioned)

            wrong_id = root / "wrong-id.hpp"
            wrong_id.write_text(
                "inline constexpr bool ProductionUpdateKeyProvisioned=true;\n"
                'inline constexpr std::string_view ProductionUpdateKeyId="p256-0000000000000000";\n'
                "inline constexpr std::array<unsigned char,64> ProductionUpdatePublicKey{{\n"
                + ",".join("0x00" for _ in range(64))
                + "\n}};\n",
                encoding="ascii",
            )
            with self.assertRaises(ValueError):
                signing.public_key_from_trust_header(wrong_id)

    def test_final_candidate_assembly_checks_embedded_signature_and_exact_payloads(self) -> None:
        with tempfile.TemporaryDirectory(prefix="ebr-final-candidate-test-") as folder:
            root = Path(folder)
            release = root / "release"
            release.mkdir()
            standalone = release / "EyeBreakReminder.exe"
            installer = release / "EyeBreakReminder-Setup-x64.exe"
            portable = release / "EyeBreakReminder-Portable-x64.zip"
            source = release / "EyeBreakReminder-Source.zip"
            standalone.write_bytes(b"standalone-v1.4.0-test-payload")
            installer.write_bytes(b"installer-v1.4.0-test-payload")
            with zipfile.ZipFile(portable, "w", zipfile.ZIP_DEFLATED) as archive:
                archive.write(standalone, "EyeBreakReminder.exe")
            with zipfile.ZipFile(source, "w", zipfile.ZIP_DEFLATED) as archive:
                archive.writestr("EyeBreakReminder/README.md", "test source snapshot")

            checksum = "".join(
                f"{candidate.sha256(release / name)}  {name}\n"
                for name in candidate.CHECKSUM_FILES
            )
            (release / "EyeBreakReminder-SHA256.txt").write_text(checksum, encoding="ascii")

            private = root / "disposable-test-private.pem"
            public = root / "disposable-test-public.pem"
            header = root / "test-trust.hpp"
            manifest_path = root / "signed-manifest.json"
            signature_path = root / "signed-manifest.sig"
            der_path = root / "signature.der"
            subprocess.run(
                ["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", str(private)],
                check=True, stdout=subprocess.DEVNULL,
            )
            subprocess.run(["openssl", "pkey", "-in", str(private), "-pubout", "-out", str(public)],
                           check=True, stdout=subprocess.DEVNULL)
            point = signing.point_from_public_pem(public)
            manifest = valid_manifest(signing.key_id(point))
            manifest["version"] = "1.4.0"
            manifest["assets"][0]["size"] = installer.stat().st_size
            manifest["assets"][0]["sha256"] = candidate.sha256(installer)
            manifest["assets"][1]["size"] = standalone.stat().st_size
            manifest["assets"][1]["sha256"] = candidate.sha256(standalone)
            manifest_path.write_bytes(signing.canonical_json(manifest))
            signing.run_openssl("dgst", "-sha256", "-sign", str(private), "-out", str(der_path), str(manifest_path))
            signature_path.write_bytes(signing.der_signature_to_raw(der_path.read_bytes()))
            signing.write_trust_header(public, header)

            result = candidate.finalize_candidate(release, manifest_path, signature_path, header)
            self.assertEqual(result["status"], "PASS")
            self.assertTrue(result["manifest_signature_verified_against_embedded_key"])
            self.assertEqual(len(result["release_files"]), 7)
            self.assertTrue((release / "EyeBreakReminder-UpdateManifest.json").is_file())
            audited = candidate.verify_candidate(release, header)
            self.assertEqual(audited["production_key_id"], signing.key_id(point))

            (release / "EyeBreakReminder-UpdateManifest.json").unlink()
            (release / "EyeBreakReminder-UpdateManifest.sig").unlink()
            with zipfile.ZipFile(source, "w", zipfile.ZIP_DEFLATED) as archive:
                archive.writestr("EyeBreakReminder/production-private.pem", "placeholder private-key file")
            checksum = "".join(
                f"{candidate.sha256(release / name)}  {name}\n"
                for name in candidate.CHECKSUM_FILES
            )
            (release / "EyeBreakReminder-SHA256.txt").write_text(checksum, encoding="ascii")
            with self.assertRaises(ValueError):
                candidate.finalize_candidate(release, manifest_path, signature_path, header)
            self.assertFalse((release / "EyeBreakReminder-UpdateManifest.json").exists())
            self.assertFalse((release / "EyeBreakReminder-UpdateManifest.sig").exists())

    def test_final_candidate_rejects_payload_change_without_partial_metadata(self) -> None:
        with tempfile.TemporaryDirectory(prefix="ebr-final-candidate-reject-") as folder:
            root = Path(folder)
            release = root / "release"
            release.mkdir()
            for name, data in (
                ("EyeBreakReminder.exe", b"portable"),
                ("EyeBreakReminder-Setup-x64.exe", b"installer"),
                ("EyeBreakReminder-Portable-x64.zip", b"zip"),
                ("EyeBreakReminder-Source.zip", b"source"),
                ("EyeBreakReminder-SHA256.txt", b"checksums\n"),
            ):
                (release / name).write_bytes(data)
            private = root / "disposable-test-private.pem"
            public = root / "disposable-test-public.pem"
            header = root / "test-trust.hpp"
            manifest_path = root / "signed-manifest.json"
            signature_path = root / "signed-manifest.sig"
            subprocess.run(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", str(private)],
                           check=True, stdout=subprocess.DEVNULL)
            subprocess.run(["openssl", "pkey", "-in", str(private), "-pubout", "-out", str(public)],
                           check=True, stdout=subprocess.DEVNULL)
            signing.write_trust_header(public, header)
            point = signing.point_from_public_pem(public)
            manifest = valid_manifest(signing.key_id(point))
            raw = signing.canonical_json(manifest)
            manifest_path.write_bytes(raw)
            der = root / "signature.der"
            signing.run_openssl("dgst", "-sha256", "-sign", str(private), "-out", str(der), str(manifest_path))
            signature_path.write_bytes(signing.der_signature_to_raw(der.read_bytes()))
            with self.assertRaises(ValueError):
                candidate.finalize_candidate(release, manifest_path, signature_path, header)
            self.assertFalse((release / "EyeBreakReminder-UpdateManifest.json").exists())
            self.assertFalse((release / "EyeBreakReminder-UpdateManifest.sig").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
