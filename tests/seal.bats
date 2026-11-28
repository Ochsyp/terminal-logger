#!/usr/bin/env bats
# Tests for tlogger seal, verify and list in bin/tlogger, run as a subprocess in the test's own
# HOME on synthetic sessions. A fake /proc, which TLOGGER_PROC names, holds the boot id and the
# processes that the liveness check reads, so that a session counts as still recorded only when
# a test says so. A session that prune removed is made here by hand: its folder removed and a line
# appended to PRUNED in the form prune writes, so that these tests do not depend on prune.
#
# The contract of phase 11 that these tests pin. Every message starts with 'tlogger: ' and shows
# a path under HOME with ~; <log folder> is ~/.local/state/tlogger/sessions here, and <folder> is
# the log folder or an engagement folder in it.
#
# verify --all, besides each session folder, reads the MANIFEST of the log folder and of each
# engagement folder:
# - Only lines '<sum>  <id>/SHA256SUMS' whose <id> is named like a session count; a line that a
#   seal by path wrote for a folder of another name never does. The last line for an id in a
#   MANIFEST gives its sum.
# - An id of a MANIFEST is gone when <folder> holds no entry of that name at all, of any type.
#   Each gone id gets one of these lines on stdout:
#     <id>  pruned   <folder>/PRUNED holds a line for <id> with that sum
#     <id>  moved    another folder, the log folder or an engagement folder, holds a session
#                    folder <id> whose SHA256SUMS has that sum; that folder gets its own line
#     <id>  missing  anything else, a copy with another sum and a PRUNED line with another sum
#                    included
# - A PRUNED line has its fields split by two spaces: a UTC time, the id, the SHA-256 of the
#   session's SHA256SUMS, the archive's file name, the archive's SHA-256 and 'tlogger <version>';
#   a line written by hand has '-' for both archive fields and 'by hand' last. A PRUNED line
#   whose id no MANIFEST line of its folder names gives no line at all.
# - For each missing id, in the order of the stdout lines, this one line goes to stderr, <UTC
#   time> being the time of the run as YYYY-MM-DDTHH:MM:SSZ, so that the line it names can be
#   appended as it is:
#     tlogger: <id>: its folder is gone from <folder> and <folder>/PRUNED does not record it; if
#     it was removed on purpose, append this line to <folder>/PRUNED: <UTC time>  <id>  <sum>  -
#     -  by hand
#   (one line, with two spaces between the fields of the PRUNED line).
# - stdout is one line per verdict, by id in byte order; for one id, the lines of its session
#   folders come first, then those of the MANIFESTs, the log folder's first, then the engagement
#   folders' by name.
# - pruned and moved are fine. missing counts as changed: exit 1. verify --all exits 3, with
#   'no sessions in <log folder>', only when there is neither a session folder nor a line that
#   counts in any MANIFEST; with every session pruned it exits 0.
# - verify <id> and list do not change: neither shows a pruned, moved or missing id.
#
# verify, with one session or --all, counts the unsealed and the unknown sessions apart. When no
# session is changed or missing, it exits 4 if either count is not 0, with these lines on stderr,
# the unsealed one first:
#   tlogger: 1 finished session is not sealed; tlogger seal --all seals it
#   tlogger: <N> finished sessions are not sealed; tlogger seal --all seals them
#   tlogger: 1 session has no recorder file, so tlogger cannot tell whether it ended, and seal
#   refuses it
#   tlogger: <N> sessions have no recorder file, so tlogger cannot tell whether they ended, and
#   seal refuses them
# (each of the last two one line).
#
# MANIFEST and PRUNED are reserved names. A real folder of either name in the log folder that
# holds an entry named like a session is refused by every command that walks the engagement
# folders, list, seal --all and verify --all among them, before anything is read or written:
# exit 1, nothing on stdout, and this line alone on stderr:
#   tlogger: the folder <log folder>/<NAME> holds sessions, but <NAME> is a reserved name;
#   rename it to a valid engagement name
# (one line). Such a folder without a session-named entry is passed over, as before, and a
# regular file named PRUNED in the log folder is the record prune --none writes.

bats_require_minimum_version 1.5.0

load helpers

# A UTC time as SEAL writes it, as an extended regular expression.
UTC_RE='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'

