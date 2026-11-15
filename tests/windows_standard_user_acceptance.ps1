param(
  [Parameter(Mandatory)][string]$InstallerPath,
  [Parameter(Mandatory)][string]$ExecutablePath,
  [Parameter(Mandatory)][string]$EvidenceDirectory,
  [switch]$Child,
  [string]$ChildResultPath
)
$ErrorActionPreference='Stop'

function Save-StandardUserResult([string]$Path,$Result){
  $directory=Split-Path -Parent $Path
  if(-not(Test-Path -LiteralPath $directory)){[void][IO.Directory]::CreateDirectory($directory)}
  $Result|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $Path -Encoding utf8
}

if($Child){
  $events=[System.Collections.Generic.List[object]]::new();$appProcess=$null;$status='FAIL';$failure=''
  function Find-StandardUserWizardWindow([int]$ProcessId){
    try{$tops=[System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children,[System.Windows.Automation.Condition]::TrueCondition);foreach($top in $tops){try{if($top.Current.ProcessId-eq$ProcessId){return $top}}catch{}}}catch{}
    return $null
  }
  function Invoke-StandardUserWizard([string]$Path,[string]$Kind,[Diagnostics.Process]$ExistingProcess=$null){
    try{$started=if($ExistingProcess){$ExistingProcess}else{Start-Process -FilePath $Path -PassThru}}catch{return [pscustomobject]@{Status='NOT TESTED';Kind=$Kind;Reason="Could not launch the interactive wizard: $($_.Exception.Message)"}}
    $watch=[Diagnostics.Stopwatch]::StartNew();$root=$null;$lastSignature='';$pageNames=[System.Collections.Generic.List[string]]::new();$finishCheckbox=$null
    try{Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop;Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop;Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop}catch{Stop-Process -Id $started.Id -Force -ErrorAction SilentlyContinue;return [pscustomobject]@{Status='NOT TESTED';Kind=$Kind;Reason="UI Automation or keyboard assemblies are unavailable: $($_.Exception.Message)"}}
    while($watch.Elapsed.TotalSeconds-lt180){
      $started.Refresh();if($started.HasExited){if($started.ExitCode-eq0){return [pscustomobject]@{Status='NOT TESTED';Kind=$Kind;Reason='Installer exited without exposing a wizard window.';ExitCode=$started.ExitCode}};return [pscustomobject]@{Status='FAIL';Kind=$Kind;Reason='Installer exited before the wizard completed.';ExitCode=$started.ExitCode}}
      $root=Find-StandardUserWizardWindow $started.Id
      if(-not$root){Start-Sleep -Milliseconds 150;continue}
      $elements=@($root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition));$named=@(foreach($element in $elements){try{$name=[string]$element.Current.Name;if($name){$name}}catch{}});$signature=$named-join'|'
      $buttons=@($elements|Where-Object{try{$_.Current.ControlType-eq[System.Windows.Automation.ControlType]::Button-and$_.Current.IsEnabled-and-not$_.Current.IsOffscreen}catch{$false}})
      $finish=@($buttons|Where-Object{try{$_.Current.Name-match'(?i)^\s*&?(Finish|Close)\s*$'}catch{$false}}|Select-Object -First 1)
      if($finish.Count){
        $finishCheckbox=@($elements|Where-Object{try{$_.Current.ControlType-eq[System.Windows.Automation.ControlType]::CheckBox-and$_.Current.Name-match'(?i)Open Eye Break Reminder'}catch{$false}}|Select-Object -First 1)
        $checkboxState='NOT EXPOSED'
        if($finishCheckbox.Count){try{$toggle=$finishCheckbox[0].GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern);if($toggle.Current.ToggleState-eq[System.Windows.Automation.ToggleState]::On){$toggle.Toggle()};$checkboxState=$toggle.Current.ToggleState.ToString();if($checkboxState-ne'Off'){return [pscustomobject]@{Status='FAIL';Kind=$Kind;Reason='The finish-page Run checkbox remained checked after the harness cleared it.';FinishCheckbox=$checkboxState;Pages=$pageNames.ToArray()}}}catch{$checkboxState='UIA state unavailable'}}
        try{$finish[0].GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()}catch{try{$finish[0].SetFocus();[System.Windows.Forms.SendKeys]::SendWait('{ENTER}')}catch{Stop-Process -Id $started.Id -Force -ErrorAction SilentlyContinue;return [pscustomobject]@{Status='NOT TESTED';Kind=$Kind;Reason="UI Automation could not activate the Finish button: $($_.Exception.Message)";FinishCheckbox=$checkboxState;Pages=$pageNames.ToArray()}}}
        if(-not$started.WaitForExit(30000)){Stop-Process -Id $started.Id -Force -ErrorAction SilentlyContinue;return [pscustomobject]@{Status='FAIL';Kind=$Kind;Reason='Wizard remained running 30 seconds after Finish.';FinishCheckbox=$checkboxState;Pages=$pageNames.ToArray()}}
        if($started.ExitCode-ne0){return [pscustomobject]@{Status='FAIL';Kind=$Kind;Reason="Wizard returned exit code $($started.ExitCode).";ExitCode=$started.ExitCode;FinishCheckbox=$checkboxState;Pages=$pageNames.ToArray()}}
        return [pscustomobject]@{Status='PASS';Kind=$Kind;ExitCode=$started.ExitCode;FinishCheckbox=$checkboxState;Pages=$pageNames.ToArray();DurationSeconds=[Math]::Round($watch.Elapsed.TotalSeconds,1)}
      }
      if($signature-ne$lastSignature){
        $next=@($buttons|Where-Object{try{$_.Current.Name-match'(?i)^\s*&?(Next|Install|Uninstall|Remove)\s*>?\s*$'}catch{$false}}|Select-Object -First 1)
        if($next.Count){$buttonName=[string]$next[0].Current.Name;$pageNames.Add($buttonName);try{$next[0].GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()}catch{try{$next[0].SetFocus();[System.Windows.Forms.SendKeys]::SendWait('{ENTER}')}catch{Stop-Process -Id $started.Id -Force -ErrorAction SilentlyContinue;return [pscustomobject]@{Status='NOT TESTED';Kind=$Kind;Reason="UI Automation could not activate wizard navigation: $($_.Exception.Message)";Pages=$pageNames.ToArray()}}};$lastSignature=$signature}
      }
      Start-Sleep -Milliseconds 150
    }
    Stop-Process -Id $started.Id -Force -ErrorAction SilentlyContinue
    [pscustomobject]@{Status='NOT TESTED';Kind=$Kind;Reason='Wizard did not expose a controllable finish page within three minutes.';Pages=$pageNames.ToArray()}
  }
  function Invoke-SettingsAppsUninstall([string]$UninstallerPath){
    Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop;Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop;Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop;Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    $settingsProcess=$null;$settingsRoot=$null;$names=[System.Collections.Generic.List[string]]::new();$screenshot=$null
    try{
    try{$settingsProcess=Start-Process -FilePath 'ms-settings:appsfeatures' -PassThru}catch{return [pscustomobject]@{Status='NOT TESTED';Reason="Windows Settings Apps page could not be opened: $($_.Exception.Message)"}}
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while($watch.Elapsed.TotalSeconds-lt35-and-not$settingsRoot){
      try{
        $tops=[System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children,[System.Windows.Automation.Condition]::TrueCondition)
        foreach($top in $tops){
          try{$elements=@($top.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition));$currentNames=@(foreach($element in $elements){try{if($element.Current.Name){[string]$element.Current.Name}}catch{}});if(($currentNames-join'|')-match'(?i)Installed apps|Apps & features|App & features'){$settingsRoot=$top;$names.AddRange([string[]]$currentNames);break}}catch{}
        }
      }catch{}
      if(-not$settingsRoot){Start-Sleep -Milliseconds 250}
    }
    if(-not$settingsRoot){return [pscustomobject]@{Status='NOT TESTED';Reason='The disposable Windows session did not expose the Installed apps page through UI Automation.';SettingsProcessId=$(if($settingsProcess){$settingsProcess.Id}else{$null})}}
    try{
      $bounds=[System.Windows.Forms.SystemInformation]::VirtualScreen
      if($bounds.Width-gt0-and$bounds.Height-gt0){$bitmap=[System.Drawing.Bitmap]::new($bounds.Width,$bounds.Height);$graphics=[System.Drawing.Graphics]::FromImage($bitmap);try{$graphics.CopyFromScreen($bounds.Left,$bounds.Top,0,0,$bitmap.Size);$screenshot=Join-Path $EvidenceDirectory 'standard-user-settings-apps-before-uninstall.png';$bitmap.Save($screenshot,[System.Drawing.Imaging.ImageFormat]::Png)}finally{$graphics.Dispose();$bitmap.Dispose()}}
    }catch{}
    $search=$null
    foreach($element in @($settingsRoot.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition))){try{if($element.Current.ControlType-eq[System.Windows.Automation.ControlType]::Edit-and$element.Current.Name-match'(?i)search apps|search this list'){$search=$element;break}}catch{}}
    if(-not$search){return [pscustomobject]@{Status='NOT TESTED';Reason='Installed apps page has no accessible app-search field.';VisibleNames=@($names|Select-Object -Unique|Select-Object -First 80);Screenshot=$screenshot}}
    try{$value=$search.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern);$value.SetValue('Eye Break Reminder')}catch{try{$search.SetFocus();[System.Windows.Forms.SendKeys]::SendWait('^a');[System.Windows.Forms.SendKeys]::SendWait('Eye Break Reminder')}catch{return [pscustomobject]@{Status='NOT TESTED';Reason="The Installed apps search field could not be set: $($_.Exception.Message)";Screenshot=$screenshot}}}
    $watch=[Diagnostics.Stopwatch]::StartNew();$appEntry=$null
    while($watch.Elapsed.TotalSeconds-lt20-and-not$appEntry){
      try{foreach($element in @($settingsRoot.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition))){try{if($element.Current.Name-match'(?i)^Eye Break Reminder$'-and$element.Current.ControlType-ne[System.Windows.Automation.ControlType]::Button){$appEntry=$element;break}}catch{}}}catch{}
      if(-not$appEntry){Start-Sleep -Milliseconds 200}
    }
    if(-not$appEntry){return [pscustomobject]@{Status='NOT TESTED';Reason='The standard-user installation did not appear in the Settings > Installed apps search results.';VisibleNames=@($names|Select-Object -Unique|Select-Object -First 80);Screenshot=$screenshot}}
    $entryScreenshot=$null
    try{$bounds=[System.Windows.Forms.SystemInformation]::VirtualScreen;$bitmap=[System.Drawing.Bitmap]::new($bounds.Width,$bounds.Height);$graphics=[System.Drawing.Graphics]::FromImage($bitmap);try{$graphics.CopyFromScreen($bounds.Left,$bounds.Top,0,0,$bitmap.Size);$entryScreenshot=Join-Path $EvidenceDirectory 'standard-user-settings-apps-eye-break-reminder-found.png';$bitmap.Save($entryScreenshot,[System.Drawing.Imaging.ImageFormat]::Png)}finally{$graphics.Dispose();$bitmap.Dispose()}}catch{}
    $menuButton=$null;$scope=$appEntry
    for($depth=0;$depth-lt7-and-not$menuButton;$depth++){
      try{$controls=@($scope.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition));$menuButton=@($controls|Where-Object{try{$_.Current.ControlType-eq[System.Windows.Automation.ControlType]::Button-and$_.Current.IsEnabled-and$_.Current.Name-match'(?i)more options|more actions|options for'}catch{$false}}|Select-Object -First 1|ForEach-Object{$_})|Select-Object -First 1}catch{}
      if(-not$menuButton){try{$scope=[System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($scope)}catch{$scope=$null};if(-not$scope-or$scope-eq[System.Windows.Automation.AutomationElement]::RootElement){break}}
    }
    if(-not$menuButton){return [pscustomobject]@{Status='NOT TESTED';Reason='The Eye Break Reminder entry exposes no accessible row-specific options button.';Screenshots=@($screenshot,$entryScreenshot)}}
    try{$menuButton.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()}catch{try{$menuButton.SetFocus();[System.Windows.Forms.SendKeys]::SendWait('{ENTER}')}catch{return [pscustomobject]@{Status='NOT TESTED';Reason="Could not open the Eye Break Reminder row menu: $($_.Exception.Message)";Screenshot=$screenshot}}}
    $uninstallChoice=$null;$watch=[Diagnostics.Stopwatch]::StartNew()
    while($watch.Elapsed.TotalSeconds-lt10-and-not$uninstallChoice){
      foreach($element in @([System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition))){try{if($element.Current.Name-match'(?i)^Uninstall$'-and$element.Current.IsEnabled-and$element.Current.ControlType-in@([System.Windows.Automation.ControlType]::Button,[System.Windows.Automation.ControlType]::MenuItem)){$uninstallChoice=$element;break}}catch{}}
      if(-not$uninstallChoice){Start-Sleep -Milliseconds 100}
    }
    if(-not$uninstallChoice){return [pscustomobject]@{Status='NOT TESTED';Reason='The app row menu exposed no Uninstall action.';Screenshots=@($screenshot,$entryScreenshot)}}
    $menuChoiceRuntime='';try{$menuChoiceRuntime=$uninstallChoice.GetRuntimeId()-join'.'}catch{}
    try{$uninstallChoice.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()}catch{try{$uninstallChoice.SetFocus();[System.Windows.Forms.SendKeys]::SendWait('{ENTER}')}catch{return [pscustomobject]@{Status='NOT TESTED';Reason="Could not activate Settings > Apps > Uninstall: $($_.Exception.Message)";Screenshots=@($screenshot,$entryScreenshot)}}}
    $uninstallProcess=$null;$confirmClicks=0;$watch=[Diagnostics.Stopwatch]::StartNew()
    while($watch.Elapsed.TotalSeconds-lt35-and-not$uninstallProcess){
      $uninstallProcess=@(Get-Process -Name Uninstall -ErrorAction SilentlyContinue|Where-Object{try{[IO.Path]::GetFullPath($_.Path)-ieq[IO.Path]::GetFullPath($UninstallerPath)}catch{$false}}|Select-Object -First 1)
      if($uninstallProcess.Count){$uninstallProcess=$uninstallProcess[0];break}
      if($confirmClicks-eq0-and$watch.Elapsed.TotalSeconds-ge2-and$menuChoiceRuntime){
        $uiNames=[System.Collections.Generic.List[string]]::new();$confirm=$null
        foreach($element in [System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)){
          try{$elementName=[string]$element.Current.Name;if($elementName){$uiNames.Add($elementName)};$runtime=$element.GetRuntimeId()-join'.';if($runtime-cne$menuChoiceRuntime-and$elementName-match'(?i)^Uninstall$'-and$element.Current.ControlType-eq[System.Windows.Automation.ControlType]::Button-and$element.Current.IsEnabled-and-not$element.Current.IsOffscreen){$confirm=$element;break}}catch{}
        }
        $confirmationVisible=($uiNames.ToArray()-join'|')-match'(?i)are you sure|this app.*uninstall|uninstall.*Eye Break Reminder|Eye Break Reminder.*uninstall'
        if($confirm-and$confirmationVisible){try{$confirm.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke();$confirmClicks=1}catch{}}
      }
      Start-Sleep -Milliseconds 200
    }
    if(-not$uninstallProcess){return [pscustomobject]@{Status='NOT TESTED';Reason='Settings launched no visible per-user NSIS uninstaller within 35 seconds.';Screenshots=@($screenshot,$entryScreenshot);ConfirmationClicks=$confirmClicks}}
    $wizard=Invoke-StandardUserWizard $UninstallerPath 'Settings Apps interactive uninstall wizard' $uninstallProcess
    if($wizard.Status-ne'PASS'){return [pscustomobject]@{Status=$wizard.Status;Reason=$wizard.Reason;Wizard=$wizard;Screenshots=@($screenshot,$entryScreenshot)}}
    $installDir=Join-Path $env:LOCALAPPDATA 'Programs\EyeBreakReminder';$uninstallKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder';$appKey='HKCU:\Software\EyeBreakReminder'
    if((Test-Path -LiteralPath $installDir)-or(Test-Path -LiteralPath $uninstallKey)-or(Test-Path -LiteralPath $appKey)){return [pscustomobject]@{Status='FAIL';Reason='Settings uninstall completed its wizard but left the per-user app, install directory, or HKCU registrations.';Wizard=$wizard;Screenshot=$screenshot}}
    [pscustomobject]@{Status='PASS';ExitCode=$wizard.ExitCode;Wizard=$wizard;InstallationRemoved=$true;HKCURegistrationsRemoved=$true;Screenshots=@($screenshot,$entryScreenshot);ConfirmationClicks=$confirmClicks}
    }finally{
      if($settingsRoot){try{$settingsRoot.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close()}catch{}}
      if($settingsProcess){try{$settingsProcess.Refresh();if(-not$settingsProcess.HasExited-and$settingsProcess.MainWindowTitle-match'(?i)Settings'){[void]$settingsProcess.CloseMainWindow()}}catch{}}
    }
  }
  try{
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent();$principal=[Security.Principal.WindowsPrincipal]::new($identity)
    $isAdministrator=$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if($isAdministrator){throw 'The disposable test account unexpectedly has administrator membership.'}
    $events.Add([pscustomobject]@{Name='Child process has a standard Windows user token';Status='PASS';User=$identity.Name;Sid=$identity.User.Value;IsAdministrator=$false})
    $installer=(Resolve-Path -LiteralPath $InstallerPath).Path;$candidate=(Resolve-Path -LiteralPath $ExecutablePath).Path
    $expectedHash=(Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToLowerInvariant()
    $installDir=Join-Path $env:LOCALAPPDATA 'Programs\EyeBreakReminder';$installed=Join-Path $installDir 'EyeBreakReminder.exe';$uninstaller=Join-Path $installDir 'Uninstall.exe'
    $wizardInstall=Invoke-StandardUserWizard $installer 'standard-user interactive install wizard'
    $events.Add([pscustomobject]@{Name='Standard-user interactive installer wizard';Status=$wizardInstall.Status;Details=$wizardInstall;TokenAdministrator=$false})
    if($wizardInstall.Status-eq'PASS'){if($wizardInstall.FinishCheckbox-ne'Off'){$events.Add([pscustomobject]@{Name='Standard-user installer finish-page Run checkbox state';Status='NOT TESTED';Details="Finish-page checkbox state: $($wizardInstall.FinishCheckbox)."})}else{$events.Add([pscustomobject]@{Name='Standard-user installer finish-page Run checkbox is unchecked';Status='PASS';State=$wizardInstall.FinishCheckbox})}}
    if($wizardInstall.Status-eq'FAIL'){throw $wizardInstall.Reason}
    if($wizardInstall.Status-ne'PASS'){
      $install=Start-Process -FilePath $installer -ArgumentList '/S' -PassThru
      if(-not$install.WaitForExit(120000)){Stop-Process -Id $install.Id -Force -ErrorAction SilentlyContinue;throw 'Per-user installer timed out under the standard account.'}
      if($install.ExitCode-ne0){throw "Per-user installer returned exit code $($install.ExitCode) under the standard account."}
      $events.Add([pscustomobject]@{Name='Silent per-user install completes without administrator credentials or UAC elevation';Status='PASS';ExitCode=$install.ExitCode;TokenAdministrator=$false})
    }
    if(-not(Test-Path -LiteralPath $installed -PathType Leaf)){throw "Installer did not create the expected user-scoped executable '$installed'."}
    $installedHash=(Get-FileHash -LiteralPath $installed -Algorithm SHA256).Hash.ToLowerInvariant()
    if($installedHash-cne$expectedHash){throw "Installed executable hash $installedHash differs from candidate hash $expectedHash."}
    $events.Add([pscustomobject]@{Name='Installed image matches the candidate at the standard user LocalAppData path';Status='PASS';Path=$installed;SHA256=$installedHash})
    $uninstallKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder';$appKey='HKCU:\Software\EyeBreakReminder'
    if(-not(Test-Path -LiteralPath $uninstallKey)){throw 'The standard user HKCU uninstall registration was not created.'}
    $registration=Get-ItemProperty -LiteralPath $uninstallKey -ErrorAction Stop
    $registeredPath=[IO.Path]::GetFullPath([string]$registration.UninstallString.Trim('"'))
    if($registeredPath-ine[IO.Path]::GetFullPath($uninstaller)){throw "Uninstall registration points at '$registeredPath', expected '$uninstaller'."}
    if(-not(Test-Path -LiteralPath $appKey)){throw 'The standard user HKCU application registration was not created.'}
    $events.Add([pscustomobject]@{Name='Installer registers under the standard account HKCU hive';Status='PASS';UninstallKey=$uninstallKey;UninstallString=$registration.UninstallString})
    $appProcess=Start-Process -FilePath $installed -PassThru
    $windowWatch=[Diagnostics.Stopwatch]::StartNew();$windowTitle=''
    while($windowWatch.Elapsed.TotalSeconds-lt15){try{$appProcess.Refresh();$windowTitle=$appProcess.MainWindowTitle;if($appProcess.MainWindowHandle-ne[IntPtr]::Zero){break}}catch{};Start-Sleep -Milliseconds 100}
    if(-not$appProcess-or$appProcess.HasExited-or$appProcess.MainWindowHandle-eq[IntPtr]::Zero){throw 'The standard user could not launch a visible application window.'}
    $events.Add([pscustomobject]@{Name='Installed candidate launches with a visible window under the standard account';Status='PASS';Pid=$appProcess.Id;Title=$windowTitle;MainWindowHandle=('0x{0:X}'-f$appProcess.MainWindowHandle.ToInt64())})
    Stop-Process -Id $appProcess.Id -Force -ErrorAction SilentlyContinue;$appProcess=$null
    $settingsUninstall=Invoke-SettingsAppsUninstall $uninstaller
    $events.Add([pscustomobject]@{Name='Windows Settings > Apps uninstalls the standard-user candidate';Status=$settingsUninstall.Status;Details=$settingsUninstall;TokenAdministrator=$false})
    Get-Process -Name SystemSettings -ErrorAction SilentlyContinue|Where-Object{$_.SessionId-eq[Diagnostics.Process]::GetCurrentProcess().SessionId}|ForEach-Object{[void]$_.CloseMainWindow()}
    if($settingsUninstall.Status-eq'FAIL'){throw $settingsUninstall.Reason}
    if($settingsUninstall.Status-eq'PASS'){
      $settingsReinstall=Start-Process -FilePath $installer -ArgumentList '/S' -PassThru
      if(-not$settingsReinstall.WaitForExit(120000)-or$settingsReinstall.ExitCode-ne0){throw 'Silent reinstall failed after Windows Settings > Apps uninstall.'}
      if(-not(Test-Path -LiteralPath $installed)-or(Test-Path -LiteralPath $uninstallKey)-or-not(Test-Path -LiteralPath $appKey)){throw 'The standard-user install did not recover its expected file and registrations after the Settings uninstall.'}
      $events.Add([pscustomobject]@{Name='Per-user silent reinstall succeeds after Windows Settings > Apps removal';Status='PASS';ExitCode=$settingsReinstall.ExitCode;InstalledHash=(Get-FileHash -LiteralPath $installed -Algorithm SHA256).Hash.ToLowerInvariant()})
    }
    $wizardUninstall=Invoke-StandardUserWizard $uninstaller 'standard-user interactive uninstall wizard'
    $events.Add([pscustomobject]@{Name='Standard-user interactive uninstaller wizard';Status=$wizardUninstall.Status;Details=$wizardUninstall;TokenAdministrator=$false})
    if($wizardUninstall.Status-eq'PASS'){if($wizardUninstall.FinishCheckbox-eq'Off'){$events.Add([pscustomobject]@{Name='Standard-user uninstaller finish-page Run checkbox is unchecked';Status='PASS';State=$wizardUninstall.FinishCheckbox})}else{$events.Add([pscustomobject]@{Name='Standard-user uninstaller finish-page Run checkbox';Status='NOT APPLICABLE';Details='The uninstaller uses MUI_UNPAGE_FINISH; setup.nsi defines the Run checkbox only for install finish pages.'})}}
    if($wizardUninstall.Status-eq'FAIL'){throw $wizardUninstall.Reason}
    if($wizardUninstall.Status-ne'PASS'){
      $uninstall=Start-Process -FilePath $uninstaller -ArgumentList '/S' -PassThru
      if(-not$uninstall.WaitForExit(90000)){Stop-Process -Id $uninstall.Id -Force -ErrorAction SilentlyContinue;throw 'Silent per-user uninstaller timed out under the standard account.'}
      if($uninstall.ExitCode-ne0){throw "Silent per-user uninstaller returned exit code $($uninstall.ExitCode)."}
      $events.Add([pscustomobject]@{Name='Silent uninstall removes the standard user installation and both HKCU registrations';Status='PASS';ExitCode=$uninstall.ExitCode;InstallDirectoryExists=$false;UninstallRegistrationExists=$false;ApplicationRegistrationExists=$false})
    }else{
      if((Test-Path -LiteralPath $installed)-or(Test-Path -LiteralPath $installDir)-or(Test-Path -LiteralPath $uninstallKey)-or(Test-Path -LiteralPath $appKey)){throw 'Interactive standard-user uninstall left the executable, installation directory, or HKCU registration behind.'}
      $events.Add([pscustomobject]@{Name='Interactive uninstall removes the standard user installation and both HKCU registrations';Status='PASS';ExitCode=$wizardUninstall.ExitCode;InstallDirectoryExists=$false;UninstallRegistrationExists=$false;ApplicationRegistrationExists=$false})
      $silentInstall=Start-Process -FilePath $installer -ArgumentList '/S' -PassThru
      if(-not$silentInstall.WaitForExit(120000)-or$silentInstall.ExitCode-ne0){throw 'Silent reinstall failed after the standard-user interactive uninstall.'}
      $silentUninstall=Start-Process -FilePath $uninstaller -ArgumentList '/S' -PassThru
      if(-not$silentUninstall.WaitForExit(90000)-or$silentUninstall.ExitCode-ne0){throw 'Silent uninstall failed after the standard-user silent reinstall.'}
      $events.Add([pscustomobject]@{Name='Silent uninstall after a standard-user silent reinstall';Status='PASS';ExitCode=$silentUninstall.ExitCode})
    }
    $status='PASS'
  }catch{$failure=$_.Exception.Message;$events.Add([pscustomobject]@{Name='Standard user acceptance';Status='FAIL';Details=$failure})}
  finally{
    if($appProcess-and-not$appProcess.HasExited){Stop-Process -Id $appProcess.Id -Force -ErrorAction SilentlyContinue}
    if($ChildResultPath){Save-StandardUserResult $ChildResultPath ([pscustomobject]@{Status=$status;Failure=$failure;User=[Security.Principal.WindowsIdentity]::GetCurrent().Name;Events=$events.ToArray();CompletedUtc=[DateTime]::UtcNow.ToString('o')})}
  }
  if($status-eq'PASS'){exit 0}else{exit 1}
}

