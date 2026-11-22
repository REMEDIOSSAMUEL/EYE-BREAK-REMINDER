param(
  [Parameter(Mandatory)][string]$InstallerPath,
  [Parameter(Mandatory)][string]$ExecutablePath,
  [Parameter(Mandatory)][string]$EvidenceDirectory,
  [switch]$Child,
  [string]$ChildResultPath,
  [switch]$DisableWholeDesktopCaptures,
  [string]$ExpectedUserSid,
  [string]$ExpectedUserName,
  [string]$RunnerEnvironmentContext,
  [string]$RunnerContextPath
)
$ErrorActionPreference='Stop'

function Save-StandardUserResult([string]$Path,$Result){
  $directory=Split-Path -Parent $Path
  if(-not(Test-Path -LiteralPath $directory)){[void][IO.Directory]::CreateDirectory($directory)}
  $Result|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $Path -Encoding utf8
}

if($Child){
  $runnerContextFromParent=$null;$runnerContextLoadError=$null
  try{
    if([string]::IsNullOrWhiteSpace($RunnerContextPath)){throw 'Parent runner-context JSON path was not provided.'}
    $runnerContextPathResolved=[IO.Path]::GetFullPath($RunnerContextPath)
    $runnerContextFromParent=Get-Content -LiteralPath $runnerContextPathResolved -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
    $contextTempRoot=[IO.Path]::GetFullPath([string]$runnerContextFromParent.RUNNER_TEMP).TrimEnd('\')+'\'
    if(-not$runnerContextPathResolved.StartsWith($contextTempRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'Runner-context JSON is outside the parent-provided RUNNER_TEMP.'}
    foreach($name in @('GITHUB_ACTIONS','GITHUB_SERVER_URL','GITHUB_REPOSITORY','GITHUB_RUN_ID','GITHUB_WORKSPACE','RUNNER_ENVIRONMENT','RUNNER_OS','RUNNER_ARCH','RUNNER_NAME','RUNNER_TEMP','ImageOS','ImageVersion','EBR_RUNNER_ENVIRONMENT_CONTEXT')){
      $property=$runnerContextFromParent.PSObject.Properties[$name]
      if($property){[Environment]::SetEnvironmentVariable($name,[string]$property.Value,'Process')}
    }
    $RunnerEnvironmentContext=[string]$runnerContextFromParent.EBR_RUNNER_ENVIRONMENT_CONTEXT
  }catch{$runnerContextLoadError=$_.Exception.Message}
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
  [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr hwnd,uint flags);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd,out uint pid);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetWindowTextW(IntPtr hwnd,StringBuilder text,int max);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr hwnd,StringBuilder text,int max);
  [DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr hwnd,uint message,IntPtr wParam,IntPtr lParam);
  [DllImport("user32.dll",SetLastError=true)] public static extern IntPtr SendMessageTimeoutW(IntPtr hwnd,uint message,IntPtr wParam,IntPtr lParam,uint flags,uint timeout,out IntPtr result);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern bool SetCursorPos(int x,int y);
  [DllImport("user32.dll")] static extern void mouse_event(uint flags,uint dx,uint dy,uint data,UIntPtr extra);
  [DllImport("user32.dll",SetLastError=true)] static extern bool GetWindowRect(IntPtr hwnd,out RECT rect);
  [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left,Top,Right,Bottom; }
  public static int[] Bounds(IntPtr hwnd){RECT r;if(!GetWindowRect(hwnd,out r))return new int[0];return new[]{r.Left,r.Top,r.Right,r.Bottom};}
  public static bool ClickAt(int x,int y){if(!SetCursorPos(x,y))return false;Thread.Sleep(80);mouse_event(0x0002,0,0,0,UIntPtr.Zero);Thread.Sleep(80);mouse_event(0x0004,0,0,0,UIntPtr.Zero);return true;}
  public static int ProcessId(IntPtr hwnd){uint pid;GetWindowThreadProcessId(hwnd,out pid);return (int)pid;}
  public static bool BelongsToWindow(IntPtr hwnd,IntPtr owner){return hwnd!=IntPtr.Zero&&owner!=IntPtr.Zero&&(hwnd==owner||GetAncestor(hwnd,3)==owner);}
  public static string Text(IntPtr hwnd){var b=new StringBuilder(512);GetWindowTextW(hwnd,b,b.Capacity);return b.ToString();}
  public static string ClassName(IntPtr hwnd){var b=new StringBuilder(128);GetClassNameW(hwnd,b,b.Capacity);return b.ToString();}
  public static IntPtr[] TopWindowsForProcess(int processId){var result=new List<IntPtr>();EnumWindows((h,d)=>{uint pid;GetWindowThreadProcessId(h,out pid);if(pid==(uint)processId)result.Add(h);return true;},IntPtr.Zero);return result.ToArray();}
  public static IntPtr[] Children(IntPtr parent){var result=new List<IntPtr>();EnumChildWindows(parent,(h,d)=>{result.Add(h);return true;},IntPtr.Zero);return result.ToArray();}
}
'@
  Add-Type -TypeDefinition $native -ErrorAction Stop
  $sessionNative=@'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
