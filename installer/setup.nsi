Unicode true
Target x86-unicode
!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "nsDialogs.nsh"
!include "x64.nsh"
!include "WinVer.nsh"
!include "FileFunc.nsh"
!define EB_PROJECT_ROOT "${__FILEDIR__}\.."
!define EB_COORDINATOR_MUTEX "Local\EyeBreakReminder.UpdateCoordinator.1"
!define EB_RUNONCE_KEY "Software\Microsoft\Windows\CurrentVersion\RunOnce"
!define EB_RECOVERY_VALUE "!EyeBreakReminderUpdateRecovery"
Name "Eye Break Reminder"
OutFile "${EB_PROJECT_ROOT}\release\EyeBreakReminder-Setup-x64.exe"
InstallDir "$LOCALAPPDATA\Programs\EyeBreakReminder"
InstallDirRegKey HKCU "Software\EyeBreakReminder" "InstallDir"
RequestExecutionLevel user
ManifestSupportedOS Win10
ManifestDPIAwareness PerMonitorV2
SetCompressor /SOLID lzma
BrandingText "Eye Break Reminder"
VIProductVersion "1.4.2.0"
VIAddVersionKey /LANG=1033 "ProductName" "Eye Break Reminder"
VIAddVersionKey /LANG=1033 "FileDescription" "Eye Break Reminder Setup"
VIAddVersionKey /LANG=1033 "FileVersion" "1.4.2.0"
VIAddVersionKey /LANG=1033 "ProductVersion" "1.4.2"
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
UninstPage custom un.UserDataPageCreate un.UserDataPageLeave
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_UNPAGE_FINISH
!insertmacro MUI_LANGUAGE "English"
Var UnKeepDataRadio
Var UnRemoveDataRadio
Var UnRemoveUserData
Var InstallMutex
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
Function un.onInit
  ; Silent uninstall has a stable, conservative policy: keep settings/history.
  StrCpy $UnRemoveUserData 0
FunctionEnd
Function un.UserDataPageCreate
  ${If} ${Silent}
    Abort
  ${EndIf}
  !insertmacro MUI_HEADER_TEXT "Application data" "Choose whether to keep or remove your Eye Break Reminder settings and history."
  nsDialogs::Create 1018
  Pop $0
  ${If} $0 == error
    Abort
  ${EndIf}
  ${NSD_CreateRadioButton} 0 0 100% 14u "Keep my settings and history (Recommended)"
  Pop $UnKeepDataRadio
  ${NSD_Check} $UnKeepDataRadio
  ${NSD_CreateRadioButton} 0 24u 100% 14u "Remove my settings and history"
  Pop $UnRemoveDataRadio
  ${NSD_CreateLabel} 0 50u 100% 40u "Keeping your data lets you restore it if you reinstall later. The active timer checkpoint is removed during uninstall. Silent uninstall keeps settings and history."
  Pop $0
  nsDialogs::Show
FunctionEnd
Function un.UserDataPageLeave
  ${NSD_GetState} $UnRemoveDataRadio $0
  ${If} $0 == ${BST_CHECKED}
    StrCpy $UnRemoveUserData 1
  ${Else}
    StrCpy $UnRemoveUserData 0
  ${EndIf}
FunctionEnd
; Keep the mutex handle open for the life of setup. The coordinator uses the
; existence of this same named object to serialize updates and rollback.
Function GuardPendingUpdate
  System::Call 'kernel32::CreateMutexW(p 0, i 0, w "${EB_COORDINATOR_MUTEX}") p.r0 ?e'
  Pop $1
  StrCpy $InstallMutex $0
  StrCmp $0 0 busy
  StrCmp $1 183 0 standalone
  Call IsCoordinatorSetup
  Pop $0
  StrCmp $0 1 allowed busy
  standalone:
    ; Query presence independently of the value type and content.
    System::Call 'advapi32::RegOpenKeyExW(p 0x80000001, w "${EB_RUNONCE_KEY}", i 0, i 0x101, *p .r0) i.r1'
    StrCmp $1 2 scan_journals
    StrCmp $1 0 0 pending
    System::Call 'advapi32::RegQueryValueExW(p r0, w "${EB_RECOVERY_VALUE}", p 0, p 0, p 0, p 0) i.r1'
    System::Call 'advapi32::RegCloseKey(p r0) i'
    StrCmp $1 2 scan_journals pending
  scan_journals:
    Call HasInterruptedJournal
    Pop $0
    StrCmp $0 1 pending allowed
  pending:
    SetErrorLevel 20
    MessageBox MB_OK|MB_ICONINFORMATION "Eye Break Reminder has pending update recovery. Setup has made no changes. Let Windows finish recovery or contact support before reinstalling." /SD IDOK
    Quit
  busy:
    SetErrorLevel 21
    MessageBox MB_OK|MB_ICONINFORMATION "Another Eye Break Reminder setup, update, or recovery is running. Close it before running setup again." /SD IDOK
    Quit
  allowed:
