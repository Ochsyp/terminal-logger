#!/usr/bin/env bats
# Tests for lib/config.zsh, the plugin's config parser, run in zsh -f: the defaults, values from
# the config, exported TLOGGER_<KEY> presets, invalid values and lines, values that look like
# code, an unsafe config file, and parity with bin/tlogger's read_config. They need a real zsh.

bats_require_minimum_version 1.5.0

load helpers

# Run before each test by bats.
# Gives the test its own HOME with the default XDG layout and an empty config folder.
setup() {
    isolate_home
    isolate_tlogger
    need zsh
    CONF_DIR="$HOME/.config/tlogger"
    CONFIG="$CONF_DIR/config"
    DEFAULT_LOGDIR="$HOME/.local/state/tlogger/sessions"
    mkdir -p "$CONF_DIR"
}

# Load the config with lib/config.zsh in zsh -f through bats `run --separate-stderr`. It prints
# one KEY=VALUE line per entry of _tlogger_cfg, in a fixed order; the warnings go to stderr.
load_config() {
    # zsh expands these, not bash.
    # shellcheck disable=SC2016
    run --separate-stderr zsh -f -c '
        source "$1" || exit 1
        _tlogger_load_config || exit 1
        for k in mode logdir record_input min_free_mb recorder config_dir; do
            print -r -- "$k=$_tlogger_cfg[$k]"
        done' zsh "$REPO_ROOT/lib/config.zsh" < /dev/null
}

# Load the config as load_config does, but print record_ssh and record_tmux, on one line.
load_policies() {
    # zsh expands these, not bash.
    # shellcheck disable=SC2016
    run --separate-stderr zsh -f -c '
        source "$1" || exit 1
        _tlogger_load_config || exit 1
        print -r -- "$_tlogger_cfg[record_ssh] $_tlogger_cfg[record_tmux]"' zsh \
        "$REPO_ROOT/lib/config.zsh" < /dev/null
}

# Load the config as load_config does, but print prompt, stamp, stamp_vpn, vpn_ifaces and
# history_timestamps, in that order, separated by |.
load_display() {
    # zsh expands these, not bash.
    # shellcheck disable=SC2016
    run --separate-stderr zsh -f -c '
        source "$1" || exit 1
        _tlogger_load_config || exit 1
        print -r -- "$_tlogger_cfg[prompt]|$_tlogger_cfg[stamp]|$_tlogger_cfg[stamp_vpn]|$_tlogger_cfg[vpn_ifaces]|$_tlogger_cfg[history_timestamps]"' \
        zsh "$REPO_ROOT/lib/config.zsh" < /dev/null
}

# Fail unless the last load_config exited 0 and printed MODE, LOGDIR, RECORD_INPUT, MIN_FREE_MB
# and RECORDER, with the default config folder.
assert_config() {
    local expected
    expected=$(printf '%s\n' "mode=$1" "logdir=$2" "record_input=$3" "min_free_mb=$4" \
        "recorder=$5" "config_dir=$CONF_DIR")
    if [[ $status -ne 0 || $output != "$expected" ]]; then
        printf 'expected, with exit 0:\n%s\ngot, with exit %s:\n%s\nstderr:\n%s\n' \
            "$expected" "$status" "$output" "$stderr" >&2
        return 1
    fi
}

# Print the mode and the logdir that lib/config.zsh reads from the config, one per line. Fails
# when it warns, since every config the parity test uses is valid.
zsh_mode_logdir() {
    local out
    # zsh expands these, not bash.
    # shellcheck disable=SC2016
    out=$(zsh -f -c 'source "$1" && _tlogger_load_config && print -rl -- "$_tlogger_cfg[mode]" "$_tlogger_cfg[logdir]"' \
        zsh "$REPO_ROOT/lib/config.zsh" < /dev/null 2> "$BATS_TEST_TMPDIR/zsh-stderr") || return 1
    if [[ -s $BATS_TEST_TMPDIR/zsh-stderr ]]; then
        printf 'lib/config.zsh warned:\n' >&2
        cat "$BATS_TEST_TMPDIR/zsh-stderr" >&2
        return 1
    fi
    printf '%s\n' "$out"
}

