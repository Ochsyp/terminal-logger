#!/usr/bin/env bats
# Lint checks: no CR byte in any file git tracks or would add, sh -n, bash -n and zsh -n syntax
# checks, no ShellCheck finding in the shell files, rcblock.awk under each awk, and hooks and
# scripts that git stores as executable files.

load helpers

# Run before each test by bats.
# Gives the test its own home, so no global git setting changes what git lists.
setup() {
    isolate_home
}

# Run ShellCheck in the repository root on the hooks, denylist.sh, bin/tlogger, the zsh stub,
# helpers.bash and the .bats files. The paths stay relative, because some ShellCheck builds
# cannot read the absolute paths a POSIX layer passes them.
shellcheck_repo() {
    (cd "$REPO_ROOT" && shellcheck .githooks/* bin/tlogger tests/stub-bin/zsh tests/*.bash tests/*.bats)
}

@test "no file that git tracks or would add holds a CR byte" {
    local path
    local -a files=() required=(bin/tlogger lib/tlogger.zsh libexec/rcblock.awk VERSION
        tests/stub-bin/zsh tests/golden/rc-block.zsh tests/fixtures/skel-zshrc)
    while IFS= read -r -d '' path; do
        if [[ -f "$REPO_ROOT/$path" ]]; then
            files+=("$REPO_ROOT/$path")
        fi
    done < <(git -C "$REPO_ROOT" ls-files -z
        git -C "$REPO_ROOT" ls-files -z --others --exclude-standard)
    (( ${#files[@]} > 0 ))
    # The installed files and the byte-exact test files must be in the list, so that an ignore
    # rule cannot take them out of the check unnoticed.
    for path in "${required[@]}"; do
        if [[ " ${files[*]} " != *" $REPO_ROOT/$path "* ]]; then
            printf '%s is not among the files git tracks or would add\n' "$path" >&2
            return 1
        fi
    done
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

@test "bin/tlogger, the zsh stub and tests/helpers.bash pass a bash -n syntax check" {
    bash -n "$REPO_ROOT/bin/tlogger"
    bash -n "$REPO_ROOT/tests/stub-bin/zsh"
    bash -n "$REPO_ROOT/tests/helpers.bash"
}

@test "lib/tlogger.zsh passes a zsh -n syntax check" {
    need zsh
    zsh -n "$REPO_ROOT/lib/tlogger.zsh"
}

@test "rcblock.awk prints none for empty input under each awk on PATH" {
    local awk
    local -i checked=0
    for awk in mawk gawk awk; do
        if ! command -v "$awk" > /dev/null 2>&1; then
            continue
        fi
        run "$awk" -f "$REPO_ROOT/libexec/rcblock.awk" < /dev/null
        if [[ $status -ne 0 || $output != none ]]; then
            printf '%s printed (exit %s):\n%s\n' "$awk" "$status" "$output" >&2
            return 1
        fi
        checked+=1
    done
    (( checked > 0 ))
}

@test "ShellCheck reports no finding in the hooks, the scripts, helpers.bash or the .bats files" {
    command -v shellcheck > /dev/null || skip "shellcheck is not on PATH"
    run shellcheck_repo
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "git stores every hook in .githooks, bin/tlogger and the zsh stub as executable files" {
    local mode path listing file
    local -i checked=0 expected=0
    # The two scripts must be in the index at all; git add --chmod=+x stages one executable.
    for path in bin/tlogger tests/stub-bin/zsh; do
        if [[ -z $(git -C "$REPO_ROOT" ls-files -- "$path") ]]; then
            printf '%s is not in the index; stage it with git add --chmod=+x\n' "$path" >&2
            return 1
        fi
        expected+=1
    done
    # git runs a hook only when it is executable; denylist.sh is sourced, never run.
    listing=$(git -C "$REPO_ROOT" ls-files -s -- .githooks bin/tlogger tests/stub-bin/zsh)
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
    (( expected > 2 && checked == expected ))
}
