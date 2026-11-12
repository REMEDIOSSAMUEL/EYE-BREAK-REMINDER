# Eye Break Reminder v1.2.0 — Final Completion Audit

- **Report date:** 2026-11-12 (UTC)
- **Release:** [v1.2.0](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/tag/v1.2.0)
- **Repository:** [REMEDIOSSAMUEL/EYE-BREAK-REMINDER](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER)
- **Published tag target:** `908a21531833eb2175fb7bd882db06b79a2b917b`
- **Tested product source:** `cbd2e467c3767765250ff11a701839a8a850134b`
- **Authoritative Windows Server 2025 run:** [43115129392](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/43115129392)

## Completion status

The existing published release remains unchanged and its prior end-to-end Windows Server 2025 evidence remains valid. This follow-up did not close the remaining real-OS and hardware gaps because there is no isolated Windows 11 x64 environment available locally, and the GitHub CLI token is invalid, preventing a verification-branch push and hosted-run dispatch. The current workstation is Windows 11 26H2 x64, but it has existing Eye Break Reminder user data and is not isolated; the published app and installer were deliberately not run against that profile.

No application, installer, build configuration, release tag, or release asset was modified. No application defect was reproduced and no v1.2.1 hotfix is indicated by the evidence collected. The follow-up added only test-harness, workflow, and documentation files in the isolated verification clone; they are not pushed. Exercise Break Reminder was not accessed or modified.

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

## Follow-up checks executed locally

| Check | Result | Evidence and limits |
|---|---|---|
| Core suite | **PASS** | `mingw32-make test`: 6,680 assertions passed. |
| Release executable compile | **PASS** | Application source compiled in the isolated clone using the installed MinGW toolchain. Compatibility overrides were needed for the local `windres`/`strip` command names and Windows API target declarations. This output is a test build, not a replacement for or a test of the published EXE; it was not launched. |
| GUI test executable compile | **PASS** | `mingw32-make gui-test` compiled with `EYEBREAK_TEST_BUILD`. This only verifies compilation; the UI test binary was not run on the personal profile. |
| NSIS process-handle technique probe | **PASS** | A harmless hidden `cmd.exe` child exited with predetermined code 47; a retained Win32 process handle returned exit code 47 after termination. This validates the handle technique only, not either NSIS uninstaller. |
| PowerShell parsing and Git whitespace check | **PASS** | The modified `windows_pre_release_acceptance.ps1`, new `process_exit_handle_probe.ps1`, and all five embedded workflow PowerShell blocks parsed; `git diff --check` reported no whitespace errors. |
| Code-signing certificate inventory | **PASS — negative inventory** | The current user and machine personal stores had no authorized Code Signing EKU certificate; no private key was exported. This does not mean a signed build was produced. |
| Local `make package` equivalent | **BLOCKED** | The local MSYS2 NSIS package has plug-ins under `share/nsis/Plugins/unicode`, while this installer target is `x86-unicode`; `makensis` could not resolve `nsDialogs::Create`. The local package step therefore did not complete. The existing hosted package suite previously passed 88 checks. |
| GitHub Actions workflow parser / remote execution | **BLOCKED** | `actionlint`, Ruby, and YAML parser modules are unavailable locally. The new workflow was manually inspected but cannot be validated by GitHub or run until it is pushed. |

The app and GUI test builds were produced from a temporary verification clone. They were not substituted for the public downloads and were not executed as published-binary evidence.

## Environment investigation

The local host is Windows 11 26H2 x64 (build `26300.9974`) with Explorer, but it is the user's personal desktop and has existing Eye Break Reminder data under the local profile. It was not used to install, launch, lock, sleep, change accessibility preferences, or alter monitor configuration. This preserves the user's settings and avoids interrupting the workstation.

No local Windows Sandbox executable, Hyper-V VM service/cmdlets, VirtualBox/VMware installation, or self-hosted Actions runner was found. No disposable local Windows 11 VM was available. GitHub's public `windows-11-arm` hosted runner is a Windows 11 ARM64 VM and is free for public repositories; Windows 11 ARM supports x64 app emulation through Prism. However, the published NSIS installer checks `IsNativeAMD64` and intentionally refuses a native ARM64 OS. Thus that runner can provide useful Windows 11 desktop evidence for the exact published x64 standalone and portable executables, but it cannot provide a valid full installer lifecycle test. A native x64 Windows 11 VM/runner is required for the installer/UAC/Installed Apps lifecycle.

