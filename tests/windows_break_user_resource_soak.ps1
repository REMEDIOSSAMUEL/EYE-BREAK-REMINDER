param(
  [Parameter(Mandatory=$true)][string]$ExecutablePath,
  [string]$EvidenceDirectory='build/hotfix-user-object-evidence/soak',
  [ValidateRange(10,200)][int]$Cycles=120,
  [ValidateSet('1.2.0','1.2.1')][string]$ExpectedProductVersion='1.2.1',
  [ValidateSet('Growth','NoGrowth')][string]$ExpectedResourceBehavior='NoGrowth'
)
$ErrorActionPreference='Stop'
[void][IO.Directory]::CreateDirectory($EvidenceDirectory)
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
$native=@"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public struct EBR_SOAK_RECT { public int Left,Top,Right,Bottom; }
public static class EBR_SOAK_NATIVE {
 public delegate bool EnumProc(IntPtr hwnd,IntPtr data);
 [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc callback,IntPtr data);
 [DllImport("user32.dll",SetLastError=true)] private static extern bool EnumChildWindows(IntPtr parent,EnumProc callback,IntPtr data);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowW(string cls,string title);
 [DllImport("user32.dll",SetLastError=true)] public static extern uint GetWindowThreadProcessId(IntPtr hwnd,out uint pid);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] private static extern int GetClassNameW(IntPtr hwnd,StringBuilder text,int max);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] private static extern int GetWindowTextW(IntPtr hwnd,StringBuilder text,int max);
 [DllImport("user32.dll",SetLastError=true)] public static extern int GetDlgCtrlID(IntPtr hwnd);
 [DllImport("user32.dll",SetLastError=true)] public static extern IntPtr GetParent(IntPtr hwnd);
 [DllImport("user32.dll",SetLastError=true)] public static extern IntPtr SendMessageW(IntPtr hwnd,uint msg,IntPtr wp,IntPtr lp);
 [DllImport("user32.dll",SetLastError=true)] public static extern IntPtr SendMessageTimeoutW(IntPtr hwnd,uint msg,IntPtr wp,IntPtr lp,uint flags,uint timeout,out IntPtr result);
 [DllImport("user32.dll",SetLastError=true)] public static extern bool IsWindow(IntPtr hwnd);
 [DllImport("user32.dll",SetLastError=true)] public static extern bool IsWindowVisible(IntPtr hwnd);
 [DllImport("user32.dll",SetLastError=true)] public static extern bool SetForegroundWindow(IntPtr hwnd);
 [DllImport("user32.dll",SetLastError=true)] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll",SetLastError=true)] public static extern bool GetWindowRect(IntPtr hwnd,out EBR_SOAK_RECT rect);
 [DllImport("user32.dll",SetLastError=true)] public static extern int GetGuiResources(IntPtr process,uint flags);
 public static string ClassName(IntPtr hwnd){StringBuilder b=new StringBuilder(256);GetClassNameW(hwnd,b,b.Capacity);return b.ToString();}
 public static string Text(IntPtr hwnd){StringBuilder b=new StringBuilder(512);GetWindowTextW(hwnd,b,b.Capacity);return b.ToString();}
 public static IntPtr FindWindow(int pid,string cls){IntPtr found=IntPtr.Zero;EnumProc cb=delegate(IntPtr h,IntPtr ignored){uint owner;GetWindowThreadProcessId(h,out owner);if(owner==(uint)pid&&IsWindowVisible(h)&&String.Equals(ClassName(h),cls,StringComparison.Ordinal)){found=h;return false;}return true;};EnumWindows(cb,IntPtr.Zero);GC.KeepAlive(cb);return found;}
 public static int CountWindows(int pid,string cls){int n=0;EnumProc cb=delegate(IntPtr h,IntPtr ignored){uint owner;GetWindowThreadProcessId(h,out owner);if(owner==(uint)pid&&(String.IsNullOrEmpty(cls)||String.Equals(ClassName(h),cls,StringComparison.Ordinal)))n++;return true;};EnumWindows(cb,IntPtr.Zero);GC.KeepAlive(cb);return n;}
 public static IntPtr ChildById(IntPtr root,int id){IntPtr found=IntPtr.Zero;EnumProc cb=delegate(IntPtr h,IntPtr ignored){if(GetDlgCtrlID(h)==id){found=h;return false;}return true;};EnumChildWindows(root,cb,IntPtr.Zero);GC.KeepAlive(cb);return found;}
 public static int User(IntPtr p){return GetGuiResources(p,1);}
 public static int Gdi(IntPtr p){return GetGuiResources(p,0);}
 public static bool Click(IntPtr h){if(h==IntPtr.Zero)return false;IntPtr r;return SendMessageTimeoutW(h,0x00F5,IntPtr.Zero,IntPtr.Zero,2,5000,out r)!=IntPtr.Zero;}
}
"@
if(-not ('EBR_SOAK_NATIVE' -as [type])){Add-Type -TypeDefinition $native -ErrorAction Stop}
$script:events=[Collections.Generic.List[object]]::new()
$script:metrics=[Collections.Generic.List[object]]::new()
$script:cycleRecords=[Collections.Generic.List[object]]::new()
$script:screenshots=[Collections.Generic.List[string]]::new()
$script:process=$null;$script:main=[IntPtr]::Zero;$script:ownedData=$false;$script:dataPath=$null
$script:started=[Diagnostics.Stopwatch]::StartNew();$script:startUtc=[DateTime]::UtcNow
function Add-Event([string]$Name,[string]$Status,$Details=$null){$script:events.Add([pscustomobject]@{Name=$Name;Status=$Status;Details=$Details;Utc=[DateTime]::UtcNow.ToString('o')})}
function Check([bool]$ok,[string]$Name,$Details=$null){if($ok){Add-Event $Name 'PASS' $Details}else{Add-Event $Name 'FAIL' $Details}}
function Status(){ $h=[EBR_SOAK_NATIVE]::ChildById($script:main,41);if($h -eq [IntPtr]::Zero){return ''};return [EBR_SOAK_NATIVE]::Text($h) }
function CountdownText(){ $h=[EBR_SOAK_NATIVE]::ChildById($script:main,40);if($h -eq [IntPtr]::Zero){return ''};return [EBR_SOAK_NATIVE]::Text($h).Trim() }
function CountdownSeconds(){ $m=[regex]::Match((CountdownText),'^(\d+):(\d{2})$');if(-not $m.Success){return -1};return ([int]$m.Groups[1].Value*60)+[int]$m.Groups[2].Value }
function BreakWindow(){[EBR_SOAK_NATIVE]::FindWindow($script:process.Id,'EyeBreakReminder.Break')}
function Sample([int]$Cycle,[string]$Stage){
 $script:process.Refresh();if($script:process.HasExited){throw 'Application exited during soak.'}
 $proc=$script:process
 $row=[pscustomobject]@{
  Utc=[DateTime]::UtcNow.ToString('o');ElapsedSeconds=[math]::Round($script:started.Elapsed.TotalSeconds,1);Cycle=$Cycle;Stage=$Stage;ProcessId=$proc.Id
  UserObjects=[EBR_SOAK_NATIVE]::User($proc.Handle);GdiObjects=[EBR_SOAK_NATIVE]::Gdi($proc.Handle);HandleCount=$proc.HandleCount
  WorkingSetBytes=$proc.WorkingSet64;PrivateBytes=$proc.PrivateMemorySize64;CpuTotalMilliseconds=$proc.TotalProcessorTime.TotalMilliseconds
  TopLevelWindows=[EBR_SOAK_NATIVE]::CountWindows($proc.Id,$null);BreakWindowCount=[EBR_SOAK_NATIVE]::CountWindows($proc.Id,'EyeBreakReminder.Break')
  TimerStatus=(Status);TimerCountdown=(CountdownText);NotificationSetting='disabled in isolated soak fixture'
 }
 $script:metrics.Add($row);return $row
}
function Wait-Until([scriptblock]$Condition,[int]$Timeout,[string]$Stage,[int]$Cycle){
 $watch=[Diagnostics.Stopwatch]::StartNew();$nextSample=0
 while($watch.Elapsed.TotalSeconds -lt $Timeout){
  if(& $Condition){return $true}
  if($watch.Elapsed.TotalSeconds -ge $nextSample){[void](Sample $Cycle $Stage);$nextSample=$watch.Elapsed.TotalSeconds+5}
  Start-Sleep -Milliseconds 200
 }
 return $false
}
function Wait-Break([int]$Timeout,[int]$Cycle){
 $script:observedBreak=[IntPtr]::Zero
 if(-not (Wait-Until {$script:observedBreak=BreakWindow;($script:observedBreak) -ne [IntPtr]::Zero} $Timeout 'waiting-for-break' $Cycle)){throw "Cycle $Cycle did not open a break window within $Timeout seconds."}
 return $script:observedBreak
}
function Wait-Closed([IntPtr]$Window,[int]$Timeout,[int]$Cycle,[string]$Action){
 if(-not (Wait-Until {(-not [EBR_SOAK_NATIVE]::IsWindow($Window)) -and (BreakWindow -eq [IntPtr]::Zero) -and (Status) -match 'Running'} $Timeout "closing-$Action" $Cycle)){throw "Cycle $Cycle did not return to work after $Action; status=$(Status)."}
}
function Capture([IntPtr]$Window,[string]$Name){
 if([EBR_SOAK_NATIVE]::GetForegroundWindow() -ne $Window){return}
 $r=New-Object EBR_SOAK_RECT;if(-not [EBR_SOAK_NATIVE]::GetWindowRect($Window,[ref]$r)){return}
 $w=$r.Right-$r.Left;$h=$r.Bottom-$r.Top;if($w -lt 100 -or $h -lt 100){return}
 $bmp=[Drawing.Bitmap]::new($w,$h);$g=[Drawing.Graphics]::FromImage($bmp)
 try{$g.CopyFromScreen($r.Left,$r.Top,0,0,$bmp.Size);$file=Join-Path $EvidenceDirectory $Name;$bmp.Save($file,[Drawing.Imaging.ImageFormat]::Png);$script:screenshots.Add($file)}finally{$g.Dispose();$bmp.Dispose()}
}
function Set-Theme([int]$Theme,[int]$Cycle){
 if(-not [EBR_SOAK_NATIVE]::Click([EBR_SOAK_NATIVE]::ChildById($script:main,12))){throw 'Settings navigation did not respond.'}
 if(-not [EBR_SOAK_NATIVE]::Click([EBR_SOAK_NATIVE]::ChildById($script:main,134))){throw 'Appearance section did not respond.'}
 $combo=[EBR_SOAK_NATIVE]::ChildById($script:main,106);if($combo -eq [IntPtr]::Zero){throw 'Theme selector was not found.'}
 [void][EBR_SOAK_NATIVE]::SendMessageW($combo,0x014E,[IntPtr]$Theme,[IntPtr]::Zero)
 [void][EBR_SOAK_NATIVE]::SendMessageW([EBR_SOAK_NATIVE]::GetParent($combo),0x0111,[IntPtr]((1 -shl 16)-bor 106),$combo)
 $saved=Get-Content -LiteralPath (Join-Path $script:dataPath 'settings.ini') -Raw
 Check ($saved -match ("(?m)^theme=$Theme$")) "Cycle $Cycle persisted theme $Theme"
 if(-not [EBR_SOAK_NATIVE]::Click([EBR_SOAK_NATIVE]::ChildById($script:main,10))){throw 'Timer navigation did not respond after theme change.'}
}
function Act-On-Break([IntPtr]$Window,[string]$Action,[int]$Cycle){
 switch($Action){
  'Skip' {if(-not [EBR_SOAK_NATIVE]::Click([EBR_SOAK_NATIVE]::ChildById($Window,24))){throw "Cycle $Cycle Skip button failed."};Wait-Closed $Window 12 $Cycle 'Skip'}
  'Complete' {if(-not [EBR_SOAK_NATIVE]::Click([EBR_SOAK_NATIVE]::ChildById($Window,23))){throw "Cycle $Cycle I'm back button failed."};Wait-Closed $Window 12 $Cycle "I'm back"}
  'Escape' {[void][EBR_SOAK_NATIVE]::SetForegroundWindow($Window);Start-Sleep -Milliseconds 150;[System.Windows.Forms.SendKeys]::SendWait('{ESC}');Wait-Closed $Window 12 $Cycle 'Escape'}
  'Close' {[void][EBR_SOAK_NATIVE]::SendMessageW($Window,0x0010,[IntPtr]::Zero,[IntPtr]::Zero);Wait-Closed $Window 12 $Cycle 'window close'}
  'Natural' {Wait-Closed $Window 45 $Cycle 'natural completion'}
 }
}
function Snooze-Window([IntPtr]$Window,[int]$Cycle){
 if(-not [EBR_SOAK_NATIVE]::Click([EBR_SOAK_NATIVE]::ChildById($Window,25))){throw "Cycle $Cycle Snooze did not respond."}
 if(-not (Wait-Until {(Status) -match 'Snoozed' -and (BreakWindow) -eq [IntPtr]::Zero} 10 'snoozed-state' $Cycle)){throw "Cycle $Cycle Snoozed status not observed."}
 [void](Sample $Cycle 'snoozed-window-closed')
 return Wait-Break 80 $Cycle
}
function Median([double[]]$Values){$s=@($Values|Sort-Object);if($s.Count%2){return [double]$s[[int][math]::Floor($s.Count/2)]};return ([double]$s[$s.Count/2-1]+[double]$s[$s.Count/2])/2}
function Slope([double[]]$Values){$n=$Values.Count;if($n-lt 2){return 0.0};$sx=$n*($n+1)/2.0;$sy=($Values|Measure-Object -Sum).Sum;$sxx=$n*($n+1)*(2*$n+1)/6.0;$sxy=0.0;for($i=0;$i-lt $n;$i++){$sxy+=($i+1)*$Values[$i]};return ($n*$sxy-$sx*$sy)/($n*$sxx-$sx*$sx)}
function Summary([string]$Name,[string]$Property){$v=[double[]]@($script:cycleRecords|ForEach-Object{[double]$_.$Property});[pscustomobject]@{Resource=$Name;StartMedian=(Median ([double[]]@($v|Select-Object -First 5)));EndMedian=(Median ([double[]]@($v|Select-Object -Last 5)));SlopePerCycle=[math]::Round((Slope $v),5);Minimum=($v|Measure-Object -Minimum).Minimum;Maximum=($v|Measure-Object -Maximum).Maximum}}
$script:result=$null
try{
 if($env:GITHUB_ACTIONS-ne'true' -or $env:RUNNER_ENVIRONMENT-ne'github-hosted' -or $env:RUNNER_OS-ne'Windows'){throw 'Refusing a long soak outside a disposable GitHub-hosted Windows runner.'}
 $exe=(Resolve-Path -LiteralPath $ExecutablePath -ErrorAction Stop).Path;$version=(Get-Item -LiteralPath $exe).VersionInfo;$hash=(Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant()
 if($version.ProductName-ne'Eye Break Reminder' -or $version.ProductVersion-notmatch ('^'+[regex]::Escape($ExpectedProductVersion)+'(\.0)?$')){throw "Expected Eye Break Reminder $ExpectedProductVersion, got $($version.ProductName) $($version.ProductVersion)."}
 if($ExpectedProductVersion-eq'1.2.0' -and $hash-cne'2895c80f942dd03186305d913516700552524ec5ba9a77da0dab457a3265fcc6'){throw "Published v1.2.0 hash mismatch: $hash"}
 if(-not [Environment]::UserInteractive -or [EBR_SOAK_NATIVE]::FindWindowW('Shell_TrayWnd',$null)-eq[IntPtr]::Zero){throw 'Interactive Explorer desktop unavailable; this is not an equivalent soak.'}
 $script:dataPath=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'EyeBreakReminder'
 if(Test-Path -LiteralPath $script:dataPath){throw "Refusing to overwrite existing test profile data: $script:dataPath"}
 if([EBR_SOAK_NATIVE]::FindWindowW('EyeBreakReminder.Native',$null)-ne[IntPtr]::Zero){throw 'Refusing to run alongside an existing application.'}
 [void][IO.Directory]::CreateDirectory($script:dataPath);$script:ownedData=$true
 $settings=@('workMinutes=1','breakSeconds=30','theme=2','breakModeColors=1','alarm=0','notifications=0','repeat=0','snooze=1','autoStart=1','startup=0','tray=1','restore=1','history=1','trayExplained=1')-join"`n"
 if($settings.Contains("`r")){throw 'Test settings fixture must use LF-only newlines because the production settings reader parses raw bytes.'}
 [IO.File]::WriteAllText((Join-Path $script:dataPath 'settings.ini'),$settings,[Text.UTF8Encoding]::new($false))
 $script:process=Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe) -PassThru
 if(-not (Wait-Until {$script:main=[EBR_SOAK_NATIVE]::FindWindow($script:process.Id,'EyeBreakReminder.Native');$script:main-ne[IntPtr]::Zero} 30 'initial-main-window' 0)){throw 'Application main window did not appear.'}
 if(-not (Wait-Until {(Status)-match'Running'} 10 'initial-running' 0)){throw "Timer did not start; status=$(Status)."}
 for($n=0;$n-lt 12;$n++){Start-Sleep -Seconds 1;[void](Sample 0 'idle-baseline')}
 $warm=@($script:metrics|Where-Object{$_.Stage -eq 'idle-baseline'}|ForEach-Object{[double]$_.UserObjects});$idleRange=[double](($warm|Measure-Object -Maximum).Maximum)-[double](($warm|Measure-Object -Minimum).Minimum)
 Add-Event 'Idle resource baseline captured' 'INFO' ([pscustomobject]@{Samples=$warm.Count;UserMinimum=($warm|Measure-Object -Minimum).Minimum;UserMaximum=($warm|Measure-Object -Maximum).Maximum;UserRange=$idleRange})
 $workControl=[EBR_SOAK_NATIVE]::ChildById($script:main,100);$breakControl=[EBR_SOAK_NATIVE]::ChildById($script:main,101);$workSetting=[EBR_SOAK_NATIVE]::Text($workControl).Trim();$breakSetting=[EBR_SOAK_NATIVE]::Text($breakControl).Trim()
 Check ($workSetting -eq '1' -and $breakSetting -eq '30') 'Isolated UI loaded the requested one-minute work and 30-second break settings' ([pscustomobject]@{WorkMinutes=$workSetting;BreakSeconds=$breakSetting;SettingsSHA256=(Get-FileHash -LiteralPath (Join-Path $script:dataPath 'settings.ini') -Algorithm SHA256).Hash})
 if($workSetting -ne '1' -or $breakSetting -ne '30'){throw "Test profile settings were not loaded through the application UI; work=$workSetting break=$breakSetting."}
 if(-not [EBR_SOAK_NATIVE]::Click([EBR_SOAK_NATIVE]::ChildById($script:main,21))){throw 'Timer reset button did not respond before the scheduled soak.'}
 $timerFile=Join-Path $script:dataPath 'timer.dat';$savedTimer=(Get-Content -LiteralPath $timerFile -Raw).Trim()-split'\s+'
 if($savedTimer.Count-ne 6 -or [math]::Abs([double]::Parse($savedTimer[3],[System.Globalization.CultureInfo]::InvariantCulture)-60.0)-gt 0.01){throw "Reset did not persist a 60-second work interval to timer.dat: $($savedTimer -join ' ')."}
 $countdownStart=CountdownSeconds
 if($countdownStart -lt 55 -or $countdownStart -gt 60){throw "Reset timer countdown should be near one minute; UI shows '$(CountdownText)' and saved duration $($savedTimer[3]) seconds."}
 if(-not (Wait-Until {(CountdownSeconds) -lt $countdownStart} 8 'real-countdown-decreasing' 0)){throw "The real application countdown did not decrease from $countdownStart seconds; UI shows '$(CountdownText)'."}
 Add-Event 'Real application countdown decreased after reset' 'PASS' ([pscustomobject]@{StartSeconds=$countdownStart;ObservedSeconds=(CountdownSeconds);SavedDurationSeconds=$savedTimer[3];Mode='Unaccelerated production executable'})
 for($i=1;$i-le$Cycles;$i++){
  $before=Sample $i 'before-break-window'
  $window=Wait-Break 105 $i
  $opened=[EBR_SOAK_NATIVE]::CountWindows($script:process.Id,'EyeBreakReminder.Break')
  if($opened-ne 1){throw "Cycle $i expected one break window; got $opened."}
  $open=Sample $i 'break-window-open'
  if($i-eq 1 -or $i-eq [math]::Ceiling($Cycles/2) -or $i-eq $Cycles){Capture $window ("break-window-cycle-{0:D4}.png"-f$i)}
  if($i%30-eq 0){
   $window=Snooze-Window $window $i
   $window=Snooze-Window $window $i
   Act-On-Break $window 'Skip' $i
   $action='Snooze twice then Skip';$windowCount=3
  }else{
   switch($i%5){1{$action='Skip'} 2{$action='Complete'} 3{$action='Escape'} 4{$action='Close'} 0{$action='Natural'}}
   Act-On-Break $window $action $i;$windowCount=1
  }
  Start-Sleep -Milliseconds 300;$after=Sample $i 'after-break-closed'
  $row=[pscustomobject]@{Cycle=$i;Action=$action;BreakWindowsOpened=$windowCount;UserBefore=$before.UserObjects;UserDuring=$open.UserObjects;UserAfter=$after.UserObjects;GdiBefore=$before.GdiObjects;GdiDuring=$open.GdiObjects;GdiAfter=$after.GdiObjects;HandlesBefore=$before.HandleCount;HandlesAfter=$after.HandleCount;PrivateBytesAfter=$after.PrivateBytes;WorkingSetAfter=$after.WorkingSetBytes;CpuMsAfter=$after.CpuTotalMilliseconds;WindowsAfter=$after.TopLevelWindows;BreakWindowsAfter=$after.BreakWindowCount;StatusAfter=$after.TimerStatus;ElapsedSeconds=$after.ElapsedSeconds}
  $script:cycleRecords.Add($row);Check ($after.BreakWindowCount-eq 0 -and $after.TimerStatus-match'Running') "Cycle $i reminder window closed and work resumed" $row
  if($i%20-eq 0){Set-Theme (($i/20)%5) $i}
  if($i%25-eq 0){
   $pause=[EBR_SOAK_NATIVE]::ChildById($script:main,20)
   if(-not [EBR_SOAK_NATIVE]::Click($pause)){throw "Cycle $i Pause did not respond."}
   if(-not (Wait-Until {(Status)-match'Paused'} 5 'pause-state' $i)){throw "Cycle $i pause state not observed."}
   if(-not [EBR_SOAK_NATIVE]::Click($pause)){throw "Cycle $i Resume did not respond."}
   if(-not (Wait-Until {(Status)-match'Running'} 5 'resume-state' $i)){throw "Cycle $i resume state not observed."}
   Check $true "Cycle $i pause and resume preserved timer operation"
  }
  if($i%10-eq 0){Write-Output ("{0}/{1} scheduled cycles; USER={2}; GDI={3}; handles={4}; elapsed={5}"-f$i,$Cycles,$after.UserObjects,$after.GdiObjects,$after.HandleCount,$script:started.Elapsed.ToString('hh\:mm\:ss'))}
 }
 $user=Summary 'USER objects' 'UserAfter';$gdi=Summary 'GDI objects' 'GdiAfter';$handles=Summary 'process handles' 'HandlesAfter';$private=Summary 'private bytes' 'PrivateBytesAfter';$working=Summary 'working set bytes' 'WorkingSetAfter'
 $drift=$user.EndMedian-$user.StartMedian
 if($ExpectedResourceBehavior-eq'Growth'){$minimum=[math]::Max(4,[math]::Floor($Cycles*0.5));Check ($user.SlopePerCycle-ge 0.5 -and $drift-ge$minimum) 'Published v1.2.0 reproduces sustained USER-object growth' ([pscustomobject]@{SlopePerCycle=$user.SlopePerCycle;StartMedian=$user.StartMedian;EndMedian=$user.EndMedian;Drift=$drift;MinimumExpectedDrift=$minimum;Basis='Half the observed approximately +2 USER objects per break window.'})}
 else{$limit=$idleRange+1;Check ($user.SlopePerCycle-le($limit/[math]::Max(1,$Cycles)) -and $drift-le$limit) 'Candidate USER-object trend remains within measured idle noise' ([pscustomobject]@{SlopePerCycle=$user.SlopePerCycle;StartMedian=$user.StartMedian;EndMedian=$user.EndMedian;Drift=$drift;IdleRange=$idleRange;AllowedDrift=$limit;Basis='Idle range plus one USER object; sustained positive trend is rejected.'})}
 Check (@($script:cycleRecords|Where-Object{$_.BreakWindowsAfter -ne 0}).Count-eq 0) 'All scheduled break windows were destroyed'
 Add-Event 'Other process-resource trend summary' 'INFO' @($gdi,$handles,$private,$working)
 # Deliberately terminate only the owned test app during a break and verify its documented fresh-work restart behavior.
 if(-not [EBR_SOAK_NATIVE]::Click([EBR_SOAK_NATIVE]::ChildById($script:main,22))){throw 'Active-break restart probe could not start a manual break.'}
 $restartWindow=Wait-Break 12 ($Cycles+1);$settingsHashBeforeRestart=(Get-FileHash -LiteralPath (Join-Path $script:dataPath 'settings.ini') -Algorithm SHA256).Hash;$oldPid=$script:process.Id;$script:process.Kill();if(-not $script:process.WaitForExit(10000)){throw 'Test application failed to exit for restart probe.'}
 $script:process.Dispose();$script:process=Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe) -PassThru;$script:main=[IntPtr]::Zero
 $opened=Wait-Until {$script:main=[EBR_SOAK_NATIVE]::FindWindow($script:process.Id,'EyeBreakReminder.Native');$script:main-ne[IntPtr]::Zero} 30 'restart-main-window' ($Cycles+1)
 $restored=$opened -and (Wait-Until {(Status)-match'Running' -and (BreakWindow)-eq[IntPtr]::Zero} 10 'restart-fresh-work' ($Cycles+1))
 $settingsPreserved=(Get-FileHash -LiteralPath (Join-Path $script:dataPath 'settings.ini') -Algorithm SHA256).Hash -ceq $settingsHashBeforeRestart
 Check ($restored -and $settingsPreserved) 'Restart during an active break restores work state and preserves settings without replaying a break' ([pscustomobject]@{OldPid=$oldPid;NewPid=$script:process.Id;Status=if($script:main-ne[IntPtr]::Zero){Status}else{''};BreakWindowCount=[EBR_SOAK_NATIVE]::CountWindows($script:process.Id,'EyeBreakReminder.Break');SettingsPreserved=$settingsPreserved;SettingsSHA256=$settingsHashBeforeRestart})
 $script:result=[pscustomobject]@{Application='Eye Break Reminder';Test='Comparative scheduled break-window soak';Version=$ExpectedProductVersion;SHA256=$hash;ExpectedBehavior=$ExpectedResourceBehavior;Mode='Scheduled real timer';RequestedCycles=$Cycles;CompletedCycles=$script:cycleRecords.Count;BreakWindowsCreated=($script:cycleRecords|Measure-Object BreakWindowsOpened -Sum).Sum;DurationSeconds=[math]::Round($script:started.Elapsed.TotalSeconds,1);Environment=[pscustomobject]@{OS=(Get-CimInstance Win32_OperatingSystem).Caption;OSVersion=[Environment]::OSVersion.VersionString;OSArchitecture=[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString();ProcessArchitecture=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString();Interactive=[Environment]::UserInteractive;Runner=$env:RUNNER_ENVIRONMENT};IdleUserRange=$idleRange;UserObjects=$user;GdiObjects=$gdi;Handles=$handles;PrivateBytes=$private;WorkingSet=$working;Screenshots=$script:screenshots.ToArray();MetricSamples=$script:metrics.Count;Events=$script:events.ToArray();Cycles=$script:cycleRecords.ToArray();Pass=(@($script:events|Where-Object{$_.Status -eq 'PASS'}).Count);Fail=(@($script:events|Where-Object{$_.Status -eq 'FAIL'}).Count);NotTested=(@($script:events|Where-Object{$_.Status -eq 'NOT TESTED'}).Count);CompletedUtc=[DateTime]::UtcNow.ToString('o')}
}catch{Add-Event 'Resource soak runner' 'FAIL' $_.Exception.ToString()}
finally{
$script:processStopped=$true
 if($script:process){try{$script:process.Refresh();if(-not $script:process.HasExited){$script:process.Kill();if(-not $script:process.WaitForExit(10000)){throw 'Owned application did not stop.'}}}catch{$script:processStopped=$false;Add-Event 'Owned process cleanup' 'FAIL' $_.Exception.Message}}
 if($script:ownedData -and $script:processStopped){try{$expected=[IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'EyeBreakReminder'));if($expected-ine$script:dataPath){throw 'Cleanup path changed.'};$item=Get-Item -LiteralPath $expected -Force;if(($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne 0){throw 'Refusing cleanup of a redirected path.'};Remove-Item -LiteralPath $expected -Recurse -Force;Add-Event 'Isolated app data cleanup' 'PASS'}catch{Add-Event 'Isolated app data cleanup' 'FAIL' $_.Exception.Message}}
 elseif($script:ownedData){Add-Event 'Isolated app data preserved because process termination was not confirmed' 'FAIL' $script:dataPath}
 if($script:cycleRecords.Count){$script:cycleRecords|Export-Csv -LiteralPath (Join-Path $EvidenceDirectory 'cycle-results.csv') -NoTypeInformation -Encoding utf8}
 if($script:metrics.Count){
  $script:metrics|Export-Csv -LiteralPath (Join-Path $EvidenceDirectory 'resource-time-series.csv') -NoTypeInformation -Encoding utf8
  $width=1200;$chartHeight=880;$panelHeight=190;$left=115;$right=1160;$plotWidth=$right-$left
  $svg=[Text.StringBuilder]::new()
  [void]$svg.AppendLine('<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="'+$chartHeight+'" viewBox="0 0 1200 '+$chartHeight+'">')
  [void]$svg.AppendLine('<rect width="1200" height="'+$chartHeight+'" fill="white"/>')
  [void]$svg.AppendLine('<text x="600" y="30" text-anchor="middle" font-family="Segoe UI,Arial" font-size="20" fill="#111">Eye Break Reminder '+$ExpectedProductVersion+' resource soak</text>')
  $panels=@(
   @{Name='USER objects';Property='UserObjects';Color='#1664a0';Scale=1.0},
   @{Name='GDI objects';Property='GdiObjects';Color='#16855b';Scale=1.0},
   @{Name='Process handles';Property='HandleCount';Color='#a05016';Scale=1.0},
   @{Name='Private bytes (MiB)';Property='PrivateBytes';Color='#7446a3';Scale=1048576.0}
  )
  for($panelIndex=0;$panelIndex-lt$panels.Count;$panelIndex++){
   $panel=$panels[$panelIndex];$top=55+$panelIndex*($panelHeight+10);$bottom=$top+$panelHeight
   $values=[double[]]@($script:metrics|ForEach-Object{[double]$_.$($panel.Property)/[double]$panel.Scale})
   $min=($values|Measure-Object -Minimum).Minimum;$max=($values|Measure-Object -Maximum).Maximum
   if($max-le$min){$max=$min+1}
   [void]$svg.AppendLine(('<text x="15" y="{0}" font-family="Segoe UI,Arial" font-size="14" fill="#222">{1}</text>'-f($top+18),$panel.Name))
   for($grid=0;$grid-le4;$grid++){
    $y=$top+20+($panelHeight-35)*$grid/4.0;$label=[math]::Round($max-($max-$min)*$grid/4.0,1)
    [void]$svg.AppendLine(('<line x1="{0}" y1="{1}" x2="{2}" y2="{1}" stroke="#dddddd"/><text x="108" y="{3}" text-anchor="end" font-family="Segoe UI,Arial" font-size="10" fill="#555">{4}</text>'-f$left,$y,$right,($y+4),$label))
   }
   $points=[Collections.Generic.List[string]]::new()
   for($point=0;$point-lt$values.Count;$point++){
    $x=$left+($plotWidth*$point/[math]::Max(1,$values.Count-1));$y=$top+20+($panelHeight-35)*(($max-$values[$point])/($max-$min))
    $points.Add(('{0:0.0},{1:0.0}'-f$x,$y))
   }
   [void]$svg.AppendLine(('<polyline fill="none" stroke="{0}" stroke-width="1.5" points="{1}"/>'-f$panel.Color,($points-join' ')))
   [void]$svg.AppendLine(('<text x="{0}" y="{1}" font-family="Segoe UI,Arial" font-size="10" fill="#555">sample 1</text><text x="{2}" y="{1}" text-anchor="end" font-family="Segoe UI,Arial" font-size="10" fill="#555">sample {3}</text>'-f$left,($bottom-3),$right,$values.Count))
  }
  [void]$svg.AppendLine('</svg>')
  [IO.File]::WriteAllText((Join-Path $EvidenceDirectory 'resource-trends.svg'),$svg.ToString(),[Text.UTF8Encoding]::new($false))
 }
 if($script:result){$script:result.Events=$script:events.ToArray();$script:result.Pass=(@($script:events|Where-Object{$_.Status -eq 'PASS'}).Count);$script:result.Fail=(@($script:events|Where-Object{$_.Status -eq 'FAIL'}).Count);$script:result.NotTested=(@($script:events|Where-Object{$_.Status -eq 'NOT TESTED'}).Count);$script:result|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'soak-summary.json') -Encoding utf8;$script:result|ConvertTo-Json -Depth 6}
 else{$failure=[pscustomobject]@{Version=$ExpectedProductVersion;Mode='Scheduled';CyclesRequested=$Cycles;CyclesCompleted=$script:cycleRecords.Count;Events=$script:events.ToArray();Fail=(@($script:events|Where-Object{$_.Status -eq 'FAIL'}).Count)};$failure|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'soak-summary.json') -Encoding utf8;$failure|ConvertTo-Json -Depth 6}
}
if(-not $script:result -or $script:result.Fail-gt 0){exit 1}
