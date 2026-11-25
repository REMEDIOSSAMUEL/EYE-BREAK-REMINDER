param(
  [Parameter(Mandatory=$true)][string]$ArtifactRoot,
  [Parameter(Mandatory=$true)][string]$OutputPath
)
$ErrorActionPreference='Stop'
$ArtifactRoot=[IO.Path]::GetFullPath($ArtifactRoot)
$OutputPath=[IO.Path]::GetFullPath($OutputPath)
$release=Join-Path $ArtifactRoot 'candidate-input/release'
$evidence=Join-Path $ArtifactRoot 'candidate-input/build/v1.4.0-updater-evidence'
$completionRoot=Join-Path $ArtifactRoot 'build/v1.4.0-final-candidate-completion'
$expected=@{
  'EyeBreakReminder.exe'=@{Bytes=2831872L;SHA256='ade9b8207895cf78be50e3198fd0d38b055bd004d8751789a35b342dc3725a66'}
  'EyeBreakReminder-Setup-x64.exe'=@{Bytes=1378106L;SHA256='71437a6078121212b704cb52fb6a1ed60fa83bc0e20989b5b04b25339befadfe'}
  'EyeBreakReminder-Portable-x64.zip'=@{Bytes=1548686L;SHA256='a5bd7610c273ee86d33225d0491646ab356b15748c7e25bd64941489495c0b78'}
  'EyeBreakReminder-Source.zip'=@{Bytes=2530289L;SHA256='340115fd90bbb9ab59c82a6bbad7ba8d76e1e27b54d380a85f23ad84ef7f6024'}
  'EyeBreakReminder-SHA256.txt'=@{Bytes=382L;SHA256='762b2056b1e5a87cf0c5fbca2c40d8d930237686a8b6194599708fbdd9208711'}
}
$files=@(Get-ChildItem -LiteralPath $release -File | Sort-Object Name)
if($files.Count-ne 5 -or (($files.Name -join "`n") -cne (($expected.Keys|Sort-Object)-join "`n"))){throw 'Retained candidate contains an unexpected release-file set.'}
foreach($name in $expected.Keys){
  $file=Get-Item -LiteralPath (Join-Path $release $name)
  $hash=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
  if($file.Length-ne $expected[$name].Bytes -or $hash-cne $expected[$name].SHA256){throw "Retained candidate identity mismatch: $name"}
}
$manifest=@(Get-Content -LiteralPath (Join-Path $release 'EyeBreakReminder-SHA256.txt'))
if($manifest.Count-ne 4){throw 'Retained SHA-256 manifest must contain exactly four payload entries.'}
foreach($name in @('EyeBreakReminder.exe','EyeBreakReminder-Setup-x64.exe','EyeBreakReminder-Portable-x64.zip','EyeBreakReminder-Source.zip')){
  if(@($manifest|Where-Object{$_ -ceq ($expected[$name].SHA256+'  '+$name)}).Count-ne 1){throw "Retained manifest mismatch: $name"}
}
foreach($name in @('EyeBreakReminder.exe','EyeBreakReminder-Setup-x64.exe')){
  if((Get-Item -LiteralPath (Join-Path $release $name)).VersionInfo.ProductVersion -notmatch '^1\.4\.0(\.0)?$'){throw "Retained executable has unexpected product version: $name"}
}
Add-Type -AssemblyName System.IO.Compression
$zip=[IO.Compression.ZipFile]::OpenRead((Join-Path $release 'EyeBreakReminder-Portable-x64.zip'))
try{
  $entry=$zip.GetEntry('EyeBreakReminder.exe')
  if(-not $entry){throw 'Portable archive lacks EyeBreakReminder.exe.'}
  $stream=$entry.Open();$sha=[Security.Cryptography.SHA256]::Create()
  try{$portableHash=[Convert]::ToHexString($sha.ComputeHash($stream)).ToLowerInvariant()}finally{$sha.Dispose();$stream.Dispose()}
}finally{$zip.Dispose()}
if($portableHash-cne $expected['EyeBreakReminder.exe'].SHA256){throw 'Portable embedded executable differs from the standalone executable.'}

