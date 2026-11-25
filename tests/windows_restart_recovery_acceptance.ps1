[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateSet('Interrupt','Recover')][string]$Phase,
  [Parameter(Mandatory)][string]$CandidateDirectory,
  [Parameter(Mandatory)][string]$CandidateExecutable,
  [Parameter(Mandatory)][string]$SuccessorInstaller,
  [Parameter(Mandatory)][string]$SuccessorExecutable,
  [Parameter(Mandatory)][string]$SignatureTool,
  [Parameter(Mandatory)][string]$EvidencePath,
  [ValidateSet('Short','Long')][string]$PathLayout = 'Short'
)

$ErrorActionPreference = 'Stop'
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
  if (-not $full.StartsWith([IO.Path]::GetFullPath($Root).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
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
$testRoot = Assert-Child (Join-Path $runnerTemp "ebr-r-$($env:GITHUB_RUN_ID)-$($env:GITHUB_RUN_ATTEMPT)-$PathLayout") $runnerTemp
$EvidencePath = Assert-Child $EvidencePath $workspace
$handoff = Join-Path $testRoot 'handoff.json'
$installName = if ($PathLayout -ceq 'Long') { 'installed-' + [char]0x00C5 + '-' + ('x' * 48) } else { 'installed' }
$install = Join-Path $testRoot $installName
$target = Join-Path $install 'EyeBreakReminder.exe'
$localAppData = [Environment]::GetFolderPath('LocalApplicationData')
if (-not $localAppData -or [IO.Path]::GetFullPath($localAppData) -ine [IO.Path]::GetFullPath($env:LOCALAPPDATA)) {
  throw 'Disposable runner LocalAppData and its Known Folder differ.'
}
$data = Assert-Child (Join-Path $localAppData 'EyeBreakReminder') $localAppData
$retryCwd = Join-Path $testRoot 'fresh working directory'
$runOnceKey = 'Software\Microsoft\Windows\CurrentVersion\RunOnce'
$valueName = '!EyeBreakReminderUpdateRecovery'
$productKey = 'Software\EyeBreakReminder'
$uninstallKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder'
$startupKey = 'Software\Microsoft\Windows\CurrentVersion\Run'
$startupCommand = '"' + $target + '" --startup'
$profileNames = @('settings.ini', 'timer.dat', 'history.dat')
$retainHistory = $PathLayout -ceq 'Long'
$deletedByClean = if ($retainHistory) { $profileNames[0..1] } else { $profileNames }
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

function Confirm-Backups([string]$Stage, $Prior) {
  $transaction = @{}
  foreach ($line in [IO.File]::ReadAllLines((Join-Path $Stage 'transaction.ini'))) {
    $key, $value = $line -split '=', 2
    if ($key) { $transaction[$key] = $value }
  }
  Confirm ($transaction.backupMask -ceq '7' -and $transaction.ownedFileMask -ceq '15') 'All prior files have persisted backup metadata'
  $previousHash = Get-Sha (Join-Path $Stage 'previous.exe')
  Confirm ($previousHash -ceq $Prior.Executable -and $previousHash -ceq $transaction.previousSha256) 'Previous executable backup matches original and metadata' $previousHash
  for ($i = 0; $i -lt $profileNames.Count; $i++) {
    $name = $profileNames[$i]
    $hash = Get-Sha (Join-Path $Stage "backup-$i.dat")
    Confirm ($hash -ceq $Prior.Profile[$name] -and $hash -ceq $transaction["backupSha256$i"]) "Profile backup $name matches original and metadata" $hash
  }
  for ($i = 0; $i -lt $installedNames.Count; $i++) {
    $name = $installedNames[$i]
    $hash = Get-Sha (Join-Path $Stage "previous-owned-$i.dat")
    Confirm ($hash -ceq $Prior.Installed[$name] -and $hash -ceq $transaction["ownedFileSha256$i"]) "Installed-file backup $name matches original and metadata" $hash
  }
}

function New-Transaction([string]$Stage, [int]$PreviousProcessId) {
  [void][IO.Directory]::CreateDirectory($Stage)
  $helper = Join-Path $Stage 'coordinator.exe'
  $setup = Join-Path $Stage 'EyeBreakReminder-Setup-x64.exe'
  $portable = Join-Path $Stage 'EyeBreakReminder.exe'
  Copy-Item -LiteralPath $CandidateExecutable -Destination $helper
  Copy-Item -LiteralPath $SuccessorInstaller -Destination $setup
  Copy-Item -LiteralPath $SuccessorExecutable -Destination $portable
  # The signer uses a narrow-character entry point. Keep its command paths ASCII,
  # then copy the resulting bytes into the real Unicode transaction directory.
  $signingStage = Join-Path $testRoot 'signing'
  [void][IO.Directory]::CreateDirectory($signingStage)
  $signingSetup = Join-Path $signingStage 'EyeBreakReminder-Setup-x64.exe'
  $signingPortable = Join-Path $signingStage 'EyeBreakReminder.exe'
  Copy-Item -LiteralPath $setup -Destination $signingSetup
  Copy-Item -LiteralPath $portable -Destination $signingPortable
  & $SignatureTool --sign-update-manifest $signingStage $signingSetup $signingPortable | Out-Host
  if ($LASTEXITCODE -ne 0) { throw 'The disposable CNG manifest signer failed.' }
  foreach ($name in 'EyeBreakReminder-UpdateManifest.json','EyeBreakReminder-UpdateManifest.sig','test-update-public-key.bin') {
    Copy-Item -LiteralPath (Join-Path $signingStage $name) -Destination $Stage
  }

  $metadata = [ordered]@{
    staging = $Stage; artifact = $setup; target = $target; data = $data
    version = '1.4.1'; previous = '1.4.0'; nonce = [guid]::NewGuid().ToString('D')
    kind = 'installed'; name = 'EyeBreakReminder-Setup-x64.exe'
    sha256 = Get-Sha $setup; applicationSha256 = Get-Sha $portable
    previousSha256 = Get-Sha $target; size = (Get-Item -LiteralPath $setup).Length
    backupMask = 0; ownedFileMask = 0; pid = $PreviousProcessId
    clean = 1; deleteHistory = [int](-not $retainHistory); dark = 0; forcedColors = 0; previousStartup = 1
  }
  for ($i = 0; $i -lt 3; $i++) { $metadata["backupSha256$i"] = '' }
  for ($i = 0; $i -lt 4; $i++) { $metadata["ownedFileSha256$i"] = '' }
  $lines = @(foreach ($entry in $metadata.GetEnumerator()) { "$($entry.Key)=$($entry.Value)" })
  $transaction = Join-Path $Stage 'transaction.ini'
  [IO.File]::WriteAllText($transaction, ($lines -join [char]10) + [char]10, $utf8)
  return $transaction
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

function Confirm-Timer($Entry) {
  $id = $Entry.Process.Id
  $first = Wait-For {
    $value = [EbrRestartObservation]::Countdown($id)
    if ($value -match '^(\d{1,2}):(\d\d)$' -and ([int]$Matches[1] * 60 + [int]$Matches[2]) -le $seedCountdownSeconds) { $value }
  } 'owned native timer with distinct checkpoint'
  $second = Wait-For {
    $value = [EbrRestartObservation]::Countdown($id)
    if ($value -match '^\d{1,2}:\d\d$' -and $value -ne $first) { $value }
  } 'timer advancement'
  $before = [int]($first -split ':')[0] * 60 + [int]($first -split ':')[1]
  $after = [int]($second -split ':')[0] * 60 + [int]($second -split ':')[1]
  Confirm ($after -lt $before -and $before -le $seedCountdownSeconds) 'Application loads the distinct seeded timer checkpoint and its countdown advances' (
    @{ Pid = $id; SeedSeconds = $seedCountdownSeconds; Before = $first; After = $second })
}

$report = [ordered]@{
  Status = 'FAIL'; Phase = $Phase; RunId = $env:GITHUB_RUN_ID; Commit = $env:GITHUB_SHA
  Runner = $env:ImageOS; OS = $os.Caption; OSBuild = $os.BuildNumber; UserSid = $sid; SessionId = $sessionId; BootUtc = $boot
  HarnessPid = $PID; HarnessStartUtc = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
  GenuineWindowsReboot = $false; WindowsSignInInvocation = $false
  Scenario = 'Signed test-key installed clean update with selected history policy and repeated recovery interruption'
  RetainHistory = $retainHistory
  RecoveryInterruptionMode = if ($PathLayout -ceq 'Long') { 'Recovery helper killed; restored application survives for retry' } else { 'Recovery helper and restored application killed before retry' }
  PathLayoutScope = 'Production-shaped LocalAppData staging. The Long layout varies the installed executable path.'
  CandidateArtifactId = 14695418078
}
try {
  $CandidateExecutable = Assert-Child $CandidateExecutable $workspace
  $SuccessorInstaller = Assert-Child $SuccessorInstaller $runnerTemp
  $SuccessorExecutable = Assert-Child $SuccessorExecutable $runnerTemp
  $SignatureTool = Assert-Child $SignatureTool $workspace
  $candidateSetup = [IO.Path]::GetFullPath((Join-Path $CandidateDirectory 'EyeBreakReminder-Setup-x64.exe'))
  $candidateApp = [IO.Path]::GetFullPath((Join-Path $CandidateDirectory 'EyeBreakReminder.exe'))
  if ($candidateSetup.StartsWith($runnerTemp.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    $candidateSetup = Assert-Child $candidateSetup $runnerTemp
    $candidateApp = Assert-Child $candidateApp $runnerTemp
  } else {
    $candidateSetup = Assert-Child $candidateSetup $workspace
    $candidateApp = Assert-Child $candidateApp $workspace
  }
  $report.Fixtures = [ordered]@{
    CandidateSetup = Get-Sha $candidateSetup; CandidateApplication = Get-Sha $candidateApp
    TestBaseline = Get-Sha $CandidateExecutable; TestSetup = Get-Sha $SuccessorInstaller
    TestSuccessor = Get-Sha $SuccessorExecutable; TestSigningTool = Get-Sha $SignatureTool
  }
  Confirm ($report.Fixtures.CandidateSetup -ceq 'a15fc525557603dbed1ef0dccb8d128e500dfee91c6416b478513de790dd5c9b' -and
    $report.Fixtures.CandidateApplication -ceq '07f6c1eaee5818df9f5c024310883ca94b8274a4f451186a8123974fb5e5f720') 'Baseline setup and application match the retained production candidate'
  Confirm ($report.Fixtures.TestBaseline -cne $report.Fixtures.CandidateApplication -and
    (Get-Item -LiteralPath $CandidateExecutable).VersionInfo.ProductVersion -match '^1\.4\.0(\.0)?$' -and
    (Get-Item -LiteralPath $SuccessorExecutable).VersionInfo.ProductVersion -match '^1\.4\.1(\.0)?$' -and
    (Get-Item -LiteralPath $SuccessorInstaller).VersionInfo.ProductVersion -match '^1\.4\.1(\.0)?$') 'Interruption uses distinct v1.4.0 and v1.4.1 test-key fixtures'

  if ($Phase -ceq 'Interrupt') {
    $knownData = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'EyeBreakReminder'
    if ((Test-Path -LiteralPath $testRoot) -or (Test-Path -LiteralPath $knownData) -or
        (Read-Reg $runOnceKey $valueName) -or (Read-Reg $startupKey 'EyeBreakReminder') -or
        (Read-Reg $productKey 'InstallDir') -or (Read-Reg $uninstallKey 'DisplayName') -or
        (Get-Process -Name EyeBreakReminder,coordinator -ErrorAction SilentlyContinue)) {
      throw 'Disposable runner already contains application state or processes.'
    }
    [void][IO.Directory]::CreateDirectory($install)
    [void][IO.Directory]::CreateDirectory($data)
    [void][IO.Directory]::CreateDirectory($retryCwd)
    $setup = Start-Exact $candidateSetup $testRoot @() -RawArguments "/S /D=$install"
    Confirm ($setup.Process.WaitForExit(120000) -and $setup.Process.ExitCode -eq 0 -and
      (Get-Sha $target) -ceq $report.Fixtures.CandidateApplication -and
      (Read-Reg $productKey 'InstallDir').Value -ieq $install) 'Real candidate installer creates the disposable baseline'
    Copy-Item -LiteralPath $CandidateExecutable -Destination $target -Force
    $settingsText = @(
      'workMinutes=37', 'breakSeconds=33', 'volume=32', 'theme=2', 'alarm=0',
      'notifications=0', 'autoStart=1', 'startup=1', 'history=1', 'breakModeColors=1',
      'customWorkAccent=1', 'workAccentColor=3900150', 'customBreakAccent=1', 'breakAccentColor=16746496',
      'schedule=0', 'autoCheckUpdates=0', 'autoDownloadUpdates=0', 'updateLastCheck=0', 'restore=1'
    )
    [IO.File]::WriteAllText((Join-Path $data 'settings.ini'), ($settingsText -join [char]10) + [char]10, $utf8)
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
      $previous.Process.ExitCode -eq 0) 'Verified baseline exits through its actual shutdown path'
    $prior = [ordered]@{ Executable = $report.Fixtures.TestBaseline; Profile = @{}; Installed = @{}; Neighbor = Get-Sha $neighbor }
    foreach ($name in $profileNames) { $prior.Profile[$name] = Get-Sha (Join-Path $data $name) }
    foreach ($name in $installedNames) { $prior.Installed[$name] = Get-Sha (Join-Path $install $name) }
    $stage = Join-Path (Join-Path $data 'updates') ([guid]::NewGuid().ToString('B'))
    $transaction = New-Transaction $stage $previous.Process.Id
    $coordinator = Start-Exact (Join-Path $stage 'coordinator.exe') $stage @('--update-coordinator',$transaction) -TestEnvironment @{ EBR_GUI_TEST_HOLD_AFTER_CLEAN_MS = '30000' }
    [void](Wait-For {
      (Read-Phase $stage) -ceq 'cleaning' -and
      @($deletedByClean | Where-Object { Test-Path -LiteralPath (Join-Path $data $_) }).Count -eq 0 -and
      $null -eq (Read-Reg $startupKey 'EyeBreakReminder')
    } 'post-clean installation state')
    Confirm ((Get-Sha $target) -ceq $report.Fixtures.TestSuccessor -and
      (Read-Reg $uninstallKey 'DisplayVersion').Value -ceq '1.4.1' -and
      @($deletedByClean | Where-Object { Test-Path -LiteralPath (Join-Path $data $_) }).Count -eq 0 -and
      (-not $retainHistory -or (Get-Sha (Join-Path $data 'history.dat')) -ceq $prior.Profile['history.dat'])) 'Actual successor installation applies only the selected clean policy'
    $command = Read-RunOnceCommand $stage
    Confirm-Backups $stage $prior
    $killed = Stop-Owned $coordinator
    Confirm ((Read-Phase $stage) -ceq 'cleaning' -and
      $null -eq (Find-TransactionProcesses $stage)) 'Forced coordinator loss leaves cleaning journal and no exact updater, installer or application process' $killed
    $report.Handoff = [ordered]@{
      Stage = $stage; Command = $command.Command; Original = $prior
      JournalSHA256 = Get-Sha (Join-Path $stage 'transaction-state.ini')
      TransactionSHA256 = Get-Sha $transaction
      ManifestSHA256 = Get-Sha (Join-Path $stage 'EyeBreakReminder-UpdateManifest.json')
      SignatureSHA256 = Get-Sha (Join-Path $stage 'EyeBreakReminder-UpdateManifest.sig')
      TestPublicKeySHA256 = Get-Sha (Join-Path $stage 'test-update-public-key.bin')
    }
    $report.Status = 'INTERRUPTED'
  } else {
    $interruption = Get-Content -LiteralPath $handoff -Raw | ConvertFrom-Json -AsHashtable
    $report.Interruption = $interruption
    Confirm ($interruption.Status -ceq 'INTERRUPTED' -and $interruption.RunId -ceq $env:GITHUB_RUN_ID -and
      $interruption.Commit -ceq $env:GITHUB_SHA -and $interruption.UserSid -ceq $sid -and
      $interruption.SessionId -eq $sessionId -and $interruption.BootUtc -ceq $boot -and
      $interruption.HarnessPid -ne $PID -and -not (Get-Process -Id $interruption.HarnessPid -ErrorAction SilentlyContinue)) 'Fresh harness runs after original harness exit in the same user session and boot'
    $stage = Assert-Child $interruption.Handoff.Stage (Join-Path $data 'updates')
    $prior = $interruption.Handoff.Original
    $command = Read-RunOnceCommand $stage
    Confirm ((Read-Phase $stage) -ceq 'cleaning' -and $command.Command -ceq $interruption.Handoff.Command -and
      (Get-Sha (Join-Path $stage 'transaction-state.ini')) -ceq $interruption.Handoff.JournalSHA256 -and
      (Get-Sha (Join-Path $stage 'transaction.ini')) -ceq $interruption.Handoff.TransactionSHA256 -and
      (Get-Sha (Join-Path $stage 'EyeBreakReminder-UpdateManifest.json')) -ceq $interruption.Handoff.ManifestSHA256 -and
      (Get-Sha (Join-Path $stage 'EyeBreakReminder-UpdateManifest.sig')) -ceq $interruption.Handoff.SignatureSHA256 -and
      (Get-Sha (Join-Path $stage 'test-update-public-key.bin')) -ceq $interruption.Handoff.TestPublicKeySHA256 -and
      (Get-Sha $target) -ceq $report.Fixtures.TestSuccessor -and
      $null -eq (Find-TransactionProcesses $stage)) 'Persisted journal, metadata, trust material and installed successor survive original process loss'
    Confirm ((Get-Sha $command.Image) -ceq $report.Fixtures.TestBaseline) 'Registered helper is the recorded test baseline image'
    $targetBefore = Get-Sha $target
    $journal = Join-Path $stage 'transaction-state.ini'
    $transaction = Join-Path $stage 'transaction.ini'
    $uninstallerBefore = Get-Sha (Join-Path $install 'Uninstall.exe')
    $timer = Join-Path $data 'timer.dat'
    foreach ($mode in 'ChangedLiveSettings','ChangedLiveHistory','MissingSettingsBackup','MissingHistoryBackup','CorruptSettingsBackup','CorruptHistoryBackup') {
      $index = if ($mode.EndsWith('Settings') -or $mode.EndsWith('SettingsBackup')) { 0 } else { 2 }
      $live = Join-Path $data $profileNames[$index]
      $backup = Join-Path $stage "backup-$index.dat"
      $originalBackup = [IO.File]::ReadAllBytes($backup)
      $backupBefore = Get-Sha $backup
      $changedLiveHash = $null
      $newValue = if ($index -eq 0) { "workMinutes=63`nhistory=1`n" } else { "$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) 1 40`n" }
      $originalLive = if ($retainHistory -and $index -eq 2) { [IO.File]::ReadAllBytes($live) }
      Confirm (($null -ne $originalLive -and (Get-Sha $live) -ceq $backupBefore) -or
        ($null -eq $originalLive -and -not (Test-Path -LiteralPath $live))) "Expected original interrupted clean state: $mode"
      try {
        if ($mode.StartsWith('Changed')) {
          [IO.File]::WriteAllText($live, $newValue, $utf8)
          $changedLiveHash = Get-Sha $live
          Confirm ($changedLiveHash -cne $backupBefore) "Induced distinct live data: $mode"
        } elseif ($mode.StartsWith('Missing')) {
          [IO.File]::Delete($backup)
          Confirm (-not (Test-Path -LiteralPath $backup)) "Induced missing saved data: $mode"
        } else {
          [IO.File]::WriteAllText($backup, 'damaged fixture', $utf8)
          Confirm ((Get-Sha $backup) -cne $backupBefore) "Induced corrupt saved data: $mode"
        }
        $rejected = Start-Exact $command.Image $retryCwd @() -RawArguments $command.RawArguments
        [void](Wait-For {
          $rejected.Process.Refresh()
          -not $rejected.Process.HasExited -and $rejected.Process.MainWindowTitle -ceq 'Eye Break Reminder Recovery'
        } "real recovery deferral for $mode")
        Confirm ($rejected.Process.CloseMainWindow() -and $rejected.Process.WaitForExit(10000) -and $rejected.Process.ExitCode -eq 1) "Recovery explicitly deferred: $mode"
        Confirm ((Get-Sha $target) -ceq $targetBefore -and
          (Get-Sha (Join-Path $install 'Uninstall.exe')) -ceq $uninstallerBefore -and
          (Get-Sha $journal) -ceq $interruption.Handoff.JournalSHA256 -and
          (Get-Sha $transaction) -ceq $interruption.Handoff.TransactionSHA256 -and
          (Read-Reg $runOnceKey $valueName).Value -ceq $command.Command -and
          (Read-Reg $uninstallKey 'DisplayVersion').Value -ceq '1.4.1' -and
          (Get-Sha (Join-Path $data 'unrelated.txt')) -ceq $prior.Neighbor -and
          -not (Test-Path -LiteralPath $timer) -and $null -eq (Find-TransactionProcesses $stage)) "Deferral leaves executable, registration, journal and unrelated data unchanged: $mode"
        if ($changedLiveHash) {
          Confirm ((Get-Sha $live) -ceq $changedLiveHash -and (Get-Sha $backup) -ceq $backupBefore) "Both saved and different live data are intact: $mode"
        } else {
          Confirm (($null -ne $originalLive -and (Get-Sha $live) -ceq $backupBefore) -or
            ($null -eq $originalLive -and -not (Test-Path -LiteralPath $live))) "Deferral preserves the original live data state: $mode"
        }
      } finally {
        if ($mode.StartsWith('Changed')) {
          if ($null -ne $originalLive) { [IO.File]::WriteAllBytes($live, [byte[]]$originalLive) }
          else { [IO.File]::Delete($live) }
        }
        elseif ($mode.StartsWith('Missing') -or $mode.StartsWith('Corrupt')) {
          [IO.File]::WriteAllBytes($backup, $originalBackup)
        }
      }
      Confirm ((Get-Sha $backup) -ceq $backupBefore) "Control case starts from the original saved fixture: $mode"
    }
    $lockedPath = Join-Path $install 'Uninstall.exe'
    $lockedPathBefore = Get-Sha $lockedPath
    $lockedStream = [IO.File]::Open($lockedPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
      $lockedAttempt = Start-Exact $command.Image $retryCwd @() -RawArguments $command.RawArguments
      $lockedProcess = Wait-For {
        $entry = Get-CimInstance Win32_Process -Filter "ProcessId=$($lockedAttempt.Process.Id)"
        if ($entry.ExecutablePath -ieq $command.Image -and $entry.CommandLine -ceq $command.Command) { $entry }
      } 'locked-file recovery helper with the exact registered command'
      Confirm ($lockedProcess.ExecutablePath -ieq $command.Image -and $lockedProcess.CommandLine -ceq $command.Command) 'Locked-file retry starts only the registered helper and verbatim command' $lockedProcess.CommandLine
      [void](Wait-For { (Get-Sha $target) -ceq $prior.Executable } 'executable restoration before the locked owned-file boundary')
      $recoveryError = Wait-For {
        $process = Get-Process -Id $lockedAttempt.Process.Id -ErrorAction SilentlyContinue
        if ($process) { $process.Refresh(); if (-not $process.HasExited -and $process.MainWindowTitle -ceq 'Eye Break Reminder Recovery') { $process.MainWindowTitle } }
      } 'recovery error dialog after the locked installer-owned file blocks replacement'
      $displayVersion = (Read-Reg $uninstallKey 'DisplayVersion').Value
      $remainingProfileFiles = @($deletedByClean | Where-Object { Test-Path -LiteralPath (Join-Path $data $_) })
      Confirm ((Read-Phase $stage) -ceq 'cleaning' -and (Get-Sha $target) -ceq $prior.Executable -and
        (Get-Sha $lockedPath) -ceq $lockedPathBefore -and $remainingProfileFiles.Count -eq 0 -and
        (-not $retainHistory -or (Get-Sha (Join-Path $data 'history.dat')) -ceq $prior.Profile['history.dat']) -and
        $displayVersion -ceq '1.4.1' -and (Read-Reg $runOnceKey $valueName).Value -ceq $command.Command) 'Locked owned-file restore stops after executable rollback, preserves later files, data and exact retry registration' (
        @{ DialogTitle = $recoveryError; DisplayVersion = $displayVersion; Executable = Get-Sha $target; LockedOwnedFile = Get-Sha $lockedPath; RemainingProfileFiles = $remainingProfileFiles; RunOnce = $command.Command })
      Confirm-Backups $stage $prior
      $lockedTermination = Stop-Owned $lockedAttempt
      Confirm ($null -eq (Find-TransactionProcesses $stage) -and
        (Read-Phase $stage) -ceq 'cleaning' -and (Read-Reg $runOnceKey $valueName).Value -ceq $command.Command) 'Terminating the failed owned recovery helper retains the transaction for a later retry' $lockedTermination
    } finally {
      $lockedStream.Dispose()
    }
    Confirm ((Get-Sha $lockedPath) -ceq $lockedPathBefore) 'Releasing the disposable file lock leaves the prior successor-owned file unchanged'
    $first = Start-Exact $command.Image $retryCwd @() -RawArguments $command.RawArguments -TestEnvironment @{ EBR_GUI_TEST_SKIP_UPDATE_CONFIRM_VERSION = '1.4.0' }
    $firstProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$($first.Process.Id)"
    Confirm ($firstProcess.CommandLine -ceq $command.Command -and $firstProcess.ExecutablePath -ieq $command.Image) 'Renewed process receives the verbatim registered command' (
      @{ ProcessId = $first.Process.Id; CommandLine = $firstProcess.CommandLine; WorkingDirectory = $retryCwd })
    [void](Wait-For { (Read-Phase $stage) -ceq 'recovered' } 'persisted recovered state before startup confirmation')
    $restored = Wait-For { Find-OwnedTarget $first } 'previous application before its suppressed startup confirmation'
    $ownerProcesses.Add($restored)
    Confirm ((Get-Sha $target) -ceq $prior.Executable -and
      (Get-Sha (Join-Path $data 'settings.ini')) -ceq $prior.Profile['settings.ini'] -and
      (Get-Sha (Join-Path $data 'history.dat')) -ceq $prior.Profile['history.dat'] -and
      (Read-Reg $runOnceKey $valueName).Value -ceq $command.Command) 'Recovery restores prior bytes and keeps RunOnce pending during startup confirmation'
    $stoppedApp = $null
    if ($PathLayout -ceq 'Long') {
      Confirm-Timer $restored
      Confirm (-not $first.Process.HasExited) 'Recovery helper remains active after the restored application is ready and before test-only termination'
    }
    $stoppedRecovery = Stop-Owned $first
    if ($PathLayout -ceq 'Long') {
      $restored.Process.Refresh()
      $remaining = @(Find-TransactionProcesses $stage)
      Confirm (-not $restored.Process.HasExited -and $remaining.Count -eq 1 -and $remaining[0].ExecutablePath -ieq $target -and
        (Read-Phase $stage) -ceq 'recovered' -and (Read-Reg $runOnceKey $valueName).Value -ceq $command.Command) 'Recovery helper loss preserves the already-running restored app and retry registration'
    } else {
      $stoppedApp = Stop-Owned $restored
      Confirm ((Read-Phase $stage) -ceq 'recovered' -and (Read-Reg $runOnceKey $valueName).Value -ceq $command.Command -and
        $null -eq (Find-TransactionProcesses $stage)) 'Loss of recovery and every transaction process preserves retry state' (
        @{ Application = $stoppedApp; Recovery = $stoppedRecovery })
    }
    Confirm-Backups $stage $prior

    $retry = Start-Exact $command.Image $retryCwd @() -RawArguments $command.RawArguments
    Confirm ($retry.Process.WaitForExit(90000) -and $retry.Process.ExitCode -eq 0) 'Registered RunOnce command independently executed successfully without an operating-system restart.' (
      @{ RecoveryPid = $retry.Process.Id; Command = $command.Command })
    if ($PathLayout -ceq 'Long') {
      $app = $restored
    } else {
      $app = Wait-For { Find-OwnedTarget $retry } 'restored previous application'
      $ownerProcesses.Add($app)
    }
    Confirm (-not $app.Process.HasExited -and (Read-Phase $stage) -ceq 'recovered' -and
      (Get-Sha $target) -ceq $prior.Executable) 'Idempotent retry leaves the exact restored application running before post-command cleanup'
    Confirm ((Read-Reg $runOnceKey $valueName).Value -ceq $command.Command) 'Manual command execution leaves the exact !RunOnce value untouched; Windows did not dispatch this invocation'
    Remove-ExactRunOnceAfterManualReplay $command.Command
    Confirm ($null -eq (Read-Reg $runOnceKey $valueName)) 'Harness removes only that exact value to model post-command OS cleanup for stage-cleanup verification'
    $observed = @{
      Application = Get-Sha $target
      Settings = Get-Sha (Join-Path $data 'settings.ini')
      History = Get-Sha (Join-Path $data 'history.dat')
      Neighbor = Get-Sha (Join-Path $data 'unrelated.txt')
      DisplayVersion = (Read-Reg $uninstallKey 'DisplayVersion').Value
      Startup = (Read-Reg $startupKey 'EyeBreakReminder').Value
    }
    Confirm ($observed.Application -ceq $prior.Executable -and $observed.Settings -ceq $prior.Profile['settings.ini'] -and
      $observed.History -ceq $prior.Profile['history.dat'] -and $observed.Neighbor -ceq $prior.Neighbor -and
      $observed.DisplayVersion -ceq '1.4.0' -and $observed.Startup -ceq $startupCommand -and
      (Get-Item -LiteralPath $target).VersionInfo.ProductVersion -match '^1\.4\.0(\.0)?$' -and
      (Read-Reg $uninstallKey 'UninstallString').Value -ceq ('"' + (Join-Path $install 'Uninstall.exe') + '"')) 'Retry preserves prior executable, settings, history and installed/startup registrations' $observed
    foreach ($name in $installedNames) {
      $hash = Get-Sha (Join-Path $install $name)
      Confirm ($hash -ceq $prior.Installed[$name]) "Restored installed file $name matches baseline" $hash
    }
    Confirm-Timer $app
    [void](Wait-For { -not (Test-Path -LiteralPath $stage) } 'application cleanup of the recovery stage')
    Confirm ($null -eq (Read-Reg $runOnceKey $valueName)) 'After the harness models OS post-command removal, the app cleanup removes transaction backups'
    Confirm ([EbrRestartObservation]::Close($app.Process.Id) -and $app.Process.WaitForExit(10000)) 'Recovered application exits normally'
    $report.Status = 'PASS'
  }
} catch {
  $report.Error = $_.Exception.Message
  throw
} finally {
  foreach ($entry in $ownerProcesses) {
    if (-not $entry.Process.HasExited) {
      try { $null = Stop-Owned $entry } catch { $report.CleanupError = $_.Exception.Message; $report.Status = 'FAIL' }
    }
  }
  $report.Assertions = $assertions.ToArray()
  if ($report.Status -ceq 'INTERRUPTED') {
    $report | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $handoff -Encoding utf8
  }
  [void][IO.Directory]::CreateDirectory((Split-Path -Parent $EvidencePath))
  $report | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $EvidencePath -Encoding utf8
}
