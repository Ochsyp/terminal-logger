#!/usr/bin/env bats
# Tests for tlogger discard in bin/tlogger, run as a subprocess in the test's own HOME on
# synthetic sessions. A fake /proc, which TLOGGER_PROC names, holds the boot id, the mountinfo
# and the processes that discard reads, so that a session counts as still recorded only when a
# test says so. TLOGGER_NOW, which discard reads instead of the clock for its 10-minute rule when
# it is 1 to 12 digits without a leading 0, lets a test make a session old: touch -d cannot set a
# file's ctime back. TLOGGER_LOCK_WAIT, 1 to 3 digits, is the seconds discard waits for the lock
# of a session folder instead of 10, so that a test of a lock held elsewhere ends soon; a value
# of another form is ignored. hold_lock (helpers.bash) holds that lock from the test. Stand-ins
# first on PATH log every rm, unlink, rmdir and sync that bin/tlogger runs: rm fails, unlink
# fails for one named file as on an immutable one, and sync fails when a test says so. One test
# answers discard's question in a pseudo-terminal that zsh's zpty module drives
# (tests/helpers/pty.zsh).
#
# The contract these tests pin. Every message starts with 'tlogger: ' and shows a path under HOME
# with ~; <log folder> is ~/.local/state/tlogger/sessions here, and <parent> is the folder that
# holds the session: the log folder, an engagement folder in it, or any folder for a path.
#
# tlogger discard SESSION [--confirm ID]
# - It removes ONE session that cannot be sealed, unsealed or unknown, with a record. SESSION is
#   required, never the newest by default: a session id, looked up as seal, verify and show do
#   (resolve_session: the log folder and its engagement folders), or a path to a session folder.
#   --confirm=ID is accepted too. -h and --help print the usage and exit 0.
# - Usage errors exit 2, the message first on stderr, then the usage:
#     tlogger: discard needs a session: its id or its path
#     tlogger: discard takes one session
#     tlogger: unknown option for discard: <option>
#     tlogger: --confirm needs a value: the session's id
#   Then, off a terminal (stdin or stderr no tty) without --confirm, exit 2 with this line alone,
#   before anything is read:
#     tlogger: --confirm is required with discard when not run from a terminal
# - Then it resolves the session; resolve_session's own refusals and exit codes stand (no log
#   folder: exit 3; no such session, no session id, a folder that is a symlink or holds no
#   output.raw: exit 1, with its messages). So a session folder that is a symlink is refused by
#   resolve_session's line '<folder> is a symlink, which tlogger does not follow'. A session
#   folder whose name holds a space or a control character, which only a path can name, is
#   refused next, as a PRUNED line cannot hold it:
#     tlogger: the name of <folder> holds a space or a control character, which a PRUNED line
#     cannot hold; rename it
#   (one line). A session named by a path whose <parent>, or the folder above <parent>, is the
#   log folder by their physical paths (pwd -P), so that <parent> is the log folder or a folder
#   in it, gets the checks of a session named by its id below ("by id" covers it). For a path,
#   discard reads the config for that: an unsafe config exits 1 with resolve_logdir's line
#     tlogger: the config <config> <what is wrong>; fix it by hand
#   and a log folder that does not exist matches no path.
# - It checks, in this order, and stops at the first that fails: exit 1, nothing on stdout, the
#   one message alone on stderr, and nothing changed anywhere:
#   1. by id, the volume of logdir_mount, as archive and prune check it:
#        tlogger: the volume <mount> of the log folder is not mounted
#      and check_logdir_mount's other lines; then <parent>, closed to its group and others,
#      sticky bit or not:
#        tlogger: the folder <parent> is writable by its group or by others; chmod go-w
#        <parent> fixes it
#      (one line).
#   2. the session folder (discard never runs chmod):
#        tlogger: session <id>: its folder is a symlink, which tlogger does not follow
#        tlogger: session <id>: its folder belongs to another user
#        tlogger: session <id>: its folder is writable by its group or by others; chmod go-w
#        <folder> fixes it
#        tlogger: session <id>: its folder has mode <mode>, so you cannot remove its files
#      (the third one line), the last when you may not read, write and search it.
#   3. sealed: the folder holds SEAL, SHA256SUMS, SEAL.part.* or SHA256SUMS.part.*, or the
#      MANIFEST of <parent> has a line for <id>:
#        tlogger: session <id> is sealed; tlogger archive and tlogger prune remove sealed
#        sessions
#      (one line). A changed sealed session is caught here too. A MANIFEST that is a symlink,
#      not a regular file or unreadable:
#        tlogger: cannot read <parent>/MANIFEST, so discard cannot tell whether session <id> is
#        sealed
#      (one line). Then a log of SEAL_FILES of mode 0400, as seal leaves it, where a recording
#      leaves 0600:
#        tlogger: session <id> has logs of mode 400, as seal leaves them, so it may be a sealed
#        session whose seal is gone; discard refuses it
#      (one line). Then, by id, the MANIFEST of the log folder and of each engagement folder,
#      with the same two lines: a sealed session moved by hand to another folder, its SEAL and
#      SHA256SUMS deleted and its logs set back to 0600, is still found, named by its id or by
#      its path in the log folder.
#   4. the verdict of verify must be unsealed or unknown:
#        tlogger: session <id> is still being recorded; discard refuses it
#      and, unsealed or unknown alike, no script process under TLOGGER_PROC (default /proc) may
#      write it. A process counts only when its name in <pid>/stat, between the first '(' and
#      the last ')', is exactly script, as the plugin's handshake reads it: a scriptreplay of the
#      session or a less of its output.raw never does. Such a process writes it when an argument
#      of its cmdline, split on NUL, is <folder>/output.raw, as the handshake looks for it, or
#      another path ending in /output.raw to the same file, by device and inode; or when an
#      entry of its fd/ resolves, by device and inode, to <folder>/output.raw, timing or
#      input.raw, as for a script started with a relative path:
#        tlogger: session <id> is still being recorded: a script process writes its output.raw;
#        discard refuses it
#      (one line).
#   5. unknown only: the folder or any entry in it changed in the last 600 seconds, by the later
#      of its mtime and its ctime, which touch -d cannot set back:
#        tlogger: session <id> has no recorder file and changed in the last 10 minutes, so a
#        terminal may still record into it; try again later
#      (one line).
#   6. its entries: only output.raw, timing, input.raw, commands.tsv, recorder, started, exited,
#      stop-requested, transcript.txt and transcript.txt.part, each a regular file of yours, not
#      a symlink, with one hard link; dot files count as entries:
#        tlogger: session <id> holds <entry>, which is no file of a session; discard removes
#        only a session's own files
#        tlogger: session <id>: <entry> is a symlink, which tlogger does not follow
#        tlogger: session <id>: <entry> is not a regular file
#        tlogger: session <id>: <entry> belongs to another user
#        tlogger: session <id>: <entry> has more than one hard link
#      (the first one line).
#   7. <parent>/PRUNED, when it exists, then <parent> itself:
#        tlogger: <parent>/PRUNED is a symlink, which tlogger does not follow
#        tlogger: <parent>/PRUNED is not a regular file
#        tlogger: <parent>/PRUNED belongs to another user
#        tlogger: <parent>/PRUNED has more than one hard link
#        tlogger: you cannot write in <parent>, so discard cannot remove the folder of session
#        <id>
#      (the last one line). Another user's PRUNED, or entry, needs root to make, so no test here
#      covers those two lines.
# - Then it shows the session on stdout, these 6 lines, printf '%-8s  %s\n':
#     session   <id>
#     folder    <parent>
#     state     unsealed|unknown
#     start     <YYYY-MM-DDTHH:MM:SSZ, from the id, as list shows it>
#     length    <list's duration: the DURATION of timing as HH:MM:SS>
#     commands  <the S lines of commands.tsv, as list counts them; 0 without one>
# - With --confirm ID it compares ID with <id>. Without, on a terminal, it asks on stderr, with
#   no line end, and reads one line:
#     tlogger: this cannot be undone; type the session's id, <id>, to go ahead:
#   (ending with ': '). A wrong ID or answer: exit 1, stdout the 6 lines, nothing changed, and
#   stderr ends with: tlogger: nothing changed
# - Then, with HUP, INT, PIPE, QUIT and TERM held off, it goes into the session folder (cd -P)
#   and exits 1, writing and removing nothing, unless that is the folder it found, by the device
#   and inode it took right after resolving the session:
#     tlogger: session <id>: its folder changed while discard checked it; nothing of it was
#     removed
#   (one line). It takes an exclusive flock on that folder, through a read-only fd on the folder
#   itself, the lock that seal takes for its whole run on a session, and holds it through rmdir,
#   so that seal and discard never work on one session at once. When the lock cannot be had
#   within TLOGGER_LOCK_WAIT seconds (default 10): exit 1, stdout the 6 lines, nothing changed,
#   and stderr ends with (one line):
#     tlogger: another tlogger command works on session <id>; nothing of it was removed; try
#     again
#   Then the path must still name that folder, with the "changed" line above, and it checks
#   everything again: any change since, such as a SEAL or a stray file made while the question
#   waits, exits 1 with the matching refusal and removes nothing; then the path once more. Then
#   it appends to <parent>/PRUNED, under flock, made with mode 0600, after a line end when the
#   file does not end with one, this line, flushes it with sync -- <parent>/PRUNED (no
#   fallback), and prints it on stdout:
#     <UTC time as YYYY-MM-DDTHH:MM:SSZ>  <id>  -  -  -  discarded <state> by tlogger <version>
#   (fields split by two spaces, as prune's; the dashes stand for prune's sum, archive and its
#   sum). A line that cannot be written: exit 1, nothing removed, last on stderr:
#     tlogger: cannot write <parent>/PRUNED; nothing of session <id> was removed
#   Written but not flushed: exit 1, the line stays, nothing removed, last on stderr:
#     tlogger: cannot flush <parent>/PRUNED to the disk; it holds the line of session <id>, but
#     nothing of it was removed; run discard again
#   (one line).
# - Then it removes each entry by its own name, relative to the session folder, with unlink --,
#   found on PATH, never rm, chmod, a glob or a recursive removal, those present in this order:
#   input.raw, commands.tsv, started, exited, stop-requested, transcript.txt.part,
#   transcript.txt, then timing and output.raw, which make the folder a session, and recorder
#   last; then, from the folder above it (cd -P ..), rmdir -- <id>. The stand-ins log each name
#   resolved, so the logged paths are absolute. A stdout or stderr that cannot be written never
#   stops the removal. The first failure: exit 1, last on stderr, while the folder still holds
#   output.raw and timing:
#     tlogger: cannot remove <file>; session <id> is discarded only in part; run discard again
#     once that is fixed
#   and a run again on what is left works like a first run and writes another line, though for
#   an unknown session the removal counts as a change, so that run waits 10 minutes; once
#   either is gone, as discard then no longer finds the session:
#     tlogger: cannot remove <file>; session <id> is discarded only in part, and without its
#     logs discard no longer finds it; remove what is left of <dir> by hand once that is fixed
#   and when rmdir fails, every file being gone:
#     tlogger: cannot remove <dir>; its files are gone, and discard no longer finds it; remove
#     the empty folder by hand once that is fixed
#   (each one line).
# - Done: exit 0, stdout the 6 lines then the PRUNED line, and this line alone on stderr:
#     tlogger: discarded session <id>; <parent>/PRUNED records it. Its data is gone from this
#     folder but not wiped from the disk
#   (one line).
# - It never touches the MANIFEST, other sessions, <parent> itself but for PRUNED and the
#   session folder, .archive or archives. verify --all then gives no line for <id>, and a
#   discarded line never makes a sealed session's MANIFEST line count as pruned, nor give the
#   hint of a prune cut short: its sum field is '-'.
# - Exit codes: 0 done; 1 a refusal, a failure, a wrong id, a session it does not find or a lock
#   it cannot have; 2 a usage error, or no --confirm off a terminal; 3 no log folder, and nothing
#   else.

