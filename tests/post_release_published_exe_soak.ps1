param(
  [Parameter(Mandatory=$true)][string]$ExecutablePath,
  [int]$DurationMinutes = 120,
  [string]$EvidenceDirectory = (Join-Path (Get-Location) 'build\post-release-evidence')
)
$ErrorActionPreference='Stop'
$expected='2895c80f942dd03186305d913516700552524ec5ba9a77da0dab457a3265fcc6'
$events=[System.Collections.Generic.List[object]]::new()
$samples=[System.Collections.Generic.List[object]]::new()
$ownedData=$false
$process=$null
$mainWindow=[IntPtr]::Zero
$native=@"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public struct EBR_SOAK_RECT { public int Left,Top,Right,Bottom; }
public static class EBR_SOAK_NATIVE {
  public delegate bool EnumCallback(IntPtr hwnd,IntPtr data);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumCallback callback,IntPtr data);
  [DllImport("user32.dll",SetLastError=true)] public static extern uint GetWindowThreadProcessId(IntPtr hwnd,out uint pid);
  [DllImport("user32.dll",SetLastError=true)] public static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] private static extern int GetClassNameW(IntPtr hwnd,StringBuilder name,int maxCount);
  [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] private static extern int GetWindowTextW(IntPtr hwnd,StringBuilder text,int maxCount);
  [DllImport("user32.dll",SetLastError=true)] private static extern int GetWindowTextLengthW(IntPtr hwnd);
  [DllImport("user32.dll",SetLastError=true)] public static extern IntPtr GetDlgItem(IntPtr hwnd,int id);
  [DllImport("user32.dll",SetLastError=true)] public static extern IntPtr SendMessageW(IntPtr hwnd,uint message,IntPtr wp,IntPtr lp);
  [DllImport("user32.dll",SetLastError=true)] public static extern IntPtr SendMessageTimeoutW(IntPtr hwnd,uint message,IntPtr wp,IntPtr lp,uint flags,uint timeout,out IntPtr result);
  [DllImport("user32.dll",SetLastError=true)] public static extern bool PostMessageW(IntPtr hwnd,uint message,IntPtr wp,IntPtr lp);
  [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern uint RegisterWindowMessageW(string name);
  [DllImport("user32.dll")] public static extern int GetGuiResources(IntPtr process,int flags);
  [DllImport("user32.dll",SetLastError=true)] public static extern bool GetWindowRect(IntPtr hwnd,out EBR_SOAK_RECT rect);
  public static string Text(IntPtr hwnd){if(hwnd==IntPtr.Zero)return "";int n=GetWindowTextLengthW(hwnd);StringBuilder b=new StringBuilder(Math.Max(2,n+2));GetWindowTextW(hwnd,b,b.Capacity);return b.ToString();}
  public static string ClassName(IntPtr hwnd){StringBuilder b=new StringBuilder(256);GetClassNameW(hwnd,b,b.Capacity);return b.ToString();}
  public static IntPtr[] WindowsForProcess(int pid,string className){List<IntPtr> result=new List<IntPtr>();EnumCallback cb=delegate(IntPtr h,IntPtr ignored){uint actual;GetWindowThreadProcessId(h,out actual);if(actual==(uint)pid&&IsWindowVisible(h)&&(className==null||ClassName(h)==className))result.Add(h);return true;};EnumWindows(cb,IntPtr.Zero);GC.KeepAlive(cb);return result.ToArray();}
}
"@
Add-Type -TypeDefinition $native -ErrorAction Stop
function Add-Result([string]$Name,[string]$Status,$Details=$null){$events.Add([pscustomobject]@{Name=$Name;Status=$Status;Details=$Details;Utc=[DateTime]::UtcNow.ToString('o')})}
function Check([bool]$Condition,[string]$Name,$Details=$null){if($Condition){Add-Result $Name 'PASS' $Details}else{Add-Result $Name 'FAIL' $Details}}
function Get-Status([IntPtr]$Window){$control=[EBR_SOAK_NATIVE]::GetDlgItem($Window,41);return [EBR_SOAK_NATIVE]::Text($control)}
function Get-Countdown([IntPtr]$Window){$control=[EBR_SOAK_NATIVE]::GetDlgItem($Window,40);return [EBR_SOAK_NATIVE]::Text($control)}
function Get-BreakWindows([int]$ProcessId){@([EBR_SOAK_NATIVE]::WindowsForProcess($ProcessId,'EyeBreakReminder.Break'))}
function Wait-MainWindow([int]$ProcessId,[int]$TimeoutSeconds=20){
  $watch=[Diagnostics.Stopwatch]::StartNew()
  while($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds){$handles=[EBR_SOAK_NATIVE]::WindowsForProcess($ProcessId,'EyeBreakReminder.Native');if($handles.Count -eq 1){return $handles[0]};if($handles.Count -gt 1){throw 'The soak process created multiple main application windows.'};Start-Sleep -Milliseconds 100}
  return [IntPtr]::Zero
}
function Get-ResourceSample([Diagnostics.Process]$App,[int]$ElapsedSeconds,[string]$Status,[string]$Countdown,[int]$BreakWindows){
  $App.Refresh()
  $gdi=[EBR_SOAK_NATIVE]::GetGuiResources($App.Handle,0);$user=[EBR_SOAK_NATIVE]::GetGuiResources($App.Handle,1)
  return [pscustomobject]@{ElapsedSeconds=$ElapsedSeconds;Utc=[DateTime]::UtcNow.ToString('o');Status=$Status;Countdown=$Countdown;BreakWindowCount=$BreakWindows;HandleCount=$App.HandleCount;GdiObjects=$gdi;UserObjects=$user;PrivateBytes=$App.PrivateMemorySize64;WorkingSetBytes=$App.WorkingSet64;CpuMilliseconds=[Math]::Round($App.TotalProcessorTime.TotalMilliseconds)}
}
function Stop-OwnedApp {
  if($process -and -not $process.HasExited -and $mainWindow -ne [IntPtr]::Zero){$message=[EBR_SOAK_NATIVE]::RegisterWindowMessageW('EyeBreakReminder.Exit.Native.1');[void][EBR_SOAK_NATIVE]::PostMessageW($mainWindow,$message,[IntPtr]::Zero,[IntPtr]::Zero);if($process.WaitForExit(10000)){return $true}}
  if($process -and -not $process.HasExited){Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue;[void]$process.WaitForExit(5000)}
  return $false
}
try{
  if($env:GITHUB_ACTIONS -ne 'true'){throw 'The published-binary soak is restricted to a disposable GitHub Actions runner.'}
  if($DurationMinutes -lt 120 -or $DurationMinutes -gt 180){throw 'A real soak must run for at least two hours and no more than three hours.'}
  [void][IO.Directory]::CreateDirectory($EvidenceDirectory)
  $os=Get-CimInstance Win32_OperatingSystem;$nativeArch=[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
  Check ([int]$os.BuildNumber -ge 22000 -and $nativeArch -eq 'Arm64') 'Soak environment is an actual Windows 11 ARM64 runner' ([pscustomobject]@{Caption=$os.Caption;Build=$os.BuildNumber;NativeArchitecture=$nativeArch;RunnerArchitecture=$env:RUNNER_ARCH})
  if([int]$os.BuildNumber -lt 22000 -or $nativeArch -ne 'Arm64'){throw 'The soak must run on the isolated Windows 11 ARM64 runner.'}
  $explorer=Get-Process explorer -ErrorAction SilentlyContinue | Select-Object -First 1
  $shell=@()
  if($explorer){$shell=@([EBR_SOAK_NATIVE]::WindowsForProcess($explorer.Id,'Shell_TrayWnd'))}
  $interactiveDesktop=[Environment]::UserInteractive -and $null -ne $explorer -and $shell.Count -gt 0
  Check $interactiveDesktop 'The runner exposes its interactive Explorer desktop' ([pscustomobject]@{UserInteractive=[Environment]::UserInteractive;TaskbarWindows=$shell.Count;ExplorerPid=if($explorer){$explorer.Id}else{$null}})
  if(-not $interactiveDesktop){throw 'The soak requires an interactive Explorer desktop with a taskbar owned by Explorer.'}

  $path=[IO.Path]::GetFullPath($ExecutablePath)
  if(-not (Test-Path -LiteralPath $path -PathType Leaf)){throw "Published standalone executable is missing: $path"}
  $hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
  Check ($hash -eq $expected) 'Soak executable is the exact public EyeBreakReminder.exe' ([pscustomobject]@{Path=$path;SHA256=$hash})
  if($hash -ne $expected){throw 'Refusing to soak an executable that does not match the published release hash.'}

  $dataDir=Join-Path $env:LOCALAPPDATA 'EyeBreakReminder'
  if(Test-Path -LiteralPath $dataDir){throw "Refusing to reuse pre-existing runner app data: $dataDir"}
  [void][IO.Directory]::CreateDirectory($dataDir);$ownedData=$true
  $settings="workMinutes=1`nbreakSeconds=5`ntheme=2`nbreakModeColors=1`nalarm=0`nnotifications=0`nrepeat=0`n"
  [IO.File]::WriteAllText((Join-Path $dataDir 'settings.ini'),$settings,[Text.UTF8Encoding]::new($false))
  Add-Result 'Disposable soak profile configured' 'INFO' ([pscustomobject]@{DataDirectory=$dataDir;WorkMinutes=1;BreakSeconds=5;AlarmEnabled=$false;NotificationsEnabled=$false})

  $process=Start-Process -FilePath $path -WorkingDirectory (Split-Path -Parent $path) -PassThru
  $mainWindow=Wait-MainWindow $process.Id
  Check ($mainWindow -ne [IntPtr]::Zero) 'Exact release binary creates one Win32 main window' ([pscustomobject]@{Pid=$process.Id;Window=('0x{0:X}' -f $mainWindow.ToInt64())})
  if($mainWindow -eq [IntPtr]::Zero){throw 'Published app main window was not created.'}
  $startStatus=Get-Status $mainWindow;$startCountdown=Get-Countdown $mainWindow
  Check ($startStatus -match 'Running' -and $startCountdown -match '^\d{1,2}:\d{2}$') 'Published app starts a valid one-minute soak timer' ([pscustomobject]@{Status=$startStatus;Countdown=$startCountdown})

  $clock=[Diagnostics.Stopwatch]::StartNew();$nextResourceSample=0;$breakStarts=0;$breakEnds=0;$duplicateBreaks=0;$invalidCountdowns=0;$statusErrors=0;$previousStatus=$startStatus;$lastSample=$null
  while($clock.Elapsed.TotalMinutes -lt $DurationMinutes){
    $process.Refresh()
    if($process.HasExited){throw "Published app exited unexpectedly at $([Math]::Round($clock.Elapsed.TotalMinutes,2)) minutes with exit code $($process.ExitCode)."}
    $status=Get-Status $mainWindow;$countdown=Get-Countdown $mainWindow
    if($status -notmatch 'Running|Taking an eye break|Paused'){$statusErrors++;throw "Unexpected soak timer state '$status'."}
    if($countdown -notmatch '^\d{1,2}:\d{2}$'){$invalidCountdowns++;throw "Timer countdown became invalid: '$countdown'."}
    $breakWindows=Get-BreakWindows $process.Id
    if($breakWindows.Count -gt 1){$duplicateBreaks++;throw "Multiple reminder windows appeared during the soak ($($breakWindows.Count))."}
    $isBreak=$status -like '*Taking an eye break*'
    if($isBreak -and $breakWindows.Count -ne 1){Start-Sleep -Milliseconds 150;$breakWindows=Get-BreakWindows $process.Id;if($breakWindows.Count -ne 1){throw 'Break status was active without exactly one reminder window.'}}
    if(-not $isBreak -and $breakWindows.Count -ne 0){$duplicateBreaks++;throw "A reminder window remained while the app reported '$status'."}
    if($previousStatus -notlike '*Taking an eye break*' -and $isBreak){$breakStarts++}
    if($previousStatus -like '*Taking an eye break*' -and -not $isBreak){$breakEnds++}
    $previousStatus=$status
    if([int]$clock.Elapsed.TotalSeconds -ge $nextResourceSample){
      $sample=Get-ResourceSample $process ([int]$clock.Elapsed.TotalSeconds) $status $countdown $breakWindows.Count
      $samples.Add($sample);$lastSample=$sample;$nextResourceSample=[int]$clock.Elapsed.TotalSeconds+30
      $responsive=[IntPtr]::Zero;$answer=([EBR_SOAK_NATIVE]::SendMessageTimeoutW($mainWindow,0,[IntPtr]::Zero,[IntPtr]::Zero,2,1500,[ref]$responsive)-ne [IntPtr]::Zero)
      if(-not $answer){throw 'Main window did not answer a bounded WM_NULL responsiveness probe.'}
    }
    Start-Sleep -Milliseconds 1000
  }
  $clock.Stop()
  $finalStatus=Get-Status $mainWindow;$finalCountdown=Get-Countdown $mainWindow
  Check ($clock.Elapsed.TotalMinutes -ge 119.9) 'Soak completed at least 120 minutes of wall-clock time' ([Math]::Round($clock.Elapsed.TotalMinutes,2))
  Check ($breakStarts -ge 100 -and $breakEnds -ge 99) 'Soak observed at least 100 naturally scheduled break cycles and completions' ([pscustomobject]@{BreakStarts=$breakStarts;BreakEnds=$breakEnds;DurationMinutes=[Math]::Round($clock.Elapsed.TotalMinutes,2)})
  Check ($process -and -not $process.HasExited -and $statusErrors -eq 0 -and $invalidCountdowns -eq 0 -and $duplicateBreaks -eq 0) 'Soak ended without a process exit, invalid state/countdown, or duplicate reminder window' ([pscustomobject]@{FinalStatus=$finalStatus;FinalCountdown=$finalCountdown;StatusErrors=$statusErrors;InvalidCountdowns=$invalidCountdowns;DuplicateBreaks=$duplicateBreaks})
  if($samples.Count -gt 1){
    $first=$samples[0];$last=$samples[$samples.Count-1]
    Add-Result 'Soak resource trend recorded (not a standalone leak assertion)' 'INFO' ([pscustomobject]@{Samples=$samples.Count;StartPrivateBytes=$first.PrivateBytes;EndPrivateBytes=$last.PrivateBytes;PrivateBytesDelta=$last.PrivateBytes-$first.PrivateBytes;MaxPrivateBytes=($samples|Measure-Object PrivateBytes -Maximum).Maximum;StartGdi=$first.GdiObjects;EndGdi=$last.GdiObjects;MaxGdi=($samples|Measure-Object GdiObjects -Maximum).Maximum;StartUser=$first.UserObjects;EndUser=$last.UserObjects;MaxUser=($samples|Measure-Object UserObjects -Maximum).Maximum;StartHandles=$first.HandleCount;EndHandles=$last.HandleCount;MaxHandles=($samples|Measure-Object HandleCount -Maximum).Maximum;CpuMilliseconds=$last.CpuMilliseconds})
  }
}catch{Add-Result 'Published binary long-run soak' 'FAIL' $_.Exception.Message}
finally{
  try{if($process -and -not $process.HasExited){$graceful=Stop-OwnedApp;Add-Result 'Soak process cleanup' $(if($graceful){'PASS'}else{'FAIL'}) ([pscustomobject]@{Graceful=$graceful;Pid=$process.Id})}}catch{Add-Result 'Soak process cleanup' 'FAIL' $_.Exception.Message}
  $csvPath=Join-Path $EvidenceDirectory 'published-app-soak-resource-samples.csv'
  $samples | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
  if($ownedData -and (Test-Path -LiteralPath $dataDir)){
    try{$resolved=[IO.Path]::GetFullPath($dataDir);$base=[IO.Path]::GetFullPath($env:LOCALAPPDATA);if(-not $resolved.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)){throw 'Soak cleanup path escaped runner LocalAppData.'};Remove-Item -LiteralPath $resolved -Recurse -Force;Add-Result 'Disposable soak app data cleanup' 'PASS' $resolved}catch{Add-Result 'Disposable soak app data cleanup' 'FAIL' $_.Exception.Message}
  }
  $summary=[pscustomobject]@{Application='Eye Break Reminder';Release='v1.2.0';ExecutableSHA256=$expected;Environment='Windows 11 ARM64 hosted runner; x64 application emulation';DurationMinutes=$DurationMinutes;Events=$events.ToArray();Pass=(@($events|Where-Object Status -eq 'PASS')).Count;Fail=(@($events|Where-Object Status -eq 'FAIL')).Count;NotTested=(@($events|Where-Object Status -eq 'NOT TESTED')).Count;Informational=(@($events|Where-Object Status -eq 'INFO')).Count;BreakStarts=$breakStarts;BreakEnds=$breakEnds;ResourceSamples=$samples.Count;ResourceCsv=$csvPath;CompletedUtc=[DateTime]::UtcNow.ToString('o')}
  $summary|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'published-app-soak-summary.json') -Encoding UTF8
  $summary|ConvertTo-Json -Depth 8
}
if($summary.Fail -gt 0){exit 1}
