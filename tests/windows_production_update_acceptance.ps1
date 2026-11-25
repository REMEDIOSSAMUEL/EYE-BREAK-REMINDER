param(
  [Parameter(Mandatory=$true)][string]$CandidateInstaller,
  [Parameter(Mandatory=$true)][string]$CandidateExecutable,
  [Parameter(Mandatory=$true)][string]$ControlledInstaller,
  [Parameter(Mandatory=$true)][string]$ControlledExecutable,
  [string]$CoordinatorFailureInstaller,
  [string]$LaunchSentinelExecutable,
  [string]$ProductionManifest,
  [string]$ProductionSignature,
  [ValidateSet('installed','portable')][string]$PackageKind = 'installed',
  [string]$EvidenceDirectory = 'build/v1.4.0-updater-evidence',
  [ValidateSet('All','CoordinatorBackupFailure','SignedPreserve')][string]$Scenario = 'All'
)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true') { throw 'This production-binary update transaction runs only on a disposable GitHub Actions Windows runner.' }

$candidateInstallerPath = [IO.Path]::GetFullPath($CandidateInstaller)
$candidateExecutablePath = [IO.Path]::GetFullPath($CandidateExecutable)
$controlledInstallerPath = [IO.Path]::GetFullPath($ControlledInstaller)
$controlledExecutablePath = [IO.Path]::GetFullPath($ControlledExecutable)
$coordinatorFailureInstallerPath = if ([string]::IsNullOrWhiteSpace($CoordinatorFailureInstaller)) { $null } else { [IO.Path]::GetFullPath($CoordinatorFailureInstaller) }
$feedSetupPath = $controlledInstallerPath
if ($Scenario -eq 'CoordinatorBackupFailure') {
  if (-not $coordinatorFailureInstallerPath -or -not (Test-Path -LiteralPath $coordinatorFailureInstallerPath -PathType Leaf)) { throw 'CoordinatorBackupFailure requires the isolated test-only controlled failing-installer fixture.' }
  if ((Get-Item -LiteralPath $coordinatorFailureInstallerPath).VersionInfo.ProductVersion -notmatch '^1\.4\.1(\.0)?$') { throw 'Coordinator failure fixture must identify as controlled version 1.4.1.' }
  $feedSetupPath = $coordinatorFailureInstallerPath
} elseif ($coordinatorFailureInstallerPath) { throw 'The test-only failure installer is accepted only by the CoordinatorBackupFailure scenario.' }
$signedPreserve = $Scenario -eq 'SignedPreserve'
$portableRoute = $PackageKind -eq 'portable'
$requiredPaths = @($candidateInstallerPath, $candidateExecutablePath, $controlledInstallerPath, $controlledExecutablePath)
if ($signedPreserve) {
  $ProductionManifest = [IO.Path]::GetFullPath($ProductionManifest)
  $ProductionSignature = [IO.Path]::GetFullPath($ProductionSignature)
  $requiredPaths += @($ProductionManifest, $ProductionSignature)
} else {
  if ($ProductionManifest -or $ProductionSignature -or $portableRoute) { throw 'Signed metadata and the portable route require SignedPreserve.' }
  $launchSentinelPath = [IO.Path]::GetFullPath($LaunchSentinelExecutable)
  $requiredPaths += $launchSentinelPath
}
foreach ($path in $requiredPaths) {
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required production-update transaction input is missing: $path" }
}
$runnerTemp = [IO.Path]::GetFullPath($env:RUNNER_TEMP)
$testRoot = [IO.Path]::GetFullPath((Join-Path $runnerTemp 'EyeBreakReminder-Production-Update-Acceptance'))
$runnerPrefix = $runnerTemp.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if (-not $testRoot.StartsWith($runnerPrefix,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $testRoot)) { throw 'Production update transaction requires a new isolated RUNNER_TEMP directory.' }
$installDir = Join-Path $testRoot 'install'
$dataDir = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'EyeBreakReminder'))
$expectedDataDir = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'EyeBreakReminder'))
$runKeyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$startupValueAdded = $false
$runKeyCreated = $false
$startupCommand = $null
$EvidenceDirectory = [IO.Path]::GetFullPath($EvidenceDirectory)
$evidenceRoot = if ($signedPreserve) { 'build/v1.4.1-updater-evidence' } else { 'build/v1.4.0-updater-evidence' }
$allowedEvidence = [IO.Path]::GetFullPath((Join-Path (Get-Location) $evidenceRoot))
if ($EvidenceDirectory -ine $allowedEvidence) { throw "Evidence path must be the isolated build folder: $allowedEvidence" }
if ($dataDir -ine $expectedDataDir -or (Test-Path -LiteralPath $dataDir)) { throw "Refusing to use an existing or unexpected app-data profile: $dataDir" }
if (Test-Path -LiteralPath $installDir) { throw "Refusing to reuse an install folder: $installDir" }
foreach ($path in @($candidateExecutablePath,$candidateInstallerPath)) {
  if ((Get-Item -LiteralPath $path).VersionInfo.ProductVersion -notmatch '^1\.4\.0(\.0)?$') { throw "Candidate file is not version 1.4.0: $path" }
}
foreach ($path in @($controlledExecutablePath,$controlledInstallerPath)) {
  if ((Get-Item -LiteralPath $path).VersionInfo.ProductVersion -notmatch '^1\.4\.1(\.0)?$') { throw "Controlled successor file is not version 1.4.1: $path" }
}

$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'The disposable runner did not provide the administrator rights needed for temporary hosts-file routing.' }
[void][IO.Directory]::CreateDirectory($EvidenceDirectory)
[void][IO.Directory]::CreateDirectory($testRoot)
$script:events = [Collections.Generic.List[object]]::new()
$script:assertions = 0
$startedUtc = [DateTime]::UtcNow
$hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$originalHostsBytes = [IO.File]::ReadAllBytes($hostsPath)
$originalHostsText = [Text.Encoding]::ASCII.GetString($originalHostsBytes)
$hostsChanged = $false
$rootThumbprint = $null
$serverProcess = $null
$originalInstallerLaunchMarker = $env:EBR_TEST_INSTALLER_LAUNCH_MARKER
$appProcess = $null
$setupExitCode = $null
$uninstallExitCode = $null
$transcriptPath = Join-Path $EvidenceDirectory 'production-update-acceptance.log'
Start-Transcript -LiteralPath $transcriptPath -Force | Out-Null

