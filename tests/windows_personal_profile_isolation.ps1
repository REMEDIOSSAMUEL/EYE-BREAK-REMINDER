# Dot-source from the owner-mode acceptance harnesses. Never move, rename, or
# back up a user's existing EyeBreakReminder data. The only supported owner
# profile is one where that app-data directory is already absent.

function Start-EbrPersonalProfileIsolation([string]$EvidenceDirectory) {
  $localRoot = [IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd('\')
  $appData = Join-Path $localRoot 'EyeBreakReminder'

  if (-not (Test-Path -LiteralPath $localRoot -PathType Container)) {
    throw "BLOCKED: LocalAppData is not an existing directory: '$localRoot'."
  }

  $running = @(Get-Process -Name EyeBreakReminder -ErrorAction SilentlyContinue)
  if ($running.Count -gt 0) {
    $instances = @($running | ForEach-Object { "PID $($_.Id), session $($_.SessionId)" }) -join '; '
    throw "BLOCKED: Eye Break Reminder is already running in this Windows profile ($instances); no data or process was changed."
  }

  if (Test-Path -LiteralPath $appData) {
    throw "BLOCKED: existing Eye Break Reminder data was found at '$appData'. This harness will not move, rename, back up, or modify it. Use a disposable Windows profile with no existing Eye Break Reminder data."
  }

  if (-not (Test-Path -LiteralPath $EvidenceDirectory -PathType Container)) {
    [void][IO.Directory]::CreateDirectory($EvidenceDirectory)
  }

  $state = [pscustomobject]@{
    AppDataPath = $appData
    OriginalExisted = $false
    BackupPath = $null
    OriginalManifest = @()
    ProfileDataMoved = $false
    Completed = $false
  }
  $record = [pscustomobject]@{
    AppDataPath = $appData
    OriginalExisted = $false
    ProfileDataMoved = $false
    FreshTestProfilePath = $appData
    StartedUtc = [DateTime]::UtcNow.ToString('o')
  }
  $record | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'personal-profile-isolation-start.json') -Encoding UTF8
  return $state
}

function Complete-EbrPersonalProfileIsolation($State, [int]$OwnedCandidatePid, [string]$EvidenceDirectory) {
  if (-not $State) { return [pscustomobject]@{Completed=$false;Reason='Fresh-profile guard was not started.'} }

  $running = @(Get-Process -Name EyeBreakReminder -ErrorAction SilentlyContinue)
  if ($running.Count -gt 0) {
    $instances = @($running | ForEach-Object { "PID $($_.Id), session $($_.SessionId)" }) -join '; '
    throw "Candidate or another Eye Break Reminder process is still running ($instances); preserving all app data."
  }

  if (Test-Path -LiteralPath $State.AppDataPath) {
    throw "App data remains at '$($State.AppDataPath)'. It was not removed because its ownership cannot be proven after the test. Inspect it manually; the harness did not restore or delete it."
  }

  $State.Completed = $true
  $result = [pscustomobject]@{
    Completed = $true
    AppDataPath = $State.AppDataPath
    OriginalDataExisted = $false
    OriginalDataMoved = $false
    TestDataAbsent = $true
    CandidatePid = $OwnedCandidatePid
    CompletedUtc = [DateTime]::UtcNow.ToString('o')
  }
  $result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'personal-profile-isolation-cleanup.json') -Encoding UTF8
  return $result
}
