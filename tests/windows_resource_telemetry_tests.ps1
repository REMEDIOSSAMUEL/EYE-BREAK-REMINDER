param([string]$EvidencePath='build/v1.4.0-updater-evidence/resource-telemetry-unit-tests.json')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'windows_resource_telemetry.ps1')
$script:assertions = 0
$script:failures = [Collections.Generic.List[string]]::new()
function Assert-Equal($Expected,$Actual,[string]$Name) {
  $script:assertions++
  if ($Expected -ne $Actual) {
    $script:failures.Add("$Name expected '$Expected'; got '$Actual'.")
    Write-Host "FAIL: $Name"
    return
  }
  Write-Host "PASS: $Name"
}
$populated = Get-ProcessTcpConnectionCount -ProcessId 42 -Query {
  param($ownerId)
  [pscustomobject]@{OwningProcess=$ownerId;State='Established'}
  [pscustomobject]@{OwningProcess=$ownerId;State='TimeWait'}
}
Assert-Equal $true $populated.Available 'TCP query succeeds'
Assert-Equal 2 $populated.Count 'TCP sessions are counted'
$empty = Get-ProcessTcpConnectionCount -ProcessId 42 -Query { param($ownerId) }
Assert-Equal $true $empty.Available 'empty TCP result is available telemetry'
Assert-Equal 0 $empty.Count 'empty TCP result is recorded as zero'
$script:noConnectionError = [Management.Automation.ErrorRecord]::new(
  [Exception]::new('No TCP entries for this process.'),
  'NoTcpEntries',
  [Management.Automation.ErrorCategory]::ObjectNotFound,
  $null
)
$none = Get-ProcessTcpConnectionCount -ProcessId 42 -Query { param($ownerId) throw $script:noConnectionError }
Assert-Equal $true $none.Available 'no-match error is available telemetry'
Assert-Equal 0 $none.Count 'no-match error maps to zero sessions'
$script:permissionError = [Management.Automation.ErrorRecord]::new(
  [UnauthorizedAccessException]::new('Access denied.'),
  'TcpQueryDenied',
  [Management.Automation.ErrorCategory]::PermissionDenied,
  $null
)
$denied = Get-ProcessTcpConnectionCount -ProcessId 42 -Query { param($ownerId) throw $script:permissionError }
Assert-Equal $false $denied.Available 'permission errors remain unavailable'
Assert-Equal 'Access denied.' $denied.Error 'permission failure is retained'
$report=[pscustomobject]@{Status=if($script:failures.Count){'FAIL'}else{'PASS'};Assertions=$script:assertions;Failures=$script:failures.ToArray();TestCases=@('populated connection list','successful empty list','ObjectNotFound maps to zero','permission failure stays unavailable');Utc=[DateTime]::UtcNow.ToString('o')}
$fullEvidence=[IO.Path]::GetFullPath($EvidencePath)
[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($fullEvidence))
$report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $fullEvidence -Encoding UTF8
Write-Host ($report | ConvertTo-Json -Depth 5)
if($report.Status -ne 'PASS'){exit 1}