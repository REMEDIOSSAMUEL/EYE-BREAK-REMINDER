[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CandidateDirectory,
    [Parameter(Mandatory)][string]$EvidencePath
)

$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or
    $env:GITHUB_SERVER_URL -cne 'https://github.com' -or
    $env:GITHUB_REPOSITORY -ine 'REMEDIOSSAMUEL/EYE-BREAK-REMINDER' -or
    $env:RUNNER_OS -cne 'Windows' -or $env:RUNNER_ARCH -cne 'X64' -or
    [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64' -or
    $env:GITHUB_RUN_ID -notmatch '^[0-9]+$' -or $env:GITHUB_RUN_ATTEMPT -notmatch '^[0-9]+$') {
    throw 'Run only in a fresh disposable GitHub-hosted Windows x64 job for this repository.'
}

function Assert-ChildPath([string]$Path, [string]$Root) {
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith([IO.Path]::GetFullPath($Root).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside the expected root: $full"
    }
    for ($part = $full; $part; $part = Split-Path -Parent $part) {
        if ((Test-Path -LiteralPath $part) -and
            ((Get-Item -LiteralPath $part -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Unexpected reparse point: $part"
        }
    }
    $full
}

function Get-Sha([string]$Path) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Assert-Fact([bool]$Condition, [string]$Fact) {
    if (-not $Condition) { throw $Fact }
}

function Wait-Observation([scriptblock]$Observe, [string]$Fact) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt 25) {
        $observed = & $Observe
        if ($null -ne $observed) { return $observed }
        Start-Sleep -Milliseconds 200
    }
    throw "Timed out: $Fact"
}

$EvidencePath = Assert-ChildPath $EvidencePath $env:GITHUB_WORKSPACE
$local = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
Assert-Fact ($local -and ([IO.Path]::GetFullPath($env:LOCALAPPDATA) -ieq $local)) 'Environment and known LocalAppData folder must match.'
$data = Assert-ChildPath (Join-Path $local 'EyeBreakReminder') $local
$runRoot = Assert-ChildPath (Join-Path $env:RUNNER_TEMP "ebr-manual-$($env:GITHUB_RUN_ID)-$($env:GITHUB_RUN_ATTEMPT)") $env:RUNNER_TEMP
$productKey = 'Software\EyeBreakReminder'
$uninstallKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder'
$runOnceKey = 'Software\Microsoft\Windows\CurrentVersion\RunOnce'
$recoveryValue = '!EyeBreakReminderUpdateRecovery'
$startupKey = 'Software\Microsoft\Windows\CurrentVersion\Run'
$registry = [Microsoft.Win32.RegistryKey]::OpenBaseKey('CurrentUser', 'Registry64')
function Read-Value([string]$Key, [string]$Name) {
    $opened = $registry.OpenSubKey($Key)
    if ($opened) {
        try { $opened.GetValue($Name) } finally { $opened.Dispose() }
    }
}

Assert-Fact (-not (Test-Path -LiteralPath $data) -and -not (Test-Path -LiteralPath $runRoot) -and
    -not (Test-Path -LiteralPath "HKCU:\$productKey") -and -not (Test-Path -LiteralPath "HKCU:\$uninstallKey") -and
    -not (Read-Value $runOnceKey $recoveryValue) -and -not (Read-Value $startupKey 'EyeBreakReminder') -and
    -not (Get-Process -Name EyeBreakReminder -ErrorAction SilentlyContinue)) 'Disposable account must have no prior installation, data, processes, or registrations.'

