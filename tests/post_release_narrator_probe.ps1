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
  [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr SetFocus(IntPtr hwnd);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll", SetLastError=true)] public static extern bool AttachThreadInput(uint attach, uint attachTo, bool attachState);
  [DllImport("user32.dll", SetLastError=true)] public static extern void keybd_event(byte virtualKey, byte scanCode, uint flags, UIntPtr extraInfo);
  public static bool ActivateWindow(IntPtr hwnd) {
    uint current=GetCurrentThreadId(), targetPid=0; uint target=GetWindowThreadProcessId(hwnd,out targetPid);
    IntPtr foreground=GetForegroundWindow(); uint foregroundPid=0; uint foregroundThread=foreground==IntPtr.Zero?0:GetWindowThreadProcessId(foreground,out foregroundPid);
    bool attachedForeground=false, attachedTarget=false;
    try {
      if(foregroundThread!=0 && foregroundThread!=current) attachedForeground=AttachThreadInput(current,foregroundThread,true);
      if(target!=0 && target!=current && target!=foregroundThread) attachedTarget=AttachThreadInput(current,target,true);
      ShowWindow(hwnd,9); SetForegroundWindow(hwnd); SetFocus(hwnd);
      return GetForegroundWindow()==hwnd;
    } finally {
      if(attachedTarget) AttachThreadInput(current,target,false);
      if(attachedForeground) AttachThreadInput(current,foregroundThread,false);
    }
  }
  public static bool BringToFront(IntPtr hwnd) {
    uint current=GetCurrentThreadId(), targetPid=0; uint target=GetWindowThreadProcessId(hwnd,out targetPid);
    IntPtr foreground=GetForegroundWindow(); uint foregroundPid=0; uint foregroundThread=foreground==IntPtr.Zero?0:GetWindowThreadProcessId(foreground,out foregroundPid);
    bool attachedForeground=false, attachedTarget=false;
    try {
      if(foregroundThread!=0 && foregroundThread!=current) attachedForeground=AttachThreadInput(current,foregroundThread,true);
      if(target!=0 && target!=current && target!=foregroundThread) attachedTarget=AttachThreadInput(current,target,true);
      ShowWindow(hwnd,9); SetForegroundWindow(hwnd);
      return GetForegroundWindow()==hwnd;
    } finally {
      if(attachedTarget) AttachThreadInput(current,target,false);
      if(attachedForeground) AttachThreadInput(current,foregroundThread,false);
    }
  }
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
  if($mainWindow -eq [IntPtr]::Zero -or -not [EBR_NARRATOR_NATIVE]::BringToFront($mainWindow)){
    throw "Keyboard input $key was not sent because the Eye Break Reminder window could not be brought to the foreground."
  }
  $foreground=[EBR_NARRATOR_NATIVE]::GetForegroundWindow();$foregroundPid=[uint32]0
  if($foreground -ne [IntPtr]::Zero){[void][EBR_NARRATOR_NATIVE]::GetWindowThreadProcessId($foreground,[ref]$foregroundPid)}
  if($foregroundPid -ne $appProcess.Id){throw "Keyboard input $key was withheld because foreground process $foregroundPid is not Eye Break Reminder ($($appProcess.Id))."}
  $focus=Get-FocusedSummary
  if($focus -and $focus.ProcessId -ne $appProcess.Id){throw "Keyboard input $key was withheld because UI Automation reports focus outside Eye Break Reminder: $($focus.Name)."}
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
    if ($focus -and $focus.ProcessId -ne $appProcess.Id) { break }
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
function Get-AppAutomationElements {
  $root=[System.Windows.Automation.AutomationElement]::FromHandle($mainWindow)
  if($null -eq $root){return @()}
  $found=$root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
  $items=[System.Collections.Generic.List[object]]::new()
  for($i=0;$i -lt $found.Count;$i++){
    try{$element=$found.Item($i);$current=$element.Current;if($current.ProcessId -eq $appProcess.Id){$items.Add([pscustomobject]@{Element=$element;Name=$current.Name;ControlType=$current.ControlType.ProgrammaticName;AutomationId=$current.AutomationId;Enabled=$current.IsEnabled;Offscreen=$current.IsOffscreen})}}catch{}
  }
  return $items.ToArray()
}
function Focus-AppElement([string]$name,[string]$controlType=''){
  $candidate=@(Get-AppAutomationElements|Where-Object {$_.Name -ceq $name -and (-not $controlType -or $_.ControlType -ceq $controlType) -and $_.Enabled -and -not $_.Offscreen}|Select-Object -First 1)
  if($candidate.Count -eq 0){return [pscustomobject]@{Found=$false;Target=$name;Focus=(Get-FocusedSummary);Names=@((Get-AppAutomationElements|ForEach-Object Name|Where-Object{$_}|Select-Object -Unique))}}
  try{$candidate[0].Element.SetFocus();Start-Sleep -Milliseconds 150;$focus=Get-FocusedSummary;return [pscustomobject]@{Found=($focus -and $focus.ProcessId -eq $appProcess.Id -and $focus.Name -ceq $name);Target=$name;Focus=$focus;ControlType=$candidate[0].ControlType;AutomationId=$candidate[0].AutomationId}}catch{return [pscustomobject]@{Found=$false;Target=$name;Focus=(Get-FocusedSummary);Error=$_.Exception.Message}}
}
function Get-AppAutomationNames { @((Get-AppAutomationElements|ForEach-Object Name|Where-Object {-not [string]::IsNullOrWhiteSpace($_)}|Select-Object -Unique)) }
function Close-NarratorUpdatesWindow {
  $root=[System.Windows.Automation.AutomationElement]::RootElement
  $top=$root.FindAll([System.Windows.Automation.TreeScope]::Children,[System.Windows.Automation.Condition]::TrueCondition)
  for($i=0;$i -lt $top.Count;$i++){
    try{
      $window=$top.Item($i);$current=$window.Current
      if($current.ControlType -ne [System.Windows.Automation.ControlType]::Window -or $current.Name -ne 'Narrator updates'){continue}
      $closeCondition=New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty,'Close')
      $close=$window.FindFirst([System.Windows.Automation.TreeScope]::Descendants,$closeCondition)
      if($close){$invoke=$null;if($close.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern,[ref]$invoke)){$invoke.Invoke();Start-Sleep -Milliseconds 250;return [pscustomobject]@{Present=$true;Closed=$true;WindowName=$current.Name;ProcessId=$current.ProcessId;Method='InvokePattern on Narrator updates Close button'}}}
      $windowPattern=$null
      if($window.TryGetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern,[ref]$windowPattern)){$windowPattern.Close();Start-Sleep -Milliseconds 250;return [pscustomobject]@{Present=$true;Closed=$true;WindowName=$current.Name;ProcessId=$current.ProcessId;Method='WindowPattern.Close'}}
      return [pscustomobject]@{Present=$true;Closed=$false;WindowName=$current.Name;ProcessId=$current.ProcessId;Reason='The Narrator updates window exposed no usable Close action.'}
    }catch{return [pscustomobject]@{Present=$true;Closed=$false;Error=$_.Exception.Message}}
  }
  return [pscustomobject]@{Present=$false;Closed=$true;Reason='No Narrator updates onboarding window was present.'}
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
  Start-Sleep -Milliseconds 350
  $narratorUpdates=Close-NarratorUpdatesWindow
  Add-Result 'Transient Narrator updates onboarding window was dismissed without stopping Narrator' $(if($narratorUpdates.Closed){'PASS'}else{'NOT TESTED'}) $narratorUpdates

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
  $foregroundActivated=[EBR_NARRATOR_NATIVE]::ActivateWindow($mainWindow)
  Start-Sleep -Milliseconds 350
  $foregroundHandle=[EBR_NARRATOR_NATIVE]::GetForegroundWindow();$foregroundPid=[uint32]0;if($foregroundHandle -ne [IntPtr]::Zero){[void][EBR_NARRATOR_NATIVE]::GetWindowThreadProcessId($foregroundHandle,[ref]$foregroundPid)}
  Add-Result 'Exact published app is visible and foreground while Narrator is running' $(if($foregroundActivated -and $foregroundPid -eq $appProcess.Id){'PASS'}else{'FAIL'}) ([pscustomobject]@{ProcessId=$appProcess.Id;Window=('0x{0:X}' -f $mainWindow.ToInt64());Title=[EBR_NARRATOR_NATIVE]::Text($mainWindow);Hash=$actualHash;ForegroundActivated=$foregroundActivated;ForegroundHandle=('0x{0:X}' -f $foregroundHandle.ToInt64());ForegroundProcessId=$foregroundPid})
  if(-not $foregroundActivated -or $foregroundPid -ne $appProcess.Id){throw 'Could not safely activate the published app on the interactive desktop; keyboard input was not sent to an unrelated foreground window.'}

  $tabSequence = [System.Collections.Generic.List[object]]::new()
  for ($i = 0; $i -lt 32; $i++) {
    Send-Key 9
    Start-Sleep -Milliseconds 160
    $focus = Get-FocusedSummary
    if ($focus) { $tabSequence.Add($focus) }
  }
  $focusedInApp = @($tabSequence | Where-Object ProcessId -eq $appProcess.Id)
  $knownNames = @($focusedInApp | ForEach-Object Name | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
  $expectedFocusNames = @('Timer','Take a break now','Pause','Reset')
  $presentFocusNames = @($expectedFocusNames | Where-Object { $_ -in $knownNames })
  $missingFocusNames = @($expectedFocusNames | Where-Object { $_ -notin $knownNames })
  $navigationOk = @('Timer','Take a break now','Pause','Reset' | Where-Object { $_ -in $knownNames }).Count -eq 4
  Add-Result 'Narrator-active Tab navigation reaches the selected main tab and timer control names' $(if($navigationOk){'PASS'}else{'FAIL'}) ([pscustomobject]@{TabKeyEvents=32;FocusedElementCount=$focusedInApp.Count;ExpectedNames=$expectedFocusNames;NamesReached=$presentFocusNames;MissingNames=$missingFocusNames;FocusSequence=@($focusedInApp)})
  Add-Result 'Narrator-active keyboard navigation exposes break and timer action names' $(if(@('Take a break now','Pause','Reset' | Where-Object { $_ -in $knownNames }).Count -eq 3){'PASS'}else{'FAIL'}) ([pscustomobject]@{NamesReached=$presentFocusNames;MissingNames=$missingFocusNames})

  $timer=Focus-AppElement 'Timer' 'ControlType.RadioButton'
  if($timer.Found){Send-Key 39;Start-Sleep -Milliseconds 200}
  $historyFocus=Get-FocusedSummary
  $historyFound=$timer.Found -and $historyFocus -and $historyFocus.ProcessId -eq $appProcess.Id -and $historyFocus.Name -ceq 'History'
  Add-Result 'Narrator-active arrow-key navigation moves from Timer to History tab' $(if($historyFound){'PASS'}else{'FAIL'}) ([pscustomobject]@{TimerFocus=$timer;HistoryFocus=$historyFocus;ExpectedNavigation='Right arrow within the native radio-button tab group'})
  if($historyFound){Send-Key 13;Start-Sleep -Milliseconds 250}
  $historyNames=Get-AppAutomationNames
  $historyContent=@('Date','Break','Seconds','Save history on this device'|Where-Object{$_ -in $historyNames})
  $historyPage=$historyFound -and $historyContent.Count -ge 4
  Add-Result 'Keyboard activation opens the History page while Narrator runs' $(if($historyPage){'PASS'}else{'FAIL'}) ([pscustomobject]@{Focus=$historyFocus;ContentNamesReached=$historyContent;ExpectedContent=@('Date','Break','Seconds','Save history on this device');Names=$historyNames})

  $historyTabRestored=if($historyPage){Focus-AppElement 'History' 'ControlType.RadioButton'}else{[pscustomobject]@{Found=$false;Target='History';Reason='The History page did not open.'}}
  if($historyTabRestored.Found){Send-Key 39;Start-Sleep -Milliseconds 200}
  $settingsFocus=Get-FocusedSummary
  $settingsFound=$historyTabRestored.Found -and $settingsFocus -and $settingsFocus.ProcessId -eq $appProcess.Id -and $settingsFocus.Name -ceq 'Settings'
  Add-Result 'Narrator-active arrow-key navigation moves from History to Settings tab' $(if($settingsFound){'PASS'}else{'FAIL'}) ([pscustomobject]@{HistoryFocusAfterOpeningPage=$historyTabRestored;SettingsFocus=$settingsFocus;KeyboardArrowSent=$historyTabRestored.Found})
  if($settingsFound){Send-Key 13;Start-Sleep -Milliseconds 250}
  $settingsNames=Get-AppAutomationNames
  $settingsContent=@('Work and break intervals','Work interval (minutes)','Break duration (seconds)'|Where-Object{$_ -in $settingsNames})
  $settingsPage=$settingsFound -and $settingsContent.Count -ge 3
  Add-Result 'Keyboard activation opens Settings while Narrator runs' $(if($settingsPage){'PASS'}else{'FAIL'}) ([pscustomobject]@{Focus=$settingsFocus;ContentNamesReached=$settingsContent;ExpectedContent=@('Work and break intervals','Work interval (minutes)','Break duration (seconds)');Names=$settingsNames})

  $aboutFocus=Focus-AppElement 'About' 'ControlType.RadioButton'
  if($aboutFocus.Found){Send-Key 13;Start-Sleep -Milliseconds 250}
  $aboutNames=Get-AppAutomationNames
  $updateControl=$aboutFocus.Found -and ('Check for Updates' -in $aboutNames)
  Add-Result 'Keyboard-accessible About section exposes the Check for Updates control' $(if($updateControl){'PASS'}else{'FAIL'}) ([pscustomobject]@{AboutFocus=$aboutFocus;UpdateControlPresent=('Check for Updates' -in $aboutNames)})
  $checkUpdatesFocus=if($updateControl){Focus-AppElement 'Check for Updates' 'ControlType.Button'}else{[pscustomobject]@{Found=$false;Target='Check for Updates';Names=$aboutNames}}
  if($checkUpdatesFocus.Found){Send-Key 13}
  $updateWatch=[Diagnostics.Stopwatch]::StartNew();$updateState='';$updateNames=@()
  while($checkUpdatesFocus.Found -and $updateWatch.Elapsed.TotalSeconds -lt 30){
    Start-Sleep -Milliseconds 250;$updateNames=Get-AppAutomationNames
    if('Eye Break Reminder is up to date.' -in $updateNames){$updateState='up-to-date';break}
    if('Latest stable version: unavailable' -in $updateNames){$updateState='unavailable';break}
  }
  Add-Result 'Keyboard-triggered live update check reports the current published version as up to date' $(if($updateState -eq 'up-to-date'){'PASS'}elseif($updateState -eq 'unavailable'){'FAIL'}else{'NOT TESTED'}) ([pscustomobject]@{CheckFocus=$checkUpdatesFocus;State=$updateState;ElapsedSeconds=[Math]::Round($updateWatch.Elapsed.TotalSeconds,2);Names=$updateNames;Reason=$(if($updateState -eq ''){'No terminal update-check result appeared within 30 seconds.'}else{$null})})

  $timer=Focus-AppElement 'Timer' 'ControlType.RadioButton'
  if($timer.Found){Send-Key 13;Start-Sleep -Milliseconds 250}
  $breakAction=Focus-AppElement 'Take a break now' 'ControlType.Button'
  if($timer.Found -and $breakAction.Found){Send-Key 13;Start-Sleep -Milliseconds 500}
  $windows=Get-AppWindows;$breakWindows=@($windows|Where-Object{-not $_.IsMain})
  Add-Result 'Keyboard activation of the break control opens the in-app reminder while Narrator runs' $(if($timer.Found -and $breakAction.Found -and $breakWindows.Count -gt 0){'PASS'}else{'FAIL'}) ([pscustomobject]@{TimerFocus=$timer;BreakActionFocus=$breakAction;AppWindows=$windows;BreakWindowCount=$breakWindows.Count})
  if($breakWindows.Count -gt 0){Send-Key 27;Start-Sleep -Milliseconds 250}
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
