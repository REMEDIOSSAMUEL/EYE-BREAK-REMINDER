function Get-ProcessTcpConnectionCount {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][ValidateRange(1,[int]::MaxValue)][int]$ProcessId,
    [scriptblock]$Query
  )
  try {
    if ($null -eq $Query) {
      $connections = @(Get-NetTCPConnection -OwningProcess $ProcessId -ErrorAction Stop)
    } else {
      $connections = @(& $Query $ProcessId)
    }
    return [pscustomobject]@{Available=$true;Count=$connections.Count;Error=$null}
  } catch {
    if ($_.CategoryInfo.Category -eq [Management.Automation.ErrorCategory]::ObjectNotFound) {
      return [pscustomobject]@{Available=$true;Count=0;Error=$null}
    }
    return [pscustomobject]@{Available=$false;Count=$null;Error=$_.Exception.Message}
  }
}