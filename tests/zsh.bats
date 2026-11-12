#!/usr/bin/env bats
# Tests that need a real zsh: ZDOTDIR and output from .zshenv, the golden block, zsh -n on the
# plugin, on an rc built from /etc/skel/.zshrc and on a broken rc, the probe of a new shell, and
# the block and the plugin in real interactive and non-interactive shells. They skip without zsh;
# CI runs them in the Kali container.

bats_require_minimum_version 1.5.0

load helpers

# Run before each test by bats.
# Gives the test its own HOME with the default zsh and XDG layout, and sets the paths it checks.
setup() {
    isolate_home
    isolate_tlogger
    RC="$HOME/.zshrc"
    IFS= read -r VERSION_TEXT < "$REPO_ROOT/VERSION"
}

# Copy lib/tlogger.zsh and lib/config.zsh into a release folder of the test's own, with a VERSION
# file and no bin/tlogger, and set PLUGIN to the copy and RELEASE_DIR to the folder, symlinks
# resolved.
make_plugin_release() {
    RELEASE_DIR="$BATS_TEST_TMPDIR/release"
    mkdir -p "$RELEASE_DIR/lib"
    cp "$REPO_ROOT/lib/tlogger.zsh" "$RELEASE_DIR/lib/tlogger.zsh"
    cp "$REPO_ROOT/lib/config.zsh" "$RELEASE_DIR/lib/config.zsh"
    printf '0.0.0-test\n' > "$RELEASE_DIR/VERSION"
    RELEASE_DIR=$(cd "$RELEASE_DIR" && pwd -P)
    PLUGIN="$RELEASE_DIR/lib/tlogger.zsh"
}

@test "ZDOTDIR set in .zshenv puts the block into the rc in ZDOTDIR" {
    need zsh
    need symlinks
    printf 'ZDOTDIR=%s\n' "$HOME/zdot" > "$HOME/.zshenv"
    mkdir -p "$HOME/zdot"
    printf 'alias ll=ls\n' > "$HOME/zdot/.zshrc"
    run_tlogger install --mode manual --yes
    [ "$status" -eq 0 ]
    assert_block_on_top "$HOME/zdot/.zshrc"
    [ ! -e "$RC" ]
    [[ $stderr == *"plugin loaded"* ]]
}

@test "output of .zshenv, even without a final newline, does not confuse the path query" {
    need zsh
    need symlinks
    printf 'print -r -- "ZDOTDIR=/tmp"\nprint -n -- noise\n' > "$HOME/.zshenv"
    printf 'alias ll=ls\n' > "$RC"
    run_tlogger install --mode manual --yes
    [ "$status" -eq 0 ]
    assert_block_on_top "$RC"
    [[ $stderr == *"plugin loaded"* ]]
}

@test "an rc that already fails zsh -n gets a warning, and the block all the same" {
    need zsh
    need symlinks
    # A stray fi is a parse error.
    printf 'alias ll=ls\nfi\n' > "$RC"
    run_tlogger install --mode manual --yes
    [ "$status" -eq 0 ]
    [[ $stderr == *"~/.zshrc already fails a zsh -n syntax check"* ]]
    assert_block_on_top "$RC"
    tail -n +5 "$RC" | cmp - <(printf 'alias ll=ls\nfi\n')
}

@test "install warns when a new interactive zsh does not load the plugin" {
    need zsh
    need symlinks
    # With NO_RCS set in .zshenv, zsh reads no .zshrc.
    printf 'unsetopt rcs\n' > "$HOME/.zshenv"
    printf 'alias ll=ls\n' > "$RC"
    run_tlogger install --mode manual --yes
    [ "$status" -eq 0 ]
    assert_block_on_top "$RC"
    [[ $stderr == *"a new interactive zsh did not load the plugin"* ]]
}

@test "a job that the rc leaves running does not hold install up" {
    need zsh
    need symlinks
    local start
    printf 'alias ll=ls\nsleep 25 &!\n' > "$RC"
    start=$SECONDS
    # fd 3 is closed, so that the job cannot hold the bats output open either.
    run_tlogger install --mode manual --yes 3>&-
    [ "$status" -eq 0 ]
    (( SECONDS - start < 20 ))
    [[ $stderr == *"plugin loaded"* ]]
}

