param(
  [Parameter(Mandatory=$true)][string]$ExecutablePath,
  [Parameter(Mandatory=$true)][string]$EvidenceDirectory
)

$ErrorActionPreference = 'Stop'
$expectedSha256 = '07f6c1eaee5818df9f5c024310883ca94b8274a4f451186a8123974fb5e5f720'
$candidateArtifactId = '14695418078'
$candidateRunId = '44875679345'
$candidateSourceCommit = '491bd2ed29f84f4d434b884fc723144db2d6f294'

# This probe is deliberately restricted to the fresh, disposable GitHub-hosted
# Windows 11 ARM64 runner. It never installs the candidate and never edits a
# pre-existing EyeBreakReminder profile.
if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows' -or $env:RUNNER_ARCH -cne 'ARM64' -or $env:GITHUB_SERVER_URL -cne 'https://github.com' -or $env:GITHUB_REPOSITORY -ine 'REMEDIOSSAMUEL/EYE-BREAK-REMINDER' -or -not $env:RUNNER_NAME) {
  throw 'BLOCKED: this Narrator probe may run only on a GitHub-hosted Windows 11 ARM64 runner.'
}
if (-not $env:GITHUB_WORKSPACE -or -not $env:RUNNER_TEMP -or -not [Environment]::UserInteractive) {
  throw 'BLOCKED: GitHub workspace and runner temporary roots are required.'
}

