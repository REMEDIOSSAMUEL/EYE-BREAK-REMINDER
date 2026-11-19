#define EYEBREAK_TEST_BUILD
#include <winsock2.h>
#undef NOMINMAX
#include "../src/update_coordinator.hpp"
#include <windows.h>
#include <atomic>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>
#include <cstring>
#include <cstdlib>
#include <objbase.h>

namespace {
int assertions=0;
bool check(bool value,const char*name){++assertions;if(!value)std::cerr<<"FAIL: "<<name<<'\n';return value;}
bool writeBytes(const std::wstring&path,const std::string&value){HANDLE file=CreateFileW(path.c_str(),GENERIC_WRITE,0,nullptr,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,nullptr);if(file==INVALID_HANDLE_VALUE)return false;DWORD wrote=0;const bool ok=WriteFile(file,value.data(),DWORD(value.size()),&wrote,nullptr)&&wrote==value.size();CloseHandle(file);return ok;}
struct RefusedLoopbackPort {
    using StartupFn=int (WSAAPI*)(WORD,LPWSADATA);using SocketFn=SOCKET (WSAAPI*)(int,int,int);using BindFn=int (WSAAPI*)(SOCKET,const sockaddr*,int);using NameFn=int (WSAAPI*)(SOCKET,sockaddr*,int*);using InetAddrFn=u_long (WSAAPI*)(const char*);using NtohsFn=u_short (WSAAPI*)(u_short);using CloseFn=int (WSAAPI*)(SOCKET);using CleanupFn=int (WSAAPI*)();
    HMODULE module{};SOCKET reservation=INVALID_SOCKET;CloseFn closeSocket{};CleanupFn cleanup{};bool winsockStarted=false;unsigned short port=0;
    template<class Function> Function loadProc(const char*name){const FARPROC raw=GetProcAddress(module,name);Function function{};static_assert(sizeof(function)==sizeof(raw));std::memcpy(&function,&raw,sizeof(function));return function;}
    bool open(){
        module=LoadLibraryW(L"Ws2_32.dll");if(!module)return false;
        const auto startup=loadProc<StartupFn>("WSAStartup");const auto createSocket=loadProc<SocketFn>("socket");const auto bindSocket=loadProc<BindFn>("bind");const auto socketName=loadProc<NameFn>("getsockname");const auto address=loadProc<InetAddrFn>("inet_addr");const auto networkToHostPort=loadProc<NtohsFn>("ntohs");closeSocket=loadProc<CloseFn>("closesocket");cleanup=loadProc<CleanupFn>("WSACleanup");
        if(!startup||!createSocket||!bindSocket||!socketName||!address||!networkToHostPort||!closeSocket||!cleanup)return false;
        WSADATA data{};if(startup(MAKEWORD(2,2),&data)!=0)return false;winsockStarted=true;reservation=createSocket(AF_INET,SOCK_STREAM,IPPROTO_TCP);if(reservation==INVALID_SOCKET)return false;
        sockaddr_in endpoint{};endpoint.sin_family=AF_INET;endpoint.sin_addr.s_addr=address("127.0.0.1");endpoint.sin_port=0;if(endpoint.sin_addr.s_addr==INADDR_NONE||bindSocket(reservation,reinterpret_cast<const sockaddr*>(&endpoint),sizeof(endpoint))!=0)return false;
        int length=sizeof(endpoint);if(socketName(reservation,reinterpret_cast<sockaddr*>(&endpoint),&length)!=0||length!=sizeof(endpoint))return false;port=networkToHostPort(endpoint.sin_port);return port>=1024;
    }
    void close(){if(reservation!=INVALID_SOCKET&&closeSocket){closeSocket(reservation);reservation=INVALID_SOCKET;}if(winsockStarted&&cleanup){cleanup();winsockStarted=false;}if(module){FreeLibrary(module);module=nullptr;}}
    ~RefusedLoopbackPort(){close();}
};
bool testInitialConnectionRefusal(const std::wstring&stage){
    RefusedLoopbackPort endpoint;if(!endpoint.open())return check(false,"reserve an unlistened loopback TCP port for deterministic connection refusal");
    // Keep the socket bound but never listen so no competing local process can
    // claim the port while WinHTTP receives a refused loopback connection.
    wchar_t priorProxy[128]{};const DWORD priorLength=GetEnvironmentVariableW(L"EBR_TEST_HTTPS_PROXY",priorProxy,DWORD(std::size(priorProxy)));if(priorLength>=std::size(priorProxy))return check(false,"read a bounded prior test proxy setting");
    const std::wstring testProxy=L"127.0.0.1:"+std::to_wstring(endpoint.port);if(!SetEnvironmentVariableW(L"EBR_TEST_HTTPS_PROXY",testProxy.c_str()))return check(false,"set the isolated loopback proxy for the connection-refusal test");
    const std::wstring sentinel=stage+L"\\connection-refusal-prior-app.sentinel";bool ok=check(writeBytes(sentinel,"existing-app-must-remain-unchanged"),"create the prior-app sentinel for connection refusal");
    eye::updates::ReleaseAsset asset;asset.name="EyeBreakReminder-Setup-x64.exe";asset.size=3;asset.digest="sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";asset.downloadUrl="https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/download/v1.3.0/EyeBreakReminder-Setup-x64.exe";
    std::atomic_bool cancelled{false};const auto result=eye::updates::downloadVerified(asset,stage,L"EyeBreakReminder-Setup-x64.exe",cancelled);
    const bool restoredProxy=priorLength?SetEnvironmentVariableW(L"EBR_TEST_HTTPS_PROXY",std::wstring(priorProxy,priorLength).c_str())!=FALSE:SetEnvironmentVariableW(L"EBR_TEST_HTTPS_PROXY",nullptr)!=FALSE;
    std::string sentinelContents;const bool priorAppUntouched=eye::win::read(sentinel,sentinelContents,128)&&sentinelContents=="existing-app-must-remain-unchanged";const bool noPartial=GetFileAttributesW((stage+L"\\EyeBreakReminder-Setup-x64.exe.part").c_str())==INVALID_FILE_ATTRIBUTES;const bool noInstaller=GetFileAttributesW((stage+L"\\EyeBreakReminder-Setup-x64.exe").c_str())==INVALID_FILE_ATTRIBUTES;
    ok&=check(restoredProxy,"restore the caller's prior loopback-proxy environment setting");ok&=check(!result.ok&&!result.cancelled&&result.received==0&&!result.error.empty()&&result.error.find("connect")!=std::string::npos,"an initial refused HTTPS connection returns an actionable failure without accepting bytes");ok&=check(noPartial&&noInstaller,"initial connection refusal removes the partial file and does not stage an installer");ok&=check(priorAppUntouched,"initial connection refusal leaves the existing app sentinel byte-for-byte unchanged");ok&=check(DeleteFileW(sentinel.c_str())!=FALSE,"remove the connection-refusal prior-app sentinel after the assertion");return ok;
}
bool createTestJunction(const std::wstring&link,const std::wstring&target){wchar_t systemDirectory[MAX_PATH]{};const UINT length=GetSystemDirectoryW(systemDirectory,MAX_PATH);if(!length||length>=MAX_PATH)return false;const std::wstring command=L"\""+std::wstring(systemDirectory)+L"\\cmd.exe\" /d /c mklink /J \""+link+L"\" \""+target+L"\"";std::vector<wchar_t>buffer(command.begin(),command.end());buffer.push_back(L'\0');STARTUPINFOW startup{};startup.cb=sizeof(startup);PROCESS_INFORMATION process{};if(!CreateProcessW(nullptr,buffer.data(),nullptr,nullptr,FALSE,CREATE_NO_WINDOW,nullptr,nullptr,&startup,&process))return false;WaitForSingleObject(process.hProcess,INFINITE);DWORD exitCode=1;GetExitCodeProcess(process.hProcess,&exitCode);CloseHandle(process.hThread);CloseHandle(process.hProcess);const DWORD attributes=GetFileAttributesW(link.c_str());return exitCode==0&&attributes!=INVALID_FILE_ATTRIBUTES&&(attributes&FILE_ATTRIBUTE_REPARSE_POINT)!=0;}
std::wstring asciiWide(const char*text){std::wstring result;for(;*text;++text)result.push_back(static_cast<unsigned char>(*text));return result;}
int holdTestCoordinatorMutex(const char*nonce){
    const std::wstring suffix=asciiWide(nonce),mutexName=L"Local\\EyeBreakReminder.UpdaterTest.CrossProcess."+suffix;
    const std::wstring readyName=L"Local\\EyeBreakReminder.UpdaterTest.Ready."+suffix,releaseName=L"Local\\EyeBreakReminder.UpdaterTest.Release."+suffix;
    HANDLE mutex{};if(!eye::updates::acquireCoordinatorMutex(mutex,mutexName.c_str()))return 10;
    HANDLE ready=OpenEventW(EVENT_MODIFY_STATE,FALSE,readyName.c_str()),release=OpenEventW(SYNCHRONIZE,FALSE,releaseName.c_str());
    if(!ready||!release){if(ready)CloseHandle(ready);if(release)CloseHandle(release);CloseHandle(mutex);return 11;}
    const bool signalled=SetEvent(ready)!=FALSE;const DWORD wait=signalled?WaitForSingleObject(release,15000):WAIT_FAILED;
    CloseHandle(release);CloseHandle(ready);CloseHandle(mutex);return wait==WAIT_OBJECT_0?0:12;
}
bool testCrossProcessCoordinatorMutex(){
    GUID id{};wchar_t guid[40]{};if(FAILED(CoCreateGuid(&id))||!StringFromGUID2(id,guid,40))return false;
    std::wstring suffix(guid);suffix.erase(std::remove(suffix.begin(),suffix.end(),L'{'),suffix.end());suffix.erase(std::remove(suffix.begin(),suffix.end(),L'}'),suffix.end());
    const std::string nonce(suffix.begin(),suffix.end());const std::wstring mutexName=L"Local\\EyeBreakReminder.UpdaterTest.CrossProcess."+suffix;
    const std::wstring readyName=L"Local\\EyeBreakReminder.UpdaterTest.Ready."+suffix,releaseName=L"Local\\EyeBreakReminder.UpdaterTest.Release."+suffix;
    SetLastError(ERROR_SUCCESS);HANDLE ready=CreateEventW(nullptr,TRUE,FALSE,readyName.c_str());if(!ready)return false;
    const bool readyWasNew=GetLastError()!=ERROR_ALREADY_EXISTS;
    SetLastError(ERROR_SUCCESS);HANDLE release=CreateEventW(nullptr,TRUE,FALSE,releaseName.c_str());if(!release){CloseHandle(ready);return false;}
    const bool releaseWasNew=GetLastError()!=ERROR_ALREADY_EXISTS;
    if(!readyWasNew||!releaseWasNew){CloseHandle(release);CloseHandle(ready);return false;}
    std::vector<wchar_t>module(32768);const DWORD moduleLength=GetModuleFileNameW(nullptr,module.data(),DWORD(module.size()));
    if(!moduleLength||moduleLength>=module.size()){CloseHandle(release);CloseHandle(ready);return false;}
    const std::wstring executable(module.data(),moduleLength);const std::wstring command=L"\""+executable+L"\" --hold-test-coordinator-mutex "+asciiWide(nonce.c_str());
    std::vector<wchar_t>commandLine(command.begin(),command.end());commandLine.push_back(L'\0');STARTUPINFOW startup{};startup.cb=sizeof(startup);PROCESS_INFORMATION child{};
    const BOOL started=CreateProcessW(executable.c_str(),commandLine.data(),nullptr,nullptr,FALSE,CREATE_NO_WINDOW,nullptr,nullptr,&startup,&child);
    bool ok=check(started!=FALSE,"start a separate updater test process to hold the coordinator mutex");
    if(started){
        const bool childReady=WaitForSingleObject(ready,5000)==WAIT_OBJECT_0;
        ok&=check(childReady,"child process signals readiness only after creating the unique coordinator mutex");
        HANDLE duplicate{};const bool secondRejected=childReady&&!eye::updates::acquireCoordinatorMutex(duplicate,mutexName.c_str())&&duplicate==nullptr;
        ok&=check(secondRejected,"a separate process cannot acquire a second updater coordinator while the first process holds its named mutex handle");
        const bool released=SetEvent(release)!=FALSE;const DWORD childWait=WaitForSingleObject(child.hProcess,17000);DWORD childExit=DWORD(-1);if(childWait==WAIT_OBJECT_0)GetExitCodeProcess(child.hProcess,&childExit);
        ok&=check(released&&childWait==WAIT_OBJECT_0&&childExit==0,"child coordinator exits cleanly after the parent releases the test event");
        HANDLE retry{};const bool reacquired=childWait==WAIT_OBJECT_0&&childExit==0&&eye::updates::acquireCoordinatorMutex(retry,mutexName.c_str());
        ok&=check(reacquired,"a new updater coordinator can acquire the mutex after the child process exits");if(retry)CloseHandle(retry);
        CloseHandle(child.hThread);CloseHandle(child.hProcess);
    }
    CloseHandle(release);CloseHandle(ready);return ok;
}
int runHttpsInterruption(int argc,char**argv){
    std::cerr<<"HTTPS test stage: entered runHttpsInterruption"<<std::endl;
    if(argc!=4){std::cerr<<"Usage: updater-windows-tests --https-interruption <proxy-port> <staging-directory>\n";return 2;}
    const unsigned long port=std::strtoul(argv[2],nullptr,10);if(port<1024||port>65535){std::cerr<<"Invalid loopback test proxy port.\n";return 2;}
    std::cerr<<"HTTPS test stage: parsed proxy port"<<std::endl;
    const std::wstring stage=std::filesystem::path(argv[3]).wstring();bool ok=true;
    std::cerr<<"HTTPS test stage: converted isolated staging path"<<std::endl;
    wchar_t configuredProxy[128]{};const DWORD proxyLength=GetEnvironmentVariableW(L"EBR_TEST_HTTPS_PROXY",configuredProxy,DWORD(std::size(configuredProxy)));
    const std::wstring expectedProxy=L"127.0.0.1:"+std::to_wstring(port);
    std::cerr<<"HTTPS test stage: read the process proxy setting"<<std::endl;
    ok&=check(proxyLength==expectedProxy.size()&&std::wstring(configuredProxy,proxyLength)==expectedProxy,"test process uses only the isolated loopback HTTPS CONNECT proxy");
    std::cerr<<"HTTPS test stage: querying the real public GitHub release API"<<std::endl;
    const auto response=eye::updates::latestStableReleaseResponse();eye::updates::ReleaseDetails release;
    std::cerr<<"HTTPS test stage: GitHub release API request returned"<<std::endl;
    const auto checked=eye::updates::evaluate(response,"1.4.0",&release);
    ok&=check(response.status==200&&checked.state==eye::updates::State::InstalledNewer&&release.tag=="v1.3.0","discover the current official stable release from the real GitHub API without credentials");
    const auto selected=eye::updates::selectAsset(release,eye::updates::PackageKind::Portable);
    ok&=check(selected.ok&&selected.asset.name=="EyeBreakReminder.exe"&&selected.asset.downloadUrl.rfind("https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/download/v1.3.0/",0)==0,"select the official stable standalone release asset and validated digest");
    if(!ok)return 1;
    const auto&asset=selected.asset;
    const auto digestSeparator=asset.digest.find(':');const std::string expected=eye::updates::client_detail::lower(asset.digest.substr(digestSeparator+1));
    std::atomic_bool cancelled{false};const std::wstring sentinel=stage+L"\\working-app.sentinel";
    ok&=check(writeBytes(sentinel,"installed-v1.4.0"),"create isolated prior-install sentinel");
    std::cerr<<"HTTPS test stage: requesting the first official asset through the proxy"<<std::endl;
    auto interrupted=eye::updates::downloadVerified(asset,stage,L"EyeBreakReminder.exe",cancelled);
    std::cerr<<"HTTPS test stage: first transfer returned"<<std::endl;
    std::string oldContents;eye::win::read(sentinel,oldContents,128);
    ok&=check(!interrupted.ok&&!interrupted.cancelled&&interrupted.received>0&&interrupted.received<asset.size&&
              GetFileAttributesW((stage+L"\\EyeBreakReminder.exe.part").c_str())==INVALID_FILE_ATTRIBUTES&&
              GetFileAttributesW((stage+L"\\EyeBreakReminder.exe").c_str())==INVALID_FILE_ATTRIBUTES&&oldContents=="installed-v1.4.0",
              "unexpected mid-body HTTPS interruption rejects and removes partial bytes while preserving the prior app sentinel");
    bool sawVerify=false;std::uint64_t finalProgress=0;
    std::cerr<<"HTTPS test stage: requesting a fresh verified asset retry"<<std::endl;
    auto retried=eye::updates::downloadVerified(asset,stage,L"EyeBreakReminder.exe",cancelled,[&](auto p){finalProgress=p.received;if(p.verifying)sawVerify=true;});
    std::cerr<<"HTTPS test stage: verified retry returned"<<std::endl;
    ok&=check(retried.ok&&retried.received==asset.size&&retried.sha256==expected&&finalProgress==asset.size&&sawVerify,
              "a fresh HTTPS retry downloads the real public asset, reports byte progress and verifies GitHub's SHA-256 digest");
    ok&=check(oldContents=="installed-v1.4.0"&&DeleteFileW(sentinel.c_str())!=FALSE,"successful retry still leaves the existing application untouched before installer coordination");
    if(!ok)return 1;
    std::cout<<"PASS: "<<assertions<<" real GitHub HTTPS interruption and retry assertions executed; release="<<release.tag<<" asset="<<asset.name<<" bytes="<<asset.size<<" sha256="<<retried.sha256<<".\n";return 0;
}
}

