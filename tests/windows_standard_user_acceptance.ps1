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
  $native=@'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;
using System.Text;
public static class EBR_STD_NATIVE {
  public delegate bool EnumProc(IntPtr hwnd,IntPtr data);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback,IntPtr data);
  [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent,EnumProc callback,IntPtr data);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd,out uint pid);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetWindowTextW(IntPtr hwnd,StringBuilder text,int max);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr hwnd,StringBuilder text,int max);
  [DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr hwnd,uint message,IntPtr wParam,IntPtr lParam);
  [DllImport("user32.dll",SetLastError=true)] public static extern IntPtr SendMessageTimeoutW(IntPtr hwnd,uint message,IntPtr wParam,IntPtr lParam,uint flags,uint timeout,out IntPtr result);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
  [DllImport("user32.dll")] static extern bool SetCursorPos(int x,int y);
  [DllImport("user32.dll")] static extern void mouse_event(uint flags,uint dx,uint dy,uint data,UIntPtr extra);
  [DllImport("user32.dll",SetLastError=true)] static extern bool GetWindowRect(IntPtr hwnd,out RECT rect);
  [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left,Top,Right,Bottom; }
  public static int[] Bounds(IntPtr hwnd){RECT r;if(!GetWindowRect(hwnd,out r))return new int[0];return new[]{r.Left,r.Top,r.Right,r.Bottom};}
  public static bool ClickAt(int x,int y){if(!SetCursorPos(x,y))return false;Thread.Sleep(80);mouse_event(0x0002,0,0,0,UIntPtr.Zero);Thread.Sleep(80);mouse_event(0x0004,0,0,0,UIntPtr.Zero);return true;}
  public static int ProcessId(IntPtr hwnd){uint pid;GetWindowThreadProcessId(hwnd,out pid);return (int)pid;}
  public static string Text(IntPtr hwnd){var b=new StringBuilder(512);GetWindowTextW(hwnd,b,b.Capacity);return b.ToString();}
  public static string ClassName(IntPtr hwnd){var b=new StringBuilder(128);GetClassNameW(hwnd,b,b.Capacity);return b.ToString();}
  public static IntPtr[] TopWindowsForProcess(int processId){var result=new List<IntPtr>();EnumWindows((h,d)=>{uint pid;GetWindowThreadProcessId(h,out pid);if(pid==(uint)processId)result.Add(h);return true;},IntPtr.Zero);return result.ToArray();}
  public static IntPtr[] Children(IntPtr parent){var result=new List<IntPtr>();EnumChildWindows(parent,(h,d)=>{result.Add(h);return true;},IntPtr.Zero);return result.ToArray();}
}
'@
  Add-Type -TypeDefinition $native -ErrorAction Stop
  Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
  Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
  $uiaClientAssembly=[System.Windows.Automation.AutomationElement].Assembly.Location
  $uiaTypesAssembly=[System.Windows.Automation.ControlType].Assembly.Location
  Add-Type -ReferencedAssemblies @($uiaClientAssembly,$uiaTypesAssembly) -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Automation;
