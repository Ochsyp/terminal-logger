#!/usr/bin/env bats
# Tests for tlogger seal, verify and list in bin/tlogger, run as a subprocess in the test's own
# HOME on synthetic sessions. A fake /proc, which TLOGGER_PROC names, holds the boot id and the
# processes that the liveness check reads, so that a session counts as still recorded only when
# a test says so.

bats_require_minimum_version 1.5.0

load helpers

# A UTC time as SEAL writes it, as an extended regular expression.
UTC_RE='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'

# The boot id of the fake /proc, and the recorder that each synthetic session names.
BOOT=0b1e7c5a-4d2f-4c3b-9a8e-7f6d5c4b3a21
REC_PID=4242
REC_START=1000

# Run before each test by bats.
# Gives the test its own HOME with the default layout, an empty log folder and a fake /proc with
# a boot id and no process.
setup() {
    isolate_home
    isolate_tlogger
    need modes
    IFS= read -r VERSION_TEXT < "$REPO_ROOT/VERSION"
    LOGS="$HOME/.local/state/tlogger/sessions"
    mkdir -p "$LOGS"
    chmod 700 "$LOGS"
    PROC="$BATS_TEST_TMPDIR/proc"
    mkdir -p "$PROC/sys/kernel/random"
    printf '%s\n' "$BOOT" > "$PROC/sys/kernel/random/boot_id"
    export TLOGGER_PROC="$PROC"
}

# Create the ended session ID in the log folder, as a recording that ended with exit leaves it:
# the logs with some output, a journal of COMMANDS S and E lines (default 2), and the recorder,
# started and exited markers, each 0600.
make_session() {
    local id=$1 count=${2:-2} i
    session_new "$LOGS/$id"
    session_out 'kali@kali:~$ ls\r\nfile\r\n'
    session_in 'ls\r'
    for (( i = 0; i < count; i++ )); do
        printf 'S\t%s\t2026-11-12T10:00:%02dZ\t4300\t/srv/work\t-\tls\n' \
            $(( 1794391200 + i )) "$i" >> "$SDIR/commands.tsv"
        printf 'E\t%s\t4300\t0\n' $(( 1794391201 + i )) >> "$SDIR/commands.tsv"
    done
    session_end
    printf '%s %s %s 34817\n' "$REC_PID" "$REC_START" "$BOOT" > "$SDIR/recorder"
    printf '2026-11-12T10:00:00Z\n' > "$SDIR/started"
    printf '2026-11-12T10:01:00Z\n' > "$SDIR/exited"
    chmod 600 "$SDIR/recorder" "$SDIR/started" "$SDIR/exited"
}

# Make the fake /proc hold process PID with STARTTIME as field 22 of its stat, as Linux writes it.
fake_process() {
    mkdir -p "$PROC/$1"
    printf '%s (script) S 1 %s %s 34816 -1 4194560 100 0 0 0 0 0 0 0 20 0 1 0 %s 9887744 1024\n' \
        "$1" "$1" "$1" "$2" > "$PROC/$1/stat"
}

# Print the files of the session folder DIR with their modes, 'NAME MODE' per line, sorted.
modes_of() {
    find "$1" -mindepth 1 -printf '%f %m\n' | LC_ALL=C sort
}

# Fail unless the last run exited STATUS, printed nothing on stdout and printed MESSAGE alone on
# stderr, with no home path in full.
assert_refused() {
    if [[ $status -ne $1 || -n $output || $stderr != "$2" || $stderr == *"$HOME"* ]]; then
        printf 'expected status %s and the message\n%s\ngot status %s and:\n%s\n%s\n' "$1" "$2" \
            "$status" "$output" "$stderr" >&2
        return 1
    fi
}

# Fail unless the last run was a usage error: exit status 2, MESSAGE as the first line of stderr,
# then the usage.
assert_usage_error() {
    if [[ $status -ne 2 || -n $output || ${stderr%%$'\n'*} != "$1" ||
        $stderr != *$'\nUsage: tlogger <command> [options]\n'* ]]; then
        printf 'expected the usage error %s, got status %s and:\n%s\n%s\n' "$1" "$status" \
            "$output" "$stderr" >&2
        return 1
    fi
}

