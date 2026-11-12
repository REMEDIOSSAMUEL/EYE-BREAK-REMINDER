param(
  [string]$StandalonePath = (Join-Path $env:RUNNER_TEMP 'eye-break-reminder-v1.2.0-published-assets\EyeBreakReminder.exe'),
  [string]$PortableExecutablePath = (Join-Path $env:RUNNER_TEMP 'eye-break-reminder-v1.2.0-published-assets\portable-extracted\EyeBreakReminder.exe'),
  [string]$EvidenceDirectory = (Join-Path (Get-Location) 'build\post-release-evidence')
)
$ErrorActionPreference='Stop'
$expected='2895c80f942dd03186305d913516700552524ec5ba9a77da0dab457a3265fcc6'
$events=[System.Collections.Generic.List[object]]::new()
$resourceSamples=[System.Collections.Generic.List[object]]::new()
$script:ownedData=$false
$script:foregroundDiagnosticCaptured=$false
$script:wslPromptHandled=$false
$script:activeProcess=$null
$script:activeWindow=[IntPtr]::Zero
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$native=@"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public struct EBR_POST_RECT { public int Left,Top,Right,Bottom; }
public struct EBR_POST_POINT { public int X,Y; }
public struct EBR_POST_SCROLLINFO { public uint cbSize,fMask; public int nMin,nMax; public uint nPage; public int nPos,nTrackPos; }
public static class EBR_POST_NATIVE {
  public delegate bool EnumCallback(IntPtr hwnd,IntPtr data);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumCallback cb,IntPtr data);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent,EnumCallback cb,IntPtr data);
  [DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr hwnd);
  [DllImport("user32.dll",SetLastError=true)] public static extern uint GetWindowThreadProcessId(IntPtr hwnd,out uint pid);
  [DllImport("user32.dll",SetLastError=true)] public static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] private static extern int GetWindowTextW(IntPtr hwnd,StringBuilder text,int maxCount);
  [DllImport("user32.dll",SetLastError=true)] private static extern int GetWindowTextLengthW(IntPtr hwnd);
  [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] private static extern int GetClassNameW(IntPtr hwnd,StringBuilder name,int maxCount);
  [DllImport("user32.dll",SetLastError=true)] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll",SetLastError=true)] public static extern void keybd_event(byte virtualKey,byte scanCode,uint flags,UIntPtr extraInfo);
  [DllImport("user32.dll",SetLastError=true)] public static extern bool SetCursorPos(int x,int y);
  [DllImport("user32.dll",SetLastError=true)] public static extern bool GetCursorPos(out EBR_POST_POINT point);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(EBR_POST_POINT point);
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hwnd,uint flags);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags,uint dx,uint dy,uint data,UIntPtr extraInfo);
  [DllImport("user32.dll",SetLastError=true)] public static extern bool SetForegroundWindow(IntPtr hwnd);
  [DllImport("user32.dll",SetLastError=true)] public static extern bool BringWindowToTop(IntPtr hwnd);
  [DllImport("user32.dll",SetLastError=true)] public static extern bool ShowWindow(IntPtr hwnd,int command);
  [DllImport("user32.dll",SetLastError=true)] public static extern bool AttachThreadInput(uint attach,uint attachTo,bool attachState);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll",SetLastError=true)] public static extern IntPtr GetDlgItem(IntPtr hwnd,int id);
  [DllImport("user32.dll",SetLastError=true)] public static extern IntPtr SendMessageW(IntPtr hwnd,uint msg,IntPtr wp,IntPtr lp);
  [DllImport("user32.dll",SetLastError=true)] public static extern IntPtr SendMessageTimeoutW(IntPtr hwnd,uint msg,IntPtr wp,IntPtr lp,uint flags,uint timeout,out IntPtr result);
  [DllImport("winmm.dll",ExactSpelling=true)] public static extern uint waveOutGetNumDevs();
  [DllImport("user32.dll",SetLastError=true)] public static extern int GetGuiResources(IntPtr process,uint flags);
  [DllImport("user32.dll",SetLastError=true)] public static extern IntPtr BeginDeferWindowPos(int count);
  [DllImport("user32.dll",SetLastError=true)] public static extern IntPtr DeferWindowPos(IntPtr batch,IntPtr hwnd,IntPtr insertAfter,int x,int y,int width,int height,uint flags);
  [DllImport("user32.dll",SetLastError=true)] public static extern bool EndDeferWindowPos(IntPtr batch);
  [DllImport("user32.dll",SetLastError=true)] public static extern bool GetScrollInfo(IntPtr hwnd,int bar,ref EBR_POST_SCROLLINFO info);
  [DllImport("user32.dll",SetLastError=true)] public static extern bool SystemParametersInfoW(uint action,uint uiParam,ref int value,uint flags);
  [DllImport("user32.dll",EntryPoint="SystemParametersInfoW",SetLastError=true)] public static extern bool SystemParametersInfoSetScalar(uint action,uint uiParam,IntPtr value,uint flags);
  [DllImport("user32.dll",SetLastError=true)] public static extern bool PostMessageW(IntPtr hwnd,uint msg,IntPtr wp,IntPtr lp);
  [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern uint RegisterWindowMessageW(string name);
  [DllImport("user32.dll",SetLastError=true)] public static extern bool GetWindowRect(IntPtr hwnd,out EBR_POST_RECT rect);
  [DllImport("user32.dll",SetLastError=true)] public static extern IntPtr GetDC(IntPtr hwnd);
  [DllImport("user32.dll",SetLastError=true)] public static extern int ReleaseDC(IntPtr hwnd,IntPtr dc);
  [DllImport("gdi32.dll",SetLastError=true)] public static extern uint GetPixel(IntPtr dc,int x,int y);
  [DllImport("user32.dll",SetLastError=true)] public static extern bool SetWindowPos(IntPtr hwnd,IntPtr insertAfter,int x,int y,int width,int height,uint flags);
  [DllImport("user32.dll",SetLastError=true)] public static extern bool GetClientRect(IntPtr hwnd,out EBR_POST_RECT rect);
  [DllImport("user32.dll",SetLastError=true)] public static extern bool ClientToScreen(IntPtr hwnd,ref EBR_POST_POINT point);
  [DllImport("user32.dll",SetLastError=true)] public static extern uint GetDpiForWindow(IntPtr hwnd);
  [DllImport("user32.dll",SetLastError=true)] public static extern IntPtr GetParent(IntPtr hwnd);
  [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern IntPtr FindWindowW(string className,string windowName);
  public static string Text(IntPtr hwnd){int n=GetWindowTextLengthW(hwnd);StringBuilder b=new StringBuilder(Math.Max(2,n+2));GetWindowTextW(hwnd,b,b.Capacity);return b.ToString();}
  public static string ClassName(IntPtr hwnd){StringBuilder b=new StringBuilder(256);GetClassNameW(hwnd,b,b.Capacity);return b.ToString();}
  public static IntPtr ControlById(IntPtr root,int id){List<IntPtr> found=new List<IntPtr>();EnumCallback cb=delegate(IntPtr h,IntPtr ignored){if(GetDlgCtrlID(h)==id)found.Add(h);return true;};EnumChildWindows(root,cb,IntPtr.Zero);GC.KeepAlive(cb);return found.Count==1?found[0]:IntPtr.Zero;}
  public static IntPtr[] WindowsForProcess(int pid){List<IntPtr> r=new List<IntPtr>();EnumCallback cb=delegate(IntPtr h,IntPtr ignored){uint actual;GetWindowThreadProcessId(h,out actual);if(actual==(uint)pid&&IsWindowVisible(h))r.Add(h);return true;};EnumWindows(cb,IntPtr.Zero);GC.KeepAlive(cb);return r.ToArray();}
  public static IntPtr[] AllWindowsForProcess(int pid){List<IntPtr> r=new List<IntPtr>();EnumCallback cb=delegate(IntPtr h,IntPtr ignored){uint actual;GetWindowThreadProcessId(h,out actual);if(actual==(uint)pid)r.Add(h);return true;};EnumWindows(cb,IntPtr.Zero);GC.KeepAlive(cb);return r.ToArray();}
  public static int ChildCount(IntPtr parent){int count=0;EnumCallback cb=delegate(IntPtr h,IntPtr ignored){count++;return true;};EnumChildWindows(parent,cb,IntPtr.Zero);GC.KeepAlive(cb);return count;}
}
"@
Add-Type -TypeDefinition $native
function Add-Result([string]$Name,[string]$Status,$Details=$null){$events.Add([pscustomobject]@{Name=$Name;Status=$Status;Details=$Details;Utc=[DateTime]::UtcNow.ToString('o')});Write-Host "[$Status] $Name"}
function Check([bool]$Condition,[string]$Name,$Details=$null){if($Condition){Add-Result $Name 'PASS' $Details}else{Add-Result $Name 'FAIL' $Details}}
function Probe-FailedDeferWindowPos([string]$Label){
  $process=[Diagnostics.Process]::GetCurrentProcess()
  $before=[EBR_POST_NATIVE]::GetGuiResources($process.Handle,1)
  $batch=[EBR_POST_NATIVE]::BeginDeferWindowPos(1)
  $returned=[IntPtr]::Zero;$errorCode=0;$endResult=$null
  if($batch -ne [IntPtr]::Zero){$returned=[EBR_POST_NATIVE]::DeferWindowPos($batch,[IntPtr]::Zero,[IntPtr]::Zero,0,0,1,1,0x0004);$errorCode=[Runtime.InteropServices.Marshal]::GetLastWin32Error();if($returned -ne [IntPtr]::Zero){$endResult=[EBR_POST_NATIVE]::EndDeferWindowPos($returned)}}
  Start-Sleep -Milliseconds 250
  $after=[EBR_POST_NATIVE]::GetGuiResources($process.Handle,1)
  Add-Result "$Label failed null-HWND DeferWindowPos resource probe (test process only)" 'INFO' ([pscustomobject]@{Process='PowerShell harness, not EyeBreakReminder.exe';InitialBatchCreated=($batch -ne [IntPtr]::Zero);DeferReturnedNull=($returned -eq [IntPtr]::Zero);EndResult=$endResult;LastError=$errorCode;UserObjectsBefore=$before;UserObjectsAfter=$after;Delta=($after-$before);Reason='Compares USER-object cleanup after the documented abandoned-batch path; it does not alter application state.'})
}
function Get-MainWindow([int]$ProcessId){
  $watch=[Diagnostics.Stopwatch]::StartNew()
  while($watch.Elapsed.TotalSeconds -lt 25){
    foreach($handle in [EBR_POST_NATIVE]::WindowsForProcess($ProcessId)){
      if([EBR_POST_NATIVE]::ClassName($handle) -eq 'EyeBreakReminder.Native'){return $handle}
    }
    Start-Sleep -Milliseconds 150
  }
  return [IntPtr]::Zero
}
function Get-Status([IntPtr]$Window){$control=[EBR_POST_NATIVE]::GetDlgItem($Window,41);if($control -eq [IntPtr]::Zero){return ''};return [EBR_POST_NATIVE]::Text($control)}
function Wait-Status([IntPtr]$Window,[string]$Expected,[int]$TimeoutSeconds=5){
  $watch=[Diagnostics.Stopwatch]::StartNew();$last=''
  while($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds){$last=Get-Status $Window;if($last -match [regex]::Escape($Expected)){return $last};Start-Sleep -Milliseconds 100}
  return $last
}
function Get-AppResourceSnapshot([string]$Label){
  if(-not $script:activeProcess){return $null}
  $script:activeProcess.Refresh()
  $windows=@([EBR_POST_NATIVE]::AllWindowsForProcess($script:activeProcess.Id)|ForEach-Object{[pscustomobject]@{Handle=('0x{0:X}' -f $_.ToInt64());Class=[EBR_POST_NATIVE]::ClassName($_);Title=[EBR_POST_NATIVE]::Text($_);Visible=[EBR_POST_NATIVE]::IsWindowVisible($_);ChildCount=[EBR_POST_NATIVE]::ChildCount($_)}})
  return [pscustomobject]@{Label=$Label;Utc=[DateTime]::UtcNow.ToString('o');HandleCount=$script:activeProcess.HandleCount;GdiObjects=[EBR_POST_NATIVE]::GetGuiResources($script:activeProcess.Handle,0);UserObjects=[EBR_POST_NATIVE]::GetGuiResources($script:activeProcess.Handle,1);PrivateBytes=$script:activeProcess.PrivateMemorySize64;TopLevelWindows=$windows;BreakTopLevelWindowCount=@($windows|Where-Object Class -eq 'EyeBreakReminder.Break').Count}
}
function Record-AppResourceLifecycle([string]$Label,$Before,$After,[switch]$RequireStableUserObjects){
  if(-not $Before -or -not $After){return}
  $sample=[pscustomobject]@{Name=$Label;Before=$Before;After=$After;UserObjectDelta=($After.UserObjects-$Before.UserObjects);GdiObjectDelta=($After.GdiObjects-$Before.GdiObjects);HandleDelta=($After.HandleCount-$Before.HandleCount);PrivateByteDelta=($After.PrivateBytes-$Before.PrivateBytes)}
  $script:resourceSamples.Add($sample)
  Add-Result "$Label process resource lifecycle sample (informational)" 'INFO' $sample
  if($RequireStableUserObjects){Check ($sample.UserObjectDelta -eq 0) "$Label destroys temporary USER objects after the break window closes" ([pscustomobject]@{Before=$Before.UserObjects;After=$After.UserObjects;Delta=$sample.UserObjectDelta;BreakWindowMustBeDestroyed=$true;BeforeBreakWindows=$Before.BreakTopLevelWindowCount;AfterBreakWindows=$After.BreakTopLevelWindowCount;AfterWindows=$After.TopLevelWindows})}
}
function Click-Control([IntPtr]$Window,[int]$Id,[string]$Name){
  if($script:activeProcess){[void](Dismiss-WslFirstRunPrompt)}
  $control=[EBR_POST_NATIVE]::ControlById($Window,$Id)
  if($control -eq [IntPtr]::Zero){throw "Published app did not expose $Name (control $Id)."}
  # BM_CLICK is synchronous across the process boundary. Bound it so an unavailable
  # runner service or app hang produces evidence instead of hanging the job forever.
  $result=[IntPtr]::Zero
  $sent=[EBR_POST_NATIVE]::SendMessageTimeoutW($control,0x00F5,[IntPtr]::Zero,[IntPtr]::Zero,2,3000,[ref]$result)
  if($sent -eq [IntPtr]::Zero){$errorCode=[Runtime.InteropServices.Marshal]::GetLastWin32Error();throw "$Name (control $Id) did not complete its bounded BM_CLICK within 3000 ms (Win32 error $errorCode)."}
  Start-Sleep -Milliseconds 150
}
function Get-WindowAutomationSummary([IntPtr]$Window){
  try{
    $root=[System.Windows.Automation.AutomationElement]::FromHandle($Window)
    $nodes=$root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
    $items=@();$limit=[Math]::Min($nodes.Count,120)
    for($i=0;$i -lt $limit;$i++){
      $node=$nodes.Item($i)
      try{
        $name=$node.Current.Name
        if(-not $name){continue}
        $bounds=$node.Current.BoundingRectangle
        $items+=,[pscustomobject]@{Name=$name;ControlType=$node.Current.ControlType.ProgrammaticName;Offscreen=$node.Current.IsOffscreen;Bounds=@([Math]::Round($bounds.X),[Math]::Round($bounds.Y),[Math]::Round($bounds.Width),[Math]::Round($bounds.Height))}
      }catch{}
    }
    return $items
  }catch{return @()}
}
function Dismiss-WslFirstRunPrompt {
  if($script:wslPromptHandled){return $true}
  try{
    $focused=[System.Windows.Automation.AutomationElement]::FocusedElement
    if($null -eq $focused){return $false}
    $current=$focused.Current
    if($current.Name -cne 'C:\Windows\system32\wsl.exe'){return $false}
    $foreground=[EBR_POST_NATIVE]::GetForegroundWindow();$foregroundPid=[uint32]0
    if($foreground -ne [IntPtr]::Zero){[void][EBR_POST_NATIVE]::GetWindowThreadProcessId($foreground,[ref]$foregroundPid)}
    $foregroundTitle=[EBR_POST_NATIVE]::Text($foreground)
    if($foregroundPid -ne $current.ProcessId -or $foregroundTitle -notmatch '(?i)wsl\.exe'){return $false}
    $screenshot=''
    try{$screenshot=Capture-DesktopDiagnostic 'wsl-first-run-prompt-before-cancel.png'}catch{}
    # This is the disposable hosted runner's explicit WSL first-run prompt. Its
    # displayed instructions say Escape cancels the optional WSL install/update.
    [EBR_POST_NATIVE]::keybd_event(0x1B,0,0,[UIntPtr]::Zero)
    [EBR_POST_NATIVE]::keybd_event(0x1B,0,0x0002,[UIntPtr]::Zero)
    $watch=[Diagnostics.Stopwatch]::StartNew();$dismissed=$false;$after=$null
    while($watch.Elapsed.TotalSeconds -lt 2){
      Start-Sleep -Milliseconds 100
      try{$after=[System.Windows.Automation.AutomationElement]::FocusedElement.Current}catch{$after=$null}
      $window=[EBR_POST_NATIVE]::GetForegroundWindow();$windowTitle=[EBR_POST_NATIVE]::Text($window)
      if(($after -and ($after.ProcessId -ne $current.ProcessId -or $after.Name -cne $current.Name)) -or $window -ne $foreground -or $windowTitle -notmatch '(?i)wsl\.exe'){$dismissed=$true;break}
    }
    Add-Result 'Disposable runner WSL first-run update prompt was canceled with Escape' $(if($dismissed){'PASS'}else{'NOT TESTED'}) ([pscustomobject]@{FocusedElement=$current.Name;ProcessId=$current.ProcessId;ForegroundTitle=$foregroundTitle;PromptScreenshot=$screenshot;Dismissed=$dismissed;Reason=$(if($dismissed){$null}else{'The exact WSL window remained foreground; no other window received test input.'})})
    $script:wslPromptHandled=$dismissed
    return $dismissed
  }catch{return $false}
}
function Ensure-AppForeground([IntPtr]$Window,[int]$ProcessId){
  [void](Dismiss-WslFirstRunPrompt)
  [void][EBR_POST_NATIVE]::ShowWindow($Window,9)
  $foregroundBefore=[EBR_POST_NATIVE]::GetForegroundWindow()
  $initialForeground=$foregroundBefore
  $foregroundProcessName=''
  if($foregroundBefore -ne [IntPtr]::Zero){$initialForegroundPid=[uint32]0;[void][EBR_POST_NATIVE]::GetWindowThreadProcessId($foregroundBefore,[ref]$initialForegroundPid);if($initialForegroundPid){try{$foregroundProcessName=(Get-Process -Id $initialForegroundPid -ErrorAction Stop).ProcessName}catch{}}}
  $dismissedSearchOverlay=$false
  if($foregroundProcessName -in @('SearchHost','StartMenuExperienceHost')){
    # Windows 11 hosted runners can leave Start/Search over the desktop after OOBE. Escape is real input to that transient shell UI.
    [EBR_POST_NATIVE]::keybd_event(0x1B,0,0,[UIntPtr]::Zero);[EBR_POST_NATIVE]::keybd_event(0x1B,0,0x0002,[UIntPtr]::Zero)
    Start-Sleep -Milliseconds 300
    $dismissedSearchOverlay=([EBR_POST_NATIVE]::GetForegroundWindow() -ne $initialForeground)
    $foregroundBefore=[EBR_POST_NATIVE]::GetForegroundWindow()
  }
  $foregroundThread=[uint32]0;$foregroundOwnerPid=[uint32]0
  # The return value is the thread ID; the out parameter is the process ID.
  if($foregroundBefore -ne [IntPtr]::Zero){$foregroundThread=[EBR_POST_NATIVE]::GetWindowThreadProcessId($foregroundBefore,[ref]$foregroundOwnerPid)}
  $targetOwnerPid=[uint32]0;$targetThread=[EBR_POST_NATIVE]::GetWindowThreadProcessId($Window,[ref]$targetOwnerPid)
  $currentThread=[EBR_POST_NATIVE]::GetCurrentThreadId()
  $attached=$false;$targetAttached=$false
  if($foregroundThread -ne 0 -and $foregroundThread -ne $currentThread){$attached=[EBR_POST_NATIVE]::AttachThreadInput($currentThread,$foregroundThread,$true)}
  if($targetThread -ne 0 -and $targetThread -ne $currentThread -and $targetThread -ne $foregroundThread){$targetAttached=[EBR_POST_NATIVE]::AttachThreadInput($currentThread,$targetThread,$true)}
  try{
    [void][EBR_POST_NATIVE]::BringWindowToTop($Window)
    [void][EBR_POST_NATIVE]::SetForegroundWindow($Window)
    try{[System.Windows.Automation.AutomationElement]::FromHandle($Window).SetFocus()}catch{}
    [void][EBR_POST_NATIVE]::SetForegroundWindow($Window)
  }finally{if($targetAttached){[void][EBR_POST_NATIVE]::AttachThreadInput($currentThread,$targetThread,$false)};if($attached){[void][EBR_POST_NATIVE]::AttachThreadInput($currentThread,$foregroundThread,$false)}}
  $titleBarClicked=$false
  if([EBR_POST_NATIVE]::GetForegroundWindow() -ne $Window){
    $rect=New-Object EBR_POST_RECT;$oldCursor=New-Object EBR_POST_POINT
    if([EBR_POST_NATIVE]::GetWindowRect($Window,[ref]$rect) -and [EBR_POST_NATIVE]::GetCursorPos([ref]$oldCursor)){
      $point=New-Object EBR_POST_POINT;$dpi=[Math]::Max(96,[int][EBR_POST_NATIVE]::GetDpiForWindow($Window))
      $point.X=$rect.Left+[int][Math]::Min(($rect.Right-$rect.Left)/3,120*$dpi/96);$point.Y=$rect.Top+[int](15*$dpi/96)
      # Activate only an unobstructed title-bar point belonging to this app, never an overlapping runner window.
      $hit=[EBR_POST_NATIVE]::WindowFromPoint($point)
      if($hit -ne [IntPtr]::Zero -and [EBR_POST_NATIVE]::GetAncestor($hit,2) -eq $Window){
        try{if([EBR_POST_NATIVE]::SetCursorPos($point.X,$point.Y)){[EBR_POST_NATIVE]::mouse_event(0x0002,0,0,0,[UIntPtr]::Zero);[EBR_POST_NATIVE]::mouse_event(0x0004,0,0,0,[UIntPtr]::Zero);$titleBarClicked=$true}}finally{[void][EBR_POST_NATIVE]::SetCursorPos($oldCursor.X,$oldCursor.Y)}
      }
    }
  }
  $watch=[Diagnostics.Stopwatch]::StartNew();$foreground=[IntPtr]::Zero;$foregroundPid=[uint32]0
  while($watch.Elapsed.TotalSeconds -lt 2){
    $foreground=[EBR_POST_NATIVE]::GetForegroundWindow();$foregroundPid=[uint32]0
    if($foreground -ne [IntPtr]::Zero){[void][EBR_POST_NATIVE]::GetWindowThreadProcessId($foreground,[ref]$foregroundPid)}
    if($foreground -eq $Window -and $foregroundPid -eq $ProcessId){break}
    Start-Sleep -Milliseconds 100
  }
  $foregroundName='';$foregroundPath=''
  if($foregroundPid){try{$foregroundProcess=Get-Process -Id $foregroundPid -ErrorAction Stop;$foregroundName=$foregroundProcess.ProcessName;$foregroundPath=$foregroundProcess.Path}catch{}}
  return [pscustomobject]@{
    ApplicationForeground=($foreground -eq $Window -and $foregroundPid -eq $ProcessId)
    ForegroundHandle=('0x{0:X}' -f $foreground.ToInt64())
    ForegroundProcessId=$foregroundPid
    ForegroundProcessName=$foregroundName
    ForegroundProcessPath=$foregroundPath
    ForegroundTitle=[EBR_POST_NATIVE]::Text($foreground)
    ForegroundClass=[EBR_POST_NATIVE]::ClassName($foreground)
    ForegroundAutomation=if($foreground -ne [IntPtr]::Zero){Get-WindowAutomationSummary $foreground}else{@()}
    WindowHandle=('0x{0:X}' -f $Window.ToInt64())
    WindowProcessId=$ProcessId
    ForegroundBefore=('0x{0:X}' -f $foregroundBefore.ToInt64())
    InitialForegroundBeforeDismiss=('0x{0:X}' -f $initialForeground.ToInt64())
    ForegroundProcessBeforeDismiss=$foregroundProcessName
    DismissedTransientSearchOverlay=$dismissedSearchOverlay
    InputThreadsAttached=$attached
    TargetInputThreadAttached=$targetAttached
    CurrentThreadId=$currentThread
    ForegroundThreadId=$foregroundThread
    TargetThreadId=$targetThread
    UnobstructedTitleBarClicked=$titleBarClicked
  }
}
function Capture-DesktopDiagnostic([string]$Name){
  $bounds=[System.Windows.Forms.Screen]::PrimaryScreen.Bounds
  if($bounds.Width -lt 100 -or $bounds.Height -lt 100){return $null}
  $bitmap=[Drawing.Bitmap]::new($bounds.Width,$bounds.Height);$graphics=[Drawing.Graphics]::FromImage($bitmap)
  try{$graphics.CopyFromScreen($bounds.Left,$bounds.Top,0,0,$bitmap.Size);$path=Join-Path $EvidenceDirectory $Name;$bitmap.Save($path,[Drawing.Imaging.ImageFormat]::Png);return $path}finally{$graphics.Dispose();$bitmap.Dispose()}
}
function Capture([IntPtr]$Window,[string]$Name){
  $windowPid=[uint32]0;[void][EBR_POST_NATIVE]::GetWindowThreadProcessId($Window,[ref]$windowPid)
  $foreground=Ensure-AppForeground $Window ([int]$windowPid)
  if(-not $foreground.ApplicationForeground){
    $diagnosticPath=$null
    if(-not $script:foregroundDiagnosticCaptured){try{$diagnosticPath=Capture-DesktopDiagnostic 'desktop-foreground-obstruction.png';$script:foregroundDiagnosticCaptured=$true}catch{}}
    Add-Result "Visible screenshot of $Name" 'NOT TESTED' ([pscustomobject]@{Reason='The published application window could not be brought to the desktop foreground; hidden-window capture is deliberately skipped.';Foreground=$foreground;DesktopDiagnostic=$diagnosticPath})
    return $null
  }
  $rect=New-Object EBR_POST_RECT
  if(-not [EBR_POST_NATIVE]::GetWindowRect($Window,[ref]$rect)){throw "Could not measure published app window for $Name"}
  $width=$rect.Right-$rect.Left;$height=$rect.Bottom-$rect.Top
  if($width -lt 100 -or $height -lt 100){throw "Published app window bounds are invalid for $Name"}
  $bitmap=[Drawing.Bitmap]::new($width,$height);$graphics=[Drawing.Graphics]::FromImage($bitmap)
  try{$graphics.CopyFromScreen($rect.Left,$rect.Top,0,0,$bitmap.Size);$path=Join-Path $EvidenceDirectory $Name;$bitmap.Save($path,[Drawing.Imaging.ImageFormat]::Png);Add-Result "Visible screenshot of $Name" 'PASS' ([pscustomobject]@{Path=$path;Foreground=$foreground;Method='CopyFromScreen'});return [pscustomobject]@{Path=$path;Width=$width;Height=$height;UniqueSampledColors=$null;Method='CopyFromScreen desktop foreground'}}finally{$graphics.Dispose();$bitmap.Dispose()}
}
function Get-BreakWindow([int]$ProcessId){
  foreach($handle in [EBR_POST_NATIVE]::WindowsForProcess($ProcessId)){if([EBR_POST_NATIVE]::ClassName($handle) -eq 'EyeBreakReminder.Break'){return $handle}}
  return [IntPtr]::Zero
}
function Wait-BreakWindow([int]$ProcessId,[int]$TimeoutSeconds=5){
  $watch=[Diagnostics.Stopwatch]::StartNew();$handle=[IntPtr]::Zero
  while($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds){$handle=Get-BreakWindow $ProcessId;if($handle -ne [IntPtr]::Zero){return $handle};Start-Sleep -Milliseconds 100}
  return [IntPtr]::Zero
}
function Select-Theme([IntPtr]$Window,[int]$ThemeIndex){
  Click-Control $Window 12 'Settings navigation for theme test'
  Click-Control $Window 134 'General settings section for theme test'
  $combo=[EBR_POST_NATIVE]::ControlById($Window,106)
  if($combo -eq [IntPtr]::Zero){throw 'Theme selection ComboBox was unavailable.'}
  [void][EBR_POST_NATIVE]::SendMessageW($combo,0x014E,[IntPtr]::new($ThemeIndex),[IntPtr]::Zero)
  $parent=[EBR_POST_NATIVE]::GetParent($combo)
  $wParam=[IntPtr]::new([long]((106 -band 0xffff) -bor (1 -shl 16)))
  [void][EBR_POST_NATIVE]::SendMessageW($parent,0x0111,$wParam,$combo)
  $selected=([EBR_POST_NATIVE]::SendMessageW($combo,0x0147,[IntPtr]::Zero,[IntPtr]::Zero)).ToInt32()
  Check ($selected -eq $ThemeIndex) "Theme combo selected index $ThemeIndex" ([pscustomobject]@{Expected=$ThemeIndex;Actual=$selected})
  Click-Control $Window 10 'Timer navigation after theme selection'
}
function Set-BreakColorOption([IntPtr]$Window,[bool]$Enabled,[string]$Label){
  Click-Control $Window 12 "$Label Settings navigation for break-colour option"
  Click-Control $Window 134 "$Label General settings section for break-colour option"
  $control=[EBR_POST_NATIVE]::ControlById($Window,124)
  if($control -eq [IntPtr]::Zero){throw 'Distinct break-colour checkbox was unavailable.'}
  $desired=if($Enabled){1}else{0};$current=([EBR_POST_NATIVE]::SendMessageW($control,0x00F0,[IntPtr]::Zero,[IntPtr]::Zero)).ToInt32()
  if($current -ne $desired){Click-Control $Window 124 "$Label set distinct break-colour option to $Enabled"}
  $actual=([EBR_POST_NATIVE]::SendMessageW($control,0x00F0,[IntPtr]::Zero,[IntPtr]::Zero)).ToInt32()
  Check ($actual -eq $desired) "$Label distinct break-colour option is $Enabled" ([pscustomobject]@{Expected=$desired;Actual=$actual})
  Click-Control $Window 10 "$Label Timer navigation after break-colour option"
}
function Get-TimerRingGeometry([IntPtr]$Window){
  $client=New-Object EBR_POST_RECT;$windowRect=New-Object EBR_POST_RECT;$origin=New-Object EBR_POST_POINT
  if(-not [EBR_POST_NATIVE]::GetClientRect($Window,[ref]$client) -or -not [EBR_POST_NATIVE]::GetWindowRect($Window,[ref]$windowRect) -or -not [EBR_POST_NATIVE]::ClientToScreen($Window,[ref]$origin)){throw 'Could not measure the application client/window geometry.'}
  $button=[EBR_POST_NATIVE]::ControlById($Window,22);$buttonRect=New-Object EBR_POST_RECT
  if($button -eq [IntPtr]::Zero -or -not [EBR_POST_NATIVE]::GetWindowRect($button,[ref]$buttonRect)){throw 'Could not measure the timer primary-action button.'}
  $dpi=[int][EBR_POST_NATIVE]::GetDpiForWindow($Window);if($dpi -lt 48){$dpi=96}
  $textScale=1.0;try{$scale=[int](Get-ItemPropertyValue -LiteralPath 'HKCU:\Software\Microsoft\Accessibility' -Name TextScaleFactor -ErrorAction Stop);$textScale=[Math]::Min(2.25,[Math]::Max(1.0,$scale/100.0))}catch{}
  $px={param([double]$Value)[int][Math]::Floor($Value*$dpi/96.0+0.5)}
  $navBottom=(& $px 16)+(& $px ([Math]::Max(40.0,31.0*$textScale)))
  $timerTop=$navBottom+(& $px 22);$statusBottom=$timerTop+(& $px 88)
  $diameter=[Math]::Min((& $px 272),[Math]::Min($client.Right-(& $px 100),($buttonRect.Top-$origin.Y)-$statusBottom-(& $px 18)))
  $diameter=[Math]::Max(1,$diameter);$ringLeft=[int][Math]::Floor(($client.Right-$diameter)/2.0)
  $ringTop=$statusBottom+(& $px 8);$ringX=$ringLeft+(& $px 4);$ringY=$ringTop+(& $px 4);$ringDiameter=$diameter-(& $px 8)
  return [pscustomobject]@{Dpi=$dpi;TextScale=$textScale;ClientWidth=$client.Right;ClientOriginX=$origin.X;ClientOriginY=$origin.Y;WindowLeft=$windowRect.Left;WindowTop=$windowRect.Top;CenterX=($origin.X-$windowRect.Left)+$ringX+$ringDiameter/2.0;CenterY=($origin.Y-$windowRect.Top)+$ringY+$ringDiameter/2.0;Radius=$ringDiameter/2.0;WindowWidth=$windowRect.Right-$windowRect.Left;WindowHeight=$windowRect.Bottom-$windowRect.Top}
}
function Test-TimerRingPixel([IntPtr]$Window,[string]$Label,[string]$ExpectedColor,[string]$ScreenshotName,[string]$ForbiddenColor=''){
  $geometry=Get-TimerRingGeometry $Window
  $image=Capture $Window $ScreenshotName
  if(-not $image -or -not $image.Path){Add-Result "$Label timer-ring accent pixel" 'NOT TESTED' 'No verified app window surface could be captured.';return}
  # A foreground HWND does not guarantee that an unrelated topmost window is not
  # covering the app's client area. Validate the real desktop owner at eight
  # points on the ring after capture so overlays cannot turn a valid color probe
  # into a false product failure.
  $occluded=[System.Collections.Generic.List[object]]::new()
  for($degrees=0;$degrees -lt 360;$degrees+=45){
    $radians=$degrees*[Math]::PI/180.0;$point=New-Object EBR_POST_POINT
    $point.X=[int][Math]::Round($geometry.WindowLeft+$geometry.CenterX+$geometry.Radius*[Math]::Cos($radians))
    $point.Y=[int][Math]::Round($geometry.WindowTop+$geometry.CenterY+$geometry.Radius*[Math]::Sin($radians))
    $hit=[EBR_POST_NATIVE]::WindowFromPoint($point)
    $root=if($hit -ne [IntPtr]::Zero){[EBR_POST_NATIVE]::GetAncestor($hit,2)}else{[IntPtr]::Zero}
    if($root -ne $Window){
      $ownerPid=[uint32]0;if($root -ne [IntPtr]::Zero){[void][EBR_POST_NATIVE]::GetWindowThreadProcessId($root,[ref]$ownerPid)}
      $ownerName='';if($ownerPid){try{$ownerName=(Get-Process -Id $ownerPid -ErrorAction Stop).ProcessName}catch{}}
      $occluded.Add([pscustomobject]@{ScreenPoint=@($point.X,$point.Y);Hit=('0x{0:X}' -f $hit.ToInt64());Root=('0x{0:X}' -f $root.ToInt64());OwnerPid=$ownerPid;OwnerName=$ownerName;OwnerTitle=[EBR_POST_NATIVE]::Text($root);OwnerClass=[EBR_POST_NATIVE]::ClassName($root)})
    }
  }
  if($occluded.Count -gt 0){
    Add-Result "$Label timer-ring screenshot has no unrelated window over sampled ring points" 'NOT TESTED' ([pscustomobject]@{Reason='The actual desktop screenshot contains an unrelated window over one or more timer-ring points; pixel results from those covered points would not describe the app.';Screenshot=$image.Path;OccludedPointCount=$occluded.Count;Occluders=@($occluded.ToArray())})
    return
  }
  $bitmap=[Drawing.Bitmap]::new($image.Path);$count=0;$examples=[System.Collections.Generic.List[string]]::new()
  try{
    if($bitmap.Width -ne $geometry.WindowWidth -or $bitmap.Height -ne $geometry.WindowHeight){Add-Result "$Label timer-ring accent pixel" 'NOT TESTED' ([pscustomobject]@{Reason='Captured window dimensions did not match the measured HWND.';Bitmap=@($bitmap.Width,$bitmap.Height);Geometry=$geometry});return}
    $target=$ExpectedColor.TrimStart('#').ToUpperInvariant();$forbidden=$ForbiddenColor.TrimStart('#').ToUpperInvariant();$forbiddenCount=0
    # Sample the actual ring annulus directly. Dense angular/radial samples cover anti-aliased arcs without a slow full-window PowerShell pixel scan.
    for($degrees=0;$degrees -lt 360;$degrees+=2){
      $radians=$degrees*[Math]::PI/180.0;$cos=[Math]::Cos($radians);$sin=[Math]::Sin($radians)
      for($offset=-5;$offset -le 5;$offset++){
        $sampleRadius=$geometry.Radius+$offset
        $x=[int][Math]::Round($geometry.CenterX+$cos*$sampleRadius);$y=[int][Math]::Round($geometry.CenterY+$sin*$sampleRadius)
        if($x -lt 0 -or $x -ge $bitmap.Width -or $y -lt 0 -or $y -ge $bitmap.Height){continue}
        $c=$bitmap.GetPixel($x,$y);$hex='{0:X2}{1:X2}{2:X2}' -f $c.R,$c.G,$c.B
        if($hex -eq $target){$count++;if($examples.Count -lt 8){$examples.Add("$x,$y")}}
        if($forbidden -and $hex -eq $forbidden){$forbiddenCount++}
      }
    }
  }finally{$bitmap.Dispose()}
  Check ($count -gt 0) "$Label timer-ring contains the expected $ExpectedColor accent pixel" ([pscustomobject]@{ExpectedColor=$ExpectedColor;ExactPixels=$count;SamplePixels=$examples.ToArray();Geometry=$geometry;Screenshot=$image.Path;CaptureMethod=$image.Method})
  if($forbidden){Check ($forbiddenCount -eq 0) "$Label timer-ring excludes the $ForbiddenColor accent pixel" ([pscustomobject]@{ForbiddenColor=$ForbiddenColor;ExactPixels=$forbiddenCount;Screenshot=$image.Path})}
}
function Get-ControlScreenColors([IntPtr]$Control){
  $rect=New-Object EBR_POST_RECT
  if($Control -eq [IntPtr]::Zero -or -not [EBR_POST_NATIVE]::GetWindowRect($Control,[ref]$rect)){throw 'Could not measure a visible control for direct state-pixel sampling.'}
  $width=$rect.Right-$rect.Left;$height=$rect.Bottom-$rect.Top
  if($width -lt 20 -or $height -lt 16){throw 'The sampled control is too small for stable state-pixel probes.'}
  $points=@(
    @{X=$rect.Left+[int]($width*0.12);Y=$rect.Top+[int]($height*0.50)},
    @{X=$rect.Left+[int]($width*0.88);Y=$rect.Top+[int]($height*0.50)},
    @{X=$rect.Left+[int]($width*0.18);Y=$rect.Top+[int]($height*0.25)},
    @{X=$rect.Left+[int]($width*0.82);Y=$rect.Top+[int]($height*0.75)},
    @{X=$rect.Left+[int]($width*0.25);Y=$rect.Bottom-2},
    @{X=$rect.Left+[int]($width*0.50);Y=$rect.Bottom-2},
    @{X=$rect.Left+[int]($width*0.75);Y=$rect.Bottom-2}
  )
  $dc=[EBR_POST_NATIVE]::GetDC([IntPtr]::Zero)
  if($dc -eq [IntPtr]::Zero){throw 'Could not acquire the real desktop surface for state-pixel sampling.'}
  $samples=[System.Collections.Generic.List[object]]::new()
  try{
    foreach($point in $points){
      $pixel=[EBR_POST_NATIVE]::GetPixel($dc,$point.X,$point.Y)
      if($pixel -eq [uint32]::MaxValue){throw "GetPixel failed at $($point.X),$($point.Y)."}
      $red=[int]($pixel -band 0xff);$green=[int](($pixel -shr 8) -band 0xff);$blue=[int](($pixel -shr 16) -band 0xff)
      $samples.Add([pscustomobject]@{X=$point.X;Y=$point.Y;Hex=('#{0:X2}{1:X2}{2:X2}' -f $red,$green,$blue)})
    }
  }finally{[void][EBR_POST_NATIVE]::ReleaseDC([IntPtr]::Zero,$dc)}
  return [pscustomobject]@{ControlRect=@($rect.Left,$rect.Top,$rect.Right,$rect.Bottom);Pixels=$samples.ToArray()}
}
function Test-TabVisualStates([IntPtr]$Window,[string]$Label){
  [void](Dismiss-WslFirstRunPrompt)
  $timer=[EBR_POST_NATIVE]::ControlById($Window,10);$settings=[EBR_POST_NATIVE]::ControlById($Window,12)
  $windowRect=New-Object EBR_POST_RECT;$oldCursor=New-Object EBR_POST_POINT
  if($timer -eq [IntPtr]::Zero -or $settings -eq [IntPtr]::Zero -or -not [EBR_POST_NATIVE]::GetWindowRect($Window,[ref]$windowRect) -or -not [EBR_POST_NATIVE]::GetCursorPos([ref]$oldCursor)){
    Add-Result "$Label active, hover and keyboard-focus navigation states can be measured" 'NOT TESTED' 'The app tab controls, window bounds or original pointer position were unavailable.';return
  }
  $settingsRect=New-Object EBR_POST_RECT
  if(-not [EBR_POST_NATIVE]::GetWindowRect($settings,[ref]$settingsRect)){Add-Result "$Label settings tab hover state is directly visible on screen" 'NOT TESTED' 'The Settings tab bounds could not be measured.';return}
  try{
    [void][EBR_POST_NATIVE]::SetCursorPos($windowRect.Left+[int](($windowRect.Right-$windowRect.Left)/3),$windowRect.Top+6)
    Start-Sleep -Milliseconds 250
    $activePixels=Get-ControlScreenColors $timer;$inactivePixels=Get-ControlScreenColors $settings
    $activeDifferential=$false
    for($i=0;$i -lt $activePixels.Pixels.Count;$i++){if($activePixels.Pixels[$i].Hex -ne $inactivePixels.Pixels[$i].Hex){$activeDifferential=$true}}
    Check $activeDifferential "$Label selected Timer tab has a distinct visible state from the inactive Settings tab" ([pscustomobject]@{SelectedTab='Timer';InactiveTab='Settings';SelectedPixels=$activePixels.Pixels;InactivePixels=$inactivePixels.Pixels;Method='Direct GetPixel samples from the visible desktop'})

    [void][EBR_POST_NATIVE]::SetCursorPos($windowRect.Left+[int](($windowRect.Right-$windowRect.Left)/3),$windowRect.Top+6)
    Start-Sleep -Milliseconds 200
    $hoverBaseline=Get-ControlScreenColors $settings
    $hoverX=$settingsRect.Left+[int](($settingsRect.Right-$settingsRect.Left)/2);$hoverY=$settingsRect.Top+[int](($settingsRect.Bottom-$settingsRect.Top)/2)
    $moved=[EBR_POST_NATIVE]::SetCursorPos($hoverX,$hoverY)
    Start-Sleep -Milliseconds 350
    $hoverPixels=Get-ControlScreenColors $settings
    $hoverDifferential=$false
    for($i=0;$i -lt $hoverBaseline.Pixels.Count;$i++){if($hoverBaseline.Pixels[$i].Hex -ne $hoverPixels.Pixels[$i].Hex){$hoverDifferential=$true}}
    Check ($moved -and $hoverDifferential) "$Label real mouse hover changes visible Settings-tab pixels" ([pscustomobject]@{MousePositionSet=$moved;HoverPoint=@($hoverX,$hoverY);Before=$hoverBaseline.Pixels;After=$hoverPixels.Pixels;Method='SetCursorPos delivered mouse movement; desktop pixels sampled with GetPixel'})

    $focusClickX=$settingsRect.Left+[int](($settingsRect.Right-$settingsRect.Left)/2);$focusClickY=$settingsRect.Top+[int](($settingsRect.Bottom-$settingsRect.Top)/2)
    $focusClickReady=[EBR_POST_NATIVE]::SetCursorPos($focusClickX,$focusClickY)
    if($focusClickReady){[EBR_POST_NATIVE]::mouse_event(0x0002,0,0,0,[UIntPtr]::Zero);[EBR_POST_NATIVE]::mouse_event(0x0004,0,0,0,[UIntPtr]::Zero);Start-Sleep -Milliseconds 180}
    $focus=[System.Windows.Automation.AutomationElement]::FocusedElement;$focusSummary=$null
    if($focus){$current=$focus.Current;$focusSummary=[pscustomobject]@{Name=$current.Name;ControlType=$current.ControlType.ProgrammaticName;ProcessId=$current.ProcessId;HasKeyboardFocus=$current.HasKeyboardFocus}}
    $focusOk=$focusSummary -and $focusSummary.ProcessId -eq $script:activeProcess.Id -and $focusSummary.Name -ceq 'Settings' -and $focusSummary.HasKeyboardFocus
    Check ($focusClickReady -and $focusOk) "$Label keyboard focus reaches the Settings navigation tab" ([pscustomobject]@{Focus=$focusSummary;Expected='Settings navigation control owns keyboard focus after an actual desktop mouse click';ClickPoint=@($focusClickX,$focusClickY);ActualMouseClick=$focusClickReady})
    Click-Control $Window 10 "$Label return to Timer after focus-state check"
  }finally{[void][EBR_POST_NATIVE]::SetCursorPos($oldCursor.X,$oldCursor.Y)}
}
function Test-DisabledReleaseLinkState([IntPtr]$Window,[string]$Label){
  [void](Dismiss-WslFirstRunPrompt)
  $oldCursor=New-Object EBR_POST_POINT;$windowRect=New-Object EBR_POST_RECT
  if(-not [EBR_POST_NATIVE]::GetCursorPos([ref]$oldCursor) -or -not [EBR_POST_NATIVE]::GetWindowRect($Window,[ref]$windowRect)){
    Add-Result "$Label disabled official-release link is exposed and stays visually inactive on hover" 'NOT TESTED' 'The runner cursor or app window bounds were unavailable.';return
  }
  try{
    Click-Control $Window 12 "$Label open settings to inspect disabled update link"
    Click-Control $Window 135 "$Label select About settings section"
    $button=[EBR_POST_NATIVE]::ControlById($Window,161);$element=$null;$current=$null
    try{if($button -ne [IntPtr]::Zero){$element=[System.Windows.Automation.AutomationElement]::FromHandle($button);if($element){$current=$element.Current}}}catch{Add-Result "$Label disabled official-release link is exposed and stays visually inactive on hover" 'NOT TESTED' ([pscustomobject]@{Reason='UI Automation could not read the disabled release-link state.';Error=$_.Exception.Message});return}
    if(-not $element -or -not $current){Add-Result "$Label disabled official-release link is exposed and stays visually inactive on hover" 'NOT TESTED' 'The Open Official Release UI Automation element was unavailable.';return}
    $rect=New-Object EBR_POST_RECT
    if(-not [EBR_POST_NATIVE]::GetWindowRect($button,[ref]$rect)){throw 'Could not measure the disabled release-link button.'}
    [void][EBR_POST_NATIVE]::SetCursorPos($windowRect.Left+[int](($windowRect.Right-$windowRect.Left)/3),$windowRect.Top+6);Start-Sleep -Milliseconds 200
    $before=Get-ControlScreenColors $button
    $hoverX=$rect.Left+[int](($rect.Right-$rect.Left)/2);$hoverY=$rect.Top+[int](($rect.Bottom-$rect.Top)/2)
    [void][EBR_POST_NATIVE]::SetCursorPos($hoverX,$hoverY);Start-Sleep -Milliseconds 300
    $after=Get-ControlScreenColors $button
    $changed=$false
    for($i=0;$i -lt $before.Pixels.Count;$i++){if($before.Pixels[$i].Hex -ne $after.Pixels[$i].Hex){$changed=$true}}
    Check (-not $current.IsEnabled) "$Label Open Official Release control is correctly disabled until an update is available" ([pscustomobject]@{Name=$current.Name;ControlType=$current.ControlType.ProgrammaticName;Enabled=$current.IsEnabled;LatestPublicVersion='1.2.0';InstalledPublicVersion='1.2.0'})
    Check (-not $changed) "$Label disabled Open Official Release control does not show an active hover style" ([pscustomobject]@{Before=$before.Pixels;After=$after.Pixels;HoverPoint=@($hoverX,$hoverY);Enabled=$current.IsEnabled;Method='Actual pointer movement and direct GetPixel desktop sampling'})
  }finally{
    [void][EBR_POST_NATIVE]::SetCursorPos($oldCursor.X,$oldCursor.Y)
    Click-Control $Window 10 "$Label return to Timer after disabled-link probe"
  }
}
function Test-PrimaryPressedState([IntPtr]$Window,[string]$Label){
  [void](Dismiss-WslFirstRunPrompt)
  $foreground=Ensure-AppForeground $Window $script:activeProcess.Id
  if(-not $foreground.ApplicationForeground){
    Add-Result "$Label primary-button mouse interaction has the app in the foreground" 'NOT TESTED' ([pscustomobject]@{Reason='The app could not be verified as the foreground desktop window, so physical mouse input was withheld.';Foreground=$foreground})
    Click-Control $Window 22 "$Label begin break after unavailable foreground mouse probe"
    return
  }
  $button=[EBR_POST_NATIVE]::ControlById($Window,22);$rect=New-Object EBR_POST_RECT;$oldCursor=New-Object EBR_POST_POINT
  if($button -eq [IntPtr]::Zero -or -not [EBR_POST_NATIVE]::GetWindowRect($button,[ref]$rect) -or -not [EBR_POST_NATIVE]::GetCursorPos([ref]$oldCursor)){
    Add-Result "$Label primary button pressed state has a visible pixel transition" 'NOT TESTED' 'The primary button bounds or original pointer position were unavailable.';Click-Control $Window 22 "$Label begin break after unavailable press-state probe";return
  }
  $mouseDown=$false
  try{
    $neutralX=$rect.Left-20;$neutralY=$rect.Top-20
    [void][EBR_POST_NATIVE]::SetCursorPos($neutralX,$neutralY);Start-Sleep -Milliseconds 250
    $before=Get-ControlScreenColors $button
    $centerX=$rect.Left+[int](($rect.Right-$rect.Left)/2);$centerY=$rect.Top+[int](($rect.Bottom-$rect.Top)/2)
    [void][EBR_POST_NATIVE]::SetCursorPos($centerX,$centerY);Start-Sleep -Milliseconds 200
    $hitPoint=New-Object EBR_POST_POINT;$hitPoint.X=$centerX;$hitPoint.Y=$centerY
    $hit=[EBR_POST_NATIVE]::WindowFromPoint($hitPoint)
    $hitRoot=if($hit -ne [IntPtr]::Zero){[EBR_POST_NATIVE]::GetAncestor($hit,2)}else{[IntPtr]::Zero}
    if($hitRoot -ne $Window){
      Add-Result "$Label primary-button is the actual desktop hit target" 'NOT TESTED' ([pscustomobject]@{Point=@($centerX,$centerY);HitHandle=('0x{0:X}' -f $hit.ToInt64());HitRoot=('0x{0:X}' -f $hitRoot.ToInt64());ExpectedWindow=('0x{0:X}' -f $Window.ToInt64());Reason='A different window owned the pointer location; no click was sent to it.'})
      [void][EBR_POST_NATIVE]::SetCursorPos($oldCursor.X,$oldCursor.Y)
      Click-Control $Window 22 "$Label begin break after unavailable desktop hit target"
      return
    }
    $hover=Get-ControlScreenColors $button
    [EBR_POST_NATIVE]::mouse_event(0x0002,0,0,0,[UIntPtr]::Zero);$mouseDown=$true;Start-Sleep -Milliseconds 200
    $pressed=Get-ControlScreenColors $button
    $pressedDifferential=$false
    for($i=0;$i -lt $hover.Pixels.Count;$i++){if($hover.Pixels[$i].Hex -ne $pressed.Pixels[$i].Hex){$pressedDifferential=$true}}
    Check $pressedDifferential "$Label real mouse-down state changes visible primary-button pixels" ([pscustomobject]@{Button='Take a break now';Before=$before.Pixels;Hover=$hover.Pixels;Pressed=$pressed.Pixels;Method='Actual desktop mouse down; GetPixel samples taken before mouse up'})
  }finally{
    if($mouseDown){[EBR_POST_NATIVE]::mouse_event(0x0004,0,0,0,[UIntPtr]::Zero);Start-Sleep -Milliseconds 180}
    [void][EBR_POST_NATIVE]::SetCursorPos($oldCursor.X,$oldCursor.Y)
  }
}
function Test-ThemeAndTimerRingMatrix([string]$Label){
  $followLight=1;try{$followLight=[int](Get-ItemPropertyValue -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop)}catch{}
  $colors=@(
    if($followLight -eq 0){@{Work='#60A5FA';Break='#2DD4BF'}}else{@{Work='#1D4ED8';Break='#0F766E'}},
    @{Work='#1D4ED8';Break='#0F766E'},
    @{Work='#60A5FA';Break='#2DD4BF'},
    @{Work='#FFFF00';Break='#00FFFF'},
    @{Work='#0000B3';Break='#005A00'}
  )
  $names=@('Follow Windows Theme','Light','Dark','High Contrast Dark','High Contrast Light')
  foreach($index in 0..4){
    Select-Theme $script:activeWindow $index
    Click-Control $script:activeWindow 21 "$Label reset work timer for $($names[$index])"
    Start-Sleep -Seconds 5
    $workStatus=Get-Status $script:activeWindow
    Check ($workStatus -match 'Running') "$Label $($names[$index]) remains in work mode before ring capture" $workStatus
    Test-TimerRingPixel $script:activeWindow "$Label $($names[$index]) work" $colors[$index].Work (("$Label-$($names[$index])-work-ring.png") -replace '[^a-zA-Z0-9.-]','-') $colors[$index].Break
    Test-TabVisualStates $script:activeWindow "$Label $($names[$index])"
    Test-DisabledReleaseLinkState $script:activeWindow "$Label $($names[$index])"

    $resourcesBeforeBreak=Get-AppResourceSnapshot "$Label $($names[$index]) break with distinct colour enabled before"
    Test-PrimaryPressedState $script:activeWindow "$Label $($names[$index])"
    $breakStatus=Wait-Status $script:activeWindow 'Taking an eye break' 5
    Check ($breakStatus -match 'Taking an eye break') "$Label $($names[$index]) enters break mode" $breakStatus
    $breakWindow=Wait-BreakWindow $script:activeProcess.Id
    Check ($breakWindow -ne [IntPtr]::Zero) "$Label $($names[$index]) reminder window opens" ([pscustomobject]@{Window=('0x{0:X}' -f $breakWindow.ToInt64())})
    Start-Sleep -Seconds 2
    Test-TimerRingPixel $script:activeWindow "$Label $($names[$index]) break with distinct colour enabled" $colors[$index].Break (("$Label-$($names[$index])-break-enabled-ring.png") -replace '[^a-zA-Z0-9.-]','-') $colors[$index].Work
    if($breakWindow -ne [IntPtr]::Zero){Click-Control $breakWindow 24 "$Label dismiss $($names[$index]) break"}
    $returned=Wait-Status $script:activeWindow 'Running' 5
    Check ($returned -match 'Running') "$Label $($names[$index]) returns to work mode" $returned
    Start-Sleep -Milliseconds 300
    Record-AppResourceLifecycle "$Label $($names[$index]) enabled-accent break" $resourcesBeforeBreak (Get-AppResourceSnapshot "$Label $($names[$index]) break with distinct colour enabled after") -RequireStableUserObjects

    Set-BreakColorOption $script:activeWindow $false "$Label $($names[$index]) disabled accent"
    Click-Control $script:activeWindow 21 "$Label reset before disabled-accent break"
    $resourcesBeforeDisabledBreak=Get-AppResourceSnapshot "$Label $($names[$index]) break with distinct colour disabled before"
    Click-Control $script:activeWindow 22 "$Label start break with distinct colour disabled"
    $disabledStatus=Wait-Status $script:activeWindow 'Taking an eye break' 5
    Check ($disabledStatus -match 'Taking an eye break') "$Label $($names[$index]) enters break mode with distinct colour disabled" $disabledStatus
    $disabledBreakWindow=Wait-BreakWindow $script:activeProcess.Id
    Start-Sleep -Seconds 2
    $disabledExpected=if($index -ge 3){$colors[$index].Break}else{$colors[$index].Work}
    $disabledForbidden=if($index -ge 3){$colors[$index].Work}else{$colors[$index].Break}
    Test-TimerRingPixel $script:activeWindow "$Label $($names[$index]) break with distinct colour disabled" $disabledExpected (("$Label-$($names[$index])-break-disabled-ring.png") -replace '[^a-zA-Z0-9.-]','-') $disabledForbidden
    if($disabledBreakWindow -ne [IntPtr]::Zero){Click-Control $disabledBreakWindow 24 "$Label dismiss disabled-accent break"}
    $disabledReturned=Wait-Status $script:activeWindow 'Running' 5
    Check ($disabledReturned -match 'Running') "$Label $($names[$index]) returns to work after disabled-accent break" $disabledReturned
    Start-Sleep -Milliseconds 300
    Record-AppResourceLifecycle "$Label $($names[$index]) disabled-accent break" $resourcesBeforeDisabledBreak (Get-AppResourceSnapshot "$Label $($names[$index]) break with distinct colour disabled after") -RequireStableUserObjects
    Set-BreakColorOption $script:activeWindow $true "$Label $($names[$index]) restore accent option"
  }
  Test-WindowsThemeChanges $Label
  Test-ReducedMotionPreference $Label
}
function Set-WindowsAppAppearance([int]$LightValue,[string]$Label){
  $path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
  if(-not (Test-Path -LiteralPath $path)){New-Item -Path $path -Force|Out-Null}
  New-ItemProperty -LiteralPath $path -Name AppsUseLightTheme -PropertyType DWord -Value $LightValue -Force|Out-Null
  New-ItemProperty -LiteralPath $path -Name SystemUsesLightTheme -PropertyType DWord -Value $LightValue -Force|Out-Null
  $observed=[int](Get-ItemPropertyValue -LiteralPath $path -Name AppsUseLightTheme)
  Check ($observed -eq $LightValue) "$Label Windows appearance preference is applied" ([pscustomobject]@{AppsUseLightTheme=$observed;SystemUsesLightTheme=(Get-ItemPropertyValue -LiteralPath $path -Name SystemUsesLightTheme)})
  $result=[IntPtr]::Zero
  $setting=([EBR_POST_NATIVE]::SendMessageTimeoutW($script:activeWindow,0x001A,[IntPtr]::Zero,[IntPtr]::Zero,2,2000,[ref]$result)-ne [IntPtr]::Zero)
  $result=[IntPtr]::Zero
  $theme=([EBR_POST_NATIVE]::SendMessageTimeoutW($script:activeWindow,0x031A,[IntPtr]::Zero,[IntPtr]::Zero,2,2000,[ref]$result)-ne [IntPtr]::Zero)
  Check ($setting -and $theme) "$Label app responds to actual Windows appearance-change notifications" ([pscustomobject]@{WM_SETTINGCHANGE=$setting;WM_THEMECHANGED=$theme})
}
function Test-WindowsThemeChanges([string]$Label){
  $path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
  $properties=Get-ItemProperty -LiteralPath $path -ErrorAction SilentlyContinue
  $oldApps=$null;$oldSystem=$null
  if($properties){$oldApps=$properties.PSObject.Properties['AppsUseLightTheme'];$oldSystem=$properties.PSObject.Properties['SystemUsesLightTheme']}
  $hadApps=$null -ne $oldApps;$hadSystem=$null -ne $oldSystem
  $appsValue=if($hadApps){[int]$oldApps.Value}else{1};$systemValue=if($hadSystem){[int]$oldSystem.Value}else{$appsValue}
  Add-Result "$Label original runner Windows appearance preference" 'INFO' ([pscustomobject]@{AppsUseLightTheme=$appsValue;SystemUsesLightTheme=$systemValue;RunnerHive='HKCU'})
  try{
    Select-Theme $script:activeWindow 0
    Set-WindowsAppAppearance 0 "$Label follow-Windows dark"
    Click-Control $script:activeWindow 21 "$Label reset timer after Windows dark preference"
    Start-Sleep -Seconds 5
    Test-TimerRingPixel $script:activeWindow "$Label Follow Windows Theme after dark preference" '#60A5FA' "$Label-follow-windows-dark-ring.png" '#2DD4BF'
    Set-WindowsAppAppearance 1 "$Label follow-Windows light"
    Click-Control $script:activeWindow 21 "$Label reset timer after Windows light preference"
    Start-Sleep -Seconds 5
    Test-TimerRingPixel $script:activeWindow "$Label Follow Windows Theme after light preference" '#1D4ED8' "$Label-follow-windows-light-ring.png" '#0F766E'
  }finally{
    if(-not (Test-Path -LiteralPath $path)){New-Item -Path $path -Force|Out-Null}
    if($hadApps){New-ItemProperty -LiteralPath $path -Name AppsUseLightTheme -PropertyType DWord -Value $appsValue -Force|Out-Null}else{Remove-ItemProperty -LiteralPath $path -Name AppsUseLightTheme -ErrorAction SilentlyContinue}
    if($hadSystem){New-ItemProperty -LiteralPath $path -Name SystemUsesLightTheme -PropertyType DWord -Value $systemValue -Force|Out-Null}else{Remove-ItemProperty -LiteralPath $path -Name SystemUsesLightTheme -ErrorAction SilentlyContinue}
    $restoredApps=if($hadApps){[int](Get-ItemPropertyValue -LiteralPath $path -Name AppsUseLightTheme) -eq $appsValue}else{$null -eq (Get-ItemProperty -LiteralPath $path -Name AppsUseLightTheme -ErrorAction SilentlyContinue)}
    $restoredSystem=if($hadSystem){[int](Get-ItemPropertyValue -LiteralPath $path -Name SystemUsesLightTheme) -eq $systemValue}else{$null -eq (Get-ItemProperty -LiteralPath $path -Name SystemUsesLightTheme -ErrorAction SilentlyContinue)}
    Check ($restoredApps -and $restoredSystem) "$Label restores the runner Windows appearance preferences" ([pscustomobject]@{AppsRestored=$restoredApps;SystemRestored=$restoredSystem;OriginalApps=$appsValue;OriginalSystem=$systemValue})
    $result=[IntPtr]::Zero
    [void][EBR_POST_NATIVE]::SendMessageTimeoutW($script:activeWindow,0x001A,[IntPtr]::Zero,[IntPtr]::Zero,2,2000,[ref]$result)
    $result=[IntPtr]::Zero
    [void][EBR_POST_NATIVE]::SendMessageTimeoutW($script:activeWindow,0x031A,[IntPtr]::Zero,[IntPtr]::Zero,2,2000,[ref]$result)
  }
}
function Test-ReducedMotionPreference([string]$Label){
  [int]$original=1
  if(-not [EBR_POST_NATIVE]::SystemParametersInfoW(0x1042,0,[ref]$original,0)){Add-Result "$Label reduced-motion preference can be queried" 'NOT TESTED' ([Runtime.InteropServices.Marshal]::GetLastWin32Error());return}
  $restoreNeeded=$false;$restoreWindow=$false;$originalBounds=New-Object EBR_POST_RECT
  if(-not [EBR_POST_NATIVE]::GetWindowRect($script:activeWindow,[ref]$originalBounds)){throw 'Could not preserve the app bounds before the reduced-motion test.'}
  try{
    # SPI_SETCLIENTAREAANIMATION takes a scalar BOOL cast to pvParam, whereas GET takes a BOOL pointer.
    # Exercise an actual enabled-to-disabled transition even if this disposable runner started with animations off.
    $restoreNeeded=$true
    $enabled=[EBR_POST_NATIVE]::SystemParametersInfoSetScalar(0x1043,0,[IntPtr]::new(1),2)
    [int]$enabledObserved=0;$enabledRead=[EBR_POST_NATIVE]::SystemParametersInfoW(0x1042,0,[ref]$enabledObserved,0)
    if(-not $enabled -or -not $enabledRead -or $enabledObserved -ne 1){
      Add-Result "$Label actual Windows animation preference transition" 'NOT TESTED' ([pscustomobject]@{Set=$enabled;Read=$enabledRead;Original=$original;ClientAreaAnimations=$enabledObserved;Reason='The disposable runner did not enable client-area animations before the controlled reduced-motion transition.'});return
    }
    $set=[EBR_POST_NATIVE]::SystemParametersInfoSetScalar(0x1043,0,[IntPtr]::Zero,2)
    [int]$observed=1;$read=[EBR_POST_NATIVE]::SystemParametersInfoW(0x1042,0,[ref]$observed,0)
    if(-not $set -or -not $read -or $observed -ne 0){
      Add-Result "$Label actual Windows reduced-motion preference is disabled" 'NOT TESTED' ([pscustomobject]@{Set=$set;Read=$read;Original=$original;ClientAreaAnimations=$observed;Reason='The disposable runner did not apply the disabled client-area animation preference; no reduced-motion behavior conclusion is drawn.'});return
    }
    Add-Result "$Label actual Windows reduced-motion preference is disabled" 'PASS' ([pscustomobject]@{Original=$original;EnabledBeforeTransition=$enabledObserved;Set=$set;Read=$read;ClientAreaAnimations=$observed;Method='SystemParametersInfo SPI_SETCLIENTAREAANIMATION with scalar BOOL; both states read back from Windows'})
    $result=[IntPtr]::Zero
    [void][EBR_POST_NATIVE]::SendMessageTimeoutW($script:activeWindow,0x001A,[IntPtr]::Zero,[IntPtr]::Zero,2,2000,[ref]$result)
    Click-Control $script:activeWindow 12 "$Label Settings navigation for reduced-motion test"
    Click-Control $script:activeWindow 134 "$Label General section for reduced-motion test"
    $dpi=[Math]::Max(96,[int][EBR_POST_NATIVE]::GetDpiForWindow($script:activeWindow))
    $targetWidth=[int][Math]::Min($originalBounds.Right-$originalBounds.Left,600*$dpi/96)
    $targetHeight=[int][Math]::Min($originalBounds.Bottom-$originalBounds.Top,620*$dpi/96)
    $restoreWindow=$true
    $resized=[EBR_POST_NATIVE]::SetWindowPos($script:activeWindow,[IntPtr]::Zero,$originalBounds.Left,$originalBounds.Top,$targetWidth,$targetHeight,0x0014)
    $actualBounds=New-Object EBR_POST_RECT;[void][EBR_POST_NATIVE]::GetWindowRect($script:activeWindow,[ref]$actualBounds)
    Add-Result "$Label reduced-motion app viewport preparation" 'INFO' ([pscustomobject]@{SetWindowPos=$resized;Original=$originalBounds;RequestedWidth=$targetWidth;RequestedHeight=$targetHeight;Actual=$actualBounds;Reason='A supported smaller app viewport creates General settings overflow; original app bounds are restored in finally.'})
    $combo=[EBR_POST_NATIVE]::ControlById($script:activeWindow,106);$pane=[EBR_POST_NATIVE]::GetParent($combo);$before=New-Object EBR_POST_RECT
    if($combo -eq [IntPtr]::Zero -or $pane -eq [IntPtr]::Zero -or -not [EBR_POST_NATIVE]::GetWindowRect($combo,[ref]$before)){throw 'Could not measure the General settings scroll position.'}
    $scrollInfo=New-Object EBR_POST_SCROLLINFO;$scrollInfo.cbSize=[uint32][Runtime.InteropServices.Marshal]::SizeOf($scrollInfo);$scrollInfo.fMask=0x17
    if(-not [EBR_POST_NATIVE]::GetScrollInfo($pane,1,[ref]$scrollInfo)){Add-Result "$Label settings scrolling applies immediately with reduced motion" 'NOT TESTED' ([pscustomobject]@{Reason='Could not read the settings pane scroll range.'});return}
    if([long]$scrollInfo.nMax+1 -le [long]$scrollInfo.nPage){Add-Result "$Label settings scrolling applies immediately with reduced motion" 'NOT TESTED' ([pscustomobject]@{Reason='The actual smaller app viewport still had no General settings overflow.';Maximum=$scrollInfo.nMax;Page=$scrollInfo.nPage;Bounds=$actualBounds});return}
    $result=[IntPtr]::Zero
    $toTop=([EBR_POST_NATIVE]::SendMessageTimeoutW($pane,0x0115,[IntPtr]::new(6),[IntPtr]::Zero,2,2000,[ref]$result)-ne [IntPtr]::Zero)
    [void][EBR_POST_NATIVE]::GetScrollInfo($pane,1,[ref]$scrollInfo);[void][EBR_POST_NATIVE]::GetWindowRect($combo,[ref]$before)
    $initialPosition=$scrollInfo.nPos;$maximumPosition=[Math]::Max(0,[long]$scrollInfo.nMax-[long]$scrollInfo.nPage+1)
    $expectedPosition=[Math]::Min($maximumPosition,[long]$initialPosition+[long]$scrollInfo.nPage)
    $sent=([EBR_POST_NATIVE]::SendMessageTimeoutW($pane,0x0115,[IntPtr]::new(3),[IntPtr]::Zero,2,2000,[ref]$result)-ne [IntPtr]::Zero)
    $after=New-Object EBR_POST_RECT;$readPosition=[EBR_POST_NATIVE]::GetScrollInfo($pane,1,[ref]$scrollInfo);$readBounds=[EBR_POST_NATIVE]::GetWindowRect($combo,[ref]$after)
    $immediatePosition=$scrollInfo.nPos;$moved=$before.Top-$after.Top
    Check ($toTop -and $sent -and $readPosition -and $readBounds -and $expectedPosition -gt $initialPosition -and $immediatePosition -eq $expectedPosition -and $moved -eq ($expectedPosition-$initialPosition)) "$Label settings scrolling applies immediately with reduced motion" ([pscustomobject]@{Input='Controlled Win32 WM_VSCROLL SB_PAGEDOWN to the actual settings pane';Observation='First scroll position and child bounds read immediately after the synchronous input returns, without a settling wait';BeforeTop=$before.Top;AfterTop=$after.Top;MovedPixels=$moved;InitialPosition=$initialPosition;ExpectedPosition=$expectedPosition;ImmediatePosition=$immediatePosition;ScrollMaximum=$scrollInfo.nMax;ScrollPage=$scrollInfo.nPage})
    Start-Sleep -Milliseconds 250
    $settled=New-Object EBR_POST_RECT;$readSettledPosition=[EBR_POST_NATIVE]::GetScrollInfo($pane,1,[ref]$scrollInfo);$readSettledBounds=[EBR_POST_NATIVE]::GetWindowRect($combo,[ref]$settled)
    Check ($readSettledPosition -and $readSettledBounds -and $scrollInfo.nPos -eq $immediatePosition -and $settled.Top -eq $after.Top) "$Label reduced-motion scrolling has no later animation movement" ([pscustomobject]@{ImmediatePosition=$immediatePosition;PositionAfter250ms=$scrollInfo.nPos;ImmediateTop=$after.Top;TopAfter250ms=$settled.Top})
  }finally{
    if($restoreWindow){
      $windowRestored=[EBR_POST_NATIVE]::SetWindowPos($script:activeWindow,[IntPtr]::Zero,$originalBounds.Left,$originalBounds.Top,$originalBounds.Right-$originalBounds.Left,$originalBounds.Bottom-$originalBounds.Top,0x0014)
      $finalBounds=New-Object EBR_POST_RECT;$boundsRead=[EBR_POST_NATIVE]::GetWindowRect($script:activeWindow,[ref]$finalBounds)
      Check ($windowRestored -and $boundsRead -and $finalBounds.Left -eq $originalBounds.Left -and $finalBounds.Top -eq $originalBounds.Top -and $finalBounds.Right -eq $originalBounds.Right -and $finalBounds.Bottom -eq $originalBounds.Bottom) "$Label restores app bounds after reduced-motion test" ([pscustomobject]@{Original=$originalBounds;Final=$finalBounds;SetWindowPos=$windowRestored})
    }
    if($restoreNeeded){
      $restored=[EBR_POST_NATIVE]::SystemParametersInfoSetScalar(0x1043,0,[IntPtr]::new($original),2)
      [int]$final=1
      $read=[EBR_POST_NATIVE]::SystemParametersInfoW(0x1042,0,[ref]$final,0)
      if($restored -and $read -and $final -eq $original){Check ($true) "$Label restores the original reduced-motion preference" ([pscustomobject]@{Set=$restored;Read=$read;Original=$original;Final=$final})}
      else{Add-Result "$Label restores the original reduced-motion preference" 'FAIL' ([pscustomobject]@{Set=$restored;Read=$read;Original=$original;Final=$final;Reason='The attempted Windows preference restoration did not match the saved original value.'})}
    }else{Add-Result "$Label original reduced-motion preference did not need changing" 'INFO' ([pscustomobject]@{Original=$original})}
    $result=[IntPtr]::Zero
    [void][EBR_POST_NATIVE]::SendMessageTimeoutW($script:activeWindow,0x001A,[IntPtr]::Zero,[IntPtr]::Zero,2,2000,[ref]$result)
    try{Click-Control $script:activeWindow 10 "$Label Timer navigation after reduced-motion test"}catch{Add-Result "$Label Timer navigation after reduced-motion test" 'FAIL' $_.Exception.Message}
  }
}
function Test-InterruptedBreakRestart([string]$Label){
  Click-Control $script:activeWindow 22 "$Label start a break before restart"
  $breakStatus=Wait-Status $script:activeWindow 'Taking an eye break' 5
  Check ($breakStatus -match 'Taking an eye break') "$Label enters break state before restart" $breakStatus
  $oldProcess=$script:activeProcess;$closed=Stop-OwnedApp;$oldProcess.Refresh()
  Check ($closed -and $oldProcess.HasExited) "$Label cleanly exits while break is active" ([pscustomobject]@{Pid=$oldProcess.Id;ExitCode=$oldProcess.ExitCode;Exited=$oldProcess.HasExited})
  $script:activeProcess=Start-Process -FilePath $script:activeExecutablePath -WorkingDirectory (Split-Path -Parent $script:activeExecutablePath) -PassThru
  $script:activeWindow=Get-MainWindow $script:activeProcess.Id
  Check ($script:activeWindow -ne [IntPtr]::Zero) "$Label restarts the exact published executable after interrupted break" ([pscustomobject]@{Pid=$script:activeProcess.Id;Path=$script:activeExecutablePath})
  if($script:activeWindow -eq [IntPtr]::Zero){Stop-OwnedApp;return}
  $status=Wait-Status $script:activeWindow 'Running' 5
  $countdownControl=[EBR_POST_NATIVE]::ControlById($script:activeWindow,40);$countdown=if($countdownControl -ne [IntPtr]::Zero){[EBR_POST_NATIVE]::Text($countdownControl)}else{''}
  $breakAfter=(Get-BreakWindow $script:activeProcess.Id) -ne [IntPtr]::Zero
  $countdownSeconds=-1
  if($countdown -match '^(\d{1,2}):(\d{2})$'){$countdownSeconds=([int]$Matches[1]*60)+[int]$Matches[2]}
  $freshIntervalSeconds=60
  Check ($status -match 'Running' -and $countdownSeconds -ge ($freshIntervalSeconds - 5) -and $countdownSeconds -le $freshIntervalSeconds -and -not $breakAfter) "$Label interrupted break recovers with a fresh one-minute work interval" ([pscustomobject]@{Status=$status;ExpectedFreshIntervalSeconds=$freshIntervalSeconds;AcceptedStartupRangeSeconds='55-60 seconds';ActualCountdown=$countdown;ActualSeconds=$countdownSeconds;BreakWindowAfterRestart=$breakAfter})
}
function Stop-OwnedApp {
  $graceful=$false
  if($script:activeProcess -and -not $script:activeProcess.HasExited){
    if($script:activeWindow -ne [IntPtr]::Zero){
      $exitMessage=[EBR_POST_NATIVE]::RegisterWindowMessageW('EyeBreakReminder.Exit.Native.1')
      [void][EBR_POST_NATIVE]::PostMessageW($script:activeWindow,$exitMessage,[IntPtr]::Zero,[IntPtr]::Zero)
    }
    $graceful=$script:activeProcess.WaitForExit(10000)
    if(-not $graceful){Stop-Process -Id $script:activeProcess.Id -Force -ErrorAction SilentlyContinue;[void]$script:activeProcess.WaitForExit(5000)}
  }
  $script:activeProcess=$null;$script:activeWindow=[IntPtr]::Zero
  return $graceful
}
function Test-PublishedExecutable([string]$Path,[string]$Label){
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){throw "$Label executable is missing: $Path"}
  $hash=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
  Check ($hash -ceq $expected) "$Label launch candidate has the exact published EXE hash" ([pscustomobject]@{Path=$Path;SHA256=$hash})
  if($hash -cne $expected){throw "$Label candidate is not the exact published executable."}
  $version=(Get-Item -LiteralPath $Path).VersionInfo
  Check ($version.ProductVersion -match '^1\.2\.0' -and $version.ProductName -eq 'Eye Break Reminder') "$Label metadata reports Eye Break Reminder v1.2.0" ([pscustomobject]@{ProductName=$version.ProductName;ProductVersion=$version.ProductVersion;FileVersion=$version.FileVersion})

  $script:activeExecutablePath=[IO.Path]::GetFullPath($Path)
  $testData=Join-Path $env:LOCALAPPDATA 'EyeBreakReminder'
  [void][IO.Directory]::CreateDirectory($testData)
  $testSettings="workMinutes=1`nbreakSeconds=20`ntheme=2`nbreakModeColors=1`nalarm=0`nnotifications=0`nrepeat=0`n"
  [IO.File]::WriteAllText((Join-Path $testData 'settings.ini'),$testSettings,[Text.UTF8Encoding]::new($false))
  Add-Result "$Label disposable isolated profile prepared with short timer intervals and muted alarm" 'INFO' ([pscustomobject]@{DataDirectory=$testData;WorkMinutes=1;BreakSeconds=20;AlarmEnabled=$false;NotificationsEnabled=$false;Reason='Exercise timer and break UI without invoking unverified runner audio or Shell notification devices.';SettingsFile=Join-Path $testData 'settings.ini'})

  $script:activeProcess=Start-Process -FilePath $Path -WorkingDirectory (Split-Path -Parent $Path) -PassThru
  $script:activeWindow=Get-MainWindow $script:activeProcess.Id
  Check ($script:activeWindow -ne [IntPtr]::Zero) "$Label process exposes its real Win32 main window" ([pscustomobject]@{Pid=$script:activeProcess.Id;Window=('0x{0:X}' -f $script:activeWindow.ToInt64())})
  if($script:activeWindow -eq [IntPtr]::Zero){Stop-OwnedApp;return}
  $foreground=Ensure-AppForeground $script:activeWindow $script:activeProcess.Id
  if($foreground.ApplicationForeground){Add-Result "$Label main window is the visible desktop foreground" 'PASS' $foreground}
  else{
    $diagnosticPath=$null
    if(-not $script:foregroundDiagnosticCaptured){try{$diagnosticPath=Capture-DesktopDiagnostic 'desktop-foreground-obstruction.png';$script:foregroundDiagnosticCaptured=$true}catch{}}
    $foreground|Add-Member -NotePropertyName DesktopDiagnostic -NotePropertyValue $diagnosticPath
    Add-Result "$Label main window is the visible desktop foreground" 'NOT TESTED' $foreground
  }
  $actualPath=''
  try{$actualPath=[IO.Path]::GetFullPath((Get-Process -Id $script:activeProcess.Id -ErrorAction Stop).Path)}catch{}
  Check ($actualPath -ieq [IO.Path]::GetFullPath($Path)) "$Label launch runs from the downloaded release path" ([pscustomobject]@{Expected=$Path;Actual=$actualPath})

  $nativeResult=[IntPtr]::Zero
  $responds=([EBR_POST_NATIVE]::SendMessageTimeoutW($script:activeWindow,0x0000,[IntPtr]::Zero,[IntPtr]::Zero,2,1500,[ref]$nativeResult) -ne [IntPtr]::Zero)
  Check $responds "$Label main window responds to a bounded Win32 UI message" ([pscustomobject]@{Responsive=$responds})
  $names=@()
  try{
    $root=[System.Windows.Automation.AutomationElement]::FromHandle($script:activeWindow)
    $nodes=$root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
    $names=@($nodes | ForEach-Object {try{$_.Current.Name}catch{''}} | Where-Object {$_} | Select-Object -Unique)
  }catch{}
  $required=@('Timer','History','Settings')
  $missing=@($required | Where-Object {$names -notcontains $_})
  Check ($missing.Count -eq 0) "$Label exposes Timer, History, and Settings through Windows UI Automation" ([pscustomobject]@{Missing=$missing;Names=$names})
  $status=Get-Status $script:activeWindow
  Check ($status -match 'Running|Paused') "$Label exposes an operational timer status" $status
  $timer=[EBR_POST_NATIVE]::GetDlgItem($script:activeWindow,40)
  $countdown=if($timer -ne [IntPtr]::Zero){[EBR_POST_NATIVE]::Text($timer)}else{''}
  Check ($countdown -match '^\d{1,2}:\d{2}$') "$Label exposes a formatted countdown" $countdown
  $script:expectedWorkCountdown=$countdown
  Capture $script:activeWindow (("$Label" -replace '[^a-zA-Z0-9]+','-').Trim('-')+'-timer-before.png') | Out-Null

  $resourcesBeforePauseResume=Get-AppResourceSnapshot "$Label before pause/resume/reset state changes"
  Click-Control $script:activeWindow 20 "$Label pause"
  $paused=Wait-Status $script:activeWindow 'Paused'
  Check ($paused -match 'Paused') "$Label pauses through its real timer button" $paused
  Click-Control $script:activeWindow 20 "$Label resume"
  $resumed=Wait-Status $script:activeWindow 'Running'
  Check ($resumed -match 'Running') "$Label resumes through its real timer button" $resumed
  Click-Control $script:activeWindow 21 "$Label reset"
  $reset=Wait-Status $script:activeWindow 'Running'
  Check ($reset -match 'Running') "$Label resets the work timer and remains in work mode" $reset
  Record-AppResourceLifecycle "$Label pause/resume/reset state changes" $resourcesBeforePauseResume (Get-AppResourceSnapshot "$Label after pause/resume/reset state changes")

  Click-Control $script:activeWindow 11 "$Label History navigation"
  $historyRoot=[System.Windows.Automation.AutomationElement]::FromHandle($script:activeWindow)
  $historyNodes=$historyRoot.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
  $historyNames=@($historyNodes | ForEach-Object {try{$_.Current.Name}catch{''}} | Where-Object {$_})
  Check (@($historyNames | Where-Object {$_ -eq 'History'}).Count -gt 0) "$Label opens the History page" $historyNames
  Click-Control $script:activeWindow 12 "$Label Settings navigation"
  $settingsRoot=[System.Windows.Automation.AutomationElement]::FromHandle($script:activeWindow)
  $settingsNodes=$settingsRoot.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
  $settingsNames=@($settingsNodes | ForEach-Object {try{$_.Current.Name}catch{''}} | Where-Object {$_})
  Check (@($settingsNames | Where-Object {$_ -eq 'Settings'}).Count -gt 0) "$Label opens the Settings page" $settingsNames
  Click-Control $script:activeWindow 10 "$Label Timer navigation"
  $timerStatus=Get-Status $script:activeWindow
  Check ($timerStatus -match 'Running') "$Label returns to the Timer page" $timerStatus

  Test-ThemeAndTimerRingMatrix $Label
  Test-InterruptedBreakRestart $Label

  $second=Start-Process -FilePath $Path -WorkingDirectory (Split-Path -Parent $Path) -PassThru
  [void]$second.WaitForExit(8000)
  $second.Refresh()
  Start-Sleep -Milliseconds 300
  $owned=@(Get-Process -Name EyeBreakReminder -ErrorAction SilentlyContinue | Where-Object {try{[IO.Path]::GetFullPath($_.Path) -ieq [IO.Path]::GetFullPath($Path)}catch{$false}})
  Check ($owned.Count -eq 1) "$Label duplicate launch routes to one running process" ([pscustomobject]@{ProcessCount=$owned.Count;PrimaryPid=$script:activeProcess.Id;SecondPid=$second.Id;SecondExited=$second.HasExited})
  Capture $script:activeWindow (("$Label" -replace '[^a-zA-Z0-9]+','-').Trim('-')+'-timer-after-actions.png') | Out-Null

  $primaryProcess=$script:activeProcess
  $gracefulExit=Stop-OwnedApp
  $primaryProcess.Refresh()
  Check ($gracefulExit -and $primaryProcess.HasExited) "$Label app closed through its own exit request" ([pscustomobject]@{Pid=$primaryProcess.Id;Exited=$primaryProcess.HasExited;Graceful=$gracefulExit})
}
try{
  [void][IO.Directory]::CreateDirectory($EvidenceDirectory)
  Probe-FailedDeferWindowPos 'Windows runner'
  $waveOutDevices=[EBR_POST_NATIVE]::waveOutGetNumDevs()
  Add-Result 'Production audio output and loopback capture' 'NOT TESTED' ([pscustomobject]@{WaveOutDeviceCount=$waveOutDevices;Reason='The isolated smoke profile disables alarms; no WASAPI loopback capture or physical speaker audibility test was performed.'})
  if(-not [Environment]::UserInteractive -or [EBR_POST_NATIVE]::FindWindowW('Shell_TrayWnd',$null) -eq [IntPtr]::Zero){
    Add-Result 'Standalone and portable published binary interactive smoke' 'NOT TESTED' 'The hosted runner did not expose an interactive Explorer desktop/taskbar.'
  }else{
    $dataDir=Join-Path $env:LOCALAPPDATA 'EyeBreakReminder'
    $installDir=Join-Path $env:LOCALAPPDATA 'Programs\EyeBreakReminder'
    if(Test-Path -LiteralPath $dataDir){throw "Refusing to overwrite pre-existing runner application data: $dataDir"}
    if(Test-Path -LiteralPath $installDir){throw "Refusing to overwrite pre-existing installation: $installDir"}
    $script:ownedData=$true
    Test-PublishedExecutable $StandalonePath 'Published standalone EXE'
    if(Test-Path -LiteralPath $dataDir){Remove-Item -LiteralPath $dataDir -Recurse -Force}
    Test-PublishedExecutable $PortableExecutablePath 'Published portable ZIP executable'
  }
}catch{Add-Result 'Published standalone/portable executable smoke runner' 'FAIL' $_.Exception.Message}
finally{
  try{Stop-OwnedApp}catch{Add-Result 'Owned app process cleanup' 'FAIL' $_.Exception.Message}
  if($script:ownedData){
    $dataDir=Join-Path $env:LOCALAPPDATA 'EyeBreakReminder'
    if(Test-Path -LiteralPath $dataDir){try{Remove-Item -LiteralPath $dataDir -Recurse -Force;Add-Result 'Disposable runner smoke data cleanup' 'PASS' $dataDir}catch{Add-Result 'Disposable runner smoke data cleanup' 'FAIL' $_.Exception.Message}}
  }
  $summary=[pscustomobject]@{
    Application='Eye Break Reminder'
    Release='v1.2.0'
    ExpectedSHA256=$expected
    Events=$events.ToArray()
    ResourceSamples=$resourceSamples.ToArray()
    Pass=(@($events|Where-Object Status -eq 'PASS')).Count
    Fail=(@($events|Where-Object Status -eq 'FAIL')).Count
    NotTested=(@($events|Where-Object Status -eq 'NOT TESTED')).Count
    Informational=(@($events|Where-Object Status -eq 'INFO')).Count
    CompletedUtc=[DateTime]::UtcNow.ToString('o')
  }
  $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'published-exe-smoke.json') -Encoding UTF8
  $summary | ConvertTo-Json -Depth 8
}
if($summary.Fail -gt 0){exit 1}
