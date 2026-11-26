# Changelog

All notable changes to this project are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Each version is the GitHub release `vX.Y.Z`.

## [Unreleased]

### Added

- `stamp=hidden`: each recorded command's stamp goes into the recording as a control string that
  terminals do not show, an OSC 7711 string, and `tlogger render` turns it into the stamp line of
  the transcript. tmux and GNU screen show none of it, and CI checks both.
- `prompt_time=iso|readable` chooses how the prompt shows the UTC time.
- Sealed sessions: a recording that ends with `exit`, Ctrl+D or `tlogger stop` is sealed at once.
  `SHA256SUMS` lists the SHA-256 of each log and marker, they become 0400, `SEAL` records the
  version, the time and the sum of `SHA256SUMS`, the data goes to the disk, and `MANIFEST` in the
  log folder gets the session's line; the terminal prints the sum to keep apart (phase 9)
- `tlogger seal [SESSION | --all]` seals by hand, for example a recording that ended
  unexpectedly; it refuses a session whose recorder still runs (phase 9)
- `tlogger verify [SESSION | --all]` reports each session as ok, changed, unsealed or recording,
  with each change, and `tlogger list` shows every session's state, start, duration, commands
  and transcript (phase 9)

### Changed

- A recording that ends unexpectedly says that its session is not sealed, and how to seal it.
- The README points to the releases and this changelog instead of a status note, and says that
  QTerminal, Kali's default terminal, hides the hidden stamp, checked by hand.
- The prompt shows what the older logger's prompt showed: the UTC time as
  `2026-11-26 13:20:52 UTC` in yellow, the VPN list in magenta, or `no vpn`, and the state, `REC`
  green, `NOREC` red and `EXT` cyan, each in brackets of its own. `NO_COLOR` drops the colours,
  and `TLOGGER_SEGMENT` stays as it was.
- The notice that a recording has started is green.
- `stamp` defaults to `hidden`, so no stamp line shows after each command any more. A config
  that names `stamp` keeps its value: `stamp=on` the visible line, and `stamp=off` no stamp at
  all. A `stamp=off` line written to hide the visible line in 0.1.0 can now go, or become
  `stamp=hidden`, so that the recording keeps each command's time.
- `VERSION` is `0.1.1-dev` after the release of 0.1.0, so an install from a checkout of `main`
  names a development version again.
- The README, `docs/guide.md` and the Release contract install a release without a login: `curl`
  downloads the two assets from the release's URLs, and `sha256sum -c SHA256SUMS` checks them.
  `gh attestation verify`, which needs a GitHub login, follows as an optional extra.

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
