param(
  [Parameter(Mandatory=$true)][string]$ExecutablePath,
  [Parameter(Mandatory=$true)][string]$EvidenceDirectory
)

$ErrorActionPreference = 'Stop'
$expectedSha256 = '07f6c1eaee5818df9f5c024310883ca94b8274a4f451186a8123974fb5e5f720'
$candidateArtifactId = '14695418078'
$candidateRunId = '44875679345'
$candidateSourceCommit = '491bd2ed29f84f4d434b884fc723144db2d6f294'
$expectedNotificationTitle = 'Time to rest your eyes'
$expectedNotificationBodyPattern = 'Look 20 feet / 6 metres away for 20 seconds'

# Run only inside the disposable GitHub-hosted Windows 11 ARM64 runner. The
# production x64 executable is intentionally tested here under x64 emulation.
if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows' -or $env:RUNNER_ARCH -cne 'ARM64') {
  throw 'BLOCKED: this Shell notification probe may run only on a GitHub-hosted Windows 11 ARM64 runner.'
}
if ($env:GITHUB_SERVER_URL -cne 'https://github.com' -or $env:GITHUB_REPOSITORY -ine 'REMEDIOSSAMUEL/EYE-BREAK-REMINDER' -or -not $env:GITHUB_RUN_ID -or -not $env:RUNNER_NAME) {
  throw 'BLOCKED: a GitHub Actions run context for the authorized project repository is required.'
}
if (-not $env:GITHUB_WORKSPACE -or -not $env:RUNNER_TEMP) {
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
$resultPath = Join-Path $EvidenceDirectory 'env-009-shell-notification-results.json'
$logPath = Join-Path $EvidenceDirectory 'env-009-shell-notification.log'
$scriptTranscriptStarted = $false
$candidateProcess = $null
$candidatePid = 0
$candidateOwned = $false
$candidateStopped = $false
$dataDirectory = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'EyeBreakReminder'))
$localAppDataRoot = [IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd('\') + '\'
$dataExistedBefore = Test-Path -LiteralPath $dataDirectory
$dataCreatedByHarness = $false
$dataRemoved = $false
$cleanupErrors = [System.Collections.Generic.List[string]]::new()
$assertions = [System.Collections.Generic.List[object]]::new()
$events = [System.Collections.Generic.List[object]]::new()
$shellSnapshots = [System.Collections.Generic.List[object]]::new()
$activationRecord = $null
$dismissalRecord = $null
$persistenceRecord = $null
$status = 'BLOCKED'
$reason = 'Preflight did not complete.'
$shellVisibilityStatus = 'NOT TESTED'
$shellVisibilityReason = 'No actual Windows Shell notification surface has been observed.'
$notificationAudioStatus = 'NOT TESTED'
$physicalAudioVerified = $false
$osRecord = $null
$candidateIdentity = $null
$shellStateRecord = $null
$timerRecord = $null
$shellRecord = $null
$sessionId = $null
$candidateMainWindow = [IntPtr]::Zero
$candidateBreakWindow = [IntPtr]::Zero
$desktopScreenshotPath = $null
$shellNotificationScreenshotPath = $null
$sameShellWindow = $false
$postScreenshotSnapshot = $null
$breakScreenshotPath = $null
$oobeRecord = [pscustomobject]@{Status='NOT TESTED';PrivacyPageDetected=$false;PrivacyPageAdvanced=$false;CandidateForegroundVerified=$false;CandidateUnobscuredVerified=$false;Reason='Candidate window has not yet been checked for a first-run OOBE overlay.';Surfaces=@();Screenshots=@()}

function Add-Event([string]$Name, [string]$Status, $Details=$null) {
  $events.Add([pscustomobject]@{ Name=$Name; Status=$Status; Details=$Details; Utc=[DateTime]::UtcNow.ToString('o') })
}

function Add-Assertion([string]$Name, [bool]$Passed, $Details=$null) {
  $assertions.Add([pscustomobject]@{ Name=$Name; Passed=$Passed; Details=$Details; Utc=[DateTime]::UtcNow.ToString('o') })
  Add-Event $Name $(if ($Passed) { 'PASS' } else { 'NOT TESTED' }) $Details
}

function Get-WindowDescription([IntPtr]$Window) {
  $windowProcessId = [EBR_SHELL_NOTIFY_NATIVE]::OwnerProcessId($Window)
  $process = Get-Process -Id $windowProcessId -ErrorAction SilentlyContinue
  [pscustomobject]@{
    Handle=('0x{0:X}' -f $Window.ToInt64()); ProcessId=$windowProcessId
    ProcessName=if($process){$process.ProcessName}else{$null}
    Title=[EBR_SHELL_NOTIFY_NATIVE]::WindowText($Window)
    ClassName=[EBR_SHELL_NOTIFY_NATIVE]::WindowClass($Window)
    Visible=[EBR_SHELL_NOTIFY_NATIVE]::IsWindowVisible($Window)
    Bounds=[EBR_SHELL_NOTIFY_NATIVE]::Bounds($Window)
  }
}

function Get-CandidateWindow([int]$ProcessId, [string]$TitlePattern) {
  foreach ($windowText in [EBR_SHELL_NOTIFY_NATIVE]::WindowsForProcess($ProcessId)) {
    $handle = [IntPtr]::new([long]$windowText)
    if ([EBR_SHELL_NOTIFY_NATIVE]::WindowText($handle) -match $TitlePattern) { return $handle }
  }
  return [IntPtr]::Zero
}

function Get-ControlText([IntPtr]$Parent, [int]$ControlId) {
  $handle = [EBR_SHELL_NOTIFY_NATIVE]::FindVisibleChildById($Parent, $ControlId)
  if ($handle -eq [IntPtr]::Zero) { return $null }
  return [EBR_SHELL_NOTIFY_NATIVE]::WindowText($handle)
}

function Get-VisibleWindowUiSnapshot([IntPtr]$Window) {
  $description = Get-WindowDescription $Window
  $names = [System.Collections.Generic.List[string]]::new()
  $buttons = [System.Collections.Generic.List[object]]::new()
  try {
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($Window)
    if (-not [string]::IsNullOrWhiteSpace($root.Current.Name)) { $names.Add([string]$root.Current.Name) }
    $elements = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    $limit = [Math]::Min($elements.Count, 500)
    for ($index = 0; $index -lt $limit; $index++) {
      try {
        $element = $elements.Item($index)
        $current = $element.Current
        if (-not [string]::IsNullOrWhiteSpace($current.Name)) { $names.Add([string]$current.Name) }
        if ($current.ControlType -eq [System.Windows.Automation.ControlType]::Button) {
          $rect = $current.BoundingRectangle
          $buttons.Add([pscustomobject]@{
            Name=[string]$current.Name;Enabled=[bool]$current.IsEnabled;Offscreen=[bool]$current.IsOffscreen
            Bounds=@([int]$rect.Left,[int]$rect.Top,[int]$rect.Right,[int]$rect.Bottom);Element=$element
          })
        }
      } catch { }
    }
  } catch { }
  [pscustomobject]@{Window=$description;Names=@($names.ToArray());Text=($names -join "`n");Buttons=@($buttons.ToArray())}
}

function Get-OobeSurfaceSnapshot([IntPtr]$CandidateWindow) {
  $surfaces = [System.Collections.Generic.List[object]]::new()
  $taskbarWindow = [EBR_SHELL_NOTIFY_NATIVE]::TaskbarWindow()
  foreach ($windowText in [EBR_SHELL_NOTIFY_NATIVE]::VisibleTopLevelWindows()) {
    $window = [IntPtr]::new([long]$windowText)
    if ($window -eq $CandidateWindow -or $window -eq $taskbarWindow) { continue }
    $snapshot = Get-VisibleWindowUiSnapshot $window
    if ($snapshot.Names.Count -gt 0) { $surfaces.Add($snapshot) }
  }
  return @($surfaces.ToArray())
}

function Get-OobeEvidenceSurface($Surface) {
  # The exact privacy-page heading is the only setup page this harness may advance.
  # The other markers are used solely to stop on an unknown page; they never
  # authorize a click or acceptance of any setup/licence prompt.
  $text = [string]$Surface.Text
  $exactPrivacy = $text -match '(?is)Choose\s+privacy\s+settings\s+for\s+your\s+device'
  $processName = [string]$Surface.Window.ProcessName
  $oobeProcess = $processName -match '(?i)^(CloudExperienceHost(Broker)?|UserOOBEBroker|msoobe|OOBE.*)$'
  $oobeMarker = $oobeProcess -or $text -match '(?is)(choose\s+privacy\s+settings|privacy\s+settings|license\s+terms|licence\s+terms|license\s+agreement|licence\s+agreement|end\s+user\s+license|terms\s+of\s+use|accept\s+and\s+continue|agree\s+and\s+continue|let.?s\s+connect|connect\s+to\s+a\s+network|microsoft\s+account|windows\s+hello|finish\s+setting\s+up|set\s+up\s+your\s+device|set\s+up\s+windows|choose\s+your\s+region|choose\s+your\s+keyboard|welcome\s+to\s+windows|out.of.box|your\s+device\s+is\s+almost\s+ready|let.?s\s+finish\s+setting\s+up)'
  if ($exactPrivacy -or $oobeMarker) {
    return [pscustomobject]@{Snapshot=$Surface;ExactPrivacyPage=$exactPrivacy;OobeMarker=$oobeMarker}
  }
  return $null
}

function Get-HigherOverlappingWindowRecords([IntPtr]$Window) {
  $orderedWindows=@([EBR_SHELL_NOTIFY_NATIVE]::VisibleTopLevelWindows() | ForEach-Object { [IntPtr]::new([long]$_) })
  $windowIndex=[Array]::IndexOf($orderedWindows,$Window)
  if ($windowIndex-lt0) { return @() }
  $targetBounds=[EBR_SHELL_NOTIFY_NATIVE]::Bounds($Window)
  $taskbarWindow=[EBR_SHELL_NOTIFY_NATIVE]::TaskbarWindow()
  $overlaps=[System.Collections.Generic.List[object]]::new()
  for ($index=0;$index-lt$windowIndex;$index++) {
    $higher=$orderedWindows[$index]
    if ($higher-eq$taskbarWindow) { continue }
    $description=Get-WindowDescription $higher
    [int[]]$rect=$description.Bounds
    if ($rect.Count-ne4-or$targetBounds.Count-ne4) { continue }
    $width=[Math]::Max(0,[Math]::Min($targetBounds[2],$rect[2])-[Math]::Max($targetBounds[0],$rect[0]))
    $height=[Math]::Max(0,[Math]::Min($targetBounds[3],$rect[3])-[Math]::Max($targetBounds[1],$rect[1]))
    if ($width-gt0-and$height-gt0) { $overlaps.Add([pscustomobject]@{Window=$description;OverlapPixels=@($width,$height)}) }
  }
  return @($overlaps.ToArray())
}

function Test-WindowInVisibleZOrder([IntPtr]$Window) {
  $handles=@([EBR_SHELL_NOTIFY_NATIVE]::VisibleTopLevelWindows() | ForEach-Object { [IntPtr]::new([long]$_) })
  return [Array]::IndexOf($handles,$Window)-ge0
}

function Resolve-FirstRunOobeAndVerifyCandidate([IntPtr]$CandidateWindow, [int]$CandidateProcessId) {
  $record = [ordered]@{
    Status='NOT TESTED';PrivacyPageDetected=$false;PrivacyPageAdvanced=$false
    CandidateForegroundVerified=$false;CandidateUnobscuredVerified=$false
    Reason=$null;Surfaces=@();Screenshots=@();ForegroundBefore=$null;ForegroundAfter=$null;ZOrderBlockers=@()
  }
  if ([EBR_SHELL_NOTIFY_NATIVE]::OwnerProcessId($CandidateWindow)-ne$CandidateProcessId -or -not(Test-WindowInVisibleZOrder $CandidateWindow)) {
    $record.Reason='The visible candidate HWND could not be tied to the harness-owned process in the desktop z-order.'
    $script:oobeRecord=[pscustomobject]$record
    throw "NOT TESTED: $($record.Reason)"
  }
  $initialSurfaces = @(Get-OobeSurfaceSnapshot $CandidateWindow)
  $evidenceSurfaces = @($initialSurfaces | ForEach-Object { Get-OobeEvidenceSurface $_ } | Where-Object { $_ })
  $privacyPages = @($evidenceSurfaces | Where-Object { $_.ExactPrivacyPage })
  $safeSummary = @($evidenceSurfaces | ForEach-Object {
    [pscustomobject]@{Window=$_.Snapshot.Window;ExactPrivacyPage=$_.ExactPrivacyPage;OobeMarker=$_.OobeMarker;Names=@($_.Snapshot.Names)}
  })
  $record.Surfaces = $safeSummary

  $initialOverlaps=@(Get-HigherOverlappingWindowRecords $CandidateWindow)
  $allowedPrivacyHandle=if($privacyPages.Count-eq1){[string]$privacyPages[0].Snapshot.Window.Handle}else{''}
  $unexpectedInitialOverlaps=@($initialOverlaps | Where-Object { [string]$_.Window.Handle -cne $allowedPrivacyHandle })
  if ($unexpectedInitialOverlaps.Count-gt0) {
    $record.ZOrderBlockers=$unexpectedInitialOverlaps
    $record.Reason='An unrecognized visible window overlaps and covers the candidate; no candidate or overlay control was interacted with.'
    $script:oobeRecord=[pscustomobject]$record
    Add-Event 'Fail closed on an unrecognized window covering the candidate before testing' 'BLOCKED' $script:oobeRecord
    throw "BLOCKED: $($record.Reason)"
  }

  if ($privacyPages.Count -gt 1) {
    $record.Reason='More than one visible window exposed the exact Windows privacy OOBE heading; no page was advanced.'
    $script:oobeRecord=[pscustomobject]$record
    Add-Event 'Detect first-run OOBE before candidate interaction' 'BLOCKED' $script:oobeRecord
    throw "BLOCKED: $($record.Reason)"
  }
  if ($evidenceSurfaces.Count -gt $privacyPages.Count) {
    $record.Reason='An unknown Windows setup/OOBE surface is visible; only the exact privacy page may be advanced, so no control was invoked.'
    $script:oobeRecord=[pscustomobject]$record
    Add-Event 'Detect unknown first-run OOBE surface and fail closed' 'BLOCKED' $script:oobeRecord
    throw "BLOCKED: $($record.Reason)"
  }

  if ($privacyPages.Count -eq 1) {
    $record.PrivacyPageDetected=$true
    $privacySurface=$privacyPages[0].Snapshot
    $sensitiveText=$privacySurface.Text -match '(?is)(license|licence|end\s+user|terms\s+of\s+use|agreement|\baccept\b|\bagree\b)'
    $nextButtons=@($privacySurface.Buttons | Where-Object { $_.Name -ceq 'Next' -and $_.Enabled -and -not $_.Offscreen })
    if ($sensitiveText) {
      $record.Reason='The exact privacy heading coexists with agreement/acceptance text; no control was invoked.'
      $script:oobeRecord=[pscustomobject]$record
      Add-Event 'Refuse to interact with an OOBE surface containing agreement or acceptance text' 'BLOCKED' $script:oobeRecord
      throw "BLOCKED: $($record.Reason)"
    }
    if ($nextButtons.Count -ne 1) {
      $record.Reason="The exact privacy page did not expose exactly one enabled, visible button named Next (found $($nextButtons.Count)); no control was invoked."
      $script:oobeRecord=[pscustomobject]$record
      Add-Event 'Require one exact Next control on the privacy OOBE page' 'BLOCKED' $script:oobeRecord
      throw "BLOCKED: $($record.Reason)"
    }
    $beforeShot=Capture-InteractiveDesktop 'env-009-oobe-privacy-before.png'
    if (-not $beforeShot) {
      $record.Reason='Could not capture the hosted interactive desktop before the exact privacy-page action; no control was invoked.'
      $script:oobeRecord=[pscustomobject]$record
      throw "NOT TESTED: $($record.Reason)"
    }
    $record.Screenshots += $beforeShot.Path
    $record.Surfaces += [pscustomobject]@{Stage='before-privacy-next';DesktopScreenshot=$beforeShot;Window=$privacySurface.Window;AccessibleNames=@($privacySurface.Names);NextButton=$nextButtons[0].Name;NextButtonBounds=$nextButtons[0].Bounds;DefaultSelectionsChanged=$false}
    $record.Reason='The exact privacy page was identified; the harness is about to invoke its single visible Next control without changing any defaults.'
    $script:oobeRecord=[pscustomobject]$record
    $nextElement=$nextButtons[0].Element
    $invokePattern=$null
    if (-not $nextElement.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern,[ref]$invokePattern)) {
      $record.Reason='The exact enabled Next control did not expose UI Automation InvokePattern; no fallback control or coordinate was used.'
      $script:oobeRecord=[pscustomobject]$record
      throw "BLOCKED: $($record.Reason)"
    }
    $invokePattern.Invoke()
    $record.PrivacyPageAdvanced=$true
    Add-Event 'Advance only the exact Windows privacy page using its enabled Next control; leave every default selection unchanged' 'ACTION' ([pscustomobject]@{Window=$privacySurface.Window;Button='Next';InvokePattern=$true;DefaultSelectionsChanged=$false;BeforeScreenshot=$beforeShot.Path})

    $pageWatch=[Diagnostics.Stopwatch]::StartNew()
    $remainingExactPage=$true
    $unknownOobeAfterAction=$false
    $lastAfterEvidence=@()
    do {
      Start-Sleep -Milliseconds 250
      $afterSurfaces=@(Get-OobeSurfaceSnapshot $CandidateWindow)
      $afterEvidence=@($afterSurfaces | ForEach-Object { Get-OobeEvidenceSurface $_ } | Where-Object { $_ })
      $remainingExactPage=@($afterEvidence | Where-Object { $_.ExactPrivacyPage }).Count -gt 0
      if (@($afterEvidence | Where-Object { -not $_.ExactPrivacyPage }).Count -gt 0) { $unknownOobeAfterAction=$true }
      $lastAfterEvidence=$afterEvidence
    } while (($remainingExactPage -or $pageWatch.Elapsed.TotalSeconds -lt 3) -and $pageWatch.Elapsed.TotalSeconds -lt 15)
    $record.Surfaces += @($lastAfterEvidence | ForEach-Object { [pscustomobject]@{Stage='after-privacy-next';Window=$_.Snapshot.Window;ExactPrivacyPage=$_.ExactPrivacyPage;OobeMarker=$_.OobeMarker;AccessibleNames=@($_.Snapshot.Names)} })
    if ($remainingExactPage) {
      $record.Reason='The exact privacy OOBE page remained visible after its single Next action; no retry or additional setup-page interaction was attempted.'
      $script:oobeRecord=[pscustomobject]$record
      throw "BLOCKED: $($record.Reason)"
    }
    if ($afterEvidence.Count -gt 0) {
      $record.Reason='A further or unknown OOBE/setup surface appeared after the privacy page; no additional page was advanced.'
      $script:oobeRecord=[pscustomobject]$record
      throw "BLOCKED: $($record.Reason)"
    }
    if ($unknownOobeAfterAction) {
      $record.Reason='A further or unknown OOBE/setup surface appeared during the post-action observation window; no additional page was advanced.'
      $script:oobeRecord=[pscustomobject]$record
      throw "BLOCKED: $($record.Reason)"
    }
    $remainingOverlaps=@(Get-HigherOverlappingWindowRecords $CandidateWindow)
    if ($remainingOverlaps.Count-gt0) {
      $record.ZOrderBlockers=$remainingOverlaps
      $record.Reason='A visible higher z-order window still overlaps the candidate after the exact privacy page disappeared; no other surface was advanced.'
      $script:oobeRecord=[pscustomobject]$record
      throw "BLOCKED: $($record.Reason)"
    }
    $afterShot=Capture-InteractiveDesktop 'env-009-oobe-after-privacy-next.png'
    if (-not $afterShot) {
      $record.Reason='The privacy page disappeared, but the required post-action hosted desktop screenshot could not be captured.'
      $script:oobeRecord=[pscustomobject]$record
      throw "NOT TESTED: $($record.Reason)"
    }
    $record.Screenshots += $afterShot.Path
    Add-Event 'Verify the privacy OOBE page disappeared and no following setup page appeared' 'PASS' ([pscustomobject]@{AfterScreenshot=$afterShot.Path;DefaultSelectionsChanged=$false;AdditionalOobePageAdvanced=$false})
  }

  $foregroundBefore=[EBR_SHELL_NOTIFY_NATIVE]::ForegroundWindow()
  $record.ForegroundBefore=if($foregroundBefore-ne[IntPtr]::Zero){Get-WindowDescription $foregroundBefore}else{$null}
  if (-not [EBR_SHELL_NOTIFY_NATIVE]::SetForegroundWindow($CandidateWindow)) {
    $record.Reason='The candidate could not be brought to the foreground in the hosted interactive session.'
    $script:oobeRecord=[pscustomobject]$record
    throw "NOT TESTED: $($record.Reason)"
  }
  $focusWatch=[Diagnostics.Stopwatch]::StartNew()
  do {
    Start-Sleep -Milliseconds 100
    $foregroundAfter=[EBR_SHELL_NOTIFY_NATIVE]::ForegroundWindow()
  } while ($foregroundAfter-ne$CandidateWindow -and $focusWatch.Elapsed.TotalSeconds-lt5)
  $record.ForegroundAfter=if($foregroundAfter-ne[IntPtr]::Zero){Get-WindowDescription $foregroundAfter}else{$null}
  $record.CandidateForegroundVerified=($foregroundAfter-eq$CandidateWindow -and [EBR_SHELL_NOTIFY_NATIVE]::IsWindowVisible($CandidateWindow))
  if (-not $record.CandidateForegroundVerified) {
    $record.Reason='The candidate main HWND was not the foreground visible window after the OOBE check.'
    $script:oobeRecord=[pscustomobject]$record
    throw "NOT TESTED: $($record.Reason)"
  }
  if (-not(Test-WindowInVisibleZOrder $CandidateWindow)) {
    $record.Reason='Candidate foreground HWND is absent from the visible top-level z-order enumeration.'
    $script:oobeRecord=[pscustomobject]$record
    throw "NOT TESTED: $($record.Reason)"
  }

  $record.ZOrderBlockers=@(Get-HigherOverlappingWindowRecords $CandidateWindow)
  $uiaCandidate=[System.Windows.Automation.AutomationElement]::FromHandle($CandidateWindow)
  $candidateOffscreen=$uiaCandidate.Current.IsOffscreen
  $record.CandidateUnobscuredVerified=($record.ZOrderBlockers.Count-eq0-and-not$candidateOffscreen)
  if (-not $record.CandidateUnobscuredVerified) {
    $record.Reason=if($candidateOffscreen){'Candidate HWND is offscreen in UI Automation.'}else{'One or more higher z-order windows overlap the candidate main window.'}
    $script:oobeRecord=[pscustomobject]$record
    throw "NOT TESTED: $($record.Reason)"
  }
  $record.Status='PASS'
  $record.Reason='No OOBE surface blocked the candidate (or only the exact privacy page was advanced once); the candidate main HWND is visible, foreground, on-screen, and has no higher overlapping top-level window.'
  $script:oobeRecord=[pscustomobject]$record
  Add-Assertion 'Candidate main window is foreground and unobscured after safe OOBE handling' $true $script:oobeRecord
}

function Capture-WindowScreenshot([IntPtr]$Window, [string]$FileName) {
  $bounds = [EBR_SHELL_NOTIFY_NATIVE]::Bounds($Window)
  if ($bounds.Count -ne 4) { return $null }
  $width = $bounds[2] - $bounds[0]; $height = $bounds[3] - $bounds[1]
  if ($width -lt 100 -or $height -lt 100 -or $width -gt 5000 -or $height -gt 4000) { return $null }
  Add-Type -AssemblyName System.Drawing -ErrorAction Stop
  $bitmap = [Drawing.Bitmap]::new($width, $height)
  $graphics = [Drawing.Graphics]::FromImage($bitmap)
  $path = Join-Path $EvidenceDirectory $FileName
  try {
    $graphics.CopyFromScreen($bounds[0], $bounds[1], 0, 0, $bitmap.Size)
    $bitmap.Save($path, [Drawing.Imaging.ImageFormat]::Png)
  } finally { $graphics.Dispose(); $bitmap.Dispose() }
  return [pscustomobject]@{Path=$path;Width=$width;Height=$height;WindowBounds=$bounds;Window=(Get-WindowDescription $Window)}
}

function Capture-InteractiveDesktop([string]$FileName) {
  Add-Type -AssemblyName System.Drawing -ErrorAction Stop
  Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
  $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
  if ($bounds.Width -le 0 -or $bounds.Height -le 0 -or $bounds.Width -gt 8000 -or $bounds.Height -gt 5000) { return $null }
  $bitmap = [Drawing.Bitmap]::new($bounds.Width, $bounds.Height)
  $graphics = [Drawing.Graphics]::FromImage($bitmap)
  $path = Join-Path $EvidenceDirectory $FileName
  try {
    # This screenshot is taken only on the fresh GitHub-hosted disposable VM.
    $graphics.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bitmap.Size)
    $bitmap.Save($path, [Drawing.Imaging.ImageFormat]::Png)
  } finally { $graphics.Dispose(); $bitmap.Dispose() }
  return [pscustomobject]@{Path=$path;Width=$bounds.Width;Height=$bounds.Height;VirtualScreen=@($bounds.Left,$bounds.Top,$bounds.Width,$bounds.Height);Capture='fresh GitHub-hosted runner desktop'}
}

