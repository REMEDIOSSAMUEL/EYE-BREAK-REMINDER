# Privacy and Windows integration

| Capability | Behaviour |
|---|---|
| Internet, accounts, telemetry, cloud, advertising | None in the app or installer. Network is used only to obtain build tools. |
| Administrator privileges | Not requested by the app or configured per-user installer. |
| Services, drivers, scheduled tasks | None. |
| Camera, microphone, location | Not accessed. |
| Windows integration | Monitors, workstation lock/sleep messages, time and time-zone change messages, system theme/text/DPI preferences, tray and optional Shell notifications. Accessible names for schedule fields use the in-process Windows accessibility annotation service. |
| Startup | Explicit opt-in HKCU `Software\Microsoft\Windows\CurrentVersion\Run\EyeBreakReminder` value. Uninstall removes it only when it matches this installed executable. |
| Installation registry | Per-user `Software\EyeBreakReminder` install directory and `Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder` Installed Apps entry. No fake publisher is written. |
| Local data | Settings, timer checkpoint and bounded break history under `%LOCALAPPDATA%\EyeBreakReminder`. No uploads. |
| Operating schedule | Stored only in the local `settings.ini`. It is evaluated by the running app with the Windows local time zone; it needs no network, cloud service, account, scheduled task, background service or extra permission, and it never starts the app. |
| Audio | Embedded PCM sounds mixed through Windows waveOut; only sample amplitudes are scaled. Global audio settings are unchanged. |

Direct upgrades preserve the countdown and personal settings/history. Uninstall deletes the timer checkpoint, program files, shortcuts and its registry registrations, while keeping preferences/history. Fresh installation also discards timer checkpoints left by an older uninstaller. Clear history in the app with confirmation, or quit and delete the documented data folder to remove all personal data.
