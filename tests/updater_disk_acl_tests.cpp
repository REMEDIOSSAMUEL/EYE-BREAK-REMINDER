#define EYEBREAK_TEST_BUILD
#include <windows.h>
#include <aclapi.h>
#include <sddl.h>
#include <atomic>
#include <cstddef>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>

namespace {
std::atomic_bool forceFreeSpace{false};
std::atomic<unsigned long long> freeSpaceBytes{0};
std::atomic<unsigned> freeSpaceQueries{0};
}

BOOL WINAPI testGetDiskFreeSpaceExW(LPCWSTR path,PULARGE_INTEGER available,PULARGE_INTEGER total,PULARGE_INTEGER totalFree){
    ++freeSpaceQueries;
    if(forceFreeSpace.load()){
        const auto value=freeSpaceBytes.load();
        if(available)available->QuadPart=value;
        if(total)total->QuadPart=value;
        if(totalFree)totalFree->QuadPart=value;
        SetLastError(ERROR_SUCCESS);
        return TRUE;
    }
    return ::GetDiskFreeSpaceExW(path,available,total,totalFree);
}

#define GetDiskFreeSpaceExW testGetDiskFreeSpaceExW
#include "../src/update_client.hpp"
#undef GetDiskFreeSpaceExW

namespace {
int assertions=0;
bool check(bool value,const char*name){
    ++assertions;
    if(!value)std::cerr<<"FAIL: "<<name<<'\n';
    else std::cout<<"PASS: "<<name<<'\n';
    return value;
}
bool writeBytes(const std::wstring&path,const std::string&value){
    HANDLE file=CreateFileW(path.c_str(),GENERIC_WRITE,0,nullptr,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,nullptr);
    if(file==INVALID_HANDLE_VALUE)return false;
    DWORD wrote=0;const bool ok=WriteFile(file,value.data(),DWORD(value.size()),&wrote,nullptr)&&wrote==value.size();
    CloseHandle(file);return ok;
}
bool currentUserCanCreateStageFile(const std::wstring&path){
    const std::wstring probe=path+L"\\acl-write-probe.tmp";
    HANDLE file=CreateFileW(probe.c_str(),GENERIC_WRITE,0,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);
    if(file==INVALID_HANDLE_VALUE)return false;
    CloseHandle(file);
    return DeleteFileW(probe.c_str())!=FALSE;
}
bool assertNoBroadWritableAce(const std::wstring&path){
    PSECURITY_DESCRIPTOR descriptor=nullptr;PACL dacl=nullptr;
    const DWORD status=GetNamedSecurityInfoW(const_cast<LPWSTR>(path.c_str()),SE_FILE_OBJECT,DACL_SECURITY_INFORMATION,nullptr,nullptr,&dacl,nullptr,&descriptor);
    if(status!=ERROR_SUCCESS||!descriptor||!dacl){if(descriptor)LocalFree(descriptor);return false;}
    bool broadWrite=false;
    const DWORD writes=FILE_ADD_FILE|FILE_ADD_SUBDIRECTORY|FILE_WRITE_DATA|DELETE|WRITE_DAC|WRITE_OWNER|GENERIC_WRITE|GENERIC_ALL;
    const auto isBroadWritable=[&](PSID sid,ACCESS_MASK mask){return IsValidSid(sid)&&(mask&writes)&&(IsWellKnownSid(sid,WinWorldSid)||IsWellKnownSid(sid,WinBuiltinUsersSid)||IsWellKnownSid(sid,WinAuthenticatedUserSid));};
    for(DWORD index=0;index<dacl->AceCount;++index){
        void*raw=nullptr;if(!GetAce(dacl,index,&raw)){broadWrite=true;break;}
        const auto*header=static_cast<const ACE_HEADER*>(raw);
        if(header->AceType==ACCESS_ALLOWED_ACE_TYPE){
            const auto*ace=static_cast<const ACCESS_ALLOWED_ACE*>(raw);
            if(isBroadWritable(const_cast<DWORD*>(&ace->SidStart),ace->Mask))broadWrite=true;
        }else if(header->AceType==ACCESS_ALLOWED_OBJECT_ACE_TYPE){
            const auto*ace=static_cast<const ACCESS_ALLOWED_OBJECT_ACE*>(raw);
            std::size_t offset=offsetof(ACCESS_ALLOWED_OBJECT_ACE,ObjectType);
            if(ace->Flags&ACE_OBJECT_TYPE_PRESENT)offset+=sizeof(GUID);
            if(ace->Flags&ACE_INHERITED_OBJECT_TYPE_PRESENT)offset+=sizeof(GUID);
            if(offset>=header->AceSize||header->AceSize-offset<sizeof(DWORD)){broadWrite=true;break;}
            auto*sid=reinterpret_cast<PSID>(reinterpret_cast<BYTE*>(raw)+offset);
            if(isBroadWritable(sid,ace->Mask))broadWrite=true;
        }
    }
    if(broadWrite){
        LPWSTR sddl=nullptr;
        if(ConvertSecurityDescriptorToStringSecurityDescriptorW(descriptor,SDDL_REVISION_1,DACL_SECURITY_INFORMATION,&sddl,nullptr)){
            std::wcerr<<L"Observed staging DACL: "<<sddl<<L'\n';LocalFree(sddl);
        }
    }
    LocalFree(descriptor);return !broadWrite;
}
bool testLowDiskSpacePreflight(const std::wstring&stage){
    const std::wstring sentinel=stage+L"\\prior-install.sentinel";
    const std::wstring partial=stage+L"\\EyeBreakReminder-Setup-x64.exe.part";
    const std::wstring final=stage+L"\\EyeBreakReminder-Setup-x64.exe";
    const bool sentinelCreated=writeBytes(sentinel,"previous installation unchanged");
    eye::updates::ReleaseAsset asset{"EyeBreakReminder-Setup-x64.exe","https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/download/v1.4.1/EyeBreakReminder-Setup-x64.exe",
      "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",1};
    std::atomic_bool cancelled{false};freeSpaceQueries=0;freeSpaceBytes=asset.size+8ull*1024*1024-1;forceFreeSpace=true;
    const auto result=eye::updates::downloadVerified(asset,stage,L"EyeBreakReminder-Setup-x64.exe",cancelled);
    forceFreeSpace=false;
    std::ifstream input(std::filesystem::path(sentinel),std::ios::binary);std::string bytes((std::istreambuf_iterator<char>(input)),{});
    bool ok=true;
    ok&=check(sentinelCreated,"create an isolated prior-install sentinel");
    ok&=check(freeSpaceQueries.load()==1,"low-space preflight queries the staging volume once");
    ok&=check(!result.ok&&!result.cancelled&&result.received==0&&result.error.find("not enough free disk space")!=std::string::npos,"download rejects a volume below payload plus safety margin with a meaningful error");
    ok&=check(GetFileAttributesW(partial.c_str())==INVALID_FILE_ATTRIBUTES&&GetFileAttributesW(final.c_str())==INVALID_FILE_ATTRIBUTES,"low-space rejection creates neither partial nor final payload");
    ok&=check(bytes=="previous installation unchanged","low-space rejection preserves prior application data byte-for-byte");
    DeleteFileW(sentinel.c_str());return ok;
}
bool testStagingAclAndGuid(const std::wstring&root){
    std::wstring staging;
    const bool created=eye::updates::createStagingDirectory(root,staging);
    if(!created)return check(false,"create a unique GUID staging directory beneath an isolated user-profile root");
    const auto leaf=staging.substr(staging.find_last_of(L"\\/")+1);
    GUID parsed{};const bool validGuid=CLSIDFromString(leaf.c_str(),&parsed)==S_OK;
    const bool noReparse=(GetFileAttributesW(staging.c_str())&FILE_ATTRIBUTE_REPARSE_POINT)==0;
    bool ok=true;
    ok&=check(validGuid,"staging path uses a fresh parseable GUID directory name");
    ok&=check(noReparse&&eye::updates::safeStagingDirectory(staging),"staging directory and its parents are regular, non-reparse directories");
    ok&=check(currentUserCanCreateStageFile(staging),"current profile user can create and remove a file in the staging directory");
    ok&=check(assertNoBroadWritableAce(staging),"staging DACL grants no write/delete rights to Everyone, Users, or Authenticated Users");
    const std::wstring source=root+L"\\acl-fixture.bin";
    const std::wstring output=staging+L"\\EyeBreakReminder.exe";
    const bool sourceCreated=writeBytes(source,"abc");
    eye::updates::ReleaseAsset asset{"EyeBreakReminder.exe","https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/download/v1.4.1/EyeBreakReminder.exe",
      "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",3};
    std::atomic_bool cancelled{false};const auto downloaded=eye::updates::downloadVerifiedFixture(asset,source,staging,L"EyeBreakReminder.exe",cancelled);
    ok&=check(sourceCreated&&downloaded.ok&&GetFileAttributesW(output.c_str())!=INVALID_FILE_ATTRIBUTES,"verified payload is staged under the private GUID folder using the fixed application filename");
    DeleteFileW(output.c_str());DeleteFileW(source.c_str());DeleteFileW((staging+L"\\EyeBreakReminder.exe.part").c_str());
    RemoveDirectoryW(staging.c_str());RemoveDirectoryW((root+L"\\updates").c_str());return ok;
}
}

