# Eye Break Reminder v1.2.0 — final pre-release verification

**Verification date:** 2026-11-11

**Published baseline:** v1.1.0 (per the project release record and the requested baseline; the live endpoint could not be reached from this host)

**Feature branch:** `feature/v1.2.0-theme-accessibility-break-mode`

**Application and packaging source commit exercised:** `84d906917bd3790c4d280d10354d865fb06fa12a`. This adds only the Source ZIP self-reference exclusion and its verifier assertion on top of feature commit `622a9f1f72c8f420d4f274cdaaf9693c52fa1c68`. This report is committed afterward and excluded from the Source ZIP; it does not change executable inputs.
**Release publication:** Not performed. No release was created and `main` was not changed.

## Scope and environment

All work used the existing `release/worktree-v1.2.0` worktree on the v1.2.0 feature branch. The worktree was clean and matched its configured upstream before this verification began. The actual installed application and its personal data were not opened or modified. GUI work used the distinct `build/gui-test/EyeBreakReminder.exe` test build, test mutex, and `build/gui-test/test-data` profile.

The host registry reported `ProductName=Windows 10 Pro`, `DisplayVersion=26H2`, build `26300.9974`; these fields do not identify a consistent marketed Windows release, so no stronger Windows-version claim is made. The GUI test process reported 144 DPI (150% scaling) and Windows text scale 100%.

No disposable VM, Windows Sandbox, or isolated Windows profile was available. The live installation and personal profile were therefore not used for installer, upgrade, shell, startup, lock, sleep, or display-configuration tests. The in-app browser/computer-use native desktop pipe was also unavailable. These constraints are reflected as **NOT TESTED** below.

## Test matrix

Counts below treat each matrix row as one test group. Assertion totals from the suites are reported separately. **PASS** means that the listed test actually ran and its assertions succeeded. **NOT TESTED** means there is no runtime evidence for that operation. No product assertion failed in the final completed suites.

| Result | Test group | Evidence / outcome |
|---|---|---|
| PASS | Branch and project isolation | Confirmed the Eye Break Reminder v1.2.0 feature worktree and upstream. No Exercise Break Reminder files/repository, `main`, published v1.1.0 assets, or live user data were touched. |
| PASS | Core regression suite | `make clean package` ran the native C++17 core suite; 6,680 assertions passed. |
| PASS | Visible Win32 GUI acceptance | `tests/gui_acceptance.ps1` ran against the isolated test build: 128 assertions passed; 37 screenshots were captured. |
| PASS | Themes, break visuals, and settings persistence | Dark, Light, High Contrast Dark, High Contrast Light, and Follow Windows were exercised in the actual application; break/work colours, reminder windows, accent opt-out, and theme persistence after relaunch were checked. |
| PASS | Timer status geometry and resizing | Running, Paused, Snoozed, and break status bounds were measured against the ring at 144 DPI. The recorded centre difference was 0 px for tested states and both resize targets (680×660 and 1100×820). |
| PASS | Timer explanatory text and dynamic schedule | The redundant 20-20-20 explanatory sentence was absent in the Timer screenshots; the two retained footer lines remained. The configured `2 min work, 30 sec rest` schedule was reflected in the visible footer. |
| PASS | Update-checker controlled responses | Same, newer, and older stable versions; prerelease; 404/private-or-not-found; rate limit; offline; timeout; TLS failure; and invalid JSON fixtures were exercised. The v1.1.0 fixture correctly reported that installed v1.2.0 was newer and left the release button disabled. Busy state and release-link behavior were checked. |
| PASS | Update-checker responsiveness and honest failure | The real application request returned an offline error instead of claiming it was current. The timer continued during the asynchronous request in the same-version fixture (10,785 to 10,763 seconds). |
| PASS | Fresh application launch and UI Automation | A separate isolated test launch exposed Timer, History, and Settings navigation through Windows UI Automation. The three native navigation controls remained visible and enabled before, during, and after a test break. |
| PASS | Screenshot evidence | 37 screenshots were captured. Representative Timer, break, reminder, History, Settings, high-contrast focus, and update-checker screenshots were opened and inspected. Files are in `build/gui-test/evidence/` on the local worktree. |
| PASS | Release build and package verification | `make clean package` rebuilt the executable, NSIS installer, portable ZIP, source ZIP, and SHA-256 manifest. The binary/package verifier passed 86 assertions for PE identity, dependencies, resources, package contents, version and digests. These checks inspect artifacts; they are not an installer runtime test. |
| NOT TESTED | Real install, uninstall, reinstall, wizard, shortcuts, installed launch, and runtime dependency execution | No disposable Windows install target was available; the live installation was deliberately left untouched. PE and installer package checks are not installation evidence. |
| NOT TESTED | v1.1.0-to-v1.2.0 upgrade and migration | Settings, history, statistics, startup preference, duplicate registration, and installed-version migration were not tested in an isolated installation. |
| NOT TESTED | Successful live GitHub Releases response | The official HTTPS API request was attempted, but this host rejected the socket. The app displayed `Could not reach GitHub. Check your internet connection.` No live JSON or current release comparison was obtained. |
| NOT TESTED | Real OS appearance switching and Forced Colors | The app's Follow Windows repaint response to a synthetic `WM_THEMECHANGED` message was checked. Windows dark/light settings were not changed, and Windows High Contrast/Forced Colors was not toggled. |
| NOT TESTED | Additional DPI and Windows text scales | Only 150% DPI and 100% text scale were available to this run. Other real DPI/text-scale configurations were not exercised. |
| NOT TESTED | Full keyboard-only navigation and screen-reader speech | A high-contrast keyboard focus indicator was captured, and navigation names were exposed through UI Automation. The desktop could not acquire focus for a full synthetic Tab sequence; Narrator or other screen-reader speech was not tested. |
| NOT TESTED | Real system-tray menu, single-instance behavior, hide/reopen, and tray exit | The automation desktop had no interactive `Shell_TrayWnd`; `Shell_NotifyIconGetRect` returned `E_FAIL` during an initial probe. The corrected probe recorded the shell integration as not testable. No tray menu workflow is claimed. |
| NOT TESTED | Windows Shell toast surface | The in-app break reminder window was visibly exercised and captured. No Windows toast was observed or claimed. |
| NOT TESTED | Physical speaker output | Audio hardware was not tested. The GUI suite disabled the alarm to keep automated runs quiet; no hardware playback claim is made. |
| NOT TESTED | Real lock/unlock and sleep/resume | Only existing deterministic core/synthetic lifecycle tests ran. The host was not locked, put to sleep, signed out, or restarted. |
| NOT TESTED | Display changes and multi-monitor placement | No display configuration was changed and no physical multi-monitor test was run. |

