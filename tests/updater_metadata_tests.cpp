#include "../src/update_checker.hpp"
#include <iostream>
#include <string>
#include <vector>

namespace {
int assertions=0;
bool check(bool value,const char*name){++assertions;if(!value)std::cerr<<"FAIL: "<<name<<'\n';return value;}
constexpr const char* repository="https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER";
constexpr const char* sha="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
std::string releaseUrl(const std::string&tag){return std::string(repository)+"/releases/tag/"+tag;}
std::string assetUrl(const std::string&tag,const std::string&name){return std::string(repository)+"/releases/download/"+tag+"/"+name;}
std::string assetJson(const std::string&name,const std::string&url,
                      std::uint64_t size=128,const std::string&digest=sha){
    return "{\"name\":\""+name+"\",\"browser_download_url\":\""+url+"\",\"size\":"+
           std::to_string(size)+",\"digest\":\""+digest+"\"}";
}
std::string releaseJson(const std::string&tag="v1.4.1",bool draft=false,bool prerelease=false,
                        const std::string&url={},const std::string&assets={}){
    const std::string html=url.empty()?releaseUrl(tag):url;
    const std::string packages=assets.empty()?assetJson("EyeBreakReminder-Setup-x64.exe",assetUrl(tag,"EyeBreakReminder-Setup-x64.exe"))+","+
        assetJson("EyeBreakReminder.exe",assetUrl(tag,"EyeBreakReminder.exe")):assets;
    return "{\"tag_name\":\""+tag+"\",\"html_url\":\""+html+
           "\",\"draft\":"+(draft?"true":"false")+",\"prerelease\":"+(prerelease?"true":"false")+
           ",\"body\":\"Release notes\\n\\u2713 verified\",\"assets\":["+packages+"]}";
}
bool failedCheck(const eye::updates::HttpResponse&response,std::string_view installed="1.4.0"){
    return eye::updates::evaluate(response,installed).state==eye::updates::State::Failed;
}
bool manifestTests(){
    using namespace eye::updates;bool ok=true;UpdateManifest manifest;
    manifest.schemaVersion=1;manifest.application=std::string(OfficialApplicationIdentity);manifest.repository=std::string(OfficialRepositoryIdentity);
    manifest.version="1.4.1";manifest.channel="stable";manifest.architecture="x64";manifest.keyId="p256-0123456789abcdef";
    manifest.issuedAt="2026-11-19T11:00:00Z";manifest.expiresAt="2027-01-01T00:00:00Z";
    manifest.assets={{"EyeBreakReminder-Setup-x64.exe","installer","installed","x64",std::string(64,'a'),64},
                     {"EyeBreakReminder.exe","portable-update","portable","x64",std::string(64,'b'),32}};
    const std::string bytes=canonicalManifest(manifest);UpdateManifest parsed;
    ok&=check(!bytes.empty()&&parseCanonicalManifest(bytes,parsed)&&canonicalManifest(parsed)==bytes,"parse and reproduce the exact canonical signed update manifest");
    std::int64_t now=0;ok&=check(manifest_detail::parseDate("2026-11-19T12:00:00Z",now),"accept a canonical UTC manifest timestamp");
    ok&=check(validateManifestFreshness(manifest,now),"accept an unexpired manifest issued within its validity period");
    auto altered=manifest;altered.issuedAt="2026-11-19T12:06:00Z";ok&=check(!validateManifestFreshness(altered,now),"reject a manifest issued too far in the future");
    altered=manifest;altered.expiresAt="2026-11-19T11:59:59Z";ok&=check(!validateManifestFreshness(altered,now),"reject an expired manifest");
    altered=manifest;altered.expiresAt="2027-03-01T00:00:00Z";ok&=check(!validateManifestFreshness(altered,now),"reject a manifest with an excessive validity interval");
    for(const std::string&bad:std::vector<std::string>{"", "{}", bytes+" ", "\xef\xbb\xbf"+bytes,
        bytes.substr(0,bytes.size()-1)+",\"version\":\"9.9.9\"}",
        "{\"schema_version\":1,\"schema_version\":1"+bytes.substr(bytes.find(",\"application\"")),
        bytes.substr(0,bytes.find("\"version\":\"1.4.1\""))+"\"version\":\"1.4.1+build.1\""+bytes.substr(bytes.find("\"channel\"" )-1),
        bytes.substr(0,bytes.find("\"sha256\":\""))+"\"sha256\":\"ABC\""+bytes.substr(bytes.find("\"},",bytes.find("\"sha256\":\""))+2)}){
        ok&=check(!parseCanonicalManifest(bad,parsed),"reject malformed, duplicated, noncanonical, or ambiguous signed manifest fields");
    }
    altered=manifest;altered.schemaVersion=2;ok&=check(canonicalManifest(altered).empty(),"refuse to serialize an unsupported schema version");
    altered=manifest;altered.repository="REMEDIOSSAMUEL/OTHER-REPOSITORY";ok&=check(canonicalManifest(altered).empty(),"refuse to serialize a manifest for another repository");
    altered=manifest;altered.architecture="arm64";ok&=check(canonicalManifest(altered).empty(),"refuse an unsupported architecture");
    altered=manifest;altered.version="1.4.01";ok&=check(canonicalManifest(altered).empty(),"reject an ambiguous leading-zero release version");
    altered=manifest;altered.assets[0].role="portable-update";ok&=check(canonicalManifest(altered).empty(),"reject a substituted or conflicting asset role");
    altered=manifest;altered.assets[0].name="EyeBreakReminder.exe";ok&=check(canonicalManifest(altered).empty(),"reject a substituted installer asset name");
    altered=manifest;altered.assets[0].size=0;ok&=check(canonicalManifest(altered).empty(),"reject a zero-sized signed payload");
    altered=manifest;altered.assets[1].sha256=std::string(63,'b');ok&=check(canonicalManifest(altered).empty(),"reject a truncated signed payload digest");
    altered=manifest;altered.keyId="unknown";ok&=check(canonicalManifest(altered).empty(),"reject an invalid signing key identifier");
    std::int64_t invalidDate=0;ok&=check(!manifest_detail::parseDate("2026-02-29T12:00:00Z",invalidDate),"reject impossible UTC calendar dates");
    return ok;
}
}

