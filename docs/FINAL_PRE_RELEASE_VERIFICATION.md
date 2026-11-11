# Eye Break Reminder v1.2.0 — Final Pre-Release Verification

**Verification date:** 2026-11-11
**Published baseline:** v1.1.0
**Feature branch:** feature/v1.2.0-theme-accessibility-break-mode
**Exact source commit tested on Windows:** cbd2e467c3767765250ff11a701839a8a850134b
**Final hosted Windows run:** [GitHub Actions run 43078836075](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/43078836075)
**Evidence artifact:** [eye-break-reminder-v1.2.0-pre-release-evidence-43078836075](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/43078836075/artifacts/13881899993) (30-day retention)
**Release publication:** Not performed. No assets were published, no release was created, and main was not changed.

## Final result

The final Windows acceptance run completed successfully on the exact source commit above. Its installed-app acceptance JSON records **340 PASS, 0 FAIL, 12 NOT TESTED**. The run also completed:

- C++17 core suite: **6,680 assertions passed**.
- Native Win32 GUI suite: **128 assertions passed**, with **37 screenshots**.
- Binary/package verifier: **88 assertions passed**.
- Production executable, NSIS installer, portable ZIP, source ZIP, and SHA-256 manifest rebuilt from the tested source.
- The interactive no-argument uninstall flow completed successfully for both v1.2.0 and the official v1.1.0 installer.

The previously reported interactive uninstall blocker was a test-harness observation error. The normal NSIS wizard was visible and completed in the verified interactive Windows session. No application or NSIS defect was found, so no production change was made. The test-harness monitoring correction is in the tested commit.

The run did not publish artifacts. The action artifact contains test evidence, screenshots, and the identities/hashes of the runner-built packages.

## Environment and isolation

The workflow ran in a disposable GitHub-hosted **Windows Server 2025 Datacenter** environment, version 10.0.26100, build 26100. The capability probe found Explorer and a taskbar in interactive session 2. Active desktop screenshots show the uninstall wizard at 1024 × 768. The runner profile and installation were isolated from the user's computer and discarded after the run.

This was an interactive Windows Server session, not a Windows 11 client VM. The uninstaller itself was exercised through its normal GUI. Windows 11-specific client behavior, Settings > Apps initiation, and standard-user UAC prompting were not independently tested.

## Test matrix

