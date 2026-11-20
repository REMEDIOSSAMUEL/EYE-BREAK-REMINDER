# Update signing and key management

**Status (2026-11-20):** ECDSA P-256/SHA-256 manifest verification and signing tooling are implemented. The signing tool rejects production private-key paths in the checkout, OneDrive roots, and temp directories, and verifies a new dedicated key directory's Windows DACL is limited to the current user. The current focused signing and candidate-finalizer suite passes 10/10 on this Windows host, including actual disposable ACL inspection and embedded-key manifest verification. Feature head `59194c229c08c2678b6d8579a542488cedf920fa` passed required CI and the Windows CNG/DNS/SEC-028 suite in runs 44730606999 and 44730606703. No existing Eye Break Reminder CNG production key or matching current-user publisher certificate was found. The owner approved manually backing up the encrypted PEM in a user-controlled secure file vault with the passphrase kept separate. No production key has been generated yet; the owner must enter the passphrase at the local prompt and confirm the backup is recoverable before the public key is embedded. The retained candidate is development-only and has no production manifest signature. Authenticode is optional for v1.4.0 under the owner's revised policy; the initial installer may remain unsigned if this is clearly disclosed.

## What the signature protects

GitHub HTTPS protects the connection to GitHub and the GitHub-provided SHA-256 digest detects payload corruption relative to metadata returned by that service. If the repository, release account, or publication metadata is compromised, those values can be changed together. They do not independently show that the release was authorized by the Eye Break Reminder maintainer.

The updater now requires a detached signature made with the publisher's P-256 private key. Windows CNG (`BCrypt*`) verifies ECDSA P-256 over SHA-256 using the public key embedded in the application. This uses the Windows platform cryptographic provider; the application contains no private key or third-party crypto implementation. The GitHub digest, when supplied, is an additional consistency check. It cannot override a publisher-signature failure.

This is update-channel authentication only. It does **not** Authenticode-sign the EXE or installer, establish a Windows publisher name, or guarantee removal of SmartScreen warnings. These remain separate release controls.

## Exact signed format

Each stable x64 release contains:

- `EyeBreakReminder-UpdateManifest.json`
- `EyeBreakReminder-UpdateManifest.sig`

The manifest is the exact ASCII byte sequence serialized as compact JSON with no BOM, whitespace, escapes, or trailing newline. Property order and asset order are fixed by schema version 1. Duplicate, unknown, missing, reordered, or noncanonical properties are rejected. The signature file is exactly 64 raw IEEE P1363 bytes (`r` then `s`, 32-byte big-endian integers each), not PEM or DER.

The schema signs the schema version, application identity, repository identity, stable version, `stable` channel, `x64` architecture, signing key ID, UTC issue/expiry timestamps, and exactly two role-bound payload entries. Those entries are the installed setup executable and standalone portable-update executable. Each binds its exact filename, role, installation type, architecture, size, and lowercase SHA-256. A payload cannot be switched between installer and portable use.

Metadata is valid for at most 90 days, permits at most five minutes of clock skew into the future, and must match the discovered GitHub tag and be newer than the installed version. There is no unsigned fallback. The updater authenticates metadata before offering/downloading, verifies payload size and hash after download, and rechecks the signature and payload binding at the coordinator's execution boundary. Missing, expired, malformed, modified, unknown-key, wrong-repository, wrong-version, wrong-channel, wrong-architecture, wrong-role, or mismatched payload data is rejected before installation begins.

## Production and test trust roots

`src/update_trust.hpp` currently has `ProductionUpdateKeyProvisioned=false` and no production point. That is intentional fail-closed behavior. A production updater never reads its trust key from a release, environment variable, command line, or staging directory.

The only staging-key path is compiled under `EYEBREAK_TEST_BUILD`. It supports disposable Windows integration fixtures. The regular application build cannot read or trust that key file. OpenSSL/CNG test keys are generated temporarily and must not be copied into `src/update_trust.hpp`, release artifacts, or production GitHub secrets.

## Current verification evidence

