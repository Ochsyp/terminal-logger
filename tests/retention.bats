#!/usr/bin/env bats
# Tests for tlogger archive, tlogger archive --verify and tlogger prune in bin/tlogger, run as a
# subprocess in the test's own HOME on synthetic sessions. A fake /proc, which TLOGGER_PROC names,
# holds the boot id and the processes that the liveness check reads, so that a session counts as
# still recorded only when a test says so, and the mountinfo that the logdir_mount guard reads.
# tests/helpers/tartool.py lists the members of the archives that tlogger writes, and builds
# archives that tlogger did not write, well formed or tampered, for archive --verify. For prune,
# stand-ins first on PATH log every rm and unlink that bin/tlogger runs, rm fails, and unlink
# fails for one named file as on an immutable one; one test answers prune's question in a
# pseudo-terminal that zsh's zpty module drives (tests/helpers/pty.zsh).
#
# The contract these tests pin. Every message starts with 'tlogger: ' and shows a path under HOME
# with ~; <log folder> is the config's logdir, else ~/.local/state/tlogger/sessions.
#
# tlogger archive ENGAGEMENT|--none [--older-than DAYS]
# - It takes one folder: the engagement folder ENGAGEMENT of the log folder, or with --none the
#   log folder itself, for the sessions directly in it. It has no default folder and never uses
#   the config's engagement. It takes the session folders that collect_sessions counts in that
#   folder; with --older-than DAYS, or --older-than=DAYS, DAYS a whole number of 0 or more, only
#   those whose id names a UTC start more than DAYS x 24 hours ago. File times never count.
# - It writes <log folder>/.archive/<name>-<UTC time as YYYYMMDDTHHMMSSZ>.tar.gz and beside it
#   <that file>.sha256, both 0400, and nothing else; <name> is ENGAGEMENT, or with --none the last
#   part of the log folder's path. It creates a missing .archive with mode 0700. It changes,
#   moves and removes nothing, and leaves no .part file.
# - The archive is one gzip stream of a tar whose members are regular files only, with no folder
#   entries and no links: <name>/MANIFEST, the whole MANIFEST of the folder, and for each session
#   <name>/<id>/<file> for each file its SHA256SUMS lists, <name>/<id>/SHA256SUMS and
#   <name>/<id>/SEAL. transcript.txt and every .part file stay out. Each member keeps the mode of
#   its file (0400; the MANIFEST 0600) and its time in whole seconds, with owner and group 0 and
#   no user or group name. Unpacked with umask 077 and tar -xzf, its sessions verify ok.
# - The .sha256 file holds the one line '<SHA-256 of the archive>  <file name of the archive>',
#   so that sha256sum -c works in .archive.
# - Done: exit 0, nothing on stdout, and these three lines alone on stderr, 'session' for one:
#     tlogger: archived <N> sessions of <folder> into <archive>
#     tlogger: SHA-256 of the archive: <sum>; keep it apart from the logs
#     tlogger: the archive lies on the same volume as the logs; copy it to encrypted storage
#     elsewhere
#   (the last is one line).
# - It checks, in this order, and stops at the first that fails, writing nothing:
#   1. the arguments: exit 2, see below;
#   2. the log folder: exit 3 with 'no sessions: the log folder <log folder> does not exist', or
#      exit 1 as every session command refuses it;
#   3. logdir_mount, when the config sets it, exit 1: its volume must be in mountinfo, and the
#      log folder must lie on it:
#        tlogger: the volume <mount> of the log folder is not mounted
#        tlogger: the log folder <log folder> does not lie on the volume <mount> that
#        logdir_mount names
#   4. the folder, exit 1: ENGAGEMENT must be an engagement folder of the log folder, and the log
#      folder, the engagement folder and each session folder it takes must give its group and
#      others no write, sticky bit or not:
#        tlogger: there is no engagement folder <ENGAGEMENT> in <log folder>
#        tlogger: <what> <folder> is writable by its group or by others; chmod go-w <folder>
#        fixes it
#      <what> is 'the log folder', 'the engagement folder' or 'the session folder'. With --none,
#      a log folder whose name holds a space or a control character, which the archive's name
#      and the PRUNED lines cannot hold (one line):
#        tlogger: the name of the log folder <log folder> holds a space or a control character,
#        which an archive's name cannot hold; use an engagement folder
#   5. a session to take, exit 3: tlogger: no session to archive in <folder>
#   6. the verdict of each session it takes, as tlogger verify gives it, exit 1. One line per
#      session that is not ok, by id; verify's own lines 'tlogger: <id>: ...' about a changed
#      one may come with them, and nothing else:
#        tlogger: session <id> is recording; close the terminals recorded into <folder>, or
#        leave it out with --older-than
#        tlogger: session <id> is unsealed; tlogger seal --all seals it
#        tlogger: session <id> is unknown, as it has no recorder file and seal refuses it; leave
#        it out with a narrower --older-than
#        tlogger: session <id> is changed; tlogger verify <id> names what changed, or leave it
#        out with a narrower --older-than
#      A log that is a symlink makes its session changed here, as in verify.
#   7. each file it would archive, the MANIFEST included, exit 1: no symlink, a regular file,
#      this user's, and one hard link only:
#        tlogger: <file> is a symlink, which tlogger does not follow
#        tlogger: <file> is not a regular file
#        tlogger: <file> belongs to another user
#        tlogger: <file> has more than one hard link
#   8. .archive, exit 1, when it exists:
#        tlogger: <log folder>/.archive is a symlink, which tlogger does not follow
#        tlogger: <log folder>/.archive is not a folder
#        tlogger: <log folder>/.archive belongs to another user
#        tlogger: <log folder>/.archive has mode <mode>, not 700; chmod 700 <log folder>/.archive
#        fixes it
#   9. python3, found as render finds it (TLOGGER_PYTHON in the tests), exit 1:
#        tlogger: archive needs python3
#   10. the archive's name, exit 1; a link never replaces a file:
#        tlogger: <archive> exists already; archive never replaces a file
#   Each of these refusals prints nothing on stdout and its message alone on stderr, except 6.
#
# tlogger archive --verify FILE
# - It reads FILE as a stream through python3, unpacks nothing and writes nothing. It prints
#   '<id>  ok' or '<id>  changed' on stdout for each session the archive holds, by id, and
#   nothing else; it exits 0 when every session is ok, else 1. Reasons go to stderr as
#   'tlogger: <id>: ...' or 'tlogger: <file name>: ...', never as a Python traceback.
# - <name> is the first part of the first member's name. A session is an id that a member named
#   <name>/<id>/... names; a member named <name>/<id>, or a name below it, belongs to <id>.
# - A session is changed by the rules of verify: a member of it that is not a regular file (a
#   symlink, a hard link, a device, a folder entry) or that is named twice; SHA256SUMS listing a
#   name outside SEAL_FILES; a listed file that is no member or has another sum; a listed file,
#   SHA256SUMS or SEAL whose mode is not 0400; a member beyond the listed files, SHA256SUMS and
#   SEAL; the SHA-256 of SHA256SUMS other than SEAL's sum or than the last line for <id> in the
#   archived MANIFEST.
# - Every session is changed when a fault belongs to no session: the .sha256 file beside FILE
#   does not hold exactly '<SHA-256 of FILE>  <file name of FILE>'; a non-zero byte follows the
#   end of the tar, in the same gzip stream or in another appended to it; a member name that is
#   absolute, holds '..', has another first part, or is <name>/<entry> for an entry other than
#   MANIFEST; a second <name>/MANIFEST; or an archived MANIFEST that is a byte prefix of the
#   MANIFEST of neither folder that <name> may name: the engagement folder <name> of the log
#   folder, and the log folder itself, when <name> is the last part of its path, as for --none.
#   Only a folder with a tie to the archive is compared: its MANIFEST names a session of the
#   archive, or its PRUNED records one. There a missing or emptied MANIFEST is compared as
#   empty, and fails, and so does a PRUNED that is a symlink, not a regular file or unreadable.
#   A folder with no tie, as on another computer, is not compared.
# - Without the .sha256 file it says so, and its verdicts stand, with this line alone on stderr:
#     tlogger: <FILE>.sha256 is missing; compare the archive's SHA-256, <sum>, with the one
#     archive printed
# - Exit 1, nothing on stdout, and the one line on stderr, for a FILE that is missing, not gzip,
#   or cut short:
#     tlogger: <FILE> does not exist
#     tlogger: <FILE> is not a gzip file
#     tlogger: <FILE> is cut short
#   Bytes after the gzip data that are no gzip stream also exit 1, with no 'ok' line.
# - python3 missing: exit 1, tlogger: archive needs python3
#
# Usage errors of archive exit 2 with the message first on stderr, then the usage:
#   tlogger: archive needs an engagement or --none
#   tlogger: archive takes an engagement or --none, not both
#   tlogger: archive takes one engagement at most
#   tlogger: unknown option for archive: <option>
#   tlogger: --older-than needs a value: a whole number of days
#   tlogger: --older-than takes a whole number of days, not '<value>'
#   tlogger: --verify needs a file
#   tlogger: archive --verify takes a file and nothing else
# An ENGAGEMENT that is no valid engagement name exits 2 with the message of tlogger engagement,
# "'<name>' is not a valid engagement name; ...". archive -h and --help print the usage, exit 0.
#
# tlogger prune ENGAGEMENT|--none --archive FILE [--older-than DAYS] [--delete [--confirm NAME]]
# - It takes one folder, <folder>, and its selection by --older-than as archive does, and never
#   the config's engagement. <name> is the folder's name: ENGAGEMENT, or with --none the last
#   part of the log folder's path. --archive=FILE and --confirm=NAME are accepted too. Without
#   --delete it is a dry run: it prints the plan and writes nothing at all.
# - It checks, in this order, and stops at the first that fails, changing nothing; each of these
#   prints nothing on stdout and its message alone on stderr:
#   1. the arguments: exit 2, see below. Then, with --delete but no --confirm when stdin or
#      stderr is no terminal, exit 2 with this message alone, before anything is read:
#        tlogger: --confirm is required with --delete when not run from a terminal
#   2. to 4. the log folder, logdir_mount and the folder, as archive checks them, with archive's
#      exit codes and messages; the session folders give keep lines instead (see below);
#   5. a session to take, exit 3: tlogger: no session to prune in <folder>
#   6. <folder>/PRUNED, when it exists, exit 1:
#        tlogger: <folder>/PRUNED is a symlink, which tlogger does not follow
#        tlogger: <folder>/PRUNED is not a regular file
#   7. python3, exit 1: tlogger: prune needs python3
#   8. FILE, exit 1: a file name that holds a space or a control character, which would break
#      the PRUNED line,
#        tlogger: the file name of the archive <FILE> holds a space or a control character;
#        rename it
#      (one line), then archive --verify's lines: does not exist, is not a gzip file, is cut
#      short;
#   9. the whole check of archive --verify on FILE, exit 1, when any session or fault fails it:
#        tlogger: the archive <FILE> fails its check; tlogger archive --verify <FILE> says why
#      A FILE without its .sha256 file passes, and archive --verify's line about that comes on
#      stderr. Then FILE must be of <folder>: its <name> and, as a byte prefix, its MANIFEST:
#        tlogger: the archive <FILE> is not of <folder>: it holds the folder <archived name>
#        tlogger: the archive <FILE> is not of <folder>: its MANIFEST is not the start of
#        <folder>/MANIFEST
#      (each one line).
# - The plan, on stdout: one line per session of the selection, by id, then the stays line:
#     <id>  remove
#     <id>  finish
#     <id>  keep: <reason>
#     stays: <folder>, its MANIFEST and PRUNED, every session not listed above, and
#     <log folder>/.archive
#   (the last is one line). The selection counts a session-named symlink in <folder> too, which
#   list and archive pass over. <reason> is the first of these that holds:
#   1. its folder: 'its folder is a symlink, which tlogger does not follow', 'its folder belongs
#      to another user', 'its folder is writable by its group or by others', or, when you may
#      not write or search it, 'its folder has mode <mode>, so you cannot remove its files'.
#      prune never runs chmod.
#   2. its verdict, as verify gives it, when not ok: 'recording', 'unsealed', 'unknown' or
#      'changed'; verify's own lines 'tlogger: <id>: ...' may come on stderr. A changed session
#      is 'finish' instead when PRUNED holds a line for <id> with the SHA-256 of the archived
#      SHA256SUMS of <id>, FILE's file name and FILE's SHA-256, and every entry left in its
#      folder is a regular 0400 file of yours with one link: a file the archived SHA256SUMS
#      lists, with that sum, its SHA256SUMS or SEAL as archived, or transcript.txt.
#   3. the archive: 'not in the archive', or 'the archive holds it with another sum' (the
#      SHA-256 of the archived SHA256SUMS is not the sum of the live SEAL and MANIFEST line);
#   4. its entries: 'it holds <entry>, which the seal does not cover', for any entry but the
#      files its SHA256SUMS lists, SHA256SUMS, SEAL and transcript.txt;
#   5. each entry: '<entry> is a symlink, which tlogger does not follow', '<entry> is not a
#      regular file', '<entry> belongs to another user', '<entry> has more than one hard link'.
#   A whole session that passes all five is 'remove', even when PRUNED holds a line for it, as
#   after a restore or a prune stopped before its first removal: each removal gets its own line.
# - It is all or nothing. When any line is keep, exit 1, with or without --delete, and this last
#   line on stderr:
#     tlogger: nothing changed: prune removes all the selected sessions or none; narrow the
#     selection with --older-than, or make a new archive
#   Else a dry run exits 0 with this line alone on stderr:
#     tlogger: nothing changed: this was a dry run; --delete removes the sessions marked remove
#     or finish
#   (each one line).
# - With --delete, after the plan: --confirm NAME must be <name> exactly. Without --confirm, on a
#   terminal, it asks on stderr, ending with ': ' and no line end, and reads one line:
#     tlogger: this cannot be undone; type the folder's name, <name>, to go ahead:
#   Any other NAME or answer: exit 1, nothing changed, and stderr ends with: tlogger: nothing
#   changed
# - Then session by session, oldest first, with HUP, INT, QUIT and TERM held off, it checks the
#   session again. For remove, it appends the session's PRUNED line under flock, syncs it and
#   prints it on stdout; for finish, it appends nothing and prints the line PRUNED holds. Then it
#   removes, each with unlink -- by its own name, the files SHA256SUMS lists, in its order, then
#   transcript.txt, SHA256SUMS and SEAL, and runs rmdir on the folder. Only unlink, rmdir,
#   flock and sync change anything: never rm, chmod, a glob, or a symlink followed.
# - Done: exit 0, stdout the plan and then the PRUNED line of each session, and this line alone
#   on stderr, after the question if one was asked ('session' for 1):
#     tlogger: removed <N> sessions of <folder>, as <folder>/PRUNED records
# - A PRUNED line that cannot be written, as in a PRUNED of mode 0400: exit 1, nothing of that
#   session or of those after it removed, and this last line on stderr:
#     tlogger: cannot write <folder>/PRUNED; nothing of session <id> was removed
#   When the line is written but sync fails, the line stays, nothing of the session is removed,
#   and the last line is (one line):
#     tlogger: cannot flush <folder>/PRUNED to the disk; it holds the line of session <id>, but
#     nothing of it was removed; run the same prune again
# - A removal that fails: exit 1, the sessions after it stay, and this last line on stderr:
#     tlogger: cannot remove <file>; session <id> is cut short and the sessions after it stay;
#     run the same prune again once that is fixed
#   (one line). verify --all then gives '<id>  changed' with, on stderr, the line
#     tlogger: <id>: a prune was cut short; run the same prune again
#   and the same prune with the same archive finishes it. verify gives that line for a session
#   that is changed, unsealed or unknown and that PRUNED records with its MANIFEST line's sum,
#   and counts it as changed; a whole session that PRUNED records is ok, with no such line.
# - <folder>/PRUNED lies beside the MANIFEST, mode 0600, made by its first line, and only grows.
#   One line per removal of a session, its fields split by two spaces:
#     <UTC time as YYYY-MM-DDTHH:MM:SSZ>  <id>  <SHA-256 of its SHA256SUMS>  <file name of FILE>
#     <SHA-256 of FILE>  tlogger <version>
#   (one line). The MANIFEST, <folder> even when empty, the log folder, .archive and every
#   archive stay as they are; once the folders are gone, verify --all gives '<id>  pruned'.
# - Exit codes: 0 done, or a dry run that --delete would carry out; 1 a refusal, a failure or a
#   wrong name; 2 a usage error, no folder, or --delete without --confirm off a terminal; 3 no
#   session selected, or no log folder.
#
# Usage errors of prune exit 2 with the message first on stderr, then the usage:
#   tlogger: prune needs an engagement or --none
#   tlogger: prune takes an engagement or --none, not both
#   tlogger: prune takes one engagement at most
#   tlogger: unknown option for prune: <option>
#   tlogger: prune needs --archive FILE
#   tlogger: --archive needs a file
#   tlogger: --confirm needs a value: the folder's name
#   tlogger: --confirm needs --delete
# and archive's two --older-than lines. A missing folder comes before a missing --archive. The
# engagement name check, -h and --help are as for archive.

