# Eye Break Reminder v1.2.0 — final pre-release verification

**Verification date:** 2026-11-11
**Published baseline:** v1.1.0
**Feature branch:** feature/v1.2.0-theme-accessibility-break-mode
**Exact final Windows test commit:** e61068b33f095db9212d8f86bf1787b1fdf34099
**Release publication:** Not performed. No release was created, no asset was published, and main was not changed.

## Final result

The final successful hosted Windows run is [GitHub Actions run 43068233585](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/43068233585). Its evidence artifact is [eye-break-reminder-v1.2.0-pre-release-evidence-43068233585](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/43068233585/artifacts/13877116807) (30-day retention).

The acceptance JSON records **304 PASS, 0 FAIL, 10 NOT TESTED**. These are event counts from tests/windows_pre_release_acceptance.ps1, not counts of broad test groups. The runner also completed:

- C++17 core suite: 6,680 assertions passed.
- Existing native Win32 GUI acceptance: 128 assertions passed; 37 screenshots.
- Binary/package verifier on the runner-built packages: 88 assertions passed.
- Installed-app acceptance: 304 passing events; no assertion failures.

The test result is not a blanket release approval. The no-argument uninstaller invocation exited without showing a wizard or removing files; its explicit silent uninstall path did remove the installation completely. That interactive behavior remains unresolved and is called out below. Do not treat the silent-uninstall result as proof that the ordinary interactive uninstall flow works.

## Environment and isolation

The workflow ran on a disposable GitHub-hosted Windows Server 2025 Datacenter runner (10.0.26100, build 26100), session 2. Explorer and the taskbar were present, and the capability probe confirmed an interactive desktop. The real installer and installed production application were launched in that session. Windows appearance settings were restored after their tests; the hosted runner was discarded afterward.

The testing workflow was adapted from the read-only inspection of the Exercise Break Reminder Windows automation. That repository and application were not modified. No local installed Eye Break Reminder application or personal application data was used.

The runner is Windows Server 2025, not a Windows 11 client VM. Its build meets the installer’s minimum build check, but results that specifically depend on Windows 11 client behavior should be confirmed in an isolated Windows 11 VM.

## Test matrix

| Result | Test group | Evidence |
|---|---|---|
| PASS | Runner and project isolation | The disposable user profile, install paths, shortcuts, app registry keys, startup entry, and processes were empty before testing. |
| PASS | Production build and package checks | The runner rebuilt the C++17 executable, NSIS 3.11 installer, portable ZIP, source ZIP, and SHA-256 manifest. The package verifier passed 88 assertions. |
| PASS | Core regression | 6,680 core assertions passed. |
| PASS | Existing visible Win32 GUI suite | 128 assertions passed and 37 screenshots were captured. |
| PASS | Installer wizard and fresh install | The production installer wizard was visibly captured and advanced through its pages. The install completed at the per-user path, registered version 1.2.0, created the Start Menu shortcut, and launched the installed executable. |
| PASS | Fresh-install application flow | The installed application exposed Timer, History, and Settings through Windows UI Automation. Settings, theme, schedule, history, and timer state were exercised. Settings and history remained after app restart. |
| PASS | Update checker against live GitHub | An unauthenticated HTTPS request to the official Releases API returned HTTP 200 and stable tag v1.1.0. The actual installed app displayed v1.1.0, said installed v1.2.0 was newer, kept the release button disabled, and did not suggest a downgrade. Its main window remained responsive during the request. |
| PASS | Windows appearance and Forced Colors | Follow Windows Theme changed the installed app palette after actual per-user light/dark preference changes. High Contrast was enabled through the Windows SPI API; the active screenshot showed the Forced Colors palette, and the sampled window and screen pixels matched. The system setting was restored. |
| PASS | Accessibility and scaling | UI Automation names and focus properties were inspected; keyboard navigation was exercised. High-contrast focus was captured. The runner tested 96 DPI against the earlier 144-DPI run, and Windows TextScaleFactor 150 increased the button height from 36 to 45 pixels. Text scale was restored. |
| PASS | Timer geometry and resizing | The status text centre matched the timer-ring centre at 96 DPI (0 px); resizes measured 0.5 px and 0 px. At 150% text scale the measured difference was 0 px. The earlier 144-DPI run measured 0 px. |
| PASS | PrintWindow investigation | In the active desktop capture, Timer, History, and Settings captions are visible. The PrintWindow image omits those captions. This indicates a PrintWindow capture limitation, not a repaint defect in the live window. Both images are in the evidence bundle. |
| PASS | Tray lifecycle | The real Explorer tray icon and native #32768 menu were opened. Pause, Resume, Take a break, Open, and Exit commands were selected and invoked. Closing hid the app to tray, reopening restored it, and a second launch routed to the existing instance (one process). |
| PASS | Actual reminder and snooze timing | With a one-minute work interval, the hidden app entered break mode after 60.1 seconds. A one-minute snooze produced the next reminder after 59.1 seconds; dismissing it returned the timer to work. The in-app reminder window was captured. |
| PASS | Fresh uninstall and reinstall | The uninstaller executable was invoked without arguments, then its explicit /S path was used. The silent path removed the executable, install directory, shortcuts, registry entries, and startup entry. Reinstallation succeeded, the app launched from its shortcut, and the selected Light theme plus settings/history data remained. |
| PASS | Official v1.1.0 to v1.2.0 upgrade | The official v1.1.0 installer was downloaded from the Eye Break Reminder release and its SHA-256 matched the release metadata. A real v1.1.0 install was configured with a 7-minute work interval, 45-second break, disabled alarm, startup enabled, and one history record. The in-place v1.2.0 upgrade preserved these settings, history bytes, and exactly one startup registration. v1.1.0 theme value 0 (“Use system setting”) remained value 0 and appeared as “Follow Windows Theme” in v1.2.0. Post-upgrade silent uninstall removed the installed files and registrations. |
| NOT TESTED | Interactive uninstaller wizard | The no-argument Uninstall.exe process exited with code 0 without exposing a visible wizard and left the files in place. Explicit /S completed removal. The ordinary interactive wizard behavior needs confirmation in an isolated Windows 11 client VM. |
| NOT TESTED | Narrator or screen-reader speech | UI Automation names and focus were inspected. No speech engine was started or verified. |
| NOT TESTED | Close-to-tray explanation text through native controls | The native dialog was visible and captured, but Windows did not expose its instruction text through GetWindowText. The screenshot was visually inspected. |
| NOT TESTED | Windows Shell toast | No separate Windows toast surface was observed. The real in-app break reminder is not counted as a toast. |
| NOT TESTED | Production audio playback | No verified physical speaker hardware was available; alarm playback was not physically verified. |
| NOT TESTED | Real workstation lock/unlock | Not attempted because locking a hosted runner can strand its session. Existing synthetic lifecycle tests are not a physical lock test. |
| NOT TESTED | Physical sleep/resume | Not attempted because a hosted runner has no controlled wake guarantee. |
| NOT TESTED | Multiple-monitor layout | The runner exposed one monitor; no additional physical or virtual display was available. |
| NOT TESTED | Physical speaker output | No verified speaker hardware was available. This is recorded separately from the unattended production alarm playback check. |

