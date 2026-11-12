#!/usr/bin/env bats
# Tests for the replay filter of libexec/tlogger_view.py, run as bin/tlogger runs it, python3 -I
# on the file, in a pipe and without a terminal: each class of terminal output that its allow-list
# passes or drops, the size cap, sequences split across reads, and the restore sequence that it
# writes at the end of its input and on SIGINT, SIGQUIT and SIGTERM.

bats_require_minimum_version 1.5.0

load helpers

# Run before each test by bats.
# Gives the test its own home and the files that hold what the filter wrote and printed on stderr.
setup() {
    isolate_home
    need python3
    GOT="$BATS_TEST_TMPDIR/got"
    WANT="$BATS_TEST_TMPDIR/want"
    ERRORS="$BATS_TEST_TMPDIR/errors"
}

# Fail, showing both with od -c, unless WANT and GOT hold the same bytes, the filter exited with
# STATUS and printed nothing on stderr.
compare_filtered() {
    if [[ $1 != 0 ]] || ! cmp -s "$WANT" "$GOT" || [[ -s $ERRORS ]]; then
        printf 'the filter exited with status %s; it should write, then wrote:\n' "$1" >&2
        od -c "$WANT" >&2
        od -c "$GOT" >&2
        cat "$ERRORS" >&2
        return 1
    fi
}

# Pipe the bytes that printf %b makes of INPUT through the filter into a pipe, and fail unless it
# exits 0 and writes the bytes that printf %b makes of OUTPUT, then FILTER_RESTORE.
assert_filtered() {
    local -a codes
    printf '%b' "$1" | "$PYTHON3" -I "$VIEW" filter 2> "$ERRORS" | cat > "$GOT"
    codes=("${PIPESTATUS[@]}")
    { printf '%b' "$2"; printf '%s' "$FILTER_RESTORE"; } > "$WANT"
    compare_filtered "${codes[1]}"
}

# Wait at most 10 seconds until FILE holds at least BYTES bytes; fail when it does not.
wait_for_size() {
    local i
    for (( i = 0; i < 200; i++ )); do
        if [[ -f $1 ]] && (( $(wc -c < "$1") >= $2 )); then
            return 0
        fi
        sleep 0.05
    done
    printf '%s did not reach %s bytes within 10 seconds\n' "$1" "$2" >&2
    return 1
}

@test "an empty input gives the restore sequence alone" {
    assert_filtered '' ''
}

@test "text, UTF-8 above ASCII, BS, HT, LF and CR pass as they are" {
    assert_filtered 'plain text\tafter a tab\bX\r\ncaf\xc3\xa9 \xe2\x94\x80 \xe6\xbc\xa2 \xf0\x9f\x94\x92\r\n' \
        'plain text\tafter a tab\bX\r\ncaf\xc3\xa9 \xe2\x94\x80 \xe6\xbc\xa2 \xf0\x9f\x94\x92\r\n'
}

@test "CSI with an allowed final and plain parameters passes as it is" {
    local final in=''
    for final in @ A B C D E F G H J K L M P S T X d f m r s u '`'; do
        in+="\\e[2$final"
    done
    in+='\e[m\e[1;31mred\e[0m\e[38:2::255:0:0m\e[38;5;196m\e[10;20H\e[;5H\e[3;20r'
    assert_filtered "$in" "$in"
}

@test "CSI S and T pass with one parameter or none; with more they are dropped (T with five is a mouse report)" {
    assert_filtered 'a\e[2Sb\e[Sc\e[3Td\e[Te' 'a\e[2Sb\e[Sc\e[3Td\e[Te'
    assert_filtered 'a\e[1;2;3;4;5Tb\e[1;2Sc\e[1:2Td\e[;Se\e[1;Tf' 'abcdef'
}

@test "ESC 7, ESC 8, ESC D, ESC E, ESC M and the G0 and G1 designations of B and 0 pass" {
    assert_filtered 'a\e7b\e8c\eDd\eEe\eMf\e(Bg\e(0h\e)Bi\e)0j' 'a\e7b\e8c\eDd\eEe\eMf\e(Bg\e(0h\e)Bi\e)0j'
}

@test "CSI 3 J, which would erase the scrollback of the terminal that replays, is dropped" {
    # clear sends ED 2, then ED 3; only ED 2 reaches the terminal.
    assert_filtered 'a\e[H\e[2J\e[3Jb\e[03Jc\e[3;1Jd\e[3:1Je\e[Jf\e[1J' 'a\e[H\e[2Jbcde\e[Jf\e[1J'
}

