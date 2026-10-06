# Manual releases from Linux

Target repository: https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER

This process uses a local Linux build and consumes no GitHub Actions minutes.

1. Start from the repository's current branch, inspect existing files/history and preserve unrelated content. If importing the source archive, put its `src`, `assets`, `installer`, `tests`, `scripts`, `docs`, Makefile and documentation at the project root. Do not nest the complete project inside repeated folders or copy an old WinUI project over it.
2. Configure the **SRemedios** author/committer name and the owner's exact account-linked email as described in CONTRIBUTING.md. Confirm both identities before committing. Keep the existing remote URL.
3. Set the next version with `python3 scripts/set-version.py X.Y.Z`. Describe the final change and testing limits in CHANGELOG.md and docs/VERIFICATION.md.
4. Run `make package`. Require successful core assertions and binary/package checks. Perform Windows testing where available and record the result; do not mark unsigned or untested binaries as signed or production-verified.
5. Review the source diff and commit it. Only source/documentation belongs in the normal Git tree; `release/` is ignored. Push the source commit using the owner's authenticated account, then tag that exact commit `vX.Y.Z`.
6. Publish a GitHub Release for that tag, with a short description of the changes and validation. Attach `EyeBreakReminder-Setup-x64.exe`, `EyeBreakReminder.exe`, `EyeBreakReminder-Portable-x64.zip`, `EyeBreakReminder-Source.zip` and `EyeBreakReminder-SHA256.txt` from the same build. Do not mix artifacts from different builds.
7. Confirm the release tag points at the source commit and the attached artifact hashes match the manifest. Keep the installer available in the chat response as well.

Never force-push or replace repository history for a routine release. Repository visibility, access permissions and source licensing are owner decisions. Signing requires the owner's legitimate certificate and must happen before regenerating packages/hashes.

