param(
  [Parameter(Mandatory=$true)][string]$InstallerPath,
  [Parameter(Mandatory=$true)][string]$StandaloneExecutable,
  [Parameter(Mandatory=$true)][string]$PortableArchive,
  [Parameter(Mandatory=$true)][string]$EvidenceDirectory,
  [string]$CandidateSourceCommit
)
$ErrorActionPreference='Stop'
$InstallerPath=[IO.Path]::GetFullPath($InstallerPath)
$StandaloneExecutable=[IO.Path]::GetFullPath($StandaloneExecutable)
$PortableArchive=[IO.Path]::GetFullPath($PortableArchive)
$EvidenceDirectory=[IO.Path]::GetFullPath($EvidenceDirectory)
$CandidateSourceCommit=if([string]::IsNullOrWhiteSpace($CandidateSourceCommit)){$env:GITHUB_SHA}else{$CandidateSourceCommit}
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
$appDataPath=Join-Path $env:LOCALAPPDATA 'EyeBreakReminder'
$uninstallKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder'
$installExistedBefore=Test-Path -LiteralPath $installDirectory
$appDataExistedBefore=Test-Path -LiteralPath $appDataPath
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
  [DllImport("user32.dll", EntryPoint="GetForegroundWindow", SetLastError=true)] private static extern IntPtr GetForegroundWindowNative();
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
  public static IntPtr Foreground() { return GetForegroundWindowNative(); }
  public static int OwnerProcessId(IntPtr hwnd) { uint processId; GetWindowThreadProcessId(hwnd,out processId); return (int)processId; }
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
  public static IntPtr ChildById(IntPtr parent, int id) {
    foreach (var child in Children(parent)) { if (GetDlgCtrlID(child)==id) return child; }
    return IntPtr.Zero;
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
function Convert-CountdownToSeconds([string]$Text){
  $match=[regex]::Match($Text,'^(\d+):([0-5]\d)$')
  if(-not $match.Success){return -1}
  return ([int]$match.Groups[1].Value*60)+[int]$match.Groups[2].Value
}
function Invoke-X64EmulatedAppSmoke([string]$Path,[string]$Label,[string]$ScreenshotName){
  $process=Start-Process -FilePath $Path -WorkingDirectory (Split-Path -Parent $Path) -PassThru
  $script:ownedProcesses.Add($process)
  $timer=[Diagnostics.Stopwatch]::StartNew();$window=[IntPtr]::Zero
  while($timer.Elapsed.TotalSeconds -lt 20 -and $window -eq [IntPtr]::Zero){
    foreach($candidateWindow in [EBR_ARM64_ACCEPTANCE_Native]::WindowsForProcess($process.Id)){
      if([EBR_ARM64_ACCEPTANCE_Native]::ClassName($candidateWindow) -eq 'EyeBreakReminder.Native' -and [EBR_ARM64_ACCEPTANCE_Native]::Text($candidateWindow) -match '^Eye Break Reminder$'){$window=$candidateWindow;break}
    }
    if($window -eq [IntPtr]::Zero){$process.Refresh();if($process.HasExited){break};Start-Sleep -Milliseconds 100}
  }
  $process.Refresh()
  Require ($window -ne [IntPtr]::Zero -and -not $process.HasExited) "$Label x64 executable creates its application window under ARM64 emulation" ([pscustomobject]@{Pid=$process.Id;Exited=$process.HasExited;ExitCode=$(if($process.HasExited){$process.ExitCode}else{$null});Window=('0x{0:X}' -f $window.ToInt64())})
  $controls=@([EBR_ARM64_ACCEPTANCE_Native]::Children($window) | ForEach-Object {[pscustomobject]@{Handle=$_;Class=[EBR_ARM64_ACCEPTANCE_Native]::ClassName($_);Text=[EBR_ARM64_ACCEPTANCE_Native]::Text($_);ControlId=[EBR_ARM64_ACCEPTANCE_Native]::ControlId($_);Visible=[EBR_ARM64_ACCEPTANCE_Native]::Visible($_);Enabled=[EBR_ARM64_ACCEPTANCE_Native]::Enabled($_)}})
  $status=@($controls|Where-Object{$_.ControlId-eq41-and$_.Visible}|Select-Object -First 1)
  $countdown=@($controls|Where-Object{$_.ControlId-eq40-and$_.Visible}|Select-Object -First 1)
  Require ($status.Count-eq1-and$status[0].Text-match'^Running(?:\b|\s|—)') "$Label opens in Work mode" ([pscustomobject]@{Status=$(if($status.Count){$status[0].Text}else{$null})})
  $initialSeconds=if($countdown.Count){Convert-CountdownToSeconds $countdown[0].Text}else{-1}
  Require ($initialSeconds-ge0) "$Label displays a valid running countdown" ([pscustomobject]@{Countdown=$(if($countdown.Count){$countdown[0].Text}else{$null})})
  [void][EBR_ARM64_ACCEPTANCE_Native]::SetForegroundWindow($window)
  $countdownWatch=[Diagnostics.Stopwatch]::StartNew();$lastSeconds=$initialSeconds;$currentSeconds=$initialSeconds
  while($countdownWatch.Elapsed.TotalSeconds-lt12-and$currentSeconds-ge$initialSeconds){
    Start-Sleep -Milliseconds 250
    $countdownHandle=[EBR_ARM64_ACCEPTANCE_Native]::ChildById($window,40)
    if($countdownHandle-ne[IntPtr]::Zero){$currentSeconds=Convert-CountdownToSeconds ([EBR_ARM64_ACCEPTANCE_Native]::Text($countdownHandle))}
  }
  Require ($currentSeconds-lt$initialSeconds) "$Label Work countdown advances during x64 emulation" ([pscustomobject]@{InitialSeconds=$initialSeconds;CurrentSeconds=$currentSeconds;ElapsedMilliseconds=[int]$countdownWatch.Elapsed.TotalMilliseconds})
  $foreground=[EBR_ARM64_ACCEPTANCE_Native]::Foreground();$foregroundPid=[EBR_ARM64_ACCEPTANCE_Native]::OwnerProcessId($foreground);$foregroundProcess=Get-Process -Id $foregroundPid -ErrorAction SilentlyContinue
  if($foreground-eq$window){
    $desktopCapture=Save-DesktopScreenshot (Join-Path $EvidenceDirectory $ScreenshotName)
    Add-Event "$Label application window is foreground on the Windows desktop" 'PASS' ([pscustomobject]@{Screenshot=$desktopCapture;ForegroundWindowClass=[EBR_ARM64_ACCEPTANCE_Native]::ClassName($foreground)})
  }else{
    $desktopCapture=Save-DesktopScreenshot (Join-Path $EvidenceDirectory ($ScreenshotName -replace '\.png$','-foreground-obstructed.png'))
    Add-Event "$Label application desktop capture is obstructed by another foreground surface" 'NOT TESTED' ([pscustomobject]@{ForegroundWindowTitle=[EBR_ARM64_ACCEPTANCE_Native]::Text($foreground);ForegroundWindowClass=[EBR_ARM64_ACCEPTANCE_Native]::ClassName($foreground);ForegroundProcess=$(if($foregroundProcess){$foregroundProcess.ProcessName}else{$null});ApplicationWindow=('0x{0:X}' -f $window.ToInt64());DesktopCapture=$desktopCapture;Note='The app window and live countdown are verified through Win32 window/control data; the runner foreground surface prevents claiming an unobstructed on-screen screenshot.'})
  }
  $process.Refresh();Require (-not $process.HasExited) "$Label remains running after its countdown advances" ([pscustomobject]@{Pid=$process.Id})
  Stop-Process -Id $process.Id -Force -ErrorAction Stop
  Require ($process.WaitForExit(15000)) "$Label test-owned process exits during cleanup" ([pscustomobject]@{Pid=$process.Id})
  return [pscustomobject]@{Path=$Path;Pid=$process.Id;InitialCountdownSeconds=$initialSeconds;FinalCountdownSeconds=$currentSeconds;ForegroundProcess=$(if($foregroundProcess){$foregroundProcess.ProcessName}else{$null})}
}
try{
  $os=Get-CimInstance Win32_OperatingSystem
  $osArch=[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
  $processArch=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
  Require ($os.Caption -match 'Windows 11' -and $osArch -eq 'Arm64' -and $processArch -eq 'Arm64') 'Runner is genuine Windows 11 ARM64 with ARM64 PowerShell' ([pscustomobject]@{Caption=$os.Caption;Version=$os.Version;OSArchitecture=$osArch;ProcessArchitecture=$processArch})

  $exeFile=Get-Item -LiteralPath $StandaloneExecutable
  $setupFile=Get-Item -LiteralPath $InstallerPath
  Require ($exeFile.VersionInfo.ProductVersion -match '^1\.3\.0(\.0)?$' -and $setupFile.VersionInfo.ProductVersion -match '^1\.3\.0(\.0)?$') 'Candidate executable and installer are version 1.3.0' ([pscustomobject]@{Executable=$exeFile.VersionInfo.ProductVersion;Installer=$setupFile.VersionInfo.ProductVersion})
  Require (-not $appDataExistedBefore) 'ARM64 runner has no pre-existing Eye Break Reminder user data' ([pscustomobject]@{AppDataPath=$appDataPath;Existed=$appDataExistedBefore})

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
  Add-Event 'Windows 11 ARM64 runtime results are supplemental x64 emulation, not native Windows 11 x64 acceptance' 'PASS' 'The exact release payload is AMD64; all ARM64 results are labelled as emulation and do not close native x64 coverage.'
  Add-Event 'Native Windows 11 x64 acceptance is not established by this ARM64 runner' 'BLOCKED' 'This Windows 11 ARM64 runner is not native x64; no authorized disposable Windows 11 x64 VM is currently available.'
  $appSmoke=Invoke-X64EmulatedAppSmoke $StandaloneExecutable 'Standalone application' 'windows-11-arm64-standalone-x64-emulation.png'

  $portableTemp=Join-Path $env:TEMP ('ebr-arm64-portable-'+[guid]::NewGuid().ToString('N'))
  Expand-Archive -LiteralPath $PortableArchive -DestinationPath $portableTemp -Force
  $portableExecutable=Join-Path $portableTemp 'EyeBreakReminder.exe'
  Require (Test-Path -LiteralPath $portableExecutable -PathType Leaf) 'Portable archive contains its x64 application executable'
  $portableHash=(Get-FileHash -LiteralPath $portableExecutable -Algorithm SHA256).Hash.ToLowerInvariant()
  Require ($portableHash -ceq $exeHash) 'Portable executable is byte-identical to the standalone payload' ([pscustomobject]@{StandaloneSHA256=$exeHash;PortableSHA256=$portableHash})
  $portableSmoke=Invoke-X64EmulatedAppSmoke $portableExecutable 'Portable application' 'windows-11-arm64-portable-x64-emulation.png'
  Add-Event 'ARM64 results distinguish the installer native-AMD64 guard from x64 app emulation' 'PASS' ([pscustomobject]@{InstallerGuard=$installerGuard.GuardText;StandaloneWindow=$appSmoke.Path;PortableWindow=$portableSmoke.Path;InstallerRejectsARM64=$true;ApplicationLaunchesUnderX64Emulation=$true;NativeWindows11x64Covered=$false})
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
  if(-not $appDataExistedBefore -and (Test-Path -LiteralPath $appDataPath)){
    $localRoot=[IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    $resolvedAppData=[IO.Path]::GetFullPath($appDataPath)
    if(-not $resolvedAppData.StartsWith($localRoot,[StringComparison]::OrdinalIgnoreCase)){throw "Refusing user-data cleanup outside LOCALAPPDATA: $resolvedAppData"}
    Remove-Item -LiteralPath $resolvedAppData -Recurse -Force
    Add-Event 'Test-owned Eye Break Reminder app data is removed' 'PASS' ([pscustomobject]@{Path=$resolvedAppData;PreExisting=$false})
  }elseif($appDataExistedBefore){Add-Event 'Pre-existing Eye Break Reminder app data remains untouched' 'NOT TESTED' ([pscustomobject]@{Path=$appDataPath})}
  $results=[pscustomobject]@{Application='Eye Break Reminder';Version=$expectedVersion;SourceCommit=$CandidateSourceCommit;AcceptanceCommit=$env:GITHUB_SHA;OSCaption=$(if($os){$os.Caption}else{$null});OSArchitecture=$(if($osArch){$osArch}else{$null});ProcessArchitecture=$(if($processArch){$processArch}else{$null});CandidateExecutableSHA256=$(if(Test-Path -LiteralPath $StandaloneExecutable){(Get-FileHash -LiteralPath $StandaloneExecutable -Algorithm SHA256).Hash.ToLowerInvariant()}else{$null});CandidateInstallerSHA256=$(if(Test-Path -LiteralPath $InstallerPath){(Get-FileHash -LiteralPath $InstallerPath -Algorithm SHA256).Hash.ToLowerInvariant()}else{$null});Pass=@($events|Where-Object Status -eq 'PASS').Count;Fail=@($events|Where-Object Status -eq 'FAIL').Count;NotTested=@($events|Where-Object Status -eq 'NOT TESTED').Count;NotApplicable=@($events|Where-Object Status -eq 'NOT APPLICABLE').Count;Blocked=@($events|Where-Object Status -eq 'BLOCKED').Count;Events=$events.ToArray();CompletedUtc=[DateTime]::UtcNow.ToString('o')}
  $results|ConvertTo-Json -Depth 9|Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'windows-arm64-emulation-results.json') -Encoding UTF8
}
if($failure){throw "Windows 11 ARM64 acceptance failed: $failure"}
Write-Output "Windows 11 ARM64 acceptance: PASS=$($results.Pass) FAIL=$($results.Fail) NOT TESTED=$($results.NotTested) NOT APPLICABLE=$($results.NotApplicable) BLOCKED=$($results.Blocked)"
