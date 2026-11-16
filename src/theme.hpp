#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <string>
#include <string_view>

namespace eye::theme {

using Color = std::uint32_t; // 0xRRGGBB; independent of Win32 COLORREF byte order.
constexpr Color rgb(unsigned red, unsigned green, unsigned blue) {
    return ((red & 0xffu) << 16) | ((green & 0xffu) << 8) | (blue & 0xffu);
}

enum class Mode : int { FollowWindows = 0, Light = 1, Dark = 2, HighContrastDark = 3, HighContrastLight = 4 };

struct Palette {
    Color background, surface, hover, foreground, secondary, line;
    Color workAccent, breakAccent, focus, workButtonText, breakButtonText;
    bool dark, highContrast;
};

inline Palette resolve(Mode mode, bool windowsDark) {
    switch (mode) {
        case Mode::Light:
            return {rgb(247,248,250), rgb(255,255,255), rgb(235,240,247), rgb(24,30,42), rgb(76,87,103), rgb(128,140,157),
                    rgb(29,78,216), rgb(15,118,110), rgb(29,78,216), rgb(255,255,255), rgb(255,255,255), false, false};
        case Mode::Dark:
            return {rgb(26,29,35), rgb(39,44,53), rgb(51,59,72), rgb(239,243,249), rgb(188,199,214), rgb(105,117,136),
                    rgb(96,165,250), rgb(45,212,191), rgb(96,165,250), rgb(15,28,46), rgb(15,28,46), true, false};
        case Mode::HighContrastDark:
            return {rgb(0,0,0), rgb(0,0,0), rgb(32,32,32), rgb(255,255,255), rgb(229,229,229), rgb(255,255,255),
                    rgb(255,255,0), rgb(0,255,255), rgb(255,255,255), rgb(0,0,0), rgb(0,0,0), true, true};
        case Mode::HighContrastLight:
            return {rgb(255,255,255), rgb(255,255,255), rgb(230,230,230), rgb(0,0,0), rgb(32,32,32), rgb(0,0,0),
                    rgb(0,0,179), rgb(0,90,0), rgb(0,0,0), rgb(255,255,255), rgb(255,255,255), false, true};
        case Mode::FollowWindows:
        default:
            return resolve(windowsDark ? Mode::Dark : Mode::Light, windowsDark);
    }
}

inline double linearChannel(unsigned value) {
    const double channel = double(value & 0xffu) / 255.0;
    return channel <= 0.04045 ? channel / 12.92 : std::pow((channel + 0.055) / 1.055, 2.4);
}

inline double luminance(Color color) {
    return 0.2126 * linearChannel((color >> 16) & 0xffu) +
           0.7152 * linearChannel((color >> 8) & 0xffu) +
           0.0722 * linearChannel(color & 0xffu);
}

inline double contrastRatio(Color first, Color second) {
    const double a = luminance(first), b = luminance(second);
    return (std::max(a,b) + 0.05) / (std::min(a,b) + 0.05);
}

inline bool parseHexColor(std::string_view text, Color& color) {
    if (text.size() == 7 && text.front() == '#') text.remove_prefix(1);
    if (text.size() != 6) return false;
    Color parsed = 0;
    for (char value : text) {
        unsigned digit;
        if (value >= '0' && value <= '9') digit = unsigned(value - '0');
        else if (value >= 'a' && value <= 'f') digit = unsigned(value - 'a' + 10);
        else if (value >= 'A' && value <= 'F') digit = unsigned(value - 'A' + 10);
        else return false;
        parsed = (parsed << 4) | digit;
    }
    color = parsed;
    return true;
}

inline std::string formatHexColor(Color color) {
    static constexpr char digits[] = "0123456789ABCDEF";
    std::string result(7, '#');
    color &= 0x00ffffffu;
    for (int i = 0; i < 6; ++i) result[i + 1] = digits[(color >> ((5 - i) * 4)) & 0xfu];
    return result;
}

inline Color readableButtonText(Color background) {
    constexpr Color black = rgb(0, 0, 0), white = rgb(255, 255, 255);
    return contrastRatio(black, background) >= contrastRatio(white, background) ? black : white;
}

// Status text can share the selected accent's hue without sacrificing readable text contrast. The saved accent itself is never
// changed; only this text rendering colour is moved the shortest distance in sRGB towards black or white when needed.
inline Color readableAccentText(Color accent, Color background, double minimumContrast = 4.5) {
    if (contrastRatio(accent, background) >= minimumContrast) return accent;
    const Color endpoints[] = {rgb(0, 0, 0), rgb(255, 255, 255)};
    Color best = accent;
    double bestAmount = 2.0;
    for (Color endpoint : endpoints) {
        if (contrastRatio(endpoint, background) < minimumContrast) continue;
        double low = 0.0, high = 1.0;
        for (int i = 0; i < 24; ++i) {
            const double amount = (low + high) / 2.0;
            auto blend = [&](unsigned shift) {
                const double start = double((accent >> shift) & 0xffu);
                const double finish = double((endpoint >> shift) & 0xffu);
                return unsigned(std::lround(start + (finish - start) * amount));
            };
            Color candidate = rgb(blend(16), blend(8), blend(0));
            if (contrastRatio(candidate, background) >= minimumContrast) high = amount;
            else low = amount;
        }
        auto blend = [&](unsigned shift) {
            const double start = double((accent >> shift) & 0xffu);
            const double finish = double((endpoint >> shift) & 0xffu);
            return unsigned(std::lround(start + (finish - start) * high));
        };
        Color candidate = rgb(blend(16), blend(8), blend(0));
        if (high < bestAmount) { best = candidate; bestAmount = high; }
    }
    return best;
}

} // namespace eye::theme
