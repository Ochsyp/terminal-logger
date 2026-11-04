#!/usr/bin/env bats
# Tests for libexec/rcblock.awk under every awk on PATH, mawk, gawk and awk: the truth table of
# marker states, CRLF lines, a missing final newline, and which lines count as running util-linux
# script. Every rc here is synthetic.

load helpers

RCBLOCK="$REPO_ROOT/libexec/rcblock.awk"
START='# >>> tlogger >>>'
END='# <<< tlogger <<<'

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

# Write TEXT, which printf %s copies byte for byte, as the rc, and scan it with rcblock.awk under
# every awk in AWKS through bats `run`, in the C locale as bin/tlogger runs it. Fails unless every
# awk prints the same lines and exits with the same status; leaves status and output set.
scan() {
    local awk first_awk='' first_output='' first_status=''
    printf '%s' "$1" > "$BATS_TEST_TMPDIR/rc"
    if (( ${#AWKS[@]} == 0 )); then
        printf 'no awk on PATH\n' >&2
        return 1
    fi
    for awk in "${AWKS[@]}"; do
        run env LC_ALL=C "$awk" -f "$RCBLOCK" < "$BATS_TEST_TMPDIR/rc"
        if [[ -z $first_awk ]]; then
            first_awk=$awk first_output=$output first_status=$status
        elif [[ $output != "$first_output" || $status != "$first_status" ]]; then
            printf '%s printed (exit %s):\n%s\n%s printed (exit %s):\n%s\n' \
                "$first_awk" "$first_status" "$first_output" "$awk" "$status" "$output" >&2
            return 1
        fi
    done
}

@test "mawk and gawk are both on PATH, so that the scan runs under each" {
    need command mawk
    need command gawk
}

@test "an rc without markers scans as none" {
    scan $'alias ll=\'ls -l\'\nexport EDITOR=vi\n'
    [ "$status" -eq 0 ]
    [ "$output" = none ]
}

@test "an empty rc scans as none" {
    scan ''
    [ "$status" -eq 0 ]
    [ "$output" = none ]
}

@test "one well-formed block at the top reports lines 1 to 4" {
    scan "$START"$'\n# managed\nsource plugin\n'"$END"$'\nalias ll=\'ls -l\'\n'
    [ "$status" -eq 0 ]
    [ "$output" = "block 1 4" ]
}

@test "a block below other lines reports its own line numbers" {
    scan $'alias ll=\'ls -l\'\n\n'"$START"$'\nsource plugin\n'"$END"$'\nexport EDITOR=vi\n'
    [ "$status" -eq 0 ]
    [ "$output" = "block 3 5" ]
}

@test "a start marker without an end marker is unpaired" {
    scan "$START"$'\nsource plugin\nalias ll=\'ls -l\'\n'
    [ "$status" -eq 1 ]
    [ "$output" = "error unpaired 1" ]
}

@test "an end marker without a start marker is unpaired" {
    scan $'alias ll=\'ls -l\'\nsource plugin\n'"$END"$'\n'
    [ "$status" -eq 1 ]
    [ "$output" = "error unpaired 3" ]
}

@test "an end marker before the start marker is reversed" {
    scan "$END"$'\nsource plugin\n'"$START"$'\n'
    [ "$status" -eq 1 ]
    [ "$output" = "error reversed 1" ]
}

@test "a second start marker is a duplicate" {
    scan "$START"$'\n'"$START"$'\nsource plugin\n'"$END"$'\n'
    [ "$status" -eq 1 ]
    [ "$output" = "error duplicate 2" ]
}

@test "a second block reports both of its markers as duplicates" {
    scan "$START"$'\nsource plugin\n'"$END"$'\nalias ll=\'ls -l\'\n'"$START"$'\nsource plugin\n'"$END"$'\n'
    [ "$status" -eq 1 ]
    [ "$output" = $'error duplicate 5\nerror duplicate 7' ]
}

@test "a marker with trailing spaces is altered" {
    scan "$START"$'  \nsource plugin\n'"$END"$'\n'
    [ "$status" -eq 1 ]
    [ "$output" = $'error altered 1\nerror unpaired 3' ]
}

@test "a marker with trailing text is altered" {
    scan "$START"$'\nsource plugin\n'"$END"$' # end of tlogger\n'
    [ "$status" -eq 1 ]
    [ "$output" = $'error unpaired 1\nerror altered 3' ]
}

@test "a marker with leading space is altered" {
    scan ' '"$START"$'\nsource plugin\n'"$END"$'\n'
    [ "$status" -eq 1 ]
    [ "$output" = $'error altered 1\nerror unpaired 3' ]
}

@test "a block with CRLF lines matches once each CR is removed" {
    scan "$START"$'\r\nsource plugin\r\n'"$END"$'\r\nalias ll=\'ls -l\'\r\n'
    [ "$status" -eq 0 ]
    [ "$output" = "block 1 3" ]
}

@test "a block whose end marker is the last line, without a final newline, is found" {
    scan $'alias ll=\'ls -l\'\n'"$START"$'\nsource plugin\n'"$END"
    [ "$status" -eq 0 ]
    [ "$output" = "block 2 4" ]
}

@test "an rc whose last line has no newline and holds no marker scans as none" {
    scan $'alias ll=\'ls -l\'\nexport EDITOR=vi'
    [ "$status" -eq 0 ]
    [ "$output" = none ]
}

@test "every way of running script outside the block is reported as foreign" {
    # The lines are rc text for awk to read; no shell expands them.
    # shellcheck disable=SC2016
    local -a lines=(
        'script'
        'script -q /tmp/session.log'
        '/usr/bin/script --flush out.raw'
        'exec script -q'
        'true; script -q'
        'true | script -q'
        'true && script -q'
        'true & script -q'
        '( script -q )'
        '{ script -q; }'
        'log=`script -q`'
        'log=$(script -q)'
        $'\tscript -q'
        $'if true; then\tscript -q; fi'
        'true;script -q'
        'true|script -q'
        'true&&script -q'
        'true&script -q'
        '(script -q)'
        '{script -q;}'
        'exec /usr/bin/script -q'
        'x=$(/usr/bin/script -q)'
        'true; script -q # a comment after it'
    )
    local expected=none i
    for i in "${!lines[@]}"; do
        expected+=$'\n'"foreign $(( i + 1 ))"
    done
    scan "$(printf '%s\n' "${lines[@]}")"$'\n'
    [ "$status" -eq 0 ]
    [ "$output" = "$expected" ]
}

@test "words that only contain script, or a different path to it, are not foreign" {
    # The lines are rc text for awk to read; no shell expands them.
    # shellcheck disable=SC2016
    local -a lines=(
        'myscript -q'
        'javascript'
        "zstyle ':completion:*' auto-description 'specify: %d'"
        'script.sh -q'
        'scripts -q'
        '/usr/local/bin/script -q'
        'SCRIPT=1'
        'script=1'
        'echo $script'
        'script;'
    )
    scan "$(printf '%s\n' "${lines[@]}")"$'\n'
    [ "$status" -eq 0 ]
    [ "$output" = none ]
}

@test "script in a comment is not foreign" {
    scan $'# script -q\n    # script -q\nalias ll=\'ls -l\' # script -q\n'
    [ "$status" -eq 0 ]
    [ "$output" = none ]
}

@test "script in a comment that follows ;, | or & without a space is not foreign" {
    scan $'true;# script -q\ntrue;#script\ntrue &# script -q\ntrue |# script -q\n'
    [ "$status" -eq 0 ]
    [ "$output" = none ]
}

@test "a script line inside the block is not foreign" {
    scan "$START"$'\nscript -q\n'"$END"$'\n'
    [ "$status" -eq 0 ]
    [ "$output" = "block 1 3" ]
}

@test "a foreign line below the block comes after the block line" {
    scan "$START"$'\nsource plugin\n'"$END"$'\nalias ll=\'ls -l\'\nscript -q /tmp/session.log\n'
    [ "$status" -eq 0 ]
    [ "$output" = $'block 1 3\nforeign 5' ]
}

@test "a script line with a CRLF end is foreign" {
    scan $'script -q\r\nscript\r\n'
    [ "$status" -eq 0 ]
    [ "$output" = $'none\nforeign 1\nforeign 2' ]
}