- The current pushed feature head passed required **Core tests and Windows package** in [run 44730606999](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44730606999) and the Windows CNG/DNS/SEC-028 job in [run 44730606703](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44730606703): 11 CNG assertions; 14 actual DNS-resolution-failure assertions; 10 GUI failure/retry assertions; SEC-028 25/25 rejection paths; 168 Windows updater assertions.
- A focused resource regression passed in [run 44729380847](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44729380847), artifact [14625931728](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44729380847/artifacts/14625931728): eight disposable test-build cycles per GUI scenario and eight coordinator rejections, no resource violations. The final key-embedded candidate still requires its separate 110-cycle soak.
- Actual Windows CNG verification passed 11 assertions, including malformed, tampered and other-key signatures, in [run 44637417753](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44637417753).
- Signed GUI update passed 19 assertions; portable/install preserve and clean-install/history choices passed 40 assertions; refusal-to-exit, denied installer launch, and locked-file recovery passed 27 assertions with disposable test keys in [run 44637430056](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44637430056). No production-key transaction was possible because the production key is not provisioned.
- SEC-028 passed for 25/25 rejection paths; FAIL-001 passed through an actual GUI DNS failure and successful normal GitHub retry in [run 44637417753](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44637417753). UN-009 remains NOT TESTED because the hosted runner does not provide the Installed Apps settings page.
- Required Core tests and Windows package passed on candidate source commit in [run 44637417786](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44637417786). Targeted updater resource loops passed in [run 44636046501](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44636046501).
- The later report-only feature head `778e450c1be4345475f54e8b09e76362d5095224` passed required Core/Windows package in [run 44640685765](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44640685765) and CNG/DNS/SEC-028 in [run 44640685783](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44640685783); the application source and candidate inputs did not change in that report commit.
- Current count: 217 PASS, 0 FAIL, 1 NOT TESTED, 11 BLOCKED, 2 NOT APPLICABLE. The five-file candidate is explicitly marked DEVELOPMENT CANDIDATE, has no production manifest signature, and is not publication-ready. Do not treat test-key artifacts as production candidates.

The signing-tool hardening rejects private-key paths under the repository, the checkout-detected or environment-configured OneDrive roots, and the system temp directory. Key generation requires a new dedicated directory on an existing volume, removes inherited ACEs, grants access only to the current Windows user SID, verifies that DACL, and verifies the generated private file inherited the same access. The encrypted PEM itself uses OpenSSL AES-256-CBC and its passphrase prompt; the passphrase is never accepted on the command line. Production key generation and signing require Windows so the tool can enforce and recheck the user-only ACL. Use a password-manager-generated random passphrase with at least 128 bits of entropy. The current seven-test suite includes the OneDrive/temp/repository path rules and an actual ACL creation/readback test in a disposable directory.

## Provision a production key

Use a protected Windows signing account and a key directory outside the checkout, OneDrive, and temp. A removable NTFS drive is preferred; the owner also approved a password-manager secure file attachment as an independently recoverable backup for the AES-256-encrypted PEM, with the passphrase stored separately. The assistant will not upload this material. The owner must run key generation locally, enter a password-manager-generated random passphrase with at least 128 bits of entropy, manually save the encrypted PEM to the approved vault, and confirm the backup is recoverable. The key-directory path supplied below must not already exist; its parent volume root must already be mounted. The generator creates the dedicated directory, removes inherited access rules, grants only the current Windows user SID, and verifies the directory and private-key file ACLs. It rejects paths in the checkout, a detected OneDrive root, or the system temp directory. The key uses OpenSSL AES-256-CBC and an interactive passphrase prompt. The script never prints the private key and never accepts its passphrase in an argument. It refuses to overwrite existing key files, refuses identical private/public paths, and signing refuses output paths that collide with keys or payloads or already contain metadata.

```powershell
$ebrKeyDir = Join-Path $env:LOCALAPPDATA 'EyeBreakReminderSigning'
python scripts/update_signing.py generate `
  --private-key (Join-Path $ebrKeyDir 'production-private.pem') `
  --public-key (Join-Path $ebrKeyDir 'production-public.pem')

```

After generation, manually attach only `production-private.pem` to the approved secure vault entry; keep the random passphrase in a separate vault item. Do not send either item to this session. To verify the stored attachment is recoverable, download it back to the protected `%LOCALAPPDATA%\EyeBreakReminderSigning` directory as `recovery-check.pem`, compare its SHA-256 with the original encrypted PEM, and derive a public key interactively without exposing the passphrase:

