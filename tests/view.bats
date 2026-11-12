#!/usr/bin/env bats
# Tests for libexec/tlogger_view.py, run as bin/tlogger runs it, python3 -I on the file: render on
# synthetic session logs that each test builds with printf, the timing parser, replay-timing,
# probe and the usage errors. Render tests need a POSIX python3 with pyte; filter.bats tests the
# replay filter.

bats_require_minimum_version 1.5.0

load helpers

# Python code for python3 -I -c CODE FILE ARGS...: run FILE as the main module with ARGS while
# pyte cannot be imported, as on a machine without python3-pyte.
BLOCK_PYTE='import runpy, sys
sys.modules["pyte"] = None
sys.argv = sys.argv[1:]
runpy.run_path(sys.argv[0], run_name="__main__")'

# Python code for python3 -I -B -c CODE LIBEXEC: load tlogger_view.py from LIBEXEC and pyte, as
# render does before it reads a log, then print VmPeak, the most virtual memory the process has
# had, in KiB. -B keeps the import from writing bytecode beside the file.
PEAK_AFTER_LOAD='import sys
sys.path.insert(0, sys.argv[1])
import tlogger_view
tlogger_view.load_screen_class()
with open("/proc/self/status") as status:
    for line in status:
        if line.startswith("VmPeak:"):
            print(line.split()[1])'

# Python code for python3 -I -B -c CODE LIBEXEC COUNT: load what render loads, then keep COUNT
# short lines as a list of strings, as a renderer that kept the whole history would.
KEEP_LINES='import sys
sys.path.insert(0, sys.argv[1])
import tlogger_view
tlogger_view.load_screen_class()
lines = ["%06d" % i for i in range(int(sys.argv[2]))]'

# Run before each test by bats.
# Gives the test its own home, the version that bin/tlogger passes render, and the paths of a
# session folder, of a transcript that render prints and of what render prints on stderr.
setup() {
    isolate_home
    need python3
    IFS= read -r VERSION_TEXT < "$REPO_ROOT/VERSION"
    ID=20261112T100000Z-a1B2c3
    SESSION="$BATS_TEST_TMPDIR/sessions/$ID"
    TRANSCRIPT="$BATS_TEST_TMPDIR/transcript.out"
    ERRORS="$BATS_TEST_TMPDIR/errors.out"
}

