# Update signing and key management

## Published production baseline

The published v1.4.0 release uses candidate `15041400454`, built from `dfd8018b319bdfde498d4f23b2d1ca96d0a99145`. Its stable x64 manifest was issued **25 November 2026 at 16:04:11 UTC** and expires **24 January 2027 at 16:04:10 UTC**. Use the published verification record for the authoritative asset hashes and provenance. The earlier signing records below preserve the identity and evidence of superseded candidates. [Published release verification](V1.4.0_PUBLISHED_RELEASE_VERIFICATION.md)

## Superseded v1.4.0 candidate 15007651099 — 2026-11-25

Candidate run [45575765880](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/45575765880) built the replacement from source commit `0f49949a9e753fcca390c25affc99d7698b1ecde`, after the recovery cleanup-handoff defect was corrected. The owner completed the existing protected local signing procedure; the passphrase was entered only at the visible local OpenSSL prompt and was not sent in chat. Key `p256-0aff97759ea95258` signed the v1.4.0 manifest using ECDSA P-256/SHA-256 and a raw 64-byte P1363 signature. Manifest SHA-256: `88ec256d6c4bb8f0c52946b947cf8778e0966f8cfe84c9f83c551f9a61af84a6`. Signature SHA-256: `c0906144d52623a4d428df0d69208a849102df731877bbcdb9d366d1f4031992`.

Finalizer [45582714164](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/45582714164) completed successfully with three jobs, 36 steps, and zero skipped steps. Authoritative final seven-file artifact: [15007651099](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/45582714164/artifacts/15007651099). Independent clean-download verification artifact: [15007920934](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/45582714164/artifacts/15007920934). Production signed update transaction artifact: [15007776608](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/45582714164/artifacts/15007776608), 21 passing assertions. Windows CNG and the embedded production trust key verified the manifest; the test-key signature was rejected. The transaction updated an isolated v1.3.0 installation, preserved settings/history/unrelated files, relaunched the app, and advanced its timer. Authenticode remains unsigned under the approved policy.

| Candidate file | Bytes | SHA-256 |
|---|---:|---|
| `EyeBreakReminder.exe` | 2,901,504 | `3dd3fa4c8e9f6200780c7bf0c2340435c7b127ce6b6202b24857105f01f3719a` |
| `EyeBreakReminder-Setup-x64.exe` | 1,401,842 | `7df5c6f61cbb56d813e4eee989637e6fcf692d1879f1446d4776da5928e49c2a` |
| `EyeBreakReminder-Portable-x64.zip` | 1,579,253 | `9337550cf5a2fc2b685672205654d8c674fb8440b01a0ce97c8762bd065f6341` |
| `EyeBreakReminder-Source.zip` | 2,971,803 | `c8971b3d32b8aad2bf634e40cf753f33b2430f7167effd93063c578e0e05480c` |
| `EyeBreakReminder-SHA256.txt` | 382 | `ae6032f9810e7362a27a0b0b15405537aab4ff2fb7ce6efc3c4e97b42e7796df` |
| `EyeBreakReminder-UpdateManifest.json` | 682 | `88ec256d6c4bb8f0c52946b947cf8778e0966f8cfe84c9f83c551f9a61af84a6` |
| `EyeBreakReminder-UpdateManifest.sig` | 64 | `c0906144d52623a4d428df0d69208a849102df731877bbcdb9d366d1f4031992` |

The finalization metadata was committed at `61a9d4732ae757f9e2cd0c2fd408140fe69db163`; it is distinct from the candidate source commit above. Earlier candidate artifact `14695418078` remains historical and preserved. Do not replace the current candidate without a genuine defect. The new candidate retained the matching 110-cycle soak from run `45499840097`, artifact `14979951493`; no new soak or rebuild followed signing. This record does not imply that FAIL-024 or ENV-005 passed: the later repeat recovery workflow used the historical installed baseline and did not reboot or observe automatic sign-in dispatch.

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