A workflow was prepared at `.github/workflows/windows-11-post-release-gap-audit.yml` to download and hash all five actual public assets, run the exact published standalone and portable executables on the Windows 11 ARM desktop, capture evidence, verify the process-handle probe, and explicitly retain the installer lifecycle as untested on ARM. This workflow has **not run**. GitHub CLI reports the active `REMEDIOSSAMUEL` account's token is invalid; shell access to GitHub is also restricted. No credential was requested, exposed, or embedded. The verification branch cannot be pushed or dispatched until the user authenticates with `gh auth login -h github.com` in their own environment.

GitHub documents Windows 11 ARM hosted runners for public repositories and Microsoft's Windows 11 ARM documentation describes Prism x64 emulation: [GitHub-hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners), [Microsoft x64 emulation on Windows 11 ARM](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/deploy-overview).

## Targeted verification matrix

`PASS` means directly exercised with evidence. `BLOCKED` means the test remains unverified because an identified safe environment, permission, or prerequisite is missing. The harness probe does not substitute for a real NSIS process test. The previous run's nine NOT TESTED observations remain unverified until direct tests are completed.

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

The isolated clone branch is `post-release-verification-v1.2.0-actual-binaries-20261111`, based on main at `908a21531833eb2175fb7bd882db06b79a2b917b`. Local follow-up changes are limited to:

- A retained native process-handle capture enhancement in `tests/windows_pre_release_acceptance.ps1`.
- A harmless known-exit-code probe in `tests/process_exit_handle_probe.ps1`.
- A Windows 11 ARM actual-public-binary verification workflow in `.github/workflows/windows-11-post-release-gap-audit.yml`.
- This report and its machine-readable acceptance update.

No product code, NSIS script, application settings, release tag, or release asset changed. No force-push was performed. The branch is not pushed because `gh auth status` reports an invalid token and GitHub network access is restricted in this session. The machine-readable report records the unpushed state and the branch base; this completion response gives the current local commit SHA. Do not treat the Windows 11 workflow as having run; no Actions URL or new screenshots exist for it.

## Code-signing assessment

The binaries are unsigned. No valid authorized code-signing certificate was found in the inspected user or machine stores, and no production signing hooks/secret references were found in the inspected workflow. The missing prerequisite is an authorized trusted Authenticode certificate plus a protected signing mechanism (for example, a hardware-backed or remote signing service, or carefully protected Actions secret access). A future release should sign both the app and installer after building, timestamp with RFC 3161/SHA-256, verify signatures with SignTool, and generate release hashes only after signing. Do not store private keys in the repository. Microsoft recommends explicit SHA-256 digest and timestamp algorithms and explains that timestamping keeps a signature verifiable after certificate expiry: [SignTool](https://learn.microsoft.com/en-us/windows/win32/seccrypto/signtool), [Authenticode timestamping](https://learn.microsoft.com/en-us/windows/win32/seccrypto/time-stamping-authenticode-signatures). No certificate was purchased or created, and v1.2.0 was not altered.

## Assessment and remaining action

The evidence available continues to support everyday use of v1.2.0 on the tested Windows Server 2025 environment: core/UI/package suites passed historically, the exact public binaries installed and operated, and no application defect was reproduced. This is not a claim of complete verification. Windows 11 client integration, Narrator speech, the legacy balloon's visible surface, real Windows audio output, real lock/sleep, multiple displays, a long soak, and the remaining display/reputation details are still unverified. The distribution caveat remains that both executables are unsigned. No v1.2.1 fix is indicated by current evidence.

The next safe step is to restore GitHub CLI authentication in the user's own terminal (`gh auth login -h github.com`). After authentication, push the already-reviewed verification branch and run its Windows 11 ARM workflow for exact standalone/portable app evidence. A separate native x64 Windows 11 disposable VM/runner is still required for installer/UAC/Settings uninstall and native x64 lifecycle tests. Hardware/OS tests should stay explicitly unverified until directly observed.
