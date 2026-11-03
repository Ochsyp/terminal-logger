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
- `tlogger install`, `uninstall`, `status`, `version` and `help` in `bin/tlogger`. `install` puts
  a 4-line block at the top of the zsh rc and installs the plugin under `~/.local/share/tlogger`,
  the config under `~/.config/tlogger` and the state folders under `~/.local/state/tlogger`;
  `uninstall` takes the block and the code out again and keeps the logs and rc backups. The
  plugin, `lib/tlogger.zsh`, defines the `tlogger` command, and `libexec/rcblock.awk` finds the
  block in an rc. Nothing is recorded yet.

### Changed

- CI runs the tests in a `kalilinux/kali-rolling` container pinned by digest, with real zsh: as a
  non-root user, then the tests tagged root as root. It fails when a test fails or is skipped.

[Unreleased]: https://github.com/Ochsyp/terminal-logger/commits/main
