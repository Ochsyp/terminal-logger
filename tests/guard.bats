#!/usr/bin/env bats
# Tests for how the plugin sees its terminal, over a fake /proc tree (tests/helpers/fakeproc.zsh
# in TLOGGER_PROC): REC on the terminal its recorder records, EXT under another script process,
# NOREC otherwise with the stale variables dropped, and the handshake and the exit of a recorded
# shell. They need a real zsh and run no recorder.

bats_require_minimum_version 1.5.0

load helpers

# What run_guard prints by default: the state, main or -, and TLOGGER_SESSION or unset.
# shellcheck disable=SC2016 # zsh expands it, not bash.
STATE_REPORT='print -r -- "$_tlogger_state ${${_tlogger_main:+main}:--} ${TLOGGER_SESSION-unset}"'

# A handshake test prints the state line, then TZ, its type and which TLOGGER_HS* are set.
# shellcheck disable=SC2016 # zsh expands it, not bash.
HS_REPORT="$STATE_REPORT"'
    print -r -- "TZ=${TZ-unset}/${(t)TZ} HS=${+TLOGGER_HS}${+TLOGGER_HS_TZSET}${+TLOGGER_HS_TZ}"'

# The processes of a shell that script 9000001, on pts/0 (34816), started on pts/1 (34817) for
# the session in TLOGGER_HS, with the command line that tlogger start gives it.
# shellcheck disable=SC2016 # zsh expands it, not bash.
HS_TREE='fake_proc 9000001 script 9000000 34816 5000
    fake_cmdline 9000001 /usr/bin/script --quiet --flush --return --logging-format advanced \
        --log-timing $TLOGGER_HS/timing --log-in $TLOGGER_HS/input.raw --log-out $TLOGGER_HS/output.raw
    fake_proc $$ zsh 9000001 34817 5001'

# Run before each test by bats.
# Gives the test its own HOME and an empty folder for the fake /proc tree.
setup() {
    isolate_home
    isolate_tlogger
    need zsh
    PROC="$BATS_TEST_TMPDIR/proc"
    SESSION="$BATS_TEST_TMPDIR/session"
    SESSIONS="$HOME/.local/state/tlogger/sessions"
    mkdir -p "$PROC"
}

# Run zsh -f -i -c through bats `run --separate-stderr` with TLOGGER_PROC set to the fake tree:
# load fakeproc.zsh, run the zsh code SETUP, which builds the tree, source the plugin from the work
# tree and run the zsh code REPORT, STATE_REPORT by default.
run_guard() {
    # zsh expands these, not bash.
    # shellcheck disable=SC2016
    run --separate-stderr zsh -f -i -c '
        TLOGGER_PROC=$1
        source $2 || exit 1
        eval $3 || exit 1
        source $4
        eval $5' zsh "$PROC" "$REPO_ROOT/tests/helpers/fakeproc.zsh" "$1" \
        "$REPO_ROOT/lib/tlogger.zsh" "${2:-$STATE_REPORT}" < /dev/null
}

# Create HS_DIR, a session folder as tlogger start hands it to the recorded shell: directly under
# the default logdir, named as tlogger names sessions, with an empty output.raw.
make_hs_session() {
    HS_DIR="$SESSIONS/20261104T101500Z-a1B2c3"
    mkdir -p "$HS_DIR"
    : > "$HS_DIR/output.raw"
}

# Run the handshake for the folder DIR, with TZ unset outside the recording, over the fake tree
# TREE (default HS_TREE), which must give this shell a script parent on its own terminal. Fails
# unless it refused with WHY, left EXT, since that script records the terminal and tlogger start
# must refuse there, and wrote no recorder file.
assert_handshake_refuses() {
    local dir=$1 why=$2 tree=${3:-$HS_TREE}
    TLOGGER_HS=$dir TLOGGER_HS_TZSET=0 TLOGGER_HS_TZ='' TZ=UTC0 run_guard "$tree"
    if [[ $status -ne 0 || $output != "EXT - unset" || -e $dir/recorder ||
        $stderr != "tlogger: warning: the recording handshake failed: $why" ]]; then
        printf 'expected the refusal: %s\ngot, with exit %s:\n%s\nstderr:\n%s\n' \
            "$why" "$status" "$output" "$stderr" >&2
        return 1
    fi
}

