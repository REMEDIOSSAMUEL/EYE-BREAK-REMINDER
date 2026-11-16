#pragma once

#include "windows_services.hpp"
#include "update_client.hpp"
#include <winver.h>
#include <atomic>
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
    bool clean=false,deleteHistory=false,dark=false,forcedColors=false,previousStartup=false;
};

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
    const std::wstring path=t.stagingDirectory+L"\\transaction-state.ini",temp=path+L".tmp";
    std::string content="phase="+eye::win::utf8(std::wstring(phase))+"\nmessage="+eye::win::utf8(message)+"\nversion="+eye::win::utf8(t.version)+"\nclean="+(t.clean?"1":"0")+"\ndeleteHistory="+(t.deleteHistory?"1":"0")+"\n";
    HANDLE f=CreateFileW(temp.c_str(),GENERIC_WRITE,0,nullptr,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL|FILE_FLAG_WRITE_THROUGH,nullptr);if(f==INVALID_HANDLE_VALUE)return false;DWORD wrote=0;bool ok=WriteFile(f,content.data(),DWORD(content.size()),&wrote,nullptr)&&wrote==content.size()&&FlushFileBuffers(f);CloseHandle(f);if(ok)ok=MoveFileExW(temp.c_str(),path.c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH);if(!ok)DeleteFileW(temp.c_str());return ok;
}
inline std::string transactionText(const Transaction&t){
    return "staging="+eye::win::utf8(t.stagingDirectory)+"\nartifact="+eye::win::utf8(t.artifactPath)+"\ntarget="+eye::win::utf8(t.targetExecutable)+"\ndata="+eye::win::utf8(t.dataDirectory)+"\nversion="+eye::win::utf8(t.version)+"\nprevious="+eye::win::utf8(t.previousVersion)+"\nnonce="+eye::win::utf8(t.nonce)+"\nkind="+t.kind+"\nname="+t.artifactName+"\nsha256="+t.sha256+"\napplicationSha256="+t.expectedApplicationSha256+"\npreviousSha256="+t.previousSha256+"\nsize="+std::to_string(t.expectedSize)+"\nbackupMask="+std::to_string(t.backupMask)+"\nownedFileMask="+std::to_string(t.ownedFileMask)+"\npid="+std::to_string(t.ownerPid)+"\nclean="+(t.clean?"1":"0")+"\ndeleteHistory="+(t.deleteHistory?"1":"0")+"\ndark="+(t.dark?"1":"0")+"\nforcedColors="+(t.forcedColors?"1":"0")+"\npreviousStartup="+(t.previousStartup?"1":"0")+"\n";
}
inline bool writeTransaction(const Transaction&t){return eye::win::writeAtomic(t.stagingDirectory+L"\\transaction.ini",transactionText(t));}
inline bool readTransaction(const std::wstring&path,Transaction&out){
    if(!safeFile(path,32768))return false;
    std::string data;if(!eye::win::read(path,data,32768))return false;Transaction t;std::array<bool,21>seen{};std::istringstream input(data);std::string line;
    while(std::getline(input,line)){if(line.empty())continue;auto eq=line.find('=');if(eq==std::string::npos)return false;const auto key=line.substr(0,eq),value=line.substr(eq+1);auto setWide=[&](std::wstring&target,std::size_t index){if(seen[index])return false;seen[index]=true;target=eye::win::wide(value);return !target.empty()&&target.find_first_of(L"\r\n") == std::wstring::npos;};auto setBool=[&](bool&target,std::size_t index){if(seen[index]||(value!="0"&&value!="1"))return false;seen[index]=true;target=value=="1";return true;};auto setUint=[&](std::uint64_t&target,std::size_t index){if(seen[index]||value.empty())return false;seen[index]=true;try{std::size_t used=0;target=std::stoull(value,&used);return used==value.size();}catch(...){return false;}};
        if(key=="staging"){if(!setWide(t.stagingDirectory,0))return false;}else if(key=="artifact"){if(!setWide(t.artifactPath,1))return false;}else if(key=="target"){if(!setWide(t.targetExecutable,2))return false;}else if(key=="data"){if(!setWide(t.dataDirectory,3))return false;}else if(key=="version"){if(!setWide(t.version,4))return false;}else if(key=="previous"){if(!setWide(t.previousVersion,5))return false;}else if(key=="nonce"){if(!setWide(t.nonce,6))return false;}else if(key=="kind"){if(seen[7]||(value!="installed"&&value!="portable"))return false;seen[7]=true;t.kind=value;}else if(key=="name"){if(seen[8])return false;seen[8]=true;t.artifactName=value;}else if(key=="sha256"){if(seen[9]||value.size()!=64)return false;seen[9]=true;t.sha256=value;}else if(key=="applicationSha256"){if(seen[10]||value.size()!=64)return false;seen[10]=true;t.expectedApplicationSha256=value;}else if(key=="previousSha256"){if(seen[11]||value.size()!=64)return false;seen[11]=true;t.previousSha256=value;}else if(key=="size"){if(!setUint(t.expectedSize,12))return false;}else if(key=="backupMask"){std::uint64_t mask=0;if(!setUint(mask,13)||mask>7)return false;t.backupMask=unsigned(mask);}else if(key=="pid"){if(seen[14]||value.empty())return false;seen[14]=true;try{std::size_t used=0;auto n=std::stoul(value,&used);if(used!=value.size()||n==0||n>UINT32_MAX)return false;t.ownerPid=DWORD(n);}catch(...){return false;}}else if(key=="clean"){if(!setBool(t.clean,15))return false;}else if(key=="deleteHistory"){if(!setBool(t.deleteHistory,16))return false;}else if(key=="dark"){if(!setBool(t.dark,17))return false;}else if(key=="forcedColors"){if(!setBool(t.forcedColors,18))return false;}else if(key=="previousStartup"){if(!setBool(t.previousStartup,19))return false;}else if(key=="ownedFileMask"){std::uint64_t mask=0;if(!setUint(mask,20)||mask>15)return false;t.ownedFileMask=unsigned(mask);}else return false;
    }
    if(!std::all_of(seen.begin(),seen.end(),[](bool value){return value;}))return false;
    out=std::move(t);return true;
}
inline bool registeredInstallDirectory(std::wstring&out){HKEY key{};if(RegOpenKeyExW(HKEY_CURRENT_USER,L"Software\\EyeBreakReminder",0,KEY_QUERY_VALUE,&key)!=ERROR_SUCCESS)return false;wchar_t value[32768]{};DWORD type=0,bytes=sizeof(value);LONG result=RegQueryValueExW(key,L"InstallDir",nullptr,&type,reinterpret_cast<BYTE*>(value),&bytes);RegCloseKey(key);if(result!=ERROR_SUCCESS||type!=REG_SZ||!value[0])return false;out=value;return true;}
inline bool digestText(const std::string&value){return value.size()==64&&std::all_of(value.begin(),value.end(),[](unsigned char c){return (c>='0'&&c<='9')||(c>='a'&&c<='f');});}
inline bool validateTransaction(const Transaction&t,const std::wstring&transactionPath,const std::wstring&coordinatorPath,std::string&error,bool allowMissingTarget=false){
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
    if(targetAttributes==INVALID_FILE_ATTRIBUTES){if(!allowMissingTarget||GetLastError()!=ERROR_FILE_NOT_FOUND){error="The application executable is missing or inaccessible.";return false;}}
    else if((targetAttributes&(FILE_ATTRIBUTE_DIRECTORY|FILE_ATTRIBUTE_REPARSE_POINT))||!safeFile(t.targetExecutable)){error="The current application executable is not a regular file.";return false;}
    if(t.kind=="installed"&&!samePath(t.artifactPath,t.stagingDirectory+L"\\EyeBreakReminder-Setup-x64.exe")){error="The downloaded installer is not in the private staging folder.";return false;}
    if(t.nonce.size()!=36||t.nonce.find_first_not_of(L"0123456789abcdefABCDEF-")!=std::wstring::npos){error="The update confirmation token is invalid.";return false;}
    if(!digestText(t.sha256)||!digestText(t.expectedApplicationSha256)||!digestText(t.previousSha256)||t.expectedSize==0||t.expectedSize>100ull*1024*1024||t.backupMask>7||t.ownedFileMask>15||(t.deleteHistory&&!t.clean)){error="The update integrity or backup metadata is invalid.";return false;}
    return true;
}