public enum EBR_STD_WTS_CONNECT_STATE { Active=0, Connected=1, ConnectQuery=2, Shadow=3, Disconnected=4, Idle=5, Listen=6, Reset=7, Down=8, Init=9 }
public sealed class EBR_STD_WTS_SESSION { public int SessionId; public string Station; public string State; }
public static class EBR_STD_SESSION_NATIVE {
  private const int UOI_NAME=2;
  private const uint DESKTOP_READOBJECTS=0x0001;
  [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] private struct WTS_SESSION_INFO { public int SessionId; [MarshalAs(UnmanagedType.LPWStr)] public string Station; public EBR_STD_WTS_CONNECT_STATE State; }
  [DllImport("kernel32.dll",SetLastError=true)] public static extern uint WTSGetActiveConsoleSessionId();
  [DllImport("wtsapi32.dll",EntryPoint="WTSEnumerateSessionsW",SetLastError=true,CharSet=CharSet.Unicode)] private static extern bool WTSEnumerateSessions(IntPtr server,int reserved,int version,out IntPtr sessions,out int count);
  [DllImport("wtsapi32.dll")] private static extern void WTSFreeMemory(IntPtr memory);
  public static EBR_STD_WTS_SESSION[] EnumerateSessions(){
    IntPtr buffer=IntPtr.Zero; int count=0;
    if(!WTSEnumerateSessions(IntPtr.Zero,0,1,out buffer,out count)) throw new Win32Exception(Marshal.GetLastWin32Error(),"WTSEnumerateSessions failed");
    try { int size=Marshal.SizeOf(typeof(WTS_SESSION_INFO)); var rows=new List<EBR_STD_WTS_SESSION>(count); for(int i=0;i<count;i++){var row=(WTS_SESSION_INFO)Marshal.PtrToStructure(IntPtr.Add(buffer,i*size),typeof(WTS_SESSION_INFO)); rows.Add(new EBR_STD_WTS_SESSION{SessionId=row.SessionId,Station=row.Station,State=row.State.ToString()});} return rows.ToArray(); }
    finally { if(buffer!=IntPtr.Zero) WTSFreeMemory(buffer); }
  }
  [DllImport("user32.dll",SetLastError=true)] private static extern IntPtr GetProcessWindowStation();
  [DllImport("user32.dll",SetLastError=true)] private static extern IntPtr GetThreadDesktop(uint threadId);
  [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
  [DllImport("user32.dll",EntryPoint="OpenInputDesktop",SetLastError=true,CharSet=CharSet.Unicode)] private static extern IntPtr OpenInputDesktop(uint flags,bool inherit,uint desiredAccess);
  [DllImport("user32.dll",SetLastError=true)] private static extern bool CloseDesktop(IntPtr desktop);
  [DllImport("user32.dll",EntryPoint="GetUserObjectInformationW",SetLastError=true,CharSet=CharSet.Unicode)] private static extern bool GetUserObjectInformation(IntPtr handle,int index,StringBuilder buffer,uint length,out uint needed);
  private static string ObjectName(IntPtr handle){if(handle==IntPtr.Zero)return null;var buffer=new StringBuilder(256);uint needed;if(!GetUserObjectInformation(handle,UOI_NAME,buffer,(uint)(buffer.Capacity*2),out needed))return "<ERROR:"+Marshal.GetLastWin32Error().ToString()+">";return buffer.ToString();}
  public static string ProcessWindowStationName(){return ObjectName(GetProcessWindowStation());}
  public static string ThreadDesktopName(){return ObjectName(GetThreadDesktop(GetCurrentThreadId()));}
  public static string InputDesktopName(){IntPtr desktop=OpenInputDesktop(0,false,DESKTOP_READOBJECTS);if(desktop==IntPtr.Zero)return "<ERROR:"+Marshal.GetLastWin32Error().ToString()+">";try{return ObjectName(desktop);}finally{CloseDesktop(desktop);}}
  [DllImport("user32.dll",EntryPoint="FindWindowW",SetLastError=true,CharSet=CharSet.Unicode)] private static extern IntPtr FindWindow(string className,string windowName);
  [DllImport("user32.dll",SetLastError=true)] private static extern uint GetWindowThreadProcessId(IntPtr window,out uint processId);
  public static IntPtr TaskbarWindow(){return FindWindow("Shell_TrayWnd",null);}
  public static uint TaskbarProcessId(IntPtr window){if(window==IntPtr.Zero)return 0;uint processId;GetWindowThreadProcessId(window,out processId);return processId;}
}
'@
  Add-Type -TypeDefinition $sessionNative -ErrorAction Stop
  $guardFailures=[System.Collections.Generic.List[string]]::new()
  $runnerContextValid=($null-ne$runnerContextFromParent-and$env:GITHUB_ACTIONS-ceq'true'-and$env:RUNNER_ENVIRONMENT-ceq'github-hosted'-and$env:RUNNER_OS-ceq'Windows'-and$env:RUNNER_ARCH-ceq'X64'-and$env:RUNNER_NAME-and$env:GITHUB_SERVER_URL-ceq'https://github.com'-and$env:GITHUB_REPOSITORY-ieq'REMEDIOSSAMUEL/EYE-BREAK-REMINDER'-and$env:GITHUB_RUN_ID-and$env:GITHUB_WORKSPACE-and$env:RUNNER_TEMP-and$env:EBR_RUNNER_ENVIRONMENT_CONTEXT-ceq'github-hosted')
  if($runnerContextLoadError){$guardFailures.Add("Parent runner context could not be loaded: $runnerContextLoadError")}
  if(-not$runnerContextValid){$guardFailures.Add('Child did not receive the validated GitHub-hosted Windows x64 runner context from its parent.')}
  $guardSessionId=-1;$guardSessionName=[string]$env:SESSIONNAME;$guardIdentity=$null;$guardIsAdministrator=$true;$guardUserInteractive=$false
  $guardActiveConsoleSessionId=[uint32]::MaxValue;$guardSessions=@();$guardConsoleSession=$null
  $guardWindowStation=$null;$guardThreadDesktop=$null;$guardInputDesktop=$null;$guardExplorer=@();$guardTaskbarHandle=[IntPtr]::Zero;$guardTaskbarProcessId=0;$guardTaskbarProcess=$null
  try {
    $guardProcess=[Diagnostics.Process]::GetCurrentProcess();$guardSessionId=[int]$guardProcess.SessionId
    $guardIdentity=[Security.Principal.WindowsIdentity]::GetCurrent();$guardPrincipal=[Security.Principal.WindowsPrincipal]::new($guardIdentity)
    $guardIsAdministrator=$guardPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $guardUserInteractive=[Environment]::UserInteractive
    $guardActiveConsoleSessionId=[EBR_STD_SESSION_NATIVE]::WTSGetActiveConsoleSessionId()
    $guardSessions=@([EBR_STD_SESSION_NATIVE]::EnumerateSessions()|ForEach-Object{[pscustomobject]@{SessionId=$_.SessionId;Station=$_.Station;State=$_.State}})
    $guardConsoleSession=@($guardSessions|Where-Object{[uint32]$_.SessionId-eq$guardActiveConsoleSessionId-and$_.Station-ieq'Console'}|Select-Object -First 1)
    if($guardConsoleSession.Count){$guardConsoleSession=$guardConsoleSession[0]}else{$guardConsoleSession=$null}
    $guardWindowStation=[EBR_STD_SESSION_NATIVE]::ProcessWindowStationName()
    $guardThreadDesktop=[EBR_STD_SESSION_NATIVE]::ThreadDesktopName()
    $guardInputDesktop=[EBR_STD_SESSION_NATIVE]::InputDesktopName()
    $guardExplorer=@(Get-Process -Name explorer -ErrorAction SilentlyContinue|Where-Object{$_.SessionId-eq$guardSessionId}|Select-Object Id,SessionId,ProcessName)
    $guardTaskbarHandle=[EBR_STD_SESSION_NATIVE]::TaskbarWindow()
    $guardTaskbarProcessId=[EBR_STD_SESSION_NATIVE]::TaskbarProcessId($guardTaskbarHandle)
    if($guardTaskbarProcessId){$guardTaskbarProcess=Get-Process -Id ([int]$guardTaskbarProcessId) -ErrorAction SilentlyContinue}
  } catch { $guardFailures.Add("Child console prelaunch probe failed: $($_.Exception.Message)") }
  $guardActiveConsoleSession=$null-ne$guardConsoleSession-and$guardConsoleSession.State-eq'Active'
  $guardProcessInActiveConsole=($guardActiveConsoleSession-and$guardSessionId-ge0-and[int64]$guardSessionId-eq[int64]$guardActiveConsoleSessionId)
  $guardWindowStationConfirmed=$guardWindowStation-ieq'WinSta0'
  $guardThreadDesktopConfirmed=$guardThreadDesktop-ieq'Default'
  $guardInputDesktopConfirmed=$guardInputDesktop-ieq'Default'
  $guardTaskbarSameSession=($guardTaskbarHandle-ne[IntPtr]::Zero-and$guardTaskbarProcess-and$guardTaskbarProcess.SessionId-eq$guardSessionId-and$guardTaskbarProcess.ProcessName-ieq'explorer')
  $guardShellSameSession=($guardExplorer.Count-gt0-and$guardTaskbarSameSession)
  if(-not$guardIdentity){$guardFailures.Add('Child Windows identity could not be established.')}
  if(-not$ExpectedUserSid){$guardFailures.Add('Parent did not pass the SID of its generated disposable account.')}
  elseif($guardIdentity-and$guardIdentity.User.Value-cne$ExpectedUserSid){$guardFailures.Add("Child SID '$($guardIdentity.User.Value)' does not match generated disposable SID '$ExpectedUserSid'.")}
  if([string]::IsNullOrWhiteSpace($ExpectedUserName)){$guardFailures.Add('Parent did not pass the generated local principal name.')}
  elseif($guardIdentity-and$guardIdentity.Name-ine$ExpectedUserName){$guardFailures.Add("Child identity '$($guardIdentity.Name)' does not match generated local principal '$ExpectedUserName'.")}
  if($guardIsAdministrator){$guardFailures.Add('Child token is an administrator.')}
  if(-not$guardActiveConsoleSession){$guardFailures.Add('The WTS active console session is not enumerated as Console/Active.')}
  if(-not$guardProcessInActiveConsole){$guardFailures.Add("Child session $guardSessionId does not match active WTS console session $guardActiveConsoleSessionId.")}
  if(-not$guardUserInteractive){$guardFailures.Add('Child Environment.UserInteractive is false.')}
  if(-not$guardWindowStationConfirmed){$guardFailures.Add("Child process window station is '$guardWindowStation', expected WinSta0.")}
  if(-not$guardThreadDesktopConfirmed){$guardFailures.Add("Child thread desktop is '$guardThreadDesktop', expected Default.")}
  if(-not$guardInputDesktopConfirmed){$guardFailures.Add("OpenInputDesktop returned '$guardInputDesktop', expected accessible Default.")}
  if(-not$guardShellSameSession){$guardFailures.Add('Explorer and the Shell_TrayWnd taskbar were not both confirmed in the child session.')}
  $childDesktopGuard=[pscustomobject]@{Status=if($guardFailures.Count){'BLOCKED'}else{'PASS'};CandidateLaunchPrevented=([bool]$guardFailures.Count);ProcessSessionId=$guardSessionId;SessionName=$guardSessionName;User=if($guardIdentity){$guardIdentity.Name}else{$null};UserSid=if($guardIdentity){$guardIdentity.User.Value}else{$null};ExpectedUserSid=$ExpectedUserSid;ExpectedUserName=$ExpectedUserName;ExpectedUserIdentityMatches=([bool]($guardIdentity-and$ExpectedUserName-and$guardIdentity.Name-ieq$ExpectedUserName));RunnerEnvironmentContext=$RunnerEnvironmentContext;RunnerContextValid=$runnerContextValid;RunnerContext=$runnerContextFromParent;RunnerContextLoadError=$runnerContextLoadError;IsAdministrator=$guardIsAdministrator;UserInteractive=$guardUserInteractive;ActiveConsoleSessionId=$guardActiveConsoleSessionId;WtsSessions=$guardSessions;MatchingConsoleSession=$guardConsoleSession;ActiveConsoleSession=$guardActiveConsoleSession;ProcessMatchesActiveConsole=$guardProcessInActiveConsole;WindowStation=$guardWindowStation;ThreadDesktop=$guardThreadDesktop;InputDesktop=$guardInputDesktop;ExplorerProcesses=$guardExplorer;TaskbarWindowHandle=if($guardTaskbarHandle-ne[IntPtr]::Zero){'0x{0:X}'-f$guardTaskbarHandle.ToInt64()}else{$null};TaskbarProcessId=$guardTaskbarProcessId;TaskbarProcessName=if($guardTaskbarProcess){$guardTaskbarProcess.ProcessName}else{$null};TaskbarProcessSessionId=if($guardTaskbarProcess){$guardTaskbarProcess.SessionId}else{$null};ExplorerAndTaskbarInChildSession=$guardShellSameSession;Failures=$guardFailures.ToArray();ObservedUtc=[DateTime]::UtcNow.ToString('o')}
  if($guardFailures.Count){
    if(-not$ChildResultPath){throw "Fail-closed console guard blocked candidate execution: $($guardFailures -join '; ')"}
    Save-StandardUserResult $ChildResultPath ([pscustomobject]@{Status='BLOCKED';Failure=$guardFailures -join '; ';CandidateExecutionStarted=$false;User=if($guardIdentity){$guardIdentity.Name}else{$null};DesktopGuard=$childDesktopGuard;Events=@([pscustomobject]@{Name='Child active-console prelaunch guard';Status='BLOCKED';Details=$childDesktopGuard});CompletedUtc=[DateTime]::UtcNow.ToString('o')})
    exit 2
  }
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
  $events.Add([pscustomobject]@{Name='Child active-console prelaunch guard';Status='PASS';Details=$childDesktopGuard})
  $events.Add([pscustomobject]@{Name='UI Automation client initializes the standard native Button provider';Status='PASS';Details=$uiaProviderBootstrap})
  function Test-StandardUserNsisTemporaryProcess($ProcessRow){
    try{
      if([IO.Path]::GetFileName([string]$ProcessRow.ExecutablePath)-cne'Un.exe'){return $false}
      $tempRoot=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'
      $fullPath=[IO.Path]::GetFullPath([string]$ProcessRow.ExecutablePath)
      if(-not$fullPath.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase)){return $false}
      $relative=$fullPath.Substring($tempRoot.Length);$parts=@($relative -split '[\\/]+')
      return ($parts.Count-eq2-and$parts[0]-match'(?i)^~nsu[^\\/]*\.tmp$'-and$parts[1]-ceq'Un.exe')
    }catch{return $false}
  }
  function Get-SettingsLaunchedUninstallerProcess([string]$ExpectedPath,[int]$SessionId,[Collections.Generic.HashSet[int]]$KnownRootIds){
    $expected=[IO.Path]::GetFullPath($ExpectedPath)
    $rows=@(Get-CimInstance Win32_Process -ErrorAction Stop|Where-Object{[int]$_.SessionId-eq$SessionId})
    $roots=@($rows|Where-Object{[IO.Path]::GetFileName([string]$_.Name)-ieq'Uninstall.exe'-and$_.ExecutablePath-and[IO.Path]::GetFullPath([string]$_.ExecutablePath)-ieq$expected})
    foreach($root in $roots){[void]$KnownRootIds.Add([int]$root.ProcessId)}
    $trusted=[Collections.Generic.HashSet[int]]::new()
    foreach($id in $KnownRootIds){[void]$trusted.Add($id)}
    $children=[Collections.Generic.List[object]]::new();$expanded=$true
    while($expanded){
      $expanded=$false
      foreach($row in $rows){
        $childProcessId=[int]$row.ProcessId
        if($trusted.Contains($childProcessId)-or-not$trusted.Contains([int]$row.ParentProcessId)){continue}
        if(Test-StandardUserNsisTemporaryProcess $row){[void]$trusted.Add($childProcessId);$children.Add($row);$expanded=$true}
      }
    }
    $candidate=if($children.Count){$children[$children.Count-1]}elseif($roots.Count){$roots[0]}else{$null}
    if(-not$candidate){return $null}
    try{[Diagnostics.Process]::GetProcessById([int]$candidate.ProcessId)}catch{$null}
  }
  function Find-StandardUserWizardWindow([int]$ProcessId,[string]$Kind){
    $processIds=[System.Collections.Generic.List[int]]::new();$processIds.Add($ProcessId)
    if($Kind-match'(?i)uninstall'){
      $rows=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{[int]$_.SessionId-eq[Diagnostics.Process]::GetCurrentProcess().SessionId})
      $trusted=[Collections.Generic.HashSet[int]]::new();[void]$trusted.Add($ProcessId);$expanded=$true
      while($expanded){
        $expanded=$false
        foreach($row in $rows){
          $childId=[int]$row.ProcessId
          if($trusted.Contains($childId)-or-not$trusted.Contains([int]$row.ParentProcessId)){continue}
          if(Test-StandardUserNsisTemporaryProcess $row){[void]$trusted.Add($childId);$processIds.Add($childId);$expanded=$true}
        }
      }
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
    if($DisableWholeDesktopCaptures){return $null}
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
    $settingsProcess=$null;$settingsRoot=$null;$settingsHost=$null;$settingsWindowHandle=[IntPtr]::Zero;$names=[System.Collections.Generic.List[string]]::new();$screenshot=$null;$settingsLaunchMethods=[System.Collections.Generic.List[string]]::new();$directSettingsLaunched=$false
    $settingsSessionId=[Diagnostics.Process]::GetCurrentProcess().SessionId
    $settingsTestUserSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;$settingsHostOwnerSidCache=@{}
    $settingsPreexistingProcessIds=[Collections.Generic.HashSet[int]]::new()
    foreach($process in @(Get-Process -Name SystemSettings,ApplicationFrameHost -ErrorAction SilentlyContinue|Where-Object{$_.SessionId-eq$settingsSessionId})){[void]$settingsPreexistingProcessIds.Add([int]$process.Id)}
    $settingsLaunchProcessIds=[Collections.Generic.HashSet[int]]::new();$settingsWindowEvidence=$null
    function Test-SettingsHostProcess([Diagnostics.Process]$Process){
      try{
        $expectedPath=switch($Process.ProcessName){
          'SystemSettings' {Join-Path $env:WINDIR 'ImmersiveControlPanel\SystemSettings.exe'}
          'ApplicationFrameHost' {Join-Path $env:WINDIR 'System32\ApplicationFrameHost.exe'}
          default {return $false}
        }
        if([IO.Path]::GetFullPath($Process.Path)-ine[IO.Path]::GetFullPath($expectedPath)){return $false}
        $ownerSid=$settingsHostOwnerSidCache[[int]$Process.Id]
        if(-not$ownerSid){
          $processRecord=Get-CimInstance Win32_Process -Filter "ProcessId=$($Process.Id)" -ErrorAction Stop
          if(-not$processRecord){return $false}
          $owner=Invoke-CimMethod -InputObject $processRecord -MethodName GetOwnerSid -ErrorAction Stop
          if($owner.ReturnValue-ne0-or[string]::IsNullOrWhiteSpace([string]$owner.Sid)){return $false}
          $ownerSid=[string]$owner.Sid;$settingsHostOwnerSidCache[[int]$Process.Id]=$ownerSid
        }
        return ($ownerSid-ceq$settingsTestUserSid)
      }catch{return $false}
    }
    function Find-SettingsAppsPageForHost($VerifiedHost){
      if($null-eq$VerifiedHost){return $null}
      $windowHandle=[IntPtr]$VerifiedHost.Handle
      if($windowHandle-eq[IntPtr]::Zero-or-not[EBR_STD_NATIVE]::IsWindowVisible($windowHandle)-or-not[EBR_STD_NATIVE]::IsWindowEnabled($windowHandle)){return $null}
      $ownerProcessId=[EBR_STD_NATIVE]::ProcessId($windowHandle)
      if($ownerProcessId-ne[int]$VerifiedHost.ProcessId){return $null}
      $owner=Get-Process -Id $ownerProcessId -ErrorAction Stop
      if($owner.SessionId-ne$settingsSessionId-or-not(Test-SettingsHostProcess $owner)){return $null}
      $root=[System.Windows.Automation.AutomationElement]::FromHandle($windowHandle)
      if($null-eq$root-or$root.Current.ControlType-ne[System.Windows.Automation.ControlType]::Window-or$root.Current.IsOffscreen-or-not$root.Current.IsEnabled){return $null}
      $elements=@($root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition))
      $installedAppsNames=@(foreach($element in $elements){try{$accessibleName=([string]$element.Current.Name).Trim();if($accessibleName-ceq'Installed apps'){$accessibleName}}catch{}})
      if($installedAppsNames.Count-eq0){return $null}
      $searchFields=@(foreach($element in $elements){try{if($element.Current.ControlType-eq[System.Windows.Automation.ControlType]::Edit-and$element.Current.Name-match'(?i)search apps|search this list'){$element}}catch{}})
      if($searchFields.Count-ne1){return $null}
      [pscustomobject]@{Root=$root;Handle=$windowHandle;ProcessId=$ownerProcessId;ProcessName=$owner.ProcessName;ProcessPath=$owner.Path;SessionId=$owner.SessionId;WindowHandle=('0x{0:X}'-f$windowHandle.ToInt64());WindowTitle=[EBR_STD_NATIVE]::Text($windowHandle);InstalledAppsTextObserved=$true;MatchingAccessibleNames=@($installedAppsNames|Select-Object -Unique);SearchFieldObserved=[pscustomobject]@{Name=[string]$searchFields[0].Current.Name;ControlType=$searchFields[0].Current.ControlType.ProgrammaticName;ProcessId=[int]$searchFields[0].Current.ProcessId;AutomationId=[string]$searchFields[0].Current.AutomationId}}
    }
    function Get-SettingsOwnedElements([System.Windows.Automation.AutomationElement]$VerifiedSettingsRoot,[Collections.Generic.HashSet[int]]$VerifiedSettingsProcessIds,[IntPtr]$VerifiedWindow){
      $owned=[Collections.Generic.List[System.Windows.Automation.AutomationElement]]::new()
      if($VerifiedSettingsRoot){
        $owned.Add($VerifiedSettingsRoot)
        foreach($element in @($VerifiedSettingsRoot.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition))){$owned.Add($element)}
      }
      $desktop=[System.Windows.Automation.AutomationElement]::RootElement
      foreach($topWindow in $desktop.FindAll([System.Windows.Automation.TreeScope]::Children,[System.Windows.Automation.Condition]::TrueCondition)){
        try{
          $windowHandle=[IntPtr]$topWindow.Current.NativeWindowHandle
          if($windowHandle-eq[IntPtr]::Zero){continue}
          if(-not[EBR_STD_NATIVE]::BelongsToWindow($windowHandle,$VerifiedWindow)){continue}
          $ownerProcessId=[EBR_STD_NATIVE]::ProcessId($windowHandle)
          if(-not$VerifiedSettingsProcessIds.Contains($ownerProcessId)){continue}
          if(-not$owned.Contains($topWindow)){$owned.Add($topWindow)}
          foreach($element in @($topWindow.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition))){if(-not$owned.Contains($element)){$owned.Add($element)}}
        }catch{}
      }
      return $owned.ToArray()
    }
    function Find-LaunchedSettingsWindow([Collections.Generic.HashSet[int]]$PreexistingProcessIds,[Collections.Generic.HashSet[int]]$LaunchProcessIds,[int]$ExpectedSessionId){
      $matches=[System.Collections.Generic.List[object]]::new()
      foreach($process in @(Get-Process -Name SystemSettings,ApplicationFrameHost -ErrorAction SilentlyContinue|Where-Object{$_.SessionId-eq$ExpectedSessionId})){
        try{
          if(-not(Test-SettingsHostProcess $process)-or$PreexistingProcessIds.Contains([int]$process.Id)){continue}
          [void]$LaunchProcessIds.Add([int]$process.Id)
          foreach($handle in [EBR_STD_NATIVE]::TopWindowsForProcess([int]$process.Id)){
            if(-not[EBR_STD_NATIVE]::IsWindowVisible($handle)-or-not[EBR_STD_NATIVE]::IsWindowEnabled($handle)){continue}
            $windowTitle=[EBR_STD_NATIVE]::Text($handle)
            $root=[System.Windows.Automation.AutomationElement]::FromHandle($handle)
            if($null-eq$root){continue}
            $current=$root.Current
            if($current.ControlType-ne[System.Windows.Automation.ControlType]::Window){continue}
            if($windowTitle-notmatch'(?i)^Settings$'-and[string]$current.Name-notmatch'(?i)^Settings$'){continue}
            $matches.Add([pscustomobject]@{Root=$root;Handle=$handle;ProcessId=[int]$process.Id;ProcessName=$process.ProcessName;ProcessPath=$process.Path;SessionId=[int]$process.SessionId;WindowTitle=$windowTitle;WindowName=[string]$current.Name;WindowClass=[EBR_STD_NATIVE]::ClassName($handle)})
          }
        }catch{}
      }
      if($matches.Count-eq1){return $matches[0]}
      if($matches.Count-gt1){throw "Multiple newly launched Settings windows matched the exact visible, enabled host criteria ($($matches.Count)); refusing ambiguous UI actions."}
      return $null
    }
    function Get-SettingsHostRecord($Host){
      if($null-eq$Host){return $null}
      [pscustomobject]@{ProcessId=$Host.ProcessId;ProcessName=$Host.ProcessName;ProcessPath=$Host.ProcessPath;SessionId=$Host.SessionId;WindowTitle=$Host.WindowTitle;WindowName=$Host.WindowName;WindowClass=$Host.WindowClass;WindowHandle=('0x{0:X}' -f ([IntPtr]$Host.Handle).ToInt64())}
    }
    function Focus-VerifiedSettingsWindow([IntPtr]$Window,[int]$ExpectedProcessId){
      $ownerPid=[EBR_STD_NATIVE]::ProcessId($Window);$owner=Get-Process -Id $ownerPid -ErrorAction Stop
      if($ownerPid-ne$ExpectedProcessId-or$owner.SessionId-ne$settingsSessionId-or-not(Test-SettingsHostProcess $owner)-or-not[EBR_STD_NATIVE]::IsWindowVisible($Window)-or-not[EBR_STD_NATIVE]::IsWindowEnabled($Window)){throw 'NOT TESTED: the Settings window failed its process, session, path, visibility, or enabled-state identity check.'}
      if(-not[EBR_STD_NATIVE]::SetForegroundWindow($Window)){throw 'NOT TESTED: Windows did not grant foreground focus to the exact Settings window.'}
      Start-Sleep -Milliseconds 150
      if([EBR_STD_NATIVE]::GetForegroundWindow()-ne$Window){throw 'NOT TESTED: the exact Settings window did not become the foreground before UI Automation or screenshot capture.'}
      return [pscustomobject]@{ProcessId=$ownerPid;SessionId=$owner.SessionId;Path=$owner.Path;WindowHandle=('0x{0:X}' -f $Window.ToInt64());ForegroundVerified=$true}
    }
    function Assert-SettingsElementForegroundFocus([System.Windows.Automation.AutomationElement]$Element,[IntPtr]$Window,[int]$ExpectedProcessId,[string]$Description){
      $windowRecord=Focus-VerifiedSettingsWindow $Window $ExpectedProcessId
      $expected=$Element.Current;$Element.SetFocus();Start-Sleep -Milliseconds 150
      $focused=[System.Windows.Automation.AutomationElement]::FocusedElement
      if($null-eq$focused){throw "NOT TESTED: UI Automation returned no focused element for $Description."}
      $observed=$focused.Current
      if(-not$observed.HasKeyboardFocus-or[int]$observed.ProcessId-ne[int]$expected.ProcessId-or[string]$observed.Name-cne[string]$expected.Name-or[string]$observed.AutomationId-cne[string]$expected.AutomationId-or$observed.ControlType-ne$expected.ControlType){throw "NOT TESTED: verified Settings keyboard focus did not resolve to the exact $Description control."}
      [pscustomobject]@{SettingsWindow=$windowRecord;Name=[string]$observed.Name;ControlType=$observed.ControlType.ProgrammaticName;AutomationId=[string]$observed.AutomationId;ProcessId=[int]$observed.ProcessId;HasKeyboardFocus=[bool]$observed.HasKeyboardFocus;NativeWindowHandle=[long]$observed.NativeWindowHandle}
    }
    function Get-SettingsTreeSnapshot([System.Windows.Automation.AutomationElement]$Root,[string]$Phase,[int]$Limit=240){
      $nodes=@($Root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition))
      $controls=@(foreach($node in ($nodes|Select-Object -First $Limit)){
        try{$current=$node.Current;[pscustomobject]@{Name=[string]$current.Name;ControlType=$current.ControlType.ProgrammaticName;AutomationId=[string]$current.AutomationId;ProcessId=[int]$current.ProcessId;Enabled=[bool]$current.IsEnabled;Offscreen=[bool]$current.IsOffscreen;NativeWindowHandle=[long]$current.NativeWindowHandle;Bounds=@($current.BoundingRectangle.Left,$current.BoundingRectangle.Top,$current.BoundingRectangle.Width,$current.BoundingRectangle.Height)}}catch{}
      })
      [pscustomobject]@{Phase=$Phase;CapturedUtc=[DateTime]::UtcNow.ToString('o');RootName=[string]$Root.Current.Name;RootHandle=('0x{0:X}' -f [long]$Root.Current.NativeWindowHandle);ObservedDescendants=$nodes.Count;RecordedDescendants=$controls.Count;Controls=$controls}
    }
    function Find-UniqueSettingsAction([System.Windows.Automation.AutomationElement]$Root,[IntPtr]$VerifiedWindow,[int]$ExpectedProcessId,[Collections.Generic.HashSet[int]]$VerifiedProcessIds,[Collections.Generic.HashSet[int]]$PreexistingProcessIds,[string[]]$ExactNames){
      $windowOwnerPid=[EBR_STD_NATIVE]::ProcessId($VerifiedWindow);$windowOwner=Get-Process -Id $windowOwnerPid -ErrorAction Stop;$windowBounds=[EBR_STD_NATIVE]::Bounds($VerifiedWindow)
      if($windowOwnerPid-ne$ExpectedProcessId-or$windowOwner.SessionId-ne$settingsSessionId-or-not(Test-SettingsHostProcess $windowOwner)-or$windowBounds.Count-ne4){throw 'NOT TESTED: the Settings window failed owner/session/path/bounds identity checks before locating a navigation action.'}
      $rootHandle=[IntPtr]$Root.Current.NativeWindowHandle
      if($rootHandle-ne$VerifiedWindow-or$Root.Current.ControlType-ne[System.Windows.Automation.ControlType]::Window){throw 'NOT TESTED: the UI Automation root is not the exact verified Settings HWND.'}
      $interactiveTypes=@([System.Windows.Automation.ControlType]::Button,[System.Windows.Automation.ControlType]::ListItem,[System.Windows.Automation.ControlType]::TreeItem,[System.Windows.Automation.ControlType]::Hyperlink,[System.Windows.Automation.ControlType]::TabItem,[System.Windows.Automation.ControlType]::MenuItem)
      $found=[System.Collections.Generic.List[System.Windows.Automation.AutomationElement]]::new()
      foreach($element in @($Root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition))){
        try{
          $current=$element.Current
          if($current.Name-notin$ExactNames-or$current.ControlType-notin$interactiveTypes-or-not$current.IsEnabled-or$current.IsOffscreen){continue}
          $controlPid=[int]$current.ProcessId
          $controlProcess=Get-Process -Id $controlPid -ErrorAction Stop
          if($controlProcess.SessionId-ne$settingsSessionId-or-not(Test-SettingsHostProcess $controlProcess)-or$PreexistingProcessIds.Contains($controlPid)){continue}
          if($controlPid-ne$ExpectedProcessId-and-not$VerifiedProcessIds.Contains($controlPid)){[void]$VerifiedProcessIds.Add($controlPid)}
          $bounds=$current.BoundingRectangle;$within=($bounds.Width-gt0-and$bounds.Height-gt0-and$bounds.Left-ge($windowBounds[0]-2)-and$bounds.Top-ge($windowBounds[1]-2)-and($bounds.Left+$bounds.Width)-le($windowBounds[2]+2)-and($bounds.Top+$bounds.Height)-le($windowBounds[3]+2))
          if(-not$within){continue}
          $found.Add($element)
        }catch{}
      }
      if($found.Count-ne1){return [pscustomobject]@{Element=$null;MatchCount=$found.Count;Matches=@(foreach($element in $found){$current=$element.Current;[pscustomobject]@{Name=[string]$current.Name;ControlType=$current.ControlType.ProgrammaticName;AutomationId=[string]$current.AutomationId;ProcessId=[int]$current.ProcessId}})}}
      $element=$found[0];$current=$element.Current
      return [pscustomobject]@{Element=$element;MatchCount=1;Matches=@([pscustomobject]@{Name=[string]$current.Name;ControlType=$current.ControlType.ProgrammaticName;AutomationId=[string]$current.AutomationId;ProcessId=[int]$current.ProcessId})}
    }
    function Test-SettingsElementInVerifiedTree([System.Windows.Automation.AutomationElement]$Element,[System.Windows.Automation.AutomationElement]$VerifiedSettingsRoot,[IntPtr]$VerifiedWindow){
      try{
        if($null-eq$Element-or$null-eq$VerifiedSettingsRoot-or$VerifiedWindow-eq[IntPtr]::Zero-or[IntPtr]$VerifiedSettingsRoot.Current.NativeWindowHandle-ne$VerifiedWindow){return $false}
        $walker=[System.Windows.Automation.TreeWalker]::RawViewWalker;$current=$Element
        for($depth=0;$depth-lt64-and$current;$depth++){
          $currentHandle=[IntPtr]$current.Current.NativeWindowHandle
          if($currentHandle-eq$VerifiedWindow){return $true}
          if($current.Current.ControlType-eq[System.Windows.Automation.ControlType]::Window-and$currentHandle-ne[IntPtr]::Zero){return [EBR_STD_NATIVE]::BelongsToWindow($currentHandle,$VerifiedWindow)}
          $current=$walker.GetParent($current)
        }
        return $false
      }catch{return $false}
    }
    function Test-SettingsElementBelongsToWindow([System.Windows.Automation.AutomationElement]$Element,[System.Windows.Automation.AutomationElement]$VerifiedSettingsRoot,[IntPtr]$VerifiedWindow,[int]$ExpectedProcessId,[Collections.Generic.HashSet[int]]$VerifiedProcessIds,[Collections.Generic.HashSet[int]]$PreexistingProcessIds){
      try{
        $windowPid=[EBR_STD_NATIVE]::ProcessId($VerifiedWindow);$windowProcess=Get-Process -Id $windowPid -ErrorAction Stop;$windowBounds=[EBR_STD_NATIVE]::Bounds($VerifiedWindow)
        if($windowPid-ne$ExpectedProcessId-or$windowProcess.SessionId-ne$settingsSessionId-or-not(Test-SettingsHostProcess $windowProcess)-or$windowBounds.Count-ne4-or-not[EBR_STD_NATIVE]::IsWindowVisible($VerifiedWindow)-or-not[EBR_STD_NATIVE]::IsWindowEnabled($VerifiedWindow)){return $false}
        if(-not(Test-SettingsElementInVerifiedTree $Element $VerifiedSettingsRoot $VerifiedWindow)){return $false}
        $current=$Element.Current
        if(-not$current.IsEnabled-or$current.IsOffscreen-or[string]::IsNullOrWhiteSpace([string]$current.Name)){return $false}
        $controlPid=[int]$current.ProcessId;$controlProcess=Get-Process -Id $controlPid -ErrorAction Stop
        if($controlProcess.SessionId-ne$settingsSessionId-or-not(Test-SettingsHostProcess $controlProcess)-or$PreexistingProcessIds.Contains($controlPid)){return $false}
        if($controlPid-ne$ExpectedProcessId-and-not$VerifiedProcessIds.Contains($controlPid)){[void]$VerifiedProcessIds.Add($controlPid)}
        $bounds=$current.BoundingRectangle
        return ($bounds.Width-gt0-and$bounds.Height-gt0-and$bounds.Left-ge($windowBounds[0]-2)-and$bounds.Top-ge($windowBounds[1]-2)-and($bounds.Left+$bounds.Width)-le($windowBounds[2]+2)-and($bounds.Top+$bounds.Height)-le($windowBounds[3]+2))
      }catch{return $false}
    }
    function Invoke-SettingsAction($Action,[System.Windows.Automation.AutomationElement]$VerifiedSettingsRoot,[IntPtr]$VerifiedWindow,[int]$ExpectedProcessId,[Collections.Generic.HashSet[int]]$VerifiedProcessIds,[Collections.Generic.HashSet[int]]$PreexistingProcessIds,[string]$Description){
      $element=$Action.Element
      if($null-eq$element){throw "NOT TESTED: no uniquely identified interactive Settings control was available for $Description."}
      $foregroundRecord=Focus-VerifiedSettingsWindow $VerifiedWindow $ExpectedProcessId
      if(-not(Test-SettingsElementBelongsToWindow $element $VerifiedSettingsRoot $VerifiedWindow $ExpectedProcessId $VerifiedProcessIds $PreexistingProcessIds)){throw "NOT TESTED: the exact UI Automation control for $Description became stale or failed its process/bounds/visibility checks before activation."}
      $current=$element.Current
      $record=[pscustomobject]@{Name=[string]$current.Name;ControlType=$current.ControlType.ProgrammaticName;AutomationId=[string]$current.AutomationId;ProcessId=[int]$current.ProcessId;WindowHandle=('0x{0:X}' -f $VerifiedWindow.ToInt64());Foreground=$foregroundRecord;Method=''}
      try{$element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke();$record.Method='UI Automation InvokePattern'}catch{
        try{$element.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select();$record.Method='UI Automation SelectionItemPattern.Select'}catch{
          $focusRecord=Assert-SettingsElementForegroundFocus $element $VerifiedWindow $ExpectedProcessId $Description
          [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
          $record.Method='UI Automation SetFocus with exact focused-element verification then real Enter key';$record.Focus=$focusRecord
        }
      }
      return $record
    }
    try{
    $settingsLaunchErrors=[System.Collections.Generic.List[string]]::new()
    try{$settingsProcess=Start-Process -FilePath 'ms-settings:' -PassThru;if($settingsProcess){[void]$settingsLaunchProcessIds.Add([int]$settingsProcess.Id);$settingsLaunchMethods.Add('Settings home URI activation')}}catch{$settingsLaunchErrors.Add("Settings home URI activation: $($_.Exception.Message)")}
    if(-not$settingsProcess){try{$explorer=Join-Path $env:WINDIR 'explorer.exe';$settingsProcess=Start-Process -FilePath $explorer -ArgumentList 'ms-settings:' -PassThru;if($settingsProcess){[void]$settingsLaunchProcessIds.Add([int]$settingsProcess.Id);$settingsLaunchMethods.Add('Explorer Settings home URI activation')}}catch{$settingsLaunchErrors.Add("Explorer Settings home URI activation: $($_.Exception.Message)")}}
    if(-not$settingsProcess-and$settingsLaunchErrors.Count){$settingsLaunchErrors.Add('Shell URI activation did not return a process handle.')}
    if(-not$settingsProcess){$settingsExe=Join-Path $env:WINDIR 'ImmersiveControlPanel\SystemSettings.exe';if(Test-Path -LiteralPath $settingsExe){try{$settingsProcess=Start-Process -FilePath $settingsExe -PassThru;if($settingsProcess){[void]$settingsLaunchProcessIds.Add([int]$settingsProcess.Id);$directSettingsLaunched=$true;$settingsLaunchMethods.Add('direct SystemSettings.exe home activation')}}catch{$settingsLaunchErrors.Add("Direct SystemSettings.exe home activation: $($_.Exception.Message)")}}}
    if(-not$settingsProcess){return [pscustomobject]@{Status='NOT TESTED';Reason="Windows Settings home could not be opened: $($settingsLaunchErrors -join '; ')";LaunchMethods=$settingsLaunchMethods.ToArray()}}
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while($watch.Elapsed.TotalSeconds-lt35-and-not$settingsHost){
      try{$settingsHost=Find-LaunchedSettingsWindow $settingsPreexistingProcessIds $settingsLaunchProcessIds $settingsSessionId;if($settingsHost){$settingsRoot=$settingsHost.Root;$settingsWindowHandle=[IntPtr]$settingsHost.Handle}}catch{}
      if(-not$settingsHost){Start-Sleep -Milliseconds 250}
    }
    if(-not$settingsHost){
      $settingsExe=Join-Path $env:WINDIR 'ImmersiveControlPanel\SystemSettings.exe'
      if(-not$directSettingsLaunched-and(Test-Path -LiteralPath $settingsExe)){
        try{
          $settingsProcess=Start-Process -FilePath $settingsExe -PassThru
          if($settingsProcess){[void]$settingsLaunchProcessIds.Add([int]$settingsProcess.Id)}
          $settingsLaunchMethods.Add('direct SystemSettings.exe home activation after shell URI failed to expose Settings')
          $watch.Restart()
          while($watch.Elapsed.TotalSeconds-lt25-and-not$settingsHost){
            try{$settingsHost=Find-LaunchedSettingsWindow $settingsPreexistingProcessIds $settingsLaunchProcessIds $settingsSessionId;if($settingsHost){$settingsRoot=$settingsHost.Root;$settingsWindowHandle=[IntPtr]$settingsHost.Handle}}catch{}
            if(-not$settingsHost){Start-Sleep -Milliseconds 250}
          }
        }catch{$settingsLaunchErrors.Add("Direct SystemSettings.exe home activation: $($_.Exception.Message)")}
      }else{$settingsLaunchErrors.Add('Direct SystemSettings.exe was not present at the standard Windows path.')}
    }
    if(-not$settingsHost){return [pscustomobject]@{Status='NOT TESTED';Reason="A newly launched Settings home window could not be identified: $($settingsLaunchErrors -join '; ')";LaunchMethods=$settingsLaunchMethods.ToArray();LaunchErrors=$settingsLaunchErrors.ToArray()}}
    if($settingsHost){
      $settingsRoot=$null
      $settingsWindowHandle=[IntPtr]$settingsHost.Handle
      $settingsWindowEvidence=$null
      $hostWatch=[Diagnostics.Stopwatch]::StartNew();$settingsHost=$null
      while($hostWatch.Elapsed.TotalSeconds-lt20-and-not$settingsHost){
        try{$settingsHost=Find-LaunchedSettingsWindow $settingsPreexistingProcessIds $settingsLaunchProcessIds $settingsSessionId}catch{$settingsLaunchErrors.Add($_.Exception.Message);break}
        if(-not$settingsHost){Start-Sleep -Milliseconds 250}
      }
      if(-not$settingsHost){
        try{
          $explorer=Join-Path $env:WINDIR 'explorer.exe'
          $homeProcess=Start-Process -FilePath $explorer -ArgumentList 'ms-settings:' -PassThru -ErrorAction Stop
          if($homeProcess){[void]$settingsLaunchProcessIds.Add([int]$homeProcess.Id);$settingsLaunchMethods.Add('Explorer activation of the Settings home page before observed Apps navigation')}
          $homeWatch=[Diagnostics.Stopwatch]::StartNew()
          while($homeWatch.Elapsed.TotalSeconds-lt20-and-not$settingsHost){
            try{$settingsHost=Find-LaunchedSettingsWindow $settingsPreexistingProcessIds $settingsLaunchProcessIds $settingsSessionId}catch{$settingsLaunchErrors.Add($_.Exception.Message);break}
            if(-not$settingsHost){Start-Sleep -Milliseconds 250}
          }
        }catch{$settingsLaunchErrors.Add("Settings home activation: $($_.Exception.Message)")}
      }
      if($settingsHost){
        $settingsRoot=$settingsHost.Root;$settingsWindowHandle=[IntPtr]$settingsHost.Handle
        $navigationEvidence=[System.Collections.Generic.List[object]]::new()
        try{$settingsHomeForeground=Focus-VerifiedSettingsWindow $settingsWindowHandle $settingsHost.ProcessId}catch{return [pscustomobject]@{Status='NOT TESTED';Reason=$_.Exception.Message;SettingsHost=(Get-SettingsHostRecord $settingsHost);LaunchMethods=$settingsLaunchMethods.ToArray()}}
        $settingsShot=Capture-StandardUserWizard $settingsWindowHandle 'standard-user-settings-home-before-apps-navigation.png'
        $navigationEvidence.Add([pscustomobject]@{Stage='Settings home before Apps navigation';Host=(Get-SettingsHostRecord $settingsHost);Foreground=$settingsHomeForeground;Screenshot=$settingsShot;Tree=(Get-SettingsTreeSnapshot $settingsRoot 'Settings home before Apps navigation')})
        $appsAction=Find-UniqueSettingsAction $settingsRoot $settingsWindowHandle $settingsHost.ProcessId $settingsLaunchProcessIds $settingsPreexistingProcessIds @('Apps')
        if($appsAction.MatchCount-ne1){
          try{
            $explorer=Join-Path $env:WINDIR 'explorer.exe';$homeProcess=Start-Process -FilePath $explorer -ArgumentList 'ms-settings:' -PassThru -ErrorAction Stop
            if($homeProcess){[void]$settingsLaunchProcessIds.Add([int]$homeProcess.Id);$settingsLaunchMethods.Add('second distinct route: Explorer activation of the Settings home URI before retrying the observed Apps action')}
            $homeWatch=[Diagnostics.Stopwatch]::StartNew();$homeSettingsHost=$null
            while($homeWatch.Elapsed.TotalSeconds-lt12-and-not$homeSettingsHost){try{$homeSettingsHost=Find-LaunchedSettingsWindow $settingsPreexistingProcessIds $settingsLaunchProcessIds $settingsSessionId}catch{break};if(-not$homeSettingsHost){Start-Sleep -Milliseconds 250}}
            if($homeSettingsHost){
              $settingsHost=$homeSettingsHost;$settingsRoot=$homeSettingsHost.Root;$settingsWindowHandle=[IntPtr]$homeSettingsHost.Handle
              try{$homeForeground=Focus-VerifiedSettingsWindow $settingsWindowHandle $settingsHost.ProcessId}catch{$navigationEvidence.Add([pscustomobject]@{Stage='Settings home foreground unavailable';Reason=$_.Exception.Message});$homeForeground=$null}
              $homeShot=Capture-StandardUserWizard $settingsWindowHandle 'standard-user-settings-home-uri-retry.png'
              $navigationEvidence.Add([pscustomobject]@{Stage='Settings home URI retry';Host=(Get-SettingsHostRecord $settingsHost);Foreground=$homeForeground;Screenshot=$homeShot;Tree=(Get-SettingsTreeSnapshot $settingsRoot 'Settings home after Explorer home-URI activation')})
              $appsAction=Find-UniqueSettingsAction $settingsRoot $settingsWindowHandle $settingsHost.ProcessId $settingsLaunchProcessIds $settingsPreexistingProcessIds @('Apps')
            }
          }catch{$navigationEvidence.Add([pscustomobject]@{Stage='Settings home URI retry failed';Error=$_.Exception.Message})}
        }
        if($appsAction.MatchCount-eq1){
          try{$appsActionRecord=Invoke-SettingsAction $appsAction $settingsRoot $settingsWindowHandle $settingsHost.ProcessId $settingsLaunchProcessIds $settingsPreexistingProcessIds 'Apps navigation'}catch{return [pscustomobject]@{Status='NOT TESTED';Reason=$_.Exception.Message;SettingsHost=(Get-SettingsHostRecord $settingsHost);NavigationEvidence=$navigationEvidence.ToArray()}}
          $navigationEvidence.Add([pscustomobject]@{Stage='Apps navigation activated';Action=$appsActionRecord})
          $installedWatch=[Diagnostics.Stopwatch]::StartNew();$installedAction=$null
          while($installedWatch.Elapsed.TotalSeconds-lt18-and(-not$installedAction-or$installedAction.MatchCount-ne1)){
            try{$settingsRoot=[System.Windows.Automation.AutomationElement]::FromHandle($settingsWindowHandle);$installedAction=Find-UniqueSettingsAction $settingsRoot $settingsWindowHandle $settingsHost.ProcessId $settingsLaunchProcessIds $settingsPreexistingProcessIds @('Installed apps')}catch{}
            if(-not$installedAction-or$installedAction.MatchCount-ne1){Start-Sleep -Milliseconds 250}
          }
          if($installedAction-and$installedAction.MatchCount-eq1){
            $navigationEvidence.Add([pscustomobject]@{Stage='Apps category after navigation';ActionCandidates=$installedAction.Matches;Tree=(Get-SettingsTreeSnapshot $settingsRoot 'Apps category after Apps navigation')})
            try{$appsForeground=Focus-VerifiedSettingsWindow $settingsWindowHandle $settingsHost.ProcessId}catch{return [pscustomobject]@{Status='NOT TESTED';Reason=$_.Exception.Message;SettingsHost=(Get-SettingsHostRecord $settingsHost);NavigationEvidence=$navigationEvidence.ToArray()}}
            $installedShot=Capture-StandardUserWizard $settingsWindowHandle 'standard-user-settings-apps-category-before-installed-apps.png'
            $navigationEvidence.Add([pscustomobject]@{Stage='Apps category before Installed apps selection';Foreground=$appsForeground;Screenshot=$installedShot})
            try{$installedActionRecord=Invoke-SettingsAction $installedAction $settingsRoot $settingsWindowHandle $settingsHost.ProcessId $settingsLaunchProcessIds $settingsPreexistingProcessIds 'Installed apps navigation'}catch{return [pscustomobject]@{Status='NOT TESTED';Reason=$_.Exception.Message;SettingsHost=(Get-SettingsHostRecord $settingsHost);NavigationEvidence=$navigationEvidence.ToArray()}}
            $navigationEvidence.Add([pscustomobject]@{Stage='Installed apps navigation activated';Action=$installedActionRecord})
            $settingsRoot=$null;$settingsWindowEvidence=$null
            $installedPageWatch=[Diagnostics.Stopwatch]::StartNew()
            while($installedPageWatch.Elapsed.TotalSeconds-lt25-and-not$settingsWindowEvidence){
              try{$settingsWindowEvidence=Find-SettingsAppsPageForHost $settingsHost;if($settingsWindowEvidence){$settingsRoot=$settingsWindowEvidence.Root;$names.AddRange([string[]]$settingsWindowEvidence.MatchingAccessibleNames)}}catch{}
              if(-not$settingsWindowEvidence){Start-Sleep -Milliseconds 250}
            }
          }else{
            $settingsRoot=[System.Windows.Automation.AutomationElement]::FromHandle($settingsWindowHandle)
            $navigationEvidence.Add([pscustomobject]@{Stage='Installed apps action not uniquely exposed after Apps navigation';ActionCandidates=if($installedAction){$installedAction.Matches}else{@()};Tree=(Get-SettingsTreeSnapshot $settingsRoot 'Apps category without a unique Installed apps action')})
          }
        }else{
          $navigationEvidence.Add([pscustomobject]@{Stage='Apps navigation not uniquely exposed';ActionCandidates=$appsAction.Matches;Tree=(Get-SettingsTreeSnapshot $settingsRoot 'Settings home with no unique Apps navigation control')})
        }
        $navigationPath=Join-Path $EvidenceDirectory 'standard-user-settings-navigation.json'
        $navigationEvidence.ToArray()|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $navigationPath -Encoding UTF8
        if($settingsRoot-and-not$settingsWindowEvidence){
          try{$settingsWindowEvidence=Find-SettingsAppsPageForHost $settingsHost}catch{}
          if($settingsWindowEvidence){$settingsRoot=$settingsWindowEvidence.Root;$names.AddRange([string[]]$settingsWindowEvidence.MatchingAccessibleNames)}
        }
        $appsNavigationRecords=@($navigationEvidence|Where-Object{$_.Stage-eq'Apps navigation activated'-and$_.Action.Name-ceq'Apps'-and$_.Action.Method})
        $installedNavigationRecords=@($navigationEvidence|Where-Object{$_.Stage-eq'Installed apps navigation activated'-and$_.Action.Name-ceq'Installed apps'-and$_.Action.Method})
        $settingsPathVerified=($appsNavigationRecords.Count-eq1-and$installedNavigationRecords.Count-eq1-and$settingsWindowEvidence-and$settingsWindowEvidence.InstalledAppsTextObserved-and$settingsWindowEvidence.SearchFieldObserved)
        if(-not$settingsPathVerified){$settingsRoot=$null}
        if(-not$settingsRoot){
          $navigationPath=Join-Path $EvidenceDirectory 'standard-user-settings-navigation.json'
          $navigationEvidencePath=if(Test-Path -LiteralPath $navigationPath){$navigationPath}else{$null}
          $finalSettingsRoot=[System.Windows.Automation.AutomationElement]::FromHandle($settingsWindowHandle)
          $finalForeground=$null;$finalScreenshot=$null
          try{$finalForeground=Focus-VerifiedSettingsWindow $settingsWindowHandle $settingsHost.ProcessId;$finalScreenshot=Capture-StandardUserWizard $settingsWindowHandle 'standard-user-settings-final-navigation-state.png'}catch{$settingsLaunchErrors.Add("Final Settings state capture: $($_.Exception.Message)")}
          $settingsDiagnostic=[pscustomobject]@{Purpose='Read-only diagnostics for actual Settings UI Automation navigation; this does not satisfy UN-009.';Host=(Get-SettingsHostRecord $settingsHost);NavigationEvidencePath=$navigationEvidencePath;FinalForeground=$finalForeground;FinalScreenshot=$finalScreenshot;FinalTree=(Get-SettingsTreeSnapshot $finalSettingsRoot 'Final Settings tree after Apps navigation attempt')}
          $settingsEvidencePath=Join-Path $EvidenceDirectory 'standard-user-settings-window-diagnostic.json'
          $settingsDiagnostic|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $settingsEvidencePath -Encoding UTF8
          return [pscustomobject]@{Status='NOT TESTED';Reason='The genuine Settings home was opened and observed, but it did not yield one enabled exact Apps/Installed apps UI action and a Settings-owned Installed apps page after the guarded UI Automation navigation attempt.';SettingsHost=(Get-SettingsHostRecord $settingsHost);InitialSettingsScreenshot=$settingsShot;FinalSettingsScreenshot=$finalScreenshot;SettingsDiagnosticPath=$settingsEvidencePath;NavigationEvidencePath=$navigationEvidencePath;LaunchMethods=$settingsLaunchMethods.ToArray();LaunchErrors=$settingsLaunchErrors.ToArray()}
        }
      }
    }
    if(-not$settingsRoot){
      $screenshot=Capture-StandardUserDesktop 'standard-user-settings-apps-page-unavailable.png'
      $settingsProcesses=@(Get-Process -Name SystemSettings,ApplicationFrameHost -ErrorAction SilentlyContinue|Where-Object{$_.SessionId-eq[Diagnostics.Process]::GetCurrentProcess().SessionId}|ForEach-Object{[pscustomobject]@{Id=$_.Id;Name=$_.ProcessName;MainWindowHandle=('0x{0:X}' -f $_.MainWindowHandle.ToInt64());MainWindowTitle=$_.MainWindowTitle}})
      $visibleWindows=@(foreach($process in $settingsProcesses){foreach($handle in [EBR_STD_NATIVE]::TopWindowsForProcess($process.Id)){if([EBR_STD_NATIVE]::IsWindowVisible($handle)){[pscustomobject]@{ProcessId=$process.Id;ProcessName=$process.Name;Handle=('0x{0:X}' -f $handle.ToInt64());Title=[EBR_STD_NATIVE]::Text($handle);Class=[EBR_STD_NATIVE]::ClassName($handle);Bounds=[EBR_STD_NATIVE]::Bounds($handle)}}}})
      $settingsAccessibilityWindows=@(
        foreach($process in @(Get-Process -Name SystemSettings,ApplicationFrameHost -ErrorAction SilentlyContinue|Where-Object{$_.SessionId-eq$settingsSessionId})){
          try{
            if(-not(Test-SettingsHostProcess $process)-or$settingsPreexistingProcessIds.Contains([int]$process.Id)){continue}
            foreach($handle in [EBR_STD_NATIVE]::TopWindowsForProcess($process.Id)){
              if(-not[EBR_STD_NATIVE]::IsWindowVisible($handle)){continue}
              $windowTitle=[EBR_STD_NATIVE]::Text($handle);$windowClass=[EBR_STD_NATIVE]::ClassName($handle)
              $uiaWindow=$null;$uiaNodes=@();$accessibleControls=@();$uiaError=''
              try{
                $uiaWindow=[System.Windows.Automation.AutomationElement]::FromHandle($handle)
                $uiaNodes=@($uiaWindow.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition))
                $accessibleControls=@(foreach($node in ($uiaNodes|Select-Object -First 160)){
                  try{$current=$node.Current;[pscustomobject]@{Name=[string]$current.Name;ControlType=$current.ControlType.ProgrammaticName;AutomationId=[string]$current.AutomationId;Enabled=[bool]$current.IsEnabled;Offscreen=[bool]$current.IsOffscreen;NativeWindowHandle=[long]$current.NativeWindowHandle;Bounds=@($current.BoundingRectangle.Left,$current.BoundingRectangle.Top,$current.BoundingRectangle.Width,$current.BoundingRectangle.Height)}}catch{}
                })
              }catch{$uiaError=$_.Exception.Message}
              $windowShot=Capture-StandardUserWizard $handle 'standard-user-settings-window-diagnostic.png'
              [pscustomobject]@{ProcessId=$process.Id;ProcessName=$process.ProcessName;ProcessPath=$process.Path;SessionId=$process.SessionId;Handle=('0x{0:X}' -f $handle.ToInt64());Title=$windowTitle;Class=$windowClass;Bounds=[EBR_STD_NATIVE]::Bounds($handle);UIAElementCount=$uiaNodes.Count;UIAError=$uiaError;AccessibleControls=$accessibleControls;TargetWindowScreenshot=$windowShot}
            }
          }catch{}
        }
      )
      $settingsWindowEvidence=[pscustomobject]@{Purpose='Read-only diagnostic evidence for a newly launched Settings host when the Installed apps page could not be identified; this does not satisfy UN-009.';PreexistingProcessIds=@($settingsPreexistingProcessIds);LaunchProcessIds=@($settingsLaunchProcessIds);Windows=$settingsAccessibilityWindows}
      $settingsEvidencePath=Join-Path $EvidenceDirectory 'standard-user-settings-window-diagnostic.json'
      $settingsWindowEvidence|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $settingsEvidencePath -Encoding UTF8
      return [pscustomobject]@{Status='NOT TESTED';Reason='A newly launched Settings host did not expose a uniquely actionable Apps > Installed apps route after actual Settings UI Automation navigation; no other window or direct uninstaller path is accepted.';SettingsProcessId=$(if($settingsProcess){$settingsProcess.Id}else{$null});SettingsProcesses=$settingsProcesses;VisibleWindows=$visibleWindows;Screenshot=$screenshot;LaunchMethods=$settingsLaunchMethods.ToArray();LaunchErrors=$settingsLaunchErrors.ToArray();SettingsWindowEvidence=$settingsWindowEvidence;SettingsDiagnosticPath=$settingsEvidencePath;NavigationEvidencePath=$(if(Test-Path -LiteralPath (Join-Path $EvidenceDirectory 'standard-user-settings-navigation.json')){Join-Path $EvidenceDirectory 'standard-user-settings-navigation.json'}else{$null});PreexistingSettingsProcessIds=@($settingsPreexistingProcessIds);LaunchProcessIds=@($settingsLaunchProcessIds)}
    }
    try{$appsWindowFocus=Focus-VerifiedSettingsWindow $settingsWindowHandle $settingsHost.ProcessId}catch{return [pscustomobject]@{Status='NOT TESTED';Reason=$_.Exception.Message;SettingsHost=(Get-SettingsHostRecord $settingsHost);SettingsWindowEvidence=$settingsWindowEvidence}}
    $screenshot=Capture-StandardUserWizard $settingsWindowHandle 'standard-user-settings-apps-before-uninstall.png'
    if(-not$screenshot-and-not$DisableWholeDesktopCaptures){$screenshot=Capture-StandardUserDesktop 'standard-user-settings-apps-before-uninstall-desktop-fallback.png'}
    $settingsProcessIds=[Collections.Generic.HashSet[int]]::new();[void]$settingsProcessIds.Add([int]$settingsHost.ProcessId)
    foreach($process in @(Get-Process -Name SystemSettings,ApplicationFrameHost -ErrorAction SilentlyContinue|Where-Object{$_.SessionId-eq$settingsSessionId})){
      try{if((Test-SettingsHostProcess $process)-and-not$settingsPreexistingProcessIds.Contains([int]$process.Id)){[void]$settingsProcessIds.Add([int]$process.Id);[void]$settingsLaunchProcessIds.Add([int]$process.Id)}}catch{}
    }
    $search=$null
    foreach($element in @($settingsRoot.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition))){try{if($element.Current.ControlType-eq[System.Windows.Automation.ControlType]::Edit-and$element.Current.Name-match'(?i)search apps|search this list'-and(Test-SettingsElementBelongsToWindow $element $settingsRoot $settingsWindowHandle $settingsHost.ProcessId $settingsProcessIds $settingsPreexistingProcessIds)){$search=$element;break}}catch{}}
    if(-not$search){return [pscustomobject]@{Status='NOT TESTED';Reason='Installed apps page has no accessible app-search field.';VisibleNames=@($names|Select-Object -Unique|Select-Object -First 80);Screenshot=$screenshot;SettingsWindowEvidence=$settingsWindowEvidence}}
    try{$searchForeground=Focus-VerifiedSettingsWindow $settingsWindowHandle $settingsHost.ProcessId}catch{return [pscustomobject]@{Status='NOT TESTED';Reason=$_.Exception.Message;Screenshot=$screenshot;SettingsWindowEvidence=$settingsWindowEvidence}}
    try{$value=$search.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern);$value.SetValue('Eye Break Reminder')}catch{try{$focusRecord=Assert-SettingsElementForegroundFocus $search $settingsWindowHandle $settingsHost.ProcessId 'Installed apps search field';[System.Windows.Forms.SendKeys]::SendWait('^a');[System.Windows.Forms.SendKeys]::SendWait('Eye Break Reminder')}catch{return [pscustomobject]@{Status='NOT TESTED';Reason="The Installed apps search field could not be set: $($_.Exception.Message)";Screenshot=$screenshot;SettingsWindowEvidence=$settingsWindowEvidence}}}
    $watch=[Diagnostics.Stopwatch]::StartNew();$appEntry=$null
    while($watch.Elapsed.TotalSeconds-lt20-and-not$appEntry){
      try{foreach($element in @($settingsRoot.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition))){try{if($element.Current.Name-match'(?i)^Eye Break Reminder$'-and$element.Current.ControlType-ne[System.Windows.Automation.ControlType]::Button-and(Test-SettingsElementBelongsToWindow $element $settingsRoot $settingsWindowHandle $settingsHost.ProcessId $settingsProcessIds $settingsPreexistingProcessIds)){$appEntry=$element;break}}catch{}}}catch{}
      if(-not$appEntry){Start-Sleep -Milliseconds 200}
    }
    if(-not$appEntry){return [pscustomobject]@{Status='NOT TESTED';Reason='The standard-user installation did not appear in the Settings > Installed apps search results.';VisibleNames=@($names|Select-Object -Unique|Select-Object -First 80);Screenshot=$screenshot;SettingsWindowEvidence=$settingsWindowEvidence}}
    $entryScreenshot=$null
    try{$entryForeground=Focus-VerifiedSettingsWindow $settingsWindowHandle $settingsHost.ProcessId;$entryHandle=[IntPtr]$settingsRoot.Current.NativeWindowHandle;$entryScreenshot=Capture-StandardUserWizard $settingsWindowHandle 'standard-user-settings-apps-eye-break-reminder-found.png'}catch{return [pscustomobject]@{Status='NOT TESTED';Reason="Could not verify/capture the exact Settings app row: $($_.Exception.Message)";Screenshot=$screenshot;SettingsWindowEvidence=$settingsWindowEvidence}}
    $menuButton=$null;$scope=$appEntry
    for($depth=0;$depth-lt7-and-not$menuButton-and$scope-ne$settingsRoot;$depth++){
      try{$controls=@($scope.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition));$matches=@($controls|Where-Object{try{$_.Current.ControlType-eq[System.Windows.Automation.ControlType]::Button-and$_.Current.Name-match'(?i)more options|more actions|options for'-and(Test-SettingsElementBelongsToWindow $_ $settingsRoot $settingsWindowHandle $settingsHost.ProcessId $settingsProcessIds $settingsPreexistingProcessIds)}catch{$false}});if($matches.Count-eq1){$menuButton=$matches[0]}}catch{}
      if(-not$menuButton){try{$scope=[System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($scope)}catch{$scope=$null};if(-not$scope-or$scope-eq[System.Windows.Automation.AutomationElement]::RootElement){break}}
    }
    if(-not$menuButton){return [pscustomobject]@{Status='NOT TESTED';Reason='The Eye Break Reminder entry exposes no accessible row-specific options button.';Screenshots=@($screenshot,$entryScreenshot);SettingsWindowEvidence=$settingsWindowEvidence}}
    try{$null=Invoke-SettingsAction ([pscustomobject]@{Element=$menuButton}) $settingsRoot $settingsWindowHandle $settingsHost.ProcessId $settingsProcessIds $settingsPreexistingProcessIds 'Eye Break Reminder row options menu'}catch{return [pscustomobject]@{Status='NOT TESTED';Reason=$_.Exception.Message;Screenshot=$screenshot;SettingsWindowEvidence=$settingsWindowEvidence}}
    $uninstallChoice=$null;$watch=[Diagnostics.Stopwatch]::StartNew()
    while($watch.Elapsed.TotalSeconds-lt10-and-not$uninstallChoice){
      foreach($process in @(Get-Process -Name SystemSettings,ApplicationFrameHost -ErrorAction SilentlyContinue|Where-Object{$_.SessionId-eq$settingsSessionId})){
        try{if((Test-SettingsHostProcess $process)-and-not$settingsPreexistingProcessIds.Contains([int]$process.Id)){[void]$settingsProcessIds.Add([int]$process.Id);[void]$settingsLaunchProcessIds.Add([int]$process.Id)}}catch{}
      }
      foreach($element in @(Get-SettingsOwnedElements $settingsRoot $settingsProcessIds $settingsWindowHandle)){try{if($element.Current.Name-match'(?i)^Uninstall$'-and$element.Current.ControlType-in@([System.Windows.Automation.ControlType]::Button,[System.Windows.Automation.ControlType]::MenuItem)-and(Test-SettingsElementBelongsToWindow $element $settingsRoot $settingsWindowHandle $settingsHost.ProcessId $settingsProcessIds $settingsPreexistingProcessIds)){$uninstallChoice=$element;break}}catch{}}
      if(-not$uninstallChoice){Start-Sleep -Milliseconds 100}
    }
    if(-not$uninstallChoice){return [pscustomobject]@{Status='NOT TESTED';Reason='The app row menu exposed no Settings-owned Uninstall action.';Screenshots=@($screenshot,$entryScreenshot);SettingsWindowEvidence=$settingsWindowEvidence;SettingsOwnedProcessIds=@($settingsProcessIds)}}
    $menuChoiceRuntime='';try{$menuChoiceRuntime=$uninstallChoice.GetRuntimeId()-join'.'}catch{}
    try{$null=Invoke-SettingsAction ([pscustomobject]@{Element=$uninstallChoice}) $settingsRoot $settingsWindowHandle $settingsHost.ProcessId $settingsProcessIds $settingsPreexistingProcessIds 'Settings > Apps > Uninstall'}catch{return [pscustomobject]@{Status='NOT TESTED';Reason=$_.Exception.Message;Screenshots=@($screenshot,$entryScreenshot);SettingsWindowEvidence=$settingsWindowEvidence;SettingsOwnedProcessIds=@($settingsProcessIds)}}
    $uninstallProcess=$null;$confirmClicks=0;$watch=[Diagnostics.Stopwatch]::StartNew();$settingsUninstallerRootIds=[Collections.Generic.HashSet[int]]::new();$settingsSessionId=[Diagnostics.Process]::GetCurrentProcess().SessionId
    while($watch.Elapsed.TotalSeconds-lt35-and-not$uninstallProcess){
      $uninstallProcess=Get-SettingsLaunchedUninstallerProcess $UninstallerPath $settingsSessionId $settingsUninstallerRootIds
      if($uninstallProcess){break}
      if($confirmClicks-eq0-and$watch.Elapsed.TotalSeconds-ge2-and$menuChoiceRuntime){
        $uiNames=[System.Collections.Generic.List[string]]::new();$confirm=$null
        foreach($element in @(Get-SettingsOwnedElements $settingsRoot $settingsProcessIds $settingsWindowHandle)){
          try{$elementName=[string]$element.Current.Name;if($elementName){$uiNames.Add($elementName)};$runtime=$element.GetRuntimeId()-join'.';if($runtime-cne$menuChoiceRuntime-and$elementName-match'(?i)^Uninstall$'-and$element.Current.ControlType-eq[System.Windows.Automation.ControlType]::Button-and(Test-SettingsElementBelongsToWindow $element $settingsRoot $settingsWindowHandle $settingsHost.ProcessId $settingsProcessIds $settingsPreexistingProcessIds)){$confirm=$element;break}}catch{}
        }
        $confirmationVisible=($uiNames.ToArray()-join'|')-match'(?i)are you sure|this app.*uninstall|uninstall.*Eye Break Reminder|Eye Break Reminder.*uninstall'
        if($confirm-and$confirmationVisible){try{$null=Invoke-SettingsAction ([pscustomobject]@{Element=$confirm}) $settingsRoot $settingsWindowHandle $settingsHost.ProcessId $settingsProcessIds $settingsPreexistingProcessIds 'Settings uninstall confirmation';$confirmClicks=1}catch{}}
      }
      Start-Sleep -Milliseconds 200
    }
    if(-not$uninstallProcess){return [pscustomobject]@{Status='NOT TESTED';Reason='Settings launched no visible per-user NSIS uninstaller within 35 seconds.';Screenshots=@($screenshot,$entryScreenshot);ConfirmationClicks=$confirmClicks;SettingsWindowEvidence=$settingsWindowEvidence;SettingsOwnedProcessIds=@($settingsProcessIds)}}
    $wizard=Invoke-StandardUserWizard $UninstallerPath 'Settings Apps interactive uninstall wizard' $uninstallProcess
    if($wizard.Status-ne'PASS'){return [pscustomobject]@{Status=$wizard.Status;Reason=$wizard.Reason;Wizard=$wizard;Screenshots=@($screenshot,$entryScreenshot);SettingsWindowEvidence=$settingsWindowEvidence;SettingsOwnedProcessIds=@($settingsProcessIds)}}
    $installDir=Join-Path $env:LOCALAPPDATA 'Programs\EyeBreakReminder';$uninstallKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder';$appKey='HKCU:\Software\EyeBreakReminder'
    if((Test-Path -LiteralPath $installDir)-or(Test-Path -LiteralPath $uninstallKey)-or(Test-Path -LiteralPath $appKey)){return [pscustomobject]@{Status='FAIL';Reason='Settings uninstall completed its wizard but left the per-user app, install directory, or HKCU registrations.';Wizard=$wizard;Screenshot=$screenshot;SettingsWindowEvidence=$settingsWindowEvidence;SettingsOwnedProcessIds=@($settingsProcessIds)}}
    [pscustomobject]@{Status='PASS';ExitCode=$wizard.ExitCode;Wizard=$wizard;InstallationRemoved=$true;HKCURegistrationsRemoved=$true;Screenshots=@($screenshot,$entryScreenshot);ConfirmationClicks=$confirmClicks;SettingsWindowEvidence=$settingsWindowEvidence;SettingsOwnedProcessIds=@($settingsProcessIds)}
    }finally{
      $settingsWindowToClose=$settingsRoot;if(-not$settingsWindowToClose-and$settingsHost){$settingsWindowToClose=$settingsHost.Root}
      if($settingsWindowToClose-and$settingsHost-and$settingsWindowHandle-ne[IntPtr]::Zero){
        try{
          $closeHandle=$settingsWindowHandle
          $closePid=[EBR_STD_NATIVE]::ProcessId($closeHandle);$closeProcess=Get-Process -Id $closePid -ErrorAction Stop
          if($closeHandle-eq[IntPtr]$settingsHost.Handle-and$closePid-eq[int]$settingsHost.ProcessId-and-not$settingsPreexistingProcessIds.Contains($closePid)-and$closeProcess.SessionId-eq$settingsSessionId-and(Test-SettingsHostProcess $closeProcess)-and[EBR_STD_NATIVE]::IsWindowVisible($closeHandle)){[System.Windows.Automation.AutomationElement]::FromHandle($closeHandle).GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close()}
        }catch{}
      }
    }
  }
  function Get-StandardUserCandidateProcesses{
    $expectedCandidate=[IO.Path]::GetFullPath($candidate)
    @(Get-CimInstance Win32_Process -ErrorAction Stop|Where-Object{
      [int]$_.SessionId-eq$guardSessionId-and
      [IO.Path]::GetFileName([string]$_.Name)-ieq'EyeBreakReminder.exe'-and
      $_.ExecutablePath-and[IO.Path]::GetFullPath([string]$_.ExecutablePath)-ieq$expectedCandidate
    })
  }
  function Remove-StandardUserFreshCandidateProfile{
    $appDataPath=Join-Path $env:LOCALAPPDATA 'EyeBreakReminder'
    if(-not(Test-Path -LiteralPath $appDataPath)){return $true}
    try{
      if((Get-StandardUserCandidateProcesses).Count){return $false}
      $localRoot=[IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd('\')+'\'
      $resolved=[IO.Path]::GetFullPath($appDataPath)
      if(-not$resolved.StartsWith($localRoot,[StringComparison]::OrdinalIgnoreCase)-or[IO.Path]::GetFileName($resolved)-cne'EyeBreakReminder'-or([IO.File]::GetAttributes($resolved)-band[IO.FileAttributes]::ReparsePoint)){return $false}
      Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
      return (-not(Test-Path -LiteralPath $resolved))
    }catch{return $false}
  }
  function Invoke-StandardUserCapabilityProbe([string]$Requirement,[string]$ScriptName,[string]$ReportName,[bool]$NeedsConsoleStation,[int]$TimeoutSeconds=480){
    $probeEvidence=Join-Path (Join-Path $EvidenceDirectory 'capability-probes') $Requirement
    [void][IO.Directory]::CreateDirectory($probeEvidence)
    $stdoutPath=Join-Path $probeEvidence ($Requirement.ToLowerInvariant()+'-stdout.log')
    $stderrPath=Join-Path $probeEvidence ($Requirement.ToLowerInvariant()+'-stderr.log')
    $reportPath=Join-Path $probeEvidence $ReportName
    $resultStatus='BLOCKED';$reason='';$exitCode=$null;$report=$null;$processTreeExited=$true
    $appDataPath=Join-Path $env:LOCALAPPDATA 'EyeBreakReminder'
    $profileAbsentBeforeProbe=(-not(Test-Path -LiteralPath $appDataPath))
    $preexistingCandidate=@(Get-StandardUserCandidateProcesses)
    if(-not$script:capabilityProbeChainClean){$reason='A previous optional probe left an app profile or candidate process; this probe was not launched.'}
    elseif(Test-Path -LiteralPath $appDataPath){$reason='Fresh standard-user app-data profile was not empty before this probe.';$script:capabilityProbeChainClean=$false}
    elseif($preexistingCandidate.Count){$reason='An exact-candidate process already existed in the validated user session before this probe.';$script:capabilityProbeChainClean=$false}
    else{
      $probeScript=Join-Path (Join-Path $stageRoot 'probes') $ScriptName
      if(-not(Test-Path -LiteralPath $probeScript -PathType Leaf)){$reason='Staged optional probe script is missing.'}
      else{
        $arguments=[Collections.Generic.List[string]]::new()
        foreach($argument in @('-NoProfile','-ExecutionPolicy','Bypass','-File',$probeScript,'-ExecutablePath',$candidate,'-EvidenceDirectory',$probeEvidence,'-ServerConsoleSession','-ExpectedSessionId',[string]$guardSessionId,'-ExpectedUser',[string]$guardIdentity.Name)){$arguments.Add($argument)}
        if($NeedsConsoleStation){$arguments.Add('-ExpectedSessionName');$arguments.Add('Console')}
        $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=Join-Path $PSHOME 'pwsh.exe';$psi.WorkingDirectory=$stageRoot;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
        foreach($argument in $arguments){$psi.ArgumentList.Add($argument)}
        $probeProcess=[Diagnostics.Process]::new();$probeProcess.StartInfo=$psi
        try{
          if(-not$probeProcess.Start()){throw 'Could not start the separate optional probe process.'}
          $stdoutTask=$probeProcess.StandardOutput.ReadToEndAsync();$stderrTask=$probeProcess.StandardError.ReadToEndAsync()
          if(-not$probeProcess.WaitForExit($TimeoutSeconds*1000)){
            try{$probeProcess.Kill($true)}catch{}
            [void]$probeProcess.WaitForExit(10000);$processTreeExited=$probeProcess.HasExited
            $reason="Probe exceeded its $TimeoutSeconds-second limit; its owned process tree was terminated."
          }else{$exitCode=$probeProcess.ExitCode}
          $stdoutText=$stdoutTask.GetAwaiter().GetResult();$stderrText=$stderrTask.GetAwaiter().GetResult()
          [IO.File]::WriteAllText($stdoutPath,$stdoutText,[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($stderrPath,$stderrText,[Text.UTF8Encoding]::new($false))
          if(Test-Path -LiteralPath $reportPath){try{$report=Get-Content -LiteralPath $reportPath -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop}catch{$reason="Probe report was not valid JSON: $($_.Exception.Message)"}}
          if($processTreeExited-and$null-ne$report-and$report.Status-in@('PASS','FAIL','BLOCKED','NOT TESTED')){
            $resultStatus=[string]$report.Status
            if($exitCode-ne0-and$resultStatus-eq'PASS'){$resultStatus='FAIL';$reason='Probe report claimed PASS but its process returned a nonzero exit code.'}
            elseif($exitCode-eq0-and$resultStatus-ne'PASS'){$reason='Probe completed without an acceptance PASS; see the report for its actual status.'}
          }elseif(-not$reason){$reason='Probe did not produce a recognized JSON result and exit status.'}
        }catch{$reason="Probe process could not be completed: $($_.Exception.Message)"}
        finally{if($probeProcess){$probeProcess.Dispose()}}
      }
    }
    $postProcesses=@();try{$postProcesses=@(Get-StandardUserCandidateProcesses)}catch{$processTreeExited=$false;$reason=if($reason){$reason+'; '}else{''}+'could not verify exact-candidate process cleanup: '+$_.Exception.Message}
    $profilePresent=Test-Path -LiteralPath $appDataPath
    $script:capabilityProbeChainClean=($processTreeExited-and$postProcesses.Count-eq0-and-not$profilePresent)
    if(-not$script:capabilityProbeChainClean){
      if($postProcesses.Count){
        foreach($row in $postProcesses){try{Stop-Process -Id ([int]$row.ProcessId) -Force -ErrorAction Stop}catch{}}
        Start-Sleep -Milliseconds 250
      }
      $profileRemoved=Remove-StandardUserFreshCandidateProfile
      $remainingProcesses=@();try{$remainingProcesses=@(Get-StandardUserCandidateProcesses)}catch{}
      if(-not$profileRemoved-or$remainingProcesses.Count-or-not$processTreeExited){$reason=if($reason){$reason+'; '}else{''}+'probe cleanup left an exact-candidate process or fresh profile that could not be safely cleared.';$resultStatus='FAIL'}
      else{$reason=if($reason){$reason+'; '}else{''}+'probe cleanup left residual state; it was safely removed and later probes were skipped to preserve fresh-profile guarantees.';if($resultStatus-eq'PASS'){$resultStatus='FAIL'}}
    }
    $script:capabilityProbeResults.Add([pscustomobject]@{Requirement=$Requirement;Status=$resultStatus;Reason=$reason;Script=$ScriptName;ReportPath=$reportPath;ReportStatus=if($report){$report.Status}else{$null};ExitCode=$exitCode;TimedOut=($reason-match'exceeded its .* limit');SeparateProcessExited=$processTreeExited;FreshProfileBeforeLaunch=$profileAbsentBeforeProbe;NoExactCandidateProcessBeforeLaunch=(-not$preexistingCandidate.Count);CandidateProcessesAfter=@($postProcesses|Select-Object ProcessId,Name,ExecutablePath,SessionId);ProfileAbsentAfterCleanup=(-not(Test-Path -LiteralPath $appDataPath));EvidenceDirectory=$probeEvidence})
  }
  try{
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent();$userProfileInfo=Get-CimInstance Win32_UserProfile -Filter "SID='$($identity.User.Value)'" -ErrorAction Stop|Where-Object{-not$_.Special}|Select-Object -First 1
    $userProfilePath=$null;$userProfilePathSource=$null
    if($userProfileInfo-and-not[string]::IsNullOrWhiteSpace([string]$userProfileInfo.LocalPath)){
      $userProfilePath=[Environment]::ExpandEnvironmentVariables([string]$userProfileInfo.LocalPath)
      $userProfilePathSource='Win32_UserProfile.LocalPath'
    }
    if([string]::IsNullOrWhiteSpace($userProfilePath)){
      $profileListKey="HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($identity.User.Value)"
      $profileListEntry=Get-ItemProperty -LiteralPath $profileListKey -ErrorAction SilentlyContinue
      if($profileListEntry-and-not[string]::IsNullOrWhiteSpace([string]$profileListEntry.ProfileImagePath)){
        $userProfilePath=[Environment]::ExpandEnvironmentVariables([string]$profileListEntry.ProfileImagePath)
        $userProfilePathSource='SID-matched ProfileList.ProfileImagePath'
      }
    }
    if([string]::IsNullOrWhiteSpace($userProfilePath)-or-not(Test-Path -LiteralPath $userProfilePath -PathType Container)){
      throw "The disposable standard-user profile path could not be resolved from the verified SID (WMI path '$($userProfileInfo.LocalPath)', ProfileList path '$($profileListEntry.ProfileImagePath)')."
    }
    $userProfilePath=[IO.Path]::GetFullPath($userProfilePath)
    $expectedProfileName=if($ExpectedUserName){($ExpectedUserName -split '\\')[-1]}else{$null}
    if(-not$expectedProfileName-or[IO.Path]::GetFileName($userProfilePath)-ine$expectedProfileName){throw "Resolved profile '$userProfilePath' does not belong to the expected disposable user '$ExpectedUserName'."}
    # CreateProcessWithLogon can inherit the launching administrator's environment block. Use the loaded
    # standard user's actual profile for per-user paths and for child installers launched by this process.
    $env:USERPROFILE=$userProfilePath;$env:LOCALAPPDATA=Join-Path $env:USERPROFILE 'AppData\Local';$env:APPDATA=Join-Path $env:USERPROFILE 'AppData\Roaming'
    $env:TEMP=Join-Path $env:LOCALAPPDATA 'Temp';$env:TMP=$env:TEMP
    if(-not(Test-Path -LiteralPath $env:LOCALAPPDATA)){[void][IO.Directory]::CreateDirectory($env:LOCALAPPDATA)}
    if(-not(Test-Path -LiteralPath $env:TEMP)){[void][IO.Directory]::CreateDirectory($env:TEMP)}
    $principal=[Security.Principal.WindowsPrincipal]::new($identity)
    $isAdministrator=$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if($isAdministrator){throw 'The disposable test account unexpectedly has administrator membership.'}
    $events.Add([pscustomobject]@{Name='Child process has a standard Windows user token';Status='PASS';User=$identity.Name;Sid=$identity.User.Value;IsAdministrator=$false;ProfilePathSource=$userProfilePathSource;ProfilePath=$env:USERPROFILE})
    $stageRoot=[IO.Path]::GetFullPath((Split-Path -Parent $PSCommandPath))
    $runnerTempRoot=[IO.Path]::GetFullPath([string]$env:RUNNER_TEMP).TrimEnd('\')+'\'
    if(-not$stageRoot.StartsWith($runnerTempRoot,[StringComparison]::OrdinalIgnoreCase)){throw "The disposable child script is outside the verified RUNNER_TEMP root: '$stageRoot'."}
    $events.Add([pscustomobject]@{Name='Child test staging root resolves from its own script path';Status='PASS';StageRoot=$stageRoot;RunnerTemp=$runnerTempRoot})
    foreach($requiredPath in @([pscustomobject]@{Name='installer';Path=$InstallerPath},[pscustomobject]@{Name='candidate executable';Path=$ExecutablePath},[pscustomobject]@{Name='evidence directory';Path=$EvidenceDirectory},[pscustomobject]@{Name='child result';Path=$ChildResultPath})){
      if([string]::IsNullOrWhiteSpace([string]$requiredPath.Path)){throw "The standard-user child received an empty $($requiredPath.Name) path."}
    }
    if(-not(Test-Path -LiteralPath $InstallerPath -PathType Leaf)){throw "The standard-user child cannot find its staged installer '$InstallerPath'."}
    if(-not(Test-Path -LiteralPath $ExecutablePath -PathType Leaf)){throw "The standard-user child cannot find its staged candidate executable '$ExecutablePath'."}
    if(-not(Test-Path -LiteralPath $EvidenceDirectory -PathType Container)){throw "The standard-user child cannot find its staged evidence directory '$EvidenceDirectory'."}
    $installer=(Resolve-Path -LiteralPath $InstallerPath).Path;$candidate=(Resolve-Path -LiteralPath $ExecutablePath).Path
    $expectedHash=(Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToLowerInvariant()
    $script:capabilityProbeResults=[System.Collections.Generic.List[object]]::new();$script:capabilityProbeChainClean=$true
    Invoke-StandardUserCapabilityProbe 'REG-008' 'windows_candidate_audio_loopback_acceptance.ps1' 'reg-008-audio-loopback-results.json' $true 480
    # Run Shell before Narrator because Narrator can leave a cursor-highlight
    # overlay that the Shell probe correctly treats as an obstruction.
    Invoke-StandardUserCapabilityProbe 'ENV-009' 'windows_shell_notification_acceptance.ps1' 'env-009-shell-notification-results.json' $true 480
    Invoke-StandardUserCapabilityProbe 'GUI-016' 'windows_narrator_speech_recap_acceptance.ps1' 'gui-016-narrator-speech-recap.json' $false 480
    foreach($probeResult in $script:capabilityProbeResults){$events.Add([pscustomobject]@{Name="Optional pre-install capability probe $($probeResult.Requirement)";Status=$probeResult.Status;Details=$probeResult})}
    if((Get-StandardUserCandidateProcesses).Count-or(Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'EyeBreakReminder'))){
      if(-not(Remove-StandardUserFreshCandidateProfile)-or(Get-StandardUserCandidateProcesses).Count){throw 'Optional probe cleanup could not restore a fresh standard-user profile before the Settings uninstall acceptance.'}
      $events.Add([pscustomobject]@{Name='Optional probes restore clean candidate process and profile state before Settings uninstall';Status='PASS';Details='Residual data from pre-install probes was removed only from the newly created standard-user EyeBreakReminder profile after verifying the staged candidate had exited.'})
    }else{$events.Add([pscustomobject]@{Name='Optional probes restore clean candidate process and profile state before Settings uninstall';Status='PASS';Details='No exact staged-candidate process or EyeBreakReminder profile remained after the probes.'})}
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
    function Get-InstalledCandidateLaunchSnapshot([switch]$CaptureScreenshots){
      $expectedPath=[IO.Path]::GetFullPath($installed);$expectedSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;$expectedSession=[int]$guardSessionId
      $candidateRows=@(Get-StandardUserCandidateProcesses);$processSnapshots=[System.Collections.Generic.List[object]]::new()
      foreach($candidateRow in $candidateRows){
        $processId=[int]$candidateRow.ProcessId;$ownerSid=$null;$ownerError=$null;$liveRow=$null
        try{
          $liveRow=Get-CimInstance Win32_Process -Filter "ProcessId=$processId" -ErrorAction Stop
          if(-not$liveRow-or-not$liveRow.ExecutablePath-or[IO.Path]::GetFullPath([string]$liveRow.ExecutablePath)-ine$expectedPath){throw 'The process path no longer matches the exact installed candidate.'}
          $owner=Invoke-CimMethod -InputObject $liveRow -MethodName GetOwnerSid -ErrorAction Stop
          if($owner.ReturnValue-ne0-or[string]::IsNullOrWhiteSpace([string]$owner.Sid)){throw "Could not verify candidate owner SID (return=$($owner.ReturnValue))."}
          $ownerSid=[string]$owner.Sid
        }catch{$ownerError=$_.Exception.Message}
        $candidatePath=[string]$candidateRow.ExecutablePath;$exactPath=($candidatePath-and[IO.Path]::GetFullPath($candidatePath)-ieq$expectedPath)
        $processSession=[int]$candidateRow.SessionId;$sessionMatches=($processSession-eq$expectedSession)
        $ownerMatches=($ownerSid-ceq$expectedSid);$process=$null;$mainHandle=[IntPtr]::Zero;$mainTitle='';$processExited=$true
        try{$process=Get-Process -Id $processId -ErrorAction Stop;$process.Refresh();$processExited=[bool]$process.HasExited;if(-not$processExited){$mainHandle=[IntPtr]$process.MainWindowHandle;$mainTitle=[string]$process.MainWindowTitle}}catch{$ownerError=if($ownerError){$ownerError+'; '}else{''}+$_.Exception.Message}
        $windowSnapshots=[System.Collections.Generic.List[object]]::new()
        if($process-and-not$processExited){foreach($window in [EBR_STD_NATIVE]::TopWindowsForProcess($processId)){
          if([EBR_STD_NATIVE]::ProcessId($window)-ne$processId){continue}
          $visible=[EBR_STD_NATIVE]::IsWindowVisible($window);$enabled=[EBR_STD_NATIVE]::IsWindowEnabled($window);$windowTitle=[EBR_STD_NATIVE]::Text($window);$windowClass=[EBR_STD_NATIVE]::ClassName($window);$bounds=[EBR_STD_NATIVE]::Bounds($window);$isMain=($window-eq$mainHandle);$screenshot=$null
          if($CaptureScreenshots-and$visible){$suffix=([long]$window.ToInt64()).ToString('X');$screenshot=Capture-StandardUserWizard $window ("standard-user-installed-candidate-{0}-{1}.png"-f$processId,$suffix)}
          $controls=@(Get-StandardUserNativeControls $window)
          $windowSnapshots.Add([pscustomobject]@{Handle=('0x{0:X}'-f$window.ToInt64());ProcessId=$processId;Title=$windowTitle;Class=$windowClass;Visible=$visible;Enabled=$enabled;IsProcessMainWindow=$isMain;Bounds=$bounds;NativeControls=$controls;Screenshot=$screenshot})
        }}
        $mainWindowRows=@($windowSnapshots|Where-Object{$_.IsProcessMainWindow});$mainWindowVisible=($mainHandle-ne[IntPtr]::Zero-and$mainWindowRows.Count-eq1-and$mainWindowRows[0].Visible)
        $identityAndPathVerified=($exactPath-and$sessionMatches-and$ownerMatches-and-not$processExited)
        $processSnapshots.Add([pscustomobject]@{ProcessId=$processId;ProcessName=[string]$candidateRow.Name;ExecutablePath=$candidatePath;ExactPathVerified=$exactPath;SessionId=$processSession;ExpectedSessionId=$expectedSession;SessionVerified=$sessionMatches;UserSid=$ownerSid;ExpectedUserSid=$expectedSid;UserIdentityVerified=$ownerMatches;OwnerQueryError=$ownerError;ProcessExited=$processExited;MainWindowHandle=if($mainHandle-ne[IntPtr]::Zero){'0x{0:X}'-f$mainHandle.ToInt64()}else{'0x0'};MainWindowTitle=$mainTitle;MainWindowVisible=$mainWindowVisible;TopLevelWindows=$windowSnapshots.ToArray();LaunchIdentityAndWindowVerified=($identityAndPathVerified-and$mainWindowVisible)})
      }
      $qualified=@($processSnapshots|Where-Object{$_.LaunchIdentityAndWindowVerified})
      [pscustomobject]@{ExpectedExecutable=$expectedPath;ExpectedUserSid=$expectedSid;ExpectedSessionId=$expectedSession;CandidateProcessCount=$candidateRows.Count;UniqueVisibleInstalledCandidateProcess=($candidateRows.Count-eq1-and$qualified.Count-eq1);Processes=$processSnapshots.ToArray();VisibleCandidateWindowCount=@($processSnapshots|ForEach-Object{$_.TopLevelWindows}|Where-Object{$_.Visible}).Count;CapturedUtc=[DateTime]::UtcNow.ToString('o')}
    }
    $launchSource='interactive installer Finish action';$launchAttemptProcessId=$null;$launchWatch=[Diagnostics.Stopwatch]::StartNew();$launchSnapshot=Get-InstalledCandidateLaunchSnapshot
    while(-not$launchSnapshot.UniqueVisibleInstalledCandidateProcess-and$launchWatch.Elapsed.TotalSeconds-lt4){Start-Sleep -Milliseconds 150;$launchSnapshot=Get-InstalledCandidateLaunchSnapshot}
    if(-not$launchSnapshot.UniqueVisibleInstalledCandidateProcess){
      if($launchSnapshot.CandidateProcessCount){
        $unverifiedProcesses=@($launchSnapshot.Processes|Where-Object{-not$_.LaunchIdentityAndWindowVerified-and(-not$_.UserIdentityVerified-or-not$_.ExactPathVerified-or-not$_.SessionVerified)})
        if($unverifiedProcesses.Count){$events.Add([pscustomobject]@{Name='Installed candidate launch pre-existing process diagnostic';Status='NOT TESTED';Details=$launchSnapshot});throw 'An exact-path candidate process existed after installer Finish but its test-user/session ownership was not fully verified; it was left untouched.'}
        foreach($candidateProcess in $launchSnapshot.Processes){if($candidateProcess.LaunchIdentityAndWindowVerified-or($candidateProcess.ExactPathVerified-and$candidateProcess.SessionVerified-and$candidateProcess.UserIdentityVerified-and-not$candidateProcess.ProcessExited)){Stop-Process -Id ([int]$candidateProcess.ProcessId) -Force -ErrorAction Stop}}
        $cleanupWatch=[Diagnostics.Stopwatch]::StartNew();while((Get-StandardUserCandidateProcesses).Count-and$cleanupWatch.Elapsed.TotalSeconds-lt5){Start-Sleep -Milliseconds 100}
        if((Get-StandardUserCandidateProcesses).Count){$launchSnapshot=Get-InstalledCandidateLaunchSnapshot -CaptureScreenshots;$events.Add([pscustomobject]@{Name='Installed candidate launch pre-existing process cleanup diagnostic';Status='NOT TESTED';Details=$launchSnapshot});throw 'An exact candidate process could not be cleared safely before the explicit installed-image launch.'}
      }
      $launchSource='explicit installed executable launch after exact-profile process cleanup'
      $appProcess=Start-Process -FilePath $installed -PassThru;$launchAttemptProcessId=[int]$appProcess.Id
      $windowWatch=[Diagnostics.Stopwatch]::StartNew();$launchSnapshot=Get-InstalledCandidateLaunchSnapshot
      while(-not$launchSnapshot.UniqueVisibleInstalledCandidateProcess-and$windowWatch.Elapsed.TotalSeconds-lt15){Start-Sleep -Milliseconds 100;$launchSnapshot=Get-InstalledCandidateLaunchSnapshot}
    }
    $launchSnapshot=Get-InstalledCandidateLaunchSnapshot -CaptureScreenshots
    if(-not$launchSnapshot.UniqueVisibleInstalledCandidateProcess){$events.Add([pscustomobject]@{Name='Installed candidate visible-window launch diagnostics';Status='NOT TESTED';LaunchSource=$launchSource;LaunchAttemptProcessId=$launchAttemptProcessId;Details=$launchSnapshot});throw 'No unique visible main window from the exact installed executable in the active standard-user session was proven; diagnostic process/window evidence was retained.'}
    $verifiedLaunchProcess=$launchSnapshot.Processes[0];$appProcess=Get-Process -Id ([int]$verifiedLaunchProcess.ProcessId) -ErrorAction Stop;$appProcess.Refresh()
    $verifiedScreenshot=@($verifiedLaunchProcess.TopLevelWindows|Where-Object{$_.IsProcessMainWindow-and$_.Visible-and$_.Screenshot})
    if($verifiedScreenshot.Count-ne1-or-not(Test-Path -LiteralPath $verifiedScreenshot[0].Screenshot -PathType Leaf)){$events.Add([pscustomobject]@{Name='Installed candidate visible-window launch diagnostics';Status='NOT TESTED';LaunchSource=$launchSource;LaunchAttemptProcessId=$launchAttemptProcessId;Details=$launchSnapshot});throw 'The exact installed candidate window was visible but no fresh bounded screenshot could be retained.'}
    $events.Add([pscustomobject]@{Name='Installed candidate launches with a visible window under the standard account';Status='PASS';LaunchSource=$launchSource;Pid=$appProcess.Id;Title=$verifiedLaunchProcess.MainWindowTitle;MainWindowHandle=$verifiedLaunchProcess.MainWindowHandle;ExecutablePath=$verifiedLaunchProcess.ExecutablePath;SHA256=$expectedHash;SessionId=$verifiedLaunchProcess.SessionId;UserSid=$verifiedLaunchProcess.UserSid;Screenshot=$verifiedScreenshot[0].Screenshot;TopLevelWindows=$verifiedLaunchProcess.TopLevelWindows})
    Stop-Process -Id $appProcess.Id -Force -ErrorAction SilentlyContinue;$appProcess=$null
    $closeWatch=[Diagnostics.Stopwatch]::StartNew();while((Get-StandardUserCandidateProcesses).Count-and$closeWatch.Elapsed.TotalSeconds-lt5){Start-Sleep -Milliseconds 100}
    if((Get-StandardUserCandidateProcesses).Count){$events.Add([pscustomobject]@{Name='Installed candidate process cleanup after visible-window verification';Status='NOT TESTED';Details=(Get-InstalledCandidateLaunchSnapshot -CaptureScreenshots)});throw 'Verified installed candidate process remained after bounded launch observation; Settings uninstall did not proceed.'}
    $settingsUninstallData=Join-Path $env:LOCALAPPDATA 'EyeBreakReminder';[void][IO.Directory]::CreateDirectory($settingsUninstallData)
    $settingsUninstallSettings=Join-Path $settingsUninstallData 'settings.ini';$settingsUninstallHistory=Join-Path $settingsUninstallData 'history.dat';$settingsUninstallUnrelated=Join-Path $settingsUninstallData 'user-not-owned.txt'
    $settingsUninstallSettingsText="workMinutes=37`nbreakSeconds=33`ntheme=2`nvolume=32`ncustomWorkAccent=1`nworkAccentColor=3900150`ncustomBreakAccent=1`nbreakAccentColor=16746496`nstartup=0`nautoCheckUpdates=0`nautoDownloadUpdates=0`n"
    $settingsUninstallHistoryText="1700000000 1 20`n";$settingsUninstallUnrelatedText='unrelated disposable test document'
    [IO.File]::WriteAllText($settingsUninstallSettings,$settingsUninstallSettingsText,[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($settingsUninstallHistory,$settingsUninstallHistoryText,[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($settingsUninstallUnrelated,$settingsUninstallUnrelatedText,[Text.UTF8Encoding]::new($false))
    $settingsUninstallDataHashes=[pscustomobject]@{Settings=(Get-FileHash -LiteralPath $settingsUninstallSettings -Algorithm SHA256).Hash.ToLowerInvariant();History=(Get-FileHash -LiteralPath $settingsUninstallHistory -Algorithm SHA256).Hash.ToLowerInvariant();Unrelated=(Get-FileHash -LiteralPath $settingsUninstallUnrelated -Algorithm SHA256).Hash.ToLowerInvariant()}
    $events.Add([pscustomobject]@{Name='Seed disposable settings, history, and unrelated file before Settings uninstall';Status='PASS';Hashes=$settingsUninstallDataHashes})
    $settingsUninstall=Invoke-SettingsAppsUninstall $uninstaller
    $events.Add([pscustomobject]@{Name='Windows Settings > Apps uninstalls the standard-user candidate';Status=$settingsUninstall.Status;Details=$settingsUninstall;TokenAdministrator=$false})
    if($settingsUninstall.Status-eq'PASS'){
      $settingsAfter=Test-Path -LiteralPath $settingsUninstallSettings -PathType Leaf;$historyAfter=Test-Path -LiteralPath $settingsUninstallHistory -PathType Leaf;$unrelatedAfter=Test-Path -LiteralPath $settingsUninstallUnrelated -PathType Leaf
      $settingsAfterHash=if($settingsAfter){(Get-FileHash -LiteralPath $settingsUninstallSettings -Algorithm SHA256).Hash.ToLowerInvariant()}else{''};$historyAfterHash=if($historyAfter){(Get-FileHash -LiteralPath $settingsUninstallHistory -Algorithm SHA256).Hash.ToLowerInvariant()}else{''};$unrelatedAfterHash=if($unrelatedAfter){(Get-FileHash -LiteralPath $settingsUninstallUnrelated -Algorithm SHA256).Hash.ToLowerInvariant()}else{''}
      $retained=$settingsAfter-and$historyAfter-and$unrelatedAfter-and$settingsAfterHash-ceq$settingsUninstallDataHashes.Settings-and$historyAfterHash-ceq$settingsUninstallDataHashes.History-and$unrelatedAfterHash-ceq$settingsUninstallDataHashes.Unrelated
      if(-not$retained){$events.Add([pscustomobject]@{Name='Windows Settings uninstall preserves settings/history and unrelated file byte-for-byte';Status='FAIL';SettingsExists=$settingsAfter;HistoryExists=$historyAfter;UnrelatedExists=$unrelatedAfter;SettingsSHA256=$settingsAfterHash;HistorySHA256=$historyAfterHash;UnrelatedSHA256=$unrelatedAfterHash;ExpectedHashes=$settingsUninstallDataHashes;DataRetentionChoice=$settingsUninstall.Wizard.DataRetentionChoice});throw 'Settings > Apps uninstall did not retain the explicit Keep choice data and unrelated file byte-for-byte.'}
      $events.Add([pscustomobject]@{Name='Windows Settings uninstall preserves settings/history and unrelated file byte-for-byte';Status='PASS';SettingsSHA256=$settingsAfterHash;HistorySHA256=$historyAfterHash;UnrelatedSHA256=$unrelatedAfterHash;DataRetentionChoice=$settingsUninstall.Wizard.DataRetentionChoice})
    }
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
  }catch{$failure=$_.Exception.Message;$events.Add([pscustomobject]@{Name='Standard user acceptance';Status='FAIL';Details=$failure;ScriptStackTrace=$_.ScriptStackTrace;PositionMessage=$_.InvocationInfo.PositionMessage;ScriptLineNumber=$_.InvocationInfo.ScriptLineNumber})}
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
    $runnerEnvironmentContext=[string]$env:EBR_RUNNER_ENVIRONMENT_CONTEXT
    $runnerOs=Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $runnerContextValid=($env:GITHUB_ACTIONS-ceq'true'-and$env:RUNNER_ENVIRONMENT-ceq'github-hosted'-and$runnerEnvironmentContext-ceq'github-hosted'-and$env:RUNNER_OS-ceq'Windows'-and$env:RUNNER_ARCH-ceq'X64'-and$env:GITHUB_SERVER_URL-ceq'https://github.com'-and$env:GITHUB_REPOSITORY-ieq'REMEDIOSSAMUEL/EYE-BREAK-REMINDER'-and$env:GITHUB_RUN_ID-and$env:RUNNER_NAME-and$env:GITHUB_WORKSPACE-and$env:RUNNER_TEMP-and$runnerOs.Caption-match'Windows Server 2025'-and[Runtime.InteropServices.RuntimeInformation]::OSArchitecture-eq[Runtime.InteropServices.Architecture]::X64-and[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture-eq[Runtime.InteropServices.Architecture]::X64)
    if(-not$runnerContextValid){throw 'The standard-user console acceptance harness requires the validated GitHub-hosted Windows Server 2025 x64 runner context.'}
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
    $runnerContextFile=Join-Path $stageRoot 'runner-context.json'
    $runnerContext=[ordered]@{GITHUB_ACTIONS=[string]$env:GITHUB_ACTIONS;GITHUB_SERVER_URL=[string]$env:GITHUB_SERVER_URL;GITHUB_REPOSITORY=[string]$env:GITHUB_REPOSITORY;GITHUB_RUN_ID=[string]$env:GITHUB_RUN_ID;GITHUB_WORKSPACE=[string]$env:GITHUB_WORKSPACE;RUNNER_ENVIRONMENT=[string]$env:RUNNER_ENVIRONMENT;RUNNER_OS=[string]$env:RUNNER_OS;RUNNER_ARCH=[string]$env:RUNNER_ARCH;RUNNER_NAME=[string]$env:RUNNER_NAME;RUNNER_TEMP=[string]$env:RUNNER_TEMP;ImageOS=[string]$env:ImageOS;ImageVersion=[string]$env:ImageVersion;EBR_RUNNER_ENVIRONMENT_CONTEXT=$runnerEnvironmentContext}
    $runnerContext|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $runnerContextFile -Encoding utf8
    $stageEvidence=Join-Path $stageRoot 'evidence';[void][IO.Directory]::CreateDirectory($stageEvidence)
    Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $stageRoot 'windows_standard_user_acceptance.ps1') -Force
    Copy-Item -LiteralPath $InstallerPath -Destination (Join-Path $stageRoot 'EyeBreakReminder-Setup-x64.exe') -Force
    Copy-Item -LiteralPath $ExecutablePath -Destination (Join-Path $stageRoot 'EyeBreakReminder.exe') -Force
    $principal="$env:COMPUTERNAME\${userName}"
    $probeStage=Join-Path $stageRoot 'probes';[void][IO.Directory]::CreateDirectory($probeStage)
    foreach($probeScriptName in @('windows_candidate_audio_loopback_acceptance.ps1','windows_narrator_speech_recap_acceptance.ps1','windows_shell_notification_acceptance.ps1')){
      $probeSource=Join-Path $PSScriptRoot $probeScriptName
      if(-not(Test-Path -LiteralPath $probeSource -PathType Leaf)){throw "Required optional capability probe '$probeScriptName' is missing from the workspace."}
      Copy-Item -LiteralPath $probeSource -Destination (Join-Path $probeStage $probeScriptName) -Force
    }
    & icacls.exe $stageRoot /grant "${principal}:(OI)(CI)M" /T /C|Out-Null
    if($LASTEXITCODE-ne0){throw "Could not grant the disposable standard user access to its isolated staging folder (icacls $LASTEXITCODE)."}
    $pwsh=Join-Path $PSHOME 'pwsh.exe';$childScript=Join-Path $stageRoot 'windows_standard_user_acceptance.ps1'
    $safeCaptureArgument=if($DisableWholeDesktopCaptures){' -DisableWholeDesktopCaptures'}else{''}
    $expectedUserSid=[string]$user.SID.Value
    $runnerEnvironmentContext=if($RunnerEnvironmentContext){$RunnerEnvironmentContext}else{[string]$env:EBR_RUNNER_ENVIRONMENT_CONTEXT}
    if($expectedUserSid-notmatch'^S-\d+(?:-\d+)+$'){throw 'Generated disposable account SID did not match the expected Windows SID format.'}
    if($principal-notmatch'^[A-Za-z0-9_.-]+\\[A-Za-z0-9_.-]+$'){throw 'Generated disposable local principal did not match the safe computer-name\user-name format.'}
    if($runnerEnvironmentContext-and$runnerEnvironmentContext-notmatch'^[A-Za-z0-9_-]+$'){throw 'Runner environment context contains characters that cannot be safely forwarded to the child.'}
    $expectedUserArgument=" -ExpectedUserSid `"$expectedUserSid`""
    $expectedPrincipalArgument=" -ExpectedUserName `"$principal`""
    $runnerEnvironmentArgument=if($runnerEnvironmentContext){" -RunnerEnvironmentContext `"$runnerEnvironmentContext`""}else{''}
    $runnerContextArgument=" -RunnerContextPath `"$runnerContextFile`""
    $arguments="-NoProfile -ExecutionPolicy Bypass -File `"$childScript`" -Child -InstallerPath `"$(Join-Path $stageRoot 'EyeBreakReminder-Setup-x64.exe')`" -ExecutablePath `"$(Join-Path $stageRoot 'EyeBreakReminder.exe')`" -EvidenceDirectory `"$stageEvidence`" -ChildResultPath `"$childResult`"$safeCaptureArgument$expectedUserArgument$expectedPrincipalArgument$runnerEnvironmentArgument$runnerContextArgument"
    $credential=[pscredential]::new($principal,$securePassword)
    $childStdout=Join-Path $stageRoot 'standard-user-child.stdout.log';$childStderr=Join-Path $stageRoot 'standard-user-child.stderr.log'
    $childProcess=Start-Process -FilePath $pwsh -Credential $credential -LoadUserProfile -ArgumentList $arguments -RedirectStandardOutput $childStdout -RedirectStandardError $childStderr -PassThru
    $testStarted=$true
    $credential=$null;try{$securePassword.Dispose()}catch{};$securePassword=$null
    if(-not$childProcess.WaitForExit(2100000)){Stop-Process -Id $childProcess.Id -Force -ErrorAction SilentlyContinue;throw 'Standard-user test process exceeded its thirty-five-minute limit.'}
    $childExitCode=$childProcess.ExitCode;$childProcess.Dispose()
    foreach($capture in @(@($childResult,'standard-user-child-results.json'),@($childStdout,'standard-user-child.stdout.log'),@($childStderr,'standard-user-child.stderr.log'))){if(Test-Path -LiteralPath $capture[0]){Copy-Item -LiteralPath $capture[0] -Destination (Join-Path $evidenceRoot $capture[1]) -Force}}
    if(Test-Path -LiteralPath $childResult){$result=Get-Content -LiteralPath $childResult -Raw|ConvertFrom-Json}else{$result=$null}
    $childOutput=if(Test-Path -LiteralPath $childStdout){(Get-Content -LiteralPath $childStdout -Tail 60)-join"`n"}else{''};$childError=if(Test-Path -LiteralPath $childStderr){(Get-Content -LiteralPath $childStderr -Tail 60)-join"`n"}else{''}
    if($result-and$result.Status-eq'BLOCKED'){$status='BLOCKED';$reason=$result.Failure}
    elseif($childExitCode-eq0-and$result-and$result.Status-eq'PASS'){$status='PASS'}
    else{$status='FAIL';$reason=if($result){$result.Failure}else{"Standard-user child returned exit code $childExitCode without a passing evidence file. stdout: $childOutput stderr: $childError"}}
  }catch{
    if($testStarted){$status='FAIL';$reason=$_.Exception.Message}else{$status='BLOCKED';$reason="The hosted runner could not safely provision or launch the isolated standard-user test: $($_.Exception.Message)"}
  }
}finally{
  $stagedEvidence=Join-Path $stageRoot 'evidence'
  if(Test-Path -LiteralPath $stagedEvidence){
    try{
      $screenshots=@(Get-ChildItem -LiteralPath $stagedEvidence -Filter '*.png' -File)
      if($screenshots.Count){$settingsScreenshotDirectory=Join-Path $evidenceRoot 'standard-user-screenshots';[void][IO.Directory]::CreateDirectory($settingsScreenshotDirectory);foreach($screenshot in $screenshots){Copy-Item -LiteralPath $screenshot.FullName -Destination (Join-Path $settingsScreenshotDirectory $screenshot.Name) -Force}}
      $probeEvidenceSource=Join-Path $stagedEvidence 'capability-probes'
      if(Test-Path -LiteralPath $probeEvidenceSource){Copy-Item -LiteralPath $probeEvidenceSource -Destination (Join-Path $evidenceRoot 'capability-probes') -Recurse -Force}
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
$resultObject=[pscustomobject]@{Status=$status;Account=$userName;Failure=$reason;ChildExitCode=$childExitCode;ChildResultCaptured=[bool]$result;CleanupActions=$cleanupActions.ToArray();CleanupErrors=$cleanupErrors.ToArray();AccountRemoved=$accountRemoved;StageRemoved=$stageRemoved;WholeDesktopCapturesDisabled=[bool]$DisableWholeDesktopCaptures;CandidateSHA256=if(Test-Path -LiteralPath $ExecutablePath){(Get-FileHash -LiteralPath $ExecutablePath -Algorithm SHA256).Hash.ToLowerInvariant()}else{$null};Events=if($result){$result.Events}else{@()};CapabilityProbes=if($result){@($result.Events|Where-Object{$_.Name-like'Optional pre-install capability probe *'}|ForEach-Object{$_.Details})}else{@()};SettingsAppsUninstall=if($settingsEvent.Count){$settingsEvent[0].Status}else{'NOT TESTED'};SettingsAppsUninstallReason=if($settingsEvent.Count){$settingsEvent[0].Details.Reason}else{'The Settings Apps probe did not produce a result.'};SettingsScreenshots=@(Get-ChildItem -LiteralPath $settingsScreenshotDirectory -Filter '*.png' -File -ErrorAction SilentlyContinue|Select-Object -ExpandProperty Name);CompletedUtc=[DateTime]::UtcNow.ToString('o')}
if($cleanupErrors.Count-gt0){$resultObject.Status='FAIL';$failureParts=@($reason)+@($cleanupErrors.ToArray())|Where-Object{$_};$resultObject.Failure=$failureParts -join '; '}
Save-StandardUserResult $finalResult $resultObject
$resultObject|ConvertTo-Json -Depth 8
if($resultObject.Status-in@('FAIL','BLOCKED')){exit 1}
