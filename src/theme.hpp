#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>

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

} // namespace eye::theme
