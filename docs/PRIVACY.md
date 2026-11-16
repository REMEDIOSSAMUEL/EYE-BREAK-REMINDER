# Privacy and Windows integration

| Capability | Behaviour |
|---|---|
| Internet, accounts, telemetry, cloud, advertising | Optional update checks contact only the public official GitHub Releases API. If the user installs an update, the selected official release asset is downloaded over HTTPS. No credentials, settings, history or other user data are sent; there is no telemetry, cloud sync or advertising. Both automatic-check preferences default off. |
| Administrator privileges | Not requested by the app or configured per-user installer. |
| Services, drivers, scheduled tasks | None. |
| Camera, microphone, location | Not accessed. |
| Windows integration | Monitors, workstation lock/sleep messages, time and time-zone change messages, system theme/text/DPI preferences, tray and optional Shell notifications. Accessible names for schedule fields use the in-process Windows accessibility annotation service. |
| Startup | Explicit opt-in HKCU `Software\Microsoft\Windows\CurrentVersion\Run\EyeBreakReminder` value. Uninstall removes it only when it matches this installed executable. |
| Interrupted-update recovery | A per-user HKCU RunOnce entry is created only during an update transaction and removed after completion or rollback. It launches the staged recovery coordinator at the next sign-in if Windows restarts during replacement. |
| Installation registry | Per-user `Software\EyeBreakReminder` install directory and `Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder` Installed Apps entry. No fake publisher is written. |
| Local data | Settings, timer checkpoint and bounded break history under `%LOCALAPPDATA%\EyeBreakReminder`. No uploads. |
| Operating schedule | Stored only in the local `settings.ini`. It is evaluated by the running app with the Windows local time zone; it needs no network, cloud service, account, scheduled task, background service or extra permission, and it never starts the app. |
| Audio | Embedded PCM sounds mixed through Windows waveOut; only sample amplitudes are scaled. Global audio settings are unchanged. |

Normal upgrades preserve preferences, history and the current timer checkpoint. Clean Install resets settings and the timer checkpoint; history is kept unless the user separately confirms its removal. Interactive uninstall offers Keep or Remove settings/history; silent uninstall keeps settings/history and removes the transient timer checkpoint. Uninstall removes program files, shortcuts and app registration without recursively deleting the shared Local AppData directory. Clear history in the app with confirmation, or quit and remove only the documented Eye Break Reminder data files to remove personal data.
