# Update signing and key management

**Current status (2026-11-20):** The existing owner-provisioned ECDSA P-256/SHA-256 key pair was verified locally; key ID `p256-0aff97759ea95258`. Its public key is embedded in `src/update_trust.hpp`; production builds trust only that root, while disposable test keys remain confined to `EYEBREAK_TEST_BUILD`. The owner confirms the encrypted private key is backed up in a password manager. Record accurately: “Encrypted production private-key backup confirmed by the owner. Independent backup restoration was not performed.” The private key is outside the repository and OneDrive at `%LOCALAPPDATA%\EyeBreakReminderSigning\production-private.pem`, protected by a current-user-only Windows ACL; never copy it into a build or artifact. Focused signing-tool tests passed 10/10 and the Windows security run passed at the prior public-key commit. The first key-embedded candidate attempt failed in test-harness setup: it used an invalid acceptance scenario and omitted a test-only signed manifest in the portable-recovery fixture. Those harness defects are being corrected before the authoritative candidate run. No production manifest has yet been signed and no authoritative production candidate exists. Authenticode is optional under the owner-approved v1.4.0 policy; SignPath approval is not required; the unsigned bootstrap limitation must be disclosed.

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

`src/update_trust.hpp` embeds the verified production public key with key ID `p256-0aff97759ea95258`. Production verification cannot be replaced through an environment variable, command line, test configuration, or release asset. Production code does not read a staging trust root. The current implementation and tests keep ephemeral test keys inside `EYEBREAK_TEST_BUILD` only.

The only staging-key path is compiled under `EYEBREAK_TEST_BUILD`. It supports disposable Windows integration fixtures. The regular application build cannot read or trust that key file. OpenSSL/CNG test keys are generated temporarily and must not be copied into `src/update_trust.hpp`, release artifacts, or production GitHub secrets.

## Current verification evidence

- The current pushed feature head passed required **Core tests and Windows package** in [run 44741647651](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44741647651) and the Windows CNG/DNS/SEC-028 job in [run 44741647472](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44741647472): 11 CNG assertions; 14 actual DNS-resolution-failure assertions; 10 GUI failure/retry assertions; SEC-028 25/25 rejection paths; 168 Windows updater assertions. The focused resource regression on unchanged product source passed in [run 44735583551](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44735583551).
- A focused resource regression passed in [run 44729380847](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44729380847), artifact [14625931728](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44729380847/artifacts/14625931728): eight disposable test-build cycles per GUI scenario and eight coordinator rejections, no resource violations. The final key-embedded candidate still requires its separate 110-cycle soak.
- Actual Windows CNG verification passed 11 assertions, including malformed, tampered and other-key signatures, in [run 44637417753](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44637417753).
- Signed GUI update passed 19 assertions; portable/install preserve and clean-install/history choices passed 40 assertions; refusal-to-exit, denied installer launch, and locked-file recovery passed 27 assertions with disposable test keys in [run 44637430056](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44637430056). That recorded integration run used disposable keys and did not test the production key; production trust is now provisioned, and a production-authenticated candidate transaction remains pending.
- SEC-028 passed for 25/25 rejection paths; FAIL-001 passed through an actual GUI DNS failure and successful normal GitHub retry in [run 44637417753](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44637417753). UN-009 remains NOT TESTED because the hosted runner does not provide the Installed Apps settings page.
- Required Core tests and Windows package passed on candidate source commit in [run 44637417786](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44637417786). Targeted updater resource loops passed in [run 44636046501](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44636046501).
- The later report-only feature head `778e450c1be4345475f54e8b09e76362d5095224` passed required Core/Windows package in [run 44640685765](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44640685765) and CNG/DNS/SEC-028 in [run 44640685783](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44640685783); the application source and candidate inputs did not change in that report commit.
- Current count: 217 PASS, 0 FAIL, 1 NOT TESTED, 11 BLOCKED, 2 NOT APPLICABLE. The five-file candidate is explicitly marked DEVELOPMENT CANDIDATE, has no production manifest signature, and is not publication-ready. Do not treat test-key artifacts as production candidates.

The signing-tool hardening rejects private-key paths under the repository, the checkout-detected or environment-configured OneDrive roots, and the system temp directory. Key generation requires a new dedicated directory on an existing volume, removes inherited ACEs, grants access only to the current Windows user SID, verifies that DACL, and verifies the generated private file inherited the same access. The encrypted PEM itself uses OpenSSL AES-256-CBC and its passphrase prompt; the passphrase is never accepted on the command line. Production key generation and signing require Windows so the tool can enforce and recheck the user-only ACL. Use a password-manager-generated random passphrase with at least 128 bits of entropy. The focused 10-test suite includes the OneDrive/temp/repository path rules and an actual ACL creation/readback test in a disposable directory.

## Production key provisioning and custody

