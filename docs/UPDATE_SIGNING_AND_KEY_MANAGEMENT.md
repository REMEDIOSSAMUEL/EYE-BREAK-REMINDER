# Update signing and key management

## Production identity and custody

Eye Break Reminder update metadata uses ECDSA P-256 with SHA-256. The production key ID is `p256-0aff97759ea95258`; its public key is embedded in `src/update_trust.hpp`. Production verification cannot be overridden by an environment variable, command line, test configuration, or release asset.

The owner confirmed an encrypted password-manager backup. Record the backup status exactly as: **“Owner confirms encrypted production-key backup. Independent backup restoration not performed.”** The encrypted private key is at `%LOCALAPPDATA%\EyeBreakReminderSigning\production-private.pem`, outside the checkout and OneDrive, under a current-user-only Windows ACL. The matching public PEM is `production-public.pem`. Never commit, package, upload, print, or move the private key into a build or synchronized folder. Never put the passphrase in chat, an environment variable, a command line, script, or log.

OpenSSL prompts locally for the encrypted PEM passphrase during signing. Use a visible local Windows console and enter it only at that prompt. Do not use production signing credentials in GitHub Actions or expose signing capability to pull-request code. Production signatures are only for the reviewed Eye Break Reminder release candidate.

Disposable Windows CNG/OpenSSL test keys are generated for individual test runs. They are not stored as production trust roots. Only `EYBREAK_TEST_BUILD` can read a test public-key fixture or use local update/data overrides. Production builds always verify with the embedded production root.

## What the signature protects

GitHub HTTPS protects the connection and GitHub's SHA-256 digest detects corruption relative to GitHub metadata. If repository or publishing credentials are compromised, an attacker could change both payload and GitHub digest. The update manifest adds independent maintainer authorization after the trusted initial installation.

A valid manifest signature authenticates exact canonical metadata and binds it to the installer and portable executable digests. It does not Authenticode-sign Windows binaries, establish a Windows publisher name, or guarantee removal of SmartScreen warnings.

## Exact signed format

The release metadata files are:

- `EyeBreakReminder-UpdateManifest.json`
- `EyeBreakReminder-UpdateManifest.sig`

The signature covers the complete canonical manifest byte sequence: compact ASCII JSON, no BOM, whitespace, escapes, or trailing newline. Schema version 1 has fixed property order and fixed asset order. Duplicate, unknown, missing, reordered, malformed, or noncanonical content is rejected. The detached signature is exactly 64 raw IEEE P1363 bytes (`r` then `s`, 32-byte big-endian integers each), not DER or PEM.

The signed schema binds schema version, application identity, official repository, stable release version and channel, supported x64 architecture, key ID, UTC issue/expiry timestamps, and exactly two role-specific payload entries. The entries are `EyeBreakReminder-Setup-x64.exe` (`installer`, `installed`) and `EyeBreakReminder.exe` (`portable-update`, `portable`). Each binds architecture, exact file size, and lowercase SHA-256. Metadata expires within 90 days. A manifest must match the discovered release tag and be newer than the installed version. There is no unsigned fallback or user signature bypass.

## Production and test roots

The production public key is generated from the owner-controlled production identity and committed in `src/update_trust.hpp`. The private key remains local and encrypted. Test roots are ephemeral and are never copied into that header or a production build.

The focused CNG and Python tests exercise valid signatures, wrong keys, malformed signatures, modified/noncanonical manifests, exact asset-role binding, expiry, version checks, and test-root rejection. The acceptance matrix records current outcomes and evidence URLs.

## Generate, embed, and verify a key

The existing production identity must not be replaced or regenerated. For a future new identity only, run the generator in a new dedicated user-protected directory outside the repository, OneDrive, and temporary folders. It creates an encrypted P-256 private PEM and matching public PEM; its Windows ACL checks restrict the directory and private file to the current user. The generator never runs implicitly:

```powershell
$keyDirectory = Join-Path $env:LOCALAPPDATA 'EyeBreakReminderSigning-New'
New-Item -ItemType Directory -Path $keyDirectory
python scripts/update_signing.py generate `
  --private-key (Join-Path $keyDirectory 'production-private.pem') `
  --public-key (Join-Path $keyDirectory 'production-public.pem')
```

