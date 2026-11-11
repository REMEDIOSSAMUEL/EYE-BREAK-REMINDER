"""Verify real Windows PE files/resources and packaged bytes; no Windows runtime test."""
from pathlib import Path
import struct, hashlib, json, zipfile, xml.etree.ElementTree as ET
ROOT=Path(__file__).resolve().parents[1]
checks=0

def require(value,message):
 global checks
 if not value: raise RuntimeError(message)
 checks+=1

class PE:
 def __init__(self,path):
  self.path=path;self.data=path.read_bytes();d=self.data
  require(d[:2]==b'MZ',f'{path.name}: DOS signature')
  self.pe=struct.unpack_from('<I',d,0x3c)[0]
  require(d[self.pe:self.pe+4]==b'PE\0\0',f'{path.name}: PE signature')
  self.machine,self.count=struct.unpack_from('<HH',d,self.pe+4)
  self.optional=self.pe+24;self.optional_size=struct.unpack_from('<H',d,self.pe+20)[0]
  self.magic=struct.unpack_from('<H',d,self.optional)[0]
  require(self.magic in (0x10b,0x20b),f'{path.name}: optional header')
  self.subsystem,self.flags=struct.unpack_from('<HH',d,self.optional+68)
  self.directories=self.optional+(112 if self.magic==0x20b else 96)
  self.sections=[]
  for i in range(self.count):
   at=self.optional+self.optional_size+i*40
   name=d[at:at+8].rstrip(b'\0').decode('ascii')
   virtual_size,rva,size,offset=struct.unpack_from('<IIII',d,at+8)
   self.sections.append((name,rva,virtual_size,size,offset))
 def directory(self,index):return struct.unpack_from('<II',self.data,self.directories+index*8)
 def offset(self,rva):
  for _,at,virtual,size,offset in self.sections:
   if at<=rva<at+max(virtual,size):
    delta=rva-at
    require(delta<size,'RVA outside section raw bytes')
    return offset+delta
  raise RuntimeError(f'Unmapped RVA {rva:x}')
 def imports(self):
  rva,size=self.directory(1)
  if not rva:return []
  at=self.offset(rva);result=[]
  while True:
   entry=struct.unpack_from('<IIIII',self.data,at)
   if not any(entry):break
   start=self.offset(entry[3]);end=self.data.index(b'\0',start)
   result.append(self.data[start:end].decode('ascii'));at+=20
  return result
 def resources(self):
  rva,size=self.directory(2)
  require(rva!=0,'Resources embedded')
  base=self.offset(rva);out={}
  def walk(relative,path):
   named,ids=struct.unpack_from('<HH',self.data,base+relative+12)
   for i in range(named+ids):
    name,target=struct.unpack_from('<II',self.data,base+relative+16+i*8)
    if name&0x80000000:
     loc=base+(name&0x7fffffff);n=struct.unpack_from('<H',self.data,loc)[0]
     key=self.data[loc+2:loc+2+2*n].decode('utf-16le')
    else:key=name
    route=path+(key,)
    if target&0x80000000:walk(target&0x7fffffff,route)
    else:
     data_rva,length,_,_=struct.unpack_from('<IIII',self.data,base+target)
     raw=self.offset(data_rva);out[route]=self.data[raw:raw+length]
  walk(0,());return out

app=PE(ROOT/'release/EyeBreakReminder.exe')
require(app.machine==0x8664 and app.magic==0x20b,'Application must be x64 PE32+')
require(app.subsystem==2,'Application must use Windows GUI subsystem')
require(app.flags&0x160==0x160,'ASLR, NX and high-entropy VA flags')
require(app.directory(4)==(0,0),'Expected unsigned release')
imports=app.imports()
allowed={'advapi32.dll','comctl32.dll','dwmapi.dll','gdi32.dll','gdiplus.dll','kernel32.dll','msvcrt.dll','ole32.dll','shell32.dll','user32.dll','wtsapi32.dll','winmm.dll','uxtheme.dll','winhttp.dll','version.dll'}
require(all(d.lower() in allowed for d in imports),'Only built-in Windows DLL dependencies')
require(not any('libgcc' in d.lower() or 'libstdc++' in d.lower() for d in imports),'No external GCC/C++ runtime DLLs')
resources=app.resources()
def resource(kind,name):
 matches=[v for k,v in resources.items() if k[0]==kind and k[1]==name]
 require(len(matches)==1,f'Embedded resource {kind}/{name}')
 return matches[0]
