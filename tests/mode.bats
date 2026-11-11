#!/usr/bin/env bats
# Tests for tlogger mode and for the smoke test of the recorder that auto mode needs, in tlogger
# mode and in install, run as a subprocess in the test's own HOME. A stub in tests/stub-bin stands
# in for util-linux script, and one test runs the real one; without a real zsh, tests/stub-bin/zsh
# answers what bin/tlogger asks zsh.

bats_require_minimum_version 1.5.0

load helpers

# Run before each test by bats.
# Gives the test its own HOME with the default zsh and XDG layout, and sets the paths it checks.
setup() {
    isolate_home
    isolate_tlogger
    RC="$HOME/.zshrc"
    CONF="$HOME/.config/tlogger"
    CONFIG="$CONF/config"
}

# Write the bytes TEXT as the config, in a config folder of mode 0700, as install leaves it.
write_config() {
    mkdir -p "$CONF"
    chmod 700 "$CONF"
    printf '%s' "$1" > "$CONFIG"
}

# Write ~/bin/NAME, an executable sh script with the body BODY, as a recorder of the test's own.
make_recorder() {
    mkdir -p "$HOME/bin"
    printf '#!/bin/sh\n%s\n' "$2" > "$HOME/bin/$1"
    chmod 755 "$HOME/bin/$1"
}

@test "tlogger mode prints the mode in the config, or manual when it has no mode line" {
    write_config $'# notes\nmode=auto\nlogdir=/home/kali/evidence\n'
    run_tlogger mode
    [ "$status" -eq 0 ]
    [ "$output" = auto ]
    [ -z "$stderr" ]
    write_config $'logdir=/home/kali/evidence\n'
    run_tlogger mode
    [ "$status" -eq 0 ]
    [ "$output" = manual ]
    [ -z "$stderr" ]
    refute_temp_left
}

@test "tlogger mode auto and manual change only the mode line and keep every other byte" {
    local before=$'# notes\r\nmode=manual\r\nlogdir=/home/kali/evidence\nengagement=demo\nrecord_ssh=no'
    write_config "$before"
    TLOGGER_RECORDER=$STUB_RECORDER run_tlogger mode auto
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$stderr" = 'tlogger: mode is now auto; new terminals record themselves' ]
    printf '%s' "${before/mode=manual/mode=auto}" | cmp - "$CONFIG"
    run_tlogger mode
    [ "$output" = auto ]
    run_tlogger mode manual
    [ "$status" -eq 0 ]
    [ "$stderr" = 'tlogger: mode is now manual; tlogger start records a terminal' ]
    printf '%s' "$before" | cmp - "$CONFIG"
    refute_temp_left
}

@test "tlogger mode appends a mode line to a config without one, also after a last line without a newline" {
    write_config $'logdir=/home/kali/evidence\n'
    TLOGGER_RECORDER=$STUB_RECORDER run_tlogger mode auto
    [ "$status" -eq 0 ]
    printf 'logdir=/home/kali/evidence\nmode=auto\n' | cmp - "$CONFIG"
    write_config 'logdir=/home/kali/evidence'
    TLOGGER_RECORDER=$STUB_RECORDER run_tlogger mode auto
    [ "$status" -eq 0 ]
    printf 'logdir=/home/kali/evidence\nmode=auto\n' | cmp - "$CONFIG"
    write_config ''
    TLOGGER_RECORDER=$STUB_RECORDER run_tlogger mode auto
    [ "$status" -eq 0 ]
    printf 'mode=auto\n' | cmp - "$CONFIG"
    refute_temp_left
}

@test "config_with fails when a write fails or the config cannot be opened, so no copy cut short replaces it" {
    need file /dev/full
    local config="$BATS_TEST_TMPDIR/config" text
    # bash expands these in the child, after the source.
    # shellcheck disable=SC2016
    local probe='source "$1" && CONFIG_FILE=$2 && { config_with mode auto > /dev/full; } 2> /dev/null'
    # /dev/full fails every write, as a full disk does.
    for text in $'mode=manual\nlogdir=/home/kali/evidence\n' $'logdir=/home/kali/evidence\n' \
        'logdir=/home/kali/evidence'; do
        printf '%s' "$text" > "$config"
        run bash -c "$probe" _ "$TLOGGER" "$config" < /dev/null
        [ "$status" -eq 1 ]
    done
    run bash -c "$probe" _ "$TLOGGER" "$BATS_TEST_TMPDIR/missing" < /dev/null
    [ "$status" -eq 1 ]
}

