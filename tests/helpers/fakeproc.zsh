# A fake /proc tree for tests/guard.bats: made-up processes, a boot id and a session folder, so
# that the plugin's process walk and handshake read known data. Sourced by the zsh under test with
# TLOGGER_PROC set to an empty folder; that zsh writes the entry for its own $$ itself.

# The boot id of the fake tree, and the session folder fake_session creates, beside the tree.
FAKE_BOOT=0b1e7c5a-4d2f-4c3b-9a8e-7f6d5c4b3a21
FAKE_SESSION=${TLOGGER_PROC:h}/session

# Write <TLOGGER_PROC>/PID/stat as Linux formats it, for the process PID named COMM, with parent
# PPID, controlling terminal TTY_NR (0 for none) and STARTTIME (default 1000) as field 22. COMM
# may hold spaces and parentheses, as a real one can.
fake_proc() {
    mkdir -p -- $TLOGGER_PROC/$1
    print -r -- "$1 ($2) S $3 $3 $3 $4 -1 4194560 100 0 0 0 0 0 0 0 20 0 1 0 ${5:-1000} 9887744 1024" \
        > $TLOGGER_PROC/$1/stat
}

# Write <TLOGGER_PROC>/PID/cmdline with the arguments ARG..., each ended by a NUL byte.
fake_cmdline() {
    local pid=$1
    shift
    mkdir -p -- $TLOGGER_PROC/$pid
    print -rn -- "${(pj:\0:)@}"$'\0' > $TLOGGER_PROC/$pid/cmdline
}

# Create FAKE_SESSION with a recorder file that names the recorder PID, its STARTTIME, the fake
# boot id and the terminal TTY_NR it records, and export TLOGGER_SESSION as that folder.
fake_session() {
    mkdir -p -- $FAKE_SESSION
    print -r -- "$1 $2 $FAKE_BOOT $3" > $FAKE_SESSION/recorder
    export TLOGGER_SESSION=$FAKE_SESSION
}

mkdir -p -- $TLOGGER_PROC/sys/kernel/random
print -r -- $FAKE_BOOT > $TLOGGER_PROC/sys/kernel/random/boot_id
