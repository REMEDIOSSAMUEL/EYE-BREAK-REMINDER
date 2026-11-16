# Checking for and installing updates

## Check preferences

Open Settings → About. **Check for Updates** checks only the official public stable-release API for `REMEDIOSSAMUEL/EYE-BREAK-REMINDER`. It sends no GitHub credentials and no user settings or history. Drafts, prereleases, malformed versions, same/older versions and packages without usable GitHub SHA-256 metadata are not installed.

Automatic checks and automatic background downloads are optional and default off. Automatic checks run at most once per day. Even if automatic download is enabled, setup never begins without the user's confirmation. An update prompt/download waits while a break is active.

## Install dialog

The native dialog shows current and available versions, release notes, and the known download size. **Preserve my settings (Recommended)** is selected by default. **Clean install — reset previous settings** must be selected explicitly and confirmed. The separate history/statistics deletion checkbox is unchecked by default. See [Settings](SETTINGS.md) for data behavior and [Updater architecture](V1.4.0_UPDATER_ARCHITECTURE.md) for process/recovery details.

Download progress is based on bytes actually written. The user can cancel until the download is verified and the install coordinator is launched. The old app then closes through its own shutdown path, the separate coordinator invokes the per-user installer or portable file replacement, and the new app must confirm startup before the update is marked complete.

## Network and recovery errors

Network/API, rate-limit, redirect, size, SHA-256, permissions, low-space and installer errors are reported as failures; the app does not treat malformed responses as “up to date.” Download and verification failures leave the current app unchanged. Failed installations attempt transaction rollback. If Windows prevents rollback, the previous executable/data backups and durable recovery state are retained and an actionable message is shown.

## First transition

Published v1.3.0 does not contain the integrated downloader/coordinator. Its check-only UI cannot automatically install v1.4.0. The one-time upgrade to v1.4.0 uses the ordinary downloaded v1.4.0 Setup executable. Updates after v1.4.0 can be installed from within the app.
