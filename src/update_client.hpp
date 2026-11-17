#pragma once

#include "update_checker.hpp"
#include <windows.h>
#include <winhttp.h>
#include <bcrypt.h>
#include <algorithm>
#include <atomic>
#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace eye::updates {

struct DownloadProgress { std::uint64_t received=0,total=0;bool verifying=false; };
struct DownloadResult { bool ok=false,cancelled=false;std::string error,sha256;std::uint64_t received=0; };

namespace client_detail {
struct Internet {
    HINTERNET value{};
    explicit Internet(HINTERNET h=nullptr):value(h){}
    ~Internet(){if(value)WinHttpCloseHandle(value);}
    Internet(const Internet&)=delete;Internet&operator=(const Internet&)=delete;
};
struct HashProvider {
    BCRYPT_ALG_HANDLE algorithm{};BCRYPT_HASH_HANDLE hash{};std::vector<BYTE> object;
    ~HashProvider(){if(hash)BCryptDestroyHash(hash);if(algorithm)BCryptCloseAlgorithmProvider(algorithm,0);}
    bool open(){DWORD bytes=0,got=0;if(BCryptOpenAlgorithmProvider(&algorithm,BCRYPT_SHA256_ALGORITHM,nullptr,0)<0||
      BCryptGetProperty(algorithm,BCRYPT_OBJECT_LENGTH,reinterpret_cast<PUCHAR>(&bytes),sizeof(bytes),&got,0)<0||!bytes)return false;
      object.resize(bytes);return BCryptCreateHash(algorithm,&hash,object.data(),bytes,nullptr,0,0)>=0;}
};
struct Url {std::wstring host,path;INTERNET_PORT port=0;};
inline bool allowHost(const std::wstring&host){
    return _wcsicmp(host.c_str(),L"github.com")==0||_wcsicmp(host.c_str(),L"release-assets.githubusercontent.com")==0||
      _wcsicmp(host.c_str(),L"objects.githubusercontent.com")==0||_wcsicmp(host.c_str(),L"github-releases.githubusercontent.com")==0;
}
inline bool crackHttps(const std::wstring&text,Url&out){
    if(text.empty()||text.size()>8192)return false;
    URL_COMPONENTSW c{};c.dwStructSize=sizeof(c);c.dwSchemeLength=DWORD(-1);c.dwHostNameLength=DWORD(-1);c.dwUserNameLength=DWORD(-1);c.dwPasswordLength=DWORD(-1);c.dwUrlPathLength=DWORD(-1);c.dwExtraInfoLength=DWORD(-1);
    if(!WinHttpCrackUrl(text.c_str(),DWORD(text.size()),0,&c)||c.nScheme!=INTERNET_SCHEME_HTTPS||c.dwUserNameLength||c.dwPasswordLength)return false;
    out.host.assign(c.lpszHostName,c.dwHostNameLength);out.port=c.nPort;
#ifdef EYEBREAK_TEST_BUILD
    const bool loopbackTest=_wcsicmp(out.host.c_str(),L"localhost")==0&&out.port>=1024;
    if(!allowHost(out.host)&&!loopbackTest)return false;
#else
    if(out.port!=INTERNET_DEFAULT_HTTPS_PORT||!allowHost(out.host))return false;
#endif
    out.path.assign(c.lpszUrlPath,c.dwUrlPathLength);if(c.dwExtraInfoLength)out.path.append(c.lpszExtraInfo,c.dwExtraInfoLength);
    if(out.path.empty())out.path=L"/";
    return out.path.front()==L'/';
}
inline std::wstring redirectLocation(HINTERNET request){
    DWORD bytes=0;WinHttpQueryHeaders(request,WINHTTP_QUERY_LOCATION,WINHTTP_HEADER_NAME_BY_INDEX,nullptr,&bytes,WINHTTP_NO_HEADER_INDEX);
    if(GetLastError()!=ERROR_INSUFFICIENT_BUFFER||!bytes||bytes>16384)return{};
    std::vector<wchar_t> buffer(bytes/sizeof(wchar_t)+1);if(!WinHttpQueryHeaders(request,WINHTTP_QUERY_LOCATION,WINHTTP_HEADER_NAME_BY_INDEX,buffer.data(),&bytes,WINHTTP_NO_HEADER_INDEX))return{};
    return buffer.data();
}
inline std::string lower(std::string value){for(char&c:value)if(c>='A'&&c<='Z')c=char(c-'A'+'a');return value;}
inline std::string hex(const BYTE*data,std::size_t n){static constexpr char digits[]="0123456789abcdef";std::string out;out.reserve(n*2);for(std::size_t i=0;i<n;++i){out.push_back(digits[data[i]>>4]);out.push_back(digits[data[i]&15]);}return out;}
inline bool contentLength(HINTERNET request,std::uint64_t&out){
    wchar_t text[64]{};DWORD bytes=sizeof(text);if(!WinHttpQueryHeaders(request,WINHTTP_QUERY_CONTENT_LENGTH,WINHTTP_HEADER_NAME_BY_INDEX,text,&bytes,WINHTTP_NO_HEADER_INDEX))return false;
    if(bytes<sizeof(wchar_t))return false;
    std::uint64_t n=0;for(const wchar_t*p=text;*p;++p){if(*p<L'0'||*p>L'9'||n>(UINT64_MAX-std::uint64_t(*p-L'0'))/10)return false;n=n*10+std::uint64_t(*p-L'0');}out=n;return true;
}
inline Failure networkFailure(DWORD code){
    if(code==ERROR_WINHTTP_TIMEOUT)return Failure::Timeout;
    if(code==ERROR_WINHTTP_SECURE_FAILURE)return Failure::SecureConnection;
    if(code==ERROR_WINHTTP_NAME_NOT_RESOLVED||code==ERROR_WINHTTP_CANNOT_CONNECT||code==ERROR_WINHTTP_CONNECTION_ERROR)return Failure::Offline;
    return Failure::Other;
}
} // namespace client_detail