$expected = [ordered]@{
    'EyeBreakReminder.exe' = '3dd3fa4c8e9f6200780c7bf0c2340435c7b127ce6b6202b24857105f01f3719a'
    'EyeBreakReminder-Setup-x64.exe' = '7df5c6f61cbb56d813e4eee989637e6fcf692d1879f1446d4776da5928e49c2a'
    'EyeBreakReminder-Portable-x64.zip' = '9337550cf5a2fc2b685672205654d8c674fb8440b01a0ce97c8762bd065f6341'
    'EyeBreakReminder-Source.zip' = 'c8971b3d32b8aad2bf634e40cf753f33b2430f7167effd93063c578e0e05480c'
    'EyeBreakReminder-SHA256.txt' = 'ae6032f9810e7362a27a0b0b15405537aab4ff2fb7ce6efc3c4e97b42e7796df'
    'EyeBreakReminder-UpdateManifest.json' = '88ec256d6c4bb8f0c52946b947cf8778e0966f8cfe84c9f83c551f9a61af84a6'
    'EyeBreakReminder-UpdateManifest.sig' = 'c0906144d52623a4d428df0d69208a849102df731877bbcdb9d366d1f4031992'
}
$observed = [ordered]@{}
foreach ($name in $expected.Keys) {
    $path = Join-Path $CandidateDirectory $name
    $root = if ([IO.Path]::GetFullPath($path).StartsWith([IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        $env:RUNNER_TEMP
    } else { $env:GITHUB_WORKSPACE }
    $path = Assert-ChildPath $path $root
    $observed[$name] = Get-Sha $path
    Assert-Fact ($observed[$name] -ceq $expected[$name]) "Candidate hash mismatch: $name"
}
$setup = [IO.Path]::GetFullPath((Join-Path $CandidateDirectory 'EyeBreakReminder-Setup-x64.exe'))
$install = Join-Path $runRoot 'installed'
$exe = Join-Path $install 'EyeBreakReminder.exe'
$utf8 = [Text.UTF8Encoding]::new($false)
$os = Get-CimInstance Win32_OperatingSystem

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class EbrManualRepairWindow
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr FindWindow(string className, string title);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint owner);

    [DllImport("user32.dll")]
    private static extern IntPtr GetDlgItem(IntPtr window, int controlId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr SendMessageTimeout(IntPtr window, uint message, UIntPtr capacity,
        StringBuilder text, uint flags, uint timeout, out UIntPtr result);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern uint RegisterWindowMessage(string name);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

    private static IntPtr OwnedWindow(int pid)
    {
        var window = FindWindow("EyeBreakReminder.Native", "Eye Break Reminder");
        return window != IntPtr.Zero && GetWindowThreadProcessId(window, out uint owner) != 0
            && owner == (uint)pid ? window : IntPtr.Zero;
    }

    public static bool Close(int pid)
    {
        var window = OwnedWindow(pid);
        return window != IntPtr.Zero && PostMessage(window,
            RegisterWindowMessage("EyeBreakReminder.Exit.Native.1"), IntPtr.Zero, IntPtr.Zero);
    }

    public static string Countdown(int pid)
    {
        var window = OwnedWindow(pid);
        if (window == IntPtr.Zero) return "";
        var countdown = GetDlgItem(window, 40);
        if (countdown == IntPtr.Zero) return "";
        var text = new StringBuilder(32);
        return SendMessageTimeout(countdown, 13, (UIntPtr)text.Capacity, text, 2, 750,
            out _) != IntPtr.Zero ? text.ToString() : "";
    }
}
"@

function Invoke-Setup {
    Assert-Fact ((Get-Sha $setup) -ceq $expected['EyeBreakReminder-Setup-x64.exe']) 'Setup changed before execution.'
    $process = Start-Process -FilePath $setup -ArgumentList "/S /D=$install" -WindowStyle Hidden -PassThru
    Assert-Fact ($process.WaitForExit(60000) -and $process.ExitCode -eq 0) 'Ordinary setup failed or timed out.'
}

function Observe-Countdown($AppProcess) {
    Wait-Observation {
        if ($AppProcess.HasExited) { throw "Installed application exited: $($AppProcess.ExitCode)" }
        $value = [EbrManualRepairWindow]::Countdown($AppProcess.Id)
        if ($value -match '^(\d{1,2}):(\d\d)$') { [int]$Matches[1] * 60 + [int]$Matches[2] }
    } 'Countdown control in the owned application window'
}

$report = [ordered]@{
    Status = 'FAIL'
    RunId = $env:GITHUB_RUN_ID
    Commit = $env:GITHUB_SHA
    OS = $os.Caption
    OSBuild = $os.BuildNumber
    CandidateArtifactId = 15007651099
    CandidateSourceCommit = '0f49949a9e753fcca390c25affc99d7698b1ecde'
    CandidateFileSha256 = $observed
    Procedure = 'Ordinary per-user NSIS setup, silent wizard invocation targeting the existing installation directory'
    GenuineInterruptedUpdate = $false
    GenuineRebootOrSignIn = $false
    PendingRunOnceOrTransaction = $false
    Cases = @()
}

$app = $null
try {
    [void][IO.Directory]::CreateDirectory($runRoot)
    Invoke-Setup
    Assert-Fact ((Get-Sha $exe) -ceq $expected['EyeBreakReminder.exe']) 'Baseline setup did not install the exact executable.'
    [void][IO.Directory]::CreateDirectory($data)
    $paths = [ordered]@{
        Settings = Join-Path $data 'settings.ini'
        History = Join-Path $data 'history.dat'
        UnrelatedData = Join-Path $data 'manual-repair-sentinel.txt'
        UnrelatedInstall = Join-Path $install 'manual-repair-sentinel.txt'
        Timer = Join-Path $data 'timer.dat'
    }
    $profileSettings = @('workMinutes=37', 'breakSeconds=33', 'theme=2', 'alarm=0',
        'notifications=0', 'autoStart=1', 'startup=0', 'history=1', 'schedule=0',
        'autoCheckUpdates=0', 'autoDownloadUpdates=0', 'restore=1')
    $image = [IO.File]::ReadAllBytes((Join-Path $CandidateDirectory 'EyeBreakReminder.exe'))
    foreach ($scenario in @('MissingExecutable', 'CorruptExecutable', 'TruncatedExecutable')) {
        $case = [ordered]@{ Scenario = $scenario; Status = 'FAIL' }
        $report.Cases += $case
        try {
            $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            [IO.File]::WriteAllLines($paths.Settings, $profileSettings, $utf8)
            [IO.File]::WriteAllText($paths.History, "$($now - 120) 1 20" + [char]10, $utf8)
            [IO.File]::WriteAllText($paths.Timer, "0 0 420 2220 7 $now", $utf8)
            [IO.File]::WriteAllText($paths.UnrelatedData, [guid]::NewGuid().ToString('D'), $utf8)
            [IO.File]::WriteAllText($paths.UnrelatedInstall, [guid]::NewGuid().ToString('D'), $utf8)
            $case.Before = [ordered]@{}
            foreach ($name in $paths.Keys) { $case.Before[$name] = Get-Sha $paths[$name] }
            Assert-Fact ((Get-Sha $exe) -ceq $expected['EyeBreakReminder.exe']) 'Exact pre-fault executable required.'
            Assert-Fact ((Read-Value $productKey 'InstallDir') -ieq $install) 'Existing per-user installation registration required.'
            switch ($scenario) {
                'MissingExecutable' { Remove-Item -LiteralPath $exe }
                'CorruptExecutable' { [IO.File]::WriteAllText($exe, 'Corrupt executable repair fixture', $utf8) }
                'TruncatedExecutable' { [IO.File]::WriteAllBytes($exe, [byte[]]$image[0..4095]) }
            }
            $case.DamagedHash = Get-Sha $exe
            $case.DamagedLength = if (Test-Path -LiteralPath $exe) { (Get-Item -LiteralPath $exe).Length } else { 0 }
            Assert-Fact ($case.DamagedHash -cne $expected['EyeBreakReminder.exe']) 'Expected failure condition was not reached.'
            Assert-Fact (($scenario -ceq 'MissingExecutable') -eq (-not (Test-Path -LiteralPath $exe))) 'Executable presence does not match the failure fixture.'

            Invoke-Setup
            $case.RepairedHash = Get-Sha $exe
            $case.ProductVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($exe).ProductVersion
            $case.RegisteredVersion = Read-Value $uninstallKey 'DisplayVersion'
            $case.RecoveryRegistration = Read-Value $runOnceKey $recoveryValue
            $case.UpdatesDirectoryExists = Test-Path -LiteralPath (Join-Path $data 'updates')
            Assert-Fact ($case.RepairedHash -ceq $expected['EyeBreakReminder.exe'] -and $case.ProductVersion -match '^1\.4\.0(\.0)?$' -and
                $case.RegisteredVersion -eq '1.4.0' -and (Read-Value $productKey 'InstallDir') -ieq $install) 'Installed image, version, or registration did not match the exact candidate.'
            Assert-Fact (-not $case.RecoveryRegistration -and -not $case.UpdatesDirectoryExists) 'Plain reinstall created unexpected recovery state.'
            $case.AfterSetup = [ordered]@{}
            foreach ($name in $paths.Keys) { $case.AfterSetup[$name] = Get-Sha $paths[$name] }
            $case.TimerCheckpointPreserved = $case.Before.Timer -ceq $case.AfterSetup.Timer
            foreach ($name in @('Settings', 'History', 'UnrelatedData', 'UnrelatedInstall')) {
                Assert-Fact ($case.Before[$name] -ceq $case.AfterSetup[$name]) "Reinstall changed $name."
            }

            $app = Start-Process -FilePath $exe -WorkingDirectory $install -PassThru
            $case.Pid = $app.Id
            $case.CountdownBeforeSeconds = Observe-Countdown $app
            $case.CountdownAfterSeconds = Wait-Observation {
                if ($app.HasExited) { throw "Installed application exited: $($app.ExitCode)" }
                $value = [EbrManualRepairWindow]::Countdown($app.Id)
                if ($value -match '^(\d{1,2}):(\d\d)$') {
                    $seconds = [int]$Matches[1] * 60 + [int]$Matches[2]
                    if ($seconds -lt $case.CountdownBeforeSeconds) { $seconds }
                }
            } 'Native countdown advancement'
            Assert-Fact ([EbrManualRepairWindow]::Close($app.Id) -and $app.WaitForExit(10000) -and $app.ExitCode -eq 0) 'Installed app did not exit through its owned window.'
            $app.Dispose()
            $app = $null
            $case.Status = 'PASS'
        } catch {
            $case.Error = $_.Exception.Message
            throw
        }
    }
    $report.Status = 'PASS'
} finally {
    if ($app) {
        try {
            if (-not $app.HasExited) { $app.Kill(); [void]$app.WaitForExit(5000) }
        } finally { $app.Dispose() }
    }
    $registry.Dispose()
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $EvidencePath))
    $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $EvidencePath -Encoding UTF8
}