FunctionEnd
; The authenticated coordinator already verified the signed package. Ordinary
; setup cannot opt into this path with a command-line switch.
Function IsCoordinatorSetup
  ${GetFileName} "$EXEPATH" $0
  StrCmp $0 "EyeBreakReminder-Setup-x64.exe" 0 rejected
  ${GetParent} "$EXEDIR" $0
  StrCmp $0 "$LOCALAPPDATA\EyeBreakReminder\updates" 0 rejected
  System::Call 'kernel32::GetFileAttributesW(w r0) i.r1'
  IntOp $1 $1 & 0x400
  StrCmp $1 0 0 rejected
  System::Call 'kernel32::GetFileAttributesW(w "$EXEDIR") i.r1'
  IntOp $1 $1 & 0x400
  StrCmp $1 0 0 rejected
  ReadRegStr $1 HKCU "${EB_RUNONCE_KEY}" "${EB_RECOVERY_VALUE}"
  StrCpy $2 '$\"$EXEDIR\coordinator.exe$\" --update-recover'
  StrCmpS $1 $2 check_parent
  StrCpy $2 '$2 $\"$EXEDIR\transaction.ini$\"'
  StrCmpS $1 $2 0 rejected
  check_parent:
    Call GetLiveParentImage
    Pop $0
    StrCmp $0 "$EXEDIR\coordinator.exe" 0 rejected
    Push 1
    Return
  rejected:
    Push 0
FunctionEnd
Function GetLiveParentImage
  StrCpy $7 ""
  System::Call 'kernel32::GetCurrentProcessId() i.r0'
  System::Call 'kernel32::CreateToolhelp32Snapshot(i 2, i 0) p.r1'
  StrCmp $1 -1 done
  ; This installer is x86 Unicode. PROCESSENTRY32W is 9 32-bit fields
  ; followed by wchar_t[MAX_PATH].
  System::Alloc 556
  Pop $2
  StrCmp $2 0 close_snapshot
  System::Call '*$2(i 556)'
  System::Call 'kernel32::Process32FirstW(p r1, p r2) i.r3'
  next_process:
    StrCmp $3 0 release_entry
    System::Call '*$2(i, i, i.r4, i, i, i, i.r5)'
    StrCmp $4 $0 query_parent
    System::Call 'kernel32::Process32NextW(p r1, p r2) i.r3'
    Goto next_process
  query_parent:
    StrCmp $5 0 release_entry
    System::Call 'kernel32::OpenProcess(i 0x101000, i 0, i r5) p.r6'
    StrCmp $6 0 release_entry
    System::Call 'kernel32::WaitForSingleObject(p r6, i 0) i.r8'
    StrCmp $8 258 0 close_parent
    System::Call 'kernel32::QueryFullProcessImageNameW(p r6, i 0, w .r7, *i ${NSIS_MAX_STRLEN}) i.r8'
    StrCmp $8 0 0 close_parent
    StrCpy $7 ""
  close_parent:
    System::Call 'kernel32::CloseHandle(p r6) i'
  release_entry:
    System::Free $2
  close_snapshot:
    System::Call 'kernel32::CloseHandle(p r1) i'
  done:
    Push $7