inline HttpResponse latestStableReleaseResponse(){
    HttpResponse response;client_detail::Internet session{WinHttpOpen(L"Eye Break Reminder updater",WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,WINHTTP_NO_PROXY_NAME,WINHTTP_NO_PROXY_BYPASS,0)};
    if(!session.value){const DWORD error=GetLastError();response.failure=client_detail::networkFailure(error);response.errorCode=error;return response;}
    if(!WinHttpSetTimeouts(session.value,5000,5000,5000,10000)){const DWORD error=GetLastError();response.failure=client_detail::networkFailure(error);response.errorCode=error;return response;}
    client_detail::Internet connection{WinHttpConnect(session.value,L"api.github.com",INTERNET_DEFAULT_HTTPS_PORT,0)};
    if(!connection.value){const DWORD error=GetLastError();response.failure=client_detail::networkFailure(error);response.errorCode=error;return response;}
    client_detail::Internet request{WinHttpOpenRequest(connection.value,L"GET",L"/repos/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/latest",nullptr,WINHTTP_NO_REFERER,WINHTTP_DEFAULT_ACCEPT_TYPES,WINHTTP_FLAG_SECURE)};
    if(!request.value){const DWORD error=GetLastError();response.failure=client_detail::networkFailure(error);response.errorCode=error;return response;}
    DWORD disableRedirects=WINHTTP_DISABLE_REDIRECTS;if(!WinHttpSetOption(request.value,WINHTTP_OPTION_DISABLE_FEATURE,&disableRedirects,sizeof(disableRedirects))){const DWORD error=GetLastError();response.failure=client_detail::networkFailure(error);response.errorCode=error;return response;}
    const wchar_t*headers=L"Accept: application/vnd.github+json\r\nX-GitHub-Api-Version: 2022-11-28\r\n";
    if(!WinHttpAddRequestHeaders(request.value,headers,DWORD(-1),WINHTTP_ADDREQ_FLAG_ADD|WINHTTP_ADDREQ_FLAG_REPLACE)||!WinHttpSendRequest(request.value,WINHTTP_NO_ADDITIONAL_HEADERS,0,WINHTTP_NO_REQUEST_DATA,0,0,0)||!WinHttpReceiveResponse(request.value,nullptr)){
        const DWORD error=GetLastError();response.failure=client_detail::networkFailure(error);response.errorCode=error;return response;
    }
    DWORD status=0,statusSize=sizeof(status);if(!WinHttpQueryHeaders(request.value,WINHTTP_QUERY_STATUS_CODE|WINHTTP_QUERY_FLAG_NUMBER,WINHTTP_HEADER_NAME_BY_INDEX,&status,&statusSize,WINHTTP_NO_HEADER_INDEX)){const DWORD error=GetLastError();response.failure=client_detail::networkFailure(error);response.errorCode=error;return response;}response.status=int(status);
    while(response.body.size()<=1024*1024){DWORD available=0;if(!WinHttpQueryDataAvailable(request.value,&available)){const DWORD error=GetLastError();response.failure=client_detail::networkFailure(error);response.errorCode=error;response.body.clear();return response;}if(!available)break;const DWORD amount=std::min<DWORD>(available,DWORD(1024*1024+1-response.body.size()));if(!amount)break;const auto old=response.body.size();response.body.resize(old+amount);DWORD read=0;if(!WinHttpReadData(request.value,response.body.data()+old,amount,&read)){const DWORD error=GetLastError();response.failure=client_detail::networkFailure(error);response.errorCode=error;response.body.clear();return response;}response.body.resize(old+read);if(!read)break;}
    return response;
}

