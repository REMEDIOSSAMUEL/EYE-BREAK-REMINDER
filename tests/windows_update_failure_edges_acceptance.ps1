param(
  [Parameter(Mandatory=$true)][string]$CandidateExecutable,
  [Parameter(Mandatory=$true)][string]$SuccessorInstaller,
  [Parameter(Mandatory=$true)][string]$SuccessorExecutable,
  [string]$EvidencePath = 'build/v1.4.0-updater-evidence/failure-edges.json'
)

$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_OS -ne 'Windows' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
  throw 'This failure-edge acceptance script is restricted to a disposable GitHub Actions Windows runner.'
}
if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne [Runtime.InteropServices.Architecture]::X64) {
  throw 'The coordinator failure-edge tests require an x64 Windows runner.'
}
if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { throw 'RUNNER_TEMP is unavailable; refusing to create disposable test state.' }

$runnerTemp = [IO.Path]::GetFullPath($env:RUNNER_TEMP)
$testRoot = [IO.Path]::GetFullPath((Join-Path $runnerTemp 'EyeBreakReminder-v140-failure-edges'))
$runnerPrefix = $runnerTemp.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if (-not $testRoot.StartsWith($runnerPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Resolved test directory escaped RUNNER_TEMP.' }
if (Test-Path -LiteralPath $testRoot) { throw "Refusing to reuse an existing failure-edge test directory: $testRoot" }

$candidate = [IO.Path]::GetFullPath($CandidateExecutable)
$successorInstaller = [IO.Path]::GetFullPath($SuccessorInstaller)
$successorExecutable = [IO.Path]::GetFullPath($SuccessorExecutable)
foreach ($file in @($candidate, $successorInstaller, $successorExecutable)) {
  if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Required test executable is missing: $file" }
}
if ((Get-Item -LiteralPath $candidate).VersionInfo.ProductVersion -notmatch '^1\.4\.0(\.0)?$') { throw 'The candidate executable is not v1.4.0.' }
if ((Get-Item -LiteralPath $successorExecutable).VersionInfo.ProductVersion -notmatch '^1\.4\.1(\.0)?$') { throw 'The controlled successor executable is not v1.4.1.' }
if ((Get-Item -LiteralPath $successorInstaller).VersionInfo.ProductVersion -notmatch '^1\.4\.1(\.0)?$') { throw 'The controlled successor installer is not v1.4.1.' }

$dataRoot = [IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'EyeBreakReminder'))
$expectedLocalAppData = [IO.Path]::GetFullPath($env:LOCALAPPDATA)
if (-not $dataRoot.StartsWith($expectedLocalAppData.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'The app data path is not within this runner user profile.' }
if (Test-Path -LiteralPath $dataRoot) { throw "Refusing to touch pre-existing app data on the runner: $dataRoot" }

$appKeyPath = 'HKCU:\Software\EyeBreakReminder'
$uninstallKeyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder'
$runKeyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runOnceKeyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
if (Test-Path -LiteralPath $appKeyPath) { throw 'Refusing to replace an existing Eye Break Reminder install registration.' }
if (Test-Path -LiteralPath $uninstallKeyPath) { throw 'Refusing to replace an existing Eye Break Reminder uninstall registration.' }
if ((Get-ItemProperty -LiteralPath $runKeyPath -Name EyeBreakReminder -ErrorAction SilentlyContinue) -or
    (Get-ItemProperty -LiteralPath $runOnceKeyPath -Name '!EyeBreakReminderUpdateRecovery' -ErrorAction SilentlyContinue)) {
  throw 'Refusing to replace an existing Eye Break Reminder startup or recovery registration.'
}

$evidencePath = [IO.Path]::GetFullPath($EvidencePath)
$allowedEvidence = [IO.Path]::GetFullPath((Join-Path (Get-Location) 'build/v1.4.0-updater-evidence'))
if (-not $evidencePath.StartsWith($allowedEvidence.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
  throw "Evidence must be written under $allowedEvidence."
}

$script:events = [Collections.Generic.List[object]]::new()
$script:assertions = 0
$script:activeApp = $null
$script:activeCoordinator = $null
$script:activeOwner = $null
$script:lockHandle = [IntPtr]::Zero
$script:suspendedThread = [IntPtr]::Zero
$script:oldSetupAcl = $null
$script:deniedSetup = $null

$native = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class EBR_FAILURE_EDGE_NATIVE {
  public delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr data);
  [DllImport("user32.dll", SetLastError=true)] static extern bool EnumWindows(EnumWindowsProc callback, IntPtr data);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern int GetClassNameW(IntPtr hwnd, StringBuilder text, int count);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern int GetWindowTextW(IntPtr hwnd, StringBuilder text, int count);
  [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr GetDlgItem(IntPtr hwnd, int id);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll", SetLastError=true)] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern uint RegisterWindowMessageW(string name);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool PostMessageW(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll", SetLastError=true)] static extern bool PostThreadMessageW(uint threadId, uint message, IntPtr wParam, IntPtr lParam);
  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenThread(uint access, bool inherit, uint threadId);
  [DllImport("kernel32.dll", SetLastError=true)] static extern uint SuspendThread(IntPtr thread);
  [DllImport("kernel32.dll", SetLastError=true)] static extern uint ResumeThread(IntPtr thread);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr handle);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateFileW(string path, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
  const uint THREAD_SUSPEND_RESUME=0x0002, GENERIC_READ=0x80000000, FILE_SHARE_READ=1, OPEN_EXISTING=3, FILE_ATTRIBUTE_NORMAL=0x80;
  public static IntPtr FindWindowByClassAndPid(string className, int processId) {
    IntPtr found=IntPtr.Zero;
    EnumWindowsProc callback=delegate(IntPtr hwnd, IntPtr ignored) {
      uint pid=0; GetWindowThreadProcessId(hwnd,out pid);
      if ((int)pid==processId && IsWindowVisible(hwnd)) {
        StringBuilder name=new StringBuilder(256); GetClassNameW(hwnd,name,name.Capacity);
        if (String.Equals(name.ToString(),className,StringComparison.Ordinal)) { found=hwnd; return false; }
      }
      return true;
    };
    EnumWindows(callback,IntPtr.Zero); GC.KeepAlive(callback); return found;
  }
  public static string WindowText(IntPtr hwnd) { StringBuilder text=new StringBuilder(2048); GetWindowTextW(hwnd,text,text.Capacity); return text.ToString(); }
  public static string CoordinatorStatus(IntPtr hwnd) { IntPtr status=GetDlgItem(hwnd,1); return status==IntPtr.Zero ? "" : WindowText(status); }
  public static bool CloseWindow(IntPtr hwnd) { return PostMessageW(hwnd,0x0010,IntPtr.Zero,IntPtr.Zero); }
  public static bool ExitApp(IntPtr hwnd) { uint message=RegisterWindowMessageW("EyeBreakReminder.Exit.Native.1"); return message!=0 && PostMessageW(hwnd,message,IntPtr.Zero,IntPtr.Zero); }
  public static IntPtr SuspendWindowThread(IntPtr hwnd) {
    uint processId=0; uint threadId=GetWindowThreadProcessId(hwnd,out processId); if(threadId==0)return IntPtr.Zero;
    IntPtr thread=OpenThread(THREAD_SUSPEND_RESUME,false,threadId); if(thread==IntPtr.Zero)return IntPtr.Zero;
    if(SuspendThread(thread)==0xffffffff){CloseHandle(thread);return IntPtr.Zero;} return thread;
  }
  public static bool ResumeOwnedThread(IntPtr thread) { if(thread==IntPtr.Zero)return true; bool ok=ResumeThread(thread)!=0xffffffff; CloseHandle(thread); return ok; }
  public static IntPtr LockFileAgainstWriteAndDelete(string path) { return CreateFileW(path,GENERIC_READ,FILE_SHARE_READ,IntPtr.Zero,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,IntPtr.Zero); }
  public static bool CloseOwnedFile(IntPtr handle) { return handle==IntPtr.Zero || CloseHandle(handle); }
}
'@
Add-Type -TypeDefinition $native -ErrorAction Stop

function Add-Assertion([bool]$Passed, [string]$Name, $Evidence=$null) {
  $status = if ($Passed) { 'PASS' } else { 'FAIL' }
  if ($Passed) { $script:assertions++ }
  $script:events.Add([pscustomobject]@{Name=$Name;Status=$status;Evidence=$Evidence;Utc=[DateTime]::UtcNow.ToString('o')})
  if (-not $Passed) { throw "Failure-edge acceptance assertion failed: $Name" }
}

function Get-Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Get-AppVersion([string]$Path) { (Get-Item -LiteralPath $Path).VersionInfo.ProductVersion }
function Quote-Argument([string]$Value) { '"' + $Value.Replace('"','\"') + '"' }

function Set-DisposableRegistration([string]$InstallDirectory) {
  New-Item -Force -Path $appKeyPath | Out-Null
  New-Item -Force -Path $uninstallKeyPath | Out-Null
  New-ItemProperty -LiteralPath $appKeyPath -Name InstallDir -PropertyType String -Value $InstallDirectory -Force | Out-Null
  New-ItemProperty -LiteralPath $uninstallKeyPath -Name DisplayVersion -PropertyType String -Value '1.4.0' -Force | Out-Null
}

function Write-Profile() {
  [void][IO.Directory]::CreateDirectory($dataRoot)
  $settings = @('workMinutes=37','breakSeconds=33','volume=32','theme=2','alarm=0','repeat=1','notifications=0','snooze=0','autoStart=0','startup=0','history=1','breakModeColors=1','customWorkAccent=1','workAccentColor=3900150','customBreakAccent=1','breakAccentColor=16746496','autoCheckUpdates=0','autoDownloadUpdates=0','updateLastCheck=0','restore=1','schedule=1','scheduleMonday=1','scheduleMonday1=09001700') -join "`n"
  [IO.File]::WriteAllText((Join-Path $dataRoot 'settings.ini'),$settings+"`n",[Text.UTF8Encoding]::new($false))
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  [IO.File]::WriteAllText((Join-Path $dataRoot 'history.dat'),"$($now-120) 1 20`n",[Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText((Join-Path $dataRoot 'unrelated-sentinel.txt'),'failure-edge unrelated data',[Text.UTF8Encoding]::new($false))
}

function Get-ProfileHashes() {
  $map = [ordered]@{}
  foreach ($name in @('settings.ini','history.dat','unrelated-sentinel.txt')) { $path=Join-Path $dataRoot $name; $map[$name]=Get-Hash $path }
  return $map
}

function Start-OwnedSleep([int]$Seconds=4) {
  $exe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
  if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'Windows PowerShell test helper was not found on the hosted runner.' }
  Start-Process -FilePath $exe -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-WindowStyle','Hidden','-Command',"Start-Sleep -Seconds $Seconds") -WindowStyle Hidden -PassThru
}

function New-Transaction([string]$Scenario, [string]$InstallDirectory, [int]$OwnerPid) {
  Set-DisposableRegistration $InstallDirectory
  $target = Join-Path $InstallDirectory 'EyeBreakReminder.exe'
  [void][IO.Directory]::CreateDirectory($InstallDirectory)
  if (-not (Test-Path -LiteralPath $target)) { Copy-Item -LiteralPath $candidate -Destination $target }
  if ((Get-Hash $target) -cne (Get-Hash $candidate)) { throw "The disposable $Scenario target does not match the authoritative candidate executable." }
  if (-not (Test-Path -LiteralPath (Join-Path $dataRoot 'settings.ini'))) { Write-Profile }

  $stage = Join-Path (Join-Path $dataRoot 'updates') ([guid]::NewGuid().ToString('D'))
  [void][IO.Directory]::CreateDirectory($stage)
  Copy-Item -LiteralPath $candidate -Destination (Join-Path $stage 'coordinator.exe')
  Copy-Item -LiteralPath $successorInstaller -Destination (Join-Path $stage 'EyeBreakReminder-Setup-x64.exe')
  $nonce = [guid]::NewGuid().ToString('D')
  $setup = Join-Path $stage 'EyeBreakReminder-Setup-x64.exe'
  $values = [ordered]@{
    staging=$stage; artifact=$setup; target=$target; data=$dataRoot
    version='1.4.1'; previous='1.4.0'; nonce=$nonce
    kind='installed'; name='EyeBreakReminder-Setup-x64.exe'
    sha256=(Get-Hash $setup); applicationSha256=(Get-Hash $successorExecutable)
    previousSha256=(Get-Hash $target); size=(Get-Item -LiteralPath $setup).Length
    backupMask=0; ownedFileMask=0; pid=$OwnerPid; clean=0; deleteHistory=0
    dark=0; forcedColors=0; previousStartup=0
    backupSha2560=''; backupSha2561=''; backupSha2562=''
    ownedFileSha2560=''; ownedFileSha2561=''; ownedFileSha2562=''; ownedFileSha2563=''
  }
  $transaction = Join-Path $stage 'transaction.ini'
  $text = ($values.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key,$_.Value }) -join "`n"
  [IO.File]::WriteAllText($transaction,$text+"`n",[Text.UTF8Encoding]::new($false))
  return [pscustomobject]@{Scenario=$Scenario;InstallDirectory=$InstallDirectory;Target=$target;Stage=$stage;Transaction=$transaction;Setup=$setup;Nonce=$nonce}
}

function Get-StatusUntil([Diagnostics.Process]$Process, [string]$Substring, [int]$TimeoutSeconds) {
  $watch=[Diagnostics.Stopwatch]::StartNew()
  while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds -and -not $Process.HasExited) {
    $hwnd=[EBR_FAILURE_EDGE_NATIVE]::FindWindowByClassAndPid('EyeBreakReminder.UpdateCoordinator',$Process.Id)
    if ($hwnd -ne [IntPtr]::Zero) {
      $status=[EBR_FAILURE_EDGE_NATIVE]::CoordinatorStatus($hwnd)
      if ($status.Contains($Substring)) { return [pscustomobject]@{Hwnd=$hwnd;Status=$status} }
    }
    Start-Sleep -Milliseconds 150
    $Process.Refresh()
  }
  throw "Timed out waiting for coordinator message '$Substring'; processExit=$($Process.HasExited)."
}