@test "CSI h and l keep only the modes 4, ?7, ?12, ?25, ?47, ?1047, ?1048 and ?1049" {
    local mode in=''
    for mode in 4 '?7' '?12' '?25' '?47' '?1047' '?1048' '?1049'; do
        in+="\\e[${mode}h\\e[${mode}l"
    done
    assert_filtered "$in" "$in"
    # Mouse, focus, bracketed paste, cursor keys, 132 columns, reverse video, smooth scrolling,
    # LNM and the other ANSI modes are dropped, alone or among allowed ones.
    assert_filtered 'a\e[?1000hb\e[?1002h\e[?1003h\e[?1005h\e[?1006h\e[?1015h\e[?9h\e[?1004hc\e[?2004hd\e[?1he\e[?3hf\e[?5hg\e[?4hh\e[20hi\e[12hj\e[?hk\e[h' \
        'abcdefghijk'
    assert_filtered '\e[?1049;1000;25h\e[?0025l\e[4;20h\e[?1000;1006l' '\e[?1049;25h\e[?25l\e[4h'
}

@test "OSC strings are dropped up to BEL, ST or a C1 ST: titles, OSC 7, OSC 8 and OSC 52" {
    assert_filtered 'a\e]0;kali@kali: ~\ab\e]2;title\e\\c\e]52;c;aGVsbG8=\ad\e]8;;https://192.0.2.10/\alink\e]8;;\e\\e\e]7;file://kali/home/kali\af\xc2\x9d0;c1 osc\xc2\x9cg\e]1;x\xc2\x9ch' \
        'abcdlinkefgh'
}

@test "DCS, SOS, PM and APC strings are dropped up to ST, DECRQSS among them, BEL inside included" {
    # shellcheck disable=SC2016 # $q is part of DECRQSS, not an expansion.
    assert_filtered 'a\eP$qm\e\\b\eP1;1|17/ab\e\\c\eXsos\e\\d\e^pm\e\\e\e_apc\e\\f\ePdcs\abel\e\\g\xc2\x90c1 dcs\xc2\x9ch' \
        'abcdefgh'
}

@test "control sequences that make a terminal answer, or act on its window, are dropped" {
    # Device attributes, status and cursor reports, window reports and resizes, DECREQTPARM,
    # cursor style, soft reset, DECRQM, XTVERSION, REP, tab clear, CBT, CHT, media copy and
    # sequences with a private marker or an intermediate byte.
    # shellcheck disable=SC2016 # $p is part of DECRQM, not an expansion.
    assert_filtered 'a\e[cb\e[0cc\e[>cd\e[=ce\e[6nf\e[5ng\e[?6nh\e[21ti\e[14tj\e[18tk\e[8;24;80tl\e[1xm\e[0 qn\e[!po\e[?1$pp\e[>0qq\e[5br\e[3gs\e[2Zt\e[2Iu\e[4iv\e[>4;1mw\e[?1Jx' \
        'abcdefghijklmnopqrstuvwx'
}

@test "escape sequences outside the allow-list are dropped" {
    # RIS, the keypad modes, DECALN, HTS, DECID, SS2, SS3, other character sets, DOCS, S7C1T,
    # DECBI and DECFI.
    assert_filtered 'a\ecb\e=c\e>d\e#8e\eHf\eZg\eNh\eOi\e(Aj\e%Gk\e Fl\e)Km\e6n\e9o' 'abcdefghijklmno'
}

@test "C0 controls but BS, HT, LF and CR are dropped, and so is DEL; CAN and SUB cut a sequence" {
    assert_filtered 'a\x00b\x01c\x07d\x0be\x0cf\x0eg\x0fh\x1ci\x7fj' 'abcdefghij'
    assert_filtered 'x\e[3\x18my\e]0;t\x1az' 'xmyz'
}

@test "every C1 control is dropped, raw or in UTF-8, and an 8-bit CSI with its sequence" {
    # A raw C1 byte is no UTF-8, so it goes alone; what follows it is text.
    assert_filtered 'a\x80b\x9b31mc\x9dd\xc2\x80e\xc2\x85f\xc2\x9b31mg\xc2\x9fapc\xc2\x9ch' 'ab31mcdefgh'
}

@test "a C0 control inside a sequence goes out first, and ESC inside a string starts a new one" {
    assert_filtered 'a\e[3\n1mX\e]0;title\e[31mred' 'a\n\e[31mX\e[31mred'
}

@test "a sequence, a string or a character split across two reads comes out whole" {
    local -a codes
    {
        printf '%b' 'a\e['
        sleep 0.3
        printf '%b' '1;31mb\e]0;ti'
        sleep 0.3
        printf '%b' 'tle\ac\xc3'
        sleep 0.3
        printf '%b' '\xa9\e'
        sleep 0.3
        printf '%b' '[0md'
    } | "$PYTHON3" -I "$VIEW" filter 2> "$ERRORS" | cat > "$GOT"
    codes=("${PIPESTATUS[@]}")
    printf '%b%s' 'a\e[1;31mbc\xc3\xa9\e[0md' "$FILTER_RESTORE" > "$WANT"
    compare_filtered "${codes[1]}"
}