# The boot id of the fake /proc, and the recorder that each synthetic session names; make_session
# and fake_process in helpers.bash read them, and LOGS and PROC, which setup sets.
BOOT=0b1e7c5a-4d2f-4c3b-9a8e-7f6d5c4b3a21
REC_PID=4242
REC_START=1000

# The log folder as tlogger shows it.
# shellcheck disable=SC2088 # The ~ is the text tlogger prints, not a path to expand.
SHOWN='~/.local/state/tlogger/sessions'

# A SHA-256 that no file here has, for the archive that a PRUNED line names.
ZERO_SUM=0000000000000000000000000000000000000000000000000000000000000000

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

# Print the notice that seal prints for the session SESSION, an id or ENGAGEMENT/ID in the log
# folder: its id and the SHA-256 of its SHA256SUMS.
sealed_notice() {
    printf 'tlogger: sealed session %s; SHA-256 of its SHA256SUMS: %s\n' "${1##*/}" \
        "$(sha_of "$LOGS/$1/SHA256SUMS")"
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

# Remove the session folder SESSION, an id or ENGAGEMENT/ID in the log folder, with all its
# files, as someone deleting it by hand would. It refuses a path outside BATS_TEST_TMPDIR.
remove_by_hand() {
    local dir=$LOGS/$1
    if [[ $dir != "$BATS_TEST_TMPDIR"/* || -z ${1##*/} || $1 == *..* ]]; then
        printf 'remove_by_hand: %s is not a session of the test\n' "$dir" >&2
        return 1
    fi
    rm -rf -- "$dir"
}

# Append to FOLDER/PRUNED, created with mode 0600, the line that prune writes for the session ID
# whose SHA256SUMS had the SHA-256 SUM, taken out with an archive of FOLDER made on 2026-11-20.
record_pruned() {
    local folder=$1
    if [[ ! -e $folder/PRUNED ]]; then
        (umask 077 && : > "$folder/PRUNED")
    fi
    printf '2026-11-20T09:30:00Z  %s  %s  %s-20261120T090000Z.tar.gz  %s  tlogger %s\n' "$2" \
        "$3" "${folder##*/}" "$ZERO_SUM" "$VERSION_TEXT" >> "$folder/PRUNED"
}

