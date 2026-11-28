#!/usr/bin/env bats
# Tests for tlogger engagement in bin/tlogger, which prints, sets or clears the engagement= line
# of the config, and for the engagement row of tlogger status, run as a subprocess in the test's
# own HOME. Without a real zsh, tests/stub-bin/zsh answers what bin/tlogger asks zsh.
#
# The contract these tests pin, for bin/tlogger:
# - tlogger engagement: prints the config's engagement, or none, on stdout; exit 0.
# - tlogger engagement NAME: writes engagement=NAME through config_with and replace_config;
#   stderr 'tlogger: engagement is now NAME; new sessions go into <log folder>/NAME', or
#   'tlogger: engagement is already NAME', which writes nothing.
# - tlogger engagement --none: writes engagement=, with 'tlogger: engagement is now none; new
#   sessions go into <log folder>', or 'tlogger: engagement is already none'.
# - A bad name exits 2, with stderr's first line
#   "tlogger: 'NAME' is not a valid engagement name; $ENGAGEMENT_RULE" (see below). MANIFEST and
#   PRUNED, the names of the files beside the sessions of a folder, are bad names in this case
#   only; manifest and pruned are good ones.
# - read_config's CONFIG_ERROR for an invalid engagement= line:
#   'has an engagement on line N that is not a valid name'. Every other config error refuses,
#   exit 1, as tlogger mode does; an invalid engagement only refuses the printing form.
# - An exported, non-empty TLOGGER_ENGAGEMENT gets the note
#   'tlogger: note: TLOGGER_ENGAGEMENT is set, and in this terminal it wins over the config'.
# - tlogger status has a row 'engagement:' with the engagement, or none.

bats_require_minimum_version 1.5.0

load helpers

# The rule that the refusal of a bad engagement name gives.
ENGAGEMENT_RULE='use letters, digits, ., _ and -, at most 64 characters, starting with a letter'
ENGAGEMENT_RULE+=' or a digit, and not MANIFEST, PRUNED or a session id'

# Run before each test by bats.
# Gives the test its own HOME with the default zsh and XDG layout, and sets the paths it checks.
setup() {
    isolate_home
    isolate_tlogger
    CONF="$HOME/.config/tlogger"
    CONFIG="$CONF/config"
}

# Write the bytes TEXT as the config, in a config folder of mode 0700, as install leaves it.
write_config() {
    mkdir -p "$CONF"
    chmod 700 "$CONF"
    printf '%s' "$1" > "$CONFIG"
}

# Fail unless the last run exited 2 with nothing on stdout and the refusal of the engagement
# name NAME as the first line of stderr.
assert_bad_name() {
    local want="tlogger: '$1' is not a valid engagement name; $ENGAGEMENT_RULE"
    if [[ $status -ne 2 || -n $output || ${stderr%%$'\n'*} != "$want" ]]; then
        printf 'expected exit 2 and\n%s\ngot status %s and:\n%s\n%s\n' "$want" "$status" \
            "$output" "$stderr" >&2
        return 1
    fi
}

@test "tlogger engagement prints the engagement in the config, or none" {
    write_config $'mode=manual\nlogdir=/srv/work/evidence\n'
    run_tlogger engagement
    [ "$status" -eq 0 ]
    [ "$output" = none ]
    [ -z "$stderr" ]
    write_config $'mode=manual\nengagement=\n'
    run_tlogger engagement
    [ "$status" -eq 0 ]
    [ "$output" = none ]
    write_config $'mode=manual\nengagement= acme \t\n'
    run_tlogger engagement
    [ "$status" -eq 0 ]
    [ "$output" = acme ]
    [ -z "$stderr" ]
    refute_temp_left
}

