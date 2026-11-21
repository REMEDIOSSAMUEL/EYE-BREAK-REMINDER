param(
  [Parameter(Mandatory)][string]$InstallerPath,
  [Parameter(Mandatory)][string]$ExecutablePath,
  [Parameter(Mandatory)][string]$EvidenceDirectory
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'windows_rdp_file_trust_prompt.ps1')
$EvidenceDirectory=[IO.Path]::GetFullPath($EvidenceDirectory)
[void][IO.Directory]::CreateDirectory($EvidenceDirectory)
$runId=if($env:GITHUB_RUN_ID){$env:GITHUB_RUN_ID}else{[guid]::NewGuid().ToString('N')}
$suffix=[guid]::NewGuid().ToString('N').Substring(0,8)
$userName="EbrRdp$suffix"
$principal="$env:COMPUTERNAME\$userName"
$stageRoot=[IO.Path]::GetFullPath((Join-Path $env:RUNNER_TEMP "ebr-settings-rdp-$runId-$suffix"))
$taskName="EbrSettingsRdp$suffix"
$firewallName="EbrSettingsRdpLoopback$suffix"
$credentialTarget='TERMSRV/127.0.0.1'
$events=[System.Collections.Generic.List[object]]::new()
$cleanupErrors=[System.Collections.Generic.List[string]]::new()
$status='BLOCKED';$reason='';$audioReport=$null;$userCreated=$false;$credentialWritten=$false;$firewallCreated=$false;$firewallProfilesConfigured=$false;$disabledInboundRules=[System.Collections.Generic.List[object]]::new();$oldFirewallProfiles=@();$rdpEnabled=$false;$serviceStarted=$false;$taskRegistered=$false;$testStarted=$false;$sessionId=-1;$mstscProcess=$null;$securePassword=$null;$password=$null
$oldDeny=$null;$oldServiceStartType=$null;$oldServiceState=$null;$oldNla=$null
$expectedExe='07f6c1eaee5818df9f5c024310883ca94b8274a4f451186a8123974fb5e5f720'
$expectedInstaller='a15fc525557603dbed1ef0dccb8d128e500dfee91c6416b478513de790dd5c9b'
$taskContextPath=Join-Path $stageRoot 'rdp-task-context.json'
$audioControllerResultPath=Join-Path $stageRoot 'audio-controller-result.json'
$childResultPath=Join-Path $stageRoot 'standard-user-child-results.json'