function Start-Coordinator($Transaction) {
  $coordinator = Join-Path $Transaction.Stage 'coordinator.exe'
  $process = Start-Process -FilePath $coordinator -ArgumentList @('--update-coordinator',(Quote-Argument $Transaction.Transaction)) -WorkingDirectory $Transaction.Stage -PassThru
  $script:activeCoordinator=$process
  return $process
}

function Close-Coordinator([Diagnostics.Process]$Process, [IntPtr]$Window) {
  if ($Window -ne [IntPtr]::Zero) { [void][EBR_FAILURE_EDGE_NATIVE]::CloseWindow($Window) }
  if (-not $Process.WaitForExit(20000)) { throw "Coordinator $($Process.Id) did not close after its completed error was acknowledged." }
  $Process.Refresh()
  if ($Process.ExitCode -ne 1) { throw "Coordinator returned unexpected failure exit code $($Process.ExitCode)." }
  $script:activeCoordinator=$null
}

function Start-DisposableApp([string]$Executable) {
  $process=Start-Process -FilePath $Executable -WorkingDirectory ([IO.Path]::GetDirectoryName($Executable)) -PassThru
  $script:activeApp=$process
  $watch=[Diagnostics.Stopwatch]::StartNew()
  while ($watch.Elapsed.TotalSeconds -lt 30 -and -not $process.HasExited) {
    $process.Refresh()
    $hwnd=[EBR_FAILURE_EDGE_NATIVE]::FindWindowByClassAndPid('EyeBreakReminder.Native',$process.Id)
    if ($hwnd -ne [IntPtr]::Zero) {
      $path=$process.Path
      if ([IO.Path]::GetFullPath($path) -ine [IO.Path]::GetFullPath($Executable)) { throw "Test application process identity differs from the disposable target: $path" }
      return [pscustomobject]@{Process=$process;Hwnd=$hwnd}
    }
    Start-Sleep -Milliseconds 100
  }
  throw 'The disposable candidate application did not create its native main window.'
}

