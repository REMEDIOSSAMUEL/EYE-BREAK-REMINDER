#pragma once

#include <algorithm>
#include <charconv>
#include <cstdint>
#include <limits>
#include <string>
#include <string_view>
#include <vector>

namespace eye::updates {

struct Version {
    std::uint64_t major=0, minor=0, patch=0;
    std::vector<std::string> prerelease;
    std::string normalized;
};

struct ReleaseAsset {
    std::string name, downloadUrl, digest;
    std::uint64_t size=0;
};

struct ReleaseDetails {
    std::string tag, releaseUrl, notes;
    bool draft=false, prerelease=false;
    std::vector<ReleaseAsset> assets;
};

namespace detail {
inline bool digits(std::string_view text) {
    return !text.empty() && std::all_of(text.begin(),text.end(),[](char c){return c>='0'&&c<='9';});
}
inline bool identifierCharacter(char c) {
    return (c>='0'&&c<='9')||(c>='A'&&c<='Z')||(c>='a'&&c<='z')||c=='-';
}
inline bool parseCoreNumber(std::string_view text,std::uint64_t&value) {
    if(!digits(text)||(text.size()>1&&text.front()=='0'))return false;
    const auto result=std::from_chars(text.data(),text.data()+text.size(),value);
    return result.ec==std::errc{}&&result.ptr==text.data()+text.size();
}
inline bool validIdentifiers(std::string_view text,bool rejectNumericLeadingZeroes) {
    if(text.empty())return false;
    std::size_t start=0;
    while(start<=text.size()){
        const auto end=text.find('.',start);
        const auto part=text.substr(start,end==std::string_view::npos?text.size()-start:end-start);
        if(part.empty()||!std::all_of(part.begin(),part.end(),identifierCharacter))return false;
        if(rejectNumericLeadingZeroes&&digits(part)&&part.size()>1&&part.front()=='0')return false;
        if(end==std::string_view::npos)break;
        start=end+1;
    }
    return true;
}
inline bool parseVersion(std::string_view text,Version&out) {
    if(!text.empty()&&text.front()=='v')text.remove_prefix(1);
    if(text.empty())return false;
    std::string_view withoutBuild=text;
    const auto plus=text.find('+');
    if(plus!=std::string_view::npos){
        if(text.find('+',plus+1)!=std::string_view::npos||!validIdentifiers(text.substr(plus+1),false))return false;
        withoutBuild=text.substr(0,plus);
    }
    std::string_view core=withoutBuild;
    std::vector<std::string> prerelease;
    const auto dash=withoutBuild.find('-');
    if(dash!=std::string_view::npos){
        core=withoutBuild.substr(0,dash);
        const auto suffix=withoutBuild.substr(dash+1);
        if(!validIdentifiers(suffix,true))return false;
        std::size_t start=0;
        while(start<=suffix.size()){
            const auto end=suffix.find('.',start);
            prerelease.emplace_back(suffix.substr(start,end==std::string_view::npos?suffix.size()-start:end-start));
            if(end==std::string_view::npos)break;
            start=end+1;
        }
    }
    const auto first=core.find('.');
    if(first==std::string_view::npos)return false;
    const auto second=core.find('.',first+1);
    if(second==std::string_view::npos||core.find('.',second+1)!=std::string_view::npos)return false;
    Version parsed;
    if(!parseCoreNumber(core.substr(0,first),parsed.major)||
       !parseCoreNumber(core.substr(first+1,second-first-1),parsed.minor)||
       !parseCoreNumber(core.substr(second+1),parsed.patch))return false;
    parsed.prerelease=std::move(prerelease);
    const auto normalized=text;
    parsed.normalized.assign(normalized);
    out=std::move(parsed);
    return true;
}
inline int compareIdentifier(const std::string&a,const std::string&b) {
    const bool aNumeric=digits(a),bNumeric=digits(b);
    if(aNumeric&&bNumeric){
        if(a.size()!=b.size())return a.size()<b.size()?-1:1;
        if(a==b)return 0;
        return a<b?-1:1;
    }
    if(aNumeric!=bNumeric)return aNumeric?-1:1;
    if(a==b)return 0;
    return a<b?-1:1;
}
inline int compare(const Version&a,const Version&b) {
    if(a.major!=b.major)return a.major<b.major?-1:1;
    if(a.minor!=b.minor)return a.minor<b.minor?-1:1;
    if(a.patch!=b.patch)return a.patch<b.patch?-1:1;
    if(a.prerelease.empty()!=b.prerelease.empty())return a.prerelease.empty()?1:-1;
    for(std::size_t i=0;i<std::min(a.prerelease.size(),b.prerelease.size());++i){
        const int order=compareIdentifier(a.prerelease[i],b.prerelease[i]);
        if(order)return order;
    }
    if(a.prerelease.size()==b.prerelease.size())return 0;
    return a.prerelease.size()<b.prerelease.size()?-1:1;
}

inline void appendUtf8(std::string&out,std::uint32_t cp) {
    if(cp<=0x7f)out.push_back(char(cp));
    else if(cp<=0x7ff){out.push_back(char(0xc0|(cp>>6)));out.push_back(char(0x80|(cp&0x3f)));}
    else if(cp<=0xffff){out.push_back(char(0xe0|(cp>>12)));out.push_back(char(0x80|((cp>>6)&0x3f)));out.push_back(char(0x80|(cp&0x3f)));}
    else {out.push_back(char(0xf0|(cp>>18)));out.push_back(char(0x80|((cp>>12)&0x3f)));out.push_back(char(0x80|((cp>>6)&0x3f)));out.push_back(char(0x80|(cp&0x3f)));}
}

class JsonReader {
    std::string_view input;
    std::size_t at=0;
    void whitespace(){while(at<input.size()&&(input[at]==' '||input[at]=='\t'||input[at]=='\r'||input[at]=='\n'))++at;}
    bool unicodeUnit(std::uint32_t&cp){
        if(at+4>input.size())return false;
        cp=0;
        for(int i=0;i<4;++i){char c=input[at++];cp<<=4;if(c>='0'&&c<='9')cp|=std::uint32_t(c-'0');else if(c>='a'&&c<='f')cp|=std::uint32_t(c-'a'+10);else if(c>='A'&&c<='F')cp|=std::uint32_t(c-'A'+10);else return false;}
        return true;
    }
    bool string(std::string&out){
        whitespace();if(at>=input.size()||input[at++]!='"')return false;
        out.clear();
        while(at<input.size()){
            unsigned char c=static_cast<unsigned char>(input[at++]);
            if(c=='"')return true;
            if(c<0x20)return false;
            if(c!='\\'){out.push_back(char(c));continue;}
            if(at>=input.size())return false;
            switch(input[at++]){
                case '"':out.push_back('"');break;case '\\':out.push_back('\\');break;case '/':out.push_back('/');break;
                case 'b':out.push_back('\b');break;case 'f':out.push_back('\f');break;case 'n':out.push_back('\n');break;
                case 'r':out.push_back('\r');break;case 't':out.push_back('\t');break;
                case 'u':{
                    std::uint32_t cp=0;if(!unicodeUnit(cp))return false;
                    if(cp>=0xd800&&cp<=0xdbff){
                        if(at+2>input.size()||input[at++]!='\\'||input[at++]!='u')return false;
                        std::uint32_t low=0;if(!unicodeUnit(low)||low<0xdc00||low>0xdfff)return false;
                        cp=0x10000+((cp-0xd800)<<10)+(low-0xdc00);
                    }else if(cp>=0xdc00&&cp<=0xdfff)return false;
                    appendUtf8(out,cp);break;
                }
                default:return false;
            }
        }
        return false;
    }
    bool number(){
        whitespace();const std::size_t start=at;
        if(at<input.size()&&input[at]=='-')++at;
        if(at>=input.size())return false;
        if(input[at]=='0')++at;
        else {if(input[at]<'1'||input[at]>'9')return false;while(at<input.size()&&input[at]>='0'&&input[at]<='9')++at;}
        if(at<input.size()&&input[at]=='.'){++at;std::size_t digitsAt=at;while(at<input.size()&&input[at]>='0'&&input[at]<='9')++at;if(at==digitsAt)return false;}
        if(at<input.size()&&(input[at]=='e'||input[at]=='E')){++at;if(at<input.size()&&(input[at]=='+'||input[at]=='-'))++at;std::size_t digitsAt=at;while(at<input.size()&&input[at]>='0'&&input[at]<='9')++at;if(at==digitsAt)return false;}
        return at>start;
    }
    bool unsignedInteger(std::uint64_t&out){
        whitespace();const std::size_t start=at;
        if(at>=input.size()||input[at]<'0'||input[at]>'9')return false;
        if(input[at]=='0')++at;else while(at<input.size()&&input[at]>='0'&&input[at]<='9')++at;
        const auto parsed=std::from_chars(input.data()+start,input.data()+at,out);
        return parsed.ec==std::errc{}&&parsed.ptr==input.data()+at;
    }
    bool nullableString(std::string&out){
        whitespace();if(input.substr(at,4)=="null"){at+=4;out.clear();return true;}return string(out);
    }
    bool literal(std::string_view value){whitespace();if(input.substr(at,value.size())!=value)return false;at+=value.size();return true;}
    bool value(unsigned depth){
        whitespace();if(depth>32||at>=input.size())return false;
        if(input[at]=='"'){std::string ignored;return string(ignored);}
        if(input[at]=='{'){
            ++at;whitespace();if(at<input.size()&&input[at]=='}'){++at;return true;}
            for(;;){std::string key;if(!string(key))return false;whitespace();if(at>=input.size()||input[at++]!=':')return false;if(!value(depth+1))return false;whitespace();if(at>=input.size())return false;if(input[at++]=='}')return true;if(input[at-1]!=',')return false;}
        }
        if(input[at]=='['){
            ++at;whitespace();if(at<input.size()&&input[at]==']'){++at;return true;}
            for(;;){if(!value(depth+1))return false;whitespace();if(at>=input.size())return false;if(input[at++]==']')return true;if(input[at-1]!=',')return false;}
        }
        if(input[at]=='t')return literal("true");
        if(input[at]=='f')return literal("false");
        if(input[at]=='n')return literal("null");
        return number();
    }
    bool asset(ReleaseAsset&out){
        whitespace();if(at>=input.size()||input[at++]!='{')return false;
        bool hasName=false,hasUrl=false,hasSize=false,hasDigest=false;
        whitespace();if(at<input.size()&&input[at]=='}')return false;
        for(;;){
            std::string key;if(!string(key))return false;whitespace();if(at>=input.size()||input[at++]!=':')return false;
            if(key=="name"){if(hasName||!string(out.name))return false;hasName=true;}
            else if(key=="browser_download_url"){if(hasUrl||!string(out.downloadUrl))return false;hasUrl=true;}
            else if(key=="size"){if(hasSize||!unsignedInteger(out.size))return false;hasSize=true;}
            else if(key=="digest"){if(hasDigest||!nullableString(out.digest))return false;hasDigest=true;}
            else if(!value(1))return false;
            whitespace();if(at>=input.size())return false;
            const char separator=input[at++];if(separator=='}')break;if(separator!=',')return false;
        }
        return hasName&&hasUrl&&hasSize;
    }
    bool assetArray(std::vector<ReleaseAsset>&out){
        whitespace();if(at>=input.size()||input[at++]!='[')return false;
        whitespace();if(at<input.size()&&input[at]==']'){++at;return true;}
        for(;;){if(out.size()>=256)return false;ReleaseAsset item;if(!asset(item))return false;out.push_back(std::move(item));whitespace();if(at>=input.size())return false;const char separator=input[at++];if(separator==']')return true;if(separator!=',')return false;}
    }
public:
    explicit JsonReader(std::string_view text):input(text){}
    bool release(std::string&tag,std::string&url,bool&draft,bool&prerelease,
                 std::vector<ReleaseAsset>*assets=nullptr,std::string*notes=nullptr){
        whitespace();if(at>=input.size()||input[at++]!='{')return false;
        bool hasTag=false,hasUrl=false,hasDraft=false,hasPrerelease=false,hasAssets=false,hasNotes=false;
        whitespace();if(at<input.size()&&input[at]=='}')return false;
        for(;;){
            std::string key;if(!string(key))return false;whitespace();if(at>=input.size()||input[at++]!=':')return false;
            if(key=="tag_name") {if(hasTag||!string(tag))return false;hasTag=true;}
            else if(key=="html_url") {if(hasUrl||!string(url))return false;hasUrl=true;}
            else if(key=="assets") {if(hasAssets)return false;std::vector<ReleaseAsset> parsed;if(!assetArray(parsed))return false;if(assets)*assets=std::move(parsed);hasAssets=true;}
            else if(key=="body") {std::string parsed;if(hasNotes||!nullableString(parsed))return false;if(notes)*notes=std::move(parsed);hasNotes=true;}
            else if(key=="draft"||key=="prerelease"){
                whitespace();bool parsed=false;
                if(input.substr(at,4)=="true"){parsed=true;at+=4;}
                else if(input.substr(at,5)=="false"){parsed=false;at+=5;}
                else return false;
                if(key=="draft"){if(hasDraft)return false;draft=parsed;hasDraft=true;}
                else {if(hasPrerelease)return false;prerelease=parsed;hasPrerelease=true;}
            }else if(!value(0))return false;
            whitespace();if(at>=input.size())return false;
            const char separator=input[at++];if(separator=='}')break;if(separator!=',')return false;
        }
        whitespace();return at==input.size()&&hasTag&&hasUrl&&hasDraft&&hasPrerelease;
    }
};
} // namespace detail

enum class Failure { None, Offline, Timeout, SecureConnection, Other };
struct HttpResponse { int status=0; std::string body; Failure failure=Failure::None; unsigned long errorCode=0; };
enum class State { UpToDate, UpdateAvailable, InstalledNewer, Failed };
struct CheckResult { State state=State::Failed; std::string latestVersion, releaseUrl, error; };

inline CheckResult evaluate(const HttpResponse&response,std::string_view installedVersion,ReleaseDetails*details=nullptr){
    CheckResult result;
    Version installed;
    if(!detail::parseVersion(installedVersion,installed)){result.error="Installed version information is missing or invalid.";return result;}
    if(response.failure!=Failure::None){
        switch(response.failure){
            case Failure::Offline:result.error="Could not reach GitHub. Check your internet connection.";break;
            case Failure::Timeout:result.error="The update check timed out. Try again later.";break;
            case Failure::SecureConnection:result.error="A secure connection to GitHub could not be verified.";break;
            case Failure::Other:result.error="The update request failed (Windows network error "+std::to_string(response.errorCode)+").";break;
            case Failure::None:break;
        }
        return result;
    }
    if(response.status==403||response.status==429){result.error="GitHub's rate limit was reached. Try again later.";return result;}
    if(response.status==401){result.error="GitHub requires authentication. This checker does not store or send credentials.";return result;}
    if(response.status==404){result.error="No public stable release was found. Private repositories cannot be checked without authentication.";return result;}
    if(response.status!=200){
        result.error=response.status>=500?"GitHub is temporarily unavailable (HTTP "+std::to_string(response.status)+"). Try again later.":"GitHub returned HTTP "+std::to_string(response.status)+".";
        return result;
    }
    if(response.body.empty()||response.body.size()>1024*1024){result.error="GitHub returned an empty or oversized response.";return result;}
    std::string tag,url;bool draft=false,prerelease=false;
    detail::JsonReader reader(response.body);
    std::vector<ReleaseAsset> assets;std::string notes;
    if(!reader.release(tag,url,draft,prerelease,details?&assets:nullptr,details?&notes:nullptr)){result.error="GitHub returned release information that could not be read.";return result;}
    if(draft||prerelease){result.error="The response was not a published stable release.";return result;}
    Version latest;
    if(!detail::parseVersion(tag,latest)||!latest.prerelease.empty()){result.error="The latest stable release has an invalid or prerelease version tag.";return result;}
    constexpr std::string_view official="https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/tag/";
    if(url!=std::string(official)+tag||
       !std::all_of(url.begin(),url.end(),[](unsigned char c){return c>=0x21&&c<=0x7e&&c!='\\'&&c!='"'&&c!='<';})){
        result.error="GitHub returned a release link outside the official Eye Break Reminder repository.";return result;
    }
    result.latestVersion=latest.normalized;result.releaseUrl=url;
    const int order=detail::compare(latest,installed);
    result.state=order>0?State::UpdateAvailable:order<0?State::InstalledNewer:State::UpToDate;
    if(details){details->tag=tag;details->releaseUrl=url;details->notes=std::move(notes);details->draft=draft;details->prerelease=prerelease;details->assets=std::move(assets);}
    return result;
}

enum class PackageKind { Installed, Portable };
struct SelectedAsset { bool ok=false;ReleaseAsset asset;std::string error; };
inline SelectedAsset selectAsset(const ReleaseDetails&release,PackageKind kind){
    SelectedAsset selected;const std::string expected=kind==PackageKind::Installed?"EyeBreakReminder-Setup-x64.exe":"EyeBreakReminder.exe";
    const ReleaseAsset*match=nullptr;unsigned matches=0;
    for(const auto&asset:release.assets)if(asset.name==expected){match=&asset;++matches;}
    if(matches!=1){selected.error=matches?"GitHub returned duplicate update assets.":"The official release is missing the supported Windows x64 update asset.";return selected;}
    if(match->size==0||match->size>100ull*1024*1024){selected.error="The update asset has an invalid or unsupported size.";return selected;}
    const std::string expectedUrl="https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/download/"+release.tag+"/"+expected;
    Version parsedTag;
    if(match->downloadUrl!=expectedUrl||!detail::parseVersion(release.tag,parsedTag)||!parsedTag.prerelease.empty()) {selected.error="GitHub returned an update asset outside the official repository.";return selected;}
    constexpr std::string_view prefix="sha256:";
    if(match->digest.size()!=prefix.size()+64||match->digest.compare(0,prefix.size(),prefix)!=0||
       !std::all_of(match->digest.begin()+std::ptrdiff_t(prefix.size()),match->digest.end(),[](unsigned char c){return (c>='0'&&c<='9')||(c>='a'&&c<='f')||(c>='A'&&c<='F');})){
        selected.error="GitHub did not provide a usable SHA-256 digest for the update asset.";return selected;
    }
    selected.ok=true;selected.asset=*match;return selected;
}

} // namespace eye::updates