# Run python3 -I with ARGS through bats `run --separate-stderr`, stdin from /dev/null. Removes the
# CR that Python on Windows writes before each LF of its messages, so that the same checks hold
# there; on Linux there is none.
run_python() {
    run --separate-stderr "$PYTHON3" -I "$@" < /dev/null
    stderr=${stderr//$'\r'/}
}

# Render the session in SDIR with --stdout into TRANSCRIPT, its stderr into ERRORS. Fails, showing
# the errors, unless render exits 0 and the transcript starts with the header for SDIR and holds
# no control character.
render_stdout() {
    local status=0
    "$PYTHON3" -I "$VIEW" render --version "$VERSION_TEXT" --stdout -- "$SDIR" \
        < /dev/null > "$TRANSCRIPT" 2> "$ERRORS" || status=$?
    if (( status != 0 )); then
        printf 'render exited with status %s:\n' "$status" >&2
        cat "$ERRORS" >&2
        return 1
    fi
    assert_transcript_header "$TRANSCRIPT" "${SDIR##*/}" "$VERSION_TEXT"
    refute_controls "$TRANSCRIPT"
}

# Fail, with a diff, unless TRANSCRIPT holds the lines LINE..., and nothing else, after its header.
assert_lines() {
    diff -u <(if (( $# )); then printf '%s\n' "$@"; fi) <(tail -n +2 "$TRANSCRIPT")
}

# Fail unless the last run_python was a usage error: exit status 2, nothing on stdout, MESSAGE as
# the first line of stderr, then the usage, and no traceback.
assert_usage_error() {
    local first=${stderr%%$'\n'*}
    if [[ $status -ne 2 || -n $output || $first != "$1" ||
        $stderr != *$'\nusage: tlogger_view.py probe [--pyte]\n'* || $stderr == *Traceback* ]]; then
        printf 'expected the usage error %s, got status %s and:\n%s\n%s\n' "$1" "$status" \
            "$output" "$stderr" >&2
        return 1
    fi
}

# Add COUNT lines of 8 bytes to output.raw of SDIR, %06d of 0 to COUNT-1 and CR LF, in O entries
# of 540 lines each; COUNT must be a multiple of 540.
add_short_lines() {
    awk -v count="$1" -v out="$SDIR/output.raw" -v timing="$SDIR/timing" 'BEGIN {
        for (i = 0; i < count; i++) {
            printf "%06d\r\n", i >> out
            if (i % 540 == 539)
                print "O 0.001000 4320" >> timing
        }
    }'
}

# Wait at most 10 seconds for PATH to exist; fail when it does not.
wait_for() {
    local i
    for (( i = 0; i < 200; i++ )); do
        if [[ -e $1 ]]; then
            return 0
        fi
        sleep 0.05
    done
    printf '%s did not appear within 10 seconds\n' "$1" >&2
    return 1
}

@test "a progress line that CR rewrites leaves its last state" {
    need pyte
    session_new "$SESSION"
    session_out 'fetch  10%\r'
    session_out 'fetch  55%\rfetch 100%\r\n'
    session_out 'done\r\n'
    session_end
    render_stdout
    assert_lines 'fetch 100%' 'done'
    [ ! -s "$ERRORS" ]
}

@test "an autosuggestion drawn after the cursor and erased with EL leaves only what was typed" {
    need pyte
    session_new "$SESSION"
    # zsh-autosuggestions shows the rest of a suggestion in grey after the cursor and moves back
    # over it; when the line is accepted, EL erases what is left of it.
    session_out '$ i\e[90md -a\e[39m\e[4D'
    session_out 'd\e[K\r\n'
    session_out 'uid=1000(kali) gid=1000(kali) groups=1000(kali)\r\n'
    session_end
    render_stdout
    assert_lines '$ id' 'uid=1000(kali) gid=1000(kali) groups=1000(kali)'
}

@test "a paste that the line kill erases before Enter leaves no trace" {
    need pyte
    session_new "$SESSION"
    session_out '$ '
    session_out '\e[7msecret-paste\e[27m'
    # The terminal's line kill erases each of the 12 characters with BS, space and BS.
    session_out "$(printf '\\b \\b%.0s' {1..12})"
    session_out '\r\n$ ls\r\nnotes.txt\r\n'
    session_end
    render_stdout
    assert_lines '$' '$ ls' notes.txt
}

@test "ESC ( B leaves no text, and ESC ( 0 draws DEC line graphics" {
    need pyte
    session_new "$SESSION"
    # tput sgr0 sends ESC ( B before SGR 0.
    session_out '\e(B\e[mplain\e(B\e[m\r\n'
    session_out '\e(0lqqk\e(B ok\r\n'
    session_end
    render_stdout
    assert_lines plain '┌──┐ ok'
}

@test "OSC 0, 2, 7 and 8, ended by BEL or by ST, leave no text" {
    need pyte
    session_new "$SESSION"
    # shellcheck disable=SC1003 # \\ is the backslash of ST for printf %b.
    session_out '\e]0;kali@kali: ~\a\e]2;kali@kali: ~\e\\'
    session_out '\e]7;file://kali/home/kali\a$ ls\r\n'
    session_out 'see \e]8;;https://192.0.2.10/report\alink\e]8;;\e\\ here\r\n'
    session_end
    render_stdout
    assert_lines '$ ls' 'see link here'
}

@test "a full-screen program leaves one marker, and the main screen comes back as it was" {
    need pyte
    local marker='[full-screen program: 24x80, not kept here; replay shows it]'
    session_new "$SESSION"
    session_out 'before\r\n$ vim notes\r\n'
    session_out '\e[?1049h\e[22;0;0t\e[H\e[2Jfull-screen text\r\n~\r\n~'
    # A resize on the alternate screen; the marker names the size at its start.
    session_winch 30 100
    session_out '\e[?1049l\e[23;0;0t$ after\r\n'
    session_end
    render_stdout
    assert_lines before '$ vim notes' "$marker" '$ after'
    # Mode 47 between ESC 7 and ESC 8, as older terminfo entries enter and leave it.
    session_new "$BATS_TEST_TMPDIR/sessions/20261112T110000Z-d4E5f6"
    session_out 'top\r\n\e7\e[?47hALT SCREEN\e[2J\e[?47l\e8bottom\r\n'
    session_end
    render_stdout
    assert_lines top "$marker" bottom
}

@test "clear, tput clear and a terminal reset keep what was on the screen before them" {
    need pyte
    session_new "$SESSION"
    session_out 'one\r\ntwo\r\n$ clear\r\n'
    # clear sends ED 2 and, for the scrollback, ED 3; under TERM=vt100, tput clear sends ED 0 in
    # the top left corner; reset sends RIS.
    session_out '\e[H\e[2J\e[3J$ tput clear\r\n'
    session_out '\e[H\e[J$ reset\r\n'
    session_out '\ec$ after\r\n'
    session_end
    render_stdout
    assert_lines one two '$ clear' '$ tput clear' '$ reset' '$ after'
}

@test "a resize mid-stream keeps every line, on a narrower screen and on one with fewer rows" {
    need pyte
    local a60 b50 i
    printf -v a60 'a%.0s' {1..60}
    printf -v b50 'b%.0s' {1..50}
    session_new "$SESSION"
    session_out "$a60"'\r\n$ '
    session_winch 10 40
    session_out '\r$ '"$b50"'\r\n'
    session_end
    render_stdout
    assert_lines "$a60" "\$ $b50"
    session_new "$BATS_TEST_TMPDIR/sessions/20261112T110000Z-d4E5f6"
    for i in {01..20}; do
        session_out "L$i"'\r\n'
    done
    session_winch 10 80
    session_out 'next\r\n'
    session_end
    render_stdout
    assert_lines L{01..20} next
}

@test "a line longer than the screen comes out whole, and PROMPT_SP padding joins no lines" {
    need pyte
    local x200 pad z70000 line
    local -a lengths=()
    printf -v x200 'x%.0s' {1..200}
    printf -v pad ' %.0s' {1..79}
    session_new "$SESSION"
    session_out "$x200"'\r\n'
    # Output that ends without a newline, then the % mark, padding and CRs of zsh's PROMPT_SP.
    session_out 'partial'
    session_out '%'"$pad"'\r \r$ next\r\n'
    session_end
    render_stdout
    assert_lines "$x200" 'partial%' '$ next'
    # A line that never ends goes out in pieces of at most 65600 characters.
    printf -v z70000 'z%.0s' {1..70000}
    session_new "$BATS_TEST_TMPDIR/sessions/20261112T110000Z-d4E5f6"
    session_out "$z70000"'\r\nnext\r\n'
    session_end
    render_stdout
    while IFS= read -r line; do
        lengths+=("${#line}")
        [[ $line == next || -z ${line//z} ]]
    done < <(tail -n +2 "$TRANSCRIPT")
    [ "${lengths[*]}" = '65600 4400 4' ]
}

@test "UTF-8 that an O entry boundary splits comes out whole, and invalid bytes become U+FFFD" {
    need pyte
    session_new "$SESSION"
    session_out 'caf\xc3'
    session_out '\xa9 \xe2\x94'
    session_out '\x80\xe2\x94\x80 \xe6\xbc\xa2\xe5\xad\x97 wide\r\n'
    session_out 'bad \xff\xfe bytes\r\n'
    session_end
    render_stdout
    assert_lines 'café ── 漢字 wide' $'bad \xef\xbf\xbd\xef\xbf\xbd bytes'
}

@test "a long run of combining marks keeps 8 characters in its cell and renders fast" {
    need pyte
    local marks start
    # 100000 times U+0301, the combining acute accent, after an a.
    printf -v marks '\xcc\x81%.0s' {1..100000}
    session_new "$SESSION"
    session_out "a$marks"'\r\n'
    session_out 'e\xcc\x81\xcc\x82 next\r\n'
    session_end
    start=$SECONDS
    render_stdout
    (( SECONDS - start < 30 ))
    # NFC makes the a and the first mark one character, á; 7 marks stay after it.
    assert_lines $'\xc3\xa1\xcc\x81\xcc\x81\xcc\x81\xcc\x81\xcc\x81\xcc\x81\xcc\x81' \
        $'\xc3\xa9\xcc\x82 next'
    [ ! -s "$ERRORS" ]
}

@test "combining marks sent with the cursor below the scroll region keep the cap of 8 characters" {
    need pyte
    local marks start pad
    # Region rows 1 to 10, an x in the last column of row 9, then 30000 times: a b in the last
    # column of row 20, below the region, and a U+0301. At the pending wrap pyte moves the cursor
    # down only to the bottom margin, so the mark joins the x, not the b.
    printf -v marks '\e[20;80Hb\xcc\x81%.0s' {1..30000}
    printf -v pad ' %.0s' {1..79}
    session_new "$SESSION"
    session_out '\e[1;10r\e[9;80Hx'"$marks"
    session_end
    start=$SECONDS
    render_stdout
    (( SECONDS - start < 30 ))
    assert_lines "${pad}x"$'\xcc\x81\xcc\x81\xcc\x81\xcc\x81\xcc\x81\xcc\x81\xcc\x81' '' '' '' '' '' '' '' '' '' '' \
        "${pad}b"
    [ ! -s "$ERRORS" ]
}

@test "a character that ICH pushes off the last column is gone, and DCH does not bring it back" {
    need pyte
    local a79
    printf -v a79 'a%.0s' {1..79}
    session_new "$SESSION"
    session_out "${a79}Z"'\r\e[@\e[P\r\n'
    session_end
    render_stdout
    assert_lines "$a79"
}

@test "malformed timing lines get one warning each, are skipped and leave a note at the end" {
    need pyte
    mkdir -p "$SESSION"
    printf 'Script started on 2026-11-12 10:00:00+00:00 [<not executed on terminal>]\nok\r\nfine\r\n' \
        > "$SESSION/output.raw"
    # Line 2 has the comma that script writes for H lines under a locale such as de_DE.
    printf '%s\n' 'H 0.000000 COLUMNS 80' 'H 0,000000 LINES 24' 'O 0.010000 4' garbage 'O 1.0' \
        'X 0.100000 3' 'S 0.100000 SIGWINCH ROWS=a COLS=3' 'H 0.000000 COLUMNS eighty' '' \
        'O 0.010000 6' 'S 0.200000 SIGTERM ' 'O 0.010000 0' > "$SESSION/timing"
    printf 'O 0.0' >> "$SESSION/timing"
    SDIR=$SESSION
    render_stdout
    assert_lines ok fine '[7 malformed timing lines skipped]'
    # tr: Python on Windows writes a CR before each LF of its messages.
    diff -u <(printf 'tlogger: warning: timing line %s is malformed; skipped\n' 4 5 6 7 8 9 13) \
        <(tr -d '\r' < "$ERRORS")
}

@test "an output.raw that ends before its timing does gives a warning and a note at the end" {
    need pyte
    mkdir -p "$SESSION"
    printf 'Script started on 2026-11-12 10:00:00+00:00 [<not executed on terminal>]\nhello\r\n' \
        > "$SESSION/output.raw"
    printf '%s\n' 'O 0.010000 7' 'O 0.010000 100' 'garbage' > "$SESSION/timing"
    SDIR=$SESSION
    render_stdout
    # The timing file is read no further, so its last line gets no warning.
    assert_lines hello '[output.raw ends before its timing does; the transcript stops here]'
    [ "$(tr -d '\r' < "$ERRORS")" = "tlogger: warning: output.raw of session $ID ends before its timing does; the transcript stops there" ]
}

@test "an output.raw that holds more than its timing covers gives a warning and a note at the end" {
    need pyte
    session_new "$SESSION"
    session_out 'hello\r\n'
    # Output that no O entry covers, before script's trailer.
    printf 'more\r\n' >> "$SESSION/output.raw"
    session_end
    render_stdout
    assert_lines hello '[output.raw holds more output than its timing covers; the transcript stops here]'
    [ "$(tr -d '\r' < "$ERRORS")" = "tlogger: warning: output.raw of session $ID holds more output than its timing covers; the transcript stops there" ]
    # Output that no O entry covers and no trailer after it.
    session_new "$SESSION"
    session_out 'hello\r\n'
    printf 'more' >> "$SESSION/output.raw"
    render_stdout
    assert_lines hello '[output.raw holds more output than its timing covers; the transcript stops here]'
    # script's trailer alone, in the language of any locale, is no output.
    session_new "$SESSION"
    session_out 'hello\r\n'
    printf '\nSkript beendet am 2026-11-12 10:01:00+00:00 [COMMAND_EXIT_CODE="0"]\n' >> "$SESSION/output.raw"
    render_stdout
    assert_lines hello
    [ ! -s "$ERRORS" ]
}

@test "ESC [ c and the other requests and reports add no text" {
    need pyte
    session_new "$SESSION"
    # shellcheck disable=SC2016 # $q is part of DECRQSS, not an expansion.
    session_out '$ x\e[c\e[>c\e[0c\e[6n\e[5n\e[21t\e[14t\e[18t\eZ\eP$qm\e\\\e[?1$p\e[>0q\r\n'
    session_out 'after\r\n'
    session_end
    render_stdout
    assert_lines '$ x' after
}

@test "a control sequence with thousands of private markers adds no text and erases nothing" {
    need pyte
    local marks
    printf -v marks '?%.0s' {1..3000}
    session_new "$SESSION"
    session_out 'before\r\n\e['"$marks"'J\e[??2J\e[?1?Kafter\r\n'
    # CSI ? 2 J, a selective erase, clears the screen as ED 2 does, which keeps history.
    session_out '\e[?2J\e[Hlast\r\n'
    session_end
    render_stdout
    assert_lines before after last
    [ ! -s "$ERRORS" ]
}

@test "CHT and CBT move the cursor between tab stops, and CHT stops at the last column" {
    need pyte
    local want
    session_new "$SESSION"
    session_out 'a\e[2Ib\e[Zc\e[3Zd\e[99Ie\r\n'
    session_end
    render_stdout
    printf -v want 'd%15sc%62se' '' ''
    assert_lines "$want"
}

@test "a session without output gives the header line alone" {
    need pyte
    session_new "$SESSION"
    session_end
    render_stdout
    [ "$(wc -l < "$TRANSCRIPT")" -eq 1 ]
    [ ! -s "$ERRORS" ]
}

@test "a hostile screen size is clamped to 1000 columns, and a size of 0 keeps the size" {
    need pyte
    local q1000 q1001
    printf -v q1000 'q%.0s' {1..1000}
    printf -v q1001 'q%.0s' {1..1001}
    # The H lines ask for 999999999 x 999999999; the screen gets 500 x 1000.
    session_new "$SESSION" 999999999 999999999
    session_out "$q1001"'\rZ\r\n'
    session_winch 0 0
    session_out "$q1001"'\rY\r\n'
    session_end
    render_stdout
    assert_lines "${q1000}Z" "${q1000}Y"
}

@test "render writes transcript.txt with mode 0600 through transcript.txt.part and a rename" {
    need pyte
    need modes
    local inode
    session_new "$SESSION"
    session_out 'hello\r\n'
    session_end
    printf 'an older transcript\n' > "$SESSION/transcript.txt"
    chmod 644 "$SESSION/transcript.txt"
    inode=$(stat -c %i "$SESSION/transcript.txt")
    run_python "$VIEW" render --version "$VERSION_TEXT" -- "$SESSION"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$stderr" ]
    [ "$(stat -c %a "$SESSION/transcript.txt")" = 600 ]
    [ "$(stat -c %i "$SESSION/transcript.txt")" != "$inode" ]
    [ ! -e "$SESSION/transcript.txt.part" ]
    assert_transcript_header "$SESSION/transcript.txt" "$ID" "$VERSION_TEXT"
    [ "$(tail -n +2 "$SESSION/transcript.txt")" = hello ]
}

@test "render refuses a transcript.txt.part that exists, a symlink included, and leaves it as it is" {
    need pyte
    need symlinks
    local refusal="tlogger: session $ID: transcript.txt.part exists, left by a render that did not finish; remove it and render again"
    session_new "$SESSION"
    session_out 'hello\r\n'
    session_end
    printf 'partial\n' > "$SESSION/transcript.txt.part"
    run_python "$VIEW" render --version "$VERSION_TEXT" -- "$SESSION"
    [ "$status" -eq 1 ]
    [ "$stderr" = "$refusal" ]
    [ "$(cat "$SESSION/transcript.txt.part")" = partial ]
    [ ! -e "$SESSION/transcript.txt" ]
    rm "$SESSION/transcript.txt.part"
    ln -s "$BATS_TEST_TMPDIR/elsewhere" "$SESSION/transcript.txt.part"
    run_python "$VIEW" render --version "$VERSION_TEXT" -- "$SESSION"
    [ "$status" -eq 1 ]
    [ "$stderr" = "$refusal" ]
    [ -L "$SESSION/transcript.txt.part" ]
    [ ! -e "$BATS_TEST_TMPDIR/elsewhere" ]
    [ ! -e "$SESSION/transcript.txt" ]
}

@test "render refuses a transcript.txt that is a symlink or not a regular file, but --stdout works" {
    need pyte
    need symlinks
    session_new "$SESSION"
    session_out 'hello\r\n'
    session_end
    printf 'keep\n' > "$BATS_TEST_TMPDIR/target"
    ln -s "$BATS_TEST_TMPDIR/target" "$SESSION/transcript.txt"
    run_python "$VIEW" render --version "$VERSION_TEXT" -- "$SESSION"
    [ "$status" -eq 1 ]
    [ "$stderr" = "tlogger: session $ID: transcript.txt is a symlink, which tlogger does not write through; remove it" ]
    [ "$(cat "$BATS_TEST_TMPDIR/target")" = keep ]
    [ ! -e "$SESSION/transcript.txt.part" ]
    SDIR=$SESSION
    render_stdout
    assert_lines hello
    rm "$SESSION/transcript.txt"
    mkdir "$SESSION/transcript.txt"
    run_python "$VIEW" render --version "$VERSION_TEXT" -- "$SESSION"
    [ "$status" -eq 1 ]
    [ "$stderr" = "tlogger: session $ID: transcript.txt is not a regular file; remove it" ]
    [ ! -e "$SESSION/transcript.txt.part" ]
}

@test "render changes no evidence file, never reads input.raw, and keeps hidden keystrokes out" {
    need pyte
    need modes
    local f
    local -A sums=() times=()
    session_new "$SESSION"
    session_out '$ sudo -k id\r\n[sudo] password for kali: '
    # Typed at a prompt that shows nothing: only input.raw has it.
    session_in 'hidden-secret-4711\r'
    session_out '\r\nuid=0(root) gid=0(root) groups=0(root)\r\n'
    session_end
    for f in output.raw timing input.raw commands.tsv; do
        sums[$f]=$(sha_of "$SESSION/$f")
        times[$f]=$(stat -c %Y "$SESSION/$f")
    done
    chmod 000 "$SESSION/input.raw"
    run_python "$VIEW" render --version "$VERSION_TEXT" -- "$SESSION"
    [ "$status" -eq 0 ]
    SDIR=$SESSION
    render_stdout
    chmod 600 "$SESSION/input.raw"
    assert_lines '$ sudo -k id' '[sudo] password for kali:' 'uid=0(root) gid=0(root) groups=0(root)'
    # The file holds what --stdout printed; only the time in the header may differ.
    [ "$(tail -n +2 "$TRANSCRIPT")" = "$(tail -n +2 "$SESSION/transcript.txt")" ]
    for f in output.raw timing input.raw commands.tsv; do
        [ "$(sha_of "$SESSION/$f")" = "${sums[$f]}" ]
        [ "$(stat -c %Y "$SESSION/$f")" = "${times[$f]}" ]
    done
    [ "$(find "$SESSION" -mindepth 1 -printf '%f\n' | LC_ALL=C sort | paste -s -d ' ' -)" = \
        'commands.tsv input.raw output.raw timing transcript.txt' ]
    run ! grep -qF hidden-secret-4711 "$SESSION/transcript.txt"
    grep -qF hidden-secret-4711 "$SESSION/input.raw"
}

@test "render refuses a symlinked session folder or log, a FIFO as a log and a missing log" {
    need pyte
    need symlinks
    need command mkfifo
    session_new "$SESSION"
    session_out 'hello\r\n'
    session_end
    ln -s "$SESSION" "$BATS_TEST_TMPDIR/sessions/link"
    run_python "$VIEW" render --version "$VERSION_TEXT" --stdout -- "$BATS_TEST_TMPDIR/sessions/link"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ $stderr == 'tlogger: session link: cannot open its folder: '* ]]
    [[ $stderr != *$'\n'* ]]
    # With a trailing slash, the kernel would follow the symlink despite O_NOFOLLOW.
    run_python "$VIEW" render --version "$VERSION_TEXT" --stdout -- "$BATS_TEST_TMPDIR/sessions/link//"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ $stderr == 'tlogger: session link: cannot open its folder: '* ]]
    mv "$SESSION/output.raw" "$BATS_TEST_TMPDIR/output.raw"
    ln -s "$BATS_TEST_TMPDIR/output.raw" "$SESSION/output.raw"
    run_python "$VIEW" render --version "$VERSION_TEXT" --stdout -- "$SESSION"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [ "$stderr" = "tlogger: session $ID: cannot open output.raw: Too many levels of symbolic links" ]
    rm "$SESSION/output.raw"
    mkfifo "$SESSION/output.raw"
    run_python "$VIEW" render --version "$VERSION_TEXT" --stdout -- "$SESSION"
    [ "$status" -eq 1 ]
    [ "$stderr" = "tlogger: session $ID: output.raw is not a regular file of yours" ]
    rm "$SESSION/output.raw"
    run_python "$VIEW" render --version "$VERSION_TEXT" -- "$SESSION"
    [ "$status" -eq 1 ]
    [ "$stderr" = "tlogger: session $ID: cannot open output.raw: No such file or directory" ]
    [ ! -e "$SESSION/transcript.txt" ]
    [ ! -e "$SESSION/transcript.txt.part" ]
}

@test "render keeps its memory bounded: more than 4 MiB of short lines under ulimit -v" {
    need pyte
    need proc
    local base bound
    session_new "$SESSION"
    # 540000 lines of 8 bytes: 4320000 bytes, more than 4 MiB.
    add_short_lines 540000
    session_end
    base=$("$PYTHON3" -I -B -c "$PEAK_AFTER_LOAD" "$REPO_ROOT/libexec")
    [[ $base =~ ^[0-9]+$ ]]
    # 16 MiB above what python3 takes once tlogger_view.py and pyte are loaded.
    bound=$(( base + 16384 ))
    # The bound holds a thousand of the lines kept as strings, but not all of them: a renderer
    # that kept the whole history would run out of memory under it.
    # shellcheck disable=SC2016 # The inner bash expands them.
    run --separate-stderr bash -c 'ulimit -v "$1" && exec "$2" -I -B -c "$3" "$4" "$5"' _ \
        "$bound" "$PYTHON3" "$KEEP_LINES" "$REPO_ROOT/libexec" 1000
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    # shellcheck disable=SC2016 # The inner bash expands them.
    run --separate-stderr bash -c 'ulimit -v "$1" && exec "$2" -I -B -c "$3" "$4" "$5"' _ \
        "$bound" "$PYTHON3" "$KEEP_LINES" "$REPO_ROOT/libexec" 540000
    [ "$status" -ne 0 ]
    [[ $stderr == *MemoryError* ]]
    # shellcheck disable=SC2016 # The inner bash expands them.
    run --separate-stderr bash -c 'ulimit -v "$1" && exec "$2" -I "$3" render --version "$4" -- "$5"' \
        _ "$bound" "$PYTHON3" "$VIEW" "$VERSION_TEXT" "$SESSION"
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    tail -n +2 "$SESSION/transcript.txt" |
        cmp - <(awk 'BEGIN { for (i = 0; i < 540000; i++) printf "%06d\n", i }')
    refute_controls "$SESSION/transcript.txt"
}

@test "SIGTERM, SIGINT and SIGQUIT stop render, which removes its .part and exits 128+n" {
    need pyte
    local sig pid status want
    session_new "$SESSION"
    add_short_lines 540000
    session_end
    for sig in TERM INT QUIT; do
        "$PYTHON3" -I "$VIEW" render --version "$VERSION_TEXT" -- "$SESSION" \
            < /dev/null > /dev/null 2> "$ERRORS" 3>&- &
        pid=$!
        wait_for "$SESSION/transcript.txt.part" || { cat "$ERRORS" >&2; false; }
        # By now render is well inside the log, which takes it seconds.
        sleep 0.2
        kill -s "$sig" "$pid"
        status=0
        wait "$pid" || status=$?
        case $sig in
            INT) want=130 ;;
            QUIT) want=131 ;;
            *) want=143 ;;
        esac
        [ "$status" -eq "$want" ]
        [ ! -s "$ERRORS" ]
        [ ! -e "$SESSION/transcript.txt.part" ]
        [ ! -e "$SESSION/transcript.txt" ]
    done
}