This command is for a deliberate key rotation only. Do not run it against the existing key directory. The current public key is embedded with:

```powershell
python scripts/update_signing.py embed-public `
  --public-key (Join-Path $env:LOCALAPPDATA 'EyeBreakReminderSigning\production-public.pem')
```

The key pair is verified by deriving the public key from the encrypted private key through the protected local prompt and confirming the key ID. The owner already completed this local check for the existing identity.

## Sign and verify a release

Build, test, and freeze the candidate first. Where Authenticode is available, apply and verify it before creating portable packages and final hashes. The v1.4.0 policy allows an unsigned installer; do not change payload bytes after generating the signed manifest.

Use a successful `ProductionCandidateOnly` Windows acceptance run on the feature branch. Verify its branch, full source commit, gate, exact five-file candidate identities, and retained artifact before signing. The following PowerShell shows the protected local procedure; replace the run ID with the final successful run:

```powershell
$ebrKeyDir = Join-Path $env:LOCALAPPDATA 'EyeBreakReminderSigning'
$candidateRunId = '00000000000'
$run = gh api "repos/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/$candidateRunId" | ConvertFrom-Json
if ($run.status -cne 'completed' -or $run.conclusion -cne 'success' -or $run.head_branch -cne 'feature/v1.4.0-automatic-updater') { throw 'Candidate run is not a successful feature-branch run.' }
$candidateSourceCommit = $run.head_sha
$candidateRoot = Join-Path $env:TEMP "EyeBreakReminder-v1.4.0-candidate-$candidateRunId"
gh run download $candidateRunId --repo REMEDIOSSAMUEL/EYE-BREAK-REMINDER `
  --name "eye-break-reminder-v1.4.0-candidate-$candidateRunId" --dir $candidateRoot
if ($LASTEXITCODE -ne 0) { throw 'Candidate artifact download failed.' }
$release = Join-Path $candidateRoot 'release'
$provenance = Get-Content (Join-Path $candidateRoot 'build/v1.4.0-updater-evidence/candidate-provenance.json') -Raw | ConvertFrom-Json
$gate = Get-Content (Join-Path $candidateRoot 'build/v1.4.0-updater-evidence/windows-acceptance-gate.json') -Raw | ConvertFrom-Json
if ($provenance.SourceCommit -cne $candidateSourceCommit -or $provenance.RunId -ne $candidateRunId -or $gate.Status -cne 'PASS' -or $gate.Scope -cne 'ProductionCandidateOnly') { throw 'Candidate provenance or gate is invalid.' }
$identities = @(Get-Content (Join-Path $candidateRoot 'build/v1.4.0-updater-evidence/release-artifact-identities.json') -Raw | ConvertFrom-Json)
if ($identities.Count -ne 5 -or @(Get-ChildItem $release -File).Count -ne 5) { throw 'Candidate file set is not the expected five files.' }
foreach ($item in $identities) {
  $file = Get-Item (Join-Path $release $item.Name)
  if ($file.Length -ne [long]$item.Bytes -or (Get-FileHash $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -cne $item.SHA256) { throw "Candidate identity mismatch: $($item.Name)" }
}
$metadataDir = Join-Path $ebrKeyDir "v1.4.0-signed-metadata-$candidateRunId"
New-Item -ItemType Directory -Path $metadataDir
$expiresAt = (Get-Date).ToUniversalTime().AddDays(60).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
python scripts/update_signing.py sign `
  --private-key (Join-Path $ebrKeyDir 'production-private.pem') `
  --public-key (Join-Path $ebrKeyDir 'production-public.pem') `
  --version 1.4.0 --expires-at $expiresAt `
  --installer (Join-Path $release 'EyeBreakReminder-Setup-x64.exe') `
  --portable (Join-Path $release 'EyeBreakReminder.exe') `
  --manifest (Join-Path $metadataDir 'EyeBreakReminder-UpdateManifest.json') `
  --signature (Join-Path $metadataDir 'EyeBreakReminder-UpdateManifest.sig')
