# Changelog

All notable changes to this project are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). There are no releases yet.

## [Unreleased]

### Added

- Repository scaffolding: the README, the MIT licence, a security policy, a contribution guide,
  this changelog, a pull request template, and editor, git and ShellCheck settings.
- Git hooks in `.githooks`: they refuse commits on `main` or `master`, merge commits included,
  and pushes to them, and they refuse a commit whose staged content, path names, author,
  committer or message holds a term from the local denylist.
- CI: a `tests` workflow that runs the bats suite with a pinned ShellCheck and fails when a test
  is skipped, a gitleaks secret scan, and Dependabot updates for the pinned GitHub Actions.

[Unreleased]: https://github.com/Ochsyp/terminal-logger/commits/main
