param(
    [Parameter(Mandatory)][string]$CandidateDirectory,
    [Parameter(Mandatory)][string]$EvidencePath
)

$ErrorActionPreference = 'Stop'
$expected = [ordered]@{
    'EyeBreakReminder.exe' = '3dd3fa4c8e9f6200780c7bf0c2340435c7b127ce6b6202b24857105f01f3719a'
    'EyeBreakReminder-Setup-x64.exe' = '7df5c6f61cbb56d813e4eee989637e6fcf692d1879f1446d4776da5928e49c2a'
    'EyeBreakReminder-Portable-x64.zip' = '9337550cf5a2fc2b685672205654d8c674fb8440b01a0ce97c8762bd065f6341'
    'EyeBreakReminder-Source.zip' = 'c8971b3d32b8aad2bf634e40cf753f33b2430f7167effd93063c578e0e05480c'
    'EyeBreakReminder-SHA256.txt' = 'ae6032f9810e7362a27a0b0b15405537aab4ff2fb7ce6efc3c4e97b42e7796df'
    'EyeBreakReminder-UpdateManifest.json' = '88ec256d6c4bb8f0c52946b947cf8778e0966f8cfe84c9f83c551f9a61af84a6'
    'EyeBreakReminder-UpdateManifest.sig' = 'c0906144d52623a4d428df0d69208a849102df731877bbcdb9d366d1f4031992'
}
$entries = @(Get-ChildItem -LiteralPath $CandidateDirectory -Force)
if ($entries.Count -ne $expected.Count) { throw 'The final candidate must contain exactly seven files.' }
$files = foreach ($name in $expected.Keys) {
    $file = Get-Item -LiteralPath (Join-Path $CandidateDirectory $name)
    if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Expected an ordinary candidate file: $name"
    }
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -cne $expected[$name]) { throw "Candidate file does not match artifact 15007651099: $name" }
    [pscustomobject]@{ Name = $name; Bytes = $file.Length; SHA256 = $hash }
}

$manifest = [IO.File]::ReadAllBytes((Join-Path $CandidateDirectory 'EyeBreakReminder-UpdateManifest.json'))
$signature = [IO.File]::ReadAllBytes((Join-Path $CandidateDirectory 'EyeBreakReminder-UpdateManifest.sig'))
$keyId = 'p256-0aff97759ea95258'
$publicKey = [Convert]::FromHexString('fc9802525bb5a5fbd41ade440c9e0a33adf60938e099a16fb383e081d7f966967b4b81346d429deb9196cd2773f4f8f32de0075c24929d545924da832b0947fa')
$publicKeyId = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($publicKey)).Substring(0, 16).ToLowerInvariant()
if ("p256-$publicKeyId" -cne $keyId) { throw 'Production public key identity mismatch.' }
$parameters = [Security.Cryptography.ECParameters]::new()
$parameters.Curve = [Security.Cryptography.ECCurve+NamedCurves]::nistP256
$point = [Security.Cryptography.ECPoint]::new()
$point.X = [byte[]]$publicKey[0..31]
$point.Y = [byte[]]$publicKey[32..63]
$parameters.Q = $point
$verifier = [Security.Cryptography.ECDsa]::Create($parameters)
try {
    if ($signature.Length -ne 64 -or -not $verifier.VerifyData($manifest, $signature,
        [Security.Cryptography.HashAlgorithmName]::SHA256,
        [Security.Cryptography.DSASignatureFormat]::IeeeP1363FixedFieldConcatenation)) {
        throw 'The final candidate manifest did not authenticate under the expected production public key.'
    }
} finally {
    $verifier.Dispose()
}

$archive = [IO.Compression.ZipFile]::OpenRead((Join-Path $CandidateDirectory 'EyeBreakReminder-Portable-x64.zip'))
try {
    $images = @($archive.Entries | Where-Object Name -CEQ 'EyeBreakReminder.exe')
    if ($images.Count -ne 1) { throw 'Expected one executable inside the portable package.' }
    $stream = $images[0].Open()
    try {
        $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant()
        if ($digest -cne $expected['EyeBreakReminder.exe']) { throw 'Portable image identity mismatch.' }
    } finally {
        $stream.Dispose()
    }
} finally {
    $archive.Dispose()
}

$directory = Split-Path -Parent ([IO.Path]::GetFullPath($EvidencePath))
[void][IO.Directory]::CreateDirectory($directory)
[ordered]@{
    Artifact = 15007651099
    FinalizerRun = 45582714164
    SourceCommit = '0f49949a9e753fcca390c25affc99d7698b1ecde'
    ProductionKeyId = $keyId
    ManifestSignatureVerified = $true
    PortableImageVerified = $true
    Files = @($files)
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $EvidencePath -Encoding utf8
