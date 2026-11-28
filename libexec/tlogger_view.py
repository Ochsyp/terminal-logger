# tlogger_view.py: the Python part of tlogger render, show and replay. render turns a session's
# output.raw and timing into a plain-text transcript through a pyte screen; for replay, filter
# keeps only an allow-list of terminal output and replay-timing cleans the timing for scriptreplay.
# For tlogger archive, archive-write packs sealed sessions into a .tar.gz and archive-check checks
# one; prune-check checks one for tlogger prune and lists the sums of its sessions. bin/tlogger
# runs it as '/usr/bin/python3 -I tlogger_view.py <command>'; stdlib and pyte only.

import bisect
import codecs
import copy
import errno
import gzip
import hashlib
import io
import os
import re
import secrets
import select
import signal
import stat
import sys
import tarfile
import time
import unicodedata
import zlib

USAGE = """\
usage: tlogger_view.py probe [--pyte]
       tlogger_view.py render --version VERSION [--stdout] [--] SESSION_FOLDER
       tlogger_view.py replay-timing < TIMING
       tlogger_view.py filter [--suspend SETTINGS]
       tlogger_view.py archive-write --name NAME --out FILE [--] FOLDER ID...
       tlogger_view.py archive-check [--logdir LOGDIR] [--] FILE
       tlogger_view.py prune-check --name NAME --folder FOLDER [--logdir LOGDIR] [--] FILE
"""

# A tlogger version, as bin/tlogger's VERSION_RE takes it.
_VERSION_RE = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?")


class Failure(Exception):
    """An error with a message for the user; main prints it after 'tlogger: ' and exits 1."""


class UsageError(Exception):
    """A wrong command line; main prints it and the usage on stderr and exits 2."""


class Stop(BaseException):
    """Raised by the signal handler; main exits with 128 plus the signal number.

    It derives from BaseException, so that no 'except Exception', such as the one around the
    import of pyte, can turn a signal into an error message.
    """

    def __init__(self, signum):
        super().__init__(signum)
        self.signum = signum


# The signals that stop a command through Stop, those of them that the system has: Windows has
# neither SIGHUP nor SIGQUIT.
_SIGHUP = getattr(signal, "SIGHUP", None)
_STOP_SIGNALS = tuple(getattr(signal, name)
                      for name in ("SIGHUP", "SIGINT", "SIGQUIT", "SIGTERM")
                      if hasattr(signal, name))


_stopping = False  # True once a signal has raised Stop


def _on_signal(signum, frame):
    """Turn the first signal of _STOP_SIGNALS into Stop, so that every command cleans up on its
    way out. Later ones return, so that none cuts that cleanup short; the first sets the status.
    """
    global _stopping
    if _stopping:
        return
    _stopping = True
    raise Stop(signum)


def _catch_signals():
    """Make each signal of _STOP_SIGNALS raise Stop.

    A SIGHUP that is ignored already, as under nohup, stays ignored; the others are caught even
    then, as in a background job of a script, which ignores SIGINT and SIGQUIT.
    """
    global _stopping
    _stopping = False
    for signum in _STOP_SIGNALS:
        if signum != _SIGHUP or signal.getsignal(signum) != signal.SIG_IGN:
            signal.signal(signum, _on_signal)


def _ignore_signals():
    """Ignore the signals of _STOP_SIGNALS from now on, so that none cuts a cleanup short."""
    for signum in _STOP_SIGNALS:
        signal.signal(signum, signal.SIG_IGN)


# Characters that never reach the transcript or a message: C0 controls but tab, DEL, C1 controls
# and lone surrogates. Each becomes U+FFFD, so that no ESC gets through.
_UNSAFE = re.compile("[\x00-\x08\x0a-\x1f\x7f-\x9f\ud800-\udfff]")


def _clean(line):
    """Return LINE without its trailing spaces and with every unsafe character as U+FFFD."""
    return _UNSAFE.sub("�", line.rstrip(" "))


def _say(message):
    """Print 'tlogger: MESSAGE' on stderr, unsafe characters replaced."""
    sys.stderr.write("tlogger: %s\n" % _clean(message))
    sys.stderr.flush()


class Sink:
    """Collect bytes for the file descriptor fd and write them out with os.write.

    Bytes go out once 64 KiB have collected, and on flush. A partial write is continued, and a
    descriptor that another process has made non-blocking is waited on with select.
    """

    def __init__(self, fd, limit=65536):
        self.fd = fd
        self.limit = limit
        self.buf = bytearray()

    def write(self, data):
        """Add DATA; write out what has collected once it reaches the limit."""
        self.buf += data
        if len(self.buf) >= self.limit:
            self.flush()

    def flush(self):
        """Write out everything collected. Raises OSError as os.write does, EAGAIN aside."""
        while self.buf:
            try:
                done = os.write(self.fd, self.buf)
            except BlockingIOError:
                select.select([], [self.fd], [])
                continue
            del self.buf[:done]


# ---------------------------------------------------------------------------------------------
# Tokens of terminal output
# ---------------------------------------------------------------------------------------------

# Token kinds: printable text, a C0 control, an escape sequence, a control sequence (CSI) and a
# hidden stamp.
TEXT, CTRL, ESC, CSI, STAMP = range(5)

# A hidden stamp, as the plugin's preexec hook writes it with stamp=hidden: the OSC string
# 'ESC ] 7711 ; tlogger-stamp <UTC> <vpn> ST', which terminals do not show. The tokenizer keeps
# at most _STAMP_MAX characters of an OSC string that starts with _STAMP_PREFIX, and only a
# string that _STAMP matches whole, ended by ST or BEL, becomes a STAMP token.
_STAMP_PREFIX = "7711;tlogger-stamp "
_STAMP = re.compile(
    r"7711;tlogger-stamp ([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)"
    r"((?: [0-9A-Za-z_.:-]{1,45})*)"
)
_STAMP_MAX = 512

# An escape or control sequence that reaches this many bytes, counted from its first byte, stops
# keeping its parameter and intermediate bytes, so that memory stays bounded. It is still read on
# to its end and then dropped whole. Control strings are not counted: they keep nothing.
CAP = 4096

# Tokenizer states: ground, escape, control sequence, control string and an ESC inside a string.
_GROUND, _ESCAPE, _CSI, _STRING, _STRING_ESC = range(5)

# The characters that end a run of text: C0 controls, DEL and C1 controls.
_SPECIAL = re.compile("[\x00-\x1f\x7f-\x9f]")

# The characters that end or break a control string: CAN, SUB, ESC, the C1 string and sequence
# introducers and ST; for OSC also BEL.
_STRING_STOP = re.compile("[\x18\x1a\x1b\x90\x98\x9b-\x9f]")
_OSC_STOP = re.compile("[\x07\x18\x1a\x1b\x90\x98\x9b-\x9f]")


class Tokenizer:
    """Split terminal output, decoded to str, into tokens, keeping its state across feed calls.

    feed returns a list of tokens: (TEXT, run) for printable characters; (CTRL, char) for a C0
    control other than ESC, CAN and SUB; (ESC, intermediates, final); (CSI, parameters,
    intermediates, final, c1), c1 true when U+009B introduced it; and (STAMP, utc, vpn) for a
    hidden stamp, an OSC 7711 string that _STAMP matches whole, vpn "" when it names none. Every
    other OSC, DCS, SOS, PM and APC string, introduced by ESC or by its C1 control and ended by ST
    (ESC \\ or U+009C), BEL for OSC, yields nothing, and so does a stamp that a CAN, a SUB, an
    ESC or a C1 control cuts short. DEL, CAN, SUB, a stray ST and every other C1 control are
    dropped. A C0 control inside a sequence is executed: its token comes before the sequence's,
    as on a DEC terminal. ESC, CAN, SUB, a C1 control or a character above ASCII inside a
    sequence ends it unfinished; such a character is then read again in the ground state. A
    control string is dropped whole, however long, as a terminal shows none of it; the tokenizer
    keeps none of its bytes but the first _STAMP_MAX characters of an OSC string that can still
    be a stamp. A sequence that reaches CAP bytes stops keeping its bytes, is read on to its end
    and is dropped whole, as a malformed one is.
    """

    def __init__(self):
        self.state = _GROUND
        self.size = 0
        self.inter = ""
        self.params = ""
        self.c1 = False
        self.bad = False
        self.osc = False
        # The OSC string read so far while it can still be a hidden stamp, else None.
        self.keep = None

    def _begin(self, state, size, c1=False, osc=False):
        """Start a sequence or string in STATE whose introducer took SIZE bytes."""
        self.state = state
        self.size = size
        self.inter = ""
        self.params = ""
        self.c1 = c1
        self.bad = size >= CAP
        self.osc = osc
        self.keep = "" if osc else None

    def _keep(self, chunk):
        """Add CHUNK of an OSC string to keep, or give it up once it can be no hidden stamp."""
        if self.keep is None:
            return
        keep = self.keep + chunk
        if len(keep) > _STAMP_MAX or not (
            keep.startswith(_STAMP_PREFIX) or _STAMP_PREFIX.startswith(keep)
        ):
            self.keep = None
        else:
            self.keep = keep

    def _end_string(self, out):
        """End the control string properly, by ST or BEL: add its STAMP token, if it is one."""
        if self.keep is not None:
            match = _STAMP.fullmatch(self.keep)
            if match is not None:
                out.append((STAMP, match.group(1), match.group(2).strip()))
        self.keep = None

    def _grow(self, count):
        """Count COUNT more bytes of the sequence; at the cap mark it bad. Returns False."""
        self.size += count
        if self.size >= CAP:
            self.bad = True
        return False

    def _control(self, ch, out):
        """Act on the control CH met in the ground state: start a sequence or add its token."""
        if ch == "\x1b":
            self._begin(_ESCAPE, 1)
        elif ch == "\x9b":
            self._begin(_CSI, 2, c1=True)
        elif ch == "\x9d":
            self._begin(_STRING, 2, osc=True)
        elif ch in "\x90\x98\x9e\x9f":
            self._begin(_STRING, 2)
        elif ch < "\x20" and ch not in "\x18\x1a":
            out.append((CTRL, ch))
        # DEL, CAN, SUB, ST and the other C1 controls are dropped.

    def _interrupt(self, ch, out):
        """Act on CH, which is no part of the escape or control sequence it arrives in.

        Returns True when CH must be read again in the ground state.
        """
        if ch == "\x1b":
            self._begin(_ESCAPE, 1)
            return False
        if ch in "\x18\x1a":
            self.state = _GROUND
            return False
        if ch == "\x7f":
            return False
        if ch < "\x20":
            out.append((CTRL, ch))
            return self._grow(1)
        self.state = _GROUND
        if ch <= "\x9f":
            self._control(ch, out)
            return False
        return True

    def _escape(self, ch, out):
        """Read CH after ESC and its intermediates. Returns True to read CH again."""
        code = ord(ch)
        if 0x20 <= code <= 0x2F:
            # Past the cap keep one intermediate, so that ESC SP [ is not read as CSI.
            if not self.bad or not self.inter:
                self.inter += ch
            return self._grow(1)
        if 0x30 <= code <= 0x7E:
            if not self.inter:
                if ch == "[":
                    self._begin(_CSI, self.size + 1)
                    return False
                if ch == "]":
                    self._begin(_STRING, self.size + 1, osc=True)
                    return False
                if ch in "PX^_":
                    self._begin(_STRING, self.size + 1)
                    return False
            if not self.bad:
                out.append((ESC, self.inter, ch))
            self.state = _GROUND
            return False
        return self._interrupt(ch, out)

    def _csi(self, ch, out):
        """Read CH inside a control sequence. Returns True to read CH again."""
        code = ord(ch)
        if 0x30 <= code <= 0x3F:
            # A parameter byte after an intermediate byte makes the sequence malformed.
            if self.inter:
                self.bad = True
            elif not self.bad:
                self.params += ch
            return self._grow(1)
        if 0x20 <= code <= 0x2F:
            if not self.bad:
                self.inter += ch
            return self._grow(1)
        if 0x40 <= code <= 0x7E:
            if not self.bad:
                out.append((CSI, self.params, self.inter, ch, self.c1))
            self.state = _GROUND
            return False
        return self._interrupt(ch, out)

    def _string(self, text, i, out):
        """Read the control string in TEXT from index I on, keeping none of it but a stamp's.

        Returns the next index to read.
        """
        match = (_OSC_STOP if self.osc else _STRING_STOP).search(text, i)
        if match is None:
            self._keep(text[i:])
            return len(text)
        end = match.start()
        self._keep(text[i:end])
        ch = text[end]
        if ch == "\x1b":
            self.state = _STRING_ESC
            return end + 1
        self.state = _GROUND
        if ch in "\x07\x9c":
            self._end_string(out)
        else:
            self.keep = None
            if ch not in "\x18\x1a":
                # A C1 introducer ends the string unfinished and starts its own sequence.
                self._control(ch, out)
        return end + 1

    def _string_esc(self, ch, out):
        """Read CH after an ESC inside a control string. Returns True to read CH again."""
        if ch == "\\":
            self.state = _GROUND
            self._end_string(out)
            return False
        # Any other character ends the string unfinished; the ESC starts an escape sequence.
        self._begin(_ESCAPE, 1)
        return True

    def feed(self, text):
        """Return the tokens that TEXT completes, keeping an unfinished sequence for later."""
        out = []
        i = 0
        n = len(text)
        while i < n:
            state = self.state
            if state == _GROUND:
                match = _SPECIAL.search(text, i)
                if match is None:
                    out.append((TEXT, text[i:]))
                    break
                j = match.start()
                if j > i:
                    out.append((TEXT, text[i:j]))
                self._control(text[j], out)
                i = j + 1
            elif state == _STRING:
                i = self._string(text, i, out)
            else:
                ch = text[i]
                i += 1
                if state == _ESCAPE:
                    again = self._escape(ch, out)
                elif state == _CSI:
                    again = self._csi(ch, out)
                else:
                    again = self._string_esc(ch, out)
                if again:
                    i -= 1
        return out

    def finish(self):
        """Drop a sequence or string that the input left unfinished."""
        self.state = _GROUND
        self.keep = None


