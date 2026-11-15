param(
  [Parameter(Mandatory=$true)][string]$InstallerPath,
  [Parameter(Mandatory=$true)][string]$StandaloneExecutable,
  [Parameter(Mandatory=$true)][string]$PortableArchive,
  [Parameter(Mandatory=$true)][string]$EvidenceDirectory
)
$ErrorActionPreference='Stop'
$InstallerPath=[IO.Path]::GetFullPath($InstallerPath)
$StandaloneExecutable=[IO.Path]::GetFullPath($StandaloneExecutable)
$PortableArchive=[IO.Path]::GetFullPath($PortableArchive)
$EvidenceDirectory=[IO.Path]::GetFullPath($EvidenceDirectory)
$repoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$releaseRoot=[IO.Path]::GetFullPath((Join-Path $repoRoot 'release'))
foreach($path in @($InstallerPath,$StandaloneExecutable,$PortableArchive)){
  if(-not $path.StartsWith($releaseRoot+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw "Refusing to test a candidate outside ${releaseRoot}: $path"}
  if(-not (Test-Path -LiteralPath $path -PathType Leaf)){throw "Candidate asset is missing: $path"}
}
if(-not [Environment]::UserInteractive){throw 'Windows 11 ARM64 emulation test requires an interactive disposable runner.'}
[void][IO.Directory]::CreateDirectory($EvidenceDirectory)
$events=[System.Collections.Generic.List[object]]::new()
$expectedVersion='1.3.0'
$installDirectory=Join-Path $env:LOCALAPPDATA 'Programs\EyeBreakReminder'
$uninstallKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder'
$installExistedBefore=Test-Path -LiteralPath $installDirectory
$uninstallKeyExistedBefore=Test-Path -LiteralPath $uninstallKey
function Add-Event([string]$Name,[string]$Status,$Details=$null){
  $script:events.Add([pscustomobject]@{Name=$Name;Status=$Status;Details=$Details;Utc=[DateTime]::UtcNow.ToString('o')})
  Write-Output "[$Status] $Name"
}
function Require([bool]$Condition,[string]$Name,$Details=$null){
  if($Condition){Add-Event $Name 'PASS' $Details;return}
  Add-Event $Name 'FAIL' $Details
  throw "ARM64 acceptance failed: $Name"
}
if(-not ('EBR_ARM64_ACCEPTANCE_Native' -as [type])){
  Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public struct EBR_ARM64_RECT { public int Left; public int Top; public int Right; public int Bottom; }
public static class EBR_ARM64_ACCEPTANCE_Native {
  private delegate bool EnumWindowProc(IntPtr hwnd, IntPtr lParam);
  [DllImport("user32.dll", SetLastError=true)] private static extern bool EnumWindows(EnumWindowProc callback, IntPtr lParam);
  [DllImport("user32.dll", SetLastError=true)] private static extern bool EnumChildWindows(IntPtr parent, EnumWindowProc callback, IntPtr lParam);
  [DllImport("user32.dll", SetLastError=true)] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="GetWindowTextW", SetLastError=true)] private static extern int GetWindowTextNative(IntPtr hwnd, StringBuilder text, int maxCount);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="GetClassNameW", SetLastError=true)] private static extern int GetClassNameNative(IntPtr hwnd, StringBuilder name, int maxCount);
  [DllImport("user32.dll", SetLastError=true)] private static extern int GetDlgCtrlID(IntPtr hwnd);
  [DllImport("user32.dll", SetLastError=true)] private static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll", SetLastError=true)] private static extern bool IsWindowEnabled(IntPtr hwnd);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool GetWindowRect(IntPtr hwnd, out EBR_ARM64_RECT rect);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool SetForegroundWindow(IntPtr hwnd);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="SendMessageW", SetLastError=true)] public static extern IntPtr SendMessage(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool PostMessage(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll", SetLastError=true)] public static extern int GetSystemMetrics(int index);
  public static string Text(IntPtr hwnd) { var b=new StringBuilder(2048); GetWindowTextNative(hwnd,b,b.Capacity); return b.ToString(); }
  public static string ClassName(IntPtr hwnd) { var b=new StringBuilder(256); GetClassNameNative(hwnd,b,b.Capacity); return b.ToString(); }
  public static int ControlId(IntPtr hwnd) { return GetDlgCtrlID(hwnd); }
  public static bool Visible(IntPtr hwnd) { return IsWindowVisible(hwnd); }
  public static bool Enabled(IntPtr hwnd) { return IsWindowEnabled(hwnd); }
  public static IntPtr[] WindowsForProcess(int expectedPid) {
    var found=new List<IntPtr>();
    EnumWindows((hwnd,l)=>{ uint pid; GetWindowThreadProcessId(hwnd,out pid); if(pid==(uint)expectedPid && IsWindowVisible(hwnd)) found.Add(hwnd); return true; },IntPtr.Zero);
    return found.ToArray();
  }
  public static IntPtr[] Children(IntPtr parent) {
    var found=new List<IntPtr>();
    EnumChildWindows(parent,(hwnd,l)=>{found.Add(hwnd);return true;},IntPtr.Zero);
    return found.ToArray();
  }
}
'@
}
function Save-DesktopScreenshot([string]$Path){
  Add-Type -AssemblyName System.Drawing
  $width=[EBR_ARM64_ACCEPTANCE_Native]::GetSystemMetrics(0);$height=[EBR_ARM64_ACCEPTANCE_Native]::GetSystemMetrics(1)
  if($width -lt 640 -or $height -lt 480){throw "Invalid interactive desktop bounds ${width}x${height}."}
  $bitmap=[System.Drawing.Bitmap]::new($width,$height);$graphics=[System.Drawing.Graphics]::FromImage($bitmap)
  try{$graphics.CopyFromScreen(0,0,0,0,$bitmap.Size);$bitmap.Save($Path,[System.Drawing.Imaging.ImageFormat]::Png)}finally{$graphics.Dispose();$bitmap.Dispose()}
  return [pscustomobject]@{Path=$Path;Width=$width;Height=$height;Bytes=(Get-Item -LiteralPath $Path).Length}
}
$ownedProcesses=[System.Collections.Generic.List[Diagnostics.Process]]::new()
$portableTemp=$null
function Invoke-ExpectedNativeX64Guard([string]$Path,[string]$Label,[string]$TitlePattern,[string]$MessagePattern,[string]$ScreenshotName){
  $process=Start-Process -FilePath $Path -WorkingDirectory (Split-Path -Parent $Path) -PassThru
  $script:ownedProcesses.Add($process)
  $timer=[Diagnostics.Stopwatch]::StartNew();$window=[IntPtr]::Zero
  while($timer.Elapsed.TotalSeconds -lt 20 -and $window -eq [IntPtr]::Zero){
    foreach($candidateWindow in [EBR_ARM64_ACCEPTANCE_Native]::WindowsForProcess($process.Id)){
      if([EBR_ARM64_ACCEPTANCE_Native]::Text($candidateWindow) -match $TitlePattern){$window=$candidateWindow;break}
    }
    if($window -eq [IntPtr]::Zero){$process.Refresh();if($process.HasExited){break};Start-Sleep -Milliseconds 100}
  }
  $process.Refresh()
  Require ($window -ne [IntPtr]::Zero) "$Label displays its native-AMD64 support guard" ([pscustomobject]@{Pid=$process.Id;Exited=$process.HasExited;ExitCode=$(if($process.HasExited){$process.ExitCode}else{$null})})
  [void][EBR_ARM64_ACCEPTANCE_Native]::SetForegroundWindow($window);Start-Sleep -Milliseconds 250
  $controls=@([EBR_ARM64_ACCEPTANCE_Native]::Children($window) | ForEach-Object {[pscustomobject]@{Handle=$_;Class=[EBR_ARM64_ACCEPTANCE_Native]::ClassName($_);Text=[EBR_ARM64_ACCEPTANCE_Native]::Text($_);ControlId=[EBR_ARM64_ACCEPTANCE_Native]::ControlId($_);Visible=[EBR_ARM64_ACCEPTANCE_Native]::Visible($_);Enabled=[EBR_ARM64_ACCEPTANCE_Native]::Enabled($_)}})
  $staticText=@($controls|Where-Object{$_.Class-eq'Static'}|ForEach-Object{$_.Text}|Where-Object{$_})
  $details=[pscustomobject]@{Binary=$Path;WindowTitle=[EBR_ARM64_ACCEPTANCE_Native]::Text($window);WindowClass=[EBR_ARM64_ACCEPTANCE_Native]::ClassName($window);StaticText=$staticText;Controls=@($controls|ForEach-Object{[pscustomobject]@{Class=$_.Class;Text=$_.Text;ControlId=$_.ControlId;Visible=$_.Visible;Enabled=$_.Enabled}})}
  $details|Add-Member -NotePropertyName Screenshot -NotePropertyValue (Save-DesktopScreenshot (Join-Path $EvidenceDirectory $ScreenshotName))
  Require (($staticText -join ' ') -match $MessagePattern) "$Label explicitly rejects non-native-AMD64 Windows with the expected message" $details
  $ok=@($controls|Where-Object{$_.Class-eq'Button' -and $_.Text -match '^\s*&?OK\s*$' -and $_.Visible -and $_.Enabled})
  Require ($ok.Count -eq 1) "$Label support guard has one enabled OK button" ([pscustomobject]@{Count=$ok.Count;ControlId=@($ok|ForEach-Object{$_.ControlId})})
  [void][EBR_ARM64_ACCEPTANCE_Native]::SendMessage($ok[0].Handle,0x00F5,[IntPtr]::Zero,[IntPtr]::Zero)
  Require ($process.WaitForExit(15000)) "$Label exits after the native-AMD64 guard is acknowledged" ([pscustomobject]@{Pid=$process.Id;ExitCode=$(if($process.HasExited){$process.ExitCode}else{$null})})
  return [pscustomobject]@{Path=$Path;Pid=$process.Id;ExitCode=$process.ExitCode;GuardText=$staticText}
}
try{
  $os=Get-CimInstance Win32_OperatingSystem
  $osArch=[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
  $processArch=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
  Require ($os.Caption -match 'Windows 11' -and $osArch -eq 'Arm64' -and $processArch -eq 'Arm64') 'Runner is genuine Windows 11 ARM64 with ARM64 PowerShell' ([pscustomobject]@{Caption=$os.Caption;Version=$os.Version;OSArchitecture=$osArch;ProcessArchitecture=$processArch})

  $exeFile=Get-Item -LiteralPath $StandaloneExecutable
  $setupFile=Get-Item -LiteralPath $InstallerPath
  Require ($exeFile.VersionInfo.ProductVersion -match '^1\.3\.0(\.0)?$' -and $setupFile.VersionInfo.ProductVersion -match '^1\.3\.0(\.0)?$') 'Candidate executable and installer are version 1.3.0' ([pscustomobject]@{Executable=$exeFile.VersionInfo.ProductVersion;Installer=$setupFile.VersionInfo.ProductVersion})

  $reader=[IO.BinaryReader]::new([IO.File]::OpenRead($StandaloneExecutable))
  try{$reader.BaseStream.Position=0x3C;$pe=$reader.ReadInt32();$reader.BaseStream.Position=$pe;if($reader.ReadUInt32()-ne0x00004550){throw 'Candidate executable has no PE signature.'};$machine=$reader.ReadUInt16()}finally{$reader.Dispose()}
  $exeHash=(Get-FileHash -LiteralPath $StandaloneExecutable -Algorithm SHA256).Hash.ToLowerInvariant()
  Require ($machine -eq 0x8664) 'Application payload is AMD64 x64 PE for emulation' ([pscustomobject]@{PEMachine=('0x{0:X4}' -f $machine);SHA256=$exeHash})

  $installerGuard=Invoke-ExpectedNativeX64Guard $InstallerPath 'Production installer' 'Eye Break Reminder Setup' 'Eye Break Reminder requires Windows 11 x64\.' 'windows-11-arm64-installer-platform-guard.png'
  if(-not $installExistedBefore -and -not $uninstallKeyExistedBefore){
    Require (-not (Test-Path -LiteralPath $installDirectory) -and -not (Test-Path -LiteralPath $uninstallKey)) 'Unsupported ARM64 setup creates no installation or uninstall registration'
  }else{
    Add-Event 'Unsupported ARM64 setup leaves pre-existing installation state untouched' 'NOT TESTED' ([pscustomobject]@{InstallDirectoryExisted=$installExistedBefore;UninstallKeyExisted=$uninstallKeyExistedBefore})
  }
  Add-Event 'Full application settings and timer integration under ARM64 is not applicable to this product build' 'NOT APPLICABLE' 'The application itself intentionally exits unless GetNativeSystemInfo reports native AMD64; Windows Server 2025 x64 exercises the full app integration suite.'
  $appGuard=Invoke-ExpectedNativeX64Guard $StandaloneExecutable 'Standalone application' 'Eye Break Reminder' 'This release supports Windows 11 x64\.' 'windows-11-arm64-standalone-platform-guard.png'

  $portableTemp=Join-Path $env:TEMP ('ebr-arm64-portable-'+[guid]::NewGuid().ToString('N'))
  Expand-Archive -LiteralPath $PortableArchive -DestinationPath $portableTemp -Force
  $portableExecutable=Join-Path $portableTemp 'EyeBreakReminder.exe'
  Require (Test-Path -LiteralPath $portableExecutable -PathType Leaf) 'Portable archive contains its x64 application executable'
  $portableHash=(Get-FileHash -LiteralPath $portableExecutable -Algorithm SHA256).Hash.ToLowerInvariant()
  Require ($portableHash -ceq $exeHash) 'Portable executable is byte-identical to the standalone payload' ([pscustomobject]@{StandaloneSHA256=$exeHash;PortableSHA256=$portableHash})
  $portableGuard=Invoke-ExpectedNativeX64Guard $portableExecutable 'Portable application' 'Eye Break Reminder' 'This release supports Windows 11 x64\.' 'windows-11-arm64-portable-platform-guard.png'
  Add-Event 'ARM64 results reflect the product native-AMD64 guard, not native Windows 11 x64 acceptance' 'PASS' ([pscustomobject]@{InstallerGuard=$installerGuard.GuardText;StandaloneGuard=$appGuard.GuardText;PortableGuard=$portableGuard.GuardText;InstallerUnsupportedOnARM64=$true;FullAppIntegration='Not applicable on unsupported architecture'})
}catch{
  Add-Event 'Windows 11 ARM64 emulation acceptance completed' 'FAIL' ([pscustomobject]@{Message=$_.Exception.Message;StackTrace=$_.ScriptStackTrace})
  $failure=$_.Exception.Message
}finally{
  foreach($process in $ownedProcesses){try{$process.Refresh();if(-not $process.HasExited){Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue};$process.Dispose()}catch{}}
  if($portableTemp -and (Test-Path -LiteralPath $portableTemp)){
    $tempRoot=[IO.Path]::GetFullPath($env:TEMP).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    $resolvedTemp=[IO.Path]::GetFullPath($portableTemp)
    if(-not $resolvedTemp.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase)){throw "Refusing recursive cleanup outside the runner temporary directory: $resolvedTemp"}
    Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
  }
  $results=[pscustomobject]@{Application='Eye Break Reminder';Version=$expectedVersion;SourceCommit=$env:GITHUB_SHA;OSCaption=$(if($os){$os.Caption}else{$null});OSArchitecture=$(if($osArch){$osArch}else{$null});ProcessArchitecture=$(if($processArch){$processArch}else{$null});CandidateExecutableSHA256=$(if(Test-Path -LiteralPath $StandaloneExecutable){(Get-FileHash -LiteralPath $StandaloneExecutable -Algorithm SHA256).Hash.ToLowerInvariant()}else{$null});CandidateInstallerSHA256=$(if(Test-Path -LiteralPath $InstallerPath){(Get-FileHash -LiteralPath $InstallerPath -Algorithm SHA256).Hash.ToLowerInvariant()}else{$null});Pass=@($events|Where-Object Status -eq 'PASS').Count;Fail=@($events|Where-Object Status -eq 'FAIL').Count;NotTested=@($events|Where-Object Status -eq 'NOT TESTED').Count;NotApplicable=@($events|Where-Object Status -eq 'NOT APPLICABLE').Count;Events=$events.ToArray();CompletedUtc=[DateTime]::UtcNow.ToString('o')}
  $results|ConvertTo-Json -Depth 9|Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'windows-arm64-emulation-results.json') -Encoding UTF8
}
if($failure){throw "Windows 11 ARM64 acceptance failed: $failure"}
Write-Output "Windows 11 ARM64 acceptance: PASS=$($results.Pass) FAIL=$($results.Fail) NOT TESTED=$($results.NotTested) NOT APPLICABLE=$($results.NotApplicable)"
