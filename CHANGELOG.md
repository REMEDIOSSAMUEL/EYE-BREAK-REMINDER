# Changelog

## 1.0.4

- Smoother scrolling in Settings, History and the break window. Mouse wheel and high-resolution wheel or trackpad input accumulate instead of being dropped, and a short ease-out animation follows the pointer. New input moves the target immediately, so nothing is queued after you stop. Windows' "lines per wheel notch" setting is honoured, and the animation is skipped when Windows animations are turned off.
- Settings controls move in one batch instead of one repaint each, and the wheel works wherever the pointer is over the page, whichever control has keyboard focus. Resizing, DPI changes and text-size changes keep the scroll position and scroll bar inside the content, so no blank area is left behind. Keyboard focus only scrolls the page when focus actually moves, so the page no longer snaps back to a focused control you have scrolled away from.
- History scrolls row by row (a native list view limit) with the same accumulation and easing.
- The selected alarm now also plays once when a break reaches zero on its own, including while the window is minimized or hidden in the tray. It uses the existing sound, volume and alarm on/off setting. Skipping, "I'm back", snoozing, resetting, pausing, and recovery after sleep, lock or restart do not play it.
- Added core tests for the completion event and the scrolling model (94 assertions in total).

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