@test "the block matches tests/golden/rc-block.zsh byte for byte" {
    need zsh
    need symlinks
    bash "$TLOGGER" install --print-only < /dev/null > "$BATS_TEST_TMPDIR/block"
    cmp "$BATS_TEST_TMPDIR/block" "$GOLDEN_BLOCK"
    printf 'alias ll=ls\n' > "$RC"
    run_tlogger install --mode manual --yes
    [ "$status" -eq 0 ]
    assert_block_on_top "$RC"
    zsh -n "$GOLDEN_BLOCK"
}

@test "lib/tlogger.zsh passes a zsh -n syntax check" {
    need zsh
    zsh -n "$REPO_ROOT/lib/tlogger.zsh"
}

@test "the rc built from /etc/skel/.zshrc passes a zsh -n syntax check" {
    need zsh
    need file /etc/skel/.zshrc
    need symlinks
    run_tlogger install --mode manual --yes
    [ "$status" -eq 0 ]
    cat "$GOLDEN_BLOCK" /etc/skel/.zshrc | cmp - "$RC"
    zsh -n "$RC"
}

@test "an interactive zsh loads the plugin, and tlogger status says that the terminal is not recorded" {
    need zsh
    need symlinks
    printf 'alias ll=ls\n' > "$RC"
    run_tlogger install --mode manual --yes
    [ "$status" -eq 0 ]
    [[ $stderr == *"plugin loaded"* ]]
    run --separate-stderr zsh -i -c 'tlogger status' < /dev/null
    [ "$status" -eq 0 ]
    grep -qxF "tlogger plugin $VERSION_TEXT" <<< "$output"
    grep -qx '  state: *NOREC, this terminal is NOT recorded' <<< "$output"
    grep -qx '  session: *none' <<< "$output"
    grep -qx '  mode: *manual' <<< "$output"
    grep -qx '  logdir: *~/\.local/state/tlogger/sessions' <<< "$output"
    grep -qx '  record_input: *yes' <<< "$output"
    grep -qx '  prompt: *on' <<< "$output"
    grep -qx '  stamp: *on' <<< "$output"
    # The VPN list of the machine, or none.
    grep -qx '  vpn: *[^ ].*' <<< "$output"
    run --separate-stderr zsh -i -c 'tlogger version' < /dev/null
    [ "$status" -eq 0 ]
    [[ $output == *"tlogger $VERSION_TEXT"* ]]
}