int main(){
    using namespace eye::updates;
    bool ok=manifestTests();
    Version parsed;
    ok&=check(detail::parseVersion("v1.4.1",parsed)&&parsed.major==1&&parsed.minor==4&&parsed.patch==1,"parse a tagged stable semantic version");
    ok&=check(detail::parseVersion("1.4.1+windows.x64",parsed)&&parsed.prerelease.empty(),"accept valid build metadata");
    const std::vector<std::string> invalidVersions={"","1","1.2","1.2.3.4","01.2.3","1.02.3","1.2.03","1.2.3-","1.2.3-alpha..1","1.2.3-alpha.01","1.2.3+","1.2.3+one+two","1.2.3-α","18446744073709551616.0.0"};
    for(const auto&value:invalidVersions)ok&=check(!detail::parseVersion(value,parsed),"reject malformed or non-SemVer version text");
    auto less=[](const char*a,const char*b){Version left,right;return detail::parseVersion(a,left)&&detail::parseVersion(b,right)&&detail::compare(left,right)<0;};
    ok&=check(less("1.3.0","1.4.0"),"order an older minor release before current version");
    ok&=check(less("1.9.9","1.10.0"),"compare version components numerically rather than lexically");
    ok&=check(less("1.4.0-alpha","1.4.0-alpha.1"),"order a shorter prerelease identifier sequence first");
    ok&=check(less("1.4.0-alpha.1","1.4.0-alpha.beta"),"order numeric prerelease identifiers before nonnumeric identifiers");
    ok&=check(less("1.4.0-alpha.beta","1.4.0-beta"),"compare prerelease identifiers lexically");
    ok&=check(less("1.4.0-beta.2","1.4.0-beta.11"),"compare numeric prerelease identifiers numerically");
    ok&=check(less("1.4.0-rc.1","1.4.0"),"order every prerelease below the stable release");
    Version buildA,buildB;ok&=check(detail::parseVersion("1.4.1+build.1",buildA)&&detail::parseVersion("1.4.1+build.2",buildB)&&detail::compare(buildA,buildB)==0,"ignore build metadata when comparing versions");

    const HttpResponse stable{200,releaseJson(),Failure::None,0};ReleaseDetails details;
    const auto latest=evaluate(stable,"1.4.0",&details);
    ok&=check(latest.state==State::UpdateAvailable&&latest.latestVersion=="1.4.1","discover a newer stable release and normalize its version");
    ok&=check(details.tag=="v1.4.1"&&details.releaseUrl==releaseUrl("v1.4.1")&&details.assets.size()==2&&details.notes.find("Release notes")!=std::string::npos,"retain validated stable metadata, asset list and release notes");
    ok&=check(evaluate(HttpResponse{200,releaseJson("v1.4.0"),Failure::None,0},"1.4.0").state==State::UpToDate,"treat an equal version as up to date");
    ok&=check(evaluate(HttpResponse{200,releaseJson("v1.3.0"),Failure::None,0},"1.4.0").state==State::InstalledNewer,"never offer an older stable version as an update");
    ok&=check(evaluate(stable,"invalid").state==State::Failed,"reject a missing or invalid installed version");

    const std::vector<Failure> networkFailures={Failure::Offline,Failure::Timeout,Failure::SecureConnection,Failure::Other};
    for(const auto failure:networkFailures)ok&=check(failedCheck(HttpResponse{0,{},failure,12029}),"reject offline, timeout, TLS and other transport failures");
    const std::vector<int> httpFailures={301,302,400,401,403,404,429,500,503};
    for(const auto status:httpFailures)ok&=check(failedCheck(HttpResponse{status,{},Failure::None,0}),"reject authentication, rate-limit, redirect and HTTP error responses");
    ok&=check(failedCheck(HttpResponse{200,{},Failure::None,0}),"reject an empty release response");
    ok&=check(failedCheck(HttpResponse{200,std::string(1024*1024+1,'x'),Failure::None,0}),"reject an oversized release response");
    for(const auto&body:std::vector<std::string>{"not-json","[]","{}",releaseJson()+"trailing",releaseJson("v1.4.1",true),releaseJson("v1.4.1",false,true),releaseJson("v1.4.1-rc.1"),releaseJson("not-a-version"),releaseJson("v1.4.1",false,false,"https://github.com/OTHER-OWNER/OTHER-REPOSITORY/releases/tag/v1.4.1"),releaseJson("v1.4.1",false,false,"http://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/tag/v1.4.1"),releaseJson("v1.4.1",false,false,releaseUrl("v9.9.9")),"{\"tag_name\":\"v1.4.1\",\"tag_name\":\"v1.4.2\",\"html_url\":\""+releaseUrl("v1.4.1")+"\",\"draft\":false,\"prerelease\":false}"})
        ok&=check(failedCheck(HttpResponse{200,body,Failure::None,0}),"reject invalid, draft, prerelease, wrong-repository and ambiguous release metadata");

    auto checkAsset=[&](PackageKind kind,const std::vector<ReleaseAsset>&assets){ReleaseDetails release;release.tag="v1.4.1";release.assets=assets;return selectAsset(release,kind);};
    ReleaseAsset setup{"EyeBreakReminder-Setup-x64.exe",assetUrl("v1.4.1","EyeBreakReminder-Setup-x64.exe"),sha,128};
    ReleaseAsset app{"EyeBreakReminder.exe",assetUrl("v1.4.1","EyeBreakReminder.exe"),sha,128};
    ok&=check(checkAsset(PackageKind::Installed,{setup}).ok,"select the exact x64 setup asset");
    ok&=check(checkAsset(PackageKind::Portable,{app}).ok,"select the exact standalone x64 portable-update asset");
    ok&=check(!checkAsset(PackageKind::Installed,{app}).ok,"reject a missing setup asset and wrong asset name");
    ok&=check(!checkAsset(PackageKind::Portable,{setup}).ok,"reject a setup executable as a portable update");
    ok&=check(!checkAsset(PackageKind::Installed,{{"EyeBreakReminder-Setup-arm64.exe",assetUrl("v1.4.1","EyeBreakReminder-Setup-arm64.exe"),sha,128}}).ok,"reject unsupported ARM64 package assets on an x64-only release");
    ok&=check(!checkAsset(PackageKind::Portable,{app,app}).ok,"reject duplicate portable assets");
    ok&=check(!checkAsset(PackageKind::Installed,{setup,setup}).ok,"reject duplicate installer assets");
    auto mutated=setup;mutated.downloadUrl="https://github.com/OTHER-OWNER/OTHER-REPOSITORY/releases/download/v1.4.1/EyeBreakReminder-Setup-x64.exe";
    ok&=check(!checkAsset(PackageKind::Installed,{mutated}).ok,"reject an asset URL from the wrong repository");
    mutated=setup;mutated.downloadUrl="http://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/download/v1.4.1/EyeBreakReminder-Setup-x64.exe";
    ok&=check(!checkAsset(PackageKind::Installed,{mutated}).ok,"reject an insecure HTTP asset URL");
    mutated=setup;mutated.downloadUrl="https://github.com.evil.invalid/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/download/v1.4.1/EyeBreakReminder-Setup-x64.exe";
    ok&=check(!checkAsset(PackageKind::Installed,{mutated}).ok,"reject a lookalike GitHub asset hostname");
    mutated=setup;mutated.downloadUrl=assetUrl("v9.9.9",setup.name);
    ok&=check(!checkAsset(PackageKind::Installed,{mutated}).ok,"reject a version-mismatched asset path");
    mutated=setup;mutated.size=0;ok&=check(!checkAsset(PackageKind::Installed,{mutated}).ok,"reject an empty update asset");
    mutated=setup;mutated.size=100ull*1024*1024+1;ok&=check(!checkAsset(PackageKind::Installed,{mutated}).ok,"reject an oversized update asset");
    mutated=setup;mutated.digest.clear();ok&=check(!checkAsset(PackageKind::Installed,{mutated}).ok,"reject a missing required SHA-256 digest");
    mutated=setup;mutated.digest="sha1:"+std::string(64,'a');ok&=check(!checkAsset(PackageKind::Installed,{mutated}).ok,"reject an unsupported digest algorithm");
    mutated=setup;mutated.digest="sha256:"+std::string(63,'a');ok&=check(!checkAsset(PackageKind::Installed,{mutated}).ok,"reject a truncated digest");
    mutated=setup;mutated.digest="sha256:"+std::string(65,'a');ok&=check(!checkAsset(PackageKind::Installed,{mutated}).ok,"reject an overlong digest");
    mutated=setup;mutated.digest="sha256:"+std::string(63,'a')+"g";ok&=check(!checkAsset(PackageKind::Installed,{mutated}).ok,"reject malformed nonhexadecimal SHA-256 metadata");
    mutated=setup;mutated.digest="SHA256:"+std::string(64,'a');ok&=check(!checkAsset(PackageKind::Installed,{mutated}).ok,"reject an unrecognized digest metadata prefix");
    mutated=setup;mutated.digest="sha256:"+std::string(64,'A');ok&=check(checkAsset(PackageKind::Installed,{mutated}).ok,"accept case-insensitive hexadecimal digest digits");
    ReleaseDetails prereleaseRelease;prereleaseRelease.tag="v1.4.2-rc.1";prereleaseRelease.assets={setup};
    ok&=check(!selectAsset(prereleaseRelease,PackageKind::Installed).ok,"reject a prerelease installer selection");
    ReleaseDetails malformedRelease;malformedRelease.tag="v01.4.2";malformedRelease.assets={setup};
    ok&=check(!selectAsset(malformedRelease,PackageKind::Installed).ok,"reject an invalid version in asset selection");

    if(!ok)return 1;
    std::cout<<"PASS: "<<assertions<<" release metadata and asset-policy assertions executed.\n";
    return 0;
}
