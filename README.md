# terminal-logger

A recorder for zsh terminal sessions on Kali Linux, keystrokes included, as evidence for
penetration tests.

> **Status:** phase 5. In auto mode every new zsh terminal records itself as its shell starts; in
> manual mode `tlogger start` records a terminal on request. `tlogger stop` pauses the recording,
> and `tlogger mode` switches between the modes. A recorded shell journals each command with its
> start time in UTC, and the prompt shows whether the terminal is recorded. `tlogger render`,
> `show` and `replay` turn a session into a plain-text transcript, page it and replay it.
> `tlogger install`, `uninstall` and `status` put the plugin in place and take it out again.
> [CONTRIBUTING.md](CONTRIBUTING.md) describes the workflow, and [CHANGELOG.md](CHANGELOG.md)
> lists what changed.

## What it will do

The finished `tlogger` command:

- records every new terminal with util-linux `script`: keystrokes and screen output, with timing
  (`--log-in`, `--log-out`, `--log-timing`, advanced format); this version does so in auto mode,
  and records on request in manual mode, as [Recording](#recording) describes;
- captures passwords typed at hidden prompts, and everything inside reverse shells, unstable
  shells and subshells, because `script` wraps the outer terminal;
- keeps a journal of the commands typed in a recorded terminal, with the start time of each in
  UTC, and stamps each command in the recording, as
  [Command journal and prompt segment](#command-journal-and-prompt-segment) describes;
- shows `REC`, `NOREC` or `EXT` in a segment of Kali's own prompt;
- replays a session with `scriptreplay`, through a filter that drops the escape sequences a
  target could abuse, and renders it as a plain-text transcript offline with `python3-pyte`,
  with no tmux anywhere; this version does both, as [Viewing a session](#viewing-a-session)
  describes;
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
| 3 | Not installed, nothing to remove, or no session to view |

## Recording

In a zsh terminal with the plugin loaded:

| Command | What it does |
|---|---|
| `tlogger start` | Records this terminal: runs util-linux `script` in the foreground with a new zsh inside it |
| `tlogger stop` | Pauses: ends the recording and returns to the shell that started it |
| `tlogger status` | Shows this terminal's state and session, the plugin version, the mode, the log folder, `record_input`, `prompt`, `stamp` and the VPN list (`none` without VPN interfaces, `off` with `stamp_vpn=off`) |
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
| `commands.tsv` | The journal: each command typed in the recorded shell and its nested shells, with its start and end, exit status, folder and VPN list |
| `recorder`, `started`, `exited`, `stop-requested` | Markers: which `script` process recorded, and how the recording began and ended |
| `transcript.txt` | Once `tlogger render` or `tlogger show` has made it: the plain-text transcript, derived from `output.raw` and `timing`, as [Viewing a session](#viewing-a-session) describes |

The log folder is `~/.local/state/tlogger/sessions` unless the config names another one. The
header of `output.raw`, the timing file, the journal, the stamps and the prompt segment use UTC;
the recorded shell keeps your own time zone.

### Command journal and prompt segment

The journal, `commands.tsv`, holds one line per event, with its fields separated by tabs:

| Line | Fields |
|---|---|
| `S` | `S`, the start in seconds since 1970, the same time in UTC (`2026-11-11T10:00:00Z`), the shell's pid, its working folder, the VPN list or `-`, and the command as typed |
| `E` | `E`, the end in seconds since 1970, the shell's pid and the command's exit status |

```text
S	1794391200	2026-11-11T10:00:00Z	4242	/home/kali	tun0 192.0.2.10	'nmap -sV 192.0.2.20'
E	1794391260	4242	0
```

The S line is written as a command starts and its E line before the next prompt, so a command
that ends its shell, such as `exit`, has none. The folder and the command are quoted as zsh's
`(q+)` flag quotes a word: plain text as it is, text with spaces or special characters in single
quotes, and text with a tab, a newline or another control character in the `$'...'` form, so that
every line holds one event. Nested shells write their own lines, with their own pid. A shell that
is not recorded writes nothing.

As each command starts, the recorded shell also prints a dim stamp, which `output.raw` keeps
with the rest of the screen:

```text
-- 2026-11-11T10:00:00Z tun0 192.0.2.10 REC
```

With `NO_COLOR` set to a non-empty value, the stamp is plain; `stamp=off` leaves it out.

Every shell where the plugin loaded shows a segment in its prompt, `[<UTC time> <VPN list>
<state>]`, which it builds again before each prompt:

```text
┌──(kali㉿kali)-[~] [2026-11-11T10:00:00Z tun0 192.0.2.10 REC]
└─$
```

- `REC`: tlogger records this terminal; `NOREC`: nothing records it; `EXT`: another `script`
  process records it.
- In a prompt of more than one line, such as Kali's two-line one, a space and the segment end the
  first line; a one-line prompt gets the segment and a space in front. Kali's prompt and its
  `precmd()` stay as they are, and so do the shell's options, unless `history_timestamps=yes`:
  the plugin adds its hooks with `add-zsh-hook`, which run after Kali's `precmd()`, takes out the
  segment it added last time and puts in the new one. It never touches `RPROMPT`, `PROMPT_CR` or
  `PROMPT_SP`. Ctrl+P, which switches Kali's prompt between one and two lines, builds a prompt
  without the segment; the segment is back from the next prompt on.
- `prompt=off` leaves the prompt alone.
- `TLOGGER_SEGMENT` holds the plain segment, exported, for prompt frameworks that build their own
  prompt, such as powerlevel10k or starship: show it from a segment of the framework's own and
  set `prompt=off`.
- The plugin takes out only the exact text it added last time. A prompt that something saves
  with a segment in it and puts back later, as a Python venv's `activate` and `deactivate` do in
  a prompt other than Kali's colour one, keeps that old segment, with its old time and state,
  beside the new one until the prompt is set again. `prompt=off` avoids it.
- The segment goes before the first line break of `PROMPT`, even when that line break lies inside
  `$(...)`, `${...}` or `%(...)`, where the segment would become part of that code. With such a
  prompt, set `prompt=off` and show `TLOGGER_SEGMENT` instead.

The VPN list names each interface under `/sys/class/net` whose name matches a `vpn_ifaces`
pattern, `tun* wg* tap*` by default, in name order, with its IPv4 address, or its first IPv6
address when it has none, as `ip -o addr show` reports it: `tun0 192.0.2.10 wg0 198.51.100.7`.
Without `ip`, which the plugin takes from `/usr/sbin/ip`, `/sbin/ip` or `/usr/bin/ip` and never
from PATH, it holds the names alone. Only names of letters, digits, `_`, `.`, `:` and `-`, at most
15 characters long, count. The list is kept, and `ip` runs again when the VPN interfaces change
or a minute has passed. While `ip` shows a VPN interface without an address, as `tun0` can be when
`openvpn` gives it its address after the prompt has come back, it runs again 5 seconds later
instead of a minute, and no sooner, so that the address shows soon without a run at every
prompt. An address that changes while its interface stays, as on a reconnect that keeps the
tunnel, shows from the next run of `ip` on: for up to a minute, the list can show the old
address.

> **Note:** the evidence holds the stamp lines and the VPN addresses. The stamps and the prompt
> segments in `output.raw` and the S lines in `commands.tsv` name the addresses, and so does a
> screenshot of the prompt. `stamp_vpn=off` keeps the addresses out of all of them, and
> `tlogger status` then shows `vpn: off`; `stamp=off` keeps the stamp lines out.

None of this slows the prompt noticeably: the hooks start no process for a command. `ip` runs only
at the rate above, and `df` at most every five minutes, to check the free space of the session's
file system: below `min_free_mb` the recorded shell warns in yellow, at most every five minutes,
and records on:

```text
tlogger: warning: less than 200 MB free in ~/.local/state/tlogger/sessions; the recording goes on
```

With `history_timestamps=yes`, the plugin also turns on zsh's `extended_history`, in every shell
where it loads, so that the history file keeps the start time and the duration of each command.
It is the only option tlogger ever sets.

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
| `prompt` | `on`, or `off` for no segment in the prompt | `on` |
| `stamp` | `on`, or `off` for no stamp as each recorded command starts | `on` |
| `stamp_vpn` | `on`, or `off` to keep the VPN list out of the stamps, the segment, the journal and `tlogger status` | `on` |
| `vpn_ifaces` | The patterns of the VPN interface names, separated by spaces or commas, each of letters, digits, `_`, `.`, `-` and the wildcard `*` | `tun* wg* tap*` |
| `history_timestamps` | `yes` to turn on zsh's `extended_history`, which keeps the start time of each command in the history file | `no` |

An exported `TLOGGER_<KEY>` variable, such as `TLOGGER_LOGDIR=/home/kali/evidence` or
`TLOGGER_PROMPT=off`, wins over the file in the shell that has it and in the shells that shell
starts. An invalid value gets its default and one warning. The config also takes `recorder`, the
path of the `script` binary, which exists for the tests.

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

## Viewing a session

`output.raw` with `timing` is the evidence: what the terminal showed, and when. tlogger never
writes, moves or renames them. Three commands read them:

| Command | What it does |
|---|---|
| `tlogger render [--stdout] [SESSION]` | Writes the plain-text transcript of the session to `transcript.txt` in its folder and names it, as in `tlogger: transcript ~/.local/state/tlogger/sessions/20261104T101500Z-a1B2c3/transcript.txt`; `--stdout` prints the transcript instead and writes nothing |
| `tlogger show [SESSION]` | Pages the transcript with `less`, after rendering it when `transcript.txt` is missing, older than the logs, or not what `render` writes (see below); without a terminal on stdout, prints it |
| `tlogger replay [--speed N] [--maxdelay S] [SESSION]` | Replays the session in this terminal at its recorded pace with util-linux `scriptreplay`, through a filter; `--speed 2` replays twice as fast and `--speed 0.5` at half the pace, and `--maxdelay 1` waits at most a second between two outputs. Space pauses, Up and Down change the speed, and Ctrl+C stops |

`SESSION` is a session id, which names a folder in the log folder, such as
`20261104T101500Z-a1B2c3`; or a path to a session folder anywhere, by any name, which holds a
`/`, such as `./20261104T101500Z-a1B2c3` or `/media/evidence/case-1`; or nothing, for the newest
session in the log folder. A session folder must be a real folder of yours, not a symlink, with
`output.raw` and `timing` as regular files of yours. Without a log folder or a session in it, the
commands exit 3; with a `SESSION` they cannot use, 1.

`render` and `show` need `python3` and `python3-pyte` (`sudo apt install python3-pyte`), and
`replay` needs `python3` and `scriptreplay`, which Kali installs by default. tlogger runs
`/usr/bin/python3 -I`, so that neither the environment, your user site nor the working folder
changes what runs.

### The transcript

The transcript is derived, and its first line says so: it names the session, the tlogger version
and when it was rendered.

```text
# DERIVED transcript of session 20261104T101500Z-a1B2c3; the evidence is output.raw with timing. tlogger 0.1.0-dev, rendered 2026-11-04T11:00:00Z
```

`render` plays the output through `pyte`, a terminal emulator, at the size the recording had,
resizes included, and writes out each line as it leaves the screen: lines that scroll off the
top, the screen that `clear`, `tput clear` or `reset` erases, and at the end the screen as it
was left. So the transcript holds what the screen showed, not the steps that drew it: a progress
line that rewrites itself leaves its last state, and a line that the line editor redrew, or a
paste erased before Enter, leaves what remained. A line that wrapped at the edge of the screen
comes back as one line, unless the wrap fell on a space. A full-screen program on the alternate
screen, such as `vim`, `less` or `htop`, leaves one line in its place, and the screen before it
comes back as it was:

```text
[full-screen program: 24x80, not kept here; replay shows it]
```

When `output.raw` ends before its timing does, holds more output than its timing covers (past
the closing line that `script` writes), or the timing file holds malformed lines, `render`
warns on stderr and ends the transcript with a note line, such as
`[3 malformed timing lines skipped]` or
`[output.raw holds more output than its timing covers; the transcript stops here]`, so that a
transcript with output missing does not look complete. Combining marks join a character until it
holds 8 code points; the rest of a longer run of marks is dropped, so that such a run cannot slow
the render down.

The transcript holds no escape sequences: colours, titles and the other control sequences are
gone, and each control character left in the text, like each byte that is not UTF-8, shows as
`�` (U+FFFD). OSC, DCS, SOS, PM and APC strings leave no text, however long, as on a terminal;
a control sequence over 4096 bytes is dropped whole. It holds nothing that was typed but not
shown either: **passwords typed at hidden prompts are not in the transcript, but they are in
`input.raw`**.

`transcript.txt` has mode 0600. `render` writes a new `transcript.txt.part` and renames it over
`transcript.txt` once it is complete, so a render cut short leaves the old transcript as it was.
A `transcript.txt.part` that is already there is what a render that did not finish left: render
refuses to go on until you remove it. It also refuses a `transcript.txt` that is a symlink or not
a regular file. `render` reads the logs a part at a time and keeps only the screen, so a long
session takes time but no more memory; Ctrl+C stops it. A stream full of escape sequences renders
slowly. A target that switches to the alternate screen and never switches back hides the rest of
the session from the transcript, though not from `replay`; the marker line shows where.

`show` runs `less` in its secure mode, with `LESSSECURE=1`, without `-R` and without `LESS`,
`LESSOPEN` and `LESSCLOSE`, so that no input preprocessor runs. It prints or pages an existing
`transcript.txt` as it is only when the file is newer than the logs, starts with the header line
that `render` writes for this session and holds no control byte but LF and HT (no NUL or other
C0 byte, no DEL, no C1 control in UTF-8). Any other file, such as one that someone put into the
session folder, is rendered again.

### Replay and its filter

A target can print anything, escape sequences included, and `output.raw` keeps them as they came.
Sent to a terminal as they are, some make the terminal answer as if you had typed the answer: a
request for the title, the size or the cursor position puts the reply into the input of the shell
you replay in. Others set the clipboard (OSC 52), change the title, switch on mouse or
bracketed-paste reporting, or change what the keypad sends. `tlogger replay` therefore sends the
output through a filter that passes only what draws the screen: text, cursor movement, erasing,
inserting and deleting, scroll regions, colours and attributes, the alternate screen and the DEC
line graphics. It drops the rest: OSC, DCS, SOS, PM and APC strings (up to their end, however
long, as a terminal shows none of their text), requests and reports, window operations, the
mouse, focus, bracketed-paste and keypad modes, resets, every C1 control, and `CSI 3 J`, which
would erase the scrollback of the terminal you replay in. It passes `CSI S` and
`CSI T` (scroll) with one number or none only: with five parameters, `CSI T` is xterm's
highlight mouse tracking, which makes a terminal wait for a mouse report. When the replay ends,
or Ctrl+C or Ctrl+\ stops it, the filter puts back the colours, the cursor, the scroll region and
the normal screen, and turns mouse, focus and bracketed-paste reporting off. The filter writes
UTF-8 and expects a UTF-8 terminal, as Kali's terminals are: a terminal set to an 8-bit character
set such as Latin-1 can read bytes inside UTF-8 characters as C1 controls.

`scriptreplay` reads a copy of the timing file, in a private temp folder, without its header
lines: under a locale such as `de_DE`, `script` writes their delays with a comma, and
`scriptreplay` stops at the first one. Lines it would stop at, such as an `O`, `I` or `S` line
with more than six fraction digits, are left out too, with a warning.

> **Warning:** never replay these logs with `scriptlive`: it runs the recorded input again, every
> command of the session, in a new shell. Do not `cat` `output.raw` to a terminal either, which
> sends the target's escape sequences to it unfiltered; use `tlogger replay` or `tlogger show`.

## Security

The logs hold everything typed and shown in a recorded terminal, passwords included.

- Keep the log folder on encrypted storage, such as a LUKS volume, with private permissions.
- Record only systems and engagements you are authorized to test. Keep and destroy the logs
  under the engagement's rules.
- Treat what a target printed as hostile: view a session with `tlogger show` or
  `tlogger replay`, which filter it, and never with `scriptlive`, which runs the recorded input
  again.

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
zsh, util-linux `script` or `scriptreplay`, `python3` or `python3-pyte`, the Linux `/proc`,
symlinks, POSIX file modes, hard links, mawk or gawk skip on a machine without them, and the tests
tagged `root` skip unless run as root. The end-to-end tests record real sessions in a
pseudo-terminal that zsh's `zpty` module drives, and render and replay one of them. CI runs the
whole suite on Kali Linux in a container, with ShellCheck 0.11.0, and fails when any test is
skipped. [CONTRIBUTING.md](CONTRIBUTING.md) tells how to run the suite as CI does.

## Licence

MIT, see [LICENSE](LICENSE).
