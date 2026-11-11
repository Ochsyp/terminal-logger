#!/usr/bin/env bats
# Tests for the autostart guard, _tlogger_autostart_why, in a real zsh without a terminal: each
# reason in the order of its contract, the presets and config keys it reads, and its silence. The
# guard runs from a script file under zsh -f -i, since zsh -c sets ZSH_EXECUTION_STRING, itself a
# reason. They need a real zsh.

bats_require_minimum_version 1.5.0

load helpers

# What an SSH login sets, with addresses from the documentation range, and what a tmux pane sets.
SSH_LOGIN='SSH_CONNECTION=192.0.2.10 50000 192.0.2.20 22'
TMUX_PANE='TMUX=/tmp/tmux-1000/default,4242,0'

# Run before each test by bats.
# Gives the test its own HOME and config folder, and writes the script that runs the guard.
setup() {
    isolate_home
    isolate_tlogger
    need zsh
    CONFIG="$HOME/.config/tlogger/config"
    WHY_SCRIPT="$BATS_TEST_TMPDIR/why.zsh"
    mkdir -p "${CONFIG%/*}"
    # zsh runs it: it sources the plugin named by its first argument, then prints the reason.
    cat > "$WHY_SCRIPT" << 'EOF'
source $1 || exit 1
_tlogger_autostart_why
print -r -- "why: $REPLY"
EOF
}

# Run WHY_SCRIPT through bats `run --separate-stderr` in zsh -f -i, with stdin from /dev/null and
# only HOME, PATH and the NAME=VALUE arguments in its environment. Sourcing the plugin runs its own
# autostart first, which stops at a reason, at the latest at the terminal check.
run_why() {
    run --separate-stderr env -i HOME="$HOME" PATH="$PATH" "$@" zsh -f -i "$WHY_SCRIPT" \
        "$REPO_ROOT/lib/tlogger.zsh" < /dev/null
}

# Fail unless the last run exited 0, printed 'why: REASON' and nothing else, wrote nothing on
# stderr, and recorded nothing: the state folder does not exist.
assert_why() {
    if [[ $status -ne 0 || $output != "why: $1" || -n $stderr ]]; then
        printf 'expected the reason: %s\ngot, with exit %s:\n%s\nstderr:\n%s\n' \
            "$1" "$status" "$output" "$stderr" >&2
        return 1
    fi
    [ ! -e "$HOME/.local/state/tlogger" ]
}

@test "a mode other than auto is the first reason, before every other one" {
    run_why
    assert_why 'the mode is not auto'
    printf 'mode=manual\nrecord_ssh=no\nrecord_tmux=no\n' > "$CONFIG"
    run_why ZSH_EXECUTION_STRING=true VSCODE_RESOLVING_ENVIRONMENT=1 ASCIINEMA_REC=1 \
        "$SSH_LOGIN" "$TMUX_PANE"
    assert_why 'the mode is not auto'
}

@test "an exported TLOGGER_MODE wins over the config's mode either way, trimmed" {
    printf 'mode=auto\n' > "$CONFIG"
    run_why TLOGGER_MODE=manual
    assert_why 'the mode is not auto'
    printf 'mode=manual\n' > "$CONFIG"
    run_why TLOGGER_MODE=auto
    assert_why 'not an interactive shell on a terminal'
    rm "$CONFIG"
    run_why 'TLOGGER_MODE= auto '
    assert_why 'not an interactive shell on a terminal'
}

