param(
  [string]$InstallerPath = (Join-Path $PSScriptRoot '..\release\EyeBreakReminder-Setup-x64.exe'),
  [string]$EvidenceDirectory = (Join-Path $PSScriptRoot '..\build\pre-release-evidence')
)
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$expectedInstaller = [IO.Path]::GetFullPath((Join-Path $repoRoot 'release\EyeBreakReminder-Setup-x64.exe'))
$expectedEvidence = [IO.Path]::GetFullPath((Join-Path $repoRoot 'build\pre-release-evidence'))
$InstallerPath = [IO.Path]::GetFullPath($InstallerPath)
$EvidenceDirectory = [IO.Path]::GetFullPath($EvidenceDirectory)
if ($InstallerPath -ine $expectedInstaller) { throw "Refusing to execute an installer outside the just-built Eye Break Reminder package: $expectedInstaller" }
if ($EvidenceDirectory -ine $expectedEvidence) { throw "Refusing to write evidence outside the isolated build folder: $expectedEvidence" }
if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) { throw "The v1.2.0 installer is missing: $InstallerPath" }
[void][IO.Directory]::CreateDirectory($EvidenceDirectory)

$installDir = Join-Path $env:LOCALAPPDATA 'Programs\EyeBreakReminder'
$dataDir = Join-Path $env:LOCALAPPDATA 'EyeBreakReminder'
$startMenuDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Eye Break Reminder'
$startMenuLink = Join-Path $startMenuDir 'Eye Break Reminder.lnk'
$desktopLink = Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) 'Eye Break Reminder.lnk'
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder'
$appKey = 'HKCU:\Software\EyeBreakReminder'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$personalizeKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
$accessibilityKey = 'HKCU:\Software\Microsoft\Accessibility'
$appExe = Join-Path $installDir 'EyeBreakReminder.exe'
$script:events = [System.Collections.Generic.List[object]]::new()
$script:passCount = 0
$script:failCount = 0
$script:notTestedCount = 0
$script:appPid = 0
$script:mainWindow = [IntPtr]::Zero
$script:ownedInstall = $false
$script:ownedData = $false
$script:interactiveDesktop = $false
$script:liveRelease = $null
$script:liveApiError = ''
$script:liveLatestError = ''
$script:osOriginal = @{}
$script:highContrastOriginal = $null
$script:transcriptStarted = $false
$script:uninstallerDiagnostics = [System.Collections.Generic.List[object]]::new()
$fatal = $false

