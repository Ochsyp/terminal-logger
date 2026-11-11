# tlogger plugin for zsh, sourced by the tlogger block at the top of the zsh rc. tlogger start
# records this terminal with util-linux script, tlogger stop pauses, tlogger status shows the
# state, and in auto mode each new terminal records itself; other subcommands go to the release's
# bin/tlogger. It changes no zsh option outside its functions and never touches PROMPT.

# Only an interactive shell gets the command.
[[ -o interactive ]] || return 0

# A root shell whose HOME is not root's own, as 'sudo -s' can leave it, reads another user's rc.
# It defines nothing, so that root never runs that user's tlogger. userdirs maps a user name to
# the home in the passwd database without a fork.
if (( EUID == 0 )) && [[ ${HOME%/} != "${${userdirs[root]:-/root}%/}" ]]; then
    return 0
fi

# The release folder: the folder above the lib/ that holds this file, with the current symlink
# resolved, so that this shell keeps using the release it loaded.
typeset -g _tlogger_release=${${(%):-%x}:A:h:h}

# A session folder is <logdir>/<UTC time>-<6 random characters>, mode 0700. script writes
# output.raw, input.raw (unless record_input=no) and timing into it, mode 0600. The recorded
# shells add markers, mode 0600 each: recorder ('<script pid> <starttime> <boot_id> <tty_nr>')
# and started from the handshake, exited from an exit of the main recorded shell while its
# recorder and terminal last, and stop-requested from tlogger stop. A marker always holds a line.
# TLOGGER_SESSION names the folder in every recorded shell. TLOGGER_PROC, default /proc, exists
# only so that the tests can point the process walk at a fake tree; production never sets it.

# Print 'tlogger: MESSAGE' on stderr, in COLOR (red or yellow; plain for none) when stderr is a
# terminal and NO_COLOR is empty. The colour wraps the whole line, so the text stays one piece.
_tlogger_say() {
    emulate -L zsh
    local on= off=
    if [[ -t 2 && -z ${NO_COLOR-} ]]; then
        case $1 in
            red) on=$'\e[31m' off=$'\e[0m' ;;
            yellow) on=$'\e[33m' off=$'\e[0m' ;;
        esac
    fi
    print -ru2 -- "${on}tlogger: $2$off"
}

