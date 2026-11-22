param(
  [Parameter(Mandatory)][string]$ExecutablePath,
  [Parameter(Mandatory)][string]$EvidenceDirectory,
  [Parameter()][int]$ExpectedSessionId=-1,
  [Parameter()][string]$ExpectedSessionName,
  [Parameter()][string]$ExpectedUser,
  [Parameter()][switch]$ServerConsoleSession,
  [Parameter()][switch]$AllowExactPrivacyOobeNext
)
$ErrorActionPreference='Stop'
$expectedSha256='07f6c1eaee5818df9f5c024310883ca94b8274a4f451186a8123974fb5e5f720'
$expectedArtifactId='14695418078'
$expectedRunId='44875679345'
$events=[System.Collections.Generic.List[object]]::new()
$captures=[System.Collections.Generic.List[object]]::new()
$audioHandleMilestones=[System.Collections.Generic.List[object]]::new()
$ownedProcess=$null
$appPid=0
$mainWindow=[IntPtr]::Zero
$appDataPath=$null
$appDataExistedBefore=$false
$endpoint=$null
$baseline=$null
$wasapiAvailable=$false
$controlFailure=$false
$acousticFailure=$false
$acousticCoverageMissing=$false
$naturalAlarmRecord=[pscustomobject]@{Status='NOT TESTED';TimerTransitionStatus='NOT TESTED';AcousticStatus='NOT TESTED';Reason='The natural Work-to-Break alarm trial has not run.'}
$overallStatus='BLOCKED'
$overallReason='The runner-only audio acceptance preconditions were not met.'
$runnerFlavor=$null
$candidateExecution=$null
$environmentDescription=$null
$sessionName=$null
$server2025ConsoleContext=$false
$consoleDesktopRecord=$null
$naturalAlarmForegroundFailureEvidence=$null
$nativeTypeLoaded=$false

function Add-AudioEvent([string]$Name,[string]$Status,$Details=$null){$script:events.Add([pscustomobject]@{Name=$Name;Status=$Status;Details=$Details;Utc=[DateTime]::UtcNow.ToString('o')})}
function Get-CandidateHandleCount {
  if(-not$script:ownedProcess){return $null}
  try{$script:ownedProcess.Refresh();if($script:ownedProcess.HasExited){return $null};return [int]$script:ownedProcess.HandleCount}catch{return $null}
}
function Test-AudioRequire([bool]$Condition,[string]$Name,$Details=$null){
  if($Condition){Add-AudioEvent $Name 'PASS' $Details;return $true}
  Add-AudioEvent $Name 'FAIL' $Details;$script:controlFailure=$true;return $false
}
function Test-AudioAcousticRequire([bool]$Condition,[string]$Name,$Details=$null){
  if($Condition){Add-AudioEvent $Name 'PASS' $Details;return $true}
  Add-AudioEvent $Name 'FAIL' $Details;$script:acousticFailure=$true;return $false
}

$nativeSource=@'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

