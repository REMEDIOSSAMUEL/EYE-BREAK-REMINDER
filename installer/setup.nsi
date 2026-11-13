Unicode true
Target x86-unicode
!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "x64.nsh"
!include "WinVer.nsh"
!define EB_PROJECT_ROOT "${__FILEDIR__}\.."
Name "Eye Break Reminder"
OutFile "${EB_PROJECT_ROOT}\release\EyeBreakReminder-Setup-x64.exe"
InstallDir "$LOCALAPPDATA\Programs\EyeBreakReminder"
InstallDirRegKey HKCU "Software\EyeBreakReminder" "InstallDir"
RequestExecutionLevel user
ManifestSupportedOS Win10
ManifestDPIAwareness PerMonitorV2
SetCompressor /SOLID lzma
BrandingText "Eye Break Reminder"
VIProductVersion "1.3.0.0"
VIAddVersionKey /LANG=1033 "ProductName" "Eye Break Reminder"
VIAddVersionKey /LANG=1033 "FileDescription" "Eye Break Reminder Setup"
VIAddVersionKey /LANG=1033 "FileVersion" "1.3.0.0"
VIAddVersionKey /LANG=1033 "ProductVersion" "1.3.0"
!define MUI_ICON "${EB_PROJECT_ROOT}\assets\App.ico"
!define MUI_UNICON "${EB_PROJECT_ROOT}\assets\App.ico"
!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\EyeBreakReminder.exe"
!define MUI_FINISHPAGE_RUN_TEXT "Open Eye Break Reminder"
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_UNPAGE_FINISH
!insertmacro MUI_LANGUAGE "English"
Function .onInit
  SetRegView 64
  ${IfNot} ${IsNativeAMD64}
    MessageBox MB_OK|MB_ICONINFORMATION "Eye Break Reminder requires Windows 11 x64."
    Abort
  ${EndIf}
  ${IfNot} ${AtLeastWin10}
    MessageBox MB_OK|MB_ICONINFORMATION "Eye Break Reminder requires Windows 11 x64."
    Abort
  ${EndIf}
  ReadRegStr $0 HKLM "SOFTWARE\Microsoft\Windows NT\CurrentVersion" "CurrentBuildNumber"
  IntCmp $0 22000 valid invalid valid
  invalid:
    MessageBox MB_OK|MB_ICONINFORMATION "Eye Break Reminder requires Windows 11 (build 22000 or newer)."
    Abort
  valid:
FunctionEnd
!macro CloseRunningApp
  FindWindow $0 "EyeBreakReminder.Native"
  ${If} $0 != 0
    System::Call 'user32::RegisterWindowMessageW(w "EyeBreakReminder.Exit.Native.1") i.r1'
    System::Call 'user32::SendMessageTimeoutW(p r0, i r1, p 0, p 0, i 2, i 3000, *p .r2) p.r3'
    Sleep 500
    FindWindow $0 "EyeBreakReminder.Native"
    ${If} $0 != 0
      MessageBox MB_OK|MB_ICONINFORMATION "Please exit Eye Break Reminder using its tray menu, then run setup again."
      Abort
    ${EndIf}
  ${EndIf}
!macroend
Section "Eye Break Reminder (required)" MainSection
  SectionIn RO
  SetShellVarContext current
  SetRegView 64
  !insertmacro CloseRunningApp
  ; A fresh install must not resume a timer left by an older uninstaller.
  ; Direct upgrades keep the active countdown, preferences and history.
  IfFileExists "$INSTDIR\EyeBreakReminder.exe" keep_timer fresh_install
  fresh_install:
    Delete "$LOCALAPPDATA\EyeBreakReminder\timer.dat"
  keep_timer:
  SetOutPath "$INSTDIR"
  File "${EB_PROJECT_ROOT}\release\EyeBreakReminder.exe"
  File "${EB_PROJECT_ROOT}\README.md"
  File "${EB_PROJECT_ROOT}\docs\PRIVACY.md"
  File "${EB_PROJECT_ROOT}\docs\VERIFICATION.md"
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  CreateDirectory "$SMPROGRAMS\Eye Break Reminder"
  CreateShortcut "$SMPROGRAMS\Eye Break Reminder\Eye Break Reminder.lnk" "$INSTDIR\EyeBreakReminder.exe" "" "$INSTDIR\EyeBreakReminder.exe" 0
  WriteRegStr HKCU "Software\EyeBreakReminder" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder" "DisplayName" "Eye Break Reminder"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder" "DisplayVersion" "1.3.0"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder" "UninstallString" '$\"$INSTDIR\Uninstall.exe$\"'
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder" "DisplayIcon" "$INSTDIR\EyeBreakReminder.exe"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder" "InstallLocation" "$INSTDIR"
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder" "NoRepair" 1
SectionEnd
Section /o "Desktop shortcut" DesktopSection
  SetShellVarContext current
  CreateShortcut "$DESKTOP\Eye Break Reminder.lnk" "$INSTDIR\EyeBreakReminder.exe" "" "$INSTDIR\EyeBreakReminder.exe" 0
SectionEnd
Section "Uninstall"
  SetShellVarContext current
  SetRegView 64
  !insertmacro CloseRunningApp
  ; Keep preferences/history, but an uninstall ends the active timer session.
  Delete "$LOCALAPPDATA\EyeBreakReminder\timer.dat"
  ReadRegStr $0 HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "EyeBreakReminder"
  StrCmp $0 '$\"$INSTDIR\EyeBreakReminder.exe$\" --startup' 0 +2
    DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "EyeBreakReminder"
  Delete "$DESKTOP\Eye Break Reminder.lnk"
  Delete "$SMPROGRAMS\Eye Break Reminder\Eye Break Reminder.lnk"
  RMDir "$SMPROGRAMS\Eye Break Reminder"
  Delete "$INSTDIR\EyeBreakReminder.exe"
  Delete "$INSTDIR\README.md"
  Delete "$INSTDIR\PRIVACY.md"
  Delete "$INSTDIR\VERIFICATION.md"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder"
  DeleteRegKey HKCU "Software\EyeBreakReminder"
  ; Preserve settings/history in LOCALAPPDATA\EyeBreakReminder.
SectionEnd
