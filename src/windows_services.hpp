#pragma once
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <windowsx.h>
#include <commctrl.h>
#include <shellapi.h>
#include <shlobj.h>
#include <oleacc.h>
#include <dwmapi.h>
#include <wtsapi32.h>
#include <uxtheme.h>
#include <mmsystem.h>
#include <gdiplus.h>
#include <filesystem>
#include <memory>
#include <ctime>
#include "core.hpp"
namespace eye::win {
inline std::wstring wide(const std::string&s){if(s.empty())return{};int n=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,s.data(),int(s.size()),nullptr,0);if(!n)return{};std::wstring out(n,L' ');MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,s.data(),int(s.size()),out.data(),n);return out;}
inline std::string utf8(const std::wstring&s){if(s.empty())return{};int n=WideCharToMultiByte(CP_UTF8,0,s.data(),int(s.size()),nullptr,0,nullptr,nullptr);std::string out(n,' ');WideCharToMultiByte(CP_UTF8,0,s.data(),int(s.size()),out.data(),n,nullptr,nullptr);return out;}
inline std::wstring executable(){std::wstring path(32768,L' ');DWORD n=GetModuleFileNameW(nullptr,path.data(),DWORD(path.size()));if(!n||n==path.size())throw std::runtime_error("Executable path unavailable");path.resize(n);return path;}
inline std::wstring dataDirectory(){PWSTR raw=nullptr;if(FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData,0,nullptr,&raw)))throw std::runtime_error("Local data folder unavailable");std::wstring dir=raw;CoTaskMemFree(raw);dir+=L"\\EyeBreakReminder";std::filesystem::create_directories(dir);return dir;}
inline std::int64_t utc(){return std::int64_t(std::time(nullptr));}
inline double monotonic(){LARGE_INTEGER t,f;QueryPerformanceCounter(&t);QueryPerformanceFrequency(&f);return double(t.QuadPart)/double(f.QuadPart);}
// Wall time with sub-second precision, used only to place operating-schedule deadlines on their exact second.
inline double preciseUtc(){FILETIME f{};GetSystemTimePreciseAsFileTime(&f);ULARGE_INTEGER u{};u.LowPart=f.dwLowDateTime;u.HighPart=f.dwHighDateTime;return double(u.QuadPart)/1e7-11644473600.0;}
// The Windows local calendar for one instant, read from the current time zone (including its daylight-saving rules for that
// year) on every call, so a time-zone change applies at once. Falls back to the C runtime if the zone cannot be read.
inline LocalTime localTime(std::int64_t stamp){
 stamp=std::max<std::int64_t>(0,stamp);ULARGE_INTEGER ticks{};ticks.QuadPart=std::uint64_t(stamp+11644473600LL)*10000000ULL;FILETIME file{ticks.LowPart,ticks.HighPart};
 SYSTEMTIME universal{},local{};DYNAMIC_TIME_ZONE_INFORMATION zone{};
 if(FileTimeToSystemTime(&file,&universal)&&GetDynamicTimeZoneInformation(&zone)!=TIME_ZONE_ID_INVALID&&SystemTimeToTzSpecificLocalTimeEx(&zone,&universal,&local))
  return{daysFromCivil(local.wYear,local.wMonth,local.wDay),local.wHour*60+local.wMinute,local.wSecond};
 std::time_t t=std::time_t(stamp);std::tm tm{};localtime_s(&tm,&t);return{daysFromCivil(tm.tm_year+1900,tm.tm_mon+1,tm.tm_mday),tm.tm_hour*60+tm.tm_min,tm.tm_sec};
}
inline bool read(const std::wstring&path,std::string&out,DWORD limit=2*1024*1024){
 HANDLE f=CreateFileW(path.c_str(),GENERIC_READ,FILE_SHARE_READ,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr);if(f==INVALID_HANDLE_VALUE)return false;
 LARGE_INTEGER n{};bool ok=GetFileSizeEx(f,&n)&&n.QuadPart>=0&&n.QuadPart<=limit;DWORD got=0;
 if(ok){out.resize(std::size_t(n.QuadPart));ok=ReadFile(f,out.data(),DWORD(out.size()),&got,nullptr)&&got==out.size();}CloseHandle(f);return ok;
}
inline bool exists(const std::wstring&path){return GetFileAttributesW(path.c_str())!=INVALID_FILE_ATTRIBUTES;}
inline bool writeAtomic(const std::wstring&path,const std::string&data){
 static unsigned counter=0;std::wstring tmp=path+L"."+std::to_wstring(GetCurrentProcessId())+L"."+std::to_wstring(++counter)+L".tmp";
 HANDLE f=CreateFileW(tmp.c_str(),GENERIC_WRITE,0,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);if(f==INVALID_HANDLE_VALUE)return false;
 DWORD wrote=0;bool ok=WriteFile(f,data.data(),DWORD(data.size()),&wrote,nullptr)&&wrote==data.size()&&FlushFileBuffers(f);CloseHandle(f);
 if(ok)ok=MoveFileExW(tmp.c_str(),path.c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH)!=0;
 if(!ok)DeleteFileW(tmp.c_str());
 return ok;
}
inline void quarantine(const std::wstring&path){MoveFileExW(path.c_str(),(path+L".corrupt").c_str(),MOVEFILE_REPLACE_EXISTING);}
inline std::wstring startupCommand(){return L"\""+executable()+L"\" --startup";}
inline bool startupEnabled(){HKEY key{};if(RegOpenKeyExW(HKEY_CURRENT_USER,L"Software\\Microsoft\\Windows\\CurrentVersion\\Run",0,KEY_QUERY_VALUE,&key)!=ERROR_SUCCESS)return false;
 wchar_t value[32768]{};DWORD type=0,size=sizeof(value);LONG result=RegQueryValueExW(key,L"EyeBreakReminder",nullptr,&type,reinterpret_cast<BYTE*>(value),&size);RegCloseKey(key);return result==ERROR_SUCCESS&&type==REG_SZ&&startupCommand()==value;}