public static class EBR_AUDIO_NATIVE {
  public delegate bool EnumWindowCallback(IntPtr hwnd,IntPtr data);
  public sealed class WtsSession { public int SessionId; public string Station; public int State; }
  [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] private struct WTS_SESSION_INFO { public int SessionId; [MarshalAs(UnmanagedType.LPWStr)] public string Station; public int State; }
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left,Top,Right,Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X,Y; }
  [StructLayout(LayoutKind.Sequential)] public struct GUITHREADINFO { public uint cbSize,flags; public IntPtr hwndActive,hwndFocus,hwndCapture,hwndMenuOwner,hwndMoveSize,hwndCaret; public RECT rcCaret; }
  public sealed class FocusSnapshot { public uint ThreadId; public uint OwnerProcessId; public IntPtr FocusedWindow; public uint FocusedThreadId; public uint FocusedProcessId; public uint Flags; }
  [DllImport("kernel32.dll",SetLastError=true)] public static extern uint WTSGetActiveConsoleSessionId();
  [DllImport("wtsapi32.dll",EntryPoint="WTSEnumerateSessionsW",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool WTSEnumerateSessions(IntPtr server,int reserved,int version,out IntPtr sessions,out int count);
  [DllImport("wtsapi32.dll")] static extern void WTSFreeMemory(IntPtr memory);
  [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
  [DllImport("user32.dll",SetLastError=true)] static extern IntPtr GetProcessWindowStation();
  [DllImport("user32.dll",SetLastError=true)] static extern IntPtr GetThreadDesktop(uint threadId);
  [DllImport("user32.dll",EntryPoint="OpenInputDesktop",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr OpenInputDesktop(uint flags,bool inherit,uint desiredAccess);
  [DllImport("user32.dll",SetLastError=true)] static extern bool CloseDesktop(IntPtr desktop);
  [DllImport("user32.dll",EntryPoint="GetUserObjectInformationW",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool GetUserObjectInformation(IntPtr handle,int index,StringBuilder buffer,uint length,out uint needed);
  [DllImport("user32.dll",SetLastError=true)] static extern bool EnumWindows(EnumWindowCallback callback,IntPtr data);
  [DllImport("user32.dll",SetLastError=true)] static extern bool EnumChildWindows(IntPtr parent,EnumWindowCallback callback,IntPtr data);
  [DllImport("user32.dll",SetLastError=true)] static extern uint GetWindowThreadProcessId(IntPtr hwnd,out uint processId);
  [DllImport("user32.dll",SetLastError=true)] static extern bool GetGUIThreadInfo(uint threadId,ref GUITHREADINFO info);
  [DllImport("user32.dll",CharSet=CharSet.Unicode,EntryPoint="GetWindowTextW",SetLastError=true)] static extern int GetWindowTextNative(IntPtr hwnd,StringBuilder text,int maxCount);
  [DllImport("user32.dll",CharSet=CharSet.Unicode,EntryPoint="GetClassNameW",SetLastError=true)] static extern int GetClassNameNative(IntPtr hwnd,StringBuilder name,int maxCount);
  [DllImport("user32.dll",SetLastError=true)] static extern int GetDlgCtrlID(IntPtr hwnd);
  [DllImport("user32.dll",SetLastError=true)] static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll",SetLastError=true)] static extern bool IsWindowEnabled(IntPtr hwnd);
  [DllImport("user32.dll",SetLastError=true)] static extern IntPtr GetParent(IntPtr hwnd);
  [DllImport("user32.dll",SetLastError=true)] static extern bool GetWindowRect(IntPtr hwnd,out RECT rect);
  [DllImport("user32.dll",SetLastError=true)] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll",SetLastError=true)] static extern IntPtr GetLastActivePopup(IntPtr hwnd);
  [DllImport("user32.dll",SetLastError=true)] static extern bool SetForegroundWindow(IntPtr hwnd);
  [DllImport("user32.dll",SetLastError=true)] static extern bool ShowWindow(IntPtr hwnd,int command);
  [DllImport("user32.dll",SetLastError=true)] static extern IntPtr WindowFromPoint(POINT point);
  [DllImport("user32.dll",SetLastError=true)] static extern bool SetCursorPos(int x,int y);
  [DllImport("user32.dll",SetLastError=true)] static extern void mouse_event(uint flags,uint dx,uint dy,uint data,UIntPtr extraInfo);
  [DllImport("user32.dll",SetLastError=true)] static extern IntPtr GetAncestor(IntPtr hwnd,uint flags);
  [DllImport("user32.dll",EntryPoint="SendMessageTimeoutW",SetLastError=true)] static extern IntPtr SendMessageTimeoutNative(IntPtr hwnd,uint msg,IntPtr wParam,IntPtr lParam,uint flags,uint timeout,out IntPtr result);
  [DllImport("user32.dll",EntryPoint="SendMessageW",SetLastError=true)] static extern IntPtr SendMessageNative(IntPtr hwnd,uint msg,IntPtr wParam,IntPtr lParam);
  [DllImport("user32.dll",EntryPoint="PostMessageW",SetLastError=true)] static extern bool PostMessageNative(IntPtr hwnd,uint msg,IntPtr wParam,IntPtr lParam);
  [DllImport("user32.dll",CharSet=CharSet.Unicode,EntryPoint="FindWindowW",SetLastError=true)] static extern IntPtr FindWindowNative(string className,string title);
  private static string UserObjectName(IntPtr handle){if(handle==IntPtr.Zero)return "<ERROR:0>";var b=new StringBuilder(256);uint needed;if(!GetUserObjectInformation(handle,2,b,(uint)(b.Capacity*2),out needed))return "<ERROR:"+Marshal.GetLastWin32Error().ToString()+">";return b.ToString();}
  public static WtsSession[] EnumerateWtsSessions(){IntPtr buffer=IntPtr.Zero;int count=0;if(!WTSEnumerateSessions(IntPtr.Zero,0,1,out buffer,out count))throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(),"WTSEnumerateSessionsW failed");try{int size=Marshal.SizeOf(typeof(WTS_SESSION_INFO));var rows=new List<WtsSession>(count);for(int i=0;i<count;i++){IntPtr current=IntPtr.Add(buffer,i*size);var row=(WTS_SESSION_INFO)Marshal.PtrToStructure(current,typeof(WTS_SESSION_INFO));rows.Add(new WtsSession{SessionId=row.SessionId,Station=row.Station,State=row.State});}return rows.ToArray();}finally{if(buffer!=IntPtr.Zero)WTSFreeMemory(buffer);}}
  public static string ProcessWindowStationName(){return UserObjectName(GetProcessWindowStation());}
  public static string ThreadDesktopName(){return UserObjectName(GetThreadDesktop(GetCurrentThreadId()));}
  public static string InputDesktopName(){IntPtr desktop=OpenInputDesktop(0,false,1);if(desktop==IntPtr.Zero)return "<ERROR:"+Marshal.GetLastWin32Error().ToString()+">";try{return UserObjectName(desktop);}finally{CloseDesktop(desktop);}}
  public static IntPtr TaskbarWindow(){return FindWindowNative("Shell_TrayWnd",null);}
  public static int TaskbarProcessId(IntPtr hwnd){if(hwnd==IntPtr.Zero)return 0;uint pid;GetWindowThreadProcessId(hwnd,out pid);return (int)pid;}
  public static string Text(IntPtr hwnd){var b=new StringBuilder(1024);GetWindowTextNative(hwnd,b,b.Capacity);return b.ToString();}
  public static string ClassName(IntPtr hwnd){var b=new StringBuilder(256);GetClassNameNative(hwnd,b,b.Capacity);return b.ToString();}
  public static int ControlId(IntPtr hwnd){return GetDlgCtrlID(hwnd);}
  public static bool Visible(IntPtr hwnd){return IsWindowVisible(hwnd);}
  public static bool Enabled(IntPtr hwnd){return IsWindowEnabled(hwnd);}
  public static IntPtr Parent(IntPtr hwnd){return GetParent(hwnd);}
  public static bool WindowRect(IntPtr hwnd,out RECT rect){return GetWindowRect(hwnd,out rect);}
  public static IntPtr WindowAtPoint(int x,int y){return WindowFromPoint(new POINT{X=x,Y=y});}
  public static bool ClickLeftAtExactWindow(IntPtr expectedWindow,int x,int y){if(expectedWindow==IntPtr.Zero||!SetCursorPos(x,y))return false;var p=new POINT{X=x,Y=y};if(WindowFromPoint(p)!=expectedWindow)return false;mouse_event(0x0002,0,0,0,UIntPtr.Zero);try{Thread.Sleep(60);}finally{mouse_event(0x0004,0,0,0,UIntPtr.Zero);}return true;}
  public static FocusSnapshot FocusForWindow(IntPtr hwnd){uint ownerPid;uint threadId=GetWindowThreadProcessId(hwnd,out ownerPid);if(hwnd==IntPtr.Zero||threadId==0)throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(),"Could not identify the target window thread.");var info=new GUITHREADINFO{cbSize=(uint)Marshal.SizeOf(typeof(GUITHREADINFO))};if(!GetGUIThreadInfo(threadId,ref info))throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(),"GetGUIThreadInfo failed for the target window thread.");uint focusedPid=0;uint focusedThread=0;if(info.hwndFocus!=IntPtr.Zero)focusedThread=GetWindowThreadProcessId(info.hwndFocus,out focusedPid);return new FocusSnapshot{ThreadId=threadId,OwnerProcessId=ownerPid,FocusedWindow=info.hwndFocus,FocusedThreadId=focusedThread,FocusedProcessId=focusedPid,Flags=info.flags};}
  public static IntPtr ForegroundWindow(){return GetForegroundWindow();}
  public static IntPtr LastActivePopup(IntPtr hwnd){return hwnd==IntPtr.Zero?IntPtr.Zero:GetLastActivePopup(hwnd);}
  public static bool TryActivate(IntPtr hwnd){ShowWindow(hwnd,9);SetForegroundWindow(hwnd);return GetForegroundWindow()==hwnd;}
  public static IntPtr RootWindowAtCenter(IntPtr hwnd){RECT r;if(!GetWindowRect(hwnd,out r))return IntPtr.Zero;var p=new POINT{X=(r.Left+r.Right)/2,Y=(r.Top+r.Bottom)/2};var hit=WindowFromPoint(p);return hit==IntPtr.Zero?IntPtr.Zero:GetAncestor(hit,2);}
  public static IntPtr Send(IntPtr hwnd,uint msg,IntPtr w,IntPtr l){return SendMessageNative(hwnd,msg,w,l);}
  public static bool Post(IntPtr hwnd,uint msg,IntPtr w,IntPtr l){return PostMessageNative(hwnd,msg,w,l);}
  public static bool SendBounded(IntPtr hwnd,uint msg,IntPtr w,IntPtr l,uint timeout,out IntPtr result){return SendMessageTimeoutNative(hwnd,msg,w,l,2,timeout,out result)!=IntPtr.Zero;}
  public static IntPtr[] ChildWindows(IntPtr parent){var all=new List<IntPtr>();EnumChildWindows(parent,(h,d)=>{all.Add(h);return true;},IntPtr.Zero);return all.ToArray();}
  public static IntPtr[] AllTopWindows(){var all=new List<IntPtr>();EnumWindows((h,d)=>{if(IsWindowVisible(h))all.Add(h);return true;},IntPtr.Zero);return all.ToArray();}
  public static IntPtr[] TopWindowsForProcess(int pid){var all=new List<IntPtr>();EnumWindows((h,d)=>{uint owner;GetWindowThreadProcessId(h,out owner);if(owner==(uint)pid&&IsWindowVisible(h))all.Add(h);return true;},IntPtr.Zero);return all.ToArray();}
  public static int OwnerPid(IntPtr hwnd){uint owner;GetWindowThreadProcessId(hwnd,out owner);return (int)owner;}
  public static Task<IntPtr> ClickButtonAsync(IntPtr hwnd){return Task.Factory.StartNew(()=>SendMessageNative(hwnd,0x00F5,IntPtr.Zero,IntPtr.Zero),CancellationToken.None,TaskCreationOptions.LongRunning,TaskScheduler.Default);}
}

public enum EBR_AUDIO_DATA_FLOW { Render=0, Capture=1, All=2 }
public enum EBR_AUDIO_ROLE { Console=0, Multimedia=1, Communications=2 }
[ComImport,Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface EBR_IMMDeviceEnumerator {
  [PreserveSig] int EnumAudioEndpoints(EBR_AUDIO_DATA_FLOW flow,uint stateMask,[MarshalAs(UnmanagedType.Interface)]out EBR_IMMDeviceCollection devices);
  [PreserveSig] int GetDefaultAudioEndpoint(EBR_AUDIO_DATA_FLOW flow,EBR_AUDIO_ROLE role,[MarshalAs(UnmanagedType.Interface)]out EBR_IMMDevice endpoint);
  [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)]string id,[MarshalAs(UnmanagedType.Interface)]out EBR_IMMDevice endpoint);
  [PreserveSig] int RegisterEndpointNotificationCallback(IntPtr callback);
  [PreserveSig] int UnregisterEndpointNotificationCallback(IntPtr callback);
}
[ComImport,Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface EBR_IMMDeviceCollection {
  [PreserveSig] int GetCount(out uint count);
  [PreserveSig] int Item(uint index,[MarshalAs(UnmanagedType.Interface)]out EBR_IMMDevice device);
}
[ComImport,Guid("D666063F-1587-4E43-81F1-B948E807363F"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface EBR_IMMDevice {
  [PreserveSig] int Activate(ref Guid iid,uint clsctx,IntPtr activationParams,[MarshalAs(UnmanagedType.IUnknown)]out object result);
  [PreserveSig] int OpenPropertyStore(uint mode,IntPtr properties);
  [PreserveSig] int GetId(out IntPtr id);
  [PreserveSig] int GetState(out uint state);
}
[ComImport,Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface EBR_IAudioClient {
  [PreserveSig] int Initialize(int shareMode,uint streamFlags,long bufferDuration,long periodicity,IntPtr format,IntPtr sessionGuid);
  [PreserveSig] int GetBufferSize(out uint frames);
  [PreserveSig] int GetStreamLatency(out long latency);
  [PreserveSig] int GetCurrentPadding(out uint padding);
  [PreserveSig] int IsFormatSupported(int shareMode,IntPtr format,IntPtr closestMatch);
  [PreserveSig] int GetMixFormat(out IntPtr format);
  [PreserveSig] int GetDevicePeriod(out long defaultPeriod,out long minimumPeriod);
  [PreserveSig] int Start();
  [PreserveSig] int Stop();
  [PreserveSig] int Reset();
  [PreserveSig] int SetEventHandle(IntPtr eventHandle);
  [PreserveSig] int GetService(ref Guid iid,[MarshalAs(UnmanagedType.IUnknown)]out object service);
}
[ComImport,Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface EBR_IAudioCaptureClient {
  [PreserveSig] int GetBuffer(out IntPtr data,out uint frames,out uint flags,out ulong devicePosition,out ulong qpcPosition);
  [PreserveSig] int ReleaseBuffer(uint frames);
  [PreserveSig] int GetNextPacketSize(out uint frames);
}
[ComImport,Guid("5CDF2C82-841E-4546-9722-0CF74078229A"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface EBR_IAudioEndpointVolume {
  [PreserveSig] int RegisterControlChangeNotify(IntPtr callback);
  [PreserveSig] int UnregisterControlChangeNotify(IntPtr callback);
  [PreserveSig] int GetChannelCount(out uint count);
  [PreserveSig] int SetMasterVolumeLevel(float level,ref Guid context);
  [PreserveSig] int SetMasterVolumeLevelScalar(float level,ref Guid context);
  [PreserveSig] int GetMasterVolumeLevel(out float level);
  [PreserveSig] int GetMasterVolumeLevelScalar(out float level);
  [PreserveSig] int SetChannelVolumeLevel(uint channel,float level,ref Guid context);
  [PreserveSig] int SetChannelVolumeLevelScalar(uint channel,float level,ref Guid context);
  [PreserveSig] int GetChannelVolumeLevel(uint channel,out float level);
  [PreserveSig] int GetChannelVolumeLevelScalar(uint channel,out float level);
  [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)]bool mute,ref Guid context);
  [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)]out bool mute);
  [PreserveSig] int GetVolumeStepInfo(out uint step,out uint stepCount);
  [PreserveSig] int VolumeStepUp(ref Guid context);
  [PreserveSig] int VolumeStepDown(ref Guid context);
  [PreserveSig] int QueryHardwareSupport(out uint supportMask);
  [PreserveSig] int GetVolumeRange(out float min,out float max,out float increment);
}

[ComImport,Guid("BFA971F1-4D5E-40BB-935E-967039BFBEE4"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface EBR_IAudioSessionManager {
  [PreserveSig] int GetAudioSessionControl(ref Guid sessionGuid,uint flags,out EBR_IAudioSessionControl session);
  [PreserveSig] int GetSimpleAudioVolume(ref Guid sessionGuid,uint flags,[MarshalAs(UnmanagedType.IUnknown)]out object volume);
}
[ComImport,Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface EBR_IAudioSessionManager2 : EBR_IAudioSessionManager {
  [PreserveSig] int GetSessionEnumerator(out EBR_IAudioSessionEnumerator sessions);
  [PreserveSig] int RegisterSessionNotification(IntPtr notification);
  [PreserveSig] int UnregisterSessionNotification(IntPtr notification);
  [PreserveSig] int RegisterDuckNotification([MarshalAs(UnmanagedType.LPWStr)]string sessionId,IntPtr notification);
  [PreserveSig] int UnregisterDuckNotification(IntPtr notification);
}
[ComImport,Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface EBR_IAudioSessionEnumerator {
  [PreserveSig] int GetCount(out int count);
  [PreserveSig] int GetSession(int index,out EBR_IAudioSessionControl session);
}
[ComImport,Guid("F4B1A599-7266-4319-A8CA-E70ACB11E8CD"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface EBR_IAudioSessionControl {
  [PreserveSig] int GetState(out int state);
  [PreserveSig] int GetDisplayName(out IntPtr name);
  [PreserveSig] int SetDisplayName([MarshalAs(UnmanagedType.LPWStr)]string name,ref Guid context);
  [PreserveSig] int GetIconPath(out IntPtr path);
  [PreserveSig] int SetIconPath([MarshalAs(UnmanagedType.LPWStr)]string path,ref Guid context);
  [PreserveSig] int GetGroupingParam(out Guid group);
  [PreserveSig] int SetGroupingParam(ref Guid group,ref Guid context);
  [PreserveSig] int RegisterAudioSessionNotification(IntPtr notification);
  [PreserveSig] int UnregisterAudioSessionNotification(IntPtr notification);
}
[ComImport,Guid("BFB7FF88-7239-4FC9-8FA2-07C950BE9C6D"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface EBR_IAudioSessionControl2 : EBR_IAudioSessionControl {
  [PreserveSig] int GetSessionIdentifier(out IntPtr id);
  [PreserveSig] int GetSessionInstanceIdentifier(out IntPtr id);
  [PreserveSig] int GetProcessId(out uint processId);
  [PreserveSig] int IsSystemSoundsSession();
  [PreserveSig] int SetDuckingPreference([MarshalAs(UnmanagedType.Bool)]bool optOut);
}
[ComImport,Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface EBR_IAudioMeterInformation {
  [PreserveSig] int GetPeakValue(out float peak);
  [PreserveSig] int GetMeteringChannelCount(out int count);
  [PreserveSig] int GetChannelsPeakValues(int count,[Out,MarshalAs(UnmanagedType.LPArray,SizeParamIndex=0)]float[] peaks);
  [PreserveSig] int QueryHardwareSupport(out uint mask);
}

public sealed class EBR_AUDIO_ENDPOINT_REPORT {
  public int ActiveRenderEndpointCount;
  public string DefaultEndpointId;
  public float DefaultMasterVolume;
  public bool DefaultMuted;
  public string Error;
}
public sealed class EBR_AUDIO_CAPTURE_RESULT {
  public string EndpointId;
  public string StartedUtc;
  public string CompletedUtc;
  public string Error;
  public int SampleRate;
  public int Channels;
  public int SourceBitsPerSample;
  public int Frames;
  public int Packets;
  public int SilentPackets;
  public int NonZeroSamples;
  public double Rms;
  public double Peak;
  public short[] Pcm16Mono;
}
public sealed class EBR_AUDIO_SESSION_METER_RESULT {
  public int ProcessId;
  public string EndpointId;
  public int Polls;
  public int SessionObservedSamples;
  public int ActiveSamples;
  public int MeterSamples;
  public int NonZeroSamples;
  public double Peak;
  public string StartedUtc;
  public string CompletedUtc;
  public string Error;
}
public static class EBR_WASAPI {
  const uint DEVICE_STATE_ACTIVE=1,CLSCTX_ALL=23,LOOPBACK=0x00020000,SILENT=2;
  static readonly Guid EnumeratorClass=new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E");
  static readonly Guid AudioClientIid=new Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2");
  static readonly Guid CaptureClientIid=new Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317");
  static readonly Guid EndpointVolumeIid=new Guid("5CDF2C82-841E-4546-9722-0CF74078229A");
  static readonly Guid FloatSubFormat=new Guid("00000003-0000-0010-8000-00AA00389B71");
  static readonly Guid PcmSubFormat=new Guid("00000001-0000-0010-8000-00AA00389B71");
  static EBR_IMMDeviceEnumerator CreateEnumerator(){return (EBR_IMMDeviceEnumerator)Activator.CreateInstance(Type.GetTypeFromCLSID(EnumeratorClass,true));}
  static void Check(int hr,string operation){if(hr<0)Marshal.ThrowExceptionForHR(hr,new IntPtr(-1));}
  static string DeviceId(EBR_IMMDevice device){IntPtr p=IntPtr.Zero;Check(device.GetId(out p),"IMMDevice.GetId");try{return Marshal.PtrToStringUni(p);}finally{if(p!=IntPtr.Zero)Marshal.FreeCoTaskMem(p);}}
  static EBR_IMMDevice GetDefault(EBR_IMMDeviceEnumerator en){EBR_IMMDevice d;Check(en.GetDefaultAudioEndpoint(EBR_AUDIO_DATA_FLOW.Render,EBR_AUDIO_ROLE.Multimedia,out d),"GetDefaultAudioEndpoint(Render, Multimedia)");return d;}
  public static EBR_AUDIO_ENDPOINT_REPORT Probe(){
    var r=new EBR_AUDIO_ENDPOINT_REPORT();EBR_IMMDeviceEnumerator en=null;EBR_IMMDeviceCollection all=null;EBR_IMMDevice d=null;object volumeObject=null;
    try{
      en=CreateEnumerator();Check(en.EnumAudioEndpoints(EBR_AUDIO_DATA_FLOW.Render,DEVICE_STATE_ACTIVE,out all),"EnumAudioEndpoints(Render, Active)");uint count;Check(all.GetCount(out count),"IMMDeviceCollection.GetCount");r.ActiveRenderEndpointCount=checked((int)count);
      d=GetDefault(en);r.DefaultEndpointId=DeviceId(d);Guid iid=EndpointVolumeIid;Check(d.Activate(ref iid,CLSCTX_ALL,IntPtr.Zero,out volumeObject),"IMMDevice.Activate(IAudioEndpointVolume)");var volume=(EBR_IAudioEndpointVolume)volumeObject;Check(volume.GetMasterVolumeLevelScalar(out r.DefaultMasterVolume),"GetMasterVolumeLevelScalar");Check(volume.GetMute(out r.DefaultMuted),"GetMute");
    }catch(Exception e){r.Error=e.GetType().FullName+": "+e.Message;}finally{if(volumeObject!=null&&Marshal.IsComObject(volumeObject))Marshal.ReleaseComObject(volumeObject);if(d!=null&&Marshal.IsComObject(d))Marshal.ReleaseComObject(d);if(all!=null&&Marshal.IsComObject(all))Marshal.ReleaseComObject(all);if(en!=null&&Marshal.IsComObject(en))Marshal.ReleaseComObject(en);}
    return r;
  }
  public sealed class Recorder {
    readonly ManualResetEventSlim ready=new ManualResetEventSlim(false),done=new ManualResetEventSlim(false);
    Thread worker;int durationMs;string startError;EBR_AUDIO_CAPTURE_RESULT result;
    public string Begin(int milliseconds){durationMs=milliseconds;worker=new Thread(Record);worker.IsBackground=true;worker.Name="EBR WASAPI loopback recorder";worker.SetApartmentState(ApartmentState.MTA);worker.Start();if(!ready.Wait(5000))return "Loopback worker did not initialize within five seconds.";return startError;}
    public bool IsCompleted { get {return done.IsSet;} }
    public EBR_AUDIO_CAPTURE_RESULT Finish(int timeoutMs){if(worker==null)return null;if(!done.Wait(timeoutMs))throw new TimeoutException("WASAPI loopback capture did not complete within the requested timeout.");return result;}
    void Record(){
      EBR_IMMDeviceEnumerator en=null;EBR_IMMDevice device=null;object clientObject=null,captureObject=null;IntPtr mix=IntPtr.Zero;EBR_IAudioClient client=null;EBR_IAudioCaptureClient capture=null;bool started=false;
      result=new EBR_AUDIO_CAPTURE_RESULT{StartedUtc=DateTime.UtcNow.ToString("o"),Pcm16Mono=new short[0]};
      try{
        en=CreateEnumerator();device=GetDefault(en);result.EndpointId=DeviceId(device);Guid iid=AudioClientIid;Check(device.Activate(ref iid,CLSCTX_ALL,IntPtr.Zero,out clientObject),"IMMDevice.Activate(IAudioClient)");client=(EBR_IAudioClient)clientObject;
        Check(client.GetMixFormat(out mix),"IAudioClient.GetMixFormat");int tag=unchecked((ushort)Marshal.ReadInt16(mix,0)),channels=unchecked((ushort)Marshal.ReadInt16(mix,2)),rate=Marshal.ReadInt32(mix,4),block=unchecked((ushort)Marshal.ReadInt16(mix,12)),bits=unchecked((ushort)Marshal.ReadInt16(mix,14));int cb=unchecked((ushort)Marshal.ReadInt16(mix,16));
        bool isFloat=tag==3,isPcm=tag==1;
        if(tag==0xfffe&&cb>=22){Guid sub=Marshal.PtrToStructure<Guid>(IntPtr.Add(mix,24));isFloat=sub==FloatSubFormat;isPcm=sub==PcmSubFormat;}
        if((!isFloat&&!isPcm)||channels<1||rate<8000||block<channels*((bits+7)/8)||!((isFloat&&bits==32)||(isPcm&&(bits==8||bits==16||bits==24||bits==32))))throw new NotSupportedException("Unsupported shared render mix format (tag="+tag+", channels="+channels+", rate="+rate+", bits="+bits+").");
        result.SampleRate=rate;result.Channels=channels;result.SourceBitsPerSample=bits;
        Check(client.Initialize(0,LOOPBACK,10000000,0,mix,IntPtr.Zero),"IAudioClient.Initialize(shared loopback)");iid=CaptureClientIid;Check(client.GetService(ref iid,out captureObject),"IAudioClient.GetService(IAudioCaptureClient)");capture=(EBR_IAudioCaptureClient)captureObject;Check(client.Start(),"IAudioClient.Start");started=true;ready.Set();
        var samples=new List<short>(Math.Max(1,rate*durationMs/1000));long framesTotal=0,nonZero=0;double sumSquares=0,peak=0;int packets=0,silentPackets=0;var timer=Stopwatch.StartNew();int bytesPerSample=(bits+7)/8;
        while(timer.ElapsedMilliseconds<durationMs){uint next;Check(capture.GetNextPacketSize(out next),"IAudioCaptureClient.GetNextPacketSize");if(next==0){Thread.Sleep(4);continue;}IntPtr data;uint frameCount,flags;ulong devicePosition,qpcPosition;Check(capture.GetBuffer(out data,out frameCount,out flags,out devicePosition,out qpcPosition),"IAudioCaptureClient.GetBuffer");
          try{
            packets++;bool silence=(flags&SILENT)!=0;if(silence)silentPackets++;byte[] buffer=null;int length=checked((int)(frameCount*(uint)block));if(!silence){buffer=new byte[length];Marshal.Copy(data,buffer,0,length);}
            for(int frame=0;frame<frameCount;frame++){double mixed=0;for(int channel=0;channel<channels;channel++){double value=0;if(!silence){int offset=frame*block+channel*bytesPerSample;if(isFloat)value=BitConverter.ToSingle(buffer,offset);else if(bits==8)value=(buffer[offset]-128)/128.0;else if(bits==16)value=BitConverter.ToInt16(buffer,offset)/32768.0;else if(bits==24){int v=buffer[offset]|(buffer[offset+1]<<8)|(buffer[offset+2]<<16);if((v&0x800000)!=0)v|=unchecked((int)0xff000000);value=v/8388608.0;}else value=BitConverter.ToInt32(buffer,offset)/2147483648.0;}mixed+=value;}
              mixed/=channels;if(double.IsNaN(mixed)||double.IsInfinity(mixed))mixed=0;mixed=Math.Max(-1,Math.Min(1,mixed));double abs=Math.Abs(mixed);if(abs>peak)peak=abs;if(abs>0.000001)nonZero++;sumSquares+=mixed*mixed;short pcm=(short)Math.Round(mixed*32767.0);samples.Add(pcm);framesTotal++;}
          }finally{Check(capture.ReleaseBuffer(frameCount),"IAudioCaptureClient.ReleaseBuffer");}
        }
        result.Frames=checked((int)Math.Min(framesTotal,int.MaxValue));result.Packets=packets;result.SilentPackets=silentPackets;result.NonZeroSamples=checked((int)Math.Min(nonZero,int.MaxValue));result.Peak=peak;result.Rms=framesTotal==0?0:Math.Sqrt(sumSquares/framesTotal);result.Pcm16Mono=samples.ToArray();
      }catch(Exception e){if(result!=null)result.Error=e.GetType().FullName+": "+e.Message;if(startError==null)startError=e.GetType().FullName+": "+e.Message;ready.Set();}
      finally{try{if(started)Check(client.Stop(),"IAudioClient.Stop");}catch{}if(mix!=IntPtr.Zero)Marshal.FreeCoTaskMem(mix);if(captureObject!=null&&Marshal.IsComObject(captureObject))Marshal.ReleaseComObject(captureObject);if(clientObject!=null&&Marshal.IsComObject(clientObject))Marshal.ReleaseComObject(clientObject);if(device!=null&&Marshal.IsComObject(device))Marshal.ReleaseComObject(device);if(en!=null&&Marshal.IsComObject(en))Marshal.ReleaseComObject(en);if(result!=null)result.CompletedUtc=DateTime.UtcNow.ToString("o");done.Set();}
    }
  }
  public sealed class SessionMeterRecorder {
    readonly ManualResetEventSlim ready=new ManualResetEventSlim(false),done=new ManualResetEventSlim(false);
    Thread worker;int durationMs,targetPid;string startError;EBR_AUDIO_SESSION_METER_RESULT result;
    public string Begin(int processId,int milliseconds){targetPid=processId;durationMs=milliseconds;worker=new Thread(Record);worker.IsBackground=true;worker.Name="EBR candidate WASAPI session meter";worker.SetApartmentState(ApartmentState.MTA);worker.Start();if(!ready.Wait(5000))return "Candidate audio-session meter did not initialize within five seconds.";return startError;}
    public EBR_AUDIO_SESSION_METER_RESULT Finish(int timeoutMs){if(worker==null)return null;if(!done.Wait(timeoutMs))throw new TimeoutException("Candidate audio-session meter did not complete within the requested timeout.");return result;}
    void Record(){
      EBR_IMMDeviceEnumerator en=null;EBR_IMMDevice device=null;object managerObject=null;EBR_IAudioSessionManager2 manager=null;
      result=new EBR_AUDIO_SESSION_METER_RESULT{ProcessId=targetPid,StartedUtc=DateTime.UtcNow.ToString("o")};
      try{
        en=CreateEnumerator();device=GetDefault(en);result.EndpointId=DeviceId(device);Guid iid=new Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F");Check(device.Activate(ref iid,CLSCTX_ALL,IntPtr.Zero,out managerObject),"IMMDevice.Activate(IAudioSessionManager2)");manager=(EBR_IAudioSessionManager2)managerObject;ready.Set();
        var timer=Stopwatch.StartNew();
        while(timer.ElapsedMilliseconds<durationMs){EBR_IAudioSessionEnumerator sessions=null;
          try{
            Check(manager.GetSessionEnumerator(out sessions),"IAudioSessionManager2.GetSessionEnumerator");int count;Check(sessions.GetCount(out count),"IAudioSessionEnumerator.GetCount");result.Polls++;
            for(int i=0;i<count;i++){EBR_IAudioSessionControl session=null;EBR_IAudioSessionControl2 control=null;EBR_IAudioMeterInformation meter=null;
              bool isCandidateSession=false;
              try{
                Check(sessions.GetSession(i,out session),"IAudioSessionEnumerator.GetSession");control=(EBR_IAudioSessionControl2)session;uint processId;int processHr=control.GetProcessId(out processId);if(processHr<0||processId!=(uint)targetPid)continue;isCandidateSession=true;
                result.SessionObservedSamples++;int state;Check(control.GetState(out state),"IAudioSessionControl.GetState");if(state==1)result.ActiveSamples++;
                meter=control as EBR_IAudioMeterInformation;if(meter==null)continue;float peak;Check(meter.GetPeakValue(out peak),"IAudioMeterInformation.GetPeakValue");result.MeterSamples++;if(peak>result.Peak)result.Peak=peak;if(state==1&&peak>0.0001f)result.NonZeroSamples++;
              }catch(Exception e){if(isCandidateSession&&result.Error==null)result.Error=e.GetType().FullName+": "+e.Message;}
              finally{
                if(session!=null&&Marshal.IsComObject(session))Marshal.ReleaseComObject(session);
              }
            }
          }catch(Exception e){if(result.Error==null)result.Error=e.GetType().FullName+": "+e.Message;}
          finally{if(sessions!=null&&Marshal.IsComObject(sessions))Marshal.ReleaseComObject(sessions);}
          Thread.Sleep(10);
        }
      }catch(Exception e){if(result!=null)result.Error=e.GetType().FullName+": "+e.Message;if(startError==null)startError=result.Error;ready.Set();}
      finally{if(managerObject!=null&&Marshal.IsComObject(managerObject))Marshal.ReleaseComObject(managerObject);if(device!=null&&Marshal.IsComObject(device))Marshal.ReleaseComObject(device);if(en!=null&&Marshal.IsComObject(en))Marshal.ReleaseComObject(en);if(result!=null)result.CompletedUtc=DateTime.UtcNow.ToString("o");done.Set();}
    }
  }
}
'@

function Get-AudioControl([int]$Id,[string]$Name){
  $found=@(foreach($h in [EBR_AUDIO_NATIVE]::ChildWindows($script:mainWindow)){if([EBR_AUDIO_NATIVE]::OwnerPid($h)-eq$script:appPid-and[EBR_AUDIO_NATIVE]::Visible($h)-and[EBR_AUDIO_NATIVE]::ControlId($h)-eq$Id){[pscustomobject]@{Handle=$h;Id=$Id;Class=[EBR_AUDIO_NATIVE]::ClassName($h);Text=[EBR_AUDIO_NATIVE]::Text($h);Enabled=[EBR_AUDIO_NATIVE]::Enabled($h)}}})
  if($found.Count-ne1){throw "Expected one visible candidate control '$Name' (ID $Id), found $($found.Count)."};return $found[0]
}
function Assert-NaturalAlarmConsoleInputGate {
  $record=$script:consoleDesktopRecord;$checks=if($record){$record.Checks}else{$null}
  $currentSession=[Diagnostics.Process]::GetCurrentProcess().SessionId;$activeConsoleSession=[EBR_AUDIO_NATIVE]::WTSGetActiveConsoleSessionId();$windowStation=[EBR_AUDIO_NATIVE]::ProcessWindowStationName();$threadDesktop=[EBR_AUDIO_NATIVE]::ThreadDesktopName();$inputDesktop=[EBR_AUDIO_NATIVE]::InputDesktopName()
  $valid=($script:server2025ConsoleContext-and$script:runnerFlavor-ceq'Server2025ConsoleX64'-and$record-and$record.RunnerContext-ceq'GitHub-hosted Windows Server 2025 x64'-and$record.OSArchitecture-ceq'X64'-and$record.ProcessArchitecture-ceq'X64'-and$record.ExpectedSessionName-ieq'Console'-and$record.RawSessionNameAccepted-and$record.ProcessSessionId-eq$record.ActiveConsoleSessionId-and$record.ProcessSessionId-eq$currentSession-and$activeConsoleSession-eq$currentSession-and[Environment]::UserInteractive-and$windowStation-ceq'WinSta0'-and$threadDesktop-ceq'Default'-and$inputDesktop-ceq'Default'-and$checks-and$checks.Identity-and$checks.ActiveConsoleSession-and$checks.Desktop-and$checks.TaskbarOwnedByExplorer-and$checks.Shell)
  if(-not$valid){throw 'NOT TESTED: native pointer/keyboard entry is authorized only in a verified disposable GitHub-hosted Server 2025 x64 Console desktop.'}
}
function Assert-NaturalWorkEditFocus([IntPtr]$ExpectedHandle,[string]$Stage){
  Assert-NaturalAlarmConsoleInputGate
  $current=Get-AudioControl 100 'Work interval';$foreground=[EBR_AUDIO_NATIVE]::ForegroundWindow();$focus=[EBR_AUDIO_NATIVE]::FocusForWindow($ExpectedHandle)
  $foregroundPid=if($foreground-ne[IntPtr]::Zero){[EBR_AUDIO_NATIVE]::OwnerPid($foreground)}else{0}
  $ok=($current.Handle-eq$ExpectedHandle-and$current.Class-ceq'Edit'-and$current.Enabled-and[EBR_AUDIO_NATIVE]::OwnerPid($ExpectedHandle)-eq$script:appPid-and$foreground-eq$script:mainWindow-and$foregroundPid-eq$script:appPid-and$focus.OwnerProcessId-eq$script:appPid-and$focus.FocusedWindow-eq$ExpectedHandle-and$focus.FocusedThreadId-eq$focus.ThreadId-and$focus.FocusedProcessId-eq$script:appPid)
  $evidence=[pscustomobject]@{Stage=$Stage;WorkEditHandle=('0x{0:X}'-f$ExpectedHandle.ToInt64());WorkEditOwnerProcessId=[EBR_AUDIO_NATIVE]::OwnerPid($ExpectedHandle);ForegroundHandle=('0x{0:X}'-f$foreground.ToInt64());ForegroundProcessId=$foregroundPid;TargetGuiThreadId=$focus.ThreadId;FocusedHandle=('0x{0:X}'-f$focus.FocusedWindow.ToInt64());FocusedThreadId=$focus.FocusedThreadId;FocusedProcessId=$focus.FocusedProcessId;GuiThreadFlags=$focus.Flags;ExactCandidateEditFocused=$ok}
  if(-not$ok){throw "NOT TESTED: candidate Work interval Edit focus verification failed at '$Stage': $($evidence|ConvertTo-Json -Compress -Depth 4)."}
  return $evidence
}
function Focus-NaturalWorkEditWithPointer($WorkControl){
  Assert-NaturalAlarmConsoleInputGate
  if($WorkControl.Id-ne100-or$WorkControl.Class-cne'Edit'-or-not$WorkControl.Enabled-or[EBR_AUDIO_NATIVE]::OwnerPid($WorkControl.Handle)-ne$script:appPid){throw 'NOT TESTED: refusing pointer input because the Work interval is not the exact enabled candidate-owned Edit HWND.'}
  $activated=[EBR_AUDIO_NATIVE]::TryActivate($script:mainWindow);Start-Sleep -Milliseconds 100
  $foreground=[EBR_AUDIO_NATIVE]::ForegroundWindow();$foregroundPid=if($foreground-ne[IntPtr]::Zero){[EBR_AUDIO_NATIVE]::OwnerPid($foreground)}else{0};$rootAtCenter=[EBR_AUDIO_NATIVE]::RootWindowAtCenter($script:mainWindow)
  $foregroundRecovery=$null
  if(-not$activated-or$foreground-ne$script:mainWindow-or$foregroundPid-ne$script:appPid-or$rootAtCenter-ne$script:mainWindow){
    $failureEvidence=Get-NaturalAlarmForegroundFailureEvidence $activated $foreground $foregroundPid $rootAtCenter
    $script:naturalAlarmForegroundFailureEvidence=$failureEvidence
    $modal=Find-NaturalAlarmExactForegroundAudioDialog $foreground
    if(-not$modal.Matched){Add-AudioEvent 'Capture candidate foreground failure diagnostics; do not relax the exact window gate' 'NOT TESTED' ([pscustomobject]@{Failure=$failureEvidence;ExactAudioUnavailableModal=$modal});throw 'NOT TESTED: candidate window was not the exact unobscured foreground window before Work interval pointer input; foreground diagnostics were captured and no safe exact modal was identified.'}
    $dismissal=Dismiss-NaturalAlarmExactAudioUnavailableDialog $modal.DialogHandle
    if(-not$dismissal.ExactDialogVerified-or-not$dismissal.ButtonClickReturned-or-not$dismissal.DialogClosed){$script:naturalAlarmForegroundFailureEvidence=[pscustomobject]@{InitialFailure=$failureEvidence;ExactAudioUnavailableModal=$modal;DismissalAttempt=$dismissal};Add-AudioEvent 'Capture exact audio-unavailable dialog evidence without using an unverified dismissal route' 'NOT TESTED' $script:naturalAlarmForegroundFailureEvidence;throw 'NOT TESTED: the exact audio-unavailable dialog did not close through its uniquely verified enabled OK button; no pointer or keyboard input was sent.'}
    Add-AudioEvent 'Dismiss only the exact candidate-owned audio-unavailable modal through its unique enabled OK button' 'PASS' $dismissal
    $activatedAfterDismissal=[EBR_AUDIO_NATIVE]::TryActivate($script:mainWindow);Start-Sleep -Milliseconds 100
    $foregroundAfterDismissal=[EBR_AUDIO_NATIVE]::ForegroundWindow();$foregroundPidAfterDismissal=if($foregroundAfterDismissal-ne[IntPtr]::Zero){[EBR_AUDIO_NATIVE]::OwnerPid($foregroundAfterDismissal)}else{0};$rootAtCenterAfterDismissal=[EBR_AUDIO_NATIVE]::RootWindowAtCenter($script:mainWindow)
    $recovered=($activatedAfterDismissal-and$foregroundAfterDismissal-eq$script:mainWindow-and$foregroundPidAfterDismissal-eq$script:appPid-and$rootAtCenterAfterDismissal-eq$script:mainWindow)
    $foregroundRecovery=[pscustomobject]@{Cause='The exact candidate-owned native audio-unavailable TaskDialog was the foreground modal';FailureDiagnostics=$failureEvidence;ExactDialogDismissal=$dismissal;ActivationSucceededAfterDismissal=$activatedAfterDismissal;ForegroundHandleAfterDismissal=('0x{0:X}'-f$foregroundAfterDismissal.ToInt64());ForegroundProcessIdAfterDismissal=$foregroundPidAfterDismissal;RootAtCandidateCenterAfterDismissal=('0x{0:X}'-f$rootAtCenterAfterDismissal.ToInt64());ExactCandidateForegroundGateRecovered=$recovered;PostDismissalScreenshot=(Save-WindowScreenshot $script:mainWindow 'natural-alarm-candidate-foreground-after-modal-dismissal.png')}
    $script:naturalAlarmForegroundFailureEvidence=$foregroundRecovery
    if(-not$recovered){$afterEvidence=Get-NaturalAlarmForegroundFailureEvidence $activatedAfterDismissal $foregroundAfterDismissal $foregroundPidAfterDismissal $rootAtCenterAfterDismissal;$script:naturalAlarmForegroundFailureEvidence=[pscustomobject]@{Initial=$foregroundRecovery;AfterDismissalFailure=$afterEvidence};Add-AudioEvent 'Recheck the exact candidate foreground gate after dismissing the verified audio-unavailable modal' 'NOT TESTED' $script:naturalAlarmForegroundFailureEvidence;throw 'NOT TESTED: the verified audio-unavailable modal was dismissed, but the exact candidate foreground/unobscured gate still failed; no pointer or keyboard input was sent.'}
    Add-AudioEvent 'Recheck the exact candidate foreground gate after dismissing the verified audio-unavailable modal' 'PASS' $foregroundRecovery
  }
  $foreground=[EBR_AUDIO_NATIVE]::ForegroundWindow();$foregroundPid=if($foreground-ne[IntPtr]::Zero){[EBR_AUDIO_NATIVE]::OwnerPid($foreground)}else{0};$rootAtCenter=[EBR_AUDIO_NATIVE]::RootWindowAtCenter($script:mainWindow)
  if($foreground-ne$script:mainWindow-or$foregroundPid-ne$script:appPid-or$rootAtCenter-ne$script:mainWindow){throw 'NOT TESTED: exact candidate foreground/unobscured gate changed before Work interval pointer input.'}
  $bounds=[EBR_AUDIO_NATIVE+RECT]::new();if(-not[EBR_AUDIO_NATIVE]::WindowRect($WorkControl.Handle,[ref]$bounds)){throw 'NOT TESTED: could not obtain the exact Work interval Edit bounds.'}
  $width=$bounds.Right-$bounds.Left;$height=$bounds.Bottom-$bounds.Top;if($width-lt6-or$height-lt6){throw 'NOT TESTED: Work interval Edit has invalid pointer target bounds.'}
  $x=$bounds.Left+[Math]::Min(8,[Math]::Max(2,[int]($width/2)));$y=$bounds.Top+[int]($height/2);$hit=[EBR_AUDIO_NATIVE]::WindowAtPoint($x,$y)
  if($hit-ne$WorkControl.Handle-or[EBR_AUDIO_NATIVE]::OwnerPid($hit)-ne$script:appPid){throw "NOT TESTED: pointer hit test did not resolve to the exact candidate Work interval Edit HWND (hit=0x$('{0:X}'-f$hit.ToInt64()))."}
  if(-not[EBR_AUDIO_NATIVE]::ClickLeftAtExactWindow($WorkControl.Handle,$x,$y)){throw 'NOT TESTED: exact-window native pointer click could not be issued safely.'}
  Start-Sleep -Milliseconds 100
  $focus=Assert-NaturalWorkEditFocus $WorkControl.Handle 'after verified native pointer click'
  return [pscustomobject]@{Method='SetCursorPos + exact WindowFromPoint check + native left-button input';CandidateMainWindow=('0x{0:X}'-f$script:mainWindow.ToInt64());CandidateProcessId=$script:appPid;WorkEditHandle=('0x{0:X}'-f$WorkControl.Handle.ToInt64());WorkEditBounds=[pscustomobject]@{Left=$bounds.Left;Top=$bounds.Top;Right=$bounds.Right;Bottom=$bounds.Bottom};ClickPoint=[pscustomobject]@{X=$x;Y=$y};HitTestHandle=('0x{0:X}'-f$hit.ToInt64());CandidateForegroundHandle=('0x{0:X}'-f([EBR_AUDIO_NATIVE]::ForegroundWindow()).ToInt64());CandidateForegroundProcessId=[EBR_AUDIO_NATIVE]::OwnerPid([EBR_AUDIO_NATIVE]::ForegroundWindow());ForegroundRecovery=$foregroundRecovery;FocusVerification=$focus;Screenshot=(Save-WindowScreenshot $script:mainWindow 'natural-alarm-work-interval-pointer-focus.png')}
}
function Add-ControlEvidence([int]$Id,[string]$Name){
  $control=Get-AudioControl $Id $Name;$uia=$null
  try{$element=[System.Windows.Automation.AutomationElement]::FromHandle($control.Handle);$uia=[pscustomobject]@{Name=$element.Current.Name;Role=$element.Current.ControlType.ProgrammaticName;AutomationId=$element.Current.AutomationId;IsEnabled=$element.Current.IsEnabled}}catch{$uia=[pscustomobject]@{Error=$_.Exception.Message}}
  Add-AudioEvent "Inspect real Settings control: $Name" 'PASS' ([pscustomobject]@{ControlId=$Id;Class=$control.Class;Text=$control.Text;Enabled=$control.Enabled;UIAutomation=$uia})
}
function Invoke-AudioClick([int]$Id,[string]$Name){$control=Get-AudioControl $Id $Name;if(-not$control.Enabled){throw "Candidate control '$Name' is disabled."};$result=[IntPtr]::Zero;if(-not[EBR_AUDIO_NATIVE]::SendBounded($control.Handle,0x00F5,[IntPtr]::Zero,[IntPtr]::Zero,5000,[ref]$result)){throw "Candidate control '$Name' did not return from BM_CLICK within five seconds."}}
function Get-AudioComboIndex([int]$Id,[string]$Name){$c=Get-AudioControl $Id $Name;if($c.Class-ne'ComboBox'){throw "Candidate control '$Name' is not a ComboBox."};return [EBR_AUDIO_NATIVE]::Send($c.Handle,0x0147,[IntPtr]::Zero,[IntPtr]::Zero).ToInt32()}
function Set-AudioSound([int]$Index){
  $c=Get-AudioControl 102 'Alarm sound';if($c.Class-ne'ComboBox'){throw 'Alarm sound control is not a ComboBox.'}
  [void][EBR_AUDIO_NATIVE]::Send($c.Handle,0x014E,[IntPtr]::new($Index),[IntPtr]::Zero);$parent=[EBR_AUDIO_NATIVE]::Parent($c.Handle);$wp=[IntPtr]::new([long](102-bor(1-shl16)));[void][EBR_AUDIO_NATIVE]::Send($parent,0x0111,$wp,$c.Handle)
  if((Get-AudioComboIndex 102 'Alarm sound')-ne$Index){throw "Alarm sound combobox did not select index $Index."}
}
function Set-AudioVolume([int]$Value){
  $c=Get-AudioControl 103 'Alarm volume';if($c.Class-notin@('MSTrackBarWndClass','TrackBar','msctls_trackbar32')){throw "Alarm volume control has unexpected class '$($c.Class)'."}
  [void][EBR_AUDIO_NATIVE]::Send($c.Handle,0x0405,[IntPtr]::new(1),[IntPtr]::new($Value));$parent=[EBR_AUDIO_NATIVE]::Parent($c.Handle);$packed=[IntPtr]::new([long](8-bor($Value-shl16)));[void][EBR_AUDIO_NATIVE]::Send($parent,0x0114,$packed,$c.Handle)
  $position=[EBR_AUDIO_NATIVE]::Send($c.Handle,0x0400,[IntPtr]::Zero,[IntPtr]::Zero).ToInt32()
  if($position-ne$Value){throw "Alarm volume trackbar returned $position after requesting $Value%."}
  $settingsPane=[EBR_AUDIO_NATIVE]::Parent($c.Handle)
  if($settingsPane-eq[IntPtr]::Zero-or[EBR_AUDIO_NATIVE]::OwnerPid($settingsPane)-ne$script:appPid-or[EBR_AUDIO_NATIVE]::ClassName($settingsPane)-ine'EyeBreakReminder.Settings'){throw 'Alarm volume trackbar is not parented by the candidate Settings pane.'}
  # The candidate gives this label logical ID 119 in its controls model after creation, while its native STATIC HWND retains ID -1. Identify it by its exact Settings-pane parent and live percentage text.
  $readouts=@(foreach($h in [EBR_AUDIO_NATIVE]::ChildWindows($settingsPane)){if([EBR_AUDIO_NATIVE]::OwnerPid($h)-eq$script:appPid-and[EBR_AUDIO_NATIVE]::Visible($h)-and[EBR_AUDIO_NATIVE]::Parent($h)-eq$settingsPane-and[EBR_AUDIO_NATIVE]::ClassName($h)-ieq'Static'){$text=[EBR_AUDIO_NATIVE]::Text($h);if($text-match'^\d{1,3}%$'){[pscustomobject]@{Handle=$h;Text=$text;Class=[EBR_AUDIO_NATIVE]::ClassName($h);ParentHandle=('0x{0:X}'-f$settingsPane.ToInt64())}}}})
  if($readouts.Count-ne1){$observed=(@($readouts|ForEach-Object{$_.Text})-join', ');throw "Expected exactly one candidate-owned visible percentage readout in the Alarm Settings pane, found $($readouts.Count) [$observed]."}
  if($readouts[0].Text-cne("$Value%")){throw "Alarm volume readout shows '$($readouts[0].Text)' after requesting $Value%."}
}
function Get-AudioCheck([int]$Id,[string]$Name){$c=Get-AudioControl $Id $Name;return [EBR_AUDIO_NATIVE]::Send($c.Handle,0x00F0,[IntPtr]::Zero,[IntPtr]::Zero).ToInt32()-eq1}
function Set-AudioCheck([int]$Id,[bool]$Value,[string]$Name){if((Get-AudioCheck $Id $Name)-ne$Value){Invoke-AudioClick $Id $Name};if((Get-AudioCheck $Id $Name)-ne$Value){throw "Candidate checkbox '$Name' did not reach state $Value."}}
function Read-AudioSettings {
  $path=Join-Path $script:appDataPath 'settings.ini';$map=@{}
  if(Test-Path -LiteralPath $path -PathType Leaf){foreach($line in Get-Content -LiteralPath $path){if($line-match'^([^=]+)=(.*)$'){$map[$Matches[1]]=$Matches[2]}}}
  return $map
}
function Wait-AudioSetting([string]$Key,[string]$Expected){$watch=[Diagnostics.Stopwatch]::StartNew();do{$saved=Read-AudioSettings;if($saved.ContainsKey($Key)-and[string]$saved[$Key]-ceq$Expected){return $true};Start-Sleep -Milliseconds 50}while($watch.Elapsed.TotalSeconds-lt4);return $false}
function Get-AudioWindowNativeText([IntPtr]$Handle){
  $text=[System.Collections.Generic.List[string]]::new();$title=[EBR_AUDIO_NATIVE]::Text($Handle);if($title){$text.Add($title)};foreach($child in [EBR_AUDIO_NATIVE]::ChildWindows($Handle)){$value=[EBR_AUDIO_NATIVE]::Text($child);if($value){$text.Add($value)}}
  return $text-join' '
}
function Get-AudioErrorDialog {
  $candidates=[System.Collections.Generic.List[IntPtr]]::new()
  $popup=[EBR_AUDIO_NATIVE]::LastActivePopup($script:mainWindow)
  if($popup-ne[IntPtr]::Zero-and$popup-ne$script:mainWindow){$candidates.Add($popup)}
  foreach($h in [EBR_AUDIO_NATIVE]::TopWindowsForProcess($script:appPid)){if($h-ne$script:mainWindow-and-not$candidates.Contains($h)){$candidates.Add($h)}}
  foreach($h in $candidates){
    if(-not[EBR_AUDIO_NATIVE]::Visible($h)-or[EBR_AUDIO_NATIVE]::OwnerPid($h)-ne$script:appPid){continue}
    if((Get-AudioWindowNativeText $h)-match'The alarm couldn.t play\. Check your Windows audio output\.') {return $h}
  }
  return [IntPtr]::Zero
}
function Save-WindowScreenshot([IntPtr]$Handle,[string]$Name){
  $path=Join-Path $script:evidenceRoot $Name
  try{$bounds=[EBR_AUDIO_NATIVE+RECT]::new();if(-not[EBR_AUDIO_NATIVE]::WindowRect($Handle,[ref]$bounds)){return $null};$width=$bounds.Right-$bounds.Left;$height=$bounds.Bottom-$bounds.Top;if($width-le0-or$height-le0-or$width-gt5000-or$height-gt5000){return $null};$bitmap=[Drawing.Bitmap]::new($width,$height);$graphics=[Drawing.Graphics]::FromImage($bitmap);try{$graphics.CopyFromScreen($bounds.Left,$bounds.Top,0,0,$bitmap.Size);$bitmap.Save($path,[Drawing.Imaging.ImageFormat]::Png)}finally{$graphics.Dispose();$bitmap.Dispose()};return $path}catch{return $null}
}
function Get-TopWindowNarration([IntPtr]$Handle){
  $pieces=[System.Collections.Generic.List[string]]::new();$title=[EBR_AUDIO_NATIVE]::Text($Handle);if($title){$pieces.Add($title)}
  foreach($child in [EBR_AUDIO_NATIVE]::ChildWindows($Handle)){$text=[EBR_AUDIO_NATIVE]::Text($child);if($text){$pieces.Add($text)}}
  $controls=@()
  try{$root=[System.Windows.Automation.AutomationElement]::FromHandle($Handle);if($root){if($root.Current.Name){$pieces.Add([string]$root.Current.Name)};$all=$root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition);foreach($element in $all){try{$name=[string]$element.Current.Name;if($name){$pieces.Add($name)};$toggle=$null;if($element.Current.ControlType-eq[System.Windows.Automation.ControlType]::CheckBox){try{if($element.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern,[ref]$toggle)){$controls+=,[pscustomobject]@{Name=$name;Role=$element.Current.ControlType.ProgrammaticName;ToggleState=$toggle.Current.ToggleState.ToString()}}}catch{}}}catch{}}}}catch{}
  return [pscustomobject]@{Window=$Handle;Handle=('0x{0:X}'-f$Handle.ToInt64());ProcessId=[EBR_AUDIO_NATIVE]::OwnerPid($Handle);Title=$title;Text=@($pieces|Select-Object -Unique);Selections=$controls;Screenshot=$null}
}
function Find-ExactPrivacyPage {
  $matches=@()
  foreach($window in [EBR_AUDIO_NATIVE]::AllTopWindows()){$info=Get-TopWindowNarration $window;if(($info.Text-join' ')-match'(?i)Choose privacy settings for your device'){$matches+=,$info}}
  return ,$matches
}
function Prepare-DisposableRunnerDesktop {
  $privacy=Find-ExactPrivacyPage
  if(-not$privacy.Count){Add-AudioEvent 'Disposable runner desktop is not covered by the first-sign-in privacy page' 'PASS' ([pscustomobject]@{PrivacyPagePresent=$false});return}
  if($privacy.Count-ne1){Add-AudioEvent 'Handle only the exact first-sign-in privacy page without accepting agreements' 'BLOCKED' ([pscustomobject]@{MatchingPages=$privacy;Reason='More than one matching privacy page is visible.'});throw 'Ambiguous first-sign-in privacy overlay.'}
  $page=$privacy[0];$page.Screenshot=Save-WindowScreenshot $page.Window 'runner-first-sign-in-privacy-page.png'
  $root=[System.Windows.Automation.AutomationElement]::FromHandle($page.Window);$all=$root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
  $next=@();$agreement=@()
  foreach($element in $all){try{$name=[string]$element.Current.Name;if($element.Current.ControlType-eq[System.Windows.Automation.ControlType]::Button-and$name-match'^\s*Next\s*$'){$next+=,$element};if($element.Current.ControlType-eq[System.Windows.Automation.ControlType]::Button-and$name-match'(?i)accept|agree|i agree|continue'){$agreement+=,$name}}catch{}}
  $beforeSelections=@($page.Selections)
  if($next.Count-ne1-or$agreement.Count){Add-AudioEvent 'Advance only the exact first-sign-in privacy page' 'BLOCKED' ([pscustomobject]@{Page=$page;NextButtonCount=$next.Count;OtherConsentButtons=$agreement;Reason='The page did not expose exactly one Next button, or consent/agreement controls were present.'});throw 'Refusing to interact with an ambiguous privacy/consent screen.'}
  if(-not$AllowExactPrivacyOobeNext){Add-AudioEvent 'Do not advance the exact first-sign-in privacy page without owner authorization' 'BLOCKED' ([pscustomobject]@{Page=$page;Action='None';NextButtonName='Next';NextButtonCount=$next.Count;DefaultSelectionsChanged=$false;AgreementOrAcceptActionInvoked=$false;Reason='The owner has not authorized advancing this Windows privacy OOBE page.'});throw 'BLOCKED: exact Windows privacy OOBE Next action requires explicit owner authorization.'}
  # This is a disposable GitHub-hosted runner only. Invoke the single Next action; do not change the default selections.
  try{$next[0].GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()}catch{Add-AudioEvent 'Advance only the exact first-sign-in privacy page' 'BLOCKED' ([pscustomobject]@{Page=$page;Reason=$_.Exception.Message;DefaultSelectionsChanged=$false;AgreementOrAcceptActionInvoked=$false});throw 'Could not invoke the exact privacy-page Next button.'}
  $watch=[Diagnostics.Stopwatch]::StartNew();$remaining=$true
  while($watch.Elapsed.TotalSeconds-lt15){Start-Sleep -Milliseconds 100;$remaining=(Find-ExactPrivacyPage).Count-gt0;if(-not$remaining){break}}
  if($remaining){Add-AudioEvent 'Advance only the exact first-sign-in privacy page' 'BLOCKED' ([pscustomobject]@{Page=$page;Reason='The privacy page remained visible after invoking Next.';DefaultSelectionsChanged=$false;AgreementOrAcceptActionInvoked=$false});throw 'First-sign-in privacy page did not close after Next.'}
  Add-AudioEvent 'Advance only the exact first-sign-in privacy page' 'PASS' ([pscustomobject]@{Page=$page;Action='Invoked the single exact UI Automation button named Next';DefaultSelectionsBefore=$beforeSelections;DefaultSelectionsChanged=$false;AgreementOrAcceptActionInvoked=$false;OtherOobePagesClicked=$false;OwnerAuthorizationSwitch=$true;Screenshot=$page.Screenshot})
}
function Assert-CandidateForegroundAndUnobscured {
  $activated=[EBR_AUDIO_NATIVE]::TryActivate($script:mainWindow);Start-Sleep -Milliseconds 150
  $foreground=[EBR_AUDIO_NATIVE]::ForegroundWindow();$foregroundPid=if($foreground-ne[IntPtr]::Zero){[EBR_AUDIO_NATIVE]::OwnerPid($foreground)}else{0};$rootAtCenter=[EBR_AUDIO_NATIVE]::RootWindowAtCenter($script:mainWindow)
  $ok=$activated-and$foreground-eq$script:mainWindow-and$rootAtCenter-eq$script:mainWindow
  Add-AudioEvent 'Candidate Settings window is foreground and unobscured after runner startup' $(if($ok){'PASS'}else{'BLOCKED'}) ([pscustomobject]@{ActivateSucceeded=$activated;ForegroundHandle=('0x{0:X}'-f$foreground.ToInt64());ForegroundOwnerProcessId=$foregroundPid;CandidateProcessId=$script:appPid;CandidateHandle=('0x{0:X}'-f$script:mainWindow.ToInt64());WindowAtCandidateCenterRoot=('0x{0:X}'-f$rootAtCenter.ToInt64());Screenshot=(Save-WindowScreenshot $script:mainWindow 'candidate-window-foreground-check.png')})
  if(-not$ok){throw 'Candidate window could not be verified as the foreground, unobscured window; no audio controls were exercised.'}
}
function Save-LoopbackWave($Capture,[string]$Name){
  if(-not$Capture-or$Capture.Error-or-not$Capture.Pcm16Mono-or$Capture.Pcm16Mono.Length-eq0){return $null}
  $path=Join-Path $script:evidenceRoot $Name;$payload=[byte[]]::new($Capture.Pcm16Mono.Length*2);[Buffer]::BlockCopy($Capture.Pcm16Mono,0,$payload,0,$payload.Length)
  $stream=[IO.File]::Open($path,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
  try{$writer=[IO.BinaryWriter]::new($stream,[Text.Encoding]::ASCII,$true);try{$writer.Write([Text.Encoding]::ASCII.GetBytes('RIFF'));$writer.Write([int](36+$payload.Length));$writer.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt '));$writer.Write([int]16);$writer.Write([short]1);$writer.Write([short]1);$writer.Write([int]$Capture.SampleRate);$writer.Write([int]($Capture.SampleRate*2));$writer.Write([short]2);$writer.Write([short]16);$writer.Write([Text.Encoding]::ASCII.GetBytes('data'));$writer.Write([int]$payload.Length);$writer.Write($payload)}finally{$writer.Dispose()}}finally{$stream.Dispose()}
  return $path
}
function Complete-UnavailableDialog([IntPtr]$Dialog,[string]$Tag){
  $dialogClassBeforeDismissal=[EBR_AUDIO_NATIVE]::ClassName($Dialog);$dialogOwnerBeforeDismissal=[EBR_AUDIO_NATIVE]::OwnerPid($Dialog);$dialogTextBeforeDismissal=Get-AudioWindowNativeText $Dialog
  if($Dialog-eq$script:mainWindow-or$dialogOwnerBeforeDismissal-ne$script:appPid-or$dialogClassBeforeDismissal-cne'#32770'-or$dialogTextBeforeDismissal-notmatch'The alarm couldn.t play\. Check your Windows audio output\.'){throw 'Refusing to dismiss a window that is not the exact candidate-owned native audio-unavailable TaskDialog.'}
  $candidateHandleCountBeforeDismissal=Get-CandidateHandleCount
  $shot=Save-WindowScreenshot $Dialog "$Tag-audio-unavailable.png";$buttons=@(foreach($h in [EBR_AUDIO_NATIVE]::ChildWindows($Dialog)){if([EBR_AUDIO_NATIVE]::OwnerPid($h)-eq$script:appPid-and[EBR_AUDIO_NATIVE]::ClassName($h)-ieq'Button'-and[EBR_AUDIO_NATIVE]::ControlId($h)-eq1-and[EBR_AUDIO_NATIVE]::Visible($h)-and[EBR_AUDIO_NATIVE]::Enabled($h)-and[EBR_AUDIO_NATIVE]::Text($h)-match'^\s*&?OK\s*$'){$h}})
  $dismissMethod=$null
  if($buttons.Count-eq1){$r=[IntPtr]::Zero;if([EBR_AUDIO_NATIVE]::SendBounded($buttons[0],0x00F5,[IntPtr]::Zero,[IntPtr]::Zero,3000,[ref]$r)){$dismissMethod='native OK button BM_CLICK'}}
  # Keep this path native-only so UIA provider calls cannot perturb the
  # candidate-process handle counts being measured by the audio acceptance.
  $uiaOkButtonCount=$null
  $watch=[Diagnostics.Stopwatch]::StartNew();while([EBR_AUDIO_NATIVE]::Visible($Dialog)-and$watch.Elapsed.TotalSeconds-lt1){Start-Sleep -Milliseconds 25}
  $taskDialogClickSent=$false
  $watch=[Diagnostics.Stopwatch]::StartNew();while([EBR_AUDIO_NATIVE]::Visible($Dialog)-and$watch.Elapsed.TotalSeconds-lt4){Start-Sleep -Milliseconds 25}
  $candidateHandleCountAfterDismissal=Get-CandidateHandleCount
  $handleCounts=[System.Collections.Generic.List[int]]::new();$watch=[Diagnostics.Stopwatch]::StartNew();$previous=$null;$stableSamples=0
  do{$handleCount=Get-CandidateHandleCount;if($null-ne$handleCount){$handleCounts.Add([int]$handleCount);if($null-ne$previous-and$handleCount-eq$previous){$stableSamples++}else{$stableSamples=0};$previous=$handleCount};if($stableSamples-ge2){break};Start-Sleep -Milliseconds 100}while($watch.Elapsed.TotalSeconds-lt3)
  $baselineMilestone=@($script:audioHandleMilestones|Where-Object{$_.Stage-eq'acceptance baseline after Settings control inspection, before endpoint/audio trials'}|Select-Object -Last 1);$baselineCount=if($baselineMilestone.Count){$baselineMilestone[0].HandleCount}else{$null};$handleCountAfterIdle=if($handleCounts.Count){$handleCounts[$handleCounts.Count-1]}else{$null}
  return [pscustomobject]@{Closed=(-not[EBR_AUDIO_NATIVE]::Visible($Dialog));Screenshot=$shot;DialogHandle=('0x{0:X}'-f$Dialog.ToInt64());DialogClass=$dialogClassBeforeDismissal;DialogOwnerProcessId=$dialogOwnerBeforeDismissal;DialogText=$dialogTextBeforeDismissal;OKButtonCount=$buttons.Count;EnabledOKButtonControlId=if($buttons.Count-eq1){[EBR_AUDIO_NATIVE]::ControlId($buttons[0])}else{$null};UIAInspectionPerformed=$false;UIAOKButtonCount=$uiaOkButtonCount;DismissMethod=$dismissMethod;TaskDialogClickSent=$taskDialogClickSent;CandidateHandleCountBeforeDismissal=$candidateHandleCountBeforeDismissal;CandidateHandleCountAfterDismissal=$candidateHandleCountAfterDismissal;CandidateHandleCountsDuringIdle=$handleCounts.ToArray();CandidateHandleCountAfterIdle=$handleCountAfterIdle;IdleSamplesStable=($stableSamples-ge2);AcceptanceBaselineHandleCount=$baselineCount;HandleDeltaFromAcceptanceBaseline=if($null-ne$baselineCount-and$null-ne$handleCountAfterIdle){$handleCountAfterIdle-$baselineCount}else{$null};OriginalAllowedHandleGrowth=2;WithinOriginalAllowedHandleGrowth=if($null-ne$baselineCount-and$null-ne$handleCountAfterIdle){$handleCountAfterIdle-le($baselineCount+2)}else{$null}}
}
function Get-NaturalAlarmNativeWindowEvidence([IntPtr]$Handle,[string]$ScreenshotName){
  if($Handle-eq[IntPtr]::Zero){return [pscustomobject]@{Handle='0x0';OwnerProcessId=0;Class=$null;Title=$null;Visible=$false;Enabled=$false;Bounds=$null;NativeText=@();Children=@();Screenshot=$null}}
  $bounds=[EBR_AUDIO_NATIVE+RECT]::new();$hasBounds=[EBR_AUDIO_NATIVE]::WindowRect($Handle,[ref]$bounds);$children=@(foreach($child in [EBR_AUDIO_NATIVE]::ChildWindows($Handle)){[pscustomobject]@{Handle=('0x{0:X}'-f$child.ToInt64());OwnerProcessId=[EBR_AUDIO_NATIVE]::OwnerPid($child);Class=[EBR_AUDIO_NATIVE]::ClassName($child);ControlId=[EBR_AUDIO_NATIVE]::ControlId($child);Visible=[EBR_AUDIO_NATIVE]::Visible($child);Enabled=[EBR_AUDIO_NATIVE]::Enabled($child);Text=[EBR_AUDIO_NATIVE]::Text($child)}})
  $texts=@(@([EBR_AUDIO_NATIVE]::Text($Handle))+@($children|ForEach-Object{$_.Text}|Where-Object{$_}));$screenshot=if($ScreenshotName){Save-WindowScreenshot $Handle $ScreenshotName}else{$null}
  return [pscustomobject]@{Handle=('0x{0:X}'-f$Handle.ToInt64());OwnerProcessId=[EBR_AUDIO_NATIVE]::OwnerPid($Handle);Class=[EBR_AUDIO_NATIVE]::ClassName($Handle);Title=[EBR_AUDIO_NATIVE]::Text($Handle);ControlId=[EBR_AUDIO_NATIVE]::ControlId($Handle);Visible=[EBR_AUDIO_NATIVE]::Visible($Handle);Enabled=[EBR_AUDIO_NATIVE]::Enabled($Handle);Bounds=if($hasBounds){[pscustomobject]@{Left=$bounds.Left;Top=$bounds.Top;Right=$bounds.Right;Bottom=$bounds.Bottom}}else{$null};NativeText=@($texts|Where-Object{$_}|Select-Object -Unique);Children=$children;Screenshot=$screenshot}
}
function Get-NaturalAlarmForegroundFailureEvidence([bool]$ActivationSucceeded,[IntPtr]$Foreground,[int]$ForegroundProcessId,[IntPtr]$RootAtCenter){
  $main=Get-NaturalAlarmNativeWindowEvidence $script:mainWindow 'natural-alarm-foreground-failure-candidate-main.png'
  $foregroundEvidence=Get-NaturalAlarmNativeWindowEvidence $Foreground 'natural-alarm-foreground-failure-actual-foreground.png'
  $topWindows=@();$index=0
  foreach($window in [EBR_AUDIO_NATIVE]::TopWindowsForProcess($script:appPid)){$index++;$topWindows+=,(Get-NaturalAlarmNativeWindowEvidence $window ('natural-alarm-foreground-failure-candidate-top-{0:D2}.png'-f$index))}
  $lastPopup=[EBR_AUDIO_NATIVE]::LastActivePopup($script:mainWindow);$popupEvidence=if($lastPopup-ne[IntPtr]::Zero-and$lastPopup-ne$script:mainWindow){Get-NaturalAlarmNativeWindowEvidence $lastPopup 'natural-alarm-foreground-failure-last-active-popup.png'}else{$null}
  $focusEvidence=$null;try{$focus=[EBR_AUDIO_NATIVE]::FocusForWindow($script:mainWindow);$focusEvidence=[pscustomobject]@{TargetThreadId=$focus.ThreadId;FocusedHandle=('0x{0:X}'-f$focus.FocusedWindow.ToInt64());FocusedThreadId=$focus.FocusedThreadId;FocusedProcessId=$focus.FocusedProcessId;Flags=$focus.Flags}}catch{$focusEvidence=[pscustomobject]@{Error=$_.Exception.Message}}
  return [pscustomobject]@{CapturedUtc=[DateTime]::UtcNow.ToString('o');CandidateProcessId=$script:appPid;ActivationSucceeded=$ActivationSucceeded;GuardForegroundHandle=('0x{0:X}'-f$Foreground.ToInt64());GuardForegroundProcessId=$ForegroundProcessId;GuardRootAtCandidateCenter=('0x{0:X}'-f$RootAtCenter.ToInt64());CandidateMainWindow=$main;ActualForegroundWindow=$foregroundEvidence;LastActivePopup=$popupEvidence;CandidateGuiThreadFocus=$focusEvidence;VisibleCandidateOwnedTopLevelWindows=$topWindows;DiagnosticScreenshot=$main.Screenshot}
}
function Find-NaturalAlarmExactForegroundAudioDialog([IntPtr]$Foreground){
  $matches=@(foreach($window in [EBR_AUDIO_NATIVE]::TopWindowsForProcess($script:appPid)){if($window-ne$script:mainWindow-and[EBR_AUDIO_NATIVE]::Visible($window)-and[EBR_AUDIO_NATIVE]::OwnerPid($window)-eq$script:appPid-and[EBR_AUDIO_NATIVE]::ClassName($window)-ceq'#32770'-and(Get-AudioWindowNativeText $window)-match'The alarm couldn.t play\. Check your Windows audio output\.'){[pscustomobject]@{NativeHandle=$window;Evidence=(Get-NaturalAlarmNativeWindowEvidence $window $null)}}})
  $lastPopup=[EBR_AUDIO_NATIVE]::LastActivePopup($script:mainWindow)
  $matched=($matches.Count-eq1-and$Foreground-ne[IntPtr]::Zero-and$matches[0].NativeHandle-eq$Foreground-and$lastPopup-eq$Foreground)
  return [pscustomobject]@{Matched=$matched;RequiredClass='#32770';RequiredOwnerProcessId=$script:appPid;RequiredNativeText="The alarm couldn't play. Check your Windows audio output.";ForegroundHandle=if($Foreground-ne[IntPtr]::Zero){'0x{0:X}'-f$Foreground.ToInt64()}else{'0x0'};LastActivePopupHandle=if($lastPopup-ne[IntPtr]::Zero){'0x{0:X}'-f$lastPopup.ToInt64()}else{'0x0'};MatchingDialogCount=$matches.Count;DialogHandle=if($matches.Count-eq1){$matches[0].NativeHandle}else{[IntPtr]::Zero};Dialog=if($matches.Count-eq1){$matches[0].Evidence}else{$null};Reason=if($matched){'Unique visible candidate-owned native error dialog is the foreground and the main window last-active popup.'}else{'No unique exact candidate-owned audio-unavailable dialog is proven to be the current foreground modal.'}}
}
function Dismiss-NaturalAlarmExactAudioUnavailableDialog([IntPtr]$Dialog){
  $title=[EBR_AUDIO_NATIVE]::Text($Dialog);$text=Get-AudioWindowNativeText $Dialog;$class=[EBR_AUDIO_NATIVE]::ClassName($Dialog);$owner=[EBR_AUDIO_NATIVE]::OwnerPid($Dialog);$foreground=[EBR_AUDIO_NATIVE]::ForegroundWindow();$lastPopup=[EBR_AUDIO_NATIVE]::LastActivePopup($script:mainWindow)
  $isExact=($Dialog-ne[IntPtr]::Zero-and$foreground-eq$Dialog-and$lastPopup-eq$Dialog-and[EBR_AUDIO_NATIVE]::Visible($Dialog)-and$class-ceq'#32770'-and$owner-eq$script:appPid-and$text-match'The alarm couldn.t play\. Check your Windows audio output\.')
  $before=Get-CandidateHandleCount;$shot=if($isExact){Save-WindowScreenshot $Dialog 'natural-alarm-exact-audio-unavailable-dialog-before-dismissal.png'}else{$null}
  $buttons=@(if($isExact){foreach($button in [EBR_AUDIO_NATIVE]::ChildWindows($Dialog)){if([EBR_AUDIO_NATIVE]::OwnerPid($button)-eq$script:appPid-and[EBR_AUDIO_NATIVE]::ClassName($button)-ieq'Button'-and[EBR_AUDIO_NATIVE]::Visible($button)-and[EBR_AUDIO_NATIVE]::Enabled($button)-and[EBR_AUDIO_NATIVE]::ControlId($button)-eq1-and[EBR_AUDIO_NATIVE]::Text($button)-match'^\s*&?OK\s*$'){$button}}})
  $clickReturned=$false;$buttonHandle=[IntPtr]::Zero
  if($buttons.Count-eq1){$buttonHandle=$buttons[0];$result=[IntPtr]::Zero;$clickReturned=[EBR_AUDIO_NATIVE]::SendBounded($buttonHandle,0x00F5,[IntPtr]::Zero,[IntPtr]::Zero,5000,[ref]$result)}
  $closed=$false;$watch=[Diagnostics.Stopwatch]::StartNew();while($isExact-and[EBR_AUDIO_NATIVE]::Visible($Dialog)-and$watch.Elapsed.TotalSeconds-lt5){Start-Sleep -Milliseconds 50};$closed=($isExact-and-not[EBR_AUDIO_NATIVE]::Visible($Dialog))
  $afterClose=Get-CandidateHandleCount;$counts=[System.Collections.Generic.List[int]]::new();$watch=[Diagnostics.Stopwatch]::StartNew();$previous=$null;$stableSamples=0
  do{$count=Get-CandidateHandleCount;if($null-ne$count){$counts.Add([int]$count);if($null-ne$previous-and$count-eq$previous){$stableSamples++}else{$stableSamples=0};$previous=$count};if($stableSamples-ge2){break};Start-Sleep -Milliseconds 100}while($watch.Elapsed.TotalSeconds-lt3)
  $baselineMilestone=@($script:audioHandleMilestones|Where-Object{$_.Stage-eq'acceptance baseline after Settings control inspection, before endpoint/audio trials'}|Select-Object -Last 1);$baselineCount=if($baselineMilestone.Count){$baselineMilestone[0].HandleCount}else{$null};$afterIdle=if($counts.Count){$counts[$counts.Count-1]}else{$null};$delta=if($null-ne$baselineCount-and$null-ne$afterIdle){$afterIdle-$baselineCount}else{$null}
  return [pscustomobject]@{ExactDialogVerified=$isExact;DialogHandle=('0x{0:X}'-f$Dialog.ToInt64());DialogClass=$class;DialogTitle=$title;DialogNativeText=$text;DialogOwnerProcessId=$owner;ForegroundHandle=('0x{0:X}'-f$foreground.ToInt64());LastActivePopupHandle=('0x{0:X}'-f$lastPopup.ToInt64());ScreenshotBeforeDismissal=$shot;EnabledOkButtonCount=$buttons.Count;EnabledOkButtonHandle=if($buttons.Count-eq1){'0x{0:X}'-f$buttonHandle.ToInt64()}else{$null};EnabledOkButtonControlId=if($buttons.Count-eq1){[EBR_AUDIO_NATIVE]::ControlId($buttonHandle)}else{$null};ButtonClickReturned=$clickReturned;DialogClosed=$closed;CandidateHandleCountBeforeDismissal=$before;CandidateHandleCountImmediatelyAfterDismissal=$afterClose;CandidateHandleCountsDuringIdle=$counts.ToArray();CandidateHandleCountAfterIdle=$afterIdle;IdleSamplesStable=($stableSamples-ge2);AcceptanceBaselineHandleCount=$baselineCount;HandleDeltaFromAcceptanceBaseline=$delta;OriginalAllowedHandleGrowth=2;WithinOriginalAllowedHandleGrowth=if($null-ne$delta){$delta-le2}else{$null};NoTaskDialogFallbackUsed=$true}
}
function Get-AudioPreview([int]$Sound,[int]$Volume,[bool]$CaptureEnabled,[string]$Tag,[bool]$ToggleAlarmDuringPlayback=$false,[bool]$WaitForNaturalCompletion=$false){
  $stop=Get-AudioControl 117 'Stop preview';if($stop.Enabled){Invoke-AudioClick 117 'Stop preview';$watch=[Diagnostics.Stopwatch]::StartNew();while((Get-AudioControl 117 'Stop preview').Enabled-and$watch.Elapsed.TotalSeconds-lt4){Start-Sleep -Milliseconds 20}}
  if((Get-AudioControl 117 'Stop preview').Enabled){throw 'Stop Preview remained enabled before the next playback.'}
  $recorder=$null;$captureStartError=$null;$sessionMeter=$null;$sessionMeterStartError=$null
  if($CaptureEnabled){$recorder=[EBR_WASAPI+Recorder]::new();$captureStartError=$recorder.Begin(2200);if($captureStartError){$recorder=$null}}
  if($CaptureEnabled){$sessionMeter=[EBR_WASAPI+SessionMeterRecorder]::new();$sessionMeterStartError=$sessionMeter.Begin($script:appPid,2200);if($sessionMeterStartError){$sessionMeter=$null}}
  $candidateHandleCountBeforePreview=Get-CandidateHandleCount
  $script:audioHandleMilestones.Add([pscustomobject]@{Stage="before preview $Tag";HandleCount=$candidateHandleCountBeforePreview;Utc=[DateTime]::UtcNow.ToString('o')})
  $clickUtc=[DateTime]::UtcNow.ToString('o');$click=[EBR_AUDIO_NATIVE]::ClickButtonAsync((Get-AudioControl 116 'Preview alarm').Handle)
  $watch=[Diagnostics.Stopwatch]::StartNew();$started=$false;$dialog=[IntPtr]::Zero;$dialogEvidence=$null;$stopClicked=$false
  $alarmToggleAttempted=$false;$stopEnabledImmediatelyBeforeAlarmToggle=$false;$stopDisabledAfterAlarmToggle=$false;$alarmToggleElapsedMs=$null;$alarmEnabledAfterToggle=$null;$previewElapsedAtAlarmToggleMs=$null;$naturalCompletionObserved=$false;$naturalCompletionElapsedMs=$null
  while($watch.Elapsed.TotalSeconds-lt8-and-not$started-and-not$dialogEvidence){
    $dialog=Get-AudioErrorDialog
    if($dialog-ne[IntPtr]::Zero){$dialogEvidence=Complete-UnavailableDialog $dialog $Tag;break}
    if((Get-AudioControl 117 'Stop preview').Enabled){
      $started=$true
      if($ToggleAlarmDuringPlayback-and-not$alarmToggleAttempted){
        $stopEnabledImmediatelyBeforeAlarmToggle=(Get-AudioControl 117 'Stop preview').Enabled
        if($stopEnabledImmediatelyBeforeAlarmToggle-and(Get-AudioCheck 32 'Alarm enabled')){
          $alarmToggleAttempted=$true;$previewElapsedAtAlarmToggleMs=[Math]::Round($watch.Elapsed.TotalMilliseconds,1);$toggleWatch=[Diagnostics.Stopwatch]::StartNew()
          Set-AudioCheck 32 $false 'Alarm enabled'
          while((Get-AudioControl 117 'Stop preview').Enabled-and$toggleWatch.Elapsed.TotalSeconds-lt1.5){Start-Sleep -Milliseconds 10}
          $stopDisabledAfterAlarmToggle= -not(Get-AudioControl 117 'Stop preview').Enabled
          $alarmToggleElapsedMs=[Math]::Round($toggleWatch.Elapsed.TotalMilliseconds,1)
          $alarmEnabledAfterToggle=Get-AudioCheck 32 'Alarm enabled'
        }
      }
      break
    }
    Start-Sleep -Milliseconds 20
  }
  if($WaitForNaturalCompletion-and$started-and-not$ToggleAlarmDuringPlayback-and-not$dialogEvidence){
    while((Get-AudioControl 117 'Stop preview').Enabled-and$watch.Elapsed.TotalSeconds-lt15){
      $dialog=Get-AudioErrorDialog
      if($dialog-ne[IntPtr]::Zero){$dialogEvidence=Complete-UnavailableDialog $dialog $Tag;break}
      Start-Sleep -Milliseconds 20
    }
    if(-not(Get-AudioControl 117 'Stop preview').Enabled){$naturalCompletionObserved=$true;$naturalCompletionElapsedMs=[Math]::Round($watch.Elapsed.TotalMilliseconds,1)}
  }
  if($recorder){
    while(-not$recorder.IsCompleted-and$watch.Elapsed.TotalSeconds-lt9){
      if(-not$dialogEvidence){$dialog=Get-AudioErrorDialog;if($dialog-ne[IntPtr]::Zero){$dialogEvidence=Complete-UnavailableDialog $dialog $Tag}}
      if((Get-AudioControl 117 'Stop preview').Enabled){$started=$true}
      Start-Sleep -Milliseconds 20
    }
    try{$capture=$recorder.Finish(1000)}catch{$capture=$null;$captureStartError=$_.Exception.Message}
  }else{$capture=$null}
  if($sessionMeter){try{$sessionMeterResult=$sessionMeter.Finish(1000)}catch{$sessionMeterResult=$null;$sessionMeterStartError=$_.Exception.Message}}else{$sessionMeterResult=$null}
  if($click.IsCompleted){try{$click.Wait(1000)}catch{}}
  $stop=Get-AudioControl 117 'Stop preview'
  if($stop.Enabled-and(-not$ToggleAlarmDuringPlayback-or-not$alarmToggleAttempted-or-not$stopDisabledAfterAlarmToggle)){
    Invoke-AudioClick 117 'Stop preview';$stopClicked=$true;$stopWatch=[Diagnostics.Stopwatch]::StartNew();while((Get-AudioControl 117 'Stop preview').Enabled-and$stopWatch.Elapsed.TotalSeconds-lt4){Start-Sleep -Milliseconds 20}
  }
  $stopAfter=(Get-AudioControl 117 'Stop preview').Enabled
  $saved=Read-AudioSettings
  $candidateHandleCountAfterPreview=Get-CandidateHandleCount
  $script:audioHandleMilestones.Add([pscustomobject]@{Stage="after preview $Tag";HandleCount=$candidateHandleCountAfterPreview;Utc=[DateTime]::UtcNow.ToString('o')})
  $wave=Save-LoopbackWave $capture "$Tag-loopback.wav"
  $sampleHash=if($wave){(Get-FileHash -LiteralPath $wave -Algorithm SHA256).Hash.ToLowerInvariant()}else{$null}
  $captureValid=[bool]($capture-and-not$capture.Error-and$capture.Frames-gt0)
  $record=[pscustomobject]@{Tag=$Tag;SoundIndex=$Sound;Volume=$Volume;ClickUtc=$clickUtc;CandidateHandleCountBeforePreview=$candidateHandleCountBeforePreview;CandidateHandleCountAfterPreview=$candidateHandleCountAfterPreview;CandidateHandleDelta=if($null-ne$candidateHandleCountBeforePreview-and$null-ne$candidateHandleCountAfterPreview){$candidateHandleCountAfterPreview-$candidateHandleCountBeforePreview}else{$null};PreviewStartedObserved=$started;UnavailableDialog=$dialogEvidence;StopClicked=$stopClicked;StopEnabledAfter=$stopAfter;NaturalCompletionRequested=$WaitForNaturalCompletion;NaturalCompletionObserved=$naturalCompletionObserved;NaturalCompletionElapsedMs=$naturalCompletionElapsedMs;AlarmToggleAttempted=$alarmToggleAttempted;StopEnabledImmediatelyBeforeAlarmToggle=$stopEnabledImmediatelyBeforeAlarmToggle;StopDisabledAfterAlarmToggle=$stopDisabledAfterAlarmToggle;AlarmToggleElapsedMs=$alarmToggleElapsedMs;PreviewElapsedAtAlarmToggleMs=$previewElapsedAtAlarmToggleMs;AlarmEnabledAfterToggle=$alarmEnabledAfterToggle;SavedSound=$saved.sound;SavedVolume=$saved.volume;LoopbackAvailable=$captureValid;LoopbackStartError=$captureStartError;CandidateSessionMeterStartError=$sessionMeterStartError;CandidateSessionMeter=if($sessionMeterResult){[pscustomobject]@{ProcessId=$sessionMeterResult.ProcessId;EndpointId=$sessionMeterResult.EndpointId;Polls=$sessionMeterResult.Polls;SessionObservedSamples=$sessionMeterResult.SessionObservedSamples;ActiveSamples=$sessionMeterResult.ActiveSamples;MeterSamples=$sessionMeterResult.MeterSamples;NonZeroSamples=$sessionMeterResult.NonZeroSamples;Peak=[Math]::Round($sessionMeterResult.Peak,8);StartedUtc=$sessionMeterResult.StartedUtc;CompletedUtc=$sessionMeterResult.CompletedUtc;Error=$sessionMeterResult.Error}}else{$null};Loopback=if($capture){[pscustomobject]@{EndpointId=$capture.EndpointId;StartedUtc=$capture.StartedUtc;CompletedUtc=$capture.CompletedUtc;Error=$capture.Error;SampleRate=$capture.SampleRate;Channels=$capture.Channels;SourceBitsPerSample=$capture.SourceBitsPerSample;Frames=$capture.Frames;Packets=$capture.Packets;SilentPackets=$capture.SilentPackets;NonZeroSamples=$capture.NonZeroSamples;Rms=[Math]::Round($capture.Rms,8);Peak=[Math]::Round($capture.Peak,8);WaveFile=$wave;WaveSHA256=$sampleHash}}else{$null}}
  $script:captures.Add($record)
  return $record
}
function Invoke-NaturalAlarmTrial {
  $trace=[System.Collections.Generic.List[object]]::new()
  $timerStatus='NOT TESTED';$timerReason='The real one-minute Work interval has not yet reached Break.'
  $acousticStatus='NOT TESTED';$acousticReason='No natural-alarm capture has been evaluated.'
  $timerStartUtc=$null;$timerElapsedSeconds=$null;$initialCountdown=$null;$finalStatusText=$null;$finalCountdownText=$null
  $breakWindow=[IntPtr]::Zero;$breakScreenshot=$null;$timerScreenshot=$null
  $recorder=$null;$sessionMeter=$null;$capture=$null;$meterResult=$null
  $captureStartError=$null;$meterStartError=$null;$captureWave=$null;$captureHash=$null
  $inputFocusTrace=[System.Collections.Generic.List[object]]::new();$pointerFocusEvidence=$null
  $script:naturalAlarmForegroundFailureEvidence=$null
  $alarmErrorDialog=$null;$alarmErrorDialogScreenshot=$null
  $captureStarted=$false;$alarmSettings=$null;$skipResult=$null
  $endpointMutedOrZero=($script:endpoint-and($script:endpoint.DefaultMuted-or$script:endpoint.DefaultMasterVolume-le0.001))

  try {
    Set-AudioSound 0
    Set-AudioVolume 100
    Set-AudioCheck 32 $true 'Alarm enabled'
    Set-AudioCheck 107 $false 'Repeat alarm'
    Invoke-AudioClick 12 'Settings navigation'
    Invoke-AudioClick 130 'Intervals settings section'
    $workControl=Get-AudioControl 100 'Work interval'
    if($workControl.Class-ne'Edit'){throw 'NOT TESTED: the real Work interval control is not an editable field.'}
    $pointerFocusEvidence=Focus-NaturalWorkEditWithPointer $workControl
    $inputFocusTrace.Add($pointerFocusEvidence.FocusVerification)
    $inputFocusTrace.Add((Assert-NaturalWorkEditFocus $workControl.Handle 'immediately before Ctrl+A'))
    [System.Windows.Forms.SendKeys]::SendWait('^a')
    $inputFocusTrace.Add((Assert-NaturalWorkEditFocus $workControl.Handle 'after Ctrl+A and immediately before typing 1'))
    [System.Windows.Forms.SendKeys]::SendWait('1')
    $inputFocusTrace.Add((Assert-NaturalWorkEditFocus $workControl.Handle 'after typing 1 and immediately before Tab commit'))
    [System.Windows.Forms.SendKeys]::SendWait('{TAB}')
    Start-Sleep -Milliseconds 100
    $committedWorkControl=Get-AudioControl 100 'Work interval'
    if($committedWorkControl.Text-cne'1'){throw "NOT TESTED: keyboard input did not leave the candidate Work interval field at '1' (found '$($committedWorkControl.Text)')."}
    Invoke-AudioClick 10 'Timer navigation'
    if(-not(Wait-AudioSetting 'workMinutes' '1')){throw 'NOT TESTED: the candidate did not persist the real one-minute Work interval edit.'}
    $alarmSettings=Read-AudioSettings
    if([string]$alarmSettings['alarm']-cne'1'-or[string]$alarmSettings['sound']-cne'0'-or[string]$alarmSettings['volume']-cne'100'-or[string]$alarmSettings['repeat']-cne'0'){
      throw 'NOT TESTED: the persisted alarm settings do not match enabled Gentle, volume 100, repeat off.'
    }
    $resetUtc=[DateTime]::UtcNow
    Invoke-AudioClick 21 'Reset timer'
    $timerStartUtc=$resetUtc.ToString('o')
    $initialStatus=Get-AudioControl 41 'Timer status'
    $initialCountdown=Get-AudioControl 40 'Timer countdown'
    $initialStatusText=[string]$initialStatus.Text
    $initialCountdownText=[string]$initialCountdown.Text
    if($initialStatusText-notmatch'(?i)running'-or$initialCountdownText-notmatch'^\s*(?:01:00|00:5[0-9])\s*$'){
      throw "NOT TESTED: Reset did not start a natural one-minute Running timer (status='$initialStatusText', countdown='$initialCountdownText')."
    }
    $timerScreenshot=Save-WindowScreenshot $script:mainWindow 'natural-alarm-one-minute-running-timer.png'
    Add-AudioEvent 'Reset the real candidate timer to its validated one-minute minimum' 'PASS' ([pscustomobject]@{WorkMinutes=[string]$alarmSettings['workMinutes'];StatusText=$initialStatusText;CountdownText=$initialCountdownText;ResetUtc=$timerStartUtc;TimerScreenshot=$timerScreenshot;Sound=[string]$alarmSettings['sound'];Volume=[string]$alarmSettings['volume'];AlarmEnabled=[string]$alarmSettings['alarm'];Repeat=[string]$alarmSettings['repeat'];NoClockOrTimerSimulation=$true})

    $timerWatch=[Diagnostics.Stopwatch]::StartNew();$captureWatch=$null;$lastTraceSecond=-1
    while($timerWatch.Elapsed.TotalSeconds-lt85-and$breakWindow-eq[IntPtr]::Zero){
      $statusControl=Get-AudioControl 41 'Timer status'
      $countdownControl=Get-AudioControl 40 'Timer countdown'
      $finalStatusText=[string]$statusControl.Text;$finalCountdownText=[string]$countdownControl.Text
      $remainingSeconds=$null
      if($finalCountdownText-match'^\s*(\d{2}):(\d{2})\s*$'){$remainingSeconds=([int]$Matches[1]*60)+[int]$Matches[2]}
      $wholeSecond=[int][Math]::Floor($timerWatch.Elapsed.TotalSeconds)
      if($wholeSecond-ne$lastTraceSecond){
        $trace.Add([pscustomobject]@{ElapsedSeconds=$wholeSecond;Utc=[DateTime]::UtcNow.ToString('o');StatusText=$finalStatusText;CountdownText=$finalCountdownText;RemainingSeconds=$remainingSeconds})
        $lastTraceSecond=$wholeSecond
      }
      if(-not$captureStarted-and$null-ne$remainingSeconds-and$remainingSeconds-le25-and$remainingSeconds-gt0){
        $captureStarted=$true;$captureWatch=[Diagnostics.Stopwatch]::StartNew()
        if($script:wasapiAvailable-and$script:baseline-and$script:baseline.EndpointId){
          $recorder=[EBR_WASAPI+Recorder]::new();$captureStartError=$recorder.Begin(30000)
          $sessionMeter=[EBR_WASAPI+SessionMeterRecorder]::new();$meterStartError=$sessionMeter.Begin($script:appPid,30000)
          Add-AudioEvent 'Arm same-endpoint WASAPI loopback and exact-candidate session-meter capture before the natural alarm deadline' $(if(-not$captureStartError-and-not$meterStartError){'PASS'}else{'NOT TESTED'}) ([pscustomobject]@{RecorderStartError=$captureStartError;SessionMeterStartError=$meterStartError;CandidatePid=$script:appPid;EndpointId=$script:baseline.EndpointId;CaptureDurationMs=30000;CountdownText=$finalCountdownText;RemainingSeconds=$remainingSeconds})
        }else{
          $script:acousticCoverageMissing=$true
          Add-AudioEvent 'Natural alarm audio endpoint and loopback capture are available' 'NOT TESTED' ([pscustomobject]@{Endpoint=$script:endpoint;BaselineEndpointId=if($script:baseline){$script:baseline.EndpointId}else{$null};BaselineLoopbackAvailable=$script:wasapiAvailable;Reason='No functioning same-endpoint WASAPI baseline is available; the genuine timer transition will still be observed.'})
        }
      }

      $dialog=Get-AudioErrorDialog
      if($dialog-ne[IntPtr]::Zero){
        $alarmErrorDialog=[pscustomobject]@{Handle=('0x{0:X}'-f$dialog.ToInt64());Class=[EBR_AUDIO_NATIVE]::ClassName($dialog);OwnerProcessId=[EBR_AUDIO_NATIVE]::OwnerPid($dialog);Text=(Get-AudioWindowNativeText $dialog)}
        $alarmErrorDialogScreenshot=Save-WindowScreenshot $dialog 'natural-alarm-output-error-dialog.png'
        $closed=Complete-UnavailableDialog $dialog 'natural-alarm-output-error-dialog'
        $alarmErrorDialog|Add-Member -NotePropertyName CloseResult -NotePropertyValue $closed -Force
        $dialogAudioFailure=($script:wasapiAvailable-and-not$endpointMutedOrZero)
        Add-AudioEvent 'Observe the candidate alarm output result at the real timer deadline' $(if($dialogAudioFailure){'FAIL'}else{'NOT TESTED'}) ([pscustomobject]@{Dialog=$alarmErrorDialog;Screenshot=$alarmErrorDialogScreenshot;NoEndpointAvailable=(-not$script:wasapiAvailable);EndpointMutedOrZero=$endpointMutedOrZero;CloseResult=$closed})
        if($dialogAudioFailure){$acousticStatus='FAIL';$acousticReason='The exact candidate showed its alarm playback failure dialog despite an available unmuted WASAPI endpoint.';$script:acousticFailure=$true}
        elseif($endpointMutedOrZero){$acousticStatus='NOT TESTED';$acousticReason='The candidate alarm error dialog appeared, but the default endpoint was muted or its master volume was effectively zero; this environment cannot establish audible output.'}
        else{$acousticReason='No WASAPI endpoint was available; the candidate alarm error was captured and acknowledged in the disposable runner, so audible output remains unverified.'}
        if(-not$closed.Closed){throw 'NOT TESTED: the exact candidate alarm-output dialog could not be closed safely.'}
      }

      foreach($candidateWindow in [EBR_AUDIO_NATIVE]::TopWindowsForProcess($script:appPid)){
        if([EBR_AUDIO_NATIVE]::ClassName($candidateWindow)-ceq'EyeBreakReminder.Break'){$breakWindow=$candidateWindow;break}
      }
      if($breakWindow-ne[IntPtr]::Zero){break}
      Start-Sleep -Milliseconds 100
    }

    $timerElapsedSeconds=[Math]::Round($timerWatch.Elapsed.TotalSeconds,2)
    if($breakWindow-eq[IntPtr]::Zero){
      if($recorder){try{$capture=$recorder.Finish(40000)}catch{$captureStartError=if($captureStartError){$captureStartError+'; '+$_.Exception.Message}else{$_.Exception.Message}}}
      if($sessionMeter){try{$meterResult=$sessionMeter.Finish(40000)}catch{$meterStartError=if($meterStartError){$meterStartError+'; '+$_.Exception.Message}else{$_.Exception.Message}}}
      if($capture){$captureWave=Save-LoopbackWave $capture 'natural-work-break-alarm-loopback.wav';if($captureWave){$captureHash=(Get-FileHash -LiteralPath $captureWave -Algorithm SHA256).Hash.ToLowerInvariant()}}
      $lastStatus=Get-AudioControl 41 'Timer status';$lastCountdown=Get-AudioControl 40 'Timer countdown'
      $finalStatusText=[string]$lastStatus.Text;$finalCountdownText=[string]$lastCountdown.Text
      $timerReason="No visible candidate-owned Break window appeared within 85 seconds after Reset (status='$finalStatusText', countdown='$finalCountdownText')."
      $timerStatus='FAIL'
      Test-AudioRequire $false 'The real one-minute Work timer naturally reaches its candidate-owned Break window' ([pscustomobject]@{ResetUtc=$timerStartUtc;ElapsedSeconds=$timerElapsedSeconds;FinalStatus=$finalStatusText;FinalCountdown=$finalCountdownText;Trace=$trace.ToArray()})|Out-Null
    }else{
      $breakStatusControl=Get-AudioControl 41 'Timer status';$breakCountdownControl=Get-AudioControl 40 'Timer countdown'
      $finalStatusText=[string]$breakStatusControl.Text;$finalCountdownText=[string]$breakCountdownControl.Text
      $dueInRange=($timerElapsedSeconds-ge50-and$timerElapsedSeconds-le85)
      $timerTransition=($dueInRange-and$finalStatusText-match'(?i)break'-and[EBR_AUDIO_NATIVE]::OwnerPid($breakWindow)-eq$script:appPid)
      $timerStatus=if($timerTransition){'PASS'}else{'FAIL'}
      $timerReason=if($timerTransition){'The one-minute Work timer naturally transitioned to Break and created a visible top-level break window owned by the exact candidate process.'}else{'The timer transition or candidate-owned Break window did not satisfy the expected natural one-minute timing/state checks.'}
      $breakScreenshot=Save-WindowScreenshot $breakWindow 'natural-work-to-break-alarm-window.png'
      Add-AudioEvent 'The real one-minute Work timer naturally reaches a candidate-owned Break window' $(if($timerTransition){'PASS'}else{'FAIL'}) ([pscustomobject]@{ResetUtc=$timerStartUtc;ElapsedSeconds=$timerElapsedSeconds;ExpectedElapsedSeconds=@(50,85);InitialCountdown=$initialCountdownText;FinalStatus=$finalStatusText;FinalCountdown=$finalCountdownText;BreakWindow=[pscustomobject]@{Handle=('0x{0:X}'-f$breakWindow.ToInt64());Class=[EBR_AUDIO_NATIVE]::ClassName($breakWindow);OwnerProcessId=[EBR_AUDIO_NATIVE]::OwnerPid($breakWindow);Title=[EBR_AUDIO_NATIVE]::Text($breakWindow)};BreakScreenshot=$breakScreenshot;Trace=$trace.ToArray()})
      if(-not$timerTransition){$script:controlFailure=$true}

      if($recorder){try{$capture=$recorder.Finish(40000)}catch{$captureStartError=if($captureStartError){$captureStartError+'; '+$_.Exception.Message}else{$_.Exception.Message}}}
      if($sessionMeter){try{$meterResult=$sessionMeter.Finish(40000)}catch{$meterStartError=if($meterStartError){$meterStartError+'; '+$_.Exception.Message}else{$_.Exception.Message}}}
      if($capture){$captureWave=Save-LoopbackWave $capture 'natural-work-break-alarm-loopback.wav';if($captureWave){$captureHash=(Get-FileHash -LiteralPath $captureWave -Algorithm SHA256).Hash.ToLowerInvariant()}}

      $meterSignal=($meterResult-and$meterResult.ProcessId-eq$script:appPid-and$meterResult.EndpointId-ceq$script:baseline.EndpointId-and$meterResult.ActiveSamples-gt0-and$meterResult.NonZeroSamples-gt0-and$meterResult.Peak-gt0.0001-and-not$meterResult.Error)
      $loopbackSignal=($capture-and-not$capture.Error-and$capture.Frames-gt0-and$capture.NonZeroSamples-gt100-and$capture.Peak-gt0.003-and$capture.EndpointId-ceq$script:baseline.EndpointId)
      $endpointSame=($capture-and$meterResult-and$capture.EndpointId-ceq$script:baseline.EndpointId-and$meterResult.EndpointId-ceq$script:baseline.EndpointId)
      $acousticCaptureErrors=($captureStartError-or$meterStartError-or-not$capture-or-not$meterResult-or$capture.Error-or$meterResult.Error)
      if(-not$script:wasapiAvailable-or-not$script:baseline-or-not$script:baseline.EndpointId){
        $script:acousticCoverageMissing=$true;$acousticStatus='NOT TESTED'
        if(-not$alarmErrorDialog){$acousticReason='The natural timer and Break window were observed, but no functioning WASAPI loopback endpoint existed for same-endpoint alarm evidence.'}
        Add-AudioEvent 'Natural candidate alarm produces same-endpoint render and candidate-PID samples' 'NOT TESTED' ([pscustomobject]@{Reason=$acousticReason;Endpoint=$script:endpoint;Capture=$capture;SessionMeter=$meterResult;AlarmErrorDialog=$alarmErrorDialog})
      }elseif($endpointMutedOrZero){
        $script:acousticCoverageMissing=$true;$acousticStatus='NOT TESTED';$acousticReason='A WASAPI endpoint exists, but it was muted or its master volume was effectively zero; natural-alarm audibility cannot be evaluated in this environment.'
        Add-AudioEvent 'Natural candidate alarm acoustic evidence is available from an unmuted, nonzero-master endpoint' 'NOT TESTED' ([pscustomobject]@{Reason=$acousticReason;DefaultEndpointId=$script:endpoint.DefaultEndpointId;DefaultMuted=$script:endpoint.DefaultMuted;DefaultMasterVolume=$script:endpoint.DefaultMasterVolume;Capture=$capture;SessionMeter=$meterResult;AlarmErrorDialog=$alarmErrorDialog;TimerTransitionStatus=$timerStatus})
      }elseif($acousticCaptureErrors){
        $script:acousticCoverageMissing=$true
        if($acousticStatus-ne'FAIL'){$acousticStatus='NOT TESTED';$acousticReason='The natural alarm capture or exact-candidate session meter could not complete; acoustic behavior remains unverified.'}
        Add-AudioEvent 'Natural candidate alarm produces same-endpoint render and candidate-PID samples' $acousticStatus ([pscustomobject]@{Reason=$acousticReason;CaptureStartError=$captureStartError;SessionMeterStartError=$meterStartError;Capture=$capture;SessionMeter=$meterResult;AlarmErrorDialog=$alarmErrorDialog})
      }else{
        $acousticPass=($timerTransition-and-not$alarmErrorDialog-and$endpointSame-and$loopbackSignal-and$meterSignal)
        $acousticStatus=if($acousticPass){'PASS'}else{'FAIL'}
        $acousticReason=if($acousticPass){'The natural timer alarm produced nonzero WASAPI render samples and nonzero audio-session meter samples attributed to the exact candidate PID on the baseline endpoint.'}else{'The natural timer alarm lacked valid same-endpoint nonzero render samples or an exact-candidate PID session-meter signal.'}
        Test-AudioAcousticRequire $acousticPass 'Natural timer alarm produces same-endpoint WASAPI output and exact-candidate PID session-meter samples' ([pscustomobject]@{TimerTransition=$timerTransition;EndpointId=$script:baseline.EndpointId;Loopback=[pscustomobject]@{EndpointId=$capture.EndpointId;Frames=$capture.Frames;Packets=$capture.Packets;NonZeroSamples=$capture.NonZeroSamples;Rms=[Math]::Round($capture.Rms,8);Peak=[Math]::Round($capture.Peak,8);WaveFile=$captureWave;WaveSHA256=$captureHash;Error=$capture.Error};CandidateSessionMeter=[pscustomobject]@{ProcessId=$meterResult.ProcessId;EndpointId=$meterResult.EndpointId;ActiveSamples=$meterResult.ActiveSamples;MeterSamples=$meterResult.MeterSamples;NonZeroSamples=$meterResult.NonZeroSamples;Peak=[Math]::Round($meterResult.Peak,8);Error=$meterResult.Error};AlarmErrorDialog=$alarmErrorDialog;Thresholds=[pscustomobject]@{MinimumLoopbackNonZeroSamples=101;MinimumLoopbackPeak=0.003;MinimumCandidateMeterPeak=0.0001}})|Out-Null
      }
    }

    if($breakWindow-ne[IntPtr]::Zero-and[EBR_AUDIO_NATIVE]::Visible($breakWindow)){
      $skipButtons=@(foreach($button in [EBR_AUDIO_NATIVE]::ChildWindows($breakWindow)){if([EBR_AUDIO_NATIVE]::OwnerPid($button)-eq$script:appPid-and[EBR_AUDIO_NATIVE]::ControlId($button)-eq24-and[EBR_AUDIO_NATIVE]::Visible($button)-and[EBR_AUDIO_NATIVE]::Enabled($button)){$button}})
      if($skipButtons.Count-eq1){$clickResult=[IntPtr]::Zero;$skipClicked=[EBR_AUDIO_NATIVE]::SendBounded($skipButtons[0],0x00F5,[IntPtr]::Zero,[IntPtr]::Zero,5000,[ref]$clickResult);$skipWatch=[Diagnostics.Stopwatch]::StartNew();while([EBR_AUDIO_NATIVE]::Visible($breakWindow)-and$skipWatch.Elapsed.TotalSeconds-lt5){Start-Sleep -Milliseconds 50};$skipResult=[pscustomobject]@{UniqueSkipButton=$true;Clicked=$skipClicked;BreakWindowClosed=(-not[EBR_AUDIO_NATIVE]::Visible($breakWindow));Action='Skip (ID 24); do not invoke completed-break alarm.'}}
      else{$skipResult=[pscustomobject]@{UniqueSkipButton=$false;Clicked=$false;BreakWindowClosed=$false;ObservedSkipButtonCount=$skipButtons.Count;Action='No ambiguous break control was clicked.'}}
      Add-AudioEvent 'Skip the captured Break without invoking the completed-break alarm' $(if($skipResult.Clicked-and$skipResult.BreakWindowClosed){'PASS'}else{'NOT TESTED'}) $skipResult
      if(-not$skipResult.Clicked-or-not$skipResult.BreakWindowClosed){$script:acousticCoverageMissing=$true}
    }
  } catch {
    if($_.Exception.Message-match'^PRODUCT DEFECT:'){$timerStatus='FAIL';$timerReason=$_.Exception.Message;$script:controlFailure=$true}
    elseif($_.Exception.Message-match'^(BLOCKED|NOT TESTED):'){$timerStatus='NOT TESTED';$timerReason=$_.Exception.Message}
    else{$timerStatus='NOT TESTED';$timerReason=$_.Exception.Message}
    $script:acousticCoverageMissing=$true
    Add-AudioEvent 'Natural one-minute Work-to-Break alarm trial' $timerStatus ([pscustomobject]@{Reason=$timerReason;ResetUtc=$timerStartUtc;InitialCountdown=$initialCountdown;FinalStatus=$finalStatusText;FinalCountdown=$finalCountdownText;Trace=$trace.ToArray();InputFocusEvidence=$pointerFocusEvidence;InputFocusTrace=$inputFocusTrace.ToArray();ForegroundFailureEvidence=$script:naturalAlarmForegroundFailureEvidence;CaptureStartError=$captureStartError;SessionMeterStartError=$meterStartError})
  }
  $overallTrialStatus=if($timerStatus-eq'FAIL'-or$acousticStatus-eq'FAIL'){'FAIL'}elseif($timerStatus-eq'PASS'-and$acousticStatus-eq'PASS'-and$skipResult-and$skipResult.Clicked-and$skipResult.BreakWindowClosed){'PASS'}else{'BLOCKED'}
  return [pscustomobject]@{Status=$overallTrialStatus;TimerTransitionStatus=$timerStatus;TimerReason=$timerReason;ResetUtc=$timerStartUtc;ElapsedSeconds=$timerElapsedSeconds;InitialCountdown=$initialCountdown;FinalStatusText=$finalStatusText;FinalCountdownText=$finalCountdownText;CountdownTrace=$trace.ToArray();InputFocusEvidence=$pointerFocusEvidence;InputFocusTrace=$inputFocusTrace.ToArray();ForegroundFailureEvidence=$script:naturalAlarmForegroundFailureEvidence;BreakWindow=if($breakWindow-ne[IntPtr]::Zero){[pscustomobject]@{Handle=('0x{0:X}'-f$breakWindow.ToInt64());Class=[EBR_AUDIO_NATIVE]::ClassName($breakWindow);OwnerProcessId=[EBR_AUDIO_NATIVE]::OwnerPid($breakWindow);Title=[EBR_AUDIO_NATIVE]::Text($breakWindow);Screenshot=$breakScreenshot}}else{$null};TimerScreenshot=$timerScreenshot;AcousticStatus=$acousticStatus;AcousticReason=$acousticReason;Loopback=if($capture){[pscustomobject]@{EndpointId=$capture.EndpointId;StartedUtc=$capture.StartedUtc;CompletedUtc=$capture.CompletedUtc;Frames=$capture.Frames;Packets=$capture.Packets;NonZeroSamples=$capture.NonZeroSamples;Rms=[Math]::Round($capture.Rms,8);Peak=[Math]::Round($capture.Peak,8);Error=$capture.Error;WaveFile=$captureWave;WaveSHA256=$captureHash}}else{$null};CandidateSessionMeter=if($meterResult){[pscustomobject]@{ProcessId=$meterResult.ProcessId;EndpointId=$meterResult.EndpointId;Polls=$meterResult.Polls;ActiveSamples=$meterResult.ActiveSamples;MeterSamples=$meterResult.MeterSamples;NonZeroSamples=$meterResult.NonZeroSamples;Peak=[Math]::Round($meterResult.Peak,8);Error=$meterResult.Error}}else{$null};CaptureStartError=$captureStartError;SessionMeterStartError=$meterStartError;AlarmErrorDialog=$alarmErrorDialog;AlarmErrorDialogScreenshot=$alarmErrorDialogScreenshot;AlarmSettings=$alarmSettings;SkipResult=$skipResult;Reason=if($overallTrialStatus-eq'PASS'){'A natural one-minute Work timer reached Break, and the actual candidate alarm produced same-endpoint render and candidate-PID session-meter evidence; the break was skipped to avoid a completion alarm.'}else{$timerReason+' '+$acousticReason}}
}

$script:evidenceRoot=[IO.Path]::GetFullPath($EvidenceDirectory)
try{
  $script:ExecutablePath=[IO.Path]::GetFullPath($ExecutablePath)
  [void][IO.Directory]::CreateDirectory($script:evidenceRoot)
  $os=Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
  $osArch=[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString();$procArch=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
  $sessionName=[string]$env:SESSIONNAME
  $testSessionId=[Diagnostics.Process]::GetCurrentProcess().SessionId
  $testUser=[Security.Principal.WindowsIdentity]::GetCurrent().Name
  $nativeProcessorCodes=@()
  $commonGitHubGate=($env:GITHUB_ACTIONS -ceq 'true' -and $env:RUNNER_ENVIRONMENT -ceq 'github-hosted' -and $env:RUNNER_OS -ceq 'Windows' -and $env:GITHUB_SERVER_URL -ceq 'https://github.com' -and $env:GITHUB_REPOSITORY -ieq 'REMEDIOSSAMUEL/EYE-BREAK-REMINDER' -and [bool]$env:RUNNER_NAME -and [Environment]::UserInteractive)
  if($ServerConsoleSession-and$commonGitHubGate-and$env:RUNNER_ARCH -ieq'X64'-and$os.Caption -match'Windows Server 2025'-and$osArch -ieq'X64'-and$procArch -ieq'X64'){$nativeProcessorCodes=@(Get-CimInstance Win32_Processor -ErrorAction Stop|Select-Object -ExpandProperty Architecture -Unique)}
  $arm64Context=(-not$ServerConsoleSession-and$commonGitHubGate -and $env:RUNNER_ARCH -ieq 'ARM64' -and $os.Caption -match 'Windows 11' -and $os.Caption -notmatch 'Server' -and $osArch -ieq 'Arm64' -and $procArch -ieq 'Arm64')
  $server2025RdpContext=(-not$ServerConsoleSession-and$commonGitHubGate -and $env:RUNNER_ARCH -ieq 'X64' -and $os.Caption -match 'Windows Server 2025' -and $osArch -ieq 'X64' -and $procArch -ieq 'X64' -and $sessionName -match '^RDP-Tcp#\d+$')
  $server2025ConsoleContext=($ServerConsoleSession-and$commonGitHubGate-and$env:RUNNER_ARCH -ieq 'X64'-and$os.Caption -match 'Windows Server 2025'-and$osArch -ieq 'X64'-and$procArch -ieq 'X64'-and 9 -in $nativeProcessorCodes)
  if($arm64Context){$runnerFlavor='Windows11Arm64';$candidateExecution='x64 emulation on native Windows 11 ARM64';$environmentDescription='Fresh GitHub-hosted interactive Windows 11 ARM64 runner'}
  elseif($server2025RdpContext){$runnerFlavor='Server2025RdpX64';$candidateExecution='native AMD64 x64 on Windows Server 2025 x64';$environmentDescription='Fresh GitHub-hosted Windows Server 2025 x64 runner in interactive localhost RDP session '+$sessionName}
  elseif($server2025ConsoleContext){$runnerFlavor='Server2025ConsoleX64';$candidateExecution='native AMD64 x64 on Windows Server 2025 x64';$environmentDescription='Fresh GitHub-hosted Windows Server 2025 x64 active Console session (native AMD64)'}
  else{
    $overallStatus='BLOCKED'
    $overallReason='Runner environment gates were not met; no application was launched.'
    Add-AudioEvent 'Runner must match a supported isolated audio-test context' 'BLOCKED' ([pscustomobject]@{GitHubActions=$env:GITHUB_ACTIONS;RunnerEnvironment=$env:RUNNER_ENVIRONMENT;RunnerOS=$env:RUNNER_OS;RunnerArchitecture=$env:RUNNER_ARCH;RunnerName=$env:RUNNER_NAME;Repository=$env:GITHUB_REPOSITORY;OS=$os.Caption;Version=$os.Version;Build=$os.BuildNumber;OSArchitecture=$osArch;ProcessArchitecture=$procArch;NativeProcessorArchitectureCodes=$nativeProcessorCodes;SessionName=$sessionName;UserInteractive=[Environment]::UserInteractive;Windows11Arm64Context=$arm64Context;WindowsServer2025RdpX64Context=$server2025RdpContext;WindowsServer2025ConsoleRequested=[bool]$ServerConsoleSession;WindowsServer2025ConsoleX64Context=$server2025ConsoleContext;RequiredContexts=@('GitHub-hosted interactive Windows 11 ARM64 x64-emulation runner','GitHub-hosted Windows Server 2025 x64 interactive localhost RDP session','GitHub-hosted Windows Server 2025 x64 active WTS Console session with native AMD64 code 9')})
    throw 'Audio acceptance environment gate failed.'
  }
  if($server2025RdpContext){
    if($ExpectedSessionId-le0-or$ExpectedSessionName-notmatch'(?i)^rdp-tcp#\d+$'-or[string]::IsNullOrWhiteSpace($ExpectedUser)){Add-AudioEvent 'Audio probe receives the exact controller-validated Server RDP identity' 'BLOCKED' 'Expected session ID, RDP session name, and temporary user are mandatory in Server RDP mode.';throw 'Audio acceptance Server RDP identity inputs are incomplete.'}
    $isAdministrator=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $identityMatches=($testSessionId-eq$ExpectedSessionId-and$sessionName-ieq$ExpectedSessionName-and$testUser-ieq$ExpectedUser-and-not$isAdministrator)
    Add-AudioEvent 'Audio probe runs as the expected temporary standard user in the controller-validated RDP session' $(if($identityMatches){'PASS'}else{'BLOCKED'}) ([pscustomobject]@{ProcessSessionId=$testSessionId;ExpectedSessionId=$ExpectedSessionId;SessionName=$sessionName;ExpectedSessionName=$ExpectedSessionName;User=$testUser;ExpectedUser=$ExpectedUser;IsAdministrator=$isAdministrator;UserInteractive=[Environment]::UserInteractive})
    if(-not$identityMatches){throw 'Audio acceptance probe identity does not match the expected temporary standard-user RDP session.'}
  }elseif($server2025ConsoleContext){
    if($ExpectedSessionId-le0-or$ExpectedSessionName-ine'Console'-or[string]::IsNullOrWhiteSpace($ExpectedUser)){Add-AudioEvent 'Audio probe receives the exact controller-validated Server Console identity' 'BLOCKED' 'Expected session ID, the exact Console station name, and temporary standard-user identity are mandatory.';throw 'Audio acceptance Server Console identity inputs are incomplete.'}
    Add-Type -TypeDefinition $nativeSource -ErrorAction Stop;$nativeTypeLoaded=$true
    $isAdministrator=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $identityMatches=($testSessionId-eq$ExpectedSessionId-and$testUser-ieq$ExpectedUser-and-not$isAdministrator)
    $rawSessionNameMatches=($sessionName-eq''-or$sessionName-ieq'Console')
    $activeConsoleId=[EBR_AUDIO_NATIVE]::WTSGetActiveConsoleSessionId()
    $wtsRows=@([EBR_AUDIO_NATIVE]::EnumerateWtsSessions())
    $consoleRows=@($wtsRows|Where-Object{$_.SessionId-eq$ExpectedSessionId-and$_.Station-ieq'Console'})
    $activeConsoleMatches=($activeConsoleId-eq$ExpectedSessionId-and$testSessionId-eq$ExpectedSessionId-and$consoleRows.Count-eq1-and$consoleRows[0].State-eq0)
    $processWindowStation=[EBR_AUDIO_NATIVE]::ProcessWindowStationName()
    $threadDesktop=[EBR_AUDIO_NATIVE]::ThreadDesktopName()
    $inputDesktop=[EBR_AUDIO_NATIVE]::InputDesktopName()
    $desktopMatches=($processWindowStation-ceq'WinSta0'-and$threadDesktop-ceq'Default'-and$inputDesktop-ceq'Default')
    $explorerProcesses=@(Get-Process -Name explorer -ErrorAction SilentlyContinue|Where-Object{$_.SessionId-eq$ExpectedSessionId}|Select-Object Id,SessionId,ProcessName)
    $taskbar=[EBR_AUDIO_NATIVE]::TaskbarWindow();$taskbarPid=[EBR_AUDIO_NATIVE]::TaskbarProcessId($taskbar)
    $taskbarProcess=if($taskbarPid-gt0){Get-Process -Id $taskbarPid -ErrorAction SilentlyContinue}else{$null}
    $taskbarOwnerIsExplorer=($taskbarProcess-and$taskbarProcess.ProcessName-ieq'explorer')
    $shellMatches=($taskbar-ne[IntPtr]::Zero-and$taskbarOwnerIsExplorer-and$taskbarProcess.SessionId-eq$ExpectedSessionId-and$explorerProcesses.Count-gt0)
    $consoleDesktopRecord=[pscustomobject]@{RunnerContext='GitHub-hosted Windows Server 2025 x64';OS=$os.Caption;Version=$os.Version;Build=$os.BuildNumber;OSArchitecture=$osArch;ProcessArchitecture=$procArch;NativeProcessorArchitectureCodes=$nativeProcessorCodes;ExpectedSessionId=$ExpectedSessionId;ProcessSessionId=$testSessionId;ActiveConsoleSessionId=$activeConsoleId;WtsSessions=$wtsRows;MatchingConsoleSessions=$consoleRows;ExpectedSessionName=$ExpectedSessionName;RawSessionName=$sessionName;RawSessionNameAccepted=$rawSessionNameMatches;ExpectedUser=$ExpectedUser;CurrentUser=$testUser;IsAdministrator=$isAdministrator;UserInteractive=[Environment]::UserInteractive;ProcessWindowStation=$processWindowStation;ThreadDesktop=$threadDesktop;InputDesktop=$inputDesktop;ExplorerProcesses=$explorerProcesses;TaskbarHandle=if($taskbar-ne[IntPtr]::Zero){'0x{0:X}'-f$taskbar.ToInt64()}else{$null};TaskbarProcessId=$taskbarPid;TaskbarProcessName=if($taskbarProcess){$taskbarProcess.ProcessName}else{$null};TaskbarProcessSessionId=if($taskbarProcess){$taskbarProcess.SessionId}else{$null};Checks=[pscustomobject]@{Identity=$identityMatches;RawSessionName=$rawSessionNameMatches;ActiveConsoleSession=$activeConsoleMatches;Desktop=$desktopMatches;TaskbarOwnedByExplorer=$taskbarOwnerIsExplorer;Shell=$shellMatches}}
    $consoleSessionValid=($identityMatches-and$rawSessionNameMatches-and$activeConsoleMatches-and$desktopMatches-and$shellMatches-and[Environment]::UserInteractive)
    Add-AudioEvent 'Server Console process has verified active WTS Console, standard-user identity, WinSta0/Default desktop, and same-session Explorer/taskbar' $(if($consoleSessionValid){'PASS'}else{'BLOCKED'}) $consoleDesktopRecord
    if(-not$consoleSessionValid){throw 'Audio acceptance Server Console proof failed; candidate not launched.'}
  }elseif($ExpectedSessionId-ne-1-or$ExpectedSessionName-or$ExpectedUser){Add-AudioEvent 'Windows 11 ARM64 audio probe does not accept Server session identity overrides' 'BLOCKED' 'Server-session identity arguments were supplied outside Server RDP/Console mode.';throw 'Audio acceptance identity arguments conflict with the Windows 11 ARM64 path.'}
  if(-not(Test-Path -LiteralPath $script:ExecutablePath -PathType Leaf)){Add-AudioEvent 'Exact production candidate executable is available' 'BLOCKED' $script:ExecutablePath;throw 'Exact production executable is missing.'}
  $actualHash=(Get-FileHash -LiteralPath $script:ExecutablePath -Algorithm SHA256).Hash.ToLowerInvariant()
  if($actualHash-cne$expectedSha256){Add-AudioEvent 'Exact production candidate SHA-256 matches artifact 14695418078' 'BLOCKED' ([pscustomobject]@{Expected=$expectedSha256;Actual=$actualHash});throw 'Candidate hash does not match the authoritative production candidate.'}
  $reader=[IO.BinaryReader]::new([IO.File]::Open($script:ExecutablePath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read))
  try{$reader.BaseStream.Position=0x3c;$pe=$reader.ReadInt32();if($pe-lt0-or$pe-gt$reader.BaseStream.Length-6){throw 'Candidate PE header offset is invalid.'};$reader.BaseStream.Position=$pe;if($reader.ReadUInt32()-ne0x00004550){throw 'Candidate executable lacks the PE signature.'};$machine=$reader.ReadUInt16()}finally{$reader.Dispose()}
  $file=Get-Item -LiteralPath $script:ExecutablePath;$version=[string]$file.VersionInfo.ProductVersion
  if($machine-ne0x8664-or$version-notmatch'^1\.4\.0(\.0)?$'){Add-AudioEvent 'Exact candidate is the signed release x64 version 1.4.0 payload' 'BLOCKED' ([pscustomobject]@{ArtifactId=$expectedArtifactId;PEMachine=('0x{0:X4}'-f$machine);ProductVersion=$version;SHA256=$actualHash});throw 'Candidate PE architecture or version does not match the acceptance identity.'}
  $script:appDataPath=Join-Path $env:LOCALAPPDATA 'EyeBreakReminder';$script:appDataExistedBefore=Test-Path -LiteralPath $script:appDataPath
  if($script:appDataExistedBefore){Add-AudioEvent 'Runner profile is fresh for Eye Break Reminder data' 'BLOCKED' ([pscustomobject]@{AppDataPath=$script:appDataPath;AlreadyExisted=$true});throw 'The disposable runner profile already contains Eye Break Reminder data; candidate not launched.'}
  Add-AudioEvent 'Exact production x64 candidate identity verified' 'PASS' ([pscustomobject]@{Requirement='REG-008';ArtifactId=$expectedArtifactId;FinalizerRunId=$expectedRunId;CandidateExecutableSHA256=$actualHash;CandidateProductVersion=$version;PEMachine=('0x{0:X4}'-f$machine);OS=$os.Caption;OSVersion=$os.Version;OSBuild=$os.BuildNumber;OSArchitecture=$osArch;ProcessArchitecture=$procArch;NativeProcessorArchitectureCodes=$nativeProcessorCodes;CandidateExecution=$candidateExecution;Environment=$environmentDescription;RunnerFlavor=$runnerFlavor;SessionId=$testSessionId;SessionName=$sessionName;ExpectedSessionId=if($server2025RdpContext-or$server2025ConsoleContext){$ExpectedSessionId}else{$null};ExpectedSessionName=if($server2025RdpContext-or$server2025ConsoleContext){$ExpectedSessionName}else{$null};ExpectedUser=if($server2025RdpContext-or$server2025ConsoleContext){$ExpectedUser}else{$null};ConsoleDesktop=$consoleDesktopRecord;FreshProfile=$true})
  if(-not$nativeTypeLoaded){Add-Type -TypeDefinition $nativeSource -ErrorAction Stop;$nativeTypeLoaded=$true}
  Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop;Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop;Add-Type -AssemblyName System.Drawing -ErrorAction Stop;Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
  Prepare-DisposableRunnerDesktop
  $script:ownedProcess=Start-Process -FilePath $script:ExecutablePath -PassThru -ErrorAction Stop;$script:appPid=$script:ownedProcess.Id
  $candidateProcessSession=(Get-Process -Id $script:appPid -ErrorAction Stop).SessionId
  $candidateSessionValid=($candidateProcessSession-eq$testSessionId)
  Add-AudioEvent 'Exact candidate process is in the verified audio-test session' $(if($candidateSessionValid){'PASS'}else{'BLOCKED'}) ([pscustomobject]@{CandidatePid=$script:appPid;CandidateSessionId=$candidateProcessSession;ExpectedSessionId=$testSessionId;CandidateExecution=$candidateExecution;User=$testUser})
  if(-not$candidateSessionValid){throw 'Exact candidate process did not start in the same verified audio-test session.'}
  $windowWatch=[Diagnostics.Stopwatch]::StartNew()
  while($windowWatch.Elapsed.TotalSeconds-lt20-and$script:mainWindow-eq[IntPtr]::Zero){foreach($h in [EBR_AUDIO_NATIVE]::TopWindowsForProcess($script:appPid)){if([EBR_AUDIO_NATIVE]::ClassName($h)-eq'EyeBreakReminder.Native'){$script:mainWindow=$h;break}};if($script:mainWindow-eq[IntPtr]::Zero){Start-Sleep -Milliseconds 50}}
  if($script:mainWindow-eq[IntPtr]::Zero){$controlFailure=$true;Add-AudioEvent 'Exact candidate creates its native main window in the verified test context' 'FAIL' ([pscustomobject]@{Pid=$script:appPid;Exited=$script:ownedProcess.HasExited;ExitCode=$(if($script:ownedProcess.HasExited){$script:ownedProcess.ExitCode}else{$null});CandidateExecution=$candidateExecution;Environment=$environmentDescription});throw 'Candidate did not create a visible native app window.'}
  Assert-CandidateForegroundAndUnobscured
  $windowTitle=[EBR_AUDIO_NATIVE]::Text($script:mainWindow)
  Add-AudioEvent 'Exact candidate launches with a visible native window' 'PASS' ([pscustomobject]@{Pid=$script:appPid;Class=[EBR_AUDIO_NATIVE]::ClassName($script:mainWindow);Title=$windowTitle;Handle=('0x{0:X}'-f$script:mainWindow.ToInt64());MainWindowScreenshot=(Save-WindowScreenshot $script:mainWindow 'candidate-main-window.png')})
  $audioHandlesAfterLaunch=Get-CandidateHandleCount;$script:audioHandleMilestones.Add([pscustomobject]@{Stage='after candidate main window launch, before Settings navigation';HandleCount=$audioHandlesAfterLaunch;Utc=[DateTime]::UtcNow.ToString('o')})
  Invoke-AudioClick 12 'Settings navigation';Invoke-AudioClick 132 'Alarm settings section'
  Start-Sleep -Milliseconds 200
  $audioHandlesAfterAlarmSettings=Get-CandidateHandleCount;$script:audioHandleMilestones.Add([pscustomobject]@{Stage='after opening Alarm Settings, before control inspection';HandleCount=$audioHandlesAfterAlarmSettings;Utc=[DateTime]::UtcNow.ToString('o')})
  foreach($control in @(@(102,'Alarm sound'),@(103,'Alarm volume'),@(116,'Preview alarm'),@(117,'Stop preview'),@(32,'Alarm enabled'))){Add-ControlEvidence ([int]$control[0]) ([string]$control[1])}
  $audioHandlesBefore=Get-CandidateHandleCount;$script:audioHandleMilestones.Add([pscustomobject]@{Stage='acceptance baseline after Settings control inspection, before endpoint/audio trials';HandleCount=$audioHandlesBefore;Utc=[DateTime]::UtcNow.ToString('o')})
  $script:endpoint=[EBR_WASAPI]::Probe()
  Add-AudioEvent 'Enumerate real active WASAPI render endpoint and observe its current master state' $(if($script:endpoint.DefaultEndpointId){'PASS'}else{'NOT TESTED'}) ([pscustomobject]@{ActiveRenderEndpointCount=$script:endpoint.ActiveRenderEndpointCount;DefaultEndpointId=$script:endpoint.DefaultEndpointId;DefaultMasterVolume=$script:endpoint.DefaultMasterVolume;DefaultMuted=$script:endpoint.DefaultMuted;Error=$script:endpoint.Error;NoEndpointDriverInstalled=$true;HostVolumeChanged=$false})
  if($script:endpoint.DefaultEndpointId){
    $baseRecorder=[EBR_WASAPI+Recorder]::new();$baseError=$baseRecorder.Begin(400)
    if(-not$baseError){$script:baseline=$baseRecorder.Finish(5000);$script:wasapiAvailable=($script:baseline-and-not$script:baseline.Error-and$script:baseline.Frames-gt0);Add-AudioEvent 'WASAPI loopback receives buffers from the selected Windows render endpoint before candidate preview' $(if($script:wasapiAvailable){'PASS'}else{'NOT TESTED'}) ([pscustomobject]@{EndpointId=$script:baseline.EndpointId;Frames=$script:baseline.Frames;Packets=$script:baseline.Packets;Rms=[Math]::Round($script:baseline.Rms,8);Peak=[Math]::Round($script:baseline.Peak,8);Error=$script:baseline.Error})}else{Add-AudioEvent 'WASAPI loopback receives buffers from the selected Windows render endpoint before candidate preview' 'NOT TESTED' $baseError}
  }else{Add-AudioEvent 'WASAPI loopback receives buffers from the selected Windows render endpoint before candidate preview' 'NOT TESTED' 'No active default render endpoint exists in this runner user session.'}

  $allResults=[System.Collections.Generic.List[object]]::new();$soundNames=@('Gentle','Bell','Chime','Clear','Soft')
  foreach($sound in 0..4){
    foreach($volume in @(0,55,100)){
      try{
        Set-AudioSound $sound;Set-AudioVolume $volume
        $persisted=(Wait-AudioSetting 'sound' ([string]$sound))-and(Wait-AudioSetting 'volume' ([string]$volume))
        Test-AudioRequire $persisted "Settings controls persist sound '$($soundNames[$sound])' ($sound) and volume $volume%" ([pscustomobject]@{SoundIndex=$sound;SoundName=$soundNames[$sound];Volume=$volume;Saved=(Read-AudioSettings)})|Out-Null
        $tag=('sound-{0}-volume-{1}' -f $soundNames[$sound],$volume) -replace '[^A-Za-z0-9-]','-'
        $result=Get-AudioPreview $sound $volume $script:wasapiAvailable $tag
        $allResults.Add($result)
        if(-not$result.LoopbackAvailable-or($volume-gt0-and-not$result.PreviewStartedObserved)){$acousticCoverageMissing=$true}
        $candidateSessionSignal=($result.CandidateSessionMeter-and$result.CandidateSessionMeter.ProcessId-eq$script:appPid-and$result.CandidateSessionMeter.EndpointId-ceq$script:baseline.EndpointId-and$result.CandidateSessionMeter.ActiveSamples-gt0-and$result.CandidateSessionMeter.NonZeroSamples-gt0-and$result.CandidateSessionMeter.Peak-gt0.0001-and-not$result.CandidateSessionMeter.Error)
        if($volume-gt0){
          if($candidateSessionSignal){Add-AudioEvent "Candidate PID audio session has active nonzero samples for $($soundNames[$sound]) at $volume%" 'PASS' $result.CandidateSessionMeter}
          else{$acousticCoverageMissing=$true;Add-AudioEvent "Candidate PID audio session has active nonzero samples for $($soundNames[$sound]) at $volume%" 'NOT TESTED' ([pscustomobject]@{PreviewStartedObserved=$result.PreviewStartedObserved;SessionMeter=$result.CandidateSessionMeter;SessionMeterStartError=$result.CandidateSessionMeterStartError;Reason='WASAPI did not expose nonzero audio-meter samples attributed to the exact candidate PID.'})}
        }else{
          $zeroSessionMeterAvailable=($result.CandidateSessionMeter-and$result.CandidateSessionMeter.ProcessId-eq$script:appPid-and$result.CandidateSessionMeter.EndpointId-ceq$script:baseline.EndpointId-and$result.CandidateSessionMeter.MeterSamples-gt0-and-not$result.CandidateSessionMeter.Error)
          if($zeroSessionMeterAvailable){
            $zeroSessionQuiet=($result.CandidateSessionMeter.NonZeroSamples-eq0-and$result.CandidateSessionMeter.Peak-le0.0001)
            Test-AudioAcousticRequire $zeroSessionQuiet "Volume 0 produces no candidate-PID session-meter signal for $($soundNames[$sound])" ([pscustomobject]@{CandidateSessionMeter=$result.CandidateSessionMeter;MaximumAcceptedPeak=0.0001;NonZeroSamples=$result.CandidateSessionMeter.NonZeroSamples})|Out-Null
          }else{$acousticCoverageMissing=$true;Add-AudioEvent "Volume 0 candidate-PID session meter is available for $($soundNames[$sound])" 'NOT TESTED' ([pscustomobject]@{CandidateSessionMeter=$result.CandidateSessionMeter;StartError=$result.CandidateSessionMeterStartError;Reason='WASAPI did not provide same-endpoint meter samples attributed to the exact candidate PID.'})}
        }
        if($result.StopEnabledAfter){$controlFailure=$true;Add-AudioEvent "Stop Preview leaves playback active after $($soundNames[$sound]) at $volume%" 'FAIL' $result}
        elseif($result.PreviewStartedObserved){Add-AudioEvent "Preview enters a real playing state for $($soundNames[$sound]) at $volume%" 'PASS' ([pscustomobject]@{PreviewStartedObserved=$result.PreviewStartedObserved;UnavailableDialog=$result.UnavailableDialog;StopClicked=$result.StopClicked;CandidateSessionMeter=$result.CandidateSessionMeter;Loopback=$result.Loopback})}
        elseif($volume-eq0-and$result.LoopbackAvailable-and-not$result.Loopback.NonZeroSamples-and-not$result.UnavailableDialog){Add-AudioEvent "Zero-volume preview remains acoustically quiet for $($soundNames[$sound])" 'PASS' ([pscustomobject]@{PreviewStartedObserved=$result.PreviewStartedObserved;ZeroVolumeSilenceObserved=$true;CandidateSessionMeter=$result.CandidateSessionMeter;Loopback=$result.Loopback})}
        else{Add-AudioEvent "Preview enters a real playing state for $($soundNames[$sound]) at $volume%" 'NOT TESTED' ([pscustomobject]@{UnavailableDialog=$result.UnavailableDialog;LoopbackStartError=$result.LoopbackStartError;CandidateSessionMeter=$result.CandidateSessionMeter;StopEnabledAfter=$result.StopEnabledAfter})}
      }catch{Add-AudioEvent "Exercise $($soundNames[$sound]) at $volume% through the real candidate Settings controls" 'FAIL' $_.Exception.Message;$controlFailure=$true}
      if($script:ownedProcess.HasExited){throw "Candidate exited during the sound/volume sweep (exit $($script:ownedProcess.ExitCode))."}
    }
  }

  if($script:wasapiAvailable){
    $baseRms=[double]$script:baseline.Rms
    foreach($sound in 0..4){
      $at0=@($allResults|Where-Object{$_.SoundIndex-eq$sound-and$_.Volume-eq0}|Select-Object -First 1)
      $at55=@($allResults|Where-Object{$_.SoundIndex-eq$sound-and$_.Volume-eq55}|Select-Object -First 1)
      $at100=@($allResults|Where-Object{$_.SoundIndex-eq$sound-and$_.Volume-eq100}|Select-Object -First 1)
      if($at0.Count-and$at55.Count-and$at100.Count-and$at0[0].LoopbackAvailable-and$at55[0].LoopbackAvailable-and$at100[0].LoopbackAvailable-and$at55[0].PreviewStartedObserved-and$at100[0].PreviewStartedObserved-and$at0[0].CandidateSessionMeter-and$at0[0].CandidateSessionMeter.ProcessId-eq$script:appPid-and$at0[0].CandidateSessionMeter.EndpointId-ceq$script:baseline.EndpointId-and$at0[0].CandidateSessionMeter.MeterSamples-gt0-and$at0[0].CandidateSessionMeter.NonZeroSamples-eq0-and$at0[0].CandidateSessionMeter.Peak-le0.0001-and$at55[0].CandidateSessionMeter-and$at55[0].CandidateSessionMeter.EndpointId-ceq$script:baseline.EndpointId-and$at55[0].CandidateSessionMeter.NonZeroSamples-gt0-and$at100[0].CandidateSessionMeter-and$at100[0].CandidateSessionMeter.EndpointId-ceq$script:baseline.EndpointId-and$at100[0].CandidateSessionMeter.NonZeroSamples-gt0-and$at0[0].Loopback.EndpointId-ceq$script:baseline.EndpointId-and$at55[0].Loopback.EndpointId-ceq$script:baseline.EndpointId-and$at100[0].Loopback.EndpointId-ceq$script:baseline.EndpointId){
        $baselinePeak=[double]$script:baseline.Peak;$zeroPeak=[double]$at0[0].Loopback.Peak;$zeroRms=[double]$at0[0].Loopback.Rms;$rms55=[double]$at55[0].Loopback.Rms;$rms100=[double]$at100[0].Loopback.Rms
        $zeroOk=($zeroRms-le($baseRms+0.003))-and($zeroPeak-le($baselinePeak+0.01))
        if($zeroOk){Test-AudioAcousticRequire $true "Volume 0 produces no candidate-PID session-meter or material loopback signal for $($soundNames[$sound])" ([pscustomobject]@{Volume0Rms=$zeroRms;Volume0Peak=$zeroPeak;BaselineRms=$baseRms;BaselinePeak=$baselinePeak;RmsThreshold=($baseRms+0.003);PeakThreshold=($baselinePeak+0.01);CandidateSessionMeter=$at0[0].CandidateSessionMeter;EndpointId=$script:baseline.EndpointId})|Out-Null}
        else{$acousticCoverageMissing=$true;Add-AudioEvent "Volume 0 is a quiet control capture for $($soundNames[$sound])" 'NOT TESTED' ([pscustomobject]@{Volume0Rms=$zeroRms;Volume0Peak=$zeroPeak;BaselineRms=$baseRms;BaselinePeak=$baselinePeak;Reason='Endpoint-wide loopback changed materially during the zero-volume control, so unrelated audio cannot be excluded.'})}
        $signalRms100=[Math]::Sqrt([Math]::Max(0,($rms100*$rms100)-($zeroRms*$zeroRms)));$signalRms55=[Math]::Sqrt([Math]::Max(0,($rms55*$rms55)-($zeroRms*$zeroRms)))
        $signalOk=$at100[0].PreviewStartedObserved-and$signalRms100-gt0.003-and$at100[0].Loopback.NonZeroSamples-gt100
        if($script:endpoint.DefaultMuted-or$script:endpoint.DefaultMasterVolume-le0.001){$acousticCoverageMissing=$true;Add-AudioEvent "Volume 100 sends $($soundNames[$sound]) through the Windows render mix" 'NOT TESTED' 'The default endpoint was muted or its master volume was zero; physical playback was not available to distinguish.'}
        elseif(-not$zeroOk){$acousticCoverageMissing=$true;Add-AudioEvent "Volume 100 candidate preview is distinguishable from unrelated loopback audio for $($soundNames[$sound])" 'NOT TESTED' 'The volume-zero control was not quiet relative to baseline, so endpoint-wide samples cannot be attributed to the candidate.'}
        else{Test-AudioAcousticRequire $signalOk "Volume 100 candidate-PID session and render mix contain preview audio for $($soundNames[$sound])" ([pscustomobject]@{Rms=$rms100;SignalRmsAboveVolumeZero=$signalRms100;VolumeZeroRms=$zeroRms;BaselineRms=$baseRms;Peak=$at100[0].Loopback.Peak;NonZeroSamples=$at100[0].Loopback.NonZeroSamples;CandidateSessionMeter=$at100[0].CandidateSessionMeter;EndpointId=$script:endpoint.DefaultEndpointId;PreviewStartedObserved=$at100[0].PreviewStartedObserved})|Out-Null}
        if($zeroOk-and$at55[0].PreviewStartedObserved-and$at100[0].PreviewStartedObserved-and$signalRms100-gt0-and$at55[0].CandidateSessionMeter.Peak-gt0-and$at100[0].CandidateSessionMeter.Peak-gt0){
          $mixRatio=$signalRms55/$signalRms100;$mixRatioOk=($mixRatio-ge0.35-and$mixRatio-le0.75)
          $sessionPeak55=[double]$at55[0].CandidateSessionMeter.Peak;$sessionPeak100=[double]$at100[0].CandidateSessionMeter.Peak;$sessionRatio=$sessionPeak55/$sessionPeak100;$sessionRatioOk=($sessionRatio-ge0.35-and$sessionRatio-le0.75)
          $ratioOk=$mixRatioOk-and$sessionRatioOk
          Test-AudioAcousticRequire $ratioOk "Volume 55 scales both candidate-PID session peaks and the render mix from volume 100 for $($soundNames[$sound])" ([pscustomobject]@{CandidateSessionPeak55=$sessionPeak55;CandidateSessionPeak100=$sessionPeak100;CandidateSessionMeasuredRatio=[Math]::Round($sessionRatio,4);RenderMixSignalRms55=$signalRms55;RenderMixSignalRms100=$signalRms100;RenderMixMeasuredRatio=[Math]::Round($mixRatio,4);ExpectedRatio=0.55;AcceptedRange='0.35..0.75';VolumeZeroRms=$zeroRms;EndpointId=$script:baseline.EndpointId})|Out-Null
        }else{$acousticCoverageMissing=$true;Add-AudioEvent "Compare candidate-PID and render-mix volume scaling for $($soundNames[$sound])" 'NOT TESTED' 'Volume 0 was not a quiet control, or same-endpoint volume 55/100 candidate session peaks and render-mix captures were unavailable.'}
      }else{$acousticCoverageMissing=$true;Add-AudioEvent "Compare captured volume scaling for $($soundNames[$sound])" 'NOT TESTED' 'A required same-endpoint capture, quiet candidate-PID volume-zero meter, playing state, or nonzero candidate-PID audio-session sample is unavailable.'}
    }
  }else{$acousticCoverageMissing=$true;Add-AudioEvent 'Volume 0/55/100 acoustic sample comparison' 'NOT TESTED' 'No functioning WASAPI loopback render capture was available; settings and preview-control tests continue independently.'}

  Set-AudioSound 0;Set-AudioVolume 55
  foreach($repeat in 1..2){
    $result=Get-AudioPreview 0 55 $script:wasapiAvailable "repeated-preview-$repeat"
    $repeatedSessionSignal=($result.CandidateSessionMeter-and$result.CandidateSessionMeter.ProcessId-eq$script:appPid-and$result.CandidateSessionMeter.EndpointId-ceq$script:baseline.EndpointId-and$result.CandidateSessionMeter.NonZeroSamples-gt0-and-not$result.CandidateSessionMeter.Error)
    if($result.StopEnabledAfter){$controlFailure=$true;Add-AudioEvent "Repeated preview $repeat ends with Stop Preview disabled" 'FAIL' $result}
    elseif(-not$result.PreviewStartedObserved-or-not$repeatedSessionSignal-or-not$result.LoopbackAvailable-or-not$result.Loopback.NonZeroSamples-or$result.Loopback.EndpointId-cne$script:baseline.EndpointId){$acousticCoverageMissing=$true;Add-AudioEvent "Repeated preview $repeat reaches a clean playing state with same-endpoint candidate-PID and render-mix evidence" 'NOT TESTED' ([pscustomobject]@{PreviewStartedObserved=$result.PreviewStartedObserved;CandidateSessionMeter=$result.CandidateSessionMeter;StopEnabledAfter=$result.StopEnabledAfter;UnavailableDialog=$result.UnavailableDialog;LoopbackAvailable=$result.LoopbackAvailable;Loopback=$result.Loopback;BaselineEndpointId=$script:baseline.EndpointId})}
    else{Add-AudioEvent "Repeated preview $repeat reaches a clean playing state with candidate-PID and render-mix evidence" 'PASS' ([pscustomobject]@{PreviewStartedObserved=$result.PreviewStartedObserved;CandidateSessionMeter=$result.CandidateSessionMeter;StopEnabledAfter=$result.StopEnabledAfter;LoopbackAvailable=$result.LoopbackAvailable;Loopback=$result.Loopback})}
  }
  Set-AudioSound 0;Set-AudioVolume 100;Set-AudioCheck 32 $true 'Alarm enabled'
  $naturalResults=[System.Collections.Generic.List[object]]::new()
  foreach($naturalAttempt in 1..3){
    $naturalTag=if($naturalAttempt-eq1){'natural-completion-baseline'}else{"natural-completion-control-$naturalAttempt"}
    $naturalTrial=Get-AudioPreview 0 100 $script:wasapiAvailable $naturalTag $false $true
    $naturalResults.Add($naturalTrial)
    if($naturalTrial.PreviewStartedObserved-and-not$naturalTrial.NaturalCompletionObserved){break}
  }
  $naturalResult=$naturalResults[0]
  $naturalRows=[System.Collections.Generic.List[object]]::new();$naturalDurations=[System.Collections.Generic.List[double]]::new();$naturalCapturesComplete=($naturalResults.Count-eq3)
  foreach($trial in $naturalResults){
    $sessionSignal=($trial.CandidateSessionMeter-and$trial.CandidateSessionMeter.ProcessId-eq$script:appPid-and$trial.CandidateSessionMeter.EndpointId-ceq$script:baseline.EndpointId-and$trial.CandidateSessionMeter.NonZeroSamples-gt0-and-not$trial.CandidateSessionMeter.Error)
    $captureComplete=($trial.PreviewStartedObserved-and$trial.NaturalCompletionObserved-and$sessionSignal-and$trial.LoopbackAvailable-and$trial.Loopback.NonZeroSamples-gt0-and$trial.Loopback.EndpointId-ceq$script:baseline.EndpointId)
    if(-not$captureComplete){$naturalCapturesComplete=$false}
    if($null-ne$trial.NaturalCompletionElapsedMs){$naturalDurations.Add([double]$trial.NaturalCompletionElapsedMs)}
    $naturalRows.Add([pscustomobject]@{Tag=$trial.Tag;PreviewStartedObserved=$trial.PreviewStartedObserved;NaturalCompletionObserved=$trial.NaturalCompletionObserved;DurationMs=$trial.NaturalCompletionElapsedMs;CandidateSessionMeter=$trial.CandidateSessionMeter;Loopback=$trial.Loopback;CaptureComplete=$captureComplete})
  }
  $naturalDurationValid=$false;$naturalMinimumMs=$null;$naturalSpreadMs=$null
  if($naturalCapturesComplete-and$naturalDurations.Count-eq3){
    $naturalMinimumMs=[double](($naturalDurations|Measure-Object -Minimum).Minimum);$naturalMaximumMs=[double](($naturalDurations|Measure-Object -Maximum).Maximum);$naturalSpreadMs=$naturalMaximumMs-$naturalMinimumMs
    $allNaturalDurationsInRange=@($naturalDurations|Where-Object{$_-lt1900-or$_-gt3500}).Count-eq0
    if(-not$allNaturalDurationsInRange){Test-AudioAcousticRequire $false 'Three same-endpoint Gentle previews each complete near the bundled 2.2-second WAV duration' ([pscustomobject]@{Trials=$naturalRows.ToArray();ExpectedWavDurationMs=2200;AcceptedRangeMs='1900..3500'})|Out-Null}
    elseif($naturalSpreadMs-gt250){$acousticCoverageMissing=$true;Add-AudioEvent 'Three same-endpoint Gentle preview completion timings form a stable mute-stop comparator' 'NOT TESTED' ([pscustomobject]@{Trials=$naturalRows.ToArray();MinimumDurationMs=$naturalMinimumMs;MaximumDurationMs=$naturalMaximumMs;SpreadMs=$naturalSpreadMs;MaximumAcceptedSpreadMs=250;Reason='The natural completion timing varied too much for a conservative early-stop comparison.'})}
    else{$naturalDurationValid=$true;Add-AudioEvent 'Three same-endpoint Gentle previews complete within the bundled 2.2-second duration with stable timing' 'PASS' ([pscustomobject]@{Trials=$naturalRows.ToArray();ExpectedWavDurationMs=2200;AcceptedRangeMs='1900..3500';MinimumDurationMs=$naturalMinimumMs;MaximumDurationMs=$naturalMaximumMs;SpreadMs=$naturalSpreadMs;MaximumAcceptedSpreadMs=250})}
  }elseif(@($naturalResults|Where-Object{$_.PreviewStartedObserved-and-not$_.NaturalCompletionObserved}).Count){
    Test-AudioAcousticRequire $false 'Gentle sound preview stops naturally after its bundled 2.2-second clip' ([pscustomobject]@{Trials=$naturalRows.ToArray();Reason='Preview entered its playing state but Stop Preview remained enabled for the full 15-second natural-completion observation window.'})|Out-Null
  }else{$acousticCoverageMissing=$true;Add-AudioEvent 'Three same-endpoint Gentle previews provide candidate-PID audio and natural-completion captures' 'NOT TESTED' ([pscustomobject]@{Trials=$naturalRows.ToArray();Reason='At least one natural control lacks same-endpoint candidate-PID session or render-mix evidence.'})}
  Set-AudioSound 0;Set-AudioVolume 100;Set-AudioCheck 32 $true 'Alarm enabled'
  try{$muteResult=Get-AudioPreview 0 100 $script:wasapiAvailable 'mute-stop-probe' $true}
  catch{
    $muteError=$_.Exception.Message
    if($muteError-match"Candidate checkbox 'Alarm enabled' did not reach state False"){$controlFailure=$true;Add-AudioEvent 'Alarm checkbox changes to disabled while the exact candidate preview is active' 'FAIL' ([pscustomobject]@{Error=$muteError;CandidatePid=$script:appPid;ExpectedAlarmState=$false})}
    else{$acousticCoverageMissing=$true;Add-AudioEvent 'Alarm-toggle playback probe completes with usable Windows audio evidence' 'NOT TESTED' ([pscustomobject]@{Error=$muteError;Reason='The runner harness could not complete the controlled Alarm-toggle probe.'})}
    throw
  }
  $muteSessionSignal=($muteResult.CandidateSessionMeter-and$muteResult.CandidateSessionMeter.ProcessId-eq$script:appPid-and$muteResult.CandidateSessionMeter.EndpointId-ceq$script:baseline.EndpointId-and$muteResult.CandidateSessionMeter.NonZeroSamples-gt0-and-not$muteResult.CandidateSessionMeter.Error)
  $muteTotalDurationMs=if($null-ne$muteResult.PreviewElapsedAtAlarmToggleMs-and$null-ne$muteResult.AlarmToggleElapsedMs){[double]$muteResult.PreviewElapsedAtAlarmToggleMs+[double]$muteResult.AlarmToggleElapsedMs}else{[double]::PositiveInfinity}
  $muteCaptureComplete=($muteResult.PreviewStartedObserved-and$muteSessionSignal-and$muteResult.LoopbackAvailable-and$muteResult.Loopback.NonZeroSamples-gt0-and$muteResult.Loopback.EndpointId-ceq$script:baseline.EndpointId)
  $muteStoppedBeforeNaturalEnd=($naturalDurationValid-and$naturalMinimumMs-gt($muteTotalDurationMs+200))
  if(-not$muteResult.AlarmToggleAttempted){$acousticCoverageMissing=$true;Add-AudioEvent 'Alarm toggle is exercised while the exact candidate preview is active' 'NOT TESTED' ([pscustomobject]@{PreviewStartedObserved=$muteResult.PreviewStartedObserved;AlarmToggleAttempted=$false;StopEnabledImmediatelyBeforeAlarmToggle=$muteResult.StopEnabledImmediatelyBeforeAlarmToggle;CandidateSessionMeter=$muteResult.CandidateSessionMeter;Loopback=$muteResult.Loopback;Reason='The harness did not observe and invoke the Alarm checkbox while Stop Preview was enabled.'});Set-AudioCheck 32 $true 'Alarm enabled'}
  elseif(-not$muteCaptureComplete-or-not$naturalDurationValid){$acousticCoverageMissing=$true;Add-AudioEvent 'Compare Alarm-toggle stop with three same-setting natural preview trials' 'NOT TESTED' ([pscustomobject]@{MuteCaptureComplete=$muteCaptureComplete;MuteResult=$muteResult;NaturalTrials=$naturalRows.ToArray();NaturalDurationValid=$naturalDurationValid;Reason='Candidate audio evidence or a stable natural-duration comparator is missing.'});Set-AudioCheck 32 $true 'Alarm enabled'}
  else{
    $muteBehaviorOk=($muteResult.StopEnabledImmediatelyBeforeAlarmToggle-and$muteResult.StopDisabledAfterAlarmToggle-and$muteResult.AlarmToggleElapsedMs-le1500-and-not$muteResult.AlarmEnabledAfterToggle-and$muteStoppedBeforeNaturalEnd)
    Test-AudioRequire $muteBehaviorOk 'Disabling Alarm stops same-endpoint candidate-attributed playback at least 200 ms before the earliest of three same-setting natural completions' ([pscustomobject]@{PreviewStartedObserved=$muteResult.PreviewStartedObserved;CandidateSessionMeter=$muteResult.CandidateSessionMeter;Loopback=$muteResult.Loopback;StopEnabledImmediatelyBeforeAlarmToggle=$muteResult.StopEnabledImmediatelyBeforeAlarmToggle;StopDisabledAfterAlarmToggle=$muteResult.StopDisabledAfterAlarmToggle;AlarmToggleElapsedMs=$muteResult.AlarmToggleElapsedMs;PreviewElapsedAtAlarmToggleMs=$muteResult.PreviewElapsedAtAlarmToggleMs;MuteTotalDurationMs=$muteTotalDurationMs;NaturalMinimumDurationMs=$naturalMinimumMs;NaturalMaximumDurationMs=($naturalMinimumMs+$naturalSpreadMs);NaturalSpreadMs=$naturalSpreadMs;StoppedAtLeast200msBeforeEarliestNaturalEnd=$muteStoppedBeforeNaturalEnd;AlarmEnabledAfterToggle=$muteResult.AlarmEnabledAfterToggle;StopPreviewEnabledAfterReturn=(Get-AudioControl 117 'Stop preview').Enabled;SavedAlarm=(Read-AudioSettings).alarm})|Out-Null
    Set-AudioCheck 32 $true 'Alarm enabled';Test-AudioRequire (Wait-AudioSetting 'alarm' '1') 'Alarm enabled setting is restored after the mute test'|Out-Null
  }

  $naturalAlarmRecord=Invoke-NaturalAlarmTrial
  if($naturalAlarmRecord.Status-ne'PASS'){$acousticCoverageMissing=$true}
  if($script:mainWindow-ne[IntPtr]::Zero){Add-AudioEvent 'Candidate main window remains responsive after preview and natural-alarm tests' 'PASS' ([pscustomobject]@{WindowVisible=[EBR_AUDIO_NATIVE]::Visible($script:mainWindow);WindowTitle=[EBR_AUDIO_NATIVE]::Text($script:mainWindow);ProcessResponding=(-not$script:ownedProcess.HasExited);NaturalAlarmStatus=$naturalAlarmRecord.Status})}
  $audioHandlesAfter=Get-CandidateHandleCount;$handlesReleased=($null-ne$audioHandlesAfter-and$audioHandlesAfter-le($audioHandlesBefore+2));Test-AudioRequire $handlesReleased 'Preview, Stop, mute, and natural-alarm paths release candidate audio handles' ([pscustomobject]@{HandleCountBefore=$audioHandlesBefore;HandleCountAfter=$audioHandlesAfter;AllowedGrowth=2;NaturalAlarmStatus=$naturalAlarmRecord.Status;Milestones=$script:audioHandleMilestones.ToArray()})|Out-Null
  $waveFiles=@(Get-ChildItem -LiteralPath $script:evidenceRoot -Filter '*.wav' -File -ErrorAction SilentlyContinue|Select-Object Name,Length)
  if($script:wasapiAvailable-and$naturalAlarmRecord.Status-eq'PASS'-and$naturalAlarmRecord.AcousticStatus-eq'PASS'-and-not$acousticCoverageMissing-and-not$controlFailure-and-not$acousticFailure){$overallStatus='PASS';$overallReason='Every required candidate sound/volume preview and mute/stop interaction plus one naturally timed one-minute Work-to-Break alarm produced valid same-endpoint WASAPI and exact-candidate session-meter evidence in '+$environmentDescription+'; physical speaker audibility was not verified.'}
  elseif($controlFailure-or$acousticFailure){$overallStatus='FAIL';$overallReason='One or more real candidate Settings/playback or loopback acoustic assertions failed; inspect the per-event evidence.'}
  else{$overallStatus='BLOCKED';$overallReason=if(-not$script:wasapiAvailable){'Settings, preview controls, and the natural timer transition were exercised, but no functioning Windows WASAPI loopback endpoint was available; acoustic output remains unverified.'}else{'Preview coverage may be available, but the natural timer-alarm or full same-endpoint acoustic assertions did not complete; REG-008 remains blocked.'}}
  Add-AudioEvent 'Physical audible sound from speakers or headphones' 'NOT TESTED' 'The runner has no user-observed physical speaker/headphone check. WASAPI loopback (if available) verifies only audio-engine render samples.'
}catch{
  if($overallStatus-ne'BLOCKED'){$overallStatus=if($controlFailure){'FAIL'}else{'BLOCKED'};$overallReason=$_.Exception.Message}
  elseif($_.Exception.Message-notmatch'Audio acceptance environment gate failed|Exact production executable is missing|Candidate hash does not match|Candidate PE architecture or version|The disposable runner profile already contains'){if($controlFailure){$overallStatus='FAIL'};$overallReason=$_.Exception.Message}
  Add-AudioEvent 'REG-008 runner harness execution' $(if($overallStatus-eq'FAIL'){'FAIL'}else{'BLOCKED'}) ([pscustomobject]@{Message=$_.Exception.Message;StackTrace=$_.ScriptStackTrace})
}finally{
  if($script:ownedProcess){try{$script:ownedProcess.Refresh();if(-not$script:ownedProcess.HasExited){[void][EBR_AUDIO_NATIVE]::Post($script:mainWindow,0x0010,[IntPtr]::Zero,[IntPtr]::Zero);if(-not$script:ownedProcess.WaitForExit(3000)){Stop-Process -Id $script:appPid -Force -ErrorAction SilentlyContinue;[void]$script:ownedProcess.WaitForExit(3000)}}}catch{Add-AudioEvent 'Stop only the harness-owned candidate process' 'FAIL' $_.Exception.Message}}
  $appExited=$true;if($script:ownedProcess){try{$script:ownedProcess.Refresh();$appExited=$script:ownedProcess.HasExited}catch{$appExited=$false}}
  if($script:appDataPath-and-not$script:appDataExistedBefore-and(Test-Path -LiteralPath $script:appDataPath)){
    try{$local=[IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd('\')+'\';$resolved=[IO.Path]::GetFullPath($script:appDataPath);if(-not$resolved.StartsWith($local,[StringComparison]::OrdinalIgnoreCase)-or[IO.Path]::GetFileName($resolved)-cne'EyeBreakReminder'-or([IO.File]::GetAttributes($resolved)-band[IO.FileAttributes]::ReparsePoint)){throw 'Refusing to remove a non-test or reparse-point app-data path.'};if(-not$appExited){throw 'Candidate process is still running; preserving its data path.'};Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop;Add-AudioEvent 'Remove only the fresh candidate app-data folder' 'PASS' ([pscustomobject]@{Path=$resolved;Preexisting=$false;CandidateExited=$appExited})}catch{Add-AudioEvent 'Remove only the fresh candidate app-data folder' 'FAIL' $_.Exception.Message;$overallStatus='FAIL';$overallReason='Test cleanup failed: '+$_.Exception.Message}
  }
  try{
    $record=[pscustomobject]@{Requirement='REG-008';Status=$overallStatus;Reason=$overallReason;AcousticCoverageComplete=(-not$acousticCoverageMissing);NaturalAlarmTrial=$naturalAlarmRecord;ArtifactId=$expectedArtifactId;FinalizerRunId=$expectedRunId;CandidateExecutableSHA256=$expectedSha256;CandidateArchitecture='AMD64 x64';CandidateExecution=$candidateExecution;Environment=$environmentDescription;RunnerFlavor=$runnerFlavor;SessionId=$testSessionId;SessionName=$sessionName;User=$testUser;ExpectedSessionId=if($server2025RdpContext-or$server2025ConsoleContext){$ExpectedSessionId}else{$null};ExpectedSessionName=if($server2025RdpContext-or$server2025ConsoleContext){$ExpectedSessionName}else{$null};ExpectedUser=if($server2025RdpContext-or$server2025ConsoleContext){$ExpectedUser}else{$null};ConsoleDesktop=$consoleDesktopRecord;OperatingSystem=[pscustomobject]@{Caption=$(if($os){$os.Caption}else{$null});Version=$(if($os){$os.Version}else{$null});Build=$(if($os){$os.BuildNumber}else{$null});OSArchitecture=$(if($osArch){$osArch}else{$null});ProcessArchitecture=$(if($procArch){$procArch}else{$null});UserInteractive=[Environment]::UserInteractive};Profile=[pscustomobject]@{AppDataPath=$script:appDataPath;ExistedBefore=$script:appDataExistedBefore;RemovedAfter=if($script:appDataPath){-not(Test-Path -LiteralPath $script:appDataPath)}else{$null}};AudioEndpoint=$script:endpoint;WasapiLoopbackStatus=if($script:wasapiAvailable){'CAPTURED'}else{'NOT AVAILABLE'};Baseline=if($script:baseline){[pscustomobject]@{Frames=$script:baseline.Frames;Packets=$script:baseline.Packets;Rms=[Math]::Round($script:baseline.Rms,8);Peak=[Math]::Round($script:baseline.Peak,8)}}else{$null};PhysicalAudibility='NOT VERIFIED';CaptureFiles=$waveFiles;Captures=$script:captures.ToArray();AudioHandleMilestones=$script:audioHandleMilestones.ToArray();Events=$script:events.ToArray();AssertionCount=@($script:events|Where-Object{$_.Status-in@('PASS','FAIL')}).Count;PassCount=@($script:events|Where-Object{$_.Status-eq'PASS'}).Count;FailCount=@($script:events|Where-Object{$_.Status-eq'FAIL'}).Count;NotTestedCount=@($script:events|Where-Object{$_.Status-eq'NOT TESTED'}).Count;CompletedUtc=[DateTime]::UtcNow.ToString('o')}
    $record|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $script:evidenceRoot 'reg-008-audio-loopback-results.json') -Encoding UTF8
  }catch{Write-Error "Could not write REG-008 evidence: $($_.Exception.Message)"}
}
Write-Host "REG-008 audio loopback attempt: $overallStatus — $overallReason"
if($overallStatus-eq'FAIL'){throw $overallReason}
