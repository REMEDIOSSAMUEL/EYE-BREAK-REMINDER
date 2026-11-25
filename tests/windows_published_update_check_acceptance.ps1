param(
  [string]$EvidencePath = 'build/published-update-check-acceptance.json'
)

$ErrorActionPreference = 'Stop'
$repository = 'REMEDIOSSAMUEL/EYE-BREAK-REMINDER'
$latestTag = 'v1.4.0'
$downloadRoot = Join-Path $env:RUNNER_TEMP 'EyeBreakReminder-v1.4.0-public-acceptance'
$localAppData = [IO.Path]::GetFullPath([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData))
$dataPath = [IO.Path]::GetFullPath((Join-Path $localAppData 'EyeBreakReminder'))
$ownedData = $false
$startedProcesses = [Collections.Generic.List[Diagnostics.Process]]::new()
$results = [Collections.Generic.List[object]]::new()
$summary = @{
  Application = 'Eye Break Reminder'
  Test = 'Focused published binary launch and live update checker acceptance'
  LatestStableTag = $null
  OfficialReleaseUrl = $null
  Downloads = @()
  PortableInnerExecutableSHA256 = $null
  Results = @()
  Status = 'FAIL'
  Failure = $null
  CompletedUtc = $null
}

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class EBRPostReleaseNative {
    public delegate bool EnumChildProc(IntPtr window, IntPtr context);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool EnumChildWindows(IntPtr parent, EnumChildProc callback, IntPtr context);
    [DllImport("user32.dll", SetLastError = true)] public static extern int GetWindowTextLengthW(IntPtr window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern int GetWindowTextW(IntPtr window, StringBuilder text, int capacity);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern int GetClassNameW(IntPtr window, StringBuilder className, int capacity);
    [DllImport("user32.dll", SetLastError = true)] public static extern int GetDlgCtrlID(IntPtr window);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool IsWindowEnabled(IntPtr window);
    [DllImport("user32.dll", SetLastError = true)] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr SendMessageTimeoutW(IntPtr window, uint message, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);
}
"@

function Write-Evidence {
  $summary.Results = @($results.ToArray())
  $summary.CompletedUtc = [DateTime]::UtcNow.ToString('o')
  $fullPath = [IO.Path]::GetFullPath($EvidencePath)
  $directory = Split-Path -Parent $fullPath
  if (-not (Test-Path -LiteralPath $directory)) {
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
  }
  $summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $fullPath -Encoding utf8
}

function Download-PublicAsset([string]$Name, [string]$Url, [string]$ExpectedSha256) {
  $path = Join-Path $downloadRoot $Name
  $lastError = $null
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    try {
      Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $path -TimeoutSec 120 -Headers @{ 'User-Agent' = 'EyeBreakReminder-PublishedAcceptance' } | Out-Null
      $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
      if ($actual -cne $ExpectedSha256) {
        throw "SHA-256 mismatch for $Name. Expected $ExpectedSha256, got $actual."
      }
      return [pscustomobject]@{ Path = $path; SHA256 = $actual; Bytes = (Get-Item -LiteralPath $path).Length; URL = $Url }
    } catch {
      $lastError = $_
      if ($attempt -lt 3) { Start-Sleep -Seconds 2 }
    }
  }
  throw "Public download failed for $Name after three attempts: $lastError"
}

function Get-WindowText([IntPtr]$Handle) {
  $length = [Math]::Max(1, [EBRPostReleaseNative]::GetWindowTextLengthW($Handle) + 1)
  $buffer = [Text.StringBuilder]::new($length)
  [void][EBRPostReleaseNative]::GetWindowTextW($Handle, $buffer, $buffer.Capacity)
  return $buffer.ToString()
}

function Get-WindowClass([IntPtr]$Handle) {
  $buffer = [Text.StringBuilder]::new(256)
  [void][EBRPostReleaseNative]::GetClassNameW($Handle, $buffer, $buffer.Capacity)
  return $buffer.ToString()
}