int main(){
    wchar_t profile[MAX_PATH]{};const DWORD length=GetEnvironmentVariableW(L"LOCALAPPDATA",profile,MAX_PATH);
    if(!length||length>=MAX_PATH){std::cerr<<"FAIL: acquire bounded per-user LOCALAPPDATA root\n";return 1;}
    GUID id{};wchar_t guid[40]{};if(FAILED(CoCreateGuid(&id))||!StringFromGUID2(id,guid,40)){std::cerr<<"FAIL: create unique disposable test root name\n";return 1;}
    std::wstring suffix(guid);suffix.erase(std::remove(suffix.begin(),suffix.end(),L'{'),suffix.end());suffix.erase(std::remove(suffix.begin(),suffix.end(),L'}'),suffix.end());
    const std::wstring root=std::wstring(profile)+L"\\EyeBreakReminder-DiskAcl-"+suffix;
    if(!CreateDirectoryW(root.c_str(),nullptr)){std::cerr<<"FAIL: create a fresh disposable test root; refusing to reuse or delete an existing path\n";return 1;}
    bool ok=testLowDiskSpacePreflight(root)&&testStagingAclAndGuid(root);
    RemoveDirectoryW(root.c_str());
    std::cout<<(ok?"PASS: ":"FAIL: ")<<assertions<<" low-space/staging ACL assertions; test-only Win32 disk-space interception was confined to this executable.\n";
    return ok?0:1;
}
