# shellcheck shell=bash
# Test helpers, sourced by every .bats file in tests/ through `load helpers`. Each test gets its
# own home, so that neither the developer's git settings, denylist or zsh files can reach it.
# Also: throwaway git repositories for the hook tests, need() for tests that only some machines
# can run, a zsh stub first on PATH where zsh is missing, a fake sysfs, journal line checks and
# synthetic session logs for render, show and replay.

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

# The python3 that the tests run libexec/tlogger_view.py with, VIEW, as bin/tlogger runs it: the
# first python3 on PATH, or empty. need python3 checks that it runs, since on Windows the first
# python3 on PATH can be the Store's stub, which only exits 9009.
PYTHON3=$(command -v python3 2> /dev/null) || PYTHON3=
# shellcheck disable=SC2034 # The .bats files use it.
VIEW="$REPO_ROOT/libexec/tlogger_view.py"

# The bytes the replay filter writes last, at the end of its input or on SIGHUP, SIGINT, SIGQUIT
# or SIGTERM: the normal screen, the full scroll region with the cursor kept, ASCII in G0 and G1,
# SGR 0, replace mode, autowrap, a visible cursor, and mouse reporting, its encodings, focus
# reporting and bracketed paste turned off. filter.bats checks them byte for byte, as a contract.
# shellcheck disable=SC2034 # The .bats files use it.
FILTER_RESTORE=$'\e[?1047l\e7\e[r\e8\e(B\e)B\e[0m\e[4l\e[?7h\e[?25h\e[?9l\e[?1000l\e[?1001l\e[?1002l\e[?1003l\e[?1005l\e[?1006l\e[?1015l\e[?1016l\e[?1004l\e[?2004l'

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
# and zsh/zselect modules), script (util-linux script 2.35 or newer at /usr/bin/script),
# scriptreplay (util-linux scriptreplay 2.35 or newer at /usr/bin/scriptreplay), python3 (a
# PYTHON3 that runs), python3-signals (a POSIX PYTHON3, to which kill sends real signals), pyte
# (a POSIX PYTHON3 that imports pyte), proc (the Linux /proc), symlinks, modes (POSIX file
# modes), hardlinks, 'command NAME' or 'file PATH' (readable). With TLOGGER_CI=1 the test fails
# instead, since CI must run every test. Call it before the test writes anything.
need() {
    local why help
    case $1 in
        python3)
            if [[ -n $PYTHON3 ]] && "$PYTHON3" -I -c 'import sys' < /dev/null > /dev/null 2>&1; then
                return 0
            fi
            why="it needs a python3 on PATH that runs"
            ;;
        python3-signals)
            if [[ -n $PYTHON3 ]] && "$PYTHON3" -I -c 'import os, sys; sys.exit(os.name != "posix")' \
                < /dev/null > /dev/null 2>&1; then
                return 0
            fi
            why="it needs a POSIX python3 on PATH, to which kill sends real signals"
            ;;
        pyte)
            if [[ -n $PYTHON3 ]] && "$PYTHON3" -I -c 'import os, sys, pyte; sys.exit(os.name != "posix")' \
                < /dev/null > /dev/null 2>&1; then
                return 0
            fi
            why="it needs a POSIX python3 on PATH with pyte (python3-pyte)"
            ;;
        scriptreplay)
            help=$(/usr/bin/scriptreplay --help 2> /dev/null) || help=
            if [[ $help == *--log-timing* ]]; then return 0; fi
            why="it needs util-linux scriptreplay 2.35 or newer at /usr/bin/scriptreplay"
            ;;
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