int main(int argc,char**argv){
    if(argc==3&&std::string(argv[1])=="--hold-test-coordinator-mutex")return holdTestCoordinatorMutex(argv[2]);
    if(argc>1&&std::string(argv[1])=="--https-interruption")return runHttpsInterruption(argc,argv);
    const auto folder=std::filesystem::current_path()/"build"/"updater-windows-tests";
    if(!CreateDirectoryW(folder.c_str(),nullptr)){std::cerr<<"FAIL: isolated test folder must be new; refusing to reuse or remove it\n";return 1;}
    const std::wstring stage=folder.wstring();bool ok=true;
    ok&=check(eye::updates::safeStagingDirectory(stage),"isolated staging directory is a regular non-reparse path");
    ok&=testInitialConnectionRefusal(stage);
    const std::wstring testMutexName=L"Local\\EyeBreakReminder.UpdaterTest."+std::to_wstring(GetCurrentProcessId());HANDLE firstMutex{},duplicateMutex{};
    const bool firstAcquired=eye::updates::acquireCoordinatorMutex(firstMutex,testMutexName.c_str());const bool duplicateRejected=!eye::updates::acquireCoordinatorMutex(duplicateMutex,testMutexName.c_str())&&duplicateMutex==nullptr;
    ok&=check(firstAcquired&&duplicateRejected,"a repeated update attempt cannot acquire a second coordinator mutex");if(firstMutex)CloseHandle(firstMutex);
    HANDLE retryMutex{};const bool retryAcquired=eye::updates::acquireCoordinatorMutex(retryMutex,testMutexName.c_str());ok&=check(retryAcquired,"a new update attempt can acquire the coordinator after the prior attempt exits");if(retryMutex)CloseHandle(retryMutex);
    ok&=testCrossProcessCoordinatorMutex();
    const std::wstring source=stage+L"\\fixture.bin";ok&=check(writeBytes(source,"abc"),"create deterministic local test fixture");
    eye::updates::ReleaseAsset asset{"EyeBreakReminder.exe","https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/download/v1.4.1/EyeBreakReminder.exe","sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",3};
    std::atomic_bool cancelled{false};bool sawVerify=false;std::uint64_t progressed=0;
    auto valid=eye::updates::downloadVerifiedFixture(asset,source,stage,L"EyeBreakReminder.exe",cancelled,[&](auto p){progressed=p.received;if(p.verifying)sawVerify=true;});
    ok&=check(valid.ok&&valid.received==3&&valid.sha256==asset.digest.substr(7)&&sawVerify&&progressed==3,"valid fixture streams, reports bytes and verifies SHA-256");
    ok&=check(DeleteFileW((stage+L"\\EyeBreakReminder.exe").c_str())!=FALSE,"remove only the test output executable");
    asset.size=4;auto interrupted=eye::updates::downloadVerifiedFixture(asset,source,stage,L"EyeBreakReminder.exe",cancelled);
    ok&=check(!interrupted.ok&&interrupted.error.find("interrupted")!=std::string::npos&&GetFileAttributesW((stage+L"\\EyeBreakReminder.exe.part").c_str())==INVALID_FILE_ATTRIBUTES,"an incomplete streamed fixture is rejected and its partial file is removed");asset.size=3;
    asset.digest="sha256:0000000000000000000000000000000000000000000000000000000000000000";
    auto mismatch=eye::updates::downloadVerifiedFixture(asset,source,stage,L"EyeBreakReminder.exe",cancelled);
    ok&=check(!mismatch.ok&&mismatch.error.find("SHA-256")!=std::string::npos&&GetFileAttributesW((stage+L"\\EyeBreakReminder.exe").c_str())==INVALID_FILE_ATTRIBUTES&&GetFileAttributesW((stage+L"\\EyeBreakReminder.exe.part").c_str())==INVALID_FILE_ATTRIBUTES,"hash mismatch removes partial and verified-output files");
    asset.digest="sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";cancelled=true;
    auto cancel=eye::updates::downloadVerifiedFixture(asset,source,stage,L"EyeBreakReminder.exe",cancelled);
    ok&=check(cancel.cancelled&&!cancel.ok&&GetFileAttributesW((stage+L"\\EyeBreakReminder.exe.part").c_str())==INVALID_FILE_ATTRIBUTES,"cancel removes the partial fixture download");cancelled=false;
    auto badName=eye::updates::downloadVerifiedFixture(asset,source,stage,L"..\\outside.exe",cancelled);
    ok&=check(!badName.ok&&GetFileAttributesW((stage+L"\\outside.exe").c_str())==INVALID_FILE_ATTRIBUTES,"unsupported output filename is rejected");
    asset.downloadUrl="https://updates.example.invalid/EyeBreakReminder.exe";
    auto unsafe=eye::updates::downloadVerified(asset,stage,L"EyeBreakReminder.exe",cancelled);
    ok&=check(!unsafe.ok&&GetFileAttributesW((stage+L"\\EyeBreakReminder.exe.part").c_str())==INVALID_FILE_ATTRIBUTES,"untrusted download host is rejected without leaving a partial file");
    eye::updates::ReleaseAsset policyAsset{"EyeBreakReminder.exe","https://localhost:8443/EyeBreakReminder.exe","sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",3};
    SetEnvironmentVariableW(L"EBR_GUI_TEST_FAIL_DOWNLOAD_TIMEOUTS",L"1");
    auto timeoutPolicyFailure=eye::updates::downloadVerified(policyAsset,stage,L"EyeBreakReminder.exe",cancelled);
    SetEnvironmentVariableW(L"EBR_GUI_TEST_FAIL_DOWNLOAD_TIMEOUTS",nullptr);
    ok&=check(!timeoutPolicyFailure.ok&&timeoutPolicyFailure.error.find("bounded secure download timeouts")!=std::string::npos&&timeoutPolicyFailure.received==0&&
              GetFileAttributesW((stage+L"\\EyeBreakReminder.exe.part").c_str())==INVALID_FILE_ATTRIBUTES&&
              GetFileAttributesW((stage+L"\\EyeBreakReminder.exe").c_str())==INVALID_FILE_ATTRIBUTES,
              "failure to configure bounded HTTPS timeouts fails closed and removes all staged bytes");
    SetEnvironmentVariableW(L"EBR_GUI_TEST_FAIL_REDIRECT_LOCKDOWN",L"1");
    auto redirectPolicyFailure=eye::updates::downloadVerified(policyAsset,stage,L"EyeBreakReminder.exe",cancelled);
    SetEnvironmentVariableW(L"EBR_GUI_TEST_FAIL_REDIRECT_LOCKDOWN",nullptr);
    ok&=check(!redirectPolicyFailure.ok&&redirectPolicyFailure.error.find("disable automatic redirects")!=std::string::npos&&redirectPolicyFailure.received==0&&
              GetFileAttributesW((stage+L"\\EyeBreakReminder.exe.part").c_str())==INVALID_FILE_ATTRIBUTES&&
              GetFileAttributesW((stage+L"\\EyeBreakReminder.exe").c_str())==INVALID_FILE_ATTRIBUTES,
              "failure to disable WinHTTP automatic redirects fails closed before sending a request and cleans the partial file");

    const std::wstring install=stage+L"\\install";CreateDirectoryW(install.c_str(),nullptr);const wchar_t*ownedNames[]={L"Uninstall.exe",L"README.md",L"PRIVACY.md",L"VERIFICATION.md"};for(unsigned i:{0u,1u,3u})ok&=check(writeBytes(install+L"\\"+ownedNames[i],"previous-owned-file"),"create exact test installer-owned file");
    eye::updates::Transaction installedFiles;installedFiles.stagingDirectory=stage;installedFiles.targetExecutable=install+L"\\EyeBreakReminder.exe";installedFiles.kind="installed";
    ok&=check(eye::updates::backupInstalledFiles(installedFiles)&&installedFiles.ownedFileMask==11,"backup only present installer-owned files and record their exact mask");
    for(const auto*name:ownedNames)ok&=check(writeBytes(install+L"\\"+name,"replacement-owned-file"),"simulate NSIS replacing an owned file");
    ok&=check(writeBytes(stage+L"\\previous-owned-3.dat","CORRUPTED-OWNED-BACKUP"),"corrupt a later staged installer-owned-file backup");
    const bool corruptedOwnedRejected=!eye::updates::restoreInstalledFiles(installedFiles);std::string stillReplacement;
    ok&=check(corruptedOwnedRejected&&eye::win::read(install+L"\\Uninstall.exe",stillReplacement,128)&&stillReplacement=="replacement-owned-file"&&eye::win::read(install+L"\\README.md",stillReplacement,128)&&stillReplacement=="replacement-owned-file"&&GetFileAttributesW((install+L"\\Uninstall.exe.update-restore").c_str())==INVALID_FILE_ATTRIBUTES&&GetFileAttributesW((install+L"\\README.md.update-restore").c_str())==INVALID_FILE_ATTRIBUTES,"reject a later corrupted owned-file backup before changing earlier files and remove all prepared restore files");
    ok&=check(writeBytes(stage+L"\\previous-owned-3.dat","previous-owned-file"),"restore exact owned-file backup fixture after the rejection check");
    ok&=check(eye::updates::restoreInstalledFiles(installedFiles),"restore previous uninstaller and installed documentation");
    std::string restored;ok&=check(eye::win::read(install+L"\\Uninstall.exe",restored,128)&&restored=="previous-owned-file"&&eye::win::read(install+L"\\README.md",restored,128)&&restored=="previous-owned-file"&&eye::win::read(install+L"\\VERIFICATION.md",restored,128)&&restored=="previous-owned-file"&&GetFileAttributesW((install+L"\\PRIVACY.md").c_str())==INVALID_FILE_ATTRIBUTES,"restore original contents and remove only files absent before the update");
    eye::updates::Transaction transaction;transaction.stagingDirectory=stage;transaction.artifactPath=stage+L"\\EyeBreakReminder.exe";transaction.targetExecutable=stage+L"\\target.exe";transaction.dataDirectory=stage+L"\\test-data";transaction.version=L"1.4.1";transaction.previousVersion=L"1.4.0";transaction.nonce=L"12345678-1234-1234-1234-123456789abc";transaction.kind="portable";transaction.artifactName="EyeBreakReminder.exe";transaction.sha256=std::string(64,'a');transaction.expectedApplicationSha256=std::string(64,'b');transaction.previousSha256=std::string(64,'c');transaction.expectedSize=3;transaction.backupMask=5;transaction.ownedFileMask=11;transaction.backupSha256={std::string(64,'d'),"",std::string(64,'e')};transaction.ownedFileSha256={std::string(64,'f'),std::string(64,'a'),"",std::string(64,'b')};transaction.ownerPid=GetCurrentProcessId();transaction.clean=true;transaction.dark=true;transaction.previousStartup=true;
    ok&=check(eye::updates::writeTransaction(transaction),"write durable-format transaction record");eye::updates::Transaction parsed;const std::wstring txPath=stage+L"\\transaction.ini";
    ok&=check(eye::updates::readTransaction(txPath,parsed)&&parsed.version==transaction.version&&parsed.previousVersion==transaction.previousVersion&&parsed.kind==transaction.kind&&parsed.expectedSize==transaction.expectedSize&&parsed.backupMask==transaction.backupMask&&parsed.ownedFileMask==transaction.ownedFileMask&&parsed.backupSha256==transaction.backupSha256&&parsed.ownedFileSha256==transaction.ownedFileSha256&&parsed.previousStartup&&parsed.clean&&parsed.dark,"transaction record round-trips versions, backup digests, data policy and recovery flags");
    ok&=check(writeBytes(txPath,eye::updates::transactionText(transaction)+"version=1.4.2\n"),"write duplicate-field transaction fixture");
    ok&=check(!eye::updates::readTransaction(txPath,parsed),"duplicate transaction keys are rejected");

    const std::wstring validationData=stage+L"\\validation-profile";CreateDirectoryW(validationData.c_str(),nullptr);SetEnvironmentVariableW(L"EBR_GUI_TEST_DATA_DIRECTORY",validationData.c_str());std::wstring resolvedValidationData;const bool testProfileResolved=eye::updates::localDataDirectory(resolvedValidationData)&&eye::updates::samePath(validationData,resolvedValidationData);ok&=check(testProfileResolved,"transaction-validation tests use an isolated disposable test profile");
    std::wstring validationStage;const bool validationStageCreated=testProfileResolved&&eye::updates::createStagingDirectory(validationData,validationStage);const std::wstring portableDirectory=stage+L"\\portable-target";CreateDirectoryW(portableDirectory.c_str(),nullptr);const std::wstring portableTarget=portableDirectory+L"\\EyeBreakReminder.exe";ok&=check(validationStageCreated&&eye::updates::safeStagingDirectory(validationStage)&&eye::updates::safeStagingDirectory(portableDirectory)&&writeBytes(portableTarget,"old"),"create an isolated portable update transaction fixture");
    eye::updates::Transaction validTransaction;validTransaction.stagingDirectory=validationStage;validTransaction.artifactPath=validationStage+L"\\EyeBreakReminder.exe";validTransaction.targetExecutable=portableTarget;validTransaction.dataDirectory=validationData;validTransaction.version=L"1.4.1";validTransaction.previousVersion=L"1.4.0";validTransaction.nonce=L"12345678-1234-1234-1234-123456789abc";validTransaction.kind="portable";validTransaction.artifactName="EyeBreakReminder.exe";validTransaction.sha256=std::string(64,'a');validTransaction.expectedApplicationSha256=std::string(64,'b');validTransaction.previousSha256=std::string(64,'c');validTransaction.expectedSize=3;validTransaction.ownerPid=GetCurrentProcessId();
    std::string validationError;const std::wstring validTransactionPath=validationStage+L"\\transaction.ini",validCoordinatorPath=validationStage+L"\\coordinator.exe";ok&=check(validationStageCreated&&eye::updates::validateTransaction(validTransaction,validTransactionPath,validCoordinatorPath,validationError),"accept a correctly scoped disposable portable transaction");
    auto wrongProfile=validTransaction;wrongProfile.dataDirectory=stage+L"\\unrelated-profile";validationError.clear();ok&=check(!eye::updates::validateTransaction(wrongProfile,validTransactionPath,validCoordinatorPath,validationError)&&validationError.find("Windows user's Eye Break Reminder profile")!=std::string::npos,"reject a transaction directed at an unrelated user-profile destination");
    auto wrongName=validTransaction;wrongName.artifactName="..\\outside.exe";validationError.clear();ok&=check(!eye::updates::validateTransaction(wrongName,validTransactionPath,validCoordinatorPath,validationError),"reject command/path substitution in the fixed portable asset name");
    auto injectedNonce=validTransaction;injectedNonce.nonce=L"12345678-1234-1234-1234-123456789abc & cmd.exe";validationError.clear();ok&=check(!eye::updates::validateTransaction(injectedNonce,validTransactionPath,validCoordinatorPath,validationError),"reject command-line metacharacters in the transaction token");
    auto outsideStage=validTransaction;outsideStage.stagingDirectory=stage;validationError.clear();ok&=check(!eye::updates::validateTransaction(outsideStage,stage+L"\\transaction.ini",stage+L"\\coordinator.exe",validationError),"reject a transaction staging path outside this profile's updates directory");

    const std::wstring updatesRoot=validationData+L"\\updates",linkedStage=updatesRoot+L"\\redirected-stage";const bool linkedStageCreated=validationStageCreated&&createTestJunction(linkedStage,validationStage);ok&=check(linkedStageCreated&&!eye::updates::safeStagingDirectory(linkedStage),"reject a reparse-point staging-directory redirect");if(linkedStageCreated)RemoveDirectoryW(linkedStage.c_str());
    const std::wstring sentinelDirectory=stage+L"\\unrelated-sentinel-directory",sentinel=sentinelDirectory+L"\\sentinel.dat";CreateDirectoryW(sentinelDirectory.c_str(),nullptr);ok&=check(writeBytes(sentinel,"unrelated-user-file"),"create an unrelated sentinel for reparse-point protection tests");
    const std::wstring linkedTargetDirectory=stage+L"\\portable-target-redirect";const bool linkedTargetCreated=createTestJunction(linkedTargetDirectory,portableDirectory);auto reparseTarget=validTransaction;reparseTarget.targetExecutable=linkedTargetDirectory+L"\\EyeBreakReminder.exe";validationError.clear();ok&=check(linkedTargetCreated&&!eye::updates::validateTransaction(reparseTarget,validTransactionPath,validCoordinatorPath,validationError),"reject a portable executable path through a reparse-point directory before update execution");std::string sentinelContents;const bool sentinelPreserved=eye::win::read(sentinel,sentinelContents,128)&&sentinelContents=="unrelated-user-file";ok&=check(sentinelPreserved,"target reparse-point rejection leaves unrelated file bytes unchanged");if(linkedTargetCreated)RemoveDirectoryW(linkedTargetDirectory.c_str());
    const std::wstring linkedSettings=validationData+L"\\settings.ini";const bool linkedSettingsCreated=createTestJunction(linkedSettings,sentinelDirectory);eye::updates::Transaction backupTransaction;backupTransaction.stagingDirectory=validationStage;backupTransaction.dataDirectory=validationData;backupTransaction.kind="portable";backupTransaction.backupMask=0;const bool unsafeBackupRejected=linkedSettingsCreated&&!eye::updates::backupData(backupTransaction);sentinelContents.clear();const bool settingsSentinelPreserved=eye::win::read(sentinel,sentinelContents,128)&&sentinelContents=="unrelated-user-file";ok&=check(unsafeBackupRejected&&settingsSentinelPreserved,"refuse to back up a reparse-point settings path without changing its target");if(linkedSettingsCreated)RemoveDirectoryW(linkedSettings.c_str());

    const std::string originalSettings="theme=dark\nwork=47\n",originalTimer="workSeconds=1234\nbreakSeconds=77\n",originalHistory="sessions=42\n";
    const std::wstring settingsPath=validationData+L"\\settings.ini",timerPath=validationData+L"\\timer.dat",historyPath=validationData+L"\\history.dat";
    ok&=check(writeBytes(settingsPath,originalSettings)&&writeBytes(timerPath,originalTimer)&&writeBytes(historyPath,originalHistory),"populate an isolated settings/history recovery profile");
    const std::wstring failedBackupStage=updatesRoot+L"\\backup-failure";CreateDirectoryW(failedBackupStage.c_str(),nullptr);ok&=check(writeBytes(failedBackupStage+L"\\backup-1.dat","existing-backup-sentinel"),"create a collision that makes the second settings backup fail");
    eye::updates::Transaction failedBackup;failedBackup.stagingDirectory=failedBackupStage;failedBackup.dataDirectory=validationData;
    std::string unchanged;const bool failedBackupRejected=!eye::updates::backupData(failedBackup)&&eye::win::read(settingsPath,unchanged,128)&&unchanged==originalSettings&&eye::win::read(timerPath,unchanged,128)&&unchanged==originalTimer&&eye::win::read(historyPath,unchanged,128)&&unchanged==originalHistory;
    std::string backupSentinel;const bool backupCollisionPreserved=eye::win::read(failedBackupStage+L"\\backup-1.dat",backupSentinel,128)&&backupSentinel=="existing-backup-sentinel";
    ok&=check(failedBackupRejected&&backupCollisionPreserved,"a backup failure leaves all live profile data and a preexisting staging file unchanged");
    DeleteFileW((failedBackupStage+L"\\backup-0.dat").c_str());DeleteFileW((failedBackupStage+L"\\backup-1.dat").c_str());RemoveDirectoryW(failedBackupStage.c_str());

    eye::updates::Transaction dataRecovery=validTransaction;dataRecovery.stagingDirectory=validationStage;dataRecovery.artifactPath=validationStage+L"\\EyeBreakReminder.exe";dataRecovery.dataDirectory=validationData;dataRecovery.ownerPid=GetCurrentProcessId();
    const bool dataBackupComplete=eye::updates::backupData(dataRecovery)&&dataRecovery.backupMask==7&&eye::updates::backupDigestMetadataValid(dataRecovery);
    eye::updates::Transaction persistedDataRecovery;const bool dataDigestsPersisted=eye::updates::readTransaction(validationStage+L"\\transaction.ini",persistedDataRecovery)&&persistedDataRecovery.backupSha256==dataRecovery.backupSha256&&persistedDataRecovery.backupMask==dataRecovery.backupMask;
    ok&=check(dataBackupComplete&&dataDigestsPersisted,"backup settings, timer and history and persist each SHA-256 in the transaction record");
    const std::string partialSettings="theme=partial-migration\n",partialTimer="incomplete=true\n",partialHistory="partial-history\n";
    ok&=check(writeBytes(settingsPath,partialSettings)&&writeBytes(timerPath,partialTimer)&&writeBytes(historyPath,partialHistory),"simulate an interrupted settings and history migration");
    const std::wstring preexistingRestoreTemp=settingsPath+L".update-restore";ok&=check(writeBytes(preexistingRestoreTemp,"preexisting-temporary-sentinel"),"create a preexisting restore-temporary sentinel");
    const bool restoreTempCollisionRejected=!eye::updates::restoreData(dataRecovery,false);unchanged.clear();const bool restoreTempPreserved=eye::win::read(preexistingRestoreTemp,unchanged,128)&&unchanged=="preexisting-temporary-sentinel";
    ok&=check(restoreTempCollisionRejected&&restoreTempPreserved&&eye::win::read(settingsPath,unchanged,128)&&unchanged==partialSettings,"a restore-temp collision fails safely without deleting the preexisting file or changing settings");
    DeleteFileW(preexistingRestoreTemp.c_str());
    ok&=check(writeBytes(validationStage+L"\\backup-2.dat","CORRUPTED-HISTORY-BACKUP"),"corrupt a later history backup after the restore-temp collision check");
    const bool corruptHistoryRejected=!eye::updates::restoreData(dataRecovery,false);
    unchanged.clear();const bool noPartialLiveOverwrite=eye::win::read(settingsPath,unchanged,128)&&unchanged==partialSettings&&eye::win::read(timerPath,unchanged,128)&&unchanged==partialTimer&&eye::win::read(historyPath,unchanged,128)&&unchanged==partialHistory;
    const bool noRestoreTemps=GetFileAttributesW((settingsPath+L".update-restore").c_str())==INVALID_FILE_ATTRIBUTES&&GetFileAttributesW((timerPath+L".update-restore").c_str())==INVALID_FILE_ATTRIBUTES;
    ok&=check(corruptHistoryRejected&&noPartialLiveOverwrite&&noRestoreTemps,"reject a corrupted history backup before overwriting any settings or history and remove all staged restore files");
    ok&=check(writeBytes(validationStage+L"\\backup-2.dat",originalHistory),"repair the test history backup to its recorded bytes");
    const bool repairedDataRestored=eye::updates::restoreData(dataRecovery,false);unchanged.clear();
    ok&=check(repairedDataRestored&&eye::win::read(settingsPath,unchanged,128)&&unchanged==originalSettings&&eye::win::read(timerPath,unchanged,128)&&unchanged==originalTimer&&eye::win::read(historyPath,unchanged,128)&&unchanged==originalHistory,"restore all original settings, timer and history after a valid retry");

    dataRecovery.clean=true;dataRecovery.deleteHistory=false;
    const bool cleanKeepsHistory=eye::updates::applyCleanPolicy(dataRecovery)&&GetFileAttributesW(settingsPath.c_str())==INVALID_FILE_ATTRIBUTES&&GetFileAttributesW(timerPath.c_str())==INVALID_FILE_ATTRIBUTES&&eye::win::read(historyPath,unchanged,128)&&unchanged==originalHistory;
    ok&=check(cleanKeepsHistory,"Clean Install resets settings and timer while preserving history");
    ok&=check(writeBytes(settingsPath,partialSettings)&&writeBytes(timerPath,partialTimer),"simulate an interrupted settings migration after Clean Install");
    const bool cleanRecovery=eye::updates::restoreData(dataRecovery,true);unchanged.clear();
    ok&=check(cleanRecovery&&eye::win::read(settingsPath,unchanged,128)&&unchanged==originalSettings&&eye::win::read(timerPath,unchanged,128)&&unchanged==originalTimer&&eye::win::read(historyPath,unchanged,128)&&unchanged==originalHistory,"recover interrupted Clean Install migration from verified backups");
    dataRecovery.deleteHistory=true;
    const bool cleanDeletesOnlyAppData=eye::updates::applyCleanPolicy(dataRecovery)&&GetFileAttributesW(settingsPath.c_str())==INVALID_FILE_ATTRIBUTES&&GetFileAttributesW(timerPath.c_str())==INVALID_FILE_ATTRIBUTES&&GetFileAttributesW(historyPath.c_str())==INVALID_FILE_ATTRIBUTES&&eye::win::read(sentinel,sentinelContents,128)&&sentinelContents=="unrelated-user-file";
    ok&=check(cleanDeletesOnlyAppData,"explicit history deletion removes only the three Eye Break Reminder data files");
    const bool destructiveCleanRecovery=eye::updates::restoreData(dataRecovery,true);unchanged.clear();
    ok&=check(destructiveCleanRecovery&&eye::win::read(settingsPath,unchanged,128)&&unchanged==originalSettings&&eye::win::read(timerPath,unchanged,128)&&unchanged==originalTimer&&eye::win::read(historyPath,unchanged,128)&&unchanged==originalHistory,"rollback after history deletion restores verified settings and history backups");
    SetEnvironmentVariableW(L"EBR_GUI_TEST_DATA_DIRECTORY",nullptr);DeleteFileW(sentinel.c_str());RemoveDirectoryW(sentinelDirectory.c_str());DeleteFileW(portableTarget.c_str());RemoveDirectoryW(portableDirectory.c_str());DeleteFileW(settingsPath.c_str());DeleteFileW(timerPath.c_str());DeleteFileW(historyPath.c_str());DeleteFileW((settingsPath+L".update-restore").c_str());DeleteFileW((timerPath+L".update-restore").c_str());DeleteFileW((historyPath+L".update-restore").c_str());DeleteFileW((validationStage+L"\\backup-0.dat").c_str());DeleteFileW((validationStage+L"\\backup-1.dat").c_str());DeleteFileW((validationStage+L"\\backup-2.dat").c_str());DeleteFileW((validationStage+L"\\transaction.ini").c_str());DeleteFileW((validationStage+L"\\transaction.ini.tmp").c_str());if(validationStageCreated)RemoveDirectoryW(validationStage.c_str());RemoveDirectoryW(updatesRoot.c_str());RemoveDirectoryW(validationData.c_str());

    DeleteFileW((stage+L"\\fixture.bin").c_str());DeleteFileW((stage+L"\\transaction.ini").c_str());DeleteFileW((stage+L"\\transaction.ini.tmp").c_str());DeleteFileW((stage+L"\\previous-owned-0.dat").c_str());DeleteFileW((stage+L"\\previous-owned-1.dat").c_str());DeleteFileW((stage+L"\\previous-owned-3.dat").c_str());const bool filesRemoved=DeleteFileW((install+L"\\Uninstall.exe").c_str())&&DeleteFileW((install+L"\\README.md").c_str())&&DeleteFileW((install+L"\\VERIFICATION.md").c_str());const bool installRemoved=filesRemoved&&RemoveDirectoryW(install.c_str());const bool removed=installRemoved&&RemoveDirectoryW(stage.c_str())!=FALSE;
    ok&=check(removed,"remove exact isolated updater test folder");
    if(!ok)return 1;
    std::cout<<"PASS: "<<assertions<<" Windows updater assertions executed.\n";return 0;
}
