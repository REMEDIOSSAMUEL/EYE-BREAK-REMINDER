# Eye Break Reminder 1.0.6 — Windows 11 x64

A native Windows desktop eye-break utility, compiled from Linux with C++17 and MinGW-w64. It uses Win32 system controls, Windows common dialogs, native title bars, native tray integration, and a custom timer dial. It has no browser, console, .NET dependency or external assets at runtime.

## Install or run

**Installer:** double-click `EyeBreakReminder-Setup-x64.exe`. It installs for your current Windows account, creates a Start Menu entry, offers a desktop shortcut and registers in Installed Apps. No administrator permission is requested. Uninstall through Windows Settings → Apps → Installed apps. Direct upgrades preserve the current countdown, preferences and history. Uninstall ends the countdown and removes startup registration owned by this installation, while keeping preferences and history. A fresh reinstall starts a full work interval, including when an older uninstaller left a timer checkpoint behind.

**Portable:** extract `EyeBreakReminder-Portable-x64.zip` and double-click `EyeBreakReminder.exe`. You can also use the separately supplied `EyeBreakReminder.exe` directly: its icon and five sounds are embedded. No compiler or SDK is needed to run it. Only Windows 11 on a native x64 operating system is supported.

**Signing:** this build is unsigned. No trusted signing certificate or publisher identity was supplied. Windows may show its normal warnings for unsigned downloads; this project does not change or bypass Windows security.

## Controls

The default schedule is 20 minutes of work followed by 20 seconds looking roughly 20 feet / 6 metres away. Use Pause/Resume, Reset and Take a break now. The break window offers I'm back, Skip and snooze for 1, 3 or 5 minutes. A completed countdown automatically begins new work. Closing a break or Escape records a skip. Snooze is not counted as completed or skipped. Duration changes take effect in the next cycle; Reset applies the new work interval immediately.

Timer, History and Settings are available through native navigation buttons. Ctrl+R resets; Ctrl+Shift+B starts a break; Ctrl+comma opens Settings. Standard Tab/Shift+Tab, Enter, Space and native arrow-key behaviour apply. Timer/break text uses native STATIC controls for accessibility; Settings are split into Intervals, Schedule, Alarm, Reminders, General and About sections, and use native buttons, checkboxes, spin edits, time fields, combos and a volume slider. History is a native list view.

Closing/minimizing hides the main window to the tray by default. First close explains this. Left-click opens; right-click provides timer, alarm, settings and Exit commands. Exit stops the process. If the tray is unavailable, the main window stays accessible. Startup at sign-in is explicitly opt-in and can be disabled in Settings. Disable startup before moving/deleting a portable executable.

Normal break windows are the default. Compact and explicitly selected fullscreen modes can use the active, primary or selected display. A disconnected selection falls back to the primary display. The app requests attention once per break and does not keep itself topmost. Shell notifications provide click-to-open when hidden/minimized, with no duplicate notification sound; Windows may suppress them. They are not actionable toast notifications and do not promise Notification Center persistence.

Alarm choices are Gentle, Bell, Chime, Clear and Soft. Volume scales this app's PCM samples, leaving global Windows volume alone. Preview and Stop preview are provided. Optional repeat lasts until the break ends or is acknowledged; pause also stops the sound. The same alarm plays once more when a break runs to zero by itself, also while the app is hidden in the tray; skipping, acknowledging early, snoozing, resetting, pausing, and recovery after sleep, lock or restart do not play it, and turning the alarm off silences both. Audio uses the default Windows output.

Light, dark and system themes set app surfaces and the native title bar. Buttons use rounded surfaces, blue primary actions and a selected-tab outline. Checkboxes and input colors follow the app palette; section headings, input padding and compact labels make Settings easier to scan. Native control behavior is retained, and high contrast falls back to Windows button rendering. Dropdowns, sliders and scrollbars retain their native Windows presentation. Native controls, high contrast, Windows text scaling and per-monitor DPI are supported in source but need the Windows runtime checks below.

## Operating schedule

*Unreleased: added to the source after 1.0.6 and not part of the published 1.0.6 downloads (see CHANGELOG.md).*

The operating schedule limits automatic eye-break reminders to the days and hours you choose, for example Monday to Friday 09:00–17:00, Saturday 10:00–14:00 and Sunday off. It is **off by default**, including after upgrading, and while it is off the app behaves exactly as before.

**Setting it up:** open Settings → Schedule and tick **Enable operating schedule**. Under Weekly hours, tick each day that should have reminders and type its hours in 24-hour local time (`09:00`, `17:30`; `9`, `930` and `9.30` are also understood). A day can have up to three periods: **Add period** appends one and **Remove** deletes one. Quick setup offers *Weekdays 09:00–17:00* and *Every day 09:00–17:00*; both ask before replacing the hours you have. An unticked day keeps its hours (greyed out) so you can switch it back on later. The initial hours are Monday to Friday 09:00–17:00, and they are not active until you enable the schedule. An invalid time (such as `25:00`) or a period with equal start and end is not saved: the field returns to its stored value and a tip explains why. The Status line shows whether reminders are active now and when the hours next end or begin.