@test "an unterminated string or sequence is dropped up to 4096 bytes, then the filter goes on" {
    local a5000 a908 pairs
    printf -v a5000 'A%.0s' {1..5000}
    printf -v a908 'A%.0s' {1..908}
    # ESC ], 0 and ; are 4 bytes, so the string ends with its 4092nd A.
    assert_filtered '\e]0;'"$a5000"'tail' "${a908}tail"
    # ESC and [ are 2 bytes, so the sequence ends with its 4094th parameter byte.
    printf -v pairs '1;%.0s' {1..3000}
    assert_filtered '\e['"$pairs"'Z' "${pairs:4094}Z"
}

@test "a string or sequence that the input leaves unfinished is dropped" {
    assert_filtered 'a\e]0;never ends' 'a'
    # shellcheck disable=SC2016 # $q is part of DECRQSS, not an expansion.
    assert_filtered 'b\eP$qm' 'b'
    assert_filtered 'c\e[1;2' 'c'
    assert_filtered 'd\e' 'd'
    assert_filtered 'e\xc3' 'e'
}

@test "a signal that cuts a write short makes the filter write RESTORE alone, not the chunk again" {
    # The harness runs the filter in-process, with an os.write that hands only CUT bytes of the
    # first big write to the descriptor and then raises SIGINT, as a signal does that comes
    # after a short write to a terminal. The cut falls inside ESC [ 6 m; sent again, the chunk
    # would start with an n, and the terminal would read ESC [ 6 n, a cursor position request.
    local code sgr full status=0
    code='import os, signal, sys
sys.path.insert(0, sys.argv[1])
import tlogger_view
cut = int(sys.argv[2])
class Proxy:
    fired = False
    def __getattr__(self, name):
        return getattr(os, name)
    def write(self, fd, data):
        if fd == 1 and not Proxy.fired and len(data) > cut:
            Proxy.fired = True
            os.write(fd, bytes(data[:cut]))
            signal.raise_signal(signal.SIGINT)
        return os.write(fd, data)
tlogger_view.os = Proxy()
sys.exit(tlogger_view.main(["filter"]))'
    printf -v sgr '\e[6m%.0s' {1..3000}
    full="n$sgr"
    printf '%s' "$full" > "$BATS_TEST_TMPDIR/input"
    "$PYTHON3" -I -B -c "$code" "$(dirname "$VIEW")" 404 < "$BATS_TEST_TMPDIR/input" > "$GOT" 2> "$ERRORS" || status=$?
    printf '%s%s' "${full:0:404}" "$FILTER_RESTORE" > "$WANT"
    [ "$status" -eq 130 ]
    compare_filtered 0
}

@test "only the first stop signal raises Stop, so that a later one cannot cut the cleanup short" {
    local code
    code='import signal, sys
sys.path.insert(0, sys.argv[1])
import tlogger_view as v
v._catch_signals()
try:
    v._on_signal(signal.SIGTERM, None)
except v.Stop as stop:
    print("first", stop.signum)
print("second", v._on_signal(signal.SIGINT, None))
v._catch_signals()
try:
    v._on_signal(signal.SIGINT, None)
except v.Stop as stop:
    print("again", stop.signum)'
    run --separate-stderr "$PYTHON3" -I -B -c "$code" "$(dirname "$VIEW")" < /dev/null
    [ "$status" -eq 0 ]
    [ "${output//$'\r'/}" = "$(printf '%s\n' 'first 15' 'second None' 'again 2')" ]
}

@test "SIGINT, SIGQUIT and SIGTERM make the filter write the restore sequence and exit 128+n" {
    need python3-signals
    need command mkfifo
    local sig pid status want writer fifo="$BATS_TEST_TMPDIR/fifo"
    mkfifo "$fifo"
    # bash starts a background job with SIGINT and SIGQUIT ignored; the filter catches them anyway.
    for sig in INT QUIT TERM; do
        "$PYTHON3" -I "$VIEW" filter < "$fifo" > "$GOT" 2> "$ERRORS" 3>&- &
        pid=$!
        exec {writer}> "$fifo"
        printf '%b' 'a\e[31mb' >&"$writer"
        # The filter writes what it read at once, while its input stays open.
        wait_for_size "$GOT" 7
        kill -s "$sig" "$pid"
        status=0
        wait "$pid" || status=$?
        exec {writer}>&-
        case $sig in
            INT) want=130 ;;
            QUIT) want=131 ;;
            *) want=143 ;;
        esac
        printf '%b%s' 'a\e[31mb' "$FILTER_RESTORE" > "$WANT"
        [ "$status" -eq "$want" ]
        compare_filtered 0
    done
}
