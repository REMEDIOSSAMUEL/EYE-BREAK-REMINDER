[CmdletBinding()]
param(
  [string]$CandidateExecutable,
  [string]$EvidenceDirectory,
  [switch]$Worker,
  [string]$WorkerConfigPath
)

# ENV-006 only. The dedicated job in
# windows-v1.4.0-retained-settings-uninstall.yml runs this on a fresh,
# disposable GitHub-hosted Windows Server 2025 x64 runner. It creates one temporary standard account and a
# loopback-only RDP session. Only that separate RDP session is locked.
#
# The caller must set EBR_RUNNER_ENVIRONMENT_CONTEXT from the trusted
# runner.environment workflow context. The script fails closed unless that
# context is github-hosted. It must not be run on a personal workstation.
#
# The generated password is never put in a command line, file, log, screenshot,
# or result record. It is stored only as a transient SecureString and in the
# runner user's short-lived credential vault entry needed for the first RDP
# logon. The vault entry is deleted before the lock test; the password is then
# typed only while the owned mstsc window is foreground and the RDP worker has
# independently verified its Winlogon input desktop.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ExpectedCandidateSHA256 = '07f6c1eaee5818df9f5c024310883ca94b8274a4f451186a8123974fb5e5f720'
$CandidateArtifactId = '14695418078'
$CandidateArtifactName = 'EyeBreakReminder-v1.4.0-production-candidate-44875679345'
$CandidateArtifactRunId = '44875679345'
$CandidateSourceCommit = '491bd2ed29f84f4d434b884fc723144db2d6f294'
$CandidateFileName = 'EyeBreakReminder.exe'
$RdpCredentialTarget = 'TERMSRV/127.0.0.1'