@test "tlogger engagement NAME and --none change only the engagement line and no other byte" {
    local before=$'# notes\r\nmode=manual\r\nlogdir=/srv/work/evidence\nrecord_ssh=no' want
    write_config "$before"
    run_tlogger engagement acme
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$stderr" = 'tlogger: engagement is now acme; new sessions go into /srv/work/evidence/acme' ]
    printf '%s\nengagement=acme\n' "$before" | cmp - "$CONFIG"
    run_tlogger engagement
    [ "$output" = acme ]
    run_tlogger engagement Demo-2.x_1
    [ "$status" -eq 0 ]
    want='tlogger: engagement is now Demo-2.x_1; new sessions go into'
    [ "$stderr" = "$want /srv/work/evidence/Demo-2.x_1" ]
    printf '%s\nengagement=Demo-2.x_1\n' "$before" | cmp - "$CONFIG"
    run_tlogger engagement --none
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$stderr" = 'tlogger: engagement is now none; new sessions go into /srv/work/evidence' ]
    printf '%s\nengagement=\n' "$before" | cmp - "$CONFIG"
    run_tlogger engagement
    [ "$output" = none ]
    # A line in the middle keeps its place and its CR.
    before=$'mode=manual\r\nengagement=acme\r\nlogdir=/srv/work/evidence\r\n'
    write_config "$before"
    run_tlogger engagement test
    [ "$status" -eq 0 ]
    printf '%s' "${before/engagement=acme/engagement=test}" | cmp - "$CONFIG"
    # Upper and lower case count as different names: manifest is not MANIFEST, nor pruned PRUNED.
    run_tlogger engagement TEST
    [ "$status" -eq 0 ]
    grep -Uqx $'engagement=TEST\r' "$CONFIG"
    run_tlogger engagement manifest
    [ "$status" -eq 0 ]
    grep -Uqx $'engagement=manifest\r' "$CONFIG"
    run_tlogger engagement pruned
    [ "$status" -eq 0 ]
    grep -Uqx $'engagement=pruned\r' "$CONFIG"
    refute_temp_left
}

@test "without a logdir line, the message names the default log folder as ~, and makes no folder" {
    local want='tlogger: engagement is now acme; new sessions go into'
    write_config $'mode=manual\n'
    run_tlogger engagement acme
    [ "$status" -eq 0 ]
    [ "$stderr" = "$want ~/.local/state/tlogger/sessions/acme" ]
    printf 'mode=manual\nengagement=acme\n' | cmp - "$CONFIG"
    [ ! -e "$HOME/.local/state/tlogger" ]
    # An existing log folder gets no engagement folder either: the first recording makes it.
    mkdir -p "$HOME/logs"
    write_config "logdir=$HOME/logs"$'\n'
    run_tlogger engagement demo
    [ "$status" -eq 0 ]
    [ "$stderr" = 'tlogger: engagement is now demo; new sessions go into ~/logs/demo' ]
    [ -z "$(ls -A "$HOME/logs")" ]
    refute_home_shown
}

@test "setting the engagement it already has, or --none without one, writes nothing" {
    local before
    write_config $'mode=manual\nengagement=acme\n'
    before=$(sha_of "$CONFIG")
    run_tlogger engagement acme
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$stderr" = 'tlogger: engagement is already acme' ]
    [ "$(sha_of "$CONFIG")" = "$before" ]
    write_config $'mode=manual\n'
    before=$(sha_of "$CONFIG")
    run_tlogger engagement --none
    [ "$status" -eq 0 ]
    [ "$stderr" = 'tlogger: engagement is already none' ]
    [ "$(sha_of "$CONFIG")" = "$before" ]
    write_config $'mode=manual\nengagement=\n'
    before=$(sha_of "$CONFIG")
    run_tlogger engagement --none
    [ "$status" -eq 0 ]
    [ "$stderr" = 'tlogger: engagement is already none' ]
    [ "$(sha_of "$CONFIG")" = "$before" ]
    refute_temp_left
}

