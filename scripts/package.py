"""Package only the actual compiled Windows files and complete source."""
from pathlib import Path
import zipfile, hashlib
root=Path(__file__).resolve().parents[1];release=root/'release'
for name in ['EyeBreakReminder.exe','EyeBreakReminder-Setup-x64.exe']:
 if not (release/name).is_file():raise RuntimeError('Build required: '+name)
with zipfile.ZipFile(release/'EyeBreakReminder-Portable-x64.zip','w',zipfile.ZIP_DEFLATED,compresslevel=9) as archive:
 archive.write(release/'EyeBreakReminder.exe','EyeBreakReminder.exe')
 archive.write(root/'README.md','README.md')
 for name in ['PRIVACY.md','VERIFICATION.md','THIRD-PARTY-LICENSES.txt']:
  archive.write(root/'docs'/name,name)
 archive.writestr('SIGNING-STATUS.txt','UNSIGNED. No signing certificate or publisher identity was supplied.\n')
# Build outputs, local tool folders and signing secrets never belong in the source archive (mirrors .gitignore). The test
# binary is tests/core-tests on Linux and tests/core-tests.exe when MinGW builds it on Windows.
EXCLUDED_DIRS={'release','build','dist','__pycache__'}
EXCLUDED_SUFFIXES={'.exe','.dll','.o','.obj','.pdb','.zip','.tmp','.pyc','.pfx','.pem','.p12','.key'}
def in_source(relative):
 # A linked worktree stores its Git metadata in a root .git text file. Never
 # ship that machine-specific pointer, while keeping the public CI workflow.
 if relative==Path('.git'):return False
 if any(p in EXCLUDED_DIRS or (p.startswith('.') and p!='.github') for p in relative.parts[:-1]):return False
 # This final report contains the source ZIP's digest; excluding it avoids a self-referential archive hash.
 if relative==Path('docs/FINAL_PRE_RELEASE_VERIFICATION.md'):return False
 return relative!=Path('tests/core-tests') and relative.suffix.lower() not in EXCLUDED_SUFFIXES
with zipfile.ZipFile(release/'EyeBreakReminder-Source.zip','w',zipfile.ZIP_DEFLATED,compresslevel=9) as archive:
 for path in sorted(root.rglob('*')):
  relative=path.relative_to(root)
  if not path.is_file() or not in_source(relative):continue
  archive.write(path,Path('EyeBreakReminder')/relative)
names=['EyeBreakReminder.exe','EyeBreakReminder-Setup-x64.exe','EyeBreakReminder-Portable-x64.zip','EyeBreakReminder-Source.zip']
(release/'EyeBreakReminder-SHA256.txt').write_text(''.join(hashlib.sha256((release/name).read_bytes()).hexdigest()+'  '+name+'\n' for name in names))
for name in names:print(name,(release/name).stat().st_size,'bytes')