# ---------------------------------------------------------------------------------------------
# The replay filter
# ---------------------------------------------------------------------------------------------

# The final bytes of the control sequences that the filter passes when their parameters are
# plain: digits, ';' and ':', with no private marker and no intermediate byte.
_CSI_FINALS = frozenset("@ABCDEFGHJKLMPSTXdfmrsu`")
_PLAIN_PARAMS = re.compile("[0-9;:]*")

# The modes that the filter lets CSI h and CSI l set and reset: ANSI and DEC private ones.
_MODE_PARAMS = re.compile("(\\?)?([0-9;]*)")
_ANSI_MODES = frozenset([4])
_DEC_MODES = frozenset([7, 12, 25, 47, 1047, 1048, 1049])

# What the filter writes when its input ends or a signal of _STOP_SIGNALS stops it, so that a
# replay cut short leaves the terminal usable.
RESTORE = (
    b"\x1b[?1047l"  # back to the normal screen; unlike 1049, it does not move the cursor
    b"\x1b7\x1b[r\x1b8"  # full scroll region; DECSTBM homes the cursor, so DECSC and DECRC keep it
    b"\x1b(B\x1b)B"  # ASCII in G0 and G1
    b"\x1b[0m"  # SGR 0
    b"\x1b[4l"  # replace mode
    b"\x1b[?7h"  # autowrap on
    b"\x1b[?25h"  # cursor shown
    b"\x1b[?9l\x1b[?1000l\x1b[?1001l\x1b[?1002l\x1b[?1003l"  # mouse reporting off
    b"\x1b[?1005l\x1b[?1006l\x1b[?1015l\x1b[?1016l"  # mouse encodings off
    b"\x1b[?1004l"  # focus reporting off
    b"\x1b[?2004l"  # bracketed paste off
)


def _filter_csi(params, inter, final, c1):
    """Return the control sequence as the filter passes it, or "" when the filter drops it.

    CSI h and CSI l keep only the allowed modes among their parameters, written as plain
    decimal numbers. ED 3 (CSI 3 J) is dropped: it erases the saved lines, the scrollback of
    the terminal that replays, which lies beyond the replayed screen. CSI S and CSI T pass
    with one plain number or none. A sequence that U+009B introduced is dropped, as every C1
    control is.
    """
    if c1 or inter:
        return ""
    if final in _CSI_FINALS:
        if not _PLAIN_PARAMS.fullmatch(params):
            return ""
        if final == "J" and params.split(";", 1)[0].split(":", 1)[0].lstrip("0") == "3":
            return ""
        # SU and SD take one parameter; CSI with five and the final T is xterm's highlight
        # mouse tracking, which makes the terminal wait for a mouse report.
        if final in "ST" and not params.isdigit() and params:
            return ""
        return "\x1b[" + params + final
    if final in ("h", "l"):
        match = _MODE_PARAMS.fullmatch(params)
        if match is None:
            return ""
        private = match.group(1) is not None
        allowed = _DEC_MODES if private else _ANSI_MODES
        kept = []
        for part in match.group(2).split(";"):
            if part and len(part) <= 5 and int(part) in allowed:
                kept.append(str(int(part)))
        if kept:
            return "\x1b[" + ("?" if private else "") + ";".join(kept) + final
    return ""


def filter_tokens(tokens):
    """Return, as one str, what the replay filter passes of TOKENS.

    Passed: text; BS, HT, LF and CR; ESC 7, 8, D, E and M; ESC ( and ESC ) with B or 0; and
    the control sequences that _filter_csi passes. Everything else is dropped, hidden stamps
    included.
    """
    out = []
    for token in tokens:
        kind = token[0]
        if kind == TEXT:
            out.append(token[1])
        elif kind == CTRL:
            if token[1] in "\b\t\n\r":
                out.append(token[1])
        elif kind == ESC:
            inter, final = token[1], token[2]
            if (inter == "" and final in "78DEM") or (inter in ("(", ")") and final in "B0"):
                out.append("\x1b" + inter + final)
        elif kind == CSI:
            out.append(_filter_csi(token[1], token[2], token[3], token[4]))
    return "".join(out)


# The form of stty -g, in which bin/tlogger passes the shell's terminal settings to the filter.
_STTY_SAVED = re.compile(r"[0-9a-fA-F]+(?::[0-9a-fA-F]+)+")


def _job_shell_above():
    """Return True when an ancestor outside this process group is in this session.

    That ancestor is a job-control shell, which can resume a stopped group. Without one the group
    is orphaned, and SIGSTOP would leave it stopped for good. An error counts as no shell.
    """
    group, session = os.getpgrp(), os.getsid(0)
    pid = os.getppid()
    try:
        while pid > 0:
            if os.getpgid(pid) != group:
                return os.getsid(pid) == session
            with open("/proc/%d/stat" % pid, "rb") as stat:
                pid = int(stat.read().rpartition(b")")[2].split()[1])
    except (OSError, ValueError, IndexError):
        pass
    return False


class _Suspend:
    """Act on Ctrl+Z during a replay: restore the terminal, stop the group, carry on after fg.

    bin/tlogger and scriptreplay ignore SIGTSTP, so the shell takes the terminal back only after
    this class has restored it and stopped them all. zsh does not reset the terminal settings of
    a stopped job, so this class puts the shell's back, and the replay's after fg.
    """

    def __init__(self, sink, saved, tty, replay_mode, termios, subprocess):
        self.sink = sink
        self.saved = saved
        self.tty = tty
        self.replay_mode = replay_mode
        self.termios = termios
        self.subprocess = subprocess
        self.writing = False
        self.pending = False
        signal.signal(signal.SIGTSTP, self.on_signal)

    @classmethod
    def start(cls, sink, saved):
        """Return a _Suspend for the controlling terminal, or None when there is none."""
        try:
            import subprocess
            import termios
            tty = os.open("/dev/tty", os.O_RDWR | os.O_NOCTTY)
        except (ImportError, OSError):
            return None
        try:
            return cls(sink, saved, tty, termios.tcgetattr(tty), termios, subprocess)
        except termios.error:
            os.close(tty)
            return None

    def on_signal(self, signum, frame):
        """Stop now, or after the write in progress, so that no sequence is cut in two."""
        if self.writing:
            self.pending = True
        else:
            self.stop()

    def write(self, data):
        """Write DATA out whole, then act on a Ctrl+Z that came during the write."""
        self.writing = True
        self.sink.write(data)
        self.sink.flush()
        self.writing = False
        if self.pending:
            self.stop()

    def foreground(self):
        """Return True while this process group owns the terminal."""
        try:
            return os.tcgetpgrp(self.tty) == os.getpgrp()
        except OSError:
            return False

    def stop(self):
        """Suspend the replay. Does nothing when no job-control shell could resume it.

        bg resumes the group too, so it stops again until it owns the terminal: in the background
        scriptreplay would read keys that belong to the shell.
        """
        signal.signal(signal.SIGTSTP, signal.SIG_IGN)
        self.pending = False
        if self.foreground() and _job_shell_above():
            if os.isatty(1):
                self.sink.write(RESTORE)
                self.sink.flush()
            try:
                self.subprocess.run(["stty", self.saved], stdin=self.tty, check=False,
                                    stdout=self.subprocess.DEVNULL,
                                    stderr=self.subprocess.DEVNULL)
            except OSError:
                pass
            os.kill(0, signal.SIGSTOP)
            while not self.foreground() and _job_shell_above():
                os.kill(0, signal.SIGSTOP)
            if self.foreground():
                try:
                    self.termios.tcsetattr(self.tty, self.termios.TCSANOW, self.replay_mode)
                except self.termios.error:
                    pass
        signal.signal(signal.SIGTSTP, self.on_signal)


def _filter_saved_settings(args):
    """Return the settings that 'filter --suspend SETTINGS' names, or None without arguments."""
    if not args:
        return None
    if args[0] != "--suspend":
        raise UsageError("filter takes no arguments")
    if len(args) != 2 or not _STTY_SAVED.fullmatch(args[1]):
        raise UsageError("filter --suspend takes the terminal settings that stty -g prints")
    return args[1]


def cmd_filter(args):
    """tlogger_view.py filter [--suspend SETTINGS]: copy stdin to stdout through the allow-list,
    then RESTORE.

    Reads and writes unbuffered, with os.read and os.write. Bytes that are not valid UTF-8 are
    dropped, raw C1 bytes among them. RESTORE follows the end of input and each signal of
    _STOP_SIGNALS; Stop then leaves through main with 128 plus the signal number. --suspend
    handles Ctrl+Z as _Suspend says; SETTINGS are the shell's terminal settings, from stty -g.
    """
    saved = _filter_saved_settings(args)
    decoder = codecs.getincrementaldecoder("utf-8")(errors="ignore")
    tokenizer = Tokenizer()
    sink = Sink(1)
    suspend = _Suspend.start(sink, saved) if saved else None

    def emit(data):
        if suspend:
            suspend.write(data)
        else:
            sink.write(data)
            sink.flush()

    try:
        while True:
            data = os.read(0, 65536)
            if not data:
                break
            text = filter_tokens(tokenizer.feed(decoder.decode(data)))
            if text:
                emit(text.encode("utf-8"))
        text = filter_tokens(tokenizer.feed(decoder.decode(b"", True)))
        tokenizer.finish()
        emit(text.encode("utf-8"))
    finally:
        if suspend:
            signal.signal(signal.SIGTSTP, signal.SIG_IGN)
        _ignore_signals()
        # A signal can come after a short write, before flush has dropped what was written. Sent
        # again, the chunk would start in the middle of whatever the cut left open. RESTORE
        # starts with ESC, which ends that.
        del sink.buf[:]
        try:
            sink.write(RESTORE)
            sink.flush()
        except OSError:
            pass
    return 0


# ---------------------------------------------------------------------------------------------
# The session logs
# ---------------------------------------------------------------------------------------------

# Lines of the advanced (multi-stream) timing file, as util-linux script writes them in
# term-utils/script.c and scriptreplay reads them back in term-utils/script-playutils.c:
# 'I|O <seconds>.<microseconds> <bytes>', 'S <delay> SIG<NAME>[ <message>]', where SIGWINCH
# carries 'ROWS=<rows> COLS=<columns>', and 'H <delay> <name>[ <value>]', such as COLUMNS 80.
# script prints the delay of an H line with %f, which writes a comma under a locale such as
# de_DE; the other delays are integers around a literal dot. script writes at most 6 fraction
# digits (microseconds) and scriptreplay 2.42 reads no more, so I, O and S lines allow 6 and
# replay-timing drops a longer one rather than let scriptreplay stop there.
_IO_LINE = re.compile(rb"([IO]) [0-9]{1,15}\.[0-9]{1,6} ([0-9]{1,15})")
_S_LINE = re.compile(rb"S [0-9]{1,15}\.[0-9]{1,6} SIG(\S+)(?: (.*))?", re.DOTALL)
_H_LINE = re.compile(rb"H [0-9]{1,15}[.,][0-9]{1,9} (\S+)(?: (.*))?", re.DOTALL)
_WINCH = re.compile(rb"ROWS=([0-9]{1,5}) COLS=([0-9]{1,5})")

# The longest timing line read, and how many malformed lines get a warning each.
_LINE_MAX = 4096
_WARN_MAX = 100