$provenance=Get-Content -LiteralPath (Join-Path $evidence 'candidate-provenance.json') -Raw|ConvertFrom-Json
if($provenance.Application-cne 'Eye Break Reminder' -or $provenance.Version-cne '1.4.0' -or $provenance.RunId-cne '44498562317' -or $provenance.Branch-cne 'feature/v1.4.0-automatic-updater' -or $provenance.PRHeadCommit-cne 'f764f2f24edafb9ac254f302ec958a648e99bd15' -or $provenance.SourceCommit-cne '67e8ed69686b1b6ec129f689b2a9944012a9b2c6'){throw 'Retained candidate provenance does not match the accepted production snapshot.'}
$priorGate=Get-Content -LiteralPath (Join-Path $evidence 'windows-acceptance-gate.json') -Raw|ConvertFrom-Json
foreach($key in @('Candidate','Fixtures','ProductionUpdateFixture','NetworkInterruption','LegacyV130Upgrade','Gui','StandardUser','Updater','PortableRecovery','ProductionBinaryUpdate','CoordinatorBackupFailure','ResourceTelemetry','CandidateIdentity')){if($priorGate.$key-cne 'success'){throw "Retained acceptance evidence is not passing: $key=$($priorGate.$key)"}}
$production=Get-Content -LiteralPath (Join-Path $evidence 'production-update-acceptance-successful-update-results.json') -Raw|ConvertFrom-Json
if($production.Status-cne 'PASS' -or $production.Scenario-cne 'All' -or $production.Assertions-lt 60){throw 'Retained real update/install acceptance did not pass.'}
$backup=Get-Content -LiteralPath (Join-Path $evidence 'production-update-acceptance-results.json') -Raw|ConvertFrom-Json
if($backup.Status-cne 'PASS' -or $backup.Scenario-cne 'CoordinatorBackupFailure' -or $backup.Assertions-lt 40 -or -not $backup.TemporaryTestRootRemoved -or -not $backup.HostsRestoredByteIdentically){throw 'Retained coordinator backup-failure recovery did not pass.'}

$timeout=Get-Content -LiteralPath (Join-Path $completionRoot 'download-stall-timeout.json') -Raw|ConvertFrom-Json
if($timeout.status-cne 'PASS' -or $timeout.nativeResult.body_bytes_sent_before_timeout-ne 0 -or -not $timeout.nativeResult.timeout_error_reported -or -not $timeout.nativeResult.partial_and_final_download_files_removed -or -not $timeout.nativeResult.preexisting_sentinel_preserved_byte_for_byte -or $timeout.nativeResult.elapsed_ms-ge 12000 -or -not $timeout.cleanup.runnerTempTestDirectoryRemoved -or $timeout.trust.windowsCertificateStoreModified -or -not $timeout.trust.testOnlyUnknownCaOverride -or -not $timeout.trust.restrictedToLocalhost){throw 'Retained HTTPS timeout/cleanup evidence is incomplete or failed.'}
$soak=Get-Content -LiteralPath (Join-Path $completionRoot 'resource-soak/soak-summary.json') -Raw|ConvertFrom-Json
if($soak.Application-cne 'Eye Break Reminder' -or $soak.Version-cne '1.4.0' -or $soak.RequestedCycles-ne 110 -or $soak.CompletedCycles-ne 110 -or $soak.Pass-lt 250 -or $soak.Fail-ne 0 -or $soak.NotTested-ne 0 -or -not $soak.DiagnosticTelemetryComplete -or $soak.SHA256-cne $expected['EyeBreakReminder.exe'].SHA256 -or $soak.MetricSamples-lt 2000){throw 'Retained 110-cycle production binary soak evidence is incomplete or does not match the candidate.'}
$trace=Join-Path $completionRoot 'resource-soak/resource-time-series.csv'
if(-not (Test-Path -LiteralPath $trace -PathType Leaf)){throw 'Retained full resource time series is missing.'}
$completion=[ordered]@{
  Status='PASS';SourceCompletionRunId='44505090187';SourceArtifactId='14530070327';OriginalCandidateRunId='44498562317'
  ProductSourceCommit=$provenance.PRHeadCommit;SourceSnapshotCommit=$provenance.SourceCommit
  TimeoutHarness='PASS';TimeoutElapsedMilliseconds=$timeout.nativeResult.elapsed_ms
  ProductionBinaryResourceSoak='PASS';SoakCycles=$soak.CompletedCycles;SoakPass=$soak.Pass;SoakFail=$soak.Fail;SoakNotTested=$soak.NotTested;SoakDurationSeconds=$soak.DurationSeconds;ResourceMetricSamples=$soak.MetricSamples;SoakedExecutableSHA256=$soak.SHA256
  CandidateFiles=@(foreach($name in ($expected.Keys|Sort-Object)){[pscustomobject]@{Name=$name;Bytes=$expected[$name].Bytes;SHA256=$expected[$name].SHA256}})
  Published=$false;Tagged=$false;Merged=$false;VerifiedUtc=[DateTime]::UtcNow.ToString('o')
}
[void][IO.Directory]::CreateDirectory((Split-Path -Parent $OutputPath))
$completion|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $OutputPath -Encoding utf8
Write-Host "Retained v1.4.0 candidate, timeout, install/recovery evidence, and exact-binary soak PASS: $OutputPath"