@test "seal writes SHA256SUMS, SEAL and a MANIFEST line, and makes every log 0400" {
    local id=20261112T100000Z-a1B2c3 dir sum f
    make_session "$id"
    dir="$LOGS/$id"
    run_tlogger seal "$id"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    sum=$(sha_of "$dir/SHA256SUMS")
    [ "$stderr" = "tlogger: sealed session $id; SHA-256 of its SHA256SUMS: $sum" ]
    # Every log and marker, in a fixed order, and nothing else.
    [ "$(cut -c67- "$dir/SHA256SUMS" | paste -s -d ' ' -)" = \
        'output.raw timing input.raw commands.tsv recorder started exited' ]
    (cd "$dir" && sha256sum --quiet -c SHA256SUMS)
    [ "$(sed -n 1p "$dir/SEAL")" = "tlogger $VERSION_TEXT" ]
    [[ $(sed -n 2p "$dir/SEAL") =~ ^sealed\ $UTC_RE$ ]]
    [ "$(sed -n 3p "$dir/SEAL")" = "sha256 $sum" ]
    [ "$(wc -l < "$dir/SEAL")" -eq 3 ]
    for f in output.raw timing input.raw commands.tsv recorder started exited SHA256SUMS SEAL; do
        [ "$(stat -c %a "$dir/$f")" = 400 ]
    done
    [ "$(stat -c %a "$dir")" = 700 ]
    [ "$(cat "$LOGS/MANIFEST")" = "$sum  $id/SHA256SUMS" ]
    [ "$(stat -c %a "$LOGS/MANIFEST")" = 600 ]
    (cd "$LOGS" && sha256sum --quiet -c MANIFEST)
}

@test "seal covers only the files a session holds, and leaves transcript.txt out" {
    local id=20261112T100000Z-a1B2c3 dir
    make_session "$id"
    dir="$LOGS/$id"
    rm "$dir/input.raw" "$dir/exited"
    printf 'derived\n' > "$dir/transcript.txt"
    printf '2026-11-12T10:00:30Z\n' > "$dir/stop-requested"
    run_tlogger seal "$id"
    [ "$status" -eq 0 ]
    [ "$(cut -c67- "$dir/SHA256SUMS" | paste -s -d ' ' -)" = \
        'output.raw timing commands.tsv recorder started stop-requested' ]
    # The transcript stays as render wrote it, writable, so that render can write it again.
    [ "$(stat -c %a "$dir/transcript.txt")" != 400 ]
}

@test "seal refuses a session that is still recorded, or one without a recorder file" {
    local id=20261112T100000Z-a1B2c3 before want
    make_session "$id"
    fake_process "$REC_PID" "$REC_START"
    before=$(modes_of "$LOGS/$id")
    run_tlogger seal "$id"
    want="tlogger: session $id is still being recorded; seal it once its recording has ended"
    assert_refused 1 "$want"
    [ "$(modes_of "$LOGS/$id")" = "$before" ]
    [ ! -e "$LOGS/MANIFEST" ]
    rm "$LOGS/$id/recorder"
    run_tlogger seal "$id"
    want="tlogger: session $id has no recorder file, so tlogger cannot tell whether it is still"
    assert_refused 1 "$want being recorded"
    [ ! -e "$LOGS/$id/SEAL" ]
}

@test "seal counts a recorder as gone when its pid runs another process or the machine rebooted" {
    local id=20261112T100000Z-a1B2c3
    # The same pid, started at another time: another process.
    make_session "$id"
    fake_process "$REC_PID" 9999
    run_tlogger seal "$id"
    [ "$status" -eq 0 ]
    [ -f "$LOGS/$id/SEAL" ]
    # The same pid and start, but another boot: the recorder of an earlier boot.
    id=20261112T110000Z-a1B2c3
    make_session "$id"
    fake_process "$REC_PID" "$REC_START"
    printf '%s\n' 11111111-2222-3333-4444-555555555555 > "$PROC/sys/kernel/random/boot_id"
    run_tlogger seal "$id"
    [ "$status" -eq 0 ]
    [ -f "$LOGS/$id/SEAL" ]
}

