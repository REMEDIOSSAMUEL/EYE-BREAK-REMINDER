param(
  [Parameter(Mandatory=$true)][string]$ExecutablePath,
  [Parameter(Mandatory=$true)][string]$ExpectedSha256,
  [string]$EvidenceDirectory='build/windows-display-change-evidence',
  [switch]$ValidateOnly
)
$ErrorActionPreference='Stop'
[void][IO.Directory]::CreateDirectory($EvidenceDirectory)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$native=@"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
[StructLayout(LayoutKind.Sequential)]
public struct EBR_DISPLAY_RECT { public int Left,Top,Right,Bottom; }
[StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]
public struct EBR_DISPLAY_DEVMODE {
 [MarshalAs(UnmanagedType.ByValTStr,SizeConst=32)] public string dmDeviceName;
 public ushort dmSpecVersion,dmDriverVersion,dmSize,dmDriverExtra;
 public uint dmFields;
 public int dmPositionX,dmPositionY;
 public uint dmDisplayOrientation,dmDisplayFixedOutput;
 public short dmColor,dmDuplex,dmYResolution,dmTTOption,dmCollate;
 [MarshalAs(UnmanagedType.ByValTStr,SizeConst=32)] public string dmFormName;
 public ushort dmLogPixels;
 public uint dmBitsPerPel,dmPelsWidth,dmPelsHeight,dmDisplayFlags,dmDisplayFrequency;
 public uint dmICMMethod,dmICMIntent,dmMediaType,dmDitherType,dmReserved1,dmReserved2,dmPanningWidth,dmPanningHeight;
}
public static class EBR_DISPLAY_NATIVE {
 public delegate bool EnumProc(IntPtr hwnd,IntPtr data);
 [DllImport("user32.dll",CharSet=CharSet.Unicode,EntryPoint="EnumDisplaySettingsW",ExactSpelling=true,SetLastError=true)] public static extern bool EnumDisplaySettingsW(string deviceName,int mode,ref EBR_DISPLAY_DEVMODE devMode);
 [DllImport("user32.dll",CharSet=CharSet.Unicode,EntryPoint="ChangeDisplaySettingsExW",ExactSpelling=true,SetLastError=true)] public static extern int ChangeDisplaySettingsExW(string deviceName,ref EBR_DISPLAY_DEVMODE devMode,IntPtr hwnd,uint flags,IntPtr lParam);
 [DllImport("user32.dll",SetLastError=true)] private static extern bool EnumWindows(EnumProc callback,IntPtr data);
 [DllImport("user32.dll",CharSet=CharSet.Unicode,EntryPoint="EnumChildWindows",ExactSpelling=true,SetLastError=true)] private static extern bool EnumChildWindows(IntPtr parent,EnumProc callback,IntPtr data);
 [DllImport("user32.dll",CharSet=CharSet.Unicode,EntryPoint="GetClassNameW",ExactSpelling=true,SetLastError=true)] private static extern int GetClassNameW(IntPtr hwnd,StringBuilder text,int max);
 [DllImport("user32.dll",CharSet=CharSet.Unicode,EntryPoint="GetWindowTextW",ExactSpelling=true,SetLastError=true)] private static extern int GetWindowTextW(IntPtr hwnd,StringBuilder text,int max);
 [DllImport("user32.dll",SetLastError=true)] private static extern bool GetWindowRect(IntPtr hwnd,out EBR_DISPLAY_RECT rect);
 [DllImport("user32.dll",SetLastError=true)] private static extern uint GetWindowThreadProcessId(IntPtr hwnd,out uint processId);
 [DllImport("user32.dll",SetLastError=true)] private static extern bool IsWindowVisible(IntPtr hwnd);
 [DllImport("user32.dll",SetLastError=true)] private static extern IntPtr GetDlgItem(IntPtr hwnd,int id);
 [DllImport("user32.dll",SetLastError=true)] private static extern int GetDlgCtrlID(IntPtr hwnd);
 [DllImport("user32.dll",SetLastError=true)] private static extern IntPtr SendMessageW(IntPtr hwnd,uint message,IntPtr wParam,IntPtr lParam);
 [DllImport("user32.dll",SetLastError=true)] private static extern IntPtr SendMessageTimeoutW(IntPtr hwnd,uint message,IntPtr wParam,IntPtr lParam,uint flags,uint timeout,out IntPtr result);
 [DllImport("user32.dll",SetLastError=true)] public static extern bool SetForegroundWindow(IntPtr hwnd);
 public static EBR_DISPLAY_DEVMODE NewMode(){EBR_DISPLAY_DEVMODE d=new EBR_DISPLAY_DEVMODE();d.dmDeviceName=new string('\0',32);d.dmFormName=new string('\0',32);d.dmSize=(ushort)Marshal.SizeOf(typeof(EBR_DISPLAY_DEVMODE));return d;}
 public static string ClassName(IntPtr hwnd){StringBuilder b=new StringBuilder(256);GetClassNameW(hwnd,b,b.Capacity);return b.ToString();}
 public static string Text(IntPtr hwnd){if(hwnd==IntPtr.Zero)return "";StringBuilder b=new StringBuilder(512);GetWindowTextW(hwnd,b,b.Capacity);return b.ToString();}
 public static EBR_DISPLAY_RECT Bounds(IntPtr hwnd){EBR_DISPLAY_RECT r=new EBR_DISPLAY_RECT();if(hwnd!=IntPtr.Zero)GetWindowRect(hwnd,out r);return r;}
 public static bool Visible(IntPtr hwnd){return hwnd!=IntPtr.Zero&&IsWindowVisible(hwnd);}
 public static IntPtr Child(IntPtr hwnd,int id){return hwnd==IntPtr.Zero?IntPtr.Zero:GetDlgItem(hwnd,id);}
 public static int ControlId(IntPtr hwnd){return hwnd==IntPtr.Zero?-1:GetDlgCtrlID(hwnd);}
 public static IntPtr FindChildByText(IntPtr parent,string expected){IntPtr found=IntPtr.Zero;EnumProc cb=delegate(IntPtr h,IntPtr ignored){if(String.Equals(ClassName(h),"Button",StringComparison.OrdinalIgnoreCase)&&String.Equals(Text(h),expected,StringComparison.OrdinalIgnoreCase)){found=h;return false;}return true;};EnumChildWindows(parent,cb,IntPtr.Zero);GC.KeepAlive(cb);return found;}
 public static bool Click(IntPtr hwnd){if(hwnd==IntPtr.Zero)return false;IntPtr result;return SendMessageTimeoutW(hwnd,0x00F5,IntPtr.Zero,IntPtr.Zero,2,2000,out result)!=IntPtr.Zero;}
 public static bool Responsive(IntPtr hwnd){if(hwnd==IntPtr.Zero)return false;IntPtr result;return SendMessageTimeoutW(hwnd,0,IntPtr.Zero,IntPtr.Zero,2,1500,out result)!=IntPtr.Zero;}
 public static IntPtr[] Children(IntPtr root){List<IntPtr> result=new List<IntPtr>();EnumProc cb=delegate(IntPtr h,IntPtr ignored){result.Add(h);return true;};EnumChildWindows(root,cb,IntPtr.Zero);GC.KeepAlive(cb);return result.ToArray();}
 public static IntPtr FindProcessWindow(int pid,string className){IntPtr found=IntPtr.Zero;EnumProc cb=delegate(IntPtr h,IntPtr ignored){uint owner;GetWindowThreadProcessId(h,out owner);if(owner==(uint)pid&&IsWindowVisible(h)&&String.Equals(ClassName(h),className,StringComparison.Ordinal)){found=h;return false;}return true;};EnumWindows(cb,IntPtr.Zero);GC.KeepAlive(cb);return found;}
 public static int CountProcessWindows(int pid,string className){int count=0;EnumProc cb=delegate(IntPtr h,IntPtr ignored){uint owner;GetWindowThreadProcessId(h,out owner);if(owner==(uint)pid&&String.Equals(ClassName(h),className,StringComparison.Ordinal))count++;return true;};EnumWindows(cb,IntPtr.Zero);GC.KeepAlive(cb);return count;}
}
"@
if(-not ('EBR_DISPLAY_NATIVE' -as [type])){Add-Type -TypeDefinition $native -ErrorAction Stop}
if($ValidateOnly){[pscustomobject]@{Status='PASS';PowerShell='Parsed';NativeInterop='Compiled';DisplayChange='Not executed'}|ConvertTo-Json;return}