function Get-ShellProcessIds {
  $names = @('explorer','ShellExperienceHost','ApplicationFrameHost','StartMenuExperienceHost','RuntimeBroker','sihost','ShellHost')
  return @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $names -contains $_.ProcessName -and $_.SessionId -eq $sessionId } | Select-Object -ExpandProperty Id -Unique)
}

function Get-ShellNotificationSnapshot {
  $snapshot = [pscustomobject]@{Utc=[DateTime]::UtcNow.ToString('o');SurfaceObserved=$false;TitleObserved=$false;BodyObserved=$false;Matches=@();ShellWindows=@();CorrelatedContainer=$null;CorrelationFailure=$null;Error=$null;TraversalErrors=@();ElementReferences=@()}
  try {
    $shellProcesses = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { @('explorer','ShellExperienceHost','ApplicationFrameHost','StartMenuExperienceHost','RuntimeBroker','sihost','ShellHost') -contains $_.ProcessName -and $_.SessionId -eq $sessionId })
    $shellProcessNames = @{}
    foreach ($process in $shellProcesses) { $shellProcessNames[[int]$process.Id] = [string]$process.ProcessName }
    $shellProcessIds = @($shellProcessNames.Keys)
    $visibleShellWindows = [System.Collections.Generic.List[object]]::new()
    foreach ($shellPid in $shellProcessIds) {
      foreach ($windowText in [EBR_SHELL_NOTIFY_NATIVE]::WindowsForProcess([int]$shellPid)) {
        $handle = [IntPtr]::new([long]$windowText)
        $description = Get-WindowDescription $handle
        if ($description.Visible) { $visibleShellWindows.Add($description) }
      }
    }
    $snapshot.ShellWindows = $visibleShellWindows.ToArray()
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $elements = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    $matches = [System.Collections.Generic.List[object]]::new()
    $refs = [System.Collections.Generic.List[object]]::new()
    $traversalErrors = [System.Collections.Generic.List[string]]::new()
    $titleObserved = $false; $bodyObserved = $false
    for ($index=0; $index -lt $elements.Count; $index++) {
      $element = $elements.Item($index)
      try {
        $current = $element.Current
        if ($current.ProcessId -eq $candidatePid -or $current.IsOffscreen -or [string]::IsNullOrWhiteSpace($current.Name)) { continue }
        if (-not $shellProcessNames.ContainsKey([int]$current.ProcessId)) { continue }
        $isTitle = $current.Name -match [regex]::Escape($expectedNotificationTitle)
        $isBody = $current.Name -match $expectedNotificationBodyPattern
        if (-not $isTitle -and -not $isBody) { continue }
        if ($isTitle) { $titleObserved = $true }
        if ($isBody) { $bodyObserved = $true }
        $bounds = $current.BoundingRectangle
        $matches.Add([pscustomobject]@{
          ProcessId=[int]$current.ProcessId;ProcessName=$shellProcessNames[[int]$current.ProcessId];Name=[string]$current.Name
          ControlType=[string]$current.ControlType.ProgrammaticName;AutomationId=[string]$current.AutomationId
          ClassName=[string]$current.ClassName;IsOffscreen=[bool]$current.IsOffscreen
          HasKeyboardFocus=[bool]$current.HasKeyboardFocus;NativeWindowHandle=[int]$current.NativeWindowHandle
          Bounds=@([double]$bounds.Left,[double]$bounds.Top,[double]$bounds.Width,[double]$bounds.Height)
          TitleMatch=$isTitle;BodyMatch=$isBody
        })
      } catch {$traversalErrors.Add("Shell root element ${index}: $($_.Exception.Message)")}
    }
    $snapshot.TitleObserved = $titleObserved
    $snapshot.BodyObserved = $bodyObserved
    # Require exactly one title and body in the same visible top-level Windows
    # Shell window. This prevents unrelated Shell nodes or different toasts
    # from satisfying the grouped visibility assertion.
    foreach ($window in $visibleShellWindows) {
      try {
        $windowHandle = [IntPtr]::new([Convert]::ToInt64(([string]$window.Handle).Substring(2),16))
        $windowElement = [System.Windows.Automation.AutomationElement]::FromHandle($windowHandle)
        if ($null -eq $windowElement) {$traversalErrors.Add("Visible Shell window $($window.Handle) could not be opened through UI Automation.");continue}
        $windowNodes = $windowElement.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
        $windowTitles = [System.Collections.Generic.List[object]]::new()
        $windowBodies = [System.Collections.Generic.List[object]]::new()
        for ($nodeIndex=0; $nodeIndex -lt $windowNodes.Count; $nodeIndex++) {
          $node = $windowNodes.Item($nodeIndex)
          try {
            $nodeCurrent = $node.Current
            if ($nodeCurrent.ProcessId -ne [int]$window.ProcessId -or $nodeCurrent.IsOffscreen -or [string]::IsNullOrWhiteSpace($nodeCurrent.Name)) { continue }
            if ($nodeCurrent.Name -match [regex]::Escape($expectedNotificationTitle)) { $windowTitles.Add($node) }
            if ($nodeCurrent.Name -match $expectedNotificationBodyPattern) { $windowBodies.Add($node) }
          } catch {$traversalErrors.Add("Shell window $($window.Handle), node ${nodeIndex}: $($_.Exception.Message)")}
        }
        if ($windowTitles.Count -eq 1 -and $windowBodies.Count -eq 1) {
          $titleCurrent = $windowTitles[0].Current
          $bodyCurrent = $windowBodies[0].Current
          $titleBounds=$titleCurrent.BoundingRectangle;$bodyBounds=$bodyCurrent.BoundingRectangle
          $virtualScreen=[System.Windows.Forms.SystemInformation]::VirtualScreen
          $titleCenterX=$titleBounds.Left+$titleBounds.Width/2;$titleCenterY=$titleBounds.Top+$titleBounds.Height/2
          $bodyCenterX=$bodyBounds.Left+$bodyBounds.Width/2;$bodyCenterY=$bodyBounds.Top+$bodyBounds.Height/2
          $titleBoundsValid=($titleBounds.Width-gt0-and$titleBounds.Height-gt0-and[double]::IsFinite($titleCenterX)-and[double]::IsFinite($titleCenterY)-and$titleCenterX-ge$virtualScreen.Left-and$titleCenterX-lt$virtualScreen.Right-and$titleCenterY-ge$virtualScreen.Top-and$titleCenterY-lt$virtualScreen.Bottom)
          $bodyBoundsValid=($bodyBounds.Width-gt0-and$bodyBounds.Height-gt0-and[double]::IsFinite($bodyCenterX)-and[double]::IsFinite($bodyCenterY)-and$bodyCenterX-ge$virtualScreen.Left-and$bodyCenterX-lt$virtualScreen.Right-and$bodyCenterY-ge$virtualScreen.Top-and$bodyCenterY-lt$virtualScreen.Bottom)
          $titleRuntimeId=(@($windowTitles[0].GetRuntimeId()) -join '.')
          $bodyRuntimeId=(@($windowBodies[0].GetRuntimeId()) -join '.')
          $titleRoot=if($titleBoundsValid){[EBR_SHELL_NOTIFY_NATIVE]::RootWindowAtPoint([int]$titleCenterX,[int]$titleCenterY)}else{$null}
          $bodyRoot=if($bodyBoundsValid){[EBR_SHELL_NOTIFY_NATIVE]::RootWindowAtPoint([int]$bodyCenterX,[int]$bodyCenterY)}else{$null}
          $titleHit=($titleBoundsValid-and$titleRoot-ceq[string]$window.Handle);$bodyHit=($bodyBoundsValid-and$bodyRoot-ceq[string]$window.Handle)
          $container=[pscustomobject]@{Type='same visible top-level Windows Shell notification window';Window=$window;VirtualScreen=@($virtualScreen.Left,$virtualScreen.Top,$virtualScreen.Width,$virtualScreen.Height);TitleNode=[pscustomobject]@{Name=[string]$titleCurrent.Name;ControlType=$titleCurrent.ControlType.ProgrammaticName;AutomationId=$titleCurrent.AutomationId;RuntimeId=$titleRuntimeId;Bounds=@([double]$titleBounds.Left,[double]$titleBounds.Top,[double]$titleBounds.Width,[double]$titleBounds.Height);BoundsValid=$titleBoundsValid;HitTestRootWindow=$titleRoot;VisibleAtWindowLevel=$titleHit};BodyNode=[pscustomobject]@{Name=[string]$bodyCurrent.Name;ControlType=$bodyCurrent.ControlType.ProgrammaticName;AutomationId=$bodyCurrent.AutomationId;RuntimeId=$bodyRuntimeId;Bounds=@([double]$bodyBounds.Left,[double]$bodyBounds.Top,[double]$bodyBounds.Width,[double]$bodyBounds.Height);BoundsValid=$bodyBoundsValid;HitTestRootWindow=$bodyRoot;VisibleAtWindowLevel=$bodyHit};UniqueTitleCount=$windowTitles.Count;UniqueBodyCount=$windowBodies.Count}
          if($titleHit-and$bodyHit){$snapshot.SurfaceObserved=$true;$snapshot.CorrelatedContainer=$container;$refs.Add($windowTitles[0]);$refs.Add($windowBodies[0]);break}
          $snapshot.CorrelationFailure='The title and body share one Shell window, but one or both UIA text nodes have invalid/off-screen bounds or hit-test to another top-level window; the surface may be obscured.'
          $snapshot.CorrelatedContainer=$container
        }
      } catch {$traversalErrors.Add("Shell window $($window.Handle): $($_.Exception.Message)")}
    }
    $snapshot.TraversalErrors=$traversalErrors.ToArray()
    $snapshot.Matches = $matches.ToArray()
    $snapshot.ElementReferences = $refs.ToArray()
  } catch { $snapshot.Error = $_.Exception.Message }
  $shellSnapshots.Add([pscustomobject]@{Utc=$snapshot.Utc;SurfaceObserved=$snapshot.SurfaceObserved;TitleObserved=$snapshot.TitleObserved;BodyObserved=$snapshot.BodyObserved;CorrelatedContainer=$snapshot.CorrelatedContainer;CorrelationFailure=$snapshot.CorrelationFailure;Matches=$snapshot.Matches;ShellWindows=$snapshot.ShellWindows;TraversalErrors=$snapshot.TraversalErrors;Error=$snapshot.Error})
  return $snapshot
}

