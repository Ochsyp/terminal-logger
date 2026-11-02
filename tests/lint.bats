#!/usr/bin/env bats
# Lint checks: no CR byte in any file git tracks or would add, sh -n and bash -n syntax checks,
# no ShellCheck finding in the hooks, denylist.sh, helpers.bash or the .bats files, and hooks
# that git stores as executable files.

load helpers

# Run before each test by bats.
# Gives the test its own home, so no global git setting changes what git lists.
setup() {
    isolate_home
}

# Run ShellCheck in the repository root on the hooks, denylist.sh, helpers.bash and the .bats
# files. The paths stay relative, because some ShellCheck builds cannot read the absolute paths
# a POSIX layer passes them.
shellcheck_repo() {
    (cd "$REPO_ROOT" && shellcheck .githooks/* tests/*.bash tests/*.bats)
}

@test "no file that git tracks or would add holds a CR byte" {
    local path
    local -a files=()
    while IFS= read -r -d '' path; do
        if [[ -f "$REPO_ROOT/$path" ]]; then
            files+=("$REPO_ROOT/$path")
        fi
    done < <(git -C "$REPO_ROOT" ls-files -z
        git -C "$REPO_ROOT" ls-files -z --others --exclude-standard)
    (( ${#files[@]} > 0 ))
    # -U keeps a grep that reads files in text mode from dropping each CR before it matches;
    # elsewhere it is a no-op.
    run grep -U -l $'\r' -- "${files[@]}"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "the hooks and denylist.sh pass an sh -n syntax check" {
    local file
    for file in "$REPO_ROOT"/.githooks/*; do
        sh -n "$file"
    done
}

@test "tests/helpers.bash passes a bash -n syntax check" {
    bash -n "$REPO_ROOT/tests/helpers.bash"
}

@test "ShellCheck reports no finding in the hooks, denylist.sh, helpers.bash or the .bats files" {
    command -v shellcheck > /dev/null || skip "shellcheck is not on PATH"
    run shellcheck_repo
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "git stores every hook in .githooks as an executable file" {
    local mode path listing file
    local -i checked=0 expected=0
    # git runs a hook only when it is executable; denylist.sh is sourced, never run.
    listing=$(git -C "$REPO_ROOT" ls-files -s -- .githooks)
    while read -r mode _ _ path; do
        [[ "$path" == .githooks/denylist.sh ]] && continue
        if [[ "$mode" != 100755 ]]; then
            printf '%s is stored with mode %s, not 100755\n' "$path" "$mode" >&2
            return 1
        fi
        checked+=1
    done <<< "$listing"
    for file in "$REPO_ROOT"/.githooks/*; do
        [[ "$file" == */denylist.sh ]] || expected+=1
    done
    # Every hook in the work tree must be in the index, so an empty or failed listing fails here.
    (( expected > 0 && checked == expected ))
}