bats_require_minimum_version 1.5.0

load helpers

# The boot id of the fake /proc, and the recorder that each synthetic session names; make_session
# and fake_process in helpers.bash read them, and LOGS and PROC, which setup sets.
BOOT=0b1e7c5a-4d2f-4c3b-9a8e-7f6d5c4b3a21
REC_PID=4242
REC_START=1000

# The log folder as tlogger shows it.
# shellcheck disable=SC2088 # The ~ is the text tlogger prints, not a path to expand.
SHOWN='~/.local/state/tlogger/sessions'

# The last line that archive prints when it is done.
SAME_VOLUME='tlogger: the archive lies on the same volume as the logs; copy it to encrypted'
SAME_VOLUME+=' storage elsewhere'

# A SHA-256 that no file here has.
ZERO_SUM=0000000000000000000000000000000000000000000000000000000000000000

# Run before each test by bats.
# Gives the test its own HOME with the default layout, a log folder of mode 0700, a fake /proc
# with a boot id, no process and an empty mountinfo, the python3 of the tests for bin/tlogger,
# and five session ids.
setup() {
    isolate_home
    isolate_tlogger
    LOGS="$HOME/.local/state/tlogger/sessions"
    ARCHIVES="$LOGS/.archive"
    mkdir -p "$LOGS"
    chmod 700 "$LOGS"
    PROC="$BATS_TEST_TMPDIR/proc"
    mkdir -p "$PROC/sys/kernel/random" "$PROC/self"
    printf '%s\n' "$BOOT" > "$PROC/sys/kernel/random/boot_id"
    : > "$PROC/self/mountinfo"
    export TLOGGER_PROC="$PROC"
    if [[ -n $PYTHON3 ]]; then
        export TLOGGER_PYTHON="$PYTHON3"
    fi
    TARTOOL="$REPO_ROOT/tests/helpers/tartool.py"
    A=20261112T100000Z-aaaaaa
    B=20261112T110000Z-bbbbbb
    C=20261112T120000Z-cccccc
    D=20261112T130000Z-dddddd
    E=20261112T140000Z-eeeeee
}

# Run after each test by bats.
# Gives every folder under HOME back to its owner's write, so that bats can remove a folder that
# a test closed.
teardown() {
    if [[ -d $HOME ]]; then
        find "$HOME" -type d -exec chmod u+rwx {} + 2> /dev/null || true
    fi
}

# Write the config with the lines TEXT, in a config folder of mode 0700.
write_config() {
    mkdir -p "$HOME/.config/tlogger"
    chmod 700 "$HOME/.config/tlogger"
    printf '%s' "$1" > "$HOME/.config/tlogger/config"
    chmod 600 "$HOME/.config/tlogger/config"
}

# Add a line to the fake mountinfo for an ext4 file system mounted at MOUNT, as Linux writes it.
mount_row() {
    local n
    n=$(( $(wc -l < "$PROC/self/mountinfo") + 20 ))
    printf '%s 1 254:%s / %s rw,relatime shared:%s - ext4 /dev/mapper/vg0-%s rw\n' "$n" "$n" \
        "$1" "$n" "$n" >> "$PROC/self/mountinfo"
}

# Create the engagement folder NAME of the log folder with mode 0700, the ended sessions IDS in
# it, and seal them all.
sealed_engagement() {
    local name=$1 id
    shift
    mkdir -p "$LOGS/$name"
    chmod 700 "$LOGS/$name"
    for id in "$@"; do
        make_session "$name/$id"
    done
    run_tlogger seal --all
    [ "$status" -eq 0 ]
}

# Print the session id whose UTC start lies DAYS days before now, with the suffix SUFFIX.
id_days_ago() {
    printf '%s-%s\n' "$(date -u -d "@$(( $(date +%s) - $1 * 86400 ))" +%Y%m%dT%H%M%SZ)" "$2"
}

# Print the refusal of the folder FOLDER, as shown, called WHAT, that its group or others may
# write in.
open_msg() {
    printf 'tlogger: %s %s is writable by its group or by others; chmod go-w %s fixes it' \
        "$1" "$2" "$2"
}

# Fail unless the last run was a usage error: exit status 2, nothing on stdout, MESSAGE as the
# first line of stderr, then the usage.
assert_usage_error() {
    if [[ $status -ne 2 || -n $output || ${stderr%%$'\n'*} != "$1" ||
        $stderr != *$'\nUsage: tlogger <command> [options]\n'* ]]; then
        printf 'expected the usage error %s, got status %s and:\n%s\n%s\n' "$1" "$status" \
            "$output" "$stderr" >&2
        return 1
    fi
}

# Print the line with which archive refuses the session ID of the folder FOLDER, as shown, whose
# verdict is VERDICT.
refusal_of() {
    local narrower='leave it out with a narrower --older-than'
    case $2 in
        recording)
            printf 'tlogger: session %s is recording; close the terminals recorded into %s,' "$1" \
                "$3"
            printf ' or leave it out with --older-than\n'
            ;;
        unsealed) printf 'tlogger: session %s is unsealed; tlogger seal --all seals it\n' "$1" ;;
        unknown)
            printf 'tlogger: session %s is unknown, as it has no recorder file and seal' "$1"
            printf ' refuses it; %s\n' "$narrower"
            ;;
        changed)
            printf 'tlogger: session %s is changed; tlogger verify %s names what changed, or %s\n' \
                "$1" "$1" "$narrower"
            ;;
        *) return 1 ;;
    esac
}

# Print the entries of .archive, at any depth, with their type, mode, size and time, and the
# SHA-256 of each file, but not the time of .archive itself.
archive_files() {
    (cd "$ARCHIVES" && find . ! -name . -printf '%p %y %m %s %T@\n' | LC_ALL=C sort &&
        find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum --)
}

# Fail unless LINE is a whole line of the last run's stderr.
assert_stderr_line() {
    local line
    for line in "${stderr_lines[@]}"; do
        if [[ $line == "$1" ]]; then
            return 0
        fi
    done
    printf 'stderr has no line\n%s\nbut:\n%s\n' "$1" "$stderr" >&2
    return 1
}

