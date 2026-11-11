param(
  [string]$ArtifactsDirectory = (Join-Path $env:RUNNER_TEMP 'eye-break-reminder-v1.2.0-published-assets'),
  [string]$EvidenceDirectory = (Join-Path (Get-Location) 'build\post-release-evidence')
)
$ErrorActionPreference = 'Stop'
$repoName = 'REMEDIOSSAMUEL/EYE-BREAK-REMINDER'
$approvedMain = '908a21531833eb2175fb7bd882db06b79a2b917b'
$testedSource = 'cbd2e467c3767765250ff11a701839a8a850134b'
$expected = [ordered]@{
  'EyeBreakReminder.exe' = '2895c80f942dd03186305d913516700552524ec5ba9a77da0dab457a3265fcc6'
  'EyeBreakReminder-Setup-x64.exe' = '121eaa8d14b8e3d342252edfc91bc25d6e8334b829c2824b7f90813062ded75f'
  'EyeBreakReminder-Portable-x64.zip' = '757f1cb10eb9a4c943a47c475f3aca8a2942b823ad4119fa217c66251dbd3658'
  'EyeBreakReminder-Source.zip' = 'd6ed5ba6827ad9097435c4ffe9776b0e60e9a67f9b9ccfc49776964d57c9e692'
  'EyeBreakReminder-SHA256.txt' = 'be97ddf2af39a52315ab7f678ce26d770bde81113181aa00ad3c7c1577b50dea'
}
$expectedNames = @($expected.Keys | Sort-Object)
$events = [System.Collections.Generic.List[object]]::new()
function Add-Check([string]$Name,[string]$Status,$Details=$null) {
  $events.Add([pscustomobject]@{Name=$Name;Status=$Status;Details=$Details;Utc=[DateTime]::UtcNow.ToString('o')})
}
function Check([bool]$Condition,[string]$Name,$Details=$null) {
  if($Condition){Add-Check $Name 'PASS' $Details}
  else{Add-Check $Name 'FAIL' $Details}
}
function Get-Bytes([System.IO.Compression.ZipArchiveEntry]$Entry) {
  $stream=$Entry.Open();$memory=[IO.MemoryStream]::new()
  try{$stream.CopyTo($memory);return ,$memory.ToArray()}finally{$stream.Dispose();$memory.Dispose()}
}
function Normalize-TextBytes([byte[]]$Bytes) {
  $text=[Text.Encoding]::UTF8.GetString($Bytes)
  [Text.Encoding]::UTF8.GetBytes($text.Replace("`r`n","`n").Replace("`r","`n"))
}
function Same-Bytes([byte[]]$Left,[byte[]]$Right) {
  if($Left.Length -ne $Right.Length){return $false}
  for($i=0;$i -lt $Left.Length;$i++){if($Left[$i] -ne $Right[$i]){return $false}}
  return $true
}
try {
  [void][IO.Directory]::CreateDirectory($ArtifactsDirectory)
  [void][IO.Directory]::CreateDirectory($EvidenceDirectory)
  Add-Type -AssemblyName System.IO.Compression.FileSystem

  $repo=Invoke-RestMethod -Method Get -Uri "https://api.github.com/repos/$repoName" -Headers @{ 'User-Agent'='EyeBreakReminder-PostReleaseVerification/1.0'; Accept='application/vnd.github+json' } -TimeoutSec 30
  Check (-not $repo.private) 'Repository is publicly visible' ([pscustomobject]@{FullName=$repo.full_name;Private=$repo.private})

  $release=Invoke-RestMethod -Method Get -Uri "https://api.github.com/repos/$repoName/releases/tags/v1.2.0" -Headers @{ 'User-Agent'='EyeBreakReminder-PostReleaseVerification/1.0'; Accept='application/vnd.github+json' } -TimeoutSec 30
  Check ($release.tag_name -ceq 'v1.2.0' -and $release.name -ceq 'Eye Break Reminder v1.2.0' -and -not $release.draft -and -not $release.prerelease) 'Published stable release metadata is correct' ([pscustomobject]@{Tag=$release.tag_name;Title=$release.name;Draft=$release.draft;Prerelease=$release.prerelease;Target=$release.target_commitish;Url=$release.html_url})
  Check ($release.target_commitish -ceq 'main') 'Release target metadata names main' $release.target_commitish
  $latest=Invoke-RestMethod -Method Get -Uri "https://api.github.com/repos/$repoName/releases/latest" -Headers @{ 'User-Agent'='EyeBreakReminder-PostReleaseVerification/1.0'; Accept='application/vnd.github+json' } -TimeoutSec 30
  Check ($latest.tag_name -ceq 'v1.2.0' -and -not $latest.draft -and -not $latest.prerelease) 'Unauthenticated latest endpoint returns stable v1.2.0' ([pscustomobject]@{Tag=$latest.tag_name;Url=$latest.html_url})
  $main=Invoke-RestMethod -Method Get -Uri "https://api.github.com/repos/$repoName/git/ref/heads/main" -Headers @{ 'User-Agent'='EyeBreakReminder-PostReleaseVerification/1.0'; Accept='application/vnd.github+json' } -TimeoutSec 30
  $tagRef=Invoke-RestMethod -Method Get -Uri "https://api.github.com/repos/$repoName/git/ref/tags/v1.2.0" -Headers @{ 'User-Agent'='EyeBreakReminder-PostReleaseVerification/1.0'; Accept='application/vnd.github+json' } -TimeoutSec 30
  $tagObject=$tagRef.object
  if($tagObject.type -eq 'tag'){$tagObject=Invoke-RestMethod -Method Get -Uri "https://api.github.com/repos/$repoName/git/tags/$($tagObject.sha)" -Headers @{ 'User-Agent'='EyeBreakReminder-PostReleaseVerification/1.0'; Accept='application/vnd.github+json' } -TimeoutSec 30;$targetCommit=$tagObject.object.sha}else{$targetCommit=$tagObject.sha}
  Check ($main.object.sha -ceq $approvedMain) 'Public main branch is the approved v1.2.0 commit' $main.object.sha
  Check ($targetCommit -ceq $main.object.sha) 'Published v1.2.0 tag peels to current main commit' ([pscustomobject]@{Tag=$targetCommit;Main=$main.object.sha})

  $sourceChanges=@(& git diff --name-only "$testedSource..$approvedMain")
  if($LASTEXITCODE -ne 0){throw 'Could not compare tested application source to merged main.'}
  $nonDocChanges=@($sourceChanges | Where-Object {$_ -notin @('docs/FINAL_PRE_RELEASE_VERIFICATION.md')})
  Check ($nonDocChanges.Count -eq 0) 'No application, installer, or build input changed after Windows-tested source' ([pscustomobject]@{Files=$sourceChanges;NonDocumentation=$nonDocChanges})

  $note=$release.body
  $noteClaims=@(
    'High Contrast Dark','High Contrast Light','Follow Windows Theme','reduced-motion','break-mode colours','Check for Updates',
    'Centred the timer status','Removed the redundant explanatory sentence','unsigned','Narrator speech','physical audio','sleep/resume'
  )
  $missingNotes=@($noteClaims | Where-Object {$note -notmatch [regex]::Escape($_)})
  Check ($missingNotes.Count -eq 0) 'Release notes describe the v1.2.0 features and disclose validation limits' ([pscustomobject]@{Missing=$missingNotes})
  $page=Invoke-WebRequest -Method Get -Uri $release.html_url -Headers @{ 'User-Agent'='EyeBreakReminder-PostReleaseVerification/1.0' } -MaximumRedirection 10 -TimeoutSec 45
  Check ([int]$page.StatusCode -eq 200 -and $page.Content -match 'Eye Break Reminder v1\.2\.0') 'Public release page loads and shows the correct title' ([pscustomobject]@{Status=[int]$page.StatusCode;FinalUrl=[string]$page.BaseResponse.ResponseUri})

  $assetNames=@($release.assets | ForEach-Object name | Sort-Object)
  Check (($assetNames.Count -eq 5) -and ((Compare-Object $expectedNames $assetNames).Count -eq 0)) 'Exactly five expected assets are attached without duplicates' $assetNames
  $metadata=@{}
  foreach($asset in $release.assets){
    if($asset.name -notin $expectedNames){continue}
    $path=Join-Path $ArtifactsDirectory $asset.name
    Invoke-WebRequest -Method Get -Uri $asset.browser_download_url -OutFile $path -Headers @{ 'User-Agent'='EyeBreakReminder-PostReleaseVerification/1.0' } -MaximumRedirection 10 -TimeoutSec 120
    $file=Get-Item -LiteralPath $path
    $hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    $matches=($hash -ceq $expected[$asset.name])
    Check $matches "Public download SHA-256 matches the expected $($asset.name)" ([pscustomobject]@{Bytes=$file.Length;Expected=$expected[$asset.name];Actual=$hash;ApiSize=$asset.size;BrowserUrl=$asset.browser_download_url})
    Check ($file.Length -eq [long]$asset.size) "Public download size matches GitHub metadata for $($asset.name)" ([pscustomobject]@{Actual=$file.Length;Expected=$asset.size})
    $metadata[$asset.name]=[pscustomobject]@{Path=$path;Bytes=$file.Length;SHA256=$hash;ExpectedSHA256=$expected[$asset.name];BrowserUrl=$asset.browser_download_url}
  }

  $manifestPath=Join-Path $ArtifactsDirectory 'EyeBreakReminder-SHA256.txt'
  $manifest=Get-Content -LiteralPath $manifestPath -Raw
  $manifestRows=@()
  foreach($line in ($manifest -split "`r?`n" | Where-Object {$_ -match '\S'})){
    if($line -notmatch '^\s*([a-fA-F0-9]{64})\s+(\S+)\s*$'){throw "Invalid SHA-256 manifest line: $line"}
    $manifestRows += [pscustomobject]@{Hash=$Matches[1].ToLowerInvariant();Name=$Matches[2]}
  }
  $manifestNames=@($manifestRows | ForEach-Object Name | Sort-Object)
  $fourExpected=@($expectedNames | Where-Object {$_ -ne 'EyeBreakReminder-SHA256.txt'})
  Check (($manifestRows.Count -eq 4) -and ((Compare-Object $fourExpected $manifestNames).Count -eq 0)) 'Manifest lists exactly the four downloadable artifacts and not itself' $manifestRows
  foreach($row in $manifestRows){
    $actual=(Get-FileHash -LiteralPath (Join-Path $ArtifactsDirectory $row.Name) -Algorithm SHA256).Hash.ToLowerInvariant()
    Check ($row.Hash -ceq $actual) "Manifest verifies $($row.Name)" ([pscustomobject]@{Manifest=$row.Hash;Actual=$actual})
  }

  foreach($name in @('EyeBreakReminder.exe','EyeBreakReminder-Setup-x64.exe')){
    $version=[Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $ArtifactsDirectory $name))
    Check ($version.ProductVersion -match '^1\.2\.0(\.0)?$' -and $version.ProductName -eq 'Eye Break Reminder') "Executable version metadata is v1.2.0 for $name" ([pscustomobject]@{ProductName=$version.ProductName;ProductVersion=$version.ProductVersion;FileVersion=$version.FileVersion})
    $signature=Get-AuthenticodeSignature -LiteralPath (Join-Path $ArtifactsDirectory $name)
    Check ($signature.Status -eq [System.Management.Automation.SignatureStatus]::NotSigned -and -not $signature.SignerCertificate) "$name remains unsigned" ([pscustomobject]@{Status=$signature.Status.ToString();Signer=$signature.SignerCertificate.Subject})
  }

  $portablePath=Join-Path $ArtifactsDirectory 'EyeBreakReminder-Portable-x64.zip'
  $portableZip=[IO.Compression.ZipFile]::OpenRead($portablePath)
  try{
    $portableFiles=@($portableZip.Entries | Where-Object {-not $_.FullName.EndsWith('/')} )
    $embedded=@($portableFiles | Where-Object {$_.Name -ceq 'EyeBreakReminder.exe'})
    $portableExpected=@('EyeBreakReminder.exe','README.md','PRIVACY.md','VERIFICATION.md','THIRD-PARTY-LICENSES.txt','SIGNING-STATUS.txt')
    $portableActual=@($portableFiles | ForEach-Object Name | Sort-Object)
    $portableExpectedSorted=@($portableExpected | Sort-Object)
    Check (($portableFiles.Count -eq 6) -and ((Compare-Object $portableExpectedSorted $portableActual).Count -eq 0)) 'Portable archive contains only the executable and its documentation/status files' ([pscustomobject]@{Files=@($portableFiles | ForEach-Object FullName)})
    Check ($embedded.Count -eq 1) 'Portable archive contains exactly one application executable' ([pscustomobject]@{Files=@($portableFiles | ForEach-Object FullName)})
    $portableTextClean=$true
    foreach($entry in $portableFiles | Where-Object {$_.Name -match '\.(md|txt)$'}){
      $bytes=Get-Bytes $entry
      $text=[Text.Encoding]::UTF8.GetString($bytes)
      if($text -match 'gh[pousr]_[A-Za-z0-9_]{20,}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----'){$portableTextClean=$false}
    }
    Check $portableTextClean 'Portable archive documentation contains no credential or private-key patterns'
    if($embedded.Count -eq 1){
      $bytes=Get-Bytes $embedded[0];$stream=[IO.MemoryStream]::new($bytes)
      try{$embeddedHash=(Get-FileHash -InputStream $stream -Algorithm SHA256).Hash.ToLowerInvariant()}finally{$stream.Dispose()}
      $standalone=$metadata['EyeBreakReminder.exe'].SHA256
      Check ($embeddedHash -ceq $standalone) 'Portable executable is byte-identical to the standalone published EXE' ([pscustomobject]@{Portable=$embeddedHash;Standalone=$standalone})
      $portableDir=Join-Path $ArtifactsDirectory 'portable-extracted'
      Expand-Archive -LiteralPath $portablePath -DestinationPath $portableDir -Force
      $portableExe=Get-ChildItem -LiteralPath $portableDir -Filter EyeBreakReminder.exe -Recurse | Select-Object -First 1
      if($portableExe){$portableDiskHash=(Get-FileHash -LiteralPath $portableExe.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
      Check ($portableExe -and $portableDiskHash -ceq $standalone) 'Extracted portable executable matches the standalone published EXE' ([pscustomobject]@{Path=if($portableExe){$portableExe.FullName}else{$null};SHA256=$portableDiskHash})
    }
  } finally {$portableZip.Dispose()}

  $sourcePath=Join-Path $ArtifactsDirectory 'EyeBreakReminder-Source.zip'
  $gitArchive=Join-Path $ArtifactsDirectory 'main-908a215-git-archive.zip'
  & git archive --format=zip "--output=$gitArchive" $approvedMain
  if($LASTEXITCODE -ne 0){throw 'Could not create the approved main Git archive for source comparison.'}
  $releaseZip=[IO.Compression.ZipFile]::OpenRead($sourcePath)
  $gitZip=[IO.Compression.ZipFile]::OpenRead($gitArchive)
  $exact=0;$crlfOnly=0;$mismatch=[System.Collections.Generic.List[string]]::new();$missing=[System.Collections.Generic.List[string]]::new();$paths=[System.Collections.Generic.List[string]]::new()
  try{
    foreach($entry in $releaseZip.Entries | Where-Object {-not $_.FullName.EndsWith('/')}){
      if(-not $entry.FullName.StartsWith('EyeBreakReminder/')){$mismatch.Add("$($entry.FullName) has an unexpected root");continue}
      $relative=$entry.FullName.Substring('EyeBreakReminder/'.Length)
      $paths.Add($relative)
      if($relative -match '(^|/)\.git(/|$)|(^|/)release(/|$)|credential|secret|token'){ $mismatch.Add("$relative has a disallowed path");continue }
      $base=$gitZip.GetEntry($relative)
      if(-not $base){$missing.Add($relative);continue}
      $actual=Get-Bytes $entry;$expectedBytes=Get-Bytes $base
      if(Same-Bytes $actual $expectedBytes){$exact++}
      elseif(Same-Bytes (Normalize-TextBytes $actual) (Normalize-TextBytes $expectedBytes)){$crlfOnly++}
      else{$mismatch.Add($relative)}
      if($relative -match '\.(md|txt|yml|yaml|cpp|hpp|h|rc|nsi|py|ini|editorconfig|gitignore)$'){
        $text=[Text.Encoding]::UTF8.GetString($actual)
        if($text -match 'gh[pousr]_[A-Za-z0-9_]{20,}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----'){$mismatch.Add("$relative contains a credential/private-key pattern")}
      }
    }
    $pathSet=@($paths | Sort-Object -Unique)
    $hasFinalReport=($pathSet -contains 'docs/FINAL_PRE_RELEASE_VERIFICATION.md')
    $hasGit=($pathSet | Where-Object {$_ -match '(^|/)\.git(/|$)'}).Count -gt 0
    $hasRelease=($pathSet | Where-Object {$_ -match '(^|/)release(/|$)'}).Count -gt 0
    Check (($missing.Count -eq 0) -and ($mismatch.Count -eq 0) -and (($exact+$crlfOnly) -eq $paths.Count)) 'Every published source file matches the approved Git commit' ([pscustomobject]@{Files=$paths.Count;ExactBlobs=$exact;CRLFOnly=$crlfOnly;Missing=$missing.ToArray();Mismatches=$mismatch.ToArray()})
    Check (-not $hasFinalReport -and -not $hasGit -and -not $hasRelease) 'Source archive excludes the pre-release report, .git metadata, and build outputs' ([pscustomobject]@{FinalReportExcluded=(-not $hasFinalReport);GitExcluded=(-not $hasGit);BuildOutputsExcluded=(-not $hasRelease);EntryCount=$paths.Count})
  } finally {$releaseZip.Dispose();$gitZip.Dispose()}

} catch {
  Add-Check 'Download audit runner' 'FAIL' $_.Exception.Message
} finally {
  $summary=[pscustomobject]@{
    Application='Eye Break Reminder'
    Release='v1.2.0'
    ReleaseUrl='https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/tag/v1.2.0'
    ApprovedMainCommit=$approvedMain
    PreviouslyTestedProductSource=$testedSource
    Artifacts=$metadata
    Events=$events.ToArray()
    Pass=(@($events | Where-Object Status -eq 'PASS')).Count
    Fail=(@($events | Where-Object Status -eq 'FAIL')).Count
    NotTested=(@($events | Where-Object Status -eq 'NOT TESTED')).Count
    CompletedUtc=[DateTime]::UtcNow.ToString('o')
  }
  $json=Join-Path $EvidenceDirectory 'published-release-download-audit.json'
  $summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $json -Encoding UTF8
  $summary | ConvertTo-Json -Depth 12
}
if($summary.Fail -gt 0){exit 1}