class Timing:
    """Read the events of an advanced-format timing file from the descriptor fd, in order.

    events yields ('out', bytes) for each O entry, ('size', rows, columns) for each SIGWINCH
    and ('info', 'COLUMNS' or 'LINES', value) for those H entries. I entries, other signals
    and other H entries yield nothing. A malformed line, one longer than 4096 bytes or a last
    line without its newline gets a warning on stderr and is skipped; past 100 warnings the
    rest are only counted, and report gives their number.
    """

    def __init__(self, fd):
        self.file = os.fdopen(fd, "rb", buffering=65536, closefd=False)
        self.bad = 0

    def lines(self):
        """Yield each line that is well formed, without its newline, with its event or None.

        Malformed lines are counted and warned about, as the class says, and not yielded.
        """
        lineno = 0
        while True:
            line = self.file.readline(_LINE_MAX + 1)
            if not line:
                return
            lineno += 1
            if not line.endswith(b"\n"):
                if len(line) > _LINE_MAX:
                    self._skip_rest()
                self._malformed(lineno)
                continue
            event = self._parse(line[:-1])
            if event is False:
                self._malformed(lineno)
            else:
                yield line[:-1], event

    def events(self):
        """Yield the events of the file, as the class says."""
        for _line, event in self.lines():
            if event is not None:
                yield event

    def _skip_rest(self):
        """Read past the rest of an over-long line, up to its newline or the end of the file."""
        while True:
            chunk = self.file.readline(65536)
            if not chunk or chunk.endswith(b"\n"):
                return

    def _parse(self, line):
        """Return the event of LINE, None for a valid line without one, False when malformed."""
        match = _IO_LINE.fullmatch(line)
        if match:
            return ("out", int(match.group(2))) if match.group(1) == b"O" else None
        match = _S_LINE.fullmatch(line)
        if match:
            if match.group(1) != b"WINCH":
                return None
            size = _WINCH.fullmatch(match.group(2) or b"")
            if size is None:
                return False
            return ("size", int(size.group(1)), int(size.group(2)))
        match = _H_LINE.fullmatch(line)
        if match:
            if match.group(1) not in (b"COLUMNS", b"LINES"):
                return None
            value = match.group(2) or b""
            if not value.isdigit() or len(value) > 9:
                return False
            return ("info", match.group(1).decode("ascii"), int(value))
        return False

    def _malformed(self, lineno):
        """Count the malformed line LINENO, and warn about it while under the limit."""
        self.bad += 1
        if self.bad <= _WARN_MAX:
            _say("warning: timing line %d is malformed; skipped" % lineno)

    def report(self):
        """Warn once about the malformed lines that got no warning of their own."""
        if self.bad > _WARN_MAX:
            _say("warning: %d more malformed timing lines skipped" % (self.bad - _WARN_MAX))


class RawLog:
    """Read output.raw from the descriptor fd: skip its header line, then hand out its bytes."""

    def __init__(self, fd):
        self.fd = fd
        self.left = b""

    def skip_header(self):
        """Skip the first line, 'Script started on ...', which no O entry covers.

        scriptreplay skips it the same way; a file without a newline is skipped whole.
        """
        while True:
            chunk = os.read(self.fd, 65536)
            if not chunk:
                return
            end = chunk.find(b"\n")
            if end >= 0:
                self.left = chunk[end + 1:]
                return

    def read(self, size):
        """Return up to SIZE bytes, at most 64 KiB, or b"" at the end of the file."""
        if self.left:
            data, self.left = self.left[:size], self.left[size:]
            return data
        return os.read(self.fd, min(size, 65536))

    def rest(self, limit):
        """Return what is left of the file, at most LIMIT bytes."""
        data = self.left[:limit]
        self.left = b""
        while len(data) < limit:
            chunk = os.read(self.fd, limit - len(data))
            if not chunk:
                break
            data += chunk
        return data


# What script writes at the end of output.raw after the last O entry's bytes: a newline, then
# 'Script done on ...' with the exit status, in the language of its locale, and a newline.
_TRAILER_MAX = 1024


def _is_trailer(data):
    """Succeed when DATA is nothing or script's trailer: a newline, one line, a newline."""
    if not data:
        return True
    return (len(data) <= _TRAILER_MAX and data.startswith(b"\n") and data.endswith(b"\n")
            and b"\n" not in data[1:-1] and len(data) > 1)


# ---------------------------------------------------------------------------------------------
# The transcript screen
# ---------------------------------------------------------------------------------------------

# The pyte 0.8 Screen methods that the transcript screen calls.
_PYTE_METHODS = (
    "draw", "index", "reverse_index", "linefeed", "carriage_return", "backspace", "tab",
    "cursor_up", "cursor_down", "cursor_forward", "cursor_back", "cursor_down1", "cursor_up1",
    "cursor_to_column", "cursor_position", "erase_in_display", "erase_in_line",
    "erase_characters", "delete_characters", "insert_characters", "insert_lines",
    "delete_lines", "set_mode", "reset_mode", "define_charset", "set_tab_stop",
    "clear_tab_stop", "reset", "ensure_hbounds", "ensure_vbounds",
)

# A run of printable ASCII, which pyte's draw takes whole; other text goes a character at a time.
_PRINTABLE_ASCII = re.compile("[\x20-\x7e]+")
_DRAW_RUNS = re.compile("[\x20-\x7e]+|[^\x20-\x7e]")

# The line that stands for what a full-screen program showed on the alternate screen.
_MARKER = "[full-screen program: %dx%d, not kept here; replay shows it]"

# The longest line that joined rows make; a longer one is cut there, so that output without
# newlines cannot grow a line, and the memory it takes, without bound.
_JOIN_MAX = 65536

# The most characters that a cell takes combining marks up to: a character and its marks. pyte
# normalizes the whole cell for each mark it adds, so without the cap a run of marks would cost
# time that grows with its square, and a cell would grow with the run.
_CELL_MAX = 8


def _numbers(params):
    """Return the parameters of a control sequence as numbers, at least one of them.

    An empty parameter is 0, the default; one that is not digits counts as 0; a sub-parameter
    after ':' is ignored; values stop at 9999, as in pyte's own parser.
    """
    out = []
    for part in params.split(";"):
        part = part.split(":", 1)[0].lstrip("0")
        if not part or not part.isdigit():
            out.append(0)
        elif len(part) > 4:
            out.append(9999)
        else:
            out.append(int(part))
    return out


