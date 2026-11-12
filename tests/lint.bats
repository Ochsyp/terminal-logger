#!/usr/bin/env bats
# Lint checks: no CR byte in any file git tracks or would add, sh -n, bash -n and zsh -n syntax
# checks, no ShellCheck finding in the shell files, rcblock.awk under each awk, and the file modes
# git stores: executable for hooks, scripts and .bats files, not for the files that are sourced.

load helpers

# Run before each test by bats.
# Gives the test its own home, so no global git setting changes what git lists.
setup() {
    isolate_home
}

# Run ShellCheck in the repository root on the hooks, denylist.sh, bin/tlogger, the stubs,
# helpers.bash and the .bats files. The paths stay relative, because some ShellCheck builds
# cannot read the absolute paths a POSIX layer passes them.
shellcheck_repo() {
    (cd "$REPO_ROOT" && shellcheck .githooks/* bin/tlogger tests/stub-bin/zsh \
        tests/stub-bin/tlogger-test-recorder tests/stub-bin/tlogger-test-ip tests/*.bash \
        tests/*.bats)
}

@test "no file that git tracks or would add holds a CR byte" {
    local path
    local -a files=() required=(bin/tlogger lib/config.zsh lib/tlogger.zsh libexec/rcblock.awk
        VERSION tests/stub-bin/zsh tests/stub-bin/tlogger-test-recorder
        tests/stub-bin/tlogger-test-ip tests/golden/rc-block.zsh
        tests/fixtures/skel-zshrc tests/fixtures/e2e-zshrc tests/fixtures/e2e-auto-zshrc
        tests/helpers/pty.zsh tests/helpers/fakeproc.zsh)
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

@test "bin/tlogger, the stubs and tests/helpers.bash pass a bash -n syntax check" {
    bash -n "$REPO_ROOT/bin/tlogger"
    bash -n "$REPO_ROOT/tests/stub-bin/zsh"
    bash -n "$REPO_ROOT/tests/stub-bin/tlogger-test-recorder"
    bash -n "$REPO_ROOT/tests/stub-bin/tlogger-test-ip"
    bash -n "$REPO_ROOT/tests/helpers.bash"
}

@test "lib/tlogger.zsh, lib/config.zsh and the zsh test helpers pass a zsh -n syntax check" {
    need zsh
    local file
    for file in "$REPO_ROOT/lib/tlogger.zsh" "$REPO_ROOT/lib/config.zsh" \
        "$REPO_ROOT/tests/helpers/pty.zsh" "$REPO_ROOT/tests/helpers/fakeproc.zsh"; do
        zsh -n "$file"
    done
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

@test "git stores the hooks, the scripts and the .bats files as executable, and the sourced files not" {
    local mode path listing file want
    local -i hooks=0 indexed_hooks=0
    # The scripts must be in the index at all; git add --chmod=+x stages one executable. A stub
    # that is missing or not executable would fail only the tests that run it, and not by name.
    for path in bin/tlogger tests/stub-bin/zsh tests/stub-bin/tlogger-test-recorder \
        tests/stub-bin/tlogger-test-ip; do
        if [[ -z $(git -C "$REPO_ROOT" ls-files -- "$path") ]]; then
            printf '%s is not in the index; stage it with git add --chmod=+x\n' "$path" >&2
            return 1
        fi
    done
    # git runs a hook only when it is executable. denylist.sh, the plugin files, rcblock.awk and
    # the test helpers are sourced or read, never run, so none of them is executable.
    listing=$(git -C "$REPO_ROOT" ls-files -s -- .githooks bin lib libexec tests)
    while read -r mode _ _ path; do
        case $path in
            .githooks/denylist.sh | lib/* | libexec/* | tests/*.bash | tests/helpers/*) want=100644 ;;
            .githooks/* | bin/* | tests/stub-bin/* | tests/*.bats) want=100755 ;;
            *) continue ;;
        esac
        if [[ $mode != "$want" ]]; then
            printf '%s is stored with mode %s, not %s\n' "$path" "$mode" "$want" >&2
            return 1
        fi
        if [[ $path == .githooks/* && $path != .githooks/denylist.sh ]]; then
            indexed_hooks+=1
        fi
    done <<< "$listing"
    for file in "$REPO_ROOT"/.githooks/*; do
        [[ "$file" == */denylist.sh ]] || hooks+=1
    done
    # Every hook in the work tree must be in the index, so an empty or failed listing fails here.
    (( hooks > 0 && indexed_hooks == hooks ))
}
