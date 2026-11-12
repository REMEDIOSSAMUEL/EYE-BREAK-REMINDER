param(
  [string]$Executable = (Join-Path $PSScriptRoot '..\build\gui-test\EyeBreakReminder.exe'),
  [string]$EvidenceDirectory = (Join-Path $PSScriptRoot '..\build\gui-test\evidence')
)
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$expectedVersion = (Get-Content -LiteralPath (Join-Path $repoRoot 'VERSION') -Raw).Trim()
if($expectedVersion -notmatch '^\d+\.\d+\.\d+$'){throw 'VERSION must contain a three-component release version.'}
$expectedExe = [IO.Path]::GetFullPath((Join-Path $repoRoot 'build\gui-test\EyeBreakReminder.exe'))
$exePath = [IO.Path]::GetFullPath($Executable)
if ($exePath -ine $expectedExe) { throw "Refusing to launch anything other than the isolated GUI test executable: $expectedExe" }
if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) { throw "GUI test executable is missing: $exePath (run make gui-test first)." }
$expectedEvidence=[IO.Path]::GetFullPath((Join-Path $repoRoot 'build\gui-test\evidence'))
if ([IO.Path]::GetFullPath($EvidenceDirectory) -ine $expectedEvidence) { throw "Refusing to write screenshots outside the isolated test evidence folder: $expectedEvidence" }
$EvidenceDirectory=$expectedEvidence
$dataDirectory = Join-Path (Split-Path -Parent $exePath) 'test-data'
$fixturePath = Join-Path (Split-Path -Parent $exePath) 'test-update-response.txt'
[void][IO.Directory]::CreateDirectory($EvidenceDirectory)
$script:testPid = 0
$script:mainWindow = [IntPtr]::Zero
$script:events = [System.Collections.Generic.List[object]]::new()
$script:assertionCount = 0
$script:updateStatusHandle = [IntPtr]::Zero
$script:updateLatestHandle = [IntPtr]::Zero
$script:updateInstalledHandle = [IntPtr]::Zero

