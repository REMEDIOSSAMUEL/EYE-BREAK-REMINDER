#include <windows.h>

#include <array>
#include <string>

namespace {

bool fullPath(const std::wstring& input, std::wstring& output) {
    std::array<wchar_t, 32768> buffer{};
    const DWORD length = GetFullPathNameW(input.c_str(), DWORD(buffer.size()), buffer.data(), nullptr);
    if (!length || length >= buffer.size()) return false;
    output.assign(buffer.data(), length);
    while (output.size() > 3 && (output.back() == L'\\' || output.back() == L'/')) output.pop_back();
    return true;
}

bool writeExistingFile(const std::wstring& path, const char* bytes, DWORD size) {
    const DWORD attributes = GetFileAttributesW(path.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES ||
        (attributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT))) return false;
    HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, OPEN_EXISTING,
                              FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return false;
    LARGE_INTEGER beginning{};
    DWORD written = 0;
    const bool ok = SetFilePointerEx(file, beginning, nullptr, FILE_BEGIN) != FALSE &&
                    WriteFile(file, bytes, size, &written, nullptr) != FALSE && written == size &&
                    SetEndOfFile(file) != FALSE;
    CloseHandle(file);
    return ok;
}

bool readInstallDirectory(std::wstring& output) {
    HKEY key{};
    if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\EyeBreakReminder", 0, KEY_QUERY_VALUE, &key) != ERROR_SUCCESS)
        return false;
    std::array<wchar_t, 32768> value{};
    DWORD type = 0;
    DWORD bytes = DWORD(value.size() * sizeof(wchar_t));
    const LONG result = RegQueryValueExW(key, L"InstallDir", nullptr, &type,
                                         reinterpret_cast<BYTE*>(value.data()), &bytes);
    RegCloseKey(key);
    if (result != ERROR_SUCCESS || type != REG_SZ || bytes < sizeof(wchar_t) || !value[0]) return false;
    output.assign(value.data());
    return true;
}

bool mutateOnlyDisposableInstall(std::wstring& markerPath) {
    std::array<wchar_t, 32768> runnerTempBuffer{};
    const DWORD length = GetEnvironmentVariableW(L"RUNNER_TEMP", runnerTempBuffer.data(), DWORD(runnerTempBuffer.size()));
    if (!length || length >= runnerTempBuffer.size()) return false;
    std::wstring runnerTemp(runnerTempBuffer.data(), length);
    std::wstring expectedInstall;
    if (!fullPath(runnerTemp + L"\\EBR-v1.4-Updater-Acceptance\\install", expectedInstall)) return false;

    std::wstring registeredInstall, actualInstall;
    if (!readInstallDirectory(registeredInstall) || !fullPath(registeredInstall, actualInstall) ||
        CompareStringOrdinal(expectedInstall.c_str(), -1, actualInstall.c_str(), -1, TRUE) != CSTR_EQUAL) return false;

    const std::wstring exePath = actualInstall + L"\\EyeBreakReminder.exe";
    const std::wstring readmePath = actualInstall + L"\\README.md";
    constexpr char partialExe[] = "EBR-PARTIAL-INSTALL-EXECUTABLE\r\n";
    constexpr char partialReadme[] = "EBR partial installer replacement\r\n";
    if (!writeExistingFile(exePath, partialExe, DWORD(sizeof(partialExe) - 1)) ||
        !writeExistingFile(readmePath, partialReadme, DWORD(sizeof(partialReadme) - 1))) return false;

    HKEY uninstall{};
    if (RegOpenKeyExW(HKEY_CURRENT_USER,
                      L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\EyeBreakReminder",
                      0, KEY_SET_VALUE, &uninstall) != ERROR_SUCCESS) return false;
    constexpr wchar_t partialVersion[] = L"1.4.1";
    const LONG registryResult = RegSetValueExW(uninstall, L"DisplayVersion", 0, REG_SZ,
        reinterpret_cast<const BYTE*>(partialVersion), DWORD(sizeof(partialVersion)));
    RegCloseKey(uninstall);
    if (registryResult != ERROR_SUCCESS) return false;

    std::wstring runnerRoot;
    if (!fullPath(runnerTemp + L"\\EBR-v1.4-Updater-Acceptance", runnerRoot)) return false;
    markerPath = runnerRoot + L"\\partial-install-mutation.txt";
    HANDLE marker = CreateFileW(markerPath.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW,
                                FILE_ATTRIBUTE_NORMAL, nullptr);
    if (marker == INVALID_HANDLE_VALUE) return false;
    constexpr char evidence[] = "partial-install-mutation-v1;expected-installer-exit=37\r\n";
    DWORD written = 0;
    const bool markerWritten = WriteFile(marker, evidence, DWORD(sizeof(evidence) - 1), &written, nullptr) != FALSE &&
                               written == sizeof(evidence) - 1;
    CloseHandle(marker);
    return markerWritten;
}

bool markProductionTestLaunch(std::wstring& markerPath) {
    std::array<wchar_t, 32768> runnerTempBuffer{};
    const DWORD runnerLength = GetEnvironmentVariableW(L"RUNNER_TEMP", runnerTempBuffer.data(), DWORD(runnerTempBuffer.size()));
    std::array<wchar_t, 32768> markerBuffer{};
    const DWORD markerLength = GetEnvironmentVariableW(L"EBR_TEST_INSTALLER_LAUNCH_MARKER", markerBuffer.data(), DWORD(markerBuffer.size()));
    if (!runnerLength || runnerLength >= runnerTempBuffer.size() || !markerLength || markerLength >= markerBuffer.size()) return false;
    std::wstring expected;
    if (!fullPath(std::wstring(runnerTempBuffer.data(), runnerLength) +
                  L"\\EyeBreakReminder-Production-Update-Acceptance\\controlled-installer-launched.txt", expected)) return false;
    std::wstring actual;
    if (!fullPath(std::wstring(markerBuffer.data(), markerLength), actual) ||
        CompareStringOrdinal(expected.c_str(), -1, actual.c_str(), -1, TRUE) != CSTR_EQUAL) return false;
    HANDLE marker = CreateFileW(actual.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW,
                                FILE_ATTRIBUTE_NORMAL, nullptr);
    if (marker == INVALID_HANDLE_VALUE) return false;
    constexpr char evidence[] = "controlled-installer-executed\r\n";
    DWORD written = 0;
    const bool ok = WriteFile(marker, evidence, DWORD(sizeof(evidence) - 1), &written, nullptr) != FALSE &&
                    written == sizeof(evidence) - 1;
    CloseHandle(marker);
    if (ok) markerPath = actual;
    return ok;
}

} // namespace

// Test-only installer stand-in. It validates the disposable GitHub Actions
// install path, damages existing installer-owned files and the version registry
// value, records that the partial mutation really happened, then exits with a
// controlled failure. The real update coordinator must restore the prior app.
int WINAPI wWinMain(HINSTANCE, HINSTANCE, LPWSTR, int) {
    std::wstring marker;
    if (GetEnvironmentVariableW(L"EBR_TEST_INSTALLER_LAUNCH_MARKER", nullptr, 0))
        return markProductionTestLaunch(marker) ? 37 : 38;
    return mutateOnlyDisposableInstall(marker) ? 37 : 38;
}
