param(
  [ValidatePattern('^v1\.2\.1$')][string]$ReleaseTag='v1.2.1',
  [Parameter(Mandatory=$true)][string]$ExpectedMainCommit,
  [string]$Destination=(Join-Path $PSScriptRoot '..\release')
)
$ErrorActionPreference='Stop'
$repoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$Destination=[IO.Path]::GetFullPath($Destination)
if($Destination -ine [IO.Path]::GetFullPath((Join-Path $repoRoot 'release'))){throw 'Refusing to download release assets outside the repository release folder.'}
[void][IO.Directory]::CreateDirectory($Destination)
$api='https://api.github.com/repos/REMEDIOSSAMUEL/EYE-BREAK-REMINDER'
$headers=@{Accept='application/vnd.github+json';'User-Agent'='EyeBreakReminder-PublishedReleaseVerification'}
$expectedNames=@('EyeBreakReminder.exe','EyeBreakReminder-Setup-x64.exe','EyeBreakReminder-Portable-x64.zip','EyeBreakReminder-Source.zip','EyeBreakReminder-SHA256.txt')
$events=[Collections.Generic.List[object]]::new()
function Assert([bool]$ok,[string]$name,$details=$null){if(-not $ok){throw "$name failed. Details: $(ConvertTo-Json -InputObject $details -Depth 8 -Compress)"};$events.Add([pscustomobject]@{Name=$name;Status='PASS';Details=$details;Utc=[DateTime]::UtcNow.ToString('o')})}
function Hash-Stream([IO.Stream]$stream){$sha=[Security.Cryptography.SHA256]::Create();try{$bytes=$sha.ComputeHash($stream);return [BitConverter]::ToString($bytes).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}}
function Hash-Entry([IO.Compression.ZipArchiveEntry]$entry){$stream=$entry.Open();try{return Hash-Stream $stream}finally{$stream.Dispose()}}
$summaryPath=Join-Path $Destination 'published-release-validation.json'
try{
  $release=Invoke-RestMethod -Method Get -Uri "$api/releases/tags/$ReleaseTag" -Headers $headers -TimeoutSec 30
  Assert ($release.tag_name -ceq $ReleaseTag -and $release.name -ceq 'Eye Break Reminder v1.2.1' -and -not $release.draft -and -not $release.prerelease -and $release.published_at) 'Published stable release metadata' ([pscustomobject]@{Tag=$release.tag_name;Title=$release.name;Draft=$release.draft;Prerelease=$release.prerelease;PublishedAt=$release.published_at;Url=$release.html_url})
  Assert ($release.html_url -ceq "https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/tag/$ReleaseTag") 'Official release URL' $release.html_url
  $latest=Invoke-RestMethod -Method Get -Uri "$api/releases/latest" -Headers $headers -TimeoutSec 30
  Assert ($latest.tag_name -ceq $ReleaseTag -and -not $latest.draft -and -not $latest.prerelease) 'Latest public stable release is v1.2.1' ([pscustomobject]@{Tag=$latest.tag_name;Url=$latest.html_url})
  $main=Invoke-RestMethod -Method Get -Uri "$api/branches/main" -Headers $headers -TimeoutSec 30
  $ref=Invoke-RestMethod -Method Get -Uri "$api/git/ref/tags/$ReleaseTag" -Headers $headers -TimeoutSec 30
  $targetSha=[string]$ref.object.sha
  if($ref.object.type -eq 'tag'){$tagObject=Invoke-RestMethod -Method Get -Uri "$api/git/tags/$targetSha" -Headers $headers -TimeoutSec 30;$targetSha=[string]$tagObject.object.sha}
  Assert ($targetSha -ceq $ExpectedMainCommit.ToLowerInvariant() -and $main.commit.sha -ceq $ExpectedMainCommit.ToLowerInvariant()) 'Release tag and current main point to the dispatched approved commit' ([pscustomobject]@{Expected=$ExpectedMainCommit;TagTarget=$targetSha;Main=$main.commit.sha})
  $assets=@($release.assets)
  $names=@($assets|ForEach-Object{[string]$_.name})
  Assert ($assets.Count -eq 5 -and (@($names|Sort-Object) -join ([string][char]10)) -ceq (@($expectedNames|Sort-Object) -join ([string][char]10)) -and @($names|Select-Object -Unique).Count -eq 5) 'Exactly five uniquely named release assets exist' $names
  $assetRecords=[Collections.Generic.List[object]]::new()
  foreach($name in $expectedNames){
    $asset=@($assets|Where-Object{$_.name -ceq $name})|Select-Object -First 1
    if(-not $asset){throw "Expected release asset is missing: $name"}
    if($asset.browser_download_url -cne "https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/download/$ReleaseTag/$name"){throw "Unexpected release download URL for $name"}
    $path=Join-Path $Destination $name
    Invoke-WebRequest -UseBasicParsing -Uri $asset.browser_download_url -OutFile $path -TimeoutSec 180 -Headers $headers
    $file=Get-Item -LiteralPath $path
    $actual=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    $apiDigest=[string]$asset.digest
    if($apiDigest -notmatch '^sha256:[0-9a-fA-F]{64}$'){throw "GitHub release API did not provide a SHA-256 digest for $name"}
    $apiDigest=$apiDigest.Substring(7).ToLowerInvariant()
    Assert ($file.Length -eq [long]$asset.size -and $actual -ceq $apiDigest) "Downloaded $name matches GitHub byte size and SHA-256" ([pscustomobject]@{Bytes=$file.Length;ApiBytes=$asset.size;SHA256=$actual;ApiSHA256=$apiDigest;Url=$asset.browser_download_url})
    $assetRecords.Add([pscustomobject]@{Name=$name;Bytes=$file.Length;SHA256=$actual;Url=$asset.browser_download_url})
  }
  $manifestPath=Join-Path $Destination 'EyeBreakReminder-SHA256.txt'
  $manifestLines=@(Get-Content -LiteralPath $manifestPath | Where-Object{$_.Trim()})
  Assert ($manifestLines.Count -eq 4) 'Checksum manifest lists exactly the four non-manifest downloads' $manifestLines.Count
  $manifest=@{}
  foreach($line in $manifestLines){if($line -notmatch '^([0-9a-fA-F]{64})\s+\*?(.+?)\s*$'){throw "Malformed checksum manifest line: $line"};$manifest[$Matches[2]]=$Matches[1].ToLowerInvariant()}
  foreach($name in $expectedNames[0..3]){$actual=(Get-FileHash -LiteralPath (Join-Path $Destination $name) -Algorithm SHA256).Hash.ToLowerInvariant();Assert ($manifest.ContainsKey($name) -and $manifest[$name] -ceq $actual) "Manifest SHA-256 matches $name" ([pscustomobject]@{Name=$name;Manifest=$manifest[$name];Actual=$actual})}
  $exePath=Join-Path $Destination 'EyeBreakReminder.exe'
  $setupPath=Join-Path $Destination 'EyeBreakReminder-Setup-x64.exe'
  $exeVersion=(Get-Item -LiteralPath $exePath).VersionInfo
  $setupVersion=(Get-Item -LiteralPath $setupPath).VersionInfo
  Assert ($exeVersion.ProductName -eq 'Eye Break Reminder' -and $exeVersion.ProductVersion -match '^1\.2\.1(\.0)?$') 'Downloaded standalone executable has v1.2.1 metadata' ([pscustomobject]@{Product=$exeVersion.ProductName;Version=$exeVersion.ProductVersion})
  Assert ($setupVersion.ProductVersion -match '^1\.2\.1(\.0)?$') 'Downloaded installer has v1.2.1 metadata' $setupVersion.ProductVersion
  Assert ((Get-AuthenticodeSignature -LiteralPath $exePath).Status -eq 'NotSigned' -and (Get-AuthenticodeSignature -LiteralPath $setupPath).Status -eq 'NotSigned') 'Published executable and installer are unsigned as disclosed' 'NotSigned'
  Add-Type -AssemblyName System.IO.Compression
  $portable=[IO.Compression.ZipFile]::OpenRead((Join-Path $Destination 'EyeBreakReminder-Portable-x64.zip'))
  try{
    $portableExe=@($portable.Entries|Where-Object{$_.FullName -ceq 'EyeBreakReminder.exe'})
    Assert ($portableExe.Count -eq 1) 'Portable ZIP contains exactly one application executable' $portableExe.Count
    $portableHash=Hash-Entry $portableExe[0]
    Assert ($portableHash -ceq $assetRecords[0].SHA256) 'Portable executable bytes match the independently downloaded standalone executable' ([pscustomobject]@{Portable=$portableHash;Standalone=$assetRecords[0].SHA256})
    Assert (@($portable.Entries|Where-Object{$_.FullName -ceq 'SIGNING-STATUS.txt'}).Count -eq 1) 'Portable ZIP discloses unsigned signing status'
  }finally{$portable.Dispose()}
  $source=[IO.Compression.ZipFile]::OpenRead((Join-Path $Destination 'EyeBreakReminder-Source.zip'))
  try{
    $sourceNames=@($source.Entries|ForEach-Object{$_.FullName})
    Assert (@($sourceNames|Select-Object -Unique).Count -eq $sourceNames.Count) 'Source ZIP paths are unique' $sourceNames.Count
    Assert (@($sourceNames|Where-Object{$_ -notmatch '^EyeBreakReminder/[^/].*' -or $_ -match '(^|/)\.\.(?:/|$)'}).Count -eq 0) 'Source ZIP paths are rooted and contain no traversal components'
    $expectedSource=@(& git -C $repoRoot ls-files)
    if($LASTEXITCODE -ne 0){throw 'git ls-files failed while verifying the source archive.'}
    $excludedDirs=@('release','build','dist','__pycache__')
    $excludedSuffix=@('.exe','.dll','.o','.obj','.pdb','.zip','.tmp','.pyc','.pfx','.pem','.p12','.key')
    $expectedSource=@($expectedSource|Where-Object{
      $relative=[string]$_
      $parts=$relative.Split('/')
      $parentParts=@();if($parts.Count -gt 1){$parentParts=$parts[0..($parts.Count-2)]}
      $hiddenParent=@($parentParts|Where-Object{$_ -like '.*' -and $_ -cne '.github'}).Count -gt 0
      $excludedParent=@($parentParts|Where-Object{$excludedDirs -contains $_}).Count -gt 0
      $excludedDocs=@('docs/FINAL_PRE_RELEASE_VERIFICATION.md','docs/V1.2.1_HOTFIX_VERIFICATION.md') -contains $relative
      $excludedBinary=($relative -ceq 'tests/core-tests') -or ($excludedSuffix -contains [IO.Path]::GetExtension($relative).ToLowerInvariant())
      -not($hiddenParent -or $excludedParent -or $excludedDocs -or $excludedBinary)
    })
    $expectedZipNames=@($expectedSource|ForEach-Object{"EyeBreakReminder/"+([string]$_).Replace('\','/')})
    Assert ((@($sourceNames|Sort-Object) -join ([string][char]10)) -ceq (@($expectedZipNames|Sort-Object) -join ([string][char]10))) 'Source ZIP file inventory matches the approved tracked source tree and documented exclusions' ([pscustomobject]@{Archive=$sourceNames.Count;Expected=$expectedZipNames.Count})
    foreach($entry in $source.Entries){
      $relative=$entry.FullName.Substring('EyeBreakReminder/'.Length).Replace('/',[IO.Path]::DirectorySeparatorChar)
      $localPath=Join-Path $repoRoot $relative
      if(-not(Test-Path -LiteralPath $localPath -PathType Leaf)){throw "Source ZIP file is absent from the approved checkout: $($entry.FullName)"}
      $sourceStream=$entry.Open();try{$archivedHash=Hash-Stream $sourceStream}finally{$sourceStream.Dispose()}
      $localHash=(Get-FileHash -LiteralPath $localPath -Algorithm SHA256).Hash.ToLowerInvariant()
      if($archivedHash -cne $localHash){throw "Source ZIP content differs from the approved checkout: $relative"}
    }
    $versionEntry=$source.GetEntry('EyeBreakReminder/VERSION')
    Assert ($versionEntry -ne $null) 'Source ZIP includes VERSION'
    $versionStream=$versionEntry.Open();$reader=[IO.StreamReader]::new($versionStream);try{$sourceVersion=$reader.ReadToEnd().Trim()}finally{$reader.Dispose()}
    Assert ($sourceVersion -ceq '1.2.1') 'Source ZIP reports version 1.2.1' $sourceVersion
    Assert (@($sourceNames|Where-Object{$_ -match '(?i)(^|/)(\.env|id_rsa|credentials\.json)$|(?i)\.(pfx|p12|pem|key)$'}).Count -eq 0) 'Source ZIP contains no credential or private-key file names'
  }finally{$source.Dispose()}
  $summary=[pscustomobject]@{Application='Eye Break Reminder';ReleaseTag=$ReleaseTag;ReleaseUrl=$release.html_url;TargetCommit=$targetSha;MainCommit=$main.commit.sha;DownloadedAtUtc=[DateTime]::UtcNow.ToString('o');Events=$events.ToArray();Assets=$assetRecords.ToArray();Pass=@($events|Where-Object Status -eq 'PASS').Count;Fail=0;NotTested=0}
  $summary|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $summaryPath -Encoding utf8
  $summary|ConvertTo-Json -Depth 8
}catch{
  $events.Add([pscustomobject]@{Name='Published release verification execution';Status='FAIL';Details=$_.Exception.ToString();Utc=[DateTime]::UtcNow.ToString('o')})
  [pscustomobject]@{Application='Eye Break Reminder';ReleaseTag=$ReleaseTag;ExpectedMainCommit=$ExpectedMainCommit;Events=$events.ToArray();Pass=@($events|Where-Object Status -eq 'PASS').Count;Fail=1}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $summaryPath -Encoding utf8
  throw
}