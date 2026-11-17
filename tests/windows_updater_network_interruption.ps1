param(
    [string]$TestExecutable = '.\build\updater-windows-tests.exe',
    [string]$EvidencePath = '.\build\v1.4.0-updater-evidence\https-interruption.json'
)

$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    throw 'This test temporarily trusts a unique localhost TLS certificate and may run only on an isolated GitHub Actions runner.'
}

$runnerTemp = [IO.Path]::GetFullPath($env:RUNNER_TEMP)
$runDirectory = Join-Path $runnerTemp ('ebr-updater-https-' + [guid]::NewGuid().ToString('N'))
$runDirectoryFull = [IO.Path]::GetFullPath($runDirectory)
$certificate = $null
$trustedCertificate = $null
$rootStore = $null
$myStore = $null
$server = $null
$testPassed = $false
$testOutput = ''
$testExitCode = 1
$testError = $null

if (-not $runDirectoryFull.StartsWith($runnerTemp.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The unique test directory did not resolve inside RUNNER_TEMP.'
}
New-Item -ItemType Directory -Path $runDirectoryFull | Out-Null
$stage = Join-Path $runDirectoryFull 'stage'
New-Item -ItemType Directory -Path $stage | Out-Null

try {
    $certificate = New-SelfSignedCertificate `
        -Subject 'CN=localhost' `
        -DnsName 'localhost' `
        -CertStoreLocation 'Cert:\CurrentUser\My' `
        -Type SSLServerAuthentication `
        -KeyAlgorithm RSA `
        -KeyLength 2048 `
        -NotAfter (Get-Date).AddHours(4)

    $rootStore = [System.Security.Cryptography.X509Certificates.X509Store]::new(
        [System.Security.Cryptography.X509Certificates.StoreName]::Root,
        [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
    $rootStore.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    $trustedCertificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($certificate.RawData)
    $rootStore.Add($trustedCertificate)

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
    $exePath = [IO.Path]::GetFullPath($TestExecutable)
    if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) { throw "Windows updater test executable is missing: $exePath" }

    $testOutput = (& $exePath '--https-interruption' ([string]$server.Port) $stage 2>&1 | Out-String)
    $testExitCode = $LASTEXITCODE
    if (-not $server.Wait(10000)) { throw 'The HTTPS test server did not finish both expected requests.' }
    if ($server.Error) { throw "The isolated HTTPS server failed: $($server.Error)" }
    if ($testExitCode -ne 0) { throw "The updater network interruption test exited $testExitCode. $testOutput" }
    if ($server.Requests -ne 2 -or $server.FirstResponseBytes -le 0 -or $server.SecondResponseBytes -ne $bytes.Length) {
        throw "The server observed an unexpected transfer sequence: requests=$($server.Requests), firstBytes=$($server.FirstResponseBytes), retryBytes=$($server.SecondResponseBytes)."
    }
    $testPassed = $true
}
catch {
    $testError = $_.Exception.Message
    throw
}
finally {
    if ($server) { $server.Dispose() }
    if ($rootStore -and $trustedCertificate) {
        try { $rootStore.Remove($trustedCertificate) } catch { }
        $rootStore.Close()
    }
    if ($trustedCertificate) { $trustedCertificate.Dispose() }
    if ($certificate) {
        $myStore = [System.Security.Cryptography.X509Certificates.X509Store]::new(
            [System.Security.Cryptography.X509Certificates.StoreName]::My,
            [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
        try {
            $myStore.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
            $myStore.Remove($certificate)
        } catch { }
        finally { if ($myStore) { $myStore.Close() } }
    }
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
