# Security policy

One maintainer runs terminal-logger. It runs on the tester's own Kali machine and records that
machine's terminals.

<!-- standard:begin reporting -->
## Reporting a vulnerability

Report a vulnerability through GitHub's private vulnerability reporting: the **Security** tab,
then **Report a vulnerability**. Do not open a public issue.
<!-- standard:end reporting -->

## Data that stays private

Never attach a real session log to a report, an issue, a pull request or a commit. A log holds
everything typed and shown in the recorded terminal, passwords included. Reproduce the problem
with synthetic data instead.

<!-- standard:begin automated-checks -->
## Automated checks

- **Secret scan.** The `secret-scan` workflow runs gitleaks (MIT, pinned by version and SHA-256,
  always with its default rules) and this repository's rule packs. It scans the commits of each
  pull request and each push to `main`, and the whole history every Monday and when run by hand.
  Positive controls run first, so a scanner that finds nothing fails. Findings are redacted.
  GitHub's secret scanning and push protection are on as well. GitHub turns the Monday run off
  after 60 days without activity in this repository.
- **Hooks.** The hooks in `.githooks/` check every commit and push on the maintainer's machine:
  content, path names, messages, ref names and identities, against the rule packs and a denylist
  that never leaves that machine. The maintainer also checks regularly, with repo-standard's
  `tools/status`, what reached GitHub, pull request texts and release notes included.
- **CI and releases.** The `ci` workflow checks the standard's copies, the privacy rules over the
  tree, the version, the changelog and the pull request, and runs the tests. The `release`
  workflow builds, attests and drafts each release, and verifies it once it is published.
- **Dependencies.** Dependabot watches the ecosystems in `.github/dependabot.yml`, with security
  updates on.

If a secret is ever committed, rotate it first, then remove it from the history.
<!-- standard:end automated-checks -->

<!-- standard:begin sealed-releases -->
## Sealed releases

Hosts install a release of this repository only when the maintainer has sealed it. A seal is an
annotated tag `seal/vX.Y.Z` with the message `<repository> vX.Y.Z`, signed with the
maintainer's offline SSH key, on the commit of the published release `vX.Y.Z`. The maintainer
seals after the publish, with a seal tool that first checks the release: published, immutable,
neither a draft nor a pre-release, drafted by GitHub Actions, its commit on `main`, its `verify`
run green, and `SEAL=yes` set once in `.github/standard.conf` at that commit. The tool refuses a
release made before the repository set `SEAL=yes`.

A host checks the seal with `git verify-tag` against its own root-owned list of allowed signers.
It also checks the seal's message, that the seal and `vX.Y.Z` name the same commit, that this
commit is on `main`, that no tag it has seen has moved, and that the version is newer. It needs
no GitHub token for this and calls no API. A stolen GitHub token or session can publish a
release but cannot seal it, so no host installs that release. A seal never moves and is never
deleted. A release that must not be installed stays unsealed, or is held on the hosts as the
Release contract in `CONTRIBUTING.md` says.
<!-- standard:end sealed-releases -->