function Find-RunningDisposableApp([string]$Executable, [int]$TimeoutSeconds=15) {
  $expected=[IO.Path]::GetFullPath($Executable)
  $watch=[Diagnostics.Stopwatch]::StartNew()
  while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
    foreach ($process in @(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($Executable)) -ErrorAction SilentlyContinue)) {
      try {
        $process.Refresh()
        if ($process.HasExited -or [string]::IsNullOrWhiteSpace($process.Path) -or [IO.Path]::GetFullPath($process.Path) -ine $expected) { continue }
        $hwnd=[EBR_FAILURE_EDGE_NATIVE]::FindWindowByClassAndPid('EyeBreakReminder.Native',$process.Id)
        if ($hwnd -ne [IntPtr]::Zero) { $script:activeApp=$process; return [pscustomobject]@{Process=$process;Hwnd=$hwnd} }
      } catch {}
    }
    Start-Sleep -Milliseconds 100
  }
  throw "The coordinator did not relaunch the previous application from '$expected'."
}

function Close-DisposableApp($App) {
  if ($null -eq $App) { return }
  if (-not $App.Process.HasExited) {
    [void][EBR_FAILURE_EDGE_NATIVE]::ExitApp($App.Hwnd)
    if (-not $App.Process.WaitForExit(15000)) { throw "Disposable app process $($App.Process.Id) did not exit through its native exit message." }
  }
  $script:activeApp=$null
}

