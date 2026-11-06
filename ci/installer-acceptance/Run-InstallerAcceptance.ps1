#Requires -Version 7.0
[CmdletBinding()]
param([switch]$DownloadOfficialOnly)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$evidenceDir = Join-Path $env:RUNNER_TEMP 'EyeBreakInstallerAcceptance'
$inputDir = Join-Path (Split-Path -Parent $evidenceDir) 'EyeBreakInstallerAcceptanceInputs'
New-Item -ItemType Directory -Force -Path $evidenceDir, $inputDir | Out-Null
$script:checks = [System.Collections.Generic.List[object]]::new()
$script:installerProcesses = [System.Collections.Generic.List[object]]::new()
$script:appLaunches = [System.Collections.Generic.List[object]]::new()
$script:dataSnapshots = [ordered]@{}
$script:scenarios = [ordered]@{
  environment='NOT_RUN'; official_v106_artifact='NOT_RUN'; fresh_v106_install='NOT_RUN'
  v106_app_and_user_data='NOT_RUN'; v106_to_v110_upgrade='NOT_RUN'; operating_schedule_runtime='NOT_RUN'
  v110_uninstall='NOT_RUN'; fresh_v110_install='NOT_RUN'; fresh_v110_uninstall='NOT_RUN'; cleanup='NOT_RUN'
}
$script:status='RUNNING'; $script:failure=$null; $script:scenario=$null
$script:environment=[ordered]@{}; $script:artifacts=[ordered]@{}; $script:activeAppPid=$null; $script:expectedRunValue=$null; $script:freshTimerAnchor=$null

$setupPath = Join-Path $inputDir 'official-v1.0.6-setup.exe'
$baselinePath = Join-Path $evidenceDir 'official-baseline.json'
$manifestPath = Join-Path $evidenceDir 'results.json'
$transcriptPath = if ($DownloadOfficialOnly) { Join-Path $evidenceDir 'download.log' } else { Join-Path $evidenceDir 'run.log' }
$expectedBase = 'fc9db9e992601cd2ba18346a74012b27ccdeb360'
$expectedOfficialSetupSha256 = '9EDA9AADEF471B9A2E08F4D2CC1DF8FF6DD0A4B7DEFC36977EE67D30B8D894DE'
$expectedOfficialAppSha256 = 'BC5D2AB50DB7AA088CC2F7AF0337BD237E4E4A43B96E7227C9C2F7550DFDEE37'
$localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
$installPath = Join-Path $localAppData 'Programs\EyeBreakReminder'
$appDataPath = Join-Path $localAppData 'EyeBreakReminder'
$installedExe = Join-Path $installPath 'EyeBreakReminder.exe'
$uninstallerExe = Join-Path $installPath 'Uninstall.exe'
$fixtureExe = Join-Path (Get-Location) 'tests\installer-acceptance-fixture.exe'
$appReg = 'Registry::HKEY_CURRENT_USER\Software\EyeBreakReminder'
$uninstallReg = 'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder'
$startMenuFolder = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::Programs)) 'Eye Break Reminder'
$startMenuShortcut = Join-Path $startMenuFolder 'Eye Break Reminder.lnk'
$desktopShortcut = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::Desktop)) 'Eye Break Reminder.lnk'
$commonMenuShortcut = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonPrograms)) 'Eye Break Reminder\Eye Break Reminder.lnk'
$commonDesktopShortcut = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonDesktopDirectory)) 'Eye Break Reminder.lnk'