if ($LASTEXITCODE -ne 0) { throw 'Local production manifest signing failed.' }
python scripts/update_signing.py verify `
  --public-key (Join-Path $ebrKeyDir 'production-public.pem') `
  --manifest (Join-Path $metadataDir 'EyeBreakReminder-UpdateManifest.json') `
  --signature (Join-Path $metadataDir 'EyeBreakReminder-UpdateManifest.sig')
if ($LASTEXITCODE -ne 0) { throw 'Public-key signature verification failed.' }
python scripts/update_signing.py verify-embedded `
  --manifest (Join-Path $metadataDir 'EyeBreakReminder-UpdateManifest.json') `
  --signature (Join-Path $metadataDir 'EyeBreakReminder-UpdateManifest.sig')
if ($LASTEXITCODE -ne 0) { throw 'Embedded production-key signature verification failed.' }
```

The signer validates the canonical schema and asset names, hashes the candidate EXE payloads, asks OpenSSL to prompt locally, converts DER ECDSA output into the raw 64-byte format, verifies against both the public PEM and embedded application key, and rehashes the payloads before writing metadata. It refuses to overwrite outputs or use private-key paths inside the checkout, OneDrive roots, or temporary directories.

Copy only the public manifest and signature into `release-inputs/v1.4.0`, plus a pointer containing the candidate run ID and source commit. Commit/push those three public files on `feature/v1.4.0-automatic-updater`. The finalizer checks that the commit after the candidate changes only those metadata inputs, verifies the required CI check and exact artifact provenance, validates all seven release files, and verifies the signature with OpenSSL and Windows CNG. A separate job clean-downloads and independently verifies every file. A further Windows job exercises the authentic signed v1.4.0 transaction against an isolated v1.3.0 baseline, rejects a disposable test-key signature, installs the exact candidate setup, and checks relaunch and data preservation. It does not publish a release or use the private key in CI.

## v1.4.0 production signing record

The production public key ID is p256-0aff97759ea95258, and the public point matches the embedded production trust key in src/update_trust.hpp. The owner confirmed the encrypted private-key backup using the exact status: **“Owner confirms encrypted production-key backup. Independent backup restoration not performed.”** No independent restore was performed. The encrypted private key remained outside the checkout and was not copied to GitHub or CI.

The authentic manifest covers the v1.4.0 candidate built from source commit 491bd2ed29f84f4d434b884fc723144db2d6f294. Its issue time is 2026-11-20T22:22:40Z, expiry 2027-02-18T00:00:00Z, manifest SHA-256 e599ff055613366133ba8a03bae3f7acff9ac383d24214cc0c620a7efbe9a682, and raw 64-byte P1363 signature SHA-256 411372a2b5a1836968d60b6f1c3e3c7d21830df3c43d92728366653833f6b8c8. Public-PE verification, embedded-key verification, and clean-runner Windows CNG verification all passed.

The authoritative finalizer run is [44875679345](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44875679345). It retained candidate artifact [14695418078](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44875679345/artifacts/14695418078), clean-runner verification artifact [14696345027](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44875679345/artifacts/14696345027), and real production signed-transaction artifact [14695039897](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44875679345/artifacts/14695039897). The finalizer verified all seven asset identities, the embedded key, source provenance, private-material scan, and production signature. The actual isolated Windows transaction accepted the authentic manifest, rejected a disposable test-key signature, updated v1.3.0 to v1.4.0, preserved settings/history/unrelated data, relaunched, and advanced the timer (20 assertions). A second actual production-key portable update passed in [run 44880169391](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44880169391), artifact [14697029252](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44880169391/artifacts/14697029252), with 20 assertions: the exact portable digest replaced the v1.3.0 executable, settings/history were preserved, the timer advanced after relaunch, and no Installed Apps registration was created.

The final 110-cycle resource evidence is [run 44800093361](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44800093361), artifact [14671214276](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44800093361/artifacts/14671214276). Its application SHA-256 exactly matches the candidate EyeBreakReminder.exe: 07f6c1eaee5818df9f5c024310883ca94b8274a4f451186a8123974fb5e5f720.