@test "with the plugin missing, an interactive zsh warns and a non-interactive one prints nothing" {
    need zsh
    cp "$GOLDEN_BLOCK" "$RC"
    run --separate-stderr zsh -i -c true < /dev/null
    [ "$status" -eq 0 ]
    [[ $stderr == *"tlogger: plugin missing, this terminal is NOT recorded"* ]]
    # zsh expands $HOME, not bash.
    # shellcheck disable=SC2016
    run zsh -c 'source "$HOME/.zshrc"' < /dev/null
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "a non-interactive zsh that sources the plugin gets nothing from it" {
    need zsh
    make_plugin_release
    # zsh expands these, not bash.
    # shellcheck disable=SC2016
    run zsh -f -c 'source "$1"; print -r -- "${+functions[tlogger]} ${+_tlogger_release}"' zsh "$PLUGIN" < /dev/null
    [ "$status" -eq 0 ]
    [ "$output" = "0 0" ]
}

@test "the plugin defines only its own functions and parameters, and changes no option" {
    need zsh
    make_plugin_release
    # The modules the plugin loads are loaded first, so that their parameters do not count as
    # new, and LC_ALL=C fixes the sort order. The name lists stay unquoted: in double quotes zsh
    # would join them before it sorts them. The script is zsh code; zsh expands it, not bash.
    # shellcheck disable=SC2016
    run --separate-stderr env LC_ALL=C zsh -f -i -c '
        zmodload zsh/datetime zsh/system zsh/parameter
        typeset -a _t_f0 _t_f1 _t_p0 _t_p1 _t_new_f _t_new_p
        typeset _t_o0 _t_o1 _t_o2 _t_prompt
        _t_prompt=$PROMPT
        _t_o0=$(setopt)
        _t_f0=(${(k)functions})
        _t_p0=(${(k)parameters})
        source "$1"
        _t_o1=$(setopt)
        _t_f1=(${(k)functions})
        _t_p1=(${(k)parameters})
        tlogger status
        _t_o2=$(setopt)
        _t_new_f=(${_t_f1:|_t_f0})
        _t_new_p=(${_t_p1:|_t_p0})
        print -r -- functions: ${(o)_t_new_f}
        print -r -- parameters: ${(o)_t_new_p}
        if [[ $_t_o0 == "$_t_o1" && $_t_o1 == "$_t_o2" ]]; then
            print -r -- "options: unchanged"
        fi
        if [[ $PROMPT == "$_t_prompt" ]]; then
            print -r -- "prompt: unchanged"
        fi
        print -r -- "release: $_tlogger_release"
    ' zsh "$PLUGIN" < /dev/null
    [ "$status" -eq 0 ]
    local want_f want_p got_f got_p
    want_f='functions: _tlogger_append _tlogger_autostart _tlogger_autostart_why _tlogger_df _tlogger_drop_empty _tlogger_handshake _tlogger_init _tlogger_load_config _tlogger_precmd _tlogger_preexec _tlogger_preflight _tlogger_prompt _tlogger_record _tlogger_say _tlogger_shown _tlogger_start _tlogger_stat _tlogger_status _tlogger_stop _tlogger_tty_state _tlogger_utc _tlogger_vpn_update _tlogger_write_new _tlogger_zshexit add-zsh-hook tlogger'
    want_p='parameters: _tlogger_cfg _tlogger_cmd _tlogger_df_time _tlogger_hs _tlogger_ip _tlogger_main _tlogger_release _tlogger_seg _tlogger_state _tlogger_vpn _tlogger_vpn_key _tlogger_vpn_time precmd_functions preexec_functions zshexit_functions'
    got_f=$(grep '^functions: ' <<< "$output") || got_f=
    got_p=$(grep '^parameters: ' <<< "$output") || got_p=
    if [[ $got_f != "$want_f" || $got_p != "$want_p" ]]; then
        printf 'want: %s\ngot:  %s\nwant: %s\ngot:  %s\nstderr:\n%s\n' \
            "$want_f" "$got_f" "$want_p" "$got_p" "$stderr" >&2
        return 1
    fi
    grep -qxF 'options: unchanged' <<< "$output"
    grep -qxF 'prompt: unchanged' <<< "$output"
    grep -qxF "release: $RELEASE_DIR" <<< "$output"
    grep -qxF 'tlogger plugin 0.0.0-test' <<< "$output"
    grep -qx '  state: *NOREC, this terminal is NOT recorded' <<< "$output"
    [ -z "$stderr" ]
}

@test "the plugin's tlogger sends other subcommands to the bin/tlogger of its release" {
    need zsh
    make_plugin_release
    mkdir -p "$RELEASE_DIR/bin"
    # A stand-in for bin/tlogger that prints its arguments and exits 7.
    cat > "$RELEASE_DIR/bin/tlogger" << 'EOF'
#!/bin/sh
printf 'release tlogger:'
printf ' %s' "$@"
printf '\n'
exit 7
EOF
    chmod +x "$RELEASE_DIR/bin/tlogger"
    # zsh expands these, not bash.
    # shellcheck disable=SC2016
    run --separate-stderr zsh -f -i -c 'source "$1"; tlogger uninstall --dry-run' zsh "$PLUGIN" < /dev/null
    [ "$status" -eq 7 ]
    [ "$output" = "release tlogger: uninstall --dry-run" ]
}

# bats test_tags=root
@test "in a root shell with another user's HOME the plugin defines nothing" {
    need zsh
    if (( EUID != 0 )); then
        skip "it runs only as root"
    fi
    local root_home
    make_plugin_release
    root_home=$(getent passwd 0 | cut -d: -f6)
    # zsh expands these, not bash.
    # shellcheck disable=SC2016
    run --separate-stderr zsh -f -i -c 'source "$1"; print -r -- "${+functions[tlogger]} ${+_tlogger_release}"' zsh "$PLUGIN" < /dev/null
    [ "$status" -eq 0 ]
    [ "$output" = "0 0" ]
    # shellcheck disable=SC2016
    run --separate-stderr env HOME="${root_home:-/root}" zsh -f -i -c 'source "$1"; print -r -- "${+functions[tlogger]} ${+_tlogger_release}"' zsh "$PLUGIN" < /dev/null
    [ "$status" -eq 0 ]
    [ "$output" = "1 1" ]
}