The owner provisioned and verified the existing identity; do not generate, overwrite, or rotate it. The encrypted PEM and matching public PEM are stored outside the checkout at `%LOCALAPPDATA%\EyeBreakReminderSigning\production-private.pem` and `production-public.pem`. The private file is encrypted with OpenSSL AES-256-CBC, its passphrase is entered only in the local OpenSSL prompt, and Windows ACL inspection confirmed current-user-only access. The public key fingerprint maps to key ID `p256-0aff97759ea95258`; the production application embeds only the public half. The private key is never an input to a GitHub workflow.

Backup status is exactly: **“Encrypted production private-key backup confirmed by the owner. Independent backup restoration was not performed.”** The owner waived the recovery-check file and restoration test. Do not state that a restoration was independently verified. Recovery remains the owner's responsibility: retrieve the encrypted private key and separately stored passphrase from the password manager, restore it only to a protected user-scoped directory outside the repository, OneDrive, and temporary folders, verify the derived public key has the existing key ID, and use the local signing tool. Do not upload key material or passphrases to GitHub. If the working key and backup are lost, or compromise is suspected, stop signing; do not accept a replacement root from a release. A reviewed manual installer carrying a separately verified replacement public key is required for recovery/rotation.

Future local signing uses the documented `scripts/update_signing.py sign` procedure below. Invoke it from a visible local Windows console so OpenSSL's passphrase prompt is provided by the local process; never put the passphrase in chat, a command-line argument, environment variable, script, or log. The tool enforces protected-key paths, current-user ACLs, no-overwrite behavior, candidate identity and payload rehashing. Sign only the exact reviewed Eye Break Reminder release candidate after its source commit, workflow provenance, build tests and artifact identities have been verified.
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

The tool validates the canonical schema and payload names, hashes the exact EXE files, creates metadata, asks OpenSSL to sign the complete manifest bytes, converts the DER signature to the 64-byte P1363 format used by CNG, verifies the result against both the public PEM and the public key embedded in the source header, rehashes payloads before writing outputs, and writes the two public metadata files outside the candidate directory. Its path-collision and no-overwrite checks protect existing payload/key/metadata files. A push that changes only `src/update_trust.hpp` automatically starts the Windows acceptance workflow in `ProductionCandidateOnly` mode. It builds, installs and tests that exact production candidate and performs the single final resource soak. The finalizer requires the latest required CI result and successful candidate gate, checks that the later commit changes only the three public metadata-input files, validates all seven release assets and source archive, verifies the real signature with OpenSSL and Windows CNG against the embedded key, and retains a separate candidate artifact that a clean Windows job independently downloads and verifies. The offline signer is never part of CI and no workflow receives a private key.

After the candidate run passes, use its run ID and `SourceCommit` from `candidate-provenance.json`. Sign the manifest using the protected local key as shown above. Then copy only the public manifest and signature into the feature branch's release-input directory and add a small public provenance pointer. Commit all three files together. This push triggers the finalizer; it does not publish a release:

```powershell
$releaseInputs = Join-Path $PWD 'release-inputs/v1.4.0'
New-Item -ItemType Directory -Force -Path $releaseInputs | Out-Null
Copy-Item -LiteralPath (Join-Path $metadataDir 'EyeBreakReminder-UpdateManifest.json') -Destination $releaseInputs
Copy-Item -LiteralPath (Join-Path $metadataDir 'EyeBreakReminder-UpdateManifest.sig') -Destination $releaseInputs
@{candidate_run_id=[string]$candidateRunId;candidate_source_commit=[string]$candidateSourceCommit} |
  ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $releaseInputs 'candidate-provenance.json') -Encoding ascii
git add -- release-inputs/v1.4.0/candidate-provenance.json release-inputs/v1.4.0/EyeBreakReminder-UpdateManifest.json release-inputs/v1.4.0/EyeBreakReminder-UpdateManifest.sig
git commit -m 'chore: add signed v1.4.0 candidate metadata'
git push origin feature/v1.4.0-automatic-updater
```

The pointer contains no secret; it binds the finalizer to the successful candidate run and source commit. The workflow has read-only repository, Actions and check-run permissions. It verifies candidate identity and artifact retention, the exact source-to-metadata-only commit delta, the latest **Core tests and Windows package** result, embedded production key, OpenSSL signature, Windows CNG signature, and payload hashes. It records the required-check identity in the final candidate provenance and independently verifies a clean download with both crypto implementations. No private key or passphrase enters Git or GitHub. The candidate artifact is retained for review; no tag, release, merge, or publication is created.

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

The owner approved this v1.4.0 policy on 2026-11-20: signed update manifests and production signature verification are mandatory; Authenticode is optional; SignPath approval is not a release prerequisite; and the initial installer may remain unsigned with clear disclosure. This policy does not make unsigned bootstrap binaries Authenticode-trusted or remove SmartScreen warnings. The public production trust root is provisioned, but the authoritative candidate, signed production metadata and final hosted verification remain pending; v1.4.0 is not yet publication-ready.
