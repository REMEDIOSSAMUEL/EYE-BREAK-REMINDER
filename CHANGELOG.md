# Changelog

## 1.0.3

- Fresh installation and uninstall discard the previous timer checkpoint. Direct upgrades retain it; preferences and history are kept.
- Disabling resume-on-reopen starts a fresh timer without a corrupt-data warning.
- Rounded action buttons, clearer selected navigation, themed checkboxes, softer light/dark colors and more compact Settings spacing.
- Added source layout, version management, contribution and manual release documentation. No GitHub Actions build is required.

## 1.0.2

- Tray context menu uses a separate foreground owner and positions above the icon to avoid the hidden-icons flyout.
- Opening Settings from the tray keeps Settings in front during a break.

## 1.0.1

- Made Settings child controls visible.
- Corrected number-field/spin-control layout and clipped pane background painting.

## 1.0.0

- Native C++17/Win32 Windows x64 application, cross-compiled on Linux.
- Timer, pause/reset, breaks, snooze, alarms, tray integration, local history and settings.
- Per-user Windows installer, portable executable and Linux core/binary verification.

All releases are unsigned. Compilation and Linux tests do not substitute for Windows runtime testing; see `docs/VERIFICATION.md`.