**Periods:** a start time is included and an end time is excluded, so 09:00–17:00 is active from 09:00:00 until just before 17:00:00. A period that ends earlier than it starts continues past midnight and belongs to the day it starts on: Monday 22:00–02:00 runs until 02:00 on Tuesday, even if Tuesday is unticked, and Sunday 22:00–02:00 continues into Monday. Use 00:00 to 24:00 for a whole day; 00:00 to 00:00 is rejected rather than read as a whole day. Overlapping or touching periods (09:00–12:00 and 12:00–17:00, or Monday 18:00–24:00 and Tuesday 00:00–05:00) count as one continuous period.

**Outside operating hours** the work countdown stands still and shows *On hold*, and the Timer page and tray tooltip say *Outside scheduled hours* together with the next start. No automatic break, alarm, repeated alarm, completion alarm or notification occurs, and missed reminders are not queued. When a period ends, an automatic break or snooze in progress is closed and its sound and notification are cleared; it is **not** recorded as completed or skipped. Breaks completed or skipped earlier stay in history. Pause/Resume, Reset, Settings, History and alarm preview remain available. **Take a break now** still starts a break you ask for, without the alarm, without snooze buttons and without a completion alarm; it is recorded as usual and does not start a reminder cycle. A break you started yourself before the end of a period may run to its end.

**When a period begins** after time outside the schedule, a fresh full work interval starts, so the first reminder comes one work interval later (at 09:20 for 09:00 with 20-minute work), never immediately.

**Pause:** a manual pause is separate from scheduled inactivity. A timer you paused stays paused, with its remaining time, through the end and the next start of operating hours. Resume outside operating hours does not override the schedule: the countdown stays on hold until the next period, which then begins with a fresh interval. With the schedule off, Pause behaves as before.

**The app must be running** (in a window or in the tray) for the schedule to apply. The schedule never starts the app; use *Start with Windows* for that. No Windows service or scheduled task is created.

**Sleep, restart and clock changes:** the schedule uses the Windows time zone and its daylight-saving rules, and is re-checked at every boundary, when Windows reports a time or time-zone change, and at least once a minute. Inside one continuous operating period, sleep, lock and restart recovery work as described below. If a period ended or began while the device slept, was locked or the app was closed, no time outside operating hours is counted, nothing is owed, and work restarts with a fresh interval if a period is open (a manual pause is kept). Changing the clock or the time zone takes effect at once; it never produces a burst of missed reminders. On the night clocks go forward, a period starting in the skipped hour begins when the clock jumps; when clocks go back, the repeated hour is evaluated as the clock shows it, so a period ending in that hour can end, reopen and end again.

## Timing, recovery and data

Countdowns use QueryPerformanceCounter through a testable elapsed-time engine. A worker waits on events/deadlines, independently of GUI rendering. Visible running timers refresh four times per second, or once per second with reduced motion; hidden/paused timers do not render. Timer state is checkpointed every 30 seconds and at transitions.

Sleep counts as elapsed work. Wake produces at most one fresh reminder if work expired. A break that expires during sleep is skipped and fresh work begins. Lock pauses by default; when disabled, lock time counts as elapsed work. Nested lock/sleep respects lock pause. Paused timers remain paused. When “Resume countdown when reopening the app” is enabled, closing and reopening restores valid work/snooze state, deducts downtime, and restores paused work; stale state or an interrupted break becomes fresh work without an immediate startup alarm. Boundary/restart time uses clamped wall-time differences, so clock changes during downtime can affect recovery; ordinary countdowns are monotonic.

The rules above apply inside operating hours or with the operating schedule off; across a scheduled boundary the operating-schedule rules take precedence.

Data stays in `%LOCALAPPDATA%\EyeBreakReminder`: `settings.ini`, `timer.dat` and `history.dat`. The operating schedule is stored in `settings.ini` as integer lines that earlier versions ignore: `schedule=0|1`, `scheduleMonday=0|1` (one per day, Monday to Sunday) and `scheduleMonday1=HHMMHHMM` for periods 1 to 3 (for example `09001700`; `2400` is midnight at the end of the day). Files without these lines load with the schedule off and the default hours. An invalid schedule line is treated like any other corrupt setting. `timer.dat` is unchanged. Writes use flushed temporary files and replacement. Corrupt files are quarantined with `.corrupt`; a native message explains recovery. History retains the latest 10,000 records and displays the latest 100. Statistics use the Windows local calendar and Monday weeks. Clear history and Reset all settings require confirmation. Delete the data folder after quitting if you want to remove personal data completely. Earlier WinUI `.json` files are preserved but are not read by this version.

## Source layout