# Print the mode and the logdir that bin/tlogger's read_config reads from the config, one per
# line, with a key the config lacks mapped to the default the plugin uses. Fails when read_config
# refuses the config.
bash_mode_logdir() {
    # bash expands these in the child, after the source.
    # shellcheck disable=SC2016
    bash -c 'source "$1" || exit 1
        CONFIG_FILE=$2
        read_config
        if [[ -n $CONFIG_ERROR ]]; then
            printf "read_config: the config %s\n" "$CONFIG_ERROR" >&2
            exit 1
        fi
        printf "%s\n" "${CONFIG_MODE:-manual}" "${CONFIG_LOGDIR:-$3}"' \
        _ "$TLOGGER" "$CONFIG" "$DEFAULT_LOGDIR" < /dev/null
}

@test "without a config or a preset every key has its default" {
    load_config
    assert_config manual "$DEFAULT_LOGDIR" yes 200 /usr/bin/script
    [ -z "$stderr" ]
}

@test "absolute XDG folders move the config and the default logdir, and relative ones count as unset" {
    mkdir -p "$HOME/xdg-config/tlogger"
    printf 'mode=auto\n' > "$HOME/xdg-config/tlogger/config"
    XDG_CONFIG_HOME="$HOME/xdg-config/" XDG_STATE_HOME="$HOME/xdg-state" load_config
    [ "$status" -eq 0 ]
    grep -qxF 'mode=auto' <<< "$output"
    grep -qxF "logdir=$HOME/xdg-state/tlogger/sessions" <<< "$output"
    grep -qxF "config_dir=$HOME/xdg-config/tlogger" <<< "$output"
    XDG_CONFIG_HOME=relative/config XDG_STATE_HOME=relative/state load_config
    assert_config manual "$DEFAULT_LOGDIR" yes 200 /usr/bin/script
}

@test "values come from the config, trimmed, with leading zeros and trailing slashes dropped" {
    printf '%s\n' 'mode= auto ' $'record_input=no\t' 'min_free_mb=0500' \
        'logdir=/home/kali/evidence//' 'recorder=/usr/local/bin/script' > "$CONFIG"
    load_config
    assert_config auto /home/kali/evidence no 500 /usr/local/bin/script
    [ -z "$stderr" ]
    # CRLF line ends, as an editor on another system may leave them.
    printf 'mode=auto\r\nlogdir=/home/kali/crlf\r\n' > "$CONFIG"
    load_config
    assert_config auto /home/kali/crlf yes 200 /usr/bin/script
    [ -z "$stderr" ]
}

@test "an exported TLOGGER_<KEY> preset wins over the config, trimmed and checked the same way" {
    printf '%s\n' mode=auto logdir=/home/kali/file-logs record_input=no min_free_mb=300 \
        recorder=/usr/bin/script > "$CONFIG"
    TLOGGER_MODE=manual TLOGGER_LOGDIR=/home/kali/env-logs/ TLOGGER_RECORD_INPUT=' yes ' \
        TLOGGER_MIN_FREE_MB=50 TLOGGER_RECORDER=/opt/script load_config
    assert_config manual /home/kali/env-logs yes 50 /opt/script
    [ -z "$stderr" ]
    # An empty preset counts as unset.
    TLOGGER_MODE='' load_config
    grep -qxF 'mode=auto' <<< "$output"
    # A preset that zsh does not export is ignored, so that this shell and the shells it starts
    # read the same values.
    # zsh expands these, not bash.
    # shellcheck disable=SC2016
    run --separate-stderr zsh -f -c 'source "$1"; TLOGGER_MODE=manual; _tlogger_load_config; print -r -- "$_tlogger_cfg[mode]"' \
        zsh "$REPO_ROOT/lib/config.zsh" < /dev/null
    [ "$status" -eq 0 ]
    [ "$output" = auto ]
}

@test "an invalid preset gets the default, not the config's value, and one warning" {
    printf 'mode=auto\nmin_free_mb=300\n' > "$CONFIG"
    TLOGGER_MODE=sometimes TLOGGER_MIN_FREE_MB=lots load_config
    assert_config manual "$DEFAULT_LOGDIR" yes 200 /usr/bin/script
    [ "${#stderr_lines[@]}" -eq 2 ]
    [ "${stderr_lines[0]}" = 'tlogger: warning: TLOGGER_MODE: mode must be auto or manual; using manual' ]
    [ "${stderr_lines[1]}" = 'tlogger: warning: TLOGGER_MIN_FREE_MB: min_free_mb must be a whole number of MB; using 200' ]
}

