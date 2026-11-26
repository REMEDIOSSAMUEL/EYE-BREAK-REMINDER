param(
  [Parameter(Mandatory=$true)][string]$BaselineInstaller,
  [Parameter(Mandatory=$true)][string]$BaselineExecutable,
  [Parameter(Mandatory=$true)][string]$UpdateInstaller,
  [Parameter(Mandatory=$true)][string]$UpdateExecutable,
  [Parameter(Mandatory=$true)][string]$FailingInstaller,
  [string]$EvidenceDirectory='build/v1.4.0-updater-evidence',
  [ValidateSet('All','UpdatePreferences','ActiveBreakDeferral','DialogThemes','VisualHotfix')][string]$Scenario='All'
)
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true'-or$env:RUNNER_OS -ne 'Windows'-or$env:RUNNER_ENVIRONMENT -ne 'github-hosted'){throw 'Updater installation acceptance is restricted to a disposable GitHub-hosted Windows runner.'}
if([Runtime.InteropServices.RuntimeInformation]::OSArchitecture-ne[Runtime.InteropServices.Architecture]::X64){throw 'Updater installation acceptance requires an x64 Windows runner.'}
if([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)){throw 'RUNNER_TEMP is unavailable; refusing to create disposable test state.'}
$runnerTemp=[IO.Path]::GetFullPath($env:RUNNER_TEMP)
$scriptRoot=[IO.Path]::GetFullPath((Join-Path $runnerTemp 'EBR-v1.4-Updater-Acceptance'))
$installDir=Join-Path $scriptRoot 'install'
$dataDir=[IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'EyeBreakReminder'))
$EvidenceDirectory=[IO.Path]::GetFullPath($EvidenceDirectory)
$allowedEvidence=[IO.Path]::GetFullPath((Join-Path (Get-Location) 'build/v1.4.0-updater-evidence'))
if($EvidenceDirectory -ine $allowedEvidence){throw "Evidence path must be the isolated build folder: $allowedEvidence"}
foreach($file in @($BaselineInstaller,$BaselineExecutable,$UpdateInstaller,$UpdateExecutable,$FailingInstaller)){if(-not(Test-Path -LiteralPath $file -PathType Leaf)){throw "Required isolated test artifact is missing: $file"}}
if((Test-Path -LiteralPath $scriptRoot) -or (Test-Path -LiteralPath $dataDir)){throw 'Refusing to reuse a runner test folder or Windows profile data directory.'}
$registryRoot=[Microsoft.Win32.Registry]::CurrentUser
foreach($subKey in @('Software\EyeBreakReminder','Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder')){$existing=$registryRoot.OpenSubKey($subKey,$false);if($null-ne$existing){$existing.Dispose();throw "Refusing to replace pre-existing Eye Break Reminder Registry key: HKCU\$subKey"}}
foreach($check in @(@{Path='Software\Microsoft\Windows\CurrentVersion\Run';Name='EyeBreakReminder'},@{Path='Software\Microsoft\Windows\CurrentVersion\RunOnce';Name='!EyeBreakReminderUpdateRecovery'})){$key=$registryRoot.OpenSubKey($check.Path,$false);if($null-eq$key){continue};try{if($key.GetValueNames()-contains$check.Name){throw "Refusing to replace pre-existing HKCU\$($check.Path)\$($check.Name)."}}finally{$key.Dispose()}}
[void][IO.Directory]::CreateDirectory($EvidenceDirectory)
[void][IO.Directory]::CreateDirectory($scriptRoot)
$script:events=[Collections.Generic.List[object]]::new();$script:assertions=0
$script:fixtureIdentities=@(foreach($entry in @(@{Role='installed baseline NSIS setup';Path=$BaselineInstaller},@{Role='installed baseline app';Path=$BaselineExecutable},@{Role='controlled update NSIS setup';Path=$UpdateInstaller},@{Role='controlled update app';Path=$UpdateExecutable},@{Role='controlled failing NSIS setup';Path=$FailingInstaller})){$item=Get-Item -LiteralPath $entry.Path;[pscustomobject]@{Role=$entry.Role;Name=$item.Name;ProductVersion=$item.VersionInfo.ProductVersion;Bytes=$item.Length;SHA256=(Get-FileHash -LiteralPath $entry.Path -Algorithm SHA256).Hash.ToLowerInvariant()}})
$script:logPath=Join-Path $EvidenceDirectory 'updater-acceptance.log'
Start-Transcript -LiteralPath $script:logPath -Force | Out-Null
$native=@'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public struct EBR_UPD_RECT { public int Left,Top,Right,Bottom; }
public struct EBR_UPD_HIGHCONTRAST { public uint cbSize,dwFlags; public IntPtr lpszDefaultScheme; }
public static class EBR_UPD_NATIVE {
 public delegate bool EnumProc(IntPtr hwnd,IntPtr data);
 [DllImport("user32.dll",SetLastError=true)] static extern bool EnumWindows(EnumProc callback,IntPtr data);
 [DllImport("user32.dll",SetLastError=true)] public static extern uint GetWindowThreadProcessId(IntPtr hwnd,out uint pid);
 [DllImport("user32.dll",SetLastError=true)] public static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll",SetLastError=true)] public static extern bool IsWindowEnabled(IntPtr hwnd);
 [DllImport("user32.dll",SetLastError=true)] public static extern bool IsWindow(IntPtr hwnd);
 [DllImport("user32.dll",SetLastError=true)] public static extern IntPtr GetParent(IntPtr hwnd);
 [DllImport("user32.dll",SetLastError=true)] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll",SetLastError=true)] public static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll",SetLastError=true)] public static extern void mouse_event(uint flags,uint dx,uint dy,uint data,UIntPtr extra);
 [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern int GetWindowTextW(IntPtr hwnd,StringBuilder text,int count);
 [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern int GetClassNameW(IntPtr hwnd,StringBuilder text,int count);
 [DllImport("user32.dll",SetLastError=true)] public static extern bool GetWindowRect(IntPtr hwnd,out EBR_UPD_RECT rect);
 [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern IntPtr FindWindowW(string className,string windowName);
 [DllImport("user32.dll",SetLastError=true)] public static extern IntPtr GetDlgItem(IntPtr parent,int id);
 [DllImport("user32.dll",SetLastError=true)] public static extern IntPtr SendMessageW(IntPtr hwnd,uint message,IntPtr wParam,IntPtr lParam);
 [DllImport("user32.dll",EntryPoint="GetWindowLongW",SetLastError=true)] public static extern int GetWindowLongW(IntPtr hwnd,int index);
 [DllImport("user32.dll",SetLastError=true)] public static extern bool SetForegroundWindow(IntPtr hwnd);
 [DllImport("user32.dll",SetLastError=true)] public static extern bool PostMessageW(IntPtr hwnd,uint message,IntPtr wp,IntPtr lp);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern uint RegisterWindowMessageW(string name);
 [DllImport("user32.dll",EntryPoint="SystemParametersInfoW",SetLastError=true)] static extern bool SystemParametersInfoGetHighContrast(uint action,uint parameter,ref EBR_UPD_HIGHCONTRAST value,uint flags);
 [DllImport("user32.dll",EntryPoint="SystemParametersInfoW",SetLastError=true)] static extern bool SystemParametersInfoSetHighContrast(uint action,uint parameter,ref EBR_UPD_HIGHCONTRAST value,uint flags);
 public static IntPtr[] Windows(int pid){var found=new List<IntPtr>();EnumProc cb=delegate(IntPtr h,IntPtr ignored){uint owner;GetWindowThreadProcessId(h,out owner);if(owner==(uint)pid&&IsWindowVisible(h))found.Add(h);return true;};EnumWindows(cb,IntPtr.Zero);GC.KeepAlive(cb);return found.ToArray();}
 public static IntPtr[] WindowsAll(){var found=new List<IntPtr>();EnumProc cb=delegate(IntPtr h,IntPtr ignored){if(IsWindowVisible(h))found.Add(h);return true;};EnumWindows(cb,IntPtr.Zero);GC.KeepAlive(cb);return found.ToArray();}
 public static bool HighContrastState(out bool enabled){var value=new EBR_UPD_HIGHCONTRAST();value.cbSize=(uint)Marshal.SizeOf(typeof(EBR_UPD_HIGHCONTRAST));bool ok=SystemParametersInfoGetHighContrast(0x0042,value.cbSize,ref value,0);enabled=(value.dwFlags&1)!=0;return ok;}
 public static bool SetHighContrastState(bool enabled){var value=new EBR_UPD_HIGHCONTRAST();value.cbSize=(uint)Marshal.SizeOf(typeof(EBR_UPD_HIGHCONTRAST));if(!SystemParametersInfoGetHighContrast(0x0042,value.cbSize,ref value,0))return false;if(enabled)value.dwFlags|=1;else value.dwFlags&=~1u;return SystemParametersInfoSetHighContrast(0x0043,value.cbSize,ref value,2);}
 public static string Title(IntPtr h){var b=new StringBuilder(512);GetWindowTextW(h,b,b.Capacity);return b.ToString();}
 public static string ClassName(IntPtr h){var b=new StringBuilder(256);GetClassNameW(h,b,b.Capacity);return b.ToString();}
 public static bool ExitWindow(IntPtr h){uint message=RegisterWindowMessageW("EyeBreakReminder.Exit.Native.1");return PostMessageW(h,message,IntPtr.Zero,IntPtr.Zero);}
}
'@
Add-Type -TypeDefinition $native -ErrorAction Stop
Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
Add-Type -AssemblyName System.Drawing -ErrorAction Stop

function Record([string]$Name,[string]$Status,$Details=$null){$script:events.Add([pscustomobject]@{Name=$Name;Status=$Status;Details=$Details;Utc=[DateTime]::UtcNow.ToString('o')})}
function Assert([bool]$Ok,[string]$Name,$Details=$null){if(-not$Ok){Record $Name 'FAIL' $Details;throw "Updater acceptance failed: $Name ($Details)"};$script:assertions++;Record $Name 'PASS' $Details}
function Save-ActiveBreakDiagnostics(){
  $source=Join-Path $installDir 'test-update-modal-diagnostic.txt'
  if(Test-Path -LiteralPath $source -PathType Leaf){$destination=Join-Path $EvidenceDirectory 'active-break-modal-diagnostic.txt';Copy-Item -LiteralPath $source -Destination $destination -Force;return [IO.File]::ReadAllText($destination)}
  return ''
}
function Get-Root([IntPtr]$Hwnd){try{[System.Windows.Automation.AutomationElement]::FromHandle($Hwnd)}catch{$null}}
function Get-Names($Root){$names=[Collections.Generic.List[string]]::new();if(-not$Root){return @()};try{$names.Add($Root.Current.Name)}catch{};try{$items=$Root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition);foreach($item in $items){try{if($item.Current.ProcessId-eq$Root.Current.ProcessId-and$item.Current.Name){$names.Add($item.Current.Name)}}catch{}}}catch{};return @($names)}
function Get-ElementDiagnostics($Dialog,[string]$Name){$rows=[Collections.Generic.List[object]]::new();$patterns=@([pscustomobject]@{Name='Invoke';Pattern=[System.Windows.Automation.InvokePattern]::Pattern},[pscustomobject]@{Name='SelectionItem';Pattern=[System.Windows.Automation.SelectionItemPattern]::Pattern},[pscustomobject]@{Name='Toggle';Pattern=[System.Windows.Automation.TogglePattern]::Pattern});foreach($element in $Dialog.Root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)){try{$current=$element.Current;if($current.ProcessId-ne$Dialog.ProcessId-or$current.Name-cne$Name){continue};$available=[Collections.Generic.List[string]]::new();foreach($check in $patterns){$value=$null;try{if($element.TryGetCurrentPattern($check.Pattern,[ref]$value)){$available.Add($check.Name)}}catch{}};$supported=@();try{$supported=@($element.GetSupportedPatterns()|ForEach-Object{$_.ProgrammaticName})}catch{};$rows.Add([pscustomobject]@{Name=$current.Name;ControlType=$current.ControlType.ProgrammaticName;ClassName=$current.ClassName;AutomationId=$current.AutomationId;ProcessId=$current.ProcessId;NativeWindowHandle=$current.NativeWindowHandle;Enabled=$current.IsEnabled;KeyboardFocusable=$current.IsKeyboardFocusable;HasKeyboardFocus=$current.HasKeyboardFocus;Patterns=@($available);SupportedPatterns=$supported})}catch{}};return ,@($rows)}
function Test-ProcessDialog([int]$appProcessId,[string]$Marker){foreach($hwnd in [EBR_UPD_NATIVE]::Windows($appProcessId)){$root=Get-Root $hwnd;if(-not$root){continue};if(((Get-Names $root)-join "`n").Contains($Marker)){return $true}};return $false}
function Find-Dialog([string]$Marker,[int[]]$ProcessIds=@(),[int]$TimeoutSeconds=30){$expectedWindowTitle=$null;if($Marker-in@('Eye Break Reminder Update Available','Clean Installation','Downloading Eye Break Reminder','Ready to install.','Download cancelled','SHA-256 integrity check','fixture copy was interrupted')){$expectedWindowTitle='Eye Break Reminder Update'}elseif($Marker-ceq'Taking an eye break'){$expectedWindowTitle='Taking an eye break — Eye Break Reminder'};$watch=[Diagnostics.Stopwatch]::StartNew();while($watch.Elapsed.TotalSeconds-lt$TimeoutSeconds){if(-not$ProcessIds-or$ProcessIds.Count-eq0){$windows=[EBR_UPD_NATIVE]::WindowsAll()}else{$list=[Collections.Generic.List[IntPtr]]::new();foreach($appProcessIdValue in $ProcessIds){foreach($hwnd in [EBR_UPD_NATIVE]::Windows([int]$appProcessIdValue)){$list.Add($hwnd)}};$windows=$list.ToArray()};foreach($hwnd in $windows){$actualPid=[uint32]0;[void][EBR_UPD_NATIVE]::GetWindowThreadProcessId($hwnd,[ref]$actualPid);$title=[EBR_UPD_NATIVE]::Title($hwnd);if($expectedWindowTitle-and$title-cne$expectedWindowTitle){continue};$root=Get-Root $hwnd;if(-not$root){continue};$names=Get-Names $root;$all=($names -join "`n")+"`n"+$title;if($all.Contains($Marker)){return [pscustomobject]@{Handle=$hwnd;Root=$root;Names=$names;ProcessId=[int]$actualPid;WindowTitle=$title}}};Start-Sleep -Milliseconds 100};$snapshot=@(Get-Process -Name EyeBreakReminder,coordinator -ErrorAction SilentlyContinue|ForEach-Object{[pscustomobject]@{Id=$_.Id;Path=$_.Path;Windows=@([EBR_UPD_NATIVE]::Windows($_.Id)|ForEach-Object{[EBR_UPD_NATIVE]::Title($_)})}});throw "Timed out waiting for UI text '$Marker'. Processes: $(ConvertTo-Json $snapshot -Depth 5 -Compress)"}
function Find-Element($Dialog,[string]$Name,[string]$ControlType=''){foreach($element in $Dialog.Root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)){try{if($element.Current.ProcessId-ne$Dialog.ProcessId-or$element.Current.Name-cne$Name){continue};if($ControlType-and$element.Current.ControlType.ProgrammaticName-ne$ControlType){continue};return $element}catch{}};$diagnostics=ConvertTo-Json -InputObject (Get-ElementDiagnostics $Dialog $Name) -Depth 5 -Compress;throw "Accessible UI element '$Name' with role '$ControlType' was not found. Matching UI Automation elements: $diagnostics. Dialog names: $($Dialog.Names -join ' | ')"}
function Get-RunnerTextScaleSnapshot(){
  $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Accessibility',$false)
  if($null-eq$key){return [pscustomobject]@{KeyExisted=$false;ValueExisted=$false;Value=$null;Kind=$null}}
  try{$exists=$key.GetValueNames()-contains'TextScaleFactor';if($exists){return [pscustomobject]@{KeyExisted=$true;ValueExisted=$true;Value=$key.GetValue('TextScaleFactor');Kind=$key.GetValueKind('TextScaleFactor')}};return [pscustomobject]@{KeyExisted=$true;ValueExisted=$false;Value=$null;Kind=$null}}
  finally{$key.Dispose()}
}
function Set-RunnerTextScale([int]$Value){
  if($Value-lt100-or$Value-gt225-or$Value%25-ne0){throw "Unsupported test text scale: $Value"}
  $key=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\Microsoft\Accessibility')
  try{$key.SetValue('TextScaleFactor',$Value,[Microsoft.Win32.RegistryValueKind]::DWord)}finally{$key.Dispose()}
}
function Restore-RunnerTextScale($Snapshot){
  $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Accessibility',$true)
  if($Snapshot.ValueExisted){if($null-eq$key){$key=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\Microsoft\Accessibility')};try{$key.SetValue('TextScaleFactor',$Snapshot.Value,$Snapshot.Kind)}finally{$key.Dispose()}}
  elseif($null-ne$key){try{$key.DeleteValue('TextScaleFactor',$false)}finally{$key.Dispose()}}
  if(-not$Snapshot.KeyExisted){$check=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Accessibility',$false);$empty=$false;if($check){try{$empty=$check.ValueCount-eq0-and$check.SubKeyCount-eq0}finally{$check.Dispose()}};if($empty){[Microsoft.Win32.Registry]::CurrentUser.DeleteSubKey('Software\Microsoft\Accessibility',$false)}}
}
function Set-LongReleaseFixture([string]$Notes){
  $path=Join-Path $installDir 'test-update-response.txt';$response=[IO.File]::ReadAllText($path);$separator=$response.IndexOf("`r`n`r`n");if($separator-lt0){throw 'The long-text fixture has no HTTP header/body separator.'}
  $headers=$response.Substring(0,$separator);$release=$response.Substring($separator+4)|ConvertFrom-Json
  $manifest=Get-Content -LiteralPath (Join-Path $installDir 'EyeBreakReminder-UpdateManifest.json') -Raw|ConvertFrom-Json
  if($release.tag_name-cne("v"+$manifest.version)){throw 'Refusing a long-notes fixture whose release tag differs from its signed manifest version.'}
  # Keep the release tag and signed manifest version unchanged and matching.
  # Only the notes need to be long for this high-scale clipping/accessibility case.
  $release.body=$Notes
  [IO.File]::WriteAllText($path,($headers+"`r`n`r`n"+($release|ConvertTo-Json -Compress -Depth 8)),[Text.UTF8Encoding]::new($false))
}
function Find-ElementByType($Dialog,[string]$ControlType){foreach($element in $Dialog.Root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)){try{if($element.Current.ProcessId-eq$Dialog.ProcessId-and$element.Current.ControlType.ProgrammaticName-ceq$ControlType){return $element}}catch{}};throw "Accessible UI element with role '$ControlType' was not found. Dialog names: $($Dialog.Names -join ' | ')"}
function Find-ElementByClass($Dialog,[string]$ClassName){$matches=[Collections.Generic.List[object]]::new();foreach($element in $Dialog.Root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)){try{if($element.Current.ProcessId-eq$Dialog.ProcessId-and$element.Current.ClassName-ceq$ClassName){$matches.Add($element)}}catch{}};if($matches.Count-ne1){throw "Expected exactly one accessible '$ClassName' control in the update dialog; found $($matches.Count)."};return $matches[0]}
function Assert-ControlWithinDialog($Dialog,[string]$Name,[string]$ControlType,[string]$Context){$element=Find-Element $Dialog $Name $ControlType;$current=$element.Current;$bounds=$current.BoundingRectangle;$window=[EBR_UPD_RECT]::new();if(-not[EBR_UPD_NATIVE]::GetWindowRect($Dialog.Handle,[ref]$window)){throw 'Could not read updater dialog bounds for layout verification.'};$windowBounds=[pscustomobject]@{Left=$window.Left;Top=$window.Top;Right=$window.Right;Bottom=$window.Bottom};$inside=$bounds.Width-gt0-and$bounds.Height-gt0-and$bounds.Left-ge($window.Left-1)-and$bounds.Top-ge($window.Top-1)-and$bounds.Right-le($window.Right+1)-and$bounds.Bottom-le($window.Bottom+1);Assert (-not$current.IsOffscreen-and$inside) "$Context '$Name' is visible and contained within the rendered dialog" ([pscustomobject]@{WindowTitle=$Dialog.WindowTitle;ControlType=$current.ControlType.ProgrammaticName;IsOffscreen=$current.IsOffscreen;Bounds=$bounds;DialogBounds=$windowBounds});return $element}
function Assert-ScreenshotHasRenderedContent([string]$Name,[string]$Context){$path=Join-Path $EvidenceDirectory $Name;$bitmap=[Drawing.Bitmap]::new($path);$different=0;try{$background=$bitmap.GetPixel(2,2).ToArgb();$step=[Math]::Max(3,[Math]::Min(12,[int]([Math]::Min($bitmap.Width,$bitmap.Height)/32)));for($y=1;$y-lt$bitmap.Height;$y+=$step){for($x=1;$x-lt$bitmap.Width;$x+=$step){if($bitmap.GetPixel($x,$y).ToArgb()-ne$background){$different++}}}}finally{$bitmap.Dispose()};Assert ($different-gt8) "$Context screenshot contains visible pixels beyond its background" ([pscustomobject]@{File=$path;SampledForegroundPixels=$different})}
function Get-TestProcessMap{$map=@{};foreach($row in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)){$map[[int]$row.ProcessId]=$row};return $map}
function Get-TestUninstallerIdentity([int]$ProcessId,[string]$ExpectedPath,[int]$LaunchPid,[hashtable]$ProcessMap=$null){
  $process=Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
  if(-not$process){return $null}
  $actual='';try{$actual=[IO.Path]::GetFullPath($process.Path)}catch{}
  $expected=[IO.Path]::GetFullPath($ExpectedPath)
  if($actual-ieq$expected){return [pscustomobject]@{Process=$process;Path=$actual;Kind='registered Uninstall.exe'}}
  # NSIS starts a detached copy of the uninstaller from %TEMP%\~nsu*.tmp\Un.exe.
  # Accept it only when its live parent chain leads back to this exact launch PID.
  $lineage=[Collections.Generic.List[int]]::new();$visited=[Collections.Generic.HashSet[int]]::new();$current=$ProcessId;$descendant=$false
  if($null-eq$ProcessMap){$ProcessMap=Get-TestProcessMap}
  for($depth=0;$depth-lt32-and$current-gt0;$depth++){
    if(-not$visited.Add([int]$current)){break};$lineage.Add([int]$current)
    if($current-eq$LaunchPid){$descendant=$true;break}
    if(-not$ProcessMap.ContainsKey([int]$current)){break}
    $current=[int]$ProcessMap[[int]$current].ParentProcessId
  }
  $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
  $tempChild=$actual.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase)-and[IO.Path]::GetFileName($actual)-ieq'Un.exe'-and[IO.Path]::GetFileName([IO.Path]::GetDirectoryName($actual))-match'^~nsu.+\.tmp$'
  if($descendant-and$tempChild){return [pscustomobject]@{Process=$process;Path=$actual;Kind='verified NSIS extracted child';Lineage=@($lineage)}}
  return $null
}
function Get-TestUninstallerProcess($Dialog,[string]$ExpectedPath,[int]$LaunchPid){$identity=Get-TestUninstallerIdentity $Dialog.ProcessId $ExpectedPath $LaunchPid;if(-not$identity){throw "Interactive uninstall UI process is not the isolated NSIS uninstaller or its verified extracted child. PID=$($Dialog.ProcessId); LaunchPID=$LaunchPid"};Assert $true 'interactive uninstall UI belongs to the isolated NSIS uninstaller' ([pscustomobject]@{Expected=[IO.Path]::GetFullPath($ExpectedPath);Actual=$identity.Path;WindowPid=$Dialog.ProcessId;Kind=$identity.Kind;Lineage=$identity.Lineage});return $identity.Process}
function Find-TestUninstallerDialog([string]$Marker,[string]$ExpectedPath,$StartedProcess,[int]$TimeoutSeconds=30){$watch=[Diagnostics.Stopwatch]::StartNew();while($watch.Elapsed.TotalSeconds-lt$TimeoutSeconds){$processMap=Get-TestProcessMap;foreach($hwnd in [EBR_UPD_NATIVE]::WindowsAll()){$ownerId=[uint32]0;[void][EBR_UPD_NATIVE]::GetWindowThreadProcessId($hwnd,[ref]$ownerId);$identity=Get-TestUninstallerIdentity ([int]$ownerId) $ExpectedPath $StartedProcess.Id $processMap;if(-not$identity){continue};$title=[EBR_UPD_NATIVE]::Title($hwnd);$root=Get-Root $hwnd;if(-not$root){continue};$names=Get-Names $root;$all=($names -join "`n")+"`n"+$title;if($all.Contains($Marker)){return [pscustomobject]@{Handle=$hwnd;Root=$root;Names=$names;ProcessId=[int]$ownerId;WindowTitle=$title;ImagePath=$identity.Path;ProcessKind=$identity.Kind}}};Start-Sleep -Milliseconds 100};$StartedProcess.Refresh();$exitCode=if($StartedProcess.HasExited){$StartedProcess.ExitCode}else{$null};$processMap=Get-TestProcessMap;$matching=@(Get-Process -ErrorAction SilentlyContinue|ForEach-Object{$identity=Get-TestUninstallerIdentity $_.Id $ExpectedPath $StartedProcess.Id $processMap;if($identity){[pscustomobject]@{Id=$_.Id;Path=$identity.Path;Kind=$identity.Kind;Windows=@([EBR_UPD_NATIVE]::Windows($_.Id)|ForEach-Object{[EBR_UPD_NATIVE]::Title($_)})}}});throw "Timed out waiting for '$Marker' in the isolated NSIS uninstaller or its extracted child. StartPID=$($StartedProcess.Id); Exited=$($StartedProcess.HasExited); ExitCode=$exitCode; MatchingProcesses=$(ConvertTo-Json $matching -Depth 5 -Compress)"}
function Invoke-Element($Dialog,[string]$Name){$element=Find-Element $Dialog $Name 'ControlType.Button';$pattern=$null;if(-not$element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern,[ref]$pattern)){throw "Button '$Name' has no accessible Invoke action."};$pattern.Invoke()}
function Invoke-TestUninstallerButton($Dialog,[string[]]$Names){
  $controls=[Collections.Generic.List[object]]::new()
  foreach($element in $Dialog.Root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)){
    try{$current=$element.Current}catch{continue}
    if($current.ProcessId-ne$Dialog.ProcessId){continue}
    $controls.Add([pscustomobject]@{Name=$current.Name;ControlType=$current.ControlType.ProgrammaticName;ClassName=$current.ClassName;AutomationId=$current.AutomationId;ProcessId=$current.ProcessId;NativeWindowHandle=$current.NativeWindowHandle;Enabled=$current.IsEnabled})
    if($Names-cnotcontains$current.Name-or-not$current.IsEnabled-or$current.ClassName-cne'Button'){continue}
    $handle=[IntPtr]$current.NativeWindowHandle
    if($handle-eq[IntPtr]::Zero){continue}
    $owner=[uint32]0;[void][EBR_UPD_NATIVE]::GetWindowThreadProcessId($handle,[ref]$owner)
    if($owner-ne[uint32]$Dialog.ProcessId-or-not[EBR_UPD_NATIVE]::IsWindowEnabled($handle)){continue}
    $invoke=$null
    if($element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern,[ref]$invoke)){$invoke.Invoke();return $current.Name}
    # The Windows Server UIA provider exposes NSIS native buttons as Pane elements
    # without patterns. Use real mouse input on the exact visible enabled Button
    # child owned by the verified isolated uninstaller process.
    if(-not[EBR_UPD_NATIVE]::IsWindow($handle)-or[EBR_UPD_NATIVE]::GetParent($handle)-ne$Dialog.Handle){continue}
    $rect=[EBR_UPD_RECT]::new();if(-not[EBR_UPD_NATIVE]::GetWindowRect($handle,[ref]$rect)){continue}
    [void][EBR_UPD_NATIVE]::SetForegroundWindow($Dialog.Handle);Start-Sleep -Milliseconds 100
    if([EBR_UPD_NATIVE]::GetForegroundWindow()-ne$Dialog.Handle){throw "Could not activate the verified NSIS wizard before clicking '$($current.Name)' on its native Windows desktop."}
    $x=[int](($rect.Left+$rect.Right)/2);$y=[int](($rect.Top+$rect.Bottom)/2)
    if(-not[EBR_UPD_NATIVE]::SetCursorPos($x,$y)){throw "Could not place the pointer over the verified NSIS button '$($current.Name)'."}
    [EBR_UPD_NATIVE]::mouse_event(0x0002,0,0,0,[UIntPtr]::Zero);Start-Sleep -Milliseconds 60;[EBR_UPD_NATIVE]::mouse_event(0x0004,0,0,0,[UIntPtr]::Zero)
    $buttonEvidence=[pscustomobject]@{Name=$current.Name;ControlType=$current.ControlType.ProgrammaticName;ClassName=$current.ClassName;ProcessId=$current.ProcessId;NativeWindowHandle=$handle.ToInt64();Bounds=$rect;Method='Interactive desktop mouse input'}
    Record 'NSIS native button clicked on the verified Windows desktop' 'INFO' $buttonEvidence
    return $current.Name
  }
  throw "No enabled native NSIS button matched [$($Names -join ', ')]. Dialog names: $($Dialog.Names -join ' | '). Controls: $(ConvertTo-Json @($controls) -Depth 5 -Compress)"
}
function Get-NsisNativeRadio($Dialog,[string]$Name){
  $nativeCandidates=[Collections.Generic.List[object]]::new()
  foreach($element in $Dialog.Root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)){
    try{$current=$element.Current}catch{continue}
    if($current.ProcessId-ne$Dialog.ProcessId-or$current.Name-cne$Name-or$current.ClassName-cne'Button'){continue}
    $handle=[IntPtr]$current.NativeWindowHandle
    $owner=[uint32]0;$isWindow=$false;$isVisible=$false;$isEnabled=$false;$style=0;$buttonType=-1;$parentChain=[Collections.Generic.List[object]]::new();$descendsFromDialog=$false
    if($handle-ne[IntPtr]::Zero){
      $isWindow=[EBR_UPD_NATIVE]::IsWindow($handle);$isVisible=[EBR_UPD_NATIVE]::IsWindowVisible($handle);$isEnabled=[EBR_UPD_NATIVE]::IsWindowEnabled($handle);[void][EBR_UPD_NATIVE]::GetWindowThreadProcessId($handle,[ref]$owner);$style=[EBR_UPD_NATIVE]::GetWindowLongW($handle,-16);$buttonType=$style-band0xF
      $ancestor=[EBR_UPD_NATIVE]::GetParent($handle)
      for($depth=0;$depth-lt16-and$ancestor-ne[IntPtr]::Zero;$depth++){
        $ancestorPid=[uint32]0;[void][EBR_UPD_NATIVE]::GetWindowThreadProcessId($ancestor,[ref]$ancestorPid)
        $parentChain.Add([pscustomobject]@{Handle=$ancestor.ToInt64();ProcessId=$ancestorPid;ClassName=[EBR_UPD_NATIVE]::ClassName($ancestor)})
        if($ancestor-eq$Dialog.Handle){$descendsFromDialog=($ancestorPid-eq[uint32]$Dialog.ProcessId);break}
        if($ancestorPid-ne[uint32]$Dialog.ProcessId){break}
        $ancestor=[EBR_UPD_NATIVE]::GetParent($ancestor)
      }
    }
    $nativeCandidates.Add([pscustomobject]@{Name=$current.Name;AutomationId=$current.AutomationId;ProcessId=$current.ProcessId;NativeWindowHandle=$handle.ToInt64();OwnerProcessId=$owner;Enabled=$current.IsEnabled;IsWindow=$isWindow;IsVisible=$isVisible;IsEnabled=$isEnabled;Style=$style;ButtonType=$buttonType;DescendsFromVerifiedDialog=$descendsFromDialog;ParentChain=@($parentChain)})
    if($handle-eq[IntPtr]::Zero-or-not$current.IsEnabled-or-not$isWindow-or-not$isVisible-or-not$isEnabled-or$owner-ne[uint32]$Dialog.ProcessId-or-not$descendsFromDialog){continue}
    if($buttonType-notin@(4,9)){continue}
    return [pscustomobject]@{Element=$element;Handle=$handle;Name=$current.Name;AutomationId=$current.AutomationId;ProcessId=$current.ProcessId;Style=$style;ButtonType=$buttonType;ParentChain=@($parentChain)}
  }
  $diagnostics=ConvertTo-Json -InputObject (Get-ElementDiagnostics $Dialog $Name) -Depth 5 -Compress
  $nativeDiagnostics=ConvertTo-Json -InputObject @($nativeCandidates) -Depth 6 -Compress
  throw "Verified NSIS radio '$Name' was not found as an enabled native radio button owned by the isolated uninstaller dialog. UIA matches: $diagnostics. Native candidates: $nativeDiagnostics"
}
function Test-NsisNativeRadioSelected($Dialog,[string]$Name){$control=Get-NsisNativeRadio $Dialog $Name;return ([EBR_UPD_NATIVE]::SendMessageW($control.Handle,0x00F0,[IntPtr]::Zero,[IntPtr]::Zero).ToInt32()-eq1)}
function Select-Radio($Dialog,[string]$Name){
  $element=$null;try{$element=Find-Element $Dialog $Name 'ControlType.RadioButton'}catch{}
  if($element){$pattern=$null;if($element.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern,[ref]$pattern)){$pattern.Select();return $element}}
  # NSIS's native radio controls are exposed by the Windows Server UIA provider as
  # Pane elements without SelectionItemPattern. Resolve only the exact radio HWND
  # owned by the already-verified isolated uninstaller, then use desktop mouse input.
  $control=Get-NsisNativeRadio $Dialog $Name
  [void][EBR_UPD_NATIVE]::SetForegroundWindow($Dialog.Handle);Start-Sleep -Milliseconds 100
  if([EBR_UPD_NATIVE]::GetForegroundWindow()-ne$Dialog.Handle){throw "Could not activate the verified NSIS wizard before selecting '$Name'."}
  $rect=[EBR_UPD_RECT]::new();if(-not[EBR_UPD_NATIVE]::GetWindowRect($control.Handle,[ref]$rect)){throw "Could not read the native NSIS radio bounds for '$Name'."}
  $x=[int](($rect.Left+$rect.Right)/2);$y=[int](($rect.Top+$rect.Bottom)/2)
  if(-not[EBR_UPD_NATIVE]::SetCursorPos($x,$y)){throw "Could not place the pointer over the verified NSIS radio '$Name'."}
  [EBR_UPD_NATIVE]::mouse_event(0x0002,0,0,0,[UIntPtr]::Zero);Start-Sleep -Milliseconds 60;[EBR_UPD_NATIVE]::mouse_event(0x0004,0,0,0,[UIntPtr]::Zero);Start-Sleep -Milliseconds 100
  if(-not(Test-NsisNativeRadioSelected $Dialog $Name)){throw "The native NSIS radio '$Name' did not become checked after desktop input."}
  Record 'NSIS native data-retention radio selected on the verified Windows desktop' 'INFO' ([pscustomobject]@{Name=$Name;AutomationId=$control.AutomationId;ProcessId=$control.ProcessId;NativeWindowHandle=$control.Handle.ToInt64();Bounds=$rect;ButtonType=$control.ButtonType;ParentChain=$control.ParentChain;Method='Interactive desktop mouse input; BM_GETCHECK confirmed'})
  return $control.Element
}
function Toggle-Check($Dialog,[string]$Name){$element=Find-Element $Dialog $Name 'ControlType.CheckBox';$pattern=$null;if(-not$element.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern,[ref]$pattern)){throw "Checkbox '$Name' has no accessible toggle action."};$before=$pattern.Current.ToggleState;$pattern.Toggle();return $before}
function Screenshot($Dialog,[string]$Name){$hwnd=$Dialog.Handle;[void][EBR_UPD_NATIVE]::SetForegroundWindow($hwnd);Start-Sleep -Milliseconds 150;$rect=[EBR_UPD_RECT]::new();if(-not[EBR_UPD_NATIVE]::GetWindowRect($hwnd,[ref]$rect)){throw 'Could not read update dialog bounds.'};$w=$rect.Right-$rect.Left;$h=$rect.Bottom-$rect.Top;if($w-lt100-or$h-lt80){throw 'Update dialog has unusable screenshot bounds.'};$bitmap=[Drawing.Bitmap]::new($w,$h);$graphics=[Drawing.Graphics]::FromImage($bitmap);try{$graphics.CopyFromScreen($rect.Left,$rect.Top,0,0,[Drawing.Size]::new($w,$h));$bitmap.Save((Join-Path $EvidenceDirectory $Name),[Drawing.Imaging.ImageFormat]::Png)}finally{$graphics.Dispose();$bitmap.Dispose()}}
function Verify-WindowsSettingsEntry([string]$Version){
  try{[void](Start-Process -FilePath 'ms-settings:appsfeatures' -PassThru -ErrorAction Stop);$settings=Find-Dialog 'Search apps' @() 45}
  catch{Record 'Windows Settings Installed apps UI' 'NOT TESTED' $_.Exception.Message;return}
  $search=Find-Element $settings 'Search apps' 'ControlType.Edit';$value=$null;if(-not$search.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern,[ref]$value)){throw 'Windows Settings app search does not expose a value entry pattern.'};$value.SetValue('Eye Break Reminder')
  $entry=Find-Dialog 'Eye Break Reminder' @($settings.ProcessId) 30;$names=$entry.Names -join ' | ';Assert ($names.Contains('Eye Break Reminder')) 'Eye Break Reminder appears in Windows Settings > Installed apps' $names;Assert ($names.Contains($Version)) 'Windows Settings displays the version installed after the updater' $names;Screenshot $entry 'windows-settings-installed-app-entry.png';[void][EBR_UPD_NATIVE]::PostMessageW($settings.Handle,0x0010,[IntPtr]::Zero,[IntPtr]::Zero);Record 'Windows Settings Installed apps UI' 'PASS' $names
}
function Get-TestOwnedApplications{$prefix=$scriptRoot.TrimEnd('\')+'\';@(Get-CimInstance Win32_Process -Filter "Name='EyeBreakReminder.exe'" -ErrorAction SilentlyContinue|Where-Object{$_.ExecutablePath-and([IO.Path]::GetFullPath([string]$_.ExecutablePath)).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)}|ForEach-Object{Get-Process -Id ([int]$_.ProcessId) -ErrorAction SilentlyContinue}|Where-Object{$null-ne$_})}
function Stop-Application(){
  foreach($p in @(Get-TestOwnedApplications)){
    foreach($hwnd in [EBR_UPD_NATIVE]::Windows($p.Id)){[void][EBR_UPD_NATIVE]::ExitWindow($hwnd)}
    $namedWindow=[EBR_UPD_NATIVE]::FindWindowW('EyeBreakReminder.Native',$null);if($namedWindow-ne[IntPtr]::Zero){$owner=[uint32]0;[void][EBR_UPD_NATIVE]::GetWindowThreadProcessId($namedWindow,[ref]$owner);if($owner-eq$p.Id){[void][EBR_UPD_NATIVE]::ExitWindow($namedWindow)}}
  }
  $watch=[Diagnostics.Stopwatch]::StartNew();$remaining=@(Get-TestOwnedApplications)
  while($watch.Elapsed.TotalSeconds-lt20-and$remaining.Count){Start-Sleep -Milliseconds 100;$remaining=@(Get-TestOwnedApplications)}
  if($remaining.Count){$state=@($remaining|ForEach-Object{[pscustomobject]@{ProcessId=$_.Id;Path=$_.Path;Windows=@([EBR_UPD_NATIVE]::Windows($_.Id)|ForEach-Object{[EBR_UPD_NATIVE]::Title($_)})}});throw "Test-owned updater application did not close through its Exit message: $(ConvertTo-Json $state -Depth 5 -Compress)"}
}
function Remove-ExactTestData(){if(Test-Path -LiteralPath $dataDir){$actual=[IO.Path]::GetFullPath($dataDir);$allowed=[IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'EyeBreakReminder'));if($actual-ine$allowed){throw 'Refusing to remove data outside the test app profile.'};Remove-Item -LiteralPath $actual -Recurse -Force}}
function Reset-Installation(){Stop-Application;if(Test-Path -LiteralPath (Join-Path $installDir 'Uninstall.exe')){$u=Start-Process -FilePath (Join-Path $installDir 'Uninstall.exe') -ArgumentList '/S' -PassThru -Wait;if($u.ExitCode-ne0){throw "Silent test cleanup uninstall returned $($u.ExitCode)."}};if(Test-Path -LiteralPath (Join-Path $installDir 'EyeBreakReminder.exe')){throw 'Test cleanup left an installed executable.'};Remove-ExactTestData;Remove-Item -LiteralPath $installDir -Recurse -Force -ErrorAction SilentlyContinue;Remove-Item -LiteralPath $scriptRoot -Recurse -Force -ErrorAction SilentlyContinue;[void][IO.Directory]::CreateDirectory($scriptRoot);[void][IO.Directory]::CreateDirectory($installDir)}
function Install-Baseline([string]$ExpectedVersion='1.4.0'){Reset-Installation;$p=Start-Process -FilePath ([IO.Path]::GetFullPath($BaselineInstaller)) -ArgumentList @('/S',"/D=$installDir") -PassThru -Wait;if($p.ExitCode-ne0){throw "The actual NSIS baseline installer returned $($p.ExitCode)."};$app=Join-Path $installDir 'EyeBreakReminder.exe';Assert ((Get-Item -LiteralPath $app).VersionInfo.ProductVersion-eq$ExpectedVersion) "baseline NSIS install has v$ExpectedVersion product metadata";Assert ((Get-FileHash -LiteralPath $app -Algorithm SHA256).Hash.ToLowerInvariant()-eq(Get-FileHash -LiteralPath $BaselineExecutable -Algorithm SHA256).Hash.ToLowerInvariant()) 'baseline installed executable matches isolated test binary';$key=Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder' -ErrorAction Stop;Assert ($key.DisplayVersion-eq$ExpectedVersion-and(Test-Path -LiteralPath (Join-Path $installDir 'Uninstall.exe'))) 'Windows Installed Apps registry and uninstaller are registered'}
function Seed-Profile([int]$Theme=2){[void][IO.Directory]::CreateDirectory($dataDir);$settings=@("workMinutes=37","breakSeconds=33","volume=32","theme=$Theme","alarm=0","repeat=1","notifications=0","snooze=0","autoStart=1","startup=0","history=1","breakModeColors=1","customWorkAccent=1","workAccentColor=3900150","customBreakAccent=1","breakAccentColor=16746496","autoCheckUpdates=1","autoDownloadUpdates=0","updateLastCheck=0","restore=1") -join "`n";[IO.File]::WriteAllText((Join-Path $dataDir 'settings.ini'),$settings+"`n",[Text.UTF8Encoding]::new($false));$now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds();[IO.File]::WriteAllText((Join-Path $dataDir 'timer.dat'),"0 0 1200 1200 7 $now",[Text.UTF8Encoding]::new($false));$script:historyText="$($now-120) 1 20`n";[IO.File]::WriteAllText((Join-Path $dataDir 'history.dat'),$script:historyText,[Text.UTF8Encoding]::new($false))}
function Read-SeededSettingsValues([string]$Path){$values=[ordered]@{};foreach($line in [IO.File]::ReadAllLines($Path)){$separator=$line.IndexOf('=');if($separator-le0){continue};$key=$line.Substring(0,$separator);if($key-eq'updateLastCheck'){continue};$values[$key]=$line.Substring($separator+1)};return $values}
function New-ReleaseFixture([string]$SetupSource,[string]$AppSource,[string]$Version='1.4.1',[string]$ReleaseBody='Controlled local Windows updater fixture; no public release is created.'){
  $tag="v$Version";$version=$Version;$setup=(Get-Item -LiteralPath $SetupSource).Length;$app=(Get-Item -LiteralPath $AppSource).Length
  $setupActualHash=(Get-FileHash -LiteralPath $SetupSource -Algorithm SHA256).Hash.ToLowerInvariant();$setupHash=$setupActualHash
  $appHash=(Get-FileHash -LiteralPath $AppSource -Algorithm SHA256).Hash.ToLowerInvariant()
  $root=Split-Path -Parent $PSScriptRoot;$signingTool=Join-Path $root 'build/updater-windows-tests.exe'
  if(-not(Test-Path -LiteralPath $signingTool -PathType Leaf)){throw 'The disposable CNG test signer is missing; refusing to create an unsigned update fixture.'}
  $metadataDirectory=Join-Path $scriptRoot ('signed-release-fixture-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($metadataDirectory)
  $signerOutput=@(& $signingTool --sign-update-manifest $metadataDirectory $SetupSource $AppSource $version 2>&1)
  if($LASTEXITCODE-ne0){throw "The disposable CNG test key could not sign the controlled update fixture. $($signerOutput -join ' ')"}
  $manifestPath=Join-Path $metadataDirectory 'EyeBreakReminder-UpdateManifest.json';$signaturePath=Join-Path $metadataDirectory 'EyeBreakReminder-UpdateManifest.sig';$publicKeyPath=Join-Path $metadataDirectory 'test-update-public-key.bin'
  foreach($path in @($manifestPath,$signaturePath,$publicKeyPath)){if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "The signed local update fixture is missing required metadata: $path"}}
  foreach($name in @('EyeBreakReminder-UpdateManifest.json','EyeBreakReminder-UpdateManifest.sig','test-update-public-key.bin')){Copy-Item -LiteralPath (Join-Path $metadataDirectory $name) -Destination (Join-Path $installDir $name) -Force}
  $manifestSize=(Get-Item -LiteralPath $manifestPath).Length;$signatureSize=(Get-Item -LiteralPath $signaturePath).Length
  $manifestHash=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant();$signatureHash=(Get-FileHash -LiteralPath $signaturePath -Algorithm SHA256).Hash.ToLowerInvariant()
  $baseUrl="https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/download/$tag/"
  $assets=@(
    [pscustomobject]@{name='EyeBreakReminder-Setup-x64.exe';browser_download_url=($baseUrl+'EyeBreakReminder-Setup-x64.exe');size=$setup;digest="sha256:$setupHash"},
    [pscustomobject]@{name='EyeBreakReminder.exe';browser_download_url=($baseUrl+'EyeBreakReminder.exe');size=$app;digest="sha256:$appHash"},
    [pscustomobject]@{name='EyeBreakReminder-UpdateManifest.json';browser_download_url=($baseUrl+'EyeBreakReminder-UpdateManifest.json');size=$manifestSize;digest="sha256:$manifestHash"},
    [pscustomobject]@{name='EyeBreakReminder-UpdateManifest.sig';browser_download_url=($baseUrl+'EyeBreakReminder-UpdateManifest.sig');size=$signatureSize;digest="sha256:$signatureHash"}
  )
  $release=[pscustomobject]@{tag_name=$tag;html_url="https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/tag/$tag";draft=$false;prerelease=$false;body=$ReleaseBody;assets=$assets}
  $fixture="status=200`r`nfailure=none`r`n`r`n"+($release|ConvertTo-Json -Compress -Depth 6);[IO.File]::WriteAllText((Join-Path $installDir 'test-update-response.txt'),$fixture,[Text.UTF8Encoding]::new($false))
  $script:setupSource=[IO.Path]::GetFullPath($SetupSource);$script:appSource=[IO.Path]::GetFullPath($AppSource);$script:setupDigest="sha256:$setupHash";$script:appDigest="sha256:$appHash"
  $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
  if($manifest.schema_version-ne1-or$manifest.application-cne'Eye Break Reminder'-or$manifest.repository-cne'REMEDIOSSAMUEL/EYE-BREAK-REMINDER'-or$manifest.version-cne$version-or$manifest.channel-cne'stable'-or$manifest.architecture-cne'x64'-or$manifest.key_id-notmatch'^p256-[0-9a-f]{16}$'-or@($manifest.assets).Count-ne2){throw 'The disposable signed update fixture has the wrong application, repository, version, channel, architecture, key or asset count.'}
  if($manifest.assets[0].name-cne'EyeBreakReminder-Setup-x64.exe'-or$manifest.assets[0].role-cne'installer'-or$manifest.assets[0].installation_type-cne'installed'-or$manifest.assets[0].architecture-cne'x64'-or$manifest.assets[0].size-ne$setup-or$manifest.assets[0].sha256-cne$setupActualHash){throw 'The disposable test signature does not bind the exact installer payload to this installed-update fixture.'}
  if($manifest.assets[1].name-cne'EyeBreakReminder.exe'-or$manifest.assets[1].role-cne'portable-update'-or$manifest.assets[1].installation_type-cne'portable'-or$manifest.assets[1].architecture-cne'x64'-or$manifest.assets[1].size-ne$app-or$manifest.assets[1].sha256-cne$appHash){throw 'The disposable test signature does not bind the exact portable payload to this portable-update fixture.'}
  if((Get-Item -LiteralPath $signaturePath).Length-ne64-or(Get-Item -LiteralPath $publicKeyPath).Length-ne64){throw 'The disposable P-256 signature or public key has an unexpected encoded length.'}
  Record 'Disposable update fixture has signed metadata bound to both payloads' 'PASS' ([pscustomobject]@{Version=$manifest.version;KeyId=$manifest.keyId;InstallerSHA256=$manifest.assets[0].sha256;PortableSHA256=$manifest.assets[1].sha256;ManifestSHA256=$manifestHash;SignatureBytes=$signatureSize;PublicKeyFileIncluded=$true})
}
function Copy-TestSignedMetadata([string]$DestinationDirectory){
  foreach($name in @('EyeBreakReminder-UpdateManifest.json','EyeBreakReminder-UpdateManifest.sig','test-update-public-key.bin')){
    $source=Join-Path $installDir $name;$destination=Join-Path $DestinationDirectory $name
    if(-not(Test-Path -LiteralPath $source -PathType Leaf)){throw "The installed fixture's signed metadata is missing: $source"}
    Copy-Item -LiteralPath $source -Destination $destination -Force
  }
}
function Start-TestApp([string]$AssetPath=$script:setupSource,[int]$Delay=0,[string]$SkipConfirmVersion='',[string]$ExecutablePath=(Join-Path $installDir 'EyeBreakReminder.exe'),[int]$HoldAfterCleanMs=0){$env:EBR_GUI_TEST_DATA_DIRECTORY=$dataDir;$env:EBR_GUI_TEST_UPDATE_ASSET_PATH=[IO.Path]::GetFullPath($AssetPath);$env:EBR_GUI_TEST_UPDATE_DELAY_MS=[string]$Delay;$env:EBR_GUI_TEST_CONFIRM_TIMEOUT_MS='1000';$env:EBR_GUI_TEST_SKIP_UPDATE_CONFIRM_VERSION=$SkipConfirmVersion;$env:EBR_GUI_TEST_HOLD_AFTER_CLEAN_MS=[string]$HoldAfterCleanMs;$p=Start-Process -FilePath $ExecutablePath -PassThru;return $p.Id}
function Wait-UpdateChoice([int]$appProcessId,[string]$screenshotName='',[string]$ExpectedVersion='v1.4.1',[string]$CurrentVersion='1.4.0',[int]$Timeout=45){$dialog=Find-Dialog 'Eye Break Reminder Update Available' @($appProcessId) $Timeout;Assert ($dialog.WindowTitle-eq'Eye Break Reminder Update') 'UI Automation targets the native update window' $dialog.WindowTitle;$names=@($dialog.Names);$summary=$names -join ' | ';$hasCurrent=@($names|Where-Object{$_.Contains("Current version: $CurrentVersion")}).Count-gt0;$hasAvailableLabel=@($names|Where-Object{$_.Contains('Available version:')}).Count-gt0;$hasAvailableVersion=@($names|Where-Object{$_.Contains($ExpectedVersion)}).Count-gt0;$hasReleaseNotes=@($names|Where-Object{$_.Contains('Release notes')}).Count-gt0;$hasDownloadInstallLabel=@($names|Where-Object{$_.Contains('Download & Install')}).Count-gt0;Assert ($hasCurrent-and$hasAvailableLabel-and$hasAvailableVersion-and$hasReleaseNotes-and$hasDownloadInstallLabel) 'update dialog shows current/available versions, install action and release notes' $summary;if($screenshotName){Screenshot $dialog $screenshotName};$radio=Find-Element $dialog 'Preserve my settings (Recommended)' 'ControlType.RadioButton';$pattern=$null;if(-not$radio.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern,[ref]$pattern)){throw 'Preserve settings radio lacks an accessible selection pattern.'};Assert ($pattern.Current.IsSelected) 'Preserve Settings is the selected default';return $dialog}
function Begin-Download([int]$appProcessId,[bool]$Clean=$false,[bool]$DeleteHistory=$false){$choice=Wait-UpdateChoice $appProcessId;if($Clean){[void](Select-Radio $choice 'Clean install — reset previous settings')};Screenshot $choice ("update-choice-{0}.png" -f $(if($Clean){'clean'}else{'preserve'}));Invoke-Element $choice 'Download & Install';if($Clean){$confirm=Find-Dialog 'Clean Installation' @($appProcessId) 15;$names=$confirm.Names -join ' | ';Assert ($names.Contains('history and statistics will be preserved')) 'clean-install confirmation explains history retention';$checkbox=Find-Element $confirm 'Also delete existing history and statistics' 'ControlType.CheckBox';$toggle=$null;if(-not$checkbox.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern,[ref]$toggle)){throw 'History-delete checkbox lacks an accessible toggle pattern.'};Assert ($toggle.Current.ToggleState-eq[System.Windows.Automation.ToggleState]::Off) 'history deletion is unchecked by default';if($DeleteHistory){[void](Toggle-Check $confirm 'Also delete existing history and statistics');$warningNames=Get-Names $confirm.Root;$confirm.Names=$warningNames;Assert (($warningNames -join ' ').Contains('will also be deleted from this Windows profile')) 'history deletion updates the explicit warning' ($warningNames -join ' | ');Screenshot $confirm 'clean-install-history-warning.png'};Invoke-Element $confirm 'Confirm Clean Install'};$progress=Find-Dialog 'Downloading Eye Break Reminder' @($appProcessId) 30;return $progress}
function Complete-DownloadAndWait([int]$appProcessId,$Progress,[string]$CoordinatorMarker='Update complete.'){
  $ready=Find-Dialog 'Ready to install.' @($appProcessId) 120
  $readyNames=Get-Names $ready.Root;$readySummary=$readyNames -join ' | '
  Assert (($readySummary.Contains('Downloaded:'))-and$readySummary.Contains('(100%)')) 'ready dialog shows complete byte progress' $readySummary
  $bars=@($ready.Root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)|Where-Object{$_.Current.ControlType-eq[System.Windows.Automation.ControlType]::ProgressBar})
  Assert ($bars.Count-eq1) 'download dialog exposes one accessible real progress indicator'
  Assert ($bars[0].Current.Name-eq'Download progress') 'download progress indicator has a screen-reader name' $bars[0].Current.Name
  $range=$null;if(-not$bars[0].TryGetCurrentPattern([System.Windows.Automation.RangeValuePattern]::Pattern,[ref]$range)){throw 'Progress bar lacks the accessible RangeValue pattern.'}
  Assert ($range.Current.Value-eq1000) 'completed download progress range reaches 100 percent' $range.Current.Value
  Screenshot $ready 'update-progress-ready.png';Invoke-Element $ready 'Install Update'
  $coordinator=Find-Dialog $CoordinatorMarker @() 150;Screenshot $coordinator 'update-coordinator-result.png';$names=$coordinator.Names -join ' | ';Record 'Updater coordinator final status' 'INFO' $names;$installationProgress=Find-Element $coordinator 'Installation progress' 'ControlType.ProgressBar';Assert ($installationProgress.Current.Name-eq'Installation progress') 'installation activity indicator has an accessible name';Invoke-Element $coordinator 'Close'
  $watch=[Diagnostics.Stopwatch]::StartNew();while($watch.Elapsed.TotalSeconds-lt20-and(Get-Process -Name coordinator -ErrorAction SilentlyContinue)){Start-Sleep -Milliseconds 100};if(Get-Process -Name coordinator -ErrorAction SilentlyContinue){throw 'The update coordinator did not exit after its result dialog closed.'}
  $updatesRoot=Join-Path $dataDir 'updates';$watch=[Diagnostics.Stopwatch]::StartNew();while($watch.Elapsed.TotalSeconds-lt20-and(Test-Path -LiteralPath $updatesRoot)-and@(Get-ChildItem -LiteralPath $updatesRoot -Force -ErrorAction SilentlyContinue).Count){Start-Sleep -Milliseconds 100};if((Test-Path -LiteralPath $updatesRoot)-and@(Get-ChildItem -LiteralPath $updatesRoot -Force -ErrorAction SilentlyContinue).Count){throw 'The update transaction left a staging directory after normal completion.'}
}
function Wait-InstalledVersion([string]$Version,[int]$Timeout=45){$watch=[Diagnostics.Stopwatch]::StartNew();$app=Join-Path $installDir 'EyeBreakReminder.exe';while($watch.Elapsed.TotalSeconds-lt$Timeout){try{$actual=(Get-Item -LiteralPath $app).VersionInfo.ProductVersion;if($actual-eq$Version){return $actual}}catch{};Start-Sleep -Milliseconds 100};throw "Installed EXE did not reach product version $Version."}
function Assert-PreservedProfile(){ $settings=Get-Content -LiteralPath (Join-Path $dataDir 'settings.ini') -Raw;$history=Get-Content -LiteralPath (Join-Path $dataDir 'history.dat') -Raw;Assert ($settings-match'(?m)^workMinutes=37$'-and$settings-match'(?m)^breakSeconds=33$'-and$settings-match'(?m)^volume=32$') 'normal update preserves timer and alarm preferences';Assert ($settings-match'(?m)^theme=2$'-and$settings-match'(?m)^workAccentColor=3900150$'-and$settings-match'(?m)^breakAccentColor=16746496$'-and$settings-match'(?m)^breakModeColors=1$') 'normal update preserves theme, custom accents and distinct break color';Assert ($settings-match'(?m)^autoCheckUpdates=1$'-and$settings-match'(?m)^autoDownloadUpdates=0$') 'normal update preserves update preferences';Assert ($history-eq$script:historyText) 'normal update preserves history byte-for-byte'}
function Open-UpdatePreferences([int]$appProcessId){$main=Find-Dialog 'Eye Break Reminder' @($appProcessId) 15;[void](Select-Radio $main 'Settings');$main=Find-Dialog 'Eye Break Reminder' @($appProcessId) 15;[void](Select-Radio $main 'About');return Find-Dialog 'Eye Break Reminder' @($appProcessId) 15}
function Start-VisualHotfixChoice([int]$Theme,[string]$ScreenshotName,[string]$ExpectedVersion,[int]$Delay=0){
  Seed-Profile $Theme
  $settingsPath=Join-Path $dataDir 'settings.ini';$settings=[IO.File]::ReadAllText($settingsPath);$settings=[regex]::Replace($settings,'(?m)^autoCheckUpdates=1$','autoCheckUpdates=0');[IO.File]::WriteAllText($settingsPath,$settings,[Text.UTF8Encoding]::new($false))
  $appProcessId=0;$about=$null
  try{
    $appProcessId=Start-TestApp $script:appSource $Delay '' $testExe;$about=Open-UpdatePreferences $appProcessId;Invoke-Element $about 'Check for Updates'
    $dialog=Wait-UpdateChoice $appProcessId $ScreenshotName $ExpectedVersion '1.4.2' 10
  }catch{
    $aboutNames=@();$aboutScreenshot=$null
    if($appProcessId){try{$about=Find-Dialog 'Eye Break Reminder' @($appProcessId) 2;$aboutNames=Get-Names $about.Root;$about.Names=$aboutNames;$aboutScreenshot='update-check-about-diagnostic.png';Screenshot $about $aboutScreenshot}catch{}}
    $responsePath=Join-Path $installDir 'test-update-response.txt';$response=$null
    if(Test-Path -LiteralPath $responsePath){
      $raw=[IO.File]::ReadAllText($responsePath);$separator=$raw.IndexOf("`r`n`r`n");if($separator-lt0){$separator=$raw.IndexOf("`n`n");$delimiterLength=2}else{$delimiterLength=4}
      $release=$null;if($separator-ge0){try{$release=$raw.Substring($separator+$delimiterLength)|ConvertFrom-Json -ErrorAction Stop}catch{}}
      $response=[pscustomobject]@{Path=$responsePath;Bytes=(Get-Item -LiteralPath $responsePath).Length;Header=([IO.File]::ReadLines($responsePath)|Select-Object -First 2);ReleaseTag=$release.tag_name;AssetNames=@($release.assets|ForEach-Object{$_.name});FixtureVersion=$(if(Test-Path -LiteralPath (Join-Path $installDir 'EyeBreakReminder-UpdateManifest.json')){(Get-Content -LiteralPath (Join-Path $installDir 'EyeBreakReminder-UpdateManifest.json') -Raw|ConvertFrom-Json).version}else{$null})}
    }
    Record 'Visual manual-check diagnostic' 'INFO' ([pscustomobject]@{AboutNames=$aboutNames;AboutScreenshot=$aboutScreenshot;Fixture=$response;WaitError=$_.Exception.Message});throw
  }
  return [pscustomobject]@{ProcessId=$appProcessId;Dialog=$dialog}
}
function Read-UpdatePreferences($Dialog){$check=Find-Element $Dialog 'Automatically check for updates' 'ControlType.CheckBox';$download=Find-Element $Dialog 'Automatically download updates (installation always asks first)' 'ControlType.CheckBox';$checkToggle=$null;$downloadToggle=$null;if(-not$check.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern,[ref]$checkToggle)){throw 'Automatic-check preference lacks an accessible toggle state.'};if(-not$download.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern,[ref]$downloadToggle)){throw 'Automatic-download preference lacks an accessible toggle state.'};return [pscustomobject]@{AutoCheck=$checkToggle.Current.ToggleState;AutoDownload=$downloadToggle.Current.ToggleState;DownloadEnabled=$download.Current.IsEnabled}}
function Set-ReleaseFixtureVersion([string]$Version){if($Version-cne'v1.4.1'){throw 'A signed fixture release version cannot be changed without regenerating and re-signing its manifest.'};$path=Join-Path $installDir 'test-update-response.txt';$fixture=[IO.File]::ReadAllText($path);$separator=$fixture.IndexOf([Environment]::NewLine+[Environment]::NewLine);if($separator-lt0){throw 'The preference test update fixture has no HTTP header/body separator.'};$headers=$fixture.Substring(0,$separator);$release=$fixture.Substring($separator+2*[Environment]::NewLine.Length)|ConvertFrom-Json;$release.tag_name=$Version;$release.html_url="https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/tag/$Version";foreach($asset in $release.assets){$asset.browser_download_url="https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/download/$Version/$($asset.name)"};[IO.File]::WriteAllText($path,($headers+[Environment]::NewLine+[Environment]::NewLine+($release|ConvertTo-Json -Compress -Depth 6)),[Text.UTF8Encoding]::new($false))}
function Run-UpdatePreferenceRoundtrip(){
  Install-Baseline;New-ReleaseFixture $UpdateInstaller $UpdateExecutable
  $appProcessId=Start-TestApp;$settings=Open-UpdatePreferences $appProcessId;$state=Read-UpdatePreferences $settings
  Assert ($state.AutoCheck-eq[System.Windows.Automation.ToggleState]::Off) 'fresh-profile automatic update checking defaults off' $state
  Assert ($state.AutoDownload-eq[System.Windows.Automation.ToggleState]::Off-and-not$state.DownloadEnabled) 'fresh-profile automatic downloading defaults off and is disabled until checking is enabled' $state
  [void](Toggle-Check $settings 'Automatically check for updates');$state=Read-UpdatePreferences $settings
  Assert ($state.AutoCheck-eq[System.Windows.Automation.ToggleState]::On-and$state.DownloadEnabled) 'enabling automatic update checks enables the dependent download preference' $state
  [void](Toggle-Check $settings 'Automatically download updates (installation always asks first)');$state=Read-UpdatePreferences $settings
  Assert ($state.AutoCheck-eq[System.Windows.Automation.ToggleState]::On-and$state.AutoDownload-eq[System.Windows.Automation.ToggleState]::On) 'both automatic update preferences can be enabled through the UI' $state
  Stop-Application;$settingsPath=Join-Path $dataDir 'settings.ini';$saved=Get-Content -LiteralPath $settingsPath -Raw
  Assert ($saved-match'(?m)^autoCheckUpdates=1$'-and$saved-match'(?m)^autoDownloadUpdates=1$') 'both enabled preferences persist after application shutdown'
  Set-ReleaseFixtureVersion 'v1.4.1'
  $settingsPath=Join-Path $dataDir 'settings.ini';$beforeSettings=Get-Content -LiteralPath $settingsPath -Raw;$beforeSettingsComparable=[regex]::Replace($beforeSettings,'(?m)^updateLastCheck=\d+$','updateLastCheck=<checked>');$historyPath=Join-Path $dataDir 'history.dat';$now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds();$expectedHistory="$($now-120) 1 20"+[Environment]::NewLine;[IO.File]::WriteAllText($historyPath,$expectedHistory,[Text.UTF8Encoding]::new($false));$historyBefore=[Convert]::ToBase64String([IO.File]::ReadAllBytes($historyPath));$baselineExe=Join-Path $installDir 'EyeBreakReminder.exe';$baselineHash=(Get-FileHash -LiteralPath $baselineExe -Algorithm SHA256).Hash.ToLowerInvariant();$baselineVersion=(Get-Item -LiteralPath $baselineExe).VersionInfo.ProductVersion
  $appProcessId=Start-TestApp;$ready=Find-Dialog 'Ready to install.' @($appProcessId) 120;$readyNames=(Get-Names $ready.Root) -join ' | '
  Assert (($readyNames.Contains('Downloaded:'))-and$readyNames.Contains('(100%)')) 'persisted automatic-download preference completes a verified fixture download with byte progress' $readyNames
  $progressBars=@($ready.Root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)|Where-Object{$_.Current.ControlType-eq[System.Windows.Automation.ControlType]::ProgressBar});Assert ($progressBars.Count-eq1) 'automatic-download ready dialog exposes one progress bar';$range=$null;if(-not$progressBars[0].TryGetCurrentPattern([System.Windows.Automation.RangeValuePattern]::Pattern,[ref]$range)){throw 'Automatic-download progress control lacks an accessible range.'};Assert ($range.Current.Value-eq1000) 'automatic-download progress reaches 100 percent after verification' $range.Current.Value
  $updatesRoot=Join-Path $dataDir 'updates';$stages=@(Get-ChildItem -LiteralPath $updatesRoot -Directory -ErrorAction Stop);Assert ($stages.Count-eq1) 'automatic download stages exactly one private update transaction folder' $stages.Count;$stage=$stages[0].FullName;$stagedInstaller=Join-Path $stage 'EyeBreakReminder-Setup-x64.exe';Assert (Test-Path -LiteralPath $stagedInstaller -PathType Leaf) 'automatic download stages the expected installed-app setup asset';$stagedHash=(Get-FileHash -LiteralPath $stagedInstaller -Algorithm SHA256).Hash.ToLowerInvariant();Assert ($stagedHash-ceq$script:setupDigest.Substring(7)) 'automatically downloaded setup fixture matches its published SHA-256 digest' $stagedHash
  $installButton=Find-Element $ready 'Install Update' 'ControlType.Button';Assert ($installButton.Current.IsEnabled) 'verified automatic download waits for the explicit Install Update action';Assert ((Get-Item -LiteralPath $baselineExe).VersionInfo.ProductVersion-eq$baselineVersion-and(Get-FileHash -LiteralPath $baselineExe -Algorithm SHA256).Hash.ToLowerInvariant()-ceq$baselineHash) 'application executable remains at baseline while waiting for installation confirmation'
  $key=Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder' -ErrorAction Stop;Assert ($key.DisplayVersion-eq'1.4.0') 'Installed Apps registration remains at baseline before user confirmation';$updateCheckValue=[regex]::Match((Get-Content -LiteralPath $settingsPath -Raw),'(?m)^updateLastCheck=([1-9]\d*)$');Assert ($updateCheckValue.Success) 'automatic update check records a successful check before showing downloaded update'
  $ownedCoordinators=@(Get-CimInstance Win32_Process -Filter "Name='coordinator.exe'" -ErrorAction SilentlyContinue|Where-Object{$_.ExecutablePath-and([IO.Path]::GetFullPath([string]$_.ExecutablePath)).StartsWith(([IO.Path]::GetFullPath($updatesRoot).TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase)});Assert ($ownedCoordinators.Count-eq0) 'no installer coordinator launches before the explicit Install Update action'
  Assert ((Find-Element $ready 'Cancel' 'ControlType.Button').Current.IsEnabled) 'verified update can be canceled before installation';Invoke-Element $ready 'Cancel';$settings=Open-UpdatePreferences $appProcessId
  $cancelStatus=Find-Dialog 'The update was not downloaded.' @($appProcessId) 20;Assert ($cancelStatus.ProcessId-eq$appProcessId) 'automatic-download cancellation returns an in-app unchanged-installation status'
  $watch=[Diagnostics.Stopwatch]::StartNew();while($watch.Elapsed.TotalSeconds-lt20-and(Test-Path -LiteralPath $updatesRoot)-and@(Get-ChildItem -LiteralPath $updatesRoot -Force -ErrorAction SilentlyContinue).Count){Start-Sleep -Milliseconds 100};$remainingStages=if(Test-Path -LiteralPath $updatesRoot){@(Get-ChildItem -LiteralPath $updatesRoot -Force -ErrorAction SilentlyContinue).Count}else{0};Assert ($remainingStages-eq0) 'canceling the downloaded update removes its staged installer'
  $afterSettings=Get-Content -LiteralPath $settingsPath -Raw;$afterSettingsComparable=[regex]::Replace($afterSettings,'(?m)^updateLastCheck=\d+$','updateLastCheck=<checked>');Assert ($afterSettingsComparable-ceq$beforeSettingsComparable) 'automatic download and cancellation leave user settings unchanged except the successful-check timestamp'
  Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($historyPath))-ceq$historyBefore) 'automatic download and cancellation preserve history bytes exactly'
  $running=@(Get-TestOwnedApplications);Assert ($running.Count-eq1-and[IO.Path]::GetFullPath($running[0].Path)-ieq[IO.Path]::GetFullPath($baselineExe)) 'baseline application remains running after automatic-download cancellation';Assert ((Get-FileHash -LiteralPath $baselineExe -Algorithm SHA256).Hash.ToLowerInvariant()-ceq$baselineHash) 'baseline executable hash remains unchanged after automatic-download cancellation'
  $state=Read-UpdatePreferences $settings;Assert ($state.AutoCheck-eq[System.Windows.Automation.ToggleState]::On-and$state.AutoDownload-eq[System.Windows.Automation.ToggleState]::On) 'both enabled preference controls remain checked after automatic download and cancellation' $state
  [void](Toggle-Check $settings 'Automatically download updates (installation always asks first)');[void](Toggle-Check $settings 'Automatically check for updates');$state=Read-UpdatePreferences $settings
  Assert ($state.AutoCheck-eq[System.Windows.Automation.ToggleState]::Off-and$state.AutoDownload-eq[System.Windows.Automation.ToggleState]::Off-and-not$state.DownloadEnabled) 'disabling checks turns off and disables the dependent download preference' $state
  Stop-Application;$saved=Get-Content -LiteralPath $settingsPath -Raw;Assert ($saved-match'(?m)^autoCheckUpdates=0$'-and$saved-match'(?m)^autoDownloadUpdates=0$') 'both disabled preferences persist after application shutdown'
  $appProcessId=Start-TestApp;$settings=Open-UpdatePreferences $appProcessId;$state=Read-UpdatePreferences $settings
  Assert ($state.AutoCheck-eq[System.Windows.Automation.ToggleState]::Off-and$state.AutoDownload-eq[System.Windows.Automation.ToggleState]::Off-and-not$state.DownloadEnabled) 'both disabled preference controls remain off after a second relaunch' $state
  Stop-Application;Record 'Automatic update preference defaults and persistence' 'PASS' ([pscustomobject]@{Defaults=@{AutoCheck='Off';AutoDownload='Off'};Enabled=@{AutoCheck='On';AutoDownload='On';CheckTriggeredAfterRelaunch=$true};Disabled=@{AutoCheck='Off';AutoDownload='Off';SecondRelaunch=$true};NoInstallerLaunched=$true})
}
function Run-NormalUpdate(){Install-Baseline;Seed-Profile;New-ReleaseFixture $UpdateInstaller $UpdateExecutable;$appProcessId=Start-TestApp;$progress=Begin-Download $appProcessId;Complete-DownloadAndWait $appProcessId $progress;Assert ((Wait-InstalledVersion '1.4.1')-eq'1.4.1') 'verified NSIS update installs the new application version';$key=Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder';Assert ($key.DisplayVersion-eq'1.4.1') 'Windows Installed Apps version follows the automatic update';Assert-PreservedProfile;Stop-Application;Record 'Normal installed update' 'PASS' ([pscustomobject]@{Baseline=(Get-FileHash -LiteralPath $BaselineExecutable -Algorithm SHA256).Hash.ToLowerInvariant();Installed=(Get-FileHash -LiteralPath (Join-Path $installDir 'EyeBreakReminder.exe') -Algorithm SHA256).Hash.ToLowerInvariant()})}
function Run-DialogThemes(){
  Install-Baseline;New-ReleaseFixture $UpdateInstaller $UpdateExecutable;$oldHc=$false;if(-not[EBR_UPD_NATIVE]::HighContrastState([ref]$oldHc)){throw 'Could not read the disposable runner High Contrast state.'};$scaleSnapshot=Get-RunnerTextScaleSnapshot;$script:updaterScaleMeasurements=@{}
  try{
    if(-not[EBR_UPD_NATIVE]::SetHighContrastState($false)){throw 'Could not disable host High Contrast for the five explicit app-theme cases.'}
    foreach($theme in 0..4){Seed-Profile $theme;$appProcessId=Start-TestApp;$dialog=Wait-UpdateChoice $appProcessId "update-choice-theme-$theme.png";foreach($name in @('Download & Install','Remind Me Later','View Release Notes')){[void](Assert-ControlWithinDialog $dialog $name 'ControlType.Button' "theme $theme")};[void](Assert-ControlWithinDialog $dialog 'Clean install — reset previous settings' 'ControlType.RadioButton' "theme $theme");$radio=Assert-ControlWithinDialog $dialog 'Preserve my settings (Recommended)' 'ControlType.RadioButton' "theme $theme";Assert ($radio.Current.IsKeyboardFocusable) "theme $theme Preserve Settings radio is keyboard-focusable";$radio.SetFocus();Start-Sleep -Milliseconds 100;Assert ($radio.Current.HasKeyboardFocus) "theme $theme exposes a visible UIA keyboard focus target";Screenshot $dialog "update-choice-theme-$theme.png";Assert-ScreenshotHasRenderedContent "update-choice-theme-$theme.png" "theme $theme";Invoke-Element $dialog 'Remind Me Later';Stop-Application}
    Seed-Profile 0;if(-not[EBR_UPD_NATIVE]::SetHighContrastState($true)){throw 'Could not enable host High Contrast for the real Forced Colors update-dialog case.'};$appProcessId=Start-TestApp;$dialog=Wait-UpdateChoice $appProcessId 'update-choice-system-forced-colors.png';Assert (($dialog.Names -join ' | ').Contains('Preserve my settings (Recommended)')) 'forced-colors update dialog retains accessible option names';Screenshot $dialog 'update-choice-system-forced-colors.png';Assert-ScreenshotHasRenderedContent 'update-choice-system-forced-colors.png' 'system Forced Colors';Invoke-Element $dialog 'Remind Me Later';Stop-Application
    if(-not[EBR_UPD_NATIVE]::SetHighContrastState($false)){throw 'Could not restore standard system colors before the text-scale theme matrix.'}
    foreach($textScale in @(125,150,200,225)){
      Set-RunnerTextScale $textScale
      foreach($theme in 0..4){
        Seed-Profile $theme;$longTextCase=($textScale-eq225-and$theme-eq4);$expectedVersion='v1.4.1'
        if($longTextCase){$notes='Long release note marker: '+(('the downloaded release notes must remain scrollable and clipped safely at high text scale. ')*45);Set-LongReleaseFixture $notes}
        $appProcessId=Start-TestApp;$shot="update-choice-theme-$theme-text-scale-$textScale.png";$dialog=Wait-UpdateChoice $appProcessId $shot $expectedVersion
        foreach($name in @('Download & Install','Remind Me Later','View Release Notes')){[void](Assert-ControlWithinDialog $dialog $name 'ControlType.Button' "$textScale% text scale/theme $theme")}
        [void](Assert-ControlWithinDialog $dialog 'Clean install — reset previous settings' 'ControlType.RadioButton' "$textScale% text scale/theme $theme")
        $radio=Assert-ControlWithinDialog $dialog 'Preserve my settings (Recommended)' 'ControlType.RadioButton' "$textScale% text scale/theme $theme";Assert ($radio.Current.IsKeyboardFocusable) "$textScale% text scale/theme $theme has a keyboard-focusable Preserve Settings option";$radio.SetFocus();Start-Sleep -Milliseconds 100;Assert ($radio.Current.HasKeyboardFocus) "$textScale% text scale/theme $theme exposes its focused option";$script:updaterScaleMeasurements["$theme/$textScale"]=$radio.Current.BoundingRectangle;Screenshot $dialog $shot;Assert-ScreenshotHasRenderedContent $shot "$textScale% text scale/theme $theme"
        if($longTextCase){$notesElement=Find-ElementByClass $dialog 'Edit';$notesBounds=$notesElement.Current.BoundingRectangle;$window=[EBR_UPD_RECT]::new();if(-not[EBR_UPD_NATIVE]::GetWindowRect($dialog.Handle,[ref]$window)){throw 'Could not read high-scale release-notes bounds.'};$inside=$notesBounds.Width-gt0-and$notesBounds.Height-gt0-and$notesBounds.Left-ge($window.Left-1)-and$notesBounds.Top-ge($window.Top-1)-and$notesBounds.Right-le($window.Right+1)-and$notesBounds.Bottom-le($window.Bottom+1);$notesStyle=[EBR_UPD_NATIVE]::GetWindowLongW([IntPtr]$notesElement.Current.NativeWindowHandle,-16);$scrollable=($notesStyle-band0x00200000)-ne0;Assert (-not$notesElement.Current.IsOffscreen-and$inside-and$notesElement.Current.IsKeyboardFocusable-and$scrollable) '225% High Contrast Light release notes remain visible, keyboard accessible, scrollable and inside the dialog' ([pscustomobject]@{Bounds=$notesBounds;DialogBounds=$window;IsOffscreen=$notesElement.Current.IsOffscreen;NativeClass=$notesElement.Current.ClassName;ControlType=$notesElement.Current.ControlType.ProgrammaticName;VerticalScrollbar=$scrollable});$valuePattern=$null;$notesText=$notesElement.Current.Name;if($notesElement.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern,[ref]$valuePattern)){$notesText=$valuePattern.Current.Value};Assert ($notesText.Contains('Long release note marker')-and$notesText.EndsWith('…')) 'long release notes retain their beginning and expose a clear truncation marker' ([pscustomobject]@{Characters=$notesText.Length;Marker='Long release note marker';EndsWithTruncation=$notesText.EndsWith('…')})}
        if($theme-eq0){Select-Radio $dialog 'Clean install — reset previous settings'|Out-Null;Invoke-Element $dialog 'Download & Install';$confirm=Find-Dialog 'Clean Installation' @($appProcessId) 15;$confirmNames=$confirm.Names-join' | ';Assert ($confirmNames.Contains('history and statistics will be preserved')) "$textScale% text scale clean-install confirmation explains default retention" $confirmNames;$check=Assert-ControlWithinDialog $confirm 'Also delete existing history and statistics' 'ControlType.CheckBox' "$textScale% clean-install confirmation";$toggle=$null;if(-not$check.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern,[ref]$toggle)){throw 'Scaled clean-install history checkbox lacks an accessible toggle pattern.'};Assert ($toggle.Current.ToggleState-eq[System.Windows.Automation.ToggleState]::Off) "$textScale% clean-install confirmation leaves history deletion unchecked";$null=Assert-ControlWithinDialog $confirm 'Confirm Clean Install' 'ControlType.Button' "$textScale% clean-install confirmation";$null=Assert-ControlWithinDialog $confirm 'Cancel' 'ControlType.Button' "$textScale% clean-install confirmation";$confirmShot="clean-install-confirmation-text-scale-$textScale.png";Screenshot $confirm $confirmShot;Assert-ScreenshotHasRenderedContent $confirmShot "$textScale% clean-install confirmation";Invoke-Element $confirm 'Cancel'}else{Invoke-Element $dialog 'Remind Me Later'}
        Stop-Application
      }
    }
    foreach($theme in 0..4){$small=$script:updaterScaleMeasurements["$theme/125"];$large=$script:updaterScaleMeasurements["$theme/225"];Assert ($large.Height-gt$small.Height) "Windows text scaling changes the updater option height for theme $theme" ([pscustomobject]@{Theme=$theme;At125Percent=$small.Height;At225Percent=$large.Height})}
  }finally{try{Restore-RunnerTextScale $scaleSnapshot}finally{[void][EBR_UPD_NATIVE]::SetHighContrastState($oldHc)}}
  Record 'Update dialog theme, Forced Colors, accessibility and text-scale screenshots' 'PASS' ([pscustomobject]@{AppThemes=@('Follow Windows','Light','Dark','High Contrast Dark','High Contrast Light');SystemForcedColors=$true;TextScaleLevels=@(125,150,200,225);ThemeScaleCombinations=20;LongReleaseNotes=$true;TextScalePreferenceRestored=$true})
}
function Run-VisualHotfix([string]$HotfixTestApplication){
  Reset-Installation
  Install-Baseline '1.4.1'
  # Keep the exact installed-app route for the visual offer and its installer
  # size while exercising the v1.4.2 UI binary in the isolated installation.
  $testExe=Join-Path $installDir 'EyeBreakReminder.exe';Copy-Item -LiteralPath $HotfixTestApplication -Destination $testExe -Force
  $notes=@'
# Eye Break Reminder v1.4.3

This maintenance release retains the existing functionality and appearance.

**Preserve my settings (Recommended)**

## Windows security

The update manifest is signed with the ECDSA P-256 production key.

## Existing validation limitations

- Historical classifications remain unchanged.
- Release-note links are displayed as plain text.
'@
  New-ReleaseFixture $UpdateInstaller $UpdateExecutable '1.4.3' $notes
  $scaleSnapshot=Get-RunnerTextScaleSnapshot;$expectedSize=([Math]::Round((Get-Item -LiteralPath $UpdateInstaller).Length/1MB,1)).ToString('0.0',[Globalization.CultureInfo]::InvariantCulture)+' MB'
  try{
    Set-RunnerTextScale 100
    foreach($theme in @(1,2)){
      $name=if($theme-eq1){'light'}else{'dark'};$visual=Start-VisualHotfixChoice $theme "update-available-$name.png" 'v1.4.3';$appProcessId=$visual.ProcessId;$dialog=$visual.Dialog
      Assert (($dialog.Names -join ' ').Contains("Download size: $expectedSize")) "$name update offer uses the shared download-size formatter"
      $notesText=$dialog.Names -join ' ';Assert ($notesText.Contains('The update manifest is signed with the ECDSA P-256 production key.')-and$notesText.Contains('Existing validation limitations')-and-not$notesText.Contains('**')-and-not$notesText.Contains('## ')) "$name release notes display as readable plain text"
      if($theme-eq2){[void](Select-Radio $dialog 'Clean install — reset previous settings');Screenshot $dialog 'update-options-clean-dark.png';[void](Select-Radio $dialog 'Preserve my settings (Recommended)');Screenshot $dialog 'update-options-preserve-dark.png'}
      Invoke-Element $dialog 'Remind Me Later';Stop-Application
    }
    Set-RunnerTextScale 150;$visual=Start-VisualHotfixChoice 2 'update-available-dark-text-scale-150.png' 'v1.4.3';$appProcessId=$visual.ProcessId;$scaled=$visual.Dialog;Assert (($scaled.Names -join ' ').Contains("Download size: $expectedSize")) '150% text-scale offer remains accessible and reports package size';Invoke-Element $scaled 'Remind Me Later';Stop-Application
    Set-RunnerTextScale 100;$visual=Start-VisualHotfixChoice 2 '' 'v1.4.3' 1200;$appProcessId=$visual.ProcessId;$choice=$visual.Dialog;Invoke-Element $choice 'Download & Install';$download=Find-Dialog 'Downloading Eye Break Reminder' @($appProcessId) 20;Screenshot $download 'download-active-dark.png'
    $watch=[Diagnostics.Stopwatch]::StartNew();$readyText='';while($watch.Elapsed.TotalSeconds-lt60){$download.Names=Get-Names $download.Root;$readyText=$download.Names -join ' ';if($readyText.Contains('Ready to install.')-and$readyText.Contains('SHA-256 digest matches GitHub')){break};Start-Sleep -Milliseconds 100}
    Assert ($readyText.Contains('Ready to install.')-and$readyText.Contains('SHA-256 digest matches GitHub')) 'download completion exposes its verified ready state' $readyText;Assert ($readyText.Contains("Downloaded: $expectedSize / $expectedSize")) 'offer and download completion show the same package size' $readyText;Screenshot $download 'download-ready-dark.png';$install=Find-Element $download 'Install Update' 'ControlType.Button';Assert ($install.Current.IsEnabled) 'Install Update is enabled only after the fixture download verifies';Invoke-Element $download 'Cancel';Stop-Application
    foreach($outcome in @('success','failure')){$arguments="--test-coordinator-$outcome";$process=Start-Process -FilePath $testExe -ArgumentList $arguments -PassThru;$coordinator=Find-Dialog 'Eye Break Reminder Update' @($process.Id) 20;Start-Sleep -Milliseconds 500;$coordinator.Names=Get-Names $coordinator.Root;$visible=$coordinator.Names -join ' ';if($outcome-eq'success'){Assert ($visible.Contains('Update complete. The new version started successfully.')) 'coordinator success text matches its completed state'}else{Assert ($visible.Contains('The update failed. The previous version and its data were restored.')) 'coordinator failure text does not claim success'};$progress=Find-Element $coordinator 'Installation progress' 'ControlType.ProgressBar';Assert ($progress.Current.Name-eq'Installation progress') "$outcome coordinator keeps its named progress control";Screenshot $coordinator "coordinator-$outcome-dark.png";Invoke-Element $coordinator 'Close';if(-not$process.WaitForExit(5000)){throw "Coordinator $outcome visual fixture did not close."}}
    Stop-Application;Reset-Installation;Record 'Focused updater visual hotfix screenshots' 'PASS' ([pscustomobject]@{Themes=@('Light','Dark');TextScalePercent=150;Screenshots=@('update-available-light.png','update-available-dark.png','update-options-clean-dark.png','update-options-preserve-dark.png','update-available-dark-text-scale-150.png','download-active-dark.png','download-ready-dark.png','coordinator-success-dark.png','coordinator-failure-dark.png');ProductionTrustBypassed=$false;OnlyLocalTestManifest=$true})
  }finally{try{Stop-Application}catch{};Restore-RunnerTextScale $scaleSnapshot}
}
function Run-ActiveBreakDeferral(){
  Install-Baseline;Seed-Profile;$settingsPath=Join-Path $dataDir 'settings.ini';$settings=Get-Content -LiteralPath $settingsPath -Raw;# GUI-test monotonic time runs 10x; use the maximum supported break so UIA setup cannot consume the test interval.
  $settings=$settings.Replace('breakSeconds=33','breakSeconds=300');[IO.File]::WriteAllText($settingsPath,$settings,[Text.UTF8Encoding]::new($false));New-ReleaseFixture $UpdateInstaller $UpdateExecutable;$fixture=Get-Content -LiteralPath (Join-Path $installDir 'test-update-response.txt') -Raw;$fixture=$fixture.Replace('failure=none',"failure=none`r`ndelay_ms=3000");[IO.File]::WriteAllText((Join-Path $installDir 'test-update-response.txt'),$fixture,[Text.UTF8Encoding]::new($false))
  Record 'Active-break update fixture prepared' 'INFO' ([pscustomobject]@{Scenario='ActiveBreakDeferral';BreakSeconds=300;DiscoveryDelayMs=3000;TestKeyOnly=$true})
  $appProcessId=Start-TestApp;$main=Find-Dialog 'Eye Break Reminder' @($appProcessId) 15;Invoke-Element $main 'Take a break now';$break=Find-Dialog 'Taking an eye break' @($appProcessId) 10;Start-Sleep -Seconds 4;Assert (Test-ProcessDialog $appProcessId 'Taking an eye break') 'the manually started break remains active while update discovery finishes';Assert (-not(Test-ProcessDialog $appProcessId 'Eye Break Reminder Update Available')) 'automatic update prompt is deferred through an active eye break'
  $diagnosticPath=Join-Path $installDir 'test-update-modal-diagnostic.txt';$watch=[Diagnostics.Stopwatch]::StartNew();$diagnostics='';while($watch.Elapsed.TotalSeconds-lt15){if(Test-Path -LiteralPath $diagnosticPath){$diagnostics=[IO.File]::ReadAllText($diagnosticPath);if($diagnostics.Contains('available-update-deferred-active-break')){break}};Start-Sleep -Milliseconds 100}
  Assert ($diagnostics.Contains('available-update-deferred-active-break')) 'authenticated update result arrives and is deferred during the active break' $diagnostics
  Screenshot $break 'update-waiting-during-break.png';Invoke-Element $break "I'm back";$watch.Restart();while($watch.Elapsed.TotalSeconds-lt15){if(Test-Path -LiteralPath $diagnosticPath){$diagnostics=[IO.File]::ReadAllText($diagnosticPath);if($diagnostics.Contains('deferred-update-dispatch')-and$diagnostics.Contains('update-choice-requested')){break}};Start-Sleep -Milliseconds 100}
  Assert ($diagnostics.Contains('deferred-update-dispatch')) 'ending the break dispatches the deferred authenticated update' $diagnostics
  Assert ($diagnostics.Contains('update-choice-requested')) 'the deferred update reaches the update-choice UI' $diagnostics
  $choice=Wait-UpdateChoice $appProcessId;$hasAvailableLabel=@($choice.Names|Where-Object{$_.Contains('Available version:')}).Count-gt0;$hasAvailableVersion=@($choice.Names|Where-Object{$_.Contains('v1.4.1')}).Count-gt0;Assert ($hasAvailableLabel-and$hasAvailableVersion) 'deferred update prompt appears after the break ends';Invoke-Element $choice 'Remind Me Later';Stop-Application;[void](Save-ActiveBreakDiagnostics);Record 'Active break update deferral' 'PASS'
}
function Run-CleanUpdate([bool]$DeleteHistory){
  Install-Baseline;Seed-Profile 1;New-ReleaseFixture $UpdateInstaller $UpdateExecutable;$appProcessId=Start-TestApp;$progress=Begin-Download $appProcessId $true $DeleteHistory;Complete-DownloadAndWait $appProcessId $progress;[void](Wait-InstalledVersion '1.4.1')
  $settingsPath=Join-Path $dataDir 'settings.ini';if(Test-Path -LiteralPath $settingsPath){$settings=Get-Content -LiteralPath $settingsPath -Raw;Assert (-not($settings-match'(?m)^workMinutes=37$')-and-not($settings-match'(?m)^workAccentColor=3900150$')) 'clean update replaced nondefault settings with defaults'}else{Assert $true 'clean update removed previous preferences before first default save'}
  if($DeleteHistory){Assert (-not(Test-Path -LiteralPath (Join-Path $dataDir 'history.dat'))) 'confirmed clean update deleted only selected history/statistics'}else{Assert ((Get-Content -LiteralPath (Join-Path $dataDir 'history.dat') -Raw)-eq$script:historyText) 'clean update preserves history when its separate option is unchecked'}
  Stop-Application;$u=Start-Process -FilePath (Join-Path $installDir 'Uninstall.exe') -ArgumentList '/S' -PassThru -Wait;Assert ($u.ExitCode-eq0-and-not(Test-Path -LiteralPath (Join-Path $installDir 'EyeBreakReminder.exe'))) 'updated clean installation can be silently uninstalled';if(-not$DeleteHistory){Assert ((Get-Content -LiteralPath (Join-Path $dataDir 'history.dat') -Raw)-eq$script:historyText) 'silent uninstall after clean install keeps preserved history'}else{Assert (-not(Test-Path -LiteralPath (Join-Path $dataDir 'history.dat'))) 'silent uninstall does not recreate previously removed history'}
  Record $(if($DeleteHistory){'Clean update including history removal'}else{'Clean update preserving history'}) 'PASS'
}
function Run-InterruptedCleanRecovery(){
  Install-Baseline;Seed-Profile 1;New-ReleaseFixture $UpdateInstaller $UpdateExecutable
  $runKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';$runKeyHandle=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Run',$false);if($null-eq$runKeyHandle){throw 'The disposable runner has no current-user Startup Run registry key.'};try{$existingStartup=$runKeyHandle.GetValue('EyeBreakReminder',$null)}finally{$runKeyHandle.Dispose()};Assert ($null-eq$existingStartup) 'disposable runner has no preexisting Eye Break Reminder startup value';$startupCommand='"'+(Join-Path $installDir 'EyeBreakReminder.exe')+'" --startup';New-ItemProperty -LiteralPath $runKey -Name 'EyeBreakReminder' -Value $startupCommand -PropertyType String|Out-Null
  $settingsPath=Join-Path $dataDir 'settings.ini';$settings=[regex]::Replace((Get-Content -LiteralPath $settingsPath -Raw),'(?m)^startup=0$','startup=1');[IO.File]::WriteAllText($settingsPath,$settings,[Text.UTF8Encoding]::new($false));$beforeExe=(Get-FileHash -LiteralPath (Join-Path $installDir 'EyeBreakReminder.exe') -Algorithm SHA256).Hash.ToLowerInvariant();$beforeHistory=(Get-FileHash -LiteralPath (Join-Path $dataDir 'history.dat') -Algorithm SHA256).Hash.ToLowerInvariant()
  $appProcessId=Start-TestApp $script:setupSource 0 '' (Join-Path $installDir 'EyeBreakReminder.exe') 30000;$progress=Begin-Download $appProcessId $true $false;$ready=Find-Dialog 'Ready to install.' @($appProcessId) 120;$readyNames=Get-Names $ready.Root;Assert (($readyNames -join ' ').Contains('Ready to install.')) 'interrupted-clean update verifies the complete package before installation';Invoke-Element $ready 'Install Update'
  $updatesRoot=Join-Path $dataDir 'updates';$watch=[Diagnostics.Stopwatch]::StartNew();$stage=$null
  while($watch.Elapsed.TotalSeconds-lt90-and-not$stage){foreach($candidate in @(Get-ChildItem -LiteralPath $updatesRoot -Directory -ErrorAction SilentlyContinue)){ $statePath=Join-Path $candidate.FullName 'transaction-state.ini';$state=if(Test-Path -LiteralPath $statePath){Get-Content -LiteralPath $statePath -Raw}else{''};if($state-match'(?m)^phase=cleaning\r?$'-and-not(Test-Path -LiteralPath $settingsPath)-and-not(Test-Path -LiteralPath (Join-Path $dataDir 'timer.dat'))){$stage=$candidate.FullName;break} };if(-not$stage){Start-Sleep -Milliseconds 50}}
  Assert ([bool]$stage) 'confirmed clean transaction reaches the durable cleaning phase before recovery' $stage
  Assert ((Test-Path -LiteralPath (Join-Path $dataDir 'history.dat'))-and((Get-FileHash -LiteralPath (Join-Path $dataDir 'history.dat') -Algorithm SHA256).Hash.ToLowerInvariant()-eq$beforeHistory)) 'clean transaction has not removed unselected history before interruption'
  $transactionPath=Join-Path $stage 'transaction.ini';$coordinatorPath=Join-Path $stage 'coordinator.exe';$runOnceHandle=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\RunOnce',$false);if($null-eq$runOnceHandle){throw 'The disposable runner has no RunOnce key for the pending recovery transaction.'};try{if($runOnceHandle.GetValueNames()-notcontains'!EyeBreakReminderUpdateRecovery'){throw 'The coordinator did not register the expected RunOnce recovery value.'};$registeredKind=$runOnceHandle.GetValueKind('!EyeBreakReminderUpdateRecovery');$registered=$runOnceHandle.GetValue('!EyeBreakReminderUpdateRecovery',$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)}finally{$runOnceHandle.Dispose()}
  $quotedCoordinator='"'+$coordinatorPath+'"';$compactCommand=$quotedCoordinator+' --update-recover';$fullCommand=$compactCommand+' "'+$transactionPath+'"';$expected=if($fullCommand.Length-le260){$fullCommand}elseif($compactCommand.Length-le260){$compactCommand}else{throw 'The recovery command cannot fit within the documented RunOnce command-line limit.'}
  Assert ($registeredKind-eq[Microsoft.Win32.RegistryValueKind]::String-and$registered-ceq$expected-and$registered.Length-le260) 'RunOnce recovery registration is the exact bounded REG_SZ staged-coordinator command' ([pscustomobject]@{Command=$registered;Kind=$registeredKind;Length=$registered.Length;Compact=($expected-ceq$compactCommand)})
  Assert ((Get-Item -LiteralPath (Join-Path $installDir 'EyeBreakReminder.exe')).VersionInfo.ProductVersion-eq'1.4.1') 'new version is installed before the simulated interruption'
  $coordinator=Get-CimInstance Win32_Process -Filter "Name='coordinator.exe'"|Where-Object{$_.ExecutablePath-ieq$coordinatorPath}|Select-Object -First 1
  Assert ([bool]$coordinator) 'the isolated update coordinator is waiting at the clean-recovery pause'
  Stop-Process -Id ([int]$coordinator.ProcessId) -Force;Start-Sleep -Milliseconds 500
  Assert (-not(Get-Process -Id ([int]$coordinator.ProcessId) -ErrorAction SilentlyContinue)) 'simulated abrupt coordinator loss leaves no coordinator process'
  Assert ((Test-Path -LiteralPath (Join-Path $stage 'previous.exe'))-and((Get-FileHash -LiteralPath (Join-Path $stage 'previous.exe') -Algorithm SHA256).Hash.ToLowerInvariant()-eq$beforeExe)) 'durable recovery keeps the exact previous executable while settings are reset'
  Assert (-not(Test-Path -LiteralPath $settingsPath)-and-not(Test-Path -LiteralPath (Join-Path $dataDir 'timer.dat'))) 'interruption fixture reaches the destructive settings boundary before recovery'
  Remove-Item Env:EBR_GUI_TEST_UPDATE_ASSET_PATH,Env:EBR_GUI_TEST_HOLD_AFTER_CLEAN_MS -ErrorAction SilentlyContinue
  $priorConfirmTimeout=$env:EBR_GUI_TEST_CONFIRM_TIMEOUT_MS;$env:EBR_GUI_TEST_CONFIRM_TIMEOUT_MS='8000'
  $recoveryArguments=$registered.Substring($quotedCoordinator.Length).TrimStart()
  try{$recovery=Start-Process -FilePath $coordinatorPath -ArgumentList $recoveryArguments -PassThru}
  finally{if($null-eq$priorConfirmTimeout){Remove-Item Env:EBR_GUI_TEST_CONFIRM_TIMEOUT_MS -ErrorAction SilentlyContinue}else{$env:EBR_GUI_TEST_CONFIRM_TIMEOUT_MS=$priorConfirmTimeout}}
  if(-not$recovery.WaitForExit(60000)){
    $dialogs=[Collections.Generic.List[string]]::new();foreach($hwnd in [EBR_UPD_NATIVE]::Windows($recovery.Id)){ $root=Get-Root $hwnd;if($root){$dialogs.Add((Get-Names $root)-join ' | ')} }
    $diagnostics=$dialogs -join ' || '
    Stop-Process -Id $recovery.Id -Force -ErrorAction SilentlyContinue
    throw "Interrupted-update recovery coordinator did not exit within 60 seconds. Visible recovery UI: $diagnostics"
  }
  $recovery.Refresh()
  Assert ($recovery.ExitCode-eq0) 'registered recovery command completes after an interrupted clean update' $recovery.ExitCode
  Assert ((Wait-InstalledVersion '1.4.0')-eq'1.4.0') 'interrupted clean update restores the previous application version'
  Assert ((Get-FileHash -LiteralPath (Join-Path $installDir 'EyeBreakReminder.exe') -Algorithm SHA256).Hash.ToLowerInvariant()-eq$beforeExe) 'recovery restores the byte-identical previous executable'
  $installed=Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder' -ErrorAction Stop;Assert ($installed.DisplayVersion-eq'1.4.0') 'recovery restores the prior Installed Apps version'
  Assert ((Get-Content -LiteralPath $settingsPath -Raw)-match'(?m)^workMinutes=37$'-and(Get-Content -LiteralPath $settingsPath -Raw)-match'(?m)^startup=1$') 'recovery restores the previous settings and startup preference'
  Assert ((Get-Content -LiteralPath (Join-Path $dataDir 'history.dat') -Raw)-eq$script:historyText-and(Get-FileHash -LiteralPath (Join-Path $dataDir 'history.dat') -Algorithm SHA256).Hash.ToLowerInvariant()-eq$beforeHistory) 'recovery preserves history byte-for-byte'
  $restoredRun=Get-ItemPropertyValue -LiteralPath $runKey -Name 'EyeBreakReminder' -ErrorAction Stop;Assert ($restoredRun-ceq$startupCommand) 'recovery restores the prior Windows startup registration' $restoredRun
  $remaining=Get-ItemPropertyValue -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name '!EyeBreakReminderUpdateRecovery' -ErrorAction SilentlyContinue
  Assert ($remaining-ceq$registered) 'manual recovery leaves the exact !RunOnce value for Windows post-command handling' ([pscustomobject]@{Command=$remaining})
  Remove-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name '!EyeBreakReminderUpdateRecovery' -ErrorAction Stop
  Assert (-not(Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name '!EyeBreakReminderUpdateRecovery' -ErrorAction SilentlyContinue)) 'disposable harness models only exact-value RunOnce deletion after automatic command execution'
  $restoredExe=[IO.Path]::GetFullPath((Join-Path $installDir 'EyeBreakReminder.exe'));$launchWatch=[Diagnostics.Stopwatch]::StartNew();$runningPid=0;$runningPath='';$runningWindow=[IntPtr]::Zero;$runningWindowClass=''
  while($launchWatch.Elapsed.TotalSeconds-lt20-and$runningPid-eq0){
    # FindWindow returns only the first desktop window with a class name. During transaction tests another app instance can
    # own that class, so enumerate windows by the exact restored process and verify its own class/title and image path.
    foreach($candidate in @(Get-TestOwnedApplications)){
      $candidate.Refresh();if($candidate.HasExited-or([IO.Path]::GetFullPath([string]$candidate.Path)-ine$restoredExe)){continue}
      foreach($window in [EBR_UPD_NATIVE]::Windows($candidate.Id)){
        $className=[EBR_UPD_NATIVE]::ClassName($window);$title=[EBR_UPD_NATIVE]::Title($window)
        if($className-ceq'EyeBreakReminder.Native'-and$title-ceq'Eye Break Reminder'){$runningPid=$candidate.Id;$runningPath=[string]$candidate.Path;$runningWindow=$window;$runningWindowClass=$className;break}
      }
      if($runningPid-gt0){break}
    }
    if($runningPid-eq0){Start-Sleep -Milliseconds 100}
  }
  $launchDetails=[pscustomobject]@{ElapsedSeconds=[Math]::Round($launchWatch.Elapsed.TotalSeconds,2);ExpectedPath=$restoredExe;ProcessId=$runningPid;ProcessPath=$runningPath;WindowHandle=('0x{0:X}' -f $runningWindow.ToInt64());WindowClass=$runningWindowClass;WindowTitle=$(if($runningWindow-ne[IntPtr]::Zero){[EBR_UPD_NATIVE]::Title($runningWindow)}else{$null});MatchingProcesses=@(Get-TestOwnedApplications|ForEach-Object{[pscustomobject]@{ProcessId=$_.Id;Path=$_.Path;MainWindowHandle=('0x{0:X}' -f $_.MainWindowHandle.ToInt64())}})}
  Assert ($runningPid-gt0-and$runningWindow-ne[IntPtr]::Zero) 'the restored previous version launched after durable recovery' $launchDetails
  $cleanupWatch=[Diagnostics.Stopwatch]::StartNew();while((Test-Path -LiteralPath $stage)-and$cleanupWatch.Elapsed.TotalSeconds-lt20){Start-Sleep -Milliseconds 200};Assert (-not(Test-Path -LiteralPath $stage)) 'restored app cleans the owned recovery stage after simulated OS RunOnce deletion' ([pscustomobject]@{ElapsedSeconds=[Math]::Round($cleanupWatch.Elapsed.TotalSeconds,2)})
  Stop-Application;$currentStartup=Get-ItemPropertyValue -LiteralPath $runKey -Name 'EyeBreakReminder' -ErrorAction SilentlyContinue;if($currentStartup-ceq$startupCommand){Remove-ItemProperty -LiteralPath $runKey -Name 'EyeBreakReminder' -ErrorAction Stop};Record 'Interrupted clean update and RunOnce recovery' 'PASS' ([pscustomobject]@{Phase='cleaning';RestoredVersion='1.4.0';SettingsRestored=$true;HistoryPreserved=$true;StartupRestored=$true;ComputerRebooted=$false;AutomaticRunOnceInvocation=$false})
}
function Run-CancelAndHashFailure([bool]$Mismatch,[string]$ProgressScreenshotName='download-cancel-progress.png',[switch]$ReturnMetrics){
  Install-Baseline;Seed-Profile;New-ReleaseFixture $UpdateInstaller $UpdateExecutable
  $progressBounds=$null
  if($Mismatch){$assetPath=Join-Path $scriptRoot 'corrupt-setup.exe';Copy-Item -LiteralPath $UpdateInstaller -Destination $assetPath;$bytes=[IO.File]::ReadAllBytes($assetPath);$bytes[$bytes.Length-1]=$bytes[$bytes.Length-1]-bxor 0x01;[IO.File]::WriteAllBytes($assetPath,$bytes);$delay=0}
  else{$assetPath=Join-Path $scriptRoot 'slow-fixture.bin';$bytes=[byte[]]::new(2*1024*1024);[Security.Cryptography.RandomNumberGenerator]::Fill($bytes);[IO.File]::WriteAllBytes($assetPath,$bytes);$delay=250;New-ReleaseFixture $assetPath $UpdateExecutable}
  $before=(Get-FileHash -LiteralPath (Join-Path $installDir 'EyeBreakReminder.exe') -Algorithm SHA256).Hash;$appProcessId=Start-TestApp $assetPath $delay;$download=Begin-Download $appProcessId
  if($Mismatch){$failed=Find-Dialog 'SHA-256 integrity check' @($appProcessId) 60;Screenshot $failed 'hash-mismatch-rejected.png'}
  else{
    Screenshot $download $ProgressScreenshotName
    $windowRect=[EBR_UPD_RECT]::new();if(-not[EBR_UPD_NATIVE]::GetWindowRect($download.Handle,[ref]$windowRect)){throw 'Could not read the live download-progress window bounds.'};$progressBounds=[pscustomobject]@{Left=$windowRect.Left;Top=$windowRect.Top;Width=$windowRect.Right-$windowRect.Left;Height=$windowRect.Bottom-$windowRect.Top}
    $watch=[Diagnostics.Stopwatch]::StartNew();$observed=$false
    while($watch.Elapsed.TotalSeconds-lt10){$download.Names=Get-Names $download.Root;if(($download.Names -join ' ')-match'Downloaded:\s*[1-9]'){$observed=$true;break};Start-Sleep -Milliseconds 100}
    Assert $observed 'cancel test observed nonzero byte progress'
    $progressBars=@($download.Root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)|Where-Object{$_.Current.ControlType-eq[System.Windows.Automation.ControlType]::ProgressBar})
    Assert ($progressBars.Count-eq1) 'in-progress dialog exposes one accessible progress bar'
    Assert ($progressBars[0].Current.Name-eq'Download progress') 'in-progress download indicator has a screen-reader name' $progressBars[0].Current.Name
    $range=$null
    if(-not$progressBars[0].TryGetCurrentPattern([System.Windows.Automation.RangeValuePattern]::Pattern,[ref]$range)){throw 'Progress bar lacks the accessible RangeValue pattern.'}
    $initialValue=$range.Current.Value
    Assert ($initialValue-gt0) 'accessible progress range reports nonzero download progress' $initialValue
    Start-Sleep -Seconds 3
    $nextValue=$range.Current.Value
    Assert ($nextValue-gt$initialValue) 'accessible progress range advances during the download' ([pscustomobject]@{Before=$initialValue;After=$nextValue})
    $download.Names=Get-Names $download.Root
    Assert (($download.Names -join ' ')-match'Downloaded:\s*[1-9]') 'slow download continues reporting byte progress before cancellation'
    Invoke-Element $download 'Cancel';$failed=Find-Dialog 'Download cancelled' @($appProcessId) 30
  }
  $text=$failed.Names -join ' | ';Assert ($text.Contains('currently installed application and its settings are unchanged')) $(if($Mismatch){'hash mismatch reports rejection without execution'}else{'cancel reports that current application remains unchanged'}) $text;Invoke-Element $failed 'Cancel';Start-Sleep -Milliseconds 500
  Assert ((Get-FileHash -LiteralPath (Join-Path $installDir 'EyeBreakReminder.exe') -Algorithm SHA256).Hash-eq$before) $(if($Mismatch){'invalid digest never executes installer'}else{'cancelling download leaves baseline executable unchanged'});Assert (-not(Get-Process -Name coordinator -ErrorAction SilentlyContinue)) 'verification failure/cancellation does not start an installer coordinator';Assert ((Get-Content -LiteralPath (Join-Path $dataDir 'history.dat') -Raw)-eq$script:historyText) 'failed/cancelled download preserves existing history';Stop-Application
  if(-not$Mismatch){$timerFields=(Get-Content -LiteralPath (Join-Path $dataDir 'timer.dat') -Raw).Trim() -split '\s+';$remaining=[double]::Parse($timerFields[2],[Globalization.CultureInfo]::InvariantCulture);Assert ($remaining-lt1197) 'the timer countdown advances while the slow update download runs' $remaining}
  Record $(if($Mismatch){'Corrupt update SHA-256'}else{'Download cancellation and timer continuity'}) 'PASS';if($ReturnMetrics){return $progressBounds}
}
function Run-ScaledProgress(){
  $scaleSnapshot=Get-RunnerTextScaleSnapshot
  $measurements=@{}
  try{foreach($textScale in @(125,150,200,225)){Set-RunnerTextScale $textScale;$measurements[$textScale]=Run-CancelAndHashFailure $false "download-cancel-progress-text-scale-$textScale.png" -ReturnMetrics};Assert ($measurements[225].Width-gt$measurements[125].Width) 'the visible download-progress dialog grows with Windows text scale' ([pscustomobject]@{At125Percent=$measurements[125];At225Percent=$measurements[225]})}
  finally{Restore-RunnerTextScale $scaleSnapshot}
  Record 'Accessible download progress at Windows text scales' 'PASS' ([pscustomobject]@{TextScaleLevels=@(125,150,200,225);ProgressName='Download progress';RangeValuePattern=$true;AdvancingProgress=$true;Cancellation=$true;TextScalePreferenceRestored=$true})
}
function Run-InterruptedDownloadRecovery(){
  Install-Baseline;Seed-Profile;New-ReleaseFixture $UpdateInstaller $UpdateExecutable
  $assetPath=Join-Path $scriptRoot 'interrupted-setup.exe';$payload=[IO.File]::ReadAllBytes($UpdateInstaller);$partial=[byte[]]::new($payload.Length-16384);[Array]::Copy($payload,$partial,$partial.Length);[IO.File]::WriteAllBytes($assetPath,$partial)
  $before=(Get-FileHash -LiteralPath (Join-Path $installDir 'EyeBreakReminder.exe') -Algorithm SHA256).Hash;$appProcessId=Start-TestApp $assetPath;$progress=Begin-Download $appProcessId;$failure=Find-Dialog 'fixture copy was interrupted' @($appProcessId) 30
  Assert (($failure.Names -join ' ').Contains('currently installed application and its settings are unchanged')) 'interrupted update stream reports safe failure';Screenshot $failure 'interrupted-download-rejected.png';Invoke-Element $failure 'Cancel';Start-Sleep -Milliseconds 500
  Assert ((Get-FileHash -LiteralPath (Join-Path $installDir 'EyeBreakReminder.exe') -Algorithm SHA256).Hash-eq$before) 'interrupted stream leaves the prior executable unchanged';Assert ((Get-Content -LiteralPath (Join-Path $dataDir 'history.dat') -Raw)-eq$script:historyText) 'interrupted stream preserves user history';Stop-Application
  $updatesRoot=Join-Path $dataDir 'updates';Assert ((Test-Path -LiteralPath $updatesRoot)-and@(Get-ChildItem -LiteralPath $updatesRoot -Force).Count-eq0) 'interrupted stream removes its partial staging transaction'
  [IO.File]::WriteAllBytes($assetPath,$payload);$settingsPath=Join-Path $dataDir 'settings.ini';$settings=[regex]::Replace((Get-Content -LiteralPath $settingsPath -Raw),'(?m)^updateLastCheck=\d+$','updateLastCheck=0');[IO.File]::WriteAllText($settingsPath,$settings,[Text.UTF8Encoding]::new($false));$appProcessId=Start-TestApp $assetPath;$progress=Begin-Download $appProcessId;Complete-DownloadAndWait $appProcessId $progress;Assert ((Wait-InstalledVersion '1.4.1')-eq'1.4.1') 'successful retry installs after an interrupted stream';Assert-PreservedProfile;Stop-Application;Record 'Interrupted stream recovery and successful retry' 'PASS'
}
function Run-InstallerFailure(){
  Install-Baseline;Seed-Profile
  $app=Join-Path $installDir 'EyeBreakReminder.exe';$readme=Join-Path $installDir 'README.md'
  $settings=Join-Path $dataDir 'settings.ini';$timer=Join-Path $dataDir 'timer.dat';$history=Join-Path $dataDir 'history.dat'
  $before=[pscustomobject]@{
    Executable=(Get-FileHash -LiteralPath $app -Algorithm SHA256).Hash.ToLowerInvariant()
    Readme=(Get-FileHash -LiteralPath $readme -Algorithm SHA256).Hash.ToLowerInvariant()
    Settings=(Read-SeededSettingsValues $settings)
    History=(Get-FileHash -LiteralPath $history -Algorithm SHA256).Hash.ToLowerInvariant()
  }
  $mutationMarker=Join-Path $scriptRoot 'partial-install-mutation.txt'
  Assert (-not(Test-Path -LiteralPath $mutationMarker)) 'partial-install failure fixture starts without a stale mutation marker'
  New-ReleaseFixture $FailingInstaller $UpdateExecutable
  $appProcessId=Start-TestApp;$choice=Wait-UpdateChoice $appProcessId;$progress=Begin-Download $appProcessId;$choice=$null
  Complete-DownloadAndWait $appProcessId $progress 'The update failed.'
  Assert ((Wait-InstalledVersion '1.4.0')-eq'1.4.0') 'failed installer transaction restores the previous product version'
  Assert ((Get-Content -LiteralPath $mutationMarker -Raw)-ceq"partial-install-mutation-v1;expected-installer-exit=37`r`n") 'controlled installer fixture changed existing install files and registry before returning its failure code'
  $afterExecutable=(Get-FileHash -LiteralPath $app -Algorithm SHA256).Hash.ToLowerInvariant()
  Assert ($afterExecutable-ceq$before.Executable) 'partial-install rollback restores the exact previous application executable hash' $afterExecutable
  $afterReadme=(Get-FileHash -LiteralPath $readme -Algorithm SHA256).Hash.ToLowerInvariant()
  Assert ($afterReadme-ceq$before.Readme) 'partial-install rollback restores the overwritten installer-owned README byte-for-byte' $afterReadme
  $key=Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder'
  Assert ($key.DisplayVersion-eq'1.4.0') 'partial-install rollback restores the previous Installed Apps version registration' $key.DisplayVersion
  $settingsAfter=Read-SeededSettingsValues $settings;$settingsDifferences=@(foreach($entry in $before.Settings.GetEnumerator()){if(-not$settingsAfter.Contains($entry.Key)-or$settingsAfter[$entry.Key]-cne$entry.Value){[pscustomobject]@{Key=$entry.Key;Expected=$entry.Value;Actual=$(if($settingsAfter.Contains($entry.Key)){$settingsAfter[$entry.Key]}else{$null})}}})
  Assert ($settingsDifferences.Count-eq0) 'partial-install rollback preserves every seeded user preference in the settings file' ([pscustomobject]@{CheckedKeys=$before.Settings.Count;Differences=$settingsDifferences;ExcludedApplicationCheckTimestamp='updateLastCheck'})
  $timerText=(Get-Content -LiteralPath $timer -Raw).Trim();$timerParts=@($timerText -split '\s+');$timerValid=$false;$timerState=$null
  if($timerParts.Count-eq6){try{$remaining=[double]::Parse($timerParts[2],[Globalization.CultureInfo]::InvariantCulture);$duration=[double]::Parse($timerParts[3],[Globalization.CultureInfo]::InvariantCulture);$cycle=[int]::Parse($timerParts[4],[Globalization.CultureInfo]::InvariantCulture);$savedAt=[long]::Parse($timerParts[5],[Globalization.CultureInfo]::InvariantCulture);$timerState=[pscustomobject]@{Phase=$timerParts[0];Paused=$timerParts[1];RemainingSeconds=$remaining;DurationSeconds=$duration;Cycle=$cycle;SavedAt=$savedAt};$timerValid=$timerParts[0]-eq'0'-and$timerParts[1]-eq'0'-and$remaining-ge0-and$remaining-le1200-and$duration-eq1200-and$cycle-eq7-and$savedAt-gt0}catch{}}
  Assert $timerValid 'partial-install rollback preserves a valid active work timer checkpoint' $timerState
  Assert ((Get-FileHash -LiteralPath $history -Algorithm SHA256).Hash.ToLowerInvariant()-ceq$before.History) 'partial-install rollback preserves history bytes exactly'
  Assert-PreservedProfile
  $restoredProcess=$null;$restartWatch=[Diagnostics.Stopwatch]::StartNew();$expectedApp=[IO.Path]::GetFullPath($app)
  while($restartWatch.Elapsed.TotalSeconds-lt30-and-not$restoredProcess){
    $restoredProcess=@(Get-TestOwnedApplications|Where-Object{$_.Id-ne$appProcessId-and$_.Path-and[IO.Path]::GetFullPath($_.Path)-ieq$expectedApp}|Select-Object -First 1)
    if(-not$restoredProcess){Start-Sleep -Milliseconds 100}
  }
  $restored=if($restoredProcess){$restoredProcess[0]}else{$null}
  Assert ($restored-and-not$restored.HasExited-and$restored.Id-ne$appProcessId-and[IO.Path]::GetFullPath($restored.Path)-ieq$expectedApp) 'the previous application relaunched from its exact installed path after partial-install rollback' ([pscustomobject]@{PreviousProcessId=$appProcessId;RestoredProcessId=$(if($restored){$restored.Id}else{$null});ProcessPath=$(if($restored){$restored.Path}else{$null});ExecutableSHA256=$afterExecutable})
  Stop-Application
  Record 'Controlled partial installer mutation and durable rollback' 'PASS' ([pscustomobject]@{MutationFixture=$mutationMarker;PriorFiles=$before;RestoredExecutableSHA256=$afterExecutable;RegistryVersion=$key.DisplayVersion;PreviousVersionRelaunched=$true})
}
function Run-StartupFailure(){Install-Baseline;Seed-Profile;New-ReleaseFixture $UpdateInstaller $UpdateExecutable;$appProcessId=Start-TestApp $script:setupSource 0 '1.4.1';$progress=Begin-Download $appProcessId;Complete-DownloadAndWait $appProcessId $progress 'The updated application did not start.';Assert ((Wait-InstalledVersion '1.4.0')-eq'1.4.0') 'missing startup confirmation triggers previous-version rollback';Assert-PreservedProfile;Stop-Application;$uninstall=Start-Process -FilePath (Join-Path $installDir 'Uninstall.exe') -ArgumentList '/S' -PassThru -Wait;Assert ($uninstall.ExitCode-eq0-and-not(Test-Path -LiteralPath (Join-Path $installDir 'EyeBreakReminder.exe'))) 'application can be uninstalled normally after startup-failure recovery';Assert (((Get-Content -LiteralPath (Join-Path $dataDir 'settings.ini') -Raw)-match'(?m)^workMinutes=37$')-and((Get-Content -LiteralPath (Join-Path $dataDir 'history.dat') -Raw)-eq$script:historyText)) 'uninstall after recovery preserves the restored settings and history';Record 'New executable startup confirmation rollback and subsequent uninstall' 'PASS'}
function Run-PortableUpdate(){Reset-Installation;Remove-Item -LiteralPath $scriptRoot -Recurse -Force -ErrorAction SilentlyContinue;[void][IO.Directory]::CreateDirectory($scriptRoot);[void][IO.Directory]::CreateDirectory($installDir);$portable=Join-Path $scriptRoot 'portable';[void][IO.Directory]::CreateDirectory($portable);$app=Join-Path $portable 'EyeBreakReminder.exe';Copy-Item -LiteralPath $BaselineExecutable -Destination $app;[IO.File]::WriteAllText((Join-Path $portable 'keep-user-document.txt'),'keep this unrelated file');Seed-Profile;New-ReleaseFixture $UpdateInstaller $UpdateExecutable;Copy-Item -LiteralPath (Join-Path $installDir 'test-update-response.txt') -Destination (Join-Path $portable 'test-update-response.txt');Copy-TestSignedMetadata $portable;$appProcessId=Start-TestApp $script:appSource 0 '' $app;[void](Begin-Download $appProcessId);$ready=Find-Dialog 'Ready to install.' @($appProcessId) 120;$names=(Get-Names $ready.Root) -join ' | ';Assert (($names-match'Downloaded:')-and($names-match'\(100%\)')) 'portable update displays completed byte progress in the native dialog' $names;Screenshot $ready 'portable-update-progress-ready.png';Complete-DownloadAndWait $appProcessId $ready;Assert ((Get-Item -LiteralPath $app).VersionInfo.ProductVersion-eq'1.4.1') 'portable update atomically replaces and relaunches the standalone executable';Assert ((Get-Content -LiteralPath (Join-Path $portable 'keep-user-document.txt') -Raw)-eq'keep this unrelated file') 'portable update preserves unrelated files';Assert (-not(Test-Path -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder')) 'portable update does not register an installed application';Assert-PreservedProfile;Stop-Application;Record 'Portable standalone update' 'PASS'}
function Run-PortableCleanUpdate([bool]$DeleteHistory){
  Reset-Installation
  $portable=Join-Path $scriptRoot 'portable';[void][IO.Directory]::CreateDirectory($portable)
  $app=Join-Path $portable 'EyeBreakReminder.exe';Copy-Item -LiteralPath $BaselineExecutable -Destination $app
  [IO.File]::WriteAllText((Join-Path $portable 'keep-user-document.txt'),'portable unrelated sentinel')
  Seed-Profile 1;New-ReleaseFixture $UpdateInstaller $UpdateExecutable
  Copy-Item -LiteralPath (Join-Path $installDir 'test-update-response.txt') -Destination (Join-Path $portable 'test-update-response.txt')
  Copy-TestSignedMetadata $portable
  $appProcessId=Start-TestApp $script:appSource 0 '' $app
  $progress=Begin-Download $appProcessId $true $DeleteHistory
  Complete-DownloadAndWait $appProcessId $progress
  Assert ((Get-Item -LiteralPath $app).VersionInfo.ProductVersion-eq'1.4.1') 'portable Clean Install replaces and relaunches the controlled successor'
  Stop-Application
  $settingsPath=Join-Path $dataDir 'settings.ini';$settingsRaw=Get-Content -LiteralPath $settingsPath -Raw
  Assert ($settingsRaw-match'(?m)^workMinutes=20$'-and$settingsRaw-match'(?m)^breakSeconds=20$'-and$settingsRaw-match'(?m)^volume=55$'-and$settingsRaw-match'(?m)^theme=2$') 'portable Clean Install restores default timer, volume and theme settings'
  Assert ($settingsRaw-match'(?m)^customWorkAccent=0$'-and$settingsRaw-match'(?m)^customBreakAccent=0$'-and$settingsRaw-match'(?m)^schedule=0$'-and$settingsRaw-match'(?m)^autoCheckUpdates=0$'-and$settingsRaw-match'(?m)^autoDownloadUpdates=0$') 'portable Clean Install clears custom accents, operating schedule and update preferences'
  if($DeleteHistory){Assert (-not(Test-Path -LiteralPath (Join-Path $dataDir 'history.dat'))) 'portable Clean Install deletes history only after separately confirmed selection'}
  else{Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $dataDir 'history.dat')))-ceq[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script:historyText))) 'portable Clean Install preserves history byte-for-byte when deletion is not selected'}
  Assert ((Get-Content -LiteralPath (Join-Path $portable 'keep-user-document.txt') -Raw)-eq'portable unrelated sentinel') 'portable Clean Install preserves unrelated neighboring files'
  Assert (-not(Test-Path -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder')) 'portable Clean Install does not create an Installed Apps registration'
  Record $(if($DeleteHistory){'Portable Clean Install with explicit history deletion'}else{'Portable Clean Install preserving history'}) 'PASS'
}
function Run-UninstallChecks(){
  Install-Baseline;Seed-Profile;New-ReleaseFixture $UpdateInstaller $UpdateExecutable
  $appProcessId=Start-TestApp;$progress=Begin-Download $appProcessId;Complete-DownloadAndWait $appProcessId $progress;[void](Wait-InstalledVersion '1.4.1');Verify-WindowsSettingsEntry '1.4.1';Stop-Application
  [IO.File]::WriteAllText((Join-Path $dataDir 'user-not-owned.txt'),'unrelated disposable test document')
  $uninstall=Start-Process -FilePath (Join-Path $installDir 'Uninstall.exe') -ArgumentList '/S' -PassThru -Wait
  Assert ($uninstall.ExitCode-eq0-and-not(Test-Path -LiteralPath (Join-Path $installDir 'EyeBreakReminder.exe'))) 'silent uninstall after automatic update removes application files'
  Assert ((Get-Content -LiteralPath (Join-Path $dataDir 'settings.ini') -Raw)-match'(?m)^workMinutes=37$'-and(Get-Content -LiteralPath (Join-Path $dataDir 'history.dat') -Raw)-eq$script:historyText-and(Test-Path -LiteralPath (Join-Path $dataDir 'user-not-owned.txt'))) 'silent uninstall deterministically keeps settings, history and unrelated files'
  $key=Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder' -ErrorAction SilentlyContinue;Assert (-not$key) 'uninstall removes the Installed Apps registry entry'
  $reinstall=Start-Process -FilePath ([IO.Path]::GetFullPath($BaselineInstaller)) -ArgumentList @('/S',"/D=$installDir") -PassThru -Wait
  $app=Join-Path $installDir 'EyeBreakReminder.exe'
  Assert ($reinstall.ExitCode-eq0-and(Test-Path -LiteralPath $app)-and(Get-Item -LiteralPath $app).VersionInfo.ProductVersion-eq'1.4.0') 'baseline setup can reinstall the app after automatic-update uninstall'
  Assert (((Get-Content -LiteralPath (Join-Path $dataDir 'settings.ini') -Raw)-match'(?m)^workMinutes=37$')-and((Get-Content -LiteralPath (Join-Path $dataDir 'history.dat') -Raw)-eq$script:historyText)) 'reinstall after uninstall keeps existing settings and history'
  $restarted=Start-Process -FilePath $app -PassThru;$watch=[Diagnostics.Stopwatch]::StartNew();while($watch.Elapsed.TotalSeconds-lt20-and-not$restarted.HasExited){$restarted.Refresh();if($restarted.MainWindowHandle-ne[IntPtr]::Zero){break};Start-Sleep -Milliseconds 100};Assert (-not$restarted.HasExited-and$restarted.MainWindowHandle-ne[IntPtr]::Zero) 'reinstalled application starts with the retained profile';Stop-Application
  $secondUninstall=Start-Process -FilePath (Join-Path $installDir 'Uninstall.exe') -ArgumentList '/S' -PassThru -Wait
  Assert ($secondUninstall.ExitCode-eq0-and-not(Test-Path -LiteralPath $app)) 'reinstalled application can be uninstalled again'
  Assert (((Get-Content -LiteralPath (Join-Path $dataDir 'settings.ini') -Raw)-match'(?m)^workMinutes=37$')-and((Get-Content -LiteralPath (Join-Path $dataDir 'history.dat') -Raw)-eq$script:historyText)) 'second uninstall keeps the original settings and history'
  Remove-ExactTestData;Remove-Item -LiteralPath $installDir -Recurse -Force -ErrorAction SilentlyContinue;Record 'Silent uninstall after automatic update and reinstallation' 'PASS'
}
function Run-InteractiveUninstall([bool]$RemoveData){
  Install-Baseline;Seed-Profile;New-ReleaseFixture $UpdateInstaller $UpdateExecutable;$appProcessId=Start-TestApp;$progress=Begin-Download $appProcessId;Complete-DownloadAndWait $appProcessId $progress;[void](Wait-InstalledVersion '1.4.1');Stop-Application
  [IO.File]::WriteAllText((Join-Path $dataDir 'user-not-owned.txt'),'unrelated disposable test document')
  $uninstallerPath=Join-Path $installDir 'Uninstall.exe';$p=Start-Process -FilePath $uninstallerPath -PassThru
  $confirm=Find-TestUninstallerDialog 'Eye Break Reminder' $uninstallerPath $p 30
  $uninstallerProcess=Get-TestUninstallerProcess $confirm $uninstallerPath $p.Id;[void](Invoke-TestUninstallerButton $confirm @('Uninstall','Yes','Next >','Next'))
  $page=Find-TestUninstallerDialog 'Application data' $uninstallerPath $p 30;$pageProcess=Get-TestUninstallerProcess $page $uninstallerPath $p.Id;Assert ($pageProcess.Id-eq$uninstallerProcess.Id) 'application-data page remains in the same NSIS uninstall process';[void](Get-NsisNativeRadio $page 'Keep my settings and history (Recommended)');Assert (Test-NsisNativeRadioSelected $page 'Keep my settings and history (Recommended)') 'interactive uninstall defaults to keeping settings and history'
  if($RemoveData){[void](Select-Radio $page 'Remove my settings and history');Assert (Test-NsisNativeRadioSelected $page 'Remove my settings and history') 'explicit interactive Remove choice becomes the selected native radio';Assert (-not(Test-NsisNativeRadioSelected $page 'Keep my settings and history (Recommended)')) 'explicit interactive Remove choice deselects Keep'}
  [void](Invoke-TestUninstallerButton $page @('Uninstall','Next >','Next'))
  # MUI_UNPAGE_FINISH deliberately waits for the user to close the wizard. Reaching
  # the finish page proves the uninstall section ran; click its real native Finish
  # button before waiting for the verified NSIS child process to exit.
  $finish=Find-TestUninstallerDialog 'Click Finish to close Setup.' $uninstallerPath $p 90
  $finishProcess=Get-TestUninstallerProcess $finish $uninstallerPath $p.Id
  Assert ($finishProcess.Id-eq$uninstallerProcess.Id) 'uninstall finish page remains in the same NSIS process'
  Assert (($finish.Names -contains 'Finish')-and($finish.Names -contains 'Completing Eye Break Reminder Uninstall')) 'interactive uninstall displays the explicit completion page'
  Screenshot $finish $(if($RemoveData){'interactive-uninstall-complete-remove.png'}else{'interactive-uninstall-complete-keep.png'})
  Assert (-not(Test-Path -LiteralPath (Join-Path $installDir 'EyeBreakReminder.exe'))) 'uninstaller removes application files before the finish page'
  Assert (-not(Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder' -ErrorAction SilentlyContinue)) 'uninstaller removes Installed Apps registration before the finish page'
  [void](Invoke-TestUninstallerButton $finish @('Finish'))
  if($uninstallerProcess.WaitForExit(30000)-eq$false){throw 'Interactive NSIS uninstall did not exit after its Finish button was clicked.'}
  $uninstallerProcess.Refresh();$p.Refresh();$installedAppStillExists=Test-Path -LiteralPath (Join-Path $installDir 'EyeBreakReminder.exe');$interactiveExitEvidence=[pscustomobject]@{LaunchProcessId=$p.Id;LaunchProcessExited=$p.HasExited;LaunchProcessExitCode=$(if($p.HasExited){$p.ExitCode}else{$null});ExtractedUninstallerProcessId=$uninstallerProcess.Id;ExtractedUninstallerExited=$uninstallerProcess.HasExited;ExtractedUninstallerExitCode=$(if($uninstallerProcess.HasExited){$uninstallerProcess.ExitCode}else{$null});InstalledExecutableStillExists=$installedAppStillExists};Record 'Interactive NSIS uninstaller process and filesystem result' 'INFO' $interactiveExitEvidence
  # NSIS runs a copied uninstaller from its temporary directory so it can delete
  # the installed copy. Its official documentation notes that the launching
  # process cannot report the copied uninstaller's error level. Gate this UI test
  # on the observed completed wizard and actual file/registry state, and retain
  # both process exit codes as diagnostic evidence rather than treating them as
  # proof of installation removal.
  Assert (-not$installedAppStillExists) 'interactive uninstall after automatic update removes installed files';$uninstallKey=Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\EyeBreakReminder' -ErrorAction SilentlyContinue;Assert (-not$uninstallKey) 'interactive uninstall removes the Installed Apps entry'
  if($RemoveData){Assert (-not(Test-Path -LiteralPath (Join-Path $dataDir 'settings.ini'))-and-not(Test-Path -LiteralPath (Join-Path $dataDir 'history.dat'))) 'explicit interactive Remove choice deletes only settings and history';Assert ((Get-Content -LiteralPath (Join-Path $dataDir 'user-not-owned.txt') -Raw)-eq'unrelated disposable test document') 'interactive data removal leaves unrelated profile files untouched'}else{Assert ((Get-Content -LiteralPath (Join-Path $dataDir 'settings.ini') -Raw)-match'(?m)^workMinutes=37$'-and(Get-Content -LiteralPath (Join-Path $dataDir 'history.dat') -Raw)-eq$script:historyText) 'interactive Keep choice preserves settings and history';Assert (Test-Path -LiteralPath (Join-Path $dataDir 'user-not-owned.txt')) 'interactive Keep choice preserves unrelated files'}
  Remove-ExactTestData;Remove-Item -LiteralPath $installDir -Recurse -Force -ErrorAction SilentlyContinue;Record $(if($RemoveData){'Interactive uninstall removes selected user data'}else{'Interactive uninstall keeps user data'}) 'PASS'
}

try{
  Assert (-not(Test-Path -LiteralPath $dataDir)) 'disposable runner starts without Eye Break Reminder profile data' $dataDir
  Record 'Updater test fixture identities' 'INFO' $script:fixtureIdentities
  if($Scenario-eq'VisualHotfix'){Assert ((Get-Item -LiteralPath $BaselineInstaller).VersionInfo.ProductVersion-eq'1.4.1') 'v1.4.1 baseline installer file version';Assert ((Get-Item -LiteralPath $BaselineExecutable).VersionInfo.ProductVersion-eq'1.4.1') 'v1.4.1 baseline application file version';Assert ((Get-Item -LiteralPath $UpdateInstaller).VersionInfo.ProductVersion-eq'1.4.2') 'v1.4.2 candidate installer file version';Assert ((Get-Item -LiteralPath $UpdateExecutable).VersionInfo.ProductVersion-eq'1.4.2') 'v1.4.2 candidate application file version'}else{Assert ((Get-Item -LiteralPath $BaselineInstaller).VersionInfo.ProductVersion-eq'1.4.0') 'baseline installer file version';Assert ((Get-Item -LiteralPath $UpdateInstaller).VersionInfo.ProductVersion-eq'1.4.1') 'test update installer file version';Assert ((Get-Item -LiteralPath $UpdateExecutable).VersionInfo.ProductVersion-eq'1.4.1') 'test update standalone file version';Assert ((Get-Item -LiteralPath $FailingInstaller).VersionInfo.ProductVersion-eq'1.4.1') 'controlled failing installer has the expected version resource'}
  if($Scenario-eq'UpdatePreferences'){
    Run-UpdatePreferenceRoundtrip
    Reset-Installation
    Record 'Overall updater preference roundtrip' 'PASS' ([pscustomobject]@{Assertions=$script:assertions;Scenario=$Scenario;Version='1.4.1';OnlyLocalFixtureMetadata=$true;PublicReleaseCreated=$false})
  }elseif($Scenario-eq'ActiveBreakDeferral'){
    Run-ActiveBreakDeferral
    Record 'Overall updater active-break deferral' 'PASS' ([pscustomobject]@{Assertions=$script:assertions;Scenario=$Scenario;Version='1.4.1';OnlyLocalFixtureMetadata=$true;PublicReleaseCreated=$false})
  }elseif($Scenario-eq'DialogThemes'){
    Run-DialogThemes
    Reset-Installation
    Record 'Overall updater dialog themes' 'PASS' ([pscustomobject]@{Assertions=$script:assertions;Scenario=$Scenario;Version='1.4.1';OnlyLocalFixtureMetadata=$true;PublicReleaseCreated=$false})
  }elseif($Scenario-eq'VisualHotfix'){
    $testApplication=Join-Path (Split-Path -Parent $PSScriptRoot) 'build/gui-test/EyeBreakReminder.exe';if(-not(Test-Path -LiteralPath $testApplication -PathType Leaf)){throw 'Hotfix GUI test application is missing.'};Run-VisualHotfix $testApplication
    Record 'Overall updater visual hotfix' 'PASS' ([pscustomobject]@{Assertions=$script:assertions;Scenario=$Scenario;Version='1.4.2';OnlyLocalTestMetadata=$true;PublicReleaseCreated=$false})
  }else{
    Run-UpdatePreferenceRoundtrip
    Run-NormalUpdate
    Run-DialogThemes
    Run-ActiveBreakDeferral
    Run-CancelAndHashFailure $false
    Run-ScaledProgress
    Run-InterruptedDownloadRecovery
    Run-CancelAndHashFailure $true
    Run-CleanUpdate $false
    Run-CleanUpdate $true
    Run-InstallerFailure
    Run-StartupFailure
    Run-InterruptedCleanRecovery
    Run-PortableUpdate
    Run-PortableCleanUpdate $false
    Run-PortableCleanUpdate $true
    Run-UninstallChecks
    Run-InteractiveUninstall $false
    Run-InteractiveUninstall $true
    Record 'Overall updater Windows integration' 'PASS' ([pscustomobject]@{Assertions=$script:assertions;Scenario=$Scenario;Version='1.4.1';OnlyLocalFixtureMetadata=$true;PublicReleaseCreated=$false})
  }
}catch{if($Scenario-eq'ActiveBreakDeferral'){ $diagnostics=Save-ActiveBreakDiagnostics;if($diagnostics){Record 'Active-break test-only application diagnostics' 'INFO' $diagnostics};$responsePath=Join-Path $installDir 'test-update-response.txt';if(Test-Path -LiteralPath $responsePath){Copy-Item -LiteralPath $responsePath -Destination (Join-Path $EvidenceDirectory 'active-break-update-response.txt') -Force} };Record 'Overall updater Windows integration' 'FAIL' $_.Exception.ToString();throw}
finally{
  try{Stop-Application}catch{Record 'Safe process cleanup' 'FAIL' $_.Exception.Message}
  $hasFailures=@($script:events|Where-Object{$_.Status -eq 'FAIL'}).Count -gt 0
  $completedSuccessfully=@($script:events|Where-Object{$_.Name -in @('Overall updater Windows integration','Overall updater preference roundtrip','Overall updater active-break deferral','Overall updater dialog themes','Overall updater visual hotfix')-and$_.Status -eq 'PASS'}).Count -gt 0
  if(-not$hasFailures-and(Test-Path -LiteralPath $scriptRoot)){
    $resolved=[IO.Path]::GetFullPath($scriptRoot)
    $prefix=$runnerTemp.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    if(-not$resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Refusing to clean the updater test folder outside RUNNER_TEMP.'}
    $attributes=[IO.File]::GetAttributes($resolved)
    if($attributes-band[IO.FileAttributes]::ReparsePoint){throw 'Refusing to clean a reparse-point updater test folder.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
  }
  Remove-Item Env:EBR_GUI_TEST_DATA_DIRECTORY,Env:EBR_GUI_TEST_UPDATE_ASSET_PATH,Env:EBR_GUI_TEST_UPDATE_DELAY_MS,Env:EBR_GUI_TEST_CONFIRM_TIMEOUT_MS,Env:EBR_GUI_TEST_SKIP_UPDATE_CONFIRM_VERSION,Env:EBR_GUI_TEST_HOLD_AFTER_CLEAN_MS -ErrorAction SilentlyContinue
  $resultStatus=if($hasFailures){'FAIL'}elseif($completedSuccessfully){'PASS'}else{'INCOMPLETE'}
  $result=[pscustomobject]@{Status=$resultStatus;Scenario=$Scenario;Assertions=$script:assertions;FixtureIdentities=$script:fixtureIdentities;Events=@($script:events);RunId=$env:GITHUB_RUN_ID;Utc=[DateTime]::UtcNow.ToString('o')};$result|ConvertTo-Json -Depth 9|Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'updater-acceptance-results.json') -Encoding UTF8
  try{Stop-Transcript|Out-Null}catch{}
}
