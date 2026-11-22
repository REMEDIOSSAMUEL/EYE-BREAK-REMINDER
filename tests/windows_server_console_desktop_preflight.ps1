param([Parameter(Mandatory)][string]$EvidenceDirectory)
$ErrorActionPreference='Stop'

$nativeSource=@'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
public enum EBR_CONSOLE_WTS_STATE { Active=0, Connected=1, ConnectQuery=2, Shadow=3, Disconnected=4, Idle=5, Listen=6, Reset=7, Down=8, Init=9 }
public sealed class EBR_CONSOLE_WTS_SESSION { public int SessionId; public string Station; public string State; }
public static class EBR_CONSOLE_NATIVE {
  private const int UOI_NAME=2;
  private const uint DESKTOP_READOBJECTS=0x0001;
  [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] private struct WTS_SESSION_INFO { public int SessionId; [MarshalAs(UnmanagedType.LPWStr)] public string Station; public EBR_CONSOLE_WTS_STATE State; }
  [DllImport("kernel32.dll",SetLastError=true)] public static extern uint WTSGetActiveConsoleSessionId();
  [DllImport("wtsapi32.dll",EntryPoint="WTSEnumerateSessionsW",SetLastError=true,CharSet=CharSet.Unicode)] private static extern bool WTSEnumerateSessions(IntPtr server,int reserved,int version,out IntPtr sessions,out int count);
  [DllImport("wtsapi32.dll")] private static extern void WTSFreeMemory(IntPtr memory);
  public static EBR_CONSOLE_WTS_SESSION[] EnumerateSessions(){IntPtr buffer=IntPtr.Zero;int count=0;if(!WTSEnumerateSessions(IntPtr.Zero,0,1,out buffer,out count))throw new Win32Exception(Marshal.GetLastWin32Error(),"WTSEnumerateSessions failed");try{int size=Marshal.SizeOf(typeof(WTS_SESSION_INFO));var rows=new List<EBR_CONSOLE_WTS_SESSION>(count);for(int i=0;i<count;i++){var row=(WTS_SESSION_INFO)Marshal.PtrToStructure(IntPtr.Add(buffer,i*size),typeof(WTS_SESSION_INFO));rows.Add(new EBR_CONSOLE_WTS_SESSION{SessionId=row.SessionId,Station=row.Station,State=row.State.ToString()});}return rows.ToArray();}finally{if(buffer!=IntPtr.Zero)WTSFreeMemory(buffer);}}
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

$probeErrors=[System.Collections.Generic.List[string]]::new()
$evidencePath=[IO.Path]::GetFullPath($EvidenceDirectory)
[void][IO.Directory]::CreateDirectory($evidencePath)
$os=$null;$processId=$PID;$processSessionId=-1;$sessionName=[string]$env:SESSIONNAME
$identity=$null;$isAdministrator=$false;$userInteractive=$false
$activeConsoleSessionId=[uint32]::MaxValue;$sessions=@();$matchingConsoleSession=$null
$processWindowStation=$null;$threadDesktop=$null;$inputDesktop=$null
$explorer=@();$taskbarWindow=[IntPtr]::Zero;$taskbarProcessId=0;$taskbarProcess=$null
try{$os=Get-CimInstance Win32_OperatingSystem -ErrorAction Stop}catch{$probeErrors.Add("Operating system query: $($_.Exception.Message)")}
try{$current=Get-Process -Id $processId -ErrorAction Stop;$processSessionId=[int]$current.SessionId}catch{$probeErrors.Add("Current process query: $($_.Exception.Message)")}
try{$identity=[Security.Principal.WindowsIdentity]::GetCurrent();$principal=[Security.Principal.WindowsPrincipal]::new($identity);$isAdministrator=$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)}catch{$probeErrors.Add("Identity/admin query: $($_.Exception.Message)")}
$userInteractive=[Environment]::UserInteractive
try{
  Add-Type -TypeDefinition $nativeSource -ErrorAction Stop
  $activeConsoleSessionId=[EBR_CONSOLE_NATIVE]::WTSGetActiveConsoleSessionId()
  $sessions=@([EBR_CONSOLE_NATIVE]::EnumerateSessions()|ForEach-Object{[pscustomobject]@{SessionId=$_.SessionId;Station=$_.Station;State=$_.State}})
  $matchingConsoleSession=@($sessions|Where-Object{[uint32]$_.SessionId-eq$activeConsoleSessionId-and$_.Station-ieq'Console'}|Select-Object -First 1)
  if($matchingConsoleSession.Count){$matchingConsoleSession=$matchingConsoleSession[0]}else{$matchingConsoleSession=$null}
  $processWindowStation=[EBR_CONSOLE_NATIVE]::ProcessWindowStationName()
  $threadDesktop=[EBR_CONSOLE_NATIVE]::ThreadDesktopName()
  $inputDesktop=[EBR_CONSOLE_NATIVE]::InputDesktopName()
  $taskbarWindow=[EBR_CONSOLE_NATIVE]::TaskbarWindow()
  $taskbarProcessId=[EBR_CONSOLE_NATIVE]::TaskbarProcessId($taskbarWindow)
  if($taskbarProcessId){$taskbarProcess=Get-Process -Id ([int]$taskbarProcessId) -ErrorAction SilentlyContinue}
}catch{$probeErrors.Add("WTS/desktop/Shell query: $($_.Exception.Message)")}
$consoleSessionActive=($null-ne$matchingConsoleSession-and$matchingConsoleSession.State-eq'Active')
$processInActiveConsole=($consoleSessionActive-and$activeConsoleSessionId-ne[uint32]::MaxValue-and[int64]$processSessionId-eq[int64]$activeConsoleSessionId)
$windowStationConfirmed=$processWindowStation-ieq'WinSta0'
$threadDesktopConfirmed=$threadDesktop-ieq'Default'
$inputDesktopConfirmed=$inputDesktop-ieq'Default'
$taskbarSameSession=($taskbarWindow-ne[IntPtr]::Zero-and$taskbarProcess-and$taskbarProcess.ProcessName-ieq'explorer'-and$taskbarProcess.SessionId-eq$processSessionId)
$explorer=@(Get-Process -Name explorer -ErrorAction SilentlyContinue|Where-Object{$_.SessionId-eq$processSessionId}|Select-Object Id,SessionId,ProcessName)
$shellSameSession=($explorer.Count-gt0-and$taskbarSameSession)
$runnerContextValid=($env:GITHUB_ACTIONS-ceq'true'-and$env:RUNNER_ENVIRONMENT-ceq'github-hosted'-and$env:RUNNER_OS-ceq'Windows'-and$env:RUNNER_ARCH-ieq'X64'-and$env:GITHUB_SERVER_URL-ceq'https://github.com'-and$env:GITHUB_REPOSITORY-ieq'REMEDIOSSAMUEL/EYE-BREAK-REMINDER')
$osArchitecture=[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
$processArchitecture=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
$nativeAmd64=($os-and$os.Caption-match'Windows Server 2025'-and$osArchitecture-eq'X64'-and$processArchitecture-eq'X64')
$ready=($probeErrors.Count-eq0-and$runnerContextValid-and$nativeAmd64-and$isAdministrator-and$userInteractive-and$processInActiveConsole-and$windowStationConfirmed-and$threadDesktopConfirmed-and$inputDesktopConfirmed-and$shellSameSession)
$outcome=if($ready){'CONSOLE_DESKTOP_READY'}elseif(-not$runnerContextValid-or-not$nativeAmd64){'REQUIRED_GITHUB_WINDOWS_SERVER_2025_X64_CONTEXT_NOT_OBSERVED'}else{'ACTIVE_CONSOLE_DESKTOP_GUARD_BLOCKED'}
$blockReasons=[System.Collections.Generic.List[string]]::new()
if($probeErrors.Count){$blockReasons.AddRange([string[]]$probeErrors.ToArray())}
if(-not$runnerContextValid){$blockReasons.Add('Runner context is not the expected GitHub-hosted project Windows runner.')}
if(-not$nativeAmd64){$blockReasons.Add('Operating system/process architecture is not native Windows Server 2025 x64.')}
if(-not$isAdministrator){$blockReasons.Add('Runner token is not an administrator and cannot provision the disposable standard-user account.')}
if(-not$userInteractive){$blockReasons.Add('Environment.UserInteractive is false.')}
if(-not$processInActiveConsole){$blockReasons.Add('Current process SessionId does not match an active WTS Console session.')}
if(-not$windowStationConfirmed){$blockReasons.Add("Process window station is '$processWindowStation', expected WinSta0.")}
if(-not$threadDesktopConfirmed){$blockReasons.Add("Current thread desktop is '$threadDesktop', expected Default.")}
if(-not$inputDesktopConfirmed){$blockReasons.Add("OpenInputDesktop returned '$inputDesktop', expected accessible Default.")}
if(-not$shellSameSession){$blockReasons.Add('Explorer and Shell_TrayWnd taskbar are not both present in the current session.')}
$report=[ordered]@{
  Probe='Active console preflight for disposable standard-user Settings uninstall';Outcome=$outcome;ReadyForCandidateTest=$ready;AcceptanceResult='NOT_RUN'
  CandidateDownloaded=$false;CandidateLaunched=$false;SystemConfigurationChanged=$false;SessionOrPowerActionPerformed=$false
  GitHubContext=[pscustomobject]@{Actions=$env:GITHUB_ACTIONS;RunnerEnvironment=$env:RUNNER_ENVIRONMENT;RunnerOS=$env:RUNNER_OS;RunnerArchitecture=$env:RUNNER_ARCH;Repository=$env:GITHUB_REPOSITORY;RunId=$env:GITHUB_RUN_ID}
  OperatingSystem=[pscustomobject]@{Caption=if($os){$os.Caption}else{$null};Version=if($os){$os.Version}else{$null};Build=if($os){$os.BuildNumber}else{$null};OSArchitecture=$osArchitecture;ProcessArchitecture=$processArchitecture;NativeAmd64=$nativeAmd64}
  Process=[pscustomobject]@{ProcessId=$processId;SessionId=$processSessionId;SessionName=$sessionName;User=if($identity){$identity.Name}else{$null};UserSid=if($identity){$identity.User.Value}else{$null};IsAdministrator=$isAdministrator;UserInteractive=$userInteractive}
  WTS=[pscustomobject]@{ActiveConsoleSessionId=$activeConsoleSessionId;Sessions=$sessions;MatchingConsoleSession=$matchingConsoleSession;MatchingConsoleSessionActive=$consoleSessionActive;ProcessSessionMatchesActiveConsole=$processInActiveConsole}
  Desktop=[pscustomobject]@{ProcessWindowStation=$processWindowStation;ThreadDesktop=$threadDesktop;InputDesktop=$inputDesktop;WinSta0Confirmed=$windowStationConfirmed;DefaultThreadDesktopConfirmed=$threadDesktopConfirmed;DefaultInputDesktopAccessible=$inputDesktopConfirmed}
  Shell=[pscustomobject]@{ExplorerProcesses=$explorer;TaskbarWindowHandle=if($taskbarWindow-ne[IntPtr]::Zero){'0x{0:X}'-f$taskbarWindow.ToInt64()}else{$null};TaskbarProcessId=$taskbarProcessId;TaskbarProcessName=if($taskbarProcess){$taskbarProcess.ProcessName}else{$null};TaskbarProcessSessionId=if($taskbarProcess){$taskbarProcess.SessionId}else{$null};ExplorerAndTaskbarInCurrentSession=$shellSameSession}
  ProbeErrors=$probeErrors.ToArray();BlockReasons=$blockReasons.ToArray();ObservedUtc=[DateTime]::UtcNow.ToString('o')
}
$jsonPath=Join-Path $evidencePath 'server-console-standard-user-preflight.json'
$report|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $jsonPath -Encoding utf8
$summary=@(
  '**Same-job read-only Windows Server console preflight (not an acceptance result)**'
  ''
  "Observation: $outcome; ready for exact-candidate test: $ready"
  "OS/native architecture: $($report.OperatingSystem.Caption) / $osArchitecture / $processArchitecture"
  "Current process session: $processSessionId ($sessionName); active WTS console session: $activeConsoleSessionId; matching Console entry Active: $consoleSessionActive"
  "Identity: $($report.Process.User); administrator: $isAdministrator; UserInteractive: $userInteractive"
  "Window station/thread/input desktop: $processWindowStation / $threadDesktop / $inputDesktop"
  "Explorer/taskbar in current session: $shellSameSession"
  'No candidate was downloaded or launched, and no session, power, display, audio, or system configuration was changed.'
  "JSON evidence: $jsonPath"
) -join "`n"
Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $summary
Write-Output $summary
if($env:GITHUB_OUTPUT){"desktop_ready=$($ready.ToString().ToLowerInvariant())"|Add-Content -LiteralPath $env:GITHUB_OUTPUT}
