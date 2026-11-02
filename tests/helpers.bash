# shellcheck shell=bash
# Test helpers, sourced by every .bats file in tests/ through `load helpers`. Each test gets its
# own home, so neither the developer's git settings nor their real denylist can reach it, and can
# build a throwaway git repository that runs the hooks under test against a synthetic denylist.

# The repository under test, and the synthetic term the denylist tests use.
REPO_ROOT="${BATS_TEST_DIRNAME%/*}"
DENY_TERM=forbidden-term-example

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