# Fail unless .archive holds exactly one archive of the folder NAME, written in the last 10
# minutes, and its .sha256 file, and nothing else. Sets ARCHIVE to the archive's path.
the_archive() {
    local name=$1 stamp when now
    local -a entries
    mapfile -t entries < <(find "$ARCHIVES" -mindepth 1 -maxdepth 1 -printf '%f\n' |
        LC_ALL=C sort)
    if (( ${#entries[@]} != 2 )) ||
        [[ ! ${entries[0]} =~ ^$name-([0-9]{8})T([0-9]{6})Z\.tar\.gz$ ||
        ${entries[1]} != "${entries[0]}.sha256" ]]; then
        printf 'expected one archive of %s and its .sha256 in .archive, found:\n' "$name" >&2
        printf '  %s\n' "${entries[@]}" >&2
        printf 'the last run exited %s, with:\n%s\n%s\n' "$status" "$output" "$stderr" >&2
        return 1
    fi
    ARCHIVE="$ARCHIVES/${entries[0]}"
    stamp=${BASH_REMATCH[1]}${BASH_REMATCH[2]}
    when=$(date -u -d "${stamp:0:8} ${stamp:8:2}:${stamp:10:2}:${stamp:12:2} UTC" +%s)
    now=$(date -u +%s)
    if (( now - when < 0 || now - when > 600 )); then
        printf 'the archive is named %s, not a UTC time of the last 10 minutes\n' "$ARCHIVE" >&2
        return 1
    fi
}

# Print the members of the .tar.gz FILE as tests/helpers/tartool.py lists them, sorted.
members_of() {
    "$PYTHON3" -I "$TARTOOL" list "$1" | tr -d '\r' | LC_ALL=C sort
}

# Print the member line, as tartool.py lists it, that the file PATH must have as the member NAME:
# a regular file with the file's mode, owner 0 and no user name, its size, time and SHA-256.
member_line() {
    printf '%s\tfile\t%s\t0\t0\t\t\t%s\t%s\t%s\n' "$1" "$(stat -c %a "$2")" "$(stat -c %s "$2")" \
        "$(stat -c %Y "$2")" "$(sha_of "$2")"
}

# Print, sorted, the member lines that an archive of the sessions IDS of the folder DIR must
# hold, under the name NAME: the MANIFEST, and for each session the files its SHA256SUMS lists,
# SHA256SUMS and SEAL.
expected_members() {
    local dir=$1 name=$2 id f
    shift 2
    {
        member_line "$name/MANIFEST" "$dir/MANIFEST"
        for id in "$@"; do
            while IFS= read -r f; do
                member_line "$name/$id/$f" "$dir/$id/$f"
            done < <(cut -c67- "$dir/$id/SHA256SUMS")
            member_line "$name/$id/SHA256SUMS" "$dir/$id/SHA256SUMS"
            member_line "$name/$id/SEAL" "$dir/$id/SEAL"
        done
    } | LC_ALL=C sort
}

# Fail unless the last run of archive was done: exit 0, nothing on stdout, and the three lines
# for COUNT sessions (WORD, session or sessions) of the folder FOLDER, as shown, on stderr,
# naming ARCHIVE and its SHA-256.
assert_archived() {
    local want
    want="tlogger: archived $1 $2 of $3 into $SHOWN/.archive/${ARCHIVE##*/}"
    want+=$'\n'"tlogger: SHA-256 of the archive: $(sha_of "$ARCHIVE"); keep it apart from the logs"
    want+=$'\n'"$SAME_VOLUME"
    if [[ $status -ne 0 || -n $output || $stderr != "$want" ]]; then
        printf 'expected status 0 and\n%s\ngot status %s and:\n%s\n%s\n' "$want" "$status" \
            "$output" "$stderr" >&2
        return 1
    fi
}

# Copy the engagement folder acme of the log folder, with its modes and times, to
# ~/cases/CASE/kept, and set KEPT to the copy.
copy_case() {
    mkdir -p "$HOME/cases/$1"
    cp -a "$LOGS/acme" "$HOME/cases/$1/kept"
    KEPT="$HOME/cases/$1/kept"
}

# Write ~/cases/CASE.tar.gz and its .sha256 file from KEPT, under the name kept, through
# tartool.py pack with the ops OPS, and set FILE to it. No folder of the log folder is named
# kept, so archive --verify has no live MANIFEST to compare.
pack_case() {
    FILE="$HOME/cases/$1.tar.gz"
    shift
    "$PYTHON3" -I "$TARTOOL" pack "$KEPT" kept "$FILE" "$@"
}

# Write the byte X over the first byte of FILE, keeping its mode.
flip_byte() {
    local mode
    mode=$(stat -c %a "$1")
    chmod 600 "$1"
    printf 'X' | dd of="$1" bs=1 seek=0 conv=notrunc status=none
    chmod "$mode" "$1"
}

# Write the SHA256SUMS of the session folder DIR again from its files, as someone hiding a
# change would, keeping its mode 0400.
resum() {
    local dir=$1
    local -a names
    mapfile -t names < <(cut -c67- "$dir/SHA256SUMS")
    (cd "$dir" && sha256sum -- "${names[@]}") > "$BATS_TEST_TMPDIR/sums"
    chmod 600 "$dir/SHA256SUMS"
    cat "$BATS_TEST_TMPDIR/sums" > "$dir/SHA256SUMS"
    chmod 400 "$dir/SHA256SUMS"
}

# Set the sum in the SEAL of the session folder DIR to SUM, keeping its mode 0400.
set_seal_sum() {
    chmod 600 "$1/SEAL"
    sed -i "3s/.*/sha256 $2/" "$1/SEAL"
    chmod 400 "$1/SEAL"
}

# Change the session A of KEPT as the tamper case CASE says.
tamper() {
    local dir=$KEPT/$A
    case $1 in
        none) ;;
        flipped) flip_byte "$dir/output.raw" ;;
        mode) chmod 600 "$dir/timing" ;;
        added)
            printf 'note\n' > "$dir/notes.txt"
            chmod 400 "$dir/notes.txt"
            ;;
        missing) rm -f "$dir/input.raw" ;;
        symlink)
            mv "$dir/commands.tsv" "$KEPT/commands.copy"
            ln -s ../commands.copy "$dir/commands.tsv"
            ;;
        resummed)
            flip_byte "$dir/output.raw"
            resum "$dir"
            ;;
        resealed)
            flip_byte "$dir/output.raw"
            resum "$dir"
            set_seal_sum "$dir" "$(sha_of "$dir/SHA256SUMS")"
            ;;
        seal) set_seal_sum "$dir" "$ZERO_SUM" ;;
        manifest) sed -i "s/^[0-9a-f]\{64\}  $A\//$ZERO_SUM  $A\//" "$KEPT/MANIFEST" ;;
        *) return 1 ;;
    esac
}

# Fail, naming CASE, unless the last run of archive --verify exited STATUS with WANT on stdout
# and no Python traceback.
assert_verdicts() {
    if [[ $status -ne $2 || $output != "$3" || $stderr == *Traceback* ]]; then
        printf 'case %s: expected status %s and\n%s\ngot status %s and:\n%s\n%s\n' "$1" "$2" \
            "$3" "$status" "$output" "$stderr" >&2
        return 1
    fi
}

# The last line of a dry run of prune that --delete would carry out.
DRY_RUN='tlogger: nothing changed: this was a dry run; --delete removes the sessions marked'
DRY_RUN+=' remove or finish'

# The last line of a prune that a kept session stops.
ALL_OR_NONE='tlogger: nothing changed: prune removes all the selected sessions or none; narrow'
ALL_OR_NONE+=' the selection with --older-than, or make a new archive'

# Print the last line of prune's plan for the folder FOLDER, as shown.
stays_line() {
    printf 'stays: %s, its MANIFEST and PRUNED, every session not listed above,' "$1"
    printf ' and %s/.archive\n' "$SHOWN"
}

