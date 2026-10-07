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

## Scrolling and completion alarm (1.0.4)

Automated checks for these were run on Windows 11 and are recorded in `docs/VERIFICATION.md`. A person should still confirm the feel and the cases that could not be scripted:

- Scroll Settings, History and a shortened break window with a real mouse wheel, a precision touchpad and a high-resolution wheel. Scrolling should feel smooth, stop promptly when input stops, and never flicker, leave blank areas or misplace controls. Repeat at 100%, 150% and 200% scaling, with enlarged Windows text, and on a second monitor with different scaling.
- Turn Windows animations off (Settings, Accessibility, Visual effects). Scrolling must jump straight to the destination.
- Drag the scroll bar thumb, click the arrows and track, and use Tab and Shift+Tab. Click controls while and just after scrolling.
- Let a real break finish with the window visible, minimized and hidden in the tray: exactly one completion alarm, using the selected sound and volume. Confirm no completion alarm after Skip, "I'm back", Pause, Reset or Snooze, with the alarm muted, and after sleeping, locking or restarting during a break.
- Install 1.0.4 over 1.0.3 and confirm the countdown, preferences and history carry over.

## Settings sections and dropdowns (1.0.5)

- Switch between Intervals, Alarm, Reminders, General and About with the mouse and with Tab and the arrow keys. Only that section's controls may appear; changing a setting in one section and returning must show it unchanged.
- Shrink the window until a section scrolls, then check the wheel, scroll bar and keyboard focus in each section. Repeat at 100%, 150% and 200% scaling, with enlarged Windows text, in light, dark and high-contrast themes.
- Open every dropdown: the whole list must be visible, selectable by mouse and keyboard, and must not leave an invisible area that blocks controls beneath it. The wheel over a closed dropdown must scroll the page, not change the value.
- Check section button captions at large text sizes: they must truncate with an ellipsis, not clip.

## Settings layout and live resizing (1.0.6)

- Drag the window edge and corners slowly and quickly, in and out of the smallest size, on Timer, History and every Settings section. No duplicated tab, ring fragment, split text or leftover button edge may remain once the drag stops, and nothing may flash white or black during it. Repeat at 100%, 150% and 200% scaling.
- On Settings, the Timer/History/Settings tab bar, the section buttons, the page heading and the form must share the same left and right edges at every window width; the scroll bar must appear inside that column, beside the content, and not at the far window edge.
- Narrow the window until the section buttons wrap to a second row and the form moves captions above their fields; both must stay readable and aligned. Repeat with enlarged Windows text.
- Alarm section: the dropdown must be dark in the dark theme and its whole list visible; the volume slider and its percentage must line up with the other fields; Preview alarm plays the selected sound, Stop preview is enabled only while it plays and stops it, and focus never lands on a disabled Stop button.
- Check high-contrast themes for the tab bar, section buttons, slider and focus rings; these use custom drawing that has not been inspected in high contrast.