| Result | Test | Evidence |
|---|---|---|
| PASS | Build, core regression, and package verification | Workflow ran make -B package gui-test. This executes the Makefile test target through package/all, builds both executables, creates all release packages, and runs scripts/verify.py. Core: 6,680 assertions; package: 88 assertions. |
| PASS | Existing native Win32 GUI acceptance | 128 assertions passed; 37 screenshots. The GUI suite covers timer states, themes, alignment, text removal, update fixtures, settings, and reminder behavior. |
| PASS | v1.2.0 installer wizard and fresh install | The real setup wizard was captured and navigated through completion. The installed executable and registry metadata report 1.2.0; the Start Menu shortcut targets the installed executable, which launched with a visible window. |
| PASS | v1.2.0 no-argument interactive uninstall | Uninstall.exe was launched without arguments. The normal NSIS confirmation, uninstall, and finish pages were visibly captured and driven. After Finish, the executable, uninstaller, install directory, Start Menu shortcut, uninstall key, and install key were absent. The test-created settings and history outside the install directory remained. |
| PASS | v1.2.0 silent uninstall and reinstallation | The existing /S cleanup path still succeeded. A subsequent reinstall placed the executable and uninstaller at the expected per-user path and launched successfully. |
| PASS | Official v1.1.0 comparison | The official v1.1.0 installer was checked against the release SHA-256 and installed in the same disposable profile. Its no-argument uninstaller displayed and completed the same visible wizard and removed the files, shortcuts, and registrations. Settings and history remained. |
| PASS | v1.1.0 to v1.2.0 upgrade | Existing settings, startup preference, history bytes, and statistics source data survived. The legacy system-theme setting mapped to Follow Windows Theme; the work interval and history were visible after upgrade. Exactly one startup registration remained, and the upgraded app launched. |
| PASS | Live update check | The installed application made a real unauthenticated HTTPS request to the official GitHub Releases API. It received stable v1.1.0, identified installed v1.2.0 as newer, and did not offer a downgrade. The UI remained responsive. |
| PASS | Windows theme and accessibility integration | Actual Windows light/dark preference changes and Forced Colors were exercised. UI Automation names/focus, keyboard use, theme persistence, and text scaling were checked. System appearance settings were restored on the runner. |
| PASS | Timer layout, resizing, and break transitions | Timer/status geometry was checked at multiple sizes and DPI conditions. Work/break, pause/resume, reminder, dismissal, and snooze transitions were exercised. The main GUI suite verified the schedule explanation and that the removed redundant sentence stays absent. |
| PASS | Tray and lifecycle | The Explorer tray icon/menu and commands were exercised; close-to-tray, reopen, pause/resume, break, exit, relaunch, and single-instance routing were checked. |
| PASS | PrintWindow repaint investigation | Active desktop captures show the navigation captions; the paired PrintWindow capture omits them. This is a PrintWindow capture limitation, not a live-window repaint defect. |
| NOT TESTED | Narrator or screen-reader speech | UI Automation properties were inspected; a speech engine was not started. |
| NOT TESTED | Close-to-tray explanation text through native controls | The dialog was visible and captured, but the instruction text was not exposed by GetWindowText. |
| NOT TESTED | Windows Shell toast surface | The in-app reminder appeared, but no separate Shell toast/notification surface was observed. The reminder window is not counted as a toast. |
| NOT TESTED | Production audio playback and physical speaker output | Hosted runners have no verified physical speaker hardware. Sounds were disabled for unattended timing checks; no physical output claim is made. |
| NOT TESTED | Workstation lock/unlock | No lock test was performed because it could strand the hosted session. |
| NOT TESTED | Physical sleep/resume | No controlled suspend/wake test was available. |
| NOT TESTED | Multiple-monitor configuration | The runner exposed one monitor. |
| NOT TESTED | v1.2.0 and v1.1.0 finish-page Run checkbox state | The visible finish pages exposed no matching Run checkbox; this is not needed for uninstall completion. |
| NOT TESTED | Exit code from extracted NSIS UI processes | The UI process handles did not expose an exit code after completion. The parent exit code and post-uninstall filesystem/registry state were recorded separately. |

The 12 NOT TESTED entries above are the acceptance JSON's event-level count. Separately, the workflow invoked the registered no-argument Uninstall.exe directly; it did not navigate Windows Settings > Apps / Installed Apps and select Uninstall through that UI. The registered command's GUI behavior is verified, but the Settings route itself is not claimed as tested.

## Interactive uninstall investigation

### Cause

The initial investigation treated the no-argument Uninstall.exe launcher exiting as if the uninstall had ended without showing UI. The harness stopped watching when that parent process exited. NSIS launches an extracted UI process from a temporary directory, so the original monitor could miss the detached/extracted child window and then fall back to /S cleanup. That prematurely concluded that no wizard had appeared.

The corrected harness monitors the launch and UI processes separately, samples top-level windows, waits for the actual wizard, captures active desktop screenshots, drives the wizard, and verifies the resulting files and registry state. The successful run shows this was a harness timing/process-monitoring issue, not an installer defect.

### v1.2.0 evidence

In run 43078836075, the installed v1.2.0 Uninstall.exe was started with an empty argument string. Parent PID 7800 exited with code 0. It launched UI process Un.exe, PID 2780, from the NSIS temporary path ending in ~nsu1.tmp\Un.exe. Both processes were in interactive session 2. The visible top-level dialog had class #32770, title “Eye Break Reminder Uninstall,” and bounds 260,165 to 763,555. The test captured the first page, the visible Uninstall button, and the finish page stating that Eye Break Reminder had been uninstalled, then clicked Finish.

Before the wizard, the executable, uninstaller, install directory, Start Menu shortcut, and both application registry entries existed. After the wizard, all were absent; no app process or owned startup entry remained. Test-created settings and history remained outside the app directory, matching the uninstall policy. The UI process exit code itself was unavailable, so that one diagnostic is kept as NOT TESTED; the GUI completion and removal state are independently verified.

### v1.1.0 comparison

The same isolated run installed the official v1.1.0 package, launched its no-argument uninstaller, displayed and completed the interactive wizard, and verified removal of the executable, install folder, Start Menu shortcut, and registration. Settings and history remained.