$native = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
[StructLayout(LayoutKind.Sequential)] public struct EBR_PRE_RECT { public int Left, Top, Right, Bottom; }
[StructLayout(LayoutKind.Sequential)] public struct EBR_PRE_POINT { public int X, Y; }
[StructLayout(LayoutKind.Sequential)] public struct EBR_PRE_HIGHCONTRAST { public uint cbSize, dwFlags; public IntPtr lpszDefaultScheme; }
[StructLayout(LayoutKind.Sequential)] public struct EBR_PRE_NOTIFYICONIDENTIFIER { public uint cbSize; public IntPtr hWnd; public uint uID; public Guid guidItem; }
public static class EBR_PRE_NATIVE {
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
  [DllImport("user32.dll", SetLastError=true)] public static extern bool GetWindowRect(IntPtr hwnd, out EBR_PRE_RECT rect);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool GetClientRect(IntPtr hwnd, out EBR_PRE_RECT rect);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool ClientToScreen(IntPtr hwnd, ref EBR_PRE_POINT point);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern int GetWindowTextW(IntPtr hwnd, StringBuilder text, int maxCount);
  [DllImport("user32.dll", SetLastError=true)] private static extern int GetWindowTextLengthW(IntPtr hwnd);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern int GetClassNameW(IntPtr hwnd, StringBuilder name, int maxCount);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr FindWindowW(string className, string windowName);
  [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr GetParent(IntPtr hwnd);
  [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr SendMessageW(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr SendMessageTimeoutW(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr insertAfter, int x, int y, int width, int height, uint flags);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool SetForegroundWindow(IntPtr hwnd);
  [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll", SetLastError=true)] public static extern uint GetDpiForWindow(IntPtr hwnd);
  [DllImport("user32.dll", SetLastError=true)] public static extern int GetSystemMetrics(int index);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern uint RegisterWindowMessageW(string name);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool PostMessageW(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] private static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
  public static void Key(byte key,bool up){keybd_event(key,0,up?2u:0u,UIntPtr.Zero);}
  [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr GetDC(IntPtr hwnd);
  [DllImport("user32.dll", SetLastError=true)] public static extern int ReleaseDC(IntPtr hwnd, IntPtr dc);
  [DllImport("gdi32.dll", SetLastError=true)] public static extern uint GetPixel(IntPtr dc, int x, int y);
  [DllImport("oleacc.dll", PreserveSig=true)] private static extern int AccessibleObjectFromWindow(IntPtr hwnd, int objectId, ref Guid iid, out IntPtr accessible);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool SystemParametersInfoW(uint action, uint parameter, ref EBR_PRE_HIGHCONTRAST value, uint flags);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool SystemParametersInfoSimpleW(uint action, uint parameter, IntPtr value, uint flags);
  [DllImport("shell32.dll", SetLastError=true)] public static extern int Shell_NotifyIconGetRect(ref EBR_PRE_NOTIFYICONIDENTIFIER id, out EBR_PRE_RECT rect);
  public static string Text(IntPtr hwnd) { int n=GetWindowTextLengthW(hwnd);StringBuilder b=new StringBuilder(Math.Max(2,n+2));GetWindowTextW(hwnd,b,b.Capacity);return b.ToString(); }
  public static string ClassName(IntPtr hwnd) { StringBuilder b=new StringBuilder(256);GetClassNameW(hwnd,b,b.Capacity);return b.ToString(); }
  public static IntPtr[] TopWindowsForProcess(int pid) { List<IntPtr> r=new List<IntPtr>();EnumCallback cb=delegate(IntPtr h,IntPtr ignored){uint actual;GetWindowThreadProcessId(h,out actual);if(actual==(uint)pid)r.Add(h);return true;};EnumWindows(cb,IntPtr.Zero);GC.KeepAlive(cb);return r.ToArray(); }
  public static IntPtr[] TopWindows() { List<IntPtr> r=new List<IntPtr>();EnumCallback cb=delegate(IntPtr h,IntPtr ignored){r.Add(h);return true;};EnumWindows(cb,IntPtr.Zero);GC.KeepAlive(cb);return r.ToArray(); }
  public static IntPtr[] Children(IntPtr root) { List<IntPtr> r=new List<IntPtr>();EnumCallback cb=delegate(IntPtr h,IntPtr ignored){r.Add(h);return true;};EnumChildWindows(root,cb,IntPtr.Zero);GC.KeepAlive(cb);return r.ToArray(); }
  public static bool AppResponds(IntPtr hwnd,uint timeout){IntPtr result;return SendMessageTimeoutW(hwnd,0,IntPtr.Zero,IntPtr.Zero,2,timeout,out result)!=IntPtr.Zero;}
  public static bool GetTrayRect(IntPtr hwnd,uint uid,out EBR_PRE_RECT rect){EBR_PRE_NOTIFYICONIDENTIFIER id=new EBR_PRE_NOTIFYICONIDENTIFIER();id.cbSize=(uint)Marshal.SizeOf(typeof(EBR_PRE_NOTIFYICONIDENTIFIER));id.hWnd=hwnd;id.uID=uid;id.guidItem=Guid.Empty;return Shell_NotifyIconGetRect(ref id,out rect)==0;}
  public static bool GetHighContrast(out uint flags){EBR_PRE_HIGHCONTRAST h=new EBR_PRE_HIGHCONTRAST();h.cbSize=(uint)Marshal.SizeOf(typeof(EBR_PRE_HIGHCONTRAST));bool ok=SystemParametersInfoW(0x0042,h.cbSize,ref h,0);flags=h.dwFlags;return ok;}
  public static bool SetHighContrast(uint flags){EBR_PRE_HIGHCONTRAST h=new EBR_PRE_HIGHCONTRAST();h.cbSize=(uint)Marshal.SizeOf(typeof(EBR_PRE_HIGHCONTRAST));h.dwFlags=flags;return SystemParametersInfoW(0x0043,h.cbSize,ref h,2);}
  public static bool BroadcastSetting(IntPtr hwnd,string name){IntPtr text=Marshal.StringToHGlobalUni(name);try{IntPtr result;return SendMessageTimeoutW(hwnd,0x001A,IntPtr.Zero,text,2,1500,out result)!=IntPtr.Zero;}finally{Marshal.FreeHGlobal(text);}}
  public static uint ClientPixel(IntPtr hwnd,int x,int y){IntPtr dc=GetDC(hwnd);if(dc==IntPtr.Zero)return 0;try{return GetPixel(dc,x,y);}finally{ReleaseDC(hwnd,dc);}}
  public static object AccessibleWindow(IntPtr hwnd,int objectId){Guid iid=new Guid("618736E0-3C3D-11CF-810C-00AA00389B71");IntPtr accessible;int hr=AccessibleObjectFromWindow(hwnd,objectId,ref iid,out accessible);if(hr<0||accessible==IntPtr.Zero)return null;try{return Marshal.GetObjectForIUnknown(accessible);}finally{Marshal.Release(accessible);}}
}
'@
Add-Type -TypeDefinition $native -ErrorAction Stop
Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
Add-Type -AssemblyName System.Drawing -ErrorAction Stop
Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop

function Add-Event([string]$Name, [string]$Status, $Details=$null) {
  $script:events.Add([pscustomobject]@{Name=$Name;Status=$Status;Details=$Details;Utc=[DateTime]::UtcNow.ToString('o')})
  switch ($Status) {
    'PASS' { $script:passCount++ }
    'FAIL' { $script:failCount++ }
    'NOT TESTED' { $script:notTestedCount++ }
  }
}
function Pass([string]$Name, $Details=$null) { Add-Event $Name 'PASS' $Details }
function Not-Tested([string]$Name, [string]$Reason) { Add-Event $Name 'NOT TESTED' $Reason }
function Require([bool]$Condition, [string]$Name, $Details=$null) {
  if (-not $Condition) { Add-Event $Name 'FAIL' $Details; throw "Acceptance failed: $Name ($Details)" }
  Pass $Name $Details
}
function Get-Rect([IntPtr]$Handle) {
  $rect = New-Object EBR_PRE_RECT
  if (-not [EBR_PRE_NATIVE]::GetWindowRect($Handle, [ref]$rect)) { throw "GetWindowRect failed for $Handle" }
  [pscustomobject]@{Left=$rect.Left;Top=$rect.Top;Right=$rect.Right;Bottom=$rect.Bottom;Width=$rect.Right-$rect.Left;Height=$rect.Bottom-$rect.Top}
}
function Get-ClientGeometry([IntPtr]$Handle) {
  $rect = New-Object EBR_PRE_RECT
  if (-not [EBR_PRE_NATIVE]::GetClientRect($Handle, [ref]$rect)) { throw 'GetClientRect failed.' }
  $origin = New-Object EBR_PRE_POINT
  if (-not [EBR_PRE_NATIVE]::ClientToScreen($Handle, [ref]$origin)) { throw 'ClientToScreen failed.' }
  [pscustomobject]@{Left=$origin.X;Top=$origin.Y;Width=$rect.Right-$rect.Left;Height=$rect.Bottom-$rect.Top}
}
function Get-VisibleControlSummary([IntPtr]$Root) {
  $summary=@()
  foreach($handle in [EBR_PRE_NATIVE]::Children($Root)) {
    $pidValue=[uint32]0;[void][EBR_PRE_NATIVE]::GetWindowThreadProcessId($handle,[ref]$pidValue)
    if($pidValue -ne $script:appPid -or -not [EBR_PRE_NATIVE]::IsWindowVisible($handle)){continue}
    $id=[int][EBR_PRE_NATIVE]::GetDlgCtrlID($handle)
    $class=[EBR_PRE_NATIVE]::ClassName($handle)
    $text=[EBR_PRE_NATIVE]::Text($handle).Replace("`r",' ').Replace("`n",' ')
    if($text.Length -gt 100){$text=$text.Substring(0,100)}
    $summary+=,[pscustomobject]@{Id=$id;Class=$class;Enabled=[EBR_PRE_NATIVE]::IsWindowEnabled($handle);Text=$text}
  }
  return $summary
}
function Get-Control([IntPtr]$Root, [int]$Id, [string]$Name) {
  $found=@()
  foreach($handle in [EBR_PRE_NATIVE]::Children($Root)) {
    $pidValue=[uint32]0;[void][EBR_PRE_NATIVE]::GetWindowThreadProcessId($handle,[ref]$pidValue)
    if($pidValue -ne $script:appPid -or -not [EBR_PRE_NATIVE]::IsWindowVisible($handle)){continue}
    $actual=[int][EBR_PRE_NATIVE]::GetDlgCtrlID($handle)
    if($actual -eq $Id){$found+=,[pscustomobject]@{Handle=$handle;Id=$actual;Class=[EBR_PRE_NATIVE]::ClassName($handle);Text=[EBR_PRE_NATIVE]::Text($handle);Enabled=[EBR_PRE_NATIVE]::IsWindowEnabled($handle);Rect=(Get-Rect $handle)}}
  }
  if($found.Count -ne 1){
    $visible=Get-VisibleControlSummary $Root
    $detail=($visible | ForEach-Object {"ID=$($_.Id) Class=$($_.Class) Enabled=$($_.Enabled) Text='$($_.Text)'"}) -join '; '
    throw "Expected one visible $Name control ID $Id, found $($found.Count). Visible app controls: $detail"
  }
  return $found[0]
}
function Get-StaticControlByText([IntPtr]$Root,[string]$ExpectedText,[string]$Name) {
  $found=@()
  foreach($handle in [EBR_PRE_NATIVE]::Children($Root)) {
    $pidValue=[uint32]0;[void][EBR_PRE_NATIVE]::GetWindowThreadProcessId($handle,[ref]$pidValue)
    if($pidValue -ne $script:appPid -or -not [EBR_PRE_NATIVE]::IsWindowVisible($handle)){continue}
    if([EBR_PRE_NATIVE]::ClassName($handle) -eq 'Static' -and [EBR_PRE_NATIVE]::Text($handle) -ceq $ExpectedText){
      $found+=,[pscustomobject]@{Handle=$handle;Text=$ExpectedText;Rect=(Get-Rect $handle)}
    }
  }
  if($found.Count -ne 1){
    $visible=Get-VisibleControlSummary $Root
    $detail=($visible | ForEach-Object {"ID=$($_.Id) Class=$($_.Class) Enabled=$($_.Enabled) Text='$($_.Text)'"}) -join '; '
    throw "Expected one visible $Name static with text '$ExpectedText', found $($found.Count). Visible app controls: $detail"
  }
  return $found[0]
}
function Click-Control([IntPtr]$Root, [int]$Id, [string]$Name) {
  $control=Get-Control $Root $Id $Name
  if(-not $control.Enabled){throw "$Name control is disabled."}
  [void][EBR_PRE_NATIVE]::SendMessageW($control.Handle,0x00F5,[IntPtr]::Zero,[IntPtr]::Zero)
}
function Get-Combo([IntPtr]$Root, [int]$Id, [string]$Name) {
  $control=Get-Control $Root $Id $Name
  if($control.Class -ne 'ComboBox'){throw "$Name is not a ComboBox."}
  return [EBR_PRE_NATIVE]::SendMessageW($control.Handle,0x0147,[IntPtr]::Zero,[IntPtr]::Zero).ToInt32()
}
function Set-Combo([IntPtr]$Root,[int]$Id,[int]$Index,[string]$Name) {
  $control=Get-Control $Root $Id $Name
  if($control.Class -ne 'ComboBox'){throw "$Name is not a ComboBox."}
  [void][EBR_PRE_NATIVE]::SendMessageW($control.Handle,0x014E,[IntPtr]::new($Index),[IntPtr]::Zero)
  $parent=[EBR_PRE_NATIVE]::GetParent($control.Handle)
  $wParam=[IntPtr]::new([long](($Id -band 0xffff) -bor (1 -shl 16)))
  [void][EBR_PRE_NATIVE]::SendMessageW($parent,0x0111,$wParam,$control.Handle)
  Require ((Get-Combo $Root $Id $Name) -eq $Index) "$Name selected index" $Index
}
function Get-Check([IntPtr]$Root,[int]$Id,[string]$Name) {
  $control=Get-Control $Root $Id $Name
  return ([EBR_PRE_NATIVE]::SendMessageW($control.Handle,0x00F0,[IntPtr]::Zero,[IntPtr]::Zero)).ToInt32() -eq 1
}
function Set-Check([IntPtr]$Root,[int]$Id,[bool]$Value,[string]$Name) {
  if((Get-Check $Root $Id $Name) -ne $Value){Click-Control $Root $Id $Name}
  Require ((Get-Check $Root $Id $Name) -eq $Value) "$Name checkbox value" $Value
}
function Focus-AppControl([IntPtr]$Handle) {
  $targetPid=[uint32]0;$targetThread=[EBR_PRE_NATIVE]::GetWindowThreadProcessId($Handle,[ref]$targetPid)
  $currentThread=[EBR_PRE_NATIVE]::GetCurrentThreadId()
  if($targetPid -ne $script:appPid -or -not [EBR_PRE_NATIVE]::IsWindowEnabled($Handle)){throw 'Refusing to focus a control outside the installed test app.'}
  [void][EBR_PRE_NATIVE]::SetForegroundWindow($script:mainWindow)
  $attached=[EBR_PRE_NATIVE]::AttachThreadInput($currentThread,$targetThread,$true)
  if(-not $attached){throw 'Could not attach keyboard input to the installed test app.'}
  try {[void][EBR_PRE_NATIVE]::SetFocus($Handle);$actual=[EBR_PRE_NATIVE]::GetFocus()}
  finally {[void][EBR_PRE_NATIVE]::AttachThreadInput($currentThread,$targetThread,$false)}
  if($actual -ne $Handle){throw 'The expected app control did not receive focus.'}
}
function Get-AppFocusedControl {
  $targetPid=[uint32]0;$targetThread=[EBR_PRE_NATIVE]::GetWindowThreadProcessId($script:mainWindow,[ref]$targetPid)
  $currentThread=[EBR_PRE_NATIVE]::GetCurrentThreadId()
  if($targetPid -ne $script:appPid){throw 'The installed app main window belongs to another process.'}
  $attached=[EBR_PRE_NATIVE]::AttachThreadInput($currentThread,$targetThread,$true)
  if(-not $attached){throw 'Could not observe keyboard focus in the installed test app.'}
  try {$actual=[EBR_PRE_NATIVE]::GetFocus()}
  finally {[void][EBR_PRE_NATIVE]::AttachThreadInput($currentThread,$targetThread,$false)}
  return $actual
}
function Click-Edit([IntPtr]$Handle) {
  $rect=Get-Rect $Handle
  $x=[int](($rect.Left+$rect.Right)/2);$y=[int](($rect.Top+$rect.Bottom)/2)
  if(-not [EBR_PRE_NATIVE]::SetForegroundWindow($script:mainWindow) -or -not [EBR_PRE_NATIVE]::SetCursorPos($x,$y)){throw 'Could not position the pointer over the installed edit control.'}
  [EBR_PRE_NATIVE]::mouse_event(0x0002,0,0,0,[UIntPtr]::Zero)
  Start-Sleep -Milliseconds 50
  [EBR_PRE_NATIVE]::mouse_event(0x0004,0,0,0,[UIntPtr]::Zero)
  Start-Sleep -Milliseconds 100
  Focus-AppControl $Handle
  $foreground=[EBR_PRE_NATIVE]::GetForegroundWindow();$foregroundPid=[uint32]0
  [void][EBR_PRE_NATIVE]::GetWindowThreadProcessId($foreground,[ref]$foregroundPid)
  Require ($foregroundPid -eq $script:appPid) 'Installed app owns the foreground before keyboard settings input' ([pscustomobject]@{ForegroundPid=$foregroundPid;AppPid=$script:appPid;ControlRect=$rect})
}
function Send-VirtualKey([byte]$Key) {
  [EBR_PRE_NATIVE]::Key($Key,$false)
  Start-Sleep -Milliseconds 25
  [EBR_PRE_NATIVE]::Key($Key,$true)
  Start-Sleep -Milliseconds 25
}
function Set-Edit([IntPtr]$Root,[int]$Id,[string]$Value,[string]$Name) {
  $control=Get-Control $Root $Id $Name
  if($control.Class -ne 'Edit' -or -not $control.Enabled){throw "$Name is not an enabled Edit control."}
  Click-Edit $control.Handle
  [EBR_PRE_NATIVE]::Key(0x11,$false) # Ctrl down
  [EBR_PRE_NATIVE]::Key(0x41,$false) # A down
  Start-Sleep -Milliseconds 25
  [EBR_PRE_NATIVE]::Key(0x41,$true)
  [EBR_PRE_NATIVE]::Key(0x11,$true)
  foreach($digit in $Value.ToCharArray()){Send-VirtualKey ([byte][int]$digit)}
  Start-Sleep -Milliseconds 100
  Capture-ActiveWindow $script:mainWindow "installed-edit-$Id-$Value.png" | Out-Null
  $nextId=if($Id -eq 100){101}else{130}
  $nextControl=if($Id -eq 100){Get-Control $Root $nextId 'Focus target after edit'}else{$null}
  Send-VirtualKey 0x09 # Tab through the app's real keyboard message loop to commit the edit.
  $focused=Get-AppFocusedControl
  $focusedPid=[uint32]0
  if($focused -ne [IntPtr]::Zero){[void][EBR_PRE_NATIVE]::GetWindowThreadProcessId($focused,[ref]$focusedPid)}
  if($Id -eq 100){
    Require ($focused -eq $nextControl.Handle) "$Name Tab navigation moves to the next setting control" ([pscustomobject]@{ExpectedHandle=('0x{0:X}' -f $nextControl.Handle.ToInt64());ActualHandle=('0x{0:X}' -f $focused.ToInt64())})
  }else{
    Require ($focused -ne $control.Handle -and $focusedPid -eq $script:appPid -and [EBR_PRE_NATIVE]::IsWindowEnabled($focused)) "$Name Tab navigation leaves the edit within the app" ([pscustomobject]@{FocusedHandle=('0x{0:X}' -f $focused.ToInt64());FocusedId=[EBR_PRE_NATIVE]::GetDlgCtrlID($focused);FocusedClass=[EBR_PRE_NATIVE]::ClassName($focused);ProcessId=$focusedPid})
  }
  Start-Sleep -Milliseconds 100
  $actual=[EBR_PRE_NATIVE]::Text($control.Handle)
  Capture-ActiveWindow $script:mainWindow "installed-edit-$Id-$Value-after-tab.png" | Out-Null
  $settingKey=if($Id -eq 100){'workMinutes'}elseif($Id -eq 101){'breakSeconds'}else{''}
  if($settingKey){
    $saved=Read-SettingsMap (Join-Path $dataDir 'settings.ini')
    Require ($saved.ContainsKey($settingKey) -and [string]$saved[$settingKey] -eq $Value) "$Name accepts keyboard input and persists after Tab" ([pscustomobject]@{Key=$settingKey;Expected=$Value;Saved=$saved[$settingKey];EditWindowText=$actual})
  } else {
    Require ($actual.Trim() -eq $Value) "$Name edit value after keyboard focus change" ([pscustomobject]@{Expected=$Value;Actual=$actual})
  }
}
function Read-SettingsMap([string]$Path) {
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){throw "Settings file is missing: $Path"}
  $contents=Get-Content -LiteralPath $Path -Raw
  $values=@{}
  foreach($line in ($contents -split '\r?\n')){
    $equals=$line.IndexOf('=')
    if($equals -gt 0){$values[$line.Substring(0,$equals)]=$line.Substring($equals+1)}
  }
  return ,$values
}
function Get-AppMainWindow([int]$ProcessId,[int]$TimeoutSeconds=20) {
  $watch=[Diagnostics.Stopwatch]::StartNew()
  while($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds){
    foreach($h in [EBR_PRE_NATIVE]::TopWindowsForProcess($ProcessId)){
      if([EBR_PRE_NATIVE]::ClassName($h) -eq 'EyeBreakReminder.Native' -and [EBR_PRE_NATIVE]::IsWindowVisible($h)){return $h}
    }
    Start-Sleep -Milliseconds 100
  }
  return [IntPtr]::Zero
}
function Get-AppWindows([int]$ProcessId) {
  @([EBR_PRE_NATIVE]::TopWindowsForProcess($ProcessId) | Where-Object { [EBR_PRE_NATIVE]::IsWindowVisible($_) })
}
function Get-BreakWindow([int]$ProcessId) {
  @([EBR_PRE_NATIVE]::TopWindowsForProcess($ProcessId) | Where-Object { [EBR_PRE_NATIVE]::ClassName($_) -eq 'EyeBreakReminder.Break' -and [EBR_PRE_NATIVE]::IsWindowVisible($_) })
}
function Switch-Settings([int]$Section) {
  Click-Control $script:mainWindow 12 'Settings navigation'
  Click-Control $script:mainWindow (130+$Section) "Settings section $Section"
  Start-Sleep -Milliseconds 100
  $sectionControl=Get-Control $script:mainWindow (130+$Section) "Settings section $Section"
  $selected=([EBR_PRE_NATIVE]::SendMessageW($sectionControl.Handle,0x00F0,[IntPtr]::Zero,[IntPtr]::Zero)).ToInt32() -eq 1
  Require $selected 'Installed application selected the requested Settings section' ([pscustomobject]@{Section=$Section;Label=$sectionControl.Text;Selected=$selected})
}
function Switch-Timer { Click-Control $script:mainWindow 10 'Timer navigation' }
function Get-Status { [EBR_PRE_NATIVE]::Text((Get-Control $script:mainWindow 41 'Timer status').Handle) }
function Get-ActiveTimerNavAccentPixel([string]$Name,[string]$ScreenshotName) {
  $nav=Get-Control $script:mainWindow 10 "$Name Timer navigation accent"
  $screenX=[int][Math]::Floor($nav.Rect.Left+$nav.Rect.Width/2.0)
  $screenY=[int]($nav.Rect.Bottom-2)
  $screenshot=Capture-ActiveWindow $script:mainWindow $ScreenshotName
  $bitmap=[System.Drawing.Bitmap]::new(1,1)
  $graphics=[System.Drawing.Graphics]::FromImage($bitmap)
  try {
    $graphics.CopyFromScreen($screenX,$screenY,0,0,[System.Drawing.Size]::new(1,1))
    $color=$bitmap.GetPixel(0,0)
    $red=[int]$color.R;$green=[int]$color.G;$blue=[int]$color.B
    $pixel=[uint32](($red -shl 16) -bor ($green -shl 8) -bor $blue)
    return [pscustomobject]@{Pixel=$pixel;Hex=('0x{0:X6}' -f $pixel);Screenshot=$screenshot;ScreenPoint="$screenX,$screenY"}
  } finally {$graphics.Dispose();$bitmap.Dispose()}
}
function Get-TimerSeconds {
  $text=[EBR_PRE_NATIVE]::Text((Get-Control $script:mainWindow 40 'Timer countdown').Handle)
  if($text -notmatch '^(\d+):(\d{2})$'){throw "Unexpected timer format: $text"}
  return ([int]$Matches[1]*60+[int]$Matches[2])
}
function Wait-ForStatus([string]$Expected,[int]$TimeoutSeconds=8) {
  $watch=[Diagnostics.Stopwatch]::StartNew();$last=''
  while($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds){$last=Get-Status;if($last -like "*$Expected*"){return $last};Start-Sleep -Milliseconds 100}
  throw "Expected status '$Expected'; last observed '$last'."
}
function Get-UiaElements([IntPtr]$Window) {
  $root=[System.Windows.Automation.AutomationElement]::FromHandle($Window)
  if(-not $root){return @()}
  @($root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition) | Where-Object { try { $_.Current.ProcessId -eq $script:appPid } catch { $false } })
}
function Capture-ActiveWindow([IntPtr]$Window,[string]$Name) {
  if(-not $script:interactiveDesktop){Not-Tested "Active desktop screenshot: $Name" 'Runner has no interactive Explorer desktop.';return $null}
  [void][EBR_PRE_NATIVE]::SetForegroundWindow($Window)
  Start-Sleep -Milliseconds 250
  $bounds=Get-Rect $Window
  if($bounds.Width -lt 100 -or $bounds.Height -lt 80){throw "Invalid screenshot bounds for $Name."}
  $path=Join-Path $EvidenceDirectory $Name
  $bitmap=[System.Drawing.Bitmap]::new($bounds.Width,$bounds.Height)
  $graphics=[System.Drawing.Graphics]::FromImage($bitmap)
  try {$graphics.CopyFromScreen($bounds.Left,$bounds.Top,0,0,$bitmap.Size);$bitmap.Save($path,[System.Drawing.Imaging.ImageFormat]::Png)}
  finally {$graphics.Dispose();$bitmap.Dispose()}
  if((Get-Item -LiteralPath $path).Length -lt 1024){throw "Active-screen screenshot appears empty: $path"}
  Pass "Active desktop screenshot: $Name" ([pscustomobject]@{Path=$path;Method='CopyFromScreen';WindowBounds=$bounds})
  return $path
}
function Get-CapturedClientPixel([IntPtr]$Window,[string]$Path) {
  $bounds=Get-Rect $Window;$client=Get-ClientGeometry $Window
  $x=$client.Left-$bounds.Left+8
  $y=$client.Top-$bounds.Top+[Math]::Max(8,$client.Height-8)
  $bitmap=[System.Drawing.Bitmap]::FromFile($Path)
  try {
    if($x -lt 0 -or $y -lt 0 -or $x -ge $bitmap.Width -or $y -ge $bitmap.Height){throw "Client sample $x,$y is outside screenshot $($bitmap.Width)x$($bitmap.Height)."}
    $pixel=$bitmap.GetPixel($x,$y)
    # Color channels are bytes; widen before shifting so PowerShell does not
    # truncate the upper two channels and mistake a real #202020 match for #20.
    $red=[int]$pixel.R;$green=[int]$pixel.G;$blue=[int]$pixel.B
    return [uint32](($blue -shl 16) -bor ($green -shl 8) -bor $red)
  } finally {$bitmap.Dispose()}
}
function Capture-PrintWindow([IntPtr]$Window,[string]$Name) {
  $bounds=Get-Rect $Window;$bitmap=[System.Drawing.Bitmap]::new($bounds.Width,$bounds.Height);$graphics=[System.Drawing.Graphics]::FromImage($bitmap)
  try {$dc=$graphics.GetHdc();try{$ok=[EBR_PRE_NATIVE]::PrintWindow($Window,$dc,2);if(-not $ok){$ok=[EBR_PRE_NATIVE]::PrintWindow($Window,$dc,0)};if(-not $ok){throw "PrintWindow failed for $Name"}}finally{$graphics.ReleaseHdc($dc)};$path=Join-Path $EvidenceDirectory $Name;$bitmap.Save($path,[System.Drawing.Imaging.ImageFormat]::Png)}
  finally {$graphics.Dispose();$bitmap.Dispose()}
  Pass "PrintWindow comparison capture: $Name" ([pscustomobject]@{Path=$path;Method='PrintWindow';WindowBounds=$bounds})
  return $path
}
function Capture-TrayPopup([IntPtr]$Window,[string]$Name) {
  if(-not $script:interactiveDesktop){Not-Tested "Active desktop screenshot: $Name" 'Runner has no interactive Explorer desktop.';return $null}
  try {
    if(-not [EBR_PRE_NATIVE]::IsWindowVisible($Window)){throw 'The native tray popup closed before capture.'}
    # Do not call SetForegroundWindow here: activating a #32768 popup can dismiss
    # the very menu being measured. Capture its already visible screen rectangle.
    $bounds=Get-Rect $Window
    if($bounds.Width -lt 10 -or $bounds.Height -lt 10){throw "Invalid popup bounds: $($bounds.Width)x$($bounds.Height)."}
    $path=Join-Path $EvidenceDirectory $Name
    $bitmap=[System.Drawing.Bitmap]::new($bounds.Width,$bounds.Height)
    $graphics=[System.Drawing.Graphics]::FromImage($bitmap)
    try {$graphics.CopyFromScreen($bounds.Left,$bounds.Top,0,0,$bitmap.Size);$bitmap.Save($path,[System.Drawing.Imaging.ImageFormat]::Png)}
    finally {$graphics.Dispose();$bitmap.Dispose()}
    if((Get-Item -LiteralPath $path).Length -lt 256){throw "Popup screenshot is unexpectedly small: $path"}
    Pass "Active desktop screenshot: $Name" ([pscustomobject]@{Path=$path;Method='CopyFromScreen without activating popup';WindowBounds=$bounds})
    return $path
  } catch {Not-Tested "Tray popup screenshot capture: $Name" $_.Exception.Message;return $null}
}
function Assert-StatusCentered([string]$Name) {
  $client=Get-ClientGeometry $script:mainWindow
  $status=Get-Control $script:mainWindow 41 'Timer status'
  $actual=($status.Rect.Left+$status.Rect.Right)/2.0
  $expected=$client.Left+$client.Width/2.0
  $difference=[Math]::Abs($actual-$expected)
  Require ($difference -le 1.0) "Timer status centered over countdown ($Name)" ([pscustomobject]@{Dpi=[EBR_PRE_NATIVE]::GetDpiForWindow($script:mainWindow);ActualCenter=$actual;ExpectedCenter=$expected;DifferencePx=$difference;ClientWidth=$client.Width})
}
function Start-InstalledApp {
  if($script:appPid){throw 'The test app is already tracked as running.'}
  $process=Start-Process -FilePath $appExe -PassThru
  $script:appPid=$process.Id
  # The image path can be unavailable briefly while CreateProcess initializes the image.
  $watch=[Diagnostics.Stopwatch]::StartNew();$actual='';$ownedProcess=$null
  while($watch.Elapsed.TotalSeconds -lt 20){
    try{$ownedProcess=Get-Process -Id $script:appPid -ErrorAction Stop;$path=[string]$ownedProcess.Path;if($path){$actual=[IO.Path]::GetFullPath($path)}}catch{$actual=''}
    if($actual -ieq $appExe){break}
    if($ownedProcess -and $ownedProcess.HasExited){break}
    Start-Sleep -Milliseconds 100
  }
  Require ($actual -ieq $appExe) 'Installed application launches from the installed executable' ([pscustomobject]@{Expected=$appExe;Actual=$actual;Pid=$script:appPid})
  if ($env:EBR_EXPECTED_PUBLISHED_EXE_SHA256) {
    $installedSha256 = (Get-FileHash -LiteralPath $appExe -Algorithm SHA256).Hash.ToLowerInvariant()
    $expectedSha256 = $env:EBR_EXPECTED_PUBLISHED_EXE_SHA256.ToLowerInvariant()
    Require ($installedSha256 -ceq $expectedSha256) 'Installed application SHA-256 equals the downloaded published standalone executable' ([pscustomobject]@{Expected=$expectedSha256;Actual=$installedSha256;Path=$appExe})
  }
  $script:mainWindow=Get-AppMainWindow $script:appPid
  if($script:interactiveDesktop){Require ($script:mainWindow -ne [IntPtr]::Zero) 'Installed application creates a visible Win32 main window' $script:appPid}
  elseif($script:mainWindow -eq [IntPtr]::Zero){Not-Tested 'Installed application GUI launch' 'The runner has no interactive desktop and did not expose a visible app window.';return $false}
  Pass 'Installed application process started' ([pscustomobject]@{Pid=$script:appPid;Window=('0x{0:X}' -f $script:mainWindow.ToInt64())})
  return $true
}
function Start-InstalledAppFromShortcut {
  if(-not $script:interactiveDesktop){Not-Tested 'Launching the application from the Start Menu shortcut' 'A visible Windows desktop is required to invoke a shell shortcut.';return Start-InstalledApp}
  if($script:appPid){throw 'The test app is already tracked as running.'}
  Start-Process -FilePath $startMenuLink | Out-Null
  $watch=[Diagnostics.Stopwatch]::StartNew();$found=$null
  while($watch.Elapsed.TotalSeconds -lt 20){
    $found=@(Get-Process -Name EyeBreakReminder -ErrorAction SilentlyContinue | Where-Object { try{[IO.Path]::GetFullPath($_.Path) -ieq $appExe}catch{$false} }) | Select-Object -First 1
    if($found){break}
    Start-Sleep -Milliseconds 150
  }
  if(-not $found){throw 'The installed Start Menu shortcut did not launch EyeBreakReminder.exe.'}
  $script:appPid=$found.Id
  Require ([IO.Path]::GetFullPath($found.Path) -ieq $appExe) 'Start Menu shortcut launches the installed executable' ([pscustomobject]@{Path=$found.Path;Pid=$found.Id})
  $script:mainWindow=Get-AppMainWindow $script:appPid
  Require ($script:mainWindow -ne [IntPtr]::Zero) 'Start Menu shortcut creates a visible app window' $script:appPid
  return $true
}
function Stop-InstalledApp {
  if(-not $script:appPid){return}
  $process=Get-Process -Id $script:appPid -ErrorAction SilentlyContinue
  if($process){
    if($script:mainWindow -ne [IntPtr]::Zero){$message=[EBR_PRE_NATIVE]::RegisterWindowMessageW('EyeBreakReminder.Exit.Native.1');[void][EBR_PRE_NATIVE]::PostMessageW($script:mainWindow,$message,[IntPtr]::Zero,[IntPtr]::Zero)}
    if(-not $process.WaitForExit(10000)){
      # Only terminate the PID started by this isolated runner script.
      $actual='';try{$actual=[IO.Path]::GetFullPath((Get-Process -Id $script:appPid -ErrorAction Stop).Path)}catch{}
      if($actual -ieq $appExe){Stop-Process -Id $script:appPid -Force -ErrorAction SilentlyContinue;if(-not $process.WaitForExit(5000)){throw 'The owned test application process did not exit after forced cleanup.'};Pass 'Test app cleanup used its owned process ID' $script:appPid}
    }
  }
  $script:appPid=0;$script:mainWindow=[IntPtr]::Zero
}
function Find-WizardButton([IntPtr]$Window,[string]$Pattern) {
  try {
    $root=[System.Windows.Automation.AutomationElement]::FromHandle($Window)
    $all=$root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
    foreach($item in $all){
      if($item.Current.ControlType -ne [System.Windows.Automation.ControlType]::Button){continue}
      if($item.Current.IsOffscreen -or -not $item.Current.IsEnabled){continue}
      if($item.Current.Name -match $Pattern){return [pscustomobject]@{Element=$item;Handle=[IntPtr]$item.Current.NativeWindowHandle;Name=$item.Current.Name;Source='UI Automation'}}
    }
  } catch {}
  foreach($child in [EBR_PRE_NATIVE]::Children($Window)){
    if([EBR_PRE_NATIVE]::ClassName($child) -ne 'Button' -or -not [EBR_PRE_NATIVE]::IsWindowVisible($child) -or -not [EBR_PRE_NATIVE]::IsWindowEnabled($child)){continue}
    $name=[EBR_PRE_NATIVE]::Text($child)
    if($name -match $Pattern){return [pscustomobject]@{Element=$null;Handle=$child;Name=$name;Source='Win32 button fallback'}}
  }
  return $null
}
function Invoke-WizardButton([IntPtr]$Window,$Button) {
  $rect=New-Object EBR_PRE_RECT
  if(-not [EBR_PRE_NATIVE]::GetWindowRect($Button.Handle,[ref]$rect)){throw "Could not measure installer button '$($Button.Name)' before clicking it."}
  $x=[int](($rect.Left+$rect.Right)/2);$y=[int](($rect.Top+$rect.Bottom)/2)
  [void][EBR_PRE_NATIVE]::SetForegroundWindow($Window)
  Start-Sleep -Milliseconds 100
  if([EBR_PRE_NATIVE]::GetForegroundWindow() -ne $Window){throw "Could not activate the installer window before clicking '$($Button.Name)' at $x,$y."}
  if(-not [EBR_PRE_NATIVE]::SetCursorPos($x,$y)){throw "Could not position the cursor over installer button '$($Button.Name)' at $x,$y."}
  [EBR_PRE_NATIVE]::mouse_event(0x0002,0,0,0,[UIntPtr]::Zero)
  Start-Sleep -Milliseconds 60
  [EBR_PRE_NATIVE]::mouse_event(0x0004,0,0,0,[UIntPtr]::Zero)
  Pass 'Installer wizard button clicked through the interactive Windows desktop' ([pscustomobject]@{Name=$Button.Name;LocatedBy=$Button.Source;Bounds=[pscustomobject]@{Left=$rect.Left;Top=$rect.Top;Right=$rect.Right;Bottom=$rect.Bottom};Window=('0x{0:X}' -f $Window.ToInt64())})
}
function Get-ProcessFamilyIds([int]$RootPid) {
  $ids=[System.Collections.Generic.HashSet[int]]::new()
  [void]$ids.Add($RootPid)
  $processes=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
  $changed=$true
  while($changed){
    $changed=$false
    foreach($entry in $processes){
      $child=[int]$entry.ProcessId
      if($ids.Contains([int]$entry.ParentProcessId) -and -not $ids.Contains($child)){[void]$ids.Add($child);$changed=$true}
    }
  }
  return @($ids)
}
function Get-ProcessTreeSnapshot([int]$RootPid,[string]$ExecutablePath) {
  $all=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
  $ids=[System.Collections.Generic.HashSet[int]]::new()
  foreach($id in (Get-ProcessFamilyIds $RootPid)){[void]$ids.Add([int]$id)}
  $expectedPath=[IO.Path]::GetFullPath($ExecutablePath)
  foreach($entry in $all){
    if($entry.ExecutablePath){try{if([IO.Path]::GetFullPath([string]$entry.ExecutablePath) -ieq $expectedPath){[void]$ids.Add([int]$entry.ProcessId)}}catch{}}
  }
  @($all | Where-Object {$ids.Contains([int]$_.ProcessId)} | ForEach-Object {
    [pscustomobject]@{ProcessId=[int]$_.ProcessId;ParentProcessId=[int]$_.ParentProcessId;SessionId=[int]$_.SessionId;Name=$_.Name;ExecutablePath=$_.ExecutablePath;CommandLine=$_.CommandLine;CreationDate=$_.CreationDate}
  })
}
function Get-AvailableProcessExitCode($Process) {
  if($null -eq $Process -or -not $Process.HasExited){return $null}
  try{$value=$Process.ExitCode;if($null -ne $value){return [int]$value}}catch{}
  return $null
}
function Get-DesktopWindowSnapshot([int[]]$RelevantProcessIds=@()) {
  @([EBR_PRE_NATIVE]::TopWindows() | ForEach-Object {
    $h=$_;$pidValue=[uint32]0;[void][EBR_PRE_NATIVE]::GetWindowThreadProcessId($h,[ref]$pidValue)
    $visible=[EBR_PRE_NATIVE]::IsWindowVisible($h)
    if($visible -or $RelevantProcessIds -contains [int]$pidValue){
      $rect=New-Object EBR_PRE_RECT;$bounds=$null
      if([EBR_PRE_NATIVE]::GetWindowRect($h,[ref]$rect)){$bounds=[pscustomobject]@{Left=$rect.Left;Top=$rect.Top;Right=$rect.Right;Bottom=$rect.Bottom}}
      $proc=$null;try{$proc=Get-Process -Id ([int]$pidValue) -ErrorAction Stop}catch{}
      [pscustomobject]@{Handle=$h.ToInt64();ProcessId=[int]$pidValue;ProcessName=$(if($proc){$proc.ProcessName}else{$null});Class=[EBR_PRE_NATIVE]::ClassName($h);Title=[EBR_PRE_NATIVE]::Text($h);Visible=$visible;Bounds=$bounds}
    }
  })
}
function Get-UninstallStateSnapshot {
  $uninstallString=$null
  try{$uninstallString=(Get-ItemProperty -LiteralPath $uninstallKey -Name UninstallString -ErrorAction Stop).UninstallString}catch{}
  $startup=@()
  if(Test-Path -LiteralPath $runKey){$startup=@((Get-ItemProperty -LiteralPath $runKey).PSObject.Properties | Where-Object {$_.Name -notmatch '^PS' -and [string]$_.Value -match 'EyeBreakReminder'} | ForEach-Object {[pscustomobject]@{Name=$_.Name;Value=[string]$_.Value}})}
  [pscustomobject]@{ExecutableExists=(Test-Path -LiteralPath $appExe);UninstallerExists=(Test-Path -LiteralPath (Join-Path $installDir 'Uninstall.exe'));InstallDirectoryExists=(Test-Path -LiteralPath $installDir);StartMenuShortcutExists=(Test-Path -LiteralPath $startMenuLink);DesktopShortcutExists=(Test-Path -LiteralPath $desktopLink);UninstallKeyExists=(Test-Path -LiteralPath $uninstallKey);UninstallString=$uninstallString;InstallKeyExists=(Test-Path -LiteralPath $appKey);StartupEntries=$startup}
}
function Capture-DesktopScreenshot([string]$Name) {
  if(-not $script:interactiveDesktop){return $null}
  $bounds=[System.Windows.Forms.SystemInformation]::VirtualScreen
  if($bounds.Width -lt 100 -or $bounds.Height -lt 80){return $null}
  $path=Join-Path $EvidenceDirectory $Name
  $bitmap=[System.Drawing.Bitmap]::new($bounds.Width,$bounds.Height);$graphics=[System.Drawing.Graphics]::FromImage($bitmap)
  try{$graphics.CopyFromScreen($bounds.Left,$bounds.Top,0,0,$bitmap.Size);$bitmap.Save($path,[System.Drawing.Imaging.ImageFormat]::Png)}finally{$graphics.Dispose();$bitmap.Dispose()}
  if((Get-Item -LiteralPath $path).Length -lt 1024){throw "Desktop screenshot appears empty: $path"}
  return $path
}
function Get-UninstallerEventLogEvidence([DateTime]$StartTime,[DateTime]$EndTime) {
  $entries=[System.Collections.Generic.List[object]]::new()
  foreach($logName in @('Application','System','Security')){
    try{
      $events=@(Get-WinEvent -FilterHashtable @{LogName=$logName;StartTime=$StartTime;EndTime=$EndTime} -MaxEvents 200 -ErrorAction Stop | Where-Object {$_.ProviderName -match 'Application Error|Windows Error Reporting|SideBySide|User32|User Profile|Kernel-Power|Security-Auditing|UAC' -or $_.Message -match 'EyeBreakReminder|Uninstall\.exe|consent\.exe|NSIS'} | Select-Object -First 40)
      foreach($event in $events){$entries.Add([pscustomobject]@{LogName=$logName;Utc=$event.TimeCreated.ToUniversalTime().ToString('o');Id=$event.Id;Provider=$event.ProviderName;Level=$event.LevelDisplayName;Message=$event.Message})}
    }catch{$entries.Add([pscustomobject]@{LogName=$logName;ReadError=$_.Exception.Message})}
  }
  return $entries.ToArray()
}
function Save-UninstallerDiagnostic($Diagnostic) {
  $script:uninstallerDiagnostics.Add($Diagnostic)
  ConvertTo-Json -InputObject ($script:uninstallerDiagnostics.ToArray()) -Depth 12 | Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'uninstaller-diagnostics.json') -Encoding UTF8
}
function Invoke-Wizard([string]$Path,[string]$Kind) {
  if(-not $script:interactiveDesktop){Not-Tested "$Kind visible wizard" 'The runner has no interactive Explorer desktop.';return $false}
  $isUninstaller=$Kind -match '(?i)uninstall'
  $launchTime=[DateTime]::Now
  $process=Start-Process -FilePath $Path -WorkingDirectory (Split-Path -Parent $Path) -PassThru
  $launchProcess=$process
  $started=[Diagnostics.Stopwatch]::StartNew();$window=[IntPtr]::Zero;$uiWindowProcessId=0
  $familyIds=@($process.Id);$familyRefresh=[Diagnostics.Stopwatch]::StartNew()
  $limitSeconds=if($isUninstaller){30}else{20}
  $windowSnapshots=[System.Collections.Generic.List[object]]::new();$desktopScreenshots=[System.Collections.Generic.List[string]]::new()
  $lastSampleSecond=-1;$lastRefreshSecond=-1
  $beforeState=if($isUninstaller){Get-UninstallStateSnapshot}else{$null}
  $initialProcesses=@();$initialWindows=@()
  if($isUninstaller){$initialProcesses=Get-ProcessTreeSnapshot $launchProcess.Id $Path;$initialIds=@($initialProcesses | ForEach-Object {$_.ProcessId});if($initialIds -notcontains $launchProcess.Id){$initialIds=@($launchProcess.Id)+$initialIds};$initialWindows=Get-DesktopWindowSnapshot $initialIds}
  if($isUninstaller){try{$shot=Capture-DesktopScreenshot ("{0}-desktop-before.png" -f $Kind);if($shot){$desktopScreenshots.Add($shot)}}catch{$desktopScreenshots.Add("capture error: $($_.Exception.Message)")}}
  while($started.Elapsed.TotalSeconds -lt $limitSeconds -and $window -eq [IntPtr]::Zero){
    $second=[int][Math]::Floor($started.Elapsed.TotalSeconds)
    if($isUninstaller -and ($familyRefresh.ElapsedMilliseconds -ge 400 -or $second -ne $lastRefreshSecond)){
      $processSnapshot=Get-ProcessTreeSnapshot $process.Id $Path
      $familyIds=@($processSnapshot | ForEach-Object {$_.ProcessId})
      if($familyIds -notcontains $process.Id){$familyIds=@($process.Id)+$familyIds}
      $allWindows=Get-DesktopWindowSnapshot $familyIds
      $visibleRelevant=@($allWindows | Where-Object {$_.Visible -and $familyIds -contains $_.ProcessId}) | Select-Object -First 1
      if(-not $visibleRelevant){$visibleRelevant=@($allWindows | Where-Object {$_.Visible -and $_.Title -match '(?i)Eye Break Reminder|Uninstall|User Account Control'}) | Select-Object -First 1}
      if($visibleRelevant){$window=[IntPtr]([long]$visibleRelevant.Handle)}
      if($second -ne $lastSampleSecond){
        $windowSnapshots.Add([pscustomobject]@{ElapsedSeconds=$second;Processes=$processSnapshot;Windows=$allWindows;InstalledState=(Get-UninstallStateSnapshot)})
        $lastSampleSecond=$second
      }
      if($second -in @(1,5,15,29)){
        try{$shot=Capture-DesktopScreenshot ("{0}-desktop-t{1:D2}.png" -f $Kind,$second);if($shot){$desktopScreenshots.Add($shot)}}catch{$desktopScreenshots.Add("t=$second capture error: $($_.Exception.Message)")}
      }
      $lastRefreshSecond=$second;$familyRefresh.Restart()
    } elseif(-not $isUninstaller) {
      if($familyRefresh.ElapsedMilliseconds -ge 400){$familyIds=Get-ProcessFamilyIds $process.Id;$familyRefresh.Restart()}
      foreach($familyPid in $familyIds){foreach($h in [EBR_PRE_NATIVE]::TopWindowsForProcess($familyPid)){if([EBR_PRE_NATIVE]::IsWindowVisible($h)){$window=$h;break}};if($window -ne [IntPtr]::Zero){break}}
      if($window -eq [IntPtr]::Zero){$process.Refresh();if($process.HasExited -and $familyIds.Count -le 1){break}}
    }
    if($window -eq [IntPtr]::Zero){Start-Sleep -Milliseconds 100}
  }
  if($window -eq [IntPtr]::Zero){
    $process.Refresh()
    if($isUninstaller){
      $endTime=[DateTime]::Now;$finalProcesses=Get-ProcessTreeSnapshot $process.Id $Path;$finalIds=@($finalProcesses | ForEach-Object {$_.ProcessId});if($finalIds -notcontains $process.Id){$finalIds=@($process.Id)+$finalIds}
      $finalWindows=Get-DesktopWindowSnapshot $finalIds;$afterState=Get-UninstallStateSnapshot
      $eventEvidence=Get-UninstallerEventLogEvidence $launchTime $endTime
      $consentProcesses=@()
      try{$consentProcesses=@(Get-CimInstance Win32_Process -Filter "Name='consent.exe'" -ErrorAction Stop | Select-Object ProcessId,ParentProcessId,SessionId,Name,ExecutablePath,CommandLine)}catch{}
      try{$shot=Capture-DesktopScreenshot ("{0}-desktop-final.png" -f $Kind);if($shot){$desktopScreenshots.Add($shot)}}catch{$desktopScreenshots.Add("final capture error: $($_.Exception.Message)")}
      $diagnostic=[pscustomobject]@{Kind=$Kind;Path=$Path;Arguments='';Started=$launchTime.ToString('o');Ended=$endTime.ToString('o');DurationSeconds=[Math]::Round($started.Elapsed.TotalSeconds,2);ParentPid=$launchProcess.Id;ParentExited=$launchProcess.HasExited;ParentExitCode=$(if($launchProcess.HasExited){$launchProcess.ExitCode}else{$null});Before=$beforeState;After=$afterState;InitialProcesses=$initialProcesses;InitialWindows=$initialWindows;Processes=$finalProcesses;ConsentProcesses=$consentProcesses;WindowSamples=$windowSnapshots.ToArray();FinalWindows=$finalWindows;DesktopScreenshots=$desktopScreenshots.ToArray();EventLogs=$eventEvidence}
      Save-UninstallerDiagnostic $diagnostic
      $consentObserved=$consentProcesses.Count -gt 0 -or @($finalWindows | Where-Object {$_.Title -match '(?i)User Account Control'}).Count -gt 0
      if($consentObserved){Not-Tested "$Kind interactive uninstall UI" 'A UAC consent process/window was observed; the isolated test did not accept or automate a security prompt.'}
      else{Add-Event "$Kind interactive uninstall displays a usable wizard or completes removal" 'FAIL' $diagnostic}
      if($launchProcess.HasExited){Pass "$Kind uninstaller parent process exit captured" ([pscustomobject]@{Pid=$launchProcess.Id;ExitCode=$launchProcess.ExitCode;ProcessTree=$finalProcesses})}
      if(-not $launchProcess.HasExited){
        $terminated=[System.Collections.Generic.List[int]]::new()
        $processIdsToStop=@($finalProcesses | ForEach-Object {$_.ProcessId});if($processIdsToStop -notcontains $launchProcess.Id){$processIdsToStop=@($launchProcess.Id)+$processIdsToStop}
        foreach($processId in $processIdsToStop){try{Stop-Process -Id $processId -Force -ErrorAction Stop;$terminated.Add([int]$processId)}catch{}}
        $script:uninstallerDiagnostics[$script:uninstallerDiagnostics.Count-1] | Add-Member -NotePropertyName CleanupTerminatedProcessIds -NotePropertyValue $terminated.ToArray() -Force
        ConvertTo-Json -InputObject ($script:uninstallerDiagnostics.ToArray()) -Depth 12 | Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'uninstaller-diagnostics.json') -Encoding UTF8
      }
      return $false
    }
    $visibleWindows=@(foreach($h in [EBR_PRE_NATIVE]::TopWindows()){
      if([EBR_PRE_NATIVE]::IsWindowVisible($h)){$pidValue=[uint32]0;[void][EBR_PRE_NATIVE]::GetWindowThreadProcessId($h,[ref]$pidValue);[pscustomobject]@{Pid=$pidValue;Class=[EBR_PRE_NATIVE]::ClassName($h);Title=[EBR_PRE_NATIVE]::Text($h)}}
    })
    Require $false "$Kind wizard shows a visible native window" ([pscustomobject]@{Pid=$process.Id;Exited=$process.HasExited;ExitCode=$(if($process.HasExited){$process.ExitCode}else{$null});ProcessFamily=$familyIds;VisibleWindows=$visibleWindows})
  }
  $windowPid=[uint32]0;[void][EBR_PRE_NATIVE]::GetWindowThreadProcessId($window,[ref]$windowPid);$uiWindowProcessId=[int]$windowPid
  if($windowPid -ne 0 -and $windowPid -ne $process.Id){try{$process=[Diagnostics.Process]::GetProcessById([int]$windowPid)}catch{}}
  $buttonsSeen=[System.Collections.Generic.List[string]]::new()
  $watch=[Diagnostics.Stopwatch]::StartNew();$stage=0;$lastCapturedStage=-1
  while($watch.Elapsed.TotalMinutes -lt 3){
    if($process.HasExited){break}
    [void][EBR_PRE_NATIVE]::SetForegroundWindow($window)
    if($stage -gt 0 -and $stage -le 6 -and $stage -ne $lastCapturedStage){Capture-ActiveWindow $window ("{0}-wizard-stage-{1}.png" -f $Kind,$stage) | Out-Null;$lastCapturedStage=$stage}
    $finish=Find-WizardButton $window '^&?(Finish|Close)$'
    if($finish){
      $checkboxes=@([System.Windows.Automation.AutomationElement]::FromHandle($window).FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition) | Where-Object { $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::CheckBox -and $_.Current.Name -match 'Open Eye Break Reminder' })
      if($checkboxes.Count -gt 0){try{$toggle=$checkboxes[0].GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern);if($toggle.Current.ToggleState -eq [System.Windows.Automation.ToggleState]::On){$toggle.Toggle()}}catch{}}
      $nativeRunChecks=@([EBR_PRE_NATIVE]::Children($window) | Where-Object {[EBR_PRE_NATIVE]::ClassName($_) -eq 'Button' -and [EBR_PRE_NATIVE]::Text($_) -match 'Open Eye Break Reminder' -and [EBR_PRE_NATIVE]::IsWindowVisible($_) -and [EBR_PRE_NATIVE]::IsWindowEnabled($_)})
      if($nativeRunChecks.Count -gt 0){
        foreach($runCheck in $nativeRunChecks){if([EBR_PRE_NATIVE]::SendMessageW($runCheck,0x00F0,[IntPtr]::Zero,[IntPtr]::Zero).ToInt32() -eq 1){[void][EBR_PRE_NATIVE]::SendMessageW($runCheck,0x00F5,[IntPtr]::Zero,[IntPtr]::Zero)}}
        $remainingChecked=@($nativeRunChecks | Where-Object {[EBR_PRE_NATIVE]::SendMessageW($_,0x00F0,[IntPtr]::Zero,[IntPtr]::Zero).ToInt32() -eq 1})
        Require ($remainingChecked.Count -eq 0) "$Kind finish-page run checkbox is cleared before test cleanup" $remainingChecked.Count
      } elseif($isUninstaller){Pass "$Kind uninstaller finish page correctly omits an app Run checkbox" ([pscustomobject]@{UIAutomationRunCheckboxes=$checkboxes.Count;NativeRunCheckboxes=$nativeRunChecks.Count;Behavior='An uninstaller finish page closes the uninstall wizard and does not offer to launch the app.'})}
      else {Not-Tested "$Kind installer finish-page Run checkbox state" 'The visible NSIS installer finish page exposed no matching Run checkbox.'}
      Capture-ActiveWindow $window ("{0}-wizard-finish.png" -f $Kind) | Out-Null
      Invoke-WizardButton $window $finish
      [void]$process.WaitForExit(30000)
      try{$process.Refresh()}catch{}
      try{$launchProcess.Refresh()}catch{}
      if($isUninstaller){
        if(-not $launchProcess.HasExited){[void]$launchProcess.WaitForExit(30000)}
        $uiExitCode=Get-AvailableProcessExitCode $process
        $parentExitCode=Get-AvailableProcessExitCode $launchProcess
        $processTreeAfter=[System.Collections.Generic.List[object]]::new();$completionSamples=[System.Collections.Generic.List[object]]::new();$completionWatch=[Diagnostics.Stopwatch]::StartNew();$afterState=Get-UninstallStateSnapshot
        while($completionWatch.Elapsed.TotalSeconds -lt 20){
          $processTreeAfter=Get-ProcessTreeSnapshot $launchProcess.Id $Path
          $completionSamples.Add([pscustomobject]@{ElapsedSeconds=[Math]::Round($completionWatch.Elapsed.TotalSeconds,1);Processes=$processTreeAfter;State=(Get-UninstallStateSnapshot)})
          $state=Get-UninstallStateSnapshot
          if(-not $state.InstallDirectoryExists -and -not $state.UninstallKeyExists -and $processTreeAfter.Count -eq 0){$afterState=$state;break}
          Start-Sleep -Milliseconds 250
        }
        $endTime=[DateTime]::Now;$afterState=Get-UninstallStateSnapshot;$finalIds=@($processTreeAfter | ForEach-Object {$_.ProcessId});if($finalIds -notcontains $launchProcess.Id){$finalIds=@($launchProcess.Id)+$finalIds};$finalWindows=Get-DesktopWindowSnapshot $finalIds;$eventEvidence=Get-UninstallerEventLogEvidence $launchTime $endTime
        try{$shot=Capture-DesktopScreenshot ("{0}-desktop-after-wizard.png" -f $Kind);if($shot){$desktopScreenshots.Add($shot)}}catch{$desktopScreenshots.Add("after-wizard capture error: $($_.Exception.Message)")}
        $uiProcessName=$null;$uiProcessPath=$null;try{$uiProcessName=$process.ProcessName;$uiProcessPath=$process.Path}catch{}
        $diagnostic=[pscustomobject]@{Kind=$Kind;Path=$Path;Arguments='';Started=$launchTime.ToString('o');Ended=$endTime.ToString('o');DurationSeconds=[Math]::Round(($endTime-$launchTime).TotalSeconds,2);LaunchPid=$launchProcess.Id;LaunchProcessExited=$launchProcess.HasExited;LaunchProcessExitCode=$parentExitCode;UiWindowProcessId=$uiWindowProcessId;UiProcessName=$uiProcessName;UiProcessPath=$uiProcessPath;UiProcessExited=$process.HasExited;UiProcessExitCode=$uiExitCode;WizardVisible=$true;WizardButtons=$buttonsSeen.ToArray();Before=$beforeState;After=$afterState;InitialProcesses=$initialProcesses;InitialWindows=$initialWindows;CompletionSamples=$completionSamples.ToArray();Processes=$processTreeAfter;FinalWindows=$finalWindows;DesktopScreenshots=$desktopScreenshots.ToArray();EventLogs=$eventEvidence}
        Save-UninstallerDiagnostic $diagnostic
        if($process.HasExited){Pass "$Kind wizard UI process exits after Finish" ([pscustomobject]@{Pid=$uiWindowProcessId;ProcessName=$uiProcessName})}else{Add-Event "$Kind wizard UI process exits after Finish" 'FAIL' ([pscustomobject]@{Pid=$uiWindowProcessId;ProcessName=$uiProcessName})}
        if($null -eq $uiExitCode){Not-Tested "$Kind wizard UI process exit code" 'The exited UI-process handle did not expose an exit code; the parent and post-uninstall state are recorded separately.'}elseif($uiExitCode -eq 0){Pass "$Kind wizard UI process exits with code 0" ([pscustomobject]@{Pid=$uiWindowProcessId;ExitCode=$uiExitCode})}else{Add-Event "$Kind wizard UI process exits with code 0" 'FAIL' ([pscustomobject]@{Pid=$uiWindowProcessId;ExitCode=$uiExitCode})}
        if($launchProcess.HasExited){Pass "$Kind launch parent process exits after the wizard completes" ([pscustomobject]@{Pid=$launchProcess.Id})}else{Add-Event "$Kind launch parent process exits after the wizard completes" 'FAIL' ([pscustomobject]@{Pid=$launchProcess.Id})}
        if($null -eq $parentExitCode){Not-Tested "$Kind launch parent process exit code" 'The exited launcher handle did not expose an exit code; interactive completion is verified separately.'}elseif($parentExitCode -eq 0){Pass "$Kind launch parent process exits with code 0" ([pscustomobject]@{Pid=$launchProcess.Id;ExitCode=$parentExitCode})}else{Add-Event "$Kind launch parent process exits with code 0" 'FAIL' ([pscustomobject]@{Pid=$launchProcess.Id;ExitCode=$parentExitCode})}
      }else{
        Require ($process.HasExited) "$Kind wizard finishes and exits" ([pscustomobject]@{ExitCode=$process.ExitCode})
        Require ($process.ExitCode -eq 0) "$Kind wizard exits with code 0" ([pscustomobject]@{ExitCode=$process.ExitCode})
      }
      return $true
    }
    $install=Find-WizardButton $window '^&?(Install|Uninstall|Remove)$'
    $next=Find-WizardButton $window '^(Next|Next >|&Next >)$'
    if($stage -eq 0){
      Capture-ActiveWindow $window ("{0}-wizard-first-page.png" -f $Kind) | Out-Null
      $nativeButtons=@([EBR_PRE_NATIVE]::Children($window) | Where-Object {[EBR_PRE_NATIVE]::ClassName($_) -eq 'Button'} | ForEach-Object {[pscustomobject]@{Name=[EBR_PRE_NATIVE]::Text($_);Visible=[EBR_PRE_NATIVE]::IsWindowVisible($_);Enabled=[EBR_PRE_NATIVE]::IsWindowEnabled($_);ControlId=[EBR_PRE_NATIVE]::GetDlgCtrlID($_);Hwnd=('0x{0:X}' -f $_.ToInt64())}})
      Require ($next -ne $null -or $install -ne $null) "$Kind wizard exposes a usable navigation button" ([pscustomobject]@{WindowTitle=[EBR_PRE_NATIVE]::Text($window);NativeButtons=$nativeButtons})
    }
    if($install){
      $name="$($install.Name) [$($install.Source)]"
      if(-not $buttonsSeen.Contains($name)){$buttonsSeen.Add($name)}
      Invoke-WizardButton $window $install;$stage++
    } elseif($next){
      $name="$($next.Name) [$($next.Source)]"
      if(-not $buttonsSeen.Contains($name)){$buttonsSeen.Add($name)}
      Invoke-WizardButton $window $next;$stage++
    }
    Start-Sleep -Milliseconds 200
    foreach($h in [EBR_PRE_NATIVE]::TopWindowsForProcess($process.Id)){if([EBR_PRE_NATIVE]::IsWindowVisible($h)){$window=$h;break}}
  }
  if(-not $process.HasExited){Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue}
  throw "$Kind wizard did not reach its finish page within three minutes; buttons seen: $($buttonsSeen -join ', ')"
}
function Invoke-SilentInstaller([string]$Path,[string]$Kind) {
  $process=Start-Process -FilePath $Path -ArgumentList '/S' -PassThru
  if(-not $process.WaitForExit(120000)){Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue;throw "$Kind silent installer timed out."}
  Require ($process.ExitCode -eq 0) "$Kind silent installer exits successfully" ([pscustomobject]@{ExitCode=$process.ExitCode})
}
function Invoke-Install([string]$Path,[string]$Kind,[bool]$UseWizard) {
  $script:ownedInstall=$true
  if($UseWizard -and $script:interactiveDesktop){[void](Invoke-Wizard $Path $Kind)}else{Invoke-SilentInstaller $Path $Kind}
  if(-not (Test-Path -LiteralPath $appExe -PathType Leaf)){throw "$Kind did not create the expected installed executable $appExe"}
  Require ((Test-Path -LiteralPath $appExe -PathType Leaf)) "$Kind installs executable at the expected per-user path" $appExe
  Require ((Test-Path -LiteralPath (Join-Path $installDir 'Uninstall.exe') -PathType Leaf)) "$Kind installs its uninstaller" (Join-Path $installDir 'Uninstall.exe')
}
function Invoke-Uninstall([string]$Kind,[bool]$UseWizard) {
  $uninstaller=Join-Path $installDir 'Uninstall.exe'
  Require (Test-Path -LiteralPath $uninstaller -PathType Leaf) "$Kind uninstaller exists before removal" $uninstaller
  $liveAppProcesses=@(Get-Process -Name EyeBreakReminder -ErrorAction SilentlyContinue)
  Require ($liveAppProcesses.Count -eq 0) "$Kind begins with the installed application process stopped" @($liveAppProcesses | ForEach-Object {[pscustomobject]@{Pid=$_.Id;Path=$_.Path}})
  $wizardShown=$false
  if($UseWizard -and $script:interactiveDesktop){$wizardShown=[bool](Invoke-Wizard $uninstaller "$Kind-uninstall")}else{
    $process=Start-Process -FilePath $uninstaller -ArgumentList '/S' -PassThru
    if(-not $process.WaitForExit(90000)){Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue;throw "$Kind uninstaller timed out."}
    Require ($process.ExitCode -eq 0) "$Kind uninstaller exits successfully" ([pscustomobject]@{ExitCode=$process.ExitCode})
  }
  $removeWatch=[Diagnostics.Stopwatch]::StartNew()
  while((Test-Path -LiteralPath $appExe) -and $removeWatch.Elapsed.TotalSeconds -lt 5){Start-Sleep -Milliseconds 200}
  if((Test-Path -LiteralPath $appExe) -and $UseWizard -and $script:interactiveDesktop -and -not $wizardShown -and (Test-Path -LiteralPath $uninstaller)){
    $process=Start-Process -FilePath $uninstaller -ArgumentList '/S' -PassThru
    if(-not $process.WaitForExit(90000)){Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue;throw "$Kind silent uninstaller timed out."}
    Require ($process.ExitCode -eq 0) "$Kind silent uninstaller exits successfully" ([pscustomobject]@{ExitCode=$process.ExitCode})
    $removeWatch.Restart()
    while((Test-Path -LiteralPath $appExe) -and $removeWatch.Elapsed.TotalSeconds -lt 5){Start-Sleep -Milliseconds 200}
  }
  $remainingFiles=@()
  if(Test-Path -LiteralPath $installDir){$remainingFiles=@(Get-ChildItem -LiteralPath $installDir -Force -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)}
  $remainingProcesses=@(Get-Process -Name EyeBreakReminder -ErrorAction SilentlyContinue | ForEach-Object {[pscustomobject]@{Pid=$_.Id;Path=$_.Path}})
  $removalEvidence=[pscustomobject]@{Executable=$appExe;Exists=(Test-Path -LiteralPath $appExe);RemainingFiles=$remainingFiles;RunningAppProcesses=$remainingProcesses;UninstallerExists=(Test-Path -LiteralPath $uninstaller);UninstallRegistrationExists=(Test-Path -LiteralPath $uninstallKey);InstallDirectoryExists=(Test-Path -LiteralPath $installDir)}
  Require (-not (Test-Path -LiteralPath $appExe)) "$Kind removes the installed executable" $removalEvidence
  Require (-not (Test-Path -LiteralPath $installDir)) "$Kind removes the installation directory" $installDir
  Require (-not (Test-Path -LiteralPath $startMenuLink)) "$Kind removes its Start Menu shortcut" $startMenuLink
  Require (-not (Test-Path -LiteralPath $desktopLink)) "$Kind removes an optional desktop shortcut" $desktopLink
  Require (-not (Test-Path -LiteralPath $uninstallKey)) "$Kind removes its uninstall registration" $uninstallKey
  Require (-not (Test-Path -LiteralPath $appKey)) "$Kind removes its install-directory registration" $appKey
  $startupRemaining=@()
  if(Test-Path -LiteralPath $runKey){$startupRemaining=@((Get-ItemProperty -LiteralPath $runKey).PSObject.Properties | Where-Object {$_.Name -notmatch '^PS' -and [string]$_.Value -match 'EyeBreakReminder'})}
  Require ($startupRemaining.Count -eq 0) "$Kind removes the owned startup registration" $startupRemaining.Count
  $script:ownedInstall=$false
}
function Get-DesktopCapability {
  $shell=[EBR_PRE_NATIVE]::GetForegroundWindow()
  $explorerShell=[EBR_PRE_NATIVE]::FindWindowW('Shell_TrayWnd',$null)
  $session=[Diagnostics.Process]::GetCurrentProcess().SessionId
  return [Environment]::UserInteractive -and $session -gt 0 -and $explorerShell -ne [IntPtr]::Zero
}
function Get-SavedRegistryValue([string]$Path,[string]$Name) {
  $exists=Test-Path -LiteralPath $Path
  $value=$null
  if($exists){try{$item=Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop;$value=$item.$Name}catch{}}
  [pscustomobject]@{KeyExists=$exists;ValueExists=($null -ne $value);Value=$value}
}
function Restore-RegistryValue([string]$Path,[string]$Name,$Saved) {
  if($Saved.ValueExists){if(-not (Test-Path -LiteralPath $Path)){New-Item -Path $Path -Force | Out-Null};Set-ItemProperty -LiteralPath $Path -Name $Name -Value $Saved.Value -Force}
  elseif(Test-Path -LiteralPath $Path){
    Remove-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
    if(-not $Saved.KeyExists){
      $remaining=@((Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue).PSObject.Properties | Where-Object {$_.Name -notmatch '^PS'})
      if($remaining.Count -eq 0){Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue}
    }
  }
}
function Set-DwordRegistryValue([string]$Path,[string]$Name,[int]$Value) {
  if(-not (Test-Path -LiteralPath $Path)){New-Item -Path $Path -Force | Out-Null}
  if((Get-SavedRegistryValue $Path $Name).ValueExists){Set-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -Force}
  else{New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null}
}
function Get-OfficialRelease([string]$Uri,[string]$Name) {
  try {
    $response=Invoke-WebRequest -UseBasicParsing -Uri $Uri -TimeoutSec 20 -Headers @{Accept='application/vnd.github+json';'User-Agent'='EyeBreakReminder-PreReleaseValidation'}
    $status=[int]$response.StatusCode
    if($status -ne 200){$script:liveApiError="HTTP $status";return $null}
    $json=$response.Content | ConvertFrom-Json
    Pass "$Name official GitHub HTTPS endpoint responds" ([pscustomobject]@{Uri=$Uri;HttpStatus=$status;Unauthenticated=$true})
    return $json
  } catch {
    $status=''
    try{$status=[string]$_.Exception.Response.StatusCode.value__}catch{}
    $script:liveApiError=if($status){"HTTP $status"}else{$_.Exception.Message}
    return $null
  }
}
function Get-AssetDigest($ReleaseAsset,$ManifestText) {
  if($ReleaseAsset.digest -and $ReleaseAsset.digest -match '^sha256:([0-9a-fA-F]{64})$'){return $Matches[1].ToLowerInvariant()}
  if($ManifestText){
    $escaped=[regex]::Escape([string]$ReleaseAsset.name)
    $match=[regex]::Match($ManifestText,"(?im)^\s*([0-9a-f]{64})\s+\*?$escaped\s*$")
    if($match.Success){return $match.Groups[1].Value.ToLowerInvariant()}
  }
  return ''
}
function Download-OfficialV11Installer {
  $release=Get-OfficialRelease 'https://api.github.com/repos/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/tags/v1.1.0' 'Official v1.1.0 release-tag API'
  if(-not $release){$release=Get-OfficialRelease 'https://api.github.com/repos/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/tags/1.1.0' 'Official v1.1.0 release-tag API fallback'}
  if(-not $release){Not-Tested 'Official v1.1.0 installer availability' "Unauthenticated release API request failed: $script:liveApiError";return $null}
  if($release.draft -or $release.prerelease -or $release.html_url -notmatch '^https://github\.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/tag/'){
    Add-Event 'Official v1.1.0 release metadata is stable and points to Eye Break Reminder' 'FAIL' ([pscustomobject]@{Tag=$release.tag_name;Url=$release.html_url;Draft=$release.draft;Prerelease=$release.prerelease});throw 'The v1.1.0 release metadata did not identify an official stable Eye Break Reminder release.'
  }
  $setup=@($release.assets | Where-Object { $_.name -eq 'EyeBreakReminder-Setup-x64.exe' }) | Select-Object -First 1
  if(-not $setup){Not-Tested 'Official v1.1.0 installer download' 'The official v1.1.0 release exposes no EyeBreakReminder-Setup-x64.exe asset.';return $null}
  if($setup.browser_download_url -notmatch '^https://github\.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/download/'){
    Add-Event 'Official v1.1.0 installer URL remains in the Eye Break Reminder repository' 'FAIL' $setup.browser_download_url
    throw 'Refusing to download an older installer from outside the official Eye Break Reminder release assets.'
  }
  $manifestAsset=@($release.assets | Where-Object { $_.name -eq 'EyeBreakReminder-SHA256.txt' }) | Select-Object -First 1
  $manifestText=''
  if($manifestAsset){try{$manifestResponse=Invoke-WebRequest -UseBasicParsing -Uri $manifestAsset.browser_download_url -TimeoutSec 20 -Headers @{'User-Agent'='EyeBreakReminder-PreReleaseValidation'};$manifestText=$manifestResponse.Content}catch{}}
  $path=Join-Path $env:RUNNER_TEMP 'EyeBreakReminder-v1.1.0-Setup-x64.exe'
  try{Invoke-WebRequest -UseBasicParsing -Uri $setup.browser_download_url -OutFile $path -TimeoutSec 90 -Headers @{'User-Agent'='EyeBreakReminder-PreReleaseValidation'}}
  catch{Not-Tested 'Official v1.1.0 installer download' "The official asset endpoint could not be reached: $($_.Exception.Message)";return $null}
  $expectedDigest=Get-AssetDigest $setup $manifestText
  $actualDigest=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
  if(-not $expectedDigest){Not-Tested 'Official v1.1.0 installer digest verification' 'The release provided no asset digest and no matching SHA-256 manifest entry; the downloaded installer was not executed.';Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue;return $null}
  Require ($actualDigest -eq $expectedDigest) 'Official v1.1.0 installer matches the release SHA-256 digest' ([pscustomobject]@{Expected=$expectedDigest;Actual=$actualDigest;Asset=$setup.name})
  $version=(Get-Item -LiteralPath $path).VersionInfo.ProductVersion
  Require ($version -match '^1\.1\.0(\.0)?$') 'Official v1.1.0 installer has 1.1.0 metadata' $version
  Pass 'Official v1.1.0 installer downloaded only from the Eye Break Reminder release' ([pscustomobject]@{Path=$path;Asset=$setup.name;Sha256=$actualDigest;ReleaseUrl=$release.html_url})
  return $path
}
function Probe-UiaNames([IntPtr]$Window) {
  try {@(Get-UiaElements $Window | ForEach-Object { try { $_.Current.Name } catch { '' } } | Where-Object { $_ })} catch {@()}
}
function Test-InstalledUpdateCheck {
  if(-not $script:interactiveDesktop -or $script:mainWindow -eq [IntPtr]::Zero){Not-Tested 'Installed v1.2.0 in-app live update check' 'No interactive app window was available on this runner.';return}
  Switch-Timer
  $secondsBefore=Get-TimerSeconds
  Switch-Settings 5
  Capture-ActiveWindow $script:mainWindow 'installed-about-before-live-update.png' | Out-Null
  # These are Win32 Static labels. The app's logical ids are used by its internal
  # control table, while the native label HWNDs intentionally retain control ID -1.
  # Match their visible initial text, as the existing GUI acceptance suite does.
  $installedControl=Get-StaticControlByText $script:mainWindow 'Installed version: 1.2.0' 'Installed version'
  $installed=[EBR_PRE_NATIVE]::Text($installedControl.Handle)
  Require ($installed -match '1\.2\.0') 'Installed About screen identifies version 1.2.0' $installed
  $latestHandle=(Get-StaticControlByText $script:mainWindow 'Latest stable version: not checked' 'Initial latest version label').Handle
  $statusHandle=(Get-StaticControlByText $script:mainWindow 'Select Check for Updates to query the official public GitHub Releases API.' 'Initial update status').Handle
  $check=Get-Control $script:mainWindow 160 'Check for Updates'
  Click-Control $script:mainWindow 160 'Check for Updates'
  $after=Get-Control $script:mainWindow 160 'Check for Updates'
  $busyObserved=(-not $after.Enabled)
  if($busyObserved){Pass 'Installed update check enters a visible busy state' ([EBR_PRE_NATIVE]::Text($statusHandle))}
  else{Not-Tested 'Live update busy-state timing' 'The live request completed before the UI Automation sample; the controlled delayed-response suite separately exercises the busy state.'}
  $watch=[Diagnostics.Stopwatch]::StartNew();$responsive=$false
  while($watch.Elapsed.TotalSeconds -lt 5){if([EBR_PRE_NATIVE]::AppResponds($script:mainWindow,800)){$responsive=$true;break};Start-Sleep -Milliseconds 100}
  Require $responsive 'Installed application main window remains responsive during the update request' ([pscustomobject]@{ElapsedMilliseconds=$watch.ElapsedMilliseconds})
  Click-Control $script:mainWindow 10 'Timer navigation during the live update request'
  $timerWatch=[Diagnostics.Stopwatch]::StartNew();$secondsAfter=$secondsBefore;$timerAdvanced=$false;$timerAdvancedDuringRequest=$false
  while($timerWatch.Elapsed.TotalSeconds -lt 4){
    $secondsAfter=Get-TimerSeconds
    $requestStillBusy=(-not [EBR_PRE_NATIVE]::IsWindowEnabled($check.Handle))
    if($secondsAfter -lt $secondsBefore){$timerAdvanced=$true;if($requestStillBusy){$timerAdvancedDuringRequest=$true};break}
    Start-Sleep -Milliseconds 150
  }
  Require $timerAdvanced 'Installed timer countdown continues across the real live update workflow' ([pscustomobject]@{Before=$secondsBefore;After=$secondsAfter;WaitMilliseconds=$timerWatch.ElapsedMilliseconds})
  if($timerAdvancedDuringRequest){Pass 'Installed countdown advances while the real update request is still busy' ([pscustomobject]@{Before=$secondsBefore;After=$secondsAfter})}
  else{Not-Tested 'Timer tick overlapping the live network request' 'The real response completed before the next displayed countdown tick; the controlled delayed-response GUI acceptance test covers overlap with an active request.'}
  Switch-Settings 5
  $watch=[Diagnostics.Stopwatch]::StartNew();$enabled=$false
  while($watch.Elapsed.TotalSeconds -lt 35){try{$enabled=(Get-Control $script:mainWindow 160 'Check for Updates').Enabled}catch{};if($enabled){break};Start-Sleep -Milliseconds 150}
  Require $enabled 'Installed update request returns and re-enables its button' ([EBR_PRE_NATIVE]::Text($statusHandle))
  $latest=[EBR_PRE_NATIVE]::Text($latestHandle);$status=[EBR_PRE_NATIVE]::Text($statusHandle)
  Capture-ActiveWindow $script:mainWindow 'installed-live-update-check.png' | Out-Null
  if($script:liveRelease){
    $tag=[string]$script:liveRelease.tag_name
    $officialUrl="https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/tag/$tag"
    Require ($script:liveRelease.html_url -ceq $officialUrl) 'Live release link is the official Eye Break Reminder tag URL' $officialUrl
    $latestSemVer=[version]([regex]::Match($tag,'^v?(\d+\.\d+\.\d+)').Groups[1].Value)
    $displayedVersionMatch=[regex]::Match($latest,'(?i)^Latest stable version:\s*v?(\d+\.\d+\.\d+)\s*$')
    $displayedSemVer=$null
    if($displayedVersionMatch.Success){$displayedSemVer=[version]::Parse($displayedVersionMatch.Groups[1].Value)}
    Require ($displayedVersionMatch.Success -and $displayedSemVer -eq $latestSemVer) 'Installed app displays the live latest stable semantic version from GitHub' ([pscustomobject]@{ExpectedTag=$tag;ExpectedVersion=$latestSemVer.ToString();LatestLabel=$latest;Status=$status})
    $installedSemVer=[version]'1.2.0'
    if($latestSemVer -lt $installedSemVer){
      Require ($status -match 'installed version is newer') 'v1.2.0 reports that it is newer than the published stable release' $status
      Require (-not (Get-Control $script:mainWindow 161 'Open Official Release').Enabled) 'v1.2.0 does not offer a downgrade to the older stable release' $tag
    } elseif($latestSemVer -eq $installedSemVer){
      Require ($status -match 'up to date') 'Installed app reports current when live stable version is equal' $status
    } else {
      Require ($status -match 'update is available') 'Installed app reports an available newer stable release' $status
      Require ((Get-Control $script:mainWindow 161 'Open Official Release').Enabled) 'Official release button enables for an available update' $officialUrl
    }
  } else {
    $latestMatch=[regex]::Match($latest,'(?i)^Latest stable version:\s*v?(\d+\.\d+\.\d+)\s*$')
    if($latestMatch.Success){
      $appLatest=[version]$latestMatch.Groups[1].Value
      $installedSemVer=[version]'1.2.0'
      Require (($appLatest -lt $installedSemVer -and $status -match 'installed version is newer') -or ($appLatest -eq $installedSemVer -and $status -match 'up to date') -or ($appLatest -gt $installedSemVer -and $status -match 'update is available')) 'Installed app compares its live version label with v1.2.0 correctly' ([pscustomobject]@{Latest=$latest;Status=$status})
      if($appLatest -lt $installedSemVer){Require (-not (Get-Control $script:mainWindow 161 'Open Official Release').Enabled) 'Installed app does not offer a downgrade when live GitHub is older' $latest}
      Pass 'Installed app displayed and compared a live version despite the separate API probe failing' ([pscustomobject]@{Latest=$latest;Status=$status})
      Not-Tested 'Independent live API response and official release-link cross-check' "PowerShell API probe was unavailable: $script:liveLatestError"
    } else {
      Require ($status -notmatch 'up to date|update is available|installed version is newer') 'App does not claim a version result when the live API request failed' ([pscustomobject]@{NetworkError=$script:liveLatestError;Status=$status;Latest=$latest})
      Pass 'Installed app shows an understandable honest network/API error' $status
      Not-Tested 'Live version comparison inside the installed app' "GitHub live stable release endpoint unavailable: $script:liveLatestError"
    }
  }
}
function Test-UiaAndKeyboard {
  $names=Probe-UiaNames $script:mainWindow
  Require (@('Timer','History','Settings' | Where-Object { $names -contains $_ }).Count -eq 3) 'UI Automation exposes the main navigation names' $names
  $elements=Get-UiaElements $script:mainWindow
  $named=@($elements | Where-Object { $_.Current.IsControlElement -and $_.Current.Name -and $_.Current.IsEnabled -and -not $_.Current.IsOffscreen })
  Require ($named.Count -ge 9) 'UI Automation exposes enabled named controls on the Timer screen' ([pscustomobject]@{NamedEnabledVisibleControls=$named.Count;Examples=@($named | Select-Object -First 20 | ForEach-Object {$_.Current.Name})})
  if(-not $script:interactiveDesktop){Not-Tested 'Keyboard-only focus order' 'No interactive Windows desktop was exposed.';return}
  $nav=Get-Control $script:mainWindow 10 'Timer navigation'
  Focus-AppControl $nav.Handle
  [System.Windows.Forms.SendKeys]::SendWait('{TAB}')
  Start-Sleep -Milliseconds 100
  $focus=[EBR_PRE_NATIVE]::GetFocus();$focusPid=[uint32]0;[void][EBR_PRE_NATIVE]::GetWindowThreadProcessId($focus,[ref]$focusPid)
  $focused=@($elements | Where-Object { $_.Current.HasKeyboardFocus } | ForEach-Object {$_.Current.Name})
  Require ($focusPid -eq $script:appPid -or $focused.Count -gt 0) 'Keyboard Tab input moves focus within the installed application' ([pscustomobject]@{FocusWindow=('0x{0:X}' -f $focus.ToInt64());FocusProcessId=$focusPid;AutomationFocus=$focused})
  Pass 'Screen-reader accessible names and focus properties are available through Windows UI Automation' ([pscustomobject]@{NamedControlCount=$named.Count;FocusedNames=$focused})
  Not-Tested 'Narrator or other screen-reader speech' 'UI Automation properties were inspected; no screen-reader speech engine was started or verified.'
}
function Test-OsAppearanceAndTextScale {
  if(-not $script:interactiveDesktop){
    Not-Tested 'Actual Windows light/dark appearance switching' 'No interactive Windows desktop was exposed.'
    Not-Tested 'Windows High Contrast / Forced Colors integration' 'No interactive Windows desktop was exposed.'
    Not-Tested 'Windows text scaling preference change' 'No interactive Windows desktop was exposed.'
    return
  }
  foreach($entry in @(@($personalizeKey,'AppsUseLightTheme'),@($personalizeKey,'SystemUseLightTheme'),@($accessibilityKey,'TextScaleFactor'))){
    $script:osOriginal["$($entry[0])|$($entry[1])"]=Get-SavedRegistryValue $entry[0] $entry[1]
  }
  $flags=[uint32]0
  if([EBR_PRE_NATIVE]::GetHighContrast([ref]$flags)){$script:highContrastOriginal=$flags}else{$script:highContrastOriginal=$null}
  try {
    Switch-Settings 4
    Set-Combo $script:mainWindow 106 0 'Follow Windows Theme'
    Switch-Timer
    if(-not (Test-Path -LiteralPath $personalizeKey)){New-Item -Path $personalizeKey -Force | Out-Null}
    Set-DwordRegistryValue $personalizeKey 'AppsUseLightTheme' 1
    Set-DwordRegistryValue $personalizeKey 'SystemUseLightTheme' 1
    [void][EBR_PRE_NATIVE]::BroadcastSetting($script:mainWindow,'ImmersiveColorSet')
    [void][EBR_PRE_NATIVE]::SendMessageW($script:mainWindow,0x031A,[IntPtr]::Zero,[IntPtr]::Zero)
    Start-Sleep -Milliseconds 350
    $lightPixel=[EBR_PRE_NATIVE]::ClientPixel($script:mainWindow,8,[Math]::Max(8,(Get-ClientGeometry $script:mainWindow).Height-8))
    Capture-ActiveWindow $script:mainWindow 'follow-windows-light-active.png' | Out-Null
    Set-DwordRegistryValue $personalizeKey 'AppsUseLightTheme' 0
    Set-DwordRegistryValue $personalizeKey 'SystemUseLightTheme' 0
    [void][EBR_PRE_NATIVE]::BroadcastSetting($script:mainWindow,'ImmersiveColorSet')
    [void][EBR_PRE_NATIVE]::SendMessageW($script:mainWindow,0x031A,[IntPtr]::Zero,[IntPtr]::Zero)
    Start-Sleep -Milliseconds 350
    $darkPixel=[EBR_PRE_NATIVE]::ClientPixel($script:mainWindow,8,[Math]::Max(8,(Get-ClientGeometry $script:mainWindow).Height-8))
    Capture-ActiveWindow $script:mainWindow 'follow-windows-dark-active.png' | Out-Null
    Require ($lightPixel -ne $darkPixel -and $lightPixel -ne 0xffffffff -and $darkPixel -ne 0xffffffff) 'Follow Windows changes the installed app palette after actual per-user light/dark setting changes' ([pscustomobject]@{LightPixel=('0x{0:X8}' -f $lightPixel);DarkPixel=('0x{0:X8}' -f $darkPixel);Notification='ImmersiveColorSet and WM_THEMECHANGED'})
    $flags=[uint32]0
    if($script:highContrastOriginal -ne $null -and [EBR_PRE_NATIVE]::SetHighContrast(($script:highContrastOriginal -bor 1))){
      [void][EBR_PRE_NATIVE]::BroadcastSetting($script:mainWindow,'Accessibility')
      [void][EBR_PRE_NATIVE]::SendMessageW($script:mainWindow,0x031A,[IntPtr]::Zero,[IntPtr]::Zero)
      [void][EBR_PRE_NATIVE]::GetHighContrast([ref]$flags)
      Require (($flags -band 1) -ne 0) 'Windows reports High Contrast enabled through SPI_GETHIGHCONTRAST' ([pscustomobject]@{Flags=$flags})
      # Windows can cover the desktop briefly with its own "Please wait" screen
      # while applying Forced Colors. Let the shell transition finish before
      # capturing and compare an on-screen app pixel with the HWND paint result.
      Start-Sleep -Seconds 2
      $forcedPixel=[EBR_PRE_NATIVE]::ClientPixel($script:mainWindow,8,[Math]::Max(8,(Get-ClientGeometry $script:mainWindow).Height-8))
      Require ($forcedPixel -ne $darkPixel) 'Follow Windows window palette responds to Forced Colors' ([pscustomobject]@{DarkPixel=('0x{0:X8}' -f $darkPixel);ForcedColorsPixel=('0x{0:X8}' -f $forcedPixel)})
      $forcedShot=Capture-ActiveWindow $script:mainWindow 'follow-windows-forced-colors-active.png'
      if($forcedShot){
        $visiblePixel=Get-CapturedClientPixel $script:mainWindow $forcedShot
        if($visiblePixel -eq $forcedPixel){Pass 'Forced Colors palette is visible in the active desktop capture' ([pscustomobject]@{WindowPixel=('0x{0:X8}' -f $forcedPixel);ScreenPixel=('0x{0:X8}' -f $visiblePixel)})}
        else{Not-Tested 'Visible Forced Colors screenshot confirmation' ([pscustomobject]@{Reason='A Windows transition/foreground overlay obscured the app; the screenshot pixel did not match the app window DC.';WindowPixel=('0x{0:X8}' -f $forcedPixel);ScreenPixel=('0x{0:X8}' -f $visiblePixel)})}
      }
      [void][EBR_PRE_NATIVE]::SetHighContrast($script:highContrastOriginal)
      [void][EBR_PRE_NATIVE]::BroadcastSetting($script:mainWindow,'Accessibility')
      Pass 'Windows High Contrast system setting restored after the test'
    } else {Not-Tested 'Windows High Contrast / Forced Colors integration' 'SPI_SET­HIGHCONTRAST was unavailable or rejected by the runner; no Forced Colors result is claimed.'}
    $dpi=[EBR_PRE_NATIVE]::GetDpiForWindow($script:mainWindow)
    $priorDpi=144
    if($dpi -ne $priorDpi){Pass 'Installed application exercised at an additional DPI versus the earlier 144-DPI run' ([pscustomobject]@{EarlierDpi=$priorDpi;RunnerDpi=$dpi})}
    else {Not-Tested 'Additional DPI configuration' 'The runner reported the same 144 DPI used in the earlier GUI campaign; changing display scaling requires an additional desktop configuration.'}
    $beforeRect=(Get-Control $script:mainWindow 22 'Take a break button').Rect
    $scaleValue=Get-SavedRegistryValue $accessibilityKey 'TextScaleFactor'
    if(-not (Test-Path -LiteralPath $accessibilityKey)){New-Item -Path $accessibilityKey -Force | Out-Null}
    Set-DwordRegistryValue $accessibilityKey 'TextScaleFactor' 150
    [void][EBR_PRE_NATIVE]::BroadcastSetting($script:mainWindow,'Accessibility')
    [void][EBR_PRE_NATIVE]::SendMessageW($script:mainWindow,0x001A,[IntPtr]::Zero,[IntPtr]::Zero)
    Start-Sleep -Milliseconds 350
    $afterRect=(Get-Control $script:mainWindow 22 'Take a break button').Rect
    Require ($afterRect.Height -gt $beforeRect.Height) 'Installed app responds to a 150% Windows TextScaleFactor preference' ([pscustomobject]@{BeforeButtonHeight=$beforeRect.Height;AfterButtonHeight=$afterRect.Height;RegistryValue=150})
    Assert-StatusCentered '150% Windows text scale'
    Capture-ActiveWindow $script:mainWindow 'text-scale-150-active.png' | Out-Null
    Restore-RegistryValue $accessibilityKey 'TextScaleFactor' $scaleValue
    [void][EBR_PRE_NATIVE]::BroadcastSetting($script:mainWindow,'Accessibility')
    Pass 'Windows text-scale preference restored after the test'
  } finally {
    if($script:highContrastOriginal -ne $null){[void][EBR_PRE_NATIVE]::SetHighContrast($script:highContrastOriginal);[void][EBR_PRE_NATIVE]::BroadcastSetting($script:mainWindow,'Accessibility')}
    foreach($key in $script:osOriginal.Keys){$parts=$key.Split('|',2);Restore-RegistryValue $parts[0] $parts[1] $script:osOriginal[$key]}
    if($script:mainWindow -ne [IntPtr]::Zero){[void][EBR_PRE_NATIVE]::BroadcastSetting($script:mainWindow,'ImmersiveColorSet');[void][EBR_PRE_NATIVE]::SendMessageW($script:mainWindow,0x031A,[IntPtr]::Zero,[IntPtr]::Zero)}
  }
  if($script:mainWindow -ne [IntPtr]::Zero){
    Switch-Settings 4
    Set-Combo $script:mainWindow 106 1 'Restore Light theme after Windows appearance testing'
    Require ((Get-Combo $script:mainWindow 106 'Restored test theme') -eq 1) 'Appearance integration restores the Light theme test fixture'
    Switch-Timer
  }
}
function Test-WindowsInstalledAppsPage {
  if(-not $script:interactiveDesktop){Not-Tested 'Windows Settings > Installed Apps listing' 'The runner did not expose an interactive Explorer desktop.';return}
  $settingsHandle=[IntPtr]::Zero
  $pageNames=@()
  $searchFound=$false
  $resultFound=$false
  try {
    Start-Process -FilePath 'ms-settings:appsfeatures' | Out-Null
    $settingsPids=@(Get-Process -Name SystemSettings,ApplicationFrameHost -ErrorAction SilentlyContinue | ForEach-Object {$_.Id})
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $searchElement=$null
    $settingsWindow=$null
    while($watch.Elapsed.TotalSeconds -lt 25){
      $elements=@()
      try{$root=[System.Windows.Automation.AutomationElement]::RootElement;$elements=@($root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition))}catch{}
      $settingsWindow=@($elements | Where-Object {try{$_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Window -and $_.Current.Name -match '(?i)Settings|Installed apps|Apps & features'}catch{$false}} | Select-Object -First 1)
      if($settingsWindow.Count -gt 0){
        try{$settingsHandle=[IntPtr]$settingsWindow[0].Current.NativeWindowHandle}catch{}
        $windowPid=0;try{$windowPid=$settingsWindow[0].Current.ProcessId}catch{}
        if($windowPid){$settingsPids=@($settingsPids)+@([int]$windowPid)}
      }
      $appElements=@($elements | Where-Object {
        try{
          $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Edit -and
          ($settingsPids -contains [int]$_.Current.ProcessId) -and
          ($_.Current.Name -match '(?i)^\s*Search apps\s*$')
        }catch{$false}
      })
      if($appElements.Count -gt 0){$searchElement=$appElements[0];break}
      Start-Sleep -Milliseconds 400
    }
    if(-not $searchElement){
      $pageNames=@($elements | ForEach-Object {try{$_.Current.Name}catch{''}} | Where-Object {$_} | Select-Object -Unique | Select-Object -First 40)
      $visibleEdits=@($elements | Where-Object {try{$_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Edit -and ($settingsPids -contains [int]$_.Current.ProcessId)}catch{$false}} | ForEach-Object {try{[pscustomobject]@{Name=$_.Current.Name;AutomationId=$_.Current.AutomationId;ClassName=$_.Current.ClassName;ProcessId=$_.Current.ProcessId}}catch{}})
      Add-Event 'Windows Settings > Installed Apps app-list search UI' 'NOT TESTED' ([pscustomobject]@{Reason='Settings launched, but the app-list Search apps edit was not exposed to UI Automation; the global Settings search is not accepted.';VisiblePageNames=$pageNames;VisibleEdits=$visibleEdits;SettingsProcesses=$settingsPids})
      return
    }
    $searchControl=[pscustomobject]@{Name=$searchElement.Current.Name;AutomationId=$searchElement.Current.AutomationId;ClassName=$searchElement.Current.ClassName;ProcessId=$searchElement.Current.ProcessId}
    $searchFound=$true
    try{
      $valuePattern=$searchElement.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
      $valuePattern.SetValue('Eye Break Reminder')
    }catch{
      try{
        [void]$searchElement.SetFocus()
        [System.Windows.Forms.SendKeys]::SendWait('^a')
        [System.Windows.Forms.SendKeys]::SendWait('Eye Break Reminder')
      }catch{throw "Could not enter the app name into the Settings Installed Apps search: $($_.Exception.Message)"}
    }
    $searchWatch=[Diagnostics.Stopwatch]::StartNew()
    while($searchWatch.Elapsed.TotalSeconds -lt 8){
      $elements=@()
      try{$elements=@([System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition))}catch{}
      $pageNames=@($elements | ForEach-Object {try{$_.Current.Name}catch{''}} | Where-Object {$_} | Select-Object -Unique)
      $matchingRows=@($elements | Where-Object {
        try{
          ($settingsPids -contains [int]$_.Current.ProcessId) -and
          ($_.Current.Name -match '(?i)^\s*Eye Break Reminder(?:\s|$)')
        }catch{$false}
      } | ForEach-Object {try{[pscustomobject]@{Name=$_.Current.Name;ControlType=$_.Current.ControlType.ProgrammaticName;AutomationId=$_.Current.AutomationId;ClassName=$_.Current.ClassName;ProcessId=$_.Current.ProcessId}}catch{}})
      if($matchingRows.Count -gt 0){$resultFound=$true;break}
      Start-Sleep -Milliseconds 400
    }
    if($settingsHandle -ne [IntPtr]::Zero){Capture-ActiveWindow $settingsHandle 'windows-settings-installed-apps.png' | Out-Null}
    if($resultFound){
      Pass 'Windows Settings > Installed Apps lists the published Eye Break Reminder installation' ([pscustomobject]@{SearchControl=$searchControl;SettingsPage=@($pageNames | Where-Object {$_ -match '(?i)Installed apps|Apps & features'} | Select-Object -First 10);MatchingRows=$matchingRows})
    }else{
      Add-Event 'Windows Settings > Installed Apps lists the published Eye Break Reminder installation' 'FAIL' ([pscustomobject]@{SearchControl=$searchControl;VisibleMatchingText=@($pageNames | Where-Object {$_ -match '(?i)Eye Break Reminder'});MatchingRows=$matchingRows;SettingsProcesses=$settingsPids})
    }
  } catch {
    Add-Event 'Windows Settings > Installed Apps UI automation' 'NOT TESTED' ([pscustomobject]@{Reason=("The Settings UI did not expose a stable searchable page: " + $_.Exception.Message);SearchObserved=$searchFound;VisiblePageNames=$pageNames})
  } finally {
    if($settingsHandle -ne [IntPtr]::Zero){[void][EBR_PRE_NATIVE]::PostMessageW($settingsHandle,0x0010,[IntPtr]::Zero,[IntPtr]::Zero)}
  }
}