bats_require_minimum_version 1.5.0

load helpers

# The boot id of the fake /proc, and the recorder that each synthetic session names; make_session
# and fake_process in helpers.bash read them, and LOGS and PROC, which setup sets.
BOOT=0b1e7c5a-4d2f-4c3b-9a8e-7f6d5c4b3a21
REC_PID=4242
REC_START=1000

# The log folder as tlogger shows it.
# shellcheck disable=SC2088 # The ~ is the text tlogger prints, not a path to expand.
SHOWN='~/.local/state/tlogger/sessions'

# A SHA-256 that no file here has.
ZERO_SUM=0000000000000000000000000000000000000000000000000000000000000000

# Run before each test by bats.
# Gives the test its own HOME with the default layout, a log folder of mode 0700, a fake /proc
# with a boot id and no process, and three session ids.
setup() {
    isolate_home
    isolate_tlogger
    LOGS="$HOME/.local/state/tlogger/sessions"
    mkdir -p "$LOGS"
    chmod 700 "$LOGS"
    PROC="$BATS_TEST_TMPDIR/proc"
    mkdir -p "$PROC/sys/kernel/random" "$PROC/self"
    printf '%s\n' "$BOOT" > "$PROC/sys/kernel/random/boot_id"
    : > "$PROC/self/mountinfo"
    export TLOGGER_PROC="$PROC"
    A=20261112T100000Z-a1B2c3
    B=20261112T110000Z-b2C3d4
    C=20261112T120000Z-c3D4e5
}

# Run after each test by bats.
# Ends a lock that hold_lock still holds, and gives every folder under HOME back to its owner's
# write, so that bats can remove a folder that a test closed.
teardown() {
    release_lock
    if [[ -d $HOME ]]; then
        find "$HOME" -type d -exec chmod u+rwx {} + 2> /dev/null || true
    fi
}