$native = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
[StructLayout(LayoutKind.Sequential)] public struct EBR_GUI_RECT { public int Left, Top, Right, Bottom; }
[StructLayout(LayoutKind.Sequential)] public struct EBR_GUI_POINT { public int X, Y; }
public static class EBR_GUI_NATIVE {
  public delegate bool EnumCallback(IntPtr hwnd, IntPtr data);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool EnumWindows(EnumCallback callback, IntPtr data);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool EnumChildWindows(IntPtr parent, EnumCallback callback, IntPtr data);
  [DllImport("user32.dll", SetLastError=true)] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll", SetLastError=true)] public static extern bool AttachThreadInput(uint attach, uint attachTo, bool attachState);
  [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr SetFocus(IntPtr hwnd);
  [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr GetFocus();
  [DllImport("user32.dll", SetLastError=true)] public static extern int GetDlgCtrlID(IntPtr hwnd);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool IsWindowEnabled(IntPtr hwnd);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool GetWindowRect(IntPtr hwnd, out EBR_GUI_RECT rect);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool GetClientRect(IntPtr hwnd, out EBR_GUI_RECT rect);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool ClientToScreen(IntPtr hwnd, ref EBR_GUI_POINT point);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern int GetWindowTextW(IntPtr hwnd, StringBuilder text, int maxCount);
  [DllImport("user32.dll", SetLastError=true)] private static extern int GetWindowTextLengthW(IntPtr hwnd);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern int GetClassNameW(IntPtr hwnd, StringBuilder name, int maxCount);
  [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr GetParent(IntPtr hwnd);
  [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr SendMessageW(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool InvalidateRect(IntPtr hwnd, IntPtr rect, bool erase);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool UpdateWindow(IntPtr hwnd);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern bool SetWindowTextW(IntPtr hwnd, string text);
  public static bool SetRemoteControlText(IntPtr hwnd, string value) {
    IntPtr text=Marshal.StringToHGlobalUni(value);
    try { return SendMessageW(hwnd,0x000C,IntPtr.Zero,text)!=IntPtr.Zero; }
    finally { Marshal.FreeHGlobal(text); }
  }
  [DllImport("user32.dll", SetLastError=true)] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr insertAfter, int x, int y, int width, int height, uint flags);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool SetForegroundWindow(IntPtr hwnd);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
  [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll", SetLastError=true)] public static extern uint GetDpiForWindow(IntPtr hwnd);
  [DllImport("user32.dll", SetLastError=true)] public static extern int GetSystemMetrics(int index);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern uint RegisterWindowMessageW(string name);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool PostMessageW(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
  public static string Text(IntPtr hwnd) { int n=SendMessageW(hwnd,0x000E,IntPtr.Zero,IntPtr.Zero).ToInt32();IntPtr b=Marshal.AllocHGlobal(Math.Max(2,n+2)*2);try{SendMessageW(hwnd,0x000D,new IntPtr(Math.Max(2,n+2)),b);return Marshal.PtrToStringUni(b)??"";}finally{Marshal.FreeHGlobal(b);} }
  public static string ClassName(IntPtr hwnd) { StringBuilder b=new StringBuilder(256); GetClassNameW(hwnd,b,b.Capacity); return b.ToString(); }
  public static IntPtr[] TopWindowsForProcess(int pid) {
    List<IntPtr> result=new List<IntPtr>(); EnumCallback cb=delegate(IntPtr hwnd,IntPtr ignored){uint actual;GetWindowThreadProcessId(hwnd,out actual);if(actual==(uint)pid)result.Add(hwnd);return true;};
    EnumWindows(cb,IntPtr.Zero);GC.KeepAlive(cb);return result.ToArray();
  }
  public static IntPtr[] Children(IntPtr root) {
    List<IntPtr> result=new List<IntPtr>(); EnumCallback cb=delegate(IntPtr hwnd,IntPtr ignored){result.Add(hwnd);return true;};
    EnumChildWindows(root,cb,IntPtr.Zero);GC.KeepAlive(cb);return result.ToArray();
  }
}
'@
Add-Type -TypeDefinition $native -Language CSharp -ErrorAction Stop
Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
Add-Type -AssemblyName System.Drawing -ErrorAction Stop

function Add-Result([string]$Name, [string]$Status, $Details=$null) {
  $script:events.Add([pscustomobject]@{Name=$Name;Status=$Status;Details=$Details;Utc=[DateTime]::UtcNow.ToString('o')})
}
function Assert-That([bool]$Condition, [string]$Name, $Details=$null) {
  if (-not $Condition) { Add-Result $Name 'FAIL' $Details; throw "GUI acceptance failed: $Name ($Details)" }
  $script:assertionCount++
  Add-Result $Name 'PASS' $Details
}
function Get-Rect([IntPtr]$Handle) {
  $rect = New-Object EBR_GUI_RECT
  if (-not [EBR_GUI_NATIVE]::GetWindowRect($Handle,[ref]$rect)) { throw "GetWindowRect failed for $Handle" }
  [pscustomobject]@{Left=$rect.Left;Top=$rect.Top;Right=$rect.Right;Bottom=$rect.Bottom;Width=$rect.Right-$rect.Left;Height=$rect.Bottom-$rect.Top}
}
function Get-ClientGeometry([IntPtr]$Handle) {
  $rect = New-Object EBR_GUI_RECT
  if (-not [EBR_GUI_NATIVE]::GetClientRect($Handle,[ref]$rect)) { throw 'GetClientRect failed.' }
  $origin = New-Object EBR_GUI_POINT
  if (-not [EBR_GUI_NATIVE]::ClientToScreen($Handle,[ref]$origin)) { throw 'ClientToScreen failed.' }
  [pscustomobject]@{Left=$origin.X;Top=$origin.Y;Width=$rect.Right-$rect.Left;Height=$rect.Bottom-$rect.Top}
}
function Get-VisibleControls([IntPtr]$Root) {
  foreach ($handle in [EBR_GUI_NATIVE]::Children($Root)) {
    $processId = [uint32]0
    [void][EBR_GUI_NATIVE]::GetWindowThreadProcessId($handle,[ref]$processId)
    if ($processId -ne $script:testPid -or -not [EBR_GUI_NATIVE]::IsWindowVisible($handle)) { continue }
    [pscustomobject]@{Handle=$handle;Id=[EBR_GUI_NATIVE]::GetDlgCtrlID($handle);Class=[EBR_GUI_NATIVE]::ClassName($handle);Text=[EBR_GUI_NATIVE]::Text($handle);Enabled=[EBR_GUI_NATIVE]::IsWindowEnabled($handle);Rect=(Get-Rect $handle)}
  }
}
function Get-Control([IntPtr]$Root,[int]$Id,[string]$Name) {
  $matches = @(Get-VisibleControls $Root | Where-Object Id -eq $Id)
  if ($matches.Count -ne 1) {
    $visible=@(Get-VisibleControls $Root | ForEach-Object { "ID=$($_.Id) Class=$($_.Class) Text='$($_.Text)' Enabled=$($_.Enabled)" }) -join '; '
    throw "Expected one visible $Name control ID $Id, found $($matches.Count). Visible controls: $visible"
  }
  $matches[0]
}
function Click-Control([IntPtr]$Root,[int]$Id,[string]$Name) {
  $control = Get-Control $Root $Id $Name
  if (-not $control.Enabled) { throw "$Name is disabled." }
  [void][EBR_GUI_NATIVE]::SendMessageW($control.Handle,0x00F5,[IntPtr]::Zero,[IntPtr]::Zero)
}
function Get-Check([IntPtr]$Root,[int]$Id,[string]$Name) {
  $control = Get-Control $Root $Id $Name
  ([EBR_GUI_NATIVE]::SendMessageW($control.Handle,0x00F0,[IntPtr]::Zero,[IntPtr]::Zero)).ToInt32() -eq 1
}
function Set-Check([IntPtr]$Root,[int]$Id,[bool]$Value,[string]$Name) {
  if ((Get-Check $Root $Id $Name) -ne $Value) { Click-Control $Root $Id $Name }
  Assert-That ((Get-Check $Root $Id $Name) -eq $Value) "$Name checkbox" $Value
}
function Set-AppFocus([IntPtr]$Handle) {
  $targetPid=[uint32]0;$targetThread=[EBR_GUI_NATIVE]::GetWindowThreadProcessId($Handle,[ref]$targetPid);$testThread=[EBR_GUI_NATIVE]::GetCurrentThreadId()
  if($targetPid -ne $script:testPid -or -not [EBR_GUI_NATIVE]::IsWindowEnabled($Handle)){throw 'Refusing to focus a control outside the enabled isolated test app.'}
  [void][EBR_GUI_NATIVE]::SetForegroundWindow($script:mainWindow)
  $attached=[EBR_GUI_NATIVE]::AttachThreadInput($testThread,$targetThread,$true)
  if(-not $attached){throw 'Could not attach keyboard input to the isolated app.'}
  try {[void][EBR_GUI_NATIVE]::SetFocus($Handle);$actual=[EBR_GUI_NATIVE]::GetFocus()}
  finally {[void][EBR_GUI_NATIVE]::AttachThreadInput($testThread,$targetThread,$false)}
  if($actual -ne $Handle){throw 'The requested isolated app control did not receive keyboard focus.'}
}
function Set-Edit([IntPtr]$Root,[int]$Id,[string]$Value,[string]$Name) {
  $control = Get-Control $Root $Id $Name
  if ($control.Class -ne 'Edit' -or -not $control.Enabled) { throw "$Name is not an enabled Edit control." }
  Set-AppFocus $control.Handle
  if(-not [EBR_GUI_NATIVE]::SetRemoteControlText($control.Handle,$Value)){throw "WM_SETTEXT failed for $Name."}
  $nextId=if($Id -eq 100){101}else{130}
  Set-AppFocus (Get-Control $Root $nextId 'Focus target after edit').Handle
  $actualText=[EBR_GUI_NATIVE]::Text($control.Handle)
  Assert-That ($actualText.Trim() -eq $Value) "$Name text" ([pscustomobject]@{Expected=$Value;Actual=$actualText})
  $settingKey=if($Id -eq 100){'workMinutes'}elseif($Id -eq 101){'breakSeconds'}else{''}
  if($settingKey){$saved=Get-Content -LiteralPath (Join-Path $dataDirectory 'settings.ini') -Raw;Assert-That ($saved -match ("(?m)^$settingKey=$Value$")) "$Name value is applied and persisted" ([regex]::Match($saved,"(?m)^$settingKey=.*$").Value)}
}
function Set-Combo([IntPtr]$Root,[int]$Id,[int]$Index,[string]$Name) {
  $control = Get-Control $Root $Id $Name
  if ($control.Class -ne 'ComboBox') { throw "$Name is not a ComboBox." }
  [void][EBR_GUI_NATIVE]::SendMessageW($control.Handle,0x014E,[IntPtr]::new($Index),[IntPtr]::Zero)
  $parent = [EBR_GUI_NATIVE]::GetParent($control.Handle)
  $wParam = [IntPtr]::new([long](($Id -band 0xffff) -bor (1 -shl 16)))
  [void][EBR_GUI_NATIVE]::SendMessageW($parent,0x0111,$wParam,$control.Handle)
  $selected = ([EBR_GUI_NATIVE]::SendMessageW($control.Handle,0x0147,[IntPtr]::Zero,[IntPtr]::Zero)).ToInt32()
  Assert-That ($selected -eq $Index) "$Name selection" $Index
}
function Get-Combo([IntPtr]$Root,[int]$Id,[string]$Name) {
  $control = Get-Control $Root $Id $Name
  ([EBR_GUI_NATIVE]::SendMessageW($control.Handle,0x0147,[IntPtr]::Zero,[IntPtr]::Zero)).ToInt32()
}
function Wait-MainWindow([int]$TimeoutSeconds=15) {
  $watch = [Diagnostics.Stopwatch]::StartNew()
  while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
    $process = Get-Process -Id $script:testPid -ErrorAction SilentlyContinue
    if ($process) { $process.Refresh(); $handle=$process.MainWindowHandle
      if ($handle -ne [IntPtr]::Zero -and [EBR_GUI_NATIVE]::ClassName($handle) -eq 'EyeBreakReminder.Native') {
        $actual=[uint32]0;[void][EBR_GUI_NATIVE]::GetWindowThreadProcessId($handle,[ref]$actual)
        if ($actual -eq $script:testPid) { return $handle }
      }
    }
    Start-Sleep -Milliseconds 100
  }
  throw 'The isolated test process did not create its main window.'
}
function Find-BreakWindow {
  $windows = @([EBR_GUI_NATIVE]::TopWindowsForProcess($script:testPid) | Where-Object { [EBR_GUI_NATIVE]::ClassName($_) -eq 'EyeBreakReminder.Break' -and [EBR_GUI_NATIVE]::IsWindowVisible($_) })
  if ($windows.Count -gt 1) { throw 'Multiple break windows belong to the isolated test process.' }
  if ($windows.Count -eq 1) { return $windows[0] }
  return [IntPtr]::Zero
}
function Wait-BreakWindow([int]$TimeoutSeconds=8) {
  $watch=[Diagnostics.Stopwatch]::StartNew()
  while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) { $window=Find-BreakWindow;if($window -ne [IntPtr]::Zero){return $window};Start-Sleep -Milliseconds 100 }
  throw 'The expected eye-break reminder window did not open.'
}
function Wait-Status([string]$Expected,[int]$TimeoutSeconds=5) {
  $watch=[Diagnostics.Stopwatch]::StartNew();$last=''
  while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) { $last=[EBR_GUI_NATIVE]::Text((Get-Control $script:mainWindow 41 'Timer status').Handle);if($last -like "*$Expected*"){return $last};Start-Sleep -Milliseconds 100 }
  throw "Timer status did not contain '$Expected'; last value: '$last'."
}
function Switch-Settings([int]$Section) {
  Click-Control $script:mainWindow 12 'Settings navigation'
  Click-Control $script:mainWindow (130+$Section) "Settings section $Section"
}
function Get-StaticHandle([string]$Text,[string]$Name) {
  $matches=@(Get-VisibleControls $script:mainWindow | Where-Object { $_.Class -eq 'Static' -and $_.Text -eq $Text })
  if($matches.Count -ne 1){throw "Expected one visible $Name static label with text '$Text'; found $($matches.Count)."}
  $matches[0].Handle
}
function Initialize-UpdateHandles {
  if($script:updateStatusHandle -ne [IntPtr]::Zero){return}
  $script:updateStatusHandle=Get-StaticHandle 'Select Check for Updates to query the official public GitHub Releases API.' 'Initial update status'
  $script:updateLatestHandle=Get-StaticHandle 'Latest stable version: not checked' 'Initial latest version'
  $script:updateInstalledHandle=Get-StaticHandle ("Installed version: $version") 'Installed version'
}
function Switch-Timer { Click-Control $script:mainWindow 10 'Timer navigation' }
function Set-Theme([int]$Theme) {
  Switch-Settings 4
  Set-Combo $script:mainWindow 106 $Theme 'Theme'
  Switch-Timer
}
function Set-Intervals([int]$Work,[int]$Break) {
  Switch-Settings 0
  Set-Edit $script:mainWindow 100 ([string]$Work) 'Work interval'
  Set-Edit $script:mainWindow 101 ([string]$Break) 'Break duration'
}
function Get-TimerSeconds {
  $text=[EBR_GUI_NATIVE]::Text((Get-Control $script:mainWindow 40 'Timer countdown').Handle)
  if ($text -notmatch '^(\d+):(\d{2})$') { throw "Unexpected timer format: $text" }
  return ([int]$Matches[1]*60+[int]$Matches[2])
}
function Get-UiaNames([IntPtr]$Window) {
  $root=[System.Windows.Automation.AutomationElement]::FromHandle($Window)
  if ($root.Current.ProcessId -ne $script:testPid) { throw 'The UI Automation root belongs to a different process.' }
  $items=$root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
  @($items | Where-Object { $_.Current.ProcessId -eq $script:testPid } | ForEach-Object { try { $_.Current.Name } catch { '' } } | Where-Object { $_ })
}
function Save-Screenshot([IntPtr]$Window,[string]$Name) {
  if (-not [EBR_GUI_NATIVE]::IsWindowVisible($Window)) { throw "Screenshot window is not visible: $Name" }
  [void][EBR_GUI_NATIVE]::SetForegroundWindow($Window)
  Start-Sleep -Milliseconds 180
  $bounds=Get-Rect $Window
  if ($bounds.Width -lt 100 -or $bounds.Height -lt 80) { throw 'Screenshot window bounds are invalid.' }
  $path=Join-Path $EvidenceDirectory $Name
  $bitmap=[System.Drawing.Bitmap]::new($bounds.Width,$bounds.Height)
  $graphics=[System.Drawing.Graphics]::FromImage($bitmap)
  try {
    $targetHdc=$graphics.GetHdc()
    try {
      $captured=[EBR_GUI_NATIVE]::PrintWindow($Window,$targetHdc,2)
      if(-not $captured){$captured=[EBR_GUI_NATIVE]::PrintWindow($Window,$targetHdc,0)}
      if(-not $captured){throw "PrintWindow could not capture '$Name'."}
    } finally {$graphics.ReleaseHdc($targetHdc)}
    $bitmap.Save($path,[System.Drawing.Imaging.ImageFormat]::Png)
  }
  finally { $graphics.Dispose();$bitmap.Dispose() }
  Add-Result 'Screenshot' 'PASS' $path
  return $path
}
function Assert-StatusAlignment([string]$Name) {
  $dpi=[EBR_GUI_NATIVE]::GetDpiForWindow($script:mainWindow)
  $scale=100
  try { $scale=[int](Get-ItemPropertyValue -LiteralPath 'HKCU:\Software\Microsoft\Accessibility' -Name TextScaleFactor -ErrorAction Stop) } catch { }
  $textScale=[Math]::Min(2.25,[Math]::Max(1.0,$scale/100.0))
  $px={ param([double]$value) [int][Math]::Floor($value*$dpi/96.0+0.5) }
  $client=Get-ClientGeometry $script:mainWindow
  $button=Get-Control $script:mainWindow 22 'Take a break button'
  $buttonTop=$button.Rect.Top-$client.Top
  $navBottom=(& $px 16)+(& $px ([Math]::Max(40.0,31.0*$textScale)))
  $timerTop=$navBottom+(& $px 22)
  $statusBottom=$timerTop+(& $px 88)
  $diameter=[Math]::Min((& $px 272),[Math]::Min($client.Width-(& $px 100),$buttonTop-$statusBottom-(& $px 18)))
  $diameter=[Math]::Max(1,$diameter)
  $ringLeft=[int][Math]::Floor(($client.Width-$diameter)/2.0)
  $status=Get-Control $script:mainWindow 41 'Timer status'
  $actual=($status.Rect.Left+$status.Rect.Right)/2.0
  $expected=$client.Left+$ringLeft+$diameter/2.0
  $difference=[Math]::Abs($actual-$expected)
  Assert-That ($difference -le 1.0) "Status centered above timer at $Name" ([pscustomobject]@{Dpi=$dpi;TextScale=$textScale;ActualCenter=$actual;RingCenter=$expected;Difference=$difference;WindowWidth=$client.Width;RingDiameter=$diameter})
}
function Write-UpdateFixture([int]$Status,[string]$Body,[string]$Failure='none',[int]$DelayMilliseconds=0) {
  $content="status=$Status`r`nfailure=$Failure`r`ndelay_ms=$DelayMilliseconds`r`n`r`n$Body"
  [IO.File]::WriteAllText($fixturePath,$content,[Text.UTF8Encoding]::new($false))
}
function Run-UpdateFixture([string]$Name,[int]$Status,[string]$Body,[string]$Failure,[string]$Expected,[int]$Delay=0) {
  $before=0
  if($Delay -ge 2000){Switch-Timer;$before=Get-TimerSeconds}
  Switch-Settings 5
  Initialize-UpdateHandles
  $fixtureDelay=[Math]::Max($Delay,300)
  Write-UpdateFixture $Status $Body $Failure $fixtureDelay
  Click-Control $script:mainWindow 160 'Check for Updates'
  $button=Get-Control $script:mainWindow 160 'Check for Updates'
  Assert-That (-not $button.Enabled) "$Name busy button disabled"
  Assert-That ([EBR_GUI_NATIVE]::Text($script:updateStatusHandle) -like '*Checking*') "$Name checking feedback"
  if ($fixtureDelay -ge 2000) {
    Start-Sleep -Milliseconds 1200
    Switch-Timer
    Start-Sleep -Milliseconds 900
    $after=Get-TimerSeconds
    Assert-That ($after -lt $before-5) "$Name timer continues during network request" ([pscustomobject]@{Before=$before;After=$after})
    Switch-Settings 5
  }
  $watch=[Diagnostics.Stopwatch]::StartNew();$enabled=$false
  while ($watch.Elapsed.TotalSeconds -lt 12) { try { $enabled=(Get-Control $script:mainWindow 160 'Check for Updates').Enabled } catch { };if($enabled){break};Start-Sleep -Milliseconds 100 }
  Assert-That $enabled "$Name check completes"
  $statusText=[EBR_GUI_NATIVE]::Text($script:updateStatusHandle)
  Assert-That ($statusText -like "*$Expected*") "$Name status result" $statusText
  $latest=[EBR_GUI_NATIVE]::Text($script:updateLatestHandle)
  Add-Result "$Name latest label" 'INFO' $latest
}
function Close-TestProcess {
  if (-not $script:testPid) { return }
  $process=Get-Process -Id $script:testPid -ErrorAction SilentlyContinue
  if (-not $process) { $script:testPid=0;return }
  $quit=[EBR_GUI_NATIVE]::RegisterWindowMessageW('EyeBreakReminder.Exit.Native.1')
  [void][EBR_GUI_NATIVE]::PostMessageW($script:mainWindow,$quit,[IntPtr]::Zero,[IntPtr]::Zero)
  if (-not $process.WaitForExit(8000)) { throw 'The isolated test app did not exit through its own Exit message.' }
  $script:testPid=0;$script:mainWindow=[IntPtr]::Zero
}

try {
  $running=@(Get-Process -Name 'EyeBreakReminder' -ErrorAction SilentlyContinue)
  foreach($item in $running){$runningPath='';try{$runningPath=[IO.Path]::GetFullPath($item.Path)}catch{};if($runningPath -ieq $exePath){throw "The isolated GUI-test executable is already running (PID $($item.Id)); refusing to reuse its test data."}}
  if([IO.Path]::GetFullPath($dataDirectory) -ine [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $exePath) 'test-data'))){throw 'The isolated test data path did not match the GUI test profile.'}
  foreach($profileFile in @('settings.ini','timer.dat','history.dat')){$profilePath=Join-Path $dataDirectory $profileFile;if(Test-Path -LiteralPath $profilePath -PathType Leaf){Remove-Item -LiteralPath $profilePath -Force}}
  $version=(Get-Item -LiteralPath $exePath).VersionInfo.ProductVersion
  Assert-That ($version -eq $expectedVersion) 'Test executable version metadata' $version
  $process=Start-Process -FilePath $exePath -PassThru
  $script:testPid=$process.Id
  if ([IO.Path]::GetFullPath((Get-Process -Id $script:testPid).Path) -ine $exePath) { throw 'Launched process path did not match the isolated GUI test executable.' }
  $script:mainWindow=Wait-MainWindow
  $uiNames=Get-UiaNames $script:mainWindow
  Assert-That ($uiNames -contains 'Timer' -and $uiNames -contains 'History' -and $uiNames -contains 'Settings') 'UI Automation exposes main navigation' ($uiNames -join ' | ')
  Switch-Settings 4
  Assert-That ((Get-Combo $script:mainWindow 106 'Theme') -eq 2) 'New installation defaults to Dark'
  Switch-Timer

  Switch-Settings 2
  Set-Check $script:mainWindow 32 $false 'Alarm enabled'
  Set-Intervals 2 30
  Switch-Timer
  Click-Control $script:mainWindow 21 'Reset timer'
  Assert-That ((Wait-Status 'Running') -like '*Running*') 'Timer reaches Running state'
  $runningBefore=Get-TimerSeconds
  Click-Control $script:mainWindow 20 'Pause work timer'
  Assert-That ((Wait-Status 'Paused') -like '*Paused*') 'Work pause status is clear'
  Assert-StatusAlignment 'paused work status'
  $pausedBefore=Get-TimerSeconds
  Start-Sleep -Milliseconds 700
  $pausedAfter=Get-TimerSeconds
  Assert-That ($pausedAfter -eq $pausedBefore) 'Paused timer remains fixed' ([pscustomobject]@{Before=$pausedBefore;After=$pausedAfter})
  Click-Control $script:mainWindow 20 'Resume work timer'
  Assert-That ((Wait-Status 'Running') -like '*Running*') 'Work timer resumes'
  Assert-That ((Get-TimerSeconds) -le $runningBefore) 'Resume continues from the saved countdown'
  Assert-StatusAlignment 'default window'
  Save-Screenshot $script:mainWindow 'timer-dynamic-schedule.png' | Out-Null

  $themeNames=@('follow-windows','light','dark','high-contrast-dark','high-contrast-light')
  foreach ($theme in 0..4) {
    Set-Theme $theme
    if ($theme -eq 0) {
      [void][EBR_GUI_NATIVE]::SendMessageW($script:mainWindow,0x031A,[IntPtr]::Zero,[IntPtr]::Zero)
      Start-Sleep -Milliseconds 150
      Assert-That ((Wait-Status 'Running') -like '*Running*') 'Follow Windows repaints on WM_THEMECHANGED'
    }
    Assert-StatusAlignment "$($themeNames[$theme]) work"
    Save-Screenshot $script:mainWindow ("timer-{0}-work.png" -f $themeNames[$theme]) | Out-Null
    Click-Control $script:mainWindow 11 'History navigation'
    Save-Screenshot $script:mainWindow ("history-{0}.png" -f $themeNames[$theme]) | Out-Null
    Switch-Settings 4
    Save-Screenshot $script:mainWindow ("settings-{0}.png" -f $themeNames[$theme]) | Out-Null
    if ($theme -eq 4) {
      $focusControl=Get-Control $script:mainWindow 124 'Distinct break accent checkbox'
      $targetPid=[uint32]0;$targetThread=[EBR_GUI_NATIVE]::GetWindowThreadProcessId($focusControl.Handle,[ref]$targetPid);$testThread=[EBR_GUI_NATIVE]::GetCurrentThreadId()
      if($targetPid -ne $script:testPid -or -not [EBR_GUI_NATIVE]::IsWindowEnabled($focusControl.Handle)){throw 'The high-contrast checkbox is not an enabled control in the test process.'}
      [void][EBR_GUI_NATIVE]::SetForegroundWindow($script:mainWindow)
      $attached=[EBR_GUI_NATIVE]::AttachThreadInput($testThread,$targetThread,$true)
      if(-not $attached){throw 'Could not attach keyboard input to the isolated app for focus verification.'}
      try {[void][EBR_GUI_NATIVE]::SetFocus($focusControl.Handle);$actualFocus=[EBR_GUI_NATIVE]::GetFocus()}
      finally {[void][EBR_GUI_NATIVE]::AttachThreadInput($testThread,$targetThread,$false)}
      Assert-That ($actualFocus -eq $focusControl.Handle) 'High-contrast checkbox receives keyboard focus' ([pscustomobject]@{FocusHandle=$actualFocus.ToInt64();ControlHandle=$focusControl.Handle.ToInt64()})
      [void][EBR_GUI_NATIVE]::SendMessageW($script:mainWindow,0x0127,[IntPtr]::new(0x00010002),[IntPtr]::Zero)
      [void][EBR_GUI_NATIVE]::InvalidateRect($focusControl.Handle,[IntPtr]::Zero,$true)
      [void][EBR_GUI_NATIVE]::UpdateWindow($focusControl.Handle)
      Start-Sleep -Milliseconds 100
      Save-Screenshot $script:mainWindow 'settings-high-contrast-visible-focus.png' | Out-Null
    }
    Switch-Timer
    Click-Control $script:mainWindow 22 'Take a break now'
    $breakWindow=Wait-BreakWindow
    Assert-That ((Wait-Status 'Taking an eye break') -like '*Taking an eye break*') "$($themeNames[$theme]) break state label"
    Assert-That ([EBR_GUI_NATIVE]::Text((Get-Control $script:mainWindow 42 'Break countdown caption').Handle) -eq 'Break time remaining') "$($themeNames[$theme]) break countdown has a distinct label"
    Assert-StatusAlignment "$($themeNames[$theme]) break"
    Save-Screenshot $script:mainWindow ("timer-{0}-break.png" -f $themeNames[$theme]) | Out-Null
    Save-Screenshot $breakWindow ("reminder-{0}.png" -f $themeNames[$theme]) | Out-Null
    $breakCount=[EBR_GUI_NATIVE]::Text((Get-Control $breakWindow 40 'Break countdown').Handle)
    Assert-That ($breakCount -match '^\d+:\d{2}$') "$($themeNames[$theme]) break duration visible" $breakCount
    Click-Control $breakWindow 24 'Skip eye break'
    Assert-That ((Wait-Status 'Running') -like '*Running*') "$($themeNames[$theme]) returns to work after skip"
  }

  Set-Intervals 1 300
  Switch-Timer
  Click-Control $script:mainWindow 21 'Reset accelerated timer'
  $acceleratedInitial=Get-TimerSeconds
  Assert-That ($acceleratedInitial -le 60) 'Accelerated test work interval resets to one minute' $acceleratedInitial
  Assert-That ((Wait-Status 'Taking an eye break' 10) -like '*Taking an eye break*') 'Accelerated work interval automatically starts a break'
  $breakWindow=Wait-BreakWindow 10
  $breakCount=[EBR_GUI_NATIVE]::Text((Get-Control $breakWindow 40 'Automatic break countdown').Handle)
  $parts=[regex]::Match($breakCount,'^(\d+):(\d{2})$');$breakRemaining=if($parts.Success){[int]$parts.Groups[1].Value*60+[int]$parts.Groups[2].Value}else{-1}
  Assert-That ($breakRemaining -le 300 -and $breakRemaining -ge 270) 'Automatic break countdown uses the configured five-minute duration' $breakCount
  Click-Control $breakWindow 25 'Snooze one minute'
  Assert-That ((Wait-Status 'Snoozed') -like '*Snoozed*') 'Snooze is visibly distinct from work and break'
  Assert-StatusAlignment 'snoozed status'
  Click-Control $script:mainWindow 20 'Pause snoozed timer'
  Assert-That ((Wait-Status 'Paused') -like '*Paused*') 'Pause state remains distinct'
  Assert-StatusAlignment 'paused snooze status'
  Click-Control $script:mainWindow 20 'Resume snoozed timer'
  $breakWindow=Wait-BreakWindow 10
  Assert-That ((Wait-Status 'Taking an eye break') -like '*Taking an eye break*') 'Snoozed reminder returns after its accelerated delay'
  Click-Control $breakWindow 24 'Skip snoozed break'

  Set-Intervals 180 300
  Switch-Timer
  Click-Control $script:mainWindow 21 'Reset long work interval'
  foreach ($size in @([pscustomobject]@{Width=680;Height=660},[pscustomobject]@{Width=1100;Height=820})) {
    $screenWidth=[EBR_GUI_NATIVE]::GetSystemMetrics(0);$screenHeight=[EBR_GUI_NATIVE]::GetSystemMetrics(1)
    $width=[Math]::Min($size.Width,$screenWidth-60);$height=[Math]::Min($size.Height,$screenHeight-60)
    [void][EBR_GUI_NATIVE]::SetWindowPos($script:mainWindow,[IntPtr]::Zero,20,20,$width,$height,0x0004 -bor 0x0010)
    Start-Sleep -Milliseconds 250
    Assert-StatusAlignment "$width x $height resize"
    Save-Screenshot $script:mainWindow ("timer-resize-{0}x{1}.png" -f $width,$height) | Out-Null
  }

  Set-Theme 2
  Click-Control $script:mainWindow 22 'Start natural break'
  $breakWindow=Wait-BreakWindow
  Save-Screenshot $breakWindow 'reminder-dark-natural.png' | Out-Null
  Start-Sleep -Seconds 31
  Assert-That ((Wait-Status 'Running') -like '*Running*') 'Natural break completion returns timer to work'
  Assert-That ((Find-BreakWindow) -eq [IntPtr]::Zero) 'Natural break closes its reminder window'
  Save-Screenshot $script:mainWindow 'timer-dark-work-after-break.png' | Out-Null

  $installedVersion=[Version]$expectedVersion
  $newerVersion='{0}.{1}.0' -f $installedVersion.Major,($installedVersion.Minor+1)
  if($installedVersion.Build -gt 0){$olderVersion='{0}.{1}.{2}' -f $installedVersion.Major,$installedVersion.Minor,($installedVersion.Build-1)}
  elseif($installedVersion.Minor -gt 0){$olderVersion='{0}.{1}.0' -f $installedVersion.Major,($installedVersion.Minor-1)}
  elseif($installedVersion.Major -gt 0){$olderVersion='{0}.0.0' -f ($installedVersion.Major-1)}
  else{throw 'Cannot construct a stable version older than 0.0.0 for the comparison fixture.'}
  function Release-Fixture([string]$Tag,[bool]$Prerelease=$false){return ([ordered]@{tag_name="v$Tag";html_url="https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/tag/v$Tag";draft=$false;prerelease=$Prerelease}|ConvertTo-Json -Compress)}
  $stable=Release-Fixture $expectedVersion
  $newer=Release-Fixture $newerVersion
  $older=Release-Fixture $olderVersion
  $prerelease=Release-Fixture "$newerVersion-rc.1" $true
  Run-UpdateFixture 'same-version' 200 $stable 'none' 'up to date' 3000
  Switch-Settings 5
  Assert-That (([EBR_GUI_NATIVE]::Text($script:updateLatestHandle)) -eq "Latest stable version: $expectedVersion") 'Same-version latest label'
  Run-UpdateFixture 'newer-version' 200 $newer 'none' 'update is available'
  Assert-That ((Get-Control $script:mainWindow 161 'Open official release').Enabled) 'Official release button enables for a newer version'
  Run-UpdateFixture 'older-version' 200 $older 'none' 'newer than the latest'
  Assert-That (-not (Get-Control $script:mainWindow 161 'Open official release').Enabled) 'Release link stays disabled when installed version is newer'
  Run-UpdateFixture 'prerelease' 200 $prerelease 'none' 'stable release'
  Run-UpdateFixture 'private-or-not-found' 404 '' 'none' 'Private repositories'
  Run-UpdateFixture 'rate-limit' 429 '' 'none' 'rate limit'
  Run-UpdateFixture 'offline' 0 '' 'offline' 'internet'
  Run-UpdateFixture 'timeout' 0 '' 'timeout' 'timed out'
  Run-UpdateFixture 'secure-connection' 0 '' 'tls' 'secure connection'
  Run-UpdateFixture 'invalid-json' 200 'not json' 'none' 'could not be read'

  Remove-Item -LiteralPath $fixturePath -Force -ErrorAction SilentlyContinue
  Switch-Settings 5
  Initialize-UpdateHandles
  Assert-That (([EBR_GUI_NATIVE]::Text($script:updateInstalledHandle)) -eq "Installed version: $version") 'About reads installed version metadata'
  Click-Control $script:mainWindow 160 'Live public update check'
  $watch=[Diagnostics.Stopwatch]::StartNew();$enabled=$false
  while ($watch.Elapsed.TotalSeconds -lt 20) { try { $enabled=(Get-Control $script:mainWindow 160 'Live public update check').Enabled } catch { };if($enabled){break};Start-Sleep -Milliseconds 150 }
  Assert-That $enabled 'Live official GitHub release request completes or reports an error'
  $liveStatus=[EBR_GUI_NATIVE]::Text($script:updateStatusHandle)
  Assert-That ($liveStatus -notlike '*Checking*') 'Live update result does not remain busy' $liveStatus
  Add-Result 'Public GitHub Releases API' 'INFO' ([pscustomobject]@{Latest=[EBR_GUI_NATIVE]::Text($script:updateLatestHandle);Status=$liveStatus})

  Set-Theme 4
  Switch-Settings 4
  Set-Check $script:mainWindow 124 $false 'Distinct break accent'
  Switch-Timer
  Click-Control $script:mainWindow 22 'High contrast break with optional accent disabled'
  $breakWindow=Wait-BreakWindow
  Save-Screenshot $script:mainWindow 'timer-high-contrast-break-accent-off.png' | Out-Null
  Save-Screenshot $breakWindow 'reminder-high-contrast-break-accent-off.png' | Out-Null
  Click-Control $breakWindow 24 'End high contrast visual check'
  Switch-Settings 4
  Set-Check $script:mainWindow 124 $true 'Distinct break accent'
  Switch-Timer
  Set-Theme 2
  Switch-Settings 4
  Set-Check $script:mainWindow 124 $false 'Distinct break accent'
  Switch-Timer
  Click-Control $script:mainWindow 22 'Dark break with optional accent disabled'
  $breakWindow=Wait-BreakWindow
  Save-Screenshot $script:mainWindow 'timer-dark-break-accent-off.png' | Out-Null
  Save-Screenshot $breakWindow 'reminder-dark-break-accent-off.png' | Out-Null
  Click-Control $breakWindow 24 'End dark accent preference check'
  Switch-Settings 4
  Set-Check $script:mainWindow 124 $true 'Distinct break accent'
  Switch-Timer
  Switch-Settings 5
  Set-Theme 4
  Switch-Settings 5
  Save-Screenshot $script:mainWindow 'about-update-checker.png' | Out-Null
  Remove-Item -LiteralPath $fixturePath -Force -ErrorAction SilentlyContinue
  Close-TestProcess
  $process=Start-Process -FilePath $exePath -PassThru
  $script:testPid=$process.Id;$script:mainWindow=Wait-MainWindow
  $script:updateStatusHandle=$script:updateLatestHandle=$script:updateInstalledHandle=[IntPtr]::Zero
  Switch-Settings 4
  Assert-That ((Get-Combo $script:mainWindow 106 'Theme') -eq 4) 'Selected theme persists across application restart'
  Save-Screenshot $script:mainWindow 'theme-persistence-high-contrast-light.png' | Out-Null
  Close-TestProcess
  Add-Result 'GUI acceptance suite' 'PASS' ([pscustomobject]@{Assertions=$script:assertionCount;EvidenceDirectory=$EvidenceDirectory;TestDataDirectory=$dataDirectory;Version=$version})
}
catch {
  Add-Result 'GUI acceptance suite' 'FAIL' $_.Exception.Message
  throw
}
finally {
  Remove-Item -LiteralPath $fixturePath -Force -ErrorAction SilentlyContinue
  try { Close-TestProcess } catch { Add-Result 'test-app cleanup' 'FAIL' $_.Exception.Message }
  $report=[pscustomobject]@{Version=$expectedVersion;Assertions=$script:assertionCount;Events=$script:events.ToArray();EvidenceDirectory=$EvidenceDirectory;TestDataDirectory=$dataDirectory}
  $report | ConvertTo-Json -Depth 9 | Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'gui-acceptance-results.json') -Encoding UTF8
  Write-Output "GUI acceptance: $($script:assertionCount) assertions; evidence: $EvidenceDirectory"
}