@test "tlogger mode renames a new config of mode 0600 over the old one" {
    need modes
    local inode
    write_config $'mode=manual\n'
    chmod 644 "$CONFIG"
    inode=$(stat -c %i "$CONFIG")
    TLOGGER_RECORDER=$STUB_RECORDER run_tlogger mode auto
    [ "$status" -eq 0 ]
    [ "$(stat -c %a "$CONFIG")" = 600 ]
    [ "$(stat -c %a "$CONF")" = 700 ]
    [ "$(stat -c %i "$CONFIG")" != "$inode" ]
    grep -qx 'mode=auto' "$CONFIG"
    refute_temp_left
}

@test "tlogger mode says when the mode is already set, and then writes nothing and runs no smoke test" {
    local before
    write_config $'mode=auto\n'
    before=$(sha_of "$CONFIG")
    TLOGGER_RECORDER=/nonexistent run_tlogger mode auto
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$stderr" = 'tlogger: mode is already auto' ]
    [ "$(sha_of "$CONFIG")" = "$before" ]
    write_config $'logdir=/home/kali/evidence\n'
    before=$(sha_of "$CONFIG")
    run_tlogger mode manual
    [ "$status" -eq 0 ]
    [ "$stderr" = 'tlogger: mode is already manual' ]
    [ "$(sha_of "$CONFIG")" = "$before" ]
    refute_temp_left
}

@test "tlogger mode with a wrong or extra argument exits 2 with the usage and changes nothing" {
    local before
    run_tlogger mode sometimes
    [ "$status" -eq 2 ]
    [ "${stderr_lines[0]}" = "tlogger: mode takes auto or manual, not 'sometimes'" ]
    [[ $stderr == *"Usage: tlogger <command> [options]"* ]]
    write_config $'mode=manual\n'
    before=$(sha_of "$CONFIG")
    run_tlogger mode auto manual
    [ "$status" -eq 2 ]
    [ "${stderr_lines[0]}" = 'tlogger: mode takes one argument at most: auto or manual' ]
    run_tlogger mode Auto
    [ "$status" -eq 2 ]
    run_tlogger mode ''
    [ "$status" -eq 2 ]
    [ "$(sha_of "$CONFIG")" = "$before" ]
    run_tlogger mode --help
    [ "$status" -eq 0 ]
    [[ $output == "Usage: tlogger <command> [options]"* ]]
    refute_temp_left
}

@test "tlogger mode without a config exits 3, says how to install, and creates nothing" {
    run_tlogger mode
    [ "$status" -eq 3 ]
    [ -z "$output" ]
    [ "$stderr" = 'tlogger: tlogger is not installed; run tlogger install' ]
    TLOGGER_RECORDER=$STUB_RECORDER run_tlogger mode auto
    [ "$status" -eq 3 ]
    [ "$stderr" = 'tlogger: tlogger is not installed; run tlogger install' ]
    refute_tlogger_folders
    refute_temp_left
}

@test "tlogger mode refuses a config that install refuses, and leaves it as it is" {
    local config before
    for config in $'mode=sometimes\n' $'mode=manual\ntouch /home/kali/ran\n' \
        $'mode=manual\nmode=auto\n' $'mode=manual\nlogdir=relative/logs\n'; do
        write_config "$config"
        before=$(sha_of "$CONFIG")
        TLOGGER_RECORDER=$STUB_RECORDER run_tlogger mode auto
        [ "$status" -eq 1 ]
        [[ $stderr == 'tlogger: the config ~/.config/tlogger/config '*'; fix it by hand' ]]
        run_tlogger mode
        [ "$status" -eq 1 ]
        [ -z "$output" ]
        [ "$(sha_of "$CONFIG")" = "$before" ]
    done
    write_config $'mode=sometimes\n'
    run_tlogger mode manual
    [ "$status" -eq 1 ]
    [ "$stderr" = 'tlogger: the config ~/.config/tlogger/config has a mode on line 1 that is neither auto nor manual; fix it by hand' ]
    refute_temp_left
}

@test "tlogger mode refuses a symlinked config or config folder and leaves the target as it is" {
    need symlinks
    mkdir -p "$HOME/elsewhere" "$CONF"
    printf 'mode=manual\n' > "$HOME/elsewhere/config"
    ln -s "$HOME/elsewhere/config" "$CONFIG"
    TLOGGER_RECORDER=$STUB_RECORDER run_tlogger mode auto
    [ "$status" -eq 1 ]
    [ "$stderr" = 'tlogger: the config ~/.config/tlogger/config is a symlink or not a regular file; fix it by hand' ]
    rm "$CONFIG"
    rmdir "$CONF"
    ln -s "$HOME/elsewhere" "$CONF"
    TLOGGER_RECORDER=$STUB_RECORDER run_tlogger mode auto
    [ "$status" -eq 1 ]
    [ "$stderr" = 'tlogger: ~/.config/tlogger is a symlink, which tlogger does not follow; remove it or replace it with a folder' ]
    [ "$(cat "$HOME/elsewhere/config")" = mode=manual ]
    refute_temp_left
}

