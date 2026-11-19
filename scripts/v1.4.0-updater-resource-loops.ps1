param(
  [string]$GuiTestExecutable = (Join-Path $PSScriptRoot '..\build\gui-test\EyeBreakReminder.exe'),
  [int]$Cycles = 8
)
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$sourceExe = [IO.Path]::GetFullPath($GuiTestExecutable)
$expectedExe = [IO.Path]::GetFullPath((Join-Path $repoRoot 'build\gui-test\EyeBreakReminder.exe'))
if ($sourceExe -ine $expectedExe) { throw 'Refusing to test an executable outside the isolated GUI test build.' }
if ($Cycles -lt 3 -or $Cycles -gt 30) { throw 'Cycles must be between 3 and 30.' }
if (-not [Environment]::UserInteractive) { throw 'An interactive Windows desktop is required for updater resource loops.' }
if (-not (Test-Path -LiteralPath $sourceExe -PathType Leaf)) { throw "The isolated GUI test executable is missing: $sourceExe" }
$version = [Version](Get-Content -LiteralPath (Join-Path $repoRoot 'VERSION') -Raw).Trim()
if ((Get-Item -LiteralPath $sourceExe).VersionInfo.ProductVersion -ne $version.ToString()) { throw 'The GUI test executable version does not match VERSION.' }

# Each run has its own executable copy, response fixture, profile, payload and evidence.
# The test binary is never allowed to use the user's LocalAppData profile.
$runId = [Guid]::NewGuid().ToString('N')
$runRoot = Join-Path $repoRoot "build\v1.4.0-updater-resource-loops-$runId"
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "EyeBreakReminder-v1.4.0-resource-loops-$runId"
$appDirectory = Join-Path $runRoot 'app'
$dataDirectory = Join-Path $tempRoot 'isolated-profile'
$evidenceDirectory = Join-Path $runRoot 'evidence'
[void][IO.Directory]::CreateDirectory($appDirectory)
[void][IO.Directory]::CreateDirectory($tempRoot)
[void][IO.Directory]::CreateDirectory($dataDirectory)
[void][IO.Directory]::CreateDirectory($evidenceDirectory)
$testExe = Join-Path $appDirectory 'EyeBreakReminder.exe'
$coordinatorExe = Join-Path $appDirectory 'coordinator.exe'
[IO.File]::Copy($sourceExe, $testExe, $false)
[IO.File]::Copy($sourceExe, $coordinatorExe, $false)
$sentinelPath = Join-Path $dataDirectory 'resource-loop-sentinel.txt'
$sentinelText = "test-owned profile sentinel $runId`n"
[IO.File]::WriteAllText($sentinelPath,$sentinelText,[Text.UTF8Encoding]::new($false))
$sentinelHash = (Get-FileHash -LiteralPath $sentinelPath -Algorithm SHA256).Hash.ToLowerInvariant()
$sourceHash = (Get-FileHash -LiteralPath $sourceExe -Algorithm SHA256).Hash.ToLowerInvariant()
if ((Get-FileHash -LiteralPath $testExe -Algorithm SHA256).Hash.ToLowerInvariant() -cne $sourceHash -or
    (Get-FileHash -LiteralPath $coordinatorExe -Algorithm SHA256).Hash.ToLowerInvariant() -cne $sourceHash) {
  throw 'The isolated executable copies do not match their GUI test source.'
}

$native = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class EBR_RESOURCE_LOOPS {
  public delegate bool EnumCallback(IntPtr hwnd, IntPtr data);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumCallback callback, IntPtr data);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumCallback callback, IntPtr data);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr parent, int id);
  [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern uint RegisterWindowMessageW(string name);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetWindowTextW(IntPtr hwnd, StringBuilder text, int count);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetClassNameW(IntPtr hwnd, StringBuilder text, int count);
  [DllImport("user32.dll")] public static extern uint GetGuiResources(IntPtr process, uint flags);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr OpenProcess(uint access, bool inherit, uint processId);
  [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr handle);
  public static string Text(IntPtr hwnd) { var text = new StringBuilder(1024); GetWindowTextW(hwnd, text, text.Capacity); return text.ToString(); }
  public static string ClassName(IntPtr hwnd) { var text = new StringBuilder(256); GetClassNameW(hwnd, text, text.Capacity); return text.ToString(); }
  public static IntPtr[] TopWindows(int pid) { var result = new List<IntPtr>(); EnumCallback cb = delegate(IntPtr hwnd, IntPtr ignored) { uint actual; GetWindowThreadProcessId(hwnd, out actual); if (actual == (uint)pid) result.Add(hwnd); return true; }; EnumWindows(cb, IntPtr.Zero); GC.KeepAlive(cb); return result.ToArray(); }
  public static IntPtr[] Children(IntPtr parent) { var result = new List<IntPtr>(); EnumCallback cb = delegate(IntPtr hwnd, IntPtr ignored) { result.Add(hwnd); return true; }; EnumChildWindows(parent, cb, IntPtr.Zero); GC.KeepAlive(cb); return result.ToArray(); }
  public static int ControlId(IntPtr hwnd) { return GetDlgCtrlID(hwnd); }
  public static IntPtr FindChildById(IntPtr parent, int id) { foreach(IntPtr child in Children(parent)) if(GetDlgCtrlID(child)==id) return child; return IntPtr.Zero; }
  [DllImport("user32.dll")] private static extern int GetDlgCtrlID(IntPtr hwnd);
}
'@
Add-Type -TypeDefinition $native -Language CSharp -ErrorAction Stop

