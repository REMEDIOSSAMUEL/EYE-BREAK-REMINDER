param(
  [string]$Executable = (Join-Path $PSScriptRoot '..\build\gui-test\EyeBreakReminder.exe'),
  [string]$EvidenceDirectory = (Join-Path $PSScriptRoot '..\build\v1.4.0-gui-handle-diagnostic')
)
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$exePath = [IO.Path]::GetFullPath($Executable)
$expectedExe = [IO.Path]::GetFullPath((Join-Path $repoRoot 'build\gui-test\EyeBreakReminder.exe'))
$dataDirectory = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $exePath) 'test-data'))
if ($exePath -ine $expectedExe -or $dataDirectory -ine [IO.Path]::GetFullPath((Join-Path $repoRoot 'build\gui-test\test-data'))) {
  throw 'Refusing to run the resource diagnostic outside the isolated GUI test executable and data directory.'
}
if (-not [Environment]::UserInteractive) { throw 'An interactive Windows desktop is required for the targeted GUI resource diagnostic.' }
if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) { throw "GUI test executable is missing: $exePath" }

$native = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class EBR_HANDLE_DIAGNOSTIC {
  public delegate bool EnumCallback(IntPtr hwnd, IntPtr data);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumCallback callback, IntPtr data);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumCallback callback, IntPtr data);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
  [DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr parent, int id);
  [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern uint RegisterWindowMessageW(string name);
  [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetWindowTextW(IntPtr hwnd, StringBuilder text, int count);
  public static string Text(IntPtr hwnd) { var text = new StringBuilder(512); GetWindowTextW(hwnd, text, text.Capacity); return text.ToString(); }
  public static IntPtr[] TopWindows(int pid) { var result = new List<IntPtr>(); EnumCallback cb = delegate(IntPtr hwnd, IntPtr ignored) { uint actual; GetWindowThreadProcessId(hwnd, out actual); if (actual == (uint)pid) result.Add(hwnd); return true; }; EnumWindows(cb, IntPtr.Zero); GC.KeepAlive(cb); return result.ToArray(); }
  public static IntPtr[] Children(IntPtr parent) { var result = new List<IntPtr>(); EnumCallback cb = delegate(IntPtr hwnd, IntPtr ignored) { result.Add(hwnd); return true; }; EnumChildWindows(parent, cb, IntPtr.Zero); GC.KeepAlive(cb); return result.ToArray(); }
}
'@
Add-Type -TypeDefinition $native -Language CSharp -ErrorAction Stop
[void][IO.Directory]::CreateDirectory($EvidenceDirectory)
[void][IO.Directory]::CreateDirectory($dataDirectory)
foreach ($name in @('settings.ini','timer.dat','history.dat')) {
  $path = Join-Path $dataDirectory $name
  if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
}

$script:testPid = 0
$script:main = [IntPtr]::Zero
$script:process = $null
$script:rows = [Collections.Generic.List[object]]::new()
$script:fixture = Join-Path (Split-Path -Parent $exePath) 'test-update-response.txt'
$baseVersion = [Version](Get-Content -LiteralPath (Join-Path $repoRoot 'VERSION') -Raw).Trim()
if ((Get-Item -LiteralPath $exePath).VersionInfo.ProductVersion -ne $baseVersion.ToString()) { throw 'GUI test executable version does not match VERSION.' }

function Get-ReleaseBody([string]$Tag) {
  $download = "https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/download/v$Tag/"
  $assets = @(
    [ordered]@{name='EyeBreakReminder-Setup-x64.exe';browser_download_url=($download+'EyeBreakReminder-Setup-x64.exe');size=2097152;digest=('sha256:'+('a'*64))},
    [ordered]@{name='EyeBreakReminder.exe';browser_download_url=($download+'EyeBreakReminder.exe');size=1048576;digest=('sha256:'+('a'*64))}
  )
  [ordered]@{tag_name="v$Tag";html_url="https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/tag/v$Tag";draft=$false;prerelease=$false;body='Controlled resource diagnostic';assets=$assets} | ConvertTo-Json -Compress -Depth 6
}
function Write-ReleaseFixture([string]$Tag) {
  $body = Get-ReleaseBody $Tag
  [IO.File]::WriteAllText($script:fixture,"status=200`r`nfailure=none`r`ndelay_ms=100`r`n`r`n$body",[Text.UTF8Encoding]::new($false))
}
function Get-Sample([int]$cycle,[string]$phase) {
  $p = [Diagnostics.Process]::GetProcessById($script:testPid)
  try { $p.Refresh(); [pscustomobject]@{Cycle=$cycle;Phase=$phase;Utc=[DateTime]::UtcNow.ToString('o');HandleCount=$p.HandleCount;PrivateBytes=$p.PrivateMemorySize64;WorkingSetBytes=$p.WorkingSet64} }
  finally { $p.Dispose() }
}
function Find-MainWindow {
  foreach ($h in [EBR_HANDLE_DIAGNOSTIC]::TopWindows($script:testPid)) { if ([EBR_HANDLE_DIAGNOSTIC]::IsWindowVisible($h) -and [EBR_HANDLE_DIAGNOSTIC]::Text($h) -eq 'Eye Break Reminder') { return $h } }
  [IntPtr]::Zero
}
function Find-UpdateDialog([int]$timeoutSeconds=12) {
  $watch=[Diagnostics.Stopwatch]::StartNew()
  while ($watch.Elapsed.TotalSeconds -lt $timeoutSeconds) {
    foreach ($h in [EBR_HANDLE_DIAGNOSTIC]::TopWindows($script:testPid)) {
      if ([EBR_HANDLE_DIAGNOSTIC]::IsWindowVisible($h) -and [EBR_HANDLE_DIAGNOSTIC]::Text($h) -eq 'Eye Break Reminder Update' -and
          [EBR_HANDLE_DIAGNOSTIC]::GetDlgItem($h,12001) -ne [IntPtr]::Zero -and [EBR_HANDLE_DIAGNOSTIC]::GetDlgItem($h,12002) -ne [IntPtr]::Zero) { return $h }
    }
    Start-Sleep -Milliseconds 25
  }
  throw 'Timed out waiting for the controlled update dialog.'
}
function Wait-Idle([IntPtr]$button,[int]$timeoutSeconds=12) {
  $watch=[Diagnostics.Stopwatch]::StartNew()
  while ($watch.Elapsed.TotalSeconds -lt $timeoutSeconds) { if ([EBR_HANDLE_DIAGNOSTIC]::IsWindowEnabled($button)) { Start-Sleep -Milliseconds 300; return }; Start-Sleep -Milliseconds 25 }
  throw 'Update check did not return to idle.'
}
function Start-Check([IntPtr]$button,[string]$tag) {
  if (-not [EBR_HANDLE_DIAGNOSTIC]::IsWindowEnabled($button)) { throw 'Update check button was not idle before a diagnostic cycle.' }
  Write-ReleaseFixture $tag
  [void][EBR_HANDLE_DIAGNOSTIC]::SendMessageW($button,0x00F5,[IntPtr]::Zero,[IntPtr]::Zero)
}
function Get-Slope([object[]]$values) {
  $n=$values.Count; $meanX=($n+1)/2.0; $ys=[double[]]@($values|ForEach-Object{[double]$_.HandleCount}); $meanY=($ys|Measure-Object -Average).Average; $num=0.0; $den=0.0
  for($i=0;$i-lt$n;$i++){$x=$i+1;$num+=($x-$meanX)*($ys[$i]-$meanY);$den+=($x-$meanX)*($x-$meanX)}
  [Math]::Round($num/[Math]::Max(1.0,$den),5)
}

try {
  $existing=@(Get-Process -Name EyeBreakReminder -ErrorAction SilentlyContinue | Where-Object { try { [IO.Path]::GetFullPath($_.Path) -ieq $exePath } catch { $false } })
  if ($existing.Count) { throw 'The isolated diagnostic executable is already running; refusing to reuse its profile.' }
  $process=Start-Process -FilePath $exePath -PassThru
  $script:process=$process; $script:testPid=$process.Id
  $watch=[Diagnostics.Stopwatch]::StartNew()
  while ($watch.Elapsed.TotalSeconds -lt 15 -and $script:main -eq [IntPtr]::Zero) { $script:main=Find-MainWindow; if ($script:main -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 50 } }
  if ($script:main -eq [IntPtr]::Zero) { throw 'The isolated GUI test app did not create its main window.' }
  if ([IO.Path]::GetFullPath((Get-Process -Id $script:testPid).Path) -ine $exePath) { throw 'The running process path does not match the isolated test executable.' }
  $navSettings=[EBR_HANDLE_DIAGNOSTIC]::GetDlgItem($script:main,12)
  [void][EBR_HANDLE_DIAGNOSTIC]::SendMessageW($navSettings,0x00F5,[IntPtr]::Zero,[IntPtr]::Zero)
  $section=[EBR_HANDLE_DIAGNOSTIC]::GetDlgItem($script:main,135)
  [void][EBR_HANDLE_DIAGNOSTIC]::SendMessageW($section,0x00F5,[IntPtr]::Zero,[IntPtr]::Zero)
  $check=[EBR_HANDLE_DIAGNOSTIC]::GetDlgItem($script:main,160)
  if ($check -eq [IntPtr]::Zero) { throw 'Could not find update check control 160.' }

  $sameTag=$baseVersion.ToString()
  for ($i=1;$i -le 3;$i++) { Start-Check $check $sameTag; Wait-Idle $check }
  $checkOnly=[Collections.Generic.List[object]]::new()
  for ($i=1;$i -le 20;$i++) {
    Start-Check $check $sameTag; Wait-Idle $check
    $sample=Get-Sample $i 'CheckOnlyAfterIdle'; $checkOnly.Add($sample); $script:rows.Add($sample)
  }

  $dialogPhases=[Collections.Generic.List[object]]::new()
  for ($i=1;$i -le 23;$i++) {
    $tag='{0}.{1}.{2}' -f $baseVersion.Major,$baseVersion.Minor,($baseVersion.Build+$i)
    $before=Get-Sample $i 'BeforeDialogCheck'; if ($i -gt 3) { $dialogPhases.Add($before); $script:rows.Add($before) }
    Start-Check $check $tag
    $dialog=Find-UpdateDialog
    Start-Sleep -Milliseconds 100
    $visible=Get-Sample $i 'DialogVisible'; if ($i -gt 3) { $dialogPhases.Add($visible); $script:rows.Add($visible) }
    $later=[EBR_HANDLE_DIAGNOSTIC]::GetDlgItem($dialog,12002)
    [void][EBR_HANDLE_DIAGNOSTIC]::SendMessageW($later,0x00F5,[IntPtr]::Zero,[IntPtr]::Zero)
    Wait-Idle $check
    $closed=Get-Sample $i 'DialogDismissed'; if ($i -gt 3) { $dialogPhases.Add($closed); $script:rows.Add($closed) }
  }
  $checkSlope=Get-Slope $checkOnly.ToArray()
  $visibleRows=@($dialogPhases|Where-Object Phase -eq 'DialogVisible')
  $closedRows=@($dialogPhases|Where-Object Phase -eq 'DialogDismissed')
  $visibleSlope=Get-Slope $visibleRows; $closedSlope=Get-Slope $closedRows
  $report=[pscustomobject]@{Status=$(if($checkSlope -le 0.15 -and $visibleSlope -le 0.15 -and $closedSlope -le 0.15){'PASS'}else{'FAIL'});SourceVersion=$baseVersion.ToString();ExecutableSHA256=(Get-FileHash -LiteralPath $exePath -Algorithm SHA256).Hash.ToLowerInvariant();WindowsCaption=(Get-CimInstance Win32_OperatingSystem).Caption;CheckOnlySlopePerCycle=$checkSlope;DialogVisibleSlopePerCycle=$visibleSlope;DialogDismissedSlopePerCycle=$closedSlope;CheckOnlySamples=$checkOnly.ToArray();DialogPhaseSamples=$dialogPhases.ToArray();Rows=$script:rows.ToArray()}
  $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'update-dialog-handle-diagnostic.json') -Encoding UTF8
  $script:rows | Export-Csv -LiteralPath (Join-Path $EvidenceDirectory 'update-dialog-handle-time-series.csv') -NoTypeInformation -Encoding utf8
  Write-Output "Update resource attribution: check-only slope=$checkSlope, visible=$visibleSlope, dismissed=$closedSlope handles/cycle."
  if ($report.Status -ne 'PASS') { throw 'Repeated update checks or dialogs show sustained process-handle growth.' }
}
finally {
  if ($script:fixture -and (Test-Path -LiteralPath $script:fixture)) { Remove-Item -LiteralPath $script:fixture -Force }
  if ($script:testPid -and $script:main -ne [IntPtr]::Zero -and [EBR_HANDLE_DIAGNOSTIC]::IsWindow($script:main)) {
    $quit=[EBR_HANDLE_DIAGNOSTIC]::RegisterWindowMessageW('EyeBreakReminder.Exit.Native.1')
    [void][EBR_HANDLE_DIAGNOSTIC]::PostMessageW($script:main,$quit,[IntPtr]::Zero,[IntPtr]::Zero)
    if ($script:process -and -not $script:process.WaitForExit(8000)) { Write-Error 'The isolated diagnostic app did not exit through its own Exit message.' }
  }
  if ($script:process) { $script:process.Dispose() }
}