@test "an invalid value in the config gets the default and one warning that names its line" {
    printf '%s\n' mode=sometimes logdir=relative/logs record_input=maybe min_free_mb=12MB \
        recorder=script > "$CONFIG"
    load_config
    assert_config manual "$DEFAULT_LOGDIR" yes 200 /usr/bin/script
    [ "${#stderr_lines[@]}" -eq 5 ]
    [ "${stderr_lines[0]}" = 'tlogger: warning: ~/.config/tlogger/config line 1: mode must be auto or manual; using manual' ]
    [ "${stderr_lines[1]}" = 'tlogger: warning: ~/.config/tlogger/config line 2: logdir must be an absolute path; using ~/.local/state/tlogger/sessions' ]
    [ "${stderr_lines[2]}" = 'tlogger: warning: ~/.config/tlogger/config line 3: record_input must be yes or no; using yes' ]
    [ "${stderr_lines[3]}" = 'tlogger: warning: ~/.config/tlogger/config line 4: min_free_mb must be a whole number of MB; using 200' ]
    [ "${stderr_lines[4]}" = 'tlogger: warning: ~/.config/tlogger/config line 5: recorder must be an absolute path; using /usr/bin/script' ]
}

@test "record_ssh and record_tmux take yes or no from the config or a preset, and default to yes" {
    load_policies
    [ "$status" -eq 0 ]
    [ "$output" = 'yes yes' ]
    [ -z "$stderr" ]
    printf 'record_ssh= no\nrecord_tmux=no\t\n' > "$CONFIG"
    load_policies
    [ "$output" = 'no no' ]
    [ -z "$stderr" ]
    TLOGGER_RECORD_SSH=yes TLOGGER_RECORD_TMUX=' yes ' load_policies
    [ "$output" = 'yes yes' ]
    [ -z "$stderr" ]
    # Invalid values get the default yes, with one warning each, in the order of the keys.
    printf 'record_tmux=1\nrecord_ssh=maybe\n' > "$CONFIG"
    load_policies
    [ "$output" = 'yes yes' ]
    [ "${#stderr_lines[@]}" -eq 2 ]
    [ "${stderr_lines[0]}" = 'tlogger: warning: ~/.config/tlogger/config line 2: record_ssh must be yes or no; using yes' ]
    [ "${stderr_lines[1]}" = 'tlogger: warning: ~/.config/tlogger/config line 1: record_tmux must be yes or no; using yes' ]
    TLOGGER_RECORD_TMUX=never load_policies
    [ "$output" = 'yes yes' ]
    [ "${stderr_lines[1]}" = 'tlogger: warning: TLOGGER_RECORD_TMUX: record_tmux must be yes or no; using yes' ]
}

@test "prompt, stamp, stamp_vpn, vpn_ifaces and history_timestamps take the config and the presets, trimmed" {
    load_display
    [ "$status" -eq 0 ]
    [ "$output" = 'on|on|on|tun* wg* tap*|no' ]
    [ -z "$stderr" ]
    # Spaces, tabs and commas separate the patterns, which are kept joined by single spaces.
    printf '%s\n' prompt=off 'stamp= off ' $'stamp_vpn=off\t' 'vpn_ifaces= tun*, wg0 ,ppp* ' \
        history_timestamps=yes > "$CONFIG"
    load_display
    [ "$status" -eq 0 ]
    [ "$output" = 'off|off|off|tun* wg0 ppp*|yes' ]
    [ -z "$stderr" ]
    TLOGGER_PROMPT=on TLOGGER_STAMP=' on ' TLOGGER_STAMP_VPN=on TLOGGER_VPN_IFACES=$'wg*,\ttun0' \
        TLOGGER_HISTORY_TIMESTAMPS=no load_display
    [ "$status" -eq 0 ]
    [ "$output" = 'on|on|on|wg* tun0|no' ]
    [ -z "$stderr" ]
}