@test "seal refuses a session folder that holds another entry, a symlink or another kind of file" {
    local id=20261112T100000Z-a1B2c3 journal
    make_session "$id"
    journal="tlogger: ~/.local/state/tlogger/sessions/$id/commands.tsv"
    printf 'note\n' > "$LOGS/$id/notes.txt"
    run_tlogger seal "$id"
    assert_refused 1 "tlogger: session $id holds notes.txt, which no session holds; seal refuses it"
    rm "$LOGS/$id/notes.txt"
    mv "$LOGS/$id/commands.tsv" "$BATS_TEST_TMPDIR/journal"
    ln -s "$BATS_TEST_TMPDIR/journal" "$LOGS/$id/commands.tsv"
    run_tlogger seal "$id"
    assert_refused 1 "$journal is a symlink, which tlogger does not follow"
    rm "$LOGS/$id/commands.tsv"
    mkdir "$LOGS/$id/commands.tsv"
    run_tlogger seal "$id"
    assert_refused 1 "$journal is not a regular file"
    [ ! -e "$LOGS/$id/SEAL" ]
    [ ! -e "$LOGS/MANIFEST" ]
}

@test "sealing twice changes nothing; seal --all seals the ended sessions and skips a live one" {
    local a=20261112T100000Z-aaaaaa b=20261112T110000Z-bbbbbb c=20261112T120000Z-cccccc sums
    make_session "$a"
    run_tlogger seal "$a"
    [ "$status" -eq 0 ]
    sums=$(cat "$LOGS/$a/SHA256SUMS" "$LOGS/$a/SEAL" "$LOGS/MANIFEST")
    run_tlogger seal "$a"
    [ "$status" -eq 0 ]
    [ "$stderr" = "tlogger: session $a is sealed already" ]
    [ "$(cat "$LOGS/$a/SHA256SUMS" "$LOGS/$a/SEAL" "$LOGS/MANIFEST")" = "$sums" ]
    # b ended; c is still recorded, by the live recorder 4343.
    make_session "$b"
    make_session "$c"
    printf '4343 2000 %s 34818\n' "$BOOT" > "$LOGS/$c/recorder"
    fake_process 4343 2000
    run_tlogger seal --all
    [ "$status" -eq 0 ]
    sums=$(sha_of "$LOGS/$b/SHA256SUMS")
    [ "${stderr_lines[0]}" = "tlogger: sealed session $b; SHA-256 of its SHA256SUMS: $sums" ]
    [ "${stderr_lines[1]}" = "tlogger: session $c is still being recorded; not sealed" ]
    [ "${#stderr_lines[@]}" -eq 2 ]
    [ -f "$LOGS/$b/SEAL" ]
    [ ! -e "$LOGS/$c/SEAL" ]
    [ "$(wc -l < "$LOGS/MANIFEST")" -eq 2 ]
    [ "$(sed -n 2p "$LOGS/MANIFEST")" = "$(sha_of "$LOGS/$b/SHA256SUMS")  $b/SHA256SUMS" ]
}

@test "a seal whose MANIFEST line could not be written gets it from the next seal" {
    local id=20261112T100000Z-a1B2c3 sum want
    make_session "$id"
    : > "$LOGS/MANIFEST"
    chmod 400 "$LOGS/MANIFEST"
    run_tlogger seal "$id"
    want="tlogger: session $id is sealed, but cannot write its line in"
    want+=" ~/.local/state/tlogger/sessions/MANIFEST; tlogger seal $id adds it once that is fixed"
    assert_refused 1 "$want"
    [ -f "$LOGS/$id/SEAL" ]
    run_tlogger verify "$id"
    [ "$status" -eq 1 ]
    chmod 600 "$LOGS/MANIFEST"
    run_tlogger seal "$id"
    [ "$status" -eq 0 ]
    sum=$(sha_of "$LOGS/$id/SHA256SUMS")
    want="tlogger: session $id is sealed already, and its MANIFEST line is added now;"
    [ "$stderr" = "$want SHA-256 of its SHA256SUMS: $sum" ]
    [ "$(cat "$LOGS/MANIFEST")" = "$sum  $id/SHA256SUMS" ]
    run_tlogger verify "$id"
    [ "$status" -eq 0 ]
    # A seal temp file that a killed run left behind counts as seal's own, not as a change.
    printf 'x\n' > "$LOGS/$id/SHA256SUMS.part.Ab12Cd"
    run_tlogger verify "$id"
    [ "$status" -eq 0 ]
}

