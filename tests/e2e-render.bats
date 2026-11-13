#!/usr/bin/env bats
# End-to-end test of tlogger render, show and replay on a session recorded for real: tlogger,
# installed from the work tree in manual mode on the e2e fixture rc, records a zsh in a
# pseudo-terminal that zsh's zpty module drives (tests/helpers/pty.zsh), where commands print,
# clear the screen and exit. Needs what e2e-manual.bats needs, /usr/bin/python3 with pyte and
# util-linux scriptreplay.

bats_require_minimum_version 1.5.0

load helpers

# Run before each test by bats.
# Gives the test its own HOME, with tlogger installed in manual mode on top of the e2e fixture rc.
setup() {
    isolate_home
    isolate_tlogger
    need zsh
    need zpty
    need script
    need scriptreplay
    need proc
    need symlinks
    need modes
    # bin/tlogger runs /usr/bin/python3, so that is the python3 that must have pyte here.
    # shellcheck disable=SC2034 # need reads it.
    PYTHON3=/usr/bin/python3
    need pyte
    IFS= read -r VERSION_TEXT < "$REPO_ROOT/VERSION"
    SESSIONS="$HOME/.local/state/tlogger/sessions"
    SCREEN="$BATS_TEST_TMPDIR/screen"
    cp "$REPO_ROOT/tests/fixtures/e2e-zshrc" "$HOME/.zshrc"
    run_tlogger install --mode manual --yes
    [ "$status" -eq 0 ]
}

# Run the zsh code on stdin as the driver: zsh -f with tests/helpers/pty.zsh loaded, under a hard
# timeout, with fd 3 closed so that nothing it starts can hold bats up. A driver that gives up
# fails the test with a report on stderr. SCREEN receives everything the terminal printed.
drive() {
    cat > "$BATS_TEST_TMPDIR/driver.zsh"
    : > "$SCREEN"
    # zsh expands these, not bash.
    # shellcheck disable=SC2016
    PTY_SCREEN_FILE=$SCREEN timeout -k 5 150 zsh -f -c 'source "$1" && source "$2"' zsh \
        "$REPO_ROOT/tests/helpers/pty.zsh" "$BATS_TEST_TMPDIR/driver.zsh" < /dev/null 3>&-
}

# Print the number of the first line of FILE that is TEXT, whole.
line_of() {
    grep -n -x -F -m 1 -- "$2" "$1" | cut -d: -f1
}

@test "a recorded session renders to a transcript that keeps its output across clear, and replays" {
    # The shell runs under TERM=dumb, which has no clear; clear runs under TERM=xterm, so that it
    # sends ED 2 and ED 3. printf sends what a hostile target could: a title in an OSC, a cursor
    # position request and mouse reporting on. The typed command spells the title as
    # e2e-$((6*7))-title, so only its output holds e2e-42-title.
    drive << 'EOF'
pty_shell
pty_begin 'tlogger start'
start=$REPLY
pty_session
pty_run 'echo e2e-before-clear-$((6*7))'
pty_out_is e2e-before-clear-42 || pty_fail "echo printed $PTY_OUT"
pty_run 'TERM=xterm clear'
(( PTY_STATUS == 0 )) || pty_fail "clear returned $PTY_STATUS"
[[ $PTY_OUT == *$'\e[2J'* ]] || pty_fail "clear printed ${(V)PTY_OUT}"
pty_run 'print -r -- e2e-after-clear'
pty_out_is e2e-after-clear || pty_fail "print printed $PTY_OUT"
pty_run "printf '\\e]0;%s\\a\\e[6n\\e[?1000h' e2e-\$((6*7))-title"
[[ $PTY_OUT == *$'\e]0;e2e-42-title\a\e[6n\e[?1000h'* ]] || pty_fail "printf printed ${(V)PTY_OUT}"
pty_send exit
pty_end $start
(( PTY_STATUS == 0 )) || pty_fail "tlogger start returned $PTY_STATUS"
EOF
    local id dir transcript f before after
    local -A sums=()
    id=$(find "$SESSIONS" -mindepth 1 -maxdepth 1 -printf '%f\n')
    [[ $id =~ ^[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9]{6}$ ]]
    dir="$SESSIONS/$id"
    transcript="$dir/transcript.txt"
    for f in output.raw input.raw timing commands.tsv; do
        sums[$f]=$(sha_of "$dir/$f")
    done
    run_tlogger render
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$stderr" = "tlogger: transcript ~/.local/state/tlogger/sessions/$id/transcript.txt" ]
    [ "$(stat -c %a "$transcript")" = 600 ]
    assert_transcript_header "$transcript" "$id" "$VERSION_TEXT"
    refute_controls "$transcript"
    grep -qF "tlogger: REC $id" "$transcript"
    # The output of the commands, in order, the lines before clear included.
    before=$(line_of "$transcript" e2e-before-clear-42)
    after=$(line_of "$transcript" e2e-after-clear)
    [[ $before =~ ^[0-9]+$ && $after =~ ^[0-9]+$ ]]
    (( before < after ))
    # shellcheck disable=SC2016 # The typed command, not an expansion.
    grep -qF 'e2e-$((6*7))-title' "$transcript"
    run ! grep -qF e2e-42-title "$transcript"
    for f in output.raw input.raw timing commands.tsv; do
        [ "$(sha_of "$dir/$f")" = "${sums[$f]}" ]
    done
    run_tlogger show
    [ "$status" -eq 0 ]
    [ "$output" = "$(cat "$transcript")" ]
    run_tlogger replay --speed 50 --maxdelay 0.01
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    [[ $output == *e2e-before-clear-42* && $output == *e2e-after-clear* ]]
    [[ $output == *"$FILTER_RESTORE" ]]
    # The filter drops the OSC with its title, the request and the mode.
    [[ $output != *$'\e]'* && $output != *e2e-42-title* ]]
    [[ $output != *$'\e[6n'* && $output != *$'\e[?1000h'* ]]
    refute_temp_left
}