$native = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public struct EBR_PROD_RECT { public int Left,Top,Right,Bottom; }
public static class EBR_PROD_UI {
 public delegate bool EnumProc(IntPtr hwnd,IntPtr data);
 [DllImport("user32.dll",SetLastError=true)] static extern bool EnumWindows(EnumProc callback,IntPtr data);
 [DllImport("user32.dll",SetLastError=true)] public static extern uint GetWindowThreadProcessId(IntPtr hwnd,out uint pid);
 [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern int GetWindowTextW(IntPtr hwnd,StringBuilder text,int count);
 [DllImport("user32.dll",SetLastError=true)] public static extern bool IsWindowVisible(IntPtr hwnd);
 [DllImport("user32.dll",SetLastError=true)] public static extern bool GetWindowRect(IntPtr hwnd,out EBR_PROD_RECT rect);
 [DllImport("user32.dll",SetLastError=true)] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll",SetLastError=true)] public static extern bool SetForegroundWindow(IntPtr hwnd);
 [DllImport("user32.dll",SetLastError=true)] public static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll",SetLastError=true)] public static extern void mouse_event(uint flags,uint dx,uint dy,uint data,UIntPtr extra);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern uint RegisterWindowMessageW(string name);
 [DllImport("user32.dll",SetLastError=true)] public static extern bool PostMessageW(IntPtr hwnd,uint message,IntPtr wp,IntPtr lp);
 public static string Title(IntPtr hwnd){var text=new StringBuilder(512);GetWindowTextW(hwnd,text,text.Capacity);return text.ToString();}
 public static IntPtr[] Windows(int pid){var list=new List<IntPtr>();EnumProc cb=delegate(IntPtr hwnd,IntPtr data){uint owner;GetWindowThreadProcessId(hwnd,out owner);if(owner==(uint)pid&&IsWindowVisible(hwnd))list.Add(hwnd);return true;};EnumWindows(cb,IntPtr.Zero);GC.KeepAlive(cb);return list.ToArray();}
 public static IntPtr[] WindowsAll(){var list=new List<IntPtr>();EnumProc cb=delegate(IntPtr hwnd,IntPtr data){if(IsWindowVisible(hwnd))list.Add(hwnd);return true;};EnumWindows(cb,IntPtr.Zero);GC.KeepAlive(cb);return list.ToArray();}
 [DllImport("user32.dll")] static extern IntPtr GetDlgItem(IntPtr hwnd, int id);
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr SendMessageW(IntPtr hwnd, uint msg, IntPtr wp, StringBuilder text);
 [DllImport("user32.dll")] public static extern uint GetGuiResources(IntPtr process, uint flag);
 public static string Countdown(IntPtr hwnd) {
   var child=GetDlgItem(hwnd,40);
   var text=new StringBuilder(64);
   if(child!=IntPtr.Zero)SendMessageW(child,0x000D,(IntPtr)text.Capacity,text);
   return text.ToString();
 }
 public static bool ExitWindow(IntPtr hwnd){uint message=RegisterWindowMessageW("EyeBreakReminder.Exit.Native.1");return PostMessageW(hwnd,message,IntPtr.Zero,IntPtr.Zero);}
}
'@
Add-Type -TypeDefinition $native -ErrorAction Stop
Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
Add-Type -AssemblyName System.Drawing -ErrorAction Stop

function Record([string]$Name,[string]$Status,$Details=$null) { $entry=[pscustomobject]@{Name=$Name;Status=$Status;Details=$Details;Utc=[DateTime]::UtcNow.ToString('o')};$script:events.Add($entry);Write-Host ('EBR_UPDATE_EVENT '+($entry|ConvertTo-Json -Depth 10 -Compress)) }
function Assert([bool]$Ok,[string]$Name,$Details=$null) { if(-not $Ok){Record $Name 'FAIL' $Details;throw "Production updater acceptance failed: $Name ($Details)"};$script:assertions++;Record $Name 'PASS' $Details }
function Read-SettingsMap([string]$Path) { $map=@{};foreach($line in Get-Content -LiteralPath $Path){$separator=$line.IndexOf('=');if($separator-gt0){$map[$line.Substring(0,$separator)]=$line.Substring($separator+1)}};return $map }
function Get-UiaNames($Root) { $names=[Collections.Generic.List[string]]::new();try{if($Root.Current.Name){$names.Add($Root.Current.Name)}}catch{};try{$all=$Root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition);foreach($item in $all){try{if($item.Current.Name){$names.Add($item.Current.Name)}}catch{}}}catch{};return $names.ToArray() }
function Find-Dialog([string]$Marker,[int]$ProcessId=0,[int]$TimeoutSeconds=120) {
  # The main application window can expose the requested text through its
  # accessible descendants (for example, an About-page status label). Update
  # workflow checks must bind to the native modal's own top-level caption so
  # that a matching child in the owner window cannot masquerade as the dialog.
  $expectedWindowTitle=$null
  if($Marker-in@('Eye Break Reminder Update Available','Downloading Eye Break Reminder','Ready to install.','Update complete.')){$expectedWindowTitle='Eye Break Reminder Update'}
  $watch=[Diagnostics.Stopwatch]::StartNew()
  while($watch.Elapsed.TotalSeconds-lt$TimeoutSeconds){
    $handles=if($ProcessId){[EBR_PROD_UI]::Windows($ProcessId)}else{[EBR_PROD_UI]::WindowsAll()}
    foreach($hwnd in $handles){try{$title=[EBR_PROD_UI]::Title($hwnd);if($expectedWindowTitle-and$title-cne$expectedWindowTitle){continue};$root=[System.Windows.Automation.AutomationElement]::FromHandle($hwnd);$names=@(Get-UiaNames $root);if((($names -join "`n")+"`n"+$title).Contains($Marker)){Record 'Matched native updater UI window' 'INFO' ([pscustomobject]@{Marker=$Marker;WindowTitle=$title;RootName=$root.Current.Name;ProcessId=$ProcessId;WindowHandle=$hwnd.ToInt64();Names=$names});return [pscustomobject]@{Handle=$hwnd;Root=$root;Names=$names;WindowTitle=$title}}}catch{}}
    Start-Sleep -Milliseconds 100
  }
  $snapshot=@()
  $diagnosticHandles=if($ProcessId){[EBR_PROD_UI]::Windows($ProcessId)}else{[EBR_PROD_UI]::WindowsAll()}
  foreach($hwnd in $diagnosticHandles){try{$title=[EBR_PROD_UI]::Title($hwnd);$root=[System.Windows.Automation.AutomationElement]::FromHandle($hwnd);$items=$root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition);$controls=@($items|ForEach-Object{try{[pscustomobject]@{Type=$_.Current.ControlType.ProgrammaticName;Name=$_.Current.Name;Offscreen=$_.Current.IsOffscreen;Enabled=$_.Current.IsEnabled;NativeHandle=$_.Current.NativeWindowHandle}}catch{}});$snapshot+=,[pscustomobject]@{WindowTitle=$title;RootName=$root.Current.Name;Controls=$controls}}catch{}}
  throw "Timed out waiting for actual application UI text '$Marker'. Visible UIA snapshot: $(ConvertTo-Json $snapshot -Depth 8 -Compress)"
}
function Find-Button($Dialog,[string]$Name) {
  $items=$Dialog.Root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
  foreach($item in $items){try{if($item.Current.Name-ceq$Name-and($item.Current.ControlType-eq[System.Windows.Automation.ControlType]::Button-or$item.Current.ControlType-eq[System.Windows.Automation.ControlType]::RadioButton)){return $item}}catch{}}
  $observed=@($items|ForEach-Object{try{"$($_.Current.ControlType.ProgrammaticName):$($_.Current.Name)"}catch{}}|Where-Object{$_}) -join ' | '
  throw "The production update UI did not expose the '$Name' button or tab. Observed controls: $observed"
}
function Invoke-Button($Dialog,[string]$Name) {
  $button=Find-Button $Dialog $Name;$pattern=$null
  if($button.Current.ControlType-eq[System.Windows.Automation.ControlType]::RadioButton){
    if(-not$button.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern,[ref]$pattern)){throw "The production update tab '$Name' has no accessible SelectionItem action."}
    $pattern.Select();return
  }
  if(-not$button.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern,[ref]$pattern)){throw "The production update button '$Name' has no accessible Invoke action."}
  $pattern.Invoke()
}
function Save-Screenshot($Dialog,[string]$Name) {
  [void][EBR_PROD_UI]::SetForegroundWindow($Dialog.Handle);Start-Sleep -Milliseconds 150
  $rect=[EBR_PROD_RECT]::new();if(-not[EBR_PROD_UI]::GetWindowRect($Dialog.Handle,[ref]$rect)){throw 'Could not read production update dialog bounds.'}
  $width=$rect.Right-$rect.Left;$height=$rect.Bottom-$rect.Top;if($width-lt100-or$height-lt80){throw 'Production update dialog has unusable screenshot bounds.'}
  $bitmap=[Drawing.Bitmap]::new($width,$height);$graphics=[Drawing.Graphics]::FromImage($bitmap)
  try{$graphics.CopyFromScreen($rect.Left,$rect.Top,0,0,[Drawing.Size]::new($width,$height));$bitmap.Save((Join-Path $EvidenceDirectory $Name),[Drawing.Imaging.ImageFormat]::Png)}finally{$graphics.Dispose();$bitmap.Dispose()}
}
function Stop-ProductionApplication {
  if($script:appProcess){try{$script:appProcess.Refresh()}catch{}}
  foreach($process in @(Get-CimInstance Win32_Process -Filter "Name='EyeBreakReminder.exe'" -ErrorAction SilentlyContinue)){
    if(-not$process.ExecutablePath){continue}
    if(-not([IO.Path]::GetFullPath([string]$process.ExecutablePath).StartsWith($installDir.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase))){continue}
    foreach($hwnd in [EBR_PROD_UI]::Windows([int]$process.ProcessId)){[void][EBR_PROD_UI]::ExitWindow($hwnd)}
  }
  $watch=[Diagnostics.Stopwatch]::StartNew()
  while($watch.Elapsed.TotalSeconds-lt15){
    $remaining=@(Get-CimInstance Win32_Process -Filter "Name='EyeBreakReminder.exe'" -ErrorAction SilentlyContinue|Where-Object{
      $_.ExecutablePath -and ([IO.Path]::GetFullPath([string]$_.ExecutablePath).StartsWith($installDir.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase))
    })
    if(-not$remaining.Count){return}
    Start-Sleep -Milliseconds 100
  }
  throw 'The production candidate application did not exit through its registered safe-shutdown message.'
}
function Add-Check($Executable,[string[]]$Arguments,[string]$Description){& $Executable @Arguments;if($LASTEXITCODE-ne0){throw "$Description failed with exit code $LASTEXITCODE."}}
# Root-store work is isolated in a child PowerShell process so a stalled
# CryptoAPI/certificate service cannot strand the entire hosted acceptance job.
# This script requires the disposable hosted runner's administrator token;
# the test root is installed only in that runner's machine store and removed
# only after byte-for-byte identity verification.
function Invoke-TemporaryRootStoreOperation([string]$Operation,[string]$Thumbprint,[string]$CertificatePath=$null,[byte[]]$ExpectedCertificateBytes=$null,[int]$TimeoutSeconds=60) {
  if($script:certificateStoreWorkerStuck){throw 'The previous certificate-store worker could not be confirmed stopped; refusing to start a concurrent trust-store worker.'}
  $workerPath=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'windows_certificate_store_worker.ps1'))
  if(-not(Test-Path -LiteralPath $workerPath -PathType Leaf)){throw "The bounded certificate-store worker is missing: $workerPath"}
  $id=[guid]::NewGuid().ToString('N')
  $resultPath=Join-Path $testRoot ("certificate-store-$id.json")
  $workerArgs=@('-NoLogo','-NoProfile','-NonInteractive','-File',$workerPath,'-Operation',$Operation,'-Thumbprint',$Thumbprint,'-ResultPath',$resultPath)
  if($CertificatePath){$workerArgs+=@('-CertificatePath',[IO.Path]::GetFullPath($CertificatePath))}
  if($ExpectedCertificateBytes){$workerArgs+=@('-ExpectedCertificateBase64',[Convert]::ToBase64String($ExpectedCertificateBytes))}
  $startInfo=[Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName=Join-Path $PSHOME 'pwsh.exe'
  $startInfo.UseShellExecute=$false
  $startInfo.CreateNoWindow=$true
  $startInfo.RedirectStandardOutput=$true
  $startInfo.RedirectStandardError=$true
  foreach($argument in $workerArgs){[void]$startInfo.ArgumentList.Add([string]$argument)}
  $process=$null
  try {
    $process=[Diagnostics.Process]::Start($startInfo)
    $stdoutTask=$process.StandardOutput.ReadToEndAsync()
    $stderrTask=$process.StandardError.ReadToEndAsync()
    if(-not$process.WaitForExit($TimeoutSeconds*1000)){
      try{$process.Kill($true)}catch{try{$process.Kill()}catch{}}
      $workerStopped=$false
      try{$workerStopped=$process.WaitForExit(5000)}catch{}
      if(-not$workerStopped){$script:certificateStoreWorkerStuck=$true;throw "The certificate-store worker remained alive after its $TimeoutSeconds-second bound and termination request; concurrent trust-store cleanup is refused."}
      throw "Windows isolated-runner machine root-store $Operation operation exceeded its $TimeoutSeconds-second bound."
    }
    [void]$process.WaitForExit(5000)
    $stdout=$stdoutTask.GetAwaiter().GetResult()
    $stderr=$stderrTask.GetAwaiter().GetResult()
    Write-Host ('EBR_CERTSTORE_EVENT '+([pscustomobject]@{Operation=$Operation;ExitCode=$process.ExitCode;Stdout=$stdout;Stderr=$stderr}|ConvertTo-Json -Depth 4 -Compress))
    if($process.ExitCode-ne0){throw "Windows isolated-runner machine root-store $Operation operation failed with exit code $($process.ExitCode). $stderr $stdout"}
    if(-not(Test-Path -LiteralPath $resultPath -PathType Leaf)){throw "The certificate-store worker did not produce its result for $Operation."}
    $result=Get-Content -LiteralPath $resultPath -Raw|ConvertFrom-Json
    if(-not$result.Success){throw "The certificate-store worker rejected $Operation`: $($result.Error)"}
    return $result
  } finally {
    if($process){$process.Dispose()}
    Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue
  }
}
function Get-TemporaryRootCertificate([string]$Thumbprint) {
  return Invoke-TemporaryRootStoreOperation 'Inspect' $Thumbprint
}
function Add-TemporaryRootCertificate([string]$CertificatePath,[string]$Thumbprint) {
  $certificate=[Security.Cryptography.X509Certificates.X509Certificate2]::new([IO.File]::ReadAllBytes($CertificatePath))
  try {
    if($certificate.Thumbprint-cne$Thumbprint){throw 'The temporary root certificate bytes do not match their recorded thumbprint.'}
    $script:temporaryRootCertificateRawData=$certificate.RawData
  } finally {$certificate.Dispose()}
  $result=Invoke-TemporaryRootStoreOperation 'Add' $Thumbprint $CertificatePath
  $script:temporaryRootCertificateAdded=$true
  return $result
}
function Remove-TemporaryRootCertificate([string]$Thumbprint,[byte[]]$ExpectedCertificateBytes) {
  $result=Invoke-TemporaryRootStoreOperation 'Remove' $Thumbprint $null $ExpectedCertificateBytes
  $script:temporaryRootCertificateAdded=$false
  return [bool]$result.Removed
}

$resultStatus='FAIL'
$hostsRestoreStatus='NOT RUN'
$trustRootCleanupStatus='NOT RUN'
$serverStopped=$true
$requestLogName=if($Scenario-eq'CoordinatorBackupFailure'){'production-update-feed-requests-coordinator-backup-failure.jsonl'}else{'production-update-feed-requests.jsonl'}
$requestLogPath=Join-Path $EvidenceDirectory $requestLogName
if(Test-Path -LiteralPath $requestLogPath){throw "The production updater evidence request log already exists for scenario '$Scenario'; refusing to reuse stale feed evidence: $requestLogPath"}
$serverStdout=Join-Path $EvidenceDirectory 'production-update-feed.stdout.log'
$serverStderr=Join-Path $EvidenceDirectory 'production-update-feed.stderr.log'
$rootCertificatePath=Join-Path $testRoot 'test-root.cer'
$temporaryRootCertificate=$null
$script:temporaryRootCertificateRawData=$null
$script:temporaryRootCertificateAdded=$false
$script:certificateStoreWorkerStuck=$false
$rootPrivateKeyPath=Join-Path $testRoot 'test-root.key'
$rootPemPath=Join-Path $testRoot 'test-root.pem'
$leafCsrPath=Join-Path $testRoot 'server.csr'
$leafPrivateKeyPath=Join-Path $testRoot 'server.key'
$leafCertificatePath=Join-Path $testRoot 'server.pem'
$leafExtensionPath=Join-Path $testRoot 'server.ext'
$wrongLeafCsrPath=Join-Path $testRoot 'wrong-host.csr'
$wrongLeafCertificatePath=Join-Path $testRoot 'wrong-host.pem'
$wrongLeafExtensionPath=Join-Path $testRoot 'wrong-host.ext'
$readyPath=Join-Path $testRoot 'feed-ready.txt'
$wrongReadyPath=Join-Path $testRoot 'wrong-host-feed-ready.txt'
$redirectMarkerPath=Join-Path $testRoot 'redirect-setup-once.marker'