## Installer, upgrade, update, and appearance detail

The actual v1.2.0 setup wizard rendered through the interactive desktop. The installed executable’s metadata and Installed Apps registration were 1.2.0, the Start Menu shortcut resolved to the installed executable, and the executable launched with a visible Win32 window.

The live release endpoint was https://api.github.com/repos/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/latest. It returned stable release v1.1.0 and the official page https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/tag/v1.1.0. The app correctly classified installed v1.2.0 as newer.

Follow Windows Theme was tested against actual Windows light/dark preference changes. Forced Colors was enabled in Windows and confirmed in the live screenshot: the app’s window pixel and the captured screen pixel were both 0x00202020. The runner restored High Contrast, light/dark, and text-scale preferences after testing.

The direct active desktop screenshot of the timer shows the full navigation labels. The paired PrintWindow image does not. The app’s main window was active and visibly painted correctly; no UI code change was made for a capture-only discrepancy.

The tray menu screenshot file did not preserve the transient popup pixels reliably. The actual popup HWND, bounds, native row selection, and successful command invocation are present in the test log and acceptance JSON; the PNG should not be used as visual proof of the menu contents.

## Evidence

The final evidence artifact contains the acceptance JSON, runner capability record, transcript/logs, release artifact identity JSON, 37 GUI screenshots, and 27 installed-app/installer screenshots. The action run and its artifact are linked above.

After downloading the evidence artifact, the local ignored copy is under:

- build/pre-release-evidence-43068233585/eye-break-reminder-v1.2.0-pre-release-evidence-43068233585/pre-release-evidence/
- build/pre-release-evidence-43068233585/eye-break-reminder-v1.2.0-pre-release-evidence-43068233585/gui-test/evidence/

Key images include:

- pre-release-evidence/v1.2.0 production installer-wizard-first-page.png
- pre-release-evidence/installed-timer-work-active.png
- pre-release-evidence/installed-timer-printwindow-comparison.png
- pre-release-evidence/installed-reminder-active.png
- pre-release-evidence/follow-windows-forced-colors-active.png
- pre-release-evidence/tray-close-to-tray-explanation.png
- pre-release-evidence/upgrade-v11-history-statistics-active.png
- gui-test/evidence/settings-high-contrast-visible-focus.png
- gui-test/evidence/reminder-high-contrast-dark.png