function Initialize-NativeTypes {
  if (-not ('EBR_ENV006_RECT' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

[StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
public struct EBR_ENV006_WTS_SESSION_INFO {
  public int SessionId;
  public IntPtr WinStationName;
  public int State;
}
[StructLayout(LayoutKind.Sequential)]
public struct EBR_ENV006_RECT { public int Left, Top, Right, Bottom; }
[StructLayout(LayoutKind.Sequential)]
public struct EBR_ENV006_KEYBDINPUT { public ushort wVk,wScan; public uint dwFlags,time; public UIntPtr dwExtraInfo; }
[StructLayout(LayoutKind.Sequential)]
public struct EBR_ENV006_MOUSEINPUT { public int dx,dy; public uint mouseData,dwFlags,time; public UIntPtr dwExtraInfo; }
[StructLayout(LayoutKind.Sequential)]
public struct EBR_ENV006_HARDWAREINPUT { public uint uMsg; public ushort wParamL,wParamH; }
[StructLayout(LayoutKind.Explicit)]
public struct EBR_ENV006_INPUT_UNION {
  [FieldOffset(0)] public EBR_ENV006_MOUSEINPUT mi;
  [FieldOffset(0)] public EBR_ENV006_KEYBDINPUT ki;
  [FieldOffset(0)] public EBR_ENV006_HARDWAREINPUT hi;
}
[StructLayout(LayoutKind.Sequential)]
public struct EBR_ENV006_INPUT { public uint type; public EBR_ENV006_INPUT_UNION U; }

public sealed class EBR_ENV006_SESSION_ROW {
  public int SessionId { get; set; }
  public string Station { get; set; }
  public string State { get; set; }
  public string User { get; set; }
  public string UserOnly { get; set; }
  public string Domain { get; set; }
}
public sealed class EBR_ENV006_WINDOW_ROW {
  public IntPtr Handle { get; set; }
  public uint ProcessId { get; set; }
  public string Title { get; set; }
  public string ClassName { get; set; }
  public bool Visible { get; set; }
  public bool Minimized { get; set; }
  public int Width { get; set; }
  public int Height { get; set; }
}

public static class EBR_ENV006_NATIVE {
  public delegate bool EnumWindowsProc(IntPtr hwnd,IntPtr data);
  [DllImport("wtsapi32.dll",SetLastError=true)] static extern bool WTSEnumerateSessionsW(IntPtr server,int reserved,int version,out IntPtr sessions,out int count);
  [DllImport("wtsapi32.dll",SetLastError=true)] static extern bool WTSQuerySessionInformationW(IntPtr server,int sessionId,int infoClass,out IntPtr buffer,out int bytes);
  [DllImport("wtsapi32.dll")] static extern void WTSFreeMemory(IntPtr memory);
  [DllImport("user32.dll",SetLastError=true)] static extern IntPtr OpenInputDesktop(uint flags,bool inherit,uint access);
  [DllImport("user32.dll",SetLastError=true)] static extern bool GetUserObjectInformationW(IntPtr handle,int index,IntPtr info,uint length,out uint needed);
  [DllImport("user32.dll",SetLastError=true)] static extern bool CloseDesktop(IntPtr desktop);
  [DllImport("user32.dll")] static extern IntPtr GetProcessWindowStation();
  [DllImport("user32.dll",SetLastError=true)] static extern bool EnumWindows(EnumWindowsProc callback,IntPtr data);
  [DllImport("user32.dll",SetLastError=true)] static extern uint GetWindowThreadProcessId(IntPtr hwnd,out uint processId);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetWindowTextW(IntPtr hwnd,StringBuilder text,int max);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr hwnd,StringBuilder text,int max);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll")] static extern bool IsIconic(IntPtr hwnd);
  [DllImport("user32.dll",SetLastError=true)] static extern bool GetWindowRect(IntPtr hwnd,out EBR_ENV006_RECT rect);
  [DllImport("user32.dll",SetLastError=true)] public static extern bool SetForegroundWindow(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hwnd,int command);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern IntPtr GetKeyboardLayout(uint threadId);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern short VkKeyScanExW(char ch,IntPtr layout);
  [DllImport("user32.dll",SetLastError=true)] static extern uint SendInput(uint count,[In] EBR_ENV006_INPUT[] inputs,int inputSize);
  [DllImport("user32.dll")] static extern short GetKeyState(int virtualKey);
  [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr OpenProcess(uint access,bool inherit,int processId);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool IsWow64Process2(IntPtr process,out ushort processMachine,out ushort nativeMachine);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
  [DllImport("user32.dll",SetLastError=true)] public static extern bool LockWorkStation();
  [DllImport("user32.dll",SetLastError=true)] public static extern bool PostMessageW(IntPtr hwnd,uint message,IntPtr wParam,IntPtr lParam);
  [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr parent,int id);

  static string UserObjectName(IntPtr handle) {
    uint needed=0; GetUserObjectInformationW(handle,2,IntPtr.Zero,0,out needed);
    if(needed==0) return "";
    IntPtr data=Marshal.AllocHGlobal((int)needed);
    try { if(!GetUserObjectInformationW(handle,2,data,needed,out needed)) return ""; return Marshal.PtrToStringUni(data)??""; }
    finally { Marshal.FreeHGlobal(data); }
  }
  static string QuerySessionString(int sessionId,int infoClass) {
    IntPtr data=IntPtr.Zero; int bytes=0;
    if(!WTSQuerySessionInformationW(IntPtr.Zero,sessionId,infoClass,out data,out bytes)) return "";
    try { return Marshal.PtrToStringUni(data)??""; }
    finally { if(data!=IntPtr.Zero) WTSFreeMemory(data); }
  }
  static string Text(IntPtr hwnd) {
    if(hwnd==IntPtr.Zero) return "";
    StringBuilder text=new StringBuilder(512); GetWindowTextW(hwnd,text,text.Capacity); return text.ToString();
  }
  static string Class(IntPtr hwnd) {
    StringBuilder text=new StringBuilder(256); GetClassNameW(hwnd,text,text.Capacity); return text.ToString();
  }
  public static string InputDesktopName() {
    IntPtr desktop=OpenInputDesktop(0,false,0x0001);
    if(desktop==IntPtr.Zero) return "";
    try { return UserObjectName(desktop); }
    finally { CloseDesktop(desktop); }
  }
  public static string WindowStationName() {
    IntPtr station=GetProcessWindowStation();
    return station==IntPtr.Zero?"":UserObjectName(station);
  }
  public static object[] EnumerateSessions() {
    IntPtr data=IntPtr.Zero; int count=0;
    if(!WTSEnumerateSessionsW(IntPtr.Zero,0,1,out data,out count)) throw new Win32Exception(Marshal.GetLastWin32Error());
    List<object> rows=new List<object>();
    int size=Marshal.SizeOf(typeof(EBR_ENV006_WTS_SESSION_INFO));
    try {
      for(int i=0;i<count;i++) {
        EBR_ENV006_WTS_SESSION_INFO s=(EBR_ENV006_WTS_SESSION_INFO)Marshal.PtrToStructure(IntPtr.Add(data,i*size),typeof(EBR_ENV006_WTS_SESSION_INFO));
        string user=QuerySessionString(s.SessionId,5),domain=QuerySessionString(s.SessionId,7);
        string state=s.State==0?"Active":s.State==4?"Disconnected":s.State.ToString();
        string station=Marshal.PtrToStringUni(s.WinStationName)??"";
        rows.Add(new EBR_ENV006_SESSION_ROW {SessionId=s.SessionId,Station=station,State=state,UserOnly=user,Domain=domain,User=String.IsNullOrEmpty(domain)?user:domain+"\\"+user});
      }
    } finally { if(data!=IntPtr.Zero) WTSFreeMemory(data); }
    return rows.ToArray();
  }
  public static object[] EnumerateWindows() {
    List<object> rows=new List<object>();
    EnumWindows((hwnd,data)=>{
      uint pid; GetWindowThreadProcessId(hwnd,out pid);
      EBR_ENV006_RECT rect; bool hasRect=GetWindowRect(hwnd,out rect);
      rows.Add(new EBR_ENV006_WINDOW_ROW {
        Handle=hwnd,ProcessId=pid,Title=Text(hwnd),ClassName=Class(hwnd),Visible=IsWindowVisible(hwnd),Minimized=IsIconic(hwnd),
        Width=hasRect?Math.Max(0,rect.Right-rect.Left):0,Height=hasRect?Math.Max(0,rect.Bottom-rect.Top):0
      });
      return true;
    },IntPtr.Zero);
    return rows.ToArray();
  }
  public static EBR_ENV006_RECT WindowRect(IntPtr hwnd) {
    EBR_ENV006_RECT rect;
    if(!GetWindowRect(hwnd,out rect)) throw new Win32Exception(Marshal.GetLastWin32Error());
    return rect;
  }
  public static IntPtr FindCandidateWindow(int processId,bool visibleOnly) {
    IntPtr best=IntPtr.Zero; long area=0;
    foreach(EBR_ENV006_WINDOW_ROW row in EnumerateWindows()) {
      if(row.ProcessId==(uint)processId && row.ClassName=="EyeBreakReminder.Native" && (!visibleOnly || (row.Visible && !row.Minimized))) {
        long current=(long)row.Width*row.Height; if(current>area) {best=row.Handle;area=current;}
      }
    }
    return best;
  }
  public static string ControlText(IntPtr hwnd) { return Text(hwnd); }
  public static uint ForegroundProcessId() {
    uint pid; GetWindowThreadProcessId(GetForegroundWindow(),out pid); return pid;
  }
  public static bool CapsLockIsOn() { return (GetKeyState(0x14)&1)!=0; }
  public static short MapCharacter(char ch) { return VkKeyScanExW(ch,GetKeyboardLayout(0)); }
  public static bool IsNativeAmd64Process(int processId) {
    IntPtr process=OpenProcess(0x1000,false,processId);
    if(process==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
    try { ushort machine,native; if(!IsWow64Process2(process,out machine,out native)) throw new Win32Exception(Marshal.GetLastWin32Error()); return machine==0 && native==0x8664; }
    finally { CloseHandle(process); }
  }
  public static uint SendVirtualKeysToForegroundProcess(uint expectedPid,ushort[] keys,uint[] flags) {
    if(keys==null || flags==null || keys.Length==0 || keys.Length!=flags.Length) throw new ArgumentException("Invalid key sequence.");
    if(ForegroundProcessId()!=expectedPid) throw new InvalidOperationException("Owned mstsc process lost foreground before input.");
    EBR_ENV006_INPUT[] inputs=new EBR_ENV006_INPUT[keys.Length];
    for(int i=0;i<inputs.Length;i++) {
      inputs[i].type=1;
      inputs[i].U.ki=new EBR_ENV006_KEYBDINPUT {wVk=keys[i],wScan=0,dwFlags=flags[i],time=0,dwExtraInfo=UIntPtr.Zero};
    }
    uint sent=SendInput((uint)inputs.Length,inputs,Marshal.SizeOf(typeof(EBR_ENV006_INPUT)));
    if(sent!=(uint)inputs.Length) throw new Win32Exception(Marshal.GetLastWin32Error(),"Input sequence was not fully delivered.");
    return sent;
  }
}
'@ -ErrorAction Stop
  }
  if (-not ('EBR_ENV006_CREDENTIAL' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
[StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]
public struct EBR_ENV006_CREDENTIAL {
  public UInt32 Flags,Type; public string TargetName,Comment; public FILETIME LastWritten;
  public UInt32 CredentialBlobSize; public IntPtr CredentialBlob; public UInt32 Persist,AttributeCount;
  public IntPtr Attributes; public string TargetAlias,UserName;
}
public static class EBR_ENV006_CREDMAN {
  [DllImport("Advapi32.dll",EntryPoint="CredWriteW",CharSet=CharSet.Unicode,SetLastError=true)] public static extern bool Write(ref EBR_ENV006_CREDENTIAL c,UInt32 flags);
  [DllImport("Advapi32.dll",EntryPoint="CredReadW",CharSet=CharSet.Unicode,SetLastError=true)] public static extern bool Read(string target,UInt32 type,UInt32 flags,out IntPtr credential);
  [DllImport("Advapi32.dll",EntryPoint="CredDeleteW",CharSet=CharSet.Unicode,SetLastError=true)] public static extern bool Delete(string target,UInt32 type,UInt32 flags);
  [DllImport("Advapi32.dll",EntryPoint="CredFree")] public static extern void Free(IntPtr credential);
}
'@ -ErrorAction Stop
  }
}

function Initialize-WorkerTypes {
  Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
  Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
  Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
  if (-not ('EBR_ENV006_WTS_FORM' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Windows.Forms;
public sealed class EBR_ENV006_WTS_FORM : Form {
  const int WM_WTSSESSION_CHANGE=0x02B1;
  public readonly List<int[]> Changes=new List<int[]>();
  [DllImport("wtsapi32.dll",SetLastError=true)] static extern bool WTSRegisterSessionNotification(IntPtr hwnd,uint flags);
  [DllImport("wtsapi32.dll",SetLastError=true)] static extern bool WTSUnRegisterSessionNotification(IntPtr hwnd);
  public EBR_ENV006_WTS_FORM() { ShowInTaskbar=false; FormBorderStyle=FormBorderStyle.None; Opacity=0; Width=1; Height=1; }
  public bool RegisterChanges() { CreateControl(); Show(); Hide(); return WTSRegisterSessionNotification(Handle,0); }
  public void UnregisterChanges() { if(IsHandleCreated) WTSUnRegisterSessionNotification(Handle); }
  protected override void WndProc(ref Message m) {
    if(m.Msg==WM_WTSSESSION_CHANGE) Changes.Add(new int[] {m.WParam.ToInt32(),m.LParam.ToInt32()});
    base.WndProc(ref m);
  }
}
'@ -ReferencedAssemblies 'System.Windows.Forms' -ErrorAction Stop
  }
}

function Write-AtomicJson([string]$Path,$Value) {
  $temp = $Path + '.tmp'
  [IO.File]::WriteAllText($temp,(ConvertTo-Json -InputObject $Value -Depth 12),[Text.UTF8Encoding]::new($false))
  Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Get-WorkerTimerState([int]$ProcessId,[bool]$CheckHash = $false,[bool]$AllowHidden = $false) {
  try { $process = Get-Process -Id $ProcessId -ErrorAction Stop }
  catch { throw 'FAIL: exact production candidate process exited during the lock/unlock cycle.' }
  if ($process.SessionId -ne [int]$script:WorkerConfig.SessionId) { throw 'FAIL: candidate process left the original RDP session.' }
  if (-not [EBR_ENV006_NATIVE]::IsNativeAmd64Process($ProcessId)) { throw 'BLOCKED: candidate process is not native AMD64 on the x64 guest.' }
  $path = [IO.Path]::GetFullPath($process.Path)
  if ($path -ine [IO.Path]::GetFullPath([string]$script:WorkerConfig.CandidatePath)) { throw 'FAIL: candidate process image path changed.' }
  $ownerProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop
  $ownerSid = (Invoke-CimMethod -InputObject $ownerProcess -MethodName GetOwnerSid -ErrorAction Stop).Sid
  if ($ownerSid -cne [string]$script:WorkerConfig.UserSid) { throw 'FAIL: candidate process owner is not the temporary RDP account.' }
  $hash = $null
  if ($CheckHash) {
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    if ($hash -cne $ExpectedCandidateSHA256) { throw 'BLOCKED: candidate file hash changed during the test.' }
  }
  $window = [EBR_ENV006_NATIVE]::FindCandidateWindow($ProcessId,-not $AllowHidden)
  if ($window -eq [IntPtr]::Zero) { throw 'BLOCKED: candidate main window is not visible in the test RDP session.' }
  $windowRow = @([EBR_ENV006_NATIVE]::EnumerateWindows() | Where-Object { $_.Handle -eq $window } | Select-Object -First 1)
  $countdown = [EBR_ENV006_NATIVE]::ControlText([EBR_ENV006_NATIVE]::GetDlgItem($window,40))
  $status = [EBR_ENV006_NATIVE]::ControlText([EBR_ENV006_NATIVE]::GetDlgItem($window,41))
  $match = [regex]::Match($countdown,'\A([0-9]+):([0-9]{2})\z')
  if (-not $match.Success) { throw "BLOCKED: unexpected countdown text '$countdown'." }
  [pscustomobject]@{
    ProcessId=$ProcessId;Path=$path;SHA256=$hash;OwnerSid=$ownerSid;SessionId=$process.SessionId
    WindowHandle=('0x{0:X}' -f $window.ToInt64());CountdownText=$countdown
    RemainingSeconds=([int]$match.Groups[1].Value * 60 + [int]$match.Groups[2].Value);StatusText=$status
    WindowVisible=if($windowRow.Count){[bool]$windowRow[0].Visible}else{$false}
    HandleCount=$process.HandleCount;ThreadCount=$process.Threads.Count;WorkingSetBytes=$process.WorkingSet64
  }
}

function Get-WorkerBreakWindow([int]$ProcessId) {
  $rows = @([EBR_ENV006_NATIVE]::EnumerateWindows() | Where-Object {
    $_.ProcessId -eq [uint32]$ProcessId -and $_.ClassName -ceq 'EyeBreakReminder.Break' -and $_.Visible -and -not $_.Minimized
  })
  if ($rows.Count -ne 1 -or $rows[0].Title -cne 'Taking an eye break — Eye Break Reminder') { return $null }
  $names = [System.Collections.Generic.List[string]]::new()
  try {
    $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$rows[0].Handle)
    if ($root) {
      $nodes = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
      for ($index=0; $index -lt $nodes.Count; $index++) {
        try {
          $current = $nodes.Item($index).Current
          if (-not $current.IsOffscreen -and -not [string]::IsNullOrWhiteSpace($current.Name)) { $names.Add([string]$current.Name) }
        } catch { }
      }
    }
  } catch { return $null }
  $text = $names -join "`n"
  if ($text -notmatch [regex]::Escape('Taking an eye break') -or $text -notmatch [regex]::Escape('Look at something at least 20 feet / 6 metres away.')) { return $null }
  [pscustomobject]@{Handle=('0x{0:X}' -f ([IntPtr]$rows[0].Handle).ToInt64());ProcessId=$ProcessId;SessionId=(Get-Process -Id $ProcessId).SessionId;ClassName=$rows[0].ClassName;Title=$rows[0].Title;Visible=$rows[0].Visible;AccessibleNames=@($names.ToArray());InstructionObserved=$true}
}

function Get-WorkerShellNotification([int]$SessionId,[int]$CandidateProcessId) {
  $expectedTitle = 'Time to rest your eyes'
  $expectedBody = 'Look 20 feet / 6 metres away for 30 seconds. Click to open the reminder.'
  $shellNames = @('explorer','ShellExperienceHost','ApplicationFrameHost','StartMenuExperienceHost','RuntimeBroker','sihost','ShellHost')
  $shell = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $shellNames -contains $_.ProcessName -and $_.SessionId -eq $SessionId })
  $shellByPid = @{}
  foreach ($process in $shell) { $shellByPid[[int]$process.Id] = [string]$process.ProcessName }
  $windows = @([EBR_ENV006_NATIVE]::EnumerateWindows() | Where-Object { $_.Visible -and $shellByPid.ContainsKey([int]$_.ProcessId) })
  $matches = [System.Collections.Generic.List[object]]::new()
  foreach ($window in $windows) {
    try {
      $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$window.Handle)
      if (-not $root) { continue }
      $nodes = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
      $titles = [System.Collections.Generic.List[string]]::new();$bodies = [System.Collections.Generic.List[string]]::new()
      for ($index=0; $index -lt $nodes.Count; $index++) {
        try {
          $current = $nodes.Item($index).Current
          if ($current.ProcessId -ne [int]$window.ProcessId -or $current.IsOffscreen) { continue }
          if ($current.Name -ceq $expectedTitle) { $titles.Add([string]$current.Name) }
          if ($current.Name -ceq $expectedBody) { $bodies.Add([string]$current.Name) }
        } catch { }
      }
      if ($titles.Count -eq 1 -and $bodies.Count -eq 1) {
        $matches.Add([pscustomobject]@{Handle=('0x{0:X}' -f ([IntPtr]$window.Handle).ToInt64());ProcessId=[int]$window.ProcessId;ProcessName=$shellByPid[[int]$window.ProcessId];ClassName=$window.ClassName;Title=$expectedTitle;Body=$expectedBody;TitleCount=$titles.Count;BodyCount=$bodies.Count;WindowVisible=$window.Visible})
      }
    } catch { }
  }
  [pscustomobject]@{ObservedUtc=[DateTime]::UtcNow.ToString('o');CandidateProcessId=$CandidateProcessId;SessionId=$SessionId;ExpectedTitle=$expectedTitle;ExpectedBody=$expectedBody;Matches=@($matches.ToArray());SurfaceObserved=($matches.Count -eq 1)}
}

function Save-WorkerDesktopScreenshot([string]$Path) {
  Add-Type -AssemblyName System.Drawing -ErrorAction Stop
  $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
  if ($bounds.Width -lt 800 -or $bounds.Height -lt 500 -or $bounds.Width -gt 8000 -or $bounds.Height -gt 5000) { throw 'BLOCKED: remote session desktop bounds are not safely capturable.' }
  $bitmap = [Drawing.Bitmap]::new($bounds.Width,$bounds.Height)
  $graphics = [Drawing.Graphics]::FromImage($bitmap)
  try {
    $graphics.CopyFromScreen($bounds.Left,$bounds.Top,0,0,$bitmap.Size)
    $bitmap.Save($Path,[Drawing.Imaging.ImageFormat]::Png)
  } finally { $graphics.Dispose();$bitmap.Dispose() }
  [pscustomobject]@{Path=$Path;Width=$bounds.Width;Height=$bounds.Height;VirtualScreen=@($bounds.Left,$bounds.Top,$bounds.Width,$bounds.Height);Capture='fresh isolated loopback RDP user desktop'}
}

function Save-WorkerState([string]$State,$Details) {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  Write-AtomicJson ([string]$script:WorkerConfig.StatePath) ([ordered]@{
    Requirement='ENV-006';Status=$State;Details=$Details;User=$identity.Name;UserSid=$identity.User.Value
    WorkerSessionId=(Get-Process -Id $PID).SessionId;ExpectedSessionId=[int]$script:WorkerConfig.SessionId
    CandidateArtifactId=$CandidateArtifactId;CandidateSHA256=$ExpectedCandidateSHA256
    Events=@($script:WorkerEvents);UpdatedUtc=[DateTime]::UtcNow.ToString('o')
  })
}

function Run-Worker {
  $script:WorkerConfig = Get-Content -LiteralPath $WorkerConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
  $script:WorkerEvents = [System.Collections.Generic.List[object]]::new()
  $script:WorkerForm = $null
  $script:WorkerProcess = $null
  $script:WorkerPid = 0
  $script:WorkerState = 'STARTING'
  try {
    Initialize-NativeTypes
    Initialize-WorkerTypes
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ($identity.User.Value -cne [string]$script:WorkerConfig.UserSid -or $identity.Name -ine [string]$script:WorkerConfig.User) { throw 'BLOCKED: worker identity is not the generated standard RDP user.' }
    if ((Get-Process -Id $PID).SessionId -ne [int]$script:WorkerConfig.SessionId -or -not [Environment]::UserInteractive) { throw 'BLOCKED: worker is not interactive in the expected RDP session.' }
    if ([string]$script:WorkerConfig.RunnerEnvironment -cne 'github-hosted' -or [string]$script:WorkerConfig.RunnerEnvironmentContext -cne 'github-hosted' -or [string]$script:WorkerConfig.RunnerOS -cne 'Windows' -or [string]$script:WorkerConfig.RunnerArch -cne 'X64' -or [string]$script:WorkerConfig.RunId -notmatch '^[0-9]+$') { throw 'BLOCKED: controller-attested runner context does not prove a GitHub-hosted Windows x64 job.' }
    $workerOs = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    if ($workerOs.Caption -notmatch 'Windows Server 2025' -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -ne 'X64' -or [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString() -ne 'X64') { throw 'BLOCKED: worker is not on native x64 Windows Server 2025.' }
    $ownSession = @([EBR_ENV006_NATIVE]::EnumerateSessions() | Where-Object { $_.SessionId -eq (Get-Process -Id $PID).SessionId } | Select-Object -First 1)
    $expectedUserOnly = ([string]$script:WorkerConfig.User -split '\\')[-1]
    if (-not $ownSession.Count -or $ownSession[0].Station -notmatch '^rdp-tcp#' -or $ownSession[0].UserOnly -ine $expectedUserOnly) { throw 'BLOCKED: worker is not in the generated temporary RDP session.' }
    if ([EBR_ENV006_NATIVE]::InputDesktopName() -ine 'Default') { throw 'BLOCKED: worker did not start on the Default input desktop.' }
    $candidatePath = [IO.Path]::GetFullPath([string]$script:WorkerConfig.CandidatePath)
    if ((Get-FileHash -LiteralPath $candidatePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ExpectedCandidateSHA256) { throw 'BLOCKED: staged executable does not match the authoritative candidate hash.' }
    $dataDirectory = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'EyeBreakReminder'
    if (Test-Path -LiteralPath $dataDirectory) { throw 'BLOCKED: temporary account already has application data; refusing to overwrite it.' }
    [void][IO.Directory]::CreateDirectory($dataDirectory)
    $settings = @('workMinutes=1','breakSeconds=30','sound=0','volume=0','alarm=0','repeat=0','notifications=1','autoStart=1','startup=0','tray=1','trayExplained=1','pauseLocked=1','restore=0','autoCheckUpdates=0','autoDownloadUpdates=0','schedule=0') -join [Environment]::NewLine
    $settingsPath = Join-Path $dataDirectory 'settings.ini'
    [IO.File]::WriteAllText($settingsPath,$settings + [Environment]::NewLine,[Text.UTF8Encoding]::new($false))
    $settingsHash = (Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $script:WorkerEvents.Add([pscustomobject]@{Name='Seed clean temporary-user one-minute timer profile';Status='PASS';Details=[pscustomobject]@{SettingsSHA256=$settingsHash;WorkMinutes=1;BreakSeconds=30;AutoStart=1;Tray=1;TrayExplained=1;PauseLocked=1;Alarm=0;Volume=0;Notifications=1;Schedule=0};Utc=[DateTime]::UtcNow.ToString('o')})

    $script:WorkerForm = [EBR_ENV006_WTS_FORM]::new()
    if (-not $script:WorkerForm.RegisterChanges()) { throw 'BLOCKED: WTS session notifications could not be registered.' }
    $script:WorkerProcess = Start-Process -FilePath $candidatePath -PassThru -ErrorAction Stop
    $script:WorkerPid = [int]$script:WorkerProcess.Id
    $launch = [Diagnostics.Stopwatch]::StartNew()
    $timer = $null
    while ($launch.Elapsed.TotalSeconds -lt 45 -and -not $timer) {
      [System.Windows.Forms.Application]::DoEvents()
      if ($script:WorkerProcess.HasExited) { throw 'FAIL: exact production candidate exited during startup.' }
      try { $timer = Get-WorkerTimerState $script:WorkerPid $true } catch { if ($_.Exception.Message -like 'FAIL:*') { throw }; Start-Sleep -Milliseconds 200 }
    }
    if (-not $timer) { throw 'BLOCKED: candidate timer window did not appear in the new RDP session.' }
    if ($timer.StatusText -notmatch '\ARunning(?:\s|$)') { throw "FAIL: production candidate did not auto-start its timer (status='$($timer.StatusText)')." }
    if ([EBR_ENV006_NATIVE]::ForegroundProcessId() -ne [uint32]$script:WorkerPid) { throw 'BLOCKED: the exact candidate was not the foreground app before locking; refusing an unknown desktop.' }
    $progress = [Diagnostics.Stopwatch]::StartNew()
    $before = $timer.RemainingSeconds
    while ($progress.Elapsed.TotalSeconds -lt 8 -and $timer.RemainingSeconds -ge $before) {
      [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100
      $timer = Get-WorkerTimerState $script:WorkerPid
    }
    if ($timer.RemainingSeconds -ge $before) { throw 'FAIL: timer did not advance before lock.' }
    $beforeLock = Get-WorkerTimerState $script:WorkerPid $true
    if ($beforeLock.StatusText -notmatch '\ARunning(?:\s|$)' -or $beforeLock.HandleCount -le 0 -or $beforeLock.ThreadCount -le 0) { throw 'FAIL: candidate state/resource baseline was invalid before lock.' }
    $script:WorkerEvents.Add([pscustomobject]@{Name='Exact candidate timer advances before lock and initial process resources are sampled';Status='PASS';Details=$beforeLock;Utc=[DateTime]::UtcNow.ToString('o')})

    $mainWindow=[IntPtr]::new([Convert]::ToInt64(([string]$beforeLock.WindowHandle).Substring(2),16))
    if (-not [EBR_ENV006_NATIVE]::PostMessageW($mainWindow,0x0010,[IntPtr]::Zero,[IntPtr]::Zero)) { throw 'BLOCKED: could not send WM_CLOSE to the candidate main window to enable its real tray notification path.' }
    $hideWatch=[Diagnostics.Stopwatch]::StartNew();$hiddenState=$null
    while ($hideWatch.Elapsed.TotalSeconds -lt 5) {
      [System.Windows.Forms.Application]::DoEvents()
      $hiddenState=Get-WorkerTimerState $script:WorkerPid $true $true
      if (-not $hiddenState.WindowVisible) { break }
      Start-Sleep -Milliseconds 100
    }
    if (-not $hiddenState -or $hiddenState.WindowVisible -or $hiddenState.StatusText -notmatch '\ARunning(?:\s|$)') { throw 'BLOCKED: candidate did not close to its tray while preserving the running timer.' }
    $script:WorkerEvents.Add([pscustomobject]@{Name='Hide main window through the candidate close-to-tray behavior for a genuine Shell reminder';Status='PASS';Details=$hiddenState;Utc=[DateTime]::UtcNow.ToString('o')})

    if (-not [EBR_ENV006_NATIVE]::LockWorkStation()) { throw 'BLOCKED: LockWorkStation failed in the isolated RDP session.' }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $lockEvent = $false; $lockEventAt = ''; $desktop = ''; $lockedTimer = $null
    while ($watch.Elapsed.TotalSeconds -lt 25 -and (-not $lockEvent -or $desktop -ine 'Winlogon' -or -not $lockedTimer -or $lockedTimer.StatusText -notmatch '\APaused(?:\s|$)')) {
      [System.Windows.Forms.Application]::DoEvents()
      foreach ($change in @($script:WorkerForm.Changes)) {
        if (-not $lockEvent -and $change[0] -eq 7 -and $change[1] -eq [int]$script:WorkerConfig.SessionId) {
          $lockEvent = $true;$lockEventAt=[DateTime]::UtcNow.ToString('o')
          $script:WorkerEvents.Add([pscustomobject]@{Name='WTS_SESSION_LOCK';Status='OBSERVED';Details=[pscustomobject]@{EventCode=7;SessionId=[int]$change[1]};Utc=$lockEventAt})
        }
      }
      $desktop = [EBR_ENV006_NATIVE]::InputDesktopName()
      if ($desktop -ieq 'Winlogon') {
        $lockedTimer = Get-WorkerTimerState $script:WorkerPid $true $true
        if ($lockedTimer.StatusText -notmatch '\APaused(?:\s|$)') { Start-Sleep -Milliseconds 200 }
      }
      Start-Sleep -Milliseconds 100
    }
    if (-not $lockEvent -or $desktop -ine 'Winlogon') { throw "BLOCKED: lock proof incomplete (WTS_SESSION_LOCK=$lockEvent; input desktop='$desktop')." }
    if (-not $lockedTimer -or $lockedTimer.StatusText -notmatch '\APaused(?:\s|$)') { throw "FAIL: candidate did not pause when Windows locked (status='$($lockedTimer.StatusText)')." }
    $lockTime = [DateTime]::UtcNow
    $lockedSeconds = $lockedTimer.RemainingSeconds
    $lockDetails = [pscustomobject]@{SessionId=[int]$script:WorkerConfig.SessionId;WtsLockEvent=$true;WtsLockEventUtc=$lockEventAt;InputDesktop=$desktop;Candidate=$lockedTimer;BeforeLockSeconds=$beforeLock.RemainingSeconds;LockedSeconds=$lockedSeconds;LockObservedUtc=$lockTime.ToString('o')}
    $script:WorkerState = 'LOCKED'
    $script:WorkerEvents.Add([pscustomobject]@{Name='WTS_SESSION_LOCK and Winlogon input desktop verified';Status='PASS';Details=$lockDetails;Utc=$lockTime.ToString('o')})
    Save-WorkerState 'LOCKED' $lockDetails

    $unlockWatch = [Diagnostics.Stopwatch]::StartNew()
    $unlockEvent = $false; $unlockEventAt = ''; $unlockDesktop = ''; $saveWatch = [Diagnostics.Stopwatch]::StartNew()
    while ($unlockWatch.Elapsed.TotalSeconds -lt 100 -and (-not $unlockEvent -or $unlockDesktop -ine 'Default')) {
      [System.Windows.Forms.Application]::DoEvents()
      foreach ($change in @($script:WorkerForm.Changes)) {
        if (-not $unlockEvent -and $change[0] -eq 8 -and $change[1] -eq [int]$script:WorkerConfig.SessionId) {
          $unlockEvent = $true;$unlockEventAt=[DateTime]::UtcNow.ToString('o')
          $script:WorkerEvents.Add([pscustomobject]@{Name='WTS_SESSION_UNLOCK';Status='OBSERVED';Details=[pscustomobject]@{EventCode=8;SessionId=[int]$change[1]};Utc=$unlockEventAt})
        }
      }
      $unlockDesktop = [EBR_ENV006_NATIVE]::InputDesktopName()
      if ($unlockDesktop -ieq 'Winlogon') {
        $lockedNow = Get-WorkerTimerState $script:WorkerPid $false $true
        if ($lockedNow.StatusText -notmatch '\APaused(?:\s|$)' -or [Math]::Abs($lockedNow.RemainingSeconds - $lockedSeconds) -gt 1) { throw 'FAIL: paused timer changed while the session remained locked.' }
        if ($saveWatch.ElapsedMilliseconds -ge 500) { Save-WorkerState 'LOCKED' $lockDetails; $saveWatch.Restart() }
      }
      Start-Sleep -Milliseconds 100
    }
    if (-not $unlockEvent -or $unlockDesktop -ine 'Default') { throw "BLOCKED: unlock proof incomplete (WTS_SESSION_UNLOCK=$unlockEvent; input desktop='$unlockDesktop')." }
    $resumeStateWatch = [Diagnostics.Stopwatch]::StartNew()
    $after = $null
    while ($resumeStateWatch.Elapsed.TotalSeconds -lt 10 -and (-not $after -or $after.StatusText -notmatch '\ARunning(?:\s|$)')) {
      [System.Windows.Forms.Application]::DoEvents()
      $after = Get-WorkerTimerState $script:WorkerPid $true $true
      if ($after.StatusText -notmatch '\ARunning(?:\s|$)') { Start-Sleep -Milliseconds 200 }
    }
    if (-not $after -or $after.StatusText -notmatch '\ARunning(?:\s|$)') { throw "FAIL: candidate did not resume after unlock (status='$($after.StatusText)')." }
    if ([Math]::Abs($after.RemainingSeconds - $lockedSeconds) -gt 1) { throw 'FAIL: candidate did not preserve its remaining time through the lock.' }
    $resume = [Diagnostics.Stopwatch]::StartNew(); $later = $after
    while ($resume.Elapsed.TotalSeconds -lt 8 -and $later.RemainingSeconds -ge $after.RemainingSeconds) {
      [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100
      $later = Get-WorkerTimerState $script:WorkerPid $false $true
    }
    if ($later.RemainingSeconds -ge $after.RemainingSeconds) { throw 'FAIL: candidate timer did not advance after unlock.' }
    $resourceSamples=[System.Collections.Generic.List[object]]::new()
    foreach ($sampleRow in @(
      [pscustomobject]@{Stage='before-lock';Sample=$beforeLock},
      [pscustomobject]@{Stage='hidden-before-lock';Sample=$hiddenState},
      [pscustomobject]@{Stage='locked';Sample=$lockedTimer},
      [pscustomobject]@{Stage='after-unlock';Sample=$after},
      [pscustomobject]@{Stage='timer-advancing-after-unlock';Sample=$later}
    )) {
      $sample=$sampleRow.Sample
      if (-not $sample) { $resourceSamples.Add([pscustomobject]@{Stage=$sampleRow.Stage;Missing=$true});continue }
      $resourceSamples.Add([pscustomobject]@{Stage=$sampleRow.Stage;ProcessId=$sample.ProcessId;HandleCount=$sample.HandleCount;ThreadCount=$sample.ThreadCount;WorkingSetBytes=$sample.WorkingSetBytes;RemainingSeconds=$sample.RemainingSeconds;StatusText=$sample.StatusText;Missing=([int]$sample.HandleCount -le 0 -or [int]$sample.ThreadCount -le 0 -or [long]$sample.WorkingSetBytes -le 0)})
    }
    $reminderWatch=[Diagnostics.Stopwatch]::StartNew();$breakState=$null;$shellNotification=$null;$desktopScreenshot=$null;$timerAtReminder=$null
    $screenshotPath=Join-Path (Split-Path -LiteralPath ([string]$script:WorkerConfig.StatePath) -Parent) 'shell-notification-desktop.png'
    while ($reminderWatch.Elapsed.TotalSeconds -lt 95 -and -not ($breakState -and $shellNotification -and $shellNotification.SurfaceObserved -and $desktopScreenshot)) {
      [System.Windows.Forms.Application]::DoEvents()
      $timerAtReminder=Get-WorkerTimerState $script:WorkerPid $false $true
      if ($timerAtReminder.StatusText -match '\ATaking an eye break\z') {
        $breakState=Get-WorkerBreakWindow $script:WorkerPid
        if ($breakState) {
          $shellNotification=Get-WorkerShellNotification ([int]$script:WorkerConfig.SessionId) $script:WorkerPid
          if ($shellNotification.SurfaceObserved -and -not $desktopScreenshot) {
            $desktopScreenshot=Save-WorkerDesktopScreenshot $screenshotPath
            $confirmShell=Get-WorkerShellNotification ([int]$script:WorkerConfig.SessionId) $script:WorkerPid
            if (-not $confirmShell.SurfaceObserved -or $confirmShell.Matches[0].Handle -cne $shellNotification.Matches[0].Handle -or $confirmShell.Matches[0].ProcessId -ne $shellNotification.Matches[0].ProcessId) {
              throw 'BLOCKED: the exact natural Shell notification was not still exposed by the same Shell window after desktop capture.'
            }
            $shellNotification=[pscustomobject]@{SurfaceObserved=$true;Initial=$shellNotification;AfterDesktopCapture=$confirmShell;SameVisibleWindow=$true}
          }
        }
      }
      if (-not ($breakState -and $shellNotification -and $shellNotification.SurfaceObserved -and $desktopScreenshot)) { Start-Sleep -Milliseconds 300 }
    }
    if (-not $breakState) { throw 'BLOCKED: the exact candidate did not expose its real break reminder window after the one-minute work timer.' }
    if (-not $shellNotification -or -not $shellNotification.SurfaceObserved -or -not $desktopScreenshot) { throw 'BLOCKED: Windows Shell UI Automation did not expose the natural reminder title and body in a visible Shell notification.' }
    if (-not $timerAtReminder -or $timerAtReminder.StatusText -notmatch '\ATaking an eye break\z') { throw 'BLOCKED: candidate timer state was unavailable at the reminder.' }
    $resourceSamples.Add([pscustomobject]@{Stage='break-reminder';ProcessId=$timerAtReminder.ProcessId;HandleCount=$timerAtReminder.HandleCount;ThreadCount=$timerAtReminder.ThreadCount;WorkingSetBytes=$timerAtReminder.WorkingSetBytes;RemainingSeconds=$timerAtReminder.RemainingSeconds;StatusText=$timerAtReminder.StatusText;Missing=([int]$timerAtReminder.HandleCount -le 0 -or [int]$timerAtReminder.ThreadCount -le 0 -or [long]$timerAtReminder.WorkingSetBytes -le 0)})
    # Allow one genuine tray-to-break UI lifecycle: up to 16 additional process
    # handles, 2 threads, and 32 MiB of working-set growth versus the pre-lock
    # baseline. All samples must belong to the same candidate PID and remain inside
    # these one-cycle limits; this is a bounded regression check, not a long soak.
    $resourceLimits=[pscustomobject]@{MaximumHandleGrowth=16;MaximumThreadGrowth=2;MaximumWorkingSetGrowthBytes=33554432;Comparison='positive growth from before-lock baseline at each lifecycle sample';Scope='one lock/unlock and one natural reminder cycle'}
    $resourceComparisons=[System.Collections.Generic.List[object]]::new();$resourceMissing=[System.Collections.Generic.List[string]]::new()
    $baselineRow=@($resourceSamples | Where-Object {$_.Stage -ceq 'before-lock'} | Select-Object -First 1)
    if (-not $baselineRow.Count -or $baselineRow[0].Missing) { $resourceMissing.Add('before-lock baseline') }
    else {
      $baseline=$baselineRow[0]
      foreach($stage in @('locked','after-unlock','timer-advancing-after-unlock','break-reminder')) {
        $sampleRows=@($resourceSamples | Where-Object {$_.Stage -ceq $stage} | Select-Object -First 1)
        if (-not $sampleRows.Count -or $sampleRows[0].Missing) { $resourceMissing.Add($stage);continue }
        $sample=$sampleRows[0]
        if ([int]$sample.ProcessId -ne [int]$baseline.ProcessId) { $resourceMissing.Add("$stage (candidate PID changed)");continue }
        $handleDelta=[int]$sample.HandleCount-[int]$baseline.HandleCount
        $threadDelta=[int]$sample.ThreadCount-[int]$baseline.ThreadCount
        $workingSetDelta=[long]$sample.WorkingSetBytes-[long]$baseline.WorkingSetBytes
        $resourceComparisons.Add([pscustomobject]@{Stage=$stage;ProcessId=$sample.ProcessId;BaselineHandleCount=$baseline.HandleCount;ObservedHandleCount=$sample.HandleCount;HandleDelta=$handleDelta;BaselineThreadCount=$baseline.ThreadCount;ObservedThreadCount=$sample.ThreadCount;ThreadDelta=$threadDelta;BaselineWorkingSetBytes=$baseline.WorkingSetBytes;ObservedWorkingSetBytes=$sample.WorkingSetBytes;WorkingSetDeltaBytes=$workingSetDelta;PositiveWorkingSetGrowthBytes=[Math]::Max([long]0,$workingSetDelta)})
      }
    }
    $resourceExcess=@($resourceComparisons | Where-Object {$_.HandleDelta -gt $resourceLimits.MaximumHandleGrowth -or $_.ThreadDelta -gt $resourceLimits.MaximumThreadGrowth -or $_.PositiveWorkingSetGrowthBytes -gt $resourceLimits.MaximumWorkingSetGrowthBytes})
    $resourceStatus=if($resourceMissing.Count){'BLOCKED'}elseif($resourceExcess.Count){'FAIL'}else{'PASS'}
    $resourceStability=[pscustomobject]@{Status=$resourceStatus;Baseline=if($baselineRow.Count){$baselineRow[0]}else{$null};Limits=$resourceLimits;Comparisons=@($resourceComparisons.ToArray());Missing=@($resourceMissing.ToArray());Exceeded=@($resourceExcess);AllSamples=@($resourceSamples.ToArray())}
    $script:WorkerEvents.Add([pscustomobject]@{Name='Bounded candidate resource stability versus the pre-lock baseline';Status=$resourceStatus;Details=$resourceStability;Utc=[DateTime]::UtcNow.ToString('o')})
    if ($resourceMissing.Count) { throw "BLOCKED: candidate resource stability comparison lacks required samples: $($resourceMissing -join ', ')." }
    if ($resourceExcess.Count) { throw "FAIL: candidate resource growth exceeded the one-cycle caps (handles +$($resourceLimits.MaximumHandleGrowth), threads +$($resourceLimits.MaximumThreadGrowth), working set +$($resourceLimits.MaximumWorkingSetGrowthBytes) bytes)." }
    if (-not (Test-Path -LiteralPath $screenshotPath -PathType Leaf)) { throw 'BLOCKED: desktop screenshot of the actual Shell reminder is missing.' }
    $script:WorkerEvents.Add([pscustomobject]@{Name='Actual one-minute timer produced a visible candidate break window and natural Windows Shell notification';Status='PASS';Details=[pscustomobject]@{WorkTimer=$timerAtReminder;BreakWindow=$breakState;ShellNotification=$shellNotification;DesktopScreenshot=$desktopScreenshot;AlarmMuted=$true};Utc=[DateTime]::UtcNow.ToString('o')})
    $finalHash = (Get-FileHash -LiteralPath $candidatePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($finalHash -cne $ExpectedCandidateSHA256) { throw 'BLOCKED: exact candidate file changed during the test.' }
    $final = [pscustomobject]@{
      LockEvent=$lockEvent;LockEventUtc=$lockEventAt;UnlockEvent=$unlockEvent;UnlockEventUtc=$unlockEventAt;InputDesktopAfterUnlock=$unlockDesktop
      LockDurationSeconds=[Math]::Round(([DateTime]::UtcNow-$lockTime).TotalSeconds,2)
      BeforeLockSeconds=$beforeLock.RemainingSeconds;LockedSeconds=$lockedSeconds
      AfterUnlockSeconds=$after.RemainingSeconds;LaterSeconds=$later.RemainingSeconds
      CandidateProcessId=$script:WorkerPid;CandidatePath=$candidatePath;CandidateSHA256=$finalHash
      SessionId=$after.SessionId;UserSid=$identity.User.Value;SettingsSHA256=$settingsHash;NativeProcessX64=$true
      ReminderWindow=$breakState;ShellNotification=$shellNotification;DesktopScreenshot=$desktopScreenshot;ResourceStability=$resourceStability;ResourceSamples=@($resourceSamples.ToArray())
    }
    $script:WorkerState = 'PASS'
    $script:WorkerEvents.Add([pscustomobject]@{Name='Same candidate process/session resumed, advanced, produced the actual one-minute reminder, and supplied handle/thread samples';Status='PASS';Details=$final;Utc=[DateTime]::UtcNow.ToString('o')})
    Save-WorkerState 'PASS' $final
  } catch {
    $failure = $_.Exception.Message
    $script:WorkerState = if ($failure -like 'FAIL:*') { 'FAIL' } else { 'BLOCKED' }
    $script:WorkerEvents.Add([pscustomobject]@{Name='ENV-006 RDP worker';Status=$script:WorkerState;Details=$failure;Utc=[DateTime]::UtcNow.ToString('o')})
    try { Save-WorkerState $script:WorkerState ([pscustomobject]@{Failure=$failure;CandidateProcessId=$script:WorkerPid}) } catch {}
  } finally {
    if ($script:WorkerForm) { try { $script:WorkerForm.UnregisterChanges();$script:WorkerForm.Close();$script:WorkerForm.Dispose() } catch {} }
  }
  if ($script:WorkerState -eq 'PASS') { exit 0 }
  exit 1
}

function Add-Event([string]$Name,[string]$Status,$Details = $null) {
  $script:Events.Add([pscustomobject]@{Name=$Name;Status=$Status;Details=$Details;Utc=[DateTime]::UtcNow.ToString('o')})
}
function Read-RegistryValue([string]$Path,[string]$Name) {
  try { (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name } catch { $null }
}
function Get-RuleRemoteAddresses($Rule) {
  $filter=Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $Rule -ErrorAction Stop
  @($filter.RemoteAddress | ForEach-Object {[string]$_})
}
function Get-RuleLocalAddresses($Rule) {
  $filter=Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $Rule -ErrorAction Stop
  @($filter.LocalAddress | ForEach-Object {[string]$_})
}
function Get-ActiveFirewallRules {
  @(Get-NetFirewallRule -PolicyStore ActiveStore -TracePolicyStore -ErrorAction Stop)
}
function Get-GroupPolicyAllowSignatures {
  $rows=[System.Collections.Generic.List[string]]::new()
  foreach($rule in @(Get-ActiveFirewallRules | Where-Object {$_.Direction -eq 'Inbound' -and $_.Action -eq 'Allow' -and $_.Enabled -eq 'True' -and $_.PolicyStoreSourceType -eq 'GroupPolicy'})) {
    $addresses=Get-RuleRemoteAddresses $rule
    $rows.Add("$($rule.Name)|$($rule.PolicyStoreSource)|$($rule.Profile)|$($rule.Enabled)|$($addresses -join ',')")
  }
  @($rows.ToArray() | Sort-Object)
}
function Initialize-DisposableRunnerFirewall {
  $enabledParameterType=(Get-Command Set-NetFirewallProfile -ErrorAction Stop).Parameters['Enabled'].ParameterType
  if (-not $enabledParameterType.IsEnum) { throw "BLOCKED: Set-NetFirewallProfile -Enabled is not an enum on this runner ($($enabledParameterType.FullName))." }
  $script:FirewallEnabledParameterType=$enabledParameterType
  $script:FirewallProfilesSnapshot=@(Get-NetFirewallProfile -ErrorAction Stop | ForEach-Object {
    $enabledName=[string]$_.Enabled
    if ($enabledName -notin @('True','False','NotConfigured')) { throw "BLOCKED: unsupported firewall Enabled value '$enabledName' for profile '$($_.Name)' before isolation." }
    [void][Enum]::Parse($enabledParameterType,$enabledName,$true)
    [pscustomobject]@{Name=[string]$_.Name;Enabled=$enabledName;DefaultInboundAction=[string]$_.DefaultInboundAction}
  })
  if (-not $script:FirewallProfilesSnapshot.Count) { throw 'BLOCKED: no firewall profile state could be snapshotted.' }
  $rules=Get-ActiveFirewallRules
  $activeAllows=@($rules | Where-Object {$_.Direction -eq 'Inbound' -and $_.Action -eq 'Allow' -and $_.Enabled -eq 'True'})
  $script:FirewallLocalAllowsSnapshot=[System.Collections.Generic.List[object]]::new()
  $script:FirewallGroupPolicySnapshot=@()
  foreach($rule in $activeAllows) {
    $source=[string]$rule.PolicyStoreSourceType
    if ($source -eq 'Local') {
      $script:FirewallLocalAllowsSnapshot.Add([pscustomobject]@{Name=[string]$rule.Name;Source=[string]$rule.PolicyStoreSource;Rule=$rule})
      continue
    }
    if ($source -ne 'GroupPolicy') { throw "BLOCKED: enabled inbound Allow rule '$($rule.Name)' has unchangeable or unknown source '$source'; the disposable host cannot be secured fail-closed." }
    $addresses=Get-RuleRemoteAddresses $rule
    if (-not $addresses.Count -or @($addresses | Where-Object {$_ -notin @('127.0.0.1','::1','127.0.0.0/8','::1/128')}).Count -gt 0) {
      throw "BLOCKED: Group Policy inbound Allow rule '$($rule.Name)' is not provably loopback-only; policy will not be modified."
    }
  }
  $script:FirewallGroupPolicySnapshot=Get-GroupPolicyAllowSignatures
  $script:FirewallSnapshotComplete=$true
  $script:FirewallProfilesModified=$true
  foreach($profile in $script:FirewallProfilesSnapshot) {
    Set-NetFirewallProfile -Profile $profile.Name -Enabled True -DefaultInboundAction Block -ErrorAction Stop | Out-Null
  }
  foreach($entry in $script:FirewallLocalAllowsSnapshot) {
    $script:FirewallLocalAllowsChanged.Add($entry)
    Disable-NetFirewallRule -InputObject $entry.Rule -ErrorAction Stop | Out-Null
  }
  $verifiedProfiles=@(Get-NetFirewallProfile -ErrorAction Stop)
  foreach($profile in $verifiedProfiles) {
    if (-not $profile.Enabled -or [string]$profile.DefaultInboundAction -ne 'Block') { throw "BLOCKED: disposable runner firewall profile '$($profile.Name)' did not enter enabled/default-inbound-block state." }
  }
  $remainingLocal=@(Get-ActiveFirewallRules | Where-Object {$_.Direction -eq 'Inbound' -and $_.Action -eq 'Allow' -and $_.Enabled -eq 'True' -and $_.PolicyStoreSourceType -eq 'Local'})
  if ($remainingLocal.Count) { throw 'BLOCKED: one or more local inbound Allow rules remain enabled after runner isolation.' }
  if ((Get-GroupPolicyAllowSignatures) -join "`n" -cne ($script:FirewallGroupPolicySnapshot -join "`n")) { throw 'BLOCKED: Group Policy firewall rules changed while establishing the isolated loopback test.' }
  Add-Event 'Snapshot and temporarily secure only the disposable hosted runner firewall' 'PASS' ([pscustomobject]@{Profiles=$script:FirewallProfilesSnapshot;DisabledLocalInboundAllowRules=@($script:FirewallLocalAllowsSnapshot | ForEach-Object {$_.Name});UnchangedGroupPolicyInboundAllows=$script:FirewallGroupPolicySnapshot;DefaultInboundAction='Block';EnabledProfiles=$true})
}
function Restore-DisposableRunnerFirewall {
  if ($script:FirewallCreated) {
    $temporary=@(Get-NetFirewallRule -Name $script:FirewallName -ErrorAction SilentlyContinue)
    if ($temporary.Count) { Remove-NetFirewallRule -InputObject $temporary -ErrorAction Stop }
    $script:FirewallCreated=$false
  }
  foreach($entry in $script:FirewallLocalAllowsChanged) {
    $current=@(Get-ActiveFirewallRules | Where-Object {$_.Name -ceq $entry.Name -and $_.PolicyStoreSourceType -eq 'Local'})
    if ($current.Count -ne 1) { throw "Unable to identify exactly one original local firewall rule '$($entry.Name)' for restoration." }
    if ($current[0].Enabled -ne 'True') { Enable-NetFirewallRule -InputObject $current[0] -ErrorAction Stop | Out-Null }
  }
  if ($script:FirewallProfilesModified) {
    foreach($profile in $script:FirewallProfilesSnapshot) {
      $enabledValue=[Enum]::Parse($script:FirewallEnabledParameterType,[string]$profile.Enabled,$true)
      Set-NetFirewallProfile -Profile $profile.Name -Enabled $enabledValue -DefaultInboundAction $profile.DefaultInboundAction -ErrorAction Stop | Out-Null
    }
  }
  if ($script:FirewallSnapshotComplete) {
    $restoredProfiles=@(Get-NetFirewallProfile -ErrorAction Stop)
    foreach($saved in $script:FirewallProfilesSnapshot) {
      $current=@($restoredProfiles | Where-Object {$_.Name -ceq $saved.Name})
      $restoredEnabled=if($current.Count){([string]$current[0].Enabled).Trim()}else{''}
      if ($current.Count -ne 1 -or $restoredEnabled -ine [string]$saved.Enabled -or [string]$current[0].DefaultInboundAction -ne $saved.DefaultInboundAction) { throw "Firewall profile '$($saved.Name)' did not restore to its snapshotted values." }
    }
    foreach($entry in $script:FirewallLocalAllowsSnapshot) {
      $current=@(Get-ActiveFirewallRules | Where-Object {$_.Name -ceq $entry.Name -and $_.PolicyStoreSourceType -eq 'Local'})
      if ($current.Count -ne 1 -or $current[0].Enabled -ne 'True') { throw "Original local inbound Allow rule '$($entry.Name)' was not restored enabled." }
    }
    if ((Get-GroupPolicyAllowSignatures) -join "`n" -cne ($script:FirewallGroupPolicySnapshot -join "`n")) { throw 'Group Policy firewall Allow rules differ from their original snapshot.' }
    if (@(Get-ActiveFirewallRules | Where-Object {$_.Name -ceq $script:FirewallName}).Count) { throw 'Temporary loopback RDP firewall rule remained after cleanup.' }
  }
  Add-Event 'Restore and verify disposable runner firewall profiles and rules' 'PASS' ([pscustomobject]@{Profiles=$script:FirewallProfilesSnapshot;RestoredLocalInboundAllowRules=@($script:FirewallLocalAllowsSnapshot | ForEach-Object {$_.Name});GroupPolicyUnchanged=$true;TemporaryLoopbackRuleAbsent=$true})
}
function Get-SessionRows { @([EBR_ENV006_NATIVE]::EnumerateSessions()) }
function Find-TestSession([string]$UserName,[int]$Id = -1) {
  foreach ($row in Get-SessionRows) {
    if ($row.UserOnly -ieq $UserName -and ($Id -lt 0 -or $row.SessionId -eq $Id) -and $row.Station -match '^rdp-tcp#') { return $row }
  }
  $null
}
function Wait-TestSession([string]$UserName,[int]$Id,[string[]]$States,[int]$Seconds) {
  $watch=[Diagnostics.Stopwatch]::StartNew()
  while ($watch.Elapsed.TotalSeconds -lt $Seconds) {
    $row=Find-TestSession $UserName $Id
    if ($row -and $States -contains $row.State) { return $row }
    Start-Sleep -Milliseconds 250
  }
  $null
}
function Add-TemporaryCredential([string]$Target,[string]$User,[Security.SecureString]$Password) {
  $memory=[Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($Password)
  try {
    $credential=[EBR_ENV006_CREDENTIAL]::new()
    $credential.Type=2;$credential.TargetName=$Target;$credential.CredentialBlob=$memory
    $credential.CredentialBlobSize=[uint32](($Password.Length+1)*2);$credential.Persist=1;$credential.UserName=$User
    if (-not [EBR_ENV006_CREDMAN]::Write([ref]$credential,0)) { throw "CredWrite failed with Win32 $([Runtime.InteropServices.Marshal]::GetLastWin32Error())." }
  } finally { [Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($memory) }
}
function Remove-TemporaryCredential([string]$Target) {
  if (-not [EBR_ENV006_CREDMAN]::Delete($Target,2,0)) {
    $code=[Runtime.InteropServices.Marshal]::GetLastWin32Error()
    if ($code -ne 1168) { throw "CredDelete failed with Win32 $code." }
  }
}
function Find-OwnedMstscWindow([int[]]$ProcessIds) {
  $windows=@([EBR_ENV006_NATIVE]::EnumerateWindows())
  $found=@($windows | Where-Object {
    $_.Visible -and -not $_.Minimized -and $_.Width -ge 640 -and $_.Height -ge 400 -and
    $ProcessIds -contains [int]$_.ProcessId -and
    ($_.ClassName -eq 'TscShellContainerClass' -or $_.Title -match '127\.0\.0\.1')
  })
  if ($found.Count -ne 1) { return $null }
  $found[0]
}
function Focus-AndVerifyMstsc([int]$ProcessId,$Window) {
  if (-not $Window -or [int]$Window.ProcessId -ne $ProcessId) { throw 'BLOCKED: RDP window identity changed.' }
  if ([EBR_ENV006_NATIVE]::InputDesktopName() -ine 'Default') { throw 'BLOCKED: controller is not on its own Default desktop.' }
  if ($Window.Minimized) { [void][EBR_ENV006_NATIVE]::ShowWindowAsync([IntPtr]$Window.Handle,9) }
  [void][EBR_ENV006_NATIVE]::SetForegroundWindow([IntPtr]$Window.Handle)
  $watch=[Diagnostics.Stopwatch]::StartNew()
  do {
    $current=@([EBR_ENV006_NATIVE]::EnumerateWindows() | Where-Object { $_.Handle -eq $Window.Handle } | Select-Object -First 1)
    if ($current.Count -and $current[0].Visible -and -not $current[0].Minimized -and [EBR_ENV006_NATIVE]::ForegroundProcessId() -eq [uint32]$ProcessId) { return $current[0] }
    Start-Sleep -Milliseconds 100
  } while ($watch.Elapsed.TotalSeconds -lt 3)
  throw 'BLOCKED: owned mstsc was not foreground; no password input was sent.'
}
function Capture-MstscWindow([string]$Name,$Window) {
  Add-Type -AssemblyName System.Drawing -ErrorAction Stop
  $rect=[EBR_ENV006_NATIVE]::WindowRect([IntPtr]$Window.Handle)
  $width=$rect.Right-$rect.Left;$height=$rect.Bottom-$rect.Top
  if ($width -lt 100 -or $height -lt 100) { throw 'BLOCKED: invalid RDP window rectangle for screenshot.' }
  $bitmap=[Drawing.Bitmap]::new($width,$height);$graphics=[Drawing.Graphics]::FromImage($bitmap)
  try {
    $graphics.CopyFromScreen($rect.Left,$rect.Top,0,0,$bitmap.Size)
    $path=Join-Path $script:EvidencePath $Name
    $bitmap.Save($path,[Drawing.Imaging.ImageFormat]::Png)
    return $path
  } finally { $graphics.Dispose();$bitmap.Dispose() }
}
function Send-RdpCtrlAltEnd([int]$ProcessId) {
  $keys=[UInt16[]]@(0x11,0x12,0x23,0x23,0x12,0x11)
  $flags=[UInt32[]]@(0,0,0,2,2,2)
  [void][EBR_ENV006_NATIVE]::SendVirtualKeysToForegroundProcess([uint32]$ProcessId,$keys,$flags)
}
function Send-SecureTemporaryPassword([int]$ProcessId,[Security.SecureString]$Password) {
  if ([EBR_ENV006_NATIVE]::CapsLockIsOn()) { throw 'BLOCKED: Caps Lock is on; password input was not sent.' }
  $keys=[System.Collections.Generic.List[UInt16]]::new()
  $flags=[System.Collections.Generic.List[UInt32]]::new()
  $memory=[Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($Password)
  try {
    for ($index=0;$index -lt $Password.Length;$index++) {
      $character=[char][Runtime.InteropServices.Marshal]::ReadInt16($memory,2*$index)
      $mapping=[EBR_ENV006_NATIVE]::MapCharacter($character)
      if ($mapping -eq -1) { throw 'BLOCKED: generated password character is unavailable on the runner keyboard layout.' }
      $vk=[UInt16]($mapping -band 0xFF);$modifiers=(($mapping -shr 8)-band 0xFF)
      if (($modifiers -band 6) -ne 0) { throw 'BLOCKED: password mapping requires Ctrl or Alt; no password input was sent.' }
      if ($modifiers -band 1) { $keys.Add([UInt16]0x10);$flags.Add([UInt32]0) }
      $keys.Add($vk);$flags.Add([UInt32]0);$keys.Add($vk);$flags.Add([UInt32]2)
      if ($modifiers -band 1) { $keys.Add([UInt16]0x10);$flags.Add([UInt32]2) }
    }
    $keys.Add([UInt16]0x0D);$flags.Add([UInt32]0);$keys.Add([UInt16]0x0D);$flags.Add([UInt32]2)
    [void][EBR_ENV006_NATIVE]::SendVirtualKeysToForegroundProcess([uint32]$ProcessId,$keys.ToArray(),$flags.ToArray())
  } finally { [Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($memory) }
}
function Save-FinalEvidence([string]$Status,[string]$Reason) {
  $os=Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
  $record=[ordered]@{
    Requirement='ENV-006';Status=$Status;Reason=$Reason
    CandidateArtifactId=$CandidateArtifactId;CandidateArtifactName=$CandidateArtifactName
    CandidateArtifactRunId=$CandidateArtifactRunId;CandidateSourceCommit=$CandidateSourceCommit
    CandidateSHA256=$ExpectedCandidateSHA256;CandidateExecution='native x64'
    OS=$os.Caption;OSVersion=$os.Version;OSBuild=$os.BuildNumber
    OSArchitecture=[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    ProcessArchitecture=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
    RunnerEnvironment=$env:RUNNER_ENVIRONMENT;RunnerEnvironmentContext=$env:EBR_RUNNER_ENVIRONMENT_CONTEXT;RunnerOS=$env:RUNNER_OS
    RunnerArch=$env:RUNNER_ARCH;RunnerName=$env:RUNNER_NAME;RunnerRunId=$env:GITHUB_RUN_ID
    Environment='GitHub-hosted disposable Windows Server 2025 x64 VM; temporary standard-user loopback RDP session'
    ControllerSessionId=$script:ControllerSessionId;RdpSessionId=$script:RdpSessionId
    TemporaryUser=$script:TestUser;TemporaryUserSid=$script:TestSid
    MstscProcessIds=@($script:MstscProcessIds)
    FailureDiagnostics=$script:FailureDiagnostics
    Assertions=@($script:Events);CleanupErrors=@($script:CleanupErrors)
    ObservedUtc=[DateTime]::UtcNow.ToString('o')
  }
  Write-AtomicJson (Join-Path $script:EvidencePath 'env006-lock-unlock-results.json') $record
}

$script:Status='BLOCKED';$script:Reason='Harness did not complete.';$script:FailureDiagnostics=$null
$script:Events=[System.Collections.Generic.List[object]]::new()
$script:CleanupErrors=[System.Collections.Generic.List[string]]::new()
$script:ControllerSessionId=-1;$script:RdpSessionId=-1
$script:TestUser='';$script:TestSid='';$script:TestPrincipal=''
$script:MstscProcessIds=@();$script:StageRoot='';$script:WorkerRoot='';$script:CandidateRoot=''
$script:WorkerStatePath='';$script:WorkerConfigPath='';$script:WorkerScriptPath='';$script:RdpFile='';$script:CandidatePath=''
$script:EvidencePath='';$script:TempRoot='';$script:TaskName='';$script:FirewallName=''
$script:Password=$null;$script:CredentialWritten=$false;$script:UserCreated=$false
$script:FirewallCreated=$false;$script:FirewallSnapshotComplete=$false;$script:FirewallProfilesModified=$false
$script:FirewallEnabledParameterType=$null
$script:FirewallProfilesSnapshot=@();$script:FirewallLocalAllowsSnapshot=[System.Collections.Generic.List[object]]::new()
$script:FirewallLocalAllowsChanged=[System.Collections.Generic.List[object]]::new();$script:FirewallGroupPolicySnapshot=@()
$script:RdpSettingChanged=$false;$script:TermServiceStarted=$false
$script:TaskRegistered=$false;$script:OldRdpDeny=$null;$script:OldTermServiceState=$null
$script:OwnedMstscStartedUtc=$null;$script:SecurePassword=$null

if ($Worker) {
  Initialize-NativeTypes
  Run-Worker
  exit 1
}

. (Join-Path $PSScriptRoot 'windows_rdp_file_trust_prompt.ps1')

try {
  Initialize-NativeTypes
  if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:EBR_RUNNER_ENVIRONMENT_CONTEXT -cne 'github-hosted' -or
      $env:RUNNER_OS -cne 'Windows' -or $env:RUNNER_ARCH -cne 'X64' -or
      $env:GITHUB_RUN_ID -notmatch '^[0-9]+$' -or -not $env:RUNNER_TEMP) {
    throw 'BLOCKED: requires GitHub Actions Windows x64 with trusted runner.environment=github-hosted context.'
  }
  if (-not [Environment]::UserInteractive -or [EBR_ENV006_NATIVE]::WindowStationName() -ine 'WinSta0' -or [EBR_ENV006_NATIVE]::InputDesktopName() -ine 'Default') {
    throw 'BLOCKED: hosted controller has no usable WinSta0\\Default interactive desktop.'
  }
  $controller=[Security.Principal.WindowsIdentity]::GetCurrent()
  if (-not ([Security.Principal.WindowsPrincipal]::new($controller)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'BLOCKED: runner job lacks administrative rights for its isolated local RDP setup.' }
  $script:ControllerSessionId=(Get-Process -Id $PID -ErrorAction Stop).SessionId
  if ($script:ControllerSessionId -le 0) { throw 'BLOCKED: controller is in a service/noninteractive session.' }
  $os=Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
  if ($os.Caption -notmatch 'Windows Server 2025' -or
      [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -ne 'X64' -or
      [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString() -ne 'X64') {
    throw "BLOCKED: expected native x64 Windows Server 2025; observed '$($os.Caption)' / $([Runtime.InteropServices.RuntimeInformation]::OSArchitecture)."
  }
  if ([string]::IsNullOrWhiteSpace($CandidateExecutable) -or [string]::IsNullOrWhiteSpace($EvidenceDirectory)) { throw 'BLOCKED: controller invocation requires candidate and evidence paths.' }
  if (-not (Test-Path -LiteralPath $CandidateExecutable -PathType Leaf) -or [IO.Path]::GetFileName($CandidateExecutable) -ine $CandidateFileName) { throw 'BLOCKED: authoritative candidate executable path is missing or misnamed.' }
  if ((Get-FileHash -LiteralPath $CandidateExecutable -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ExpectedCandidateSHA256) { throw 'BLOCKED: supplied file is not the exact authoritative production candidate.' }

  $script:TempRoot=[IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')+'\'
  $tempItem=Get-Item -LiteralPath $env:RUNNER_TEMP -Force -ErrorAction Stop
  if (($tempItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'BLOCKED: RUNNER_TEMP is a reparse point.' }
  $script:EvidencePath=[IO.Path]::GetFullPath($EvidenceDirectory)
  if (-not $script:EvidencePath.StartsWith($script:TempRoot,[StringComparison]::OrdinalIgnoreCase)) { throw 'BLOCKED: evidence directory must be within RUNNER_TEMP.' }
  [void][IO.Directory]::CreateDirectory($script:EvidencePath)
  if (([IO.File]::GetAttributes($script:EvidencePath) -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or @(Get-ChildItem -LiteralPath $script:EvidencePath -Force).Count -gt 0) { throw 'BLOCKED: evidence directory must be fresh, empty, and not a reparse point.' }

  $preexistingClient=@(Get-Process -Name mstsc -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $script:ControllerSessionId })
  if ($preexistingClient.Count) { throw 'BLOCKED: existing mstsc process in controller session; refusing to take ownership.' }
  $credentialPointer=[IntPtr]::Zero
  if ([EBR_ENV006_CREDMAN]::Read($RdpCredentialTarget,2,0,[ref]$credentialPointer)) {
    [EBR_ENV006_CREDMAN]::Free($credentialPointer);throw 'BLOCKED: an existing localhost RDP credential would be overwritten.'
  }
  if ([Runtime.InteropServices.Marshal]::GetLastWin32Error() -notin @(2,1168)) { throw 'BLOCKED: existing localhost credential could not be safely queried.' }
  $rdpKey='HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
  $rdpTcpKey='HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
  $policyKey='HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
  $script:OldRdpDeny=Read-RegistryValue $rdpKey 'fDenyTSConnections'
  $oldNla=Read-RegistryValue $rdpTcpKey 'UserAuthentication'
  $policyDeny=Read-RegistryValue $policyKey 'fDenyTSConnections'
  if ($null -eq $script:OldRdpDeny -or $null -eq $oldNla -or [int]$oldNla -ne 1) { throw 'BLOCKED: RDP state is incomplete or NLA was not already enabled.' }
  if ($null -ne $policyDeny -and [int]$policyDeny -eq 1) { throw 'BLOCKED: RDP is denied by machine policy; no policy override attempted.' }
  $service=Get-Service -Name TermService -ErrorAction Stop
  $script:OldTermServiceState=$service.Status
  if ($service.StartType -eq 'Disabled') { throw 'BLOCKED: TermService is disabled by runner policy.' }
  $suffix=[guid]::NewGuid().ToString('N')
  $script:StageRoot=[IO.Path]::GetFullPath((Join-Path $env:RUNNER_TEMP "ebr-env006-$($env:GITHUB_RUN_ID)-$suffix"))
  if (-not $script:StageRoot.StartsWith($script:TempRoot,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $script:StageRoot)) { throw 'BLOCKED: staging path is not fresh and inside RUNNER_TEMP.' }
  $script:WorkerRoot=Join-Path $script:StageRoot 'worker';$script:CandidateRoot=Join-Path $script:StageRoot 'candidate'
  [void][IO.Directory]::CreateDirectory($script:WorkerRoot);[void][IO.Directory]::CreateDirectory($script:CandidateRoot)
  $script:CandidatePath=Join-Path $script:CandidateRoot $CandidateFileName
  Copy-Item -LiteralPath $CandidateExecutable -Destination $script:CandidatePath -ErrorAction Stop
  if ((Get-FileHash -LiteralPath $script:CandidatePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ExpectedCandidateSHA256) { throw 'BLOCKED: staged candidate hash mismatch.' }

  $script:TestUser='EbrL'+$suffix.Substring(0,8)
  $script:TestPrincipal="$env:COMPUTERNAME\$script:TestUser"
  $script:TaskName='EbrEnv006Lock'+$suffix.Substring(0,8)
  $script:FirewallName='EbrEnv006LockLoopback'+$suffix.Substring(0,8)
  $script:WorkerStatePath=Join-Path $script:WorkerRoot 'worker-state.json'
  $script:WorkerConfigPath=Join-Path $script:WorkerRoot 'worker-config.json'
  $script:WorkerScriptPath=Join-Path $script:WorkerRoot 'lock-worker.ps1'
  $script:RdpFile=Join-Path $script:WorkerRoot 'localhost-lock-test.rdp'
  if (Get-LocalUser -Name $script:TestUser -ErrorAction SilentlyContinue) { throw 'BLOCKED: generated temporary account name already exists.' }
  $random=[byte[]]::new(20)
  [Security.Cryptography.RandomNumberGenerator]::Fill($random)
  $hex=[Convert]::ToHexString($random).ToLowerInvariant()
  [Array]::Clear($random,0,$random.Length)
  $clearPassword='Q!m4'+$hex
  $script:SecurePassword=ConvertTo-SecureString -String $clearPassword -AsPlainText -Force
  $clearPassword=$null;$hex=$null

  $script:FirewallName='EbrEnv006LockLoopback'+$suffix.Substring(0,8)
  Initialize-DisposableRunnerFirewall
  $script:FirewallCreated=$true
  # Windows Firewall rejects loopback addresses in RemoteAddress. Restrict the
  # destination address to 127.0.0.1 and the rule to TermService/TCP 3389.
  New-NetFirewallRule -Name $script:FirewallName -DisplayName $script:FirewallName -Direction Inbound -Action Allow -Protocol TCP -LocalPort 3389 -LocalAddress '127.0.0.1' -RemoteAddress Any -Service TermService -Profile Any -ErrorAction Stop | Out-Null
  $loopbackRules=@(Get-NetFirewallRule -Name $script:FirewallName -ErrorAction Stop)
  if ($loopbackRules.Count -ne 1) { throw 'BLOCKED: the temporary loopback RDP firewall rule is not uniquely identifiable.' }
  $loopbackRule=$loopbackRules[0]
  $loopbackLocalAddresses=@(Get-RuleLocalAddresses $loopbackRule)
  $loopbackRemoteAddresses=@(Get-RuleRemoteAddresses $loopbackRule)
  $loopbackPorts=@(Get-NetFirewallPortFilter -AssociatedNetFirewallRule $loopbackRule -ErrorAction Stop)
  $loopbackServices=@(Get-NetFirewallServiceFilter -AssociatedNetFirewallRule $loopbackRule -ErrorAction Stop)
  $protocols=@($loopbackPorts | ForEach-Object {[string]$_.Protocol})
  $localPorts=@($loopbackPorts | ForEach-Object { @($_.LocalPort | ForEach-Object {[string]$_}) })
  if ($loopbackLocalAddresses.Count -ne 1 -or $loopbackLocalAddresses[0] -cne '127.0.0.1' -or $loopbackRemoteAddresses.Count -ne 1 -or $loopbackRemoteAddresses[0] -cne 'Any' -or $loopbackRule.Direction -ne 'Inbound' -or $loopbackRule.Action -ne 'Allow' -or $loopbackRule.Enabled -ne 'True' -or $protocols.Count -ne 1 -or $protocols[0] -notin @('TCP','6') -or $localPorts.Count -ne 1 -or $localPorts[0] -cne '3389' -or $loopbackServices.Count -ne 1 -or [string]$loopbackServices[0].Service -cne 'TermService') { throw 'BLOCKED: temporary RDP firewall rule did not resolve to enabled inbound TCP/3389 for TermService at local loopback 127.0.0.1 only.' }
  Add-Event 'Verify exact IPv4 loopback-destination-only temporary RDP firewall rule' 'PASS' ([pscustomobject]@{RuleName=$script:FirewallName;Direction=$loopbackRule.Direction;Action=$loopbackRule.Action;Enabled=$loopbackRule.Enabled;Protocols=$protocols;LocalPorts=$localPorts;Service=$loopbackServices[0].Service;LocalAddresses=$loopbackLocalAddresses;RemoteAddresses=$loopbackRemoteAddresses;NoExternalInterfaceDestination=$true})
  if ([int]$script:OldRdpDeny -ne 0) { Set-ItemProperty -LiteralPath $rdpKey -Name fDenyTSConnections -Value 0 -ErrorAction Stop;$script:RdpSettingChanged=$true }
  if ($service.Status -ne 'Running') { Start-Service -Name TermService -ErrorAction Stop;$script:TermServiceStarted=$true }
  $listenWatch=[Diagnostics.Stopwatch]::StartNew();$listening=$false
  while ($listenWatch.Elapsed.TotalSeconds -lt 25) {
    $listening=Test-NetConnection -ComputerName 127.0.0.1 -Port 3389 -InformationLevel Quiet -WarningAction SilentlyContinue
    if ($listening) { break }
    Start-Sleep -Milliseconds 500
  }
  if (-not $listening) { throw 'BLOCKED: localhost RDP listener unavailable through loopback-only firewall.' }

  New-LocalUser -Name $script:TestUser -Password $script:SecurePassword -PasswordNeverExpires -UserMayNotChangePassword -AccountNeverExpires -ErrorAction Stop | Out-Null
  $script:UserCreated=$true
  $localUser=Get-LocalUser -Name $script:TestUser -ErrorAction Stop
  $script:TestSid=$localUser.SID.Value
  if (@(Get-CimInstance Win32_UserProfile -ErrorAction Stop | Where-Object {$_.SID -eq $script:TestSid}).Count) { throw 'BLOCKED: generated account unexpectedly has an existing profile.' }
  $rdpGroup=Get-LocalGroup -SID ([Security.Principal.SecurityIdentifier]'S-1-5-32-555') -ErrorAction Stop
  Add-LocalGroupMember -Group $rdpGroup -Member $script:TestUser -ErrorAction Stop
  if (@(Get-LocalGroupMember -Group 'Administrators' -ErrorAction Stop | Where-Object {$_.SID.Value -eq $script:TestSid}).Count) { throw 'BLOCKED: temporary account unexpectedly has administrator rights.' }
  $script:CredentialWritten=$true
  Add-TemporaryCredential $RdpCredentialTarget $script:TestPrincipal $script:SecurePassword

  @(
    'full address:s:127.0.0.1:3389',
    "username:s:$script:TestPrincipal",
    'prompt for credentials:i:0','promptcredentialonce:i:0','enablecredsspsupport:i:1',
    'authentication level:i:2','screen mode id:i:1','desktopwidth:i:1600','desktopheight:i:900',
    'session bpp:i:32','keyboardhook:i:1','autoreconnection enabled:i:0','use multimon:i:0',
    'redirectclipboard:i:0','redirectprinters:i:0','drivestoredirect:s:','redirectsmartcards:i:0',
    'redirectcomports:i:0','redirectlocation:i:0','redirectposdevices:i:0','redirectwebauthn:i:0',
    'devicestoredirect:s:','usbdevicestoredirect:s:','camerastoredirect:s:',
    'audiocapturemode:i:0','audiomode:i:2'
  ) | Set-Content -LiteralPath $script:RdpFile -Encoding Unicode
  $pwsh=Get-Command pwsh.exe -ErrorAction Stop
  $taskArgs='-NoProfile -Sta -ExecutionPolicy Bypass -File '+[char]34+$script:WorkerScriptPath+[char]34+' -Worker -WorkerConfigPath '+[char]34+$script:WorkerConfigPath+[char]34

  Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
  $virtualScreen=[System.Windows.Forms.SystemInformation]::VirtualScreen
  if ($virtualScreen.Width -le 0 -or $virtualScreen.Height -le 0) { throw 'BLOCKED: controller has no capturable interactive display.' }
  $mstsc=Join-Path $env:WINDIR 'System32\mstsc.exe'
  if (-not (Test-Path -LiteralPath $mstsc -PathType Leaf)) { throw 'BLOCKED: mstsc is unavailable.' }
  $script:OwnedMstscStartedUtc=[DateTime]::UtcNow
  $script:OwnedMstsc=Start-Process -FilePath $mstsc -ArgumentList ([char]34+$script:RdpFile+[char]34) -PassThru -ErrorAction Stop
  $trustPrompt=Resolve-EBRTestRdpFileTrustPrompt -MstscProcessId $script:OwnedMstsc.Id -RdpFilePath $script:RdpFile -EvidenceDirectory $script:EvidencePath -TimeoutSeconds 20
  if($trustPrompt.Status-eq'ACKNOWLEDGED'){Add-Event 'Acknowledge only exact localhost RDP-file prompts; keep all resource redirections disabled' 'PASS' $trustPrompt}
  else{Add-Event 'No first-run RDP-file prompt was present for the generated localhost connection' 'INFO' $trustPrompt}
  $openWatch=[Diagnostics.Stopwatch]::StartNew();$session=$null;$window=$null
  while ($openWatch.Elapsed.TotalSeconds -lt 70 -and (-not $session -or -not $window)) {
    $owned=@(Get-Process -Name mstsc -ErrorAction SilentlyContinue | Where-Object {$_.SessionId -eq $script:ControllerSessionId -and $_.StartTime.ToUniversalTime() -ge $script:OwnedMstscStartedUtc.AddSeconds(-2)})
    $script:MstscProcessIds=@($owned.Id)
    $session=Find-TestSession $script:TestUser -1
    if ($session -and $session.State -ne 'Active') { $session=$null }
    if ($owned.Count) { $window=Find-OwnedMstscWindow $script:MstscProcessIds }
    if (-not $session -or -not $window) { Start-Sleep -Milliseconds 250 }
  }
  if (-not $session -or $session.Station -notmatch '^rdp-tcp#') { throw 'BLOCKED: mstsc did not create a genuine active temporary-user RDP session.' }
  if (-not $window) { throw 'BLOCKED: no unique visible owned mstsc desktop window was identified.' }
  $script:RdpSessionId=[int]$session.SessionId
  if ($script:RdpSessionId -eq $script:ControllerSessionId) { throw 'BLOCKED: RDP session unexpectedly equals controller session.' }
  Add-Event 'Create isolated loopback RDP standard-user session' 'PASS' ([pscustomobject]@{User=$script:TestPrincipal;UserSid=$script:TestSid;SessionId=$script:RdpSessionId;Station=$session.Station;NLA=$true;RemoteAddress='127.0.0.1';MstscProcessIds=$script:MstscProcessIds})
  Remove-TemporaryCredential $RdpCredentialTarget
  Add-Event 'Delete transient first-logon credential before lock test' 'PASS' ([pscustomobject]@{CredentialTarget=$RdpCredentialTarget;NoPasswordInEvidence=$true})

  & (Join-Path $env:WINDIR 'System32\icacls.exe') $script:StageRoot /grant "$($script:TestPrincipal):(RX)" | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'BLOCKED: cannot grant temporary account staging traversal.' }
  & (Join-Path $env:WINDIR 'System32\icacls.exe') $script:WorkerRoot /grant "$($script:TestPrincipal):(OI)(CI)M" /T /C | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'BLOCKED: cannot grant worker state directory access.' }
  Copy-Item -LiteralPath $PSCommandPath -Destination $script:WorkerScriptPath -ErrorAction Stop
  & (Join-Path $env:WINDIR 'System32\icacls.exe') $script:WorkerScriptPath /inheritance:r /grant:r "$($script:TestPrincipal):(RX)" 'BUILTIN\Administrators:(F)' 'NT AUTHORITY\SYSTEM:(F)' | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'BLOCKED: worker script is not read/execute-only for the temporary account.' }
  & (Join-Path $env:WINDIR 'System32\icacls.exe') $script:CandidateRoot /grant "$($script:TestPrincipal):(OI)(CI)RX" /T /C | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'BLOCKED: cannot grant candidate read/execute access.' }
  [ordered]@{RunId=[string]$env:GITHUB_RUN_ID;RunnerEnvironment=$env:RUNNER_ENVIRONMENT;RunnerEnvironmentContext=$env:EBR_RUNNER_ENVIRONMENT_CONTEXT;RunnerOS=$env:RUNNER_OS;RunnerArch=$env:RUNNER_ARCH;User=$script:TestPrincipal;UserSid=$script:TestSid;SessionId=$script:RdpSessionId;CandidatePath=$script:CandidatePath;CandidateArtifactId=$CandidateArtifactId;CandidateSHA256=$ExpectedCandidateSHA256;StatePath=$script:WorkerStatePath} |
    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:WorkerConfigPath -Encoding UTF8
  & (Join-Path $env:WINDIR 'System32\icacls.exe') $script:WorkerConfigPath /inheritance:r /grant:r "$($script:TestPrincipal):(R)" 'BUILTIN\Administrators:(F)' 'NT AUTHORITY\SYSTEM:(F)' | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'BLOCKED: worker configuration is not readable by the scheduled user.' }

  $action=New-ScheduledTaskAction -Execute $pwsh.Source -Argument $taskArgs -WorkingDirectory $script:WorkerRoot
  $principalTask=New-ScheduledTaskPrincipal -UserId $script:TestPrincipal -LogonType Interactive -RunLevel Limited
  $settingsTask=New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -StartWhenAvailable -MultipleInstances IgnoreNew
  Register-ScheduledTask -TaskName $script:TaskName -Action $action -Principal $principalTask -Settings $settingsTask -Force -ErrorAction Stop | Out-Null
  $script:TaskRegistered=$true
  Start-ScheduledTask -TaskName $script:TaskName -ErrorAction Stop

  $startWatch=[Diagnostics.Stopwatch]::StartNew();$workerState=$null
  while ($startWatch.Elapsed.TotalSeconds -lt 70 -and -not $workerState) {
    Start-Sleep -Milliseconds 250
    if (Test-Path -LiteralPath $script:WorkerStatePath) { try {$workerState=Get-Content -LiteralPath $script:WorkerStatePath -Raw | ConvertFrom-Json} catch {} }
  }
  if (-not $workerState -or $workerState.UserSid -cne $script:TestSid -or [int]$workerState.WorkerSessionId -ne $script:RdpSessionId) { throw 'BLOCKED: worker did not prove the correct account and RDP session.' }
  $lockWait=[Diagnostics.Stopwatch]::StartNew()
  while ($lockWait.Elapsed.TotalSeconds -lt 75 -and $workerState.Status -notin @('LOCKED','PASS','FAIL','BLOCKED')) {
    Start-Sleep -Milliseconds 250
    try {$workerState=Get-Content -LiteralPath $script:WorkerStatePath -Raw | ConvertFrom-Json} catch {}
  }
  if (-not $workerState -or $workerState.Status -ne 'LOCKED') {
    if ($workerState -and $workerState.Status -eq 'FAIL') { throw "FAIL: $($workerState.Details.Failure)" }
    throw "BLOCKED: genuine lock proof did not arrive (state='$($workerState.Status)')."
  }
  if ([int]$workerState.Details.SessionId -ne $script:RdpSessionId -or $workerState.Details.InputDesktop -ine 'Winlogon') { throw 'BLOCKED: lock evidence refers to another session or a non-Winlogon desktop.' }
  $window=Find-OwnedMstscWindow $script:MstscProcessIds
  if (-not $window) { throw 'BLOCKED: owned mstsc window is not identifiable while locked.' }
  $window=Focus-AndVerifyMstsc ([int]$window.ProcessId) $window
  $lockScreenshot=Capture-MstscWindow 'env006-rdp-locked-winlogon.png' $window
  Add-Event 'Worker proved WTS lock event and Winlogon input desktop' 'PASS' ([pscustomobject]@{SessionId=$script:RdpSessionId;WorkerState=$workerState;Screenshot=$lockScreenshot})
  Start-Sleep -Seconds 3
  $workerState=Get-Content -LiteralPath $script:WorkerStatePath -Raw | ConvertFrom-Json
  if ($workerState.Status -ne 'LOCKED' -or $workerState.Details.InputDesktop -ine 'Winlogon' -or [int]$workerState.WorkerSessionId -ne $script:RdpSessionId) { throw 'BLOCKED: lock state changed before credentials were sent.' }
  $window=Find-OwnedMstscWindow $script:MstscProcessIds
  if (-not $window) { throw 'BLOCKED: owned mstsc window no longer uniquely identifies the remote desktop.' }
  $window=Focus-AndVerifyMstsc ([int]$window.ProcessId) $window
  $clientPid=[int]$window.ProcessId
  $lockedClientScreenshot=Capture-MstscWindow 'env006-rdp-locked-client-foreground.png' $window
  Send-RdpCtrlAltEnd $clientPid
  Start-Sleep -Milliseconds 700
  if ([EBR_ENV006_NATIVE]::ForegroundProcessId() -ne [uint32]$clientPid -or [EBR_ENV006_NATIVE]::InputDesktopName() -ine 'Default') { throw 'BLOCKED: mstsc lost verified foreground after Ctrl+Alt+End; password not sent.' }
  $workerState=Get-Content -LiteralPath $script:WorkerStatePath -Raw | ConvertFrom-Json
  if ($workerState.Status -ne 'LOCKED' -or $workerState.Details.InputDesktop -ine 'Winlogon') { throw 'BLOCKED: remote desktop left its independently verified lock state.' }
  $window=Find-OwnedMstscWindow $script:MstscProcessIds
  if (-not $window -or [int]$window.ProcessId -ne $clientPid) { throw 'BLOCKED: mstsc client identity changed before password entry.' }
  $window=Focus-AndVerifyMstsc $clientPid $window
  $securityScreenshot=Capture-MstscWindow 'env006-rdp-secure-screen-after-ctrl-alt-end.png' $window
  Add-Event 'Send Ctrl+Alt+End to the verified foreground mstsc client' 'PASS' ([pscustomobject]@{ClientProcessId=$clientPid;ControllerDesktop='Default';RemoteDesktop='Winlogon';KeyboardHookMode=1;Screenshot=$securityScreenshot})

  Send-SecureTemporaryPassword $clientPid $script:SecurePassword
  Add-Event 'Send transient test-user password and Enter to verified foreground mstsc' 'PASS' ([pscustomobject]@{ClientProcessId=$clientPid;RemoteDesktopVerified='Winlogon';PasswordRecorded=$false;Keystrokes=$script:SecurePassword.Length+1})
  $unlockWait=[Diagnostics.Stopwatch]::StartNew();$workerState=$null
  while ($unlockWait.Elapsed.TotalSeconds -lt 160 -and (-not $workerState -or $workerState.Status -notin @('PASS','FAIL','BLOCKED'))) {
    Start-Sleep -Milliseconds 250
    if (Test-Path -LiteralPath $script:WorkerStatePath) { try {$workerState=Get-Content -LiteralPath $script:WorkerStatePath -Raw | ConvertFrom-Json} catch {} }
  }
  if (-not $workerState) { throw 'BLOCKED: worker produced no post-unlock evidence.' }
  if ($workerState.Status -eq 'FAIL') { throw "FAIL: $($workerState.Details.Failure)" }
  if ($workerState.Status -ne 'PASS') { throw "BLOCKED: unlock/default desktop/timer assertions failed: $($workerState.Details.Failure)" }
  if ([int]$workerState.Details.SessionId -ne $script:RdpSessionId -or [int]$workerState.Details.CandidateProcessId -le 0 -or $workerState.Details.CandidateSHA256 -cne $ExpectedCandidateSHA256) { throw 'BLOCKED: worker did not prove same session and exact candidate identity.' }
  $expectedWorkerScreenshot=[IO.Path]::GetFullPath((Join-Path $script:WorkerRoot 'shell-notification-desktop.png'))
  $reportedWorkerScreenshot=[IO.Path]::GetFullPath([string]$workerState.Details.DesktopScreenshot.Path)
  if ($reportedWorkerScreenshot -ine $expectedWorkerScreenshot -or -not (Test-Path -LiteralPath $expectedWorkerScreenshot -PathType Leaf)) { throw 'BLOCKED: actual Shell notification desktop capture was not produced in the owned worker staging directory.' }
  $notificationScreenshot=Join-Path $script:EvidencePath 'env006-rdp-actual-shell-notification-desktop.png'
  Copy-Item -LiteralPath $expectedWorkerScreenshot -Destination $notificationScreenshot -ErrorAction Stop
  Add-Event 'Copy screenshot captured while actual Shell notification and candidate break window were observed' 'PASS' ([pscustomobject]@{Screenshot=$notificationScreenshot;WorkerObservation=$workerState.Details.DesktopScreenshot;ShellNotification=$workerState.Details.ShellNotification;BreakWindow=$workerState.Details.ReminderWindow})
  if (-not (Wait-TestSession $script:TestUser $script:RdpSessionId @('Active') 10)) { throw 'BLOCKED: same RDP session did not remain active after unlock.' }
  $window=Find-OwnedMstscWindow $script:MstscProcessIds
  if (-not $window -or [EBR_ENV006_NATIVE]::ForegroundProcessId() -ne [uint32]$clientPid) { throw 'BLOCKED: same mstsc client is not foreground after unlock.' }
  $unlockedScreenshot=Capture-MstscWindow 'env006-rdp-unlocked-candidate-timer.png' $window
  $script:Events.AddRange([object[]]@($workerState.Events))
  Add-Event 'Same session and candidate resumed after verified unlock' 'PASS' ([pscustomobject]@{WorkerState=$workerState;ClientProcessId=$clientPid;Screenshot=$unlockedScreenshot})
  $script:Status='PASS'
  $script:Reason='The exact production candidate paused on a verified Winlogon lock, the same RDP session was reauthenticated to Default, its timer resumed and advanced, handle/thread samples were captured, and its one-minute timer produced the visible reminder window plus a UIA-correlated natural Windows Shell notification.'
} catch {
  $errorRecord=$_
  $failure=$errorRecord.Exception.Message
  if ($failure -like 'FAIL:*') { $script:Status='FAIL';$script:Reason=$failure }
  else { $script:Status='BLOCKED';$script:Reason=$failure }
  $script:FailureDiagnostics=[ordered]@{
    ExceptionType=$errorRecord.Exception.GetType().FullName
    HResult=('0x{0:X8}' -f $errorRecord.Exception.HResult)
    FullyQualifiedErrorId=$errorRecord.FullyQualifiedErrorId
    CategoryInfo=[string]$errorRecord.CategoryInfo
    Message=$failure
    PositionMessage=[string]$errorRecord.InvocationInfo.PositionMessage
    Line=[string]$errorRecord.InvocationInfo.Line
    ScriptStackTrace=[string]$errorRecord.ScriptStackTrace
    InnerException=if($errorRecord.Exception.InnerException){$errorRecord.Exception.InnerException.ToString()}else{$null}
  }
  Add-Event 'ENV-006 isolated lock/unlock attempt' $script:Status $script:FailureDiagnostics
} finally {
  $script:Password=$null
  if ($script:SecurePassword) { try {$script:SecurePassword.Dispose()} catch {}; $script:SecurePassword=$null }
  if ($script:TaskRegistered) {
    try { Stop-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue;Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction Stop;Add-Event 'Remove temporary scheduled task' 'PASS' }
    catch {$script:CleanupErrors.Add("Task cleanup: $($_.Exception.Message)")}
  }
  if ($script:RdpSessionId -gt 0) {
    try {
      $session=Find-TestSession $script:TestUser $script:RdpSessionId
      if ($session -and $session.UserOnly -ieq $script:TestUser -and $session.Station -match '^rdp-tcp#' -and $script:RdpSessionId -ne $script:ControllerSessionId) {
        & (Join-Path $env:WINDIR 'System32\logoff.exe') $script:RdpSessionId 2>$null
        if ($LASTEXITCODE -ne 0) { throw "logoff.exe returned $LASTEXITCODE for the verified temporary session." }
        $logoffWatch=[Diagnostics.Stopwatch]::StartNew()
        $remaining=Find-TestSession $script:TestUser $script:RdpSessionId
        while ($remaining -and $logoffWatch.Elapsed.TotalSeconds -lt 10) { Start-Sleep -Milliseconds 250; $remaining=Find-TestSession $script:TestUser $script:RdpSessionId }
        if ($remaining) { throw 'Verified temporary RDP session remained after logoff.' }
        Add-Event 'Log off only verified temporary RDP session' 'PASS' ([pscustomobject]@{User=$script:TestUser;SessionId=$script:RdpSessionId})
      } else { $script:CleanupErrors.Add('Logoff refused because the original user/session/rdp-tcp identity no longer matched.') }
    } catch {$script:CleanupErrors.Add("Temporary RDP session logoff: $($_.Exception.Message)")}
  }
  foreach ($processId in @($script:MstscProcessIds)) {
    try {
      $process=Get-Process -Id $processId -ErrorAction SilentlyContinue
      if ($process -and $process.ProcessName -eq 'mstsc' -and $process.SessionId -eq $script:ControllerSessionId -and $script:OwnedMstscStartedUtc -and $process.StartTime.ToUniversalTime() -ge $script:OwnedMstscStartedUtc.AddSeconds(-2)) { Stop-Process -Id $processId -Force -ErrorAction Stop }
    } catch {$script:CleanupErrors.Add("Owned mstsc cleanup PID $($processId): $($_.Exception.Message)")}
  }
  if ($script:CredentialWritten) { try {Remove-TemporaryCredential $RdpCredentialTarget} catch {$script:CleanupErrors.Add("Credential cleanup: $($_.Exception.Message)")} }
  if ($script:UserCreated) {
    try {
      $user=Get-LocalUser -Name $script:TestUser -ErrorAction SilentlyContinue
      if ($user) {
        $profile=Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object {$_.SID -eq $script:TestSid -and -not $_.Special} | Select-Object -First 1
        $wait=[Diagnostics.Stopwatch]::StartNew()
        while ($profile -and $profile.Loaded -and $wait.Elapsed.TotalSeconds -lt 15) {Start-Sleep -Milliseconds 500;$profile=Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object {$_.SID -eq $script:TestSid -and -not $_.Special} | Select-Object -First 1}
        if ($profile -and $profile.Loaded) {$script:CleanupErrors.Add('Temporary profile remained loaded; deletion refused.')}
        else {
          if ($profile) {
            $path=[IO.Path]::GetFullPath($profile.LocalPath)
            $usersRoot=[IO.Path]::GetFullPath((Join-Path $env:SystemDrive 'Users')).TrimEnd('\')+'\'
            if (-not $path.StartsWith($usersRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($path) -ine $script:TestUser) {throw 'Unexpected temporary profile path; deletion refused.'}
            Remove-CimInstance -InputObject $profile -ErrorAction Stop
          }
          Remove-LocalUser -Name $script:TestUser -ErrorAction Stop
          Add-Event 'Remove temporary RDP user and profile' 'PASS'
        }
      }
    } catch {$script:CleanupErrors.Add("Temporary user/profile cleanup: $($_.Exception.Message)")}
  }
  if ($script:FirewallSnapshotComplete -or $script:FirewallCreated) {
    try { Restore-DisposableRunnerFirewall }
    catch {$script:CleanupErrors.Add("Firewall cleanup/restore verification: $($_.Exception.Message)")}
  }
  if ($script:RdpSettingChanged -and $null -ne $script:OldRdpDeny) {
    try {Set-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value ([int]$script:OldRdpDeny) -ErrorAction Stop}
    catch {$script:CleanupErrors.Add("Restore RDP registry setting: $($_.Exception.Message)")}
  }
  if ($script:TermServiceStarted -and $script:OldTermServiceState -eq 'Stopped') {try {Stop-Service -Name TermService -Force -ErrorAction Stop} catch {$script:CleanupErrors.Add("Restore TermService state: $($_.Exception.Message)")}}
  if ($script:StageRoot -and (Test-Path -LiteralPath $script:StageRoot)) {
    try {
      $stage=[IO.Path]::GetFullPath($script:StageRoot)
      if (-not $stage.StartsWith($script:TempRoot,[StringComparison]::OrdinalIgnoreCase) -or ([IO.File]::GetAttributes($stage) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {throw 'Refusing to remove staging path outside RUNNER_TEMP or through reparse point.'}
      Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction Stop
    } catch {$script:CleanupErrors.Add("Staging cleanup: $($_.Exception.Message)")}
  }
  if ($script:CleanupErrors.Count -gt 0 -and $script:Status -eq 'PASS') {$script:Status='BLOCKED';$script:Reason='Assertions passed but disposable runner cleanup was incomplete.';Add-Event 'Require successful cleanup for PASS' 'BLOCKED' @($script:CleanupErrors)}
  if ($script:EvidencePath -and (Test-Path -LiteralPath $script:EvidencePath)) {try {Save-FinalEvidence $script:Status $script:Reason} catch {Write-Error "Unable to write ENV-006 evidence: $($_.Exception.Message)"}}
}

if ($script:Status -eq 'FAIL') {throw $script:Reason}
if ($script:Status -ne 'PASS') {Write-Error "ENV-006 lock/unlock: $($script:Status) — $($script:Reason)";exit 1}
Write-Host 'ENV-006 isolated Windows Server RDP lock/unlock assertions passed.'
