# Eye Break Reminder v1.2.0 — Final Completion Audit

- **Report date:** 2026-11-12 (UTC)
- **Release:** [v1.2.0](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/tag/v1.2.0)
- **Repository:** [REMEDIOSSAMUEL/EYE-BREAK-REMINDER](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER)
- **Published tag target:** `908a21531833eb2175fb7bd882db06b79a2b917b`
- **Tested product source:** `cbd2e467c3767765250ff11a701839a8a850134b`
- **Authoritative Windows Server 2025 run:** [43115129392](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/43115129392)

## Completion status

The initial follow-up snapshot below was superseded when GitHub access was restored. The verification branch has since been pushed, a disposable Windows 11 ARM64 desktop and a Windows Server 2025 runner were used, and a genuine USER-object leak was reproduced in the published v1.2.0 application. A separate unpublished v1.2.1 candidate fixes that leak and passed its hosted regression workflow. The original v1.2.0 release, tag, assets, and main branch remain unchanged.

The v1.2.0 release itself was not modified. Verification-only changes were pushed to the existing verification branch. The separate v1.2.1 hotfix candidate contains a narrowly scoped product correction and regression coverage; it is unpublished and awaits the user's approval before any release. Exercise Break Reminder was not accessed or modified.

## Verified release identity and prior evidence

The prior independent public-release audit recorded a public, stable, published release with the correct title and tag, exactly five expected assets, correct source equivalence, and correct checksums. The tag peels to main commit `908a21531833eb2175fb7bd882db06b79a2b917b`. The source archive comparison found 38 exact source-file matches and zero mismatches against the approved main tree, excluding documented files. The application, installer, and build inputs between the Windows-tested source and approved main were equivalent.

| Published file | Bytes | SHA-256 |
|---|---:|---|
| `EyeBreakReminder.exe` | 2,604,032 | `2895c80f942dd03186305d913516700552524ec5ba9a77da0dab457a3265fcc6` |
| `EyeBreakReminder-Setup-x64.exe` | 1,395,139 | `121eaa8d14b8e3d342252edfc91bc25d6e8334b829c2824b7f90813062ded75f` |
| `EyeBreakReminder-Portable-x64.zip` | 1,448,916 | `757f1cb10eb9a4c943a47c475f3aca8a2942b823ad4119fa217c66251dbd3658` |
| `EyeBreakReminder-Source.zip` | 1,003,262 | `d6ed5ba6827ad9097435c4ffe9776b0e60e9a67f9b9ccfc49776964d57c9e692` |
| `EyeBreakReminder-SHA256.txt` | 382 | `be97ddf2af39a52315ab7f678ce26d770bde81113181aa00ad3c7c1577b50dea` |

Historical release-acceptance totals remain **756 PASS, 0 FAIL, 9 NOT TESTED**, with 11 informational events excluded from the counts. The earlier suites recorded 6,680 core assertions, 128 Win32 GUI assertions, and 88 package checks. These are previous-run results, not new results from this follow-up.

The prior run exercised the exact published downloads on an interactive Windows Server 2025 runner: install, app launch and operation, themes, timer and reminder cycles, tray behavior, settings/history, update checking, upgrade, interactive uninstall, silent uninstall, and reinstall. The actual live updater found v1.2.0 and reported the installed v1.2.0 app current. The Windows Server result is not a Windows 11 client result.

## Initial local follow-up snapshot (superseded where stated below)

| Check | Result | Evidence and limits |
|---|---|---|
| Core suite | **PASS** | `mingw32-make test`: 6,680 assertions passed. |
| Release executable compile | **PASS** | Application source compiled in the isolated clone using the installed MinGW toolchain. Compatibility overrides were needed for the local `windres`/`strip` command names and Windows API target declarations. This output is a test build, not a replacement for or a test of the published EXE; it was not launched. |
| GUI test executable compile | **PASS** | `mingw32-make gui-test` compiled with `EYEBREAK_TEST_BUILD`. This only verifies compilation; the UI test binary was not run on the personal profile. |
| NSIS process-handle technique probe | **PASS** | A harmless hidden `cmd.exe` child exited with predetermined code 47; a retained Win32 process handle returned exit code 47 after termination. This validates the handle technique only, not either NSIS uninstaller. |
| PowerShell parsing and Git whitespace check | **PASS** | The modified `windows_pre_release_acceptance.ps1`, new `process_exit_handle_probe.ps1`, and all five embedded workflow PowerShell blocks parsed; `git diff --check` reported no whitespace errors. |
| Code-signing certificate inventory | **PASS — negative inventory** | The current user and machine personal stores had no authorized Code Signing EKU certificate; no private key was exported. This does not mean a signed build was produced. |
| Local `make package` equivalent | **BLOCKED at this snapshot; RESOLVED in continuation** | The installed MSYS2 NSIS package exposed only `share/nsis/Plugins/unicode`; the installer requests the `x86-unicode` plug-in set, so `nsDialogs::Create` did not resolve. A portable upstream NSIS 3.11 x86 setup later completed packaging without changing the installed toolchain; see continuation. |
| GitHub Actions workflow parser / remote execution | **BLOCKED at this snapshot; RESOLVED in continuation** | GitHub access was restored; the verification branch was pushed and workflows were executed. |

The app and GUI test builds were produced from a temporary verification clone. They were not substituted for the public downloads and were not executed as published-binary evidence.

