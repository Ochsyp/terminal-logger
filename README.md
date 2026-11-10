# terminal-logger

A recorder for zsh terminal sessions on Kali Linux, keystrokes included, as evidence for
penetration tests.

> **Status:** phase 2. `tlogger start` records a terminal on request and `tlogger stop` pauses the
> recording; recording every new terminal by itself arrives in the next phase. `tlogger install`,
> `uninstall` and `status` put the plugin in place and take it out again.
> [CONTRIBUTING.md](CONTRIBUTING.md) describes the workflow, and [CHANGELOG.md](CHANGELOG.md)
> lists what changed.

## What it will do

The finished `tlogger` command:

- records every new terminal with util-linux `script`: keystrokes and screen output, with timing
  (`--log-in`, `--log-out`, `--log-timing`, advanced format); this version records on request,
  as [Recording](#recording) describes;
- captures passwords typed at hidden prompts, and everything inside reverse shells, unstable
  shells and subshells, because `script` wraps the outer terminal;
- keeps a command journal with the start time of each command in UTC;
- shows a `REC` or `NOREC` marker in Kali's own prompt;
- replays a session with `scriptreplay`;
- renders a session as a plain-text transcript offline with `python3-pyte`, with no tmux anywhere;
- seals a finished session with SHA-256 sums, which expose a later change only while a copy of
  the sums is kept apart from the logs;
- keeps its logs under `~/.local/state/tlogger`, with mode 0700 for directories and 0600 for
  files.

## Install

Until the first release, install from a checkout of this repository, as the user whose terminals
are to be recorded, not as root:

```bash
bin/tlogger install --mode manual
```

Installing from a release, with a download you can check, comes with the first release.

`install` shows its plan and the change to the rc as a diff, then asks before it writes anything.
`--dry-run` shows the same and writes nothing, and `--print-only` prints only the block. Outside a
terminal, pass `--mode` and `--yes`. `--mode manual` records only on request; `--mode auto` will
record every new terminal once autostart arrives in the next phase. This version records only on
request, with `tlogger start`, in both modes.

`install` adds these 4 lines at the top of `${ZDOTDIR-$HOME}/.zshrc`, or updates an existing
block where it stands, and changes nothing else in the file:

```zsh
# >>> tlogger >>>
# Managed by tlogger; remove it with tlogger uninstall.
if [[ -r "$HOME/.local/share/tlogger/current/lib/tlogger.zsh" ]]; then source "$HOME/.local/share/tlogger/current/lib/tlogger.zsh"; elif [[ -o interactive ]]; then print -u2 "tlogger: plugin missing, this terminal is NOT recorded"; fi
# <<< tlogger <<<
```

The paths follow the XDG base directories as zsh sees them, `.zshenv` included. With the
defaults they are:

| What | Where | Modes |
|---|---|---|
| Code | `~/.local/share/tlogger/releases/<version>/`, and `current`, a symlink to the release in use; the current release and one older one are kept | 0755 folders and `bin/tlogger`, 0644 files |
| Config | `~/.config/tlogger/config`: `key=value` lines, read as data and never run | 0700 folder, 0600 file |
| State | `~/.local/state/tlogger/`: `sessions/` for the logs, `rc-backups/` for a copy of the rc before each change, of which install keeps the five newest | 0700 folders, 0600 backups |

The rc keeps its mode, its hard links and every byte outside the block, CRLF line ends and a
missing final newline included. A missing rc is created from `/etc/skel/.zshrc`, or empty without
that file. tlogger does not edit an rc that is a symlink, not a regular file, another user's file
or not writable: it prints the block to add by hand at the top, and exits 1. With the block in
place, the next `install` sets up the rest and leaves that file as it is. `install` also refuses
while another line of the rc runs util-linux `script`, the sign of another session recorder.

In a new zsh terminal, `tlogger status` names the plugin version and shows whether the terminal is
recorded; [Recording](#recording) describes the commands. Outside zsh,
`~/.local/share/tlogger/current/bin/tlogger status` reports the installation instead.

### Uninstall

```bash
tlogger uninstall
```

Outside zsh, run `~/.local/share/tlogger/current/bin/tlogger uninstall`. It removes the block and
the code. The config stays unless `--purge-config` is given. The state folder, with the logs and
the rc backups, always stays: delete it by hand when the rules of the engagement allow it.
`--dry-run` shows the change to the rc and what would be removed.

### Exit status

| Status | Meaning |
|---|---|
| 0 | Done, or nothing to change |
| 1 | An error or a refusal; a refusal changes nothing. For `status`: installed only in part |
| 2 | A usage error, or `--mode` or `--yes` missing outside a terminal |
| 3 | Not installed, or nothing to remove |

## Recording

In a zsh terminal with the plugin loaded:

| Command | What it does |
|---|---|
| `tlogger start` | Records this terminal: runs util-linux `script` in the foreground with a new zsh inside it |
| `tlogger stop` | Pauses: ends the recording and returns to the shell that ran `tlogger start` |
| `tlogger status` | Shows this terminal's state and session, the plugin version, the mode, the log folder and `record_input` |

`tlogger start` prints one line before it records, and the new shell confirms that it records:

```text
tlogger: recording session 20261104T101500Z-a1B2c3; everything typed and shown is saved, passwords included; tlogger stop pauses
tlogger: REC 20261104T101500Z-a1B2c3
```

The recording covers everything that runs in that shell: commands and programs, `sudo` and
`ssh`, nested shells and subshells, reverse shells and unstable shells, because `script` wraps the
terminal itself. `tlogger stop` in the recorded shell ends the recording and returns to the shell
where `tlogger start` ran, which is not recorded:
`tlogger: recording paused; this terminal is NOT recorded; tlogger start resumes in a new session`.
`exit` ends the recording as well. `tlogger start` resumes, in a new session. `tlogger stop` works
only in the shell that `tlogger start` opened, also after `exec zsh` there, and not while that
shell has running or suspended jobs; in a nested shell or a subshell it says what to do instead.

`tlogger status` names the state of the terminal it runs in: `REC <id>` while tlogger records it,
`EXT` while another `script` process records it, and `NOREC` while nothing does. Messages name a
session by its id, which is its folder name, and show home paths as `~`.

### What is recorded

Each recording gets a session folder of its own, `<log folder>/<UTC time>-<6 random characters>`,
with mode 0700. Its files have mode 0600:

| File | Content |
|---|---|
| `input.raw` | Every keystroke, passwords typed at prompts that do not show them included (`sudo`, `ssh`, `read -s`) |
| `output.raw` | Everything the terminal showed |
| `timing` | When each piece of input and output came, in the advanced format of util-linux `script`, which `scriptreplay` reads |
| `recorder`, `started`, `exited`, `stop-requested` | Markers: which `script` process recorded, and how the recording began and ended |

The log folder is `~/.local/state/tlogger/sessions` unless the config names another one. The
header of `output.raw` and the timing file use UTC; the recorded shell keeps your own time zone.

### Modes and settings

- `manual` records only on `tlogger start`.
- `auto` will record every new terminal once autostart arrives in the next phase. Until then it
  records only on request, as `manual` does.

`~/.config/tlogger/config` holds `key=value` lines and `#` comments; tlogger reads it as data and
never runs it.

| Key | Values | Default |
|---|---|---|
| `mode` | `auto` or `manual` | `manual` |
| `logdir` | An absolute path | `~/.local/state/tlogger/sessions` |
| `record_input` | `yes`, or `no` to write no `input.raw` | `yes` |
| `min_free_mb` | The free space in MB that `tlogger start` needs in the log folder | `200` |

An exported `TLOGGER_<KEY>` variable, such as `TLOGGER_LOGDIR=/home/kali/evidence`, wins over the
file. An invalid value gets its default and one warning. The config also takes `recorder`, the
path of the `script` binary, which exists for the tests.

### Kill switches and refusals

`TLOGGER_DISABLE=1` in the environment, or a file named `disable` in `~/.config/tlogger`, stops
`tlogger start`. Before it records, `tlogger start` also checks that nothing records the terminal
already, that `/usr/bin/script` is util-linux 2.35 or newer, that the log folder is a folder of
yours, not a symlink, that you can write in (a missing one is created with mode 0700), that its
group and other users cannot write in it unless its sticky bit is set, and that it has at least
`min_free_mb` MB and 100 inodes free. It also refuses when the new session folder or its files do
not keep their private modes, as on a file system without POSIX modes such as vfat. When a check
fails, it prints a red `tlogger: NOT recording this terminal: <reason>`, records nothing and
leaves the shell as it was. A recording that fails to start, or ends without `exit` or
`tlogger stop`, for example because the `script` process was killed, gets a red or yellow notice
too.

> **Warning:** the session folders hold secrets in cleartext: every password typed in a recorded
> terminal, and every key, token or hash it showed. Keep the log folder on encrypted storage, such
> as a LUKS volume, with its private permissions.

## Security

The logs hold everything typed and shown in a recorded terminal, passwords included.

- Keep the log folder on encrypted storage, such as a LUKS volume, with private permissions.
- Record only systems and engagements you are authorized to test. Keep and destroy the logs
  under the engagement's rules.

[SECURITY.md](SECURITY.md) describes how to report a vulnerability.

## Development

Turn on the git hooks once after cloning:

```text
git config core.hooksPath .githooks
```

They refuse commits on `main` or `master` and pushes to them. They also refuse a commit whose
staged content, path names, message, author or committer holds a term from your local denylist.
[CONTRIBUTING.md](CONTRIBUTING.md) describes them, what they do not check, and the workflow.

Run the tests from the repository root with [bats-core](https://github.com/bats-core/bats-core):

```bash
bats tests/
```

The ShellCheck test needs `shellcheck` on PATH and is skipped without it. Tests that need a real
zsh, util-linux `script`, the Linux `/proc`, symlinks, POSIX file modes, hard links, mawk or gawk
skip on a machine without them, and the tests tagged `root` skip unless run as root. The
end-to-end tests record real sessions in a pseudo-terminal that zsh's `zpty` module drives. CI
runs the whole suite on Kali Linux in a container, with ShellCheck 0.11.0, and fails when any
test is skipped. [CONTRIBUTING.md](CONTRIBUTING.md) tells how to run the suite as CI does.

## Licence

MIT, see [LICENSE](LICENSE).