$finalResult=Join-Path $EvidenceDirectory 'standard-user-results.json';$runId=if($env:GITHUB_RUN_ID){$env:GITHUB_RUN_ID}else{[guid]::NewGuid().ToString('N').Substring(0,10)}
$userName=('EbrStd'+$runId);if($userName.Length-gt20){$userName=$userName.Substring(0,20)}
$stageRoot=[IO.Path]::GetFullPath((Join-Path $env:RUNNER_TEMP "eye-break-reminder-standard-user-$runId"))
$evidenceRoot=[IO.Path]::GetFullPath($EvidenceDirectory);$userCreated=$false;$testStarted=$false;$status='BLOCKED';$reason='';$result=$null;$childExitCode=$null;$cleanupActions=[System.Collections.Generic.List[string]]::new();$cleanupErrors=[System.Collections.Generic.List[string]]::new();$childResult=Join-Path $stageRoot 'standard-user-child-results.json'
[void][IO.Directory]::CreateDirectory($evidenceRoot)
try{
  try{
    $bytes=[byte[]]::new(48);[Security.Cryptography.RandomNumberGenerator]::Fill($bytes);$passwordText=[Convert]::ToBase64String($bytes)+'aA9!';[Array]::Clear($bytes,0,$bytes.Length)
    $securePassword=ConvertTo-SecureString -String $passwordText -AsPlainText -Force;$passwordText=$null
    New-LocalUser -Name $userName -Password $securePassword -PasswordNeverExpires -UserMayNotChangePassword -AccountNeverExpires -ErrorAction Stop|Out-Null
    $userCreated=$true
    $user=Get-LocalUser -Name $userName -ErrorAction Stop
    $usersGroup=Get-LocalGroup -SID ([Security.Principal.SecurityIdentifier]'S-1-5-32-545') -ErrorAction Stop
    $usersMembership=@(Get-LocalGroupMember -Group $usersGroup -ErrorAction Stop|Where-Object{$_.SID.Value-eq$user.SID.Value})
    if(-not$usersMembership.Count){Add-LocalGroupMember -Group $usersGroup -Member $userName -ErrorAction Stop}
    $adminMembership=@(Get-LocalGroupMember -Group 'Administrators' -ErrorAction Stop|Where-Object{$_.SID.Value-eq$user.SID.Value})
    if($adminMembership.Count){throw 'Temporary account was added to the local Administrators group.'}
    $status='FAIL'
    $reason=''
    [void][IO.Directory]::CreateDirectory($stageRoot)
    $stageEvidence=Join-Path $stageRoot 'evidence';[void][IO.Directory]::CreateDirectory($stageEvidence)
    Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $stageRoot 'windows_standard_user_acceptance.ps1') -Force
    Copy-Item -LiteralPath $InstallerPath -Destination (Join-Path $stageRoot 'EyeBreakReminder-Setup-x64.exe') -Force
    Copy-Item -LiteralPath $ExecutablePath -Destination (Join-Path $stageRoot 'EyeBreakReminder.exe') -Force
    $principal="$env:COMPUTERNAME\${userName}"
    & icacls.exe $stageRoot /grant "${principal}:(OI)(CI)M" /T /C|Out-Null
    if($LASTEXITCODE-ne0){throw "Could not grant the disposable standard user access to its isolated staging folder (icacls $LASTEXITCODE)."}
    $pwsh=Join-Path $PSHOME 'pwsh.exe';$childScript=Join-Path $stageRoot 'windows_standard_user_acceptance.ps1'
    $arguments="-NoProfile -ExecutionPolicy Bypass -File `"$childScript`" -Child -InstallerPath `"$(Join-Path $stageRoot 'EyeBreakReminder-Setup-x64.exe')`" -ExecutablePath `"$(Join-Path $stageRoot 'EyeBreakReminder.exe')`" -EvidenceDirectory `"$stageEvidence`" -ChildResultPath `"$childResult`""
    $credential=[pscredential]::new($principal,$securePassword)
    $childStdout=Join-Path $stageRoot 'standard-user-child.stdout.log';$childStderr=Join-Path $stageRoot 'standard-user-child.stderr.log'
    $child=Start-Process -FilePath $pwsh -Credential $credential -LoadUserProfile -ArgumentList $arguments -RedirectStandardOutput $childStdout -RedirectStandardError $childStderr -PassThru
    $testStarted=$true
    $credential=$null;try{$securePassword.Dispose()}catch{};$securePassword=$null
    if(-not$child.WaitForExit(900000)){Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue;throw 'Standard-user test process exceeded the fifteen-minute limit.'}
    $childExitCode=$child.ExitCode;$child.Dispose()
    foreach($capture in @(@($childResult,'standard-user-child-results.json'),@($childStdout,'standard-user-child.stdout.log'),@($childStderr,'standard-user-child.stderr.log'))){if(Test-Path -LiteralPath $capture[0]){Copy-Item -LiteralPath $capture[0] -Destination (Join-Path $evidenceRoot $capture[1]) -Force}}
    if(Test-Path -LiteralPath $childResult){$result=Get-Content -LiteralPath $childResult -Raw|ConvertFrom-Json}else{$result=$null}
    $childOutput=if(Test-Path -LiteralPath $childStdout){(Get-Content -LiteralPath $childStdout -Tail 60)-join"`n"}else{''};$childError=if(Test-Path -LiteralPath $childStderr){(Get-Content -LiteralPath $childStderr -Tail 60)-join"`n"}else{''}
    if($childExitCode-eq0-and$result-and$result.Status-eq'PASS'){$status='PASS'}else{$status='FAIL';$reason=if($result){$result.Failure}else{"Standard-user child returned exit code $childExitCode without a passing evidence file. stdout: $childOutput stderr: $childError"}}
  }catch{
    if($testStarted){$status='FAIL';$reason=$_.Exception.Message}else{$status='BLOCKED';$reason="The hosted runner could not safely provision or launch the isolated standard-user test: $($_.Exception.Message)"}
  }
}finally{
  $stagedEvidence=Join-Path $stageRoot 'evidence'
  if(Test-Path -LiteralPath $stagedEvidence){
    try{
      $screenshots=@(Get-ChildItem -LiteralPath $stagedEvidence -Filter '*.png' -File)
      if($screenshots.Count){$settingsScreenshotDirectory=Join-Path $evidenceRoot 'standard-user-screenshots';[void][IO.Directory]::CreateDirectory($settingsScreenshotDirectory);foreach($screenshot in $screenshots){Copy-Item -LiteralPath $screenshot.FullName -Destination (Join-Path $settingsScreenshotDirectory $screenshot.Name) -Force}}
    }catch{$cleanupErrors.Add("Could not retain standard-user screenshots: $($_.Exception.Message)")}
  }
  if($userCreated){
    try{
      $localUser=Get-LocalUser -Name $userName -ErrorAction SilentlyContinue
      if($localUser){
        $profile=Get-CimInstance Win32_UserProfile -ErrorAction Stop|Where-Object{$_.SID-eq$localUser.SID.Value-and-not$_.Special}|Select-Object -First 1
        $profileWatch=[Diagnostics.Stopwatch]::StartNew()
        while($profile-and$profile.Loaded-and$profileWatch.Elapsed.TotalSeconds-lt12){Start-Sleep -Milliseconds 500;$profile=Get-CimInstance Win32_UserProfile -ErrorAction Stop|Where-Object{$_.SID-eq$localUser.SID.Value-and-not$_.Special}|Select-Object -First 1}
        if($profile-and$profile.Loaded){
          $stopped=[System.Collections.Generic.List[string]]::new()
          foreach($process in Get-CimInstance Win32_Process -ErrorAction Stop){
            try{$owner=Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid -ErrorAction Stop;if($owner.ReturnValue-eq0-and$owner.Sid-eq$localUser.SID.Value){Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue;$stopped.Add("$($process.Name)#$($process.ProcessId)")}}catch{}
          }
          if($stopped.Count){$cleanupActions.Add("Stopped remaining processes owned by the disposable account after its child test exited: $($stopped -join ', ')")}
          $profileWatch.Restart()
          while($profile-and$profile.Loaded-and$profileWatch.Elapsed.TotalSeconds-lt12){Start-Sleep -Milliseconds 500;$profile=Get-CimInstance Win32_UserProfile -ErrorAction Stop|Where-Object{$_.SID-eq$localUser.SID.Value-and-not$_.Special}|Select-Object -First 1}
        }
        if($profile-and$profile.Loaded){$cleanupErrors.Add("Temporary profile is still loaded after waiting and stopping disposable-user processes: $($profile.LocalPath)")}
        Remove-LocalUser -Name $userName -ErrorAction Stop
        if($profile){
          $resolvedProfile=[IO.Path]::GetFullPath($profile.LocalPath);$usersRoot=[IO.Path]::GetFullPath((Join-Path $env:SystemDrive 'Users'))
          if(-not$resolvedProfile.StartsWith($usersRoot+'\',[StringComparison]::OrdinalIgnoreCase)-or[IO.Path]::GetFileName($resolvedProfile)-ne$userName){throw "Refusing to remove an unexpected profile path '$resolvedProfile'."}
          if(-not$profile.Loaded){Remove-CimInstance -InputObject $profile -ErrorAction Stop}
        }
      }
    }catch{$cleanupErrors.Add($_.Exception.Message)}
  }
  if(Test-Path -LiteralPath $stageRoot){
    $runnerTemp=[IO.Path]::GetFullPath($env:RUNNER_TEMP)
    if(-not$stageRoot.StartsWith($runnerTemp+'\',[StringComparison]::OrdinalIgnoreCase)){throw "Refusing to remove a staging path outside RUNNER_TEMP: $stageRoot"}
    Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
$accountRemoved=(-not[bool](Get-LocalUser -Name $userName -ErrorAction SilentlyContinue));$stageRemoved=(-not(Test-Path -LiteralPath $stageRoot))
if(-not$accountRemoved){$cleanupErrors.Add('Disposable standard-user account still exists after cleanup.')};if(-not$stageRemoved){$cleanupErrors.Add('Temporary candidate staging directory still exists after cleanup.')}
$settingsEvent=if($result){@($result.Events|Where-Object{$_.Name-eq'Windows Settings > Apps uninstalls the standard-user candidate'}|Select-Object -First 1)}else{@()}
$settingsScreenshotDirectory=Join-Path $evidenceRoot 'standard-user-screenshots'
$resultObject=[pscustomobject]@{Status=$status;Account=$userName;Failure=$reason;ChildExitCode=$childExitCode;ChildResultCaptured=[bool]$result;CleanupActions=$cleanupActions.ToArray();CleanupErrors=$cleanupErrors.ToArray();AccountRemoved=$accountRemoved;StageRemoved=$stageRemoved;CandidateSHA256=if(Test-Path -LiteralPath $ExecutablePath){(Get-FileHash -LiteralPath $ExecutablePath -Algorithm SHA256).Hash.ToLowerInvariant()}else{$null};Events=if($result){$result.Events}else{@()};SettingsAppsUninstall=if($settingsEvent.Count){$settingsEvent[0].Status}else{'NOT TESTED'};SettingsAppsUninstallReason=if($settingsEvent.Count){$settingsEvent[0].Details.Reason}else{'The Settings Apps probe did not produce a result.'};SettingsScreenshots=@(Get-ChildItem -LiteralPath $settingsScreenshotDirectory -Filter '*.png' -File -ErrorAction SilentlyContinue|Select-Object -ExpandProperty Name);CompletedUtc=[DateTime]::UtcNow.ToString('o')}
if($cleanupErrors.Count-gt0){$resultObject.Status='FAIL';$failureParts=@($reason)+@($cleanupErrors.ToArray())|Where-Object{$_};$resultObject.Failure=$failureParts -join '; '}
Save-StandardUserResult $finalResult $resultObject
$resultObject|ConvertTo-Json -Depth 8
if($resultObject.Status-eq'FAIL'){exit 1}