**Final matrix totals:** PASS 11, FAIL 0, NOT TESTED 11. The 6,680 core, 128 GUI, and package-verifier assertion totals below are separate from these group counts. Initial tray-probe/harness diagnostics are described in the limitations section and are not counted as product assertion failures.

## Live update request

The isolated GUI suite made a real request from the application and completed it with a useful offline error; it did not report “up to date.” A separate direct request to `https://api.github.com/repos/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/latest` failed with a socket-permission error (`An attempt was made to access a socket in a way forbidden by its access permissions`). The live endpoint's reachability, live JSON parsing, live latest stable tag, and official release URL response could not be verified. Controlled fixtures covered the relevant version and HTTP failure paths without publishing a release.

## Lock, sleep, tray, notification, and audio boundaries

The GUI test directly launched the isolated native application, navigated its real top-level window via process-bound Win32 handles, used UI Automation, started/skipped/snoozed breaks, captured the reminder HWND, and inspected navigation controls across a break. This is a real GUI operation, but it is not proof of tray operation or a Windows toast.

An initial tray probe returned `E_FAIL` when the automation session had no interactive `Shell_TrayWnd`. A subsequent corrected isolated probe recorded the shell tray as **NOT TESTED** and exited the test app cleanly. During development of that diagnostic helper, one attempt stopped because the helper lacked an `IsWindowEnabled` declaration; the helper was corrected and rerun. Neither diagnostic failure exercised or changed the product. No successful tray icon, menu, duplicate-launch, toast, physical sound, lock, sleep, resume, or multi-monitor operation is claimed.

## Regression and artifact results

Source/packaging commit: `84d906917bd3790c4d280d10354d865fb06fa12a`

Feature implementation commit: `622a9f1f72c8f420d4f274cdaaf9693c52fa1c68`
Build toolchain: MSYS2 MINGW64 GCC 15.2.0 (MSVCRT), C++17 with `-Wall -Wextra -Wpedantic -Werror`, `WINVER=0x0A00`, `_WIN32_WINNT=0x0A00`; MINGW32 NSIS 3.11 (32-bit bootstrap); Python packaging and verification scripts.

| Suite / package | Result |
|---|---|
| C++17 core regression | 6,680 assertions passed |
| Visible Win32 GUI acceptance | 128 assertions passed; 37 screenshots |
| Binary/package verifier | 86 assertions passed |
| Installer execution | NOT TESTED |

The application and NSIS installer are **unsigned**. No signing certificate was supplied or used. The Source ZIP intentionally excludes this final verification report because the report contains the Source ZIP's own SHA-256; packaging and verification scripts enforce that exclusion. The report remains in the Git repository.

| Artifact | Final size | SHA-256 |
|---|---:|---|
| `release/EyeBreakReminder.exe` | 2,604,032 bytes | `5bc04bb369b81faad93687395e599a73386718e7dbeda95bb859304a7f0df7bd` |
| `release/EyeBreakReminder-Setup-x64.exe` | 1,391,275 bytes | `6b20f9db56b6afa34529d2e24db24e7b36d9feccffe658337163d3983d81d186` |
| `release/EyeBreakReminder-Portable-x64.zip` | 1,447,954 bytes | `10bc380eea3c5e07b536d48fd2df5aeac23754ace90a649d69e12af83d86028a` |
| `release/EyeBreakReminder-Source.zip` | 968,767 bytes | `976cce913b725af305054c383e3efbe25200e31eb5f026e69522104266bd64d5` |
| `release/EyeBreakReminder-SHA256.txt` | 382 bytes | `50230b2f98c1e9e5cd595506bb3708f5ad45df5b5caef6e649cfcc0136efd5c3` |

The packaged executable and installer metadata are `1.2.0` (`1.2.0.0` in PE version resources). The x64 Windows GUI identity, embedded manifest/icons/sounds, built-in Windows DLL dependency allowlist, portable executable byte identity, source archive contents, ZIP CRCs, source-report exclusion, and all four artifact hashes passed. The source archive excludes release outputs; the portable archive contains the exact verified v1.2.0 executable. NSIS built the installer after that executable from `installer/setup.nsi`, which names `release/EyeBreakReminder.exe`. No v1.1.0 binary is included. NSIS emitted warning 9100 because the project has no supplied `LegalCopyright` identity; none was invented. The app and installer remain unsigned.

## Release-readiness conclusion

The automated core, GUI, update-fixture, and package checks pass, but this is **not a complete real-Windows pre-release validation**: the installer and upgrade workflow, live GitHub response, interactive shell, Windows theme/Forced Colors changes, audio, lock/sleep, and multi-monitor behavior remain untested. v1.2.0 is built for review, but the available evidence does not justify claiming that all requested release validation passed. No v1.2.0 release has been published.
