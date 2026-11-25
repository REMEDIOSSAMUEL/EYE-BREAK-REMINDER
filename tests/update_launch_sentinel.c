#define WIN32_LEAN_AND_MEAN
#include <windows.h>

int main(void) {
    wchar_t marker[MAX_PATH];
    DWORD length = GetEnvironmentVariableW(
        L"EBR_TEST_UNVERIFIED_LAUNCH_MARKER", marker, (DWORD)(sizeof(marker) / sizeof(marker[0])));
    if (length == 0 || length >= sizeof(marker) / sizeof(marker[0])) return 2;

    HANDLE file = CreateFileW(marker, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS,
                              FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return 3;

    static const char message[] = "unverified installer payload was executed";
    DWORD written = 0;
    BOOL ok = WriteFile(file, message, (DWORD)(sizeof(message) - 1), &written, NULL);
    CloseHandle(file);
    return ok && written == sizeof(message) - 1 ? 0 : 4;
}