# Set REPLY to PATH with a leading $HOME replaced by ~, the form every message uses, as
# bin/tlogger's shown does. HOME counts without its trailing slashes; a HOME of / replaces nothing.
_tlogger_shown() {
    emulate -L zsh
    setopt extendedglob
    local home=${${HOME-}%%/##}
    REPLY=$1
    if [[ -n $home && ( $1 == "$home" || $1 == "$home"/* ) ]]; then
        REPLY="~${1#"$home"}"
    fi
}

# Set the parameter named NAME to the time now in UTC, as strftime FORMAT writes it.
# NAME must not be TZ, which is local here; zsh/datetime must be loaded.
_tlogger_utc() {
    emulate -L zsh
    local -x TZ=UTC0
    strftime -s $1 $2 $EPOCHSECONDS
}

# Create FILE with mode 0600 and the line TEXT, without a fork. Returns 1 when FILE exists, even
# as a symlink, which is never followed, or cannot be written; a FILE it created but could not
# write is removed again, so that no empty marker is left to count. zsh/system must be loaded.
_tlogger_write_new() {
    emulate -L zsh
    local fd
    local -i rc
    if ! sysopen -w -o creat,excl,nofollow,cloexec -m 600 -u fd $1 2> /dev/null; then
        return 1
    fi
    {
        print -r -u $fd -- $2 2> /dev/null
        rc=$?
    } always {
        exec {fd}>&-
    }
    if (( rc )); then
        # Only a full disk or an I/O error gets here, so the fork of rm does not matter.
        command rm -f -- $1 2> /dev/null
        return 1
    fi
}

# Set reply to the comm, ppid, tty_nr and starttime of process PID from <proc>/PID/stat, read
# without a fork. The comm lies between the first '(' and the last ')', since it may hold either;
# the numbers follow the last ')', starttime as field 22. Returns 1 when the file cannot be read
# or a field is not a number, so that no other text reaches an arithmetic context.
_tlogger_stat() {
    emulate -L zsh
    local line comm rest
    local -a f
    reply=()
    if [[ $1 != <-> ]] || ! { line=$(<${TLOGGER_PROC:-/proc}/$1/stat); } 2> /dev/null; then
        return 1
    fi
    if [[ $line != *'('*')'* ]]; then
        return 1
    fi
    comm=${line#*\(}
    comm=${comm%\)*}
    rest=${line##*\)}
    f=(${(s: :)rest})
    if [[ $f[2] != <-> || $f[5] != <-> || $f[20] != <-> ]]; then
        return 1
    fi
    reply=("$comm" $f[2] $f[5] $f[20])
}

# Set _tlogger_state to this terminal's state, walking the process tree from $$ up without a
# fork. REC: an ancestor is the recorder that $TLOGGER_SESSION/recorder names (pid, starttime,
# boot_id and tty_nr match) and its child on the chain has this shell's tty_nr. EXT: another
# ancestor named script has its child on this tty. NOREC otherwise, and for a shell without a
# controlling terminal. Sets _tlogger_main to the session folder when this shell is the
# recorder's own child, the main recorded shell, else empty. Unless REC, unsets TLOGGER_SESSION
# and TLOGGER_HS*.
_tlogger_tty_state() {
    emulate -L zsh
    local proc=${TLOGGER_PROC:-/proc} dir=${TLOGGER_SESSION-} boot= my_tty child_tty pid
    local -a reply rec
    local -i depth=0
    typeset -g _tlogger_state=NOREC _tlogger_main=
    if [[ $dir == /* && -d $dir && ! -L $dir && -O $dir && -f $dir/recorder &&
        ! -L $dir/recorder && -O $dir/recorder ]]; then
        { rec=(${(s: :)"$(<$dir/recorder)"}); } 2> /dev/null
        { boot=$(<$proc/sys/kernel/random/boot_id); } 2> /dev/null
        if [[ $#rec != 4 || $rec[1] != <-> || $rec[2] != <-> || $rec[4] != <-> || -z $boot ||
            $rec[3] != "$boot" ]]; then
            rec=()
        fi
    fi
    if _tlogger_stat $$ && [[ $reply[3] != 0 ]]; then
        my_tty=$reply[3] child_tty=$reply[3] pid=$reply[2]
        # pid holds digits only: _tlogger_stat checked every field it returns.
        while (( depth++ < 128 && pid > 0 )) && _tlogger_stat $pid; do
            if [[ $child_tty == "$my_tty" ]]; then
                if [[ $pid == "${rec[1]-}" && $reply[4] == "${rec[2]-}" &&
                    ${rec[4]-} == "$my_tty" ]]; then
                    _tlogger_state=REC
                    if (( depth == 1 )); then
                        _tlogger_main=$dir
                    fi
                    break
                fi
                if [[ $reply[1] == script ]]; then
                    _tlogger_state=EXT
                    break
                fi
            fi
            child_tty=$reply[3] pid=$reply[2]
        done
    fi
    if [[ $_tlogger_state != REC ]]; then
        unset TLOGGER_SESSION TLOGGER_HS TLOGGER_HS_TZSET TLOGGER_HS_TZ
    fi
}

# Join the recording that tlogger start began, in the shell that script starts for it, for the
# session folder DIR that TLOGGER_HS named; _tlogger_init has already restored TZ and unset
# TLOGGER_HS*. DIR must be a fresh session folder directly under logdir, and the parent a script
# whose command line names its output.raw. Then writes recorder and started, exports
# TLOGGER_SESSION and prints the REC line; on any failure warns, writes no marker that says
# started, and returns 1. Needs _tlogger_cfg filled.
_tlogger_handshake() {
    emulate -L zsh
    setopt extendedglob
    local dir=$1
    local proc=${TLOGGER_PROC:-/proc} logdir=${_tlogger_cfg[logdir]-} why= boot= stamp
    local my_tty ppid start
    local -a reply args
    if [[ -z $logdir || $dir != /* || ${dir:h} != "$logdir" ]]; then
        why='its folder does not lie directly under the log folder'
    elif [[ ${dir:t} != [0-9](#c8)T[0-9](#c6)Z-[A-Za-z0-9](#c6) ]]; then
        why='its folder name is not a session name'
    elif [[ -L $dir || ! -d $dir || ! -O $dir ]]; then
        why="its folder is a symlink, not a folder or another user's"
    elif [[ -L $dir/output.raw || ! -f $dir/output.raw ]]; then
        why='its folder holds no output.raw'
    elif [[ -e $dir/started || -L $dir/started ]]; then
        why='its session has started already'
    elif ! _tlogger_stat $$; then
        why="cannot read this shell's process"
    else
        my_tty=$reply[3] ppid=$reply[2]
        if ! _tlogger_stat $ppid || [[ $reply[1] != script ]]; then
            why='the parent process is not script'
        else
            start=$reply[4]
            { args=(${(0)"$(<$proc/$ppid/cmdline)"}); } 2> /dev/null
            { boot=$(<$proc/sys/kernel/random/boot_id); } 2> /dev/null
            if (( ! ${args[(Ie)$dir/output.raw]} )); then
                why="the parent script does not write this session's output.raw"
            elif [[ $boot != [0-9a-f-]## ]]; then
                why='cannot read the boot id'
            fi
        fi
    fi
    if [[ -z $why ]]; then
        _tlogger_utc stamp '%Y-%m-%dT%H:%M:%SZ'
        if ! _tlogger_write_new $dir/recorder "$ppid $start $boot $my_tty"; then
            why='cannot write its recorder file'
        elif ! _tlogger_write_new $dir/started $stamp; then
            why='cannot write its started marker'
        fi
    fi
    if [[ -n $why ]]; then
        _tlogger_say yellow "warning: the recording handshake failed: $why"
        return 1
    fi
    export TLOGGER_SESSION=$dir
    _tlogger_say plain "REC ${dir:t}"
}

# Set reply to the total and the free amount that df -P<UNIT> reports for DIR: 1024-byte blocks
# for k, inodes for i. The numbers are read left of the capacity column, so that a device name
# with spaces still parses. Returns 1 when df fails or prints no line of that form.
_tlogger_df() {
    emulate -L zsh
    local out IFS=$' \t\n'
    local -a lines w
    local -i i
    reply=()
    if ! out=$(LC_ALL=C command df -P$1 -- $2 2> /dev/null); then
        return 1
    fi
    lines=("${(@f)out}")
    w=(${=lines[2]})
    for (( i = 4; i <= $#w; i++ )); do
        if [[ $w[i] != <->% && $w[i] != - ]]; then
            continue
        fi
        if [[ $w[i-3] == <-> && $w[i-2] == <-> && ( $w[i-1] == <-> || $w[i-1] == -<-> ) ]]; then
            reply=($w[i-3] $w[i-1])
            return 0
        fi
    done
    return 1
}

# Remove the session folder DIR when it holds nothing but empty output.raw, input.raw and timing
# files, as a recording that never started leaves it. Returns 0 when DIR is gone, 1 when it stays.
_tlogger_drop_empty() {
    emulate -L zsh
    local f
    local -a entries
    entries=($1/*(DN))
    for f in $entries; do
        case ${f:t} in
            output.raw | input.raw | timing)
                if [[ -L $f || ! -f $f || -s $f ]]; then
                    return 1
                fi
                ;;
            *)
                return 1
                ;;
        esac
    done
    if (( $#entries )) && ! command rm -f -- $entries 2> /dev/null; then
        return 1
    fi
    command rmdir -- $1 2> /dev/null
}

# Make the checks tlogger start runs before it records, in this order: the kill switches, this
# terminal's state, a terminal, the recorder, logdir and who else may write in it, its free space
# and inodes; then create the session folder and its empty log files, and check that their modes
# keep them private. Sets REPLY to the new folder, or to the reason a check failed and returns 1.
# Needs _tlogger_cfg filled. Creates nothing but a missing logdir until the session folder, which
# it removes again when that folder or a file in it is not private. Loads zstat of zsh/stat.
_tlogger_preflight() {
    emulate -L zsh
    setopt extendedglob
    local logdir=$_tlogger_cfg[logdir] recorder=$_tlogger_cfg[recorder]
    local min=$_tlogger_cfg[min_free_mb] shown_dir shown_rec help stamp dir f
    local -a reply st
    _tlogger_shown $logdir
    shown_dir=$REPLY
    _tlogger_shown $recorder
    shown_rec=$REPLY
    if [[ -n ${TLOGGER_DISABLE-} && $TLOGGER_DISABLE != 0 ]]; then
        REPLY='TLOGGER_DISABLE is set'
        return 1
    fi
    if [[ -e $_tlogger_cfg[config_dir]/disable || -L $_tlogger_cfg[config_dir]/disable ]]; then
        _tlogger_shown $_tlogger_cfg[config_dir]/disable
        REPLY="the kill switch $REPLY exists"
        return 1
    fi
    _tlogger_tty_state
    if [[ $_tlogger_state == REC ]]; then
        REPLY="already recorded, in session ${TLOGGER_SESSION:t}"
        return 1
    fi
    if [[ $_tlogger_state == EXT ]]; then
        REPLY='already recorded, by another script process'
        return 1
    fi
    if [[ ! -t 0 || ! -t 1 ]]; then
        REPLY='this shell has no terminal to record'
        return 1
    fi
    if [[ ! -f $recorder || ! -x $recorder ]]; then
        REPLY="the recorder $shown_rec is missing or not executable"
        return 1
    fi
    help=$($recorder --help < /dev/null 2> /dev/null)
    if [[ $help != *--logging-format* ]]; then
        REPLY="the recorder $shown_rec lacks --logging-format, which util-linux 2.35 and newer have"
        return 1
    fi
    # Created under umask 077, so that every folder mkdir -p makes on the way is private too.
    if [[ ! -e $logdir && ! -L $logdir ]] &&
        ! (umask 077 && command mkdir -p -m 700 -- $logdir) 2> /dev/null; then
        REPLY="the log folder $shown_dir cannot be created"
        return 1
    fi
    if [[ -L $logdir ]]; then
        REPLY="the log folder $shown_dir is a symlink"
        return 1
    fi
    if [[ ! -d $logdir ]]; then
        REPLY="the log folder $shown_dir is not a folder"
        return 1
    fi
    if [[ ! -O $logdir ]]; then
        REPLY="the log folder $shown_dir belongs to another user"
        return 1
    fi
    if [[ ! -w $logdir || ! -x $logdir ]]; then
        REPLY="the log folder $shown_dir is not writable"
        return 1
    fi
    # Another user who may write in logdir could rename a session folder and put a symlink in its
    # place; the sticky bit keeps each entry to its owner. zstat, loaded alone, reads the mode
    # without a fork and leaves the stat command as it is.
    if ! zmodload -F zsh/stat b:zstat 2> /dev/null ||
        ! zstat -L -A st +mode $logdir 2> /dev/null; then
        REPLY="cannot read the mode of the log folder $shown_dir"
        return 1
    fi
    if (( (st[1] & 8#022) && (st[1] & 8#1000) == 0 )); then
        REPLY="the log folder $shown_dir is writable by its group or by others"
        return 1
    fi
    if [[ $min != <-> ]]; then
        min=200
    fi
    if ! _tlogger_df k $logdir; then
        _tlogger_say yellow "warning: cannot read the free space in $shown_dir; recording anyway"
    elif (( reply[2] < min * 1024 )); then
        REPLY="less than $min MB free in $shown_dir"
        return 1
    fi
    if _tlogger_df i $logdir && (( reply[1] > 0 && reply[2] < 100 )); then
        REPLY="fewer than 100 free inodes in $shown_dir"
        return 1
    fi
    _tlogger_utc stamp '%Y%m%dT%H%M%SZ'
    if ! dir=$(command mktemp -d $logdir/$stamp-XXXXXX 2> /dev/null) ||
        [[ $dir != $logdir/$stamp-?????? || -L $dir || ! -d $dir ]]; then
        REPLY="cannot create a session folder in $shown_dir"
        return 1
    fi
    # script opens the logs with fopen "w", which keeps the mode of a file that exists.
    if ! (umask 077 && : >| $dir/output.raw && : >| $dir/timing &&
        if [[ $_tlogger_cfg[record_input] == yes ]]; then : >| $dir/input.raw; fi) 2> /dev/null
    then
        _tlogger_drop_empty $dir
        REPLY="cannot create the log files in $shown_dir"
        return 1
    fi
    # A file system without POSIX modes, such as vfat, may give them other modes than 0700 and
    # 0600; no group or other bit may be set.
    for f in $dir $dir/*(DN); do
        if ! zstat -L -A st +mode $f 2> /dev/null || (( st[1] & 8#077 )); then
            _tlogger_drop_empty $dir
            REPLY="cannot keep the session private in $shown_dir"
            return 1
        fi
    done
    REPLY=$dir
}

# Record this terminal, for tlogger start (KIND start) or for autostart (KIND auto): find the zsh
# binary, run the preflight, print the banner and run the recorder in the foreground, with
# TZ=UTC0 for its timestamps and SHELL set to that binary; then tell how the recording ended from
# the markers in the session folder, never from the exit status or script's own messages. Prints
# the notice of each outcome, but none for a recording that ended in KIND auto. Sets REPLY to
# ended, paused, unexpected, failed or refused, and reply to the recorder's exit status, empty
# unless it ran; callers declare both local. Returns 0 when the recording ended or was paused, 1
# when a check refused it, it failed to start or it ended unexpectedly. Needs _tlogger_cfg filled.
_tlogger_record() {
    emulate -L zsh
    local kind=$1 dir id zsh_bin tzset=0 tzval=
    local -i rc
    local -a login
    reply=()
    # The binary this shell runs, so that the recorded shell is the same zsh.
    zsh_bin=${${:-${TLOGGER_PROC:-/proc}/$$/exe}:A}
    if [[ ! -f $zsh_bin || ! -x $zsh_bin ]]; then
        zsh_bin=${commands[zsh]-}
    fi
    if [[ -z $zsh_bin ]]; then
        _tlogger_say red 'NOT recording this terminal: cannot find the zsh binary'
        REPLY=refused
        return 1
    fi
    if ! _tlogger_preflight; then
        _tlogger_say red "NOT recording this terminal: $REPLY"
        REPLY=refused
        return 1
    fi
    dir=$REPLY id=${REPLY:t}
    # Only an exported TZ reaches the commands this shell runs, so only that one is passed on.
    if [[ ${(t)TZ} == *export* ]]; then
        tzset=1 tzval=$TZ
    fi
    if [[ $_tlogger_cfg[record_input] == yes ]]; then
        login=(--log-in $dir/input.raw)
        _tlogger_say plain "recording session $id; everything typed and shown is saved, passwords included; tlogger stop pauses"
    else
        _tlogger_say plain "recording session $id; everything shown is saved, keystrokes are not; tlogger stop pauses"
    fi
    TLOGGER_HS=$dir TLOGGER_HS_TZSET=$tzset TLOGGER_HS_TZ=$tzval TZ=UTC0 SHELL=$zsh_bin \
        $_tlogger_cfg[recorder] --quiet --flush --return --logging-format advanced \
        --log-timing $dir/timing $login --log-out $dir/output.raw
    rc=$?
    reply=($rc)
    # A marker counts only with its line in it.
    if [[ -s $dir/started ]]; then
        if [[ -s $dir/stop-requested ]]; then
            _tlogger_say plain 'recording paused; this terminal is NOT recorded; tlogger start resumes in a new session'
            REPLY=paused
            return 0
        fi
        if [[ -s $dir/exited ]]; then
            if [[ $kind != auto ]]; then
                _tlogger_say plain 'recording ended; this terminal is NOT recorded'
            fi
            REPLY=ended
            return 0
        fi
        _tlogger_say yellow "recording ended unexpectedly; session $id kept"
        REPLY=unexpected
        return 1
    fi
    if _tlogger_drop_empty $dir; then
        _tlogger_say red 'recording failed to start'
    else
        _tlogger_say red "recording failed to start; session $id kept"
    fi
    REPLY=failed
    return 1
}

# tlogger start: read the config again and record this terminal with _tlogger_record. The
# terminal always stays open, in auto mode too: the end of the recording returns to this shell's
# prompt. Returns 0 when the recording was paused or ended, 1 when a check refused it, it failed to
# start or it ended unexpectedly.
_tlogger_start() {
    emulate -L zsh
    local REPLY
    local -a reply
    _tlogger_load_config
    _tlogger_record start
}

# tlogger stop: pause the recording. Works only in the main recorded shell, outside a subshell
# and with no running or suspended job: writes stop-requested and returns 0, and tlogger then
# exits that shell, which ends script and hands the terminal back to the shell that ran tlogger
# start. Elsewhere it says why and returns 1.
_tlogger_stop() {
    emulate -L zsh
    local stamp
    local -a live
    if (( ZSH_SUBSHELL )); then
        _tlogger_say plain 'tlogger stop does not work in a subshell'
        return 1
    fi
    _tlogger_tty_state
    if [[ $_tlogger_state == NOREC ]]; then
        _tlogger_say plain 'this terminal is NOT recorded; there is nothing to stop'
        return 1
    fi
    if [[ $_tlogger_state == EXT ]]; then
        _tlogger_say plain 'this terminal is recorded by another script process, which tlogger stop does not end'
        return 1
    fi
    if [[ -z $_tlogger_main ]]; then
        _tlogger_say plain "this is a nested shell in session ${TLOGGER_SESSION:t}; type exit to leave it, then run tlogger stop in the main shell"
        return 1
    fi
    live=(${${(v)jobstates}:#done*})
    if (( $#live )); then
        _tlogger_say plain "this shell has $#live job(s); end or disown them, then run tlogger stop again"
        return 1
    fi
    _tlogger_utc stamp '%Y-%m-%dT%H:%M:%SZ'
    if ! _tlogger_write_new $_tlogger_main/stop-requested $stamp; then
        _tlogger_say red "cannot write the stop marker in session ${_tlogger_main:t}; the recording goes on"
        return 1
    fi
}

# tlogger status: print on stdout the plugin version, this terminal's state, its session and the
# config values mode, logdir (in the ~ form) and record_input. Config warnings go to stderr.
_tlogger_status() {
    emulate -L zsh
    local REPLY version=unknown state session=none
    _tlogger_load_config
    _tlogger_tty_state
    if [[ -r $_tlogger_release/VERSION ]]; then
        IFS= read -r version < $_tlogger_release/VERSION || :
    fi
    case $_tlogger_state in
        REC) state="REC ${TLOGGER_SESSION:t}" session=${TLOGGER_SESSION:t} ;;
        EXT) state='EXT, recorded by another script process' ;;
        *) state='NOREC, this terminal is NOT recorded' ;;
    esac
    _tlogger_shown $_tlogger_cfg[logdir]
    print -r -- "tlogger plugin ${version:-unknown}"
    printf '  %-13s %s\n' state: "$state" session: "$session" mode: "$_tlogger_cfg[mode]" \
        logdir: "$REPLY" record_input: "$_tlogger_cfg[record_input]"
}

# zshexit hook: in the main recorded shell, write exited into the session folder, so that the
# shell that ran tlogger start can tell an exit from a crash. Only while the recorder is still
# this shell's parent and the recorded terminal still its own: zsh runs the hook on a hangup too,
# and a hangup, such as the death of the recorder, takes the terminal away, so that stat then
# shows tty_nr 0 and the session counts as ended unexpectedly. Does nothing in any other shell.
# It calls no shell function, only builtins, and so repeats what _tlogger_stat, _tlogger_utc and
# _tlogger_write_new do: after an exit from inside nested functions, zsh runs the hook with that
# exit still pending, and the first function the hook called would make the hook return early.
_tlogger_zshexit() {
    emulate -L zsh
    local line stamp fd
    local -a rec f
    local -i rc
    if [[ -z ${_tlogger_main-} ]] || (( ZSH_SUBSHELL )); then
        return 0
    fi
    { rec=(${(s: :)"$(<$_tlogger_main/recorder)"}); } 2> /dev/null
    { line=$(<${TLOGGER_PROC:-/proc}/$$/stat); } 2> /dev/null
    # The fields after the last ')' of stat: the ppid is the second of them, tty_nr the fifth.
    f=(${(s: :)${line##*\)}})
    if [[ $line != *'('*')'* || $#rec != 4 || $f[2] != "$rec[1]" || $f[5] != "$rec[4]" ]]; then
        return 0
    fi
    local -x TZ=UTC0
    strftime -s stamp '%Y-%m-%dT%H:%M:%SZ' $EPOCHSECONDS
    if ! sysopen -w -o creat,excl,nofollow,cloexec -m 600 -u fd $_tlogger_main/exited 2> /dev/null; then
        return 0
    fi
    {
        print -r -u $fd -- $stamp 2> /dev/null
        rc=$?
    } always {
        exec {fd}>&-
    }
    # Only a full disk or an I/O error gets here; no empty marker may stay behind.
    if (( rc )); then
        command rm -f -- $_tlogger_main/exited 2> /dev/null
    fi
    return 0
}

# In a shell that script started for a recording, restore TZ and unset TLOGGER_HS* before
# anything can fail, so that no failure leaves them to this shell and its children, and keep the
# session folder that TLOGGER_HS named in _tlogger_hs, empty in every other shell, so that
# autostart never runs in a shell that a recorder started. Then load the zsh modules and
# lib/config.zsh, read the config, run the handshake there, work out this terminal's state and add
# the zshexit hook. Runs once, when the plugin is sourced. Returns 0, or prints one warning and
# returns 1 when a module or lib/config.zsh is missing.
_tlogger_init() {
    emulate -L zsh
    local REPLY hs=${TLOGGER_HS-}
    # TLOGGER_HS_TZSET is 1 when TZ was exported outside the recording, and 0 when it was not.
    if [[ -n $hs ]]; then
        case ${TLOGGER_HS_TZSET-} in
            1) export TZ=${TLOGGER_HS_TZ-} ;;
            0) unset TZ ;;
        esac
    fi
    unset TLOGGER_HS TLOGGER_HS_TZSET TLOGGER_HS_TZ
    typeset -g _tlogger_hs=$hs
    if ! zmodload zsh/datetime zsh/system zsh/parameter 2> /dev/null; then
        _tlogger_say plain 'warning: zsh lacks the zsh/datetime, zsh/system or zsh/parameter module; tlogger cannot record in this terminal'
        return 1
    fi
    # zsh would name a damaged file in full in its parse error; the warning names it with ~.
    if [[ ! -f $_tlogger_release/lib/config.zsh ]] ||
        ! source $_tlogger_release/lib/config.zsh 2> /dev/null ||
        (( ! ${+functions[_tlogger_load_config]} )); then
        _tlogger_shown $_tlogger_release/lib/config.zsh
        _tlogger_say plain "warning: $REPLY is missing or broken; tlogger cannot record in this terminal"
        return 1
    fi
    _tlogger_load_config
    if [[ -n $hs ]]; then
        _tlogger_handshake $hs
    fi
    _tlogger_tty_state
    # add-zsh-hook leaves hooks of others, such as Kali's precmd, as they are.
    autoload -Uz add-zsh-hook
    if ! add-zsh-hook zshexit _tlogger_zshexit 2> /dev/null; then
        typeset -ga zshexit_functions
        zshexit_functions=(${zshexit_functions:#_tlogger_zshexit} _tlogger_zshexit)
    fi
    return 0
}

# Set REPLY to the first reason autostart does not run in this shell, or to empty when it runs.
# The checks run in this order, which is part of the contract: the mode is not auto, a TLOGGER_MODE
# preset included; ZSH_EXECUTION_STRING is set, as zsh -c and IDE probes set it;
# VSCODE_RESOLVING_ENVIRONMENT, or ASCIINEMA_REC or ASCIINEMA_SESSION, is not empty; an SSH login
# with record_ssh=no; a tmux pane with record_tmux=no; a shell that is not interactive or lacks a
# terminal on stdin or stdout; a terminal that is REC or EXT already, or a shell that a recorder
# started (_tlogger_hs). Only the last two checks need a terminal. Prints nothing and forks
# nothing; needs _tlogger_cfg filled. The last check runs _tlogger_tty_state.
_tlogger_autostart_why() {
    emulate -L zsh
    REPLY=
    if [[ ${_tlogger_cfg[mode]-} != auto ]]; then
        REPLY='the mode is not auto'
    elif (( ${+ZSH_EXECUTION_STRING} )); then
        REPLY='ZSH_EXECUTION_STRING is set'
    elif [[ -n ${VSCODE_RESOLVING_ENVIRONMENT-} ]]; then
        REPLY='VSCODE_RESOLVING_ENVIRONMENT is set'
    elif [[ -n ${ASCIINEMA_REC-} || -n ${ASCIINEMA_SESSION-} ]]; then
        REPLY='ASCIINEMA_REC or ASCIINEMA_SESSION is set'
    elif [[ ( -n ${SSH_CONNECTION-} || -n ${SSH_TTY-} ) && ${_tlogger_cfg[record_ssh]-} == no ]]; then
        REPLY='an SSH login, and record_ssh is no'
    elif [[ -n ${TMUX-} && ${_tlogger_cfg[record_tmux]-} == no ]]; then
        REPLY='a tmux pane, and record_tmux is no'
    elif [[ ! -o interactive || ! -t 0 || ! -t 1 ]]; then
        REPLY='not an interactive shell on a terminal'
    else
        _tlogger_tty_state
        if [[ $_tlogger_state == REC ]]; then
            REPLY="already recorded, in session ${TLOGGER_SESSION:t}"
        elif [[ $_tlogger_state == EXT ]]; then
            REPLY='already recorded, by another script process'
        elif [[ -n ${_tlogger_hs-} ]]; then
            # A recorder whose handshake failed and that zsh cannot see as script, such as one
            # under another name; recording here would nest recorders without end.
            REPLY='a recorder started this shell, and its handshake failed'
        fi
    fi
}

# Autostart: record this new terminal with _tlogger_record, as tlogger start does, unless
# _tlogger_autostart_why finds a reason not to, in which case it does nothing and prints nothing.
# A recording that ended, started and exited without stop-requested, exits this shell with the
# recorder's exit status, so that the window closes, and prints nothing. After a pause or a
# failure, whose notices _tlogger_record prints, it returns 0, and the rest of the rc loads in an
# ordinary NOREC shell. The exit runs here, one function deep, for the reason tlogger gives for
# its own. Called once, by the plugin's last lines, after _tlogger_init succeeded.
_tlogger_autostart() {
    emulate -L zsh
    local REPLY
    local -a reply
    _tlogger_autostart_why
    if [[ -n $REPLY ]]; then
        return 0
    fi
    if _tlogger_record auto && [[ $REPLY == ended ]]; then
        builtin exit $reply[1]
    fi
    return 0
}

# tlogger: start, stop and status run in this shell and take no arguments; every other
# subcommand runs <release>/bin/tlogger with the same arguments and returns its exit status.
# The function keyword keeps an alias named tlogger from changing this definition.
function tlogger {
    # Confines option changes to this function; the shell's own options stay as they are.
    emulate -L zsh
    local REPLY
    case ${1-} in
        start | stop | status)
            if (( $# > 1 )); then
                _tlogger_say plain "$1 takes no arguments"
                return 2
            fi
            if (( ! ${+functions[_tlogger_load_config]} )) || ! zmodload -e zsh/datetime ||
                ! zmodload -e zsh/system; then
                _tlogger_say plain 'the plugin did not load completely; open a new terminal'
                return 1
            fi
            if [[ $1 == stop ]]; then
                # The exit runs here, one function deep: after an exit from deeper down, zsh runs
                # every zshexit hook with that exit pending, which cuts the hooks short.
                _tlogger_stop || return 1
                builtin exit 0
            fi
            _tlogger_$1
            return
            ;;
    esac
    if [[ -z $_tlogger_release || ! -x $_tlogger_release/bin/tlogger ]]; then
        _tlogger_shown ${_tlogger_release:-the release folder}
        _tlogger_say plain "$REPLY/bin/tlogger is missing; run tlogger install from a checkout"
        return 1
    fi
    "$_tlogger_release/bin/tlogger" "$@"
}

# Loading never ends the rc early: an error inside _tlogger_init or the autostart is caught here
# and reported in one warning, and the rest of the rc runs as usual. Only an autostarted recording
# that ended normally ends this shell, from inside _tlogger_autostart.
{
    if _tlogger_init; then
        _tlogger_autostart
    fi
} always {
    if (( TRY_BLOCK_ERROR )); then
        TRY_BLOCK_ERROR=0
        print -ru2 -- 'tlogger: warning: the plugin hit an error while loading; recording may not work in this terminal'
    fi
}