public static class EBR_STD_UIA_CLIENT {
  [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern IntPtr CreateWindowExW(uint ex,string cls,string text,uint style,int x,int y,int width,int height,IntPtr parent,IntPtr menu,IntPtr instance,IntPtr param);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern IntPtr GetModuleHandleW(string name);
  [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr hwnd);
  public static string InitializeNativeProviders(){
    IntPtr hwnd=CreateWindowExW(0,"BUTTON","UIA provider bootstrap",0,0,0,2,2,IntPtr.Zero,IntPtr.Zero,GetModuleHandleW(null),IntPtr.Zero);
    if(hwnd==IntPtr.Zero)throw new InvalidOperationException("Could not create the hidden native Button used to initialize UI Automation providers.");
    try{return AutomationElement.FromHandle(hwnd).Current.ControlType.ProgrammaticName;}finally{DestroyWindow(hwnd);}
  }
}
'@ -ErrorAction Stop
  $uiaProviderBootstrap=[EBR_STD_UIA_CLIENT]::InitializeNativeProviders()
  if($uiaProviderBootstrap-cne'ControlType.Button'){throw "UI Automation provider bootstrap returned '$uiaProviderBootstrap', expected ControlType.Button."}
  $events=[System.Collections.Generic.List[object]]::new();$appProcess=$null;$status='FAIL';$failure=''
  $events.Add([pscustomobject]@{Name='UI Automation client initializes the standard native Button provider';Status='PASS';Details=$uiaProviderBootstrap})
  function Find-StandardUserWizardWindow([int]$ProcessId,[string]$Kind){
    $processIds=[System.Collections.Generic.List[int]]::new();$processIds.Add($ProcessId)
    if($Kind-match'(?i)uninstall'){
      foreach($process in Get-Process -Name 'Un','Uninstall' -ErrorAction SilentlyContinue|Where-Object{$_.SessionId-eq[Diagnostics.Process]::GetCurrentProcess().SessionId}){if(-not$processIds.Contains($process.Id)){$processIds.Add($process.Id)}}
    }
    foreach($candidateId in $processIds){foreach($handle in [EBR_STD_NATIVE]::TopWindowsForProcess($candidateId)){
      if(-not[EBR_STD_NATIVE]::IsWindowVisible($handle)){continue}
      $top=$null;try{$top=[System.Windows.Automation.AutomationElement]::FromHandle($handle)}catch{}
      return [pscustomobject]@{Element=$top;Handle=$handle;ProcessId=$candidateId}
    }}
    return $null
  }
  function Get-StandardUserNativeControls([IntPtr]$Window){
    foreach($handle in [EBR_STD_NATIVE]::Children($Window)){
      if([EBR_STD_NATIVE]::ProcessId($handle)-ne[EBR_STD_NATIVE]::ProcessId($Window)){continue}
      [pscustomobject]@{Handle=$handle;Class=[EBR_STD_NATIVE]::ClassName($handle);Text=[EBR_STD_NATIVE]::Text($handle);Id=[EBR_STD_NATIVE]::GetDlgCtrlID($handle);Visible=[EBR_STD_NATIVE]::IsWindowVisible($handle);Enabled=[EBR_STD_NATIVE]::IsWindowEnabled($handle);Bounds=[EBR_STD_NATIVE]::Bounds($handle)}
    }
  }
  function Invoke-StandardUserNativeButton([IntPtr]$Button,[string]$Name){
    $result=[IntPtr]::Zero;$sent=[EBR_STD_NATIVE]::SendMessageTimeoutW($Button,0x00F5,[IntPtr]::Zero,[IntPtr]::Zero,2,5000,[ref]$result)
    if($sent-eq[IntPtr]::Zero){throw "Native Win32 button '$Name' did not return within five seconds (win32Error=$([Runtime.InteropServices.Marshal]::GetLastWin32Error()))."}
  }
  function Capture-StandardUserWizard([IntPtr]$Window,[string]$Name){
    try{$bounds=[EBR_STD_NATIVE]::Bounds($Window);if($bounds.Count-ne4-or$bounds[2]-le$bounds[0]-or$bounds[3]-le$bounds[1]){return $null};$bitmap=[Drawing.Bitmap]::new($bounds[2]-$bounds[0],$bounds[3]-$bounds[1]);$graphics=[Drawing.Graphics]::FromImage($bitmap);$path=Join-Path $EvidenceDirectory $Name;try{$graphics.CopyFromScreen($bounds[0],$bounds[1],0,0,$bitmap.Size);$bitmap.Save($path,[Drawing.Imaging.ImageFormat]::Png)}finally{$graphics.Dispose();$bitmap.Dispose()};return $path}catch{return $null}
  }
  function Capture-StandardUserDesktop([string]$Name){
    try{$bounds=[System.Windows.Forms.SystemInformation]::VirtualScreen;if($bounds.Width-le0-or$bounds.Height-le0){return $null};$bitmap=[Drawing.Bitmap]::new($bounds.Width,$bounds.Height);$graphics=[Drawing.Graphics]::FromImage($bitmap);$path=Join-Path $EvidenceDirectory $Name;try{$graphics.CopyFromScreen($bounds.Left,$bounds.Top,0,0,$bitmap.Size);$bitmap.Save($path,[Drawing.Imaging.ImageFormat]::Png)}finally{$graphics.Dispose();$bitmap.Dispose()};return $path}catch{return $null}
  }
  function Invoke-StandardUserWizard([string]$Path,[string]$Kind,[Diagnostics.Process]$ExistingProcess=$null){
    try{$started=if($ExistingProcess){$ExistingProcess}else{Start-Process -FilePath $Path -PassThru}}catch{return [pscustomobject]@{Status='NOT TESTED';Kind=$Kind;Reason="Could not launch the interactive wizard: $($_.Exception.Message)"}}
    $watch=[Diagnostics.Stopwatch]::StartNew();$root=$null;$lastSignature='';$pageNames=[System.Collections.Generic.List[string]]::new();$finishCheckbox=$null;$terminalUninstallAt=$null;$uninstallDataChoice='NOT SHOWN';$terminalScreenshot=$null;$terminalFallbackUsed=$false;$terminalButtonSignature=''
    try{Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop;Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop;Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop;Add-Type -AssemblyName System.Drawing -ErrorAction Stop}catch{Stop-Process -Id $started.Id -Force -ErrorAction SilentlyContinue;return [pscustomobject]@{Status='NOT TESTED';Kind=$Kind;Reason="UI Automation or keyboard assemblies are unavailable: $($_.Exception.Message)"}}
    while($watch.Elapsed.TotalSeconds-lt180){
      if($Kind-match'(?i)uninstall'-and$terminalUninstallAt){
        $started.Refresh()
        $installRoot=Split-Path -Parent $Path
        $installedExe=Join-Path $installRoot 'EyeBreakReminder.exe'
        $uninstallKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder'
        $applicationKey='HKCU:\Software\EyeBreakReminder'
        $removed=(-not(Test-Path -LiteralPath $installedExe)-and-not(Test-Path -LiteralPath $installRoot)-and-not(Test-Path -LiteralPath $uninstallKey)-and-not(Test-Path -LiteralPath $applicationKey))
        if($started.HasExited-and$started.ExitCode-eq0-and$removed){if($uninstallDataChoice-match'(?i)^Keep my settings and history'){return [pscustomobject]@{Status='PASS';Kind=$Kind;ExitCode=$started.ExitCode;ProcessCompleted=$true;FinishPageExpected=$false;Completion='NSIS uninstall exits after its terminal Uninstall action; installed image, directory and HKCU registrations are absent';DataRetentionChoice=$uninstallDataChoice;Navigation='UI Automation with native Win32 fallback';Pages=$pageNames.ToArray();TerminalScreenshot=$terminalScreenshot;DurationSeconds=[Math]::Round($watch.Elapsed.TotalSeconds,1)}};return [pscustomobject]@{Status='NOT TESTED';Kind=$Kind;Reason='The installation was removed but the interactive keep-data selection was not exposed for verification.';ExitCode=$started.ExitCode;DataRetentionChoice=$uninstallDataChoice;Pages=$pageNames.ToArray();TerminalScreenshot=$terminalScreenshot}}
        if($watch.Elapsed.TotalSeconds-$terminalUninstallAt.TotalSeconds-ge75){return [pscustomobject]@{Status='NOT TESTED';Kind=$Kind;Reason='Terminal Uninstall action did not remove the per-user installation and exit within 75 seconds.';ExitCode=$(if($started.HasExited){$started.ExitCode}else{$null});InstallationRemoved=$removed;DataRetentionChoice=$uninstallDataChoice;Pages=$pageNames.ToArray();TerminalScreenshot=$terminalScreenshot;DesktopScreenshot=(Capture-StandardUserDesktop 'standard-user-uninstall-terminal-timeout.png')}}
      }
      $started.Refresh();$root=Find-StandardUserWizardWindow $started.Id $Kind
      if(-not$root){if($started.HasExited-and$watch.Elapsed.TotalSeconds-ge8){if($started.ExitCode-eq0){return [pscustomobject]@{Status='NOT TESTED';Kind=$Kind;Reason='Installer exited without exposing a wizard window.';ExitCode=$started.ExitCode}};return [pscustomobject]@{Status='FAIL';Kind=$Kind;Reason='Installer exited before the wizard completed.';ExitCode=$started.ExitCode}};Start-Sleep -Milliseconds 150;continue}
      $elements=@();if($root.Element){try{$elements=@($root.Element.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition))}catch{}}
      $nativeControls=@(Get-StandardUserNativeControls $root.Handle);$nativeVisible=@($nativeControls|Where-Object{$_.Visible});$named=@(foreach($element in $elements){try{$name=[string]$element.Current.Name;if($name){$name}}catch{}});$signature=$named-join'|';if(-not$signature){$signature=($nativeVisible|Where-Object{$_.Text}|ForEach-Object{$_.Text})-join'|'}
      $buttons=@($elements|Where-Object{try{$_.Current.ControlType-eq[System.Windows.Automation.ControlType]::Button-and$_.Current.IsEnabled-and-not$_.Current.IsOffscreen}catch{$false}})
      if($Kind-match'(?i)uninstall'-and$terminalUninstallAt-and-not$terminalFallbackUsed-and$signature-eq$terminalButtonSignature-and($watch.Elapsed.TotalSeconds-$terminalUninstallAt.TotalSeconds)-ge5){
        $fallbackButton=@($nativeControls|Where-Object{$_.Class-eq'Button'-and$_.Visible-and$_.Enabled-and$_.Text-match'(?i)^\s*&?Uninstall\s*$'}|Select-Object -First 1)
        if($fallbackButton.Count-and$fallbackButton[0].Bounds.Count-eq4){
          $bounds=$fallbackButton[0].Bounds;[void][EBR_STD_NATIVE]::SetForegroundWindow($root.Handle)
          if([EBR_STD_NATIVE]::ClickAt([int](($bounds[0]+$bounds[2])/2),[int](($bounds[1]+$bounds[3])/2))){$terminalFallbackUsed=$true;$pageNames.Add('Uninstall (physical-input fallback after unchanged UIA page)')}
        }
      }
      if($Kind-match'(?i)uninstall'-and$uninstallDataChoice-eq'NOT SHOWN'){
        $keepRadio=@($elements|Where-Object{try{$_.Current.ControlType-eq[System.Windows.Automation.ControlType]::RadioButton-and$_.Current.Name-match'(?i)^Keep my settings and history'}catch{$false}}|Select-Object -First 1)
        if($keepRadio.Count){try{$selection=$keepRadio[0].GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern);if(-not$selection.Current.IsSelected){$selection.Select()};if($selection.Current.IsSelected){$uninstallDataChoice='Keep my settings and history (UI Automation)'}}catch{}}
        if($uninstallDataChoice-eq'NOT SHOWN'){
          $nativeKeep=@($nativeControls|Where-Object{$_.Class-eq'Button'-and$_.Text-match'(?i)^Keep my settings and history'})|Select-Object -First 1
          if($nativeKeep.Count){$keepState=[EBR_STD_NATIVE]::SendMessageW($nativeKeep[0].Handle,0x00F0,[IntPtr]::Zero,[IntPtr]::Zero).ToInt32();if($keepState-ne1){Invoke-StandardUserNativeButton $nativeKeep[0].Handle 'Keep my settings and history';$keepState=[EBR_STD_NATIVE]::SendMessageW($nativeKeep[0].Handle,0x00F0,[IntPtr]::Zero,[IntPtr]::Zero).ToInt32()};if($keepState-eq1){$uninstallDataChoice='Keep my settings and history (native radio verified)'}}
        }
      }
      $finish=@($buttons|Where-Object{try{$_.Current.Name-match'(?i)^\s*&?Finish\s*$'}catch{$false}}|Select-Object -First 1)
      $nativeButtons=@($nativeControls|Where-Object{$_.Class-eq'Button'-and$_.Visible-and$_.Enabled});$nativeFinish=@($nativeButtons|Where-Object{$_.Text-match'(?i)^\s*&?(Finish|Close)\s*$'}|Select-Object -First 1)
      if($finish.Count-or$nativeFinish.Count){
        [void][EBR_STD_NATIVE]::SetForegroundWindow($root.Handle)
        $finishCheckbox=@($elements|Where-Object{try{$_.Current.ControlType-eq[System.Windows.Automation.ControlType]::CheckBox-and$_.Current.Name-match'(?i)Open Eye Break Reminder'}catch{$false}}|Select-Object -First 1)
        $checkboxState='NOT EXPOSED'
        if($finishCheckbox.Count){try{$toggle=$finishCheckbox[0].GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern);if($toggle.Current.ToggleState-eq[System.Windows.Automation.ToggleState]::On){$toggle.Toggle()};$checkboxState=$toggle.Current.ToggleState.ToString()}catch{$checkboxState='UIA state unavailable'}}
        $nativeChecks=@($nativeButtons|Where-Object{$_.Text-match'(?i)Open Eye Break Reminder'})
        if($nativeChecks.Count){foreach($check in $nativeChecks){if([EBR_STD_NATIVE]::SendMessageW($check.Handle,0x00F0,[IntPtr]::Zero,[IntPtr]::Zero).ToInt32()-eq1){[void][EBR_STD_NATIVE]::SendMessageW($check.Handle,0x00F5,[IntPtr]::Zero,[IntPtr]::Zero)}};$remaining=@($nativeChecks|Where-Object{[EBR_STD_NATIVE]::SendMessageW($_.Handle,0x00F0,[IntPtr]::Zero,[IntPtr]::Zero).ToInt32()-eq1});if($remaining.Count){return [pscustomobject]@{Status='FAIL';Kind=$Kind;Reason='The native finish-page Run checkbox remained checked after the harness cleared it.';FinishCheckbox='On';Pages=$pageNames.ToArray();NativeChecks=$nativeChecks}};$checkboxState='Off (native Win32)'}elseif($finishCheckbox.Count-and$checkboxState-ne'Off'){return [pscustomobject]@{Status='FAIL';Kind=$Kind;Reason='The finish-page Run checkbox could not be cleared or verified.';FinishCheckbox=$checkboxState;Pages=$pageNames.ToArray()}}
        $finishScreenshot=Capture-StandardUserWizard $root.Handle 'standard-user-wizard-finish.png'
        if($finish.Count){try{$finish[0].GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()}catch{try{$finish[0].SetFocus();[System.Windows.Forms.SendKeys]::SendWait('{ENTER}')}catch{Stop-Process -Id $started.Id -Force -ErrorAction SilentlyContinue;return [pscustomobject]@{Status='NOT TESTED';Kind=$Kind;Reason="UI Automation could not activate the Finish button: $($_.Exception.Message)";FinishCheckbox=$checkboxState;Pages=$pageNames.ToArray()}}}}else{Invoke-StandardUserNativeButton $nativeFinish[0].Handle 'Finish'}
        $wizardProcess=try{[Diagnostics.Process]::GetProcessById($root.ProcessId)}catch{$started}
        if(-not$wizardProcess.WaitForExit(30000)){
          $started.Refresh();$wizardProcess.Refresh()
          $processes=@(Get-Process -ErrorAction SilentlyContinue|Where-Object{$_.SessionId-eq$started.SessionId-and($_.ProcessName-match'(?i)EyeBreakReminder|Setup|Uninstall')}|ForEach-Object{[pscustomobject]@{Pid=$_.Id;Name=$_.ProcessName;MainWindowTitle=$_.MainWindowTitle;Path=$(try{$_.Path}catch{$null})}})
          $topWindowHandles=[EBR_STD_NATIVE]::TopWindowsForProcess($root.ProcessId)
          $windows=@(foreach($handle in $topWindowHandles){[pscustomobject]@{Handle=('0x{0:X}'-f$handle.ToInt64());Title=[EBR_STD_NATIVE]::Text($handle);Class=[EBR_STD_NATIVE]::ClassName($handle);Controls=@(Get-StandardUserNativeControls $handle)}})
          $afterScreenshot=Capture-StandardUserWizard $root.Handle 'standard-user-wizard-after-finish-timeout.png'
          Stop-Process -Id $root.ProcessId -Force -ErrorAction SilentlyContinue;Stop-Process -Id $started.Id -Force -ErrorAction SilentlyContinue
          return [pscustomobject]@{Status='FAIL';Kind=$Kind;Reason='Wizard remained running 30 seconds after Finish.';FinishCheckbox=$checkboxState;Pages=$pageNames.ToArray();ProcessId=$root.ProcessId;HasExited=$wizardProcess.HasExited;ExitCode=$(if($wizardProcess.HasExited){$wizardProcess.ExitCode}else{$null});WindowTitle=[EBR_STD_NATIVE]::Text($root.Handle);NativeWindow=('0x{0:X}'-f$root.Handle.ToInt64());NativeWindows=$windows;RelatedProcesses=$processes;FinishScreenshot=$finishScreenshot;TimeoutScreenshot=$afterScreenshot}
        }
        $wizardExitCode=$null;try{$wizardExitCode=$wizardProcess.ExitCode}catch{};$started.Refresh();$parentExitCode=if($started.HasExited){$started.ExitCode}else{$null}
        if(($null-ne$wizardExitCode-and$wizardExitCode-ne0)-or($null-ne$parentExitCode-and$parentExitCode-ne0)){return [pscustomobject]@{Status='FAIL';Kind=$Kind;Reason='Installer or uninstaller wizard returned a nonzero process exit code.';ExitCode=$wizardExitCode;ExitCodeObserved=($null-ne$wizardExitCode);ParentExitCode=$parentExitCode;FinishCheckbox=$checkboxState;Pages=$pageNames.ToArray()}}
        return [pscustomobject]@{Status='PASS';Kind=$Kind;ExitCode=$wizardExitCode;ExitCodeObserved=($null-ne$wizardExitCode);ProcessCompleted=$true;ParentExitCode=$parentExitCode;WizardProcessId=$root.ProcessId;FinishCheckbox=$checkboxState;Navigation='UI Automation with native Win32 fallback';Pages=$pageNames.ToArray();DurationSeconds=[Math]::Round($watch.Elapsed.TotalSeconds,1)}
      }
      if($signature-ne$lastSignature){
        $next=@($buttons|Where-Object{try{$_.Current.Name-match'(?i)^\s*&?(Next|Install|Uninstall|Remove)\s*>?\s*$'}catch{$false}}|Select-Object -First 1)
        $nativeNext=@($nativeButtons|Where-Object{$_.Text-match'(?i)^\s*&?(Next|Install|Uninstall|Remove)\s*>?\s*$'}|Select-Object -First 1)
        if($next.Count){$buttonName=[string]$next[0].Current.Name;$pageNames.Add($buttonName);if($Kind-match'(?i)uninstall'-and$buttonName-match'(?i)^\s*&?Uninstall\s*$'){$terminalScreenshot=Capture-StandardUserWizard $root.Handle 'standard-user-uninstall-retention-choice.png'};try{$next[0].GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()}catch{try{$next[0].SetFocus();[System.Windows.Forms.SendKeys]::SendWait('{ENTER}')}catch{Stop-Process -Id $started.Id -Force -ErrorAction SilentlyContinue;return [pscustomobject]@{Status='NOT TESTED';Kind=$Kind;Reason="UI Automation could not activate wizard navigation: $($_.Exception.Message)";Pages=$pageNames.ToArray()}}};if($Kind-match'(?i)uninstall'-and$buttonName-match'(?i)^\s*&?Uninstall\s*$'){$terminalUninstallAt=$watch.Elapsed;$terminalButtonSignature=$signature};$lastSignature=$signature}
        elseif($nativeNext.Count){$buttonName=[string]$nativeNext[0].Text;$pageNames.Add($buttonName);if($Kind-match'(?i)uninstall'-and$buttonName-match'(?i)^\s*&?Uninstall\s*$'){$terminalScreenshot=Capture-StandardUserWizard $root.Handle 'standard-user-uninstall-retention-choice.png'};Invoke-StandardUserNativeButton $nativeNext[0].Handle $buttonName;if($Kind-match'(?i)uninstall'-and$buttonName-match'(?i)^\s*&?Uninstall\s*$'){$terminalUninstallAt=$watch.Elapsed;$terminalButtonSignature=$signature};$lastSignature=$signature}
      }
      Start-Sleep -Milliseconds 150
    }
    $started.Refresh();$nativeWindows=@(foreach($handle in [EBR_STD_NATIVE]::TopWindowsForProcess($started.Id)){[pscustomobject]@{Handle=('0x{0:X}'-f$handle.ToInt64());Title=[EBR_STD_NATIVE]::Text($handle);Class=[EBR_STD_NATIVE]::ClassName($handle);Visible=[EBR_STD_NATIVE]::IsWindowVisible($handle);Enabled=[EBR_STD_NATIVE]::IsWindowEnabled($handle);Bounds=[EBR_STD_NATIVE]::Bounds($handle);Controls=@(Get-StandardUserNativeControls $handle)}})
    $desktopScreenshot=Capture-StandardUserDesktop 'standard-user-wizard-not-detected-desktop.png'
    $processInfo=try{$started.Refresh();[pscustomobject]@{Id=$started.Id;HasExited=$started.HasExited;ExitCode=$(if($started.HasExited){$started.ExitCode}else{$null});SessionId=$started.SessionId;MainWindowHandle=('0x{0:X}'-f$started.MainWindowHandle.ToInt64());MainWindowTitle=$started.MainWindowTitle;Path=$started.Path}}catch{$null}
    Stop-Process -Id $started.Id -Force -ErrorAction SilentlyContinue
    [pscustomobject]@{Status='NOT TESTED';Kind=$Kind;Reason='Wizard did not expose a controllable finish page within three minutes.';Pages=$pageNames.ToArray();NativeWindows=$nativeWindows;Process=$processInfo;ProcessEnvironmentLocalAppData=$env:LOCALAPPDATA;DesktopScreenshot=$desktopScreenshot}
  }
  function Invoke-SettingsAppsUninstall([string]$UninstallerPath){
    Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop;Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop;Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop;Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    $settingsProcess=$null;$settingsRoot=$null;$names=[System.Collections.Generic.List[string]]::new();$screenshot=$null;$settingsLaunchMethods=[System.Collections.Generic.List[string]]::new();$directSettingsLaunched=$false
    try{
    $settingsLaunchErrors=[System.Collections.Generic.List[string]]::new()
    try{$settingsProcess=Start-Process -FilePath 'ms-settings:appsfeatures' -PassThru;if($settingsProcess){$settingsLaunchMethods.Add('ms-settings URI activation')}}catch{$settingsLaunchErrors.Add("URI activation: $($_.Exception.Message)")}
    if(-not$settingsProcess){try{$explorer=Join-Path $env:WINDIR 'explorer.exe';$settingsProcess=Start-Process -FilePath $explorer -ArgumentList 'ms-settings:appsfeatures' -PassThru;if($settingsProcess){$settingsLaunchMethods.Add('Explorer URI activation')}}catch{$settingsLaunchErrors.Add("Explorer URI activation: $($_.Exception.Message)")}}
    if(-not$settingsProcess-and$settingsLaunchErrors.Count){$settingsLaunchErrors.Add('Shell URI activation did not return a process handle.')}
    if(-not$settingsProcess){$settingsExe=Join-Path $env:WINDIR 'ImmersiveControlPanel\SystemSettings.exe';if(Test-Path -LiteralPath $settingsExe){try{$settingsProcess=Start-Process -FilePath $settingsExe -ArgumentList 'ms-settings:appsfeatures' -PassThru;if($settingsProcess){$directSettingsLaunched=$true;$settingsLaunchMethods.Add('direct SystemSettings.exe activation')}}catch{$settingsLaunchErrors.Add("Direct SystemSettings.exe activation: $($_.Exception.Message)")}}}
    if(-not$settingsProcess){return [pscustomobject]@{Status='NOT TESTED';Reason="Windows Settings Apps page could not be opened: $($settingsLaunchErrors -join '; ')";LaunchMethods=$settingsLaunchMethods.ToArray()}}
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
    if(-not$settingsRoot){
      $settingsExe=Join-Path $env:WINDIR 'ImmersiveControlPanel\SystemSettings.exe'
      if(-not$directSettingsLaunched-and(Test-Path -LiteralPath $settingsExe)){
        try{
          $settingsProcess=Start-Process -FilePath $settingsExe -ArgumentList 'ms-settings:appsfeatures' -PassThru
          $settingsLaunchMethods.Add('direct SystemSettings.exe activation after shell URI failed to expose Installed apps')
          $watch.Restart()
          while($watch.Elapsed.TotalSeconds-lt25-and-not$settingsRoot){
            try{$tops=[System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children,[System.Windows.Automation.Condition]::TrueCondition);foreach($top in $tops){try{$elements=@($top.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition));$currentNames=@(foreach($element in $elements){try{if($element.Current.Name){[string]$element.Current.Name}}catch{}});if(($currentNames-join'|')-match'(?i)Installed apps|Apps & features|App & features'){$settingsRoot=$top;$names.AddRange([string[]]$currentNames);break}}catch{}}}catch{}
            if(-not$settingsRoot){Start-Sleep -Milliseconds 250}
          }
        }catch{$settingsLaunchErrors.Add("Direct SystemSettings.exe activation: $($_.Exception.Message)")}
      }else{$settingsLaunchErrors.Add('Direct SystemSettings.exe was not present at the standard Windows path.')}
    }
    if(-not$settingsRoot){
      $screenshot=Capture-StandardUserDesktop 'standard-user-settings-apps-page-unavailable.png'
      $settingsProcesses=@(Get-Process -Name SystemSettings,ApplicationFrameHost -ErrorAction SilentlyContinue|Where-Object{$_.SessionId-eq[Diagnostics.Process]::GetCurrentProcess().SessionId}|ForEach-Object{[pscustomobject]@{Id=$_.Id;Name=$_.ProcessName;MainWindowHandle=('0x{0:X}' -f $_.MainWindowHandle.ToInt64());MainWindowTitle=$_.MainWindowTitle}})
      $visibleWindows=@(foreach($process in $settingsProcesses){foreach($handle in [EBR_STD_NATIVE]::TopWindowsForProcess($process.Id)){if([EBR_STD_NATIVE]::IsWindowVisible($handle)){[pscustomobject]@{ProcessId=$process.Id;ProcessName=$process.Name;Handle=('0x{0:X}' -f $handle.ToInt64());Title=[EBR_STD_NATIVE]::Text($handle);Class=[EBR_STD_NATIVE]::ClassName($handle);Bounds=[EBR_STD_NATIVE]::Bounds($handle)}}}})
      return [pscustomobject]@{Status='NOT TESTED';Reason='The disposable Windows session did not expose the Installed apps page through UI Automation, including direct SystemSettings.exe activation.';SettingsProcessId=$(if($settingsProcess){$settingsProcess.Id}else{$null});SettingsProcesses=$settingsProcesses;VisibleWindows=$visibleWindows;Screenshot=$screenshot;LaunchMethods=$settingsLaunchMethods.ToArray();LaunchErrors=$settingsLaunchErrors.ToArray()}
    }
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
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent();$userProfileInfo=Get-CimInstance Win32_UserProfile -Filter "SID='$($identity.User.Value)'" -ErrorAction Stop|Where-Object{-not$_.Special}|Select-Object -First 1
    if(-not$userProfileInfo-or-not(Test-Path -LiteralPath $userProfileInfo.LocalPath)){throw 'The disposable standard-user profile could not be resolved for its verified Windows SID.'}
    # CreateProcessWithLogon can inherit the launching administrator's environment block. Use the loaded
    # standard user's actual profile for per-user paths and for child installers launched by this process.
    $env:USERPROFILE=[IO.Path]::GetFullPath($userProfileInfo.LocalPath);$env:LOCALAPPDATA=Join-Path $env:USERPROFILE 'AppData\Local';$env:APPDATA=Join-Path $env:USERPROFILE 'AppData\Roaming'
    $env:TEMP=Join-Path $env:LOCALAPPDATA 'Temp';$env:TMP=$env:TEMP
    if(-not(Test-Path -LiteralPath $env:LOCALAPPDATA)){[void][IO.Directory]::CreateDirectory($env:LOCALAPPDATA)}
    if(-not(Test-Path -LiteralPath $env:TEMP)){[void][IO.Directory]::CreateDirectory($env:TEMP)}
    $principal=[Security.Principal.WindowsPrincipal]::new($identity)
    $isAdministrator=$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if($isAdministrator){throw 'The disposable test account unexpectedly has administrator membership.'}
    $events.Add([pscustomobject]@{Name='Child process has a standard Windows user token';Status='PASS';User=$identity.Name;Sid=$identity.User.Value;IsAdministrator=$false})
    $installer=(Resolve-Path -LiteralPath $InstallerPath).Path;$candidate=(Resolve-Path -LiteralPath $ExecutablePath).Path
    $expectedHash=(Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToLowerInvariant()
    $installDir=Join-Path $env:LOCALAPPDATA 'Programs\EyeBreakReminder';$installed=Join-Path $installDir 'EyeBreakReminder.exe';$uninstaller=Join-Path $installDir 'Uninstall.exe'
    $wizardInstall=Invoke-StandardUserWizard $installer 'standard-user interactive install wizard'
    $events.Add([pscustomobject]@{Name='Standard-user interactive installer wizard';Status=$wizardInstall.Status;Details=$wizardInstall;TokenAdministrator=$false})
    if($wizardInstall.Status-eq'PASS'){if($wizardInstall.FinishCheckbox-notmatch'(?i)^(Off|Unchecked)(?:\s+\(native Win32\))?$'){$events.Add([pscustomobject]@{Name='Standard-user installer finish-page Run checkbox state';Status='NOT TESTED';Details="Finish-page checkbox state: $($wizardInstall.FinishCheckbox)."})}else{$events.Add([pscustomobject]@{Name='Standard-user installer finish-page Run checkbox is unchecked';Status='PASS';State=$wizardInstall.FinishCheckbox})}}
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
    $startMenuShortcut=Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Eye Break Reminder\Eye Break Reminder.lnk'
    if(-not(Test-Path -LiteralPath $startMenuShortcut -PathType Leaf)){throw "The standard-user installer did not create the expected per-user Start Menu shortcut '$startMenuShortcut'."}
    $shortcutShell=$null;$shortcut=$null
    try{
      $shortcutShell=New-Object -ComObject WScript.Shell;$shortcut=$shortcutShell.CreateShortcut($startMenuShortcut)
      $shortcutTarget=[IO.Path]::GetFullPath([string]$shortcut.TargetPath);$shortcutArguments=[string]$shortcut.Arguments
      if($shortcutTarget-ine[IO.Path]::GetFullPath($installed)){throw "The standard-user Start Menu shortcut targets '$shortcutTarget', expected '$installed'."}
      if($shortcutArguments.Length-ne0){throw "The standard-user Start Menu shortcut has unexpected arguments '$shortcutArguments'."}
      $events.Add([pscustomobject]@{Name='Per-user Start Menu shortcut points exactly to the installed executable without arguments';Status='PASS';ShortcutPath=$startMenuShortcut;TargetPath=$shortcutTarget;Arguments=$shortcutArguments})
    }finally{
      if($shortcut-and[Runtime.InteropServices.Marshal]::IsComObject($shortcut)){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut)}
      if($shortcutShell-and[Runtime.InteropServices.Marshal]::IsComObject($shortcutShell)){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcutShell)}
    }
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
    $dataDir=Join-Path $env:LOCALAPPDATA 'EyeBreakReminder';[void][IO.Directory]::CreateDirectory($dataDir)
    $settingsFixturePath=Join-Path $dataDir 'settings.ini';$historyFixturePath=Join-Path $dataDir 'history.dat'
    $settingsFixture="workMinutes=37`nbreakSeconds=33`ntheme=2`nvolume=32`ncustomWorkAccent=1`nworkAccentColor=3900150`ncustomBreakAccent=1`nbreakAccentColor=16746496`nstartup=0`nautoCheckUpdates=0`nautoDownloadUpdates=0`n"
    [IO.File]::WriteAllText($settingsFixturePath,$settingsFixture,[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($historyFixturePath,"1700000000 1 20`n",[Text.UTF8Encoding]::new($false))
    $settingsFixtureHash=(Get-FileHash -LiteralPath $settingsFixturePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $historyFixtureHash=(Get-FileHash -LiteralPath $historyFixturePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $events.Add([pscustomobject]@{Name='Disposable standard-user settings and history seeded immediately before interactive uninstall';Status='PASS';SettingsSHA256=$settingsFixtureHash;HistorySHA256=$historyFixtureHash})
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
      $settingsAfterUninstall=Test-Path -LiteralPath $settingsFixturePath -PathType Leaf;$historyAfterUninstall=Test-Path -LiteralPath $historyFixturePath -PathType Leaf
      $settingsAfterHash=if($settingsAfterUninstall){(Get-FileHash -LiteralPath $settingsFixturePath -Algorithm SHA256).Hash.ToLowerInvariant()}else{''}
      $historyAfterHash=if($historyAfterUninstall){(Get-FileHash -LiteralPath $historyFixturePath -Algorithm SHA256).Hash.ToLowerInvariant()}else{''}
      $settingsPreserved=$settingsAfterUninstall-and($settingsAfterHash-ceq$settingsFixtureHash)
      $historyPreserved=$historyAfterUninstall-and($historyAfterHash-ceq$historyFixtureHash)
      if(-not$settingsPreserved-or-not$historyPreserved){throw 'Interactive standard-user uninstall did not retain its disposable settings and history byte-for-byte.'}
      $events.Add([pscustomobject]@{Name='Interactive uninstall removes the standard user installation, preserves settings/history byte-for-byte, and clears both HKCU registrations';Status='PASS';ExitCode=$wizardUninstall.ExitCode;InstallDirectoryExists=$false;UninstallRegistrationExists=$false;ApplicationRegistrationExists=$false;SettingsSHA256=$settingsFixtureHash;SettingsPreserved=$settingsPreserved;HistorySHA256=$historyFixtureHash;HistoryPreserved=$historyPreserved})
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
    $childProcess=Start-Process -FilePath $pwsh -Credential $credential -LoadUserProfile -ArgumentList $arguments -RedirectStandardOutput $childStdout -RedirectStandardError $childStderr -PassThru
    $testStarted=$true
    $credential=$null;try{$securePassword.Dispose()}catch{};$securePassword=$null
    if(-not$childProcess.WaitForExit(900000)){Stop-Process -Id $childProcess.Id -Force -ErrorAction SilentlyContinue;throw 'Standard-user test process exceeded the fifteen-minute limit.'}
    $childExitCode=$childProcess.ExitCode;$childProcess.Dispose()
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
if($resultObject.Status-in@('FAIL','BLOCKED')){exit 1}
