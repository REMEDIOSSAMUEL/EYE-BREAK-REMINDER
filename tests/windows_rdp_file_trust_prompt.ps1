function Resolve-EBRTestRdpFileTrustPrompt {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][int]$MstscProcessId,
    [Parameter(Mandatory)][string]$RdpFilePath,
    [Parameter(Mandatory)][string]$EvidenceDirectory,
    [switch]$AllowAudioPlayback,
    [int]$TimeoutSeconds = 20
  )

  $ErrorActionPreference = 'Stop'
  $RdpFilePath = [IO.Path]::GetFullPath($RdpFilePath)
  $EvidenceDirectory = [IO.Path]::GetFullPath($EvidenceDirectory)
  if (-not (Test-Path -LiteralPath $RdpFilePath -PathType Leaf)) {
    throw 'BLOCKED: the owned RDP client launch has no generated RDP file.'
  }
  $rdpText = Get-Content -LiteralPath $RdpFilePath -Raw
  $addresses = [regex]::Matches($rdpText, '(?im)^[ \t]*full address:s:([^\r\n]*?)[ \t]*\r?$')
  if ($addresses.Count -ne 1 -or $addresses[0].Groups[1].Value -cne '127.0.0.1:3389') {
    throw 'BLOCKED: refusing RDP prompts unless the generated file has exactly one full-address field targeting 127.0.0.1:3389.'
  }

  function Assert-EBRRdpSetting([string]$Key, [string]$ExpectedValue) {
    $settingMatches = [regex]::Matches($rdpText, '(?im)^[ \t]*' + [regex]::Escape($Key) + ':([^\r\n]*?)[ \t]*\r?$')
    if ($settingMatches.Count -ne 1 -or $settingMatches[0].Groups[1].Value -cne $ExpectedValue) {
      throw "BLOCKED: RDP setting '$Key' is missing, duplicated, or differs from the approved test value."
    }
  }
  Assert-EBRRdpSetting 'redirectclipboard:i' '0'
  Assert-EBRRdpSetting 'redirectprinters:i' '0'
  Assert-EBRRdpSetting 'drivestoredirect:s' ''
  Assert-EBRRdpSetting 'redirectsmartcards:i' '0'
  Assert-EBRRdpSetting 'redirectcomports:i' '0'
  Assert-EBRRdpSetting 'redirectlocation:i' '0'
  Assert-EBRRdpSetting 'redirectposdevices:i' '0'
  Assert-EBRRdpSetting 'redirectwebauthn:i' '0'
  Assert-EBRRdpSetting 'devicestoredirect:s' ''
  Assert-EBRRdpSetting 'usbdevicestoredirect:s' ''
  Assert-EBRRdpSetting 'camerastoredirect:s' ''
  Assert-EBRRdpSetting 'audiocapturemode:i' '0'
  if ($AllowAudioPlayback) { Assert-EBRRdpSetting 'audiomode:i' '0' }
  else { Assert-EBRRdpSetting 'audiomode:i' '2' }
  $allowedRedirectKeys = @('redirectclipboard', 'redirectprinters', 'drivestoredirect', 'redirectsmartcards', 'redirectcomports', 'redirectlocation', 'redirectposdevices', 'redirectwebauthn', 'devicestoredirect', 'usbdevicestoredirect', 'camerastoredirect')
  foreach ($line in ($rdpText -split '\r?\n')) {
    if ($line -match '^[ \t]*([^:]*redirect[^:]*):') {
      if ($Matches[1] -cnotin $allowedRedirectKeys) {
        throw "BLOCKED: unreviewed RDP redirection directive '$($Matches[1])' is present."
      }
    }
  }

  $client = Get-Process -Id $MstscProcessId -ErrorAction Stop
  if ($client.ProcessName -cne 'mstsc') {
    throw "BLOCKED: RDP prompt process identity is '$($client.ProcessName)', not mstsc."
  }
  Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
  Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop

  $educationCheckboxName = 'I understand and allow RDP files to open on this device for my account'
  $educationHeading = 'Opening Remote Desktop Connection'
  $desktop = [System.Windows.Automation.AutomationElement]::RootElement
  $trueCondition = [System.Windows.Automation.Condition]::TrueCondition
  $educationAcknowledged = $false
  $connectionAcknowledged = $false
  $audioPlaybackAuthorized = $false
  $promptActionMethods = [System.Collections.Generic.List[string]]::new()
  $watch = [Diagnostics.Stopwatch]::StartNew()

  function Get-EBROwnedRdpWindows {
    $found = [System.Collections.Generic.List[System.Windows.Automation.AutomationElement]]::new()
    $windows = $desktop.FindAll([System.Windows.Automation.TreeScope]::Children, $trueCondition)
    foreach ($window in $windows) {
      try {
        $current = $window.Current
        if ($current.ControlType -eq [System.Windows.Automation.ControlType]::Window -and
            $current.ProcessId -eq $MstscProcessId -and $current.NativeWindowHandle -ne 0 -and
            -not $current.IsOffscreen -and $current.Name -ceq 'Remote Desktop Connection') {
          $found.Add($window)
        }
      } catch { }
    }
    return $found.ToArray()
  }

  function Get-EBRPromptSnapshot($Window) {
    $nodes = $Window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $trueCondition)
    $tree = @(
      foreach ($node in $nodes) {
        try {
          $current = $node.Current
          [pscustomobject]@{
            Name = [string]$current.Name
            ControlType = [string]$current.ControlType.ProgrammaticName
            AutomationId = [string]$current.AutomationId
            ProcessId = [int]$current.ProcessId
            Enabled = [bool]$current.IsEnabled
            Offscreen = [bool]$current.IsOffscreen
            Bounds = @([double]$current.BoundingRectangle.Left, [double]$current.BoundingRectangle.Top, [double]$current.BoundingRectangle.Width, [double]$current.BoundingRectangle.Height)
          }
        } catch { }
      }
    )
    $names = @($tree | ForEach-Object { [string]$_.Name })
    [pscustomobject]@{
      Window = $Window
      Handle = [long]$Window.Current.NativeWindowHandle
      Tree = $tree
      Nodes = $nodes
      JoinedNames = $names -join [Environment]::NewLine
    }
  }

  function Get-EBRNamedPromptActions($Nodes, [string]$Name, [string]$AutomationId = '') {
    $actions = [System.Collections.Generic.List[System.Windows.Automation.AutomationElement]]::new()
    foreach ($node in $Nodes) {
      try {
        $current = $node.Current
        $isActionControl = $current.ControlType -eq [System.Windows.Automation.ControlType]::Button -or
          $current.ControlType -eq [System.Windows.Automation.ControlType]::Pane
        $automationIdMatches = [string]::IsNullOrEmpty($AutomationId) -or $current.AutomationId -ceq $AutomationId
        if ($isActionControl -and $current.Name -ceq $Name -and $automationIdMatches -and -not $current.IsOffscreen) { $actions.Add($node) }
      } catch { }
    }
    return $actions.ToArray()
  }

  function Invoke-EBRNamedPromptAction($Element, [string]$Name) {
    $current = $Element.Current
    $isActionControl = $current.ControlType -eq [System.Windows.Automation.ControlType]::Button -or
      $current.ControlType -eq [System.Windows.Automation.ControlType]::Pane
    if (-not $isActionControl -or $current.Name -cne $Name -or -not $current.IsEnabled -or $current.IsOffscreen) {
      throw "BLOCKED: refusing to invoke an unverified '$Name' RDP prompt action."
    }

    $pattern = $null
    if ($Element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) {
      ([System.Windows.Automation.InvokePattern]$pattern).Invoke()
      return 'InvokePattern'
    }
    $legacyPattern = $null
    if ($Element.TryGetCurrentPattern([System.Windows.Automation.LegacyIAccessiblePattern]::Pattern, [ref]$legacyPattern)) {
      $legacy = [System.Windows.Automation.LegacyIAccessiblePattern]$legacyPattern
      $legacyCurrent = $legacy.Current
      $pushButtonRole = 43 # ROLE_SYSTEM_PUSHBUTTON from oleacc.h
      if ([int]$legacyCurrent.Role -ne $pushButtonRole -or [string]::IsNullOrWhiteSpace([string]$legacyCurrent.DefaultAction)) {
        throw "BLOCKED: the exact '$Name' control's legacy action is not a verified push button with a default action."
      }
      $legacy.DoDefaultAction()
      return "LegacyIAccessiblePattern(role=$pushButtonRole; defaultAction=$([string]$legacyCurrent.DefaultAction))"
    }
    throw "BLOCKED: the exact '$Name' RDP prompt action exposed neither Invoke nor LegacyIAccessible action support."
  }

  function Save-EBRPromptEvidence($Snapshot, [string]$BaseName, $Extra = $null) {
    [void][IO.Directory]::CreateDirectory($EvidenceDirectory)
    $record = [pscustomobject]@{
      WindowTitle = 'Remote Desktop Connection'
      ProcessId = $MstscProcessId
      RdpFile = $RdpFilePath
      Target = '127.0.0.1:3389'
      AllowAudioPlayback = [bool]$AllowAudioPlayback
      Controls = $Snapshot.Tree
      State = $Extra
      CapturedUtc = [DateTime]::UtcNow.ToString('o')
    }
    $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $EvidenceDirectory ($BaseName + '.uia.json')) -Encoding UTF8
    try {
      Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
      Add-Type -AssemblyName System.Drawing -ErrorAction Stop
      $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
      if ($bounds.Width -gt 0 -and $bounds.Height -gt 0) {
        $bitmap = [Drawing.Bitmap]::new($bounds.Width, $bounds.Height)
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        try {
          $graphics.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bitmap.Size)
          $bitmap.Save((Join-Path $EvidenceDirectory ($BaseName + '.png')), [Drawing.Imaging.ImageFormat]::Png)
        } finally { $graphics.Dispose(); $bitmap.Dispose() }
      }
    } catch { }
  }

  while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
    $ownedWindows = @(Get-EBROwnedRdpWindows)
    if ($ownedWindows.Count -gt 1) {
      throw "BLOCKED: found $($ownedWindows.Count) owned Remote Desktop Connection windows; no prompt was acknowledged."
    }
    if ($ownedWindows.Count -eq 1) {
      $snapshot = Get-EBRPromptSnapshot $ownedWindows[0]
      $names = $snapshot.JoinedNames
      $nodes = $snapshot.Nodes

      $educationCheckboxes = @(
        foreach ($node in $nodes) {
          try {
            $current = $node.Current
            if ($current.ControlType -eq [System.Windows.Automation.ControlType]::CheckBox -and
                $current.Name -ceq $educationCheckboxName -and $current.IsEnabled -and -not $current.IsOffscreen) { $node }
          } catch { }
        }
      )
      if ($names -match '(?is)You\s+are\s+opening\s+an\s+RDP\s+file\s+which\s+will\s+establish\s+a\s+connection\s+to\s+another\s+computer' -and
          $names -match [regex]::Escape($educationHeading) -and $educationCheckboxes.Count -eq 1) {
        $okButtons = @(Get-EBRNamedPromptActions $nodes 'OK' 'CommandButton_1')
        $cancelButtons = @(Get-EBRNamedPromptActions $nodes 'Cancel' 'CommandButton_2' | Where-Object { $_.Current.IsEnabled })
        if ($okButtons.Count -ne 1 -or $cancelButtons.Count -ne 1) {
          Save-EBRPromptEvidence $snapshot 'rdp-file-education-prompt-unrecognized'
          throw 'BLOCKED: the exact educational RDP-file prompt did not expose unique OK and Cancel actions.'
        }
        $checkbox = $educationCheckboxes[0]
        $toggle = [System.Windows.Automation.TogglePattern]$checkbox.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
        $before = [string]$toggle.Current.ToggleState
        if ($before -eq [string][System.Windows.Automation.ToggleState]::Off) { $toggle.Toggle() }
        $after = [string]$toggle.Current.ToggleState
        if ($after -ne [string][System.Windows.Automation.ToggleState]::On -or -not $okButtons[0].Current.IsEnabled) {
          throw 'BLOCKED: the exact per-account RDP-file acknowledgement did not enable its unique OK action.'
        }
        Save-EBRPromptEvidence $snapshot 'rdp-file-education-prompt-before-acknowledgement' ([pscustomobject]@{Checkbox=$educationCheckboxName;Before=$before;After=$after;Action='OK'})
        $handle = $snapshot.Handle
        $actionPattern = Invoke-EBRNamedPromptAction $okButtons[0] 'OK'
        $promptActionMethods.Add("Education OK: $actionPattern")
        $educationAcknowledged = $true
        $closeWatch = [Diagnostics.Stopwatch]::StartNew()
        do {
          Start-Sleep -Milliseconds 100
          $stillOpen = @($desktop.FindAll([System.Windows.Automation.TreeScope]::Children, $trueCondition) | Where-Object { try { [long]$_.Current.NativeWindowHandle -eq $handle } catch { $false } }).Count -gt 0
        } while ($stillOpen -and $closeWatch.Elapsed.TotalSeconds -lt 8)
        if ($stillOpen) { throw 'BLOCKED: the exact RDP-file education prompt remained open after acknowledgement.' }
        Save-EBRPromptEvidence $snapshot 'rdp-file-education-prompt-acknowledged' ([pscustomobject]@{Checkbox=$educationCheckboxName;Before=$before;After=$after;Action='OK';ActionPattern=$actionPattern;PromptClosed=$true})
        continue
      }

      $isUnknownConnectionWarning = $names -match '(?i)Caution:\s*Unknown remote connection' -and
        $names -match '(?i)Unknown publisher' -and $names -match '(?<![A-Za-z0-9.])127\.0\.0\.1(?::3389)?(?!\d|:)'
      if ($isUnknownConnectionWarning) {
        $checkboxes = @(
          foreach ($node in $nodes) {
            try { $current = $node.Current; if ($current.ControlType -eq [System.Windows.Automation.ControlType]::CheckBox -and -not $current.IsOffscreen) { $node } } catch { }
          }
        )
        $connectButtons = @(Get-EBRNamedPromptActions $nodes 'Connect')
        $cancelButtons = @(Get-EBRNamedPromptActions $nodes 'Cancel' | Where-Object { $_.Current.IsEnabled })
        if ($checkboxes.Count -eq 0 -or $connectButtons.Count -ne 1 -or $cancelButtons.Count -ne 1) {
          Save-EBRPromptEvidence $snapshot 'rdp-connection-security-prompt-unrecognized'
          throw 'BLOCKED: the exact localhost connection warning lacked uniquely verifiable resource controls or Connect/Cancel actions.'
        }
        $statesBefore = [System.Collections.Generic.List[object]]::new()
        $audioNodes = [System.Collections.Generic.List[System.Windows.Automation.AutomationElement]]::new()
        foreach ($node in $checkboxes) {
          try {
            $current = $node.Current
            $toggle = [System.Windows.Automation.TogglePattern]$node.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
            $state = [string]$toggle.Current.ToggleState
            $statesBefore.Add([pscustomobject]@{Name=[string]$current.Name;State=$state})
            if ($current.Name -ceq 'Audio playback') { $audioNodes.Add($node) }
          } catch {
            Save-EBRPromptEvidence $snapshot 'rdp-connection-security-prompt-unreadable'
            throw 'BLOCKED: one or more localhost connection resource checkboxes could not be read safely.'
          }
        }
        if ($AllowAudioPlayback -and $audioNodes.Count -ne 1) {
          Save-EBRPromptEvidence $snapshot 'rdp-connection-security-prompt-audio-unrecognized' ([pscustomobject]@{CheckboxStates=@($statesBefore)})
          throw 'BLOCKED: audio playback was requested, but exactly one UI Automation checkbox named Audio playback was not present.'
        }
        if (-not $AllowAudioPlayback -and $audioNodes.Count -gt 1) {
          Save-EBRPromptEvidence $snapshot 'rdp-connection-security-prompt-audio-ambiguous' ([pscustomobject]@{CheckboxStates=@($statesBefore)})
          throw 'BLOCKED: the disabled-audio test exposed ambiguous audio resource controls.'
        }
        foreach ($item in $statesBefore) {
          if ($item.Name -ceq 'Audio playback' -and $AllowAudioPlayback) { continue }
          if ($item.State -ne [string][System.Windows.Automation.ToggleState]::Off) {
            Save-EBRPromptEvidence $snapshot 'rdp-connection-security-prompt-resource-already-enabled' ([pscustomobject]@{CheckboxStates=@($statesBefore)})
            throw "BLOCKED: unexpected RDP redirection '$($item.Name)' was already enabled; no resource was accepted."
          }
        }
        Save-EBRPromptEvidence $snapshot 'rdp-connection-security-prompt-before-acknowledgement' ([pscustomobject]@{CheckboxStates=@($statesBefore);AudioPlaybackRequested=[bool]$AllowAudioPlayback})
        $audioState = $null
        if ($AllowAudioPlayback) {
          $audioNode = $audioNodes[0]
          $audioToggle = [System.Windows.Automation.TogglePattern]$audioNode.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
          if ([string]$audioToggle.Current.ToggleState -eq [string][System.Windows.Automation.ToggleState]::Off) { $audioToggle.Toggle() }
          $audioState = [string]$audioToggle.Current.ToggleState
          if ($audioState -ne [string][System.Windows.Automation.ToggleState]::On) {
            throw 'BLOCKED: the exact Audio playback resource could not be enabled for the disposable test client.'
          }
          $audioPlaybackAuthorized = $true
        }
        if (-not $connectButtons[0].Current.IsEnabled) { throw 'BLOCKED: the exact localhost Connect action is disabled.' }
        $buttonHandle = $snapshot.Handle
        $actionPattern = Invoke-EBRNamedPromptAction $connectButtons[0] 'Connect'
        $promptActionMethods.Add("Connection Connect: $actionPattern")
        $connectionAcknowledged = $true
        $closeWatch = [Diagnostics.Stopwatch]::StartNew()
        $stillOpen = $true
        while ($stillOpen -and $closeWatch.Elapsed.TotalSeconds -lt 8) {
          Start-Sleep -Milliseconds 100
          $sameHandleWindow = $null
          foreach ($candidateWindow in $desktop.FindAll([System.Windows.Automation.TreeScope]::Children, $trueCondition)) {
            try {
              if ([long]$candidateWindow.Current.NativeWindowHandle -eq $buttonHandle -and $candidateWindow.Current.ProcessId -eq $MstscProcessId) {
                $sameHandleWindow = $candidateWindow
                break
              }
            } catch { }
          }
          $stillOpen = $null -ne $sameHandleWindow
          if ($stillOpen) {
            $changed = Get-EBRPromptSnapshot $sameHandleWindow
            if ($changed.JoinedNames -match '(?i)(identity of the remote computer|server certificate|certificate warning|authentication of the server)') {
              Save-EBRPromptEvidence $changed 'rdp-server-certificate-warning-unaccepted'
              throw 'BLOCKED: an RDP server certificate/identity warning appeared; it was captured and no certificate trust action was taken.'
            }
            if ($changed.JoinedNames -notmatch '(?i)Caution:\s*Unknown remote connection') {
              Save-EBRPromptEvidence $changed 'rdp-post-connect-warning-unrecognized'
              $stillOpen = $false
            }
          }
        }
        if ($stillOpen) {
          Save-EBRPromptEvidence $snapshot 'rdp-connection-security-prompt-did-not-close' ([pscustomobject]@{CheckboxStatesBefore=@($statesBefore);AudioPlaybackAfter=$audioState})
          throw 'BLOCKED: the exact localhost connection security dialog remained open after the scoped action.'
        }
        $after = [pscustomobject]@{CheckboxStatesBefore=@($statesBefore);AudioPlaybackAfter=$audioState;ConnectInvoked=$true;ActionPattern=$actionPattern;AudioOnlyWhenRequested=[bool]$AllowAudioPlayback}
        Save-EBRPromptEvidence $snapshot 'rdp-connection-security-prompt-after-scoped-selection' $after
        $postWatch = [Diagnostics.Stopwatch]::StartNew()
        while ($postWatch.Elapsed.TotalSeconds -lt 20) {
          foreach ($possible in @(Get-EBROwnedRdpWindows)) {
            $post = Get-EBRPromptSnapshot $possible
            if ($post.JoinedNames -match '(?i)(identity of the remote computer|server certificate|certificate warning|authentication of the server)') {
              Save-EBRPromptEvidence $post 'rdp-server-certificate-warning-unaccepted'
              throw 'BLOCKED: an RDP server certificate/identity warning appeared; it was captured and no certificate trust action was taken.'
            }
          }
          Start-Sleep -Milliseconds 100
        }
        return [pscustomobject]@{
          Status = 'ACKNOWLEDGED'
          ProcessId = $MstscProcessId
          ProcessName = $client.ProcessName
          RdpFile = $RdpFilePath
          Target = '127.0.0.1:3389'
          EducationalPromptAcknowledged = $educationAcknowledged
          ConnectionSecurityAcknowledged = $connectionAcknowledged
          PromptActionMethods = @($promptActionMethods.ToArray())
          AudioPlaybackRequested = [bool]$AllowAudioPlayback
          AudioPlaybackAuthorized = $audioPlaybackAuthorized
          ResourceRedirections = 'All visible resource checkboxes remained off except the exact Audio playback checkbox when explicitly requested by the RDP file and caller.'
          CertificatePromptAccepted = $false
          Scope = 'Ephemeral GitHub-hosted runner profile; the only connection target is the runner itself at 127.0.0.1:3389.'
        }
      }

      if ($names -match '(?i)(identity of the remote computer|server certificate|certificate warning|authentication of the server)') {
        Save-EBRPromptEvidence $snapshot 'rdp-server-certificate-warning-unaccepted'
        throw 'BLOCKED: an RDP server certificate/identity warning appeared; it was captured and no certificate trust action was taken.'
      }
      if ($names -match '(?i)(Caution: Unknown remote connection|Unknown publisher|opening an RDP file)') {
        Save-EBRPromptEvidence $snapshot 'rdp-prompt-unrecognized'
        throw 'BLOCKED: an RDP warning did not match an exact reviewed localhost prompt; no control was invoked.'
      }
    }
    Start-Sleep -Milliseconds 100
  }

  if ($educationAcknowledged -or $connectionAcknowledged) {
    return [pscustomobject]@{
      Status = 'ACKNOWLEDGED'
      ProcessId = $MstscProcessId
      ProcessName = $client.ProcessName
      RdpFile = $RdpFilePath
      Target = '127.0.0.1:3389'
      EducationalPromptAcknowledged = $educationAcknowledged
      ConnectionSecurityAcknowledged = $connectionAcknowledged
      PromptActionMethods = @($promptActionMethods.ToArray())
      AudioPlaybackRequested = [bool]$AllowAudioPlayback
      AudioPlaybackAuthorized = $audioPlaybackAuthorized
      CertificatePromptAccepted = $false
      Note = 'Only reviewed RDP-file prompts appeared before the timeout; no certificate warning was accepted.'
    }
  }
  return [pscustomobject]@{Status='NOT PRESENT';ProcessId=$MstscProcessId;ProcessName=$client.ProcessName;RdpFile=$RdpFilePath;Target='127.0.0.1:3389';ObservedSeconds=[Math]::Round($watch.Elapsed.TotalSeconds,2);AudioPlaybackRequested=[bool]$AllowAudioPlayback}
}