try {
  Write-Host "EBR_UPDATE_STAGE begin production binary transaction run=$env:GITHUB_RUN_ID commit=$env:GITHUB_SHA"
  if ($originalHostsText -match '(?im)^\s*(127\.0\.0\.1|::1)\s+.*\b(api\.github\.com|github\.com|unexpected-updates\.example\.invalid)\b') { throw 'The hosted runner already has a controlled update-feed hostname loopback mapping; refusing to replace it.' }
  if (Test-Path -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder') { throw 'The disposable hosted profile already contains an Eye Break Reminder uninstall registration.' }
  Record 'Input identities' 'INFO' ([pscustomobject]@{
    CandidateExecutable=[pscustomobject]@{Path=$candidateExecutablePath;Version=(Get-Item $candidateExecutablePath).VersionInfo.ProductVersion;Bytes=(Get-Item $candidateExecutablePath).Length;SHA256=(Get-FileHash $candidateExecutablePath -Algorithm SHA256).Hash.ToLowerInvariant()}
    CandidateInstaller=[pscustomobject]@{Path=$candidateInstallerPath;Version=(Get-Item $candidateInstallerPath).VersionInfo.ProductVersion;Bytes=(Get-Item $candidateInstallerPath).Length;SHA256=(Get-FileHash $candidateInstallerPath -Algorithm SHA256).Hash.ToLowerInvariant()}
    ControlledExecutable=[pscustomobject]@{Path=$controlledExecutablePath;Version=(Get-Item $controlledExecutablePath).VersionInfo.ProductVersion;Bytes=(Get-Item $controlledExecutablePath).Length;SHA256=(Get-FileHash $controlledExecutablePath -Algorithm SHA256).Hash.ToLowerInvariant()}
    ControlledInstaller=[pscustomobject]@{Path=$controlledInstallerPath;Version=(Get-Item $controlledInstallerPath).VersionInfo.ProductVersion;Bytes=(Get-Item $controlledInstallerPath).Length;SHA256=(Get-FileHash $controlledInstallerPath -Algorithm SHA256).Hash.ToLowerInvariant()}
    FeedSetup=[pscustomobject]@{Path=$feedSetupPath;Version=(Get-Item $feedSetupPath).VersionInfo.ProductVersion;Bytes=(Get-Item $feedSetupPath).Length;SHA256=(Get-FileHash $feedSetupPath -Algorithm SHA256).Hash.ToLowerInvariant()}
  })

  $openssl=(Get-Command openssl.exe -ErrorAction Stop).Source
  $python=Join-Path $env:MSYS2_ROOT 'mingw64\bin\python.exe'
  if(-not(Test-Path -LiteralPath $python -PathType Leaf)){throw "The workflow's pinned MSYS2 Python was not found: $python"}
  Add-Check $openssl @('req','-x509','-newkey','rsa:2048','-nodes','-keyout',$rootPrivateKeyPath,'-out',$rootPemPath,'-days','1','-sha256','-subj','/CN=Eye Break Reminder isolated production updater test CA','-addext','basicConstraints=critical,CA:TRUE','-addext','keyUsage=critical,keyCertSign,cRLSign') 'create disposable test-only TLS root'
  Add-Check $openssl @('req','-new','-newkey','rsa:2048','-nodes','-keyout',$leafPrivateKeyPath,'-out',$leafCsrPath,'-sha256','-subj','/CN=api.github.com') 'create disposable official-host TLS leaf request'
  [IO.File]::WriteAllText($leafExtensionPath,"[server_cert]`r`nbasicConstraints=critical,CA:FALSE`r`nkeyUsage=critical,digitalSignature,keyEncipherment`r`nextendedKeyUsage=serverAuth`r`nsubjectAltName=DNS:api.github.com,DNS:github.com,DNS:unexpected-updates.example.invalid`r`n",[Text.Encoding]::ASCII)
  Add-Check $openssl @('x509','-req','-in',$leafCsrPath,'-CA',$rootPemPath,'-CAkey',$rootPrivateKeyPath,'-CAcreateserial','-out',$leafCertificatePath,'-days','1','-sha256','-extfile',$leafExtensionPath,'-extensions','server_cert') 'sign disposable official-host TLS leaf with the temporary test root'
  Add-Check $openssl @('req','-new','-key',$leafPrivateKeyPath,'-out',$wrongLeafCsrPath,'-sha256','-subj','/CN=wrong-host.invalid') 'create a disposable wrong-host TLS leaf request'
  [IO.File]::WriteAllText($wrongLeafExtensionPath,"[server_cert]`r`nbasicConstraints=critical,CA:FALSE`r`nkeyUsage=critical,digitalSignature,keyEncipherment`r`nextendedKeyUsage=serverAuth`r`nsubjectAltName=DNS:wrong-host.invalid`r`n",[Text.Encoding]::ASCII)
  Add-Check $openssl @('x509','-req','-in',$wrongLeafCsrPath,'-CA',$rootPemPath,'-CAkey',$rootPrivateKeyPath,'-CAcreateserial','-out',$wrongLeafCertificatePath,'-days','1','-sha256','-extfile',$wrongLeafExtensionPath,'-extensions','server_cert') 'sign a trusted TLS leaf that deliberately does not name either GitHub hostname'
  Add-Check $openssl @('x509','-in',$rootPemPath,'-outform','DER','-out',$rootCertificatePath) 'export temporary test-root certificate'
  Record 'Temporary isolated test TLS trust material is ready' 'INFO'
  $rootThumbprint=(Get-FileHash -LiteralPath $rootCertificatePath -Algorithm SHA1).Hash.ToUpperInvariant()
  Record 'Test-root certificate thumbprint computed from its DER bytes' 'INFO' $rootThumbprint
  $temporaryRootCertificate=Add-TemporaryRootCertificate $rootCertificatePath $rootThumbprint
  Assert ($temporaryRootCertificate.Thumbprint-ceq$rootThumbprint) 'temporary test trust anchor is accepted by the disposable runner machine root store without an interactive prompt' $rootThumbprint

  $tail=[Text.Encoding]::ASCII.GetBytes("`r`n127.0.0.1 api.github.com github.com unexpected-updates.example.invalid`r`n::1 api.github.com github.com unexpected-updates.example.invalid`r`n")
  $newHosts=[byte[]]::new($originalHostsBytes.Length+$tail.Length)
  [Array]::Copy($originalHostsBytes,0,$newHosts,0,$originalHostsBytes.Length);[Array]::Copy($tail,0,$newHosts,$originalHostsBytes.Length,$tail.Length)
  $hostsChanged=$true;[IO.File]::WriteAllBytes($hostsPath,$newHosts)
  & ipconfig.exe /flushdns | Out-Host;if($LASTEXITCODE-ne0){throw 'Could not flush the disposable runner DNS cache after temporary feed routing.'}
  $apiResolvedAddresses=@([Net.Dns]::GetHostAddresses('api.github.com')|ForEach-Object{$_.IPAddressToString})
  Assert ($apiResolvedAddresses.Count-eq2-and($apiResolvedAddresses-contains'127.0.0.1')-and($apiResolvedAddresses-contains'::1')) 'official GitHub API hostname resolves only to the isolated IPv4/IPv6 loopback test feed during this transaction' $apiResolvedAddresses
  $assetResolvedAddresses=@([Net.Dns]::GetHostAddresses('github.com')|ForEach-Object{$_.IPAddressToString})
  Assert ($assetResolvedAddresses.Count-eq2-and($assetResolvedAddresses-contains'127.0.0.1')-and($assetResolvedAddresses-contains'::1')) 'official GitHub asset hostname resolves only to the isolated IPv4/IPv6 loopback test feed during this transaction' $assetResolvedAddresses
  $unexpectedRedirectAddresses=@([Net.Dns]::GetHostAddresses('unexpected-updates.example.invalid')|ForEach-Object{$_.IPAddressToString})
  Assert ($unexpectedRedirectAddresses.Count-eq2-and($unexpectedRedirectAddresses-contains'127.0.0.1')-and($unexpectedRedirectAddresses-contains'::1')) 'unexpected HTTPS redirect hostname resolves only to the isolated IPv4/IPv6 loopback test feed so a followed redirect is observable' $unexpectedRedirectAddresses

  $scriptPath=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'production_update_test_feed.py'))
  $serverArgs=@($scriptPath,'--certificate',$leafCertificatePath,'--private-key',$leafPrivateKeyPath,'--setup',$feedSetupPath,'--app',$controlledExecutablePath,'--request-log',$requestLogPath,'--ready-file',$readyPath,'--redirect-marker',$redirectMarkerPath)
  if($signedPreserve){$serverArgs += @('--manifest',$ProductionManifest,'--signature',$ProductionSignature)}
  $serverStopped=$false
  $serverProcess=Start-Process -FilePath $python -ArgumentList $serverArgs -PassThru -WindowStyle Hidden -RedirectStandardOutput $serverStdout -RedirectStandardError $serverStderr
  $listenWatch=[Diagnostics.Stopwatch]::StartNew()
  while($listenWatch.Elapsed.TotalSeconds-lt15-and-not(Test-Path -LiteralPath $readyPath)){if($serverProcess.HasExited){throw "Loopback TLS feed exited before it became ready. $([IO.File]::ReadAllText($serverStderr))"};Start-Sleep -Milliseconds 100}
  if(-not(Test-Path -LiteralPath $readyPath)){throw 'Loopback TLS feed did not become ready on IPv4 and IPv6 loopback port 443.'}
  if ($signedPreserve) {
    [void][IO.Directory]::CreateDirectory($installDir)
    $installedExe = Join-Path $installDir 'EyeBreakReminder.exe'
    $uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder'
    if ($portableRoute) {
      Copy-Item -LiteralPath $candidateExecutablePath -Destination $installedExe
    } else {
      $setup = Start-Process -FilePath $candidateInstallerPath -ArgumentList @('/S',"/D=$installDir") -PassThru
      Assert ($setup.WaitForExit(90000) -and $setup.ExitCode -eq 0) 'Public v1.4.0 setup installed the predecessor in the disposable profile'
      Assert ((Get-ItemProperty -LiteralPath $uninstallKey).DisplayVersion -ceq '1.4.0') 'Predecessor Installed Apps version'
    }
    Assert ((Get-FileHash $installedExe).Hash -ceq '90880BE4B515AF59967FF221E379AB5958D84C2E98F2EF50AC4CC5AECC9DC6A9') 'Exact public v1.4.0 executable SHA-256'
    [void][IO.Directory]::CreateDirectory($dataDir)
    $settingsPath = Join-Path $dataDir 'settings.ini'
    $historyPath = Join-Path $dataDir 'history.dat'
    Set-Content -LiteralPath $settingsPath -Encoding ascii -Value @('workMinutes=37','breakSeconds=33','volume=32','theme=2','alarm=0','autoStart=1','history=1','schedule=0','autoCheckUpdates=0','autoDownloadUpdates=0')
    $settingsBefore = Read-SettingsMap $settingsPath
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    [IO.File]::WriteAllText($historyPath, "$($now-120) 1 20" + [char]10)
    $historyHash = (Get-FileHash $historyPath).Hash
    $appProcess = Start-Process -FilePath $installedExe -PassThru
    Invoke-Button (Find-Dialog 'Eye Break Reminder' $appProcess.Id 30) 'Settings'
    Invoke-Button (Find-Dialog 'About' $appProcess.Id 15) 'About'
    $about = Find-Dialog 'Check for Updates' $appProcess.Id 20
    $check = Find-Button $about 'Check for Updates'
    if ($check.Current.IsEnabled) { Invoke-Button $about 'Check for Updates' }
    $choice = Find-Dialog 'Eye Break Reminder Update Available' $appProcess.Id 60
    $choiceText = $choice.Names -join ' | '
    Assert ($choiceText.Contains('Current version: 1.4.0') -and $choiceText.Contains('Available version: v1.4.1')) 'Production v1.4.0 discovered the newer signed offer' $choiceText
    $preserve = Find-Button $choice 'Preserve my settings (Recommended)'
    $selection = $null
    Assert ($preserve.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern,[ref]$selection) -and $selection.Current.IsSelected) 'Preserve Settings is selected'
    Save-Screenshot $choice 'signed-update-offer.png'
    Invoke-Button $choice 'Download & Install'
    Save-Screenshot (Find-Dialog 'Downloading Eye Break Reminder' $appProcess.Id 30) 'signed-update-progress.png'
    $ready = Find-Dialog 'Ready to install.' $appProcess.Id 45
    $readyText = $ready.Names -join ' | '
    Assert ($readyText.Contains('(100%)') -and $readyText.Contains('SHA-256 digest matches GitHub')) 'Download reached 100% and the UI confirmed SHA-256 verification' $readyText
    Save-Screenshot $ready 'signed-update-ready.png'
    $assetName = if ($portableRoute) { 'EyeBreakReminder.exe' } else { 'EyeBreakReminder-Setup-x64.exe' }
    $payload = if ($portableRoute) { $controlledExecutablePath } else { $controlledInstallerPath }
    $staged = @(Get-ChildItem -LiteralPath (Join-Path $dataDir 'updates') -File -Recurse -Filter $assetName)
    Assert ($staged.Count -eq 1 -and (Get-FileHash $staged[0].FullName).Hash -ceq (Get-FileHash $payload).Hash) 'Staged payload matches the production-signed candidate bytes'
    Invoke-Button $ready 'Install Update'
    $success = Find-Dialog 'Update complete.' 0 150
    Save-Screenshot $success 'signed-update-complete.png'
    Invoke-Button $success 'Close'
    Assert ($appProcess.WaitForExit(15000)) 'The exact predecessor process shut down during handoff'

    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
      $running = @(Get-CimInstance Win32_Process -Filter "Name='EyeBreakReminder.exe'" | Where-Object { $_.ExecutablePath -ieq $installedExe })
      if ($running.Count) { break }
      Start-Sleep -Milliseconds 200
    } while ($watch.Elapsed.TotalSeconds -lt 30)
    Assert ($running.Count -eq 1 -and $running[0].ProcessId -ne $appProcess.Id) 'Coordinator automatically relaunched the successor'
    Assert ((Get-Item $installedExe).VersionInfo.ProductVersion -ceq '1.4.1' -and (Get-FileHash $installedExe).Hash -ceq (Get-FileHash $controlledExecutablePath).Hash) 'Relaunched version and executable digest match the exact v1.4.1 candidate'
    if ($portableRoute) {
      Assert (-not (Test-Path -LiteralPath $uninstallKey)) 'Portable replacement created no Installed Apps entry'
    } else {
      Assert ((Get-ItemProperty -LiteralPath $uninstallKey).DisplayVersion -ceq '1.4.1' -and (Test-Path (Join-Path $installDir 'Uninstall.exe'))) 'NSIS handoff set Installed Apps version and retained the uninstaller'
    }
    $settingsAfter = Read-SettingsMap $settingsPath
    $changed = @($settingsBefore.Keys | Where-Object { $settingsBefore[$_] -cne $settingsAfter[$_] })
    Assert ($changed.Count -eq 0) 'Preserve Settings kept every seeded setting value' $changed
    Assert ((Get-FileHash $historyPath).Hash -ceq $historyHash) 'History remained byte-for-byte identical'
    $updated = Get-Process -Id $running[0].ProcessId
    $mainAfter = Find-Dialog 'Eye Break Reminder' $updated.Id 25
    $initial = [EBR_PROD_UI]::Countdown($mainAfter.Handle)
    Assert ($initial -match '^\d+:\d{2}$') 'The relaunched timer displayed a countdown' $initial
    $samples = @(for ($i = 0; $i -lt 6; $i++) {
      $updated.Refresh()
      [pscustomobject]@{
        USER=[EBR_PROD_UI]::GetGuiResources($updated.Handle,1)
        GDI=[EBR_PROD_UI]::GetGuiResources($updated.Handle,0)
        Handles=$updated.HandleCount
        PrivateBytes=$updated.PrivateMemorySize64
      }
      Start-Sleep -Seconds 1
    })
    Assert (@($samples | Where-Object { $_.USER -le 0 -or $_.GDI -le 0 -or $_.Handles -le 0 -or $_.PrivateBytes -le 0 }).Count -eq 0) 'Focused resource smoke collected live USER, GDI, handle and private memory samples' $samples
    $current = [EBR_PROD_UI]::Countdown($mainAfter.Handle)
    Assert ($current -match '^\d+:\d{2}$' -and [TimeSpan]::Parse("00:$current") -lt [TimeSpan]::Parse("00:$initial")) 'The relaunched timer advanced' "$initial to $current"

    $recoveryKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    $updatesRoot = Join-Path $dataDir 'updates'
    $watch.Restart()
    do {
      $stageRemains = (Test-Path -LiteralPath $updatesRoot) -and @(Get-ChildItem -LiteralPath $updatesRoot -Force).Count -gt 0
      $recoveryRemains = $null -ne (Get-ItemProperty -LiteralPath $recoveryKey -Name '!EyeBreakReminderUpdateRecovery' -ErrorAction SilentlyContinue)
      if (-not ($stageRemains -or $recoveryRemains)) { break }
      Start-Sleep -Milliseconds 200
    } while ($watch.Elapsed.TotalSeconds -lt 30)
    Assert (-not ($stageRemains -or $recoveryRemains)) 'Update stage and recovery registration were cleared'
    $requests = @(Get-Content -LiteralPath $requestLogPath | ForEach-Object { $_ | ConvertFrom-Json })
    foreach ($name in @('EyeBreakReminder-UpdateManifest.json','EyeBreakReminder-UpdateManifest.sig',$assetName)) {
      $path = "/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/download/v1.4.1/$name"
      Assert (@($requests | Where-Object { $_.host -ceq 'github.com' -and $_.path -ceq $path -and $_.response_status -eq 200 }).Count -gt 0) "Unmodified production updater requested $name from isolated HTTPS"
    }
    $script:resultStatus = 'PASS'
    return
  }

  # First remove the test-only issuer and prove Windows rejects the endpoint.
  # The production application will exercise the same WinHTTP certificate
  # validation path below. Reinstall the temporary root only after rejection.
  $rootRemoveBeforeRejection=Remove-TemporaryRootCertificate $rootThumbprint $script:temporaryRootCertificateRawData
  Assert ($rootRemoveBeforeRejection) 'the test-only TLS issuer is removed before invalid-certificate rejection' $rootThumbprint
  $rootAbsentBeforeRejection=Get-TemporaryRootCertificate $rootThumbprint
  Assert (-not$rootAbsentBeforeRejection.Present) 'the test-only TLS issuer is absent before the invalid-certificate rejection case' $rootThumbprint
  $requestsBeforePretrust=@(Get-Content -LiteralPath $requestLogPath -ErrorAction SilentlyContinue).Count
  $pretrustProbeFailed=$false;$pretrustProbeMessage=''
  try { [void](Invoke-WebRequest -Uri 'https://api.github.com/repos/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/latest' -UseBasicParsing -TimeoutSec 10) }
  catch { $pretrustProbeFailed=$true;$pretrustProbeMessage=$_.Exception.ToString() }
  Assert ($pretrustProbeFailed-and$pretrustProbeMessage-match'certificate|trust|secure|SSL|TLS') 'Windows rejects the isolated feed certificate while its issuer is untrusted' $pretrustProbeMessage
  $requestsAfterPretrust=@(Get-Content -LiteralPath $requestLogPath -ErrorAction SilentlyContinue).Count
  Assert ($requestsAfterPretrust-eq$requestsBeforePretrust) 'an untrusted TLS handshake adds no HTTP request to the isolated release feed' ([pscustomobject]@{RequestsBefore=$requestsBeforePretrust;RequestsAfter=$requestsAfterPretrust;Scenario=$Scenario})

  [void][IO.Directory]::CreateDirectory($installDir)
  Record 'Begin isolated fresh install of the exact candidate' 'INFO' $candidateInstallerPath
  $setup=Start-Process -FilePath $candidateInstallerPath -ArgumentList @('/S',"/D=$installDir") -PassThru
  if(-not$setup.WaitForExit(120000)){Stop-Process -Id $setup.Id -Force -ErrorAction SilentlyContinue;[void]$setup.WaitForExit(5000);throw 'The exact candidate silent installer exceeded its 120-second acceptance bound.'}
  $setupExitCode=$setup.ExitCode
  Assert ($setupExitCode-eq0) 'the exact authoritative v1.4.0 NSIS installer completed a fresh per-user installation' $setupExitCode
  $installedExe=Join-Path $installDir 'EyeBreakReminder.exe'
  Assert ((Get-FileHash -LiteralPath $installedExe -Algorithm SHA256).Hash.ToLowerInvariant()-eq(Get-FileHash -LiteralPath $candidateExecutablePath -Algorithm SHA256).Hash.ToLowerInvariant()) 'fresh install contains the exact candidate production executable'
  Assert ((Get-Item -LiteralPath $installedExe).VersionInfo.ProductVersion-match'^1\.4\.0(\.0)?$') 'fresh install executable reports the v1.4.0 product version'
  $uninstallKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder'
  Assert ((Get-ItemProperty -LiteralPath $uninstallKey -ErrorAction Stop).DisplayVersion-eq'1.4.0') 'fresh v1.4.0 install has the correct Installed Apps version'

  [void][IO.Directory]::CreateDirectory($dataDir)
  $settings=@('workMinutes=37','breakSeconds=33','volume=32','theme=2','alarm=0','repeat=1','notifications=0','snooze=0','autoStart=0','startup=1','history=1','breakModeColors=1','customWorkAccent=1','workAccentColor=3900150','customBreakAccent=1','breakAccentColor=16746496','autoCheckUpdates=1','autoDownloadUpdates=0','updateLastCheck=0','restore=1','schedule=1','scheduleMonday=1','scheduleMonday1=09001700') -join "`n"
  [IO.File]::WriteAllText((Join-Path $dataDir 'settings.ini'),$settings+"`n",[Text.UTF8Encoding]::new($false))
  $now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds();$historyText="$($now-120) 1 20`n"
  [IO.File]::WriteAllText((Join-Path $dataDir 'history.dat'),$historyText,[Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText((Join-Path $dataDir 'unrelated-sentinel.txt'),'unrelated runner profile data',[Text.UTF8Encoding]::new($false))
  if(-not(Test-Path -LiteralPath $runKeyPath)){New-Item -Path $runKeyPath -Force -ErrorAction Stop|Out-Null;$runKeyCreated=$true}
  $existingStartup=Get-ItemProperty -LiteralPath $runKeyPath -Name EyeBreakReminder -ErrorAction SilentlyContinue
  if($null-ne$existingStartup){throw 'The disposable runner already has an Eye Break Reminder startup value; refusing to replace it.'}
  $startupCommand='"'+$installedExe+'" --startup'
  $startupValueAdded=$true
  New-ItemProperty -LiteralPath $runKeyPath -Name EyeBreakReminder -PropertyType String -Value $startupCommand -ErrorAction Stop | Out-Null
  Assert ((Get-ItemProperty -LiteralPath $runKeyPath -Name EyeBreakReminder -ErrorAction Stop).EyeBreakReminder-ceq$startupCommand) 'disposable profile starts with an explicit Eye Break Reminder startup registration before updating'
  $settingsBeforeHash=(Get-FileHash -LiteralPath (Join-Path $dataDir 'settings.ini') -Algorithm SHA256).Hash.ToLowerInvariant()
  $settingsBefore=Read-SettingsMap (Join-Path $dataDir 'settings.ini')
  $historyBefore=[IO.File]::ReadAllBytes((Join-Path $dataDir 'history.dat'))
  $sentinelBefore=[IO.File]::ReadAllBytes((Join-Path $dataDir 'unrelated-sentinel.txt'))
  $appProcess=Start-Process -FilePath $installedExe -PassThru
  Record 'Actual installed production app launched' 'INFO' ([pscustomobject]@{ProcessId=$appProcess.Id;ExecutablePath=$installedExe;SHA256=(Get-FileHash -LiteralPath $installedExe -Algorithm SHA256).Hash.ToLowerInvariant();ProductVersion=(Get-Item $installedExe).VersionInfo.ProductVersion;BuildMacro='EYEBREAK_TEST_BUILD absent'})
  $settingsTab=Find-Dialog 'Eye Break Reminder' $appProcess.Id 30
  Invoke-Button $settingsTab 'Settings'
  Start-Sleep -Milliseconds 250
  $settingsTab=Find-Dialog 'Eye Break Reminder' $appProcess.Id 5
  Save-Screenshot $settingsTab 'production-settings-navigation.png'
  Record 'UI state after selecting the production Settings tab' 'INFO' ($settingsTab.Names -join ' | ')
  $about=Find-Dialog 'About' $appProcess.Id 15
  Invoke-Button $about 'About'
  $tlsError=Find-Dialog 'A secure connection to GitHub could not be verified.' $appProcess.Id 30
  Assert ($tlsError.WindowTitle-eq'Eye Break Reminder') 'production updater presents a meaningful TLS certificate validation error in the About settings UI' ($tlsError.Names -join ' | ')
  Assert (@(Get-Content -LiteralPath $requestLogPath -ErrorAction SilentlyContinue).Count-eq0) 'production WinHTTP rejects the untrusted certificate before sending release metadata over HTTP'
  Assert (-not(Test-Path -LiteralPath (Join-Path $dataDir 'updates'))) 'invalid TLS certificate rejection creates no update staging directory'
  Assert ((Get-FileHash -LiteralPath $installedExe -Algorithm SHA256).Hash.ToLowerInvariant()-eq(Get-FileHash -LiteralPath $candidateExecutablePath -Algorithm SHA256).Hash.ToLowerInvariant()) 'invalid TLS certificate rejection does not replace the installed production candidate'
  Assert ([Convert]::ToBase64String($historyBefore)-ceq[Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $dataDir 'history.dat')))-and[Convert]::ToBase64String($sentinelBefore)-ceq[Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $dataDir 'unrelated-sentinel.txt')))) 'invalid TLS certificate rejection leaves existing history and unrelated user data byte-for-byte unchanged'
  $rootStillAbsent=Get-TemporaryRootCertificate $rootThumbprint
  Assert (-not$rootStillAbsent.Present) 'unverified feed does not acquire a trusted-root installation or bypass certificate validation' $rootThumbprint
  Stop-ProductionApplication
  $appProcess=$null
  $rootImportAfterRejection=Add-TemporaryRootCertificate $rootCertificatePath $rootThumbprint
  Assert ($rootImportAfterRejection.Present-and$rootImportAfterRejection.Thumbprint-ceq$rootThumbprint) 'temporary test CA is installed only after the invalid-certificate rejection is verified' $rootImportAfterRejection
  $rootPresenceAfterRejection=Get-TemporaryRootCertificate $rootThumbprint
  Assert ($rootPresenceAfterRejection.Present-and$rootPresenceAfterRejection.RawDataBase64-ceq[Convert]::ToBase64String($script:temporaryRootCertificateRawData)) 'trusted controlled update feed has only the disposable current-user TLS test root'

  if($serverProcess){$serverProcess.Kill();if(-not$serverProcess.WaitForExit(5000)){throw 'Trusted-host TLS feed did not stop before the wrong-host case.'};$serverProcess.Dispose();$serverProcess=$null;$serverStopped=$true}
  Remove-Item -LiteralPath $wrongReadyPath -Force -ErrorAction SilentlyContinue
  $wrongServerArgs=@($scriptPath,'--certificate',$wrongLeafCertificatePath,'--private-key',$leafPrivateKeyPath,'--setup',$feedSetupPath,'--app',$controlledExecutablePath,'--request-log',$requestLogPath,'--ready-file',$wrongReadyPath)
  $wrongServerStdout=Join-Path $EvidenceDirectory 'wrong-host-feed.stdout.log';$wrongServerStderr=Join-Path $EvidenceDirectory 'wrong-host-feed.stderr.log'
  $serverProcess=Start-Process -FilePath $python -ArgumentList $wrongServerArgs -PassThru -WindowStyle Hidden -RedirectStandardOutput $wrongServerStdout -RedirectStandardError $wrongServerStderr;$serverStopped=$false
  $wrongListenWatch=[Diagnostics.Stopwatch]::StartNew()
  while($wrongListenWatch.Elapsed.TotalSeconds-lt15-and-not(Test-Path -LiteralPath $wrongReadyPath)){if($serverProcess.HasExited){throw "Wrong-host HTTPS feed exited before it became ready. $([IO.File]::ReadAllText($wrongServerStderr))"};Start-Sleep -Milliseconds 100}
  if(-not(Test-Path -LiteralPath $wrongReadyPath)){throw 'Wrong-host HTTPS feed did not become ready on IPv4 and IPv6 loopback port 443.'}
  $wrongHostProbeFailed=$false;$wrongHostProbeMessage=''
  try{[void](Invoke-WebRequest -Uri 'https://api.github.com/repos/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/latest' -UseBasicParsing -TimeoutSec 10)}catch{$wrongHostProbeFailed=$true;$wrongHostProbeMessage=$_.Exception.ToString()}
  Assert ($wrongHostProbeFailed-and$wrongHostProbeMessage-match'RemoteCertificateNameMismatch|name mismatch|target name|NameMismatch') 'Windows rejects a trusted certificate whose SAN does not match the GitHub request hostname' $wrongHostProbeMessage
  Assert (@(Get-Content -LiteralPath $requestLogPath -ErrorAction SilentlyContinue).Count-eq0) 'a trusted wrong-host TLS handshake sends no HTTP request to the isolated release feed'
  $wrongHostSettingsPath=Join-Path $dataDir 'settings.ini';$wrongHostSettingsRaw=Get-Content -LiteralPath $wrongHostSettingsPath -Raw;$wrongHostTimestamp=[regex]::Match($wrongHostSettingsRaw,'(?m)^updateLastCheck=(\d+)$');if(-not$wrongHostTimestamp.Success){throw 'The disposable update-check timestamp is missing before the wrong-host rejection test.'};if($wrongHostTimestamp.Groups[1].Value-cne'0'){$wrongHostSettingsRaw=[regex]::Replace($wrongHostSettingsRaw,'(?m)^updateLastCheck=\d+$','updateLastCheck=0');[IO.File]::WriteAllText($wrongHostSettingsPath,$wrongHostSettingsRaw,[Text.UTF8Encoding]::new($false))};$wrongHostSettingsBefore=Read-SettingsMap $wrongHostSettingsPath
  $appProcess=Start-Process -FilePath $installedExe -PassThru
  Record 'Actual installed production app launched against trusted wrong-host TLS certificate' 'INFO' ([pscustomobject]@{ProcessId=$appProcess.Id;ExecutablePath=$installedExe;ServerCertificate=$wrongLeafCertificatePath;ExpectedHostname='api.github.com'})
  $wrongHostSettingsTab=Find-Dialog 'Eye Break Reminder' $appProcess.Id 30
  Invoke-Button $wrongHostSettingsTab 'Settings'
  Start-Sleep -Milliseconds 250
  $wrongHostSettingsTab=Find-Dialog 'Eye Break Reminder' $appProcess.Id 5
  $wrongHostAbout=Find-Dialog 'About' $appProcess.Id 15;Invoke-Button $wrongHostAbout 'About'
  $wrongHostTlsError=Find-Dialog 'A secure connection to GitHub could not be verified.' $appProcess.Id 30
  Assert ($wrongHostTlsError.WindowTitle-eq'Eye Break Reminder') 'production updater displays a meaningful error for a trusted certificate with the wrong hostname' ($wrongHostTlsError.Names -join ' | ')
  Assert (@(Get-Content -LiteralPath $requestLogPath -ErrorAction SilentlyContinue).Count-eq0) 'production WinHTTP rejects the trusted wrong-host certificate before sending release metadata'
  Assert (-not(Test-Path -LiteralPath (Join-Path $dataDir 'updates'))) 'trusted wrong-host certificate rejection creates no update staging directory'
  Assert ((Get-FileHash -LiteralPath $installedExe -Algorithm SHA256).Hash.ToLowerInvariant()-eq(Get-FileHash -LiteralPath $candidateExecutablePath -Algorithm SHA256).Hash.ToLowerInvariant()) 'trusted wrong-host certificate rejection does not replace the installed production candidate'
  $wrongHostSettingsAfter=Read-SettingsMap $wrongHostSettingsPath;$wrongHostSettingKeys=@($wrongHostSettingsBefore.Keys|Where-Object{$_-cne'updateLastCheck'});$wrongHostSettingChanges=@($wrongHostSettingKeys|Where-Object{-not$wrongHostSettingsAfter.ContainsKey($_)-or[string]$wrongHostSettingsBefore[$_]-cne[string]$wrongHostSettingsAfter[$_]})
  Assert ($wrongHostSettingChanges.Count-eq0-and[Convert]::ToBase64String($historyBefore)-ceq[Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $dataDir 'history.dat')))-and[Convert]::ToBase64String($sentinelBefore)-ceq[Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $dataDir 'unrelated-sentinel.txt')))) 'trusted wrong-host rejection preserves settings, history and unrelated profile data byte-for-byte (except the check timestamp)' ([pscustomobject]@{ChangedSettings=$wrongHostSettingChanges;HistoryUnchanged=$true;UnrelatedSentinelUnchanged=$true})
  Stop-ProductionApplication;$appProcess=$null
  if($serverProcess){$serverProcess.Kill();if(-not$serverProcess.WaitForExit(5000)){throw 'Wrong-host HTTPS feed did not stop before restoring the trusted feed.'};$serverProcess.Dispose();$serverProcess=$null;$serverStopped=$true}
  Remove-Item -LiteralPath $readyPath -Force -ErrorAction SilentlyContinue
  $serverArgs=@($scriptPath,'--certificate',$leafCertificatePath,'--private-key',$leafPrivateKeyPath,'--setup',$feedSetupPath,'--app',$controlledExecutablePath,'--request-log',$requestLogPath,'--ready-file',$readyPath,'--redirect-marker',$redirectMarkerPath)
  $serverProcess=Start-Process -FilePath $python -ArgumentList $serverArgs -PassThru -WindowStyle Hidden -RedirectStandardOutput $serverStdout -RedirectStandardError $serverStderr;$serverStopped=$false
  $listenWatch=[Diagnostics.Stopwatch]::StartNew()
  while($listenWatch.Elapsed.TotalSeconds-lt15-and-not(Test-Path -LiteralPath $readyPath)){if($serverProcess.HasExited){throw "Trusted-host TLS feed exited before it became ready. $([IO.File]::ReadAllText($serverStderr))"};Start-Sleep -Milliseconds 100}
  if(-not(Test-Path -LiteralPath $readyPath)){throw 'Trusted-host HTTPS feed did not become ready after wrong-host rejection.'}
  $feedProbe=Invoke-WebRequest -Uri 'https://api.github.com/repos/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/latest' -UseBasicParsing -TimeoutSec 10
  $feedContent=if($feedProbe.Content-is[byte[]]){[Text.Encoding]::UTF8.GetString($feedProbe.Content)}else{[string]$feedProbe.Content}
  $feedRelease=ConvertFrom-Json -InputObject $feedContent
  $feedProbeDetails=[pscustomobject]@{StatusCode=[int]$feedProbe.StatusCode;TagName=[string]$feedRelease.tag_name;ResponseContent=$feedContent;Requests=@(Get-Content -LiteralPath $requestLogPath -ErrorAction SilentlyContinue|ForEach-Object{$_|ConvertFrom-Json})}
  Assert (($feedProbeDetails.StatusCode-eq200)-and($feedProbeDetails.TagName-ceq'v1.4.1')) 'ephemeral CA validates HTTPS to the isolated controlled official-host release feed' $feedProbeDetails
  Record 'Trusted controlled HTTPS feed probe completed' 'INFO'
  $launchSentinelMarker=Join-Path $EvidenceDirectory 'unverified-installer-launch-marker.txt'
  if(Test-Path -LiteralPath $launchSentinelMarker){throw 'The test-only launch-sentinel marker unexpectedly exists before the payload replacement test.'}
  $env:EBR_TEST_UNVERIFIED_LAUNCH_MARKER=$launchSentinelMarker
  $sentinelBytes=[IO.File]::ReadAllBytes($launchSentinelPath)
  Record 'Test-only unverified-executable sentinel identity' 'INFO' ([pscustomobject]@{Path=$launchSentinelPath;Bytes=$sentinelBytes.Length;SHA256=(Get-FileHash -LiteralPath $launchSentinelPath -Algorithm SHA256).Hash.ToLowerInvariant();MarkerPath=$launchSentinelMarker})

  if($Scenario-eq'CoordinatorBackupFailure'){
    $controlledInstallerMarker=Join-Path $testRoot 'controlled-installer-launched.txt'
    if(Test-Path -LiteralPath $controlledInstallerMarker){throw 'The test-only controlled-installer launch marker unexpectedly exists before the backup-failure test.'}
    $env:EBR_TEST_INSTALLER_LAUNCH_MARKER=$controlledInstallerMarker
    $appProcess=Start-Process -FilePath $installedExe -PassThru
    Record 'Exact candidate launched for coordinator backup-failure injection' 'INFO' ([pscustomobject]@{ProcessId=$appProcess.Id;ExecutablePath=$installedExe;ProductVersion=(Get-Item $installedExe).VersionInfo.ProductVersion})
    $choice=Find-Dialog 'Eye Break Reminder Update Available' $appProcess.Id 90
    Assert ($choice.WindowTitle-eq'Eye Break Reminder Update') 'exact candidate discovers the controlled stable successor before backup-failure injection' $choice.WindowTitle
    Invoke-Button $choice 'Download & Install'
    $ready=Find-Dialog 'Ready to install.' $appProcess.Id 120
    Assert ((@($ready.Names)-join' ').Contains('(100%)')-and(@($ready.Names)-join' ').Contains('SHA-256 digest matches GitHub')) 'the controlled update payload is completely downloaded and verified before coordinator backup-failure injection' ($ready.Names -join ' | ')
    $updatesRoot=Join-Path $dataDir 'updates'
    $backupStages=@(Get-ChildItem -LiteralPath $updatesRoot -Directory -Force -ErrorAction Stop)
    Assert ($backupStages.Count-eq1) 'the verified update has one isolated private staging directory before coordinator startup' @($backupStages.FullName)
    $backupCollision=Join-Path $backupStages[0].FullName 'backup-0.dat'
    if(Test-Path -LiteralPath $backupCollision){throw 'The exact backup collision fixture path unexpectedly exists.'}
    [IO.File]::WriteAllText($backupCollision,'disposable pre-existing backup-name collision',[Text.Encoding]::ASCII)
    $collisionHash=(Get-FileHash -LiteralPath $backupCollision -Algorithm SHA256).Hash.ToLowerInvariant()
    $oldPid=$appProcess.Id
    Invoke-Button $ready 'Install Update'
    $backupFailure=Find-Dialog 'The current application or its settings could not be backed up and verified.' 0 180
    $backupFailureText=$backupFailure.Names -join ' '
    Assert ($backupFailure.WindowTitle-eq'Eye Break Reminder Update'-and$backupFailureText.Contains('The current application or its settings could not be backed up and verified.')-and$backupFailureText.Contains('The update was not installed.')) 'the actual production coordinator reports an actionable backup failure before installer execution' $backupFailureText
    Assert (-not(Test-Path -LiteralPath $controlledInstallerMarker)) 'coordinator backup failure rejects before the controlled installer process is launched' $controlledInstallerMarker
    Assert ((Get-Item -LiteralPath $installedExe).VersionInfo.ProductVersion-match'^1\.4\.0(\.0)?$'-and(Get-FileHash -LiteralPath $installedExe -Algorithm SHA256).Hash.ToLowerInvariant()-ceq(Get-FileHash -LiteralPath $candidateExecutablePath -Algorithm SHA256).Hash.ToLowerInvariant()) 'coordinator backup failure leaves the exact tested v1.4.0 installed executable unchanged' ([pscustomobject]@{Version=(Get-Item $installedExe).VersionInfo.ProductVersion;SHA256=(Get-FileHash -LiteralPath $installedExe -Algorithm SHA256).Hash.ToLowerInvariant()})
    Assert ((Get-ItemProperty -LiteralPath $uninstallKey -ErrorAction Stop).DisplayVersion-eq'1.4.0') 'coordinator backup failure leaves Installed Apps registration at v1.4.0'
    $settingsAfterFailure=Read-SettingsMap (Join-Path $dataDir 'settings.ini')
    $settingKeysBefore=@($settingsBefore.Keys|Where-Object{$_-cne'updateLastCheck'}|Sort-Object)
    $changedSettings=@($settingKeysBefore|Where-Object{-not$settingsAfterFailure.ContainsKey($_)-or[string]$settingsBefore[$_]-cne[string]$settingsAfterFailure[$_]})
    Assert ($changedSettings.Count-eq0-and[Convert]::ToBase64String($historyBefore)-ceq[Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $dataDir 'history.dat')))-and[Convert]::ToBase64String($sentinelBefore)-ceq[Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $dataDir 'unrelated-sentinel.txt')))) 'coordinator backup failure preserves user settings, history and unrelated profile bytes' ([pscustomobject]@{ChangedSettings=$changedSettings;HistoryUnchanged=$true;UnrelatedSentinelUnchanged=$true;UpdateCheckTimestampMayAdvance=$true})
    Invoke-Button $backupFailure 'Close'
    $relaunchWatch=[Diagnostics.Stopwatch]::StartNew();$restoredProcesses=@()
    while($relaunchWatch.Elapsed.TotalSeconds-lt45){
      $restoredProcesses=@(Get-CimInstance Win32_Process -Filter "Name='EyeBreakReminder.exe'" -ErrorAction SilentlyContinue|Where-Object{$_.ExecutablePath-and[IO.Path]::GetFullPath([string]$_.ExecutablePath)-ieq$installedExe-and[int]$_.ProcessId-ne$oldPid})
      if($restoredProcesses.Count){break};Start-Sleep -Milliseconds 200
    }
    Assert ($restoredProcesses.Count-gt0) 'the previous v1.4.0 application relaunches after coordinator backup failure' $restoredProcesses
    $restoredProcess=Get-Process -Id ([int]$restoredProcesses[0].ProcessId) -ErrorAction Stop
    Assert ($restoredProcess.MainWindowHandle-ne[IntPtr]::Zero) 'the recovered previous application has a live visible main window' ([pscustomobject]@{ProcessId=$restoredProcess.Id;Path=$restoredProcesses[0].ExecutablePath;WindowHandle=$restoredProcess.MainWindowHandle.ToInt64()})
    $stageWatch=[Diagnostics.Stopwatch]::StartNew()
    while($stageWatch.Elapsed.TotalSeconds-lt20-and(Test-Path -LiteralPath $backupStages[0].FullName)){Start-Sleep -Milliseconds 100}
    Assert (-not(Test-Path -LiteralPath $backupStages[0].FullName)) 'recovery cleanup removes the collision marker and private staging directory' ([pscustomobject]@{StagePath=$backupStages[0].FullName;Removed=(-not(Test-Path -LiteralPath $backupStages[0].FullName));CollisionSHA256=$collisionHash;WaitSeconds=[Math]::Round($stageWatch.Elapsed.TotalSeconds,2)})
    Assert (@(Get-Content -LiteralPath $requestLogPath|ForEach-Object{$_|ConvertFrom-Json}|Where-Object{$_.host-eq'github.com'-and$_.path-eq'/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/download/v1.4.1/EyeBreakReminder-Setup-x64.exe'}).Count-ge1) 'the isolated feed records the verified successor-setup download that preceded the coordinator backup failure'
    Record 'Exact production coordinator backup failure and recovery' 'PASS' ([pscustomobject]@{CandidateVersion='1.4.0';NoInstallerLaunch=(-not(Test-Path -LiteralPath $controlledInstallerMarker));PreviousApplicationRelaunched=$true;UserDataPreserved=$true;StageCleaned=$true;ServedTestInstallerSHA256=(Get-FileHash -LiteralPath $feedSetupPath -Algorithm SHA256).Hash.ToLowerInvariant()})
    $script:resultStatus='PASS'
    return
  }

  if(Test-Path -LiteralPath $redirectMarkerPath){throw 'The one-shot unexpected-redirect fixture marker already exists.'}
  [IO.File]::WriteAllText($redirectMarkerPath,'redirect the next setup asset response once',[Text.Encoding]::ASCII)
  $unexpectedRedirect='https://unexpected-updates.example.invalid/unsafe.exe'
  $appProcess=Start-Process -FilePath $installedExe -PassThru
  Record 'Actual installed production app launched for the unexpected HTTPS redirect rejection scenario' 'INFO' ([pscustomobject]@{ProcessId=$appProcess.Id;ExecutablePath=$installedExe;ProductVersion=(Get-Item $installedExe).VersionInfo.ProductVersion})
  $redirectChoice=Find-Dialog 'Eye Break Reminder Update Available' $appProcess.Id 90
  Assert ($redirectChoice.WindowTitle-eq'Eye Break Reminder Update') 'production binary discovered the controlled stable release before the redirect rejection test' $redirectChoice.WindowTitle
  Invoke-Button $redirectChoice 'Download & Install'
  $redirectFailure=Find-Dialog 'GitHub returned an unsafe or invalid HTTPS download redirect.' $appProcess.Id 120
  $redirectFailureText=$redirectFailure.Names -join ' '
  Assert ($redirectFailure.WindowTitle-eq'Eye Break Reminder Update'-and$redirectFailureText.Contains('Download failed.')-and$redirectFailureText.Contains('The currently installed application and its settings are unchanged.')) 'production updater shows a meaningful error explaining the unsafe HTTPS redirect and that current app/settings are unchanged' $redirectFailureText
  $redirectRequests=@(Get-Content -LiteralPath $requestLogPath|ForEach-Object{$_|ConvertFrom-Json})
  $setupRedirects=@($redirectRequests|Where-Object{$_.host-eq'github.com'-and$_.path-eq'/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/download/v1.4.1/EyeBreakReminder-Setup-x64.exe'-and[int]$_.response_status-eq302-and$_.location-ceq$unexpectedRedirect})
  Assert ($setupRedirects.Count-eq1-and-not(Test-Path -LiteralPath $redirectMarkerPath)) 'the controlled HTTPS asset endpoint returned exactly one logged HTTP 302 to the unexpected host and consumed its one-shot fixture marker' ([pscustomobject]@{Redirects=$setupRedirects;MarkerConsumed=(-not(Test-Path -LiteralPath $redirectMarkerPath))})
  Assert (@($redirectRequests|Where-Object{$_.host-eq'unexpected-updates.example.invalid'}).Count-eq0) 'the production downloader rejected the redirect before making a request to the unexpected host' $redirectRequests
  Assert (-not(Test-Path -LiteralPath $launchSentinelMarker)) 'the rejected HTTPS redirect never launched the unverified installer sentinel' $launchSentinelMarker
  Assert ((Get-Item -LiteralPath $installedExe).VersionInfo.ProductVersion-match'^1\.4\.0(\.0)?$' -and (Get-FileHash -LiteralPath $installedExe -Algorithm SHA256).Hash.ToLowerInvariant()-eq(Get-FileHash -LiteralPath $candidateExecutablePath -Algorithm SHA256).Hash.ToLowerInvariant()) 'unexpected redirect rejection retains the exact installed v1.4.0 candidate executable'
  Assert ((Get-ItemProperty -LiteralPath $uninstallKey -ErrorAction Stop).DisplayVersion-eq'1.4.0') 'unexpected redirect rejection leaves the Installed Apps version unchanged'
  $redirectSettingsAfter=Read-SettingsMap (Join-Path $dataDir 'settings.ini');$redirectSettingKeys=@($settingsBefore.Keys|Where-Object{$_-cne'updateLastCheck'});$redirectSettingChanges=@($redirectSettingKeys|Where-Object{-not$redirectSettingsAfter.ContainsKey($_)-or[string]$settingsBefore[$_]-cne[string]$redirectSettingsAfter[$_]})
  Assert ($redirectSettingChanges.Count-eq0-and[Convert]::ToBase64String($historyBefore)-ceq[Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $dataDir 'history.dat')))-and[Convert]::ToBase64String($sentinelBefore)-ceq[Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $dataDir 'unrelated-sentinel.txt')))) 'unexpected redirect rejection preserves settings (except the normal update-check timestamp), history and unrelated user data byte-for-byte' ([pscustomobject]@{ChangedSettings=$redirectSettingChanges;HistoryUnchanged=$true;UnrelatedSentinelUnchanged=$true})
  $redirectUpdatesRoot=Join-Path $dataDir 'updates';$redirectStageDirectories=@();$redirectPayloads=@()
  if(Test-Path -LiteralPath $redirectUpdatesRoot){$redirectStageDirectories=@(Get-ChildItem -LiteralPath $redirectUpdatesRoot -Directory -Force -ErrorAction SilentlyContinue);$redirectPayloads=@(Get-ChildItem -LiteralPath $redirectUpdatesRoot -File -Recurse -Force -ErrorAction SilentlyContinue|Where-Object{$_.Name -like 'EyeBreakReminder*'})}
  $redirectStagePaths=@($redirectStageDirectories|ForEach-Object{$_.FullName})
  Assert ($redirectStageDirectories.Count-eq1-and$redirectPayloads.Count-eq0) 'while the download error is displayed, its private staging directory contains no executable or partial payload' ([pscustomobject]@{StageDirectories=$redirectStageDirectories.Count;PayloadFiles=$redirectPayloads.Count;StagePaths=$redirectStagePaths})
  Invoke-Button $redirectFailure 'Cancel'
  $redirectCleanupWatch=[Diagnostics.Stopwatch]::StartNew()
  while($redirectCleanupWatch.Elapsed.TotalSeconds-lt10-and@($redirectStagePaths|Where-Object{Test-Path -LiteralPath $_}).Count-gt0){Start-Sleep -Milliseconds 100}
  $redirectRemainingStagePaths=@($redirectStagePaths|Where-Object{Test-Path -LiteralPath $_})
  $redirectPayloadsAfterCancel=@()
  if(Test-Path -LiteralPath $redirectUpdatesRoot){$redirectPayloadsAfterCancel=@(Get-ChildItem -LiteralPath $redirectUpdatesRoot -File -Recurse -Force -ErrorAction SilentlyContinue|Where-Object{$_.Name -like 'EyeBreakReminder*'})}
  Assert ($redirectRemainingStagePaths.Count-eq0-and$redirectPayloadsAfterCancel.Count-eq0) 'dismissing the download error lets the application remove the failed transaction staging directory and any payload' ([pscustomobject]@{RemovedStagePaths=$redirectStagePaths;RemainingStagePaths=$redirectRemainingStagePaths;PayloadFiles=$redirectPayloadsAfterCancel.Count;WaitSeconds=[Math]::Round($redirectCleanupWatch.Elapsed.TotalSeconds,2)})
  Record 'Unexpected HTTPS update redirect rejection' 'PASS' ([pscustomobject]@{HttpStatus=302;Location=$unexpectedRedirect;NoRedirectedRequest=$true;NoInstallerLaunch=(-not(Test-Path -LiteralPath $launchSentinelMarker));InstalledVersion=(Get-Item $installedExe).VersionInfo.ProductVersion;NoStagedPayload=($redirectPayloads.Count-eq0-and$redirectRemainingStagePaths.Count-eq0-and$redirectPayloadsAfterCancel.Count-eq0);StageRemovedAfterCancel=($redirectRemainingStagePaths.Count-eq0)})
  Stop-ProductionApplication;$appProcess=$null
  $redirectSettingsPath=Join-Path $dataDir 'settings.ini';$redirectSettingsRaw=[regex]::Replace((Get-Content -LiteralPath $redirectSettingsPath -Raw),'(?m)^updateLastCheck=\d+$','updateLastCheck=0');[IO.File]::WriteAllText($redirectSettingsPath,$redirectSettingsRaw,[Text.UTF8Encoding]::new($false))
  $appProcess=Start-Process -FilePath $installedExe -PassThru
  Record 'Production app relaunched after safely rejecting an unexpected HTTPS redirect' 'INFO' ([pscustomobject]@{ProcessId=$appProcess.Id;ExecutablePath=$installedExe;ProductVersion=(Get-Item $installedExe).VersionInfo.ProductVersion})
  $choice=Find-Dialog 'Eye Break Reminder Update Available' $appProcess.Id 90
  Assert ($choice.WindowTitle-eq'Eye Break Reminder Update') 'production binary discovered the controlled stable release and opened its native update dialog' $choice.WindowTitle
  Assert ((@($choice.Names)-join' ').Contains('Current version: 1.4.0')-and(@($choice.Names)-join' ').Contains('v1.4.1')-and(@($choice.Names)-join' ').Contains('Release notes')) 'production update dialog shows installed/available versions and release notes' ($choice.Names -join ' | ')
  Save-Screenshot $choice 'production-update-available.png'
  Invoke-Button $choice 'Download & Install'
  $ready=Find-Dialog 'Ready to install.' $appProcess.Id 120
  Assert ((@($ready.Names)-join' ').Contains('(100%)')-and(@($ready.Names)-join' ').Contains('SHA-256 digest matches GitHub')) 'production downloader reaches complete byte progress and digest verification' ($ready.Names -join ' | ')
  Save-Screenshot $ready 'production-update-ready-to-install.png'

  $updatesRoot=Join-Path $dataDir 'updates';$stagedSetups=@(Get-ChildItem -LiteralPath $updatesRoot -Directory -ErrorAction Stop|ForEach-Object{Get-ChildItem -LiteralPath $_.FullName -File -Filter 'EyeBreakReminder-Setup-x64.exe' -ErrorAction SilentlyContinue})
  Assert ($stagedSetups.Count-eq1) 'the verified update installer exists at one uniquely staged path before the replacement attack' $stagedSetups.FullName
  $expectedSetupSize=(Get-Item -LiteralPath $controlledInstallerPath).Length
  if($sentinelBytes.Length-gt$expectedSetupSize){throw 'The test sentinel executable is unexpectedly larger than the controlled installer payload.'}
  $replacementBytes=[byte[]]::new([int]$expectedSetupSize);[Array]::Copy($sentinelBytes,0,$replacementBytes,0,$sentinelBytes.Length)
  [IO.File]::WriteAllBytes($stagedSetups[0].FullName,$replacementBytes)
  $replacementHash=(Get-FileHash -LiteralPath $stagedSetups[0].FullName -Algorithm SHA256).Hash.ToLowerInvariant();$expectedSetupHash=(Get-FileHash -LiteralPath $controlledInstallerPath -Algorithm SHA256).Hash.ToLowerInvariant()
  Assert ((Get-Item -LiteralPath $stagedSetups[0].FullName).Length-eq$expectedSetupSize-and$replacementHash-cne$expectedSetupHash) 'post-verification replacement preserves the expected size but changes the installer digest' ([pscustomobject]@{ExpectedSize=$expectedSetupSize;ActualSize=(Get-Item -LiteralPath $stagedSetups[0].FullName).Length;ExpectedSHA256=$expectedSetupHash;ReplacementSHA256=$replacementHash})
  Invoke-Button $ready 'Install Update'
  $replacementRejected=Find-Dialog 'The staged update failed its final size or SHA-256 verification.' 0 180
  Assert ($replacementRejected.WindowTitle-eq'Eye Break Reminder Update') 'the coordinator reports that the staged installer changed after its download verification' ($replacementRejected.Names -join ' | ')
  Assert (-not(Test-Path -LiteralPath $launchSentinelMarker)) 'the replaced unverified installer was not launched at the coordinator execution boundary'
  Assert ((Get-Item -LiteralPath $installedExe).VersionInfo.ProductVersion-match'^1\.4\.0(\.0)?$'-and(Get-FileHash -LiteralPath $installedExe -Algorithm SHA256).Hash.ToLowerInvariant()-eq(Get-FileHash -LiteralPath $candidateExecutablePath -Algorithm SHA256).Hash.ToLowerInvariant()) 'post-verification payload replacement leaves the installed v1.4.0 executable byte-identical'
  Assert ((Get-ItemProperty -LiteralPath $uninstallKey -ErrorAction Stop).DisplayVersion-eq'1.4.0') 'post-verification payload replacement leaves the Installed Apps version unchanged'
  Assert ([Convert]::ToBase64String($historyBefore)-ceq[Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $dataDir 'history.dat')))-and[Convert]::ToBase64String($sentinelBefore)-ceq[Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $dataDir 'unrelated-sentinel.txt')))) 'post-verification payload replacement preserves history and unrelated user data byte-for-byte'
  Invoke-Button $replacementRejected 'Close';Stop-ProductionApplication;$appProcess=$null
  $settingsPath=Join-Path $dataDir 'settings.ini';$settingsRaw=[regex]::Replace((Get-Content -LiteralPath $settingsPath -Raw),'(?m)^updateLastCheck=\d+$','updateLastCheck=0');[IO.File]::WriteAllText($settingsPath,$settingsRaw,[Text.UTF8Encoding]::new($false))
  $appProcess=Start-Process -FilePath $installedExe -PassThru
  Record 'Production app restarted after rejecting the changed update payload' 'INFO' ([pscustomobject]@{ProcessId=$appProcess.Id;ExecutablePath=$installedExe;Version=(Get-Item $installedExe).VersionInfo.ProductVersion})
  $choice=Find-Dialog 'Eye Break Reminder Update Available' $appProcess.Id 90
  Assert ($choice.WindowTitle-eq'Eye Break Reminder Update') 'production updater rediscovered the stable release after safely rejecting the substituted payload' $choice.WindowTitle
  Save-Screenshot $choice 'production-update-available.png'
  Invoke-Button $choice 'Download & Install'
  $ready=Find-Dialog 'Ready to install.' $appProcess.Id 120
  Assert ((@($ready.Names)-join' ').Contains('(100%)')-and(@($ready.Names)-join' ').Contains('SHA-256 digest matches GitHub')) 'clean retry completes download progress and SHA-256 verification after substitution rejection' ($ready.Names -join ' | ')
  Save-Screenshot $ready 'production-update-ready-to-install.png'
  Invoke-Button $ready 'Install Update'
  $success=Find-Dialog 'Update complete.' 0 180
  Assert ((@($success.Names)-join' ').Contains('Installation progress')) 'production update coordinator reports the completed installer transaction' ($success.Names -join ' | ')
  Save-Screenshot $success 'production-update-result.png'
  Invoke-Button $success 'Close'

  $watch=[Diagnostics.Stopwatch]::StartNew();$running=@();$installedVersion=''
  while($watch.Elapsed.TotalSeconds-lt90){
    $installedVersion=(Get-Item -LiteralPath $installedExe).VersionInfo.ProductVersion
    $running=@(Get-CimInstance Win32_Process -Filter "Name='EyeBreakReminder.exe'" -ErrorAction SilentlyContinue|Where-Object{$_.ExecutablePath-and[IO.Path]::GetFullPath([string]$_.ExecutablePath)-ieq$installedExe})
    if($installedVersion-match'^1\.4\.1(\.0)?$'-and$running.Count){break}
    Start-Sleep -Milliseconds 250
  }
  $newHash=(Get-FileHash -LiteralPath $installedExe -Algorithm SHA256).Hash.ToLowerInvariant()
  $expectedHash=(Get-FileHash -LiteralPath $controlledExecutablePath -Algorithm SHA256).Hash.ToLowerInvariant()
  Assert ($installedVersion-match'^1\.4\.1(\.0)?$') 'the existing installed executable was replaced by the controlled v1.4.1 production successor' $installedVersion
  Assert ($newHash-eq$expectedHash) 'installed production successor is byte-identical to the verified download payload' ([pscustomobject]@{Actual=$newHash;Expected=$expectedHash})
  Assert ($running.Count-gt0-and[int]$running[0].ProcessId-ne$appProcess.Id) 'the updater relaunched a new process from the verified installed path' $running
  Assert ((Get-ItemProperty -LiteralPath $uninstallKey -ErrorAction Stop).DisplayVersion-eq'1.4.1') 'the update maintained the correct Installed Apps version registration'
  Assert ((Get-ItemProperty -LiteralPath $runKeyPath -Name EyeBreakReminder -ErrorAction Stop).EyeBreakReminder-ceq$startupCommand) 'production Preserve Settings updates the startup registration to the new executable at the same installed path'
  $settingsAfter=Read-SettingsMap (Join-Path $dataDir 'settings.ini')
  $keysBefore=@($settingsBefore.Keys|Where-Object{$_-cne'updateLastCheck'}|Sort-Object)
  $settingsMissing=@($keysBefore|Where-Object{-not$settingsAfter.ContainsKey($_)-or[string]$settingsBefore[$_]-cne[string]$settingsAfter[$_]})
  Assert ($settingsMissing.Count-eq0-and$settingsAfter['schedule']-ceq'1'-and$settingsAfter['scheduleMonday']-ceq'1'-and$settingsAfter['scheduleMonday1']-ceq'09001700') 'production Preserve Settings keeps every seeded setting, operating schedule and value in the real settings file (excluding the expected update-check timestamp)' ([pscustomobject]@{Before=$settingsBefore;After=$settingsAfter;MissingOrChanged=$settingsMissing;TimestampMayAdvance=$true;OriginalFileSHA256=$settingsBeforeHash})
  Assert ([Convert]::ToBase64String($historyBefore)-ceq[Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $dataDir 'history.dat')))) 'production Preserve Settings keeps history byte-for-byte'
  Assert ([Convert]::ToBase64String($sentinelBefore)-ceq[Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $dataDir 'unrelated-sentinel.txt')))) 'production update leaves unrelated profile files byte-for-byte unchanged'
  $updatesRoot=Join-Path $dataDir 'updates';$stageWatch=[Diagnostics.Stopwatch]::StartNew()
  while($stageWatch.Elapsed.TotalSeconds-lt20-and(Test-Path -LiteralPath $updatesRoot)-and@(Get-ChildItem -LiteralPath $updatesRoot -Force -ErrorAction SilentlyContinue).Count-gt0){Start-Sleep -Milliseconds 100}
  Assert (-not(Test-Path -LiteralPath $updatesRoot)-or@(Get-ChildItem -LiteralPath $updatesRoot -Force -ErrorAction SilentlyContinue).Count-eq0) 'successful production update cleans its private staging directory'
  $requests=@(Get-Content -LiteralPath $requestLogPath|ForEach-Object{$_|ConvertFrom-Json})
  $apiRequests=@($requests|Where-Object{$_.host-eq'api.github.com'-and$_.path-eq'/repos/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/latest'})
  $assetRequests=@($requests|Where-Object{$_.host-eq'github.com'-and$_.path-eq'/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/download/v1.4.1/EyeBreakReminder-Setup-x64.exe'})
  Assert ($apiRequests.Count-ge2-and$assetRequests.Count-ge1) 'feed log records controlled HTTPS release discovery and the verified installer download' ([pscustomobject]@{APIRequests=$apiRequests.Count;InstallerRequests=$assetRequests.Count;Paths=$requests})
  Record 'Exact in-app production update' 'PASS' ([pscustomobject]@{Baseline='v1.4.0';Updated='v1.4.1';ProcessId=$running[0].ProcessId;InstalledPath=$installedExe;InstalledSHA256=$newHash;InstallerExitStatus='Update complete UI plus file/version/hash/registry verification';PreserveSettings='All persisted setting names/values and history bytes verified; update-check timestamp allowed to advance';Feed='Isolated TLS feed at exact official HTTPS hostnames; temporary test CA is not production signing evidence'})
  $script:resultStatus='PASS'
}
catch { Record 'Overall production-binary update acceptance' 'FAIL' $_.Exception.ToString(); throw }
finally {
  try { Stop-ProductionApplication; Record 'Safe production-app shutdown' 'PASS' } catch {
    Record 'Safe production-app shutdown' 'FAIL' $_.Exception.Message
    foreach($process in @(Get-CimInstance Win32_Process -Filter "Name='EyeBreakReminder.exe'" -ErrorAction SilentlyContinue)){
      try{$processPath=[IO.Path]::GetFullPath([string]$process.ExecutablePath);$installPrefix=$installDir.TrimEnd('\')+'\';if($processPath.StartsWith($installPrefix,[StringComparison]::OrdinalIgnoreCase)){Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop;Record 'Force-stop disposable installation after recorded graceful-shutdown failure' 'INFO' ([pscustomobject]@{Pid=$process.ProcessId;Path=$processPath})}}catch{}
    }
  }
  Remove-Item Env:EBR_TEST_UNVERIFIED_LAUNCH_MARKER -ErrorAction SilentlyContinue
  if ($null -eq $originalInstallerLaunchMarker) { Remove-Item Env:EBR_TEST_INSTALLER_LAUNCH_MARKER -ErrorAction SilentlyContinue } else { $env:EBR_TEST_INSTALLER_LAUNCH_MARKER = $originalInstallerLaunchMarker }
  if($serverProcess){try{if(-not$serverProcess.HasExited){$serverProcess.Kill();[void]$serverProcess.WaitForExit(5000)};$serverStopped=$serverProcess.HasExited;$serverProcess.Dispose();if(-not$serverStopped){throw 'Loopback HTTPS feed did not terminate.'}}catch{Record 'Stop isolated HTTPS feed' 'FAIL' $_.Exception.Message}}
  if($hostsChanged){
    try{[IO.File]::WriteAllBytes($hostsPath,$originalHostsBytes);& ipconfig.exe /flushdns|Out-Null;if($LASTEXITCODE-ne0){throw 'DNS flush after restoring hosts file failed.'};$restored=[IO.File]::ReadAllBytes($hostsPath);$equal=([Convert]::ToBase64String($originalHostsBytes)-ceq[Convert]::ToBase64String($restored));if(-not$equal){throw 'Hosts file did not return byte-for-byte to its original contents.'};$hostsRestoreStatus='PASS';Record 'Restore runner hosts file' 'PASS' ([pscustomobject]@{ByteIdentical=$equal})}catch{$hostsRestoreStatus='FAIL';Record 'Restore runner hosts file' 'FAIL' $_.Exception.Message}
  }else{$hostsRestoreStatus='NOT NEEDED'}
  if($rootThumbprint){
    try{
      $remaining=Get-TemporaryRootCertificate $rootThumbprint
      if($remaining.Present){
        if(-not$script:temporaryRootCertificateRawData-or$remaining.RawDataBase64-cne[Convert]::ToBase64String($script:temporaryRootCertificateRawData)){throw 'The machine root-store certificate does not exactly match the generated disposable test root; refusing cleanup.'}
        $removed=Remove-TemporaryRootCertificate $rootThumbprint $script:temporaryRootCertificateRawData
        if(-not$removed){throw 'The generated disposable root was present but the bounded cleanup worker did not remove it.'}
      }
      $verifiedAbsent=Get-TemporaryRootCertificate $rootThumbprint
      if($verifiedAbsent.Present){throw 'The disposable test root remains in the isolated runner machine root store after bounded cleanup.'}
      $script:temporaryRootCertificateAdded=$false
      $temporaryRootCertificate=$null
      $trustRootCleanupStatus='PASS';Record 'Remove temporary TLS trust root' 'PASS' $rootThumbprint
    }catch{$trustRootCleanupStatus='FAIL';Record 'Remove temporary TLS trust root' 'FAIL' $_.Exception.Message}
  }else{$trustRootCleanupStatus='NOT CREATED'}
  if((Test-Path -LiteralPath $installDir) -and -not $portableRoute){
    try{
      $uninstaller=Join-Path $installDir 'Uninstall.exe'
      if(-not(Test-Path -LiteralPath $uninstaller)){throw 'The candidate installer did not register its normal uninstaller.'}
      $un=Start-Process -FilePath $uninstaller -ArgumentList '/S' -PassThru
      if(-not$un.WaitForExit(90000)){Stop-Process -Id $un.Id -Force -ErrorAction SilentlyContinue;[void]$un.WaitForExit(5000);throw 'Disposable production acceptance uninstall exceeded its ninety-second cleanup bound.'}
      $uninstallExitCode=$un.ExitCode;if($un.ExitCode-ne0){throw "Disposable production acceptance uninstall returned $($un.ExitCode)."}
      $remainingExecutable=Join-Path $installDir 'EyeBreakReminder.exe'
      $removeWatch=[Diagnostics.Stopwatch]::StartNew()
      while((Test-Path -LiteralPath $remainingExecutable)-and$removeWatch.Elapsed.TotalSeconds-lt5){Start-Sleep -Milliseconds 200}
      if(Test-Path -LiteralPath $remainingExecutable){
        $remainingProcesses=@(Get-CimInstance Win32_Process -Filter "Name='EyeBreakReminder.exe'" -ErrorAction SilentlyContinue|Where-Object{try{[IO.Path]::GetFullPath([string]$_.ExecutablePath).StartsWith($installDir.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)}catch{$false}}|ForEach-Object{[pscustomobject]@{ProcessId=$_.ProcessId;ExecutablePath=$_.ExecutablePath;CommandLine=$_.CommandLine}})
        $exclusiveOpen=$false;$exclusiveOpenError=$null;$stream=$null
        try{$stream=[IO.File]::Open($remainingExecutable,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$exclusiveOpen=$true}catch{$exclusiveOpenError=$_.Exception.Message}finally{if($stream){$stream.Dispose()}}
        $remainingFiles=@(Get-ChildItem -LiteralPath $installDir -Force -ErrorAction SilentlyContinue|ForEach-Object{[pscustomobject]@{Name=$_.Name;Length=if(-not$_.PSIsContainer){$_.Length}else{$null}}})
        $registration=Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder' -ErrorAction SilentlyContinue
        $diagnostic=[pscustomobject]@{UninstallerExitCode=$uninstallExitCode;ExecutableStillPresent=$true;ExecutableExclusiveOpen=$exclusiveOpen;ExclusiveOpenError=$exclusiveOpenError;PathScopedProcesses=$remainingProcesses;RemainingFiles=$remainingFiles;UninstallRegistrationPresent=[bool]$registration;RegisteredUninstallString=if($registration){$registration.UninstallString}else{$null}}
        throw "Silent cleanup uninstall left the application executable behind. Diagnostics: $(ConvertTo-Json $diagnostic -Depth 6 -Compress)"
      }
      if(Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder' -ErrorAction SilentlyContinue){throw 'Silent cleanup uninstall left the Installed Apps registration behind.'}
      if(Test-Path -LiteralPath $installDir){Remove-Item -LiteralPath $installDir -Recurse -Force}
      Record 'Disposable production installation cleanup' 'PASS' $uninstallExitCode
    }catch{Record 'Disposable production installation cleanup' 'FAIL' $_.Exception.Message}
  }
  if($startupValueAdded){
    try{
      $currentStartup=Get-ItemProperty -LiteralPath $runKeyPath -Name EyeBreakReminder -ErrorAction SilentlyContinue
      if($null-ne$currentStartup){
        if([string]$currentStartup.EyeBreakReminder-cne$startupCommand){throw 'The Eye Break Reminder startup value changed to an unexpected command; refusing to remove it.'}
        Remove-ItemProperty -LiteralPath $runKeyPath -Name EyeBreakReminder -ErrorAction Stop
      }
      if($runKeyCreated-and(Test-Path -LiteralPath $runKeyPath)){
        $remainingValues=@((Get-ItemProperty -LiteralPath $runKeyPath -ErrorAction SilentlyContinue).PSObject.Properties|Where-Object{$_.Name-notmatch'^PS'})
        if($remainingValues.Count-eq0){Remove-Item -LiteralPath $runKeyPath -Force -ErrorAction Stop}else{Record 'Preserve non-test Windows Run values' 'INFO' ([pscustomobject]@{RemainingValueNames=@($remainingValues|Select-Object -ExpandProperty Name)})}
      }
      Record 'Remove disposable startup registration' 'PASS' 'Only the exact runner-owned Eye Break Reminder command was removed; an already-removed value is accepted.'
    }catch{Record 'Remove disposable startup registration' 'FAIL' $_.Exception.Message}
  }
  if(Test-Path -LiteralPath $dataDir){
    try{$resolved=[IO.Path]::GetFullPath($dataDir);if($resolved-ine$expectedDataDir){throw 'Refusing to remove an unexpected user-data path.'};if((Get-Item -LiteralPath $resolved).Attributes-band[IO.FileAttributes]::ReparsePoint){throw 'Refusing to remove a reparse-point user-data path.'};Remove-Item -LiteralPath $resolved -Recurse -Force;Record 'Remove disposable Eye Break Reminder profile fixture' 'PASS' $resolved}catch{Record 'Remove disposable Eye Break Reminder profile fixture' 'FAIL' $_.Exception.Message}
  }
  try{$resolvedTestRoot=[IO.Path]::GetFullPath($testRoot);if($resolvedTestRoot-ine$testRoot-or-not$resolvedTestRoot.StartsWith($runnerPrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Refusing to remove files outside the isolated production-update runner folder.'};if(Test-Path -LiteralPath $resolvedTestRoot){if((Get-Item -LiteralPath $resolvedTestRoot).Attributes-band[IO.FileAttributes]::ReparsePoint){throw 'Refusing to remove a reparse-point test folder.'};Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force};if(Test-Path -LiteralPath $resolvedTestRoot){throw 'Disposable TLS keys and transaction files remain in RUNNER_TEMP.'};Record 'Remove disposable TLS private keys and test folder' 'PASS' $resolvedTestRoot}catch{Record 'Remove disposable TLS private keys and test folder' 'FAIL' $_.Exception.Message}
  if($hostsRestoreStatus-eq'FAIL'-or$trustRootCleanupStatus-eq'FAIL'-or@($script:events|Where-Object Status -EQ 'FAIL').Count){ $script:resultStatus='FAIL' }
  $script:events.Add([pscustomobject]@{Name='Isolated feed cleanup';Status=$(if($hostsRestoreStatus-ne'FAIL'-and$trustRootCleanupStatus-ne'FAIL'-and$serverStopped){'PASS'}else{'FAIL'});Details=[pscustomobject]@{HostsFile=$hostsRestoreStatus;TemporaryTrustRoot=$trustRootCleanupStatus;ServerProcessStopped=$serverStopped;TestCAOrKeysUploaded=$false};Utc=[DateTime]::UtcNow.ToString('o')})
  $report=[pscustomobject]@{Status=$script:resultStatus;Scenario=$Scenario;Assertions=$script:assertions;RunId=$env:GITHUB_RUN_ID;SourceCommit=$env:GITHUB_SHA;StartedUtc=$startedUtc.ToString('o');CompletedUtc=[DateTime]::UtcNow.ToString('o');CandidateBaselineVersion='1.4.0';ControlledSuccessorVersion='1.4.1';TestTrustAnchor=$rootThumbprint;TemporaryTestRootRemoved=($trustRootCleanupStatus-eq'PASS');HostsRestoredByteIdentically=($hostsRestoreStatus-eq'PASS');ProductionTestEndpointOverrideCompiled=$false;Events=@($script:events)}
  $report|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'production-update-acceptance-results.json') -Encoding UTF8
  try{Stop-Transcript|Out-Null}catch{}
  if ($signedPreserve -and $script:resultStatus -ne 'PASS') { throw 'Exact signed transaction or isolated host cleanup did not pass. See the evidence report.' }
}
