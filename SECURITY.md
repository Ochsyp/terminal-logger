# Security policy

One maintainer runs terminal-logger. It runs on the tester's own Kali machine and records that
machine's terminals.

<!-- standard:begin reporting -->
## Reporting a vulnerability

Report a vulnerability through GitHub's private vulnerability reporting: the **Security** tab,
then **Report a vulnerability**. Do not open a public issue.
<!-- standard:end reporting -->

## Supported versions

Only the latest release gets security fixes, as a new release. One maintainer runs the project,
so there is no fixed response time.

## Scope

In scope:

- a way past the replay filter or the transcript's cleaning, so that a target's escape sequences
  reach your terminal;
- a way past seal, verify or `archive --verify`, so that a change to a sealed session or an
  archive goes unreported;
- a race on files, links or folder modes that lets someone else read, swap or add a log;
- `archive` copying, or `prune` removing, anything other than what its checks allow;
- a leak of log content to another user, another file or the network.

Out of scope:

- an attacker who is root, or your own user, on the machine that records;
- a host that others use, where tlogger is not meant to run;
- what the README lists under
  [What tlogger does not protect against](README.md#what-tlogger-does-not-protect-against).

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
