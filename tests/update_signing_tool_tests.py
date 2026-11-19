"""Focused tests for offline manifest signing-tool formats and OpenSSL interop."""
from __future__ import annotations

import datetime as dt
import hashlib
import json
from argparse import Namespace
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import update_signing as signing


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
            changed = bytearray(manifest_path.read_bytes())
            changed[changed.index(b"1.4.1")] = ord("9")
            manifest_path.write_bytes(changed)
            with self.assertRaises((ValueError, RuntimeError)):
                signing.verify_signature(public, manifest_path, signature_path)


if __name__ == "__main__":
    unittest.main(verbosity=2)
