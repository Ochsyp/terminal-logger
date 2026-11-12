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
- Per-command UTC start stamps, a `commands.tsv` journal and a REC/NOREC/EXT prompt segment, with
  VPN addresses. A recorded shell, nested shells included, appends an S line as each command
  starts (time, pid, folder, VPN list and the command as typed, quoted so that it stays on one
  line) and an E line with its exit status before the next prompt, and prints a dim
  `-- <UTC> <VPN list> REC` stamp. Every shell with the plugin shows `[<UTC> <VPN list> <state>]`
  at the end of the first line of a two-line prompt, or in front of a one-line one, and exports
  it as `TLOGGER_SEGMENT` for prompt frameworks. Kali's prompt, its `precmd()` and the shell's
  options stay untouched; the hooks fork nothing per command. The VPN list comes from
  `/sys/class/net` and `ip`, which runs again when the VPN interfaces change or a minute has
  passed, or 5 seconds after it showed a VPN interface without an address. A recorded shell
  warns, at most every five minutes, when its log folder has less than `min_free_mb` free.
- The config keys `prompt`, `stamp` and `stamp_vpn` (`on` or `off`, default `on`), `vpn_ifaces`
  (default `tun* wg* tap*`) and `history_timestamps` (`yes` or `no`, default `no`, which turns on
  zsh's `extended_history`), each with its `TLOGGER_<KEY>` preset. `tlogger status` shows
  `prompt`, `stamp` and the VPN list.
- Unit tests of the journal, the stamps, the VPN list and the segment in a real zsh, Kali's
  `configure_prompt` in both Ctrl+P states included, and end-to-end tests of the journal, the
  stamp and the segment, with Ctrl+P under the rc built from `/etc/skel/.zshrc`.
- `tlogger render`, `show` and `replay`, which build a derived plain-text transcript with
  `python3-pyte` and replay through an escape-sequence filter, without tmux. `render` writes
  `transcript.txt` (mode 0600, through `transcript.txt.part` and a rename) in the session folder,
  or prints it with `--stdout`: the lines that scroll off the screen or that `clear` erases, the
  screen at the end, one marker line for a full-screen program, and a note line when
  `output.raw` ends early or timing lines are malformed, with no escape sequences. `show` pages
  it with `less` in secure mode, rendering it first when it is missing or older than the logs.
  `replay` runs util-linux `scriptreplay`, with `--speed` and `--maxdelay`, and passes its output
  through a filter that keeps only an allow-list of what draws the screen, without `CSI 3 J`,
  which would erase the scrollback of the terminal that replays. Each takes
  a session id, a path to a session folder or nothing for the newest session, and never writes
  the evidence files. `libexec/tlogger_view.py`, run with `/usr/bin/python3 -I`, does the work.
- Tests of the renderer on synthetic logs, of the replay filter and of the three commands, and an
  end-to-end test that renders and replays a session recorded in a pseudo-terminal.

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
  `min_free_mb`, `record_ssh` and `record_tmux` in its comments, and `prompt`, `stamp`,
  `stamp_vpn`, `vpn_ifaces` and `history_timestamps` as well.
- A session folder also holds `commands.tsv`, created empty with mode 0600 before the recording
  starts; a session that never started, with nothing but empty logs, is still removed.
- CI installs `python3` and `python3-pyte` and prints the versions of `scriptreplay`, `python3`
  and `python3-pyte`. A release holds `libexec/tlogger_view.py` as well.

[Unreleased]: https://github.com/Ochsyp/terminal-logger/commits/main
