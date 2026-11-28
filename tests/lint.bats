#!/usr/bin/env bats
# Lint checks of this repository's own files: no CR byte in any file git tracks or would add,
# bash -n and zsh -n syntax checks, no ShellCheck finding in the shell files, rcblock.awk and
# legacyblock.awk under each awk, tlogger_view.py compiled, its imports and the way bin/tlogger
# runs it, and the file modes git stores: executable for scripts and .bats files, not for the files
# that are sourced or read. The standard's own lint.bats checks the hooks, its tools and ci/.
# Also that no file in bin, lib or libexec removes anything recursively: outside a line that is a
# comment, no rm with an option holding r or R, no --recursive, no find ... -delete and no rmtree
# (shutil.rmtree). prune removes each file by name with unlink and each folder with rmdir.

load helpers

# The forms of a recursive removal, as extended regular expressions for grep -E: rm, as a word,
# with an option that holds r or R after any other options, and the -delete of find.
RM_RECURSIVE='(^|[^[:alnum:]_.-])rm([[:space:]]+-[^[:space:]]*)*[[:space:]]+-[[:alpha:]]*[rR]'
FIND_DELETE='[[:space:]]-delete([^[:alnum:]_-]|$)'

# Python code for python3 -I -c CODE FILE: print each import in FILE of a module that is neither
# in the standard library nor pyte, and each relative import, one line each.
FOREIGN_IMPORTS='import ast, sys
allowed = set(sys.stdlib_module_names) | {"pyte"}
with open(sys.argv[1], encoding="utf-8") as source:
    tree = ast.parse(source.read())
for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        names = [alias.name for alias in node.names]
    elif isinstance(node, ast.ImportFrom):
        names = [node.module or "."] if node.level == 0 else ["." * node.level]
    else:
        continue
    for name in names:
        if name.split(".")[0] not in allowed:
            print("line %d imports %s" % (node.lineno, name))'

# A Python script that prints each function, class or upper-case constant that the top level of
# the file in argv[1] defines more than once, with the lines of each definition.
TWICE_DEFINED='import ast, sys
with open(sys.argv[1], encoding="utf-8") as source:
    tree = ast.parse(source.read())
seen = {}
for node in tree.body:
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
        names = [node.name]
    elif isinstance(node, ast.Assign):
        names = [t.id for t in node.targets if isinstance(t, ast.Name) and t.id.isupper()]
    else:
        continue
    for name in names:
        seen.setdefault(name, []).append(node.lineno)
for name, lines in sorted(seen.items()):
    if len(lines) > 1:
        print("%s is defined on lines %s" % (name, ", ".join(map(str, lines))))'

# Run before each test by bats.
# Gives the test its own home, so no global git setting changes what git lists.
setup() {
    isolate_home
}