inline bool setStartup(bool on){HKEY key{};if(RegCreateKeyExW(HKEY_CURRENT_USER,L"Software\\Microsoft\\Windows\\CurrentVersion\\Run",0,nullptr,0,KEY_SET_VALUE,nullptr,&key,nullptr)!=ERROR_SUCCESS)return false;
 auto command=startupCommand();LONG result=on?RegSetValueExW(key,L"EyeBreakReminder",0,REG_SZ,reinterpret_cast<const BYTE*>(command.c_str()),DWORD((command.size()+1)*sizeof(wchar_t))):RegDeleteValueW(key,L"EyeBreakReminder");RegCloseKey(key);return result==ERROR_SUCCESS||(!on&&result==ERROR_FILE_NOT_FOUND);}
struct Monitor {HMONITOR handle{};std::wstring device;RECT bounds{},work{};bool primary=false;};
inline std::vector<Monitor> monitors(){std::vector<Monitor> list;EnumDisplayMonitors(nullptr,nullptr,[](HMONITOR h,HDC,LPRECT,LPARAM p)->BOOL{MONITORINFOEXW info{};info.cbSize=sizeof(info);if(GetMonitorInfoW(h,&info))reinterpret_cast<std::vector<Monitor>*>(p)->push_back({h,info.szDevice,info.rcMonitor,info.rcWork,(info.dwFlags&MONITORINFOF_PRIMARY)!=0});return TRUE;},reinterpret_cast<LPARAM>(&list));return list;}
inline Monitor preferred(const Settings&s,HWND active){auto list=monitors();if(list.empty())return{};auto primary=std::find_if(list.begin(),list.end(),[](auto&m){return m.primary;});Monitor fallback=primary!=list.end()?*primary:list[0];
 if(s.monitor==1)return fallback;
 for(auto&m:list)if((s.monitor==2&&utf8(m.device)==s.selectedMonitor)||(s.monitor==0&&m.handle==MonitorFromWindow(active,MONITOR_DEFAULTTONEAREST)))return m;
 return fallback;}
inline int calendarDay(std::int64_t stamp){std::time_t t=std::time_t(stamp);std::tm tm{};localtime_s(&tm,&t);
 int y=tm.tm_year+1900,m=tm.tm_mon+1,d=tm.tm_mday;y-=m<=2;int era=(y>=0?y:y-399)/400;unsigned yo=unsigned(y-era*400),doy=(153*(m+(m>2?-3:9))+2)/5+d-1;return era*146097+int(yo*365+yo/4-yo/100+doy);}