@test "a bad engagement name exits 2 with the rule and changes nothing" {
    local before name long
    write_config $'mode=manual\nengagement=acme\n'
    before=$(sha_of "$CONFIG")
    long=$(printf 'a%.0s' {1..65})
    # The $(id) is a name to refuse, never run.
    # shellcheck disable=SC2016
    for name in '' .hidden _acme 'a b' a/b ../acme 'acme!' 'ab$(id)' MANIFEST PRUNED \
        20261112T100000Z-a1B2c3 "$long"; do
        run_tlogger engagement "$name"
        assert_bad_name "$name"
        [ "$(sha_of "$CONFIG")" = "$before" ]
    done
    # 64 characters are allowed.
    run_tlogger engagement "${long:1}"
    [ "$status" -eq 0 ]
    grep -qx "engagement=${long:1}" "$CONFIG"
    refute_temp_left
}

@test "tlogger engagement with an extra argument or an unknown option is a usage error" {
    local before
    write_config $'mode=manual\n'
    before=$(sha_of "$CONFIG")
    run_tlogger engagement acme demo
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    [ "${stderr_lines[0]}" = 'tlogger: engagement takes one argument at most: a name or --none' ]
    [[ $stderr == *$'\nUsage: tlogger <command> [options]\n'* ]]
    run_tlogger engagement --all
    [ "$status" -eq 2 ]
    [ "${stderr_lines[0]}" = 'tlogger: unknown option for engagement: --all' ]
    run_tlogger engagement -acme
    [ "$status" -eq 2 ]
    [ "${stderr_lines[0]}" = 'tlogger: unknown option for engagement: -acme' ]
    run_tlogger engagement --none acme
    [ "$status" -eq 2 ]
    [ "${stderr_lines[0]}" = 'tlogger: engagement takes one argument at most: a name or --none' ]
    [ "$(sha_of "$CONFIG")" = "$before" ]
    run_tlogger engagement --help
    [ "$status" -eq 0 ]
    [[ $output == "Usage: tlogger <command> [options]"* ]]
    refute_temp_left
}

@test "--none or a new name replaces an invalid engagement, which the printing form refuses" {
    local before=$'mode=manual\nengagement=../x\nlogdir=/srv/work/evidence\n' value
    local want='tlogger: the config ~/.config/tlogger/config has an engagement on line 2 that is'
    want+=' not a valid name'
    write_config "$before"
    run_tlogger engagement
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ $stderr == "$want"* ]]
    run_tlogger engagement --none
    [ "$status" -eq 0 ]
    [ "$stderr" = 'tlogger: engagement is now none; new sessions go into /srv/work/evidence' ]
    printf '%s' "${before/engagement=..\/x/engagement=}" | cmp - "$CONFIG"
    for value in MANIFEST PRUNED 20261112T100000Z-a1B2c3 'a b' .acme; do
        write_config $'mode=manual\nengagement='"$value"$'\nlogdir=/srv/work/evidence\n'
        run_tlogger engagement
        [ "$status" -eq 1 ]
        [[ $stderr == "$want"* ]]
        run_tlogger engagement acme
        [ "$status" -eq 0 ]
        printf 'mode=manual\nengagement=acme\nlogdir=/srv/work/evidence\n' | cmp - "$CONFIG"
    done
    refute_temp_left
}

@test "tlogger engagement refuses every other config error and leaves the config as it is" {
    local config before
    for config in $'mode=sometimes\nengagement=acme\n' $'engagement=acme\ntouch /srv/work/ran\n' \
        $'engagement=acme\nengagement=demo\n' $'logdir=relative/logs\n' \
        $'engagement=../x\nmode=sometimes\n'; do
        write_config "$config"
        before=$(sha_of "$CONFIG")
        run_tlogger engagement test
        [ "$status" -eq 1 ]
        [ -z "$output" ]
        [[ $stderr == 'tlogger: the config ~/.config/tlogger/config '*'; fix it by hand' ]]
        run_tlogger engagement --none
        [ "$status" -eq 1 ]
        [ "$(sha_of "$CONFIG")" = "$before" ]
    done
    refute_temp_left
}