@test "verify prints ok for an untouched seal, and changed for a byte, a mode or a file" {
    local s
    for s in aaaaaa bbbbbb cccccc dddddd eeeeee; do
        make_session "20261112T100000Z-$s"
    done
    run_tlogger seal --all
    [ "$status" -eq 0 ]
    run_tlogger verify 20261112T100000Z-aaaaaa
    [ "$status" -eq 0 ]
    [ "$output" = '20261112T100000Z-aaaaaa  ok' ]
    [ -z "$stderr" ]
    # b: a byte added to output.raw.
    chmod 600 "$LOGS/20261112T100000Z-bbbbbb/output.raw"
    printf 'x' >> "$LOGS/20261112T100000Z-bbbbbb/output.raw"
    chmod 400 "$LOGS/20261112T100000Z-bbbbbb/output.raw"
    run_tlogger verify 20261112T100000Z-bbbbbb
    [ "$status" -eq 1 ]
    [ "$output" = '20261112T100000Z-bbbbbb  changed' ]
    [ "$stderr" = 'tlogger: 20261112T100000Z-bbbbbb: output.raw changed' ]
    # c: a file made writable again.
    chmod 600 "$LOGS/20261112T100000Z-cccccc/timing"
    run_tlogger verify 20261112T100000Z-cccccc
    [ "$status" -eq 1 ]
    [ "$stderr" = 'tlogger: 20261112T100000Z-cccccc: timing has mode 600, not 400' ]
    # d: a file gone and another added.
    rm -f "$LOGS/20261112T100000Z-dddddd/input.raw"
    printf 'later\n' > "$LOGS/20261112T100000Z-dddddd/later.txt"
    run_tlogger verify 20261112T100000Z-dddddd
    [ "$status" -eq 1 ]
    [ "${stderr_lines[0]}" = 'tlogger: 20261112T100000Z-dddddd: input.raw is missing' ]
    [ "${stderr_lines[1]}" = \
        'tlogger: 20261112T100000Z-dddddd: later.txt is not covered by the seal' ]
    # A transcript is derived, and never counts.
    printf 'derived\n' > "$LOGS/20261112T100000Z-aaaaaa/transcript.txt"
    run_tlogger verify 20261112T100000Z-aaaaaa
    [ "$status" -eq 0 ]
}

@test "verify catches SHA256SUMS rewritten to match a change, by SEAL and by the MANIFEST" {
    local id=20261112T100000Z-a1B2c3 dir sum
    make_session "$id"
    dir="$LOGS/$id"
    run_tlogger seal "$id"
    [ "$status" -eq 0 ]
    # Change a log and write its sums again, as someone hiding the change would.
    chmod 600 "$dir/commands.tsv" "$dir/SHA256SUMS"
    printf 'S\t1794391300\t2026-11-12T10:01:40Z\t4300\t/srv/work\t-\tid\n' >> "$dir/commands.tsv"
    (cd "$dir" && sha256sum output.raw timing input.raw commands.tsv recorder started exited) \
        > "$dir/SHA256SUMS"
    chmod 400 "$dir/commands.tsv" "$dir/SHA256SUMS"
    run_tlogger verify "$id"
    [ "$status" -eq 1 ]
    [ "$stderr" = "tlogger: $id: SHA256SUMS does not match its SEAL" ]
    # And SEAL rewritten to match: the MANIFEST still holds the sum of the first seal.
    sum=$(sha_of "$dir/SHA256SUMS")
    chmod 600 "$dir/SEAL"
    sed -i "3s/.*/sha256 $sum/" "$dir/SEAL"
    chmod 400 "$dir/SEAL"
    run_tlogger verify "$id"
    [ "$status" -eq 1 ]
    [ "$stderr" = "tlogger: $id: SHA256SUMS does not match its line in the MANIFEST" ]
    # Without its MANIFEST line, the seal cannot be checked against a copy.
    rm "$LOGS/MANIFEST"
    run_tlogger verify "$id"
    [ "$status" -eq 1 ]
    [ "$stderr" = "tlogger: $id: no line in the MANIFEST names this session" ]
}

