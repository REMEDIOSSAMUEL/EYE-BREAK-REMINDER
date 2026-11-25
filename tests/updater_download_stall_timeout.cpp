#define EYEBREAK_TEST_BUILD
#include "../src/update_client.hpp"
#include <windows.h>
#include <atomic>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <string>

namespace {
bool writeUtf8(const std::wstring& path, const std::string& text) {
    HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW,
                              FILE_ATTRIBUTE_NORMAL | FILE_FLAG_WRITE_THROUGH, nullptr);
    if (file == INVALID_HANDLE_VALUE) return false;
    DWORD written = 0;
    const bool ok = WriteFile(file, text.data(), static_cast<DWORD>(text.size()), &written, nullptr) != FALSE &&
                    written == text.size() && FlushFileBuffers(file) != FALSE;
    CloseHandle(file);
    if (!ok) DeleteFileW(path.c_str());
    return ok;
}

bool readUtf8(const std::wstring& path, std::string& text) {
    HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                              FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
    if (file == INVALID_HANDLE_VALUE) return false;
    FILE_ATTRIBUTE_TAG_INFO tag{};
    LARGE_INTEGER size{};
    if (!GetFileInformationByHandleEx(file, FileAttributeTagInfo, &tag, sizeof(tag)) ||
        (tag.FileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY)) ||
        !GetFileSizeEx(file, &size) || size.QuadPart < 0 || size.QuadPart > 4096) {
        CloseHandle(file);
        return false;
    }
    text.resize(static_cast<std::size_t>(size.QuadPart));
    DWORD read = 0;
    const bool ok = ReadFile(file, text.data(), static_cast<DWORD>(text.size()), &read, nullptr) != FALSE &&
                    read == text.size();
    CloseHandle(file);
    return ok;
}

std::string jsonEscape(const std::string& value) {
    std::string out;
    for (const unsigned char ch : value) {
        if (ch == '"' || ch == '\\') { out.push_back('\\'); out.push_back(static_cast<char>(ch)); }
        else if (ch >= 0x20) out.push_back(static_cast<char>(ch));
    }
    return out;
}

bool exists(const std::wstring& path) {
    return GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES;
}
}

int wmain(int argc, wchar_t** argv) {
    if (argc != 4) {
        std::wcerr << L"usage: updater-download-stall-timeout.exe <port> <isolated-root> <result-json>\n";
        return 2;
    }
    wchar_t* end = nullptr;
    const unsigned long port = std::wcstoul(argv[1], &end, 10);
    if (!end || *end || port < 1024 || port > 65535) return 2;

    const std::wstring root = argv[2];
    const std::wstring stage = root + L"\\download-staging";
    const std::wstring protectedInstall = root + L"\\protected-install";
    const std::wstring sentinel = protectedInstall + L"\\existing-user-data.sentinel";
    const std::wstring partial = stage + L"\\EyeBreakReminder-Setup-x64.exe.part";
    const std::wstring output = stage + L"\\EyeBreakReminder-Setup-x64.exe";
    if (!eye::updates::safeStagingDirectory(root) ||
        !CreateDirectoryW(stage.c_str(), nullptr) ||
        !CreateDirectoryW(protectedInstall.c_str(), nullptr) ||
        !writeUtf8(sentinel, "pre-existing user data must remain byte-for-byte intact\n")) {
        std::cerr << "FAIL: create a new, isolated staging root and protected-data sentinel\n";
        return 3;
    }

    std::string before;
    if (!readUtf8(sentinel, before)) return 3;
    const std::string url = "https://localhost:" + std::to_string(port) + "/stall.bin";
    eye::updates::ReleaseAsset asset{
        "EyeBreakReminder-Setup-x64.exe", url,
        "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", 3
    };
    std::atomic_bool cancelled{false};
    const ULONGLONG started = GetTickCount64();
    const auto result = eye::updates::downloadVerified(asset, stage, L"EyeBreakReminder-Setup-x64.exe", cancelled);
    const ULONGLONG elapsedMs = GetTickCount64() - started;
    std::string after;
    const bool dataProtected = readUtf8(sentinel, after) && before == after;
    const bool noUnsafePayload = !exists(partial) && !exists(output);
    const bool timeoutReported = result.error.find("timed out") != std::string::npos;
    // The test-build WinHTTP receive timeout for localhost is 3000 ms. This
    // elapsed time also includes request setup, name resolution, connection,
    // and runner scheduling, so keep a wider bound while staying below the
    // PowerShell harness's 15-second watchdog.
    const bool stalledTransferExpired = elapsedMs >= 2200 && elapsedMs < 12000;
    const bool passed = !result.ok && !result.cancelled && timeoutReported &&
                        result.received == 0 && stalledTransferExpired &&
                        dataProtected && noUnsafePayload;

    const std::string json =
        std::string("{\n  \"test\": \"actual_stalled_https_asset_body_timeout\",\n") +
        "  \"status\": \"" + (passed ? "PASS" : "FAIL") + "\",\n" +
        "  \"actual_download_function\": \"eye::updates::downloadVerified\",\n" +
        "  \"tls_hostname\": \"localhost\",\n" +
        "  \"http_status_and_declared_content_length_sent\": 200,\n" +
        "  \"body_bytes_sent_before_timeout\": " + std::to_string(result.received) + ",\n" +
        "  \"elapsed_ms\": " + std::to_string(elapsedMs) + ",\n" +
        "  \"expected_receive_timeout_ms\": 3000,\n" +
        "  \"maximum_total_elapsed_ms\": 12000,\n" +
        "  \"timeout_error_reported\": " + (timeoutReported ? "true" : "false") + ",\n" +
        "  \"partial_and_final_download_files_removed\": " + (noUnsafePayload ? "true" : "false") + ",\n" +
        "  \"preexisting_sentinel_preserved_byte_for_byte\": " + (dataProtected ? "true" : "false") + ",\n" +
        "  \"error\": \"" + jsonEscape(result.error) + "\"\n}\n";
    if (!writeUtf8(argv[3], json)) {
        std::cerr << "FAIL: write the test result JSON\n";
        return 4;
    }

    std::cout << (passed ? "PASS" : "FAIL")
              << ": real WinHTTP HTTPS response-body stall, bounded timeout, no staged payload, "
                 "and existing-data preservation (elapsed " << elapsedMs << " ms; "
              << result.received << " body bytes; error: " << result.error << ")\n";
    return passed ? 0 : 1;
}
