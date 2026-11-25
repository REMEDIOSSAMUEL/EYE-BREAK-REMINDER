#include "../src/update_client.hpp"
#include <windows.h>
#include <atomic>
#include <filesystem>
#include <iostream>
#include <string>

namespace {
int fail(const std::string&message){std::cerr<<"FAIL: "<<message<<'\n';return 1;}
}

int main(int argc,char**argv){
    const bool preserveLegacySetup=argc==2&&std::string(argv[1])=="--save-v1.3.0-setup";
    const auto response=eye::updates::latestStableReleaseResponse();
    eye::updates::ReleaseDetails release;
    const auto checked=eye::updates::evaluate(response,"1.4.0",&release);
    if(checked.state==eye::updates::State::Failed)return fail("official GitHub API request: "+checked.error);
    if(response.status!=200)return fail("official API did not return HTTP 200");
    if(preserveLegacySetup&&release.tag!="v1.3.0")return fail("requested one-time transition fixture requires the actual public v1.3.0 release");
    if(release.releaseUrl!="https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/tag/"+release.tag)return fail("release identity was not the official Eye Break Reminder repository");
    if(checked.state!=eye::updates::State::InstalledNewer)return fail("the development version should be newer than the current stable v1.3.0 release");
    const auto installed=eye::updates::selectAsset(release,eye::updates::PackageKind::Installed);
    const auto portable=eye::updates::selectAsset(release,eye::updates::PackageKind::Portable);
    if(!installed.ok)return fail("official setup asset: "+installed.error);
    if(!portable.ok)return fail("official portable executable asset: "+portable.error);

    const std::filesystem::path base=std::filesystem::current_path()/"build"/"github-updater-smoke";
    if(!CreateDirectoryW(base.c_str(),nullptr))return fail("isolated smoke folder must be new; refusing to reuse or remove existing files");
    const std::wstring stage=base.wstring();
    if(!eye::updates::safeStagingDirectory(stage)){RemoveDirectoryW(stage.c_str());return fail("isolated smoke folder contains a reparse point or unsafe path");}
    std::atomic_bool cancelled{false};
    auto verify=[&](const eye::updates::ReleaseAsset&asset,const wchar_t*fileName,bool keepSetup=false){
        std::uint64_t lastPercent=UINT64_MAX;bool verifying=false;
        const auto result=eye::updates::downloadVerified(asset,stage,fileName,cancelled,[&](eye::updates::DownloadProgress progress){
            if(progress.verifying){verifying=true;return;}if(!progress.total)return;const auto percent=progress.received*100/progress.total;if(percent/10!=lastPercent/10){lastPercent=percent;std::cout<<asset.name<<" progress="<<percent<<"% bytes="<<progress.received<<"/"<<progress.total<<'\n';}
        });
        if(!result.ok){std::cerr<<"FAIL: "<<asset.name<<" download: "<<result.error<<'\n';return false;}
        if(result.received!=asset.size||result.sha256!=eye::updates::client_detail::lower(asset.digest.substr(7))||!verifying){std::cerr<<"FAIL: "<<asset.name<<" size, SHA-256, or verification phase mismatch\n";return false;}
        std::cout<<"PASS: "<<asset.name<<" bytes="<<result.received<<" sha256="<<result.sha256<<" verified=true\n";
        if(keepSetup){const std::filesystem::path saved=std::filesystem::current_path()/"build"/"gui-test"/"public-v1.3.0-setup.exe";if(GetFileAttributesW(saved.c_str())!=INVALID_FILE_ATTRIBUTES||!CopyFileW((stage+L"\\"+fileName).c_str(),saved.c_str(),TRUE)){std::cerr<<"FAIL: could not retain the verified public v1.3.0 installer for isolated upgrade acceptance\n";return false;}std::cout<<"PASS: retained verified public v1.3.0 installer at "<<saved.string()<<"\n";}
        return DeleteFileW((stage+L"\\"+fileName).c_str())!=FALSE;
    };
    const bool setupOk=verify(installed.asset,L"EyeBreakReminder-Setup-x64.exe",preserveLegacySetup);
    const bool portableOk=setupOk&&verify(portable.asset,L"EyeBreakReminder.exe");
    const bool removed=RemoveDirectoryW(stage.c_str())!=FALSE;
    if(!setupOk||!portableOk||!removed)return fail("a verified release download or isolated-file cleanup failed");
    std::cout<<"PASS: anonymous official GitHub API and release-asset downloads; tag="<<release.tag<<" current=1.4.0 state=installed-newer\n";
    return 0;
}
