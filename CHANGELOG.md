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
  block in an rc.
- `tlogger start` and `tlogger stop` record a zsh terminal on request with util-linux `script`:
  keystrokes, passwords at hidden prompts included, screen output and timing go into a session
  folder of its own (0700, files 0600) under the log folder, with UTC timestamps, while the
  recorded shell keeps its time zone. `tlogger stop` pauses and `tlogger start` resumes in a new
  session; `tlogger status` shows whether the terminal is recorded (REC, EXT or NOREC). A kill
  switch, a recorded terminal, an old or missing `script`, an unusable log folder, one that other
  users may write in, a session folder that cannot stay private or too little free space stop
  `tlogger start` with a red notice and leave the shell working. A recording whose `script`
  process dies counts as ended unexpectedly. The config takes `record_input` and `min_free_mb`,
  and `TLOGGER_<KEY>` variables win over it; `lib/config.zsh` reads it as data.
- Tests for the config parser, for the terminal state over a fake `/proc`, and end to end in a
  pseudo-terminal that zsh's `zpty` module drives, also under the rc built from Kali's
  `/etc/skel/.zshrc`.
- Automatic mode: with `mode=auto`, every new interactive zsh terminal records itself as its shell
  starts, through the same checks and recording as `tlogger start`. `exit` and Ctrl+D end the
  recording and close the terminal; `tlogger stop` pauses and keeps it open, as does a recording
  that is refused, fails to start or ends unexpectedly, with its notice. `zsh -c` and `zsh -i -c`
  commands, VS Code's environment probe, asciinema recordings, shells without a terminal and
  terminals that are recorded already do not record themselves, and say nothing. The kill
  switches, `TLOGGER_DISABLE=1` and the `disable` file, stop it with a red notice in each new
  terminal, and exported `TLOGGER_<KEY>` variables, such as `TLOGGER_MODE=manual`, set the policy
  of a terminal profile.
- `tlogger mode` prints the mode in the config, and `tlogger mode auto|manual` sets it: it
  changes only the `mode=` line and writes the config with mode 0600 through a temp file and a
  rename.
- The config keys `record_ssh` and `record_tmux` (`yes` or `no`, default `yes`) decide whether an
  SSH login or a tmux pane records itself in auto mode.
- A smoke test of the recorder: `install` in auto mode, a dry run included, and
  `tlogger mode auto` first record the command `true` with `script` in a private temp folder, and
  refuse auto mode when that fails.
- Tests of the autostart guard in a real zsh, of `tlogger mode` and the smoke test with a stub
  recorder, and end to end in auto mode in a pseudo-terminal that zsh's `zpty` module drives.

### Changed

- CI runs the tests in a `kalilinux/kali-rolling` container pinned by digest, with real zsh: as a
  non-root user, then the tests tagged root as root. It fails when a test fails or is skipped.
- `bin/tlogger` reads the config by the line rules of `lib/config.zsh`: values are trimmed, and
  indented comments and lines of blanks are skipped. `install` keeps the `record_input`,
  `min_free_mb` and `recorder` lines as they are, and a release holds `lib/config.zsh` as well.
  `bin/tlogger start` and `stop`, which a terminal still on the plugin it loaded before an
  install sends there, exit 2 and say that they work only in a zsh terminal that has loaded the
  plugin.
- The config that `install` writes for a new user names the optional keys `record_input`,
  `min_free_mb`, `record_ssh` and `record_tmux` in its comments.

[Unreleased]: https://github.com/Ochsyp/terminal-logger/commits/main
