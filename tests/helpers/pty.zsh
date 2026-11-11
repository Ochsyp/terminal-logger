# Drives an interactive shell in a pseudo-terminal through zsh's own zsh/zpty module, for
# tests/e2e-manual.bats and tests/e2e-auto.bats: types lines and keys, waits for output or for the
# end of a process against a hard deadline, and frames commands with markers that give their output
# and exit status. A wait that fails ends the driver with a report of the output; no tmux involved.

if ! zmodload zsh/zpty zsh/zselect zsh/datetime 2> /dev/null; then
    print -ru2 -- 'pty: this zsh lacks the zsh/zpty, zsh/zselect or zsh/datetime module'
    exit 97
fi
setopt extendedglob

# The zpty command name. PTY_BUF holds the output no wait has consumed yet, PTY_LOG all output
# read so far, PTY_BEFORE what the last pty_expect skipped before its text. PTY_OUT and PTY_STATUS
# are the output and exit status of the last frame; PTY_ID and PTY_BANNER come from pty_session.
# PTY_PID is the pid of the shell in the terminal, whose end cuts every wait short; pty_shell and
# pty_auto_shell set it, and pty_auto_shell also sets PTY_OUTER, PTY_RECORDER and PTY_INNER.
# PTY_SEQ counts the frames, and _pty_mark keeps the length of PTY_LOG when each frame began.
typeset -g PTY_NAME=e2e PTY_BUF= PTY_LOG= PTY_BEFORE= PTY_OUT= PTY_ID= PTY_BANNER=
typeset -gi PTY_STATUS=0 PTY_SEQ=0 PTY_PID=0 PTY_OUTER=0 PTY_RECORDER=0 PTY_INNER=0
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
# TERM=dumb and the NAME=VALUE arguments in its environment, and type nothing. Forgets the unread
# output of an earlier terminal, and PTY_PID until a starter sets it again.
pty_open() {
    local -a assignments
    assignments=(HOME=$HOME PATH=$PATH TERM=dumb "$@")
    PTY_BUF= PTY_PID=0
    # In double quotes, (@) keeps the words apart, so that (q) quotes each one before they are
    # joined; without it the words would be joined first and env would get one argument.
    if ! zpty -e $PTY_NAME "stty rows 24 cols 80 2> /dev/null; exec env -i ${(j: :)${(@q)assignments}} zsh -i"; then
        pty_fail 'zpty cannot start the shell'
    fi
}

# Start the zsh under test as pty_open does, wait until it runs commands and set PTY_PID to its
# pid. The first line is typed at once and runs once the rc has loaded; in a terminal that records
# itself, it runs in the recorded shell, since script passes on what was typed before it started.
pty_shell() {
    pty_open "$@"
    pty_run 'print -r -- $$'
    if (( PTY_STATUS != 0 )) || [[ $PTY_OUT != <->$'\n' ]]; then
        pty_fail 'the shell does not run commands'
    fi
    PTY_PID=${PTY_OUT%$'\n'}
}

# Start the zsh under test as pty_open does, in a terminal that records itself while the rc loads,
# and type nothing until the banner and the REC line have come, which pty_session reads. Then set
# PTY_INNER to the pid of the recorded shell, PTY_RECORDER to that of its parent, which must be
# script, and PTY_OUTER and PTY_PID to that of script's parent, the shell that zpty started.
pty_auto_shell() {
    local -a ids
    pty_open "$@"
    pty_session
    pty_run 'print -r -- "$$ $PPID"'
    ids=(${=PTY_OUT})
    if (( PTY_STATUS != 0 || $#ids != 2 )) || [[ $ids[1] != <-> || $ids[2] != <-> ]]; then
        pty_fail "the recorded shell does not run commands: ${(V)PTY_OUT}"
    fi
    PTY_INNER=$ids[1] PTY_RECORDER=$ids[2]
    pty_parent $PTY_RECORDER
    if [[ $reply[1] != script ]]; then
        pty_fail "the parent of the recorded shell is ${(V)reply[1]}, not script"
    fi
    PTY_OUTER=$REPLY PTY_PID=$REPLY
}

# End the terminal: read what it printed last, then let zpty -d hang up whatever still runs in it,
# so that pty_open can start the next terminal under the same name.
pty_close() {
    _pty_read
    zpty -d $PTY_NAME 2> /dev/null
    PTY_BUF= PTY_PID=0
    return 0
}

# Type LINE and Enter into the terminal.
pty_send() {
    zpty -w $PTY_NAME "$1" || pty_fail "cannot type into the terminal: $1"
}

# Type TEXT into the terminal without Enter, such as $'\x04' for Ctrl+D.
pty_type() {
    zpty -wn $PTY_NAME "$1" || pty_fail "cannot type into the terminal: ${(V)1}"
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

# Wait for the banner of a recording and the REC line of the recorded shell; set PTY_BANNER to
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

# Set REPLY to the parent pid and reply to the comm of process PID, from /proc/PID/stat read
# without a fork: the comm lies between the first ( and the last ), and the ppid is the second
# field after it. Ends the driver when the file cannot be read.
pty_parent() {
    local line
    local -a f
    if ! { line=$(</proc/$1/stat); } 2> /dev/null || [[ $line != *'('*')'* ]]; then
        pty_fail "cannot read /proc/$1/stat"
    fi
    f=(${(s: :)${line##*\)}})
    reply=("${${line#*\(}%\)*}")
    REPLY=$f[2]
}

# Wait at most SECONDS until process PID has ended and the driver has reaped it, as the shell that
# zpty started does once a recording closes its terminal. kill -0 still finds a process that has
# ended until then; zsh reaps every child as SIGCHLD comes.
pty_wait_gone() {
    local pid=$1
    _pty_until '! kill -0 $pid 2> /dev/null' "the end of process $pid" $2
}

# Let CENTISECONDS (default 20) pass. zselect returns 1 when its time runs out, which is the point
# here, so the pause returns 0: a driver that ends with a pause must not fail for it.
pty_pause() {
    zselect -t ${1:-20}
    return 0
}
