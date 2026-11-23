#!/usr/bin/env bats
# Tests for tlogger install --remove-block, --block-sha256 and --quarantine, on synthetic rc files
# in the test's own HOME: the cut, the fingerprint, the refusals, the move of a stale backup and
# the undo. Without a real zsh, tests/stub-bin/zsh answers what bin/tlogger asks zsh.

# Code passed to run_with runs in a child, which expands it. Each test sets BEFORE for itself.
# shellcheck disable=SC2016,SC2030,SC2031

bats_require_minimum_version 1.5.0

load helpers

OLD_START='# BEGIN example-recorder'
OLD_END='# END example-recorder'
OLD_BODY='script -q -f /tmp/example-recorder.log'

# Run before each test by bats.
# Gives the test its own HOME with the default zsh and XDG layout, and sets the paths it checks.
setup() {
    isolate_home
    isolate_tlogger
    RC="$HOME/.zshrc"
    DATA="$HOME/.local/share/tlogger"
    CONF="$HOME/.config/tlogger"
    STATE="$HOME/.local/state/tlogger"
    QDIR="$STATE/quarantine"
    STALE="$HOME/.zshrc.example-backup"
    OWN=$(cat "$GOLDEN_BLOCK"; printf x)
    OWN=${OWN%x}
}

# Print the old block with the line end EOL, LF by default.
old_block() {
    local eol=${1-$'\n'}
    printf '%s%s' "$OLD_START" "$eol" "$OLD_BODY" "$eol" "$OLD_END" "$eol"
}

# Write the rc alias a=1, the old block, alias z=2, and remember its SHA-256 in BEFORE.
simple_rc() {
    { printf 'alias a=1\n'; old_block; printf 'alias z=2\n'; } > "$RC"
    BEFORE=$(sha_of "$RC")
}

# Write a stale backup of the older logger, with a line that must never reach the rc.
stale_file() {
    printf 'stale-backup-content\n' > "${1:-$STALE}"
}

# Run a dry run of the removal, passing on ARGS.
run_plan() {
    run_tlogger install --mode manual --dry-run --remove-block "$OLD_START" "$OLD_END" "$@"
}

# Set FP to the fingerprint a dry run prints.
fingerprint() {
    run_plan
    [ "$status" -eq 0 ] || return 1
    FP=$(sed -n 's/^  old block: .*sha256 \([0-9a-f]\{64\}\)$/\1/p' <<< "$output")
    [ "${#FP}" -eq 64 ]
}

# Do what a user does: a dry run for the fingerprint, then the real run with ARGS added.
migrate() {
    fingerprint || return 1
    run_tlogger install --mode manual --yes --remove-block "$OLD_START" "$OLD_END" \
        --block-sha256 "$FP" "$@"
}

# Run main of bin/tlogger with ARGS, in a bash that first evaluates the function definitions in
# OVERRIDES, so that a test can act at one exact step. Same contract as run_tlogger.
run_with() {
    local overrides=$1
    shift
    require_test_home || return 1
    # shellcheck disable=SC2016 # The child expands these.
    run --separate-stderr bash -c 'source "$1"; eval "$2"; shift 2; main "$@"' _ \
        "$TLOGGER" "$overrides" "$@" < /dev/null
}

# Fail if the last run printed the test's HOME in full.
refute_home_shown() {
    if [[ $output == *"$HOME"* || $stderr == *"$HOME"* ]]; then
        printf 'the output names the home folder in full:\n%s\n%s\n' "$output" "$stderr" >&2
        return 1
    fi
}

# Fail if the last run printed the marker text in a message.
refute_markers_shown() {
    if [[ $stderr == *example-recorder* ]]; then
        printf 'a message holds the marker text:\n%s\n' "$stderr" >&2
        return 1
    fi
}

# Fail unless the last run exited STATUS, left the rc byte-identical to BEFORE, created no tlogger
# folder or temp file, and kept the marker text and the home path out of its messages.
assert_refused() {
    [ "$status" -eq "$1" ]
    [[ $stderr != *"unknown option"* ]]
    [ "$(sha_of "$RC")" = "$BEFORE" ]
    refute_tlogger_folders
    refute_temp_left
    refute_markers_shown
    refute_home_shown
}

# Print the one saved block in the quarantine folder, or fail.
saved_block() {
    local -a files=("$QDIR"/removed-block.L*)
    if (( ${#files[@]} != 1 )) || [[ ! -f ${files[0]} ]]; then
        printf 'expected one saved block, found: %s\n' "${files[*]}" >&2
        return 1
    fi
    printf '%s\n' "${files[0]}"
}

# Print the one quarantined copy of the stale backup, or fail.
moved_stale() {
    local -a files=("$QDIR/${STALE##*/}".*)
    if (( ${#files[@]} != 1 )) || [[ ! -f ${files[0]} ]]; then
        printf 'expected one moved file, found: %s\n' "${files[*]}" >&2
        return 1
    fi
    printf '%s\n' "${files[0]}"
}

# Print the number of rc backups in the state folder.
count_backups() {
    local -a files=("$STATE/rc-backups"/zshrc.*)
    if [[ -e ${files[0]} ]]; then
        printf '%s\n' "${#files[@]}"
    else
        printf '0\n'
    fi
}

# Build an rc from the line end EOL and the last line's own end LAST, with the tlogger block at
# WHERE (absent, above or below), migrate it, and fail unless every byte outside the old block is
# kept, the rc was written once with one backup, and the saved block holds the exact bytes.
check_cut() {
    local eol=$1 last=$2 where=$3 first second old before after
    first="alias a=1$eol"
    second="alias z=2$last"
    old=$(old_block "$eol"; printf x)
    old=${old%x}
    case $where in
        absent) before=$first$old$second after=$OWN$first$second ;;
        above) before=$OWN$first$old$second after=$OWN$first$second ;;
        below) before=$first$old$OWN$second after=$first$OWN$second ;;
    esac
    printf '%s' "$before" > "$RC"
    printf '%s' "$before" > "$BATS_TEST_TMPDIR/original"
    printf '%s' "$after" > "$BATS_TEST_TMPDIR/expected"
    printf '%s' "$old" > "$BATS_TEST_TMPDIR/old"
    migrate
    [ "$status" -eq 0 ]
    cmp "$RC" "$BATS_TEST_TMPDIR/expected"
    [ "$(count_backups)" -eq 1 ]
    cmp "$STATE/rc-backups"/zshrc.* "$BATS_TEST_TMPDIR/original"
    cmp "$(saved_block)" "$BATS_TEST_TMPDIR/old"
    [ "$FP" = "$(sha_of "$BATS_TEST_TMPDIR/old")" ]
    refute_home_shown
    refute_temp_left
}

# Migrate an rc with the tlogger block at WHERE, uninstall, run the undo commands the real run
# printed, and fail unless the rc is the original without any tlogger block, byte for byte.
check_undo() {
    local where=$1 first=$'alias a=1\r\n' second=$'alias z=2' old before original undo
    old=$(old_block; printf x)
    old=${old%x}
    case $where in
        absent) before=$first$old$second ;;
        above) before=$OWN$first$old$second ;;
        below) before=$first$old$OWN$second ;;
    esac
    original=$first$old$second
    printf '%s' "$before" > "$RC"
    printf '%s' "$original" > "$BATS_TEST_TMPDIR/original"
    migrate
    [ "$status" -eq 0 ]
    undo=$(undo_commands)
    [[ $undo == *"~/.local/share/tlogger/current/bin/tlogger uninstall &&"* ]]
    # A person answers uninstall's question at the terminal; this shell has none, so it passes --yes.
    undo=${undo/ uninstall &&/' uninstall --yes &&'}
    [[ $undo == *" uninstall --yes &&"* ]]
    bash -c "$undo" < /dev/null
    [ -f "$(saved_block)" ]
    cmp "$RC" "$BATS_TEST_TMPDIR/original"
    [ ! -e "$RC.undo" ]
}

