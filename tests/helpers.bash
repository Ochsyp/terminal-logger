# shellcheck shell=bash
# Test helpers, sourced by every .bats file in tests/ through `load helpers`. Each test gets its
# own home, so that neither the developer's git settings, denylist or zsh files can reach it.
# Also: throwaway git repositories for the hook tests, need() for tests that only some machines
# can run, a zsh stub first on PATH where zsh is missing, a fake sysfs and journal line checks.

# The repository under test, and the synthetic term the denylist tests use.
REPO_ROOT="${BATS_TEST_DIRNAME%/*}"
DENY_TERM=forbidden-term-example

# bin/tlogger, and the block it writes for the default layout, byte for byte.
TLOGGER="$REPO_ROOT/bin/tlogger"
GOLDEN_BLOCK="$REPO_ROOT/tests/golden/rc-block.zsh"

# A stand-in for util-linux script that passes the smoke test of auto mode. Wherever install or
# tlogger mode must pass that test, installer.bats and mode.bats name it, in TLOGGER_RECORDER or in
# the config's recorder=, so that they run without script; e2e-auto.bats runs the real one.
# shellcheck disable=SC2034 # The .bats files use it.
STUB_RECORDER="$REPO_ROOT/tests/stub-bin/tlogger-test-recorder"

# A stand-in for ip that answers 'ip -o addr show' with fixed lines; journal.bats and
# e2e-prompt.bats name it in TLOGGER_IP, since CI has no iproute2.
# shellcheck disable=SC2034 # The .bats files use it.
STUB_IP="$REPO_ROOT/tests/stub-bin/tlogger-test-ip"

# The real zsh, found before the stub can shadow it, or empty. Without one, tests/stub-bin goes
# first on PATH, so that bin/tlogger still gets answers to what it asks zsh; the stub refuses to
# run when TLOGGER_CI=1, so CI cannot pass on it.
REAL_ZSH=$(command -v zsh 2> /dev/null) || REAL_ZSH=
if [[ $REAL_ZSH == "$REPO_ROOT/tests/stub-bin/zsh" ]]; then
    REAL_ZSH=
fi
if [[ -z $REAL_ZSH ]]; then
    PATH="$REPO_ROOT/tests/stub-bin:$PATH"
fi

# Give the test its own HOME, XDG_CONFIG_HOME and TMPDIR under BATS_TEST_TMPDIR, and set DENYLIST
# to the path the hooks read there. Keeps out the system and global git config, git's identity
# variables, TERMINAL_LOGGER_DENYLIST and the repository variables a hook exports, such as
# GIT_DIR and GIT_INDEX_FILE. Call from setup(), so that every test starts from an empty home.
isolate_home() {
    local var
    export HOME="$BATS_TEST_TMPDIR/home"
    export XDG_CONFIG_HOME="$HOME/.config"
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"
    export GIT_CONFIG_NOSYSTEM=1
    while IFS= read -r var; do
        unset "$var"
    done < <(git rev-parse --local-env-vars)
    unset GIT_CONFIG_GLOBAL GIT_TEMPLATE_DIR TERMINAL_LOGGER_DENYLIST \
        GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
    DENYLIST="$XDG_CONFIG_HOME/terminal-logger-dev/denylist"
    mkdir -p "$XDG_CONFIG_HOME" "$TMPDIR"
}

# Prepare a test of bin/tlogger: unset ZDOTDIR, the XDG base folder variables, BASH_ENV and every
# TLOGGER_ variable but TLOGGER_CI, so that the defaults under the test's HOME apply and no file
# of the developer's runs inside bash. Call after isolate_home; fails unless HOME is a test home.
isolate_tlogger() {
    local var
    require_test_home || return 1
    unset ZDOTDIR XDG_DATA_HOME XDG_CONFIG_HOME XDG_STATE_HOME BASH_ENV
    for var in "${!TLOGGER_@}"; do
        if [[ $var != TLOGGER_CI ]]; then
            unset "$var"
        fi
    done
    mkdir -p "$HOME"
}

