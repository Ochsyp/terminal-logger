#!/usr/bin/env bats
# Tests for the folder check of the session commands in bin/tlogger: list, seal, verify, render,
# show and replay refuse a log folder, an engagement folder, or the folder that holds a session
# named by its path, when it is a symlink, another user's, or writable by its group or by others
# without the sticky bit, as a recording refuses it. They do not need write permission, so a
# folder closed to 0500 still lists and verifies. Run as a subprocess in the test's own HOME on
# synthetic sessions, with a fake /proc, which TLOGGER_PROC names, so that no session counts as
# still recorded.
#
# The messages, with the folder shown as ~ where it lies under HOME:
# - '<what> <folder> is a symlink, which tlogger does not follow'
# - '<what> <folder> belongs to another user'
# - '<what> <folder> is writable by its group or by others; chmod go-w <folder> fixes it'
# where <what> is 'the log folder', 'the engagement folder' or, for the folder that holds a
# session named by its path, 'the folder'.

bats_require_minimum_version 1.5.0

load helpers

# The boot id of the fake /proc, and the recorder that each synthetic session names.
BOOT=0b1e7c5a-4d2f-4c3b-9a8e-7f6d5c4b3a21

# The log folder as tlogger shows it.
# shellcheck disable=SC2088 # The ~ is the text tlogger prints, not a path to expand.
SHOWN='~/.local/state/tlogger/sessions'

# Run before each test by bats.
# Gives the test its own HOME with the default layout, a log folder of mode 0700, a fake /proc
# with a boot id and no process, and two session ids.
setup() {
    isolate_home
    isolate_tlogger
    need modes
    LOGS="$HOME/.local/state/tlogger/sessions"
    mkdir -p "$LOGS"
    chmod 700 "$LOGS"
    PROC="$BATS_TEST_TMPDIR/proc"
    mkdir -p "$PROC/sys/kernel/random"
    printf '%s\n' "$BOOT" > "$PROC/sys/kernel/random/boot_id"
    export TLOGGER_PROC="$PROC"
    A=20261112T100000Z-aaaaaa
    B=20261112T110000Z-bbbbbb
}

# Run after each test by bats.
# Gives every folder under HOME back to its owner's write, so that bats can remove a folder that
# a test closed.
teardown() {
    if [[ -d $HOME ]]; then
        find "$HOME" -type d -exec chmod u+rwx {} + 2> /dev/null || true
    fi
}

# Create the ended session folder DIR, as a recording that ended with exit leaves it: the logs
# with some output, a journal of one command, and the recorder, started and exited markers.
make_session() {
    session_new "$1"
    session_out 'kali@kali:~$ ls\r\nfile\r\n'
    session_in 'ls\r'
    printf 'S\t1794391200\t2026-11-12T10:00:00Z\t4300\t/srv/work\t-\tls\n' >> "$SDIR/commands.tsv"
    printf 'E\t1794391201\t4300\t0\n' >> "$SDIR/commands.tsv"
    session_end
    printf '4242 1000 %s 34817\n' "$BOOT" > "$SDIR/recorder"
    printf '2026-11-12T10:00:00Z\n' > "$SDIR/started"
    printf '2026-11-12T10:01:00Z\n' > "$SDIR/exited"
    chmod 600 "$SDIR/recorder" "$SDIR/started" "$SDIR/exited"
}

# Print the refusal of the folder FOLDER, as shown, called WHAT, that its group or others may
# write in.
open_msg() {
    printf 'tlogger: %s %s is writable by its group or by others; chmod go-w %s fixes it' \
        "$1" "$2" "$2"
}

# Fail unless the last run exited 1, printed nothing on stdout and printed MESSAGE alone on
# stderr, with no home path in full.
assert_refused() {
    if [[ $status -ne 1 || -n $output || $stderr != "$1" ]]; then
        printf 'expected status 1 and the message\n%s\ngot status %s and:\n%s\n%s\n' "$1" \
            "$status" "$output" "$stderr" >&2
        return 1
    fi
    refute_home_shown
}

# Fail unless every session command, run on the session SESSION (an id or a path) and on all
# sessions, exits 1 with MESSAGE alone on stderr and changes nothing in the log folder.
assert_every_command_refuses() {
    local session=$1 want=$2 before args
    before=$(find "$LOGS" -printf '%p %m %s\n' | LC_ALL=C sort)
    for args in list 'seal --all' 'verify --all' seal verify render show replay \
        "seal $session" "verify $session" "render $session" "show $session" \
        "replay $session"; do
        # shellcheck disable=SC2086 # Each row is the command and its arguments, split on spaces.
        run_tlogger $args
        if ! assert_refused "$want"; then
            printf 'for: tlogger %s\n' "$args" >&2
            return 1
        fi
    done
    [ "$(find "$LOGS" -printf '%p %m %s\n' | LC_ALL=C sort)" = "$before" ]
}

@test "a log folder that its group or others may write in is refused by every session command" {
    local mode
    make_session "$LOGS/$A"
    for mode in 770 720 702 2770; do
        chmod "$mode" "$LOGS"
        assert_every_command_refuses "$A" "$(open_msg 'the log folder' "$SHOWN")"
    done
}

