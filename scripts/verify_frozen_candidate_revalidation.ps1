[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$CandidateRoot,
  [Parameter(Mandatory)][string]$NetworkRoot,
  [Parameter(Mandatory)][string]$SoakRoot,
  [Parameter(Mandatory)][ValidateRange(1, [long]::MaxValue)][long]$SoakArtifactId,
  [Parameter(Mandatory)][string]$ReportPath
)

$ErrorActionPreference = 'Stop'
$source = 'dfd8018b319bdfde498d4f23b2d1ca96d0a99145'
$networkSource = '0af9f24d71ab003f82bd18e9146d0da8038973c4'
$exeHash = '90880be4b515af59967ff221e379ab5958d84c2e98f2ef50ac4cc5aecc9dc6a9'

function Read-Report([string]$Path) {
  Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

$buildEvidence = Join-Path $CandidateRoot 'build/v1.4.0-updater-evidence'
$gatePath = Join-Path $buildEvidence 'windows-acceptance-gate.json'
$gate = Read-Report $gatePath
$provenance = Read-Report (Join-Path $buildEvidence 'candidate-provenance.json')
$unchanged = Read-Report (Join-Path $buildEvidence 'candidate-unchanged.json')
$initialNetwork = Read-Report (Join-Path $buildEvidence 'https-interruption.json')
$provenanceMatch = $provenance.Application -ceq 'Eye Break Reminder' -and $provenance.Version -ceq '1.4.0' -and
  $provenance.Branch -ceq 'feature/v1.4.0-automatic-updater' -and $provenance.SourceCommit -ceq $source -and
  $provenance.RunId -eq '45624936126'
if (-not $provenanceMatch -or $gate.Scope -cne 'ProductionCandidateOnly' -or $gate.Status -cne 'NOT READY' -or
    $gate.NetworkInterruption -cne 'failure' -or $gate.ResourceSoak -cne 'skipped' -or $gate.ResourceSoakReused -ne 'false' -or
    $gate.DesktopAvailable -ne $true -or $unchanged.Status -cne 'PASS' -or $unchanged.ExactCandidateRetained -ne $true -or
    $initialNetwork.Status -cne 'FAIL' -or $initialNetwork.Commit -cne $source -or $initialNetwork.AssetConnections -ne 0 -or
    $initialNetwork.FirstAssetTruncated -ne $false -or $initialNetwork.TLSValidationDisabled -ne $false -or
    $initialNetwork.TemporaryTrustStoreModified -ne $false) {
  throw 'Original run does not match the one preserved pre-transfer failure and skipped soak.'
}
foreach ($name in 'Candidate','Fixtures','DownloadBodyTimeout','LegacyV130Upgrade','Gui','StandardUser',
    'Updater','PortableRecovery','ResourceTelemetry','CandidateIdentity') {
  if ($gate.$name -cne 'success') { throw "A required original gate did not pass: $name" }
}

$networkPath = Join-Path $NetworkRoot 'https-interruption.json'
$network = Read-Report $networkPath
if ($network.Status -cne 'PASS' -or $network.Commit -cne $networkSource -or $network.TestExitCode -ne 0 -or
    $network.TLSValidationDisabled -ne $false -or $network.TemporaryTrustStoreModified -ne $false -or
    $network.AssetConnections -lt 2 -or $network.FirstAssetTruncated -ne $true -or
    $network.FirstAssetForwardedEncryptedBytes -lt 65536 -or
    $network.TestOutput -notmatch 'PASS: 7 real GitHub HTTPS interruption and retry assertions executed' -or
    $network.TestOutput -notmatch 'HTTPS discovery diagnostics: status=200 transportFailure=0 nativeError=0') {
  throw 'The independent network gate lacks proof of a real interruption and verified retry.'
}

$soakPath = Join-Path $SoakRoot 'resource-soak/soak-summary.json'
$threadsPath = Join-Path $SoakRoot 'resource-soak/resource-thread-summary-verification.json'
$tracePath = Join-Path $SoakRoot 'resource-soak/resource-time-series.csv'
$cyclePath = Join-Path $SoakRoot 'resource-soak/cycle-results.csv'
$soak = Read-Report $soakPath
$threads = Read-Report $threadsPath
$soakOrigin = Read-Report (Join-Path $SoakRoot 'verified-origin.json')
if ($soakOrigin.RunId -ne $provenance.RunId -or $soakOrigin.SourceCommit -cne $source -or
    $soak.SHA256 -cne $exeHash -or $soak.ExpectedBehavior -cne 'NoGrowth' -or
    $soak.RequestedCycles -ne 110 -or $soak.CompletedCycles -ne 110 -or
    $soak.Environment.Runner -cne 'github-hosted' -or $soak.Environment.OSArchitecture -cne 'X64' -or
    $soak.Environment.Interactive -ne $true -or $soak.Pass -le 0 -or $soak.Fail -ne 0 -or $soak.NotTested -ne 0 -or
    $threads.Status -cne 'PASS' -or $threads.CandidateExecutableSHA256 -cne $exeHash -or
    $threads.CycleRows -ne 110 -or $threads.MetricSamples -le 110 -or $threads.SummaryJsonUpdated -ne $true -or
    $threads.SyntheticCheck -cne 'PASS' -or $threads.TraceSHA256 -cne (Get-FileHash -LiteralPath $tracePath).Hash.ToLowerInvariant() -or
    @(Import-Csv -LiteralPath $cyclePath).Count -ne 110 -or @(Import-Csv -LiteralPath $tracePath).Count -ne $threads.MetricSamples) {
  throw 'Fresh hosted resource soak and its thread evidence must pass for the frozen executable hash.'
}

$expected = [ordered]@{
  'EyeBreakReminder.exe' = $exeHash
  'EyeBreakReminder-Setup-x64.exe' = 'c1d30c9d7f5ecf070fda86711eda7130c5f662fc27d98eab7b6ce9e7a6b6865a'
  'EyeBreakReminder-Portable-x64.zip' = 'f1a34c4fa79044264aa7f9c8a3ef9734c727ae7af42971b75baeae60225f78ca'
  'EyeBreakReminder-Source.zip' = 'e465c88c7deb76399bf2b166420294c622ff2c6b9f8e26bc05aecfc5196181d9'
  'EyeBreakReminder-SHA256.txt' = '45819b9540d00c64534b919a7f9e0eec467f1910e81cc129ce960a7ea70dc7f2'
}
$release = Join-Path $CandidateRoot 'release'
if (@(Get-ChildItem -LiteralPath $release -Force).Count -ne 5 -or @($provenance.CandidateFiles).Count -ne 5 -or
    @($soakOrigin.CandidateFiles).Count -ne 5 -or @($unchanged.Files).Count -ne 5) {
  throw 'Expected exactly the original five files in both runs.'
}
$verified = foreach ($name in $expected.Keys) {
  $file = Get-Item -LiteralPath (Join-Path $release $name)
  $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $hash -cne $expected[$name]) {
    throw "Unexpected bytes or type for $name"
  }
  foreach ($records in @($provenance.CandidateFiles, $soakOrigin.CandidateFiles, $unchanged.Files)) {
    $item = @($records | Where-Object Name -CEQ $name)
    if ($item.Count -ne 1 -or $item[0].Bytes -ne $file.Length -or $item[0].SHA256 -cne $hash) {
      throw "Evidence identity mismatch for $name"
    }
  }
  [pscustomobject]@{ Name = $name; Bytes = $file.Length; SHA256 = $hash }
}

[ordered]@{
  Status = 'PASS'
  CandidateSource = $source
  OriginalBuildRun = 45624936126
  OriginalCandidateArtifact = 15029531496
  OriginalWorkflowConclusion = 'failure'
  RevalidationRun = 45628377723
  RevalidationSource = $networkSource
  NetworkArtifact = 15029466773
  SoakArtifact = $SoakArtifactId
  NetworkEvidenceSHA256 = (Get-FileHash -LiteralPath $networkPath).Hash.ToLowerInvariant()
  SoakEvidenceSHA256 = (Get-FileHash -LiteralPath $soakPath).Hash.ToLowerInvariant()
  ThreadEvidenceSHA256 = (Get-FileHash -LiteralPath $threadsPath).Hash.ToLowerInvariant()
  VerifiedFiles = @($verified)
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ReportPath -Encoding utf8