inline bool safeStagingDirectory(const std::wstring&path){
    std::vector<wchar_t> full(32768);DWORD n=GetFullPathNameW(path.c_str(),DWORD(full.size()),full.data(),nullptr);if(!n||n>=full.size()||n<4||full[1]!=L':'||full[2]!=L'\\')return false;
    std::wstring current(full.data(),n);for(std::size_t at=3;at<=current.size();++at)if(at==current.size()||current[at]==L'\\'){
        const std::wstring part=current.substr(0,at);DWORD attr=GetFileAttributesW(part.c_str());if(attr==INVALID_FILE_ATTRIBUTES||!(attr&FILE_ATTRIBUTE_DIRECTORY)||(attr&FILE_ATTRIBUTE_REPARSE_POINT))return false;
    }
    return true;
}

inline bool createStagingDirectory(const std::wstring&dataDirectory,std::wstring&out){
    if(!safeStagingDirectory(dataDirectory))return false;
    const std::wstring updates=dataDirectory+L"\\updates";if(!CreateDirectoryW(updates.c_str(),nullptr)&&GetLastError()!=ERROR_ALREADY_EXISTS)return false;
    if(!safeStagingDirectory(updates))return false;
    GUID id{};if(FAILED(CoCreateGuid(&id)))return false;wchar_t name[40]{};if(!StringFromGUID2(id,name,40))return false;
    out=updates+L"\\"+name;if(!CreateDirectoryW(out.c_str(),nullptr)){out.clear();return false;}if(!safeStagingDirectory(out)){RemoveDirectoryW(out.c_str());out.clear();return false;}return true;
}