# Run ShellCheck in the repository root on bin/tlogger, the stubs, helpers.bash and the .bats
# files. The paths stay relative, because some ShellCheck builds cannot read the absolute paths a
# POSIX layer passes them.
shellcheck_repo() {
    (cd "$REPO_ROOT" && shellcheck bin/tlogger tests/stub-bin/zsh \
        tests/stub-bin/tlogger-test-recorder tests/stub-bin/tlogger-test-ip tests/*.bash \
        tests/*.bats)
}

# Print each line of the files FILE..., paths relative to the folder DIR, that removes
# recursively, as 'FILE:LINE:TEXT', skipping the lines that are comments: rm with an r or R
# option, --recursive, find's -delete or rmtree. Fails when grep cannot read a file.
recursive_removals() {
    local dir=$1 found rc=0
    shift
    found=$(cd "$dir" && grep -nHE -e "$RM_RECURSIVE" -e '--recursive' -e "$FIND_DELETE" \
        -e rmtree -- "$@") || rc=$?
    if (( rc > 1 )); then
        printf 'grep cannot read the files in %s: %s\n' "$dir" "$*" >&2
        return 1
    fi
    if [[ -n $found ]]; then
        grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' <<< "$found" || true
    fi
}

@test "no file that git tracks or would add holds a CR byte" {
    local path
    local -a files=() required=(bin/tlogger lib/config.zsh lib/tlogger.zsh libexec/legacyblock.awk
        libexec/rcblock.awk libexec/tlogger_view.py VERSION tests/stub-bin/zsh
        tests/stub-bin/tlogger-test-recorder
        tests/stub-bin/tlogger-test-ip tests/golden/rc-block.zsh
        tests/fixtures/skel-zshrc tests/fixtures/e2e-zshrc tests/fixtures/e2e-auto-zshrc
        tests/helpers/pty.zsh tests/helpers/fakeproc.zsh tests/helpers/view-tty.zsh)
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
        "$REPO_ROOT/tests/helpers/pty.zsh" "$REPO_ROOT/tests/helpers/fakeproc.zsh" \
        "$REPO_ROOT/tests/helpers/view-tty.zsh"; do
        zsh -n "$file"
    done
}

@test "docs/guide.md names only commands and options that tlogger help lists" {
    local help code word
    local -a words
    help=$(bash "$TLOGGER" help)
    [[ -f "$REPO_ROOT/docs/guide.md" ]]
    # The guide's code, fenced blocks and inline spans, on the lines that run tlogger; other
    # tools' options, such as gh's, are not tlogger's.
    code=$(awk '/^```/ { fence = !fence; next }
        fence { print; next }
        { while (match($0, /`[^`]+`/)) {
            print substr($0, RSTART + 1, RLENGTH - 2); $0 = substr($0, RSTART + RLENGTH) } }' \
        "$REPO_ROOT/docs/guide.md" | grep -E '(^|[^a-z-])tlogger( |$)') || code=
    mapfile -t words < <(grep -oE 'tlogger [a-z]+|--[a-z][a-z-]*' <<< "$code" |
        sed 's/^tlogger //' | sort -u)
    (( ${#words[@]} > 0 ))
    for word in "${words[@]}"; do
        if [[ ! $help =~ (^|[^a-z-])"$word"($|[^a-z-]) ]]; then
            printf 'docs/guide.md names %s, which tlogger help does not list\n' "$word" >&2
            return 1
        fi
    done
}

@test "the README and docs/guide.md install a release without a gh login" {
    local file block url=https://github.com/Ochsyp/terminal-logger/releases/download/vX.Y.Z
    for file in README.md docs/guide.md; do
        # The first fenced block that unpacks a release, up to its tar line: the download and the
        # checks that come before anything is unpacked.
        block=$(awk '/^```/ { fence = !fence; buf = ""; next }
            fence { buf = buf $0 "\n" }
            fence && /^tar -xzf terminal-logger-/ { printf "%s", buf; exit }' "$REPO_ROOT/$file")
        if [[ -z $block ]]; then
            printf '%s has no block that unpacks a release\n' "$file" >&2
            return 1
        fi
        if [[ $block != *"curl -fLO $url/terminal-logger-X.Y.Z.tar.gz"* ||
            $block != *"curl -fLO $url/SHA256SUMS"* ||
            $block != *'sha256sum -c SHA256SUMS'* ]]; then
            printf '%s does not download both assets with curl and check SHA256SUMS\n' "$file" >&2
            return 1
        fi
        if grep -qE '^gh ' <<< "$block"; then
            printf '%s needs gh, and so a login, before the release is unpacked\n' "$file" >&2
            return 1
        fi
    done
}

@test "every e2e file runs its drivers through drive in tests/helpers.bash and defines none" {
    local file
    local -a files=("$REPO_ROOT"/tests/e2e-*.bats)
    (( ${#files[@]} >= 5 ))
    grep -q '^drive() {$' "$REPO_ROOT/tests/helpers.bash"
    for file in "${files[@]}"; do
        if grep -qE '^[[:space:]]*(function[[:space:]]+)?drive[[:space:]]*(\(\)|\{)' "$file"; then
            printf '%s defines its own drive\n' "${file##*/}" >&2
            return 1
        fi
        # A launcher copied under another name still starts zsh this way.
        if grep -qF "zsh -f -c 'source" "$file"; then
            printf '%s starts a driver without drive\n' "${file##*/}" >&2
            return 1
        fi
        grep -qF "drive << 'EOF'" "$file"
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

@test "legacyblock.awk prints none for empty input under each awk on PATH" {
    local awk
    local -i checked=0
    for awk in mawk gawk awk; do
        if ! command -v "$awk" > /dev/null 2>&1; then
            continue
        fi
        run env LEGACY_START='# start' LEGACY_END='# end' \
            "$awk" -f "$REPO_ROOT/libexec/legacyblock.awk" < /dev/null
        if [[ $status -ne 0 || $output != none ]]; then
            printf '%s printed (exit %s):\n%s\n' "$awk" "$status" "$output" >&2
            return 1
        fi
        checked+=1
    done
    (( checked > 0 ))
}

@test "libexec/tlogger_view.py compiles and imports nothing but the standard library and pyte" {
    need python3
    # cfile puts the bytecode in the test's folder, not beside the file.
    "$PYTHON3" -I -c 'import py_compile, sys; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)' \
        "$VIEW" "$BATS_TEST_TMPDIR/tlogger_view.pyc"
    run "$PYTHON3" -I -c "$FOREIGN_IMPORTS" "$VIEW"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "libexec/tlogger_view.py defines each top-level function, class and constant once" {
    need python3
    # A second def of a name replaces the first for every caller, as a second _create_part once
    # broke render; the script prints each name defined twice.
    run "$PYTHON3" -I -c "$TWICE_DEFINED" "$VIEW"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "bin/tlogger runs libexec/tlogger_view.py only as \"\$PYTHON\" -I, isolated from the environment" {
    local line
    local -i runs=0
    while IFS= read -r line; do
        # Comments, the list of release files and the path that require_python checks run nothing.
        # shellcheck disable=SC2016 # The text of bin/tlogger, not an expansion.
        if [[ $line =~ ^[[:space:]]*# || $line == *'libexec/tlogger_view.py VERSION)' ||
            $line =~ ^[[:space:]]*'local view=$SRC_ROOT/libexec/tlogger_view.py'$ ]]; then
            continue
        fi
        # shellcheck disable=SC2016 # The text of bin/tlogger, not an expansion.
        if [[ $line != *'"$PYTHON" -I "$SRC_ROOT/libexec/tlogger_view.py" '* ]]; then
            printf 'bin/tlogger runs tlogger_view.py in another way:\n%s\n' "$line" >&2
            return 1
        fi
        runs+=1
    done < <(grep -F tlogger_view.py "$REPO_ROOT/bin/tlogger")
    (( runs >= 4 ))
}

@test "bin, lib and libexec remove nothing recursively, outside comments" {
    local sample="$BATS_TEST_TMPDIR/sample" path
    local -a files=()
    # The check finds each form, and passes comments and the removals of one name.
    cat > "$sample" << 'EOF'
rm -r "$dir"
    rm -R -- "$dir"
rm -rf -- "$dir"
  command rm -f -fR x
rm --recursive x
cp --recursive a b
find "$dir" -type f -delete
    shutil.rmtree(path)
# without rm -r
    # shutil.rmtree is never used, nor find -delete
rm -f -- "$file"
command rm -f "$tmp" "$tmp.part"
unlink -- "$file"
rmdir -- "$dir"
confirm -R
os.rmdir(path)
EOF
    run recursive_removals "$BATS_TEST_TMPDIR" sample
    [ "$status" -eq 0 ]
    [ "$(cut -d : -f 2 <<< "$output" | paste -s -d ' ' -)" = '1 2 3 4 5 6 7 8' ]
    # Every file in bin, lib and libexec.
    for path in "$REPO_ROOT"/bin/* "$REPO_ROOT"/lib/* "$REPO_ROOT"/libexec/*; do
        if [[ -f $path ]]; then
            files+=("${path#"$REPO_ROOT"/}")
        fi
    done
    [[ " ${files[*]} " == *' bin/tlogger '* && " ${files[*]} " == *' lib/tlogger.zsh '* &&
        " ${files[*]} " == *' libexec/tlogger_view.py '* ]]
    run recursive_removals "$REPO_ROOT" "${files[@]}"
    if [[ $status -ne 0 || -n $output ]]; then
        printf 'a recursive removal outside a comment:\n%s\n' "$output" >&2
        return 1
    fi
}

@test "ShellCheck reports no finding in the scripts, helpers.bash or the .bats files" {
    command -v shellcheck > /dev/null || skip "shellcheck is not on PATH"
    run shellcheck_repo
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "git stores the scripts and the .bats files as executable, and the sourced files not" {
    local mode path listing want
    local -i scripts=0
    # The scripts must be in the index at all; git add --chmod=+x stages one executable. A stub
    # that is missing or not executable would fail only the tests that run it, and not by name.
    for path in bin/tlogger tests/stub-bin/zsh tests/stub-bin/tlogger-test-recorder \
        tests/stub-bin/tlogger-test-ip; do
        if [[ -z $(git -C "$REPO_ROOT" ls-files -- "$path") ]]; then
            printf '%s is not in the index; stage it with git add --chmod=+x\n' "$path" >&2
            return 1
        fi
    done
    # The plugin files, the two awk scanners, tlogger_view.py, which python3 -I reads, and the test
    # helpers are sourced or read, never run themselves, so none of them is executable.
    listing=$(git -C "$REPO_ROOT" ls-files -s -- bin lib libexec tests)
    while read -r mode _ _ path; do
        case $path in
            lib/* | libexec/* | tests/*.bash | tests/helpers/*) want=100644 ;;
            bin/* | tests/stub-bin/* | tests/*.bats) want=100755 ;;
            *) continue ;;
        esac
        if [[ $mode != "$want" ]]; then
            printf '%s is stored with mode %s, not %s\n' "$path" "$mode" "$want" >&2
            return 1
        fi
        if [[ $path == bin/* ]]; then
            scripts+=1
        fi
    done <<< "$listing"
    # An empty or failed listing fails here.
    (( scripts > 0 ))
}
