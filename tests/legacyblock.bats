#!/usr/bin/env bats
# Tests for libexec/legacyblock.awk under every awk on PATH, mawk, gawk and awk: the truth table of
# two given marker lines, compared literally, and for the range of lines that libexec/rcblock.awk
# skips on a migration run. Every rc and marker here is synthetic.

load helpers

LEGACY="$REPO_ROOT/libexec/legacyblock.awk"
RCBLOCK="$REPO_ROOT/libexec/rcblock.awk"
OLD_START='# BEGIN example-recorder'
OLD_END='# END example-recorder'
OWN_START='# >>> tlogger >>>'
OWN_END='# <<< tlogger <<<'

# Run before each test by bats.
# Gives the test its own home and fills AWKS with each of mawk, gawk and awk found on PATH.
setup() {
    local awk
    isolate_home
    AWKS=()
    for awk in mawk gawk awk; do
        if command -v "$awk" > /dev/null 2>&1; then
            AWKS+=("$awk")
        fi
    done
}

# Run COMMAND... through bats `run` once per awk in AWKS, with the awk's name in place of the word
# AWK, on the file rc. Fails unless every awk prints the same lines and exits with the same status;
# leaves status and output set.
across_awks() {
    local awk arg first_awk='' first_output='' first_status=''
    local -a cmd
    if (( ${#AWKS[@]} == 0 )); then
        printf 'no awk on PATH\n' >&2
        return 1
    fi
    for awk in "${AWKS[@]}"; do
        cmd=()
        for arg in "$@"; do
            if [[ $arg == AWK ]]; then
                arg=$awk
            fi
            cmd+=("$arg")
        done
        run "${cmd[@]}" < "$BATS_TEST_TMPDIR/rc"
        if [[ -z $first_awk ]]; then
            first_awk=$awk first_output=$output first_status=$status
        elif [[ $output != "$first_output" || $status != "$first_status" ]]; then
            printf '%s printed (exit %s):\n%s\n%s printed (exit %s):\n%s\n' \
                "$first_awk" "$first_status" "$first_output" "$awk" "$status" "$output" >&2
            return 1
        fi
    done
}

# Write TEXT as the rc, byte for byte, and scan it with legacyblock.awk for the markers START and
# END, by default the two example markers, in the C locale, as bin/tlogger runs it.
scan() {
    printf '%s' "$1" > "$BATS_TEST_TMPDIR/rc"
    across_awks env LC_ALL=C LEGACY_START="${2-$OLD_START}" LEGACY_END="${3-$OLD_END}" \
        AWK -f "$LEGACY"
}

# Write TEXT as the rc and scan it with rcblock.awk, lines FROM to TO being the skipped range.
scan_skip() {
    printf '%s' "$1" > "$BATS_TEST_TMPDIR/rc"
    across_awks env LC_ALL=C RCBLOCK_SKIP_FROM="$2" RCBLOCK_SKIP_TO="$3" AWK -f "$RCBLOCK"
}

@test "mawk and gawk are both on PATH, so that the scan runs under each" {
    need command mawk
    need command gawk
}

@test "one pair of markers reports its lines" {
    scan $'alias a=1\n'"$OLD_START"$'\nsource old\n'"$OLD_END"$'\nalias z=2\n'
    [ "$status" -eq 0 ]
    [ "$output" = "block 2 4" ]
}

@test "a pair on two neighbouring lines is a block" {
    scan "$OLD_START"$'\n'"$OLD_END"$'\n'
    [ "$status" -eq 0 ]
    [ "$output" = "block 1 2" ]
}

@test "an rc with neither marker scans as none" {
    scan $'alias a=1\nexport EDITOR=vi\n'
    [ "$status" -eq 0 ]
    [ "$output" = none ]
}

@test "an empty rc scans as none" {
    scan ''
    [ "$status" -eq 0 ]
    [ "$output" = none ]
}

@test "a missing start marker is unpaired, at the end marker" {
    scan $'alias a=1\n'"$OLD_END"$'\n'
    [ "$status" -eq 1 ]
    [ "$output" = "error unpaired 2" ]
}

@test "a missing end marker is unpaired, at the start marker" {
    scan $'alias a=1\n'"$OLD_START"$'\nalias z=2\n'
    [ "$status" -eq 1 ]
    [ "$output" = "error unpaired 2" ]
}

@test "a second start marker is a duplicate" {
    scan "$OLD_START"$'\n'"$OLD_START"$'\n'"$OLD_END"$'\n'
    [ "$status" -eq 1 ]
    [ "$output" = "error duplicate 2" ]
}

@test "a second end marker is a duplicate" {
    scan "$OLD_START"$'\n'"$OLD_END"$'\nalias a=1\n'"$OLD_END"$'\n'
    [ "$status" -eq 1 ]
    [ "$output" = "error duplicate 4" ]
}

@test "a second pair reports both of its markers, in line order" {
    scan "$OLD_START"$'\n'"$OLD_END"$'\n'"$OLD_START"$'\n'"$OLD_END"$'\n'
    [ "$status" -eq 1 ]
    [ "$output" = $'error duplicate 3\nerror duplicate 4' ]
}

@test "an end marker before the start marker is reversed" {
    scan "$OLD_END"$'\nalias a=1\n'"$OLD_START"$'\n'
    [ "$status" -eq 1 ]
    [ "$output" = "error reversed 1" ]
}

@test "a marker with trailing text is altered" {
    scan "$OLD_START"$' v2\nsource old\n'"$OLD_END"$'\n'
    [ "$status" -eq 1 ]
    [ "$output" = $'error altered 1\nerror unpaired 3' ]
}

@test "a marker with a leading space is altered" {
    scan ' '"$OLD_START"$'\nsource old\n'"$OLD_END"$'\n'
    [ "$status" -eq 1 ]
    [ "$output" = $'error altered 1\nerror unpaired 3' ]
}

@test "an altered line inside a good pair is refused too" {
    scan "$OLD_START"$'\necho '"$OLD_END"$'\n'"$OLD_END"$'\n'
    [ "$status" -eq 1 ]
    [ "$output" = "error altered 2" ]
}

@test "CRLF lines match once the one trailing CR is removed" {
    scan "$OLD_START"$'\r\nsource old\r\n'"$OLD_END"$'\r\nalias z=2\r\n'
    [ "$status" -eq 0 ]
    [ "$output" = "block 1 3" ]
}

@test "a line with two trailing CRs is altered" {
    # Git Bash's gawk reads in text mode and drops one CR before the scan sees the line.
    [[ $(printf 'a\r\n' | awk '{ print length($0) }') == 2 ]] || skip "this awk drops a CR itself"
    scan "$OLD_START"$'\r\r\nsource old\n'"$OLD_END"$'\n'
    [ "$status" -eq 1 ]
    [ "$output" = $'error altered 1\nerror unpaired 3' ]
}

@test "an end marker on the last line, without a final newline, is found" {
    scan $'alias a=1\n'"$OLD_START"$'\nsource old\n'"$OLD_END"
    [ "$status" -eq 0 ]
    [ "$output" = "block 2 4" ]
}

@test "backslashes in a marker are literal" {
    local start='# BEGIN \t \\ example' end='# END \n example'
    scan "$start"$'\nsource old\n'"$end"$'\n' "$start" "$end"
    [ "$status" -eq 0 ]
    [ "$output" = "block 1 3" ]
    # A line with a real tab is not the marker that spells it \t.
    scan $'# BEGIN \t \\ example\n'"$end"$'\n' "$start" "$end"
    [ "$status" -eq 1 ]
    [ "$output" = "error unpaired 2" ]
}

@test "regex characters in a marker match only themselves" {
    local start='# [.*] ^BEGIN$ (a|b)+' end='# [.*] ^END$ (a|b)+'
    scan "$start"$'\nsource old\n'"$end"$'\n' "$start" "$end"
    [ "$status" -eq 0 ]
    [ "$output" = "block 1 3" ]
    scan $'# xx ^BEGIN$ a\nsource old\n# xx ^END$ b\n' "$start" "$end"
    [ "$status" -eq 0 ]
    [ "$output" = none ]
}

@test "a marker that looks like a number is compared as text" {
    # 1e1 equals 10 as a number and does not hold the text 10.
    scan $'1e1\nsource old\n20\n' 10 20
    [ "$status" -eq 1 ]
    [ "$output" = "error unpaired 3" ]
    scan $'10\nsource old\n20\n' 10 20
    [ "$status" -eq 0 ]
    [ "$output" = "block 1 3" ]
}

@test "a marker that is a prefix of tlogger's own leaves tlogger's lines alone" {
    local start='# >>> tlogger' end='# <<< tlogger'
    scan "$OWN_START"$'\nsource plugin\n'"$OWN_END"$'\n'"$start"$'\nsource old\n'"$end"$'\n' \
        "$start" "$end"
    [ "$status" -eq 0 ]
    [ "$output" = "block 4 6" ]
}

@test "tlogger's own marker lines alone count as neither marker" {
    scan "$OWN_START"$'\n'"$OWN_END"$'\n' '# >>> tlogger' '# <<< tlogger'
    [ "$status" -eq 0 ]
    [ "$output" = none ]
}

@test "a changed copy of tlogger's marker that holds the given text is altered" {
    scan "$OWN_START"$' v2\n' '# >>> tlogger' '# <<< tlogger'
    [ "$status" -eq 1 ]
    [ "$output" = "error altered 1" ]
}

@test "a marker that is a substring of the other still pairs" {
    local start='# example' end='# example end'
    scan "$start"$'\nsource old\n'"$end"$'\n' "$start" "$end"
    [ "$status" -eq 0 ]
    [ "$output" = "block 1 3" ]
    scan "$end"$'\nsource old\n'"$start"$'\n' "$end" "$start"
    [ "$status" -eq 0 ]
    [ "$output" = "block 1 3" ]
}

@test "an empty marker is an awk usage error, not a scan that finds nothing" {
    scan $'alias a=1\n' '' "$OLD_END"
    [ "$status" -eq 2 ]
    [ -z "$output" ]
}

@test "rcblock.awk skips the altered and script checks inside the range only" {
    local rc="# >>> tlogger v1"$'\nscript -q\n# after\nscript -q\n'
    scan_skip "$rc" 1 2
    [ "$status" -eq 0 ]
    [ "$output" = $'none\nforeign 4' ]
}

@test "rcblock.awk counts exact tlogger markers inside the range, at their real lines" {
    scan_skip $'alias a=1\n# BEGIN\n'"$OWN_START"$'\n# x\n'"$OWN_END"$'\n# END\nalias z=2\n' 2 6
    [ "$status" -eq 0 ]
    [ "$output" = "block 3 5" ]
}

@test "rcblock.awk treats empty range variables as no range" {
    scan_skip $'script -q\n' '' ''
    [ "$status" -eq 0 ]
    [ "$output" = $'none\nforeign 1' ]
}

@test "rcblock.awk treats a range from line 0 as no range" {
    scan_skip $'script -q\n' 0 0
    [ "$status" -eq 0 ]
    [ "$output" = $'none\nforeign 1' ]
}
