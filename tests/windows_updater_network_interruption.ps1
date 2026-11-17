param(
    [string]$TestExecutable = '.\build\updater-windows-tests.exe',
    [string]$EvidencePath = '.\build\v1.4.0-updater-evidence\https-interruption.json'
)

$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    throw 'This test temporarily trusts a unique localhost TLS certificate and may run only on an isolated GitHub Actions runner.'
}
Write-Host 'Starting isolated WinHTTP HTTPS interruption/retry acceptance.'

$runnerTemp = [IO.Path]::GetFullPath($env:RUNNER_TEMP)
$runDirectory = Join-Path $runnerTemp ('ebr-updater-https-' + [guid]::NewGuid().ToString('N'))
$runDirectoryFull = [IO.Path]::GetFullPath($runDirectory)
$thumbprintPath = Join-Path $runnerTemp 'ebr-updater-https-root-thumbprint.txt'
$certificatePath = Join-Path $runDirectoryFull 'localhost-test-root.cer'
$certificate = $null
$privateKey = $null
$server = $null
$testProcess = $null
$stage = $null
$testPassed = $false
$testOutput = ''
$testExitCode = 1
$testError = $null

if (-not $runDirectoryFull.StartsWith($runnerTemp.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The unique test directory did not resolve inside RUNNER_TEMP.'
}

function Invoke-CertutilBounded([string[]]$Arguments, [int]$TimeoutSeconds) {
    $certutilPath = Join-Path $env:WINDIR 'System32\certutil.exe'
    if (-not (Test-Path -LiteralPath $certutilPath -PathType Leaf)) { throw 'Windows certutil.exe is unavailable for isolated temporary test trust.' }
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $certutilPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    foreach ($argument in $Arguments) { $startInfo.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'Could not start certutil.exe for temporary HTTPS test trust.' }
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill($true) } catch { }
            [void]$process.WaitForExit(5000)
            throw "certutil.exe exceeded its $TimeoutSeconds-second bound."
        }
        return $process.ExitCode
    }
    finally { $process.Dispose() }
}

