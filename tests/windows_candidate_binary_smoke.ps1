param(
  [Parameter(Mandatory=$true)][string]$StandaloneExecutable,
  [Parameter(Mandatory=$true)][string]$PortableArchive,
  [Parameter(Mandatory=$true)][string]$EvidenceDirectory,
  [string]$ExpectedProductVersion = '1.3.0'
)
$ErrorActionPreference='Stop'
$StandaloneExecutable=[IO.Path]::GetFullPath($StandaloneExecutable)
$PortableArchive=[IO.Path]::GetFullPath($PortableArchive)
$EvidenceDirectory=[IO.Path]::GetFullPath($EvidenceDirectory)
foreach($path in @($StandaloneExecutable,$PortableArchive)){
  if(-not (Test-Path -LiteralPath $path -PathType Leaf)){throw "Candidate file is missing: $path"}
}
if(-not [Environment]::UserInteractive){throw 'The candidate executable smoke test requires an interactive Windows session.'}
if(-not ('EBR_CANDIDATE_SMOKE_Native' -as [type])){
  Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class EBR_CANDIDATE_SMOKE_Native {
  [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="RegisterWindowMessageW", SetLastError=true)]
  public static extern uint RegisterWindowMessage(string name);
  [DllImport("user32.dll", SetLastError=true)]
  [return: MarshalAs(UnmanagedType.Bool)] public static extern bool PostMessage(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
}
'@
}
[void][IO.Directory]::CreateDirectory($EvidenceDirectory)
$tempRoot=Join-Path $env:RUNNER_TEMP ('ebr-candidate-smoke-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($tempRoot)
$results=[System.Collections.Generic.List[object]]::new()
$ownedProcesses=[System.Collections.Generic.List[Diagnostics.Process]]::new()
function Invoke-CandidateLaunch([string]$Executable,[string]$Label,[string]$ExpectedHash){
  $Executable=[IO.Path]::GetFullPath($Executable)
  $file=Get-Item -LiteralPath $Executable
  $version=[string]$file.VersionInfo.ProductVersion
  if($version -notmatch ('^'+[regex]::Escape($ExpectedProductVersion)+'(\.0)?$')){throw "$Label file version was '$version', expected $ExpectedProductVersion."}
  $hash=(Get-FileHash -LiteralPath $Executable -Algorithm SHA256).Hash.ToLowerInvariant()
  if($ExpectedHash -and $hash -ne $ExpectedHash){throw "$Label executable hash did not match the standalone candidate."}
  $stale=@(Get-Process -Name EyeBreakReminder -ErrorAction SilentlyContinue)
  if($stale.Count){throw "Refusing to launch $Label while an Eye Break Reminder process is already running."}
  $process=Start-Process -FilePath $Executable -PassThru
  $ownedProcesses.Add($process)
  $watch=[Diagnostics.Stopwatch]::StartNew();$window=[IntPtr]::Zero
  while($watch.Elapsed.TotalSeconds -lt 20 -and -not $process.HasExited){
    $process.Refresh();$window=$process.MainWindowHandle
    if($window -ne [IntPtr]::Zero){break}
    Start-Sleep -Milliseconds 150
  }
  if($process.HasExited){throw "$Label candidate exited during launch with code $($process.ExitCode)."}
  if($window -eq [IntPtr]::Zero){throw "$Label candidate did not create a visible main window within 20 seconds."}
  $process.Refresh()
  $actualPath=[IO.Path]::GetFullPath($process.Path)
  if($actualPath -ine $Executable){throw "$Label launched '$actualPath' instead of '$Executable'."}
  $event= [EBR_CANDIDATE_SMOKE_Native]::RegisterWindowMessage('EyeBreakReminder.Exit.Native.1')
  if(-not $event){throw "Could not register the application's documented graceful-exit message."}
  if(-not [EBR_CANDIDATE_SMOKE_Native]::PostMessage($window,$event,[IntPtr]::Zero,[IntPtr]::Zero)){throw "$Label candidate did not accept the graceful-exit message."}
  if(-not $process.WaitForExit(15000)){
    $process.Refresh()
    if(-not $process.HasExited -and [IO.Path]::GetFullPath($process.Path) -ieq $Executable){Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue}
    throw "$Label candidate did not exit cleanly after its owned window received the application exit message."
  }
  $results.Add([pscustomobject]@{Name=$Label;Status='PASS';Path=$Executable;ProductVersion=$version;SHA256=$hash;Pid=$process.Id;WindowHandle=('0x{0:X}' -f $window.ToInt64());ExitCode=$process.ExitCode})
}
try{
  $standaloneHash=(Get-FileHash -LiteralPath $StandaloneExecutable -Algorithm SHA256).Hash.ToLowerInvariant()
  Invoke-CandidateLaunch $StandaloneExecutable 'Standalone candidate executable launch and graceful exit' $standaloneHash
  $extract=Join-Path $tempRoot 'portable'
  Expand-Archive -LiteralPath $PortableArchive -DestinationPath $extract -Force
  $portableExecutable=Join-Path $extract 'EyeBreakReminder.exe'
  if(-not (Test-Path -LiteralPath $portableExecutable -PathType Leaf)){throw 'Portable archive did not contain its root EyeBreakReminder.exe.'}
  Invoke-CandidateLaunch $portableExecutable 'Portable candidate executable launch and graceful exit' $standaloneHash
  $summary=[pscustomobject]@{Application='Eye Break Reminder';Version=$ExpectedProductVersion;StandaloneSHA256=$standaloneHash;PortableExecutableSHA256=(Get-FileHash -LiteralPath $portableExecutable -Algorithm SHA256).Hash.ToLowerInvariant();PortableArchiveSHA256=(Get-FileHash -LiteralPath $PortableArchive -Algorithm SHA256).Hash.ToLowerInvariant();Results=$results.ToArray();Passed=$results.Count;Failed=0;CompletedUtc=[DateTime]::UtcNow.ToString('o')}
  $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'candidate-binary-smoke-results.json') -Encoding UTF8
  Write-Output "PASS: $($results.Count) exact candidate standalone/portable launch checks."
}finally{
  foreach($process in $ownedProcesses){
    try{$process.Refresh();if(-not $process.HasExited){$path=[IO.Path]::GetFullPath($process.Path);if($path -ieq $StandaloneExecutable -or $path.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase)){Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue}};$process.Dispose()}catch{}
  }
  if(Test-Path -LiteralPath $tempRoot){Remove-Item -LiteralPath $tempRoot -Recurse -Force}
}
