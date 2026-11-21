param(
  [string]$EvidenceDirectory,
  [string]$ExecutablePath
)
$ErrorActionPreference='Stop'

$sourcePath=Join-Path $PSScriptRoot 'windows_break_user_resource_soak.ps1'
$tokens=$null;$parseErrors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($sourcePath,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw "Resource-soak source does not parse: $($parseErrors|Out-String)"}
$required=@('Median','Slope','SummaryFromMetrics')
$definitions=@($ast.FindAll({param($node)$node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $required -contains $node.Name},$true))
foreach($name in $required){$definition=@($definitions|Where-Object Name -CEQ $name);if($definition.Count-ne1){throw "Expected exactly one $name definition in the soak harness."};Invoke-Expression $definition[0].Extent.Text}

$synthetic=@(
  [pscustomobject]@{Cycle=0;ThreadCount=4},[pscustomobject]@{Cycle=0;ThreadCount=6},
  [pscustomobject]@{Cycle=1;ThreadCount=5},[pscustomobject]@{Cycle=1;ThreadCount=7},
  [pscustomobject]@{Cycle=2;ThreadCount=6},[pscustomobject]@{Cycle=2;ThreadCount=6},
  [pscustomobject]@{Cycle=3;ThreadCount=7},[pscustomobject]@{Cycle=3;ThreadCount=7},
  [pscustomobject]@{Cycle=4;ThreadCount=7},[pscustomobject]@{Cycle=4;ThreadCount=7},
  [pscustomobject]@{Cycle=5;ThreadCount=8},[pscustomobject]@{Cycle=5;ThreadCount=8}
)
$script:metrics=$synthetic
$syntheticSummary=SummaryFromMetrics 'threads' 'ThreadCount'
if($syntheticSummary.StartMedian-ne6-or$syntheticSummary.EndMedian-ne7-or$syntheticSummary.Minimum-ne5-or$syntheticSummary.Maximum-ne8-or$syntheticSummary.CycleGroups-ne6){throw "Synthetic thread summary was incorrect: $(ConvertTo-Json $syntheticSummary -Compress)"}

if([string]::IsNullOrWhiteSpace($EvidenceDirectory)-xor[string]::IsNullOrWhiteSpace($ExecutablePath)){throw 'EvidenceDirectory and ExecutablePath must be supplied together.'}
if(-not[string]::IsNullOrWhiteSpace($EvidenceDirectory)){
  $evidence=[IO.Path]::GetFullPath($EvidenceDirectory)
  $summaryPath=Join-Path $evidence 'soak-summary.json';$tracePath=Join-Path $evidence 'resource-time-series.csv';$cyclePath=Join-Path $evidence 'cycle-results.csv'
  foreach($path in @($summaryPath,$tracePath,$cyclePath,$ExecutablePath)){if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "Required resource-soak evidence is missing: $path"}}
  $summary=Get-Content -LiteralPath $summaryPath -Raw|ConvertFrom-Json
  $exeHash=(Get-FileHash -LiteralPath $ExecutablePath -Algorithm SHA256).Hash.ToLowerInvariant()
  if($summary.SHA256-cne$exeHash){throw 'Resource-soak trace belongs to a different candidate executable.'}
  $trace=@(Import-Csv -LiteralPath $tracePath);$cycles=@(Import-Csv -LiteralPath $cyclePath)
  if($trace.Count-ne[int]$summary.MetricSamples-or$cycles.Count-ne110-or@($cycles|Where-Object{$_.StatusAfter-cne'Running'-or[int]$_.BreakWindowsAfter-ne0}).Count){throw 'Resource-soak trace/cycle rows do not satisfy the recorded exact 110-cycle summary.'}
  if(@($trace|Where-Object{[string]::IsNullOrWhiteSpace([string]$_.ThreadCount)}).Count){throw 'One or more resource samples lack thread telemetry.'}
  $script:metrics=$trace
  $threadSummary=SummaryFromMetrics 'threads' 'ThreadCount'
  if($threadSummary.CycleGroups-lt110-or$threadSummary.Minimum-lt1-or$threadSummary.Maximum-gt128){throw "Thread summary is outside the valid application-process range: $(ConvertTo-Json $threadSummary -Compress)"}
  $traceHash=(Get-FileHash -LiteralPath $tracePath -Algorithm SHA256).Hash.ToLowerInvariant()
  $summary.ThreadCountSummary=$threadSummary
  $summary|ConvertTo-Json -Depth 100|Set-Content -LiteralPath $summaryPath -Encoding UTF8
  [pscustomobject]@{Status='PASS';CandidateExecutableSHA256=$exeHash;TraceSHA256=$traceHash;MetricSamples=$trace.Count;CycleRows=$cycles.Count;SyntheticCheck='PASS';ThreadCountSummary=$threadSummary;SummaryJsonUpdated=$true;UpdatedUtc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $evidence 'resource-thread-summary-verification.json') -Encoding UTF8
  Write-Output ("Resource-soak thread summary: start median {0}, end median {1}, range {2}–{3}, slope {4}/cycle" -f $threadSummary.StartMedian,$threadSummary.EndMedian,$threadSummary.Minimum,$threadSummary.Maximum,$threadSummary.SlopePerCycle)
}
Write-Output 'Resource-soak summary unit checks PASS.'