@test "an invalid prompt, stamp, stamp_vpn, vpn_ifaces or history_timestamps gets its default and one warning" {
    local value
    printf '%s\n' prompt=yes stamp=1 stamp_vpn=no 'vpn_ifaces=tun0;id' history_timestamps=on \
        > "$CONFIG"
    load_display
    [ "$status" -eq 0 ]
    [ "$output" = 'on|on|on|tun* wg* tap*|no' ]
    [ "${#stderr_lines[@]}" -eq 5 ]
    [ "${stderr_lines[0]}" = 'tlogger: warning: ~/.config/tlogger/config line 1: prompt must be on or off; using on' ]
    [ "${stderr_lines[1]}" = 'tlogger: warning: ~/.config/tlogger/config line 2: stamp must be on or off; using on' ]
    [ "${stderr_lines[2]}" = 'tlogger: warning: ~/.config/tlogger/config line 3: stamp_vpn must be on or off; using on' ]
    [ "${stderr_lines[3]}" = 'tlogger: warning: ~/.config/tlogger/config line 4: vpn_ifaces must list interface name patterns made of letters, digits, _ . - and *; using tun* wg* tap*' ]
    [ "${stderr_lines[4]}" = 'tlogger: warning: ~/.config/tlogger/config line 5: history_timestamps must be yes or no; using no' ]
    # No pattern at all, or a character that could run or glob, makes the list invalid; nothing
    # in it runs.
    rm "$CONFIG"
    mkdir -p "$BATS_TEST_TMPDIR/work"
    cd "$BATS_TEST_TMPDIR/work"
    # shellcheck disable=SC2016 # Values that must stay text.
    for value in ' , ' 'tun[0-9]' 'wg?' 'tun0|wg0' 'tun0,$(touch pwned-vpn)' '`touch pwned-tick`'; do
        TLOGGER_VPN_IFACES=$value load_display
        [ "$status" -eq 0 ]
        [ "$output" = 'on|on|on|tun* wg* tap*|no' ]
        [ "$stderr" = 'tlogger: warning: TLOGGER_VPN_IFACES: vpn_ifaces must list interface name patterns made of letters, digits, _ . - and *; using tun* wg* tap*' ]
    done
    [ -z "$(find "$BATS_TEST_TMPDIR" -name 'pwned*')" ]
}

@test "min_free_mb takes 1 to 12 digits only, and logdir no control character" {
    local value
    for value in -5 1e3 0x10 ' ' 1234567890123 '1 000'; do
        printf 'min_free_mb=%s\n' "$value" > "$CONFIG"
        load_config
        grep -qxF min_free_mb=200 <<< "$output"
        [ "${#stderr_lines[@]}" -eq 1 ]
    done
    printf 'min_free_mb=999999999999\n' > "$CONFIG"
    load_config
    grep -qxF min_free_mb=999999999999 <<< "$output"
    [ -z "$stderr" ]
    printf 'logdir=/home/kali/a\tb\n' > "$CONFIG"
    load_config
    grep -qxF "logdir=$DEFAULT_LOGDIR" <<< "$output"
    [ "${#stderr_lines[@]}" -eq 1 ]
}

@test "a value or a key that looks like code is never run" {
    # Config lines that would create a pwned-* file if anything ran them; no shell may expand
    # them here.
    # shellcheck disable=SC2016
    local mode='$(touch pwned-mode)' logdir='/home/kali/$(touch pwned-logdir)' \
        input='`touch pwned-input`' min='$(touch pwned-min)' \
        recorder='/usr/bin/${$(touch pwned-recorder)}' key='$(touch pwned-key)' \
        env_min='a[$(touch pwned-env)]' env_mode='$(touch pwned-env-mode)'
    mkdir -p "$BATS_TEST_TMPDIR/work"
    cd "$BATS_TEST_TMPDIR/work"
    printf '%s\n' "mode=$mode" "logdir=$logdir" "record_input=$input" "min_free_mb=$min" \
        "recorder=$recorder" "$key=1" > "$CONFIG"
    load_config
    assert_config manual "$logdir" yes 200 "$recorder"
    # The key line, mode, record_input and min_free_mb; the two paths are plain text.
    [ "${#stderr_lines[@]}" -eq 4 ]
    TLOGGER_MIN_FREE_MB=$env_min TLOGGER_MODE=$env_mode load_config
    [ "$status" -eq 0 ]
    grep -qxF min_free_mb=200 <<< "$output"
    grep -qxF mode=manual <<< "$output"
    [ -z "$(find "$BATS_TEST_TMPDIR" -name 'pwned*')" ]
}