After a test-only DNS warm-up timing defect was diagnosed from run 44877708026, the harness was changed to sample the full bounded 100-request window. The focused security workflow then passed in run [44878066198](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44878066198): 14 real DNS assertions, 25/25 SEC-028 paths, and 169 Windows updater assertions. Required CI passed in [run 44878066187](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44878066187), and focused resource regression passed in [run 44878062963](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44878062963). These changes did not alter product binaries or the signed candidate.

The retained candidate has seven files: application EXE, x64 setup, portable ZIP, source ZIP, SHA-256 list, manifest JSON and detached signature. Their exact hashes are recorded in V1.4.0_ACCEPTANCE_MATRIX.json. The EXE and setup are Authenticode NotSigned; the owner approved Authenticode as optional for v1.4.0 and SignPath is not a prerequisite. The initial installer remains a bootstrap trust boundary and must be obtained through a trusted manual process with clear unsigned-status disclosure. No merge or public release occurred.

## Recovery and rotation

No automatic key rotation is implemented. To recover the current identity, retrieve the encrypted PEM and its separately stored passphrase from the owner-controlled password manager, restore them only into a protected user-scoped directory outside the repository, OneDrive, and temp, then verify the derived key ID is still `p256-0aff97759ea95258`. Do not claim backup restoration was tested unless a restoration is actually performed.

If the signing key is lost or compromised, stop signing. Never accept a replacement key merely because it appears in a GitHub release. Recovery requires a trusted manual installer or another independently authenticated channel that carries a reviewed replacement public key. Existing clients with the old embedded key do not receive an unauthenticated automatic key rotation. A legitimate rollback likewise requires a separately verified manual installer; an older signed manifest is not a downgrade bypass.

## Initial bootstrap and Authenticode

The signed manifest cannot authenticate the application that first delivers its embedded public key. The initial v1.4.0 installation must be obtained through a trusted manual bootstrap and independently verified. The owner approved that bootstrap installer may remain Authenticode unsigned if the limitation is clearly disclosed.

Authenticode and update-manifest signing are separate controls. Authenticode can identify a publisher to Windows and may affect SmartScreen reputation; manifest signing authorizes future application updates. The approved v1.4.0 policy makes Authenticode optional and does not require SignPath approval.

### SignPath Foundation findings

SignPath Foundation currently offers its service free to qualifying open-source projects. Its published terms require an OSI-approved license for all components, no proprietary project code, active maintenance, a prior release in the form to be signed, and public download documentation. Certificate-specific conditions include signing only the project's own source-built binaries, MFA for repository and SignPath access, defined author/reviewer/approver roles, a public code-signing policy and privacy statement, verifiable build provenance, and manual approval of each release signing request. The certificate is issued to SignPath Foundation and its private key is held in its HSM. This would add Authenticode signing; it would not replace the independent signed-manifest mechanism. See [Foundation eligibility terms](https://signpath.org/terms) and [GitHub integration requirements](https://docs.signpath.io/trusted-build-systems/github).

This repository has no `LICENSE`, `LICENCE`, or `COPYING` file, and its README has no code-signing policy, so the published license and policy criteria are not currently established. The project is maintained and v1.3.0 is released, but v1.4.0 has not yet been released in the form proposed for signing. Eligibility therefore cannot be claimed without those changes and Foundation review. No application was submitted, no agreement accepted, no personal information supplied, and no certificate issued. Under the owner-approved policy, SignPath review is optional for v1.4.0. The [service description](https://signpath.org/) says the qualifying OSS service is free; the [project documentation](https://docs.signpath.io/projects) describes project and manual-approval configuration.

Other reviewed no-purchase options do not provide an immediate public Authenticode signature for the current NSIS/EXE/portable release set. Microsoft Store signing applies to Store-managed packages; Azure Artifact Signing and Certum options are paid; a self-signed certificate does not create public Windows publisher trust. See [Microsoft code-signing options](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/code-signing-options) and [Certum Open Source Code Signing](https://www.certum.eu/en/code-signing-certificates/).
