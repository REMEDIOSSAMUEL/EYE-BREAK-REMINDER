#define EYEBREAK_TEST_BUILD
#include "../src/update_coordinator.hpp"
#include <windows.h>
#include <atomic>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <cstdlib>

namespace {
int assertions=0;
bool check(bool value,const char*name){++assertions;if(!value)std::cerr<<"FAIL: "<<name<<'\n';return value;}
bool writeBytes(const std::wstring&path,const std::string&value){HANDLE file=CreateFileW(path.c_str(),GENERIC_WRITE,0,nullptr,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,nullptr);if(file==INVALID_HANDLE_VALUE)return false;DWORD wrote=0;const bool ok=WriteFile(file,value.data(),DWORD(value.size()),&wrote,nullptr)&&wrote==value.size();CloseHandle(file);return ok;}
int runHttpsInterruption(int argc,char**argv){
    if(argc!=4){std::cerr<<"Usage: updater-windows-tests --https-interruption <proxy-port> <staging-directory>\n";return 2;}
    const unsigned long port=std::strtoul(argv[2],nullptr,10);if(port<1024||port>65535){std::cerr<<"Invalid loopback test proxy port.\n";return 2;}
    const std::wstring stage=std::filesystem::path(argv[3]).wstring();bool ok=true;
    wchar_t configuredProxy[128]{};const DWORD proxyLength=GetEnvironmentVariableW(L"EBR_TEST_HTTPS_PROXY",configuredProxy,DWORD(std::size(configuredProxy)));
    const std::wstring expectedProxy=L"127.0.0.1:"+std::to_wstring(port);
    ok&=check(proxyLength==expectedProxy.size()&&std::wstring(configuredProxy,proxyLength)==expectedProxy,"test process uses only the isolated loopback HTTPS CONNECT proxy");
    const auto response=eye::updates::latestStableReleaseResponse();eye::updates::ReleaseDetails release;
    const auto checked=eye::updates::evaluate(response,"1.4.0",&release);
    ok&=check(response.status==200&&checked.state==eye::updates::State::InstalledNewer&&release.tag=="v1.3.0","discover the current official stable release from the real GitHub API without credentials");
    const auto selected=eye::updates::selectAsset(release,eye::updates::PackageKind::Portable);
    ok&=check(selected.ok&&selected.asset.name=="EyeBreakReminder.exe"&&selected.asset.downloadUrl.rfind("https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/download/v1.3.0/",0)==0,"select the official stable standalone release asset and validated digest");
    if(!ok)return 1;
    const auto&asset=selected.asset;
    const auto digestSeparator=asset.digest.find(':');const std::string expected=eye::updates::client_detail::lower(asset.digest.substr(digestSeparator+1));
    std::atomic_bool cancelled{false};const std::wstring sentinel=stage+L"\\working-app.sentinel";
    ok&=check(writeBytes(sentinel,"installed-v1.4.0"),"create isolated prior-install sentinel");
    auto interrupted=eye::updates::downloadVerified(asset,stage,L"EyeBreakReminder.exe",cancelled);
    std::string oldContents;eye::win::read(sentinel,oldContents,128);
    ok&=check(!interrupted.ok&&!interrupted.cancelled&&interrupted.received>0&&interrupted.received<asset.size&&
              GetFileAttributesW((stage+L"\\EyeBreakReminder.exe.part").c_str())==INVALID_FILE_ATTRIBUTES&&
              GetFileAttributesW((stage+L"\\EyeBreakReminder.exe").c_str())==INVALID_FILE_ATTRIBUTES&&oldContents=="installed-v1.4.0",
              "unexpected mid-body HTTPS interruption rejects and removes partial bytes while preserving the prior app sentinel");
    bool sawVerify=false;std::uint64_t finalProgress=0;
    auto retried=eye::updates::downloadVerified(asset,stage,L"EyeBreakReminder.exe",cancelled,[&](auto p){finalProgress=p.received;if(p.verifying)sawVerify=true;});
    ok&=check(retried.ok&&retried.received==asset.size&&retried.sha256==expected&&finalProgress==asset.size&&sawVerify,
              "a fresh HTTPS retry downloads the real public asset, reports byte progress and verifies GitHub's SHA-256 digest");
    ok&=check(oldContents=="installed-v1.4.0"&&DeleteFileW(sentinel.c_str())!=FALSE,"successful retry still leaves the existing application untouched before installer coordination");
    if(!ok)return 1;
    std::cout<<"PASS: "<<assertions<<" real GitHub HTTPS interruption and retry assertions executed; release="<<release.tag<<" asset="<<asset.name<<" bytes="<<asset.size<<" sha256="<<retried.sha256<<".\n";return 0;
}
}