# Write the config with the lines TEXT, in a config folder of mode 0700.
write_config() {
    mkdir -p "$HOME/.config/tlogger"
    chmod 700 "$HOME/.config/tlogger"
    printf '%s' "$1" > "$HOME/.config/tlogger/config"
    chmod 600 "$HOME/.config/tlogger/config"
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

# Write the stand-ins that run_watched puts first on PATH, in a folder of the test's own, and
# empty CALLS, UNLINK_FAIL and SYNC_FAIL. rm, which discard must never run, logs 'rm<tab><its
# arguments>' to CALLS and fails loudly. unlink, rmdir and sync log '<name><tab><their last
# argument, resolved>' to CALLS. unlink fails as on an immutable file for the resolved file that
# UNLINK_FAIL names, sync fails when SYNC_FAIL is 1; else each runs the real tool.
make_stand_ins() {
    local name real
    STAND_INS="$BATS_TEST_TMPDIR/stand-ins"
    CALLS="$BATS_TEST_TMPDIR/calls"
    UNLINK_FAIL=
    SYNC_FAIL=
    mkdir -p "$STAND_INS"
    : > "$CALLS"
    # The stand-ins expand these when they run, not this function.
    # shellcheck disable=SC2016
    printf '%s\n' '#!/usr/bin/env bash' \
        'printf '\''rm\t%s\n'\'' "$*" >> "$CALLS"' \
        'printf '\''rm stand-in: discard ran rm %s\n'\'' "$*" >&2' \
        'exit 1' > "$STAND_INS/rm"
    for name in unlink rmdir sync; do
        real=$(command -v "$name")
        # shellcheck disable=SC2016
        printf '%s\n' '#!/usr/bin/env bash' \
            'file=$(readlink -f -- "${!#}")' \
            "printf '$name\\t%s\\n' \"\$file\" >> \"\$CALLS\"" \
            'if [[ -n ${UNLINK_FAIL-} && $file == "$UNLINK_FAIL" && ${0##*/} == unlink ]] ||' \
            '    [[ ${SYNC_FAIL-} == 1 && ${0##*/} == sync ]]; then' \
            '    printf '\''%s: %s: Operation not permitted\n'\'' "${0##*/}" "${!#}" >&2' \
            '    exit 1' \
            'fi' \
            "exec '$real' \"\$@\"" > "$STAND_INS/$name"
    done
    chmod 755 "$STAND_INS/rm" "$STAND_INS/unlink" "$STAND_INS/rmdir" "$STAND_INS/sync"
}

# Run bin/tlogger with ARGS as run_tlogger does, with the stand-ins of make_stand_ins first on
# its PATH, and CALLS, UNLINK_FAIL and SYNC_FAIL in its environment. The test's own commands keep
# the real tools.
run_watched() {
    require_test_home || return 1
    run --separate-stderr env PATH="$STAND_INS:$PATH" CALLS="$CALLS" UNLINK_FAIL="$UNLINK_FAIL" \
        SYNC_FAIL="$SYNC_FAIL" bash "$TLOGGER" "$@" < /dev/null
}

# Fail, naming the calls, if bin/tlogger ran rm since make_stand_ins.
refute_rm() {
    if grep -q '^rm'$'\t' "$CALLS"; then
        printf 'discard ran rm:\n%s\n' "$(grep '^rm'$'\t' "$CALLS")" >&2
        return 1
    fi
}

# Fail, naming the calls, if bin/tlogger ran rm, or unlink or rmdir on anything under HOME, since
# make_stand_ins.
refute_removed() {
    local hits home
    refute_rm || return 1
    home=$(readlink -f -- "$HOME")
    hits=$(grep -F -e "unlink"$'\t'"$home/" -e "rmdir"$'\t'"$home/" "$CALLS") || true
    if [[ -n $hits ]]; then
        printf 'discard removed files:\n%s\n' "$hits" >&2
        return 1
    fi
}

# Print the last line of the last run's stderr, or nothing.
last_stderr_line() {
    if (( ${#stderr_lines[@]} )); then
        printf '%s\n' "${stderr_lines[${#stderr_lines[@]} - 1]}"
    fi
}

# Print the 6 lines with which discard shows the session ID of the folder FOLDER, as shown, in the
# state STATE, with COMMANDS started commands (default 2, as make_session writes them) and the
# length LENGTH (default 00:01:00, the DURATION that make_session writes).
show_lines() {
    local id=$1
    printf '%-8s  %s\n' session "$id" folder "$2" state "$3" \
        start "${id:0:4}-${id:4:2}-${id:6:2}T${id:9:2}:${id:11:2}:${id:13:2}Z" \
        length "${5:-00:01:00}" commands "${4:-2}"
}

# Print the line with which discard says it is done with the session ID of the folder FOLDER, as
# shown.
done_msg() {
    printf 'tlogger: discarded session %s; %s/PRUNED records it. Its data is gone from this' \
        "$1" "$2"
    printf ' folder but not wiped from the disk\n'
}

# Print the refusal of the sealed session ID.
sealed_msg() {
    printf 'tlogger: session %s is sealed; tlogger archive and tlogger prune remove sealed' "$1"
    printf ' sessions\n'
}

# Print the refusal of the session ID whose folder its group or others may write in.
open_msg() {
    printf 'tlogger: session %s: its folder is writable by its group or by others; chmod go-w' \
        "$1"
    printf ' %s/%s fixes it\n' "$SHOWN" "$1"
}

# Print the refusal of the session ID whose output.raw a script process writes.
writer_msg() {
    printf 'tlogger: session %s is still being recorded: a script process writes its' "$1"
    printf ' output.raw; discard refuses it\n'
}

# Print the refusal of the session ID whose logs have mode 400, as seal leaves them.
mode400_msg() {
    printf 'tlogger: session %s has logs of mode 400, as seal leaves them, so it may be a' "$1"
    printf ' sealed session whose seal is gone; discard refuses it\n'
}

# Print the refusal of the folder FOLDER, as shown, that holds a session, when its group or
# others may write in it.
open_parent_msg() {
    printf 'tlogger: the folder %s is writable by its group or by others; chmod go-w %s' \
        "$1" "$1"
    printf ' fixes it\n'
}

# Make the process PID, started at START, a script process that writes the session folder DIR:
# fake_process, and a cmdline file that holds the arguments, each ended by a NUL, with which
# the plugin starts script, then ARGS in place of the default --log-out <DIR>/output.raw.
fake_script() {
    local pid=$1 start=$2 dir=$3
    shift 3
    if (( $# == 0 )); then
        set -- --log-out "$dir/output.raw"
    fi
    fake_process "$pid" "$start"
    printf '%s\0' script --quiet --flush --return --logging-format advanced --log-timing \
        "$dir/timing" --log-in "$dir/input.raw" "$@" > "$PROC/$pid/cmdline"
}

# Make the process PID of the fake /proc a process named NAME, no script, with ARGS as its
# cmdline, each ended by a NUL.
fake_other() {
    local pid=$1 name=$2
    shift 2
    mkdir -p "$PROC/$pid"
    printf '%s (%s) S 1 %s %s 34816 -1 4194560 100 0 0 0 0 0 0 0 20 0 1 0 3000 9887744 1024\n' \
        "$pid" "$name" "$pid" "$pid" > "$PROC/$pid/stat"
    printf '%s\0' "$@" > "$PROC/$pid/cmdline"
}

# Print the refusal of the session ID without a recorder file that changed in the last 10
# minutes.
fresh_msg() {
    printf 'tlogger: session %s has no recorder file and changed in the last 10 minutes, so a' "$1"
    printf ' terminal may still record into it; try again later\n'
}

# Print the refusal of the session ID that holds ENTRY, which no session holds.
foreign_msg() {
    printf 'tlogger: session %s holds %s, which is no file of a session; discard removes only' \
        "$1" "$2"
    printf " a session's own files\n"
}

# Fail unless LINE is a PRUNED line of discard, written in the last 10 minutes by this version of
# tlogger, for the session ID in the state STATE.
assert_discard_line() {
    local stamp=${1%%  *} want when now
    want="$2  -  -  -  discarded $3 by tlogger $(< "$REPO_ROOT/VERSION")"
    if [[ ${1#*  } != "$want" ||
        ! $stamp =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
        printf 'expected a PRUNED line\n<UTC time>  %s\ngot\n%s\n' "$want" "$1" >&2
        return 1
    fi
    when=$(date -u -d "$stamp" +%s)
    now=$(date -u +%s)
    if (( now - when < 0 || now - when > 600 )); then
        printf 'the PRUNED line names %s, not a UTC time of the last 10 minutes\n' "$stamp" >&2
        return 1
    fi
}

# Print the calls, as the stand-ins log them, with which discard must record and remove the
# session folder DIR: sync on the PRUNED beside it, unlink on each file it holds, in the order of
# SEAL_FILES, then transcript.txt.part and transcript.txt, and rmdir on the folder. Call it
# before discard runs.
discard_calls() {
    local name
    printf 'sync\t%s\n' "$(readlink -f -- "${1%/*}/PRUNED")"
    for name in input.raw commands.tsv started exited stop-requested transcript.txt.part \
        transcript.txt timing output.raw recorder; do
        if [[ -e $1/$name || -L $1/$name ]]; then
            printf 'unlink\t%s\n' "$(readlink -f -- "$1/$name")"
        fi
    done
    printf 'rmdir\t%s\n' "$(readlink -f -- "$1")"
}

# Set the modification time of the session folder DIR and of every entry in it to the time T, in
# seconds since 1970. Their ctime, which discard also reads, becomes now.
set_mtimes() {
    find "$1" -exec touch -h -d "@$2" {} +
}

# Make discard's 10-minute rule see now as SECONDS from now (default 720, more than 10 minutes),
# through TLOGGER_NOW, which every later run of bin/tlogger in this test reads. Files made before
# then are that much older.
age_by() {
    TLOGGER_NOW=$(( $(date +%s) + ${1:-720} ))
    export TLOGGER_NOW
}

# Create the session ID in the log folder as a recording that ended leaves it but for the
# recorder file, which a terminal of an older version did not write. It is fresh until a test
# calls age_by. Sets SDIR to its folder.
unknown_session() {
    make_session "$1"
    rm -f -- "$SDIR/recorder"
}

# Run discard on the session ID with --confirm ID through the stand-ins, and fail unless it was
# refused with MESSAGE alone, exit 1, and HOME, PRUNED included, stayed as it was, byte for byte,
# mode for mode and time for time, with nothing removed.
assert_discard_refused() {
    local before
    before=$(tree_of "$HOME")
    run_watched discard "$1" --confirm "$1"
    assert_refused 1 "$2"
    [ "$(tree_of "$HOME")" = "$before" ]
    refute_removed
}

@test "discard --confirm removes an unsealed session, after showing it, and PRUNED records it" {
    need modes
    local want manifest keep_b keep_acme entries
    local -a lines
    make_session "$A" 3
    printf '2026-11-12T10:00:30Z\n' > "$SDIR/stop-requested"
    printf 'derived\n' > "$SDIR/transcript.txt"
    printf 'part\n' > "$SDIR/transcript.txt.part"
    chmod 600 "$SDIR/stop-requested" "$SDIR/transcript.txt" "$SDIR/transcript.txt.part"
    make_session "$B"
    run_tlogger seal "$B"
    [ "$status" -eq 0 ]
    mkdir -m 700 "$LOGS/acme"
    make_session "acme/$C"
    make_stand_ins
    manifest=$(sha_of "$LOGS/MANIFEST")
    keep_b=$(tree_of "$LOGS/$B")
    keep_acme=$(tree_of "$LOGS/acme")
    want=$(discard_calls "$LOGS/$A")
    run_watched discard "$A" --confirm "$A"
    [ "$status" -eq 0 ]
    [ "$stderr" = "$(done_msg "$A" "$SHOWN")" ]
    # A new PRUNED of mode 0600 holds the one line, also printed after the 6 lines.
    [ "$(stat -c %a "$LOGS/PRUNED")" = 600 ]
    mapfile -t lines < "$LOGS/PRUNED"
    [ "${#lines[@]}" -eq 1 ]
    assert_discard_line "${lines[0]}" "$A" unsealed
    [ "$output" = "$(show_lines "$A" "$SHOWN" unsealed 3)"$'\n'"${lines[0]}" ]
    # The line was flushed before the first removal; each file went by its own name, through
    # unlink on PATH, in the pinned order, then the folder through rmdir; rm never ran.
    [ "$(cat "$CALLS")" = "$want" ]
    refute_rm
    [[ ! -e $LOGS/$A && ! -L $LOGS/$A ]]
    # The MANIFEST, the other sessions and the log folder but for PRUNED stay as they were.
    [ "$(sha_of "$LOGS/MANIFEST")" = "$manifest" ]
    [ "$(tree_of "$LOGS/$B")" = "$keep_b" ]
    [ "$(tree_of "$LOGS/acme")" = "$keep_acme" ]
    [ "$(stat -c %a "$LOGS")" = 700 ]
    entries=$(find "$LOGS" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)
    [ "$entries" = "$(printf '%s\n' "$B" MANIFEST PRUNED acme | LC_ALL=C sort)" ]
    [ -z "$(ls -A "$TMPDIR")" ]
    # verify --all names the other sessions and nothing of the discarded one.
    run_tlogger verify --all
    grep -Fxq "$B  ok" <<< "$output"
    grep -Fxq "$C  unsealed" <<< "$output"
    [[ $output != *"$A"* && $stderr != *"$A"* ]]
}

@test "discard removes a session without a recorder file once 10 minutes old, never before" {
    need modes
    local want
    local -a lines
    unknown_session "$A"
    make_stand_ins
    # Fresh, as a terminal of an older version that writes no recorder file leaves it.
    assert_discard_refused "$A" "$(fresh_msg "$A")"
    # Set back an hour with touch -d, folder and all: their ctime still says now.
    set_mtimes "$SDIR" $(( $(date +%s) - 3600 ))
    assert_discard_refused "$A" "$(fresh_msg "$A")"
    # 12 minutes on, but one file written 5 minutes before then.
    age_by 720
    touch -d "@$(( TLOGGER_NOW - 300 ))" "$SDIR/output.raw"
    assert_discard_refused "$A" "$(fresh_msg "$A")"
    # Old files, but the folder changed 5 minutes before then, as when a file in it was removed.
    set_mtimes "$SDIR" $(( $(date +%s) - 3600 ))
    touch -d "@$(( TLOGGER_NOW - 300 ))" "$SDIR"
    assert_discard_refused "$A" "$(fresh_msg "$A")"
    [ ! -e "$LOGS/PRUNED" ]
    # More than 10 minutes old, folder and all, by mtime and ctime.
    set_mtimes "$SDIR" $(( $(date +%s) - 3600 ))
    age_by 720
    want=$(discard_calls "$SDIR")
    run_watched discard "$A" --confirm "$A"
    [ "$status" -eq 0 ]
    [ "$stderr" = "$(done_msg "$A" "$SHOWN")" ]
    mapfile -t lines < "$LOGS/PRUNED"
    [ "${#lines[@]}" -eq 1 ]
    assert_discard_line "${lines[0]}" "$A" unknown
    [ "$output" = "$(show_lines "$A" "$SHOWN" unknown)"$'\n'"${lines[0]}" ]
    [ "$(cat "$CALLS")" = "$want" ]
    [[ ! -e $LOGS/$A && ! -L $LOGS/$A ]]
}

@test "discard refuses a sealed session: SEAL, SHA256SUMS, a temp file of seal, a MANIFEST line" {
    need modes
    local name
    make_session "$A"
    run_tlogger seal "$A"
    [ "$status" -eq 0 ]
    make_session "$B"
    make_stand_ins
    assert_discard_refused "$A" "$(sealed_msg "$A")"
    # Changed after its seal: still sealed.
    chmod 600 "$LOGS/$A/timing"
    assert_discard_refused "$A" "$(sealed_msg "$A")"
    # Its SEAL and SHA256SUMS gone, its line in the MANIFEST stays.
    rm -f -- "$LOGS/$A/SEAL" "$LOGS/$A/SHA256SUMS"
    assert_discard_refused "$A" "$(sealed_msg "$A")"
    # An unsealed session that holds a file of a seal, whole or a temp file.
    for name in SEAL SHA256SUMS SEAL.part.Ab12Cd SHA256SUMS.part.Xy34Zw; do
        printf 'part\n' > "$LOGS/$B/$name"
        assert_discard_refused "$B" "$(sealed_msg "$B")"
        rm -f -- "$LOGS/$B/$name"
    done
    # A line for it in the MANIFEST beside it, though it never was sealed here.
    printf '%s  %s/SHA256SUMS\n' "$ZERO_SUM" "$B" >> "$LOGS/MANIFEST"
    assert_discard_refused "$B" "$(sealed_msg "$B")"
    [ ! -e "$LOGS/PRUNED" ]
}

@test "discard refuses a MANIFEST beside the session that is a symlink" {
    need modes
    need symlinks
    local want
    make_session "$A"
    mkdir -m 700 "$HOME/elsewhere"
    : > "$HOME/elsewhere/MANIFEST"
    ln -s "$HOME/elsewhere/MANIFEST" "$LOGS/MANIFEST"
    make_stand_ins
    want="tlogger: cannot read $SHOWN/MANIFEST, so discard cannot tell whether session $A is"
    assert_discard_refused "$A" "$want sealed"
    [ ! -s "$HOME/elsewhere/MANIFEST" ]
    [ ! -e "$LOGS/PRUNED" ]
}

@test "discard refuses a sealed session moved by hand, its SEAL and SHA256SUMS deleted" {
    need modes
    local before
    mkdir -m 700 "$LOGS/acme"
    make_session "acme/$A"
    run_tlogger seal "$A"
    [ "$status" -eq 0 ]
    mv -- "$LOGS/acme/$A" "$LOGS/$A"
    rm -f -- "$LOGS/$A/SEAL" "$LOGS/$A/SHA256SUMS"
    make_stand_ins
    # Its logs keep the mode 0400 that seal gave them.
    assert_discard_refused "$A" "$(mode400_msg "$A")"
    # Set back to 0600, only the line in the MANIFEST of acme, where it was sealed, shows it.
    chmod 600 "$LOGS/$A"/*
    assert_discard_refused "$A" "$(sealed_msg "$A")"
    # Named by its path in the log folder, it gets the same checks as by its id.
    before=$(tree_of "$HOME")
    run_watched discard "$LOGS/$A" --confirm "$A"
    assert_refused 1 "$(sealed_msg "$A")"
    [ "$(tree_of "$HOME")" = "$before" ]
    refute_removed
    [ ! -e "$LOGS/PRUNED" ]
    [ ! -e "$LOGS/acme/PRUNED" ]
}

@test "discard refuses a session that is still being recorded" {
    need modes
    make_session "$A"
    fake_process "$REC_PID" "$REC_START"
    make_stand_ins
    assert_discard_refused "$A" \
        "tlogger: session $A is still being recorded; discard refuses it"
    [ ! -e "$LOGS/PRUNED" ]
}

@test "discard refuses a session whose output.raw a script process writes, recorder file or not" {
    need modes
    local want
    make_session "$A"
    unknown_session "$B"
    make_stand_ins
    # Unsealed: its recorder file names a process that has gone, but another script process,
    # which a recorder file does not name, writes its output.raw.
    fake_script 5150 2000 "$LOGS/$A"
    assert_discard_refused "$A" "$(writer_msg "$A")"
    # Without a recorder file and 12 minutes old, it is still being written.
    fake_script 5151 2001 "$LOGS/$B"
    age_by 720
    assert_discard_refused "$B" "$(writer_msg "$B")"
    # Another spelling of the path to the same file counts as well.
    fake_script 5151 2001 "$LOGS/.//$B"
    assert_discard_refused "$B" "$(writer_msg "$B")"
    # Only an argument that names the file counts, not one that holds its path.
    fake_script 5150 2000 "$LOGS/$A" --log-out "$LOGS/$A/output.raw.old" \
        "--log-out=$LOGS/$A/output.raw"
    want=$(discard_calls "$LOGS/$A")
    run_watched discard "$A" --confirm "$A"
    [ "$status" -eq 0 ]
    [ "$stderr" = "$(done_msg "$A" "$SHOWN")" ]
    [ "$(cat "$CALLS")" = "$want" ]
    [[ ! -e $LOGS/$A && ! -L $LOGS/$A ]]
}

@test "discard refuses a session that a script process holds open, whatever its cmdline names" {
    need modes
    need symlinks
    local name
    make_session "$A"
    make_stand_ins
    # A script started with relative paths in the session folder, as its cmdline shows; one of
    # its fds holds a log open. timing or input.raw alone counts too, as for a session folder
    # moved by hand while it records.
    fake_process 5150 2000
    printf '%s\0' script --quiet --flush --log-timing timing --log-in input.raw \
        --log-out output.raw > "$PROC/5150/cmdline"
    mkdir "$PROC/5150/fd"
    ln -s /dev/null "$PROC/5150/fd/0"
    for name in output.raw timing input.raw; do
        ln -s "$SDIR/$name" "$PROC/5150/fd/3"
        assert_discard_refused "$A" "$(writer_msg "$A")"
        rm -f -- "$PROC/5150/fd/3"
    done
    # The same fd in a process of another name does not count.
    ln -s "$SDIR/output.raw" "$PROC/5150/fd/3"
    fake_other 5150 less less -R output.raw
    run_watched discard "$A" --confirm "$A"
    [ "$status" -eq 0 ]
    [ "$stderr" = "$(done_msg "$A" "$SHOWN")" ]
    [[ ! -e $SDIR && ! -L $SDIR ]]
}

@test "discard passes over a scriptreplay or a less of the session, which are no script process" {
    need modes
    local want
    make_session "$A"
    make_stand_ins
    fake_other 6100 scriptreplay scriptreplay --log-timing "$SDIR/timing" \
        --log-out "$SDIR/output.raw"
    fake_other 6101 less less -R "$SDIR/output.raw"
    want=$(discard_calls "$SDIR")
    run_watched discard "$A" --confirm "$A"
    [ "$status" -eq 0 ]
    [ "$stderr" = "$(done_msg "$A" "$SHOWN")" ]
    [ "$(cat "$CALLS")" = "$want" ]
    [[ ! -e $SDIR && ! -L $SDIR ]]
}

@test "discard waits for a lock that another command holds on the folder, then changes nothing" {
    need modes
    need command flock
    local before want start
    make_session "$A"
    make_stand_ins
    hold_lock "$SDIR"
    export TLOGGER_LOCK_WAIT=1
    before=$(tree_of "$HOME")
    start=$SECONDS
    run_watched discard "$A" --confirm "$A"
    [ "$status" -eq 1 ]
    (( SECONDS - start >= 1 ))
    [ "$output" = "$(show_lines "$A" "$SHOWN" unsealed)" ]
    want="tlogger: another tlogger command works on session $A; nothing of it was removed;"
    [ "$stderr" = "$want try again" ]
    [ "$(tree_of "$HOME")" = "$before" ]
    refute_removed
    # Once the lock is let go, discard removes the session.
    release_lock
    : > "$CALLS"
    want=$(discard_calls "$SDIR")
    run_watched discard "$A" --confirm "$A"
    [ "$status" -eq 0 ]
    [ "$(cat "$CALLS")" = "$want" ]
    [[ ! -e $SDIR && ! -L $SDIR ]]
}

@test "discard reads the clock for a TLOGGER_NOW of another form than 1 to 12 digits" {
    need modes
    local later value
    unknown_session "$A"
    make_stand_ins
    later=$(( $(date +%s) + 720 ))
    for value in "0$later" "$later " "+$later" "${later}000" "$later.5" '-1'; do
        export TLOGGER_NOW=$value
        assert_discard_refused "$A" "$(fresh_msg "$A")"
    done
    [ ! -e "$LOGS/PRUNED" ]
    # The same time in the form it takes: the session is old enough.
    export TLOGGER_NOW=$later
    run_watched discard "$A" --confirm "$A"
    [ "$status" -eq 0 ]
    [[ ! -e $SDIR && ! -L $SDIR ]]
}

@test "discard refuses a session folder open to group or others, or one you cannot change" {
    need modes
    local mode
    make_session "$A"
    make_stand_ins
    for mode in 770 707 1770; do
        chmod "$mode" "$SDIR"
        assert_discard_refused "$A" "$(open_msg "$A")"
    done
    for mode in 500 300; do
        chmod "$mode" "$SDIR"
        assert_discard_refused "$A" \
            "tlogger: session $A: its folder has mode $mode, so you cannot remove its files"
    done
    chmod 700 "$SDIR"
    [ ! -e "$LOGS/PRUNED" ]
}

@test "discard refuses a folder that holds the session open to group or others, sticky or not" {
    need modes
    make_session "$A"
    mkdir -m 700 "$LOGS/acme"
    make_session "acme/$B"
    make_stand_ins
    chmod 1770 "$LOGS"
    assert_discard_refused "$A" "$(open_parent_msg "$SHOWN")"
    chmod 700 "$LOGS"
    chmod 1770 "$LOGS/acme"
    assert_discard_refused "$B" "$(open_parent_msg "$SHOWN/acme")"
    # Named by its path, too.
    run_watched discard "$LOGS/acme/$B" --confirm "$B"
    assert_refused 1 "$(open_parent_msg "$SHOWN/acme")"
    chmod 700 "$LOGS/acme"
    refute_removed
    [ ! -e "$LOGS/PRUNED" ]
    [ ! -e "$LOGS/acme/PRUNED" ]
}

@test "discard refuses a folder you cannot write in, and a session named by id off its volume" {
    need modes
    local want
    make_session "$A"
    mkdir -m 700 "$LOGS/acme"
    make_session "acme/$B"
    make_stand_ins
    # Closed to yourself, as you may close it: its sessions still show and verify.
    chmod 500 "$LOGS/acme"
    want="tlogger: you cannot write in $SHOWN/acme, so discard cannot remove the folder of"
    assert_discard_refused "$B" "$want session $B"
    chmod 700 "$LOGS/acme"
    # logdir_mount names a volume that is not mounted: a session named by its id is refused, as
    # archive and prune refuse its folder, and so is one named by its path in the log folder or
    # in an engagement folder. A session elsewhere, named by its path, is shown.
    write_config "logdir_mount=$HOME/vault"$'\n'
    assert_discard_refused "$A" 'tlogger: the volume ~/vault of the log folder is not mounted'
    run_watched discard "$LOGS/$A" --confirm "$A"
    assert_refused 1 'tlogger: the volume ~/vault of the log folder is not mounted'
    run_watched discard "$LOGS/acme/$B" --confirm "$B"
    assert_refused 1 'tlogger: the volume ~/vault of the log folder is not mounted'
    mkdir -p "$HOME/cases"
    mkdir -m 700 "$HOME/cases/kept"
    make_session "$HOME/cases/kept/$C"
    run_watched discard "$HOME/cases/kept/$C" --confirm "$B"
    [ "$status" -eq 1 ]
    # shellcheck disable=SC2088 # The ~ is the text tlogger prints.
    [ "$output" = "$(show_lines "$C" '~/cases/kept' unsealed)" ]
    [ "$stderr" = 'tlogger: nothing changed' ]
    refute_removed
    [ ! -e "$LOGS/PRUNED" ]
}

@test "discard refuses a session folder whose name holds a space, which a PRUNED line cannot" {
    need modes
    local before want
    mkdir -p "$HOME/cases"
    mkdir -m 700 "$HOME/cases/kept"
    make_session "$HOME/cases/kept/old $A"
    make_stand_ins
    before=$(tree_of "$HOME")
    run_watched discard "$HOME/cases/kept/old $A" --confirm "old $A"
    want="tlogger: the name of ~/cases/kept/old $A holds a space or a control character, which"
    assert_refused 1 "$want a PRUNED line cannot hold; rename it"
    [ "$(tree_of "$HOME")" = "$before" ]
    refute_removed
}

@test "discard refuses a session folder that is a symlink, as resolve_session does" {
    need modes
    need symlinks
    make_session "$HOME/elsewhere/$A"
    chmod 700 "$HOME/elsewhere"
    ln -s "$HOME/elsewhere/$A" "$LOGS/$A"
    make_stand_ins
    assert_discard_refused "$A" "tlogger: $SHOWN/$A is a symlink, which tlogger does not follow"
    [ ! -e "$LOGS/PRUNED" ]
}

@test "discard refuses an entry that is no file of a session, dot files included" {
    need modes
    make_session "$A"
    make_stand_ins
    printf 'note\n' > "$SDIR/notes.txt"
    assert_discard_refused "$A" "$(foreign_msg "$A" notes.txt)"
    rm -f -- "$SDIR/notes.txt"
    printf 'note\n' > "$SDIR/.hidden"
    assert_discard_refused "$A" "$(foreign_msg "$A" .hidden)"
    rm -f -- "$SDIR/.hidden"
    mkdir -m 700 "$SDIR/notes"
    assert_discard_refused "$A" "$(foreign_msg "$A" notes)"
    rmdir "$SDIR/notes"
    [ ! -e "$LOGS/PRUNED" ]
}

@test "discard refuses an entry that is a symlink, a folder, a FIFO or a file with two links" {
    need modes
    need symlinks
    need hardlinks
    make_session "$A"
    mkdir -m 700 "$HOME/elsewhere"
    make_stand_ins
    # A symlink, whose target stays as it is.
    printf 'derived\n' > "$HOME/elsewhere/transcript.txt"
    ln -s "$HOME/elsewhere/transcript.txt" "$SDIR/transcript.txt"
    assert_discard_refused "$A" \
        "tlogger: session $A: transcript.txt is a symlink, which tlogger does not follow"
    rm -f -- "$SDIR/transcript.txt"
    rm -f -- "$SDIR/exited"
    mkdir -m 700 "$SDIR/exited"
    assert_discard_refused "$A" "tlogger: session $A: exited is not a regular file"
    rmdir "$SDIR/exited"
    mkfifo -m 600 "$SDIR/stop-requested"
    assert_discard_refused "$A" "tlogger: session $A: stop-requested is not a regular file"
    rm -f -- "$SDIR/stop-requested"
    # A second name for a log keeps its data on the disk, and could change behind discard.
    ln "$SDIR/commands.tsv" "$HOME/elsewhere/commands.tsv"
    assert_discard_refused "$A" "tlogger: session $A: commands.tsv has more than one hard link"
    [ "$(cat "$HOME/elsewhere/transcript.txt")" = derived ]
    [ ! -e "$LOGS/PRUNED" ]
}

@test "discard refuses a PRUNED that is a symlink, not a regular file or has two links" {
    need modes
    need symlinks
    need hardlinks
    make_session "$A"
    mkdir -m 700 "$HOME/elsewhere"
    make_stand_ins
    printf 'kept\n' > "$HOME/elsewhere/PRUNED"
    ln -s "$HOME/elsewhere/PRUNED" "$LOGS/PRUNED"
    assert_discard_refused "$A" \
        "tlogger: $SHOWN/PRUNED is a symlink, which tlogger does not follow"
    [ "$(cat "$HOME/elsewhere/PRUNED")" = kept ]
    rm -f -- "$LOGS/PRUNED"
    mkdir -m 700 "$LOGS/PRUNED"
    assert_discard_refused "$A" "tlogger: $SHOWN/PRUNED is not a regular file"
    [ -z "$(ls -A "$LOGS/PRUNED")" ]
    rmdir "$LOGS/PRUNED"
    # A second name for PRUNED, which could change behind discard.
    : > "$LOGS/PRUNED"
    chmod 600 "$LOGS/PRUNED"
    ln "$LOGS/PRUNED" "$HOME/elsewhere/PRUNED.copy"
    assert_discard_refused "$A" "tlogger: $SHOWN/PRUNED has more than one hard link"
    [ ! -s "$LOGS/PRUNED" ]
}

@test "discard names the first refusal in the order of its checks" {
    need modes
    need symlinks
    make_session "$A"
    fake_process "$REC_PID" "$REC_START"
    unknown_session "$B"
    make_stand_ins
    # Recorded, holding a SEAL and a stray file, in a folder that others may write in, in a log
    # folder that its group may write in.
    printf 'part\n' > "$LOGS/$A/SEAL"
    printf 'note\n' > "$LOGS/$A/notes.txt"
    ln -s "$HOME/nowhere" "$LOGS/PRUNED"
    chmod 770 "$LOGS/$A"
    chmod 1770 "$LOGS"
    assert_discard_refused "$A" "$(open_parent_msg "$SHOWN")"
    chmod 700 "$LOGS"
    assert_discard_refused "$A" "$(open_msg "$A")"
    chmod 700 "$LOGS/$A"
    assert_discard_refused "$A" "$(sealed_msg "$A")"
    rm -f -- "$LOGS/$A/SEAL"
    assert_discard_refused "$A" "tlogger: session $A is still being recorded; discard refuses it"
    # Without a recorder file and fresh, holding a stray file.
    printf 'note\n' > "$LOGS/$B/notes.txt"
    assert_discard_refused "$B" "$(fresh_msg "$B")"
    # Old, the stray file comes before PRUNED.
    age_by 720
    assert_discard_refused "$B" "$(foreign_msg "$B" notes.txt)"
    rm -f -- "$LOGS/$B/notes.txt"
    age_by 720
    assert_discard_refused "$B" \
        "tlogger: $SHOWN/PRUNED is a symlink, which tlogger does not follow"
}

@test "discard needs --confirm off a terminal, before it reads anything" {
    local before
    before=$(tree_of "$HOME")
    run_tlogger discard "$A"
    assert_refused 2 'tlogger: --confirm is required with discard when not run from a terminal'
    run_tlogger discard "$HOME/cases/$A"
    assert_refused 2 'tlogger: --confirm is required with discard when not run from a terminal'
    [ "$(tree_of "$HOME")" = "$before" ]
    # Not even the config is read: a log folder that does not exist is never found missing.
    write_config "logdir=$HOME/gone"$'\n'
    before=$(tree_of "$HOME")
    run_tlogger discard "$A"
    assert_refused 2 'tlogger: --confirm is required with discard when not run from a terminal'
    [ "$(tree_of "$HOME")" = "$before" ]
}

@test "discard with a wrong --confirm shows the session and changes nothing" {
    need modes
    local before id
    make_session "$A"
    make_session "$B"
    make_stand_ins
    before=$(tree_of "$HOME")
    for id in "$B" "${A%?}" "$A " "${A,,}" "$SHOWN/$A" "$LOGS/$A"; do
        run_watched discard "$A" --confirm "$id"
        [ "$status" -eq 1 ]
        [ "$output" = "$(show_lines "$A" "$SHOWN" unsealed)" ]
        [ "$stderr" = 'tlogger: nothing changed' ]
    done
    run_watched discard "$A" --confirm="$B"
    [ "$status" -eq 1 ]
    [ "$stderr" = 'tlogger: nothing changed' ]
    [ "$(tree_of "$HOME")" = "$before" ]
    [ ! -e "$LOGS/PRUNED" ]
    refute_removed
}

@test "discard refuses wrong arguments with a usage error, and prints its help" {
    local value
    run_tlogger discard
    assert_usage_error 'tlogger: discard needs a session: its id or its path'
    run_tlogger discard --confirm "$A"
    assert_usage_error 'tlogger: discard needs a session: its id or its path'
    run_tlogger discard "$A" "$B" --confirm "$A"
    assert_usage_error 'tlogger: discard takes one session'
    for value in --force --all --delete -y; do
        run_tlogger discard "$A" --confirm "$A" "$value"
        assert_usage_error "tlogger: unknown option for discard: $value"
    done
    run_tlogger discard "$A" --confirm
    assert_usage_error "tlogger: --confirm needs a value: the session's id"
    [ -z "$(ls -A "$LOGS")" ]
    run_tlogger discard --help
    [ "$status" -eq 0 ]
    [[ $output == 'Usage: tlogger <command> [options]'* ]]
    run_tlogger discard -h
    [ "$status" -eq 0 ]
    [[ $output == 'Usage: tlogger <command> [options]'* ]]
}

@test "discard exits 3 without a log folder, and 1 for an id that names no session" {
    need modes
    make_session "$A"
    run_tlogger discard "$B" --confirm "$B"
    assert_refused 1 "tlogger: there is no session $B in $SHOWN"
    run_tlogger discard nosuch --confirm nosuch
    assert_refused 1 \
        "tlogger: 'nosuch' is not a session id; name a session folder elsewhere by a path with a /"
    write_config "logdir=$HOME/gone"$'\n'
    run_tlogger discard "$A" --confirm "$A"
    assert_refused 3 'tlogger: no sessions: the log folder ~/gone does not exist'
    [ ! -e "$HOME/gone" ]
    [ -d "$LOGS/$A" ]
}

@test "discard takes a session of an engagement or by its path, with PRUNED beside it" {
    need modes
    local old manifest keep_b want kept
    local -a lines
    # shellcheck disable=SC2088 # The ~ is the text tlogger prints.
    kept='~/cases/kept'
    mkdir -m 700 "$LOGS/acme"
    make_session "acme/$A"
    make_session "acme/$B"
    run_tlogger seal "$B"
    [ "$status" -eq 0 ]
    # A PRUNED whose last line has no line end.
    old="2026-11-12T12:00:00Z  $C  $ZERO_SUM  acme-20261112T120000Z.tar.gz  $ZERO_SUM"
    old+="  tlogger 0.2.0"
    printf '%s' "$old" > "$LOGS/acme/PRUNED"
    chmod 600 "$LOGS/acme/PRUNED"
    manifest=$(sha_of "$LOGS/acme/MANIFEST")
    keep_b=$(tree_of "$LOGS/acme/$B")
    make_stand_ins
    want=$(discard_calls "$LOGS/acme/$A")
    run_watched discard "$A" --confirm="$A"
    [ "$status" -eq 0 ]
    [ "$stderr" = "$(done_msg "$A" "$SHOWN/acme")" ]
    mapfile -t lines < "$LOGS/acme/PRUNED"
    [ "${#lines[@]}" -eq 2 ]
    [ "${lines[0]}" = "$old" ]
    assert_discard_line "${lines[1]}" "$A" unsealed
    [ "$(stat -c %a "$LOGS/acme/PRUNED")" = 600 ]
    [ "$output" = "$(show_lines "$A" "$SHOWN/acme" unsealed)"$'\n'"${lines[1]}" ]
    [ "$(cat "$CALLS")" = "$want" ]
    [[ ! -e $LOGS/acme/$A && ! -L $LOGS/acme/$A ]]
    [ ! -e "$LOGS/PRUNED" ]
    [ "$(sha_of "$LOGS/acme/MANIFEST")" = "$manifest" ]
    [ "$(tree_of "$LOGS/acme/$B")" = "$keep_b" ]
    # A session folder named by its path, outside the log folder.
    mkdir -p "$HOME/cases"
    mkdir -m 700 "$HOME/cases/kept"
    make_session "$HOME/cases/kept/$C"
    : > "$CALLS"
    want=$(discard_calls "$HOME/cases/kept/$C")
    run_watched discard "$HOME/cases/kept/$C" --confirm "$C"
    [ "$status" -eq 0 ]
    [ "$stderr" = "$(done_msg "$C" "$kept")" ]
    [ "$(stat -c %a "$HOME/cases/kept/PRUNED")" = 600 ]
    mapfile -t lines < "$HOME/cases/kept/PRUNED"
    [ "${#lines[@]}" -eq 1 ]
    assert_discard_line "${lines[0]}" "$C" unsealed
    [ "$output" = "$(show_lines "$C" "$kept" unsealed)"$'\n'"${lines[0]}" ]
    [ "$(cat "$CALLS")" = "$want" ]
    [ "$(ls -A "$HOME/cases/kept")" = PRUNED ]
    refute_rm
}

@test "a removal that fails leaves the PRUNED line, and discard run again finishes it" {
    need modes
    local want first
    local -a lines
    make_session "$A"
    printf 'derived\n' > "$SDIR/transcript.txt"
    make_stand_ins
    # input.raw, the first to go, cannot be removed, as if it were immutable.
    UNLINK_FAIL=$(readlink -f -- "$SDIR/input.raw")
    run_watched discard "$A" --confirm "$A"
    [ "$status" -eq 1 ]
    want="tlogger: cannot remove $SHOWN/$A/input.raw; session $A is discarded only in part; run"
    [ "$(last_stderr_line)" = "$want discard again once that is fixed" ]
    # The line was written, flushed and printed before the removal was tried.
    mapfile -t lines < "$LOGS/PRUNED"
    [ "${#lines[@]}" -eq 1 ]
    assert_discard_line "${lines[0]}" "$A" unsealed
    first=${lines[0]}
    [ "$output" = "$(show_lines "$A" "$SHOWN" unsealed)"$'\n'"$first" ]
    [ "$(cat "$CALLS")" = "$(printf 'sync\t%s\nunlink\t%s\n' \
        "$(readlink -f -- "$LOGS/PRUNED")" "$UNLINK_FAIL")" ]
    [ -f "$SDIR/input.raw" ]
    [ -f "$SDIR/transcript.txt" ]
    refute_rm
    # Run again, it is a first run on what is left, with a line of its own.
    UNLINK_FAIL=
    : > "$CALLS"
    want=$(discard_calls "$SDIR")
    run_watched discard "$A" --confirm "$A"
    [ "$status" -eq 0 ]
    [ "$stderr" = "$(done_msg "$A" "$SHOWN")" ]
    mapfile -t lines < "$LOGS/PRUNED"
    [ "${#lines[@]}" -eq 2 ]
    [ "${lines[0]}" = "$first" ]
    assert_discard_line "${lines[1]}" "$A" unsealed
    [ "$output" = "$(show_lines "$A" "$SHOWN" unsealed)"$'\n'"${lines[1]}" ]
    [ "$(cat "$CALLS")" = "$want" ]
    [[ ! -e $LOGS/$A && ! -L $LOGS/$A ]]
    refute_rm
}

@test "a removal cut once timing is gone says to remove the rest by hand" {
    need modes
    local want
    make_session "$A"
    make_stand_ins
    # output.raw cannot be removed; timing, before it, is gone by then.
    UNLINK_FAIL=$(readlink -f -- "$SDIR/output.raw")
    run_watched discard "$A" --confirm "$A"
    [ "$status" -eq 1 ]
    want="tlogger: cannot remove $SHOWN/$A/output.raw; session $A is discarded only in part, and"
    want+=" without its logs discard no longer finds it; remove what is left of $SHOWN/$A by hand"
    [ "$(last_stderr_line)" = "$want once that is fixed" ]
    [ -f "$SDIR/output.raw" ]
    [ -f "$SDIR/recorder" ]
    [[ ! -e $SDIR/timing ]]
    refute_rm
}

@test "an rmdir that fails, once every file is gone, says to remove the empty folder by hand" {
    need modes
    local want
    make_session "$A"
    make_stand_ins
    printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$STAND_INS/rmdir"
    run_watched discard "$A" --confirm "$A"
    [ "$status" -eq 1 ]
    want="tlogger: cannot remove $SHOWN/$A; its files are gone, and discard no longer finds it;"
    [ "$(last_stderr_line)" = "$want remove the empty folder by hand once that is fixed" ]
    [ -d "$SDIR" ]
    [ -z "$(ls -A "$SDIR")" ]
    [ "$(grep -c discarded "$LOGS/PRUNED")" -eq 1 ]
    refute_rm
}

@test "a PRUNED that cannot be written or flushed keeps the whole session" {
    need modes
    local keep want
    local -a lines
    make_session "$A"
    make_stand_ins
    keep=$(tree_of "$SDIR")
    # A PRUNED of mode 0400 cannot take the line.
    : > "$LOGS/PRUNED"
    chmod 400 "$LOGS/PRUNED"
    run_watched discard "$A" --confirm "$A"
    [ "$status" -eq 1 ]
    [ "$output" = "$(show_lines "$A" "$SHOWN" unsealed)" ]
    [ "$(last_stderr_line)" = \
        "tlogger: cannot write $SHOWN/PRUNED; nothing of session $A was removed" ]
    [ ! -s "$LOGS/PRUNED" ]
    [ "$(tree_of "$SDIR")" = "$keep" ]
    refute_removed
    # A line that sync cannot flush stays, and nothing of the session goes.
    chmod 600 "$LOGS/PRUNED"
    SYNC_FAIL=1
    run_watched discard "$A" --confirm "$A"
    [ "$status" -eq 1 ]
    want="tlogger: cannot flush $SHOWN/PRUNED to the disk; it holds the line of session $A, but"
    [ "$(last_stderr_line)" = "$want nothing of it was removed; run discard again" ]
    mapfile -t lines < "$LOGS/PRUNED"
    [ "${#lines[@]}" -eq 1 ]
    assert_discard_line "${lines[0]}" "$A" unsealed
    [ "$(tree_of "$SDIR")" = "$keep" ]
    refute_removed
}

@test "a discarded line never makes verify --all call a sealed session of that id pruned" {
    need modes
    make_session "$A"
    make_stand_ins
    run_watched discard "$A" --confirm "$A"
    [ "$status" -eq 0 ]
    grep -q "  $A  -  -  -  discarded unsealed by tlogger " "$LOGS/PRUNED"
    # A session sealed later under the same id: ok, then changed with no hint of a prune cut
    # short, then gone, which is missing, not pruned.
    make_session "$A"
    run_tlogger seal "$A"
    [ "$status" -eq 0 ]
    run_tlogger verify --all
    [ "$status" -eq 0 ]
    [ "$output" = "$A  ok" ]
    chmod 600 "$LOGS/$A/timing"
    run_tlogger verify --all
    [ "$status" -eq 1 ]
    [ "$output" = "$A  changed" ]
    [[ $stderr != *'a prune was cut short'* ]]
    rm -f -- "$LOGS/$A"/*
    rmdir -- "$LOGS/$A"
    run_tlogger verify --all
    [ "$status" -eq 1 ]
    [ "$output" = "$A  missing" ]
}

@test "on a terminal, discard asks for the session's id, and only that id removes it" {
    need modes
    need zsh
    need zpty
    local before
    local -a lines
    make_session "$A"
    make_session "$B"
    cp "$REPO_ROOT/tests/fixtures/e2e-zshrc" "$HOME/.zshrc"
    export TLOGGER LOGS ID=$A OTHER=$B DIR=$LOGS/$A
    # shellcheck disable=SC2034 # drive reads it.
    SCREEN="$BATS_TEST_TMPDIR/screen"
    before=$(tree_of "$LOGS")
    # zsh expands these, not bash.
    # shellcheck disable=SC2016
    drive << 'DRIVER'
pty_shell "TLOGGER=$TLOGGER" "TLOGGER_PROC=$TLOGGER_PROC" "TMPDIR=$TMPDIR" "S=$ID"
pty_begin 'bash "$TLOGGER" discard "$S"'
frame=$REPLY
pty_expect "tlogger: this cannot be undone; type the session's id, $ID, to go ahead: "
pty_send "$OTHER"
pty_end $frame
(( PTY_STATUS == 1 )) || pty_fail "a wrong id made discard return $PTY_STATUS"
pty_out_has "session $ID" || pty_fail "discard did not show the session: ${(V)PTY_OUT}"
pty_out_has 'state unsealed' || pty_fail "discard did not show the state: ${(V)PTY_OUT}"
pty_out_has 'tlogger: nothing changed' || pty_fail "a wrong id printed ${(V)PTY_OUT}"
pty_close
DRIVER
    [ "$(tree_of "$LOGS")" = "$before" ]
    # shellcheck disable=SC2016
    drive << 'DRIVER'
pty_shell "TLOGGER=$TLOGGER" "TLOGGER_PROC=$TLOGGER_PROC" "TMPDIR=$TMPDIR" "S=$ID"
# A file that comes while the question waits is found by the second check.
pty_begin 'bash "$TLOGGER" discard "$S"'
frame=$REPLY
pty_expect "tlogger: this cannot be undone; type the session's id, $ID, to go ahead: "
print -r -- note > $DIR/notes.txt
pty_send "$ID"
pty_end $frame
(( PTY_STATUS == 1 )) || pty_fail "a change made in time made discard return $PTY_STATUS"
pty_out_has "tlogger: session $ID holds notes.txt, which is no file of a session" ||
    pty_fail "a change made in time printed ${(V)PTY_OUT}"
[[ ! -e $LOGS/PRUNED && -f $DIR/output.raw ]] || pty_fail 'a change made in time removed files'
rm -f -- $DIR/notes.txt
# So is a SEAL.
pty_begin 'bash "$TLOGGER" discard "$S"'
frame=$REPLY
pty_expect "tlogger: this cannot be undone; type the session's id, $ID, to go ahead: "
print -r -- part > $DIR/SEAL
pty_send "$ID"
pty_end $frame
(( PTY_STATUS == 1 )) || pty_fail "a SEAL made in time made discard return $PTY_STATUS"
pty_out_has "tlogger: session $ID is sealed; tlogger archive and tlogger prune remove sealed" ||
    pty_fail "a SEAL made in time printed ${(V)PTY_OUT}"
[[ ! -e $LOGS/PRUNED && -f $DIR/output.raw ]] || pty_fail 'a SEAL made in time removed files'
rm -f -- $DIR/SEAL
pty_begin 'bash "$TLOGGER" discard "$S"'
frame=$REPLY
pty_expect "tlogger: this cannot be undone; type the session's id, $ID, to go ahead: "
pty_send "$ID"
pty_end $frame
(( PTY_STATUS == 0 )) || pty_fail "the right id made discard return $PTY_STATUS"
pty_out_has "tlogger: discarded session $ID; ~/.local/state/tlogger/sessions/PRUNED records it." ||
    pty_fail "the right id printed ${(V)PTY_OUT}"
pty_close
DRIVER
    [[ ! -e $LOGS/$A && ! -L $LOGS/$A ]]
    [ -d "$LOGS/$B" ]
    mapfile -t lines < "$LOGS/PRUNED"
    [ "${#lines[@]}" -eq 1 ]
    assert_discard_line "${lines[0]}" "$A" unsealed
}
