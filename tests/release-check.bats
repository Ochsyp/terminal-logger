#!/usr/bin/env bats
# Tests of ci/release-check, which the standard's release-build runs on every archive it builds,
# dry runs included, and of an install from an unpacked release. The archive is built here as
# release-build builds it: git archive of HEAD under terminal-logger-VERSION/, under TZ=UTC, with
# the release manifest added through --add-file.

bats_require_minimum_version 1.5.0

load helpers

# Run before each test by bats.
# Gives the test its own HOME and a folder for the archive, the manifest and the unpacked trees.
setup() {
    isolate_home
    isolate_tlogger
    IFS= read -r VERSION_TEXT < "$REPO_ROOT/VERSION"
    CHECK="$REPO_ROOT/ci/release-check"
    BUILD="$BATS_TEST_TMPDIR/build"
    mkdir -p "$BUILD"
}

# Write the release manifest that names VERSION to FILE, in the form release-build writes it.
write_manifest() {
    printf '{\n  "schema": 1,\n  "name": "terminal-logger",\n  "version": "%s",\n  "tag": "v%s",\n  "commit": "%s"\n}\n' \
        "$1" "$1" "$(git -C "$REPO_ROOT" rev-parse HEAD)" > "$2"
}

# Set ARCHIVE to the archive of HEAD for VERSION, with a manifest that names NAMED (default
# VERSION), built as release-build builds it.
build_archive() {
    local version=$1
    write_manifest "${2:-$1}" "$BUILD/terminal-logger-release.json"
    ARCHIVE="$BUILD/terminal-logger-$version.tar.gz"
    TZ=UTC git -C "$REPO_ROOT" archive --format=tar.gz --prefix="terminal-logger-$version/" \
        --add-file="$BUILD/terminal-logger-release.json" HEAD > "$ARCHIVE"
}

# Unpack ARCHIVE into a new folder DIR (default $BUILD/tree) and set TREE to its one top folder.
unpack() {
    local dir=${1:-$BUILD/tree}
    mkdir -p "$dir"
    tar --force-local -xzf "$ARCHIVE" -C "$dir"
    TREE=$(find "$dir" -mindepth 1 -maxdepth 1 -type d)
}

# Pack TREE, as changed, back into ARCHIVE.
repack() {
    tar --force-local -czf "$ARCHIVE" -C "${TREE%/*}" "${TREE##*/}"
}

# Run ci/release-check on ARCHIVE for VERSION (default VERSION_TEXT).
run_check() {
    run --separate-stderr bash "$CHECK" --archive "$ARCHIVE" --version "${1:-$VERSION_TEXT}"
}

@test "release-check passes the archive of HEAD" {
    build_archive "$VERSION_TEXT"
    run_check
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "release-check refuses an archive that lacks a file install needs, and names it" {
    build_archive "$VERSION_TEXT"
    unpack
    rm "$TREE/lib/tlogger.zsh"
    repack
    run_check
    [ "$status" -eq 1 ]
    [[ $stderr == *lib/tlogger.zsh* ]]
}

@test "release-check refuses an archive whose bin/tlogger is not executable" {
    need modes
    build_archive "$VERSION_TEXT"
    unpack
    chmod 644 "$TREE/bin/tlogger"
    repack
    run_check
    [ "$status" -eq 1 ]
    [[ $stderr == *bin/tlogger* ]]
}

@test "release-check refuses an archive that holds a development file or an unknown entry" {
    local extra
    build_archive "$VERSION_TEXT"
    for extra in tests/x.bats .github/x ci/x CONTRIBUTING.md notes.txt docs/notes.md; do
        rm -rf "$BUILD/tree"
        unpack
        mkdir -p "$TREE/$(dirname "$extra")"
        : > "$TREE/$extra"
        repack
        run_check
        [ "$status" -eq 1 ]
        [[ $stderr == *"${extra%%/*}"* ]]
    done
}

@test "release-check refuses a manifest, a VERSION or a folder that names another version" {
    build_archive "$VERSION_TEXT" 0.0.9
    run_check
    [ "$status" -eq 1 ]
    [[ $stderr == *manifest* ]]
    build_archive "$VERSION_TEXT"
    run_check 9.9.9
    [ "$status" -eq 1 ]
    [[ $stderr == *9.9.9* ]]
    unpack
    printf '9.9.9\n' > "$TREE/VERSION"
    repack
    run_check
    [ "$status" -eq 1 ]
    [[ $stderr == *"VERSION holds 9.9.9"* ]]
}

@test "release-check takes --archive FILE and --version X.Y.Z only" {
    run --separate-stderr bash "$CHECK"
    [ "$status" -eq 64 ]
    run --separate-stderr bash "$CHECK" --archive "$BUILD/none.tar.gz" --version "$VERSION_TEXT" --x
    [ "$status" -eq 64 ]
    run --separate-stderr bash "$CHECK" --archive "$BUILD/none.tar.gz" --version "$VERSION_TEXT"
    [ "$status" -eq 1 ]
}

@test "an unpacked release installs without git and names its version" {
    need symlinks
    build_archive "$VERSION_TEXT"
    unpack
    [ ! -e "$TREE/.git" ]
    run --separate-stderr bash "$TREE/bin/tlogger" install --mode manual --yes < /dev/null
    [ "$status" -eq 0 ]
    run --separate-stderr bash "$HOME/.local/share/tlogger/current/bin/tlogger" version
    [ "$status" -eq 0 ]
    [ "$output" = "tlogger $VERSION_TEXT" ]
    [ ! -e "$HOME/.local/share/tlogger/current/terminal-logger-release.json" ]
}

@test "install refuses an unpacked release whose manifest names another version" {
    build_archive "$VERSION_TEXT" 0.0.9
    unpack
    run --separate-stderr bash "$TREE/bin/tlogger" install --mode manual --yes < /dev/null
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ $stderr == "tlogger: the release manifest "*"names version 0.0.9, but VERSION is $VERSION_TEXT; unpack the release again" ]]
    refute_tlogger_folders
}

@test "a release 0.1.0 installs over 0.1.0-dev, and 0.1.0-dev does not install over 0.1.0" {
    need symlinks
    local dev release
    build_archive "$VERSION_TEXT"
    unpack "$BUILD/dev"
    dev=$TREE
    printf '0.1.0-dev\n' > "$dev/VERSION"
    write_manifest 0.1.0-dev "$dev/terminal-logger-release.json"
    unpack "$BUILD/release"
    release=$TREE
    printf '0.1.0\n' > "$release/VERSION"
    write_manifest 0.1.0 "$release/terminal-logger-release.json"
    run --separate-stderr bash "$dev/bin/tlogger" install --mode manual --yes < /dev/null
    [ "$status" -eq 0 ]
    run --separate-stderr bash "$release/bin/tlogger" install --yes < /dev/null
    [ "$status" -eq 0 ]
    [ "$(readlink "$HOME/.local/share/tlogger/current")" = releases/0.1.0 ]
    run --separate-stderr bash "$dev/bin/tlogger" install --yes < /dev/null
    [ "$status" -eq 1 ]
    [[ $stderr == *"newer than this tlogger (0.1.0-dev)"* ]]
    [ "$(readlink "$HOME/.local/share/tlogger/current")" = releases/0.1.0 ]
}
