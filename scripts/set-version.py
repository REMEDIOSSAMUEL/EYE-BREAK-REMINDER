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
version_path = root / "VERSION"
version_bytes = version_path.read_bytes()
old = version_bytes.decode("utf-8").strip()
changes = []
for name in ["src/app.cpp", "src/app.manifest", "src/resources.rc", "installer/setup.nsi", "README.md"]:
    path = root / name
    original = path.read_bytes().decode("utf-8")
    if old not in original:
        raise SystemExit(f"Expected version {old} missing from {name}; reconcile metadata first")
    if name == "README.md":
        updated, count = re.subn(
            rf"(?m)^(# Eye Break Reminder ){re.escape(old)}( — Windows 11 x64)(\r?)$",
            rf"\g<1>{new}\g<2>\g<3>",
            original,
            count=1,
        )
        if count != 1:
            raise SystemExit(f"Expected current product version title missing from {name}; reconcile metadata first")
    else:
        updated = original.replace(old, new).replace(old.replace(".", ",") + ",0", new.replace(".", ",") + ",0")
    changes.append((path, updated))
for path, updated in changes:
    path.write_bytes(updated.encode("utf-8"))
version_newline = b"\r\n" if b"\r\n" in version_bytes else b"\n"
version_path.write_bytes(new.encode("utf-8") + version_newline)
print(f"Version {old} -> {new}. Update CHANGELOG.md and verification notes before packaging.")