struct UiState {std::mutex mutex;std::wstring message=L"Preparing the update…";std::atomic_bool done{false};bool success=false,dark=false,forcedColors=false;};
inline HRESULT CALLBACK coordinatorDialog(HWND dialog,UINT notification,WPARAM,LPARAM,LONG_PTR data){
    auto&state=*reinterpret_cast<UiState*>(data);
    if(notification==TDN_CREATED)eye::win::taskDialogAppearance(dialog,notification,0,0,(state.dark?1:0)|(state.forcedColors?2:0));
    if(notification==TDN_CREATED){EnableWindow(GetDlgItem(dialog,IDOK),FALSE);SendMessageW(dialog,TDM_SET_PROGRESS_BAR_MARQUEE,TRUE,80);}
    else if(notification==TDN_TIMER){std::wstring message;{std::lock_guard<std::mutex>lock(state.mutex);message=state.message;}SendMessageW(dialog,TDM_SET_ELEMENT_TEXT,TDE_CONTENT,reinterpret_cast<LPARAM>(message.c_str()));if(state.done.load()){SendMessageW(dialog,TDM_SET_PROGRESS_BAR_MARQUEE,FALSE,0);EnableWindow(GetDlgItem(dialog,IDOK),TRUE);}}
    else if(notification==TDN_BUTTON_CLICKED&&state.done.load())return S_OK;
    else if(notification==TDN_BUTTON_CLICKED)return S_FALSE;
    return S_OK;
}
inline void coordinatorMessage(UiState&state,const std::wstring&text){std::lock_guard<std::mutex>lock(state.mutex);state.message=text;}
inline std::wstring quoteArgument(const std::wstring&value){std::wstring out=L"\"";unsigned slashes=0;for(wchar_t c:value){if(c==L'\\'){++slashes;continue;}if(c==L'\"'){out.append(slashes*2+1,L'\\');out.push_back(c);}else{out.append(slashes,L'\\');out.push_back(c);}slashes=0;}out.append(slashes*2,L'\\');out.push_back(L'\"');return out;}
inline DWORD confirmationWaitMilliseconds(){
#ifdef EYEBREAK_TEST_BUILD
    wchar_t text[16]{};DWORD length=GetEnvironmentVariableW(L"EBR_GUI_TEST_CONFIRM_TIMEOUT_MS",text,DWORD(std::size(text)));if(length&&length<std::size(text)){wchar_t*end=nullptr;unsigned long value=std::wcstoul(text,&end,10);if(end&&!*end&&value>=1000&&value<=10000)return DWORD(value);}
#endif
    return 45000;
}
inline bool launchProcess(const std::wstring&image,const std::wstring&arguments,PROCESS_INFORMATION&pi){STARTUPINFOW si{};si.cb=sizeof(si);std::wstring command=quoteArgument(image)+(arguments.empty()?L"":L" "+arguments);return CreateProcessW(image.c_str(),command.data(),nullptr,nullptr,FALSE,CREATE_UNICODE_ENVIRONMENT,nullptr,parentPath(image).c_str(),&si,&pi)!=FALSE;}
inline bool writeVersionRegistry(const std::wstring&version){HKEY key{};if(RegOpenKeyExW(HKEY_CURRENT_USER,L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\EyeBreakReminder",0,KEY_SET_VALUE,&key)!=ERROR_SUCCESS)return false;LONG result=RegSetValueExW(key,L"DisplayVersion",0,REG_SZ,reinterpret_cast<const BYTE*>(version.c_str()),DWORD((version.size()+1)*sizeof(wchar_t)));RegCloseKey(key);return result==ERROR_SUCCESS;}
inline bool setStartupRegistration(const Transaction&t,bool enabled){
    HKEY key{};if(RegCreateKeyExW(HKEY_CURRENT_USER,L"Software\\Microsoft\\Windows\\CurrentVersion\\Run",0,nullptr,0,KEY_QUERY_VALUE|KEY_SET_VALUE,nullptr,&key,nullptr)!=ERROR_SUCCESS)return false;
    const std::wstring expected=L"\""+t.targetExecutable+L"\" --startup";bool ok=true;
    if(enabled)ok=RegSetValueExW(key,L"EyeBreakReminder",0,REG_SZ,reinterpret_cast<const BYTE*>(expected.c_str()),DWORD((expected.size()+1)*sizeof(wchar_t)))==ERROR_SUCCESS;
    else{wchar_t value[32768]{};DWORD type=0,bytes=sizeof(value);LONG result=RegQueryValueExW(key,L"EyeBreakReminder",nullptr,&type,reinterpret_cast<BYTE*>(value),&bytes);if(result==ERROR_SUCCESS&&type==REG_SZ&&expected==value)ok=RegDeleteValueW(key,L"EyeBreakReminder")==ERROR_SUCCESS;else if(result!=ERROR_SUCCESS&&result!=ERROR_FILE_NOT_FOUND)ok=false;}
    RegCloseKey(key);return ok;
}
inline std::wstring quoteArgument(const std::wstring&value);
inline bool copyAtomic(const std::wstring&source,const std::wstring&target){const std::wstring temp=target+L".update-restore";DeleteFileW(temp.c_str());if(!CopyFileW(source.c_str(),temp.c_str(),TRUE))return false;if(!MoveFileExW(temp.c_str(),target.c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH)){DeleteFileW(temp.c_str());return false;}return true;}
inline bool setRecoveryRegistration(const Transaction&t,bool enabled){
    HKEY key{};if(RegCreateKeyExW(HKEY_CURRENT_USER,L"Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce",0,nullptr,0,KEY_SET_VALUE,nullptr,&key,nullptr)!=ERROR_SUCCESS)return false;
    constexpr wchar_t name[]=L"!EyeBreakReminderUpdateRecovery";bool ok=true;
    if(enabled){const std::wstring helper=t.stagingDirectory+L"\\coordinator.exe",transaction=t.stagingDirectory+L"\\transaction.ini";const std::wstring command=quoteArgument(helper)+L" --update-recover "+quoteArgument(transaction);ok=RegSetValueExW(key,name,0,REG_SZ,reinterpret_cast<const BYTE*>(command.c_str()),DWORD((command.size()+1)*sizeof(wchar_t)))==ERROR_SUCCESS;}
    else{LONG result=RegDeleteValueW(key,name);ok=result==ERROR_SUCCESS||result==ERROR_FILE_NOT_FOUND;}
    RegCloseKey(key);return ok;
}
inline bool recoveryRegistrationAbsent(){HKEY key{};LONG open=RegOpenKeyExW(HKEY_CURRENT_USER,L"Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce",0,KEY_QUERY_VALUE,&key);if(open==ERROR_FILE_NOT_FOUND)return true;if(open!=ERROR_SUCCESS)return false;DWORD type=0,bytes=0;LONG result=RegQueryValueExW(key,L"!EyeBreakReminderUpdateRecovery",nullptr,&type,nullptr,&bytes);RegCloseKey(key);return result==ERROR_FILE_NOT_FOUND;}
inline bool acquireCoordinatorMutex(HANDLE&mutex,const wchar_t*name=L"Local\\EyeBreakReminder.UpdateCoordinator.1"){
    mutex=CreateMutexW(nullptr,FALSE,name);if(!mutex)return false;
    if(GetLastError()==ERROR_ALREADY_EXISTS){CloseHandle(mutex);mutex=nullptr;return false;}
    return true;
}
inline std::wstring journalPhase(const Transaction&t){std::string data;if(!eye::win::read(t.stagingDirectory+L"\\transaction-state.ini",data,4096))return{};const auto end=data.find('\n');if(end==std::string::npos||data.compare(0,6,"phase=")!=0)return{};return eye::win::wide(data.substr(6,end-6));}
inline bool backupData(Transaction&t){const wchar_t*names[]={L"settings.ini",L"timer.dat",L"history.dat"};for(unsigned i=0;i<3;++i){std::wstring path=t.dataDirectory+L"\\"+names[i];DWORD attr=GetFileAttributesW(path.c_str());if(attr==INVALID_FILE_ATTRIBUTES){if(GetLastError()==ERROR_FILE_NOT_FOUND)continue;return false;}if((attr&(FILE_ATTRIBUTE_REPARSE_POINT|FILE_ATTRIBUTE_DIRECTORY))||!safeFile(path,32ull*1024*1024))return false;const std::wstring backup=t.stagingDirectory+L"\\backup-"+std::to_wstring(i)+L".dat";if(!CopyFileW(path.c_str(),backup.c_str(),TRUE))return false;t.backupMask|=1u<<i;}return writeTransaction(t);}
inline bool backupInstalledFiles(Transaction&t){if(t.kind!="installed")return true;const wchar_t*names[]={L"Uninstall.exe",L"README.md",L"PRIVACY.md",L"VERIFICATION.md"};for(unsigned i=0;i<4;++i){const std::wstring path=parentPath(t.targetExecutable)+L"\\"+names[i];DWORD attr=GetFileAttributesW(path.c_str());if(attr==INVALID_FILE_ATTRIBUTES){if(GetLastError()==ERROR_FILE_NOT_FOUND)continue;return false;}if((attr&(FILE_ATTRIBUTE_REPARSE_POINT|FILE_ATTRIBUTE_DIRECTORY))||!safeFile(path))return false;const std::wstring backup=t.stagingDirectory+L"\\previous-owned-"+std::to_wstring(i)+L".dat";if(!CopyFileW(path.c_str(),backup.c_str(),TRUE))return false;t.ownedFileMask|=1u<<i;}return writeTransaction(t);}
inline bool restoreInstalledFiles(const Transaction&t){if(t.kind!="installed")return true;const wchar_t*names[]={L"Uninstall.exe",L"README.md",L"PRIVACY.md",L"VERIFICATION.md"};for(unsigned i=0;i<4;++i){const std::wstring target=parentPath(t.targetExecutable)+L"\\"+names[i];if(t.ownedFileMask&(1u<<i)){const std::wstring backup=t.stagingDirectory+L"\\previous-owned-"+std::to_wstring(i)+L".dat";if(!safeFile(backup)||!copyAtomic(backup,target))return false;}else{DWORD attr=GetFileAttributesW(target.c_str());if(attr!=INVALID_FILE_ATTRIBUTES){if((attr&(FILE_ATTRIBUTE_REPARSE_POINT|FILE_ATTRIBUTE_DIRECTORY))||!DeleteFileW(target.c_str()))return false;}else if(GetLastError()!=ERROR_FILE_NOT_FOUND)return false;}}return true;}
inline bool restoreData(const Transaction&t,bool restoringClean){const wchar_t*names[]={L"settings.ini",L"timer.dat",L"history.dat"};for(unsigned i=0;i<3;++i){const bool affected=restoringClean&&(i<2||t.deleteHistory);if(!affected&&!(t.backupMask&(1u<<i)))continue;const std::wstring target=t.dataDirectory+L"\\"+names[i],backup=t.stagingDirectory+L"\\backup-"+std::to_wstring(i)+L".dat";if(t.backupMask&(1u<<i)){if(!safeFile(backup,32ull*1024*1024)||!copyAtomic(backup,target))return false;}else if(affected){DWORD attr=GetFileAttributesW(target.c_str());if(attr!=INVALID_FILE_ATTRIBUTES){if((attr&(FILE_ATTRIBUTE_REPARSE_POINT|FILE_ATTRIBUTE_DIRECTORY))||!DeleteFileW(target.c_str()))return false;}else if(GetLastError()!=ERROR_FILE_NOT_FOUND)return false;}}return true;}
inline bool applyCleanPolicy(const Transaction&t){const wchar_t*names[]={L"settings.ini",L"timer.dat",L"history.dat"};for(int i=0;i<3;++i){if(i==2&&!t.deleteHistory)continue;const std::wstring path=t.dataDirectory+L"\\"+names[i];DWORD attr=GetFileAttributesW(path.c_str());if(attr==INVALID_FILE_ATTRIBUTES&&GetLastError()==ERROR_FILE_NOT_FOUND)continue;if(attr==INVALID_FILE_ATTRIBUTES||(attr&(FILE_ATTRIBUTE_REPARSE_POINT|FILE_ATTRIBUTE_DIRECTORY))||!DeleteFileW(path.c_str()))return false;}return true;}
inline bool startPrevious(const Transaction&t){if(productVersion(t.targetExecutable)!=t.previousVersion)return false;const std::wstring args=L"--update-cleanup "+quoteArgument(t.stagingDirectory)+L" "+std::to_wstring(GetCurrentProcessId());PROCESS_INFORMATION pi{};if(!launchProcess(t.targetExecutable,args,pi))return false;CloseHandle(pi.hThread);const DWORD pid=pi.dwProcessId;bool started=false;for(int i=0;i<150;++i){if(WaitForSingleObject(pi.hProcess,0)==WAIT_OBJECT_0)break;HWND window=FindWindowW(L"EyeBreakReminder.Native",nullptr);DWORD found=0;if(window)GetWindowThreadProcessId(window,&found);if(found==pid){started=true;break;}Sleep(100);}CloseHandle(pi.hProcess);return started;}
inline bool stopRunningApplication(){HWND window=FindWindowW(L"EyeBreakReminder.Native",nullptr);if(!window)return true;DWORD pid=0;GetWindowThreadProcessId(window,&pid);if(!pid||pid==GetCurrentProcessId())return false;HANDLE process=OpenProcess(SYNCHRONIZE,FALSE,pid);if(!process)return GetLastError()==ERROR_INVALID_PARAMETER;const UINT quit=RegisterWindowMessageW(L"EyeBreakReminder.Exit.Native.1");DWORD_PTR ignored=0;SendMessageTimeoutW(window,quit,0,0,SMTO_ABORTIFHUNG,5000,&ignored);const DWORD wait=WaitForSingleObject(process,60000);CloseHandle(process);return wait==WAIT_OBJECT_0;}
inline bool restorePreviousVersion(const Transaction&t){
    const std::wstring backup=t.stagingDirectory+L"\\previous.exe";std::string digest;
    if(!safeFile(backup)||productVersion(backup)!=t.previousVersion||!hashFile(backup,digest)||digest!=t.previousSha256)return false;
    if(!stopRunningApplication())return false;
    const bool appRestored=copyAtomic(backup,t.targetExecutable);
    const bool filesRestored=appRestored&&restoreInstalledFiles(t);
    const bool dataRestored=filesRestored&&restoreData(t,t.clean);
    const bool versionRestored=dataRestored&&(t.kind!="installed"||writeVersionRegistry(t.previousVersion));
    const bool startupRestored=versionRestored&&(!t.clean||setStartupRegistration(t,t.previousStartup));
    if(!startupRestored)return false;
    if(!writeJournal(t,L"recovered"))return false;
    if(!setRecoveryRegistration(t,false))return false;
    return startPrevious(t);
}
inline int runRecovery(const std::wstring&transactionPath){
    Transaction t;if(!readTransaction(transactionPath,t)){MessageBoxW(nullptr,L"The saved update recovery record is invalid. No files were changed; keep the recovery folder for manual review.",L"Eye Break Reminder Recovery",MB_OK|MB_ICONERROR);return 2;}
    std::string error;if(!validateTransaction(t,transactionPath,t.stagingDirectory+L"\\coordinator.exe",error,true)){MessageBoxW(nullptr,eye::win::wide(error).c_str(),L"Eye Break Reminder Recovery",MB_OK|MB_ICONERROR);return 2;}
    const std::wstring phase=journalPhase(t);
    if(phase==L"complete"||phase==L"recovered"){setRecoveryRegistration(t,false);return 0;}
    if(phase==L"verified"){setRecoveryRegistration(t,false);return 0;}
    if(phase!=L"installing"&&phase!=L"installed"&&phase!=L"cleaning"&&phase!=L"starting")return 2;
    HANDLE single{};if(!acquireCoordinatorMutex(single))return 3;
    const bool restored=restorePreviousVersion(t);CloseHandle(single);
    if(!restored){setRecoveryRegistration(t,true);MessageBoxW(nullptr,L"Eye Break Reminder could not finish automatic recovery. The previous application and data backups remain in the updates folder. Close Eye Break Reminder and run the saved coordinator again, or contact support with the recovery folder contents.",L"Eye Break Reminder Recovery",MB_OK|MB_ICONERROR);return 1;}
    return 0;
}

inline void performTransaction(Transaction t,UiState&ui){
    auto fail=[&](const std::wstring&message){coordinatorMessage(ui,message);ui.success=false;ui.done=true;};
    std::string error;if(!validateTransaction(t,t.stagingDirectory+L"\\transaction.ini",t.stagingDirectory+L"\\coordinator.exe",error)){fail(eye::win::wide(error));return;}
    HANDLE single{};if(!acquireCoordinatorMutex(single)){fail(L"Another update operation is already running. Close it before trying again.");return;}
    auto rollback=[&](const wchar_t*message){coordinatorMessage(ui,L"Restoring the previous application and its data…");const bool restored=restorePreviousVersion(t);CloseHandle(single);fail(restored?message:L"Automatic rollback could not finish. The previous executable and data backup remain in the updates folder, and Windows will retry recovery at the next sign-in.");};
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
    if(!writeJournal(t,L"verified")||!setRecoveryRegistration(t,true)||!writeJournal(t,L"installing")){setRecoveryRegistration(t,false);abortBeforeInstall(L"Windows could not save the durable recovery information. The current application was not changed.");return;}
    coordinatorMessage(ui,L"Installing the verified update…");bool installed=false;
    if(t.kind=="installed"){
        PROCESS_INFORMATION setup{};if(launchProcess(t.artifactPath,L"/S",setup)){CloseHandle(setup.hThread);DWORD wait=WaitForSingleObject(setup.hProcess,10*60*1000);DWORD code=1;if(wait==WAIT_OBJECT_0)GetExitCodeProcess(setup.hProcess,&code);else {coordinatorMessage(ui,L"The installer is taking longer than expected. Waiting for it to finish safely…");wait=WaitForSingleObject(setup.hProcess,INFINITE);if(wait==WAIT_OBJECT_0)GetExitCodeProcess(setup.hProcess,&code);}CloseHandle(setup.hProcess);installed=wait==WAIT_OBJECT_0&&code==0;}
    }else{
        const std::wstring temp=t.targetExecutable+L".update-new";DeleteFileW(temp.c_str());std::string tempHash;installed=CopyFileW(t.artifactPath.c_str(),temp.c_str(),TRUE)&&productVersion(temp)==t.version&&hashFile(temp,tempHash)&&tempHash==t.expectedApplicationSha256&&MoveFileExW(temp.c_str(),t.targetExecutable.c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH);if(!installed)DeleteFileW(temp.c_str());
    }
    std::string installedHash;if(!installed||productVersion(t.targetExecutable)!=t.version||!hashFile(t.targetExecutable,installedHash)||installedHash!=t.expectedApplicationSha256){rollback(L"The update failed. The previous version was restored and restarted with its data.");return;}
    if(!writeJournal(t,L"installed")){rollback(L"The update could not save its installation state. The previous version was restored and restarted.");return;}
    if(t.clean){coordinatorMessage(ui,L"Applying the confirmed clean-install settings…");if(!writeJournal(t,L"cleaning")||!applyCleanPolicy(t)||!setStartupRegistration(t,false)){rollback(L"The clean install could not finish. The previous version and its data were restored.");return;}}
    if(!writeJournal(t,L"starting")){rollback(L"The update could not save its startup state. The previous version was restored and restarted.");return;}
    coordinatorMessage(ui,L"Starting the updated application and waiting for its startup confirmation…");
    const std::wstring eventName=L"Local\\EyeBreakReminder.UpdateConfirm."+t.nonce;HANDLE confirmed=CreateEventW(nullptr,TRUE,FALSE,eventName.c_str());PROCESS_INFORMATION app{};const std::wstring args=L"--update-confirm "+t.nonce+L" --update-cleanup "+quoteArgument(t.stagingDirectory)+L" "+std::to_wstring(GetCurrentProcessId());
    bool running=confirmed&&launchProcess(t.targetExecutable,args,app);bool launched=running&&WaitForSingleObject(confirmed,confirmationWaitMilliseconds())==WAIT_OBJECT_0;if(confirmed)CloseHandle(confirmed);
    if(running&&!launched){UINT quit=RegisterWindowMessageW(L"EyeBreakReminder.Exit.Native.1");DWORD_PTR ignored=0;SendMessageTimeoutW(FindWindowW(L"EyeBreakReminder.Native",nullptr),quit,0,0,SMTO_ABORTIFHUNG,5000,&ignored);DWORD wait=WaitForSingleObject(app.hProcess,10000);CloseHandle(app.hThread);CloseHandle(app.hProcess);if(wait!=WAIT_OBJECT_0){CloseHandle(single);fail(L"The new application did not confirm startup and did not close safely. The previous executable and data backup remain available; no process was forced to stop.");return;}}
    else if(running){CloseHandle(app.hThread);CloseHandle(app.hProcess);}
    if(!launched){rollback(L"The updated application did not start. The previous version was restored and restarted with its data.");return;}
    if(!writeJournal(t,L"complete")){rollback(L"The new application started, but its durable completion record could not be saved. The previous version was restored and restarted.");return;}
    setRecoveryRegistration(t,false);CloseHandle(single);ui.success=true;coordinatorMessage(ui,L"Update complete. The new version started successfully. Your settings and history follow the choices you confirmed.");ui.done=true;
}

inline int runCoordinator(const std::wstring&transactionPath){
    Transaction t;if(!readTransaction(transactionPath,t)){MessageBoxW(nullptr,L"The update transaction is missing or invalid. No downloaded file was executed.",L"Eye Break Reminder Update",MB_OK|MB_ICONERROR);return 2;}
    UiState ui;std::thread worker;try{worker=std::thread([t,&ui]{try{performTransaction(t,ui);}catch(...){coordinatorMessage(ui,L"The update coordinator stopped unexpectedly. Recovery files have been retained.");ui.success=false;ui.done=true;}});}catch(...){MessageBoxW(nullptr,L"Windows could not start the update coordinator.",L"Eye Break Reminder Update",MB_OK|MB_ICONERROR);return 3;}
    const TASKDIALOG_BUTTON buttons[]={{IDOK,L"Close"}};TASKDIALOGCONFIG cfg{};cfg.cbSize=sizeof(cfg);cfg.dwFlags=TDF_SIZE_TO_CONTENT|TDF_CALLBACK_TIMER|TDF_SHOW_PROGRESS_BAR;cfg.pszWindowTitle=L"Eye Break Reminder Update";cfg.pszMainInstruction=L"Updating Eye Break Reminder";cfg.pszContent=L"Preparing the update…";cfg.cButtons=1;cfg.pButtons=buttons;cfg.nDefaultButton=IDOK;cfg.pfCallback=coordinatorDialog;cfg.lpCallbackData=reinterpret_cast<LONG_PTR>(&ui);cfg.dwCommonButtons=0;
    DWORD light=1,size=sizeof(light);RegGetValueW(HKEY_CURRENT_USER,L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",L"AppsUseLightTheme",RRF_RT_REG_DWORD,nullptr,&light,&size);HIGHCONTRASTW contrast{};contrast.cbSize=sizeof(contrast);SystemParametersInfoW(SPI_GETHIGHCONTRAST,sizeof(contrast),&contrast,0);ui.dark=light==0;ui.forcedColors=(contrast.dwFlags&HCF_HIGHCONTRASTON)!=0;cfg.pfCallback=coordinatorDialog;cfg.lpCallbackData=reinterpret_cast<LONG_PTR>(&ui);
    int button=0;HRESULT shown=TaskDialogIndirect(&cfg,&button,nullptr,nullptr);if(FAILED(shown)){while(!ui.done.load())Sleep(50);}if(worker.joinable())worker.join();return ui.success?0:1;
}

} // namespace eye::updates
