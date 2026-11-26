#pragma once

#include "windows_services.hpp"
#include "update_client.hpp"
#include "update_signature_win.hpp"
#include "update_accessibility.hpp"
#include <winver.h>
#include <atomic>
#include <array>
#include <cmath>
#include <algorithm>
#include <cwchar>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace eye::updates {

struct Transaction {
    std::wstring stagingDirectory,artifactPath,targetExecutable,dataDirectory,version,previousVersion,nonce;
    std::string kind,artifactName,sha256;
    DWORD ownerPid=0;
    std::uint64_t expectedSize=0;
    unsigned backupMask=0,ownedFileMask=0;
    std::string expectedApplicationSha256,previousSha256;
    std::array<std::string,3> backupSha256{};
    std::array<std::string,4> ownedFileSha256{};
    bool clean=false,deleteHistory=false,dark=false,forcedColors=false,previousStartup=false;
};

inline bool digestText(const std::string&value){return value.size()==64&&std::all_of(value.begin(),value.end(),[](unsigned char c){return (c>='0'&&c<='9')||(c>='a'&&c<='f');});}
// These hashes detect accidental or corrupt staged backups. The journal and backups share the user's profile ACL, so they are not authentication against code already running as that user.
inline bool backupDigestMetadataValid(const Transaction&t){
    for(unsigned i=0;i<t.backupSha256.size();++i){const bool present=(t.backupMask&(1u<<i))!=0;if(present?!digestText(t.backupSha256[i]):!t.backupSha256[i].empty())return false;}
    for(unsigned i=0;i<t.ownedFileSha256.size();++i){const bool present=(t.ownedFileMask&(1u<<i))!=0;if(present?!digestText(t.ownedFileSha256[i]):!t.ownedFileSha256[i].empty())return false;}
    return true;
}

inline std::wstring absolutePath(const std::wstring&path){std::vector<wchar_t>buffer(32768);DWORD n=GetFullPathNameW(path.c_str(),DWORD(buffer.size()),buffer.data(),nullptr);return n&&n<buffer.size()?std::wstring(buffer.data(),n):std::wstring{};}
inline bool samePath(const std::wstring&a,const std::wstring&b){auto x=absolutePath(a),y=absolutePath(b);return !x.empty()&&!y.empty()&&CompareStringOrdinal(x.c_str(),-1,y.c_str(),-1,TRUE)==CSTR_EQUAL;}
inline std::wstring parentPath(const std::wstring&path){auto at=path.find_last_of(L"\\/");return at==std::wstring::npos?L"":path.substr(0,at);}
inline bool safeFile(const std::wstring&path,std::uint64_t maximum=512ull*1024*1024){DWORD attr=GetFileAttributesW(path.c_str());if(attr==INVALID_FILE_ATTRIBUTES||(attr&FILE_ATTRIBUTE_DIRECTORY)||(attr&FILE_ATTRIBUTE_REPARSE_POINT))return false;WIN32_FILE_ATTRIBUTE_DATA data{};return GetFileAttributesExW(path.c_str(),GetFileExInfoStandard,&data)&&((std::uint64_t(data.nFileSizeHigh)<<32)|data.nFileSizeLow)<=maximum;}
inline bool localDataDirectory(std::wstring&out){
#ifdef EYEBREAK_TEST_BUILD
    wchar_t overridePath[32768]{};DWORD length=GetEnvironmentVariableW(L"EBR_GUI_TEST_DATA_DIRECTORY",overridePath,DWORD(std::size(overridePath)));if(length&&length<std::size(overridePath))out.assign(overridePath,length);else{out=eye::win::executable();const auto slash=out.find_last_of(L"\\/");if(slash==std::wstring::npos)return false;out.resize(slash+1);out+=L"test-data";}std::error_code ec;std::filesystem::create_directories(out,ec);return !ec&&safeStagingDirectory(out);
#else
    PWSTR raw=nullptr;if(FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData,0,nullptr,&raw)))return false;out=raw;CoTaskMemFree(raw);out+=L"\\EyeBreakReminder";return safeStagingDirectory(out);