@test "an exported TLOGGER_MODE gets a note, since it wins over the config in that terminal" {
    write_config $'mode=manual\n'
    TLOGGER_MODE=auto run_tlogger mode
    [ "$status" -eq 0 ]
    [ "$output" = manual ]
    [ "$stderr" = 'tlogger: note: TLOGGER_MODE is set, and in this terminal it wins over the config' ]
    TLOGGER_MODE=manual TLOGGER_RECORDER=$STUB_RECORDER run_tlogger mode auto
    [ "$status" -eq 0 ]
    [ "${#stderr_lines[@]}" -eq 2 ]
    [ "${stderr_lines[0]}" = 'tlogger: mode is now auto; new terminals record themselves' ]
    [ "${stderr_lines[1]}" = 'tlogger: note: TLOGGER_MODE is set, and in this terminal it wins over the config' ]
    # An empty TLOGGER_MODE counts as unset, as in lib/config.zsh.
    TLOGGER_MODE='' run_tlogger mode
    [ "$output" = auto ]
    [ -z "$stderr" ]
}

@test "tlogger mode auto refuses a recorder that fails its smoke test and changes nothing" {
    local before recorder
    write_config $'mode=manual\n'
    before=$(sha_of "$CONFIG")
    TLOGGER_RECORDER=/nonexistent run_tlogger mode auto
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [ "$stderr" = 'tlogger: auto mode needs a working recorder: /nonexistent failed its smoke test; keep manual mode, or fix script' ]
    TLOGGER_TEST_RECORDER_STATUS=1 TLOGGER_RECORDER=$STUB_RECORDER run_tlogger mode auto
    [ "$status" -eq 1 ]
    [ "$stderr" = "tlogger: auto mode needs a working recorder: $STUB_RECORDER failed its smoke test; keep manual mode, or fix script" ]
    # One that exits 0 and writes no logs, and one that, as script before util-linux 2.35, has no
    # --logging-format. sh expands the body, not bash.
    make_recorder no-logs 'exit 0'
    # shellcheck disable=SC2016
    make_recorder old-script 'for arg; do if [ "$arg" = --logging-format ]; then exit 1; fi; done; exit 0'
    for recorder in no-logs old-script; do
        TLOGGER_RECORDER="$HOME/bin/$recorder" run_tlogger mode auto
        [ "$status" -eq 1 ]
        [ "$stderr" = "tlogger: auto mode needs a working recorder: ~/bin/$recorder failed its smoke test; keep manual mode, or fix script" ]
    done
    [ "$(sha_of "$CONFIG")" = "$before" ]
    refute_temp_left
}

@test "a recorder that is not executable fails the smoke test" {
    need modes
    write_config $'mode=manual\n'
    make_recorder plain 'exit 0'
    chmod 644 "$HOME/bin/plain"
    TLOGGER_RECORDER="$HOME/bin/plain" run_tlogger mode auto
    [ "$status" -eq 1 ]
    [ "$stderr" = 'tlogger: auto mode needs a working recorder: ~/bin/plain failed its smoke test; keep manual mode, or fix script' ]
    grep -qx 'mode=manual' "$CONFIG"
    refute_temp_left
}

@test "the smoke test runs TLOGGER_RECORDER, else the config's recorder, else /usr/bin/script" {
    write_config "mode=manual"$'\n'"recorder=$STUB_RECORDER"$'\n'
    run_tlogger mode auto
    [ "$status" -eq 0 ]
    [ "$stderr" = 'tlogger: mode is now auto; new terminals record themselves' ]
    run_tlogger mode manual
    [ "$status" -eq 0 ]
    # The failure names the config's recorder, so that a working /usr/bin/script, as CI has,
    # cannot pass in its place.
    TLOGGER_TEST_RECORDER_STATUS=1 run_tlogger mode auto
    [ "$status" -eq 1 ]
    [ "$stderr" = "tlogger: auto mode needs a working recorder: $STUB_RECORDER failed its smoke test; keep manual mode, or fix script" ]
    TLOGGER_RECORDER=/nonexistent run_tlogger mode auto
    [ "$status" -eq 1 ]
    [[ $stderr == *'/nonexistent failed its smoke test'* ]]
    # Whitespace around the value is trimmed, as lib/config.zsh trims it; an untrimmed value would
    # get a warning and the default.
    TLOGGER_RECORDER=" $STUB_RECORDER " run_tlogger mode auto
    [ "$status" -eq 0 ]
    [ "$stderr" = 'tlogger: mode is now auto; new terminals record themselves' ]
    write_config $'mode=manual\nrecorder=relative/script\n'
    run_tlogger mode auto
    [ "${stderr_lines[0]}" = 'tlogger: warning: ~/.config/tlogger/config line 2: recorder must be an absolute path; using /usr/bin/script' ]
    # What follows depends on whether this machine has a working /usr/bin/script.
    if (( status != 0 )); then
        [ "$status" -eq 1 ]
        [ "${stderr_lines[1]}" = 'tlogger: auto mode needs a working recorder: /usr/bin/script failed its smoke test; keep manual mode, or fix script' ]
    fi
    refute_temp_left
}

