#!/usr/bin/env bats
# Runs tlogger show and replay in a real pseudo-terminal, as a person does, on made-up sessions:
# the pager and its secure mode, the replay keys, Ctrl+C and the terminal they leave behind.
# Gaps are whole seconds with seconds of margin, and every wait has a hard deadline.

bats_require_minimum_version 1.5.0

load helpers

# Run before each test by bats.
# Gives the test its own HOME with an empty log folder, the e2e fixture rc and the tools below.
setup() {
    isolate_home
    isolate_tlogger
    need zsh
    need zpty
    need scriptreplay
    need modes
    # bin/tlogger runs /usr/bin/python3, so that is the python3 that must have pyte here.
    # shellcheck disable=SC2034 # need reads it.
    PYTHON3=/usr/bin/python3
    need pyte
    export ID=20261112T100000Z-a1B2c3 TLOGGER FILTER_RESTORE
    LOGS="$HOME/.local/state/tlogger/sessions"
    SCREEN="$BATS_TEST_TMPDIR/screen"
    mkdir -p "$LOGS" "$HOME/bin"
    cp "$REPO_ROOT/tests/fixtures/e2e-zshrc" "$HOME/.zshrc"
    make_tools
}

# Write two tools to ~/bin. jj records that it ran; the tests name it wherever a pager that is not
# secure would run a command, and as pager keys its name only scrolls. tty-replay runs tlogger
# replay and saves, inside the job, the terminal settings and O_NONBLOCK as replay left them: zsh
# clears that flag before it reads its next line. Its trap is not an ignore, because bash cannot
# trap a signal that was ignored when it started.
make_tools() {
    cat > "$HOME/bin/jj" << 'EOF'
#!/bin/sh
: > "$HOME/tool-ran"
EOF
    cat > "$HOME/bin/tty-replay" << 'EOF'
#!/bin/sh
trap : INT
bash "$TLOGGER" replay "$@"
code=$?
stty -g > "$HOME/tty-after"
/usr/bin/python3 -I -c 'import fcntl, os; print(fcntl.fcntl(0, fcntl.F_GETFL) & os.O_NONBLOCK)' \
    > "$HOME/nonblock-after"
exit "$code"
EOF
    chmod 755 "$HOME/bin/jj" "$HOME/bin/tty-replay"
}

# Run the zsh code on stdin as the driver, after the helpers below: zsh -f with
# tests/helpers/pty.zsh loaded, under a hard timeout, with fd 3 closed so that nothing it starts
# can hold bats up. SCREEN receives everything the terminal printed.
#   term_shell   starts the shell in a 24x80 xterm, with ~/bin first on PATH.
#   shell_works  fails unless the shell still runs a command.
#   tty_is       fails unless tty-replay saved the terminal settings SAVED.
drive() {
    {
        cat << 'EOF'
term_shell() {
    pty_shell TERM=xterm "PATH=$HOME/bin:$PATH" "TLOGGER=$TLOGGER" "TMPDIR=$TMPDIR" "$@"
}
shell_works() {
    pty_run 'print -r -- shell-ok-$((6*7))'
    pty_out_is shell-ok-42 || pty_fail "the shell printed ${(V)PTY_OUT}"
}
tty_is() {
    [[ $(<$HOME/tty-after) == "$1" ]] ||
        pty_fail "the terminal settings are $(<$HOME/tty-after), not $1"
}
EOF
        cat
    } > "$BATS_TEST_TMPDIR/driver.zsh"
    : > "$SCREEN"
    # zsh expands these, not bash.
    # shellcheck disable=SC2016
    PTY_SCREEN_FILE=$SCREEN timeout -k 5 150 zsh -f -c 'source "$1" && source "$2"' zsh \
        "$REPO_ROOT/tests/helpers/pty.zsh" "$BATS_TEST_TMPDIR/driver.zsh" < /dev/null 3>&-
}

# Create the session ID with 200 numbered lines, more than one screen of the pager holds.
page_session() {
    local text='' line i
    session_new "$LOGS/$ID"
    for (( i = 1; i <= 200; i++ )); do
        printf -v line 'page-line-%03d\\r\\n' "$i"
        text+=$line
    done
    session_out "$text"
    session_end
}