def load_screen_class():
    """Import pyte and return TranscriptScreen, a pyte.Screen that writes a transcript.

    Raises Failure when pyte does not import or its Screen lacks a method that this file
    calls, as a pyte other than 0.8 may.
    """
    try:
        import pyte
        from pyte import modes
        from pyte.screens import Margins
    except Exception:
        raise Failure("rendering needs python3-pyte (apt install python3-pyte)")
    missing = [name for name in _PYTE_METHODS if not callable(getattr(pyte.Screen, name, None))]
    if missing:
        raise Failure("rendering needs pyte 0.8; this pyte's Screen lacks %s" % ", ".join(missing))

    class TranscriptScreen(pyte.Screen):
        """A pyte screen that writes each line leaving it to a transcript, through emit.

        A row goes out when it scrolls off the top of the scroll region, when a full clear or
        a reset erases it, when a resize pushes it out, and at finish. Rows that an autowrap
        continued are joined into one line: draw's wraps set a row's mark and explicit line
        feeds clear it, as a terminal does when it copies a wrapped line, and a wrap on a space
        sets none, so that zsh's PROMPT_SP padding does not glue a prompt to the output before
        it. Nothing of the alternate screen is kept: one marker line stands for it, before the
        row the cursor returns to. A resize that narrows the screen first writes out the rows
        above the cursor's line up to the last one that reaches past the new width, and
        remembers their clipped text in _done, so that clipping loses no text and no row goes
        out twice. Only the main screen keeps these marks.
        """

        def __init__(self, columns, lines, emit):
            self._emit = emit  # writes one transcript line
            self._alt = None  # the main screen's buffer, cursor, margins, lines and columns
            self._saved = None  # the state DECSC saves
            self._notes = {}  # row -> marker lines that go out before that row
            self._tail = []  # marker lines that go out after the last row
            self._done = {}  # row -> its clipped text, written out early by a resize
            self._wrap = set()  # rows that an autowrap continued on the next row
            self._pending = ""  # the start of a line whose rows continue
            self._drawing = False  # True while draw runs, so that index can tell an autowrap
            self._wrap_char = None  # the character that the next autowrap happens on
            super().__init__(columns, lines)

        # -- input -----------------------------------------------------------------------

        def put_text(self, text):
            """Draw the printable TEXT at the cursor.

            pyte's draw stops at the first character of zero width that does not combine,
            such as a zero-width joiner, and drops the rest of its run, so text other than
            printable ASCII goes a character at a time and only that character is lost. A
            combining mark is dropped once the cell that it would join holds _CELL_MAX
            characters.
            """
            self._drawing = True
            try:
                if _PRINTABLE_ASCII.fullmatch(text):
                    self._draw_ascii(text)
                else:
                    for match in _DRAW_RUNS.finditer(text):
                        run = match.group()
                        if "\x20" <= run[0] <= "\x7e":
                            self._draw_ascii(run)
                        elif not (unicodedata.combining(run) and self._cell_full()):
                            self._wrap_char = run
                            self.draw(run)
            finally:
                self._drawing = False

        def _cell_full(self):
            """Succeed when the cell that draw adds a combining mark to holds _CELL_MAX
            characters or more.

            pyte 0.8's draw adds it to the cell before the cursor, or at the left edge to the
            last cell of the row above. With the cursor past the last column, draw first wraps,
            and that cell still holds what the last cell of the cursor's row holds now. Below
            the scroll region, the wrap's cursor_down stops at the bottom margin, so the mark
            joins the last cell of the row above the margin.
            """
            x, y = min(self.cursor.x, self.columns), self.cursor.y
            if x >= self.columns and modes.DECAWM in self.mode:
                bottom = self.margins.bottom if self.margins else self.lines - 1
                if y > bottom:
                    y = bottom
                    x = 0
            if x > 0:
                x -= 1
            elif y > 0:
                x, y = self.columns - 1, y - 1
            else:
                return False
            row = self.buffer.get(y)
            cell = row.get(x) if row else None
            return cell is not None and len(cell.data) >= _CELL_MAX

        def _draw_ascii(self, run):
            """Draw the printable ASCII RUN with one draw call per row it fills.

            The character that starts each new row gets a call of its own, with _wrap_char
            naming it, since it is the one that the autowrap happens on.
            """
            if modes.DECAWM not in self.mode:
                self.draw(run)
                return
            i, n = 0, len(run)
            while i < n:
                if self.cursor.x >= self.columns:
                    self._wrap_char = run[i]
                    self.draw(run[i])
                    i += 1
                else:
                    end = min(n, i + self.columns - self.cursor.x)
                    self.draw(run[i:end])
                    i = end

        def insert_characters(self, count=None):
            """Insert blanks as pyte does, and drop what that pushed past the last column.

            pyte 0.8 keeps the pushed character in a cell at x == columns, where DCH or a wider
            screen would bring it back. Draw in insert mode comes through here too.
            """
            super().insert_characters(count)
            row = self.buffer.get(self.cursor.y)
            if row:
                for x in [x for x in row if x >= self.columns]:
                    del row[x]

        def stamp(self, utc, vpn):
            """Draw the hidden stamp of UTC and VPN as the line that stamp=on prints.

            The line, '-- UTC VPN REC' or '-- UTC REC' without a VPN, stands on its own: a stamp
            met in the middle of a line starts a new one first, and what follows starts below.
            """
            if self.cursor.x:
                self.control("\r")
                self.control("\n")
            self.put_text("-- %s%s REC" % (utc, " " + vpn if vpn else ""))
            self.control("\r")
            self.control("\n")

        def control(self, ch):
            """Act on the C0 control CH; BEL, SO, SI and the others leave the text as it is."""
            if ch in "\n\x0b\x0c":
                self.linefeed()
            elif ch == "\r":
                self.carriage_return()
            elif ch == "\b":
                self.backspace()
            elif ch == "\t":
                self.tab()

        def escape(self, inter, final):
            """Act on the escape sequence ESC INTER FINAL, as xterm does on the screen."""
            if not inter:
                if final == "7":
                    self._decsc()
                elif final == "8":
                    self._decrc()
                elif final == "D":
                    self.index()
                elif final == "E":
                    self.carriage_return()
                    self.index()
                elif final == "M":
                    self._reverse_index()
                elif final == "H":
                    self.set_tab_stop()
                elif final == "c":
                    self._full_reset()
            elif inter in ("(", ")") and final in "B0":
                self.define_charset(final, inter)

        def csi(self, params, inter, final):
            """Act on the control sequence CSI PARAMS INTER FINAL, as xterm does on the screen.

            Requests, reports, SGR and every sequence that leaves the text as it is do nothing.
            So does REP (CSI b), which the replay filter drops too: each one would repeat a
            character up to a screen's worth, so a hostile stream could blow the transcript up.
            Of the sequences with a private marker, only the DEC modes and the selective erases
            act: CSI ? J and CSI ? K erase as ED and EL do, there being no protected cells,
            and only with plain parameters after the '?', as in xterm.
            """
            if inter:
                return
            if params[:1] in ("?", ">", "<", "="):
                rest = params[1:]
                if params[0] == "?":
                    if final in ("h", "l"):
                        self._private_modes(rest, final == "h")
                    elif final in ("J", "K") and _PLAIN_PARAMS.fullmatch(rest):
                        if final == "J":
                            self._erase_display(_numbers(rest)[0])
                        else:
                            self._erase_line(_numbers(rest)[0])
                return
            if final == "m":
                return
            p = _numbers(params)
            n = p[0]
            if final == "@":
                self.insert_characters(n)
            elif final == "A":
                self.cursor_up(n)
            elif final in ("B", "e"):
                self.cursor_down(n)
            elif final in ("C", "a"):
                self.cursor_forward(n)
            elif final == "D":
                self.cursor_back(n)
            elif final == "E":
                self.cursor_down1(n)
            elif final == "F":
                self.cursor_up1(n)
            elif final in ("G", "`"):
                self.cursor_to_column(n)
            elif final in ("H", "f"):
                self.cursor_position(n, p[1] if len(p) > 1 else 0)
            elif final == "I":
                self._forward_tab(n)
            elif final == "J":
                self._erase_display(n)
            elif final == "K":
                self._erase_line(n)
            elif final == "L":
                self._forget_marks(self.cursor.y)
                self.insert_lines(n)
            elif final == "M":
                self._forget_marks(self.cursor.y)
                self.delete_lines(n)
            elif final == "P":
                self.delete_characters(n)
            elif final == "S" and len(p) == 1:
                self._scroll_up(n)
            elif final == "T" and len(p) == 1:
                self._scroll_down(n)
            elif final == "X":
                self.erase_characters(n)
            elif final == "Z":
                self._back_tab(n)
            elif final == "d":
                self.cursor_position(n, self.cursor.x + 1)
            elif final == "g":
                self.clear_tab_stop(n)
            elif final in ("h", "l"):
                for mode in p:
                    if mode in (4, 20):
                        if final == "h":
                            self.set_mode(mode)
                        else:
                            self.reset_mode(mode)
            elif final == "r":
                self._set_region(p)
            elif final == "s" and not params:
                self._decsc()
            elif final == "u" and not params:
                self._decrc()

        def resize_to(self, lines, columns):
            """Resize the screen to LINES x COLUMNS, as a SIGWINCH entry says.

            The scroll region resets, tab stops follow the new width and the cursor stays in
            bounds. On the main screen, rows pushed out above the cursor are written out and
            text that a narrower screen would clip goes out first; see the class.
            """
            if (lines, columns) == (self.lines, self.columns):
                return
            if self._alt is None:
                self._resize_main(lines, columns)
            else:
                self._resize_plain(lines, columns)

        def finish(self):
            """Write out the rest at the end of the input: the main screen, with any marker."""
            if self._alt is not None:
                self._alt_leave(0)
            self._flush()

        # -- scrolling and output ----------------------------------------------------------

        def index(self):
            """Move the cursor down a line, scrolling at the bottom margin.

            pyte calls it for LF, VT, FF and for an autowrap inside draw; IND and NEL call it
            too. On the main screen the row it leaves gets its wrap mark from how it is left:
            an autowrap sets it, unless a space wraps, as when zsh's PROMPT_SP pads a line
            that output left unfinished; a line feed clears it.
            """
            if self._alt is None:
                if self._drawing and self._wrap_char != " ":
                    self._wrap.add(self.cursor.y)
                else:
                    self._wrap.discard(self.cursor.y)
            self._scroll_once()

        def _scroll_once(self):
            """Run pyte's index, writing out the row it scrolls off on the main screen."""
            top, bottom = self.margins or (0, self.lines - 1)
            if self._alt is None and self.cursor.y == bottom:
                self._write_notes(self._notes.pop(top, None))
                self._write_row(top)
                self._move_marks(top + 1, bottom, -1)
                if bottom == self.lines - 1 and self._tail:
                    self._notes[bottom] = self._tail
                    self._tail = []
            super().index()

        def _reverse_index(self):
            """Move the cursor up a line, scrolling down at the top margin, as RI does."""
            top = self.margins.top if self.margins else 0
            if self.cursor.y == top:
                self._forget_marks(top)
            self.reverse_index()

        def _scroll_up(self, count):
            """Scroll the region up COUNT lines, as SU does, writing out what leaves its top."""
            bottom = self.margins.bottom if self.margins else self.lines - 1
            x, y = self.cursor.x, self.cursor.y
            for _ in range(min(count or 1, self.lines)):
                self.cursor.y = bottom
                self._scroll_once()
            self.cursor.x, self.cursor.y = x, y

        def _scroll_down(self, count):
            """Scroll the region down COUNT lines, as SD does; rows pushed off its bottom go."""
            top = self.margins.top if self.margins else 0
            x, y = self.cursor.x, self.cursor.y
            self._forget_marks(top)
            for _ in range(min(count or 1, self.lines)):
                self.cursor.y = top
                self.reverse_index()
            self.cursor.x, self.cursor.y = x, y

        def _row_text(self, y, full=False):
            """Return the text of row Y: its cells joined, gaps as spaces, trailing ones cut.

            With FULL, the row keeps every column, trailing spaces included, as a row that
            continues on the next one needs.
            """
            row = self.buffer.get(y)
            columns = self.columns
            parts = []
            pos = 0
            if row:
                for x in sorted(row):
                    if x >= columns:
                        break
                    if x > pos:
                        parts.append(" " * (x - pos))
                    parts.append(row[x].data)
                    pos = x + 1
            if full:
                if pos < columns:
                    parts.append(" " * (columns - pos))
                return "".join(parts)
            return "".join(parts).rstrip(" ")

        def _put_row(self, text, wrapped):
            """Write TEXT as the next row of the transcript; a WRAPPED row waits for the next.

            A joined line that reaches _JOIN_MAX characters goes out as it is.
            """
            if wrapped:
                self._pending += text
                if len(self._pending) >= _JOIN_MAX:
                    self._end_line()
            else:
                self._emit(self._pending + text)
                self._pending = ""

        def _end_line(self):
            """End a line whose rows continued, so that whatever comes next starts a new one."""
            if self._pending:
                self._emit(self._pending)
                self._pending = ""

        def _write_notes(self, notes):
            """Write the marker lines NOTES, if any, each as a line of its own."""
            if notes:
                self._end_line()
                for note in notes:
                    self._emit(note)

        def _write_row(self, y):
            """Write out row Y as it leaves the screen, unless a resize wrote it unchanged."""
            wrapped = y in self._wrap
            self._wrap.discard(y)
            text = self._row_text(y, wrapped)
            done = self._done.pop(y, None)
            if done is not None:
                if done == text.rstrip(" "):
                    return
                self._end_line()
            self._put_row(text, wrapped)

        def _flush(self):
            """Write out the whole main screen, top to bottom, and clear the marks.

            Blank rows above the first content and below the last are screen space, not
            output, and stay out; blank rows between them are kept.
            """
            rows = []
            for y in range(self.lines):
                wrapped = y in self._wrap
                text = self._row_text(y, wrapped)
                done = self._done.get(y)
                redo = done is not None and done != text.rstrip(" ")
                if done is not None and not redo:
                    text = None
                rows.append((self._notes.get(y), text, wrapped, redo))
            tail = self._tail
            self._notes, self._done, self._wrap, self._tail = {}, {}, set(), []
            first, last = 0, len(rows)
            if not self._pending:
                while first < last and not rows[first][0] and rows[first][1] is not None \
                        and not rows[first][1].strip(" "):
                    first += 1
            while last > first and not rows[last - 1][0] and \
                    (rows[last - 1][1] is None or not rows[last - 1][1].strip(" ")):
                last -= 1
            for notes, text, wrapped, redo in rows[first:last]:
                self._write_notes(notes)
                if redo:
                    self._end_line()
                if text is not None:
                    self._put_row(text, wrapped)
            self._write_notes(tail)
            self._end_line()

        def _move_marks(self, low, high, delta):
            """Move the notes, done texts and wrap marks of rows LOW..HIGH by DELTA rows."""
            def moved(key):
                return key + delta if low <= key <= high else key
            if self._notes:
                self._notes = {moved(key): value for key, value in self._notes.items()}
            if self._done:
                self._done = {moved(key): value for key, value in self._done.items()}
            if self._wrap:
                self._wrap = {moved(key) for key in self._wrap}

        def _forget_marks(self, first):
            """Drop the wrap and done marks of rows FIRST and below, whose rows move or go."""
            if self._alt is None:
                self._wrap = {y for y in self._wrap if y < first}
                self._done = {y: text for y, text in self._done.items() if y < first}

        # -- erasing ---------------------------------------------------------------------

        def _erase_display(self, how):
            """Erase in display (ED); a full clear writes the main screen out first.

            ED 2 and 3, as clear sends them, and ED 0 with the cursor in the top left corner
            erase the whole screen. xterm keeps the screen for ED 3 and clears its scrollback;
            erasing it here too keeps later output from overwriting rows that never went out.
            Rows erased whole lose their wrap marks. A full clear drops every cell, which leaves
            the same text as pyte's ED 2, which overwrites each cell, and keeps each later clear
            as cheap as the screen's rows.
            """
            if how in (2, 3) or (how == 0 and self.cursor.x == 0 and self.cursor.y == 0):
                if self._alt is None:
                    self._flush()
                self.buffer.clear()
            elif how in (0, 1):
                if self._alt is None:
                    y = self.cursor.y
                    if how == 0:
                        keep = y if self.cursor.x > 0 else y - 1
                        self._wrap = {r for r in self._wrap if r <= keep}
                    else:
                        self._wrap = {r for r in self._wrap if r >= y}
                self.erase_in_display(how)

        def _erase_line(self, how):
            """Erase in line (EL); erasing all of a row, or all of it from its start, unwraps it."""
            if how in (0, 1, 2):
                if self._alt is None and (how == 2 or (how == 0 and self.cursor.x == 0)):
                    self._wrap.discard(self.cursor.y)
                self.erase_in_line(how)

        def _full_reset(self):
            """RIS: write out the main screen, as a clear does, then reset everything."""
            if self._alt is not None:
                self._alt_leave(0)
            self._flush()
            self.reset()
            self._saved = None

        # -- modes, cursor and region ------------------------------------------------------

        def _private_modes(self, params, on):
            """Set (ON) or reset the DEC private modes in PARAMS that change the text.

            47, 1047 and 1049 switch the alternate screen, 1048 saves or restores the cursor,
            6 is origin mode and 7 autowrap. Every other mode is ignored, 3 (132 columns)
            included, since pyte would erase the screen for it.
            """
            for part in params.split(";"):
                if not part.isdigit() or len(part) > 5:
                    continue
                mode = int(part)
                if mode in (47, 1047, 1049):
                    if on:
                        self._alt_enter(mode)
                    else:
                        self._alt_leave(mode)
                elif mode == 1048:
                    if on:
                        self._decsc()
                    else:
                        self._decrc()
                elif mode in (6, 7):
                    if on:
                        self.set_mode(mode, private=True)
                    else:
                        self.reset_mode(mode, private=True)

        def _decsc(self):
            """Save the cursor as DECSC does: one slot, as in xterm."""
            cursor = self.cursor
            self._saved = (cursor.x, cursor.y, cursor.attrs, self.g0_charset, self.g1_charset,
                           self.charset, modes.DECOM in self.mode, modes.DECAWM in self.mode)

        def _decrc(self):
            """Restore what DECSC saved, as DECRC does; without a save, home the cursor."""
            if self._saved is None:
                self.mode.discard(modes.DECOM)
                self.cursor_position()
                return
            x, y, attrs, g0, g1, charset, origin, wrap = self._saved
            self.g0_charset, self.g1_charset, self.charset = g0, g1, charset
            for flag, on in ((modes.DECOM, origin), (modes.DECAWM, wrap)):
                if on:
                    self.mode.add(flag)
                else:
                    self.mode.discard(flag)
            self.cursor.x, self.cursor.y, self.cursor.attrs = x, y, attrs
            self.ensure_hbounds()
            self.ensure_vbounds()

        def _set_region(self, p):
            """Set the scroll region, as DECSTBM does, and home the cursor.

            Defaults are the first and the last line; a region of fewer than 2 lines is
            ignored, as xterm does.
            """
            top = min(p[0] or 1, self.lines)
            bottom = min((p[1] if len(p) > 1 else 0) or self.lines, self.lines)
            if bottom - top < 1:
                return
            if top == 1 and bottom == self.lines:
                self.margins = None
            else:
                self.margins = Margins(top - 1, bottom - 1)
            self.cursor_position()

        def _forward_tab(self, count):
            """Move the cursor forward COUNT tab stops, as CHT does, to the last column at most.

            One search in the sorted stops, where COUNT calls of pyte's tab would sort them
            COUNT times.
            """
            stops = sorted(self.tabstops)
            i = bisect.bisect_right(stops, self.cursor.x) + (count or 1) - 1
            last = self.columns - 1
            self.cursor.x = min(stops[i], last) if i < len(stops) else last

        def _back_tab(self, count):
            """Move the cursor back COUNT tab stops, as CBT does, to column 0 at most."""
            stops = sorted(self.tabstops)
            i = bisect.bisect_left(stops, self.cursor.x) - (count or 1)
            self.cursor.x = stops[i] if i >= 0 else 0

        # -- the alternate screen ----------------------------------------------------------

        def _alt_enter(self, mode):
            """Switch to an empty alternate screen and keep the main one aside.

            1049 also saves the cursor, as DECSC does; on the alternate screen already, 1049
            clears it and 47 and 1047 do nothing, as in xterm.
            """
            if self._alt is not None:
                if mode == 1049:
                    self.buffer.clear()
                return
            if mode == 1049:
                self._decsc()
            self._alt = (self.buffer, copy.copy(self.cursor), self.margins, self.lines,
                         self.columns)
            self.buffer = type(self.buffer)(self.buffer.default_factory)

        def _alt_leave(self, mode):
            """Switch back to the main screen with its cursor and add the marker line.

            The main screen takes the current size, as resize_to would have given it. Off the
            alternate screen, leaving 1049 restores the cursor as DECRC does, as in xterm.
            """
            if self._alt is None:
                if mode == 1049:
                    self._decrc()
                return
            buffer, cursor, margins, lines, columns = self._alt
            self._alt = None
            now = (self.lines, self.columns)
            self.buffer, self.cursor, self.margins = buffer, cursor, margins
            self.lines, self.columns = lines, columns
            if now != (lines, columns):
                self._resize_main(now[0], now[1])
            note = _MARKER % (lines, columns)
            y = self.cursor.y + (1 if self.cursor.x > 0 else 0)
            notes = self._tail if y >= self.lines else self._notes.setdefault(y, [])
            if not notes or notes[-1] != note:
                notes.append(note)

        # -- resizing --------------------------------------------------------------------

        def _resize_main(self, lines, columns):
            """Resize the main screen to LINES x COLUMNS, losing no text that left it.

            See the class for a narrower screen. With fewer lines, the rows above the cursor
            that no longer fit go out as if scrolled off, and rows below the cursor that do
            not fit are dropped, their markers kept for the end.
            """
            old_lines, old_columns = self.lines, self.columns
            cursor_y = min(self.cursor.y, old_lines - 1)
            if columns < old_columns:
                start = cursor_y
                while start > 0 and start - 1 in self._wrap:
                    start -= 1
                last = -1
                for y in range(start):
                    if self._reaches(y, columns):
                        last = y
                for y in range(last + 1):
                    self._write_notes(self._notes.pop(y, None))
                    wrapped = y in self._wrap
                    text = self._row_text(y, wrapped)
                    done = self._done.get(y)
                    if done is None or done != text.rstrip(" "):
                        if done is not None:
                            self._end_line()
                        self._put_row(text, wrapped)
                self._clip(columns)
                for y in range(last + 1):
                    self._done[y] = self._row_text(y)
            if lines < old_lines:
                if cursor_y >= lines:
                    count = cursor_y - lines + 1
                    for y in range(count):
                        self._write_notes(self._notes.pop(y, None))
                        self._write_row(y)
                    self._move_marks(count, old_lines - 1, -count)
                    self._shift_rows(count)
                    self.cursor.y = cursor_y - count
                for y in [y for y in self.buffer if y >= lines]:
                    del self.buffer[y]
                moved = []
                for y in sorted(key for key in self._notes if key >= lines):
                    moved.extend(self._notes.pop(y))
                self._tail = moved + self._tail
                self._done = {y: text for y, text in self._done.items() if y < lines}
                self._wrap = {y for y in self._wrap if y < lines}
            self.lines, self.columns = lines, columns
            self._after_resize(old_columns)

        def _resize_plain(self, lines, columns):
            """Resize the alternate screen to LINES x COLUMNS; its rows are never written."""
            old_columns = self.columns
            if columns < old_columns:
                self._clip(columns)
            if lines < self.lines:
                if self.cursor.y >= lines:
                    count = self.cursor.y - lines + 1
                    self._shift_rows(count)
                    self.cursor.y -= count
                for y in [y for y in self.buffer if y >= lines]:
                    del self.buffer[y]
            self.lines, self.columns = lines, columns
            self._after_resize(old_columns)

        def _reaches(self, y, columns):
            """Succeed when row Y holds text in column COLUMNS or further right."""
            row = self.buffer.get(y)
            if not row:
                return False
            return any(columns <= x < self.columns and cell.data.strip()
                       for x, cell in row.items())

        def _clip(self, columns):
            """Drop every cell in column COLUMNS or further right."""
            for row in self.buffer.values():
                for x in [x for x in row if x >= columns]:
                    del row[x]

        def _shift_rows(self, count):
            """Move every row up COUNT rows; the top COUNT rows go."""
            old = self.buffer
            new = type(old)(old.default_factory)
            for y, row in old.items():
                if y >= count:
                    new[y - count] = row
            self.buffer = new

        def _after_resize(self, old_columns):
            """Reset the region, fit the tab stops to the width and keep the cursor in bounds.

            Columns that a wider screen adds get tab stops every 8 columns, as at a reset.
            """
            self.margins = None
            columns = self.columns
            stops = {stop for stop in self.tabstops if stop < columns}
            if columns > old_columns:
                stops.update(range(max(8, -(-old_columns // 8) * 8), columns, 8))
            self.tabstops = stops
            self.ensure_hbounds()
            self.ensure_vbounds()

    return TranscriptScreen


def _dispatch(screen, tokens):
    """Hand each token to the screen method that acts on its kind."""
    for token in tokens:
        kind = token[0]
        if kind == TEXT:
            screen.put_text(token[1])
        elif kind == CTRL:
            screen.control(token[1])
        elif kind == ESC:
            screen.escape(token[1], token[2])
        elif kind == CSI:
            screen.csi(token[1], token[2], token[3])
        else:
            screen.stamp(token[1], token[2])


# ---------------------------------------------------------------------------------------------
# render
# ---------------------------------------------------------------------------------------------

# The transcript's name in the session folder, and the name it is written under first.
FINAL = "transcript.txt"
PART = "transcript.txt.part"

# The screen sizes a timing file may set, so that a hostile one cannot make the screen huge; a
# size of 0, as script logs for a terminal without one, keeps the size as it is.
_MIN_SIZE = 2
_MAX_LINES = 500
_MAX_COLUMNS = 1000


def _clamp(value, current, top):
    """Return VALUE within _MIN_SIZE..TOP, or CURRENT when VALUE is 0."""
    if value == 0:
        return current
    return max(_MIN_SIZE, min(value, top))


def _open_session(folder, sid):
    """Open the session FOLDER, which must be a real folder of this user's, and return its fd."""
    try:
        fd = os.open(folder, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except OSError as error:
        raise Failure("session %s: cannot open its folder: %s" % (sid, error.strerror))
    if os.fstat(fd).st_uid != os.geteuid():
        os.close(fd)
        raise Failure("session %s: its folder belongs to another user" % sid)
    return fd


def _open_log(dfd, name, sid):
    """Open the log NAME in the session folder DFD for reading and return its fd.

    It must be a regular file of this user's; a symlink is not followed, and a FIFO in its
    place cannot hold the open up.
    """
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dfd)
    except OSError as error:
        raise Failure("session %s: cannot open %s: %s" % (sid, name, error.strerror))
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid():
        os.close(fd)
        raise Failure("session %s: %s is not a regular file of yours" % (sid, name))
    os.set_blocking(fd, True)
    return fd


def _check_transcript(dfd, sid):
    """Raise Failure when transcript.txt in DFD exists as a symlink or not as a regular file."""
    try:
        info = os.stat(FINAL, dir_fd=dfd, follow_symlinks=False)
    except FileNotFoundError:
        return
    if stat.S_ISLNK(info.st_mode):
        raise Failure("session %s: transcript.txt is a symlink, which tlogger does not write "
                      "through; remove it" % sid)
    if not stat.S_ISREG(info.st_mode):
        raise Failure("session %s: transcript.txt is not a regular file; remove it" % sid)


def _remove_part(dfd):
    """Remove transcript.txt.part from DFD; a failure is ignored."""
    try:
        os.unlink(PART, dir_fd=dfd)
    except OSError:
        pass


def _create_part(dfd, sid):
    """Create transcript.txt.part in DFD, mode 0600, and return its fd.

    O_EXCL and O_NOFOLLOW refuse a .part that exists, a symlink included, which is never
    followed: a render that did not finish leaves one, and its user removes it. When the mode
    cannot be set, the new .part is closed and removed before Failure is raised.
    """
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC
    try:
        fd = os.open(PART, flags, 0o600, dir_fd=dfd)
    except FileExistsError:
        raise Failure("session %s: transcript.txt.part exists, left by a render that did not "
                      "finish; remove it and render again" % sid)
    except OSError as error:
        raise Failure("session %s: cannot create transcript.txt.part: %s"
                      % (sid, error.strerror))
    try:
        os.fchmod(fd, 0o600)
    except OSError as error:
        os.close(fd)
        _remove_part(dfd)
        raise Failure("session %s: cannot set mode 0600 on transcript.txt.part: %s"
                      % (sid, error.strerror))
    return fd


def _transcribe(screen_class, sink, timing_fd, output_fd, sid, version):
    """Write the transcript of the session's logs to SINK: the header line, then the text.

    Only O entries carry output, taken in order from output.raw after its header line;
    H COLUMNS and LINES before the first output set the first size (80x24 by default) and
    SIGWINCH entries resize, all clamped. UTF-8 that a chunk boundary splits is decoded whole;
    invalid bytes become U+FFFD. Output that ends before its timing gets one warning, and so
    does output.raw holding more than its timing covers, once past script's trailer. Either of
    these or malformed timing lines also end the transcript with a note line each, so that a
    transcript that lacks output does not look complete.
    """
    def emit(line):
        sink.write(_clean(line).encode("utf-8") + b"\n")

    emit("# DERIVED transcript of session %s; the evidence is output.raw with timing. "
         "tlogger %s, rendered %s"
         % (sid, version, time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())))
    timing = Timing(timing_fd)
    raw = RawLog(output_fd)
    raw.skip_header()
    decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
    tokenizer = Tokenizer()
    lines, columns = 24, 80
    screen = None
    short = False
    for event in timing.events():
        if event[0] == "info":
            if screen is None:
                if event[1] == "LINES":
                    lines = _clamp(event[2], lines, _MAX_LINES)
                else:
                    columns = _clamp(event[2], columns, _MAX_COLUMNS)
            continue
        if event[0] == "size":
            if screen is None:
                lines = _clamp(event[1], lines, _MAX_LINES)
                columns = _clamp(event[2], columns, _MAX_COLUMNS)
            else:
                screen.resize_to(_clamp(event[1], screen.lines, _MAX_LINES),
                                 _clamp(event[2], screen.columns, _MAX_COLUMNS))
            continue
        if screen is None:
            screen = screen_class(columns, lines, emit)
        left = event[1]
        while left > 0:
            data = raw.read(left)
            if not data:
                break
            left -= len(data)
            _dispatch(screen, tokenizer.feed(decoder.decode(data)))
        if left > 0:
            _say("warning: output.raw of session %s ends before its timing does; the "
                 "transcript stops there" % sid)
            short = True
            break
    extra = False
    if not short and not _is_trailer(raw.rest(_TRAILER_MAX + 1)):
        _say("warning: output.raw of session %s holds more output than its timing covers; the "
             "transcript stops there" % sid)
        extra = True
    if screen is None:
        screen = screen_class(columns, lines, emit)
    _dispatch(screen, tokenizer.feed(decoder.decode(b"", True)))
    tokenizer.finish()
    screen.finish()
    timing.report()
    if timing.bad:
        emit("[%d malformed timing line%s skipped]" % (timing.bad, "" if timing.bad == 1 else "s"))
    if short:
        emit("[output.raw ends before its timing does; the transcript stops here]")
    if extra:
        emit("[output.raw holds more output than its timing covers; the transcript stops here]")


def render(folder, version, to_stdout):
    """Render the session in FOLDER: to stdout, or to transcript.txt in FOLDER.

    The file goes through transcript.txt.part, created with O_EXCL and O_NOFOLLOW, mode 0600,
    synced and renamed over transcript.txt, which must not be a symlink or other than a
    regular file. On any failure or signal the .part is removed: the signals of _STOP_SIGNALS
    wait while it is created, so that none comes between its creation and the mark that it
    exists. FOLDER loses its trailing slashes, with which the kernel would follow a symlink
    despite O_NOFOLLOW. The evidence files are only read. Returns 0.
    """
    screen_class = load_screen_class()
    folder = folder.rstrip("/") or folder
    sid = os.path.basename(folder) or folder
    dfd = _open_session(folder, sid)
    fds = [dfd]
    part = -1
    created = False
    try:
        timing_fd = _open_log(dfd, "timing", sid)
        fds.append(timing_fd)
        output_fd = _open_log(dfd, "output.raw", sid)
        fds.append(output_fd)
        if to_stdout:
            sink = Sink(1)
        else:
            _check_transcript(dfd, sid)
            signal.pthread_sigmask(signal.SIG_BLOCK, _STOP_SIGNALS)
            try:
                part = _create_part(dfd, sid)
                created = True
            finally:
                # A signal that came meanwhile raises Stop here, once the .part is marked.
                signal.pthread_sigmask(signal.SIG_UNBLOCK, _STOP_SIGNALS)
            sink = Sink(part)
        _transcribe(screen_class, sink, timing_fd, output_fd, sid, version)
        sink.flush()
        if created:
            os.fsync(part)
            # part is -1 before the close, so that a signal right after it cannot close it twice.
            fd, part = part, -1
            os.close(fd)
            _check_transcript(dfd, sid)
            os.rename(PART, FINAL, src_dir_fd=dfd, dst_dir_fd=dfd)
            created = False
    except BaseException:
        _ignore_signals()
        if part >= 0:
            os.close(part)
        if created:
            _remove_part(dfd)
        raise
    finally:
        for fd in fds:
            os.close(fd)
    return 0


def cmd_render(args):
    """tlogger_view.py render --version VERSION [--stdout] [--] FOLDER: render a session."""
    version = None
    to_stdout = False
    folders = []
    rest = list(args)
    while rest:
        arg = rest.pop(0)
        if arg == "--stdout":
            to_stdout = True
        elif arg == "--version":
            if not rest:
                raise UsageError("--version needs a value")
            version = rest.pop(0)
        elif arg == "--":
            folders.extend(rest)
            rest = []
        elif arg.startswith("-"):
            raise UsageError("unknown option for render: %s" % arg)
        else:
            folders.append(arg)
    if version is None or not _VERSION_RE.fullmatch(version):
        raise UsageError("render needs --version and a version such as 0.1.0")
    if len(folders) != 1:
        raise UsageError("render takes one session folder")
    return render(folders[0], version, to_stdout)


def cmd_replay_timing(args):
    """tlogger_view.py replay-timing: copy a timing file from stdin to stdout for scriptreplay.

    I, O and S lines go out as they are. H lines stay out: their delay is always 0, script
    prints it with %f, which writes a comma under a locale such as de_DE, and scriptreplay
    2.42 reads it as <integer>.<integer> (term-utils/script-playutils.c) and stops there as
    at the end of the file. Malformed lines stay out with a warning each, as in render, since
    scriptreplay stops at the first one. bin/tlogger opens the timing file. Returns 0.
    """
    if args:
        raise UsageError("replay-timing takes no arguments")
    timing = Timing(0)
    sink = Sink(1)
    for line, _event in timing.lines():
        if not line.startswith(b"H"):
            sink.write(line + b"\n")
    sink.flush()
    timing.report()
    return 0


def cmd_probe(args):
    """tlogger_view.py probe [--pyte]: print ok, or no-pyte when pyte does not import.

    bin/tlogger runs it to tell a missing python3 from a missing pyte; only --pyte imports
    pyte. Writes with os.write, so that no newline translation adds a CR. Returns 0.
    """
    if args not in ([], ["--pyte"]):
        raise UsageError("probe takes --pyte at most")
    answer = b"ok\n"
    if args:
        try:
            import pyte  # noqa: F401
        except Exception:
            answer = b"no-pyte\n"
    os.write(1, answer)
    return 0


# ---------------------------------------------------------------------------------------------
# Archives
# ---------------------------------------------------------------------------------------------

# An archive of tlogger archive is one gzip stream of a tar whose members are regular files
# only, with no folder entries and no links: <name>/MANIFEST first, the whole MANIFEST of the
# folder, then for each session <name>/<id>/<file> for each file its SHA256SUMS lists, in that
# order, <name>/<id>/SHA256SUMS and <name>/<id>/SEAL. Each member keeps the mode of its file and
# its time in whole seconds, with owner and group 0 and no user or group name.

# The files a seal covers, as bin/tlogger's SEAL_FILES lists them.
SEAL_FILES = ("output.raw", "timing", "input.raw", "commands.tsv", "recorder", "started",
              "exited", "stop-requested")

# A session id, as bin/tlogger's SESSION_NAME_RE takes it, and an engagement name, as its
# ENGAGEMENT_RE does; the names of the files beside the sessions and a session id are none.
_SESSION_ID = re.compile(r"[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9]{6}")
_ENGAGEMENT = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")
_RESERVED = ("MANIFEST", "PRUNED")

# A line of SHA256SUMS as verify reads it, and the start of a MANIFEST line: a sum, two spaces.
_SUM_LINE = re.compile(rb"([0-9a-f]{64}) [ *](.+)")
_MANIFEST_SUM = re.compile(rb"[0-9a-f]{64}  ")

_GZIP_MAGIC = b"\x1f\x8b"
_CHUNK = 1 << 16

# The largest MANIFEST, SHA256SUMS or SEAL, and .sha256 file read whole: a MANIFEST line takes
# about 90 bytes, a SHA256SUMS of all the SEAL_FILES about 700.
_MANIFEST_MAX = 16 << 20
_SMALL_MAX = 1 << 16
_SIDECAR_MAX = 4096

# The member types that are regular files.
_REGULAR = (tarfile.REGTYPE, tarfile.AREGTYPE)

# Open flags that a system may lack: Windows has neither O_NOFOLLOW nor O_NONBLOCK, and reads
# a file without O_BINARY as text.
_O_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)
_O_NONBLOCK = getattr(os, "O_NONBLOCK", 0)
_O_DIRECTORY = getattr(os, "O_DIRECTORY", 0)
_O_CLOEXEC = getattr(os, "O_CLOEXEC", 0)
_O_BINARY = getattr(os, "O_BINARY", 0)
_O_READ = os.O_RDONLY | _O_NOFOLLOW | _O_NONBLOCK | _O_CLOEXEC | _O_BINARY

# The characters of the random part of a temp name.
_TOKEN = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"


def _shown(path):
    """Return PATH with a leading HOME replaced by ~, as bin/tlogger's shown does."""
    home = os.environ.get("HOME", "")
    while home.endswith("/") and home != "/":
        home = home[:-1]
    if home and home != "/" and (path == home or path.startswith(home + "/")):
        return "~" + path[len(home):]
    return path


def _engagement_ok(name):
    """Return True when NAME is a valid engagement name, as bin/tlogger's engagement_name_ok."""
    return (bool(_ENGAGEMENT.fullmatch(name)) and name not in _RESERVED
            and not _SESSION_ID.fullmatch(name))


def _lines(data):
    """Return the lines of DATA as a bash read loop gives them: split at each LF, with no empty
    last line after a final LF."""
    lines = data.split(b"\n")
    if lines[-1] == b"":
        lines.pop()
    return lines


def _seal_sum(data):
    """Return the sum that the last 'sha256 ' line of the SEAL DATA names, or None."""
    sealed = None
    for line in _lines(data):
        if line.startswith(b"sha256 "):
            sealed = line[7:]
    return sealed


def _manifest_sum(manifest, sid):
    """Return the sum of the last line '<sum>  SID/SHA256SUMS' of the MANIFEST bytes, as
    bin/tlogger's manifest_line finds it, or None."""
    want = (sid + "/SHA256SUMS").encode()
    found = None
    for line in _lines(manifest or b""):
        if _MANIFEST_SUM.fullmatch(line[:66]) and line[66:] == want:
            found = line[:64]
    return found


def _read_upto(fd, size):
    """Return the first SIZE bytes of the file FD, or all of it when it is shorter."""
    data = bytearray()
    while len(data) < size:
        chunk = os.read(fd, min(_CHUNK, size - len(data)))
        if not chunk:
            break
        data += chunk
    return bytes(data)


def _write_all(fd, data):
    """Write all of DATA to the file FD."""
    view = memoryview(data)
    while view:
        view = view[os.write(fd, view):]


class _Gunzip:
    """Read the open file FD as tar reads a .tar.gz: its gzip members one after another, as one
    stream of bytes.

    It hashes the bytes of the file as they come, and keeps the offset of the last byte of the
    stream that is not 0. A file that does not start as gzip, a member cut short or damaged, and
    bytes after a member that start no other one raise Failure, its message after SHOWN; error
    keeps it, should tarfile wrap it in an error of its own.
    """

    def __init__(self, fd, shown):
        self.fd = fd
        self.shown = shown
        self.digest = hashlib.sha256()
        self.unzip = None
        self.members = 0
        self.pending = b""
        self.out = bytearray()
        self.offset = 0
        self.last_data = -1
        self.ended = False
        self.error = None

    def _fail(self, what):
        """Raise Failure: SHOWN, then WHAT."""
        self.error = Failure("%s %s" % (self.shown, what))
        raise self.error

    def _raw(self):
        """Return the next bytes of the file, b'' at its end, and hash them."""
        data = os.read(self.fd, _CHUNK)
        self.digest.update(data)
        return data

    def _produce(self):
        """Add the next piece of the stream to out, or set ended at the end of the file."""
        while not self.ended:
            if self.unzip is None:
                while len(self.pending) < 2:
                    data = self._raw()
                    if not data:
                        break
                    self.pending += data
                if not self.pending:
                    if not self.members:
                        self._fail("is not a gzip file")
                    self.ended = True
                    return
                if self.pending[:2] != _GZIP_MAGIC:
                    if not self.members:
                        self._fail("is not a gzip file")
                    self._fail("holds bytes after its gzip data that are no gzip stream")
                self.unzip = zlib.decompressobj(16 + zlib.MAX_WBITS)
                self.members += 1
            data, self.pending = self.pending, b""
            if not data:
                data = self._raw()
            try:
                chunk = self.unzip.decompress(data, _CHUNK) if data else self.unzip.flush()
            except zlib.error:
                self._fail("is damaged: its gzip data does not decode")
            if self.unzip.eof:
                self.pending = self.unzip.unused_data
                self.unzip = None
            elif data:
                self.pending = self.unzip.unconsumed_tail
            elif not chunk:
                self._fail("is cut short")
            if chunk:
                kept = len(chunk.rstrip(b"\0"))
                if kept:
                    self.last_data = self.offset + kept - 1
                self.offset += len(chunk)
                self.out += chunk
                return

    def read(self, size=-1):
        """Return the next SIZE bytes of the stream, fewer at its end; all with a negative SIZE."""
        while (size < 0 or len(self.out) < size) and not self.ended:
            self._produce()
        if size < 0:
            size = len(self.out)
        data = bytes(self.out[:size])
        del self.out[:size]
        return data

    def drain(self):
        """Read the stream to the end of the file."""
        while self.read(_CHUNK):
            pass


class _Member:
    """A regular member of an archived session: its mode, the SHA-256 of its data, and the data
    itself for SHA256SUMS and SEAL, None when it is not kept."""

    def __init__(self, mode, digest, data):
        self.mode = mode
        self.digest = digest
        self.data = data


class _Session:
    """An archived session: its regular members by entry name, every entry name it holds, and
    what is wrong with its members."""

    def __init__(self):
        self.files = {}
        self.names = set()
        self.problems = []


class ArchiveCheck:
    """What check_archive found in an archive: its <name>, the bytes of its MANIFEST (None
    without one), its sessions by id, the faults that belong to no session, the findings of each
    session, which make it changed, and the SHA-256 of the file."""

    def __init__(self):
        self.name = None
        self.manifest = None
        self.manifest_seen = False
        self.sessions = {}
        self.faults = []
        self.findings = {}
        self.digest = ""

    def ok(self):
        """Return True when the archive has no fault and every session is ok."""
        return not self.faults and not any(self.findings.values())

    def verdict(self, sid):
        """Return the verdict of the session SID: ok or changed."""
        return "changed" if self.faults or self.findings[sid] else "ok"


def _member_data(tar, info, keep):
    """Return the SHA-256 of the regular member INFO of TAR and, when KEEP, its data, else None."""
    digest = hashlib.sha256()
    data = bytearray()
    source = tar.extractfile(info)
    while True:
        chunk = source.read(_CHUNK)
        if not chunk:
            break
        digest.update(chunk)
        if keep:
            data += chunk
    return digest.hexdigest(), (bytes(data) if keep else None)


def _take(tar, info, result):
    """Sort the member INFO of TAR into RESULT, reading the data of a regular member."""
    name = info.name
    parts = name.split("/")
    if result.name is None:
        result.name = parts[0]
    regular = info.type in _REGULAR
    if (name.startswith("/") or parts[0] != result.name or len(parts) < 2
            or any(part in ("", ".", "..") for part in parts)):
        result.faults.append("it holds %s, which is no file in the folder %s"
                             % (name, result.name))
        return
    if len(parts) == 2 and parts[1] == "MANIFEST":
        if result.manifest_seen:
            result.faults.append("it holds %s twice" % name)
        elif not regular:
            result.faults.append("its MANIFEST is not a regular file")
        elif info.size > _MANIFEST_MAX:
            result.faults.append("its MANIFEST is larger than %d bytes" % _MANIFEST_MAX)
        else:
            result.manifest = _member_data(tar, info, True)[1]
        result.manifest_seen = True
        return
    sid = parts[1]
    if not _SESSION_ID.fullmatch(sid):
        result.faults.append("it holds %s, which is neither its MANIFEST nor in a session folder"
                             % name)
        return
    session = result.sessions.setdefault(sid, _Session())
    if len(parts) == 2:
        session.problems.append("the archive holds an entry for its folder")
        return
    entry = "/".join(parts[2:])
    if entry in session.names:
        session.problems.append("%s is in the archive twice" % entry)
        return
    session.names.add(entry)
    mode = info.mode & 0o7777
    if len(parts) > 3:
        session.problems.append("%s is not covered by the seal" % entry)
    elif info.issym():
        session.problems.append("%s is a symlink" % entry)
    elif info.islnk():
        session.problems.append("%s is a hard link" % entry)
    elif not regular:
        session.problems.append("%s is not a regular file" % entry)
    elif entry in ("SHA256SUMS", "SEAL") and info.size > _SMALL_MAX:
        session.problems.append("%s is larger than %d bytes" % (entry, _SMALL_MAX))
        session.files[entry] = _Member(mode, "", None)
    else:
        digest, data = _member_data(tar, info, entry in ("SHA256SUMS", "SEAL"))
        session.files[entry] = _Member(mode, digest, data)


def _findings(sid, session, manifest):
    """Return what makes the archived session SID changed by the rules of tlogger verify, one
    message each, without the id; none when it is ok. MANIFEST is the archived one."""
    found = list(session.problems)
    sums = session.files.get("SHA256SUMS")
    seal = session.files.get("SEAL")
    listed = set()
    if sums is None:
        if "SHA256SUMS" not in session.names:
            found.append("SHA256SUMS is missing")
    elif sums.data is not None:
        for line in _lines(sums.data):
            match = _SUM_LINE.fullmatch(line)
            if not match:
                found.append("SHA256SUMS holds a line that is not a sum")
                continue
            entry = match.group(2).decode("utf-8", "surrogateescape")
            if entry not in SEAL_FILES:
                found.append("SHA256SUMS names %s, which no session holds" % entry)
                continue
            listed.add(entry)
            member = session.files.get(entry)
            if member is None:
                if entry not in session.names:
                    found.append("%s is missing" % entry)
                continue
            if member.mode != 0o400:
                found.append("%s has mode %o, not 400" % (entry, member.mode))
            if member.digest != match.group(1).decode("ascii"):
                found.append("%s changed" % entry)
    for entry in ("SHA256SUMS", "SEAL"):
        member = session.files.get(entry)
        if member is not None and member.mode != 0o400:
            found.append("%s has mode %o, not 400" % (entry, member.mode))
    if seal is None and "SEAL" not in session.names:
        found.append("SEAL is missing")
    for entry in sorted(session.files):
        if entry not in listed and entry not in ("SHA256SUMS", "SEAL"):
            found.append("%s is not covered by the seal" % entry)
    if sums is not None and sums.data is not None and seal is not None and seal.data is not None:
        line = _manifest_sum(manifest, sid)
        if _seal_sum(seal.data) != sums.digest.encode("ascii"):
            found.append("SHA256SUMS does not match its SEAL")
        elif line is None:
            found.append("no line in the archived MANIFEST names this session")
        elif line != sums.digest.encode("ascii"):
            found.append("SHA256SUMS does not match its line in the archived MANIFEST")
    return found


def check_archive(fd, shown):
    """Read the archive in the open file FD, which messages call SHOWN, as a stream, and return
    an ArchiveCheck of it. Writes nothing.

    A file that is not gzip, is cut short, holds no tar or no session raises Failure. A byte
    other than 0 after the end of the tar, in the same gzip stream or in one appended to it, is
    a fault; so is every member that belongs to no session and is not the one MANIFEST.
    """
    result = ArchiveCheck()
    reader = _Gunzip(fd, shown)
    try:
        with tarfile.open(fileobj=reader, mode="r|") as tar:
            for info in tar:
                _take(tar, info, result)
            end = tar.offset
        reader.drain()
    except Failure:
        raise
    except (tarfile.TarError, EOFError):
        if reader.error is not None:
            raise reader.error
        raise Failure("%s holds no tar data that tlogger can read" % shown)
    if reader.error is not None:
        raise reader.error
    if reader.last_data >= end:
        result.faults.append("bytes other than 0 follow the end of its tar data")
    if not result.sessions:
        raise Failure("%s holds no session" % shown)
    result.digest = reader.digest.hexdigest()
    for sid, session in result.sessions.items():
        result.findings[sid] = _findings(sid, session, result.manifest)
    return result


def _open_archive(path, shown):
    """Open the archive PATH, shown as SHOWN, for reading and return its fd: a regular file."""
    try:
        fd = os.open(path, os.O_RDONLY | _O_NONBLOCK | _O_CLOEXEC | _O_BINARY)
    except FileNotFoundError:
        raise Failure("%s does not exist" % shown)
    except OSError as error:
        raise Failure("cannot read %s: %s" % (shown, error.strerror))
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        os.close(fd)
        raise Failure("%s is not a regular file" % shown)
    if _O_NONBLOCK:
        os.set_blocking(fd, True)
    return fd


def _check_sidecar(path, shown, result):
    """Check the .sha256 file beside the archive PATH, shown as SHOWN, against RESULT: it must
    hold the one line '<SHA-256>  <file name>', else that is a fault of RESULT. Returns the note
    for a missing one, else None."""
    want = ("%s  %s\n" % (result.digest, os.path.basename(path))).encode()
    try:
        fd = os.open(path + ".sha256", _O_READ)
    except FileNotFoundError:
        return ("%s.sha256 is missing; compare the archive's SHA-256, %s, with the one archive"
                " printed" % (shown, result.digest))
    except OSError as error:
        result.faults.append("its .sha256 file cannot be read: %s" % error.strerror)
        return None
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            result.faults.append("its .sha256 file is not a regular file")
        elif _read_upto(fd, _SIDECAR_MAX) != want:
            result.faults.append("its .sha256 file does not hold '%s'" % want.decode().rstrip())
    finally:
        os.close(fd)
    return None


def _read_small(path):
    """Return the bytes of the regular file PATH, read without following a symlink, at most
    _MANIFEST_MAX of them; None when it is missing; raise OSError when it cannot be read, and
    ValueError when it is not a regular file."""
    try:
        fd = os.open(path, _O_READ)
    except FileNotFoundError:
        return None
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise ValueError(path)
        return _read_upto(fd, _MANIFEST_MAX)
    finally:
        os.close(fd)


def _live_problem(folder, result):
    """Return why the MANIFEST bytes of RESULT are not a byte prefix of FOLDER/MANIFEST, read
    without following a symlink, a missing one holding none; None when they are; and False when
    FOLDER has no tie to RESULT, so that the archive is not of it: it is no folder, or its
    MANIFEST names none of RESULT's sessions, its PRUNED records none, and it holds none of
    them. On the computer that made the archive the folder keeps such a tie, as the MANIFEST
    only grows and prune records what it removes; a MANIFEST emptied or removed there is a
    fault, not a reason to pass over it."""
    try:
        if not stat.S_ISDIR(os.lstat(folder).st_mode):
            return False
    except OSError:
        return False
    live = os.path.join(folder, "MANIFEST")
    try:
        data = _read_small(live)
    except ValueError:
        return "%s is not a regular file" % _shown(live)
    except OSError as error:
        return "cannot read %s: %s" % (_shown(live), error.strerror)
    sids = set(result.sessions)
    ends = tuple(("  %s/SHA256SUMS" % sid).encode() for sid in sids)
    tied = data is not None and any(line.endswith(ends) for line in _lines(data))
    if not tied:
        try:
            pruned = _read_small(os.path.join(folder, "PRUNED"))
        except (OSError, ValueError):
            pruned = None
        if pruned is not None:
            for line in _lines(pruned):
                fields = line.split(b"  ")
                if len(fields) > 1 and fields[1].decode("ascii", "replace") in sids:
                    tied = True
                    break
    if not tied:
        tied = any(os.path.lexists(os.path.join(folder, sid)) for sid in sids)
    if not tied:
        return False
    if not (data or b"").startswith(result.manifest):
        return "its MANIFEST is not the start of %s" % _shown(live)
    return None


def _check_live(logdir, result):
    """Make it a fault of RESULT that its archived MANIFEST starts the MANIFEST of none of the
    folders of LOGDIR that its <name> may name: the engagement folder <name>, and LOGDIR itself
    when <name> is the last part of its path, as archive --none names its archives. A folder
    with no tie to the archive (see _live_problem), as on another computer, is not compared."""
    name = result.name
    if logdir is None or result.manifest is None or not name:
        return
    folders = []
    if _engagement_ok(name):
        folders.append(os.path.join(logdir, name))
    if os.path.basename(logdir.rstrip("/")) == name:
        folders.append(logdir)
    problems = [p for p in (_live_problem(f, result) for f in folders) if p is not False]
    if problems and None not in problems:
        result.faults.extend(problems)


def report_check(result, label):
    """Print the faults of RESULT after LABEL, then the findings of each session after its id,
    on stderr, as 'tlogger: ...' lines."""
    for fault in result.faults:
        _say("%s: %s" % (label, fault))
    for sid in sorted(result.findings):
        for finding in result.findings[sid]:
            _say("%s: %s" % (sid, finding))


def cmd_archive_check(args):
    """tlogger_view.py archive-check [--logdir LOGDIR] [--] FILE: check the archive FILE.

    Prints '<id>  ok' or '<id>  changed' for each session it holds, by id, and the reasons on
    stderr. With LOGDIR, an archive named after an engagement folder there must hold a MANIFEST
    that is the start of that folder's. Returns 0 when every session is ok, else 1.
    """
    logdir = None
    files = []
    rest = list(args)
    while rest:
        arg = rest.pop(0)
        if arg == "--logdir":
            if not rest:
                raise UsageError("--logdir needs a folder")
            logdir = rest.pop(0)
        elif arg == "--":
            files.extend(rest)
            rest = []
        elif arg.startswith("-"):
            raise UsageError("unknown option for archive-check: %s" % arg)
        else:
            files.append(arg)
    if len(files) != 1:
        raise UsageError("archive-check takes one file")
    path = files[0]
    shown = _shown(path)
    fd = _open_archive(path, shown)
    try:
        result = check_archive(fd, shown)
    finally:
        os.close(fd)
    note = _check_sidecar(path, shown, result)
    _check_live(logdir, result)
    report_check(result, os.path.basename(path) or path)
    if note:
        _say(note)
    sink = Sink(1)
    for sid in sorted(result.sessions):
        sink.write(("%s  %s\n" % (sid, result.verdict(sid))).encode())
    sink.flush()
    return 0 if result.ok() else 1


def _starts_live(folder, manifest):
    """Return True when the bytes MANIFEST are a byte prefix of FOLDER/MANIFEST, which is read
    without following a symlink; a missing one has no bytes. Raises Failure when it cannot be
    read."""
    live = os.path.join(folder, "MANIFEST")
    try:
        fd = os.open(live, _O_READ)
    except FileNotFoundError:
        return not manifest
    except OSError as error:
        raise Failure("cannot read %s: %s" % (_shown(live), error.strerror))
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            return False
        return _read_upto(fd, len(manifest)) == manifest
    finally:
        os.close(fd)


def cmd_prune_check(args):
    """tlogger_view.py prune-check --name NAME --folder FOLDER [--logdir LOGDIR] [--] FILE:
    check the archive FILE for tlogger prune of the folder FOLDER, whose name is NAME.

    It runs the whole check of archive-check, LOGDIR as there, then asks that the archive holds
    the folder NAME and a MANIFEST that is a byte prefix of FOLDER/MANIFEST. A failure prints one
    line on stderr and returns 1. Else it prints, tab-separated, 'archive <SHA-256 of FILE>',
    then for each session by id 'session <id> <SHA-256 of its SHA256SUMS>' and 'file <id>
    <entry> <SHA-256>' for each file its SHA256SUMS lists, in that order, then for SHA256SUMS
    and SEAL; the note about a missing .sha256 file goes to stderr, and it returns 0. Writes
    nothing.
    """
    name = folder = logdir = None
    files = []
    rest = list(args)
    while rest:
        arg = rest.pop(0)
        if arg in ("--name", "--folder", "--logdir"):
            if not rest:
                raise UsageError("%s needs a value" % arg)
            value = rest.pop(0)
            if arg == "--name":
                name = value
            elif arg == "--folder":
                folder = value
            else:
                logdir = value
        elif arg == "--":
            files.extend(rest)
            rest = []
        elif arg.startswith("-"):
            raise UsageError("unknown option for prune-check: %s" % arg)
        else:
            files.append(arg)
    if not name or not folder:
        raise UsageError("prune-check needs --name and --folder")
    if len(files) != 1:
        raise UsageError("prune-check takes one file")
    path = files[0]
    shown = _shown(path)
    fd = _open_archive(path, shown)
    try:
        result = check_archive(fd, shown)
    finally:
        os.close(fd)
    note = _check_sidecar(path, shown, result)
    _check_live(logdir, result)
    if not result.ok():
        raise Failure("the archive %s fails its check; tlogger archive --verify %s says why"
                      % (shown, shown))
    if result.name != name:
        raise Failure("the archive %s is not of %s: it holds the folder %s"
                      % (shown, _shown(folder), result.name))
    if result.manifest is None or not _starts_live(folder, result.manifest):
        raise Failure("the archive %s is not of %s: its MANIFEST is not the start of %s"
                      % (shown, _shown(folder), _shown(os.path.join(folder, "MANIFEST"))))
    if note:
        _say(note)
    sink = Sink(1)
    sink.write(("archive\t%s\n" % result.digest).encode())
    for sid in sorted(result.sessions):
        members = result.sessions[sid].files
        sums = members["SHA256SUMS"]
        sink.write(("session\t%s\t%s\n" % (sid, sums.digest)).encode())
        entries = []
        for line in _lines(sums.data):
            entries.append(_SUM_LINE.fullmatch(line).group(2).decode("ascii"))
        for entry in entries + ["SHA256SUMS", "SEAL"]:
            sink.write(("file\t%s\t%s\t%s\n" % (sid, entry, members[entry].digest)).encode())
    sink.flush()
    return 0


class _HashingWriter:
    """Write to the file FD, hashing every byte written."""

    def __init__(self, fd):
        self.fd = fd
        self.digest = hashlib.sha256()

    def write(self, data):
        """Write all of DATA and return its length."""
        self.digest.update(data)
        _write_all(self.fd, data)
        return len(data)

    def flush(self):
        """Nothing to flush: write leaves nothing behind."""


def _open_folder(path, private=False):
    """Open the folder PATH, a real folder of this user's, not through a symlink, and return its
    fd; with PRIVATE its mode must be 0700."""
    shown = _shown(path)
    try:
        fd = os.open(path, os.O_RDONLY | _O_DIRECTORY | _O_NOFOLLOW | _O_CLOEXEC)
    except OSError as error:
        raise Failure("cannot open %s: %s" % (shown, error.strerror))
    info = os.fstat(fd)
    problem = None
    if not stat.S_ISDIR(info.st_mode):
        problem = "is not a folder"
    elif info.st_uid != os.geteuid():
        problem = "belongs to another user"
    elif private and stat.S_IMODE(info.st_mode) != 0o700:
        problem = "has mode %o, not 700" % stat.S_IMODE(info.st_mode)
    if problem:
        os.close(fd)
        raise Failure("%s %s" % (shown, problem))
    return fd


def _open_at(dfd, name, path, folder=False):
    """Open NAME in the folder DFD for reading, never through a symlink, and return its fd and
    stat. PATH names it in messages. It must be this user's, and with FOLDER a folder, else a
    regular file with one link."""
    shown = _shown(path)
    flags = _O_READ | (_O_DIRECTORY if folder else 0)
    try:
        fd = os.open(name, flags, dir_fd=dfd)
    except OSError as error:
        if error.errno == errno.ELOOP:
            raise Failure("%s is a symlink, which tlogger does not follow" % shown)
        raise Failure("cannot read %s: %s" % (shown, error.strerror))
    info = os.fstat(fd)
    problem = None
    if not (stat.S_ISDIR if folder else stat.S_ISREG)(info.st_mode):
        problem = "is not a folder" if folder else "is not a regular file"
    elif info.st_uid != os.geteuid():
        problem = "belongs to another user"
    elif not folder and info.st_nlink != 1:
        problem = "has more than one hard link"
    if problem:
        os.close(fd)
        raise Failure("%s %s" % (shown, problem))
    if _O_NONBLOCK:
        os.set_blocking(fd, True)
    return fd, info


def _member_info(name, info, size):
    """Return the TarInfo of a regular member NAME of SIZE bytes with the mode and the time in
    whole seconds of the stat INFO, owner and group 0 and no user or group name."""
    member = tarfile.TarInfo(name)
    member.type = tarfile.REGTYPE
    member.size = size
    member.mode = stat.S_IMODE(info.st_mode)
    member.mtime = info.st_mtime_ns // 1000000000
    member.uid = member.gid = 0
    member.uname = member.gname = ""
    return member


def _add_small(tar, dfd, entry, path, member, limit):
    """Add the file ENTRY of the folder DFD, at PATH, to TAR as the member MEMBER, and return its
    bytes; it must be no larger than LIMIT."""
    fd, info = _open_at(dfd, entry, path)
    try:
        data = _read_upto(fd, limit + 1)
    finally:
        os.close(fd)
    if len(data) > limit:
        raise Failure("%s is larger than %d bytes" % (_shown(path), limit))
    tar.addfile(_member_info(member, info, len(data)), io.BytesIO(data))
    return data


def _add_session(tar, fdfd, folder, name, sid):
    """Add the session SID of the folder FDFD, at FOLDER, to TAR under NAME: the files its
    SHA256SUMS lists, in that order, then SHA256SUMS and SEAL."""
    path = os.path.join(folder, sid)
    sfd, _ = _open_at(fdfd, sid, path, folder=True)
    try:
        fd, info = _open_at(sfd, "SHA256SUMS", os.path.join(path, "SHA256SUMS"))
        try:
            sums = _read_upto(fd, _SMALL_MAX + 1)
        finally:
            os.close(fd)
        if len(sums) > _SMALL_MAX:
            raise Failure("session %s: its SHA256SUMS is larger than %d bytes" % (sid, _SMALL_MAX))
        for line in _lines(sums):
            match = _SUM_LINE.fullmatch(line)
            entry = match.group(2).decode("utf-8", "surrogateescape") if match else None
            if entry not in SEAL_FILES:
                raise Failure("session %s: its SHA256SUMS holds a line that names no log" % sid)
            entry_path = os.path.join(path, entry)
            fd, entry_info = _open_at(sfd, entry, entry_path)
            try:
                with os.fdopen(fd, "rb", closefd=False) as source:
                    tar.addfile(_member_info("%s/%s/%s" % (name, sid, entry), entry_info,
                                             entry_info.st_size), source)
            except OSError as error:
                raise Failure("cannot read %s: %s" % (_shown(entry_path), error.strerror
                                                      or "it changed while archive read it"))
            finally:
                os.close(fd)
        tar.addfile(_member_info("%s/%s/SHA256SUMS" % (name, sid), info, len(sums)),
                    io.BytesIO(sums))
        _add_small(tar, sfd, "SEAL", os.path.join(path, "SEAL"), "%s/%s/SEAL" % (name, sid),
                   _SMALL_MAX)
    finally:
        os.close(sfd)


def _write_tar(sink, fdfd, folder, name, ids):
    """Write the archive of the sessions IDS of the folder FDFD, at FOLDER, under NAME to SINK,
    as one gzip stream, and return the bytes of the MANIFEST it holds."""
    gz = gzip.GzipFile(filename="", mode="wb", compresslevel=6, fileobj=sink, mtime=0)
    try:
        tar = tarfile.open(fileobj=gz, mode="w", format=tarfile.PAX_FORMAT)
        try:
            manifest = _add_small(tar, fdfd, "MANIFEST", os.path.join(folder, "MANIFEST"),
                                  name + "/MANIFEST", _MANIFEST_MAX)
            for sid in ids:
                _add_session(tar, fdfd, folder, name, sid)
        finally:
            tar.close()
    finally:
        gz.close()
    return manifest


def _create_temp(dfd, base, made):
    """Create a new temp file for the file BASE in the folder DFD, mode 0600, add its name to
    MADE and return the name and an fd that writes it. The signals of _STOP_SIGNALS wait while it
    is created, so that none comes between its creation and its name in MADE."""
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | _O_NOFOLLOW | _O_CLOEXEC | _O_BINARY
    for _ in range(100):
        part = ".%s.part.%s" % (base, "".join(secrets.choice(_TOKEN) for _ in range(6)))
        signal.pthread_sigmask(signal.SIG_BLOCK, _STOP_SIGNALS)
        try:
            fd = os.open(part, flags, 0o600, dir_fd=dfd)
            made.append(part)
        except FileExistsError:
            continue
        finally:
            # A signal that came meanwhile raises Stop here, once the name is in MADE.
            signal.pthread_sigmask(signal.SIG_UNBLOCK, _STOP_SIGNALS)
        return part, fd
    raise Failure("cannot create a temp file for %s" % base)


def _finish_part(fd, fds):
    """Sync the temp file FD to the disk, set its mode to 0400 and close it, taking it out of
    FDS."""
    os.fsync(fd)
    os.fchmod(fd, 0o400)
    fds.remove(fd)
    os.close(fd)


def _link(dfd, part, base, path, made):
    """Give the file PART of the folder DFD its name BASE, at PATH, by a link, which never
    replaces a file, and add BASE to MADE."""
    try:
        os.link(part, base, src_dir_fd=dfd, dst_dir_fd=dfd)
    except FileExistsError:
        raise Failure("%s exists already; archive never replaces a file" % _shown(path))
    made.append(base)


def _check_written(dfd, part, out, name, ids, manifest, digest):
    """Check the archive just written to the file PART of the folder DFD, for OUT: whole, every
    session of IDS ok and no other, named NAME, with the MANIFEST bytes MANIFEST and the SHA-256
    DIGEST. Raises Failure, after the reasons, when it is not."""
    shown = _shown(out)
    fd = os.open(part, os.O_RDONLY | _O_NOFOLLOW | _O_CLOEXEC, dir_fd=dfd)
    try:
        result = check_archive(fd, shown)
    finally:
        os.close(fd)
    if (result.ok() and result.name == name and result.manifest == manifest
            and result.digest == digest and sorted(result.sessions) == sorted(ids)):
        return
    report_check(result, os.path.basename(out))
    raise Failure("the archive written for %s fails its check, so archive keeps nothing; a log"
                  " may have changed meanwhile: tlogger verify --all names it" % shown)


def archive_write(name, out, folder, ids):
    """Write the archive OUT of the sessions IDS of FOLDER, under NAME, and OUT.sha256, both
    mode 0400, and return the archive's SHA-256.

    The folder of OUT must be a real folder of this user's with mode 0700. Each file is written
    to a new temp name there, synced and set to 0400; the archive is read back through
    check_archive before it gets its name by a link, which never replaces a file, and the temp
    names are removed. On any failure or signal, every name this run made goes again. The logs
    are only read, never through a symlink, and must be regular files with one link.
    """
    folder_of_out, base = os.path.split(out)
    side = base + ".sha256"
    adfd = _open_folder(folder_of_out or ".", private=True)
    fds = [adfd]
    made = []
    try:
        fdfd = _open_folder(folder)
        fds.append(fdfd)
        part, fd = _create_temp(adfd, base, made)
        fds.append(fd)
        sink = _HashingWriter(fd)
        manifest = _write_tar(sink, fdfd, folder, name, ids)
        _finish_part(fd, fds)
        digest = sink.digest.hexdigest()
        _check_written(adfd, part, out, name, ids, manifest, digest)
        side_part, fd = _create_temp(adfd, side, made)
        fds.append(fd)
        _write_all(fd, ("%s  %s\n" % (digest, base)).encode())
        _finish_part(fd, fds)
        _link(adfd, part, base, out, made)
        _link(adfd, side_part, side, out + ".sha256", made)
        for entry in (part, side_part):
            os.unlink(entry, dir_fd=adfd)
            made.remove(entry)
        os.fsync(adfd)
        made = []
    except BaseException:
        _ignore_signals()
        for entry in reversed(made):
            try:
                os.unlink(entry, dir_fd=adfd)
            except OSError:
                pass
        raise
    finally:
        for fd in fds:
            os.close(fd)
    return digest


def cmd_archive_write(args):
    """tlogger_view.py archive-write --name NAME --out FILE [--] FOLDER ID...: write the archive
    FILE of the sessions IDS of FOLDER under NAME, and FILE.sha256, and print its SHA-256."""
    options = {"--name": None, "--out": None}
    positional = []
    rest = list(args)
    while rest:
        arg = rest.pop(0)
        if arg in options:
            if not rest:
                raise UsageError("%s needs a value" % arg)
            options[arg] = rest.pop(0)
        elif arg == "--":
            positional.extend(rest)
            rest = []
        elif arg.startswith("-"):
            raise UsageError("unknown option for archive-write: %s" % arg)
        else:
            positional.append(arg)
    name, out = options["--name"], options["--out"]
    if not name or name in (".", "..") or "/" in name:
        raise UsageError("archive-write needs --name and a name without a /")
    if not out:
        raise UsageError("archive-write needs --out")
    if len(positional) < 2:
        raise UsageError("archive-write takes a folder and one session id or more")
    folder, ids = positional[0], positional[1:]
    for sid in ids:
        if not _SESSION_ID.fullmatch(sid):
            raise UsageError("'%s' is not a session id" % sid)
    if len(set(ids)) != len(ids):
        raise UsageError("archive-write takes each session once")
    digest = archive_write(name, out, folder, ids)
    _write_all(1, (digest + "\n").encode())
    return 0


def _where(error):
    """Return where ERROR happened: 'FILE line N' of the innermost frame of its traceback.

    FILE comes without its folder, so that the message of an internal error names no path.
    """
    trace = error.__traceback__
    while trace is not None and trace.tb_next is not None:
        trace = trace.tb_next
    if trace is None:
        return "an unknown line"
    name = os.path.basename(trace.tb_frame.f_code.co_filename)
    return "%s line %d" % (name, trace.tb_lineno)


def main(argv):
    """Run the command in ARGV and return the exit status: 0 done, 1 error, 2 usage error.

    A signal of _STOP_SIGNALS returns 128 plus its number. Every error prints one 'tlogger: '
    line on stderr and no traceback; an unexpected one names its type and line, but no path.
    """
    _catch_signals()
    try:
        if not argv:
            raise UsageError("no command given")
        command, args = argv[0], argv[1:]
        if command == "probe":
            return cmd_probe(args)
        if command == "render":
            return cmd_render(args)
        if command == "replay-timing":
            return cmd_replay_timing(args)
        if command == "filter":
            return cmd_filter(args)
        if command == "archive-write":
            return cmd_archive_write(args)
        if command == "archive-check":
            return cmd_archive_check(args)
        if command == "prune-check":
            return cmd_prune_check(args)
        raise UsageError("unknown command: %s" % command)
    except UsageError as error:
        _say(str(error))
        sys.stderr.write(USAGE)
        return 2
    except Failure as error:
        _say(str(error))
        return 1
    except Stop as stop:
        return 128 + stop.signum
    except BrokenPipeError:
        return 1
    except OSError as error:
        _say("%s failed: %s" % (argv[0], error.strerror or type(error).__name__))
        return 1
    except Exception as error:
        _say("internal error at %s: %s" % (_where(error), type(error).__name__))
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
