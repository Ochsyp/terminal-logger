# Guide: an engagement with terminal-logger

This guide walks through one penetration test from start to end. The [README](../README.md) is the
reference for every command, setting and message.

## Before the engagement

**Where the logs go.** A recording holds everything typed and shown, passwords at hidden prompts
included. So keep the log folder on encrypted storage, readable by you only. By default it is
`~/.local/state/tlogger/sessions`, and the config can name another folder, such as one on a LUKS
volume. Mount that volume before you open the first terminal of the day.

**Install, as the user whose terminals you record, not as root.** Download a release into an
empty folder, with no login, and check it before you unpack it. Then install from the folder:

```bash
curl -fLO https://github.com/Ochsyp/terminal-logger/releases/download/vX.Y.Z/terminal-logger-X.Y.Z.tar.gz
curl -fLO https://github.com/Ochsyp/terminal-logger/releases/download/vX.Y.Z/SHA256SUMS
sha256sum -c SHA256SUMS
tar -xzf terminal-logger-X.Y.Z.tar.gz
cd terminal-logger-X.Y.Z
./bin/tlogger install --mode auto
```

`sha256sum -c` must print `OK`. Signed in to the GitHub CLI, you can also run
`gh attestation verify terminal-logger-X.Y.Z.tar.gz --repo Ochsyp/terminal-logger` before you
unpack, which proves where the archive was built; the README's Install section says more.

`--mode auto` records every new terminal as its shell starts, which suits an engagement: no
terminal is forgotten. `--mode manual` records only after `tlogger start`. Add `--dry-run` to see
the plan and the change to your `.zshrc` without writing anything.

**Check it.** Open a new terminal. It prints `tlogger: recording session <id>`, and the prompt
shows `REC`. `tlogger status` names the state, the session, the mode and the log folder.

## During the engagement

**Work as usual.** Each new terminal is its own session, a folder named after the UTC time it
started. Everything inside it is recorded: `sudo`, `ssh`, nested shells, reverse shells and
programs that take over the screen. The journal `commands.tsv` notes each command with its start
time in UTC, its folder and its exit status, and the prompt shows the UTC time.

**Pause for anything private.** `tlogger stop` ends the recording, and the prompt shows `NOREC`.
`tlogger start` records again, in a new session. Nothing typed while the terminal is paused
reaches the logs.

**Watch the prompt.** `REC` means this terminal is recorded, `NOREC` that it is not, and `EXT`
that another recorder records it. When a recording cannot start, the terminal says why in red
and stays usable. Fix the cause, or record by hand with `tlogger start`.

## After the engagement

**Look at a session.** The session id is the folder name under the log folder. Leave it out to
use the newest session.

- `tlogger render <id>` writes `transcript.txt`, a plain-text transcript, into the session's
  folder.
- `tlogger show <id>` pages that transcript, and renders it first when needed.
- `tlogger replay <id>` plays the session back at its recorded pace. Space pauses, Up and Down
  change the speed, Ctrl+C stops and Ctrl+Z suspends it until `fg`. `--speed 2` plays it twice
  as fast, and `--maxdelay 1` shortens every pause to at most a second.

**Keep the evidence.** `output.raw` with `timing` and `input.raw`, and `commands.tsv`, are the
evidence. The transcript is derived from them, and its first line says so. Do not edit the
logs. Copy the session folders to the engagement's encrypted archive. Never put a log into a
repository, a ticket or an unencrypted report: it holds every password typed.

**Remove the recorder when you are done.** `tlogger uninstall` takes the block out of your
`.zshrc` and removes the plugin. Your logs and the backups of your `.zshrc` stay.
