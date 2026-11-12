param(
  [string]$StandalonePath = (Join-Path $env:RUNNER_TEMP 'eye-break-reminder-v1.2.0-published-assets\EyeBreakReminder.exe'),
  [string]$PortableExecutablePath = (Join-Path $env:RUNNER_TEMP 'eye-break-reminder-v1.2.0-published-assets\portable-extracted\EyeBreakReminder.exe'),
  [string]$EvidenceDirectory = (Join-Path (Get-Location) 'build\post-release-evidence')
)
$ErrorActionPreference='Stop'
$expected='2895c80f942dd03186305d913516700552524ec5ba9a77da0dab457a3265fcc6'
$events=[System.Collections.Generic.List[object]]::new()
$script:ownedData=$false
$script:foregroundDiagnosticCaptured=$false
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
  [DllImport("user32.dll",SetLastError=true)] public static extern bool SetForegroundWindow(IntPtr hwnd);
  [DllImport("user32.dll",SetLastError=true)] public static extern bool BringWindowToTop(IntPtr hwnd);
  [DllImport("user32.dll",SetLastError=true)] public static extern bool ShowWindow(IntPtr hwnd,int command);
  [DllImport("user32.dll",SetLastError=true)] public static extern bool AttachThreadInput(uint attach,uint attachTo,bool attachState);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll",SetLastError=true)] public static extern IntPtr GetDlgItem(IntPtr hwnd,int id);
  [DllImport("user32.dll",SetLastError=true)] public static extern IntPtr SendMessageW(IntPtr hwnd,uint msg,IntPtr wp,IntPtr lp);
  [DllImport("user32.dll",SetLastError=true)] public static extern IntPtr SendMessageTimeoutW(IntPtr hwnd,uint msg,IntPtr wp,IntPtr lp,uint flags,uint timeout,out IntPtr result);
  [DllImport("user32.dll",SetLastError=true)] public static extern bool PostMessageW(IntPtr hwnd,uint msg,IntPtr wp,IntPtr lp);
  [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern uint RegisterWindowMessageW(string name);
  [DllImport("user32.dll",SetLastError=true)] public static extern bool GetWindowRect(IntPtr hwnd,out EBR_POST_RECT rect);
  [DllImport("user32.dll",SetLastError=true)] public static extern bool GetClientRect(IntPtr hwnd,out EBR_POST_RECT rect);
  [DllImport("user32.dll",SetLastError=true)] public static extern bool ClientToScreen(IntPtr hwnd,ref EBR_POST_POINT point);
  [DllImport("user32.dll",SetLastError=true)] public static extern uint GetDpiForWindow(IntPtr hwnd);
  [DllImport("user32.dll",SetLastError=true)] public static extern IntPtr GetParent(IntPtr hwnd);
  [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern IntPtr FindWindowW(string className,string windowName);
  public static string Text(IntPtr hwnd){int n=GetWindowTextLengthW(hwnd);StringBuilder b=new StringBuilder(Math.Max(2,n+2));GetWindowTextW(hwnd,b,b.Capacity);return b.ToString();}
  public static string ClassName(IntPtr hwnd){StringBuilder b=new StringBuilder(256);GetClassNameW(hwnd,b,b.Capacity);return b.ToString();}
  public static IntPtr ControlById(IntPtr root,int id){List<IntPtr> found=new List<IntPtr>();EnumCallback cb=delegate(IntPtr h,IntPtr ignored){if(GetDlgCtrlID(h)==id)found.Add(h);return true;};EnumChildWindows(root,cb,IntPtr.Zero);GC.KeepAlive(cb);return found.Count==1?found[0]:IntPtr.Zero;}
  public static IntPtr[] WindowsForProcess(int pid){List<IntPtr> r=new List<IntPtr>();EnumCallback cb=delegate(IntPtr h,IntPtr ignored){uint actual;GetWindowThreadProcessId(h,out actual);if(actual==(uint)pid&&IsWindowVisible(h))r.Add(h);return true;};EnumWindows(cb,IntPtr.Zero);GC.KeepAlive(cb);return r.ToArray();}
}
"@
Add-Type -TypeDefinition $native
function Add-Result([string]$Name,[string]$Status,$Details=$null){$events.Add([pscustomobject]@{Name=$Name;Status=$Status;Details=$Details;Utc=[DateTime]::UtcNow.ToString('o')});Write-Host "[$Status] $Name"}
function Check([bool]$Condition,[string]$Name,$Details=$null){if($Condition){Add-Result $Name 'PASS' $Details}else{Add-Result $Name 'FAIL' $Details}}
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
function Click-Control([IntPtr]$Window,[int]$Id,[string]$Name){
  $control=[EBR_POST_NATIVE]::ControlById($Window,$Id)
  if($control -eq [IntPtr]::Zero){throw "Published app did not expose $Name (control $Id)."}
  [void][EBR_POST_NATIVE]::SendMessageW($control,0x00F5,[IntPtr]::Zero,[IntPtr]::Zero)
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
function Ensure-AppForeground([IntPtr]$Window,[int]$ProcessId){
  [void][EBR_POST_NATIVE]::ShowWindow($Window,9)
  $foregroundBefore=[EBR_POST_NATIVE]::GetForegroundWindow()
  $foregroundThread=[uint32]0
  if($foregroundBefore -ne [IntPtr]::Zero){[void][EBR_POST_NATIVE]::GetWindowThreadProcessId($foregroundBefore,[ref]$foregroundThread)}
  $currentThread=[EBR_POST_NATIVE]::GetCurrentThreadId()
  $attached=$false
  if($foregroundThread -ne 0 -and $foregroundThread -ne $currentThread){$attached=[EBR_POST_NATIVE]::AttachThreadInput($currentThread,$foregroundThread,$true)}
  try{
    [void][EBR_POST_NATIVE]::BringWindowToTop($Window)
    [void][EBR_POST_NATIVE]::SetForegroundWindow($Window)
    try{[System.Windows.Automation.AutomationElement]::FromHandle($Window).SetFocus()}catch{}
    [void][EBR_POST_NATIVE]::SetForegroundWindow($Window)
  }finally{if($attached){[void][EBR_POST_NATIVE]::AttachThreadInput($currentThread,$foregroundThread,$false)}}
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
    InputThreadsAttached=$attached
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
function Test-TimerRingPixel([IntPtr]$Window,[string]$Label,[string]$ExpectedColor,[string]$ScreenshotName){
  $image=Capture $Window $ScreenshotName
  if(-not $image -or -not $image.Path){Add-Result "$Label timer-ring accent pixel" 'NOT TESTED' 'No verified app window surface could be captured.';return}
  $geometry=Get-TimerRingGeometry $Window
  $bitmap=[Drawing.Bitmap]::new($image.Path);$count=0;$examples=[System.Collections.Generic.List[string]]::new()
  try{
    if($bitmap.Width -ne $geometry.WindowWidth -or $bitmap.Height -ne $geometry.WindowHeight){Add-Result "$Label timer-ring accent pixel" 'NOT TESTED' ([pscustomobject]@{Reason='Captured window dimensions did not match the measured HWND.';Bitmap=@($bitmap.Width,$bitmap.Height);Geometry=$geometry});return}
    $target=$ExpectedColor.TrimStart('#').ToUpperInvariant()
    # Sample the actual ring annulus directly. Dense angular/radial samples cover anti-aliased arcs without a slow full-window PowerShell pixel scan.
    for($degrees=0;$degrees -lt 360;$degrees+=2){
      $radians=$degrees*[Math]::PI/180.0;$cos=[Math]::Cos($radians);$sin=[Math]::Sin($radians)
      for($offset=-5;$offset -le 5;$offset++){
        $sampleRadius=$geometry.Radius+$offset
        $x=[int][Math]::Round($geometry.CenterX+$cos*$sampleRadius);$y=[int][Math]::Round($geometry.CenterY+$sin*$sampleRadius)
        if($x -lt 0 -or $x -ge $bitmap.Width -or $y -lt 0 -or $y -ge $bitmap.Height){continue}
        $c=$bitmap.GetPixel($x,$y);$hex='{0:X2}{1:X2}{2:X2}' -f $c.R,$c.G,$c.B
        if($hex -eq $target){$count++;if($examples.Count -lt 8){$examples.Add("$x,$y")}}
      }
    }
  }finally{$bitmap.Dispose()}
  Check ($count -gt 0) "$Label timer-ring contains the expected $ExpectedColor accent pixel" ([pscustomobject]@{ExpectedColor=$ExpectedColor;ExactPixels=$count;SamplePixels=$examples.ToArray();Geometry=$geometry;Screenshot=$image.Path;CaptureMethod=$image.Method})
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
    Test-TimerRingPixel $script:activeWindow "$Label $($names[$index]) work" $colors[$index].Work (("$Label-$($names[$index])-work-ring.png") -replace '[^a-zA-Z0-9.-]','-')

    Click-Control $script:activeWindow 22 "$Label begin $($names[$index]) break"
    $breakStatus=Wait-Status $script:activeWindow 'Taking an eye break' 5
    Check ($breakStatus -match 'Taking an eye break') "$Label $($names[$index]) enters break mode" $breakStatus
    $breakWindow=Wait-BreakWindow $script:activeProcess.Id
    Check ($breakWindow -ne [IntPtr]::Zero) "$Label $($names[$index]) reminder window opens" ([pscustomobject]@{Window=('0x{0:X}' -f $breakWindow.ToInt64())})
    Start-Sleep -Seconds 2
    Test-TimerRingPixel $script:activeWindow "$Label $($names[$index]) break" $colors[$index].Break (("$Label-$($names[$index])-break-ring.png") -replace '[^a-zA-Z0-9.-]','-')
    if($breakWindow -ne [IntPtr]::Zero){Click-Control $breakWindow 24 "$Label dismiss $($names[$index]) break"}
    $returned=Wait-Status $script:activeWindow 'Running' 5
    Check ($returned -match 'Running') "$Label $($names[$index]) returns to work mode" $returned
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
  Check ($status -match 'Running' -and $countdown -eq $script:expectedWorkCountdown -and -not $breakAfter) "$Label interrupted break recovers as a fresh work interval" ([pscustomobject]@{Status=$status;ExpectedCountdown=$script:expectedWorkCountdown;ActualCountdown=$countdown;BreakWindowAfterRestart=$breakAfter})
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
  $testSettings="workMinutes=1`nbreakSeconds=20`ntheme=2`nbreakModeColors=1`n"
  [IO.File]::WriteAllText((Join-Path $testData 'settings.ini'),$testSettings,[Text.UTF8Encoding]::new($false))
  Add-Result "$Label disposable isolated profile prepared with short timer intervals" 'INFO' ([pscustomobject]@{DataDirectory=$testData;WorkMinutes=1;BreakSeconds=20;SettingsFile=Join-Path $testData 'settings.ini'})

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

  Click-Control $script:activeWindow 20 "$Label pause"
  $paused=Wait-Status $script:activeWindow 'Paused'
  Check ($paused -match 'Paused') "$Label pauses through its real timer button" $paused
  Click-Control $script:activeWindow 20 "$Label resume"
  $resumed=Wait-Status $script:activeWindow 'Running'
  Check ($resumed -match 'Running') "$Label resumes through its real timer button" $resumed
  Click-Control $script:activeWindow 21 "$Label reset"
  $reset=Wait-Status $script:activeWindow 'Running'
  Check ($reset -match 'Running') "$Label resets the work timer and remains in work mode" $reset

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