function Test-SameShellNotification([object]$First,[object]$Next) {
  if(-not$First-or-not$Next-or-not$First.SurfaceObserved-or-not$Next.SurfaceObserved){return $false}
  $a=$First.CorrelatedContainer;$b=$Next.CorrelatedContainer
  return [bool]($a-and$b-and$a.Window.Handle-ceq$b.Window.Handle-and$a.TitleNode.RuntimeId-ceq$b.TitleNode.RuntimeId-and$a.BodyNode.RuntimeId-ceq$b.BodyNode.RuntimeId-and$a.TitleNode.HitTestRootWindow-ceq$b.TitleNode.HitTestRootWindow-and$a.BodyNode.HitTestRootWindow-ceq$b.BodyNode.HitTestRootWindow)
}

function Try-InvokeShellNotification([object]$Snapshot, [IntPtr]$MainWindow) {
  $record = [pscustomobject]@{Status='NOT TESTED';Method=$null;ControlName=$null;Reason='No exposed invokable notification control was found.';MainWindowVisibleAfter=$false;Utc=[DateTime]::UtcNow.ToString('o')}
  $activeSnapshot=Get-ShellNotificationSnapshot
  if(-not(Test-SameShellNotification $Snapshot $activeSnapshot)){$record.Reason='The exact observed notification identity changed before activation; no stale UIA element was invoked.';return $record}
  foreach ($element in $activeSnapshot.ElementReferences) {
    $candidate = $element
    for ($depth=0; $depth -lt 4 -and $null -ne $candidate; $depth++) {
      try {
        $current = $candidate.Current
        $isNotificationControl = ($current.Name -match [regex]::Escape($expectedNotificationTitle) -or $current.Name -match $expectedNotificationBodyPattern)
        if ($current.ProcessId -ne $candidatePid -and -not $current.IsOffscreen -and $isNotificationControl) {
          $pattern = $null
          if ($candidate.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) {
            $pattern.Invoke()
            $watch = [Diagnostics.Stopwatch]::StartNew()
            while ($watch.Elapsed.TotalSeconds -lt 5 -and -not [EBR_SHELL_NOTIFY_NATIVE]::IsWindowVisible($MainWindow)) { Start-Sleep -Milliseconds 100 }
            $record.Status = if ([EBR_SHELL_NOTIFY_NATIVE]::IsWindowVisible($MainWindow)) { 'PASS' } else { 'NOT TESTED' }
            $record.Method = 'UI Automation InvokePattern on the observed Windows Shell notification surface'
            $record.ControlName = [string]$current.Name
            $record.Reason = if ($record.Status -eq 'PASS') { 'The real Shell notification was invokable and opened the candidate main window.' } else { 'The Shell element was invoked, but the candidate main window did not become visible.' }
            $record.MainWindowVisibleAfter = [EBR_SHELL_NOTIFY_NATIVE]::IsWindowVisible($MainWindow)
            $record.Utc = [DateTime]::UtcNow.ToString('o')
            return $record
          }
        }
        $candidate = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($candidate)
      } catch { break }
    }
  }
  return $record
}

