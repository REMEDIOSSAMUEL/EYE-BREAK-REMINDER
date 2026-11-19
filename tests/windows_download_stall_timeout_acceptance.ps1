[CmdletBinding()]
param(
    [string]$EvidencePath = 'build/v1.4.0-updater-evidence/download-stall-timeout.json'
)

$ErrorActionPreference = 'Stop'

function Invoke-CheckedProcess {
    param([string]$FilePath, [string[]]$ArgumentList, [string]$Name)
    & $FilePath @ArgumentList 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "$Name failed with exit code $LASTEXITCODE" }
}

function Quote-ProcessArgument([string]$Value) {
    '"' + $Value.Replace('"', '\"') + '"'
}

if ($env:GITHUB_ACTIONS -cne 'true') {
    throw 'This test installs a disposable test CA in CurrentUser\Root; it may run only on an ephemeral GitHub Actions Windows runner.'
}
if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP) -or
    -not (Test-Path -LiteralPath $env:RUNNER_TEMP -PathType Container)) {
    throw 'RUNNER_TEMP is not available; refusing to create test certificates or staging files.'
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runnerTemp = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')
$root = Join-Path $runnerTemp ('ebr-download-stall-' + [guid]::NewGuid().ToString('N'))
$rootFull = [IO.Path]::GetFullPath($root).TrimEnd('\')
$runnerPrefix = $runnerTemp + '\'
if (-not $rootFull.StartsWith($runnerPrefix, [StringComparison]::OrdinalIgnoreCase) -or
    (Test-Path -LiteralPath $rootFull)) {
    throw 'The unique disposable test directory is not a new child of RUNNER_TEMP.'
}
$null = New-Item -ItemType Directory -Path $rootFull
if (-not (Get-Item -LiteralPath $rootFull).FullName.StartsWith($runnerPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Resolved test directory escaped RUNNER_TEMP; refusing to proceed.'
}

$serverProcess = $null
$serverPid = $null
$trustedThumbprint = $null
$trustInstallAttempted = $false
$certificateRemovalVerified = $true
$runnerTempRootRemoved = $false
$cleanupFailures = [System.Collections.Generic.List[string]]::new()
$finalEvidence = $null
$failure = $null
$serverStdout = Join-Path $rootFull 'server.stdout.log'
$serverStderr = Join-Path $rootFull 'server.stderr.log'
$phase = 'initialization'

try {
    Write-Host "Stall test phase: validate tools and isolated root at $([DateTime]::UtcNow.ToString('o'))"
    $openssl = Get-Command openssl -ErrorAction Stop
    $python = Get-Command python -ErrorAction Stop
    $compiler = Get-Command x86_64-w64-mingw32-g++ -ErrorAction Stop

    $caKey = Join-Path $rootFull 'ephemeral-test-ca.key'
    $caPem = Join-Path $rootFull 'ephemeral-test-ca.pem'
    $caDer = Join-Path $rootFull 'ephemeral-test-ca.cer'
    $leafKey = Join-Path $rootFull 'localhost-test-server.key'
    $leafCsr = Join-Path $rootFull 'localhost-test-server.csr'
    $leafPem = Join-Path $rootFull 'localhost-test-server.pem'
    $leafExt = Join-Path $rootFull 'localhost-test-server.ext'

    $phase = 'generate disposable test CA'
    Write-Host "Stall test phase: $phase"
    Invoke-CheckedProcess $openssl.Source @(
        'req','-x509','-newkey','rsa:2048','-sha256','-nodes','-keyout',$caKey,'-out',$caPem,
        '-days','1','-subj','/CN=EyeBreakReminder-Disposable-DownloadTimeout-Test-CA',
        '-addext','basicConstraints=critical,CA:TRUE,pathlen:0',
        '-addext','keyUsage=critical,keyCertSign,cRLSign'
    ) 'Generate the disposable test certificate authority'
    $phase = 'generate localhost certificate request'
    Write-Host "Stall test phase: $phase"
    Invoke-CheckedProcess $openssl.Source @(
        'req','-newkey','rsa:2048','-sha256','-nodes','-keyout',$leafKey,'-out',$leafCsr,
        '-subj','/CN=localhost'
    ) 'Generate the localhost test-server certificate request'
    @(
        'basicConstraints=critical,CA:FALSE'
        'keyUsage=critical,digitalSignature,keyEncipherment'
        'extendedKeyUsage=serverAuth'
        'subjectAltName=DNS:localhost'
        'subjectKeyIdentifier=hash'
        'authorityKeyIdentifier=keyid,issuer'
    ) | Set-Content -LiteralPath $leafExt -Encoding ascii
    $phase = 'sign localhost certificate'
    Write-Host "Stall test phase: $phase"
    Invoke-CheckedProcess $openssl.Source @(
        'x509','-req','-in',$leafCsr,'-CA',$caPem,'-CAkey',$caKey,'-CAcreateserial',
        '-out',$leafPem,'-days','1','-sha256','-extfile',$leafExt
    ) 'Sign the localhost server certificate with the disposable test CA'
    $phase = 'export disposable CA certificate'
    Write-Host "Stall test phase: $phase"
    Invoke-CheckedProcess $openssl.Source @('x509','-in',$caPem,'-outform','DER','-out',$caDer) 'Prepare the disposable CA for Windows trust'

    $phase = 'load and install disposable CA in CurrentUser Root'
    Write-Host "Stall test phase: $phase"
    $caCertificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($caDer)
    $trustedThumbprint = $caCertificate.Thumbprint
    if ([string]::IsNullOrWhiteSpace($trustedThumbprint)) { throw 'The disposable CA certificate has no thumbprint.' }
    $trustInstallAttempted = $true
    $trust = Import-Certificate -FilePath $caDer -CertStoreLocation Cert:\CurrentUser\Root
    if (-not $trust -or -not $trust.Thumbprint) { throw 'Windows did not import the disposable test CA.' }
    if ([string]$trust.Thumbprint -cne $trustedThumbprint) { throw 'Windows imported a certificate with an unexpected identity.' }

    $phase = 'reserve loopback TLS feed port'
    Write-Host "Stall test phase: $phase"
    $probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::IPv6Any, 0)
    $probe.Server.DualMode = $true
    $probe.Start()
    $port = [int]$probe.LocalEndpoint.Port
    $probe.Stop()

    $statePath = Join-Path $rootFull 'server-state.json'
    $serverScript = Join-Path $PSScriptRoot 'download_stall_timeout_feed.py'
    $serverArgs = @(
        '-u', (Quote-ProcessArgument $serverScript), [string]$port,
        (Quote-ProcessArgument $leafPem), (Quote-ProcessArgument $leafKey),
        (Quote-ProcessArgument $statePath), '20'
    ) -join ' '
    $phase = 'start loopback TLS feed'
    Write-Host "Stall test phase: $phase"
    $serverProcess = Start-Process -FilePath $python.Source -ArgumentList $serverArgs -WindowStyle Hidden `
        -PassThru -RedirectStandardOutput $serverStdout -RedirectStandardError $serverStderr
    $serverPid = $serverProcess.Id

    $readyDeadline = [DateTime]::UtcNow.AddSeconds(10)
    while ([DateTime]::UtcNow -lt $readyDeadline -and -not (Test-Path -LiteralPath $statePath)) {
        if ($serverProcess.HasExited) { throw "The loopback TLS feed exited before listening. $((Get-Content -LiteralPath $serverStderr -Raw -ErrorAction SilentlyContinue))" }
        Start-Sleep -Milliseconds 100
    }
    if (-not (Test-Path -LiteralPath $statePath)) { throw 'The loopback TLS feed did not signal readiness.' }

    $phase = 'compile the native WinHTTP stalled-body test'
    Write-Host "Stall test phase: $phase"
    $testExe = Join-Path $rootFull 'updater-download-stall-timeout.exe'
    Invoke-CheckedProcess $compiler.Source @(
        '-std=c++17','-O2','-DWINVER=0x0A00','-D_WIN32_WINNT=0x0A00',
        (Join-Path $PSScriptRoot 'updater_download_stall_timeout.cpp'),
        '-o',$testExe,'-municode','-lwinhttp','-lbcrypt','-lole32'
    ) 'Compile the focused WinHTTP stalled-body timeout test'

    $phase = 'execute the native WinHTTP stalled-body test'
    Write-Host "Stall test phase: $phase"
    $resultPath = Join-Path $rootFull 'native-test-result.json'
    $testProcess = Start-Process -FilePath $testExe -ArgumentList @(
        [string]$port, (Quote-ProcessArgument $rootFull), (Quote-ProcessArgument $resultPath)
    ) -WindowStyle Hidden -PassThru
    if (-not $testProcess.WaitForExit(15000)) {
        $stalledFeedState = if (Test-Path -LiteralPath $statePath) {
            Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        } else { $null }
        $elapsed = [DateTime]::UtcNow - $testProcess.StartTime.ToUniversalTime()
        Stop-Process -Id $testProcess.Id -Force -ErrorAction Stop
        $testChildTerminated = $testProcess.WaitForExit(5000)
        if (-not $testChildTerminated) { throw "The native timeout-test child PID $($testProcess.Id) did not terminate after the harness stopped it." }
        $finalEvidence = [pscustomobject]@{
            test = 'FAIL-005 actual stalled HTTPS asset-body timeout'
            status = 'FAIL'
            failure = "Native test did not exit within 15 seconds; elapsedMs=$([int]$elapsed.TotalMilliseconds); phase=$phase; feedState=$($stalledFeedState | ConvertTo-Json -Compress -Depth 5)"
            sourceCommit = $env:GITHUB_SHA
            runnerImage = $env:ImageOS
            nativeProcessId = $testProcess.Id
            nativeTestChildTerminated = $testChildTerminated
            feedEvidence = $stalledFeedState
            trust = [pscustomobject]@{ store = 'Cert:\CurrentUser\Root'; installAttempted = $trustInstallAttempted; thumbprint = $trustedThumbprint; removalVerified = $false }
            cleanup = [pscustomobject]@{ runnerTempTestDirectoryRemoved = $false; errors = @() }
            serverStdout = if (Test-Path -LiteralPath $serverStdout) { Get-Content -LiteralPath $serverStdout -Raw -ErrorAction SilentlyContinue } else { $null }
            serverStderr = if (Test-Path -LiteralPath $serverStderr) { Get-Content -LiteralPath $serverStderr -Raw -ErrorAction SilentlyContinue } else { $null }
            laptopRestarted = $false
            destructiveInstallPerformed = $false
        }
        throw $finalEvidence.failure
    }
    if ($testProcess.ExitCode -ne 0) {
        $nativeResult = if (Test-Path -LiteralPath $resultPath) { Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json } else { $null }
        throw "The focused actual-download timeout test failed with exit code $($testProcess.ExitCode): $($nativeResult | ConvertTo-Json -Compress -Depth 5)"
    }
    if (-not (Test-Path -LiteralPath $resultPath)) { throw 'The native test exited successfully without writing its evidence JSON.' }

    $nativeResult = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
    $feedDeadline = [DateTime]::UtcNow.AddSeconds(2)
    $feedState = $null
    do {
        if (Test-Path -LiteralPath $statePath) { $feedState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json }
        if ($feedState -and $feedState.headers_sent) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $feedDeadline)
    if (-not $feedState -or -not $feedState.headers_sent -or $feedState.body_bytes_sent -ne 0) {
        throw 'The server did not prove that it sent HTTP 200 headers and then withheld the complete declared response body.'
    }
    if ($nativeResult.status -ne 'PASS' -or -not $nativeResult.timeout_error_reported -or
        -not $nativeResult.partial_and_final_download_files_removed -or
        -not $nativeResult.preexisting_sentinel_preserved_byte_for_byte) {
        throw 'The native stalled-download assertions did not all pass.'
    }

    $finalEvidence = [pscustomobject]@{
        test = 'FAIL-005 actual stalled HTTPS asset-body timeout'
        status = 'PASS'
        classification = 'real WinHTTP receive timeout against a trusted loopback TLS server; not a timeout-configuration assertion'
        sourceCommit = $env:GITHUB_SHA
        runnerImage = $env:ImageOS
        nativeResult = $nativeResult
        feedEvidence = $feedState
        trust = [pscustomobject]@{ store = 'Cert:\CurrentUser\Root'; ephemeralUserRootInstalled = $true; thumbprint = $trustedThumbprint; removalVerified = $false }
        cleanup = [pscustomobject]@{ runnerTempTestDirectoryRemoved = $false; errors = @() }
        laptopRestarted = $false
        destructiveInstallPerformed = $false
    }
}
catch {
    $failure = $_
    if (-not $finalEvidence) { $finalEvidence = [pscustomobject]@{
        test = 'FAIL-005 actual stalled HTTPS asset-body timeout'
        status = 'FAIL'
        failure = "phase=$phase; $([string]$failure)"
        sourceCommit = $env:GITHUB_SHA
        runnerImage = $env:ImageOS
        trust = [pscustomobject]@{ store = 'Cert:\CurrentUser\Root'; installAttempted = $trustInstallAttempted; thumbprint = $trustedThumbprint; removalVerified = $false }
        cleanup = [pscustomobject]@{ runnerTempTestDirectoryRemoved = $false; errors = @() }
        laptopRestarted = $false
        destructiveInstallPerformed = $false
        serverStdout = if (Test-Path -LiteralPath $serverStdout) { Get-Content -LiteralPath $serverStdout -Raw } else { $null }
        serverStderr = if (Test-Path -LiteralPath $serverStderr) { Get-Content -LiteralPath $serverStderr -Raw } else { $null }
    } }
}
finally {
    if ($serverPid -and (Get-Process -Id $serverPid -ErrorAction SilentlyContinue)) {
        Stop-Process -Id $serverPid -Force -ErrorAction SilentlyContinue
    }
    if ($trustInstallAttempted) {
        $certificateRemovalVerified = $false
        if ([string]::IsNullOrWhiteSpace($trustedThumbprint)) {
            $cleanupFailures.Add('The harness attempted certificate installation but did not retain the exact thumbprint for removal.')
        } else {
            $certificatePath = "Cert:\CurrentUser\Root\$trustedThumbprint"
            if (Test-Path -LiteralPath $certificatePath) {
                try {
                    Remove-Item -LiteralPath $certificatePath -Force -ErrorAction Stop
                } catch {
                    $cleanupFailures.Add("Could not remove disposable CurrentUser Root certificate $trustedThumbprint`: $($_.Exception.Message)")
                }
            }
            if (Test-Path -LiteralPath $certificatePath) {
                $cleanupFailures.Add("Disposable CurrentUser Root certificate $trustedThumbprint remains after cleanup.")
            } else {
                $certificateRemovalVerified = $true
            }
        }
    }
}

 # This is a newly created GUID child of RUNNER_TEMP. Verify its identity
 # and non-reparse status again before recursively deleting only this test root.