#endif
}
inline std::wstring productVersion(const std::wstring&path){DWORD ignored=0,size=GetFileVersionInfoSizeW(path.c_str(),&ignored);if(!size||size>4*1024*1024)return{};std::vector<BYTE>data(size);if(!GetFileVersionInfoW(path.c_str(),0,size,data.data()))return{};VS_FIXEDFILEINFO*info=nullptr;UINT length=0;if(!VerQueryValueW(data.data(),L"\\",reinterpret_cast<void**>(&info),&length)||!info||length<sizeof(*info))return{};return std::to_wstring(HIWORD(info->dwProductVersionMS))+L"."+std::to_wstring(LOWORD(info->dwProductVersionMS))+L"."+std::to_wstring(HIWORD(info->dwProductVersionLS));}
inline bool hashFile(const std::wstring&path,std::string&out){
    HANDLE file=CreateFileW(path.c_str(),GENERIC_READ,FILE_SHARE_READ,nullptr,OPEN_EXISTING,FILE_FLAG_SEQUENTIAL_SCAN|FILE_FLAG_OPEN_REPARSE_POINT,nullptr);if(file==INVALID_HANDLE_VALUE)return false;
    FILE_ATTRIBUTE_TAG_INFO tag{};bool ok=GetFileInformationByHandleEx(file,FileAttributeTagInfo,&tag,sizeof(tag))&&!(tag.FileAttributes&FILE_ATTRIBUTE_REPARSE_POINT);
    BCRYPT_ALG_HANDLE algorithm{};BCRYPT_HASH_HANDLE hash{};DWORD objectSize=0,got=0;if(ok)ok=BCryptOpenAlgorithmProvider(&algorithm,BCRYPT_SHA256_ALGORITHM,nullptr,0)>=0&&BCryptGetProperty(algorithm,BCRYPT_OBJECT_LENGTH,reinterpret_cast<PUCHAR>(&objectSize),sizeof(objectSize),&got,0)>=0&&objectSize>0;
    std::vector<BYTE>object;if(ok){object.resize(objectSize);ok=BCryptCreateHash(algorithm,&hash,object.data(),objectSize,nullptr,0,0)>=0;}
    BYTE buffer[64*1024];DWORD read=0;while(ok){if(!ReadFile(file,buffer,sizeof(buffer),&read,nullptr)){ok=false;break;}if(!read)break;ok=BCryptHashData(hash,buffer,read,0)>=0;}
    if(ok){BYTE digest[32]{};ok=BCryptFinishHash(hash,digest,sizeof(digest),0)>=0;if(ok)out=client_detail::hex(digest,sizeof(digest));}
    if(hash)BCryptDestroyHash(hash);
    if(algorithm)BCryptCloseAlgorithmProvider(algorithm,0);
    CloseHandle(file);return ok;
}
inline bool writeJournal(const Transaction&t,const wchar_t*phase,const std::wstring&message={}){
    const std::wstring path=t.stagingDirectory+L"\\transaction-state.ini";
    if(!safeStagingDirectory(t.stagingDirectory))return false;
    const DWORD attributes=GetFileAttributesW(path.c_str());
    if(attributes==INVALID_FILE_ATTRIBUTES){if(GetLastError()!=ERROR_FILE_NOT_FOUND)return false;}
    else if(!safeFile(path,4096))return false;
    std::string content="phase="+eye::win::utf8(std::wstring(phase))+"\nmessage="+eye::win::utf8(message)+"\nversion="+eye::win::utf8(t.version)+"\nclean="+(t.clean?"1":"0")+"\ndeleteHistory="+(t.deleteHistory?"1":"0")+"\n";
    return eye::win::writeAtomic(path,content);
}
inline std::string transactionText(const Transaction&t){
    std::string text="staging="+eye::win::utf8(t.stagingDirectory)+"\nartifact="+eye::win::utf8(t.artifactPath)+"\ntarget="+eye::win::utf8(t.targetExecutable)+"\ndata="+eye::win::utf8(t.dataDirectory)+"\nversion="+eye::win::utf8(t.version)+"\nprevious="+eye::win::utf8(t.previousVersion)+"\nnonce="+eye::win::utf8(t.nonce)+"\nkind="+t.kind+"\nname="+t.artifactName+"\nsha256="+t.sha256+"\napplicationSha256="+t.expectedApplicationSha256+"\npreviousSha256="+t.previousSha256+"\nsize="+std::to_string(t.expectedSize)+"\nbackupMask="+std::to_string(t.backupMask)+"\nownedFileMask="+std::to_string(t.ownedFileMask)+"\npid="+std::to_string(t.ownerPid)+"\nclean="+(t.clean?"1":"0")+"\ndeleteHistory="+(t.deleteHistory?"1":"0")+"\ndark="+(t.dark?"1":"0")+"\nforcedColors="+(t.forcedColors?"1":"0")+"\npreviousStartup="+(t.previousStartup?"1":"0")+"\n";
    for(unsigned i=0;i<t.backupSha256.size();++i)text+="backupSha256"+std::to_string(i)+"="+t.backupSha256[i]+"\n";
    for(unsigned i=0;i<t.ownedFileSha256.size();++i)text+="ownedFileSha256"+std::to_string(i)+"="+t.ownedFileSha256[i]+"\n";
    return text;
}
inline bool writeTransaction(const Transaction&t){return eye::win::writeAtomic(t.stagingDirectory+L"\\transaction.ini",transactionText(t));}
inline bool readTransaction(const std::wstring&path,Transaction&out){
    if(!safeFile(path,32768))return false;
    std::string data;if(!eye::win::read(path,data,32768))return false;Transaction t;std::array<bool,28>seen{};std::istringstream input(data);std::string line;
    while(std::getline(input,line)){if(line.empty())continue;auto eq=line.find('=');if(eq==std::string::npos)return false;const auto key=line.substr(0,eq),value=line.substr(eq+1);auto setWide=[&](std::wstring&target,std::size_t index){if(seen[index])return false;seen[index]=true;target=eye::win::wide(value);return !target.empty()&&target.find_first_of(L"\r\n") == std::wstring::npos;};auto setBool=[&](bool&target,std::size_t index){if(seen[index]||(value!="0"&&value!="1"))return false;seen[index]=true;target=value=="1";return true;};auto setUint=[&](std::uint64_t&target,std::size_t index){if(seen[index]||value.empty())return false;seen[index]=true;try{std::size_t used=0;target=std::stoull(value,&used);return used==value.size();}catch(...){return false;}};
        if(key=="staging"){if(!setWide(t.stagingDirectory,0))return false;}else if(key=="artifact"){if(!setWide(t.artifactPath,1))return false;}else if(key=="target"){if(!setWide(t.targetExecutable,2))return false;}else if(key=="data"){if(!setWide(t.dataDirectory,3))return false;}else if(key=="version"){if(!setWide(t.version,4))return false;}else if(key=="previous"){if(!setWide(t.previousVersion,5))return false;}else if(key=="nonce"){if(!setWide(t.nonce,6))return false;}else if(key=="kind"){if(seen[7]||(value!="installed"&&value!="portable"))return false;seen[7]=true;t.kind=value;}else if(key=="name"){if(seen[8])return false;seen[8]=true;t.artifactName=value;}else if(key=="sha256"){if(seen[9]||value.size()!=64)return false;seen[9]=true;t.sha256=value;}else if(key=="applicationSha256"){if(seen[10]||value.size()!=64)return false;seen[10]=true;t.expectedApplicationSha256=value;}else if(key=="previousSha256"){if(seen[11]||value.size()!=64)return false;seen[11]=true;t.previousSha256=value;}else if(key=="size"){if(!setUint(t.expectedSize,12))return false;}else if(key=="backupMask"){std::uint64_t mask=0;if(!setUint(mask,13)||mask>7)return false;t.backupMask=unsigned(mask);}else if(key=="pid"){if(seen[14]||value.empty())return false;seen[14]=true;try{std::size_t used=0;auto n=std::stoul(value,&used);if(used!=value.size()||n==0||n>UINT32_MAX)return false;t.ownerPid=DWORD(n);}catch(...){return false;}}else if(key=="clean"){if(!setBool(t.clean,15))return false;}else if(key=="deleteHistory"){if(!setBool(t.deleteHistory,16))return false;}else if(key=="dark"){if(!setBool(t.dark,17))return false;}else if(key=="forcedColors"){if(!setBool(t.forcedColors,18))return false;}else if(key=="previousStartup"){if(!setBool(t.previousStartup,19))return false;}else if(key=="ownedFileMask"){std::uint64_t mask=0;if(!setUint(mask,20)||mask>15)return false;t.ownedFileMask=unsigned(mask);}else if(key=="backupSha256"+std::to_string(0)){if(seen[21]||(!value.empty()&&!digestText(value)))return false;seen[21]=true;t.backupSha256[0]=value;}else if(key=="backupSha256"+std::to_string(1)){if(seen[22]||(!value.empty()&&!digestText(value)))return false;seen[22]=true;t.backupSha256[1]=value;}else if(key=="backupSha256"+std::to_string(2)){if(seen[23]||(!value.empty()&&!digestText(value)))return false;seen[23]=true;t.backupSha256[2]=value;}else if(key=="ownedFileSha256"+std::to_string(0)){if(seen[24]||(!value.empty()&&!digestText(value)))return false;seen[24]=true;t.ownedFileSha256[0]=value;}else if(key=="ownedFileSha256"+std::to_string(1)){if(seen[25]||(!value.empty()&&!digestText(value)))return false;seen[25]=true;t.ownedFileSha256[1]=value;}else if(key=="ownedFileSha256"+std::to_string(2)){if(seen[26]||(!value.empty()&&!digestText(value)))return false;seen[26]=true;t.ownedFileSha256[2]=value;}else if(key=="ownedFileSha256"+std::to_string(3)){if(seen[27]||(!value.empty()&&!digestText(value)))return false;seen[27]=true;t.ownedFileSha256[3]=value;}else return false;
    }
    if(!std::all_of(seen.begin(),seen.end(),[](bool value){return value;})||!backupDigestMetadataValid(t))return false;
    out=std::move(t);return true;
}
inline bool registeredInstallDirectory(std::wstring&out){HKEY key{};if(RegOpenKeyExW(HKEY_CURRENT_USER,L"Software\\EyeBreakReminder",0,KEY_QUERY_VALUE,&key)!=ERROR_SUCCESS)return false;wchar_t value[32768]{};DWORD type=0,bytes=sizeof(value);LONG result=RegQueryValueExW(key,L"InstallDir",nullptr,&type,reinterpret_cast<BYTE*>(value),&bytes);RegCloseKey(key);if(result!=ERROR_SUCCESS||type!=REG_SZ||!value[0])return false;out=value;return true;}
inline bool validateTransaction(const Transaction&t,const std::wstring&transactionPath,const std::wstring&coordinatorPath,std::string&error,ManifestUse use=ManifestUse::Install){
    Version newer,older;if(!detail::parseVersion(eye::win::utf8(t.version),newer)||!detail::parseVersion(eye::win::utf8(t.previousVersion),older)||detail::compare(newer,older)<=0){error="The update transaction has invalid or non-upgrading version metadata.";return false;}
    if(!safeStagingDirectory(t.stagingDirectory)||!samePath(transactionPath,t.stagingDirectory+L"\\transaction.ini")||!samePath(coordinatorPath,t.stagingDirectory+L"\\coordinator.exe")){error="The update staging path failed its safety checks.";return false;}
    std::wstring expectedData;if(!localDataDirectory(expectedData)||!samePath(t.dataDirectory,expectedData)||!samePath(parentPath(t.stagingDirectory),expectedData+L"\\updates")){error="The update data path is outside this Windows user's Eye Break Reminder profile.";return false;}
    const std::wstring wantedName=t.kind=="installed"?L"EyeBreakReminder-Setup-x64.exe":L"EyeBreakReminder.exe";
    if(t.artifactName!=(t.kind=="installed"?"EyeBreakReminder-Setup-x64.exe":"EyeBreakReminder.exe")||!samePath(t.artifactPath,t.stagingDirectory+L"\\"+wantedName)){error="The update transaction selected an unsupported package.";return false;}
    if(t.kind=="installed"&&!samePath(t.targetExecutable,parentPath(t.targetExecutable)+L"\\EyeBreakReminder.exe")){error="The installed application path is invalid.";return false;}
    if(t.kind=="portable"&&!samePath(t.targetExecutable,parentPath(t.targetExecutable)+L"\\EyeBreakReminder.exe")){error="The portable application path is invalid.";return false;}
    std::wstring installDir;const bool isRegistered=registeredInstallDirectory(installDir)&&samePath(installDir,parentPath(t.targetExecutable));
    if((t.kind=="installed")!=isRegistered){error="The installation type changed while the update was being prepared.";return false;}
    if(!safeStagingDirectory(parentPath(t.targetExecutable))){error="The application folder is not safe to update.";return false;}
    const DWORD targetAttributes=GetFileAttributesW(t.targetExecutable.c_str());
    if(targetAttributes==INVALID_FILE_ATTRIBUTES){if(use!=ManifestUse::Recover||GetLastError()!=ERROR_FILE_NOT_FOUND){error="The application executable is missing or inaccessible.";return false;}}
    else if((targetAttributes&(FILE_ATTRIBUTE_DIRECTORY|FILE_ATTRIBUTE_REPARSE_POINT))||!safeFile(t.targetExecutable)){error="The current application executable is not a regular file.";return false;}
    if(t.kind=="installed"&&!samePath(t.artifactPath,t.stagingDirectory+L"\\EyeBreakReminder-Setup-x64.exe")){error="The downloaded installer is not in the private staging folder.";return false;}
    if(t.nonce.size()!=36||t.nonce.find_first_not_of(L"0123456789abcdefABCDEF-")!=std::wstring::npos){error="The update confirmation token is invalid.";return false;}
    if(!digestText(t.sha256)||!digestText(t.expectedApplicationSha256)||!digestText(t.previousSha256)||t.expectedSize==0||t.expectedSize>100ull*1024*1024||t.backupMask>7||t.ownedFileMask>15||!backupDigestMetadataValid(t)||(t.deleteHistory&&!t.clean)){error="The update integrity or backup metadata is invalid.";return false;}
    std::string manifestBytes,signatureBytes;
    if(!eye::win::read(t.stagingDirectory+L"\\EyeBreakReminder-UpdateManifest.json",manifestBytes,16384)||
       !eye::win::read(t.stagingDirectory+L"\\EyeBreakReminder-UpdateManifest.sig",signatureBytes,64)){
        error="The publisher-signed update manifest or signature is missing or unreadable.";return false;
    }
    const std::string signedReleaseTag="v"+eye::win::utf8(t.version);
    const auto authorization=verifyStagedManifest(manifestBytes,signatureBytes,t.stagingDirectory,signedReleaseTag,eye::win::utf8(t.previousVersion),std::time(nullptr),use);
    if(!authorization.ok){error=authorization.error;return false;}
    const auto*installer=manifestAsset(authorization.manifest,true);const auto*portable=manifestAsset(authorization.manifest,false);
    const auto*selected=t.kind=="installed"?installer:portable;
    if(!selected||authorization.manifest.version!=eye::win::utf8(t.version)||selected->name!=t.artifactName||
       selected->size!=t.expectedSize||selected->sha256!=t.sha256||!portable||portable->sha256!=t.expectedApplicationSha256){
        error="The update transaction does not match a payload authorized by the signed manifest.";return false;
    }
    return true;
}
inline bool installedTargetIsNewerThanTransaction(const Transaction&t){
    const auto installed=productVersion(t.targetExecutable);
    if(installed.empty())return false;
    Version current,transaction;
    return detail::parseVersion(eye::win::utf8(installed),current)&&
        detail::parseVersion(eye::win::utf8(t.version),transaction)&&
        detail::compare(current,transaction)>0;
}