FunctionEnd
; Windows may already have consumed RunOnce after an unsuccessful attempt.
; Keep unresolved app-owned evidence without running the saved command.
Function HasInterruptedJournal
  StrCpy $5 0
  StrCpy $6 "$LOCALAPPDATA\EyeBreakReminder\updates"
  System::Call 'kernel32::GetFileAttributesW(w r6) i.r2'
  IntOp $2 $2 & 0x400
  StrCmp $2 0 0 journal_done
  ClearErrors
  FindFirst $0 $1 "$6\*"
  IfErrors journal_done
  next_stage:
    StrLen $2 $1
    StrCmp $2 38 0 advance_stage
    StrCpy $2 $1 1
    StrCmp $2 "{" 0 advance_stage
    StrCpy $2 $1 1 37
    StrCmp $2 "}" 0 advance_stage
    StrCpy $3 "$6\$1"
    System::Call 'kernel32::GetFileAttributesW(w r3) i.r2'
    IntOp $2 $2 & 0x410
    StrCmp $2 16 0 advance_stage
    System::Call 'kernel32::GetFileAttributesW(w "$3\transaction.ini") i.r2 ?e'
    Pop $7
    ${If} $2 = -1
      StrCmp $7 2 advance_stage
      StrCmp $7 3 advance_stage journal_pending
    ${EndIf}
    IntOp $2 $2 & 0x410
    StrCmp $2 0 0 journal_pending
    StrCpy $3 "$3\transaction-state.ini"
    System::Call 'kernel32::GetFileAttributesW(w r3) i.r2 ?e'
    Pop $7
    ${If} $2 = -1
      ; A transaction file can exist before its first journal is created.
      StrCmp $7 2 advance_stage
      StrCmp $7 3 advance_stage journal_pending
    ${EndIf}
    IntOp $2 $2 & 0x410
    StrCmp $2 0 0 journal_pending
    ClearErrors
    FileOpen $2 "$3" r
    IfErrors journal_pending
    ClearErrors
    FileRead $2 $4 64
    IfErrors close_unreadable
    FileClose $2
    StrCmpS $4 "phase=waiting$\n" advance_stage
    StrCmpS $4 "phase=verified$\n" advance_stage
    StrCmpS $4 "phase=complete$\n" advance_stage
    StrCmpS $4 "phase=recovered$\n" advance_stage journal_pending
  close_unreadable:
    FileClose $2
    Goto journal_pending
  advance_stage:
    ClearErrors
    FindNext $0 $1
    IfErrors close_search next_stage
  journal_pending:
    StrCpy $5 1
  close_search:
    FindClose $0
  journal_done:
    Push $5
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
  Call GuardPendingUpdate
  !insertmacro CloseRunningApp
  ; A fresh install must not resume a timer left by an older uninstaller.
  ; Direct upgrades and repairs of the registered installation keep the timer.
  IfFileExists "$INSTDIR\EyeBreakReminder.exe" keep_timer
  IfFileExists "$INSTDIR\Uninstall.exe" 0 fresh_install
  ReadRegStr $0 HKCU "Software\EyeBreakReminder" "InstallDir"
  ReadRegStr $1 HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder" "InstallLocation"
  StrCmp $0 "" fresh_install
  StrCmp $1 "" fresh_install
  ; Compare the existing uninstaller's normalized path, so differences in
  ; directory spelling or a trailing separator do not turn repair into install.
  GetFullPathName /SHORT $2 "$INSTDIR\Uninstall.exe"
  GetFullPathName /SHORT $0 "$0\Uninstall.exe"
  GetFullPathName /SHORT $1 "$1\Uninstall.exe"
  StrCmp $2 "" fresh_install
  StrCmp $0 $2 0 fresh_install
  StrCmp $1 $2 keep_timer
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
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder" "DisplayVersion" "1.4.2"
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
  ${If} $UnRemoveUserData == 1
    ; Delete only the application's known files in its exact per-user data folder.
    Delete "$LOCALAPPDATA\EyeBreakReminder\settings.ini"
    Delete "$LOCALAPPDATA\EyeBreakReminder\history.dat"
    RMDir "$LOCALAPPDATA\EyeBreakReminder"
  ${EndIf}
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