## Environment investigation

The local host is Windows 11 26H2 x64 (build `26300.9974`) with Explorer, but it is the user's personal desktop and has existing Eye Break Reminder data under the local profile. It was not used to install, launch, lock, sleep, change accessibility preferences, or alter monitor configuration. This preserves the user's settings and avoids interrupting the workstation.

No local Windows Sandbox executable, Hyper-V VM service/cmdlets, VirtualBox/VMware installation, or self-hosted Actions runner was found. No disposable local Windows 11 VM was available. GitHub's public `windows-11-arm` hosted runner is a Windows 11 ARM64 VM and is free for public repositories; Windows 11 ARM supports x64 app emulation through Prism. However, the published NSIS installer checks `IsNativeAMD64` and intentionally refuses a native ARM64 OS. Thus that runner can provide useful Windows 11 desktop evidence for the exact published x64 standalone and portable executables, but it cannot provide a valid full installer lifecycle test. A native x64 Windows 11 VM/runner is required for the installer/UAC/Installed Apps lifecycle.

A workflow was prepared at `.github/workflows/windows-11-post-release-gap-audit.yml` to download and hash all five actual public assets, run the exact published standalone and portable executables on the Windows 11 ARM desktop, capture evidence, verify the process-handle probe, and explicitly retain native x64 installer lifecycle checks as untested on ARM. The first run attempt is documented in the earlier snapshot; the continuation records the successful rerun, its evidence, and the unresolved Windows 11 ARM USER-object leak assertions.

GitHub documents Windows 11 ARM hosted runners for public repositories and Microsoft's Windows 11 ARM documentation describes Prism x64 emulation: [GitHub-hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners), [Microsoft x64 emulation on Windows 11 ARM](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/deploy-overview).

## Targeted verification matrix

`PASS` means directly exercised with evidence. `BLOCKED` means the test remains unverified because an identified safe environment, permission, or prerequisite is missing. The harness probe does not substitute for a real NSIS process test. The matrix and counts in this section are the initial follow-up snapshot; the continuation at the end records subsequent results and supersedes its changed dispositions.

The **new local execution set** has **6 PASS, 0 FAIL, 0 NOT TESTED, 0 NOT APPLICABLE, and 2 BLOCKED**. The **26-item remaining-gap matrix** has **0 newly resolved PASS, 0 FAIL, 1 NOT TESTED, 1 NOT APPLICABLE, and 24 BLOCKED**. These counts are separate from the historical 756/0/9 aggregate; they are not added together.