@test "tlogger engagement without a config exits 3, says how to install, and creates nothing" {
    run_tlogger engagement
    [ "$status" -eq 3 ]
    [ -z "$output" ]
    [ "$stderr" = 'tlogger: tlogger is not installed; run tlogger install' ]
    run_tlogger engagement acme
    [ "$status" -eq 3 ]
    [ "$stderr" = 'tlogger: tlogger is not installed; run tlogger install' ]
    run_tlogger engagement --none
    [ "$status" -eq 3 ]
    refute_tlogger_folders
    refute_temp_left
}

@test "tlogger engagement renames a new config of mode 0600 over the old one" {
    need modes
    local inode
    write_config $'mode=manual\n'
    chmod 644 "$CONFIG"
    inode=$(stat -c %i "$CONFIG")
    run_tlogger engagement acme
    [ "$status" -eq 0 ]
    [ "$(stat -c %a "$CONFIG")" = 600 ]
    [ "$(stat -c %a "$CONF")" = 700 ]
    [ "$(stat -c %i "$CONFIG")" != "$inode" ]
    run_tlogger engagement --none
    [ "$status" -eq 0 ]
    [ "$(stat -c %a "$CONFIG")" = 600 ]
    refute_temp_left
}

@test "an exported TLOGGER_ENGAGEMENT gets a note, since it wins over the config in that terminal" {
    local note='tlogger: note: TLOGGER_ENGAGEMENT is set, and in this terminal it wins over'
    note+=' the config'
    write_config $'mode=manual\nengagement=acme\nlogdir=/srv/work/evidence\n'
    TLOGGER_ENGAGEMENT=demo run_tlogger engagement
    [ "$status" -eq 0 ]
    [ "$output" = acme ]
    [ "$stderr" = "$note" ]
    TLOGGER_ENGAGEMENT=demo run_tlogger engagement test
    [ "$status" -eq 0 ]
    [ "${#stderr_lines[@]}" -eq 2 ]
    [ "${stderr_lines[0]}" = \
        'tlogger: engagement is now test; new sessions go into /srv/work/evidence/test' ]
    [ "${stderr_lines[1]}" = "$note" ]
    grep -qx 'engagement=test' "$CONFIG"
    # An empty TLOGGER_ENGAGEMENT counts as unset, as in lib/config.zsh.
    TLOGGER_ENGAGEMENT='' run_tlogger engagement
    [ "$output" = test ]
    [ -z "$stderr" ]
}

@test "tlogger status shows the engagement in the config, or none" {
    write_config $'mode=manual\nengagement=acme\n'
    run_tlogger status
    grep -qx '  engagement: *acme' <<< "$output"
    write_config $'mode=manual\n'
    run_tlogger status
    grep -qx '  engagement: *none' <<< "$output"
    write_config $'mode=manual\nengagement=\n'
    run_tlogger status
    grep -qx '  engagement: *none' <<< "$output"
}

@test "help and the usage name tlogger engagement" {
    run_tlogger help
    [ "$status" -eq 0 ]
    grep -qE '^  engagement \[NAME \| --none\]( |$)' <<< "$output"
    run_tlogger frobnicate
    [ "$status" -eq 2 ]
    grep -qE '^  engagement \[NAME \| --none\]( |$)' <<< "$stderr"
}

# bats test_tags=root
@test "tlogger engagement as root for another user's HOME is refused" {
    if (( EUID != 0 )); then
        skip "it runs only as root"
    fi
    local before
    write_config $'mode=manual\n'
    before=$(sha_of "$CONFIG")
    run_tlogger engagement acme
    [ "$status" -eq 1 ]
    [[ $stderr == *"refusing to run as root for a home folder that is not root's"* ]]
    [ "$(sha_of "$CONFIG")" = "$before" ]
}