The v1.1.0 release's NSIS Uninstall section is identical to v1.2.0's section. Both use the standard MUI uninstall confirmation, file-progress, and finish pages, per-user execution level, and quoted registered Uninstall.exe command. The behavior therefore predates v1.2.0; the new run confirms that both versions uninstall normally when the extracted UI process is monitored correctly. The official v1.1.0 release was not modified.

The runner account was its built-in administrator account and no UAC prompt appeared. This run does not establish the UAC experience for a standard Windows user. No Application/System event matched the uninstall interval; Security process-creation events recorded the launcher and extracted UI process.

### Screenshots and raw evidence

The action evidence artifact above contains the acceptance JSON, uninstaller diagnostics, logs, package identities, and screenshots. Relevant screenshot files are:

- pre-release-evidence/v1.2.0 fresh uninstall-uninstall-wizard-first-page.png
- pre-release-evidence/v1.2.0 fresh uninstall-uninstall-wizard-stage-1.png
- pre-release-evidence/v1.2.0 fresh uninstall-uninstall-wizard-finish.png
- pre-release-evidence/v1.2.0 fresh uninstall-uninstall-desktop-after-wizard.png
- pre-release-evidence/official v1.1.0 no-argument uninstall comparison-uninstall-wizard-first-page.png
- pre-release-evidence/official v1.1.0 no-argument uninstall comparison-uninstall-wizard-finish.png
- pre-release-evidence/official v1.1.0 no-argument uninstall comparison-uninstall-desktop-after-wizard.png

The screenshots were inspected. Both finish-page captures show the NSIS message that the application has been uninstalled and a Finish button. The artifact download was saved locally under build/pre-release-evidence-43078836075/.

## Final runner-built release artifact identities

The successful workflow rebuilt these five v1.2.0 artifacts from source commit cbd2e467c3767765250ff11a701839a8a850134b. Sizes and SHA-256 values below come from release-artifact-identities.json and final-package-sha256.txt in the evidence artifact.

| Artifact | Size | SHA-256 |
|---|---:|---|
| release/EyeBreakReminder.exe | 2,640,896 bytes | e05da8e02852afdf69fd636ab2c475ce350d478c530021fa1c03d7027795762d |
| release/EyeBreakReminder-Setup-x64.exe | 1,308,349 bytes | e25de9bfb82f7e751c2c313266add8881ddb37d6a42cfe95ae42bf8887212c98 |
| release/EyeBreakReminder-Portable-x64.zip | 1,463,136 bytes | f91f33d141f51be66f70d2a1ca6abb630bea2e7a21315b08ff30fcf629704123 |
| release/EyeBreakReminder-Source.zip | 1,003,262 bytes | 906627c591d2c5cd8ab01b5451c7a8e69c68783cd679cbf6d2564cdb1ee95a77 |
| release/EyeBreakReminder-SHA256.txt | 382 bytes | 19308188c16e2f03e897ad4741a9402c30e47584eb2b91f7224e2d54a805afa9 |

The installer metadata and installed application version were verified as 1.2.0. The NSIS build emitted warning 9100 because no LegalCopyright resource key is supplied; no identity was invented. The executable and installer remain unsigned. These artifacts were built and tested on the runner, but the workflow uploaded only evidence, not release binaries or public assets.

## Changes and regression status

No application source or NSIS script was changed for this uninstall investigation; there was no product defect to fix. The branch's acceptance harness now waits for and inspects the extracted UI process rather than deciding the result from the launcher's exit alone. The final Windows run passed on that harness. The report update is documentation only.

The previous 43068233585 run's apparent no-wizard result is superseded by the direct GUI evidence from run 43078836075. The previous run's observed behavior was not a product failure; the old harness stopped observing too soon. The current run also compares the official v1.1.0 uninstaller and verifies the real removal state for each version.

## Release assessment

**The interactive uninstall release blocker is resolved. I recommend v1.2.0 for publication approval**, subject to the documented coverage limits: this validation used Windows Server 2025 rather than a Windows 11 client VM; it did not initiate uninstall through the Settings > Apps UI; and Narrator speech, Shell toast display, physical audio, workstation lock/sleep, and multiple monitors remain unverified. No merge or publication has been performed. Exercise Break Reminder and its repository were not modified.
