param(
  [Parameter(Mandatory)][string]$InstallerPath,
  [Parameter(Mandatory)][string]$ExecutablePath,
  [Parameter(Mandatory)][string]$EvidenceDirectory
)
$ErrorActionPreference='Stop'

$expectedExeHash='07f6c1eaee5818df9f5c024310883ca94b8274a4f451186a8123974fb5e5f720'
$expectedInstallerHash='a15fc525557603dbed1ef0dccb8d128e500dfee91c6416b478513de790dd5c9b'
$runId=[string]$env:GITHUB_RUN_ID
$stageRoot=$null;$stageRootCreatedByThisRun=$false;$currentProfileProvenFresh=$false;$childProcess=$null;$childResultPath=$null;$childExited=$true;$activeConsoleUserSid=$null;$activeConsoleSessionId=$null
$cleanupErrors=[System.Collections.Generic.List[string]]::new();$cleanupActions=[System.Collections.Generic.List[string]]::new()

function Save-ActiveConsoleEvidence([string]$Path,$Value){
  $parent=Split-Path -Parent $Path
  if(-not(Test-Path -LiteralPath $parent)){[void][IO.Directory]::CreateDirectory($parent)}
  $Value|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $Path -Encoding utf8
}

function Get-ProcessesUsingActiveConsoleStage([string]$Root){
  $fullRoot=[IO.Path]::GetFullPath($Root).TrimEnd('\')+'\'
  $allProcesses=@(Get-CimInstance Win32_Process -ErrorAction Stop)
  @($allProcesses|Where-Object{
    $usesStage=$false
    if($_.ExecutablePath){$image=[IO.Path]::GetFullPath([string]$_.ExecutablePath);if($image.StartsWith($fullRoot,[StringComparison]::OrdinalIgnoreCase)){$usesStage=$true}}
    if(-not$usesStage-and$_.CommandLine-and([string]$_.CommandLine).IndexOf($Root,[StringComparison]::OrdinalIgnoreCase)-ge0){$usesStage=$true}
    $usesStage
  })
}

try{
  [void][IO.Directory]::CreateDirectory($EvidenceDirectory)
  $os=Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
  $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
  $principal=[Security.Principal.WindowsPrincipal]::new($identity)
  $isAdministrator=$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  $runnerValid=($env:GITHUB_ACTIONS-ceq'true'-and$env:RUNNER_ENVIRONMENT-ceq'github-hosted'-and$env:EBR_RUNNER_ENVIRONMENT_CONTEXT-ceq'github-hosted'-and$env:GITHUB_SERVER_URL-ceq'https://github.com'-and$env:GITHUB_REPOSITORY-ieq'REMEDIOSSAMUEL/EYE-BREAK-REMINDER'-and$env:RUNNER_OS-ceq'Windows'-and$env:RUNNER_ARCH-ceq'X64'-and$runId-and$env:RUNNER_TEMP-and$os.Caption-match'Windows Server 2025'-and[Runtime.InteropServices.RuntimeInformation]::OSArchitecture-eq[Runtime.InteropServices.Architecture]::X64-and[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture-eq[Runtime.InteropServices.Architecture]::X64)
  if(-not$runnerValid){throw "Requires the project's disposable GitHub-hosted Windows Server 2025 x64 runner; found '$($os.Caption)' / $([Runtime.InteropServices.RuntimeInformation]::OSArchitecture) / $env:RUNNER_ARCH."}
  if(-not[Environment]::UserInteractive){throw 'The current runner process is not interactive.'}
  if(-not$isAdministrator){throw 'Expected the GitHub runner active Console owner account to have its normal administrator token.'}
  $process=[Diagnostics.Process]::GetCurrentProcess()
  $preflightPath=Join-Path $PWD 'remaining-coverage-evidence/standard-user-console/server-console-standard-user-preflight.json'
  $preflight=Get-Content -LiteralPath $preflightPath -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
  if(-not$preflight.ReadyForCandidateTest-or[int]$preflight.Process.SessionId-ne$process.SessionId-or$identity.Name-ine[string]$preflight.Process.User-or$identity.User.Value-cne[string]$preflight.Process.UserSid){throw 'Current test process identity/session does not exactly match the already-verified active Console owner.'}
  $activeConsoleUserSid=[string]$identity.User.Value
  $activeConsoleSessionId=[int]$process.SessionId
  $candidate=(Resolve-Path -LiteralPath $ExecutablePath -ErrorAction Stop).Path
  $installer=(Resolve-Path -LiteralPath $InstallerPath -ErrorAction Stop).Path
  if((Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToLowerInvariant()-cne$expectedExeHash){throw 'Exact production candidate executable hash mismatch.'}
  if((Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()-cne$expectedInstallerHash){throw 'Exact production candidate installer hash mismatch.'}
  $profileData=Join-Path $env:LOCALAPPDATA 'EyeBreakReminder'
  $installDirectory=Join-Path $env:LOCALAPPDATA 'Programs\EyeBreakReminder'
  $uninstallRegistration='HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder'
  $applicationRegistration='HKCU:\Software\EyeBreakReminder'
  $oldCandidateProcesses=@(Get-CimInstance Win32_Process -Filter "Name='EyeBreakReminder.exe'" -ErrorAction Stop|Where-Object{$_.ExecutablePath})
  if((Test-Path -LiteralPath $profileData)-or(Test-Path -LiteralPath $installDirectory)-or(Test-Path -LiteralPath $uninstallRegistration)-or(Test-Path -LiteralPath $applicationRegistration)-or$oldCandidateProcesses.Count){throw 'The disposable active Console profile is not fresh; refusing to overwrite or remove pre-existing app state.'}
  $currentProfileProvenFresh=$true
  $stageRoot=[IO.Path]::GetFullPath((Join-Path $env:RUNNER_TEMP "eye-break-reminder-active-console-owner-$runId"))
  $runnerTemp=[IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')+'\'
  if(-not$stageRoot.StartsWith($runnerTemp,[StringComparison]::OrdinalIgnoreCase)){throw 'Active Console staging directory escaped RUNNER_TEMP.'}
  if($stageRoot.IndexOfAny([char[]]@('*','?','[',']'))-ge0){throw 'Active Console staging path contains PowerShell wildcard characters; refusing ambiguous directory creation.'}
  if(Test-Path -LiteralPath $stageRoot){throw 'Unique active Console staging directory already exists; refusing to reuse it.'}
  [void](New-Item -ItemType Directory -Path $stageRoot -ErrorAction Stop)
  $stageRootCreatedByThisRun=$true
  $stagedHarness=Join-Path $stageRoot 'windows_standard_user_acceptance.ps1'
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'windows_standard_user_acceptance.ps1') -Destination $stagedHarness -ErrorAction Stop
  $stagedInstaller=Join-Path $stageRoot 'EyeBreakReminder-Setup-x64.exe'
  $stagedExecutable=Join-Path $stageRoot 'EyeBreakReminder.exe'
  Copy-Item -LiteralPath $installer -Destination $stagedInstaller -ErrorAction Stop
  Copy-Item -LiteralPath $candidate -Destination $stagedExecutable -ErrorAction Stop
  $childResultPath=Join-Path $EvidenceDirectory 'active-console-owner-child-results.json'
  $runnerContextPath=Join-Path $stageRoot 'runner-context.json'
  $runnerContext=[ordered]@{
    GITHUB_ACTIONS=[string]$env:GITHUB_ACTIONS
    GITHUB_SERVER_URL=[string]$env:GITHUB_SERVER_URL
    GITHUB_REPOSITORY=[string]$env:GITHUB_REPOSITORY
    GITHUB_RUN_ID=[string]$env:GITHUB_RUN_ID
    GITHUB_WORKSPACE=[string]$env:GITHUB_WORKSPACE
    RUNNER_ENVIRONMENT=[string]$env:RUNNER_ENVIRONMENT
    RUNNER_OS=[string]$env:RUNNER_OS
    RUNNER_ARCH=[string]$env:RUNNER_ARCH
    RUNNER_NAME=[string]$env:RUNNER_NAME
    RUNNER_TEMP=[string]$env:RUNNER_TEMP
    ImageOS=[string]$env:ImageOS
    ImageVersion=[string]$env:ImageVersion
    EBR_RUNNER_ENVIRONMENT_CONTEXT=[string]$env:EBR_RUNNER_ENVIRONMENT_CONTEXT
  }
  $runnerContext|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $runnerContextPath -Encoding utf8

  $pwsh=Join-Path $PSHOME 'pwsh.exe'
  $psi=[Diagnostics.ProcessStartInfo]::new()
  $psi.FileName=$pwsh;$psi.WorkingDirectory=$stageRoot;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
  $psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
  foreach($argument in @(
    '-NoProfile','-ExecutionPolicy','Bypass','-File',$stagedHarness,
    '-Child','-AllowActiveConsoleAdministrator','-SkipCapabilityProbes',
    '-InstallerPath',$stagedInstaller,'-ExecutablePath',$stagedExecutable,
    '-EvidenceDirectory',[IO.Path]::GetFullPath($EvidenceDirectory),
    '-ChildResultPath',[IO.Path]::GetFullPath($childResultPath),
    '-ExpectedUserSid',[string]$identity.User.Value,
    '-ExpectedUserName',[string]$identity.Name,
    '-RunnerEnvironmentContext','github-hosted',
    '-RunnerContextPath',[IO.Path]::GetFullPath($runnerContextPath)
  )){[void]$psi.ArgumentList.Add([string]$argument)}
  $childProcess=[Diagnostics.Process]::Start($psi)
  if(-not$childProcess){throw 'Could not start the active Console owner harness child.'}
  $childExited=$false
  $stdoutTask=$childProcess.StandardOutput.ReadToEndAsync();$stderrTask=$childProcess.StandardError.ReadToEndAsync()
  if(-not$childProcess.WaitForExit(1200000)){
    try{if(-not$childProcess.HasExited){$childProcess.Kill($true)}}catch{$cleanupErrors.Add("Could not stop the timed-out active Console child tree: $($_.Exception.Message)")}
    try{$childExited=[bool]$childProcess.WaitForExit(10000)}catch{$cleanupErrors.Add("Could not verify active Console harness exit after timeout: $($_.Exception.Message)")}
    if(-not$childExited){$cleanupErrors.Add('The active Console harness child remained alive after its timeout cleanup attempt.')}
    throw 'The active Console owner Settings attempt exceeded its 20-minute process limit.'
  }
  $childExited=[bool]$childProcess.HasExited
  if(-not$childExited){throw 'The active Console harness child did not report a verified exit.'}
  $stdoutText=$stdoutTask.GetAwaiter().GetResult();$stderrText=$stderrTask.GetAwaiter().GetResult()
  [IO.File]::WriteAllText((Join-Path $EvidenceDirectory 'active-console-owner-child.stdout.log'),$stdoutText,[Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText((Join-Path $EvidenceDirectory 'active-console-owner-child.stderr.log'),$stderrText,[Text.UTF8Encoding]::new($false))
  if(-not(Test-Path -LiteralPath $childResultPath -PathType Leaf)){throw "Active Console child exited $($childProcess.ExitCode) without a result report. stderr: $stderrText"}
  $childResult=Get-Content -LiteralPath $childResultPath -Raw|ConvertFrom-Json
  $settingsEvent=@($childResult.Events|Where-Object{$_.Name-eq'Windows Settings > Apps uninstalls the active Console owner candidate'}|Select-Object -First 1)
  $retentionEvent=@($childResult.Events|Where-Object{$_.Name-eq'Windows Settings uninstall preserves settings/history and unrelated file byte-for-byte'}|Select-Object -First 1)
  $settingsStatus=if($settingsEvent.Count){[string]$settingsEvent[0].Status}else{'NOT TESTED'}
  $retentionStatus=if($retentionEvent.Count){[string]$retentionEvent[0].Status}else{'NOT TESTED'}
  $un009Status=if($settingsStatus-eq'PASS'-and$retentionStatus-eq'PASS'){'PASS'}elseif($settingsStatus-eq'FAIL'-or$retentionStatus-eq'FAIL'){'FAIL'}elseif($settingsStatus-eq'BLOCKED'-or$retentionStatus-eq'BLOCKED'){'BLOCKED'}else{'NOT TESTED'}
  $reason=if($settingsEvent.Count){[string]$settingsEvent[0].Details.Reason}else{'No active-console Settings uninstall event was recorded.'}
  $candidateIdentity=Get-Content -LiteralPath (Join-Path (Split-Path -Parent $EvidenceDirectory) 'candidate-identity.json') -Raw|ConvertFrom-Json
  $summary="Requirement: UN-009`nCandidate: artifact $($candidateIdentity.ArtifactId); EXE SHA-256 $expectedExeHash`nOS: $($os.Caption), version $($os.Version), build $($os.BuildNumber)`nArchitecture: OS $([Runtime.InteropServices.RuntimeInformation]::OSArchitecture), process $([Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture), candidate native x64`nEnvironment: disposable GitHub-hosted Windows Server 2025 x64 active Console owner identity`nUser: $($identity.Name); SID $($identity.User.Value); administrator token: $isAdministrator`nSettings uninstall UI result: $settingsStatus`nSettings/history/unrelated-file retention: $retentionStatus`nUN-009 result: $un009Status — $reason`nHarness status: $($childResult.Status) — $($childResult.Failure)`n"
  $summary|Tee-Object -FilePath $env:GITHUB_STEP_SUMMARY -Append
  Write-Host $summary
  if($childResult.Status-eq'FAIL'){throw "Active Console harness detected an application/test failure: $($childResult.Failure)"}
  if($un009Status-eq'FAIL'){throw "Active Console Settings uninstall acceptance failed: $reason"}
  if($un009Status-ne'PASS'){Write-Warning "UN-009 remains $un009Status; actual Settings Apps uninstall and both retention assertions are required."}
}catch{
  $failure=$_.Exception.Message
  Save-ActiveConsoleEvidence (Join-Path $EvidenceDirectory 'active-console-owner-harness-error.json') ([pscustomobject]@{Status='NOT TESTED';Failure=$failure;RunId=$runId;RunnerEnvironment=$env:RUNNER_ENVIRONMENT;RunnerArchitecture=$env:RUNNER_ARCH;OperatingSystem=if($os){[pscustomobject]@{Caption=$os.Caption;Version=$os.Version;Build=$os.BuildNumber}}else{$null};User=if($identity){$identity.Name}else{$null};UserSid=if($identity){$identity.User.Value}else{$null};CandidateSHA256=if(Test-Path -LiteralPath $ExecutablePath){(Get-FileHash -LiteralPath $ExecutablePath -Algorithm SHA256).Hash.ToLowerInvariant()}else{$null};ObservedUtc=[DateTime]::UtcNow.ToString('o')})
  throw
}finally{
  if($childProcess-and-not$childExited){
    try{if(-not$childProcess.HasExited){$childProcess.Kill($true)}}catch{$cleanupErrors.Add("Could not stop active Console child tree during final cleanup: $($_.Exception.Message)")}
    try{$childExited=[bool]$childProcess.WaitForExit(10000)}catch{$cleanupErrors.Add("Could not verify active Console harness exit during final cleanup: $($_.Exception.Message)")}
    if(-not$childExited){$cleanupErrors.Add('Active Console harness child is still alive; preserving its account profile and staged files.')}
  }
  if($currentProfileProvenFresh-and$childExited){
    $profileData=Join-Path $env:LOCALAPPDATA 'EyeBreakReminder'
    $installDirectory=Join-Path $env:LOCALAPPDATA 'Programs\EyeBreakReminder'
    $installedExecutable=Join-Path $installDirectory 'EyeBreakReminder.exe'
    $uninstaller=Join-Path $installDirectory 'Uninstall.exe'
    $installedImageHash=$null
    if(Test-Path -LiteralPath $installedExecutable -PathType Leaf){$installedImageHash=(Get-FileHash -LiteralPath $installedExecutable -Algorithm SHA256).Hash.ToLowerInvariant()}
    $canCleanupProfile=$true
    if($installedImageHash-and$installedImageHash-cne$expectedExeHash){$cleanupErrors.Add("Post-test image at the test-owned install path had unexpected SHA-256 $installedImageHash; preserving profile and refusing candidate cleanup.");$canCleanupProfile=$false}
    if($canCleanupProfile){
      try{$allNamedRows=@(Get-CimInstance Win32_Process -Filter "Name='EyeBreakReminder.exe'" -ErrorAction Stop);$unknownPathRows=@($allNamedRows|Where-Object{-not$_.ExecutablePath});if($unknownPathRows.Count){throw 'A candidate-named process had no readable executable path.'};$candidateProcessRows=@($allNamedRows|Where-Object{[IO.Path]::GetFullPath([string]$_.ExecutablePath)-ieq[IO.Path]::GetFullPath($installedExecutable)})}catch{$cleanupErrors.Add("Could not enumerate candidate processes safely: $($_.Exception.Message)");$canCleanupProfile=$false;$candidateProcessRows=@()}
      foreach($row in $candidateProcessRows){
        try{
          $ownerResult=Invoke-CimMethod -InputObject $row -MethodName GetOwnerSid -ErrorAction Stop
          if([uint32]$ownerResult.ReturnValue-ne0-or[string]$ownerResult.Sid-cne$activeConsoleUserSid-or[int]$row.SessionId-ne$activeConsoleSessionId){throw 'Candidate process owner SID or session did not match the active Console test owner.'}
          Stop-Process -Id ([int]$row.ProcessId) -Force -ErrorAction Stop
          $cleanupActions.Add("Stopped exact candidate process $($row.ProcessId) after verifying path, owner SID, and active Console session.")
        }catch{$cleanupErrors.Add("Could not safely stop exact candidate process $($row.ProcessId): $($_.Exception.Message)");$canCleanupProfile=$false}
      }
    }
    if($canCleanupProfile){
      $remaining=@()
      $processDeadline=[DateTime]::UtcNow.AddSeconds(10)
      do{
        try{$allNamedRows=@(Get-CimInstance Win32_Process -Filter "Name='EyeBreakReminder.exe'" -ErrorAction Stop);$unknownPathRows=@($allNamedRows|Where-Object{-not$_.ExecutablePath});if($unknownPathRows.Count){throw 'A candidate-named process had no readable executable path.'};$remaining=@($allNamedRows|Where-Object{[IO.Path]::GetFullPath([string]$_.ExecutablePath)-ieq[IO.Path]::GetFullPath($installedExecutable)})}catch{$cleanupErrors.Add("Could not verify candidate process exit safely: $($_.Exception.Message)");$canCleanupProfile=$false;break}
        if(-not$remaining.Count){break}
        Start-Sleep -Milliseconds 200
      }while([DateTime]::UtcNow-lt$processDeadline)
      if($remaining.Count){$cleanupErrors.Add('Candidate process remained alive after the bounded stop wait; preserving app profile, install directory, and registration.');$canCleanupProfile=$false}
    }
    if($canCleanupProfile-and$installedImageHash-ceq$expectedExeHash-and(Test-Path -LiteralPath $uninstaller -PathType Leaf)){
      try{$registered=Get-ItemProperty -LiteralPath $uninstallRegistration -ErrorAction Stop;$registeredUninstaller=[string]$registered.UninstallString;if($registeredUninstaller.StartsWith('"')-and$registeredUninstaller.EndsWith('"')){$registeredUninstaller=$registeredUninstaller.Substring(1,$registeredUninstaller.Length-2)};if([IO.Path]::GetFullPath($registeredUninstaller)-ine[IO.Path]::GetFullPath($uninstaller)){throw 'The fresh HKCU uninstall registration did not point to the candidate-owned Uninstall.exe.'};$cleanup=Start-Process -FilePath $uninstaller -ArgumentList '/S' -PassThru -Wait -ErrorAction Stop;if($cleanup.ExitCode-ne0){$cleanupErrors.Add("Scoped silent cleanup uninstaller returned $($cleanup.ExitCode).") }else{$cleanupActions.Add('Ran the candidate-owned silent uninstaller only as post-test cleanup after the exact installed image and registration were verified.') }}catch{$cleanupErrors.Add("Candidate-owned silent cleanup uninstaller: $($_.Exception.Message)")}
    }
    if($canCleanupProfile){
      foreach($path in @($installDirectory,$profileData)){
        if(Test-Path -LiteralPath $path){try{Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop;$cleanupActions.Add("Removed fresh runner-account path $path") }catch{$cleanupErrors.Add("Could not remove runner-account path ${path}: $($_.Exception.Message)")}}
      }
      foreach($key in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder','HKCU:\Software\EyeBreakReminder')){
        if(Test-Path -LiteralPath $key){try{Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction Stop;$cleanupActions.Add("Removed candidate-owned HKCU key $key") }catch{$cleanupErrors.Add("Could not remove candidate-owned key ${key}: $($_.Exception.Message)")}}
      }
    }
  }elseif($currentProfileProvenFresh-and-not$childExited){$cleanupErrors.Add('Preserved the fresh runner profile because the active Console harness child could not be confirmed exited.')}
  if($childProcess){$childProcess.Dispose()}
  if($stageRootCreatedByThisRun-and$stageRoot-and(Test-Path -LiteralPath $stageRoot)-and$childExited){
    try{
      $resolved=[IO.Path]::GetFullPath($stageRoot);$root=[IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')+'\'
      if(-not$resolved.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)){throw 'Refusing to remove staging outside RUNNER_TEMP.'}
      $stageDeadline=[DateTime]::UtcNow.AddSeconds(10);$stageUsers=@()
      do{$stageUsers=@(Get-ProcessesUsingActiveConsoleStage -Root $resolved);if(-not$stageUsers.Count){break};Start-Sleep -Milliseconds 250}while([DateTime]::UtcNow-lt$stageDeadline)
      if($stageUsers.Count){$cleanupErrors.Add("Preserved staging because process(es) still reference it: $(($stageUsers|ForEach-Object{"$($_.Name):$($_.ProcessId)"})-join', ').")}
      else{Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop;$cleanupActions.Add('Removed unique staged files only after verifying no process image or command line still referenced RUNNER_TEMP staging.')}
    }catch{$cleanupErrors.Add("Could not verify/remove staged files safely: $($_.Exception.Message)")}
  }elseif($stageRootCreatedByThisRun-and$stageRoot-and(Test-Path -LiteralPath $stageRoot)-and-not$childExited){$cleanupErrors.Add('Preserved staged files because the active Console harness child could not be confirmed exited.')}
  Save-ActiveConsoleEvidence (Join-Path $EvidenceDirectory 'active-console-owner-cleanup.json') ([pscustomobject]@{Status=if($cleanupErrors.Count){'FAIL'}else{'PASS'};Actions=$cleanupActions.ToArray();Errors=$cleanupErrors.ToArray();ObservedUtc=[DateTime]::UtcNow.ToString('o')})
  if($cleanupErrors.Count){Write-Warning "Active Console test cleanup reported $($cleanupErrors.Count) error(s); see active-console-owner-cleanup.json."}
}
if($cleanupErrors.Count){throw "Active Console test cleanup failed with $($cleanupErrors.Count) error(s); see active-console-owner-cleanup.json."}
