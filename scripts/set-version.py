"""Set consistent release metadata without building or publishing anything."""
import re
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
if len(sys.argv) != 2 or not re.fullmatch(r"\d+\.\d+\.\d+", sys.argv[1]):
    raise SystemExit("Usage: python3 scripts/set-version.py X.Y.Z")
new = sys.argv[1]
if any(int(part) > 65535 for part in new.split(".")):
    raise SystemExit("Each Windows version component must be at most 65535")
old = (root / "VERSION").read_text().strip()
changes = []
for name in ["src/app.cpp", "src/app.manifest", "src/resources.rc", "installer/setup.nsi", "README.md"]:
    path = root / name
    original = path.read_text()
    if old not in original:
        raise SystemExit(f"Expected version {old} missing from {name}; reconcile metadata first")
    updated = original.replace(old, new).replace(old.replace(".", ",") + ",0", new.replace(".", ",") + ",0")
    changes.append((path, updated))
for path, updated in changes:
    path.write_text(updated)
(root / "VERSION").write_text(new + "\n")
print(f"Version {old} -> {new}. Update CHANGELOG.md and verification notes before packaging.")
