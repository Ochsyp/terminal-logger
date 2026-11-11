#!/usr/bin/env bats
# End-to-end tests of auto mode: tlogger, installed from the work tree with --mode auto on the auto
# fixture rc, records each new zsh terminal as its rc loads, in a pseudo-terminal that zsh's zpty
# module drives (tests/helpers/pty.zsh), without tmux. They need Linux, zsh with zpty, script 2.35
# or newer, symlinks, POSIX modes and a non-root user.

bats_require_minimum_version 1.5.0

load helpers

# Run before each test by bats.
# Gives the test its own HOME, with tlogger installed in auto mode on top of the auto fixture rc;
# the real script passes the smoke test, and the probe of install records nothing.
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
    cp "$REPO_ROOT/tests/fixtures/e2e-auto-zshrc" "$HOME/.zshrc"
    run_tlogger install --mode auto --yes
    [ "$status" -eq 0 ]
    [[ $stderr == *"plugin loaded"* ]]
    [ -z "$(session_names)" ]
}

# Run the zsh code on stdin as the driver: zsh -f with tests/helpers/pty.zsh loaded, under a hard
# timeout, with fd 3 closed so that nothing it starts can hold bats up. A driver that gives up
# fails the test with a report on stderr. SCREEN receives everything the terminals printed.
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

# Open a terminal with the NAME=VALUE arguments in its environment, which must keep it from
# recording itself without a word: the rest of its rc loads, tlogger status says NOREC, the
# terminal shows no 'tlogger: ' line and no session folder appears.
assert_auto_silent() {
    E2E_ENV="$*" drive << 'EOF'
pty_shell ${=E2E_ENV}
pty_run 'print -r -- ${E2E_RC_DONE-unset}'
pty_out_is 1 || pty_fail "the rest of the rc did not run: $PTY_OUT"
pty_run 'tlogger status'
pty_out_has 'state: NOREC, this terminal is NOT recorded' || pty_fail 'the shell is not NOREC'
EOF
    [ -z "$(session_names)" ]
    run ! grep -qF 'tlogger: ' "$SCREEN"
}

# Open a terminal with the NAME=VALUE arguments in its environment, where a check must refuse to
# record it with REASON: the red notice, then the rest of the rc, a shell that works and is NOREC,
# and no session folder.
assert_auto_refused() {
    local reason=$1
    shift
    E2E_REASON=$reason E2E_ENV="$*" drive << 'EOF'
pty_shell ${=E2E_ENV}
[[ $PTY_LOG == *$'\e[31m'"tlogger: NOT recording this terminal: $E2E_REASON"$'\e[0m'* ]] ||
    pty_fail "no red notice that says: $E2E_REASON"
pty_run 'print -r -- ${E2E_RC_DONE-unset}'
pty_out_is 1 || pty_fail "the rest of the rc did not run after the refusal: $PTY_OUT"
pty_run 'tlogger status'
pty_out_has 'state: NOREC, this terminal is NOT recorded' || pty_fail 'the shell does not work after the refusal'
EOF
    [ -z "$(session_names)" ]
}

@test "a new terminal records itself, loads the rest of its rc in the recorded shell, and exit closes it" {
    drive << 'EOF'
pty_auto_shell
[[ $PTY_BANNER == "tlogger: recording session $PTY_ID; everything typed and shown is saved, passwords included; tlogger stop pauses" ]] ||
    pty_fail "the banner is: $PTY_BANNER"
pty_run 'print -r -- ${E2E_RC_DONE-unset}'
pty_out_is 1 || pty_fail "the recorded shell did not load the rest of the rc: $PTY_OUT"
pty_run 'tlogger status'
pty_out_has "state: REC $PTY_ID" || pty_fail 'tlogger status in the recorded shell does not say REC'
pty_out_has 'mode: auto' || pty_fail 'tlogger status in the recorded shell does not say mode auto'
pty_run 'echo e2e-typed-in-auto-$((6*7))'
pty_out_is e2e-typed-in-auto-42 || pty_fail "echo printed $PTY_OUT"
# A nested zsh finds the terminal recorded and starts no recording of its own.
pty_begin zsh
nested=$REPLY
pty_run 'tlogger status'
pty_out_has "state: REC $PTY_ID" || pty_fail 'the nested zsh is not REC'
pty_send exit
pty_end $nested
[[ $PTY_OUT != *'tlogger: recording session'* ]] || pty_fail 'the nested zsh started a recording'
pty_send exit
pty_wait_gone $PTY_OUTER
EOF
    one_session
    [ -f "$DIR/started" ]
    [ -f "$DIR/exited" ]
    [ ! -e "$DIR/stop-requested" ]
    grep -qF "tlogger: REC ${DIR##*/}" "$DIR/output.raw"
    # The line as typed; only input.raw holds it in this form.
    # shellcheck disable=SC2016
    grep -qF 'echo e2e-typed-in-auto-$((6*7))' "$DIR/input.raw"
    # The shell that recorded closes without a notice.
    run ! grep -qF 'tlogger: recording ended' "$SCREEN"
    run ! grep -qF 'handshake failed' "$SCREEN"
}

