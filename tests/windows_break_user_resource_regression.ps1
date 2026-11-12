param(
  [Parameter(Mandatory=$true)][string]$ExecutablePath,
  [string]$EvidenceDirectory = 'build/hotfix-user-object-evidence',
  [ValidateRange(3,100)][int]$Cycles = 12,
  [ValidateSet('1.2.0','1.2.1')][string]$ExpectedProductVersion = '1.2.1',
  [ValidateSet('NoGrowth','Growth')][string]$ExpectedResourceBehavior = 'NoGrowth'
)
$ErrorActionPreference = 'Stop'
[void][IO.Directory]::CreateDirectory($EvidenceDirectory)
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
$native = @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public struct EBR_HOTFIX_RECT { public int Left,Top,Right,Bottom; }
public static class EBR_HOTFIX_NATIVE {
  public delegate bool EnumProc(IntPtr hwnd,IntPtr data);
  [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc callback,IntPtr data);
  [DllImport("user32.dll",SetLastError=true)] public static extern uint GetWindowThreadProcessId(IntPtr hwnd,out uint pid);
  [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] private static extern int GetClassNameW(IntPtr hwnd,StringBuilder text,int maxCount);
  [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] private static extern int GetWindowTextW(IntPtr hwnd,StringBuilder text,int maxCount);
  [DllImport("user32.dll",SetLastError=true)] public static extern IntPtr GetDlgItem(IntPtr hwnd,int id);
  [DllImport("user32.dll",SetLastError=true)] public static extern IntPtr SendMessageTimeoutW(IntPtr hwnd,uint msg,IntPtr wp,IntPtr lp,uint flags,uint timeout,out IntPtr result);
  [DllImport("user32.dll",SetLastError=true)] public static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll",SetLastError=true)] public static extern bool IsWindow(IntPtr hwnd);
  [DllImport("user32.dll",SetLastError=true)] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern IntPtr FindWindowW(string className,string windowName);
  [DllImport("user32.dll",SetLastError=true)] public static extern bool GetWindowRect(IntPtr hwnd,out EBR_HOTFIX_RECT rect);
  [DllImport("user32.dll",SetLastError=true)] public static extern int GetGuiResources(IntPtr process,uint flags);
  public static string ClassName(IntPtr hwnd){StringBuilder b=new StringBuilder(256);GetClassNameW(hwnd,b,b.Capacity);return b.ToString();}
  public static string Text(IntPtr hwnd){StringBuilder b=new StringBuilder(512);GetWindowTextW(hwnd,b,b.Capacity);return b.ToString();}
  public static IntPtr FindProcessWindow(int processId,string className){IntPtr found=IntPtr.Zero;EnumProc cb=delegate(IntPtr h,IntPtr ignored){uint pid;GetWindowThreadProcessId(h,out pid);if(pid==(uint)processId&&IsWindowVisible(h)&&String.Equals(ClassName(h),className,StringComparison.Ordinal)){found=h;return false;}return true;};EnumWindows(cb,IntPtr.Zero);GC.KeepAlive(cb);return found;}
  public static int UserObjects(IntPtr process){return GetGuiResources(process,1);}
  public static bool Click(IntPtr hwnd){if(hwnd==IntPtr.Zero)return false;IntPtr result;return SendMessageTimeoutW(hwnd,0x00F5,IntPtr.Zero,IntPtr.Zero,2,5000,out result)!=IntPtr.Zero;}
}
"@
if(-not ('EBR_HOTFIX_NATIVE' -as [type])){Add-Type -TypeDefinition $native -ErrorAction Stop}
$events = [System.Collections.Generic.List[object]]::new()
$cycleSamples = [System.Collections.Generic.List[object]]::new()
$ownedData = $false
$ownedDataPath = $null
$process = $null
$mainWindow = [IntPtr]::Zero
$screenshot = $null
function Add-Event([string]$Name,[string]$Status,$Details=$null){$events.Add([pscustomobject]@{Name=$Name;Status=$Status;Details=$Details;Utc=[DateTime]::UtcNow.ToString('o')})}
function Check([bool]$Condition,[string]$Name,$Details=$null){if($Condition){Add-Event $Name 'PASS' $Details}else{Add-Event $Name 'FAIL' $Details}}
function Get-Status([IntPtr]$Window){$h=[EBR_HOTFIX_NATIVE]::GetDlgItem($Window,41);if($h -eq [IntPtr]::Zero){return ''};return [EBR_HOTFIX_NATIVE]::Text($h)}
function Wait-Condition([scriptblock]$Condition,[int]$Seconds=8){$timer=[Diagnostics.Stopwatch]::StartNew();while($timer.Elapsed.TotalSeconds -lt $Seconds){if(& $Condition){return $true};Start-Sleep -Milliseconds 100};return $false}
function Get-AppUserObjects {
  $script:process.Refresh()
  if($script:process.HasExited){throw 'The tested application exited during resource sampling.'}
  $count=[EBR_HOTFIX_NATIVE]::UserObjects($script:process.Handle)
  if($count -le 0){throw "GetGuiResources did not return a valid USER-object count for application PID $($script:process.Id). Win32 error: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"}
  return $count
}
function Invoke-BreakCycle([int]$Index,[bool]$Capture=$false){
  $before=Get-AppUserObjects
  $take=[EBR_HOTFIX_NATIVE]::GetDlgItem($script:mainWindow,22)
  if(-not [EBR_HOTFIX_NATIVE]::Click($take)){throw "Cycle ${Index}: the Take a break now button did not respond."}
  $opened=Wait-Condition {([EBR_HOTFIX_NATIVE]::FindProcessWindow($script:process.Id,'EyeBreakReminder.Break')) -ne [IntPtr]::Zero -and (Get-Status $script:mainWindow) -match 'Taking an eye break'}
  $breakWindow=[EBR_HOTFIX_NATIVE]::FindProcessWindow($script:process.Id,'EyeBreakReminder.Break')
  $breakStatus=Get-Status $script:mainWindow
  if(-not $opened -or $breakWindow -eq [IntPtr]::Zero -or $breakStatus -notmatch 'Taking an eye break'){throw "Cycle ${Index}: reminder window/status not observed; status='$breakStatus'."}
  if($Capture -and [EBR_HOTFIX_NATIVE]::GetForegroundWindow() -eq $breakWindow){
    $rect=New-Object EBR_HOTFIX_RECT
    if([EBR_HOTFIX_NATIVE]::GetWindowRect($breakWindow,[ref]$rect)){
      $width=$rect.Right-$rect.Left;$height=$rect.Bottom-$rect.Top
      if($width -gt 100 -and $height -gt 100){$bitmap=[Drawing.Bitmap]::new($width,$height);$graphics=[Drawing.Graphics]::FromImage($bitmap);try{$graphics.CopyFromScreen($rect.Left,$rect.Top,0,0,$bitmap.Size);$script:screenshot=Join-Path $EvidenceDirectory 'candidate-break-reminder.png';$bitmap.Save($script:screenshot,[Drawing.Imaging.ImageFormat]::Png)}finally{$graphics.Dispose();$bitmap.Dispose()}}
    }
  }
  $skip=[EBR_HOTFIX_NATIVE]::GetDlgItem($breakWindow,24)
  if(-not [EBR_HOTFIX_NATIVE]::Click($skip)){throw "Cycle ${Index}: the Skip button did not respond."}
  $closed=Wait-Condition {-not [EBR_HOTFIX_NATIVE]::IsWindow($breakWindow) -and ([EBR_HOTFIX_NATIVE]::FindProcessWindow($script:process.Id,'EyeBreakReminder.Break')) -eq [IntPtr]::Zero -and (Get-Status $script:mainWindow) -match 'Running'}
  Start-Sleep -Milliseconds 250
  $after=Get-AppUserObjects
  $sample=[pscustomobject]@{Cycle=$Index;Measured=($Index -gt 0);ProcessId=$script:process.Id;BreakWindow=('0x{0:X}' -f $breakWindow.ToInt64());Status=if($closed){'PASS'}else{'FAIL'};BreakStatus=$breakStatus;BreakWindowClosed=$closed;UserObjectsBefore=$before;UserObjectsAfter=$after;Delta=$after-$before;Utc=[DateTime]::UtcNow.ToString('o')}
  $cycleSamples.Add($sample)
  Check $closed "Break cycle $Index opened, skipped and returned to work" $sample
  if($Index -eq 0){Add-Event 'Warm-up resource sample (excluded from measured-cycle assertions)' 'INFO' $sample}
  elseif($ExpectedResourceBehavior -eq 'Growth'){
    if($sample.Delta -gt 0){Add-Event "v1.2.0 baseline USER-object leak reproduced in cycle $Index" 'INFO' $sample}else{Check $false "v1.2.0 baseline USER-object leak reproduced in cycle $Index" $sample}
  }else{Check ($sample.Delta -eq 0) "Break cycle $Index released temporary USER objects" $sample}
}
try{
  if($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:RUNNER_OS -ne 'Windows'){
    throw 'Refusing application execution outside a disposable GitHub-hosted Windows runner.'
  }
  $exe=(Resolve-Path -LiteralPath $ExecutablePath -ErrorAction Stop).Path
  $file=Get-Item -LiteralPath $exe
  $version=$file.VersionInfo
  $expectedVersionPattern='^'+[regex]::Escape($ExpectedProductVersion)+'(\.0)?$'
  $executableHash=(Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant()
  Check ($version.ProductName -eq 'Eye Break Reminder' -and $version.ProductVersion -match $expectedVersionPattern) "Executable version metadata is $ExpectedProductVersion" ([pscustomobject]@{ProductName=$version.ProductName;ProductVersion=$version.ProductVersion;Path=$exe;SHA256=$executableHash})
  if($version.ProductName -ne 'Eye Break Reminder' -or $version.ProductVersion -notmatch $expectedVersionPattern){throw "Expected Eye Break Reminder $ExpectedProductVersion executable; found $($version.ProductName) $($version.ProductVersion)."}
  if($ExpectedProductVersion -eq '1.2.0' -and $executableHash -cne '2895c80f942dd03186305d913516700552524ec5ba9a77da0dab457a3265fcc6'){throw 'Refusing to execute a v1.2.0 baseline that does not match the exact published executable SHA-256.'}
  if(-not [Environment]::UserInteractive -or [EBR_HOTFIX_NATIVE]::FindWindowW('Shell_TrayWnd',$null) -eq [IntPtr]::Zero){Add-Event 'Interactive Explorer desktop available' 'NOT TESTED' 'The hosted runner did not expose an interactive Explorer desktop.';throw 'The USER-object regression requires a real interactive desktop.'}
  $data=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'EyeBreakReminder'
  if(Test-Path -LiteralPath $data){throw "Refusing to overwrite pre-existing runner application data: $data"}
  if([EBR_HOTFIX_NATIVE]::FindWindowW('EyeBreakReminder.Native',$null) -ne [IntPtr]::Zero){throw 'Refusing to run alongside an existing Eye Break Reminder window.'}
  [void][IO.Directory]::CreateDirectory($data);$ownedData=$true
  $ownedDataPath=(Resolve-Path -LiteralPath $data -ErrorAction Stop).Path
  $settings="workMinutes=1`nbreakSeconds=30`ntheme=2`nbreakModeColors=1`nalarm=0`nnotifications=0`nrepeat=0`nsnooze=0`nautoStart=1`n"
  [IO.File]::WriteAllText((Join-Path $data 'settings.ini'),$settings,[Text.UTF8Encoding]::new($false))
  Add-Event 'Disposable isolated runner profile prepared' 'INFO' ([pscustomobject]@{DataDirectory=$data;WorkMinutes=1;BreakSeconds=30;AlarmEnabled=$false;NotificationsEnabled=$false})
  $process=Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe) -PassThru
  $found=Wait-Condition {$script:mainWindow=[EBR_HOTFIX_NATIVE]::FindProcessWindow($script:process.Id,'EyeBreakReminder.Native');$script:mainWindow -ne [IntPtr]::Zero} 30
  Check $found 'Test executable created its main Win32 window' ([pscustomobject]@{Pid=$process.Id;Window=('0x{0:X}' -f $mainWindow.ToInt64());Path=$exe})
  if(-not $found){throw 'Test executable main window did not appear.'}
  $actualPath=(Get-Process -Id $process.Id -ErrorAction Stop).Path
  $sameExecutable=[IO.Path]::GetFullPath($actualPath) -ieq $exe
  Check $sameExecutable 'The running process matches the executable passed to the regression test' $actualPath
  if(-not $sameExecutable){throw 'Started process does not match the specified executable.'}
  if(-not (Wait-Condition {(Get-Status $script:mainWindow) -match 'Running'})){throw "Test executable timer did not start; status='$(Get-Status $mainWindow)'."}
  Invoke-BreakCycle 0 $true
  Add-Event 'Warm-up break cycle completed' 'INFO' ([pscustomobject]@{ExpectedResourceBehavior=$ExpectedResourceBehavior;Reason='One initial cycle primes common controls before the measured repeated-cycle check.'})
  for($index=1;$index -le $Cycles;$index++){Invoke-BreakCycle $index $false}
  Check (@($cycleSamples | Where-Object Measured).Count -eq $Cycles) 'All requested measured break cycles executed' ([pscustomobject]@{Requested=$Cycles;Actual=@($cycleSamples | Where-Object Measured).Count})
  Check ((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $executableHash) 'Tested executable bytes remained unchanged' $executableHash
  if($screenshot -and (Test-Path -LiteralPath $screenshot)){Add-Event 'Real break-window screenshot captured' 'INFO' $screenshot}else{Add-Event 'Real break-window screenshot captured' 'NOT TESTED' 'The runner desktop foreground did not expose the break window for pixel capture.'}
}catch{Add-Event 'USER-object regression runner' 'FAIL' $_.Exception.Message}
finally{
  $processStopped=$true
  if($process){
    try{$process.Refresh();if(-not $process.HasExited){$process.Kill();if(-not $process.WaitForExit(5000)){throw 'Owned test process did not stop within five seconds.'}}}catch{$processStopped=$false;Add-Event 'Owned test process cleanup' 'FAIL' $_.Exception.Message}
  }
  if($ownedData){
    try{
      if(-not $processStopped){throw 'Preserving runner data because the owned application could not be confirmed stopped.'}
      $expectedDataPath=[IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'EyeBreakReminder'))
      if(-not $ownedDataPath -or $ownedDataPath -ine $expectedDataPath){throw 'Owned cleanup path does not match the exact application data directory created by this test.'}
      if(Test-Path -LiteralPath $ownedDataPath){
        $resolved=(Resolve-Path -LiteralPath $ownedDataPath -ErrorAction Stop).Path
        $item=Get-Item -LiteralPath $resolved -Force
        if($resolved -ine $expectedDataPath -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Refusing cleanup of a changed or redirected data directory.'}
        Remove-Item -LiteralPath $resolved -Recurse -Force
        Add-Event 'Disposable application data cleaned up' 'INFO' $resolved
      }
    }catch{Add-Event 'Disposable application data cleanup' 'FAIL' $_.Exception.Message}
  }
  $osCaption=[Environment]::OSVersion.VersionString
  try{$osCaption=(Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption}catch{}
  $result=[pscustomobject]@{Application='Eye Break Reminder';TestedVersion=$ExpectedProductVersion;ExecutableSHA256=$executableHash;ExpectedResourceBehavior=$ExpectedResourceBehavior;Test='Repeated real Win32 break window lifecycle with per-process USER-object sampling';Environment=[pscustomobject]@{OS=$osCaption;Architecture=[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString();Interactive=[Environment]::UserInteractive;RunnerEnvironment=$env:RUNNER_ENVIRONMENT};RequestedMeasuredCycles=$Cycles;Cycles=$cycleSamples.ToArray();Events=$events.ToArray();Pass=(@($events|Where-Object Status -eq 'PASS')).Count;Fail=(@($events|Where-Object Status -eq 'FAIL')).Count;NotTested=(@($events|Where-Object Status -eq 'NOT TESTED')).Count;Informational=(@($events|Where-Object Status -eq 'INFO')).Count;Screenshot=$screenshot;CompletedUtc=[DateTime]::UtcNow.ToString('o')}
  $result|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'windows-break-user-resource-regression.json') -Encoding UTF8
  $result|ConvertTo-Json -Depth 5
}
if($result.Fail -gt 0){exit 1}