$workspaceRoot = [IO.Path]::GetFullPath($env:GITHUB_WORKSPACE).TrimEnd('\') + '\'
$runnerTempRoot = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\') + '\'
$ExecutablePath = [IO.Path]::GetFullPath($ExecutablePath)
$EvidenceDirectory = [IO.Path]::GetFullPath($EvidenceDirectory)
if (-not ($ExecutablePath.StartsWith($workspaceRoot, [StringComparison]::OrdinalIgnoreCase) -or $ExecutablePath.StartsWith($runnerTempRoot, [StringComparison]::OrdinalIgnoreCase))) {
  throw 'BLOCKED: the candidate must be staged inside the GitHub workspace or runner temporary directory.'
}
if (-not ($EvidenceDirectory.StartsWith($workspaceRoot, [StringComparison]::OrdinalIgnoreCase) -or $EvidenceDirectory.StartsWith($runnerTempRoot, [StringComparison]::OrdinalIgnoreCase))) {
  throw 'BLOCKED: evidence must be written inside the GitHub workspace or runner temporary directory.'
}

[void][IO.Directory]::CreateDirectory($EvidenceDirectory)
$resultPath = Join-Path $EvidenceDirectory 'gui-016-narrator-speech-recap.json'
$transcriptPath = Join-Path $EvidenceDirectory 'gui-016-narrator-speech.txt'
$logPath = Join-Path $EvidenceDirectory 'gui-016-narrator-speech.log'
$scriptTranscriptStarted = $false
$candidateProcess = $null
$candidatePid = 0
$candidateOwned = $false
$candidateStoppedByHarness = $false
$narratorProcess = $null
$narratorPid = 0
$narratorOwned = $false
$narratorStoppedByHarness = $false
$dataDirectory = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'EyeBreakReminder'))
$localAppDataRoot = [IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd('\') + '\'
$dataExistedBefore = Test-Path -LiteralPath $dataDirectory
$dataCreatedByHarness = $false
$dataRemoved = $false
$cleanupErrors = [System.Collections.Generic.List[string]]::new()
$assertions = [System.Collections.Generic.List[object]]::new()
$focusTrace = [System.Collections.Generic.List[object]]::new()
$speechCaptures = [System.Collections.Generic.List[object]]::new()
$screenshots = [System.Collections.Generic.List[string]]::new()
$oobeActions = [System.Collections.Generic.List[object]]::new()
$events = [System.Collections.Generic.List[object]]::new()
$status = 'BLOCKED'
$reason = 'Preflight did not complete.'
$speechAcceptanceAssertionRecorded = $false
$osRecord = $null
$nativeCpuArchitecture = $null
$sessionId = $null
$candidateIdentity = $null
$narratorRecord = $null
$physicalAudioVerified = $false

function Add-Event([string]$Name, [string]$Status, $Details=$null) {
  $events.Add([pscustomobject]@{ Name=$Name; Status=$Status; Details=$Details; Utc=[DateTime]::UtcNow.ToString('o') })
}

function Add-Assertion([string]$Name, [bool]$Passed, $Details=$null, [string]$FailureStatus='NOT TESTED') {
  $assertionStatus = if ($Passed) { 'PASS' } else { $FailureStatus }
  $assertions.Add([pscustomobject]@{ Name=$Name; Passed=$Passed; Status=$assertionStatus; Details=$Details; Utc=[DateTime]::UtcNow.ToString('o') })
  Add-Event $Name $assertionStatus $Details
}

function Get-FocusSnapshot([int]$CandidateProcessId, [string]$Phase) {
  $snapshot = [pscustomobject]@{
    Phase=$Phase; Utc=[DateTime]::UtcNow.ToString('o'); ProcessId=$null; IsCandidateProcess=$false
    Name=''; AutomationId=''; ControlType=''; ClassName=''; HasKeyboardFocus=$false
    IsKeyboardFocusable=$false; NativeWindowHandle=[long]0; Bounds=$null; Error=$null
  }
  try {
    $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
    if ($null -eq $focused) { throw 'UI Automation returned no focused element.' }
    $current = $focused.Current
    $bounds = $current.BoundingRectangle
    $snapshot.ProcessId = [int]$current.ProcessId
    $snapshot.IsCandidateProcess = ($snapshot.ProcessId -eq $CandidateProcessId)
    $snapshot.Name = [string]$current.Name
    $snapshot.AutomationId = [string]$current.AutomationId
    $snapshot.ControlType = [string]$current.ControlType.ProgrammaticName
    $snapshot.ClassName = [string]$current.ClassName
    $snapshot.HasKeyboardFocus = [bool]$current.HasKeyboardFocus
    $snapshot.IsKeyboardFocusable = [bool]$current.IsKeyboardFocusable
    $snapshot.NativeWindowHandle = [long]$current.NativeWindowHandle
    $snapshot.Bounds = @([double]$bounds.Left, [double]$bounds.Top, [double]$bounds.Width, [double]$bounds.Height)
  } catch { $snapshot.Error = $_.Exception.Message }
  $focusTrace.Add($snapshot)
  return $snapshot
}

function Get-ControlElement([IntPtr]$MainWindow, [int]$ControlId, [string]$Description) {
  $handle = [EBR_NARRATOR_NATIVE]::FindVisibleChildById($MainWindow, $ControlId)
  if ($handle -eq [IntPtr]::Zero) { throw "NOT TESTED: the candidate does not currently expose visible enabled control ID $ControlId ($Description)." }
  $element = [System.Windows.Automation.AutomationElement]::FromHandle($handle)
  if ($null -eq $element) { throw "UI Automation could not attach to candidate control ID $ControlId ($Description)." }
  $current = $element.Current
  if ($current.ProcessId -ne $candidatePid) { throw "Control ID $ControlId is owned by PID $($current.ProcessId), not candidate PID $candidatePid." }
  $control = [pscustomobject]@{ Handle=$handle; Element=$element; ProcessId=[int]$current.ProcessId; Name=[string]$current.Name; AutomationId=[string]$current.AutomationId; ControlType=[string]$current.ControlType.ProgrammaticName; ClassName=[string]$current.ClassName; Enabled=[bool]$current.IsEnabled; Offscreen=[bool]$current.IsOffscreen; KeyboardFocusable=[bool]$current.IsKeyboardFocusable; NativeWindowHandle=[int]$current.NativeWindowHandle; Bounds=@([double]$current.BoundingRectangle.Left,[double]$current.BoundingRectangle.Top,[double]$current.BoundingRectangle.Width,[double]$current.BoundingRectangle.Height) }
  if ([string]::IsNullOrWhiteSpace($control.Name)) { throw "PRODUCT DEFECT: visible candidate control ID $ControlId ($Description) has no accessible name." }
  if (-not $control.KeyboardFocusable) { throw "PRODUCT DEFECT: visible candidate control ID $ControlId ($Description) is not keyboard-focusable in UI Automation." }
  if (-not $control.Enabled -or $control.Offscreen) { throw "NOT TESTED: candidate control ID $ControlId ($Description) is disabled or offscreen." }
  if ($control.NativeWindowHandle -ne [int]$handle.ToInt64()) { throw "NOT TESTED: UI Automation native identity for control ID $ControlId ($Description) does not match its native HWND." }
  return $control
}

function Capture-WindowScreenshot([IntPtr]$Window, [string]$FileName, [string]$Description) {
  $bounds = [EBR_NARRATOR_NATIVE]::Bounds($Window)
  if ($bounds.Count -ne 4) { throw "Could not obtain the $Description window rectangle for a target-window screenshot." }
  $width = $bounds[2] - $bounds[0]
  $height = $bounds[3] - $bounds[1]
  if ($width -lt 100 -or $height -lt 100 -or $width -gt 5000 -or $height -gt 4000) { throw "$Description window rectangle is not usable for a target-window screenshot: ${width}x${height}." }
  Add-Type -AssemblyName System.Drawing -ErrorAction Stop
  $bitmap = [Drawing.Bitmap]::new($width, $height)
  $graphics = [Drawing.Graphics]::FromImage($bitmap)
  $path = Join-Path $EvidenceDirectory $FileName
  try {
    # Crop to the verified target HWND; do not capture the full desktop.
    $graphics.CopyFromScreen($bounds[0], $bounds[1], 0, 0, $bitmap.Size)
    $bitmap.Save($path, [Drawing.Imaging.ImageFormat]::Png)
  } finally { $graphics.Dispose(); $bitmap.Dispose() }
  $screenshots.Add($path)
  return [pscustomobject]@{ Path=$path; Width=$width; Height=$height; WindowBounds=$bounds; Capture="$Description HWND bounds only" }
}

function Capture-CandidateWindow([IntPtr]$Window, [string]$FileName) {
  return Capture-WindowScreenshot $Window $FileName 'candidate'
}

function Find-PrivacyOobeWindow {
  $root = [System.Windows.Automation.AutomationElement]::RootElement
  $elements = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
  $privacyWindows = [System.Collections.Generic.List[object]]::new()
  foreach ($element in $elements) {
    try {
      if ([string]$element.Current.Name -cne 'Choose privacy settings for your device') { continue }
      $ancestor = $element
      for ($depth = 0; $depth -lt 20 -and $null -ne $ancestor; $depth++) {
        if ($ancestor.Current.ControlType -eq [System.Windows.Automation.ControlType]::Window) {
          $windowHandle = [IntPtr]$ancestor.Current.NativeWindowHandle
          if ($windowHandle -eq [IntPtr]::Zero -or -not [EBR_NARRATOR_NATIVE]::IsWindowVisible($windowHandle) -or $ancestor.Current.IsOffscreen) { break }
          $foreground = [EBR_NARRATOR_NATIVE]::ForegroundWindow()
          if ($foreground -ne $windowHandle -or [EBR_NARRATOR_NATIVE]::OwnerProcessId($foreground) -le 0) { break }
          if (@($privacyWindows | Where-Object { $_.Handle -eq $windowHandle }).Count -eq 0) {
            $privacyWindows.Add([pscustomobject]@{ Page=$element; Window=$ancestor; Handle=$windowHandle; PageName=[string]$element.Current.Name; WindowName=[string]$ancestor.Current.Name; OwnerProcessId=[EBR_NARRATOR_NATIVE]::OwnerProcessId($windowHandle) })
          }
          break
        }
        $ancestor = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($ancestor)
      }
    } catch {}
  }
  if ($privacyWindows.Count -gt 1) { throw "NOT TESTED: found $($privacyWindows.Count) visible foreground top-level windows containing the exact privacy page; no OOBE action was taken." }
  if ($privacyWindows.Count -eq 1) { return $privacyWindows[0] }
  return $null
}

function Resolve-PrivacyOobeIfPresent {
  $oobeWindow = Find-PrivacyOobeWindow
  if ($null -eq $oobeWindow) {
    $oobeActions.Add([pscustomobject]@{Detected=$false;Action='None';Reason='No unique visible foreground top-level window exposed the exact Windows privacy OOBE page.';Utc=[DateTime]::UtcNow.ToString('o')})
    return
  }
  $windowHandle = [IntPtr]$oobeWindow.Handle
  $title = [string]$oobeWindow.WindowName
  $buttons = @($oobeWindow.Window.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition) | Where-Object {
    try { $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and $_.Current.IsEnabled -and -not $_.Current.IsOffscreen -and $_.Current.Name -ceq 'Next' -and $_.Current.NativeWindowHandle -ne 0 -and [EBR_NARRATOR_NATIVE]::IsWindowVisible([IntPtr]$_.Current.NativeWindowHandle) } catch { $false }
  })
  if ($buttons.Count -ne 1) { throw "NOT TESTED: the exact privacy OOBE page was visible but did not expose one enabled Next button; no unknown screen was clicked. Title='$title'; NextButtons=$($buttons.Count)." }
  $nextButton = $buttons[0]
  $buttonRecord = [pscustomobject]@{Name=[string]$nextButton.Current.Name;ControlType=[string]$nextButton.Current.ControlType.ProgrammaticName;AutomationId=[string]$nextButton.Current.AutomationId;Bounds=@([double]$nextButton.Current.BoundingRectangle.Left,[double]$nextButton.Current.BoundingRectangle.Top,[double]$nextButton.Current.BoundingRectangle.Width,[double]$nextButton.Current.BoundingRectangle.Height)}
  $privacyToggles = @(
    foreach ($node in $oobeWindow.Window.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)) {
      try {
        if ($node.Current.IsOffscreen -or -not $node.Current.IsEnabled) { continue }
        $toggle = [System.Windows.Automation.TogglePattern]$node.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
        [pscustomobject]@{Name=[string]$node.Current.Name;AutomationId=[string]$node.Current.AutomationId;ControlType=[string]$node.Current.ControlType.ProgrammaticName;ToggleState=[string]$toggle.Current.ToggleState;Bounds=@([double]$node.Current.BoundingRectangle.Left,[double]$node.Current.BoundingRectangle.Top,[double]$node.Current.BoundingRectangle.Width,[double]$node.Current.BoundingRectangle.Height)}
      } catch {}
    }
  )
  if ($privacyToggles.Count -eq 0 -or @($privacyToggles | Where-Object { [string]::IsNullOrWhiteSpace($_.Name) }).Count -gt 0) { throw 'NOT TESTED: the visible privacy OOBE page did not expose named toggle states; no OOBE action was taken.' }
  $oobeShot = Capture-WindowScreenshot $windowHandle 'gui-016-windows-privacy-oobe-before-next.png' 'Windows privacy OOBE'
  $oobeActions.Add([pscustomobject]@{Detected=$true;PageName=$oobeWindow.PageName;WindowTitle=$title;WindowHandle=('0x{0:X}' -f $windowHandle.ToInt64());OwnerProcessId=$oobeWindow.OwnerProcessId;Screenshot=$oobeShot.Path;PrivacyToggleValues=$privacyToggles;Action='Invoke the exact visible privacy page Next button through UI Automation; leave every displayed toggle unchanged';Button=$buttonRecord;AgreementAccepted=$false;SettingsEffect='Not measured; advancing may apply the displayed privacy choices.';Utc=[DateTime]::UtcNow.ToString('o')})
  try { $invoke = [System.Windows.Automation.InvokePattern]$nextButton.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern); $invoke.Invoke() }
  catch { throw "NOT TESTED: could not advance only the detected Windows privacy page through its Next control: $($_.Exception.Message)" }
  $watch = [Diagnostics.Stopwatch]::StartNew()
  while ($watch.Elapsed.TotalSeconds -lt 12) {
    Start-Sleep -Milliseconds 150
    if ($null -eq (Find-PrivacyOobeWindow)) {
      $oobeActions.Add([pscustomobject]@{Detected=$true;Action='Verify the exact privacy page closed after Next';Status='PASS';Utc=[DateTime]::UtcNow.ToString('o')})
      Add-Event 'Advance only the Windows first-run privacy page; do not accept license/consent screens' 'PASS' ([pscustomobject]@{PageName=$oobeWindow.PageName;WindowTitle=$title;Button=$buttonRecord;PrivacyToggleValues=$privacyToggles;Screenshot=$oobeShot.Path;AgreementAccepted=$false;SettingsEffect='Not measured; advancing may apply the displayed privacy choices.'})
      return
    }
  }
  throw 'NOT TESTED: the privacy OOBE page remained after invoking its Next button; no other setup page was touched.'
}

