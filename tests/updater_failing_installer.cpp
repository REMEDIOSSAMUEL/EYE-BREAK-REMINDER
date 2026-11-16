#include <windows.h>

// Test-only installer stand-in. It has an explicit 1.4.1 product resource,
// accepts any arguments without interpreting them, and exits unsuccessfully
// before changing files or registry state.
int WINAPI wWinMain(HINSTANCE,HINSTANCE,LPWSTR,int){return 37;}
