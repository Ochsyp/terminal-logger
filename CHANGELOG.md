# Changelog

All notable changes to this project are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Each version is the GitHub release `vX.Y.Z`.

## [Unreleased]

### Added

- `tlogger doctor` checks that the logs are on encrypted, private storage and that its volume is
  mounted. It only reads, changes nothing, and exits 1 on any warning or unknown.
  `tlogger engagement NAME` keeps each engagement's sessions in their own folder of the log
  folder, with their own `MANIFEST`, and `tlogger engagement --none` clears it. Two new settings:
  `engagement`, and `logdir_mount`, the mount point of the volume that holds the log folder.

### Changed

- `list`, `seal`, `verify`, `render`, `show` and `replay` refuse a log folder or engagement folder
  that is a symlink, another user's, or writable by its group or by others without the sticky
  bit, as a recording does; so does the folder that holds a session named by its path, which may
  also be root's. Such an engagement folder is no longer skipped silently. They do not need write
  permission, so a folder closed to mode 0500 still lists and verifies.
- A recording no longer creates a missing log folder other than the default. It refuses to record
  while the volume that `logdir_mount` names is not mounted, or while the engagement in the config
  is not a valid name; the terminal stays usable. `list` has an engagement column. `seal --all`,
  `verify --all`, session ids and the newest session also cover engagement folders. Sessions
  recorded before stay where they are, and keep verifying `ok`.
- `VERSION` is `0.2.1-dev` after the release of 0.2.0, so an install from a checkout of `main`
  names a development version again.
- Repository standard 1.3.1, with seals off: releases from the next one on are not sealed, and
  installing one needs no key and no login: download, `sha256sum -c SHA256SUMS` and the archive's
  commit line, with `gh attestation verify` as an optional extra. They rely on GitHub's immutable
  releases and the build attestation. v0.2.0 keeps its seal, the tag `seal/v0.2.0`.

## [0.2.0] - 2026-11-26

Sealed sessions, the older logger's prompt, and the first sealed release.

### Added

- Sealed sessions. A recording that ends with `exit`, Ctrl+D or `tlogger stop` is sealed at once:
  `SHA256SUMS` lists the SHA-256 of each log, the logs become read-only, `SEAL` names the version,
  the time and the sum of `SHA256SUMS`, and `MANIFEST` in the log folder gets the session's line.
  The terminal prints the sum; keep it, or a copy of `MANIFEST`, apart from the logs.
- `tlogger seal [SESSION | --all]` seals by hand, for example a recording that ended
  unexpectedly; it never seals a session that is still recorded. After the upgrade,
  `tlogger seal --all` seals the sessions recorded with 0.1.0.
- `tlogger verify [SESSION | --all]` says for each session ok, changed, unsealed or recording,
  and names each change. `tlogger list` shows every session with its state, start, duration,
  number of commands and transcript.
- `stamp=hidden`, the new default: each command's start time goes into the recording without
  showing on the screen, and `tlogger render` turns it into the stamp line of the transcript.
  QTerminal, tmux and GNU screen show nothing of it.
- `prompt_time=iso|readable` chooses how the prompt shows the time.

### Changed

- The prompt shows what the older logger's prompt showed: the UTC time as
  `2026-11-26 13:20:52 UTC` in yellow, the VPN list in magenta, or `no vpn`, and the state, `REC`
  green, `NOREC` red and `EXT` cyan, each in brackets of its own. `NO_COLOR` turns the colours
  off. The notice that a recording has started is green.
- No stamp line shows after each command any more. A config that names `stamp` keeps its value:
  a `stamp=off` line, as 0.1.0 needed to hide the line, keeps every stamp out of the recording;
  change it to `stamp=hidden`, or remove it.
- A recording that ends unexpectedly says that it is not sealed, and how to seal it.
- Releases are sealed from this one on: after publishing, the maintainer signs each release with
  an offline SSH key, as the tag `seal/vX.Y.Z`. The README's install steps check the seal before
  anything is unpacked, and download and check a release without a GitHub login.

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

[Unreleased]: https://github.com/Ochsyp/terminal-logger/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/Ochsyp/terminal-logger/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/Ochsyp/terminal-logger/releases/tag/v0.1.0