function Try-DismissShellNotification([object]$Snapshot) {
  $record = [pscustomobject]@{Status='NOT TESTED';ControlName=$null;Reason='The actual notification surface exposed no safely scoped Dismiss/Close control.';SurfaceDisappeared=$false;Utc=[DateTime]::UtcNow.ToString('o')}
  $activeSnapshot=Get-ShellNotificationSnapshot
  if(-not(Test-SameShellNotification $Snapshot $activeSnapshot)){$record.Reason='The exact observed notification identity changed before dismissal; no stale UIA element was invoked.';return $record}
  foreach ($element in $activeSnapshot.ElementReferences) {
    $candidate = $element
    for ($depth=0; $depth -lt 4 -and $null -ne $candidate; $depth++) {
      try {
        $current = $candidate.Current
        if ($current.ProcessId -ne $candidatePid -and -not $current.IsOffscreen -and $current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and $current.Name -match '(?i)^(dismiss notification|close notification)$') {
          $pattern = $null
          if ($candidate.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) {
            $invokeStartedUtc=[DateTime]::UtcNow.ToString('o')
            $pattern.Invoke()
            $after = Get-ShellNotificationSnapshot
            $hasNoVisibleExpectedText=(-not$after.TitleObserved-and-not$after.BodyObserved)
            $shellSnapshotHealthy=(-not$after.Error-and-not$after.CorrelationFailure-and@($after.TraversalErrors).Count-eq0-and@($after.ShellWindows).Count-gt0)
            $gone=($shellSnapshotHealthy-and$hasNoVisibleExpectedText-and-not$after.SurfaceObserved)
            $record.Status = if ($gone) { 'PASS' } else { 'NOT TESTED' }
            $record.ControlName = [string]$current.Name
            $record.Reason = if ($gone) { 'A scoped visible Dismiss/Close control was invoked while the same notification identity was current; a healthy Shell snapshot showed no visible matching title or body immediately afterward.' } elseif(-not$shellSnapshotHealthy){'Dismiss/Close was invoked, but the post-action Shell snapshot was incomplete or ambiguous.'} elseif(-not$hasNoVisibleExpectedText){'Dismiss/Close was invoked, but matching notification title/body text remained visible immediately afterward.'} else { 'Dismiss/Close was invoked, but a correlated title/body surface remained visible immediately afterward.' }
            $record.SurfaceDisappeared = $gone
            $record.SameNotificationBeforeAction=$activeSnapshot.CorrelatedContainer
            $record.AfterAction=$after.CorrelatedContainer
            $record.AfterActionSnapshotHealthy=$shellSnapshotHealthy
            $record.AfterActionTraversalErrors=@($after.TraversalErrors)
            $record.InvokeStartedUtc=$invokeStartedUtc
            $record.Utc = [DateTime]::UtcNow.ToString('o')
            return $record
          }
        }
        $candidate = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($candidate)
      } catch { break }
    }
  }
  return $record
}