function Assert {
  param([string]$Name,[bool]$Passed,[object]$Observed,[object]$Expected)
  $item=[ordered]@{name=$Name;status=if($Passed){'PASS'}else{'FAIL'};observed=$Observed;expected=$Expected}
  $script:checks.Add($item)
  Write-Host ("ASSERT {0}: {1} | observed={2}" -f $item.status,$Name,(ConvertTo-Json -InputObject $Observed -Compress -Depth 5))
  if(-not $Passed){throw "Acceptance assertion failed: $Name"}
}
function Begin-Scenario([string]$Name){$script:scenario=$Name;$script:scenarios[$Name]='RUNNING';Write-Host "SCENARIO START: $Name"}
function End-Scenario([string]$Name){$script:scenarios[$Name]='PASS';$script:scenario=$null;Write-Host "SCENARIO PASS: $Name"}
function Hash([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function FileVersion([string]$Path){[Diagnostics.FileVersionInfo]::GetVersionInfo($Path)}
function FullPath([string]$Path){[IO.Path]::GetFullPath($Path).TrimEnd('\')}
function SamePath([string]$A,[string]$B){if([string]::IsNullOrWhiteSpace($A)-or[string]::IsNullOrWhiteSpace($B)){return $false};(FullPath $A)-ieq(FullPath $B)}
function IsDescendantPath([string]$Path,[string]$Parent){if([string]::IsNullOrWhiteSpace($Path)-or[string]::IsNullOrWhiteSpace($Parent)){return $false};$child=FullPath $Path;$prefix=(FullPath $Parent).TrimEnd('\')+'\';$child.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)}
function RegValue([string]$Path,[string]$Name){if(-not(Test-Path -LiteralPath $Path)){return $null};try{Get-ItemPropertyValue -LiteralPath $Path -Name $Name -ErrorAction Stop}catch{return $null}}
function RunValue{
  $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Run')
  if($null-eq$key){return [ordered]@{present=$false;kind=$null;value=$null}}
  try{
    if('EyeBreakReminder'-notin @($key.GetValueNames())){return [ordered]@{present=$false;kind=$null;value=$null}}
    [ordered]@{present=$true;kind=$key.GetValueKind('EyeBreakReminder').ToString();value=$key.GetValue('EyeBreakReminder',$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)}
  }finally{$key.Dispose()}
}
function SameRunValue([object]$A,[object]$B){
  [bool]($A.present-eq$B.present-and$A.kind-ceq$B.kind-and[string]$A.value-ceq[string]$B.value)
}
function TestOwnedStartupValue {
  $expected='"'+$installedExe+'" --startup'
  $key=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\Microsoft\Windows\CurrentVersion\Run')
  if($null-eq$key){throw 'Could not create the test-user Run registry key.'}
  try{$key.SetValue('EyeBreakReminder',$expected,[Microsoft.Win32.RegistryValueKind]::String)}finally{$key.Dispose()}
  $actual=RunValue
  Assert -Name 'test-owned startup value has the installed executable path' -Passed ($actual.present-and$actual.kind-ceq'String'-and$actual.value-ceq$expected) -Observed $actual -Expected ([ordered]@{present=$true;kind='String';value=$expected})
}
function TestForeignStartupValue {
  $expected='"C:\AcceptanceOther\EyeBreakReminder.exe" --startup'
  $key=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\Microsoft\Windows\CurrentVersion\Run')
  if($null-eq$key){throw 'Could not create the test-user Run registry key.'}
  try{$key.SetValue('EyeBreakReminder',$expected,[Microsoft.Win32.RegistryValueKind]::String)}finally{$key.Dispose()}
  $actual=RunValue;$script:expectedRunValue=$actual
  Assert -Name 'unrelated startup command fixture is present as REG_SZ' -Passed ($actual.present-and$actual.kind-ceq'String'-and$actual.value-ceq$expected) -Observed $actual -Expected ([ordered]@{present=$true;kind='String';value=$expected})
}
function ClearForeignStartupValue {
  $actual=RunValue
  Assert -Name 'uninstaller preserved unrelated startup command' -Passed (SameRunValue $actual $script:expectedRunValue) -Observed $actual -Expected $script:expectedRunValue
  $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Run',$true)
  if($null-eq$key){throw 'Startup Run key disappeared before fixture cleanup.'}
  try{$key.DeleteValue('EyeBreakReminder',$false)}finally{$key.Dispose()}
  $script:expectedRunValue=$script:environment.runValue;$restored=RunValue
  Assert -Name 'foreign startup fixture cleanup restores the initial value state' -Passed (SameRunValue $restored $script:environment.runValue) -Observed $restored -Expected $script:environment.runValue
}
function ReparseChain([string]$Path){
  $points=[Collections.Generic.List[string]]::new();$cursor=FullPath $Path
  while($true){
    $attributes=$null
    try{$item=Get-Item -LiteralPath $cursor -Force -ErrorAction Stop;$attributes=$item.Attributes}
    catch{
      try{$attributes=[IO.File]::GetAttributes($cursor)}
      catch [IO.FileNotFoundException]{$attributes=$null}
      catch [IO.DirectoryNotFoundException]{$attributes=$null}
      catch{$points.Add("uninspectable:$cursor")}
    }
    if($null-ne$attributes-and($attributes-band[IO.FileAttributes]::ReparsePoint)-ne 0){$points.Add($cursor)}
    $parent=Split-Path -Parent $cursor;if([string]::IsNullOrWhiteSpace($parent)-or(SamePath $parent $cursor)){break};$cursor=$parent
  }
  $points.ToArray()
}
function CheckNoReparse([string]$Path,[string]$Stage,[switch]$Contents){
  $chain=@(ReparseChain $Path);$nested=@()
  if($Contents-and(Test-Path -LiteralPath $Path -PathType Container)){$nested=@(Get-ChildItem -LiteralPath $Path -Force -Recurse|Where-Object{($_.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne 0}|ForEach-Object FullName)}
  Assert -Name "$Stage path has no reparse point" -Passed ($chain.Count-eq 0-and$nested.Count-eq 0) -Observed ([ordered]@{chain=$chain;nested=$nested}) -Expected @()
}
function DataHashes([string]$Label){
  $values=[ordered]@{}
  foreach($name in @('settings.ini','timer.dat','history.dat','acceptance-unrelated-sentinel.txt')){
    $path=Join-Path $appDataPath $name
    $values[$name]=if(Test-Path -LiteralPath $path -PathType Leaf){Hash $path}else{$null}
  }
  $script:dataSnapshots[$Label]=$values
  Write-Host ("DATA {0}: {1}" -f $Label,(ConvertTo-Json $values -Compress))
  return $values
}
function SeedEpoch{
  $path=Join-Path $appDataPath 'acceptance-unrelated-sentinel.txt'
  if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "Timer seed timestamp missing: $path"}
  $content=[IO.File]::ReadAllText($path)
  if($content-notmatch'(?m)^seeded-at=(\d+)\s*$'){throw 'Timer seed timestamp is malformed.'}
  [long]$Matches[1]
}
function CountdownSeconds([string]$Text){
  if($Text-notmatch'^(\d{2,}):([0-5]\d)$'){throw "Countdown text is not mm:ss: $Text"}
  ([int]$Matches[1]*60)+[int]$Matches[2]
}
function AssertCountdownNear([string]$Name,[string]$Text,[double]$ExpectedSeconds,[int]$ToleranceSeconds=5){
  $actual=CountdownSeconds $Text;$expected=[int][Math]::Ceiling($ExpectedSeconds);$delta=[Math]::Abs($actual-$expected)
  Assert -Name $Name -Passed ($ExpectedSeconds-gt 0-and$delta-le$ToleranceSeconds) -Observed ([ordered]@{text=$Text;seconds=$actual;expectedSeconds=$expected;deltaSeconds=$delta}) -Expected ([ordered]@{seconds=$expected;toleranceSeconds=$ToleranceSeconds})
}
function Fixture([string[]]$FixtureArgs){
  if(-not(Test-Path -LiteralPath $fixtureExe -PathType Leaf)){throw "Fixture helper absent: $fixtureExe"}
  $output=@(& $fixtureExe @FixtureArgs 2>&1);$code=$LASTEXITCODE
  foreach($line in $output){Write-Host $line}
  Assert -Name ("fixture "+($FixtureArgs -join ' ')) -Passed ($code-eq 0) -Observed $code -Expected 0
}
function EyeBreakProcesses{@(Get-CimInstance Win32_Process -Filter "Name='EyeBreakReminder.exe'")}
function NoEyeBreak([string]$Stage){
  $found=@(EyeBreakProcesses)
  $details=@($found|ForEach-Object{[ordered]@{pid=[int]$_.ProcessId;path=$_.ExecutablePath;parent=[int]$_.ParentProcessId}})
  Assert -Name "$Stage has no Eye Break Reminder process" -Passed ($found.Count-eq 0) -Observed $details -Expected @()
}
function TreeSnapshot([int]$Root,[datetime]$Started){
  $all=@(Get-CimInstance Win32_Process);$ids=[Collections.Generic.HashSet[int]]::new();[void]$ids.Add($Root)
  $children=[Collections.Generic.List[object]]::new();$unknown=[Collections.Generic.List[object]]::new();$changed=$true
  while($changed){
    $changed=$false
    foreach($p in $all){
      $parent=[int]$p.ParentProcessId;$id=[int]$p.ProcessId
      if(-not$ids.Contains($parent)-or$ids.Contains($id)){continue}
      try{if($p.CreationDate-is[datetime]){$created=$p.CreationDate.ToUniversalTime()}else{$created=[Management.ManagementDateTimeConverter]::ToDateTime([string]$p.CreationDate).ToUniversalTime()}}catch{[void]$ids.Add($id);$changed=$true;$unknown.Add([ordered]@{pid=$id;parent=$parent;name=$p.Name;path=$p.ExecutablePath;creationDate=[string]$p.CreationDate});continue}
      if($created-lt$Started.AddSeconds(-2)){continue}
      [void]$ids.Add($id);$children.Add([ordered]@{pid=$id;parent=$parent;name=$p.Name;path=$p.ExecutablePath;createdUtc=$created.ToString('o')});$changed=$true
    }
  }
  $alive=@($all|Where-Object{$ids.Contains([int]$_.ProcessId)}|ForEach-Object{[ordered]@{pid=[int]$_.ProcessId;parent=[int]$_.ParentProcessId;name=$_.Name;path=$_.ExecutablePath}})
  [ordered]@{alive=$alive;children=@($children);unknown=@($unknown)}
}
function WaitTree([int]$Root,[datetime]$Started,[int]$Seconds=20){
  $until=[DateTime]::UtcNow.AddSeconds($Seconds)
  do{$snap=TreeSnapshot $Root $Started;if(@($snap.alive).Count-eq 0-and@($snap.unknown).Count-eq 0){return $snap};Start-Sleep -Milliseconds 250}while([DateTime]::UtcNow-lt$until)
  TreeSnapshot $Root $Started
}
function RunBounded([string]$Name,[string]$Path,[string[]]$ProcessArgs,[int]$Seconds=120){
  if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){throw "$Name executable missing: $Path"}
  $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$Path;$info.WorkingDirectory=Split-Path -Parent $Path
  $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
  foreach($arg in $ProcessArgs){[void]$info.ArgumentList.Add($arg)}
  $proc=[Diagnostics.Process]::new();$proc.StartInfo=$info;$started=[DateTime]::UtcNow
  if(-not$proc.Start()){throw "$Name did not start"};$id=$proc.Id
  try{$processSid=ProcessSid $proc;$sessionId=$proc.SessionId;$processImage=ProcessImage $proc}catch{try{$proc.Kill($true);[void]$proc.WaitForExit(5000)}catch{};$proc.Dispose();throw}
  $identityOk=($processSid-eq$script:environment.sid)-and($sessionId-eq$script:environment.sessionId)-and(SamePath $processImage $Path)
  if(-not$identityOk){
    $identityRecord=[ordered]@{name=$Name;path=$Path;actualProcessImage=$processImage;pid=$id;processTokenSid=$processSid;sessionId=$sessionId;expectedSid=$script:environment.sid;expectedSessionId=$script:environment.sessionId;identityAccepted=$false}
    $script:installerProcesses.Add($identityRecord);Write-Host ("PROCESS IDENTITY REJECTED: "+(ConvertTo-Json $identityRecord -Compress))
    try{$proc.Kill($true);[void]$proc.WaitForExit(5000)}catch{}
    $proc.Dispose();throw "$Name process image, token SID, or session did not match the runner before waiting for completion."
  }
  $exited=$proc.WaitForExit($Seconds*1000)
  $code=if($exited){$proc.ExitCode}else{$null}
  if(-not$exited){try{$proc.Kill($true);[void]$proc.WaitForExit(5000)}catch{}}
  $tree=WaitTree $id $started 20
  $record=[ordered]@{name=$Name;path=$Path;args=$ProcessArgs;actualProcessImage=$processImage;pid=$id;startedUtc=$started.ToString('o');timeoutSeconds=$Seconds;processTokenSid=$processSid;sessionId=$sessionId;identityAccepted=$identityOk;exited=$exited;exitCode=$code;descendants=$tree.children;remainingTree=$tree.alive;unknownTree=$tree.unknown}
  $script:installerProcesses.Add($record);Write-Host ("PROCESS: "+(ConvertTo-Json $record -Compress -Depth 6))
  Assert -Name "$Name process token SID matches runner identity" -Passed ($processSid-eq$script:environment.sid) -Observed $processSid -Expected $script:environment.sid
  Assert -Name "$Name runs in the runner process session" -Passed ($sessionId-eq$script:environment.sessionId) -Observed $sessionId -Expected $script:environment.sessionId
  Assert -Name "$Name and descendants exit within timeout" -Passed ($exited-and@($tree.alive).Count-eq 0-and@($tree.unknown).Count-eq 0) -Observed ([ordered]@{exited=$exited;exitCode=$code;remaining=$tree.alive;unknown=$tree.unknown}) -Expected 'all processes exited'
  Assert -Name "$Name exit code" -Passed ($code-eq 0) -Observed $code -Expected 0
  $proc.Dispose();$record
}
function PeInfo([string]$Path){
  $b=[IO.File]::ReadAllBytes($Path)
  if($b.Length-lt 256-or$b[0]-ne 0x4D-or$b[1]-ne 0x5A){throw "Not a PE: $Path"}
  $offset=[BitConverter]::ToInt32($b,0x3C)
  if($offset-lt 0-or$offset+26-gt$b.Length-or$b[$offset]-ne 0x50-or$b[$offset+1]-ne 0x45-or$b[$offset+2]-ne 0-or$b[$offset+3]-ne 0){throw "Invalid PE header: $Path"}
  [ordered]@{machine=('0x{0:X4}'-f[BitConverter]::ToUInt16($b,$offset+4));magic=('0x{0:X4}'-f[BitConverter]::ToUInt16($b,$offset+24))}
}
function AppIdentity([string]$Path,[string]$Version,[string]$ExpectedHash){
  $v=FileVersion $Path;$pe=PeInfo $Path;$sha=Hash $Path
  Assert -Name "$Version app is x64 PE32+" -Passed ($pe.machine-eq'0x8664'-and$pe.magic-eq'0x020B') -Observed $pe -Expected @{machine='0x8664';magic='0x020B'}
  Assert -Name "$Version app file version" -Passed ($v.FileVersion-eq"$Version.0") -Observed $v.FileVersion -Expected "$Version.0"
  if($ExpectedHash){Assert -Name "$Version app SHA-256" -Passed ($sha-eq$ExpectedHash) -Observed $sha -Expected $ExpectedHash}
  [ordered]@{path=$Path;fileVersion=$v.FileVersion;productVersion=$v.ProductVersion;sha256=$sha;pe=$pe}
}
function HklmPaths{
  @('Registry::HKEY_LOCAL_MACHINE\SOFTWARE\EyeBreakReminder',
    'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder',
    'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\EyeBreakReminder',
    'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder')
}
function NoHklm([string]$Stage){$present=@(HklmPaths|Where-Object{Test-Path -LiteralPath $_});Assert -Name "$Stage no HKLM registration" -Passed ($present.Count-eq 0) -Observed $present -Expected @()}
function MachineAppDirectories{
  $roots=@($env:ProgramFiles);$pf86=[Environment]::GetEnvironmentVariable('ProgramFiles(x86)');if($pf86){$roots+=$pf86}
  @($roots|Where-Object{Test-Path -LiteralPath $_ -PathType Container}|ForEach-Object{Get-ChildItem -LiteralPath $_ -Force -Directory}|Where-Object{$_.Name-like'*EyeBreak*'-or$_.Name-like'*Eye Break*'}|ForEach-Object{FullPath $_.FullName}|Sort-Object)
}
function NoMachineAppDirectories([string]$Stage){$actual=@(MachineAppDirectories);Assert -Name "$Stage no machine-wide app directories" -Passed ($actual.Count-eq 0) -Observed $actual -Expected @()}
function InstalledFiles{
  if(-not(Test-Path -LiteralPath $installPath -PathType Container)){return @()}
  @(Get-ChildItem -LiteralPath $installPath -Force -File -Recurse|ForEach-Object{$_.FullName.Substring($installPath.Length).TrimStart('\')}|Sort-Object)
}
function CheckFileSet([string]$Stage){
  CheckNoReparse $installPath "$Stage install" -Contents
  $expected=@('EyeBreakReminder.exe','PRIVACY.md','README.md','Uninstall.exe','VERIFICATION.md')|Sort-Object
  $actual=@(InstalledFiles)
  [string[]]$dirs=@()
  if(Test-Path -LiteralPath $installPath -PathType Container){
    $dirs=@(
      Get-ChildItem -LiteralPath $installPath -Force -Directory -Recurse |
        ForEach-Object Name
    )
  }
  $ok=([string]::Join('|',$actual)-ceq[string]::Join('|',$expected))-and$dirs.Count-eq 0
  Assert -Name "$Stage exact installed files/layout" -Passed $ok -Observed ([ordered]@{files=$actual;directories=$dirs}) -Expected $expected
}
function CheckNoDuplicate([string]$Stage){
  $root=Join-Path $localAppData 'Programs'

  [string[]]$actual=@()
  if(Test-Path -LiteralPath $root -PathType Container){
    $actual=@(
      Get-ChildItem -LiteralPath $root -Force -Directory |
        Where-Object { $_.Name -like '*EyeBreak*' -or $_.Name -like '*Eye Break*' } |
        ForEach-Object { FullPath $_.FullName } |
        Sort-Object
    )
  }

  [string[]]$expected=@()
  if(Test-Path -LiteralPath $installPath -PathType Container){
    $expected=@((FullPath $installPath))
  }

  $valid=($actual.Count -eq $expected.Count)

  if($valid -and $expected.Count -eq 1){
    $valid=(SamePath $actual[0] $expected[0])
  }

  Assert -Name "$Stage no duplicate per-user install" -Passed $valid -Observed $actual -Expected $expected
}
function CheckInstallRegistration([string]$Version,[string]$Stage){
  $dir=RegValue $appReg 'InstallDir';$name=RegValue $uninstallReg 'DisplayName';$dv=RegValue $uninstallReg 'DisplayVersion'
  $loc=RegValue $uninstallReg 'InstallLocation';$icon=RegValue $uninstallReg 'DisplayIcon';$uninst=[string](RegValue $uninstallReg 'UninstallString')
  Assert -Name "$Stage HKCU app InstallDir" -Passed (SamePath ([string]$dir) $installPath) -Observed $dir -Expected $installPath
  Assert -Name "$Stage uninstall registration version/name" -Passed ($name-eq'Eye Break Reminder'-and$dv-eq$Version) -Observed ([ordered]@{name=$name;version=$dv}) -Expected ([ordered]@{name='Eye Break Reminder';version=$Version})
  $paths=(SamePath ([string]$loc) $installPath)-and(SamePath ([string]$icon) $installedExe)-and(SamePath $uninst.Trim('"') $uninstallerExe)
  Assert -Name "$Stage uninstall registration paths" -Passed $paths -Observed ([ordered]@{location=$loc;icon=$icon;uninstall=$uninst}) -Expected ([ordered]@{location=$installPath;icon=$installedExe;uninstall='"'+$uninstallerExe+'"'})
  $sidApp="Registry::HKEY_USERS\$($script:environment.sid)\Software\EyeBreakReminder"
  $sidUninstall="Registry::HKEY_USERS\$($script:environment.sid)\Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder"
  $sidOk=(SamePath ([string](RegValue $sidApp 'InstallDir')) $installPath)-and((RegValue $sidUninstall 'DisplayVersion')-eq$Version)
  Assert -Name "$Stage HKCU matches process SID hive" -Passed $sidOk -Observed ([ordered]@{sid=$script:environment.sid;installDir=(RegValue $sidApp 'InstallDir');version=(RegValue $sidUninstall 'DisplayVersion')}) -Expected ([ordered]@{sid=$script:environment.sid;installDir=$installPath;version=$Version})
  if(-not(Test-Path -LiteralPath $startMenuShortcut -PathType Leaf)){Assert -Name "$Stage per-user Start Menu shortcut exists" -Passed $false -Observed $startMenuShortcut -Expected 'shortcut exists';return}
  $shell=New-Object -ComObject WScript.Shell;$link=$null
  try{$link=$shell.CreateShortcut($startMenuShortcut);$target=(SamePath ([string]$link.TargetPath) $installedExe)
    $iconParts=([string]$link.IconLocation).Split(',');$iconOk=($iconParts.Count-eq 2)-and(SamePath $iconParts[0] $installedExe)-and($iconParts[1].Trim()-ceq'0')
    Assert -Name "$Stage shortcut target and icon" -Passed ($target-and$iconOk) -Observed ([ordered]@{target=$link.TargetPath;icon=$link.IconLocation}) -Expected ([ordered]@{target=$installedExe;icon="$installedExe,0"})
  }finally{if($null-ne$link){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($link)};[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)}
  Assert -Name "$Stage optional user Desktop shortcut not selected" -Passed (-not(Test-Path -LiteralPath $desktopShortcut)) -Observed (Test-Path -LiteralPath $desktopShortcut) -Expected $false
  $shared=(Test-Path -LiteralPath $commonMenuShortcut)-or(Test-Path -LiteralPath $commonDesktopShortcut)
  Assert -Name "$Stage has no shared shortcuts" -Passed (-not$shared) -Observed $shared -Expected $false
  NoHklm $Stage;NoMachineAppDirectories $Stage;CheckNoDuplicate $Stage
}
function CheckUninstalled([string]$Stage){
  if(Test-Path -LiteralPath $installPath){
    $remaining=@()
    if(Test-Path -LiteralPath $installPath -PathType Container){
      $remaining=@(
        Get-ChildItem -LiteralPath $installPath -Force |
        ForEach-Object { $_.Name }
      )
    }else{
      $remaining=@('[installation path exists but is not a directory]')
    }
    Write-Host (
      'UNINSTALL_REMAINING: ' +
      (ConvertTo-Json -InputObject $remaining -Compress)
    )
  }
  Assert -Name "$Stage files removed" -Passed (-not(Test-Path -LiteralPath $installPath)) -Observed (Test-Path -LiteralPath $installPath) -Expected $false
  foreach($pair in @(@($startMenuShortcut,'user Start Menu shortcut'),@($startMenuFolder,'user Start Menu folder'),@($desktopShortcut,'user Desktop'),@($commonMenuShortcut,'common Start Menu'),@($commonDesktopShortcut,'common Desktop'))){
    Assert -Name "$Stage $($pair[1]) absent" -Passed (-not(Test-Path -LiteralPath $pair[0])) -Observed (Test-Path -LiteralPath $pair[0]) -Expected $false
  }
  $keys=(Test-Path -LiteralPath $appReg)-or(Test-Path -LiteralPath $uninstallReg)
  Assert -Name "$Stage HKCU app and uninstall keys removed" -Passed (-not$keys) -Observed $keys -Expected $false
  NoHklm $Stage;NoMachineAppDirectories $Stage;CheckNoDuplicate $Stage
  $run=RunValue;Assert -Name "$Stage startup Run value matches expected policy state" -Passed (SameRunValue $run $script:expectedRunValue) -Observed $run -Expected $script:expectedRunValue
}
function CheckInstall([string]$Version,[string]$Stage,[string]$ExpectedHash){
  CheckFileSet $Stage;$exe=AppIdentity $installedExe $Version $ExpectedHash
  Assert -Name "$Stage executable installed at expected path" -Passed (SamePath $exe.path $installedExe) -Observed $exe.path -Expected $installedExe
  CheckInstallRegistration $Version $Stage
  $exe
}
function Install([string]$Name,[string]$Path){
  NoEyeBreak "$Name preflight";[void](RunBounded $Name $Path @('/S') 120);NoEyeBreak "$Name postflight"
}
function Add-WindowProbe{
  if('EbrAcceptanceWindowProbe'-as[type]){return}
  Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;
public static class EbrAcceptanceWindowProbe {
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string className,string windowName);
[DllImport("user32.dll", EntryPoint="GetClassNameW", CharSet=CharSet.Unicode, ExactSpelling=true, SetLastError=true)] public static extern int GetClassName(IntPtr hwnd,System.Text.StringBuilder className,int maxCount);
[DllImport("user32.dll", EntryPoint="GetParent", ExactSpelling=true)]
public static extern IntPtr GetParent(IntPtr hwnd);

[UnmanagedFunctionPointer(CallingConvention.Winapi)]
private delegate bool ChildWindowVisitor(IntPtr hwnd,IntPtr data);

[DllImport("user32.dll", EntryPoint="EnumChildWindows", ExactSpelling=true)]
private static extern bool EnumerateChildren(
    IntPtr parent,ChildWindowVisitor callback,IntPtr data);

[DllImport("user32.dll", EntryPoint="GetDlgCtrlID", ExactSpelling=true)]
public static extern int GetDlgCtrlID(IntPtr hwnd);

public static IntPtr[] DirectChildWindows(IntPtr parent) {
    var children=new System.Collections.Generic.List<IntPtr>();
    ChildWindowVisitor callback=(child,data)=>{
        if(GetParent(child)==parent) children.Add(child);
        return true;
    };
    EnumerateChildren(parent,callback,IntPtr.Zero);
    GC.KeepAlive(callback);
    return children.ToArray();
}
public static IntPtr FindSettingsPaneByEnumeration(IntPtr parent,uint expectedPid) {
    IntPtr match=IntPtr.Zero;

    ChildWindowVisitor callback=(child,data)=>{
        if(GetParent(child)!=parent)return true;

        uint pid=0;
        if(GetWindowThreadProcessId(child,out pid)==0 || pid!=expectedPid)
            return true;

        var cls=new System.Text.StringBuilder(256);
        if(GetClassName(child,cls,cls.Capacity)>0 &&
           string.Equals(cls.ToString(),"EyeBreakReminder.Settings",
                         StringComparison.Ordinal)){
            match=child;
            return false;
        }
        return true;
    };

    EnumerateChildren(parent,callback,IntPtr.Zero);
    GC.KeepAlive(callback);
    return match;
}
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent,IntPtr after,string className,string windowName);
 [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr parent,int id);
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hwnd,System.Text.StringBuilder text,int count);
 [DllImport("user32.dll", EntryPoint="SendMessageTimeoutW", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr SendMessageTimeoutText(IntPtr hwnd,uint message,IntPtr wParam,System.Text.StringBuilder text,uint flags,uint timeout,out IntPtr result);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd,out uint processId);
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern uint RegisterWindowMessage(string message);
 [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr SendMessageTimeout(IntPtr hwnd,uint message,IntPtr wParam,IntPtr lParam,uint flags,uint timeout,out IntPtr result);
}
public static class EbrProcessTokenProbe {
 [StructLayout(LayoutKind.Sequential)] struct SidAndAttributes { public IntPtr Sid; public uint Attributes; }
 [StructLayout(LayoutKind.Sequential)] struct TokenUser { public SidAndAttributes User; }
  [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr processHandle,uint desiredAccess,out IntPtr tokenHandle);
 [DllImport("advapi32.dll", SetLastError=true)] static extern bool GetTokenInformation(IntPtr tokenHandle,int tokenInformationClass,IntPtr tokenInformation,int tokenInformationLength,out int returnLength);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool QueryFullProcessImageName(IntPtr processHandle,uint flags,System.Text.StringBuilder imagePath,ref int size);
 [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
 public static string SidForProcess(IntPtr processHandle) {
  IntPtr token=IntPtr.Zero,buffer=IntPtr.Zero;
  try {
   if(!OpenProcessToken(processHandle,0x0008,out token)) throw new Win32Exception(Marshal.GetLastWin32Error());
   int size=0; GetTokenInformation(token,1,IntPtr.Zero,0,out size);
   if(size<=0) throw new Win32Exception(Marshal.GetLastWin32Error());
   buffer=Marshal.AllocHGlobal(size);
   if(!GetTokenInformation(token,1,buffer,size,out size)) throw new Win32Exception(Marshal.GetLastWin32Error());
   TokenUser user=(TokenUser)Marshal.PtrToStructure(buffer,typeof(TokenUser));
   return new SecurityIdentifier(user.User.Sid).Value;
  } finally { if(buffer!=IntPtr.Zero) Marshal.FreeHGlobal(buffer); if(token!=IntPtr.Zero) CloseHandle(token); }
 }
  public static string ImageForProcess(IntPtr processHandle) {
   System.Text.StringBuilder image=new System.Text.StringBuilder(32768);int size=image.Capacity;
   if(!QueryFullProcessImageName(processHandle,0,image,ref size)) throw new Win32Exception(Marshal.GetLastWin32Error());
   return image.ToString();
  }
}
'@
}
function ProcessSid([Diagnostics.Process]$Process){[EbrProcessTokenProbe]::SidForProcess($Process.Handle)}
function ProcessImage([Diagnostics.Process]$Process){[EbrProcessTokenProbe]::ImageForProcess($Process.Handle)}
function UiChild([IntPtr]$Parent,[int]$Id,[string]$Name){
  $child=[EbrAcceptanceWindowProbe]::GetDlgItem($Parent,$Id)
  Assert -Name "$Name control exists" -Passed ($child-ne[IntPtr]::Zero) -Observed ('0x{0:X}'-f$child.ToInt64()) -Expected 'nonzero HWND'
  $visible=if($child-ne[IntPtr]::Zero){[EbrAcceptanceWindowProbe]::IsWindowVisible($child)}else{$false}
  Assert -Name "$Name control is visible in the active window hierarchy" -Passed $visible -Observed $visible -Expected $true
  $child
}
function UiMessage([IntPtr]$Hwnd,[uint32]$Message,[IntPtr]$WParam=[IntPtr]::Zero,[IntPtr]$LParam=[IntPtr]::Zero){
  $result=[IntPtr]::Zero;$sent=[EbrAcceptanceWindowProbe]::SendMessageTimeout($Hwnd,$Message,$WParam,$LParam,2,3000,[ref]$result)
  if($sent-eq[IntPtr]::Zero){throw ("UI message 0x{0:X} timed out or failed"-f$Message)}
  $result
}
function UiText([IntPtr]$Parent,[int]$Id,[string]$Name){
  $control=UiChild $Parent $Id $Name;$buffer=[Text.StringBuilder]::new(1024);$result=[IntPtr]::Zero
  $sent=[EbrAcceptanceWindowProbe]::SendMessageTimeoutText($control,0x000D,[IntPtr]$buffer.Capacity,$buffer,2,3000,[ref]$result)
  if($sent-eq[IntPtr]::Zero){throw "Reading native control text timed out: $Name"}
  $buffer.ToString()
}
function UiExpectText([IntPtr]$Parent,[int]$Id,[string]$Name,[string]$Expected){
  $actual=UiText $Parent $Id $Name
  Assert -Name "$Name visible control text" -Passed ($actual-ceq$Expected) -Observed $actual -Expected $Expected
}
function UiExpectCheck([IntPtr]$Parent,[int]$Id,[string]$Name,[bool]$Expected){
  $control=UiChild $Parent $Id $Name;$result=[IntPtr]::Zero
  $sent=[EbrAcceptanceWindowProbe]::SendMessageTimeout($control,0x00F0,[IntPtr]::Zero,[IntPtr]::Zero,2,3000,[ref]$result)
  if($sent-eq[IntPtr]::Zero){throw "Reading native checkbox state timed out: $Name"}
  $check=$result.ToInt64();Assert -Name "$Name checked state" -Passed ($check-eq[long]([int]$Expected)) -Observed $check -Expected ([int]$Expected)
}
function UiExpectSelection([IntPtr]$Parent,[int]$Id,[string]$Name,[int]$Expected){
  $control=UiChild $Parent $Id $Name;$result=[IntPtr]::Zero;$sent=[EbrAcceptanceWindowProbe]::SendMessageTimeout($control,0x0147,[IntPtr]::Zero,[IntPtr]::Zero,2,3000,[ref]$result)
  if($sent-eq[IntPtr]::Zero){throw "Reading native combo selection timed out: $Name"}
  $actual=$result.ToInt64();Assert -Name "$Name selected index" -Passed ($actual-eq$Expected) -Observed $actual -Expected $Expected
}
function UiClick([IntPtr]$Parent,[int]$Id,[string]$Name){
  $control=UiChild $Parent $Id $Name;[void](UiMessage $control 0x00F5)
}
function UiSettingsPane([IntPtr]$Main){
  [uint32]$mainPid=0
  [void][EbrAcceptanceWindowProbe]::GetWindowThreadProcessId(
    $Main,[ref]$mainPid
  )

  $pane=[EbrAcceptanceWindowProbe]::FindWindowEx(
    $Main,[IntPtr]::Zero,'EyeBreakReminder.Settings',$null
  )

  $method='class lookup'
  $observed=[Collections.Generic.List[object]]::new()

  if($pane -eq [IntPtr]::Zero){
    $method='direct child enumeration'
    $after=[IntPtr]::Zero

    for($i=0;$i -lt 512;$i++){
      $child=[EbrAcceptanceWindowProbe]::FindWindowEx(
        $Main,$after,$null,$null
      )

      if($child -eq [IntPtr]::Zero){break}
      $after=$child

      $classBuffer=[Text.StringBuilder]::new(256)
      [void][EbrAcceptanceWindowProbe]::GetClassName(
        $child,$classBuffer,$classBuffer.Capacity
      )

      [uint32]$childPid=0
      [void][EbrAcceptanceWindowProbe]::GetWindowThreadProcessId(
        $child,[ref]$childPid
      )

      if($observed.Count -lt 30){
        $observed.Add([ordered]@{
          handle=('0x{0:X}' -f $child.ToInt64())
          class=$classBuffer.ToString()
          pid=$childPid
        })
      }

      if(
        $classBuffer.ToString() -ceq 'EyeBreakReminder.Settings' -and
        $childPid -eq $mainPid
      ){
        $pane=$child
        break
      }
    }
  }

  # The v1.0.6 settings pane has a null child-window ID.
  # ID zero is only a candidate; verify class, parent and PID.
  if($pane -eq [IntPtr]::Zero){
    $candidate=[EbrAcceptanceWindowProbe]::GetDlgItem($Main,0)

    if($candidate -ne [IntPtr]::Zero){
      $candidateClass=[Text.StringBuilder]::new(256)
      [void][EbrAcceptanceWindowProbe]::GetClassName(
        $candidate,$candidateClass,$candidateClass.Capacity
      )

      [uint32]$candidatePid=0
      [void][EbrAcceptanceWindowProbe]::GetWindowThreadProcessId(
        $candidate,[ref]$candidatePid
      )

      $candidateParent=[EbrAcceptanceWindowProbe]::GetParent($candidate)

      Write-Host (
        'SETTINGS_ID_ZERO: ' +
        (ConvertTo-Json -InputObject ([ordered]@{
          handle=('0x{0:X}' -f $candidate.ToInt64())
          class=$candidateClass.ToString()
          pid=$candidatePid
          directParent=($candidateParent -eq $Main)
        }) -Compress)
      )

      if(
        $candidateClass.ToString() -ceq 'EyeBreakReminder.Settings' -and
        $candidatePid -eq $mainPid -and
        $candidateParent -eq $Main
      ){
        $pane=$candidate
        $method='validated child ID zero'
      }
    }
  }

  if($pane -eq [IntPtr]::Zero){
    $method='native EnumChildWindows'
    $pane=[EbrAcceptanceWindowProbe]::FindSettingsPaneByEnumeration(
      $Main,$mainPid
    )
  }
  # Validate the handle even if the original lookup succeeded.
  if($pane -ne [IntPtr]::Zero){
    [uint32]$panePid=0
    $paneClass=[Text.StringBuilder]::new(256)

    [void][EbrAcceptanceWindowProbe]::GetWindowThreadProcessId(
      $pane,[ref]$panePid
    )
    [void][EbrAcceptanceWindowProbe]::GetClassName(
      $pane,$paneClass,$paneClass.Capacity
    )

    if(
      $panePid -ne $mainPid -or
      $paneClass.ToString() -cne 'EyeBreakReminder.Settings'
    ){
      $pane=[IntPtr]::Zero
    }
  }

  Write-Host (
    'SETTINGS_PANE_PROBE: ' +
    (ConvertTo-Json -InputObject ([ordered]@{
      method=$method
      mainPid=$mainPid
      handle=('0x{0:X}' -f $pane.ToInt64())
      observedChildren=$observed.ToArray()
    }) -Depth 5 -Compress)
  )

  $pane
}
function UiExpectStaticLabel([IntPtr]$Parent,[string]$Name,[string]$Expected){
  [uint32]$parentPid=0
  [void][EbrAcceptanceWindowProbe]::GetWindowThreadProcessId(
    $Parent,[ref]$parentPid
  )

  $matches=[Collections.Generic.List[IntPtr]]::new()
  $samples=[Collections.Generic.List[object]]::new()
  $candidateCount=0

  foreach($child in [EbrAcceptanceWindowProbe]::DirectChildWindows($Parent)){
    if([EbrAcceptanceWindowProbe]::GetParent($child) -ne $Parent){continue}

    [uint32]$childPid=0
    [void][EbrAcceptanceWindowProbe]::GetWindowThreadProcessId(
      $child,[ref]$childPid
    )
    if($childPid -ne $parentPid -or $parentPid -eq 0){continue}

    $className=[Text.StringBuilder]::new(256)
    [void][EbrAcceptanceWindowProbe]::GetClassName(
      $child,$className,$className.Capacity
    )
    if($className.ToString() -ine 'Static'){continue}

    $nativeId=[EbrAcceptanceWindowProbe]::GetDlgCtrlID($child)
    if($nativeId -ne -1){continue}

    if(-not [EbrAcceptanceWindowProbe]::IsWindowVisible($child)){continue}

    $candidateCount++
    $buffer=[Text.StringBuilder]::new(2048)
    $result=[IntPtr]::Zero
    $sent=[EbrAcceptanceWindowProbe]::SendMessageTimeoutText(
      $child,0x000D,[IntPtr]$buffer.Capacity,$buffer,
      2,3000,[ref]$result
    )

    if($sent -eq [IntPtr]::Zero){
      throw "Unable to read $Name STATIC label candidate"
    }

    $actual=$buffer.ToString()
    if($samples.Count -lt 20){
      $samples.Add([ordered]@{
        handle=('0x{0:X}' -f $child.ToInt64())
        text=$actual
      })
    }

    if($actual -ceq $Expected){
      $matches.Add($child)
    }
  }

  Assert -Name "$Name visible native label and exact text" `
    -Passed ($matches.Count -eq 1) `
    -Observed ([ordered]@{
      matchingLabels=$matches.Count
      visibleStaticCandidates=$candidateCount
      examined=$samples.ToArray()
    }) `
    -Expected ([ordered]@{
      class='Static'
      nativeId=-1
      parent='settings pane'
      text=$Expected
      matchingLabels=1
    })
}
function UiExpectedDefaults([IntPtr]$Main,[bool]$Fresh,[bool]$HasSchedule){
  UiClick $Main 12 'Settings tab';$settings=UiSettingsPane $Main
  Assert -Name 'settings pane window exists' -Passed ($settings-ne[IntPtr]::Zero) -Observed ('0x{0:X}'-f$settings.ToInt64()) -Expected 'nonzero HWND'
  UiClick $Main 130 'Intervals section'
  UiExpectText $settings 100 'work interval' $(if($Fresh){'20'}else{'25'})
  UiExpectText $settings 101 'break duration' $(if($Fresh){'20'}else{'30'})
  $alarmSection=if($HasSchedule){132}else{131};$reminderSection=if($HasSchedule){133}else{132};$generalSection=if($HasSchedule){134}else{133}
  UiClick $Main $alarmSection 'Alarm section'
  UiExpectSelection $settings 102 'alarm sound' $(if($Fresh){0}else{2})
  $volume=UiChild $settings 103 'alarm volume';$result=[IntPtr]::Zero;$sent=[EbrAcceptanceWindowProbe]::SendMessageTimeout($volume,0x0400,[IntPtr]::Zero,[IntPtr]::Zero,2,3000,[ref]$result)
  if($sent-eq[IntPtr]::Zero){throw 'Reading native alarm volume timed out'}
  $actualVolume=$result.ToInt64();$expectedVolume=if($Fresh){55}else{63};Assert -Name 'alarm volume slider position' -Passed ($actualVolume-eq$expectedVolume) -Observed $actualVolume -Expected $expectedVolume
  UiExpectCheck $settings 32 'alarm enabled' $true
  UiExpectCheck $settings 107 'repeat alarm' (-not$Fresh)
  UiClick $Main $reminderSection 'Break reminders section'
  UiExpectCheck $settings 108 'Windows notifications' $Fresh
  UiExpectCheck $settings 109 'snooze enabled' $true
  UiExpectSelection $settings 104 'break presentation' $(if($Fresh){0}else{1})
  UiExpectSelection $settings 105 'preferred monitor' 0
  UiExpectSelection $settings 115 'selected monitor' 0
  UiClick $Main $generalSection 'General section'
  UiExpectSelection $settings 106 'theme' $(if($Fresh){0}else{2})
  UiExpectCheck $settings 110 'start timer automatically' $true
  UiExpectCheck $settings 111 'start with Windows' $false
  UiExpectCheck $settings 112 'minimize to tray' $Fresh
  UiExpectCheck $settings 113 'resume countdown setting' $true
  UiExpectCheck $settings 114 'pause while locked setting' $true
  if($HasSchedule){
    UiClick $Main 131 'Operating Schedule section';$settings=UiSettingsPane $Main
    UiExpectCheck $settings 120 'operating schedule enabled' $false
    UiExpectStaticLabel $settings 'operating schedule status' 'The operating schedule is off. Reminders run whenever the timer is running.'
    for($day=0;$day-lt 7;$day++){
      UiExpectCheck $settings (280+$day) "default schedule day $day" ($day-lt 5)
      UiExpectText $settings (300+$day*10) "default schedule day $day start" '09:00'
      UiExpectText $settings (301+$day*10) "default schedule day $day end" '17:00'
    }
  }
  UiClick $Main 10 'Timer tab'
}
function UiExpectedClosedSchedule([IntPtr]$Main){
  UiExpectText $Main 41 'closed schedule timer state' 'Outside scheduled hours'
  UiExpectText $Main 42 'closed schedule timer caption' 'On hold'
  UiExpectText $Main 40 'closed schedule full work interval' '25:00'
  UiClick $Main 12 'Settings tab';$settings=UiSettingsPane $Main
  UiClick $Main 131 'Operating Schedule section';$settings=UiSettingsPane $Main
  UiExpectCheck $settings 120 'closed schedule enabled' $true
  UiExpectStaticLabel $settings 'closed schedule status' 'No days are selected, so no automatic reminders will occur.'
  for($day=0;$day-lt 7;$day++){
    UiExpectCheck $settings (280+$day) "closed schedule day $day" $false
    UiExpectText $settings (300+$day*10) "closed schedule day $day start" '09:00'
    UiExpectText $settings (301+$day*10) "closed schedule day $day end" '17:00'
  }
  UiClick $Main 10 'Timer tab'
}
function UiHistoryCount([IntPtr]$Main,[int]$Expected,[string]$Stage){
  UiClick $Main 11 'History tab';$list=UiChild $Main 200 'history list';$result=[IntPtr]::Zero
  UiExpectCheck $Main 30 'save history setting' $true
  $sent=[EbrAcceptanceWindowProbe]::SendMessageTimeout($list,0x1004,[IntPtr]::Zero,[IntPtr]::Zero,2,3000,[ref]$result)
  if($sent-eq[IntPtr]::Zero){throw 'Reading native history row count timed out'}
  $actual=$result.ToInt64();Assert -Name "$Stage history list row count" -Passed ($actual-eq$Expected) -Observed $actual -Expected $Expected
  UiClick $Main 10 'Timer tab'
}
function AppSmoke([string]$Version,[string]$Stage){
  NoEyeBreak "$Stage preflight";Add-WindowProbe
  $file=FileVersion $installedExe
  Assert -Name "$Stage launch file version" -Passed ($file.FileVersion-eq"$Version.0") -Observed $file.FileVersion -Expected "$Version.0"
  $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$installedExe;$info.WorkingDirectory=$installPath;$info.UseShellExecute=$false;$info.CreateNoWindow=$false;$info.WindowStyle=[Diagnostics.ProcessWindowStyle]::Normal
  $proc=[Diagnostics.Process]::new();$proc.StartInfo=$info;$started=[DateTime]::UtcNow
  if(-not$proc.Start()){throw "$Stage app failed to start"};$id=$proc.Id;$script:activeAppPid=$id
  try{$processSid=ProcessSid $proc;$processSession=$proc.SessionId;$processImage=ProcessImage $proc}catch{try{$proc.Kill($true);[void]$proc.WaitForExit(5000)}catch{};throw}
  if($processSid-ne$script:environment.sid-or$processSession-ne$script:environment.sessionId-or-not(SamePath $processImage $installedExe)){
    try{$proc.Kill($true);[void]$proc.WaitForExit(5000)}catch{}
    throw "$Stage app image, token SID, or session did not match the runner before UI inspection."
  }
  Assert -Name "$Stage process token SID matches runner identity" -Passed ($processSid-eq$script:environment.sid) -Observed $processSid -Expected $script:environment.sid
  Assert -Name "$Stage app runs in the runner process session" -Passed ($processSession-eq$script:environment.sessionId) -Observed $processSession -Expected $script:environment.sessionId
  try{[void]$proc.WaitForInputIdle(10000)}catch{}
  $hwnd=[IntPtr]::Zero;$windowPid=[uint32]0;$until=[DateTime]::UtcNow.AddSeconds(20)
  do{$candidate=[EbrAcceptanceWindowProbe]::FindWindow('EyeBreakReminder.Native',$null)
    if($candidate-ne[IntPtr]::Zero){[void][EbrAcceptanceWindowProbe]::GetWindowThreadProcessId($candidate,[ref]$windowPid);if([int]$windowPid-eq$id){$hwnd=$candidate;break}}
    if($proc.HasExited){break};Start-Sleep -Milliseconds 250
  }while([DateTime]::UtcNow-lt$until)
  if($hwnd -eq [IntPtr]::Zero){
    $proc.Refresh()
    $candidate=$proc.MainWindowHandle

    if($candidate -ne [IntPtr]::Zero){
      [uint32]$candidatePid=0
      [void][EbrAcceptanceWindowProbe]::GetWindowThreadProcessId(
        $candidate,[ref]$candidatePid
      )

      $classBuffer=[Text.StringBuilder]::new(256)
      $classLength=[EbrAcceptanceWindowProbe]::GetClassName(
        $candidate,$classBuffer,$classBuffer.Capacity
      )

      $titleBuffer=[Text.StringBuilder]::new(512)
      [void][EbrAcceptanceWindowProbe]::GetWindowText(
        $candidate,$titleBuffer,$titleBuffer.Capacity
      )

      $candidateVisible=[EbrAcceptanceWindowProbe]::IsWindowVisible($candidate)

      $accepted=(
        $classLength -gt 0 -and
        $classBuffer.ToString() -ceq 'EyeBreakReminder.Native' -and
        [int]$candidatePid -eq $id
      )

      $candidateEvidence=[ordered]@{
        handle=('0x{0:X}' -f $candidate.ToInt64())
        pid=$candidatePid
        expectedPid=$id
        class=$classBuffer.ToString()
        title=$titleBuffer.ToString()
        visible=$candidateVisible
        accepted=$accepted
      }

      Write-Host (
        'WINDOW_CANDIDATE: ' +
        (ConvertTo-Json -InputObject $candidateEvidence -Compress)
      )

      if($accepted){
        $hwnd=$candidate
        $windowPid=$candidatePid
      }
    }
  }
  $proc.Refresh();$alive=-not$proc.HasExited;$path=$processImage
  if($hwnd -eq [IntPtr]::Zero){
    $windowDiagnostics=[ordered]@{
      stage=$Stage
      processId=$id
      processSession=$processSession
      runnerSession=$script:environment.sessionId
      userInteractive=[Environment]::UserInteractive
      sessionName=$env:SESSIONNAME
      processMainWindowHandle=$null
      processMainWindowTitle=$null
      windows=[ordered]@{}
    }

    try{
      $proc.Refresh()
      $windowDiagnostics.processMainWindowHandle=('0x{0:X}' -f $proc.MainWindowHandle.ToInt64())
      $windowDiagnostics.processMainWindowTitle=$proc.MainWindowTitle
    }catch{
      $windowDiagnostics.processProbeError=$_.Exception.Message
    }

    $windowSpecs=@(
      @{name='main';class='EyeBreakReminder.Native';title=$null}
      @{name='tray';class='EyeBreakReminder.TrayMenu';title=$null}
      @{name='startupDialog';class='#32770';title='Eye Break Reminder'}
      @{name='titleOnly';class=$null;title='Eye Break Reminder'}
    )

    foreach($spec in $windowSpecs){
      $foundWindow=[EbrAcceptanceWindowProbe]::FindWindow(
        $spec.class,
        $spec.title
      )

      $owner=[uint32]0
      $caption=''
      $visible=$false

      if($foundWindow -ne [IntPtr]::Zero){
        [void][EbrAcceptanceWindowProbe]::GetWindowThreadProcessId(
          $foundWindow,
          [ref]$owner
        )

        $buffer=[Text.StringBuilder]::new(512)
        [void][EbrAcceptanceWindowProbe]::GetWindowText(
          $foundWindow,
          $buffer,
          $buffer.Capacity
        )

        $caption=$buffer.ToString()
        $visible=[EbrAcceptanceWindowProbe]::IsWindowVisible($foundWindow)
      }

      $windowDiagnostics.windows[$spec.name]=[ordered]@{
        handle=('0x{0:X}' -f $foundWindow.ToInt64())
        ownerPid=$owner
        belongsToApp=([int]$owner -eq $id)
        visible=$visible
        title=$caption
      }
    }

    Write-Host (
      'WINDOW_DIAGNOSTIC: ' +
      (ConvertTo-Json -InputObject $windowDiagnostics -Depth 7 -Compress)
    )
  }
  Assert -Name "$Stage process is running from installed path" -Passed ($alive-and(SamePath ([string]$path) $installedExe)) -Observed ([ordered]@{pid=$id;session=$proc.SessionId;path=$path;alive=$alive}) -Expected ([ordered]@{alive=$true;path=$installedExe})
  Assert -Name "$Stage creates native main window for its process" -Passed ($hwnd-ne[IntPtr]::Zero-and[int]$windowPid-eq$id) -Observed ([ordered]@{hwnd=('0x{0:X}'-f$hwnd.ToInt64());pid=$windowPid}) -Expected ([ordered]@{class='EyeBreakReminder.Native';pid=$id})
  $visible=$false;$title=''
  if($hwnd-ne[IntPtr]::Zero){$visible=[EbrAcceptanceWindowProbe]::IsWindowVisible($hwnd);$text=[Text.StringBuilder]::new(512);[void][EbrAcceptanceWindowProbe]::GetWindowText($hwnd,$text,$text.Capacity);$title=$text.ToString()}
  Assert -Name "$Stage main window has the visible style in its runner session" -Passed $visible -Observed ([ordered]@{windowVisibleStyle=$visible;title=$title;session=$proc.SessionId}) -Expected $true
  Assert -Name "$Stage main window title" -Passed ($title-ceq'Eye Break Reminder') -Observed $title -Expected 'Eye Break Reminder'
  if($Stage-like'*closed-schedule*'){
    UiExpectedClosedSchedule $hwnd;UiHistoryCount $hwnd 2 $Stage
  }elseif($Stage-like'fresh v1.1.0*'){
    UiExpectText $hwnd 41 'fresh timer state' 'Running';UiExpectText $hwnd 42 'fresh timer caption' 'Next eye break'
    if($null-eq$script:freshTimerAnchor){$script:freshTimerAnchor=$started}
    $freshCountdown=UiText $hwnd 40 'fresh timer countdown';$freshExpected=1200.0-([DateTime]::UtcNow-$script:freshTimerAnchor).TotalSeconds
    AssertCountdownNear "$Stage fresh timer matches the 20-minute launch checkpoint" $freshCountdown $freshExpected 5
    UiExpectedDefaults $hwnd $true $true;UiHistoryCount $hwnd 0 $Stage
  }else{
    UiExpectText $hwnd 41 'restored timer state' 'Running';UiExpectText $hwnd 42 'restored timer caption' 'Next eye break'
    $restoredCountdown=UiText $hwnd 40 'restored timer countdown';$restoredExpected=1190.0-([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()-(SeedEpoch))
    AssertCountdownNear "$Stage resumed timer matches its seeded checkpoint minus elapsed time" $restoredCountdown $restoredExpected 5
    UiExpectedDefaults $hwnd $false ($Version-eq'1.1.0');UiHistoryCount $hwnd 2 $Stage
  }
  Start-Sleep -Seconds 3
  if($hwnd-ne[IntPtr]::Zero){$msg=[EbrAcceptanceWindowProbe]::RegisterWindowMessage('EyeBreakReminder.Exit.Native.1');$result=[IntPtr]::Zero;[void][EbrAcceptanceWindowProbe]::SendMessageTimeout($hwnd,$msg,[IntPtr]::Zero,[IntPtr]::Zero,2,3000,[ref]$result)}
  $normal=$proc.WaitForExit(15000)
  if(-not$normal-and-not$proc.HasExited){try{[void]$proc.CloseMainWindow();$normal=$proc.WaitForExit(5000)}catch{}}
  if(-not$normal-and-not$proc.HasExited){try{$proc.Kill($true);[void]$proc.WaitForExit(5000)}catch{}}
  $code=if($proc.HasExited){$proc.ExitCode}else{$null};$session=$null;try{$session=$proc.SessionId}catch{}
  $entry=[ordered]@{version=$Version;stage=$Stage;path=$installedExe;actualProcessImage=$processImage;pid=$id;processTokenSid=$processSid;sessionId=$session;startedUtc=$started.ToString('o');windowObserved=($hwnd-ne[IntPtr]::Zero);windowVisible=$visible;windowTitle=$title;normalExit=$normal;exitCode=$code}
  $script:appLaunches.Add($entry);Write-Host ("APP: "+(ConvertTo-Json $entry -Compress))
  Assert -Name "$Stage normal app shutdown" -Passed ($normal-and$code-eq 0) -Observed ([ordered]@{normalExit=$normal;exitCode=$code}) -Expected ([ordered]@{normalExit=$true;exitCode=0})
  $proc.Dispose();$script:activeAppPid=$null;NoEyeBreak "$Stage shutdown"
}
function DownloadOfficial{
  $token=$env:GITHUB_TOKEN;$repo=$env:GITHUB_REPOSITORY
  if([string]::IsNullOrWhiteSpace($token)-or[string]::IsNullOrWhiteSpace($repo)){throw 'Official baseline download needs repository token and name.'}
  if($repo-notmatch'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'){throw 'Repository name is not a valid owner/repository pair.'}
  $headers=@{Accept='application/vnd.github+json';Authorization="Bearer $token";'X-GitHub-Api-Version'='2022-11-28';'User-Agent'='EyeBreakReminder-InstallerAcceptance'}
  $api='https://api.github.com'
  $repoInfo=Invoke-RestMethod -Uri "$api/repos/$repo" -Headers $headers -TimeoutSec 30
  $release=Invoke-RestMethod -Uri "$api/repos/$repo/releases/tags/v1.0.6" -Headers $headers -TimeoutSec 30
  if($release.tag_name-ne'v1.0.6'-or$release.draft-or$release.prerelease){throw 'Baseline is not the official stable v1.0.6 release.'}
  $assets=@($release.assets|Where-Object{$_.name-eq'EyeBreakReminder-Setup-x64.exe'})
  if($assets.Count-ne 1){throw "Expected one official v1.0.6 setup asset; found $($assets.Count)."};$asset=$assets[0]
  $assetId=[string]$asset.id
  if($assetId-notmatch'^\d+$'){throw 'Release API returned an invalid setup asset ID.'}
  try{$assetUri=[Uri]::new([string]$asset.url,[UriKind]::Absolute)}catch{throw 'Release API returned an invalid setup asset URL.'}
  $expectedAssetPath="/repos/$repo/releases/assets/$assetId"
  $assetUrlAllowed=($assetUri.Scheme-eq'https'-and$assetUri.Host-ieq'api.github.com'-and$assetUri.Port-eq443-and$assetUri.AbsolutePath-ieq$expectedAssetPath-and[string]::IsNullOrEmpty($assetUri.Query)-and[string]::IsNullOrEmpty($assetUri.Fragment)-and[string]::IsNullOrEmpty($assetUri.UserInfo))
  Assert -Name 'official asset URL is the exact GitHub API release asset endpoint' -Passed $assetUrlAllowed -Observed ([ordered]@{scheme=$assetUri.Scheme;host=$assetUri.Host;path=$assetUri.AbsolutePath;assetId=$assetId}) -Expected ([ordered]@{scheme='https';host='api.github.com';path=$expectedAssetPath;assetId=$assetId})
  if($asset.digest-and$asset.digest-ne"sha256:$expectedOfficialSetupSha256"){throw 'Release API asset digest mismatch.'}
  Invoke-WebRequest -Uri $assetUri.AbsoluteUri -Headers @{Accept='application/octet-stream';Authorization="Bearer $token";'X-GitHub-Api-Version'='2022-11-28';'User-Agent'='EyeBreakReminder-InstallerAcceptance'} -OutFile $setupPath -TimeoutSec 90
  $sha=Hash $setupPath;Assert -Name 'official setup SHA-256' -Passed ($sha-eq$expectedOfficialSetupSha256) -Observed $sha -Expected $expectedOfficialSetupSha256
  $version=FileVersion $setupPath;Assert -Name 'official setup file version' -Passed ($version.FileVersion-eq'1.0.6.0') -Observed $version.FileVersion -Expected '1.0.6.0'
  $pe=PeInfo $setupPath;Assert -Name 'official setup PE format' -Passed ($pe.machine-eq'0x014C'-and$pe.magic-eq'0x010B') -Observed $pe -Expected @{machine='0x014C';magic='0x010B'}
  $baseline=[ordered]@{repository=$repo;repositoryPrivate=[bool]$repoInfo.private;releaseTag=$release.tag_name;releasePublishedAt=$release.published_at;asset=$asset.name;assetId=[string]$asset.id;setupSha256=$sha;setupFileVersion=$version.FileVersion;setupPath=$setupPath;downloadedAtUtc=[DateTime]::UtcNow.ToString('o')}
  [IO.File]::WriteAllText($baselinePath,(ConvertTo-Json $baseline -Depth 6),[Text.UTF8Encoding]::new($false))
  Write-Host ("OFFICIAL BASELINE: "+(ConvertTo-Json $baseline -Compress))
  $headers.Clear();$token=$null;Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue;Remove-Item Env:GITHUB_REPOSITORY -ErrorAction SilentlyContinue
}
function EnvironmentEvidence{
  $os=Get-CimInstance Win32_OperatingSystem;$cs=Get-CimInstance Win32_ComputerSystem
  $identity=[Security.Principal.WindowsIdentity]::GetCurrent();$principal=[Security.Principal.WindowsPrincipal]::new($identity);$sid=$identity.User.Value
  $profile=[Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile);$profileEnv=$env:USERPROFILE;$local=[Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
  $profileKey="Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
  $profileImage=[Environment]::ExpandEnvironmentVariables([string](Get-ItemPropertyValue -LiteralPath $profileKey -Name ProfileImagePath))
  $uac=Get-ItemPropertyValue -LiteralPath 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name EnableLUA -ErrorAction SilentlyContinue
  $adminPrompt=Get-ItemPropertyValue -LiteralPath 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name ConsentPromptBehaviorAdmin -ErrorAction Stop
  $script:environment=[ordered]@{osCaption=$os.Caption;osVersion=$os.Version;osBuild=[int]$os.BuildNumber;osArchitecture=$os.OSArchitecture;computerName=$cs.Name;processArchitecture=$env:PROCESSOR_ARCHITECTURE;username=$identity.Name;sid=$sid;profilePath=$profile;userProfileEnvironment=$profileEnv;profileListPath=$profileImage;localAppData=$local;administrator=$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator);uacEnableLUA=$uac;uacConsentPromptBehaviorAdmin=$adminPrompt;runValue=(RunValue);sessionId=[Diagnostics.Process]::GetCurrentProcess().SessionId}
  Assert -Name 'Windows Server 2025 image' -Passed ($os.Caption-like'*Windows Server 2025*') -Observed $os.Caption -Expected 'Windows Server 2025'
  Assert -Name 'Windows OS and process are x64' -Passed ([Environment]::Is64BitOperatingSystem-and[Environment]::Is64BitProcess-and$env:PROCESSOR_ARCHITECTURE-eq'AMD64'-and$os.OSArchitecture-like'*64*') -Observed ([ordered]@{os=$os.OSArchitecture;process=$env:PROCESSOR_ARCHITECTURE;process64=[Environment]::Is64BitProcess}) -Expected 'x64'
  Assert -Name 'Windows build meets application gate' -Passed ([int]$os.BuildNumber-ge 22000) -Observed ([int]$os.BuildNumber) -Expected '>=22000'
  Assert -Name 'ProfileList path belongs to current process SID' -Passed ((Test-Path -LiteralPath $profile -PathType Container)-and(SamePath $profile $profileImage)) -Observed ([ordered]@{sid=$sid;profile=$profile;profileList=$profileImage}) -Expected 'same real profile path'
  Assert -Name 'USERPROFILE matches the current token profile' -Passed (SamePath $profile $profileEnv) -Observed ([ordered]@{specialFolder=$profile;environment=$profileEnv}) -Expected 'same real profile path'
  $hku="Registry::HKEY_USERS\$sid";Assert -Name 'user hive loaded under process SID' -Passed (Test-Path -LiteralPath $hku -PathType Container) -Observed $hku -Expected 'loaded hive'
  Assert -Name 'LOCALAPPDATA resolves inside runner profile' -Passed ((Test-Path -LiteralPath $local -PathType Container)-and(SamePath $local $env:LOCALAPPDATA)-and(IsDescendantPath $local $profile)) -Observed ([ordered]@{special=$local;env=$env:LOCALAPPDATA;profile=$profile}) -Expected 'profile-backed LocalApplicationData'
  $probeRoot='Registry::HKEY_CURRENT_USER\Software\EyeBreakInstallerAcceptance'
  Assert -Name 'test HKCU probe namespace initially absent' -Passed (-not(Test-Path -LiteralPath $probeRoot)) -Observed (Test-Path -LiteralPath $probeRoot) -Expected $false
  $probeName='Probe-'+[Guid]::NewGuid().ToString('N');$probe="$probeRoot\$probeName"
  New-Item -Path $probe -Force|Out-Null;$marker=[Guid]::NewGuid().ToString('N')
  New-ItemProperty -LiteralPath $probe -Name Marker -Value $marker -PropertyType String -Force|Out-Null
  $sidProbe="Registry::HKEY_USERS\$sid\Software\EyeBreakInstallerAcceptance\$($probeName)"
  $sidMarker=Get-ItemPropertyValue -LiteralPath $sidProbe -Name Marker
  Assert -Name 'HKCU identity resolves to process token SID' -Passed ($sidMarker-eq$marker) -Observed ([ordered]@{sid=$sid;markerMatches=($sidMarker-eq$marker)}) -Expected $true
  Remove-Item -LiteralPath $probe -Recurse -Force;Remove-Item -LiteralPath $probeRoot -Recurse -Force
  Assert -Name 'HKCU probe is removed' -Passed (-not(Test-Path -LiteralPath $probeRoot)) -Observed (Test-Path -LiteralPath $probeRoot) -Expected $false
  Assert -Name 'GITHUB_TOKEN absent from installer step' -Passed (-not(Test-Path Env:GITHUB_TOKEN)) -Observed (Test-Path Env:GITHUB_TOKEN) -Expected $false
  Assert -Name 'hosted runner administrator token and no-prompt elevation policy are recorded' -Passed ($null-ne$sid-and$script:environment.administrator-and$uac-in @(0,1)-and$adminPrompt-eq 0) -Observed ([ordered]@{user=$identity.Name;sid=$sid;administrator=$script:environment.administrator;enableLUA=$uac;consentPromptBehaviorAdmin=$adminPrompt}) -Expected ([ordered]@{administrator=$true;enableLUA='record actual 0 or 1';consentPromptBehaviorAdmin=0})
  Assert -Name 'NSIS uninstaller path argument is unambiguous' -Passed (-not $installPath.Contains(' ')) -Observed $installPath -Expected 'path with no spaces for /_?= directory argument'
  foreach($path in @($profile,$local,$installPath,$appDataPath,$startMenuFolder,$startMenuShortcut)){CheckNoReparse $path 'runner user path'}
  Assert -Name 'pre-existing app HKCU registration absent' -Passed (-not(Test-Path -LiteralPath $appReg)-and-not(Test-Path -LiteralPath $uninstallReg)) -Observed ([ordered]@{app=(Test-Path -LiteralPath $appReg);uninstall=(Test-Path -LiteralPath $uninstallReg)}) -Expected 'both absent'
  foreach($pair in @(@($startMenuShortcut,'user Start Menu shortcut'),@($startMenuFolder,'user Start Menu folder'),@($desktopShortcut,'user Desktop'),@($commonMenuShortcut,'common Start Menu'),@($commonDesktopShortcut,'common Desktop'))){Assert -Name "pre-existing $($pair[1]) absent" -Passed (-not(Test-Path -LiteralPath $pair[0])) -Observed (Test-Path -LiteralPath $pair[0]) -Expected $false}
  $script:expectedRunValue=$script:environment.runValue
  Assert -Name 'pre-existing app startup Run value absent' -Passed (-not$script:environment.runValue.present) -Observed $script:environment.runValue -Expected ([ordered]@{present=$false;kind=$null;value=$null})
  Assert -Name 'per-user install path initially absent' -Passed (-not(Test-Path -LiteralPath $installPath)) -Observed (Test-Path -LiteralPath $installPath) -Expected $false
  Assert -Name 'app data initially absent' -Passed (-not(Test-Path -LiteralPath $appDataPath)) -Observed (Test-Path -LiteralPath $appDataPath) -Expected $false
  NoMachineAppDirectories 'runner preflight';NoHklm 'runner preflight';CheckNoDuplicate 'runner preflight';NoEyeBreak 'runner preflight'
  $script:environment.repository=$env:GITHUB_REPOSITORY;$script:environment.head=(git rev-parse HEAD).Trim();$script:environment.parent=(git rev-parse 'HEAD^').Trim();$script:environment.sourceBase=$expectedBase
  & git merge-base --is-ancestor $expectedBase $script:environment.head;$sourceBaseIsAncestor=$LASTEXITCODE-eq 0
  Assert -Name 'intended feature source is an ancestor of acceptance commit' -Passed $sourceBaseIsAncestor -Observed ([ordered]@{sourceBase=$expectedBase;head=$script:environment.head}) -Expected 'source base is an ancestor'
  Assert -Name 'workflow branch is dedicated acceptance branch' -Passed ($env:GITHUB_REF_NAME-eq'test/v110-release-acceptance') -Observed $env:GITHUB_REF_NAME -Expected 'test/v110-release-acceptance'
  Add-WindowProbe
}
function CandidateIdentity{
  $setup=Join-Path (Get-Location) 'release\EyeBreakReminder-Setup-x64.exe';$exe=Join-Path (Get-Location) 'release\EyeBreakReminder.exe'
  if(-not(Test-Path -LiteralPath $setup -PathType Leaf)-or-not(Test-Path -LiteralPath $exe -PathType Leaf)){throw 'Candidate binaries missing.'}
  $sv=FileVersion $setup;$spe=PeInfo $setup;$app=AppIdentity $exe '1.1.0' $null
  Assert -Name 'test-only installer metadata is v1.1.0' -Passed ($sv.FileVersion-eq'1.1.0.0'-and$sv.ProductVersion-like'1.1.0*') -Observed ([ordered]@{fileVersion=$sv.FileVersion;productVersion=$sv.ProductVersion}) -Expected '1.1.0.0 / 1.1.0'
  Assert -Name 'candidate is an NSIS x86 bootstrap with x64 app' -Passed ($spe.machine-eq'0x014C'-and$spe.magic-eq'0x010B') -Observed $spe -Expected @{machine='0x014C';magic='0x010B'}
  $sh=Hash $setup;$ah=Hash $exe;Assert -Name 'candidate installer and executable SHA-256 identities' -Passed ($sh-match'^[A-F0-9]{64}$'-and$ah-match'^[A-F0-9]{64}$') -Observed ([ordered]@{setup=$sh;application=$ah}) -Expected 'two SHA-256 hashes'
  $script:artifacts.candidate=[ordered]@{sourceBaseCommit=$script:environment.sourceBase;candidateCommit=$script:environment.head;candidateParentCommit=$script:environment.parent;version='1.1.0';setup=$setup;setupSha256=$sh;setupFileVersion=$sv.FileVersion;setupProductVersion=$sv.ProductVersion;application=$exe;applicationSha256=$ah;applicationFileVersion=$app.fileVersion}
  $ah
}
function SaveManifest{
  $result=[ordered]@{schemaVersion=1;status=$script:status;failure=$script:failure;generatedAtUtc=[DateTime]::UtcNow.ToString('o');runner=$script:environment;artifacts=$script:artifacts;scenarios=$script:scenarios;assertions=@($script:checks);installerProcesses=@($script:installerProcesses);applicationLaunches=@($script:appLaunches);dataSnapshots=$script:dataSnapshots
    limitations=@('Windows Server 2025 is not Windows 11.','No separate standard account was created; standard-token behavior is not certified.','The NSIS run uses /S; native process/window/control-message checks are not visual wizard or accessibility acceptance.','No screenshot, Narrator, or Shell notification claim is made.','The hosted runner process token is Administrator; EnableLUA and ConsentPromptBehaviorAdmin are recorded without changing them, and admin prompt behavior is asserted to be 0. HKCU and no-HKLM scope are asserted; standard-user token and interactive UAC behavior are not certified.')}
  [IO.File]::WriteAllText($manifestPath,(ConvertTo-Json -InputObject $result -Depth 12),[Text.UTF8Encoding]::new($false))
}
function AcceptanceMain{
  Begin-Scenario 'environment';EnvironmentEvidence;End-Scenario 'environment'
  if(-not(Test-Path -LiteralPath $baselinePath -PathType Leaf)-or-not(Test-Path -LiteralPath $setupPath -PathType Leaf)){throw 'Verified official baseline is missing.'}
  $base=Get-Content -LiteralPath $baselinePath -Raw|ConvertFrom-Json;$officialHash=Hash $setupPath
  Assert -Name 'downloaded v1.0.6 setup matches baseline manifest' -Passed ($officialHash-eq$expectedOfficialSetupSha256-and$base.setupSha256-eq$expectedOfficialSetupSha256) -Observed $officialHash -Expected $expectedOfficialSetupSha256
  $script:scenarios.official_v106_artifact='PASS';$script:artifacts.officialV106=$base
  $script:environment.repositoryPrivate=[bool]$base.repositoryPrivate;$script:environment.repositoryVisibility=if($base.repositoryPrivate){'private'}else{'public'}
  $script:environment.buildLog=Join-Path $evidenceDir 'build.log';$script:environment.downloadLog=Join-Path $evidenceDir 'download.log'
  $candidateHash=CandidateIdentity;Fixture @('schedule-core')

  Begin-Scenario 'fresh_v106_install';Install 'official v1.0.6 setup /S' $setupPath
  $v106=CheckInstall '1.0.6' 'fresh v1.0.6' $expectedOfficialAppSha256
  if($null -eq $v106 -or [string]::IsNullOrWhiteSpace([string]$v106.sha256)){
    throw 'Official v1.0.6 installed executable hash was not returned.'
  }
  if($script:artifacts.officialV106 -isnot [pscustomobject]){
    throw 'Official v1.0.6 artifact manifest is not a PSCustomObject.'
  }
  Add-Member -InputObject $script:artifacts.officialV106 -MemberType NoteProperty -Name installedAppSha256 -Value $v106.sha256 -ErrorAction Stop
  Assert -Name 'official v1.0.6 installed hash recorded' -Passed ($script:artifacts.officialV106.installedAppSha256 -ceq $v106.sha256) -Observed $script:artifacts.officialV106.installedAppSha256 -Expected $v106.sha256
  Assert -Name 'fresh setup did not create app data before app launch' -Passed (-not(Test-Path -LiteralPath $appDataPath)) -Observed (Test-Path -LiteralPath $appDataPath) -Expected $false
  End-Scenario 'fresh_v106_install'

  Begin-Scenario 'v106_app_and_user_data';Fixture @('seed','representative',$appDataPath)
  $sentinel=Join-Path $appDataPath 'acceptance-unrelated-sentinel.txt'
  CheckNoReparse $appDataPath 'v1.0.6 application data' -Contents
  Fixture @('validate','representative',$appDataPath);$sentinelHash=Hash $sentinel;$v106BeforeApp=DataHashes 'v106-before-app'
  AppSmoke '1.0.6' 'v1.0.6 representative data';Fixture @('validate','resumed',$appDataPath)
  $baseline=DataHashes 'v106-after-normal-exit'
  Assert -Name 'v1.0.6 app preserves history bytes' -Passed ($baseline['history.dat']-eq$v106BeforeApp['history.dat']) -Observed $baseline['history.dat'] -Expected $v106BeforeApp['history.dat']
  Assert -Name 'v1.0.6 app preserved unrelated sentinel' -Passed ($baseline['acceptance-unrelated-sentinel.txt']-eq$sentinelHash) -Observed $baseline['acceptance-unrelated-sentinel.txt'] -Expected $sentinelHash
  End-Scenario 'v106_app_and_user_data'

  $candidateSetup=Join-Path (Get-Location) 'release\EyeBreakReminder-Setup-x64.exe'
  Begin-Scenario 'v106_to_v110_upgrade';Install 'test-only v1.1.0 upgrade /S' $candidateSetup
  [void](CheckInstall '1.1.0' 'v1.0.6 to v1.1.0 upgrade' $candidateHash)
  $upgraded=DataHashes 'after-v110-upgrade'
  foreach($name in @('settings.ini','timer.dat','history.dat','acceptance-unrelated-sentinel.txt')){
    Assert -Name "upgrade preserves $name byte-for-byte" -Passed ($upgraded[$name]-eq$baseline[$name]) -Observed $upgraded[$name] -Expected $baseline[$name]
  }
  AppSmoke '1.1.0' 'upgraded v1.1.0 legacy data restore'
  Fixture @('validate','resumed',$appDataPath)
  $afterUpgradeApp=DataHashes 'after-v110-app-resume'
  Assert -Name 'upgraded app preserved history after resume' -Passed ($afterUpgradeApp['history.dat']-eq$upgraded['history.dat']) -Observed $afterUpgradeApp['history.dat'] -Expected $upgraded['history.dat']
  Assert -Name 'upgraded app preserved unrelated sentinel after resume' -Passed ($afterUpgradeApp['acceptance-unrelated-sentinel.txt']-eq$sentinelHash) -Observed $afterUpgradeApp['acceptance-unrelated-sentinel.txt'] -Expected $sentinelHash
  End-Scenario 'v106_to_v110_upgrade'

  Begin-Scenario 'operating_schedule_runtime';Fixture @('seed','schedule-hold',$appDataPath);CheckNoReparse $appDataPath 'schedule test data' -Contents;Fixture @('validate','schedule-input',$appDataPath)
  AppSmoke '1.1.0' 'v1.1.0 closed-schedule runtime';Fixture @('validate','schedule-hold',$appDataPath)
  $scheduleData=DataHashes 'after-schedule-runtime'
  Assert -Name 'schedule runtime preserved sentinel' -Passed ($scheduleData['acceptance-unrelated-sentinel.txt']-eq$sentinelHash) -Observed $scheduleData['acceptance-unrelated-sentinel.txt'] -Expected $sentinelHash
  End-Scenario 'operating_schedule_runtime'

  Begin-Scenario 'v110_uninstall';TestOwnedStartupValue;$beforeUninstall=DataHashes 'before-v110-uninstall'
  # NSIS _?= disables its own temporary-copy step. Execute our verified
  # runner-owned copy so the installed Uninstall.exe can be deleted.
  if($env:GITHUB_ACTIONS -ne 'true'){
    throw 'Uninstaller acceptance must run only in GitHub Actions'
  }
  if([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)){
    throw 'GitHub runner temporary directory is missing'
  }

  $runnerTemp=FullPath $env:RUNNER_TEMP
  Assert -Name 'uninstaller staging root exists' `
    -Passed (Test-Path -LiteralPath $runnerTemp -PathType Container) `
    -Observed $runnerTemp -Expected 'existing runner temporary directory'

  $uninstallStage=Join-Path $runnerTemp (
    'EyeBreakAcceptanceUninstall-' + [guid]::NewGuid().ToString('N')
  )
  $uninstallStage=FullPath $uninstallStage

  Assert -Name 'uninstaller staging directory is inside runner temp' `
    -Passed (IsDescendantPath $uninstallStage $runnerTemp) `
    -Observed $uninstallStage -Expected $runnerTemp

  if(Test-Path -LiteralPath $uninstallStage){
    throw 'Uninstaller staging directory already exists'
  }

  $originalUninstallerHash=Hash $uninstallerExe

  try{
    [void](New-Item -ItemType Directory -Path $uninstallStage -ErrorAction Stop)
    CheckNoReparse $uninstallStage 'uninstaller temporary staging' -Contents

    $copiedUninstaller=Join-Path $uninstallStage 'Uninstall.exe'

    Copy-Item -LiteralPath $uninstallerExe `
      -Destination $copiedUninstaller -ErrorAction Stop

    $copiedHash=Hash $copiedUninstaller

    Assert -Name 'temporary uninstaller is byte-identical to installed uninstaller' `
      -Passed ($copiedHash -eq $originalUninstallerHash) `
      -Observed $copiedHash -Expected $originalUninstallerHash

    [void](RunBounded `
      'v1.1.0 real uninstaller /S (verified temporary copy)' `
      $copiedUninstaller @('/S',"_?=$installPath") 120)
  }
  finally{
    if(Test-Path -LiteralPath $uninstallStage){
      if(-not(IsDescendantPath $uninstallStage $runnerTemp)){
        throw 'Refusing cleanup outside GitHub runner temporary directory'
      }
      Remove-Item -LiteralPath $uninstallStage -Recurse -Force -ErrorAction Stop
    }
  }

  NoEyeBreak 'v1.1.0 uninstall'
  CheckUninstalled 'upgrade uninstall'
  foreach($name in @('settings.ini','history.dat','acceptance-unrelated-sentinel.txt')){
    $p=Join-Path $appDataPath $name;$actual=if(Test-Path -LiteralPath $p -PathType Leaf){Hash $p}else{$null}
    Assert -Name "uninstall retains $name" -Passed ($actual-eq$beforeUninstall[$name]) -Observed $actual -Expected $beforeUninstall[$name]
  }
  $timerPath=Join-Path $appDataPath 'timer.dat';Assert -Name 'uninstall removes timer.dat' -Passed (-not(Test-Path -LiteralPath $timerPath)) -Observed (Test-Path -LiteralPath $timerPath) -Expected $false
  $names=@(Get-ChildItem -LiteralPath $appDataPath -Force -File|ForEach-Object Name|Sort-Object)
  $dirs=@(Get-ChildItem -LiteralPath $appDataPath -Force -Directory|ForEach-Object Name);Assert -Name 'uninstall leaves no test-data subdirectories' -Passed ($dirs.Count-eq 0) -Observed $dirs -Expected @()
  Assert -Name 'uninstall retains only settings/history/sentinel' -Passed ([string]::Join('|',$names)-eq'acceptance-unrelated-sentinel.txt|history.dat|settings.ini') -Observed $names -Expected @('acceptance-unrelated-sentinel.txt','history.dat','settings.ini')
  End-Scenario 'v110_uninstall'

  Begin-Scenario 'fresh_v110_install'
  $expectedData=FullPath (Join-Path $localAppData 'EyeBreakReminder')
  Assert -Name 'data reset scoped to runner app-data path' -Passed ((SamePath $appDataPath $expectedData)-and(IsDescendantPath $appDataPath $localAppData)) -Observed $appDataPath -Expected $expectedData
  foreach($name in @('settings.ini','history.dat','acceptance-unrelated-sentinel.txt')){$p=Join-Path $appDataPath $name;if(Test-Path -LiteralPath $p -PathType Leaf){Remove-Item -LiteralPath $p -Force}}
  $left=@(Get-ChildItem -LiteralPath $appDataPath -Force);Assert -Name 'fresh reset left no unexpected files' -Passed ($left.Count-eq 0) -Observed @($left|ForEach-Object Name) -Expected @()
  Remove-Item -LiteralPath $appDataPath -Force
  Fixture @('seed','stale-timer',$appDataPath);CheckNoReparse $appDataPath 'stale timer fixture' -Contents;$staleTimer=DataHashes 'stale-timer-before-fresh-install'
  Assert -Name 'stale timer fixture has only timer.dat' -Passed ($staleTimer['timer.dat']-and-not$staleTimer['settings.ini']-and-not$staleTimer['history.dat']-and-not$staleTimer['acceptance-unrelated-sentinel.txt']) -Observed $staleTimer -Expected 'only timer.dat present'
  Install 'fresh test-only v1.1.0 setup /S' $candidateSetup
  [void](CheckInstall '1.1.0' 'fresh v1.1.0' $candidateHash)
  CheckNoReparse $appDataPath 'fresh post-install app data' -Contents
  $timerPath=Join-Path $appDataPath 'timer.dat'
  Assert -Name 'fresh installer removes a stale timer checkpoint before app launch' -Passed (-not(Test-Path -LiteralPath $timerPath)) -Observed (Test-Path -LiteralPath $timerPath) -Expected $false
  $prelaunchData=@(Get-ChildItem -LiteralPath $appDataPath -Force);Assert -Name 'fresh installer leaves no stale or unrelated user data' -Passed ($prelaunchData.Count-eq 0) -Observed @($prelaunchData|ForEach-Object Name) -Expected @()
  AppSmoke '1.1.0' 'fresh v1.1.0 normal launch';$freshAnchorEpoch=[DateTimeOffset]::new($script:freshTimerAnchor).ToUnixTimeSeconds();Fixture @('validate','fresh',$appDataPath,[string]$freshAnchorEpoch)
  $fresh=DataHashes 'fresh-v110-after-exit'
  Assert -Name 'fresh app writes settings and timer on exit' -Passed ($fresh['settings.ini']-and$fresh['timer.dat']) -Observed ([ordered]@{settings=$fresh['settings.ini'];timer=$fresh['timer.dat']}) -Expected 'both hashes present'
  AppSmoke '1.1.0' 'fresh v1.1.0 persistence relaunch';Fixture @('validate','fresh',$appDataPath,[string]$freshAnchorEpoch)
  $again=DataHashes 'fresh-v110-after-relaunch'
  Assert -Name 'fresh settings persist across relaunch' -Passed ($again['settings.ini']-eq$fresh['settings.ini']) -Observed $again['settings.ini'] -Expected $fresh['settings.ini']
  Assert -Name 'fresh timer checkpoint updated on relaunch' -Passed ($again['timer.dat']-and$again['timer.dat']-ne$fresh['timer.dat']) -Observed $again['timer.dat'] -Expected 'new running-timer checkpoint hash'
  Assert -Name 'fresh history remains unchanged across relaunch' -Passed ($again['history.dat']-eq$fresh['history.dat']) -Observed $again['history.dat'] -Expected $fresh['history.dat']
  $fresh=$again;End-Scenario 'fresh_v110_install'

  Begin-Scenario 'fresh_v110_uninstall'
  TestForeignStartupValue
  # NSIS _?= disables its own temporary-copy step. Execute our verified
  # runner-owned copy so the installed Uninstall.exe can be deleted.
  if($env:GITHUB_ACTIONS -ne 'true'){
    throw 'Uninstaller acceptance must run only in GitHub Actions'
  }
  if([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)){
    throw 'GitHub runner temporary directory is missing'
  }

  $runnerTemp=FullPath $env:RUNNER_TEMP
  Assert -Name 'uninstaller staging root exists' `
    -Passed (Test-Path -LiteralPath $runnerTemp -PathType Container) `
    -Observed $runnerTemp -Expected 'existing runner temporary directory'

  $uninstallStage=Join-Path $runnerTemp (
    'EyeBreakAcceptanceUninstall-' + [guid]::NewGuid().ToString('N')
  )
  $uninstallStage=FullPath $uninstallStage

  Assert -Name 'uninstaller staging directory is inside runner temp' `
    -Passed (IsDescendantPath $uninstallStage $runnerTemp) `
    -Observed $uninstallStage -Expected $runnerTemp

  if(Test-Path -LiteralPath $uninstallStage){
    throw 'Uninstaller staging directory already exists'
  }

  $originalUninstallerHash=Hash $uninstallerExe

  try{
    [void](New-Item -ItemType Directory -Path $uninstallStage -ErrorAction Stop)
    CheckNoReparse $uninstallStage 'uninstaller temporary staging' -Contents

    $copiedUninstaller=Join-Path $uninstallStage 'Uninstall.exe'

    Copy-Item -LiteralPath $uninstallerExe `
      -Destination $copiedUninstaller -ErrorAction Stop

    $copiedHash=Hash $copiedUninstaller

    Assert -Name 'temporary uninstaller is byte-identical to installed uninstaller' `
      -Passed ($copiedHash -eq $originalUninstallerHash) `
      -Observed $copiedHash -Expected $originalUninstallerHash

    [void](RunBounded `
      'fresh v1.1.0 real uninstaller /S (verified temporary copy)' `
      $copiedUninstaller @('/S',"_?=$installPath") 120)
  }
  finally{
    if(Test-Path -LiteralPath $uninstallStage){
      if(-not(IsDescendantPath $uninstallStage $runnerTemp)){
        throw 'Refusing cleanup outside GitHub runner temporary directory'
      }
      Remove-Item -LiteralPath $uninstallStage -Recurse -Force -ErrorAction Stop
    }
  }

  NoEyeBreak 'fresh uninstall'
  CheckUninstalled 'fresh uninstall'
  ClearForeignStartupValue
  foreach($name in @('settings.ini','history.dat','acceptance-unrelated-sentinel.txt')){
    $p=Join-Path $appDataPath $name;$actual=if(Test-Path -LiteralPath $p -PathType Leaf){Hash $p}else{$null}
    Assert -Name "fresh uninstall retention policy for $name" -Passed ($actual-eq$fresh[$name]) -Observed $actual -Expected $fresh[$name]
  }
  $timerPath=Join-Path $appDataPath 'timer.dat';Assert -Name 'fresh uninstall removes timer.dat' -Passed (-not(Test-Path -LiteralPath $timerPath)) -Observed (Test-Path -LiteralPath $timerPath) -Expected $false
  End-Scenario 'fresh_v110_uninstall'

  Begin-Scenario 'cleanup';NoEyeBreak 'final cleanup'
  Assert -Name 'final install is absent' -Passed (-not(Test-Path -LiteralPath $installPath)) -Observed (Test-Path -LiteralPath $installPath) -Expected $false
  $residue=@(Get-ChildItem -LiteralPath $appDataPath -Force|ForEach-Object Name|Sort-Object)
  $unexpected=@($residue|Where-Object{$_-notin@('settings.ini','history.dat','acceptance-unrelated-sentinel.txt')})
  Assert -Name 'remaining data is only verified test data' -Passed ($unexpected.Count-eq 0) -Observed $residue -Expected 'test settings/history may remain until runner disposal'
  End-Scenario 'cleanup'
}
try {
  Start-Transcript -LiteralPath $transcriptPath -Force|Out-Null
  if($DownloadOfficialOnly){Begin-Scenario 'official_v106_artifact';DownloadOfficial;End-Scenario 'official_v106_artifact'}
  else{AcceptanceMain}
}catch{
  $script:status='FAIL';$script:failure=$_.Exception.Message;if($script:scenario){$script:scenarios[$script:scenario]='FAIL'}
  Write-Host ("ACCEPTANCE FAILURE: "+$script:failure);Write-Host $_.ScriptStackTrace
}finally{
  if(-not$DownloadOfficialOnly-and$script:activeAppPid){
    try{$p=Get-Process -Id $script:activeAppPid -ErrorAction Stop;if($p.Path-and(SamePath $p.Path $installedExe)){
      Add-WindowProbe;$w=[EbrAcceptanceWindowProbe]::FindWindow('EyeBreakReminder.Native',$null)
      if($w-ne[IntPtr]::Zero){$m=[EbrAcceptanceWindowProbe]::RegisterWindowMessage('EyeBreakReminder.Exit.Native.1');$r=[IntPtr]::Zero;[void][EbrAcceptanceWindowProbe]::SendMessageTimeout($w,$m,[IntPtr]::Zero,[IntPtr]::Zero,2,3000,[ref]$r)}
      if(-not$p.WaitForExit(10000)){$p.Kill($true);[void]$p.WaitForExit(5000)}
    }}catch{}
  }
  try{Stop-Transcript|Out-Null}catch{}
  if($DownloadOfficialOnly){
    $base=if(Test-Path -LiteralPath $baselinePath){Get-Content -LiteralPath $baselinePath -Raw|ConvertFrom-Json}else{$null}
    $report=[ordered]@{status=if($script:failure){'FAIL'}else{'PASS'};failure=$script:failure;repository=if($base){$base.repository}else{$env:GITHUB_REPOSITORY};repositoryPrivate=if($base){$base.repositoryPrivate}else{$null};setupSha256=if(Test-Path -LiteralPath $setupPath){Hash $setupPath}else{$null};assertions=@($script:checks);generatedAtUtc=[DateTime]::UtcNow.ToString('o')}
    [IO.File]::WriteAllText((Join-Path $evidenceDir 'download-results.json'),(ConvertTo-Json $report -Depth 8),[Text.UTF8Encoding]::new($false))
    if(-not$script:failure){$script:status='PASS'}
  }else{
    if($script:status-eq'RUNNING'){$script:status='PASS'}
    if($script:status-eq'PASS'-and@($script:scenarios.Values|Where-Object{$_-ne'PASS'}).Count-ne 0){$script:status='FAIL';$script:failure='A required acceptance scenario did not reach PASS.'}
    $manifest=[ordered]@{
      schemaVersion=1;status=$script:status;failure=$script:failure;generatedAtUtc=[DateTime]::UtcNow.ToString('o')
      runner=$script:environment;artifacts=$script:artifacts;scenarios=$script:scenarios;assertions=@($script:checks)
      installerProcesses=@($script:installerProcesses);applicationLaunches=@($script:appLaunches);dataSnapshots=$script:dataSnapshots
      limitations=@('Windows Server 2025 is not Windows 11.','No separate standard account was created; this result does not certify standard-token behavior.','The NSIS run uses /S; native process/window/control-message checks are not visual wizard or accessibility acceptance.','No screenshot, Narrator, or Shell notification claim is made.','The hosted runner process token is Administrator; EnableLUA and ConsentPromptBehaviorAdmin are recorded without changing them, and admin prompt behavior is asserted to be 0. HKCU and no-HKLM scope are asserted; standard-user token and interactive UAC behavior are not certified.')
    }
    [IO.File]::WriteAllText($manifestPath,(ConvertTo-Json $manifest -Depth 12),[Text.UTF8Encoding]::new($false))
  }
}
if($script:status-ne'PASS'){exit 1};exit 0