$cleanupItem = Get-Item -LiteralPath $rootFull -Force -ErrorAction SilentlyContinue
if (-not $cleanupItem) {
    $runnerTempRootRemoved = $true
} elseif (-not $rootFull.StartsWith($runnerPrefix, [StringComparison]::OrdinalIgnoreCase) -or
    $cleanupItem.Name -cnotlike 'ebr-download-stall-*' -or
    ($cleanupItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
    [IO.Path]::GetFullPath($cleanupItem.FullName) -ine $rootFull) {
    $cleanupFailures.Add('The disposable test directory failed identity/reparse validation and was not recursively deleted.')
} else {
    try {
        Remove-Item -LiteralPath $rootFull -Recurse -Force -ErrorAction Stop
    } catch {
        $cleanupFailures.Add("Could not remove disposable RUNNER_TEMP directory: $($_.Exception.Message)")
    }
    if (Test-Path -LiteralPath $rootFull) {
        $cleanupFailures.Add('The disposable RUNNER_TEMP test directory remains after cleanup.')
    } else {
        $runnerTempRootRemoved = $true
    }
}

if ($finalEvidence) {
    if ($finalEvidence.trust) { $finalEvidence.trust.removalVerified = $certificateRemovalVerified }
    if ($finalEvidence.cleanup) {
        $finalEvidence.cleanup.runnerTempTestDirectoryRemoved = $runnerTempRootRemoved
        $finalEvidence.cleanup.errors = @($cleanupFailures)
    }
}
if (-not $certificateRemovalVerified -or -not $runnerTempRootRemoved -or $cleanupFailures.Count -gt 0) {
    $failure = if ($failure) { "$failure; cleanup verification failed: $($cleanupFailures -join '; ')" } else { "Cleanup verification failed: $($cleanupFailures -join '; ')" }
    if ($finalEvidence) {
        $finalEvidence.status = 'FAIL'
        $finalEvidence | Add-Member -NotePropertyName failure -NotePropertyValue $failure -Force
    }
}

if ($EvidencePath) {
    $evidenceFull = if ([IO.Path]::IsPathRooted($EvidencePath)) { [IO.Path]::GetFullPath($EvidencePath) } else { [IO.Path]::GetFullPath((Join-Path $repoRoot $EvidencePath)) }
    $buildPrefix = ([IO.Path]::GetFullPath((Join-Path $repoRoot 'build'))).TrimEnd('\') + '\'
    if (-not $evidenceFull.StartsWith($buildPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'EvidencePath must be inside the repository build directory.'
    }
    $evidenceParent = Split-Path -Parent $evidenceFull
    $null = New-Item -ItemType Directory -Force -Path $evidenceParent
    $finalEvidence | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $evidenceFull -Encoding utf8
    Write-Host "Evidence: $evidenceFull"
}

if ($failure) {
    Write-Error $failure
    exit 1
}
Write-Host 'PASS: actual WinHTTP HTTPS response-body stall timed out and protected existing data.'
