#pragma once

#include <algorithm>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace eye::updates::presentation {

inline std::wstring nativeLines(std::wstring_view input) {
    std::wstring output;
    output.reserve(input.size() + 8);
    for (std::size_t i = 0; i < input.size(); ++i) {
        const wchar_t c = input[i];
        if (c == L'\r' || c == L'\n') {
            if (c == L'\r' && i + 1 < input.size() && input[i + 1] == L'\n') ++i;
            output += L"\r\n";
        } else if (c == 0) {
            continue;
        } else if ((c < 0x20 && c != L'\t') || c == 0x7f) {
            output.push_back(L' ');
        } else {
            output.push_back(c);
        }
    }
    return output;
}

inline std::wstring markdownPlainText(std::wstring_view input, std::size_t limit = 1800) {
    const auto normalized = nativeLines(input);
    std::vector<std::wstring> lines;
    std::vector<bool> headings;
    std::size_t at = 0;
    auto trim = [](std::wstring& line) {
        while (!line.empty() && (line.back() == L' ' || line.back() == L'\t')) line.pop_back();
        std::size_t first = 0;
        while (first < line.size() && (line[first] == L' ' || line[first] == L'\t')) ++first;
        if (first) line.erase(0, first);
    };
    while (at <= normalized.size()) {
        const auto end = normalized.find(L"\r\n", at);
        const auto length = (end == std::wstring::npos ? normalized.size() : end) - at;
        std::wstring line(normalized.substr(at, length));
        at = end == std::wstring::npos ? normalized.size() + 1 : end + 2;
        trim(line);

        bool heading = false;
        std::size_t hashes = 0;
        while (hashes < line.size() && hashes < 6 && line[hashes] == L'#') ++hashes;
        if (hashes && hashes < line.size() && line[hashes] == L' ') {
            line.erase(0, hashes + 1);
            heading = true;
        }
        bool bullet = line.size() >= 2 && (line[0] == L'-' || line[0] == L'*' || line[0] == L'+') && line[1] == L' ';
        if (bullet) line.replace(0, 2, L"• ");
        if (line.size() >= 2 && line[0] == L'>' && line[1] == L' ') line.replace(0, 2, L"  ");

        std::wstring plain;
        plain.reserve(line.size());
        for (std::size_t i = 0; i < line.size();) {
            if (line[i] == L'[') {
                const auto close = line.find(L"](", i + 1);
                const auto finish = close == std::wstring::npos ? std::wstring::npos : line.find(L')', close + 2);
                if (finish != std::wstring::npos) {
                    plain.append(line, i + 1, close - i - 1);
                    i = finish + 1;
                    continue;
                }
            }
            if (line[i] == L'\\' && i + 1 < line.size()) {
                plain.push_back(line[i + 1]);
                i += 2;
                continue;
            }
            if (line[i] == L'`') {
                const auto close = line.find(L'`', i + 1);
                if (close != std::wstring::npos) { plain.append(line, i + 1, close - i - 1); i = close + 1; continue; }
                plain.push_back(line[i++]);
                continue;
            }
            if (line[i] == L'*' || line[i] == L'_' || line[i] == L'~') {
                const wchar_t marker = line[i];
                std::size_t run = 1;
                while (i + run < line.size() && line[i + run] == marker) ++run;
                const std::wstring markerRun(run, marker);
                const auto close = line.find(markerRun, i + run);
                const auto open = i ? line.rfind(markerRun, i - 1) : std::wstring::npos;
                if ((run >= 2 || marker != L'~') && (close != std::wstring::npos || open != std::wstring::npos)) { i += run; continue; }
                plain.append(run, marker); i += run; continue;
            }
            plain.push_back(line[i++]);
        }
        if (plain.empty()) {
            if (!lines.empty() && !lines.back().empty()) { lines.emplace_back(); headings.push_back(false); }
            continue;
        }
        if (heading && !lines.empty() && !lines.back().empty()) { lines.emplace_back(); headings.push_back(false); }
        else if (!heading && !lines.empty() && headings.back()) { lines.emplace_back(); headings.push_back(false); }
        lines.push_back(std::move(plain));
        headings.push_back(heading);
    }
    while (!lines.empty() && lines.back().empty()) { lines.pop_back(); headings.pop_back(); }
    std::wstring output;
    for (const auto& line : lines) { if (!output.empty()) output += L"\r\n"; output += line; }
    if (output.size() > limit) {
        output.resize(limit > 2 ? limit - 2 : limit);
        if (limit >= 2) output += L"\r\n";
        if (output.size() < limit) output += L"…";
    }
    return output;
}

inline std::wstring formatDataSize(std::uint64_t bytes) {
    constexpr std::uint64_t kib = 1024, mib = 1024 * kib;
    if (bytes < mib) return std::to_wstring((bytes + kib / 2) / kib) + L" KB";
    const std::uint64_t tenths = (bytes / mib) * 10 + ((bytes % mib) * 10 + mib / 2) / mib;
    return std::to_wstring(tenths / 10) + L"." + std::to_wstring(tenths % 10) + L" MB";
}

} // namespace eye::updates::presentation
