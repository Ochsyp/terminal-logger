# tlogger_view.py: the Python part of tlogger render, show and replay. render turns a session's
# output.raw and timing into a plain-text transcript through a pyte screen; for replay, filter
# keeps only an allow-list of terminal output and replay-timing cleans the timing for scriptreplay.
# bin/tlogger runs it as '/usr/bin/python3 -I tlogger_view.py <command>'; stdlib and pyte only.

import bisect
import codecs
import copy
import os
import re
import select
import signal
import stat
import sys
import time
import unicodedata

USAGE = """\
usage: tlogger_view.py probe [--pyte]
       tlogger_view.py render --version VERSION [--stdout] [--] SESSION_FOLDER
       tlogger_view.py replay-timing < TIMING
       tlogger_view.py filter
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

# Token kinds: printable text, a C0 control, an escape sequence and a control sequence (CSI).
TEXT, CTRL, ESC, CSI = range(4)

# A sequence or control string that reaches this many UTF-8 bytes without its end, counted from
# its first byte, is dropped, and parsing goes on in the ground state with the next character.
CAP = 4096

# Tokenizer states: ground, escape, control sequence, control string and an ESC inside a string.
_GROUND, _ESCAPE, _CSI, _STRING, _STRING_ESC = range(5)

# The characters that end a run of text: C0 controls, DEL and C1 controls.
_SPECIAL = re.compile("[\x00-\x1f\x7f-\x9f]")

# The characters that end or break a control string: CAN, SUB, ESC, the C1 string and sequence
# introducers and ST; for OSC also BEL.
_STRING_STOP = re.compile("[\x18\x1a\x1b\x90\x98\x9b-\x9f]")
_OSC_STOP = re.compile("[\x07\x18\x1a\x1b\x90\x98\x9b-\x9f]")


def _u8len(ch):
    """Return the number of bytes the character CH takes in UTF-8."""
    code = ord(ch)
    if code < 0x80:
        return 1
    if code < 0x800:
        return 2
    return 3 if code < 0x10000 else 4


class Tokenizer:
    """Split terminal output, decoded to str, into tokens, keeping its state across feed calls.

    feed returns a list of tokens: (TEXT, run) for printable characters; (CTRL, char) for a C0
    control other than ESC, CAN and SUB; (ESC, intermediates, final); and (CSI, parameters,
    intermediates, final, c1), c1 true when U+009B introduced it. OSC, DCS, SOS, PM and APC
    strings, introduced by ESC or by their C1 controls and ended by ST (ESC \\ or U+009C), BEL
    for OSC, yield nothing. DEL, CAN, SUB, a stray ST and every other C1 control are dropped. A
    C0 control inside a sequence is executed: its token comes before the sequence's, as on a
    DEC terminal. ESC, CAN, SUB, a C1 control or a character above ASCII inside a sequence ends
    it unfinished; such a character is then read again in the ground state. A sequence or string
    that reaches CAP bytes is dropped, and the next character starts afresh in the ground state.
    """

    def __init__(self):
        self.state = _GROUND
        self.size = 0
        self.inter = ""
        self.params = ""
        self.c1 = False
        self.bad = False
        self.osc = False

    def _begin(self, state, size, c1=False, osc=False):
        """Start a sequence or string in STATE whose introducer took SIZE bytes."""
        self.state = state
        self.size = size
        self.inter = ""
        self.params = ""
        self.c1 = c1
        self.bad = False
        self.osc = osc

    def _grow(self, count):
        """Count COUNT more bytes of the sequence; drop it at the cap. Returns False."""
        self.size += count
        if self.size >= CAP:
            self.state = _GROUND
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
            else:
                self.params += ch
            return self._grow(1)
        if 0x20 <= code <= 0x2F:
            self.inter += ch
            return self._grow(1)
        if 0x40 <= code <= 0x7E:
            if not self.bad:
                out.append((CSI, self.params, self.inter, ch, self.c1))
            self.state = _GROUND
            return False
        return self._interrupt(ch, out)

    def _string(self, text, i, out):
        """Read the control string in TEXT from index I on. Returns the next index to read."""
        match = (_OSC_STOP if self.osc else _STRING_STOP).search(text, i)
        end = len(text) if match is None else match.start()
        if end > i:
            run = text[i:end]
            size = self.size + len(run.encode("utf-8", "surrogatepass"))
            if size >= CAP:
                size = self.size
                for k, ch in enumerate(run):
                    size += _u8len(ch)
                    if size >= CAP:
                        self.state = _GROUND
                        return i + k + 1
            self.size = size
        if match is None:
            return end
        ch = text[end]
        if ch == "\x1b":
            self.state = _STRING_ESC
            self._grow(1)
            return end + 1
        self.state = _GROUND
        if ch not in "\x07\x18\x1a\x9c":
            # A C1 introducer ends the string unfinished and starts its own sequence.
            self._control(ch, out)
        return end + 1

    def _string_esc(self, ch, out):
        """Read CH after an ESC inside a control string. Returns True to read CH again."""
        if ch == "\\":
            self.state = _GROUND
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
    the control sequences that _filter_csi passes. Everything else is dropped.
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
        else:
            out.append(_filter_csi(token[1], token[2], token[3], token[4]))
    return "".join(out)


def cmd_filter(args):
    """tlogger_view.py filter: copy stdin to stdout through the allow-list, then RESTORE.

    Reads and writes unbuffered, with os.read and os.write. Bytes that are not valid UTF-8 are
    dropped, raw C1 bytes among them. RESTORE follows the end of input and each signal of
    _STOP_SIGNALS; Stop then leaves through main with 128 plus the signal number.
    """
    if args:
        raise UsageError("filter takes no arguments")
    decoder = codecs.getincrementaldecoder("utf-8")(errors="ignore")
    tokenizer = Tokenizer()
    sink = Sink(1)
    try:
        while True:
            data = os.read(0, 65536)
            if not data:
                break
            text = filter_tokens(tokenizer.feed(decoder.decode(data)))
            if text:
                sink.write(text.encode("utf-8"))
                sink.flush()
        text = filter_tokens(tokenizer.feed(decoder.decode(b"", True)))
        tokenizer.finish()
        sink.write(text.encode("utf-8"))
        sink.flush()
    finally:
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
        else:
            screen.csi(token[1], token[2], token[3])


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
