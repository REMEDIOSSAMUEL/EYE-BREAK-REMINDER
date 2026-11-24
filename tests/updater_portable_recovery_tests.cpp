#define EYEBREAK_TEST_BUILD
#include "../src/update_coordinator.hpp"
#include <windows.h>
#include <aclapi.h>
#include <objbase.h>
#include <algorithm>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

// Focused Windows integration test for PORT-008/009/010. It calls the actual
// portable transaction and recovery functions from update_coordinator.hpp,
// using real versioned application executables copied only beneath RUNNER_TEMP.
// Run only on a disposable GitHub-hosted Windows runner; it writes the runner's
// HKCU RunOnce recovery entry as a real failed transaction would.
namespace {
int assertions = 0;
bool check(bool condition, const char* label) {
    ++assertions;
    if (!condition) std::cerr << "FAIL: " << label << '\n';
    else std::cout << "PASS: " << label << '\n';
    return condition;
}

bool writeFile(const std::wstring& path, const std::string& contents) {
    HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW,
                              FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return false;
    DWORD written = 0;
    const bool ok = WriteFile(file, contents.data(), DWORD(contents.size()), &written, nullptr) != FALSE
        && written == contents.size() && FlushFileBuffers(file);
    CloseHandle(file);
    return ok;
}

bool copyFile(const std::wstring& source, const std::wstring& destination) {
    return CopyFileW(source.c_str(), destination.c_str(), TRUE) != FALSE;
}

bool readFile(const std::wstring& path, std::string& contents) {
    return eye::win::read(path, contents, 32ull * 1024 * 1024);
}

std::string sha256(const std::wstring& path) {
    std::string digest;
    return eye::updates::hashFile(path, digest) ? digest : std::string{};
}

bool deleteTree(const std::wstring& path) {
    std::error_code ec;
    std::filesystem::remove_all(std::filesystem::path(path), ec);
    return !ec && GetFileAttributesW(path.c_str()) == INVALID_FILE_ATTRIBUTES;
}

struct DirectoryAcl {
    std::wstring path;
    PSECURITY_DESCRIPTOR originalDescriptor = nullptr;
    PACL originalDacl = nullptr;
    bool restricted = false;

    bool denyCurrentUserWrites(const std::wstring& directory) {
        path = directory;
        PSID userSid = nullptr;
        HANDLE token = nullptr;
        DWORD bytes = 0;
        if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return false;
        GetTokenInformation(token, TokenUser, nullptr, 0, &bytes);
        if (GetLastError() != ERROR_INSUFFICIENT_BUFFER || !bytes) {
            CloseHandle(token);
            return false;
        }
        std::vector<BYTE> tokenData(bytes);
        const bool gotUser = GetTokenInformation(token, TokenUser, tokenData.data(), bytes, &bytes) != FALSE;
        CloseHandle(token);
        if (!gotUser) return false;
        userSid = reinterpret_cast<TOKEN_USER*>(tokenData.data())->User.Sid;

        PSID owner = nullptr, group = nullptr;
        PACL sacl = nullptr;
        const DWORD saved = GetNamedSecurityInfoW(const_cast<LPWSTR>(path.c_str()), SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION, &owner, &group, &originalDacl, &sacl, &originalDescriptor);
        if (saved != ERROR_SUCCESS) return false;

        EXPLICIT_ACCESSW deny{};
        deny.grfAccessPermissions = FILE_ADD_FILE | FILE_ADD_SUBDIRECTORY | FILE_DELETE_CHILD |
            FILE_WRITE_DATA | FILE_APPEND_DATA | DELETE;
        deny.grfAccessMode = DENY_ACCESS;
        deny.grfInheritance = SUB_CONTAINERS_AND_OBJECTS_INHERIT;
        deny.Trustee.TrusteeForm = TRUSTEE_IS_SID;
        deny.Trustee.TrusteeType = TRUSTEE_IS_USER;
        deny.Trustee.ptstrName = static_cast<LPWSTR>(userSid);
        PACL restrictedDacl = nullptr;
        const DWORD aclResult = SetEntriesInAclW(1, &deny, originalDacl, &restrictedDacl);
        if (aclResult != ERROR_SUCCESS) return false;
        const DWORD setResult = SetNamedSecurityInfoW(const_cast<LPWSTR>(path.c_str()), SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION, nullptr, nullptr, restrictedDacl, nullptr);
        LocalFree(restrictedDacl);
        restricted = setResult == ERROR_SUCCESS;
        return restricted;
    }

