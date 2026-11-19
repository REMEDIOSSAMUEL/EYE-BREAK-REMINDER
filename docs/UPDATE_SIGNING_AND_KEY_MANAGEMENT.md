# Update signing and key management

**Status (2026-11-19):** ECDSA P-256/SHA-256 update-manifest verification and offline signing tooling are implemented. The production verification key is deliberately unprovisioned, so this source build rejects every update. A development-only executable exists, but no complete or production release candidate has been created.

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

## Provision a production key

Use an offline signing machine and an encrypted removable drive that is outside the checkout and all synchronized folders. Keep the passphrase in a password manager. Make a separately protected encrypted backup and record who controls it. The command prompts for the PEM encryption passphrase; the script never prints the private key. It refuses to overwrite existing key files, refuses identical private/public paths, and signing refuses output paths that collide with keys or payloads or already contain metadata. Use an offline drive with protected access and no automatic synchronization; do not pass the passphrase on a command line.

```powershell
python scripts/update_signing.py generate `
  --private-key "E:\EyeBreakReminderSigning\production-private.pem" `
  --public-key "E:\EyeBreakReminderSigning\production-public.pem"

python scripts/update_signing.py embed-public `
  --public-key "E:\EyeBreakReminderSigning\production-public.pem"
```

Review the generated key ID and public-key diff, then commit only `src/update_trust.hpp`. Keep both PEM files on protected offline storage; never put the private PEM in Git, OneDrive, an installer, a ZIP, a workflow artifact, a screenshot, or a log. Do not provision a key until its backup and recovery procedure are in place. The owner must perform this step; the key has not been generated here.

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

No automatic key rotation is implemented. Rotation requires a new trusted installation whose embedded key is reviewed out of band, or a future design where the currently trusted key signs and authorizes a successor key. Never trust a replacement key merely because GitHub serves it. If the private key is lost or suspected compromised, stop signing; publish no further updates under it. Recovery requires an owner-verified installer with a new embedded public key. The update path will not install a downgrade. A legitimate rollback requires a separately verified manual installer and user-data recovery procedure; an old signed manifest is not a downgrade bypass.

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
