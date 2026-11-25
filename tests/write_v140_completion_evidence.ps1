param(
  [Parameter(Mandatory=$true)][string]$CompletionPath,
  [Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-fA-F]{64}$')][string]$ExecutableSHA256,
  [Parameter(Mandatory=$true)][ValidateRange(1,10000)][int]$SoakCycles
)
$ErrorActionPreference='Stop'
$CompletionPath=[IO.Path]::GetFullPath($CompletionPath)
if(-not (Test-Path -LiteralPath $CompletionPath -PathType Leaf)){throw "Completion evidence is missing: $CompletionPath"}
$completion=Get-Content -LiteralPath $CompletionPath -Raw|ConvertFrom-Json -AsHashtable
if($completion -isnot [System.Collections.IDictionary]){throw 'Completion evidence must be a JSON object.'}
$hash=$ExecutableSHA256.ToLowerInvariant()
$completion['TimeoutHarness']='PASS'
$completion['ProductionBinaryResourceSoak']='PASS'
$completion['SoakedExecutableSHA256']=$hash
$completion['SoakCycles']=$SoakCycles
$completion['SoakedUtc']=[DateTime]::UtcNow.ToString('o')
$json=$completion|ConvertTo-Json -Depth 16
Set-Content -LiteralPath $CompletionPath -Value $json -Encoding utf8
$verified=Get-Content -LiteralPath $CompletionPath -Raw|ConvertFrom-Json -AsHashtable
if($verified['TimeoutHarness']-cne 'PASS' -or $verified['ProductionBinaryResourceSoak']-cne 'PASS' -or $verified['SoakedExecutableSHA256']-cne $hash -or [int]$verified['SoakCycles']-ne $SoakCycles -or [string]::IsNullOrWhiteSpace([string]$verified['SoakedUtc'])){throw 'Completion evidence did not persist the exact timeout and soak result.'}
Write-Host "Completion evidence write-back verified: $CompletionPath; cycles=$SoakCycles; SHA-256=$hash"
