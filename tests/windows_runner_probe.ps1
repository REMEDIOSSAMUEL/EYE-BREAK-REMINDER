param(
  [string]$EvidenceDirectory = (Join-Path $PSScriptRoot '..\build\pre-release-evidence')
)
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$expected = [IO.Path]::GetFullPath((Join-Path $repoRoot 'build\pre-release-evidence'))
if ([IO.Path]::GetFullPath($EvidenceDirectory) -ine $expected) {
  throw "Refusing to write runner capability evidence outside $expected"
}
[void][IO.Directory]::CreateDirectory($expected)

$native = @'
using System;
using System.Runtime.InteropServices;
public static class EBR_RUNNER_PROBE {
  [DllImport("user32.dll")] public static extern IntPtr GetShellWindow();
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowW(string className, string windowName);
  [DllImport("user32.dll", SetLastError=true)] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
}
'@
Add-Type -TypeDefinition $native -ErrorAction Stop
$shell = [EBR_RUNNER_PROBE]::GetShellWindow()
$taskbar = [EBR_RUNNER_PROBE]::FindWindowW('Shell_TrayWnd', $null)
$shellProcessId = [uint32]0
if ($shell -ne [IntPtr]::Zero) { [void][EBR_RUNNER_PROBE]::GetWindowThreadProcessId($shell, [ref]$shellProcessId) }
$shellProcessName = ''
if ($shellProcessId) { try { $shellProcessName = (Get-Process -Id $shellProcessId -ErrorAction Stop).ProcessName } catch {} }
$sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
$interactive = [Environment]::UserInteractive -and $sessionId -gt 0 -and
  $shell -ne [IntPtr]::Zero -and $taskbar -ne [IntPtr]::Zero -and
  $shellProcessName -ieq 'explorer'
$record = [pscustomobject]@{
  utc = [DateTime]::UtcNow.ToString('o')
  osCaption = (Get-CimInstance Win32_OperatingSystem).Caption
  osVersion = (Get-CimInstance Win32_OperatingSystem).Version
  osBuild = (Get-CimInstance Win32_OperatingSystem).BuildNumber
  sessionId = $sessionId
  sessionName = $env:SESSIONNAME
  userInteractive = [Environment]::UserInteractive
  shellWindow = ('0x{0:X}' -f $shell.ToInt64())
  taskbarWindow = ('0x{0:X}' -f $taskbar.ToInt64())
  shellProcessName = $shellProcessName
  interactiveDesktopAvailable = [bool]$interactive
  reason = if ($interactive) { 'Explorer shell and taskbar are present in an interactive user session.' } else { 'No interactive Explorer desktop and taskbar were exposed to this runner session.' }
}
$record | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $expected 'runner-capabilities.json') -Encoding UTF8
$record | ConvertTo-Json -Compress
