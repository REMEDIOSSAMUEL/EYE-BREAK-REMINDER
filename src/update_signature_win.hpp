#pragma once

#include "update_checker.hpp"
#include "update_trust.hpp"
#include <windows.h>
#include <bcrypt.h>
#include <algorithm>
#include <array>
#include <climits>
#include <string>
#include <vector>

namespace eye::updates {
namespace signature_detail {

struct AlgorithmHandle {
    BCRYPT_ALG_HANDLE value{};
    ~AlgorithmHandle(){if(value)BCryptCloseAlgorithmProvider(value,0);}
    AlgorithmHandle(const AlgorithmHandle&)=delete;AlgorithmHandle&operator=(const AlgorithmHandle&)=delete;
    AlgorithmHandle()=default;
};
struct KeyHandle {
    BCRYPT_KEY_HANDLE value{};
    ~KeyHandle(){if(value)BCryptDestroyKey(value);}
    KeyHandle(const KeyHandle&)=delete;KeyHandle&operator=(const KeyHandle&)=delete;
    KeyHandle()=default;
};
struct HashHandle {
    BCRYPT_HASH_HANDLE value{};
    ~HashHandle(){if(value)BCryptDestroyHash(value);}
    HashHandle(const HashHandle&)=delete;HashHandle&operator=(const HashHandle&)=delete;
    HashHandle()=default;
};

inline bool sha256(std::string_view bytes,std::array<unsigned char,32>&digest){
    AlgorithmHandle algorithm;if(BCryptOpenAlgorithmProvider(&algorithm.value,BCRYPT_SHA256_ALGORITHM,nullptr,0)<0)return false;
    DWORD objectLength=0,got=0;if(BCryptGetProperty(algorithm.value,BCRYPT_OBJECT_LENGTH,reinterpret_cast<PUCHAR>(&objectLength),sizeof(objectLength),&got,0)<0||!objectLength)return false;
    std::vector<unsigned char>object(objectLength);HashHandle hash;
    if(BCryptCreateHash(algorithm.value,&hash.value,object.data(),objectLength,nullptr,0,0)<0)return false;
    std::size_t offset=0;while(offset<bytes.size()){
        const auto amount=static_cast<ULONG>(std::min<std::size_t>(bytes.size()-offset,ULONG_MAX));
        if(BCryptHashData(hash.value,reinterpret_cast<PUCHAR>(const_cast<char*>(bytes.data()+offset)),amount,0)<0)return false;
        offset+=amount;
    }
    return BCryptFinishHash(hash.value,digest.data(),static_cast<ULONG>(digest.size()),0)>=0;
}
inline std::string hex(const unsigned char*bytes,std::size_t size){
    static constexpr char digits[]="0123456789abcdef";std::string value;value.reserve(size*2);
    for(std::size_t i=0;i<size;++i){value.push_back(digits[bytes[i]>>4]);value.push_back(digits[bytes[i]&15]);}return value;
}
inline bool keyIdForPoint(const std::vector<unsigned char>&point,std::string&out){
    if(point.size()!=64)return false;
    std::array<unsigned char,32>digest{};
    const std::string_view bytes(reinterpret_cast<const char*>(point.data()),point.size());if(!sha256(bytes,digest))return false;
    out="p256-"+hex(digest.data(),8);return true;
}
inline bool importPublicKey(const std::vector<unsigned char>&point,BCRYPT_KEY_HANDLE&key){
    if(point.size()!=64)return false;
    struct PublicBlob {BCRYPT_ECCKEY_BLOB header;unsigned char coordinates[64];} blob{};
    blob.header.dwMagic=BCRYPT_ECDSA_PUBLIC_P256_MAGIC;blob.header.cbKey=32;std::copy(point.begin(),point.end(),blob.coordinates);
    AlgorithmHandle algorithm;if(BCryptOpenAlgorithmProvider(&algorithm.value,BCRYPT_ECDSA_P256_ALGORITHM,nullptr,0)<0)return false;
    return BCryptImportKeyPair(algorithm.value,nullptr,BCRYPT_ECCPUBLIC_BLOB,&key,reinterpret_cast<PUCHAR>(&blob),sizeof(blob),0)>=0;
}
inline bool verifyP256Sha256(const std::vector<unsigned char>&point,std::string_view message,std::string_view signature){
    if(point.size()!=64||signature.size()!=64)return false;
    std::array<unsigned char,32>digest{};if(!sha256(message,digest))return false;
    BCRYPT_KEY_HANDLE rawKey{};if(!importPublicKey(point,rawKey))return false;KeyHandle key;key.value=rawKey;
    return BCryptVerifySignature(key.value,nullptr,digest.data(),static_cast<ULONG>(digest.size()),
        reinterpret_cast<PUCHAR>(const_cast<char*>(signature.data())),static_cast<ULONG>(signature.size()),0)>=0;
}
} // namespace signature_detail

inline bool verifyManifestSignature(std::string_view manifest,std::string_view signature,const TrustedPublicKey&key){
    std::string computedId;
    return manifest_detail::safeKeyId(key.keyId)&&key.p256Point.size()==64&&signature.size()==64&&
           signature_detail::keyIdForPoint(key.p256Point,computedId)&&computedId==key.keyId&&
           signature_detail::verifyP256Sha256(key.p256Point,manifest,signature);
}

struct ManifestAuthorization {bool ok=false;UpdateManifest manifest;std::string error;};

inline ManifestAuthorization verifyProductionManifest(std::string_view manifestBytes,std::string_view signatureBytes,
    std::string_view releaseTag,std::string_view installedVersion,std::int64_t now,ManifestUse use=ManifestUse::Install){
    ManifestAuthorization result;
    if(!ProductionUpdateKeyProvisioned||ProductionUpdateKeyId.empty()){
        result.error="Publisher update authentication is not configured on this build.";return result;
    }
    TrustedPublicKey key;key.keyId.assign(ProductionUpdateKeyId.data(),ProductionUpdateKeyId.size());key.p256Point.assign(ProductionUpdatePublicKey.begin(),ProductionUpdatePublicKey.end());
    if(!verifyManifestSignature(manifestBytes,signatureBytes,key)){result.error="The update manifest signature is missing, invalid, or from an unknown publisher key.";return result;}
    if(!parseCanonicalManifest(manifestBytes,result.manifest)){result.error="The signed update manifest is malformed or uses an unsupported schema.";return result;}
    if(result.manifest.keyId!=key.keyId||releaseTag!="v"+result.manifest.version){result.error="The signed update manifest does not match this official release version.";return result;}
    if(!validateManifestFreshness(result.manifest,now,use)){result.error="The signed update manifest is expired or has an invalid publication time.";return result;}
    Version installed,latest;
    if(!detail::parseVersion(installedVersion,installed)||!detail::parseVersion(result.manifest.version,latest)||
       !latest.prerelease.empty()||detail::compare(latest,installed)<=0){result.error="The signed update is not a newer stable version.";return result;}
    result.ok=true;return result;
}

inline ManifestAuthorization verifyManifestWithKey(std::string_view manifestBytes,std::string_view signatureBytes,
    std::string_view releaseTag,std::string_view installedVersion,std::int64_t now,const TrustedPublicKey&key,
    ManifestUse use=ManifestUse::Install){
    ManifestAuthorization result;
    if(!verifyManifestSignature(manifestBytes,signatureBytes,key)){result.error="The update manifest signature is missing, invalid, or from an unknown publisher key.";return result;}
    if(!parseCanonicalManifest(manifestBytes,result.manifest)){result.error="The signed update manifest is malformed or uses an unsupported schema.";return result;}
    if(result.manifest.keyId!=key.keyId||releaseTag!="v"+result.manifest.version){result.error="The signed update manifest does not match this official release version.";return result;}
    if(!validateManifestFreshness(result.manifest,now,use)){result.error="The signed update manifest is expired or has an invalid publication time.";return result;}
    Version installed,latest;
    if(!detail::parseVersion(installedVersion,installed)||!detail::parseVersion(result.manifest.version,latest)||
       !latest.prerelease.empty()||detail::compare(latest,installed)<=0){result.error="The signed update is not a newer stable version.";return result;}
    result.ok=true;return result;
}

#ifdef EYEBREAK_TEST_BUILD
inline bool readTestPublicKey(const std::wstring&stagingDirectory,TrustedPublicKey&key){
    const std::wstring path=stagingDirectory+L"\\test-update-public-key.bin";
    HANDLE file=CreateFileW(path.c_str(),GENERIC_READ,FILE_SHARE_READ,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL|FILE_FLAG_OPEN_REPARSE_POINT,nullptr);
    if(file==INVALID_HANDLE_VALUE)return false;
    FILE_ATTRIBUTE_TAG_INFO tag{};LARGE_INTEGER size{};std::array<unsigned char,64>point{};DWORD got=0;
    const bool ok=GetFileInformationByHandleEx(file,FileAttributeTagInfo,&tag,sizeof(tag))&&!(tag.FileAttributes&(FILE_ATTRIBUTE_REPARSE_POINT|FILE_ATTRIBUTE_DIRECTORY))&&
        GetFileSizeEx(file,&size)&&size.QuadPart==static_cast<LONGLONG>(point.size())&&ReadFile(file,point.data(),DWORD(point.size()),&got,nullptr)&&got==point.size();
    CloseHandle(file);if(!ok)return false;key.p256Point.assign(point.begin(),point.end());return signature_detail::keyIdForPoint(key.p256Point,key.keyId);
}
inline ManifestAuthorization verifyStagedManifest(std::string_view manifestBytes,std::string_view signatureBytes,
    const std::wstring&stagingDirectory,std::string_view releaseTag,std::string_view installedVersion,std::int64_t now,
    ManifestUse use=ManifestUse::Install){
    TrustedPublicKey testKey;
    if(readTestPublicKey(stagingDirectory,testKey))return verifyManifestWithKey(manifestBytes,signatureBytes,releaseTag,installedVersion,now,testKey,use);
    return verifyProductionManifest(manifestBytes,signatureBytes,releaseTag,installedVersion,now,use);
}
#else
inline ManifestAuthorization verifyStagedManifest(std::string_view manifestBytes,std::string_view signatureBytes,
    const std::wstring&,std::string_view releaseTag,std::string_view installedVersion,std::int64_t now,
    ManifestUse use=ManifestUse::Install){
    return verifyProductionManifest(manifestBytes,signatureBytes,releaseTag,installedVersion,now,use);
}
#endif

} // namespace eye::updates
