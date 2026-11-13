# Settings: themes and custom accent colours

Open **Settings → General** and choose the **Appearance** section.

## Themes

The five existing themes remain available: **Follow Windows Theme**, **Light**, **Dark**, **High Contrast Dark**, and **High Contrast Light**. Theme changes apply immediately and persist in the existing `settings.ini` file.

## Work and break accents

Choose **Choose Colour...** beside **Work Mode colour** or **Break Mode colour**. This opens the native Windows `ChooseColorW` dialog, including basic colours, custom colours, full colour selection, and Red/Green/Blue entry. The swatch displays the selected hexadecimal RGB value.

Work and break colours are independent. In normal themes, the Work Mode colour is used during work. During a break, the Break Mode colour is used when **Use a distinct accent during eye breaks** is enabled; otherwise the Work Mode colour is used for both states. The break status continues to read **Taking an eye break**.

The normal Dark theme defaults are Work `#60A5FA` and Break `#2DD4BF`. The Light theme uses its existing blue and teal accents (`#1D4ED8` and `#0F766E`). High-contrast themes use their accessible palette. With **Follow Windows Theme**, the defaults follow the selected Windows light/dark appearance.

Pressing **OK** applies and saves the choice immediately. Pressing **Cancel** discards the dialog's pending selection. Neither action resets or pauses the timer. Saved colours remain when the theme changes or the application restarts. High contrast and Windows Forced Colors temporarily take priority while keeping custom preferences saved.

## Reset

**Reset to Default Colours** clears the two custom accent overrides and restores the selected theme's built-in accents. It does not change the theme, timer intervals or state, alarm, operating schedule, history, startup, notification, or other settings. The defaults update with later theme changes.

## Compatibility and saved values

Colours are stored as 24-bit `RRGGBB` values in the existing settings file, with separate enabled flags for the Work Mode and Break Mode overrides. Older files that lack these entries use the theme's built-in colours. An invalid or out-of-range colour disables only the affected override and safely uses its default; unrelated settings continue to load.
