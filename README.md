# terminal-logger

A recorder for zsh terminal sessions on Kali Linux, keystrokes included, as evidence for
penetration tests.

> **Status:** phase 3. In auto mode every new zsh terminal records itself as its shell starts; in
> manual mode `tlogger start` records a terminal on request. `tlogger stop` pauses the recording,
> and `tlogger mode` switches between the modes. `tlogger install`, `uninstall` and `status` put
> the plugin in place and take it out again. [CONTRIBUTING.md](CONTRIBUTING.md) describes the
> workflow, and [CHANGELOG.md](CHANGELOG.md) lists what changed.

## What it will do

The finished `tlogger` command:

- records every new terminal with util-linux `script`: keystrokes and screen output, with timing
  (`--log-in`, `--log-out`, `--log-timing`, advanced format); this version does so in auto mode,
  and records on request in manual mode, as [Recording](#recording) describes;
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
bin/tlogger install --mode auto
```

Installing from a release, with a download you can check, comes with the first release.

`install` shows its plan and the change to the rc as a diff, then asks before it writes anything.
`--dry-run` shows the same and writes nothing, and `--print-only` prints only the block. Outside a
terminal, pass `--mode` and `--yes`. `--mode auto` records every new terminal as its shell
starts, and `--mode manual` records only on request, with `tlogger start`; without `--mode`,
install keeps the mode in the config or asks. [Modes and settings](#modes-and-settings) describes
both.

Before it writes anything in auto mode, `install` runs a smoke test of the recorder: it records
the command `true` with `script` in a new private temp folder, which it removes again, and gives
up with exit 1 when `script` is missing, cannot run, lacks `--logging-format` or fails. Install
with `--mode manual` then, or fix `script`. `--dry-run` runs the smoke test too, and
`--print-only` does not.

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
| `tlogger stop` | Pauses: ends the recording and returns to the shell that started it |
| `tlogger status` | Shows this terminal's state and session, the plugin version, the mode, the log folder and `record_input` |
| `tlogger mode` | Prints the mode in the config; `tlogger mode auto` or `tlogger mode manual` sets it |

A recording prints one line before it starts, and the recorded shell confirms that it records:

```text
tlogger: recording session 20261104T101500Z-a1B2c3; everything typed and shown is saved, passwords included; tlogger stop pauses
tlogger: REC 20261104T101500Z-a1B2c3
```

The recording covers everything that runs in that shell: commands and programs, `sudo` and
`ssh`, nested shells and subshells, reverse shells and unstable shells, because `script` wraps the
terminal itself.

`tlogger status` names the state of the terminal it runs in: `REC <id>` while tlogger records it,
`EXT` while another `script` process records it, and `NOREC` while nothing does. Messages name a
session by its id, which is its folder name, and show home paths as `~`.

### Auto mode

In auto mode a new interactive zsh terminal records itself while its shell reads the rc: the
tlogger block at the top of the rc runs the same checks and the same recording as `tlogger start`,
and the rest of the rc then loads in the recorded shell.

- `exit` or Ctrl+D in the recorded shell ends the recording and closes the terminal: the shell
  that started the recording exits too, with the exit status of the recorded shell, and prints
  nothing.
- `tlogger stop` pauses and keeps the terminal open. The shell that started the recording says
  `tlogger: recording paused; this terminal is NOT recorded; tlogger start resumes in a new session`,
  loads the rest of the rc and is not recorded.
- A recording that a check refuses, that fails to start or that ends unexpectedly keeps the
  terminal open as well, with the red or yellow notice that
  [Kill switches and refusals](#kill-switches-and-refusals) describes, and the rest of the rc
  loads.

A pause or a refusal holds for that shell only. A later `zsh` or `exec zsh` in the same terminal,
or `source ~/.zshrc` there, records the terminal again as a new terminal does, checks included;
`exit` in a recording that `exec zsh` or `source ~/.zshrc` started closes the terminal.

The recorded shell is interactive but never a login shell, since `script` starts it as `zsh -i`.
On an SSH or console login, `.zprofile` therefore runs only in the shell that starts the
recording, which passes on what it exports; `.zlogin` runs there only when that shell goes on
after a pause or a failure; and `logout` does not work in the recorded shell, where `exit` does.

A shell does not record itself, and says nothing about it, when:

- the mode is `manual`, from the config or from `TLOGGER_MODE`;
- it runs a command, as `zsh -c` and `zsh -i -c` do: editors and IDEs start one to read the
  environment, which sets `ZSH_EXECUTION_STRING`;
- VS Code reads the environment through it (`VSCODE_RESOLVING_ENVIRONMENT` is set), or asciinema
  records it (`ASCIINEMA_REC` or `ASCIINEMA_SESSION` is set);
- it is an SSH login (`SSH_CONNECTION` or `SSH_TTY` is set) while `record_ssh` is `no`, or a tmux
  pane (`TMUX` is set) while `record_tmux` is `no`;
- it is not interactive, or its input or output is not a terminal;
- its terminal is recorded already: by tlogger, as for a nested shell or an `exec zsh` in a
  recorded shell, or by another `script` process. The shell inside a recording is such a shell,
  so a terminal never runs two recordings at once.

Nor does a shell that a recorder started but whose recording handshake failed, as under a
`script` binary run by another name: it shows the yellow handshake warning instead, since a
recording there would nest one recorder in another.

### tlogger start and stop

`tlogger start` records the terminal it runs in, in either mode. `tlogger stop` in the recorded
shell ends the recording and returns to the shell where `tlogger start` ran, which is not
recorded, with the paused notice. `exit` ends the recording as well, and returns there too:
`tlogger start` never closes a terminal. It resumes after a pause, in a new session.

`tlogger stop` works only in the shell that the recording started, also after `exec zsh` there,
and not while that shell has running or suspended jobs; in a nested shell or a subshell it says
what to do instead.

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

- `auto` records every new terminal as its shell starts, as [Auto mode](#auto-mode) describes.
- `manual` records only on `tlogger start`.

`tlogger mode` prints the mode in the config, and `manual` when the config names none.
`tlogger mode auto` and `tlogger mode manual` set it for the terminals opened afterwards. They
change only the `mode=` line, or add one, and keep every other byte of the config, which they
write with mode 0600 through a temp file that replaces it in one rename. `tlogger mode auto` first
runs the smoke test that `install` runs, and leaves the config as it is when the test fails; so
does a config that `install` would refuse.

`~/.config/tlogger/config` holds `key=value` lines and `#` comments; tlogger reads it as data and
never runs it.

| Key | Values | Default |
|---|---|---|
| `mode` | `auto` or `manual` | `manual` |
| `logdir` | An absolute path | `~/.local/state/tlogger/sessions` |
| `record_input` | `yes`, or `no` to write no `input.raw` | `yes` |
| `min_free_mb` | The free space in MB that a recording needs in the log folder | `200` |
| `record_ssh` | `yes`, or `no` so that an SSH login does not record itself in auto mode | `yes` |
| `record_tmux` | `yes`, or `no` so that a tmux pane does not record itself in auto mode | `yes` |

An exported `TLOGGER_<KEY>` variable, such as `TLOGGER_LOGDIR=/home/kali/evidence`, wins over the
file in the shell that has it and in the shells that shell starts. An invalid value gets its
default and one warning. The config also takes `recorder`, the path of the `script` binary, which
exists for the tests.

These variables give a terminal profile a policy of its own: set them in the environment that the
profile, or the launcher that opens it, gives the shell. `TLOGGER_MODE=manual` makes the
terminals of that profile record only on request, `TLOGGER_RECORD_SSH=no` and
`TLOGGER_RECORD_TMUX=no` act as the keys do, and `TLOGGER_DISABLE=1` keeps them from recording at
all. In a terminal where `TLOGGER_MODE` is set, `tlogger mode` notes that it wins over the config
there.

### Kill switches and refusals

`TLOGGER_DISABLE=1` in the environment, or a file named `disable` in `~/.config/tlogger`, stops
`tlogger start` and, in auto mode, the recording of each new terminal, which then shows the red
notice below as it opens. Before it records, a recording also checks that nothing records the
terminal already, that `/usr/bin/script` is util-linux 2.35 or newer, that the log folder is a
folder of yours, not a symlink, that you can write in (a missing one is created with mode 0700),
that its group and other users cannot write in it unless its sticky bit is set, and that it has
at least `min_free_mb` MB and 100 inodes free. It also refuses when the new session folder or its
files do not keep their private modes, as on a file system without POSIX modes such as vfat. When
a check fails, it prints a red `tlogger: NOT recording this terminal: <reason>`, records nothing
and leaves the shell as it was. A recording that fails to start, or ends without `exit`, Ctrl+D
or `tlogger stop`, for example because the `script` process was killed, gets a red or yellow
notice too. In auto mode the terminal then stays open, and the rest of the rc loads.

> **Warning:** the session folders hold secrets in cleartext: every password typed in a recorded
> terminal, and every key, token or hash it showed. Keep the log folder on encrypted storage, such
> as a LUKS volume, with its private permissions. A recording creates a missing log folder, so
> mount that volume before you open a terminal, in auto mode above all: while it is not mounted,
> the logs can land unencrypted on the disk beneath its mount point.

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
