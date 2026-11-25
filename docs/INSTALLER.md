# Windows installer and uninstall behavior

Eye Break Reminder uses a per-user x86 Unicode NSIS bootstrap to install the native x64 app into `%LOCALAPPDATA%\Programs\EyeBreakReminder`. It requests user execution level, writes per-user Installed Apps registration and Start Menu shortcuts, and does not elevate or change installation scope during an update.

## Fresh install and upgrade

A fresh install creates the application folder and starts a full work interval. An in-place upgrade reuses the existing registered install path and preserves the current settings, timer checkpoint and history. It does not clear AppData as part of setup.

The integrated updater passes `/S` only after the user confirms installation. Before setup starts, the separate per-user coordinator waits for the application to exit normally, records recovery information and verifies the setup and packaged app bytes. NSIS retains the existing uninstall key/identity and updates `DisplayVersion`; the coordinator confirms the installed app version/hash and startup event before reporting completion.

## Clean Install

Clean Install is an updater policy, not a separate installation scope. It is never the default. The updater first backs up the app executable and known user-data files; only after the new application has been installed and verified does it remove `settings.ini` and `timer.dat`. The user must separately confirm the unchecked history/statistics removal option to delete `history.dat`. Startup registration owned by this application is reset. A failed or unconfirmed new start restores the previous version and recoverable data when Windows permits it.

## Recovery and repair

If rollback is still pending, ordinary setup defers to protect the transaction and current data. Once rollback completes, run the authentic installer in the same installation directory to replace missing or damaged application files. Existing registration and the uninstaller help setup identify a repair and retain an eligible timer checkpoint. The repair path cannot recreate absent user data.

Recovery checks required backup files before replacing the application. It rejects missing or corrupt backups, protects different live settings or history, and leaves a file that appears during restoration in place. If the journal, coordinator or backup is unusable, or if recovery stops because live data differ, keep the transaction folder and surviving data and contact support before retrying.

## Uninstall

Windows Settings → Installed Apps invokes the registered per-user `Uninstall.exe`. Interactive uninstall asks the user to keep or remove settings/history; either choice ends the active timer session. The uninstaller deletes only known app files, shortcuts and per-user registration. It does not recursively delete the Local AppData directory or unrelated portable-folder contents.

Silent uninstall (`Uninstall.exe /S`) has a deterministic retention policy: keep `settings.ini` and `history.dat`, remove the transient `timer.dat`, and remove app files/registration. This supports unattended removal without silently erasing user preferences or statistics.
