# Drives an interactive shell in a pseudo-terminal through zsh's own zsh/zpty module, for
# tests/e2e-manual.bats: types lines, waits for output against a hard deadline and frames commands
# with markers that give their output and exit status. A wait that times out or sees the shell end
# ends the driver with a report of the terminal output. Sourced by the driver; no tmux involved.

if ! zmodload zsh/zpty zsh/zselect zsh/datetime 2> /dev/null; then
    print -ru2 -- 'pty: this zsh lacks the zsh/zpty, zsh/zselect or zsh/datetime module'
    exit 97
fi
setopt extendedglob

# The zpty command name. PTY_BUF holds the output no wait has consumed yet, PTY_LOG all output
# read so far, PTY_BEFORE what the last pty_expect skipped before its text. PTY_OUT and PTY_STATUS
# are the output and exit status of the last frame; PTY_ID and PTY_BANNER come from pty_session,
# PTY_PID, the pid of the shell in the terminal, from pty_shell. PTY_SEQ counts the frames, and
# _pty_mark keeps the length of PTY_LOG when each frame began.
typeset -g PTY_NAME=e2e PTY_BUF= PTY_LOG= PTY_BEFORE= PTY_OUT= PTY_ID= PTY_BANNER=
typeset -gi PTY_STATUS=0 PTY_SEQ=0 PTY_PID=0
typeset -ga _pty_mark
# The longest a wait lasts, in seconds.
typeset -gi PTY_WAIT=20

# Print MESSAGE and the last part of the terminal output, control characters shown as ^X, on
# stderr, and end the driver with status 1. Never returns.
pty_fail() {
    print -ru2 -- "pty: $1"
    print -ru2 -- 'pty: the end of what the terminal printed, control characters shown as ^X:'
    print -ru2 -- "${(V)PTY_LOG[-2500,-1]}"
    exit 1
}

# Append the output the terminal has ready to PTY_BUF, PTY_LOG and the file PTY_SCREEN_FILE when
# that is set, without blocking: zpty -rt polls before each read. Returns once nothing more is
# ready. zpty -r cannot tell that the shell has ended: only zpty -t notices that, through a read
# that blocks on this pty, so _pty_until asks kill -0 instead.
_pty_read() {
    local chunk
    while true; do
        chunk=
        if ! zpty -rt $PTY_NAME chunk 2> /dev/null; then
            return 0
        fi
        PTY_BUF+=$chunk
        PTY_LOG+=$chunk
        if [[ -n ${PTY_SCREEN_FILE-} ]]; then
            print -rn -- "$chunk" >> $PTY_SCREEN_FILE
        fi
    done
}

# Read the terminal until the condition CODE, run with eval, holds, at most SECONDS (default
# PTY_WAIT); end the driver with a report naming WHAT when it does not, at once when the shell in
# the terminal has ended. CODE sees the caller's local parameters and must not use the positional
# ones.
_pty_until() {
    local -F _pty_deadline=$(( EPOCHREALTIME + ${3:-$PTY_WAIT} ))
    while true; do
        _pty_read
        if eval "$1"; then
            return 0
        fi
        # The driver reaps the shell when it ends, and kill -0 fails from then on. What it printed
        # last is still read once more.
        if (( PTY_PID )) && ! kill -0 $PTY_PID 2> /dev/null; then
            _pty_read
            if eval "$1"; then
                return 0
            fi
            pty_fail "the shell in the terminal ended before it printed $2"
        fi
        if (( EPOCHREALTIME >= _pty_deadline )); then
            pty_fail "no $2 within ${3:-$PTY_WAIT} seconds"
        fi
        # 50 ms; zselect without a file descriptor only waits.
        zselect -t 5
    done
}