@test "the smoke test passes with the real util-linux script and leaves nothing behind" {
    need script
    write_config $'mode=manual\n'
    run_tlogger mode auto
    [ "$status" -eq 0 ]
    [ "$stderr" = 'tlogger: mode is now auto; new terminals record themselves' ]
    grep -qx 'mode=auto' "$CONFIG"
    refute_temp_left
}

@test "install in auto mode refuses a recorder that fails its smoke test and writes nothing, in a dry run too" {
    local before
    printf 'alias ll=ls\n' > "$RC"
    before=$(sha_of "$RC")
    TLOGGER_RECORDER=/nonexistent run_tlogger install --mode auto --yes
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ $stderr == *'tlogger: auto mode needs a working recorder: /nonexistent failed its smoke test; install with --mode manual, or fix script'* ]]
    TLOGGER_TEST_RECORDER_STATUS=1 TLOGGER_RECORDER=$STUB_RECORDER run_tlogger install --mode auto --dry-run
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ $stderr == *"tlogger: auto mode needs a working recorder: $STUB_RECORDER failed its smoke test; install with --mode manual, or fix script"* ]]
    [ "$(sha_of "$RC")" = "$before" ]
    refute_tlogger_folders
    refute_temp_left
}

@test "install that keeps mode=auto from the config runs the smoke test, and a failure leaves everything" {
    local before
    printf 'alias ll=ls\n' > "$RC"
    write_config $'mode=auto\n'
    before=$(sha_of "$CONFIG")
    TLOGGER_RECORDER=/nonexistent run_tlogger install --yes
    [ "$status" -eq 1 ]
    [[ $stderr == *'tlogger: auto mode needs a working recorder: /nonexistent failed its smoke test'* ]]
    [ "$(sha_of "$CONFIG")" = "$before" ]
    printf 'alias ll=ls\n' | cmp - "$RC"
    [ ! -e "$HOME/.local/share/tlogger" ]
    [ ! -e "$HOME/.local/state/tlogger" ]
    refute_temp_left
}

@test "install --print-only runs no smoke test" {
    TLOGGER_RECORDER=/nonexistent run_tlogger install --mode auto --print-only
    [ "$status" -eq 0 ]
    [ "$output" = "$(cat "$GOLDEN_BLOCK")" ]
    refute_tlogger_folders
    refute_temp_left
}

@test "with a recorder that passes the smoke test, install --mode auto and tlogger mode auto succeed" {
    need symlinks
    printf 'alias ll=ls\n' > "$RC"
    TLOGGER_RECORDER=$STUB_RECORDER run_tlogger install --mode auto --yes
    [ "$status" -eq 0 ]
    [[ $output == *"is installed. Every new zsh terminal records itself, and tlogger stop pauses."* ]]
    grep -qx 'mode=auto' "$CONFIG"
    run_tlogger mode manual
    [ "$status" -eq 0 ]
    grep -qx 'mode=manual' "$CONFIG"
    TLOGGER_RECORDER=$STUB_RECORDER run_tlogger mode auto
    [ "$status" -eq 0 ]
    grep -qx 'mode=auto' "$CONFIG"
    refute_temp_left
}

@test "help and the usage name tlogger mode" {
    run_tlogger help
    [ "$status" -eq 0 ]
    grep -qE '^  mode +Print the mode in the config' <<< "$output"
    run_tlogger frobnicate
    [ "$status" -eq 2 ]
    grep -qE '^  mode +Print the mode in the config' <<< "$stderr"
}

# bats test_tags=root
@test "tlogger mode as root for another user's HOME is refused" {
    if (( EUID != 0 )); then
        skip "it runs only as root"
    fi
    local before
    write_config $'mode=manual\n'
    before=$(sha_of "$CONFIG")
    TLOGGER_RECORDER=$STUB_RECORDER run_tlogger mode auto
    [ "$status" -eq 1 ]
    [[ $stderr == *"refusing to run as root for a home folder that is not root's"* ]]
    run_tlogger mode
    [ "$status" -eq 1 ]
    [ "$(sha_of "$CONFIG")" = "$before" ]
}
