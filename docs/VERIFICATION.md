# Verification — Linux cross-compiled Windows release 1.0.3

This deliverable uses **C++17 / native Win32**, replacing the earlier WinUI/.NET implementation at the user's request to compile from Linux.

- Application: compiled with MinGW-w64 GCC 13-win32, x64 Windows GUI subsystem, static GCC/C++ runtime linkage. Build treats compiler warnings as errors.
- Automated core tests: **58 assertions executed successfully on Linux**, covering work/break timing, pause/resume/reset, snooze, alarm rules, duplicate prevention, sleep/wake, nested lock/sleep, restart recovery, settings/state/history serialization and corruption, statistics and history retention. These are actual C++ tests of the core linked into the Windows application.
- Installer: generated with Linux NSIS 3.09. The GUI bootstrap is x86; installation is restricted to native Windows 11 x64 and deploys the x64 GUI application.
- Binary verification: PE architecture/subsystem and security flags, imported DLLs, embedded manifest/version/icon/sound resources, and signing-directory status are checked by `scripts/verify.py`. The source and portable archives and SHA-256 manifest are checked after packaging.
- Signing: **unsigned**. No certificate or publisher identity was supplied. No Windows certificate validation or security setting is changed.
- Windows 11 runtime: **unavailable**. No manual Windows application launch, installation, uninstall, audio, tray, notification, DPI, accessibility or lifecycle testing is claimed. Wine is not installed and is not counted as Windows 11 testing.

Important limits: native Win32 controls provide a different presentation from WinUI 3. App surfaces/title bars support theme choices; buttons/checkboxes use themed custom drawing while dropdowns/sliders/scrollbars retain native rendering; visual fidelity, native control contrast, text scaling and per-monitor layouts remain runtime-unverified. Notifications are Shell balloons with click-to-open, not actionable toasts. All-display reminders are omitted. There is no supplied source licence or copyright/publisher identity. History totals are bounded to retained records.

Run `docs/WINDOWS-TESTING.md` on a real Windows 11 x64 system before calling this a production-verified release. The source includes the exact Linux build/packaging commands, tests and verification script.

## Settings visibility fix (1.0.1)

The user supplied a Windows screenshot showing an empty Settings page except for the scrollbar and spin arrows. Inspection found that shared control creation omitted `WS_VISIBLE`, while page switching deliberately left the Settings children to inherit visibility from their parent. Version 1.0.1 creates these children visibly and continues to hide/show the parent pane when switching pages. Number fields now keep explicit references to their spin controls for layout, and the pane clips child drawing during background erasure. Version metadata distinguishes this rebuild from 1.0.0. The core and binary/package checks were rerun after this change. Visual confirmation of this fix on Windows is still pending.

## Tray-menu layering fix (1.0.2)

The user supplied a screenshot showing the native tray context menu partially covered by the Windows hidden-icons flyout. Version 1.0.2 uses a dedicated zero-size tool window as the foreground menu owner, makes that owner temporarily topmost while tracking the menu, and removes that status afterward. The main application is never made topmost. The icon bounds are read with `Shell_NotifyIconGetRect` before activating the menu owner, and `TrackPopupMenuEx` positions the menu above the icon with a padded exclusion rectangle. Version-4 tray callback coordinates support mouse and keyboard invocation. Focus returns to the tray only for cancellation and commands that keep the app hidden. Selecting Settings now keeps the Settings window in the foreground even during a break. Build/core and binary/package checks were rerun. Windows runtime confirmation of this fix remains pending.

## Reinstall recovery and visual polish (1.0.3)

The earlier uninstaller intentionally preserved all application data, including `timer.dat`. Version 1.0.3 deletes that checkpoint during uninstall, and on a fresh install before copying the application. Direct upgrades preserve it. Preferences and history are retained. Turning off resume-on-reopen skips restoration without treating that choice as corrupt data. Two additional core assertions cover opt-out of restoration and the resulting fresh work state. Windows install/uninstall execution is still pending.

Native buttons and checkboxes now use common-controls custom drawing, keeping native input and accessibility behavior. Rounded push buttons, visible selected navigation, blue primary actions, softer palettes, clearer settings headings, compact label spacing and padded number fields are implemented. Native rendering is retained for buttons in high contrast. Visual/DPI/accessibility checks on Windows are still pending. Source layout, contribution and manual release documentation were prepared. Repository publication is separate from Windows runtime verification and uses the owner's signed-in GitHub account. Publishing source and release assets does not establish Windows runtime correctness.
