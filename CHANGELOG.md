# Changelog

All notable changes to this project are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Each version is the GitHub release `vX.Y.Z`.

## [Unreleased]

## [0.1.0] - 2026-11-26

The first release: a recorder for zsh terminals on Kali Linux, keystrokes included, as evidence
for penetration tests.

### Added

- `tlogger start` records a zsh terminal with util-linux `script`: keystrokes, passwords at
  hidden prompts included, screen output and timing, in a session folder of its own (0700, files
  0600) with UTC timestamps. `tlogger stop` pauses, and `tlogger start` resumes in a new session.
- Auto mode: with `mode=auto`, every new interactive zsh terminal records itself as its shell
  starts. `zsh -c` commands, VS Code's environment probe, shells without a terminal and terminals
  that are recorded already do not. `record_ssh` and `record_tmux` decide for SSH logins and tmux
  panes, and `tlogger mode auto|manual` switches the mode.
- Refusals that leave the shell working, with a red notice: the kill switches `TLOGGER_DISABLE=1`
  and the `disable` file, a missing or old `script`, a log folder that is unusable or that other
  users may write in, and too little free space.
- A command journal, `commands.tsv`, with each command's start time in UTC, folder, VPN addresses
  and exit status; a dim stamp before each command; and a `[<UTC> <VPN list> <state>]` segment in
  the prompt, with the state `REC`, `NOREC` or `EXT`. Kali's own prompt stays as it is.
- A config under `~/.config/tlogger`, read as data, with `TLOGGER_<KEY>` variables that win over
  it: `record_input`, `min_free_mb`, `prompt`, `stamp`, `stamp_vpn`, `vpn_ifaces`,
  `history_timestamps` and the mode keys.
- `tlogger render`, `show` and `replay`: a plain-text transcript derived from the logs, paged with
  `less` in secure mode, and a replay with `--speed` and `--maxdelay` through a filter that keeps
  only what draws the screen. None of them writes the evidence files.
- `tlogger install`, `uninstall`, `status`, `version` and `help`. `install` shows its plan and the
  change to the rc as a diff and asks first; `--dry-run` writes nothing. In auto mode it first
  records a test command, to prove that `script` works. `uninstall` keeps the logs.
- Installs from a release go to `~/.local/share/tlogger/releases/X.Y.Z`, with `current` pointing
  at it, and keep the release before it. `install` refuses an older release over a newer one, and
  an unpacked release whose manifest names another version.
- Moving from an older logger: `install --remove-block START END` takes its block out of the rc
  in the same checked write, keeps its bytes in a private quarantine, and prints how to undo it.
  `--block-sha256` holds a real run to the block the dry run showed.
- `docs/guide.md`, an engagement from start to end.
- Each release is a tar archive with `SHA256SUMS` and a GitHub build attestation.

[Unreleased]: https://github.com/Ochsyp/terminal-logger/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Ochsyp/terminal-logger/releases/tag/v0.1.0
