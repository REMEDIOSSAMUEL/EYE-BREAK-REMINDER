param(
  [string]$EvidenceDirectory = (Join-Path $PSScriptRoot '..\build\pre-release-evidence')
)
$ErrorActionPreference = 'Stop'
[void][IO.Directory]::CreateDirectory($EvidenceDirectory)
Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
Add-Type -AssemblyName System.Drawing -ErrorAction Stop
Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
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
$before=Save-Desktop 'windows-11-runner-before-desktop-prep.png'
$windowsBefore=@(Get-TopLevelWindows)
$namesBefore=@(Get-DesktopAccessibleNames)
$privacyVisible=@($namesBefore|Where-Object {$_ -match 'Choose privacy settings for your device'}).Count -gt 0
$explorerBefore=$null -ne (Get-Process explorer -ErrorAction SilentlyContinue|Select-Object -First 1)
$buttonFound=$false
$buttonInvoked=$false
$action='No initial privacy page detected'
$reason=''
if($privacyVisible){
  $all=[System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
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
  if(-not $buttonFound){$reason='The privacy page was visible but no enabled accessible Next button was exposed.'}
  if($buttonInvoked){Start-Sleep -Seconds 5}
}
$after=Save-Desktop 'windows-11-runner-after-desktop-prep.png'
$windowsAfter=@(Get-TopLevelWindows)
$namesAfter=@(Get-DesktopAccessibleNames)
$privacyStillVisible=@($namesAfter|Where-Object {$_ -match 'Choose privacy settings for your device'}).Count -gt 0
$explorerAfter=$null -ne (Get-Process explorer -ErrorAction SilentlyContinue|Select-Object -First 1)
$status=if($privacyStillVisible){'NOT TESTED'}elseif($explorerAfter){'PASS'}else{'NOT TESTED'}
if($privacyStillVisible -and -not $reason){$reason='The initial privacy page remained; no other OOBE page or account choice was automated.'}
if(-not $explorerAfter -and -not $reason){$reason='Explorer desktop process was not available after the bounded preparation step.'}
$record=[pscustomobject]@{
  Status=$status
  Environment='Disposable GitHub-hosted Windows 11 ARM64 runner'
  OobePrivacyPageDetected=$privacyVisible
  Action=$action
  NextButtonFound=$buttonFound
  NextButtonInvoked=$buttonInvoked
  PrivacyPageStillVisible=$privacyStillVisible
  ExplorerBefore=$explorerBefore
  ExplorerAfter=$explorerAfter
  ScreenshotBefore=$before
  ScreenshotAfter=$after
  Reason=$reason
  Utc=[DateTime]::UtcNow.ToString('o')
}
$record|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'windows-11-desktop-prep.json') -Encoding UTF8
$record|ConvertTo-Json -Depth 5