Use a successful `ProductionCandidateOnly` Windows acceptance run on the feature branch. Verify its branch, full source commit, gate, exact five-file candidate identities, and retained artifact before signing. The following PowerShell is the v1.4.0 example. For future releases, substitute the intended version, branch, run ID and actual artifact/evidence paths. [Future release checklist](V1.4.0_PUBLICATION_PLAN.md#future-release-checklist)

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

## Superseded v1.4.0 candidate 14695418078

The production public key ID is p256-0aff97759ea95258, and the public point matches the embedded production trust key in src/update_trust.hpp. The owner confirmed the encrypted private-key backup using the exact status: **“Owner confirms encrypted production-key backup. Independent backup restoration not performed.”** No independent restore was performed. The encrypted private key remained outside the checkout and was not copied to GitHub or CI.

The authentic manifest covers the v1.4.0 candidate built from source commit 491bd2ed29f84f4d434b884fc723144db2d6f294. Its issue time is 2026-11-20T22:22:40Z, expiry 2027-02-18T00:00:00Z, manifest SHA-256 e599ff055613366133ba8a03bae3f7acff9ac383d24214cc0c620a7efbe9a682, and raw 64-byte P1363 signature SHA-256 411372a2b5a1836968d60b6f1c3e3c7d21830df3c43d92728366653833f6b8c8. Public-PE verification, embedded-key verification, and clean-runner Windows CNG verification all passed.

The authoritative finalizer run is [44875679345](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44875679345). It retained candidate artifact [14695418078](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44875679345/artifacts/14695418078), clean-runner verification artifact [14696345027](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44875679345/artifacts/14696345027), and real production signed-transaction artifact [14695039897](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44875679345/artifacts/14695039897). The finalizer verified all seven asset identities, the embedded key, source provenance, private-material scan, and production signature. The actual isolated Windows transaction accepted the authentic manifest, rejected a disposable test-key signature, updated v1.3.0 to v1.4.0, preserved settings/history/unrelated data, relaunched, and advanced the timer (20 assertions). A second actual production-key portable update passed in [run 44880169391](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44880169391), artifact [14697029252](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44880169391/artifacts/14697029252), with 20 assertions: the exact portable digest replaced the v1.3.0 executable, settings/history were preserved, the timer advanced after relaunch, and no Installed Apps registration was created.

The final 110-cycle resource evidence is [run 44800093361](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44800093361), artifact [14671214276](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44800093361/artifacts/14671214276). Its application SHA-256 exactly matches the candidate EyeBreakReminder.exe: 07f6c1eaee5818df9f5c024310883ca94b8274a4f451186a8123974fb5e5f720.

After a test-only DNS warm-up timing defect was diagnosed from run 44877708026, the harness was changed to sample the full bounded 100-request window. The focused security workflow then passed in run [44878066198](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44878066198): 14 real DNS assertions, 25/25 SEC-028 paths, and 169 Windows updater assertions. Required CI passed in [run 44878066187](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44878066187), and focused resource regression passed in [run 44878062963](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44878062963). These changes did not alter product binaries or the signed candidate.

The retained candidate has seven files: application EXE, x64 setup, portable ZIP, source ZIP, SHA-256 list, manifest JSON and detached signature. Their exact hashes are recorded in V1.4.0_ACCEPTANCE_MATRIX.json. The EXE and setup are Authenticode NotSigned; the owner approved Authenticode as optional for v1.4.0 and SignPath is not a prerequisite. The initial installer remains a bootstrap trust boundary and must be obtained through a trusted manual process with clear unsigned-status disclosure. No merge or public release occurred.

## How manifest expiry affects users

| Scenario | Effect of expiry |
|---|---|
| Older authenticated updater discovers a newer stable release | It fetches and authenticates that release's manifest and signature before offering installation. An expired manifest makes the check fail. This applies to installed and portable clients with the authenticated updater. v1.3.0 is a discovery-only client that directs users to the release for manual installation. |
| v1.4.0 checks while v1.4.0 is latest | Release discovery compares the versions and reports up to date without fetching the manifest. Future offers use the successor's manifest, independently of v1.4.0's expiry. |
| An update is already staged | The coordinator checks freshness again immediately before launching setup or replacing the portable executable. Expiry at or before that check stops installation. |
| Manual installation or ordinary application use | Users can independently verify and manually install the known-good setup or portable package. Installed applications continue to run. The standalone v1.4.0 installer remains Authenticode unsigned. |
| Rollback of an interrupted transaction | Local recovery can authenticate the saved pair after it expires. Signature, transaction ownership, backups and applicable data-safety checks still apply. Recovery restores the prior installation and never uses that exception to run a successor installer or offer a network downgrade. |

Installation requires `expires_at > now`, a validity window of at most 90 days, and an issue time no more than five minutes ahead of the client's clock. The rollback path skips only the expiry cutoff. [Release discovery and offer](../src/app.cpp) · [Time policy](../src/update_manifest.hpp) · [Installation and recovery](../src/update_coordinator.hpp)

Renew an unpublished candidate if its remaining validity cannot cover the intended publication and independent verification window. For published releases, keep the original assets and use a separately approved newer signed release when compatible older clients need a fresh in-app offer. Expiry alone calls for no v1.4.0 renewal. Verify a published offer before considering any exceptional replacement of its metadata. [Renewal procedure](V1.4.0_PUBLICATION_PLAN.md#signed-manifest-expiry-and-renewal)

## Signing and publication incidents

| Incident | Maintainer action and effect on existing installations |
|---|---|
| Lost or corrupted encrypted PEM | Pause signing. With owner approval, recover the encrypted PEM and separately backed-up passphrase into a private, user-scoped location outside the checkout, OneDrive and temp. Use the local OpenSSL prompt to derive the public key and verify its full point and ID match the embedded production key. If recoverable and uncompromised, the same identity can sign future updates. |
| Forgotten passphrase | Ask the owner to check its protected backup. There is no passphrase bypass. If the key cannot be recovered and remains uncompromised, installations can still accept already-signed eligible releases while valid. Future updates under a different key require a trusted manual bootstrap. |
| Suspected private-key compromise | Suspend signing and publication. Preserve evidence privately, secure GitHub and maintainer access as applicable, and give users independently authenticated instructions to avoid the affected update channel. Treat the old key as untrustworthy even when its signatures verify. Existing clients have no automatic key rotation or revocation mechanism. After review, use a trusted manual installer that embeds a new key delivered via an independently authenticated channel. Clients can resume authenticated updates after installing that trusted build. |
| Failed production signature verification | Hold the draft and preserve the evidence. Independently fetch the expected pair, compare hashes, verify canonical bytes and key identity, and check the verifier's clock and version inputs if the failure is a policy rejection. If already public, inform the owner, investigate possible tampering or mixed assets and authorize any containment separately. Keep signature enforcement in place. |
| Incorrect signed payload hash or size | Stop installation and publication. Compare the download and frozen candidate against signed sizes and hashes. A valid signature does not authenticate different payload bytes. Recover the original verified bytes while still in draft. If the frozen payload itself is wrong, freeze and independently verify a corrected candidate, then obtain separate signing approval. For a published mismatch, preserve evidence and prefer a separately approved corrected successor. |
| Expired update manifest | Verify the UTC clock, exact pair and discovery target. Keep ordinary use and manual installation available. For an unpublished candidate, follow the metadata-only renewal procedure. For a published offer, prefer a newer authorized signed release when an in-app path is needed. |
| Interrupted publication | Reconcile the exact tag target, release ID, draft/stable flags, and asset names, sizes and hashes before retrying. If still in draft, complete and verify the whole asset set before publishing. If public, capture what clients actually receive and notify the owner. Resume verification if the release is complete and correct. If assets differ or are missing, treat the offer as unavailable until an approved repair or corrected successor passes public verification. |

Restoration of the original uncompromised key keeps existing clients on the authenticated path. Permanent loss or suspected compromise requires a trusted manual transition to a new identity for clients pinned to the old key. A deliberate downgrade outside an interrupted transaction also requires a separately verified manual installer. Production clients only authorize newer stable versions.

## Maintenance checks and approvals

| When | Review |
|---|---|
| **10 January 2027** | Check the live v1.4.0 pair against the production key and recorded hashes. Confirm expiry, the latest stable tag and the manual installation route. Decide whether older compatible clients still need a fresh in-app offer. |
| Before each signing or release, and when reviewing a still-active offer near expiry | Verify private key availability by metadata, the public key identity and owner-confirmed access to the encrypted backup and separately stored passphrase. Check current UTC and the intended publication window. On each new release, record the expiry and next review date. |
| During release closeout and before relevant Actions artifacts expire | Verify that unique signing, recovery, candidate and publication evidence has a durable verified copy. Record artifact retention dates and keep sensitive evidence private. |
| Before each protected merge or publication | Review required checks and main branch protections. Resolve review requirements through the normal protected process and preserve prior releases and tags. |
| When triaging reports or when suitable isolated environments become available | Review user-reported defects, run targeted regressions, and revisit deferred acceptance cases as the environment permits. Keep classifications aligned with actual evidence. |

Obtain explicit owner approval before production signing, backup restoration, generating or changing production trust, publishing or changing public assets or tags, or creating recurring workflows or automated signing jobs. The dates above are manual review points.

## Initial bootstrap and Authenticode

The signed manifest cannot authenticate the application that first delivers its embedded public key. The initial v1.4.0 installation must be obtained through a trusted manual bootstrap and independently verified. The owner approved that bootstrap installer may remain Authenticode unsigned if the limitation is clearly disclosed.

Authenticode and update-manifest signing are separate controls. Authenticode can identify a publisher to Windows and may affect SmartScreen reputation; manifest signing authorizes future application updates. The approved v1.4.0 policy makes Authenticode optional and does not require SignPath approval.

### Historical SignPath Foundation assessment

SignPath Foundation currently offers its service free to qualifying open-source projects. Its published terms require an OSI-approved license for all components, no proprietary project code, active maintenance, a prior release in the form to be signed, and public download documentation. Certificate-specific conditions include signing only the project's own source-built binaries, MFA for repository and SignPath access, defined author/reviewer/approver roles, a public code-signing policy and privacy statement, verifiable build provenance, and manual approval of each release signing request. The certificate is issued to SignPath Foundation and its private key is held in its HSM. This would add Authenticode signing; it would not replace the independent signed-manifest mechanism. See [Foundation eligibility terms](https://signpath.org/terms) and [GitHub integration requirements](https://docs.signpath.io/trusted-build-systems/github).

At the time of this assessment, the repository lacked a license file and a README code-signing policy. v1.4.0 has since been published. Any future application would need a fresh assessment against the Foundation's requirements. The project has no recorded application or issued certificate. SignPath review was optional for v1.4.0. [Service description](https://signpath.org/) · [Project configuration](https://docs.signpath.io/projects)

Other reviewed no-purchase options do not provide an immediate public Authenticode signature for the current NSIS/EXE/portable release set. Microsoft Store signing applies to Store-managed packages; Azure Artifact Signing and Certum options are paid; a self-signed certificate does not create public Windows publisher trust. See [Microsoft code-signing options](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/code-signing-options) and [Certum Open Source Code Signing](https://www.certum.eu/en/code-signing-certificates/).