| Area | Existing evidence and required procedure / success criterion | Result and evidence |
|---|---|---|
| Release page, metadata, tag, assets and checksums | Prior independent download audit checked the public page, stable metadata, exact tag target, five downloads, sizes, manifest and file hashes. | **PASS — prior run 43115129392.** Hashes above. Not repeated. |
| Source equivalence | Compare the published source ZIP and complete product/installer/build-input tree against the approved main tree, excluding documented outputs. | **PASS — prior run.** 38 exact file matches; no source mismatches. |
| Published app, installer, themes, timer, tray, update check, upgrade/uninstall | Run the exact downloaded release binaries in an interactive disposable Windows environment. | **PASS — prior Windows Server 2025 run.** Not rerun in this follow-up. |
| Native Windows 11 x64 published-binary run | Run actual release files inside an isolated Windows 11 x64 VM with rollback. No such VM/runner is currently available locally. | **BLOCKED.** Personal host is intentionally excluded; no x64 disposable environment. |
| Published standalone and portable app on Windows 11 | Execute both exact SHA-256-verified public files on Windows 11; observe UI and controls on Explorer desktop. | **BLOCKED.** Windows 11 ARM workflow is prepared but cannot be pushed/run with the invalid GitHub token. The workflow would use actual downloads, not rebuilt binaries. |
| Published installer on Windows 11 | Wizard and full install/uninstall/upgrade require native AMD64 because the installer guard rejects non-AMD64. | **BLOCKED.** ARM runner is not a valid installer target; need native x64 Windows 11 isolation. |
| Settings > Apps uninstall flow | Start uninstall from the real Windows 11 Installed Apps page and verify cleanup/preserved user data. | **BLOCKED.** Requires interactive Windows 11 install, which was not performed. |
| Narrator keyboard navigation | Start Narrator in an isolated Windows desktop; navigate tabs, timer, themes, history, update controls, and reminder; inspect focus and accessible names. | **BLOCKED.** UI Automation metadata had passed before; actual Narrator focus navigation was not run in this follow-up. |
| Narrator audible speech | Directly hear or capture Narrator speech for meaningful labels, roles and states. | **BLOCKED.** No Narrator process/speech was started; metadata does not prove speech. |
| Legacy Shell tray balloon | Trigger a scheduled reminder on Windows 11 with app notification permission enabled; observe/dismiss the actual `Shell_NotifyIconW` balloon, quiet-time behavior and repeats. | **BLOCKED.** The prior app-owned reminder window was observed; actual balloon visibility/dismissal was not. |
| Modern Windows toast | Inspect implementation and confirm whether a modern toast API is part of the product. | **NOT APPLICABLE.** Source implements an app-owned reminder window and legacy Shell tray balloon (`Shell_NotifyIconW`/`NIF_INFO`); no modern Toast API/identity path is implemented. Do not represent the balloon as a toast. |
| Audio output submitted to Windows | On a disposable Windows desktop with an endpoint/loopback sink, exercise preview, timer alarm, reminder audio, disabled/muted state and repeat behavior; capture non-silent samples. | **BLOCKED.** Previous run did not verify production output; no isolated Windows audio endpoint/loopback test was available locally. |
| Physical speaker audibility | Verify human-audible output through physical speakers. | **BLOCKED.** No safe isolated physical-speaker setup. Generated PCM or `waveOutWrite` submission would not prove audibility. |
| Real lock/unlock | Lock and unlock a disposable Windows session during an active timer and verify recovery and single reminder behavior. | **BLOCKED.** No disposable VM/session; personal desktop was not locked. Previous source-level/synthetic session coverage is not equivalent. |
| Real sleep/resume | Suspend and wake a disposable Windows VM/device and verify the documented elapsed-time semantics, UI, tray and reminder recovery. | **BLOCKED.** No safe VM with controlled Windows power lifecycle; VM pause is not claimed as OS sleep. |
| Multiple monitors | Use two actual virtual displays; move windows, vary DPI, disconnect/reconnect, and verify timers/dialog positions. | **BLOCKED.** Previous runner exposed one display; no isolated multi-display Windows environment. |
| v1.2.0 NSIS UI child exit code | Hold a process handle before Finish and capture child exit status after termination; independently verify files, registry and wizard completion. | **BLOCKED.** Actual uninstall and cleanup passed previously, but child UI exit code remained unavailable. New native-handle probe passed for a benign child only; real v1.2.0 NSIS has not been rerun. |
| Official v1.1.0 NSIS UI child exit code | Same procedure against the official v1.1.0 uninstaller. | **BLOCKED.** Same harness limitation and no safe interactive installer run in this follow-up. |
| NSIS native-handle capture method | Hold `SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION`, wait, and query after a test child exits with a known code. | **PASS.** Probe recorded expected 47, actual 47, wait result 0. Does not prove NSIS uses this observable lifecycle. |
| Multi-hour soak / timer drift | Run multiple real or accelerated cycles in disposable Windows while sampling private bytes, GDI/USER objects, handles, CPU and timer drift over hours. | **BLOCKED.** No disposable runner was available; the previous short resource sample is not a soak. |
| Restart during active break | Start a break using the exact public EXE, restart it, and compare state against documented restoration semantics. | **BLOCKED.** No safe published-binary desktop run was possible in this follow-up. |
| Timer-ring pixels | Capture actual screenshots of work/break ring under dark, light and both high-contrast themes; sample the rendered ring arc pixels, not navigation accents. | **BLOCKED.** Prior action screenshots were not present in the local workspace and could not be retrieved without authenticated GitHub access; no new desktop capture was made. |
| Hover/focus/pressed/disabled states | Systematically inspect controls and contrast in all themes with mouse and keyboard on the actual app. | **BLOCKED.** Prior GUI checks covered focus/legibility in part; a complete state-by-state published-binary review was not executed in this follow-up. |
| Reduced motion | Toggle the actual Windows accessibility preference, observe the running app and restore the original setting. | **BLOCKED.** Personal Windows settings were not changed; no isolated desktop was available. |
| SmartScreen/reputation | Launch the exact unsigned public EXE and installer with normal Windows 11 security settings; observe prompts without bypassing them. | **BLOCKED.** No isolated consumer Windows 11 test; Windows Server evidence does not determine consumer reputation behavior. |
| Standard-user interactive UAC | Use a disposable standard account and an authorized admin prompt in isolated Windows 11; verify install and uninstall privilege handling. | **BLOCKED.** Prior hosted checks included a disposable standard-user install/silent uninstall, but not interactive UAC on Windows 11. No credentials stored. |
| Text scaling / DPI matrix | Exercise supported Windows text scale and per-monitor DPI combinations; measure status and ring alignment, controls, settings and reminder layout. | **BLOCKED.** No isolated Windows 11 display environment; previous single-runner DPI checks do not cover this matrix. |
| Update URL launch from a newer release state | Use an isolated app fixture that presents a newer stable version; click the actual enabled update link and confirm the official release page opens. | **NOT TESTED.** Public latest is v1.2.0, so the current installed app correctly disables the link; previous controlled version scenarios did not launch a browser. |
| Optional break-accent toggle in every theme | Toggle the setting in the actual published app under all five themes and sample the real timer ring/reminder color. | **BLOCKED.** Previous published-binary evidence covered default work/break colors; the full optional-setting/theme matrix was not run. |
| Production code signing | Sign and verify with a trusted certificate and timestamp service. | **BLOCKED.** A valid authorized certificate and protected signing credential/service are missing. The published v1.2.0 binaries remain unsigned. |

### Previous nine NOT TESTED results — disposition

None of the nine app-level gaps became a direct PASS in this follow-up. The two child-exit-code test harness gaps now have a successful isolated native-handle technique probe, but the official v1.2.0 and v1.1.0 NSIS processes still need to be retested; their statuses remain unverified. The modern Windows toast item is accurately reclassified as **NOT APPLICABLE** because the application implements no modern Toast API. The actual legacy tray-balloon display remains unverified.

