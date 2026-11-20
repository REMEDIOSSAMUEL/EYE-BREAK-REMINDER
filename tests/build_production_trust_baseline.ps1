param(
  [string]$OutputDirectory = (Join-Path $env:RUNNER_TEMP 'EyeBreakReminder-ProductionTrust-Baseline-1.3.0')
)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_OS -ne 'Windows') { throw 'The production-trust baseline build is restricted to an isolated Windows Actions runner.' }

$sourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$fixtureRoot = [IO.Path]::GetFullPath($OutputDirectory)
$runnerTemp = [IO.Path]::GetFullPath($env:RUNNER_TEMP)
$prefix = $runnerTemp.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if (-not $fixtureRoot.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $fixtureRoot)) { throw 'Baseline output must be a new directory below RUNNER_TEMP.' }

$msysRoot = $env:MSYS2_ROOT
$mingwBin = if ($msysRoot) { Join-Path $msysRoot 'mingw64\bin' } else { $null }
if (-not $mingwBin -or -not (Test-Path -LiteralPath $mingwBin -PathType Container)) { throw 'The Windows runner MINGW64 compiler directory is unavailable.' }
$windres = Join-Path $mingwBin 'windres.exe'
$compiler = Join-Path $mingwBin 'x86_64-w64-mingw32-g++.exe'
$strip = Join-Path $mingwBin 'x86_64-w64-mingw32-strip.exe'
foreach ($tool in @($windres, $compiler, $strip)) { if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { throw "Required MINGW64 tool is missing: $tool" } }

[void][IO.Directory]::CreateDirectory((Join-Path $fixtureRoot 'src'))
[void][IO.Directory]::CreateDirectory((Join-Path $fixtureRoot 'assets'))
[void][IO.Directory]::CreateDirectory((Join-Path $fixtureRoot 'release'))
foreach ($name in @('app.cpp','core.hpp','theme.hpp','update_checker.hpp','update_client.hpp','update_coordinator.hpp','update_accessibility.hpp','update_manifest.hpp','update_signature_win.hpp','update_trust.hpp','windows_services.hpp','app.manifest','resources.rc')) {
  Copy-Item -LiteralPath (Join-Path $sourceRoot "src\$name") -Destination (Join-Path $fixtureRoot "src\$name")
}
foreach ($name in @('App.ico','Gentle.wav','Bell.wav','Chime.wav','Clear.wav','Soft.wav')) {
  Copy-Item -LiteralPath (Join-Path $sourceRoot "assets\$name") -Destination (Join-Path $fixtureRoot "assets\$name")
}
$resourcePath = Join-Path $fixtureRoot 'src\resources.rc'
$resourceText = [IO.File]::ReadAllText($resourcePath)
$resourceText = $resourceText.Replace('1,4,0,0','1,3,0,0').Replace('1.4.0.0','1.3.0.0').Replace('1.4.0','1.3.0')
if (-not $resourceText.Contains('PRODUCTVERSION 1,3,0,0') -or -not $resourceText.Contains('"ProductVersion", "1.3.0')) { throw 'The isolated baseline version resource was not changed to v1.3.0.' }
[IO.File]::WriteAllText($resourcePath, $resourceText, [Text.UTF8Encoding]::new($false))

$compilerArgs = @(
  '-std=c++17','-O2','-Wall','-Wextra','-Wpedantic','-Werror','-municode','-mwindows','-static','-static-libgcc','-static-libstdc++',
  '-D_WIN32_WINNT=0x0A00','-DWINVER=0x0A00','-DUNICODE','-D_UNICODE','-DEYEBREAK_TEST_BUILD',
  'src/app.cpp','release/resources.o','-o','release/EyeBreakReminder.exe',
  '-lcomctl32','-lcomdlg32','-ldwmapi','-lwtsapi32','-lwinmm','-lgdiplus','-lshell32','-lole32','-loleaut32','-luuid','-ladvapi32','-luxtheme','-lwinhttp','-lversion','-lbcrypt',
  '-Wl,--dynamicbase,--nxcompat,--high-entropy-va'
)
$originalPath = $env:PATH
try {
  $env:PATH = $mingwBin + [IO.Path]::PathSeparator + $originalPath
  Push-Location $fixtureRoot
  try {
    & $windres 'src/resources.rc' '-O' 'coff' '-o' 'release/resources.o'
    if ($LASTEXITCODE -ne 0) { throw 'Could not compile isolated v1.3.0 Windows resources.' }
    & $compiler @compilerArgs
    if ($LASTEXITCODE -ne 0) { throw 'Could not compile the production-trust v1.3.0 GUI baseline.' }
    & $strip '--preserve-dates' 'release/EyeBreakReminder.exe'
    if ($LASTEXITCODE -ne 0) { throw 'Could not strip the isolated baseline executable.' }
  } finally { Pop-Location }
} finally { $env:PATH = $originalPath }

$exe = Get-Item -LiteralPath (Join-Path $fixtureRoot 'release\EyeBreakReminder.exe')
if ($exe.VersionInfo.ProductVersion -notmatch '^1\.3\.0(\.0)?$') { throw "The isolated baseline has unexpected version '$($exe.VersionInfo.ProductVersion)'." }
$trust = [IO.File]::ReadAllText((Join-Path $fixtureRoot 'src\update_trust.hpp'))
if ($trust -notmatch 'ProductionUpdateKeyId\s*=\s*"p256-0aff97759ea95258"' -or $trust -match 'TestUpdateKey|TestPublicKey|EYBREAK_TEST_BUILD') { throw 'The baseline does not contain only the embedded production trust root.' }
[pscustomobject]@{Status='PASS';Application='Eye Break Reminder';Version=$exe.VersionInfo.ProductVersion;Executable=$exe.FullName;Bytes=$exe.Length;SHA256=(Get-FileHash -LiteralPath $exe.FullName -Algorithm SHA256).Hash.ToLowerInvariant();ProductionKeyId='p256-0aff97759ea95258';Purpose='Disposable v1.3.0 version-resource baseline built from the exact reviewed source; test-only local metadata and data-directory hooks enabled; no test verification key is provisioned.'} | ConvertTo-Json -Depth 4 | Write-Output