@test "comments, blank lines and unknown keys are skipped, and every other bad line warns" {
    printf '%s\n' '# a comment' '' '   # an indented comment' $'\t ' 'engagement=demo' \
        'mode=auto' ' mode=manual' 'Mode=manual' 'mode = manual' 'mode=manual' 'just text' > "$CONFIG"
    load_config
    assert_config auto "$DEFAULT_LOGDIR" yes 200 /usr/bin/script
    [ "${#stderr_lines[@]}" -eq 5 ]
    [ "${stderr_lines[0]}" = 'tlogger: warning: ~/.config/tlogger/config line 7 is not a key=value line; ignored' ]
    [ "${stderr_lines[1]}" = 'tlogger: warning: ~/.config/tlogger/config line 8 is not a key=value line; ignored' ]
    [ "${stderr_lines[2]}" = 'tlogger: warning: ~/.config/tlogger/config line 9 is not a key=value line; ignored' ]
    [ "${stderr_lines[3]}" = 'tlogger: warning: ~/.config/tlogger/config line 10 repeats the key mode; ignored' ]
    [ "${stderr_lines[4]}" = 'tlogger: warning: ~/.config/tlogger/config line 11 is not a key=value line; ignored' ]
}

@test "a config that is a symlink, a folder or unreadable is not read" {
    need symlinks
    need modes
    printf 'mode=auto\n' > "$HOME/real-config"
    ln -s "$HOME/real-config" "$CONFIG"
    load_config
    assert_config manual "$DEFAULT_LOGDIR" yes 200 /usr/bin/script
    [ "$stderr" = 'tlogger: warning: ~/.config/tlogger/config is a symlink or not a regular file; using the defaults' ]
    rm "$CONFIG"
    mkdir "$CONFIG"
    load_config
    assert_config manual "$DEFAULT_LOGDIR" yes 200 /usr/bin/script
    [ "$stderr" = 'tlogger: warning: ~/.config/tlogger/config is a symlink or not a regular file; using the defaults' ]
    rmdir "$CONFIG"
    printf 'mode=auto\n' > "$CONFIG"
    chmod 000 "$CONFIG"
    load_config
    assert_config manual "$DEFAULT_LOGDIR" yes 200 /usr/bin/script
    [ "$stderr" = 'tlogger: warning: ~/.config/tlogger/config is not readable; using the defaults' ]
    chmod 600 "$CONFIG"
}

@test "lib/config.zsh and bin/tlogger's read_config read the same mode and logdir" {
    local name zsh_read bash_read
    # Configs that both parsers accept, and the mode and logdir each one gives.
    local -A configs=(
        [plain]=$'mode=auto\nlogdir=/home/kali/evidence\n'
        [spaced]=$'# a comment\n\n   # an indented comment\n\t \nmode= manual \t\nlogdir=/home/kali/ev//  \n'
        [crlf]=$'mode=auto\r\nlogdir=/home/kali/crlf\r\n'
        [plugin-keys]=$'record_input=no\nmin_free_mb=500\nrecorder=/usr/bin/script\nrecord_ssh=no\nrecord_tmux=no\nprompt=off\nstamp=off\nstamp_vpn=off\nvpn_ifaces=tun*, wg0\nhistory_timestamps=yes\nengagement=demo\nmode=auto\n'
        [root]=$'logdir=/\n'
        [no-final-newline]='mode=auto'
        [empty]=''
    )
    local -A wants=(
        [plain]=$'auto\n/home/kali/evidence'
        [spaced]=$'manual\n/home/kali/ev'
        [crlf]=$'auto\n/home/kali/crlf'
        [plugin-keys]="auto"$'\n'"$DEFAULT_LOGDIR"
        [root]=$'manual\n/'
        [no-final-newline]="auto"$'\n'"$DEFAULT_LOGDIR"
        [empty]="manual"$'\n'"$DEFAULT_LOGDIR"
    )
    for name in "${!configs[@]}"; do
        printf '%s' "${configs[$name]}" > "$CONFIG"
        zsh_read=$(zsh_mode_logdir)
        bash_read=$(bash_mode_logdir)
        if [[ $zsh_read != "${wants[$name]}" || $bash_read != "$zsh_read" ]]; then
            printf 'config %s: expected\n%s\nlib/config.zsh read\n%s\nread_config read\n%s\n' \
                "$name" "${wants[$name]}" "$zsh_read" "$bash_read" >&2
            return 1
        fi
    done
}