| Previous observation | Follow-up disposition |
|---|---|
| Narrator or other screen-reader speech | **BLOCKED / unverified.** No speech was started. |
| Windows Shell notification surface display/dismissal | **BLOCKED / unverified** for the legacy balloon. Modern toast: **NOT APPLICABLE**. |
| Production audio playback | **BLOCKED / unverified.** |
| v1.2.0 extracted NSIS UI process exit code | **BLOCKED / unverified**; handle method probe passed, actual NSIS not run. |
| v1.1.0 extracted NSIS UI process exit code | **BLOCKED / unverified**; handle method probe passed, actual NSIS not run. |
| Real lock/unlock | **BLOCKED / unverified.** |
| Physical sleep/resume | **BLOCKED / unverified.** |
| Multiple-monitor behavior | **BLOCKED / unverified.** |
| Physical speaker output | **BLOCKED / unverified.** |

Earlier pre-release NOT TESTED observations that were resolved before publication remain resolved: the close-to-tray native explanation, and the expected absence of an app Run checkbox on both v1.2.0 and v1.1.0 uninstaller finish pages. They are not new follow-up results.

## Notification and audio implementation classification

Source review of `src/app.cpp` and `src/windows_services.hpp` found three distinct paths:

1. An application-owned break reminder window.
2. A legacy Shell tray balloon requested with `Shell_NotifyIconW`/`NIF_INFO`, `NIIF_NOSOUND`, and `NIIF_RESPECT_QUIET_TIME`.
3. No modern Windows Toast Notification API or toast identity/configuration path.

Therefore the absence of a visible modern toast is not an application defect; a modern toast test is not applicable. Whether the legacy Shell balloon is visible on Windows 11, including quiet-time and dismissal behavior, is still blocked/unverified. The audio implementation generates embedded PCM and submits it via WinMM `waveOut`; neither successful submission nor prior audio-generation checks establish captured non-silent endpoint output or physical human audibility.

The app handles power/session notifications in its Windows integration, and existing deterministic tests cover related state logic. They do not replace actual session lock/unlock or OS sleep/resume tests.

## Branch and change safety

The isolated verification branch is `post-release-verification-v1.2.0-actual-binaries-20261111`, based on main at `908a21531833eb2175fb7bd882db06b79a2b917b`. Its harness changes were pushed without force to the same branch. They cover authenticated release metadata requests, Windows 11 foreground recovery after OOBE, direct timer-ring pixel sampling, actual appearance-preference transitions, reduced-motion preference changes/restoration, and safe manual-only execution for the two-hour soak workflow.

- Installer process-exit capture and regression harness improvements.
- Published-download, smoke, timer-ring, appearance, and reduced-motion test updates.
- Windows 11 ARM actual-public-binary workflow and two-hour soak workflow.
- This report and its machine-readable acceptance update.

The verification branch contains no application, NSIS, or release-file changes. A separate branch `hotfix/v1.2.1-user-object-leak` contains the candidate fix and regression test, based on the unchanged main commit; it was pushed and tested but not merged or released. No force-push was performed. The v1.2.0 tag and release assets remain unchanged.

## Code-signing assessment

