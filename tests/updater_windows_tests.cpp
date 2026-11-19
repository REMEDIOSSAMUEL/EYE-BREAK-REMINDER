#define EYEBREAK_TEST_BUILD
#include <winsock2.h>
#undef NOMINMAX
#include "../src/update_coordinator.hpp"
#include "../src/update_signature_win.hpp"
#include <windows.h>
#include <atomic>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>
#include <cstring>
#include <cstdlib>
#include <cstdio>
#include <ctime>
#include <objbase.h>

namespace {
int assertions=0;
bool check(bool value,const char*name){++assertions;if(!value)std::cerr<<"FAIL: "<<name<<'\n';return value;}
bool writeBytes(const std::wstring&path,const std::string&value){HANDLE file=CreateFileW(path.c_str(),GENERIC_WRITE,0,nullptr,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,nullptr);if(file==INVALID_HANDLE_VALUE)return false;DWORD wrote=0;const bool ok=WriteFile(file,value.data(),DWORD(value.size()),&wrote,nullptr)&&wrote==value.size();CloseHandle(file);return ok;}
struct EphemeralSigningKey {
    eye::updates::signature_detail::AlgorithmHandle algorithm;
    eye::updates::signature_detail::KeyHandle key;
    eye::updates::TrustedPublicKey trusted;
    bool generate(){
        if(BCryptOpenAlgorithmProvider(&algorithm.value,BCRYPT_ECDSA_P256_ALGORITHM,nullptr,0)<0||
           BCryptGenerateKeyPair(algorithm.value,&key.value,256,0)<0||BCryptFinalizeKeyPair(key.value,0)<0)return false;
        DWORD length=0;if(BCryptExportKey(key.value,nullptr,BCRYPT_ECCPUBLIC_BLOB,nullptr,0,&length,0)<0||length!=sizeof(BCRYPT_ECCKEY_BLOB)+64)return false;
        std::vector<unsigned char>blob(length);if(BCryptExportKey(key.value,nullptr,BCRYPT_ECCPUBLIC_BLOB,blob.data(),length,&length,0)<0)return false;
        const auto*header=reinterpret_cast<const BCRYPT_ECCKEY_BLOB*>(blob.data());if(header->dwMagic!=BCRYPT_ECDSA_PUBLIC_P256_MAGIC||header->cbKey!=32)return false;
        trusted.p256Point.assign(blob.begin()+sizeof(BCRYPT_ECCKEY_BLOB),blob.end());return eye::updates::signature_detail::keyIdForPoint(trusted.p256Point,trusted.keyId);
    }
    bool sign(std::string_view message,std::string&signature){
        std::array<unsigned char,32>digest{};if(!eye::updates::signature_detail::sha256(message,digest))return false;
        DWORD length=0;signature.assign(64,'\0');
        return BCryptSignHash(key.value,nullptr,digest.data(),DWORD(digest.size()),reinterpret_cast<PUCHAR>(signature.data()),DWORD(signature.size()),&length,0)>=0&&length==64;
    }
};
bool manifestTimestamp(std::time_t value,std::string&text){
    std::tm utc{};const __time64_t stamp=static_cast<__time64_t>(value);if(_gmtime64_s(&utc,&stamp)!=0)return false;
    char buffer[32]{};const int count=std::snprintf(buffer,sizeof(buffer),"%04d-%02d-%02dT%02d:%02d:%02dZ",utc.tm_year+1900,utc.tm_mon+1,utc.tm_mday,utc.tm_hour,utc.tm_min,utc.tm_sec);
    if(count!=20)return false;
    text.assign(buffer,std::size_t(count));return true;
}
bool writeSignedManifest(const std::wstring&stage,EphemeralSigningKey&signer,const eye::updates::UpdateManifest&manifest){
    const std::string bytes=eye::updates::canonicalManifest(manifest);std::string signature;
    if(bytes.empty()){std::cerr<<"FAIL: test manifest did not serialize canonically\n";return false;}
    if(!signer.sign(bytes,signature)){std::cerr<<"FAIL: CNG could not sign the disposable transaction manifest\n";return false;}
    const bool manifestWritten=writeBytes(stage+L"\\EyeBreakReminder-UpdateManifest.json",bytes);const DWORD manifestError=manifestWritten?ERROR_SUCCESS:GetLastError();
    const bool signatureWritten=writeBytes(stage+L"\\EyeBreakReminder-UpdateManifest.sig",signature);const DWORD signatureError=signatureWritten?ERROR_SUCCESS:GetLastError();
    const bool publicKeyWritten=writeBytes(stage+L"\\test-update-public-key.bin",std::string(reinterpret_cast<const char*>(signer.trusted.p256Point.data()),signer.trusted.p256Point.size()));const DWORD publicKeyError=publicKeyWritten?ERROR_SUCCESS:GetLastError();
    if(!manifestWritten||!signatureWritten||!publicKeyWritten)std::cerr<<"FAIL: signed test fixture write results manifest="<<manifestWritten<<" error="<<manifestError<<" signature="<<signatureWritten<<" error="<<signatureError<<" public_key="<<publicKeyWritten<<" error="<<publicKeyError<<" stage_exists="<<(GetFileAttributesW(stage.c_str())!=INVALID_FILE_ATTRIBUTES)<<" parent_exists="<<(GetFileAttributesW(eye::updates::parentPath(stage).c_str())!=INVALID_FILE_ATTRIBUTES)<<" stage="<<std::filesystem::path(stage).string()<<"\n";
    return manifestWritten&&signatureWritten&&publicKeyWritten;
}
eye::updates::UpdateManifest transactionManifest(const EphemeralSigningKey&signer){
    const std::time_t now=std::time(nullptr);std::string issued,expires;
    eye::updates::UpdateManifest manifest;if(!manifestTimestamp(now,issued)||!manifestTimestamp(now+24*60*60,expires))return manifest;
    manifest.schemaVersion=1;manifest.application=std::string(eye::updates::OfficialApplicationIdentity);
    manifest.repository=std::string(eye::updates::OfficialRepositoryIdentity);manifest.version="1.4.1";manifest.channel="stable";manifest.architecture="x64";
    manifest.keyId=signer.trusted.keyId;manifest.issuedAt=issued;manifest.expiresAt=expires;
    manifest.assets={{"EyeBreakReminder-Setup-x64.exe","installer","installed","x64",std::string(64,'c'),3},
                     {"EyeBreakReminder.exe","portable-update","portable","x64",std::string(64,'b'),3}};
    return manifest;
}
std::wstring asciiWide(const char*text);
bool createGuiResourceMetadata(const char*directoryText,const char*portableDigest,const char*portableSizeText){
    if(!directoryText||!portableDigest||!portableSizeText||!eye::updates::manifest_detail::lowerHex(portableDigest,64))return false;
    char*end=nullptr;const unsigned long long portableSize=std::strtoull(portableSizeText,&end,10);
    if(!end||*end||!portableSize||portableSize>100ull*1024*1024)return false;
    const std::wstring directory=asciiWide(directoryText);
    if(GetFileAttributesW(directory.c_str())==INVALID_FILE_ATTRIBUTES)return false;
    const wchar_t*names[]={L"EyeBreakReminder-UpdateManifest.json",L"EyeBreakReminder-UpdateManifest.sig",L"test-update-public-key.bin"};
    for(const auto*name:names)if(GetFileAttributesW((directory+L"\\"+name).c_str())!=INVALID_FILE_ATTRIBUTES)return false;
    EphemeralSigningKey signer;if(!signer.generate())return false;
    auto manifest=transactionManifest(signer);if(manifest.assets.size()!=2)return false;
    manifest.assets[0].size=100;manifest.assets[0].sha256=std::string(64,'a');
    manifest.assets[1].size=portableSize;manifest.assets[1].sha256=portableDigest;
    const bool written=writeSignedManifest(directory,signer,manifest);
    if(written)std::cout<<"Created disposable GUI resource manifest and signature; private test key remained ephemeral. key_id="<<signer.trusted.keyId<<"\n";
    return written;
}
bool signUpdateManifestForFiles(const char*stageText,const char*setupText,const char*portableText){
    if(!stageText||!setupText||!portableText)return false;
    const std::wstring stage=asciiWide(stageText),setupPath=asciiWide(setupText),portablePath=asciiWide(portableText);
    auto measure=[](const std::wstring&path,std::uint64_t&size,std::string&digest){
        if(!eye::updates::safeFile(path,100ull*1024*1024)||!eye::updates::hashFile(path,digest))return false;
        WIN32_FILE_ATTRIBUTE_DATA info{};if(!GetFileAttributesExW(path.c_str(),GetFileExInfoStandard,&info))return false;
        size=(std::uint64_t(info.nFileSizeHigh)<<32)|info.nFileSizeLow;return size>0&&size<=100ull*1024*1024;
    };
    std::uint64_t setupSize=0,portableSize=0;std::string setupDigest,portableDigest;
    if(!measure(setupPath,setupSize,setupDigest)||!measure(portablePath,portableSize,portableDigest))return false;
    EphemeralSigningKey signer;if(!signer.generate())return false;
    auto manifest=transactionManifest(signer);if(manifest.assets.size()!=2)return false;
    manifest.assets[0].size=setupSize;manifest.assets[0].sha256=setupDigest;
    manifest.assets[1].size=portableSize;manifest.assets[1].sha256=portableDigest;
    const bool written=writeSignedManifest(stage,signer,manifest);
    if(written)std::cout<<"Created disposable test-key update manifest for controlled Windows payloads; private test key remained ephemeral. key_id="<<signer.trusted.keyId<<"\n";
    return written;
}
bool testSignedManifestVerification(){
    using namespace eye::updates;EphemeralSigningKey signer,other;bool ok=true;
    ok&=check(signer.generate()&&other.generate(),"generate separate disposable Windows CNG P-256 test keys");
    UpdateManifest manifest;manifest.schemaVersion=1;manifest.application=std::string(OfficialApplicationIdentity);manifest.repository=std::string(OfficialRepositoryIdentity);manifest.version="1.4.1";manifest.channel="stable";manifest.architecture="x64";manifest.keyId=signer.trusted.keyId;manifest.issuedAt="2026-11-19T11:00:00Z";manifest.expiresAt="2027-01-01T00:00:00Z";
    manifest.assets={{"EyeBreakReminder-Setup-x64.exe","installer","installed","x64",std::string(64,'a'),100},
                     {"EyeBreakReminder.exe","portable-update","portable","x64",std::string(64,'b'),90}};
    const std::string bytes=canonicalManifest(manifest);std::string signature;ok&=check(!bytes.empty()&&signer.sign(bytes,signature),"sign the complete canonical manifest using the disposable CNG key");
    ok&=check(verifyManifestSignature(bytes,signature,signer.trusted),"verify a valid SHA-256/ECDSA P-256 manifest signature with its matching key");
    ok&=check(!verifyManifestSignature(bytes,{},signer.trusted),"reject a missing manifest signature");
    ok&=check(!verifyManifestSignature(bytes,std::string_view(signature.data(),signature.size()-1),signer.trusted),"reject a truncated ECDSA signature");
    std::string changed=bytes;changed[changed.find("1.4.1")]='9';ok&=check(!verifyManifestSignature(changed,signature,signer.trusted),"reject a modified version or any other manifest byte");
    std::string badEncoding=signature;badEncoding[0]=char(badEncoding[0]^0x80);ok&=check(!verifyManifestSignature(bytes,badEncoding,signer.trusted),"reject an invalid raw signature encoding");
    ok&=check(!verifyManifestSignature(bytes,signature,other.trusted),"reject a signature from a different key");
    TrustedPublicKey unknown=signer.trusted;unknown.keyId="p256-ffffffffffffffff";ok&=check(!verifyManifestSignature(bytes,signature,unknown),"reject an unknown or mismatched signing key identifier");
    const bool productionSeparate=!ProductionUpdateKeyProvisioned&&ProductionUpdateKeyId.empty()&&
        !verifyProductionManifest(bytes,signature,"v1.4.1","1.4.0",std::time(nullptr)).ok;
    ok&=check(productionSeparate,"a disposable test-key signature is rejected by the unprovisioned production trust configuration");
    DWORD before=0,after=0;const bool handleBaseline=GetProcessHandleCount(GetCurrentProcess(),&before)!=FALSE;
    bool repeated=handleBaseline;for(unsigned i=0;i<100;++i)repeated&=verifyManifestSignature(bytes,signature,signer.trusted);
    const bool handlesObserved=GetProcessHandleCount(GetCurrentProcess(),&after)!=FALSE;ok&=check(repeated&&handlesObserved&&before==after,"100 signature verifications release CNG handles back to the process baseline");
    return ok;
}
bool testInvalidTemporaryRoot(const std::wstring&stage){
    const std::wstring invalidDataRoot=stage+L"\\missing-parent\\EyeBreakReminder";
    std::wstring rejectedStage;
    const bool invalidTempRootRejected=!eye::updates::createStagingDirectory(invalidDataRoot,rejectedStage)&&rejectedStage.empty()&&
      GetFileAttributesW((stage+L"\\missing-parent").c_str())==INVALID_FILE_ATTRIBUTES&&
      GetFileAttributesW(invalidDataRoot.c_str())==INVALID_FILE_ATTRIBUTES;
    return check(invalidTempRootRejected,"a missing temporary data root is rejected without creating parent or staging directories");
}
bool countDirectoryEntries(const std::wstring&path,std::size_t&count){
    count=0;std::error_code error;
    for(const auto&entry:std::filesystem::directory_iterator(path,error)){(void)entry;if(error)return false;++count;}
    return !error;
}
bool testRepeatedPayloadVerification(const std::wstring&stage){
    constexpr unsigned iterations=100;
    const std::wstring source=stage+L"\\verification-fixture.bin",destination=stage+L"\\EyeBreakReminder.exe",partial=destination+L".part";
    const bool sourceCreated=writeBytes(source,"abc");DWORD baselineHandles=0;
    const bool baselineObserved=GetProcessHandleCount(GetCurrentProcess(),&baselineHandles)!=FALSE;
    eye::updates::ReleaseAsset asset{"EyeBreakReminder.exe","https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/download/v1.3.0/EyeBreakReminder.exe","sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",3};
    std::atomic_bool cancelled{false};bool allVerified=sourceCreated&&baselineObserved;DWORD maximumPostCallHandles=baselineHandles;bool filesCleanPerIteration=true;
    for(unsigned i=0;i<iterations;++i){
        const auto result=eye::updates::downloadVerifiedFixture(asset,source,stage,L"EyeBreakReminder.exe",cancelled);
        DWORD handles=0;const bool handlesObserved=GetProcessHandleCount(GetCurrentProcess(),&handles)!=FALSE;if(handlesObserved)maximumPostCallHandles=std::max(maximumPostCallHandles,handles);
        std::size_t stagedEntries=0;const bool stagedCountObserved=countDirectoryEntries(stage,stagedEntries);
        allVerified&=result.ok&&result.received==asset.size&&result.sha256==asset.digest.substr(7)&&handlesObserved;
        filesCleanPerIteration&=stagedCountObserved&&stagedEntries==2&&GetFileAttributesW(destination.c_str())!=INVALID_FILE_ATTRIBUTES&&GetFileAttributesW(partial.c_str())==INVALID_FILE_ATTRIBUTES;
        const bool outputRemoved=DeleteFileW(destination.c_str())!=FALSE;std::size_t afterCleanup=0;
        filesCleanPerIteration&=outputRemoved&&countDirectoryEntries(stage,afterCleanup)&&afterCleanup==1&&GetFileAttributesW(partial.c_str())==INVALID_FILE_ATTRIBUTES;
    }
    const bool sourceRemoved=DeleteFileW(source.c_str())!=FALSE;std::size_t finalEntries=0;const bool noResidualFiles=sourceRemoved&&countDirectoryEntries(stage,finalEntries)&&finalEntries==0;
    DWORD finalHandles=0;const bool finalHandlesObserved=GetProcessHandleCount(GetCurrentProcess(),&finalHandles)!=FALSE;
    const bool handlesStable=finalHandlesObserved&&finalHandles==baselineHandles&&maximumPostCallHandles==baselineHandles;
    const bool passed=check(allVerified&&filesCleanPerIteration&&noResidualFiles&&handlesStable,"100 successful fixture SHA-256 verifications leave process handle counts and staging files at baseline");
    std::cout<<"SHA256 soak: iterations="<<iterations<<" baseline_handles="<<baselineHandles<<" max_post_call_handles="<<maximumPostCallHandles<<" final_handles="<<finalHandles<<" residual_stage_entries="<<finalEntries<<"\n";
    return passed;
}
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
bool testDnsResolutionFailure(const std::wstring&stage){
    const std::wstring profile=stage+L"\\dns-profile",app=profile+L"\\EyeBreakReminder.exe",settings=profile+L"\\settings.ini",history=profile+L"\\history.dat",marker=stage+L"\\dns-installer-launched.marker";
    const bool profileCreated=CreateDirectoryW(profile.c_str(),nullptr)!=FALSE;
    const bool fixturesCreated=profileCreated&&writeBytes(app,"existing-application")&&writeBytes(settings,"theme=dark\nwork=47\n")&&writeBytes(history,"sessions=42\n");
    bool ok=check(fixturesCreated,"create disposable app/settings/history sentinels for the DNS failure test");
    std::string appBefore,settingsBefore,historyBefore;ok&=check(eye::updates::hashFile(app,appBefore)&&eye::updates::hashFile(settings,settingsBefore)&&eye::updates::hashFile(history,historyBefore),"record disposable file identities before DNS resolution");
    wchar_t previous[8]{};const DWORD previousLength=GetEnvironmentVariableW(L"EBR_GUI_TEST_DNS_FAILURE",previous,DWORD(std::size(previous)));
    const unsigned closeFailuresBefore=eye::updates::client_detail::WinHttpCloseFailures.load(std::memory_order_relaxed);
    const bool configured=SetEnvironmentVariableW(L"EBR_GUI_TEST_DNS_FAILURE",L"1")!=FALSE;
    eye::updates::HttpResponse response;if(configured)for(unsigned i=0;i<8;++i)response=eye::updates::latestStableReleaseResponse();
    Sleep(5000);std::vector<DWORD>dnsHandleSamples;DWORD stableHandleBaseline=0,previousHandles=0;unsigned stableSamples=0,warmupSamples=0;bool stableBaselineObserved=false;
    for(unsigned i=0;i<15&&configured;++i){Sleep(1000);DWORD handles=0;if(!GetProcessHandleCount(GetCurrentProcess(),&handles))break;dnsHandleSamples.push_back(handles);++warmupSamples;if(i&&handles==previousHandles)++stableSamples;else stableSamples=0;previousHandles=handles;}
    stableHandleBaseline=previousHandles;stableBaselineObserved=warmupSamples==15;bool repeatedHandleCountsStable=stableBaselineObserved&&stableSamples>=3;
    for(unsigned i=0;i<20&&configured;++i){response=eye::updates::latestStableReleaseResponse();Sleep(250);DWORD handles=0;const bool observed=GetProcessHandleCount(GetCurrentProcess(),&handles)!=FALSE;dnsHandleSamples.push_back(handles);repeatedHandleCountsStable&=observed&&handles==stableHandleBaseline;}
    const bool restoredEnvironment=previousLength?SetEnvironmentVariableW(L"EBR_GUI_TEST_DNS_FAILURE",std::wstring(previous,previousLength).c_str())!=FALSE:SetEnvironmentVariableW(L"EBR_GUI_TEST_DNS_FAILURE",nullptr)!=FALSE;
    Sleep(5000);DWORD finalHandles=0;const bool handlesObserved=GetProcessHandleCount(GetCurrentProcess(),&finalHandles)!=FALSE;
    const unsigned closeFailuresAfter=eye::updates::client_detail::WinHttpCloseFailures.load(std::memory_order_relaxed);
    ok&=check(configured&&restoredEnvironment,"enable the fixed test-only DNS origin for one request and restore the process environment");
    ok&=check(response.status==0&&response.body.empty()&&response.failure==eye::updates::Failure::Offline&&response.errorCode==ERROR_WINHTTP_NAME_NOT_RESOLVED,"real WinHTTP resolution of the reserved .invalid origin returns DNS-name-not-resolved, not an HTTP error");
    const auto failed=eye::updates::evaluate(response,"1.4.0");
    ok&=check(failed.state==eye::updates::State::Failed&&failed.error.find("Could not reach GitHub")!=std::string::npos,"report DNS failure as a recoverable offline update-check message");
    const auto liveRetryResponse=restoredEnvironment?eye::updates::latestStableReleaseResponse():eye::updates::HttpResponse{};eye::updates::ReleaseDetails liveRetryDetails;const auto liveRetry=eye::updates::evaluate(liveRetryResponse,"1.4.0",&liveRetryDetails);
    if(!restoredEnvironment||liveRetryResponse.status!=200||liveRetryResponse.failure!=eye::updates::Failure::None||liveRetry.state==eye::updates::State::Failed){
        std::cout<<"INFO: live retry diagnostics status="<<liveRetryResponse.status<<" failure="<<static_cast<int>(liveRetryResponse.failure)
                 <<" errorCode="<<liveRetryResponse.errorCode<<" message="<<liveRetryResponse.error<<" bodyBytes="<<liveRetryResponse.body.size()
                 <<" tag="<<liveRetryDetails.tag<<"\n";
    }
    ok&=check(restoredEnvironment&&liveRetryResponse.status==200&&liveRetryResponse.failure==eye::updates::Failure::None&&liveRetry.state!=eye::updates::State::Failed&&!liveRetryDetails.tag.empty(),"a real retry to the official GitHub release API succeeds after the test-only DNS failure is removed");
    const std::string installerDigest="sha256:"+std::string(64,'c'),portableDigest="sha256:"+std::string(64,'b');
    const std::string newerRelease="{\"tag_name\":\"v1.4.1\",\"html_url\":\"https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/tag/v1.4.1\",\"draft\":false,\"prerelease\":false,\"assets\":["
        "{\"name\":\"EyeBreakReminder-Setup-x64.exe\",\"browser_download_url\":\"https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/download/v1.4.1/EyeBreakReminder-Setup-x64.exe\",\"size\":3,\"digest\":\""+installerDigest+"\"},"
        "{\"name\":\"EyeBreakReminder.exe\",\"browser_download_url\":\"https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/download/v1.4.1/EyeBreakReminder.exe\",\"size\":3,\"digest\":\""+portableDigest+"\"}]}";
    eye::updates::ReleaseDetails retryDetails;
    const auto retry=eye::updates::evaluate(eye::updates::HttpResponse{200,newerRelease,eye::updates::Failure::None,0},"1.4.0",&retryDetails);
    ok&=check(retry.state==eye::updates::State::UpdateAvailable&&retry.latestVersion=="1.4.1","a later successful stable-release lookup remains discoverable after the DNS failure");
    ok&=check(!eye::updates::selectAuthenticatedAsset(retryDetails,eye::updates::PackageKind::Installed).ok,"a discovered retry cannot be offered before its manifest signature is authenticated");
    EphemeralSigningKey retrySigner;const bool retryKeyGenerated=retrySigner.generate();const auto retryManifest=transactionManifest(retrySigner);const std::string retryManifestBytes=eye::updates::canonicalManifest(retryManifest);std::string retrySignature;
    const bool retrySigned=retryKeyGenerated&&!retryManifestBytes.empty()&&retrySigner.sign(retryManifestBytes,retrySignature);
    const auto retryAuthorization=retrySigned?eye::updates::verifyManifestWithKey(retryManifestBytes,retrySignature,"v1.4.1","1.4.0",std::time(nullptr),retrySigner.trusted):eye::updates::ManifestAuthorization{};
    retryDetails.assets.push_back({std::string(eye::updates::UpdateManifestName),"https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/download/v1.4.1/"+std::string(eye::updates::UpdateManifestName),{},retryManifestBytes.size()});
    retryDetails.assets.push_back({std::string(eye::updates::UpdateManifestSignatureName),"https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/download/v1.4.1/"+std::string(eye::updates::UpdateManifestSignatureName),{},64});
    const auto retryManifestAsset=eye::updates::selectManifestAsset(retryDetails,eye::updates::UpdateManifestName);
    const auto retrySignatureAsset=eye::updates::selectManifestAsset(retryDetails,eye::updates::UpdateManifestSignatureName);
    retryDetails.manifestVerified=retryAuthorization.ok;retryDetails.signedManifestBytes=retryManifestBytes;retryDetails.signedManifestSignature=retrySignature;retryDetails.authenticatedManifest=retryAuthorization.manifest;
    const auto retryInstaller=eye::updates::selectAuthenticatedAsset(retryDetails,eye::updates::PackageKind::Installed);
    const auto retryPortable=eye::updates::selectAuthenticatedAsset(retryDetails,eye::updates::PackageKind::Portable);
    ok&=check(retryAuthorization.ok&&retryManifestAsset.ok&&retrySignatureAsset.ok&&retryInstaller.ok&&retryInstaller.asset.name=="EyeBreakReminder-Setup-x64.exe"&&retryPortable.ok&&retryPortable.asset.name=="EyeBreakReminder.exe","a successful retry proceeds only with a valid disposable-key manifest and role-bound installer/portable payloads");
    std::string appAfter,settingsAfter,historyAfter;const bool filesUnchanged=eye::updates::hashFile(app,appAfter)&&eye::updates::hashFile(settings,settingsAfter)&&eye::updates::hashFile(history,historyAfter)&&appBefore==appAfter&&settingsBefore==settingsAfter&&historyBefore==historyAfter;
    const bool noInstaller=GetFileAttributesW(marker.c_str())==INVALID_FILE_ATTRIBUTES&&GetFileAttributesW((stage+L"\\EyeBreakReminder-Setup-x64.exe").c_str())==INVALID_FILE_ATTRIBUTES;
    ok&=check(filesUnchanged,"DNS failure leaves disposable app, settings and history sentinels unchanged");
    ok&=check(noInstaller,"DNS failure neither stages nor launches an installer");
    ok&=check(closeFailuresBefore==closeFailuresAfter,"per-request WinHTTP connection and request handles close successfully after DNS failure");
    ok&=check(stableBaselineObserved&&handlesObserved,"observe the process handle count around repeated resolver failures");
    ok&=check(repeatedHandleCountsStable&&stableHandleBaseline==finalHandles,"reuse the bounded process WinHTTP session without accumulating handles across repeated DNS failures");
    if(!repeatedHandleCountsStable||stableHandleBaseline!=finalHandles){std::cout<<"INFO: test-only no-proxy DNS process handles:";for(auto value:dnsHandleSamples)std::cout<<' '<<value;std::cout<<" warmupSamples="<<warmupSamples<<" baseline="<<stableHandleBaseline<<" settled="<<finalHandles<<" (handle count failed to stabilize after the full warm-up).\n";}
    else std::cout<<"INFO: test-only no-proxy DNS handle count stabilized at "<<stableHandleBaseline<<" after "<<warmupSamples<<" warm-up samples and stayed there for 20 repeated resolver failures.\n";
    DeleteFileW(app.c_str());DeleteFileW(settings.c_str());DeleteFileW(history.c_str());RemoveDirectoryW(profile.c_str());DeleteFileW(marker.c_str());return ok;
}
bool createTestJunction(const std::wstring&link,const std::wstring&target){wchar_t systemDirectory[MAX_PATH]{};const UINT length=GetSystemDirectoryW(systemDirectory,MAX_PATH);if(!length||length>=MAX_PATH)return false;const std::wstring command=L"\""+std::wstring(systemDirectory)+L"\\cmd.exe\" /d /c mklink /J \""+link+L"\" \""+target+L"\"";std::vector<wchar_t>buffer(command.begin(),command.end());buffer.push_back(L'\0');STARTUPINFOW startup{};startup.cb=sizeof(startup);PROCESS_INFORMATION process{};if(!CreateProcessW(nullptr,buffer.data(),nullptr,nullptr,FALSE,CREATE_NO_WINDOW,nullptr,nullptr,&startup,&process))return false;WaitForSingleObject(process.hProcess,INFINITE);DWORD exitCode=1;GetExitCodeProcess(process.hProcess,&exitCode);CloseHandle(process.hThread);CloseHandle(process.hProcess);const DWORD attributes=GetFileAttributesW(link.c_str());return exitCode==0&&attributes!=INVALID_FILE_ATTRIBUTES&&(attributes&FILE_ATTRIBUTE_REPARSE_POINT)!=0;}
std::wstring asciiWide(const char*text){std::wstring result;for(;*text;++text)result.push_back(static_cast<unsigned char>(*text));return result;}
struct GuiWindowSearch {DWORD processId{};HWND window{};};
BOOL CALLBACK findGuiWindowForProcess(HWND candidate,LPARAM parameter){auto*search=reinterpret_cast<GuiWindowSearch*>(parameter);if(!search||!IsWindowVisible(candidate))return TRUE;DWORD processId=0;GetWindowThreadProcessId(candidate,&processId);if(processId!=search->processId)return TRUE;wchar_t className[128]{};if(GetClassNameW(candidate,className,DWORD(std::size(className)))&&wcscmp(className,L"EyeBreakReminder.Native")==0){search->window=candidate;return FALSE;}return TRUE;}
HWND guiWindowForProcess(DWORD processId){GuiWindowSearch search{processId,nullptr};EnumWindows(findGuiWindowForProcess,reinterpret_cast<LPARAM>(&search));return search.window;}
struct RunningGuiFixture {
    PROCESS_INFORMATION process{};HWND window{};DWORD createError{};DWORD processQueryError{};DWORD observedExitCode{STILL_ACTIVE};DWORD foreignWindowPid{};bool timedOut{};bool environmentRestored{};
    bool start(const std::wstring&image,const std::wstring&dataDirectory){
        wchar_t priorData[32768]{};const DWORD priorLength=GetEnvironmentVariableW(L"EBR_GUI_TEST_DATA_DIRECTORY",priorData,DWORD(std::size(priorData)));
        if(priorLength>=std::size(priorData)||!SetEnvironmentVariableW(L"EBR_GUI_TEST_DATA_DIRECTORY",dataDirectory.c_str()))return false;
        STARTUPINFOW startup{};startup.cb=sizeof(startup);std::wstring command=eye::updates::quoteArgument(image);
        const BOOL created=CreateProcessW(image.c_str(),command.data(),nullptr,nullptr,FALSE,CREATE_UNICODE_ENVIRONMENT,nullptr,eye::updates::parentPath(image).c_str(),&startup,&process);createError=created?ERROR_SUCCESS:GetLastError();
        const BOOL restored=priorLength?SetEnvironmentVariableW(L"EBR_GUI_TEST_DATA_DIRECTORY",std::wstring(priorData,priorLength).c_str()):SetEnvironmentVariableW(L"EBR_GUI_TEST_DATA_DIRECTORY",nullptr);environmentRestored=restored!=FALSE;
        if(process.hThread){CloseHandle(process.hThread);process.hThread=nullptr;}
        if(!created||!restored){close();return false;}
        for(unsigned i=0;i<200;++i){
            if(!GetExitCodeProcess(process.hProcess,&observedExitCode)){processQueryError=GetLastError();return false;}if(observedExitCode!=STILL_ACTIVE)return false;
            HWND candidate=guiWindowForProcess(process.dwProcessId);
            if(candidate){window=candidate;return responsive();}
            HWND any=FindWindowW(L"EyeBreakReminder.Native",nullptr);if(any)GetWindowThreadProcessId(any,&foreignWindowPid);
            Sleep(50);
        }
        timedOut=true;return false;
    }
    bool responsive()const{
        DWORD_PTR ignored=0;return process.hProcess&&window&&IsWindow(window)&&
            SendMessageTimeoutW(window,WM_NULL,0,0,SMTO_ABORTIFHUNG|SMTO_BLOCK,2000,&ignored)!=0;
    }
    bool timerSeconds(unsigned&remaining)const{
        if(!window||!IsWindow(window)){return false;}
        const HWND timer=GetDlgItem(window,40);if(!timer)return false;
        wchar_t text[32]{};if(!GetWindowTextW(timer,text,DWORD(std::size(text))))return false;
        const wchar_t*colon=std::wcschr(text,L':');if(!colon||colon==text||std::wcslen(colon+1)!=2)return false;
        unsigned minutes=0,seconds=0;for(const wchar_t*at=text;at<colon;++at){if(*at<L'0'||*at>L'9')return false;minutes=minutes*10+unsigned(*at-L'0');}
        if(colon[1]<L'0'||colon[1]>L'9'||colon[2]<L'0'||colon[2]>L'9')return false;
        seconds=unsigned(colon[1]-L'0')*10+unsigned(colon[2]-L'0');remaining=minutes*60+seconds;return true;
    }
    bool waitForTimerProgress(unsigned initial,unsigned timeoutMilliseconds=8000)const{
        for(unsigned elapsed=0;elapsed<timeoutMilliseconds;elapsed+=100){unsigned current=initial;if(timerSeconds(current)&&current<initial)return true;Sleep(100);}
        return false;
    }
    bool close(){
        if(!process.hProcess)return true;
        if(window&&IsWindow(window)){const UINT quit=RegisterWindowMessageW(L"EyeBreakReminder.Exit.Native.1");PostMessageW(window,quit,0,0);}
        bool exited=WaitForSingleObject(process.hProcess,10000)==WAIT_OBJECT_0;
        if(!exited){TerminateProcess(process.hProcess,1);WaitForSingleObject(process.hProcess,5000);}
        CloseHandle(process.hProcess);process.hProcess=nullptr;window=nullptr;return exited;
    }
    ~RunningGuiFixture(){close();}
};
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
    if(argc==5&&std::string(argv[1])=="--create-gui-resource-metadata")return createGuiResourceMetadata(argv[2],argv[3],argv[4])?0:1;
    if(argc==5&&std::string(argv[1])=="--sign-update-manifest")return signUpdateManifestForFiles(argv[2],argv[3],argv[4])?0:1;
    if(argc==2&&std::string(argv[1])=="--test-signatures"){
        const bool ok=testSignedManifestVerification();if(ok)std::cout<<"PASS: "<<assertions<<" Windows CNG signature assertions executed.\n";return ok?0:1;
    }
    if(argc==2&&std::string(argv[1])=="--dns-failure"){
        const auto folder=std::filesystem::current_path()/"build"/"updater-windows-tests";
        if(!CreateDirectoryW(folder.c_str(),nullptr)){std::cerr<<"FAIL: isolated DNS test folder must be new; refusing to reuse or remove it\n";return 1;}
        const bool ok=testDnsResolutionFailure(folder.wstring());const bool removed=RemoveDirectoryW(folder.c_str())!=FALSE;
        if(ok&&removed)std::cout<<"PASS: "<<assertions<<" test-only real DNS-failure assertions executed; no production endpoint override was enabled.\n";
        return ok&&removed?0:1;
    }
    if(argc==2&&std::string(argv[1])=="--invalid-temp-root"){
        const auto folder=std::filesystem::current_path()/"build"/"updater-windows-tests";
        if(!CreateDirectoryW(folder.c_str(),nullptr)){std::cerr<<"FAIL: isolated test folder must be new; refusing to reuse or remove it\n";return 1;}
        const bool ok=testInvalidTemporaryRoot(folder.wstring());
        if(ok)std::cout<<"PASS: "<<assertions<<" invalid temporary-root assertion executed.\n";
        return ok?0:1;
    }
    if(argc==2&&std::string(argv[1])=="--repeat-sha256"){
        const auto folder=std::filesystem::current_path()/"build"/"updater-windows-tests";
        if(!CreateDirectoryW(folder.c_str(),nullptr)){std::cerr<<"FAIL: isolated test folder must be new; refusing to reuse or remove it\n";return 1;}
        const bool ok=testRepeatedPayloadVerification(folder.wstring());RemoveDirectoryW(folder.c_str());
        if(ok)std::cout<<"PASS: "<<assertions<<" repeated payload verification assertion executed.\n";
        return ok?0:1;
    }
    const auto folder=std::filesystem::current_path()/"build"/"updater-windows-tests";
    if(!CreateDirectoryW(folder.c_str(),nullptr)){std::cerr<<"FAIL: isolated test folder must be new; refusing to reuse or remove it\n";return 1;}
    const std::wstring stage=folder.wstring();bool ok=true;
    ok&=testSignedManifestVerification();
    ok&=check(eye::updates::safeStagingDirectory(stage),"isolated staging directory is a regular non-reparse path");
    ok&=testInvalidTemporaryRoot(stage);
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
    std::wstring validationStage;const bool validationStageCreated=testProfileResolved&&eye::updates::createStagingDirectory(validationData,validationStage);const std::wstring portableDirectory=stage+L"\\portable-target";const bool portableDirectoryCreated=CreateDirectoryW(portableDirectory.c_str(),nullptr)!=FALSE;const std::wstring portableTarget=portableDirectory+L"\\EyeBreakReminder.exe";const bool targetInitiallyAbsent=GetFileAttributesW(portableTarget.c_str())==INVALID_FILE_ATTRIBUTES;wchar_t testPreviousAppBuffer[32768]{};const DWORD testPreviousAppLength=GetEnvironmentVariableW(L"EBR_TEST_PREVIOUS_APP",testPreviousAppBuffer,DWORD(std::size(testPreviousAppBuffer)));const std::wstring testPreviousApp=testPreviousAppLength&&testPreviousAppLength<std::size(testPreviousAppBuffer)?std::wstring(testPreviousAppBuffer,testPreviousAppLength):std::wstring{};const bool appCopied=portableDirectoryCreated&&targetInitiallyAbsent&&!testPreviousApp.empty()&&CopyFileW(testPreviousApp.c_str(),portableTarget.c_str(),TRUE);const std::wstring copiedVersion=appCopied?eye::updates::productVersion(portableTarget):std::wstring{};const bool supportedPreviousVersion=copiedVersion==L"1.4.0"||copiedVersion==L"1.4.0.0";const bool usableAppCopied=appCopied&&supportedPreviousVersion;ok&=check(validationStageCreated&&eye::updates::safeStagingDirectory(validationStage)&&eye::updates::safeStagingDirectory(portableDirectory)&&usableAppCopied,"copy the actual isolated v1.4.0 application into the disposable portable transaction fixture");if(!usableAppCopied)std::cerr<<"SEC-028 fixture diagnostic: targetInitiallyAbsent="<<targetInitiallyAbsent<<" sourcePresent="<<!testPreviousApp.empty()<<" sourcePath="<<std::string(testPreviousApp.begin(),testPreviousApp.end())<<" copyError="<<GetLastError()<<" version="<<std::string(copiedVersion.begin(),copiedVersion.end())<<"\\n";
    EphemeralSigningKey transactionSigner;const bool testKeyReady=transactionSigner.generate();const auto validManifest=transactionManifest(transactionSigner);
    ok&=check(validationStageCreated&&testKeyReady&&writeSignedManifest(validationStage,transactionSigner,validManifest),"create a signed test-key transaction fixture with only its public key in the isolated stage");
    eye::updates::Transaction validTransaction;validTransaction.stagingDirectory=validationStage;validTransaction.artifactPath=validationStage+L"\\EyeBreakReminder.exe";validTransaction.targetExecutable=portableTarget;validTransaction.dataDirectory=validationData;validTransaction.version=L"1.4.1";validTransaction.previousVersion=L"1.4.0";validTransaction.nonce=L"12345678-1234-1234-1234-123456789abc";validTransaction.kind="portable";validTransaction.artifactName="EyeBreakReminder.exe";validTransaction.sha256=std::string(64,'b');validTransaction.expectedApplicationSha256=std::string(64,'b');validTransaction.previousSha256=std::string(64,'c');validTransaction.expectedSize=3;validTransaction.ownerPid=GetCurrentProcessId();
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
    struct RejectionFixture {std::string name,manifest,signature;std::string publicPoint;bool missingSignature=false;bool missingManifest=false;};
    std::vector<RejectionFixture> rejectionCases;std::string validManifestBytes=eye::updates::canonicalManifest(validManifest),validSignature;
    ok&=check(transactionSigner.sign(validManifestBytes,validSignature),"prepare the complete valid signed-manifest baseline for the rejection matrix");
    rejectionCases.push_back({"missing signature",validManifestBytes,{}, {},true});
    rejectionCases.push_back({"missing manifest",{}, {}, {},false,true});
    rejectionCases.push_back({"empty signature",validManifestBytes,"",{},false});
    rejectionCases.push_back({"truncated signature",validManifestBytes,validSignature.substr(0,63),{},false});
    rejectionCases.push_back({"invalid signature encoding",validManifestBytes,std::string(64,'\0'),{},false});
    EphemeralSigningKey otherTransactionSigner;ok&=check(otherTransactionSigner.generate(),"generate an unrelated disposable key for transaction rejection coverage");
    std::string otherSignature;otherTransactionSigner.sign(validManifestBytes,otherSignature);
    rejectionCases.push_back({"signature from another key",validManifestBytes,otherSignature,std::string(reinterpret_cast<const char*>(otherTransactionSigner.trusted.p256Point.data()),otherTransactionSigner.trusted.p256Point.size()),false});
    auto addRawCase=[&](const std::string&name,std::string bytes){std::string signature;if(transactionSigner.sign(bytes,signature))rejectionCases.push_back({name,std::move(bytes),std::move(signature),{},false});else ok&=check(false,"sign a controlled rejection fixture with the disposable test key");};
    auto replaceText=[](std::string value,const std::string&from,const std::string&to,bool last=false){const auto at=last?value.rfind(from):value.find(from);if(at==std::string::npos)return std::string{};value.replace(at,from.size(),to);return value;};
    addRawCase("empty signed JSON","");
    rejectionCases.push_back({"manifest modified after signing",replaceText(validManifestBytes,"1.4.1","1.4.2"),validSignature,{},false});
    addRawCase("malformed signed JSON","{");
    const auto duplicateSchema=replaceText(validManifestBytes,"\"schema_version\":1,","\"schema_version\":1,\"schema_version\":1,");
    ok&=check(!duplicateSchema.empty(),"create a signed duplicate-JSON-field rejection fixture");
    if(!duplicateSchema.empty())addRawCase("duplicate JSON schema field",duplicateSchema);
    addRawCase("unsupported signed schema",replaceText(validManifestBytes,"\"schema_version\":1","\"schema_version\":2"));
    addRawCase("wrong signed application",replaceText(validManifestBytes,"Eye Break Reminder","Other Application"));
    addRawCase("wrong signed repository",replaceText(validManifestBytes,"REMEDIOSSAMUEL/EYE-BREAK-REMINDER","REMEDIOSSAMUEL/OTHER-REPOSITORY"));
    addRawCase("unauthorized prerelease channel",replaceText(validManifestBytes,"\"channel\":\"stable\"","\"channel\":\"prerelease\""));
    addRawCase("unsupported signed architecture",replaceText(validManifestBytes,"\"architecture\":\"x64\"","\"architecture\":\"arm64\""));
    addRawCase("unknown signing key identifier",replaceText(validManifestBytes,transactionSigner.trusted.keyId,"p256-ffffffffffffffff"));
    addRawCase("installer/portable asset substitution",replaceText(validManifestBytes,"EyeBreakReminder-Setup-x64.exe","EyeBreakReminder.exe"));
    auto badRole=validManifest;badRole.assets[1].role="installer";std::string badRoleBytes=eye::updates::canonicalManifest(badRole),badRoleSignature;transactionSigner.sign(badRoleBytes,badRoleSignature);rejectionCases.push_back({"conflicting signed asset role",badRoleBytes,badRoleSignature,{},false});
    auto duplicateAsset=validManifest;duplicateAsset.assets.push_back(duplicateAsset.assets.back());std::string duplicateAssetBytes=eye::updates::canonicalManifest(duplicateAsset),duplicateAssetSignature;const bool duplicateAssetSigned=transactionSigner.sign(duplicateAssetBytes,duplicateAssetSignature);ok&=check(duplicateAssetSigned,"sign a conflicting duplicate-asset rejection fixture with the disposable test key");if(duplicateAssetSigned)rejectionCases.push_back({"duplicate signed asset entry",duplicateAssetBytes,duplicateAssetSignature,{},false});
    auto badInstallType=validManifest;badInstallType.assets[1].installationType="installed";std::string badInstallBytes=eye::updates::canonicalManifest(badInstallType),badInstallSignature;transactionSigner.sign(badInstallBytes,badInstallSignature);rejectionCases.push_back({"installer/portable installation-type substitution",badInstallBytes,badInstallSignature,{},false});
    auto badSize=validManifest;badSize.assets[1].size=4;std::string badSizeBytes=eye::updates::canonicalManifest(badSize),badSizeSignature;transactionSigner.sign(badSizeBytes,badSizeSignature);rejectionCases.push_back({"signed size differs from transaction",badSizeBytes,badSizeSignature,{},false});
    auto badDigest=validManifest;badDigest.assets[1].sha256=std::string(64,'d');std::string badDigestBytes=eye::updates::canonicalManifest(badDigest),badDigestSignature;transactionSigner.sign(badDigestBytes,badDigestSignature);rejectionCases.push_back({"signed digest differs from transaction",badDigestBytes,badDigestSignature,{},false});
    auto stale=validManifest;stale.expiresAt="2026-01-01T00:00:00Z";std::string staleBytes=eye::updates::canonicalManifest(stale),staleSignature;transactionSigner.sign(staleBytes,staleSignature);rejectionCases.push_back({"expired signed metadata",staleBytes,staleSignature,{},false});
    auto replay=validManifest;replay.version="1.3.0";std::string replayBytes=eye::updates::canonicalManifest(replay),replaySignature;transactionSigner.sign(replayBytes,replaySignature);rejectionCases.push_back({"replayed older release",replayBytes,replaySignature,{},false});
    auto substitutedVersion=validManifest;substitutedVersion.version="1.4.2";std::string substitutedBytes=eye::updates::canonicalManifest(substitutedVersion),substitutedSignature;transactionSigner.sign(substitutedBytes,substitutedSignature);rejectionCases.push_back({"signed manifest version differs from transaction",substitutedBytes,substitutedSignature,{},false});
    const std::wstring registryPath=L"Software\\EyeBreakReminder-Security-Test\\Process-"+std::to_wstring(GetCurrentProcessId());HKEY testRegistry{};
    DWORD regDisposition=0;const LONG registryCreateStatus=RegCreateKeyExW(HKEY_CURRENT_USER,registryPath.c_str(),0,nullptr,0,KEY_SET_VALUE|KEY_QUERY_VALUE,nullptr,&testRegistry,&regDisposition);
    const bool registryCreated=registryCreateStatus==ERROR_SUCCESS;
    const std::wstring registrySentinel=L"unchanged";const LONG registryWriteStatus=registryCreated?RegSetValueExW(testRegistry,L"Sentinel",0,REG_SZ,reinterpret_cast<const BYTE*>(registrySentinel.c_str()),DWORD((registrySentinel.size()+1)*sizeof(wchar_t))):registryCreateStatus;const bool registryWritten=registryWriteStatus==ERROR_SUCCESS;if(testRegistry)RegCloseKey(testRegistry);
    if(!registryWritten)std::cerr<<"SEC-028 registry setup failed: create="<<registryCreateStatus<<" write="<<registryWriteStatus<<" path="<<std::filesystem::path(registryPath).string()<<"\n";
    ok&=check(registryWritten,"create an isolated current-user registry sentinel for SEC-028");
    const std::wstring launchMarker=stage+L"\\unauthorized-installer-launched.marker";DeleteFileW(launchMarker.c_str());const std::wstring usabilityProfile=stage+L"\\sec028-application-profile";const bool usabilityProfileCreated=CreateDirectoryW(usabilityProfile.c_str(),nullptr)!=FALSE;RunningGuiFixture runningApplication;const bool applicationStarted=usabilityProfileCreated&&usableAppCopied&&runningApplication.start(portableTarget,usabilityProfile);unsigned appTimerInitial=0;const bool appTimerObserved=applicationStarted&&runningApplication.timerSeconds(appTimerInitial);if(!applicationStarted||!appTimerObserved){DWORD liveExitCode=STILL_ACTIVE;const bool exitReadable=runningApplication.process.hProcess&&GetExitCodeProcess(runningApplication.process.hProcess,&liveExitCode);const DWORD exitReadError=exitReadable?ERROR_SUCCESS:GetLastError();std::cerr<<"SEC-028 GUI launch diagnostic: profileCreated="<<usabilityProfileCreated<<" appCopyValid="<<usableAppCopied<<" processStarted="<<applicationStarted<<" timerReadable="<<appTimerObserved<<" pid="<<runningApplication.process.dwProcessId<<" createError="<<runningApplication.createError<<" environmentRestored="<<runningApplication.environmentRestored<<" exitReadable="<<exitReadable<<" exitCode="<<liveExitCode<<" exitReadError="<<exitReadError<<" processQueryError="<<runningApplication.processQueryError<<" timedOut="<<runningApplication.timedOut<<" foreignWindowPid="<<runningApplication.foreignWindowPid<<" window="<<runningApplication.window<<"\n";}ok&=check(applicationStarted,"launch the actual existing Eye Break Reminder app from its disposable profile");if(applicationStarted)ok&=check(appTimerObserved,"read the active timer from the actual running application");
    auto coordinatorMutexExists=[](){HANDLE mutex=OpenMutexW(SYNCHRONIZE,FALSE,L"Local\\EyeBreakReminder.UpdateCoordinator.1");if(!mutex)return false;CloseHandle(mutex);return true;};
    const bool mutexBefore=coordinatorMutexExists();const unsigned launchAttemptsBefore=eye::updates::TestProcessLaunchAttempts.load(std::memory_order_relaxed);unsigned rejectionPasses=0,fileSideEffectPasses=0;
    for(const auto&fixture:rejectionCases){
        const std::wstring manifestPath=validationStage+L"\\EyeBreakReminder-UpdateManifest.json",signaturePath=validationStage+L"\\EyeBreakReminder-UpdateManifest.sig";
        bool written=true;
        if(fixture.missingManifest){
            written=(DeleteFileW(manifestPath.c_str())!=FALSE||GetFileAttributesW(manifestPath.c_str())==INVALID_FILE_ATTRIBUTES);
            written=written&&(DeleteFileW(signaturePath.c_str())!=FALSE||GetFileAttributesW(signaturePath.c_str())==INVALID_FILE_ATTRIBUTES);
        }else{
            written=writeBytes(manifestPath,fixture.manifest);
            const bool signaturePrepared=fixture.missingSignature?
                DeleteFileW(signaturePath.c_str())!=FALSE:writeBytes(signaturePath,fixture.signature);
            written=written&&signaturePrepared;
        }
        if(!fixture.publicPoint.empty())written&=writeBytes(validationStage+L"\\test-update-public-key.bin",fixture.publicPoint);
        else written&=writeBytes(validationStage+L"\\test-update-public-key.bin",std::string(reinterpret_cast<const char*>(transactionSigner.trusted.p256Point.data()),transactionSigner.trusted.p256Point.size()));
        std::string oldExecutable,oldSettings,oldTimer,oldHistory,oldUnrelated;eye::updates::hashFile(portableTarget,oldExecutable);
        eye::win::read(settingsPath,oldSettings,128);eye::win::read(timerPath,oldTimer,128);eye::win::read(historyPath,oldHistory,128);eye::win::read(sentinel,oldUnrelated,128);
        std::size_t entriesBefore=0;const bool entriesObserved=countDirectoryEntries(validationStage,entriesBefore);
        eye::updates::UiState rejectionUi;if(written)eye::updates::performTransaction(validTransaction,rejectionUi);
        validationError=eye::win::utf8(rejectionUi.message);
        const bool rejectionReported=validationError.find("manifest")!=std::string::npos||validationError.find("signature")!=std::string::npos||validationError.find("publisher")!=std::string::npos||validationError.find("stable version")!=std::string::npos;
        const bool rejected=written&&rejectionUi.done.load()&&!rejectionUi.success&&rejectionReported;
        std::string afterExecutable,afterSettings,afterTimer,afterHistory,afterUnrelated;const bool filesObserved=eye::updates::hashFile(portableTarget,afterExecutable)&&eye::win::read(settingsPath,afterSettings,128)&&eye::win::read(timerPath,afterTimer,128)&&eye::win::read(historyPath,afterHistory,128)&&eye::win::read(sentinel,afterUnrelated,128);
        std::size_t entriesAfter=0;const bool entriesStable=entriesObserved&&countDirectoryEntries(validationStage,entriesAfter)&&entriesAfter==entriesBefore;
        HKEY verifyRegistry{};wchar_t registryValue[32]{};DWORD registryType=0,registryBytes=sizeof(registryValue);const LONG registryOpenStatus=RegOpenKeyExW(HKEY_CURRENT_USER,registryPath.c_str(),0,KEY_QUERY_VALUE,&verifyRegistry);const LONG registryQueryStatus=registryOpenStatus==ERROR_SUCCESS?RegQueryValueExW(verifyRegistry,L"Sentinel",nullptr,&registryType,reinterpret_cast<BYTE*>(registryValue),&registryBytes):registryOpenStatus;const bool registryStable=registryQueryStatus==ERROR_SUCCESS&&registryType==REG_SZ&&wcscmp(registryValue,registrySentinel.c_str())==0;if(verifyRegistry)RegCloseKey(verifyRegistry);
        const bool noLaunch=GetFileAttributesW(launchMarker.c_str())==INVALID_FILE_ATTRIBUTES&&eye::updates::TestProcessLaunchAttempts.load(std::memory_order_relaxed)==launchAttemptsBefore;const bool noTemp=GetFileAttributesW((validationStage+L"\\EyeBreakReminder.exe.part").c_str())==INVALID_FILE_ATTRIBUTES&&GetFileAttributesW((validationStage+L"\\transaction.ini.tmp").c_str())==INVALID_FILE_ATTRIBUTES;const bool applicationUsable=applicationStarted&&runningApplication.responsive();
        const bool fileAndProcessEffectsClear=rejected&&filesObserved&&oldExecutable==afterExecutable&&oldSettings==afterSettings&&oldTimer==afterTimer&&oldHistory==afterHistory&&oldUnrelated==afterUnrelated&&coordinatorMutexExists()==mutexBefore&&entriesStable&&noLaunch&&noTemp&&applicationUsable;
        if(fileAndProcessEffectsClear)++fileSideEffectPasses;
        if(fileAndProcessEffectsClear&&registryStable)++rejectionPasses;
        else if(!fileAndProcessEffectsClear||registryWritten)std::cerr<<"SEC-028 detail: "<<fixture.name<<" written="<<written<<" rejected="<<rejected<<" error="<<validationError<<" files="<<filesObserved<<" exe="<<(oldExecutable==afterExecutable)<<" settings="<<(oldSettings==afterSettings)<<" timer="<<(oldTimer==afterTimer)<<" history="<<(oldHistory==afterHistory)<<" unrelated="<<(oldUnrelated==afterUnrelated)<<" registry="<<registryStable<<" regOpen="<<registryOpenStatus<<" regQuery="<<registryQueryStatus<<" regType="<<registryType<<" mutex="<<(coordinatorMutexExists()==mutexBefore)<<" entries="<<entriesStable<<" launch="<<noLaunch<<" temp="<<noTemp<<" appUsable="<<applicationUsable<<" countBefore="<<entriesBefore<<" countAfter="<<entriesAfter<<"\n";
        ok&=check(fileAndProcessEffectsClear,("reject "+fixture.name+" without changing app/profile/filesystem/staging, launching a helper, or interrupting the running app").c_str());
        if(registryWritten)ok&=check(registryStable,("reject "+fixture.name+" without changing the isolated registry sentinel").c_str());
        ok&=check(writeSignedManifest(validationStage,transactionSigner,validManifest),"restore the valid signed test metadata after each rejection probe");
    }
    if(registryWritten)ok&=check(rejectionPasses==rejectionCases.size(),"SEC-028 scoped rejection matrix preserves app/profile/registry/process state across every signed-metadata rejection");
    else {std::cerr<<"BLOCKED: SEC-028 registry side-effect observation unavailable; disposable HKCU write returned ERROR_ACCESS_DENIED. File/profile/staging observations passed "<<fileSideEffectPasses<<"/"<<rejectionCases.size()<<" cases.\n";ok=false;}
    if(registryWritten&&rejectionPasses==rejectionCases.size())std::cout<<"PASS: SEC-028 observed "<<rejectionPasses<<"/"<<rejectionCases.size()<<" rejection paths with unchanged executable, settings, timer, history, unrelated file, registry sentinel, staging entries and coordinator state; zero helper launches; running app remained responsive.\n";
    ok&=check(appTimerObserved&&runningApplication.waitForTimerProgress(appTimerInitial),"the running application's timer continues progressing during repeated signed-manifest rejection checks");
    ok&=check(runningApplication.close(),"close the isolated prior application normally after the rejection matrix");
    RegDeleteKeyW(HKEY_CURRENT_USER,registryPath.c_str());
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
    SetEnvironmentVariableW(L"EBR_GUI_TEST_DATA_DIRECTORY",nullptr);DeleteFileW(sentinel.c_str());RemoveDirectoryW(sentinelDirectory.c_str());DeleteFileW(portableTarget.c_str());RemoveDirectoryW(portableDirectory.c_str());DeleteFileW(settingsPath.c_str());DeleteFileW(timerPath.c_str());DeleteFileW(historyPath.c_str());DeleteFileW((settingsPath+L".update-restore").c_str());DeleteFileW((timerPath+L".update-restore").c_str());DeleteFileW((historyPath+L".update-restore").c_str());DeleteFileW((validationStage+L"\\EyeBreakReminder-UpdateManifest.json").c_str());DeleteFileW((validationStage+L"\\EyeBreakReminder-UpdateManifest.sig").c_str());DeleteFileW((validationStage+L"\\test-update-public-key.bin").c_str());DeleteFileW((validationStage+L"\\backup-0.dat").c_str());DeleteFileW((validationStage+L"\\backup-1.dat").c_str());DeleteFileW((validationStage+L"\\backup-2.dat").c_str());DeleteFileW((validationStage+L"\\transaction.ini").c_str());DeleteFileW((validationStage+L"\\transaction.ini.tmp").c_str());if(validationStageCreated)RemoveDirectoryW(validationStage.c_str());RemoveDirectoryW(updatesRoot.c_str());RemoveDirectoryW(validationData.c_str());

