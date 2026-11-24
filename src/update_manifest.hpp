#pragma once

#include <algorithm>
#include <climits>
#include <cstdint>
#include <ctime>
#include <limits>
#include <string>
#include <string_view>
#include <vector>

namespace eye::updates {

struct ManifestAsset {
    std::string name, role, installationType, architecture, sha256;
    std::uint64_t size=0;
};

struct UpdateManifest {
    unsigned schemaVersion=0;
    std::string application, repository, version, channel, architecture, keyId, issuedAt, expiresAt;
    std::vector<ManifestAsset> assets;
};

struct TrustedPublicKey {
    std::string keyId;
    std::vector<unsigned char> p256Point; // SEC1 uncompressed point contents X || Y, 32 bytes each.
};

inline constexpr std::string_view UpdateManifestName="EyeBreakReminder-UpdateManifest.json";
inline constexpr std::string_view UpdateManifestSignatureName="EyeBreakReminder-UpdateManifest.sig";
inline constexpr std::string_view OfficialApplicationIdentity="Eye Break Reminder";
inline constexpr std::string_view OfficialRepositoryIdentity="REMEDIOSSAMUEL/EYE-BREAK-REMINDER";

namespace manifest_detail {
inline bool lowerHex(std::string_view text,std::size_t length){
    return text.size()==length&&std::all_of(text.begin(),text.end(),[](char c){return(c>='0'&&c<='9')||(c>='a'&&c<='f');});
}
inline bool safeKeyId(std::string_view value){
    return value.size()==21&&value.substr(0,5)=="p256-"&&lowerHex(value.substr(5),16);
}
inline bool stableVersion(std::string_view value){
    unsigned components=0;std::size_t start=0;
    while(start<=value.size()){
        const auto end=value.find('.',start);const auto part=value.substr(start,end==std::string_view::npos?value.size()-start:end-start);
        if(part.empty()||(part.size()>1&&part.front()=='0')||!std::all_of(part.begin(),part.end(),[](char c){return c>='0'&&c<='9';}))return false;
        std::uint64_t parsed=0;for(char c:part){if(parsed>(UINT64_MAX-std::uint64_t(c-'0'))/10)return false;parsed=parsed*10+std::uint64_t(c-'0');}
        ++components;if(end==std::string_view::npos)break;start=end+1;
    }
    return components==3;
}
inline bool validDateText(std::string_view value){
    if(value.size()!=20||value[4]!='-'||value[7]!='-'||value[10]!='T'||value[13]!=':'||value[16]!=':'||value[19]!='Z')return false;
    for(std::size_t i=0;i<value.size();++i)if(i!=4&&i!=7&&i!=10&&i!=13&&i!=16&&i!=19&&(value[i]<'0'||value[i]>'9'))return false;
    return true;
}
inline bool parseDate(std::string_view value,std::int64_t&seconds){
    if(!validDateText(value))return false;
    auto number=[&](std::size_t at,std::size_t length){int result=0;for(std::size_t i=0;i<length;++i)result=result*10+value[at+i]-'0';return result;};
    const int year=number(0,4),month=number(5,2),day=number(8,2),hour=number(11,2),minute=number(14,2),second=number(17,2);
    if(year<2020||month<1||month>12||hour>23||minute>59||second>59)return false;
    const bool leap=(year%4==0&&year%100!=0)||year%400==0;
    const int daysInMonth[]={31,leap?29:28,31,30,31,30,31,31,30,31,30,31};
    if(day<1||day>daysInMonth[month-1])return false;
    int adjustedYear=year-(month<=2);const int era=(adjustedYear>=0?adjustedYear:adjustedYear-399)/400;
    const unsigned yearOfEra=unsigned(adjustedYear-era*400);const unsigned shiftedMonth=unsigned(month+(month>2?-3:9));
    const unsigned dayOfYear=(153*shiftedMonth+2)/5+unsigned(day)-1;
    const unsigned dayOfEra=yearOfEra*365+yearOfEra/4-yearOfEra/100+dayOfYear;
    const std::int64_t days=std::int64_t(era)*146097+std::int64_t(dayOfEra)-719468;
    seconds=days*86400+hour*3600+minute*60+second;return true;
}
inline bool validAssets(const std::vector<ManifestAsset>&assets){
    if(assets.size()!=2)return false;
    const auto&setup=assets[0];const auto&portable=assets[1];
    auto valid=[](const ManifestAsset&a){return a.architecture=="x64"&&a.size>0&&a.size<=100ull*1024*1024&&lowerHex(a.sha256,64);};
    return setup.name=="EyeBreakReminder-Setup-x64.exe"&&setup.role=="installer"&&setup.installationType=="installed"&&valid(setup)&&
           portable.name=="EyeBreakReminder.exe"&&portable.role=="portable-update"&&portable.installationType=="portable"&&valid(portable);
}
inline bool validShape(const UpdateManifest&m){
    return m.schemaVersion==1&&m.application==OfficialApplicationIdentity&&m.repository==OfficialRepositoryIdentity&&stableVersion(m.version)&&
           m.channel=="stable"&&m.architecture=="x64"&&safeKeyId(m.keyId)&&validDateText(m.issuedAt)&&validDateText(m.expiresAt)&&validAssets(m.assets);
}
} // namespace manifest_detail

class CanonicalReader {
    std::string_view text;std::size_t at=0;
    bool literal(std::string_view expected){if(text.substr(at,expected.size())!=expected)return false;at+=expected.size();return true;}
    bool quoted(std::string&out){
        if(at>=text.size()||text[at++]!='"')return false;
        out.clear();
        while(at<text.size()){
            const unsigned char c=static_cast<unsigned char>(text[at++]);if(c=='"')return true;
            if(c<' '||c>'~'||c=='\\')return false;
            out.push_back(char(c));
        }
        return false;
    }
    bool uintValue(std::uint64_t&out){
        if(at>=text.size()||text[at]<'0'||text[at]>'9')return false;
        const auto start=at;
        if(text[at]=='0')++at;else while(at<text.size()&&text[at]>='0'&&text[at]<='9')++at;
        const auto digits=text.substr(start,at-start);std::uint64_t value=0;
        for(char c:digits){if(value>(UINT64_MAX-std::uint64_t(c-'0'))/10)return false;value=value*10+std::uint64_t(c-'0');}
        out=value;return true;
    }
    bool field(std::string_view name,std::string&out){return literal("\"")&&literal(name)&&literal("\":")&&quoted(out);}
    bool asset(ManifestAsset&out){
        std::uint64_t size=0;
        if(!literal("{\"name\":")||!quoted(out.name)||!literal(",\"role\":")||!quoted(out.role)||
           !literal(",\"installation_type\":")||!quoted(out.installationType)||!literal(",\"architecture\":")||!quoted(out.architecture)||
           !literal(",\"size\":")||!uintValue(size)||!literal(",\"sha256\":")||!quoted(out.sha256)||!literal("}"))return false;
        out.size=size;return true;
    }
public:
    explicit CanonicalReader(std::string_view value):text(value){}
    bool parse(UpdateManifest&out){
        std::uint64_t schema=0;
        if(!literal("{\"schema_version\":")||!uintValue(schema)||schema>UINT_MAX||!literal(",")||
           !field("application",out.application)||!literal(",")||!field("repository",out.repository)||!literal(",")||
           !field("version",out.version)||!literal(",")||!field("channel",out.channel)||!literal(",")||
           !field("architecture",out.architecture)||!literal(",")||!field("key_id",out.keyId)||!literal(",")||
           !field("issued_at",out.issuedAt)||!literal(",")||!field("expires_at",out.expiresAt)||!literal(",\"assets\":["))return false;
        ManifestAsset first,second;if(!asset(first)||!literal(",")||!asset(second)||!literal("]}"))return false;
        if(at!=text.size())return false;
        out.schemaVersion=unsigned(schema);out.assets={std::move(first),std::move(second)};
        return manifest_detail::validShape(out)&&serialize(out)==text;
    }
    static std::string serialize(const UpdateManifest&m){
        if(!manifest_detail::validShape(m))return{};
        auto quote=[](const std::string&v){return std::string("\"")+v+"\"";};
        auto assetText=[&](const ManifestAsset&a){return std::string("{\"name\":")+quote(a.name)+",\"role\":"+quote(a.role)+",\"installation_type\":"+quote(a.installationType)+",\"architecture\":"+quote(a.architecture)+",\"size\":"+std::to_string(a.size)+",\"sha256\":"+quote(a.sha256)+"}";};
        return std::string("{\"schema_version\":1,\"application\":")+quote(m.application)+",\"repository\":"+quote(m.repository)+",\"version\":"+quote(m.version)+",\"channel\":"+quote(m.channel)+",\"architecture\":"+quote(m.architecture)+",\"key_id\":"+quote(m.keyId)+",\"issued_at\":"+quote(m.issuedAt)+",\"expires_at\":"+quote(m.expiresAt)+",\"assets\":["+assetText(m.assets[0])+","+assetText(m.assets[1])+"]}";
    }
};

inline std::string canonicalManifest(const UpdateManifest&m){return CanonicalReader::serialize(m);}
inline bool parseCanonicalManifest(std::string_view bytes,UpdateManifest&out){
    if(bytes.empty()||bytes.size()>16384||bytes.find('\0')!=std::string_view::npos)return false;
    CanonicalReader reader(bytes);return reader.parse(out);
}

enum class ManifestUse { Install, Recover };

inline bool validateManifestFreshness(const UpdateManifest&m,std::int64_t now,ManifestUse use=ManifestUse::Install){
    std::int64_t issued=0,expires=0;
    return manifest_detail::parseDate(m.issuedAt,issued)&&manifest_detail::parseDate(m.expiresAt,expires)&&
           issued<=now+300&&(use==ManifestUse::Recover||expires>now)&&expires>issued&&expires-issued<=90ll*24*60*60;
}

inline const ManifestAsset* manifestAsset(const UpdateManifest&m,bool installed){
    if(!manifest_detail::validAssets(m.assets))return nullptr;
    return &m.assets[installed?0:1];
}

} // namespace eye::updates