These files are ignored local test outputs; the GitHub Actions evidence artifact is retained for 30 days.

## Artifacts and integrity

The final Windows run rebuilt the following artifacts from test commit e61068b33f095db9212d8f86bf1787b1fdf34099. These runner outputs were the build inputs for the tested installer/application. The workflow retains the identity JSON and hashes as evidence, not the release binaries themselves; it does not upload release assets.

| Runner-built artifact | Size | SHA-256 |
|---|---:|---|
| release/EyeBreakReminder.exe | 2,640,896 bytes | cbf411eec57a7ddca95b5ff306d5633d16f0ca767d6283dffea1a755213ca413 |
| release/EyeBreakReminder-Setup-x64.exe | 1,308,847 bytes | a87044f5beed44e57c826b3354df1b8e8cabb2da3996ab2815c8bd0d8068a557 |
| release/EyeBreakReminder-Portable-x64.zip | 1,463,135 bytes | 55c051dd70faed0917e4ba02d3752741db358307d8620b5383c28b38b0f869ee |
| release/EyeBreakReminder-Source.zip | 1,000,336 bytes | 4a6333710c6fe443913cb9daa9a530b26b018a1daf9754b81f49bb03d8ac36d0 |
| release/EyeBreakReminder-SHA256.txt | 382 bytes | 5e2b5d9e1d9be79aac7a030aa9bdbcb9bc8f3cc32ec372511b550a330a48bf8a |

The local release directory also contains a separately prepared artifact set. scripts/package.py refreshed its portable ZIP, source ZIP, and manifest from the current branch; scripts/verify.py then passed 88 assertions. Those local executable/installer hashes differ from the runner-built hashes, so these two build sets must not be mixed:

| Local prepared artifact | Size | SHA-256 |
|---|---:|---|
| release/EyeBreakReminder.exe | 2,604,032 bytes | 6ad0b65d1a5a6d8e44a661829235f8aeb9c241340684c640390ca1b713b480f4 |
| release/EyeBreakReminder-Setup-x64.exe | 1,396,337 bytes | fe37bc697f70305592522f2e1eaa2617ee4d5300f54069e82af43cf16343dc39 |
| release/EyeBreakReminder-Portable-x64.zip | 1,448,917 bytes | 922abdf60678cd73fa5e50b6652e1b5dceb432185ec6033e973223d0234d84ba |
| release/EyeBreakReminder-Source.zip | 1,000,209 bytes | 0694e37e07ae42e810f0efbbd97225cd2a0fd4ef93cd077e7e4c84214ebb6901 |
| release/EyeBreakReminder-SHA256.txt | 382 bytes | 3133c1970dadbc94d93de201f26fd424b54ddca0f8cd9ef24cab8cdc9c480b65 |

The local set passed version, architecture, dependency allowlist, resource, package contents, byte identity, and hash checks. Its installer was not the binary installed in the hosted Windows workflow. The v1.2.0 executable and installer are unsigned. NSIS reported warning 9100 because no LegalCopyright value is supplied; no publisher identity was invented.

## Test harness corrections and product changes

No application source or installer script was changed during this validation. Two test assumptions were corrected:

1. The OS appearance test selected Follow Windows; it now restores Light before the reinstall-persistence assertion.
2. The v1.1.0 source defines theme value 0 as “Use system setting.” The upgrade test now checks that v1.2.0 preserves that value as Follow Windows rather than incorrectly expecting Dark.

The uninstaller test now checks that the app process is stopped, allows a short file-removal interval, records remnants, and verifies the explicit silent path when the runner does not expose an interactive uninstaller window.

## Remaining validation procedure

Before publication, use an isolated Windows 11 client VM (not the live user profile) to repeat the no-argument launch of the installed Uninstall.exe and confirm whether a visible wizard appears and removes the install. If it again exits without a UI and leaves files behind, fix the NSIS uninstall flow, add regression coverage, rebuild, and retest.

For the remaining environment-only checks, use that disposable VM for lock/unlock, sleep/resume, and an additional monitor if the VM supports one. Verify Narrator speech with a real screen-reader session. Verify audio with a physical speaker or a clearly identified audio test sink. Keep shell toast testing separate from the in-app reminder window.

## Release decision

**Not ready for publication approval yet.** Fresh install, silent uninstall/reinstall, official v1.1.0 upgrade, live update checking, theme/Forced Colors integration, tray actions, timer/snooze, core/GUI/package regression, and artifact identities are verified. The no-argument uninstaller behavior needs confirmation or correction in a Windows 11 client VM; Narrator, toast presentation, physical audio, lock/sleep, and multi-monitor behavior remain untested. No release has been published.