    auto removeOptionalProfileFile=[](const std::wstring&path){if(DeleteFileW(path.c_str()))return true;const DWORD error=GetLastError();return error==ERROR_FILE_NOT_FOUND||error==ERROR_PATH_NOT_FOUND;};
    const bool profileFilesRemoved=removeOptionalProfileFile(usabilityProfile+L"\\settings.ini")&&removeOptionalProfileFile(usabilityProfile+L"\\timer.dat")&&removeOptionalProfileFile(usabilityProfile+L"\\history.dat");const bool profileRemoved=profileFilesRemoved&&RemoveDirectoryW(usabilityProfile.c_str())!=FALSE;const DWORD profileRemoveError=profileRemoved?ERROR_SUCCESS:GetLastError();
    DeleteFileW((stage+L"\\fixture.bin").c_str());DeleteFileW((stage+L"\\transaction.ini").c_str());DeleteFileW((stage+L"\\transaction.ini.tmp").c_str());DeleteFileW((stage+L"\\previous-owned-0.dat").c_str());DeleteFileW((stage+L"\\previous-owned-1.dat").c_str());DeleteFileW((stage+L"\\previous-owned-3.dat").c_str());const bool uninstallRemoved=DeleteFileW((install+L"\\Uninstall.exe").c_str())!=FALSE;const DWORD uninstallRemoveError=uninstallRemoved?ERROR_SUCCESS:GetLastError();const bool readmeRemoved=DeleteFileW((install+L"\\README.md").c_str())!=FALSE;const DWORD readmeRemoveError=readmeRemoved?ERROR_SUCCESS:GetLastError();const bool verificationRemoved=DeleteFileW((install+L"\\VERIFICATION.md").c_str())!=FALSE;const DWORD verificationRemoveError=verificationRemoved?ERROR_SUCCESS:GetLastError();const bool filesRemoved=uninstallRemoved&&readmeRemoved&&verificationRemoved;const bool installRemoved=filesRemoved&&RemoveDirectoryW(install.c_str())!=FALSE;const DWORD installRemoveError=installRemoved?ERROR_SUCCESS:GetLastError();const bool stageRemoved=installRemoved&&RemoveDirectoryW(stage.c_str())!=FALSE;const DWORD stageRemoveError=stageRemoved?ERROR_SUCCESS:GetLastError();const bool removed=stageRemoved&&profileRemoved;
    if(!removed){std::cerr<<"SEC-028 cleanup diagnostic: uninstall="<<uninstallRemoved<<" error="<<uninstallRemoveError<<" readme="<<readmeRemoved<<" error="<<readmeRemoveError<<" verification="<<verificationRemoved<<" error="<<verificationRemoveError<<" installDir="<<installRemoved<<" error="<<installRemoveError<<" profileFiles="<<profileFilesRemoved<<" profileDir="<<profileRemoved<<" error="<<profileRemoveError<<" stageDir="<<stageRemoved<<" error="<<stageRemoveError<<" stage="<<std::filesystem::path(stage).string()<<" remaining=";std::error_code listingError;for(const auto&entry:std::filesystem::directory_iterator(stage,listingError))std::cerr<<entry.path().filename().string()<<((entry.is_directory(listingError))?"/":"")<<",";std::cerr<<" listingError="<<listingError.value()<<"\n";}
    ok&=check(removed,"remove exact isolated updater test folder");
    if(!ok)return 1;
    std::cout<<"PASS: "<<assertions<<" Windows updater assertions executed.\n";return 0;
}