inline DownloadResult downloadVerified(const ReleaseAsset&asset,const std::wstring&stagingDirectory,const std::wstring&fileName,
                                       std::atomic_bool&cancelled,const std::function<void(DownloadProgress)>&progress={}){
    DownloadResult result;
    constexpr std::uint64_t maximum=100ull*1024*1024;
    if(asset.size==0||asset.size>maximum||asset.name.empty()||(fileName!=L"EyeBreakReminder-Setup-x64.exe"&&fileName!=L"EyeBreakReminder.exe")||!safeStagingDirectory(stagingDirectory)){
        result.error="The update asset or its private staging location is invalid.";return result;
    }
    const auto digestAt=asset.digest.find(':');if(digestAt==std::string::npos||asset.digest.substr(0,digestAt)!="sha256"||asset.digest.size()-digestAt-1!=64){result.error="The update has no usable SHA-256 digest.";return result;}
    const std::string expected=client_detail::lower(asset.digest.substr(digestAt+1));
    ULARGE_INTEGER freeBytes{};if(!GetDiskFreeSpaceExW(stagingDirectory.c_str(),&freeBytes,nullptr,nullptr)||freeBytes.QuadPart<asset.size+8ull*1024*1024){result.error="There is not enough free disk space to stage this update safely.";return result;}
    const std::wstring partial=stagingDirectory+L"\\"+fileName+L".part",destination=stagingDirectory+L"\\"+fileName;
    HANDLE output=CreateFileW(partial.c_str(),GENERIC_WRITE,0,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL|FILE_FLAG_WRITE_THROUGH,nullptr);
    if(output==INVALID_HANDLE_VALUE){result.error="Windows could not create a private update download file.";return result;}
    if(progress)progress({0,asset.size,false});
    auto removePartial=[&]{CloseHandle(output);output=INVALID_HANDLE_VALUE;DeleteFileW(partial.c_str());};
    client_detail::HashProvider hash;if(!hash.open()){removePartial();result.error="Windows could not initialize SHA-256 verification.";return result;}
    std::wstring current;try{current=std::wstring(asset.downloadUrl.begin(),asset.downloadUrl.end());}catch(...){removePartial();result.error="The official download address is invalid.";return result;}
    DWORD accessType=WINHTTP_ACCESS_TYPE_DEFAULT_PROXY;
#ifdef EYEBREAK_TEST_BUILD
    client_detail::Url initialUrl;const bool loopbackTestSession=client_detail::crackHttps(current,initialUrl)&&_wcsicmp(initialUrl.host.c_str(),L"localhost")==0;
    if(loopbackTestSession)accessType=WINHTTP_ACCESS_TYPE_NO_PROXY;
#endif
    client_detail::Internet session{WinHttpOpen(L"Eye Break Reminder updater",accessType,WINHTTP_NO_PROXY_NAME,WINHTTP_NO_PROXY_BYPASS,0)};
    if(!session.value){removePartial();result.error="Windows could not start the secure download service.";return result;}
#ifdef EYEBREAK_TEST_BUILD
    if(loopbackTestSession)WinHttpSetTimeouts(session.value,1000,1000,1000,3000);
    else WinHttpSetTimeouts(session.value,5000,5000,10000,15000);
#else
    WinHttpSetTimeouts(session.value,5000,5000,10000,15000);
#endif
    const ULONGLONG start=GetTickCount64();bool complete=false;
    for(unsigned redirect=0;redirect<=5&&!complete;++redirect){
        if(cancelled.load()){result.cancelled=true;break;}client_detail::Url url;if(!client_detail::crackHttps(current,url)){result.error="The download redirect left the approved HTTPS GitHub asset hosts.";break;}
        client_detail::Internet connection{WinHttpConnect(session.value,url.host.c_str(),url.port,0)};
        if(!connection.value){result.error="The secure connection to the release asset failed.";break;}
        client_detail::Internet request{WinHttpOpenRequest(connection.value,L"GET",url.path.c_str(),nullptr,WINHTTP_NO_REFERER,WINHTTP_DEFAULT_ACCEPT_TYPES,WINHTTP_FLAG_SECURE)};
        if(!request.value){result.error="Windows could not prepare the release asset request.";break;}
        DWORD disableRedirects=WINHTTP_DISABLE_REDIRECTS;WinHttpSetOption(request.value,WINHTTP_OPTION_DISABLE_FEATURE,&disableRedirects,sizeof(disableRedirects));
        const wchar_t*headers=L"Accept: application/octet-stream\r\n";
        if(!WinHttpAddRequestHeaders(request.value,headers,DWORD(-1),WINHTTP_ADDREQ_FLAG_ADD|WINHTTP_ADDREQ_FLAG_REPLACE)||!WinHttpSendRequest(request.value,WINHTTP_NO_ADDITIONAL_HEADERS,0,WINHTTP_NO_REQUEST_DATA,0,0,0)||!WinHttpReceiveResponse(request.value,nullptr)){
            result.error=GetLastError()==ERROR_WINHTTP_TIMEOUT?"The download timed out. Try again when your connection is stable.":"Windows could not securely connect to the release asset.";break;
        }
        DWORD status=0,statusBytes=sizeof(status);if(!WinHttpQueryHeaders(request.value,WINHTTP_QUERY_STATUS_CODE|WINHTTP_QUERY_FLAG_NUMBER,WINHTTP_HEADER_NAME_BY_INDEX,&status,&statusBytes,WINHTTP_NO_HEADER_INDEX)){result.error="GitHub returned an unreadable download response.";break;}
        if(status==301||status==302||status==303||status==307||status==308){if(redirect==5){result.error="GitHub redirected the download too many times.";break;}std::wstring next=client_detail::redirectLocation(request.value);client_detail::Url checked;if(next.empty()||!client_detail::crackHttps(next,checked)){result.error="GitHub returned an unsafe or invalid HTTPS download redirect.";break;}current=std::move(next);continue;}
        if(status!=200){result.error="GitHub returned HTTP "+std::to_string(status)+" while downloading the update.";break;}
        std::uint64_t headerLength=0;if(client_detail::contentLength(request.value,headerLength)&&headerLength!=asset.size){result.error="The release asset size did not match GitHub's metadata.";break;}
        for(;;){
            if(cancelled.load()){result.cancelled=true;break;}if(GetTickCount64()-start>10ull*60*1000){result.error="The download exceeded its 10 minute time limit.";break;}
            DWORD available=0;if(!WinHttpQueryDataAvailable(request.value,&available)){result.error=GetLastError()==ERROR_WINHTTP_TIMEOUT?"The download timed out.":"The update download was interrupted.";break;}if(!available){complete=true;break;}
            BYTE buffer[64*1024];DWORD amount=std::min<DWORD>(available,sizeof(buffer)),read=0;
            if(!WinHttpReadData(request.value,buffer,amount,&read)){result.error="The update download was interrupted.";break;}if(!read){complete=true;break;}
            if(read>asset.size||result.received>asset.size-read){result.error="The downloaded asset exceeded GitHub's published size.";break;}
            DWORD written=0;if(!WriteFile(output,buffer,read,&written,nullptr)||written!=read||BCryptHashData(hash.hash,buffer,read,0)<0){result.error="The update could not be written or verified on disk.";break;}
            result.received+=read;if(progress)progress({result.received,asset.size});
        }
        if(!complete||result.cancelled||!result.error.empty())break;
    }
    if(result.cancelled){removePartial();result.error="Download cancelled.";return result;}
    if(!complete||!result.error.empty()||result.received!=asset.size){if(result.error.empty())result.error="The download was incomplete.";removePartial();return result;}
    if(progress)progress({result.received,asset.size,true});
    BYTE digest[32]{};if(BCryptFinishHash(hash.hash,digest,sizeof(digest),0)<0){removePartial();result.error="Windows could not finish SHA-256 verification.";return result;}
    result.sha256=client_detail::hex(digest,sizeof(digest));if(result.sha256!=expected){removePartial();result.error="The downloaded file failed GitHub's SHA-256 integrity check.";return result;}
    if(!FlushFileBuffers(output)){removePartial();result.error="Windows could not flush the verified update to disk.";return result;}
    CloseHandle(output);output=INVALID_HANDLE_VALUE;
    if(!MoveFileExW(partial.c_str(),destination.c_str(),MOVEFILE_WRITE_THROUGH)){DeleteFileW(partial.c_str());result.error="Windows could not move the verified update into its staging location.";return result;}
    result.ok=true;return result;
}

