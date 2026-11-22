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
  $rdpFileSHA256 = (Get-FileHash -LiteralPath $RdpFilePath -Algorithm SHA256).Hash.ToLowerInvariant()
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
  if ($null -eq ('EBR_RdpUiNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class EBR_RdpUiNative {
  [DllImport("user32.dll", SetLastError = true)]
  [return: MarshalAs(UnmanagedType.Bool)]
  public static extern bool IsChild(IntPtr parent, IntPtr child);

  [DllImport("user32.dll", SetLastError = true)]
  [return: MarshalAs(UnmanagedType.Bool)]
  public static extern bool IsWindowVisible(IntPtr hWnd);

  [DllImport("user32.dll", SetLastError = true)]
  [return: MarshalAs(UnmanagedType.Bool)]
  public static extern bool IsWindowEnabled(IntPtr hWnd);

  [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
  public static extern int GetClassName(IntPtr hWnd, StringBuilder className, int maxCount);

  [DllImport("user32.dll", SetLastError = true)]
  public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

  [DllImport("user32.dll")]
  public static extern IntPtr GetForegroundWindow();

  [DllImport("user32.dll", SetLastError = true)]
  public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam, uint flags, uint timeoutMilliseconds, out IntPtr result);

  [DllImport("oleacc.dll", ExactSpelling = true)]
  private static extern int AccessibleObjectFromWindow(IntPtr hWnd, uint objectId, ref Guid interfaceId, [MarshalAs(UnmanagedType.Interface)] out object accessibleObject);

  public static object GetAccessibleClient(IntPtr hWnd) {
    Guid interfaceId = new Guid("618736E0-3C3D-11CF-810C-00AA00389B71");
    object accessibleObject;
    int hr = AccessibleObjectFromWindow(hWnd, 0xFFFFFFFCu, ref interfaceId, out accessibleObject);
    Marshal.ThrowExceptionForHR(hr);
    if (accessibleObject == null) throw new InvalidOperationException("OBJID_CLIENT returned no IAccessible object.");
    return accessibleObject;
  }
}
'@ -ErrorAction Stop
  }

  $educationCheckboxName = 'I understand and allow RDP files to open on this device for my account'
  $educationHeading = 'Opening Remote Desktop Connection'
  $desktop = [System.Windows.Automation.AutomationElement]::RootElement
  $trueCondition = [System.Windows.Automation.Condition]::TrueCondition
  $educationAcknowledged = $false
  $connectionAcknowledged = $false
  $audioPlaybackAuthorized = $false
  $serverCertificateAccepted = $false
  $serverCertificateIdentity = $null
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
            -not $current.IsOffscreen -and $current.Name -cin @('Remote Desktop Connection','Remote Desktop Connection security warning')) {
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
          $value = ''
          try {
            $valuePattern = $null
            if ($node.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$valuePattern)) {
              $value = [string]([System.Windows.Automation.ValuePattern]$valuePattern).Current.Value
            }
          } catch { }
          [pscustomobject]@{
            Name = [string]$current.Name
            Value = $value
            ControlType = [string]$current.ControlType.ProgrammaticName
            AutomationId = [string]$current.AutomationId
            ProcessId = [int]$current.ProcessId
            NativeWindowHandle = [long]$current.NativeWindowHandle
            ClassName = [string]$current.ClassName
            Enabled = [bool]$current.IsEnabled
            Offscreen = [bool]$current.IsOffscreen
            Bounds = @([double]$current.BoundingRectangle.Left, [double]$current.BoundingRectangle.Top, [double]$current.BoundingRectangle.Width, [double]$current.BoundingRectangle.Height)
          }
        } catch { }
      }
    )
    $names = @($tree | ForEach-Object { [string]$_.Name; if (-not [string]::IsNullOrWhiteSpace([string]$_.Value)) { [string]$_.Value } })
    [pscustomobject]@{
      Window = $Window
      Handle = [long]$Window.Current.NativeWindowHandle
      Tree = $tree
      Nodes = $nodes
      JoinedNames = $names -join [Environment]::NewLine
    }
  }

  function Get-EBRNestedCertificateViewerWindows($WarningSnapshot) {
    $matches = [System.Collections.Generic.List[System.Windows.Automation.AutomationElement]]::new()
    foreach ($node in $WarningSnapshot.Nodes) {
      try {
        $current = $node.Current
        if ($current.ControlType -eq [System.Windows.Automation.ControlType]::Window -and
            $current.Name -ceq 'Certificate' -and $current.ProcessId -eq $MstscProcessId) {
          $matches.Add($node)
        }
      } catch { }
    }
    return $matches.ToArray()
  }

  function Test-EBRUnknownConnectionWarning([string]$JoinedNames) {
    $warningTextObserved = $JoinedNames -match '(?i)(Caution:\s*Unknown remote connection|We could not verify the publisher of this remote connection)'
    $unknownPublisherObserved = $JoinedNames -match '(?i)Unknown publisher'
    $loopbackTargetObserved = $JoinedNames -match '(?<![A-Za-z0-9.])127\.0\.0\.1(?::3389)?(?!\d|:)'
    return ($warningTextObserved -and $unknownPublisherObserved -and $loopbackTargetObserved)
  }

  function Get-EBRNamedPromptActions($Nodes, [string]$Name, [string]$AutomationId, [int]$ProcessId) {
    $actions = [System.Collections.Generic.List[System.Windows.Automation.AutomationElement]]::new()
    foreach ($node in $Nodes) {
      try {
        $current = $node.Current
        $isActionControl = $current.ControlType -eq [System.Windows.Automation.ControlType]::Button -or
          $current.ControlType -eq [System.Windows.Automation.ControlType]::Pane -or
          $current.ControlType -eq [System.Windows.Automation.ControlType]::Hyperlink
        $automationIdMatches = [string]::IsNullOrEmpty($AutomationId) -or $current.AutomationId -ceq $AutomationId
        if ($isActionControl -and $current.ProcessId -eq $ProcessId -and $current.Name -ceq $Name -and $automationIdMatches -and -not $current.IsOffscreen) { $actions.Add($node) }
      } catch { }
    }
    return $actions.ToArray()
  }

  function Invoke-EBRNamedPromptAction($Element, [string]$Name, [int]$ExpectedProcessId, [long]$PromptWindowHandle, [string]$ExpectedAutomationId = '') {
    $current = $Element.Current
    $isActionControl = $current.ControlType -eq [System.Windows.Automation.ControlType]::Button -or
      $current.ControlType -eq [System.Windows.Automation.ControlType]::Pane -or
      $current.ControlType -eq [System.Windows.Automation.ControlType]::Hyperlink
    $automationIdMatches = [string]::IsNullOrEmpty($ExpectedAutomationId) -or $current.AutomationId -ceq $ExpectedAutomationId
    if (-not $isActionControl -or $current.ProcessId -ne $ExpectedProcessId -or $current.Name -cne $Name -or -not $automationIdMatches -or -not $current.IsEnabled -or $current.IsOffscreen) {
      throw "BLOCKED: refusing to invoke an unverified '$Name' RDP prompt action."
    }

    $pattern = $null
    if ($Element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) {
      ([System.Windows.Automation.InvokePattern]$pattern).Invoke()
      return 'InvokePattern'
    }
    $rootHandle = [IntPtr]$PromptWindowHandle
    $controlHandle = [IntPtr]$current.NativeWindowHandle
    if ($rootHandle -eq [IntPtr]::Zero -or $controlHandle -eq [IntPtr]::Zero -or
        -not [EBR_RdpUiNative]::IsChild($rootHandle, $controlHandle)) {
      throw "BLOCKED: the exact '$Name' pane did not expose a child HWND owned by its verified RDP prompt window."
    }
    $ownerProcessId = [uint32]0
    [void][EBR_RdpUiNative]::GetWindowThreadProcessId($controlHandle, [ref]$ownerProcessId)
    if ($ownerProcessId -ne [uint32]$MstscProcessId -or
        -not [EBR_RdpUiNative]::IsWindowVisible($controlHandle) -or
        -not [EBR_RdpUiNative]::IsWindowEnabled($controlHandle) -or
        [EBR_RdpUiNative]::GetForegroundWindow() -ne $rootHandle) {
      throw "BLOCKED: refusing the native '$Name' action because HWND process, visibility, enabled state, or foreground-window checks failed."
    }
    $className = [Text.StringBuilder]::new(128)
    if ([EBR_RdpUiNative]::GetClassName($controlHandle, $className, $className.Capacity) -le 0 -or $className.ToString() -cne 'Button') {
      throw "BLOCKED: the exact '$Name' pane's native window class is not Button."
    }
    $messageResult = [IntPtr]::Zero
    $sendStatus = [EBR_RdpUiNative]::SendMessageTimeout($controlHandle, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero, 0x0002, 3000, [ref]$messageResult)
    if ($sendStatus -eq [IntPtr]::Zero) { throw "BLOCKED: the verified native '$Name' Button did not accept BM_CLICK within three seconds." }
    return "NativeBM_CLICK: class=Button; process=$ownerProcessId; automationId=$([string]$current.AutomationId); foregroundPromptVerified=True"
  }

  function Invoke-EBRViewCertificateAction($Element, [int]$ExpectedProcessId, [long]$PromptWindowHandle, [string]$ExpectedAutomationId) {
    $current = $Element.Current
    $isViewControl = $current.ControlType -in @([System.Windows.Automation.ControlType]::Button, [System.Windows.Automation.ControlType]::Pane, [System.Windows.Automation.ControlType]::Hyperlink)
    $nameMatches = $current.Name -match '(?i)^\s*View certificate\s*\.{0,3}\s*$'
    if (-not $isViewControl -or $current.ProcessId -ne $ExpectedProcessId -or -not $nameMatches -or
        $current.AutomationId -cne $ExpectedAutomationId -or -not $current.IsEnabled -or $current.IsOffscreen) {
      throw 'BLOCKED: refusing to invoke an unverified View certificate action.'
    }

    $pattern = $null
    if ($Element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) {
      ([System.Windows.Automation.InvokePattern]$pattern).Invoke()
      return 'InvokePattern'
    }

    # Some Server UIA providers expose the legacy pattern without a loadable
    # LegacyIAccessiblePattern .NET type. Discover it by its UIA pattern ID and
    # call DoDefaultAction only when the provider actually supplies that method.
    $legacyPatternId = [System.Windows.Automation.AutomationPattern]::LookupById(10018)
    if ($null -ne $legacyPatternId) {
      $legacy = $null
      if ($Element.TryGetCurrentPattern($legacyPatternId, [ref]$legacy)) {
        $defaultAction = $legacy.GetType().GetMethod('DoDefaultAction', [type[]]@())
        if ($null -ne $defaultAction) {
          [void]$defaultAction.Invoke($legacy, [object[]]@())
          return 'LegacyIAccessible.DoDefaultAction'
        }
      }
    }

    # Last resort: exactly one native click, tightly scoped to the verified
    # child Button. A failed/indeterminate result is never retried.
    $rootHandle = [IntPtr]$PromptWindowHandle
    $controlHandle = [IntPtr]$current.NativeWindowHandle
    if ($rootHandle -eq [IntPtr]::Zero -or $controlHandle -eq [IntPtr]::Zero -or
        -not [EBR_RdpUiNative]::IsChild($rootHandle, $controlHandle)) {
      throw 'BLOCKED: the exact View certificate control did not expose a child HWND owned by its verified RDP prompt.'
    }
    $rootProcessId = [uint32]0
    $controlProcessId = [uint32]0
    [void][EBR_RdpUiNative]::GetWindowThreadProcessId($rootHandle, [ref]$rootProcessId)
    [void][EBR_RdpUiNative]::GetWindowThreadProcessId($controlHandle, [ref]$controlProcessId)
    if ($rootProcessId -ne [uint32]$ExpectedProcessId -or $controlProcessId -ne [uint32]$ExpectedProcessId -or
        -not [EBR_RdpUiNative]::IsWindowVisible($rootHandle) -or -not [EBR_RdpUiNative]::IsWindowEnabled($rootHandle) -or
        -not [EBR_RdpUiNative]::IsWindowVisible($controlHandle) -or -not [EBR_RdpUiNative]::IsWindowEnabled($controlHandle) -or
        [EBR_RdpUiNative]::GetForegroundWindow() -ne $rootHandle) {
      throw 'BLOCKED: refusing the native View certificate action because process, visibility, enabled-state, or foreground checks failed.'
    }
    $className = [Text.StringBuilder]::new(128)
    if ([EBR_RdpUiNative]::GetClassName($controlHandle, $className, $className.Capacity) -le 0 -or $className.ToString() -cne 'Button') {
      throw 'BLOCKED: the exact View certificate control native class is not Button.'
    }
    $messageResult = [IntPtr]::Zero
    $sendStatus = [EBR_RdpUiNative]::SendMessageTimeout($controlHandle, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero, 0x0002, 3000, [ref]$messageResult)
    if ($sendStatus -eq [IntPtr]::Zero) {
      $nativeError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
      return "NativeBM_CLICK: class=Button; process=$controlProcessId; automationId=$([string]$current.AutomationId); foregroundPromptVerified=True; singleAttempt=True; result=TimedOutOrIndeterminate; win32Error=$nativeError; observeOnly=True; noRetry=True"
    }
    return "NativeBM_CLICK: class=Button; process=$controlProcessId; automationId=$([string]$current.AutomationId); foregroundPromptVerified=True; singleAttempt=True; result=SendMessageReturned; observeOnly=True; noRetry=True"
  }

  function Save-EBRPromptEvidence($Snapshot, [string]$BaseName, $Extra = $null) {
    [void][IO.Directory]::CreateDirectory($EvidenceDirectory)
    $record = [pscustomobject]@{
      WindowTitle = [string]$Snapshot.Window.Current.Name
      ProcessId = $MstscProcessId
      RdpFile = $RdpFilePath
      RdpFileSHA256 = $rdpFileSHA256
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

  function Get-EBRProcessTopLevelWindows {
    $found=[System.Collections.Generic.List[System.Windows.Automation.AutomationElement]]::new()
    foreach($window in $desktop.FindAll([System.Windows.Automation.TreeScope]::Children,$trueCondition)){
      try{$c=$window.Current;if($c.ControlType-eq[System.Windows.Automation.ControlType]::Window-and$c.ProcessId-eq$MstscProcessId-and$c.NativeWindowHandle-ne0-and-not$c.IsOffscreen){$found.Add($window)}}catch{}
    }
    return $found.ToArray()
  }

  function Test-EBRForegroundProcessWindow([long]$Handle,[int]$ProcessId){
    $h=[IntPtr]$Handle
    if($h-eq[IntPtr]::Zero-or[EBR_RdpUiNative]::GetForegroundWindow()-ne$h-or-not[EBR_RdpUiNative]::IsWindowVisible($h)-or-not[EBR_RdpUiNative]::IsWindowEnabled($h)){return $false}
    $owner=[uint32]0
    [void][EBR_RdpUiNative]::GetWindowThreadProcessId($h,[ref]$owner)
    return $owner-eq[uint32]$ProcessId
  }

  function Get-EBRNativeCertificateTabs([long]$TabHandle){
    $accessible=[EBR_RdpUiNative]::GetAccessibleClient([IntPtr]$TabHandle)
    $count=[int]$accessible.accChildCount
    if($count-lt1-or$count-gt8){throw "native SysTabControl32 exposed an unexpected MSAA child count: $count."}
    $items=[System.Collections.Generic.List[object]]::new()
    for($childId=1;$childId-le$count;$childId++){
      $name=[string]$accessible.accName([object]$childId)
      $role=[int]$accessible.accRole([object]$childId)
      $state=[int]$accessible.accState([object]$childId)
      if([string]::IsNullOrWhiteSpace($name)-or$role-ne37){throw "MSAA tab child $childId did not expose an exact named ROLE_SYSTEM_PAGETAB (name '$name', role $role)."}
      $defaultAction=[string]$accessible.accDefaultAction([object]$childId)
      $items.Add([pscustomobject]@{ChildId=$childId;Name=$name;Role=$role;State=$state;Selected=(($state-band0x2)-ne0);DefaultAction=$defaultAction})
    }
    return [pscustomobject]@{Accessible=$accessible;Items=$items.ToArray()}
  }

  function Get-EBRListenerCertificate {
    if($env:GITHUB_ACTIONS-cne'true'-or$env:RUNNER_ENVIRONMENT-cne'github-hosted'-or$env:EBR_RUNNER_ENVIRONMENT_CONTEXT-cne'github-hosted'-or$env:RUNNER_OS-cne'Windows'-or$env:RUNNER_ARCH-cne'X64'-or$env:GITHUB_RUN_ID-notmatch'^[0-9]+$'){
      throw 'listener certificate validation is allowed only in the identified GitHub-hosted Windows x64 disposable run.'
    }
    $os=Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    if($os.Caption-notmatch'Windows Server 2025'-or[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()-ne'X64'-or[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()-ne'X64'){
      throw "expected native x64 Windows Server 2025; observed '$($os.Caption)' / $([Runtime.InteropServices.RuntimeInformation]::OSArchitecture)."
    }
    $settings=@(Get-CimInstance -Namespace 'root/cimv2/TerminalServices' -ClassName 'Win32_TSGeneralSetting' -Filter "TerminalName='RDP-Tcp'" -ErrorAction Stop)
    if($settings.Count-ne1){throw "expected one RDP-Tcp certificate mapping; found $($settings.Count)."}
    $kind=[int]$settings[0].SSLCertificateSHA1HashType
    $thumb=([string]$settings[0].SSLCertificateSHA1Hash-replace'\s','').ToUpperInvariant()
    if($kind-notin@(1,3)-or$thumb-notmatch'^[0-9A-F]{40}$'){throw 'RDP-Tcp certificate mapping type or SHA-1 thumbprint is unsupported.'}
    $storeName=if($kind-eq1){'Remote Desktop'}else{'My'}
    $storePath="Cert:\LocalMachine\$storeName"
    $matches=@(Get-ChildItem -LiteralPath $storePath -ErrorAction Stop|Where-Object{([string]$_.Thumbprint-replace'\s','').ToUpperInvariant()-ceq$thumb})
    if($matches.Count-ne1){throw "listener thumbprint did not resolve to one certificate in LocalMachine\$storeName."}
    $cert=$matches[0];$rawData=[byte[]]$cert.RawData
    if($rawData.Length-lt128-or-not$cert.HasPrivateKey){throw 'mapped listener certificate has no usable DER bytes or private-key association.'}
    $sha1=[Security.Cryptography.SHA1]::Create();$sha256=[Security.Cryptography.SHA256]::Create()
    try{$computedSha1=[BitConverter]::ToString($sha1.ComputeHash($rawData)).Replace('-','').ToUpperInvariant();$computedSha256=[BitConverter]::ToString($sha256.ComputeHash($rawData)).Replace('-','').ToLowerInvariant()}finally{$sha1.Dispose();$sha256.Dispose()}
    if($computedSha1-cne$thumb){throw 'listener certificate DER does not match its configured thumbprint.'}
    if($cert.NotBefore.ToUniversalTime()-gt[DateTime]::UtcNow-or$cert.NotAfter.ToUniversalTime()-le[DateTime]::UtcNow){throw 'mapped listener certificate is outside its validity period.'}
    [pscustomobject]@{MappingType=$kind;Store=$storePath;ThumbprintSHA1=$computedSha1;SHA256=$computedSha256;RawDataBase64=[Convert]::ToBase64String($rawData);Subject=[string]$cert.Subject}
  }

  function Assert-EBRCurrentReviewedRdpFile {
    if(-not(Test-Path -LiteralPath $RdpFilePath -PathType Leaf)){throw 'reviewed RDP file disappeared before certificate acceptance.'}
    $text=Get-Content -LiteralPath $RdpFilePath -Raw -ErrorAction Stop
    $matches=[regex]::Matches($text,'(?im)^[ \t]*full address:s:([^\r\n]*?)[ \t]*\r?$')
    $hash=(Get-FileHash -LiteralPath $RdpFilePath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    if($matches.Count-ne1-or$matches[0].Groups[1].Value-cne'127.0.0.1:3389'-or$hash-cne$rdpFileSHA256){throw 'reviewed RDP target or file SHA-256 changed before certificate acceptance.'}
    return $hash
  }

  function Get-EBRDisplayedCertificateThumbprint($ViewerSnapshot){
    $labels=@(foreach($node in $ViewerSnapshot.Nodes){try{$c=$node.Current;if(-not$c.IsOffscreen-and$c.Name-match'(?i)^\s*Thumbprint(?:\s*\(SHA-?1\))?(?:\s*[:=].*)?\s*$'){$node}}catch{}})
    if($labels.Count-ne1){throw "certificate Details UI exposed $($labels.Count) exact Thumbprint labels."}
    $walker=[System.Windows.Automation.TreeWalker]::ControlViewWalker;$row=$null;$labelControlType=$labels[0].Current.ControlType
    if($labelControlType-in@([System.Windows.Automation.ControlType]::ListItem,[System.Windows.Automation.ControlType]::DataItem)){$row=$labels[0]}
    else{
      $ancestor=$labels[0]
      for($depth=0;$depth-lt6;$depth++){
        $ancestor=$walker.GetParent($ancestor);if($null-eq$ancestor){break}
        if($ancestor.Current.ControlType-in@([System.Windows.Automation.ControlType]::ListItem,[System.Windows.Automation.ControlType]::DataItem)){$row=$ancestor;break}
      }
    }
    if($null-eq$row-or$row.Current.IsOffscreen){throw 'visible Thumbprint label is not inside a visible UIA list/data row.'}
    $related=[System.Collections.Generic.List[System.Windows.Automation.AutomationElement]]::new();$related.Add($row)
    foreach($node in $row.FindAll([System.Windows.Automation.TreeScope]::Descendants,$trueCondition)){$related.Add($node)}
    $values=[System.Collections.Generic.List[string]]::new()
    foreach($node in $related){
      if($node.Current.IsOffscreen){continue}
      $texts=[System.Collections.Generic.List[string]]::new()
      try{$texts.Add([string]$node.Current.Name)}catch{}
      try{$vp=$null;if($node.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern,[ref]$vp)){$texts.Add([string]([System.Windows.Automation.ValuePattern]$vp).Current.Value)}}catch{}
      foreach($text in $texts){
        $candidate=$text.Trim()
        if($candidate-match'(?is)^Thumbprint(?:\s*\(SHA-?1\))?\s*[:=]\s*([0-9A-F:\s]{40,})$'){$candidate=$Matches[1]}
        elseif($candidate-notmatch'(?is)^[0-9A-F:\s]{40,}$'){continue}
        $normalized=($candidate-replace'[^0-9A-Fa-f]','').ToUpperInvariant()
        if($normalized-match'^[0-9A-F]{40}$'-and-not$values.Contains($normalized)){$values.Add($normalized)}
      }
    }
    if($values.Count-ne1){throw "Thumbprint row exposed $($values.Count) unique SHA-1 values."}
    return $values[0]
  }

  function Test-EBRServerCertificateWarning([string]$JoinedNames){
    return $JoinedNames-match'(?i)(identity of the remote computer|server certificate|security certificate|certificate warning|authentication of the server|certificate.{0,50}(?:trusted|verified|valid)|(?:trusted|verified).{0,50}certificate)'
  }

  function Resolve-EBRServerCertificateWarning($WarningSnapshot,[bool]$AlreadyAccepted){
    $viewerSnapshot=$null;$yesAction=$null;$yesActionAttempted=$false
    Save-EBRPromptEvidence $WarningSnapshot 'rdp-server-certificate-warning-before-validation'
    try{
      if($AlreadyAccepted){throw 'second server certificate warning appeared; only one Yes action is allowed.'}
      if(-not(Test-EBRServerCertificateWarning $WarningSnapshot.JoinedNames)){throw 'owned window is not a recognized server certificate warning.'}
      if($WarningSnapshot.JoinedNames-match'(?i)(expired|revoked|not yet valid|revocation status|invalid signature|signature.{0,30}invalid|usage.{0,30}invalid)'){throw 'certificate warning reports a validity, revocation, signature, or usage failure.'}
      $owned=@(Get-EBROwnedRdpWindows)
      if($owned.Count-ne1-or[long]$owned[0].Current.NativeWindowHandle-ne$WarningSnapshot.Handle-or-not(Test-EBRForegroundProcessWindow $WarningSnapshot.Handle $MstscProcessId)){throw 'certificate warning is not the unique foreground window owned by this mstsc process.'}
      $listenerBefore=Get-EBRListenerCertificate
      $freshWarnings=@(Get-EBROwnedRdpWindows|Where-Object{[long]$_.Current.NativeWindowHandle-eq[long]$WarningSnapshot.Handle})
      if($freshWarnings.Count-ne1-or-not(Test-EBRForegroundProcessWindow $WarningSnapshot.Handle $MstscProcessId)){throw 'certificate warning changed or lost foreground before the View action.'}
      $WarningSnapshot=Get-EBRPromptSnapshot $freshWarnings[0]
      if(-not(Test-EBRServerCertificateWarning $WarningSnapshot.JoinedNames)){throw 'refreshed View action parent is no longer the exact server certificate warning.'}
      $view=@(foreach($node in $WarningSnapshot.Nodes){try{$c=$node.Current;if($c.ProcessId-eq$MstscProcessId-and$c.IsEnabled-and-not$c.IsOffscreen-and$c.ControlType-in@([System.Windows.Automation.ControlType]::Button,[System.Windows.Automation.ControlType]::Pane,[System.Windows.Automation.ControlType]::Hyperlink)-and$c.Name-match'(?i)^\s*View certificate\s*\.{0,3}\s*$'){$node}}catch{}})
      if($view.Count-ne1){throw "expected one exact View certificate action; found $($view.Count)."}
      $warningHandle=[long]$WarningSnapshot.Handle
      $existingNestedViewers=@(Get-EBRNestedCertificateViewerWindows $WarningSnapshot)
      $existingTopLevelViewers=@(Get-EBRProcessTopLevelWindows|Where-Object{$_.Current.ControlType-eq[System.Windows.Automation.ControlType]::Window-and$_.Current.Name-ceq'Certificate'})
      if($existingNestedViewers.Count-gt0-or$existingTopLevelViewers.Count-gt0){
        Save-EBRPromptEvidence $WarningSnapshot 'rdp-server-certificate-viewer-present-before-view-action' ([pscustomobject]@{NestedCertificateWindowCount=$existingNestedViewers.Count;TopLevelCertificateWindowCount=$existingTopLevelViewers.Count;ViewActionAttempted=$false})
        throw 'a same-process Certificate window was already present before the exact View certificate action; no action was taken.'
      }
      $oldHandles=@(Get-EBRProcessTopLevelWindows|ForEach-Object{[long]$_.Current.NativeWindowHandle})
      $viewAction=Invoke-EBRViewCertificateAction $view[0] $MstscProcessId $warningHandle ([string]$view[0].Current.AutomationId)
      $viewer=$null;$viewerSource=$null;$watch=[Diagnostics.Stopwatch]::StartNew()
      while($watch.Elapsed.TotalSeconds-lt10-and-not$viewer){
        $viewerCandidates=@{}
        $topLevelCandidates=@(Get-EBRProcessTopLevelWindows|Where-Object{[long]$_.Current.NativeWindowHandle-notin$oldHandles})
        foreach($candidate in $topLevelCandidates){
          $candidateHandle=[long]$candidate.Current.NativeWindowHandle
          $viewerCandidates[[string]$candidateHandle]=[pscustomobject]@{Element=$candidate;Source='NewSameProcessTopLevel';Handle=$candidateHandle}
        }
        $warningRoots=@(Get-EBROwnedRdpWindows|Where-Object{[long]$_.Current.NativeWindowHandle-eq$warningHandle})
        if($warningRoots.Count-gt1){throw 'original mstsc certificate warning became ambiguous while observing the Certificate window.'}
        if($warningRoots.Count-eq1){
          $freshWarning=Get-EBRPromptSnapshot $warningRoots[0]
          if(-not(Test-EBRServerCertificateWarning $freshWarning.JoinedNames)){throw 'the original warning changed while waiting for its Certificate viewer.'}
          $nestedViewers=@(Get-EBRNestedCertificateViewerWindows $freshWarning)
          $nestedIndex=0
          foreach($candidate in $nestedViewers){
            $nestedIndex++
            $candidateHandle=[long]$candidate.Current.NativeWindowHandle
            $key=if($candidateHandle-ne0){[string]$candidateHandle}else{"nested-without-hwnd-$nestedIndex"}
            $viewerCandidates[$key]=[pscustomobject]@{Element=$candidate;Source='NestedDescendantOfVerifiedWarning';Handle=$candidateHandle;ParentSnapshot=$freshWarning}
          }
        }
        if($viewerCandidates.Count-gt1){
          foreach($candidate in $viewerCandidates.Values){try{Save-EBRPromptEvidence (Get-EBRPromptSnapshot $candidate.Element) 'rdp-server-certificate-viewer-ambiguous' ([pscustomobject]@{CandidateSource=$candidate.Source;Handle=$candidate.Handle})}catch{}}
          throw 'View certificate produced multiple same-process viewer-window candidates.'
        }
        if($viewerCandidates.Count-eq1){foreach($observed in $viewerCandidates.Values){break};$viewer=$observed.Element;$viewerSource=$observed.Source}
        else{Start-Sleep -Milliseconds 100}
      }
      if(-not$viewer){
        $remaining=@(Get-EBRProcessTopLevelWindows|Where-Object{[long]$_.Current.NativeWindowHandle-eq$warningHandle})
        $evidenceSnapshot=if($remaining.Count-eq1){Get-EBRPromptSnapshot $remaining[0]}else{$WarningSnapshot}
        $afterWindows=@(Get-EBRProcessTopLevelWindows|ForEach-Object{[pscustomobject]@{Title=[string]$_.Current.Name;Handle=[long]$_.Current.NativeWindowHandle}})
        $nestedAfter=@(Get-EBRNestedCertificateViewerWindows $evidenceSnapshot)
        Save-EBRPromptEvidence $evidenceSnapshot 'rdp-server-certificate-viewer-not-opened' ([pscustomobject]@{ViewAction=$viewAction;NewSameProcessCertificateWindowObserved=$false;NestedCertificateWindowCount=$nestedAfter.Count;WarningWindowStillPresent=($remaining.Count-eq1);SameProcessTopLevelWindows=$afterWindows})
        throw 'View certificate did not open one new same-process certificate window; captured post-action UIA and screenshot evidence.'
      }
      $viewerSnapshot=Get-EBRPromptSnapshot $viewer
      $viewerCurrent=$viewerSnapshot.Window.Current
      $viewerHandle=[long]$viewerCurrent.NativeWindowHandle
      $viewerOwner=[uint32]0
      if($viewerHandle-ne0){[void][EBR_RdpUiNative]::GetWindowThreadProcessId([IntPtr]$viewerHandle,[ref]$viewerOwner)}
      if($viewerCurrent.ControlType-ne[System.Windows.Automation.ControlType]::Window-or$viewerCurrent.Name-cne'Certificate'-or$viewerCurrent.ProcessId-ne$MstscProcessId-or$viewerHandle-eq0-or$viewerHandle-eq$warningHandle-or$viewerCurrent.ClassName-cne'#32770'-or-not$viewerCurrent.IsEnabled-or$viewerCurrent.IsOffscreen-or$viewerOwner-ne[uint32]$MstscProcessId-or-not[EBR_RdpUiNative]::IsWindowVisible([IntPtr]$viewerHandle)-or-not[EBR_RdpUiNative]::IsWindowEnabled([IntPtr]$viewerHandle)){
        Save-EBRPromptEvidence $viewerSnapshot 'rdp-server-certificate-viewer-unrecognized' ([pscustomobject]@{ViewAction=$viewAction;Source=$viewerSource;Title=$viewerCurrent.Name;ControlType=[string]$viewerCurrent.ControlType.ProgrammaticName;ProcessId=$viewerCurrent.ProcessId;OwnerProcessId=$viewerOwner;Handle=$viewerHandle;ClassName=$viewerCurrent.ClassName;Enabled=$viewerCurrent.IsEnabled;Offscreen=$viewerCurrent.IsOffscreen})
        throw 'View certificate did not produce one visible, enabled, distinct same-process Certificate #32770 window; captured its UIA tree and blocked.'
      }
      Save-EBRPromptEvidence $viewerSnapshot 'rdp-server-certificate-viewer-before-thumbprint' ([pscustomobject]@{ViewAction=$viewAction;Source=$viewerSource;ListenerCertificate=$listenerBefore})
      if(-not(Test-EBRForegroundProcessWindow $viewerSnapshot.Handle $MstscProcessId)){throw 'certificate viewer is not the foreground mstsc window.'}
      $tabHosts=@(foreach($node in $viewerSnapshot.Nodes){try{$c=$node.Current;if($c.ControlType-eq[System.Windows.Automation.ControlType]::Pane-and$c.ClassName-ceq'SysTabControl32'-and$c.ProcessId-eq$MstscProcessId-and$c.NativeWindowHandle-ne0-and$c.IsEnabled-and-not$c.IsOffscreen){$node}}catch{}})
      if($tabHosts.Count-ne1){throw "expected one exact visible SysTabControl32 certificate tab host; found $($tabHosts.Count)."}
      $tabHost=$tabHosts[0];$tabHostCurrent=$tabHost.Current;$tabHandle=[long]$tabHostCurrent.NativeWindowHandle;$tabOwner=[uint32]0
      [void][EBR_RdpUiNative]::GetWindowThreadProcessId([IntPtr]$tabHandle,[ref]$tabOwner)
      if($tabHandle-eq0-or$tabOwner-ne[uint32]$MstscProcessId-or-not[EBR_RdpUiNative]::IsChild([IntPtr]$viewerSnapshot.Handle,[IntPtr]$tabHandle)-or-not[EBR_RdpUiNative]::IsWindowVisible([IntPtr]$tabHandle)-or-not[EBR_RdpUiNative]::IsWindowEnabled([IntPtr]$tabHandle)){
        throw 'the exact certificate tab host is not a visible, enabled child of the verified foreground mstsc Certificate window.'
      }
      $nativeTabs=Get-EBRNativeCertificateTabs $tabHandle
      $expectedTabNames=@('General','Details','Certification Path')
      $observedTabNames=@($nativeTabs.Items|ForEach-Object{$_.Name})
      $details=@($nativeTabs.Items|Where-Object{$_.Name-ceq'Details'-and$_.Role-eq37})
      $general=@($nativeTabs.Items|Where-Object{$_.Name-ceq'General'-and$_.Role-eq37})
      $selectedBefore=@($nativeTabs.Items|Where-Object{$_.Selected})
      $tabSetMatches=($nativeTabs.Items.Count-eq$expectedTabNames.Count-and[string]::Join("`n",$observedTabNames)-ceq[string]::Join("`n",$expectedTabNames))
      if(-not$tabSetMatches-or$details.Count-ne1-or$general.Count-ne1-or$selectedBefore.Count-ne1-or$selectedBefore[0].Name-cne'General'-or$details[0].Selected-or$details[0].DefaultAction-cne'Switch'){
        Save-EBRPromptEvidence $viewerSnapshot 'rdp-server-certificate-tabs-unrecognized' ([pscustomobject]@{NativeTabs=$nativeTabs.Items;ExpectedTabNames=$expectedTabNames;NativeTabHostHandle=$tabHandle})
        throw 'native IAccessible did not expose the exact General/Details/Certification Path tabs with General selected and a unique Details Switch action.'
      }
      Save-EBRPromptEvidence $viewerSnapshot 'rdp-server-certificate-tabs-before-details' ([pscustomobject]@{NativeTabs=$nativeTabs.Items;SelectedTab='General';DetailsChildId=$details[0].ChildId;NativeTabHostHandle=$tabHandle;ListenerCertificate=$listenerBefore})
      $nativeTabs.Accessible.accDoDefaultAction([object]$details[0].ChildId)
      $nativeTabsAfter=Get-EBRNativeCertificateTabs $tabHandle
      $detailsAfter=@($nativeTabsAfter.Items|Where-Object{$_.Name-ceq'Details'-and$_.Role-eq37})
      $selectedAfter=@($nativeTabsAfter.Items|Where-Object{$_.Selected})
      if($detailsAfter.Count-ne1-or-not$detailsAfter[0].Selected-or$selectedAfter.Count-ne1-or$selectedAfter[0].Name-cne'Details'){
        $viewerSnapshot=Get-EBRPromptSnapshot $viewer
        Save-EBRPromptEvidence $viewerSnapshot 'rdp-server-certificate-details-tab-not-selected' ([pscustomobject]@{NativeTabs=$nativeTabsAfter.Items;DetailsChildId=$details[0].ChildId;Action='IAccessible.accDoDefaultAction once'})
        throw 'the exact native Details tab did not become the unique selected certificate tab after its single accessible Switch action.'
      }
      $viewerSnapshot=Get-EBRPromptSnapshot $viewer
      Save-EBRPromptEvidence $viewerSnapshot 'rdp-server-certificate-details-tab-selected' ([pscustomobject]@{NativeTabs=$nativeTabsAfter.Items;SelectedTab='Details';DetailsChildId=$detailsAfter[0].ChildId;Action='IAccessible.accDoDefaultAction once'})
      $displayed=$null;$thumbprintFailure='';$wait=[Diagnostics.Stopwatch]::StartNew()
      while($wait.Elapsed.TotalSeconds-lt5-and-not$displayed){
        $viewerSnapshot=Get-EBRPromptSnapshot $viewer
        if($viewerSnapshot.JoinedNames-match'(?i)\bThumbprint\b'){try{$displayed=Get-EBRDisplayedCertificateThumbprint $viewerSnapshot}catch{$thumbprintFailure=$_.Exception.Message}}
        if(-not$displayed){Start-Sleep -Milliseconds 100}
      }
      if(-not$displayed){$viewerSnapshot=Get-EBRPromptSnapshot $viewer;Save-EBRPromptEvidence $viewerSnapshot 'rdp-server-certificate-thumbprint-unavailable' ([pscustomobject]@{Failure=$thumbprintFailure});throw 'Details UI did not expose exactly one readable Thumbprint row.'}
      Save-EBRPromptEvidence $viewerSnapshot 'rdp-server-certificate-viewer-thumbprint' ([pscustomobject]@{DetailsTabSelected=$true;DisplayedThumbprintSHA1=$displayed;ListenerCertificate=$listenerBefore})
      if($displayed-cne$listenerBefore.ThumbprintSHA1){throw 'displayed RDP certificate thumbprint does not match the configured listener certificate.'}
      if(-not(Test-EBRForegroundProcessWindow $viewerSnapshot.Handle $MstscProcessId)){throw 'certificate viewer lost foreground before close.'}
      $close=@(foreach($node in $viewerSnapshot.Nodes){try{$c=$node.Current;if($c.ControlType-eq[System.Windows.Automation.ControlType]::Button-and$c.ProcessId-eq$MstscProcessId-and$c.IsEnabled-and-not$c.IsOffscreen-and$c.Name-cin@('Close','OK')){$node}}catch{}})
      if($close.Count-ne1){throw "expected one safe certificate viewer Close/OK button; found $($close.Count)."}
      [void](Invoke-EBRNamedPromptAction $close[0] ([string]$close[0].Current.Name) $MstscProcessId $viewerSnapshot.Handle ([string]$close[0].Current.AutomationId))
      $wait=[Diagnostics.Stopwatch]::StartNew();$open=$true
      while($open-and$wait.Elapsed.TotalSeconds-lt8){Start-Sleep -Milliseconds 100;$open=@(Get-EBRProcessTopLevelWindows|Where-Object{[long]$_.Current.NativeWindowHandle-eq$viewerSnapshot.Handle}).Count-gt0}
      if($open){throw 'certificate viewer remained open after Close/OK.'}
      $allWarnings=@(Get-EBROwnedRdpWindows);$warnings=@($allWarnings|Where-Object{[long]$_.Current.NativeWindowHandle-eq$warningHandle})
      if($allWarnings.Count-ne1-or$warnings.Count-ne1){throw 'original mstsc certificate warning did not uniquely return after viewing certificate.'}
      $warning=Get-EBRPromptSnapshot $warnings[0]
      if(-not(Test-EBRServerCertificateWarning $warning.JoinedNames)-or-not(Test-EBRForegroundProcessWindow $warningHandle $MstscProcessId)){throw 'certificate warning changed or lost foreground before Yes.'}
      $checkboxes=@(foreach($node in $warning.Nodes){try{$c=$node.Current;if($c.ControlType-eq[System.Windows.Automation.ControlType]::CheckBox-and-not$c.IsOffscreen){$node}}catch{}})
      $rememberCheckboxName="Don't ask me again for connections to this computer"
      $rememberCheckboxes=@(foreach($node in $checkboxes){try{if($node.Current.Name-ceq$rememberCheckboxName){$node}}catch{}})
      if($warning.JoinedNames-notmatch[regex]::Escape($rememberCheckboxName)-or$rememberCheckboxes.Count-ne1){Save-EBRPromptEvidence $warning 'rdp-server-certificate-remember-checkbox-unrecognized' ([pscustomobject]@{ObservedText=($warning.JoinedNames-match[regex]::Escape($rememberCheckboxName));ExactNamedCheckboxCount=$rememberCheckboxes.Count;VisibleCheckboxCount=$checkboxes.Count});throw 'the observed remember-trust text did not map to one exact accessible CheckBox name.'}
      $checkboxStates=[System.Collections.Generic.List[object]]::new()
      foreach($node in $checkboxes){try{$c=$node.Current;$toggle=[System.Windows.Automation.TogglePattern]$node.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern);$state=[string]$toggle.Current.ToggleState;$checkboxStates.Add([pscustomobject]@{Name=[string]$c.Name;State=$state});if($state-ne[string][System.Windows.Automation.ToggleState]::Off){throw 'persistent trust checkbox is selected.'}}catch{Save-EBRPromptEvidence $warning 'rdp-server-certificate-checkbox-state-unreadable' ([pscustomobject]@{Checkboxes=@($checkboxStates)});throw 'certificate trust checkbox state is unreadable or selected.'}}
      $yes=@(Get-EBRNamedPromptActions $warning.Nodes 'Yes' '' $MstscProcessId);$no=@(Get-EBRNamedPromptActions $warning.Nodes 'No' '' $MstscProcessId)
      if($yes.Count-ne1-or$no.Count-ne1-or-not$yes[0].Current.IsEnabled-or-not$no[0].Current.IsEnabled){Save-EBRPromptEvidence $warning 'rdp-server-certificate-actions-unrecognized' ([pscustomobject]@{DisplayedThumbprintSHA1=$displayed;Checkboxes=@($checkboxStates)});throw 'expected unique enabled Yes and No certificate-warning actions.'}
      $rdpHash=Assert-EBRCurrentReviewedRdpFile;$listenerAfter=Get-EBRListenerCertificate
      if($listenerAfter.MappingType-ne$listenerBefore.MappingType-or$listenerAfter.Store-cne$listenerBefore.Store-or$listenerAfter.ThumbprintSHA1-cne$listenerBefore.ThumbprintSHA1-or$listenerAfter.SHA256-cne$listenerBefore.SHA256-or$listenerAfter.RawDataBase64-cne$listenerBefore.RawDataBase64){throw 'listener certificate mapping or bytes changed during UI verification.'}
      if($rdpHash-cne$rdpFileSHA256-or$displayed-cne$listenerAfter.ThumbprintSHA1-or-not(Test-EBRForegroundProcessWindow $warningHandle $MstscProcessId)){throw 'RDP file, target, certificate fingerprint, or foreground prompt changed before Yes.'}
      Save-EBRPromptEvidence $warning 'rdp-server-certificate-warning-before-scoped-yes' ([pscustomobject]@{Target='127.0.0.1:3389';RdpFileSHA256=$rdpHash;DisplayedThumbprintSHA1=$displayed;ListenerCertificate=$listenerAfter;Checkboxes=@($checkboxStates)})
      $yesActionAttempted=$true
      $yesAction=Invoke-EBRNamedPromptAction $yes[0] 'Yes' $MstscProcessId $warningHandle ([string]$yes[0].Current.AutomationId)
      $wait=[Diagnostics.Stopwatch]::StartNew();$open=$true
      while($open-and$wait.Elapsed.TotalSeconds-lt8){Start-Sleep -Milliseconds 100;$open=@(Get-EBROwnedRdpWindows|Where-Object{[long]$_.Current.NativeWindowHandle-eq$warningHandle}).Count-gt0}
      if($open){$after=Get-EBRPromptSnapshot (@(Get-EBROwnedRdpWindows|Where-Object{[long]$_.Current.NativeWindowHandle-eq$warningHandle})[0]);Save-EBRPromptEvidence $after 'rdp-server-certificate-warning-did-not-close' ([pscustomobject]@{DisplayedThumbprintSHA1=$displayed;YesAction=$yesAction});throw 'verified server certificate warning remained open after Yes.'}
      return [pscustomobject]@{Accepted=$true;Action=$yesAction;YesActionAttempted=$yesActionAttempted;YesActionPatternReturned=$yesAction;DisplayedThumbprintSHA1=$displayed;ListenerCertificate=$listenerAfter;RdpFileSHA256=$rdpHash;Target='127.0.0.1:3389'}
    }catch{
      $failure=$_.Exception.Message
      try{Save-EBRPromptEvidence $WarningSnapshot 'rdp-server-certificate-warning-blocked' ([pscustomobject]@{Failure=$failure;YesActionAttempted=$yesActionAttempted;YesActionPatternReturned=$yesAction})}catch{}
      if($viewerSnapshot){try{Save-EBRPromptEvidence $viewerSnapshot 'rdp-server-certificate-viewer-blocked' ([pscustomobject]@{Failure=$failure})}catch{}}
      throw "BLOCKED: server certificate validation failed closed: $failure"
    }
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
                $current.ProcessId -eq $MstscProcessId -and $current.AutomationId -ceq 'VerificationCheckBox' -and
                $current.Name -ceq $educationCheckboxName -and $current.IsEnabled -and -not $current.IsOffscreen) { $node }
          } catch { }
        }
      )
      if ($names -match '(?is)You\s+are\s+opening\s+an\s+RDP\s+file\s+which\s+will\s+establish\s+a\s+connection\s+to\s+another\s+computer' -and
          $names -match [regex]::Escape($educationHeading) -and $educationCheckboxes.Count -eq 1) {
        $okButtons = @(Get-EBRNamedPromptActions $nodes 'OK' 'CommandButton_1' $MstscProcessId)
        $cancelButtons = @(Get-EBRNamedPromptActions $nodes 'Cancel' 'CommandButton_2' $MstscProcessId | Where-Object { $_.Current.IsEnabled })
        if ($okButtons.Count -ne 1 -or $cancelButtons.Count -ne 1) {
          Save-EBRPromptEvidence $snapshot 'rdp-file-education-prompt-unrecognized'
          throw 'BLOCKED: the exact educational RDP-file prompt did not expose unique OK and Cancel actions.'
        }
        $checkbox = $educationCheckboxes[0]
        $toggle = [System.Windows.Automation.TogglePattern]$checkbox.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
        $before = [string]$toggle.Current.ToggleState
        $checkboxAction = 'AlreadyOn; no toggle sent'
        $immediateAfterToggle = $before
        $toggleError = $null
        if ($before -eq [string][System.Windows.Automation.ToggleState]::Off) {
          $checkboxAction = 'One TogglePattern.Toggle() on exact VerificationCheckBox'
          try {
            $toggle.Toggle()
            $immediateAfterToggle = [string]$toggle.Current.ToggleState
          } catch {
            $toggleError = $_.Exception.Message
          }
        }
        # This consent checkbox can visually update before the original UIA
        # element/pattern reports the new state. Never toggle twice on a stale
        # Off reading: reacquire the same mstsc dialog and exact control first.
        $freshEducationWindows = @()
        $freshEducation = $null
        $freshCheckboxes = @()
        $freshCheckboxState = 'UNREADABLE'
        $freshCheckboxObservation = $null
        $checkboxStateWatch = [Diagnostics.Stopwatch]::StartNew()
        do {
          $freshEducationWindows = @(
            foreach ($candidateWindow in $desktop.FindAll([System.Windows.Automation.TreeScope]::Children, $trueCondition)) {
              try {
                if ([long]$candidateWindow.Current.NativeWindowHandle -eq $snapshot.Handle -and $candidateWindow.Current.ProcessId -eq $MstscProcessId) { $candidateWindow }
              } catch { }
            }
          )
          if ($freshEducationWindows.Count -eq 1) {
            $freshEducation = Get-EBRPromptSnapshot $freshEducationWindows[0]
            $freshCheckboxes = @(
              foreach ($node in $freshEducation.Nodes) {
                try {
                  $current = $node.Current
                  if ($current.ControlType -eq [System.Windows.Automation.ControlType]::CheckBox -and
                      $current.ProcessId -eq $MstscProcessId -and $current.AutomationId -ceq 'VerificationCheckBox' -and
                      $current.Name -ceq $educationCheckboxName -and $current.IsEnabled -and -not $current.IsOffscreen) { $node }
                } catch { }
              }
            )
            if ($freshCheckboxes.Count -eq 1) {
              try {
                $freshToggle = [System.Windows.Automation.TogglePattern]$freshCheckboxes[0].GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
                $freshCheckboxState = [string]$freshToggle.Current.ToggleState
                $freshCurrent = $freshCheckboxes[0].Current
                $freshCheckboxObservation = [pscustomobject]@{ProcessId=$freshCurrent.ProcessId;AutomationId=$freshCurrent.AutomationId;Name=$freshCurrent.Name;ControlType=$freshCurrent.ControlType.ProgrammaticName;Enabled=$freshCurrent.IsEnabled;Offscreen=$freshCurrent.IsOffscreen;NativeWindowHandle=[long]$freshCurrent.NativeWindowHandle;Bounds=@($freshCurrent.BoundingRectangle.Left,$freshCurrent.BoundingRectangle.Top,$freshCurrent.BoundingRectangle.Width,$freshCurrent.BoundingRectangle.Height);ToggleState=$freshCheckboxState}
              } catch {
                $freshCheckboxState = 'UNREADABLE'
                $freshCheckboxObservation = [pscustomobject]@{Error=$_.Exception.Message}
              }
            } elseif ($freshCheckboxes.Count -gt 1) {
              $freshCheckboxState = 'AMBIGUOUS'
            }
          } elseif ($freshEducationWindows.Count -gt 1) {
            $freshCheckboxState = 'AMBIGUOUS'
          }
          if ($freshEducationWindows.Count -eq 1 -and $freshCheckboxes.Count -eq 1 -and $freshCheckboxState -eq [string][System.Windows.Automation.ToggleState]::On) { break }
          Start-Sleep -Milliseconds 100
        } while ($checkboxStateWatch.Elapsed.TotalSeconds -lt 3)
        $after = $freshCheckboxState
        if ($after -ne [string][System.Windows.Automation.ToggleState]::On) {
          $failureSnapshot = if ($freshEducation) { $freshEducation } else { Get-EBRPromptSnapshot $ownedWindows[0] }
          Save-EBRPromptEvidence $failureSnapshot 'rdp-file-education-prompt-checkbox-not-enabled' ([pscustomobject]@{Checkbox=$educationCheckboxName;AutomationId='VerificationCheckBox';Before=$before;ImmediateAfterToggle=$immediateAfterToggle;RefreshedAfter=$after;Action=$checkboxAction;ToggleError=$toggleError;FreshWindowMatches=$freshEducationWindows.Count;FreshControlMatches=$freshCheckboxes.Count;FreshControl=$freshCheckboxObservation;ReacquisitionMilliseconds=[Math]::Round($checkboxStateWatch.Elapsed.TotalMilliseconds,1)})
          throw 'BLOCKED: the exact per-account RDP-file acknowledgement checkbox did not reach On after a fresh same-window/control re-read.'
        }
        if ($freshEducationWindows.Count -ne 1) {
          Save-EBRPromptEvidence $snapshot 'rdp-file-education-prompt-window-refresh-failed' ([pscustomobject]@{Checkbox=$educationCheckboxName;AutomationId='VerificationCheckBox';Before=$before;ImmediateAfterToggle=$immediateAfterToggle;After=$after;Action=$checkboxAction;WindowMatches=$freshEducationWindows.Count})
          throw 'BLOCKED: the exact educational prompt could not be re-identified after the acknowledgement checkbox changed.'
        }
        $freshOkButtons = @(Get-EBRNamedPromptActions $freshEducation.Nodes 'OK' 'CommandButton_1' $MstscProcessId)
        $freshCancelButtons = @(Get-EBRNamedPromptActions $freshEducation.Nodes 'Cancel' 'CommandButton_2' $MstscProcessId | Where-Object { $_.Current.IsEnabled })
        $educationRefreshEvidence = [pscustomobject]@{Checkbox=$educationCheckboxName;AutomationId='VerificationCheckBox';Before=$before;ImmediateAfterToggle=$immediateAfterToggle;After=$after;RefreshedCheckboxState=$freshCheckboxState;FreshControl=$freshCheckboxObservation;ToggleError=$toggleError;UniqueEnabledOK=($freshOkButtons.Count -eq 1 -and [bool]$freshOkButtons[0].Current.IsEnabled);UniqueEnabledCancel=($freshCancelButtons.Count -eq 1);Action=$checkboxAction}
        Save-EBRPromptEvidence $freshEducation 'rdp-file-education-prompt-after-ui-refresh' $educationRefreshEvidence
        if ($freshCheckboxes.Count -ne 1 -or $freshCheckboxState -ne [string][System.Windows.Automation.ToggleState]::On -or $freshOkButtons.Count -ne 1 -or $freshCancelButtons.Count -ne 1) {
          Save-EBRPromptEvidence $freshEducation 'rdp-file-education-prompt-refreshed-controls-invalid' $educationRefreshEvidence
          throw 'BLOCKED: refreshed educational prompt controls or acknowledgement state were ambiguous.'
        }
        if (-not $freshOkButtons[0].Current.IsEnabled) {
          Save-EBRPromptEvidence $freshEducation 'rdp-file-education-prompt-ok-disabled' $educationRefreshEvidence
          throw 'BLOCKED: the refreshed educational prompt still has a disabled OK action; dialog UIA and screenshot evidence were captured.'
        }
        $handle = $snapshot.Handle
        $actionPattern = Invoke-EBRNamedPromptAction $freshOkButtons[0] 'OK' $MstscProcessId $snapshot.Handle 'CommandButton_1'
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

      $isUnknownConnectionWarning = Test-EBRUnknownConnectionWarning $names
      if ($isUnknownConnectionWarning) {
        $checkboxes = @(
          foreach ($node in $nodes) {
            try { $current = $node.Current; if ($current.ControlType -eq [System.Windows.Automation.ControlType]::CheckBox -and -not $current.IsOffscreen) { $node } } catch { }
          }
        )
        $connectButtons = @(Get-EBRNamedPromptActions $nodes 'Connect' '' $MstscProcessId)
        $cancelButtons = @(Get-EBRNamedPromptActions $nodes 'Cancel' '' $MstscProcessId | Where-Object { $_.Current.IsEnabled })
        if ($connectButtons.Count -ne 1 -or $cancelButtons.Count -ne 1) {
          Save-EBRPromptEvidence $snapshot 'rdp-connection-security-prompt-unrecognized'
          throw 'BLOCKED: the exact localhost connection warning lacked unique Connect/Cancel actions.'
        }
        $statesBefore = [System.Collections.Generic.List[object]]::new()
        $audioNodes = [System.Collections.Generic.List[System.Windows.Automation.AutomationElement]]::new()
        if ($checkboxes.Count -gt 0) {
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
        }
        if ($checkboxes.Count -gt 0 -and $AllowAudioPlayback -and $audioNodes.Count -ne 1) {
          Save-EBRPromptEvidence $snapshot 'rdp-connection-security-prompt-audio-unrecognized' ([pscustomobject]@{CheckboxStates=@($statesBefore)})
          throw 'BLOCKED: audio playback was requested, but exactly one UI Automation checkbox named Audio playback was not present.'
        }
        if (-not $AllowAudioPlayback -and $audioNodes.Count -gt 1) {
          Save-EBRPromptEvidence $snapshot 'rdp-connection-security-prompt-audio-ambiguous' ([pscustomobject]@{CheckboxStates=@($statesBefore)})
          throw 'BLOCKED: the disabled-audio test exposed ambiguous audio resource controls.'
        }
        if ($checkboxes.Count -gt 0) {
          foreach ($item in $statesBefore) {
            if ($item.Name -ceq 'Audio playback' -and $AllowAudioPlayback) { continue }
            if ($item.State -ne [string][System.Windows.Automation.ToggleState]::Off) {
              Save-EBRPromptEvidence $snapshot 'rdp-connection-security-prompt-resource-already-enabled' ([pscustomobject]@{CheckboxStates=@($statesBefore)})
              throw "BLOCKED: unexpected RDP redirection '$($item.Name)' was already enabled; no resource was accepted."
            }
          }
        }
        if ($checkboxes.Count -eq 0) {
          $audioState = if ($AllowAudioPlayback) {'No resource checkboxes were presented; the exact generated file requests only audiomode:i:0 after all redirections were verified disabled.'} else {'No resource checkboxes were presented; the exact generated file sets audiomode:i:2 and all other redirections disabled.'}
        } else { $audioState = $null }
        Save-EBRPromptEvidence $snapshot 'rdp-connection-security-prompt-before-acknowledgement' ([pscustomobject]@{CheckboxStates=@($statesBefore);NoResourceCheckboxesDisplayed=($checkboxes.Count-eq0);AudioPlaybackRequested=[bool]$AllowAudioPlayback;RdpFileSHA256=$rdpFileSHA256})
        if ($AllowAudioPlayback -and $checkboxes.Count -gt 0) {
          $audioNode = $audioNodes[0]
          $audioToggle = [System.Windows.Automation.TogglePattern]$audioNode.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
          if ([string]$audioToggle.Current.ToggleState -eq [string][System.Windows.Automation.ToggleState]::Off) { $audioToggle.Toggle() }
          $audioState = [string]$audioToggle.Current.ToggleState
          if ($audioState -ne [string][System.Windows.Automation.ToggleState]::On) {
            throw 'BLOCKED: the exact Audio playback resource could not be enabled for the disposable test client.'
          }
          $audioPlaybackAuthorized = $true
        } elseif ($AllowAudioPlayback -and $checkboxes.Count -eq 0) {
          $audioPlaybackAuthorized = $true
        }
        if (-not $connectButtons[0].Current.IsEnabled) { throw 'BLOCKED: the exact localhost Connect action is disabled.' }
        $currentRdpFileSHA256 = (Get-FileHash -LiteralPath $RdpFilePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($currentRdpFileSHA256 -cne $rdpFileSHA256) { throw 'BLOCKED: the reviewed generated RDP file changed before connection; no Connect action was invoked.' }
        $buttonHandle = $snapshot.Handle
        $actionPattern = Invoke-EBRNamedPromptAction $connectButtons[0] 'Connect' $MstscProcessId $snapshot.Handle ([string]$connectButtons[0].Current.AutomationId)
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
            if (Test-EBRServerCertificateWarning $changed.JoinedNames) {
              $certificateResult = Resolve-EBRServerCertificateWarning $changed $serverCertificateAccepted
              $serverCertificateAccepted = [bool]$certificateResult.Accepted
              $serverCertificateIdentity = $certificateResult
              $promptActionMethods.Add("Server certificate Yes: $($certificateResult.Action)")
              $stillOpen = $false
              continue
            }
            if (-not (Test-EBRUnknownConnectionWarning $changed.JoinedNames)) {
              Save-EBRPromptEvidence $changed 'rdp-post-connect-warning-unrecognized'
              $stillOpen = $false
            }
          }
        }
        if ($stillOpen) {
          Save-EBRPromptEvidence $snapshot 'rdp-connection-security-prompt-did-not-close' ([pscustomobject]@{CheckboxStatesBefore=@($statesBefore);AudioPlaybackAfter=$audioState})
          throw 'BLOCKED: the exact localhost connection security dialog remained open after the scoped action.'
        }
        $after = [pscustomobject]@{CheckboxStatesBefore=@($statesBefore);NoResourceCheckboxesDisplayed=($checkboxes.Count-eq0);AudioPlaybackAfter=$audioState;AudioPlaybackAuthorized=$audioPlaybackAuthorized;ConnectInvoked=$true;ActionPattern=$actionPattern;RdpFileSHA256Before=$rdpFileSHA256;RdpFileSHA256AtConnect=$currentRdpFileSHA256;AudioOnlyWhenRequested=[bool]$AllowAudioPlayback}
        Save-EBRPromptEvidence $snapshot 'rdp-connection-security-prompt-after-scoped-selection' $after
        $postWatch = [Diagnostics.Stopwatch]::StartNew()
        while ($postWatch.Elapsed.TotalSeconds -lt 20) {
          foreach ($possible in @(Get-EBROwnedRdpWindows)) {
            $post = Get-EBRPromptSnapshot $possible
            if (Test-EBRUnknownConnectionWarning $post.JoinedNames) {
              Save-EBRPromptEvidence $post 'rdp-connection-security-prompt-still-open'
              throw 'BLOCKED: the verified localhost publisher warning remained open after Connect; no session is treated as established.'
            }
            if (Test-EBRServerCertificateWarning $post.JoinedNames) {
              $certificateResult = Resolve-EBRServerCertificateWarning $post $serverCertificateAccepted
              $serverCertificateAccepted = [bool]$certificateResult.Accepted
              $serverCertificateIdentity = $certificateResult
              $promptActionMethods.Add("Server certificate Yes: $($certificateResult.Action)")
            }
          }
          Start-Sleep -Milliseconds 100
        }
        return [pscustomobject]@{
          Status = 'ACKNOWLEDGED'
          ProcessId = $MstscProcessId
          ProcessName = $client.ProcessName
          RdpFile = $RdpFilePath
          RdpFileSHA256 = $rdpFileSHA256
          Target = '127.0.0.1:3389'
          EducationalPromptAcknowledged = $educationAcknowledged
          ConnectionSecurityAcknowledged = $connectionAcknowledged
          PromptActionMethods = @($promptActionMethods.ToArray())
          AudioPlaybackRequested = [bool]$AllowAudioPlayback
          AudioPlaybackAuthorized = $audioPlaybackAuthorized
          ResourceCheckboxCount = $checkboxes.Count
          NoResourceCheckboxesDisplayed = ($checkboxes.Count -eq 0)
          ResourceRedirections = if($checkboxes.Count-eq0){'No resource checkbox controls were displayed; the exact generated .rdp file SHA-256 and every redirection setting were verified before Connect.'}else{'All visible resource checkboxes remained off except the exact Audio playback checkbox when explicitly requested by the RDP file and caller.'}
          CertificatePromptAccepted = $serverCertificateAccepted
          ServerCertificateIdentity = $serverCertificateIdentity
          Scope = 'Ephemeral GitHub-hosted runner profile; the only connection target is the runner itself at 127.0.0.1:3389.'
        }
      }

      if (Test-EBRServerCertificateWarning $names) {
        $certificateResult = Resolve-EBRServerCertificateWarning $snapshot $serverCertificateAccepted
        $serverCertificateAccepted = [bool]$certificateResult.Accepted
        $serverCertificateIdentity = $certificateResult
        $promptActionMethods.Add("Server certificate Yes: $($certificateResult.Action)")
        continue
      }
      if ($names -match '(?i)(Caution: Unknown remote connection|Unknown publisher|opening an RDP file)') {
        Save-EBRPromptEvidence $snapshot 'rdp-prompt-unrecognized'
        throw 'BLOCKED: an RDP warning did not match an exact reviewed localhost prompt; no control was invoked.'
      }
    }
    Start-Sleep -Milliseconds 100
  }

  if ($educationAcknowledged -or $connectionAcknowledged -or $serverCertificateAccepted) {
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
      CertificatePromptAccepted = $serverCertificateAccepted
      ServerCertificateIdentity = $serverCertificateIdentity
      Note = 'Only reviewed RDP-file prompts and a server-certificate warning with a matching local RDP-Tcp listener fingerprint could be accepted.'
    }
  }
  return [pscustomobject]@{Status='NOT PRESENT';ProcessId=$MstscProcessId;ProcessName=$client.ProcessName;RdpFile=$RdpFilePath;Target='127.0.0.1:3389';ObservedSeconds=[Math]::Round($watch.Elapsed.TotalSeconds,2);AudioPlaybackRequested=[bool]$AllowAudioPlayback;CertificatePromptAccepted=$false}
}