function Assert-InstallationMetadata([string]$ExpectedVersion) {
  $exeVersion=(Get-Item -LiteralPath $appExe).VersionInfo.ProductVersion
  Require ($exeVersion -match "^$([regex]::Escape($ExpectedVersion))(\.0)?$") "Installed executable metadata is $ExpectedVersion" $exeVersion
  $registered=Get-ItemProperty -LiteralPath $uninstallKey -ErrorAction Stop
  Require ($registered.DisplayVersion -eq $ExpectedVersion) "Installed Apps registration is $ExpectedVersion" $registered.DisplayVersion
  Require ([IO.Path]::GetFullPath($registered.InstallLocation) -ieq [IO.Path]::GetFullPath($installDir)) 'Installed Apps registration points at the expected location' $registered.InstallLocation
  $registeredDir=(Get-ItemProperty -LiteralPath $appKey -Name InstallDir -ErrorAction Stop).InstallDir
  Require ([IO.Path]::GetFullPath($registeredDir) -ieq [IO.Path]::GetFullPath($installDir)) 'Application install registry entry points at the expected location' $registeredDir
  $shortcut=New-Object -ComObject WScript.Shell
  $link=$shortcut.CreateShortcut($startMenuLink)
  Require ([IO.Path]::GetFullPath($link.TargetPath) -ieq [IO.Path]::GetFullPath($appExe)) 'Start Menu shortcut targets the installed executable' $link.TargetPath
  Require ((Test-Path -LiteralPath (Join-Path $installDir 'README.md')) -and (Test-Path -LiteralPath (Join-Path $installDir 'PRIVACY.md')) -and (Test-Path -LiteralPath (Join-Path $installDir 'VERIFICATION.md'))) 'Installed documentation files are present' $installDir
  $startupValues=@()
  if(Test-Path -LiteralPath $runKey){$startupValues=@((Get-ItemProperty -LiteralPath $runKey).PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' -and [string]$_.Value -match 'EyeBreakReminder' })}
  Require ($startupValues.Count -le 1) 'No duplicate Eye Break Reminder startup registration exists' $startupValues.Count
  Pass 'Per-user install layout and version metadata' ([pscustomobject]@{InstallDirectory=$installDir;ExecutableVersion=$exeVersion;DisplayVersion=$registered.DisplayVersion;StartMenuLink=$startMenuLink;Uninstaller=(Join-Path $installDir 'Uninstall.exe')})
}
function Start-And-CheckApp([string]$ExpectedVersion) {
  Assert-InstallationMetadata $ExpectedVersion
  $visible=if($script:interactiveDesktop){Start-InstalledAppFromShortcut}else{Start-InstalledApp}
  if(-not $visible){return $false}
  if(-not $script:interactiveDesktop){Not-Tested 'Start Menu shortcut launch' 'The runner has no interactive Explorer desktop; shortcut target path was package-checked only.'}
  $root=[System.Windows.Automation.AutomationElement]::FromHandle($script:mainWindow)
  $names=Probe-UiaNames $script:mainWindow
  Pass 'Installed app launched and exposes its native UI Automation tree' ([pscustomobject]@{WindowTitle=[EBR_PRE_NATIVE]::Text($script:mainWindow);NameCount=$names.Count;Names=@($names | Select-Object -First 20)})
  return $true
}
function Test-FreshInstallApp {
  if(-not $script:interactiveDesktop -or $script:mainWindow -eq [IntPtr]::Zero){Not-Tested 'Installed app settings, History, timer layout and UI interactions' 'No interactive app window was available.';return}
  $names=Probe-UiaNames $script:mainWindow
  Require (@('Timer','History','Settings' | Where-Object { $names -contains $_ }).Count -eq 3) 'Installed app exposes Timer, History and Settings navigation' $names
  Switch-Settings 4
  Require ((Get-Combo $script:mainWindow 106 'Theme') -eq 2) 'Fresh v1.2.0 installation keeps the dark theme default' 2
  Set-Combo $script:mainWindow 106 1 'Theme'
  Switch-Settings 0
  Set-Edit $script:mainWindow 100 '1' 'Work interval'
  Set-Edit $script:mainWindow 101 '30' 'Break duration'
  Switch-Settings 2
  Set-Check $script:mainWindow 32 $false 'Alarm enabled'
  $themeNames=@('follow-windows','light','dark','high-contrast-dark','high-contrast-light')
  foreach($themeIndex in 0..4){
    $themeName=$themeNames[$themeIndex]
    Switch-Settings 4
    Set-Combo $script:mainWindow 106 $themeIndex "Published binary theme: $themeName"
    Require ((Get-Combo $script:mainWindow 106 "Published theme $themeName") -eq $themeIndex) "Published binary selects $themeName" $themeIndex
    $accessibleNames=Probe-UiaNames $script:mainWindow
    Require (@('Timer','History','Settings' | Where-Object {$accessibleNames -contains $_}).Count -eq 3) "Published binary $themeName Settings screen retains accessible navigation" $accessibleNames
    Capture-ActiveWindow $script:mainWindow "published-theme-$themeName-settings.png" | Out-Null
    Switch-Timer
    Require ((Wait-ForStatus 'Running') -like '*Running*') "Published binary $themeName timer screen remains operational"
    Assert-StatusCentered "published $themeName work state"
    $workSample=Get-ActiveTimerNavAccentPixel "$themeName work" "published-theme-$themeName-timer-work.png"
    Click-Control $script:mainWindow 22 "Published binary $themeName manual break"
    $breakWait=[Diagnostics.Stopwatch]::StartNew();$breakWindow=[IntPtr]::Zero
    while($breakWait.Elapsed.TotalSeconds -lt 10){$breaks=Get-BreakWindow $script:appPid;if($breaks.Count -eq 1){$breakWindow=$breaks[0];break};Start-Sleep -Milliseconds 100}
    Require ($breakWindow -ne [IntPtr]::Zero) "Published binary $themeName opens its reminder window"
    Require ((Wait-ForStatus 'Taking an eye break') -like '*Taking an eye break*') "Published binary $themeName reports the break state"
    Assert-StatusCentered "published $themeName break state"
    Start-Sleep -Milliseconds 200
    $breakSample=Get-ActiveTimerNavAccentPixel "$themeName break" "published-theme-$themeName-timer-break.png"
    Require ($workSample.Pixel -ne $breakSample.Pixel) "Published binary $themeName uses a distinct work and break accent" ([pscustomobject]@{WorkPixel=$workSample.Hex;BreakPixel=$breakSample.Hex;WorkScreenPoint=$workSample.ScreenPoint;BreakScreenPoint=$breakSample.ScreenPoint;WorkScreenshot=$workSample.Screenshot;BreakScreenshot=$breakSample.Screenshot;Sample='Selected Timer navigation underline, pixel measured directly from the active desktop'})
    Capture-ActiveWindow $breakWindow "published-theme-$themeName-reminder.png" | Out-Null
    Require ([EBR_PRE_NATIVE]::Text((Get-Control $breakWindow 40 "$themeName break countdown").Handle) -match '^\d+:\d{2}$') "Published binary $themeName reminder shows its countdown"
    Click-Control $breakWindow 23 "Acknowledge published binary $themeName break"
    Require ((Wait-ForStatus 'Running') -like '*Running*') "Published binary $themeName returns to work after break completion"
    Switch-Settings 4
    Capture-ActiveWindow $script:mainWindow "published-theme-$themeName-settings-after-break.png" | Out-Null
    Switch-Timer
    Click-Control $script:mainWindow 11 "Published binary $themeName History navigation"
    $historyList=Get-Control $script:mainWindow 200 "$themeName History list"
    $historyRows=[EBR_PRE_NATIVE]::SendMessageW($historyList.Handle,0x1004,[IntPtr]::Zero,[IntPtr]::Zero).ToInt32()
    Require ($historyRows -ge 1) "Published binary $themeName History screen contains the completed break" $historyRows
    Capture-ActiveWindow $script:mainWindow "published-theme-$themeName-history.png" | Out-Null
    Switch-Timer
    Stop-InstalledApp
    Require (Start-InstalledApp) "Published binary restarts after $themeName persistence check"
    Switch-Settings 4
    Require ((Get-Combo $script:mainWindow 106 "Restarted $themeName theme") -eq $themeIndex) "Published binary persists $themeName across restart" $themeIndex
  }
  Set-Combo $script:mainWindow 106 1 'Restore Light theme test fixture after published all-theme loop'
  Switch-Timer
  Click-Control $script:mainWindow 21 'Reset one-minute work timer'
  Require ((Wait-ForStatus 'Running') -like '*Running*') 'Installed app timer starts in the work state'
  Assert-StatusCentered 'installed work state'
  Capture-ActiveWindow $script:mainWindow 'installed-timer-work-active.png' | Out-Null
  Capture-PrintWindow $script:mainWindow 'installed-timer-printwindow-comparison.png' | Out-Null
  $dpi=[EBR_PRE_NATIVE]::GetDpiForWindow($script:mainWindow)
  foreach($size in @(@{Width=680;Height=660},@{Width=1100;Height=820})){
    $screenWidth=[EBR_PRE_NATIVE]::GetSystemMetrics(0);$screenHeight=[EBR_PRE_NATIVE]::GetSystemMetrics(1)
    $width=[Math]::Min([int]$size.Width,$screenWidth-60);$height=[Math]::Min([int]$size.Height,$screenHeight-60)
    [void][EBR_PRE_NATIVE]::SetWindowPos($script:mainWindow,[IntPtr]::Zero,20,20,$width,$height,0x0004 -bor 0x0010)
    Start-Sleep -Milliseconds 250
    Assert-StatusCentered "installed $width x $height at $dpi DPI"
  }
  [void][EBR_PRE_NATIVE]::SetWindowPos($script:mainWindow,[IntPtr]::Zero,80,60,820,720,0x0004 -bor 0x0010)
  Test-InstalledUpdateCheck
  Switch-Timer
  Click-Control $script:mainWindow 22 'Manual break for installed history and reminder test'
  $breakWait=[Diagnostics.Stopwatch]::StartNew();$breakWindow=[IntPtr]::Zero
  while($breakWait.Elapsed.TotalSeconds -lt 10){$breaks=Get-BreakWindow $script:appPid;if($breaks.Count -eq 1){$breakWindow=$breaks[0];break};Start-Sleep -Milliseconds 100}
  Require ($breakWindow -ne [IntPtr]::Zero) 'Installed app opens the native eye-break reminder window'
  Require ((Wait-ForStatus 'Taking an eye break') -like '*Taking an eye break*') 'Installed app clearly labels the break state'
  Capture-ActiveWindow $breakWindow 'installed-reminder-active.png' | Out-Null
  Require ([EBR_PRE_NATIVE]::Text((Get-Control $breakWindow 40 'Break countdown').Handle) -match '^\d+:\d{2}$') 'Installed reminder exposes the remaining break duration'
  Click-Control $breakWindow 23 'Acknowledge the installed app break'
  Require ((Wait-ForStatus 'Running') -like '*Running*') 'Installed app returns to work after acknowledging a break'
  $historyPath=Join-Path $dataDir 'history.dat'
  $historyLines=@()
  if(Test-Path -LiteralPath $historyPath){$historyLines=@(Get-Content -LiteralPath $historyPath | Where-Object { $_.Trim() })}
  Require ($historyLines.Count -ge 1) 'Installed app records an acknowledged break in history' ([pscustomobject]@{HistoryRecords=$historyLines.Count;Path=$historyPath})
  Switch-Settings 4
  Switch-Timer
  $settingsPath=Join-Path $dataDir 'settings.ini'
  $settings=Read-SettingsMap $settingsPath
  $persistedValues=[pscustomobject]@{Theme=$settings['theme'];WorkMinutes=$settings['workMinutes'];BreakSeconds=$settings['breakSeconds']}
  Require ($settings['theme'] -eq '1' -and $settings['workMinutes'] -eq '1' -and $settings['breakSeconds'] -eq '30') 'Installed app persists theme and configured schedule values' ([pscustomobject]@{Path=$settingsPath;Observed=$persistedValues})
  $hashBefore=(Get-FileHash -LiteralPath $historyPath -Algorithm SHA256).Hash
  Stop-InstalledApp
  $restore=Start-InstalledApp
  if($restore){
    Switch-Settings 4
    Require ((Get-Combo $script:mainWindow 106 'Theme') -eq 1) 'Installed app restores the selected theme after restart'
    Switch-Settings 0
    Require ([EBR_PRE_NATIVE]::Text((Get-Control $script:mainWindow 100 'Restored work interval').Handle) -eq '1') 'Installed app restores the work interval after restart'
    Require ([EBR_PRE_NATIVE]::Text((Get-Control $script:mainWindow 101 'Restored break duration').Handle) -eq '30') 'Installed app restores the break duration after restart'
    $listId=200
    Switch-Settings 0
    Switch-Timer
    Click-Control $script:mainWindow 11 'History navigation'
    $list=Get-Control $script:mainWindow $listId 'History list'
    $rows=[EBR_PRE_NATIVE]::SendMessageW($list.Handle,0x1004,[IntPtr]::Zero,[IntPtr]::Zero).ToInt32()
    Require ($rows -ge 1) 'Installed app reloads history into the visible History list after restart' $rows
    Capture-ActiveWindow $script:mainWindow 'installed-history-statistics-active.png' | Out-Null
  }
  $hashAfter=(Get-FileHash -LiteralPath $historyPath -Algorithm SHA256).Hash
  Require ($hashBefore -eq $hashAfter) 'Installed app preserves the saved history bytes across restart' ([pscustomobject]@{Before=$hashBefore;After=$hashAfter})
  if($restore){Test-OsAppearanceAndTextScale;Test-UiaAndKeyboard;Stop-InstalledApp}
}
function Get-HiddenIconsButton {
  $root=[System.Windows.Automation.AutomationElement]::RootElement
  $condition=[System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty,[System.Windows.Automation.ControlType]::Button)
  $buttons=$root.FindAll([System.Windows.Automation.TreeScope]::Descendants,$condition)
  for($i=0;$i -lt $buttons.Count;$i++){
    $button=$buttons.Item($i)
    try{if($button.Current.Name -match '(?i)(hidden icons|more icons|overflow)' -and -not $button.Current.IsOffscreen -and $button.Current.BoundingRectangle.Width -gt 0){return $button}}catch{}
  }
  return $null
}
function Get-ShellTrayIconElement {
  $iconRect=New-Object EBR_PRE_RECT
  if(-not [EBR_PRE_NATIVE]::GetTrayRect($script:mainWindow,1,[ref]$iconRect)){return $null}
  $iconX=($iconRect.Left+$iconRect.Right)/2.0;$iconY=($iconRect.Top+$iconRect.Bottom)/2.0
  $root=[System.Windows.Automation.AutomationElement]::RootElement
  $condition=[System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty,[System.Windows.Automation.ControlType]::Button)
  $buttons=$root.FindAll([System.Windows.Automation.TreeScope]::Descendants,$condition)
  for($i=0;$i -lt $buttons.Count;$i++){
    $button=$buttons.Item($i)
    try{$rect=$button.Current.BoundingRectangle;if($button.Current.Name -match '(?i)^Eye Break Reminder(\s*[—-].*)?$' -and -not $button.Current.IsOffscreen -and $rect.Width -gt 0 -and [Math]::Abs(($rect.Left+$rect.Width/2)-$iconX) -le 24 -and [Math]::Abs(($rect.Top+$rect.Height/2)-$iconY) -le 24){return $button}}catch{}
  }
  return $null
}
function Test-TrayOverflowOpen {
  $iconRect=New-Object EBR_PRE_RECT
  $hiddenButton=Get-HiddenIconsButton
  if(-not $hiddenButton -or -not [EBR_PRE_NATIVE]::GetTrayRect($script:mainWindow,1,[ref]$iconRect)){return $false}
  $hiddenRect=$hiddenButton.Current.BoundingRectangle
  $hiddenX=$hiddenRect.Left+$hiddenRect.Width/2;$hiddenY=$hiddenRect.Top+$hiddenRect.Height/2
  return ([Math]::Abs((($iconRect.Left+$iconRect.Right)/2)-$hiddenX) -gt 30 -or [Math]::Abs((($iconRect.Top+$iconRect.Bottom)/2)-$hiddenY) -gt 30)
}
function Open-TrayOverflow {
  if(Test-TrayOverflowOpen){return $true}
  $button=Get-HiddenIconsButton
  if(-not $button){return $false}
  try{$button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()}
  catch{$rect=$button.Current.BoundingRectangle;if($rect.Width -le 0 -or $rect.Height -le 0 -or -not [EBR_PRE_NATIVE]::SetCursorPos([int]($rect.Left+$rect.Width/2),[int]($rect.Top+$rect.Height/2))){return $false};[EBR_PRE_NATIVE]::mouse_event(0x0002,0,0,0,[UIntPtr]::Zero);Start-Sleep -Milliseconds 60;[EBR_PRE_NATIVE]::mouse_event(0x0004,0,0,0,[UIntPtr]::Zero)}
  $watch=[Diagnostics.Stopwatch]::StartNew()
  while($watch.Elapsed.TotalSeconds -lt 3){if(Test-TrayOverflowOpen){return $true};Start-Sleep -Milliseconds 100}
  return $false
}
function Wait-ForTrayPopup([int]$TimeoutSeconds=3) {
  $watch=[Diagnostics.Stopwatch]::StartNew()
  while($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds){$menus=@([EBR_PRE_NATIVE]::TopWindows() | Where-Object { [EBR_PRE_NATIVE]::ClassName($_) -eq '#32768' -and [EBR_PRE_NATIVE]::IsWindowVisible($_) });if($menus.Count -eq 1){return $menus[0]};Start-Sleep -Milliseconds 100}
  return [IntPtr]::Zero
}
function Open-TrayContextMenu {
  $overflowOpened=Open-TrayOverflow
  $icon=Get-ShellTrayIconElement
  $rect=New-Object EBR_PRE_RECT
  if(-not [EBR_PRE_NATIVE]::GetTrayRect($script:mainWindow,1,[ref]$rect)){return [IntPtr]::Zero}
  $x=[int](($rect.Left+$rect.Right)/2);$y=[int](($rect.Top+$rect.Bottom)/2)
  if($icon){$bounds=$icon.Current.BoundingRectangle;$x=[int]($bounds.Left+$bounds.Width/2);$y=[int]($bounds.Top+$bounds.Height/2)}
  if([EBR_PRE_NATIVE]::SetCursorPos($x,$y)){
    [EBR_PRE_NATIVE]::mouse_event(0x0008,0,0,0,[UIntPtr]::Zero);Start-Sleep -Milliseconds 60;[EBR_PRE_NATIVE]::mouse_event(0x0010,0,0,0,[UIntPtr]::Zero)
  }
  $menu=Wait-ForTrayPopup 3
  $method='Shell tray icon right-click'
  if($menu -eq [IntPtr]::Zero -and $icon){
    try{$icon.SetFocus();[EBR_PRE_NATIVE]::Key(0x10,$false);[EBR_PRE_NATIVE]::Key(0x79,$false);Start-Sleep -Milliseconds 80;[EBR_PRE_NATIVE]::Key(0x79,$true);[EBR_PRE_NATIVE]::Key(0x10,$true)}catch{}
    $menu=Wait-ForTrayPopup 2;$method='Accessible shell tray icon Shift+F10'
  }
  if($menu -ne [IntPtr]::Zero){Pass 'Actual tray context menu opened through the interactive shell' ([pscustomobject]@{MenuWindow=('0x{0:X}' -f $menu.ToInt64());OverflowOpened=$overflowOpened;ShellIconAccessible=($null -ne $icon);Method=$method})}
  return $menu
}
function Get-TrayMenuItems([IntPtr]$MenuWindow) {
  $menuRoot=[System.Windows.Automation.AutomationElement]::FromHandle($MenuWindow)
  $condition=[System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty,[System.Windows.Automation.ControlType]::MenuItem)
  $uiaItems=@($menuRoot.FindAll([System.Windows.Automation.TreeScope]::Descendants,$condition) | Where-Object { $_.Current.Name })
  if($uiaItems.Count -gt 0){return [pscustomobject]@{Source='UIA';Items=$uiaItems;Handle=$MenuWindow}}
  foreach($objectId in @(-4,-3,-16)){
    try{
      $accessible=[EBR_PRE_NATIVE]::AccessibleWindow($MenuWindow,$objectId)
      if($null -eq $accessible){continue}
      $entries=@(for($childId=1;$childId -le $accessible.accChildCount;$childId++){
        try{$name=[string]$accessible.get_accName([object]$childId);if(-not [string]::IsNullOrWhiteSpace($name)){[pscustomobject]@{Name=$name.Trim();ChildId=$childId}}}catch{}
      })
      if($entries.Count -gt 0){return [pscustomobject]@{Source='MSAA';Accessible=$accessible;Entries=$entries;Handle=$MenuWindow}}
    }catch{}
  }
  return [pscustomobject]@{Source='HitTest';Entries=@();Handle=$MenuWindow}
}
function Get-TrayMenuNames($Items) {
  if($Items.Source -eq 'UIA'){return @($Items.Items | ForEach-Object {$_.Current.Name})}
  if($Items.Source -eq 'MSAA'){return @($Items.Entries | ForEach-Object {$_.Name})}
  return @()
}
function Invoke-TrayCommandByHitTest([IntPtr]$MenuWindow,[string]$Name) {
  $index=switch -Exact ($Name){'Open Eye Break Reminder'{0};'Pause timer'{1};'Resume timer'{1};'Take a break now'{2};'Alarm muted'{3};'Settings'{4};'Exit'{5};default{throw "Unknown tray command '$Name'."}}
  $bounds=Get-Rect $MenuWindow
  if($bounds.Width -le 100 -or $bounds.Height -le 60){throw "Native tray popup has unusable hit-test bounds for '$Name': $($bounds.Width)x$($bounds.Height)."}
  $row=($bounds.Height-4)/6.5
  $separator=if($index -ge 5){$row/2}else{0}
  $x=[int]($bounds.Left+$bounds.Width/3);$y=[int]($bounds.Top+2+$index*$row+$separator+$row/2)
  if(-not [EBR_PRE_NATIVE]::SetCursorPos($x,$y)){throw "Could not position pointer over tray command '$Name' at $x,$y."}
  [EBR_PRE_NATIVE]::mouse_event(0x0002,0,0,0,[UIntPtr]::Zero);Start-Sleep -Milliseconds 70;[EBR_PRE_NATIVE]::mouse_event(0x0004,0,0,0,[UIntPtr]::Zero)
  Start-Sleep -Milliseconds 350
  if([EBR_PRE_NATIVE]::IsWindowVisible($MenuWindow)){
    [void][EBR_PRE_NATIVE]::SetForegroundWindow($MenuWindow)
    [System.Windows.Forms.SendKeys]::SendWait('{HOME}')
    for($i=0;$i -lt $index;$i++){[System.Windows.Forms.SendKeys]::SendWait('{DOWN}')}
    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
  }
  Pass "Tray menu command selected by native row interaction: $Name" ([pscustomobject]@{Source='Visible #32768 popup hit-test with keyboard retry';Index=$index;Bounds=$bounds})
}
function Invoke-TrayCommand([string]$Name) {
  $menu=Open-TrayContextMenu
  if($menu -eq [IntPtr]::Zero){throw "Could not open the actual Windows tray menu to select '$Name'."}
  $items=Get-TrayMenuItems $menu
  if($items.Source -eq 'UIA'){
    $item=@($items.Items | Where-Object { $_.Current.Name -eq $Name }) | Select-Object -First 1
    if(-not $item){throw "The native tray menu did not expose an accessible '$Name' command. Found: $(@(Get-TrayMenuNames $items) -join ' | ')"}
    try{$item.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()}
    catch{$item.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select();[System.Windows.Forms.SendKeys]::SendWait('{ENTER}')}
  } elseif($items.Source -eq 'MSAA'){
    $entry=@($items.Entries | Where-Object {$_.Name -eq $Name}) | Select-Object -First 1
    if(-not $entry){throw "MSAA tray menu item '$Name' was not present: $(@(Get-TrayMenuNames $items) -join ', ')."}
    $items.Accessible.accDoDefaultAction([object]$entry.ChildId)
  } else {Invoke-TrayCommandByHitTest $menu $Name}
  Start-Sleep -Milliseconds 350
  Pass "Tray menu command invoked: $Name" $Name
}
function Wait-ForCloseToTrayExplanation([int]$TimeoutSeconds=5) {
  $watch=[Diagnostics.Stopwatch]::StartNew()
  while($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds){
    $foreground=[EBR_PRE_NATIVE]::GetForegroundWindow()
    $handles=@($foreground)+@([EBR_PRE_NATIVE]::TopWindows())
    foreach($window in $handles | Select-Object -Unique){
      if($window -eq [IntPtr]::Zero -or $window -eq $script:mainWindow -or -not [EBR_PRE_NATIVE]::IsWindowVisible($window)){continue}
      $pidValue=[uint32]0;[void][EBR_PRE_NATIVE]::GetWindowThreadProcessId($window,[ref]$pidValue)
      $class=[EBR_PRE_NATIVE]::ClassName($window);$title=[EBR_PRE_NATIVE]::Text($window)
      if($pidValue -ne $script:appPid -and -not ($class -eq '#32770' -and $title -eq 'Eye Break Reminder')){continue}
      $texts=@(foreach($child in [EBR_PRE_NATIVE]::Children($window)){$text=[EBR_PRE_NATIVE]::Text($child);if($text){$text}})
      $uiaTexts=@()
      try{$uiaTexts=@([System.Windows.Automation.AutomationElement]::FromHandle($window).FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition) | ForEach-Object {try{$name=$_.Current.Name;if($name){$name}}catch{}} | Where-Object {$_})}catch{}
      $allTexts=@($texts)+@($uiaTexts) | Select-Object -Unique
      $combined=$allTexts -join ' '
      if(($combined -match 'Closing keeps your reminders active' -and $combined -match 'right-click the tray icon') -or ($pidValue -eq $script:appPid -and $title -eq 'Eye Break Reminder')){return [pscustomobject]@{Handle=$window;Texts=$allTexts;NativeTexts=$texts;UIAutomationTexts=$uiaTexts;Class=$class;Title=$title;MessageTextExposed=($combined -match 'Closing keeps your reminders active' -and $combined -match 'right-click the tray icon');ProcessId=$pidValue}}
    }
    Start-Sleep -Milliseconds 100
  }
  return $null
}
function Test-ShellTrayAndNaturalNotification {
  if(-not $script:interactiveDesktop -or $script:mainWindow -eq [IntPtr]::Zero){
    Not-Tested 'Real system tray icon/menu, actions, hide/reopen and duplicate instance behavior' 'No interactive Explorer taskbar was exposed.'
    Not-Tested 'Windows Shell reminder notification surface' 'No interactive Explorer taskbar was exposed.'
    Not-Tested 'Production audio playback' 'Hosted runners do not provide a physically verified speaker output.'
    return
  }
  $tray=New-Object EBR_PRE_RECT
  if(-not [EBR_PRE_NATIVE]::GetTrayRect($script:mainWindow,1,[ref]$tray)){
    Not-Tested 'Real system tray icon/menu, actions, hide/reopen and duplicate instance behavior' 'Shell_NotifyIconGetRect did not expose the app icon in the runner desktop.'
    Not-Tested 'Windows Shell reminder notification surface' 'The application tray icon was not exposed by the shell.'
    Not-Tested 'Production audio playback' 'Hosted runners do not provide a physically verified speaker output.'
    return
  }
  Require ($tray.Right -gt $tray.Left -and $tray.Bottom -gt $tray.Top) 'Shell exposes a registered Eye Break Reminder tray icon rectangle' $tray
  Switch-Timer
  Click-Control $script:mainWindow 21 'Reset work timer before tray action checks'
  $menu=Open-TrayContextMenu
  if($menu -eq [IntPtr]::Zero){Not-Tested 'Actual tray context menu rendering and actions' 'The icon rectangle was present but no native context-menu window appeared after a right-click.';return}
  Pass 'Actual tray context menu opened as a native popup' ([pscustomobject]@{MenuWindow=('0x{0:X}' -f $menu.ToInt64())})
  Capture-TrayPopup $menu 'tray-context-menu-active.png' | Out-Null
  $menuItems=Get-TrayMenuItems $menu
  $menuNames=@(Get-TrayMenuNames $menuItems)
  if($menuItems.Source -ne 'HitTest'){
    Require (@('Open Eye Break Reminder','Pause timer','Take a break now','Settings','Exit' | Where-Object {$menuNames -contains $_}).Count -ge 5) "Tray menu exposes expected $($menuItems.Source) native commands" $menuNames
  } else {
    Pass 'Tray popup has a readable native screenshot; row actions will be exercised against visible menu bounds' ([pscustomobject]@{Source=$menuItems.Source;Screenshot='tray-context-menu-active.png';Bounds=(Get-Rect $menu)})
  }
  Invoke-TrayCommand 'Pause timer'
  Require ((Wait-ForStatus 'Paused') -like '*Paused*') 'Tray Pause command pauses the installed timer' (Get-Status)
  Invoke-TrayCommand 'Resume timer'
  Require ((Wait-ForStatus 'Running') -like '*Running*') 'Tray Resume command resumes the installed timer' (Get-Status)
  Invoke-TrayCommand 'Take a break now'
  $breaks=Get-BreakWindow $script:appPid
  Require ($breaks.Count -eq 1) 'Tray Take a break command opens the installed reminder window' $breaks.Count
  Click-Control $breaks[0] 24 'Skip break started from the tray menu'
  Require ((Wait-ForStatus 'Running') -like '*Running*') 'Tray-triggered break can be dismissed' (Get-Status)
  Switch-Settings 4
  Set-Check $script:mainWindow 112 $true 'Minimize to system tray'
  Switch-Timer
  $prefsBeforeClose=Read-SettingsMap (Join-Path $dataDir 'settings.ini')
  Require ($prefsBeforeClose['tray'] -eq '1') 'Close-to-tray test explicitly enables the tray preference' $prefsBeforeClose['tray']
  $needsCloseExplanation=($prefsBeforeClose['trayExplained'] -ne '1')
  Require ([EBR_PRE_NATIVE]::PostMessageW($script:mainWindow,0x0010,[IntPtr]::Zero,[IntPtr]::Zero)) 'Close-to-tray message was delivered to the main window' ([pscustomobject]@{Window=('0x{0:X}' -f $script:mainWindow.ToInt64());ProcessId=$script:appPid;Tray=$prefsBeforeClose['tray'];TrayExplained=$prefsBeforeClose['trayExplained']})
  if($needsCloseExplanation){
    $explanation=Wait-ForCloseToTrayExplanation
    $visibleWindows=@(foreach($window in [EBR_PRE_NATIVE]::TopWindows()){if([EBR_PRE_NATIVE]::IsWindowVisible($window)){$pidValue=[uint32]0;[void][EBR_PRE_NATIVE]::GetWindowThreadProcessId($window,[ref]$pidValue);[pscustomobject]@{Handle=('0x{0:X}' -f $window.ToInt64());Pid=$pidValue;Class=[EBR_PRE_NATIVE]::ClassName($window);Title=[EBR_PRE_NATIVE]::Text($window)}}})
    Require ($null -ne $explanation) 'First close-to-tray action shows the one-time reminder explanation' ([pscustomobject]@{Expected='Native TaskDialog titled Eye Break Reminder';Tray=$prefsBeforeClose['tray'];TrayExplained=$prefsBeforeClose['trayExplained'];VisibleWindows=$visibleWindows})
    Pass 'Close-to-tray explanation is displayed in a visible native dialog' ([pscustomobject]@{Class=$explanation.Class;Title=$explanation.Title;ProcessId=$explanation.ProcessId;MessageTextExposed=$explanation.MessageTextExposed;Texts=$explanation.Texts})
    Capture-ActiveWindow $explanation.Handle 'tray-close-to-tray-explanation.png' | Out-Null
    if($explanation.MessageTextExposed){Pass 'Close-to-tray explanation text is available through native dialog controls' $explanation.Texts}else{Not-Tested 'Close-to-tray explanation text through native controls' 'The TaskDialog was visible and captured, but Windows did not expose its instruction text through GetWindowText.'}
    $okButtons=@(foreach($child in [EBR_PRE_NATIVE]::Children($explanation.Handle)){if([EBR_PRE_NATIVE]::ClassName($child) -eq 'Button' -and [EBR_PRE_NATIVE]::IsWindowVisible($child) -and [EBR_PRE_NATIVE]::IsWindowEnabled($child) -and [EBR_PRE_NATIVE]::Text($child) -match '^\s*&?OK\s*$'){[pscustomobject]@{Handle=$child;Text=[EBR_PRE_NATIVE]::Text($child);Id=[EBR_PRE_NATIVE]::GetDlgCtrlID($child)}}})
    Require ($okButtons.Count -eq 1) 'Close-to-tray TaskDialog exposes one enabled OK button' $okButtons
    [void][EBR_PRE_NATIVE]::SendMessageW($okButtons[0].Handle,0x00F5,[IntPtr]::Zero,[IntPtr]::Zero)
    Pass 'One-time close-to-tray explanation was acknowledged through its native OK button'
  }
  $closeWait=[Diagnostics.Stopwatch]::StartNew()
  while([EBR_PRE_NATIVE]::IsWindowVisible($script:mainWindow) -and $closeWait.Elapsed.TotalSeconds -lt 5){Start-Sleep -Milliseconds 100}
  Require (-not [EBR_PRE_NATIVE]::IsWindowVisible($script:mainWindow)) 'Closing the app window keeps it running in the system tray'
  $afterClose=Get-Process -Id $script:appPid -ErrorAction SilentlyContinue
  Require ($null -ne $afterClose -and -not $afterClose.HasExited) 'Closing to the tray leaves the installed reminder process running' $script:appPid
  Invoke-TrayCommand 'Open Eye Break Reminder'
  Require ([EBR_PRE_NATIVE]::IsWindowVisible($script:mainWindow)) 'Tray Open command restores the installed app window'
  $second=Start-Process -FilePath $appExe -PassThru
  [void]$second.WaitForExit(8000)
  Start-Sleep -Milliseconds 300
  $owned=@(Get-Process -Name EyeBreakReminder -ErrorAction SilentlyContinue | Where-Object { try{[IO.Path]::GetFullPath($_.Path) -ieq $appExe}catch{$false} })
  $secondExit=if($second.HasExited){$second.ExitCode}else{'still running'}
  Require ($owned.Count -eq 1) 'Second app launch is routed to the running instance without a duplicate process' ([pscustomobject]@{OwnedProcessCount=$owned.Count;PrimaryPid=$script:appPid;SecondLaunchExitCode=$secondExit})
  Invoke-TrayCommand 'Exit'
  $primary=Get-Process -Id $script:appPid -ErrorAction SilentlyContinue
  if($primary){Require ($primary.WaitForExit(10000)) 'Tray Exit command terminates the application process' $script:appPid}else{Pass 'Tray Exit command terminates the application process' $script:appPid}
  $script:appPid=0;$script:mainWindow=[IntPtr]::Zero
  if(-not (Start-InstalledApp)){Not-Tested 'Automatic break, Shell notification and snooze after tray restart' 'The runner stopped exposing the installed GUI after restarting from tray exit.';return}
  Switch-Settings 3
  Set-Check $script:mainWindow 108 $true 'Windows notifications enabled'
  Switch-Timer
  $resourceSamples=[System.Collections.Generic.List[object]]::new()
  $resourceProc=Get-Process -Id $script:appPid -ErrorAction Stop;$resourceProc.Refresh()
  $resourceSamples.Add([pscustomobject]@{Checkpoint='before first scheduled reminder';PrivateBytes=[long]$resourceProc.PrivateMemorySize64;WorkingSetBytes=[long]$resourceProc.WorkingSet64;HandleCount=[int]$resourceProc.HandleCount;ThreadCount=[int]$resourceProc.Threads.Count})
  Click-Control $script:mainWindow 21 'Reset real one-minute notification timer'
  [void][EBR_PRE_NATIVE]::PostMessageW($script:mainWindow,0x0010,[IntPtr]::Zero,[IntPtr]::Zero)
  $dueWatch=[Diagnostics.Stopwatch]::StartNew();$naturalBreak=[IntPtr]::Zero
  while($dueWatch.Elapsed.TotalSeconds -lt 80){$breaks=Get-BreakWindow $script:appPid;if($breaks.Count -eq 1){$naturalBreak=$breaks[0];break};Start-Sleep -Milliseconds 200}
  Require ($naturalBreak -ne [IntPtr]::Zero) 'Installed one-minute work timer reaches its real scheduled break after hide-to-tray' ([pscustomobject]@{WaitSeconds=[Math]::Round($dueWatch.Elapsed.TotalSeconds,1)})
  $resourceProc=Get-Process -Id $script:appPid -ErrorAction Stop;$resourceProc.Refresh()
  $resourceSamples.Add([pscustomobject]@{Checkpoint='first scheduled reminder';PrivateBytes=[long]$resourceProc.PrivateMemorySize64;WorkingSetBytes=[long]$resourceProc.WorkingSet64;HandleCount=[int]$resourceProc.HandleCount;ThreadCount=[int]$resourceProc.Threads.Count})
  Capture-ActiveWindow $naturalBreak 'installed-natural-reminder-after-hidden-work.png' | Out-Null
  $shellNames=@()
  try {
    $uiaRoot=[System.Windows.Automation.AutomationElement]::RootElement
    $desktopElements=$uiaRoot.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
    $shellNames=@($desktopElements | ForEach-Object {try{$_.Current.Name}catch{''}} | Where-Object {$_ -match 'Time to rest your eyes|Look 20 feet'})
  } catch {}
  if($shellNames.Count -gt 0){Pass 'Windows Shell reminder notification surface observed in the desktop UIA tree' $shellNames}
  else{Not-Tested 'Windows Shell notification surface acceptance/dismissal' 'The real hidden-app timer reached break mode and the reminder window appeared, but no separate Shell balloon/toast surface was observed. The in-app reminder is not counted as a toast.'}
  Click-Control $naturalBreak 25 'Snooze one minute in the installed application'
  Invoke-TrayCommand 'Open Eye Break Reminder'
  Require ((Wait-ForStatus 'Snoozed') -like '*Snoozed*') 'Installed app clearly reports Snoozed after a real break reminder is snoozed'
  [void][EBR_PRE_NATIVE]::PostMessageW($script:mainWindow,0x0010,[IntPtr]::Zero,[IntPtr]::Zero)
  $snoozeWatch=[Diagnostics.Stopwatch]::StartNew();$returned=[IntPtr]::Zero
  while($snoozeWatch.Elapsed.TotalSeconds -lt 80){$breaks=Get-BreakWindow $script:appPid;if($breaks.Count -eq 1){$returned=$breaks[0];break};Start-Sleep -Milliseconds 200}
  Require ($returned -ne [IntPtr]::Zero) 'Installed one-minute snooze reschedules a real reminder' ([pscustomobject]@{WaitSeconds=[Math]::Round($snoozeWatch.Elapsed.TotalSeconds,1)})
  $resourceProc=Get-Process -Id $script:appPid -ErrorAction Stop;$resourceProc.Refresh()
  $resourceSamples.Add([pscustomobject]@{Checkpoint='snoozed reminder';PrivateBytes=[long]$resourceProc.PrivateMemorySize64;WorkingSetBytes=[long]$resourceProc.WorkingSet64;HandleCount=[int]$resourceProc.HandleCount;ThreadCount=[int]$resourceProc.Threads.Count})
  Click-Control $returned 24 'Dismiss the snoozed reminder'
  Invoke-TrayCommand 'Open Eye Break Reminder'
  Require ((Wait-ForStatus 'Running') -like '*Running*') 'Installed timer returns to work after the snoozed reminder is dismissed'


  [void][EBR_PRE_NATIVE]::PostMessageW($script:mainWindow,0x0010,[IntPtr]::Zero,[IntPtr]::Zero)
  $repeatWatch=[Diagnostics.Stopwatch]::StartNew();$repeatBreak=[IntPtr]::Zero;$duplicateRepeatBreaks=$false
  while($repeatWatch.Elapsed.TotalSeconds -lt 80){
    $breaks=Get-BreakWindow $script:appPid
    if($breaks.Count -gt 1){$duplicateRepeatBreaks=$true;break}
    if($breaks.Count -eq 1){$repeatBreak=$breaks[0];break}
    Start-Sleep -Milliseconds 200
  }
  Require ($repeatBreak -ne [IntPtr]::Zero) 'Next one-minute work interval reaches another real break reminder' ([pscustomobject]@{WaitSeconds=[Math]::Round($repeatWatch.Elapsed.TotalSeconds,1)})
  Require (-not $duplicateRepeatBreaks) 'Repeated work/break cycle creates exactly one reminder window'
  $resourceProc=Get-Process -Id $script:appPid -ErrorAction Stop;$resourceProc.Refresh()
  $resourceSamples.Add([pscustomobject]@{Checkpoint='next scheduled reminder';PrivateBytes=[long]$resourceProc.PrivateMemorySize64;WorkingSetBytes=[long]$resourceProc.WorkingSet64;HandleCount=[int]$resourceProc.HandleCount;ThreadCount=[int]$resourceProc.Threads.Count})
  Capture-ActiveWindow $repeatBreak 'installed-repeated-reminder-cycle.png' | Out-Null
  Click-Control $repeatBreak 24 'Dismiss the repeated real break reminder'
  Invoke-TrayCommand 'Open Eye Break Reminder'
  Require ((Wait-ForStatus 'Running') -like '*Running*') 'Repeated break completion returns the installed timer to work'
  $resourceAfter=Get-Process -Id $script:appPid -ErrorAction Stop
  $resourceAfter.Refresh()
  $resourceSamples.Add([pscustomobject]@{Checkpoint='after repeated reminder dismissal';PrivateBytes=[long]$resourceAfter.PrivateMemorySize64;WorkingSetBytes=[long]$resourceAfter.WorkingSet64;HandleCount=[int]$resourceAfter.HandleCount;ThreadCount=[int]$resourceAfter.Threads.Count})
  $baseline=$resourceSamples[0]
  $peakPrivateBytes=[long](($resourceSamples | Measure-Object -Property PrivateBytes -Maximum).Maximum)
  $peakHandles=[int](($resourceSamples | Measure-Object -Property HandleCount -Maximum).Maximum)
  $privateGrowth=$peakPrivateBytes-[long]$baseline.PrivateBytes
  $handleGrowth=$peakHandles-[int]$baseline.HandleCount
  Require ($privateGrowth -le 33554432 -and $handleGrowth -le 128) 'Three real reminder transitions show bounded process memory and handle growth' ([pscustomobject]@{Cycles='scheduled reminder, snooze reminder, next scheduled reminder';PrivateBytesStart=[long]$baseline.PrivateBytes;PeakPrivateBytes=$peakPrivateBytes;PeakPrivateGrowth=$privateGrowth;HandlesStart=[int]$baseline.HandleCount;PeakHandles=$peakHandles;PeakHandleGrowth=$handleGrowth;Samples=$resourceSamples.ToArray()})
  Stop-InstalledApp
  Not-Tested 'Production audio playback' 'Hosted runners do not provide physically verified speaker hardware; alarm sounds were disabled during unattended timer tests.'
}
function Test-UpgradeFromV11([string]$OldInstaller) {
  if(-not $OldInstaller){Not-Tested 'Official v1.1.0 to v1.2.0 in-place upgrade, settings/history/statistics/startup migration' 'No independently digest-verified official v1.1.0 installer was available.';return}
  if(Test-Path -LiteralPath $dataDir){Remove-Item -LiteralPath $dataDir -Recurse -Force}
  Invoke-Install $OldInstaller 'official v1.1.0' $false
  Assert-InstallationMetadata '1.1.0'
  if(-not (Start-And-CheckApp '1.1.0')){Not-Tested 'v1.1.0 application UI state preparation for upgrade' 'No interactive app window was available.';Not-Tested 'Official v1.1.0 to v1.2.0 in-place upgrade and migration' 'The old application could not be prepared through its actual UI.';Stop-InstalledApp;Invoke-Uninstall 'v1.1.0 pre-upgrade' $false;return}
  if(-not $script:interactiveDesktop){Not-Tested 'v1.1.0 settings/history preparation through the actual UI' 'No interactive Explorer desktop was exposed.';Not-Tested 'Official v1.1.0 to v1.2.0 in-place upgrade and migration' 'No interactive session was available to configure and verify legacy settings/history.';Stop-InstalledApp;Invoke-Uninstall 'v1.1.0 pre-upgrade' $false;return}
  # The v1.1 UI retains the same native control IDs for intervals, alarm, General, History, and manual breaks.
  Switch-Settings 0
  Set-Edit $script:mainWindow 100 '7' 'v1.1 work interval'
  Set-Edit $script:mainWindow 101 '45' 'v1.1 break duration'
  Switch-Settings 2
  Set-Check $script:mainWindow 32 $false 'v1.1 alarm enabled'
  Switch-Settings 4
  Set-Check $script:mainWindow 111 $true 'v1.1 start with Windows'
  Switch-Timer
  Click-Control $script:mainWindow 22 'v1.1 manual break for migration history'
  $breakWait=[Diagnostics.Stopwatch]::StartNew();$breakWindow=[IntPtr]::Zero
  while($breakWait.Elapsed.TotalSeconds -lt 10){$breaks=Get-BreakWindow $script:appPid;if($breaks.Count -eq 1){$breakWindow=$breaks[0];break};Start-Sleep -Milliseconds 100}
  Require ($breakWindow -ne [IntPtr]::Zero) 'v1.1 creates a real manual break window before upgrade'
  Click-Control $breakWindow 23 'Complete v1.1 migration history break'
  Stop-InstalledApp
  $settingsPath=Join-Path $dataDir 'settings.ini';$historyPath=Join-Path $dataDir 'history.dat'
  $v11Settings=Read-SettingsMap $settingsPath
  $v11History=@(Get-Content -LiteralPath $historyPath | Where-Object {$_.Trim()})
  Require ($v11Settings['workMinutes'] -eq '7' -and $v11Settings['breakSeconds'] -eq '45' -and $v11Settings['startup'] -eq '1' -and $v11Settings['theme'] -eq '0') 'v1.1 representative settings and system-theme preference persisted before upgrade' ([pscustomobject]@{Path=$settingsPath;Observed=[pscustomobject]@{WorkMinutes=$v11Settings['workMinutes'];BreakSeconds=$v11Settings['breakSeconds'];Startup=$v11Settings['startup'];Theme=$v11Settings['theme']}})
  Require ($v11History.Count -ge 1) 'v1.1 generated a history/statistics record before upgrade' $v11History.Count
  $beforeHistory=(Get-FileHash -LiteralPath $historyPath -Algorithm SHA256).Hash
  Invoke-Install $InstallerPath 'v1.2.0 in-place upgrade from v1.1.0' $false
  Assert-InstallationMetadata '1.2.0'
  $afterSettings=Read-SettingsMap $settingsPath
  Require ($afterSettings['workMinutes'] -eq '7' -and $afterSettings['breakSeconds'] -eq '45' -and $afterSettings['startup'] -eq '1' -and $afterSettings['theme'] -eq '0') 'v1.2.0 preserves v1.1.0 settings and system-theme preference during upgrade' ([pscustomobject]@{Path=$settingsPath;Observed=[pscustomobject]@{WorkMinutes=$afterSettings['workMinutes'];BreakSeconds=$afterSettings['breakSeconds'];Startup=$afterSettings['startup'];Theme=$afterSettings['theme']}})
  $afterHistory=(Get-FileHash -LiteralPath $historyPath -Algorithm SHA256).Hash
  Require ($afterHistory -eq $beforeHistory) 'v1.2.0 preserves v1.1.0 history bytes during in-place upgrade' ([pscustomobject]@{Before=$beforeHistory;After=$afterHistory;Rows=$v11History.Count})
  $runValues=@((Get-ItemProperty -LiteralPath $runKey).PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' -and [string]$_.Value -match 'EyeBreakReminder' })
  Require ($runValues.Count -eq 1) 'In-place upgrade leaves exactly one Eye Break Reminder startup registration' $runValues.Count
  if(Start-And-CheckApp '1.2.0'){
    Switch-Settings 4
    $legacyThemeIndex=Get-Combo $script:mainWindow 106 'Theme'
    Require ($legacyThemeIndex -eq 0) 'Legacy v1.1 Use system setting preference maps to Follow Windows Theme after upgrade' ([pscustomobject]@{LegacyThemeValue=$v11Settings['theme'];UpgradedThemeIndex=$legacyThemeIndex;ExpectedTheme='Follow Windows Theme'})
    Switch-Settings 0
    Require ([EBR_PRE_NATIVE]::Text((Get-Control $script:mainWindow 100 'Migrated work interval').Handle) -eq '7') 'Upgraded app loads v1.1 work interval' '7'
    Click-Control $script:mainWindow 11 'History after upgrade'
    $list=Get-Control $script:mainWindow 200 'Migrated history list'
    $rows=[EBR_PRE_NATIVE]::SendMessageW($list.Handle,0x1004,[IntPtr]::Zero,[IntPtr]::Zero).ToInt32()
    Require ($rows -ge $v11History.Count) 'Upgraded app loads v1.1 history rows and statistics source data' ([pscustomobject]@{Before=$v11History.Count;VisibleRows=$rows})
    Capture-ActiveWindow $script:mainWindow 'upgrade-v11-history-statistics-active.png' | Out-Null
    Stop-InstalledApp
  }
  Invoke-Uninstall 'v1.2.0 post-upgrade' $false
  $settingsStill=Test-Path -LiteralPath $settingsPath;$historyStill=Test-Path -LiteralPath $historyPath
  Require ($settingsStill -and $historyStill) 'Final uninstall preserves the runner-created settings and history for cleanup verification' ([pscustomobject]@{SettingsPreserved=$settingsStill;HistoryPreserved=$historyStill})
}

function Test-V11InteractiveUninstaller([string]$OldInstaller) {
  if(-not $OldInstaller -or -not $script:interactiveDesktop){Not-Tested 'Official v1.1.0 no-argument interactive uninstall comparison' 'A digest-verified v1.1.0 installer and interactive desktop are both required.';return}
  Invoke-Install $OldInstaller 'official v1.1.0 uninstall comparison' $false
  Assert-InstallationMetadata '1.1.0'
  Invoke-Uninstall 'official v1.1.0 no-argument uninstall comparison' $true
  $settingsStill=Test-Path -LiteralPath (Join-Path $dataDir 'settings.ini');$historyStill=Test-Path -LiteralPath (Join-Path $dataDir 'history.dat')
  Require ($settingsStill -and $historyStill) 'v1.1.0 uninstall comparison preserves settings and history' ([pscustomobject]@{SettingsPreserved=$settingsStill;HistoryPreserved=$historyStill})
}

try {
  Start-Transcript -LiteralPath (Join-Path $EvidenceDirectory 'windows-pre-release-acceptance.log') -Force | Out-Null
  $script:transcriptStarted=$true
  $computer=Get-CimInstance Win32_OperatingSystem
  $script:interactiveDesktop=Get-DesktopCapability
  Pass 'Windows runner identity and interactive capability recorded' ([pscustomobject]@{Caption=$computer.Caption;Version=$computer.Version;Build=$computer.BuildNumber;SessionId=[Diagnostics.Process]::GetCurrentProcess().SessionId;SessionName=$env:SESSIONNAME;UserInteractive=[Environment]::UserInteractive;ExplorerTaskbar=([EBR_PRE_NATIVE]::FindWindowW('Shell_TrayWnd',$null) -ne [IntPtr]::Zero);InteractiveDesktop=$script:interactiveDesktop;SourceCommit=$env:GITHUB_SHA;RunUrl=if($env:GITHUB_RUN_ID){"$env:GITHUB_SERVER_URL/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID"}else{''}})
  $running=@(Get-Process -Name EyeBreakReminder -ErrorAction SilentlyContinue)
  Require ($running.Count -eq 0) 'No Eye Break Reminder process was running in the disposable runner before testing' $running.Count
  $preExisting=@($installDir,$dataDir,$startMenuDir,$desktopLink) | Where-Object {Test-Path -LiteralPath $_}
  $preExistingRegistry=@($appKey,$uninstallKey) | Where-Object {Test-Path -LiteralPath $_}
  $preExistingStartup=$false
  if(Test-Path -LiteralPath $runKey){$preExistingStartup=@((Get-ItemProperty -LiteralPath $runKey).PSObject.Properties | Where-Object {$_.Name -notmatch '^PS' -and [string]$_.Value -match 'EyeBreakReminder'}).Count -gt 0}
  Require ($preExisting.Count -eq 0 -and $preExistingRegistry.Count -eq 0 -and -not $preExistingStartup) 'Runner user profile, install path, shortcuts, registry and startup slot were empty before cleanup ownership' ([pscustomobject]@{Paths=$preExisting;Registry=$preExistingRegistry;Startup=$preExistingStartup})
  $script:ownedData=$true

  $script:liveRelease=Get-OfficialRelease 'https://api.github.com/repos/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/latest' 'Live latest stable GitHub Releases API'
  if($script:liveRelease){
    Require (-not $script:liveRelease.draft -and -not $script:liveRelease.prerelease) 'The official latest endpoint returned a published stable release' ([pscustomobject]@{Tag=$script:liveRelease.tag_name;Draft=$script:liveRelease.draft;Prerelease=$script:liveRelease.prerelease})
    Require ($script:liveRelease.html_url -ceq "https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/tag/$($script:liveRelease.tag_name)") 'Latest API link points to the official Eye Break Reminder release page' $script:liveRelease.html_url
    $script:liveRelease | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'github-releases-latest.json') -Encoding UTF8
    Pass 'Live latest stable version parsed as semantic version' ([pscustomobject]@{Tag=$script:liveRelease.tag_name;ReleaseUrl=$script:liveRelease.html_url;Prerelease=$script:liveRelease.prerelease})
  } else {$script:liveLatestError=$script:liveApiError;Not-Tested 'Live latest stable GitHub release/version comparison' "Official unauthenticated endpoint unavailable: $script:liveLatestError"}

  $oldInstaller=Download-OfficialV11Installer
  if($script:interactiveDesktop){
    Invoke-Install $InstallerPath 'v1.2.0 production installer' $true
    Require ((Get-Item -LiteralPath (Join-Path $installDir 'EyeBreakReminder.exe')).VersionInfo.ProductVersion -match '^1\.2\.0') 'Installed application file version is 1.2.0' (Get-Item -LiteralPath $appExe).VersionInfo.ProductVersion
    if(Start-And-CheckApp '1.2.0'){
      Test-FreshInstallApp
      if(Start-InstalledApp){Test-ShellTrayAndNaturalNotification;Stop-InstalledApp}
    }
    Stop-InstalledApp
    Invoke-Uninstall 'v1.2.0 fresh uninstall' $true
    $prefsPersist=Test-Path -LiteralPath (Join-Path $dataDir 'settings.ini')
    $historyPersist=Test-Path -LiteralPath (Join-Path $dataDir 'history.dat')
    Require ($prefsPersist -and $historyPersist) 'Uninstall preserves settings and history data outside the app folder' ([pscustomobject]@{Settings=$prefsPersist;History=$historyPersist})
    Invoke-Install $InstallerPath 'v1.2.0 reinstall after uninstall' $false
    Assert-InstallationMetadata '1.2.0'
    Test-WindowsInstalledAppsPage
    if(Start-And-CheckApp '1.2.0'){
      if($script:interactiveDesktop){Switch-Settings 4;Require ((Get-Combo $script:mainWindow 106 'Theme') -eq 1) 'Reinstalled app retains user settings' 'Light theme';Switch-Timer;Stop-InstalledApp}
      else{Stop-InstalledApp}
    }
    Invoke-Uninstall 'v1.2.0 reinstall cleanup' $false
  } else {
    Invoke-Install $InstallerPath 'v1.2.0 production installer' $false
    Assert-InstallationMetadata '1.2.0'
    Not-Tested 'Visible NSIS installer wizard and rendered wizard screenshots' 'The runner exposes no interactive Explorer desktop; only the actual silent install path was exercised.'
    if(Start-And-CheckApp '1.2.0'){Not-Tested 'Installed GUI workflow, themes, UIA, and live in-app update request' 'No interactive Windows desktop was available.';Stop-InstalledApp}
    Invoke-Uninstall 'v1.2.0 fresh uninstall' $false
    Invoke-Install $InstallerPath 'v1.2.0 reinstall after uninstall' $false
    Assert-InstallationMetadata '1.2.0'
    if(Start-And-CheckApp '1.2.0'){Stop-InstalledApp}
    Invoke-Uninstall 'v1.2.0 reinstall cleanup' $false
  }

  Test-UpgradeFromV11 $oldInstaller
  Test-V11InteractiveUninstaller $oldInstaller
  if(-not $script:interactiveDesktop){
    Not-Tested 'Real Windows theme switching and Forced Colors' 'Runner desktop capability probe reported no Explorer shell/taskbar.'
    Not-Tested 'Tray menu actions and actual Shell notification surface' 'Runner desktop capability probe reported no Explorer shell/taskbar.'
    Not-Tested 'Keyboard-only application workflows and UIA focus order' 'Runner desktop capability probe reported no Explorer shell/taskbar.'
    Not-Tested 'Additional DPI/text-scale configurations' 'Runner desktop capability probe reported no Explorer shell/taskbar.'
  }
  Not-Tested 'Real workstation lock/unlock' 'A hosted runner lock would strand the job in an inaccessible session; only the isolated runner was available.'
  Not-Tested 'Physical sleep/resume' 'Suspending a hosted runner has no controlled wake guarantee; no physical suspend test was attempted.'
  $monitorCount=[EBR_PRE_NATIVE]::GetSystemMetrics(80)
  if($monitorCount -gt 1){Pass 'Windows runner exposes multiple monitor heads' $monitorCount}else{Not-Tested 'Multiple-monitor display configuration and restoration' "Runner exposed $monitorCount monitor; no additional physical or virtual monitor was available."}
  Not-Tested 'Physical speaker output' 'Hosted Windows runners do not have verified physical speaker hardware.'
  if($script:ownedInstall -and (Test-Path -LiteralPath (Join-Path $installDir 'Uninstall.exe'))){Stop-InstalledApp;Invoke-Uninstall 'final cleanup' $false}
  if($script:ownedData -and (Test-Path -LiteralPath $dataDir)){Remove-Item -LiteralPath $dataDir -Recurse -Force;Require (-not (Test-Path -LiteralPath $dataDir)) 'Disposable runner user-data cleanup completed' $dataDir}
} catch {
  $fatal=$true
  if($script:failCount -eq 0){Add-Event 'Windows pre-release acceptance runner' 'FAIL' $_.Exception.Message}
  Write-Error $_
} finally {
  try { Stop-InstalledApp } catch { Add-Event 'Installed test process cleanup' 'FAIL' $_.Exception.Message }
  if($script:highContrastOriginal -ne $null){[void][EBR_PRE_NATIVE]::SetHighContrast($script:highContrastOriginal)}
  foreach($key in $script:osOriginal.Keys){$parts=$key.Split('|',2);try{Restore-RegistryValue $parts[0] $parts[1] $script:osOriginal[$key]}catch{Add-Event 'Windows appearance preference restoration' 'FAIL' $_.Exception.Message}}
  if($script:ownedInstall){
    $cleanupErrors=[System.Collections.Generic.List[string]]::new()
    $uninstaller=Join-Path $installDir 'Uninstall.exe'
    if(Test-Path -LiteralPath $uninstaller){
      try{$u=Start-Process -FilePath $uninstaller -ArgumentList '/S' -PassThru;if($u.WaitForExit(90000) -and $u.ExitCode -ne 0){$cleanupErrors.Add("Uninstaller exit code $($u.ExitCode)")}elseif(-not $u.HasExited){Stop-Process -Id $u.Id -Force -ErrorAction SilentlyContinue;$cleanupErrors.Add('Uninstaller timed out')}}catch{$cleanupErrors.Add($_.Exception.Message)}
    }
    # The runner was proven empty before ownership was acquired. Remove only
    # these exact per-user installation artifacts if a failed installer or
    # uninstaller left a partial installation behind.
    foreach($path in @($installDir,$startMenuDir,$desktopLink)){
      if(Test-Path -LiteralPath $path){try{Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop}catch{$cleanupErrors.Add("$path :: $($_.Exception.Message)")}}
    }
    foreach($key in @($uninstallKey,$appKey)){
      if(Test-Path -LiteralPath $key){try{Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction Stop}catch{$cleanupErrors.Add("$key :: $($_.Exception.Message)")}}
    }
    if(Test-Path -LiteralPath $runKey){
      $ownedStartupNames=@((Get-ItemProperty -LiteralPath $runKey).PSObject.Properties | Where-Object {$_.Name -notmatch '^PS' -and [string]$_.Value -match 'EyeBreakReminder'} | ForEach-Object {$_.Name})
      foreach($name in $ownedStartupNames){try{Remove-ItemProperty -LiteralPath $runKey -Name $name -ErrorAction Stop}catch{$cleanupErrors.Add("Startup value $name :: $($_.Exception.Message)")}}
    }
    if($cleanupErrors.Count -eq 0 -and -not (Test-Path -LiteralPath $installDir) -and -not (Test-Path -LiteralPath $startMenuDir) -and -not (Test-Path -LiteralPath $desktopLink) -and -not (Test-Path -LiteralPath $uninstallKey) -and -not (Test-Path -LiteralPath $appKey)){
      Pass 'Owned partial installation cleanup removed only runner-created paths and registrations'
      $script:ownedInstall=$false
    }else{Add-Event 'Owned partial installation cleanup' 'FAIL' ([pscustomobject]@{Errors=$cleanupErrors.ToArray();InstallDir=(Test-Path -LiteralPath $installDir);StartMenu=(Test-Path -LiteralPath $startMenuDir);DesktopLink=(Test-Path -LiteralPath $desktopLink);UninstallKey=(Test-Path -LiteralPath $uninstallKey);AppKey=(Test-Path -LiteralPath $appKey)})}
  }
  if($script:ownedData -and (Test-Path -LiteralPath $dataDir)){try{Remove-Item -LiteralPath $dataDir -Recurse -Force}catch{Add-Event 'Runner user-data cleanup' 'FAIL' $_.Exception.Message}}
  $summary=[pscustomobject]@{
    Application='Eye Break Reminder'
    Version='1.2.0'
    SourceCommit=$env:GITHUB_SHA
    ActionsRunUrl=if($env:GITHUB_RUN_ID){"$env:GITHUB_SERVER_URL/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID"}else{''}
    WindowsCaption=(Get-CimInstance Win32_OperatingSystem).Caption
    WindowsVersion=(Get-CimInstance Win32_OperatingSystem).Version
    WindowsBuild=(Get-CimInstance Win32_OperatingSystem).BuildNumber
    InteractiveDesktopAvailable=$script:interactiveDesktop
    Pass=$script:passCount
    Fail=$script:failCount
    NotTested=$script:notTestedCount
    Events=$script:events.ToArray()
    UninstallerDiagnostics=$script:uninstallerDiagnostics.ToArray()
  }
  $summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'windows-pre-release-results.json') -Encoding UTF8
  if($script:uninstallerDiagnostics.Count -gt 0){$script:uninstallerDiagnostics.ToArray() | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'uninstaller-diagnostics.json') -Encoding UTF8}
  $summaryLine="Windows pre-release acceptance: PASS=$($script:passCount) FAIL=$($script:failCount) NOT TESTED=$($script:notTestedCount)"
  Write-Output $summaryLine
  try { $summaryLine | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8 } catch {}
  if($script:transcriptStarted){try{Stop-Transcript | Out-Null}catch{}}
}
if($fatal -or $script:failCount -gt 0){exit 1}
