# Main branch protection

**Repository:** [REMEDIOSSAMUEL/EYE-BREAK-REMINDER](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER)  
**Last audited:** 2026-11-16

## Ruleset

- **Name:** Protect main — PR and CI required
- **Ruleset ID:** 27397921
- **Settings:** [Open the ruleset](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/rules/27397921)
- **Enforcement:** Active
- **Target:** The exact branch ref `refs/heads/main`
- **Required pull requests:** Yes. Ordinary direct pushes to `main` are blocked.
- **Required approvals:** 0. At the audit, REMEDIOSSAMUEL was the only repository collaborator. This allows the solo maintainer to merge their own PR after CI passes.
- **Required status check:** `Core tests and Windows package` from GitHub Actions (integration ID 15368).
- **Up-to-date branch:** Required before merging.
- **Conversation resolution:** Required.
- **Force pushes:** Blocked by the non-fast-forward rule.
- **Branch deletion:** Blocked.
- **Merge methods:** Merge, squash, and rebase are allowed.
- **Bypass actors:** None. Administrators are not configured as bypass actors; repository administrators can still edit the ruleset for recovery.

GitHub also returns its default additional-approval setting for unattributed Copilot pull requests. That setting has no effect while the required approval count is zero, as described in [GitHub's ruleset documentation](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets#require-an-additional-approval-for-unattributed-copilot-pull-requests).

## Required CI

The workflow is [`.github/workflows/pull-request-validation.yml`](../.github/workflows/pull-request-validation.yml). It runs for every pull request targeting `main`, without path filters or conditional skips. The `Core tests and Windows package` job runs on Ubuntu 24.04 with a 20-minute timeout and read-only repository permissions. It installs the build dependencies and runs the existing `make package` command, which runs the core tests, cross-builds the Windows application and installer, packages them, and verifies the package. The workflow does not publish releases or upload build artifacts.

Validation evidence: [PR #4](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/pull/4) passed [run 43931328595](https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/actions/runs/43931328595) with the required check and was merged after GitHub reported the PR clean and mergeable.

## Contribution and release workflow

1. Create and push a feature branch.
2. Open a pull request targeting `main`.
3. Wait for `Core tests and Windows package` to pass. Keep the branch up to date with `main` if it advances.
4. Resolve review conversations, then merge the PR. No human approval is required by this ruleset.
5. For a future release, make version/source changes through PRs, merge them to `main`, then create the intended version tag and GitHub Release through the normal release process.

This ruleset targets only `refs/heads/main`; it does not target feature branches, tags, or Actions artifact references. It does not require a release workflow to push directly to `main`.

## Safe administrative recovery

First inspect the Actions run and confirm the required check's exact name and source. Prefer repairing or replacing the workflow through a pull request. If a GitHub Actions outage prevents any repair PR from passing, a repository administrator may temporarily remove or replace only the unavailable status-check requirement in this ruleset so a repair PR can merge. Keep the pull-request, conversation-resolution, force-push, and deletion protections active; do not add a bypass actor or push directly to `main`. Record the reason and time, merge only the repair PR, then restore the verified status check immediately and confirm it is active.