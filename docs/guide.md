# Guide: an engagement with terminal-logger

This guide walks through one penetration test from start to end. The [README](../README.md) is the
reference for every command, setting and message.

## Before the engagement

**Where the logs go.** A recording holds everything typed and shown, passwords at hidden prompts
included. So keep the log folder on encrypted storage, readable by you only. By default it is
`~/.local/state/tlogger/sessions`, and the config can name another folder, such as one on a LUKS
volume. Mount that volume before you open the first terminal of the day.

**Install, as the user whose terminals you record, not as root.** Download a release into an
empty folder, with no login, and check it before you unpack it; take only a release that the
releases page does not mark as a pre-release. Then install from the folder:

```bash
curl -fLO https://github.com/Ochsyp/terminal-logger/releases/download/vX.Y.Z/terminal-logger-X.Y.Z.tar.gz
curl -fLO https://github.com/Ochsyp/terminal-logger/releases/download/vX.Y.Z/SHA256SUMS
sha256sum -c SHA256SUMS
tar -xzOf terminal-logger-X.Y.Z.tar.gz terminal-logger-X.Y.Z/terminal-logger-release.json | grep '"commit"'
tar -xzf terminal-logger-X.Y.Z.tar.gz
cd terminal-logger-X.Y.Z
./bin/tlogger install --mode auto
```

`sha256sum -c` must print `OK`, and the manifest line names the commit the archive was built
from. Signed in to the GitHub CLI, you can also run
`gh attestation verify terminal-logger-X.Y.Z.tar.gz --repo Ochsyp/terminal-logger` before `tar`,
which proves where the archive was built; the README's Install section says more.

`--mode auto` records every new terminal as its shell starts, which suits an engagement: no
terminal is forgotten. `--mode manual` records only after `tlogger start`. Add `--dry-run` to see
the plan and the change to your `.zshrc` without writing anything.

**Check it.** Open a new terminal. It prints `tlogger: recording session <id>` in green, and the
prompt shows `[REC]` in green. `tlogger status` names the state, the session, the mode, the log
folder and the engagement.

**Check the log folder.** Run `tlogger doctor`. It checks whether the log folder lies on encrypted
storage that keeps Unix permissions, whether the folder is private, and whether its volume is
mounted. It changes nothing. Each line says `ok`, `warn` with what to do, or `unknown` with what
to check by hand. It ends with `No warnings. Nothing was changed.` when every check is `ok`.

**Guard the volume.** When the logs live on a volume of their own, such as a LUKS volume mounted
at `/srv/work`, name its mount point in `~/.config/tlogger/config` beside the log folder:

```text
logdir=/srv/work/tlogger
logdir_mount=/srv/work
```

A recording then refuses, in red, while that volume is not mounted, and the terminal stays
usable: mount the volume, then run `tlogger start` or open a new terminal. Without that line,
the logs could land unencrypted on the disk beneath the mount point. `tlogger doctor` prints the
`logdir_mount=` line to add when it finds such a volume; under your home folder that line shows
`~`, which you write out as the full path. If the path runs through a symlink, write the real
path.

**Name the engagement.** Before you open the first terminal of the job, run
`tlogger engagement acme`, with the name of the job in place of `acme`. Its sessions then go into
a folder of their own in the log folder, with their own `MANIFEST`. A name has letters, digits,
`.`, `_` and `-`, and starts with a letter or a digit. A terminal that records already keeps its
session where it started, so open a new one. Run `tlogger doctor` again: it checks the engagement
folder too.

## During the engagement

**Work as usual.** Each new terminal is its own session, a folder named after the UTC time it
started. Everything inside it is recorded: `sudo`, `ssh`, nested shells, reverse shells and
programs that take over the screen. The journal `commands.tsv` notes each command with its start
time in UTC, its folder and its exit status, and the prompt shows the UTC time and the VPN
address. Each command's start time also goes into the recording itself, without showing on the
screen, and appears as a stamp line in the transcript.

**Pause for anything private.** `tlogger stop` ends the recording, and the prompt shows `NOREC`.
`tlogger start` records again, in a new session. Nothing typed while the terminal is paused
reaches the logs.

**Watch the prompt.** `REC` in green means this terminal is recorded, `NOREC` in red that it is
not, and `EXT` in cyan that another recorder records it. When a recording cannot start, the
terminal says why in red and stays usable. Fix the cause, or record by hand with `tlogger start`.

## After the engagement

**Look at a session.** The session id is the folder name in the log folder, or in the
engagement folder. Leave it out to use the newest session.

- `tlogger render <id>` writes `transcript.txt`, a plain-text transcript, into the session's
  folder.
- `tlogger show <id>` pages that transcript, and renders it first when needed.
- `tlogger replay <id>` plays the session back at its recorded pace. Space pauses, Up and Down
  change the speed, Ctrl+C stops and Ctrl+Z suspends it until `fg`. `--speed 2` plays it twice
  as fast, and `--maxdelay 1` shortens every pause to at most a second.

**Check the seals.** Each session was sealed as its recording ended, and the terminal printed
its sum. `tlogger list` shows every session and its state. `tlogger seal --all` seals the ones
that ended unexpectedly, and `tlogger verify --all` checks every sealed session; it must print
`ok` for each. Keep a copy of `MANIFEST` from the engagement folder, or the sums the terminal
printed, with the engagement's records, apart from the logs: only that copy shows a later change.
Sessions recorded without an engagement have their lines in the `MANIFEST` of the log folder.

**Keep the evidence.** `output.raw` with `timing` and `input.raw`, and `commands.tsv`, are the
evidence. The transcript is derived from them, and its first line says so. Do not edit the
logs; once sealed, they are read-only. Copy the engagement folder as a whole, with its
`MANIFEST`, to the engagement's encrypted archive. Do not move a session into another folder:
`verify` then says `changed` for it, since no `MANIFEST` line there names it, until you move it
back or run `tlogger seal <id>`, which adds the line while its seal still matches. Never put a log
into a repository, a ticket or an unencrypted report: it holds every password typed.

**Close the engagement.** `tlogger engagement --none` sends the next sessions to the log folder
again, or `tlogger engagement` with the next job's name to that job's folder.

**Remove the recorder when you are done.** `tlogger uninstall` takes the block out of your
`.zshrc` and removes the plugin. Your logs and the backups of your `.zshrc` stay.