# Fail unless HOME lies under BATS_TEST_TMPDIR, so that no test runs bin/tlogger on a real home.
require_test_home() {
    if [[ $HOME != "$BATS_TEST_TMPDIR"/* ]]; then
        printf 'HOME is not under BATS_TEST_TMPDIR, so bin/tlogger does not run on it\n' >&2
        return 1
    fi
}

# Create a git repository at $REPO under BATS_TEST_TMPDIR, on main, with a test identity and
# without commit signing. Makes one commit before the hooks are turned on, then points
# core.hooksPath at the hooks under test. Sets REPO; call after isolate_home.
make_repo() {
    REPO="$BATS_TEST_TMPDIR/repo"
    git init -q -b main "$REPO"
    git -C "$REPO" config user.name "Test User"
    git -C "$REPO" config user.email test@example.invalid
    git -C "$REPO" config commit.gpgsign false
    printf 'synthetic test repository\n' > "$REPO/README.md"
    git -C "$REPO" add README.md
    git -C "$REPO" commit -q -m "chore: initial commit"
    git -C "$REPO" config core.hooksPath "$REPO_ROOT/.githooks"
}

# Write the denylist the hooks read, $DENYLIST, one line per argument.
# Without arguments it holds a comment, a blank line and DENY_TERM. Every line must be
# synthetic; call after isolate_home.
write_denylist() {
    (( $# )) || set -- '# Synthetic denylist for the hook tests.' '' "$DENY_TERM"
    mkdir -p "${DENYLIST%/*}"
    printf '%s\n' "$@" > "$DENYLIST"
}

# Skip the test unless this machine has FEATURE: zsh (a real one), zpty (zsh with the zsh/zpty
# and zsh/zselect modules), script (util-linux script 2.35 or newer at /usr/bin/script), proc
# (the Linux /proc), symlinks, modes (POSIX file modes), hardlinks, 'command NAME' or 'file PATH'
# (readable). With TLOGGER_CI=1 the test fails instead, since CI must run every test. Call it
# before the test writes anything.
need() {
    local why help
    case $1 in
        zsh)
            if [[ -n $REAL_ZSH ]]; then return 0; fi
            why="it needs a real zsh"
            ;;
        zpty)
            if [[ -n $REAL_ZSH ]] && "$REAL_ZSH" -f -c 'zmodload zsh/zpty zsh/zselect' < /dev/null 2> /dev/null; then
                return 0
            fi
            why="it needs a real zsh with the zsh/zpty and zsh/zselect modules"
            ;;
        script)
            help=$(/usr/bin/script --help 2> /dev/null) || help=
            if [[ $help == *--logging-format* ]]; then return 0; fi
            why="it needs util-linux script 2.35 or newer at /usr/bin/script"
            ;;
        proc)
            if [[ $(uname -s) == Linux && -r /proc/self/stat && -r /proc/sys/kernel/random/boot_id ]]; then
                return 0
            fi
            why="it needs the Linux /proc"
            ;;
        symlinks)
            if has_symlinks; then return 0; fi
            why="it needs symlinks, which ln -s does not make here"
            ;;
        modes)
            if has_modes; then return 0; fi
            why="it needs POSIX file modes, which chmod does not set here"
            ;;
        hardlinks)
            if has_hardlinks; then return 0; fi
            why="it needs hard links, which ln does not make here"
            ;;
        command)
            if command -v "$2" > /dev/null 2>&1; then return 0; fi
            why="it needs $2 on PATH"
            ;;
        file)
            if [[ -r $2 ]]; then return 0; fi
            why="it needs the file $2"
            ;;
        *)
            printf 'need: unknown feature %s\n' "$1" >&2
            return 1
            ;;
    esac
    if [[ ${TLOGGER_CI:-} == 1 ]]; then
        printf 'need: %s, and TLOGGER_CI=1 forbids a skip\n' "$why" >&2
        return 1
    fi
    skip "$why"
}

# Create a fake sysfs at DIR for the plugin's VPN list, as TLOGGER_SYSFS names it: the folder
# DIR/class/net, and for each NAME=IFINDEX argument a folder DIR/class/net/NAME with an ifindex
# file. A NAME is data, never run, and may hold any character but / and =.
fake_sysfs() {
    local dir=$1 arg
    shift
    mkdir -p "$dir/class/net"
    for arg in "$@"; do
        mkdir -p "$dir/class/net/${arg%%=*}"
        printf '%s\n' "${arg#*=}" > "$dir/class/net/${arg%%=*}/ifindex"
    done
}

# Set FIELDS to the fields of the journal line LINE, split at each tab, empty fields kept.
split_tabs() {
    local line=$1
    FIELDS=()
    while [[ $line == *$'\t'* ]]; do
        FIELDS+=("${line%%$'\t'*}")
        line=${line#*$'\t'}
    done
    FIELDS+=("$line")
}

# Fail, naming the line, unless LINE is a journal S line of the shell PID with the folder PWD,
# the VPN field VPN and the typed text TYPED, each as the journal writes it, and a UTC field
# that is date -u's time for its epoch. Sets FIELDS.
assert_s_line() {
    split_tabs "$1"
    if [[ ${#FIELDS[@]} -ne 7 || ${FIELDS[0]} != S || ! ${FIELDS[1]} =~ ^[0-9]+$ ||
        ${FIELDS[2]} != "$(date -u -d "@${FIELDS[1]}" +%Y-%m-%dT%H:%M:%SZ)" ||
        ${FIELDS[3]} != "$2" || ${FIELDS[4]} != "$3" || ${FIELDS[5]} != "$4" ||
        ${FIELDS[6]} != "$5" ]]; then
        printf 'expected the S line of pid %s for %s in %s, VPN %s; got:\n%s\n' \
            "$2" "$5" "$3" "$4" "$1" >&2
        return 1
    fi
}

# Fail, naming the line, unless LINE is a journal E line of the shell PID with the exit status
# STATUS. Sets FIELDS.
assert_e_line() {
    split_tabs "$1"
    if [[ ${#FIELDS[@]} -ne 4 || ${FIELDS[0]} != E || ! ${FIELDS[1]} =~ ^[0-9]+$ ||
        ${FIELDS[2]} != "$2" || ${FIELDS[3]} != "$3" ]]; then
        printf 'expected the E line of pid %s with status %s; got:\n%s\n' "$2" "$3" "$1" >&2
        return 1
    fi
}

# Succeed when ln -s makes a real symlink, even to a missing target, as on Linux. Git for Windows
# copies the target instead, or fails when it is missing.
has_symlinks() {
    local dir="$BATS_TEST_TMPDIR/need-symlinks"
    mkdir -p "$dir"
    rm -f "$dir/link"
    ln -s missing-target "$dir/link" 2> /dev/null && [[ -L $dir/link ]]
}

# Succeed when chmod sets the mode that stat then reports, as on Linux.
has_modes() {
    local file="$BATS_TEST_TMPDIR/need-modes"
    : > "$file" && chmod 600 "$file" && [[ $(stat -c %a "$file") == 600 ]]
}

# Succeed when ln makes a second hard link that stat counts.
has_hardlinks() {
    local dir="$BATS_TEST_TMPDIR/need-hardlinks"
    mkdir -p "$dir"
    rm -f "$dir/a" "$dir/b"
    : > "$dir/a" && ln "$dir/a" "$dir/b" 2> /dev/null && [[ $(stat -c %h "$dir/a") == 2 ]]
}

# Run bin/tlogger with ARGS through bats `run --separate-stderr`: under bash, so that the test
# does not depend on the executable bit, and with stdin from /dev/null, so that it sees no
# terminal. Sets status, output (stdout) and stderr; the .bats file must require bats 1.5.0.
# Fails without running it unless HOME is a test home.
run_tlogger() {
    require_test_home || return 1
    run --separate-stderr bash "$TLOGGER" "$@" < /dev/null
}

# Fail unless the first 4 lines of FILE are the golden block, byte for byte.
# For the default layout under HOME, which isolate_tlogger sets up.
assert_block_on_top() {
    head -n 4 "$1" | cmp - "$GOLDEN_BLOCK"
}

# Print the SHA-256 of FILE.
sha_of() {
    local sum
    sum=$(sha256sum < "$1") || return 1
    printf '%s\n' "${sum%% *}"
}

# Fail, naming what exists, if the test's home holds the tlogger code, config or state folder.
# For the default layout under HOME, which isolate_tlogger sets up.
refute_tlogger_folders() {
    local dir found=0
    for dir in "$HOME/.local/share/tlogger" "$HOME/.config/tlogger" "$HOME/.local/state/tlogger"; do
        if [[ -e $dir || -L $dir ]]; then
            printf 'tlogger created ~/%s\n' "${dir#"$HOME"/}" >&2
            found=1
        fi
    done
    (( found == 0 ))
}

# Fail, listing what is left, unless bin/tlogger left no temp file: TMPDIR must be empty, and no
# temp name of its own may remain beside the rc in ZDOT (default HOME), in the config folder, the
# data folder or the releases folder. For the default XDG layout under HOME.
refute_temp_left() {
    local zdot=${1:-$HOME} left path data="$HOME/.local/share/tlogger"
    local -a found=()
    left=$(ls -A "$TMPDIR")
    if [[ -n $left ]]; then
        printf 'tlogger left files in TMPDIR:\n%s\n' "$left" >&2
        return 1
    fi
    for path in "$zdot"/.zshrc.tlogger.* "$HOME/.config/tlogger"/.config.* "$data"/.current.* \
        "$data/releases"/.build.* "$data/releases"/.old.*; do
        if [[ -e $path || -L $path ]]; then
            found+=("$path")
        fi
    done
    if (( ${#found[@]} )); then
        printf 'tlogger left temp files:\n' >&2
        printf '  %s\n' "${found[@]}" >&2
        return 1
    fi
}