# Print the undo commands of the last run, from the uninstall line to the end of the restore.
undo_commands() {
    sed -n '/ uninstall &&$/,/rm .*undo )$/p' <<< "$output"
}

@test "a marker that is empty, blank or holds a control character exits 2" {
    simple_rc
    local bad
    for bad in '' '   ' $'\t' $'# BEGIN\texample' $'# BEGIN example\r' $'# BEGIN\nexample' \
        $'# BEGIN \e[31m'; do
        run_tlogger install --mode manual --dry-run --remove-block "$bad" "$OLD_END"
        assert_refused 2
        run_tlogger install --mode manual --dry-run --remove-block "$OLD_START" "$bad"
        assert_refused 2
    done
}

@test "two equal markers, or one equal to tlogger's own, exit 2" {
    simple_rc
    run_tlogger install --mode manual --dry-run --remove-block "$OLD_START" "$OLD_START"
    assert_refused 2
    run_tlogger install --mode manual --dry-run --remove-block '# >>> tlogger >>>' "$OLD_END"
    assert_refused 2
    run_tlogger install --mode manual --dry-run --remove-block "$OLD_START" '# <<< tlogger <<<'
    assert_refused 2
    run_tlogger install --mode manual --dry-run --remove-block '# <<< tlogger <<<' "$OLD_END"
    assert_refused 2
    run_tlogger install --mode manual --dry-run --remove-block "$OLD_START" '# >>> tlogger >>>'
    assert_refused 2
}

@test "--remove-block without two values exits 2" {
    simple_rc
    run_tlogger install --mode manual --dry-run --remove-block "$OLD_START"
    assert_refused 2
    run_tlogger install --mode manual --dry-run --remove-block
    assert_refused 2
}

@test "--yes with --remove-block and no fingerprint exits 2 outside a dry run" {
    simple_rc
    run_tlogger install --mode manual --yes --remove-block "$OLD_START" "$OLD_END"
    assert_refused 2
    [[ $stderr == *"--block-sha256"* ]]
}

@test "a fingerprint that is not 64 hex characters exits 2" {
    simple_rc
    local bad
    for bad in '' abc "$(printf 'g%.0s' {1..64})" "$(printf 'a%.0s' {1..63})" \
        "$(printf 'a%.0s' {1..65})"; do
        run_tlogger install --mode manual --yes --remove-block "$OLD_START" "$OLD_END" \
            --block-sha256 "$bad"
        assert_refused 2
    done
}

@test "--block-sha256 without --remove-block exits 2" {
    simple_rc
    run_tlogger install --mode manual --yes --block-sha256 "$(printf 'a%.0s' {1..64})"
    assert_refused 2
}

@test "--print-only with any of the new options exits 2" {
    simple_rc
    stale_file
    run_tlogger install --print-only --remove-block "$OLD_START" "$OLD_END"
    assert_refused 2
    run_tlogger install --print-only --quarantine "$STALE"
    assert_refused 2
    run_tlogger install --print-only --block-sha256 "$(printf 'a%.0s' {1..64})"
    assert_refused 2
}

@test "a repeated new option exits 2" {
    simple_rc
    stale_file
    run_tlogger install --mode manual --dry-run --remove-block "$OLD_START" "$OLD_END" \
        --remove-block "$OLD_START" "$OLD_END"
    assert_refused 2
    run_tlogger install --mode manual --dry-run --quarantine "$STALE" --quarantine "$STALE"
    assert_refused 2
    run_tlogger install --mode manual --dry-run --remove-block "$OLD_START" "$OLD_END" \
        --block-sha256 "$(printf 'a%.0s' {1..64})" --block-sha256 "$(printf 'a%.0s' {1..64})"
    assert_refused 2
}

@test "--quarantine without a file exits 2" {
    simple_rc
    run_tlogger install --mode manual --dry-run --quarantine
    assert_refused 2
    run_tlogger install --mode manual --dry-run --quarantine ''
    assert_refused 2
}

@test "--remove-block takes the next two arguments literally" {
    printf 'alias a=1\n--yes\nsource old\n--mode\nalias z=2\n' > "$RC"
    BEFORE=$(sha_of "$RC")
    run_tlogger install --mode manual --dry-run --remove-block --yes --mode
    [ "$status" -eq 0 ]
    [[ $output == *"old block at lines 2-4 removed"* ]]
    [ "$(sha_of "$RC")" = "$BEFORE" ]
    refute_tlogger_folders
}

@test "a missing rc exits 3 and never scans the skel file" {
    local skel="$BATS_TEST_TMPDIR/skel"
    { old_block; } > "$skel"
    stale_file
    TLOGGER_SKEL=$skel run_tlogger install --mode manual --yes --remove-block "$OLD_START" \
        "$OLD_END" --block-sha256 "$(sha_of "$skel")" --quarantine "$STALE"
    [ "$status" -eq 3 ]
    [ ! -e "$RC" ]
    [ -f "$STALE" ]
    refute_tlogger_folders
    refute_temp_left
    refute_markers_shown
    [[ $stderr == *"not moved"* ]]
    [[ $stderr == *"install --quarantine ~/.zshrc.example-backup"* ]]
}

@test "an rc with neither marker exits 3, and says the stale backup was not moved" {
    printf 'alias a=1\n' > "$RC"
    BEFORE=$(sha_of "$RC")
    stale_file
    run_tlogger install --mode manual --dry-run --remove-block "$OLD_START" "$OLD_END" \
        --quarantine "$STALE"
    assert_refused 3
    [ -f "$STALE" ]
    [[ $stderr == *"not moved"* ]]
    [[ $stderr == *"check both marker lines"* ]]
    [[ $stderr != *"install --quarantine"* ]]
}

@test "a mistyped marker gets no command that would put tlogger beside the old block" {
    simple_rc
    stale_file
    run_tlogger install --mode manual --yes --remove-block '# BEGIN mistyped' '# END mistyped' \
        --block-sha256 "$(printf 'a%.0s' {1..64})" --quarantine "$STALE"
    assert_refused 3
    [ -f "$STALE" ]
    [[ $stderr == *"check both marker lines"* ]]
    [[ $stderr != *"install --quarantine"* ]]
}

@test "without --quarantine, exit 3 names no follow-up" {
    printf 'alias a=1\n' > "$RC"
    BEFORE=$(sha_of "$RC")
    run_tlogger install --mode manual --dry-run --remove-block "$OLD_START" "$OLD_END"
    assert_refused 3
    [[ $stderr != *"--quarantine"* ]]
    [[ $stderr != *"check both marker lines"* ]]
}

@test "--quarantine=FILE and --block-sha256=HASH work like the two-word forms" {
    need symlinks
    simple_rc
    stale_file
    fingerprint
    run_tlogger install --mode manual --yes --remove-block "$OLD_START" "$OLD_END" \
        "--block-sha256=$FP" "--quarantine=$STALE"
    [ "$status" -eq 0 ]
    [ ! -e "$STALE" ]
    grep -qx 'stale-backup-content' "$(moved_stale)"
    run grep -cF "$OLD_BODY" "$RC"
    [ "$output" = 0 ]
}