```powershell
$recovered = Join-Path $ebrKeyDir 'recovery-check.pem'
$derivedPublic = Join-Path $ebrKeyDir 'recovery-check-public.pem'
Remove-Item -LiteralPath $derivedPublic -Force -ErrorAction SilentlyContinue
if ((Get-FileHash $recovered -Algorithm SHA256).Hash -ne (Get-FileHash (Join-Path $ebrKeyDir 'production-private.pem') -Algorithm SHA256).Hash) { throw 'The recovered encrypted backup differs from the original.' }
openssl pkey -in $recovered -pubout -out $derivedPublic
if ($LASTEXITCODE -ne 0) { throw 'OpenSSL could not decrypt the recovered key and derive its public key.' }
if ((Get-FileHash $derivedPublic -Algorithm SHA256).Hash -ne (Get-FileHash (Join-Path $ebrKeyDir 'production-public.pem') -Algorithm SHA256).Hash) { throw 'The recovered key does not match the provisioned public key.' }
Remove-Item -LiteralPath $recovered, $derivedPublic

# After the recovered public key matches, embed only the public key in source.
python scripts/update_signing.py embed-public `
  --public-key (Join-Path $ebrKeyDir 'production-public.pem')
```

Run this only after the vault attachment can be downloaded successfully. It checks both byte-for-byte recovery and that the encrypted key decrypts to the matching public key. The removal command targets only the two named temporary verification files inside the dedicated protected key directory.

Review the generated key ID and public-key diff, then commit only `src/update_trust.hpp`. Never put the private PEM in Git, OneDrive, an installer, a ZIP, a workflow artifact, a screenshot, or a log. In this session, no matching publisher certificate existed; the current environment exposed no removable volume, and volume/BitLocker metadata could not be queried without host administrator access. The owner approved the secure-vault backup route but must still run the command locally, enter the passphrase, manually save the encrypted PEM attachment with the passphrase separate, and confirm that the backup is recoverable. Until that confirmation, no production key has been generated or embedded, so production updates remain fail-closed. No identity or passphrase was invented.

## Sign and verify a release

Build and test final payloads first. If Authenticode signing is available, sign and verify the EXE and installer before building the portable ZIP and before hashing. Do not alter any payload after signing its manifest digest.

```powershell
$ebrKeyDir = Join-Path $env:LOCALAPPDATA 'EyeBreakReminderSigning'
$candidateRunId = '00000000000' # Replace with the successful ProductionCandidateOnly Windows run.
$run = gh api "repos/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/$candidateRunId" | ConvertFrom-Json
if ($run.name -cne 'Windows v1.4.0 updater and release-candidate acceptance' -or $run.status -cne 'completed' -or $run.conclusion -cne 'success' -or $run.head_branch -cne 'feature/v1.4.0-automatic-updater') { throw 'Candidate run is not the successful feature-branch acceptance run.' }
$candidateSourceCommit = $run.head_sha
$candidateRoot = Join-Path $env:TEMP "EyeBreakReminder-v1.4.0-candidate-$candidateRunId"
gh run download $candidateRunId --repo REMEDIOSSAMUEL/EYE-BREAK-REMINDER `
  --name "eye-break-reminder-v1.4.0-candidate-$candidateRunId" `
  --dir $candidateRoot