function Wait-CandidateFocus([string]$Phase, [int]$TimeoutSeconds=5) {
  $watch = [Diagnostics.Stopwatch]::StartNew()
  $snapshot = $null
  while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
    $snapshot = Get-FocusSnapshot $candidatePid $Phase
    if ($snapshot.IsCandidateProcess) { return $snapshot }
    Start-Sleep -Milliseconds 100
  }
  return $snapshot
}

function Test-SameFocusIdentity($Left, $Right) {
  return ($Left.ProcessId -eq $Right.ProcessId -and $Left.NativeWindowHandle -eq $Right.NativeWindowHandle -and $Left.Name -ceq $Right.Name -and $Left.AutomationId -ceq $Right.AutomationId -and $Left.ControlType -ceq $Right.ControlType -and $Left.ClassName -ceq $Right.ClassName)
}

function Assert-ExactCandidateFocus($Control, [string]$Phase, $ExpectedIdentity=$null) {
  $foreground = [EBR_NARRATOR_NATIVE]::ForegroundWindow()
  $foregroundPid = [EBR_NARRATOR_NATIVE]::OwnerProcessId($foreground)
  if ($foreground -ne $mainWindow -or $foregroundPid -ne $candidatePid) { throw "NOT TESTED: candidate lost the foreground before or during $Phase; no Narrator command was sent." }
  $snapshot = Get-FocusSnapshot $candidatePid $Phase
  if (-not $snapshot.IsCandidateProcess) { throw "NOT TESTED: UI Automation focus left the candidate during $Phase." }
  if ($snapshot.NativeWindowHandle -ne [long]$Control.Handle.ToInt64()) { throw "NOT TESTED: the focused candidate HWND does not match the intended control during $Phase." }
  if ([string]::IsNullOrWhiteSpace($snapshot.Name)) { throw "PRODUCT DEFECT: focused candidate control $($Control.ControlType) has no accessible name during $Phase." }
  if ($snapshot.Name -cne $Control.Name -or $snapshot.AutomationId -cne $Control.AutomationId -or $snapshot.ControlType -cne $Control.ControlType -or $snapshot.ClassName -cne $Control.ClassName) {
    throw "PRODUCT DEFECT: UI Automation identity for the focused candidate control changed during $Phase. Expected $($Control | Select-Object Name,AutomationId,ControlType,ClassName,NativeWindowHandle | ConvertTo-Json -Compress); observed $($snapshot | Select-Object Name,AutomationId,ControlType,ClassName,NativeWindowHandle | ConvertTo-Json -Compress)."
  }
  if (-not $snapshot.IsKeyboardFocusable -or -not $snapshot.HasKeyboardFocus) { throw "PRODUCT DEFECT: UI Automation did not report the exact candidate control as keyboard-focusable and keyboard-focused during $Phase." }
  if ($snapshot.Name.Trim().Length -lt 3) { throw "PRODUCT DEFECT: focused candidate control accessible name is shorter than three characters during $Phase." }
  if ($null -ne $ExpectedIdentity -and -not (Test-SameFocusIdentity $ExpectedIdentity $snapshot)) { throw "NOT TESTED: the exact candidate control identity changed during $Phase." }
  return $snapshot
}

function Get-ControlFromFocusSnapshot($Snapshot, [string]$Description) {
  if (-not $Snapshot.IsCandidateProcess -or $Snapshot.NativeWindowHandle -eq 0) { throw "NOT TESTED: UI Automation did not expose a native candidate control identity after $Description." }
  $handle = [IntPtr]::new([long]$Snapshot.NativeWindowHandle)
  $element = [System.Windows.Automation.AutomationElement]::FromHandle($handle)
  if ($null -eq $element) { throw "NOT TESTED: UI Automation could not resolve the focused control after $Description." }
  $current = $element.Current
  if ($current.ProcessId -ne $candidatePid -or [long]$current.NativeWindowHandle -ne [long]$handle.ToInt64()) { throw "NOT TESTED: focused-control identity did not resolve back to the candidate HWND after $Description." }
  $control = [pscustomobject]@{ Handle=$handle; Element=$element; ProcessId=[int]$current.ProcessId; Name=[string]$current.Name; AutomationId=[string]$current.AutomationId; ControlType=[string]$current.ControlType.ProgrammaticName; ClassName=[string]$current.ClassName; Enabled=[bool]$current.IsEnabled; Offscreen=[bool]$current.IsOffscreen; KeyboardFocusable=[bool]$current.IsKeyboardFocusable; NativeWindowHandle=[long]$current.NativeWindowHandle; Bounds=@([double]$current.BoundingRectangle.Left,[double]$current.BoundingRectangle.Top,[double]$current.BoundingRectangle.Width,[double]$current.BoundingRectangle.Height) }
  if ([string]::IsNullOrWhiteSpace($control.Name)) { throw "PRODUCT DEFECT: the candidate control receiving keyboard focus after $Description has no accessible name." }
  if (-not $control.KeyboardFocusable -or -not $control.Enabled -or $control.Offscreen) { throw "PRODUCT DEFECT: the candidate control receiving keyboard focus after $Description is not an enabled, visible keyboard-focusable control." }
  if ($control.Name.Trim().Length -lt 3) { throw "PRODUCT DEFECT: focused candidate control accessible name is shorter than three characters after $Description." }
  $semanticControlTypes = @('ControlType.Button','ControlType.Slider','ControlType.CheckBox','ControlType.ComboBox','ControlType.Edit','ControlType.RadioButton','ControlType.TabItem','ControlType.Hyperlink','ControlType.Spinner')
  if ($control.ControlType -notin $semanticControlTypes) { throw "PRODUCT DEFECT: candidate keyboard focus landed on an element with non-interactive UI Automation role '$($control.ControlType)' after $Description." }
  return $control
}

function Send-NarratorChord([byte]$Key, [byte]$ModifierKey, [string]$Description) {
  # The native helper checks SendInput's returned event count and marks Insert
  # with KEYEVENTF_EXTENDEDKEY. A successful return proves delivery to the
  # foreground input stream; the captured exact-name phrase proves Narrator
  # processed the command.
  $eventsSent = [EBR_NARRATOR_NATIVE]::SendChord([byte]0x2D, $Key, $ModifierKey)
  $expectedEvents = if ($ModifierKey -eq 0) { 4 } else { 6 }
  if ($eventsSent -ne $expectedEvents) { throw "NOT TESTED: SendInput did not deliver the complete $Description chord ($eventsSent/$expectedEvents events)." }
  $chordName = if ($Key -eq 0x09 -and $ModifierKey -eq 0) { 'Insert+Tab (Read Item)' } elseif ($Key -eq 0x58 -and $ModifierKey -eq 0x11) { 'Insert+Ctrl+X (Copy Last Phrase)' } else { "Insert+0x$('{0:X2}' -f $ModifierKey)+0x$('{0:X2}' -f $Key)" }
  return [pscustomobject]@{Chord=$chordName;Key=$Key;ModifierKey=$ModifierKey;NarratorKey='Insert';InputEventsSent=$eventsSent;ExtendedInsertKey=$true;DeliveryVerified=$true}
}