function Get-DisplaySnapshot {
  $screenRows=@([System.Windows.Forms.Screen]::AllScreens|ForEach-Object{[pscustomobject]@{DeviceName=$_.DeviceName;Primary=$_.Primary;Left=$_.Bounds.Left;Top=$_.Bounds.Top;Width=$_.Bounds.Width;Height=$_.Bounds.Height}})
  $main=[EBR_DISPLAY_NATIVE]::FindProcessWindow($script:app.Id,'EyeBreakReminder.Native')
  $break=[EBR_DISPLAY_NATIVE]::FindProcessWindow($script:app.Id,'EyeBreakReminder.Break')
  $mainRect=[EBR_DISPLAY_NATIVE]::Bounds($main);$breakRect=[EBR_DISPLAY_NATIVE]::Bounds($break)
  $status=if($main-ne[IntPtr]::Zero){[EBR_DISPLAY_NATIVE]::Text([EBR_DISPLAY_NATIVE]::Child($main,41))}else{''}
  $actions=@(foreach($id in 23..27){$control=[EBR_DISPLAY_NATIVE]::Child($break,$id);[pscustomobject]@{Id=$id;Exists=($control-ne[IntPtr]::Zero);Visible=[EBR_DISPLAY_NATIVE]::Visible($control);Text=[EBR_DISPLAY_NATIVE]::Text($control)}})
  [pscustomobject]@{Screens=$screenRows;MonitorCount=$screenRows.Count;MainWindow=[pscustomobject]@{Exists=($main-ne[IntPtr]::Zero);Visible=[EBR_DISPLAY_NATIVE]::Visible($main);Bounds=$mainRect;Responsive=[EBR_DISPLAY_NATIVE]::Responsive($main);Status=$status};BreakWindow=[pscustomobject]@{Exists=($break-ne[IntPtr]::Zero);Visible=[EBR_DISPLAY_NATIVE]::Visible($break);Bounds=$breakRect;Actions=$actions};VirtualScreen=[pscustomobject]@{Left=[System.Windows.Forms.SystemInformation]::VirtualScreen.Left;Top=[System.Windows.Forms.SystemInformation]::VirtualScreen.Top;Width=[System.Windows.Forms.SystemInformation]::VirtualScreen.Width;Height=[System.Windows.Forms.SystemInformation]::VirtualScreen.Height}}
}
function Save-Screenshot([string]$Name) {
  try{$bounds=[System.Windows.Forms.SystemInformation]::VirtualScreen;if($bounds.Width-le0-or$bounds.Height-le0){return $null};$bitmap=[Drawing.Bitmap]::new($bounds.Width,$bounds.Height);$graphics=[Drawing.Graphics]::FromImage($bitmap);try{$graphics.CopyFromScreen($bounds.Left,$bounds.Top,0,0,$bitmap.Size);$path=Join-Path $EvidenceDirectory $Name;$bitmap.Save($path,[Drawing.Imaging.ImageFormat]::Png);return $path}finally{$graphics.Dispose();$bitmap.Dispose()}}catch{return "capture unavailable: $($_.Exception.Message)"}
}
function Get-Mode {
  $mode=[EBR_DISPLAY_NATIVE]::NewMode()
  if([string]::IsNullOrWhiteSpace($script:displayDevice)){throw 'Windows did not expose a primary display device name.'}
  if(-not [EBR_DISPLAY_NATIVE]::EnumDisplaySettingsW($script:displayDevice,-1,[ref]$mode)){$errorCode=[Runtime.InteropServices.Marshal]::GetLastWin32Error();throw "Windows could not report the current mode for $($script:displayDevice) (Win32 error $errorCode)."}
  return $mode
}
function Test-Mode([uint32]$Width,[uint32]$Height) {
  $mode=[EBR_DISPLAY_NATIVE]::NewMode();$mode.dmFields=0x00080000 -bor 0x00100000;$mode.dmPelsWidth=$Width;$mode.dmPelsHeight=$Height
  return [EBR_DISPLAY_NATIVE]::ChangeDisplaySettingsExW($script:displayDevice,[ref]$mode,[IntPtr]::Zero,2,[IntPtr]::Zero)
}
function Format-Mode($Mode){[pscustomobject]@{Width=[uint32]$Mode.dmPelsWidth;Height=[uint32]$Mode.dmPelsHeight;BitsPerPel=[uint32]$Mode.dmBitsPerPel;Frequency=[uint32]$Mode.dmDisplayFrequency}}
function Test-InVirtualScreen($Rect,$VirtualScreen){return ($Rect.Left-ge$VirtualScreen.Left-and$Rect.Top-ge$VirtualScreen.Top-and$Rect.Right-le($VirtualScreen.Left+$VirtualScreen.Width)-and$Rect.Bottom-le($VirtualScreen.Top+$VirtualScreen.Height))}

