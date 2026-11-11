#!/usr/bin/env bats
# Tests for bin/tlogger install, uninstall, status, version and help, run as a subprocess in the
# test's own HOME on synthetic rc files. Without a real zsh, tests/stub-bin/zsh answers what
# bin/tlogger asks zsh. Tests that need symlinks, POSIX modes, hard links or root say so.

bats_require_minimum_version 1.5.0

load helpers

# The synthetic rc that a missing rc is seeded from.
SKEL_FIXTURE="$REPO_ROOT/tests/fixtures/skel-zshrc"

# Run before each test by bats.
# Gives the test its own HOME with the default zsh and XDG layout, and sets the paths it checks.
setup() {
    isolate_home
    isolate_tlogger
    RC="$HOME/.zshrc"
    DATA="$HOME/.local/share/tlogger"
    CONF="$HOME/.config/tlogger"
    STATE="$HOME/.local/state/tlogger"
    IFS= read -r VERSION_TEXT < "$REPO_ROOT/VERSION"
    RELEASE="$DATA/releases/$VERSION_TEXT"
}

# Fail if the last run printed the test's HOME in full: tlogger shows home paths as ~.
refute_home_shown() {
    if [[ $output == *"$HOME"* || $stderr == *"$HOME"* ]]; then
        printf 'the output names the home folder in full:\n%s\n%s\n' "$output" "$stderr" >&2
        return 1
    fi
}