try {
    New-Item -ItemType Directory -Path $runDirectoryFull | Out-Null
    $stage = Join-Path $runDirectoryFull 'stage'
    New-Item -ItemType Directory -Path $stage | Out-Null
    Write-Host 'Creating the short-lived localhost TLS certificate.'
    $privateKey = [System.Security.Cryptography.RSA]::Create(2048)
    $subject = [System.Security.Cryptography.X509Certificates.X500DistinguishedName]::new('CN=localhost')
    $request = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
        $subject,
        $privateKey,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $request.CertificateExtensions.Add([System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($false, $false, 0, $true))
    $keyUsage = [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature -bor [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyEncipherment
    $request.CertificateExtensions.Add([System.Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new($keyUsage, $true))
    $subjectAlternativeNames = [System.Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
    $subjectAlternativeNames.AddDnsName('localhost')
    $request.CertificateExtensions.Add($subjectAlternativeNames.Build())
    $enhancedKeyUsages = [System.Security.Cryptography.OidCollection]::new()
    [void]$enhancedKeyUsages.Add([System.Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.1'))
    $request.CertificateExtensions.Add([System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($enhancedKeyUsages, $true))
    $certificate = $request.CreateSelfSigned((Get-Date).AddMinutes(-5), (Get-Date).AddHours(4))
    [IO.File]::WriteAllText($thumbprintPath, $certificate.Thumbprint, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllBytes($certificatePath, $certificate.RawData)
    Write-Host 'The TLS certificate was generated in memory and exported without its private key.'
    Write-Host 'Adding the unique localhost TLS certificate to only the runner CurrentUser Root store.'
    $addExitCode = Invoke-CertutilBounded @('-user', '-addstore', '-f', 'Root', $certificatePath) 30
    if ($addExitCode -ne 0) { throw "certutil could not add the temporary HTTPS test root (exit $addExitCode)." }
    $verifyStore = [System.Security.Cryptography.X509Certificates.X509Store]::new(
        [System.Security.Cryptography.X509Certificates.StoreName]::Root,
        [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
    try {
        $verifyStore.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
        $trustedEntries = @($verifyStore.Certificates | Where-Object { $_.Thumbprint -eq $certificate.Thumbprint })
        foreach ($entry in $trustedEntries) { $entry.Dispose() }
        if ($trustedEntries.Count -ne 1) { throw 'The unique localhost TLS certificate was not present in the runner CurrentUser Root store.' }
    }
    finally { $verifyStore.Close(); $verifyStore.Dispose() }
    Write-Host 'TLS certificate trusted only in the runner CurrentUser Root store.'

    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Threading;

namespace EbrUpdaterNetworkInterruption {
    public sealed class TruncatingHttpsServer : IDisposable {
        private readonly X509Certificate2 certificate;
        private readonly byte[] payload;
        private readonly TcpListener listener;
        private readonly Thread worker;
        public int Port { get; private set; }
        public int Requests { get; private set; }
        public int FirstResponseBytes { get; private set; }
        public int SecondResponseBytes { get; private set; }
        public string Error { get; private set; }

        public TruncatingHttpsServer(X509Certificate2 cert, byte[] bytes) {
            certificate = cert;
            payload = bytes;
            listener = new TcpListener(IPAddress.IPv6Loopback, 0);
            listener.Server.DualMode = true;
            listener.Start();
            Port = ((IPEndPoint)listener.LocalEndpoint).Port;
            worker = new Thread(Serve) { IsBackground = true, Name = "EBR isolated HTTPS test server" };
            worker.Start();
        }

        private static void ReadRequestHeaders(Stream stream) {
            byte[] terminator = new byte[] { 13, 10, 13, 10 };
            int matched = 0;
            int value;
            int count = 0;
            while ((value = stream.ReadByte()) >= 0 && ++count <= 16384) {
                if ((byte)value == terminator[matched]) {
                    if (++matched == 4) return;
                } else {
                    matched = (byte)value == 13 ? 1 : 0;
                }
            }
            throw new IOException("The HTTPS client did not send a complete request header.");
        }

        private void Serve() {
            try {
                for (int requestIndex = 0; requestIndex < 2; requestIndex++) {
                    using (TcpClient client = listener.AcceptTcpClient()) {
                        SslStream tls = new SslStream(client.GetStream(), false);
                        try {
                            tls.AuthenticateAsServer(certificate, false, SslProtocols.Tls12, false);
                            ReadRequestHeaders(tls);
                            Requests++;
                            byte[] header = Encoding.ASCII.GetBytes(
                                "HTTP/1.1 200 OK\r\nContent-Length: " + payload.Length +
                                "\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n\r\n");
                            tls.Write(header, 0, header.Length);
                            if (requestIndex == 0) {
                                FirstResponseBytes = Math.Max(1, payload.Length / 8);
                                tls.Write(payload, 0, FirstResponseBytes);
                                tls.Flush();
                                Thread.Sleep(200);
                                client.Client.LingerState = new LingerOption(true, 0);
                                client.Close();
                            } else {
                                SecondResponseBytes = payload.Length;
                                tls.Write(payload, 0, payload.Length);
                                tls.Flush();
                            }
                        } finally {
                            try { tls.Dispose(); } catch { }
                        }
                    }
                }
            } catch (Exception error) {
                Error = error.GetType().Name + ": " + error.Message;
            }
        }

        public bool Wait(int milliseconds) { return worker.Join(milliseconds); }
        public void Stop() { try { listener.Stop(); } catch { } }
        public void Dispose() { Stop(); if (worker.IsAlive) worker.Join(2000); }
    }
}
'@

    $bytes = [byte[]]::new(1MB)
    for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [byte](($i * 37 + 11) -band 255) }
    $server = [EbrUpdaterNetworkInterruption.TruncatingHttpsServer]::new($certificate, $bytes)
    Write-Host "Loopback HTTPS server is listening on localhost:$($server.Port)."
    $exePath = [IO.Path]::GetFullPath($TestExecutable)
    if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) { throw "Windows updater test executable is missing: $exePath" }

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $exePath
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.ArgumentList.Add('--https-interruption')
    $startInfo.ArgumentList.Add([string]$server.Port)
    $startInfo.ArgumentList.Add($stage)
    Write-Host 'Launching the updater test binary with a 60-second process bound.'
    $testProcess = [Diagnostics.Process]::Start($startInfo)
    if (-not $testProcess.WaitForExit(60000)) {
        try { $testProcess.Kill() } catch { }
        $testExitCode = 124
        $testOutput = 'The WinHTTP updater test process exceeded its 60-second bound.'
        throw $testOutput
    }
    $testProcess.WaitForExit()
    $testExitCode = $testProcess.ExitCode
    $testOutput = $testProcess.StandardOutput.ReadToEnd() + [Environment]::NewLine + $testProcess.StandardError.ReadToEnd()
    Write-Host "Updater test process exited with code $testExitCode."
    if (-not $server.Wait(3000)) { throw 'The HTTPS test server did not finish both expected requests within three seconds.' }
    if ($server.Error) { throw "The isolated HTTPS server failed: $($server.Error)" }
    if ($testExitCode -ne 0) { throw "The updater network interruption test exited $testExitCode. $testOutput" }
    if ($server.Requests -ne 2 -or $server.FirstResponseBytes -le 0 -or $server.SecondResponseBytes -ne $bytes.Length) {
        throw "The server observed an unexpected transfer sequence: requests=$($server.Requests), firstBytes=$($server.FirstResponseBytes), retryBytes=$($server.SecondResponseBytes)."
    }
    $testPassed = $true
}
catch {
    $testError = $_.Exception.Message
    Write-Host "HTTPS interruption test stopped: $testError"
    throw
}
finally {
    if ($testProcess) {
        try { if (-not $testProcess.HasExited) { $testProcess.Kill() } } catch { }
        $testProcess.Dispose()
    }
    if ($server) { $server.Dispose() }
    if (Test-Path -LiteralPath $thumbprintPath -PathType Leaf) {
        $cleanupThumbprint = (Get-Content -LiteralPath $thumbprintPath -Raw).Trim()
        if ($cleanupThumbprint -match '^[A-Fa-f0-9]{40}$') {
            try {
                $deleteExitCode = Invoke-CertutilBounded @('-user', '-delstore', 'Root', $cleanupThumbprint) 15
                $checkStore = [System.Security.Cryptography.X509Certificates.X509Store]::new(
                    [System.Security.Cryptography.X509Certificates.StoreName]::Root,
                    [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
                $checkOpened = $false
                try {
                    $checkStore.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
                    $checkOpened = $true
                    $remaining = @($checkStore.Certificates | Where-Object { $_.Thumbprint -eq $cleanupThumbprint })
                    foreach ($entry in $remaining) { $entry.Dispose() }
                    if ($remaining.Count) {
                        $testPassed = $false
                        $testError = "Temporary HTTPS root cleanup failed (certutil exit $deleteExitCode); matching certificate remains in CurrentUser Root."
                    }
                }
                finally { if ($checkOpened) { $checkStore.Close() }; $checkStore.Dispose() }
            }
            catch {
                $testPassed = $false
                $testError = "Could not verify temporary HTTPS root cleanup: $($_.Exception.Message)"
            }
        } else {
            $testPassed = $false
            $testError = 'The temporary HTTPS root thumbprint was malformed; cleanup was refused.'
        }
    }
    if ($certificate) { $certificate.Dispose() }
    if ($privateKey) { $privateKey.Dispose() }
    Remove-Item -LiteralPath $thumbprintPath -Force -ErrorAction SilentlyContinue
    $evidence = [pscustomobject]@{
        Status = if ($testPassed) { 'PASS' } else { 'FAIL' }
        Test = 'Actual WinHTTP HTTPS body interruption followed by a new verified retry'
        Commit = $env:GITHUB_SHA
        TLSValidationDisabled = $false
        TemporaryTrustScope = 'Unique localhost leaf certificate in CurrentUser Root; removed in finally'
        Requests = if ($server) { $server.Requests } else { 0 }
        InterruptedResponseBytes = if ($server) { $server.FirstResponseBytes } else { 0 }
        RetryResponseBytes = if ($server) { $server.SecondResponseBytes } else { 0 }
        TestExitCode = $testExitCode
        TestOutput = $testOutput.Trim()
        Error = $testError
        Utc = [DateTime]::UtcNow.ToString('o')
    }
    $evidenceFull = [IO.Path]::GetFullPath($EvidencePath)
    $evidenceParent = Split-Path -Parent $evidenceFull
    New-Item -ItemType Directory -Path $evidenceParent -Force | Out-Null
    $evidence | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $evidenceFull -Encoding UTF8
    if (Test-Path -LiteralPath $runDirectoryFull) {
        if (-not $runDirectoryFull.StartsWith($runnerTemp.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Refusing to clean a test path outside RUNNER_TEMP.'
        }
        Remove-Item -LiteralPath $runDirectoryFull -Recurse -Force
    }
}