$script:app=$null;$script:displayDevice=$null;$originalMode=$null;$displayChanged=$false;$result=[ordered]@{Application='Eye Break Reminder';Test='Real Windows display-resolution change while a Break reminder is visible';Status='NOT TESTED';CandidateSHA256=$null;ExpectedSHA256=$ExpectedSha256.ToLowerInvariant();CandidateRunId=$env:CANDIDATE_RUN_ID;CandidateSourceCommit=$env:CANDIDATE_SOURCE_COMMIT;Environment=$null;InitialMode=$null;ChangedMode=$null;RestoredMode=$null;TakeBreakControl=$null;InitialScreenshot=$null;ChangedScreenshot=$null;RestoredScreenshot=$null;BeforeChange=$null;AfterChange=$null;AfterRestore=$null;Reason='';Failure='';CompletedUtc=$null}
try {
  $exe=(Resolve-Path -LiteralPath $ExecutablePath).Path;$hash=(Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant();$result.CandidateSHA256=$hash
  if($hash-cne$ExpectedSha256.ToLowerInvariant()){throw "Candidate executable hash mismatch: expected $ExpectedSha256; found $hash."}
  $primaryScreen=[System.Windows.Forms.Screen]::PrimaryScreen;if($null-eq$primaryScreen){throw 'Windows did not expose a primary screen for display-mode testing.'};$script:displayDevice=$primaryScreen.DeviceName
  $version=(Get-Item -LiteralPath $exe).VersionInfo.ProductVersion;if($version-notmatch'^1\.3\.0(\.0)?$'){throw "Expected application version 1.3.0; found $version."}
  $os=Get-CimInstance Win32_OperatingSystem;$architecture=[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString();$explorerProcess=Get-Process -Name explorer -ErrorAction SilentlyContinue|Select-Object -First 1;$explorer=if($explorerProcess){[EBR_DISPLAY_NATIVE]::FindProcessWindow($explorerProcess.Id,'Shell_TrayWnd')}else{[IntPtr]::Zero}
  $result.Environment=[pscustomobject]@{OS=$os.Caption;OSVersion=$os.Version;OSArchitecture=$architecture;ProcessArchitecture=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString();Interactive=[Environment]::UserInteractive;ExplorerDesktop=($explorer-ne[IntPtr]::Zero);MonitorCount=[System.Windows.Forms.Screen]::AllScreens.Count;PrimaryDisplayDevice=$script:displayDevice;ProductVersion=$version;CandidateRunId=$env:CANDIDATE_RUN_ID;CandidateSourceCommit=$env:CANDIDATE_SOURCE_COMMIT}
  if($os.Caption-notmatch'Windows Server 2025'-or$architecture-ne'X64'){throw "Expected isolated Windows Server 2025 x64, found $($os.Caption) / $architecture."}
  if(-not$result.Environment.ExplorerDesktop){$result.Reason='The hosted runner did not expose an interactive Explorer desktop.';return}
  $running=@(Get-Process -Name EyeBreakReminder -ErrorAction SilentlyContinue);if($running.Count){throw 'An Eye Break Reminder process already exists on the disposable runner.'}
  $originalMode=Get-Mode;$result.InitialMode=Format-Mode $originalMode
  $modes=[Collections.Generic.List[object]]::new()
  for($i=0;$i-lt256;$i++){$mode=[EBR_DISPLAY_NATIVE]::NewMode();if(-not[EBR_DISPLAY_NATIVE]::EnumDisplaySettingsW($script:displayDevice,$i,[ref]$mode)){break};$modes.Add((Format-Mode $mode))}
  $alternatives=@($modes|Where-Object{($_.Width-ne$result.InitialMode.Width-or$_.Height-ne$result.InitialMode.Height)-and$_.Width-ge1024-and$_.Height-ge600}|Sort-Object @{Expression={if($_.Height-ge$result.InitialMode.Height){0}else{1}}},@{Expression={if($_.Height-ge$result.InitialMode.Height){[math]::Abs(($_.Width*$_.Height)-($result.InitialMode.Width*$result.InitialMode.Height))}else{-[double]($_.Width*$_.Height)}}})
  $selected=$null;foreach($mode in $alternatives){if((Test-Mode $mode.Width $mode.Height)-eq0){$selected=$mode;break}}
  if(-not$selected){$result.Reason='The isolated Windows display driver exposed no different supported resolution that passed CDS_TEST; no display setting was changed.';return}
  $script:app=Start-Process -FilePath $exe -PassThru
  $watch=[Diagnostics.Stopwatch]::StartNew();$main=[IntPtr]::Zero
  while($watch.Elapsed.TotalSeconds-lt20-and$main-eq[IntPtr]::Zero){$main=[EBR_DISPLAY_NATIVE]::FindProcessWindow($script:app.Id,'EyeBreakReminder.Native');if($main-eq[IntPtr]::Zero){Start-Sleep -Milliseconds 100}}
  if($main-eq[IntPtr]::Zero){throw 'Exact-candidate standalone executable did not expose its main native window.'}
  if(-not[EBR_DISPLAY_NATIVE]::Responsive($main)){throw 'The exact-candidate main window did not answer a Win32 responsiveness probe.'}
  $result.InitialScreenshot=Save-Screenshot 'display-change-before.png';if($result.InitialScreenshot-notmatch'\.png$'){$result.Reason="Could not capture the hosted desktop before display reconfiguration: $($result.InitialScreenshot)";return};$result.BeforeChange=Get-DisplaySnapshot
  $breakButton=[EBR_DISPLAY_NATIVE]::Child($main,22);$buttonLookup='GetDlgItem control ID 22'
  if($breakButton-eq[IntPtr]::Zero){$buttonMatches=@([EBR_DISPLAY_NATIVE]::Children($main)|Where-Object{$owner=[uint32]0;[void][EBR_DISPLAY_NATIVE]::GetWindowThreadProcessId($_,[ref]$owner);$owner-eq$script:app.Id-and[EBR_DISPLAY_NATIVE]::Visible($_)-and[EBR_DISPLAY_NATIVE]::ControlId($_)-eq22-and[EBR_DISPLAY_NATIVE]::ClassName($_)-eq'Button'});if($buttonMatches.Count-eq1){$breakButton=$buttonMatches[0];$buttonLookup='EnumChildWindows process/visible/control ID 22'}else{$breakButton=[EBR_DISPLAY_NATIVE]::FindChildByText($main,'Take a break now');$buttonLookup='visible button caption fallback'}}
  if($breakButton-eq[IntPtr]::Zero){$children=@([EBR_DISPLAY_NATIVE]::Children($main)|ForEach-Object{$owner=[uint32]0;[void][EBR_DISPLAY_NATIVE]::GetWindowThreadProcessId($_,[ref]$owner);[pscustomobject]@{ProcessId=$owner;ControlId=[EBR_DISPLAY_NATIVE]::ControlId($_);Class=[EBR_DISPLAY_NATIVE]::ClassName($_);Visible=[EBR_DISPLAY_NATIVE]::Visible($_);Caption=[EBR_DISPLAY_NATIVE]::Text($_)}});throw "The visible Take a break now button was not found by ID or caption. Main-window child controls: $($children|ConvertTo-Json -Compress -Depth 4)"}
  $result.TakeBreakControl=[pscustomobject]@{Lookup=$buttonLookup;ControlId=[EBR_DISPLAY_NATIVE]::ControlId($breakButton);Caption=[EBR_DISPLAY_NATIVE]::Text($breakButton);Visible=[EBR_DISPLAY_NATIVE]::Visible($breakButton);Bounds=[EBR_DISPLAY_NATIVE]::Bounds($breakButton)}
  if(-not$result.TakeBreakControl.Visible){throw 'The Take a break now control was not visible before it was activated.'}
  [void][EBR_DISPLAY_NATIVE]::SetForegroundWindow($main);Start-Sleep -Milliseconds 200
  if(-not[EBR_DISPLAY_NATIVE]::Click($breakButton)){throw "Could not activate the real Take a Break button via $buttonLookup."}
  $watch.Restart();$break=[IntPtr]::Zero
  while($watch.Elapsed.TotalSeconds-lt15-and$break-eq[IntPtr]::Zero){$break=[EBR_DISPLAY_NATIVE]::FindProcessWindow($script:app.Id,'EyeBreakReminder.Break');if($break-eq[IntPtr]::Zero){Start-Sleep -Milliseconds 100}}
  if($break-eq[IntPtr]::Zero){throw 'A real Break reminder did not appear before the display change.'}
  $result.BeforeChange=Get-DisplaySnapshot
  if(-not$result.BeforeChange.BreakWindow.Visible){throw 'Break reminder was not visible before the display change.'}
  if($result.BeforeChange.BreakWindow.Actions.Count-ne5-or@($result.BeforeChange.BreakWindow.Actions|Where-Object{-not$_.Visible}).Count-gt0){throw 'The visible Break reminder did not expose all five visible action controls before the display change.'}
  $changedMode=[EBR_DISPLAY_NATIVE]::NewMode();$changedMode.dmFields=0x00080000 -bor 0x00100000;$changedMode.dmPelsWidth=$selected.Width;$changedMode.dmPelsHeight=$selected.Height
  $changeResult=[EBR_DISPLAY_NATIVE]::ChangeDisplaySettingsExW($script:displayDevice,[ref]$changedMode,[IntPtr]::Zero,0,[IntPtr]::Zero)
  if($changeResult-ne0){$result.Reason="Windows rejected the supported display mode with DISP_CHANGE code $changeResult; the candidate UI was left unchanged.";return}
  $displayChanged=$true;$result.ChangedMode=[pscustomobject]@{Width=$selected.Width;Height=$selected.Height;BitsPerPel=$selected.BitsPerPel;Frequency=$selected.Frequency;DispChangeCode=$changeResult}
  Start-Sleep -Seconds 2
  $result.AfterChange=Get-DisplaySnapshot;$result.ChangedScreenshot=Save-Screenshot 'display-change-reminder-visible.png';if($result.ChangedScreenshot-notmatch'\.png$'){$result.Reason="Could not capture the hosted desktop after display reconfiguration: $($result.ChangedScreenshot)";return}
  $main=[EBR_DISPLAY_NATIVE]::FindProcessWindow($script:app.Id,'EyeBreakReminder.Native');$break=[EBR_DISPLAY_NATIVE]::FindProcessWindow($script:app.Id,'EyeBreakReminder.Break');$virtual=$result.AfterChange.VirtualScreen
  if($result.AfterChange.MonitorCount-ne$result.BeforeChange.MonitorCount){throw "Unexpected monitor count change: $($result.BeforeChange.MonitorCount) to $($result.AfterChange.MonitorCount)."}
  if(-not[EBR_DISPLAY_NATIVE]::Responsive($main)){throw 'The exact-candidate main window stopped responding after the genuine display-mode change.'}
  if(-not[EBR_DISPLAY_NATIVE]::Visible($break)-or[EBR_DISPLAY_NATIVE]::CountProcessWindows($script:app.Id,'EyeBreakReminder.Break')-ne1){throw 'The reminder closed, hid, or duplicated after the genuine display-mode change.'}
  if(-not(Test-InVirtualScreen $result.AfterChange.BreakWindow.Bounds $virtual)){throw 'The visible reminder moved outside the usable virtual screen after the display-mode change.'}
  [void][EBR_DISPLAY_NATIVE]::SetForegroundWindow($main);Start-Sleep -Milliseconds 200;[void][EBR_DISPLAY_NATIVE]::SetForegroundWindow($break);Start-Sleep -Milliseconds 200
  if(-not[EBR_DISPLAY_NATIVE]::Responsive($main)-or-not[EBR_DISPLAY_NATIVE]::Responsive($break)){throw 'The main or reminder window did not remain responsive after focus was moved across them.'}
  $ack=[EBR_DISPLAY_NATIVE]::Child($break,23);if(-not[EBR_DISPLAY_NATIVE]::Visible($ack)){throw 'The reminder acknowledgement control was not visible after the display-mode change.'}
  if(-not[EBR_DISPLAY_NATIVE]::Click($ack)){throw 'The reminder acknowledgement control did not respond after the display-mode change.'}
  $watch.Restart();do{$break=[EBR_DISPLAY_NATIVE]::FindProcessWindow($script:app.Id,'EyeBreakReminder.Break');if($break-eq[IntPtr]::Zero){break};Start-Sleep -Milliseconds 100}while($watch.Elapsed.TotalSeconds-lt10)
  if($break-ne[IntPtr]::Zero){throw 'The reminder did not close after acknowledging it following the display-mode change.'}
  if([EBR_DISPLAY_NATIVE]::CountProcessWindows($script:app.Id,'EyeBreakReminder.Break')-ne0){throw 'A duplicate reminder window remained after acknowledgement.'}
  $result.Status='PASS';$result.Reason='Windows applied a different enumerated display resolution; the exact sealed candidate kept one visible and responsive reminder in the changed display bounds, preserved focus/input, and returned to Work without a duplicate window.'
  $result.MultiMonitorStatus=if($result.AfterChange.MonitorCount-gt1){'NOT TESTED: this probe did not move the app between displays or change topology.'}else{'BLOCKED: only one display was exposed by the isolated runner.'}
}catch{$result.Status='FAIL';$result.Failure=$_.Exception.Message}
finally {
  if($displayChanged-and$null-ne$originalMode){try{$restore=[EBR_DISPLAY_NATIVE]::ChangeDisplaySettingsExW($script:displayDevice,[ref]$originalMode,[IntPtr]::Zero,0,[IntPtr]::Zero);if($restore-ne0){$result.Status='FAIL';$result.Failure="Could not restore original display mode; DISP_CHANGE code $restore. $($result.Failure)"}else{Start-Sleep -Milliseconds 500;$result.RestoredMode=Format-Mode (Get-Mode);$result.RestoredScreenshot=Save-Screenshot 'display-change-restored.png';if($result.RestoredMode.Width-ne$result.InitialMode.Width-or$result.RestoredMode.Height-ne$result.InitialMode.Height){$result.Status='FAIL';$result.Failure='Windows reported a different resolution after restoring the original display mode.'}}}catch{$result.Status='FAIL';$result.Failure="Could not verify display-mode restoration: $($_.Exception.Message)"}}
  if($script:app){try{if(-not$script:app.HasExited){Stop-Process -Id $script:app.Id -Force -ErrorAction Stop};$script:app.WaitForExit(5000)}catch{if($result.Status-ne'FAIL'){$result.Status='FAIL'};$result.Failure="Could not stop the owned candidate test process: $($_.Exception.Message) $($result.Failure)"}}
  $result.CompletedUtc=[DateTime]::UtcNow.ToString('o');$result|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'windows-display-change-results.json') -Encoding UTF8
}
$result|ConvertTo-Json -Depth 10
if($result.Status-eq'FAIL'){exit 1}
