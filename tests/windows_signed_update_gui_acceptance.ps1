param(
  [Parameter(Mandatory=$true)][string]$TestApplication,
  [Parameter(Mandatory=$true)][string]$SuccessorInstaller,
  [Parameter(Mandatory=$true)][string]$SuccessorApplication,
  [Parameter(Mandatory=$true)][string]$SignatureTool,
  [string]$ProductionManifest,
  [string]$ProductionSignature,
  [ValidateSet('installed','portable')][string]$PackageKind = 'installed',
  [ValidateSet('preserve','clean-preserve-history','clean-delete-history')][string]$UpdateChoice = 'preserve',
  [ValidatePattern('^\d+\.\d+\.\d+$')][string]$BaselineVersion = '1.4.0',
  [ValidatePattern('^\d+\.\d+\.\d+$')][string]$UpdateVersion = '1.4.1',
  [string]$EvidencePath = 'build/v1.4.0-updater-evidence/signed-gui-update.json'
)

$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_OS -ne 'Windows' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') { throw 'Signed GUI update acceptance is restricted to a disposable GitHub Actions Windows runner.' }
if([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne [Runtime.InteropServices.Architecture]::X64) { throw 'Signed GUI update acceptance requires an x64 Windows runner.' }
if([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP) -or [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { throw 'The hosted runner test and user-profile paths are unavailable.' }

$portableMode=$PackageKind -ceq 'portable'
$cleanMode=$UpdateChoice -cne 'preserve';$deleteHistoryMode=$UpdateChoice -ceq 'clean-delete-history'
if($portableMode -and $cleanMode){throw 'Clean installation choices apply only to the installed package transaction.'}
$testRoot=[IO.Path]::GetFullPath((Join-Path $env:RUNNER_TEMP "EyeBreakReminder-v140-signed-gui-update-$PackageKind-$UpdateChoice"))
$runnerPrefix=[IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')+'\'
if(-not $testRoot.StartsWith($runnerPrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Resolved GUI test directory escaped RUNNER_TEMP.'}
if(Test-Path -LiteralPath $testRoot){throw "Refusing to reuse an existing signed GUI test directory: $testRoot"}
$localAppData=[IO.Path]::GetFullPath([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData))
if(-not $localAppData.Equals([IO.Path]::GetFullPath($env:LOCALAPPDATA),[StringComparison]::OrdinalIgnoreCase)){throw 'The runner LocalAppData identity does not match its profile environment.'}
$dataRoot=[IO.Path]::GetFullPath((Join-Path $localAppData 'EyeBreakReminder'))
if(Test-Path -LiteralPath $dataRoot){throw "Refusing to touch pre-existing application data on the hosted runner: $dataRoot"}
$appKey='HKCU:\Software\EyeBreakReminder';$uninstallKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder'
$runKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';$runOnceKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
if((Test-Path -LiteralPath $appKey) -or (Test-Path -LiteralPath $uninstallKey) -or
   (Get-ItemProperty -LiteralPath $runKey -Name EyeBreakReminder -ErrorAction SilentlyContinue) -or
   (Get-ItemProperty -LiteralPath $runOnceKey -Name '!EyeBreakReminderUpdateRecovery' -ErrorAction SilentlyContinue)) { throw 'Refusing to replace pre-existing Eye Break Reminder registry state on the hosted runner.' }
$testApp=[IO.Path]::GetFullPath($TestApplication);$setup=[IO.Path]::GetFullPath($SuccessorInstaller);$portable=[IO.Path]::GetFullPath($SuccessorApplication);$signer=[IO.Path]::GetFullPath($SignatureTool)
foreach($path in @($testApp,$setup,$portable,$signer)){if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "Required signed GUI update input is missing: $path"}}
$productionTrustMode=(-not[string]::IsNullOrWhiteSpace($ProductionManifest))-or(-not[string]::IsNullOrWhiteSpace($ProductionSignature))
if($productionTrustMode-and([string]::IsNullOrWhiteSpace($ProductionManifest)-or[string]::IsNullOrWhiteSpace($ProductionSignature))){throw 'Production trust mode requires both the authentic production manifest and signature.'}
if((Get-Item -LiteralPath $testApp).VersionInfo.ProductVersion -notmatch ('^'+[regex]::Escape($BaselineVersion)+'(\.0)?$') -or
   (Get-Item -LiteralPath $setup).VersionInfo.ProductVersion -notmatch ('^'+[regex]::Escape($UpdateVersion)+'(\.0)?$') -or
   (Get-Item -LiteralPath $portable).VersionInfo.ProductVersion -notmatch ('^'+[regex]::Escape($UpdateVersion)+'(\.0)?$')) { throw "The GUI update requires baseline $BaselineVersion and matching $UpdateVersion payloads." }
$productionManifestPath=$null;$productionSignaturePath=$null
if($productionTrustMode){
  $productionManifestPath=[IO.Path]::GetFullPath($ProductionManifest);$productionSignaturePath=[IO.Path]::GetFullPath($ProductionSignature)
  foreach($path in @($productionManifestPath,$productionSignaturePath)){if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "Required production update metadata is missing: $path"}}
}
$evidence=[IO.Path]::GetFullPath($EvidencePath);$evidenceRoot=[IO.Path]::GetFullPath((Join-Path (Get-Location) 'build/v1.4.0-updater-evidence'))
if(-not $evidence.StartsWith($evidenceRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Evidence must remain under build/v1.4.0-updater-evidence.'}

$native=@'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class EBR_SIGNED_GUI_NATIVE {
  public delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr data);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc callback, IntPtr data);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr hwnd, StringBuilder text, int count);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowTextW(IntPtr hwnd, StringBuilder text, int count);
  [DllImport("user32.dll", SetLastError=true)] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
  [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr hwnd, int id);
  [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr hwnd, uint message, IntPtr w, IntPtr l);
  [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr SendMessageTimeoutW(IntPtr hwnd, uint message, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr result);
  [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr hwnd, uint message, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr hwnd);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern uint GetModuleFileNameW(IntPtr module, StringBuilder text, int count);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);
  public static IntPtr FindWindowByClassAndPid(string expected, int wantedPid) {
    IntPtr found=IntPtr.Zero;
    EnumWindowsProc callback=delegate(IntPtr hwnd, IntPtr ignored) {
      uint pid=0; GetWindowThreadProcessId(hwnd,out pid);
      if((int)pid==wantedPid && IsWindowVisible(hwnd)) { StringBuilder name=new StringBuilder(256); GetClassNameW(hwnd,name,name.Capacity); if(String.Equals(name.ToString(),expected,StringComparison.Ordinal)) found=hwnd; }
      return true;
    };
    EnumWindows(callback,IntPtr.Zero); GC.KeepAlive(callback); return found;
  }
  public static string Text(IntPtr hwnd) { StringBuilder text=new StringBuilder(2048); GetWindowTextW(hwnd,text,text.Capacity); return text.ToString(); }
  public static string ChildText(IntPtr hwnd,int id) { IntPtr child=GetDlgItem(hwnd,id); return child==IntPtr.Zero?"":Text(child); }
  public static string ImagePath(IntPtr hwnd) { uint pid=0; GetWindowThreadProcessId(hwnd,out pid); try { using(var p=System.Diagnostics.Process.GetProcessById((int)pid)) return p.MainModule.FileName; } catch { return ""; } }
  public static string NativeExitCode(IntPtr process) { uint code; if(!GetExitCodeProcess(process,out code)) return "error:"+Marshal.GetLastWin32Error(); return code.ToString(System.Globalization.CultureInfo.InvariantCulture); }
  public static bool Responsive(IntPtr hwnd) { IntPtr ignored; return SendMessageTimeoutW(hwnd,0,IntPtr.Zero,IntPtr.Zero,2|32,1500,out ignored)!=IntPtr.Zero; }
  public static bool Click(IntPtr hwnd,int id) { IntPtr child=GetDlgItem(hwnd,id); if(child==IntPtr.Zero||!IsWindowEnabled(child))return false; SendMessageW(child,0x00F5,IntPtr.Zero,IntPtr.Zero); return true; }
  public static bool SetChecked(IntPtr hwnd,int id,bool value) { IntPtr child=GetDlgItem(hwnd,id); if(child==IntPtr.Zero||!IsWindowEnabled(child))return false; SendMessageW(child,0x00F1,(IntPtr)(value?1:0),IntPtr.Zero); return true; }
  public static bool IsChecked(IntPtr hwnd,int id) { IntPtr child=GetDlgItem(hwnd,id); return child!=IntPtr.Zero&&SendMessageW(child,0x00F0,IntPtr.Zero,IntPtr.Zero).ToInt64()==1; }
  public static void CloseCoordinator(IntPtr hwnd) { Click(hwnd,3); }
  public static void ExitApp(IntPtr hwnd) { uint quit=RegisterWindowMessageW("EyeBreakReminder.Exit.Native.1"); PostMessageW(hwnd,quit,IntPtr.Zero,IntPtr.Zero); }
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern uint RegisterWindowMessageW(string name);
}
'@
Add-Type -TypeDefinition $native -Language CSharp -ErrorAction Stop

function Assert-That([bool]$passed,[string]$message){$script:assertions++;if(-not $passed){throw "Signed GUI update assertion failed: $message"}}
function Get-Hash([string]$path){(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
function Get-TimerSeconds([IntPtr]$window){$text=[EBR_SIGNED_GUI_NATIVE]::ChildText($window,40);if($text -notmatch '^(\d+):(\d{2})$'){throw "Unexpected application timer text '$text'."};return ([int]$Matches[1]*60+[int]$Matches[2])}
function Wait-TimerProgress([IntPtr]$window,[int]$initial,[int]$timeoutMilliseconds=7000){$watch=[Diagnostics.Stopwatch]::StartNew();while($watch.ElapsedMilliseconds -lt $timeoutMilliseconds){if((Get-TimerSeconds $window) -lt $initial){return $true};Start-Sleep -Milliseconds 100};return $false}
function Wait-NoStagedUpdates([string]$updates,[int]$timeoutSeconds=20){$watch=[Diagnostics.Stopwatch]::StartNew();while($watch.Elapsed.TotalSeconds -lt $timeoutSeconds){if(-not(Test-Path -LiteralPath $updates) -or @(Get-ChildItem -LiteralPath $updates -Force).Count -eq 0){return $true};Start-Sleep -Milliseconds 100};return $false}
function Get-ModalFailureDiagnostics([Diagnostics.Process]$process){
  $mainWindow=[EBR_SIGNED_GUI_NATIVE]::FindWindowByClassAndPid('EyeBreakReminder.Native',$process.Id)
  $modalWindow=[EBR_SIGNED_GUI_NATIVE]::FindWindowByClassAndPid('#32770',$process.Id)
  $status='';$latest='';$modalHeading='';$modalBody='';$mainTitle=''
  if($mainWindow -ne [IntPtr]::Zero){
    $mainTitle=[EBR_SIGNED_GUI_NATIVE]::Text($mainWindow)
    $status=[EBR_SIGNED_GUI_NATIVE]::ChildText($mainWindow,162)
    $latest=[EBR_SIGNED_GUI_NATIVE]::ChildText($mainWindow,163)
  }
  if($modalWindow -ne [IntPtr]::Zero){
    $modalHeading=[EBR_SIGNED_GUI_NATIVE]::ChildText($modalWindow,12320)
    $modalBody=[EBR_SIGNED_GUI_NATIVE]::ChildText($modalWindow,12321)
  }
  $diagnosticPath=Join-Path (Split-Path -Parent $testApp) 'test-update-modal-diagnostic.txt'
  $modalDiagnostic=if(Test-Path -LiteralPath $diagnosticPath){[IO.File]::ReadAllText($diagnosticPath)}else{''}
  return [pscustomobject]@{
    ProcessId=$process.Id
    ProcessExited=$process.HasExited
    MainWindowFound=($mainWindow -ne [IntPtr]::Zero)
    MainWindowTitle=$mainTitle
    UpdateStatus=$status
    LatestVersionStatus=$latest
    ModalWindowFound=($modalWindow -ne [IntPtr]::Zero)
    ModalHeading=$modalHeading
    ModalBody=$modalBody
    TestOnlyModalDiagnostic=$modalDiagnostic
  }
}
function Wait-Modal([Diagnostics.Process]$process,[string]$heading,[int]$timeoutSeconds=90,[switch]$EnabledPrimary){
  $watch=[Diagnostics.Stopwatch]::StartNew()
  while($watch.Elapsed.TotalSeconds -lt $timeoutSeconds -and -not $process.HasExited){
    $window=[EBR_SIGNED_GUI_NATIVE]::FindWindowByClassAndPid('#32770',$process.Id)
    if($window -ne [IntPtr]::Zero -and [EBR_SIGNED_GUI_NATIVE]::ChildText($window,12320) -ceq $heading){
      $button=[EBR_SIGNED_GUI_NATIVE]::GetDlgItem($window,12001)
      if($heading -eq 'Clean Installation'){$button=[EBR_SIGNED_GUI_NATIVE]::GetDlgItem($window,12326)}
      if($button -ne [IntPtr]::Zero -and (-not $EnabledPrimary -or [EBR_SIGNED_GUI_NATIVE]::IsWindowEnabled($button))){return $window}
    }
    Start-Sleep -Milliseconds 100
    $process.Refresh()
  }
  $process.Refresh()
  $diagnostics=Get-ModalFailureDiagnostics $process
  throw "Timed out waiting for signed updater dialog '$heading'; diagnostics=$($diagnostics|ConvertTo-Json -Compress -Depth 4)"
}
function Wait-ReadyDownloadModal([Diagnostics.Process]$process,[int]$timeoutSeconds=120){
  $watch=[Diagnostics.Stopwatch]::StartNew()
  while($watch.Elapsed.TotalSeconds -lt $timeoutSeconds -and -not $process.HasExited){
    $window=[EBR_SIGNED_GUI_NATIVE]::FindWindowByClassAndPid('#32770',$process.Id)
    if($window -ne [IntPtr]::Zero -and [EBR_SIGNED_GUI_NATIVE]::ChildText($window,12320) -ceq 'Downloading Eye Break Reminder'){
      $body=[EBR_SIGNED_GUI_NATIVE]::ChildText($window,12321)
      $install=[EBR_SIGNED_GUI_NATIVE]::GetDlgItem($window,12001)
      if($body.Contains('The download is complete and its SHA-256 digest matches GitHub.') -and
         $install -ne [IntPtr]::Zero -and [EBR_SIGNED_GUI_NATIVE]::IsWindowEnabled($install)){
        return [pscustomobject]@{Window=$window;Body=$body}
      }
    }
    Start-Sleep -Milliseconds 100
    $process.Refresh()
  }
  $process.Refresh()
  $diagnostics=Get-ModalFailureDiagnostics $process
  throw "Timed out waiting for the verified signed download to become ready; diagnostics=$($diagnostics|ConvertTo-Json -Compress -Depth 4)"
}
function Wait-UpdateCoordinator([int]$timeoutSeconds=180){$watch=[Diagnostics.Stopwatch]::StartNew();$last='';while($watch.Elapsed.TotalSeconds -lt $timeoutSeconds){foreach($process in [Diagnostics.Process]::GetProcessesByName('coordinator')){try{$process.Refresh();if(-not $process.HasExited){$window=[EBR_SIGNED_GUI_NATIVE]::FindWindowByClassAndPid('EyeBreakReminder.UpdateCoordinator',$process.Id);if($window -ne [IntPtr]::Zero){$last=[EBR_SIGNED_GUI_NATIVE]::ChildText($window,1);if($last.Contains('Update complete.')){return [pscustomobject]@{Process=$process;Window=$window;Message=$last;ImagePath=[EBR_SIGNED_GUI_NATIVE]::ImagePath($window)}};$process.Dispose();break}}}catch{$process.Dispose()}};Start-Sleep -Milliseconds 100};throw "Timed out waiting for the real signed update coordinator; last status='$last'."}
function Wait-UpdatedApplication([string]$target,[int]$timeoutSeconds=40){$full=[IO.Path]::GetFullPath($target);$watch=[Diagnostics.Stopwatch]::StartNew();while($watch.Elapsed.TotalSeconds -lt $timeoutSeconds){foreach($process in [Diagnostics.Process]::GetProcessesByName('EyeBreakReminder')){try{$process.Refresh();if(-not $process.HasExited -and [IO.Path]::GetFullPath($process.Path) -ieq $full){$window=[EBR_SIGNED_GUI_NATIVE]::FindWindowByClassAndPid('EyeBreakReminder.Native',$process.Id);if($window -ne [IntPtr]::Zero -and [EBR_SIGNED_GUI_NATIVE]::Responsive($window)){return [pscustomobject]@{Process=$process;Window=$window}}}}catch{};$process.Dispose()};Start-Sleep -Milliseconds 100};throw 'The signed GUI update did not relaunch the installed successor application.'}
function Close-App($app){if($null -eq $app -or $app.Process.HasExited){return};[EBR_SIGNED_GUI_NATIVE]::ExitApp($app.Window);if(-not $app.Process.WaitForExit(10000)){throw 'The updated test application did not exit through its normal message.'};$app.Process.Dispose()}

$script:assertions=0;$script:started=[DateTime]::UtcNow;$script:app=$null;$script:coordinator=$null;$script:updatedApp=$null;$script:dataCreated=$false;$script:registered=$false
try{
  [void][IO.Directory]::CreateDirectory($testRoot);$targetDirectory=Join-Path $testRoot $PackageKind;[void][IO.Directory]::CreateDirectory($targetDirectory);$target=Join-Path $targetDirectory 'EyeBreakReminder.exe';Copy-Item -LiteralPath $testApp -Destination $target
  if(-not $portableMode){
    New-Item -Path $appKey -Force | Out-Null;New-ItemProperty -LiteralPath $appKey -Name InstallDir -PropertyType String -Value $targetDirectory -Force | Out-Null
    New-Item -Path $uninstallKey -Force | Out-Null;New-ItemProperty -LiteralPath $uninstallKey -Name DisplayVersion -PropertyType String -Value $BaselineVersion -Force | Out-Null;$script:registered=$true
  }elseif((Test-Path -LiteralPath $appKey) -or (Test-Path -LiteralPath $uninstallKey)){
    throw 'Portable production-trust transaction unexpectedly found installed-app registration.'
  }
  [void][IO.Directory]::CreateDirectory($dataRoot);$script:dataCreated=$true
  $settings="workMinutes=37`nbreakSeconds=33`nvolume=32`ntheme=2`nalarm=0`nrepeat=1`nnotifications=0`nsnooze=0`nautoStart=0`nstartup=0`nhistory=1`nautoCheckUpdates=1`nautoDownloadUpdates=1`nupdateLastCheck=0`n"
  $historyRecord="$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()-120) 1 20`n";$settingsPath=Join-Path $dataRoot 'settings.ini';$historyPath=Join-Path $dataRoot 'history.dat';$sentinelPath=Join-Path $dataRoot 'unrelated-sentinel.txt'
  [IO.File]::WriteAllText($settingsPath,$settings,[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($historyPath,$historyRecord,[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($sentinelPath,'signed-gui-sentinel',[Text.UTF8Encoding]::new($false))
  $historyHash=Get-Hash $historyPath;$sentinelHash=Get-Hash $sentinelPath
  if($productionTrustMode){
    Copy-Item -LiteralPath $productionManifestPath -Destination (Join-Path $targetDirectory 'EyeBreakReminder-UpdateManifest.json')
    Copy-Item -LiteralPath $productionSignaturePath -Destination (Join-Path $targetDirectory 'EyeBreakReminder-UpdateManifest.sig')
    if(Test-Path -LiteralPath (Join-Path $targetDirectory 'test-update-public-key.bin')){throw 'Production-trust integration must not have a test public key in the application directory.'}
    & $signer --verify-production-manifest (Join-Path $targetDirectory 'EyeBreakReminder-UpdateManifest.json') (Join-Path $targetDirectory 'EyeBreakReminder-UpdateManifest.sig') ('v'+$UpdateVersion) $BaselineVersion
    if($LASTEXITCODE -ne 0){throw 'Windows CNG did not authenticate the exact production update manifest against the embedded production key.'}
    $manifestObject=Get-Content -LiteralPath (Join-Path $targetDirectory 'EyeBreakReminder-UpdateManifest.json') -Raw|ConvertFrom-Json
    if($manifestObject.version-cne$UpdateVersion-or$manifestObject.key_id-cne'p256-0aff97759ea95258'){throw 'Production update metadata has an unexpected version or key identifier.'}
    $setupHash=Get-Hash $setup;$portableHash=Get-Hash $portable
    if($manifestObject.assets.Count-ne2-or$manifestObject.assets[0].name-cne'EyeBreakReminder-Setup-x64.exe'-or$manifestObject.assets[0].role-cne'installer'-or$manifestObject.assets[0].installation_type-cne'installed'-or$manifestObject.assets[0].architecture-cne'x64'-or[long]$manifestObject.assets[0].size-ne(Get-Item -LiteralPath $setup).Length-or$manifestObject.assets[0].sha256-cne$setupHash-or$manifestObject.assets[1].name-cne'EyeBreakReminder.exe'-or$manifestObject.assets[1].role-cne'portable-update'-or$manifestObject.assets[1].installation_type-cne'portable'-or$manifestObject.assets[1].architecture-cne'x64'-or[long]$manifestObject.assets[1].size-ne(Get-Item -LiteralPath $portable).Length-or$manifestObject.assets[1].sha256-cne$portableHash){throw 'The signed production manifest does not bind both exact candidate payloads to their intended roles and installation types.'}
    $testKeyDirectory=Join-Path $testRoot 'disposable-test-key-rejection';[void][IO.Directory]::CreateDirectory($testKeyDirectory)
    & $signer --sign-update-manifest $testKeyDirectory $setup $portable $UpdateVersion;if($LASTEXITCODE-ne0){throw 'Could not create the disposable test-key rejection fixture.'}
    $testManifestPath=Join-Path $testKeyDirectory 'EyeBreakReminder-UpdateManifest.json';$testManifest=Get-Content -LiteralPath $testManifestPath -Raw|ConvertFrom-Json
    $testPublicKeyPath=Join-Path $testKeyDirectory 'test-update-public-key.bin'
    if($testManifest.key_id-ceq'p256-0aff97759ea95258'-or-not(Test-Path -LiteralPath $testPublicKeyPath -PathType Leaf)){throw 'The rejection fixture did not use a separate disposable test verification key.'}
    & $signer --verify-production-manifest $testManifestPath (Join-Path $testKeyDirectory 'EyeBreakReminder-UpdateManifest.sig') ('v'+$UpdateVersion) $BaselineVersion 2>&1 | Out-Null
    $testKeyRejected=($LASTEXITCODE-ne0)
    Assert-That $testKeyRejected 'the production CNG trust configuration rejects a correctly signed manifest from a disposable test key'
    $metadataTrust='Embedded production verification key; no test public key file present'
  }else{
    & $signer --sign-update-manifest $targetDirectory $setup $portable $UpdateVersion;if($LASTEXITCODE -ne 0){throw 'The ephemeral CNG test key could not sign the controlled successor manifest.'}
    $metadataTrust='Ephemeral Windows CNG ECDSA P-256 test key'
  }
  $assetNames=@('EyeBreakReminder-Setup-x64.exe','EyeBreakReminder.exe','EyeBreakReminder-UpdateManifest.json','EyeBreakReminder-UpdateManifest.sig')
  $releaseAssets=@(foreach($name in $assetNames){$path=switch($name){'EyeBreakReminder-Setup-x64.exe'{$setup};'EyeBreakReminder.exe'{$portable};default{Join-Path $targetDirectory $name}};$item=Get-Item -LiteralPath $path;[pscustomobject]@{name=$name;browser_download_url="https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/download/v$UpdateVersion/$name";size=[long]$item.Length;digest=('sha256:'+ (Get-Hash $path))}})
  $release=[ordered]@{tag_name="v$UpdateVersion";html_url="https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/tag/v$UpdateVersion";draft=$false;prerelease=$false;body='Controlled signed Windows integration fixture';assets=$releaseAssets}
  [IO.File]::WriteAllText((Join-Path $targetDirectory 'test-update-response.txt'),($release|ConvertTo-Json -Depth 8 -Compress),[Text.UTF8Encoding]::new($false))
  $env:EBR_GUI_TEST_DATA_DIRECTORY=$dataRoot;$env:EBR_GUI_TEST_UPDATE_ASSET_PATH=if($portableMode){$portable}else{$setup}
  $process=Start-Process -FilePath $target -WorkingDirectory $targetDirectory -PassThru;$script:app=$process
  $download=Wait-ReadyDownloadModal $process
  Assert-That ($download.Body.Contains('Downloaded:') -and $download.Body.Contains('(100%)')) 'automatic signed update download completes and verifies its payload before presenting install choices'
  Assert-That ([EBR_SIGNED_GUI_NATIVE]::Click($download.Window,12001)) 'the completed signed download advances to the explicit installation choice'
  $choice=Wait-Modal $process 'Eye Break Reminder Update Available'
  Assert-That ([EBR_SIGNED_GUI_NATIVE]::ChildText($choice,12320) -ceq 'Eye Break Reminder Update Available') 'the app discovers the newer stable release and presents the authenticated update choice'
  Assert-That ([EBR_SIGNED_GUI_NATIVE]::ChildText($choice,12321).Contains('already been downloaded and verified')) 'automatic download completes and is authenticated before the user install prompt'
  if($cleanMode){
    Assert-That ([EBR_SIGNED_GUI_NATIVE]::Click($choice,12102)) 'the clean-install radio option can be selected for the production-signed update'
    Assert-That ([EBR_SIGNED_GUI_NATIVE]::IsChecked($choice,12102)) 'the clean-install option is selected before continuing'
  }else{
    Assert-That (-not [EBR_SIGNED_GUI_NATIVE]::IsChecked($choice,12102)) 'the default production update choice preserves settings'
  }
  Assert-That ([EBR_SIGNED_GUI_NATIVE]::Click($choice,12001)) 'the update choice starts the real verified download flow'
  if($cleanMode){
    $cleanConfirmation=Wait-Modal $process 'Clean Installation'
    $cleanBody=[EBR_SIGNED_GUI_NATIVE]::ChildText($cleanConfirmation,12321)
    Assert-That ($cleanBody.Contains('history and statistics will be preserved unless you select their removal')) 'clean-install confirmation explains the history-preservation default'
    if($deleteHistoryMode){
      Assert-That ([EBR_SIGNED_GUI_NATIVE]::Click($cleanConfirmation,12325)) 'the explicit history-deletion option can be selected'
      Assert-That ([EBR_SIGNED_GUI_NATIVE]::IsChecked($cleanConfirmation,12325)) 'history deletion is checked only after the explicit user choice'
    }else{
      Assert-That (-not [EBR_SIGNED_GUI_NATIVE]::IsChecked($cleanConfirmation,12325)) 'clean installation preserves history by default'
    }
    Assert-That ([EBR_SIGNED_GUI_NATIVE]::Click($cleanConfirmation,12326)) 'the clean-install choice is confirmed through the application dialog'
  }
  $script:coordinator=Wait-UpdateCoordinator
  Assert-That ($script:coordinator.Message.Contains('Update complete.')) 'the actual app-launched update coordinator reports success'
  $coordinatorHandle=$script:coordinator.Process.Handle
  Assert-That ($coordinatorHandle -ne [IntPtr]::Zero) 'the running signed update coordinator exposes a valid process handle for exit verification'
  [EBR_SIGNED_GUI_NATIVE]::CloseCoordinator($script:coordinator.Window)
  if(-not $script:coordinator.Process.WaitForExit(20000)){throw 'The completed signed update coordinator did not exit after its status was acknowledged.'};$script:coordinator.Process.Refresh()
  $coordinatorExit=$script:coordinator.Process.ExitCode
  $coordinatorNativeExit=[EBR_SIGNED_GUI_NATIVE]::NativeExitCode($coordinatorHandle)
  Assert-That ($coordinatorNativeExit -ceq '0') "the signed update coordinator exits successfully (managedExit='$coordinatorExit'; nativeExit='$coordinatorNativeExit'; pid=$($script:coordinator.Process.Id); image='$($script:coordinator.ImagePath)'; status='$($script:coordinator.Message)')"
  $script:coordinator.Process.Dispose();$script:coordinator=$null
  $script:updatedApp=Wait-UpdatedApplication $target
  $timerInitial=Get-TimerSeconds $script:updatedApp.Window
  if($cleanMode){
    Assert-That ([EBR_SIGNED_GUI_NATIVE]::ChildText($script:updatedApp.Window,41).StartsWith('Running') -and [EBR_SIGNED_GUI_NATIVE]::ChildText($script:updatedApp.Window,20) -ceq 'Pause') 'the clean install resets the seeded paused timer preference and starts with defaults'
  }else{
    Assert-That ([EBR_SIGNED_GUI_NATIVE]::ChildText($script:updatedApp.Window,41) -ceq 'Paused' -and [EBR_SIGNED_GUI_NATIVE]::ChildText($script:updatedApp.Window,20) -ceq 'Resume') 'the relaunched application respects the preserved disabled auto-start preference'
    Assert-That ([EBR_SIGNED_GUI_NATIVE]::Click($script:updatedApp.Window,20)) 'the relaunched signed successor can resume its timer normally'
  }
  Assert-That ((Get-Hash $target) -ceq (Get-Hash $portable) -and (Get-Item -LiteralPath $target).VersionInfo.ProductVersion -match ('^'+[regex]::Escape($UpdateVersion)+'(\.0)?$')) 'the updated application exactly matches the signed portable-application digest and successor version'
  Assert-That ([EBR_SIGNED_GUI_NATIVE]::Responsive($script:updatedApp.Window)) 'the relaunched signed successor application responds to the window message check'
  Assert-That (Wait-TimerProgress $script:updatedApp.Window $timerInitial) 'the relaunched signed successor timer continues to advance'
  $settingsAfter=[IO.File]::ReadAllText($settingsPath)
  if($cleanMode){
    Assert-That (-not $settingsAfter.Contains('workMinutes=37') -and -not $settingsAfter.Contains('volume=32') -and -not $settingsAfter.Contains('autoStart=0')) 'the production-signed clean install resets the deliberately seeded settings'
  }else{
    Assert-That ($settingsAfter.Contains('workMinutes=37') -and $settingsAfter.Contains('volume=32') -and $settingsAfter.Contains('autoStart=0')) 'the signed installed update preserves user settings, including the disabled auto-start choice'
  }
  if($deleteHistoryMode){
    $historyStillContainsSeed=Test-Path -LiteralPath $historyPath
    if($historyStillContainsSeed){$historyStillContainsSeed=([IO.File]::ReadAllText($historyPath)).Contains($historyRecord.Trim())}
    Assert-That (-not $historyStillContainsSeed) 'the production-signed clean install deletes seeded history only after explicit confirmation'
  }else{
    Assert-That ((Get-Hash $historyPath) -ceq $historyHash) 'the signed update preserves user history byte-for-byte under the selected policy'
  }
  Assert-That ((Get-Hash $sentinelPath) -ceq $sentinelHash) 'the signed installed update preserves unrelated user data'
  if($portableMode){
    Assert-That (-not(Test-Path -LiteralPath $appKey) -and -not(Test-Path -LiteralPath $uninstallKey)) 'the production-key portable update leaves Windows installed-app registration absent'
  }else{
    $version=(Get-ItemProperty -LiteralPath $uninstallKey -Name DisplayVersion).DisplayVersion
    Assert-That ([string]$version -ceq $UpdateVersion) 'Windows installed-app registration reports the successor version'
  }
  $updatesPath=Join-Path $dataRoot 'updates'
  Assert-That (Wait-NoStagedUpdates $updatesPath) 'the verified GUI transaction removes its completed staging directory'
  Assert-That (-not (Get-ItemProperty -LiteralPath $runOnceKey -Name '!EyeBreakReminderUpdateRecovery' -ErrorAction SilentlyContinue)) 'the verified GUI transaction clears temporary recovery registration'
  Close-App $script:updatedApp;$script:updatedApp=$null
  $metadata=Get-Content -LiteralPath (Join-Path $targetDirectory 'EyeBreakReminder-UpdateManifest.json') -Raw|ConvertFrom-Json
  $report=[ordered]@{Application='Eye Break Reminder';Scenario="Real $PackageKind GUI update ($UpdateChoice) through discovery, signed metadata, payload download, coordinator, and relaunch";InstallationType=$PackageKind;UpdateChoice=$UpdateChoice;CleanInstall=$cleanMode;DeleteHistory=$deleteHistoryMode;Status='PASS';Assertions=$script:assertions;InitialVersion=$BaselineVersion;UpdatedVersion=$UpdateVersion;Trust=$metadataTrust;KeyId=$metadata.key_id;TestKeyRejectedByProductionTrust=if($productionTrustMode){$testKeyRejected}else{$false};InitialApplicationSHA256=(Get-Hash $testApp);InstallerSHA256=(Get-Hash $setup);PortableSHA256=(Get-Hash $portable);UpdatedApplicationSHA256=(Get-Hash $target);ManifestSHA256=(Get-Hash (Join-Path $targetDirectory 'EyeBreakReminder-UpdateManifest.json'));SignatureSHA256=(Get-Hash (Join-Path $targetDirectory 'EyeBreakReminder-UpdateManifest.sig'));SettingsPreserved=(-not $cleanMode);HistoryPreserved=(-not $deleteHistoryMode);UnrelatedDataPreserved=$true;Relaunched=$true;TimerAdvanced=$true;HostScope='Disposable GitHub Actions Windows runner';ProductionKeyProvisioned=$productionTrustMode;AuthenticodeEstablished=$false;HostRebooted=$false;UtcStarted=$script:started.ToString('o');UtcCompleted=[DateTime]::UtcNow.ToString('o')}
  [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($evidence));$report|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $evidence -Encoding utf8;Write-Host ($report|ConvertTo-Json -Depth 7)
}catch{
  $failure=[ordered]@{Application='Eye Break Reminder';Scenario="Real signed $PackageKind GUI update ($UpdateChoice)";InstallationType=$PackageKind;UpdateChoice=$UpdateChoice;Status='FAIL';Failure=$_.Exception.ToString();Assertions=$script:assertions;HostScope='Disposable GitHub Actions Windows runner';ProductionTrustChanged=$false;HostRebooted=$false;UtcStarted=$script:started.ToString('o');UtcCompleted=[DateTime]::UtcNow.ToString('o')}
  [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($evidence));$failure|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $evidence -Encoding utf8;throw
}finally{
  if($null -ne $script:app){try{$script:app.Refresh();if(-not $script:app.HasExited){$window=[EBR_SIGNED_GUI_NATIVE]::FindWindowByClassAndPid('EyeBreakReminder.Native',$script:app.Id);if($window -ne [IntPtr]::Zero){[EBR_SIGNED_GUI_NATIVE]::ExitApp($window)};if(-not $script:app.WaitForExit(5000)){Stop-Process -Id $script:app.Id -Force -ErrorAction SilentlyContinue}}}catch{}finally{$script:app.Dispose()}}
  if($null -ne $script:updatedApp){try{if(-not $script:updatedApp.Process.HasExited){[EBR_SIGNED_GUI_NATIVE]::ExitApp($script:updatedApp.Window);if(-not $script:updatedApp.Process.WaitForExit(5000)){Stop-Process -Id $script:updatedApp.Process.Id -Force -ErrorAction SilentlyContinue}}}catch{}finally{$script:updatedApp.Process.Dispose()}}
  foreach($processName in @('EyeBreakReminder','coordinator')){foreach($process in [Diagnostics.Process]::GetProcessesByName($processName)){try{$process.Refresh();if(-not $process.HasExited){$path=[IO.Path]::GetFullPath($process.Path);if($path.StartsWith($testRoot,[StringComparison]::OrdinalIgnoreCase)){Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue}}}catch{}finally{$process.Dispose()}}}
  if($script:registered -and (Test-Path -LiteralPath (Join-Path $targetDirectory 'Uninstall.exe'))){try{$uninstall=Start-Process -FilePath (Join-Path $targetDirectory 'Uninstall.exe') -ArgumentList '/S' -PassThru -Wait;if($uninstall.ExitCode -ne 0){Write-Warning "Isolated GUI test uninstall returned $($uninstall.ExitCode)."}}catch{Write-Warning "Isolated GUI test uninstall cleanup failed: $_"}}
  if($script:registered){
    if(Test-Path -LiteralPath $appKey){Remove-Item -LiteralPath $appKey -Recurse -Force -ErrorAction SilentlyContinue}
    if(Test-Path -LiteralPath $uninstallKey){Remove-Item -LiteralPath $uninstallKey -Recurse -Force -ErrorAction SilentlyContinue}
  }
  if(Test-Path -LiteralPath $runOnceKey -PathType Container){Remove-ItemProperty -LiteralPath $runOnceKey -Name '!EyeBreakReminderUpdateRecovery' -ErrorAction SilentlyContinue}
  if($script:dataCreated -and (Test-Path -LiteralPath $dataRoot)){Remove-Item -LiteralPath $dataRoot -Recurse -Force -ErrorAction SilentlyContinue}
  if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue}
  Remove-Item Env:\EBR_GUI_TEST_DATA_DIRECTORY,Env:\EBR_GUI_TEST_UPDATE_ASSET_PATH -ErrorAction SilentlyContinue
}