| Path | Purpose |
|---|---|
| `src/` | Windows UI/integration and shared timer engine |
| `assets/` | Embedded app icon and five alarm sounds |
| `installer/` | Per-user NSIS installer and uninstaller |
| `tests/` | Timer/recovery/serialization tests executable on Linux |
| `scripts/` | Asset generation, version update, packaging and binary verification |
| `docs/` | Privacy, verification, Windows test checklist and release instructions |
| `release/` | Generated downloads, excluded from Git |

See [CHANGELOG.md](CHANGELOG.md) for releases and [CONTRIBUTING.md](CONTRIBUTING.md) for development and commit attribution.

## Build on Windows (MSYS2)

The 1.0.6 release was built on Windows 11 with MSYS2 instead of Linux. The `mingw64` (msvcrt) toolchain is required: `ucrt64` links `api-ms-win-crt-*` DLLs and fails the import check in `scripts/verify.py`. Install `mingw-w64-x86_64-gcc`, `mingw-w64-x86_64-binutils`, `make` and, for the installer, `mingw-w64-i686-nsis`, whose x86 stubs give the 32-bit bootstrap (the `ucrt64` NSIS package has only amd64 stubs). Compared with the Linux commands below:

- pass `WINDRES=windres PYTHON=python` and `CROSS_CXX='x86_64-w64-mingw32-g++ -DWINVER=0x0A00 -D_WIN32_WINNT=0x0A00'` (MSYS2 headers default to an older Windows target and omit `GetDpiForWindow`);
- make `x86_64-w64-mingw32-strip` resolvable (the Makefile hardcodes that name; a copy of `strip.exe` under that name on `PATH` works);
- pass `TMP=C:/msys64/tmp TEMP=C:/msys64/tmp` to `make`, because MSYS `sh` drops them and native GCC then cannot create temporary files;
- native `makensis` needs backslashes in the `File` and `OutFile` paths of `installer/setup.nsi`; build the installer from a backslash-converted copy, run from the repository root with `-NOCD`, then run `make package`;
- run Python with `PYTHONUTF8=1` for `scripts/set-version.py`.

## Build from Linux

On Ubuntu/Debian, install `g++`, `make`, `python3`, `g++-mingw-w64-x86-64`, `binutils-mingw-w64-x86-64`, and `nsis`. From this folder:

```sh
make all      # execute native Linux core tests; cross-compile and strip the Windows x64 GUI EXE
make package  # build graphical installer, portable/source archives and SHA-256 checksums; verify PEs/resources
```

The output is under `release/`. Flags statically link GCC/C++ runtimes, set the Windows GUI subsystem, and enable ASLR/NX/high-entropy VA. Windows DLLs used are built-in system components. Assets are embedded through `resources.rc`; no asset generation is required. `scripts/generate-assets.py` can recreate the icon/sounds with Pillow.

Produced files: `EyeBreakReminder.exe`, `EyeBreakReminder-Setup-x64.exe`, `EyeBreakReminder-Portable-x64.zip`, `EyeBreakReminder-Source.zip`, `EyeBreakReminder-SHA256.txt`.

NSIS uses its standard **32-bit GUI installer bootstrap**, restricted to native Windows 11 x64; it installs the verified **64-bit application**. No 32-bit or ARM64 app is built. The installer filename describes its supported target, not the bootstrap PE architecture.

For a legitimate signing certificate, sign the app before installer packaging, then sign the finished installer using your certificate and a trusted RFC3161 timestamp service (for example Windows SDK `signtool sign /sha1 THUMBPRINT /fd SHA256 /tr TIMESTAMP_URL /td SHA256 FILE`). Verify with `signtool verify /pa /all FILE` and regenerate the hashes after signing. Configure NSIS `!uninstfinalize` with your legitimate signer if a signed uninstaller is required. The downloadable build is unsigned. The repository owner has not yet selected a source license; no publisher/copyright identity is invented. GCC/MinGW runtime and NSIS notices are bundled in `docs/THIRD-PARTY-LICENSES.txt`.

## Verification boundary

The executable and installer are compiled with MinGW-w64 and NSIS, with actual core test execution and binary/resource checks. Releases 1.0.4 and 1.0.5 were launched on a real Windows 11 x64 machine and exercised with scripted input and audio-session measurements; release 1.0.6 was launched there and its live-resize repainting was measured with scripted window sizing and screen capture (see `docs/VERIFICATION.md`). The unreleased operating schedule was exercised on Windows 11 with scripted input, UI Automation and screenshots; sleep, lock, clock and time-zone changes are covered by core tests only. **The installer has not been run, and the interactive UI checklist in `docs/WINDOWS-TESTING.md` has not been completed by a person.** Successful compilation does not establish runtime correctness. See `docs/VERIFICATION.md` and `docs/WINDOWS-TESTING.md` for the actual evidence and open checks.

## Publishing releases

Build locally with `make package`, then publish the verified installer, portable ZIP and checksums as assets on a versioned GitHub Release. Do not commit generated binaries or signing keys to the source tree. The manual process in [docs/RELEASING.md](docs/RELEASING.md) does not use GitHub Actions minutes. Repository owner approval is needed before selecting a source license.
