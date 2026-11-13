#!/usr/bin/env bats
# Tests for tlogger render, show and replay in bin/tlogger, run as a subprocess in the test's own
# HOME on synthetic sessions: which session a SESSION argument names, the refusals, the usage
# errors and the messages for a missing python3, pyte or scriptreplay. TLOGGER_PYTHON and
# TLOGGER_SCRIPTREPLAY name stand-ins; render tests need a POSIX python3 with pyte.

bats_require_minimum_version 1.5.0

load helpers

# Run before each test by bats.
# Gives the test its own HOME with the default layout, an empty log folder and a session id.
setup() {
    isolate_home
    isolate_tlogger
    IFS= read -r VERSION_TEXT < "$REPO_ROOT/VERSION"
    LOGS="$HOME/.local/state/tlogger/sessions"
    ID=20261112T100000Z-a1B2c3
    mkdir -p "$LOGS"
}

# Run bin/tlogger with ARGS as run_tlogger does, then remove the CR that Python on Windows writes
# before each LF of the messages it adds to stderr; on Linux there is none.
run_cmd() {
    run_tlogger "$@"
    stderr=${stderr//$'\r'/}
}

# Fail if the last run printed the test's HOME in full: tlogger shows home paths as ~.
refute_home_shown() {
    if [[ $output == *"$HOME"* || $stderr == *"$HOME"* ]]; then
        printf 'the output names the home folder in full:\n%s\n%s\n' "$output" "$stderr" >&2
        return 1
    fi
}

# Fail unless the last run exited STATUS, printed nothing on stdout and printed MESSAGE alone on
# stderr, with no home path in full.
assert_refused() {
    if [[ $status -ne $1 || -n $output || $stderr != "$2" ]]; then
        printf 'expected status %s and the message\n%s\ngot status %s and:\n%s\n%s\n' "$1" "$2" \
            "$status" "$output" "$stderr" >&2
        return 1
    fi
    refute_home_shown
}

# Fail unless the last run was a usage error: exit status 2, nothing on stdout, MESSAGE as the
# first line of stderr, then the usage.
assert_usage_error() {
    if [[ $status -ne 2 || -n $output || ${stderr%%$'\n'*} != "$1" ||
        $stderr != *$'\nUsage: tlogger <command> [options]\n'* ]]; then
        printf 'expected the usage error %s, got status %s and:\n%s\n%s\n' "$1" "$status" \
            "$output" "$stderr" >&2
        return 1
    fi
}

# Write ~/bin/NAME, an executable sh script with the body BODY, as a stand-in of the test's own.
make_tool() {
    mkdir -p "$HOME/bin"
    printf '#!/bin/sh\n%s\n' "$2" > "$HOME/bin/$1"
    chmod 755 "$HOME/bin/$1"
}

# Write ~/bin/scriptreplay, a stand-in for util-linux scriptreplay. It writes its arguments to
# ~/replay-args, one per line, copies the timing file it is given to ~/replay-timing and prints
# the bytes of ~/replay-out as the replay. When ~/replay-status exists, it prints a message that
# names ~/replay-out in full on stderr instead and exits with the status that file holds.
make_scriptreplay() {
    # shellcheck disable=SC2016 # sh expands these, not bash.
    make_tool scriptreplay '
printf "%s\n" "$@" > "$HOME/replay-args"
while [ "$#" -gt 0 ]; do
    if [ "$1" = --log-timing ]; then
        cp -- "$2" "$HOME/replay-timing"
    fi
    shift
done
if [ -f "$HOME/replay-status" ]; then
    echo "scriptreplay: cannot open $HOME/replay-out: No such file or directory" >&2
    exit "$(cat "$HOME/replay-status")"
fi
cat -- "$HOME/replay-out"'
}

# Print the header line that render writes to the transcript of the session NAME.
transcript_header() {
    printf '# DERIVED transcript of session %s; the evidence is output.raw with timing. tlogger 0.1.0, rendered 2026-11-12T10:00:00Z\n' "$1"
}

# Give the session in SDIR a transcript.txt that holds render's header line and then the line
# TEXT, and is newer than its logs, whose times go back to 2001, so that show prints it as it is.
fresh_transcript() {
    { transcript_header "${SDIR##*/}"; printf '%s\n' "$1"; } > "$SDIR/transcript.txt"
    touch -d '2001-01-01 00:00:00' "$SDIR/output.raw" "$SDIR/timing"
}

# Give the session in SDIR a transcript.txt that is newer than its logs and starts with render's
# header line for it, then holds the bytes that printf %b makes of BODY.
crafted_transcript() {
    { transcript_header "${SDIR##*/}"; printf '%b' "$1"; } > "$SDIR/transcript.txt"
    touch -d '2001-01-01 00:00:00' "$SDIR/output.raw" "$SDIR/timing"
}

@test "help lists render, show and replay, and -h or --help after each prints the usage" {
    local cmd usage
    run_tlogger help
    [ "$status" -eq 0 ]
    usage=$output
    [[ $usage == *$'\n  render     Write the plain-text transcript of a session to transcript.txt in its folder.\n'* ]]
    [[ $usage == *$'\n  show       Page the transcript of a session'* ]]
    [[ $usage == *$'\n  replay     Replay a session in this terminal at its recorded pace'* ]]
    for cmd in render show replay; do
        run_tlogger "$cmd" -h
        [ "$status" -eq 0 ]
        [ "$output" = "$usage" ]
        run_tlogger "$cmd" --help
        [ "$status" -eq 0 ]
        [ "$output" = "$usage" ]
    done
}

@test "a missing log folder, or one without a session in it, exits 3" {
    rmdir "$LOGS"
    run_tlogger show
    assert_refused 3 'tlogger: no sessions: the log folder ~/.local/state/tlogger/sessions does not exist'
    run_tlogger render "$ID"
    assert_refused 3 'tlogger: no sessions: the log folder ~/.local/state/tlogger/sessions does not exist'
    mkdir "$LOGS"
    run_tlogger replay
    assert_refused 3 'tlogger: no sessions in ~/.local/state/tlogger/sessions'
    # Names that are not those of session folders do not count, nor does a file.
    mkdir "$LOGS/notes" "$LOGS/20261112T100000Z-abc" "$LOGS/20261112t100000z-abcdef"
    : > "$LOGS/20261112T100000Z-zzzzzz"
    run_tlogger show
    assert_refused 3 'tlogger: no sessions in ~/.local/state/tlogger/sessions'
}

@test "SESSION names a session by its id or by a path, and none names the newest one by name" {
    local name
    for name in 20261110T090000Z-aaaaaa 20261112T080000Z-bbbbbb 20261111T235959Z-cccccc; do
        session_new "$LOGS/$name"
        fresh_transcript "transcript of $name"
    done
    session_new "$HOME/evidence/case-1"
    fresh_transcript 'transcript of case-1'
    run_tlogger show
    [ "$status" -eq 0 ]
    [ "$output" = "$(transcript_header 20261112T080000Z-bbbbbb; echo 'transcript of 20261112T080000Z-bbbbbb')" ]
    [ -z "$stderr" ]
    run_tlogger show 20261110T090000Z-aaaaaa
    [ "$status" -eq 0 ]
    [ "${output##*$'\n'}" = 'transcript of 20261110T090000Z-aaaaaa' ]
    run_tlogger show -- 20261111T235959Z-cccccc
    [ "$status" -eq 0 ]
    [ "${output##*$'\n'}" = 'transcript of 20261111T235959Z-cccccc' ]
    run_tlogger show "$LOGS/20261110T090000Z-aaaaaa/"
    [ "$status" -eq 0 ]
    [ "${output##*$'\n'}" = 'transcript of 20261110T090000Z-aaaaaa' ]
    # A path may name a session folder anywhere, by any name, and be relative.
    run_tlogger show "$HOME/evidence/case-1"
    [ "$status" -eq 0 ]
    [ "${output##*$'\n'}" = 'transcript of case-1' ]
    cd "$HOME/evidence"
    run_tlogger show ./case-1
    [ "$status" -eq 0 ]
    [ "${output##*$'\n'}" = 'transcript of case-1' ]
    run_tlogger show case-1
    assert_refused 1 "tlogger: 'case-1' is not a session id; name a session folder elsewhere by a path with a /"
}

@test "the newest session folder is checked, not skipped: one without logs exits 1" {
    session_new "$LOGS/20261110T090000Z-aaaaaa"
    fresh_transcript 'an older session'
    mkdir "$LOGS/20261112T080000Z-bbbbbb"
    run_tlogger show
    assert_refused 1 'tlogger: ~/.local/state/tlogger/sessions/20261112T080000Z-bbbbbb holds no output.raw, so it is not a session folder'
}

@test "a SESSION that names no session folder exits 1, with home paths as ~" {
    session_new "$LOGS/$ID"
    run_tlogger show nope
    assert_refused 1 "tlogger: 'nope' is not a session id; name a session folder elsewhere by a path with a /"
    run_tlogger show -
    assert_refused 1 "tlogger: '-' is not a session id; name a session folder elsewhere by a path with a /"
    run_tlogger replay 20261112T100000Z-zzzzzz
    assert_refused 1 'tlogger: there is no session 20261112T100000Z-zzzzzz in ~/.local/state/tlogger/sessions'
    run_tlogger show "$HOME/missing/case"
    assert_refused 1 'tlogger: ~/missing/case does not exist'
    : > "$HOME/file"
    run_tlogger render "$HOME/file"
    assert_refused 1 'tlogger: ~/file is not a folder'
    mkdir "$HOME/case"
    run_tlogger show "$HOME/case"
    assert_refused 1 'tlogger: ~/case holds no output.raw, so it is not a session folder'
    : > "$HOME/case/output.raw"
    run_tlogger show "$HOME/case"
    assert_refused 1 'tlogger: ~/case holds no timing, so it is not a session folder'
    mkdir "$HOME/case/timing"
    run_tlogger show "$HOME/case"
    assert_refused 1 'tlogger: ~/case/timing is not a regular file'
    rm "$HOME/case/output.raw"
    mkdir "$HOME/case/output.raw"
    run_tlogger show "$HOME/case"
    assert_refused 1 'tlogger: ~/case/output.raw is not a regular file'
    run_tlogger show "$LOGS/."
    assert_refused 1 'tlogger: name the session folder itself in the path, not . or ..'
    run_tlogger show "$LOGS/$ID/.."
    assert_refused 1 'tlogger: name the session folder itself in the path, not . or ..'
}

@test "a symlink as the session folder, as one of its logs or as the log folder is refused" {
    need symlinks
    session_new "$LOGS/$ID"
    fresh_transcript 'the real session'
    ln -s "$LOGS/$ID" "$HOME/link"
    run_tlogger show "$HOME/link"
    assert_refused 1 'tlogger: ~/link is a symlink, which tlogger does not follow'
    # A symlink in the log folder, by a name newer than every session's.
    ln -s "$LOGS/$ID" "$LOGS/20261112T235959Z-zzzzzz"
    run_tlogger show 20261112T235959Z-zzzzzz
    assert_refused 1 'tlogger: ~/.local/state/tlogger/sessions/20261112T235959Z-zzzzzz is a symlink, which tlogger does not follow'
    run_tlogger show
    [ "$status" -eq 0 ]
    [ "${output##*$'\n'}" = 'the real session' ]
    session_new "$HOME/case"
    mv "$HOME/case/output.raw" "$HOME/output.raw"
    ln -s "$HOME/output.raw" "$HOME/case/output.raw"
    run_tlogger show "$HOME/case"
    assert_refused 1 'tlogger: ~/case/output.raw is a symlink, which tlogger does not follow'
    session_new "$HOME/case2"
    mv "$HOME/case2/timing" "$HOME/timing"
    ln -s "$HOME/timing" "$HOME/case2/timing"
    run_tlogger show "$HOME/case2"
    assert_refused 1 'tlogger: ~/case2/timing is a symlink, which tlogger does not follow'
    mv "$LOGS" "$HOME/logs"
    ln -s "$HOME/logs" "$LOGS"
    run_tlogger show "$ID"
    assert_refused 1 'tlogger: the log folder ~/.local/state/tlogger/sessions is a symlink, which tlogger does not follow'
}

@test "a timing file that cannot be read exits 1" {
    need modes
    session_new "$LOGS/$ID"
    chmod 000 "$LOGS/$ID/timing"
    run_tlogger show "$ID"
    assert_refused 1 "tlogger: cannot read ~/.local/state/tlogger/sessions/$ID/timing"
    chmod 600 "$LOGS/$ID/timing"
}

@test "the logdir in the config is where an id or the newest session is looked up" {
    mkdir -p "$HOME/.config/tlogger"
    printf 'mode=manual\nlogdir=%s\n' "$HOME/evidence/" > "$HOME/.config/tlogger/config"
    session_new "$HOME/evidence/$ID"
    fresh_transcript 'in the evidence folder'
    session_new "$LOGS/20261112T235959Z-zzzzzz"
    fresh_transcript 'in the default log folder'
    run_tlogger show
    [ "$status" -eq 0 ]
    [ "${output##*$'\n'}" = 'in the evidence folder' ]
    run_tlogger show "$ID"
    [ "$status" -eq 0 ]
    [ "${output##*$'\n'}" = 'in the evidence folder' ]
    printf 'not a key line\n' > "$HOME/.config/tlogger/config"
    run_tlogger show "$ID"
    assert_refused 1 'tlogger: the config ~/.config/tlogger/config has line 1, which is not a key=value line; fix it by hand'
}

@test "usage errors exit 2: extra sessions, unknown options and bad --speed and --maxdelay values" {
    local value
    run_tlogger render a b
    assert_usage_error 'tlogger: render takes one session at most'
    run_tlogger show -- a b
    assert_usage_error 'tlogger: show takes one session at most'
    run_tlogger replay a b
    assert_usage_error 'tlogger: replay takes one session at most'
    run_tlogger render --x
    assert_usage_error 'tlogger: unknown option for render: --x'
    run_tlogger show -x
    assert_usage_error 'tlogger: unknown option for show: -x'
    run_tlogger replay --speeds 2
    assert_usage_error 'tlogger: unknown option for replay: --speeds'
    run_tlogger replay --speed
    assert_usage_error 'tlogger: --speed needs a value: a positive decimal number'
    run_tlogger replay "$ID" --maxdelay
    assert_usage_error 'tlogger: --maxdelay needs a value: a positive decimal number'
    for value in abc 0 0.0 00 .0 2. 1e3 -1 '' ' 1' 1,5 0x10 123456789012345678901; do
        run_tlogger replay --speed "$value"
        assert_usage_error "tlogger: --speed takes a positive decimal number, not '$value'"
        run_tlogger replay "--maxdelay=$value"
        assert_usage_error "tlogger: --maxdelay takes a positive decimal number, not '$value'"
    done
}

@test "replay hands scriptreplay --divisor, --maxdelay and a cleaned copy of the timing, and filters it" {
    need python3
    local garbage timing_sum
    local -a args
    make_scriptreplay
    session_new "$LOGS/$ID"
    session_out 'hello\r\n'
    session_winch 30 100
    session_timing garbage
    session_in 'x'
    session_end
    garbage=$(grep -n '^garbage$' "$SDIR/timing" | cut -d: -f1)
    timing_sum=$(sha_of "$SDIR/timing")
    printf '%b' 'shown\e]52;c;aGVsbG8=\a\e[31mred\e[0m\e[6n\e[?1000h\r\n' > "$HOME/replay-out"
    TLOGGER_PYTHON=$PYTHON3 TLOGGER_SCRIPTREPLAY=$HOME/bin/scriptreplay \
        run_cmd replay --speed 2 --maxdelay=.25 "$ID"
    [ "$status" -eq 0 ]
    [ "$output" = $'shown\e[31mred\e[0m\r\n'"$FILTER_RESTORE" ]
    [ "$stderr" = "tlogger: warning: timing line $garbage is malformed; skipped" ]
    mapfile -t args < "$HOME/replay-args"
    [ "${#args[@]}" -eq 8 ]
    [ "${args[0]}" = --log-timing ]
    [[ ${args[1]} == "$TMPDIR"/tlogger.*/timing ]]
    [ "${args[*]:2}" = "--log-out $LOGS/$ID/output.raw --divisor 2 --maxdelay .25" ]
    # Only the I, O and S lines go to scriptreplay, as they are.
    [ "$(cat "$HOME/replay-timing")" = "$(printf '%s\n' 'O 0.010000 7' \
        'S 0.300000 SIGWINCH ROWS=30 COLS=100' 'I 0.200000 1')" ]
    [ "$(sha_of "$SDIR/timing")" = "$timing_sum" ]
    refute_temp_left
}

@test "a scriptreplay that fails gives its messages, home paths as ~, and exit 1" {
    need python3
    make_scriptreplay
    printf '3\n' > "$HOME/replay-status"
    session_new "$LOGS/$ID"
    session_out 'hello\r\n'
    session_end
    TLOGGER_PYTHON=$PYTHON3 TLOGGER_SCRIPTREPLAY=$HOME/bin/scriptreplay run_cmd replay
    [ "$status" -eq 1 ]
    [ "$output" = "$FILTER_RESTORE" ]
    [ "$stderr" = "tlogger: scriptreplay: scriptreplay: cannot open ~/replay-out: No such file or directory
tlogger: the replay of session $ID failed: scriptreplay exited with status 3" ]
    refute_home_shown
    refute_temp_left
}

@test "replay without scriptreplay or python3 exits 1 with the message, after the session check" {
    make_scriptreplay
    make_tool python-store 'exit 9009'
    session_new "$LOGS/$ID"
    session_out 'hello\r\n'
    session_end
    TLOGGER_SCRIPTREPLAY=$HOME/missing run_tlogger replay
    assert_refused 1 'tlogger: replay needs scriptreplay, from util-linux'
    TLOGGER_SCRIPTREPLAY=$HOME/bin/scriptreplay TLOGGER_PYTHON=$HOME/missing run_tlogger replay
    assert_refused 1 'tlogger: replay needs python3'
    # As the stub of the Windows Store does, a python3 that only fails is no python3.
    TLOGGER_SCRIPTREPLAY=$HOME/bin/scriptreplay TLOGGER_PYTHON=$HOME/bin/python-store \
        run_tlogger replay
    assert_refused 1 'tlogger: replay needs python3'
    TLOGGER_SCRIPTREPLAY=$HOME/missing run_tlogger replay nope
    assert_refused 1 "tlogger: 'nope' is not a session id; name a session folder elsewhere by a path with a /"
    [ ! -e "$HOME/replay-args" ]
    refute_temp_left
}

@test "render and show without python3 or pyte exit 1 with the message, after the session check" {
    local cmd
    make_tool python-store 'exit 9009'
    # shellcheck disable=SC2016 # sh expands it, not bash.
    make_tool python-nopyte 'case "$*" in *" probe --pyte") echo no-pyte ;; *" probe") echo ok ;; *) exit 1 ;; esac'
    session_new "$LOGS/$ID"
    session_out 'hello\r\n'
    session_end
    for cmd in render show; do
        TLOGGER_PYTHON=$HOME/missing run_tlogger "$cmd"
        assert_refused 1 "tlogger: $cmd needs python3"
        TLOGGER_PYTHON=$HOME/bin/python-store run_tlogger "$cmd"
        assert_refused 1 "tlogger: $cmd needs python3"
        TLOGGER_PYTHON=$HOME/bin/python-nopyte run_tlogger "$cmd" "$ID"
        assert_refused 1 "tlogger: $cmd needs python3-pyte (apt install python3-pyte)"
        TLOGGER_PYTHON=$HOME/missing run_tlogger "$cmd" nope
        assert_refused 1 "tlogger: 'nope' is not a session id; name a session folder elsewhere by a path with a /"
    done
    [ ! -e "$SDIR/transcript.txt" ]
}

@test "render, show and replay name a tlogger_view.py that is missing, not python3" {
    local cmd
    make_scriptreplay
    # A source tree, as a release folder holds one, that lacks libexec/tlogger_view.py.
    mkdir -p "$HOME/tree/bin"
    cp "$TLOGGER" "$HOME/tree/bin/tlogger"
    cp "$REPO_ROOT/VERSION" "$HOME/tree/VERSION"
    session_new "$LOGS/$ID"
    session_out 'hello\r\n'
    session_end
    for cmd in render show replay; do
        TLOGGER_PYTHON=$HOME/missing TLOGGER_SCRIPTREPLAY=$HOME/bin/scriptreplay \
            run --separate-stderr bash "$HOME/tree/bin/tlogger" "$cmd" < /dev/null
        assert_refused 1 "tlogger: $cmd cannot read ~/tree/libexec/tlogger_view.py; install tlogger again"
    done
    [ ! -e "$HOME/replay-args" ]
    refute_temp_left
}

@test "show prints a transcript newer than the logs as it is, without python3" {
    session_new "$LOGS/$ID"
    fresh_transcript 'kept as it is'
    TLOGGER_PYTHON=$HOME/missing run_tlogger show
    [ "$status" -eq 0 ]
    [ "$output" = "$(transcript_header "$ID"; echo 'kept as it is')" ]
    [ -z "$stderr" ]
}

@test "show does not print a transcript that holds control bytes or lacks render's header, and renders it again" {
    session_new "$LOGS/$ID"
    local body
    # OSC 52 writes the clipboard of the terminal and CSI 6 n makes it answer.
    for body in 'x\e]52;c;aGVsbG8=\a\n' 'x\e[6n\n' 'x\x00y\n' 'x\x01y\n' 'x\x7fy\n' 'x\xc2\x9b6ny\n' \
        'x\xc2\x80y\n' 'x\xc2\x9fy\n'; do
        crafted_transcript "$body"
        TLOGGER_PYTHON=$HOME/missing run_tlogger show
        assert_refused 1 'tlogger: show needs python3'
    done
    # No header, or the header of another session; the text is harmless.
    printf 'plain text\n' > "$SDIR/transcript.txt"
    touch -d '2001-01-01 00:00:00' "$SDIR/output.raw" "$SDIR/timing"
    TLOGGER_PYTHON=$HOME/missing run_tlogger show
    assert_refused 1 'tlogger: show needs python3'
    { transcript_header 20261111T100000Z-zzzzzz; echo 'plain text'; } > "$SDIR/transcript.txt"
    touch -d '2001-01-01 00:00:00' "$SDIR/output.raw" "$SDIR/timing"
    TLOGGER_PYTHON=$HOME/missing run_tlogger show
    assert_refused 1 'tlogger: show needs python3'
}

@test "show keeps a transcript with tabs and UTF-8 that is no C1 control" {
    session_new "$LOGS/$ID"
    crafted_transcript 'a\tb caf\xc3\xa9 \xe2\x94\x80 \xc2\xa0 \xc2\xa9\n'
    TLOGGER_PYTHON=$HOME/missing run_tlogger show
    [ "$status" -eq 0 ]
    [ "${output##*$'\n'}" = $'a\tb caf\xc3\xa9 \xe2\x94\x80 \xc2\xa0 \xc2\xa9' ]
}

@test "show renders a crafted transcript again instead of printing it" {
    need pyte
    session_new "$LOGS/$ID"
    session_out 'fresh output\r\n'
    session_end
    crafted_transcript 'x\e]52;c;aGVsbG8=\a\n'
    TLOGGER_PYTHON=$PYTHON3 run_tlogger show
    [ "$status" -eq 0 ]
    [ "${output#*$'\n'}" = 'fresh output' ]
    [ "$(tail -n +2 "$SDIR/transcript.txt")" = 'fresh output' ]
}

@test "render writes transcript.txt and names it with ~, and --stdout prints it and writes nothing" {
    need pyte
    session_new "$LOGS/$ID"
    session_out '$ id\r\nuid=1000(kali) gid=1000(kali)\r\n'
    session_end
    TLOGGER_PYTHON=$PYTHON3 run_tlogger render
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$stderr" = "tlogger: transcript ~/.local/state/tlogger/sessions/$ID/transcript.txt" ]
    assert_transcript_header "$SDIR/transcript.txt" "$ID" "$VERSION_TEXT"
    [ "$(tail -n +2 "$SDIR/transcript.txt")" = $'$ id\nuid=1000(kali) gid=1000(kali)' ]
    rm "$SDIR/transcript.txt"
    TLOGGER_PYTHON=$PYTHON3 run_tlogger render --stdout "$ID"
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/stdout"
    assert_transcript_header "$BATS_TEST_TMPDIR/stdout" "$ID" "$VERSION_TEXT"
    [ "${output#*$'\n'}" = $'$ id\nuid=1000(kali) gid=1000(kali)' ]
    [ ! -e "$SDIR/transcript.txt" ]
    [ ! -e "$SDIR/transcript.txt.part" ]
    refute_temp_left
}

@test "show renders a missing or stale transcript first, and prints it without a terminal" {
    need pyte
    session_new "$LOGS/$ID"
    session_out 'fresh output\r\n'
    session_end
    TLOGGER_PYTHON=$PYTHON3 run_tlogger show
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    [ "${output#*$'\n'}" = 'fresh output' ]
    [ "$output" = "$(cat "$SDIR/transcript.txt")" ]
    printf 'stale\n' > "$SDIR/transcript.txt"
    touch -d '2001-01-01 00:00:00' "$SDIR/transcript.txt"
    TLOGGER_PYTHON=$PYTHON3 run_tlogger show "$ID"
    [ "$status" -eq 0 ]
    [ "${output#*$'\n'}" = 'fresh output' ]
    [ "$(tail -n +2 "$SDIR/transcript.txt")" = 'fresh output' ]
}

@test "show does not page through a transcript.txt that is a symlink, which render refuses" {
    need pyte
    need symlinks
    session_new "$LOGS/$ID"
    session_out 'fresh output\r\n'
    session_end
    printf 'elsewhere\n' > "$HOME/elsewhere"
    ln -s "$HOME/elsewhere" "$SDIR/transcript.txt"
    TLOGGER_PYTHON=$PYTHON3 run_tlogger show
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [ "$stderr" = "tlogger: session $ID: transcript.txt is a symlink, which tlogger does not write through; remove it" ]
    [ "$(cat "$HOME/elsewhere")" = elsewhere ]
}

@test "replay runs util-linux scriptreplay through the filter, also on H lines with a comma" {
    need scriptreplay
    need python3
    local want middle
    session_new "$LOGS/$ID"
    # The H lines as script writes them under a locale such as de_DE, which scriptreplay 2.42
    # cannot read; replay hands it a copy without them.
    printf 'H 0,000000 %s\n' 'START_TIME 2026-11-12 10:00:00+00:00' 'COLUMNS 80' 'LINES 24' \
        > "$SDIR/timing"
    session_out 'one\r\n'
    session_in 'x'
    session_out '\e]0;title\atwo\e[6n\r\n'
    session_winch 30 100
    session_out '\e[?2004hthree\r\n'
    session_end
    TLOGGER_PYTHON=$PYTHON3 run_cmd replay --speed 4 --maxdelay 0.5
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    want=$'one\r\ntwo\r\nthree\r\n'
    [[ $output == "$want"* && $output == *"$FILTER_RESTORE" ]]
    # scriptreplay may end with a newline of its own.
    middle=${output#"$want"}
    middle=${middle%"$FILTER_RESTORE"}
    [[ -z $middle || $middle == $'\n' ]]
    refute_temp_left
}