@test "Ctrl+D at the prompt of the recorded shell closes the terminal as exit does" {
    drive << 'EOF'
pty_auto_shell
pty_run 'print -r -- ${E2E_RC_DONE-unset}'
pty_out_is 1 || pty_fail "the recorded shell did not load the rest of the rc: $PTY_OUT"
# Ctrl+D on an empty line is the end of input for the recorded shell, which then exits.
pty_type $'\x04'
pty_wait_gone $PTY_OUTER
EOF
    one_session
    [ -f "$DIR/started" ]
    [ -f "$DIR/exited" ]
    [ ! -e "$DIR/stop-requested" ]
}

@test "tlogger stop keeps the terminal, whose shell loads the rest of its rc, and tlogger start records again" {
    drive << 'EOF'
pty_auto_shell
first_id=$PTY_ID
pty_send 'tlogger stop'
pty_expect 'tlogger: recording paused; this terminal is NOT recorded; tlogger start resumes in a new session'
pty_run 'print -r -- "${E2E_RC_DONE-unset} $$"'
pty_out_is "1 $PTY_OUTER" || pty_fail "the outer shell is gone or did not load the rest of its rc: $PTY_OUT"
pty_run 'tlogger status'
pty_out_has 'state: NOREC, this terminal is NOT recorded' || pty_fail 'the outer shell is not NOREC after the pause'
pty_out_has 'session: none' || pty_fail 'the outer shell names a session after the pause'
pty_out_has 'mode: auto' || pty_fail 'tlogger status does not say mode auto'
pty_begin 'tlogger start'
start=$REPLY
pty_session
[[ $PTY_ID != $first_id ]] || pty_fail 'tlogger start reused the paused session'
pty_send exit
pty_end $start
(( PTY_STATUS == 0 )) || pty_fail "tlogger start returned $PTY_STATUS after exit"
pty_out_has 'tlogger: recording ended; this terminal is NOT recorded' || pty_fail 'no notice that the recording ended'
pty_run 'print -r -- $$'
pty_out_is $PTY_OUTER || pty_fail "exit after tlogger start left the outer shell: $PTY_OUT"
EOF
    local name
    local -i paused=0
    [ "$(session_names | wc -l)" -eq 2 ]
    while IFS= read -r name; do
        [ -f "$SESSIONS/$name/started" ]
        [ -f "$SESSIONS/$name/exited" ]
        if [[ -e $SESSIONS/$name/stop-requested ]]; then
            paused+=1
        fi
    done < <(session_names)
    [ "$paused" -eq 1 ]
}

@test "zsh -i -c, as an IDE runs it to read the environment, records nothing and prints no tlogger line" {
    # --foreground keeps zsh in the process group of bats: where bats runs in a terminal, an
    # interactive zsh in a background group would stop as it takes that terminal over.
    run --separate-stderr timeout --foreground 10 zsh -i -c true < /dev/null
    [ "$status" -eq 0 ]
    [[ $output != *tlogger* ]]
    [[ $stderr != *tlogger* ]]
    [ -z "$(session_names)" ]
}

@test "zsh -i -c with a terminal on stdin and stdout records nothing either, by ZSH_EXECUTION_STRING alone" {
    # TLOGGER_MODE=manual keeps the outer shell silent. The inner zsh gets auto back and has the
    # terminal on stdin and stdout, so that only the check of ZSH_EXECUTION_STRING stops it.
    drive << 'EOF'
pty_shell TLOGGER_MODE=manual
pty_run 'TLOGGER_MODE=auto zsh -i -c "print -r -- probe-ok"'
(( PTY_STATUS == 0 )) || pty_fail "zsh -i -c exited with $PTY_STATUS"
pty_out_is probe-ok || pty_fail "zsh -i -c printed: $PTY_OUT"
EOF
    [ -z "$(session_names)" ]
    run ! grep -qF 'tlogger: ' "$SCREEN"
}

@test "VSCODE_RESOLVING_ENVIRONMENT, TLOGGER_MODE=manual and ASCIINEMA_REC each leave a terminal silent and unrecorded" {
    assert_auto_silent VSCODE_RESOLVING_ENVIRONMENT=1
    assert_auto_silent TLOGGER_MODE=manual
    assert_auto_silent ASCIINEMA_REC=1
}

@test "TLOGGER_DISABLE=1 and the disable file each give the red notice, a usable shell and no session folder" {
    assert_auto_refused 'TLOGGER_DISABLE is set' TLOGGER_DISABLE=1
    : > "$HOME/.config/tlogger/disable"
    assert_auto_refused 'the kill switch ~/.config/tlogger/disable exists'
}

@test "a missing recorder gives the red notice, a usable shell and no session folder" {
    printf 'recorder=/nonexistent\n' >> "$CONFIG"
    assert_auto_refused 'the recorder /nonexistent is missing or not executable'
}