function Start-Recovery($Transaction) {
  $coordinator=Join-Path $Transaction.Stage 'coordinator.exe'
  $args=@('--update-recover',(Quote-Argument $Transaction.Transaction))
  $process=Start-Process -FilePath $coordinator -ArgumentList $args -WorkingDirectory $Transaction.Stage -PassThru
  if (-not $process.WaitForExit(90000)) { throw 'Recovery helper exceeded its 90-second hosted acceptance bound.' }
  $process.Refresh()
  if ($process.ExitCode -ne 0) { throw "Recovery helper returned exit code $($process.ExitCode)." }
  return $process
}

function Invoke-OwnerRefusesExitTest() {
  $install=Join-Path $testRoot 'owner-refuses-exit\install'
  $transaction=$null; $app=$null; $suspended=$false; $coordinatorWindow=[IntPtr]::Zero
  try {
    $transaction=New-Transaction 'owner-refuses-exit' $install 0
    $app=Start-DisposableApp $transaction.Target
    $profileBefore=Get-ProfileHashes
    $suspender=[EBR_FAILURE_EDGE_NATIVE]::SuspendWindowThread($app.Hwnd)
    if ($suspender -eq [IntPtr]::Zero) { throw 'Could not suspend the disposable candidate app UI thread for the refusal-to-exit fault injection.' }
    $script:suspendedThread=$suspender; $suspended=$true
    $ini=[IO.File]::ReadAllText($transaction.Transaction).Replace('pid=0',"pid=$($app.Process.Id)")
    [IO.File]::WriteAllText($transaction.Transaction,$ini,[Text.UTF8Encoding]::new($false))
    $coordinator=Start-Coordinator $transaction
    $status=Get-StatusUntil $coordinator 'did not close within one minute' 90
    $coordinatorWindow=$status.Hwnd
    Add-Assertion ($status.Status.Contains('No files were changed')) 'FAIL-012: unresponsive real candidate process is rejected without installation' ([pscustomobject]@{Message=$status.Status;OwnerPid=$app.Process.Id;OwnerExecutable=$app.Process.Path;WaitMilliseconds=60000})
    Close-Coordinator $coordinator $coordinatorWindow
    $coordinatorWindow=[IntPtr]::Zero
    $targetHash=Get-Hash $transaction.Target
    Add-Assertion ($targetHash -ceq (Get-Hash $candidate) -and (Get-AppVersion $transaction.Target) -match '^1\.4\.0(\.0)?$') 'FAIL-012: installed executable remains byte-identical v1.4.0' ([pscustomobject]@{SHA256=$targetHash;ProductVersion=(Get-AppVersion $transaction.Target)})
    $profileAfter=Get-ProfileHashes
    foreach ($name in @('settings.ini','history.dat','unrelated-sentinel.txt')) { Add-Assertion ($profileAfter[$name] -ceq $profileBefore[$name]) "FAIL-012: $name is unchanged byte-for-byte" @{Before=$profileBefore[$name];After=$profileAfter[$name]} }
    $uninstall=Get-ItemProperty -LiteralPath $uninstallKeyPath -Name DisplayVersion -ErrorAction Stop
    Add-Assertion ($uninstall.DisplayVersion -ceq '1.4.0') 'FAIL-012: Installed Apps registration remains on v1.4.0'
    return [pscustomobject]@{Status='PASS';Scenario='FAIL-012';Assertions=6;Message=$status.Status;OwnerProcess='Exact v1.4.0 candidate; UI thread suspended only in this disposable runner test process';TargetSHA256=$targetHash;SettingsHistorySentinelUnchanged=$true;FilesChanged=$false}
  } finally {
    if ($suspended -and $script:suspendedThread -ne [IntPtr]::Zero) { [void][EBR_FAILURE_EDGE_NATIVE]::ResumeOwnedThread($script:suspendedThread); $script:suspendedThread=[IntPtr]::Zero }
    if ($null -ne $app) { try { Close-DisposableApp $app } catch { Write-Warning $_ } }
    if ($null -ne $transaction -and (Test-Path -LiteralPath $transaction.Stage)) { Remove-Item -LiteralPath $transaction.Stage -Recurse -Force -ErrorAction SilentlyContinue }
  }
}

