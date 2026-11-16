param(
  [Parameter(Mandatory=$true)][string]$EvidenceDirectory,
  [Parameter(Mandatory=$true)][string]$CandidateRunId,
  [Parameter(Mandatory=$true)][string]$CandidateExeSHA256
)
$ErrorActionPreference='Stop'
$EvidenceDirectory=[IO.Path]::GetFullPath($EvidenceDirectory)
[void][IO.Directory]::CreateDirectory($EvidenceDirectory)
if(-not ('EBR_AUDIO_ENDPOINT_PROBE' -as [type])){
  Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
[StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
public struct EBR_AUDIO_WAVEOUTCAPS {
  public ushort wMid, wPid, vDriverVersion;
  [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string szPname;
  public uint dwFormats;
  public ushort wChannels, wReserved1;
  public uint dwSupport;
}
[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
public class EBR_AUDIO_MMDeviceEnumeratorComObject {}
[ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface EBR_AUDIO_IMMDeviceEnumerator {
  [PreserveSig] int EnumAudioEndpoints(int dataFlow, uint stateMask, [MarshalAs(UnmanagedType.Interface)] out EBR_AUDIO_IMMDeviceCollection devices);
  [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, [MarshalAs(UnmanagedType.Interface)] out EBR_AUDIO_IMMDevice device);
}
[ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface EBR_AUDIO_IMMDeviceCollection {
  [PreserveSig] int GetCount(out uint count);
  [PreserveSig] int Item(uint index, [MarshalAs(UnmanagedType.Interface)] out EBR_AUDIO_IMMDevice device);
}
[ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface EBR_AUDIO_IMMDevice {
  [PreserveSig] int Activate(ref Guid iid, uint classContext, IntPtr activationParameters, [MarshalAs(UnmanagedType.IUnknown)] out object activatedInterface);
  [PreserveSig] int OpenPropertyStore(uint access, out IntPtr properties);
  [PreserveSig] int GetId(out IntPtr endpointId);
  [PreserveSig] int GetState(out uint state);
}
public static class EBR_AUDIO_ENDPOINT_PROBE {
  [DllImport("winmm.dll", ExactSpelling=true)] public static extern uint waveOutGetNumDevs();
  [DllImport("winmm.dll", CharSet=CharSet.Unicode, ExactSpelling=true)] public static extern uint waveOutGetDevCapsW(UIntPtr deviceId, out EBR_AUDIO_WAVEOUTCAPS caps, uint size);
  public static string[] WinMMDevices() {
    uint count=waveOutGetNumDevs(); var result=new List<string>();
    for(uint i=0;i<count;i++){EBR_AUDIO_WAVEOUTCAPS caps;uint status=waveOutGetDevCapsW(new UIntPtr(i),out caps,(uint)Marshal.SizeOf(typeof(EBR_AUDIO_WAVEOUTCAPS)));result.Add(status==0?caps.szPname:"device-index-"+i+" caps-error-"+status);}
    return result.ToArray();
  }
  public static string[] ActiveRenderEndpointIds() {
    object raw=null; EBR_AUDIO_IMMDeviceCollection devices=null; var result=new List<string>();
    try {
      raw=Activator.CreateInstance(typeof(EBR_AUDIO_MMDeviceEnumeratorComObject));
      var enumerator=(EBR_AUDIO_IMMDeviceEnumerator)raw;
      int hr=enumerator.EnumAudioEndpoints(0,1,out devices);if(hr<0)Marshal.ThrowExceptionForHR(hr);
      uint count=0;hr=devices.GetCount(out count);if(hr<0)Marshal.ThrowExceptionForHR(hr);
      for(uint i=0;i<count;i++){
        EBR_AUDIO_IMMDevice device=null;IntPtr id=IntPtr.Zero;
        try{hr=devices.Item(i,out device);if(hr<0)Marshal.ThrowExceptionForHR(hr);hr=device.GetId(out id);if(hr<0)Marshal.ThrowExceptionForHR(hr);uint state=0;hr=device.GetState(out state);if(hr<0)Marshal.ThrowExceptionForHR(hr);result.Add(Marshal.PtrToStringUni(id)+";state="+state);}
        finally{if(id!=IntPtr.Zero)Marshal.FreeCoTaskMem(id);if(device!=null&&Marshal.IsComObject(device))Marshal.ReleaseComObject(device);}
      }
      return result.ToArray();
    } finally {if(devices!=null&&Marshal.IsComObject(devices))Marshal.ReleaseComObject(devices);if(raw!=null&&Marshal.IsComObject(raw))Marshal.ReleaseComObject(raw);}
  }
  public static string DefaultAudioClientActivation() {
    object raw=null; EBR_AUDIO_IMMDevice device=null;object audioClient=null;
    try {
      raw=Activator.CreateInstance(typeof(EBR_AUDIO_MMDeviceEnumeratorComObject));
      var enumerator=(EBR_AUDIO_IMMDeviceEnumerator)raw;
      int hr=enumerator.GetDefaultAudioEndpoint(0,0,out device);if(hr<0)return "GetDefaultAudioEndpoint HRESULT=0x"+hr.ToString("X8");
      Guid iid=new Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2");hr=device.Activate(ref iid,1,IntPtr.Zero,out audioClient);
      return hr<0?"IAudioClient activation HRESULT=0x"+hr.ToString("X8"):"IAudioClient activation succeeded";
    } catch(Exception ex){return ex.GetType().FullName+": "+ex.Message;}
    finally{if(audioClient!=null&&Marshal.IsComObject(audioClient))Marshal.ReleaseComObject(audioClient);if(device!=null&&Marshal.IsComObject(device))Marshal.ReleaseComObject(device);if(raw!=null&&Marshal.IsComObject(raw))Marshal.ReleaseComObject(raw);}
  }
}
'@ -ErrorAction Stop
}
$os=Get-CimInstance Win32_OperatingSystem
$arch=[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
$winmm=@([EBR_AUDIO_ENDPOINT_PROBE]::WinMMDevices())
$wasapi=@([EBR_AUDIO_ENDPOINT_PROBE]::ActiveRenderEndpointIds())
$activation=if($wasapi.Count){[EBR_AUDIO_ENDPOINT_PROBE]::DefaultAudioClientActivation()}else{'Not attempted because no active WASAPI render endpoint was enumerated.'}
$audioStatus=if($wasapi.Count -eq 0){'BLOCKED'}elseif($activation -like 'IAudioClient activation succeeded'){'NOT TESTED'}else{'BLOCKED'}
$reason=if($wasapi.Count -eq 0){'This hosted Windows 11 ARM64 runner exposes no active WASAPI render endpoint; WinMM playback and WASAPI loopback are unavailable here.'}elseif($activation -notlike 'IAudioClient activation succeeded'){"A render endpoint exists, but IAudioClient could not activate: $activation"}else{'A Windows render endpoint and IAudioClient exist. App preview and alarm loopback capture must still be measured before claiming playback.'}
$result=[pscustomobject]@{
  CandidateRunId=$CandidateRunId
  CandidateExecutableSHA256=$CandidateExeSHA256
  OS=$os.Caption
  OSVersion=$os.Version
  OSArchitecture=$arch
  ProcessArchitecture=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
  WinMM=[pscustomobject]@{DeviceCount=$winmm.Count;Devices=$winmm}
  WASAPI=[pscustomobject]@{Api='IMMDeviceEnumerator.EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE)';ActiveRenderEndpointCount=$wasapi.Count;EndpointIds=$wasapi;DefaultAudioClientActivation=$activation}
  WindowsAudioOutputAndLoopbackStatus=$audioStatus
  PlaybackAttempted=$false
  LoopbackCaptureAttempted=$false
  Reason=$reason
  ObservedUtc=[DateTime]::UtcNow.ToString('o')
}
$result|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'windows-audio-endpoint-inventory.json') -Encoding UTF8
Write-Host "Windows audio endpoint inventory: WinMM=$($winmm.Count) WASAPI=$($wasapi.Count) status=$audioStatus"
