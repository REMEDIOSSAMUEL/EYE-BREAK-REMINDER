param(
  [string]$PublishedExecutablePath = (Join-Path $env:RUNNER_TEMP 'eye-break-reminder-v1.2.0-published-assets\EyeBreakReminder.exe'),
  [string]$EvidenceDirectory = (Join-Path (Get-Location) 'build\post-release-evidence')
)
$ErrorActionPreference = 'Stop'
$expectedHash = '2895c80f942dd03186305d913516700552524ec5ba9a77da0dab457a3265fcc6'
$events = [System.Collections.Generic.List[object]]::new()
$narratorProcess = $null
$appProcess = $null
$ownedData = $false
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$native = @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class EBR_NARRATOR_NATIVE {
  public delegate bool EnumCallback(IntPtr hwnd, IntPtr data);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool EnumWindows(EnumCallback callback, IntPtr data);
  [DllImport("user32.dll", SetLastError=true)] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern int GetWindowTextW(IntPtr hwnd, StringBuilder text, int maxCount);
  [DllImport("user32.dll", SetLastError=true)] private static extern int GetWindowTextLengthW(IntPtr hwnd);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern int GetClassNameW(IntPtr hwnd, StringBuilder name, int maxCount);
  [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll", SetLastError=true)] public static extern bool SetForegroundWindow(IntPtr hwnd);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool ShowWindow(IntPtr hwnd, int command);
  [DllImport("user32.dll", SetLastError=true)] public static extern void keybd_event(byte virtualKey, byte scanCode, uint flags, UIntPtr extraInfo);
  public static IntPtr[] WindowsForProcess(int processId) {
    List<IntPtr> result = new List<IntPtr>();
    EnumCallback callback = delegate(IntPtr hwnd, IntPtr ignored) {
      uint actual; GetWindowThreadProcessId(hwnd, out actual);
      if (actual == (uint)processId && IsWindowVisible(hwnd)) result.Add(hwnd);
      return true;
    };
    EnumWindows(callback, IntPtr.Zero); GC.KeepAlive(callback); return result.ToArray();
  }
  public static string ClassName(IntPtr hwnd) { StringBuilder b = new StringBuilder(256); GetClassNameW(hwnd, b, b.Capacity); return b.ToString(); }
  public static string Text(IntPtr hwnd) { int n = GetWindowTextLengthW(hwnd); StringBuilder b = new StringBuilder(Math.Max(2, n + 2)); GetWindowTextW(hwnd, b, b.Capacity); return b.ToString(); }
}
"@
Add-Type -TypeDefinition $native
function Add-Result([string]$name, [string]$status, $details = $null) {
  $events.Add([pscustomobject]@{Name=$name;Status=$status;Details=$details;Utc=[DateTime]::UtcNow.ToString('o')})
  Write-Host "[$status] $name"
}
function Send-Key([byte]$key) {
  [EBR_NARRATOR_NATIVE]::keybd_event($key, 0, 0, [UIntPtr]::Zero)
  [EBR_NARRATOR_NATIVE]::keybd_event($key, 0, 2, [UIntPtr]::Zero)
}
function Get-FocusedSummary {
  try {
    $element = [System.Windows.Automation.AutomationElement]::FocusedElement
    if ($null -eq $element) { return $null }
    $current = $element.Current
    return [pscustomobject]@{
      Name = $current.Name
      ControlType = $current.ControlType.ProgrammaticName
      AutomationId = $current.AutomationId
      ProcessId = $current.ProcessId
      HasKeyboardFocus = $current.HasKeyboardFocus
      IsEnabled = $current.IsEnabled
      Bounds = @($current.BoundingRectangle.X,$current.BoundingRectangle.Y,$current.BoundingRectangle.Width,$current.BoundingRectangle.Height)
    }
  } catch { return $null }
}
function Send-TabUntil([string]$target, [int]$maximumTabs = 40) {
  $seen = [System.Collections.Generic.List[object]]::new()
  for ($i = 0; $i -lt $maximumTabs; $i++) {
    Send-Key 9
    Start-Sleep -Milliseconds 160
    $focus = Get-FocusedSummary
    if ($focus) { $seen.Add($focus) }
    if ($focus -and $focus.ProcessId -eq $appProcess.Id -and $focus.Name -ceq $target) {
      return [pscustomobject]@{Found=$true;Target=$target;Focus=$focus;Sequence=$seen.ToArray()}
    }
  }
  return [pscustomobject]@{Found=$false;Target=$target;Focus=(Get-FocusedSummary);Sequence=$seen.ToArray()}
}
function Get-AppWindows {
  $result = @()
  foreach ($handle in [EBR_NARRATOR_NATIVE]::WindowsForProcess($appProcess.Id)) {
    $result += [pscustomobject]@{
      Handle = ('0x{0:X}' -f $handle.ToInt64())
      Class = [EBR_NARRATOR_NATIVE]::ClassName($handle)
      Title = [EBR_NARRATOR_NATIVE]::Text($handle)
      IsMain = ([EBR_NARRATOR_NATIVE]::ClassName($handle) -eq 'EyeBreakReminder.Native')
    }
  }
  return $result
}
try {
  New-Item -ItemType Directory -Force -Path $EvidenceDirectory | Out-Null
  $actualHash = (Get-FileHash -LiteralPath $PublishedExecutablePath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actualHash -cne $expectedHash) { throw "Narrator probe executable is not the exact published v1.2.0 EXE: $actualHash" }
  Add-Result 'Narrator probe executable matches the published v1.2.0 SHA-256' 'PASS' $actualHash

  $dataPath = Join-Path $env:LOCALAPPDATA 'EyeBreakReminder'
  if (Test-Path -LiteralPath $dataPath) {
    Add-Result 'Disposable runner has a clean Eye Break Reminder profile before the Narrator probe' 'NOT TESTED' ([pscustomobject]@{Path=$dataPath;Reason='Existing app data was preserved and the probe did not launch against it.'})
    return
  }
  $ownedData = $true
  $narratorPath = Join-Path $env:WINDIR 'System32\Narrator.exe'
  if (-not (Test-Path -LiteralPath $narratorPath)) {
    Add-Result 'Windows Narrator executable is available' 'NOT TESTED' ([pscustomobject]@{Path=$narratorPath;Reason='Narrator is absent from this Windows image.'})
    return
  }
  $narratorProcess = Start-Process -FilePath $narratorPath -PassThru
  $watch = [Diagnostics.Stopwatch]::StartNew()
  $narratorObserved = $false
  while ($watch.Elapsed.TotalSeconds -lt 10) {
    $narratorProcess.Refresh()
    if (-not $narratorProcess.HasExited) { $narratorObserved = $true; break }
    Start-Sleep -Milliseconds 200
  }
  if (-not $narratorObserved) {
    Add-Result 'Windows Narrator starts on the disposable runner' 'NOT TESTED' ([pscustomobject]@{Path=$narratorPath;Reason='Narrator did not remain running; no focus-navigation or speech conclusion is drawn.'})
    return
  }
  Add-Result 'Windows Narrator is running during application keyboard navigation' 'PASS' ([pscustomobject]@{ProcessId=$narratorProcess.Id;Path=$narratorPath;OS=(Get-CimInstance Win32_OperatingSystem).Caption;NativeArchitecture=[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()})

  $appProcess = Start-Process -FilePath $PublishedExecutablePath -PassThru
  $watch = [Diagnostics.Stopwatch]::StartNew()
  $mainWindow = [IntPtr]::Zero
  while ($watch.Elapsed.TotalSeconds -lt 20) {
    $appProcess.Refresh()
    if ($appProcess.HasExited) { break }
    foreach ($handle in [EBR_NARRATOR_NATIVE]::WindowsForProcess($appProcess.Id)) {
      if ([EBR_NARRATOR_NATIVE]::ClassName($handle) -eq 'EyeBreakReminder.Native') { $mainWindow = $handle; break }
    }
    if ($mainWindow -ne [IntPtr]::Zero) { break }
    Start-Sleep -Milliseconds 150
  }
  if ($appProcess.HasExited -or $mainWindow -eq [IntPtr]::Zero) { throw 'The exact published executable did not create its visible main window while Narrator was running.' }
  [void][EBR_NARRATOR_NATIVE]::ShowWindow($mainWindow, 9)
  [void][EBR_NARRATOR_NATIVE]::SetForegroundWindow($mainWindow)
  Start-Sleep -Milliseconds 350
  Add-Result 'Exact published app is visible while Narrator is running' 'PASS' ([pscustomobject]@{ProcessId=$appProcess.Id;Window=('0x{0:X}' -f $mainWindow.ToInt64());Title=[EBR_NARRATOR_NATIVE]::Text($mainWindow);Hash=$actualHash})

  $tabSequence = [System.Collections.Generic.List[object]]::new()
  for ($i = 0; $i -lt 32; $i++) {
    Send-Key 9
    Start-Sleep -Milliseconds 160
    $focus = Get-FocusedSummary
    if ($focus) { $tabSequence.Add($focus) }
  }
  $focusedInApp = @($tabSequence | Where-Object ProcessId -eq $appProcess.Id)
  $knownNames = @($focusedInApp | ForEach-Object Name | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
  $expectedFocusNames = @('Timer','History','Settings','Take a break now','Pause','Reset')
  $presentFocusNames = @($expectedFocusNames | Where-Object { $_ -in $knownNames })
  $missingFocusNames = @($expectedFocusNames | Where-Object { $_ -notin $knownNames })
  $navigationOk = @('Timer','History','Settings' | Where-Object { $_ -in $knownNames }).Count -eq 3
  Add-Result 'Narrator-active keyboard navigation exposes main tabs and timer control names' $(if($navigationOk){'PASS'}else{'FAIL'}) ([pscustomobject]@{TabKeyEvents=32;FocusedElementCount=$focusedInApp.Count;ExpectedNames=$expectedFocusNames;NamesReached=$presentFocusNames;MissingNames=$missingFocusNames;FocusSequence=$focusedInApp.ToArray()})
  Add-Result 'Narrator-active keyboard navigation exposes break and timer action names' $(if(@('Take a break now','Pause','Reset' | Where-Object { $_ -in $knownNames }).Count -eq 3){'PASS'}else{'FAIL'}) ([pscustomobject]@{NamesReached=$presentFocusNames;MissingNames=$missingFocusNames})

  $history = Send-TabUntil 'History'
  if ($history.Found) {
    Send-Key 13
    Start-Sleep -Milliseconds 300
    Add-Result 'Keyboard activation moves focus to History navigation' 'PASS' ([pscustomobject]@{Target=$history.Target;Focus=$history.Focus;AppWindows=(Get-AppWindows)})
  } else {
    Add-Result 'Keyboard activation moves focus to History navigation' 'FAIL' $history
  }
  $settings = Send-TabUntil 'Settings'
  if ($settings.Found) {
    Send-Key 13
    Start-Sleep -Milliseconds 300
    $focusAfterSettings = Get-FocusedSummary
    Add-Result 'Keyboard activation moves focus to Settings navigation' 'PASS' ([pscustomobject]@{Target=$settings.Target;Focus=$settings.Focus;FocusAfterActivation=$focusAfterSettings;AppWindows=(Get-AppWindows)})
  } else {
    Add-Result 'Keyboard activation moves focus to Settings navigation' 'FAIL' $settings
  }

  $timer = Send-TabUntil 'Timer'
  if ($timer.Found) { Send-Key 13; Start-Sleep -Milliseconds 300 }
  $breakAction = Send-TabUntil 'Take a break now'
  if ($timer.Found -and $breakAction.Found) {
    Send-Key 13
    Start-Sleep -Milliseconds 500
    $windows = Get-AppWindows
    $breakWindows = @($windows | Where-Object { -not $_.IsMain })
    $status = 'FAIL'
    if ($breakWindows.Count -gt 0) { $status = 'PASS' }
    Add-Result 'Keyboard activation of the break control opens the in-app reminder while Narrator runs' $status ([pscustomobject]@{TimerFocus=$timer.Focus;BreakActionFocus=$breakAction.Focus;AppWindows=$windows;BreakWindowCount=$breakWindows.Count})
    if ($breakWindows.Count -gt 0) { Send-Key 27; Start-Sleep -Milliseconds 250 }
  } else {
    Add-Result 'Keyboard activation of the break control opens the in-app reminder while Narrator runs' 'FAIL' ([pscustomobject]@{TimerNavigation=$timer;BreakAction=$breakAction})
  }
  Add-Result 'Audible Narrator speech was directly verified' 'NOT TESTED' ([pscustomobject]@{Reason='The Windows 11 runner exposed zero waveOut devices in the published-binary smoke; the Narrator process and keyboard focus do not prove synthesized speech reached an output endpoint.'})
} catch {
  Add-Result 'Narrator keyboard probe completed without an automation exception' 'FAIL' $_.Exception.Message
} finally {
  if ($appProcess) {
    try { $appProcess.Refresh(); if (-not $appProcess.HasExited) { [void]$appProcess.CloseMainWindow(); if (-not $appProcess.WaitForExit(3000)) { Stop-Process -Id $appProcess.Id -Force -ErrorAction SilentlyContinue } } } catch {}
  }
  if ($narratorProcess) {
    try { $narratorProcess.Refresh(); if (-not $narratorProcess.HasExited) { Stop-Process -Id $narratorProcess.Id -Force -ErrorAction SilentlyContinue } } catch {}
  }
  if (-not (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'EyeBreakReminder'))) { $ownedData = $false }
  if ($ownedData) {
    $dataPath = Join-Path $env:LOCALAPPDATA 'EyeBreakReminder'
    if (Test-Path -LiteralPath $dataPath) { Remove-Item -LiteralPath $dataPath -Recurse -Force }
  }
  $result = [pscustomobject]@{
    Application='Eye Break Reminder'
    Release='v1.2.0'
    ExecutableSHA256=$expectedHash
    Environment=[pscustomobject]@{OS=(Get-CimInstance Win32_OperatingSystem).Caption;Build=(Get-CimInstance Win32_OperatingSystem).BuildNumber;NativeArchitecture=[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString();RunnerArchitecture=$env:RUNNER_ARCH;InteractiveDesktop=$true}
    Pass=(@($events | Where-Object Status -eq 'PASS')).Count
    Fail=(@($events | Where-Object Status -eq 'FAIL')).Count
    NotTested=(@($events | Where-Object Status -eq 'NOT TESTED')).Count
    Events=$events.ToArray()
    CompletedUtc=[DateTime]::UtcNow.ToString('o')
  }
  $result | ConvertTo-Json -Depth 14 | Set-Content (Join-Path $EvidenceDirectory 'narrator-keyboard-probe.json') -Encoding UTF8
}
$failures = @($events | Where-Object Status -eq 'FAIL')
if ($failures.Count -gt 0) { exit 1 }
