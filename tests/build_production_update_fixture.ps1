param(
  [string]$OutputDirectory = (Join-Path $env:RUNNER_TEMP 'EyeBreakReminder-Production-Update-Fixture')
)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true') { throw 'Production update fixture builds are restricted to a disposable GitHub Actions Windows runner.' }

$sourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$fixtureRoot = [IO.Path]::GetFullPath($OutputDirectory)
$runnerTemp = [IO.Path]::GetFullPath($env:RUNNER_TEMP)
$prefix = $runnerTemp.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if (-not $fixtureRoot.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture output must remain under RUNNER_TEMP.' }
if (Test-Path -LiteralPath $fixtureRoot) { throw "Refusing to reuse an existing production-update fixture folder: $fixtureRoot" }

function Invoke-Checked([string]$Executable, [string[]]$Arguments, [string]$Label) {
  Write-Host "Running $Label"
  & $Executable @Arguments
  if ($LASTEXITCODE -ne 0) { throw "$Label failed with exit code $LASTEXITCODE." }
}

[void][IO.Directory]::CreateDirectory($fixtureRoot)
foreach ($directory in @('src', 'assets', 'installer', 'docs', 'release')) {
  [void][IO.Directory]::CreateDirectory((Join-Path $fixtureRoot $directory))
}
foreach ($name in @('app.cpp', 'core.hpp', 'theme.hpp', 'update_checker.hpp', 'update_client.hpp', 'update_coordinator.hpp', 'update_accessibility.hpp', 'windows_services.hpp', 'app.manifest', 'resources.rc')) {
  Copy-Item -LiteralPath (Join-Path $sourceRoot "src\$name") -Destination (Join-Path $fixtureRoot "src\$name")
}
foreach ($name in @('App.ico', 'Gentle.wav', 'Bell.wav', 'Chime.wav', 'Clear.wav', 'Soft.wav')) {
  Copy-Item -LiteralPath (Join-Path $sourceRoot "assets\$name") -Destination (Join-Path $fixtureRoot "assets\$name")
}
foreach ($name in @('PRIVACY.md', 'VERIFICATION.md', 'THIRD-PARTY-LICENSES.txt')) {
  Copy-Item -LiteralPath (Join-Path $sourceRoot "docs\$name") -Destination (Join-Path $fixtureRoot "docs\$name")
}
Copy-Item -LiteralPath (Join-Path $sourceRoot 'README.md') -Destination (Join-Path $fixtureRoot 'README.md')
Copy-Item -LiteralPath (Join-Path $sourceRoot 'installer\setup.nsi') -Destination (Join-Path $fixtureRoot 'installer\setup.nsi')

$resourcePath = Join-Path $fixtureRoot 'src\resources.rc'
$resourceText = [IO.File]::ReadAllText($resourcePath)
$resourceText = $resourceText.Replace('1,4,0,0', '1,4,1,0').Replace('1.4.0.0', '1.4.1.0').Replace('1.4.0', '1.4.1')
if (-not $resourceText.Contains('PRODUCTVERSION 1,4,1,0') -or -not $resourceText.Contains('"ProductVersion", "1.4.1')) { throw 'The controlled successor resource version was not fully rewritten.' }
[IO.File]::WriteAllText($resourcePath, $resourceText, [Text.UTF8Encoding]::new($false))

$installerPath = Join-Path $fixtureRoot 'installer\setup.nsi'
$installerText = [IO.File]::ReadAllText($installerPath).Replace('1.4.0', '1.4.1')
if (-not $installerText.Contains('VIProductVersion "1.4.1.0"')) { throw 'The controlled successor installer version was not rewritten.' }
[IO.File]::WriteAllText($installerPath, $installerText, [Text.UTF8Encoding]::new($false))

$msysRoot = $env:MSYS2_ROOT
$mingwBin = if (-not [string]::IsNullOrWhiteSpace($msysRoot)) { Join-Path $msysRoot 'mingw64\bin' } else { $null }
if ([string]::IsNullOrWhiteSpace($mingwBin) -or -not (Test-Path -LiteralPath $mingwBin -PathType Container)) { throw 'The disposable Windows runner did not expose the MSYS2 MINGW64 tool directory.' }
function Resolve-MingwTool([string[]]$Names) {
  foreach ($name in $Names) {
    if ($mingwBin) {
      $candidate = Join-Path $mingwBin $name
      if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    $command = Get-Command $name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
  }
  throw "Required MSYS2 tool not found: $($Names -join ' or ')"
}
$windres = Resolve-MingwTool @('windres.exe')
$compiler = Resolve-MingwTool @('x86_64-w64-mingw32-g++.exe')
$strip = Resolve-MingwTool @('x86_64-w64-mingw32-strip.exe', 'strip.exe')
$makensis = Join-Path $env:NSISDIR 'makensis.exe'
Write-Host "MSYS2 tool root: $mingwBin"
if (-not (Test-Path -LiteralPath $makensis -PathType Leaf)) { throw "Pinned NSIS 3.11 compiler was not found: $makensis" }

$compilerArgs = @(
  '-std=c++17', '-O2', '-Wall', '-Wextra', '-Wpedantic', '-Werror', '-municode', '-mwindows', '-static', '-static-libgcc', '-static-libstdc++',
  '-D_WIN32_WINNT=0x0A00', '-DWINVER=0x0A00', '-DUNICODE', '-D_UNICODE', 'src/app.cpp', 'release/resources.o', '-o', 'release/EyeBreakReminder.exe',
  '-lcomctl32', '-lcomdlg32', '-ldwmapi', '-lwtsapi32', '-lwinmm', '-lgdiplus', '-lshell32', '-lole32', '-loleaut32', '-luuid', '-ladvapi32', '-luxtheme', '-lwinhttp', '-lversion', '-lbcrypt',
  '-Wl,--dynamicbase,--nxcompat,--high-entropy-va'
)
$originalPath = $env:PATH
try {
  $env:PATH = $mingwBin + [IO.Path]::PathSeparator + $originalPath
  Push-Location $fixtureRoot
  try {
    Invoke-Checked $windres @('src/resources.rc', '-O', 'coff', '-o', 'release/resources.o') 'compile controlled successor Windows resources'
    Invoke-Checked $compiler $compilerArgs 'compile the unmodified production updater as controlled v1.4.1'
    Invoke-Checked $strip @('release/EyeBreakReminder.exe') 'strip controlled successor application'
    Invoke-Checked $makensis @('-NOCD', 'installer/setup.nsi') 'build controlled successor installer with pinned NSIS 3.11'
  } finally {
    Pop-Location
  }
} finally {
  $env:PATH = $originalPath
}

$app = Get-Item -LiteralPath (Join-Path $fixtureRoot 'release\EyeBreakReminder.exe')
$setup = Get-Item -LiteralPath (Join-Path $fixtureRoot 'release\EyeBreakReminder-Setup-x64.exe')
if ($app.VersionInfo.ProductVersion -ne '1.4.1.0' -and $app.VersionInfo.ProductVersion -ne '1.4.1') { throw "Controlled application has unexpected product version '$($app.VersionInfo.ProductVersion)'." }
if ($setup.VersionInfo.ProductVersion -ne '1.4.1.0' -and $setup.VersionInfo.ProductVersion -ne '1.4.1') { throw "Controlled installer has unexpected product version '$($setup.VersionInfo.ProductVersion)'." }
$identity = [pscustomobject]@{
  Status = 'PASS'
  Kind = 'Test-only controlled successor built without EYEBREAK_TEST_BUILD'
  SourceCommit = $env:GITHUB_SHA
  FixtureSourceRoot = $fixtureRoot
  Application = [pscustomobject]@{ Name=$app.Name; ProductVersion=$app.VersionInfo.ProductVersion; Bytes=$app.Length; SHA256=(Get-FileHash -LiteralPath $app.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
  Installer = [pscustomobject]@{ Name=$setup.Name; ProductVersion=$setup.VersionInfo.ProductVersion; Bytes=$setup.Length; SHA256=(Get-FileHash -LiteralPath $setup.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
  TestEndpointOverrideCompiledIntoFixture = $false
  ProductionSourceVersionOnlyChanged = @('src/resources.rc version resource', 'installer/setup.nsi version resource')
}
$identityPath = Join-Path (Join-Path $sourceRoot 'build\v1.4.0-updater-evidence') 'production-update-fixture-identities.json'
New-Item -ItemType Directory -Path (Split-Path -Parent $identityPath) -Force | Out-Null
$identity | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $identityPath -Encoding UTF8
Write-Host ($identity | ConvertTo-Json -Depth 6)