# Archive the folder NAME, an engagement or --none, and set ARCHIVE to the archive it wrote, the
# only one of that folder in .archive, and SHOWN_ARCHIVE to it as tlogger shows it.
make_archive() {
    local name=$1
    local -a found
    run_tlogger archive "$name"
    if [[ $name == --none ]]; then
        name=${LOGS##*/}
    fi
    mapfile -t found < <(find "$ARCHIVES" -maxdepth 1 -name "$name-*.tar.gz" 2> /dev/null)
    if (( status != 0 || ${#found[@]} != 1 )); then
        printf 'archive %s exited %s and left %s archives of it:\n%s\n' "$1" "$status" \
            "${#found[@]}" "$stderr" >&2
        return 1
    fi
    ARCHIVE=${found[0]}
    SHOWN_ARCHIVE="$SHOWN/.archive/${ARCHIVE##*/}"
}

# Write the stand-ins that run_watched puts first on PATH, in a folder of the test's own, and
# empty CALLS and UNLINK_FAIL. rm, which prune must never run, logs 'rm<tab><arguments>' to
# CALLS and fails loudly. unlink logs 'unlink<tab><its file, resolved>' to CALLS; for the
# resolved file that UNLINK_FAIL names it fails as on an immutable file, else it runs the real
# unlink.
make_stand_ins() {
    local real
    real=$(command -v unlink)
    STAND_INS="$BATS_TEST_TMPDIR/stand-ins"
    CALLS="$BATS_TEST_TMPDIR/calls"
    UNLINK_FAIL=
    mkdir -p "$STAND_INS"
    : > "$CALLS"
    # The stand-ins expand these when they run, not this function.
    # shellcheck disable=SC2016
    printf '%s\n' '#!/usr/bin/env bash' \
        'printf '\''rm\t%s\n'\'' "$*" >> "$CALLS"' \
        'printf '\''rm stand-in: prune ran rm %s\n'\'' "$*" >&2' \
        'exit 1' > "$STAND_INS/rm"
    # shellcheck disable=SC2016
    printf '%s\n' '#!/usr/bin/env bash' \
        'file=$(readlink -f -- "${!#}")' \
        'printf '\''unlink\t%s\n'\'' "$file" >> "$CALLS"' \
        'if [[ -n ${UNLINK_FAIL-} && $file == "$UNLINK_FAIL" ]]; then' \
        '    printf '\''unlink: cannot unlink %s: Operation not permitted\n'\'' "${!#}" >&2' \
        '    exit 1' \
        'fi' \
        "exec '$real' \"\$@\"" > "$STAND_INS/unlink"
    chmod 755 "$STAND_INS/rm" "$STAND_INS/unlink"
}

# Run bin/tlogger with ARGS as run_tlogger does, with the stand-ins of make_stand_ins first on
# its PATH, and CALLS and UNLINK_FAIL in its environment. The test's own commands keep the real
# tools.
run_watched() {
    require_test_home || return 1
    run --separate-stderr env PATH="$STAND_INS:$PATH" CALLS="$CALLS" UNLINK_FAIL="$UNLINK_FAIL" \
        bash "$TLOGGER" "$@" < /dev/null
}

# Fail, naming the calls, if bin/tlogger ran rm since make_stand_ins.
refute_rm() {
    if grep -q '^rm' "$CALLS"; then
        printf 'prune ran rm:\n%s\n' "$(grep '^rm' "$CALLS")" >&2
        return 1
    fi
}

# Fail, naming the calls, if bin/tlogger ran rm, or unlink on anything in the log folder, since
# make_stand_ins.
refute_removed() {
    local hits
    refute_rm || return 1
    hits=$(grep -F "unlink"$'\t'"$(readlink -f -- "$LOGS")/" "$CALLS") || true
    if [[ -n $hits ]]; then
        printf 'prune removed files:\n%s\n' "$hits" >&2
        return 1
    fi
}

# Print the resolved paths of the files of the session folder DIR in the order prune removes
# them: the files its SHA256SUMS lists, in that order, then transcript.txt when it is there,
# SHA256SUMS and SEAL.
removal_order() {
    local f
    {
        cut -c67- "$1/SHA256SUMS"
        if [[ -e $1/transcript.txt ]]; then
            printf 'transcript.txt\n'
        fi
        printf '%s\n' SHA256SUMS SEAL
    } | while IFS= read -r f; do
        readlink -f -- "$1/$f"
    done
}

# Fail unless LINE is a PRUNED line, written in the last 10 minutes by this version of tlogger,
# for the session ID whose SHA256SUMS had the SHA-256 SUM, removed with the archive ARCHIVE.
assert_pruned_line() {
    local stamp=${1%%  *} want when now
    want="$2  $3  ${ARCHIVE##*/}  $(sha_of "$ARCHIVE")  tlogger $(< "$REPO_ROOT/VERSION")"
    if [[ ${1#*  } != "$want" ||
        ! $stamp =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
        printf 'expected a PRUNED line\n<UTC time>  %s\ngot\n%s\n' "$want" "$1" >&2
        return 1
    fi
    when=$(date -u -d "$stamp" +%s)
    now=$(date -u +%s)
    if (( now - when < 0 || now - when > 600 )); then
        printf 'the PRUNED line names %s, not a UTC time of the last 10 minutes\n' "$stamp" >&2
        return 1
    fi
}

# Print the last line of the last run's stderr, or nothing.
last_stderr_line() {
    if (( ${#stderr_lines[@]} )); then
        printf '%s\n' "${stderr_lines[${#stderr_lines[@]} - 1]}"
    fi
}

# Fail unless the last run of prune refused for a kept session: exit 1, the plan PLAN on stdout,
# and on stderr ALL_OR_NONE as the last line, after verify's lines about the sessions IDS only.
assert_kept() {
    local plan=$1 line id ok n=${#stderr_lines[@]}
    shift
    if [[ $status -ne 1 || $output != "$plan" || $(last_stderr_line) != "$ALL_OR_NONE" ]]; then
        printf 'expected status 1, the plan\n%s\nand last\n%s\ngot status %s and:\n%s\n%s\n' \
            "$plan" "$ALL_OR_NONE" "$status" "$output" "$stderr" >&2
        return 1
    fi
    for line in "${stderr_lines[@]:0:n-1}"; do
        ok=0
        for id in "$@"; do
            if [[ $line == "tlogger: $id: "* ]]; then
                ok=1
            fi
        done
        if (( ! ok )); then
            printf 'stderr has a line that is neither verify'\''s nor the last:\n%s\n' "$line" >&2
            return 1
        fi
    done
    refute_home_shown
}

@test "archive packs the sealed sessions of an engagement into a checked .tar.gz in .archive" {
    need modes
    need python3
    local before
    sealed_engagement acme "$A" "$B"
    mkdir -m 700 "$LOGS/demo"
    make_session "demo/$C"
    make_session "$D"
    run_tlogger seal --all
    [ "$status" -eq 0 ]
    # A transcript and the temp files of render and seal stay out of the archive.
    printf 'derived\n' > "$LOGS/acme/$A/transcript.txt"
    printf 'part\n' > "$LOGS/acme/$A/transcript.txt.part"
    printf 'part\n' > "$LOGS/acme/$B/SHA256SUMS.part.Ab12Cd"
    before=$(tree_of "$LOGS/acme")
    [ ! -e "$ARCHIVES" ]
    run_tlogger archive acme
    the_archive acme
    assert_archived 2 sessions "$SHOWN/acme"
    [ "$(stat -c %a "$ARCHIVES")" = 700 ]
    [ "$(stat -c %a "$ARCHIVE")" = 400 ]
    [ "$(stat -c %a "$ARCHIVE.sha256")" = 400 ]
    [ "$(cat "$ARCHIVE.sha256")" = "$(sha_of "$ARCHIVE")  ${ARCHIVE##*/}" ]
    (cd "$ARCHIVES" && sha256sum --quiet -c "${ARCHIVE##*/}.sha256")
    # Exactly the MANIFEST and the sealed files of acme, each as it is: no folder entry, no link,
    # owner 0 and no user name, the mode and the time of the file.
    [ "$(members_of "$ARCHIVE")" = "$(expected_members "$LOGS/acme" acme "$A" "$B")" ]
    # Nothing in the folder changed, and every session still verifies.
    [ "$(tree_of "$LOGS/acme")" = "$before" ]
    run_tlogger verify --all
    [ "$status" -eq 0 ]
}

@test "archive --none takes only the sessions directly in the log folder, named after it" {
    need modes
    need python3
    sealed_engagement acme "$C"
    make_session "$A"
    make_session "$B"
    run_tlogger seal --all
    [ "$status" -eq 0 ]
    run_tlogger archive --none
    the_archive sessions
    assert_archived 2 sessions "$SHOWN"
    [ "$(members_of "$ARCHIVE")" = "$(expected_members "$LOGS" sessions "$A" "$B")" ]
}

@test "archive --older-than takes sessions by the UTC time in their id, never by file times" {
    need modes
    need python3
    local old young want
    old=$(id_days_ago 10 o1d0a2)
    young=$(id_days_ago 2 y0ung1)
    sealed_engagement acme "$old"
    # young is still recorded, by the live recorder 4242. File times say the opposite of the ids.
    make_session "acme/$young"
    fake_process "$REC_PID" "$REC_START"
    find "$LOGS/acme/$old" -exec touch -d "@$(date +%s)" {} +
    find "$LOGS/acme/$young" -exec touch -d "@$(( $(date +%s) - 30 * 86400 ))" {} +
    want=$(refusal_of "$young" recording "$SHOWN/acme")
    run_tlogger archive acme
    assert_refused 1 "$want"
    run_tlogger archive acme --older-than=1
    assert_refused 1 "$want"
    [ ! -e "$ARCHIVES" ]
    run_tlogger archive --older-than 20 acme
    assert_refused 3 "tlogger: no session to archive in $SHOWN/acme"
    [ ! -e "$ARCHIVES" ]
    run_tlogger archive acme --older-than 5
    the_archive acme
    assert_archived 1 session "$SHOWN/acme"
    [ "$(members_of "$ARCHIVE")" = "$(expected_members "$LOGS/acme" acme "$old")" ]
}

@test "archive refuses a session that is recording, unsealed, unknown or changed, writing nothing" {
    need modes
    local before line want
    # A and E sealed, then a log of E made writable again: changed. B ended unsealed, its own
    # recorder gone; C still recorded by the live recorder 4242; D without a recorder file.
    sealed_engagement acme "$A" "$E"
    chmod 600 "$LOGS/acme/$E/timing"
    make_session "acme/$B"
    chmod 600 "$LOGS/acme/$B/recorder"
    printf '4343 2000 %s 34818\n' "$BOOT" > "$LOGS/acme/$B/recorder"
    make_session "acme/$C"
    make_session "acme/$D"
    rm "$LOGS/acme/$D/recorder"
    fake_process "$REC_PID" "$REC_START"
    before=$(tree_of "$LOGS")
    run_tlogger archive acme
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    want=$(refusal_of "$B" unsealed; refusal_of "$C" recording "$SHOWN/acme"
        refusal_of "$D" unknown; refusal_of "$E" changed)
    # One line per session, by id; only verify's own lines about E may come with them.
    [ "$(grep '^tlogger: session ' <<< "$stderr")" = "$want" ]
    for line in "${stderr_lines[@]}"; do
        [[ $line == "tlogger: session "* || $line == "tlogger: $E: "* ]]
    done
    refute_home_shown
    [ "$(tree_of "$LOGS")" = "$before" ]
    [ ! -e "$ARCHIVES" ]
}

@test "archive refuses a symlinked log, and a log or MANIFEST with a second hard link" {
    need modes
    need symlinks
    need hardlinks
    need python3
    local before
    sealed_engagement acme "$A" "$B"
    mkdir -m 700 "$HOME/elsewhere"
    # A second name for a log, or for the MANIFEST, could change it behind the seal.
    ln "$LOGS/acme/$A/output.raw" "$HOME/elsewhere/output.raw"
    before=$(tree_of "$LOGS")
    run_tlogger archive acme
    assert_refused 1 "tlogger: $SHOWN/acme/$A/output.raw has more than one hard link"
    rm "$HOME/elsewhere/output.raw"
    ln "$LOGS/acme/MANIFEST" "$HOME/elsewhere/MANIFEST"
    run_tlogger archive acme
    assert_refused 1 "tlogger: $SHOWN/acme/MANIFEST has more than one hard link"
    rm "$HOME/elsewhere/MANIFEST"
    [ "$(tree_of "$LOGS")" = "$before" ]
    [ ! -e "$ARCHIVES" ]
    # A symlinked log makes the session changed, which archive names.
    mv "$LOGS/acme/$B/commands.tsv" "$HOME/elsewhere/commands.tsv"
    ln -s "$HOME/elsewhere/commands.tsv" "$LOGS/acme/$B/commands.tsv"
    before=$(tree_of "$LOGS")
    run_tlogger archive acme
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    assert_stderr_line "$(refusal_of "$B" changed)"
    [ "$(tree_of "$LOGS")" = "$before" ]
    [ ! -e "$ARCHIVES" ]
    # Put back as sealed, the folder archives.
    rm "$LOGS/acme/$B/commands.tsv"
    mv "$HOME/elsewhere/commands.tsv" "$LOGS/acme/$B/commands.tsv"
    run_tlogger archive acme
    the_archive acme
    assert_archived 2 sessions "$SHOWN/acme"
}

@test "archive refuses a log, engagement or session folder open to group or others, sticky or not" {
    need modes
    local before mode
    sealed_engagement acme "$A"
    make_session "$B"
    run_tlogger seal --all
    [ "$status" -eq 0 ]
    before=$(tree_of "$LOGS")
    # The session commands take a sticky log folder; archive does not.
    chmod 1777 "$LOGS"
    run_tlogger verify --all
    [ "$status" -eq 0 ]
    for mode in 1777 770 1730; do
        chmod "$mode" "$LOGS"
        run_tlogger archive acme
        assert_refused 1 "$(open_msg 'the log folder' "$SHOWN")"
        run_tlogger archive --none
        assert_refused 1 "$(open_msg 'the log folder' "$SHOWN")"
    done
    chmod 700 "$LOGS"
    for mode in 1770 707; do
        chmod "$mode" "$LOGS/acme"
        run_tlogger archive acme
        assert_refused 1 "$(open_msg 'the engagement folder' "$SHOWN/acme")"
    done
    chmod 700 "$LOGS/acme"
    chmod 770 "$LOGS/acme/$A"
    run_tlogger archive acme
    assert_refused 1 "$(open_msg 'the session folder' "$SHOWN/acme/$A")"
    chmod 1777 "$LOGS/$B"
    run_tlogger archive --none
    assert_refused 1 "$(open_msg 'the session folder' "$SHOWN/$B")"
    chmod 700 "$LOGS/acme/$A" "$LOGS/$B"
    [ "$(tree_of "$LOGS")" = "$before" ]
    [ ! -e "$ARCHIVES" ]
}

@test "archive refuses an .archive that is a symlink, a file, or a folder of a mode not 0700" {
    need modes
    need symlinks
    need python3
    local before
    sealed_engagement acme "$A"
    mkdir -m 700 "$HOME/elsewhere"
    ln -s "$HOME/elsewhere" "$ARCHIVES"
    before=$(tree_of "$LOGS/acme")
    run_tlogger archive acme
    assert_refused 1 "tlogger: $SHOWN/.archive is a symlink, which tlogger does not follow"
    [ -z "$(ls -A "$HOME/elsewhere")" ]
    rm "$ARCHIVES"
    printf 'not a folder\n' > "$ARCHIVES"
    run_tlogger archive acme
    assert_refused 1 "tlogger: $SHOWN/.archive is not a folder"
    [ "$(cat "$ARCHIVES")" = 'not a folder' ]
    rm "$ARCHIVES"
    mkdir -m 755 "$ARCHIVES"
    run_tlogger archive acme
    assert_refused 1 \
        "tlogger: $SHOWN/.archive has mode 755, not 700; chmod 700 $SHOWN/.archive fixes it"
    [ -z "$(ls -A "$ARCHIVES")" ]
    [ "$(tree_of "$LOGS/acme")" = "$before" ]
    # A private .archive made by hand is taken as it is.
    chmod 700 "$ARCHIVES"
    run_tlogger archive acme
    the_archive acme
    assert_archived 1 session "$SHOWN/acme"
}

@test "archive refuses when logdir_mount names a volume that is not mounted or not the log's" {
    need modes
    need python3
    local before
    sealed_engagement acme "$A"
    before=$(tree_of "$LOGS")
    mount_row /
    write_config "logdir_mount=$HOME/.local/state"$'\n'
    run_tlogger archive acme
    assert_refused 1 'tlogger: the volume ~/.local/state of the log folder is not mounted'
    run_tlogger archive --none
    assert_refused 1 'tlogger: the volume ~/.local/state of the log folder is not mounted'
    mount_row "$HOME/vault"
    write_config "logdir_mount=$HOME/vault"$'\n'
    run_tlogger archive acme
    assert_refused 1 \
        "tlogger: the log folder $SHOWN does not lie on the volume ~/vault that logdir_mount names"
    [ "$(tree_of "$LOGS")" = "$before" ]
    [ ! -e "$ARCHIVES" ]
    # Mounted, the guard lets archive go on.
    mount_row "$HOME/.local/state"
    write_config "logdir_mount=$HOME/.local/state"$'\n'
    run_tlogger archive acme
    the_archive acme
    assert_archived 1 session "$SHOWN/acme"
}

@test "archive never replaces a file in .archive, and leaves no temp file" {
    need modes
    need python3
    local now t name files want
    sealed_engagement acme "$A"
    mkdir -m 700 "$ARCHIVES"
    # A file under each name that archive could pick in the next 40 seconds.
    now=$(date +%s)
    for (( t = now - 2; t <= now + 40; t++ )); do
        name="acme-$(date -u -d "@$t" +%Y%m%dT%H%M%SZ).tar.gz"
        printf 'kept %s\n' "$t" > "$ARCHIVES/$name"
        chmod 400 "$ARCHIVES/$name"
    done
    files=$(archive_files)
    run_tlogger archive acme
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [ "${#stderr_lines[@]}" -eq 1 ]
    want="tlogger: $SHOWN/.archive/acme-*.tar.gz exists already; archive never replaces a file"
    # shellcheck disable=SC2053 # want is a pattern: the time in the name is not known here.
    [[ $stderr == $want ]]
    # No file changed, no .sha256 file came, and no temp file is left.
    [ "$(archive_files)" = "$files" ]
}

@test "archive exits 3 without a session to archive, and 1 for an engagement folder not there" {
    need modes
    sealed_engagement acme "$A"
    mkdir -m 700 "$LOGS/demo"
    run_tlogger archive demo
    assert_refused 3 "tlogger: no session to archive in $SHOWN/demo"
    # The sessions of acme are not directly in the log folder.
    run_tlogger archive --none
    assert_refused 3 "tlogger: no session to archive in $SHOWN"
    run_tlogger archive nosuch
    assert_refused 1 "tlogger: there is no engagement folder nosuch in $SHOWN"
    [ ! -e "$ARCHIVES" ]
    [ ! -e "$LOGS/nosuch" ]
    write_config "logdir=$HOME/gone"$'\n'
    run_tlogger archive acme
    assert_refused 3 'tlogger: no sessions: the log folder ~/gone does not exist'
    [ ! -e "$HOME/gone" ]
}

@test "archive without a folder is a usage error, and never takes the config's engagement" {
    mkdir -p "$LOGS/acme"
    chmod 700 "$LOGS/acme"
    make_session "acme/$A"
    write_config $'engagement=acme\n'
    run_tlogger archive
    assert_usage_error 'tlogger: archive needs an engagement or --none'
    run_tlogger archive --older-than 1
    assert_usage_error 'tlogger: archive needs an engagement or --none'
    [ ! -e "$ARCHIVES" ]
}

@test "archive refuses wrong arguments with a usage error, and prints its help" {
    local value
    run_tlogger archive acme --none
    assert_usage_error 'tlogger: archive takes an engagement or --none, not both'
    run_tlogger archive --none acme
    assert_usage_error 'tlogger: archive takes an engagement or --none, not both'
    run_tlogger archive acme demo
    assert_usage_error 'tlogger: archive takes one engagement at most'
    run_tlogger archive acme --force
    assert_usage_error 'tlogger: unknown option for archive: --force'
    run_tlogger archive acme --older-than
    assert_usage_error 'tlogger: --older-than needs a value: a whole number of days'
    for value in x -1 1.5 '' 3d; do
        run_tlogger archive acme --older-than "$value"
        assert_usage_error "tlogger: --older-than takes a whole number of days, not '$value'"
    done
    run_tlogger archive --verify
    assert_usage_error 'tlogger: --verify needs a file'
    run_tlogger archive --verify "$HOME/a.tar.gz" acme
    assert_usage_error 'tlogger: archive --verify takes a file and nothing else'
    run_tlogger archive acme --verify "$HOME/a.tar.gz"
    assert_usage_error 'tlogger: archive --verify takes a file and nothing else'
    run_tlogger archive --none --verify "$HOME/a.tar.gz"
    assert_usage_error 'tlogger: archive --verify takes a file and nothing else'
    run_tlogger archive --verify "$HOME/a.tar.gz" --older-than 3
    assert_usage_error 'tlogger: archive --verify takes a file and nothing else'
    for value in 'bad name' MANIFEST "$A" .archive; do
        run_tlogger archive "$value"
        [ "$status" -eq 2 ]
        [ -z "$output" ]
        [[ ${stderr_lines[0]} == "tlogger: '$value' is not a valid engagement name; "* ]]
    done
    [ ! -e "$ARCHIVES" ]
    run_tlogger archive --help
    [ "$status" -eq 0 ]
    [[ $output == 'Usage: tlogger <command> [options]'* ]]
}

@test "archive and archive --verify need python3, and archive writes nothing without it" {
    need modes
    need python3
    local file
    sealed_engagement acme "$A"
    TLOGGER_PYTHON=$HOME/missing run_tlogger archive acme
    assert_refused 1 'tlogger: archive needs python3'
    [ ! -e "$ARCHIVES" ]
    run_tlogger archive acme
    the_archive acme
    file=$ARCHIVE
    TLOGGER_PYTHON=$HOME/missing run_tlogger archive --verify "$file"
    assert_refused 1 'tlogger: archive needs python3'
}

@test "an archive unpacked with umask 077, as yourself, holds sessions that verify ok" {
    need modes
    need python3
    local id
    sealed_engagement acme "$A" "$B"
    run_tlogger archive acme
    the_archive acme
    (umask 077 && mkdir "$HOME/restore" && tar -xzf "$ARCHIVE" -C "$HOME/restore")
    [ "$(stat -c %a "$HOME/restore/acme")" = 700 ]
    cmp "$HOME/restore/acme/MANIFEST" "$LOGS/acme/MANIFEST"
    for id in "$A" "$B"; do
        [ "$(stat -c %a "$HOME/restore/acme/$id")" = 700 ]
        [ "$(modes_of "$HOME/restore/acme/$id")" = "$(modes_of "$LOGS/acme/$id")" ]
        [ "$(cd "$HOME/restore/acme/$id" && sha256sum -- *)" = \
            "$(cd "$LOGS/acme/$id" && sha256sum -- *)" ]
        run_tlogger verify "$HOME/restore/acme/$id"
        [ "$status" -eq 0 ]
        [ "$output" = "$id  ok" ]
    done
}

@test "archive --verify prints ok for each session of a whole archive, and writes nothing" {
    need modes
    need python3
    local before sum want
    sealed_engagement acme "$A" "$B"
    run_tlogger archive acme
    the_archive acme
    # One that tlogger wrote, and one that another tar writer made of the same sessions.
    copy_case plain
    pack_case plain
    before=$(tree_of "$HOME")
    run_tlogger archive --verify "$ARCHIVE"
    assert_verdicts tlogger 0 "$A  ok"$'\n'"$B  ok"
    [ -z "$stderr" ]
    run_tlogger archive --verify "$FILE"
    assert_verdicts tartool 0 "$A  ok"$'\n'"$B  ok"
    [ -z "$stderr" ]
    [ "$(tree_of "$HOME")" = "$before" ]
    [ -z "$(ls -A "$TMPDIR")" ]
    # Without its .sha256 file, it names the sum to compare.
    rm "$FILE.sha256"
    sum=$(sha_of "$FILE")
    run_tlogger archive --verify "$FILE"
    assert_verdicts no-sidecar 0 "$A  ok"$'\n'"$B  ok"
    want="tlogger: ~/cases/plain.tar.gz.sha256 is missing; compare the archive's SHA-256, $sum,"
    [ "$stderr" = "$want with the one archive printed" ]
    # A session sealed later only adds to the live MANIFEST of acme: the archive still agrees.
    make_session "acme/$C"
    run_tlogger seal "$C"
    [ "$status" -eq 0 ]
    run_tlogger archive --verify "$ARCHIVE"
    assert_verdicts later-seal 0 "$A  ok"$'\n'"$B  ok"
    # A live MANIFEST whose first line changed no longer starts with the archived one.
    sed -i '1s/^./x/' "$LOGS/acme/MANIFEST"
    run_tlogger archive --verify "$ARCHIVE"
    assert_verdicts live-manifest 1 "$A  changed"$'\n'"$B  changed"
}

@test "archive --verify and verify give the same verdicts on the same tampered sessions" {
    need modes
    need symlinks
    need python3
    local name want status_want
    sealed_engagement acme "$A" "$B"
    for name in none flipped mode added missing symlink resummed resealed seal manifest; do
        copy_case "$name"
        tamper "$name"
        pack_case "$name"
        want=changed status_want=1
        if [[ $name == none ]]; then
            want=ok status_want=0
        fi
        run_tlogger verify "$KEPT/$A"
        assert_verdicts "$name (verify)" "$status_want" "$A  $want"
        run_tlogger verify "$KEPT/$B"
        assert_verdicts "$name (verify)" 0 "$B  ok"
        run_tlogger archive --verify "$FILE"
        assert_verdicts "$name" "$status_want" "$A  $want"$'\n'"$B  ok"
    done
}

@test "archive --verify finds a bad name, a link, a device, a folder entry or a duplicate" {
    need modes
    need python3
    local both="$A  changed"$'\n'"$B  changed" one="$A  changed"$'\n'"$B  ok"
    sealed_engagement acme "$A" "$B"
    copy_case faults
    # Faults of no session: every session is changed.
    pack_case up --add ../x text
    run_tlogger archive --verify "$FILE"
    assert_verdicts up 1 "$both"
    pack_case absolute --add /x text
    run_tlogger archive --verify "$FILE"
    assert_verdicts absolute 1 "$both"
    pack_case loose --add kept/notes.txt text
    run_tlogger archive --verify "$FILE"
    assert_verdicts loose 1 "$both"
    pack_case other --add "other/$A/output.raw" text
    run_tlogger archive --verify "$FILE"
    assert_verdicts other 1 "$both"
    pack_case two-manifests --dup kept/MANIFEST
    run_tlogger archive --verify "$FILE"
    assert_verdicts two-manifests 1 "$both"
    # Faults of one session: only that session is changed.
    pack_case duplicate --dup "kept/$A/output.raw"
    run_tlogger archive --verify "$FILE"
    assert_verdicts duplicate 1 "$one"
    pack_case hardlink --hardlink "kept/$A/stop-requested" "kept/$A/output.raw"
    run_tlogger archive --verify "$FILE"
    assert_verdicts hardlink 1 "$one"
    pack_case device --device "kept/$A/stop-requested"
    run_tlogger archive --verify "$FILE"
    assert_verdicts device 1 "$one"
    pack_case folder --dir "kept/$A"
    run_tlogger archive --verify "$FILE"
    assert_verdicts folder 1 "$one"
}

@test "archive --verify finds a wrong .sha256 file and data after the end of the archive" {
    need modes
    need python3
    local both="$A  changed"$'\n'"$B  changed"
    sealed_engagement acme "$A" "$B"
    copy_case sums
    pack_case wrong-sum
    printf '%s  %s\n' "$ZERO_SUM" wrong-sum.tar.gz > "$FILE.sha256"
    run_tlogger archive --verify "$FILE"
    assert_verdicts wrong-sum 1 "$both"
    pack_case wrong-name
    printf '%s  %s\n' "$(sha_of "$FILE")" other.tar.gz > "$FILE.sha256"
    run_tlogger archive --verify "$FILE"
    assert_verdicts wrong-name 1 "$both"
    pack_case trailing-same --trailing-same
    run_tlogger archive --verify "$FILE"
    assert_verdicts trailing-same 1 "$both"
    pack_case trailing-gzip --trailing-gzip
    run_tlogger archive --verify "$FILE"
    assert_verdicts trailing-gzip 1 "$both"
    # Bytes after the gzip data that are no gzip stream: no session can be called ok.
    pack_case junk
    printf 'junk after the archive\n' >> "$FILE"
    printf '%s  %s\n' "$(sha_of "$FILE")" junk.tar.gz > "$FILE.sha256"
    run_tlogger archive --verify "$FILE"
    [ "$status" -eq 1 ]
    [[ $output != *'  ok'* ]]
    [[ $stderr != *Traceback* ]]
}

@test "archive --verify exits 1 for a missing, non-gzip or cut-short file, and writes nothing" {
    need modes
    need python3
    local before size
    sealed_engagement acme "$A" "$B"
    copy_case whole
    pack_case whole
    printf 'not an archive\n' > "$HOME/cases/plain.tar.gz"
    (cd "$HOME/cases" && sha256sum plain.tar.gz > plain.tar.gz.sha256)
    size=$(stat -c %s "$FILE")
    head -c $(( size / 2 )) "$FILE" > "$HOME/cases/cut.tar.gz"
    (cd "$HOME/cases" && sha256sum cut.tar.gz > cut.tar.gz.sha256)
    before=$(tree_of "$HOME")
    run_tlogger archive --verify "$HOME/cases/none.tar.gz"
    assert_refused 1 'tlogger: ~/cases/none.tar.gz does not exist'
    run_tlogger archive --verify "$HOME/cases/plain.tar.gz"
    assert_refused 1 'tlogger: ~/cases/plain.tar.gz is not a gzip file'
    run_tlogger archive --verify "$HOME/cases/cut.tar.gz"
    assert_refused 1 'tlogger: ~/cases/cut.tar.gz is cut short'
    [ "$(tree_of "$HOME")" = "$before" ]
    [ -z "$(ls -A "$TMPDIR")" ]
}

@test "prune --delete --confirm removes only the selected sessions, and PRUNED records each" {
    need modes
    need python3
    local old1 old2 young sum1 sum2 sum plan before keep_young keep_demo keep_e keep_acme files
    local -a lines
    old1=$(id_days_ago 10 o1d0a1)
    old2=$(id_days_ago 9 o1d0a2)
    young=$(id_days_ago 1 y0ung1)
    sealed_engagement acme "$old1" "$old2" "$young"
    mkdir -m 700 "$LOGS/demo"
    make_session "demo/$D"
    make_session "$E"
    run_tlogger seal --all
    [ "$status" -eq 0 ]
    make_archive acme
    make_stand_ins
    cp "$LOGS/acme/MANIFEST" "$BATS_TEST_TMPDIR/manifest"
    sum1=$(sha_of "$LOGS/acme/$old1/SHA256SUMS")
    sum2=$(sha_of "$LOGS/acme/$old2/SHA256SUMS")
    plan=$(printf '%s  remove\n' "$old1" "$old2"; stays_line "$SHOWN/acme")
    # The dry run shows the plan and writes nothing: no file, mode or time changes.
    before=$(tree_of "$HOME")
    run_watched prune acme --archive "$ARCHIVE" --older-than 5
    [ "$status" -eq 0 ]
    [ "$output" = "$plan" ]
    [ "$stderr" = "$DRY_RUN" ]
    [ "$(tree_of "$HOME")" = "$before" ]
    [ -z "$(ls -A "$TMPDIR")" ]
    keep_young=$(tree_of "$LOGS/acme/$young")
    keep_demo=$(tree_of "$LOGS/demo")
    keep_e=$(tree_of "$LOGS/$E")
    files=$(archive_files)
    run_watched prune acme --archive "$ARCHIVE" --older-than 5 --delete --confirm acme
    [ "$status" -eq 0 ]
    [ "$stderr" = "tlogger: removed 2 sessions of $SHOWN/acme, as $SHOWN/acme/PRUNED records" ]
    # One line per session in a new PRUNED of mode 0600, also printed after the plan.
    [ "$(stat -c %a "$LOGS/acme/PRUNED")" = 600 ]
    mapfile -t lines < "$LOGS/acme/PRUNED"
    [ "${#lines[@]}" -eq 2 ]
    assert_pruned_line "${lines[0]}" "$old1" "$sum1"
    assert_pruned_line "${lines[1]}" "$old2" "$sum2"
    [ "$output" = "$plan"$'\n'"${lines[0]}"$'\n'"${lines[1]}" ]
    [[ ! -e $LOGS/acme/$old1 && ! -L $LOGS/acme/$old1 ]]
    [[ ! -e $LOGS/acme/$old2 && ! -L $LOGS/acme/$old2 ]]
    # The MANIFEST, the engagement folder, the young session, the other folders and the archive
    # stay as they were.
    cmp "$LOGS/acme/MANIFEST" "$BATS_TEST_TMPDIR/manifest"
    [ "$(stat -c %a "$LOGS/acme")" = 700 ]
    [ "$(tree_of "$LOGS/acme/$young")" = "$keep_young" ]
    [ "$(tree_of "$LOGS/demo")" = "$keep_demo" ]
    [ "$(tree_of "$LOGS/$E")" = "$keep_e" ]
    [ "$(archive_files)" = "$files" ]
    grep -q '^unlink' "$CALLS"
    refute_rm
    # --none prunes the sessions directly in the log folder, and its PRUNED lies there.
    keep_acme=$(tree_of "$LOGS/acme")
    make_archive --none
    sum=$(sha_of "$LOGS/$E/SHA256SUMS")
    run_watched prune --none --archive "$ARCHIVE" --delete --confirm sessions
    [ "$status" -eq 0 ]
    [ "$stderr" = "tlogger: removed 1 session of $SHOWN, as $SHOWN/PRUNED records" ]
    [ "$(stat -c %a "$LOGS/PRUNED")" = 600 ]
    mapfile -t lines < "$LOGS/PRUNED"
    [ "${#lines[@]}" -eq 1 ]
    assert_pruned_line "${lines[0]}" "$E" "$sum"
    [ "$output" = "$E  remove"$'\n'"$(stays_line "$SHOWN")"$'\n'"${lines[0]}" ]
    [[ ! -e $LOGS/$E && ! -L $LOGS/$E ]]
    [ "$(tree_of "$LOGS/acme")" = "$keep_acme" ]
    [ "$(tree_of "$LOGS/demo")" = "$keep_demo" ]
    refute_rm
}

@test "prune keeps every session when one would be kept, and names the reason for each" {
    need modes
    need symlinks
    need hardlinks
    need python3
    local i plan before
    local -a s
    for (( i = 1; i <= 15; i++ )); do
        s[i]=$(printf '20261112T%02d0000Z-sess%02d' "$i" "$i")
    done
    sealed_engagement acme "${s[1]}" "${s[2]}" "${s[3]}" "${s[4]}" "${s[5]}" "${s[6]}" \
        "${s[7]}" "${s[8]}" "${s[9]}" "${s[10]}" "${s[14]}"
    make_archive acme
    mkdir -m 700 "$HOME/elsewhere" "$HOME/old"
    # Sealed after the archive was made: not in it.
    make_session "acme/${s[11]}"
    run_tlogger seal "${s[11]}"
    [ "$status" -eq 0 ]
    # Moved away, and sealed again under its id with other logs: the archive has the old sum.
    # seal refuses a second MANIFEST line for one id, so the line is added by hand, as for a
    # session sealed again elsewhere and copied back with its line.
    mv "$LOGS/acme/${s[14]}" "$HOME/old/${s[14]}"
    make_session "acme/${s[14]}" 3
    run_tlogger seal "${s[14]}"
    [ "$status" -eq 1 ]
    printf '%s  %s/SHA256SUMS\n' "$(sha_of "$LOGS/acme/${s[14]}/SHA256SUMS")" "${s[14]}" \
        >> "$LOGS/acme/MANIFEST"
    # Ended unsealed, its recorder 4343 gone; still recorded by 4242; without a recorder file.
    REC_PID=4343 make_session "acme/${s[12]}"
    make_session "acme/${s[13]}"
    make_session "acme/${s[15]}"
    rm "$LOGS/acme/${s[15]}/recorder"
    fake_process "$REC_PID" "$REC_START"
    # A changed log, a symlinked log, a log with a second hard link, a symlinked transcript, a
    # temp file of render, a file the seal does not cover, a folder of mode 0500, a folder its
    # group may write, and a session folder that is a symlink.
    flip_byte "$LOGS/acme/${s[2]}/output.raw"
    mv "$LOGS/acme/${s[3]}/commands.tsv" "$HOME/elsewhere/commands.tsv"
    ln -s "$HOME/elsewhere/commands.tsv" "$LOGS/acme/${s[3]}/commands.tsv"
    ln "$LOGS/acme/${s[4]}/output.raw" "$HOME/elsewhere/output.raw"
    printf 'derived\n' > "$HOME/elsewhere/transcript.txt"
    ln -s "$HOME/elsewhere/transcript.txt" "$LOGS/acme/${s[5]}/transcript.txt"
    printf 'part\n' > "$LOGS/acme/${s[6]}/transcript.txt.part"
    printf 'note\n' > "$LOGS/acme/${s[7]}/notes.txt"
    chmod 500 "$LOGS/acme/${s[8]}"
    chmod 770 "$LOGS/acme/${s[9]}"
    mv "$LOGS/acme/${s[10]}" "$HOME/elsewhere/${s[10]}"
    ln -s "$HOME/elsewhere/${s[10]}" "$LOGS/acme/${s[10]}"
    plan=$(
        printf '%s  remove\n' "${s[1]}"
        printf '%s  keep: changed\n' "${s[2]}" "${s[3]}"
        printf '%s  keep: output.raw has more than one hard link\n' "${s[4]}"
        printf '%s  keep: transcript.txt is a symlink, which tlogger does not follow\n' "${s[5]}"
        printf '%s  keep: it holds transcript.txt.part, which the seal does not cover\n' "${s[6]}"
        printf '%s  keep: changed\n' "${s[7]}"
        printf '%s  keep: its folder has mode 500, so you cannot remove its files\n' "${s[8]}"
        printf '%s  keep: its folder is writable by its group or by others\n' "${s[9]}"
        printf '%s  keep: its folder is a symlink, which tlogger does not follow\n' "${s[10]}"
        printf '%s  keep: not in the archive\n' "${s[11]}"
        printf '%s  keep: unsealed\n' "${s[12]}"
        printf '%s  keep: recording\n' "${s[13]}"
        printf '%s  keep: the archive holds it with another sum\n' "${s[14]}"
        printf '%s  keep: unknown\n' "${s[15]}"
        stays_line "$SHOWN/acme"
    )
    make_stand_ins
    before=$(tree_of "$HOME")
    run_watched prune acme --archive "$ARCHIVE"
    assert_kept "$plan" "${s[2]}" "${s[3]}" "${s[7]}"
    [ "$(tree_of "$HOME")" = "$before" ]
    # With --delete and the right name it is refused all the same: nothing is removed, no mode
    # changes, no PRUNED is made, and no symlink's target is touched.
    run_watched prune acme --archive "$ARCHIVE" --delete --confirm acme
    assert_kept "$plan" "${s[2]}" "${s[3]}" "${s[7]}"
    [ "$(tree_of "$HOME")" = "$before" ]
    [ ! -e "$LOGS/acme/PRUNED" ]
    refute_removed
}

@test "prune refuses the whole run for a bad archive, folder, mount or PRUNED, removing nothing" {
    need modes
    need symlinks
    need python3
    local good demo demo_shown state want
    sealed_engagement acme "$A" "$B"
    sealed_engagement demo "$C"
    make_archive demo
    demo=$ARCHIVE demo_shown=$SHOWN_ARCHIVE
    make_archive acme
    good=$ARCHIVE
    # A copy of acme with a changed log, packed under the name acme by another tar writer.
    copy_case bad
    tamper flipped
    "$PYTHON3" -I "$TARTOOL" pack "$KEPT" acme "$HOME/cases/bad.tar.gz"
    mkdir -m 700 "$HOME/elsewhere"
    make_stand_ins
    state=$(tree_of "$LOGS/acme/$A"; tree_of "$LOGS/acme/$B"; sha_of "$LOGS/acme/MANIFEST"
        archive_files)
    run_watched prune acme --archive "$HOME/cases/bad.tar.gz" --delete --confirm acme
    want='tlogger: the archive ~/cases/bad.tar.gz fails its check; tlogger archive --verify'
    assert_refused 1 "$want ~/cases/bad.tar.gz says why"
    run_watched prune acme --archive "$demo" --delete --confirm acme
    want="tlogger: the archive $demo_shown is not of $SHOWN/acme: it holds the folder demo"
    assert_refused 1 "$want"
    run_watched prune acme --archive "$HOME/nope.tar.gz" --delete --confirm acme
    assert_refused 1 'tlogger: ~/nope.tar.gz does not exist'
    TLOGGER_PYTHON=$HOME/missing run_watched prune acme --archive "$good" --delete --confirm acme
    assert_refused 1 'tlogger: prune needs python3'
    # A log folder or an engagement folder that others may write in, sticky bit or not.
    chmod 1777 "$LOGS"
    run_watched prune acme --archive "$good" --delete --confirm acme
    assert_refused 1 "$(open_msg 'the log folder' "$SHOWN")"
    chmod 700 "$LOGS"
    chmod 770 "$LOGS/acme"
    run_watched prune acme --archive "$good" --delete --confirm acme
    assert_refused 1 "$(open_msg 'the engagement folder' "$SHOWN/acme")"
    chmod 700 "$LOGS/acme"
    # A PRUNED that is a symlink, whose target stays as it is, or that is not a file.
    printf 'kept\n' > "$HOME/elsewhere/PRUNED"
    ln -s "$HOME/elsewhere/PRUNED" "$LOGS/acme/PRUNED"
    run_watched prune acme --archive "$good" --delete --confirm acme
    assert_refused 1 "tlogger: $SHOWN/acme/PRUNED is a symlink, which tlogger does not follow"
    [ "$(cat "$HOME/elsewhere/PRUNED")" = kept ]
    rm "$LOGS/acme/PRUNED"
    mkdir -m 700 "$LOGS/acme/PRUNED"
    run_watched prune acme --archive "$good" --delete --confirm acme
    assert_refused 1 "tlogger: $SHOWN/acme/PRUNED is not a regular file"
    rmdir "$LOGS/acme/PRUNED"
    # logdir_mount names a volume that is not mounted.
    mount_row /
    write_config "logdir_mount=$HOME/.local/state"$'\n'
    run_watched prune acme --archive "$good" --delete --confirm acme
    assert_refused 1 'tlogger: the volume ~/.local/state of the log folder is not mounted'
    write_config ''
    # A PRUNED that cannot be written: the plan comes, then nothing of the first session goes.
    : > "$LOGS/acme/PRUNED"
    chmod 400 "$LOGS/acme/PRUNED"
    run_watched prune acme --archive "$good" --delete --confirm acme
    [ "$status" -eq 1 ]
    [ "$output" = "$(printf '%s  remove\n' "$A" "$B"; stays_line "$SHOWN/acme")" ]
    [ "$(last_stderr_line)" = \
        "tlogger: cannot write $SHOWN/acme/PRUNED; nothing of session $A was removed" ]
    [ ! -s "$LOGS/acme/PRUNED" ]
    [ "$(tree_of "$LOGS/acme/$A"; tree_of "$LOGS/acme/$B"; sha_of "$LOGS/acme/MANIFEST"
        archive_files)" = "$state" ]
    refute_removed
}

@test "prune --none refuses an archive of the engagement named like the log folder" {
    need modes
    need python3
    local before want
    # The engagement sessions and the log folder ~/.local/state/tlogger/sessions share a name.
    sealed_engagement sessions "$A"
    make_session "$B"
    run_tlogger seal --all
    [ "$status" -eq 0 ]
    make_archive sessions
    make_stand_ins
    before=$(tree_of "$HOME")
    run_watched prune --none --archive "$ARCHIVE" --delete --confirm sessions
    want="tlogger: the archive $SHOWN_ARCHIVE is not of $SHOWN: its MANIFEST is not the start of"
    assert_refused 1 "$want $SHOWN/MANIFEST"
    [ "$(tree_of "$HOME")" = "$before" ]
    # The engagement whose archive it is may be pruned with it.
    run_watched prune sessions --archive "$ARCHIVE"
    [ "$status" -eq 0 ]
    [ "$output" = "$A  remove"$'\n'"$(stays_line "$SHOWN/sessions")" ]
    [ "$(tree_of "$HOME")" = "$before" ]
    refute_removed
}

@test "a prune cut short is changed for verify --all, and the same prune again finishes it" {
    need modes
    need python3
    local sum_a sum_b first second plan want first_line want_b before
    local -a lines
    sealed_engagement acme "$A" "$B"
    printf 'derived\n' > "$LOGS/acme/$A/transcript.txt"
    make_archive acme
    make_stand_ins
    cp "$LOGS/acme/MANIFEST" "$BATS_TEST_TMPDIR/manifest"
    sum_a=$(sha_of "$LOGS/acme/$A/SHA256SUMS")
    sum_b=$(sha_of "$LOGS/acme/$B/SHA256SUMS")
    first=$(sed -n 1p "$LOGS/acme/$A/SHA256SUMS" | cut -c67-)
    second=$(sed -n 2p "$LOGS/acme/$A/SHA256SUMS" | cut -c67-)
    want_b=$(removal_order "$LOGS/acme/$B")
    before=$(tree_of "$LOGS/acme/$B")
    # The second log of A cannot be removed, as if it were immutable.
    UNLINK_FAIL=$(readlink -f -- "$LOGS/acme/$A/$second")
    plan=$(printf '%s  remove\n' "$A" "$B"; stays_line "$SHOWN/acme")
    run_watched prune acme --archive "$ARCHIVE" --delete --confirm acme
    [ "$status" -eq 1 ]
    want="tlogger: cannot remove $SHOWN/acme/$A/$second; session $A is cut short and the"
    want+=" sessions after it stay; run the same prune again once that is fixed"
    [ "$(last_stderr_line)" = "$want" ]
    # The PRUNED line of A was written, and printed, before anything was removed.
    mapfile -t lines < "$LOGS/acme/PRUNED"
    [ "${#lines[@]}" -eq 1 ]
    assert_pruned_line "${lines[0]}" "$A" "$sum_a"
    first_line=${lines[0]}
    [ "$output" = "$plan"$'\n'"$first_line" ]
    # Only the first log of A is gone; B was not reached.
    [ "$(grep -F "/$A/" "$CALLS" | cut -f 2)" = \
        "$(readlink -f -- "$LOGS/acme/$A/$first")"$'\n'"$UNLINK_FAIL" ]
    run grep -F "/$B/" "$CALLS"
    [ "$status" -eq 1 ]
    [[ ! -e $LOGS/acme/$A/$first ]]
    [ -f "$LOGS/acme/$A/$second" ]
    [ -f "$LOGS/acme/$A/transcript.txt" ]
    [ -f "$LOGS/acme/$A/SHA256SUMS" ]
    [ -f "$LOGS/acme/$A/SEAL" ]
    [ "$(tree_of "$LOGS/acme/$B")" = "$before" ]
    refute_rm
    # A can never look unsealed: verify --all calls it changed, and says how to finish it.
    run_tlogger verify --all
    [ "$status" -eq 1 ]
    grep -Fxq "$A  changed" <<< "$output"
    grep -Fxq "$B  ok" <<< "$output"
    assert_stderr_line "tlogger: $A: a prune was cut short; run the same prune again"
    # The same prune again shows A to finish, then finishes it and removes B.
    UNLINK_FAIL=
    : > "$CALLS"
    plan=$(printf '%s  finish\n%s  remove\n' "$A" "$B"; stays_line "$SHOWN/acme")
    run_watched prune acme --archive "$ARCHIVE"
    [ "$status" -eq 0 ]
    [ "$output" = "$plan" ]
    [ "$(last_stderr_line)" = "$DRY_RUN" ]
    run_watched prune acme --archive "$ARCHIVE" --delete --confirm acme
    [ "$status" -eq 0 ]
    [ "$(last_stderr_line)" = \
        "tlogger: removed 2 sessions of $SHOWN/acme, as $SHOWN/acme/PRUNED records" ]
    # A finish adds no line to PRUNED: it prints the one written first.
    mapfile -t lines < "$LOGS/acme/PRUNED"
    [ "${#lines[@]}" -eq 2 ]
    [ "${lines[0]}" = "$first_line" ]
    assert_pruned_line "${lines[1]}" "$B" "$sum_b"
    [ "$output" = "$plan"$'\n'"${lines[0]}"$'\n'"${lines[1]}" ]
    [[ ! -e $LOGS/acme/$A && ! -L $LOGS/acme/$A ]]
    [[ ! -e $LOGS/acme/$B && ! -L $LOGS/acme/$B ]]
    # B's files went one by one, in the order of its SHA256SUMS, with SEAL last.
    [ "$(grep -F "/$B/" "$CALLS" | cut -f 2)" = "$want_b" ]
    cmp "$LOGS/acme/MANIFEST" "$BATS_TEST_TMPDIR/manifest"
    [ -d "$LOGS/acme" ]
    refute_rm
    run_tlogger verify --all
    [ "$status" -eq 0 ]
    [ "$(LC_ALL=C sort <<< "$output")" = "$A  pruned"$'\n'"$B  pruned" ]
}

@test "a prune stopped before its first removal leaves the session ok for the next one" {
    need modes
    need python3
    local sum_a first want
    local -a lines
    sealed_engagement acme "$A"
    make_archive acme
    make_stand_ins
    sum_a=$(sha_of "$LOGS/acme/$A/SHA256SUMS")
    first=$(sed -n 1p "$LOGS/acme/$A/SHA256SUMS" | cut -c67-)
    # PRUNED cannot be flushed to the disk: its line stays, and nothing is removed.
    printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$STAND_INS/sync"
    chmod 755 "$STAND_INS/sync"
    run_watched prune acme --archive "$ARCHIVE" --delete --confirm acme
    [ "$status" -eq 1 ]
    want="tlogger: cannot flush $SHOWN/acme/PRUNED to the disk; it holds the line of session $A,"
    want+=" but nothing of it was removed; run the same prune again"
    [ "$(last_stderr_line)" = "$want" ]
    refute_removed
    rm -f -- "$STAND_INS/sync"
    mapfile -t lines < "$LOGS/acme/PRUNED"
    [ "${#lines[@]}" -eq 1 ]
    assert_pruned_line "${lines[0]}" "$A" "$sum_a"
    # Its first log cannot be removed either: the session stays whole, with a second line.
    UNLINK_FAIL=$(readlink -f -- "$LOGS/acme/$A/$first")
    run_watched prune acme --archive "$ARCHIVE" --delete --confirm acme
    [ "$status" -eq 1 ]
    [ -f "$LOGS/acme/$A/$first" ]
    # A whole session is ok, with no hint: it may as well have been put back on purpose.
    run_tlogger verify --all
    [ "$status" -eq 0 ]
    [ "$output" = "$A  ok" ]
    [ -z "$stderr" ]
    # The next prune removes it as any other, and records it once more.
    UNLINK_FAIL=
    run_watched prune acme --archive "$ARCHIVE" --delete --confirm acme
    [ "$status" -eq 0 ]
    mapfile -t lines < "$LOGS/acme/PRUNED"
    [ "${#lines[@]}" -eq 3 ]
    assert_pruned_line "${lines[2]}" "$A" "$sum_a"
    [ "$output" = "$A  remove"$'\n'"$(stays_line "$SHOWN/acme")"$'\n'"${lines[2]}" ]
    [[ ! -e $LOGS/acme/$A && ! -L $LOGS/acme/$A ]]
    refute_rm
    run_tlogger verify --all
    [ "$status" -eq 0 ]
    [ "$output" = "$A  pruned" ]
}

@test "prune refuses an archive file name with a space, and archive never makes one" {
    need modes
    need python3
    local before want
    sealed_engagement acme "$A"
    make_archive acme
    cp -p -- "$ARCHIVE" "$HOME/acme copy.tar.gz"
    make_stand_ins
    before=$(tree_of "$LOGS")
    run_watched prune acme --archive "$HOME/acme copy.tar.gz" --delete --confirm acme
    want='tlogger: the file name of the archive ~/acme copy.tar.gz holds a space or a control'
    assert_refused 1 "$want character; rename it"
    [ "$(tree_of "$LOGS")" = "$before" ]
    refute_removed
    # archive --none never makes such a name: a log folder named with a space is refused.
    mkdir -m 700 "$HOME/case logs"
    make_session "$HOME/case logs/$B"
    write_config "logdir=$HOME/case logs"$'\n'
    run_tlogger seal --all
    [ "$status" -eq 0 ]
    before=$(tree_of "$HOME/case logs")
    run_tlogger archive --none
    want='tlogger: the name of the log folder ~/case logs holds a space or a control character,'
    assert_refused 1 "$want which an archive's name cannot hold; use an engagement folder"
    [ "$(tree_of "$HOME/case logs")" = "$before" ]
    # prune --none checks the folder the same way, before it reads FILE.
    run_tlogger prune --none --archive "$ARCHIVE"
    assert_refused 1 "$want which an archive's name cannot hold; use an engagement folder"
    [ "$(tree_of "$HOME/case logs")" = "$before" ]
}

@test "archive --verify compares with a folder tied to the archive, never with an unrelated one" {
    need modes
    need symlinks
    need python3
    sealed_engagement acme "$A"
    make_archive acme
    run_tlogger prune acme --archive "$ARCHIVE" --delete --confirm acme
    [ "$status" -eq 0 ]
    run_tlogger archive --verify "$ARCHIVE"
    [ "$status" -eq 0 ]
    [ "$output" = "$A  ok" ]
    # PRUNED still records A, so an emptied or removed MANIFEST of acme is compared, and fails.
    : > "$LOGS/acme/MANIFEST"
    run_tlogger archive --verify "$ARCHIVE"
    [ "$status" -eq 1 ]
    [ "$output" = "$A  changed" ]
    assert_stderr_line \
        "tlogger: ${ARCHIVE##*/}: its MANIFEST is not the start of $SHOWN/acme/MANIFEST"
    rm -f -- "$LOGS/acme/MANIFEST"
    run_tlogger archive --verify "$ARCHIVE"
    [ "$status" -eq 1 ]
    [ "$output" = "$A  changed" ]
    # A PRUNED that cannot be read, here a symlink, hides no tie: it fails as well.
    mv "$LOGS/acme/PRUNED" "$HOME/pruned"
    ln -s "$HOME/pruned" "$LOGS/acme/PRUNED"
    run_tlogger archive --verify "$ARCHIVE"
    [ "$status" -eq 1 ]
    [ "$output" = "$A  changed" ]
    [[ $stderr == *"tlogger: ${ARCHIVE##*/}: cannot read $SHOWN/acme/PRUNED: "* ]]
    rm -f -- "$LOGS/acme/PRUNED"
    mv "$HOME/pruned" "$LOGS/acme/PRUNED"
    # A folder acme with no tie to the archive, as on another computer, is passed over.
    mv "$LOGS/acme" "$HOME/old-acme"
    sealed_engagement acme "$B"
    run_tlogger archive --verify "$ARCHIVE"
    [ "$status" -eq 0 ]
    [ "$output" = "$A  ok" ]
}

@test "an archive --none passes its checks when an engagement shares the log folder's name" {
    need modes
    need python3
    sealed_engagement sessions "$A"
    make_session "$B"
    run_tlogger seal --all
    [ "$status" -eq 0 ]
    make_archive --none
    run_tlogger archive --verify "$ARCHIVE"
    [ "$status" -eq 0 ]
    [ "$output" = "$B  ok" ]
    make_stand_ins
    run_watched prune --none --archive "$ARCHIVE"
    [ "$status" -eq 0 ]
    [ "$output" = "$B  remove"$'\n'"$(stays_line "$SHOWN")" ]
    [ "$(last_stderr_line)" = "$DRY_RUN" ]
    refute_removed
}

@test "prune --delete needs --confirm off a terminal, and a wrong name changes nothing" {
    need modes
    need python3
    local before plan name
    sealed_engagement acme "$A" "$B"
    make_archive acme
    make_stand_ins
    before=$(tree_of "$HOME")
    run_watched prune acme --archive "$ARCHIVE" --delete
    assert_refused 2 'tlogger: --confirm is required with --delete when not run from a terminal'
    plan=$(printf '%s  remove\n' "$A" "$B"; stays_line "$SHOWN/acme")
    for name in ACME 'acme ' acm sessions "$SHOWN/acme"; do
        run_watched prune acme --archive "$ARCHIVE" --delete --confirm "$name"
        [ "$status" -eq 1 ]
        [ "$output" = "$plan" ]
        [ "$stderr" = 'tlogger: nothing changed' ]
    done
    run_watched prune acme --archive="$ARCHIVE" --delete --confirm=acm
    [ "$status" -eq 1 ]
    [ "$stderr" = 'tlogger: nothing changed' ]
    [ "$(tree_of "$HOME")" = "$before" ]
    refute_removed
}

@test "on a terminal, prune --delete asks for the folder's name, and only that name removes" {
    need modes
    need python3
    need zsh
    need zpty
    local before
    local -a lines
    sealed_engagement acme "$A" "$B"
    make_archive acme
    cp "$REPO_ROOT/tests/fixtures/e2e-zshrc" "$HOME/.zshrc"
    export TLOGGER ARCHIVE
    # shellcheck disable=SC2034 # drive reads it.
    SCREEN="$BATS_TEST_TMPDIR/screen"
    before=$(tree_of "$LOGS")
    # zsh expands these, not bash.
    # shellcheck disable=SC2016
    drive << 'DRIVER'
pty_shell "TLOGGER=$TLOGGER" "TLOGGER_PROC=$TLOGGER_PROC" "TLOGGER_PYTHON=$TLOGGER_PYTHON" \
    "TMPDIR=$TMPDIR" "F=$ARCHIVE"
pty_begin 'bash "$TLOGGER" prune acme --archive "$F" --delete'
frame=$REPLY
pty_expect "tlogger: this cannot be undone; type the folder's name, acme, to go ahead: "
pty_send ACME
pty_end $frame
(( PTY_STATUS == 1 )) || pty_fail "a wrong name made prune return $PTY_STATUS"
pty_out_has 'tlogger: nothing changed' || pty_fail "a wrong name printed ${(V)PTY_OUT}"
pty_close
DRIVER
    [ "$(tree_of "$LOGS")" = "$before" ]
    # shellcheck disable=SC2016
    drive << 'DRIVER'
pty_shell "TLOGGER=$TLOGGER" "TLOGGER_PROC=$TLOGGER_PROC" "TLOGGER_PYTHON=$TLOGGER_PYTHON" \
    "TMPDIR=$TMPDIR" "F=$ARCHIVE"
pty_begin 'bash "$TLOGGER" prune acme --archive "$F" --delete'
frame=$REPLY
pty_expect "tlogger: this cannot be undone; type the folder's name, acme, to go ahead: "
pty_send acme
pty_end $frame
(( PTY_STATUS == 0 )) || pty_fail "the right name made prune return $PTY_STATUS"
pty_out_has 'tlogger: removed 2 sessions of ~/.local/state/tlogger/sessions/acme, as' ||
    pty_fail "the right name printed ${(V)PTY_OUT}"
pty_close
DRIVER
    [[ ! -e $LOGS/acme/$A && ! -e $LOGS/acme/$B ]]
    mapfile -t lines < "$LOGS/acme/PRUNED"
    [ "${#lines[@]}" -eq 2 ]
}

@test "prune exits 3 without a session to prune, and 1 for an engagement folder not there" {
    need modes
    local before
    sealed_engagement acme "$A"
    mkdir -m 700 "$LOGS/demo"
    before=$(tree_of "$LOGS")
    # These come before the archive is read: FILE need not exist.
    run_tlogger prune demo --archive "$HOME/none.tar.gz" --delete --confirm demo
    assert_refused 3 "tlogger: no session to prune in $SHOWN/demo"
    run_tlogger prune acme --archive "$HOME/none.tar.gz" --older-than 100000
    assert_refused 3 "tlogger: no session to prune in $SHOWN/acme"
    run_tlogger prune --none --archive "$HOME/none.tar.gz"
    assert_refused 3 "tlogger: no session to prune in $SHOWN"
    run_tlogger prune nosuch --archive "$HOME/none.tar.gz"
    assert_refused 1 "tlogger: there is no engagement folder nosuch in $SHOWN"
    [ "$(tree_of "$LOGS")" = "$before" ]
}

@test "prune without a folder is a usage error, and never takes the config's engagement" {
    local before
    mkdir -p "$LOGS/acme"
    chmod 700 "$LOGS/acme"
    make_session "acme/$A"
    write_config $'engagement=acme\n'
    before=$(tree_of "$LOGS")
    run_tlogger prune --archive "$HOME/a.tar.gz" --delete --confirm acme
    assert_usage_error 'tlogger: prune needs an engagement or --none'
    run_tlogger prune --archive "$HOME/a.tar.gz"
    assert_usage_error 'tlogger: prune needs an engagement or --none'
    run_tlogger prune
    assert_usage_error 'tlogger: prune needs an engagement or --none'
    [ "$(tree_of "$LOGS")" = "$before" ]
}

@test "prune refuses wrong arguments with a usage error, and prints its help" {
    local value
    run_tlogger prune acme --none --archive "$HOME/a.tar.gz"
    assert_usage_error 'tlogger: prune takes an engagement or --none, not both'
    run_tlogger prune acme demo --archive "$HOME/a.tar.gz"
    assert_usage_error 'tlogger: prune takes one engagement at most'
    for value in --force --verify --all -y; do
        run_tlogger prune acme --archive "$HOME/a.tar.gz" "$value"
        assert_usage_error "tlogger: unknown option for prune: $value"
    done
    run_tlogger prune acme
    assert_usage_error 'tlogger: prune needs --archive FILE'
    run_tlogger prune acme --delete --confirm acme
    assert_usage_error 'tlogger: prune needs --archive FILE'
    run_tlogger prune acme --archive
    assert_usage_error 'tlogger: --archive needs a file'
    run_tlogger prune acme --archive "$HOME/a.tar.gz" --delete --confirm
    assert_usage_error "tlogger: --confirm needs a value: the folder's name"
    run_tlogger prune acme --archive "$HOME/a.tar.gz" --confirm acme
    assert_usage_error 'tlogger: --confirm needs --delete'
    run_tlogger prune acme --archive "$HOME/a.tar.gz" --older-than
    assert_usage_error 'tlogger: --older-than needs a value: a whole number of days'
    for value in x -1 1.5 '' 3d; do
        run_tlogger prune acme --archive "$HOME/a.tar.gz" --older-than "$value"
        assert_usage_error "tlogger: --older-than takes a whole number of days, not '$value'"
    done
    for value in 'bad name' MANIFEST PRUNED "$A" .archive; do
        run_tlogger prune "$value" --archive "$HOME/a.tar.gz"
        [ "$status" -eq 2 ]
        [ -z "$output" ]
        [[ ${stderr_lines[0]} == "tlogger: '$value' is not a valid engagement name; "* ]]
    done
    # Off a terminal, --delete without --confirm stops before any folder is looked at: acme does
    # not exist here.
    run_tlogger prune acme --archive "$HOME/a.tar.gz" --delete
    assert_refused 2 'tlogger: --confirm is required with --delete when not run from a terminal'
    [ -z "$(ls -A "$LOGS")" ]
    run_tlogger prune --help
    [ "$status" -eq 0 ]
    [[ $output == 'Usage: tlogger <command> [options]'* ]]
}