manifest=resource(24,1);ET.fromstring(manifest)
require(b'level="asInvoker"' in manifest,'Standard-user manifest')
require(b'PerMonitorV2' in manifest and b'processorArchitecture="amd64"' in manifest,'DPI/x64 manifest')
require(b'Microsoft.Windows.Common-Controls' in manifest,'Visual styles activation manifest')
version=resource(16,1)
release_version=(ROOT/'VERSION').read_text().strip()
for value in ['Eye Break Reminder',release_version,release_version+'.0']:
 require(value.encode('utf-16le') in version,'Version metadata '+value)
require('CompanyName'.encode('utf-16le') not in version and 'LegalCopyright'.encode('utf-16le') not in version,'No invented publisher/copyright')
group=resource(14,1);reserved,kind,count=struct.unpack_from('<HHH',group)
require(kind==1 and count==9,'Nine embedded icon images')
sizes=set()
for i in range(count):
 width,height=struct.unpack_from('<BB',group,6+i*14);sizes.add((width or 256,height or 256))
require(sizes=={(n,n) for n in [16,20,24,32,40,48,64,128,256]},'Embedded icon dimensions')
for i,name in enumerate(['Gentle','Bell','Chime','Clear','Soft']):
 require(resource(10,101+i)==(ROOT/'assets'/f'{name}.wav').read_bytes(),'Embedded sound bytes '+name)
installer_path=ROOT/'release/EyeBreakReminder-Setup-x64.exe'
if installer_path.exists():
 installer=PE(installer_path)
 require(installer.subsystem==2,'Installer uses Windows GUI subsystem')
 require(installer.machine==0x14c,'NSIS standard x86 bootstrap architecture reported honestly')
 require(installer.directory(4)==(0,0),'Installer unsigned')
 script=(ROOT/'installer/setup.nsi').read_text()
 require('IsNativeAMD64' in script and '22000' in script,'Installer restricts native Windows 11 x64')
 require('RequestExecutionLevel user' in script,'Per-user non-elevated installer')
for name in ['EyeBreakReminder-Portable-x64.zip','EyeBreakReminder-Source.zip']:
 path=ROOT/'release'/name
 if path.exists():
  with zipfile.ZipFile(path) as archive:
   require(archive.testzip() is None,'Archive CRCs '+name)
   names=archive.namelist()
   if 'Portable' in name:
    require(archive.read('EyeBreakReminder.exe')==app.data,'Portable executable matches actual verified build')
   else:
    require('EyeBreakReminder/src/app.cpp' in names and 'EyeBreakReminder/tests/core_tests.cpp' in names,'Complete source/tests in archive')
    require(not any('/release/' in p or p.endswith('/core-tests') for p in names),'Source archive excludes build outputs')
    # No compiled test binary (Linux or Windows name), other binaries, archives, temporary files, signing secrets or tool folders.
    banned=('.exe','.dll','.o','.obj','.pdb','.zip','.tmp','.pyc','.pfx','.pem','.p12','.key')
    require(not any(p.lower().endswith(banned) or any(part in {'build','dist','__pycache__'} or part.startswith('.') for part in p.split('/')[1:-1]) for p in names),'Source archive has no binaries, build outputs, secrets or tool folders')
    # Everything needed to build, test and package is present: sources, test sources, scripts, installer, assets, documentation.
    shipped={str(f.relative_to(ROOT)).replace('\\','/') for d in ['src','scripts','installer','assets','docs'] for f in (ROOT/d).rglob('*') if f.is_file() and not f.name.lower().endswith(banned) and '__pycache__' not in f.parts}
    shipped|={'tests/core_tests.cpp','Makefile','VERSION','README.md','CHANGELOG.md','CONTRIBUTING.md','.editorconfig','.gitattributes','.gitignore'}
    missing=sorted(p for p in shipped if 'EyeBreakReminder/'+p not in names)
    require(not missing,'Source archive is missing '+', '.join(missing))
hashes=ROOT/'release/EyeBreakReminder-SHA256.txt'
if hashes.exists():
 for line in hashes.read_text().splitlines():
  digest,name=line.split('  ',1)
  require(hashlib.sha256((ROOT/'release'/name).read_bytes()).hexdigest()==digest,'SHA256 '+name)
report={'application':'EyeBreakReminder.exe','machine':'AMD64 / x64','subsystem':'Windows GUI','windows_dll_imports':imports,'embedded_icon_sizes':sorted(sizes),'embedded_alarm_count':5,'unsigned':True,'windows_11_runtime_tested':False,'binary_and_package_assertions_passed':checks}
(ROOT/'release/BINARY-VERIFICATION.json').write_text(json.dumps(report,indent=2)+'\n')
print(f'PASS: {checks} binary/package assertions. Actual x64 Windows GUI executable; 5 embedded sounds; 9 icon sizes. Windows runtime NOT tested.')