@test "probe answers ok, and with --pyte no-pyte when pyte does not import" {
    run_python "$VIEW" probe
    [ "$status" -eq 0 ]
    [ "$output" = ok ]
    [ -z "$stderr" ]
    run_python "$VIEW" probe --pyte
    [ "$status" -eq 0 ]
    [[ $output == ok || $output == no-pyte ]]
    run_python -c "$BLOCK_PYTE" "$VIEW" probe --pyte
    [ "$status" -eq 0 ]
    [ "$output" = no-pyte ]
    [ -z "$stderr" ]
    run_python -c "$BLOCK_PYTE" "$VIEW" render --version "$VERSION_TEXT" -- "$SESSION"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [ "$stderr" = 'tlogger: rendering needs python3-pyte (apt install python3-pyte)' ]
}

@test "usage errors exit 2 with a message and the usage, and no traceback" {
    run_python "$VIEW"
    assert_usage_error 'tlogger: no command given'
    run_python "$VIEW" nope
    assert_usage_error 'tlogger: unknown command: nope'
    run_python "$VIEW" filter extra
    assert_usage_error 'tlogger: filter takes no arguments'
    run_python "$VIEW" replay-timing extra
    assert_usage_error 'tlogger: replay-timing takes no arguments'
    run_python "$VIEW" probe --other
    assert_usage_error 'tlogger: probe takes --pyte at most'
    run_python "$VIEW" probe --pyte --pyte
    assert_usage_error 'tlogger: probe takes --pyte at most'
    run_python "$VIEW" render "$SESSION"
    assert_usage_error 'tlogger: render needs --version and a version such as 0.1.0'
    run_python "$VIEW" render --version
    assert_usage_error 'tlogger: --version needs a value'
    run_python "$VIEW" render --version 0.1 "$SESSION"
    assert_usage_error 'tlogger: render needs --version and a version such as 0.1.0'
    run_python "$VIEW" render --version 0.1.0
    assert_usage_error 'tlogger: render takes one session folder'
    run_python "$VIEW" render --version 0.1.0 "$SESSION" "$SESSION"
    assert_usage_error 'tlogger: render takes one session folder'
    run_python "$VIEW" render --version 0.1.0 --bogus "$SESSION"
    assert_usage_error 'tlogger: unknown option for render: --bogus'
    # After --, a name that starts with - is a folder: an error of its own, not a usage error.
    run_python "$VIEW" render --version 0.1.0 -- --stdout
    [ "$status" -eq 1 ]
    [[ $stderr != *Traceback* ]]
}

