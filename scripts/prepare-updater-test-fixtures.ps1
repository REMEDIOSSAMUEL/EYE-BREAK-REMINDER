param([Parameter(Mandatory=$true)][string]$NsisCompiler)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if($env:GITHUB_ACTIONS-ne'true'){throw 'Updater installer fixtures may only be built on the disposable GitHub Actions runner.'}
$runnerTemp=[IO.Path]::GetFullPath($env:RUNNER_TEMP)
$temp=[IO.Path]::GetFullPath((Join-Path $runnerTemp 'EBR-v1.4-fixture-build'))
if(Test-Path -LiteralPath $temp){throw "Refusing to reuse fixture build folder: $temp"}
$release=Join-Path $root 'release';$build=Join-Path $root 'build/gui-test'
$trustPath=Join-Path $root 'src/update_trust.hpp'
$productionTrustBytes=[IO.File]::ReadAllBytes($trustPath)
$productionTrustText=[Text.Encoding]::ASCII.GetString($productionTrustBytes)
if($productionTrustText-notmatch'ProductionUpdateKeyProvisioned\s*=\s*true\s*;'-or$productionTrustText-notmatch'ProductionUpdateKeyId\s*=\s*"p256-[0-9a-f]{16}"'){throw 'Refusing test fixtures unless the production trust header is provisioned.'}
$productionTrustBase64=[Convert]::ToBase64String($productionTrustBytes)
$testTrustHeader=@'
#pragma once
#include <array>
#include <string_view>
namespace eye::updates {
// Used only by EYEBREAK_TEST_BUILD GUI integration binaries.
inline constexpr bool ProductionUpdateKeyProvisioned=false;
inline constexpr std::string_view ProductionUpdateKeyId="";
inline constexpr std::array<unsigned char,64> ProductionUpdatePublicKey{};
}
'@
$testTrustActive=$false
$originalExe=Join-Path $temp 'candidate-EyeBreakReminder.exe';$originalSetup=Join-Path $temp 'candidate-EyeBreakReminder-Setup-x64.exe'
$msysRoot=[IO.Path]::GetFullPath($env:MSYS2_ROOT);$make=[IO.Path]::GetFullPath($env:MSYS2_MAKE)
$rootPrefix=$msysRoot.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
if(-not$make.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase)-or-not(Test-Path -LiteralPath $make -PathType Leaf)){throw "The workflow-provided MSYS2 make executable is missing or outside its measured root: $make"}
$env:PATH="$(Join-Path $msysRoot 'mingw64\bin');$(Join-Path $msysRoot 'mingw32\bin');$(Join-Path $msysRoot 'usr\bin');$env:PATH"
function Invoke-Make([string]$Target){& $make $Target "CROSS_CXX=x86_64-w64-mingw32-g++ -DWINVER=0x0A00 -D_WIN32_WINNT=0x0A00" 'WINDRES=windres' "MAKENSIS=$NsisCompiler" 'PYTHON=python';if($LASTEXITCODE-ne0){throw "make $Target failed with exit code $LASTEXITCODE."}}
function Set-SourceVersion([string]$Version){& python (Join-Path $root 'scripts/set-version.py') $Version;if($LASTEXITCODE-ne0){throw "Could not set the temporary source version to $Version."}}
function Enable-TestBuildTrust(){[IO.File]::WriteAllText($trustPath,$testTrustHeader,[Text.Encoding]::ASCII);$script:testTrustActive=$true}
function Restore-ProductionTrust(){
  if(-not$script:testTrustActive){return}
  [IO.File]::WriteAllBytes($trustPath,$productionTrustBytes)
  $restored=[Convert]::ToBase64String([IO.File]::ReadAllBytes($trustPath))
  if($restored-cne$productionTrustBase64){throw 'Production update trust header did not restore byte-for-byte after test fixture compilation.'}
  $script:testTrustActive=$false
  $trustHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($productionTrustBytes)).ToLowerInvariant()
  [pscustomobject]@{Status='PASS';TestBuildTrust='Fail-closed, scoped to EYEBREAK_TEST_BUILD GUI fixture executables';ProductionTrustRestoredByteIdentically=$true;ProductionTrustSHA256=$trustHash;ProductionTrustKeyId=([regex]::Match($productionTrustText,'ProductionUpdateKeyId\s*=\s*"(p256-[0-9a-f]{16})"').Groups[1].Value);VerifiedUtc=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $root 'build/v1.4.0-updater-evidence/test-trust-restoration.json') -Encoding UTF8
}
try{
  [void][IO.Directory]::CreateDirectory($temp)
  [void][IO.Directory]::CreateDirectory((Join-Path $root 'build/v1.4.0-updater-evidence'))
  foreach($name in @('EyeBreakReminder.exe','EyeBreakReminder-Setup-x64.exe')){$source=Join-Path $release $name;if(-not(Test-Path -LiteralPath $source -PathType Leaf)){throw "Packaged candidate is missing: $source"};$destination=if($name-eq'EyeBreakReminder.exe'){$originalExe}else{$originalSetup};Copy-Item -LiteralPath $source -Destination $destination}
  Enable-TestBuildTrust
  Invoke-Make 'gui-test'
  $baselineTestExecutable=Join-Path $build 'baseline-test-executable.exe'
  Copy-Item -LiteralPath (Join-Path $build 'EyeBreakReminder.exe') -Destination $baselineTestExecutable -Force
  Copy-Item -LiteralPath $baselineTestExecutable -Destination (Join-Path $release 'EyeBreakReminder.exe') -Force
  & $NsisCompiler -NOCD (Join-Path $root 'installer/setup.nsi');if($LASTEXITCODE-ne0){throw 'NSIS failed to create the disposable 1.4.0 baseline test installer.'}
  Copy-Item -LiteralPath (Join-Path $release 'EyeBreakReminder-Setup-x64.exe') -Destination (Join-Path $build 'baseline-test-setup.exe') -Force
  Set-SourceVersion '1.4.1'
  Invoke-Make 'gui-test'
  Copy-Item -LiteralPath (Join-Path $build 'EyeBreakReminder.exe') -Destination (Join-Path $build 'update-test-executable.exe') -Force
  Copy-Item -LiteralPath (Join-Path $build 'EyeBreakReminder.exe') -Destination (Join-Path $release 'EyeBreakReminder.exe') -Force
  & $NsisCompiler -NOCD (Join-Path $root 'installer/setup.nsi');if($LASTEXITCODE-ne0){throw 'NSIS failed to create the disposable 1.4.1 update test installer.'}
  Copy-Item -LiteralPath (Join-Path $release 'EyeBreakReminder-Setup-x64.exe') -Destination (Join-Path $build 'update-test-setup.exe') -Force
  Invoke-Make 'updater-test-artifacts'
  Copy-Item -LiteralPath (Join-Path $root 'build/updater-failing-installer.exe') -Destination (Join-Path $build 'failing-test-setup.exe') -Force
}finally{
  try{
    if((Get-Content -LiteralPath (Join-Path $root 'VERSION') -Raw).Trim()-ne'1.4.0'){Set-SourceVersion '1.4.0'}
    if(Test-Path -LiteralPath $originalExe){Copy-Item -LiteralPath $originalExe -Destination (Join-Path $release 'EyeBreakReminder.exe') -Force}
    if(Test-Path -LiteralPath $originalSetup){Copy-Item -LiteralPath $originalSetup -Destination (Join-Path $release 'EyeBreakReminder-Setup-x64.exe') -Force}
    if($testTrustActive){Invoke-Make 'gui-test'}
  }finally{Restore-ProductionTrust}
  & python (Join-Path $root 'scripts/verify.py');if($LASTEXITCODE-ne0){throw 'Release package verification failed after restoring the exact candidate files.'}
  $resolvedTemp=[IO.Path]::GetFullPath($temp);$runnerPrefix=$runnerTemp.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar;if(-not$resolvedTemp.StartsWith($runnerPrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Refusing to clean a fixture folder outside RUNNER_TEMP.'};Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
}
$identities=foreach($name in @('baseline-test-setup.exe','baseline-test-executable.exe','EyeBreakReminder.exe','update-test-setup.exe','update-test-executable.exe','failing-test-setup.exe')){$path=Join-Path $build $name;if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "Prepared updater fixture is missing: $name"};$item=Get-Item -LiteralPath $path;[pscustomobject]@{Name=$name;Bytes=$item.Length;SHA256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant();ProductVersion=$item.VersionInfo.ProductVersion}}
$identities|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $root 'build/v1.4.0-updater-evidence/updater-fixture-identities.json') -Encoding UTF8
Write-Output ($identities|Format-Table -AutoSize|Out-String)
