param(
  [Parameter(Mandatory=$true)][string]$ExecutablePath,
  [ValidateSet('1.2.1')][string]$ExpectedProductVersion='1.2.1',
  [Parameter(Mandatory=$true)][string]$ExpectedSHA256,
  [string]$EvidencePath='build/published-binary-smoke.json'
)
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:RUNNER_OS -ne 'Windows'){throw 'Refusing published-binary smoke outside disposable GitHub-hosted Windows.'}
if(-not [Environment]::UserInteractive -or [Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0){throw 'Interactive Windows desktop is unavailable.'}
$exe=(Resolve-Path -LiteralPath $ExecutablePath -ErrorAction Stop).Path
$actualHash=(Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant()
if($actualHash -cne $ExpectedSHA256.ToLowerInvariant()){throw "Published executable hash mismatch: $actualHash"}
$version=(Get-Item -LiteralPath $exe).VersionInfo
if($version.ProductName -ne 'Eye Break Reminder' -or $version.ProductVersion -notmatch ('^'+[regex]::Escape($ExpectedProductVersion)+'(\.0)?$')){throw "Published executable metadata mismatch: $($version.ProductName) $($version.ProductVersion)"}
if((Get-AuthenticodeSignature -LiteralPath $exe).Status -ne 'NotSigned'){throw 'Candidate signing status differs from the approved unsigned release.'}
$localAppData=[IO.Path]::GetFullPath([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData))
$dataPath=[IO.Path]::GetFullPath((Join-Path $localAppData 'EyeBreakReminder'))
if($dataPath -ine (Join-Path $localAppData 'EyeBreakReminder')){throw 'Refusing an unexpected app-data path.'}
if(Test-Path -LiteralPath $dataPath){throw "Refusing to overwrite pre-existing runner profile data: $dataPath"}
$oldProcesses=@(Get-Process -Name EyeBreakReminder -ErrorAction SilentlyContinue)
if($oldProcesses.Count){throw 'Refusing to launch beside an existing Eye Break Reminder process.'}
$events=[Collections.Generic.List[object]]::new();$started=$null;$ownsData=$false;$clean=$false
function Add-Result([string]$Name,[string]$Status,$Details=$null){$events.Add([pscustomobject]@{Name=$Name;Status=$Status;Details=$Details;Utc=[DateTime]::UtcNow.ToString('o')})}
try {
  $ownsData=$true
  $started=Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe) -PassThru
  Add-Result 'Actual published executable process started' 'PASS' ([pscustomobject]@{Path=$exe;Pid=$started.Id;SHA256=$actualHash;ProductVersion=$version.ProductVersion})
  $watch=[Diagnostics.Stopwatch]::StartNew();$window=[IntPtr]::Zero;$responsive=$false
  while($watch.Elapsed.TotalSeconds -lt 30){
    $started.Refresh();if($started.HasExited){throw "Published app exited during startup with code $($started.ExitCode)."}
    $proc=Get-Process -Id $started.Id -ErrorAction Stop;$window=$proc.MainWindowHandle
    if($window -ne [IntPtr]::Zero){try{$responsive=[bool]$proc.Responding}catch{$responsive=$false};if($responsive){break}}
    Start-Sleep -Milliseconds 200
  }
  if($window -eq [IntPtr]::Zero){throw 'Published app did not create a main desktop window within 30 seconds.'}
  if(-not $responsive){throw 'Published app main window did not respond to the Windows process responsiveness probe.'}
  Add-Result 'Published executable created a responsive Windows desktop window' 'PASS' ([pscustomobject]@{Pid=$started.Id;WindowHandle=('0x{0:X}' -f $window.ToInt64());Title=(Get-Process -Id $started.Id).MainWindowTitle;ElapsedSeconds=[math]::Round($watch.Elapsed.TotalSeconds,2)})
  $ownsData=$true
} catch { Add-Result 'Published executable smoke' 'FAIL' $_.Exception.ToString() }
finally {
  if($started){try{$started.Refresh();if(-not $started.HasExited){Stop-Process -Id $started.Id -Force -ErrorAction Stop;if(-not $started.WaitForExit(10000)){throw 'Owned smoke process did not exit.'}};$started.Dispose()}catch{Add-Result 'Owned process cleanup' 'FAIL' $_.Exception.Message}}
  if($ownsData -and (Test-Path -LiteralPath $dataPath)){
    try{$resolved=[IO.Path]::GetFullPath($dataPath);if($resolved -ine (Join-Path $localAppData 'EyeBreakReminder')){throw 'Refusing cleanup outside owned app data.'};$item=Get-Item -LiteralPath $resolved -Force;if(($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne 0){throw 'Refusing redirected app-data cleanup.'};Remove-Item -LiteralPath $resolved -Recurse -Force; $clean=-not(Test-Path -LiteralPath $resolved);if($clean){Add-Result 'Runner-created app data cleanup' 'PASS'}else{throw 'Runner app data remained after cleanup.'}}catch{Add-Result 'Runner-created app data cleanup' 'FAIL' $_.Exception.Message}
  }
  $dir=Split-Path -Parent $EvidencePath;$fullEvidence=[IO.Path]::GetFullPath($EvidencePath);$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'));if(-not $fullEvidence.StartsWith($repo,[StringComparison]::OrdinalIgnoreCase)){throw 'Evidence path escaped repository.'};if(-not(Test-Path -LiteralPath (Split-Path -Parent $fullEvidence))){New-Item -ItemType Directory -Force -Path (Split-Path -Parent $fullEvidence)|Out-Null};$summary=[pscustomobject]@{Application='Eye Break Reminder';Test='Published executable desktop smoke';Version=$ExpectedProductVersion;Path=$exe;SHA256=$actualHash;Windows=(Get-CimInstance Win32_OperatingSystem).Caption;Interactive=$true;Events=$events.ToArray();Pass=@($events|Where-Object Status -eq 'PASS').Count;Fail=@($events|Where-Object Status -eq 'FAIL').Count;CompletedUtc=[DateTime]::UtcNow.ToString('o')};$summary|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $fullEvidence -Encoding UTF8
}
if(@($events|Where-Object Status -eq 'FAIL').Count){throw 'Published executable smoke reported one or more failures.'}
Write-Output 'Published executable smoke: PASS'