function Send-KeyboardKey([byte]$Key, [string]$Description) {
  $eventsSent = [EBR_NARRATOR_NATIVE]::SendKey($Key)
  if ($eventsSent -ne 2) { throw "NOT TESTED: SendInput did not deliver the complete $Description key ($eventsSent/2 events)." }
  return [pscustomobject]@{Key=$Key;InputEventsSent=$eventsSent;DeliveryVerified=$true}
}

function Copy-NarratorLastPhrase($Control, [string]$Phase) {
  if ([string]::IsNullOrWhiteSpace($Control.Name) -or $Control.Name.Trim().Length -lt 3) { throw 'PRODUCT DEFECT: refusing to accept Narrator speech for a candidate control without a full accessible name of at least three characters.' }
  $beforeRead = Assert-ExactCandidateFocus $Control "$Phase before Read Item"
  $sentinel = '__EBR_NARRATOR_RECAP_' + [guid]::NewGuid().ToString('N')
  Set-Clipboard -Value $sentinel -ErrorAction Stop
  Start-Sleep -Milliseconds 100
  $afterSentinel = Assert-ExactCandidateFocus $Control "$Phase after clipboard sentinel" $beforeRead
  $readItemChord = Send-NarratorChord 0x09 0 'Read Item'
  Start-Sleep -Milliseconds 500
  $afterRead = Assert-ExactCandidateFocus $Control "$Phase after Read Item" $afterSentinel
  $copyChord = Send-NarratorChord 0x58 0x11 'Copy Last Phrase'
  $watch = [Diagnostics.Stopwatch]::StartNew()
  $phrase = ''
  while ($watch.Elapsed.TotalSeconds -lt 5) {
    Start-Sleep -Milliseconds 150
    try { $phrase = [string](Get-Clipboard -Raw -ErrorAction Stop) } catch { $phrase = '' }
    if (-not [string]::IsNullOrWhiteSpace($phrase) -and $phrase -cne $sentinel) { break }
  }
  $afterCopy = Assert-ExactCandidateFocus $Control "$Phase after Copy Last Phrase" $afterRead
  $phrase = ($phrase -replace '[\r\n\t]+', ' ').Trim()
  $accessibleName = ($Control.Name -replace '[\r\n\t]+', ' ').Trim()
  $nameIncluded = ($phrase.Length -gt 0 -and $phrase.IndexOf($accessibleName, [StringComparison]::OrdinalIgnoreCase) -ge 0)
  $freshText = (-not [string]::IsNullOrWhiteSpace($phrase) -and $phrase -cne $sentinel)
  $capture = [pscustomobject]@{
    Phase=$Phase; TargetControl=$Control.Name; TargetIdentity=[pscustomobject]@{ProcessId=$Control.ProcessId;NativeWindowHandle=$Control.NativeWindowHandle;Name=$Control.Name;AutomationId=$Control.AutomationId;ControlType=$Control.ControlType;ClassName=$Control.ClassName}
    Method='Narrator Insert+Tab Read Item followed by Insert+Ctrl+X Copy Last Phrase'
    ReadItemChord=$readItemChord;CopyChord=$copyChord;FocusBeforeRead=$beforeRead;FocusAfterClipboardSentinel=$afterSentinel;FocusAfterRead=$afterRead;FocusAfterCopy=$afterCopy
    Text=$phrase;SentinelReplaced=$freshText;FreshText=$freshText;PhraseIncludesFullAccessibleName=$nameIncluded;ValidatedFreshPhrase=($freshText -and $nameIncluded)
    CapturedUtc=[DateTime]::UtcNow.ToString('o')
  }
  $speechCaptures.Add($capture)
  return $capture
}

function Save-Result([string]$FinalStatus, [string]$FinalReason) {
  $result = [pscustomobject]@{
    Requirement='GUI-016'; Status=$FinalStatus; Reason=$FinalReason
    Candidate=[pscustomobject]@{
      ArtifactId=$candidateArtifactId; FinalizerRunId=$candidateRunId; SourceCommit=$candidateSourceCommit
      ExecutablePath=$ExecutablePath; SHA256=$expectedSha256; Identity=$candidateIdentity
      Execution='x64 candidate under Windows 11 ARM64 x64 emulation'; InstallerLaunched=$false
    }
    OperatingSystem=$osRecord; NativeCPUArchitecture=$nativeCpuArchitecture
    Environment=[pscustomobject]@{ Provider='GitHub-hosted Actions runner'; ImageOS=$env:ImageOS; ImageVersion=$env:ImageVersion; RunnerOS=$env:RUNNER_OS; RunnerArchitecture=$env:RUNNER_ARCH; ProcessSessionId=$sessionId; UserInteractive=[Environment]::UserInteractive }
    Profile=[pscustomobject]@{ LocalAppData=$env:LOCALAPPDATA; AppDataPath=$dataDirectory; AppDataAbsentBeforeTest=(-not $dataExistedBefore); TestDataCreatedByHarness=$dataCreatedByHarness; TestDataRemoved=$dataRemoved }
    Narrator=[pscustomobject]@{ ProcessId=$narratorPid; StartedByHarness=$narratorOwned; Version=if($narratorRecord){$narratorRecord.Version}else{$null}; SessionId=if($narratorRecord){$narratorRecord.SessionId}else{$null}; RecapMethod='Insert+Ctrl+X Copy Last Phrase'; Captures=@($speechCaptures); PhysicalAudioVerified=$physicalAudioVerified }
    OOBEActions=@($oobeActions); FocusTrace=@($focusTrace); Assertions=@($assertions); Events=@($events)
     AssertionCounts=[pscustomobject]@{Total=$assertions.Count;Passed=@($assertions|Where-Object{$_.Status -eq 'PASS'}).Count;Fail=@($assertions|Where-Object{$_.Status -eq 'FAIL'}).Count;NotTested=@($assertions|Where-Object{$_.Status -eq 'NOT TESTED'}).Count}
    Screenshots=@($screenshots); TranscriptFile=$transcriptPath; LogFile=$logPath
    Cleanup=[pscustomobject]@{CandidateProcessStopped=$candidateStoppedByHarness;NarratorProcessStopped=$narratorStoppedByHarness;AppDataRemoved=$dataRemoved;Errors=@($cleanupErrors)}
    Limitations=@('Windows 11 ARM64 host; exact x64 candidate ran under emulation, not native x64.','Speech Recap text verifies Narrator speech content only; physical audio rendering and audibility were not tested.','The standalone candidate was launched; no installer or updater was run.')
    ObservedUtc=[DateTime]::UtcNow.ToString('o')
  }
  $result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resultPath -Encoding utf8
  if ($speechCaptures.Count) {
    $lines = foreach ($capture in $speechCaptures) { "[$($capture.Phase)] target=$($capture.TargetControl)`r`n$($capture.Text)`r`n" }
    Set-Content -LiteralPath $transcriptPath -Value ($lines -join "`r`n") -Encoding utf8
  }
  return $result
}