function Get-ChildWindowHandles([IntPtr]$Root) {
  $script:enumHandles = [Collections.Generic.List[IntPtr]]::new()
  $callback = [EBRPostReleaseNative+EnumChildProc]{
    param([IntPtr]$Window, [IntPtr]$Context)
    $script:enumHandles.Add($Window)
    return $true
  }
  [void][EBRPostReleaseNative]::EnumChildWindows($Root, $callback, [IntPtr]::Zero)
  return $script:enumHandles.ToArray()
}

function Get-AppControls([IntPtr]$Root, [uint32]$ProcessId) {
  $controls = [Collections.Generic.List[object]]::new()
  foreach ($handle in (Get-ChildWindowHandles $Root)) {
    [uint32]$owner = 0
    [void][EBRPostReleaseNative]::GetWindowThreadProcessId($handle, [ref]$owner)
    if ($owner -ne $ProcessId -or -not [EBRPostReleaseNative]::IsWindowVisible($handle)) { continue }
    $controls.Add([pscustomobject]@{
      Handle = $handle
      Id = [EBRPostReleaseNative]::GetDlgCtrlID($handle)
      Class = Get-WindowClass $handle
      Text = Get-WindowText $handle
      Enabled = [EBRPostReleaseNative]::IsWindowEnabled($handle)
    })
  }
  return $controls.ToArray()
}

function Get-AppControl([IntPtr]$Root, [uint32]$ProcessId, [int]$Id, [string]$Name) {
  $found = @((Get-AppControls $Root $ProcessId) | Where-Object { $_.Id -eq $Id })
  if ($found.Count -ne 1) {
    throw "Expected one visible $Name control with ID $Id; found $($found.Count)."
  }
  return $found[0]
}

function Get-StaticControl([IntPtr]$Root, [uint32]$ProcessId, [string]$Text, [string]$Name) {
  $found = @((Get-AppControls $Root $ProcessId) | Where-Object { $_.Class -eq 'Static' -and $_.Text -ceq $Text })
  if ($found.Count -ne 1) {
    throw "Expected one $Name static control with text '$Text'; found $($found.Count)."
  }
  return $found[0]
}

function Click-AppControl([IntPtr]$Root, [uint32]$ProcessId, [int]$Id, [string]$Name) {
  $control = Get-AppControl $Root $ProcessId $Id $Name
  if (-not $control.Enabled) { throw "$Name control is disabled." }
  $result = [IntPtr]::Zero
  $sent = [EBRPostReleaseNative]::SendMessageTimeoutW($control.Handle, [uint32]0x00F5, [IntPtr]::Zero, [IntPtr]::Zero, [uint32]2, [uint32]5000, [ref]$result)
  if ($sent -eq [IntPtr]::Zero) { throw "$Name control did not respond to BM_CLICK within five seconds." }
}

