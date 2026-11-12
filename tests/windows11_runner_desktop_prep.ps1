param(
  [string]$EvidenceDirectory = (Join-Path $PSScriptRoot '..\build\pre-release-evidence')
)
$ErrorActionPreference = 'Stop'
[void][IO.Directory]::CreateDirectory($EvidenceDirectory)
Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
Add-Type -AssemblyName System.Drawing -ErrorAction Stop
Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
$native=@"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class EBR_W11_DESKTOP {
  [DllImport("user32.dll",SetLastError=true)] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll",SetLastError=true)] public static extern uint GetWindowThreadProcessId(IntPtr hwnd,out uint pid);
  [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] private static extern int GetWindowTextW(IntPtr hwnd,StringBuilder text,int maxCount);
  [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] private static extern int GetClassNameW(IntPtr hwnd,StringBuilder text,int maxCount);
  [DllImport("user32.dll",SetLastError=true)] public static extern bool SetCursorPos(int x,int y);
  [DllImport("user32.dll",SetLastError=true)] public static extern void mouse_event(uint flags,uint dx,uint dy,uint data,UIntPtr extraInfo);
  public static string Text(IntPtr hwnd){StringBuilder b=new StringBuilder(512);GetWindowTextW(hwnd,b,b.Capacity);return b.ToString();}
  public static string ClassName(IntPtr hwnd){StringBuilder b=new StringBuilder(256);GetClassNameW(hwnd,b,b.Capacity);return b.ToString();}
}
"@
Add-Type -TypeDefinition $native -ErrorAction Stop
function Get-ForegroundSnapshot {
  $handle=[EBR_W11_DESKTOP]::GetForegroundWindow();$foregroundProcessId=0
  if($handle -eq [IntPtr]::Zero){return [pscustomobject]@{Handle='0x0';ProcessId=0;ProcessName='';Title='';Class=''}}
  [void][EBR_W11_DESKTOP]::GetWindowThreadProcessId($handle,[ref]$foregroundProcessId)
  $processName='';try{$processName=(Get-Process -Id $foregroundProcessId -ErrorAction Stop).ProcessName}catch{}
  return [pscustomobject]@{Handle=('0x{0:X}' -f $handle.ToInt64());ProcessId=$foregroundProcessId;ProcessName=$processName;Title=[EBR_W11_DESKTOP]::Text($handle);Class=[EBR_W11_DESKTOP]::ClassName($handle)}
}
function Save-Desktop([string]$Name){
  $screen=[Windows.Forms.Screen]::PrimaryScreen
  if(-not $screen -or $screen.Bounds.Width -lt 100 -or $screen.Bounds.Height -lt 100){return $null}
  $bitmap=[Drawing.Bitmap]::new($screen.Bounds.Width,$screen.Bounds.Height)
  $graphics=[Drawing.Graphics]::FromImage($bitmap)
  try{
    $graphics.CopyFromScreen($screen.Bounds.Left,$screen.Bounds.Top,0,0,$bitmap.Size)
    $file=Join-Path $EvidenceDirectory $Name
    $bitmap.Save($file,[Drawing.Imaging.ImageFormat]::Png)
    return $file
  }finally{$graphics.Dispose();$bitmap.Dispose()}
}
function Get-TopLevelWindows {
  $items=[System.Collections.Generic.List[object]]::new()
  $root=[System.Windows.Automation.AutomationElement]::RootElement
  $windows=$root.FindAll([System.Windows.Automation.TreeScope]::Children,[System.Windows.Automation.Condition]::TrueCondition)
  foreach($window in $windows){
    try{
      $name=[string]$window.Current.Name
      $controlType=$window.Current.ControlType.ProgrammaticName
      if($name -or $controlType){$items.Add([pscustomobject]@{Name=$name;ControlType=$controlType})}
    }catch{}
  }
  return $items.ToArray()
}
function Get-DesktopAccessibleNames {
  $names=[System.Collections.Generic.List[string]]::new()
  $root=[System.Windows.Automation.AutomationElement]::RootElement
  $all=$root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
  for($i=0;$i -lt $all.Count;$i++){
    try{$name=[string]$all.Item($i).Current.Name;if($name){$names.Add($name)}}catch{}
  }
  return $names.ToArray()
}
function Find-LowerRightBlueTarget([string]$Path){
  if(-not $Path -or -not (Test-Path -LiteralPath $Path)){return $null}
  $bitmap=[Drawing.Bitmap]::new($Path);$imageWidth=$bitmap.Width;$imageHeight=$bitmap.Height;$minX=$imageWidth;$minY=$imageHeight;$maxX=-1;$maxY=-1;$count=0
  try{
    $left=[int]($imageWidth*0.78);$right=[int]($imageWidth*0.95);$top=[int]($imageHeight*0.80);$bottom=[int]($imageHeight*0.91)
    for($y=$top;$y -lt $bottom;$y++){for($x=$left;$x -lt $right;$x++){$c=$bitmap.GetPixel($x,$y);if($c.R -lt 150 -and $c.G -gt 30 -and $c.B -gt 80){$count++;$minX=[Math]::Min($minX,$x);$maxX=[Math]::Max($maxX,$x);$minY=[Math]::Min($minY,$y);$maxY=[Math]::Max($maxY,$y)}}}
  }finally{$bitmap.Dispose()}
  $width=$maxX-$minX+1;$height=$maxY-$minY+1
  if($count -ge 500 -and $width -ge 70 -and $height -ge 22 -and $width -le [int]($imageWidth*0.30) -and $height -le [int]($imageHeight*0.12)){return [pscustomobject]@{Left=$minX;Top=$minY;Width=$width;Height=$height;BluePixels=$count;CenterX=[int](($minX+$maxX)/2);CenterY=[int](($minY+$maxY)/2)}}
  return $null
}
$before=Save-Desktop 'windows-11-runner-before-desktop-prep.png'
$foregroundBefore=Get-ForegroundSnapshot
$windowsBefore=@(Get-TopLevelWindows)
$namesBefore=@(Get-DesktopAccessibleNames)
$privacyVisibleByUIA=@($namesBefore|Where-Object {$_ -match 'Choose privacy settings for your device'}).Count -gt 0
$oobeForeground=($foregroundBefore.ProcessName -ieq 'WWAHost' -and $foregroundBefore.Title -match 'Microsoft account')
$privacyVisible=$privacyVisibleByUIA -or $oobeForeground
$explorerBefore=$null -ne (Get-Process explorer -ErrorAction SilentlyContinue|Select-Object -First 1)
$buttonFound=$false
$buttonInvoked=$false
$action='No initial privacy page detected'
$reason=''
$target=$null
$visualActions=[System.Collections.Generic.List[object]]::new()
$firstActionScreenshot=$null
$firstActionChanged=$false
$foregroundAfterFirstAction=$null
if($privacyVisible){
  $all=@()
  if($oobeForeground){try{$rootWindow=[System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]::new([Convert]::ToInt64($foregroundBefore.Handle.Substring(2),16)));$all=$rootWindow.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)}catch{}}
  if($all.Count -eq 0){$all=[System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)}
  foreach($element in $all){
    try{
      if($element.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and $element.Current.Name -eq 'Next' -and -not $element.Current.IsOffscreen -and $element.Current.IsEnabled){
        $buttonFound=$true
        $pattern=$null
        if($element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern,[ref]$pattern)){
          $pattern.Invoke()
          $buttonInvoked=$true
          $action='Invoked Next on the initial privacy page using the disposable runner current defaults'
        }else{$reason='The accessible Next button did not expose InvokePattern.'}
        break
      }
    }catch{}
  }
  if(-not $buttonFound -and $oobeForeground){
    $target=Find-LowerRightBlueTarget $before
    if($target){
      $screenBounds=[Windows.Forms.Screen]::PrimaryScreen.Bounds
      $cursorSet=[EBR_W11_DESKTOP]::SetCursorPos($screenBounds.Left+$target.CenterX,$screenBounds.Top+$target.CenterY)
      if($cursorSet){[EBR_W11_DESKTOP]::mouse_event(0x0002,0,0,0,[UIntPtr]::Zero);[EBR_W11_DESKTOP]::mouse_event(0x0004,0,0,0,[UIntPtr]::Zero);$visualActions.Add([pscustomobject]@{Stage='initial privacy page';Target=$target;ScreenOrigin=@($screenBounds.Left,$screenBounds.Top);CursorPositionSet=$true;Input='mouse_event left-button down/up'});$action='Clicked the visually detected lower-right action on the initial OOBE privacy page using real desktop mouse input'}else{$reason='A lower-right blue action was detected but Windows could not position the cursor; no click was sent.'}
    }else{$reason='The WWAHost privacy page was foreground but no accessible Next button or unambiguous lower-right blue button was detected.'}
  }
  if(-not $buttonFound -and $visualActions.Count -eq 0 -and -not $reason){$reason='The privacy page was visible but no enabled accessible Next button was exposed.'}
  if($buttonInvoked -or $visualActions.Count -gt 0){
    Start-Sleep -Seconds 5
    $firstActionScreenshot=Save-Desktop 'windows-11-runner-after-first-oobe-action.png'
    $foregroundAfterFirstAction=Get-ForegroundSnapshot
    if($before -and $firstActionScreenshot){$firstActionChanged=(Get-FileHash -LiteralPath $before -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $firstActionScreenshot -Algorithm SHA256).Hash}
    $stillOnOobe=($foregroundAfterFirstAction.ProcessName -ieq 'WWAHost' -and $foregroundAfterFirstAction.Title -match 'Microsoft account')
    if($stillOnOobe -and $firstActionChanged){
      $acceptTarget=Find-LowerRightBlueTarget $firstActionScreenshot
      if($acceptTarget){
        $screenBounds=[Windows.Forms.Screen]::PrimaryScreen.Bounds
        $cursorSet=[EBR_W11_DESKTOP]::SetCursorPos($screenBounds.Left+$acceptTarget.CenterX,$screenBounds.Top+$acceptTarget.CenterY)
        if($cursorSet){[EBR_W11_DESKTOP]::mouse_event(0x0002,0,0,0,[UIntPtr]::Zero);[EBR_W11_DESKTOP]::mouse_event(0x0004,0,0,0,[UIntPtr]::Zero);$visualActions.Add([pscustomobject]@{Stage='changed OOBE privacy confirmation page';Target=$acceptTarget;ScreenOrigin=@($screenBounds.Left,$screenBounds.Top);CursorPositionSet=$true;Input='mouse_event left-button down/up';Reason='A new screenshot confirmed the page changed after the first action; a single lower-right action target remained on the disposable privacy page.'});$action+='; clicked the next visually detected privacy confirmation action';Start-Sleep -Seconds 5}else{$reason='The privacy confirmation changed, but Windows could not position the cursor; no second click was sent.'}
      }
    }
  }
}
$after=Save-Desktop 'windows-11-runner-after-desktop-prep.png'
$foregroundAfter=Get-ForegroundSnapshot
$windowsAfter=@(Get-TopLevelWindows)
$namesAfter=@(Get-DesktopAccessibleNames)
$privacyStillVisibleByUIA=@($namesAfter|Where-Object {$_ -match 'Choose privacy settings for your device'}).Count -gt 0
$oobeStillForeground=($foregroundAfter.ProcessName -ieq 'WWAHost' -and $foregroundAfter.Title -match 'Microsoft account')
$privacyStillVisible=$privacyStillVisibleByUIA
$desktopObstructed=$privacyStillVisibleByUIA -or $oobeStillForeground
$explorerAfter=$null -ne (Get-Process explorer -ErrorAction SilentlyContinue|Select-Object -First 1)
$status=if($desktopObstructed){'NOT TESTED'}elseif($explorerAfter){'PASS'}else{'NOT TESTED'}
if($desktopObstructed -and -not $reason){if($visualActions.Count -gt 0){$reason='WWAHost remained foreground after the bounded privacy-page actions; no account credentials were entered.'}else{$reason='The initial privacy page remained; no other OOBE page or account choice was automated.'}}
if(-not $explorerAfter -and -not $reason){$reason='Explorer desktop process was not available after the bounded preparation step.'}
$record=[pscustomobject]@{
  Status=$status
  Environment='Disposable GitHub-hosted Windows 11 ARM64 runner'
  OobePrivacyPageDetected=$privacyVisible
  PrivacyPageDetectedByUIAutomation=$privacyVisibleByUIA
  OobeForegroundDetected=$oobeForeground
  ForegroundBefore=$foregroundBefore
  Action=$action
  NextButtonFound=$buttonFound
  NextButtonInvoked=$buttonInvoked
  OobeVisualActions=$visualActions.ToArray()
  FirstActionScreenshot=$firstActionScreenshot
  FirstActionChangedScreen=$firstActionChanged
  ForegroundAfterFirstAction=$foregroundAfterFirstAction
  PrivacyPageStillVisible=$privacyStillVisible
  PrivacyPageStillVisibleByUIAutomation=$privacyStillVisibleByUIA
  OobeStillForeground=$oobeStillForeground
  DesktopObstructed=$desktopObstructed
  ForegroundAfter=$foregroundAfter
  ExplorerBefore=$explorerBefore
  ExplorerAfter=$explorerAfter
  ScreenshotBefore=$before
  ScreenshotAfter=$after
  Reason=$reason
  Utc=[DateTime]::UtcNow.ToString('o')
}
$record|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'windows-11-desktop-prep.json') -Encoding UTF8
$record|ConvertTo-Json -Depth 5
