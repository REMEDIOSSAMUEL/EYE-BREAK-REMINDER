param(
  [Parameter(Mandatory=$true)][string]$ExecutablePath,
  [Parameter(Mandatory=$true)][string]$EvidenceDirectory
)

$ErrorActionPreference = 'Stop'
$expectedSha256 = '07f6c1eaee5818df9f5c024310883ca94b8274a4f451186a8123974fb5e5f720'
$candidateArtifactId = '14695418078'
$candidateRunId = '44875679345'
$candidateSourceCommit = '491bd2ed29f84f4d434b884fc723144db2d6f294'

# This probe is deliberately restricted to the fresh, disposable GitHub-hosted
# Windows 11 ARM64 runner. It never installs the candidate and never edits a
# pre-existing EyeBreakReminder profile.
if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_OS -cne 'Windows' -or $env:RUNNER_ARCH -cne 'ARM64') {
  throw 'BLOCKED: this Narrator probe may run only on a GitHub-hosted Windows 11 ARM64 runner.'
}
if (-not $env:GITHUB_WORKSPACE -or -not $env:RUNNER_TEMP) {
  throw 'BLOCKED: GitHub workspace and runner temporary roots are required.'
}

$workspaceRoot = [IO.Path]::GetFullPath($env:GITHUB_WORKSPACE).TrimEnd('\') + '\'
$runnerTempRoot = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\') + '\'
$ExecutablePath = [IO.Path]::GetFullPath($ExecutablePath)
$EvidenceDirectory = [IO.Path]::GetFullPath($EvidenceDirectory)
if (-not ($ExecutablePath.StartsWith($workspaceRoot, [StringComparison]::OrdinalIgnoreCase) -or $ExecutablePath.StartsWith($runnerTempRoot, [StringComparison]::OrdinalIgnoreCase))) {
  throw 'BLOCKED: the candidate must be staged inside the GitHub workspace or runner temporary directory.'
}
if (-not ($EvidenceDirectory.StartsWith($workspaceRoot, [StringComparison]::OrdinalIgnoreCase) -or $EvidenceDirectory.StartsWith($runnerTempRoot, [StringComparison]::OrdinalIgnoreCase))) {
  throw 'BLOCKED: evidence must be written inside the GitHub workspace or runner temporary directory.'
}

[void][IO.Directory]::CreateDirectory($EvidenceDirectory)
$resultPath = Join-Path $EvidenceDirectory 'gui-016-narrator-speech-recap.json'
$transcriptPath = Join-Path $EvidenceDirectory 'gui-016-narrator-speech.txt'
$logPath = Join-Path $EvidenceDirectory 'gui-016-narrator-speech.log'
$scriptTranscriptStarted = $false
$candidateProcess = $null
$candidatePid = 0
$candidateOwned = $false
$candidateStoppedByHarness = $false
$narratorProcess = $null
$narratorPid = 0
$narratorOwned = $false
$narratorStoppedByHarness = $false
$dataDirectory = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'EyeBreakReminder'))
$localAppDataRoot = [IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd('\') + '\'
$dataExistedBefore = Test-Path -LiteralPath $dataDirectory
$dataCreatedByHarness = $false
$dataRemoved = $false
$cleanupErrors = [System.Collections.Generic.List[string]]::new()
$assertions = [System.Collections.Generic.List[object]]::new()
$focusTrace = [System.Collections.Generic.List[object]]::new()
$speechCaptures = [System.Collections.Generic.List[object]]::new()
$screenshots = [System.Collections.Generic.List[string]]::new()
$events = [System.Collections.Generic.List[object]]::new()
$status = 'BLOCKED'
$reason = 'Preflight did not complete.'
$osRecord = $null
$nativeCpuArchitecture = $null
$sessionId = $null
$candidateIdentity = $null
$narratorRecord = $null
$physicalAudioVerified = $false

function Add-Event([string]$Name, [string]$Status, $Details=$null) {
  $events.Add([pscustomobject]@{ Name=$Name; Status=$Status; Details=$Details; Utc=[DateTime]::UtcNow.ToString('o') })
}

function Add-Assertion([string]$Name, [bool]$Passed, $Details=$null) {
  $assertions.Add([pscustomobject]@{ Name=$Name; Passed=$Passed; Details=$Details; Utc=[DateTime]::UtcNow.ToString('o') })
  Add-Event $Name $(if ($Passed) { 'PASS' } else { 'NOT TESTED' }) $Details
}

function Get-FocusSnapshot([int]$CandidateProcessId, [string]$Phase) {
  $snapshot = [pscustomobject]@{
    Phase=$Phase; Utc=[DateTime]::UtcNow.ToString('o'); ProcessId=$null; IsCandidateProcess=$false
    Name=''; AutomationId=''; ControlType=''; ClassName=''; HasKeyboardFocus=$false
    IsKeyboardFocusable=$false; NativeWindowHandle=0; Bounds=$null; Error=$null
  }
  try {
    $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
    if ($null -eq $focused) { throw 'UI Automation returned no focused element.' }
    $current = $focused.Current
    $bounds = $current.BoundingRectangle
    $snapshot.ProcessId = [int]$current.ProcessId
    $snapshot.IsCandidateProcess = ($snapshot.ProcessId -eq $CandidateProcessId)
    $snapshot.Name = [string]$current.Name
    $snapshot.AutomationId = [string]$current.AutomationId
    $snapshot.ControlType = [string]$current.ControlType.ProgrammaticName
    $snapshot.ClassName = [string]$current.ClassName
    $snapshot.HasKeyboardFocus = [bool]$current.HasKeyboardFocus
    $snapshot.IsKeyboardFocusable = [bool]$current.IsKeyboardFocusable
    $snapshot.NativeWindowHandle = [int]$current.NativeWindowHandle
    $snapshot.Bounds = @([double]$bounds.Left, [double]$bounds.Top, [double]$bounds.Width, [double]$bounds.Height)
  } catch { $snapshot.Error = $_.Exception.Message }
  $focusTrace.Add($snapshot)
  return $snapshot
}

function Get-ControlElement([IntPtr]$MainWindow, [int]$ControlId, [string]$Description) {
  $handle = [EBR_NARRATOR_NATIVE]::FindVisibleChildById($MainWindow, $ControlId)
  if ($handle -eq [IntPtr]::Zero) { throw "The candidate did not expose visible control ID $ControlId ($Description)." }
  $element = [System.Windows.Automation.AutomationElement]::FromHandle($handle)
  if ($null -eq $element) { throw "UI Automation could not attach to candidate control ID $ControlId ($Description)." }
  $current = $element.Current
  if ($current.ProcessId -ne $candidatePid) { throw "Control ID $ControlId is owned by PID $($current.ProcessId), not candidate PID $candidatePid." }
  [pscustomobject]@{ Handle=$handle; Element=$element; Name=[string]$current.Name; AutomationId=[string]$current.AutomationId; ControlType=[string]$current.ControlType.ProgrammaticName; ClassName=[string]$current.ClassName; Enabled=[bool]$current.IsEnabled; Offscreen=[bool]$current.IsOffscreen; Bounds=@([double]$current.BoundingRectangle.Left,[double]$current.BoundingRectangle.Top,[double]$current.BoundingRectangle.Width,[double]$current.BoundingRectangle.Height) }
}

function Capture-CandidateWindow([IntPtr]$Window, [string]$FileName) {
  $bounds = [EBR_NARRATOR_NATIVE]::Bounds($Window)
  if ($bounds.Count -ne 4) { throw 'Could not obtain the candidate window rectangle for a target-window screenshot.' }
  $width = $bounds[2] - $bounds[0]
  $height = $bounds[3] - $bounds[1]
  if ($width -lt 100 -or $height -lt 100 -or $width -gt 5000 -or $height -gt 4000) { throw "Candidate window rectangle is not usable for a target-window screenshot: ${width}x${height}." }
  Add-Type -AssemblyName System.Drawing -ErrorAction Stop
  $bitmap = [Drawing.Bitmap]::new($width, $height)
  $graphics = [Drawing.Graphics]::FromImage($bitmap)
  $path = Join-Path $EvidenceDirectory $FileName
  try {
    # Crop to the candidate's HWND rectangle; do not capture the full desktop.
    $graphics.CopyFromScreen($bounds[0], $bounds[1], 0, 0, $bitmap.Size)
    $bitmap.Save($path, [Drawing.Imaging.ImageFormat]::Png)
  } finally { $graphics.Dispose(); $bitmap.Dispose() }
  $screenshots.Add($path)
  return [pscustomobject]@{ Path=$path; Width=$width; Height=$height; WindowBounds=$bounds; Capture='candidate window bounds only' }
}

function Wait-CandidateFocus([string]$Phase, [int]$TimeoutSeconds=5) {
  $watch = [Diagnostics.Stopwatch]::StartNew()
  $snapshot = $null
  while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
    $snapshot = Get-FocusSnapshot $candidatePid $Phase
    if ($snapshot.IsCandidateProcess) { return $snapshot }
    Start-Sleep -Milliseconds 100
  }
  return $snapshot
}

function Copy-NarratorLastPhrase([string]$ControlName, [string]$Phase) {
  $sentinel = '__EBR_NARRATOR_RECAP_' + [guid]::NewGuid().ToString('N')
  Set-Clipboard -Value $sentinel -ErrorAction Stop
  Start-Sleep -Milliseconds 150
  # Insert is Narrator's default modifier. Ctrl+X is Microsoft's documented
  # “Copy Last Phrase” command, which must replace this sentinel with fresh text.
  [EBR_NARRATOR_NATIVE]::KeyDown(0x2D) # VK_INSERT
  Start-Sleep -Milliseconds 40
  [EBR_NARRATOR_NATIVE]::KeyDown(0x11) # VK_CONTROL
  Start-Sleep -Milliseconds 40
  [EBR_NARRATOR_NATIVE]::KeyDown(0x58) # VK_X
  Start-Sleep -Milliseconds 40
  [EBR_NARRATOR_NATIVE]::KeyUp(0x58)
  [EBR_NARRATOR_NATIVE]::KeyUp(0x11)
  [EBR_NARRATOR_NATIVE]::KeyUp(0x2D)
  $watch = [Diagnostics.Stopwatch]::StartNew()
  $phrase = ''
  while ($watch.Elapsed.TotalSeconds -lt 5) {
    Start-Sleep -Milliseconds 150
    try { $phrase = [string](Get-Clipboard -Raw -ErrorAction Stop) } catch { $phrase = '' }
    if (-not [string]::IsNullOrWhiteSpace($phrase) -and $phrase -cne $sentinel) { break }
  }
  $phrase = ($phrase -replace '[\r\n\t]+', ' ').Trim()
  $capture = [pscustomobject]@{
    Phase=$Phase; TargetControl=$ControlName; Method='Narrator (Insert)+Ctrl+X Copy Last Phrase'
    Text=$phrase; SentinelReplaced=($phrase -and $phrase -cne $sentinel)
    FreshText=($phrase -and $phrase -cne $sentinel); CapturedUtc=[DateTime]::UtcNow.ToString('o')
  }
  $speechCaptures.Add($capture)
  return $capture
}

function Save-Result([string]$FinalStatus, [string]$FinalReason) {
  $result = [pscustomobject]@{
    Requirement='GUI-016'; Status=$FinalStatus; Reason=$FinalReason
    Candidate=[pscustomobject]@{
      ArtifactId=$candidateArtifactId; FinalizerRunId=$candidateRunId; SourceCommit=$candidateSourceCommit
      ExecutablePath=$ExecutablePath; SHA256=$expectedSha256; Identity=$candidateIdentity
      Execution='x64 candidate under Windows 11 ARM64 x64 emulation'; InstallerLaunched=$false
    }
    OperatingSystem=$osRecord; NativeCPUArchitecture=$nativeCpuArchitecture
    Environment=[pscustomobject]@{ Provider='GitHub-hosted Actions runner'; ImageOS=$env:ImageOS; ImageVersion=$env:ImageVersion; RunnerOS=$env:RUNNER_OS; RunnerArchitecture=$env:RUNNER_ARCH; ProcessSessionId=$sessionId; UserInteractive=[Environment]::UserInteractive }
    Profile=[pscustomobject]@{ LocalAppData=$env:LOCALAPPDATA; AppDataPath=$dataDirectory; AppDataAbsentBeforeTest=(-not $dataExistedBefore); TestDataCreatedByHarness=$dataCreatedByHarness; TestDataRemoved=$dataRemoved }
    Narrator=[pscustomobject]@{ ProcessId=$narratorPid; StartedByHarness=$narratorOwned; Version=if($narratorRecord){$narratorRecord.Version}else{$null}; SessionId=if($narratorRecord){$narratorRecord.SessionId}else{$null}; RecapMethod='Insert+Ctrl+X Copy Last Phrase'; Captures=@($speechCaptures); PhysicalAudioVerified=$physicalAudioVerified }
    FocusTrace=@($focusTrace); Assertions=@($assertions); Events=@($events)
    AssertionCounts=[pscustomobject]@{Total=$assertions.Count;Passed=@($assertions|Where-Object{$_.Passed}).Count;NotTested=@($assertions|Where-Object{-not$_.Passed}).Count}
    Screenshots=@($screenshots); TranscriptFile=$transcriptPath; LogFile=$logPath
    Cleanup=[pscustomobject]@{CandidateProcessStopped=$candidateStoppedByHarness;NarratorProcessStopped=$narratorStoppedByHarness;AppDataRemoved=$dataRemoved;Errors=@($cleanupErrors)}
    Limitations=@('Windows 11 ARM64 host; exact x64 candidate ran under emulation, not native x64.','Speech Recap text verifies Narrator speech content only; physical audio rendering and audibility were not tested.','The standalone candidate was launched; no installer or updater was run.')
    ObservedUtc=[DateTime]::UtcNow.ToString('o')
  }
  $result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resultPath -Encoding utf8
  if ($speechCaptures.Count) {
    $lines = foreach ($capture in $speechCaptures) { "[$($capture.Phase)] target=$($capture.TargetControl)`r`n$($capture.Text)`r`n" }
    Set-Content -LiteralPath $transcriptPath -Value ($lines -join "`r`n") -Encoding utf8
  }
  return $result
}

try {
  Start-Transcript -LiteralPath $logPath -Force | Out-Null
  $scriptTranscriptStarted = $true
  Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

[StructLayout(LayoutKind.Sequential)]
public struct EBR_NARRATOR_SYSTEM_INFO {
  public ushort ProcessorArchitecture;
  public ushort Reserved;
  public uint PageSize;
  public IntPtr MinimumApplicationAddress;
  public IntPtr MaximumApplicationAddress;
  public UIntPtr ActiveProcessorMask;
  public uint NumberOfProcessors;
  public uint ProcessorType;
  public uint AllocationGranularity;
  public ushort ProcessorLevel;
  public ushort ProcessorRevision;
}

public static class EBR_NARRATOR_NATIVE {
  private delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr data);
  [DllImport("kernel32.dll")] private static extern void GetNativeSystemInfo(out EBR_NARRATOR_SYSTEM_INFO info);
  [DllImport("user32.dll", SetLastError=true)] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr data);
  [DllImport("user32.dll", SetLastError=true)] private static extern bool EnumChildWindows(IntPtr parent, EnumWindowsProc callback, IntPtr data);
  [DllImport("user32.dll", SetLastError=true)] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="GetWindowTextW", SetLastError=true)] private static extern int GetWindowTextNative(IntPtr hwnd, StringBuilder text, int maxCount);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="GetClassNameW", SetLastError=true)] private static extern int GetClassNameNative(IntPtr hwnd, StringBuilder text, int maxCount);
  [DllImport("user32.dll", SetLastError=true)] private static extern int GetDlgCtrlID(IntPtr hwnd);
  [DllImport("user32.dll", SetLastError=true)] private static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll", SetLastError=true)] private static extern bool IsWindowEnabled(IntPtr hwnd);
  [DllImport("user32.dll", SetLastError=true)] private static extern bool GetWindowRect(IntPtr hwnd, out EBR_NARRATOR_RECT rect);
  [DllImport("user32.dll", SetLastError=true)] private static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] private static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extraInfo);
  [DllImport("user32.dll")] private static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extraInfo);
  [StructLayout(LayoutKind.Sequential)] private struct EBR_NARRATOR_RECT { public int Left, Top, Right, Bottom; }
  public static ushort NativeArchitecture() { EBR_NARRATOR_SYSTEM_INFO i; GetNativeSystemInfo(out i); return i.ProcessorArchitecture; }
  public static string[] WindowsForProcess(int expectedPid) {
    var found = new List<IntPtr>();
    EnumWindows((hwnd, data) => { uint pid; GetWindowThreadProcessId(hwnd, out pid); if (pid == (uint)expectedPid && IsWindowVisible(hwnd)) found.Add(hwnd); return true; }, IntPtr.Zero);
    var result = new List<string>(); foreach (var hwnd in found) result.Add(hwnd.ToInt64().ToString()); return result.ToArray();
  }
  public static IntPtr FindVisibleChildById(IntPtr parent, int id) {
    IntPtr found = IntPtr.Zero;
    EnumChildWindows(parent, (hwnd, data) => { if (found == IntPtr.Zero && GetDlgCtrlID(hwnd) == id && IsWindowVisible(hwnd) && IsWindowEnabled(hwnd)) { found = hwnd; return false; } return true; }, IntPtr.Zero);
    return found;
  }
  public static int[] Bounds(IntPtr hwnd) {
    EBR_NARRATOR_RECT r; if (!GetWindowRect(hwnd, out r)) return new int[0];
    return new int[] { r.Left, r.Top, r.Right, r.Bottom };
  }
  public static string WindowText(IntPtr hwnd) { var b = new StringBuilder(512); GetWindowTextNative(hwnd, b, b.Capacity); return b.ToString(); }
  public static string WindowClass(IntPtr hwnd) { var b = new StringBuilder(256); GetClassNameNative(hwnd, b, b.Capacity); return b.ToString(); }
  public static int OwnerProcessId(IntPtr hwnd) { uint pid; GetWindowThreadProcessId(hwnd, out pid); return (int)pid; }
  public static bool ClickAt(int x, int y) { if (!SetCursorPos(x, y)) return false; System.Threading.Thread.Sleep(80); mouse_event(0x0002,0,0,0,UIntPtr.Zero); System.Threading.Thread.Sleep(80); mouse_event(0x0004,0,0,0,UIntPtr.Zero); return true; }
  public static void KeyDown(byte key) { keybd_event(key, 0, 0, UIntPtr.Zero); }
  public static void KeyUp(byte key) { keybd_event(key, 0, 2, UIntPtr.Zero); }
}
'@ -ErrorAction Stop
  Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
  Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop

  $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
  $osArchitecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
  $processArchitecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
  $nativeCpuArchitecture = [EBR_NARRATOR_NATIVE]::NativeArchitecture()
  $osRecord = [pscustomobject]@{ Caption=$os.Caption; Version=$os.Version; Build=$os.BuildNumber; OSArchitecture=$osArchitecture; ProcessArchitecture=$processArchitecture; NativeProcessorArchitectureCode=$nativeCpuArchitecture; NativeProcessorArchitecture=if($nativeCpuArchitecture -eq 12){'ARM64'}else{"Unknown ($nativeCpuArchitecture)"} }
  $sessionId = (Get-Process -Id $PID -ErrorAction Stop).SessionId
  $osValid = ($os.Caption -match 'Windows 11' -and $osArchitecture -eq 'Arm64' -and $processArchitecture -eq 'Arm64' -and $nativeCpuArchitecture -eq 12)
  Add-Assertion 'Runner is Windows 11 with native ARM64 OS, CPU, and ARM64 PowerShell process' $osValid $osRecord
  if (-not $osValid) { throw 'BLOCKED: the runner is not a native Windows 11 ARM64 environment.' }
  Add-Assertion 'Runner process has an interactive desktop session' ([Environment]::UserInteractive) ([pscustomobject]@{SessionId=$sessionId;UserInteractive=[Environment]::UserInteractive;RunnerImage=$env:ImageOS})
  if (-not [Environment]::UserInteractive) { throw 'BLOCKED: this runner job does not have an interactive desktop.' }

  if (-not (Test-Path -LiteralPath $ExecutablePath -PathType Leaf)) { throw 'BLOCKED: exact standalone candidate executable is missing.' }
  $candidateInfo = Get-Item -LiteralPath $ExecutablePath -ErrorAction Stop
  $actualSha256 = (Get-FileHash -LiteralPath $ExecutablePath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
  if ($actualSha256 -cne $expectedSha256) { throw "BLOCKED: candidate hash mismatch; expected $expectedSha256, found $actualSha256." }
  $reader = [IO.BinaryReader]::new([IO.File]::OpenRead($ExecutablePath))
  try {
    $reader.BaseStream.Position = 0x3C; $peOffset = $reader.ReadInt32(); $reader.BaseStream.Position = $peOffset
    if ($reader.ReadUInt32() -ne 0x00004550) { throw 'Candidate executable has no valid PE signature.' }
    $peMachine = $reader.ReadUInt16()
  } finally { $reader.Dispose() }
  if ($peMachine -ne 0x8664) { throw "BLOCKED: expected an x64 PE candidate, found machine 0x$('{0:X4}' -f $peMachine)." }
  if ($candidateInfo.VersionInfo.ProductVersion -notmatch '^1\.4\.0(\.0)?$') { throw "BLOCKED: candidate file version is '$($candidateInfo.VersionInfo.ProductVersion)', not 1.4.0." }
  $candidateIdentity = [pscustomobject]@{ ArtifactId=$candidateArtifactId; FinalizerRunId=$candidateRunId; SourceCommit=$candidateSourceCommit; SHA256=$actualSha256; Bytes=$candidateInfo.Length; ProductVersion=$candidateInfo.VersionInfo.ProductVersion; PEMachine=('0x{0:X4}' -f $peMachine); Execution='x64 emulation on native Windows 11 ARM64' }
  Add-Assertion 'Standalone executable matches production artifact 14695418078 exact x64 payload' $true $candidateIdentity

  $currentAppProcesses = @(Get-Process -Name EyeBreakReminder -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sessionId })
  if ($currentAppProcesses.Count -gt 0) { throw 'BLOCKED: an Eye Break Reminder process already exists in this runner session; refusing to interfere with it.' }
  if ($dataExistedBefore) { throw "BLOCKED: this runner profile already has EyeBreakReminder data at '$dataDirectory'; refusing to overwrite it." }
  if (-not $dataDirectory.StartsWith($localAppDataRoot, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($dataDirectory) -cne 'EyeBreakReminder') {
    throw 'BLOCKED: the app-data cleanup target is not the exact EyeBreakReminder child of LocalAppData.'
  }
  Add-Assertion 'Fresh runner profile has no pre-existing EyeBreakReminder app data' $true ([pscustomobject]@{Path=$dataDirectory;AbsentBeforeTest=$true})

  $narratorPath = Join-Path $env:WINDIR 'System32\Narrator.exe'
  if (-not (Test-Path -LiteralPath $narratorPath -PathType Leaf)) { throw 'NOT TESTED: Narrator.exe is unavailable on this runner image.' }
  $narratorInSession = @(Get-Process -Name Narrator -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sessionId })
  if ($narratorInSession.Count -gt 0) {
    $narratorProcess = $narratorInSession | Select-Object -First 1
    $narratorPid = $narratorProcess.Id
    $narratorOwned = $false
    Add-Event 'Use already-running Narrator in the same session' 'INFO' ([pscustomobject]@{ProcessId=$narratorPid;SessionId=$narratorProcess.SessionId;OwnedByHarness=$false})
  }

  # Seed only the previously absent runner-local profile with benign, quiet
  # settings. This prevents auto-start, notifications, audio, and update checks.
  [void][IO.Directory]::CreateDirectory($dataDirectory)
  $dataCreatedByHarness = $true
  $settingsPath = Join-Path $dataDirectory 'settings.ini'
  $settingsText = "workMinutes=20`nbreakSeconds=20`nsound=0`nvolume=55`nmode=0`nmonitor=0`ntheme=2`nalarm=0`nrepeat=0`nnotifications=0`nsnooze=0`nautoStart=0`nstartup=0`ntray=0`nautoCheckUpdates=0`nautoDownloadUpdates=0`nhistory=0`n"
  [IO.File]::WriteAllText($settingsPath, $settingsText, [Text.UTF8Encoding]::new($false))
  Add-Event 'Create quiet test-only profile settings after confirming the app-data path was absent' 'PASS' ([pscustomobject]@{SettingsPath=$settingsPath;SettingsSHA256=(Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash.ToLowerInvariant();AutoStart=$false;Notifications=$false;Alarm=$false;UpdateChecks=$false})

  $candidateProcess = Start-Process -FilePath $ExecutablePath -WorkingDirectory (Split-Path -Parent $ExecutablePath) -PassThru -ErrorAction Stop
  $candidatePid = $candidateProcess.Id
  $candidateOwned = $true
  $mainWindow = [IntPtr]::Zero
  $windowWatch = [Diagnostics.Stopwatch]::StartNew()
  while ($windowWatch.Elapsed.TotalSeconds -lt 20 -and $mainWindow -eq [IntPtr]::Zero) {
    $candidateProcess.Refresh()
    if ($candidateProcess.HasExited) { throw "NOT TESTED: candidate exited before creating a window (exit code $($candidateProcess.ExitCode))." }
    foreach ($windowText in [EBR_NARRATOR_NATIVE]::WindowsForProcess($candidatePid)) {
      $handle = [IntPtr]::new([long]$windowText)
      if ([EBR_NARRATOR_NATIVE]::WindowText($handle) -match 'Eye Break Reminder') { $mainWindow = $handle; break }
    }
    if ($mainWindow -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 150 }
  }
  if ($mainWindow -eq [IntPtr]::Zero) { throw 'NOT TESTED: exact candidate did not expose its visible main window within 20 seconds.' }
  Add-Assertion 'Exact production candidate created its visible main window in the interactive test session' $true ([pscustomobject]@{Pid=$candidatePid;WindowHandle=('0x{0:X}' -f $mainWindow.ToInt64());WindowTitle=[EBR_NARRATOR_NATIVE]::WindowText($mainWindow);SessionId=$candidateProcess.SessionId;Path=$candidateProcess.Path;SHA256=$actualSha256})
  $firstShot = Capture-CandidateWindow $mainWindow 'gui-016-candidate-timer-window.png'
  Add-Event 'Capture target-window screenshot of the exact candidate' 'PASS' $firstShot

  if ($null -eq $narratorProcess) {
    $narratorProcess = Start-Process -FilePath $narratorPath -PassThru -ErrorAction Stop
    $narratorPid = $narratorProcess.Id
    $narratorOwned = $true
    $narratorWait = [Diagnostics.Stopwatch]::StartNew()
    while ($narratorWait.Elapsed.TotalSeconds -lt 8) {
      $narratorProcess.Refresh()
      if ($narratorProcess.HasExited) { throw 'NOT TESTED: Narrator did not remain running after launch.' }
      if ($narratorProcess.SessionId -eq $sessionId) { break }
      Start-Sleep -Milliseconds 100
    }
    if ($narratorProcess.SessionId -ne $sessionId) { throw 'NOT TESTED: Narrator is not running in the candidate test session.' }
    Add-Event 'Start Narrator because no instance was already running in the test session' 'PASS' ([pscustomobject]@{ProcessId=$narratorPid;SessionId=$narratorProcess.SessionId;OwnedByHarness=$true;Path=$narratorPath})
  }
  $narratorInfo = Get-Item -LiteralPath $narratorPath -ErrorAction Stop
  $narratorRecord = [pscustomobject]@{Path=$narratorPath;ProductVersion=$narratorInfo.VersionInfo.ProductVersion;Version=$narratorInfo.VersionInfo.FileVersion;ProcessId=$narratorPid;SessionId=$narratorProcess.SessionId;OwnedByHarness=$narratorOwned;ModifierKey='Insert';CopyLastPhraseShortcut='Insert+Ctrl+X'}
  Start-Sleep -Seconds 2

  $settingsButton = Get-ControlElement $mainWindow 12 'Settings navigation button'
  if ($settingsButton.Name -notmatch '(?i)settings') { throw "NOT TESTED: candidate navigation control ID 12 has unexpected accessible name '$($settingsButton.Name)'." }
  $navClick = $settingsButton.Bounds
  if ($navClick.Count -ne 4 -or $navClick[2] -le 0 -or $navClick[3] -le 0) { throw 'NOT TESTED: Settings navigation control has no usable visible UIA bounds.' }
  if (-not [EBR_NARRATOR_NATIVE]::ClickAt([int]($navClick[0] + $navClick[2]/2), [int]($navClick[1] + $navClick[3]/2))) { throw 'NOT TESTED: real pointer input could not focus Settings navigation.' }
  Start-Sleep -Milliseconds 350
  $settingsWait = [Diagnostics.Stopwatch]::StartNew()
  $volumeControl = $null
  while ($settingsWait.Elapsed.TotalSeconds -lt 8 -and $null -eq $volumeControl) {
    try { $volumeControl = Get-ControlElement $mainWindow 103 'Alarm volume slider' } catch { Start-Sleep -Milliseconds 100 }
  }
  if ($null -eq $volumeControl) { throw 'NOT TESTED: the real candidate Settings page did not expose its Alarm volume control.' }
  $settingsShot = Capture-CandidateWindow $mainWindow 'gui-016-candidate-settings-window.png'
  Add-Assertion 'Real Settings navigation opens the candidate settings surface through pointer input' $true ([pscustomobject]@{NavigationControl=$settingsButton;VolumeControl=$volumeControl;Screenshot=$settingsShot.Path})

  $volumeBounds = $volumeControl.Bounds
  if ($volumeBounds.Count -ne 4 -or $volumeBounds[2] -le 0 -or $volumeBounds[3] -le 0) { throw 'NOT TESTED: Alarm volume control has no usable visible UIA bounds.' }
  if (-not [EBR_NARRATOR_NATIVE]::ClickAt([int]($volumeBounds[0] + $volumeBounds[2]/2), [int]($volumeBounds[1] + $volumeBounds[3]/2))) { throw 'NOT TESTED: real pointer input could not focus Alarm volume.' }
  Start-Sleep -Milliseconds 400
  $focusedVolume = Wait-CandidateFocus 'After pointer focus on candidate Alarm volume slider' 5
  if (-not $focusedVolume.IsCandidateProcess) { $volumeControl.Element.SetFocus(); Start-Sleep -Milliseconds 250; $focusedVolume = Wait-CandidateFocus 'After UI Automation SetFocus on Alarm volume slider' 3 }
  if (-not $focusedVolume.IsCandidateProcess -or $focusedVolume.Name -notmatch '(?i)volume') { throw 'NOT TESTED: UI Automation focus did not land on the candidate Alarm volume control.' }
  $firstSpeech = Copy-NarratorLastPhrase $focusedVolume.Name 'Alarm volume pointer focus'
  $firstPhraseValid = ($firstSpeech.FreshText -and $firstSpeech.Text -match '(?i)volume')
  Add-Assertion 'Narrator Copy Last Phrase returns fresh speech content for the candidate Alarm volume control' $firstPhraseValid ([pscustomobject]@{Focus=$focusedVolume;Capture=$firstSpeech;PhysicalAudioVerified=$false})

  [EBR_NARRATOR_NATIVE]::KeyDown(0x09) # Tab: real keyboard navigation from the focused slider.
  [EBR_NARRATOR_NATIVE]::KeyUp(0x09)
  Start-Sleep -Milliseconds 400
  $focusedAfterTab = Get-FocusSnapshot $candidatePid 'After real Tab navigation from Alarm volume'
  $tabChangedCandidateFocus = ($focusedAfterTab.IsCandidateProcess -and (($focusedAfterTab.AutomationId -ne $focusedVolume.AutomationId) -or ($focusedAfterTab.Name -ne $focusedVolume.Name) -or ($focusedAfterTab.NativeWindowHandle -ne $focusedVolume.NativeWindowHandle)))
  Add-Assertion 'Real Tab input moves keyboard focus to another named candidate control' $tabChangedCandidateFocus ([pscustomobject]@{Before=$focusedVolume;After=$focusedAfterTab;Key='Tab'})
  if (-not $tabChangedCandidateFocus) { throw 'NOT TESTED: Tab did not move focus to another named control in the candidate window.' }
  $secondShot = Capture-CandidateWindow $mainWindow 'gui-016-candidate-keyboard-focus-window.png'
  $secondSpeech = Copy-NarratorLastPhrase $focusedAfterTab.Name 'Keyboard Tab focus to candidate control'
  $expectedName = [regex]::Escape(($focusedAfterTab.Name -replace '&','').Trim())
  $secondPhraseValid = ($secondSpeech.FreshText -and $secondSpeech.Text -match '(?i)volume|preview|stop|alarm|slider|button')
  if ($focusedAfterTab.Name -and $focusedAfterTab.Name.Length -ge 3) { $secondPhraseValid = $secondPhraseValid -and ($secondSpeech.Text -match "(?i)$expectedName") }
  Add-Assertion 'Narrator Copy Last Phrase returns fresh speech content after keyboard focus changes' $secondPhraseValid ([pscustomobject]@{Focus=$focusedAfterTab;Capture=$secondSpeech;Screenshot=$secondShot.Path;PhysicalAudioVerified=$false})

  $goodCaptures = @($speechCaptures | Where-Object { $_.FreshText -and -not [string]::IsNullOrWhiteSpace($_.Text) })
  $evidenceReady = ($goodCaptures.Count -ge 2 -and $firstPhraseValid -and $tabChangedCandidateFocus -and $secondPhraseValid -and $screenshots.Count -ge 3)
  if ($evidenceReady) {
    $status = 'PASS'
    $reason = 'Two fresh Narrator Copy Last Phrase captures were associated with real candidate controls after pointer and keyboard navigation; target-window screenshots and focus trace were retained. Physical audio remains unverified.'
  } else {
    $status = 'NOT TESTED'
    $reason = 'The harness did not capture sufficient fresh Narrator Recap text associated with candidate controls; UI Automation observations alone are not accepted as speech evidence.'
  }
  Add-Event 'GUI-016 documented Speech Recap alternative result' $status ([pscustomobject]@{FreshSpeechCaptureCount=$goodCaptures.Count;PhysicalAudioVerified=$false;CandidateArchitecture='x64 emulation on Windows 11 ARM64'})
} catch {
  $errorMessage = $_.Exception.Message
  if ($errorMessage -match '^(BLOCKED|NOT TESTED):') { $status = if($errorMessage.StartsWith('BLOCKED:')){'BLOCKED'}else{'NOT TESTED'}; $reason = $errorMessage }
  else { $status = 'NOT TESTED'; $reason = "Narrator speech content was not established: $errorMessage" }
  Add-Event 'GUI-016 harness attempt' $status ([pscustomobject]@{Message=$errorMessage;StackTrace=$_.ScriptStackTrace})
} finally {
  if ($candidateOwned -and $candidatePid -gt 0) {
    try {
      $owned = Get-Process -Id $candidatePid -ErrorAction SilentlyContinue
      if ($owned) {
        $ownedPath = ''
        try { $ownedPath = [IO.Path]::GetFullPath($owned.Path) } catch {}
        if ($ownedPath -ieq $ExecutablePath) {
          [void]$owned.CloseMainWindow()
          if (-not $owned.WaitForExit(5000)) { Stop-Process -Id $candidatePid -Force -ErrorAction Stop; $owned.WaitForExit(5000) | Out-Null }
          $candidateStoppedByHarness = $true
          Add-Event 'Stop only the standalone candidate process launched by this harness' 'PASS' ([pscustomobject]@{ProcessId=$candidatePid;Path=$ownedPath})
        } else { $cleanupErrors.Add("Candidate PID $candidatePid now resolves to another image; it was not stopped.") }
      } else { $candidateStoppedByHarness = $true }
    } catch { $cleanupErrors.Add("Candidate process cleanup: $($_.Exception.Message)") }
  }
  if ($narratorOwned -and $narratorPid -gt 0) {
    try {
      $ownedNarrator = Get-Process -Id $narratorPid -ErrorAction SilentlyContinue
      if ($ownedNarrator) {
        $narratorImage = ''
        try { $narratorImage = [IO.Path]::GetFullPath($ownedNarrator.Path) } catch {}
        if ($narratorImage -ieq [IO.Path]::GetFullPath((Join-Path $env:WINDIR 'System32\Narrator.exe'))) {
          Stop-Process -Id $narratorPid -Force -ErrorAction Stop
          $narratorStoppedByHarness = $true
          Add-Event 'Stop only the Narrator process started by this harness' 'PASS' ([pscustomobject]@{ProcessId=$narratorPid;Path=$narratorImage})
        } else { $cleanupErrors.Add("Narrator PID $narratorPid no longer resolves to Narrator.exe; it was not stopped.") }
      } else { $narratorStoppedByHarness = $true }
    } catch { $cleanupErrors.Add("Owned Narrator process cleanup: $($_.Exception.Message)") }
  }
  if ($dataCreatedByHarness -and -not $dataExistedBefore -and (Test-Path -LiteralPath $dataDirectory)) {
    try {
      $resolvedData = [IO.Path]::GetFullPath($dataDirectory)
      if (-not $resolvedData.StartsWith($localAppDataRoot, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolvedData) -cne 'EyeBreakReminder') { throw "Refusing cleanup outside the exact test profile folder: $resolvedData" }
      if (([IO.File]::GetAttributes($resolvedData) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Refusing to recurse into an app-data reparse point.' }
      $reparseChildren = @(Get-ChildItem -LiteralPath $resolvedData -Force -Recurse -ErrorAction Stop | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })
      if ($reparseChildren.Count -gt 0) { throw 'Refusing to recurse into a reparse point created inside the app-data test folder.' }
      Remove-Item -LiteralPath $resolvedData -Recurse -Force -ErrorAction Stop
      $dataRemoved = -not (Test-Path -LiteralPath $resolvedData)
      if (-not $dataRemoved) { throw 'The new test app-data directory remains after cleanup.' }
      Add-Event 'Remove only the fresh app-data directory created by this harness' 'PASS' ([pscustomobject]@{Path=$resolvedData;Removed=$true})
    } catch { $cleanupErrors.Add("App-data cleanup: $($_.Exception.Message)") }
  }
  if ($scriptTranscriptStarted) { try { Stop-Transcript | Out-Null } catch { $cleanupErrors.Add("Transcript close: $($_.Exception.Message)") } }
}

if ($status -eq 'PASS' -and $cleanupErrors.Count -gt 0) {
  $status = 'NOT TESTED'
  $reason += ' Cleanup did not complete cleanly; GUI-016 is not marked PASS.'
}
try {
  $result = Save-Result $status $reason
  $result | ConvertTo-Json -Depth 12
  Write-Host "GUI-016 Narrator speech result: $status — $reason"
} catch { throw "Could not save GUI-016 evidence: $($_.Exception.Message)" }