function Invoke-InstallerLaunchDeniedTest() {
  $install=Join-Path $testRoot 'installer-launch-denied\install'
  $transaction=$null; $coordinatorWindow=[IntPtr]::Zero; $app=$null; $setupAclRestored=$true
  try {
    $owner=Start-OwnedSleep 3; $script:activeOwner=$owner
    $transaction=New-Transaction 'installer-launch-denied' $install $owner.Id
    $script:deniedSetup=$transaction.Setup
    $script:oldSetupAcl=Get-Acl -LiteralPath $transaction.Setup
    $originalSddl=$script:oldSetupAcl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All)
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent().User
    $deny=[Security.AccessControl.FileSystemAccessRule]::new($identity,[Security.AccessControl.FileSystemRights]::ExecuteFile,[Security.AccessControl.AccessControlType]::Deny)
    $deniedAcl=Get-Acl -LiteralPath $transaction.Setup; $deniedAcl.SetAccessRule($deny); Set-Acl -LiteralPath $transaction.Setup -AclObject $deniedAcl
    $script:oldSetupAcl=$originalSddl
    $readHash=Get-Hash $transaction.Setup
    $effectiveAcl=Get-Acl -LiteralPath $transaction.Setup
    $hasExecuteDeny=@($effectiveAcl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]) | Where-Object { $_.IdentityReference.Value -ceq $identity.Value -and $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Deny -and ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::ExecuteFile) -ne 0 }).Count -gt 0
    Add-Assertion ($readHash -ceq (Get-Hash $successorInstaller) -and $hasExecuteDeny) 'FAIL-014 precondition: explicit ExecuteFile deny ACE is present while installer remains readable/hashable' ([pscustomobject]@{InstallerSHA256=$readHash;DeniedRight='ExecuteFile';RunnerSid=$identity.Value})
    $profileBefore=Get-ProfileHashes
    $coordinator=Start-Coordinator $transaction
    $status=Get-StatusUntil $coordinator 'previous version was restored and restarted' 120
    $coordinatorWindow=$status.Hwnd
    if (-not $owner.WaitForExit(10000)) { throw 'Installer-launch owner did not exit in the expected test interval.' }
    Add-Assertion ($status.Status.Contains('previous version was restored') -and $status.Status.Contains('with its data')) 'FAIL-014: coordinator reports verified prior-version recovery after CreateProcess denial' ([pscustomobject]@{Message=$status.Status})
    $installedHash=Get-Hash $transaction.Target
    Add-Assertion ($installedHash -ceq (Get-Hash $candidate) -and (Get-AppVersion $transaction.Target) -match '^1\.4\.0(\.0)?$') 'FAIL-014: application remains the original v1.4.0 executable' ([pscustomobject]@{SHA256=$installedHash;ProductVersion=(Get-AppVersion $transaction.Target)})
    Add-Assertion ((Get-ItemProperty -LiteralPath $uninstallKeyPath -Name DisplayVersion -ErrorAction Stop).DisplayVersion -ceq '1.4.0') 'FAIL-014: Installed Apps version is restored to v1.4.0'
    $app=Find-RunningDisposableApp $transaction.Target
    Add-Assertion ($null -ne $app -and -not $app.Process.HasExited -and [IO.Path]::GetFullPath($app.Process.Path) -ieq [IO.Path]::GetFullPath($transaction.Target)) 'FAIL-014: restored v1.4.0 app relaunches from the registered install path'
    Close-DisposableApp $app; $app=$null
    $profileAfter=Get-ProfileHashes
    foreach ($name in @('settings.ini','history.dat','unrelated-sentinel.txt')) { Add-Assertion ($profileAfter[$name] -ceq $profileBefore[$name]) "FAIL-014: $name survives failed installer launch and rollback byte-for-byte" @{Before=$profileBefore[$name];After=$profileAfter[$name]} }
    Add-Assertion (-not (Get-ItemProperty -LiteralPath $runOnceKeyPath -Name '!EyeBreakReminderUpdateRecovery' -ErrorAction SilentlyContinue)) 'FAIL-014: successful rollback clears the recovery RunOnce entry'
    Close-Coordinator $coordinator $coordinatorWindow; $coordinatorWindow=[IntPtr]::Zero
    return [pscustomobject]@{Status='PASS';Scenario='FAIL-014';Assertions=9;Message=$status.Status;InstallerLaunchPreventedBy='NTFS ExecuteFile deny ACE on the disposable staged setup';OriginalExecutableSHA256=$installedHash;SettingsHistorySentinelUnchanged=$true;PreviousVersionRelaunched=$true}
  } finally {
    if ($script:oldSetupAcl -is [string] -and $script:deniedSetup -and (Test-Path -LiteralPath $script:deniedSetup)) {
      $restoreAcl=Get-Acl -LiteralPath $script:deniedSetup; $restoreAcl.SetSecurityDescriptorSddlForm($script:oldSetupAcl,[Security.AccessControl.AccessControlSections]::All); Set-Acl -LiteralPath $script:deniedSetup -AclObject $restoreAcl; $script:oldSetupAcl=$null; $script:deniedSetup=$null
    }
    if ($null -ne $app) { try { Close-DisposableApp $app } catch { Write-Warning $_ } }
    if ($null -ne $owner -and -not $owner.HasExited) { $owner.WaitForExit(10000) | Out-Null; $script:activeOwner=$null }
    if ($null -ne $transaction -and (Test-Path -LiteralPath $transaction.Stage)) { Remove-Item -LiteralPath $transaction.Stage -Recurse -Force -ErrorAction SilentlyContinue }
  }
}

