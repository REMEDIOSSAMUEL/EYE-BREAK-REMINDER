param(
  [string]$Executable = (Join-Path $PSScriptRoot '..\build\gui-test\EyeBreakReminder.exe'),
  [string]$EvidenceDirectory = (Join-Path $PSScriptRoot '..\build\gui-test\evidence'),
  [switch]$TestSystemHighContrast
)
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$expectedVersion = (Get-Content -LiteralPath (Join-Path $repoRoot 'VERSION') -Raw).Trim()
if($expectedVersion -notmatch '^\d+\.\d+\.\d+$'){throw 'VERSION must contain a three-component release version.'}
$expectedExe = [IO.Path]::GetFullPath((Join-Path $repoRoot 'build\gui-test\EyeBreakReminder.exe'))
$temporaryExe = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) 'EyeBreakReminder-GuiAcceptance\EyeBreakReminder.exe'))
$exePath = [IO.Path]::GetFullPath($Executable)
if ($exePath -ine $expectedExe -and $exePath -ine $temporaryExe) { throw "Refusing to launch anything other than the isolated GUI test executable or its fixed temp copy: $expectedExe" }
if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) { throw "GUI test executable is missing: $exePath (run make gui-test first)." }
$expectedEvidence=[IO.Path]::GetFullPath((Join-Path $repoRoot 'build\gui-test\evidence'))
if ([IO.Path]::GetFullPath($EvidenceDirectory) -ine $expectedEvidence) { throw "Refusing to write screenshots outside the isolated test evidence folder: $expectedEvidence" }
$EvidenceDirectory=$expectedEvidence
$dataDirectory = Join-Path (Split-Path -Parent $exePath) 'test-data'
$fixturePath = Join-Path (Split-Path -Parent $exePath) 'test-update-response.txt'
$script:updateBarrierStartedName="Local\EyeBreakReminder.GuiTest.UpdateStarted.$PID"
$script:updateBarrierReleaseName="Local\EyeBreakReminder.GuiTest.UpdateRelease.$PID"
$script:oldUpdateBarrierStarted=[Environment]::GetEnvironmentVariable('EBR_GUI_TEST_UPDATE_STARTED','Process')
$script:oldUpdateBarrierRelease=[Environment]::GetEnvironmentVariable('EBR_GUI_TEST_UPDATE_RELEASE','Process')
$script:updateBarrierStartedCreated=$false
$script:updateBarrierReleaseCreated=$false
$script:updateBarrierStarted=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$script:updateBarrierStartedName,[ref]$script:updateBarrierStartedCreated)
$script:updateBarrierRelease=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$script:updateBarrierReleaseName,[ref]$script:updateBarrierReleaseCreated)
[Environment]::SetEnvironmentVariable('EBR_GUI_TEST_UPDATE_STARTED',$script:updateBarrierStartedName,'Process')
[Environment]::SetEnvironmentVariable('EBR_GUI_TEST_UPDATE_RELEASE',$script:updateBarrierReleaseName,'Process')
[void][IO.Directory]::CreateDirectory($EvidenceDirectory)
$script:testPid = 0
$script:mainWindow = [IntPtr]::Zero
$script:events = [System.Collections.Generic.List[object]]::new()
$script:assertionCount = 0
$script:updateStatusHandle = [IntPtr]::Zero
$script:updateLatestHandle = [IntPtr]::Zero
$script:updateInstalledHandle = [IntPtr]::Zero
$script:pickerResourceSamples = [System.Collections.Generic.List[object]]::new()
$script:breakResourceSamples = [System.Collections.Generic.List[object]]::new()

