param(
  [string]$PublishedExecutablePath = (Join-Path $env:RUNNER_TEMP 'eye-break-reminder-v1.2.0-published-assets\EyeBreakReminder.exe'),
  [string]$EvidenceDirectory = (Join-Path (Get-Location) 'build\post-release-evidence'),
  [int]$MaximumWaitSeconds = 85
)
$ErrorActionPreference = 'Stop'
$expectedHash = '2895c80f942dd03186305d913516700552524ec5ba9a77da0dab457a3265fcc6'
$events = [System.Collections.Generic.List[object]]::new()
$appProcess = $null
$ownedData = $false
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$native = @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class EBR_SHELL_NOTICE_NATIVE {
  public delegate bool EnumCallback(IntPtr hwnd, IntPtr data);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool EnumWindows(EnumCallback callback, IntPtr data);
  [DllImport("user32.dll", SetLastError=true)] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool IsIconic(IntPtr hwnd);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern int GetWindowTextW(IntPtr hwnd, StringBuilder text, int maxCount);
  [DllImport("user32.dll", SetLastError=true)] private static extern int GetWindowTextLengthW(IntPtr hwnd);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern int GetClassNameW(IntPtr hwnd, StringBuilder name, int maxCount);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool ShowWindow(IntPtr hwnd, int command);
  [DllImport("winmm.dll", ExactSpelling=true)] public static extern uint waveOutGetNumDevs();
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
function Add-Result([string]$name,[string]$status,$details=$null){
  $events.Add([pscustomobject]@{Name=$name;Status=$status;Details=$details;Utc=[DateTime]::UtcNow.ToString('o')})
  Write-Host "[$status] $name"
}
function Get-AppWindows {
  $result = @()
  foreach ($handle in [EBR_SHELL_NOTICE_NATIVE]::WindowsForProcess($appProcess.Id)) {
    $result += [pscustomobject]@{
      Handle=('0x{0:X}' -f $handle.ToInt64())
      Class=[EBR_SHELL_NOTICE_NATIVE]::ClassName($handle)
      Title=[EBR_SHELL_NOTICE_NATIVE]::Text($handle)
      Minimized=[EBR_SHELL_NOTICE_NATIVE]::IsIconic($handle)
    }
  }
  return $result
}
function Get-DesktopAutomationNames {
  $names = [System.Collections.Generic.List[object]]::new()
  $root = [System.Windows.Automation.AutomationElement]::RootElement
  $top = $root.FindAll([System.Windows.Automation.TreeScope]::Children,[System.Windows.Automation.Condition]::TrueCondition)
  for ($i=0; $i -lt [Math]::Min($top.Count,120); $i++) {
    $element=$top.Item($i)
    try {
      $current=$element.Current
      if (-not [string]::IsNullOrWhiteSpace($current.Name)) { $names.Add([pscustomobject]@{Name=$current.Name;ProcessId=$current.ProcessId;ControlType=$current.ControlType.ProgrammaticName;Window=$true}) }
      $children=$element.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
      for ($j=0; $j -lt [Math]::Min($children.Count,500); $j++) {
        try { $child=$children.Item($j);$c=$child.Current;if(-not [string]::IsNullOrWhiteSpace($c.Name)){$names.Add([pscustomobject]@{Name=$c.Name;ProcessId=$c.ProcessId;ControlType=$c.ControlType.ProgrammaticName;Window=$false})} } catch {}
      }
    } catch {}
  }
  return $names.ToArray()
}
function Save-DesktopScreenshot([string]$Path) {
  $screen=[System.Windows.Forms.Screen]::PrimaryScreen.Bounds
  $bitmap=[System.Drawing.Bitmap]::new($screen.Width,$screen.Height)
  $graphics=[System.Drawing.Graphics]::FromImage($bitmap)
  try { $graphics.CopyFromScreen($screen.Location,[System.Drawing.Point]::Empty,$screen.Size);$bitmap.Save($Path,[System.Drawing.Imaging.ImageFormat]::Png) }
  finally { $graphics.Dispose();$bitmap.Dispose() }
}
try {
  New-Item -ItemType Directory -Force -Path $EvidenceDirectory | Out-Null
  $actualHash=(Get-FileHash -LiteralPath $PublishedExecutablePath -Algorithm SHA256).Hash.ToLowerInvariant()
  if($actualHash -cne $expectedHash){throw "Notification probe executable is not the exact published v1.2.0 EXE: $actualHash"}
  Add-Result 'Notification probe uses the exact published v1.2.0 EXE' 'PASS' $actualHash

  $dataPath=Join-Path $env:LOCALAPPDATA 'EyeBreakReminder'
  if(Test-Path -LiteralPath $dataPath){Add-Result 'Disposable notification profile is clean' 'NOT TESTED' ([pscustomobject]@{Path=$dataPath;Reason='Existing profile data was preserved; no app process was launched.'});return}
  $ownedData=$true
  New-Item -ItemType Directory -Path $dataPath | Out-Null
  $settings=@(
    'workMinutes=1','breakSeconds=5','sound=0','volume=0','mode=0','monitor=0','theme=2','breakModeColors=1',
    'alarm=0','repeat=0','notifications=1','snooze=0','autoStart=1','startup=0','tray=1','restore=0',
    'pauseLocked=0','history=1','trayExplained=1','schedule=0'
  ) -join "`n"
  $settingsPath=Join-Path $dataPath 'settings.ini'
  Set-Content -LiteralPath $settingsPath -Value ($settings+"`n") -Encoding ASCII -NoNewline
  $fixtureText=[IO.File]::ReadAllText($settingsPath)
  if($fixtureText.Contains("`r") -or $fixtureText -notmatch '(?m)^notifications=1$'){throw 'The isolated settings fixture is not LF-delimited with notifications enabled.'}
  Add-Result 'Isolated profile requests a one-minute work cycle with Shell notifications enabled' 'PASS' ([pscustomobject]@{SettingsPath=(Join-Path $dataPath 'settings.ini');WorkMinutes=1;BreakSeconds=5;Notifications=1;Alarm=0;Schedule=0;DataDirectory=$dataPath})

  $appProcess=Start-Process -FilePath $PublishedExecutablePath -PassThru
  $watch=[Diagnostics.Stopwatch]::StartNew();$main=[IntPtr]::Zero
  while($watch.Elapsed.TotalSeconds -lt 20){
    $appProcess.Refresh();if($appProcess.HasExited){break}
    foreach($handle in [EBR_SHELL_NOTICE_NATIVE]::WindowsForProcess($appProcess.Id)){if([EBR_SHELL_NOTICE_NATIVE]::ClassName($handle) -eq 'EyeBreakReminder.Native'){$main=$handle;break}}
    if($main -ne [IntPtr]::Zero){break};Start-Sleep -Milliseconds 150
  }
  if($appProcess.HasExited -or $main -eq [IntPtr]::Zero){throw 'The published app did not create its main window for the actual reminder cycle.'}
  $readSettings=Get-Content -LiteralPath (Join-Path $dataPath 'settings.ini') -Raw
  if($readSettings -notmatch '(?m)^notifications=1\s*$'){throw 'The running app did not preserve the test profile notification setting.'}
  Add-Result 'Published app loaded the notification-enabled profile' 'PASS' ([pscustomobject]@{ProcessId=$appProcess.Id;MainWindow=('0x{0:X}' -f $main.ToInt64());SettingsPath=(Join-Path $dataPath 'settings.ini')})
  [void][EBR_SHELL_NOTICE_NATIVE]::ShowWindow($main,6)
  Start-Sleep -Milliseconds 400
  $minimized=[EBR_SHELL_NOTICE_NATIVE]::IsIconic($main)
  Add-Result 'Main application window is actually minimized before the timer expires' $(if($minimized){'PASS'}else{'FAIL'}) ([pscustomobject]@{MainWindow=('0x{0:X}' -f $main.ToInt64());IsIconic=$minimized})
  if(-not $minimized){throw 'The app could not be minimized; Shell notification trigger precondition was not met.'}

  $watch=[Diagnostics.Stopwatch]::StartNew();$breakWindow=$false;$firstWindows=@();$screenshot=$null
  while($watch.Elapsed.TotalSeconds -lt $MaximumWaitSeconds){
    $appProcess.Refresh()
    if($appProcess.HasExited){throw 'The published app exited during the one-minute real-time reminder cycle.'}
    $windows=Get-AppWindows
    $break=@($windows|Where-Object {$_.Class -ne 'EyeBreakReminder.Native'})
    if($break.Count -gt 0){$breakWindow=$true;$firstWindows=$windows;break}
    Start-Sleep -Milliseconds 200
  }
  if(-not $breakWindow){Add-Result 'Real one-minute timer cycle opens the app-owned reminder window' 'FAIL' ([pscustomobject]@{ElapsedSeconds=[Math]::Round($watch.Elapsed.TotalSeconds,2);MaximumWaitSeconds=$MaximumWaitSeconds;Windows=(Get-AppWindows)});throw 'No app-owned break window appeared within the actual 60-second work interval plus timeout.'}
  Add-Result 'Real one-minute timer cycle opens the app-owned reminder window' 'PASS' ([pscustomobject]@{ElapsedSeconds=[Math]::Round($watch.Elapsed.TotalSeconds,2);BreakWindows=$firstWindows;ActualWallClockTimer=$true})
  $screenshot=Join-Path $EvidenceDirectory 'windows-11-real-reminder-shell-notification.png'
  Save-DesktopScreenshot $screenshot
  Add-Result 'Desktop screenshot captured during the real reminder cycle' 'PASS' ([pscustomobject]@{Path=$screenshot;Method='CopyFromScreen';Screen=(Get-CimInstance Win32_VideoController|Select-Object -First 1 -ExpandProperty CurrentHorizontalResolution), (Get-CimInstance Win32_VideoController|Select-Object -First 1 -ExpandProperty CurrentVerticalResolution)})

  $automationNames=Get-DesktopAutomationNames
  $notificationMatches=@($automationNames|Where-Object {$_.Name -match 'Time to rest your eyes|Look 20 feet / 6 metres away'})
  $shellProcesses=@(Get-Process -Name explorer,ShellExperienceHost,StartMenuExperienceHost -ErrorAction SilentlyContinue|Select-Object -Unique ProcessName,Id)
  if($notificationMatches.Count -gt 0){
    Add-Result 'A visible Windows Shell notification exposes the app title or reminder text' 'PASS' ([pscustomobject]@{Matches=$notificationMatches;OtherDesktopNames=@($automationNames|Where-Object {$_.ProcessId -ne $appProcess.Id}|Select-Object -First 60);ShellProcesses=$shellProcesses;Screenshot=$screenshot})
  }else{
    Add-Result 'A separate visible Windows Shell notification was observed' 'NOT TESTED' ([pscustomobject]@{Reason='The real app timer and in-app reminder ran with notifications enabled while minimized, but UI Automation did not expose the Shell balloon text. Screenshot is retained for visual review; a successful Shell request or in-app window is not counted as a visible balloon.';OtherDesktopNames=@($automationNames|Where-Object {$_.ProcessId -ne $appProcess.Id}|Select-Object -First 80);ShellProcesses=$shellProcesses;Screenshot=$screenshot})
  }
  Add-Result 'Modern Windows Toast notification feature' 'NOT APPLICABLE' 'The implementation uses Shell_NotifyIconW with NIF_INFO; it has no modern Toast API or app identity path.'
}catch{
  Add-Result 'Windows Shell notification probe completed without an automation exception' 'FAIL' $_.Exception.Message
}finally{
  if($appProcess){try{$appProcess.Refresh();if(-not $appProcess.HasExited){[void]$appProcess.CloseMainWindow();if(-not $appProcess.WaitForExit(3000)){Stop-Process -Id $appProcess.Id -Force -ErrorAction SilentlyContinue;$appProcess.WaitForExit(3000)}}}catch{}}
  if($ownedData){$dataPath=Join-Path $env:LOCALAPPDATA 'EyeBreakReminder';if(Test-Path -LiteralPath $dataPath){Remove-Item -LiteralPath $dataPath -Recurse -Force}}
  $result=[pscustomobject]@{
    Application='Eye Break Reminder'
    Release='v1.2.0'
    ExecutableSHA256=$expectedHash
    Environment=[pscustomobject]@{OS=(Get-CimInstance Win32_OperatingSystem).Caption;Build=(Get-CimInstance Win32_OperatingSystem).BuildNumber;NativeArchitecture=[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString();RunnerArchitecture=$env:RUNNER_ARCH;WaveOutDeviceCount=[EBR_SHELL_NOTICE_NATIVE]::waveOutGetNumDevs()}
    Pass=(@($events|Where-Object Status -eq 'PASS')).Count
    Fail=(@($events|Where-Object Status -eq 'FAIL')).Count
    NotTested=(@($events|Where-Object Status -eq 'NOT TESTED')).Count
    NotApplicable=(@($events|Where-Object Status -eq 'NOT APPLICABLE')).Count
    Events=$events.ToArray()
    CompletedUtc=[DateTime]::UtcNow.ToString('o')
  }
  $result|ConvertTo-Json -Depth 14|Set-Content (Join-Path $EvidenceDirectory 'windows-11-shell-notification-probe.json') -Encoding UTF8
}
$failures=@($events|Where-Object Status -eq 'FAIL')
if($failures.Count -gt 0){exit 1}
