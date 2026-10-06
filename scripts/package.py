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
with zipfile.ZipFile(release/'EyeBreakReminder-Source.zip','w',zipfile.ZIP_DEFLATED,compresslevel=9) as archive:
 for path in sorted(root.rglob('*')):
  relative=path.relative_to(root)
  if not path.is_file() or any(p in {'release','.git','__pycache__'} for p in relative.parts) or relative==Path('tests/core-tests'):continue
  archive.write(path,Path('EyeBreakReminder')/relative)
names=['EyeBreakReminder.exe','EyeBreakReminder-Setup-x64.exe','EyeBreakReminder-Portable-x64.zip','EyeBreakReminder-Source.zip']
(release/'EyeBreakReminder-SHA256.txt').write_text(''.join(hashlib.sha256((release/name).read_bytes()).hexdigest()+'  '+name+'\n' for name in names))
for name in names:print(name,(release/name).stat().st_size,'bytes')
