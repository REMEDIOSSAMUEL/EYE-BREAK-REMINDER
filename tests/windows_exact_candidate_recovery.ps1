[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateSet('Interrupt','Recover')][string]$Phase,
  [ValidateSet('InstallerStart','BeforeRelaunch')][string]$FaultBoundary = 'BeforeRelaunch',
  [Parameter(Mandatory)][string]$CandidateDirectory,
  [Parameter(Mandatory)][string]$BaselineInstaller,
  [Parameter(Mandatory)][string]$BaselineApplication,
  [Parameter(Mandatory)][string]$EvidencePath,
  [switch]$ReinstallBeforeRecovery,
  [ValidateSet('None','MissingCoordinator','MissingBackup','CorruptBackup')][string]$RecoveryDamage = 'None'
)

$ErrorActionPreference = 'Stop'
if ($ReinstallBeforeRecovery -and ($Phase -cne 'Recover' -or $FaultBoundary -cne 'BeforeRelaunch')) {
  throw 'The pending-recovery reinstall probe requires the post-install interruption.'
}
if ($RecoveryDamage -cne 'None' -and ($Phase -cne 'Recover' -or $FaultBoundary -cne 'BeforeRelaunch' -or $ReinstallBeforeRecovery)) {
  throw 'The damaged-transaction probe requires a separate post-install interruption.'
}
if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or
    $env:GITHUB_SERVER_URL -cne 'https://github.com' -or
    $env:GITHUB_REPOSITORY -ine 'REMEDIOSSAMUEL/EYE-BREAK-REMINDER' -or
    $env:RUNNER_OS -cne 'Windows' -or $env:RUNNER_ARCH -cne 'X64' -or
    [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64' -or
    $env:GITHUB_RUN_ID -notmatch '^[0-9]+$' -or $env:GITHUB_RUN_ATTEMPT -notmatch '^[0-9]+$') {
  throw 'Use this harness only in the dedicated GitHub-hosted Windows x64 job.'
}