@test "an empty --quarantine= or --block-sha256= exits 2" {
    simple_rc
    run_tlogger install --mode manual --dry-run --quarantine=
    assert_refused 2
    [[ $stderr == *"--quarantine needs a file"* ]]
    run_tlogger install --mode manual --dry-run --remove-block "$OLD_START" "$OLD_END" \
        --block-sha256=
    assert_refused 2
    [[ $stderr == *"64 hex characters"* ]]
}

@test "after --remove-block a mistyped option is named, and a stray word is not repeated" {
    simple_rc
    run_tlogger install --mode manual --remove-block "$OLD_START" "$OLD_END" --dryrun=value
    [ "$status" -eq 2 ]
    [[ $stderr == *"unknown option for install: --dryrun"* ]]
    [[ $stderr != *"quote both markers"* ]]
    [[ $stderr != *value* ]]
    run_tlogger install --mode manual --remove-block "$OLD_START" "$OLD_END" stray-word
    [ "$status" -eq 2 ]
    [[ $stderr == *"quote both markers"* ]]
    [[ $stderr != *stray-word* ]]
    [ "$(sha_of "$RC")" = "$BEFORE" ]
    refute_tlogger_folders
}

@test "a stale backup name too long for the quarantine folder is refused before any write" {
    local long wide
    simple_rc
    # 232 bytes, and 116 two-byte characters: the suffix of 24 bytes takes either past 255.
    printf -v long '%*s' 232 ''
    long=${long// /b}
    printf -v wide '%*s' 116 ''
    wide=${wide// /$'\xc3\xa9'}
    fingerprint
    for name in "$long" "$wide"; do
        stale_file "$HOME/$name"
        run_tlogger install --mode manual --yes --remove-block "$OLD_START" "$OLD_END" \
            --block-sha256 "$FP" --quarantine "$HOME/$name"
        assert_refused 1
        [[ $stderr == *"file name is too long"* ]]
        [ -f "$HOME/$name" ]
    done
}

@test "the name limit is the one of the file system that holds the quarantine folder" {
    local name
    simple_rc
    mkdir -p "$HOME/bin"
    printf '#!/bin/sh\necho 143\n' > "$HOME/bin/getconf"
    chmod +x "$HOME/bin/getconf"
    printf -v name '%*s' 120 ''
    name=${name// /b}
    stale_file "$HOME/$name"
    PATH="$HOME/bin:$PATH" run_tlogger install --mode manual --dry-run \
        --remove-block "$OLD_START" "$OLD_END" --quarantine "$HOME/$name"
    assert_refused 1
    [[ $stderr == *"file name is too long"* ]]
}

@test "the longest stale backup name that fits is moved" {
    need symlinks
    local name
    simple_rc
    printf -v name '%*s' 231 ''
    name=${name// /b}
    STALE="$HOME/$name"
    stale_file
    migrate --quarantine "$STALE"
    [ "$status" -eq 0 ]
    [ ! -e "$STALE" ]
    grep -qx 'stale-backup-content' "$(moved_stale)"
}

@test "a missing marker, a duplicate, a reversed pair or an altered line exits 1 at its line" {
    printf 'alias a=1\n%s\n' "$OLD_START" > "$RC"
    BEFORE=$(sha_of "$RC")
    run_plan
    assert_refused 1
    [[ $stderr == *"line 2: unpaired"* ]]
    printf 'alias a=1\n%s\n' "$OLD_END" > "$RC"
    BEFORE=$(sha_of "$RC")
    run_plan
    assert_refused 1
    [[ $stderr == *"line 2: unpaired"* ]]
    printf '%s\n%s\n%s\n' "$OLD_START" "$OLD_END" "$OLD_END" > "$RC"
    BEFORE=$(sha_of "$RC")
    run_plan
    assert_refused 1
    [[ $stderr == *"line 3: duplicate"* ]]
    printf '%s\nalias a=1\n%s\n' "$OLD_END" "$OLD_START" > "$RC"
    BEFORE=$(sha_of "$RC")
    run_plan
    assert_refused 1
    [[ $stderr == *"line 1: reversed"* ]]
    printf '%s v2\nalias a=1\n%s\n' "$OLD_START" "$OLD_END" > "$RC"
    BEFORE=$(sha_of "$RC")
    run_plan
    assert_refused 1
    [[ $stderr == *"line 1: altered"* ]]
}

@test "the cut keeps every byte of an LF rc without a tlogger block" {
    need symlinks
    check_cut $'\n' $'\n' absent
}

@test "the cut keeps every byte of an LF rc with the tlogger block above" {
    need symlinks
    check_cut $'\n' $'\n' above
}

@test "the cut keeps every byte of an LF rc with the tlogger block below" {
    need symlinks
    check_cut $'\n' $'\n' below
}

@test "the cut keeps every byte of a CRLF rc without a tlogger block" {
    need symlinks
    check_cut $'\r\n' $'\r\n' absent
}

@test "the cut keeps every byte of a CRLF rc with the tlogger block above" {
    need symlinks
    check_cut $'\r\n' $'\r\n' above
}

@test "the cut keeps every byte of a CRLF rc with the tlogger block below" {
    need symlinks
    check_cut $'\r\n' $'\r\n' below
}

@test "the cut keeps every byte of an rc without a final newline and no tlogger block" {
    need symlinks
    check_cut $'\n' '' absent
}

@test "the cut keeps every byte of an rc without a final newline, tlogger block above" {
    need symlinks
    check_cut $'\n' '' above
}

@test "the cut keeps every byte of an rc without a final newline, tlogger block below" {
    need symlinks
    check_cut $'\n' '' below
}

@test "an old block on the last lines, without a final newline, is cut exactly" {
    need symlinks
    printf 'alias a=1\n%s\n%s\n%s' "$OLD_START" "$OLD_BODY" "$OLD_END" > "$RC"
    migrate
    [ "$status" -eq 0 ]
    printf 'alias a=1\n' | cat "$GOLDEN_BLOCK" - | cmp - "$RC"
    printf '%s\n%s\n%s' "$OLD_START" "$OLD_BODY" "$OLD_END" | cmp - "$(saved_block)"
    [ "$FP" = "$(sha_of "$(saved_block)")" ]
}

@test "the rc is written once, for the cut and the block together" {
    need symlinks
    simple_rc
    fingerprint
    # shellcheck disable=SC2016 # The child expands these.
    run_with 'eval "real_$(declare -f write_rc)"
        write_rc() { printf x >> "$HOME/writes"; real_write_rc "$@"; }' \
        install --mode manual --yes --remove-block "$OLD_START" "$OLD_END" --block-sha256 "$FP"
    [ "$status" -eq 0 ]
    [ "$(cat "$HOME/writes")" = x ]
    [ "$(count_backups)" -eq 1 ]
}

@test "an outdated tlogger block is updated in the same write" {
    need symlinks
    printf '# >>> tlogger >>>\n# an older body\n# <<< tlogger <<<\nalias a=1\n' > "$RC"
    old_block >> "$RC"
    printf 'alias z=2\n' >> "$RC"
    migrate
    [ "$status" -eq 0 ]
    printf 'alias a=1\nalias z=2\n' | cat "$GOLDEN_BLOCK" - | cmp - "$RC"
    [ "$(count_backups)" -eq 1 ]
}

@test "the saved block's name holds the line it goes back to" {
    need symlinks
    local name
    { cat "$GOLDEN_BLOCK"; printf 'alias a=1\n'; old_block; } > "$RC"
    migrate
    [ "$status" -eq 0 ]
    name=$(saved_block)
    name=${name##*/}
    # Line 6 in the file, line 2 once the 4 lines of tlogger's block are out.
    [[ $name =~ ^removed-block\.L2\.[0-9]{8}T[0-9]{6}Z\.[A-Za-z0-9]{6}$ ]]
}

@test "the old block no longer blocks install, and a script line outside it still does" {
    { printf 'alias a=1\n'; old_block; printf 'alias b=2\nscript -q /tmp/other.log\n'; } > "$RC"
    BEFORE=$(sha_of "$RC")
    run_plan
    assert_refused 1
    [[ $stderr == *"at line 6"* ]]
    { printf 'alias a=1\n'; old_block; printf 'alias b=2\n'; } > "$RC"
    run_plan
    [ "$status" -eq 0 ]
}

@test "an exported range cannot hide a script line from a plain install" {
    printf 'script -q /tmp/other.log\n' > "$RC"
    BEFORE=$(sha_of "$RC")
    RCBLOCK_SKIP_FROM=1 RCBLOCK_SKIP_TO=9 run_tlogger install --mode manual --dry-run
    assert_refused 1
    [[ $stderr == *"at line 1"* ]]
}

@test "a tlogger block inside the old block is refused" {
    { printf '%s\n' "$OLD_START"; cat "$GOLDEN_BLOCK"; printf '%s\n' "$OLD_END"; } > "$RC"
    BEFORE=$(sha_of "$RC")
    run_plan
    assert_refused 1
    [[ $stderr == *"lines 2-5"* ]]
}

@test "a tlogger block around the old block is refused" {
    { head -n 3 "$GOLDEN_BLOCK"; old_block; tail -n 1 "$GOLDEN_BLOCK"; } > "$RC"
    BEFORE=$(sha_of "$RC")
    run_plan
    assert_refused 1
}

@test "a tlogger block that crosses the start of the old block is refused" {
    { head -n 3 "$GOLDEN_BLOCK"; printf '%s\n' "$OLD_START"; tail -n 1 "$GOLDEN_BLOCK"
        printf '%s\n%s\n' "$OLD_BODY" "$OLD_END"; } > "$RC"
    BEFORE=$(sha_of "$RC")
    run_plan
    assert_refused 1
}

@test "a tlogger block that crosses the end of the old block is refused" {
    { printf '%s\n%s\n' "$OLD_START" "$OLD_BODY"; head -n 3 "$GOLDEN_BLOCK"
        printf '%s\n' "$OLD_END"; tail -n 1 "$GOLDEN_BLOCK"; } > "$RC"
    BEFORE=$(sha_of "$RC")
    run_plan
    assert_refused 1
}

@test "a cut that would break the rc's syntax is refused" {
    need zsh
    printf 'if true; then\n%s\nfi\n%s\n' "$OLD_START" "$OLD_END" > "$RC"
    BEFORE=$(sha_of "$RC")
    run_plan
    assert_refused 1
    [[ $stderr == *"zsh -n"* ]]
}

@test "a dry run shows the range, the full fingerprint and the diff, and writes nothing" {
    simple_rc
    local sum
    sum=$(old_block | sha_of /dev/stdin)
    run_plan
    [ "$status" -eq 0 ]
    [[ $output == *"old block at lines 2-4 removed; tlogger block added at lines 1-4"* ]]
    grep -qxF "  old block: 3 lines, sha256 $sum" <<< "$output"
    grep -qF '  saved to:  ~/.local/state/tlogger/quarantine/removed-block.L2.' <<< "$output"
    grep -qxF -- "-$OLD_START" <<< "$output"
    grep -qxF -- "-$OLD_BODY" <<< "$output"
    grep -qxF -- "-$OLD_END" <<< "$output"
    grep -qxF -- '+# >>> tlogger >>>' <<< "$output"
    [[ $stderr == *"dry run: nothing was written"* ]]
    assert_refused 0
}

@test "a dry run works with --yes and no fingerprint, and needs no temp folder" {
    simple_rc
    TMPDIR="$HOME/no-such-tmp" run_tlogger install --mode manual --dry-run --yes \
        --remove-block "$OLD_START" "$OLD_END"
    [ "$status" -eq 0 ]
    [ ! -e "$HOME/no-such-tmp" ]
    assert_refused 0
}

@test "a dry run checks a fingerprint when one is given" {
    simple_rc
    run_plan --block-sha256 "$(printf 'a%.0s' {1..64})"
    assert_refused 1
}

@test "a dry run refuses when the rc changes while the diff is shown" {
    simple_rc
    run_with 'show_diff() { printf "# edited\n" >> "$HOME/.zshrc"; }' install --mode manual \
        --dry-run --remove-block "$OLD_START" "$OLD_END"
    [ "$status" -eq 1 ]
    [[ $stderr == *"changed"* ]]
    [[ $stderr != *"nothing was written"* ]]
    refute_tlogger_folders
    refute_temp_left
}

@test "a dry run refuses when the rc disappears while the diff is shown, and names no full path" {
    simple_rc
    run_with 'show_diff() { command rm -f -- "$HOME/.zshrc"; }' install --mode manual \
        --dry-run --remove-block "$OLD_START" "$OLD_END"
    [ "$status" -eq 1 ]
    [[ $stderr == *"changed"* ]]
    [[ $stderr != *"nothing was written"* ]]
    refute_home_shown
    refute_tlogger_folders
}

@test "the fingerprint covers CRLF line ends byte for byte" {
    need symlinks
    { printf 'alias a=1\r\n'; old_block $'\r\n'; } > "$RC"
    old_block $'\r\n' > "$BATS_TEST_TMPDIR/crlf"
    old_block > "$BATS_TEST_TMPDIR/lf"
    fingerprint
    [ "$FP" = "$(sha_of "$BATS_TEST_TMPDIR/crlf")" ]
    [ "$FP" != "$(sha_of "$BATS_TEST_TMPDIR/lf")" ]
    run_tlogger install --mode manual --yes --remove-block "$OLD_START" "$OLD_END" \
        --block-sha256 "$FP"
    [ "$status" -eq 0 ]
}

@test "an upper-case fingerprint matches" {
    need symlinks
    simple_rc
    fingerprint
    run_tlogger install --mode manual --yes --remove-block "$OLD_START" "$OLD_END" \
        --block-sha256 "${FP^^}"
    [ "$status" -eq 0 ]
}

@test "a block changed by one byte is refused and the rc stays identical" {
    simple_rc
    fingerprint
    { printf 'alias a=1\n%s\n%s \n%s\nalias z=2\n' "$OLD_START" "$OLD_BODY" "$OLD_END"; } > "$RC"
    BEFORE=$(sha_of "$RC")
    run_tlogger install --mode manual --yes --remove-block "$OLD_START" "$OLD_END" \
        --block-sha256 "$FP"
    assert_refused 1
    [[ $stderr == *"fingerprint"* ]]
}

@test "the question names the block's removal and the file's move" {
    # shellcheck disable=SC2016 # The child expands these.
    run bash -c 'source "$1"; HOME=/home/kali RC=/home/kali/.zshrc
        QUARANTINE_DIR=/home/kali/.local/state/tlogger/quarantine RC_CHANGED=1 SCAN_START=0
        OPT_REMOVE=1 LEGACY_FROM=12 LEGACY_TO=63 OPT_QUARANTINE=/home/kali/.zshrc.example-backup
        install_question' _ "$TLOGGER" < /dev/null
    [ "$status" -eq 0 ]
    [[ $output == *"old block at lines 12-63"* ]]
    [[ $output == *"move ~/.zshrc.example-backup"* ]]
    [[ $output == *"?" ]]
}

@test "the question says keep for a current tlogger block and update for an outdated one" {
    { cat "$GOLDEN_BLOCK"; printf 'alias a=1\n'; old_block; } > "$RC"
    fingerprint
    run_with 'confirm() { printf "question: %s\n" "$1"; exit 0; }' install --mode manual --yes \
        --remove-block "$OLD_START" "$OLD_END" --block-sha256 "$FP"
    [ "$status" -eq 0 ]
    [[ $output == *"question: Remove the old block at lines 6-8 of ~/.zshrc, keep the tlogger block"* ]]
    [[ $output != *"update the tlogger block"* ]]
    { sed '2s/.*/# An outdated block./' "$GOLDEN_BLOCK"; printf 'alias a=1\n'; old_block; } > "$RC"
    fingerprint
    run_with 'confirm() { printf "question: %s\n" "$1"; exit 0; }' install --mode manual --yes \
        --remove-block "$OLD_START" "$OLD_END" --block-sha256 "$FP"
    [ "$status" -eq 0 ]
    [[ $output == *"question: Remove the old block at lines 6-8 of ~/.zshrc, update the tlogger block"* ]]
}

@test "an rc edited while the question waits stops the run before the code is written" {
    simple_rc
    fingerprint
    run_with 'confirm() { printf "# edited\n" >> "$HOME/.zshrc"; }' install --mode manual --yes \
        --remove-block "$OLD_START" "$OLD_END" --block-sha256 "$FP"
    [ "$status" -eq 1 ]
    [[ $stderr == *"changed"* ]]
    refute_tlogger_folders
    refute_temp_left
    { printf 'alias a=1\n'; old_block; printf 'alias z=2\n# edited\n'; } | cmp - "$RC"
}

@test "an rc edited after the second compare is not written, and the message says why" {
    need symlinks
    simple_rc
    stale_file
    fingerprint
    run_with 'install_state() { mkdir -p "$STATE_DIR/rc-backups"; printf "# edited\n" >> "$HOME/.zshrc"; }' \
        install --mode manual --yes --remove-block "$OLD_START" "$OLD_END" --block-sha256 "$FP" \
        --quarantine "$STALE"
    [ "$status" -eq 1 ]
    [[ $stderr == *"changed while tlogger was working"* ]]
    [[ $stderr != *"nothing changed"* ]]
    { printf 'alias a=1\n'; old_block; printf 'alias z=2\n# edited\n'; } | cmp - "$RC"
    [ -f "$STALE" ]
    # The saved block goes again, since the rc still holds the block.
    [ -z "$(find "$QDIR" -type f 2> /dev/null)" ]
}

@test "a symlinked rc gets the edits printed bottom-up and is not written" {
    need symlinks
    mkdir -p "$HOME/dotfiles"
    { printf 'alias a=1\n'; old_block; printf '# >>> tlogger >>>\n# old\n# <<< tlogger <<<\n'; } \
        > "$HOME/dotfiles/zshrc"
    BEFORE=$(sha_of "$HOME/dotfiles/zshrc")
    ln -s dotfiles/zshrc "$RC"
    stale_file
    run_plan --quarantine "$STALE"
    [ "$status" -eq 1 ]
    [ -L "$RC" ]
    [ "$(sha_of "$HOME/dotfiles/zshrc")" = "$BEFORE" ]
    [ "$output" = "$(cat "$GOLDEN_BLOCK")" ]
    [[ $stderr == *"is a symlink"* ]]
    [[ $stderr == *"1. replace lines 5-7"* ]]
    [[ $stderr == *"2. delete lines 2-4"* ]]
    [[ $stderr == *"install --quarantine ~/.zshrc.example-backup"* ]]
    [ -f "$STALE" ]
    refute_tlogger_folders
    refute_markers_shown
    refute_home_shown
}

@test "a symlinked rc with the block above gets the deletion first" {
    need symlinks
    mkdir -p "$HOME/dotfiles"
    { printf '# >>> tlogger >>>\n# old\n# <<< tlogger <<<\n'; old_block; } > "$HOME/dotfiles/zshrc"
    ln -s dotfiles/zshrc "$RC"
    run_plan
    [ "$status" -eq 1 ]
    [[ $stderr == *"1. delete lines 4-6"* ]]
    [[ $stderr == *"2. replace lines 1-3"* ]]
}

@test "a symlinked rc without a block deletes first and adds at the top last" {
    need symlinks
    mkdir -p "$HOME/dotfiles"
    { printf 'alias a=1\n'; old_block; } > "$HOME/dotfiles/zshrc"
    ln -s dotfiles/zshrc "$RC"
    run_plan
    [ "$status" -eq 1 ]
    [[ $stderr == *"1. delete lines 2-4"* ]]
    [[ $stderr == *"2. add"*"at the very top"* ]]
}

@test "a symlinked rc with an up-to-date block needs only the deletion" {
    need symlinks
    mkdir -p "$HOME/dotfiles"
    { cat "$GOLDEN_BLOCK"; old_block; } > "$HOME/dotfiles/zshrc"
    ln -s dotfiles/zshrc "$RC"
    run_plan
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ $stderr == *"1. delete lines 5-7"* ]]
    [[ $stderr != *"  2. "* ]]
}

@test "an rc that cannot be read says the old block could not be located" {
    need symlinks
    ln -s no-such-target "$RC"
    run_plan
    [ "$status" -eq 1 ]
    [[ $stderr == *"could not locate the old block"* ]]
    [[ $stderr == *"by hand"* ]]
    [ -L "$RC" ]
    refute_tlogger_folders
    refute_temp_left
}

@test "a regular rc without read permission says the old block could not be located" {
    need modes
    simple_rc
    stale_file
    # Writable and unreadable, so that it counts as a regular rc until the read.
    chmod 200 "$RC"
    run_plan --quarantine "$STALE"
    chmod 644 "$RC"
    [ "$status" -eq 1 ]
    [[ $stderr == *"cannot be read, so tlogger does not edit it"* ]]
    [[ $stderr == *"could not locate the old block"* ]]
    [[ $stderr == *"by hand"* ]]
    [[ $stderr == *"install --quarantine ~/.zshrc.example-backup"* ]]
    [ "$(sha_of "$RC")" = "$BEFORE" ]
    [ -f "$STALE" ]
    refute_tlogger_folders
    refute_temp_left
    refute_markers_shown
    refute_home_shown
}

@test "an rc without write permission gets the edits and is not written" {
    need modes
    simple_rc
    chmod 444 "$RC"
    run_plan
    [ "$status" -eq 1 ]
    [[ $stderr == *"is not writable"* ]]
    [[ $stderr == *"delete lines 2-4"* ]]
    [ "$(sha_of "$RC")" = "$BEFORE" ]
    [ "$(stat -c %a "$RC")" = 444 ]
    refute_tlogger_folders
}

# bats test_tags=root
@test "another user's rc gets the edits and is not written" {
    if (( EUID != 0 )); then
        skip "it runs only as root"
    fi
    simple_rc
    chown nobody "$RC"
    run_with 'refuse_foreign_root() { :; }; refuse_foreign_root_paths() { :; }' install \
        --mode manual --dry-run --remove-block "$OLD_START" "$OLD_END"
    [ "$status" -eq 1 ]
    [[ $stderr == *"belongs to another user"* ]]
    [[ $stderr == *"delete lines 2-4"* ]]
    [ "$(sha_of "$RC")" = "$BEFORE" ]
}

@test "a hard-linked rc keeps both names through the cut" {
    need symlinks
    need hardlinks
    simple_rc
    ln "$RC" "$HOME/zshrc-link"
    migrate
    [ "$status" -eq 0 ]
    [ "$(stat -c %h "$RC")" -eq 2 ]
    printf 'alias a=1\nalias z=2\n' | cat "$GOLDEN_BLOCK" - | cmp - "$RC"
    cmp "$RC" "$HOME/zshrc-link"
}

@test "the in-place write of a hard-linked rc ignores QUIT and restores its default" {
    need hardlinks
    local probe="$BATS_TEST_TMPDIR/quit-trap" new="$BATS_TEST_TMPDIR/new"
    mkdir -p "$BATS_TEST_TMPDIR/backups"
    printf 'old\n' > "$RC"
    ln "$RC" "$HOME/zshrc-link"
    cp "$RC" "$BATS_TEST_TMPDIR/old-rc"
    printf 'new\n' > "$new"
    # shellcheck disable=SC2016 # The child expands these.
    run bash -c 'source "$1"; set -euo pipefail; RC=$2 OLD_RC=$3 BACKUP_DIR=$4 ZDOT=$HOME
        RC_STATE=regular PROBE=$5 NEW=$6
        cat() { if [[ ${2-} == "$NEW" ]]; then trap -p QUIT > "$PROBE"; fi; command cat "$@"; }
        write_rc "$NEW" keep
        trap -p QUIT' _ "$TLOGGER" "$RC" "$BATS_TEST_TMPDIR/old-rc" "$BATS_TEST_TMPDIR/backups" \
        "$probe" "$new" < /dev/null
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    grep -q "trap -- '' SIGQUIT" "$probe"
    cmp "$RC" "$new"
}

@test "a symlinked quarantine folder is refused before anything is written" {
    need symlinks
    simple_rc
    # A dry run refuses the link too, so the fingerprint comes first.
    fingerprint
    mkdir -p "$STATE" "$HOME/elsewhere"
    ln -s "$HOME/elsewhere" "$QDIR"
    run_tlogger install --mode manual --yes --remove-block "$OLD_START" "$OLD_END" \
        --block-sha256 "$FP"
    [ "$status" -eq 1 ]
    [[ $stderr == *"~/.local/state/tlogger/quarantine is a symlink"* ]]
    [ "$(sha_of "$RC")" = "$BEFORE" ]
    [ ! -e "$DATA" ]
    [ -z "$(ls -A "$HOME/elsewhere")" ]
}

@test "a quarantine path that is a file is refused" {
    simple_rc
    mkdir -p "$STATE"
    : > "$QDIR"
    run_plan
    [ "$status" -eq 1 ]
    [[ $stderr == *"is not a folder"* ]]
    [ "$(sha_of "$RC")" = "$BEFORE" ]
}

@test "a quarantine folder without write permission is refused" {
    need modes
    simple_rc
    mkdir -p "$QDIR"
    chmod 500 "$QDIR"
    run_plan
    chmod 700 "$QDIR"
    [ "$status" -eq 1 ]
    [[ $stderr == *"cannot write in ~/.local/state/tlogger/quarantine"* ]]
    [ "$(sha_of "$RC")" = "$BEFORE" ]
}

# bats test_tags=root
@test "another user's quarantine folder is refused" {
    if (( EUID != 0 )); then
        skip "it runs only as root"
    fi
    simple_rc
    mkdir -p "$QDIR"
    chown nobody "$QDIR"
    run_with 'refuse_foreign_root() { :; }; refuse_foreign_root_paths() { :; }' install \
        --mode manual --dry-run --remove-block "$OLD_START" "$OLD_END"
    [ "$status" -eq 1 ]
    [[ $stderr == *"belongs to another user"* ]]
    [ "$(sha_of "$RC")" = "$BEFORE" ]
}

@test "the stale backup moves with its bytes and timestamp, and never reaches the rc" {
    need symlinks
    local moved name
    simple_rc
    stale_file
    touch -d '2026-03-02 10:00:00 UTC' "$STALE"
    cp -p "$STALE" "$BATS_TEST_TMPDIR/stale-copy"
    migrate --quarantine "$STALE"
    [ "$status" -eq 0 ]
    [ ! -e "$STALE" ]
    moved=$(moved_stale)
    name=${moved##*/}
    [[ $name =~ ^\.zshrc\.example-backup\.[0-9]{8}T[0-9]{6}Z\.[A-Za-z0-9]{6}$ ]]
    cmp "$moved" "$BATS_TEST_TMPDIR/stale-copy"
    [ "$(stat -c %Y "$moved")" = "$(stat -c %Y "$BATS_TEST_TMPDIR/stale-copy")" ]
    [ "$(grep -c stale-backup-content "$RC")" -eq 0 ]
    [ -z "$(find "$QDIR" -name '.moving.*')" ]
    refute_home_shown
    refute_temp_left
}

@test "the stale backup gets mode 0600 in a 0700 folder, and the saved block 0600" {
    need symlinks
    need modes
    local moved
    simple_rc
    stale_file
    chmod 644 "$STALE"
    migrate --quarantine "$STALE"
    [ "$status" -eq 0 ]
    moved=$(moved_stale)
    [ "$(stat -c %a "$QDIR")" = 700 ]
    [ "$(stat -c %a "$moved")" = 600 ]
    [ "$(stat -c %a "$(saved_block)")" = 600 ]
    # The summary prints the old mode, for the way back.
    [[ $output == *"644"* ]]
}

@test "--quarantine works alone, and the plan shows the file's size, date and mode" {
    need symlinks
    stale_file
    touch -d '2026-03-02 10:00:00 UTC' "$STALE"
    printf 'alias a=1\n' > "$RC"
    run_tlogger install --mode manual --dry-run --quarantine "$STALE"
    [ "$status" -eq 0 ]
    grep -q '^  stale: *~/\.zshrc\.example-backup, 21 bytes, 2026-03-02, moves to quarantine/' <<< "$output"
    [ -f "$STALE" ]
    refute_tlogger_folders
    run_tlogger install --mode manual --yes --quarantine "$STALE"
    [ "$status" -eq 0 ]
    [ ! -e "$STALE" ]
    [ -f "$(moved_stale)" ]
    printf 'alias a=1\n' | cat "$GOLDEN_BLOCK" - | cmp - "$RC"
}

@test "--quarantine works when there is no rc yet" {
    need symlinks
    stale_file
    run_tlogger install --mode manual --yes --quarantine "$STALE"
    [ "$status" -eq 0 ]
    [ ! -e "$STALE" ]
    [ -f "$(moved_stale)" ]
    assert_block_on_top "$RC"
    [ "$(grep -c stale-backup-content "$RC")" -eq 0 ]
}

@test "--remove-block works alone, and creates the quarantine folder only then" {
    need symlinks
    simple_rc
    migrate
    [ "$status" -eq 0 ]
    [ -d "$QDIR" ]
    [ -f "$(saved_block)" ]
}

@test "a plain install does not create the quarantine folder" {
    need symlinks
    printf 'alias a=1\n' > "$RC"
    run_tlogger install --mode manual --yes
    [ "$status" -eq 0 ]
    [ ! -e "$QDIR" ]
}

@test "a run repeated after the block is gone exits 3 and names the follow-up" {
    need symlinks
    simple_rc
    stale_file
    fingerprint
    run_tlogger install --mode manual --yes --remove-block "$OLD_START" "$OLD_END" \
        --block-sha256 "$FP"
    [ "$status" -eq 0 ]
    run_tlogger install --mode manual --yes --remove-block "$OLD_START" "$OLD_END" \
        --block-sha256 "$FP" --quarantine "$STALE"
    [ "$status" -eq 3 ]
    [[ $stderr == *"not moved"* ]]
    [[ $stderr == *"install --quarantine ~/.zshrc.example-backup"* ]]
    [ -f "$STALE" ]
    run_tlogger install --yes --quarantine "$STALE"
    [ "$status" -eq 0 ]
    [ ! -e "$STALE" ]
}

@test "a missing stale backup, a link, a folder or a second hard link is refused" {
    need symlinks
    need hardlinks
    simple_rc
    run_plan --quarantine "$STALE"
    assert_refused 1
    [[ $stderr == *"~/.zshrc.example-backup"* ]]
    printf 'x\n' > "$HOME/target"
    ln -s target "$STALE"
    run_plan --quarantine "$STALE"
    assert_refused 1
    [[ $stderr == *"symlink"* ]]
    rm "$STALE"
    mkdir "$STALE"
    run_plan --quarantine "$STALE"
    assert_refused 1
    rmdir "$STALE"
    printf 'x\n' > "$STALE"
    ln "$STALE" "$HOME/second-name"
    run_plan --quarantine "$STALE"
    assert_refused 1
    [[ $stderr == *"hard link"* ]]
    [ -f "$STALE" ]
}

@test "a stale backup outside the home and zsh folders is refused" {
    simple_rc
    local outside="$BATS_TEST_TMPDIR/outside-backup"
    stale_file "$outside"
    run_plan --quarantine "$outside"
    [ "$status" -eq 1 ]
    [[ $stderr == *"outside"* ]]
    [ -f "$outside" ]
    [ "$(sha_of "$RC")" = "$BEFORE" ]
    refute_tlogger_folders
}

@test "a stale path with a control character is refused without echoing it" {
    simple_rc
    local bad=$HOME/bad$'\e'name
    stale_file "$bad"
    run_plan --quarantine "$bad"
    assert_refused 1
    [[ $stderr != *$'\e'* ]]
    [ -f "$bad" ]
}

@test "a zsh start-up file is refused, in HOME and in ZDOTDIR" {
    local name zdot="$HOME/zdot"
    mkdir -p "$zdot"
    for name in .zshenv .zprofile .zshrc .zlogin .zlogout; do
        printf 'alias a=1\n' > "$HOME/$name"
        printf 'alias a=1\n' > "$zdot/$name"
    done
    { printf 'alias a=1\n'; old_block; } > "$zdot/.zshrc"
    for name in .zshenv .zprofile .zshrc .zlogin .zlogout; do
        ZDOTDIR=$zdot run_plan --quarantine "$HOME/$name"
        [ "$status" -eq 1 ]
        [[ $stderr == *"start-up file"* ]]
        [ -f "$HOME/$name" ]
        ZDOTDIR=$zdot run_plan --quarantine "$zdot/$name"
        [ "$status" -eq 1 ]
        [[ $stderr == *"start-up file"* ]]
        [ -f "$zdot/$name" ]
    done
    refute_tlogger_folders
}

@test "the real file behind a symlinked rc is refused" {
    need symlinks
    mkdir -p "$HOME/dotfiles"
    { cat "$GOLDEN_BLOCK"; printf 'alias a=1\n'; } > "$HOME/dotfiles/zshrc"
    ln -s dotfiles/zshrc "$RC"
    run_tlogger install --mode manual --dry-run --quarantine "$HOME/dotfiles/zshrc"
    [ "$status" -eq 1 ]
    [[ $stderr == *"start-up file"* ]]
    [ -f "$HOME/dotfiles/zshrc" ]
    refute_tlogger_folders
}

@test "a file in tlogger's code, config or state folder is refused" {
    simple_rc
    local dir
    for dir in "$DATA" "$CONF" "$STATE" "$STATE/sessions" "$QDIR"; do
        mkdir -p "$dir"
        stale_file "$dir/example"
        run_plan --quarantine "$dir/example"
        [ "$status" -eq 1 ]
        [[ $stderr == *"tlogger's own"* ]]
        [ -f "$dir/example" ]
    done
    [ "$(sha_of "$RC")" = "$BEFORE" ]
}

@test "a file in the configured or the exported log folder is refused" {
    simple_rc
    mkdir -p "$CONF" "$HOME/evidence" "$HOME/exported"
    printf 'mode=manual\nlogdir=%s/evidence\n' "$HOME" > "$CONF/config"
    stale_file "$HOME/evidence/example"
    stale_file "$HOME/exported/example"
    run_plan --quarantine "$HOME/evidence/example"
    [ "$status" -eq 1 ]
    [[ $stderr == *"tlogger's own"* ]]
    [ -f "$HOME/evidence/example" ]
    TLOGGER_LOGDIR="$HOME/exported" run_plan --quarantine "$HOME/exported/example"
    [ "$status" -eq 1 ]
    [[ $stderr == *"tlogger's own"* ]]
    [ -f "$HOME/exported/example" ]
    # The plugin trims the exported value, so the same folder with spaces around it counts too.
    TLOGGER_LOGDIR=" $HOME/exported " run_plan --quarantine "$HOME/exported/example"
    [ "$status" -eq 1 ]
    [[ $stderr == *"tlogger's own"* ]]
    [ -f "$HOME/exported/example" ]
    # A variable that is set but not exported reaches no shell, so it protects nothing.
    # shellcheck disable=SC2016 # The child expands it.
    run_with 'TLOGGER_LOGDIR=$HOME/exported' install --mode manual --dry-run \
        --remove-block "$OLD_START" "$OLD_END" --quarantine "$HOME/exported/example"
    [ "$status" -eq 0 ]
}

# bats test_tags=root
@test "a stale backup of another user is refused" {
    if (( EUID != 0 )); then
        skip "it runs only as root"
    fi
    simple_rc
    stale_file
    chown nobody "$STALE"
    run_with 'refuse_foreign_root() { :; }; refuse_foreign_root_paths() { :; }' install \
        --mode manual --dry-run --remove-block "$OLD_START" "$OLD_END" --quarantine "$STALE"
    [ "$status" -eq 1 ]
    [[ $stderr == *"belongs to another user"* ]]
    [ -f "$STALE" ]
}

@test "a move that fails leaves the finished rc and prints the command that finishes it" {
    need symlinks
    local stub="$BATS_TEST_TMPDIR/stub"
    simple_rc
    stale_file
    fingerprint
    mkdir -p "$stub"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$stub/touch"
    chmod +x "$stub/touch"
    PATH="$stub:$PATH" run_tlogger install --mode manual --yes --remove-block "$OLD_START" \
        "$OLD_END" --block-sha256 "$FP" --quarantine "$STALE"
    [ "$status" -eq 1 ]
    printf 'alias a=1\nalias z=2\n' | cat "$GOLDEN_BLOCK" - | cmp - "$RC"
    [ -f "$STALE" ]
    [[ $stderr == *"~/.local/share/tlogger/current/bin/tlogger install --quarantine ~/.zshrc.example-backup"* ]]
    # The undo details came first, on stdout.
    [[ $output == *"To put it back"* ]]
    [ -f "$(saved_block)" ]
    [ -z "$(find "$QDIR" -name '.moving.*')" ]
    refute_home_shown
    run_tlogger install --yes --quarantine "$STALE"
    [ "$status" -eq 0 ]
    [ ! -e "$STALE" ]
    [ -f "$(moved_stale)" ]
}

@test "a stale backup that changes during the copy stays where it is" {
    need symlinks
    simple_rc
    stale_file
    fingerprint
    run_with 'touch() { printf "more\n" >> "$HOME/.zshrc.example-backup"; command touch "$@"; }' \
        install --mode manual --yes --remove-block "$OLD_START" "$OLD_END" --block-sha256 "$FP" \
        --quarantine "$STALE"
    [ "$status" -eq 1 ]
    [ -f "$STALE" ]
    grep -q more "$STALE"
    [[ $stderr == *"install --quarantine ~/.zshrc.example-backup"* ]]
    [ -z "$(find "$QDIR" -name '.zshrc.example-backup.*')" ]
    [ -z "$(find "$QDIR" -name '.moving.*')" ]
}

@test "a stale backup with the same bytes but a new identity after the compare stays" {
    need symlinks
    simple_rc
    stale_file
    fingerprint
    # shellcheck disable=SC2016 # The child expands these.
    run_with 'cmp() { if [[ ${!#} == */quarantine/.moving.* ]]; then command touch -d "2001-01-01 00:00:00 UTC" -- "$HOME/.zshrc.example-backup"; fi; command cmp "$@"; }' \
        install --mode manual --yes --remove-block "$OLD_START" "$OLD_END" --block-sha256 "$FP" \
        --quarantine "$STALE"
    [ "$status" -eq 1 ]
    [[ $stderr == *"changed while tlogger was copying"* ]]
    [ "$(cat "$STALE")" = "stale-backup-content" ]
    [ -z "$(find "$QDIR" -name '.zshrc.example-backup.*')" ]
    [ -z "$(find "$QDIR" -name '.moving.*')" ]
}

@test "when only the removal fails, it says to delete the original and offers no second copy" {
    need symlinks
    simple_rc
    stale_file
    fingerprint
    # shellcheck disable=SC2016 # The child expands these.
    run_with 'rm() { if [[ ${!#} == "$HOME/.zshrc.example-backup" ]]; then return 1; fi; command rm "$@"; }' \
        install --mode manual --yes --remove-block "$OLD_START" "$OLD_END" --block-sha256 "$FP" \
        --quarantine "$STALE"
    [ "$status" -eq 1 ]
    [ -f "$STALE" ]
    cmp "$STALE" "$(moved_stale)"
    [[ $stderr == *"delete it by hand"* ]]
    [[ $stderr != *"install --quarantine"* ]]
    refute_home_shown
}

@test "a stale backup that cannot be read, or whose folder denies the move, is refused" {
    need modes
    simple_rc
    stale_file
    chmod 000 "$STALE"
    run_plan --quarantine "$STALE"
    chmod 600 "$STALE"
    assert_refused 1
    [[ $stderr == *"cannot be read"* ]]
    mkdir "$HOME/locked"
    stale_file "$HOME/locked/example"
    chmod 500 "$HOME/locked"
    run_plan --quarantine "$HOME/locked/example"
    chmod 700 "$HOME/locked"
    assert_refused 1
    [[ $stderr == *"its folder"* ]]
    chmod 600 "$HOME/locked"
    run_plan --quarantine "$HOME/locked/example"
    chmod 700 "$HOME/locked"
    assert_refused 1
    [ -f "$HOME/locked/example" ]
}

@test "an rc that appears during the run is kept, and the message does not claim nothing changed" {
    need symlinks
    stale_file
    # shellcheck disable=SC2016 # The child expands these.
    run_with 'install_state() { mkdir -p "$STATE_DIR/rc-backups"; printf "# appeared\n" > "$HOME/.zshrc"; }' \
        install --mode manual --yes --quarantine "$STALE"
    [ "$status" -eq 1 ]
    [[ $stderr == *"did not write it"* ]]
    [[ $stderr == *"may already be updated"* ]]
    [[ $stderr != *"nothing changed"* ]]
    printf '# appeared\n' | cmp - "$RC"
    [ -f "$STALE" ]
}

@test "an rc edited during uninstall is not written, and the message says nothing was removed" {
    need symlinks
    printf 'alias a=1\n' > "$RC"
    run_tlogger install --mode manual --yes
    [ "$status" -eq 0 ]
    run_with 'confirm() { printf "# edited\n" >> "$HOME/.zshrc"; }' uninstall --yes
    [ "$status" -eq 1 ]
    [[ $stderr == *"changed while tlogger was working"* ]]
    [[ $stderr == *"nothing was removed"* ]]
    [[ $stderr != *"may already be updated"* ]]
    [ -L "$DATA/current" ]
    grep -q '^# edited$' "$RC"
}

@test "the printed undo stops at a failed uninstall and leaves the rc alone" {
    need symlinks
    local undo after
    simple_rc
    migrate
    [ "$status" -eq 0 ]
    undo=$(undo_commands)
    [ -n "$undo" ]
    after=$(sha_of "$RC")
    # Without a terminal and without --yes, uninstall refuses.
    run bash -c "$undo" < /dev/null
    [ "$status" -ne 0 ]
    [ "$(sha_of "$RC")" = "$after" ]
    [ ! -e "$RC.undo" ]
}

@test "a stray word after --remove-block is not repeated in the error" {
    simple_rc
    run_tlogger install --mode manual --dry-run --remove-block '#' BEGIN example-recorder \
        '#' END example-recorder
    assert_refused 2
    [[ $stderr == *"quote"* ]]
}

@test "a plain plan keeps its label column, and a migration run widens it by one" {
    printf 'alias a=1\n' > "$RC"
    run_tlogger install --mode manual --dry-run
    [ "$status" -eq 0 ]
    grep -q '^  rc:       ~/\.zshrc (' <<< "$output"
    grep -q '^  version:  ' <<< "$output"
    stale_file
    run_tlogger install --mode manual --dry-run --quarantine "$STALE"
    [ "$status" -eq 0 ]
    grep -q '^  rc:        ~/\.zshrc (' <<< "$output"
    grep -q '^  version:   ' <<< "$output"
}

@test "a stop between the copy and the removal leaves two copies, never none" {
    need symlinks
    simple_rc
    stale_file
    fingerprint
    run_with 'rm() { if [[ ${!#} == "$HOME/.zshrc.example-backup" ]]; then exit 143; fi; command rm "$@"; }' \
        install --mode manual --yes --remove-block "$OLD_START" "$OLD_END" --block-sha256 "$FP" \
        --quarantine "$STALE"
    [ "$status" -eq 143 ]
    [ -f "$STALE" ]
    cmp "$STALE" "$(moved_stale)"
}

@test "a stop before the rename leaves the original and no partial copy" {
    need symlinks
    simple_rc
    stale_file
    fingerprint
    # shellcheck disable=SC2016 # The child expands these.
    run_with 'mv() { if [[ ${!#} == */quarantine/.zshrc.example-backup.* ]]; then exit 143; fi; command mv "$@"; }' \
        install --mode manual --yes --remove-block "$OLD_START" "$OLD_END" --block-sha256 "$FP" \
        --quarantine "$STALE"
    [ "$status" -eq 143 ]
    [ -f "$STALE" ]
    [ -z "$(find "$QDIR" -name '.zshrc.example-backup.*')" ]
    [ -z "$(find "$QDIR" -name '.moving.*')" ]
}

@test "the undo commands give back the file when there was no tlogger block" {
    need symlinks
    check_undo absent
}

@test "the undo commands give back the file without a tlogger block that stood above" {
    need symlinks
    check_undo above
}

@test "the undo commands give back the file without a tlogger block that stood below" {
    need symlinks
    check_undo below
}

@test "the help text names the new options" {
    run_tlogger help
    [ "$status" -eq 0 ]
    [[ $output == *"--remove-block START END"* ]]
    [[ $output == *"--block-sha256 HASH"* ]]
    [[ $output == *"--quarantine FILE"* ]]
}