# Fail unless STDERR_LINE is the missing message for the session ID, gone from the folder that
# tlogger shows as FOLDER, whose MANIFEST line holds the SHA-256 SUM, with a PRUNED line stamped
# within the last 10 minutes. Sets HAND_LINE to the PRUNED line it names.
assert_missing() {
    local line=$1 id=$2 folder=$3 sum=$4 head stamp when now
    head="tlogger: $id: its folder is gone from $folder and $folder/PRUNED does not record it;"
    head+=" if it was removed on purpose, append this line to $folder/PRUNED: "
    HAND_LINE=${line#"$head"}
    stamp=${HAND_LINE%%  *}
    if [[ $line != "$head"* || $HAND_LINE != "$stamp  $id  $sum  -  -  by hand" ||
        ! $stamp =~ ^$UTC_RE$ ]]; then
        printf 'expected the missing message for %s in %s with the sum %s; got:\n%s\n' "$id" \
            "$folder" "$sum" "$line" >&2
        return 1
    fi
    when=$(date -u -d "$stamp" +%s)
    now=$(date -u +%s)
    if (( now - when < 0 || now - when > 600 )); then
        printf 'the PRUNED line names %s, not a time of the last 10 minutes\n' "$stamp" >&2
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
    # A seal whose SHA256SUMS no longer has the sum SEAL names gets no MANIFEST line.
    chmod 600 "$LOGS/$id/SHA256SUMS"
    printf '%s  extra\n' "$sum" >> "$LOGS/$id/SHA256SUMS"
    chmod 400 "$LOGS/$id/SHA256SUMS"
    : > "$LOGS/MANIFEST"
    run_tlogger seal "$id"
    want="tlogger: session $id is sealed, but its SHA256SUMS does not match its SEAL, so seal adds"
    assert_refused 1 "$want no MANIFEST line; tlogger verify $id names what changed"
    [ ! -s "$LOGS/MANIFEST" ]
}

@test "a session given by a path with any folder name gets one MANIFEST line beside it" {
    local dir="$BATS_TEST_TMPDIR/cases/a+b(1)" sum
    mkdir -p "$BATS_TEST_TMPDIR/cases"
    make_session 20261112T100000Z-a1B2c3
    mv "$LOGS/20261112T100000Z-a1B2c3" "$dir"
    run_tlogger seal "$dir"
    [ "$status" -eq 0 ]
    run_tlogger seal "$dir"
    [ "$status" -eq 0 ]
    sum=$(sha_of "$dir/SHA256SUMS")
    [ "$(cat "$BATS_TEST_TMPDIR/cases/MANIFEST")" = "$sum  a+b(1)/SHA256SUMS" ]
    [ ! -e "$LOGS/MANIFEST" ]
    run_tlogger verify "$dir"
    [ "$status" -eq 0 ]
    [ "$output" = 'a+b(1)  ok' ]
}

@test "a second first seal of a session whose MANIFEST holds an older sum fails" {
    local id=20261112T100000Z-a1B2c3 want
    make_session "$id"
    run_tlogger seal "$id"
    [ "$status" -eq 0 ]
    # SEAL removed and a log changed, then sealed again: the MANIFEST keeps the first sum.
    rm -f "$LOGS/$id/SEAL" "$LOGS/$id/SHA256SUMS"
    chmod 600 "$LOGS/$id/commands.tsv"
    printf 'S\t1794391300\t2026-11-12T10:01:40Z\t4300\t/srv/work\t-\tid\n' \
        >> "$LOGS/$id/commands.tsv"
    run_tlogger seal "$id"
    want="tlogger: session $id is sealed, but the MANIFEST holds another sum for it from an"
    assert_refused 1 "$want earlier seal; tlogger verify $id names what changed"
    [ "$(wc -l < "$LOGS/MANIFEST")" -eq 1 ]
    run_tlogger verify "$id"
    [ "$status" -eq 1 ]
    # Sealing it again says so too, instead of 'sealed already'.
    run_tlogger seal "$id"
    want="tlogger: session $id is sealed, but its line in the MANIFEST holds another sum than"
    assert_refused 1 "$want its SEAL; tlogger verify $id names what changed"
}

@test "a MANIFEST that ends without a newline gets one before the next line" {
    local id=20261112T100000Z-a1B2c3
    make_session "$id"
    printf 'cut short' > "$LOGS/MANIFEST"
    run_tlogger seal "$id"
    [ "$status" -eq 0 ]
    [ "$(sed -n 1p "$LOGS/MANIFEST")" = 'cut short' ]
    [ "$(sed -n 2p "$LOGS/MANIFEST")" = "$(sha_of "$LOGS/$id/SHA256SUMS")  $id/SHA256SUMS" ]
    [ "$(wc -l < "$LOGS/MANIFEST")" -eq 2 ]
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

@test "list shows each session's state, start, duration, commands, transcript and engagement" {
    local a=20261112T100000Z-aaaaaa b=20261112T110000Z-bbbbbb c=20261112T120000Z-cccccc
    local d=20261112T130000Z-dddddd e=20261112T140000Z-eeeeee
    local row='%-23s  %-9s  %-20s  %8s  %8s  %-10s  %s'
    # a: sealed, with a transcript. b, in the engagement acme: ended. c: still recorded by the
    # live recorder 4242. d, in the engagement demo: sealed, then a log made writable. e: no
    # recorder file. The rows go by id, whichever folder holds the session.
    mkdir -m 700 "$LOGS/acme" "$LOGS/demo"
    make_session "$a" 3
    run_tlogger seal "$a"
    printf 'derived\n' > "$LOGS/$a/transcript.txt"
    make_session "acme/$b" 1
    make_session "$c" 0
    make_session "demo/$d"
    run_tlogger seal "$d"
    [ "$status" -eq 0 ]
    chmod 600 "$LOGS/demo/$d/timing"
    make_session "$e"
    rm "$LOGS/$e/recorder"
    fake_process "$REC_PID" "$REC_START"
    printf '4343 2000 %s 34818\n' "$BOOT" > "$LOGS/acme/$b/recorder"
    printf 'not a session\n' > "$LOGS/notes.txt"
    run_tlogger list
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    # shellcheck disable=SC2059 # The row format is the test's own.
    [ "$output" = "$(printf "$row\n" SESSION STATE 'START (UTC)' DURATION COMMANDS TRANSCRIPT \
        ENGAGEMENT \
        "$a" sealed 2026-11-12T10:00:00Z 00:01:00 3 yes - \
        "$b" ended 2026-11-12T11:00:00Z 00:01:00 1 no acme \
        "$c" recording 2026-11-12T12:00:00Z 00:01:00 0 no - \
        "$d" changed 2026-11-12T13:00:00Z 00:01:00 2 no demo \
        "$e" unknown 2026-11-12T14:00:00Z 00:01:00 2 no -)" ]
}

@test "seal and verify cover flat and engagement sessions by id, with one MANIFEST per folder" {
    local a=20261112T100000Z-aaaaaa b=20261112T110000Z-bbbbbb c=20261112T120000Z-cccccc
    local d=20261112T130000Z-dddddd e=20261112T140000Z-eeeeee dir f
    mkdir -m 700 "$LOGS/acme" "$LOGS/demo"
    make_session "$a"
    make_session "acme/$b"
    make_session "$c"
    make_session "demo/$d"
    make_session "acme/$e"
    # Without a SESSION, seal takes the newest id, which lies in acme.
    run_tlogger seal
    [ "$status" -eq 0 ]
    [ "$stderr" = "$(sealed_notice "acme/$e")" ]
    [ ! -e "$LOGS/MANIFEST" ]
    # --all seals the others in id order, whichever folder holds them.
    run_tlogger seal --all
    [ "$status" -eq 0 ]
    [ "${#stderr_lines[@]}" -eq 4 ]
    [ "${stderr_lines[0]}" = "$(sealed_notice "$a")" ]
    [ "${stderr_lines[1]}" = "$(sealed_notice "acme/$b")" ]
    [ "${stderr_lines[2]}" = "$(sealed_notice "$c")" ]
    [ "${stderr_lines[3]}" = "$(sealed_notice "demo/$d")" ]
    for f in output.raw timing input.raw commands.tsv SHA256SUMS SEAL; do
        [ "$(stat -c %a "$LOGS/acme/$b/$f")" = 400 ]
        [ "$(stat -c %a "$LOGS/demo/$d/$f")" = 400 ]
    done
    # Each folder's MANIFEST names its own sessions, relative to itself.
    [ "$(cat "$LOGS/MANIFEST")" = "$(manifest_entry "$a")"$'\n'"$(manifest_entry "$c")" ]
    [ "$(cat "$LOGS/acme/MANIFEST")" = \
        "$(manifest_entry "acme/$e")"$'\n'"$(manifest_entry "acme/$b")" ]
    [ "$(cat "$LOGS/demo/MANIFEST")" = "$(manifest_entry "demo/$d")" ]
    for dir in "$LOGS" "$LOGS/acme" "$LOGS/demo"; do
        [ "$(stat -c %a "$dir/MANIFEST")" = 600 ]
        (cd "$dir" && sha256sum --quiet -c MANIFEST)
    done
    run_tlogger verify "$d"
    [ "$status" -eq 0 ]
    [ "$output" = "$d  ok" ]
    run_tlogger verify
    [ "$status" -eq 0 ]
    [ "$output" = "$e  ok" ]
    run_tlogger verify --all
    [ "$status" -eq 0 ]
    [ "$output" = "$a  ok"$'\n'"$b  ok"$'\n'"$c  ok"$'\n'"$d  ok"$'\n'"$e  ok" ]
    [ -z "$stderr" ]
}

@test "a flat session of 0.2.0 and its MANIFEST stay byte for byte as they are, and verify ok" {
    local old=20261101T090000Z-o1d0a2 x=20261120T100000Z-acme01 y=20261121T100000Z-acme02
    local before
    # A session sealed before engagements existed, as 0.2.0 left it.
    make_session "$old"
    run_tlogger seal "$old"
    [ "$status" -eq 0 ]
    cp "$LOGS/MANIFEST" "$BATS_TEST_TMPDIR/manifest-before"
    before=$(tree_of "$LOGS/$old")
    mkdir -m 700 "$LOGS/acme"
    make_session "acme/$x"
    make_session "acme/$y"
    run_tlogger seal --all
    [ "$status" -eq 0 ]
    [ "${#stderr_lines[@]}" -eq 2 ]
    cmp "$LOGS/MANIFEST" "$BATS_TEST_TMPDIR/manifest-before"
    [ "$(tree_of "$LOGS/$old")" = "$before" ]
    [ "$(wc -l < "$LOGS/acme/MANIFEST")" -eq 2 ]
    run_tlogger verify "$old"
    [ "$status" -eq 0 ]
    [ "$output" = "$old  ok" ]
    run_tlogger verify --all
    [ "$status" -eq 0 ]
    [ "$output" = "$old  ok"$'\n'"$x  ok"$'\n'"$y  ok" ]
}

@test "seal --all reaches a hand-made folder named like an engagement, and no other subfolder" {
    local f=20261112T100000Z-ffffff name dir
    # Made by hand, with the default mode, and named like an engagement.
    mkdir "$LOGS/Case_2026.x"
    make_session "Case_2026.x/$f"
    # Not engagement folders: a hidden name, a name with a space and a second level. A symlink
    # named like an engagement is refused; tests/folder-modes.bats checks that. A folder named
    # MANIFEST or PRUNED that holds sessions is refused too; a test below checks that.
    for name in .old/20261112T110000Z-gggggg 'bad name/20261112T120000Z-hhhhhh' \
        Case_2026.x/sub/20261112T140000Z-jjjjjj; do
        make_session "$name"
    done
    run_tlogger seal --all
    [ "$status" -eq 0 ]
    [ "$stderr" = "$(sealed_notice "Case_2026.x/$f")" ]
    [ "$(stat -c %a "$LOGS/Case_2026.x/$f/output.raw")" = 400 ]
    [ "$(cat "$LOGS/Case_2026.x/MANIFEST")" = "$(manifest_entry "Case_2026.x/$f")" ]
    for dir in "$LOGS/.old/20261112T110000Z-gggggg" "$LOGS/bad name/20261112T120000Z-hhhhhh" \
        "$LOGS/Case_2026.x/sub/20261112T140000Z-jjjjjj"; do
        [ ! -e "$dir/SEAL" ]
        [ "$(stat -c %a "$dir/output.raw")" = 600 ]
        [ ! -e "${dir%/*}/MANIFEST" ]
    done
    run_tlogger verify --all
    [ "$status" -eq 0 ]
    [ "$output" = "$f  ok" ]
}

@test "verify --all reads each MANIFEST: a session that PRUNED records with its sum is pruned" {
    local a=20261112T100000Z-aaaaaa b=20261112T110000Z-bbbbbb c=20261112T120000Z-cccccc
    local sum_a sum_c
    mkdir -m 700 "$LOGS/acme"
    make_session "$a"
    make_session "$b"
    make_session "acme/$c"
    run_tlogger seal --all
    [ "$status" -eq 0 ]
    sum_a=$(sha_of "$LOGS/$a/SHA256SUMS")
    sum_c=$(sha_of "$LOGS/acme/$c/SHA256SUMS")
    # a directly in the log folder, as prune --none leaves it, and c in the engagement acme.
    remove_by_hand "$a"
    record_pruned "$LOGS" "$a" "$sum_a"
    remove_by_hand "acme/$c"
    record_pruned "$LOGS/acme" "$c" "$sum_c"
    cp "$LOGS/MANIFEST" "$BATS_TEST_TMPDIR/manifest"
    cp "$LOGS/PRUNED" "$BATS_TEST_TMPDIR/pruned"
    run_tlogger verify --all
    [ "$status" -eq 0 ]
    [ "$output" = "$a  pruned"$'\n'"$b  ok"$'\n'"$c  pruned" ]
    [ -z "$stderr" ]
    # verify reads the MANIFEST and PRUNED, and changes neither.
    cmp "$LOGS/MANIFEST" "$BATS_TEST_TMPDIR/manifest"
    cmp "$LOGS/PRUNED" "$BATS_TEST_TMPDIR/pruned"
    # list shows the session folders, as before.
    run_tlogger list
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [[ ${lines[1]} == "$b "* ]]
}

@test "verify names a prune cut short that emptied a folder, but not a whole session" {
    local b=20261112T110000Z-bbbbbb c=20261112T120000Z-cccccc f
    make_session "$b"
    make_session "$c"
    run_tlogger seal --all
    [ "$status" -eq 0 ]
    # Both are in PRUNED: b as a prune cut short before its folder went left it, with no file
    # left; c whole, as a session put back after a prune, or one a prune stopped before its first
    # removal.
    record_pruned "$LOGS" "$b" "$(sha_of "$LOGS/$b/SHA256SUMS")"
    record_pruned "$LOGS" "$c" "$(sha_of "$LOGS/$c/SHA256SUMS")"
    for f in "$LOGS/$b"/*; do
        rm -f -- "$f"
    done
    run_tlogger verify --all
    [ "$status" -eq 1 ]
    [ "${#lines[@]}" -eq 2 ]
    [[ ${lines[0]} == "$b  "* && ${lines[0]} != "$b  ok" ]]
    [ "${lines[1]}" = "$c  ok" ]
    grep -Fxq "tlogger: $b: a prune was cut short; run the same prune again" <<< "$stderr"
    [ "$(grep -c 'a prune was cut short' <<< "$stderr")" -eq 1 ]
    # Neither count names b: it is no session for seal --all.
    [[ $stderr != *'not sealed'* && $stderr != *'no recorder file'* ]]
}

@test "a session deleted by hand is missing, exits 1, and its message gives the PRUNED line" {
    local a=20261112T100000Z-aaaaaa b=20261112T110000Z-bbbbbb c=20261112T120000Z-cccccc
    local sum_a sum_c
    mkdir -m 700 "$LOGS/acme"
    make_session "$a"
    make_session "$b"
    make_session "acme/$c"
    run_tlogger seal --all
    [ "$status" -eq 0 ]
    sum_a=$(sha_of "$LOGS/$a/SHA256SUMS")
    sum_c=$(sha_of "$LOGS/acme/$c/SHA256SUMS")
    remove_by_hand "$a"
    remove_by_hand "acme/$c"
    run_tlogger verify --all
    [ "$status" -eq 1 ]
    [ "$output" = "$a  missing"$'\n'"$b  ok"$'\n'"$c  missing" ]
    [ "${#stderr_lines[@]}" -eq 2 ]
    assert_missing "${stderr_lines[0]}" "$a" "$SHOWN" "$sum_a"
    assert_missing "${stderr_lines[1]}" "$c" "$SHOWN/acme" "$sum_c"
    refute_home_shown
    [ ! -e "$LOGS/PRUNED" ]
    [ ! -e "$LOGS/acme/PRUNED" ]
    # The line the message gives, appended as it is, records the removal: c is pruned now.
    (umask 077 && printf '%s\n' "$HAND_LINE" >> "$LOGS/acme/PRUNED")
    run_tlogger verify --all
    [ "$status" -eq 1 ]
    [ "$output" = "$a  missing"$'\n'"$b  ok"$'\n'"$c  pruned" ]
    assert_missing "$stderr" "$a" "$SHOWN" "$sum_a"
    (umask 077 && printf '%s\n' "$HAND_LINE" >> "$LOGS/PRUNED")
    run_tlogger verify --all
    [ "$status" -eq 0 ]
    [ "$output" = "$a  pruned"$'\n'"$b  ok"$'\n'"$c  pruned" ]
    [ -z "$stderr" ]
}

@test "a session moved by hand and sealed again is moved in its old folder and ok in the new" {
    local a=20261112T100000Z-aaaaaa b=20261112T110000Z-bbbbbb
    make_session "$a"
    make_session "$b"
    run_tlogger seal --all
    [ "$status" -eq 0 ]
    mkdir -m 700 "$LOGS/acme"
    mv "$LOGS/$a" "$LOGS/acme/$a"
    # In its new folder it lacks a MANIFEST line, so that copy is changed until seal adds it.
    run_tlogger verify --all
    [ "$status" -eq 1 ]
    [ "$output" = "$a  changed"$'\n'"$a  moved"$'\n'"$b  ok" ]
    [ "$stderr" = "tlogger: $a: no line in the MANIFEST names this session" ]
    run_tlogger seal "$a"
    [ "$status" -eq 0 ]
    run_tlogger verify --all
    [ "$status" -eq 0 ]
    [ "$output" = "$a  ok"$'\n'"$a  moved"$'\n'"$b  ok" ]
    [ -z "$stderr" ]
}

@test "a copy or a PRUNED line with another sum leaves a session missing" {
    local a=20261112T100000Z-aaaaaa b=20261112T110000Z-bbbbbb c=20261112T120000Z-cccccc
    local sum_a sum_b
    make_session "$a"
    make_session "$b"
    run_tlogger seal --all
    [ "$status" -eq 0 ]
    sum_a=$(sha_of "$LOGS/$a/SHA256SUMS")
    sum_b=$(sha_of "$LOGS/$b/SHA256SUMS")
    # a: deleted, and another session of the same id sealed in the engagement acme.
    remove_by_hand "$a"
    mkdir -m 700 "$LOGS/acme"
    make_session "acme/$a" 3
    run_tlogger seal "$a"
    [ "$status" -eq 0 ]
    [ "$(sha_of "$LOGS/acme/$a/SHA256SUMS")" != "$sum_a" ]
    # b: deleted, with PRUNED lines of another sum, of another id, and in another folder.
    remove_by_hand "$b"
    record_pruned "$LOGS" "$b" "$ZERO_SUM"
    record_pruned "$LOGS" "$c" "$sum_b"
    record_pruned "$LOGS/acme" "$b" "$sum_b"
    run_tlogger verify --all
    [ "$status" -eq 1 ]
    # A PRUNED line alone, as for c, gives no line.
    [ "$output" = "$a  ok"$'\n'"$a  missing"$'\n'"$b  missing" ]
    [ "${#stderr_lines[@]}" -eq 2 ]
    assert_missing "${stderr_lines[0]}" "$a" "$SHOWN" "$sum_a"
    assert_missing "${stderr_lines[1]}" "$b" "$SHOWN" "$sum_b"
}

@test "a MANIFEST line for a folder sealed by path under another name never counts" {
    local a=20261112T100000Z-aaaaaa
    make_session "$LOGS/copy+1"
    run_tlogger seal "$LOGS/copy+1"
    [ "$status" -eq 0 ]
    grep -qF '  copy+1/SHA256SUMS' "$LOGS/MANIFEST"
    # Neither with its folder there nor with it gone is it a session, or missing.
    run_tlogger verify --all
    assert_refused 3 "tlogger: no sessions in $SHOWN"
    remove_by_hand copy+1
    run_tlogger verify --all
    assert_refused 3 "tlogger: no sessions in $SHOWN"
    make_session "$a"
    run_tlogger seal "$a"
    [ "$status" -eq 0 ]
    run_tlogger verify --all
    [ "$status" -eq 0 ]
    [ "$output" = "$a  ok" ]
    [ -z "$stderr" ]
}

@test "with every session pruned verify --all exits 0, and 3 only without folders and lines" {
    local a=20261112T100000Z-aaaaaa b=20261112T110000Z-bbbbbb sum_a sum_b
    # An empty MANIFEST holds no line.
    (umask 077 && : > "$LOGS/MANIFEST")
    run_tlogger verify --all
    assert_refused 3 "tlogger: no sessions in $SHOWN"
    mkdir -m 700 "$LOGS/acme"
    make_session "acme/$a"
    make_session "acme/$b"
    run_tlogger seal --all
    [ "$status" -eq 0 ]
    sum_a=$(sha_of "$LOGS/acme/$a/SHA256SUMS")
    sum_b=$(sha_of "$LOGS/acme/$b/SHA256SUMS")
    remove_by_hand "acme/$a"
    remove_by_hand "acme/$b"
    record_pruned "$LOGS/acme" "$a" "$sum_a"
    record_pruned "$LOGS/acme" "$b" "$sum_b"
    run_tlogger verify --all
    [ "$status" -eq 0 ]
    [ "$output" = "$a  pruned"$'\n'"$b  pruned" ]
    [ -z "$stderr" ]
    # list and seal --all walk the session folders alone, and find none, as before.
    run_tlogger list
    assert_refused 3 "tlogger: no sessions in $SHOWN"
    run_tlogger seal --all
    assert_refused 3 "tlogger: no sessions in $SHOWN"
    [ -d "$LOGS/acme" ]
}

@test "verify counts unsealed and unknown sessions apart, and exits 4 for either" {
    local a=20261112T100000Z-aaaaaa b=20261112T110000Z-bbbbbb c=20261112T120000Z-cccccc
    local d=20261112T130000Z-dddddd e=20261112T140000Z-eeeeee
    local unsealed1='tlogger: 1 finished session is not sealed; tlogger seal --all seals it'
    local unsealed2='tlogger: 2 finished sessions are not sealed; tlogger seal --all seals them'
    local unknown1='tlogger: 1 session has no recorder file, so tlogger cannot tell whether it'
    local unknown2='tlogger: 2 sessions have no recorder file, so tlogger cannot tell whether'
    unknown1+=' ended, and seal refuses it'
    unknown2+=' they ended, and seal refuses them'
    # a ended; b and c have no recorder file.
    make_session "$a"
    make_session "$b"
    make_session "$c"
    rm -- "${LOGS:?}/$b/recorder" "${LOGS:?}/$c/recorder"
    run_tlogger verify --all
    [ "$status" -eq 4 ]
    [ "$output" = "$a  unsealed"$'\n'"$b  unknown"$'\n'"$c  unknown" ]
    [ "$stderr" = "$unsealed1"$'\n'"$unknown2" ]
    # Sealed, a no longer counts, and one unknown session is named alone.
    run_tlogger seal "$a"
    [ "$status" -eq 0 ]
    remove_by_hand "$b"
    run_tlogger verify --all
    [ "$status" -eq 4 ]
    [ "$output" = "$a  ok"$'\n'"$c  unknown" ]
    [ "$stderr" = "$unknown1" ]
    run_tlogger verify "$c"
    [ "$status" -eq 4 ]
    [ "$output" = "$c  unknown" ]
    [ "$stderr" = "$unknown1" ]
    # Two ended sessions and the unknown one: the unsealed line comes first.
    make_session "$d"
    make_session "$e"
    run_tlogger verify --all
    [ "$status" -eq 4 ]
    [ "$stderr" = "$unsealed2"$'\n'"$unknown1" ]
    run_tlogger verify "$e"
    [ "$status" -eq 4 ]
    [ "$stderr" = "$unsealed1" ]
}

@test "a folder named MANIFEST or PRUNED that holds sessions is refused by list, seal and verify" {
    local a=20261112T100000Z-aaaaaa f=20261112T130000Z-ffffff name want
    make_session "$a"
    for name in MANIFEST PRUNED; do
        mkdir -m 700 "$LOGS/$name"
        # A session folder in MANIFEST; in PRUNED, a plain file named like a session.
        if [[ $name == MANIFEST ]]; then
            make_session "$name/$f"
        else
            : > "$LOGS/$name/$f"
        fi
        want="tlogger: the folder $SHOWN/$name holds sessions, but $name is a reserved name;"
        want+=' rename it to a valid engagement name'
        run_tlogger list
        assert_refused 1 "$want"
        run_tlogger seal --all
        assert_refused 1 "$want"
        run_tlogger verify --all
        assert_refused 1 "$want"
        [ ! -e "$LOGS/$a/SEAL" ]
        [ "$(stat -c %a "$LOGS/$a/output.raw")" = 600 ]
        remove_by_hand "$name"
    done
    # Without a session-named entry, such a folder is passed over, as before.
    mkdir -m 700 "$LOGS/PRUNED"
    printf 'notes\n' > "$LOGS/PRUNED/notes.txt"
    run_tlogger seal --all
    [ "$status" -eq 0 ]
    run_tlogger verify --all
    [ "$status" -eq 0 ]
    [ "$output" = "$a  ok" ]
    # A regular file PRUNED in the log folder is prune's record, not a folder to refuse.
    remove_by_hand PRUNED
    record_pruned "$LOGS" 20261112T090000Z-gggggg "$ZERO_SUM"
    run_tlogger list
    [ "$status" -eq 0 ]
    run_tlogger verify --all
    [ "$status" -eq 0 ]
    [ "$output" = "$a  ok" ]
    [ -z "$stderr" ]
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
