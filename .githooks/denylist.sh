# shellcheck shell=sh
# Denylist check for the pre-commit and commit-msg hooks, which source this file; git never runs
# it as a hook. The denylist is a local file outside the repository that lists terms, such as
# names, host names and home paths, that must never be committed.

# The denylist file, and the private temp directory that denylist_load fills.
denylist_file=${TERMINAL_LOGGER_DENYLIST:-${XDG_CONFIG_HOME:-$HOME/.config}/terminal-logger-dev/denylist}
denylist_dir=

# The denylist path as messages show it. A home path often holds a term, so HOME shows as ~.
denylist_shown=$denylist_file
if [ -n "${HOME:-}" ]; then
    case $denylist_file in
        "$HOME"/*) denylist_shown="~${denylist_file#"$HOME"}" ;;
    esac
fi

# Print "HOOK: PROBLEM, so the commit is refused." on stderr and exit 1.
# For a check that cannot run, so that a broken check never lets a change through.
denylist_fail() {
    printf '%s: %s, so the commit is refused.\n' "$1" "$2" >&2
    exit 1
}

# Load the denylist's terms into the private temp file $denylist_dir/terms, one per line.
# $1 names the hook in messages; a byte order mark, blank lines and '#' comments are skipped.
# Returns 1 after one note on stderr when the denylist is missing or holds no term, and exits 1
# when it is unreadable or holds NUL bytes. Sets umask 077 and the cleanup traps; set no others.
denylist_load() {
    if [ ! -e "$denylist_file" ]; then
        printf '%s: no denylist at %s, so the denylist check is skipped.\n' \
            "$1" "$denylist_shown" >&2
        return 1
    fi
    umask 077
    denylist_dir=$(mktemp -d "${TMPDIR:-/tmp}/terminal-logger.XXXXXX") ||
        denylist_fail "$1" "cannot create a temp directory for the denylist check"
    trap denylist_cleanup EXIT
    trap 'exit 1' HUP INT TERM
    # Whitespace around a term, the CR of a CRLF line included, is not part of the term, and nor
    # is the UTF-8 byte order mark some editors write. sed's own error would show the full path.
    sed -e "1s/^$(printf '\357\273\277')//" -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
        -e '/^#/d' -e '/^$/d' "$denylist_file" > "$denylist_dir/terms" 2> /dev/null ||
        denylist_fail "$1" "cannot read the denylist at $denylist_shown"
    # UTF-16 text holds NUL bytes, and its terms would never match the UTF-8 text they guard.
    # Both commands only read the denylist, so SC2094 does not apply; their errors would show the
    # full path, as sed's would.
    # shellcheck disable=SC2094
    tr -d '\000' < "$denylist_file" 2> /dev/null | cmp -s - "$denylist_file" 2> /dev/null ||
        denylist_fail "$1" "the denylist at $denylist_shown holds NUL bytes and is not UTF-8 text"
    if [ ! -s "$denylist_dir/terms" ]; then
        printf '%s: the denylist at %s holds no term, so the denylist check is skipped.\n' \
            "$1" "$denylist_shown" >&2
        return 1
    fi
}

# Succeed when FILE, or standard input without one, holds a denylist term in any case.
# Binary data is searched as text, so a NUL byte cannot hide a term. Returns 1 when no term
# matches and 2 when grep fails. Call after denylist_load has returned 0.
denylist_match() {
    grep -a -i -q -F -f "$denylist_dir/terms" "$@"
}

# Remove $denylist_dir and the files in it, at exit through the traps denylist_load sets.
# Does nothing before denylist_load has made the directory.
denylist_cleanup() {
    [ -n "$denylist_dir" ] || return 0
    rm -f -- "$denylist_dir"/*
    rmdir -- "$denylist_dir"
}