struct UiState {std::mutex mutex;std::wstring message=L"Preparing the update…";std::atomic_bool done{false};bool success=false,dark=false,forcedColors=false,completionShown=false;int marqueePhase=0;HWND window{},heading{},status{},progress{},close{};HBRUSH background{};HFONT normalFont{},headingFont{};COLORREF foreground{},accent{},buttonText{};UINT dpi=96;double textScale=1.0;};
inline constexpr wchar_t CoordinatorWindowClass[]=L"EyeBreakReminder.UpdateCoordinator";
inline constexpr int CoordinatorStatus=1,CoordinatorProgress=2,CoordinatorClose=3;
inline int coordinatorPx(const UiState&state,int value){return std::max(1,MulDiv(value,int(state.dpi),96));}
inline int coordinatorWindowWidth(const UiState&state){return coordinatorPx(state,int(std::lround(640+40*(state.textScale-1.0))));}
inline int coordinatorWindowHeight(const UiState&state){return coordinatorPx(state,int(std::lround(340+80*(state.textScale-1.0))));}
inline double coordinatorTextScale(){DWORD scale=100,size=sizeof(scale);if(RegGetValueW(HKEY_CURRENT_USER,L"Software\\Microsoft\\Accessibility",L"TextScaleFactor",RRF_RT_REG_DWORD,nullptr,&scale,&size)!=ERROR_SUCCESS)scale=100;return std::clamp(scale/100.0,1.0,2.25);}
inline void coordinatorCreateFonts(UiState&state){if(state.normalFont)DeleteObject(state.normalFont);if(state.headingFont)DeleteObject(state.headingFont);state.textScale=coordinatorTextScale();auto height=[&](double points){return -std::max(1,int(std::lround(points*double(state.dpi)/72.0*state.textScale)));};state.normalFont=CreateFontW(height(11),0,0,0,FW_NORMAL,FALSE,FALSE,FALSE,DEFAULT_CHARSET,OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,CLEARTYPE_QUALITY,DEFAULT_PITCH,L"Segoe UI Variable");state.headingFont=CreateFontW(height(15),0,0,0,FW_SEMIBOLD,FALSE,FALSE,FALSE,DEFAULT_CHARSET,OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,CLEARTYPE_QUALITY,DEFAULT_PITCH,L"Segoe UI Variable");}
inline int coordinatorStatusHeight(HWND hwnd,UiState&state,int width){RECT bounds{0,0,width,0};wchar_t text[2048]{};GetWindowTextW(state.status,text,int(std::size(text)));HDC dc=GetDC(hwnd);if(!dc)return coordinatorPx(state,104);auto previous=SelectObject(dc,state.normalFont);DrawTextW(dc,text,-1,&bounds,DT_CALCRECT|DT_WORDBREAK|DT_NOPREFIX|DT_EDITCONTROL);SelectObject(dc,previous);ReleaseDC(hwnd,dc);return std::max(coordinatorPx(state,74),int(bounds.bottom-bounds.top)+coordinatorPx(state,8));}
inline void coordinatorLayout(HWND hwnd,UiState&state){RECT client{};GetClientRect(hwnd,&client);const int pad=coordinatorPx(state,24),inner=std::max(160,int(client.right)-2*pad),buttonH=std::max(coordinatorPx(state,36),coordinatorPx(state,int(std::lround(30*state.textScale)))),headingHeight=std::max(coordinatorPx(state,30),coordinatorPx(state,int(std::lround(30*state.textScale)))),statusTop=pad+headingHeight+coordinatorPx(state,10),statusHeight=coordinatorStatusHeight(hwnd,state,inner);MoveWindow(state.heading,pad,pad,inner,headingHeight,TRUE);MoveWindow(state.status,pad,statusTop,inner,statusHeight,TRUE);MoveWindow(state.progress,pad,statusTop+statusHeight+coordinatorPx(state,12),inner,coordinatorPx(state,20),TRUE);MoveWindow(state.close,int(client.right)-pad-coordinatorPx(state,112),int(client.bottom)-pad-buttonH,coordinatorPx(state,112),buttonH,TRUE);}
inline void drawCoordinatorClose(UiState&state,DRAWITEMSTRUCT*draw){if(!draw||draw->CtlID!=CoordinatorClose)return;const bool enabled=IsWindowEnabled(draw->hwndItem)!=FALSE,pressed=(draw->itemState&ODS_SELECTED)!=0,focused=(draw->itemState&ODS_FOCUS)!=0;COLORREF fill=state.forcedColors?GetSysColor(COLOR_HIGHLIGHT):state.accent,ink=state.forcedColors?GetSysColor(COLOR_HIGHLIGHTTEXT):state.buttonText;if(!enabled){fill=GetSysColor(COLOR_BTNFACE);ink=GetSysColor(COLOR_GRAYTEXT);}if(pressed&&!state.forcedColors)fill=RGB(45,110,220);RECT r=draw->rcItem;InflateRect(&r,-1,-1);HBRUSH brush=CreateSolidBrush(fill);HPEN pen=CreatePen(PS_SOLID,1,state.forcedColors?GetSysColor(COLOR_WINDOWTEXT):fill);int saved=SaveDC(draw->hDC);HGDIOBJ oldBrush=SelectObject(draw->hDC,brush),oldPen=SelectObject(draw->hDC,pen);RoundRect(draw->hDC,r.left,r.top,r.right,r.bottom,coordinatorPx(state,14),coordinatorPx(state,14));SelectObject(draw->hDC,oldBrush);SelectObject(draw->hDC,oldPen);DeleteObject(brush);DeleteObject(pen);SetBkMode(draw->hDC,TRANSPARENT);SetTextColor(draw->hDC,ink);SelectObject(draw->hDC,reinterpret_cast<HFONT>(SendMessageW(draw->hwndItem,WM_GETFONT,0,0)));wchar_t caption[128]{};GetWindowTextW(draw->hwndItem,caption,int(std::size(caption)));DrawTextW(draw->hDC,caption,-1,&r,DT_CENTER|DT_VCENTER|DT_SINGLELINE|DT_NOPREFIX);if(focused){InflateRect(&r,-coordinatorPx(state,5),-coordinatorPx(state,5));DrawFocusRect(draw->hDC,&r);}RestoreDC(draw->hDC,saved);}
inline void paintCoordinatorProgress(UiState&state,HWND hwnd){PAINTSTRUCT paint{};HDC dc=BeginPaint(hwnd,&paint);if(!dc)return;RECT rect{};GetClientRect(hwnd,&rect);InflateRect(&rect,-1,-1);const int width=rect.right-rect.left,height=rect.bottom-rect.top;if(width>0&&height>0){const COLORREF track=state.dark?RGB(43,47,55):RGB(229,233,239),borderColor=state.dark?RGB(70,76,87):RGB(190,197,207),successColor=RGB(34,197,94);HBRUSH brush=CreateSolidBrush(track);HPEN pen=CreatePen(PS_SOLID,1,borderColor);int saved=SaveDC(dc);HGDIOBJ oldBrush=SelectObject(dc,brush),oldPen=SelectObject(dc,pen);RoundRect(dc,rect.left,rect.top,rect.right,rect.bottom,height,height);SelectObject(dc,oldBrush);SelectObject(dc,oldPen);DeleteObject(brush);DeleteObject(pen);const int innerWidth=std::max(0,width-2),innerHeight=std::max(1,height-2),segmentWidth=std::max(1,innerWidth/3);int left=0,fillWidth=0;COLORREF fillColor=state.accent;if(state.done.load()){if(state.success){fillWidth=innerWidth;fillColor=successColor;}}else{const int travel=std::max(1,innerWidth-segmentWidth),period=travel*2,phase=period?state.marqueePhase%period:0;left=phase<=travel?phase:period-phase;fillWidth=segmentWidth;}if(fillWidth>0){HBRUSH fill=CreateSolidBrush(fillColor);HPEN fillPen=CreatePen(PS_SOLID,1,fillColor);HGDIOBJ oldFill=SelectObject(dc,fill),oldFillPen=SelectObject(dc,fillPen);const int x=rect.left+1+left,y=rect.top+1;RoundRect(dc,x,y,x+fillWidth,y+innerHeight,std::min(fillWidth,innerHeight),innerHeight);SelectObject(dc,oldFill);SelectObject(dc,oldFillPen);DeleteObject(fill);DeleteObject(fillPen);}RestoreDC(dc,saved);}EndPaint(hwnd,&paint);}
inline LRESULT CALLBACK coordinatorProgressProc(HWND hwnd,UINT message,WPARAM w,LPARAM l,UINT_PTR subclass,DWORD_PTR reference){auto*state=reinterpret_cast<UiState*>(reference);if(message==WM_ERASEBKGND)return 1;if(message==WM_PAINT&&state){paintCoordinatorProgress(*state,hwnd);return 0;}if(message==WM_NCDESTROY)RemoveWindowSubclass(hwnd,coordinatorProgressProc,subclass);return DefSubclassProc(hwnd,message,w,l);}
inline LRESULT CALLBACK coordinatorWindowProc(HWND hwnd,UINT message,WPARAM w,LPARAM l){
    auto*state=reinterpret_cast<UiState*>(GetWindowLongPtrW(hwnd,GWLP_USERDATA));
    if(message==WM_NCCREATE){auto*create=reinterpret_cast<CREATESTRUCTW*>(l);state=static_cast<UiState*>(create->lpCreateParams);if(!state)return FALSE;state->window=hwnd;state->dpi=GetDpiForWindow(hwnd);SetWindowLongPtrW(hwnd,GWLP_USERDATA,reinterpret_cast<LONG_PTR>(state));}
    if(!state)return DefWindowProcW(hwnd,message,w,l);
    switch(message){
    case WM_CREATE:{
        if(state->forcedColors){state->foreground=GetSysColor(COLOR_WINDOWTEXT);state->accent=GetSysColor(COLOR_HIGHLIGHT);state->buttonText=GetSysColor(COLOR_HIGHLIGHTTEXT);}
        else if(state->dark){state->foreground=RGB(239,243,249);state->accent=RGB(96,165,250);state->buttonText=RGB(15,28,46);}
        else{state->foreground=RGB(24,30,42);state->accent=RGB(29,78,216);state->buttonText=RGB(255,255,255);}
        const COLORREF background=state->forcedColors?GetSysColor(COLOR_WINDOW):(state->dark?RGB(26,29,35):RGB(247,248,250));state->background=CreateSolidBrush(background);coordinatorCreateFonts(*state);
        state->heading=CreateWindowExW(0,L"STATIC",L"Updating Eye Break Reminder",WS_CHILD|WS_VISIBLE|SS_LEFT|SS_NOPREFIX,0,0,1,1,hwnd,reinterpret_cast<HMENU>(INT_PTR(CoordinatorStatus+10)),GetModuleHandleW(nullptr),nullptr);
        state->status=CreateWindowExW(0,L"STATIC",L"Preparing the update…",WS_CHILD|WS_VISIBLE|SS_LEFT|SS_NOPREFIX|SS_EDITCONTROL,0,0,1,1,hwnd,reinterpret_cast<HMENU>(INT_PTR(CoordinatorStatus)),GetModuleHandleW(nullptr),nullptr);
        state->progress=CreateWindowExW(0,PROGRESS_CLASSW,L"Installation progress",WS_CHILD|WS_VISIBLE|PBS_MARQUEE|PBS_SMOOTH,0,0,1,1,hwnd,reinterpret_cast<HMENU>(INT_PTR(CoordinatorProgress)),GetModuleHandleW(nullptr),nullptr);
        if(state->progress&&!state->forcedColors&&!SetWindowSubclass(state->progress,coordinatorProgressProc,0xEB1422,reinterpret_cast<DWORD_PTR>(state)))return -1;
        state->close=CreateWindowExW(0,L"BUTTON",L"Close",WS_CHILD|WS_VISIBLE|WS_TABSTOP|BS_OWNERDRAW,0,0,1,1,hwnd,reinterpret_cast<HMENU>(INT_PTR(CoordinatorClose)),GetModuleHandleW(nullptr),nullptr);
        if(state->heading){SendMessageW(state->heading,WM_SETFONT,reinterpret_cast<WPARAM>(state->headingFont),FALSE);}
        if(state->status){SendMessageW(state->status,WM_SETFONT,reinterpret_cast<WPARAM>(state->normalFont),FALSE);}
        if(state->progress){SendMessageW(state->progress,WM_SETFONT,reinterpret_cast<WPARAM>(state->normalFont),FALSE);}
        if(state->close){SendMessageW(state->close,WM_SETFONT,reinterpret_cast<WPARAM>(state->normalFont),FALSE);}
        if(!state->heading||!state->status||!state->progress||!state->close||!state->background||!state->normalFont||!state->headingFont||!update_accessibility::attach(state->heading,update_accessibility::Kind::Text)||!update_accessibility::attach(state->status,update_accessibility::Kind::Text)||!update_accessibility::attachActivityProgress(state->progress,L"Installation progress")||!update_accessibility::attach(state->close,update_accessibility::Kind::Button,true))return -1;
        SendMessageW(state->progress,PBM_SETRANGE32,0,1000);SendMessageW(state->progress,PBM_SETMARQUEE,TRUE,80);EnableWindow(state->close,FALSE);SetWindowPos(hwnd,nullptr,0,0,coordinatorWindowWidth(*state),coordinatorWindowHeight(*state),SWP_NOMOVE|SWP_NOZORDER|SWP_NOACTIVATE);SetTimer(hwnd,1,150,nullptr);return 0;
    }
    case WM_SIZE:coordinatorLayout(hwnd,*state);return 0;
    case WM_DPICHANGED:{state->dpi=HIWORD(w);coordinatorCreateFonts(*state);for(HWND child:{state->heading,state->status,state->progress,state->close})if(child)SendMessageW(child,WM_SETFONT,reinterpret_cast<WPARAM>(child==state->heading?state->headingFont:state->normalFont),TRUE);auto*rect=reinterpret_cast<RECT*>(l);SetWindowPos(hwnd,nullptr,rect->left,rect->top,rect->right-rect->left,rect->bottom-rect->top,SWP_NOZORDER|SWP_NOACTIVATE);coordinatorLayout(hwnd,*state);return 0;}
    case WM_TIMER:{std::wstring messageText;{std::lock_guard<std::mutex>lock(state->mutex);messageText=state->message;}const int currentLength=GetWindowTextLengthW(state->status);std::wstring current(std::size_t(std::max(0,currentLength))+1,L'\0');GetWindowTextW(state->status,current.data(),int(current.size()));current.resize(std::wcslen(current.c_str()));if(current!=messageText){SetWindowTextW(state->status,messageText.c_str());coordinatorLayout(hwnd,*state);}if(!state->done.load()){state->marqueePhase+=24;RECT progressRect{};GetClientRect(state->progress,&progressRect);const int cycle=std::max(1,int(progressRect.right-progressRect.left)*2);if(state->marqueePhase>=cycle)state->marqueePhase%=cycle;InvalidateRect(state->progress,nullptr,FALSE);}if(state->done.load()&&!state->completionShown){state->completionShown=true;SendMessageW(state->progress,PBM_SETMARQUEE,FALSE,0);LONG_PTR style=GetWindowLongPtrW(state->progress,GWL_STYLE);SetWindowLongPtrW(state->progress,GWL_STYLE,style&~PBS_MARQUEE);SetWindowPos(state->progress,nullptr,0,0,0,0,SWP_NOMOVE|SWP_NOSIZE|SWP_NOZORDER|SWP_NOACTIVATE|SWP_FRAMECHANGED);SendMessageW(state->progress,PBM_SETRANGE32,0,1000);SendMessageW(state->progress,PBM_SETSTATE,state->success?PBST_NORMAL:PBST_ERROR,0);SendMessageW(state->progress,PBM_SETPOS,state->success?1000:0,0);InvalidateRect(state->progress,nullptr,TRUE);EnableWindow(state->close,TRUE);SetFocus(state->close);}return 0;}
    case WM_ERASEBKGND:{RECT client{};GetClientRect(hwnd,&client);FillRect(reinterpret_cast<HDC>(w),&client,state->background);return 1;}
    case WM_CTLCOLORSTATIC:{HDC dc=reinterpret_cast<HDC>(w);SetTextColor(dc,state->forcedColors?GetSysColor(COLOR_WINDOWTEXT):state->foreground);SetBkColor(dc,state->forcedColors?GetSysColor(COLOR_WINDOW):(state->dark?RGB(26,29,35):RGB(247,248,250)));SetBkMode(dc,TRANSPARENT);return reinterpret_cast<LRESULT>(state->background);}
    case WM_DRAWITEM:if(LOWORD(w)==CoordinatorClose){drawCoordinatorClose(*state,reinterpret_cast<DRAWITEMSTRUCT*>(l));return TRUE;}return FALSE;
    case WM_COMMAND:if(LOWORD(w)==CoordinatorClose&&state->done.load()){DestroyWindow(hwnd);return 0;}return 0;
    case WM_CLOSE:if(state->done.load())DestroyWindow(hwnd);return 0;
    case WM_DESTROY:KillTimer(hwnd,1);PostQuitMessage(0);return 0;
    case WM_NCDESTROY:{LRESULT result=DefWindowProcW(hwnd,message,w,l);if(state->background)DeleteObject(state->background);if(state->normalFont)DeleteObject(state->normalFont);if(state->headingFont)DeleteObject(state->headingFont);state->background=nullptr;state->normalFont=state->headingFont=nullptr;state->window=nullptr;SetWindowLongPtrW(hwnd,GWLP_USERDATA,0);return result;}
    }
    return DefWindowProcW(hwnd,message,w,l);
}
inline void coordinatorMessage(UiState&state,const std::wstring&text){std::lock_guard<std::mutex>lock(state.mutex);state.message=text;}
inline std::wstring quoteArgument(const std::wstring&value){std::wstring out=L"\"";unsigned slashes=0;for(wchar_t c:value){if(c==L'\\'){++slashes;continue;}if(c==L'\"'){out.append(slashes*2+1,L'\\');out.push_back(c);}else{out.append(slashes,L'\\');out.push_back(c);}slashes=0;}out.append(slashes*2,L'\\');out.push_back(L'\"');return out;}
inline DWORD confirmationWaitMilliseconds(){
#ifdef EYEBREAK_TEST_BUILD
    wchar_t text[16]{};DWORD length=GetEnvironmentVariableW(L"EBR_GUI_TEST_CONFIRM_TIMEOUT_MS",text,DWORD(std::size(text)));if(length&&length<std::size(text)){wchar_t*end=nullptr;unsigned long value=std::wcstoul(text,&end,10);if(end&&!*end&&value>=1000&&value<=10000)return DWORD(value);}
#endif
    return 45000;
}
#ifdef EYEBREAK_TEST_BUILD
inline std::atomic<unsigned> TestProcessLaunchAttempts{0};
#endif
inline bool launchProcess(const std::wstring&image,const std::wstring&arguments,PROCESS_INFORMATION&pi){
#ifdef EYEBREAK_TEST_BUILD
    TestProcessLaunchAttempts.fetch_add(1,std::memory_order_relaxed);
#endif
    STARTUPINFOW si{};si.cb=sizeof(si);std::wstring command=quoteArgument(image)+(arguments.empty()?L"":L" "+arguments);return CreateProcessW(image.c_str(),command.data(),nullptr,nullptr,FALSE,CREATE_UNICODE_ENVIRONMENT,nullptr,parentPath(image).c_str(),&si,&pi)!=FALSE;
}
inline bool writeVersionRegistry(const std::wstring&version){HKEY key{};if(RegOpenKeyExW(HKEY_CURRENT_USER,L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\EyeBreakReminder",0,KEY_SET_VALUE,&key)!=ERROR_SUCCESS)return false;LONG result=RegSetValueExW(key,L"DisplayVersion",0,REG_SZ,reinterpret_cast<const BYTE*>(version.c_str()),DWORD((version.size()+1)*sizeof(wchar_t)));RegCloseKey(key);return result==ERROR_SUCCESS;}
inline bool setStartupRegistration(const Transaction&t,bool enabled){
    HKEY key{};if(RegCreateKeyExW(HKEY_CURRENT_USER,L"Software\\Microsoft\\Windows\\CurrentVersion\\Run",0,nullptr,0,KEY_QUERY_VALUE|KEY_SET_VALUE,nullptr,&key,nullptr)!=ERROR_SUCCESS)return false;
    const std::wstring expected=L"\""+t.targetExecutable+L"\" --startup";bool ok=true;
    if(enabled)ok=RegSetValueExW(key,L"EyeBreakReminder",0,REG_SZ,reinterpret_cast<const BYTE*>(expected.c_str()),DWORD((expected.size()+1)*sizeof(wchar_t)))==ERROR_SUCCESS;
    else{wchar_t value[32768]{};DWORD type=0,bytes=sizeof(value);LONG result=RegQueryValueExW(key,L"EyeBreakReminder",nullptr,&type,reinterpret_cast<BYTE*>(value),&bytes);if(result==ERROR_SUCCESS&&type==REG_SZ&&expected==value)ok=RegDeleteValueW(key,L"EyeBreakReminder")==ERROR_SUCCESS;else if(result!=ERROR_SUCCESS&&result!=ERROR_FILE_NOT_FOUND)ok=false;}
    RegCloseKey(key);return ok;
}
inline std::wstring quoteArgument(const std::wstring&value);
inline std::wstring recoveryCommand(const std::wstring&stage){
    constexpr std::size_t maxRunOnceCommand=260;
    const auto compact=quoteArgument(stage+L"\\coordinator.exe")+L" --update-recover";
    const auto explicitPath=compact+L" "+quoteArgument(stage+L"\\transaction.ini");
    if(explicitPath.size()<=maxRunOnceCommand)return explicitPath;
    return compact.size()<=maxRunOnceCommand?compact:std::wstring{};
}
inline bool recoveryRegistrationValueMatches(const Transaction&t,const std::wstring&value){
    const auto command=recoveryCommand(t.stagingDirectory);
    const auto legacyCommand=quoteArgument(t.stagingDirectory+L"\\coordinator.exe")+L" --update-recover "+
        quoteArgument(t.stagingDirectory+L"\\transaction.ini");
    return (!command.empty()&&value==command)||value==legacyCommand;
}
inline bool recoveryRegistrationMatches(const Transaction&t){
    HKEY key{};if(RegOpenKeyExW(HKEY_CURRENT_USER,L"Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce",0,KEY_QUERY_VALUE,&key)!=ERROR_SUCCESS)return false;
    wchar_t existing[32768]{};DWORD type=0,bytes=sizeof(existing);
    const LONG query=RegQueryValueExW(key,L"!EyeBreakReminderUpdateRecovery",nullptr,&type,reinterpret_cast<BYTE*>(existing),&bytes);
    RegCloseKey(key);
    if(query!=ERROR_SUCCESS||type!=REG_SZ||bytes<sizeof(wchar_t)||bytes%sizeof(wchar_t)!=0||bytes>sizeof(existing)||existing[bytes/sizeof(wchar_t)-1]!=L'\0')return false;
    return recoveryRegistrationValueMatches(t,std::wstring(existing,bytes/sizeof(wchar_t)-1));
}
inline bool recoveryRegistrationWriteNeeded(bool enabled,bool owned,LONG query){
    return enabled&&!owned&&query==ERROR_FILE_NOT_FOUND;
}
inline bool setRecoveryRegistration(const Transaction&t,bool enabled){
    const auto command=recoveryCommand(t.stagingDirectory);
    if(enabled&&command.empty())return false;
    const auto legacyCommand=quoteArgument(t.stagingDirectory+L"\\coordinator.exe")+L" --update-recover "+
        quoteArgument(t.stagingDirectory+L"\\transaction.ini");
    HKEY key{};
    if(RegCreateKeyExW(HKEY_CURRENT_USER,L"Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce",0,nullptr,0,
                       KEY_QUERY_VALUE|KEY_SET_VALUE,nullptr,&key,nullptr)!=ERROR_SUCCESS)return false;
    constexpr wchar_t name[]=L"!EyeBreakReminderUpdateRecovery";
    wchar_t existing[32768]{};
    DWORD type=0,bytes=sizeof(existing);
    const LONG query=RegQueryValueExW(key,name,nullptr,&type,reinterpret_cast<BYTE*>(existing),&bytes);
    const DWORD commandBytes=DWORD((command.size()+1)*sizeof(wchar_t));
    const auto matches=[&](const std::wstring&value){
        return bytes==(value.size()+1)*sizeof(wchar_t)&&
            std::equal(value.c_str(),value.c_str()+value.size()+1,existing);
    };
    const bool owned=query==ERROR_SUCCESS&&type==REG_SZ&&
        ((!command.empty()&&matches(command))||matches(legacyCommand));
    bool ok=false;
    if(enabled)
        ok=owned||(recoveryRegistrationWriteNeeded(enabled,owned,query)&&
            RegSetValueExW(key,name,0,REG_SZ,reinterpret_cast<const BYTE*>(command.c_str()),commandBytes)==ERROR_SUCCESS);
    else if(!enabled)
        ok=query==ERROR_FILE_NOT_FOUND||(owned&&RegDeleteValueW(key,name)==ERROR_SUCCESS);
    RegCloseKey(key);
    return ok;
}
inline bool recoveryRegistrationAbsent(){HKEY key{};LONG open=RegOpenKeyExW(HKEY_CURRENT_USER,L"Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce",0,KEY_QUERY_VALUE,&key);if(open==ERROR_FILE_NOT_FOUND)return true;if(open!=ERROR_SUCCESS)return false;DWORD type=0,bytes=0;LONG result=RegQueryValueExW(key,L"!EyeBreakReminderUpdateRecovery",nullptr,&type,nullptr,&bytes);RegCloseKey(key);return result==ERROR_FILE_NOT_FOUND;}
inline bool acquireCoordinatorMutex(HANDLE&mutex,const wchar_t*name=L"Local\\EyeBreakReminder.UpdateCoordinator.1"){
    mutex=CreateMutexW(nullptr,FALSE,name);if(!mutex)return false;
    if(GetLastError()==ERROR_ALREADY_EXISTS){CloseHandle(mutex);mutex=nullptr;return false;}
    return true;
}
inline std::wstring journalPhase(const Transaction&t){
    const auto path=t.stagingDirectory+L"\\transaction-state.ini";
    if(!safeFile(path,4096))return{};
    std::string data;if(!eye::win::read(path,data,4096))return{};
    std::istringstream input(data);std::array<std::string,5>lines{};
    for(auto&line:lines)if(!std::getline(input,line))return{};
    std::string extra;if(std::getline(input,extra))return{};
    const std::string version="version="+eye::win::utf8(t.version);
    const std::string clean=std::string("clean=")+(t.clean?"1":"0");
    const std::string deleteHistory=std::string("deleteHistory=")+(t.deleteHistory?"1":"0");
    if(lines[0].compare(0,6,"phase=")!=0||lines[1].compare(0,8,"message=")!=0||
       lines[2]!=version||lines[3]!=clean||lines[4]!=deleteHistory)return{};
    const auto phase=lines[0].substr(6);
    static const std::array<std::string,8>allowed={"waiting","verified","installing","installed","cleaning","starting","complete","recovered"};
    if(std::find(allowed.begin(),allowed.end(),phase)==allowed.end())return{};
    return eye::win::wide(phase);
}
inline bool cleanupTransactionIsCurrent(const std::wstring&stage,const std::wstring&applicationPath){
    if(!safeStagingDirectory(stage))return false;
    const auto transactionPath=stage+L"\\transaction.ini";
    Transaction t;if(!readTransaction(transactionPath,t))return false;
    std::string error;
    if(!validateTransaction(t,transactionPath,stage+L"\\coordinator.exe",error,ManifestUse::Recover)||
       !samePath(applicationPath,t.targetExecutable))return false;
    const auto phase=journalPhase(t);
    std::string digest;
    if(phase==L"complete")
        return productVersion(t.targetExecutable)==t.version&&hashFile(t.targetExecutable,digest)&&digest==t.expectedApplicationSha256;
    if(phase==L"recovered"||phase==L"verified"||phase==L"waiting")
        return productVersion(t.targetExecutable)==t.previousVersion&&hashFile(t.targetExecutable,digest)&&digest==t.previousSha256;
    return false;
}
inline bool backupData(Transaction&t){
    const wchar_t*names[]={L"settings.ini",L"timer.dat",L"history.dat"};
    for(unsigned i=0;i<3;++i){
        const std::wstring path=t.dataDirectory+L"\\"+names[i];DWORD attr=GetFileAttributesW(path.c_str());
        if(attr==INVALID_FILE_ATTRIBUTES){if(GetLastError()==ERROR_FILE_NOT_FOUND)continue;return false;}
        if((attr&(FILE_ATTRIBUTE_REPARSE_POINT|FILE_ATTRIBUTE_DIRECTORY))||!safeFile(path,32ull*1024*1024))return false;
        const std::wstring backup=t.stagingDirectory+L"\\backup-"+std::to_wstring(i)+L".dat";std::string sourceHash,backupHash;
        if(!hashFile(path,sourceHash)||!CopyFileW(path.c_str(),backup.c_str(),TRUE))return false;
        if(!hashFile(backup,backupHash)||sourceHash!=backupHash){DeleteFileW(backup.c_str());return false;}
        t.backupMask|=1u<<i;t.backupSha256[i]=std::move(backupHash);
    }
    return writeTransaction(t);
}
inline bool backupInstalledFiles(Transaction&t){
    if(t.kind!="installed")return true;
    const wchar_t*names[]={L"Uninstall.exe",L"README.md",L"PRIVACY.md",L"VERIFICATION.md"};
    for(unsigned i=0;i<4;++i){
        const std::wstring path=parentPath(t.targetExecutable)+L"\\"+names[i];DWORD attr=GetFileAttributesW(path.c_str());
        if(attr==INVALID_FILE_ATTRIBUTES){if(GetLastError()==ERROR_FILE_NOT_FOUND)continue;return false;}
        if((attr&(FILE_ATTRIBUTE_REPARSE_POINT|FILE_ATTRIBUTE_DIRECTORY))||!safeFile(path))return false;
        const std::wstring backup=t.stagingDirectory+L"\\previous-owned-"+std::to_wstring(i)+L".dat";std::string sourceHash,backupHash;
        if(!hashFile(path,sourceHash)||!CopyFileW(path.c_str(),backup.c_str(),TRUE))return false;
        if(!hashFile(backup,backupHash)||sourceHash!=backupHash){DeleteFileW(backup.c_str());return false;}
        t.ownedFileMask|=1u<<i;t.ownedFileSha256[i]=std::move(backupHash);
    }
    return writeTransaction(t);
}
inline std::wstring restoreTemporaryPath(const Transaction&t,const std::wstring&target){
    return target+L".update-restore."+t.nonce;
}
inline bool prepareVerifiedRestore(const Transaction&t,const std::wstring&source,const std::wstring&target,const std::string&expected,std::uint64_t maximum,std::wstring&prepared){
    if(!digestText(expected)||!safeFile(source,maximum))return false;
    const DWORD targetAttributes=GetFileAttributesW(target.c_str());
    if(targetAttributes==INVALID_FILE_ATTRIBUTES){if(GetLastError()!=ERROR_FILE_NOT_FOUND)return false;}
    else if(targetAttributes&(FILE_ATTRIBUTE_REPARSE_POINT|FILE_ATTRIBUTE_DIRECTORY))return false;
    const std::wstring temp=restoreTemporaryPath(t,target);
    // A terminated recovery can leave a complete or partial copy beside the
    // target. Recopy from the backup using only this transaction's scratch path.
    const DWORD tempAttributes=GetFileAttributesW(temp.c_str());
    if(tempAttributes==INVALID_FILE_ATTRIBUTES){
        if(GetLastError()!=ERROR_FILE_NOT_FOUND)return false;
    }else{
        if(!safeFile(temp,maximum))return false;
        if(!DeleteFileW(temp.c_str()))return false;
    }
    if(!CopyFileW(source.c_str(),temp.c_str(),TRUE))return false;
    prepared=temp;
    std::string stagedHash;
    if(!safeFile(prepared,maximum)||!hashFile(prepared,stagedHash)||stagedHash!=expected){DeleteFileW(prepared.c_str());prepared.clear();return false;}
    return true;
}
inline void discardPreparedRestores(const std::array<std::wstring,4>&prepared){for(const auto&path:prepared)if(!path.empty())DeleteFileW(path.c_str());}
inline bool commitPreparedRestore(const std::wstring&prepared,const std::wstring&target){return MoveFileExW(prepared.c_str(),target.c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH)!=FALSE;}
inline bool restoreInstalledFiles(const Transaction&t){
    if(t.kind!="installed")return true;
    const wchar_t*names[]={L"Uninstall.exe",L"README.md",L"PRIVACY.md",L"VERIFICATION.md"};
    std::array<std::wstring,4>prepared{},targets{};const std::wstring installDirectory=parentPath(t.targetExecutable);
    for(unsigned i=0;i<4;++i){
        targets[i]=installDirectory+L"\\"+names[i];const DWORD attr=GetFileAttributesW(targets[i].c_str());
        if(t.ownedFileMask&(1u<<i)){
            const std::wstring backup=t.stagingDirectory+L"\\previous-owned-"+std::to_wstring(i)+L".dat";
            if(!prepareVerifiedRestore(t,backup,targets[i],t.ownedFileSha256[i],512ull*1024*1024,prepared[i])){discardPreparedRestores(prepared);return false;}
        }else if(attr!=INVALID_FILE_ATTRIBUTES){
            if((attr&(FILE_ATTRIBUTE_REPARSE_POINT|FILE_ATTRIBUTE_DIRECTORY))||!safeFile(targets[i])){discardPreparedRestores(prepared);return false;}
        }else if(GetLastError()!=ERROR_FILE_NOT_FOUND){discardPreparedRestores(prepared);return false;}
    }
    for(unsigned i=0;i<4;++i){
        const bool ok=(t.ownedFileMask&(1u<<i))?commitPreparedRestore(prepared[i],targets[i]):DeleteFileW(targets[i].c_str())||GetLastError()==ERROR_FILE_NOT_FOUND;
        if(!ok){discardPreparedRestores(prepared);return false;}
        prepared[i].clear();
    }
    discardPreparedRestores(prepared);return true;
}
inline constexpr std::array<const wchar_t*,3> RecoveryDataNames={L"settings.ini",L"timer.dat",L"history.dat"};
inline constexpr std::uint64_t RecoveryDataLimit=32ull*1024*1024;
enum class FreshRecoveryDataStatus { Ready, LiveConflict, InvalidBackup };
enum class FreshRecoveryLiveFile { Missing, MatchesBackup, Conflict };
inline FreshRecoveryLiveFile freshRecoveryLiveFile(const Transaction&t,unsigned i){
    const auto path=t.dataDirectory+L"\\"+RecoveryDataNames[i];
    const DWORD attr=GetFileAttributesW(path.c_str());
    if(attr==INVALID_FILE_ATTRIBUTES)
        return GetLastError()==ERROR_FILE_NOT_FOUND?FreshRecoveryLiveFile::Missing:FreshRecoveryLiveFile::Conflict;
    std::string digest;
    return (t.backupMask&(1u<<i))&&safeFile(path,RecoveryDataLimit)&&hashFile(path,digest)&&digest==t.backupSha256[i]
        ?FreshRecoveryLiveFile::MatchesBackup:FreshRecoveryLiveFile::Conflict;
}
inline bool freshRecoveryLiveDataMatches(const Transaction&t){
    // A countdown is a checkpoint and can change as the app shuts down.
    // Protect settings and history that rollback would replace or remove.
    for(unsigned i:{0u,2u}){
        const bool backed=(t.backupMask&(1u<<i))!=0;
        const bool cleanAffected=t.clean&&(i==0||t.deleteHistory);
        if(!backed&&!cleanAffected)continue;
        if(freshRecoveryLiveFile(t,i)==FreshRecoveryLiveFile::Conflict)return false;
    }
    return true;
}
inline bool recoveryBackupMatches(const std::wstring&path,const std::string&expected,std::uint64_t maximum){
    std::string digest;
    return safeFile(path,maximum)&&hashFile(path,digest)&&digest==expected;
}
inline FreshRecoveryDataStatus checkFreshRecoveryData(const Transaction&t){
    if(!freshRecoveryLiveDataMatches(t))return FreshRecoveryDataStatus::LiveConflict;
    for(unsigned i=0;i<RecoveryDataNames.size();++i){
        if(!(t.backupMask&(1u<<i)))continue;
        const auto path=t.stagingDirectory+L"\\backup-"+std::to_wstring(i)+L".dat";
        if(!recoveryBackupMatches(path,t.backupSha256[i],RecoveryDataLimit))
            return FreshRecoveryDataStatus::InvalidBackup;
    }
    if(t.kind=="installed"){
        for(unsigned i=0;i<t.ownedFileSha256.size();++i){
            if(!(t.ownedFileMask&(1u<<i)))continue;
            const auto path=t.stagingDirectory+L"\\previous-owned-"+std::to_wstring(i)+L".dat";
            if(!recoveryBackupMatches(path,t.ownedFileSha256[i],512ull*1024*1024))
                return FreshRecoveryDataStatus::InvalidBackup;
        }
    }
    return FreshRecoveryDataStatus::Ready;
}
inline bool restoreData(const Transaction&t,bool restoringClean,FreshRecoveryDataStatus*freshStatus=nullptr){
    std::array<std::wstring,4>prepared{};std::array<std::wstring,3>targets{};std::array<bool,3>affected{};
    for(unsigned i=0;i<3;++i){
        affected[i]=restoringClean&&(i<2||t.deleteHistory);if(!affected[i]&&!(t.backupMask&(1u<<i)))continue;
        targets[i]=t.dataDirectory+L"\\"+RecoveryDataNames[i];const DWORD attr=GetFileAttributesW(targets[i].c_str());
        if(t.backupMask&(1u<<i)){
            const std::wstring backup=t.stagingDirectory+L"\\backup-"+std::to_wstring(i)+L".dat";
            if(!prepareVerifiedRestore(t,backup,targets[i],t.backupSha256[i],RecoveryDataLimit,prepared[i])){discardPreparedRestores(prepared);return false;}
        }else if(affected[i]&&attr!=INVALID_FILE_ATTRIBUTES){
            if((attr&(FILE_ATTRIBUTE_REPARSE_POINT|FILE_ATTRIBUTE_DIRECTORY))||!safeFile(targets[i],RecoveryDataLimit)){discardPreparedRestores(prepared);return false;}
        }else if(affected[i]&&GetLastError()!=ERROR_FILE_NOT_FOUND){discardPreparedRestores(prepared);return false;}
    }
    if(freshStatus&&!freshRecoveryLiveDataMatches(t)){
        *freshStatus=FreshRecoveryDataStatus::LiveConflict;discardPreparedRestores(prepared);return false;
    }
    for(unsigned i=0;i<3;++i){
        if(!affected[i]&&!(t.backupMask&(1u<<i)))continue;
        if(freshStatus&&i!=1){
            const auto live=freshRecoveryLiveFile(t,i);
            if(live==FreshRecoveryLiveFile::Conflict){
                *freshStatus=FreshRecoveryDataStatus::LiveConflict;discardPreparedRestores(prepared);return false;
            }
            // Retain an existing matching file. A concurrent writer can also
            // create the path after this check, so a restore must never replace
            // an existing settings/history file, even at the rename boundary.
            if(live==FreshRecoveryLiveFile::Missing&&!prepared[i].empty()){
                if(!MoveFileExW(prepared[i].c_str(),targets[i].c_str(),MOVEFILE_WRITE_THROUGH)){
                    if(freshRecoveryLiveFile(t,i)==FreshRecoveryLiveFile::Conflict)
                        *freshStatus=FreshRecoveryDataStatus::LiveConflict;
                    discardPreparedRestores(prepared);return false;
                }
                prepared[i].clear();
            }
            continue;
        }
        const bool ok=(t.backupMask&(1u<<i))?commitPreparedRestore(prepared[i],targets[i]):DeleteFileW(targets[i].c_str())||GetLastError()==ERROR_FILE_NOT_FOUND;
        if(!ok){discardPreparedRestores(prepared);return false;}
        prepared[i].clear();
    }
    discardPreparedRestores(prepared);return true;
}
inline bool applyCleanPolicy(const Transaction&t){const wchar_t*names[]={L"settings.ini",L"timer.dat",L"history.dat"};for(int i=0;i<3;++i){if(i==2&&!t.deleteHistory)continue;const std::wstring path=t.dataDirectory+L"\\"+names[i];DWORD attr=GetFileAttributesW(path.c_str());if(attr==INVALID_FILE_ATTRIBUTES&&GetLastError()==ERROR_FILE_NOT_FOUND)continue;if(attr==INVALID_FILE_ATTRIBUTES||(attr&(FILE_ATTRIBUTE_REPARSE_POINT|FILE_ATTRIBUTE_DIRECTORY))||!DeleteFileW(path.c_str()))return false;}return true;}
inline bool targetApplicationRunning(const Transaction&t,DWORD expectedPid=0){HWND window=FindWindowW(L"EyeBreakReminder.Native",nullptr);if(!window)return false;DWORD pid=0;GetWindowThreadProcessId(window,&pid);if(!pid||(expectedPid&&pid!=expectedPid))return false;HANDLE process=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,FALSE,pid);if(!process)return false;wchar_t path[32768]{};DWORD length=DWORD(std::size(path));const bool same=QueryFullProcessImageNameW(process,0,path,&length)&&samePath(path,t.targetExecutable);CloseHandle(process);return same;}
inline bool requestExactApplicationExit(const Transaction&t,DWORD expectedPid){
    if(!expectedPid)return false;
    HWND window=FindWindowW(L"EyeBreakReminder.Native",nullptr);if(!window)return false;
    DWORD pid=0;GetWindowThreadProcessId(window,&pid);if(pid!=expectedPid)return false;
    HANDLE process=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,FALSE,pid);if(!process)return false;
    wchar_t path[32768]{};DWORD length=DWORD(std::size(path));
    const bool exact=QueryFullProcessImageNameW(process,0,path,&length)&&samePath(path,t.targetExecutable);
    CloseHandle(process);if(!exact)return false;
    const UINT quit=RegisterWindowMessageW(L"EyeBreakReminder.Exit.Native.1");DWORD_PTR ignored=0;
    return SendMessageTimeoutW(window,quit,0,0,SMTO_ABORTIFHUNG,5000,&ignored)!=0;
}
inline bool startPrevious(const Transaction&t){
    std::string digest;
    if(productVersion(t.targetExecutable)!=t.previousVersion||
       !hashFile(t.targetExecutable,digest)||digest!=t.previousSha256)return false;
    if(targetApplicationRunning(t))return true;
    const std::wstring eventName=L"Local\\EyeBreakReminder.UpdateConfirm."+t.nonce;HANDLE confirmed=CreateEventW(nullptr,TRUE,FALSE,eventName.c_str());if(!confirmed)return false;const DWORD eventError=GetLastError();if(eventError==ERROR_ALREADY_EXISTS){CloseHandle(confirmed);return false;}
    const std::wstring args=L"--update-confirm "+quoteArgument(t.nonce)+L" --update-cleanup "+quoteArgument(t.stagingDirectory)+L" "+std::to_wstring(GetCurrentProcessId());PROCESS_INFORMATION pi{};
    if(!launchProcess(t.targetExecutable,args,pi)){CloseHandle(confirmed);return false;}
    CloseHandle(pi.hThread);const DWORD wait=WaitForSingleObject(confirmed,confirmationWaitMilliseconds());CloseHandle(confirmed);
    const bool alive=wait==WAIT_OBJECT_0&&WaitForSingleObject(pi.hProcess,2000)==WAIT_TIMEOUT&&targetApplicationRunning(t,pi.dwProcessId);
    if(!alive){HWND window=FindWindowW(L"EyeBreakReminder.Native",nullptr);DWORD owner=0;if(window)GetWindowThreadProcessId(window,&owner);if(window&&owner==pi.dwProcessId){const UINT quit=RegisterWindowMessageW(L"EyeBreakReminder.Exit.Native.1");DWORD_PTR ignored=0;SendMessageTimeoutW(window,quit,0,0,SMTO_ABORTIFHUNG,5000,&ignored);}WaitForSingleObject(pi.hProcess,10000);}
    CloseHandle(pi.hProcess);return alive;
}
inline bool stopRunningApplication(const Transaction&t){
    HWND window=FindWindowW(L"EyeBreakReminder.Native",nullptr);if(!window)return true;
    DWORD pid=0;GetWindowThreadProcessId(window,&pid);if(!pid||pid==GetCurrentProcessId())return false;
    HANDLE process=OpenProcess(SYNCHRONIZE|PROCESS_QUERY_LIMITED_INFORMATION,FALSE,pid);
    if(!process)return GetLastError()==ERROR_INVALID_PARAMETER;
    wchar_t path[32768]{};DWORD length=DWORD(std::size(path));
    DWORD owner=0;GetWindowThreadProcessId(window,&owner);
    const bool target=owner==pid&&QueryFullProcessImageNameW(process,0,path,&length)&&samePath(path,t.targetExecutable);
    if(!target){CloseHandle(process);return false;}
    const UINT quit=RegisterWindowMessageW(L"EyeBreakReminder.Exit.Native.1");DWORD_PTR ignored=0;
    SendMessageTimeoutW(window,quit,0,0,SMTO_ABORTIFHUNG,5000,&ignored);
    const DWORD wait=WaitForSingleObject(process,60000);CloseHandle(process);return wait==WAIT_OBJECT_0;
}
inline bool restorePreviousVersion(const Transaction&t,FreshRecoveryDataStatus*freshStatus=nullptr){
    const std::wstring backup=t.stagingDirectory+L"\\previous.exe";std::string digest;
    if(!safeFile(backup)||productVersion(backup)!=t.previousVersion||!hashFile(backup,digest)||digest!=t.previousSha256)return false;
    if(freshStatus){
        *freshStatus=checkFreshRecoveryData(t);
        if(*freshStatus!=FreshRecoveryDataStatus::Ready)return false;
    }
    if(!stopRunningApplication(t))return false;
    // A graceful exit saves current settings, including a changed window position.
    if(freshStatus){
        *freshStatus=checkFreshRecoveryData(t);
        if(*freshStatus!=FreshRecoveryDataStatus::Ready)return false;
    }
    std::wstring prepared;
    if(!prepareVerifiedRestore(t,backup,t.targetExecutable,t.previousSha256,512ull*1024*1024,prepared))return false;
    if(!commitPreparedRestore(prepared,t.targetExecutable)){DeleteFileW(prepared.c_str());return false;}
    const bool filesRestored=restoreInstalledFiles(t);
    const bool dataRestored=filesRestored&&restoreData(t,t.clean,freshStatus);
    const bool versionRestored=dataRestored&&(t.kind!="installed"||writeVersionRegistry(t.previousVersion));
    const bool startupRestored=versionRestored&&(!t.clean||setStartupRegistration(t,t.previousStartup));
    if(!startupRestored)return false;
    if(!writeJournal(t,L"recovered"))return false;
    if(!startPrevious(t))return false;
    // Leave a RunOnce command's own value alone. Windows removes the
    // !-prefixed value after the command finishes.
    return true;
}
inline int runRecovery(const std::wstring&transactionPath,const std::wstring&coordinatorPath){
    HANDLE single{};if(!acquireCoordinatorMutex(single))return 3;
    Transaction t;if(!readTransaction(transactionPath,t)){
        CloseHandle(single);
        MessageBoxW(nullptr,L"The saved update recovery record is invalid. No files were changed; keep the recovery folder for manual review.",L"Eye Break Reminder Recovery",MB_OK|MB_ICONERROR);return 2;
    }
    // Expiry gates installation. This path authenticates the record for rollback and never launches the successor payload.
    std::string error;if(!validateTransaction(t,transactionPath,coordinatorPath,error,ManifestUse::Recover)){
        CloseHandle(single);
        MessageBoxW(nullptr,eye::win::wide(error).c_str(),L"Eye Break Reminder Recovery",MB_OK|MB_ICONERROR);return 2;
    }
    const std::wstring phase=journalPhase(t);
    if(phase==L"complete"){
        CloseHandle(single);
        return 0;
    }
    if(phase==L"recovered"||phase==L"verified"){
        const bool started=startPrevious(t);
        CloseHandle(single);
        if(started)return 0;
        MessageBoxW(nullptr,L"Eye Break Reminder could not confirm that the restored application started. Keep the recovery folder and contact support; Windows may remove this one-time entry after the command exits.",L"Eye Break Reminder Recovery",MB_OK|MB_ICONERROR);return 1;
    }
    if(phase!=L"installing"&&phase!=L"installed"&&phase!=L"cleaning"&&phase!=L"starting"){CloseHandle(single);return 2;}
    if(installedTargetIsNewerThanTransaction(t)){
        CloseHandle(single);
        return 2;
    }
    const bool registrationOwned=recoveryRegistrationMatches(t);
    if(!registrationOwned&&!recoveryRegistrationAbsent()){
        CloseHandle(single);
        MessageBoxW(nullptr,L"Another update owns the Windows recovery registration. No application files were changed.",L"Eye Break Reminder Recovery",MB_OK|MB_ICONERROR);
        return 2;
    }
    if(!registrationOwned){
        const std::wstring prompt=L"Windows no longer has this update's recovery command registered. This saved transaction may be stale.\n\nRecovery: "+
            t.version+L" to "+t.previousVersion+L"\nFolder: "+t.stagingDirectory+
            L"\n\nContinue only if you intentionally started this manual recovery.";
        const int choice=MessageBoxW(nullptr,prompt.c_str(),L"Eye Break Reminder Manual Recovery",MB_YESNO|MB_ICONWARNING|MB_DEFBUTTON2);
        if(choice!=IDYES){CloseHandle(single);return 2;}
    }
    auto dataStatus=FreshRecoveryDataStatus::Ready;
    const bool restored=restorePreviousVersion(t,&dataStatus);
    CloseHandle(single);
    if(dataStatus==FreshRecoveryDataStatus::LiveConflict){
        MessageBoxW(nullptr,L"Update recovery stopped to protect current settings or history that differ from the saved backup or could not be verified. Keep the recovery folder and contact support before retrying.",L"Eye Break Reminder Recovery",MB_OK|MB_ICONWARNING);return 1;
    }
    if(dataStatus==FreshRecoveryDataStatus::InvalidBackup){
        MessageBoxW(nullptr,L"Update recovery stopped before changing the installed application because a saved backup is missing or invalid. Keep the recovery folder and contact support.",L"Eye Break Reminder Recovery",MB_OK|MB_ICONWARNING);return 1;
    }
    if(!restored){MessageBoxW(nullptr,L"Eye Break Reminder could not finish automatic recovery. The previous application and data backups remain in the updates folder. Close Eye Break Reminder and run the saved coordinator again, or contact support with the recovery folder contents.",L"Eye Break Reminder Recovery",MB_OK|MB_ICONERROR);return 1;}
    return 0;
}

inline void testHoldAfterCleanForRecovery(){
#ifdef EYEBREAK_TEST_BUILD
    wchar_t text[16]{};DWORD length=GetEnvironmentVariableW(L"EBR_GUI_TEST_HOLD_AFTER_CLEAN_MS",text,DWORD(std::size(text)));
    if(length&&length<std::size(text)){wchar_t*end=nullptr;unsigned long value=std::wcstoul(text,&end,10);if(end&&!*end&&value>=1000&&value<=30000)Sleep(DWORD(value));}
#endif
}

inline void performTransaction(Transaction t,UiState&ui){
    auto fail=[&](const std::wstring&message){coordinatorMessage(ui,message);ui.success=false;ui.done=true;};
    std::string error;if(!validateTransaction(t,t.stagingDirectory+L"\\transaction.ini",t.stagingDirectory+L"\\coordinator.exe",error)){fail(eye::win::wide(error));return;}
    HANDLE single{};if(!acquireCoordinatorMutex(single)){fail(L"Another update operation is already running. Close it before trying again.");return;}
    auto rollback=[&](const wchar_t*message){coordinatorMessage(ui,L"Restoring the previous application and its data…");const bool restored=restorePreviousVersion(t);const bool registrationCleared=restored&&setRecoveryRegistration(t,false);CloseHandle(single);fail(registrationCleared?message:L"Automatic rollback could not finish. The previous executable and data backup remain in the updates folder. Close Eye Break Reminder and run the saved recovery command, or contact support with the recovery folder contents.");};
    auto abortBeforeInstall=[&](const std::wstring&message){const bool restarted=startPrevious(t);CloseHandle(single);fail(restarted?message:message+L" The existing version is unchanged; reopen Eye Break Reminder if it is not already running.");};
    coordinatorMessage(ui,L"Waiting for Eye Break Reminder to close safely…");if(!writeJournal(t,L"waiting")){CloseHandle(single);fail(L"The update recovery record could not be saved. No files were changed.");return;}
    HANDLE owner=OpenProcess(SYNCHRONIZE,FALSE,t.ownerPid);if(owner){DWORD wait=WaitForSingleObject(owner,60000);CloseHandle(owner);if(wait!=WAIT_OBJECT_0){CloseHandle(single);fail(L"The application did not close within one minute. No files were changed; reopen it and try again.");return;}}
    else if(GetLastError()!=ERROR_INVALID_PARAMETER){CloseHandle(single);fail(L"Windows could not confirm that the application closed. No files were changed.");return;}
    coordinatorMessage(ui,L"Preparing a recovery copy of the application and relevant data…");
    const std::wstring previous=t.stagingDirectory+L"\\previous.exe";
    std::string previousHash;
    if(productVersion(t.targetExecutable)!=t.previousVersion||!CopyFileW(t.targetExecutable.c_str(),previous.c_str(),TRUE)||!hashFile(previous,previousHash)||previousHash!=t.previousSha256||!backupData(t)||!backupInstalledFiles(t)){
        abortBeforeInstall(L"The current application or its settings could not be backed up and verified. The update was not installed.");return;
    }
    std::string actual;WIN32_FILE_ATTRIBUTE_DATA artifactInfo{};const bool sizeMatches=GetFileAttributesExW(t.artifactPath.c_str(),GetFileExInfoStandard,&artifactInfo)&&((std::uint64_t(artifactInfo.nFileSizeHigh)<<32)|artifactInfo.nFileSizeLow)==t.expectedSize;
    if(!sizeMatches||!hashFile(t.artifactPath,actual)||actual!=t.sha256){abortBeforeInstall(L"The staged update failed its final size or SHA-256 verification. It was not executed.");return;}
    if((t.kind=="installed"&&productVersion(t.artifactPath)!=t.version)||(t.kind=="portable"&&(productVersion(t.artifactPath)!=t.version||actual!=t.expectedApplicationSha256))){abortBeforeInstall(L"The downloaded update does not contain the expected application version and identity.");return;}
    std::string finalManifest,finalSignature;
    const bool finalMetadataRead=eye::win::read(t.stagingDirectory+L"\\EyeBreakReminder-UpdateManifest.json",finalManifest,16384)&&
        eye::win::read(t.stagingDirectory+L"\\EyeBreakReminder-UpdateManifest.sig",finalSignature,64);
    const auto finalAuthorization=finalMetadataRead?verifyStagedManifest(finalManifest,finalSignature,t.stagingDirectory,
        "v"+eye::win::utf8(t.version),eye::win::utf8(t.previousVersion),std::time(nullptr)):ManifestAuthorization{};
    const auto*finalSelected=finalAuthorization.ok?manifestAsset(finalAuthorization.manifest,t.kind=="installed"):nullptr;
    const auto*finalPortable=finalAuthorization.ok?manifestAsset(finalAuthorization.manifest,false):nullptr;
    if(!finalAuthorization.ok||!finalSelected||!finalPortable||finalSelected->name!=t.artifactName||finalSelected->size!=t.expectedSize||
       finalSelected->sha256!=t.sha256||finalPortable->sha256!=t.expectedApplicationSha256){
        abortBeforeInstall(L"The publisher signature could not be revalidated at the installation boundary. The update was not executed.");return;
    }
    if(!writeJournal(t,L"verified")||!setRecoveryRegistration(t,true)||!writeJournal(t,L"installing")){setRecoveryRegistration(t,false);abortBeforeInstall(L"Windows could not save the durable recovery information. The current application was not changed.");return;}
    coordinatorMessage(ui,L"Installing the verified update…");bool installed=false;
    if(t.kind=="installed"){
        PROCESS_INFORMATION setup{};if(launchProcess(t.artifactPath,L"/S",setup)){CloseHandle(setup.hThread);DWORD wait=WaitForSingleObject(setup.hProcess,10*60*1000);DWORD code=1;if(wait==WAIT_OBJECT_0)GetExitCodeProcess(setup.hProcess,&code);else {coordinatorMessage(ui,L"The installer is taking longer than expected. Waiting for it to finish safely…");wait=WaitForSingleObject(setup.hProcess,INFINITE);if(wait==WAIT_OBJECT_0)GetExitCodeProcess(setup.hProcess,&code);}CloseHandle(setup.hProcess);installed=wait==WAIT_OBJECT_0&&code==0;}
    }else{
        const std::wstring temp=t.targetExecutable+L".update-new";DeleteFileW(temp.c_str());std::string tempHash;installed=CopyFileW(t.artifactPath.c_str(),temp.c_str(),TRUE)&&productVersion(temp)==t.version&&hashFile(temp,tempHash)&&tempHash==t.expectedApplicationSha256&&MoveFileExW(temp.c_str(),t.targetExecutable.c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH);if(!installed)DeleteFileW(temp.c_str());
    }
    std::string installedHash;if(!installed||productVersion(t.targetExecutable)!=t.version||!hashFile(t.targetExecutable,installedHash)||installedHash!=t.expectedApplicationSha256){rollback(L"The update failed. The previous version was restored and restarted with its data.");return;}
    if(!writeJournal(t,L"installed")){rollback(L"The update could not save its installation state. The previous version was restored and restarted.");return;}
    if(t.clean){coordinatorMessage(ui,L"Applying the confirmed clean-install settings…");if(!writeJournal(t,L"cleaning")||!applyCleanPolicy(t)||!setStartupRegistration(t,false)){rollback(L"The clean install could not finish. The previous version and its data were restored.");return;}testHoldAfterCleanForRecovery();}
    if(!writeJournal(t,L"starting")){rollback(L"The update could not save its startup state. The previous version was restored and restarted.");return;}
    coordinatorMessage(ui,L"Starting the updated application and waiting for its startup confirmation…");
    const std::wstring eventName=L"Local\\EyeBreakReminder.UpdateConfirm."+t.nonce;HANDLE confirmed=CreateEventW(nullptr,TRUE,FALSE,eventName.c_str());PROCESS_INFORMATION app{};const std::wstring args=L"--update-confirm "+t.nonce+L" --update-cleanup "+quoteArgument(t.stagingDirectory)+L" "+std::to_wstring(GetCurrentProcessId());
    bool running=confirmed&&launchProcess(t.targetExecutable,args,app);bool launched=running&&WaitForSingleObject(confirmed,confirmationWaitMilliseconds())==WAIT_OBJECT_0;if(confirmed)CloseHandle(confirmed);
    if(running&&!launched){requestExactApplicationExit(t,app.dwProcessId);DWORD wait=WaitForSingleObject(app.hProcess,10000);CloseHandle(app.hThread);CloseHandle(app.hProcess);if(wait!=WAIT_OBJECT_0){CloseHandle(single);fail(L"The new application did not confirm startup and did not close safely. The previous executable and data backup remain available; no process was forced to stop.");return;}}
    else if(running){CloseHandle(app.hThread);CloseHandle(app.hProcess);}
    if(!launched){rollback(L"The updated application did not start. The previous version was restored and restarted with its data.");return;}
    if(!writeJournal(t,L"complete")){rollback(L"The new application started, but its durable completion record could not be saved. The previous version was restored and restarted.");return;}
    setRecoveryRegistration(t,false);CloseHandle(single);ui.success=true;coordinatorMessage(ui,L"Update complete. The new version started successfully. Your settings and history follow the choices you confirmed.");ui.done=true;
}

inline int runCoordinator(const std::wstring&transactionPath){
    Transaction t;if(!readTransaction(transactionPath,t)){MessageBoxW(nullptr,L"The update transaction is missing or invalid. No downloaded file was executed.",L"Eye Break Reminder Update",MB_OK|MB_ICONERROR);return 2;}
    INITCOMMONCONTROLSEX common{sizeof(common),ICC_BAR_CLASSES|ICC_STANDARD_CLASSES};InitCommonControlsEx(&common);UiState ui;HIGHCONTRASTW contrast{};contrast.cbSize=sizeof(contrast);SystemParametersInfoW(SPI_GETHIGHCONTRAST,sizeof(contrast),&contrast,0);ui.dark=t.dark;ui.forcedColors=(contrast.dwFlags&HCF_HIGHCONTRASTON)!=0;
    WNDCLASSEXW cls{};cls.cbSize=sizeof(cls);cls.hInstance=GetModuleHandleW(nullptr);cls.hCursor=LoadCursorW(nullptr,IDC_ARROW);cls.lpfnWndProc=coordinatorWindowProc;cls.lpszClassName=CoordinatorWindowClass;if(!RegisterClassExW(&cls)&&GetLastError()!=ERROR_CLASS_ALREADY_EXISTS){MessageBoxW(nullptr,L"Windows could not prepare the update status window. No files were changed.",L"Eye Break Reminder Update",MB_OK|MB_ICONERROR);return 3;}
    const DWORD style=WS_OVERLAPPED|WS_CAPTION|WS_SYSMENU|WS_CLIPCHILDREN,exstyle=WS_EX_DLGMODALFRAME|WS_EX_CONTROLPARENT;HWND dialog=CreateWindowExW(exstyle,CoordinatorWindowClass,L"Eye Break Reminder Update",style,CW_USEDEFAULT,CW_USEDEFAULT,600,260,nullptr,nullptr,GetModuleHandleW(nullptr),&ui);if(!dialog){MessageBoxW(nullptr,L"Windows could not create the update status window. No files were changed.",L"Eye Break Reminder Update",MB_OK|MB_ICONERROR);return 3;}
    BOOL dark=ui.dark&&!ui.forcedColors;DwmSetWindowAttribute(dialog,20,&dark,sizeof(dark));if(dark)SetWindowTheme(dialog,L"DarkMode_Explorer",nullptr);RECT work{};MONITORINFO monitor{};monitor.cbSize=sizeof(monitor);if(GetMonitorInfoW(MonitorFromPoint(POINT{0,0},MONITOR_DEFAULTTOPRIMARY),&monitor))work=monitor.rcWork;ui.dpi=GetDpiForWindow(dialog);RECT outer{0,0,coordinatorWindowWidth(ui),coordinatorWindowHeight(ui)};AdjustWindowRectExForDpi(&outer,style,FALSE,exstyle,ui.dpi);int x=work.left+(work.right-work.left-(outer.right-outer.left))/2,y=work.top+(work.bottom-work.top-(outer.bottom-outer.top))/2;SetWindowPos(dialog,nullptr,x,y,outer.right-outer.left,outer.bottom-outer.top,SWP_NOZORDER|SWP_NOACTIVATE);
    std::thread worker;try{worker=std::thread([t,&ui]{try{performTransaction(t,ui);}catch(...){coordinatorMessage(ui,L"The update coordinator stopped unexpectedly. Recovery files have been retained.");ui.success=false;ui.done=true;}});}catch(...){coordinatorMessage(ui,L"Windows could not start the update operation. Your existing application and data are unchanged.");ui.success=false;ui.done=true;}
    ShowWindow(dialog,SW_SHOWNORMAL);UpdateWindow(dialog);MSG message{};while(GetMessageW(&message,nullptr,0,0)>0){if(!IsDialogMessageW(dialog,&message)){TranslateMessage(&message);DispatchMessageW(&message);}}
    if(worker.joinable())worker.join();
    return ui.success?0:1;
}

#ifdef EYEBREAK_TEST_BUILD
inline int runCoordinatorVisualFixture(bool success){
    INITCOMMONCONTROLSEX common{sizeof(common),ICC_BAR_CLASSES|ICC_STANDARD_CLASSES};InitCommonControlsEx(&common);UiState ui;ui.dark=true;ui.success=success;ui.done=true;ui.message=success?L"Update complete. The new version started successfully. Your settings and history follow the choices you confirmed.":L"The update failed. The previous version and its data were restored.";
    WNDCLASSEXW cls{};cls.cbSize=sizeof(cls);cls.hInstance=GetModuleHandleW(nullptr);cls.hCursor=LoadCursorW(nullptr,IDC_ARROW);cls.lpfnWndProc=coordinatorWindowProc;cls.lpszClassName=CoordinatorWindowClass;if(!RegisterClassExW(&cls)&&GetLastError()!=ERROR_CLASS_ALREADY_EXISTS)return 3;
    const DWORD style=WS_OVERLAPPED|WS_CAPTION|WS_SYSMENU|WS_CLIPCHILDREN,exstyle=WS_EX_DLGMODALFRAME|WS_EX_CONTROLPARENT;HWND dialog=CreateWindowExW(exstyle,CoordinatorWindowClass,L"Eye Break Reminder Update",style,CW_USEDEFAULT,CW_USEDEFAULT,640,340,nullptr,nullptr,GetModuleHandleW(nullptr),&ui);if(!dialog)return 3;BOOL dark=TRUE;DwmSetWindowAttribute(dialog,20,&dark,sizeof(dark));SetWindowTheme(dialog,L"DarkMode_Explorer",nullptr);RECT work{};MONITORINFO monitor{};monitor.cbSize=sizeof(monitor);if(GetMonitorInfoW(MonitorFromPoint(POINT{0,0},MONITOR_DEFAULTTOPRIMARY),&monitor))work=monitor.rcWork;ui.dpi=GetDpiForWindow(dialog);RECT outer{0,0,coordinatorWindowWidth(ui),coordinatorWindowHeight(ui)};AdjustWindowRectExForDpi(&outer,style,FALSE,exstyle,ui.dpi);const int x=work.left+(work.right-work.left-(outer.right-outer.left))/2,y=work.top+(work.bottom-work.top-(outer.bottom-outer.top))/2;SetWindowPos(dialog,nullptr,x,y,outer.right-outer.left,outer.bottom-outer.top,SWP_NOZORDER|SWP_NOACTIVATE);ShowWindow(dialog,SW_SHOWNORMAL);UpdateWindow(dialog);MSG message{};while(GetMessageW(&message,nullptr,0,0)>0){if(!IsDialogMessageW(dialog,&message)){TranslateMessage(&message);DispatchMessageW(&message);}}return success?0:1;
}
#endif

} // namespace eye::updates
