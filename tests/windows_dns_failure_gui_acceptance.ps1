param(
  [Parameter(Mandatory=$true)][string]$TestApplication,
  [string]$EvidencePath = 'build/v1.4.0-updater-evidence/dns-failure-gui.json'
)

$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_OS -ne 'Windows' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') { throw 'DNS GUI acceptance is restricted to a disposable GitHub Actions Windows runner.' }
if([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne [Runtime.InteropServices.Architecture]::X64) { throw 'DNS GUI acceptance requires an x64 Windows runner.' }
if([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP) -or [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { throw 'Hosted runner test paths are unavailable.' }

$testRoot=[IO.Path]::GetFullPath((Join-Path $env:RUNNER_TEMP 'EyeBreakReminder-v140-dns-gui'))
$runnerPrefix=[IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')+'\'
if(-not $testRoot.StartsWith($runnerPrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Resolved DNS GUI test directory escaped RUNNER_TEMP.'}
if(Test-Path -LiteralPath $testRoot){throw "Refusing to reuse an existing DNS GUI test directory: $testRoot"}
$localDataRoot=[IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'EyeBreakReminder'))
if(Test-Path -LiteralPath $localDataRoot){throw "Refusing to touch pre-existing local application data: $localDataRoot"}
if($null -ne $env:EBR_GUI_TEST_DNS_FAILURE -and $env:EBR_GUI_TEST_DNS_FAILURE -ne ''){throw 'Refusing to run with a pre-existing DNS endpoint override.'}
$appKey='HKCU:\Software\EyeBreakReminder';$uninstallKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder'
if((Test-Path -LiteralPath $appKey) -or (Test-Path -LiteralPath $uninstallKey)){throw 'Refusing to run with pre-existing Eye Break Reminder registry state.'}

$testApp=[IO.Path]::GetFullPath($TestApplication)
if(-not(Test-Path -LiteralPath $testApp -PathType Leaf) -or (Get-Item -LiteralPath $testApp).VersionInfo.ProductVersion -notmatch '^1\.4\.0(\.0)?$'){throw 'The DNS GUI test requires the isolated v1.4.0 test integration executable.'}
$evidence=[IO.Path]::GetFullPath($EvidencePath);$evidenceRoot=[IO.Path]::GetFullPath((Join-Path (Get-Location) 'build/v1.4.0-updater-evidence'))
if(-not $evidence.StartsWith($evidenceRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Evidence must remain under build/v1.4.0-updater-evidence.'}

$native=@'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class EBR_DNS_GUI_NATIVE {
  public delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr data);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc callback, IntPtr data);
  [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, EnumWindowsProc callback, IntPtr data);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr hwnd, StringBuilder text, int count);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowTextW(IntPtr hwnd, StringBuilder text, int count);
  [DllImport("user32.dll")] static extern int GetDlgCtrlID(IntPtr hwnd);
  [DllImport("user32.dll", SetLastError=true)] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool PostMessageW(IntPtr hwnd, uint message, IntPtr w, IntPtr l);
  [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr SendMessageW(IntPtr hwnd, uint message, IntPtr w, IntPtr l);
  [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr SendMessageTimeoutW(IntPtr hwnd, uint message, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr result);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern uint RegisterWindowMessageW(string name);
  public static IntPtr FindMainWindowByPid(int wantedPid) {
    IntPtr found=IntPtr.Zero;
    EnumWindowsProc callback=delegate(IntPtr hwnd, IntPtr ignored) {
      uint pid=0; GetWindowThreadProcessId(hwnd,out pid);
      if((int)pid==wantedPid && IsWindowVisible(hwnd)) { StringBuilder cls=new StringBuilder(256); GetClassNameW(hwnd,cls,cls.Capacity); if(String.Equals(cls.ToString(),"EyeBreakReminder.Native",StringComparison.Ordinal)) found=hwnd; }
      return true;
    };
    EnumWindows(callback,IntPtr.Zero); GC.KeepAlive(callback); return found;
  }
  public static IntPtr FindChildById(IntPtr parent,int wantedId) {
    IntPtr found=IntPtr.Zero;
    EnumWindowsProc callback=delegate(IntPtr hwnd,IntPtr ignored) { if(GetDlgCtrlID(hwnd)==wantedId){found=hwnd;return false;} return true; };
    EnumChildWindows(parent,callback,IntPtr.Zero); GC.KeepAlive(callback); return found;
  }
  public static string ChildText(IntPtr parent,int id) { IntPtr child=FindChildById(parent,id); if(child==IntPtr.Zero)return ""; StringBuilder text=new StringBuilder(4096);GetWindowTextW(child,text,text.Capacity);return text.ToString(); }
  public static string WindowText(IntPtr hwnd) { StringBuilder text=new StringBuilder(4096);GetWindowTextW(hwnd,text,text.Capacity);return text.ToString(); }
  public static bool Responsive(IntPtr hwnd) { IntPtr ignored;return hwnd!=IntPtr.Zero&&SendMessageTimeoutW(hwnd,0,IntPtr.Zero,IntPtr.Zero,2|32,1500,out ignored)!=IntPtr.Zero; }
  public static bool RequestNormalExit(IntPtr hwnd) { uint message=RegisterWindowMessageW("EyeBreakReminder.Exit.Native.1");return message!=0&&PostMessageW(hwnd,message,IntPtr.Zero,IntPtr.Zero); }
}
'@
Add-Type -TypeDefinition $native -Language CSharp -ErrorAction Stop

function Get-Hash([string]$path){(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
function Click-Control([IntPtr]$window,[int]$controlId){$control=[EBR_DNS_GUI_NATIVE]::FindChildById($window,$controlId);if($control -eq [IntPtr]::Zero){throw "The isolated app did not expose control $controlId."};[void][EBR_DNS_GUI_NATIVE]::SendMessageW($control,0x00F5,[IntPtr]::Zero,[IntPtr]::Zero)}
function Get-TimerSeconds([IntPtr]$window){$text=[EBR_DNS_GUI_NATIVE]::ChildText($window,40);if($text -notmatch '^(\d+):(\d{2})$'){throw "Unexpected timer text '$text'."};return ([int]$Matches[1]*60+[int]$Matches[2])}
function Wait-AppWindow([Diagnostics.Process]$process,[int]$timeoutSeconds=30){$watch=[Diagnostics.Stopwatch]::StartNew();while($watch.Elapsed.TotalSeconds -lt $timeoutSeconds){$process.Refresh();if($process.HasExited){throw "The isolated app exited during startup with code $($process.ExitCode)."};$window=[EBR_DNS_GUI_NATIVE]::FindMainWindowByPid($process.Id);if($window -ne [IntPtr]::Zero -and [EBR_DNS_GUI_NATIVE]::Responsive($window)){return $window};Start-Sleep -Milliseconds 100};throw 'The isolated app did not expose a responsive native main window.'}
function Wait-UpdateResult([Diagnostics.Process]$process,[IntPtr]$window,[int]$timeoutSeconds=60){$watch=[Diagnostics.Stopwatch]::StartNew();$latest='';$status='';while($watch.Elapsed.TotalSeconds -lt $timeoutSeconds){$process.Refresh();if($process.HasExited){throw "The app exited while checking updates with code $($process.ExitCode)."};$latest=[EBR_DNS_GUI_NATIVE]::ChildText($window,163);$status=[EBR_DNS_GUI_NATIVE]::ChildText($window,162);$checking=$status -ceq 'Checking the official stable release on GitHub…';$failed=$latest -ceq 'Latest stable version: unavailable' -and $status.Contains('Could not reach GitHub');$succeeded=$latest -match '^Latest stable version: \d+\.\d+\.\d+' -and -not $checking;if($failed -or $succeeded){return [pscustomobject]@{Latest=$latest;Status=$status}};Start-Sleep -Milliseconds 100};throw "Timed out waiting for a completed update-check result; latest='$latest'; status='$status'."}
function Wait-TimerProgress([IntPtr]$window,[int]$initial,[int]$timeoutMilliseconds=8000){$watch=[Diagnostics.Stopwatch]::StartNew();while($watch.ElapsedMilliseconds -lt $timeoutMilliseconds){if((Get-TimerSeconds $window) -lt $initial){return $true};Start-Sleep -Milliseconds 100};return $false}
function Close-TestApp([Diagnostics.Process]$process,[IntPtr]$window){if($null -eq $process){return};$process.Refresh();if($process.HasExited){return};if(-not [EBR_DNS_GUI_NATIVE]::RequestNormalExit($window)){throw 'Could not request normal exit from the isolated DNS test app.'};if(-not $process.WaitForExit(10000)){throw 'The isolated DNS test app did not exit through its normal message.'};$process.Refresh();if($process.ExitCode -ne 0){throw "The isolated DNS test app exited with $($process.ExitCode)."};$process.Dispose()}

$script:assertions=0;$script:started=[DateTime]::UtcNow;$script:firstProcess=$null;$script:secondProcess=$null;$script:firstWindow=[IntPtr]::Zero;$script:secondWindow=[IntPtr]::Zero;$script:rootCreated=$false;$script:oldDataEnv=$env:EBR_GUI_TEST_DATA_DIRECTORY;$script:oldDnsEnv=$env:EBR_GUI_TEST_DNS_FAILURE
function Assert-That([bool]$passed,[string]$message){$script:assertions++;if(-not $passed){throw "DNS GUI assertion failed: $message"}}
try{
  [void][IO.Directory]::CreateDirectory($testRoot);$script:rootCreated=$true
  $install=Join-Path $testRoot 'install';$data=Join-Path $testRoot 'profile';[void][IO.Directory]::CreateDirectory($install);[void][IO.Directory]::CreateDirectory($data)
  $target=Join-Path $install 'EyeBreakReminder.exe';Copy-Item -LiteralPath $testApp -Destination $target
  $settingsPath=Join-Path $data 'settings.ini';$historyPath=Join-Path $data 'history.dat';$sentinelPath=Join-Path $data 'unrelated-sentinel.txt'
  $settings="workMinutes=47`nbreakSeconds=20`nvolume=32`ntheme=2`nalarm=0`nrepeat=0`nnotifications=0`nsnooze=0`nautoStart=1`nstartup=0`nhistory=1`ntray=0`nautoCheckUpdates=0`nautoDownloadUpdates=0`nupdateLastCheck=0`n"
  [IO.File]::WriteAllText($settingsPath,$settings,[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($historyPath,"$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()-120) 1 20`n",[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($sentinelPath,'dns-gui-sentinel',[Text.UTF8Encoding]::new($false))
  $appHash=Get-Hash $target;$settingsHash=Get-Hash $settingsPath;$historyHash=Get-Hash $historyPath;$sentinelHash=Get-Hash $sentinelPath

  $env:EBR_GUI_TEST_DATA_DIRECTORY=$data;$env:EBR_GUI_TEST_DNS_FAILURE='1'
  $script:firstProcess=Start-Process -FilePath $target -WorkingDirectory $install -PassThru
  Remove-Item Env:\EBR_GUI_TEST_DNS_FAILURE -ErrorAction SilentlyContinue
  $script:firstWindow=Wait-AppWindow $script:firstProcess
  Click-Control $script:firstWindow 12
  Click-Control $script:firstWindow 160
  $firstResult=Wait-UpdateResult $script:firstProcess $script:firstWindow
  Assert-That ($firstResult.Latest -ceq 'Latest stable version: unavailable' -and $firstResult.Status.Contains('Could not reach GitHub')) 'the actual application displays a recoverable DNS failure from its real WinHTTP request'
  Assert-That ([EBR_DNS_GUI_NATIVE]::Responsive($script:firstWindow)) 'the app window remains responsive after the DNS failure'
  Click-Control $script:firstWindow 10
  $timerInitial=Get-TimerSeconds $script:firstWindow
  Assert-That (Wait-TimerProgress $script:firstWindow $timerInitial) 'the running timer continues progressing after the DNS failure'
  Assert-That ((Get-Hash $target) -ceq $appHash -and (Get-Hash $settingsPath) -ceq $settingsHash -and (Get-Hash $historyPath) -ceq $historyHash -and (Get-Hash $sentinelPath) -ceq $sentinelHash) 'the DNS failure leaves the executable, settings, history and unrelated sentinel byte-identical'
  $updatesPath=Join-Path $data 'updates'
  Assert-That (-not(Test-Path -LiteralPath $updatesPath) -or @(Get-ChildItem -LiteralPath $updatesPath -Force).Count -eq 0) 'the DNS failure creates no update stage or installer payload'
  Close-TestApp $script:firstProcess $script:firstWindow;$script:firstProcess=$null;$script:firstWindow=[IntPtr]::Zero
  Assert-That (([IO.File]::ReadAllText($settingsPath)).Contains('updateLastCheck=0')) 'the failed check does not advance the last successful check time'

  $env:EBR_GUI_TEST_DATA_DIRECTORY=$data
  $script:secondProcess=Start-Process -FilePath $target -WorkingDirectory $install -PassThru
  $script:secondWindow=Wait-AppWindow $script:secondProcess
  Click-Control $script:secondWindow 12
  Click-Control $script:secondWindow 160
  $secondResult=Wait-UpdateResult $script:secondProcess $script:secondWindow
  Assert-That ($secondResult.Latest -match '^Latest stable version: \d+\.\d+\.\d+' -and -not $secondResult.Status.Contains('Could not reach GitHub')) 'a later real HTTPS retry to the official GitHub release API succeeds after the DNS override is removed'
  $settingsAfterRetry=[IO.File]::ReadAllText($settingsPath)
  Assert-That ($settingsAfterRetry.Contains('workMinutes=47') -and $settingsAfterRetry.Contains('volume=32') -and $settingsAfterRetry.Contains('autoStart=1') -and $settingsAfterRetry -match 'updateLastCheck=[1-9]\d*') 'the successful retry records its check time while preserving user preferences'
  Assert-That ((Get-Hash $historyPath) -ceq $historyHash -and (Get-Hash $sentinelPath) -ceq $sentinelHash -and (Get-Hash $target) -ceq $appHash) 'the successful retry also preserves application, history and unrelated files'
  Assert-That ([EBR_DNS_GUI_NATIVE]::Responsive($script:secondWindow)) 'the app remains responsive after the successful retry'
  $report=[ordered]@{Application='Eye Break Reminder';Scenario='Actual GUI DNS failure and successful retry after removing the test-only endpoint override';Status='PASS';Assertions=$script:assertions;InitialApplicationSHA256=$appHash;InitialSettingsSHA256=$settingsHash;HistorySHA256=$historyHash;DnsFailureLatest=$firstResult.Latest;DnsFailureStatus=$firstResult.Status;SuccessfulRetryLatest=$secondResult.Latest;SuccessfulRetryStatus=$secondResult.Status;SettingsPreserved=$true;HistoryPreserved=$true;ApplicationResponsive=$true;TimerAdvanced=$true;NoInstallerLaunched=$true;HostScope='Disposable GitHub Actions Windows runner';TestOnlyDnsOverride='eye-break-reminder-dns-test.invalid; compiled only with EYEBREAK_TEST_BUILD';ProductionEndpointOverride=false;ProductionTrustChanged=$false;HostRebooted=$false;UtcStarted=$script:started.ToString('o');UtcCompleted=[DateTime]::UtcNow.ToString('o')}
  [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($evidence));$report|ConvertTo-Json -Depth 7|Set-Content -LiteralPath $evidence -Encoding utf8;Write-Host ($report|ConvertTo-Json -Depth 6)
}catch{
  $failure=[ordered]@{Application='Eye Break Reminder';Scenario='Actual GUI DNS failure and retry';Status='FAIL';Failure=$_.Exception.ToString();Assertions=$script:assertions;HostScope='Disposable GitHub Actions Windows runner';ProductionTrustChanged=$false;HostRebooted=$false;UtcStarted=$script:started.ToString('o');UtcCompleted=[DateTime]::UtcNow.ToString('o')}
  [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($evidence));$failure|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $evidence -Encoding utf8;throw
}finally{
  if($null -ne $script:firstProcess){try{Close-TestApp $script:firstProcess $script:firstWindow}catch{Write-Warning "First isolated DNS app cleanup: $_"}}
  if($null -ne $script:secondProcess){try{Close-TestApp $script:secondProcess $script:secondWindow}catch{Write-Warning "Retry isolated DNS app cleanup: $_"}}
  if($null -eq $script:oldDataEnv){Remove-Item Env:\EBR_GUI_TEST_DATA_DIRECTORY -ErrorAction SilentlyContinue}else{$env:EBR_GUI_TEST_DATA_DIRECTORY=$script:oldDataEnv}
  if($null -eq $script:oldDnsEnv){Remove-Item Env:\EBR_GUI_TEST_DNS_FAILURE -ErrorAction SilentlyContinue}else{$env:EBR_GUI_TEST_DNS_FAILURE=$script:oldDnsEnv}
  if($script:rootCreated){$resolved=[IO.Path]::GetFullPath($testRoot);if($resolved.StartsWith($runnerPrefix,[StringComparison]::OrdinalIgnoreCase)-and (Test-Path -LiteralPath $resolved)){Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue}}
}