#ifdef EYEBREAK_TEST_BUILD
inline DownloadResult downloadVerifiedFixture(const ReleaseAsset&asset,const std::wstring&sourcePath,const std::wstring&stagingDirectory,const std::wstring&fileName,
                                               std::atomic_bool&cancelled,const std::function<void(DownloadProgress)>&progress={}){
    DownloadResult result;constexpr std::uint64_t maximum=100ull*1024*1024;
    if(asset.size==0||asset.size>maximum||!safeStagingDirectory(stagingDirectory)||(fileName!=L"EyeBreakReminder-Setup-x64.exe"&&fileName!=L"EyeBreakReminder.exe")){result.error="The test update asset or staging location is invalid.";return result;}
    const auto separator=asset.digest.find(':');if(separator==std::string::npos||asset.digest.substr(0,separator)!="sha256"||asset.digest.size()-separator-1!=64){result.error="The test update has no usable SHA-256 digest.";return result;}
    const std::string expected=client_detail::lower(asset.digest.substr(separator+1));
    HANDLE input=CreateFileW(sourcePath.c_str(),GENERIC_READ,FILE_SHARE_READ,nullptr,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT|FILE_FLAG_SEQUENTIAL_SCAN,nullptr);
    if(input==INVALID_HANDLE_VALUE){result.error="The test update fixture could not be opened.";return result;}
    FILE_ATTRIBUTE_TAG_INFO tag{};LARGE_INTEGER length{};const bool sourceValid=GetFileInformationByHandleEx(input,FileAttributeTagInfo,&tag,sizeof(tag))&&!(tag.FileAttributes&(FILE_ATTRIBUTE_REPARSE_POINT|FILE_ATTRIBUTE_DIRECTORY))&&GetFileSizeEx(input,&length)&&length.QuadPart>0&&std::uint64_t(length.QuadPart)<=asset.size;
    if(!sourceValid){CloseHandle(input);result.error="The test update fixture is not a regular file of the declared size.";return result;}
    const std::wstring partial=stagingDirectory+L"\\"+fileName+L".part",destination=stagingDirectory+L"\\"+fileName;HANDLE output=CreateFileW(partial.c_str(),GENERIC_WRITE,0,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL|FILE_FLAG_WRITE_THROUGH,nullptr);
    if(output==INVALID_HANDLE_VALUE){CloseHandle(input);result.error="Windows could not create the test update staging file.";return result;}
    auto cleanup=[&]{CloseHandle(input);CloseHandle(output);DeleteFileW(partial.c_str());};client_detail::HashProvider hash;if(!hash.open()){cleanup();result.error="Windows could not initialize test SHA-256 verification.";return result;}
    DWORD delay=0;wchar_t delayText[16]{};DWORD delayChars=GetEnvironmentVariableW(L"EBR_GUI_TEST_UPDATE_DELAY_MS",delayText,DWORD(std::size(delayText)));if(delayChars&&delayChars<std::size(delayText))delay=std::min<DWORD>(250,DWORD(std::wcstoul(delayText,nullptr,10)));
    if(progress)progress({0,asset.size,false});
    BYTE buffer[64*1024];bool ok=true;
    while(ok){if(cancelled.load()){result.cancelled=true;break;}DWORD read=0;if(!ReadFile(input,buffer,sizeof(buffer),&read,nullptr)){ok=false;break;}if(!read)break;DWORD written=0;if(!WriteFile(output,buffer,read,&written,nullptr)||written!=read||BCryptHashData(hash.hash,buffer,read,0)<0){ok=false;break;}result.received+=read;if(progress)progress({result.received,asset.size,false});if(delay)Sleep(delay);}
    if(result.cancelled){cleanup();result.error="Download cancelled.";return result;}if(!ok||result.received!=asset.size){cleanup();result.error="The test update fixture copy was interrupted.";return result;}
    if(progress)progress({result.received,asset.size,true});
    BYTE digest[32]{};if(BCryptFinishHash(hash.hash,digest,sizeof(digest),0)<0){cleanup();result.error="Windows could not finish test SHA-256 verification.";return result;}
    result.sha256=client_detail::hex(digest,sizeof(digest));if(result.sha256!=expected){cleanup();result.error="The test update fixture failed its SHA-256 integrity check.";return result;}
    if(!FlushFileBuffers(output)){cleanup();result.error="Windows could not flush the verified test update.";return result;}CloseHandle(input);input=INVALID_HANDLE_VALUE;CloseHandle(output);output=INVALID_HANDLE_VALUE;
    if(!MoveFileExW(partial.c_str(),destination.c_str(),MOVEFILE_WRITE_THROUGH)){DeleteFileW(partial.c_str());result.error="Windows could not move the verified test update into its staging folder.";return result;}result.ok=true;return result;
}
#endif

} // namespace eye::updates
