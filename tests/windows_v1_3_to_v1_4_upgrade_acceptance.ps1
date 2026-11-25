param(
  [Parameter(Mandatory=$true)][string]$LegacyInstaller,
  [Parameter(Mandatory=$true)][string]$CandidateInstaller,
  [Parameter(Mandatory=$true)][string]$CandidateExecutable,
  [string]$EvidenceDirectory='build/v1.4.0-updater-evidence'
)
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS-ne'true'){throw 'The v1.3.0 upgrade acceptance may only use the disposable hosted Windows profile.'}
$runnerTemp=[IO.Path]::GetFullPath($env:RUNNER_TEMP);$testRoot=[IO.Path]::GetFullPath((Join-Path $runnerTemp ('EBR-v1.3-v1.4-transition-'+[guid]::NewGuid().ToString('N'))))
$installDir=Join-Path $testRoot 'install';$dataDir=[IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'EyeBreakReminder'))
$EvidenceDirectory=[IO.Path]::GetFullPath($EvidenceDirectory);$expectedEvidence=[IO.Path]::GetFullPath((Join-Path (Get-Location) 'build/v1.4.0-updater-evidence'))
if($EvidenceDirectory-ine$expectedEvidence){throw "Evidence must be in $expectedEvidence"}
foreach($file in @($LegacyInstaller,$CandidateInstaller,$CandidateExecutable)){if(-not(Test-Path -LiteralPath $file -PathType Leaf)){throw "Upgrade artifact is missing: $file"}}
if(Test-Path -LiteralPath $testRoot){throw "Refusing to reuse an existing isolated upgrade test directory: $testRoot"}
if(Test-Path -LiteralPath $dataDir){throw "Refusing to overwrite an existing Eye Break Reminder user profile in the hosted test account: $dataDir"}
[void][IO.Directory]::CreateDirectory($EvidenceDirectory);[void][IO.Directory]::CreateDirectory($testRoot)
$native=@'
using System;
using System.Runtime.InteropServices;
public static class EBR_LEGACY_UPGRADE_NATIVE {
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern uint RegisterWindowMessageW(string name);
 [DllImport("user32.dll",SetLastError=true)] public static extern bool PostMessageW(IntPtr hwnd,uint message,IntPtr wParam,IntPtr lParam);
}
'@
Add-Type -TypeDefinition $native -ErrorAction Stop
$events=[Collections.Generic.List[object]]::new();$assertions=0;$result='FAIL'
function Assert([bool]$ok,[string]$name,$details=$null){if(-not$ok){$events.Add([pscustomobject]@{Name=$name;Status='FAIL';Details=$details;Utc=[DateTime]::UtcNow.ToString('o')});throw "v1.3.0 to v1.4.0 upgrade failed: $name ($details)"};$script:assertions++;$script:events.Add([pscustomobject]@{Name=$name;Status='PASS';Details=$details;Utc=[DateTime]::UtcNow.ToString('o')})}
function Assert-StartMenuRegistration([string]$expectedTarget,[string]$phase){
  $expectedDirectory=Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Eye Break Reminder'
  $shortcutPath=Join-Path $expectedDirectory 'Eye Break Reminder.lnk'
  Assert (Test-Path -LiteralPath $shortcutPath -PathType Leaf) "$phase creates the shortcut at the exact per-user Start Menu path" $shortcutPath
  $shell=$null;$link=$null
  try{
    $shell=New-Object -ComObject WScript.Shell
    $link=$shell.CreateShortcut($shortcutPath)
    $actualTarget=[string]$link.TargetPath;$actualArguments=[string]$link.Arguments
    $targetMatches= -not[string]::IsNullOrWhiteSpace($actualTarget) -and [IO.Path]::GetFullPath($actualTarget)-ieq[IO.Path]::GetFullPath($expectedTarget)
    $argumentsMatch=[string]::IsNullOrEmpty($actualArguments)
    Assert ($targetMatches-and$argumentsMatch) "$phase shortcut targets the exact installed executable with no command-line arguments" ([pscustomobject]@{Path=$shortcutPath;ExpectedTarget=[IO.Path]::GetFullPath($expectedTarget);ActualTarget=$actualTarget;ExpectedArguments='';ActualArguments=$actualArguments})
  }finally{
    if($link){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($link)}
    if($shell){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)}
  }
}
try{
  Assert ((Get-Item -LiteralPath $LegacyInstaller).VersionInfo.ProductVersion-eq'1.3.0') 'downloaded official baseline installer has v1.3.0 product identity'
  Assert ((Get-Item -LiteralPath $CandidateInstaller).VersionInfo.ProductVersion-eq'1.4.0') 'candidate setup has v1.4.0 product identity'
  Assert ((Get-Item -LiteralPath $CandidateExecutable).VersionInfo.ProductVersion-eq'1.4.0') 'candidate standalone executable has v1.4.0 product identity'
  $legacyHash=(Get-FileHash -LiteralPath $LegacyInstaller -Algorithm SHA256).Hash.ToLowerInvariant();$candidateHash=(Get-FileHash -LiteralPath $CandidateInstaller -Algorithm SHA256).Hash.ToLowerInvariant();$candidateExeHash=(Get-FileHash -LiteralPath $CandidateExecutable -Algorithm SHA256).Hash.ToLowerInvariant()
  $old=Start-Process -FilePath ([IO.Path]::GetFullPath($LegacyInstaller)) -ArgumentList @('/S',"/D=$installDir") -PassThru -Wait
  Assert ($old.ExitCode-eq0-and(Test-Path -LiteralPath (Join-Path $installDir 'EyeBreakReminder.exe'))) 'real public v1.3.0 NSIS installer completes in a disposable per-user folder' $old.ExitCode
  Assert ((Get-Item -LiteralPath (Join-Path $installDir 'EyeBreakReminder.exe')).VersionInfo.ProductVersion-eq'1.3.0') 'installed baseline executable is v1.3.0'
  Assert-StartMenuRegistration (Join-Path $installDir 'EyeBreakReminder.exe') 'Fresh v1.3.0 install'
  $installKey=Get-ItemProperty -LiteralPath 'HKCU:\Software\EyeBreakReminder' -ErrorAction Stop;$uninstallKey=Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder' -ErrorAction Stop
  Assert ([IO.Path]::GetFullPath($installKey.InstallDir)-ieq[IO.Path]::GetFullPath($installDir)-and$uninstallKey.DisplayVersion-eq'1.3.0') 'v1.3.0 install registration points to the isolated path and Apps entry'
  [void][IO.Directory]::CreateDirectory($dataDir);$now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $settings=@('workMinutes=37','breakSeconds=33','volume=32','theme=2','alarm=0','repeat=1','notifications=0','snooze=0','autoStart=1','startup=0','history=1','breakModeColors=1','customWorkAccent=1','workAccentColor=3900150','customBreakAccent=1','breakAccentColor=16746496','futureLegacyFlag=opaque-value','autoCheckUpdates=0','autoDownloadUpdates=0','updateLastCheck=0','restore=1') -join "`n"
  $settingsPath=Join-Path $dataDir 'settings.ini';$timerPath=Join-Path $dataDir 'timer.dat';$historyPath=Join-Path $dataDir 'history.dat'
  [IO.File]::WriteAllText($settingsPath,$settings+"`n",[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($timerPath,"0 0 1200 1200 7 $now",[Text.UTF8Encoding]::new($false));$historyText="$($now-120) 1 20`n";[IO.File]::WriteAllText($historyPath,$historyText,[Text.UTF8Encoding]::new($false))
  $before=@{Settings=(Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash.ToLowerInvariant();Timer=(Get-FileHash -LiteralPath $timerPath -Algorithm SHA256).Hash.ToLowerInvariant();History=(Get-FileHash -LiteralPath $historyPath -Algorithm SHA256).Hash.ToLowerInvariant()}
  $upgrade=Start-Process -FilePath ([IO.Path]::GetFullPath($CandidateInstaller)) -ArgumentList '/S' -PassThru -Wait
  Assert ($upgrade.ExitCode-eq0) 'v1.4.0 NSIS installer upgrades the existing v1.3.0 path without a separate uninstall' $upgrade.ExitCode
  $app=Join-Path $installDir 'EyeBreakReminder.exe';Assert ((Get-Item -LiteralPath $app).VersionInfo.ProductVersion-eq'1.4.0') 'seamless upgrade installs the v1.4.0 application executable'
  Assert ((Get-FileHash -LiteralPath $app -Algorithm SHA256).Hash.ToLowerInvariant()-eq$candidateExeHash) 'installed executable is byte-identical to the candidate standalone binary'
  $installKey=Get-ItemProperty -LiteralPath 'HKCU:\Software\EyeBreakReminder' -ErrorAction Stop;$uninstallKey=Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder' -ErrorAction Stop
  Assert ([IO.Path]::GetFullPath($installKey.InstallDir)-ieq[IO.Path]::GetFullPath($installDir)-and$uninstallKey.DisplayVersion-eq'1.4.0'-and(Test-Path -LiteralPath (Join-Path $installDir 'Uninstall.exe'))) 'upgrade retains the installation identity and updates Installed Apps metadata'
  Assert ((Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash.ToLowerInvariant()-eq$before.Settings-and(Get-FileHash -LiteralPath $timerPath -Algorithm SHA256).Hash.ToLowerInvariant()-eq$before.Timer-and(Get-FileHash -LiteralPath $historyPath -Algorithm SHA256).Hash.ToLowerInvariant()-eq$before.History) 'installer preserves pre-existing v1.3.0 settings, timer checkpoint and history exactly'
  Assert-StartMenuRegistration $app 'In-place v1.4.0 upgrade'
  $appProcess=Start-Process -FilePath $app -PassThru;$watch=[Diagnostics.Stopwatch]::StartNew();while($watch.Elapsed.TotalSeconds-lt20-and-not$appProcess.HasExited){$appProcess.Refresh();if($appProcess.MainWindowHandle-ne[IntPtr]::Zero){break};Start-Sleep -Milliseconds 100};Assert (-not$appProcess.HasExited-and$appProcess.MainWindowHandle-ne[IntPtr]::Zero) 'upgraded v1.4.0 binary starts with the existing legacy profile';$quit=[EBR_LEGACY_UPGRADE_NATIVE]::RegisterWindowMessageW('EyeBreakReminder.Exit.Native.1');[void][EBR_LEGACY_UPGRADE_NATIVE]::PostMessageW($appProcess.MainWindowHandle,$quit,[IntPtr]::Zero,[IntPtr]::Zero);if(-not$appProcess.WaitForExit(15000)){throw 'Upgraded application did not exit through its own Exit message.'}
  $migrated=Get-Content -LiteralPath $settingsPath -Raw;Assert ($migrated-match'(?m)^workMinutes=37$'-and$migrated-match'(?m)^theme=2$'-and$migrated-match'(?m)^workAccentColor=3900150$'-and$migrated-match'(?m)^breakAccentColor=16746496$') 'v1.4.0 loads and rewrites legacy timer/theme/custom accent settings'
  $startupRunKey=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Run',$false)
  if($null-eq$startupRunKey){$startupRunValue=$null}else{try{$startupRunValue=$startupRunKey.GetValue('EyeBreakReminder',$null)}finally{$startupRunKey.Dispose()}}
  Assert ($migrated-match'(?m)^startup=0$'-and$null-eq$startupRunValue) 'upgraded profile keeps the disabled startup preference and has no Eye Break Reminder Run registration' ([pscustomobject]@{SettingsStartup='0';RunValue=$startupRunValue})
  Assert ($migrated-match'(?m)^futureLegacyFlag=opaque-value$') 'v1.4.0 preserves an unknown valid legacy setting during migration'
  Assert ((Get-FileHash -LiteralPath $historyPath -Algorithm SHA256).Hash.ToLowerInvariant()-eq$before.History) 'starting the upgraded application preserves statistics/history'
  $uninstall=Start-Process -FilePath (Join-Path $installDir 'Uninstall.exe') -ArgumentList '/S' -PassThru -Wait;Assert ($uninstall.ExitCode-eq0-and-not(Test-Path -LiteralPath $app)) 'upgraded v1.4.0 can be removed through the registered uninstaller'
  Assert ((Get-Content -LiteralPath $settingsPath -Raw)-match'(?m)^workMinutes=37$'-and(Get-FileHash -LiteralPath $historyPath -Algorithm SHA256).Hash.ToLowerInvariant()-eq$before.History) 'silent uninstall after the legacy upgrade keeps settings and history'
  $remaining=Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder' -ErrorAction SilentlyContinue;Assert (-not$remaining) 'uninstall removes the current Windows Apps registry entry'
  $result='PASS';$events.Add([pscustomobject]@{Name='Actual v1.3.0 to v1.4.0 installed upgrade';Status='PASS';Details=[pscustomobject]@{LegacyInstallerSHA256=$legacyHash;CandidateInstallerSHA256=$candidateHash;CandidateExecutableSHA256=$candidateExeHash;UpgradeExitCode=$upgrade.ExitCode;UninstallExitCode=$uninstall.ExitCode};Utc=[DateTime]::UtcNow.ToString('o')})
}catch{$events.Add([pscustomobject]@{Name='Actual v1.3.0 to v1.4.0 installed upgrade';Status='FAIL';Details=$_.Exception.ToString();Utc=[DateTime]::UtcNow.ToString('o')});throw}
finally{
  $app=Join-Path $installDir 'EyeBreakReminder.exe';$uninstaller=Join-Path $installDir 'Uninstall.exe';if(Test-Path -LiteralPath $uninstaller){try{$p=Start-Process -FilePath $uninstaller -ArgumentList '/S' -PassThru -Wait;if($p.ExitCode-ne0){$events.Add([pscustomobject]@{Name='Disposable cleanup uninstall';Status='FAIL';Details=$p.ExitCode})}}catch{}}
  if(Test-Path -LiteralPath $dataDir){$resolved=[IO.Path]::GetFullPath($dataDir);$expected=[IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'EyeBreakReminder'));if($resolved-ieq$expected){Remove-Item -LiteralPath $resolved -Recurse -Force}}
  Remove-Item -LiteralPath $installDir -Recurse -Force -ErrorAction SilentlyContinue;Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
  [pscustomobject]@{Status=$result;Assertions=$assertions;Events=@($events);Utc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'v1.3-to-v1.4-upgrade-results.json') -Encoding UTF8
}
