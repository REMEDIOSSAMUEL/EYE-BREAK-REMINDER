# Windows 11 x64 acceptance checks — not yet executed

Record OS build, display scaling, SDK/tool versions and actual results. Do not mark items passed from source inspection.

- Cross-compile x64, execute C++ core tests, package; check EXE GUI subsystem, metadata, icon, and runtime folder.
- Install as a standard user; verify Start Menu, optional desktop shortcut, Installed Apps, upgrade preservation and uninstall/startup cleanup.
- Launch twice, including simultaneous launches and an existing hidden/minimized instance; confirm one timer and user-requested activation.
- Default and custom work/break intervals; pause/resume, reset, early completion, skip, snooze 1/3/5; confirm exactly one alarm/window per due event.
- Five alarm sounds, app volume, mute, preview/stop, repeat until break ends, different audio outputs, absent/muted output.
- Native notification when hidden/minimized, click-to-open, quiet time/Do Not Disturb behaviour, no stale notifications after completion, taskbar/Explorer restart.
- Tray left-click and keyboard context menu, all commands, first close explanation, minimizing, close-to-tray, explicit Exit, unavailable tray handling.
- System/light/dark theme, live system changes, high contrast, accent brushes, title bar, system menu, maximize/restore/Snap, drag region.
- Narrow/wide windows, 100/125/150/175/200% DPI, Windows text scaling, tab order, Narrator names, reduced motion, long countdowns, empty history.
- Normal/compact/fullscreen break modes; active/primary/selected display; different display DPI, disconnected/rearranged monitors, fullscreen opt-in.
- Short and long sleep during work/break/snooze; lock pause on/off; lock then sleep; sleep then lock; duplicate resume messages; system clock changes while running and at suspend boundaries.
- Clean restart, forced termination between checkpoints, paused restart, stale state, corrupt/oversized/read-only JSON, disk-full save failure.
- History outcomes, local midnight/week/streak calculation, history off, clear confirmation, retention bound.
- Offline operation from installer and portable folder with no globally installed third-party runtimes.
- Unsigned and legitimate signed release paths, executable/installer/uninstaller verification, archive contents, SHA-256 checksums.

A Linux MinGW-w64 cross-compiler was used successfully; no genuine Windows 11 runtime was available. All UI, lifecycle, installer and audio/notification acceptance checks remain open until executed.

## Settings-page regression (1.0.1)

- Open Settings using the navigation button and Ctrl+comma. Verify labels, both number edits, spin arrows, checkboxes, dropdowns, volume slider and preview buttons appear.
- Scroll to Appearance, Behaviour and About; verify version 1.0.1 and that text and controls remain visible. Resize and repeat at 100%, 150% and 200% display scaling.
- Switch between Timer, History and Settings repeatedly; ensure only the selected page is visible and settings values persist.
- Change each number with typing and spin arrows, reset all settings, and repeat the visibility checks.

## Tray-menu regression (1.0.2)

- With the app hidden, right-click its icon inside the Windows hidden-icons flyout. Verify the whole menu including Settings and Exit appears above the flyout and every item is clickable.
- Repeat with the icon pinned directly on the taskbar, with the main window visible or minimized, and on displays with 100%, 150% and 200% scaling.
- Invoke the tray context menu from the keyboard. Check Escape and clicking outside dismiss it, then repeat opening/cancelling multiple times.
- Select Settings, Open, Pause/Resume, alarm toggle, Take a break and Exit. Settings must be foreground even during a break; the main window must not stay always-on-top afterward.

## Reinstall and controls regression (1.0.3)

- Install an older release, change preferences, record some history and let work count down. Uninstall it and install 1.0.3: the work interval must start fresh; preferences/history must remain.
- Uninstall 1.0.3, verify `timer.dat` is removed, reinstall and verify fresh work. Upgrade 1.0.3 directly without uninstall: a valid current timer should resume.
- Disable resume-on-reopen, exit and relaunch: verify full work time and no corrupt-data warning. Enable it and verify normal restart recovery.
- Check rounded buttons, selected tabs, checkbox ticks, editable number fields, keyboard focus, disabled controls and accelerator cues under light/dark/system themes and high contrast.
- Repeat Settings scrolling, focus and multiline text checks at 100%, 150%, 200% display scaling and enlarged Windows text.