inline std::wstring formatDate(std::int64_t stamp){std::time_t t=std::time_t(stamp);std::tm tm{};localtime_s(&tm,&t);wchar_t text[100]{};std::wcsftime(text,100,L"%x %H:%M",&tm);return text;}
inline std::wstring timeText(double remaining){int n=int(std::ceil(remaining));wchar_t text[32]{};swprintf(text,32,L"%02d:%02d",n/60,n%60);return text;}
inline bool confirm(HWND parent,const wchar_t*title,const wchar_t*message){TASKDIALOGCONFIG cfg{};cfg.cbSize=sizeof(cfg);cfg.hwndParent=parent;cfg.dwFlags=TDF_ALLOW_DIALOG_CANCELLATION|TDF_SIZE_TO_CONTENT;cfg.pszWindowTitle=L"Eye Break Reminder";cfg.pszMainInstruction=title;cfg.pszContent=message;cfg.dwCommonButtons=TDCBF_YES_BUTTON|TDCBF_CANCEL_BUTTON;cfg.nDefaultButton=IDCANCEL;int result=0;return SUCCEEDED(TaskDialogIndirect(&cfg,&result,nullptr,nullptr))&&result==IDYES;}
inline void inform(HWND parent,const wchar_t*title,const wchar_t*message){TaskDialog(parent,nullptr,L"Eye Break Reminder",title,message,TDCBF_OK_BUTTON,nullptr,nullptr);}
class Audio {
 HWAVEOUT device=nullptr;WAVEHDR header{};std::vector<BYTE> pcm;bool prepared=false;HWND window=nullptr;
public:
 bool playing=false,preview=false;std::function<void()> changed; // notified when playback starts or stops
 explicit Audio(HWND hwnd):window(hwnd){}
 void stop(){playing=false;if(device){waveOutReset(device);if(prepared)waveOutUnprepareHeader(device,&header,sizeof(header));waveOutClose(device);device=nullptr;}prepared=false;pcm.clear();header={};if(changed)changed();}
 bool play(const Settings&s,bool isPreview=false){
  stop();preview=isPreview;if(!s.alarm&&!preview)return true;
  auto resource=FindResourceW(nullptr,MAKEINTRESOURCEW(101+s.sound),RT_RCDATA);if(!resource)return false;auto loaded=LoadResource(nullptr,resource);auto bytes=static_cast<const BYTE*>(LockResource(loaded));DWORD length=SizeofResource(nullptr,resource);
  if(!bytes||length<44||memcmp(bytes,"RIFF",4)||memcmp(bytes+8,"WAVE",4))return false;
  WAVEFORMATEX format{};const BYTE*data=nullptr;DWORD dataSize=0;
  for(DWORD p=12;p+8<=length;){DWORD n=0;memcpy(&n,bytes+p+4,4);if(n>length-p-8)return false;
   if(!memcmp(bytes+p,"fmt ",4)&&n>=16){memcpy(&format,bytes+p+8,16);format.cbSize=0;}
   if(!memcmp(bytes+p,"data",4)){data=bytes+p+8;dataSize=n;}DWORD jump=8+n+(n&1);if(jump>length-p)break;p+=jump;}
  if(!data||format.wFormatTag!=WAVE_FORMAT_PCM||format.wBitsPerSample!=16||format.nChannels!=1||dataSize%2)return false;
  pcm.assign(data,data+dataSize);for(std::size_t i=0;i<pcm.size();i+=2){std::int16_t sample=0;memcpy(&sample,pcm.data()+i,2);sample=std::int16_t(int(sample)*s.volume/100);memcpy(pcm.data()+i,&sample,2);}
  if(waveOutOpen(&device,WAVE_MAPPER,&format,reinterpret_cast<DWORD_PTR>(window),0,CALLBACK_WINDOW)!=MMSYSERR_NOERROR){device=nullptr;return false;}
  header.lpData=reinterpret_cast<LPSTR>(pcm.data());header.dwBufferLength=DWORD(pcm.size());
  if(waveOutPrepareHeader(device,&header,sizeof(header))!=MMSYSERR_NOERROR){stop();return false;}prepared=true;
  if(waveOutWrite(device,&header,sizeof(header))!=MMSYSERR_NOERROR){stop();return false;}playing=true;if(changed)changed();return true;
 }
 bool done(WPARAM handle,LPARAM buffer){if(reinterpret_cast<HWAVEOUT>(handle)!=device||reinterpret_cast<WAVEHDR*>(buffer)!=&header||!(header.dwFlags&WHDR_DONE))return false;playing=false;if(changed)changed();return true;}
 ~Audio(){changed=nullptr;stop();}
};
}