if ($LASTEXITCODE -ne 0) { throw 'Could not download the retained Windows acceptance candidate.' }
$release = Join-Path $candidateRoot 'release'
if ($run.status -cne 'completed' -or $run.conclusion -cne 'success' -or $run.head_branch -cne 'feature/v1.4.0-automatic-updater' -or $run.head_sha -cne $candidateSourceCommit) { throw 'Candidate run is not a successful exact-commit feature-branch run.' }
$provenance = Get-Content (Join-Path $candidateRoot 'build/v1.4.0-updater-evidence/candidate-provenance.json') -Raw | ConvertFrom-Json
$gate = Get-Content (Join-Path $candidateRoot 'build/v1.4.0-updater-evidence/windows-acceptance-gate.json') -Raw | ConvertFrom-Json
if ($provenance.Application -cne 'Eye Break Reminder' -or $provenance.Version -cne '1.4.0' -or $provenance.RunId -ne $candidateRunId -or $provenance.SourceCommit -cne $candidateSourceCommit -or $provenance.Branch -cne 'feature/v1.4.0-automatic-updater' -or $gate.Status -cne 'PASS' -or $gate.Scope -cne 'ProductionCandidateOnly') { throw 'Candidate provenance or production-candidate acceptance gate is not valid.' }
$identities = @(Get-Content (Join-Path $candidateRoot 'build/v1.4.0-updater-evidence/release-artifact-identities.json') -Raw | ConvertFrom-Json)
if ($identities.Count -ne 5 -or @(Get-ChildItem -LiteralPath $release -File).Count -ne 5 -or @(Get-ChildItem -LiteralPath $release -Directory).Count -ne 0) { throw 'Candidate identity record/release directory does not contain exactly five release files.' }
foreach ($item in $identities) {
  $file = Get-Item (Join-Path $release $item.Name)
  if ($file.Length -ne [long]$item.Bytes -or (Get-FileHash $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -cne $item.SHA256) { throw "Candidate bytes differ from the verified acceptance identity: $($item.Name)" }
}
$metadataDir = Join-Path $ebrKeyDir "v1.4.0-signed-metadata-$candidateRunId"
$expiresAt = (Get-Date).ToUniversalTime().AddDays(60).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")

python scripts/update_signing.py sign `
  --private-key (Join-Path $ebrKeyDir 'production-private.pem') `
  --public-key (Join-Path $ebrKeyDir 'production-public.pem') `
  --version 1.4.0 `
  --expires-at $expiresAt `
  --installer (Join-Path $release 'EyeBreakReminder-Setup-x64.exe') `
  --portable (Join-Path $release 'EyeBreakReminder.exe') `
  --manifest (Join-Path $metadataDir 'EyeBreakReminder-UpdateManifest.json') `
  --signature (Join-Path $metadataDir 'EyeBreakReminder-UpdateManifest.sig')

python scripts/update_signing.py verify `
  --public-key (Join-Path $ebrKeyDir 'production-public.pem') `
  --manifest (Join-Path $metadataDir 'EyeBreakReminder-UpdateManifest.json') `
  --signature (Join-Path $metadataDir 'EyeBreakReminder-UpdateManifest.sig')

python scripts/update_signing.py verify-embedded `
  --manifest (Join-Path $metadataDir 'EyeBreakReminder-UpdateManifest.json') `
  --signature (Join-Path $metadataDir 'EyeBreakReminder-UpdateManifest.sig')
```

The tool validates the canonical schema and payload names, hashes the exact EXE files, creates metadata, asks OpenSSL to sign the complete manifest bytes, converts the DER signature to the 64-byte P1363 format used by CNG, verifies the result against both the public PEM and the public key embedded in the source header, rehashes payloads before writing outputs, and writes the two public metadata files outside the candidate directory. Its path-collision and no-overwrite checks protect existing payload/key/metadata files. The finalizer workflow requires the latest required CI result and successful exact-commit Windows candidate gate, validates all seven files and scans the source archive, verifies the authentic signature with OpenSSL and a Windows CNG executable against the embedded key, then retains a separate signed candidate artifact and independently downloads and verifies it with both verifiers. Run `windows-v1.4.0-updater-acceptance.yml` with `ProductionCandidateOnly` after the required PR check passes; this installs and tests the exact production candidate and performs the final resource soak once without using the obsolete unsigned production-feed test path. The offline signer is never part of pull-request CI and no workflow receives a private key.

After signing, use PowerShell to dispatch finalization with the public metadata only. Replace the run ID and commit with those of the successful `ProductionCandidateOnly` candidate build. The base64 values contain only the public manifest and public signature:

```powershell
$candidateRunId = '00000000000'
$candidateCommit = $candidateSourceCommit
$manifestBase64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $metadataDir 'EyeBreakReminder-UpdateManifest.json')))
$signatureBase64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $metadataDir 'EyeBreakReminder-UpdateManifest.sig')))
gh workflow run windows-v1.4.0-finalize-production-candidate.yml `
  --repo REMEDIOSSAMUEL/EYE-BREAK-REMINDER `
  --ref feature/v1.4.0-automatic-updater `
  -f "candidate_run_id=$candidateRunId" `
  -f "candidate_source_commit=$candidateCommit" `
  -f "manifest_base64=$manifestBase64" `
  -f "signature_base64=$signatureBase64"
```

The finalization workflow has read-only repository, Actions and check-run permissions. It requires the latest **Core tests and Windows package** check to have succeeded on the exact candidate commit; it then checks the candidate run status, exact branch and commit, artifact expiry, version, embedded production key, OpenSSL signature, Windows CNG signature, and all payload hashes. It records the successful required-check run identity in the candidate provenance and independently verifies the downloaded candidate with both crypto implementations. It does not publish a release, create a tag, merge the PR, or receive any private signing material.

## Bootstrap, rollback, and recovery

An embedded key cannot authenticate the application that first brings it to the user. The initial v1.4.0 installation therefore needs a trusted manual bootstrap: obtain the application through a maintainer-controlled channel and independently verify its source/build identity and checksum, or use a trusted Authenticode signer if one is available. A signed update manifest does not repair a compromised unsigned bootstrap download.

No automatic key rotation is implemented. If the working key directory is lost but its offline encrypted backup is intact, restore the private PEM to a new user-only ACL directory on the authorized Windows signing account, retrieve the passphrase from the password manager, and verify that its derived public key has the already embedded key ID before signing. Never copy the passphrase alongside the backup. If both the working key and backup are lost, or the key may be compromised, stop signing; existing clients need an owner-verified manual installer containing a reviewed replacement public key. Never trust a replacement key merely because GitHub serves it. The update path will not install a downgrade. A legitimate rollback requires a separately verified manual installer and user-data recovery procedure; an old signed manifest is not a downgrade bypass.

For an invalid signature or payload, keep the current application installed and operational, preserve settings and history, report the verification failure, retain diagnostics, and clean or safely quarantine staging data. Do not provide an ordinary-user signature bypass.

## Authenticode option: SignPath Foundation

SignPath Foundation currently advertises free open-source code signing. Its public certificate is issued to SignPath Foundation, with the signing private key held in its HSM; this would give Windows an Authenticode publisher identity but would not make this project's update manifest signed. Its current eligibility terms require an OSI-approved license for all components, active maintenance, an existing release in the form to be signed, public download-page documentation, project/source ownership, source-built binaries with verifiable origin, MFA for repository and SignPath access, and defined author/reviewer/approver roles. Its terms say each release requires manual signing approval. A code-signing policy with specified roles and privacy wording is also required on the project home/download pages. The Foundation can accept or reject applications; eligibility is not automatic. [SignPath Foundation terms](https://signpath.org/terms), [free service description](https://signpath.org/), [SignPath project and approval documentation](https://docs.signpath.io/projects).

The current checkout has no `LICENSE`/`COPYING` file, so the required open-source-license condition is not presently established. The project has a public GitHub repository and existing releases, but application remains subject to licensing all components, documentation/policy updates, verified GitHub build integration and Foundation review. The service says no personal identification is needed; no application was submitted, no agreement accepted, and no personal information supplied. No certificate has been issued. It is a free external application route, not an immediate credential and not a reason to delay manifest work.

If the owner elects to apply: choose and add an OSI-approved project license after considering its legal effect; publish a code-signing policy and identify author/reviewer/approver roles; enable MFA; apply from the official SignPath Foundation page with the repository and download-page links; configure GitHub Actions as a trusted build system with origin verification restricted to reviewed release branches/tags; require a human approval for every release signing request; and verify the returned Authenticode signatures before final hashes and manifest signing. Do not expose SignPath credentials to pull-request code. Alternatively, use an already authorized certificate from a trusted issuer if one exists; no such certificate is currently available and none should be purchased for this task.

## Other no-purchase options reviewed

Microsoft documents free store-managed signing for MSIX packages distributed through the Microsoft Store. That option would require adopting MSIX and Store distribution; it does not sign this project's current NSIS installer, standalone executable, or portable ZIP. The Store's MSI/EXE submission path still requires the publisher to sign those files. This is a separate distribution decision, not an available Authenticode credential for the current release files. [Microsoft code-signing options](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/code-signing-options).

Microsoft's Azure Artifact Signing is paid (the current Microsoft comparison lists about US$9.99/month) and therefore is outside this no-purchase task. Certum's official Open Source Code Signing listing currently starts at €25, so it is also not free. A self-signed certificate is free for development or managed enterprise trust, but Microsoft documents that it blocks installation for public users; it does not establish public Windows publisher trust. No existing authorized certificate or account was found or used. [Certum Open Source Code Signing](https://www.certum.eu/en/code-signing-certificates/), [Microsoft code-signing options](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/code-signing-options).

## Release policy decision

The owner approved this v1.4.0 policy on 2026-11-20: signed update manifests and production signature verification are mandatory; Authenticode is optional; SignPath approval is not a release prerequisite; and the initial installer may remain unsigned with clear disclosure. This policy does not make unsigned bootstrap binaries Authenticode-trusted or remove SmartScreen warnings. The production manifest trust root and signed production metadata are still absent, so v1.4.0 is not yet publication-ready.