@test "a nested zsh on the terminal that the recorder records is REC, but not the main shell" {
    # The recorder 9000001 records pts/1 for the main shell 9000002, which started this zsh.
    # zsh expands these, not bash.
    # shellcheck disable=SC2016
    run_guard '
        fake_proc 9000001 script 9000000 34816 5000
        fake_proc 9000002 zsh 9000001 34817 5001
        fake_proc $$ zsh 9000002 34817 5002
        fake_session 9000001 5000 34817'
    [ "$status" -eq 0 ]
    [ "$output" = "REC - $SESSION" ]
    [ -z "$stderr" ]
    # Only the main shell's zshexit hook writes exited.
    [ ! -e "$SESSION/exited" ]
}

@test "a shell whose parent is the recorder, as after exec zsh, is REC and the main shell" {
    # exec keeps the pid, so a shell that exec started has the recorder as its parent.
    # zsh expands these, not bash.
    # shellcheck disable=SC2016
    run_guard '
        fake_proc 9000001 script 9000000 34816 5000
        fake_proc $$ zsh 9000001 34817 5001
        fake_session 9000001 5000 34817'
    [ "$status" -eq 0 ]
    [ "$output" = "REC main $SESSION" ]
    [ -z "$stderr" ]
    # Its zshexit hook wrote exited when the shell ended.
    [[ $(cat "$SESSION/exited") =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "a main shell that ends after a hangup, or after its recorder is gone, writes no exited" {
    # A hangup, as when the recorder dies, takes the terminal away: stat then shows tty_nr 0.
    # zsh expands these, not bash.
    # shellcheck disable=SC2016
    run_guard '
        fake_proc 9000001 script 9000000 34816 5000
        fake_proc $$ zsh 9000001 34817 5001
        fake_session 9000001 5000 34817' "$STATE_REPORT"'
        fake_proc $$ zsh 9000001 0 5001'
    [ "$status" -eq 0 ]
    [ "$output" = "REC main $SESSION" ]
    [ ! -e "$SESSION/exited" ]
    # Gone: init has become the parent, on the same terminal.
    # shellcheck disable=SC2016
    run_guard '
        fake_proc 9000001 script 9000000 34816 5000
        fake_proc $$ zsh 9000001 34817 5001
        fake_session 9000001 5000 34817' "$STATE_REPORT"'
        fake_proc $$ zsh 1 34817 5001'
    [ "$status" -eq 0 ]
    [ "$output" = "REC main $SESSION" ]
    [ ! -e "$SESSION/exited" ]
}

@test "a terminal opened from a recorded shell is NOREC and drops the inherited variables" {
    # A terminal emulator that the main shell 9000002 started runs this zsh on pts/2 (34818).
    # zsh expands these, not bash.
    # shellcheck disable=SC2016
    run_guard '
        fake_proc 9000001 script 9000000 34816 5000
        fake_proc 9000002 zsh 9000001 34817 5001
        fake_proc 9000003 qterminal 9000002 34817 5002
        fake_proc $$ zsh 9000003 34818 5003
        fake_session 9000001 5000 34817
        export TLOGGER_HS_TZSET=1 TLOGGER_HS_TZ=CET-1' "$STATE_REPORT"'
        print -r -- "${+TLOGGER_HS_TZSET}${+TLOGGER_HS_TZ}"'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "NOREC - unset" ]
    [ "${lines[1]}" = 00 ]
}

@test "a new terminal on a reused pts without a script ancestor is NOREC" {
    # The session names pts/1, which a terminal under init now has.
    # zsh expands these, not bash.
    # shellcheck disable=SC2016
    run_guard '
        fake_proc 1 systemd 0 0 1
        fake_proc 9000010 xterm 1 0 7000
        fake_proc $$ zsh 9000010 34817 7001
        fake_session 9000001 5000 34817'
    [ "$status" -eq 0 ]
    [ "$output" = "NOREC - unset" ]
}

@test "a script process of another recorder on this terminal makes it EXT" {
    # zsh expands these, not bash.
    # shellcheck disable=SC2016
    run_guard '
        fake_proc 9000020 script 9000019 34816 8000
        fake_proc $$ zsh 9000020 34819 8001'
    [ "$status" -eq 0 ]
    [ "$output" = "EXT - unset" ]
    # A TLOGGER_SESSION of tlogger's own, left from another recording, goes too.
    # shellcheck disable=SC2016
    run_guard '
        fake_proc 9000020 script 9000019 34816 8000
        fake_proc $$ zsh 9000020 34819 8001
        fake_session 9000001 5000 34819'
    [ "$status" -eq 0 ]
    [ "$output" = "EXT - unset" ]
}

@test "a recorder that is gone, whose pid is reused or that ran on another boot gives no REC" {
    # Gone: its shell now has init as its parent.
    # zsh expands these, not bash.
    # shellcheck disable=SC2016
    run_guard '
        fake_proc 1 systemd 0 0 1
        fake_proc $$ zsh 1 34817 5002
        fake_session 9000001 5000 34817'
    [ "$status" -eq 0 ]
    [ "$output" = "NOREC - unset" ]
    # Reused: pid 9000001 belongs to a process that started later.
    # shellcheck disable=SC2016
    run_guard '
        fake_proc 9000001 bash 9000000 34816 6000
        fake_proc $$ zsh 9000001 34817 6001
        fake_session 9000001 5000 34817'
    [ "$status" -eq 0 ]
    [ "$output" = "NOREC - unset" ]
    # Another boot: the recorder file does not count, so the script parent is another recorder.
    # shellcheck disable=SC2016
    run_guard '
        fake_proc 9000001 script 9000000 34816 5000
        fake_proc $$ zsh 9000001 34817 5001
        fake_session 9000001 5000 34817
        print -r -- "9000001 5000 1f2e3d4c-5b6a-4978-8695-a4b3c2d1e0f9 34817" > $FAKE_SESSION/recorder'
    [ "$status" -eq 0 ]
    [ "$output" = "EXT - unset" ]
}

@test "a comm that holds ') (' and digits is read between the first ( and the last )" {
    # Cut at the first ')', this comm would shift every field after it.
    # zsh expands these, not bash.
    # shellcheck disable=SC2016
    run_guard '
        fake_proc 9000001 script 9000000 34816 5000
        fake_proc 9000002 "z) S 1 1 1 0 (" 9000001 34817 5001
        fake_proc $$ zsh 9000002 34817 5002
        fake_session 9000001 5000 34817
        mkdir -p $TLOGGER_PROC/9000003
        print -r -- "9000003 (zsh) S x 1 1 34817" > $TLOGGER_PROC/9000003/stat' '
        _tlogger_stat 9000002 && print -r -- "${(j:|:)reply}"
        _tlogger_stat 9000003 || print -r -- rejected
        '"$STATE_REPORT"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "z) S 1 1 1 0 (|9000001|34817|5001" ]
    [ "${lines[1]}" = rejected ]
    [ "${lines[2]}" = "REC - $SESSION" ]
}

@test "the handshake restores TZ, writes recorder and started, exports TLOGGER_SESSION and says REC" {
    need modes
    make_hs_session
    TLOGGER_HS=$HS_DIR TLOGGER_HS_TZSET=1 TLOGGER_HS_TZ=CET-1 TZ=UTC0 run_guard "$HS_TREE" "$HS_REPORT"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "REC main $HS_DIR" ]
    [ "${lines[1]}" = "TZ=CET-1/scalar-export HS=000" ]
    [ "$stderr" = "tlogger: REC 20261104T101500Z-a1B2c3" ]
    [ "$(cat "$HS_DIR/recorder")" = "9000001 5000 $(cat "$PROC/sys/kernel/random/boot_id") 34817" ]
    [[ $(cat "$HS_DIR/started") =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
    [ "$(stat -c %a "$HS_DIR/recorder")" = 600 ]
    [ "$(stat -c %a "$HS_DIR/started")" = 600 ]
}

@test "a handshake under a parent that is not script warns, writes no marker and unsets TZ" {
    make_hs_session
    # zsh expands these, not bash.
    # shellcheck disable=SC2016
    TLOGGER_HS=$HS_DIR TLOGGER_HS_TZSET=0 TLOGGER_HS_TZ='' TZ=UTC0 run_guard '
        fake_proc 9000001 bash 9000000 34816 5000
        fake_cmdline 9000001 /usr/bin/script --log-out $TLOGGER_HS/output.raw
        fake_proc $$ zsh 9000001 34817 5001' "$HS_REPORT"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "NOREC - unset" ]
    [ "${lines[1]}" = "TZ=unset/ HS=000" ]
    [ "$stderr" = "tlogger: warning: the recording handshake failed: the parent process is not script" ]
    [ ! -e "$HS_DIR/recorder" ]
    [ ! -e "$HS_DIR/started" ]
}

@test "the handshake refuses a folder or a parent that does not belong to the session" {
    need symlinks
    local other="$HOME/elsewhere/20261104T101500Z-b2C3d4" other_tree
    make_hs_session
    mkdir -p "$other" "$SESSIONS/not-a-session" "$SESSIONS/20261104T101500Z-c3D4e5"
    : > "$other/output.raw"
    : > "$SESSIONS/not-a-session/output.raw"
    assert_handshake_refuses "$other" 'its folder does not lie directly under the log folder'
    assert_handshake_refuses "$SESSIONS/not-a-session" 'its folder name is not a session name'
    assert_handshake_refuses "$SESSIONS/20261104T101500Z-c3D4e5" 'its folder holds no output.raw'
    ln -s "$other" "$SESSIONS/20261104T101500Z-d4E5f6"
    assert_handshake_refuses "$SESSIONS/20261104T101500Z-d4E5f6" \
        "its folder is a symlink, not a folder or another user's"
    # zsh expands these, not bash.
    # shellcheck disable=SC2016
    other_tree='fake_proc 9000001 script 9000000 34816 5000
        fake_cmdline 9000001 /usr/bin/script --log-out /home/kali/other/output.raw
        fake_proc $$ zsh 9000001 34817 5001'
    assert_handshake_refuses "$HS_DIR" "the parent script does not write this session's output.raw" \
        "$other_tree"
    # zsh expands these, not bash.
    # shellcheck disable=SC2016
    assert_handshake_refuses "$HS_DIR" 'cannot read the boot id' "$HS_TREE"'
        rm $TLOGGER_PROC/sys/kernel/random/boot_id'
    printf '2026-11-04T10:15:00Z\n' > "$HS_DIR/started"
    assert_handshake_refuses "$HS_DIR" 'its session has started already'
}

@test "a shell that script starts gets its TZ back and drops TLOGGER_HS* when the plugin cannot load" {
    local release="$HOME/release"
    make_hs_session
    # A release without lib/config.zsh: the plugin warns and loads no further.
    mkdir -p "$release/lib"
    cp "$REPO_ROOT/lib/tlogger.zsh" "$release/lib/tlogger.zsh"
    # zsh expands these, not bash.
    # shellcheck disable=SC2016
    TLOGGER_HS=$HS_DIR TLOGGER_HS_TZSET=1 TLOGGER_HS_TZ=CET-1 TZ=UTC0 \
        run --separate-stderr zsh -f -i -c 'source $1
            print -r -- "TZ=${TZ-unset}/${(t)TZ} HS=${+TLOGGER_HS}${+TLOGGER_HS_TZSET}${+TLOGGER_HS_TZ}"' \
        zsh "$release/lib/tlogger.zsh" < /dev/null
    [ "$status" -eq 0 ]
    [ "$output" = "TZ=CET-1/scalar-export HS=000" ]
    [[ $stderr == "tlogger: warning: "*"/lib/config.zsh is missing or broken; tlogger cannot record"* ]]
    [ ! -e "$HS_DIR/started" ]
}