$native = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
[StructLayout(LayoutKind.Sequential)] public struct EBR_GUI_RECT { public int Left, Top, Right, Bottom; }
[StructLayout(LayoutKind.Sequential)] public struct EBR_GUI_POINT { public int X, Y; }
[StructLayout(LayoutKind.Sequential)] public struct EBR_GUI_HIGHCONTRAST { public uint cbSize, dwFlags; public IntPtr scheme; }
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
  [DllImport("user32.dll", SetLastError=true)] public static extern bool IsWindow(IntPtr hwnd);
  [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr GetDlgItem(IntPtr parent,int id);
  [DllImport("user32.dll", EntryPoint="GetWindowLongPtrW", SetLastError=true)] public static extern IntPtr GetWindowLongPtrW(IntPtr hwnd,int index);
  [DllImport("user32.dll", SetLastError=true)] public static extern int GetGuiResources(IntPtr process,uint flags);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool IsWindowEnabled(IntPtr hwnd);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool GetWindowRect(IntPtr hwnd, out EBR_GUI_RECT rect);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool GetClientRect(IntPtr hwnd, out EBR_GUI_RECT rect);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool ClientToScreen(IntPtr hwnd, ref EBR_GUI_POINT point);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern int GetWindowTextW(IntPtr hwnd, StringBuilder text, int maxCount);
  [DllImport("user32.dll", SetLastError=true)] private static extern int GetWindowTextLengthW(IntPtr hwnd);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern int GetClassNameW(IntPtr hwnd, StringBuilder name, int maxCount);
  [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr GetParent(IntPtr hwnd);
  [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr SendMessageW(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll", EntryPoint="SendMessageTimeoutW", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr SendMessageTimeoutTextW(IntPtr hwnd,uint message,IntPtr wParam,[Out] StringBuilder text,uint flags,uint timeout,out IntPtr result);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool InvalidateRect(IntPtr hwnd, IntPtr rect, bool erase);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool UpdateWindow(IntPtr hwnd);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern bool SetWindowTextW(IntPtr hwnd, string text);
  public static bool SetRemoteControlText(IntPtr hwnd, string value) {
    IntPtr text=Marshal.StringToHGlobalUni(value);
    try { return SendMessageW(hwnd,0x000C,IntPtr.Zero,text)!=IntPtr.Zero; }
    finally { Marshal.FreeHGlobal(text); }
  }
  [DllImport("user32.dll", SetLastError=true)] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr insertAfter, int x, int y, int width, int height, uint flags);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool SetCursorPos(int x,int y);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool SetForegroundWindow(IntPtr hwnd);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
  [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll", SetLastError=true)] public static extern uint GetDpiForWindow(IntPtr hwnd);
  [DllImport("user32.dll", SetLastError=true)] public static extern int GetSystemMetrics(int index);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern uint RegisterWindowMessageW(string name);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool PostMessageW(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll", SetLastError=true)] private static extern bool SystemParametersInfoW(uint action,uint parameter,ref EBR_GUI_HIGHCONTRAST value,uint flags);
  [DllImport("user32.dll", EntryPoint="SystemParametersInfoW", SetLastError=true)] private static extern bool SystemParametersInfoGetAnimationW(uint action,uint parameter,ref int value,uint flags);
  [DllImport("user32.dll", EntryPoint="SystemParametersInfoW", SetLastError=true)] private static extern bool SystemParametersInfoSetAnimationW(uint action,uint parameter,IntPtr value,uint flags);
  [DllImport("user32.dll", SetLastError=true)] public static extern uint GetSysColor(int index);
  public static bool GetHighContrast(out uint flags){EBR_GUI_HIGHCONTRAST value=new EBR_GUI_HIGHCONTRAST();value.cbSize=(uint)Marshal.SizeOf(typeof(EBR_GUI_HIGHCONTRAST));bool ok=SystemParametersInfoW(0x0042,value.cbSize,ref value,0);flags=value.dwFlags;return ok;}
  public static bool SetHighContrast(uint flags){EBR_GUI_HIGHCONTRAST value=new EBR_GUI_HIGHCONTRAST();value.cbSize=(uint)Marshal.SizeOf(typeof(EBR_GUI_HIGHCONTRAST));value.dwFlags=flags;return SystemParametersInfoW(0x0043,value.cbSize,ref value,2);}
  public static bool GetClientAreaAnimation(out bool enabled){int value=0;bool ok=SystemParametersInfoGetAnimationW(0x1042,0,ref value,0);enabled=value!=0;return ok;}
  // SPI_SETCLIENTAREAANIMATION encodes BOOL in pvParam itself; it is not a BOOL* like SPI_GETCLIENTAREAANIMATION.
  public static bool SetClientAreaAnimation(bool enabled){IntPtr value=enabled?new IntPtr(1):IntPtr.Zero;return SystemParametersInfoSetAnimationW(0x1043,0,value,2);}
  [DllImport("user32.dll")] public static extern void keybd_event(byte virtualKey,byte scanCode,uint flags,UIntPtr extraInfo);
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
  $handle=[EBR_GUI_NATIVE]::GetDlgItem($Root,$Id)
  if($handle-eq[IntPtr]::Zero){$watch=[Diagnostics.Stopwatch]::StartNew();$matches=@();while($watch.Elapsed.TotalSeconds-lt2){$matches=@([EBR_GUI_NATIVE]::Children($Root)|Where-Object{[EBR_GUI_NATIVE]::GetDlgCtrlID($_)-eq$Id-and[EBR_GUI_NATIVE]::IsWindowVisible($_)});if($matches.Count-eq1){break};Start-Sleep -Milliseconds 50};if($matches.Count-ne1){$rootInfo=if([EBR_GUI_NATIVE]::IsWindow($Root)){'Class='+[EBR_GUI_NATIVE]::ClassName($Root)+' Text='+[EBR_GUI_NATIVE]::Text($Root)+' Visible='+[EBR_GUI_NATIVE]::IsWindowVisible($Root)}else{'destroyed'};$descendants=@([EBR_GUI_NATIVE]::Children($Root)|ForEach-Object{$pidValue=[uint32]0;[void][EBR_GUI_NATIVE]::GetWindowThreadProcessId($_,[ref]$pidValue);'ID='+[EBR_GUI_NATIVE]::GetDlgCtrlID($_)+' Class='+[EBR_GUI_NATIVE]::ClassName($_)+' Visible='+[EBR_GUI_NATIVE]::IsWindowVisible($_)+' PID='+$pidValue+' Text='+[EBR_GUI_NATIVE]::Text($_)});throw "Expected one visible $Name control ID $Id after 2 seconds, found $($matches.Count). Root=$rootInfo. Descendants=$($descendants -join '; ')."};$handle=$matches[0]}
  if(-not[EBR_GUI_NATIVE]::IsWindow($handle)-or-not[EBR_GUI_NATIVE]::IsWindowVisible($handle)){throw "$Name control ID $Id disappeared before click."}
  $processId=[uint32]0;[void][EBR_GUI_NATIVE]::GetWindowThreadProcessId($handle,[ref]$processId)
  if($processId-ne$script:testPid){throw "$Name control ID $Id belongs to process $processId, expected $($script:testPid)."}
  if(-not[EBR_GUI_NATIVE]::IsWindowEnabled($handle)){throw "$Name is disabled."}
  [void][EBR_GUI_NATIVE]::SendMessageW($handle,0x00F5,[IntPtr]::Zero,[IntPtr]::Zero)
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
function Get-AppFocusedControl([IntPtr]$Root) {
  $rootPid=[uint32]0;$targetThread=[EBR_GUI_NATIVE]::GetWindowThreadProcessId($Root,[ref]$rootPid);$testThread=[EBR_GUI_NATIVE]::GetCurrentThreadId()
  if($rootPid -ne $script:testPid){throw 'Refusing to inspect keyboard focus outside the isolated test app.'}
  $attached=[EBR_GUI_NATIVE]::AttachThreadInput($testThread,$targetThread,$true)
  if(-not $attached){throw 'Could not attach keyboard input to inspect focus in the isolated test app.'}
  try {$actual=[EBR_GUI_NATIVE]::GetFocus()}
  finally {[void][EBR_GUI_NATIVE]::AttachThreadInput($testThread,$targetThread,$false)}
  return $actual
}
function Set-Edit([IntPtr]$Root,[int]$Id,[string]$Value,[string]$Name) {
  $control = Get-Control $Root $Id $Name
  if ($control.Class -ne 'Edit' -or -not $control.Enabled) { throw "$Name is not an enabled Edit control." }
  if(-not [EBR_GUI_NATIVE]::SetRemoteControlText($control.Handle,$Value)){throw "WM_SETTEXT failed for $Name."}
  $encodedCommand=($Id -bor (0x0200 -shl 16))
  [void][EBR_GUI_NATIVE]::SendMessageW([EBR_GUI_NATIVE]::GetParent($control.Handle),0x0111,[IntPtr]$encodedCommand,$control.Handle)
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
function Find-ColorPicker {
  $matches=@([EBR_GUI_NATIVE]::TopWindowsForProcess($script:testPid) | Where-Object { [EBR_GUI_NATIVE]::IsWindowVisible($_) -and [EBR_GUI_NATIVE]::ClassName($_) -eq '#32770' })
  if($matches.Count -gt 1){throw 'More than one common dialog belongs to the isolated application.'}
  if($matches.Count -eq 1){return $matches[0]}
  return [IntPtr]::Zero
}
function Wait-ColorPicker([int]$TimeoutSeconds=5) {
  $watch=[Diagnostics.Stopwatch]::StartNew()
  while($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds){$dialog=Find-ColorPicker;if($dialog -ne [IntPtr]::Zero){return $dialog};Start-Sleep -Milliseconds 50}
  throw 'The native ChooseColorW dialog did not open.'
}
function Open-ColorPicker([int]$ButtonId,[string]$Name) {
  $control=Get-Control $script:mainWindow $ButtonId $Name
  if(-not $control.Enabled){throw "$Name is disabled."}
  $style=[EBR_GUI_NATIVE]::GetWindowLongPtrW($control.Handle,-16).ToInt64()
  Assert-That (($style -band 0x00010000) -ne 0) "$Name has the Win32 WS_TABSTOP keyboard style" ([pscustomobject]@{Style=('0x{0:X}' -f $style)})
  Set-AppFocus $control.Handle
  [void][EBR_GUI_NATIVE]::PostMessageW($control.Handle,0x0100,[IntPtr]0x20,[IntPtr]::Zero)
  [void][EBR_GUI_NATIVE]::PostMessageW($control.Handle,0x0101,[IntPtr]0x20,[IntPtr]::Zero)
  Wait-ColorPicker
}
function Set-NativePickerRgb([IntPtr]$Dialog,[int]$Red,[int]$Green,[int]$Blue) {
  foreach($item in @(@{Id=706;Value=$Red;Name='Red'},@{Id=707;Value=$Green;Name='Green'},@{Id=708;Value=$Blue;Name='Blue'})){
    $field=[EBR_GUI_NATIVE]::GetDlgItem($Dialog,$item.Id)
    if($field -eq [IntPtr]::Zero -or [EBR_GUI_NATIVE]::ClassName($field) -ne 'Edit'){throw "ChooseColorW did not expose its native $($item.Name) RGB edit control (ID $($item.Id))."}
    [void][EBR_GUI_NATIVE]::SendMessageW($field,0x00B1,[IntPtr]::Zero,[IntPtr](-1))
    [void][EBR_GUI_NATIVE]::SendMessageW($field,0x0102,[IntPtr]0x08,[IntPtr]::Zero)
    foreach($digit in ([string]$item.Value).ToCharArray()){[void][EBR_GUI_NATIVE]::SendMessageW($field,0x0102,[IntPtr][int][char]$digit,[IntPtr]::Zero)}
    $notification=($item.Id -bor (0x0300 -shl 16))
    [void][EBR_GUI_NATIVE]::SendMessageW([EBR_GUI_NATIVE]::GetParent($field),0x0111,[IntPtr]$notification,$field)
    if(([EBR_GUI_NATIVE]::Text($field)).Trim() -ne [string]$item.Value){throw "The native $($item.Name) field did not retain its value."}
  }
}
function Get-NativePickerRgb([IntPtr]$Dialog) {
  $values=@();foreach($id in @(706,707,708)){$value=0;if(-not [int]::TryParse(([EBR_GUI_NATIVE]::Text([EBR_GUI_NATIVE]::GetDlgItem($Dialog,$id))).Trim(),[ref]$value)){throw "Native RGB field $id was not numeric."};$values+=,$value};return ,$values
}
function Get-SystemColorHex([int]$Index) {
  $color=[EBR_GUI_NATIVE]::GetSysColor($Index);$red=[int]($color -band 0xff);$green=[int](($color -shr 8) -band 0xff);$blue=[int](($color -shr 16) -band 0xff)
  return ('#{0:X2}{1:X2}{2:X2}' -f $red,$green,$blue)
}
function Get-ContrastRatio([string]$First,[string]$Second) {
  $luminance={param([string]$Hex)$rgb=@(0,2,4|ForEach-Object{[Convert]::ToInt32($Hex.Substring(1+$_,2),16)/255.0});$linear=@($rgb|ForEach-Object{if($_ -le 0.04045){$_/12.92}else{[Math]::Pow(($_+0.055)/1.055,2.4)}});return 0.2126*$linear[0]+0.7152*$linear[1]+0.0722*$linear[2]}
  $a=&$luminance $First;$b=&$luminance $Second;return ([Math]::Max($a,$b)+0.05)/([Math]::Min($a,$b)+0.05)
}
function Test-SystemHighContrast {
  if(-not $TestSystemHighContrast){Add-Result 'Actual Windows High Contrast / Forced Colors test' 'NOT TESTED' 'This test is gated to disposable hosted Windows runners; no personal Windows accessibility settings were changed.';return}
  $original=[uint32]0
  if(-not [EBR_GUI_NATIVE]::GetHighContrast([ref]$original)){Add-Result 'Actual Windows High Contrast / Forced Colors test' 'NOT TESTED' 'SPI_GETHIGHCONTRAST was unavailable.';return}
  $highContrastWasEnabled=($original -band 1) -ne 0
  try {
    if(-not $highContrastWasEnabled -and -not [EBR_GUI_NATIVE]::SetHighContrast($original -bor 1)){Add-Result 'Actual Windows High Contrast / Forced Colors test' 'NOT TESTED' 'SPI_SETHIGHCONTRAST was unavailable or rejected by this runner.';return}
    Start-Sleep -Seconds 2
    $observed=[uint32]0
    if(-not [EBR_GUI_NATIVE]::GetHighContrast([ref]$observed) -or ($observed -band 1) -eq 0){Add-Result 'Actual Windows High Contrast / Forced Colors test' 'NOT TESTED' 'Windows did not report the requested system High Contrast state.';return}
    $window=Get-SystemColorHex 5;$windowText=Get-SystemColorHex 8;$buttonFace=Get-SystemColorHex 15;$highlight=Get-SystemColorHex 13;$highlightText=Get-SystemColorHex 14
    $windowContrast=Get-ContrastRatio $windowText $window;$buttonContrast=Get-ContrastRatio $highlightText $highlight;$focusContrast=Get-ContrastRatio $highlight $buttonFace
    Assert-That ($windowContrast -ge 4.5 -and $buttonContrast -ge 4.5 -and $focusContrast -ge 3.0) 'Actual Windows Forced Colors text, primary-button and focus colours meet contrast thresholds' ([pscustomobject]@{WindowText=$windowText;WindowBackground=$window;WindowTextRatio=[Math]::Round($windowContrast,2);ButtonText=$highlightText;ButtonBackground=$highlight;ButtonTextRatio=[Math]::Round($buttonContrast,2);Focus=$highlight;ButtonFace=$buttonFace;FocusRatio=[Math]::Round($focusContrast,2)})
    $names=@('follow-windows','light','dark','high-contrast-dark','high-contrast-light')
    $storedWork=Get-SettingLine 'workAccentColor';$storedBreak=Get-SettingLine 'breakAccentColor';$customWork=Get-SettingLine 'customWorkAccent';$customBreak=Get-SettingLine 'customBreakAccent'
    for($theme=0;$theme -le 4;$theme++){
      Set-Theme $theme
      Assert-That ((Get-SettingLine 'workAccentColor') -eq $storedWork -and (Get-SettingLine 'breakAccentColor') -eq $storedBreak -and (Get-SettingLine 'customWorkAccent') -eq $customWork -and (Get-SettingLine 'customBreakAccent') -eq $customBreak) "Windows Forced Colors preserves saved custom colours under $($names[$theme])" ([pscustomobject]@{Work=$storedWork;Break=$storedBreak;WorkOverride=$customWork;BreakOverride=$customBreak})
      Click-Control $script:mainWindow 21 "Reset Work timer under system Forced Colors $($names[$theme])";Wait-RingProgress "Windows Forced Colors $($names[$theme]) Work"
      $workShot=Save-Screenshot $script:mainWindow "system-forced-colors-$($names[$theme])-work.png"
      Assert-TimerRingPixel $workShot $highlight "Windows Forced Colors $($names[$theme]) Work Mode ring"
      Click-Control $script:mainWindow 22 "Start Break under system Forced Colors $($names[$theme])"
      $breakWindow=Wait-BreakWindow
      Assert-That ((Wait-Status 'Taking an eye break') -like '*Taking an eye break*') "Windows Forced Colors $($names[$theme]) retains the named Break status"
      Assert-That ([EBR_GUI_NATIVE]::Text((Get-Control $script:mainWindow 42 'Break countdown caption').Handle) -eq 'Break time remaining') "Windows Forced Colors $($names[$theme]) retains a distinct Break countdown caption"
      Save-Screenshot $breakWindow "system-forced-colors-$($names[$theme])-reminder.png" | Out-Null
      Wait-RingProgress "Windows Forced Colors $($names[$theme]) Break"
      $breakShot=Save-Screenshot $script:mainWindow "system-forced-colors-$($names[$theme])-break.png" -PreserveForeground
      $hotlight=Get-SystemColorHex 26
      Assert-TimerRingPixel $breakShot $hotlight "Windows Forced Colors $($names[$theme]) Break Mode ring"
      Click-Control $breakWindow 24 "Complete Break under system Forced Colors $($names[$theme])"
      Assert-That ((Wait-Status 'Running') -like '*Running*') "Windows Forced Colors $($names[$theme]) returns to Work Mode after Break"
      Wait-RingProgress "Windows Forced Colors $($names[$theme]) Work after Break"
      $returnShot=Save-Screenshot $script:mainWindow "system-forced-colors-$($names[$theme])-work-after-break.png"
      Assert-TimerRingPixel $returnShot $highlight "Windows Forced Colors $($names[$theme]) restores Work Mode ring after Break"
    }
    Switch-Settings 4
    $focusControl=Get-Control $script:mainWindow 127 'Work accent picker focus target under system Forced Colors'
    Set-AppFocus $focusControl.Handle
    Assert-That ([EBR_GUI_NATIVE]::IsWindowEnabled($focusControl.Handle)) 'Work colour picker remains keyboard-accessible under actual Windows Forced Colors'
    Save-Screenshot $script:mainWindow 'system-forced-colors-visible-keyboard-focus.png' | Out-Null
    [void][EBR_GUI_NATIVE]::SetHighContrast($original -band 0xfffffffe);Start-Sleep -Seconds 2
    $disabledFlags=[uint32]0
    Assert-That ([EBR_GUI_NATIVE]::GetHighContrast([ref]$disabledFlags) -and ($disabledFlags -band 1) -eq 0) 'Windows reports Forced Colors disabled before testing saved custom accents'
    [void][EBR_GUI_NATIVE]::SendMessageW($script:mainWindow,0x001A,[IntPtr]::Zero,[IntPtr]::Zero)
    Set-Theme 2
    Assert-That ((Get-SettingLine 'workAccentColor') -eq $storedWork -and (Get-SettingLine 'breakAccentColor') -eq $storedBreak) 'Turning Windows High Contrast off restores saved custom colour preferences'
    Switch-Timer;Click-Control $script:mainWindow 21 'Restore normal Work ring after system Forced Colors test';Wait-RingProgress 'Disabling Windows Forced Colors restored Work'
    Assert-TimerRingPixel (Save-Screenshot $script:mainWindow 'system-forced-colors-disabled-restored-custom-work.png') '#22C55E' 'Disabling Windows Forced Colors restores custom Work Mode accent'
    Click-Control $script:mainWindow 22 'Verify restored Break accent after system Forced Colors';$breakWindow=Wait-BreakWindow
    Save-Screenshot $breakWindow 'system-forced-colors-disabled-restored-custom-break-reminder.png' | Out-Null
    Wait-RingProgress 'Disabling Windows Forced Colors restored Break'
    Assert-TimerRingPixel (Save-Screenshot $script:mainWindow 'system-forced-colors-disabled-restored-custom-break.png' -PreserveForeground) '#EF4444' 'Disabling Windows Forced Colors restores custom Break Mode accent'
    Click-Control $breakWindow 24 'Finish restored Break accent check'
    Assert-That ((Wait-Status 'Running') -like '*Running*') 'Normal Work mode returns after system Forced Colors is disabled'
  } finally {
    [void][EBR_GUI_NATIVE]::SetHighContrast($original);Start-Sleep -Seconds 2
    [void][EBR_GUI_NATIVE]::SendMessageW($script:mainWindow,0x001A,[IntPtr]::Zero,[IntPtr]::Zero)
    [void][EBR_GUI_NATIVE]::SendMessageW($script:mainWindow,0x031A,[IntPtr]::Zero,[IntPtr]::Zero)
  }
}
function Test-ReducedMotionIntegration {
  $original=$false
  if(-not [EBR_GUI_NATIVE]::GetClientAreaAnimation([ref]$original)){Add-Result 'Actual Windows reduced-motion preference' 'NOT TESTED' 'SPI_GETCLIENTAREAANIMATION was unavailable on this runner.';return}
  $changed=$false
  try{
    Switch-Settings 4;Start-Sleep -Milliseconds 650
    $panes=@([EBR_GUI_NATIVE]::Children($script:mainWindow)|Where-Object{[EBR_GUI_NATIVE]::ClassName($_)-eq'EyeBreakReminder.Settings'})
    if($panes.Count-ne 1){Add-Result 'Actual Windows reduced-motion response' 'NOT TESTED' "Expected one live settings scroll pane, found $($panes.Count).";return}
    $pane=$panes[0];$target=[EBR_GUI_NATIVE]::GetDlgItem($pane,127)
    if($target-eq[IntPtr]::Zero){Add-Result 'Actual Windows reduced-motion response' 'NOT TESTED' 'The appearance scroll target was not present in the settings pane.';return}
    if(-not [EBR_GUI_NATIVE]::SetClientAreaAnimation($false)){Add-Result 'Actual Windows reduced-motion preference' 'NOT TESTED' 'SPI_SETCLIENTAREAANIMATION(FALSE) was unavailable or rejected by the isolated runner.';return}
    $changed=$true;$observed=$true
    if(-not [EBR_GUI_NATIVE]::GetClientAreaAnimation([ref]$observed)-or$observed){Add-Result 'Actual Windows reduced-motion preference' 'NOT TESTED' 'The isolated runner did not expose the requested disabled client-area animation state.';return}
    [void][EBR_GUI_NATIVE]::SendMessageW($pane,0x0115,[IntPtr]6,[IntPtr]::Zero);Start-Sleep -Milliseconds 350
    $topDisabled=(Get-Rect $target).Top
    [void][EBR_GUI_NATIVE]::SendMessageW($pane,0x0115,[IntPtr]7,[IntPtr]::Zero)
    $disabledImmediate=(Get-Rect $target).Top;Start-Sleep -Milliseconds 80;$disabledSettled=(Get-Rect $target).Top
    Save-Screenshot $script:mainWindow 'reduced-motion-disabled-scroll.png' | Out-Null
    Assert-That ([Math]::Abs($disabledImmediate-$disabledSettled)-le 2-and[Math]::Abs($disabledSettled-$topDisabled)-gt 40) 'Windows reduced-motion setting makes settings scrolling jump immediately' ([pscustomobject]@{SPI_GETCLIENTAREAANIMATION=$observed;TopY=$topDisabled;ImmediateY=$disabledImmediate;SettledY=$disabledSettled})

    if(-not [EBR_GUI_NATIVE]::SetClientAreaAnimation($true)){Add-Result 'Actual Windows reduced-motion preference' 'NOT TESTED' 'SPI_SETCLIENTAREAANIMATION(TRUE) was unavailable before the animation comparison.';return}
    $observed=$false
    if(-not [EBR_GUI_NATIVE]::GetClientAreaAnimation([ref]$observed)-or-not$observed){Add-Result 'Actual Windows reduced-motion preference' 'NOT TESTED' 'The isolated runner did not expose the requested enabled client-area animation state.';return}
    [void][EBR_GUI_NATIVE]::SendMessageW($pane,0x0115,[IntPtr]6,[IntPtr]::Zero);Start-Sleep -Milliseconds 700
    $topEnabled=(Get-Rect $target).Top
    [void][EBR_GUI_NATIVE]::SendMessageW($pane,0x0115,[IntPtr]7,[IntPtr]::Zero)
    $enabledImmediate=(Get-Rect $target).Top;Start-Sleep -Milliseconds 80;$enabledIntermediate=(Get-Rect $target).Top
    Save-Screenshot $script:mainWindow 'reduced-motion-enabled-scroll.png' | Out-Null
    Start-Sleep -Milliseconds 650;$enabledSettled=(Get-Rect $target).Top
    Assert-That ([Math]::Abs($enabledImmediate-$enabledSettled)-gt 25-and[Math]::Abs($enabledSettled-$disabledSettled)-le 3) 'Windows client-area animation setting controls the app scroll transition' ([pscustomobject]@{SPI_GETCLIENTAREAANIMATION=$observed;TopY=$topEnabled;ImmediateY=$enabledImmediate;IntermediateY=$enabledIntermediate;SettledY=$enabledSettled;ReducedMotionSettledY=$disabledSettled})
  }finally{
    if($changed){
      [void][EBR_GUI_NATIVE]::SetClientAreaAnimation($original)
      $restored=$false;$restoreOk=[EBR_GUI_NATIVE]::GetClientAreaAnimation([ref]$restored)
      if(-not$restoreOk-or$restored-ne$original){Add-Result 'Restore original Windows reduced-motion preference' 'FAIL' ([pscustomobject]@{Expected=$original;Actual=$restored;QuerySucceeded=$restoreOk})}
      else{Add-Result 'Restore original Windows reduced-motion preference' 'PASS' ([pscustomobject]@{Value=$restored})}
    }
    if($script:mainWindow-ne[IntPtr]::Zero){[void][EBR_GUI_NATIVE]::SendMessageW($script:mainWindow,0x001A,[IntPtr]::Zero,[IntPtr]::Zero)}
  }
}
function Close-NativePicker([IntPtr]$Dialog,[bool]$Accept) {
  $id=if($Accept){1}else{2};$button=[EBR_GUI_NATIVE]::GetDlgItem($Dialog,$id)
  if($button -eq [IntPtr]::Zero){throw "ChooseColorW is missing its native $(if($Accept){'OK'}else{'Cancel'}) button."}
  [void][EBR_GUI_NATIVE]::SendMessageW($button,0x00F5,[IntPtr]::Zero,[IntPtr]::Zero)
  $watch=[Diagnostics.Stopwatch]::StartNew()
  while($watch.Elapsed.TotalSeconds -lt 5 -and [EBR_GUI_NATIVE]::IsWindow($Dialog)){Start-Sleep -Milliseconds 25}
  if([EBR_GUI_NATIVE]::IsWindow($Dialog)){throw 'The native color dialog did not close after its button was activated.'}
}
function Get-PickerResourceSample([int]$Cycle) {
  $process=[Diagnostics.Process]::GetProcessById($script:testPid)
  try{$process.Refresh();[pscustomobject]@{Cycle=$Cycle;UserObjects=[EBR_GUI_NATIVE]::GetGuiResources($process.Handle,1);GdiObjects=[EBR_GUI_NATIVE]::GetGuiResources($process.Handle,0);HandleCount=$process.HandleCount;PrivateBytes=$process.PrivateMemorySize64;WorkingSetBytes=$process.WorkingSet64}}
  finally{$process.Dispose()}
}
function Get-PickerResourceTrend([string]$Name,[string]$Property,$Samples=$script:pickerResourceSamples) {
  $values=[double[]]@($Samples|ForEach-Object{[double]$_.$Property});$first=[double[]]@($values|Select-Object -First 5|Sort-Object);$last=[double[]]@($values|Select-Object -Last 5|Sort-Object)
  $n=$values.Count;$meanX=($n+1)/2.0;$meanY=($values|Measure-Object -Average).Average;$numerator=0.0;$denominator=0.0
  for($i=0;$i -lt $n;$i++){$x=$i+1;$numerator+=($x-$meanX)*($values[$i]-$meanY);$denominator+=[Math]::Pow($x-$meanX,2)}
  [pscustomobject]@{Resource=$Name;StartMedian=$first[2];EndMedian=$last[2];SlopePerInteraction=[Math]::Round($numerator/[Math]::Max(1.0,$denominator),5);Samples=$n;Minimum=($values|Measure-Object -Minimum).Minimum;Maximum=($values|Measure-Object -Maximum).Maximum}
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
  $script:updateStatusHandle=Get-StaticHandle 'Check for Updates queries the official public GitHub Releases API.' 'Initial update status'
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
function Wait-RingProgress([string]$Name) {
  $start=Get-TimerSeconds;$watch=[Diagnostics.Stopwatch]::StartNew()
  while($watch.Elapsed.TotalSeconds-lt5-and(Get-TimerSeconds)-ge$start){Start-Sleep -Milliseconds 100}
  Assert-That ((Get-TimerSeconds)-lt$start) "$Name countdown advances before rendered ring sampling"
  Start-Sleep -Milliseconds 4500
}
function Get-UiaNames([IntPtr]$Window) {
  $root=[System.Windows.Automation.AutomationElement]::FromHandle($Window)
  if ($root.Current.ProcessId -ne $script:testPid) { throw 'The UI Automation root belongs to a different process.' }
  $items=$root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
  @($items | Where-Object { $_.Current.ProcessId -eq $script:testPid } | ForEach-Object { try { $_.Current.Name } catch { '' } } | Where-Object { $_ })
}
function Get-UiaElementDiagnostics($Root,[string]$Name) {
  $rows=[Collections.Generic.List[object]]::new()
  $patterns=@(
    [pscustomobject]@{Name='Invoke';Pattern=[System.Windows.Automation.InvokePattern]::Pattern},
    [pscustomobject]@{Name='SelectionItem';Pattern=[System.Windows.Automation.SelectionItemPattern]::Pattern},
    [pscustomobject]@{Name='Toggle';Pattern=[System.Windows.Automation.TogglePattern]::Pattern}
  )
  foreach($element in $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)){
    try{
      $current=$element.Current
      if($current.Name-cne$Name){continue}
      $available=[Collections.Generic.List[string]]::new()
      foreach($check in $patterns){$value=$null;try{if($element.TryGetCurrentPattern($check.Pattern,[ref]$value)){$available.Add($check.Name)}}catch{}}
      $supported=@();try{$supported=@($element.GetSupportedPatterns()|ForEach-Object{$_.ProgrammaticName})}catch{}
      $rows.Add([pscustomobject]@{Name=$current.Name;ControlType=$current.ControlType.ProgrammaticName;ClassName=$current.ClassName;AutomationId=$current.AutomationId;ProcessId=$current.ProcessId;NativeWindowHandle=$current.NativeWindowHandle;Enabled=$current.IsEnabled;KeyboardFocusable=$current.IsKeyboardFocusable;HasKeyboardFocus=$current.HasKeyboardFocus;Patterns=@($available);SupportedPatterns=$supported})
    }catch{}
  }
  return ,@($rows)
}
function Find-UiaDialog([string]$Marker,[int]$TimeoutSeconds=15) {
  $watch=[Diagnostics.Stopwatch]::StartNew()
  while($watch.Elapsed.TotalSeconds-lt$TimeoutSeconds){
    foreach($window in [EBR_GUI_NATIVE]::TopWindowsForProcess($script:testPid)){
      if(-not[EBR_GUI_NATIVE]::IsWindowVisible($window)){continue}
      try{$windowTitle=[EBR_GUI_NATIVE]::Text($window);if($Marker-eq'Eye Break Reminder Update Available'-and$windowTitle-cne'Eye Break Reminder Update'){continue};$root=[System.Windows.Automation.AutomationElement]::FromHandle($window);$rootName=$root.Current.Name;$names=@($rootName)+@(Get-UiaNames $window);if(($names -join "`n").Contains($Marker)){return [pscustomobject]@{Handle=$window;Root=$root;Names=$names;WindowTitle=$windowTitle}}}catch{}
    }
    Start-Sleep -Milliseconds 100
  }
  throw "Timed out waiting for UI Automation dialog text '$Marker'."
}
function Invoke-UiaButton($Dialog,[string]$Name) {
  $items=$Dialog.Root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
  foreach($element in $items){
    try{if($element.Current.ProcessId-ne$script:testPid-or$element.Current.Name-cne$Name-or$element.Current.ControlType-ne[System.Windows.Automation.ControlType]::Button){continue};$pattern=$null;if($element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern,[ref]$pattern)){$pattern.Invoke();return}}catch{}
  }
  $diagnostics=ConvertTo-Json -InputObject (Get-UiaElementDiagnostics $Dialog.Root $Name) -Depth 5 -Compress
  throw "Accessible dialog button '$Name' could not be invoked. Matching UI Automation elements: $diagnostics. Dialog names: $($Dialog.Names -join ' | ')"
}
function Save-Screenshot([IntPtr]$Window,[string]$Name,[switch]$PreserveForeground) {
  if (-not [EBR_GUI_NATIVE]::IsWindowVisible($Window)) { throw "Screenshot window is not visible: $Name" }
  if(-not $PreserveForeground){[void][EBR_GUI_NATIVE]::SetForegroundWindow($Window);Start-Sleep -Milliseconds 180}
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
function Assert-TimerRingPixel([string]$ScreenshotPath,[string]$Hex,[string]$Name) {
  $expected=[Drawing.ColorTranslator]::FromHtml($Hex);$bounds=Get-Rect $script:mainWindow;$client=Get-ClientGeometry $script:mainWindow
  $dpi=[EBR_GUI_NATIVE]::GetDpiForWindow($script:mainWindow);$scale=100
  try{$scale=[int](Get-ItemPropertyValue -LiteralPath 'HKCU:\Software\Microsoft\Accessibility' -Name TextScaleFactor -ErrorAction Stop)}catch{}
  $textScale=[Math]::Min(2.25,[Math]::Max(1.0,$scale/100.0));$px={param([double]$v)[int][Math]::Floor($v*$dpi/96.0+0.5)}
  $button=Get-Control $script:mainWindow 22 'Ring geometry reference button';$buttonTop=$button.Rect.Top-$client.Top
  $navBottom=(& $px 16)+(& $px ([Math]::Max(40.0,31.0*$textScale)));$timerTop=$navBottom+(& $px 22);$statusBottom=$timerTop+(& $px 88)
  $diameter=[Math]::Min((& $px 272),[Math]::Min($client.Width-(& $px 100),$buttonTop-$statusBottom-(& $px 18)));$diameter=[Math]::Max(1,$diameter)
  $ringDiameter=$diameter-(& $px 8);$ringX=[int][Math]::Floor(($client.Width-$diameter)/2.0)+(& $px 4);$ringY=$statusBottom+(& $px 8)+(& $px 4)
  $centerX=($client.Left-$bounds.Left)+$ringX+$ringDiameter/2.0;$centerY=($client.Top-$bounds.Top)+$ringY+$ringDiameter/2.0;$radius=$ringDiameter/2.0
  $bitmap=[Drawing.Bitmap]::new($ScreenshotPath);$matches=0
  try{
    for($y=[Math]::Max(0,$ringY+($client.Top-$bounds.Top)-8);$y -lt [Math]::Min($bitmap.Height,$ringY+($client.Top-$bounds.Top)+$ringDiameter+8);$y++){
      for($x=[Math]::Max(0,$ringX+($client.Left-$bounds.Left)-8);$x -lt [Math]::Min($bitmap.Width,$ringX+($client.Left-$bounds.Left)+$ringDiameter+8);$x++){
        $distance=[Math]::Abs([Math]::Sqrt([Math]::Pow($x-$centerX,2)+[Math]::Pow($y-$centerY,2))-$radius)
        if($distance -gt 4.5){continue};$pixel=$bitmap.GetPixel($x,$y)
        if([Math]::Abs($pixel.R-$expected.R) -le 1 -and [Math]::Abs($pixel.G-$expected.G) -le 1 -and [Math]::Abs($pixel.B-$expected.B) -le 1){$matches++}
      }
    }
  }finally{$bitmap.Dispose()}
  Assert-That ($matches -ge 2) "$Name rendered timer-ring pixels equal $Hex" ([pscustomobject]@{Expected=$Hex;MatchingRingPixels=$matches;RingDiameter=$ringDiameter;Screenshot=$ScreenshotPath})
}
function Get-SettingLine([string]$Key) {
  $content=Get-Content -LiteralPath (Join-Path $dataDirectory 'settings.ini') -Raw;$match=[regex]::Match($content,"(?m)^$([regex]::Escape($Key))=(.*)$")
  if(-not $match.Success){throw "Saved setting '$Key' is missing."};return $match.Groups[1].Value
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
function Get-ScreenshotPixel([string]$ScreenshotPath,[IntPtr]$Window,[int]$ScreenX,[int]$ScreenY) {
  $bounds=Get-Rect $Window;$x=$ScreenX-$bounds.Left;$y=$ScreenY-$bounds.Top;$bitmap=[Drawing.Bitmap]::new($ScreenshotPath)
  try{if($x-lt0-or$y-lt0-or$x-ge$bitmap.Width-or$y-ge$bitmap.Height){throw "Requested pixel ($ScreenX,$ScreenY) is outside the captured window."};$pixel=$bitmap.GetPixel($x,$y);return ('#{0:X2}{1:X2}{2:X2}'-f$pixel.R,$pixel.G,$pixel.B)}finally{$bitmap.Dispose()}
}
function Get-RenderedControlTextContrast([string]$ScreenshotPath,[IntPtr]$Window,$ControlRect,[string]$Background) {
  $windowRect=Get-Rect $Window;$bitmap=[Drawing.Bitmap]::new($ScreenshotPath);$pixels=@{}
  try{
    $left=$ControlRect.Left-$windowRect.Left+8;$right=$ControlRect.Right-$windowRect.Left-24;$top=$ControlRect.Top-$windowRect.Top+4;$bottom=$ControlRect.Bottom-$windowRect.Top-4
    for($y=$top;$y-le$bottom;$y++){for($x=$left;$x-le$right;$x++){$pixel=$bitmap.GetPixel($x,$y);$color=('#{0:X2}{1:X2}{2:X2}'-f$pixel.R,$pixel.G,$pixel.B);if($color-ceq$Background){continue};if(-not$pixels.ContainsKey($color)){$pixels[$color]=0};$pixels[$color]++}}
  }finally{$bitmap.Dispose()}
  $readableColors=@(foreach($entry in $pixels.GetEnumerator()){$ratio=Get-ContrastRatio $entry.Key $Background;if($ratio-ge1.2){[pscustomobject]@{Color=$entry.Key;Pixels=[int]$entry.Value;Contrast=$ratio}}})
  $candidate=@($readableColors|Sort-Object -Property Pixels -Descending|Select-Object -First 1)
  if(-not$candidate.Count){return [pscustomobject]@{RenderedTextColor=$null;Background=$Background;ContrastRatio=0;SampledNonBackgroundColors=$pixels.Count;CorePixelCount=0}}
  [pscustomobject]@{RenderedTextColor=$candidate[0].Color;Background=$Background;ContrastRatio=[Math]::Round($candidate[0].Contrast,2);SampledNonBackgroundColors=$pixels.Count;CorePixelCount=$candidate[0].Pixels}
}
function Get-FocusContrastEvidence([string]$BeforePath,[string]$AfterPath,[IntPtr]$Window,$ControlRect,[string]$Background) {
  $windowRect=Get-Rect $Window;$before=[Drawing.Bitmap]::new($BeforePath);$after=[Drawing.Bitmap]::new($AfterPath);$changed=0;$readable=0;$maxRatio=0.0
  try{
    $left=$ControlRect.Left-$windowRect.Left+4;$right=$ControlRect.Right-$windowRect.Left-5;$top=$ControlRect.Top-$windowRect.Top+4;$bottom=$ControlRect.Bottom-$windowRect.Top-5
    $points=[System.Collections.Generic.List[object]]::new()
    for($x=$left;$x-le$right;$x++){$points.Add(@($x,$top));$points.Add(@($x,$bottom))}
    for($y=$top+1;$y-lt$bottom;$y++){$points.Add(@($left,$y));$points.Add(@($right,$y))}
    foreach($point in $points){$old=$before.GetPixel([int]$point[0],[int]$point[1]);$new=$after.GetPixel([int]$point[0],[int]$point[1]);if($old.ToArgb()-eq$new.ToArgb()){continue};$changed++;$color=('#{0:X2}{1:X2}{2:X2}'-f$new.R,$new.G,$new.B);$ratio=Get-ContrastRatio $color $Background;if($ratio-gt$maxRatio){$maxRatio=$ratio};if($ratio-ge3.0){$readable++}}
  }finally{$before.Dispose();$after.Dispose()}
  [pscustomobject]@{ChangedFocusBorderPixels=$changed;PixelsAtLeast3To1=$readable;MaxFocusPixelContrast=[Math]::Round($maxRatio,2);Background=$Background}
}
function Get-ThemePalette([int]$Theme) {
  if($Theme-eq0){$light=$true;try{$light=[int](Get-ItemPropertyValue -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop)-ne0}catch{};$Theme=if($light){1}else{2}}
  switch($Theme){
    1 {return [pscustomobject]@{Surface='#FFFFFF';Hover='#EBF0F7';Foreground='#181E2A';Secondary='#4C5767'}}
    2 {return [pscustomobject]@{Surface='#272C35';Hover='#333B48';Foreground='#EFF3F9';Secondary='#BCC7D6'}}
    3 {return [pscustomobject]@{Surface='#000000';Hover='#202020';Foreground='#FFFFFF';Secondary='#E5E5E5'}}
    4 {return [pscustomobject]@{Surface='#FFFFFF';Hover='#E6E6E6';Foreground='#000000';Secondary='#202020'}}
    default {throw "Unknown appearance theme $Theme."}
  }
}
function Get-MixedColorHex([string]$Base,[string]$Tint,[int]$TintPercent) {
  $baseColor=[Drawing.ColorTranslator]::FromHtml($Base);$tintColor=[Drawing.ColorTranslator]::FromHtml($Tint)
  $mix={param([int]$b,[int]$t)[int][Math]::Floor(($b*(100-$TintPercent)+$t*$TintPercent)/100)}
  $r=&$mix $baseColor.R $tintColor.R;$g=&$mix $baseColor.G $tintColor.G;$b=&$mix $baseColor.B $tintColor.B
  return ('#{0:X2}{1:X2}{2:X2}' -f $r,$g,$b)
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
  $fixtureDelay=[Math]::Max($Delay,1500)
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
  if($Name-eq'newer-version'){
    $dialog=Find-UiaDialog 'Eye Break Reminder Update Available'
    Assert-That ($dialog.WindowTitle-eq'Eye Break Reminder Update') 'UI Automation targets the actual update Task Dialog window' $dialog.WindowTitle
    $names=@($dialog.Names);$summary=$names -join ' | '
    $hasCurrent=@($names|Where-Object{$_.Contains("Current version: $expectedVersion")}).Count-gt0
    $hasAvailableLabel=@($names|Where-Object{$_.Contains('Available version:')}).Count-gt0
    $hasAvailableVersion=@($names|Where-Object{$_.Contains("v$newerVersion")}).Count-gt0
    $hasReleaseNotes=@($names|Where-Object{$_.Contains('Release notes')}).Count-gt0
    $hasDownloadInstallLabel=@($names|Where-Object{$_.Contains('Download & Install')}).Count-gt0
    Assert-That ($hasCurrent-and$hasAvailableLabel-and$hasAvailableVersion-and$hasReleaseNotes-and$hasDownloadInstallLabel) 'Update dialog exposes current/available versions, install action and release notes' $summary
    Save-Screenshot $dialog.Handle 'update-dialog-newer-release.png'
    Invoke-UiaButton $dialog 'Remind Me Later'
  }
  $watch=[Diagnostics.Stopwatch]::StartNew();$enabled=$false
  while ($watch.Elapsed.TotalSeconds -lt 12) { try { $enabled=(Get-Control $script:mainWindow 160 'Check for Updates').Enabled } catch { };if($enabled){break};Start-Sleep -Milliseconds 100 }
  Assert-That $enabled "$Name check completes"
  $statusText=[EBR_GUI_NATIVE]::Text($script:updateStatusHandle)
  Assert-That ($statusText -like "*$Expected*") "$Name status result" $statusText
  $latest=[EBR_GUI_NATIVE]::Text($script:updateLatestHandle)
  Add-Result "$Name latest label" 'INFO' $latest
}
function Run-UpdateOverlapBarrier {
  Switch-Timer
  Click-Control $script:mainWindow 21 'Reset timer before deterministic update overlap'
  Assert-That ((Wait-Status 'Running') -like '*Running*') 'Timer is running before the update overlap barrier'
  $before=Get-TimerSeconds
  Assert-That ($before -gt 0) 'Countdown has a positive value before the update overlap barrier' $before
  Switch-Settings 5
  Initialize-UpdateHandles
  $script:updateBarrierStarted.Reset();$script:updateBarrierRelease.Reset()
  $body=([ordered]@{tag_name="v$expectedVersion";html_url="https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/tag/v$expectedVersion";draft=$false;prerelease=$false}|ConvertTo-Json -Compress)
  $fixture="status=200`r`nfailure=none`r`nbarrier=1`r`n`r`n$body"
  [IO.File]::WriteAllText($fixturePath,$fixture,[Text.UTF8Encoding]::new($false))
  Click-Control $script:mainWindow 160 'Begin deterministic update overlap barrier'
  $requestStarted=$script:updateBarrierStarted.WaitOne([TimeSpan]::FromSeconds(10))
  Assert-That $requestStarted 'Update worker reached the deliberately unresolved response barrier'
  $button=Get-Control $script:mainWindow 160 'Check for Updates'
  Assert-That (-not $button.Enabled) 'Update action remains busy while the response barrier is held'
  Assert-That (-not $script:updateBarrierRelease.WaitOne(0)) 'Controlled response is still unresolved before timer sampling'
  $text=[Text.StringBuilder]::new(512);$messageResult=[IntPtr]::Zero
  $sendResult=[EBR_GUI_NATIVE]::SendMessageTimeoutTextW($script:updateStatusHandle,0x000D,[IntPtr]512,$text,0x0002,1000,[ref]$messageResult)
  Assert-That ($sendResult -ne [IntPtr]::Zero -and $text.ToString() -like '*Checking*') 'UI responds to a bounded native text request while HTTP work is pending' ([pscustomobject]@{Response=$text.ToString();MessageResult=$messageResult.ToInt64()})
  Save-Screenshot $script:mainWindow 'update-overlap-request-pending.png' | Out-Null
  Switch-Timer
  $watch=[Diagnostics.Stopwatch]::StartNew();$during=$before
  while($watch.Elapsed.TotalSeconds -lt 15 -and $during -ge $before){$during=Get-TimerSeconds;if($during -ge $before){[Threading.Thread]::Sleep(25)}}
  Assert-That ($during -lt $before) 'Countdown advances while the controlled update response remains unresolved' ([pscustomobject]@{Before=$before;During=$during;ElapsedMilliseconds=$watch.ElapsedMilliseconds})
  Assert-That (-not $script:updateBarrierRelease.WaitOne(0)) 'HTTP response remains pending at the observed timer tick'
  $script:updateBarrierRelease.Set()
  Switch-Settings 5
  $watch=[Diagnostics.Stopwatch]::StartNew();$enabled=$false
  while($watch.Elapsed.TotalSeconds -lt 15){try{$enabled=(Get-Control $script:mainWindow 160 'Check for Updates').Enabled}catch{};if($enabled){break};[Threading.Thread]::Sleep(50)}
  Assert-That $enabled 'Update result returns and re-enables the control after the barrier is released'
  $latest=[EBR_GUI_NATIVE]::Text($script:updateLatestHandle);$status=[EBR_GUI_NATIVE]::Text($script:updateStatusHandle)
  Assert-That ($latest -eq "Latest stable version: $expectedVersion" -and $status -like '*up to date*') 'Controlled update response is applied to the UI' ([pscustomobject]@{Latest=$latest;Status=$status})
  Switch-Timer
  $after=Get-TimerSeconds
  Assert-That ($after -le $during -and $after -gt 0) 'Countdown remains consistent after the response is released' ([pscustomobject]@{During=$during;After=$after})
  Save-Screenshot $script:mainWindow 'update-overlap-result-released.png' | Out-Null
  Remove-Item -LiteralPath $fixturePath -Force -ErrorAction SilentlyContinue
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
  Set-Intervals 20 30
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

  Set-Theme 2
  Switch-Settings 4
  $appearanceNames=Get-UiaNames $script:mainWindow
  Assert-That ($appearanceNames -contains 'Work Mode colour' -and $appearanceNames -contains 'Break Mode colour' -and $appearanceNames -contains 'Reset to Default Colours') 'Appearance exposes custom accent labels and reset through UI Automation' ($appearanceNames -join ' | ')
  Assert-That (([EBR_GUI_NATIVE]::Text((Get-Control $script:mainWindow 125 'Work accent swatch').Handle)) -eq '#60A5FA') 'Dark theme displays the existing default work accent'
  Assert-That (([EBR_GUI_NATIVE]::Text((Get-Control $script:mainWindow 126 'Break accent swatch').Handle)) -eq '#2DD4BF') 'Dark theme displays the existing default break accent'
  Save-Screenshot $script:mainWindow 'settings-custom-accent-colours.png' | Out-Null

  $customCombos=@(
    [pscustomobject]@{Name='extreme-black-white';Work=@(0,0,0);Break=@(255,255,255);WorkHex='#000000';BreakHex='#FFFFFF'},
    [pscustomobject]@{Name='purple-orange';Work=@(139,92,246);Break=@(249,115,22);WorkHex='#8B5CF6';BreakHex='#F97316'},
    [pscustomobject]@{Name='blue-pink';Work=@(59,130,246);Break=@(236,72,153);WorkHex='#3B82F6';BreakHex='#EC4899'},
    [pscustomobject]@{Name='bright-yellow-dark-navy';Work=@(255,255,0);Break=@(0,0,128);WorkHex='#FFFF00';BreakHex='#000080'},
    [pscustomobject]@{Name='saturated-red-very-pale';Work=@(255,0,0);Break=@(255,247,237);WorkHex='#FF0000';BreakHex='#FFF7ED'},
    [pscustomobject]@{Name='identical-work-break';Work=@(51,65,85);Break=@(51,65,85);WorkHex='#334155';BreakHex='#334155'},
    [pscustomobject]@{Name='similar-work-break';Work=@(30,64,175);Break=@(29,78,216);WorkHex='#1E40AF';BreakHex='#1D4ED8'},
    [pscustomobject]@{Name='green-red';Work=@(34,197,94);Break=@(239,68,68);WorkHex='#22C55E';BreakHex='#EF4444'}
  )
  foreach($combo in $customCombos){
    Switch-Timer;$timerBeforeWorkPicker=Get-TimerSeconds;Switch-Settings 4
    $workDialog=Open-ColorPicker 127 'Choose Work Mode colour'
    Assert-That ([EBR_GUI_NATIVE]::ClassName($workDialog) -eq '#32770') "$($combo.Name) opens the actual native common colour dialog" ([EBR_GUI_NATIVE]::Text($workDialog))
    if($combo.Name -eq 'purple-orange'){
      foreach($id in @(719,720,721,706,707,708,1,2)){$child=[EBR_GUI_NATIVE]::GetDlgItem($workDialog,$id);Assert-That ($child -ne [IntPtr]::Zero -and [EBR_GUI_NATIVE]::IsWindowVisible($child)) "Native colour picker exposes required dialog control $id"}
      Save-Screenshot $workDialog 'native-choose-color-dialog.png' | Out-Null
    }
    if($combo.Name -eq 'purple-orange'){
      Start-Sleep -Milliseconds 1600
    }
    Set-NativePickerRgb $workDialog $combo.Work[0] $combo.Work[1] $combo.Work[2]
    if($combo.Name -eq 'green-red'){
      $addToPalette=[EBR_GUI_NATIVE]::GetDlgItem($workDialog,712)
      Assert-That ($addToPalette -ne [IntPtr]::Zero -and [EBR_GUI_NATIVE]::IsWindowVisible($addToPalette)) 'Native ChooseColorW exposes Add to Custom Colors'
      [void][EBR_GUI_NATIVE]::SendMessageW($addToPalette,0x00F5,[IntPtr]::Zero,[IntPtr]::Zero)
    }
    Close-NativePicker $workDialog $true
    Switch-Timer;$workAfterPicker=Get-TimerSeconds
    Assert-That ($workAfterPicker -le $timerBeforeWorkPicker) "$($combo.Name) Work Mode colour change leaves the countdown running without resetting it" ([pscustomobject]@{Before=$timerBeforeWorkPicker;After=$workAfterPicker})
    if($combo.Name -eq 'purple-orange'){
      Assert-That ($workAfterPicker -lt $timerBeforeWorkPicker) 'Work countdown advances while the native colour picker is open' ([pscustomobject]@{Before=$timerBeforeWorkPicker;After=$workAfterPicker})
    }
    Switch-Settings 4
    Assert-That ((Get-SettingLine 'customWorkAccent') -eq '1' -and (Get-SettingLine 'workAccentColor') -eq [string][int]([Convert]::ToInt32($combo.WorkHex.Substring(1),16))) "$($combo.Name) Work Mode RGB selection is saved as integer RGB"
    Assert-That (([EBR_GUI_NATIVE]::Text((Get-Control $script:mainWindow 125 'Work accent swatch').Handle)) -eq $combo.WorkHex) "$($combo.Name) Work Mode swatch updates immediately"

    $breakDialog=Open-ColorPicker 128 'Choose Break Mode colour'
    Set-NativePickerRgb $breakDialog $combo.Break[0] $combo.Break[1] $combo.Break[2]
    Close-NativePicker $breakDialog $true
    Switch-Timer
    Assert-That ((Get-SettingLine 'customBreakAccent') -eq '1' -and (Get-SettingLine 'breakAccentColor') -eq [string][int]([Convert]::ToInt32($combo.BreakHex.Substring(1),16))) "$($combo.Name) Break Mode RGB selection is saved independently"
    Switch-Settings 4
    Assert-That (([EBR_GUI_NATIVE]::Text((Get-Control $script:mainWindow 126 'Break accent swatch').Handle)) -eq $combo.BreakHex) "$($combo.Name) Break Mode swatch updates immediately"
    Save-Screenshot $script:mainWindow "settings-custom-combo-$($combo.Name).png" | Out-Null

    Switch-Timer;Click-Control $script:mainWindow 21 'Reset before rendered work ring check';Wait-RingProgress "$($combo.Name) Work"
    $workShot=Save-Screenshot $script:mainWindow "custom-$($combo.Name)-work.png"
    Assert-TimerRingPixel $workShot $combo.WorkHex "$($combo.Name) Work Mode"
    Click-Control $script:mainWindow 22 'Start custom-colour break'
    $breakWindow=Wait-BreakWindow
    Assert-That ((Wait-Status 'Taking an eye break') -like '*Taking an eye break*') "$($combo.Name) break keeps the existing Taking an eye break status"
    Save-Screenshot $breakWindow "reminder-custom-$($combo.Name)-break.png" | Out-Null
    $breakStartSeconds=Get-TimerSeconds;$breakProgressWatch=[Diagnostics.Stopwatch]::StartNew()
    while($breakProgressWatch.Elapsed.TotalSeconds -lt 5 -and (Get-TimerSeconds) -ge $breakStartSeconds){Start-Sleep -Milliseconds 100}
    Assert-That ((Get-TimerSeconds) -lt $breakStartSeconds) "$($combo.Name) Break countdown advances before ring pixel sampling"
    Start-Sleep -Milliseconds 1400
    $breakShot=Save-Screenshot $script:mainWindow "custom-$($combo.Name)-break.png" -PreserveForeground
    Assert-TimerRingPixel $breakShot $combo.BreakHex "$($combo.Name) Break Mode"
    Click-Control $breakWindow 24 'Finish custom-colour break'
    Assert-That ((Wait-Status 'Running') -like '*Running*') "$($combo.Name) break returns to work"
    $workStartSeconds=Get-TimerSeconds;$workProgressWatch=[Diagnostics.Stopwatch]::StartNew()
    while($workProgressWatch.Elapsed.TotalSeconds -lt 5 -and (Get-TimerSeconds) -ge $workStartSeconds){Start-Sleep -Milliseconds 100}
    Assert-That ((Get-TimerSeconds) -lt $workStartSeconds) "$($combo.Name) Work countdown advances after Break completion"
    Start-Sleep -Milliseconds 4500;$returnShot=Save-Screenshot $script:mainWindow "custom-$($combo.Name)-work-after-break.png"
    Assert-TimerRingPixel $returnShot $combo.WorkHex "$($combo.Name) Work Mode after break"
    Switch-Settings 4
  }

  Switch-Timer;$countBeforeCancel=Get-TimerSeconds;Switch-Settings 4
  $beforeCancelWork=Get-SettingLine 'workAccentColor';$beforeCancelCustom=Get-SettingLine 'customWorkAccent';$cancelDialog=Open-ColorPicker 127 'Choose Work Mode colour';Set-NativePickerRgb $cancelDialog 255 255 255
  Start-Sleep -Milliseconds 1300
  Close-NativePicker $cancelDialog $false
  Switch-Timer;$countDuringCancel=Get-TimerSeconds
  Assert-That ($countDuringCancel -lt $countBeforeCancel) 'Countdown keeps running while a picker selection is pending'
  Assert-That ((Get-SettingLine 'workAccentColor') -eq $beforeCancelWork -and (Get-SettingLine 'customWorkAccent') -eq $beforeCancelCustom) 'Cancel leaves the stored Work Mode colour unchanged'
  Switch-Settings 4
  Assert-That (([EBR_GUI_NATIVE]::Text((Get-Control $script:mainWindow 125 'Work accent swatch').Handle)) -eq '#22C55E') 'Cancel leaves the visible swatch unchanged'
  Switch-Timer;$cancelShot=Save-Screenshot $script:mainWindow 'custom-cancel-keeps-green.png';Assert-TimerRingPixel $cancelShot '#22C55E' 'Cancelled Work Mode selection'

  Switch-Settings 4;$resourceWarmup=5;$resourceCycles=40
  for($i=0;$i -lt ($resourceWarmup+$resourceCycles);$i++){
    $beforeValue=Get-SettingLine 'workAccentColor';$dialog=Open-ColorPicker 127 'Repeated Work Mode colour picker'
    $accept=($i%2 -eq 0)
    if($accept){Close-NativePicker $dialog $true}
    else{Set-NativePickerRgb $dialog 255 255 255;Close-NativePicker $dialog $false}
    $afterValue=Get-SettingLine 'workAccentColor'
    Assert-That ($afterValue -eq $beforeValue) "Repeated picker $(if($accept){'OK'}else{'Cancel'}) action $($i+1) preserves the current RGB" $afterValue
    if($i -ge $resourceWarmup){$script:pickerResourceSamples.Add((Get-PickerResourceSample ($i-$resourceWarmup+1)))}
  }
  $resourceTrends=@((Get-PickerResourceTrend 'USER objects' 'UserObjects'),(Get-PickerResourceTrend 'GDI objects' 'GdiObjects'),(Get-PickerResourceTrend 'process handles' 'HandleCount'),(Get-PickerResourceTrend 'private bytes' 'PrivateBytes'),(Get-PickerResourceTrend 'working set bytes' 'WorkingSetBytes'))
  foreach($trend in $resourceTrends){
    $tolerance=switch($trend.Resource){'private bytes'{1048576}'working set bytes'{8388608}default{2}}
    $needsFlatSlope=($trend.Resource -notin @('private bytes','working set bytes'))
    Assert-That ($trend.EndMedian -le ($trend.StartMedian+$tolerance) -and (-not $needsFlatSlope -or $trend.SlopePerInteraction -le 0.15)) "Repeated native picker has no sustained $($trend.Resource) growth" ([pscustomobject]@{Trend=$trend;AllowedMedianDrift=$tolerance})
  }
  Add-Result 'Repeated native picker resource soak' 'INFO' ([pscustomobject]@{WarmupDialogs=$resourceWarmup;MeasuredDialogs=$resourceCycles;OkActions=[int]($resourceCycles/2);CancelActions=[int]($resourceCycles/2);Trends=$resourceTrends})
  Switch-Timer;$breakResourceCycles=20
  for($i=1;$i -le $breakResourceCycles;$i++){
    Click-Control $script:mainWindow 22 "Resource-soak eye break $i";$resourceBreak=Wait-BreakWindow
    Click-Control $resourceBreak 24 "Close resource-soak eye break $i"
    Assert-That ((Wait-Status 'Running') -like '*Running*') "Reminder window resource cycle $i returned to Work Mode"
    Assert-That ((Find-BreakWindow) -eq [IntPtr]::Zero) "Reminder window resource cycle $i destroyed its window"
    $script:breakResourceSamples.Add((Get-PickerResourceSample $i))
  }
  $breakResourceTrends=@((Get-PickerResourceTrend 'USER objects' 'UserObjects' $script:breakResourceSamples),(Get-PickerResourceTrend 'GDI objects' 'GdiObjects' $script:breakResourceSamples),(Get-PickerResourceTrend 'process handles' 'HandleCount' $script:breakResourceSamples),(Get-PickerResourceTrend 'private bytes' 'PrivateBytes' $script:breakResourceSamples),(Get-PickerResourceTrend 'working set bytes' 'WorkingSetBytes' $script:breakResourceSamples))
  foreach($trend in $breakResourceTrends){$tolerance=switch($trend.Resource){'private bytes'{1048576}'working set bytes'{8388608}default{2}};$flat=($trend.Resource -notin @('private bytes','working set bytes'));Assert-That ($trend.EndMedian -le ($trend.StartMedian+$tolerance) -and (-not $flat -or $trend.SlopePerInteraction -le 0.15)) "Repeated reminder windows have no sustained $($trend.Resource) growth" ([pscustomobject]@{Trend=$trend;AllowedMedianDrift=$tolerance})}
  Add-Result 'Repeated reminder-window resource soak' 'INFO' ([pscustomobject]@{MeasuredCycles=$breakResourceCycles;ClosedWindows=$breakResourceCycles;Trends=$breakResourceTrends})
  # This executable accelerates its monotonic clock tenfold. Keep both phases long enough for the five-theme render checks.
  Set-Intervals 180 300;Switch-Timer;Click-Control $script:mainWindow 21 'Reset after picker verification'

  $themeNames=@('follow-windows','light','dark','high-contrast-dark','high-contrast-light')
  foreach ($theme in 0..4) {
    Set-Theme $theme
    Assert-That ((Get-SettingLine 'workAccentColor') -eq [string][int]0x22C55E -and (Get-SettingLine 'breakAccentColor') -eq [string][int]0xEF4444) "$($themeNames[$theme]) preserves both custom colours"
    if ($theme -eq 0) {
      [void][EBR_GUI_NATIVE]::SendMessageW($script:mainWindow,0x031A,[IntPtr]::Zero,[IntPtr]::Zero)
      Start-Sleep -Milliseconds 150
      Assert-That ((Wait-Status 'Running') -like '*Running*') 'Follow Windows repaints on WM_THEMECHANGED'
    }
    Wait-RingProgress "$($themeNames[$theme]) Work"
    Assert-StatusAlignment "$($themeNames[$theme]) work"
    Save-Screenshot $script:mainWindow ("timer-{0}-work.png" -f $themeNames[$theme]) | Out-Null
    if($theme -eq 3){$contrastWorkShot=Save-Screenshot $script:mainWindow 'custom-high-contrast-dark-work.png';Assert-TimerRingPixel $contrastWorkShot '#FFFF00' 'High Contrast Dark overrides custom Work Mode colour'}
    if($theme -eq 4){$contrastWorkShot=Save-Screenshot $script:mainWindow 'custom-high-contrast-light-work.png';Assert-TimerRingPixel $contrastWorkShot '#0000B3' 'High Contrast Light overrides custom Work Mode colour'}
    Click-Control $script:mainWindow 11 'History navigation'
    Save-Screenshot $script:mainWindow ("history-{0}.png" -f $themeNames[$theme]) | Out-Null
    Switch-Settings 4
    $selectedShot=Save-Screenshot $script:mainWindow ("settings-{0}.png" -f $themeNames[$theme])
    $selectedTab=Get-Control $script:mainWindow 134 'Selected Appearance section tab'
    # Sample blank interior padding, away from the label glyph and the 2 px high-contrast border stroke.
    $selectedTabX=$selectedTab.Rect.Left+8;$selectedTabY=[int](($selectedTab.Rect.Top+$selectedTab.Rect.Bottom)/2)
    $selectedTabPixel=Get-ScreenshotPixel $selectedShot $script:mainWindow $selectedTabX $selectedTabY
    $selectedAccent=@('#22C55E','#22C55E','#22C55E','#FFFF00','#0000B3')[$theme]
    $palette=Get-ThemePalette $theme
    $expectedSelectedFill=Get-MixedColorHex $palette.Surface $selectedAccent 22
    Assert-That ($selectedTabPixel-ceq$expectedSelectedFill) "$($themeNames[$theme]) selected Appearance tab uses a tint of its active Work accent" ([pscustomobject]@{ExpectedFill=$expectedSelectedFill;Accent=$selectedAccent;TintPercent=22;Actual=$selectedTabPixel;ControlId=134;Screenshot=$selectedShot})
    $workPicker=Get-Control $script:mainWindow 127 'Work colour picker for keyboard focus and hover matrix'
    Set-AppFocus $workPicker.Handle
    $actualFocus=Get-AppFocusedControl $script:mainWindow
    Assert-That ($actualFocus-eq$workPicker.Handle) "$($themeNames[$theme]) Work picker receives keyboard focus" ([pscustomobject]@{ActualHandle=$actualFocus.ToInt64();ExpectedHandle=$workPicker.Handle.ToInt64();FocusReadOnTargetThread=$true})
    [void][EBR_GUI_NATIVE]::SendMessageW($script:mainWindow,0x0127,[IntPtr]::new(0x00010002),[IntPtr]::Zero)
    [void][EBR_GUI_NATIVE]::InvalidateRect($workPicker.Handle,[IntPtr]::Zero,$true);[void][EBR_GUI_NATIVE]::UpdateWindow($workPicker.Handle)
    $focusShot=Save-Screenshot $script:mainWindow "ui-state-$($themeNames[$theme])-work-picker-focus.png"
    $focusEvidence=Get-FocusContrastEvidence $selectedShot $focusShot $script:mainWindow $workPicker.Rect $palette.Surface
    Assert-That ($focusEvidence.ChangedFocusBorderPixels-ge2-and$focusEvidence.PixelsAtLeast3To1-ge2) "$($themeNames[$theme]) visible keyboard focus outline contrasts at least 3:1" $focusEvidence
    [void][EBR_GUI_NATIVE]::SetCursorPos(0,0);Start-Sleep -Milliseconds 120
    $idleShot=Save-Screenshot $script:mainWindow "ui-state-$($themeNames[$theme])-work-picker-idle.png"
    # Keep the sample inside the fill, clear of the centred caption and focus border.
    $sampleX=$workPicker.Rect.Left+8;$sampleY=[int](($workPicker.Rect.Top+$workPicker.Rect.Bottom)/2)
    $idlePixel=Get-ScreenshotPixel $idleShot $script:mainWindow $sampleX $sampleY
    Assert-That ($idlePixel-ceq$palette.Surface) "$($themeNames[$theme]) button idle fill matches its rendered theme surface" ([pscustomobject]@{Expected=$palette.Surface;Actual=$idlePixel;SampleX=$sampleX;SampleY=$sampleY})
    [void][EBR_GUI_NATIVE]::SetCursorPos([int](($workPicker.Rect.Left+$workPicker.Rect.Right)/2),$sampleY);Start-Sleep -Milliseconds 120
    $hoverShot=Save-Screenshot $script:mainWindow "ui-state-$($themeNames[$theme])-work-picker-hover.png"
    $hoverPixel=Get-ScreenshotPixel $hoverShot $script:mainWindow $sampleX $sampleY
    $hoverContrast=Get-ContrastRatio $palette.Foreground $hoverPixel
    Assert-That ($hoverPixel-ceq$palette.Hover) "$($themeNames[$theme]) actual pointer hover fill matches the theme hover color" ([pscustomobject]@{Expected=$palette.Hover;Actual=$hoverPixel;Screenshot=$hoverShot})
    Assert-That ($hoverContrast-ge4.5) "$($themeNames[$theme]) hovered Work picker text contrast is at least 4.5:1" ([pscustomobject]@{Foreground=$palette.Foreground;RenderedBackground=$hoverPixel;ContrastRatio=[Math]::Round($hoverContrast,2)})
    [void][EBR_GUI_NATIVE]::SetCursorPos(0,0)
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
    Save-Screenshot $breakWindow ("reminder-{0}.png" -f $themeNames[$theme]) | Out-Null
    $breakCount=[EBR_GUI_NATIVE]::Text((Get-Control $breakWindow 40 'Break countdown').Handle)
    Assert-That ($breakCount -match '^\d+:\d{2}$') "$($themeNames[$theme]) break duration visible" $breakCount
    Wait-RingProgress "$($themeNames[$theme]) Break"
    Save-Screenshot $script:mainWindow ("timer-{0}-break.png" -f $themeNames[$theme]) -PreserveForeground | Out-Null
    if($theme -eq 3){Assert-TimerRingPixel (Join-Path $EvidenceDirectory ("timer-{0}-break.png" -f $themeNames[$theme])) '#00FFFF' 'High Contrast Dark overrides custom Break Mode colour'}
    if($theme -eq 4){Assert-TimerRingPixel (Join-Path $EvidenceDirectory ("timer-{0}-break.png" -f $themeNames[$theme])) '#005A00' 'High Contrast Light overrides custom Break Mode colour'}
    Click-Control $breakWindow 24 'Skip eye break'
    Assert-That ((Wait-Status 'Running') -like '*Running*') "$($themeNames[$theme]) returns to work after skip"
    Click-Control $script:mainWindow 20 "$($themeNames[$theme]) pause state matrix"
    Assert-That ((Wait-Status 'Paused')-like'*Paused*') "$($themeNames[$theme]) paused state remains named"
    Assert-StatusAlignment "$($themeNames[$theme]) paused state matrix"
    Save-Screenshot $script:mainWindow "ui-state-$($themeNames[$theme])-paused.png"|Out-Null
    Click-Control $script:mainWindow 20 "$($themeNames[$theme]) resume state matrix"
    Assert-That ((Wait-Status 'Running')-like'*Running*') "$($themeNames[$theme]) resumes from pause"
    Switch-Settings 1
    Set-Check $script:mainWindow 120 $false "$($themeNames[$theme]) disable schedule before held-state fixture"
    foreach($dayId in 280..286){Set-Check $script:mainWindow $dayId $false "$($themeNames[$theme]) clear schedule day $dayId"}
    $scheduleTime=Get-Control $script:mainWindow 300 "$($themeNames[$theme]) disabled Monday start time"
    Assert-That (-not $scheduleTime.Enabled) "$($themeNames[$theme]) inactive schedule input is disabled" ([pscustomobject]@{ControlId=300;Text=$scheduleTime.Text;Bounds=$scheduleTime.Rect})
    $disabledShot=Save-Screenshot $script:mainWindow "ui-state-$($themeNames[$theme])-disabled-schedule-input.png"
    $disabledBg=Get-ScreenshotPixel $disabledShot $script:mainWindow ($scheduleTime.Rect.Right-8) ([int](($scheduleTime.Rect.Top+$scheduleTime.Rect.Bottom)/2))
    $disabledTextEvidence=Get-RenderedControlTextContrast $disabledShot $script:mainWindow $scheduleTime.Rect $disabledBg
    Assert-That ($disabledTextEvidence.CorePixelCount-ge3-and$disabledTextEvidence.ContrastRatio-ge3.0) "$($themeNames[$theme]) rendered disabled schedule text contrasts at least 3:1" ([pscustomobject]@{ExpectedSurface=$palette.Surface;MeasuredSurface=$disabledBg;Rendered=$disabledTextEvidence;Screenshot=$disabledShot})
    Set-Check $script:mainWindow 120 $true "$($themeNames[$theme]) enable empty schedule hold"
    Switch-Timer
    Assert-That ((Wait-Status 'Outside scheduled hours')-like'*Outside scheduled hours*') "$($themeNames[$theme]) schedule enters the held state"
    Assert-StatusAlignment "$($themeNames[$theme]) scheduled hold state matrix"
    Save-Screenshot $script:mainWindow "ui-state-$($themeNames[$theme])-scheduled-hold.png"|Out-Null
    Switch-Settings 1;Set-Check $script:mainWindow 120 $false "$($themeNames[$theme]) restore schedule disabled";Switch-Timer
    Assert-That ((Wait-Status 'Running')-like'*Running*') "$($themeNames[$theme]) returns to Running after schedule fixture"
    Click-Control $script:mainWindow 22 "$($themeNames[$theme]) snooze state matrix Break";$snoozeWindow=Wait-BreakWindow
    Click-Control $snoozeWindow 25 "$($themeNames[$theme]) snooze state matrix action"
    Assert-That ((Wait-Status 'Snoozed')-like'*Snoozed*') "$($themeNames[$theme]) snoozed state remains named"
    Assert-StatusAlignment "$($themeNames[$theme]) snoozed state matrix"
    Save-Screenshot $script:mainWindow "ui-state-$($themeNames[$theme])-snoozed.png"|Out-Null
    Click-Control $script:mainWindow 21 "$($themeNames[$theme]) clear snooze state fixture"
    Assert-That ((Wait-Status 'Running')-like'*Running*') "$($themeNames[$theme]) Reset clears its snooze fixture"
  }

  # Repeat the visible timer states with distinct Break colours disabled. This
  # exercises the other half of the theme × accent-mode matrix. Standard
  # themes share the Work ring; High Contrast retains its accessible phase
  # colours even when custom accents are shared.
  $sharedAccentByTheme=@('#22C55E','#22C55E','#22C55E','#FFFF00','#0000B3')
  $sharedBreakAccentByTheme=@('#22C55E','#22C55E','#22C55E','#00FFFF','#005A00')
  foreach($theme in 0..4){
    $themeName=$themeNames[$theme];$sharedAccent=$sharedAccentByTheme[$theme]
    Set-Theme $theme;Switch-Settings 4;Set-Check $script:mainWindow 124 $false "$themeName disable distinct Break accent for shared-colour state matrix"
    Assert-That ((Get-SettingLine 'breakModeColors')-eq'0') "$themeName shared-colour matrix disables distinct Break accent"
    Switch-Timer;Click-Control $script:mainWindow 21 "$themeName reset shared-colour Work state";Wait-RingProgress "$themeName shared-colour Work"
    $sharedWorkShot=Save-Screenshot $script:mainWindow "shared-accent-$themeName-work-running.png"
    Assert-TimerRingPixel $sharedWorkShot $sharedAccent "$themeName shared-colour matrix Running Work ring"
    Click-Control $script:mainWindow 20 "$themeName shared-colour pause state"
    Assert-That ((Wait-Status 'Paused')-like'*Paused*') "$themeName shared-colour matrix Paused state"
    Assert-StatusAlignment "$themeName shared-colour Paused state"
    Save-Screenshot $script:mainWindow "shared-accent-$themeName-paused.png"|Out-Null
    Click-Control $script:mainWindow 20 "$themeName resume shared-colour state"
    Assert-That ((Wait-Status 'Running')-like'*Running*') "$themeName resumes from shared-colour pause"
    Click-Control $script:mainWindow 22 "$themeName shared-colour Break state";$sharedBreakWindow=Wait-BreakWindow
    Assert-That ((Wait-Status 'Taking an eye break')-like'*Taking an eye break*') "$themeName shared-colour matrix Break state"
    Wait-RingProgress "$themeName shared-colour Break";$sharedBreakShot=Save-Screenshot $script:mainWindow "shared-accent-$themeName-break.png" -PreserveForeground
    $sharedBreakAccent=$sharedBreakAccentByTheme[$theme]
    $ringExpectation=if($theme-ge3){'preserves the accessible system Break ring in High Contrast'}else{'uses the shared Work ring colour'}
    Assert-TimerRingPixel $sharedBreakShot $sharedBreakAccent "$themeName shared-accent Break $ringExpectation"
    Click-Control $sharedBreakWindow 24 "$themeName complete shared-colour Break";Assert-That ((Wait-Status 'Running')-like'*Running*') "$themeName returns to Work after shared-colour Break"
    Switch-Settings 1;Set-Check $script:mainWindow 120 $false "$themeName clear schedule before shared-colour hold"
    foreach($dayId in 280..286){Set-Check $script:mainWindow $dayId $false "$themeName clear shared-colour schedule day $dayId"}
    Set-Check $script:mainWindow 120 $true "$themeName enable empty schedule shared-colour hold";Switch-Timer
    Assert-That ((Wait-Status 'Outside scheduled hours')-like'*Outside scheduled hours*') "$themeName shared-colour matrix scheduled hold"
    Assert-StatusAlignment "$themeName shared-colour scheduled hold"
    Save-Screenshot $script:mainWindow "shared-accent-$themeName-scheduled-hold.png"|Out-Null
    Switch-Settings 1;Set-Check $script:mainWindow 120 $false "$themeName restore disabled shared-colour schedule";Switch-Timer
    Assert-That ((Wait-Status 'Running')-like'*Running*') "$themeName returns to Running after shared-colour hold"
    Click-Control $script:mainWindow 22 "$themeName shared-colour Snooze reminder";$sharedSnoozeWindow=Wait-BreakWindow
    Click-Control $sharedSnoozeWindow 25 "$themeName shared-colour Snooze action"
    Assert-That ((Wait-Status 'Snoozed')-like'*Snoozed*') "$themeName shared-colour matrix Snoozed state"
    Assert-StatusAlignment "$themeName shared-colour Snoozed state"
    Save-Screenshot $script:mainWindow "shared-accent-$themeName-snoozed.png"|Out-Null
    Click-Control $script:mainWindow 21 "$themeName clear shared-colour Snooze state"
    Assert-That ((Wait-Status 'Running')-like'*Running*') "$themeName Reset clears the shared-colour Snooze fixture"
  }
  Switch-Settings 4;Set-Check $script:mainWindow 124 $true 'Restore distinct Break colours after the shared-colour matrix';Set-Theme 2;Switch-Timer

  Test-SystemHighContrast
  Test-ReducedMotionIntegration

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
  function Release-Fixture([string]$Tag,[bool]$Prerelease=$false){
    $tagName="v$Tag";$downloadBase="https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/download/$tagName/";$digest='sha256:'+('a'*64)
    $assets=@(
      [ordered]@{name='EyeBreakReminder-Setup-x64.exe';browser_download_url=($downloadBase+'EyeBreakReminder-Setup-x64.exe');size=2097152;digest=$digest},
      [ordered]@{name='EyeBreakReminder.exe';browser_download_url=($downloadBase+'EyeBreakReminder.exe');size=1048576;digest=$digest}
    )
    return ([ordered]@{tag_name=$tagName;html_url="https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/tag/$tagName";draft=$false;prerelease=$Prerelease;body='Controlled GUI acceptance fixture release notes.';assets=$assets}|ConvertTo-Json -Compress -Depth 6)
  }
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
  Run-UpdateOverlapBarrier

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

  $sharedAccentExpected=@('#22C55E','#22C55E','#22C55E','#00FFFF','#005A00')
  foreach($theme in 0..4){
    Set-Theme $theme;Switch-Settings 4;Set-Check $script:mainWindow 124 $false "$($themeNames[$theme]) distinct Break accent disabled";Switch-Timer
    Click-Control $script:mainWindow 22 "$($themeNames[$theme]) shared Work accent during Break";$breakWindow=Wait-BreakWindow
    Assert-That ((Wait-Status 'Taking an eye break')-like'*Taking an eye break*') "$($themeNames[$theme]) shared-accent Break status remains clear"
    Wait-RingProgress "$($themeNames[$theme]) shared-accent Break";$sharedShot=Save-Screenshot $script:mainWindow "timer-$($themeNames[$theme])-break-accent-off.png" -PreserveForeground
    Assert-TimerRingPixel $sharedShot $sharedAccentExpected[$theme] "$($themeNames[$theme]) Break ring respects disabled distinct accent and theme contrast"
    Save-Screenshot $breakWindow "reminder-$($themeNames[$theme])-break-accent-off.png" -PreserveForeground|Out-Null
    Click-Control $breakWindow 24 "$($themeNames[$theme]) finish shared-accent Break";Assert-That ((Wait-Status 'Running')-like'*Running*') "$($themeNames[$theme]) shared-accent Break returns to Work"
    Switch-Settings 4;Set-Check $script:mainWindow 124 $true "$($themeNames[$theme]) restore distinct Break accent";Switch-Timer
  }
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
  Assert-That ((Get-SettingLine 'customWorkAccent') -eq '1' -and (Get-SettingLine 'workAccentColor') -eq [string][int]0x22C55E) 'Custom Work Mode colour persists across application restart'
  Assert-That ((Get-SettingLine 'customBreakAccent') -eq '1' -and (Get-SettingLine 'breakAccentColor') -eq [string][int]0xEF4444) 'Custom Break Mode colour persists across application restart'
  Assert-That (([EBR_GUI_NATIVE]::Text((Get-Control $script:mainWindow 125 'Work accent swatch').Handle)) -eq '#22C55E' -and ([EBR_GUI_NATIVE]::Text((Get-Control $script:mainWindow 126 'Break accent swatch').Handle)) -eq '#EF4444') 'Both custom color swatches restore after application restart'
  $paletteIndex=-1
  for($i=0;$i -lt 16;$i++){if((Get-SettingLine "pickerCustomColor$i") -eq [string][int]0x22C55E){$paletteIndex=$i;break}}
  Assert-That ($paletteIndex -ge 0) 'Native picker custom-colour palette persists its added colour across restart' ([pscustomobject]@{PaletteIndex=$paletteIndex;Stored=if($paletteIndex -ge 0){Get-SettingLine "pickerCustomColor$paletteIndex"}else{$null}})
  $paletteDialog=Open-ColorPicker 127 'Reopen Work Mode colour picker after restart'
  $paletteSwatch=[EBR_GUI_NATIVE]::GetDlgItem($paletteDialog,721+$paletteIndex)
  Assert-That ($paletteSwatch -ne [IntPtr]::Zero) 'Restarted native picker exposes the persisted custom swatch' ([pscustomobject]@{ControlId=721+$paletteIndex})
  [void][EBR_GUI_NATIVE]::SendMessageW($paletteSwatch,0x00F5,[IntPtr]::Zero,[IntPtr]::Zero)
  $paletteRgb=Get-NativePickerRgb $paletteDialog
  Assert-That (($paletteRgb -join ',') -eq '34,197,94') 'Persisted native custom-colour swatch selects the same RGB after restart' $paletteRgb
  Close-NativePicker $paletteDialog $false
  Save-Screenshot $script:mainWindow 'theme-persistence-high-contrast-light.png' | Out-Null
  $timerBeforeReset=Get-Content -LiteralPath (Join-Path $dataDirectory 'timer.dat') -Raw
  Click-Control $script:mainWindow 129 'Reset to Default Colours'
  Assert-That ((Get-SettingLine 'customWorkAccent') -eq '0' -and (Get-SettingLine 'customBreakAccent') -eq '0') 'Reset clears only both custom accent overrides'
  Assert-That (([EBR_GUI_NATIVE]::Text((Get-Control $script:mainWindow 125 'Work accent swatch').Handle)) -eq '#0000B3' -and ([EBR_GUI_NATIVE]::Text((Get-Control $script:mainWindow 126 'Break accent swatch').Handle)) -eq '#005A00') 'Reset shows the accessible defaults for the active high-contrast theme'
  Assert-That ((Get-Combo $script:mainWindow 106 'Theme') -eq 4) 'Reset preserves the selected theme'
  Assert-That ((Get-Content -LiteralPath (Join-Path $dataDirectory 'timer.dat') -Raw) -eq $timerBeforeReset) 'Reset does not modify saved timer state'
  Set-Theme 2
  Switch-Settings 4
  Assert-That (([EBR_GUI_NATIVE]::Text((Get-Control $script:mainWindow 125 'Work accent swatch').Handle)) -eq '#60A5FA' -and ([EBR_GUI_NATIVE]::Text((Get-Control $script:mainWindow 126 'Break accent swatch').Handle)) -eq '#2DD4BF') 'Reset restores the original Dark theme accent colours'
  Switch-Timer
  Wait-RingProgress 'Reset to default Work Mode'
  $resetRingShot=Save-Screenshot $script:mainWindow 'custom-reset-default-work.png'
  Assert-TimerRingPixel $resetRingShot '#60A5FA' 'Reset restores rendered default Work Mode ring'
  Close-TestProcess
  Add-Result 'GUI acceptance suite' 'PASS' ([pscustomobject]@{Assertions=$script:assertionCount;EvidenceDirectory=$EvidenceDirectory;TestDataDirectory=$dataDirectory;Version=$version})
}
catch {
  Add-Result 'GUI acceptance suite' 'FAIL' $_.Exception.Message
  throw
}
finally {
  try{$script:updateBarrierRelease.Set()}catch{}
  Remove-Item -LiteralPath $fixturePath -Force -ErrorAction SilentlyContinue
  try { Close-TestProcess } catch { Add-Result 'test-app cleanup' 'FAIL' $_.Exception.Message }
  [Environment]::SetEnvironmentVariable('EBR_GUI_TEST_UPDATE_STARTED',$script:oldUpdateBarrierStarted,'Process')
  [Environment]::SetEnvironmentVariable('EBR_GUI_TEST_UPDATE_RELEASE',$script:oldUpdateBarrierRelease,'Process')
  if($script:updateBarrierStarted){$script:updateBarrierStarted.Dispose()}
  if($script:updateBarrierRelease){$script:updateBarrierRelease.Dispose()}
  if($script:pickerResourceSamples.Count){$script:pickerResourceSamples|Export-Csv -LiteralPath (Join-Path $EvidenceDirectory 'picker-resource-time-series.csv') -NoTypeInformation -Encoding utf8}
  if($script:breakResourceSamples.Count){$script:breakResourceSamples|Export-Csv -LiteralPath (Join-Path $EvidenceDirectory 'reminder-window-resource-time-series.csv') -NoTypeInformation -Encoding utf8}
  $os=Get-CimInstance Win32_OperatingSystem
  $guiExecutableHash=(Get-FileHash -LiteralPath $exePath -Algorithm SHA256).Hash.ToLowerInvariant()
  $report=[pscustomobject]@{Version=$expectedVersion;ExecutableRole='Accelerated GUI test build; distinct from the production release candidate';ExecutableSHA256=$guiExecutableHash;WindowsCaption=$os.Caption;WindowsVersion=$os.Version;WindowsBuild=$os.BuildNumber;OSArchitecture=[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString();ProcessArchitecture=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString();InteractiveDesktopAvailable=[Environment]::UserInteractive;Assertions=$script:assertionCount;Events=$script:events.ToArray();EvidenceDirectory=$EvidenceDirectory;TestDataDirectory=$dataDirectory}
  $report | ConvertTo-Json -Depth 9 | Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'gui-acceptance-results.json') -Encoding UTF8
  Write-Output "GUI acceptance: $($script:assertionCount) assertions; evidence: $EvidenceDirectory"
}