function Invoke-PublishedUpdateCheck([string]$Version, [string]$ExecutablePath, [string]$ExpectedSha256, [string]$ExpectedResult) {
  $actualHash = (Get-FileHash -LiteralPath $ExecutablePath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actualHash -cne $ExpectedSha256) { throw "Executable hash mismatch for v$Version." }
  $fileVersion = (Get-Item -LiteralPath $ExecutablePath).VersionInfo
  if ($fileVersion.ProductName -ne 'Eye Break Reminder' -or $fileVersion.ProductVersion -notmatch ('^' + [regex]::Escape($Version) + '(\.0)?$')) {
    throw "Unexpected product metadata for v$($Version): $($fileVersion.ProductName) $($fileVersion.ProductVersion)"
  }
  if ((Get-AuthenticodeSignature -LiteralPath $ExecutablePath).Status -ne 'NotSigned') { throw "Signing status changed for v$Version." }

  $process = Start-Process -FilePath $ExecutablePath -WorkingDirectory (Split-Path -Parent $ExecutablePath) -PassThru
  $startedProcesses.Add($process)
  try {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $window = [IntPtr]::Zero
    while ($watch.Elapsed.TotalSeconds -lt 30) {
      $process.Refresh()
      if ($process.HasExited) { throw "v$Version exited during startup with code $($process.ExitCode)." }
      $window = $process.MainWindowHandle
      if ($window -ne [IntPtr]::Zero -and [EBRPostReleaseNative]::IsWindowVisible($window)) { break }
      Start-Sleep -Milliseconds 200
    }
    if ($window -eq [IntPtr]::Zero) { throw "v$Version did not create a desktop window within 30 seconds." }
    try { $responsive = [bool]$process.Responding } catch { $responsive = $false }
    if (-not $responsive) { throw "v$Version main window did not respond after startup." }

    [uint32]$processId = $process.Id
    Click-AppControl $window $processId 12 'Settings navigation'
    Click-AppControl $window $processId 135 'About section'
    $installed = Get-StaticControl $window $processId "Installed version: $Version" 'Installed version'
    $latest = Get-StaticControl $window $processId 'Latest stable version: not checked' 'Initial latest stable version'
    $initialStatus = if ($Version -eq '1.4.0') { 'Check for Updates queries the official public GitHub Releases API.' } else { 'Select Check for Updates to query the official public GitHub Releases API.' }
    $status = Get-StaticControl $window $processId $initialStatus 'Initial update status'
    Click-AppControl $window $processId 160 'Check for Updates'

    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
      $latestText = Get-WindowText $latest.Handle
      $statusText = Get-WindowText $status.Handle
      if ($latestText -notmatch 'checking|not checked' -and $statusText -notmatch '^Checking') { break }
      Start-Sleep -Milliseconds 150
    } while ($watch.Elapsed.TotalSeconds -lt 50)

    $latestText = Get-WindowText $latest.Handle
    $statusText = Get-WindowText $status.Handle
    $checkButton = Get-AppControl $window $processId 160 'Check for Updates'
    $releaseButton = Get-AppControl $window $processId 161 'Open Official Release'
    if ($latestText -cne 'Latest stable version: 1.4.0') { throw "v$Version displayed an unexpected latest version: $latestText" }
    if (-not $checkButton.Enabled) { throw "v$Version update request did not return and re-enable its button." }
    if ($statusText -notmatch [regex]::Escape($ExpectedResult)) { throw "v$Version returned unexpected update status: $statusText" }
    if (-not $releaseButton.Enabled) { throw "v$Version official release button was disabled after successful discovery." }
    $officialReleaseInvoked = $false
    if ($Version -eq '1.3.0') {
      Click-AppControl $window $processId 161 'Open Official Release'
      $officialReleaseInvoked = $true
    }

    $results.Add([pscustomobject]@{
      Version = $Version
      ProductName = $fileVersion.ProductName
      ProductVersion = $fileVersion.ProductVersion
      SHA256 = $actualHash
      WindowResponsive = $responsive
      InstalledLabel = Get-WindowText $installed.Handle
      LatestLabel = $latestText
      Status = $statusText
      OfficialReleaseButtonEnabled = $releaseButton.Enabled
      OfficialReleaseButtonInvoked = $officialReleaseInvoked
      ExpectedResult = $ExpectedResult
      Pass = $true
    })
  } finally {
    $process.Refresh()
    if (-not $process.HasExited) {
      Stop-Process -Id $process.Id -Force
      if (-not $process.WaitForExit(10000)) { throw "Could not stop v$Version acceptance process." }
    }
    $process.Dispose()
  }
}