function Assert-Child([string]$Path, [string]$Root) {
  $full = [IO.Path]::GetFullPath($Path)
  $prefix = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
  if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Path is outside its intended disposable root: $full"
  }
  for ($part = $full; $part; $part = Split-Path -Parent $part) {
    if ((Test-Path -LiteralPath $part) -and
        ((Get-Item -LiteralPath $part -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
      throw "Reparse points are prohibited in disposable test paths: $part"
    }
  }
  return $full
}

$runnerTemp = [IO.Path]::GetFullPath($env:RUNNER_TEMP)
$workspace = [IO.Path]::GetFullPath($env:GITHUB_WORKSPACE)
$testRoot = Assert-Child (Join-Path $runnerTemp "ebr-exact-$($env:GITHUB_RUN_ID)-$($env:GITHUB_RUN_ATTEMPT)") $runnerTemp
$EvidencePath = Assert-Child $EvidencePath $workspace
$BaselineInstaller = Assert-Child $BaselineInstaller $runnerTemp
$BaselineApplication = Assert-Child $BaselineApplication $runnerTemp
$candidatePrefix = $runnerTemp.TrimEnd('\') + '\'
$candidateRoot = if ([IO.Path]::GetFullPath($CandidateDirectory).StartsWith($candidatePrefix,[StringComparison]::OrdinalIgnoreCase)) {
  Assert-Child $CandidateDirectory $runnerTemp
} else {
  Assert-Child $CandidateDirectory $workspace
}
$install = Join-Path $testRoot 'installed'
$target = Join-Path $install 'EyeBreakReminder.exe'
$retryCwd = Join-Path $testRoot 'fresh working directory'
$handoff = Join-Path $testRoot 'handoff.json'
$localAppData = [Environment]::GetFolderPath('LocalApplicationData')
if (-not $localAppData -or [IO.Path]::GetFullPath($localAppData) -ine [IO.Path]::GetFullPath($env:LOCALAPPDATA)) {
  throw 'LocalAppData environment variable and Known Folder identity differ.'
}
$data = Assert-Child (Join-Path $localAppData 'EyeBreakReminder') $localAppData
$runOnceKey = 'Software\Microsoft\Windows\CurrentVersion\RunOnce'
$valueName = '!EyeBreakReminderUpdateRecovery'
$productKey = 'Software\EyeBreakReminder'
$uninstallKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder'
$startupKey = 'Software\Microsoft\Windows\CurrentVersion\Run'
$startupCommand = '"' + $target + '" --startup'
$profileNames = @('settings.ini', 'timer.dat', 'history.dat')
$installedNames = @('Uninstall.exe', 'README.md', 'PRIVACY.md', 'VERIFICATION.md')
$seedCountdownSeconds = 420
$ownerProcesses = [Collections.Generic.List[object]]::new()
$assertions = [Collections.Generic.List[object]]::new()
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$sessionId = (Get-Process -Id $PID).SessionId
$os = Get-CimInstance Win32_OperatingSystem
$boot = $os.LastBootUpTime.ToUniversalTime().ToString('o')
$utf8 = [Text.UTF8Encoding]::new($false)

function Get-Sha([string]$Path) {
  (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Confirm([bool]$Condition, [string]$Name, $Evidence = $null) {
  $assertions.Add([ordered]@{
    Name = $Name
    Status = if ($Condition) { 'PASS' } else { 'FAIL' }
    Evidence = $Evidence
    Utc = [DateTime]::UtcNow.ToString('o')
  })
  if (-not $Condition) { throw "Unproved recovery assertion: $Name" }
}

function Read-Reg([string]$Key, [string]$Name) {
  $handle = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Key, $false)
  if ($null -eq $handle) { return }
  try {
    if ($handle.GetValueNames() -contains $Name) {
      [pscustomobject]@{ Value = $handle.GetValue($Name, $null, 'DoNotExpandEnvironmentNames'); Kind = $handle.GetValueKind($Name).ToString() }
    }
  } finally {
    $handle.Dispose()
  }
}

function Wait-For([scriptblock]$Observation, [string]$Description, [int]$Seconds = 30) {
  $watch = [Diagnostics.Stopwatch]::StartNew()
  while ($watch.Elapsed.TotalSeconds -lt $Seconds) {
    $result = & $Observation
    if ($result) { return $result }
    Start-Sleep -Milliseconds 25
  }
  throw "Timed out observing $Description."
}

function Read-Phase([string]$Stage) {
  $name = Join-Path $Stage 'transaction-state.ini'
  if (Test-Path -LiteralPath $name -PathType Leaf) {
    try {
      if ([IO.File]::ReadAllText($name) -match '(?m)^phase=([a-z]+)$') { return $Matches[1] }
    } catch [IO.IOException] {}
  }
}

function Start-Exact([string]$Image, [string]$WorkingDirectory, [string[]]$ArgumentList,
    [string]$RawArguments = '', [hashtable]$TestEnvironment = @{}) {
  $info = [Diagnostics.ProcessStartInfo]::new()
  $info.FileName = $Image
  $info.WorkingDirectory = $WorkingDirectory
  $info.UseShellExecute = $false
  if ($RawArguments) {
    $info.Arguments = $RawArguments
  } else {
    foreach ($argument in $ArgumentList) { $info.ArgumentList.Add($argument) }
  }
  $info.Environment.Clear()
  foreach ($name in 'SYSTEMROOT','WINDIR','PATH','TEMP','TMP','USERPROFILE','LOCALAPPDATA','APPDATA','USERNAME','USERDOMAIN','SESSIONNAME','COMSPEC','PROGRAMDATA','SYSTEMDRIVE') {
    $value = [Environment]::GetEnvironmentVariable($name)
    if ($value) { $info.Environment[$name] = $value }
  }
  $info.Environment['EBR_GUI_TEST_DATA_DIRECTORY'] = $data
  foreach ($name in $TestEnvironment.Keys) { $info.Environment[$name] = [string]$TestEnvironment[$name] }

  $process = [Diagnostics.Process]::Start($info)
  if ($null -eq $process) { throw "Could not launch the owned image: $Image" }
  $entry = [pscustomobject]@{ Process = $process; Image = $Image; Start = $process.StartTime.ToUniversalTime() }
  $ownerProcesses.Add($entry)
  return $entry
}

function Stop-Owned($Entry) {
  $process = $Entry.Process
  $process.Refresh()
  if ($process.HasExited) { throw "Owned process $($process.Id) exited before the requested interruption." }
  if ($process.Path -ine $Entry.Image -or $process.SessionId -ne $sessionId -or
      $process.StartTime.ToUniversalTime() -ne $Entry.Start) {
    throw "Refusing to touch process $($process.Id) after identity mismatch."
  }
  $process.Kill()
  if (-not $process.WaitForExit(5000)) { throw "Owned process $($process.Id) did not exit." }
  [pscustomobject]@{ Id = $process.Id; Image = $Entry.Image; StartedUtc = $Entry.Start.ToString('o'); ExitCode = $process.ExitCode }
}

function Find-OwnedTarget($LaunchingHelper) {
  foreach ($process in Get-Process -Name EyeBreakReminder -ErrorAction SilentlyContinue) {
    if ($process.Path -ieq $target -and $process.SessionId -eq $sessionId -and -not $process.HasExited) {
      $started = $process.StartTime.ToUniversalTime()
      $instance = Get-CimInstance Win32_Process -Filter "ProcessId=$($process.Id)"
      if ($instance.ParentProcessId -eq $LaunchingHelper.Process.Id -and $started -ge $LaunchingHelper.Start) {
        return [pscustomobject]@{ Process = $process; Image = $target; Start = $started }
      }
    }
  }
}

function Find-TransactionProcesses([string]$Stage) {
  $images = @($target, (Join-Path $Stage 'coordinator.exe'), (Join-Path $Stage 'EyeBreakReminder-Setup-x64.exe'))
  Get-CimInstance Win32_Process -Filter "Name='EyeBreakReminder.exe' OR Name='coordinator.exe' OR Name='EyeBreakReminder-Setup-x64.exe'" |
    Where-Object { $images -icontains $_.ExecutablePath }
}

function Read-RunOnceCommand([string]$Stage) {
  $helper = Join-Path $Stage 'coordinator.exe'
  $transaction = Join-Path $Stage 'transaction.ini'
  $full = '"' + $helper + '" --update-recover "' + $transaction + '"'
  $compact = '"' + $helper + '" --update-recover'
  $value = Read-Reg $runOnceKey $valueName
  $expected = if ($full.Length -le 260) { $full } else { $compact }
  Confirm ($value.Kind -ceq 'String' -and $value.Value -ceq $expected -and $expected.Length -le 260) 'HKCU RunOnce stores the exact quoted recovery command within 260 characters' (
    @{ Key = "HKCU\$runOnceKey"; Name = $valueName; Command = $value.Value; Kind = $value.Kind; FullFormLength = $full.Length; Length = $expected.Length; Sid = $sid })
  return [pscustomobject]@{
    Image = $helper
    Command = [string]$value.Value
    RawArguments = $value.Value.Substring($helper.Length + 3)
  }
}

function Remove-ExactRunOnceAfterManualReplay([string]$ExpectedCommand) {
  $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($runOnceKey, $true)
  if ($null -eq $key) { throw 'The manual replay did not leave its exact pending RunOnce key available for the post-command cleanup simulation.' }
  try {
    if ($key.GetValueKind($valueName) -ne [Microsoft.Win32.RegistryValueKind]::String -or
        $key.GetValue($valueName, $null, 'DoNotExpandEnvironmentNames') -cne $ExpectedCommand) {
      throw 'Refusing to remove a RunOnce value that is not the exact transaction command created by the coordinator.'
    }
    $key.DeleteValue($valueName, $false)
  } finally {
    $key.Dispose()
  }
}

$native = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class EbrRestartObservation
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr FindWindow(string className, string title);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);

    [DllImport("user32.dll")]
    private static extern IntPtr GetDlgItem(IntPtr window, int id);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr SendMessageTimeout(IntPtr window, uint message, UIntPtr maxChars,
        StringBuilder text, uint flags, uint timeout, out UIntPtr result);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern uint RegisterWindowMessage(string name);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

    private static IntPtr NativeWindow(int pid)
    {
        var window = FindWindow("EyeBreakReminder.Native", "Eye Break Reminder");
        return window != IntPtr.Zero && GetWindowThreadProcessId(window, out uint owner) != 0
            && owner == (uint)pid ? window : IntPtr.Zero;
    }

    public static bool Close(int pid)
    {
        var window = NativeWindow(pid);
        return window != IntPtr.Zero && PostMessage(window,
            RegisterWindowMessage("EyeBreakReminder.Exit.Native.1"), IntPtr.Zero, IntPtr.Zero);
    }

    public static string Countdown(int pid)
    {
        var window = NativeWindow(pid);
        if (window == IntPtr.Zero) return "";
        var countdown = GetDlgItem(window, 40);
        if (countdown == IntPtr.Zero) return "";
        var text = new StringBuilder(32);
        return SendMessageTimeout(countdown, 13, (UIntPtr)text.Capacity, text, 2, 750,
            out _) != IntPtr.Zero ? text.ToString() : "";
    }
}
'@
Add-Type -TypeDefinition $native

function Confirm-Timer($Entry, [int]$MaximumSeconds = $seedCountdownSeconds) {
  $id = $Entry.Process.Id
  $first = Wait-For {
    $value = [EbrRestartObservation]::Countdown($id)
    if ($value -match '^(\d{1,3}):(\d\d)$' -and ([int]$Matches[1] * 60 + [int]$Matches[2]) -le $MaximumSeconds) { $value }
  } 'owned native timer'
  $second = Wait-For {
    $value = [EbrRestartObservation]::Countdown($id)
    if ($value -match '^\d{1,3}:\d\d$' -and $value -ne $first) { $value }
  } 'timer advancement'
  $before = [int]($first -split ':')[0] * 60 + [int]($first -split ':')[1]
  $after = [int]($second -split ':')[0] * 60 + [int]($second -split ':')[1]
  $name = if ($MaximumSeconds -eq $seedCountdownSeconds) {
    'Application loads the distinct seeded timer checkpoint and its countdown advances'
  } else { 'Reinstalled exact application opens and its default countdown advances' }
  Confirm ($after -lt $before -and $before -le $MaximumSeconds) $name (
    @{ Pid = $id; MaximumSeconds = $MaximumSeconds; Before = $first; After = $second })
}



Add-Type -Path (Join-Path $PSScriptRoot 'windows_exact_candidate_recovery_debugger.cs')

function New-ExactTransaction([string]$Stage, [int]$PreviousProcessId) {
  [void][IO.Directory]::CreateDirectory($Stage)
  $helper = Join-Path $Stage 'coordinator.exe'
  $setup = Join-Path $Stage 'EyeBreakReminder-Setup-x64.exe'
  Copy-Item -LiteralPath (Join-Path $candidateRoot 'EyeBreakReminder.exe') -Destination $helper
  foreach ($name in @('EyeBreakReminder-Setup-x64.exe','EyeBreakReminder-UpdateManifest.json','EyeBreakReminder-UpdateManifest.sig')) {
    Copy-Item -LiteralPath (Join-Path $candidateRoot $name) -Destination $Stage
  }
  $clean = if ($FaultBoundary -ceq 'BeforeRelaunch') { 1 } else { 0 }
  $metadata = [ordered]@{
    staging = $Stage; artifact = $setup; target = $target; data = $data
    version = '1.4.0'; previous = '1.3.0'; nonce = [guid]::NewGuid().ToString('D')
    kind = 'installed'; name = 'EyeBreakReminder-Setup-x64.exe'
    sha256 = Get-Sha $setup; applicationSha256 = Get-Sha $helper
    previousSha256 = Get-Sha $target; size = (Get-Item -LiteralPath $setup).Length
    backupMask = 0; ownedFileMask = 0; pid = $PreviousProcessId
    clean = $clean; deleteHistory = $clean; dark = 0; forcedColors = 0; previousStartup = 1
  }
  for ($i = 0; $i -lt 3; $i++) { $metadata["backupSha256$i"] = '' }
  for ($i = 0; $i -lt 4; $i++) { $metadata["ownedFileSha256$i"] = '' }
  $lines = @(foreach ($entry in $metadata.GetEnumerator()) { "$($entry.Key)=$($entry.Value)" })
  $transaction = Join-Path $Stage 'transaction.ini'
  [IO.File]::WriteAllText($transaction, ($lines -join [char]10) + [char]10, $utf8)
  return $transaction
}

function Confirm-ExactBackups([string]$Stage, $Prior) {
  $transaction = @{}
  foreach ($line in [IO.File]::ReadAllLines((Join-Path $Stage 'transaction.ini'))) {
    $key, $value = $line -split '=', 2
    if ($key) { $transaction[$key] = $value }
  }
  $mask = 0
  for ($i = 0; $i -lt $installedNames.Count; $i++) {
    $name = $installedNames[$i]
    $path = Join-Path $Stage "previous-owned-$i.dat"
    if ($Prior.Installed.Contains($name)) {
      $mask = $mask -bor (1 -shl $i)
      $hash = Get-Sha $path
      Confirm ($hash -ceq $Prior.Installed[$name] -and $hash -ceq $transaction["ownedFileSha256$i"]) "Installer-owned backup matches prior $name" $hash
    } else {
      Confirm (-not (Test-Path -LiteralPath $path)) "No backup of installer file absent at baseline: $name"
    }
  }
  Confirm ($transaction.backupMask -ceq '7' -and $transaction.ownedFileMask -eq $mask) 'Persisted backup masks match the existing disposable files'
  $previousHash = Get-Sha (Join-Path $Stage 'previous.exe')
  Confirm ($previousHash -ceq $Prior.Executable -and $previousHash -ceq $transaction.previousSha256) 'Previous executable backup matches original and metadata' $previousHash
  for ($i = 0; $i -lt $profileNames.Count; $i++) {
    $name = $profileNames[$i]
    $hash = Get-Sha (Join-Path $Stage "backup-$i.dat")
    Confirm ($hash -ceq $Prior.Profile[$name] -and $hash -ceq $transaction["backupSha256$i"]) "Profile backup matches prior $name" $hash
  }
}

$candidateFiles = [ordered]@{
  'EyeBreakReminder.exe' = '3dd3fa4c8e9f6200780c7bf0c2340435c7b127ce6b6202b24857105f01f3719a'
  'EyeBreakReminder-Setup-x64.exe' = '7df5c6f61cbb56d813e4eee989637e6fcf692d1879f1446d4776da5928e49c2a'
  'EyeBreakReminder-Portable-x64.zip' = '9337550cf5a2fc2b685672205654d8c674fb8440b01a0ce97c8762bd065f6341'
  'EyeBreakReminder-Source.zip' = 'c8971b3d32b8aad2bf634e40cf753f33b2430f7167effd93063c578e0e05480c'
  'EyeBreakReminder-SHA256.txt' = 'ae6032f9810e7362a27a0b0b15405537aab4ff2fb7ce6efc3c4e97b42e7796df'
  'EyeBreakReminder-UpdateManifest.json' = '88ec256d6c4bb8f0c52946b947cf8778e0966f8cfe84c9f83c551f9a61af84a6'
  'EyeBreakReminder-UpdateManifest.sig' = 'c0906144d52623a4d428df0d69208a849102df731877bbcdb9d366d1f4031992'
}
$report = [ordered]@{
  Status = 'FAIL'; Phase = $Phase; Boundary = $FaultBoundary; RunId = $env:GITHUB_RUN_ID; WorkflowCommit = $env:GITHUB_SHA
  CandidateArtifactId = 15007651099; CandidateSource = '0f49949a9e753fcca390c25affc99d7698b1ecde'; KeyId = 'p256-0aff97759ea95258'
  OS = $os.Caption; OSBuild = $os.BuildNumber; UserSid = $sid; SessionId = $sessionId; BootUtc = $boot; HarnessPid = $PID
  GenuineWindowsReboot = $false; WindowsSignInInvocation = $false; RecoveryDamage = $RecoveryDamage
  Baseline = 'Published v1.3.0 setup and install metadata with a separately identified v1.3.0 version-adjusted fixture app that implements startup confirmation.'
  Scope = 'Harness supplies staged transaction input. Exact production image performs coordinator and rollback. Production signature verification remains active.'
}
try {
  foreach ($name in $candidateFiles.Keys) {
    $hash = Get-Sha (Assert-Child (Join-Path $candidateRoot $name) $candidateRoot)
    Confirm ($hash -ceq $candidateFiles[$name]) "Candidate artifact 15007651099 matches $name" $hash
  }
  Confirm ((Get-Sha $BaselineInstaller) -ceq '67c7bb338e83397e17007fa0afff9b4ad06f0a2d7924bb016198d9d38e3a76b4' -and
    (Get-Item -LiteralPath $BaselineApplication).VersionInfo.ProductVersion -match '^1\.3\.0(\.0)?$') 'Pinned published v1.3.0 setup and distinct confirmation-capable test fixture were supplied' (Get-Sha $BaselineApplication)
  if ($Phase -ceq 'Interrupt') {
    if ((Test-Path -LiteralPath $testRoot) -or (Test-Path -LiteralPath $data) -or (Read-Reg $runOnceKey $valueName) -or
        (Read-Reg $startupKey 'EyeBreakReminder') -or (Read-Reg $productKey 'InstallDir') -or
        (Read-Reg $uninstallKey 'DisplayName') -or (Get-Process -Name EyeBreakReminder,coordinator -ErrorAction SilentlyContinue)) {
      throw 'Disposable runner already contains application state or processes.'
    }
    foreach ($directory in $install,$data,$retryCwd) { [void][IO.Directory]::CreateDirectory($directory) }
    $setup = Start-Exact $BaselineInstaller $testRoot @() -RawArguments "/S /D=$install"
    Confirm ($setup.Process.WaitForExit(120000) -and $setup.Process.ExitCode -eq 0 -and
      (Get-Sha $target) -ceq '3ca3133559de29d78f7a1054542d757d24877e93b4409c731081ebf6d1846d66' -and
      (Read-Reg $productKey 'InstallDir').Value -ieq $install -and (Read-Reg $uninstallKey 'DisplayVersion').Value -ceq '1.3.0') 'Published v1.3.0 setup installs its genuine application and matching registration'
    Copy-Item -LiteralPath $BaselineApplication -Destination $target -Force
    $settings = @('workMinutes=37','breakSeconds=33','volume=32','theme=2','alarm=0','notifications=0',
      'autoStart=1','startup=1','history=1','schedule=0','autoCheckUpdates=0','autoDownloadUpdates=0','restore=1')
    [IO.File]::WriteAllLines((Join-Path $data 'settings.ini'), $settings, $utf8)
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    [IO.File]::WriteAllText((Join-Path $data 'timer.dat'), "0 0 $seedCountdownSeconds 2220 7 $now", $utf8)
    [IO.File]::WriteAllLines((Join-Path $data 'history.dat'), @("$($now - 120) 1 20"), $utf8)
    $neighbor = Join-Path $data 'unrelated.txt'
    [IO.File]::WriteAllText($neighbor, [guid]::NewGuid().ToString('D'), $utf8)
    $run = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($startupKey)
    try { $run.SetValue('EyeBreakReminder', $startupCommand, 'String') } finally { $run.Dispose() }
    $previous = Start-Exact $target $install @()
    Confirm-Timer $previous
    Confirm ([EbrRestartObservation]::Close($previous.Process.Id) -and $previous.Process.WaitForExit(10000) -and
      $previous.Process.ExitCode -eq 0) 'Confirmation-capable baseline exits through its actual shutdown path'
    $prior = [ordered]@{ Executable = Get-Sha $target; Profile = [ordered]@{}; Installed = [ordered]@{}; Neighbor = Get-Sha $neighbor }
    foreach ($name in $profileNames) { $prior.Profile[$name] = Get-Sha (Join-Path $data $name) }
    foreach ($name in $installedNames) {
      $file = Join-Path $install $name
      if (Test-Path -LiteralPath $file -PathType Leaf) { $prior.Installed[$name] = Get-Sha $file }
    }
    $stage = Assert-Child (Join-Path (Join-Path $data 'updates') ([guid]::NewGuid().ToString('B'))) $data
    $transaction = New-ExactTransaction $stage $previous.Process.Id
    $helper = Join-Path $stage 'coordinator.exe'
    $installer = Join-Path $stage 'EyeBreakReminder-Setup-x64.exe'
    Confirm ((Get-Sha $helper) -ceq $candidateFiles['EyeBreakReminder.exe'] -and
      (Get-Sha $installer) -ceq $candidateFiles['EyeBreakReminder-Setup-x64.exe']) 'Exact production coordinator and setup bytes were staged'
    $boundaryObserver = [Action[uint32,uint32]]{
      param($coordinatorPid, $childPid)
      $expectedPhase = if ($FaultBoundary -ceq 'BeforeRelaunch') { 'starting' } else { 'installing' }
      Confirm ((Read-Phase $stage) -ceq $expectedPhase) 'Phase was observed while the precisely identified child was still stopped by its process-creation debug event' (
        @{ Phase = $expectedPhase; CoordinatorPid = $coordinatorPid; ChildPid = $childPid })
      $commandAtBoundary = Read-RunOnceCommand $stage
      Confirm-ExactBackups $stage $prior
      if ($FaultBoundary -ceq 'BeforeRelaunch') {
        Confirm ((Get-Sha $target) -ceq $candidateFiles['EyeBreakReminder.exe'] -and
          (Read-Reg $uninstallKey 'DisplayVersion').Value -ceq '1.4.0' -and
          @($profileNames | Where-Object { Test-Path -LiteralPath (Join-Path $data $_) }).Count -eq 0 -and
          -not (Read-Reg $startupKey 'EyeBreakReminder')) 'Exact setup replaced the executable and registration, and coordinator applied the requested cleanup before relaunch'
      } else {
        Confirm ((Get-Sha $target) -ceq $prior.Executable -and (Read-Reg $uninstallKey 'DisplayVersion').Value -ceq '1.3.0') 'Exact installer was stopped before any replacement'
      }
    }
    $observation = [EbrRecoveryDebugger]::Interrupt($helper,$transaction,$installer,$target,$FaultBoundary,$boundaryObserver)
    Confirm ($observation.CoordinatorExitCode -eq 197 -and $observation.InterruptedChildExitCode -eq 197 -and
      $null -eq (Find-TransactionProcesses $stage)) 'Debugger recorded exit of both specifically identified processes and no transaction process survived' $observation
    $command = Read-RunOnceCommand $stage
    $report.Handoff = [ordered]@{
      Stage = $stage; Command = $command.Command; Original = $prior; Journal = Read-Phase $stage
      JournalHash = Get-Sha (Join-Path $stage 'transaction-state.ini'); TransactionHash = Get-Sha $transaction
    }
    $report.Status = 'INTERRUPTED'
  } else {
    $original = Get-Content -LiteralPath $handoff -Raw | ConvertFrom-Json -AsHashtable
    Confirm ($original.Status -ceq 'INTERRUPTED' -and $original.RunId -ceq $env:GITHUB_RUN_ID -and
      $original.WorkflowCommit -ceq $env:GITHUB_SHA -and $original.Boundary -ceq $FaultBoundary -and
      $original.UserSid -ceq $sid -and $original.SessionId -eq $sessionId -and $original.BootUtc -ceq $boot -and
      $original.HarnessPid -ne $PID -and -not (Get-Process -Id $original.HarnessPid -ErrorAction SilentlyContinue)) 'Recovery starts in a separate harness after original process loss under the same Windows boot and user'
    $stage = Assert-Child $original.Handoff.Stage (Join-Path $data 'updates')
    $prior = $original.Handoff.Original
    $command = Read-RunOnceCommand $stage
    Confirm ((Get-Sha $command.Image) -ceq $candidateFiles['EyeBreakReminder.exe'] -and
      $command.Command -ceq $original.Handoff.Command -and (Read-Phase $stage) -ceq $original.Handoff.Journal -and
      (Get-Sha (Join-Path $stage 'transaction-state.ini')) -ceq $original.Handoff.JournalHash -and
      (Get-Sha (Join-Path $stage 'transaction.ini')) -ceq $original.Handoff.TransactionHash -and
      $null -eq (Find-TransactionProcesses $stage)) 'Original transient processes are absent and the saved registered command targets the exact production image'
    foreach ($name in 'EyeBreakReminder-UpdateManifest.json','EyeBreakReminder-UpdateManifest.sig') {
      Confirm ((Get-Sha (Join-Path $stage $name)) -ceq $candidateFiles[$name]) "Staged production authentication material is unchanged: $name"
    }
    Confirm-ExactBackups $stage $prior
    if ($RecoveryDamage -cne 'None') {
      $report.DamagedTransaction = [ordered]@{ Status = 'INCOMPLETE'; Damage = $RecoveryDamage }
      $damagedFile = if ($RecoveryDamage -ceq 'MissingCoordinator') { $command.Image } else { Join-Path $stage 'previous.exe' }
      $damagedFile = Assert-Child $damagedFile $stage
      $hashBefore = Get-Sha $damagedFile
      if ($RecoveryDamage -ceq 'CorruptBackup') {
        [IO.File]::WriteAllBytes($damagedFile, [byte[]]@())
        Confirm ((Get-Item -LiteralPath $damagedFile).Length -eq 0 -and (Get-Sha $damagedFile) -cne $hashBefore) 'Previous executable backup is an existing truncated file'
      } else {
        [IO.File]::Delete($damagedFile)
        Confirm (-not (Test-Path -LiteralPath $damagedFile)) 'Selected transaction file is genuinely missing'
      }
      $report.DamagedTransaction.BeforeDamageSHA256 = $hashBefore
      $report.DamagedTransaction.AfterDamageSHA256 = if (Test-Path -LiteralPath $damagedFile) { Get-Sha $damagedFile } else { $null }

      $targetPath = Assert-Child $target $testRoot
      [IO.File]::Delete($targetPath)
      Confirm (-not (Test-Path -LiteralPath $target) -and
        (Read-Reg $runOnceKey $valueName).Value -ceq $command.Command) 'Installed executable is missing while the genuine recovery registration remains'
      $installerPath = Join-Path $candidateRoot 'EyeBreakReminder-Setup-x64.exe'
      $repair = Start-Exact $installerPath $testRoot @() -RawArguments "/S /D=$install"
      Confirm ($repair.Process.WaitForExit(120000) -and $repair.Process.ExitCode -eq 0 -and
        (Get-Sha $target) -ceq $candidateFiles['EyeBreakReminder.exe'] -and
        (Read-Reg $uninstallKey 'DisplayVersion').Value -ceq '1.4.0' -and
        (Get-Sha (Join-Path $data 'unrelated.txt')) -ceq $prior.Neighbor) 'Ordinary exact reinstall restores v1.4.0 and preserves the unrelated file'
      $report.DamagedTransaction.InstalledSHA256 = Get-Sha $target
      $report.DamagedTransaction.Version = (Read-Reg $uninstallKey 'DisplayVersion').Value
      Confirm (-not (Test-Path -LiteralPath (Join-Path $data 'settings.ini')) -and
        -not (Test-Path -LiteralPath (Join-Path $data 'history.dat'))) 'Ordinary reinstall does not reconstruct settings or history removed before interruption'

      if ($RecoveryDamage -ceq 'MissingCoordinator') {
        Confirm (-not (Test-Path -LiteralPath $command.Image) -and (Read-Reg $runOnceKey $valueName).Value -ceq $command.Command) 'Exact saved RunOnce name still targets the missing coordinator'
        $report.DamagedTransaction.RunOnceReplay = 'BLOCKED_MISSING_REGISTERED_IMAGE'
      } else {
        $traceSource = "ebr-recovery-$PID"
        $trace = Register-CimIndicationEvent -Query 'SELECT * FROM Win32_ProcessStartTrace' -SourceIdentifier $traceSource
        try {
          $failure = Start-Exact $command.Image $retryCwd @() -RawArguments $command.RawArguments
          [void](Wait-For {
            $failure.Process.Refresh()
            -not $failure.Process.HasExited -and $failure.Process.MainWindowTitle -ceq 'Eye Break Reminder Recovery'
          } 'exact recovery error dialog for the damaged executable backup')
          $native = Get-CimInstance Win32_Process -Filter "ProcessId=$($failure.Process.Id)"
          Confirm ($native.ExecutablePath -ieq $command.Image -and $native.CommandLine -ceq $command.Command) 'Exact saved RunOnce command was replayed after the backup failure'
          Confirm ($failure.Process.CloseMainWindow() -and $failure.Process.WaitForExit(10000) -and
            $failure.Process.ExitCode -eq 1) 'Exact production recovery reports failure and exits with code 1'
          $startedChildren = @(Get-Event -SourceIdentifier $traceSource -ErrorAction SilentlyContinue |
            Where-Object { $_.SourceEventArgs.NewEvent.ParentProcessID -eq $failure.Process.Id })
          $helperEvent = @(Get-Event -SourceIdentifier $traceSource -ErrorAction SilentlyContinue |
            Where-Object { $_.SourceEventArgs.NewEvent.ProcessID -eq $failure.Process.Id -and
              $_.SourceEventArgs.NewEvent.ProcessName -ceq 'coordinator.exe' })
          Confirm ($helperEvent.Count -eq 1 -and $startedChildren.Count -eq 0) 'Runner process-start trace observes the recovery helper and no child process'
          $report.DamagedTransaction.RunOnceReplay = 'RECOVERY_REJECTED_UNUSABLE_BACKUP'
        } finally {
          Unregister-Event -SourceIdentifier $traceSource
          Remove-Event -SourceIdentifier $traceSource -ErrorAction SilentlyContinue
        }
      }

      Confirm ((Read-Reg $runOnceKey $valueName).Value -ceq $command.Command -and
        (Get-Sha (Join-Path $stage 'transaction-state.ini')) -ceq $original.Handoff.JournalHash -and
        (Get-Sha (Join-Path $stage 'transaction.ini')) -ceq $original.Handoff.TransactionHash -and
        (Get-Sha (Join-Path $stage 'EyeBreakReminder-UpdateManifest.json')) -ceq $candidateFiles['EyeBreakReminder-UpdateManifest.json'] -and
        (Get-Sha (Join-Path $stage 'EyeBreakReminder-UpdateManifest.sig')) -ceq $candidateFiles['EyeBreakReminder-UpdateManifest.sig'] -and
        (Get-Sha (Join-Path $stage 'EyeBreakReminder-Setup-x64.exe')) -ceq $candidateFiles['EyeBreakReminder-Setup-x64.exe']) 'Genuine pending registration, stage, and signed update inputs survive reinstall and recovery rejection'
      for ($i = 0; $i -lt $profileNames.Count; $i++) {
        Confirm ((Get-Sha (Join-Path $stage "backup-$i.dat")) -ceq $prior.Profile[$profileNames[$i]]) "Verified transaction data backup still matches original: $($profileNames[$i])"
      }
      Confirm ((Get-Sha $target) -ceq $candidateFiles['EyeBreakReminder.exe'] -and
        (Read-Reg $uninstallKey 'DisplayVersion').Value -ceq '1.4.0' -and
        -not (Test-Path -LiteralPath (Join-Path $data 'settings.ini')) -and
        -not (Test-Path -LiteralPath (Join-Path $data 'history.dat'))) 'Recovery rejection performs no rollback and restores no missing live settings or history'
      $installedApp = Start-Exact $target $install @()
      Confirm ($installedApp.Process.Path -ieq $target -and
        (Get-Sha $target) -ceq $candidateFiles['EyeBreakReminder.exe']) 'Ordinary launch runs the exact reinstalled candidate image'
      Confirm-Timer $installedApp 3600
      Confirm ([EbrRestartObservation]::Close($installedApp.Process.Id) -and $installedApp.Process.WaitForExit(10000)) 'Reinstalled exact app exits normally'
      Confirm ((Get-Sha (Join-Path $data 'unrelated.txt')) -ceq $prior.Neighbor -and
        (Read-Reg $runOnceKey $valueName).Value -ceq $command.Command) 'Ordinary launch does not clean the pending update or change the unrelated file'
      $report.DamagedTransaction.Status = 'APP_REPAIRED_PENDING_RECOVERY_UNRESOLVED'
      $report.Status = 'PASS'
      return
    }
    if ($ReinstallBeforeRecovery) {
      $report.ReinstallBeforeRecovery = [ordered]@{ Status = 'INCOMPLETE' }
      $installerPath = Join-Path $candidateRoot 'EyeBreakReminder-Setup-x64.exe'
      # Recreate a genuinely unlaunchable installation without touching its
      # authentic transaction, registration, or the protected candidate artifact.
      Assert-Child $target $testRoot | Out-Null
      [IO.File]::Delete($target)
      Confirm (-not (Test-Path -LiteralPath $target) -and
        (Read-Reg $runOnceKey $valueName).Value -ceq $command.Command) 'Repair case has a missing installed executable and still has the real pending recovery registration'
      $repair = Start-Exact $installerPath $testRoot @() -RawArguments "/S /D=$install"
      Confirm ($repair.Process.WaitForExit(120000) -and $repair.Process.ExitCode -eq 0 -and
        (Get-Sha $target) -ceq $candidateFiles['EyeBreakReminder.exe'] -and
        (Read-Reg $uninstallKey 'DisplayVersion').Value -ceq '1.4.0' -and
        (Get-Sha (Join-Path $data 'unrelated.txt')) -ceq $prior.Neighbor) 'Ordinary exact reinstall restores the installed executable and leaves the unrelated file intact'
      Confirm ((Read-Reg $runOnceKey $valueName).Value -ceq $command.Command -and
        (Get-Sha (Join-Path $stage 'transaction-state.ini')) -ceq $original.Handoff.JournalHash -and
        (Get-Sha (Join-Path $stage 'transaction.ini')) -ceq $original.Handoff.TransactionHash -and
        -not (Test-Path -LiteralPath (Join-Path $data 'settings.ini')) -and
        -not (Test-Path -LiteralPath (Join-Path $data 'history.dat'))) 'Ordinary reinstall leaves the authentic pending transaction and cannot recreate the already removed data'
      $report.ReinstallBeforeRecovery.Status = 'EXECUTABLE_REPAIRED_PENDING_RECOVERY_RETAINED'
      $report.ReinstallBeforeRecovery.InstalledSHA256 = Get-Sha $target
      $report.ReinstallBeforeRecovery.PendingCommand = $command.Command
    }
    if ($FaultBoundary -ceq 'BeforeRelaunch') {
      $lockedPath = Join-Path $install 'Uninstall.exe'
      $lockedHash = Get-Sha $lockedPath
      $stream = [IO.File]::Open($lockedPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
      try {
        $locked = Start-Exact $command.Image $retryCwd @() -RawArguments $command.RawArguments
        [void](Wait-For {
          $locked.Process.Refresh()
          -not $locked.Process.HasExited -and $locked.Process.MainWindowTitle -ceq 'Eye Break Reminder Recovery'
        } 'exact production recovery error reporting the blocked restoration')
        $native = Get-CimInstance Win32_Process -Filter "ProcessId=$($locked.Process.Id)"
        Confirm ($native.ExecutablePath -ieq $command.Image -and $native.CommandLine -ceq $command.Command -and
          (Get-Sha $target) -ceq $prior.Executable -and (Get-Sha $lockedPath) -ceq $lockedHash -and
          (Read-Reg $uninstallKey 'DisplayVersion').Value -ceq '1.4.0' -and
          -not (Test-Path -LiteralPath (Join-Path $data 'history.dat')) -and
          (Read-Phase $stage) -ceq 'starting' -and (Read-Reg $runOnceKey $valueName).Value -ceq $command.Command) 'Exact recovery restores the executable but cannot replace the locked owned file, retaining later data backups and retry authority'
        Confirm-ExactBackups $stage $prior
        $killed = Stop-Owned $locked
        Confirm ($null -eq (Find-TransactionProcesses $stage)) 'Failed recovery process exits before unlocking and retry' $killed
      } finally { $stream.Dispose() }
    }
    $recovery = Start-Exact $command.Image $retryCwd @() -RawArguments $command.RawArguments
    $native = Get-CimInstance Win32_Process -Filter "ProcessId=$($recovery.Process.Id)"
    Confirm ($native.ExecutablePath -ieq $command.Image -and $native.CommandLine -ceq $command.Command) 'Fresh process executes the captured RunOnce command verbatim' $native.CommandLine
    Confirm ($recovery.Process.WaitForExit(90000) -and $recovery.Process.ExitCode -eq 0) 'Exact production recovery returns success following process loss'
    $app = Wait-For { Find-OwnedTarget $recovery } 'restored confirmation-capable baseline app'
    $ownerProcesses.Add($app)
    Confirm ((Read-Phase $stage) -ceq 'recovered' -and (Read-Reg $runOnceKey $valueName).Value -ceq $command.Command -and
      (Read-Reg $uninstallKey 'DisplayVersion').Value -ceq '1.3.0' -and
      (Read-Reg $startupKey 'EyeBreakReminder').Value -ceq $startupCommand -and
      (Get-Sha $target) -ceq $prior.Executable -and (Get-Sha (Join-Path $data 'settings.ini')) -ceq $prior.Profile['settings.ini'] -and
      (Get-Sha (Join-Path $data 'history.dat')) -ceq $prior.Profile['history.dat'] -and
      (Get-Sha (Join-Path $data 'unrelated.txt')) -ceq $prior.Neighbor) 'Prior executable, version, startup, settings, history and unrelated file are restored exactly'
    if ($ReinstallBeforeRecovery) {
      $report.ReinstallBeforeRecovery.Status = 'REINSTALL_DOES_NOT_SUPERSEDE_PENDING_ROLLBACK'
      $report.ReinstallBeforeRecovery.AfterRecoverySHA256 = Get-Sha $target
      $report.ReinstallBeforeRecovery.AfterRecoveryVersion = (Read-Reg $uninstallKey 'DisplayVersion').Value
    }
    foreach ($name in $installedNames) {
      $path = Join-Path $install $name
      if ($prior.Installed.Contains($name)) {
        Confirm ((Get-Sha $path) -ceq $prior.Installed[$name]) "Restored installed file matches prior bytes: $name"
      } else {
        Confirm (-not (Test-Path -LiteralPath $path)) "Restoration removes successor-only installer file: $name"
      }
    }
    $retry = Start-Exact $command.Image $retryCwd @() -RawArguments $command.RawArguments
    Confirm ($retry.Process.WaitForExit(30000) -and $retry.Process.ExitCode -eq 0 -and -not $app.Process.HasExited -and
      (Read-Phase $stage) -ceq 'recovered' -and (Get-Sha $target) -ceq $prior.Executable -and
      (Read-Reg $runOnceKey $valueName).Value -ceq $command.Command) 'Repeated exact recovery is idempotent while the restored app is alive'
    Remove-ExactRunOnceAfterManualReplay $command.Command
    Confirm-Timer $app
    [void](Wait-For { -not (Test-Path -LiteralPath $stage) } 'restored app cleanup after the harness models Windows RunOnce deletion')
    Confirm (-not (Read-Reg $runOnceKey $valueName)) 'Recovery stage and exact registration are absent after modelled post-command removal'
    Confirm ([EbrRestartObservation]::Close($app.Process.Id) -and $app.Process.WaitForExit(10000)) 'Restored app exits normally'
    $report.Status = 'PASS'
  }
} catch {
  $report.Error = $_.Exception.ToString()
  throw
} finally {
  foreach ($entry in $ownerProcesses) {
    if (-not $entry.Process.HasExited) {
      try { $null = Stop-Owned $entry } catch { $report.ProcessCleanupError = $_.Exception.Message; $report.Status = 'FAIL' }
    }
  }
  $report.Assertions = $assertions.ToArray()
  if ($report.Status -ceq 'INTERRUPTED') {
    $report | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $handoff -Encoding utf8
  }
  [void][IO.Directory]::CreateDirectory((Split-Path -Parent $EvidencePath))
  $report | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $EvidencePath -Encoding utf8
}
