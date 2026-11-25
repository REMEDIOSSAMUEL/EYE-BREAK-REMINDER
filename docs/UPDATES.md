# Checking for and installing updates

## Check preferences

Open Settings → About. **Check for Updates** checks only the official public stable-release API for `REMEDIOSSAMUEL/EYE-BREAK-REMINDER`. It sends no GitHub credentials and no user settings or history. Drafts, prereleases, malformed versions, same/older versions and packages without usable GitHub SHA-256 metadata are not installed.

Automatic checks and automatic background downloads are optional and default off. Automatic checks run at most once per day. Even if automatic download is enabled, setup never begins without the user's confirmation. Prompts and automatic downloads wait while a break is active. If a user-approved download is already running when a break starts, it continues in the background and the progress window is hidden until the break ends.

## Install dialog

The native dialog shows current and available versions, release notes, and the known download size. **Preserve my settings (Recommended)** is selected by default. **Clean install — reset previous settings** must be selected explicitly and confirmed. The separate history/statistics deletion checkbox is unchecked by default. See [Settings](SETTINGS.md) for data behavior and [Updater architecture](V1.4.0_UPDATER_ARCHITECTURE.md) for process/recovery details.

Download progress is based on bytes actually written. The user can cancel until the download is verified and the install coordinator is launched. The old app then closes through its own shutdown path, the separate coordinator invokes the per-user installer or portable file replacement, and the new app must confirm startup before the update is marked complete.

## Network and recovery errors

Network/API, rate-limit, redirect, size, SHA-256, permissions, low-space and installer errors are reported as failures; the app does not treat malformed responses as “up to date.” Download and verification failures leave the current app unchanged. Failed installations attempt transaction rollback. If Windows prevents rollback, the previous executable/data backups and durable recovery state are retained and an actionable message is shown.

If recovery is pending, let it finish before trying repair. If the app cannot complete rollback, preserve the transaction folder and contact support. See [Recovery and repair](INSTALLER.md#recovery-and-repair) for when same-directory setup can repair the application.

## First transition

Published v1.3.0 does not contain the integrated downloader/coordinator. Its check-only UI cannot automatically install v1.4.0. Download v1.4.0 from the official release and run Setup manually, or close a portable copy and replace its executable with the one from the new portable ZIP. The initial setup and executable are Authenticode unsigned. Windows may show an unknown-publisher or SmartScreen warning. Later signed updates can be installed from within the app.
