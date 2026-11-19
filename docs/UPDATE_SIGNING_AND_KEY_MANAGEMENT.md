# Update signing and key management

**Status (2026-11-19):** ECDSA P-256/SHA-256 manifest verification and signing tooling are implemented. The signing tool now rejects production private-key paths in the checkout, OneDrive roots, and temp directories, and verifies a new dedicated key directory's Windows DACL is limited to the current user. Its seven focused signing-tool tests pass, including a real disposable Windows ACL check. No existing Eye Break Reminder CNG production key or matching current-user publisher certificate was found. The environment has no removable volume for an offline recovery copy, so no production key was generated or embedded. There is no production-signed candidate; Authenticode is a separate unresolved control.

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

- Actual Windows CNG verification passed 11 assertions, including malformed, tampered and other-key signatures, in [run 44626772320](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44626772320).
- Signed GUI update, settings-preservation/clean-install policy and transaction failure/recovery passed with disposable test keys in [run 44614219099](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44614219099). Production-key jobs were skipped because no production key exists in the environment.
- The same current-head security run passed SEC-028 for 25/25 rejection paths and FAIL-001 through an actual GUI DNS failure and successful normal GitHub retry. The only prior NOT TESTED item now is UN-009; the hosted runner does not provide the Installed Apps settings page.
- Required Core tests and Windows package passed on current feature head in [run 44626772318](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44626772318). Updater resource loops passed in [run 44626760993](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/44626760993).
- Current count: 217 PASS, 0 FAIL, 1 NOT TESTED, 11 BLOCKED, 2 NOT APPLICABLE. No complete current candidate or production metadata signature has been produced. Do not treat test-key artifacts as production candidates.

The signing-tool hardening rejects private-key paths under the repository, the checkout-detected or environment-configured OneDrive roots, and the system temp directory. Key generation requires a new dedicated directory on an existing volume, removes inherited ACEs, grants access only to the current Windows user SID, verifies that DACL, and verifies the generated private file inherited the same access. The encrypted PEM itself uses OpenSSL AES-256-CBC and its passphrase prompt; the passphrase is never accepted on the command line. Production key generation and signing require Windows so the tool can enforce and recheck the user-only ACL. Use a password-manager-generated random passphrase with at least 128 bits of entropy. The current seven-test suite includes the OneDrive/temp/repository path rules and an actual ACL creation/readback test in a disposable directory.

## Provision a production key

Use an offline Windows signing machine and an encrypted NTFS removable drive that is outside the checkout and all synchronized folders. The key-directory path supplied below must not already exist; its parent volume root must already be mounted. The generator creates the dedicated directory, removes inherited access rules, grants only the current Windows user SID, and verifies the directory and private-key file ACLs. It rejects paths in the checkout, a detected OneDrive root, or the system temp directory. The key uses OpenSSL AES-256-CBC and an interactive passphrase prompt. Generate a random passphrase with at least 128 bits of entropy in a password manager. Keep that passphrase there and make a separately protected encrypted backup on offline media; never save the passphrase beside the private-key backup. The script never prints the private key and never accepts its passphrase in an argument. It refuses to overwrite existing key files, refuses identical private/public paths, and signing refuses output paths that collide with keys or payloads or already contain metadata.

```powershell
python scripts/update_signing.py generate `
  --private-key "E:\EyeBreakReminderSigning\production-private.pem" `
  --public-key "E:\EyeBreakReminderSigning\production-public.pem"

python scripts/update_signing.py embed-public `
  --public-key "E:\EyeBreakReminderSigning\production-public.pem"
```

Review the generated key ID and public-key diff, then commit only `src/update_trust.hpp`. Keep both PEM files on protected offline storage; never put the private PEM in Git, OneDrive, an installer, a ZIP, a workflow artifact, a screenshot, or a log. Do not provision a key until its offline backup and recovery procedure are in place. In this session, the expected Eye Break Reminder user CNG key was absent (Windows returned `NTE_BAD_KEYSET`), no matching publisher certificate existed, and the removable-volume inventory returned no devices. Therefore no private key was generated, no public trust key was embedded, and production updates remain fail-closed. An offline NTFS recovery device and a separately managed passphrase are the minimum custody prerequisites; no identity or passphrase was invented.

## Sign and verify a release

Build and test final payloads first. If Authenticode signing is available, sign and verify the EXE and installer before building the portable ZIP and before hashing. Do not alter any payload after signing its manifest digest.

```powershell
python scripts/update_signing.py sign `
  --private-key "E:\EyeBreakReminderSigning\production-private.pem" `
  --public-key "E:\EyeBreakReminderSigning\production-public.pem" `
  --version 1.4.1 `
  --expires-at "2027-02-17T00:00:00Z" `
  --installer "release\EyeBreakReminder-Setup-x64.exe" `
  --portable "release\EyeBreakReminder.exe" `
  --manifest "release\EyeBreakReminder-UpdateManifest.json" `
  --signature "release\EyeBreakReminder-UpdateManifest.sig"

python scripts/update_signing.py verify `
  --public-key "E:\EyeBreakReminderSigning\production-public.pem" `
  --manifest "release\EyeBreakReminder-UpdateManifest.json" `
  --signature "release\EyeBreakReminder-UpdateManifest.sig"
```

The tool validates the canonical schema and payload names, hashes the exact EXE files, creates metadata, asks OpenSSL to sign the complete manifest bytes, converts the DER signature to the 64-byte P1363 format used by CNG, verifies the result against the public key, rehashes payloads before writing the outputs, and writes the two public metadata files. Its path-collision and no-overwrite checks protect existing payload/key/metadata files. Independently verify each release file's size and checksum after signing. The offline signer is never part of pull-request CI; only exact binaries from a reviewed, required-check-passing release commit may be brought to the protected signing process. Publish the manifest and signature as ordinary public release assets only after the protected release process approves the exact candidate.

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

The signed-manifest architecture is implemented as an alternative to relying solely on Authenticode for automatic-update authenticity. It does not change the original Authenticode acceptance requirement. The owner must explicitly approve this policy change before publication. At present neither the production manifest trust root nor an Authenticode certificate has been provisioned, so v1.4.0 is not production-ready.