    bool restore() {
        if (!restricted) return true;
        const DWORD result = SetNamedSecurityInfoW(const_cast<LPWSTR>(path.c_str()), SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION, nullptr, nullptr, originalDacl, nullptr);
        restricted = false;
        return result == ERROR_SUCCESS;
    }

    ~DirectoryAcl() {
        restore();
        if (originalDescriptor) LocalFree(originalDescriptor);
    }
};

bool hasRunOnceRecovery() {
    HKEY key = nullptr;
    if (RegOpenKeyExW(HKEY_CURRENT_USER,
        L"Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce", 0,
        KEY_QUERY_VALUE, &key) != ERROR_SUCCESS) return false;
    DWORD type = 0, bytes = 0;
    const LONG result = RegQueryValueExW(key, L"!EyeBreakReminderUpdateRecovery",
        nullptr, &type, nullptr, &bytes);
    RegCloseKey(key);
    return result == ERROR_SUCCESS;
}

bool emulateWindowsRunOncePostCommandRemovalForTest(const eye::updates::Transaction&transaction) {
    // This test calls runRecovery directly instead of allowing Windows to
    // dispatch RunOnce. Remove only the exact owned value to model the
    // documented post-command cleanup; this is not automatic-invocation proof.
    if (!eye::updates::recoveryRegistrationMatches(transaction)) return false;
    HKEY key = nullptr;
    if (RegOpenKeyExW(HKEY_CURRENT_USER,
        L"Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce", 0,
        KEY_SET_VALUE, &key) != ERROR_SUCCESS) return false;
    const LONG result = RegDeleteValueW(key, L"!EyeBreakReminderUpdateRecovery");
    RegCloseKey(key);
    return result == ERROR_SUCCESS;
}

bool assertProfilePreserved(const std::wstring& dataDirectory, const std::string& historyBefore) {
    std::string settings, history;
    const bool readSettings = readFile(dataDirectory + L"\\settings.ini", settings);
    const bool readHistory = readFile(dataDirectory + L"\\history.dat", history);
    bool ok = true;
    ok &= check(readSettings && settings.find("workMinutes=37") != std::string::npos &&
                settings.find("breakSeconds=33") != std::string::npos &&
                settings.find("customWorkAccent=1") != std::string::npos &&
                settings.find("workAccentColor=3900150") != std::string::npos,
                "portable failure recovery preserves meaningful existing settings");
    ok &= check(readHistory && history == historyBefore,
                "portable failure recovery preserves history byte-for-byte");
    return ok;
}

bool createSignedTestManifest(const std::wstring& signer, const std::wstring& stage,
                              const std::wstring& installer, const std::wstring& portable) {
    if (signer.empty() || !eye::updates::safeFile(signer) ||
        !eye::updates::safeFile(installer) || !eye::updates::safeFile(portable)) return false;
    std::wstring command = eye::updates::quoteArgument(signer) +
        L" --sign-update-manifest " + eye::updates::quoteArgument(stage) + L" " +
        eye::updates::quoteArgument(installer) + L" " + eye::updates::quoteArgument(portable);
    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION process{};
    if (!CreateProcessW(signer.c_str(), command.data(), nullptr, nullptr, FALSE,
                        CREATE_NO_WINDOW, nullptr, eye::updates::parentPath(signer).c_str(),
                        &startup, &process)) return false;
    CloseHandle(process.hThread);
    const DWORD wait = WaitForSingleObject(process.hProcess, INFINITE);
    DWORD exitCode = 1;
    const bool exited = wait == WAIT_OBJECT_0 && GetExitCodeProcess(process.hProcess, &exitCode);
    CloseHandle(process.hProcess);
    return exited && exitCode == 0 &&
        eye::updates::safeFile(stage + L"\\EyeBreakReminder-UpdateManifest.json", 16384) &&
        eye::updates::safeFile(stage + L"\\EyeBreakReminder-UpdateManifest.sig", 64) &&
        eye::updates::safeFile(stage + L"\\test-update-public-key.bin", 64);
}

struct TestCase {
    const char* name;
    bool lockExecutable;
    bool denyDirectoryWrites;
    bool suppressUpdatedConfirmation;
};

bool runCase(const TestCase& test, const std::wstring& baseline, const std::wstring& update,
             const std::wstring& installer, const std::wstring& signer,
             const std::wstring& testRoot) {
    bool ok = true;
    const std::wstring data = testRoot + L"\\profile";
    const std::wstring portable = testRoot + L"\\portable";
    if (!CreateDirectoryW(testRoot.c_str(), nullptr) || !CreateDirectoryW(data.c_str(), nullptr) ||
        !CreateDirectoryW(portable.c_str(), nullptr)) {
        return check(false, "create a new disposable case directory tree");
    }
    SetEnvironmentVariableW(L"EBR_GUI_TEST_DATA_DIRECTORY", data.c_str());

    std::wstring resolvedData;
    ok &= check(eye::updates::localDataDirectory(resolvedData) &&
                eye::updates::samePath(resolvedData, data),
                "coordinator is pointed at a disposable profile under RUNNER_TEMP");

    std::wstring stage;
    ok &= check(eye::updates::createStagingDirectory(data, stage),
                "create a private disposable recovery staging directory");
    const std::wstring target = portable + L"\\EyeBreakReminder.exe";
    const std::wstring artifact = stage + L"\\EyeBreakReminder.exe";
    const std::wstring coordinator = stage + L"\\coordinator.exe";
    const std::wstring transactionPath = stage + L"\\transaction.ini";
    const std::wstring neighboringFile = portable + L"\\keep-user-document.txt";
    const std::string settings =
        "workMinutes=37\nbreakSeconds=33\nvolume=32\ntheme=2\nalarm=0\nrepeat=1\n"
        "notifications=0\nsnooze=0\nautoStart=1\nstartup=0\nhistory=1\nbreakModeColors=1\n"
        "customWorkAccent=1\nworkAccentColor=3900150\ncustomBreakAccent=1\n"
        "breakAccentColor=16746496\nautoCheckUpdates=0\nautoDownloadUpdates=0\n"
        "updateLastCheck=0\nrestore=1\n";
    const std::string history = "1790000000 1 20\n";
    const std::string unrelated = "portable neighbor must not be changed\n";
    ok &= check(copyFile(baseline, target) && copyFile(update, artifact) &&
                copyFile(baseline, coordinator) && writeFile(data + L"\\settings.ini", settings) &&
                writeFile(data + L"\\history.dat", history) && writeFile(neighboringFile, unrelated),
                "stage real versioned binaries and disposable settings/history sentinels");

    const std::string originalHash = sha256(target);
    const std::string updateHash = sha256(artifact);
    ok &= check(!originalHash.empty() && eye::updates::productVersion(target) == L"1.4.0" &&
                eye::updates::productVersion(artifact) == L"1.4.1" && !updateHash.empty(),
                "fixtures are actual v1.4.0 and v1.4.1 Windows executables");

    eye::updates::Transaction transaction;
    transaction.stagingDirectory = stage;
    transaction.artifactPath = artifact;
    transaction.targetExecutable = target;
    transaction.dataDirectory = data;
    transaction.version = L"1.4.1";
    transaction.previousVersion = L"1.4.0";
    transaction.nonce = L"12345678-1234-1234-1234-123456789abc";
    transaction.kind = "portable";
    transaction.artifactName = "EyeBreakReminder.exe";
    transaction.sha256 = updateHash;
    transaction.expectedApplicationSha256 = updateHash;
    transaction.previousSha256 = originalHash;
    WIN32_FILE_ATTRIBUTE_DATA artifactInfo{};
    const bool gotArtifactInfo = GetFileAttributesExW(artifact.c_str(), GetFileExInfoStandard, &artifactInfo) != FALSE;
    transaction.expectedSize = gotArtifactInfo
        ? (std::uint64_t(artifactInfo.nFileSizeHigh) << 32) | artifactInfo.nFileSizeLow : 0;
    transaction.ownerPid = 0xFFFFFFFEu;
    ok &= check(gotArtifactInfo && transaction.expectedSize != 0 &&
                eye::updates::writeTransaction(transaction),
                "write a valid isolated portable transaction using actual payload identities");
    ok &= check(createSignedTestManifest(signer, stage, installer, artifact),
                "sign the isolated transaction metadata with an ephemeral test-only CNG key");
    if (!ok) {
        SetEnvironmentVariableW(L"EBR_GUI_TEST_DATA_DIRECTORY", nullptr);
        deleteTree(testRoot);
        return false;
    }

    HANDLE missingOwner = OpenProcess(SYNCHRONIZE, FALSE, transaction.ownerPid);
    const DWORD ownerError = GetLastError();
    if (missingOwner) CloseHandle(missingOwner);
    ok &= check(!missingOwner && ownerError == ERROR_INVALID_PARAMETER,
                "transaction owner PID is confirmed absent so the test cannot wait on a live process");
    if (missingOwner || ownerError != ERROR_INVALID_PARAMETER) {
        SetEnvironmentVariableW(L"EBR_GUI_TEST_DATA_DIRECTORY", nullptr);
        deleteTree(testRoot);
        return false;
    }

    DirectoryAcl directoryAcl;
    HANDLE targetLock = INVALID_HANDLE_VALUE;
    bool faultReady = true;
    if (test.denyDirectoryWrites) {
        const bool aclApplied = directoryAcl.denyCurrentUserWrites(portable);
        ok &= check(aclApplied,
                    "apply a temporary current-user write denial to the disposable portable folder");
        const std::wstring probe = portable + L"\\write-probe.tmp";
        HANDLE denied = CreateFileW(probe.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW,
                                    FILE_ATTRIBUTE_NORMAL, nullptr);
        const DWORD deniedError = GetLastError();
        if (denied != INVALID_HANDLE_VALUE) { CloseHandle(denied); DeleteFileW(probe.c_str()); }
        const bool deniedAsExpected = denied == INVALID_HANDLE_VALUE && deniedError == ERROR_ACCESS_DENIED;
        ok &= check(deniedAsExpected,
                    "the disposable portable directory genuinely rejects writes before update");
        faultReady = aclApplied && deniedAsExpected;
    }
    if (test.lockExecutable) {
        targetLock = CreateFileW(target.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
                                 nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        const bool lockHeld = targetLock != INVALID_HANDLE_VALUE;
        ok &= check(lockHeld,
                    "hold the disposable portable executable without FILE_SHARE_DELETE");
        faultReady = lockHeld;
    }
    if (!faultReady) {
        if (targetLock != INVALID_HANDLE_VALUE) CloseHandle(targetLock);
        directoryAcl.restore();
        SetEnvironmentVariableW(L"EBR_GUI_TEST_DATA_DIRECTORY", nullptr);
        deleteTree(testRoot);
        return false;
    }

    SetEnvironmentVariableW(L"EBR_GUI_TEST_CONFIRM_TIMEOUT_MS", nullptr);
    SetEnvironmentVariableW(L"EBR_GUI_TEST_SKIP_UPDATE_CONFIRM_VERSION", nullptr);
    if (test.suppressUpdatedConfirmation) {
        SetEnvironmentVariableW(L"EBR_GUI_TEST_CONFIRM_TIMEOUT_MS", L"5000");
        SetEnvironmentVariableW(L"EBR_GUI_TEST_SKIP_UPDATE_CONFIRM_VERSION", L"1.4.1");
    }
    eye::updates::UiState state;
    eye::updates::performTransaction(transaction, state);
    if (test.suppressUpdatedConfirmation) {
        ok &= check(state.done.load() && !state.success &&
                    state.message.find(L"The updated application did not start.") != std::wstring::npos &&
                    state.message.find(L"previous version was restored") != std::wstring::npos,
                    "failed portable startup reports that the previous version was restored");
    } else {
        ok &= check(state.done.load() && !state.success &&
                    state.message.find(L"previous executable and data backup remain") != std::wstring::npos,
                    "failed portable replacement returns a meaningful recoverable error");
    }
    ok &= check(sha256(target) == originalHash && eye::updates::productVersion(target) == L"1.4.0",
                "failed replacement leaves the previous executable byte-for-byte unchanged");
    ok &= check(GetFileAttributesW((target + L".update-new").c_str()) == INVALID_FILE_ATTRIBUTES &&
                GetFileAttributesW((target + L".update-restore").c_str()) == INVALID_FILE_ATTRIBUTES,
                "failed replacement leaves no partial or rollback temporary executable");
    std::string currentNeighbor;
    ok &= check(readFile(neighboringFile, currentNeighbor) && currentNeighbor == unrelated,
                "failed replacement does not write to an unrelated neighboring file");
    ok &= assertProfilePreserved(data, history);
    if (test.suppressUpdatedConfirmation) {
        ok &= check(!hasRunOnceRecovery(),
                    "automatic rollback clears its recovery registration after restoring the prior version");
    } else {
        ok &= check(hasRunOnceRecovery(),
                    "failed replacement retains the durable Windows recovery registration");
    }

    if (targetLock != INVALID_HANDLE_VALUE) {
        CloseHandle(targetLock);
        targetLock = INVALID_HANDLE_VALUE;
    }
    ok &= check(directoryAcl.restore(),
                "restore the disposable portable directory ACL before recovery");

    if (!test.suppressUpdatedConfirmation) {
        const int recoveryExit = eye::updates::runRecovery(transactionPath, transaction.stagingDirectory + L"\\coordinator.exe");
        ok &= check(recoveryExit == 0,
                    "actual coordinator recovery restores the previous portable executable after the fault clears");
    }
    ok &= check(sha256(target) == originalHash && eye::updates::productVersion(target) == L"1.4.0",
                "recovery restores the exact previous executable identity and version");
    ok &= check(eye::updates::targetApplicationRunning(transaction),
                "the recovered previous portable application launches and confirms startup");
    ok &= assertProfilePreserved(data, history);
    if (test.suppressUpdatedConfirmation) {
        ok &= check(!hasRunOnceRecovery(),
                    "the ordinary coordinator clears its owned RunOnce value after in-process rollback");
    } else {
        ok &= check(hasRunOnceRecovery() && eye::updates::recoveryRegistrationMatches(transaction),
                    "manual recovery leaves the exact !RunOnce value for Windows post-command handling");
        ok &= check(emulateWindowsRunOncePostCommandRemovalForTest(transaction) && !hasRunOnceRecovery(),
                    "test harness models post-command RunOnce removal without claiming an automatic sign-in invocation");
    }

    ok &= check(eye::updates::stopRunningApplication(transaction),
                "close only the recovered disposable portable application gracefully");
    for (int attempt = 0; attempt < 100 && eye::updates::targetApplicationRunning(transaction); ++attempt)
        Sleep(50);
    ok &= check(!eye::updates::targetApplicationRunning(transaction),
                "the recovered disposable portable process exits cleanly");
    ok &= check(readFile(neighboringFile, currentNeighbor) && currentNeighbor == unrelated,
                "recovery preserves unrelated files next to the portable executable");

    if (targetLock != INVALID_HANDLE_VALUE) CloseHandle(targetLock);
    if (!directoryAcl.restore()) ok &= check(false, "remove the temporary disposable-folder ACL restriction");
    SetEnvironmentVariableW(L"EBR_GUI_TEST_CONFIRM_TIMEOUT_MS", nullptr);
    SetEnvironmentVariableW(L"EBR_GUI_TEST_SKIP_UPDATE_CONFIRM_VERSION", nullptr);
    SetEnvironmentVariableW(L"EBR_GUI_TEST_DATA_DIRECTORY", nullptr);
    if (!deleteTree(testRoot)) ok &= check(false, "remove only the unique disposable case directory");
    return ok;
}

std::wstring toWide(const char* value) {
    const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, nullptr, 0);
    if (length <= 1) return {};
    std::wstring result(static_cast<std::size_t>(length), L'\0');
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, result.data(), length);
    result.pop_back();
    return result;
}

