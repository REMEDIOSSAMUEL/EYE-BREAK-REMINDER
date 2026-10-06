# Contributing

This project targets Windows 11 x64 and is built from Linux using MinGW-w64 and NSIS. Keep native Windows input, keyboard focus, high contrast and text/DPI scaling intact when changing the UI.

## Development

1. Install the packages listed in README.md.
2. Change the relevant source, installer or assets.
3. Run `make package` to execute core tests, build the application/installer, create archives and verify their bytes.
4. Run the applicable checks in `docs/WINDOWS-TESTING.md` on Windows. Record what was executed and what remains untested in `docs/VERIFICATION.md`.
5. Update CHANGELOG.md. Use `python3 scripts/set-version.py X.Y.Z` when preparing a release.

Add tests for changes to timer behavior, recovery and serialization. Visual changes require Windows checks; a compile-only result must be described accurately. Never commit personal application data, signing keys, downloaded toolchains or generated releases.

## Requested commit identity

The repository owner requests the author and committer display name **SRemedios**. Use the real account-linked Git email (or the exact private noreply address shown in GitHub account settings). A name alone does not guarantee that GitHub credits the account.

Configure identity in this repository, not globally:

```sh
git config --local user.name SRemedios
git config --local user.email 'remediossamuel@gmail.com'
git var GIT_AUTHOR_IDENT
git var GIT_COMMITTER_IDENT
```

Do not use an assistant identity or add assistant coauthor trailers to commits made for the owner. Do not invent an email address. Preserve existing repository history and unrelated work when applying an update.

## Source licensing

The repository owner has not yet selected a source license. Do not add one without their instruction. Bundled runtime/installer notices are in `docs/THIRD-PARTY-LICENSES.txt` and are separate from a license for this project's source.
