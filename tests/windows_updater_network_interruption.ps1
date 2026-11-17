param(
    [string]$TestExecutable = '.\build\updater-windows-tests.exe',
    [string]$EvidencePath = '.\build\v1.4.0-updater-evidence\https-interruption.json'
)

$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    throw 'This test starts a loopback CONNECT proxy for real public GitHub HTTPS requests and may run only on a disposable GitHub Actions runner.'
}
Write-Host 'Starting real GitHub HTTPS interruption/retry acceptance through an isolated loopback CONNECT proxy.'

$runnerTemp = [IO.Path]::GetFullPath($env:RUNNER_TEMP)
$runDirectory = Join-Path $runnerTemp ('ebr-updater-https-' + [guid]::NewGuid().ToString('N'))
$runDirectoryFull = [IO.Path]::GetFullPath($runDirectory)
$proxy = $null
$testProcess = $null
$testPassed = $false
$testOutput = ''
$testExitCode = 1
$testError = $null

if (-not $runDirectoryFull.StartsWith($runnerTemp.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The unique test directory did not resolve inside RUNNER_TEMP.'
}

try {
    New-Item -ItemType Directory -Path $runDirectoryFull | Out-Null
    $stage = Join-Path $runDirectoryFull 'stage'
    New-Item -ItemType Directory -Path $stage | Out-Null

    Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

namespace EbrUpdaterNetworkInterruption {
    public sealed class TruncatingConnectProxy : IDisposable {
        private const int CutAfterEncryptedBytes = 65536;
        private readonly TcpListener listener;
        private readonly Thread acceptThread;
        private readonly ConcurrentBag<TcpClient> activeClients = new ConcurrentBag<TcpClient>();
        private readonly object errorLock = new object();
        private volatile bool stopping;
        private string error;
        private int assetConnections;
        private int claimedTruncation;
        private int firstAssetTruncated;
        private long firstAssetForwardedBytes;

        public int Port { get; private set; }
        public int AssetConnections { get { return Interlocked.CompareExchange(ref assetConnections, 0, 0); } }
        public bool FirstAssetTruncated { get { return Interlocked.CompareExchange(ref firstAssetTruncated, 0, 0) == 1; } }
        public long FirstAssetForwardedBytes { get { return Interlocked.Read(ref firstAssetForwardedBytes); } }
        public string Error { get { lock (errorLock) { return error; } } }

        public TruncatingConnectProxy() {
            listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            Port = ((IPEndPoint)listener.LocalEndpoint).Port;
            acceptThread = new Thread(AcceptLoop) { IsBackground = true, Name = "EBR temporary GitHub HTTPS proxy" };
            acceptThread.Start();
        }

        private void SetError(string value) { lock (errorLock) { if (String.IsNullOrEmpty(error)) error = value; } }
        private static string ReadHeaders(NetworkStream stream) {
            byte[] ending = new byte[] { 13, 10, 13, 10 };
            int matched = 0;
            int value;
            int count = 0;
            StringBuilder text = new StringBuilder();
            while ((value = stream.ReadByte()) >= 0 && ++count <= 16384) {
                text.Append((char)value);
                if ((byte)value == ending[matched]) {
                    if (++matched == ending.Length) return text.ToString();
                } else {
                    matched = (byte)value == 13 ? 1 : 0;
                }
            }
            throw new IOException("The HTTPS client did not send a bounded CONNECT request header.");
        }

        private void AcceptLoop() {
            while (!stopping) {
                try {
                    TcpClient client = listener.AcceptTcpClient();
                    activeClients.Add(client);
                    ThreadPool.QueueUserWorkItem(state => Handle((TcpClient)state), client);
                } catch (SocketException e) {
                    if (!stopping) SetError("Proxy accept failed: " + e.Message);
                    return;
                } catch (ObjectDisposedException) { return; }
            }
        }

        private static bool AllowedHost(string host) {
            return String.Equals(host, "github.com", StringComparison.OrdinalIgnoreCase) ||
                   String.Equals(host, "release-assets.githubusercontent.com", StringComparison.OrdinalIgnoreCase) ||
                   String.Equals(host, "objects.githubusercontent.com", StringComparison.OrdinalIgnoreCase) ||
                   String.Equals(host, "github-releases.githubusercontent.com", StringComparison.OrdinalIgnoreCase);
        }
        private static bool IsAssetHost(string host) { return !String.Equals(host, "github.com", StringComparison.OrdinalIgnoreCase); }

        private void Handle(TcpClient client) {
            TcpClient upstream = null;
            try {
                NetworkStream clientStream = client.GetStream();
                string[] request = ReadHeaders(clientStream).Split(new string[] { "\r\n" }, StringSplitOptions.None)[0].Split(' ');
                if (request.Length < 3 || !String.Equals(request[0], "CONNECT", StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException("The test client did not use an HTTPS CONNECT request.");
                string[] authority = request[1].Split(':');
                int port;
                if (authority.Length != 2 || !Int32.TryParse(authority[1], out port) || port != 443 || !AllowedHost(authority[0]))
                    throw new InvalidDataException("The test proxy rejected an unapproved GitHub HTTPS destination: " + request[1]);
                string host = authority[0];
                bool assetHost = IsAssetHost(host);
                bool truncate = assetHost && Interlocked.CompareExchange(ref claimedTruncation, 1, 0) == 0;
                if (assetHost) Interlocked.Increment(ref assetConnections);

                upstream = new TcpClient();
                activeClients.Add(upstream);
                upstream.ReceiveTimeout = 30000;
                upstream.SendTimeout = 30000;
                upstream.Connect(host, 443);
                NetworkStream upstreamStream = upstream.GetStream();
                byte[] established = Encoding.ASCII.GetBytes("HTTP/1.1 200 Connection Established\r\nProxy-Agent: EyeBreakReminder-Test\r\n\r\n");
                clientStream.Write(established, 0, established.Length);
                clientStream.Flush();

                ManualResetEvent finished = new ManualResetEvent(false);
                Thread clientToServer = new Thread(() => Relay(clientStream, upstreamStream, false, truncate, client, upstream, finished)) { IsBackground = true };
                Thread serverToClient = new Thread(() => Relay(upstreamStream, clientStream, true, truncate, client, upstream, finished)) { IsBackground = true };
                clientToServer.Start();
                serverToClient.Start();
                if (!finished.WaitOne(120000)) SetError("An HTTPS tunnel exceeded the two-minute bound for " + host + ".");
                try { client.Close(); } catch { }
                try { upstream.Close(); } catch { }
                clientToServer.Join(2000);
                serverToClient.Join(2000);
                finished.Dispose();
            } catch (Exception e) {
                if (!stopping) SetError(e.GetType().Name + ": " + e.Message);
                try { client.Close(); } catch { }
                if (upstream != null) try { upstream.Close(); } catch { }
            }
        }

        private void Relay(NetworkStream source, NetworkStream destination, bool fromServer, bool truncate, TcpClient client, TcpClient upstream, ManualResetEvent finished) {
            try {
                byte[] buffer = new byte[65536];
                while (!stopping) {
                    int count = source.Read(buffer, 0, buffer.Length);
                    if (count <= 0) break;
                    if (fromServer && truncate) {
                        long previous = Interlocked.Read(ref firstAssetForwardedBytes);
                        int remaining = (int)Math.Max(0, CutAfterEncryptedBytes - previous);
                        int amount = Math.Min(count, remaining);
                        if (amount > 0) {
                            destination.Write(buffer, 0, amount);
                            destination.Flush();
                            Interlocked.Add(ref firstAssetForwardedBytes, amount);
                        }
                        if (previous + amount >= CutAfterEncryptedBytes) {
                            Thread.Sleep(150);
                            Interlocked.Exchange(ref firstAssetTruncated, 1);
                            try { client.Client.LingerState = new LingerOption(true, 0); } catch { }
                            try { client.Close(); } catch { }
                            try { upstream.Close(); } catch { }
                            break;
                        }
                    } else {
                        destination.Write(buffer, 0, count);
                        destination.Flush();
                    }
                }
            } catch (IOException) { }
              catch (SocketException) { }
              catch (ObjectDisposedException) { }
            finally { finished.Set(); }
        }

        public void Dispose() {
            stopping = true;
            try { listener.Stop(); } catch { }
            foreach (TcpClient client in activeClients) { try { client.Close(); } catch { } }
            try { acceptThread.Join(2000); } catch { }
        }
    }
}
'@
    $proxy = [EbrUpdaterNetworkInterruption.TruncatingConnectProxy]::new()
    Write-Host "Loopback CONNECT proxy listening on 127.0.0.1:$($proxy.Port); outbound TLS will be end-to-end to GitHub with normal Windows certificate validation."

    $exePath = [IO.Path]::GetFullPath($TestExecutable)
    if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) { throw "Windows updater test executable is missing: $exePath" }
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $exePath
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.ArgumentList.Add('--https-interruption')
    $startInfo.ArgumentList.Add([string]$proxy.Port)
    $startInfo.ArgumentList.Add($stage)
    $startInfo.Environment['EBR_TEST_HTTPS_PROXY'] = "127.0.0.1:$($proxy.Port)"
    Write-Host 'Launching the updater test binary with a 120-second process bound.'
    $testProcess = [Diagnostics.Process]::Start($startInfo)
    if (-not $testProcess.WaitForExit(120000)) {
        try { $testProcess.Kill($true) } catch { }
        $testExitCode = 124
        $testOutput = 'The public GitHub HTTPS updater test process exceeded its 120-second bound.'
        throw $testOutput
    }
    $testProcess.WaitForExit()
    $testExitCode = $testProcess.ExitCode
    $testOutput = $testProcess.StandardOutput.ReadToEnd() + [Environment]::NewLine + $testProcess.StandardError.ReadToEnd()
    Write-Host "Updater test process exited with code $testExitCode."
    if ($testOutput) { Write-Host $testOutput }
    if ($testExitCode -ne 0) { throw "The real GitHub HTTPS interruption/retry test exited $testExitCode. $testOutput" }
    if ($proxy.Error) { throw "The isolated HTTPS proxy failed: $($proxy.Error)" }
    if ($proxy.AssetConnections -lt 2 -or -not $proxy.FirstAssetTruncated -or $proxy.FirstAssetForwardedBytes -lt 65536) {
        throw "The public asset interruption/retry sequence was incomplete: assetConnections=$($proxy.AssetConnections), firstAssetTruncated=$($proxy.FirstAssetTruncated), forwardedEncryptedBytes=$($proxy.FirstAssetForwardedBytes)."
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
        try { if (-not $testProcess.HasExited) { $testProcess.Kill($true) } } catch { }
        $testProcess.Dispose()
    }
    if ($proxy) { $proxy.Dispose() }
    $evidence = [pscustomobject]@{
        Status = if ($testPassed) { 'PASS' } else { 'FAIL' }
        Test = 'Actual public GitHub HTTPS body interruption followed by a verified retry'
        Commit = $env:GITHUB_SHA
        TLSValidationDisabled = $false
        TemporaryTrustStoreModified = $false
        Proxy = 'Loopback HTTP CONNECT tunnel; TLS remains end-to-end to the approved GitHub host and Windows validates its certificate'
        AssetConnections = if ($proxy) { $proxy.AssetConnections } else { 0 }
        FirstAssetTruncated = if ($proxy) { $proxy.FirstAssetTruncated } else { $false }
        FirstAssetForwardedEncryptedBytes = if ($proxy) { $proxy.FirstAssetForwardedBytes } else { 0 }
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