@test "the later reasons come in their order: zsh -c, VS Code, asciinema, SSH, tmux, the terminal" {
    local i
    # Each run leaves out the first variable of the run before it, so that it trips the next guard.
    local -a vars=(ZSH_EXECUTION_STRING=true VSCODE_RESOLVING_ENVIRONMENT=1 ASCIINEMA_REC=1
        "$SSH_LOGIN" "$TMUX_PANE")
    local -a reasons=('ZSH_EXECUTION_STRING is set' 'VSCODE_RESOLVING_ENVIRONMENT is set'
        'ASCIINEMA_REC or ASCIINEMA_SESSION is set' 'an SSH login, and record_ssh is no'
        'a tmux pane, and record_tmux is no' 'not an interactive shell on a terminal')
    printf 'mode=auto\nrecord_ssh=no\nrecord_tmux=no\n' > "$CONFIG"
    for (( i = 0; i < ${#reasons[@]}; i++ )); do
        run_why "${vars[@]:i}"
        assert_why "${reasons[i]}"
    done
}

@test "zsh -c sets ZSH_EXECUTION_STRING, so an IDE's zsh -i -c stops at it, and set at all counts" {
    printf 'mode=auto\n' > "$CONFIG"
    # zsh expands these, not bash.
    # shellcheck disable=SC2016
    run --separate-stderr env -i HOME="$HOME" PATH="$PATH" zsh -f -i -c \
        'source $1 || exit 1; _tlogger_autostart_why; print -r -- "why: $REPLY"' \
        zsh "$REPO_ROOT/lib/tlogger.zsh" < /dev/null
    assert_why 'ZSH_EXECUTION_STRING is set'
    # zsh -c '' sets it to the empty string.
    run_why ZSH_EXECUTION_STRING=
    assert_why 'ZSH_EXECUTION_STRING is set'
}

@test "ASCIINEMA_SESSION and SSH_TTY count on their own, and an empty variable counts as unset" {
    printf 'mode=auto\nrecord_ssh=no\nrecord_tmux=no\n' > "$CONFIG"
    run_why ASCIINEMA_SESSION=demo
    assert_why 'ASCIINEMA_REC or ASCIINEMA_SESSION is set'
    run_why SSH_TTY=/dev/pts/7
    assert_why 'an SSH login, and record_ssh is no'
    run_why VSCODE_RESOLVING_ENVIRONMENT= ASCIINEMA_REC= ASCIINEMA_SESSION= SSH_CONNECTION= \
        SSH_TTY= TMUX=
    assert_why 'not an interactive shell on a terminal'
}

@test "record_ssh and record_tmux default to yes, and their presets win over the config, trimmed" {
    printf 'mode=auto\n' > "$CONFIG"
    run_why "$SSH_LOGIN" "$TMUX_PANE"
    assert_why 'not an interactive shell on a terminal'
    run_why "$SSH_LOGIN" TLOGGER_RECORD_SSH=no
    assert_why 'an SSH login, and record_ssh is no'
    run_why "$TMUX_PANE" 'TLOGGER_RECORD_TMUX= no '
    assert_why 'a tmux pane, and record_tmux is no'
    printf 'mode=auto\nrecord_ssh=no\nrecord_tmux=no\n' > "$CONFIG"
    run_why "$SSH_LOGIN" "$TMUX_PANE" TLOGGER_RECORD_SSH=yes TLOGGER_RECORD_TMUX=yes
    assert_why 'not an interactive shell on a terminal'
    # The two policies apply only to SSH logins and tmux panes.
    run_why
    assert_why 'not an interactive shell on a terminal'
}

@test "an invalid record_ssh or record_tmux warns once and counts as yes" {
    printf 'mode=auto\nrecord_tmux=sometimes\n' > "$CONFIG"
    run_why "$SSH_LOGIN" "$TMUX_PANE" TLOGGER_RECORD_SSH=maybe
    [ "$status" -eq 0 ]
    [ "$output" = 'why: not an interactive shell on a terminal' ]
    [ "${#stderr_lines[@]}" -eq 2 ]
    [ "${stderr_lines[0]}" = 'tlogger: warning: TLOGGER_RECORD_SSH: record_ssh must be yes or no; using yes' ]
    [ "${stderr_lines[1]}" = 'tlogger: warning: ~/.config/tlogger/config line 2: record_tmux must be yes or no; using yes' ]
    [ ! -e "$HOME/.local/state/tlogger" ]
}