function Save-Result([string]$FinalStatus, [string]$FinalReason) {
  $result = [pscustomobject]@{
    Requirement='ENV-009'; Status=$FinalStatus; Reason=$FinalReason
    Candidate=[pscustomobject]@{ArtifactId=$candidateArtifactId;FinalizerRunId=$candidateRunId;SourceCommit=$candidateSourceCommit;ExecutablePath=$ExecutablePath;SHA256=$expectedSha256;Identity=$candidateIdentity;Execution='x64 emulation on native Windows 11 ARM64';InstallerLaunched=$false}
    OperatingSystem=$osRecord
    Environment=[pscustomobject]@{Provider='GitHub-hosted Actions runner';ImageOS=$env:ImageOS;ImageVersion=$env:ImageVersion;RunnerOS=$env:RUNNER_OS;RunnerArchitecture=$env:RUNNER_ARCH;ProcessSessionId=$sessionId;UserInteractive=[Environment]::UserInteractive}
    Profile=[pscustomobject]@{LocalAppData=$env:LOCALAPPDATA;AppDataPath=$dataDirectory;AppDataAbsentBeforeTest=(-not $dataExistedBefore);TestDataCreatedByHarness=$dataCreatedByHarness;TestDataRemoved=$dataRemoved}
    Timer=$timerRecord;FirstRunOobe=$oobeRecord;WindowsShell=$shellRecord;ShellNotificationVisibilityStatus=$shellVisibilityStatus;ShellNotificationVisibilityReason=$shellVisibilityReason
    NotificationActivation=$activationRecord;NotificationDismissal=$dismissalRecord;NotificationPersistence=$persistenceRecord
    Audio=[pscustomobject]@{Status=$notificationAudioStatus;PhysicalAudioVerified=$physicalAudioVerified;NotificationSoundExpected=$false;Reason='The candidate sets NIIF_NOSOUND and NIIF_RESPECT_QUIET_TIME for Shell reminders. Alarm audio was disabled for this test; no audio endpoint or audible output was verified.'}
    Assertions=@($assertions);Events=@($events);ShellUiAutomationSnapshots=@($shellSnapshots)
    AssertionCounts=[pscustomobject]@{Total=$assertions.Count;Passed=@($assertions|Where-Object{$_.Passed}).Count;NotTested=@($assertions|Where-Object{-not$_.Passed}).Count}
    Screenshots=@(@($desktopScreenshotPath,$shellNotificationScreenshotPath,$breakScreenshotPath) + @($oobeRecord.Screenshots) | Where-Object { $_ })
    LogFile=$logPath
    Cleanup=[pscustomobject]@{CandidateProcessStopped=$candidateStopped;AppDataRemoved=$dataRemoved;Errors=@($cleanupErrors)}
    Limitations=@('Windows 11 ARM64 host; exact x64 candidate ran under emulation, not native x64.','ENV-009 aggregate status remains BLOCKED because audio was not verified; notification visibility is tracked independently.','The standalone candidate was launched; no installer, updater, or physical speaker path was exercised.')
    ObservedUtc=[DateTime]::UtcNow.ToString('o')
  }
  $result | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $resultPath -Encoding utf8
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

[StructLayout(LayoutKind.Sequential)] public struct EBR_SHELL_NOTIFY_RECT { public int Left, Top, Right, Bottom; }
[StructLayout(LayoutKind.Sequential)] public struct EBR_SHELL_NOTIFY_POINT { public int X, Y; }
[StructLayout(LayoutKind.Sequential)] public struct EBR_SHELL_NOTIFY_ICON_IDENTIFIER { public uint cbSize; public IntPtr hWnd; public uint uID; public Guid guidItem; }
[StructLayout(LayoutKind.Sequential)] public struct EBR_SHELL_SYSTEM_INFO { public ushort ProcessorArchitecture; public ushort Reserved; public uint PageSize; public IntPtr MinimumApplicationAddress; public IntPtr MaximumApplicationAddress; public UIntPtr ActiveProcessorMask; public uint NumberOfProcessors; public uint ProcessorType; public uint AllocationGranularity; public ushort ProcessorLevel; public ushort ProcessorRevision; }

public static class EBR_SHELL_NOTIFY_NATIVE {
  private delegate bool EnumProc(IntPtr hwnd, IntPtr data);
  [DllImport("kernel32.dll")] private static extern void GetNativeSystemInfo(out EBR_SHELL_SYSTEM_INFO info);
  [DllImport("user32.dll", SetLastError=true)] private static extern bool EnumWindows(EnumProc callback, IntPtr data);
  [DllImport("user32.dll", SetLastError=true)] private static extern bool EnumChildWindows(IntPtr parent, EnumProc callback, IntPtr data);
  [DllImport("user32.dll", SetLastError=true)] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="GetWindowTextW", SetLastError=true)] private static extern int GetWindowTextNative(IntPtr hwnd, StringBuilder text, int maxCount);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="GetClassNameW", SetLastError=true)] private static extern int GetClassNameNative(IntPtr hwnd, StringBuilder text, int maxCount);
  [DllImport("user32.dll", SetLastError=true)] private static extern int GetDlgCtrlID(IntPtr hwnd);
  [DllImport("user32.dll", EntryPoint="IsWindowVisible", SetLastError=true)] private static extern bool IsWindowVisibleNative(IntPtr hwnd);
  [DllImport("user32.dll", SetLastError=true)] private static extern bool IsWindowEnabled(IntPtr hwnd);
  [DllImport("user32.dll", SetLastError=true)] private static extern bool GetWindowRect(IntPtr hwnd, out EBR_SHELL_NOTIFY_RECT rect);
  [DllImport("user32.dll", SetLastError=true)] private static extern IntPtr WindowFromPoint(EBR_SHELL_NOTIFY_POINT point);
  [DllImport("user32.dll", SetLastError=true)] private static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
  [DllImport("user32.dll", SetLastError=true)] private static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll", EntryPoint="SetForegroundWindow", SetLastError=true)] private static extern bool SetForegroundWindowNative(IntPtr hwnd);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="FindWindowW", SetLastError=true)] private static extern IntPtr FindWindowNative(string className, string title);
  [DllImport("user32.dll", SetLastError=true)] private static extern bool PostMessageW(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="RegisterWindowMessageW", SetLastError=true)] private static extern uint RegisterWindowMessageNative(string name);
  [DllImport("user32.dll", SetLastError=true)] private static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] private static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extraInfo);
  [DllImport("shell32.dll", SetLastError=true)] private static extern int Shell_NotifyIconGetRect(ref EBR_SHELL_NOTIFY_ICON_IDENTIFIER id, out EBR_SHELL_NOTIFY_RECT rect);
  [DllImport("shell32.dll", SetLastError=true)] private static extern int SHQueryUserNotificationState(out int state);

  public static ushort NativeArchitecture() { EBR_SHELL_SYSTEM_INFO i; GetNativeSystemInfo(out i); return i.ProcessorArchitecture; }
  public static string[] VisibleTopLevelWindows() {
    var found=new List<string>();
    EnumWindows((hwnd,data)=>{if(IsWindowVisible(hwnd))found.Add(hwnd.ToInt64().ToString());return true;},IntPtr.Zero);
    return found.ToArray();
  }
  public static IntPtr ForegroundWindow() { return GetForegroundWindow(); }
  public static bool SetForegroundWindow(IntPtr hwnd) { return SetForegroundWindowNative(hwnd); }
  public static string[] WindowsForProcess(int expectedPid) {
    var found=new List<IntPtr>();
    EnumWindows((hwnd,data)=>{uint pid;GetWindowThreadProcessId(hwnd,out pid);if(pid==(uint)expectedPid&&IsWindowVisible(hwnd))found.Add(hwnd);return true;},IntPtr.Zero);
    var result=new List<string>();foreach(var h in found)result.Add(h.ToInt64().ToString());return result.ToArray();
  }
  public static IntPtr FindVisibleChildById(IntPtr parent,int id) {
    IntPtr found=IntPtr.Zero;EnumChildWindows(parent,(hwnd,data)=>{if(found==IntPtr.Zero&&GetDlgCtrlID(hwnd)==id&&IsWindowVisible(hwnd)&&IsWindowEnabled(hwnd)){found=hwnd;return false;}return true;},IntPtr.Zero);return found;
  }
  public static int[] Bounds(IntPtr hwnd) { EBR_SHELL_NOTIFY_RECT r;if(!GetWindowRect(hwnd,out r))return new int[0];return new int[]{r.Left,r.Top,r.Right,r.Bottom}; }
  public static string WindowText(IntPtr hwnd) { var b=new StringBuilder(512);GetWindowTextNative(hwnd,b,b.Capacity);return b.ToString(); }
  public static string WindowClass(IntPtr hwnd) { var b=new StringBuilder(256);GetClassNameNative(hwnd,b,b.Capacity);return b.ToString(); }
  public static int OwnerProcessId(IntPtr hwnd) { uint pid;GetWindowThreadProcessId(hwnd,out pid);return (int)pid; }
  public static bool IsWindowVisible(IntPtr hwnd) { return IsWindowVisibleNative(hwnd); }
  public static string RootWindowAtPoint(int x,int y) { EBR_SHELL_NOTIFY_POINT p=new EBR_SHELL_NOTIFY_POINT{X=x,Y=y};IntPtr hit=WindowFromPoint(p);if(hit==IntPtr.Zero)return null;IntPtr root=GetAncestor(hit,2);return root==IntPtr.Zero?null:"0x"+root.ToInt64().ToString("X"); }
  public static IntPtr TaskbarWindow() { return FindWindowNative("Shell_TrayWnd",null); }
  public static int TrayIconRectangle(IntPtr hwnd,uint id,out int[] bounds) {
    var ident=new EBR_SHELL_NOTIFY_ICON_IDENTIFIER();ident.cbSize=(uint)Marshal.SizeOf(typeof(EBR_SHELL_NOTIFY_ICON_IDENTIFIER));ident.hWnd=hwnd;ident.uID=id;ident.guidItem=Guid.Empty;
    EBR_SHELL_NOTIFY_RECT r;int hr=Shell_NotifyIconGetRect(ref ident,out r);bounds=hr==0?new int[]{r.Left,r.Top,r.Right,r.Bottom}:new int[0];return hr;
  }
  public static int NotificationState(out int state) { return SHQueryUserNotificationState(out state); }
  public static bool CloseWindow(IntPtr hwnd) { return PostMessageW(hwnd,0x0010,IntPtr.Zero,IntPtr.Zero); }
  public static bool ExitOwnedApp(IntPtr hwnd) { uint msg=RegisterWindowMessageNative("EyeBreakReminder.Exit.Native.1");return msg!=0&&PostMessageW(hwnd,msg,IntPtr.Zero,IntPtr.Zero); }
  public static bool ClickAt(int x,int y) { if(!SetCursorPos(x,y))return false;System.Threading.Thread.Sleep(75);mouse_event(0x0002,0,0,0,UIntPtr.Zero);System.Threading.Thread.Sleep(75);mouse_event(0x0004,0,0,0,UIntPtr.Zero);return true; }
}
'@ -ErrorAction Stop
  Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
  Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop

  $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
  $osArchitecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
  $processArchitecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
  $nativeCpuArchitecture = [EBR_SHELL_NOTIFY_NATIVE]::NativeArchitecture()
  $osRecord = [pscustomobject]@{Caption=$os.Caption;Version=$os.Version;Build=$os.BuildNumber;OSArchitecture=$osArchitecture;ProcessArchitecture=$processArchitecture;NativeProcessorArchitectureCode=$nativeCpuArchitecture;NativeProcessorArchitecture=if($nativeCpuArchitecture-eq12){'ARM64'}else{"Unknown ($nativeCpuArchitecture)"}}
  $sessionId = (Get-Process -Id $PID -ErrorAction Stop).SessionId
  $osValid = ($os.Caption -match 'Windows 11' -and $osArchitecture -eq 'Arm64' -and $processArchitecture -eq 'Arm64' -and $nativeCpuArchitecture -eq 12)
  Add-Assertion 'Runner is Windows 11 with native ARM64 OS, CPU, and ARM64 PowerShell process' $osValid $osRecord
  if (-not $osValid) { throw 'BLOCKED: runner is not native Windows 11 ARM64.' }
  if (-not [Environment]::UserInteractive) { throw 'BLOCKED: runner has no interactive user session.' }
  Add-Assertion 'Windows runner has a genuinely interactive user session' $true ([pscustomobject]@{SessionId=$sessionId;UserInteractive=[Environment]::UserInteractive;RunnerImage=$env:ImageOS})
  $taskbar = [EBR_SHELL_NOTIFY_NATIVE]::TaskbarWindow()
  $explorer = @(Get-Process -Name explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sessionId })
  $shellAvailable = ($taskbar -ne [IntPtr]::Zero -and $explorer.Count -gt 0)
  $shellRecord = [pscustomobject]@{TaskbarWindow=if($taskbar-ne[IntPtr]::Zero){'0x{0:X}'-f$taskbar.ToInt64()}else{$null};ExplorerProcesses=@($explorer|ForEach-Object{[pscustomobject]@{Id=$_.Id;SessionId=$_.SessionId}});InteractiveShellAvailable=$shellAvailable}
  Add-Assertion 'Interactive Windows Shell and Explorer taskbar are present in the runner session' $shellAvailable $shellRecord
  if (-not $shellAvailable) { throw 'NOT TESTED: the runner has no interactive Explorer taskbar for Shell notification display.' }

  if (-not (Test-Path -LiteralPath $ExecutablePath -PathType Leaf)) { throw 'BLOCKED: exact standalone candidate is missing.' }
  $candidateInfo = Get-Item -LiteralPath $ExecutablePath -ErrorAction Stop
  $actualSha256 = (Get-FileHash -LiteralPath $ExecutablePath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
  if ($actualSha256 -cne $expectedSha256) { throw "BLOCKED: candidate hash mismatch; expected $expectedSha256, found $actualSha256." }
  $reader = [IO.BinaryReader]::new([IO.File]::OpenRead($ExecutablePath))
  try { $reader.BaseStream.Position=0x3C;$peOffset=$reader.ReadInt32();$reader.BaseStream.Position=$peOffset;if($reader.ReadUInt32()-ne0x00004550){throw 'Candidate has no valid PE signature.'};$peMachine=$reader.ReadUInt16() } finally { $reader.Dispose() }
  if ($peMachine -ne 0x8664) { throw "BLOCKED: exact candidate is not AMD64 PE (0x8664); found 0x$('{0:X4}' -f $peMachine)." }
  if ($candidateInfo.VersionInfo.ProductVersion -notmatch '^1\.4\.0(\.0)?$') { throw "BLOCKED: candidate version is '$($candidateInfo.VersionInfo.ProductVersion)', not 1.4.0." }
  $candidateIdentity = [pscustomobject]@{ArtifactId=$candidateArtifactId;FinalizerRunId=$candidateRunId;SourceCommit=$candidateSourceCommit;SHA256=$actualSha256;Bytes=$candidateInfo.Length;ProductVersion=$candidateInfo.VersionInfo.ProductVersion;PEMachine=('0x{0:X4}'-f$peMachine);Execution='x64 emulation on native Windows 11 ARM64'}
  Add-Assertion 'Standalone executable matches authoritative production artifact 14695418078' $true $candidateIdentity

  if ($dataExistedBefore) { throw "BLOCKED: fresh runner profile requirement failed; existing EyeBreakReminder data is present at '$dataDirectory'." }
  if (-not $dataDirectory.StartsWith($localAppDataRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($dataDirectory)-cne'EyeBreakReminder') { throw 'BLOCKED: app-data cleanup target is not the exact LocalAppData\EyeBreakReminder folder.' }
  if (@(Get-Process -Name EyeBreakReminder -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sessionId }).Count -gt 0) { throw 'BLOCKED: a candidate process already exists in this runner session; refusing to interact with it.' }
  Add-Assertion 'Fresh runner profile has no pre-existing EyeBreakReminder app data' $true ([pscustomobject]@{Path=$dataDirectory;AbsentBeforeTest=$true})

  $notificationState=0
  $notificationStateHResult=[EBR_SHELL_NOTIFY_NATIVE]::NotificationState([ref]$notificationState)
  $notificationStateName=switch($notificationState){1{'QUNS_NOT_PRESENT'}2{'QUNS_BUSY'}3{'QUNS_RUNNING_D3D_FULL_SCREEN'}4{'QUNS_PRESENTATION_MODE'}5{'QUNS_ACCEPTS_NOTIFICATIONS'}6{'QUNS_QUIET_TIME'}7{'QUNS_APP'}default{"Unknown ($notificationState)"}}
  $shellStateRecord=[pscustomobject]@{HRESULT=('0x{0:X8}'-f([long]$notificationStateHResult-band[long]4294967295));StateCode=$notificationState;StateName=$notificationStateName;AcceptsNotifications=($notificationStateHResult-eq0-and$notificationState-eq5);ThisIsEligibilityOnlyNotDisplayEvidence=$true}
  Add-Event 'Windows Shell notification eligibility before the real timer' 'INFO' $shellStateRecord

  [void][IO.Directory]::CreateDirectory($dataDirectory)
  $dataCreatedByHarness=$true
  $settingsPath=Join-Path $dataDirectory 'settings.ini'
  $settingsText="workMinutes=1`nbreakSeconds=20`nsound=0`nvolume=0`nmode=0`nmonitor=0`ntheme=2`nalarm=0`nrepeat=0`nnotifications=1`nsnooze=0`nautoStart=1`nstartup=0`ntray=1`ntrayExplained=1`nrestore=1`npauseLocked=0`nhistory=0`nautoCheckUpdates=0`nautoDownloadUpdates=0`n"
  [IO.File]::WriteAllText($settingsPath,$settingsText,[Text.UTF8Encoding]::new($false))
  Add-Event 'Seed the fresh test profile for a real one-minute hidden-tray reminder' 'PASS' ([pscustomobject]@{SettingsPath=$settingsPath;SettingsSHA256=(Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash.ToLowerInvariant();WorkMinutes=1;BreakSeconds=20;AutoStart=$true;Notifications=$true;Alarm=$false;Tray=$true;AutoUpdateChecks=$false;TestDataOnly=$true})

  $timerStartUtc=[DateTime]::UtcNow
  $candidateProcess=Start-Process -FilePath $ExecutablePath -WorkingDirectory (Split-Path -Parent $ExecutablePath) -PassThru -ErrorAction Stop
  $candidatePid=$candidateProcess.Id;$candidateOwned=$true
  $windowWatch=[Diagnostics.Stopwatch]::StartNew()
  while($windowWatch.Elapsed.TotalSeconds-lt20-and$candidateMainWindow-eq[IntPtr]::Zero){
    $candidateProcess.Refresh();if($candidateProcess.HasExited){throw "NOT TESTED: candidate exited during startup (code $($candidateProcess.ExitCode))."}
    $candidateMainWindow=Get-CandidateWindow $candidatePid 'Eye Break Reminder'
    if($candidateMainWindow-eq[IntPtr]::Zero){Start-Sleep -Milliseconds 100}
  }
  if($candidateMainWindow-eq[IntPtr]::Zero){throw 'NOT TESTED: candidate did not create its visible main window.'}
  # Hosted Windows 11 ARM64 runners may show first-run privacy OOBE over the
  # candidate. Only the exact privacy page is permitted to advance, once, using
  # its visible Next button. All other setup pages and unknown overlays block.
  Resolve-FirstRunOobeAndVerifyCandidate $candidateMainWindow $candidatePid
  $timerStatus=Get-ControlText $candidateMainWindow 41
  $timerCountdown=Get-ControlText $candidateMainWindow 40
  Add-Assertion 'Exact candidate starts a real one-minute Work timer with notifications enabled' ($timerStatus-match'(?i)running') ([pscustomobject]@{Pid=$candidatePid;MainWindow=(Get-WindowDescription $candidateMainWindow);StatusText=$timerStatus;CountdownText=$timerCountdown;StartedUtc=$timerStartUtc.ToString('o');SettingsSHA256=(Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash.ToLowerInvariant()})
  if ($timerStatus -notmatch '(?i)running') { throw 'NOT TESTED: candidate did not report the expected running Work timer.' }

  $trayBounds=[int[]]@()
  $trayHResult=[EBR_SHELL_NOTIFY_NATIVE]::TrayIconRectangle($candidateMainWindow,1,[ref]$trayBounds)
  $trayWatch=[Diagnostics.Stopwatch]::StartNew()
  while($trayHResult-ne0-and$trayWatch.Elapsed.TotalSeconds-lt5){Start-Sleep -Milliseconds 200;$trayHResult=[EBR_SHELL_NOTIFY_NATIVE]::TrayIconRectangle($candidateMainWindow,1,[ref]$trayBounds)}
  Add-Assertion 'Candidate tray icon is registered in the real Windows Shell' ($trayHResult-eq0) ([pscustomobject]@{HResult=('0x{0:X8}'-f([long]$trayHResult-band[long]4294967295));TrayBounds=$trayBounds;Taskbar=(Get-WindowDescription $taskbar)})
  if($trayHResult-ne0){throw 'NOT TESTED: Shell_NotifyIconGetRect could not locate the candidate icon; hiding to tray would not be valid.'}

  # If startup consumed most of the minute, reset the app's real timer through
  # its visible Reset button and require a full countdown before hiding it.
  $countdownBeforeHide=Get-ControlText $candidateMainWindow 40
  if($windowWatch.Elapsed.TotalSeconds-gt20-or-not$countdownBeforeHide){
    $resetHandle=[EBR_SHELL_NOTIFY_NATIVE]::FindVisibleChildById($candidateMainWindow,21)
    if($resetHandle-eq[IntPtr]::Zero){throw 'NOT TESTED: could not reset the actual one-minute Work timer before hiding the app.'}
    $resetBounds=[EBR_SHELL_NOTIFY_NATIVE]::Bounds($resetHandle)
    $resetWidth=$resetBounds[2]-$resetBounds[0];$resetHeight=$resetBounds[3]-$resetBounds[1]
    if($resetWidth-le0-or$resetHeight-le0-or-not[EBR_SHELL_NOTIFY_NATIVE]::ClickAt([int]($resetBounds[0]+$resetWidth/2),[int]($resetBounds[1]+$resetHeight/2))){throw 'NOT TESTED: real pointer input could not reset the timer.'}
    Start-Sleep -Milliseconds 300
    $countdownBeforeHide=Get-ControlText $candidateMainWindow 40
    $timerStartUtc=[DateTime]::UtcNow
  }
  $timerRecord=[pscustomobject]@{TimerStartUtc=$timerStartUtc.ToString('o');StatusBeforeHide=Get-ControlText $candidateMainWindow 41;CountdownBeforeHide=$countdownBeforeHide;WorkMinutes=1;BreakSeconds=20;TimerWasNaturallyStarted=$true;TestFixtureResetByRealResetControl=($windowWatch.Elapsed.TotalSeconds-gt20)}

  if(-not[EBR_SHELL_NOTIFY_NATIVE]::CloseWindow($candidateMainWindow)){throw 'NOT TESTED: could not send the candidate main window close action to hide it to the tray.'}
  $hideWatch=[Diagnostics.Stopwatch]::StartNew()
  while([EBR_SHELL_NOTIFY_NATIVE]::IsWindowVisible($candidateMainWindow)-and$hideWatch.Elapsed.TotalSeconds-lt5){Start-Sleep -Milliseconds 100}
  $hidden=(-not[EBR_SHELL_NOTIFY_NATIVE]::IsWindowVisible($candidateMainWindow))
  $candidateProcess.Refresh()
  Add-Assertion 'Real candidate window hides to the Windows Shell tray while its process and timer continue' ($hidden-and-not$candidateProcess.HasExited) ([pscustomobject]@{WindowHidden=$hidden;ProcessAlive=(-not$candidateProcess.HasExited);ProcessId=$candidatePid;TrayBounds=$trayBounds;HiddenUtc=[DateTime]::UtcNow.ToString('o')})
  if(-not$hidden-or$candidateProcess.HasExited){throw 'NOT TESTED: candidate did not remain alive and hidden in the Windows Shell tray.'}

  $dueWatch=[Diagnostics.Stopwatch]::StartNew()
  while($dueWatch.Elapsed.TotalSeconds-lt90-and$candidateBreakWindow-eq[IntPtr]::Zero){
    $candidateProcess.Refresh()
    if($candidateProcess.HasExited){throw 'NOT TESTED: candidate exited before the natural one-minute reminder.'}
    $candidateBreakWindow=Get-CandidateWindow $candidatePid 'Taking an eye break'
    if($candidateBreakWindow-eq[IntPtr]::Zero){Start-Sleep -Milliseconds 200}
  }
  if($candidateBreakWindow-eq[IntPtr]::Zero){throw 'NOT TESTED: the actual one-minute Work timer did not reach a Break reminder within 90 seconds.'}
  $breakDueUtc=[DateTime]::UtcNow
  $elapsedFromStart=($breakDueUtc-$timerStartUtc).TotalSeconds
  $elapsedFromHide=$dueWatch.Elapsed.TotalSeconds
  $breakScreenshot=Capture-WindowScreenshot $candidateBreakWindow 'env-009-candidate-natural-break-window.png'
  if($breakScreenshot){$breakScreenshotPath=$breakScreenshot.Path}
  $timerRecord | Add-Member -NotePropertyName NaturalBreakDueUtc -NotePropertyValue $breakDueUtc.ToString('o') -Force
  $timerRecord | Add-Member -NotePropertyName SecondsFromTimerStart -NotePropertyValue ([Math]::Round($elapsedFromStart,2)) -Force
  $timerRecord | Add-Member -NotePropertyName SecondsFromHide -NotePropertyValue ([Math]::Round($elapsedFromHide,2)) -Force
  $timerRecord | Add-Member -NotePropertyName CandidateBreakWindow -NotePropertyValue (Get-WindowDescription $candidateBreakWindow) -Force
  $timerRecord | Add-Member -NotePropertyName BreakScreenshot -NotePropertyValue $breakScreenshot -Force
  $naturalIntervalValid=($elapsedFromStart-ge50-and$elapsedFromStart-le90)
  Add-Assertion 'One-minute candidate timer naturally opened its real Break reminder after approximately one minute' $naturalIntervalValid ([pscustomobject]@{SecondsFromTimerStart=[Math]::Round($elapsedFromStart,2);SecondsFromHide=[Math]::Round($elapsedFromHide,2);ExpectedRangeSeconds=@(50,90);BreakWindow=(Get-WindowDescription $candidateBreakWindow);Screenshot=$breakScreenshot})
  if(-not$naturalIntervalValid){throw 'NOT TESTED: natural break was not observed in the expected real one-minute timer interval.'}

  # Capture the runner desktop immediately while the Windows notification is
  # most likely visible. The screenshot is supplemental; UIA text from a Shell
  # process is mandatory for the visibility subresult.
  try { $desktopShot=Capture-InteractiveDesktop 'env-009-windows-shell-notification-desktop.png';if($desktopShot){$desktopScreenshotPath=$desktopShot.Path};Add-Event 'Capture the interactive runner desktop at the natural reminder' $(if($desktopShot){'PASS'}else{'NOT TESTED'}) $desktopShot } catch { Add-Event 'Capture the interactive runner desktop at the natural reminder' 'NOT TESTED' $_.Exception.Message }

  $firstShellSnapshot=$null
  $shellWatch=[Diagnostics.Stopwatch]::StartNew()
  while($shellWatch.Elapsed.TotalSeconds-lt12-and-not($firstShellSnapshot-and$firstShellSnapshot.SurfaceObserved)){
    $firstShellSnapshot=Get-ShellNotificationSnapshot
    if($firstShellSnapshot.SurfaceObserved){break}
    Start-Sleep -Milliseconds 750
  }
  if($firstShellSnapshot-and$firstShellSnapshot.SurfaceObserved){
    try {
      $visibleShellShot=Capture-InteractiveDesktop 'env-009-windows-shell-notification-visible.png'
      if($visibleShellShot){
        $shellNotificationScreenshotPath=$visibleShellShot.Path
        $postScreenshotSnapshot=Get-ShellNotificationSnapshot
        $sameShellWindow=Test-SameShellNotification $firstShellSnapshot $postScreenshotSnapshot
        if($sameShellWindow){Add-Event 'Capture the runner desktop after Shell UIA exposed the correlated notification and verify it remains in that Shell window' 'PASS' ([pscustomobject]@{Screenshot=$visibleShellShot;Before=$firstShellSnapshot.CorrelatedContainer;After=$postScreenshotSnapshot.CorrelatedContainer})}
        else{$shellNotificationScreenshotPath=$null;Add-Event 'Capture the runner desktop after Shell UIA exposed the notification and verify it remains visible' 'NOT TESTED' ([pscustomobject]@{Screenshot=$visibleShellShot;Before=$firstShellSnapshot.CorrelatedContainer;After=$postScreenshotSnapshot.CorrelatedContainer;Reason='The exact correlated Shell notification was no longer visible in the same window after capture.'})}
      } else {Add-Event 'Capture the runner desktop after Shell UIA exposed the notification text' 'NOT TESTED' 'No interactive desktop screenshot was returned.'}
    } catch { Add-Event 'Capture the runner desktop after Shell UIA exposed the notification text' 'NOT TESTED' $_.Exception.Message }
  }
  if($firstShellSnapshot-and$firstShellSnapshot.SurfaceObserved-and$shellNotificationScreenshotPath-and$sameShellWindow){
    $shellVisibilityStatus='PASS'
    $shellVisibilityReason='The unique actual natural reminder title and body were present in the same visible Windows Shell window, both text centers hit-tested to that window, the same RuntimeIds remained after screenshot capture, and the desktop screenshot was retained.'
    Add-Assertion 'Windows Shell UIA exposes the correlated natural reminder title/body and a post-observation desktop screenshot' $true ([pscustomobject]@{CorrelatedContainer=$firstShellSnapshot.CorrelatedContainer;Matches=$firstShellSnapshot.Matches;ShellWindows=$firstShellSnapshot.ShellWindows;Screenshot=$shellNotificationScreenshotPath})
  } elseif($firstShellSnapshot-and$firstShellSnapshot.SurfaceObserved){
    $shellVisibilityStatus='NOT TESTED'
    $shellVisibilityReason=if($shellNotificationScreenshotPath){'The screenshot was retained, but the same Shell window and title/body RuntimeIds did not remain hit-test visible through post-capture verification.'}else{'The correlated Shell UIA window was found, but a separate post-observation desktop screenshot could not be retained.'}
    Add-Assertion 'Windows Shell notification evidence retains a post-observation screenshot and the same visible notification identity' $false ([pscustomobject]@{CorrelatedContainer=$firstShellSnapshot.CorrelatedContainer;PostCaptureSnapshot=$postScreenshotSnapshot;Matches=$firstShellSnapshot.Matches;Screenshot=$shellNotificationScreenshotPath})
  } else {
    $shellVisibilityStatus='NOT TESTED'
    $shellVisibilityReason=if($shellStateRecord.AcceptsNotifications){'Windows reported QUNS_ACCEPTS_NOTIFICATIONS, but no actual Shell UIA title/body surface was observed; eligibility alone is not display evidence.'}else{"The real in-app break appeared but no Shell notification text was observed. Windows notification state was $($shellStateRecord.StateName), so suppression versus Shell delivery/display remains unproven."}
    Add-Assertion 'Windows Shell UIA exposes the actual natural reminder title and body outside the candidate process' $false ([pscustomobject]@{NotificationState=$shellStateRecord;BreakWindow=(Get-WindowDescription $candidateBreakWindow);Snapshot=[pscustomobject]@{Utc=$firstShellSnapshot.Utc;SurfaceObserved=$firstShellSnapshot.SurfaceObserved;TitleObserved=$firstShellSnapshot.TitleObserved;BodyObserved=$firstShellSnapshot.BodyObserved;Matches=$firstShellSnapshot.Matches;ShellWindows=$firstShellSnapshot.ShellWindows;Error=$firstShellSnapshot.Error}})
  }
  if($firstShellSnapshot){Add-Event 'First Windows Shell notification UIA snapshot' $(if($firstShellSnapshot.SurfaceObserved){'PASS'}else{'NOT TESTED'}) ([pscustomobject]@{Utc=$firstShellSnapshot.Utc;TitleObserved=$firstShellSnapshot.TitleObserved;BodyObserved=$firstShellSnapshot.BodyObserved;CorrelatedContainer=$firstShellSnapshot.CorrelatedContainer;CorrelationFailure=$firstShellSnapshot.CorrelationFailure;Matches=$firstShellSnapshot.Matches;ShellWindows=$firstShellSnapshot.ShellWindows;Error=$firstShellSnapshot.Error})}

  if($firstShellSnapshot-and$firstShellSnapshot.SurfaceObserved){
    $persistenceWatch=[Diagnostics.Stopwatch]::StartNew();$persisted=$false;$identityChecks=[System.Collections.Generic.List[object]]::new()
    while($persistenceWatch.Elapsed.TotalSeconds-lt5){Start-Sleep -Milliseconds 500;$latest=Get-ShellNotificationSnapshot;$same=Test-SameShellNotification $firstShellSnapshot $latest;$identityChecks.Add([pscustomobject]@{Utc=$latest.Utc;SameNotificationIdentity=$same;CorrelatedContainer=$latest.CorrelatedContainer});if($same){$persisted=$true}else{break}}
    $persistenceRecord=[pscustomobject]@{Status=if($persisted){'OBSERVED'}else{'NOT OBSERVED'};ObservedForSeconds=[Math]::Round($persistenceWatch.Elapsed.TotalSeconds,2);SameNotificationIdentityChecks=$identityChecks.ToArray();Reason=if($persisted){'The same Shell window, title RuntimeId and body RuntimeId remained hit-test visible throughout the observation interval.'}else{'The original Shell notification identity was not preserved through the full observation interval.'}}
    Add-Event 'Observe real Shell notification persistence without simulating time' $(if($persisted){'PASS'}else{'NOT TESTED'}) $persistenceRecord
    $activationRecord=Try-InvokeShellNotification $firstShellSnapshot $candidateMainWindow
    Add-Event 'Attempt activation only through an exposed Windows Shell notification InvokePattern' $activationRecord.Status $activationRecord
    if($activationRecord.Status-eq'PASS'){
      Add-Assertion 'Actual Shell notification activation makes the hidden candidate main window visible' $true $activationRecord
    }else{
      $dismissalRecord=Try-DismissShellNotification $firstShellSnapshot
      Add-Event 'Attempt dismissal only through an exposed notification-scoped Dismiss/Close control' $dismissalRecord.Status $dismissalRecord
    }
  }

  $audioRecord=[pscustomobject]@{Status='NOT TESTED';PhysicalAudioVerified=$false;NotificationSoundExpected=$false;Reason='Candidate notifications use NIIF_NOSOUND|NIIF_RESPECT_QUIET_TIME. Alarm was disabled and no audio capture/physical output was tested.'}
  $status='BLOCKED'
  $reason=if($shellVisibilityStatus-eq'PASS'){'Windows Shell notification visibility subtest passed, but ENV-009 remains BLOCKED because the original requirement also includes audio and physical endpoint/audibility was not verified.'}else{'ENV-009 remains BLOCKED: actual Windows Shell notification display was not established, and audio was also unverified.'}
  Add-Event 'ENV-009 aggregate acceptance status' 'BLOCKED' ([pscustomobject]@{ShellNotificationVisibility=$shellVisibilityStatus;NotificationAudio='NOT TESTED';PhysicalAudioVerified=$false;Reason=$reason})
} catch {
  $errorMessage=$_.Exception.Message
  if($errorMessage-match'^(BLOCKED|NOT TESTED):'){$status=if($errorMessage.StartsWith('BLOCKED:')){'BLOCKED'}else{'NOT TESTED'};$reason=$errorMessage}else{$status='NOT TESTED';$reason="The actual Windows Shell notification test did not complete: $errorMessage"}
  if($shellVisibilityStatus-eq'PASS'){$status='BLOCKED';$reason="Shell visibility was separately observed, but the ENV-009 aggregate remains blocked: $errorMessage"}
  Add-Event 'ENV-009 harness attempt' $status ([pscustomobject]@{Message=$errorMessage;StackTrace=$_.ScriptStackTrace})
} finally {
  if($candidateOwned-and$candidatePid-gt0){
    try{
      $owned=Get-Process -Id $candidatePid -ErrorAction SilentlyContinue
      if($owned){
        $ownedPath='';try{$ownedPath=[IO.Path]::GetFullPath($owned.Path)}catch{}
        if($ownedPath-ieq$ExecutablePath){
          if($candidateMainWindow-ne[IntPtr]::Zero){[void][EBR_SHELL_NOTIFY_NATIVE]::ExitOwnedApp($candidateMainWindow)}
          if(-not$owned.WaitForExit(5000)){Stop-Process -Id $candidatePid -Force -ErrorAction Stop;$owned.WaitForExit(5000)|Out-Null}
          $candidateStopped=$true
          Add-Event 'Stop only the exact standalone candidate process started by this harness' 'PASS' ([pscustomobject]@{ProcessId=$candidatePid;Path=$ownedPath})
        }else{$cleanupErrors.Add("Candidate PID $candidatePid no longer resolves to the exact candidate; it was not stopped.")}
      }else{$candidateStopped=$true}
    }catch{$cleanupErrors.Add("Candidate process cleanup: $($_.Exception.Message)")}
  }
  if($dataCreatedByHarness-and-not$dataExistedBefore-and(Test-Path -LiteralPath $dataDirectory)){
    try{
      $resolvedData=[IO.Path]::GetFullPath($dataDirectory)
      if(-not$resolvedData.StartsWith($localAppDataRoot,[StringComparison]::OrdinalIgnoreCase)-or[IO.Path]::GetFileName($resolvedData)-cne'EyeBreakReminder'){throw "Refusing cleanup outside the exact test profile folder: $resolvedData"}
      if(([IO.File]::GetAttributes($resolvedData)-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'Refusing to recurse into an app-data reparse point.'}
      $reparseChildren=@(Get-ChildItem -LiteralPath $resolvedData -Force -Recurse -ErrorAction Stop|Where-Object{($_.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0})
      if($reparseChildren.Count){throw 'Refusing to recurse into a reparse point created inside the app-data test folder.'}
      Remove-Item -LiteralPath $resolvedData -Recurse -Force -ErrorAction Stop
      $dataRemoved=-not(Test-Path -LiteralPath $resolvedData)
      if(-not$dataRemoved){throw 'Fresh test app-data directory remains after cleanup.'}
      Add-Event 'Remove only the fresh app-data directory created by this harness' 'PASS' ([pscustomobject]@{Path=$resolvedData;Removed=$true})
    }catch{$cleanupErrors.Add("App-data cleanup: $($_.Exception.Message)")}
  }
  if($scriptTranscriptStarted){try{Stop-Transcript|Out-Null}catch{$cleanupErrors.Add("Transcript close: $($_.Exception.Message)")}}
}

if($status-eq'PASS'){$status='BLOCKED';$reason='ENV-009 is a grouped audio and Shell requirement; notification visibility alone cannot mark the aggregate PASS.'}
if($cleanupErrors.Count-gt0-and$status-eq'PASS'){$status='BLOCKED';$reason+=' Cleanup did not complete cleanly.'}
try{
  $result=Save-Result $status $reason
  $result|ConvertTo-Json -Depth 14
  Write-Host "ENV-009 Shell notification attempt: $status — $reason"
}catch{throw "Could not save ENV-009 evidence: $($_.Exception.Message)"}