@test "replay-timing keeps the I, O and S lines as they are and drops the H lines and malformed ones" {
    local long
    printf -v long 'A%.0s' {1..5000}
    # Line 2 has the comma that script writes for H lines under a locale such as de_DE, which
    # scriptreplay cannot read; line 7 is longer than 4096 bytes; the last one has no newline.
    printf '%s\n' 'H 0.000000 START_TIME 2026-11-12 10:00:00+00:00' 'H 0,000000 COLUMNS 80' \
        'O 0.010000 5' 'I 1.500000 3' garbage 'S 0.250000 SIGWINCH ROWS=30 COLS=100' "$long" \
        'S 0.000001 SIGTERM ' 'O 12.000001 7' 'H 0.000000 DURATION 13.510002' \
        > "$BATS_TEST_TMPDIR/timing"
    printf 'O 0.1' >> "$BATS_TEST_TMPDIR/timing"
    run --separate-stderr "$PYTHON3" -I "$VIEW" replay-timing < "$BATS_TEST_TMPDIR/timing"
    stderr=${stderr//$'\r'/}
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s\n' 'O 0.010000 5' 'I 1.500000 3' \
        'S 0.250000 SIGWINCH ROWS=30 COLS=100' 'S 0.000001 SIGTERM ' 'O 12.000001 7')" ]
    [ "$stderr" = "$(printf 'tlogger: warning: timing line %s is malformed; skipped\n' 5 7 11)" ]
}

@test "replay-timing drops O, I and S lines with more than 6 fraction digits, which scriptreplay rejects" {
    printf '%s\n' 'O 0.1234567 5' 'I 0.12345678 3' 'S 0.123456789 SIGTERM ' 'O 0.123456 7' \
        'I 0.1 1' 'S 0.000001 SIGWINCH ROWS=30 COLS=100' 'O 1.0000000 2' > "$BATS_TEST_TMPDIR/timing"
    run --separate-stderr "$PYTHON3" -I "$VIEW" replay-timing < "$BATS_TEST_TMPDIR/timing"
    stderr=${stderr//$'\r'/}
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s\n' 'O 0.123456 7' 'I 0.1 1' 'S 0.000001 SIGWINCH ROWS=30 COLS=100')" ]
    [ "$stderr" = "$(printf 'tlogger: warning: timing line %s is malformed; skipped\n' 1 2 3 7)" ]
}

@test "more than 100 malformed timing lines get 100 warnings and one line for the rest" {
    local i
    {
        printf 'H 0.000000 COLUMNS 80\n'
        for (( i = 1; i <= 150; i++ )); do
            printf 'bad line %s\n' "$i"
        done
        printf 'O 0.010000 2\n'
    } > "$BATS_TEST_TMPDIR/timing"
    run --separate-stderr "$PYTHON3" -I "$VIEW" replay-timing < "$BATS_TEST_TMPDIR/timing"
    stderr=${stderr//$'\r'/}
    [ "$status" -eq 0 ]
    [ "$output" = 'O 0.010000 2' ]
    [ "$stderr" = "$(printf 'tlogger: warning: timing line %s is malformed; skipped\n' {2..101}
        printf 'tlogger: warning: 50 more malformed timing lines skipped\n')" ]
}
