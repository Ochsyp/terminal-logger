#!/usr/bin/env bats
# End-to-end tests of tlogger start and stop: the plugin, installed from the work tree into the
# test's HOME on the e2e fixture rc, or on the rc built from /etc/skel/.zshrc, runs in a real zsh
# in a pseudo-terminal that zsh's zpty module drives (tests/helpers/pty.zsh); script records. They
# need Linux, zsh with zpty, script 2.35 or newer, symlinks, POSIX modes and a non-root user.

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
    need proc
    need symlinks
    need modes
    SESSIONS="$HOME/.local/state/tlogger/sessions"
    CONFIG="$HOME/.config/tlogger/config"
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

# Print the names in the sessions folder, one per line, sorted.
session_names() {
    find "$SESSIONS" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort
}

# Set DIR to the only session folder. Fails unless there is exactly one, named as tlogger names
# sessions: the UTC time, then 6 random characters.
one_session() {
    local -a names
    mapfile -t names < <(session_names)
    if (( ${#names[@]} != 1 )); then
        printf 'expected one session folder, found %s: %s\n' "${#names[@]}" "${names[*]}" >&2
        return 1
    fi
    [[ ${names[0]} =~ ^[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9]{6}$ ]]
    DIR="$SESSIONS/${names[0]}"
}

# Start the shell with the NAME=VALUE arguments in its environment and run tlogger start, which
# must refuse with REASON. Fails unless the refusal leaves what it promises: the red notice, exit
# status 1, a shell that still runs commands and no session folder.
assert_start_refused() {
    local reason=$1
    shift
    E2E_REASON=$reason E2E_ENV="$*" drive << 'EOF'
pty_shell ${=E2E_ENV}
pty_run 'tlogger start'
(( PTY_STATUS == 1 )) || pty_fail "tlogger start returned $PTY_STATUS, not 1"
[[ $PTY_OUT == $'\e[31m'"tlogger: NOT recording this terminal: $E2E_REASON"$'\e[0m\n' ]] ||
    pty_fail "tlogger start printed no red notice that says: $E2E_REASON"
pty_run 'tlogger status'
pty_out_has 'state: NOREC, this terminal is NOT recorded' || pty_fail 'the shell does not work after the refusal'
EOF
    [ -z "$(session_names)" ]
}

@test "tlogger start shows REC, and exit in the main shell writes exited and returns to the outer prompt" {
    drive << 'EOF'
pty_shell
pty_run 'tlogger status'
pty_out_has 'state: NOREC, this terminal is NOT recorded' || pty_fail 'the new shell is not NOREC'
pty_begin 'tlogger start'
start=$REPLY
pty_session
pty_run 'tlogger status'
pty_out_has "state: REC $PTY_ID" || pty_fail 'tlogger status in the recorded shell does not say REC'
pty_out_has "session: $PTY_ID" || pty_fail 'tlogger status in the recorded shell names no session'
pty_run 'print -r -- "TZ=${TZ-unset} HS=${+TLOGGER_HS}${+TLOGGER_HS_TZSET}${+TLOGGER_HS_TZ} SESSION=${TLOGGER_SESSION:t}"'
pty_out_is "TZ=unset HS=000 SESSION=$PTY_ID" || pty_fail "the recorded shell has: $PTY_OUT"
pty_send exit
pty_end $start
(( PTY_STATUS == 0 )) || pty_fail "tlogger start returned $PTY_STATUS after exit"
pty_out_has 'tlogger: recording ended; this terminal is NOT recorded' || pty_fail 'no notice that the recording ended'
pty_run 'tlogger status'
pty_out_has 'state: NOREC, this terminal is NOT recorded' || pty_fail 'the outer shell is not NOREC after exit'
EOF
    local pid start boot tty
    one_session
    [ -f "$DIR/started" ]
    [ -f "$DIR/exited" ]
    [ ! -e "$DIR/stop-requested" ]
    # script writes a header into each log as it starts, so only what was shown and typed in the
    # recorded shell proves that it recorded.
    grep -qF "tlogger: REC ${DIR##*/}" "$DIR/output.raw"
    grep -qF 'tlogger status' "$DIR/input.raw"
    grep -Eq '^I [0-9]+\.[0-9]+ [0-9]+$' "$DIR/timing"
    grep -Eq '^O [0-9]+\.[0-9]+ [0-9]+$' "$DIR/timing"
    read -r pid start boot tty < "$DIR/recorder"
    [[ $pid =~ ^[0-9]+$ && $start =~ ^[0-9]+$ && $tty =~ ^[0-9]+$ ]]
    [ "$boot" = "$(cat /proc/sys/kernel/random/boot_id)" ]
}

@test "the session folder is 0700, every file in it 0600, and timing has H COLUMNS, I and O lines" {
    drive << 'EOF'
pty_shell
pty_begin 'tlogger start'
start=$REPLY
pty_session
pty_run 'echo shown-in-the-recording'
pty_out_is shown-in-the-recording || pty_fail "echo printed $PTY_OUT"
pty_send exit
pty_end $start
(( PTY_STATUS == 0 )) || pty_fail "tlogger start returned $PTY_STATUS"
EOF
    one_session
    [ "$(stat -c %a "$DIR")" = 700 ]
    # output.raw, input.raw, timing, recorder, started and exited, each a plain 0600 file.
    [ "$(find "$DIR" -mindepth 1 | wc -l)" -eq 6 ]
    [ -z "$(find "$DIR" -mindepth 1 \( ! -type f -o ! -perm 600 \))" ]
    grep -Eq '^H [0-9]+\.[0-9]+ COLUMNS 80$' "$DIR/timing"
    grep -Eq '^H [0-9]+\.[0-9]+ LINES 24$' "$DIR/timing"
    grep -Eq '^I [0-9]+\.[0-9]+ [0-9]+$' "$DIR/timing"
    grep -Eq '^O [0-9]+\.[0-9]+ [0-9]+$' "$DIR/timing"
}

@test "output.raw starts in UTC while the recorded shell keeps the outer TZ" {
    drive << 'EOF'
pty_shell TZ=CET-1
pty_run 'date +%z'
pty_out_is '+0100' || pty_fail "the outer shell does not run in CET-1: $PTY_OUT"
pty_begin 'tlogger start'
start=$REPLY
pty_session
pty_run 'date +%z'
pty_out_is '+0100' || pty_fail "date in the recorded shell gives $PTY_OUT"
pty_run 'print -r -- "$TZ ${(t)TZ}"'
pty_out_is 'CET-1 scalar-export' || pty_fail "TZ in the recorded shell is $PTY_OUT"
pty_send exit
pty_end $start
EOF
    local first
    one_session
    IFS= read -r first < "$DIR/output.raw"
    [[ $first == 'Script started on '* ]]
    [[ $first == *'+00:00 '* ]]
    [[ $(cat "$DIR/started") =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "a secret typed at read -rs is in input.raw and not in output.raw" {
    drive << 'EOF'
pty_shell
pty_begin 'tlogger start'
start=$REPLY
pty_session
pty_begin 'read -rs "secret?pw$((6*7)): "'
frame=$REPLY
# The prompt comes once read runs; the pause leaves it time to have turned echo off.
pty_expect 'pw42: '
pty_pause 30
pty_send 'e2e-hidden-secret-4711'
pty_end $frame
(( PTY_STATUS == 0 )) || pty_fail "read returned $PTY_STATUS"
pty_run 'print -r -- ${#secret}'
pty_out_is 22 || pty_fail "read got $PTY_OUT characters, not 22"
pty_send exit
pty_end $start
EOF
    one_session
    grep -qF e2e-hidden-secret-4711 "$DIR/input.raw"
    run ! grep -qF e2e-hidden-secret-4711 "$DIR/output.raw"
    run ! grep -qF e2e-hidden-secret-4711 "$SCREEN"
    [ "$(grep -rlF e2e-hidden-secret-4711 "$DIR")" = "$DIR/input.raw" ]
}

@test "text typed into a subshell is in input.raw, and its echo and its output in output.raw" {
    # The line typed into sh; only its echo can put the first word into output.raw.
    # shellcheck disable=SC2016 # sh expands it, not bash.
    local typed=': e2e-typed-in-sh; echo e2e-shown-by-sh-$((6*7))'
    drive << 'EOF'
pty_shell
pty_begin 'tlogger start'
start=$REPLY
pty_session
pty_begin sh
sub=$REPLY
pty_run ': e2e-typed-in-sh; echo e2e-shown-by-sh-$((6*7))'
pty_out_is e2e-shown-by-sh-42 || pty_fail "sh printed $PTY_OUT"
pty_send exit
pty_end $sub
(( PTY_STATUS == 0 )) || pty_fail "sh returned $PTY_STATUS"
pty_send exit
pty_end $start
EOF
    one_session
    grep -qF "$typed" "$DIR/input.raw"
    grep -qF "$typed" "$DIR/output.raw"
    grep -qF e2e-shown-by-sh-42 "$DIR/output.raw"
}

@test "a nested zsh stays REC, refuses start and stop, and starts no second session" {
    drive << 'EOF'
pty_shell
pty_begin 'tlogger start'
start=$REPLY
pty_session
pty_begin zsh
nested=$REPLY
pty_run 'tlogger status'
pty_out_has "state: REC $PTY_ID" || pty_fail 'the nested zsh is not REC'
pty_run 'tlogger start'
(( PTY_STATUS == 1 )) || pty_fail "tlogger start in the nested zsh returned $PTY_STATUS"
pty_out_has "tlogger: NOT recording this terminal: already recorded, in session $PTY_ID" ||
    pty_fail 'tlogger start in the nested zsh did not refuse'
pty_run 'tlogger stop'
(( PTY_STATUS == 1 )) || pty_fail "tlogger stop in the nested zsh returned $PTY_STATUS"
pty_out_has "tlogger: this is a nested shell in session $PTY_ID; type exit to leave it, then run tlogger stop in the main shell" ||
    pty_fail 'tlogger stop in the nested zsh did not refuse'
pty_run '(tlogger stop)'
pty_out_has 'tlogger: tlogger stop does not work in a subshell' || pty_fail 'tlogger stop in a subshell did not refuse'
pty_send exit
pty_end $nested
sessions=($HOME/.local/state/tlogger/sessions/*(N))
(( $#sessions == 1 )) || pty_fail "there are $#sessions session folders, not 1"
[[ ! -e $sessions[1]/exited ]] || pty_fail 'the nested zsh wrote exited'
pty_run 'tlogger status'
pty_out_has "state: REC $PTY_ID" || pty_fail 'the main shell is not REC after the nested zsh'
pty_send exit
pty_end $start
(( PTY_STATUS == 0 )) || pty_fail "tlogger start returned $PTY_STATUS"
EOF
    one_session
}

@test "tlogger stop pauses, and tlogger start then records a new session" {
    drive << 'EOF'
pty_shell
pty_run 'tlogger stop'
(( PTY_STATUS == 1 )) || pty_fail "tlogger stop in a shell that is not recorded returned $PTY_STATUS"
pty_out_has 'tlogger: this terminal is NOT recorded; there is nothing to stop' || pty_fail 'tlogger stop did not refuse'
pty_begin 'tlogger start'
first=$REPLY
pty_session
first_id=$PTY_ID
pty_send 'tlogger stop'
pty_end $first
(( PTY_STATUS == 0 )) || pty_fail "tlogger start returned $PTY_STATUS after tlogger stop"
pty_out_has 'tlogger: recording paused; this terminal is NOT recorded; tlogger start resumes in a new session' ||
    pty_fail 'no notice that the recording paused'
pty_run 'tlogger status'
pty_out_has 'state: NOREC, this terminal is NOT recorded' || pty_fail 'the outer shell is not NOREC after the pause'
pty_out_has 'session: none' || pty_fail 'the outer shell names a session after the pause'
pty_begin 'tlogger start'
second=$REPLY
pty_session
[[ $PTY_ID != $first_id ]] || pty_fail 'the second tlogger start reused the first session'
pty_send 'tlogger stop'
pty_end $second
(( PTY_STATUS == 0 )) || pty_fail "the second tlogger start returned $PTY_STATUS"
EOF
    local name
    [ "$(session_names | wc -l)" -eq 2 ]
    while IFS= read -r name; do
        [ -f "$SESSIONS/$name/started" ]
        [ -f "$SESSIONS/$name/stop-requested" ]
        [ -f "$SESSIONS/$name/exited" ]
    done < <(session_names)
}

@test "after exec zsh the main shell stays the main shell, and tlogger stop pauses there" {
    drive << 'EOF'
pty_shell
pty_begin 'tlogger start'
start=$REPLY
pty_session
pty_send 'exec zsh'
pty_run 'tlogger status'
pty_out_has "state: REC $PTY_ID" || pty_fail 'the shell that exec started is not REC'
pty_run 'print -r -- ${_tlogger_main:t}'
pty_out_is $PTY_ID || pty_fail 'the shell that exec started is not the main shell'
pty_send 'tlogger stop'
pty_end $start
(( PTY_STATUS == 0 )) || pty_fail "tlogger start returned $PTY_STATUS"
pty_out_has 'tlogger: recording paused; this terminal is NOT recorded; tlogger start resumes in a new session' ||
    pty_fail 'no notice that the recording paused'
EOF
    one_session
    [ -f "$DIR/stop-requested" ]
    [ -f "$DIR/exited" ]
    # The shell that exec started joined without a handshake of its own.
    run ! grep -qF 'handshake failed' "$SCREEN"
}

@test "tlogger stop refuses while the recorded shell has a job" {
    drive << 'EOF'
pty_shell
pty_begin 'tlogger start'
start=$REPLY
pty_session
pty_run 'sleep 60 & true'
pty_run 'tlogger stop'
(( PTY_STATUS == 1 )) || pty_fail "tlogger stop with a job returned $PTY_STATUS"
pty_out_has 'tlogger: this shell has 1 job(s); end or disown them, then run tlogger stop again' ||
    pty_fail 'tlogger stop did not refuse the job'
pty_run 'kill %1; wait'
pty_send 'tlogger stop'
pty_end $start
(( PTY_STATUS == 0 )) || pty_fail "tlogger start returned $PTY_STATUS"
EOF
    one_session
    [ -f "$DIR/stop-requested" ]
}

@test "a missing recorder leaves a usable shell, a red notice and no session folder" {
    printf 'recorder=/nonexistent\n' >> "$CONFIG"
    assert_start_refused 'the recorder /nonexistent is missing or not executable'
}

@test "an unwritable log folder leaves a usable shell, a red notice and no session folder" {
    chmod 500 "$SESSIONS"
    assert_start_refused 'the log folder ~/.local/state/tlogger/sessions is not writable'
    chmod 700 "$SESSIONS"
}

@test "a log folder that others may write in leaves a usable shell, a red notice and no session folder" {
    # Without the sticky bit, another user could rename a session folder and leave a symlink.
    chmod 777 "$SESSIONS"
    assert_start_refused 'the log folder ~/.local/state/tlogger/sessions is writable by its group or by others'
    chmod 700 "$SESSIONS"
}

@test "a min_free_mb above the free space leaves a usable shell, a red notice and no session folder" {
    printf 'min_free_mb=999999999999\n' >> "$CONFIG"
    assert_start_refused 'less than 999999999999 MB free in ~/.local/state/tlogger/sessions'
}

@test "TLOGGER_DISABLE=1 and the disable file each leave a usable shell, a red notice and no session folder" {
    assert_start_refused 'TLOGGER_DISABLE is set' TLOGGER_DISABLE=1
    : > "$HOME/.config/tlogger/disable"
    assert_start_refused 'the kill switch ~/.config/tlogger/disable exists'
}

@test "a recorder that starts no shell gives a red notice and leaves no empty session folder" {
    # A stand-in for script that passes the check of tlogger start and records nothing.
    cat > "$HOME/no-shell-recorder" << 'SH'
#!/bin/sh
if [ "$1" = --help ]; then
    echo ' -T, --logging-format <format>  log format'
fi
exit 0
SH
    chmod 755 "$HOME/no-shell-recorder"
    printf 'recorder=%s\n' "$HOME/no-shell-recorder" >> "$CONFIG"
    drive << 'EOF'
pty_shell
pty_run 'tlogger start'
(( PTY_STATUS == 1 )) || pty_fail "tlogger start returned $PTY_STATUS, not 1"
[[ $PTY_OUT == *$'\e[31m''tlogger: recording failed to start'$'\e[0m\n' ]] ||
    pty_fail 'no red notice that the recording failed to start'
pty_run 'tlogger status'
pty_out_has 'state: NOREC, this terminal is NOT recorded' || pty_fail 'the shell does not work after the failure'
EOF
    [ -z "$(session_names)" ]
}

@test "a recorded shell that dies without exit leaves its session and a yellow notice" {
    drive << 'EOF'
pty_shell
pty_begin 'tlogger start'
start=$REPLY
pty_session
pty_send 'kill -KILL $$'
pty_end $start
(( PTY_STATUS == 1 )) || pty_fail "tlogger start returned $PTY_STATUS, not 1"
[[ $PTY_OUT == *$'\e[33m'"tlogger: recording ended unexpectedly; session $PTY_ID kept"$'\e[0m\n' ]] ||
    pty_fail 'no yellow notice that the recording ended unexpectedly'
pty_run 'tlogger status'
pty_out_has 'state: NOREC, this terminal is NOT recorded' || pty_fail 'the outer shell is not NOREC'
EOF
    one_session
    [ -f "$DIR/started" ]
    [ ! -e "$DIR/exited" ]
    [ ! -e "$DIR/stop-requested" ]
    grep -qF "tlogger: REC ${DIR##*/}" "$DIR/output.raw"
}

@test "a recorder that is killed leaves its session, a yellow notice and no exited marker" {
    drive << 'EOF'
pty_shell
pty_begin 'tlogger start'
start=$REPLY
pty_session
# The parent of the main recorded shell is the recorder; its death hangs up that shell's terminal.
pty_send 'kill -KILL $PPID'
pty_end $start
(( PTY_STATUS == 1 )) || pty_fail "tlogger start returned $PTY_STATUS, not 1"
[[ $PTY_OUT == *$'\e[33m'"tlogger: recording ended unexpectedly; session $PTY_ID kept"$'\e[0m'* ]] ||
    pty_fail 'no yellow notice that the recording ended unexpectedly'
pty_run 'tlogger status'
pty_out_has 'state: NOREC, this terminal is NOT recorded' || pty_fail 'the outer shell is not NOREC'
# Time for the hung-up shell to run its zshexit hook, which must write no exited.
pty_pause 50
EOF
    one_session
    [ -f "$DIR/started" ]
    [ ! -e "$DIR/exited" ]
    [ ! -e "$DIR/stop-requested" ]
    grep -qF "tlogger: REC ${DIR##*/}" "$DIR/output.raw"
}

@test "the banner and the notices name the session by its id and show no absolute path" {
    drive << 'EOF'
pty_shell
pty_begin 'tlogger start'
start=$REPLY
pty_session
[[ $PTY_BANNER == "tlogger: recording session $PTY_ID; everything typed and shown is saved, passwords included; tlogger stop pauses" ]] ||
    pty_fail "the banner is: $PTY_BANNER"
pty_run 'tlogger status'
pty_run 'tlogger start'
pty_send 'tlogger stop'
pty_end $start
pty_run 'tlogger status'
pty_out_has 'logdir: ~/.local/state/tlogger/sessions' || pty_fail 'tlogger status does not show the logdir with ~'
EOF
    grep -qF 'tlogger: recording paused' "$SCREEN"
    run ! grep -qF "$BATS_TEST_TMPDIR" "$SCREEN"
}

@test "record_input=no writes no input.raw, and the banner says that keystrokes are not saved" {
    printf 'record_input=no\n' >> "$CONFIG"
    drive << 'EOF'
pty_shell
pty_begin 'tlogger start'
start=$REPLY
pty_session
[[ $PTY_BANNER == "tlogger: recording session $PTY_ID; everything shown is saved, keystrokes are not; tlogger stop pauses" ]] ||
    pty_fail "the banner is: $PTY_BANNER"
pty_run 'tlogger status'
pty_out_has 'record_input: no' || pty_fail 'tlogger status does not show record_input no'
pty_send exit
pty_end $start
EOF
    one_session
    [ ! -e "$DIR/input.raw" ]
    grep -qF "tlogger: REC ${DIR##*/}" "$DIR/output.raw"
    grep -q '^O ' "$DIR/timing"
    run ! grep -q '^I ' "$DIR/timing"
}

@test "under the rc built from /etc/skel/.zshrc, with the line editor on, start says REC and stop pauses" {
    need file /etc/skel/.zshrc
    # The rc that install builds from Kali's own: the block, then /etc/skel/.zshrc as it is, with
    # its precmd, key bindings and line editor. Only whole notices are matched, so that the
    # redraws of the line editor do not matter.
    cat "$GOLDEN_BLOCK" /etc/skel/.zshrc > "$HOME/.zshrc"
    drive << 'EOF'
pty_shell
pty_begin 'tlogger start'
start=$REPLY
pty_session
pty_send 'tlogger stop'
pty_expect 'tlogger: recording paused; this terminal is NOT recorded; tlogger start resumes in a new session'
pty_end $start
(( PTY_STATUS == 0 )) || pty_fail "tlogger start returned $PTY_STATUS"
EOF
    one_session
    [ -f "$DIR/started" ]
    [ -f "$DIR/stop-requested" ]
    [ -f "$DIR/exited" ]
}