# Start the synthetic session folder DIR, mode 0700, as util-linux script leaves one when it
# starts in a terminal of COLS x ROWS (default 80 x 24): output.raw with script's header line,
# which no O entry covers, timing with script's first H lines, and an empty input.raw and
# commands.tsv, all mode 0600. Sets SDIR, which the other session_ functions add to.
session_new() {
    local cols=${2:-80} rows=${3:-24} f
    SDIR=$1
    mkdir -p "$SDIR"
    chmod 700 "$SDIR"
    printf 'Script started on 2026-11-12 10:00:00+00:00 [TERM="xterm-256color" TTY="/dev/pts/1" COLUMNS="%s" LINES="%s"]\n' \
        "$cols" "$rows" > "$SDIR/output.raw"
    printf 'H 0.000000 %s\n' 'START_TIME 2026-11-12 10:00:00+00:00' 'TERM xterm-256color' \
        'TTY /dev/pts/1' "COLUMNS $cols" "LINES $rows" 'SHELL /usr/bin/zsh' \
        "TIMING_LOG /home/kali/.local/state/tlogger/sessions/${SDIR##*/}/timing" \
        "OUTPUT_LOG /home/kali/.local/state/tlogger/sessions/${SDIR##*/}/output.raw" \
        "INPUT_LOG /home/kali/.local/state/tlogger/sessions/${SDIR##*/}/input.raw" > "$SDIR/timing"
    : > "$SDIR/input.raw"
    : > "$SDIR/commands.tsv"
    for f in output.raw timing input.raw commands.tsv; do
        chmod 600 "$SDIR/$f"
    done
}

# Add the bytes that printf %b makes of TEXT to output.raw of SDIR, as one O entry: output the
# terminal showed. TEXT takes the escapes of printf %b, such as \e, \r and \xHH; % is plain.
session_out() {
    local chunk="$BATS_TEST_TMPDIR/session-chunk"
    printf '%b' "$1" > "$chunk"
    cat "$chunk" >> "$SDIR/output.raw"
    printf 'O 0.010000 %s\n' "$(( $(wc -c < "$chunk") ))" >> "$SDIR/timing"
}

# Add the bytes that printf %b makes of TEXT to input.raw of SDIR, as one I entry: keys typed,
# which the terminal may or may not have shown.
session_in() {
    local chunk="$BATS_TEST_TMPDIR/session-chunk"
    printf '%b' "$1" > "$chunk"
    cat "$chunk" >> "$SDIR/input.raw"
    printf 'I 0.200000 %s\n' "$(( $(wc -c < "$chunk") ))" >> "$SDIR/timing"
}

# Add a SIGWINCH entry to the timing file of SDIR: the terminal is ROWS x COLS from there on.
session_winch() {
    printf 'S 0.300000 SIGWINCH ROWS=%s COLS=%s\n' "$1" "$2" >> "$SDIR/timing"
}

# Add each LINE to the timing file of SDIR as it is, well formed or not.
session_timing() {
    printf '%s\n' "$@" >> "$SDIR/timing"
}

# End the session in SDIR as script does: the trailer of output.raw, which no O entry covers,
# and the last H lines of the timing file.
session_end() {
    printf '\nScript done on 2026-11-12 10:01:00+00:00 [COMMAND_EXIT_CODE="0"]\n' >> "$SDIR/output.raw"
    printf 'H 0.000000 %s\n' 'DURATION 60.000000' 'EXIT_CODE 0' >> "$SDIR/timing"
}

# Fail unless the first line of the transcript FILE is the header that render writes for the
# session ID with the tlogger version VERSION, stamped with a UTC time of the last 10 minutes.
assert_transcript_header() {
    local header stamp when now
    IFS= read -r header < "$1" || true
    stamp=${header##*, rendered }
    if [[ $header != "# DERIVED transcript of session $2; the evidence is output.raw with timing. tlogger $3, rendered $stamp" ||
        ! $stamp =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
        printf 'not the transcript header for session %s and tlogger %s:\n%s\n' "$2" "$3" "$header" >&2
        return 1
    fi
    when=$(date -u -d "$stamp" +%s)
    now=$(date -u +%s)
    if (( now - when < 0 || now - when > 600 )); then
        printf 'the transcript header names %s, not a time of the last 10 minutes\n' "$stamp" >&2
        return 1
    fi
}

# Fail, naming FILE, if it holds a control character: ESC or any other C0 control but the line
# feed, DEL, or a C1 control (U+0080 to U+009F) in UTF-8. LC_ALL=C makes grep match bytes.
refute_controls() {
    if LC_ALL=C grep -q '[[:cntrl:]]' "$1" || LC_ALL=C grep -q $'\xc2[\x80-\x9f]' "$1"; then
        printf '%s holds a control character:\n' "$1" >&2
        LC_ALL=C grep -n -m 5 -e '[[:cntrl:]]' -e $'\xc2[\x80-\x9f]' "$1" | od -c | head -n 20 >&2
        return 1
    fi
}