@test "verify --all names every session, and exits 4 when a finished session is unsealed" {
    local a=20261112T100000Z-aaaaaa b=20261112T110000Z-bbbbbb c=20261112T120000Z-cccccc
    make_session "$a"
    run_tlogger seal "$a"
    make_session "$b"
    make_session "$c"
    fake_process "$REC_PID" "$REC_START"
    # b and c name the same live recorder; b's own recorder line names another, gone one.
    chmod 600 "$LOGS/$b/recorder"
    printf '4343 2000 %s 34818\n' "$BOOT" > "$LOGS/$b/recorder"
    run_tlogger verify --all
    [ "$status" -eq 4 ]
    [ "$output" = "$a  ok"$'\n'"$b  unsealed"$'\n'"$c  recording" ]
    [ "$stderr" = "tlogger: 1 finished session is not sealed; tlogger seal --all seals it" ]
    # A session that is still recorded does not count against the result.
    run_tlogger seal "$b"
    run_tlogger verify --all
    [ "$status" -eq 0 ]
}

@test "list shows each session's state, start, duration, commands and transcript" {
    local a=20261112T100000Z-aaaaaa b=20261112T110000Z-bbbbbb c=20261112T120000Z-cccccc
    local d=20261112T130000Z-dddddd e=20261112T140000Z-eeeeee row='%-23s  %-9s  %-20s  %8s  %8s  %s'
    # a: sealed, with a transcript. b: ended. c: still recorded by the live recorder 4242.
    # d: sealed, then a log made writable. e: no recorder file.
    make_session "$a" 3
    run_tlogger seal "$a"
    printf 'derived\n' > "$LOGS/$a/transcript.txt"
    make_session "$b" 1
    make_session "$c" 0
    make_session "$d"
    run_tlogger seal "$d"
    chmod 600 "$LOGS/$d/timing"
    make_session "$e"
    rm "$LOGS/$e/recorder"
    fake_process "$REC_PID" "$REC_START"
    printf '4343 2000 %s 34818\n' "$BOOT" > "$LOGS/$b/recorder"
    printf 'not a session\n' > "$LOGS/notes.txt"
    run_tlogger list
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    # shellcheck disable=SC2059 # The row format is the test's own.
    [ "$output" = "$(printf "$row\n" SESSION STATE 'START (UTC)' DURATION COMMANDS TRANSCRIPT \
        "$a" sealed 2026-11-12T10:00:00Z 00:01:00 3 yes \
        "$b" ended 2026-11-12T11:00:00Z 00:01:00 1 no \
        "$c" recording 2026-11-12T12:00:00Z 00:01:00 0 no \
        "$d" changed 2026-11-12T13:00:00Z 00:01:00 2 no \
        "$e" unknown 2026-11-12T14:00:00Z 00:01:00 2 no)" ]
}

@test "list, verify and seal exit 3 without sessions, and refuse wrong arguments" {
    run_tlogger list
    assert_refused 3 'tlogger: no sessions in ~/.local/state/tlogger/sessions'
    run_tlogger verify --all
    assert_refused 3 'tlogger: no sessions in ~/.local/state/tlogger/sessions'
    run_tlogger seal --all
    assert_refused 3 'tlogger: no sessions in ~/.local/state/tlogger/sessions'
    run_tlogger seal --force
    assert_usage_error 'tlogger: unknown option for seal: --force'
    run_tlogger seal a b
    assert_usage_error 'tlogger: seal takes one session at most'
    run_tlogger seal --all 20261112T100000Z-a1B2c3
    assert_usage_error 'tlogger: seal takes a session or --all, not both'
    run_tlogger verify --quick
    assert_usage_error 'tlogger: unknown option for verify: --quick'
    run_tlogger list 20261112T100000Z-a1B2c3
    assert_usage_error 'tlogger: list takes no session'
}

@test "help names seal, verify and list" {
    run_tlogger help
    [ "$status" -eq 0 ]
    [[ $output == *$'\n  seal '* && $output == *$'\n  verify '* && $output == *$'\n  list '* ]]
}