function Add-Event([string]$Name,[string]$State,$Details=$null){$events.Add([pscustomobject]@{Name=$Name;Status=$State;Details=$Details})}
function Read-Value([string]$Path,[string]$Name){try{(Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name}catch{$null}}
function Save-Status([string]$Value,[string]$Why){
  $os=Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
  $record=[pscustomobject]@{Requirement='UN-009';Status=$Value;Reason=$Why;ArtifactId='14695418078';FinalizerRunId='44875679345';CandidateExecutableSHA256=$expectedExe;OS=$os.Caption;OSVersion=$os.Version;OSBuild=$os.BuildNumber;OSArchitecture=[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString();ProcessArchitecture=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString();CandidateExecution='native x64';Environment='GitHub-hosted disposable Windows Server 2025 x64 runner with temporary localhost RDP session';RdpSessionId=$sessionId;AudioAttemptStatus=if($audioReport){[string]$audioReport.Status}else{'NOT TESTED'};AudioAttemptReason=if($audioReport){[string]$audioReport.Reason}else{$null};AudioReport=$audioReport;FirewallProfilesBefore=@($oldFirewallProfiles);InboundAllowRulesTemporarilyDisabled=$disabledInboundRules.Count;Events=@($events);CleanupErrors=@($cleanupErrors);ObservedUtc=[DateTime]::UtcNow.ToString('o')}
  $record|ConvertTo-Json -Depth 9|Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'settings-uninstall-rdp-results.json') -Encoding UTF8
}

try{
  if($env:GITHUB_ACTIONS-cne'true'-or$env:RUNNER_ENVIRONMENT-cne'github-hosted'-or$env:RUNNER_OS-cne'Windows'-or$env:RUNNER_ARCH-cne'X64'-or-not$env:RUNNER_TEMP){throw 'BLOCKED: this runner-only RDP harness may execute only on a GitHub-hosted Windows x64 runner.'}
  if(-not(Test-Path -LiteralPath $InstallerPath -PathType Leaf)-or-not(Test-Path -LiteralPath $ExecutablePath -PathType Leaf)){throw 'BLOCKED: exact candidate installer or executable is missing.'}
  if((Get-FileHash -LiteralPath $ExecutablePath -Algorithm SHA256).Hash.ToLowerInvariant()-cne$expectedExe){throw 'BLOCKED: executable is not the authoritative production candidate.'}
  if((Get-FileHash -LiteralPath $InstallerPath -Algorithm SHA256).Hash.ToLowerInvariant()-cne$expectedInstaller){throw 'BLOCKED: installer is not the authoritative production candidate.'}
  $os=Get-CimInstance Win32_OperatingSystem
  $arch=[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
  if($os.Caption-notmatch'Windows Server 2025'-or$arch-ne'X64'){throw "BLOCKED: expected Windows Server 2025 x64, found '$($os.Caption)' / '$arch'."}
  $identity=[Security.Principal.WindowsIdentity]::GetCurrent();$admin=[Security.Principal.WindowsPrincipal]::new($identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if(-not$admin){throw 'BLOCKED: the hosted runner account cannot provision a standard RDP test user.'}
  $profiles=@(Get-NetFirewallProfile -ErrorAction Stop)
  if($profiles.Count-ne3){throw "BLOCKED: expected three Windows Firewall profiles; found $($profiles.Count)."}
  # Get-NetFirewallProfile exposes Enabled as Boolean on this runner, while
  # Set-NetFirewallProfile requires its GpoBoolean enum. Snapshot the named
  # value, then parse it to the setter's declared type during restoration.
  $enabledParameterType=(Get-Command Set-NetFirewallProfile -ErrorAction Stop).Parameters['Enabled'].ParameterType
  if(-not$enabledParameterType.IsEnum){throw "BLOCKED: Set-NetFirewallProfile -Enabled is not an enum on this runner ($($enabledParameterType.FullName))."}
  $oldFirewallProfiles=@($profiles|ForEach-Object{$enabledName=[string]$_.Enabled;if($enabledName-notin@('True','False','NotConfigured')){throw "BLOCKED: unsupported firewall Enabled value '$enabledName' for profile '$($_.Name)'."};[void][Enum]::Parse($enabledParameterType,$enabledName,$true);[pscustomobject]@{Name=[string]$_.Name;Enabled=$enabledName;DefaultInboundAction=[string]$_.DefaultInboundAction}})
  $rdpKey='HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server';$rdpTcpKey='HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
  $oldDeny=Read-Value $rdpKey 'fDenyTSConnections';$oldNla=Read-Value $rdpTcpKey 'UserAuthentication'
  if($null-eq$oldDeny-or$null-eq$oldNla-or[int]$oldNla-ne1){throw 'BLOCKED: RDP listener state or Network Level Authentication could not be verified; refusing to weaken authentication.'}
  $service=Get-Service -Name TermService -ErrorAction Stop
  $oldServiceStartType=$service.StartType;$oldServiceState=$service.Status
  if($oldServiceStartType-eq'Disabled'){throw 'BLOCKED: Remote Desktop Services is disabled by image policy; no policy override attempted.'}
  [void][IO.Directory]::CreateDirectory($stageRoot)
  $credSource=@'
using System;
using System.Runtime.InteropServices;
[StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
public struct EBR_CREDENTIAL {
  public UInt32 Flags, Type;
  public string TargetName, Comment;
  public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
  public UInt32 CredentialBlobSize;
  public IntPtr CredentialBlob;
  public UInt32 Persist, AttributeCount;
  public IntPtr Attributes;
  public string TargetAlias, UserName;
}
public static class EBR_CREDMAN {
  [DllImport("Advapi32.dll", EntryPoint="CredWriteW", CharSet=CharSet.Unicode, SetLastError=true)] public static extern bool Write(ref EBR_CREDENTIAL credential, UInt32 flags);
  [DllImport("Advapi32.dll", EntryPoint="CredDeleteW", CharSet=CharSet.Unicode, SetLastError=true)] public static extern bool Delete(string target, UInt32 type, UInt32 flags);
}
'@
  Add-Type -TypeDefinition $credSource -ErrorAction Stop
  $existingInboundAllows=@(Get-NetFirewallRule -Direction Inbound -Enabled True -Action Allow -ErrorAction Stop)
  $policyManagedAllows=@($existingInboundAllows|Where-Object{$_.PolicyStoreSourceType-eq'GroupPolicy'})
  if($policyManagedAllows.Count){throw "BLOCKED: $($policyManagedAllows.Count) enabled inbound allow rules are controlled by Group Policy; refusing to alter managed firewall policy."}
  foreach($rule in $existingInboundAllows){
    Disable-NetFirewallRule -InputObject $rule -ErrorAction Stop
    $disabledInboundRules.Add($rule)
  }
  $firewallProfilesConfigured=$true
  foreach($profile in $oldFirewallProfiles){Set-NetFirewallProfile -Profile $profile.Name -Enabled True -DefaultInboundAction Block -ErrorAction Stop}
  $securedFirewallProfiles=@(Get-NetFirewallProfile -ErrorAction Stop)
  if(@($securedFirewallProfiles|Where-Object{[string]$_.Enabled-ne'True'-or[string]$_.DefaultInboundAction-ne'Block'}).Count){throw 'BLOCKED: could not verify all firewall profiles enabled with default inbound block.'}
  Add-Event 'Temporarily secure the disposable hosted runner firewall for loopback-only RDP' 'PASS' ([pscustomobject]@{OriginalProfiles=$oldFirewallProfiles;TestProfiles=@($securedFirewallProfiles|ForEach-Object{[pscustomobject]@{Name=$_.Name;Enabled=$_.Enabled;DefaultInboundAction=$_.DefaultInboundAction}});ExistingInboundAllowRulesTemporarilyDisabled=$disabledInboundRules.Count;OutboundRulesOrDefaultUnchanged=$true;RestoreAttemptedInFinally=$true})
  $firewallProfiles=@(Get-NetFirewallProfile -ErrorAction Stop|ForEach-Object{[pscustomobject]@{Name=$_.Name;Enabled=$_.Enabled;DefaultInboundAction=$_.DefaultInboundAction}})
  $unsafeRdpRules=[System.Collections.Generic.List[string]]::new()
  foreach($rule in @(Get-NetFirewallRule -Direction Inbound -Enabled True -Action Allow -ErrorAction SilentlyContinue)){
    try{
      $port=Get-NetFirewallPortFilter -AssociatedNetFirewallRule $rule -ErrorAction Stop
      if([string]$port.Protocol-notin@('TCP','UDP','Any','6','17','256')){continue}
      $allows3389=$false
      foreach($entry in @($port.LocalPort)){
        foreach($value in ([string]$entry -split ','|ForEach-Object{$_.Trim()})){
          if($value-eq'Any'){$allows3389=$true;break}
          if($value-match'^(\d+)-(\d+)$'){$first=[int]$Matches[1];$last=[int]$Matches[2];if($first-le3389-and$last-ge3389){$allows3389=$true;break}}
          elseif($value-eq'3389'){$allows3389=$true;break}
        }
        if($allows3389){break}
      }
      if(-not$allows3389){continue}
      $address=Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $rule -ErrorAction Stop
      $remote=@($address.RemoteAddress|ForEach-Object{[string]$_})
      if(-not$remote.Count-or@($remote|Where-Object{$_-notin@('127.0.0.1','127.0.0.0/8')}).Count){$unsafeRdpRules.Add("$($rule.Name) [remote=$($remote-join',')]")}
    }catch{$unsafeRdpRules.Add("$($rule.Name) [scope could not be verified: $($_.Exception.Message)]")}
  }
  if($unsafeRdpRules.Count){throw "BLOCKED: existing enabled inbound TCP allow rules could expose RDP beyond loopback: $($unsafeRdpRules-join'; '). No rules were disabled or changed."}
  # Windows Firewall rejects loopback addresses in RemoteAddress. Scope the
  # rule to the destination loopback address instead; remote addresses remain
  # Any, but a packet arriving on a network interface cannot have LocalAddress
  # 127.0.0.1. Restrict the service and port as well.
  $firewallCreated=$true
  New-NetFirewallRule -Name $firewallName -DisplayName $firewallName -Direction Inbound -Action Allow -Protocol TCP -LocalPort 3389 -LocalAddress '127.0.0.1' -RemoteAddress Any -Service TermService -Profile Any -ErrorAction Stop|Out-Null
  $temporaryRules=@(Get-NetFirewallRule -Name $firewallName -ErrorAction Stop)
  if($temporaryRules.Count-ne1){throw 'BLOCKED: the temporary loopback RDP firewall rule is not uniquely identifiable.'}
  $temporaryRule=$temporaryRules[0]
  $temporaryAddress=Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $temporaryRule -ErrorAction Stop
  $temporaryPort=Get-NetFirewallPortFilter -AssociatedNetFirewallRule $temporaryRule -ErrorAction Stop
  $temporaryService=Get-NetFirewallServiceFilter -AssociatedNetFirewallRule $temporaryRule -ErrorAction Stop
  $localAddresses=@($temporaryAddress.LocalAddress|ForEach-Object{[string]$_});$remoteAddresses=@($temporaryAddress.RemoteAddress|ForEach-Object{[string]$_})
  $temporaryPorts=@($temporaryPort.LocalPort|ForEach-Object{[string]$_})
  if($temporaryRule.Direction-ne'Inbound'-or$temporaryRule.Action-ne'Allow'-or$temporaryRule.Enabled-ne'True'-or$localAddresses.Count-ne1-or$localAddresses[0]-cne'127.0.0.1'-or$remoteAddresses.Count-ne1-or$remoteAddresses[0]-cne'Any'-or[string]$temporaryPort.Protocol-notin@('TCP','6')-or$temporaryPorts.Count-ne1-or$temporaryPorts[0]-cne'3389'-or[string]$temporaryService.Service-cne'TermService'){throw 'BLOCKED: the temporary RDP firewall rule did not resolve to inbound TCP/3389 for TermService at local loopback 127.0.0.1 only.'}
  Add-Event 'Verify temporary inbound RDP rule is restricted to the loopback destination' 'PASS' ([pscustomobject]@{Direction=$temporaryRule.Direction;Action=$temporaryRule.Action;Enabled=$temporaryRule.Enabled;Protocol=$temporaryPort.Protocol;LocalPort=$temporaryPorts;Service=$temporaryService.Service;LocalAddress=$localAddresses;RemoteAddress=$remoteAddresses;NoExternalInterfaceDestination=$true})
  Set-ItemProperty -LiteralPath $rdpKey -Name fDenyTSConnections -Value 0 -ErrorAction Stop
  $rdpEnabled=$true
  if($service.StartType-eq'Manual'-or$service.StartType-eq'Automatic'){if($service.Status-ne'Running'){Start-Service -Name TermService -ErrorAction Stop;$serviceStarted=$true}}else{Set-Service -Name TermService -StartupType Manual -ErrorAction Stop;if($service.Status-ne'Running'){Start-Service -Name TermService -ErrorAction Stop;$serviceStarted=$true}}
  $listenerWatch=[Diagnostics.Stopwatch]::StartNew();$listener=$false
  while($listenerWatch.Elapsed.TotalSeconds-lt25){$listener=Test-NetConnection -ComputerName 127.0.0.1 -Port 3389 -InformationLevel Quiet -WarningAction SilentlyContinue;if($listener){break};Start-Sleep -Milliseconds 500}
  if(-not$listener){throw 'BLOCKED: localhost RDP listener did not become reachable with the loopback-only firewall rule.'}
  $random=[byte[]]::new(36);[Security.Cryptography.RandomNumberGenerator]::Fill($random);$password=[Convert]::ToBase64String($random)+'aA9!';[Array]::Clear($random,0,$random.Length)
  $securePassword=ConvertTo-SecureString -String $password -AsPlainText -Force
  New-LocalUser -Name $userName -Password $securePassword -PasswordNeverExpires -UserMayNotChangePassword -AccountNeverExpires -ErrorAction Stop|Out-Null
  $userCreated=$true
  $rdpUsers=Get-LocalGroup -SID ([Security.Principal.SecurityIdentifier]'S-1-5-32-555') -ErrorAction Stop
  Add-LocalGroupMember -Group $rdpUsers -Member $userName -ErrorAction Stop
  $testUser=Get-LocalUser -Name $userName -ErrorAction Stop
  if(@(Get-LocalGroupMember -Group 'Administrators' -ErrorAction Stop|Where-Object{$_.SID.Value-eq$testUser.SID.Value}).Count){throw 'BLOCKED: disposable RDP account unexpectedly belongs to Administrators.'}
  $bytes=[Text.Encoding]::Unicode.GetBytes($password);$blob=[Runtime.InteropServices.Marshal]::AllocHGlobal($bytes.Length)
  try{
    [Runtime.InteropServices.Marshal]::Copy($bytes,0,$blob,$bytes.Length)
    $credential=[EBR_CREDENTIAL]::new();$credential.Type=2;$credential.TargetName=$credentialTarget;$credential.CredentialBlob=$blob;$credential.CredentialBlobSize=[uint32]$bytes.Length;$credential.Persist=1;$credential.UserName=$principal
    if(-not[EBR_CREDMAN]::Write([ref]$credential,0)){throw "BLOCKED: Windows Credential Manager rejected the temporary localhost RDP credential (Win32 $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))."}
    $credentialWritten=$true
  }finally{[Array]::Clear($bytes,0,$bytes.Length);[Runtime.InteropServices.Marshal]::Copy([byte[]]::new($bytes.Length),0,$blob,$bytes.Length);[Runtime.InteropServices.Marshal]::FreeHGlobal($blob);$password=$null;try{$securePassword.Dispose()}catch{};$securePassword=$null}
  $rdpFile=Join-Path $stageRoot 'localhost-test.rdp'
  @(
    "full address:s:127.0.0.1:3389"
    "username:s:$principal"
    'prompt for credentials:i:0'
    'enablecredsspsupport:i:1'
    'authentication level:i:2'
    'screen mode id:i:1'
    'desktopwidth:i:1600'
    'desktopheight:i:900'
    'session bpp:i:32'
    'use multimon:i:0'
    'redirectclipboard:i:0'
    'redirectprinters:i:0'
    'drivestoredirect:s:'
    'redirectsmartcards:i:0'
    'redirectcomports:i:0'
    'redirectlocation:i:0'
    'redirectposdevices:i:0'
    'redirectwebauthn:i:0'
    'devicestoredirect:s:'
    'usbdevicestoredirect:s:'
    'camerastoredirect:s:'
    'audiocapturemode:i:0'
    'audiomode:i:0'
  )|Set-Content -LiteralPath $rdpFile -Encoding Unicode
  $mstscPath=Join-Path $env:WINDIR 'System32\mstsc.exe'
  if(-not(Test-Path -LiteralPath $mstscPath -PathType Leaf)){throw 'BLOCKED: built-in Remote Desktop client is unavailable.'}
  $mstscProcess=Start-Process -FilePath $mstscPath -ArgumentList "`"$rdpFile`"" -PassThru
  $trustPrompt=Resolve-EBRTestRdpFileTrustPrompt -MstscProcessId $mstscProcess.Id -RdpFilePath $rdpFile -EvidenceDirectory $EvidenceDirectory -AllowAudioPlayback -TimeoutSeconds 20
  if($trustPrompt.Status-eq'ACKNOWLEDGED'){Add-Event 'Acknowledge only the exact generated localhost RDP-file prompts; allow only the explicitly requested audio playback resource' 'PASS' $trustPrompt}
  else{Add-Event 'No first-run RDP-file prompt was present for the generated localhost connection' 'INFO' $trustPrompt}
  $sessionWatch=[Diagnostics.Stopwatch]::StartNew();$sessionRow=$null;$sessionTable=''
  while($sessionWatch.Elapsed.TotalSeconds-lt60-and-not$sessionRow){
    $sessionTable=& (Join-Path $env:WINDIR 'System32\query.exe') user 2>$null|Out-String
    foreach($line in ($sessionTable -split "`r?`n")){
      if($line-match('^\s*>?\s*'+[regex]::Escape($userName)+'\s+(\S+)\s+(\d+)\s+Active(?:\s|$)')){$sessionRow=[pscustomobject]@{SessionName=$Matches[1];SessionId=[int]$Matches[2];State='Active'};break}
    }
    if(-not$sessionRow){Start-Sleep -Milliseconds 500}
  }
  if(-not$sessionRow){
    $mstscProcess.Refresh()
    $diagnostic=[pscustomobject]@{Reason='mstsc did not create an Active RDP session for the temporary standard user within 60 seconds.';QueryUser=$sessionTable;MstscProcessId=$mstscProcess.Id;MstscExited=$mstscProcess.HasExited;MstscExitCode=if($mstscProcess.HasExited){$mstscProcess.ExitCode}else{$null};MstscMainWindowTitle=$mstscProcess.MainWindowTitle;MstscMainWindowHandle=('0x{0:X}'-f$mstscProcess.MainWindowHandle.ToInt64());EnvironmentUserInteractive=[Environment]::UserInteractive;NLAEnabled=([int]$oldNla-eq1);AuthenticationLevel=2}
    Add-Event 'Create active localhost RDP user session' 'BLOCKED' $diagnostic
    try{Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop;Add-Type -AssemblyName System.Drawing -ErrorAction Stop;$bounds=[System.Windows.Forms.SystemInformation]::VirtualScreen;if($bounds.Width-gt0-and$bounds.Height-gt0){$bitmap=[Drawing.Bitmap]::new($bounds.Width,$bounds.Height);$graphics=[Drawing.Graphics]::FromImage($bitmap);try{$graphics.CopyFromScreen($bounds.Left,$bounds.Top,0,0,$bitmap.Size);$bitmap.Save((Join-Path $EvidenceDirectory 'rdp-login-diagnostic.png'),[Drawing.Imaging.ImageFormat]::Png)}finally{$graphics.Dispose();$bitmap.Dispose()}}}catch{Add-Event 'Capture localhost RDP login diagnostic screenshot' 'NOT TESTED' $_.Exception.Message}
    throw 'BLOCKED: localhost RDP did not establish an active interactive user session.'
  }
  if($sessionRow.SessionName-notmatch'^rdp-tcp#'){throw "BLOCKED: the active test account is not in a genuine RDP session (session name '$($sessionRow.SessionName)')."}
  $sessionId=$sessionRow.SessionId
  Add-Event 'Create active localhost RDP user session' 'PASS' ([pscustomobject]@{User=$principal;SessionName=$sessionRow.SessionName;SessionId=$sessionId;NLAEnabled=([int]$oldNla-eq1);FirewallLocalAddress=@('127.0.0.1');FirewallRemoteAddress=@('Any');FirewallService='TermService';RemoteHost='127.0.0.1';IPv6RemoteAddressConfigured=$false;NoDriveOrClipboardRedirection=$true})
  $stageEvidence=Join-Path $stageRoot 'evidence';[void][IO.Directory]::CreateDirectory($stageEvidence)
  $stageAudioEvidence=Join-Path $stageRoot 'audio-evidence';[void][IO.Directory]::CreateDirectory($stageAudioEvidence)
  $candidateInstaller=Join-Path $stageRoot 'EyeBreakReminder-Setup-x64.exe';$candidateExecutable=Join-Path $stageRoot 'EyeBreakReminder.exe';$childScript=Join-Path $stageRoot 'windows_standard_user_acceptance.ps1';$audioScript=Join-Path $stageRoot 'windows_candidate_audio_loopback_acceptance.ps1'
  Copy-Item -LiteralPath $InstallerPath -Destination $candidateInstaller -Force;Copy-Item -LiteralPath $ExecutablePath -Destination $candidateExecutable -Force;Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'windows_standard_user_acceptance.ps1') -Destination $childScript -Force;Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'windows_candidate_audio_loopback_acceptance.ps1') -Destination $audioScript -Force
  $stageGrant="${principal}:(OI)(CI)M";& icacls.exe $stageRoot /grant $stageGrant /T /C|Out-Null
  if($LASTEXITCODE-ne0){throw 'BLOCKED: failed to grant the isolated RDP user access to its candidate/test staging folder.'}
  $payloadPath=Join-Path $stageRoot 'task-payload.json'
  [pscustomobject]@{ChildScript=$childScript;AudioScript=$audioScript;InstallerPath=$candidateInstaller;ExecutablePath=$candidateExecutable;EvidenceDirectory=$stageEvidence;AudioEvidenceDirectory=$stageAudioEvidence;AudioControllerResultPath=$audioControllerResultPath;ChildResultPath=$childResultPath;ExpectedSessionId=$sessionId;ExpectedSessionName=$sessionRow.SessionName;ExpectedUser=$principal;TaskContextPath=$taskContextPath;RunnerName=$env:RUNNER_NAME;RunnerTemp=$env:RUNNER_TEMP;GitHubWorkspace=$env:GITHUB_WORKSPACE;GitHubRunId=$env:GITHUB_RUN_ID}|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $payloadPath -Encoding UTF8
  $runnerScript=Join-Path $stageRoot 'run-standard-user-child.ps1'
  $runnerBody=@'
param([Parameter(Mandatory)][string]$PayloadPath)
$ErrorActionPreference='Stop'
$p=Get-Content -LiteralPath $PayloadPath -Raw|ConvertFrom-Json
$session=(Get-Process -Id $PID).SessionId
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$context=[pscustomobject]@{User=$identity.Name;Sid=$identity.User.Value;SessionId=$session;ExpectedSessionId=[int]$p.ExpectedSessionId;EnvironmentUserInteractive=[Environment]::UserInteractive;ProcessArchitecture=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString();OSArchitecture=[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString();ObservedUtc=[DateTime]::UtcNow.ToString('o')}
$context|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $p.TaskContextPath -Encoding UTF8
if($identity.Name -ine [string]$p.ExpectedUser -or $session -ne [int]$p.ExpectedSessionId -or -not[Environment]::UserInteractive){exit 3}
$env:GITHUB_ACTIONS='true';$env:RUNNER_ENVIRONMENT='github-hosted';$env:RUNNER_OS='Windows';$env:RUNNER_ARCH='X64';$env:GITHUB_SERVER_URL='https://github.com';$env:GITHUB_REPOSITORY='REMEDIOSSAMUEL/EYE-BREAK-REMINDER';$env:RUNNER_NAME=[string]$p.RunnerName;$env:RUNNER_TEMP=[string]$p.RunnerTemp;$env:GITHUB_WORKSPACE=[string]$p.GitHubWorkspace;$env:GITHUB_RUN_ID=[string]$p.GitHubRunId;$env:SESSIONNAME=[string]$p.ExpectedSessionName
try { & $p.AudioScript -ExecutablePath $p.ExecutablePath -EvidenceDirectory $p.AudioEvidenceDirectory } catch { $audioHarnessError=$_.Exception.Message }
$audioReportPath=Join-Path $p.AudioEvidenceDirectory 'reg-008-audio-loopback-results.json';$audioReport=$null
if(Test-Path -LiteralPath $audioReportPath -PathType Leaf){try{$audioReport=Get-Content -LiteralPath $audioReportPath -Raw|ConvertFrom-Json}catch{}}
[pscustomobject]@{Status=if($audioReport){[string]$audioReport.Status}else{'NOT TESTED'};Reason=if($audioReport){[string]$audioReport.Reason}else{[string]$audioHarnessError};RunnerContextSource='Outer PowerShell controller validated the GitHub-hosted runner; values copied into the same verified RDP session task';RdpSessionName=$p.ExpectedSessionName;RdpSessionId=$session;User=$identity.Name;AudioReportPresent=[bool]$audioReport;CompletedUtc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $p.AudioControllerResultPath -Encoding UTF8
if(Test-Path -LiteralPath $p.AudioEvidenceDirectory){$audioDestination=Join-Path $p.EvidenceDirectory 'audio';[void][IO.Directory]::CreateDirectory($audioDestination);Get-ChildItem -LiteralPath $p.AudioEvidenceDirectory -File -Recurse|ForEach-Object{$target=Join-Path $audioDestination $_.Name;Copy-Item -LiteralPath $_.FullName -Destination $target -Force}}
& $p.ChildScript -Child -InstallerPath $p.InstallerPath -ExecutablePath $p.ExecutablePath -EvidenceDirectory $p.EvidenceDirectory -ChildResultPath $p.ChildResultPath
exit $LASTEXITCODE
'@
  Set-Content -LiteralPath $runnerScript -Value $runnerBody -Encoding UTF8
  $pwshPath=Join-Path $PSHOME 'pwsh.exe';$actionArgs="-NoProfile -ExecutionPolicy Bypass -File `"$runnerScript`" -PayloadPath `"$payloadPath`""
  $action=New-ScheduledTaskAction -Execute $pwshPath -Argument $actionArgs -WorkingDirectory $stageRoot
  $taskPrincipal=New-ScheduledTaskPrincipal -UserId $principal -LogonType Interactive -RunLevel Limited
  $taskSettings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 35) -StartWhenAvailable -MultipleInstances IgnoreNew
  Register-ScheduledTask -TaskName $taskName -Action $action -Principal $taskPrincipal -Settings $taskSettings -Force -ErrorAction Stop|Out-Null
  $taskRegistered=$true
  $taskStartUtc=[DateTime]::UtcNow
  Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
  $testStarted=$true
  $testWatch=[Diagnostics.Stopwatch]::StartNew()
  while($testWatch.Elapsed.TotalMinutes-lt35-and-not(Test-Path -LiteralPath $childResultPath -PathType Leaf)){
    Start-Sleep -Milliseconds 500
    $taskInfo=Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
    $task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if($task-and$task.State-eq'Ready'-and$taskInfo-and$taskInfo.LastRunTime.ToUniversalTime()-ge$taskStartUtc-and$taskInfo.LastTaskResult-ne267009){break}
  }
  if(Test-Path -LiteralPath $childResultPath -PathType Leaf){
    $child=Get-Content -LiteralPath $childResultPath -Raw|ConvertFrom-Json
    $settingsEvent=@($child.Events|Where-Object{$_.Name-eq'Windows Settings > Apps uninstalls the standard-user candidate'}|Select-Object -First 1)
    $retentionEvent=@($child.Events|Where-Object{$_.Name-eq'Windows Settings uninstall preserves settings/history and unrelated file byte-for-byte'}|Select-Object -First 1)
    if($settingsEvent.Count-and$settingsEvent[0].Status-eq'FAIL'){$status='FAIL';$reason=[string]$settingsEvent[0].Details.Reason}
    elseif($retentionEvent.Count-and$retentionEvent[0].Status-eq'FAIL'){$status='FAIL';$reason='Settings uninstall did not preserve the explicitly retained test settings/history or unrelated file byte-for-byte.'}
    elseif($settingsEvent.Count-and$settingsEvent[0].Status-eq'PASS'-and$child.Status-eq'FAIL'-and-not($retentionEvent.Count-and$retentionEvent[0].Status-eq'PASS')){$status='FAIL';$reason=[string]$child.Failure}
    elseif($settingsEvent.Count-and$settingsEvent[0].Status-eq'PASS'-and$retentionEvent.Count-and$retentionEvent[0].Status-eq'PASS'){$status='PASS';$reason='The exact production candidate was removed through the real Windows Settings Installed Apps UI; Keep-data selection and byte-identical user data were verified.'}
    else{$status='NOT TESTED';$reason=if($settingsEvent.Count){[string]$settingsEvent[0].Details.Reason}else{'The Settings UI event was absent from the child test evidence.'}}
    Copy-Item -LiteralPath $childResultPath -Destination (Join-Path $EvidenceDirectory 'standard-user-child-results.json') -Force
    if(Test-Path -LiteralPath $taskContextPath){Copy-Item -LiteralPath $taskContextPath -Destination (Join-Path $EvidenceDirectory 'rdp-task-context.json') -Force}
    if(Test-Path -LiteralPath $stageEvidence){Get-ChildItem -LiteralPath $stageEvidence -File -Recurse|ForEach-Object{$dest=Join-Path $EvidenceDirectory $_.Name;Copy-Item -LiteralPath $_.FullName -Destination $dest -Force}}
    Add-Event 'Run exact-candidate Settings UIA in the active RDP user session' $status ([pscustomobject]@{ChildStatus=$child.Status;SettingsAppsUninstall=if($settingsEvent.Count){$settingsEvent[0]};DataRetention=if($retentionEvent.Count){$retentionEvent[0]};SessionContext=if(Test-Path -LiteralPath $taskContextPath){Get-Content -LiteralPath $taskContextPath -Raw|ConvertFrom-Json}else{$null};Assertions=@($child.Events|Where-Object{$_.Status-eq'PASS'}).Count})
  }elseif(Test-Path -LiteralPath $taskContextPath){
    $context=Get-Content -LiteralPath $taskContextPath -Raw|ConvertFrom-Json
    if(-not$context.EnvironmentUserInteractive-or$context.SessionId-ne$sessionId){$status='BLOCKED';$reason='The scheduled child did not run as an interactive process in the active RDP session.'}
    else{$status='BLOCKED';$reason='The isolated RDP-session child did not produce its UIA result within 35 minutes.'}
    Copy-Item -LiteralPath $taskContextPath -Destination (Join-Path $EvidenceDirectory 'rdp-task-context.json') -Force
  }else{$status='BLOCKED';$reason='The interactive-token task did not start in the active RDP session.'}
  if(Test-Path -LiteralPath $audioControllerResultPath -PathType Leaf){$audioControllerResult=Get-Content -LiteralPath $audioControllerResultPath -Raw|ConvertFrom-Json;Copy-Item -LiteralPath $audioControllerResultPath -Destination (Join-Path $EvidenceDirectory 'audio-controller-result.json') -Force;$audioReportPath=Join-Path (Join-Path $stageRoot 'audio-evidence') 'reg-008-audio-loopback-results.json';if(Test-Path -LiteralPath $audioReportPath -PathType Leaf){$audioReport=Get-Content -LiteralPath $audioReportPath -Raw|ConvertFrom-Json;Add-Event 'REG-008 exact candidate preview and Windows render-loopback attempt in the same isolated RDP session' ([string]$audioReport.Status) ([pscustomobject]@{Reason=$audioReport.Reason;AudioController=$audioControllerResult;PhysicalAudibility=$audioReport.PhysicalAudibility;Endpoint=$audioReport.AudioEndpoint;WasapiLoopbackStatus=$audioReport.WasapiLoopbackStatus})}else{Add-Event 'REG-008 exact candidate preview and Windows render-loopback attempt in the same isolated RDP session' 'NOT TESTED' $audioControllerResult}}
  if($status-eq'BLOCKED'){Add-Event 'Run exact-candidate Settings UIA in the active RDP user session' 'BLOCKED' $reason}
}catch{
  $message=$_.Exception.Message
  if($message-match'^BLOCKED:'){$status='BLOCKED';$reason=$message;Add-Event 'Loopback RDP provisioning or session launch' 'BLOCKED' $message}
  else{$status='BLOCKED';$reason="The RDP/test harness did not complete; this is infrastructure evidence, not an application failure: $message";Add-Event 'Loopback RDP Settings test harness' 'BLOCKED' $message}
}finally{
  $password=$null;try{if($securePassword){$securePassword.Dispose()}}catch{}
  if($taskRegistered){try{Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue;Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop;Add-Event 'Remove temporary interactive-token task' 'PASS'}catch{$cleanupErrors.Add("Scheduled task cleanup: $($_.Exception.Message)")}}
  if($mstscProcess){try{$mstscProcess.Refresh();if(-not$mstscProcess.HasExited){Stop-Process -Id $mstscProcess.Id -Force -ErrorAction SilentlyContinue}}catch{}}
  if($sessionId-gt0){
    try{
      $currentSession=(Get-Process -Id $PID).SessionId
      if($sessionId-ne$currentSession){& (Join-Path $env:WINDIR 'System32\logoff.exe') $sessionId 2>$null;Start-Sleep -Seconds 2}
    }catch{$cleanupErrors.Add("RDP session logoff: $($_.Exception.Message)")}
  }
  if($credentialWritten){try{if(-not[EBR_CREDMAN]::Delete($credentialTarget,2,0)){$code=[Runtime.InteropServices.Marshal]::GetLastWin32Error();if($code-ne1168){$cleanupErrors.Add("Temporary RDP credential cleanup failed with Win32 $code.")}}}catch{$cleanupErrors.Add("Temporary RDP credential cleanup: $($_.Exception.Message)")}}
  if($userCreated){
    try{
      $user=Get-LocalUser -Name $userName -ErrorAction SilentlyContinue
      if($user){
        $profile=Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue|Where-Object{$_.SID-eq$user.SID.Value-and-not$_.Special}|Select-Object -First 1
        $profileWatch=[Diagnostics.Stopwatch]::StartNew()
        while($profile-and$profile.Loaded-and$profileWatch.Elapsed.TotalSeconds-lt15){Start-Sleep -Milliseconds 500;$profile=Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue|Where-Object{$_.SID-eq$user.SID.Value-and-not$_.Special}|Select-Object -First 1}
        if($profile-and$profile.Loaded){$cleanupErrors.Add('Temporary RDP user profile remained loaded after its session was logged off.')}
        elseif($profile){Remove-CimInstance -InputObject $profile -ErrorAction Stop}
        Remove-LocalUser -Name $userName -ErrorAction Stop
        Add-Event 'Remove temporary RDP standard user and profile' 'PASS'
      }
    }catch{$cleanupErrors.Add("Temporary RDP account/profile cleanup: $($_.Exception.Message)")}
  }
  if($firewallCreated){try{Remove-NetFirewallRule -Name $firewallName -ErrorAction Stop}catch{$cleanupErrors.Add("Loopback firewall rule cleanup: $($_.Exception.Message)")}}
  if($rdpEnabled-and$null-ne$oldDeny){try{Set-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value ([int]$oldDeny) -ErrorAction Stop}catch{$cleanupErrors.Add("Restore RDP listener setting: $($_.Exception.Message)")}}
  try{if($oldServiceStartType){Set-Service -Name TermService -StartupType $oldServiceStartType -ErrorAction Stop};if($oldServiceState-eq'Stopped'){Stop-Service -Name TermService -Force -ErrorAction Stop}}catch{$cleanupErrors.Add("Restore Remote Desktop Services state: $($_.Exception.Message)")}
  foreach($rule in $disabledInboundRules){try{Enable-NetFirewallRule -InputObject $rule -ErrorAction Stop}catch{$cleanupErrors.Add("Restore inbound firewall rule '$($rule.Name)': $($_.Exception.Message)")}}
  if($firewallProfilesConfigured){
    foreach($profile in $oldFirewallProfiles){try{$enabledValue=[Enum]::Parse($enabledParameterType,[string]$profile.Enabled,$true);Set-NetFirewallProfile -Profile $profile.Name -Enabled $enabledValue -DefaultInboundAction $profile.DefaultInboundAction -ErrorAction Stop}catch{$cleanupErrors.Add("Restore $($profile.Name) firewall profile: $($_.Exception.Message)")}}
    try{
      $restoredProfiles=@(Get-NetFirewallProfile -ErrorAction Stop)
      $profileMismatches=@(foreach($expectedProfile in $oldFirewallProfiles){$actualProfile=@($restoredProfiles|Where-Object{$_.Name-ceq$expectedProfile.Name}|Select-Object -First 1);if(-not$actualProfile.Count-or[string]$actualProfile[0].Enabled-cne[string]$expectedProfile.Enabled-or[string]$actualProfile[0].DefaultInboundAction-cne$expectedProfile.DefaultInboundAction){$expectedProfile.Name}})
      if($profileMismatches.Count){$cleanupErrors.Add("Windows Firewall profile restoration did not match its original state: $($profileMismatches-join', ')")}else{Add-Event 'Restore original Windows Firewall profile settings after the isolated RDP attempt' 'PASS' ([pscustomobject]@{Profiles=$restoredProfiles|ForEach-Object{[pscustomobject]@{Name=$_.Name;Enabled=$_.Enabled;DefaultInboundAction=$_.DefaultInboundAction}}})}
      $missingRules=@(foreach($disabledRule in $disabledInboundRules){$restoredRule=@(Get-NetFirewallRule -Name $disabledRule.Name -ErrorAction SilentlyContinue|Where-Object{$_.Enabled-eq'True'});if(-not$restoredRule.Count){$disabledRule.Name}})
      if($missingRules.Count){$cleanupErrors.Add("Some original enabled inbound firewall rules were not restored: $($missingRules-join', ')")}else{Add-Event 'Restore all previously enabled inbound allow rules' 'PASS' ([pscustomobject]@{Count=$disabledInboundRules.Count})}
    }catch{$cleanupErrors.Add("Verify original firewall restoration: $($_.Exception.Message)")}
  }
  try{if(Test-Path -LiteralPath $stageRoot){$resolved=[IO.Path]::GetFullPath($stageRoot);$runnerTemp=[IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')+'\';if(-not$resolved.StartsWith($runnerTemp,[StringComparison]::OrdinalIgnoreCase)-or([IO.File]::GetAttributes($resolved)-band[IO.FileAttributes]::ReparsePoint)){throw 'Refusing cleanup outside the non-reparse RUNNER_TEMP test folder.'};Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop}}catch{$cleanupErrors.Add("Temporary staging cleanup: $($_.Exception.Message)")}
  if($cleanupErrors.Count-and$status-ne'FAIL'){$status='BLOCKED';$reason="The UI result could not be accepted because isolated-runner cleanup was incomplete: $($cleanupErrors-join'; ')"}
  try{Save-Status $status $reason}catch{Write-Error "Could not write final Settings RDP evidence: $($_.Exception.Message)"}
}
if($status-eq'FAIL'){throw $reason}
Write-Host "UN-009 loopback RDP attempt: $status — $reason"