try {
  if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:RUNNER_OS -ne 'Windows') {
    throw 'This focused binary acceptance must run on an isolated GitHub-hosted Windows runner.'
  }
  if (-not [Environment]::UserInteractive -or [Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0) {
    throw 'Interactive Windows desktop is unavailable on this runner.'
  }
  if (Test-Path -LiteralPath $dataPath) { throw "Refusing to use pre-existing runner profile data: $dataPath" }
  if (@(Get-Process -Name EyeBreakReminder -ErrorAction SilentlyContinue).Count -gt 0) { throw 'Refusing to run beside an existing Eye Break Reminder process.' }

  $latestRelease = Invoke-RestMethod -UseBasicParsing -Uri "https://api.github.com/repos/$repository/releases/latest" -TimeoutSec 30 -Headers @{ 'User-Agent' = 'EyeBreakReminder-PublishedAcceptance' }
  if ($latestRelease.tag_name -cne $latestTag -or $latestRelease.draft -or $latestRelease.prerelease) {
    throw "Expected stable latest release $latestTag, received $($latestRelease.tag_name)."
  }
  $summary.LatestStableTag = $latestRelease.tag_name

  $officialUrl = 'https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/tag/v1.4.0'
  if ($latestRelease.html_url -cne $officialUrl) { throw 'Latest stable release returned an unexpected official URL.' }
  $summary.OfficialReleaseUrl = $officialUrl
  $v130Release = Invoke-RestMethod -UseBasicParsing -Uri "https://api.github.com/repos/$repository/releases/tags/v1.3.0" -TimeoutSec 30 -Headers @{ 'User-Agent' = 'EyeBreakReminder-PublishedAcceptance' }
  if ($v130Release.draft -or $v130Release.prerelease) { throw 'v1.3.0 is not a published stable release.' }

  New-Item -ItemType Directory -Force -Path $downloadRoot | Out-Null
  $oldExe = Download-PublicAsset 'v1.3.0-EyeBreakReminder.exe' 'https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/download/v1.3.0/EyeBreakReminder.exe' '3ca3133559de29d78f7a1054542d757d24877e93b4409c731081ebf6d1846d66'
  $newExe = Download-PublicAsset 'v1.4.0-EyeBreakReminder.exe' 'https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/download/v1.4.0/EyeBreakReminder.exe' '90880be4b515af59967ff221e379ab5958d84c2e98f2ef50ac4cc5aecc9dc6a9'
  $portableZip = Download-PublicAsset 'v1.4.0-EyeBreakReminder-Portable-x64.zip' 'https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/download/v1.4.0/EyeBreakReminder-Portable-x64.zip' 'f1a34c4fa79044264aa7f9c8a3ef9734c727ae7af42971b75baeae60225f78ca'
  $portablePath = Join-Path $downloadRoot 'v1.4.0-portable'
  Expand-Archive -LiteralPath $portableZip.Path -DestinationPath $portablePath
  $portableExe = Join-Path $portablePath 'EyeBreakReminder.exe'
  $portableHash = (Get-FileHash -LiteralPath $portableExe -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($portableHash -cne $newExe.SHA256) { throw 'Portable package executable differs from the published standalone executable.' }

  $summary.Downloads = @($oldExe, $newExe, $portableZip) | ForEach-Object {
    [pscustomobject]@{ Name = Split-Path -Leaf $_.Path; SHA256 = $_.SHA256; Bytes = $_.Bytes; URL = $_.URL }
  }
  $summary.PortableInnerExecutableSHA256 = $portableHash
  $ownedData = $true
  Invoke-PublishedUpdateCheck '1.3.0' $oldExe.Path '3ca3133559de29d78f7a1054542d757d24877e93b4409c731081ebf6d1846d66' 'update is available'
  Invoke-PublishedUpdateCheck '1.4.0' $newExe.Path '90880be4b515af59967ff221e379ab5958d84c2e98f2ef50ac4cc5aecc9dc6a9' 'up to date'

  $summary.Status = 'PASS'
  Write-Output 'Focused published binary and live update checker acceptance: PASS'
} catch {
  $summary.Failure = $_.Exception.ToString()
  throw
} finally {
  foreach ($process in $startedProcesses) {
    try { $process.Refresh(); if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } } catch { }
  }
  if ($ownedData -and (Test-Path -LiteralPath $dataPath)) {
    $resolvedDataPath = [IO.Path]::GetFullPath($dataPath)
    if ($resolvedDataPath -ine $dataPath) { throw 'Refusing cleanup outside the runner-owned app-data directory.' }
    $item = Get-Item -LiteralPath $resolvedDataPath -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Refusing to remove redirected runner app data.' }
    Remove-Item -LiteralPath $resolvedDataPath -Recurse -Force
  }
  Write-Evidence
}