The binaries are unsigned. No valid authorized code-signing certificate was found in the inspected user or machine stores, and no production signing hooks/secret references were found in the inspected workflow. The missing prerequisite is an authorized trusted Authenticode certificate plus a protected signing mechanism (for example, a hardware-backed or remote signing service, or carefully protected Actions secret access). A future release should sign both the app and installer after building, timestamp with RFC 3161/SHA-256, verify signatures with SignTool, and generate release hashes only after signing. Do not store private keys in the repository. Microsoft recommends explicit SHA-256 digest and timestamp algorithms and explains that timestamping keeps a signature verifiable after certificate expiry: [SignTool](https://learn.microsoft.com/en-us/windows/win32/seccrypto/signtool), [Authenticode timestamping](https://learn.microsoft.com/en-us/windows/win32/seccrypto/time-stamping-authenticode-signatures). No certificate was purchased or created, and v1.2.0 was not altered.

## Assessment and remaining action

That assessment has been superseded: the published v1.2.0 app has a reproduced USER-object leak when each break window closes. The issue is not an immediate launch or timer failure, but repeated cycles accumulate USER objects. A focused v1.2.1 fix has passed an isolated hosted regression and remains unpublished. Treat this as a release risk until the user approves and publishes the hotfix.

GitHub authentication is now restored. The verification branch was pushed and the Windows 11 ARM and Windows Server workflows were run. The remaining need is approval to publish v1.2.1, plus isolated Windows infrastructure and real hardware capabilities for the blocked OS and audio cases below.

## Final continuation — 2026-11-12

### Current finding

All Windows 11 ARM and Windows Server 2025 tests below used clean GitHub-hosted runners. The Windows 11 runner is ARM64; it executed the exact public x64 standalone and portable binaries through Windows x64 emulation, not native x64 hardware. The full installer lifecycle was exercised on native x64 Windows Server 2025. No test ran against the user's personal Windows profile.

The release audit again downloaded all five public v1.2.0 assets and matched the previously reported SHA-256 hashes and release sizes. The stable release, tag, main commit, and assets remain unchanged. The new hosted audit's 36 release assertions passed.

### New Windows 11 ARM published-binary run

Run [43233331746](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/43233331746), commit `bf654312b430ff493b2e7309f36921a2cbdea2f1`, ran on Windows 11 Enterprise build `26200`, ARM64. It downloaded and verified the public standalone EXE and portable ZIP, extracted the latter, verified both executable SHA-256 values, and visibly launched both exact v1.2.0 x64 binaries under emulation. The app was the foreground desktop window and screenshots were captured; the earlier Search overlay issue was resolved by the harness's real Escape key input and safe foreground activation.

The smoke result was **261 PASS, 20 FAIL, 1 NOT TESTED, 29 INFO**. All 20 failures were per-break USER-object cleanup checks: 10 break paths for the standalone EXE and 10 for the portable executable. The failures reproduce the same product defect, not an app launch, UI, timer, theme, or test-harness failure. All five themes, work/break states, and the optional break accent on/off were exercised. The harness sampled actual rendered timer-ring pixels: expected work and break colors appeared in their appropriate arcs and the opposite color was absent. Both app variants also followed real test-runner dark/light appearance preference changes, and the running app updated accordingly. The reduced-motion test used `SPI_SETCLIENTAREAANIMATION`, read both preference states back from Windows, measured synchronous settings scrolling, and restored the original setting and window bounds.

The smoke's one NOT TESTED item is Windows audio output: `waveOutGetNumDevs` returned zero. No physical speaker or loopback output was available. The run did not test Narrator speech, a visible legacy tray balloon, native x64 installation, UAC, SmartScreen reputation, lock/sleep, or multi-monitor behavior.

The Actions artifact is `eye-break-reminder-v1.2.0-windows-11-arm-gap-audit-43233331746`; it contains the JSON result, downloaded files/audit records, runner screenshots, app screenshots, and direct ring-pixel assertions. Representative screenshots include `Published-standalone-EXE-Dark-work-ring.png` and `Published-standalone-EXE-Dark-break-enabled-ring.png`.

### Separate v1.2.1 candidate diagnosis and regression

The exact published EXE hash `2895c80f942dd03186305d913516700552524ec5ba9a77da0dab457a3265fcc6` was run on interactive Windows Server 2025. Five measured break cycles each added exactly two process USER objects (baseline 158, final 168). The candidate regression also recorded full break-window destruction and the exact binary hash. The 12-cycle v1.2.1 candidate run recorded zero USER-object growth in every measured cycle (156 before and after), with 30 PASS, 0 FAIL, and 0 NOT TESTED; its built executable hash was `77b2195f767daeb3d681ebb467f89b0274bd0c2d76bd54cccecf6ef17805c120`.

The root cause is an early synchronous `WM_SIZE`: the break window's initial `SetWindowPos` can call `layoutBreak()` before the break child controls exist. The failed deferred-position batch receives null child HWNDs and leaks a USER object. The candidate adds a narrow early guard in `layoutBreak()` until those required controls exist. No assertion was weakened. The exact v1.2.0 leak is expected/reproduced by the regression test; the candidate's no-growth assertion passes.

Run [43232353585](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/43232353585) passed on Windows Server 2025 x64. It also completed `make test` (6,680 core assertions), `make all`, `make package` (88 binary/package assertions), and `make gui-test` (128 Win32 GUI assertions), plus the native GUI acceptance suite. The NSIS 3.11 package warning 9100 only notes missing `LegalCopyright`; no copyright text was fabricated. The candidate is on branch `hotfix/v1.2.1-user-object-leak` at `7adc7545e1b6657258d7b690bd40a80f70a5f826`. It is not merged and not published.

### NSIS build environment

The original local failure came from selecting the MSYS2 UCRT64 NSIS compiler for an `x86-unicode` installer. Its `nsDialogs.dll` is an x64 PE image, although the compiler lists its commands, so NSIS rejects `nsDialogs::Create` for the x86 target. The installed MINGW32 NSIS 3.11 compiler has the matching x86 Unicode plug-in and compiled the installer successfully. `make -B package` then passed locally with 6,680 core assertions and 99 package assertions. The command used the existing MINGW64 cross compiler, the matching MINGW32 NSIS executable, and a temporary build-directory copy of `strip.exe` under the Makefile's expected cross-prefixed name; it did not alter the system NSIS installation or installer script. `make -B gui-test` also compiled the GUI acceptance executable. These are local build/package checks only; they did not launch the freshly built application, and those artifacts were not used to replace or publish any release asset. NSIS emitted warning 9100 about missing `LegalCopyright`; no copyright text was invented.

### Additional evidence and remaining dispositions

| Scenario | Current result | Evidence / limitation |
|---|---|---|
| Exact v1.2.0 EXE/portable downloads and release metadata | **PASS** | All five assets redownloaded and rehashed; 36 release audit assertions passed on the current Server run. |
| Windows 11 real desktop app operation | **PASS with a separate product failure** | Exact EXE and portable app visibly ran under x64 emulation; 261 smoke assertions passed. The distinct leak assertions are FAIL, not hidden by the run result. |
| Five themes and direct ring pixels; both break-accent states | **PASS** | Actual pixel samples from visible Windows 11 screenshots; both executable forms and work/break paths. |
| Windows dark/light appearance preference changes | **PASS** | Changed in the disposable runner; app appearance and ring colors updated; original values restored. This was not an interactive Windows Settings UI test. |
| Reduced motion | **PASS** | Actual Windows SPI preference was toggled/read back/restored. Settings scroll moved immediately with no subsequent animation movement. |
| Restart during active break | **PASS** | Previously captured against the exact release binary on Server 2025; restarted app followed documented fresh-work-state behavior. |
| Timer-ring/status alignment and footer | **PASS** | Pixel sampling verified ring arc; visible screenshots show centered Running/break status and the retained 20-20-20 summary plus dynamic schedule. Prior Win32 GUI geometry assertion measured zero horizontal difference at the tested size. |
| v1.2.0 and v1.1.0 interactive NSIS child exit codes | **PASS** | The improved full-process-tree harness retained handles and recorded exit code 0 for both UI uninstallers on Server 2025; cleanup was independently checked. |
| Multi-hour stability | **FAIL — resource leak** | Two-hour run 43194592820 executed 110 cycles and 240 samples without a crash or invalid timer; USER objects nevertheless rose 155→373 (+218). The controlled reproduction isolates +2 per break. |
| Windows modern Toast API | **NOT APPLICABLE** | No modern Toast API/identity path exists. The app uses its own reminder window and legacy Shell tray-balloon requests. |
| Visible legacy Shell balloon | **NOT TESTED** | Shell request acceptance is not proof that a balloon was visibly displayed or dismissed. |
| Narrator keyboard navigation / audible speech | **NOT TESTED** | Accessibility/UIA metadata exists, but Narrator was not started; no speech was observed or captured. |
| Windows audio endpoint / physical speaker | **NOT TESTED** | Windows 11 runner had zero output devices; no loopback sink or physical speaker test. |
| Real lock/unlock and OS sleep/resume | **NOT TESTED** | No isolated VM exposed safe genuine session and power lifecycle controls. Synthetic events are not counted. |
| Native x64 Windows 11 install, Installed Apps, UAC, SmartScreen | **NOT TESTED** | The only Windows 11 runner is ARM64; its installer refuses non-native AMD64. Server 2025 is not consumer Windows 11 SmartScreen evidence. |
| Multi-monitor topology | **NOT TESTED** | Hosted runner exposed one display; no real multi-display environment. |
| Windows 11 DPI/text-scale matrix | **PARTIAL** | Windows 11 run tested 96 DPI/100% text scale. Server GUI checks cover additional text-scaling and forced-colors cases, but no multi-monitor per-display matrix. |
| Update-link browser launch with a newer version | **NOT TESTED** | The live published latest is v1.2.0, so the current app correctly has no newer target to open. |
| Production Authenticode signing | **BLOCKED** | No authorized trusted signing certificate/key/service was available. v1.2.0 remains unsigned. |

### Test counts and release status

Keep separate totals by evidence source: historical release acceptance remains **756 PASS, 0 FAIL, 9 NOT TESTED**; the fresh Windows 11 smoke is **261 PASS, 20 FAIL, 1 NOT TESTED** (29 informational); current release download audit is **36 PASS, 0 FAIL**; candidate validation has **6,680 core, 88 package, and 128 GUI assertions passed**, plus the separate 11-assertion leak-reproduction and 30-assertion candidate no-growth reports. Do not sum repeated platform and suite assertions into a single deduplicated acceptance total. The Server 2025 exact-release run triggered by commit `bf65431` is still running at the time of this interim update; its final totals and artifact link will be inserted before this audit is committed.

v1.2.0 remains the official unchanged stable release. The new product defect makes a focused v1.2.1 hotfix necessary; publishing it requires the user's explicit approval. The v1.2.1 candidate has passed the tested suites, but real audio, Narrator speech, visible Shell balloon, lock/sleep, multi-monitor, native Windows 11 x64 installer/UAC, SmartScreen reputation, and signing remain unverified or unavailable as listed above.

## Final rerun results — 2026-11-12

This section supersedes the earlier interim statement that run 432581 was still running and the 432607 interim totals below. Final hosted evidence is from verification commit `96d0b0472f8b2ed71115459736bbb0ffd1c332df`:

- Windows 11 ARM desktop: [run 43261407923](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/43261407923), artifact `eye-break-reminder-v1.2.0-windows-11-arm-gap-audit-43261407923`.
- Windows Server 2025 x64: [run 43261407951](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/43261407951), artifact `eye-break-reminder-v1.2.0-post-release-evidence-43261407951`.

Both runners downloaded the public release. The Windows 11 runner verified all five asset identities and launched the byte-identical published standalone and portable x64 executable under Windows x64 emulation. This is direct Windows 11 ARM evidence, not native Windows 11 x64 evidence. The x64 installer lifecycle was exercised on the interactive Windows Server 2025 x64 runner.

### New run outcomes

| Suite | PASS | FAIL | NOT TESTED | Other |
|---|---:|---:|---:|---|
| Windows 11 published-app smoke | 322 | 20 | 1 | 29 informational |
| Windows 11 Narrator navigation and control activation | 13 | 0 | 1 | Actual speech output is untested |
| Windows 11 Shell/in-app reminder probe | 7 | 0 | 3 | 1 NOT APPLICABLE |
| Windows 11 release asset audit | 36 | 0 | 0 | All five hashes and archive checks pass |
| Windows Server combined acceptance summary | 1,047 | 20 | 8 | Includes overlapping suites; do not add it to the rows above |
| Windows Server installer, upgrade, uninstall, update, and GUI acceptance | 508 | 0 | 7 | 128 Win32 GUI assertions also passed |
| Windows Server published standalone/portable smoke | 321 | 20 | 1 | All 20 failures are resource-stability assertions |
| Windows Server standard-user install/uninstall | 16 | 0 | 0 | Silent install and uninstall; no elevation was observed |
| Fresh regression build | 6,680 core | 0 | 0 | 128 GUI and 88 package assertions passed |

The historical authoritative acceptance remains 756 PASS, 0 FAIL, 9 NOT TESTED, with 6,680 core, 128 GUI, and 88 package assertions. It is a separate historical result and is not folded into these new results.

### Confirmed product risk

Every failure in the two latest published-binary smoke runs is the strict per-cycle USER-object cleanup assertion; no theme, timer, break-window, mouse, ring-pixel, launch, or input assertion failed in the final run. Per-cycle deltas include small positive and negative changes, so those individual samples are noisy. The independent two-hour test remains decisive: 110 cycles and 240 samples increased USER objects from 155 to 373 (+218), and the controlled reproduction isolated a cumulative increase associated with break-window creation. There was no crash or invalid timer in that soak. Treat this as a real resource leak and a release risk, not as 20 independent product defects.

A focused candidate fix remains on `hotfix/v1.2.1-user-object-leak` at `7adc7545e1b6657258d7b690bd40a80f70a5f826`. Its 12-cycle no-growth regression and the core, GUI, and package suites passed. The candidate is not merged or published. v1.2.0 and its release files remain unchanged; a v1.2.1 release requires approval.

### Windows 11 ARM desktop evidence

The exact published binaries report version 1.2.0 and matching SHA-256. The standalone and extracted portable executable are byte-identical and ran as visible desktop windows under x64 emulation. All five themes, work and break ring pixels, both optional break-accent settings, timer controls, reminder windows, selected/hover/focus/pressed states, and actual light/dark Windows appearance preference changes were exercised. The reduced-motion setting was changed and read back on the disposable runner, and then restored. The WSL first-run console was identified, captured as `wsl-first-run-prompt-before-cancel.png`, and canceled with its displayed Escape action before input continued.

Final smoke evidence is `published-exe-smoke.json` plus the `Published-standalone-EXE-*-ring.png` and `Published-portable-ZIP-executable-*-ring.png` screenshots in the Windows 11 artifact. Direct ring sampling—not the navigation indicator—confirmed work/break colors. The earlier Follow Windows/portable high-contrast input failures did not recur after foreground and hit-target checks were added.

Narrator ran during keyboard-only navigation. Tabs, timer controls, History, Settings, About, the live update check, and Space activation of the focused break button passed (13 PASS, 0 FAIL). Audible Narrator speech remains NOT TESTED because the runner has no audio endpoint. Evidence is `narrator-keyboard-probe.json`.

A real short in-app reminder cycle appeared after approximately one minute. The runner reported Do Not Disturb/quiet time; the Settings toggle was not available through the exposed UI Automation pattern, and a separate visible legacy Shell balloon was not established (3 NOT TESTED). Modern toast notifications are NOT APPLICABLE: the implementation uses `Shell_NotifyIconW`/ `NIF_INFO` and has no modern Toast API or app identity. Evidence is `windows-11-shell-notification-probe.json` and `windows-11-real-reminder-shell-notification.png`.

No Windows audio output device was available. PCM generation or Shell request acceptance is not counted as audible output. Native Windows 11 x64 installation, Windows Settings initiated uninstall, consumer SmartScreen, physical audio, real lock/unlock, genuine sleep/resume, and multi-monitor behavior were not demonstrated by ARM emulation.

### Windows Server 2025 installer and build evidence

On native x64 Windows Server 2025 the actual published installer opened its wizard, installed the 1.2.0 executable, created the expected per-user files/shortcuts/registry entries, launched the app, upgraded from official v1.1.0 while preserving settings/history, and completed both interactive and silent uninstalls. A retained native process handle captured exit code 0 from the extracted v1.2.0 NSIS UI process and from the v1.1.0 comparison uninstaller; filesystem, shortcut, and registry cleanup was independently verified. The Start Menu and Installed Apps registration were verified. Windows Settings > Installed Apps displayed the published v1.2.0 entry, but the Settings-initiated Uninstall action itself was not exercised. Screenshots include `v1.2.0 production installer-wizard-*.png`, `v1.2.0 fresh uninstall-*.png`, `upgrade-v11-history-statistics-active.png`, `installed-live-update-check.png`, and `windows-settings-installed-apps.png` in the Server artifact.

A separate disposable standard account installed and silently uninstalled the exact published installer. The test confirmed the account was not an administrator, install data and registry were scoped to its profile, no UAC consent process appeared, and cleanup completed. The standard-user GUI wizard/UAC prompt was not separately exercised.

The runner rebuilt from the approved source: `make test` passed 6,680 assertions, `make all` passed, `make package` passed 88 package assertions, and `make gui-test` passed 128 Win32 GUI assertions. The local NSIS issue was a toolchain mismatch: UCRT64 NSIS 3.11 had an x64 plug-in where the installer requires x86 Unicode. The matching MINGW32 NSIS 3.11 toolchain resolved it. Local `make -B package` then passed with 6,680 core and 99 local package checks; a temporary build-directory `strip.exe` alias was used, without changing system installations or the installer script.

### Final unique gap matrix

These are 35 distinct verification areas, counted once each; they are not assertion totals and do not include repeated runs. Final status counts: **21 PASS, 1 FAIL, 7 NOT TESTED, 1 NOT APPLICABLE, 5 BLOCKED**.

| Area | Status | Evidence or precise limitation |
|---|---|---|
| Published release metadata, five public assets, checksums, source archive, and absence of packaged secrets | PASS | 36 release audit assertions; the source ZIP matched all 38 approved files and excluded build outputs and repository metadata. |
| Windows 11 ARM execution of the published x64 standalone and portable binaries | PASS | Exact release hash and visible desktop operation under x64 emulation. |
| Native x64 Windows 11 installer lifecycle | BLOCKED | No native x64 Windows 11 VM/runner was available; the installer rejects non-native AMD64. |
| Five themes, work/break colors, optional accent, and direct timer-ring pixels | PASS | Both published executable forms; all five themes and both accent settings. |
| Actual Windows appearance preference changes | PASS | Windows app light/dark preferences changed, read back, and restored on the disposable runner. |
| Actual reduced-motion preference | PASS | Preference changed/read back/restored; settings scrolling remained immediate. |
| Hover, keyboard focus, pressed, disabled, and active states | PASS | Direct desktop pixel/UI Automation checks across themes. |
| Timer start, pause, resume, reset, manual break, and short real cycle | PASS | Exact published application was operated on Windows 11 ARM and Server 2025. |
| Timer status centering and timer footer | PASS | UI geometry and screenshots show centered status and the retained summary/schedule without redundant line. |
| Live update checker | PASS | The running published app reported installed/latest 1.2.0 and up to date from GitHub. |
| Narrator metadata, keyboard navigation, and Space activation | PASS | Narrator process ran; tabs, timer controls, History, Settings, About/update, and break action were reached. |
| Audible Narrator speech | NOT TESTED | No Windows audio endpoint was exposed. |
| In-app reminder window on a timed cycle | PASS | Directly observed after approximately one minute on the Windows 11 desktop. |
| Separate visible legacy Shell notification | NOT TESTED | Quiet time was on; the separate balloon was not observed. |
| Modern Windows Toast API | NOT APPLICABLE | No modern toast implementation or app identity exists. |
| Windows audio loopback/output | NOT TESTED | `waveOutGetNumDevs` returned zero; no captured endpoint output. |
| Physical speaker audibility | NOT TESTED | No physical output device was available. |
| Published installer fresh install, v1.1.0 upgrade, interactive uninstall, registry and shortcut integration | PASS | Exact v1.2.0 setup on interactive x64 Server 2025; settings/history migration passed. |
| Silent uninstall and independent cleanup | PASS | Exact published uninstaller removed files, shortcuts, registration, and install directory. |
| Windows Settings Installed Apps registration listing | PASS | Actual Settings page listed Eye Break Reminder 1.2.0 on Server 2025. |
| Settings-initiated uninstall on Windows 11 | NOT TESTED | The ARM runner could not install the x64 package; no native x64 Windows 11 environment was available. |
| Extracted NSIS UI process exit and cleanup for v1.1.0/v1.2.0 | PASS | Retained handles returned exit code 0; file/registry cleanup passed. |
| Standard-user silent install/uninstall without elevation | PASS | 16 assertions; disposable non-admin profile and no UAC consent process. |
| Standard-user interactive wizard/UAC flow | NOT TESTED | The separate interactive standard-user wizard was not run. |
| Consumer Windows 11 SmartScreen reputation | NOT TESTED | No safe consumer x64 Windows 11 environment; protections were not bypassed. |
| Two-hour soak | FAIL | USER objects grew 155→373 (+218) over 110 cycles/240 samples. |
| Restart during an active break | PASS | Exact release binary followed documented fresh-work-state behavior. |
| Actual session lock/unlock | BLOCKED | No disposable VM/session lifecycle; the personal host was not locked. |
| Genuine Windows sleep/resume | BLOCKED | No safe VM supported real suspend/resume and controlled wake. |
| Multiple monitors and per-display DPI matrix | BLOCKED | Hosted desktop exposed one display; no multi-display environment. |
| 150% Windows text scaling | PASS | Actual settings layout captured at 150%; Windows 11 runner was 96 DPI. |
| Core, GUI, and package regression suites | PASS | Core 6,680; GUI 128; hosted package 88 assertions. |
| Local NSIS package build after toolchain correction | PASS | Local package verifier passed 99 checks with matching x86 Unicode plug-in. |
| Production Authenticode signing | BLOCKED | No authorized trusted certificate/key or signing service exists; binaries remain unsigned. |
| Release/tag/main and out-of-scope project safety | PASS | v1.2.0 unchanged; test-only verification branch; Exercise Break Reminder not accessed. |
### Final assessment

The release metadata and downloadable files are correct, and the actual app and installer functioned in the tested Windows environments. The confirmed accumulating USER-object leak is the only application defect discovered, and it is a release risk for long-running repeated use. The focused v1.2.1 candidate is ready for review but remains unpublished pending approval. The Windows 11 ARM results provide real client-desktop evidence under x64 emulation; they do not establish native Windows 11 x64 installer behavior. Narrator speech, visible Shell balloon, audio output, lock/sleep, multi-monitor, consumer SmartScreen, and production signing remain unverified or blocked for the reasons above.

The v1.2.0 release, tag, main branch, and five public assets were not changed. No force-push occurred. The verification branch contains only verification harness/report changes. The personal Windows application data was not used or modified, and Exercise Break Reminder was not accessed.
