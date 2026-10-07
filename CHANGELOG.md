# Changelog

## 1.0.6

Changed

- Settings has a redesigned layout. The top-level tabs (Timer, History, Settings) and the section buttons (Intervals, Alarm, Reminders, General, About) are now visibly different levels: the tabs form a bar with an accent underline on the selected tab, and the section buttons are smaller, quieter segments that wrap onto a second row instead of being clipped.
- The tab bar, section buttons, page heading, form, History list and divider share one centred column (at most 640 logical px wide), so they line up on the same left and right edges at every window size. The Settings scroll bar sits inside that column, at the right edge of the content, instead of at the far edge of the window.
- Settings forms use a shared grid: a caption sits beside its field when the column is wide enough and above it when it is not, fields run to the same right edge, and spacing is more consistent between headings, hints, checkboxes and buttons.
- The alarm dropdown and number fields use dark styling that matches the rest of the page. The volume slider is redrawn as a thin track with a round thumb and has a percentage readout aligned to the right edge.
- "Preview alarm" is the main action and "Stop preview" sits beside it; Stop is enabled only while a sound is playing.
- Layout calculations use the window's DPI and the Windows text-size setting more consistently, so the page reflows at larger scales and text sizes instead of overlapping.

Fixed

- Stale or ghosted pixels while resizing the window (a duplicated tab, fragments of the timer ring, split text, leftover button edges) no longer remain. The main and Settings windows now repaint when their size changes, and controls are repositioned in one batch that repaints them completely, instead of moving old pixels along with them. Scrolling keeps its cheaper repaint.
- Dropdown, scrolling and focus behaviour from 1.0.5 is preserved in the new layout: dropdown lists use their real height, the mouse wheel over a closed dropdown scrolls the page, and keyboard focus stays within the visible section.

Also

- Added core tests for the new layout geometry (the shared column, tab and section rows, and form placement across DPI scales and window widths); 5807 core assertions in total. Release verification and its limits are recorded in `docs/VERIFICATION.md`.

## 1.0.5

- Settings are grouped into five sections (Intervals, Alarm, Reminders, General, About) chosen from a row of buttons above the page, so far less scrolling is needed. Each section scrolls on its own when the window is small, and Tab, arrow keys and the scroll position stay inside the visible section.
- Dropdowns no longer carry 220 px of hidden window height. They use their real height and ask Windows for eight visible rows, which removes an invisible area that overlapped the controls below. The mouse wheel scrolls the page over a closed dropdown instead of changing its value, and still scrolls the list while it is open.
- Long push-button captions end in an ellipsis instead of being clipped at large text sizes.
- Layout was re-checked at 100% and 150% scaling.

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