@test "an engagement folder that its group or others may write in is refused, not skipped" {
    local eng="$SHOWN/acme"
    make_session "$LOGS/$A"
    mkdir -m 700 "$LOGS/acme"
    make_session "$LOGS/acme/$B"
    chmod 730 "$LOGS/acme"
    # Even a session directly in the log folder: an id is looked up in every engagement folder.
    assert_every_command_refuses "$A" "$(open_msg 'the engagement folder' "$eng")"
    # A folder made by hand gets the same check.
    chmod 700 "$LOGS/acme"
    mkdir "$LOGS/Case_2026.x"
    chmod 707 "$LOGS/Case_2026.x"
    run_tlogger list
    assert_refused "$(open_msg 'the engagement folder' "$SHOWN/Case_2026.x")"
}

@test "a symlink named like an engagement that leads to a folder is refused by every command" {
    need symlinks
    make_session "$LOGS/$A"
    make_session "$HOME/elsewhere/$B"
    ln -s "$HOME/elsewhere" "$LOGS/linked"
    assert_every_command_refuses "$A" \
        "tlogger: the engagement folder $SHOWN/linked is a symlink, which tlogger does not follow"
}

@test "a symlink named like an engagement that leads to a file or nowhere is no engagement folder" {
    need symlinks
    make_session "$LOGS/$A"
    : > "$HOME/notes"
    ln -s "$HOME/notes" "$LOGS/notes"
    ln -s "$HOME/gone" "$LOGS/gone"
    run_tlogger list
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [[ ${lines[1]} == "$A "* ]]
    run_tlogger seal --all
    [ "$status" -eq 0 ]
    run_tlogger verify --all
    [ "$status" -eq 0 ]
    [ "$output" = "$A  ok" ]
}

@test "the sticky bit lets a log folder and an engagement folder that others write in pass" {
    make_session "$LOGS/$A"
    mkdir -m 700 "$LOGS/acme"
    make_session "$LOGS/acme/$B"
    chmod 1777 "$LOGS"
    chmod 1770 "$LOGS/acme"
    run_tlogger seal --all
    [ "$status" -eq 0 ]
    [ "${#stderr_lines[@]}" -eq 2 ]
    run_tlogger verify --all
    [ "$status" -eq 0 ]
    [ "$output" = "$A  ok"$'\n'"$B  ok" ]
    run_tlogger list
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 3 ]
}

@test "a log folder and an engagement folder closed to 0500 still list and verify" {
    make_session "$LOGS/$A"
    mkdir -m 700 "$LOGS/acme"
    make_session "$LOGS/acme/$B"
    run_tlogger seal --all
    [ "$status" -eq 0 ]
    chmod 500 "$LOGS/acme" "$LOGS"
    run_tlogger list
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    [ "${#lines[@]}" -eq 3 ]
    [[ ${lines[1]} == "$A  sealed "* ]]
    [[ ${lines[2]} == "$B  sealed "* ]]
    run_tlogger verify --all
    [ "$status" -eq 0 ]
    [ "$output" = "$A  ok"$'\n'"$B  ok" ]
    run_tlogger verify "$B"
    [ "$status" -eq 0 ]
    [ "$output" = "$B  ok" ]
    run_tlogger verify "$LOGS/acme/$B"
    [ "$status" -eq 0 ]
    run_tlogger seal --all
    [ "$status" -eq 0 ]
}

@test "a session named by its path is refused when the folder that holds it is open to others" {
    local args
    mkdir -m 700 "$HOME/cases"
    make_session "$HOME/cases/$A"
    chmod 770 "$HOME/cases"
    for args in seal verify render show replay; do
        run_tlogger "$args" "$HOME/cases/$A"
        # shellcheck disable=SC2088 # The ~ is the text tlogger prints.
        assert_refused "$(open_msg 'the folder' '~/cases')"
    done
    [ ! -e "$HOME/cases/MANIFEST" ]
    [ ! -e "$HOME/cases/$A/SEAL" ]
    chmod 1770 "$HOME/cases"
    run_tlogger seal "$HOME/cases/$A"
    [ "$status" -eq 0 ]
    run_tlogger verify "$HOME/cases/$A"
    [ "$status" -eq 0 ]
    [ "$output" = "$A  ok" ]
}

@test "a session named by its path is refused when the folder that holds it is a symlink" {
    need symlinks
    local args
    mkdir -m 700 "$HOME/cases"
    make_session "$HOME/cases/$A"
    ln -s "$HOME/cases" "$HOME/link"
    for args in seal verify render show replay; do
        run_tlogger "$args" "$HOME/link/$A"
        assert_refused 'tlogger: the folder ~/link is a symlink, which tlogger does not follow'
    done
    [ ! -e "$HOME/cases/MANIFEST" ]
}

@test "a session named by its path is refused when the folder that holds it is another user's" {
    if (( EUID == 0 )); then
        skip "it needs a user other than root"
    fi
    if [[ ! -d /root || -O /root ]]; then
        skip "it needs /root, owned by another user"
    fi
    local args
    for args in seal verify render show replay; do
        run_tlogger "$args" "/root/$A"
        assert_refused 'tlogger: the folder /root belongs to another user'
    done
}