# Start the interactive zsh under test in a new 24x80 terminal with echo on, with only HOME, PATH,
# TERM=dumb and the NAME=VALUE arguments in its environment, wait until it runs commands and set
# PTY_PID to its pid.
pty_shell() {
    local -a assignments
    assignments=(HOME=$HOME PATH=$PATH TERM=dumb "$@")
    # In double quotes, (@) keeps the words apart, so that (q) quotes each one before they are
    # joined; without it the words would be joined first and env would get one argument.
    if ! zpty -e $PTY_NAME "stty rows 24 cols 80 2> /dev/null; exec env -i ${(j: :)${(@q)assignments}} zsh -i"; then
        pty_fail 'zpty cannot start the shell'
    fi
    pty_run 'print -r -- $$'
    if (( PTY_STATUS != 0 )) || [[ $PTY_OUT != <->$'\n' ]]; then
        pty_fail 'the shell does not run commands'
    fi
    PTY_PID=${PTY_OUT%$'\n'}
}

# Type LINE and Enter into the terminal.
pty_send() {
    zpty -w $PTY_NAME "$1" || pty_fail "cannot type into the terminal: $1"
}

# Wait until the terminal prints TEXT, at most SECONDS; consume the output up to the end of TEXT
# and set PTY_BEFORE to the part before it.
pty_expect() {
    local text=$1
    _pty_until '[[ $PTY_BUF == *"$text"* ]]' "output '${(V)text}'" $2
    PTY_BEFORE=${PTY_BUF%%"$text"*}
    PTY_BUF=${PTY_BUF#*"$text"}
}

# Type COMMAND between two marker commands, which print <b:N> and <e:STATUS:N> for frame N, and set
# REPLY to N. The typed form of a marker, $((N+0)), never matches its output; the markers work in
# zsh and in sh.
pty_begin() {
    (( ++PTY_SEQ ))
    _pty_mark[PTY_SEQ]=$#PTY_LOG
    REPLY=$PTY_SEQ
    pty_send "echo \"<b:\$(($PTY_SEQ+0))>\"; $1; echo \"<e:\$?:\$(($PTY_SEQ+0))>\""
}

# Wait at most SECONDS for the end marker of frame N, then set PTY_STATUS to the exit status of its
# command and PTY_OUT to everything printed between the two markers, carriage returns removed.
pty_end() {
    local n=$1 seg
    _pty_until '[[ $PTY_BUF == (#b)*"<e:"(<->)":$n>"* ]]' "end marker of frame $n" $2
    PTY_STATUS=$match[1]
    PTY_BUF=${PTY_BUF#*"<e:$match[1]:$n>"}
    seg=${PTY_LOG[_pty_mark[n]+1,-1]}
    seg=${seg#*"<b:$n>"}
    seg=${seg%%"<e:$PTY_STATUS:$n>"*}
    seg=${seg//$'\r'}
    PTY_OUT=${seg#$'\n'}
}

# Run COMMAND in a frame and wait at most SECONDS for it to end; sets PTY_OUT and PTY_STATUS.
pty_run() {
    pty_begin "$1"
    pty_end $REPLY $2
}

# Succeed when PTY_OUT holds TEXT, every run of spaces in either counting as one space.
pty_out_has() {
    [[ ${PTY_OUT// ##/ } == *"${1// ##/ }"* ]]
}

# Succeed when PTY_OUT is TEXT followed by one line end.
pty_out_is() {
    [[ $PTY_OUT == "$1"$'\n' ]]
}

# Wait for the banner of tlogger start and the REC line of the recorded shell; set PTY_BANNER to
# the banner line and PTY_ID to the session id it names.
pty_session() {
    pty_expect 'tlogger: recording session '
    pty_expect $'\r\n'
    PTY_BANNER="tlogger: recording session $PTY_BEFORE"
    PTY_ID=${PTY_BEFORE%%;*}
    if [[ $PTY_ID != [0-9](#c8)T[0-9](#c6)Z-[A-Za-z0-9](#c6) ]]; then
        pty_fail "the banner names no session id: ${(V)PTY_BANNER}"
    fi
    pty_expect "tlogger: REC $PTY_ID"$'\r\n'
}

# Let CENTISECONDS (default 20) pass.
pty_pause() {
    zselect -t ${1:-20}
}