bool underRunnerTemp(const std::wstring& path, const std::wstring& runnerTemp) {
    const std::wstring root = eye::updates::absolutePath(runnerTemp);
    const std::wstring candidate = eye::updates::absolutePath(path);
    if (root.empty() || candidate.empty()) return false;
    const std::wstring prefix = root.back() == L'\\' ? root : root + L"\\";
    return candidate.size() > prefix.size() && CompareStringOrdinal(
        candidate.c_str(), int(prefix.size()), prefix.c_str(), int(prefix.size()), TRUE) == CSTR_EQUAL;
}
}

int main(int argc, char** argv) {
    wchar_t actions[16]{};
    wchar_t runnerTempRaw[32768]{};
    wchar_t runnerOs[32]{};
    const DWORD actionsLength = GetEnvironmentVariableW(L"GITHUB_ACTIONS", actions, DWORD(std::size(actions)));
    const DWORD tempLength = GetEnvironmentVariableW(L"RUNNER_TEMP", runnerTempRaw, DWORD(std::size(runnerTempRaw)));
    const DWORD osLength = GetEnvironmentVariableW(L"RUNNER_OS", runnerOs, DWORD(std::size(runnerOs)));
    if (actionsLength != 4 || _wcsicmp(actions, L"true") != 0 || !tempLength ||
        tempLength >= std::size(runnerTempRaw) || osLength != 7 || _wcsicmp(runnerOs, L"Windows") != 0) {
        std::cerr << "BLOCKED: this test may run only on a disposable GitHub Actions Windows runner with RUNNER_TEMP.\n";
        return 2;
    }
    if (argc != 5) {
        std::cerr << "Usage: updater-portable-recovery-tests.exe <baseline-v1.4.0.exe> <update-v1.4.1.exe> <update-v1.4.1-setup.exe> <disposable-test-signer.exe>\n";
        return 2;
    }
    const std::wstring baseline = toWide(argv[1]);
    const std::wstring update = toWide(argv[2]);
    const std::wstring installer = toWide(argv[3]);
    const std::wstring signer = toWide(argv[4]);
    if (baseline.empty() || update.empty() || !eye::updates::safeFile(baseline) ||
        !eye::updates::safeFile(update) || installer.empty() || !eye::updates::safeFile(installer) ||
        signer.empty() || !eye::updates::safeFile(signer)) {
        std::cerr << "FAIL: test inputs and the disposable test signer must be regular Windows executable files.\n";
        return 1;
    }
    if (FindWindowW(L"EyeBreakReminder.Native", nullptr)) {
        std::cerr << "BLOCKED: a reminder app window is already running; refusing to interact with it.\n";
        return 2;
    }
    if (hasRunOnceRecovery()) {
        std::cerr << "BLOCKED: a prior Eye Break Reminder recovery entry exists; refusing to overwrite it.\n";
        return 2;
    }
    const std::wstring runnerTemp(runnerTempRaw, tempLength);
    GUID id{};
    wchar_t idText[40]{};
    if (FAILED(CoCreateGuid(&id)) || !StringFromGUID2(id, idText, int(std::size(idText)))) {
        std::cerr << "FAIL: create a unique case identity.\n";
        return 1;
    }
    std::wstring suffix(idText);
    suffix.erase(std::remove(suffix.begin(), suffix.end(), L'{'), suffix.end());
    suffix.erase(std::remove(suffix.begin(), suffix.end(), L'}'), suffix.end());
    const TestCase cases[] = {
        {"PORT-008 unwritable portable directory", false, true, false},
        {"PORT-009 locked portable executable", true, false, false},
        {"PORT-010 failed new-version startup after replacement", false, false, true},
    };
    bool ok = true;
    for (std::size_t i = 0; i < std::size(cases); ++i) {
        const std::wstring root = runnerTemp + L"\\EBR-portable-recovery-" + suffix + L"-" + std::to_wstring(i);
        if (!underRunnerTemp(root, runnerTemp)) {
            std::cerr << "FAIL: refusing to create a case outside RUNNER_TEMP.\n";
            return 1;
        }
        std::cout << "CASE: " << cases[i].name << '\n';
        ok &= runCase(cases[i], baseline, update, installer, signer, root);
    }
    std::cout << (ok ? "PASS" : "FAIL") << ": " << assertions
              << " portable recovery integration assertions; cases: PORT-008, PORT-009, PORT-010."
              << " Production coordinator/recovery functions and real app fixtures were exercised;"
              << " no personal installation or profile path was used.\n";
    return ok ? 0 : 1;
}