# Create the session ID from pairs of DELAY and TEXT: each TEXT is one line of output that comes
# DELAY seconds after the one before.
timed_session() {
    local chunk="$BATS_TEST_TMPDIR/session-chunk"
    session_new "$LOGS/$ID"
    while (( $# )); do
        printf '%s\r\n' "$2" > "$chunk"
        cat "$chunk" >> "$SDIR/output.raw"
        printf 'O %s %s\n' "$1" "$(( $(wc -c < "$chunk") ))" >> "$SDIR/timing"
        shift 2
    done
    session_end
}

# Set and export NOLESS, a folder of links to everything on PATH except less.
path_without_less() {
    local dir
    local -a dirs
    export NOLESS="$BATS_TEST_TMPDIR/noless"
    mkdir -p "$NOLESS"
    IFS=: read -r -a dirs <<< "$PATH"
    for dir in "${dirs[@]}"; do
        if [[ -d $dir ]]; then
            # ln keeps the first of two tools with one name and complains about the second.
            find "$dir/" -maxdepth 1 ! -type d ! -name less -exec ln -s -t "$NOLESS" {} + \
                2> /dev/null || true
        fi
    done
}

@test "show opens the pager on the first page, and q returns to a working shell with status 0" {
    need command less
    page_session
    drive << 'EOF'
term_shell
pty_begin "bash \"\$TLOGGER\" show $ID"
n=$REPLY
pty_expect '# DERIVED transcript'
pty_expect page-line-001
pty_expect page-line-015
pty_absent page-line-100 1
pty_type q
pty_end $n
(( PTY_STATUS == 0 )) || pty_fail "show returned $PTY_STATUS"
shell_works
pty_close
EOF
}

@test "the pager's shell, pipe, editor and log-file keys run nothing" {
    need command less
    page_session
    # The first three would run jj in a pager that is not secure. less never saves a regular file,
    # so the log-file key -O is checked by the message that only secure mode prints.
    drive << 'EOF'
term_shell "SHELL=$HOME/bin/jj" "VISUAL=$HOME/bin/jj" "EDITOR=$HOME/bin/jj"
pty_run 'cd ~'
pty_begin "bash \"\$TLOGGER\" show $ID"
n=$REPLY
pty_expect page-line-015
for keys in $'!jj\n' $'|.jj\n' $'v\n' $'-Ojj\n'; do
    pty_type $keys
    pty_expect 'not available'
done
pty_type q
pty_end $n
(( PTY_STATUS == 0 )) || pty_fail "show returned $PTY_STATUS"
shell_works
[[ ! -e $HOME/tool-ran ]] || pty_fail 'a pager key ran a command'
pty_close
EOF
}

@test "LESSSECURE_ALLOW cannot turn the pager's shell key back on" {
    need command less
    page_session
    drive << 'EOF'
term_shell "SHELL=$HOME/bin/jj" 'LESSSECURE_ALLOW=shell'
pty_begin "bash \"\$TLOGGER\" show $ID"
n=$REPLY
pty_expect page-line-015
pty_type $'!jj\n'
pty_expect 'not available'
pty_type q
pty_end $n
(( PTY_STATUS == 0 )) || pty_fail "show returned $PTY_STATUS"
[[ ! -e $HOME/tool-ran ]] || pty_fail 'the shell key ran a command'
pty_close
EOF
}

@test "LESS_IS_MORE with MORE cannot pass options to the pager" {
    need command less
    page_session
    # LESS_IS_MORE makes less read its options from MORE, and +G would open it on the last page.
    drive << 'EOF'
term_shell 'LESS_IS_MORE=1' 'MORE=+G'
pty_begin "bash \"\$TLOGGER\" show $ID"
n=$REPLY
pty_expect page-line-001
pty_absent page-line-200 1
pty_type q
pty_end $n
(( PTY_STATUS == 0 )) || pty_fail "show returned $PTY_STATUS"
pty_close
EOF
}

@test "a hostile LESS, LESSOPEN or LESSCLOSE has no effect on show" {
    need command less
    page_session
    # LESS=+G would open the pager on the last page, and the other two would run jj.
    drive << 'EOF'
term_shell 'LESS=+G' "LESSOPEN=|$HOME/bin/jj %s" "LESSCLOSE=$HOME/bin/jj %s %s"
pty_begin "bash \"\$TLOGGER\" show $ID"
n=$REPLY
pty_expect page-line-001
pty_absent page-line-200 1
pty_type q
pty_end $n
(( PTY_STATUS == 0 )) || pty_fail "show returned $PTY_STATUS"
shell_works
[[ ! -e $HOME/tool-ran ]] || pty_fail 'LESSOPEN or LESSCLOSE ran a command'
pty_close
EOF
}

@test "without less, show prints the whole transcript to the terminal" {
    need symlinks
    page_session
    path_without_less
    drive << 'EOF'
term_shell "PATH=$HOME/bin:$NOLESS"
pty_run 'command -v less'
(( PTY_STATUS != 0 )) || pty_fail "less is still on PATH: $PTY_OUT"
pty_run "bash \"\$TLOGGER\" show $ID"
(( PTY_STATUS == 0 )) || pty_fail "show returned $PTY_STATUS"
[[ $PTY_OUT == '# DERIVED transcript'* ]] || pty_fail "the output starts ${(V)PTY_OUT[1,80]}"
pty_out_has page-line-001 || pty_fail 'the first line is missing'
pty_out_has page-line-200 || pty_fail 'the last line is missing'
[[ $PTY_OUT != *$'\e'* ]] || pty_fail 'a plain print holds an escape sequence'
shell_works
pty_close
EOF
}

@test "replay shows its keys, plays the session and leaves the terminal as it was" {
    local f
    local -A sums=()
    timed_session 0.100000 replay-one 1.000000 replay-two
    for f in output.raw input.raw timing commands.tsv; do
        sums[$f]=$(sha_of "$SDIR/$f")
    done
    drive << 'EOF'
term_shell
pty_stty
saved=$REPLY
pty_run "tty-replay $ID"
(( PTY_STATUS == 0 )) || pty_fail "replay returned $PTY_STATUS"
pty_out_has "tlogger: replaying session $ID: Space pauses, Up and Down change the speed, Ctrl+C stops" ||
    pty_fail "no key help in ${(V)PTY_OUT}"
[[ $PTY_OUT == *replay-one*replay-two*"$FILTER_RESTORE"* ]] ||
    pty_fail "not the session, then the restore sequence: ${(V)PTY_OUT}"
tty_is $saved
shell_works
pty_close
EOF
    for f in output.raw input.raw timing commands.tsv; do
        [ "$(sha_of "$SDIR/$f")" = "${sums[$f]}" ]
    done
    refute_temp_left
}

@test "Space pauses a replay and a second Space continues it" {
    timed_session 0.100000 pause-one 5.000000 pause-two 1.000000 pause-three
    # Paused for longer than the 5-second gap, so the second line can only come after the key.
    drive << 'EOF'
term_shell
pty_begin "tty-replay $ID"
n=$REPLY
pty_expect pause-one
pty_type ' '
pty_absent pause-two 7
pty_type ' '
pty_expect pause-two
pty_expect pause-three
pty_end $n
(( PTY_STATUS == 0 )) || pty_fail "replay returned $PTY_STATUS"
pty_close
EOF
}

@test "the Up key makes a replay faster" {
    timed_session 0.100000 up-one 6.000000 up-two 30.000000 up-three
    # scriptreplay takes one key per 100 ms and applies the pace to the next gap. 24 presses make
    # it about 9.8 times as fast, so the 30-second gap ends well inside the 20-second deadline.
    drive << 'EOF'
term_shell
pty_begin "tty-replay $ID"
n=$REPLY
pty_expect up-one
keys=
repeat 24 keys+=$'\e[A'
pty_type $keys
pty_expect up-two
pty_expect up-three 20
pty_end $n
(( PTY_STATUS == 0 )) || pty_fail "replay returned $PTY_STATUS"
pty_close
EOF
}

@test "the Down key makes a replay slower" {
    timed_session 0.100000 down-one 5.000000 down-two 3.000000 down-three
    # 12 presses make it about 0.28 times as fast, so the 3-second gap lasts 10 seconds.
    drive << 'EOF'
term_shell
pty_begin "tty-replay $ID"
n=$REPLY
pty_expect down-one
keys=
repeat 12 keys+=$'\e[B'
pty_type $keys
pty_expect down-two
pty_absent down-three 5
pty_expect down-three
pty_end $n
(( PTY_STATUS == 0 )) || pty_fail "replay returned $PTY_STATUS"
pty_close
EOF
}

@test "Ctrl+C stops a replay with status 130, restores the terminal and the shell still works" {
    timed_session 0.100000 ctrl-one 30.000000 ctrl-two
    drive << 'EOF'
term_shell
pty_stty
saved=$REPLY
pty_begin "tty-replay $ID"
n=$REPLY
pty_expect ctrl-one
pty_type $'\x03'
pty_end $n
(( PTY_STATUS == 130 )) || pty_fail "replay returned $PTY_STATUS"
[[ $PTY_OUT == *ctrl-one*"$FILTER_RESTORE"* ]] || pty_fail "no restore in ${(V)PTY_OUT}"
[[ $PTY_OUT != *ctrl-two* ]] || pty_fail 'the replay went on after Ctrl+C'
tty_is $saved
shell_works
pty_close
EOF
    refute_temp_left
}

@test "keys typed during a replay do not reach the shell afterwards" {
    timed_session 0.100000 spill-one 3.000000 spill-two
    drive << 'EOF'
term_shell
pty_begin "tty-replay $ID"
n=$REPLY
pty_expect spill-one
pty_type $'jj\n'
pty_end $n
(( PTY_STATUS == 0 )) || pty_fail "replay returned $PTY_STATUS"
shell_works
[[ ! -e $HOME/tool-ran ]] || pty_fail 'a key typed during the replay ran in the shell'
pty_close
EOF
}

@test "keys still queued when a replay ends do not reach the shell" {
    timed_session 0.100000 late-one 3.000000 late-two
    # scriptreplay reads the terminal only when its key buffer is empty and takes one key per
    # 100 ms. The 60 keys last past the end of the replay, so the line typed after them stays queued.
    drive << 'EOF'
term_shell
pty_begin "tty-replay $ID"
n=$REPLY
pty_expect late-one
keys=
repeat 60 keys+=x
pty_type $keys
pty_pause 50
pty_type $'jj\n'
pty_end $n
(( PTY_STATUS == 0 )) || pty_fail "replay returned $PTY_STATUS"
shell_works
[[ ! -e $HOME/tool-ran ]] || pty_fail 'a key queued at the end of the replay ran in the shell'
pty_close
EOF
}

@test "hostile sequences in a session do not reach the live terminal" {
    session_new "$LOGS/$ID"
    # A title, a clipboard write, three requests for an answer, mouse reporting, DCS, APC and PM.
    session_out 'safe-one\r\n\e]0;evil-title\a\e]52;c;ZXZpbA==\a\e[6n\e[c\e[21t\e[?1000h\eP1\x24qm\e\\\e_evil-apc\e\\\e^evil-pm\e\\\e[31mred-text\e[0m\r\nsafe-two\r\n'
    session_end
    drive << 'EOF'
term_shell
pty_run "tty-replay $ID"
(( PTY_STATUS == 0 )) || pty_fail "replay returned $PTY_STATUS"
[[ $PTY_OUT == *safe-one*$'\e[31mred-text'*safe-two* ]] ||
    pty_fail "the harmless output is missing: ${(V)PTY_OUT}"
for bad in $'\e]' $'\e[6n' $'\e[c' $'\e[21t' $'\e[?1000h' $'\eP' $'\e_' $'\e^' \
    evil-title ZXZpbA evil-apc evil-pm; do
    [[ $PTY_OUT != *"$bad"* ]] || pty_fail "the terminal got ${(V)bad}"
done
shell_works
pty_close
EOF
}

@test "replay leaves the shell's terminal file blocking" {
    timed_session 0.100000 block-one
    # scriptreplay sets O_NONBLOCK on its stdin and keeps it there when its stdout is a pipe.
    drive << 'EOF'
term_shell
pty_run "tty-replay $ID"
(( PTY_STATUS == 0 )) || pty_fail "replay returned $PTY_STATUS"
[[ $(<$HOME/nonblock-after) == 0 ]] ||
    pty_fail "O_NONBLOCK is set on the shell's terminal: $(<$HOME/nonblock-after)"
pty_close
EOF
}
