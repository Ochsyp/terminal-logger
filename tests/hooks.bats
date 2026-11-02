#!/usr/bin/env bats
# Tests for the git hooks in .githooks: the branch guards of pre-commit, pre-merge-commit and
# pre-push, and the denylist checks of pre-commit and commit-msg. Every denylist term is synthetic.

load helpers

# Object ids for the ref lines git feeds pre-push on stdin; the hook reads only the refs.
LOCAL_OID=1111111111111111111111111111111111111111
ZERO_OID=0000000000000000000000000000000000000000

# Run before each test by bats.
# Gives the test its own home and TMPDIR, so no real denylist or git setting reaches it.
setup() {
    isolate_home
}

# Write CONTENT and a newline to FILE, a path relative to $REPO, and stage it.
# Creates the parent directories FILE needs.
stage() {
    mkdir -p "$(dirname "$REPO/$1")"
    printf '%s\n' "$2" > "$REPO/$1"
    git -C "$REPO" add -- "$1"
}

# Print TEXT as UTF-16LE text with a byte order mark and a CRLF line end.
# TEXT must be ASCII; printf builds the bytes, so no iconv is needed.
utf16le() {
    local text="$1"$'\r\n' i
    printf '\377\376'
    for (( i = 0; i < ${#text}; i++ )); do
        printf '%s\000' "${text:i:1}"
    done
}

# Run `git commit -m MESSAGE` in $REPO through bats `run`, so the hooks run as git runs them.
# Sets status and output, which holds the hooks' stderr.
try_commit() {
    run git -C "$REPO" commit -q -m "$1"
}

# Print the number of commits reachable from HEAD in $REPO.
# Call after make_repo, whose initial commit counts as one.
commit_count() {
    git -C "$REPO" rev-list --count HEAD
}

# Fail, printing the output, if $output shows DENY_TERM in any case.
# Reads $output from the last bats `run`.
refute_term_shown() {
    if [[ "${output,,}" == *"$DENY_TERM"* ]]; then
        printf 'the output shows the denylist term:\n%s\n' "$output" >&2
        return 1
    fi
}

# Fail, listing what is left, unless TMPDIR is empty after the hooks ran.
# isolate_home points TMPDIR at an empty directory of the test's own.
assert_tmpdir_empty() {
    local left
    left=$(ls -A "$TMPDIR")
    if [[ -n "$left" ]]; then
        printf 'the hooks left files in TMPDIR:\n%s\n' "$left" >&2
        return 1
    fi
}

# Run the pre-push hook through bats `run` with one ref line on stdin, as git writes it, that
# pushes a local branch to the remote ref REF. Sets status and output. The hook runs under sh,
# so this test does not depend on its executable bit.
run_pre_push() {
    run sh "$REPO_ROOT/.githooks/pre-push" origin https://example.invalid/terminal-logger.git \
        <<< "refs/heads/feat/example $LOCAL_OID $1 $ZERO_OID"
}

@test "pre-commit refuses a commit on main" {
    make_repo
    stage notes.txt 'synthetic notes'
    try_commit "docs: add notes"
    [ "$status" -ne 0 ]
    [[ "$output" == *"commits on 'main' are refused"* ]]
    [ "$(commit_count)" -eq 1 ]
}

@test "pre-commit refuses a commit on master" {
    make_repo
    git -C "$REPO" branch -m master
    stage notes.txt 'synthetic notes'
    try_commit "docs: add notes"
    [ "$status" -ne 0 ]
    [[ "$output" == *"commits on 'master' are refused"* ]]
    [ "$(commit_count)" -eq 1 ]
}

@test "pre-commit refuses a commit on main while a tag named main exists" {
    make_repo
    git -C "$REPO" tag main
    stage notes.txt 'synthetic notes'
    try_commit "docs: add notes"
    [ "$status" -ne 0 ]
    [[ "$output" == *"commits on 'main' are refused"* ]]
    [ "$(commit_count)" -eq 1 ]
}

@test "pre-commit allows a commit on a feature branch" {
    make_repo
    write_denylist
    git -C "$REPO" switch -q -c feat/example
    stage notes.txt 'synthetic notes'
    try_commit "docs: add notes"
    [ "$status" -eq 0 ]
    [ "$(commit_count)" -eq 2 ]
    assert_tmpdir_empty
}

@test "pre-commit allows a commit in a detached HEAD" {
    make_repo
    write_denylist
    git -C "$REPO" switch -q --detach
    stage notes.txt 'synthetic notes'
    try_commit "docs: add notes"
    [ "$status" -eq 0 ]
    [ "$(commit_count)" -eq 2 ]
}

@test "pre-merge-commit refuses a merge commit on main" {
    make_repo
    git -C "$REPO" switch -q -c feat/example
    stage notes.txt 'synthetic notes'
    try_commit "docs: add notes"
    [ "$status" -eq 0 ]
    git -C "$REPO" switch -q main
    run git -C "$REPO" merge -q --no-ff -m "Merge feat/example" feat/example
    [ "$status" -ne 0 ]
    [[ "$output" == *"commits on 'main' are refused"* ]]
    [ "$(commit_count)" -eq 1 ]
}

@test "pre-merge-commit refuses a merge that brings in a denylist term" {
    make_repo
    # The commit predates the denylist, as it does when a term is added to the denylist later.
    git -C "$REPO" switch -q -c feat/leak
    stage docs/leak.md "contact $DENY_TERM"
    try_commit "docs: add notes"
    [ "$status" -eq 0 ]
    write_denylist
    git -C "$REPO" switch -q -c feat/merge main
    run git -C "$REPO" merge -q --no-ff -m "Merge feat/leak" feat/leak
    [ "$status" -ne 0 ]
    [[ "$output" == *"docs/leak.md"* ]]
    refute_term_shown
    [ "$(commit_count)" -eq 1 ]
}

@test "pre-commit refuses staged content that holds a denylist term in another case" {
    make_repo
    write_denylist
    git -C "$REPO" switch -q -c feat/example
    stage docs/notes.md 'Written by FORBIDDEN-Term-Example.'
    try_commit "docs: add notes"
    [ "$status" -ne 0 ]
    [[ "$output" == *"docs/notes.md"* ]]
    refute_term_shown
    [ "$(commit_count)" -eq 1 ]
}

@test "pre-commit refuses binary content that holds a denylist term" {
    make_repo
    write_denylist
    git -C "$REPO" switch -q -c feat/example
    printf 'prompt$ %s\n\000\n' "$DENY_TERM" > "$REPO/session.bin"
    git -C "$REPO" add -- session.bin
    try_commit "test: add a recording"
    [ "$status" -ne 0 ]
    [[ "$output" == *"session.bin"* ]]
    refute_term_shown
    [ "$(commit_count)" -eq 1 ]
}

@test "pre-commit refuses UTF-16 text that holds a denylist term" {
    make_repo
    write_denylist
    git -C "$REPO" switch -q -c feat/example
    utf16le "notes by $DENY_TERM" > "$REPO/notes.txt"
    git -C "$REPO" add -- notes.txt
    try_commit "docs: add notes"
    [ "$status" -ne 0 ]
    [[ "$output" == *"notes.txt"* ]]
    refute_term_shown
    [ "$(commit_count)" -eq 1 ]
}

@test "pre-commit refuses a staged path name that holds a denylist term" {
    make_repo
    write_denylist
    git -C "$REPO" switch -q -c feat/example
    stage "notes-$DENY_TERM.txt" 'synthetic notes'
    try_commit "docs: add notes"
    [ "$status" -ne 0 ]
    [[ "$output" == *"1 staged path name"* ]]
    refute_term_shown
    [ "$(commit_count)" -eq 1 ]
}

@test "pre-commit refuses a file renamed to a name with spaces whose content gains a term" {
    make_repo
    write_denylist
    git -C "$REPO" switch -q -c feat/example
    stage notes.txt "$(printf 'synthetic line %s\n' 1 2 3 4 5 6 7 8)"
    try_commit "docs: add notes"
    [ "$status" -eq 0 ]
    git -C "$REPO" mv notes.txt "meeting notes.txt"
    printf 'contact %s\n' "$DENY_TERM" >> "$REPO/meeting notes.txt"
    git -C "$REPO" add -- "meeting notes.txt"
    [[ "$(git -C "$REPO" diff --cached --name-status)" == R* ]]
    try_commit "docs: rename the notes"
    [ "$status" -ne 0 ]
    [[ "$output" == *"meeting notes.txt"* ]]
    refute_term_shown
    [ "$(commit_count)" -eq 2 ]
}

@test "pre-commit refuses a file turned into a symlink whose target holds a denylist term" {
    local blob
    make_repo
    write_denylist
    git -C "$REPO" switch -q -c feat/example
    # A symlink's staged content is its target. update-index stages one without a real symlink,
    # which not every file system allows.
    blob=$(printf '/home/%s/notes.txt' "$DENY_TERM" | git -C "$REPO" hash-object -w --stdin)
    git -C "$REPO" update-index --cacheinfo "120000,$blob,README.md"
    [[ "$(git -C "$REPO" diff --cached --name-status)" == T* ]]
    try_commit "docs: link the readme"
    [ "$status" -ne 0 ]
    [[ "$output" == *"README.md"* ]]
    refute_term_shown
    [ "$(commit_count)" -eq 1 ]
}

@test "pre-commit refuses a commit whose author holds a denylist term" {
    make_repo
    write_denylist
    git -C "$REPO" switch -q -c feat/example
    stage notes.txt 'synthetic notes'
    run git -C "$REPO" commit -q --author="${DENY_TERM^^} <author@example.invalid>" \
        -m "docs: add notes"
    [ "$status" -ne 0 ]
    [[ "$output" == *"the author or committer name or e-mail holds a term"* ]]
    refute_term_shown
    [ "$(commit_count)" -eq 1 ]
}

@test "pre-commit refuses a commit whose committer holds a denylist term" {
    make_repo
    write_denylist
    git -C "$REPO" switch -q -c feat/example
    stage notes.txt 'synthetic notes'
    run env GIT_COMMITTER_EMAIL="$DENY_TERM@example.invalid" \
        git -C "$REPO" commit -q -m "docs: add notes"
    [ "$status" -ne 0 ]
    [[ "$output" == *"the author or committer name or e-mail holds a term"* ]]
    refute_term_shown
    [ "$(commit_count)" -eq 1 ]
}

@test "commit-msg refuses a commit message that holds a denylist term" {
    make_repo
    write_denylist
    git -C "$REPO" switch -q -c feat/example
    stage notes.txt 'synthetic notes'
    try_commit "docs: add notes from ${DENY_TERM^^}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"commit-msg: the commit message, or a comment line git adds to it"* ]]
    refute_term_shown
    [ "$(commit_count)" -eq 1 ]
}

@test "a missing denylist allows the commit, with a note" {
    make_repo
    git -C "$REPO" switch -q -c feat/example
    stage notes.txt "synthetic notes that mention $DENY_TERM"
    try_commit "docs: add notes"
    [ "$status" -eq 0 ]
    [[ "$output" == *"pre-commit: no denylist at "* ]]
    [ "$(commit_count)" -eq 2 ]
}

@test "a denylist of comments and blank lines allows the commit" {
    make_repo
    write_denylist "# $DENY_TERM" '' '    '
    git -C "$REPO" switch -q -c feat/example
    stage notes.txt "# $DENY_TERM"
    try_commit "docs: add notes"
    [ "$status" -eq 0 ]
    [[ "$output" == *"holds no term, so the denylist check is skipped"* ]]
    [ "$(commit_count)" -eq 2 ]
}

@test "a denylist with a byte order mark and CRLF line ends still matches its first term" {
    make_repo
    write_denylist $'\357\273\277'"$DENY_TERM"$'\r' $'# Synthetic denylist for the hook tests.\r'
    git -C "$REPO" switch -q -c feat/example
    stage notes.txt "contact $DENY_TERM"
    try_commit "docs: add notes"
    [ "$status" -ne 0 ]
    [[ "$output" == *"notes.txt"* ]]
    refute_term_shown
    [ "$(commit_count)" -eq 1 ]
}

@test "a denylist saved as UTF-16 refuses the commit instead of matching nothing" {
    make_repo
    mkdir -p "${DENYLIST%/*}"
    utf16le "$DENY_TERM" > "$DENYLIST"
    git -C "$REPO" switch -q -c feat/example
    stage notes.txt 'synthetic notes'
    try_commit "docs: add notes"
    [ "$status" -ne 0 ]
    [[ "$output" == *"holds NUL bytes and is not UTF-8 text"* ]]
    [ "$(commit_count)" -eq 1 ]
}

@test "TERMINAL_LOGGER_DENYLIST points the hooks at another denylist" {
    make_repo
    export TERMINAL_LOGGER_DENYLIST="$BATS_TEST_TMPDIR/other config/denylist"
    mkdir -p "${TERMINAL_LOGGER_DENYLIST%/*}"
    printf '%s\n' "$DENY_TERM" > "$TERMINAL_LOGGER_DENYLIST"
    git -C "$REPO" switch -q -c feat/example
    stage notes.txt "contact $DENY_TERM"
    try_commit "docs: add notes"
    [ "$status" -ne 0 ]
    [[ "$output" == *"notes.txt"* ]]
    refute_term_shown
    [ "$(commit_count)" -eq 1 ]
}

@test "a refusal shows a denylist path under HOME with ~, since HOME may hold a term" {
    export HOME="$BATS_TEST_TMPDIR/$DENY_TERM"
    unset XDG_CONFIG_HOME
    # A directory where the denylist belongs cannot be read as one.
    mkdir -p "$HOME/.config/terminal-logger-dev/denylist"
    make_repo
    git -C "$REPO" switch -q -c feat/example
    stage notes.txt 'synthetic notes'
    try_commit "docs: add notes"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot read the denylist at ~/.config/terminal-logger-dev/denylist"* ]]
    refute_term_shown
    [ "$(commit_count)" -eq 1 ]
}

@test "the hooks run through the relative core.hooksPath the docs give, from a subdirectory" {
    make_repo
    write_denylist
    cp -R "$REPO_ROOT/.githooks" "$REPO/.githooks"
    git -C "$REPO" config core.hooksPath .githooks
    git -C "$REPO" switch -q -c feat/example
    stage docs/leak.md "contact $DENY_TERM"
    run git -C "$REPO/docs" commit -q -m "docs: add notes"
    [ "$status" -ne 0 ]
    [[ "$output" == *"docs/leak.md"* ]]
    refute_term_shown
    [ "$(commit_count)" -eq 1 ]
}

@test "a refusal names the offending files but never the term" {
    make_repo
    write_denylist
    git -C "$REPO" switch -q -c feat/example
    stage docs/leak.md "contact $DENY_TERM"
    stage docs/clean.md 'synthetic notes'
    stage "$DENY_TERM/notes.md" 'synthetic notes'
    try_commit "docs: add notes"
    [ "$status" -ne 0 ]
    [[ "$output" == *"docs/leak.md"* ]]
    [[ "$output" != *"docs/clean.md"* ]]
    [[ "$output" == *"1 staged path name"* ]]
    refute_term_shown
    [ "$(commit_count)" -eq 1 ]
    assert_tmpdir_empty
}

@test "pre-push refuses a push to main" {
    run_pre_push refs/heads/main
    [ "$status" -eq 1 ]
    [[ "$output" == *"pushing to 'main' is refused"* ]]
}

@test "pre-push refuses a push to master" {
    run_pre_push refs/heads/master
    [ "$status" -eq 1 ]
    [[ "$output" == *"pushing to 'master' is refused"* ]]
}

@test "pre-push allows a push to a feature branch" {
    run_pre_push refs/heads/feat/example
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
