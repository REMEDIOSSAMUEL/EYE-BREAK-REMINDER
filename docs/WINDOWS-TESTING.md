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

## Operating schedule

Record the Windows time zone, the date, the display scaling and the text size for each run. Use a short work interval (1 minute) and set period ends a few minutes ahead so boundaries can be watched. Back up `%LOCALAPPDATA%\EyeBreakReminder` first if the machine has real data.

- **Schedule off / legacy:** upgrade from 1.0.6 with existing preferences, history and a running countdown. The schedule must be off, the countdown must continue, and reminders, Pause, Reset, Take a break now, snooze, completion alarm, notifications and tray behave exactly as before. Reopen 1.0.6 on the upgraded `settings.ini` and confirm it still loads without a corrupt-data message.
- **Weekday schedule:** enable it with the Weekdays preset. On a weekday inside 09:00–17:00 the Timer page reads "Running — within scheduled hours"; on a weekend it reads "Outside scheduled hours — next period Monday at 09:00", the caption reads "On hold" and the countdown does not move.
- **Different hours per day and several periods:** give two days different hours, add a second and third period to one day, remove a middle period, and untick a day (its fields grey out but keep their values). Restart the app and confirm every value persisted. Try `25:00`, `ab`, `9:5` and equal start and end: the field must revert and a tip must explain why; `9`, `930` and `9.30` must become `09:00`/`09:30`. Enter must store a time without leaving the field.
- **Overnight:** set Monday 22:00–02:00 with Tuesday unticked, and Sunday 22:00–02:00 with Monday unticked. Reminders run until 02:00 the next morning, then stop. Check 00:00–24:00 as a whole day and that 00:00–00:00 is refused.
- **Boundaries, window visible:** let a period end while the countdown runs, during an automatic break (the window must close, the alarm and any repeat must stop and no history row may appear), during a snooze (no reminder may follow) and during a break started with Take a break now (it may finish; no completion alarm after the end). Let the next period begin: no reminder at the start, the first one a full work interval later.
- **Boundaries, hidden in the tray:** repeat the end and start of a period with the window closed to the tray and with it minimized. No break window, sound or Shell notification may appear outside hours; the tray tooltip must say "Outside scheduled hours" (and "Paused, outside scheduled hours" when paused).
- **Manual actions outside hours:** Pause/Resume (Resume must not start the countdown), Reset, Settings, History, alarm preview and Stop preview, Take a break now from the window, the tray menu and Ctrl+Shift+B (break window without snooze buttons and without alarm; Skip and I'm back record history as usual; no reminder follows).
- **Manual pause across boundaries:** pause shortly before a period ends and leave it paused across the next start: it must stay paused with the same remaining time; Resume then continues it.
- **Reconfiguration during a countdown:** extend and shorten the current period, untick today, switch the schedule off and on, use both presets (confirmation appears only when hours would change) and Reset all settings (schedule off, default hours). The countdown must continue when the period stays open and hold at once when it closes.
- **Restart across boundaries:** with "Resume countdown when reopening the app" on, exit inside a period and reopen in the same period (downtime deducted), after the period ended (on hold), and in the next period (fresh interval, no startup alarm). Repeat with a paused timer and with a break open at exit.
- **Sleep and lock:** sleep and lock (lock pause on and off) across an end and across a start, nested lock then sleep and sleep then lock, and repeated wake and unlock. No reminder on waking outside hours, no burst of reminders, a fresh interval when waking into a new period, and a paused timer stays paused.
- **Clock and time zone:** change the time zone so that it becomes outside and then inside hours, change the clock forwards past an end and backwards before it, and leave the app hidden across a daylight-saving change if one is available (or a time zone whose change is near). The state must follow within a minute without reminders bursting or repeating. Leave it running for several days.
- **Appearance and accessibility:** check the Schedule section in light, dark and system themes and with a high-contrast theme (day check boxes, greyed fields, Add period and Remove buttons, focus rectangles). Tab and Shift+Tab through every day; Space toggles days; focused fields scroll into view. With Narrator, each time field must read its day, period and whether it is the start or end time; Remove and Add period must name their day. Turn Windows animations off and check scrolling. Repeat at 100%, 125%, 150%, 175% and 200% scaling and with enlarged text: rows must wrap with each "From"/"to" label beside its field, nothing may clip or overlap, and the smallest window must stay usable. Resize while the section shows (no stale pixels) and check the other sections, History, Timer and About for regressions.
- **Installer and portable:** install over 1.0.6 with a schedule-less `settings.ini`, configure a schedule, upgrade again and confirm it persists; run the portable executable and confirm it reads the same settings.