function Invoke-LockedExecutableRecoveryTest() {
  $install=Join-Path $testRoot 'locked-executable\install'
  $transaction=$null; $coordinatorWindow=[IntPtr]::Zero; $recoveryApp=$null; $recoveryRequired=$false
  try {
    $owner=Start-OwnedSleep 5; $script:activeOwner=$owner
    $transaction=New-Transaction 'locked-executable' $install $owner.Id
    $script:lockHandle=[EBR_FAILURE_EDGE_NATIVE]::LockFileAgainstWriteAndDelete($transaction.Target)
    if ($script:lockHandle -eq [IntPtr]::Zero -or $script:lockHandle -eq [IntPtr]::new(-1)) { throw 'Could not open the disposable installed executable with a deny-write/delete file-sharing lock.' }
    $profileBefore=Get-ProfileHashes
    $coordinator=Start-Coordinator $transaction
    $status=Get-StatusUntil $coordinator 'could not finish' 150
    $coordinatorWindow=$status.Hwnd
    if (-not $owner.WaitForExit(10000)) { throw 'Locked-file owner did not exit in the expected test interval.' }
    $recoveryRequired=$true
    Add-Assertion ($status.Status.Contains('previous executable and data backup remain in the updates folder')) 'INST-011: installer replacement failure retains explicit recovery data while the EXE is locked' ([pscustomobject]@{Message=$status.Status})
    $stillOriginal=(Get-Hash $transaction.Target) -ceq (Get-Hash $candidate) -and (Get-AppVersion $transaction.Target) -match '^1\.4\.0(\.0)?$'
    Add-Assertion $stillOriginal 'INST-011: locked installed executable is not truncated or replaced' ([pscustomobject]@{SHA256=(Get-Hash $transaction.Target);ProductVersion=(Get-AppVersion $transaction.Target)})
    $registeredVersion=(Get-ItemProperty -LiteralPath $uninstallKeyPath -Name DisplayVersion -ErrorAction Stop).DisplayVersion
    $recoveryCommand=(Get-ItemProperty -LiteralPath $runOnceKeyPath -Name '!EyeBreakReminderUpdateRecovery' -ErrorAction Stop).'!EyeBreakReminderUpdateRecovery'
    $registrationRecoverable=($registeredVersion -ceq '1.4.0') -or ($registeredVersion -ceq '1.4.1' -and $recoveryCommand -like '*--update-recover*')
    Add-Assertion $registrationRecoverable 'INST-011: registration is previous version or explicitly pending the verified rollback' ([pscustomobject]@{DisplayVersion=$registeredVersion;RecoveryCommand=$recoveryCommand})
    Add-Assertion ($recoveryCommand -like '*--update-recover*') 'INST-011: interrupted automatic rollback retains an actionable recovery registration'
    Close-Coordinator $coordinator $coordinatorWindow; $coordinatorWindow=[IntPtr]::Zero
    [void][EBR_FAILURE_EDGE_NATIVE]::CloseOwnedFile($script:lockHandle); $script:lockHandle=[IntPtr]::Zero
    $recovery=Start-Recovery $transaction
    $recoveryRequired=$false
    $recoveryApp=Find-RunningDisposableApp $transaction.Target
    Add-Assertion ($recovery.ExitCode -eq 0 -and $recoveryApp.Process -and -not $recoveryApp.Process.HasExited) 'INST-011: after releasing the test lock, explicit recovery starts the previous app successfully' ([pscustomobject]@{RecoveryExitCode=$recovery.ExitCode;ProcessId=$recoveryApp.Process.Id;Path=$recoveryApp.Process.Path})
    Add-Assertion ((Get-Hash $transaction.Target) -ceq (Get-Hash $candidate) -and (Get-AppVersion $transaction.Target) -match '^1\.4\.0(\.0)?$') 'INST-011: recovered installation is byte-identical v1.4.0'
    Add-Assertion ((Get-ItemProperty -LiteralPath $uninstallKeyPath -Name DisplayVersion -ErrorAction Stop).DisplayVersion -ceq '1.4.0') 'INST-011: recovered Installed Apps registration is v1.4.0'
    $profileAfter=Get-ProfileHashes
    foreach ($name in @('settings.ini','history.dat','unrelated-sentinel.txt')) { Add-Assertion ($profileAfter[$name] -ceq $profileBefore[$name]) "INST-011: $name survives failed replacement and recovery byte-for-byte" @{Before=$profileBefore[$name];After=$profileAfter[$name]} }
    Add-Assertion (-not (Get-ItemProperty -LiteralPath $runOnceKeyPath -Name '!EyeBreakReminderUpdateRecovery' -ErrorAction SilentlyContinue)) 'INST-011: recovery clears its RunOnce entry after application confirmation'
    Close-DisposableApp $recoveryApp; $recoveryApp=$null
    $watch=[Diagnostics.Stopwatch]::StartNew(); while ((Test-Path -LiteralPath $transaction.Stage) -and $watch.Elapsed.TotalSeconds -lt 20) { Start-Sleep -Milliseconds 200 }
    Add-Assertion (-not (Test-Path -LiteralPath $transaction.Stage)) 'INST-011: successful recovery removes its owned staging directory after the app exits'
    return [pscustomobject]@{Status='PASS';Scenario='INST-011';Assertions=12;Message=$status.Status;Lock='Real Windows handle denies write and delete sharing on the installed executable';InitialVersionIntact=$true;RecoveryExitCode=$recovery.ExitCode;RecoveredApplicationRelaunched=$true;SettingsHistorySentinelUnchanged=$true;StageCleaned=$true}
  } finally {
    if ($script:lockHandle -ne [IntPtr]::Zero -and $script:lockHandle -ne [IntPtr]::new(-1)) { [void][EBR_FAILURE_EDGE_NATIVE]::CloseOwnedFile($script:lockHandle); $script:lockHandle=[IntPtr]::Zero }
    if ($null -ne $recoveryApp) { try { Close-DisposableApp $recoveryApp } catch { Write-Warning $_ } }
    if ($null -ne $owner -and -not $owner.HasExited) { $owner.WaitForExit(10000) | Out-Null; $script:activeOwner=$null }
    if ($null -ne $transaction -and (Test-Path -LiteralPath $transaction.Stage) -and -not $recoveryRequired) { Remove-Item -LiteralPath $transaction.Stage -Recurse -Force -ErrorAction SilentlyContinue }
  }
}

