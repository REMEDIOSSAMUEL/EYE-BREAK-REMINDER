param(
  [string]$InstallerPath = (Join-Path $env:RUNNER_TEMP 'eye-break-reminder-v1.2.0-published-assets\EyeBreakReminder-Setup-x64.exe'),
  [string]$EvidenceDirectory = (Join-Path (Get-Location) 'build\post-release-evidence')
)
$ErrorActionPreference='Stop'
$expectedInstaller='121eaa8d14b8e3d342252edfc91bc25d6e8334b829c2824b7f90813062ded75f'
$events=[System.Collections.Generic.List[object]]::new()
$created=$false
$installStarted=$false
$userName='Ebr12_'+[guid]::NewGuid().ToString('N').Substring(0,10)
$user=$null
$credential=$null
$profilePath=$null
$profileObject=$null
$appProcess=$null
function Add-Result([string]$Name,[string]$Status,$Details=$null){$events.Add([pscustomobject]@{Name=$Name;Status=$Status;Details=$Details;Utc=[DateTime]::UtcNow.ToString('o')})}
function Check([bool]$Condition,[string]$Name,$Details=$null){if($Condition){Add-Result $Name 'PASS' $Details}else{Add-Result $Name 'FAIL' $Details}}
function Invoke-StandardProcess([string]$FilePath,[string[]]$Arguments,[int]$TimeoutSeconds=120){
  $process=Start-Process -FilePath $FilePath -ArgumentList $Arguments -Credential $credential -LoadUserProfile -PassThru
  if(-not $process.WaitForExit($TimeoutSeconds*1000)){Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue;throw "Standard-user process timed out: $FilePath"}
  $process.Refresh()
  return [pscustomobject]@{Pid=$process.Id;ExitCode=$process.ExitCode}
}
try{
  [void][IO.Directory]::CreateDirectory($EvidenceDirectory)
  if(-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)){throw "The publicly downloaded release installer was not found at $InstallerPath"}
  $installerHash=(Get-FileHash -LiteralPath $InstallerPath -Algorithm SHA256).Hash.ToLowerInvariant()
  Check ($installerHash -ceq $expectedInstaller) 'Standard-user test uses the exact published installer hash' ([pscustomobject]@{SHA256=$installerHash;Path=$InstallerPath})
  if($installerHash -cne $expectedInstaller){throw 'The downloaded installer identity did not match the published v1.2.0 asset.'}

  try{
    $passwordText='Aa1!'+[guid]::NewGuid().ToString('N')+'xZ9#'
    $password=ConvertTo-SecureString -String $passwordText -AsPlainText -Force
    $user=New-LocalUser -Name $userName -Password $password -AccountNeverExpires -PasswordNeverExpires -UserMayNotChangePassword -Description 'Disposable EBR test account'
    $created=$true
    $sid=$user.SID.Value
    $usersGroup=Get-LocalGroup -SID 'S-1-5-32-545'
    $adminsGroup=Get-LocalGroup -SID 'S-1-5-32-544'
    $members=@(Get-LocalGroupMember -Group $usersGroup -ErrorAction SilentlyContinue | ForEach-Object {$_.SID.Value})
    if($members -notcontains $sid){Add-LocalGroupMember -Group $usersGroup -Member $user}
    $adminMembers=@(Get-LocalGroupMember -Group $adminsGroup -ErrorAction SilentlyContinue | ForEach-Object {$_.SID.Value})
    Check ($sid -notin $adminMembers) 'Disposable test account is a standard user, not an administrator' ([pscustomobject]@{AccountType='Standard';AdministratorMembership=($sid -in $adminMembers)})
    if($sid -in $adminMembers){throw 'The test account unexpectedly belongs to the Administrators group.'}
    $credential=[PSCredential]::new("$env:COMPUTERNAME\$userName",$password)
    Add-Result 'Disposable standard account created without recording its credential' 'PASS' ([pscustomobject]@{AccountType='Standard';SID=$sid})
  }catch{
    $newLocalUserAvailable=[bool](Get-Command New-LocalUser -ErrorAction SilentlyContinue)
    Add-Result 'Standard-user account capability' 'NOT TESTED' ([pscustomobject]@{Reason=$_.Exception.Message;UserManagementAvailable=$newLocalUserAvailable})
    throw [System.OperationCanceledException]::new('Standard-user account creation is not available on this hosted runner.')
  }finally{
    Remove-Variable passwordText,password -ErrorAction SilentlyContinue
  }

  $profileObject=Get-CimInstance Win32_UserProfile -Filter "SID='$sid'" -ErrorAction SilentlyContinue
  if($profileObject){$profilePath=[string]$profileObject.LocalPath}
  if(-not $profilePath){
    $run=Invoke-StandardProcess -FilePath $InstallerPath -Arguments @('/S') -TimeoutSeconds 120
    $installStarted=$true
    Check ($run.ExitCode -eq 0) 'Published installer silently installs as a standard user without elevation' ([pscustomobject]@{ExitCode=$run.ExitCode})
    $profileObject=Get-CimInstance Win32_UserProfile -Filter "SID='$sid'" -ErrorAction SilentlyContinue
    if($profileObject){$profilePath=[string]$profileObject.LocalPath}
  }
  if(-not $profilePath){throw 'Windows did not create a disposable standard-user profile after launching the installer.'}
  $localAppData=Join-Path $profilePath 'AppData\Local'
  $installDir=Join-Path $localAppData 'Programs\EyeBreakReminder'
  $appExe=Join-Path $installDir 'EyeBreakReminder.exe'
  $uninstaller=Join-Path $installDir 'Uninstall.exe'
  $dataDir=Join-Path $localAppData 'EyeBreakReminder'
  $appKeyPath="$sid\Software\EyeBreakReminder"
  $uninstallKeyPath="$sid\Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder"
  $userHive=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::Users,[Microsoft.Win32.RegistryView]::Default)
  try{
    $appKey=$userHive.OpenSubKey($appKeyPath)
    $uninstallKey=$userHive.OpenSubKey($uninstallKeyPath)
    $displayVersion=if($uninstallKey){[string]$uninstallKey.GetValue('DisplayVersion')}else{''}
    $registeredLocation=if($uninstallKey){[string]$uninstallKey.GetValue('InstallLocation')}else{''}
    Check ((Test-Path -LiteralPath $appExe) -and (Test-Path -LiteralPath $uninstaller)) 'Standard-user install writes the executable and uninstaller to the profile installation path' ([pscustomobject]@{Executable=(Test-Path -LiteralPath $appExe);Uninstaller=(Test-Path -LiteralPath $uninstaller);InstallDir=$installDir})
    if(Test-Path -LiteralPath $appExe){
      $version=(Get-Item -LiteralPath $appExe).VersionInfo.ProductVersion
      Check ($version -match '^1\.2\.0') 'Standard-user installed executable reports v1.2.0' $version
    }
    Check ($appKey -and $uninstallKey -and $displayVersion -eq '1.2.0' -and [IO.Path]::GetFullPath($registeredLocation) -ieq [IO.Path]::GetFullPath($installDir)) 'Standard-user HKCU registration identifies the correct installed application' ([pscustomobject]@{AppKeyPresent=[bool]$appKey;UninstallKeyPresent=[bool]$uninstallKey;DisplayVersion=$displayVersion;InstallLocation=$registeredLocation})
    if($appKey){$appKey.Dispose()};if($uninstallKey){$uninstallKey.Dispose()}
  }finally{$userHive.Dispose()}

  $consentBefore=@(Get-Process -Name consent -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
  $appProcess=Start-Process -FilePath $appExe -Credential $credential -LoadUserProfile -PassThru
  Start-Sleep -Seconds 5
  $appProcess.Refresh()
  $runningPath=''
  try{$runningPath=[IO.Path]::GetFullPath((Get-Process -Id $appProcess.Id -ErrorAction Stop).Path)}catch{}
  Check (-not $appProcess.HasExited -and $runningPath -ieq [IO.Path]::GetFullPath($appExe)) 'Standard-user application starts from its per-user installed executable' ([pscustomobject]@{Pid=$appProcess.Id;Expected=$appExe;Actual=$runningPath;HasExited=$appProcess.HasExited})
  if(-not $appProcess.HasExited){Stop-Process -Id $appProcess.Id -Force -ErrorAction SilentlyContinue;[void]$appProcess.WaitForExit(5000)}
  $consentAfter=@(Get-Process -Name consent -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
  Check ((Compare-Object $consentBefore $consentAfter).Count -eq 0) 'Standard-user install and launch did not start a UAC consent process' ([pscustomobject]@{Before=$consentBefore;After=$consentAfter})
  if(Test-Path -LiteralPath $uninstaller){
    $uninstall=Invoke-StandardProcess -FilePath $uninstaller -Arguments @('/S') -TimeoutSeconds 120
    Check ($uninstall.ExitCode -eq 0) 'Published uninstaller silently removes the standard-user installation' ([pscustomobject]@{ExitCode=$uninstall.ExitCode})
    Check (-not (Test-Path -LiteralPath $installDir)) 'Standard-user silent uninstall removes its per-user installation directory' $installDir
    $userHive=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::Users,[Microsoft.Win32.RegistryView]::Default)
    try{$remaining=$userHive.OpenSubKey($uninstallKeyPath);Check ($null -eq $remaining) 'Standard-user silent uninstall removes its per-user registration';if($remaining){$remaining.Dispose()}}finally{$userHive.Dispose()}
  }
}catch{
  if($_.Exception -isnot [System.OperationCanceledException]){Add-Result 'Standard-user installer lifecycle' 'FAIL' $_.Exception.Message}
}finally{
  if($appProcess -and -not $appProcess.HasExited){try{Stop-Process -Id $appProcess.Id -Force -ErrorAction SilentlyContinue}catch{}}
  if($created){
    try{
      if($credential -and $uninstaller -and (Test-Path -LiteralPath $uninstaller)){
        $cleanup=Invoke-StandardProcess -FilePath $uninstaller -Arguments @('/S') -TimeoutSeconds 120
        if($cleanup.ExitCode -ne 0){Add-Result 'Standard-user cleanup uninstaller' 'FAIL' ([pscustomobject]@{ExitCode=$cleanup.ExitCode})}
      }
    }catch{Add-Result 'Standard-user cleanup uninstaller' 'FAIL' $_.Exception.Message}
    try{Remove-LocalUser -Name $userName -ErrorAction Stop}catch{Add-Result 'Disposable account cleanup' 'FAIL' $_.Exception.Message}
    try{
      $profileObject=Get-CimInstance Win32_UserProfile -Filter "SID='$sid'" -ErrorAction SilentlyContinue
      if($profileObject -and -not $profileObject.Special){
        $resolved=[IO.Path]::GetFullPath([string]$profileObject.LocalPath)
        $usersRoot=[IO.Path]::GetFullPath((Join-Path $env:SystemDrive 'Users'))+[IO.Path]::DirectorySeparatorChar
        if(-not $resolved.StartsWith($usersRoot,[StringComparison]::OrdinalIgnoreCase)){throw "Refusing to remove a test profile outside $usersRoot"}
        Remove-CimInstance -InputObject $profileObject -ErrorAction Stop
      }
      Add-Result 'Disposable standard-user profile cleanup' 'PASS' ([pscustomobject]@{ProfilePath=$profilePath})
    }catch{Add-Result 'Disposable standard-user profile cleanup' 'FAIL' $_.Exception.Message}
  }
  $summary=[pscustomobject]@{
    Application='Eye Break Reminder'
    Release='v1.2.0'
    InstallerSHA256=$expectedInstaller
    Events=$events.ToArray()
    Pass=(@($events|Where-Object Status -eq 'PASS')).Count
    Fail=(@($events|Where-Object Status -eq 'FAIL')).Count
    NotTested=(@($events|Where-Object Status -eq 'NOT TESTED')).Count
    CompletedUtc=[DateTime]::UtcNow.ToString('o')
  }
  $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'standard-user-install.json') -Encoding UTF8
  $summary | ConvertTo-Json -Depth 8
}
if($summary.Fail -gt 0){exit 1}