# Print the number of rc backups in the state folder: the files named as tlogger names them,
# zshrc.<UTC time>.<6 random characters>.
count_backups() {
    local -i n=0
    local f
    for f in "$STATE/rc-backups"/zshrc.*; do
        if [[ -f $f && ${f##*/} =~ ^zshrc\.[0-9]{8}T[0-9]{6}Z\.[A-Za-z0-9]{6}$ ]]; then
            n+=1
        fi
    done
    printf '%s\n' "$n"
}

# Fail unless every line of the last run's stderr is a tlogger message, so that no tool's own
# error, which names paths in full, got through.
assert_only_tlogger_messages() {
    local line
    while IFS= read -r line; do
        if [[ $line != 'tlogger: '* ]]; then
            printf 'stderr holds a line that is not a tlogger message:\n%s\n' "$line" >&2
            return 1
        fi
    done <<< "$stderr"
}

# Install into an rc that holds the bytes ORIGINAL, append the bytes EDIT, uninstall, and fail
# unless the rc then holds ORIGINAL and EDIT and nothing else. Checks the installed rc too.
round_trip() {
    local original=$1 edit=$2
    printf '%s' "$original" > "$RC"
    printf '%s' "$original" | cat "$GOLDEN_BLOCK" - > "$BATS_TEST_TMPDIR/installed"
    printf '%s%s' "$original" "$edit" > "$BATS_TEST_TMPDIR/expected"
    run_tlogger install --mode manual --yes
    [ "$status" -eq 0 ]
    cmp "$RC" "$BATS_TEST_TMPDIR/installed"
    printf '%s' "$edit" >> "$RC"
    run_tlogger uninstall --yes
    [ "$status" -eq 0 ]
    cmp "$RC" "$BATS_TEST_TMPDIR/expected"
    refute_temp_left
}

# Copy the release files of the repository into a new source tree DIR whose VERSION is VERSION,
# so that a test can install a release other than the repository's own.
make_source_tree() {
    local dir=$1 version=$2 f
    for f in bin/tlogger lib/config.zsh lib/tlogger.zsh libexec/rcblock.awk; do
        mkdir -p "$dir/${f%/*}"
        cp "$REPO_ROOT/$f" "$dir/$f"
    done
    printf '%s\n' "$version" > "$dir/VERSION"
}

# Run DIR/bin/tlogger install --mode manual --yes through bats `run`, as run_tlogger does for
# the repository's own copy, and with the same check that HOME is a test home.
install_from() {
    require_test_home || return 1
    run --separate-stderr bash "$1/bin/tlogger" install --mode manual --yes < /dev/null
}

# Print the names of every entry in the releases folder, hidden ones included, sorted and
# separated by spaces, so that a leftover temp folder shows.
list_releases() {
    find "$DATA/releases" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort | paste -s -d ' ' -
}

@test "install puts the block on lines 1-4 and installs the code, config and state" {
    need symlinks
    local f
    local -a backups
    printf 'alias ll=%s\nexport EDITOR=vi\n' "'ls -l'" > "$RC"
    cp "$RC" "$BATS_TEST_TMPDIR/original"
    run_tlogger install --mode manual --yes
    [ "$status" -eq 0 ]
    assert_block_on_top "$RC"
    tail -n +5 "$RC" | cmp - "$BATS_TEST_TMPDIR/original"
    [ -L "$DATA/current" ]
    [ "$(readlink "$DATA/current")" = "releases/$VERSION_TEXT" ]
    for f in bin/tlogger lib/config.zsh lib/tlogger.zsh libexec/rcblock.awk VERSION; do
        cmp "$REPO_ROOT/$f" "$RELEASE/$f"
    done
    [ "$(wc -l < "$RELEASE/MANIFEST")" -eq 5 ]
    (cd "$RELEASE" && sha256sum --quiet --check MANIFEST)
    grep -qx 'mode=manual' "$CONF/config"
    grep -qxF "logdir=$STATE/sessions" "$CONF/config"
    [ -d "$STATE/sessions" ]
    backups=("$STATE/rc-backups"/zshrc.*)
    [ "${#backups[@]}" -eq 1 ]
    [[ ${backups[0]##*/} =~ ^zshrc\.[0-9]{8}T[0-9]{6}Z\.[A-Za-z0-9]+$ ]]
    cmp "${backups[0]}" "$BATS_TEST_TMPDIR/original"
    [[ $output == *"tlogger $VERSION_TEXT is installed"* ]]
    [[ $output == *"tlogger uninstall"* ]]
    [[ $stderr == *"plugin loaded"* ]]
    refute_home_shown
    refute_temp_left
}

@test "install gives the config, the state, the code and the backup their modes" {
    need symlinks
    need modes
    local -a backups
    printf 'alias ll=ls\n' > "$RC"
    chmod 644 "$RC"
    run_tlogger install --mode manual --yes
    [ "$status" -eq 0 ]
    [ "$(stat -c %a "$CONF")" = 700 ]
    [ "$(stat -c %a "$CONF/config")" = 600 ]
    [ "$(stat -c %a "$STATE")" = 700 ]
    [ "$(stat -c %a "$STATE/rc-backups")" = 700 ]
    [ "$(stat -c %a "$STATE/sessions")" = 700 ]
    [ "$(stat -c %a "$RELEASE/bin/tlogger")" = 755 ]
    [ "$(stat -c %a "$RELEASE/lib/config.zsh")" = 644 ]
    [ "$(stat -c %a "$RELEASE/lib/tlogger.zsh")" = 644 ]
    [ "$(stat -c %a "$RELEASE/libexec/rcblock.awk")" = 644 ]
    [ "$(stat -c %a "$RELEASE/VERSION")" = 644 ]
    [ "$(stat -c %a "$RELEASE/MANIFEST")" = 644 ]
    [ "$(stat -c %a "$RC")" = 644 ]
    backups=("$STATE/rc-backups"/zshrc.*)
    [ "$(stat -c %a "${backups[0]}")" = 600 ]
}

@test "install tightens an existing state folder to 0700" {
    need symlinks
    need modes
    printf 'alias ll=ls\n' > "$RC"
    mkdir -p "$STATE/sessions"
    chmod 755 "$STATE" "$STATE/sessions"
    run_tlogger install --mode manual --yes
    [ "$status" -eq 0 ]
    [ "$(stat -c %a "$STATE")" = 700 ]
    [ "$(stat -c %a "$STATE/sessions")" = 700 ]
}

@test "a second install leaves the rc's sha256 and the backups as they are" {
    need symlinks
    local before
    printf 'alias ll=ls\n' > "$RC"
    run_tlogger install --mode manual --yes
    [ "$status" -eq 0 ]
    before=$(sha_of "$RC")
    run_tlogger install --yes
    [ "$status" -eq 0 ]
    [[ $stderr == *"already installed, block up to date"* ]]
    [[ $output == *"already up to date"* ]]
    [ "$(sha_of "$RC")" = "$before" ]
    [ "$(count_backups)" -eq 1 ]
    grep -qx 'mode=manual' "$CONF/config"
    refute_temp_left
}

@test "install, an edit and uninstall keep the edit and every other byte of an LF rc" {
    need symlinks
    round_trip $'alias ll=\'ls -l\'\nexport EDITOR=vi\n' $'# edited later\n'
}

@test "install, an edit and uninstall keep the edit and every other byte of a CRLF rc" {
    need symlinks
    round_trip $'alias ll=\'ls -l\'\r\nexport EDITOR=vi\r\n' $'# edited later\r\n'
}

@test "install, an edit and uninstall keep the edit and every byte of an rc without a final newline" {
    need symlinks
    round_trip $'alias ll=\'ls -l\'\nexport EDITOR=vi' $'\n# edited later'
}

@test "uninstall keeps a line added above the block" {
    need symlinks
    printf 'alias ll=ls\n' > "$RC"
    run_tlogger install --mode manual --yes
    [ "$status" -eq 0 ]
    { printf '# added above\n'; cat "$RC"; } > "$BATS_TEST_TMPDIR/edited"
    cat "$BATS_TEST_TMPDIR/edited" > "$RC"
    run_tlogger uninstall --yes
    [ "$status" -eq 0 ]
    printf '# added above\nalias ll=ls\n' | cmp - "$RC"
}

@test "a missing rc is seeded from the skel file, below the block" {
    need symlinks
    TLOGGER_SKEL="$SKEL_FIXTURE" run_tlogger install --mode manual --yes
    [ "$status" -eq 0 ]
    cat "$GOLDEN_BLOCK" "$SKEL_FIXTURE" | cmp - "$RC"
    [ "$(count_backups)" -eq 0 ]
    [[ $output == *"none: there was no rc"* ]]
    refute_temp_left
}

@test "a missing rc is created with mode 0644" {
    need symlinks
    need modes
    TLOGGER_SKEL="$SKEL_FIXTURE" run_tlogger install --mode manual --yes
    [ "$status" -eq 0 ]
    [ "$(stat -c %a "$RC")" = 644 ]
}

@test "a missing rc without a readable skel file gets the block alone" {
    need symlinks
    TLOGGER_SKEL="$BATS_TEST_TMPDIR/no-such-skel" run_tlogger install --mode manual --yes
    [ "$status" -eq 0 ]
    cmp "$RC" "$GOLDEN_BLOCK"
}

@test "install puts the block into the rc in ZDOTDIR" {
    need symlinks
    local zdot="$HOME/zdot"
    mkdir -p "$zdot"
    printf 'alias ll=ls\n' > "$zdot/.zshrc"
    ZDOTDIR=$zdot run_tlogger install --mode manual --yes
    [ "$status" -eq 0 ]
    assert_block_on_top "$zdot/.zshrc"
    [ ! -e "$RC" ]
    refute_temp_left "$zdot"
}

@test "a symlinked rc gets the block printed and exit 1, and nothing is written" {
    need symlinks
    local before
    mkdir -p "$HOME/dotfiles"
    printf 'alias ll=ls\n' > "$HOME/dotfiles/zshrc"
    before=$(sha_of "$HOME/dotfiles/zshrc")
    ln -s dotfiles/zshrc "$RC"
    run_tlogger install --mode manual --yes
    [ "$status" -eq 1 ]
    [ "$output" = "$(cat "$GOLDEN_BLOCK")" ]
    [[ $stderr == *"~/.zshrc is a symlink, so tlogger does not edit it."* ]]
    [[ $stderr == *"at the very top of the file"* ]]
    [ -L "$RC" ]
    [ "$(sha_of "$HOME/dotfiles/zshrc")" = "$before" ]
    refute_tlogger_folders
    refute_temp_left
}

@test "an rc without write permission gets the block printed and exit 1, and nothing is written" {
    need modes
    local before
    printf 'alias ll=ls\n' > "$RC"
    chmod 444 "$RC"
    before=$(sha_of "$RC")
    run_tlogger install --mode manual --yes
    [ "$status" -eq 1 ]
    [ "$output" = "$(cat "$GOLDEN_BLOCK")" ]
    [[ $stderr == *"~/.zshrc is not writable, so tlogger does not edit it."* ]]
    [ "$(sha_of "$RC")" = "$before" ]
    [ "$(stat -c %a "$RC")" = 444 ]
    refute_tlogger_folders
    refute_temp_left
}

@test "a symlinked rc that already holds the block gets the rest installed without an edit" {
    need symlinks
    local before
    mkdir -p "$HOME/dotfiles"
    printf 'alias ll=ls\n' | cat "$GOLDEN_BLOCK" - > "$HOME/dotfiles/zshrc"
    before=$(sha_of "$HOME/dotfiles/zshrc")
    ln -s dotfiles/zshrc "$RC"
    run_tlogger install --mode manual --yes
    [ "$status" -eq 0 ]
    [ -L "$RC" ]
    [ "$(sha_of "$HOME/dotfiles/zshrc")" = "$before" ]
    [ -L "$DATA/current" ]
    [ "$(count_backups)" -eq 0 ]
}

@test "a hard-linked rc keeps both links, and both names show the block" {
    need symlinks
    need hardlinks
    printf 'alias ll=ls\n' > "$RC"
    ln "$RC" "$HOME/zshrc-link"
    run_tlogger install --mode manual --yes
    [ "$status" -eq 0 ]
    [ "$(stat -c %h "$RC")" -eq 2 ]
    assert_block_on_top "$RC"
    assert_block_on_top "$HOME/zshrc-link"
    run_tlogger uninstall --yes
    [ "$status" -eq 0 ]
    [ "$(stat -c %h "$RC")" -eq 2 ]
    printf 'alias ll=ls\n' | cmp - "$HOME/zshrc-link"
    refute_temp_left
}

@test "a 0600 rc keeps its mode through install and uninstall" {
    need symlinks
    need modes
    printf 'alias ll=ls\n' > "$RC"
    chmod 600 "$RC"
    run_tlogger install --mode manual --yes
    [ "$status" -eq 0 ]
    [ "$(stat -c %a "$RC")" = 600 ]
    run_tlogger uninstall --yes
    [ "$status" -eq 0 ]
    [ "$(stat -c %a "$RC")" = 600 ]
}

@test "rc backups are 0600" {
    need symlinks
    need modes
    local f
    printf 'alias ll=ls\n' > "$RC"
    run_tlogger install --mode manual --yes
    [ "$status" -eq 0 ]
    run_tlogger uninstall --yes
    [ "$status" -eq 0 ]
    [ "$(count_backups)" -eq 2 ]
    for f in "$STATE/rc-backups"/zshrc.*; do
        [ "$(stat -c %a "$f")" = 600 ]
    done
}

@test "install keeps only the five newest rc backups, and uninstall deletes none" {
    need symlinks
    local i backup
    printf 'alias ll=ls\n' > "$RC"
    for (( i = 1; i <= 4; i++ )); do
        run_tlogger install --mode manual --yes
        [ "$status" -eq 0 ]
        run_tlogger uninstall --yes
        [ "$status" -eq 0 ]
    done
    [ "$(count_backups)" -eq 6 ]
    run_tlogger install --mode manual --yes
    [ "$status" -eq 0 ]
    [ "$(count_backups)" -eq 5 ]
    backup=$(sed -n 's/^  backup: *~\(.*\)$/\1/p' <<< "$output")
    [ -n "$backup" ]
    [ -f "$HOME$backup" ]
}

@test "install deletes the oldest of its own rc backups and no other file in rc-backups" {
    need symlinks
    local dir="$STATE/rc-backups" day backup
    printf 'alias ll=ls\n' > "$RC"
    mkdir -p "$dir"
    for day in 1 2 3 4 5 6; do
        printf 'synthetic backup %s\n' "$day" > "$dir/zshrc.2020010${day}T000000Z.aaaaaa"
    done
    # Copies of the user's own, which sort before and after tlogger's names.
    printf 'alias ll=ls\n' > "$dir/zshrc.0-pristine"
    printf 'alias ll=ls\n' > "$dir/zshrc.orig"
    run_tlogger install --mode manual --yes
    [ "$status" -eq 0 ]
    [ ! -e "$dir/zshrc.20200101T000000Z.aaaaaa" ]
    [ ! -e "$dir/zshrc.20200102T000000Z.aaaaaa" ]
    for day in 3 4 5 6; do
        [ -f "$dir/zshrc.2020010${day}T000000Z.aaaaaa" ]
    done
    backup=$(sed -n 's/^  backup: *~\(.*\)$/\1/p' <<< "$output")
    [ -f "$HOME$backup" ]
    [ "$(count_backups)" -eq 5 ]
    [ -f "$dir/zshrc.0-pristine" ]
    [ -f "$dir/zshrc.orig" ]
}

@test "install off a terminal without --mode or a config exits 2 and writes nothing" {
    local before
    printf 'alias ll=ls\n' > "$RC"
    before=$(sha_of "$RC")
    run_tlogger install --yes
    [ "$status" -eq 2 ]
    [[ $stderr == *"--mode is required when not run from a terminal"* ]]
    [ "$(sha_of "$RC")" = "$before" ]
    refute_tlogger_folders
    refute_temp_left
}

@test "install off a terminal without --yes exits 2 and writes nothing" {
    local before
    printf 'alias ll=ls\n' > "$RC"
    before=$(sha_of "$RC")
    run_tlogger install --mode manual
    [ "$status" -eq 2 ]
    [[ $stderr == *"--yes is required when not run from a terminal"* ]]
    [ "$(sha_of "$RC")" = "$before" ]
    refute_tlogger_folders
    refute_temp_left
}

@test "an unknown command exits 2 with the usage" {
    run_tlogger frobnicate
    [ "$status" -eq 2 ]
    [[ $stderr == *"tlogger: unknown command: frobnicate"* ]]
    [[ $stderr == *"Usage: tlogger <command> [options]"* ]]
}

@test "start and stop exit 2 and name the terminal where they work" {
    local cmd
    # A terminal still on the plugin it loaded before an install of this version sends them here.
    for cmd in start stop; do
        run_tlogger "$cmd"
        [ "$status" -eq 2 ]
        [ -z "$output" ]
        [ "$stderr" = "tlogger: tlogger $cmd works only in a zsh terminal that has loaded the plugin; open a new zsh terminal" ]
    done
    refute_tlogger_folders
}

@test "no command exits 2 with the usage" {
    run_tlogger
    [ "$status" -eq 2 ]
    [[ $stderr == *"Usage: tlogger"* ]]
}

@test "an unknown option or a bad --mode exits 2 and writes nothing" {
    printf 'alias ll=ls\n' > "$RC"
    run_tlogger install --frobnicate
    [ "$status" -eq 2 ]
    [[ $stderr == *"unknown option for install: --frobnicate"* ]]
    run_tlogger install --mode sometimes --yes
    [ "$status" -eq 2 ]
    [[ $stderr == *"--mode takes auto or manual"* ]]
    run_tlogger install --mode
    [ "$status" -eq 2 ]
    run_tlogger uninstall --mode manual
    [ "$status" -eq 2 ]
    run_tlogger status --verbose
    [ "$status" -eq 2 ]
    refute_tlogger_folders
}

@test "uninstall without a block or code exits 3 and writes nothing" {
    local before
    printf 'alias ll=ls\n' > "$RC"
    before=$(sha_of "$RC")
    run_tlogger uninstall --yes
    [ "$status" -eq 3 ]
    [[ $stderr == *"not installed"* ]]
    [ "$(sha_of "$RC")" = "$before" ]
    refute_tlogger_folders
    refute_temp_left
}

@test "uninstall without an rc or code exits 3" {
    run_tlogger uninstall --yes
    [ "$status" -eq 3 ]
    [ ! -e "$RC" ]
    refute_tlogger_folders
}

@test "install --dry-run prints the plan and the diff and writes nothing" {
    local before
    printf 'alias ll=ls\n' > "$RC"
    before=$(sha_of "$RC")
    run_tlogger install --mode manual --dry-run
    [ "$status" -eq 0 ]
    [[ $output == "tlogger install plan"* ]]
    grep -qx '  mode: *manual' <<< "$output"
    grep -qx "  version: *$VERSION_TEXT" <<< "$output"
    grep -qxF -- '--- ~/.zshrc' <<< "$output"
    grep -qxF -- '+++ ~/.zshrc (new)' <<< "$output"
    grep -qxF -- '+# >>> tlogger >>>' <<< "$output"
    [[ $stderr == *"dry run: nothing was written"* ]]
    [ "$(sha_of "$RC")" = "$before" ]
    refute_tlogger_folders
    refute_home_shown
    refute_temp_left
    # A dry run needs no temp folder, so a TMPDIR that does not exist stops nothing.
    TMPDIR="$HOME/no-such-tmp" run_tlogger install --mode manual --dry-run
    [ "$status" -eq 0 ]
    [ ! -e "$HOME/no-such-tmp" ]
    [ "$(sha_of "$RC")" = "$before" ]
    refute_tlogger_folders
}

@test "install replaces an outdated block where it stands and keeps every other byte" {
    need symlinks
    local old=$'alias a=1\r\n# >>> tlogger >>>\n# an older body\n# <<< tlogger <<<\nalias b=2'
    printf '%s' "$old" > "$RC"
    run_tlogger install --mode manual --dry-run
    [ "$status" -eq 0 ]
    [[ $output == *"(the block at lines 2-4 is replaced)"* ]]
    run_tlogger install --mode manual --yes
    [ "$status" -eq 0 ]
    { printf 'alias a=1\r\n'; cat "$GOLDEN_BLOCK"; printf 'alias b=2'; } | cmp - "$RC"
    [ "$(count_backups)" -eq 1 ]
    printf '%s' "$old" | cmp - "$STATE/rc-backups"/zshrc.*
    refute_temp_left
}

@test "install --dry-run for a missing rc creates nothing" {
    # Auto mode runs the smoke test, a dry run too; the stub passes it.
    TLOGGER_RECORDER=$STUB_RECORDER TLOGGER_SKEL="$SKEL_FIXTURE" run_tlogger install --mode auto --dry-run
    [ "$status" -eq 0 ]
    grep -qx '  mode: *auto' <<< "$output"
    [ ! -e "$RC" ]
    refute_tlogger_folders
    refute_temp_left
}

@test "install --print-only prints the golden block and writes nothing" {
    local before
    printf 'alias ll=ls\n' > "$RC"
    before=$(sha_of "$RC")
    bash "$TLOGGER" install --print-only < /dev/null > "$BATS_TEST_TMPDIR/block"
    cmp "$BATS_TEST_TMPDIR/block" "$GOLDEN_BLOCK"
    [ "$(sha_of "$RC")" = "$before" ]
    refute_tlogger_folders
    refute_temp_left
}

@test "a data folder outside HOME is written in full in the block" {
    local data="$BATS_TEST_TMPDIR/data"
    XDG_DATA_HOME=$data bash "$TLOGGER" install --print-only < /dev/null > "$BATS_TEST_TMPDIR/block"
    grep -qF "source \"$data/tlogger/current/lib/tlogger.zsh\";" "$BATS_TEST_TMPDIR/block"
    [ ! -e "$data" ]
}

@test "a line that runs script refuses install and leaves the rc as it is" {
    local before
    printf 'alias ll=ls\nscript -q -f /tmp/session.log\n' > "$RC"
    before=$(sha_of "$RC")
    run_tlogger install --mode manual --yes
    [ "$status" -eq 1 ]
    [[ $stderr == *"another session recorder appears to be set up in ~/.zshrc at line 2; remove it first"* ]]
    [ "$(sha_of "$RC")" = "$before" ]
    refute_tlogger_folders
    refute_temp_left
}

@test "malformed markers refuse install and uninstall and name the line" {
    local before
    printf 'alias ll=ls\n%s\nsource plugin\n' '# >>> tlogger >>>' > "$RC"
    before=$(sha_of "$RC")
    run_tlogger install --mode manual --yes
    [ "$status" -eq 1 ]
    [[ $stderr == *"line 2: unpaired"* ]]
    run_tlogger uninstall --yes
    [ "$status" -eq 1 ]
    [[ $stderr == *"line 2: unpaired"* ]]
    [ "$(sha_of "$RC")" = "$before" ]
    refute_tlogger_folders
    refute_temp_left
}

@test "an altered marker refuses install" {
    local before
    printf '%s\nsource plugin\n%s\n' '# >>> tlogger >>> (edited)' '# <<< tlogger <<<' > "$RC"
    before=$(sha_of "$RC")
    run_tlogger install --mode manual --yes
    [ "$status" -eq 1 ]
    [[ $stderr == *"line 1: altered"* ]]
    [ "$(sha_of "$RC")" = "$before" ]
    refute_tlogger_folders
}

@test "a plugin path with a double quote is refused" {
    XDG_DATA_HOME="$HOME/da\"ta" run_tlogger install --mode manual --yes
    [ "$status" -eq 1 ]
    [[ $stderr == *"holds a double quote"* ]]
    [ ! -e "$RC" ]
    refute_temp_left
}

@test "a plugin path with a dollar sign, a backquote or a backslash is refused" {
    local data
    for data in "$HOME/da\$ta" "$HOME/da\`ta" "$HOME/da\\ta"; do
        XDG_DATA_HOME=$data run_tlogger install --mode manual --print-only
        [ "$status" -eq 1 ]
        [[ $stderr == *"holds a double quote, dollar sign, backquote, backslash or newline"* ]]
    done
    [ ! -e "$RC" ]
}

@test "a config with a line that is not key=value refuses install and is never run" {
    local before
    printf 'alias ll=ls\n' > "$RC"
    before=$(sha_of "$RC")
    mkdir -p "$CONF"
    printf 'mode=manual\ntouch %s/ran\n' "$HOME" > "$CONF/config"
    run_tlogger install --yes
    [ "$status" -eq 1 ]
    [[ $stderr == *"the config ~/.config/tlogger/config has line 2, which is not a key=value line"* ]]
    # The config line is data for tlogger; no shell may expand it.
    # shellcheck disable=SC2016
    printf 'mode=$(touch %s/ran)\n' "$HOME" > "$CONF/config"
    run_tlogger install --yes
    [ "$status" -eq 1 ]
    [[ $stderr == *"has a mode on line 1 that is neither auto nor manual"* ]]
    [ ! -e "$HOME/ran" ]
    [ "$(sha_of "$RC")" = "$before" ]
}

@test "install keeps the config's mode and unknown keys, and --mode changes only the mode" {
    need symlinks
    local logdir
    printf 'alias ll=ls\n' > "$RC"
    run_tlogger install --mode manual --yes
    [ "$status" -eq 0 ]
    logdir=$(grep '^logdir=' "$CONF/config")
    printf '# a note\nengagement=demo\n' >> "$CONF/config"
    # Auto mode, given or kept, runs the smoke test; the stub passes it.
    TLOGGER_RECORDER=$STUB_RECORDER run_tlogger install --mode auto --yes
    [ "$status" -eq 0 ]
    grep -qx 'mode=auto' "$CONF/config"
    grep -qxF "$logdir" "$CONF/config"
    grep -qx '# a note' "$CONF/config"
    grep -qx 'engagement=demo' "$CONF/config"
    [ "$(grep -c '^mode=' "$CONF/config")" -eq 1 ]
    TLOGGER_RECORDER=$STUB_RECORDER run_tlogger install --yes
    [ "$status" -eq 0 ]
    grep -qx 'mode=auto' "$CONF/config"
}

@test "install keeps the plugin's own config keys and an indented comment as they are" {
    need symlinks
    printf 'alias ll=ls\n' > "$RC"
    run_tlogger install --mode manual --yes
    [ "$status" -eq 0 ]
    printf '  # tuned for this engagement\nrecord_input=no\nmin_free_mb=500\nrecorder=/usr/bin/script\nrecord_ssh=no\nrecord_tmux=no\n' \
        >> "$CONF/config"
    cp "$CONF/config" "$BATS_TEST_TMPDIR/config-before"
    run_tlogger install --yes
    [ "$status" -eq 0 ]
    cmp "$CONF/config" "$BATS_TEST_TMPDIR/config-before"
    # Auto mode runs the smoke test; the stub passes it, and TLOGGER_RECORDER wins over the
    # recorder= line.
    TLOGGER_RECORDER=$STUB_RECORDER run_tlogger install --mode auto --yes
    [ "$status" -eq 0 ]
    grep -qx 'mode=auto' "$CONF/config"
    grep -qxF '  # tuned for this engagement' "$CONF/config"
    grep -qx 'record_input=no' "$CONF/config"
    grep -qx 'min_free_mb=500' "$CONF/config"
    grep -qx 'recorder=/usr/bin/script' "$CONF/config"
    grep -qx 'record_ssh=no' "$CONF/config"
    grep -qx 'record_tmux=no' "$CONF/config"
    run_tlogger status
    [ "$status" -eq 0 ]
    grep -qx '  mode: *auto' <<< "$output"
}

@test "a new config names the optional keys in its comments and sets only mode and logdir" {
    need symlinks
    local key
    printf 'alias ll=ls\n' > "$RC"
    run_tlogger install --mode manual --yes
    [ "$status" -eq 0 ]
    for key in record_input min_free_mb record_ssh record_tmux; do
        grep -q "^#.*$key=" "$CONF/config"
    done
    [ "$(grep -v '^#' "$CONF/config")" = "mode=manual"$'\n'"logdir=$STATE/sessions" ]
}

@test "read_config trims values, skips indented comments and blank lines, and runs no value" {
    local config="$BATS_TEST_TMPDIR/config"
    # bash expands these in the child, after the source.
    # shellcheck disable=SC2016
    local probe='source "$1" && CONFIG_FILE=$2 && read_config && printf "%s|%s|%s\n" "$CONFIG_MODE" "$CONFIG_LOGDIR" "$CONFIG_ERROR"'
    printf '   # an indented comment\n\t \nmode= auto \t\nlogdir=/home/kali/evidence//  \r\nrecord_input=no\nmin_free_mb=500\n' \
        > "$config"
    run bash -c "$probe" _ "$TLOGGER" "$config" < /dev/null
    [ "$status" -eq 0 ]
    [ "$output" = 'auto|/home/kali/evidence|' ]
    # The config line is data for tlogger; no shell may expand it.
    # shellcheck disable=SC2016
    printf 'mode=$(touch %s/ran)\n' "$BATS_TEST_TMPDIR" > "$config"
    run bash -c "$probe" _ "$TLOGGER" "$config" < /dev/null
    [ "$status" -eq 0 ]
    [ "$output" = '||has a mode on line 1 that is neither auto nor manual' ]
    [ ! -e "$BATS_TEST_TMPDIR/ran" ]
    printf 'logdir=/home/kali/a\tb\n' > "$config"
    run bash -c "$probe" _ "$TLOGGER" "$config" < /dev/null
    [ "$status" -eq 0 ]
    [ "$output" = '||has a logdir on line 1 that is not an absolute path' ]
}

@test "a source tree without lib/config.zsh is refused before anything is written" {
    make_source_tree "$BATS_TEST_TMPDIR/src" 0.0.1
    rm "$BATS_TEST_TMPDIR/src/lib/config.zsh"
    install_from "$BATS_TEST_TMPDIR/src"
    [ "$status" -eq 1 ]
    [[ $stderr == *"lacks lib/config.zsh"* ]]
    refute_tlogger_folders
}

@test "a symlinked state folder refuses install before anything is written" {
    need symlinks
    local before
    printf 'alias ll=ls\n' > "$RC"
    before=$(sha_of "$RC")
    mkdir -p "$HOME/elsewhere" "$HOME/.local/state"
    ln -s "$HOME/elsewhere" "$STATE"
    run_tlogger install --mode manual --yes
    [ "$status" -eq 1 ]
    [[ $stderr == *"~/.local/state/tlogger is a symlink"* ]]
    [ "$(sha_of "$RC")" = "$before" ]
    [ ! -e "$DATA" ]
    [ ! -e "$CONF" ]
    [ -z "$(ls -A "$HOME/elsewhere")" ]
}

@test "uninstall removes the block and the code and keeps the config and the state" {
    need symlinks
    printf 'alias ll=ls\n' > "$RC"
    run_tlogger install --mode manual --yes
    [ "$status" -eq 0 ]
    mkdir -p "$STATE/sessions/demo"
    printf 'synthetic session\n' > "$STATE/sessions/demo/output.raw"
    run_tlogger uninstall --yes
    [ "$status" -eq 0 ]
    printf 'alias ll=ls\n' | cmp - "$RC"
    [ ! -e "$DATA" ]
    [ -f "$CONF/config" ]
    [ -f "$STATE/sessions/demo/output.raw" ]
    [ "$(count_backups)" -eq 2 ]
    [[ $output == *"tlogger is uninstalled."* ]]
    grep -q '^  kept: *~/.local/state/tlogger ' <<< "$output"
    refute_home_shown
    refute_temp_left
}

@test "uninstall --purge-config removes the config as well, and keeps the state" {
    need symlinks
    printf 'alias ll=ls\n' > "$RC"
    run_tlogger install --mode manual --yes
    [ "$status" -eq 0 ]
    run_tlogger uninstall --purge-config --yes
    [ "$status" -eq 0 ]
    [ ! -e "$CONF" ]
    [ ! -e "$DATA" ]
    [ -d "$STATE/rc-backups" ]
}

@test "uninstall --purge-config after an uninstall removes the config left behind" {
    need symlinks
    printf 'alias ll=ls\n' > "$RC"
    run_tlogger install --mode manual --yes
    [ "$status" -eq 0 ]
    run_tlogger uninstall --yes
    [ "$status" -eq 0 ]
    [ -f "$CONF/config" ]
    run_tlogger uninstall --purge-config --yes
    [ "$status" -eq 0 ]
    [ ! -e "$CONF" ]
}

@test "uninstall --dry-run lists what it would remove and writes nothing" {
    need symlinks
    local before
    printf 'alias ll=ls\n' > "$RC"
    run_tlogger install --mode manual --yes
    [ "$status" -eq 0 ]
    before=$(sha_of "$RC")
    run_tlogger uninstall --dry-run
    [ "$status" -eq 0 ]
    [[ $output == "tlogger uninstall plan"* ]]
    grep -qxF "  ~/.local/share/tlogger/releases/$VERSION_TEXT/bin/tlogger" <<< "$output"
    grep -qxF -- '-# >>> tlogger >>>' <<< "$output"
    [ "$(sha_of "$RC")" = "$before" ]
    [ -L "$DATA/current" ]
    [ -f "$RELEASE/bin/tlogger" ]
    [ "$(count_backups)" -eq 1 ]
    refute_temp_left
}

@test "uninstall leaves a file it did not install, and its folder" {
    need symlinks
    printf 'alias ll=ls\n' > "$RC"
    run_tlogger install --mode manual --yes
    [ "$status" -eq 0 ]
    printf 'synthetic notes\n' > "$RELEASE/notes.txt"
    run_tlogger uninstall --yes
    [ "$status" -eq 0 ]
    [ -f "$RELEASE/notes.txt" ]
    [ ! -e "$RELEASE/bin/tlogger" ]
    [ ! -e "$DATA/current" ]
    [[ $stderr == *"holds files tlogger did not install"* ]]
}

@test "uninstall follows no symlink inside a release folder" {
    need symlinks
    printf 'alias ll=ls\n' > "$RC"
    run_tlogger install --mode manual --yes
    [ "$status" -eq 0 ]
    mkdir -p "$HOME/precious"
    printf 'keep me\n' > "$HOME/precious/tlogger.zsh"
    mv "$RELEASE/lib" "$BATS_TEST_TMPDIR/lib-moved"
    ln -s "$HOME/precious" "$RELEASE/lib"
    run_tlogger uninstall --dry-run
    [ "$status" -eq 0 ]
    grep -qxF "  (left in place: ~/.local/share/tlogger/releases/$VERSION_TEXT/lib/tlogger.zsh, a symlink is in its path)" <<< "$output"
    run_tlogger uninstall --yes
    [ "$status" -eq 0 ]
    [ -f "$HOME/precious/tlogger.zsh" ]
    [[ $stderr == *"a symlink is in its path"* ]]
}

@test "status exits 3 before install" {
    run_tlogger status
    [ "$status" -eq 3 ]
    [[ $output == "tlogger is not installed."* ]]
    refute_tlogger_folders
}

@test "status exits 0 after install and reports the rc, the plugin and the config" {
    need symlinks
    printf 'alias ll=ls\n' > "$RC"
    run_tlogger install --mode manual --yes
    [ "$status" -eq 0 ]
    run_tlogger status
    [ "$status" -eq 0 ]
    [[ $output == "tlogger is installed."* ]]
    grep -qx "  version: *$VERSION_TEXT" <<< "$output"
    grep -qx '  rc: *~/\.zshrc (block at lines 1-4)' <<< "$output"
    grep -qx '  plugin: *~/\.local/share/tlogger/current/lib/tlogger\.zsh (readable)' <<< "$output"
    grep -qx '  mode: *manual' <<< "$output"
    grep -qx '  logdir: *~/\.local/state/tlogger/sessions' <<< "$output"
    refute_home_shown
}

@test "status exits 1 when tlogger is installed only in part" {
    need symlinks
    printf 'alias ll=ls\n' > "$RC"
    run_tlogger install --mode manual --yes
    [ "$status" -eq 0 ]
    rm "$DATA/current"
    run_tlogger status
    [ "$status" -eq 1 ]
    [[ $output == "tlogger is installed only in part; run tlogger install to repair it."* ]]
    grep -qx '  plugin: *~/\.local/share/tlogger/current/lib/tlogger\.zsh (not readable)' <<< "$output"
}

@test "status exits 3 after uninstall" {
    need symlinks
    printf 'alias ll=ls\n' > "$RC"
    run_tlogger install --mode manual --yes
    [ "$status" -eq 0 ]
    run_tlogger uninstall --yes
    [ "$status" -eq 0 ]
    run_tlogger status
    [ "$status" -eq 3 ]
}

@test "sourcing bin/tlogger defines its functions and runs nothing" {
    # bash expands these in the child, after the source.
    # shellcheck disable=SC2016
    run bash -c 'source "$1" && HOME=/home/kali && shown /home/kali/.zshrc && shown /etc/skel/.zshrc &&
        HOME=/home/kali// && shown /home/kali/.zshrc' _ "$TLOGGER" < /dev/null
    [ "$status" -eq 0 ]
    [ "$output" = $'~/.zshrc\n/etc/skel/.zshrc\n~/.zshrc' ]
}

@test "version_newer ranks numbers as numbers and a suffix below the plain version" {
    # bash expands these in the child, after the source.
    # shellcheck disable=SC2016
    run bash -c 'source "$1" &&
        version_newer 0.10.0 0.9.0 && ! version_newer 0.9.0 0.10.0 &&
        version_newer 0.1.0 0.1.0-dev && ! version_newer 0.1.0-dev 0.1.0 &&
        version_newer 0.1.0-rc.10 0.1.0-rc.2 && version_newer 0.1.0-dev 0.0.9 &&
        ! version_newer 1.0.0 1.0.0' _ "$TLOGGER" < /dev/null
    [ "$status" -eq 0 ]
}

@test "a relative path or one with a newline from the zsh query is refused" {
    XDG_STATE_HOME=relative/state run_tlogger install --mode manual --yes
    [ "$status" -eq 1 ]
    [[ $stderr == *"zsh reports XDG_STATE_HOME as a value that is not an absolute path without a newline"* ]]
    XDG_CONFIG_HOME="$HOME/con"$'\n'"fig" run_tlogger install --mode manual --yes
    [ "$status" -eq 1 ]
    [[ $stderr == *"zsh reports XDG_CONFIG_HOME as a value that is not an absolute path without a newline"* ]]
    # zsh falls back to HOME only when ZDOTDIR is unset; an empty one makes it read /.zshrc.
    ZDOTDIR='' run_tlogger install --mode manual --yes
    [ "$status" -eq 1 ]
    [[ $stderr == *"zsh reports ZDOTDIR as a value that is not an absolute path without a newline"* ]]
    refute_tlogger_folders
    refute_temp_left
}

@test "an install that fails names home paths as ~ and writes nothing" {
    local before
    printf 'alias ll=ls\n' > "$RC"
    before=$(sha_of "$RC")
    # A file where the config's parent folder belongs is found before anything is written.
    rmdir "$HOME/.config"
    printf 'not a folder\n' > "$HOME/.config"
    run_tlogger install --mode manual --yes
    [ "$status" -eq 1 ]
    [[ $stderr == *"tlogger: cannot create ~/.config/tlogger: ~/.config is not a folder"* ]]
    assert_only_tlogger_messages
    refute_home_shown
    [ ! -e "$DATA" ]
    [ ! -e "$STATE" ]
    [ "$(sha_of "$RC")" = "$before" ]
    rm "$HOME/.config"
    # mktemp's own error would name the full path of the missing TMPDIR.
    TMPDIR="$HOME/no-such-tmp" run_tlogger install --mode manual --yes
    [ "$status" -eq 1 ]
    [[ $stderr == *"tlogger: cannot create a temp folder in ~/no-such-tmp"* ]]
    assert_only_tlogger_messages
    refute_home_shown
    [ "$(sha_of "$RC")" = "$before" ]
    refute_tlogger_folders
}

@test "version prints the version in VERSION" {
    run_tlogger version
    [ "$status" -eq 0 ]
    [ "$output" = "tlogger $VERSION_TEXT" ]
}

@test "help, -h and --help print the usage and exit 0" {
    local arg
    for arg in help -h --help; do
        run_tlogger "$arg"
        [ "$status" -eq 0 ]
        [[ $output == "Usage: tlogger <command> [options]"* ]]
    done
    run_tlogger install --help
    [ "$status" -eq 0 ]
    [[ $output == "Usage: tlogger"* ]]
}

@test "install keeps the current release and one older one" {
    need symlinks
    local v
    printf 'alias ll=ls\n' > "$RC"
    for v in 0.0.1 0.0.2 0.0.3; do
        make_source_tree "$BATS_TEST_TMPDIR/src-$v" "$v"
        install_from "$BATS_TEST_TMPDIR/src-$v"
        [ "$status" -eq 0 ]
    done
    [ "$(readlink "$DATA/current")" = releases/0.0.3 ]
    [ "$(list_releases)" = "0.0.2 0.0.3" ]
}

@test "install from a release older than the current one is refused and switches nothing" {
    need symlinks
    local v before
    printf 'alias ll=ls\n' > "$RC"
    for v in 0.0.1 0.0.2; do
        make_source_tree "$BATS_TEST_TMPDIR/src-$v" "$v"
        install_from "$BATS_TEST_TMPDIR/src-$v"
        [ "$status" -eq 0 ]
    done
    [ "$(list_releases)" = "0.0.1 0.0.2" ]
    before=$(sha_of "$RC")
    # The bin/tlogger that a terminal opened before the upgrade still runs.
    install_from "$DATA/releases/0.0.1"
    [ "$status" -eq 1 ]
    [[ $stderr == *"~/.local/share/tlogger/current is 0.0.2, newer than this tlogger (0.0.1)"* ]]
    [ "$(readlink "$DATA/current")" = releases/0.0.2 ]
    [ "$(list_releases)" = "0.0.1 0.0.2" ]
    [ "$(sha_of "$RC")" = "$before" ]
    refute_temp_left
}

@test "a second install of the same version with other files replaces the release" {
    need symlinks
    printf 'alias ll=ls\n' > "$RC"
    make_source_tree "$BATS_TEST_TMPDIR/src" 0.0.1
    install_from "$BATS_TEST_TMPDIR/src"
    [ "$status" -eq 0 ]
    printf '# changed\n' >> "$BATS_TEST_TMPDIR/src/lib/tlogger.zsh"
    install_from "$BATS_TEST_TMPDIR/src"
    [ "$status" -eq 0 ]
    [[ $output == *"(installed)"* ]]
    cmp "$BATS_TEST_TMPDIR/src/lib/tlogger.zsh" "$DATA/releases/0.0.1/lib/tlogger.zsh"
    (cd "$DATA/releases/0.0.1" && sha256sum --quiet --check MANIFEST)
    [ "$(list_releases)" = 0.0.1 ]
}

@test "install run from the installed release keeps that release" {
    need symlinks
    printf 'alias ll=ls\n' > "$RC"
    run_tlogger install --mode manual --yes
    [ "$status" -eq 0 ]
    run --separate-stderr bash "$DATA/current/bin/tlogger" install --yes < /dev/null
    [ "$status" -eq 0 ]
    [[ $output == *"kept: tlogger runs from this release"* ]]
    (cd "$RELEASE" && sha256sum --quiet --check MANIFEST)
}

@test "install without zsh on PATH exits 1 and writes nothing" {
    need symlinks
    local bin="$BATS_TEST_TMPDIR/bin"
    printf 'alias ll=ls\n' > "$RC"
    mkdir -p "$bin"
    ln -s "$(command -v readlink)" "$bin/readlink"
    run --separate-stderr env PATH="$bin" "$BASH" "$TLOGGER" install --mode manual --yes < /dev/null
    [ "$status" -eq 1 ]
    [[ $stderr == *"zsh is not installed"* ]]
    refute_tlogger_folders
}

# bats test_tags=root
@test "install and uninstall as root for another user's HOME are refused" {
    if (( EUID != 0 )); then
        skip "it runs only as root"
    fi
    local before
    printf 'alias ll=ls\n' > "$RC"
    before=$(sha_of "$RC")
    run_tlogger install --mode manual --yes
    [ "$status" -eq 1 ]
    [[ $stderr == *"refusing to run as root for a home folder that is not root's"* ]]
    run_tlogger uninstall --yes
    [ "$status" -eq 1 ]
    [[ $stderr == *"refusing to run as root"* ]]
    # status runs the zsh query, and with it the .zshenv of the home it is given.
    run_tlogger status
    [ "$status" -eq 1 ]
    [[ $stderr == *"refusing to run as root"* ]]
    [ "$(sha_of "$RC")" = "$before" ]
    refute_tlogger_folders
}

# bats test_tags=root
@test "as root, a ZDOTDIR or XDG folder outside root's home is refused" {
    if (( EUID != 0 )); then
        skip "it runs only as root"
    fi
    local root_home
    root_home=$(getent passwd 0 | cut -d: -f6)
    root_home=${root_home:-/root}
    # --print-only writes nothing, so root's real home stays as it is even without the refusal.
    run --separate-stderr env HOME="$root_home" XDG_DATA_HOME="$BATS_TEST_TMPDIR/data" \
        bash "$TLOGGER" install --print-only < /dev/null
    [ "$status" -eq 1 ]
    [[ $stderr == *"tlogger: refusing to run as root with $BATS_TEST_TMPDIR/data outside root's home"* ]]
    run --separate-stderr env HOME="$root_home" ZDOTDIR="$BATS_TEST_TMPDIR/zdot" \
        bash "$TLOGGER" install --print-only < /dev/null
    [ "$status" -eq 1 ]
    [[ $stderr == *"refusing to run as root with a ZDOTDIR outside root's home"* ]]
    [ -z "$output" ]
    [ ! -e "$BATS_TEST_TMPDIR/data" ]
}