try {
  Start-Transcript -LiteralPath $logPath -Force | Out-Null
  $scriptTranscriptStarted = $true
  Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

[StructLayout(LayoutKind.Sequential)]
public struct EBR_NARRATOR_SYSTEM_INFO {
  public ushort ProcessorArchitecture;
  public ushort Reserved;
  public uint PageSize;
  public IntPtr MinimumApplicationAddress;
  public IntPtr MaximumApplicationAddress;
  public UIntPtr ActiveProcessorMask;
  public uint NumberOfProcessors;
  public uint ProcessorType;
  public uint AllocationGranularity;
  public ushort ProcessorLevel;
  public ushort ProcessorRevision;
}

 [StructLayout(LayoutKind.Sequential)] public struct EBR_NARRATOR_KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public UIntPtr dwExtraInfo; }
 [StructLayout(LayoutKind.Sequential)] public struct EBR_NARRATOR_MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public UIntPtr dwExtraInfo; }
 [StructLayout(LayoutKind.Explicit)] public struct EBR_NARRATOR_INPUTUNION { [FieldOffset(0)] public EBR_NARRATOR_MOUSEINPUT mi; [FieldOffset(0)] public EBR_NARRATOR_KEYBDINPUT ki; }
 [StructLayout(LayoutKind.Sequential)] public struct EBR_NARRATOR_INPUT { public uint type; public EBR_NARRATOR_INPUTUNION u; }

 public static class EBR_NARRATOR_NATIVE {
  private delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr data);
  [DllImport("kernel32.dll")] private static extern void GetNativeSystemInfo(out EBR_NARRATOR_SYSTEM_INFO info);
  [DllImport("user32.dll", SetLastError=true)] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr data);
  [DllImport("user32.dll", SetLastError=true)] private static extern bool EnumChildWindows(IntPtr parent, EnumWindowsProc callback, IntPtr data);
  [DllImport("user32.dll", SetLastError=true)] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="GetWindowTextW", SetLastError=true)] private static extern int GetWindowTextNative(IntPtr hwnd, StringBuilder text, int maxCount);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="GetClassNameW", SetLastError=true)] private static extern int GetClassNameNative(IntPtr hwnd, StringBuilder text, int maxCount);
  [DllImport("user32.dll", SetLastError=true)] private static extern int GetDlgCtrlID(IntPtr hwnd);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll", SetLastError=true)] private static extern bool IsWindowEnabled(IntPtr hwnd);
  [DllImport("user32.dll", SetLastError=true)] private static extern bool GetWindowRect(IntPtr hwnd, out EBR_NARRATOR_RECT rect);
  [DllImport("user32.dll", SetLastError=true)] private static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll", SetLastError=true)] private static extern bool SetForegroundWindow(IntPtr hwnd);
  [DllImport("user32.dll", SetLastError=true)] private static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] private static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extraInfo);
  [DllImport("user32.dll", SetLastError=true)] private static extern uint SendInput(uint count, [In, MarshalAs(UnmanagedType.LPArray, SizeParamIndex=0)] EBR_NARRATOR_INPUT[] inputs, int inputSize);
  [StructLayout(LayoutKind.Sequential)] private struct EBR_NARRATOR_RECT { public int Left, Top, Right, Bottom; }
  private static EBR_NARRATOR_INPUT KeyboardInput(byte key, bool keyUp) {
    uint flags = key == 0x2D ? 0x0001u : 0u; // VK_INSERT is an E0-prefixed extended key.
    if (keyUp) flags |= 0x0002u;
    return new EBR_NARRATOR_INPUT { type=1u, u=new EBR_NARRATOR_INPUTUNION { ki=new EBR_NARRATOR_KEYBDINPUT { wVk=key, wScan=0, dwFlags=flags, time=0, dwExtraInfo=UIntPtr.Zero } } };
  }
  private static void ReleaseKeys(byte[] keys) {
    var release = new EBR_NARRATOR_INPUT[keys.Length];
    for (int i=0; i<keys.Length; i++) release[i]=KeyboardInput(keys[keys.Length-1-i], true);
    if (release.Length > 0) SendInput((uint)release.Length, release, Marshal.SizeOf(typeof(EBR_NARRATOR_INPUT)));
  }
  public static int SendChord(byte narratorKey, byte key, byte modifierKey) {
    byte[] keys = modifierKey == 0 ? new byte[] { narratorKey, key } : new byte[] { narratorKey, modifierKey, key };
    var inputs = new EBR_NARRATOR_INPUT[keys.Length * 2];
    int at=0;
    for (int i=0; i<keys.Length; i++) inputs[at++]=KeyboardInput(keys[i], false);
    for (int i=keys.Length-1; i>=0; i--) inputs[at++]=KeyboardInput(keys[i], true);
    uint sent=SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(EBR_NARRATOR_INPUT)));
    if (sent != (uint)inputs.Length) {
      int error=Marshal.GetLastWin32Error();
      ReleaseKeys(keys);
      throw new System.ComponentModel.Win32Exception(error, "SendInput delivered " + sent + " of " + inputs.Length + " Narrator chord events.");
    }
    return (int)sent;
  }
  public static int SendKey(byte key) {
    var inputs = new EBR_NARRATOR_INPUT[] { KeyboardInput(key, false), KeyboardInput(key, true) };
    uint sent=SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(EBR_NARRATOR_INPUT)));
    if (sent != (uint)inputs.Length) {
      int error=Marshal.GetLastWin32Error();
      ReleaseKeys(new byte[] { key });
      throw new System.ComponentModel.Win32Exception(error, "SendInput delivered " + sent + " of 2 keyboard events.");
    }
    return (int)sent;
  }
  public static ushort NativeArchitecture() { EBR_NARRATOR_SYSTEM_INFO i; GetNativeSystemInfo(out i); return i.ProcessorArchitecture; }
  public static string[] WindowsForProcess(int expectedPid) {
    var found = new List<IntPtr>();
    EnumWindows((hwnd, data) => { uint pid; GetWindowThreadProcessId(hwnd, out pid); if (pid == (uint)expectedPid && IsWindowVisible(hwnd)) found.Add(hwnd); return true; }, IntPtr.Zero);
    var result = new List<string>(); foreach (var hwnd in found) result.Add(hwnd.ToInt64().ToString()); return result.ToArray();
  }
  public static IntPtr FindVisibleChildById(IntPtr parent, int id) {
    IntPtr found = IntPtr.Zero;
    EnumChildWindows(parent, (hwnd, data) => { if (found == IntPtr.Zero && GetDlgCtrlID(hwnd) == id && IsWindowVisible(hwnd) && IsWindowEnabled(hwnd)) { found = hwnd; return false; } return true; }, IntPtr.Zero);
    return found;
  }
  public static int[] Bounds(IntPtr hwnd) {
    EBR_NARRATOR_RECT r; if (!GetWindowRect(hwnd, out r)) return new int[0];
    return new int[] { r.Left, r.Top, r.Right, r.Bottom };
  }
  public static string WindowText(IntPtr hwnd) { var b = new StringBuilder(512); GetWindowTextNative(hwnd, b, b.Capacity); return b.ToString(); }
  public static string WindowClass(IntPtr hwnd) { var b = new StringBuilder(256); GetClassNameNative(hwnd, b, b.Capacity); return b.ToString(); }
  public static int OwnerProcessId(IntPtr hwnd) { uint pid; GetWindowThreadProcessId(hwnd, out pid); return (int)pid; }
  public static IntPtr ForegroundWindow() { return GetForegroundWindow(); }
  public static bool FocusWindow(IntPtr hwnd) { return SetForegroundWindow(hwnd); }
  public static bool ClickAt(int x, int y) { if (!SetCursorPos(x, y)) return false; System.Threading.Thread.Sleep(80); mouse_event(0x0002,0,0,0,UIntPtr.Zero); System.Threading.Thread.Sleep(80); mouse_event(0x0004,0,0,0,UIntPtr.Zero); return true; }
}
'@ -ErrorAction Stop
  Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
  Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop

  $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
  $osArchitecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
  $processArchitecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
  $nativeCpuArchitecture = [EBR_NARRATOR_NATIVE]::NativeArchitecture()
  $osRecord = [pscustomobject]@{ Caption=$os.Caption; Version=$os.Version; Build=$os.BuildNumber; OSArchitecture=$osArchitecture; ProcessArchitecture=$processArchitecture; NativeProcessorArchitectureCode=$nativeCpuArchitecture; NativeProcessorArchitecture=if($nativeCpuArchitecture -eq 12){'ARM64'}else{"Unknown ($nativeCpuArchitecture)"} }
  $sessionId = (Get-Process -Id $PID -ErrorAction Stop).SessionId
  $osValid = ($os.Caption -match 'Windows 11' -and $osArchitecture -eq 'Arm64' -and $processArchitecture -eq 'Arm64' -and $nativeCpuArchitecture -eq 12)
  Add-Assertion 'Runner is Windows 11 with native ARM64 OS, CPU, and ARM64 PowerShell process' $osValid $osRecord
  if (-not $osValid) { throw 'BLOCKED: the runner is not a native Windows 11 ARM64 environment.' }
  Add-Assertion 'Runner process has an interactive desktop session' ([Environment]::UserInteractive) ([pscustomobject]@{SessionId=$sessionId;UserInteractive=[Environment]::UserInteractive;RunnerImage=$env:ImageOS})
  if (-not [Environment]::UserInteractive) { throw 'BLOCKED: this runner job does not have an interactive desktop.' }

  if (-not (Test-Path -LiteralPath $ExecutablePath -PathType Leaf)) { throw 'BLOCKED: exact standalone candidate executable is missing.' }
  $candidateInfo = Get-Item -LiteralPath $ExecutablePath -ErrorAction Stop
  $actualSha256 = (Get-FileHash -LiteralPath $ExecutablePath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
  if ($actualSha256 -cne $expectedSha256) { throw "BLOCKED: candidate hash mismatch; expected $expectedSha256, found $actualSha256." }
  $reader = [IO.BinaryReader]::new([IO.File]::OpenRead($ExecutablePath))
  try {
    $reader.BaseStream.Position = 0x3C; $peOffset = $reader.ReadInt32(); $reader.BaseStream.Position = $peOffset
    if ($reader.ReadUInt32() -ne 0x00004550) { throw 'Candidate executable has no valid PE signature.' }
    $peMachine = $reader.ReadUInt16()
  } finally { $reader.Dispose() }
  if ($peMachine -ne 0x8664) { throw "BLOCKED: expected an x64 PE candidate, found machine 0x$('{0:X4}' -f $peMachine)." }
  if ($candidateInfo.VersionInfo.ProductVersion -notmatch '^1\.4\.0(\.0)?$') { throw "BLOCKED: candidate file version is '$($candidateInfo.VersionInfo.ProductVersion)', not 1.4.0." }
  $candidateIdentity = [pscustomobject]@{ ArtifactId=$candidateArtifactId; FinalizerRunId=$candidateRunId; SourceCommit=$candidateSourceCommit; SHA256=$actualSha256; Bytes=$candidateInfo.Length; ProductVersion=$candidateInfo.VersionInfo.ProductVersion; PEMachine=('0x{0:X4}' -f $peMachine); Execution='x64 emulation on native Windows 11 ARM64' }
  Add-Assertion 'Standalone executable matches production artifact 14695418078 exact x64 payload' $true $candidateIdentity

  $currentAppProcesses = @(Get-Process -Name EyeBreakReminder -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sessionId })
  if ($currentAppProcesses.Count -gt 0) { throw 'BLOCKED: an Eye Break Reminder process already exists in this runner session; refusing to interfere with it.' }
  if ($dataExistedBefore) { throw "BLOCKED: this runner profile already has EyeBreakReminder data at '$dataDirectory'; refusing to overwrite it." }
  if (-not $dataDirectory.StartsWith($localAppDataRoot, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($dataDirectory) -cne 'EyeBreakReminder') {
    throw 'BLOCKED: the app-data cleanup target is not the exact EyeBreakReminder child of LocalAppData.'
  }
  Add-Assertion 'Fresh runner profile has no pre-existing EyeBreakReminder app data' $true ([pscustomobject]@{Path=$dataDirectory;AbsentBeforeTest=$true})

  $narratorPath = Join-Path $env:WINDIR 'System32\Narrator.exe'
  if (-not (Test-Path -LiteralPath $narratorPath -PathType Leaf)) { throw 'NOT TESTED: Narrator.exe is unavailable on this runner image.' }
  $narratorInSession = @(Get-Process -Name Narrator -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sessionId })
  if ($narratorInSession.Count -gt 0) {
    $narratorProcess = $narratorInSession | Select-Object -First 1
    $narratorPid = $narratorProcess.Id
    $narratorOwned = $false
    Add-Event 'Use already-running Narrator in the same session' 'INFO' ([pscustomobject]@{ProcessId=$narratorPid;SessionId=$narratorProcess.SessionId;OwnedByHarness=$false})
  }

  # Seed only the previously absent runner-local profile with benign, quiet
  # settings. This prevents auto-start, notifications, audio, and update checks.
  [void][IO.Directory]::CreateDirectory($dataDirectory)
  $dataCreatedByHarness = $true
  $settingsPath = Join-Path $dataDirectory 'settings.ini'
  $settingsText = "workMinutes=20`nbreakSeconds=20`nsound=0`nvolume=55`nmode=0`nmonitor=0`ntheme=2`nalarm=0`nrepeat=0`nnotifications=0`nsnooze=0`nautoStart=0`nstartup=0`ntray=0`nautoCheckUpdates=0`nautoDownloadUpdates=0`nhistory=0`n"
  [IO.File]::WriteAllText($settingsPath, $settingsText, [Text.UTF8Encoding]::new($false))
  Add-Event 'Create quiet test-only profile settings after confirming the app-data path was absent' 'PASS' ([pscustomobject]@{SettingsPath=$settingsPath;SettingsSHA256=(Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash.ToLowerInvariant();AutoStart=$false;Notifications=$false;Alarm=$false;UpdateChecks=$false})

  $candidateProcess = Start-Process -FilePath $ExecutablePath -WorkingDirectory (Split-Path -Parent $ExecutablePath) -PassThru -ErrorAction Stop
  $candidatePid = $candidateProcess.Id
  $candidateOwned = $true
  $mainWindow = [IntPtr]::Zero
  $windowWatch = [Diagnostics.Stopwatch]::StartNew()
  while ($windowWatch.Elapsed.TotalSeconds -lt 20 -and $mainWindow -eq [IntPtr]::Zero) {
    $candidateProcess.Refresh()
    if ($candidateProcess.HasExited) { throw "NOT TESTED: candidate exited before creating a window (exit code $($candidateProcess.ExitCode))." }
    foreach ($windowText in [EBR_NARRATOR_NATIVE]::WindowsForProcess($candidatePid)) {
      $handle = [IntPtr]::new([long]$windowText)
      if ([EBR_NARRATOR_NATIVE]::WindowText($handle) -match 'Eye Break Reminder') { $mainWindow = $handle; break }
    }
    if ($mainWindow -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 150 }
  }
  if ($mainWindow -eq [IntPtr]::Zero) { throw 'NOT TESTED: exact candidate did not expose its visible main window within 20 seconds.' }
  Add-Assertion 'Exact production candidate created its main-window handle in the interactive test session' $true ([pscustomobject]@{Pid=$candidatePid;WindowHandle=('0x{0:X}' -f $mainWindow.ToInt64());WindowTitle=[EBR_NARRATOR_NATIVE]::WindowText($mainWindow);SessionId=$candidateProcess.SessionId;WindowVisible=[EBR_NARRATOR_NATIVE]::IsWindowVisible($mainWindow);Path=$candidateProcess.Path;SHA256=$actualSha256})
  Resolve-PrivacyOobeIfPresent
  try { ([System.Windows.Automation.AutomationElement]::FromHandle($mainWindow)).SetFocus() } catch {}
  [void][EBR_NARRATOR_NATIVE]::FocusWindow($mainWindow)
  Start-Sleep -Milliseconds 400
  $foreground = [EBR_NARRATOR_NATIVE]::ForegroundWindow()
  $foregroundProcessId = [EBR_NARRATOR_NATIVE]::OwnerProcessId($foreground)
  $candidateWindowUnobscured = ($foreground -eq $mainWindow -and $foregroundProcessId -eq $candidatePid -and [EBR_NARRATOR_NATIVE]::IsWindowVisible($mainWindow))
  Add-Assertion 'Candidate main window is foreground and unobscured before accessibility interaction' $candidateWindowUnobscured ([pscustomobject]@{ForegroundWindow=('0x{0:X}' -f $foreground.ToInt64());ForegroundProcessId=$foregroundProcessId;CandidateWindow=('0x{0:X}' -f $mainWindow.ToInt64());CandidatePid=$candidatePid;OOBEActions=@($oobeActions)})
  if (-not $candidateWindowUnobscured) { throw 'NOT TESTED: the candidate window is obscured by another foreground window; accessibility interaction stopped.' }
  $firstShot = Capture-CandidateWindow $mainWindow 'gui-016-candidate-timer-window.png'
  Add-Event 'Capture target-window screenshot of the exact candidate' 'PASS' $firstShot

  if ($null -eq $narratorProcess) {
    $narratorProcess = Start-Process -FilePath $narratorPath -PassThru -ErrorAction Stop
    $narratorPid = $narratorProcess.Id
    $narratorOwned = $true
    $narratorWait = [Diagnostics.Stopwatch]::StartNew()
    while ($narratorWait.Elapsed.TotalSeconds -lt 8) {
      $narratorProcess.Refresh()
      if ($narratorProcess.HasExited) { throw 'NOT TESTED: Narrator did not remain running after launch.' }
      if ($narratorProcess.SessionId -eq $sessionId) { break }
      Start-Sleep -Milliseconds 100
    }
    if ($narratorProcess.SessionId -ne $sessionId) { throw 'NOT TESTED: Narrator is not running in the candidate test session.' }
    Add-Event 'Start Narrator because no instance was already running in the test session' 'PASS' ([pscustomobject]@{ProcessId=$narratorPid;SessionId=$narratorProcess.SessionId;OwnedByHarness=$true;Path=$narratorPath})
  }
  $narratorInfo = Get-Item -LiteralPath $narratorPath -ErrorAction Stop
  $narratorRecord = [pscustomobject]@{Path=$narratorPath;ProductVersion=$narratorInfo.VersionInfo.ProductVersion;Version=$narratorInfo.VersionInfo.FileVersion;ProcessId=$narratorPid;SessionId=$narratorProcess.SessionId;OwnedByHarness=$narratorOwned;ModifierKey='Insert';CopyLastPhraseShortcut='Insert+Ctrl+X'}
  Start-Sleep -Seconds 2

  $settingsButton = Get-ControlElement $mainWindow 12 'Settings navigation button'
  if ($settingsButton.Name -notmatch '(?i)settings') { throw "PRODUCT DEFECT: candidate Settings navigation control has accessible name '$($settingsButton.Name)', which does not identify the Settings action." }
  if ($settingsButton.ControlType -ne 'ControlType.Button') { throw "PRODUCT DEFECT: candidate Settings navigation control exposes role '$($settingsButton.ControlType)', not Button." }
  $navClick = $settingsButton.Bounds
  if ($navClick.Count -ne 4 -or $navClick[2] -le 0 -or $navClick[3] -le 0) { throw 'NOT TESTED: Settings navigation control has no usable visible UIA bounds.' }
  if (-not [EBR_NARRATOR_NATIVE]::ClickAt([int]($navClick[0] + $navClick[2]/2), [int]($navClick[1] + $navClick[3]/2))) { throw 'NOT TESTED: real pointer input could not focus Settings navigation.' }
  Start-Sleep -Milliseconds 350
  $alarmSection = Get-ControlElement $mainWindow 132 'Alarm Settings section navigation'
  if ($alarmSection.Name -notmatch '(?i)alarm') { throw "PRODUCT DEFECT: candidate Alarm section navigation has accessible name '$($alarmSection.Name)', which does not identify the Alarm section." }
  $alarmBounds = $alarmSection.Bounds
  if ($alarmBounds.Count -ne 4 -or $alarmBounds[2] -le 0 -or $alarmBounds[3] -le 0) { throw 'NOT TESTED: Alarm section navigation control has no usable visible UIA bounds.' }
  if (-not [EBR_NARRATOR_NATIVE]::ClickAt([int]($alarmBounds[0] + $alarmBounds[2]/2), [int]($alarmBounds[1] + $alarmBounds[3]/2))) { throw 'NOT TESTED: real pointer input could not select the candidate Alarm settings section.' }
  Start-Sleep -Milliseconds 350
  $settingsWait = [Diagnostics.Stopwatch]::StartNew()
  $volumeControl = $null
  while ($settingsWait.Elapsed.TotalSeconds -lt 8 -and $null -eq $volumeControl) {
    try { $volumeControl = Get-ControlElement $mainWindow 103 'Alarm volume slider' }
    catch { if ($_.Exception.Message -match '^PRODUCT DEFECT:') { throw }; Start-Sleep -Milliseconds 100 }
  }
  if ($null -eq $volumeControl) { throw 'NOT TESTED: the real candidate Settings page did not expose its Alarm volume control.' }
  if ($volumeControl.ControlType -ne 'ControlType.Slider') { throw "PRODUCT DEFECT: candidate Alarm volume control exposes role '$($volumeControl.ControlType)', not Slider." }
  $settingsShot = Capture-CandidateWindow $mainWindow 'gui-016-candidate-settings-window.png'
  Add-Assertion 'Real Settings > Alarm navigation opens the candidate alarm controls through pointer input' $true ([pscustomobject]@{NavigationControl=$settingsButton;AlarmSection=$alarmSection;VolumeControl=$volumeControl;Screenshot=$settingsShot.Path})

  $volumeBounds = $volumeControl.Bounds
  if ($volumeBounds.Count -ne 4 -or $volumeBounds[2] -le 0 -or $volumeBounds[3] -le 0) { throw 'NOT TESTED: Alarm volume control has no usable visible UIA bounds.' }
  if (-not [EBR_NARRATOR_NATIVE]::ClickAt([int]($volumeBounds[0] + $volumeBounds[2]/2), [int]($volumeBounds[1] + $volumeBounds[3]/2))) { throw 'NOT TESTED: real pointer input could not focus Alarm volume.' }
  Start-Sleep -Milliseconds 400
  $focusedVolume = Assert-ExactCandidateFocus $volumeControl 'After pointer focus on candidate Alarm volume slider'
  if ($focusedVolume.Name -notmatch '(?i)volume') { throw "PRODUCT DEFECT: candidate volume control accessible name '$($focusedVolume.Name)' does not identify the Alarm volume slider." }
  $firstSpeech = Copy-NarratorLastPhrase $volumeControl 'Exact focus on Alarm volume control'
  $firstPhraseValid = $firstSpeech.ValidatedFreshPhrase
  Add-Assertion 'Narrator Read Item and Copy Last Phrase capture the full accessible name of the focused Alarm volume control' $firstPhraseValid ([pscustomobject]@{Focus=$focusedVolume;Capture=$firstSpeech;PhysicalAudioVerified=$false})

  [void](Assert-ExactCandidateFocus $volumeControl 'Immediately before real Tab navigation' $focusedVolume)
  $tabInput = Send-KeyboardKey 0x09 'Tab navigation from the focused Alarm volume slider'
  Start-Sleep -Milliseconds 400
  $focusedAfterTab = Get-FocusSnapshot $candidatePid 'After real Tab navigation from Alarm volume'
  if (-not $focusedAfterTab.IsCandidateProcess) { throw 'NOT TESTED: real Tab input moved focus outside the candidate process.' }
  if (-not $focusedAfterTab.HasKeyboardFocus -or -not $focusedAfterTab.IsKeyboardFocusable) { throw 'PRODUCT DEFECT: the candidate element receiving real Tab input is not reported as keyboard-focused and keyboard-focusable by UI Automation.' }
  $secondControl = Get-ControlFromFocusSnapshot $focusedAfterTab 'real Tab navigation from Alarm volume'
  $tabChangedCandidateFocus = -not (Test-SameFocusIdentity $focusedVolume $focusedAfterTab)
  if (-not $tabChangedCandidateFocus) {
    $candidateRoot = [System.Windows.Automation.AutomationElement]::FromHandle($mainWindow)
    $focusableControls = @($candidateRoot.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition) | Where-Object { try { $_.Current.ProcessId -eq $candidatePid -and $_.Current.IsEnabled -and -not $_.Current.IsOffscreen -and $_.Current.IsKeyboardFocusable } catch { $false } })
    if ($focusableControls.Count -gt 1) { throw 'PRODUCT DEFECT: delivered Tab input did not move focus from Alarm volume despite multiple visible enabled keyboard-focusable candidate controls.' }
    throw 'NOT TESTED: Tab did not move to a distinct UI Automation control identity.'
  }
  Add-Assertion 'Real Tab input moves keyboard focus to a distinct named candidate control' $true ([pscustomobject]@{Before=$focusedVolume;After=$focusedAfterTab;Key='Tab';Input=$tabInput;ExactIdentityChanged=$true})
  $secondShot = Capture-CandidateWindow $mainWindow 'gui-016-candidate-keyboard-focus-window.png'
  $secondSpeech = Copy-NarratorLastPhrase $secondControl 'Keyboard Tab focus to candidate control'
  $secondPhraseValid = $secondSpeech.ValidatedFreshPhrase
  Add-Assertion 'Narrator Read Item and Copy Last Phrase capture the full accessible name after real keyboard focus changes' $secondPhraseValid ([pscustomobject]@{Focus=$focusedAfterTab;Control=$secondControl;Capture=$secondSpeech;Screenshot=$secondShot.Path;PhysicalAudioVerified=$false})

  $goodCaptures = @($speechCaptures | Where-Object { $_.ValidatedFreshPhrase -eq $true -and $_.FreshText -eq $true -and $_.PhraseIncludesFullAccessibleName -eq $true })
  $evidenceReady = ($goodCaptures.Count -ge 2 -and $firstPhraseValid -and $tabChangedCandidateFocus -and $secondPhraseValid -and $screenshots.Count -ge 3)
  if ($evidenceReady) {
    $status = 'PASS'
    $reason = 'Two fresh Narrator Read Item plus Copy Last Phrase captures included each exact current candidate control accessible name after verified focus; target-window screenshots and focus trace were retained. Physical audio remains unverified.'
  } else {
    $status = 'NOT TESTED'
    $reason = 'The harness did not capture sufficient fresh Narrator Recap text associated with candidate controls; UI Automation observations alone are not accepted as speech evidence.'
  }
  Add-Event 'GUI-016 documented Speech Recap alternative result' $status ([pscustomobject]@{FreshSpeechCaptureCount=$goodCaptures.Count;PhysicalAudioVerified=$false;CandidateArchitecture='x64 emulation on Windows 11 ARM64'})
  Add-Assertion 'GUI-016 Narrator speech content follows real candidate keyboard focus' ($status -eq 'PASS') ([pscustomobject]@{Status=$status;Reason=$reason;FreshSpeechCaptureCount=$goodCaptures.Count;PhysicalAudioVerified=$false})
  $speechAcceptanceAssertionRecorded = $true
} catch {
  $errorMessage = $_.Exception.Message
  if ($errorMessage -match '^PRODUCT DEFECT:') { $status = 'FAIL'; $reason = $errorMessage }
  elseif ($errorMessage -match '^(BLOCKED|NOT TESTED):') { $status = if($errorMessage.StartsWith('BLOCKED:')){'BLOCKED'}else{'NOT TESTED'}; $reason = $errorMessage }
  else { $status = 'NOT TESTED'; $reason = "Narrator speech content was not established: $errorMessage" }
  Add-Event 'GUI-016 harness attempt' $status ([pscustomobject]@{Message=$errorMessage;StackTrace=$_.ScriptStackTrace})
  if (-not $speechAcceptanceAssertionRecorded) { Add-Assertion 'GUI-016 Narrator speech content follows real candidate keyboard focus' $false ([pscustomobject]@{Status=$status;Reason=$reason;Message=$errorMessage;PhysicalAudioVerified=$false}) $(if($status -eq 'FAIL'){'FAIL'}else{'NOT TESTED'}) }
} finally {
  if ($candidateOwned -and $candidatePid -gt 0) {
    try {
      $owned = Get-Process -Id $candidatePid -ErrorAction SilentlyContinue
      if ($owned) {
        $ownedPath = ''
        try { $ownedPath = [IO.Path]::GetFullPath($owned.Path) } catch {}
        if ($ownedPath -ieq $ExecutablePath) {
          [void]$owned.CloseMainWindow()
          if (-not $owned.WaitForExit(5000)) { Stop-Process -Id $candidatePid -Force -ErrorAction Stop; $owned.WaitForExit(5000) | Out-Null }
          $candidateStoppedByHarness = $true
          Add-Event 'Stop only the standalone candidate process launched by this harness' 'PASS' ([pscustomobject]@{ProcessId=$candidatePid;Path=$ownedPath})
        } else { $cleanupErrors.Add("Candidate PID $candidatePid now resolves to another image; it was not stopped.") }
      } else { $candidateStoppedByHarness = $true }
    } catch { $cleanupErrors.Add("Candidate process cleanup: $($_.Exception.Message)") }
  }
  if ($narratorOwned -and $narratorPid -gt 0) {
    try {
      $ownedNarrator = Get-Process -Id $narratorPid -ErrorAction SilentlyContinue
      if ($ownedNarrator) {
        $narratorImage = ''
        try { $narratorImage = [IO.Path]::GetFullPath($ownedNarrator.Path) } catch {}
        if ($narratorImage -ieq [IO.Path]::GetFullPath((Join-Path $env:WINDIR 'System32\Narrator.exe'))) {
          Stop-Process -Id $narratorPid -Force -ErrorAction Stop
          $narratorStoppedByHarness = $true
          Add-Event 'Stop only the Narrator process started by this harness' 'PASS' ([pscustomobject]@{ProcessId=$narratorPid;Path=$narratorImage})
        } else { $cleanupErrors.Add("Narrator PID $narratorPid no longer resolves to Narrator.exe; it was not stopped.") }
      } else { $narratorStoppedByHarness = $true }
    } catch { $cleanupErrors.Add("Owned Narrator process cleanup: $($_.Exception.Message)") }
  }
  if ($dataCreatedByHarness -and -not $dataExistedBefore -and (Test-Path -LiteralPath $dataDirectory)) {
    try {
      $resolvedData = [IO.Path]::GetFullPath($dataDirectory)
      if (-not $resolvedData.StartsWith($localAppDataRoot, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolvedData) -cne 'EyeBreakReminder') { throw "Refusing cleanup outside the exact test profile folder: $resolvedData" }
      if (([IO.File]::GetAttributes($resolvedData) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Refusing to recurse into an app-data reparse point.' }
      $reparseChildren = @(Get-ChildItem -LiteralPath $resolvedData -Force -Recurse -ErrorAction Stop | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })
      if ($reparseChildren.Count -gt 0) { throw 'Refusing to recurse into a reparse point created inside the app-data test folder.' }
      Remove-Item -LiteralPath $resolvedData -Recurse -Force -ErrorAction Stop
      $dataRemoved = -not (Test-Path -LiteralPath $resolvedData)
      if (-not $dataRemoved) { throw 'The new test app-data directory remains after cleanup.' }
      Add-Event 'Remove only the fresh app-data directory created by this harness' 'PASS' ([pscustomobject]@{Path=$resolvedData;Removed=$true})
    } catch { $cleanupErrors.Add("App-data cleanup: $($_.Exception.Message)") }
  }
  if ($scriptTranscriptStarted) { try { Stop-Transcript | Out-Null } catch { $cleanupErrors.Add("Transcript close: $($_.Exception.Message)") } }
}

if ($status -eq 'PASS' -and $cleanupErrors.Count -gt 0) {
  $status = 'NOT TESTED'
  $reason += ' Cleanup did not complete cleanly; GUI-016 is not marked PASS.'
}
try {
  $result = Save-Result $status $reason
  $result | ConvertTo-Json -Depth 12
  Write-Host "GUI-016 Narrator speech result: $status — $reason"
} catch { throw "Could not save GUI-016 evidence: $($_.Exception.Message)" }
