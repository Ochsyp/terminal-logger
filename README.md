# terminal-logger

A planned recorder for zsh terminal sessions on Kali Linux, keystrokes included, as evidence for
penetration tests.

> **Status:** phase 1. `tlogger install`, `uninstall` and `status` exist, so the plugin can be put
> in place and taken out again, but nothing is recorded yet. [CONTRIBUTING.md](CONTRIBUTING.md)
> describes the workflow, and [CHANGELOG.md](CHANGELOG.md) lists what changed.

## What it will do

The planned `tlogger` command:

- records every new terminal with util-linux `script`: keystrokes and screen output, with timing
  (`--log-in`, `--log-out`, `--log-timing`, advanced format);
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
terminal, pass `--mode` and `--yes`. Once recording exists, `--mode auto` records every new
terminal and `--mode manual` only on request; this version records nothing in either mode.

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

In a new terminal, `tlogger status` names the plugin version and says that the terminal is not
recorded.

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
zsh, symlinks, POSIX file modes, hard links, mawk or gawk skip on a machine without them, and the
tests tagged `root` skip unless run as root. CI runs the whole suite on Kali Linux in a container,
with ShellCheck 0.11.0, and fails when any test is skipped. [CONTRIBUTING.md](CONTRIBUTING.md)
tells how to run the suite as CI does.

## Licence

MIT, see [LICENSE](LICENSE).
