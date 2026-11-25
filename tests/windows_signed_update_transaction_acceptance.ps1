param(
  [Parameter(Mandatory=$true)][string]$TestApplication,
  [Parameter(Mandatory=$true)][string]$SuccessorInstaller,
  [Parameter(Mandatory=$true)][string]$SuccessorApplication,
  [Parameter(Mandatory=$true)][string]$SignatureTool,
  [string]$EvidencePath = 'build/v1.4.0-updater-evidence/signed-update-transactions.json'
)

$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_OS -ne 'Windows' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted'){throw 'Signed update integration transactions are restricted to a disposable GitHub Actions Windows runner.'}
if([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne [Runtime.InteropServices.Architecture]::X64){throw 'Signed update integration transactions require an x64 Windows runner.'}
if([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)){throw 'RUNNER_TEMP is unavailable; refusing to create disposable transaction state.'}

$runnerTemp=[IO.Path]::GetFullPath($env:RUNNER_TEMP)
$testRoot=[IO.Path]::GetFullPath((Join-Path $runnerTemp 'EyeBreakReminder-v140-signed-transactions'))
$runnerPrefix=$runnerTemp.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
if(-not $testRoot.StartsWith($runnerPrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Resolved signed transaction test directory escaped RUNNER_TEMP.'}
if(Test-Path -LiteralPath $testRoot){throw "Refusing to reuse an existing signed transaction test directory: $testRoot"}
$testApp=[IO.Path]::GetFullPath($TestApplication);$successorSetup=[IO.Path]::GetFullPath($SuccessorInstaller);$successorApp=[IO.Path]::GetFullPath($SuccessorApplication);$signer=[IO.Path]::GetFullPath($SignatureTool)
foreach($path in @($testApp,$successorSetup,$successorApp,$signer)){if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "Required isolated test input is missing: $path"}}
if((Get-Item -LiteralPath $testApp).VersionInfo.ProductVersion -notmatch '^1\.4\.0(\.0)?$'){throw 'The initial integration app is not v1.4.0.'}
if((Get-Item -LiteralPath $successorSetup).VersionInfo.ProductVersion -notmatch '^1\.4\.1(\.0)?$' -or (Get-Item -LiteralPath $successorApp).VersionInfo.ProductVersion -notmatch '^1\.4\.1(\.0)?$'){throw 'The signed test installer and portable payload must both be the controlled v1.4.1 test build.'}

$evidence=[IO.Path]::GetFullPath($EvidencePath);$evidenceRoot=[IO.Path]::GetFullPath((Join-Path (Get-Location) 'build/v1.4.0-updater-evidence'))
if(-not $evidence.StartsWith($evidenceRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Evidence must remain under build/v1.4.0-updater-evidence.'}
$localAppData=[IO.Path]::GetFullPath([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData))
$expectedLocalAppData=[IO.Path]::GetFullPath($env:LOCALAPPDATA)
if(-not $localAppData.Equals($expectedLocalAppData,[StringComparison]::OrdinalIgnoreCase)){throw 'The disposable runner LocalAppData identity did not match its profile environment.'}
$profile=[IO.Path]::GetFullPath((Join-Path $localAppData 'EyeBreakReminder'))
if(-not $profile.StartsWith($localAppData.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($profile) -cne 'EyeBreakReminder'){throw 'The resolved test data path is not the exact application-owned LocalAppData directory.'}
if(Test-Path -LiteralPath $profile){throw "Refusing to touch pre-existing application data on the hosted runner: $profile"}
$appKeyPath='HKCU:\Software\EyeBreakReminder';$uninstallKeyPath='HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder'
$runKeyPath='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';$runOnceKeyPath='HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
if((Test-Path -LiteralPath $appKeyPath) -or (Test-Path -LiteralPath $uninstallKeyPath) -or
   (Get-ItemProperty -LiteralPath $runKeyPath -Name EyeBreakReminder -ErrorAction SilentlyContinue) -or
   (Get-ItemProperty -LiteralPath $runOnceKeyPath -Name '!EyeBreakReminderUpdateRecovery' -ErrorAction SilentlyContinue)){
  throw 'Refusing to replace pre-existing Eye Break Reminder registry state on the hosted runner.'
}
$script:assertions=0;$script:dataRootCreated=$false

$native=@'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class EBR_SIGNED_UPDATE_NATIVE {
  public delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr data);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc callback, IntPtr data);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr hwnd, StringBuilder text, int count);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowTextW(IntPtr hwnd, StringBuilder text, int count);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr hwnd, int id);
  [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr hwnd, uint message, IntPtr w, IntPtr l);
  [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr SendMessageTimeoutW(IntPtr hwnd, uint message, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr result);
  [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr hwnd, uint message, IntPtr w, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern uint RegisterWindowMessageW(string name);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetDlgItemTextW(IntPtr hwnd, int id, StringBuilder text, int count);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
  public static IntPtr FindWindowByClassAndPid(string expected, int wantedPid) {
    IntPtr found=IntPtr.Zero;
    EnumWindowsProc callback=delegate(IntPtr hwnd, IntPtr ignored) {
      uint pid=0; GetWindowThreadProcessId(hwnd,out pid);
      if((int)pid==wantedPid && IsWindowVisible(hwnd)) {
        StringBuilder name=new StringBuilder(256); GetClassNameW(hwnd,name,name.Capacity);
        if(String.Equals(name.ToString(),expected,StringComparison.Ordinal)) found=hwnd;
      }
      return true;
    };
    EnumWindows(callback,IntPtr.Zero); GC.KeepAlive(callback); return found;
  }
  public static string Text(IntPtr hwnd) { StringBuilder text=new StringBuilder(2048); GetWindowTextW(hwnd,text,text.Capacity); return text.ToString(); }
  public static string ChildText(IntPtr hwnd,int id) { IntPtr child=GetDlgItem(hwnd,id); return child==IntPtr.Zero?"":Text(child); }
  public static string TimerText(IntPtr hwnd) { StringBuilder text=new StringBuilder(128); GetDlgItemTextW(hwnd,40,text,text.Capacity); return text.ToString(); }
  public static bool Responsive(IntPtr hwnd) { IntPtr ignored; return SendMessageTimeoutW(hwnd,0,IntPtr.Zero,IntPtr.Zero,2|32,1500,out ignored)!=IntPtr.Zero; }
  public static void CloseCoordinator(IntPtr hwnd) { IntPtr button=GetDlgItem(hwnd,3); if(button!=IntPtr.Zero) SendMessageW(button,0x00F5,IntPtr.Zero,IntPtr.Zero); }
  public static void ExitApp(IntPtr hwnd) { uint quit=RegisterWindowMessageW("EyeBreakReminder.Exit.Native.1"); PostMessageW(hwnd,quit,IntPtr.Zero,IntPtr.Zero); }
}
'@
Add-Type -TypeDefinition $native -Language CSharp -ErrorAction Stop

function Get-Hash([string]$path){(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
function Quote-Argument([string]$value){'"'+$value.Replace('"','\"')+'"'}
function Assert-That([bool]$passed,[string]$message){$script:assertions++;if(-not $passed){throw "Signed update transaction assertion failed: $message"}}
function Get-TimerSeconds([IntPtr]$window){$text=[EBR_SIGNED_UPDATE_NATIVE]::TimerText($window);if($text -notmatch '^(\d+):(\d{2})$'){throw "Unexpected relaunch timer text '$text'."};return ([int]$Matches[1]*60+[int]$Matches[2])}
function Wait-TimerProgress([IntPtr]$window,[int]$initial,[int]$timeoutMilliseconds=7000){$watch=[Diagnostics.Stopwatch]::StartNew();while($watch.ElapsedMilliseconds -lt $timeoutMilliseconds){if((Get-TimerSeconds $window) -lt $initial){return $true};Start-Sleep -Milliseconds 100};return $false}
function Wait-NoStagedUpdates([string]$updates,[int]$timeoutSeconds=20){$watch=[Diagnostics.Stopwatch]::StartNew();while($watch.Elapsed.TotalSeconds -lt $timeoutSeconds){if(-not(Test-Path -LiteralPath $updates) -or @(Get-ChildItem -LiteralPath $updates -Force).Count -eq 0){return $true};Start-Sleep -Milliseconds 100};return $false}
function Set-DisposableRegistration([string]$directory){
  New-Item -Force -Path 'HKCU:\Software\EyeBreakReminder' | Out-Null
  New-ItemProperty -LiteralPath 'HKCU:\Software\EyeBreakReminder' -Name InstallDir -PropertyType String -Value $directory -Force | Out-Null
  New-Item -Force -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder' | Out-Null
  New-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder' -Name DisplayVersion -PropertyType String -Value '1.4.0' -Force | Out-Null
}
function Wait-CoordinatorMessage([Diagnostics.Process]$process,[string]$expected,[int]$timeoutSeconds=180){
  $watch=[Diagnostics.Stopwatch]::StartNew();$last=''
  while($watch.Elapsed.TotalSeconds -lt $timeoutSeconds -and -not $process.HasExited){
    $window=[EBR_SIGNED_UPDATE_NATIVE]::FindWindowByClassAndPid('EyeBreakReminder.UpdateCoordinator',$process.Id)
    if($window -ne [IntPtr]::Zero){$last=[EBR_SIGNED_UPDATE_NATIVE]::ChildText($window,1);if($last.Contains($expected)){return [pscustomobject]@{Window=$window;Message=$last}}}
    Start-Sleep -Milliseconds 100;$process.Refresh()
  }
  throw "Timed out waiting for signed update coordinator status '$expected'; exited=$($process.HasExited); last='$last'."
}
function Wait-UpdatedApp([string]$path,[int]$timeoutSeconds=30){
  $full=[IO.Path]::GetFullPath($path);$watch=[Diagnostics.Stopwatch]::StartNew()
  while($watch.Elapsed.TotalSeconds -lt $timeoutSeconds){
    foreach($process in [Diagnostics.Process]::GetProcessesByName('EyeBreakReminder')){
      try{$process.Refresh();if(-not $process.HasExited -and [IO.Path]::GetFullPath($process.Path) -ieq $full){$window=[EBR_SIGNED_UPDATE_NATIVE]::FindWindowByClassAndPid('EyeBreakReminder.Native',$process.Id);if($window -ne [IntPtr]::Zero -and [EBR_SIGNED_UPDATE_NATIVE]::Responsive($window)){return [pscustomobject]@{Process=$process;Window=$window}}}}catch{}
      $process.Dispose()
    }
    Start-Sleep -Milliseconds 100
  }
  throw "The signed update did not relaunch a responsive v1.4.1 application from '$full'."
}
function Close-UpdatedApp($app){
  if($null -eq $app -or $app.Process.HasExited){return $true}
  [EBR_SIGNED_UPDATE_NATIVE]::ExitApp($app.Window)
  $closed=$app.Process.WaitForExit(10000);$app.Process.Refresh()
  return $closed
}
function Assert-PreferenceState([string]$settingsPath,[bool]$clean){
  if(-not(Test-Path -LiteralPath $settingsPath)){if($clean){return $true};throw 'The settings file disappeared during preserve-settings update.'}
  $settings=[IO.File]::ReadAllText($settingsPath)
  if($clean){if($settings.Contains('workMinutes=37') -or $settings.Contains('volume=32') -or $settings.Contains('theme=2')){throw 'A clean installation retained old preferences.'}}
  elseif(-not($settings.Contains('workMinutes=37') -and $settings.Contains('volume=32') -and $settings.Contains('theme=2'))){throw 'The signed update did not preserve the selected settings.'}
  return $true
}

$script:results=[Collections.Generic.List[object]]::new();$script:errors=[Collections.Generic.List[string]]::new();$script:runStarted=[DateTime]::UtcNow
try{
  [void][IO.Directory]::CreateDirectory($testRoot)
  $scenarios=@(
    [pscustomobject]@{Name='PortablePreserve';Kind='portable';Clean=$false;DeleteHistory=$false},
    [pscustomobject]@{Name='InstalledPreserve';Kind='installed';Clean=$false;DeleteHistory=$false},
    [pscustomobject]@{Name='InstalledCleanKeepHistory';Kind='installed';Clean=$true;DeleteHistory=$false},
    [pscustomobject]@{Name='InstalledCleanDeleteHistory';Kind='installed';Clean=$true;DeleteHistory=$true}
  )
  foreach($scenario in $scenarios){
    if(Test-Path -LiteralPath $profile){throw "Application data remained between isolated scenarios: $profile"}
    $scenarioRoot=Join-Path $testRoot $scenario.Name;[void][IO.Directory]::CreateDirectory($scenarioRoot)
    [void][IO.Directory]::CreateDirectory($profile);$script:dataRootCreated=$true;$updates=Join-Path $profile 'updates';[void][IO.Directory]::CreateDirectory($updates)
    $settingsPath=Join-Path $profile 'settings.ini';$historyPath=Join-Path $profile 'history.dat';$sentinelPath=Join-Path $profile 'unrelated-sentinel.txt'
    $settings="workMinutes=37`nbreakSeconds=33`nvolume=32`ntheme=2`nalarm=0`nrepeat=1`nnotifications=0`nsnooze=0`nautoStart=1`nstartup=0`nhistory=1`n"
    [IO.File]::WriteAllText($settingsPath,$settings,[Text.UTF8Encoding]::new($false));$historyRecord="$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()-120) 1 20`n"
    [IO.File]::WriteAllText($historyPath,$historyRecord,[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($sentinelPath,'unrelated-profile-sentinel',[Text.UTF8Encoding]::new($false))
    $historyHash=Get-Hash $historyPath;$sentinelHash=Get-Hash $sentinelPath
    if($scenario.Kind -eq 'installed'){$targetDirectory=Join-Path $scenarioRoot 'installed';Set-DisposableRegistration $targetDirectory}else{$targetDirectory=Join-Path $scenarioRoot 'portable';if(Test-Path -LiteralPath 'HKCU:\Software\EyeBreakReminder'){throw 'Portable test found leftover installed-app registration.'}}
    [void][IO.Directory]::CreateDirectory($targetDirectory);$target=Join-Path $targetDirectory 'EyeBreakReminder.exe';Copy-Item -LiteralPath $testApp -Destination $target
    $stage=Join-Path $updates ([guid]::NewGuid().ToString('D'));[void][IO.Directory]::CreateDirectory($stage)
    $coordinator=Join-Path $stage 'coordinator.exe';Copy-Item -LiteralPath $testApp -Destination $coordinator
    $setup=Join-Path $stage 'EyeBreakReminder-Setup-x64.exe';$portable=Join-Path $stage 'EyeBreakReminder.exe'
    Copy-Item -LiteralPath $successorSetup -Destination $setup;Copy-Item -LiteralPath $successorApp -Destination $portable
    & $signer --sign-update-manifest $stage $setup $portable
    if($LASTEXITCODE -ne 0){throw "CNG test-key manifest signing failed for $($scenario.Name)."}
    $manifest=Get-Content -LiteralPath (Join-Path $stage 'EyeBreakReminder-UpdateManifest.json') -Raw | ConvertFrom-Json
    $selected=if($scenario.Kind -eq 'installed'){$setup}else{$portable};$assetName=if($scenario.Kind -eq 'installed'){'EyeBreakReminder-Setup-x64.exe'}else{'EyeBreakReminder.exe'}
    $nonce=[guid]::NewGuid().ToString('D');$previousHash=Get-Hash $target;$selectedHash=Get-Hash $selected;$setupHash=Get-Hash $setup;$portableHash=Get-Hash $portable
    $values=[ordered]@{
      staging=$stage;artifact=$selected;target=$target;data=$profile;version='1.4.1';previous='1.4.0';nonce=$nonce
      kind=$scenario.Kind;name=$assetName;sha256=$selectedHash;applicationSha256=$portableHash;previousSha256=$previousHash;size=(Get-Item -LiteralPath $selected).Length
      backupMask=0;ownedFileMask=0;pid=4294967295;clean=[int]$scenario.Clean;deleteHistory=[int]$scenario.DeleteHistory
      dark=0;forcedColors=0;previousStartup=0;backupSha2560='';backupSha2561='';backupSha2562='';ownedFileSha2560='';ownedFileSha2561='';ownedFileSha2562='';ownedFileSha2563=''
    }
    $transaction=Join-Path $stage 'transaction.ini';$transactionText=($values.GetEnumerator()|ForEach-Object{'{0}={1}' -f $_.Key,$_.Value}) -join "`n";[IO.File]::WriteAllText($transaction,$transactionText+"`n",[Text.UTF8Encoding]::new($false))
    $env:EBR_GUI_TEST_DATA_DIRECTORY=$profile
    $proc=Start-Process -FilePath $coordinator -ArgumentList @('--update-coordinator',(Quote-Argument $transaction)) -WorkingDirectory $stage -PassThru
    $completion=Wait-CoordinatorMessage $proc 'Update complete.' 180
    [EBR_SIGNED_UPDATE_NATIVE]::CloseCoordinator($completion.Window)
    if(-not $proc.WaitForExit(20000)){throw "The signed $($scenario.Name) coordinator did not exit after completion was acknowledged."};$proc.Refresh()
    if($proc.ExitCode -ne 0){throw "The signed $($scenario.Name) coordinator returned $($proc.ExitCode)."}
    Assert-That ((Get-Hash $target) -ceq $portableHash -and (Get-Item -LiteralPath $target).VersionInfo.ProductVersion -match '^1\.4\.1(\.0)?$') "$($scenario.Name): installed executable exactly matches the signed portable application digest and version"
    $app=Wait-UpdatedApp $target
    $timerInitial=Get-TimerSeconds $app.Window
    Assert-That ([EBR_SIGNED_UPDATE_NATIVE]::Responsive($app.Window)) "$($scenario.Name): relaunch created a responsive v1.4.1 application window"
    $timerAdvanced=Wait-TimerProgress $app.Window $timerInitial
    Assert-That $timerAdvanced "$($scenario.Name): the relaunched application's timer continues to advance (initial=$timerInitial current=$(Get-TimerSeconds $app.Window))"
    Assert-That (Assert-PreferenceState $settingsPath $scenario.Clean) "$($scenario.Name): settings match the selected preserve or clean-install policy"
    $historyPresent=Test-Path -LiteralPath $historyPath
    if($scenario.DeleteHistory){Assert-That (-not $historyPresent -or -not (Get-Content -LiteralPath $historyPath -Raw).Contains($historyRecord.Trim())) "$($scenario.Name): explicit history deletion removes the old session"}
    else{Assert-That ($historyPresent -and (Get-Hash $historyPath) -ceq $historyHash) "$($scenario.Name): signed update preserves history byte-for-byte"}
    Assert-That ((Get-Hash $sentinelPath) -ceq $sentinelHash) "$($scenario.Name): unrelated data remains unchanged"
    if($scenario.Kind -eq 'installed'){
      $version=(Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder' -Name DisplayVersion).DisplayVersion
      Assert-That ([string]$version -ceq '1.4.1') "$($scenario.Name): installed-app registration reports 1.4.1"
    }else{Assert-That (-not(Test-Path -LiteralPath $appKeyPath) -and -not(Test-Path -LiteralPath $uninstallKeyPath)) "$($scenario.Name): portable updating does not create installed-app registration"}
    Assert-That ($completion.Message.Contains('Update complete.')) "$($scenario.Name): verified update coordinator reports successful completion"
    Assert-That (Wait-NoStagedUpdates $updates) "$($scenario.Name): startup cleanup removes the completed update staging directory"
    Assert-That (-not (Get-ItemProperty -LiteralPath $runOnceKeyPath -Name '!EyeBreakReminderUpdateRecovery' -ErrorAction SilentlyContinue)) "$($scenario.Name): completed transaction removes the recovery registration"
    if(-not (Close-UpdatedApp $app)){throw "The updated $($scenario.Name) application did not close through its normal exit message."}
    $app.Process.Dispose();$proc.Dispose()
    $script:results.Add([pscustomobject]@{Scenario=$scenario.Name;Status='PASS';Kind=$scenario.Kind;Clean=$scenario.Clean;DeleteHistory=$scenario.DeleteHistory;TestKeyId=$manifest.key_id;InitialApplicationSHA256=$previousHash;AuthorizedInstallerSHA256=$setupHash;AuthorizedPortableSHA256=$portableHash;InstalledApplicationSHA256=(Get-Hash $target);SettingsPreserved=(-not $scenario.Clean);HistoryPreserved=(-not $scenario.DeleteHistory);ApplicationRelaunched=$true;TimerAdvanced=$true;TestTrust='Disposable CNG ECDSA P-256 key; production trust unchanged'})
    if($scenario.Kind -eq 'installed'){$uninstaller=Join-Path $targetDirectory 'Uninstall.exe';if(Test-Path -LiteralPath $uninstaller){$uninstall=Start-Process -FilePath $uninstaller -ArgumentList '/S' -PassThru -Wait;if($uninstall.ExitCode -ne 0){throw "Isolated test installation cleanup returned $($uninstall.ExitCode)."}}}
    if(Test-Path -LiteralPath $appKeyPath){Remove-Item -LiteralPath $appKeyPath -Recurse -Force}
    if(Test-Path -LiteralPath $uninstallKeyPath){Remove-Item -LiteralPath $uninstallKeyPath -Recurse -Force}
    if(Test-Path -LiteralPath $runOnceKeyPath -PathType Container){Remove-ItemProperty -LiteralPath $runOnceKeyPath -Name '!EyeBreakReminderUpdateRecovery' -ErrorAction SilentlyContinue}
    Remove-Item -LiteralPath $profile -Recurse -Force;$script:dataRootCreated=$false
  }
  $report=[ordered]@{Application='Eye Break Reminder';Version='1.4.0 test integration build to controlled 1.4.1 test integration build';Status='PASS';Assertions=$script:assertions;TestTrust='Ephemeral Windows CNG P-256 signing keys; only public test keys written to isolated update stages; never production trust';Scenarios=$script:results.ToArray();TestRoot=$testRoot;HostScope='Disposable GitHub Actions Windows runner';ProductionKeyProvisioned=$false;AuthenticodeEstablished=$false;HostRebooted=$false;UtcStarted=$script:runStarted.ToString('o');UtcCompleted=[DateTime]::UtcNow.ToString('o')}
  [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($evidence));$report|ConvertTo-Json -Depth 9|Set-Content -LiteralPath $evidence -Encoding utf8;Write-Host ($report|ConvertTo-Json -Depth 8)
}catch{
  $failure=[ordered]@{Application='Eye Break Reminder';Version='1.4.0 test integration build';Status='FAIL';Failure=$_.Exception.ToString();Scenarios=$script:results.ToArray();TestTrust='Disposable CNG test key only';TestRoot=$testRoot;HostScope='Disposable GitHub Actions Windows runner';HostRebooted=$false;UtcStarted=$script:runStarted.ToString('o');UtcCompleted=[DateTime]::UtcNow.ToString('o')}
  [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($evidence));$failure|ConvertTo-Json -Depth 9|Set-Content -LiteralPath $evidence -Encoding utf8;throw
}finally{
  foreach($process in [Diagnostics.Process]::GetProcessesByName('EyeBreakReminder')){try{$path=[IO.Path]::GetFullPath($process.Path);if($path.StartsWith($testRoot,[StringComparison]::OrdinalIgnoreCase)){ $window=[EBR_SIGNED_UPDATE_NATIVE]::FindWindowByClassAndPid('EyeBreakReminder.Native',$process.Id);if($window -ne [IntPtr]::Zero){[EBR_SIGNED_UPDATE_NATIVE]::ExitApp($window)};if(-not $process.WaitForExit(7000)){Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue}}}catch{}finally{$process.Dispose()}}
  foreach($process in [Diagnostics.Process]::GetProcessesByName('EyeBreakReminder')){try{$path=[IO.Path]::GetFullPath($process.Path);if($path.StartsWith($testRoot,[StringComparison]::OrdinalIgnoreCase)){Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue}}catch{}finally{$process.Dispose()}}
  if(Test-Path -LiteralPath 'HKCU:\Software\EyeBreakReminder'){Remove-Item -LiteralPath 'HKCU:\Software\EyeBreakReminder' -Recurse -Force -ErrorAction SilentlyContinue}
  if(Test-Path -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder'){Remove-Item -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder' -Recurse -Force -ErrorAction SilentlyContinue}
  if(Test-Path -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce\!EyeBreakReminderUpdateRecovery'){Remove-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name '!EyeBreakReminderUpdateRecovery' -ErrorAction SilentlyContinue}
  if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue}
  if($script:dataRootCreated -and (Test-Path -LiteralPath $profile)){Remove-Item -LiteralPath $profile -Recurse -Force -ErrorAction SilentlyContinue}
  Remove-Item Env:\EBR_GUI_TEST_DATA_DIRECTORY -ErrorAction SilentlyContinue
}