$script:rows = [Collections.Generic.List[object]]::new()
$script:appProcess = $null
$script:appPid = 0
$script:mainWindow = [IntPtr]::Zero
$script:responsePath = Join-Path $appDirectory 'test-update-response.txt'
$script:modalDiagnosticPath = Join-Path $appDirectory 'test-update-modal-diagnostic.txt'
$payloadPath = Join-Path $tempRoot 'controlled-payload.bin'
$payloadBytes = 1MB
$payload = [IO.File]::Open($payloadPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try { $payload.SetLength($payloadBytes) } finally { $payload.Dispose() }
$payloadHash = (Get-FileHash -LiteralPath $payloadPath -Algorithm SHA256).Hash.ToLowerInvariant()
$metadataTool = Join-Path $repoRoot 'build\updater-windows-tests.exe'
if (-not (Test-Path -LiteralPath $metadataTool -PathType Leaf)) { throw 'The isolated disposable-key metadata fixture tool was not built.' }
& $metadataTool --create-gui-resource-metadata $appDirectory $payloadHash $payloadBytes
if ($LASTEXITCODE -ne 0) { throw "Could not create the disposable signed GUI resource fixture (exit $LASTEXITCODE)." }

function Get-ProcessSample([string]$Phase, [int]$Cycle) {
  $p = [Diagnostics.Process]::GetProcessById($script:appPid)
  try {
    $p.Refresh()
    $query = [EBR_RESOURCE_LOOPS]::OpenProcess(0x0400, $false, [uint32]$script:appPid)
    if ($query -eq [IntPtr]::Zero) { throw 'Could not query isolated GUI process resources.' }
    try {
      [pscustomobject]@{
        Cycle=$Cycle; Phase=$Phase; Utc=[DateTime]::UtcNow.ToString('o')
        ProcessId=$script:appPid; HandleCount=$p.HandleCount
        PrivateBytes=$p.PrivateMemorySize64; WorkingSetBytes=$p.WorkingSet64
        GdiObjects=[EBR_RESOURCE_LOOPS]::GetGuiResources($query, 0)
        UserObjects=[EBR_RESOURCE_LOOPS]::GetGuiResources($query, 1)
      }
    } finally { [void][EBR_RESOURCE_LOOPS]::CloseHandle($query) }
  } finally { $p.Dispose() }
}
function Get-HarnessHandleCount {
  $p=[Diagnostics.Process]::GetCurrentProcess()
  try{$p.Refresh();$p.HandleCount}finally{$p.Dispose()}
}
function Get-Slope([object[]]$Samples, [string]$Property) {
  if ($Samples.Count -lt 3) { return [double]::PositiveInfinity }
  # Ignore the first measured point when fitting a sustained slope. Some native
  # controls allocate one lazy process-wide resource on their first interaction.
  $stableSamples=@($Samples | Select-Object -Skip 1)
  $ys = [double[]]@($stableSamples | ForEach-Object { [double]$_.PSObject.Properties[$Property].Value })
  $n=$ys.Count; $meanX=($n+1)/2.0; $meanY=($ys|Measure-Object -Average).Average; $num=0.0; $den=0.0
  for($i=0;$i -lt $n;$i++){ $x=$i+1; $num+=($x-$meanX)*($ys[$i]-$meanY); $den+=($x-$meanX)*($x-$meanX) }
  [Math]::Round($num/[Math]::Max(1.0,$den),5)
}
function Find-TopWindow([int]$ProcessId, [string]$Title, [int]$TimeoutSeconds=12) {
  $watch=[Diagnostics.Stopwatch]::StartNew()
  while($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
    foreach($hwnd in [EBR_RESOURCE_LOOPS]::TopWindows($ProcessId)) {
      if([EBR_RESOURCE_LOOPS]::IsWindowVisible($hwnd) -and [EBR_RESOURCE_LOOPS]::Text($hwnd) -ceq $Title) { return $hwnd }
    }
    Start-Sleep -Milliseconds 25
  }
  $windows=@([EBR_RESOURCE_LOOPS]::TopWindows($ProcessId)|ForEach-Object{$hwnd=$_;[pscustomobject]@{Title=[EBR_RESOURCE_LOOPS]::Text($hwnd);Class=[EBR_RESOURCE_LOOPS]::ClassName($hwnd);Visible=[EBR_RESOURCE_LOOPS]::IsWindowVisible($hwnd);Children=(Get-DescendantTexts $hwnd)-join ' | '}})|ConvertTo-Json -Compress -Depth 5
  $status=if($script:mainWindow-ne[IntPtr]::Zero){(Get-DescendantTexts $script:mainWindow)-join ' | '}else{''}
  $fixture=if($script:responsePath-and(Test-Path -LiteralPath $script:responsePath)){[IO.File]::ReadAllText($script:responsePath)}else{''}
  $modalDiagnostic=if($script:modalDiagnosticPath-and(Test-Path -LiteralPath $script:modalDiagnosticPath)){[IO.File]::ReadAllText($script:modalDiagnosticPath)}else{'<none>'}
  if($fixture.Length-gt 700){$fixture=$fixture.Substring(0,700)}
  throw "Timed out waiting for '$Title' from process $ProcessId. MainStatus='$status'; top-level windows=$windows; fixture='$fixture'; modalDiagnostic='$modalDiagnostic'."
}
function Get-ControlText([IntPtr]$Window, [int]$ControlId) {
  $control=[EBR_RESOURCE_LOOPS]::FindChildById($Window,$ControlId)
  if($control -eq [IntPtr]::Zero) { return '' }
  [EBR_RESOURCE_LOOPS]::Text($control)
}
function Get-DescendantTexts([IntPtr]$Window) {
  @([EBR_RESOURCE_LOOPS]::Children($Window) | ForEach-Object { [EBR_RESOURCE_LOOPS]::Text($_) } | Where-Object { $_ })
}
function Get-TopWindowDiagnostics {
  @([EBR_RESOURCE_LOOPS]::TopWindows($script:appPid) | ForEach-Object {
    $h=$_
    [pscustomobject]@{Title=[EBR_RESOURCE_LOOPS]::Text($h);Class=[EBR_RESOURCE_LOOPS]::ClassName($h);Visible=[EBR_RESOURCE_LOOPS]::IsWindowVisible($h);Children=(Get-DescendantTexts $h) -join ' | '}
  })
}
function Wait-Idle([IntPtr]$CheckButton, [int]$TimeoutSeconds=15) {
  $watch=[Diagnostics.Stopwatch]::StartNew()
  while($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
    if([EBR_RESOURCE_LOOPS]::IsWindowEnabled($CheckButton)) { Start-Sleep -Milliseconds 250; return }
    Start-Sleep -Milliseconds 25
  }
  throw 'The isolated app update check did not return to idle.'
}
function Wait-DownloadFailureCleanup([IntPtr]$CheckButton, [int]$TimeoutSeconds=20) {
  $watch=[Diagnostics.Stopwatch]::StartNew();$updates=Join-Path $dataDirectory 'updates'
  while($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
    $remaining=if(Test-Path -LiteralPath $updates -PathType Container){@(Get-ChildItem -LiteralPath $updates -Force)}else{@()}
    $status=(Get-DescendantTexts $script:mainWindow) -join ' '
    if([EBR_RESOURCE_LOOPS]::IsWindowEnabled($CheckButton) -and $remaining.Count -eq 0 -and $status.Contains('The update was not installed.')){return}
    Start-Sleep -Milliseconds 50
  }
  throw 'The cancelled or rejected update did not finish application cleanup.'
}
function Write-CheckFailureFixture {
  $body = '{"tag_name":"v'+$version+'","draft":false,"prerelease":false,"body":"controlled resource failure","assets":[]}'
  [IO.File]::WriteAllText($script:responsePath,"status=503`r`nfailure=none`r`n`r`n$body",[Text.UTF8Encoding]::new($false))
}
function Write-UpdateFixture([bool]$BadDigest) {
  $stream = [IO.File]::Open($payloadPath, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::Read)
  try { $stream.SetLength(0); $stream.SetLength($payloadBytes); if($BadDigest){$stream.Position=0;$stream.WriteByte(1)} } finally { $stream.Dispose() }
  $manifestPath=Join-Path $appDirectory 'EyeBreakReminder-UpdateManifest.json'
  $signaturePath=Join-Path $appDirectory 'EyeBreakReminder-UpdateManifest.sig'
  $manifest=Get-Item -LiteralPath $manifestPath;$signature=Get-Item -LiteralPath $signaturePath
  $assets=@(
    [ordered]@{name='EyeBreakReminder.exe';browser_download_url='https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/download/v1.4.1/EyeBreakReminder.exe';size=$payloadBytes;digest="sha256:$payloadHash"},
    [ordered]@{name='EyeBreakReminder-UpdateManifest.json';browser_download_url='https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/download/v1.4.1/EyeBreakReminder-UpdateManifest.json';size=$manifest.Length;digest=('sha256:'+(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant())},
    [ordered]@{name='EyeBreakReminder-UpdateManifest.sig';browser_download_url='https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/download/v1.4.1/EyeBreakReminder-UpdateManifest.sig';size=$signature.Length;digest=('sha256:'+(Get-FileHash -LiteralPath $signaturePath -Algorithm SHA256).Hash.ToLowerInvariant())}
  )
  $release=[ordered]@{tag_name='v1.4.1';html_url='https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/tag/v1.4.1';draft=$false;prerelease=$false;body='Controlled resource-loop fixture. No public release is created.';assets=$assets}
  [IO.File]::WriteAllText($script:responsePath,"status=200`r`nfailure=none`r`n`r`n$($release|ConvertTo-Json -Compress -Depth 6)",[Text.UTF8Encoding]::new($false))
}
function Write-DnsFailureFixture {
  [IO.File]::WriteAllText($script:responsePath,"status=200`r`nfailure=dns`r`n`r`n{}",[Text.UTF8Encoding]::new($false))
}
function Get-MainTimerSeconds {
  $text=Get-ControlText $script:mainWindow 40
  if($text -notmatch '^(\d+):(\d{2})$'){throw "The isolated application timer text is invalid: '$text'."}
  ([int]$Matches[1]*60)+[int]$Matches[2]
}
function Run-DnsFailureAndSignedRetry([IntPtr]$CheckButton) {
  $initialTimer=Get-MainTimerSeconds
  Write-DnsFailureFixture;Trigger-Check $CheckButton;Wait-Idle $CheckButton 15
  $status=(Get-DescendantTexts $script:mainWindow) -join ' '
  if(-not $status.Contains('Could not reach GitHub')){throw "The app did not show a meaningful DNS failure: $status"}
  # The update controls live on Settings. Return to the timer page so the visible countdown is refreshed while the engine continues.
  [void][EBR_RESOURCE_LOOPS]::SendMessageW([EBR_RESOURCE_LOOPS]::GetDlgItem($script:mainWindow,10),0x00F5,[IntPtr]::Zero,[IntPtr]::Zero)
  $watch=[Diagnostics.Stopwatch]::StartNew();$timerAdvanced=$false
  while($watch.Elapsed.TotalSeconds -lt 8){if((Get-MainTimerSeconds) -lt $initialTimer){$timerAdvanced=$true;break};Start-Sleep -Milliseconds 100}
  if(-not $timerAdvanced){throw 'The active timer did not progress while the DNS failure was handled.'}
  if(@(Get-Process -Name coordinator -ErrorAction SilentlyContinue | Where-Object { try {[IO.Path]::GetFullPath($_.Path) -ieq $coordinatorExe} catch {$false} }).Count){throw 'A coordinator launched after genuine update-origin DNS failure.'}
  $appHash=(Get-FileHash -LiteralPath $testExe -Algorithm SHA256).Hash.ToLowerInvariant()
  if($appHash -cne $sourceHash){throw 'The existing app changed after the genuine DNS failure.'}
  $settingsNav=[EBR_RESOURCE_LOOPS]::GetDlgItem($script:mainWindow,12)
  if($settingsNav -eq [IntPtr]::Zero){throw 'Could not return to Settings after verifying timer progress.'}
  [void][EBR_RESOURCE_LOOPS]::SendMessageW($settingsNav,0x00F5,[IntPtr]::Zero,[IntPtr]::Zero)
  if(-not [EBR_RESOURCE_LOOPS]::IsWindowVisible($CheckButton)){throw 'The isolated update-check control was not visible after returning to Settings.'}
  Write-UpdateFixture $false;Trigger-Check $CheckButton
  try { $choice=Find-TopWindow $script:appPid 'Eye Break Reminder Update' }
  catch { $status=(Get-DescendantTexts $script:mainWindow) -join ' | ';$windows=Get-TopWindowDiagnostics | ConvertTo-Json -Compress -Depth 5;$modalDiagnostic=if(Test-Path -LiteralPath $script:modalDiagnosticPath){[IO.File]::ReadAllText($script:modalDiagnosticPath)}else{'<none>'};throw "$($_.Exception.Message) Retry status='$status'; top-level windows=$windows; fixtureBytes=$((Get-Item -LiteralPath $script:responsePath).Length); modalDiagnostic='$modalDiagnostic'." }
  $body=Get-ControlText $choice 12321
  if(-not $body.Contains('Available version: v1.4.1')){throw "A valid signed retry did not present the successor version: $body"}
  $later=[EBR_RESOURCE_LOOPS]::GetDlgItem($choice,12002)
  if($later -eq [IntPtr]::Zero){throw 'The valid signed retry did not expose its Later action.'}
  [void][EBR_RESOURCE_LOOPS]::SendMessageW($later,0x00F5,[IntPtr]::Zero,[IntPtr]::Zero)
  Wait-Idle $CheckButton
  if((Get-FileHash -LiteralPath $testExe -Algorithm SHA256).Hash.ToLowerInvariant() -cne $sourceHash){throw 'The existing app changed after the successful signed retry was deferred.'}
  if((Get-FileHash -LiteralPath $sentinelPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $sentinelHash){throw 'The isolated profile sentinel changed during DNS failure and signed retry.'}
  $updates=Join-Path $dataDirectory 'updates';if(Test-Path -LiteralPath $updates){$remaining=@(Get-ChildItem -LiteralPath $updates -Force);if($remaining.Count){throw 'A deferred signed retry left an update transaction staged.'}}
  $script:rows.Add([pscustomobject]@{Cycle=0;Phase='DnsFailureThenSignedRetry';Utc=[DateTime]::UtcNow.ToString('o');DnsErrorShown=$true;TimerAdvanced=$timerAdvanced;SignedRetryPresented=$true;ExistingExecutableUnchanged=$true})
}
function Trigger-Check([IntPtr]$Button) {
  if(-not [EBR_RESOURCE_LOOPS]::IsWindowEnabled($Button)){throw 'The update check button was not idle.'}
  if(-not [EBR_RESOURCE_LOOPS]::IsWindowVisible($Button)){throw 'The update check button is hidden; select Settings before using it.'}
  [void][EBR_RESOURCE_LOOPS]::SendMessageW($Button,0x00F5,[IntPtr]::Zero,[IntPtr]::Zero)
}
function Open-Download([IntPtr]$Button) {
  Trigger-Check $Button
  $choice=Find-TopWindow $script:appPid 'Eye Break Reminder Update'
  $downloadAndInstall=[EBR_RESOURCE_LOOPS]::GetDlgItem($choice,12001)
  if($downloadAndInstall -eq [IntPtr]::Zero){throw 'Update choice did not expose its Download & Install button.'}
  [void][EBR_RESOURCE_LOOPS]::SendMessageW($downloadAndInstall,0x00F5,[IntPtr]::Zero,[IntPtr]::Zero)
  Find-TopWindow $script:appPid 'Eye Break Reminder Update'
}
function Wait-DownloadModal([string]$RequiredText, [int]$TimeoutSeconds=30) {
  $watch=[Diagnostics.Stopwatch]::StartNew()
  while($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
    foreach($hwnd in [EBR_RESOURCE_LOOPS]::TopWindows($script:appPid)) {
      if(-not [EBR_RESOURCE_LOOPS]::IsWindowVisible($hwnd) -or [EBR_RESOURCE_LOOPS]::Text($hwnd) -cne 'Eye Break Reminder Update'){continue}
      $body=Get-ControlText $hwnd 12321
      if($body.Contains($RequiredText)){return [pscustomobject]@{Window=$hwnd;Body=$body}}
    }
    Start-Sleep -Milliseconds 25
  }
  throw "Timed out waiting for download modal text '$RequiredText'."
}
function Wait-EnabledControl([IntPtr]$Window, [int]$ControlId, [int]$TimeoutSeconds=5) {
  $watch=[Diagnostics.Stopwatch]::StartNew()
  while($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
    $control=[EBR_RESOURCE_LOOPS]::GetDlgItem($Window,$ControlId)
    if($control -ne [IntPtr]::Zero -and [EBR_RESOURCE_LOOPS]::IsWindowEnabled($control)){return $control}
    Start-Sleep -Milliseconds 25
  }
  throw "Control $ControlId did not become enabled after the download result appeared."
}
function Run-CancelCycle([IntPtr]$CheckButton, [int]$Cycle, [string]$Phase) {
  Write-UpdateFixture $false
  $null=Open-Download $CheckButton
  $watch=[Diagnostics.Stopwatch]::StartNew();$cancelled=$false;$observed=[Collections.Generic.List[string]]::new()
  while($watch.Elapsed.TotalSeconds -lt 10) {
    foreach($hwnd in [EBR_RESOURCE_LOOPS]::TopWindows($script:appPid)) {
      if([EBR_RESOURCE_LOOPS]::Text($hwnd) -cne 'Eye Break Reminder Update'){continue}
      $body=Get-ControlText $hwnd 12321
      if($body -and ($observed.Count -eq 0 -or $observed[$observed.Count-1] -cne $body)){$observed.Add($body)}
      $received=0.0
      if($body -match 'Downloaded:\s+([\d.]+)\s+(KB|MB)\s*/') { $received=[double]$Matches[1] }
      if($received -gt 0 -and $body -notmatch '\(100%\)') {
        $cancel=[EBR_RESOURCE_LOOPS]::GetDlgItem($hwnd,12202)
        if($cancel -eq [IntPtr]::Zero){throw 'Download modal has no Cancel control.'}
        [void][EBR_RESOURCE_LOOPS]::SendMessageW($cancel,0x00F5,[IntPtr]::Zero,[IntPtr]::Zero)
        $cancelled=$true;break
      }
    }
    if($cancelled){break};Start-Sleep -Milliseconds 25
  }
  if(-not $cancelled){throw "The 1 MiB fixture completed before cancellation; observed modal text: $($observed -join ' | ')"}
  $result=Wait-DownloadModal 'Download cancelled.'
  $close=Wait-EnabledControl $result.Window 12202
  [void][EBR_RESOURCE_LOOPS]::SendMessageW($close,0x00F5,[IntPtr]::Zero,[IntPtr]::Zero)
  Wait-DownloadFailureCleanup $CheckButton
  $updates=Join-Path $dataDirectory 'updates'
  $remaining=if(Test-Path -LiteralPath $updates -PathType Container){@(Get-ChildItem -LiteralPath $updates -Force)}else{@()}
  if($remaining.Count -ne 0){throw 'Cancelled download left staged files behind.'}
  if(@(Get-Process -Name coordinator -ErrorAction SilentlyContinue | Where-Object { try {[IO.Path]::GetFullPath($_.Path) -ieq $coordinatorExe} catch {$false} }).Count){throw 'A coordinator launched after download cancellation.'}
  $sample=Get-ProcessSample $Phase $Cycle;$script:rows.Add($sample)
}
function Run-HashFailureCycle([IntPtr]$CheckButton, [int]$Cycle) {
  Write-UpdateFixture $true
  $null=Open-Download $CheckButton
  $result=Wait-DownloadModal 'failed its SHA-256 integrity check.' 30
  $cancel=Wait-EnabledControl $result.Window 12202
  [void][EBR_RESOURCE_LOOPS]::SendMessageW($cancel,0x00F5,[IntPtr]::Zero,[IntPtr]::Zero)
  Wait-DownloadFailureCleanup $CheckButton
  $updates=Join-Path $dataDirectory 'updates'
  $remaining=if(Test-Path -LiteralPath $updates -PathType Container){@(Get-ChildItem -LiteralPath $updates -Force)}else{@()}
  if($remaining.Count -ne 0){throw 'Hash failure left a partial or unverified payload staged.'}
  if(@(Get-Process -Name coordinator -ErrorAction SilentlyContinue | Where-Object { try {[IO.Path]::GetFullPath($_.Path) -ieq $coordinatorExe} catch {$false} }).Count){throw 'A coordinator launched after hash verification failed.'}
  $sample=Get-ProcessSample 'DownloadHashRejected' $Cycle;$script:rows.Add($sample)
}
function Run-RecoveryCoordinatorLoops {
  $missingTransaction=Join-Path $runRoot 'deliberately-missing-transaction.ini'
  if(Test-Path -LiteralPath $missingTransaction){throw 'The coordinator fixture must not exist.'}
  $samples=[Collections.Generic.List[object]]::new()
  for($i=1;$i -le $Cycles;$i++){
    $p=Start-Process -FilePath $coordinatorExe -ArgumentList ('--update-recover "'+$missingTransaction+'"') -PassThru
    try{
      $window=Find-TopWindow $p.Id 'Eye Break Reminder Recovery'
      $process=[Diagnostics.Process]::GetProcessById($p.Id)
      try{
        $process.Refresh();$query=[EBR_RESOURCE_LOOPS]::OpenProcess(0x0400,$false,[uint32]$p.Id)
        if($query -eq [IntPtr]::Zero){throw 'Could not query isolated coordinator resources.'}
        try{
          if([IO.Path]::GetFullPath($process.Path) -ine $coordinatorExe){throw 'The recovery helper process identity differs from the isolated coordinator copy.'}
          $samples.Add([pscustomobject]@{Cycle=$i;ProcessId=$p.Id;Handles=$process.HandleCount;PrivateBytes=$process.PrivateMemorySize64;GdiObjects=[EBR_RESOURCE_LOOPS]::GetGuiResources($query,0);UserObjects=[EBR_RESOURCE_LOOPS]::GetGuiResources($query,1)})
        }
        finally{[void][EBR_RESOURCE_LOOPS]::CloseHandle($query);$process.Dispose()}
      }catch{throw}
      [void][EBR_RESOURCE_LOOPS]::PostMessageW($window,0x0010,[IntPtr]::Zero,[IntPtr]::Zero)
      if(-not $p.WaitForExit(10000)){throw 'Invalid-record recovery helper did not close after its message was dismissed.'}
      if($p.ExitCode -ne 2){throw "Invalid-record recovery helper returned $($p.ExitCode), expected 2."}
      $exitCode=$p.ExitCode
      if(Get-Process -Id $p.Id -ErrorAction SilentlyContinue){throw 'A recovery helper process remained after its expected rejection.'}
    }finally{$p.Dispose()}
    $script:rows.Add([pscustomobject]@{Cycle=$i;Phase='CoordinatorRejected';Utc=[DateTime]::UtcNow.ToString('o');CoordinatorProcessExited=$true;ExitCode=$exitCode})
  }
  if(Test-Path -LiteralPath $missingTransaction){throw 'A malformed recovery launch unexpectedly created transaction data.'}
  return $samples.ToArray()
}

try {
  $existing=@(Get-Process -Name EyeBreakReminder -ErrorAction SilentlyContinue | Where-Object { try {[IO.Path]::GetFullPath($_.Path) -ieq $testExe} catch {$false} })
  if($existing.Count){throw 'This isolated test executable is already running; refusing to reuse its profile.'}
  $env:EBR_GUI_TEST_DATA_DIRECTORY=$dataDirectory
  $env:EBR_GUI_TEST_UPDATE_ASSET_PATH=$payloadPath
  $env:EBR_GUI_TEST_UPDATE_DELAY_MS='200'
  $script:appProcess=Start-Process -FilePath $testExe -PassThru
  $script:appPid=$script:appProcess.Id
  $script:mainWindow=Find-TopWindow $script:appPid 'Eye Break Reminder' 20
  if([IO.Path]::GetFullPath((Get-Process -Id $script:appPid).Path) -ine $testExe){throw 'The running GUI process does not match the isolated executable copy.'}
  [void][EBR_RESOURCE_LOOPS]::SendMessageW([EBR_RESOURCE_LOOPS]::GetDlgItem($script:mainWindow,12),0x00F5,[IntPtr]::Zero,[IntPtr]::Zero)
  [void][EBR_RESOURCE_LOOPS]::SendMessageW([EBR_RESOURCE_LOOPS]::GetDlgItem($script:mainWindow,135),0x00F5,[IntPtr]::Zero,[IntPtr]::Zero)
  $check=[EBR_RESOURCE_LOOPS]::FindChildById($script:mainWindow,160)
  if($check -eq [IntPtr]::Zero){throw 'Could not find the update-check button in the isolated test app.'}
  # Warm up the worker, theme controls, modal and allocator before taking trend samples.
  for($i=1;$i -le 3;$i++){Write-CheckFailureFixture;Trigger-Check $check;Wait-Idle $check;Start-Sleep -Milliseconds 100}
  Run-CancelCycle $check 0 'WarmupCancellation' | Out-Null
  $script:rows.Clear()
  Run-HashFailureCycle $check 0 | Out-Null
  $script:rows.Clear()
  Run-DnsFailureAndSignedRetry $check
  $failureSamples=[Collections.Generic.List[object]]::new()
  for($i=1;$i -le $Cycles;$i++){
    Write-CheckFailureFixture;Trigger-Check $check;Wait-Idle $check
    $statusTexts=Get-DescendantTexts $script:mainWindow
    if(-not (($statusTexts -join ' ') -match 'HTTP 503')){throw "The failed update check did not expose an actionable HTTP 503 message: $($statusTexts -join ' | ')"}
    $sample=Get-ProcessSample 'UpdateCheckFailed' $i;$failureSamples.Add($sample);$script:rows.Add($sample)
  }
  $cancelSamples=[Collections.Generic.List[object]]::new()
  for($i=1;$i -le $Cycles;$i++){Run-CancelCycle $check $i 'DownloadCancelled';$cancelSamples.Add($script:rows[$script:rows.Count-1])}
  $hashSamples=[Collections.Generic.List[object]]::new()
  for($i=1;$i -le $Cycles;$i++){Run-HashFailureCycle $check $i;$hashSamples.Add($script:rows[$script:rows.Count-1])}
  $coordinatorSamples=Run-RecoveryCoordinatorLoops
  if((Get-FileHash -LiteralPath $sentinelPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $sentinelHash){throw 'An isolated user-profile sentinel changed during the updater failure loops.'}
  if((Get-FileHash -LiteralPath $testExe -Algorithm SHA256).Hash.ToLowerInvariant() -cne $sourceHash){throw 'The isolated GUI executable changed during repeated failed update attempts.'}
  $resourceProperties=@('HandleCount','GdiObjects','UserObjects','PrivateBytes','WorkingSetBytes')
  $slopeThresholds=[ordered]@{HandleCount=0.15;GdiObjects=0.15;UserObjects=0.15;PrivateBytes=65536}
  $slopes=[ordered]@{}
  $netGrowth=[ordered]@{}
  foreach($group in @(
    [pscustomobject]@{Name='CheckFailure';Rows=$failureSamples.ToArray()},
    [pscustomobject]@{Name='DownloadCancellation';Rows=$cancelSamples.ToArray()},
    [pscustomobject]@{Name='HashFailure';Rows=$hashSamples.ToArray()}
  )) {
    foreach($property in $resourceProperties){
      $key="$($group.Name).$property";$slopes[$key]=Get-Slope $group.Rows $property
      $values=@($group.Rows|ForEach-Object{[double]$_.PSObject.Properties[$property].Value})
      $netGrowth[$key]=[Math]::Round($values[-1]-$values[0],2)
    }
  }
  $violations=[Collections.Generic.List[object]]::new()
  foreach($entry in $slopes.GetEnumerator()){
    $metricProperty=$entry.Key.Split('.')[-1]
    if(-not $slopeThresholds.Contains($metricProperty)){continue}
    $threshold=$slopeThresholds[$metricProperty]
    $sustained=$entry.Value -gt $threshold
    if($metricProperty -in @('HandleCount','GdiObjects','UserObjects')){$sustained=$sustained -and $netGrowth[$entry.Key] -gt 1}
    if($sustained){$violations.Add([pscustomobject]@{Metric=$entry.Key;SlopePerCycle=$entry.Value;NetGrowth=$netGrowth[$entry.Key];ThresholdPerCycle=$threshold})}
  }
  $coordinatorSlopes=[ordered]@{}
  foreach($property in @('Handles','GdiObjects','UserObjects','PrivateBytes')){$coordinatorSlopes[$property]=Get-Slope $coordinatorSamples $property}
  $caption='Microsoft Windows NT '+[Environment]::OSVersion.Version.ToString()+'; '+[Runtime.InteropServices.RuntimeInformation]::OSArchitecture
  $report=[ordered]@{
    Status=$(if($violations.Count -eq 0){'PASS'}else{'FAIL'});Environment=$caption;SourceVersion=$version.ToString()
    TestFixture='EYEBREAK_TEST_BUILD copy only; one 1 MiB zero-filled local payload; no public release or production binary used'
    TestExecutableSHA256=$sourceHash;ExecutableCopySHA256=(Get-FileHash -LiteralPath $testExe -Algorithm SHA256).Hash.ToLowerInvariant()
    IsolatedProfile=$dataDirectory;ProfileSentinelSHA256=$sentinelHash;ProfileSentinelUnchanged=$true;CyclesPerGuiScenario=$Cycles;RepeatedCoordinatorRejections=$coordinatorSamples.Count
    ResourceSlopePerCycle=$slopes;ResourceNetGrowth=$netGrowth;SlopeThresholdPerMetric=$slopeThresholds;WorkingSetSlope='Recorded for review; not used as a leak gate because resident-page changes are environment-dependent'
    CoordinatorResourceSlopeAcrossLaunches=$coordinatorSlopes;CoordinatorPrivateBytesAndObjectCounts=$true
    OneTimeNativeLazyInitializationToleranceObjects=1;Violations=$violations
    CoordinatorResourceSamples=$coordinatorSamples;Rows=$script:rows.ToArray();HostRestarted=$false
  }
  $report | ConvertTo-Json -Depth 9 | Set-Content -LiteralPath (Join-Path $evidenceDirectory 'updater-resource-loops.json') -Encoding UTF8
  $script:rows | Export-Csv -LiteralPath (Join-Path $evidenceDirectory 'updater-resource-loops.csv') -NoTypeInformation -Encoding utf8
  $report | ConvertTo-Json -Depth 4
  if($violations.Count){throw 'At least one updater GUI resource slope exceeded its object/handle or 64 KiB private-memory per-cycle threshold.'}
} finally {
  [Environment]::SetEnvironmentVariable('EBR_GUI_TEST_UPDATE_DELAY_MS',$null,'Process')
  if($script:responsePath -and (Test-Path -LiteralPath $script:responsePath)){Remove-Item -LiteralPath $script:responsePath -Force}
  if($script:modalDiagnosticPath -and (Test-Path -LiteralPath $script:modalDiagnosticPath)){Remove-Item -LiteralPath $script:modalDiagnosticPath -Force}
  if($script:appPid -and $script:mainWindow -ne [IntPtr]::Zero){
    $quit=[EBR_RESOURCE_LOOPS]::RegisterWindowMessageW('EyeBreakReminder.Exit.Native.1')
    [void][EBR_RESOURCE_LOOPS]::PostMessageW($script:mainWindow,$quit,[IntPtr]::Zero,[IntPtr]::Zero)
    if($script:appProcess -and -not $script:appProcess.WaitForExit(10000)){throw 'The isolated diagnostic app did not exit via its normal Exit message.'}
  }
  if($script:appProcess){$script:appProcess.Dispose()}
}
