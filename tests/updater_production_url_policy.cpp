#include "../src/update_client.hpp"
#include <iostream>

namespace {
int assertions=0;
bool check(bool value,const char*name){++assertions;if(!value)std::cerr<<"FAIL: "<<name<<'\n';return value;}
}

int main(){
    using eye::updates::client_detail::Url;
    bool ok=true;Url parsed;
    ok&=check(eye::updates::client_detail::crackHttps(L"https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/download/v1.4.1/EyeBreakReminder.exe",parsed),"canonical official GitHub release URL is accepted in production policy");
    ok&=check(eye::updates::client_detail::crackHttps(L"https://release-assets.githubusercontent.com/asset",parsed),"approved GitHub release-asset redirect host is accepted in production policy");
    ok&=check(!eye::updates::client_detail::crackHttps(L"https://localhost:49152/asset",parsed),"test-only localhost TLS endpoint is rejected by the production URL policy");
    ok&=check(!eye::updates::client_detail::crackHttps(L"https://github.com:49152/asset",parsed),"nonstandard HTTPS port is rejected by the production URL policy");
    ok&=check(!eye::updates::client_detail::crackHttps(L"http://github.com/asset",parsed),"plaintext HTTP is rejected by the production URL policy");
    ok&=check(!eye::updates::client_detail::crackHttps(L"https://github.com.evil.invalid/asset",parsed),"lookalike GitHub hostname is rejected by the production URL policy");
    ok&=check(!eye::updates::client_detail::crackHttps(L"https://user:password@github.com/asset",parsed),"URL-embedded credentials are rejected by the production URL policy");
    ok&=check(!eye::updates::client_detail::crackHttps(L"https://api.github.com/repos/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/latest",parsed),"API host cannot be substituted for a release asset host");
    if(!ok)return 1;
    std::cout<<"PASS: "<<assertions<<" production URL-policy assertions executed.\n";return 0;
}