$runStarted=[DateTime]::UtcNow
$runFailure=$null
try {
  [void][IO.Directory]::CreateDirectory($testRoot)
  [void][IO.Directory]::CreateDirectory($dataRoot)
  $results = @(
    (Invoke-OwnerRefusesExitTest),
    (Invoke-InstallerLaunchDeniedTest),
    (Invoke-LockedExecutableRecoveryTest)
  )
  $summary=[pscustomobject]@{
    Application='Eye Break Reminder';Version='1.4.0';Status='PASS';Scenario='Coordinator launch/shutdown/locked-file failure edges'
    Assertions=$script:assertions;Results=$results;CandidateSHA256=(Get-Hash $candidate)
    SuccessorInstallerSHA256=(Get-Hash $successorInstaller);SuccessorExecutableSHA256=(Get-Hash $successorExecutable)
    HostScope='Disposable GitHub Actions Windows runner only';TestRoot=$testRoot;DataRoot=$dataRoot
    HostRebooted=$false;HostShutdown=$false;HostLocked=$false;HostSuspended=$false
    TestApplicationThreadSuspendedDuringFAIL012=$true;UtcStarted=$runStarted.ToString('o');UtcCompleted=[DateTime]::UtcNow.ToString('o')
  }
} catch {
  $runFailure=$_.Exception.ToString()
  $summary=[pscustomobject]@{Application='Eye Break Reminder';Version='1.4.0';Status='FAIL';Scenario='Coordinator launch/shutdown/locked-file failure edges';Assertions=$script:assertions;Failure=$_.Exception.ToString();Events=$script:events;HostScope='Disposable GitHub Actions Windows runner only';HostRebooted=$false;HostShutdown=$false;HostLocked=$false;HostSuspended=$false;UtcStarted=$runStarted.ToString('o');UtcCompleted=[DateTime]::UtcNow.ToString('o')}
} finally {
  if ($script:suspendedThread -ne [IntPtr]::Zero) { [void][EBR_FAILURE_EDGE_NATIVE]::ResumeOwnedThread($script:suspendedThread); $script:suspendedThread=[IntPtr]::Zero }
  if ($script:lockHandle -ne [IntPtr]::Zero -and $script:lockHandle -ne [IntPtr]::new(-1)) { [void][EBR_FAILURE_EDGE_NATIVE]::CloseOwnedFile($script:lockHandle); $script:lockHandle=[IntPtr]::Zero }
  if ($null -ne $script:activeApp -and -not $script:activeApp.HasExited) { try { $hwnd=[EBR_FAILURE_EDGE_NATIVE]::FindWindowByClassAndPid('EyeBreakReminder.Native',$script:activeApp.Id); if ($hwnd -ne [IntPtr]::Zero) { [void][EBR_FAILURE_EDGE_NATIVE]::ExitApp($hwnd) }; if (-not $script:activeApp.WaitForExit(7000) -and [IO.Path]::GetFullPath($script:activeApp.Path).StartsWith($testRoot,[StringComparison]::OrdinalIgnoreCase)) { Stop-Process -Id $script:activeApp.Id -Force -ErrorAction SilentlyContinue } } catch {} }
  if ($null -ne $script:activeOwner -and -not $script:activeOwner.HasExited) { try { if (-not $script:activeOwner.WaitForExit(5000)) { Stop-Process -Id $script:activeOwner.Id -Force -ErrorAction SilentlyContinue } } catch {} }
  if ($null -ne $script:activeCoordinator -and -not $script:activeCoordinator.HasExited) { try { $hwnd=[EBR_FAILURE_EDGE_NATIVE]::FindWindowByClassAndPid('EyeBreakReminder.UpdateCoordinator',$script:activeCoordinator.Id); if ($hwnd -ne [IntPtr]::Zero) { [void][EBR_FAILURE_EDGE_NATIVE]::CloseWindow($hwnd) }; $path=[IO.Path]::GetFullPath($script:activeCoordinator.Path); $ownedCoordinator=$path.StartsWith($testRoot,[StringComparison]::OrdinalIgnoreCase) -or $path.StartsWith($dataRoot.TrimEnd('\')+'\updates\',[StringComparison]::OrdinalIgnoreCase); if (-not $script:activeCoordinator.WaitForExit(7000) -and $ownedCoordinator) { Stop-Process -Id $script:activeCoordinator.Id -Force -ErrorAction SilentlyContinue } } catch {} }
  if ($script:oldSetupAcl -is [string] -and $script:deniedSetup -and (Test-Path -LiteralPath $script:deniedSetup)) { try { $acl=Get-Acl -LiteralPath $script:deniedSetup; $acl.SetSecurityDescriptorSddlForm($script:oldSetupAcl,[Security.AccessControl.AccessControlSections]::All); Set-Acl -LiteralPath $script:deniedSetup -AclObject $acl } catch { Write-Warning "Could not restore the staged test installer ACL: $_" } }
  $recovery=Get-ItemProperty -LiteralPath $runOnceKeyPath -Name '!EyeBreakReminderUpdateRecovery' -ErrorAction SilentlyContinue
  if ($recovery -and [string]$recovery.'!EyeBreakReminderUpdateRecovery' -like ('*'+$dataRoot+'\updates\*')) { Remove-ItemProperty -LiteralPath $runOnceKeyPath -Name '!EyeBreakReminderUpdateRecovery' -ErrorAction SilentlyContinue }
  if (Test-Path -LiteralPath $dataRoot) { Remove-Item -LiteralPath $dataRoot -Recurse -Force -ErrorAction SilentlyContinue }
  if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
  if (Test-Path -LiteralPath $appKeyPath) { Remove-Item -LiteralPath $appKeyPath -Recurse -Force -ErrorAction SilentlyContinue }
  if (Test-Path -LiteralPath $uninstallKeyPath) { Remove-Item -LiteralPath $uninstallKeyPath -Recurse -Force -ErrorAction SilentlyContinue }
}

[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($evidencePath))
$summary | Add-Member -NotePropertyName Events -NotePropertyValue @($script:events) -Force
$summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $evidencePath -Encoding utf8
Write-Host ($summary | ConvertTo-Json -Depth 10)
if ($runFailure) { throw "Failure-edge hosted acceptance failed: $runFailure" }