int main(int argc,char**argv){
    if(argc>1&&std::string(argv[1])=="--https-interruption")return runHttpsInterruption(argc,argv);
    const auto folder=std::filesystem::current_path()/"build"/"updater-windows-tests";
    if(!CreateDirectoryW(folder.c_str(),nullptr)){std::cerr<<"FAIL: isolated test folder must be new; refusing to reuse or remove it\n";return 1;}
    const std::wstring stage=folder.wstring();bool ok=true;
    ok&=check(eye::updates::safeStagingDirectory(stage),"isolated staging directory is a regular non-reparse path");
    const std::wstring testMutexName=L"Local\\EyeBreakReminder.UpdaterTest."+std::to_wstring(GetCurrentProcessId());HANDLE firstMutex{},duplicateMutex{};
    const bool firstAcquired=eye::updates::acquireCoordinatorMutex(firstMutex,testMutexName.c_str());const bool duplicateRejected=!eye::updates::acquireCoordinatorMutex(duplicateMutex,testMutexName.c_str())&&duplicateMutex==nullptr;
    ok&=check(firstAcquired&&duplicateRejected,"a repeated update attempt cannot acquire a second coordinator mutex");if(firstMutex)CloseHandle(firstMutex);
    HANDLE retryMutex{};const bool retryAcquired=eye::updates::acquireCoordinatorMutex(retryMutex,testMutexName.c_str());ok&=check(retryAcquired,"a new update attempt can acquire the coordinator after the prior attempt exits");if(retryMutex)CloseHandle(retryMutex);
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

    const std::wstring install=stage+L"\\install";CreateDirectoryW(install.c_str(),nullptr);const wchar_t*ownedNames[]={L"Uninstall.exe",L"README.md",L"PRIVACY.md",L"VERIFICATION.md"};for(unsigned i:{0u,1u,3u})ok&=check(writeBytes(install+L"\\"+ownedNames[i],"previous-owned-file"),"create exact test installer-owned file");
    eye::updates::Transaction installedFiles;installedFiles.stagingDirectory=stage;installedFiles.targetExecutable=install+L"\\EyeBreakReminder.exe";installedFiles.kind="installed";
    ok&=check(eye::updates::backupInstalledFiles(installedFiles)&&installedFiles.ownedFileMask==11,"backup only present installer-owned files and record their exact mask");
    for(const auto*name:ownedNames)ok&=check(writeBytes(install+L"\\"+name,"replacement-owned-file"),"simulate NSIS replacing an owned file");
    ok&=check(eye::updates::restoreInstalledFiles(installedFiles),"restore previous uninstaller and installed documentation");
    std::string restored;ok&=check(eye::win::read(install+L"\\Uninstall.exe",restored,128)&&restored=="previous-owned-file"&&eye::win::read(install+L"\\README.md",restored,128)&&restored=="previous-owned-file"&&eye::win::read(install+L"\\VERIFICATION.md",restored,128)&&restored=="previous-owned-file"&&GetFileAttributesW((install+L"\\PRIVACY.md").c_str())==INVALID_FILE_ATTRIBUTES,"restore original contents and remove only files absent before the update");
    eye::updates::Transaction transaction;transaction.stagingDirectory=stage;transaction.artifactPath=stage+L"\\EyeBreakReminder.exe";transaction.targetExecutable=stage+L"\\target.exe";transaction.dataDirectory=stage+L"\\test-data";transaction.version=L"1.4.1";transaction.previousVersion=L"1.4.0";transaction.nonce=L"12345678-1234-1234-1234-123456789abc";transaction.kind="portable";transaction.artifactName="EyeBreakReminder.exe";transaction.sha256=std::string(64,'a');transaction.expectedApplicationSha256=std::string(64,'b');transaction.previousSha256=std::string(64,'c');transaction.expectedSize=3;transaction.backupMask=5;transaction.ownedFileMask=11;transaction.ownerPid=GetCurrentProcessId();transaction.clean=true;transaction.dark=true;transaction.previousStartup=true;
    ok&=check(eye::updates::writeTransaction(transaction),"write durable-format transaction record");eye::updates::Transaction parsed;const std::wstring txPath=stage+L"\\transaction.ini";
    ok&=check(eye::updates::readTransaction(txPath,parsed)&&parsed.version==transaction.version&&parsed.previousVersion==transaction.previousVersion&&parsed.kind==transaction.kind&&parsed.expectedSize==transaction.expectedSize&&parsed.backupMask==transaction.backupMask&&parsed.ownedFileMask==transaction.ownedFileMask&&parsed.previousStartup&&parsed.clean&&parsed.dark,"transaction record round-trips versions, digests, data policy and recovery flags");
    ok&=check(writeBytes(txPath,eye::updates::transactionText(transaction)+"version=1.4.2\n"),"write duplicate-field transaction fixture");
    ok&=check(!eye::updates::readTransaction(txPath,parsed),"duplicate transaction keys are rejected");

    DeleteFileW((stage+L"\\fixture.bin").c_str());DeleteFileW((stage+L"\\transaction.ini").c_str());DeleteFileW((stage+L"\\transaction.ini.tmp").c_str());DeleteFileW((stage+L"\\previous-owned-0.dat").c_str());DeleteFileW((stage+L"\\previous-owned-1.dat").c_str());DeleteFileW((stage+L"\\previous-owned-3.dat").c_str());const bool filesRemoved=DeleteFileW((install+L"\\Uninstall.exe").c_str())&&DeleteFileW((install+L"\\README.md").c_str())&&DeleteFileW((install+L"\\VERIFICATION.md").c_str());const bool installRemoved=filesRemoved&&RemoveDirectoryW(install.c_str());const bool removed=installRemoved&&RemoveDirectoryW(stage.c_str())!=FALSE;
    ok&=check(removed,"remove exact isolated updater test folder");
    if(!ok)return 1;
    std::cout<<"PASS: "<<assertions<<" Windows updater assertions executed.\n";return 0;
}
