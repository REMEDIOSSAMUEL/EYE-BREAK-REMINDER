param(
  [string]$EvidenceDirectory = (Join-Path (Get-Location) 'build\post-release-evidence')
)
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$expectedEvidence = [IO.Path]::GetFullPath((Join-Path $repoRoot 'build\post-release-evidence'))
if ([IO.Path]::GetFullPath($EvidenceDirectory) -ine $expectedEvidence) { throw "Refusing to write process-handle evidence outside $expectedEvidence" }
[void][IO.Directory]::CreateDirectory($expectedEvidence)

$native = @'
using System;
using System.Runtime.InteropServices;
public static class EBR_EXIT_HANDLE_PROBE {
  [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr OpenProcess(uint desiredAccess, bool inheritHandle, int processId);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr handle);
}
'@
Add-Type -TypeDefinition $native -ErrorAction Stop

$expectedExitCode = 47
$process = $null
$handle = [IntPtr]::Zero
$waitResult = $null
$actualExitCode = $null
$errorText = ''
try {
  $process = Start-Process -FilePath $env:ComSpec -ArgumentList '/d','/c','ping -n 3 127.0.0.1 > nul & exit 47' -WindowStyle Hidden -PassThru
  $handle = [EBR_EXIT_HANDLE_PROBE]::OpenProcess(0x00101000, $false, $process.Id)
  if ($handle -eq [IntPtr]::Zero) { throw "OpenProcess failed with Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
  $waitResult = [EBR_EXIT_HANDLE_PROBE]::WaitForSingleObject($handle, 10000)
  if ($waitResult -ne 0) { throw "Process handle did not signal within 10 seconds; wait result $waitResult" }
  [uint32]$code = 0
  if (-not [EBR_EXIT_HANDLE_PROBE]::GetExitCodeProcess($handle, [ref]$code)) { throw "GetExitCodeProcess failed with Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
  $actualExitCode = [int]$code
} catch {
  $errorText = $_.Exception.Message
} finally {
  if ($handle -ne [IntPtr]::Zero) { [void][EBR_EXIT_HANDLE_PROBE]::CloseHandle($handle) }
  if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
}

$passed = ($actualExitCode -eq $expectedExitCode)
$record = [pscustomobject]@{
  Name = 'Retained native process handle captures child exit code after termination'
  Status = if ($passed) { 'PASS' } else { 'FAIL' }
  ExpectedExitCode = $expectedExitCode
  ActualExitCode = $actualExitCode
  WaitResult = $waitResult
  Error = $errorText
  Utc = [DateTime]::UtcNow.ToString('o')
}
$record | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $expectedEvidence 'process-exit-handle-probe.json') -Encoding UTF8
$record
if (-not $passed) { exit 1 }
