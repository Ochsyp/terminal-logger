# Helpers for the drivers of tests/e2e-view-tty.bats, loaded by drive in tests/helpers.bash after
# tests/helpers/pty.zsh. They read ID, TLOGGER, TMPDIR and FILTER_RESTORE from the environment
# that the test file exports.

# The frame of the show that show_begin typed.
typeset -gi SHOW_FRAME=0

# Start the zsh under test in a 24x80 xterm, with ~/bin first on PATH and the NAME=VALUE arguments
# in its environment.
term_shell() {
    pty_shell TERM=xterm "PATH=$HOME/bin:$PATH" "TLOGGER=$TLOGGER" "TMPDIR=$TMPDIR" "$@"
}

# Fail unless the shell still runs a command.
shell_works() {
    pty_run 'print -r -- shell-ok-$((6*7))'
    pty_out_is shell-ok-42 || pty_fail "the shell printed ${(V)PTY_OUT}"
}

# Fail unless tty-replay saved the terminal settings SAVED.
tty_is() {
    [[ $(<$HOME/tty-after) == "$1" ]] ||
        pty_fail "the terminal settings are $(<$HOME/tty-after), not $1"
}

# Type a replay as a job of its own, on a line without frame markers: zsh would run the end
# marker of a frame as soon as the job is suspended.
start_replay() {
    pty_send "bash \"\$TLOGGER\" replay $ID"
}

# Type Ctrl+Z and wait for the restore sequence, then for zsh's job message.
press_ctrl_z() {
    pty_type $'\x1a'
    pty_expect "$FILTER_RESTORE"
    pty_expect suspended
}

# Type fg, then a marker <fg:STATUS> with the status that fg returns.
type_fg() {
    pty_send 'fg; echo "<fg:$?>"'
}

# Type tlogger show for the session ID in a frame, and set SHOW_FRAME to it for show_quit.
show_begin() {
    pty_begin "bash \"\$TLOGGER\" show $ID"
    SHOW_FRAME=$REPLY
}

# Quit the pager with q, and fail unless show returned 0.
show_quit() {
    pty_type q
    pty_end $SHOW_FRAME
    (( PTY_STATUS == 0 )) || pty_fail "show returned $PTY_STATUS"
}