@test "an unwritable log folder gives the red notice, a usable shell and no session folder" {
    chmod 500 "$SESSIONS"
    assert_auto_refused 'the log folder ~/.local/state/tlogger/sessions is not writable'
    chmod 700 "$SESSIONS"
}

@test "a new terminal with an earlier session's TLOGGER_SESSION and TMUX records itself, unless record_tmux is no" {
    drive << 'EOF'
# A tmux pane started from a recorded terminal is a terminal of its own, whose shell has TMUX set
# and the TLOGGER_SESSION that the recorded shell exports.
pty_auto_shell
first_id=$PTY_ID
pty_run 'print -r -- "${(t)TLOGGER_SESSION} $TLOGGER_SESSION"'
[[ $PTY_OUT == "scalar-export /"*"/$first_id"$'\n' ]] || pty_fail "the recorded shell exports no TLOGGER_SESSION: $PTY_OUT"
first_dir=${${PTY_OUT#* }%$'\n'}
pty_send exit
pty_wait_gone $PTY_OUTER
pty_close
pty_auto_shell TLOGGER_SESSION=$first_dir TMUX=/tmp/tmux-1000/default,4242,0
[[ $PTY_ID != $first_id ]] || pty_fail 'the pane joined the earlier session'
pty_run 'print -r -- "${TMUX-unset} ${TLOGGER_SESSION:t}"'
pty_out_is "/tmp/tmux-1000/default,4242,0 $PTY_ID" || pty_fail "the recorded pane has: $PTY_OUT"
pty_send exit
pty_wait_gone $PTY_OUTER
pty_close
mark=$#PTY_LOG
pty_shell TLOGGER_SESSION=$first_dir TMUX=/tmp/tmux-1000/default,4242,0 TLOGGER_RECORD_TMUX=no
pty_run 'tlogger status'
pty_out_has 'state: NOREC, this terminal is NOT recorded' || pty_fail 'the pane with TLOGGER_RECORD_TMUX=no is not NOREC'
pty_out_has 'session: none' || pty_fail 'the pane with TLOGGER_RECORD_TMUX=no names a session'
[[ ${PTY_LOG[mark+1,-1]} != *'tlogger: '* ]] || pty_fail 'the pane with TLOGGER_RECORD_TMUX=no printed a tlogger line'
EOF
    local name
    [ "$(session_names | wc -l)" -eq 2 ]
    while IFS= read -r name; do
        [ -f "$SESSIONS/$name/started" ]
        [ -f "$SESSIONS/$name/exited" ]
    done < <(session_names)
}

@test "an SSH login records itself, but not with TLOGGER_RECORD_SSH=no" {
    drive << 'EOF'
pty_shell 'SSH_CONNECTION=192.0.2.10 50000 192.0.2.20 22' TLOGGER_RECORD_SSH=no
pty_run 'tlogger status'
pty_out_has 'state: NOREC, this terminal is NOT recorded' || pty_fail 'the SSH login with TLOGGER_RECORD_SSH=no is not NOREC'
[[ $PTY_LOG != *'tlogger: '* ]] || pty_fail 'the SSH login with TLOGGER_RECORD_SSH=no printed a tlogger line'
pty_close
pty_auto_shell 'SSH_CONNECTION=192.0.2.10 50000 192.0.2.20 22'
pty_run 'print -r -- $SSH_CONNECTION'
pty_out_is '192.0.2.10 50000 192.0.2.20 22' || pty_fail "the recorded shell has SSH_CONNECTION $PTY_OUT"
pty_send exit
pty_wait_gone $PTY_OUTER
EOF
    one_session
    [ -f "$DIR/started" ]
    [ -f "$DIR/exited" ]
}

@test "a recorder under another name fails the handshake, records no second time inside, and keeps the terminal" {
    # zsh sees a process by the name it was started under, so the shell that this script starts
    # cannot tell it as script. It must not start a recording of its own, or recorders would nest.
    ln -s /usr/bin/script "$HOME/recorder"
    printf 'recorder=%s\n' "$HOME/recorder" >> "$CONFIG"
    drive << 'EOF'
pty_open
pty_expect 'tlogger: recording session '
pty_expect $'\r\n'
id=${PTY_BEFORE%%;*}
pty_expect 'tlogger: warning: the recording handshake failed: the parent process is not script'
pty_run 'tlogger status'
pty_out_has 'state: NOREC, this terminal is NOT recorded' || pty_fail 'the shell under the renamed recorder is not NOREC'
sessions=($HOME/.local/state/tlogger/sessions/*(N))
(( $#sessions == 1 )) || pty_fail "there are $#sessions session folders, not 1"
pty_send exit
pty_expect $'\e[31m'"tlogger: recording failed to start; session $id kept"$'\e[0m'
pty_run 'print -r -- ${E2E_RC_DONE-unset}'
pty_out_is 1 || pty_fail "the outer shell did not load the rest of its rc after the failure: $PTY_OUT"
EOF
    one_session
    [ ! -e "$DIR/started" ]
    [ ! -e "$DIR/recorder" ]
}
