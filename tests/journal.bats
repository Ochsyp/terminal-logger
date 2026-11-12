#!/usr/bin/env bats
# shellcheck disable=SC2016 # The tests hand zsh code to zsh in single quotes; zsh expands it.
# Unit tests of the command journal, the UTC stamps, the VPN list and the prompt segment, in a real
# zsh without a terminal: the hooks run as calls under zsh -f -i -c, or as zsh runs them in a shell
# that reads its commands on stdin. A fake /proc (tests/helpers/fakeproc.zsh) sets the terminal's
# state; a fake sysfs and tests/stub-bin/tlogger-test-ip set the VPN list. They need a real zsh.

bats_require_minimum_version 1.5.0

load helpers

# The fake process trees, as zsh code for fakeproc.zsh. REC_TREE: this shell is a nested shell on
# pts/1 (34817), which the recorder 9000001 records, so that it is REC but not the main shell and
# writes no exited marker. NOREC_TREE: this shell has no controlling terminal. EXT_TREE: another
# script process records this shell's terminal.
REC_TREE='fake_proc 9000001 script 9000000 34816 5000
    fake_proc 9000002 zsh 9000001 34817 5001
    fake_proc $$ zsh 9000002 34817 5002
    fake_session 9000001 5000 34817'
NOREC_TREE='fake_proc $$ zsh 9000000 0 5002'
EXT_TREE='fake_proc 9000020 script 9000019 34816 8000
    fake_proc $$ zsh 9000020 34819 8001'

# A UTC time as the journal, the stamp and the segment write it, as an extended regular expression.
UTC_RE='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'

# The VPN list that the stub ip gives for tun0 and wg0, and the same as a regular expression.
VPN='tun0 192.0.2.10 wg0 198.51.100.7'
VPN_RE='tun0 192\.0\.2\.10 wg0 198\.51\.100\.7'

# Run before each test by bats.
# Gives the test its own HOME and config folder, an empty folder for the fake /proc tree and an
# empty fake sysfs, which every shell reads. ip is missing unless a test names the stub, so that
# neither the interfaces nor the ip of the machine can reach a result.
setup() {
    isolate_home
    isolate_tlogger
    need zsh
    PROC="$BATS_TEST_TMPDIR/proc"
    SESSION="$BATS_TEST_TMPDIR/session"
    SYS="$BATS_TEST_TMPDIR/sys"
    WORK="$BATS_TEST_TMPDIR/work"
    CONFIG="$HOME/.config/tlogger/config"
    mkdir -p "$PROC" "$WORK" "${CONFIG%/*}"
    fake_sysfs "$SYS"
    export TLOGGER_SYSFS="$SYS" TLOGGER_IP="$BATS_TEST_TMPDIR/no-ip"
    export TLOGGER_TEST_IP_LOG="$BATS_TEST_TMPDIR/ip-runs"
}

# Run zsh -f -i -c through bats `run --separate-stderr` with TLOGGER_PROC set to the fake tree:
# load fakeproc.zsh, run the zsh code TREE, which builds the tree, source the plugin from the work
# tree and run the zsh code CODE. zsh -c runs no hook by itself, so CODE calls the hooks; $? at a
# call of _tlogger_precmd is the status of the command before it, as zsh hands it to the hook.
# timeout kills a zsh that still runs after 60 seconds, so that a hook that hangs fails its test
# instead of holding up the suite; --foreground leaves zsh in the process group of bats.
run_hooks() {
    run --separate-stderr timeout --foreground -s KILL 60 zsh -f -i -c '
        TLOGGER_PROC=$1
        source $2 || exit 1
        eval $3 || exit 1
        source $4
        eval $5' zsh "$PROC" "$REPO_ROOT/tests/helpers/fakeproc.zsh" "$1" \
        "$REPO_ROOT/lib/tlogger.zsh" "$2" < /dev/null
}

# Fail unless the last run exited 0, wrote nothing on stderr and printed, for the epochs 0,
# 951782400 and 4107542400, each epoch and date -u's time for it, then the line LAST. ZONE names
# the time zone in the report.
assert_utc_run() {
    local want e
    want=$(for e in 0 951782400 4107542400; do
        printf '%s %s\n' "$e" "$(date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ)"
    done
    printf '%s\n' "$2")
    if [[ $status -ne 0 || $output != "$want" || -n $stderr ]]; then
        printf 'TZ %s: expected\n%s\ngot, with exit %s:\n%s\nstderr:\n%s\n' \
            "$1" "$want" "$status" "$output" "$stderr" >&2
        return 1
    fi
}

@test "_tlogger_utc writes date -u's time for 1970, a leap day and 2100, whatever the local TZ" {
    local tz
    # date itself must give these, so that a broken date cannot hide a broken plugin.
    [ "$(date -u -d @0 +%Y-%m-%dT%H:%M:%SZ)" = 1970-01-01T00:00:00Z ]
    [ "$(date -u -d @951782400 +%Y-%m-%dT%H:%M:%SZ)" = 2000-02-29T00:00:00Z ]
    [ "$(date -u -d @4107542400 +%Y-%m-%dT%H:%M:%SZ)" = 2100-03-01T00:00:00Z ]
    # POSIX TZ strings, which need no tzdata: UTC, Central Europe and New Zealand with their
    # summer times, the US east coast and a half-hour offset. The last line shows that the
    # shell's own TZ and local time stay as they were.
    for tz in UTC0 'CET-1CEST,M3.5.0,M10.5.0/3' 'NZST-12NZDT,M9.5.0,M4.1.0/3' \
        'EST5EDT,M3.2.0,M11.1.0' 'IST-5:30'; do
        TZ=$tz run_hooks "$NOREC_TREE" '
            for e in 0 951782400 4107542400; do
                _tlogger_utc out %Y-%m-%dT%H:%M:%SZ $e
                print -r -- "$e $out"
            done
            strftime -s here %H:%M 0
            print -r -- "${TZ-unset} ${(t)TZ} $here"'
        assert_utc_run "$tz" "$tz scalar-export $(TZ=$tz date -d @0 +%H:%M)"
    done
    unset TZ
    run_hooks "$NOREC_TREE" '
        for e in 0 951782400 4107542400; do
            _tlogger_utc out %Y-%m-%dT%H:%M:%SZ $e
            print -r -- "$e $out"
        done
        strftime -s here %H:%M 0
        print -r -- "${TZ-unset} ${(t)TZ} $here"'
    assert_utc_run unset "unset  $(date -d @0 +%H:%M)"
}

@test "preexec appends the S line and precmd the E line: epoch, UTC, pid, folder, VPN, typed text, status" {
    need modes
    local pid
    local -a rows
    local -i s_epoch
    fake_sysfs "$SYS" lo=1 eth0=2 tun0=5 wg0=6
    # REC through the fake /proc. The second preexec has no typed text, as when history is off,
    # and the last precmd follows no command, as after an empty line.
    TLOGGER_IP=$STUB_IP run_hooks "$REC_TREE" '
        cd /
        _tlogger_preexec "ls -la" "ls -la" "ls -la"
        (exit 3)
        _tlogger_precmd
        _tlogger_preexec "" "print -r" "print -r -- full text"
        true
        _tlogger_precmd
        _tlogger_precmd
        print -r -- $$'
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    pid=$output
    mapfile -t rows < "$SESSION/commands.tsv"
    [ "${#rows[@]}" -eq 4 ]
    assert_s_line "${rows[0]}" "$pid" / "$VPN" "'ls -la'"
    s_epoch=${FIELDS[1]}
    assert_e_line "${rows[1]}" "$pid" 3
    (( FIELDS[1] >= s_epoch ))
    assert_s_line "${rows[2]}" "$pid" / "$VPN" "'print -r -- full text'"
    assert_e_line "${rows[3]}" "$pid" 0
    [ "$(stat -c %a "$SESSION/commands.tsv")" = 600 ]
}

@test "a tab or a newline in the folder or the typed text stays inside its S line, quoted as (q+) does" {
    # REC through the fake /proc. zsh reads the two fields back with eval, which turns the
    # quoting back into the text; the $(id) in the typed text never runs.
    J_DIR=$'tab\there\nnext' J_TYPED=$'print -r -- "a\tb" $(id)\nprint -r -- it\'s' \
        run_hooks "$REC_TREE" '
        mkdir -p -- ${TLOGGER_PROC:h}/$J_DIR && cd -- ${TLOGGER_PROC:h}/$J_DIR || exit 1
        _tlogger_preexec $J_TYPED "print -r" $J_TYPED
        line=$(<$TLOGGER_SESSION/commands.tsv)
        f=("${(@ps:\t:)line}")
        eval "dir_back=$f[5] typed_back=$f[7]"
        print -r -- "fields: $#f"
        [[ $dir_back == "$PWD" ]] && print -r -- "folder read back"
        [[ $typed_back == "$J_TYPED" ]] && print -r -- "typed text read back"'
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    [ "$output" = $'fields: 7\nfolder read back\ntyped text read back' ]
    # One line, whose only tabs are the 6 between its fields; both fields take the $'...' form.
    [ "$(wc -l < "$SESSION/commands.tsv")" -eq 1 ]
    [ "$(tr -cd '\t' < "$SESSION/commands.tsv" | wc -c)" -eq 6 ]
    split_tabs "$(cat "$SESSION/commands.tsv")"
    [[ ${FIELDS[4]} == "\$'"*"'" && ${FIELDS[6]} == "\$'"*"'" ]]
    [[ ${FIELDS[6]} == *'\t'*'\n'* ]]
}

@test "precmd reads the status of the user's command, not that of a precmd() that runs before it" {
    local script="$BATS_TEST_TMPDIR/commands.zsh" row
    local -a rows
    # One command per line, as a terminal sends them. precmd() ends with status 1, as Kali's can,
    # and zsh runs it before the hooks in precmd_functions. REC comes from the fake /proc.
    cat > "$script" << 'EOF'
TLOGGER_PROC=$J_PROC
source $J_FAKEPROC || exit 1
fake_proc 9000001 script 9000000 34816 5000; fake_proc 9000002 zsh 9000001 34817 5001
fake_proc $$ zsh 9000002 34817 5002; fake_session 9000001 5000 34817
precmd() { print -rn -- "${TERM_TITLE-}"; [[ -n ${TERM_TITLE-} ]]; }
source $J_PLUGIN
(exit 42)
(exit 7)
true
EOF
    # With -s, zsh reads the commands on stdin and runs the precmd hooks before each prompt, as
    # in a terminal, and callhookfunc (Src/utils.c) hands each one the status of the command. It
    # prints its prompts on stderr: PS1 from the environment makes them empty, and prompt=off
    # keeps the segment out of them. Without a terminal, as in CI, zsh writes to stderr what it
    # would write to one (init_shout, Src/init.c), the PROMPT_SP mark before each prompt included
    # (preprompt, Src/utils.c); +o promptsp turns that mark off.
    J_PROC=$PROC J_FAKEPROC="$REPO_ROOT/tests/helpers/fakeproc.zsh" \
        J_PLUGIN="$REPO_ROOT/lib/tlogger.zsh" TLOGGER_PROMPT=off PS1='' \
        run --separate-stderr zsh -f +o promptsp -i -s < "$script"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$stderr" ]
    mapfile -t rows < "$SESSION/commands.tsv"
    [ "${#rows[@]}" -eq 6 ]
    split_tabs "${rows[0]}"
    [[ ${FIELDS[0]} == S && ${FIELDS[6]} == *'exit 42'* ]]
    assert_e_line "${rows[1]}" "${FIELDS[3]}" 42
    assert_e_line "${rows[3]}" "${FIELDS[2]}" 7
    assert_e_line "${rows[5]}" "${FIELDS[2]}" 0
    for row in "${rows[2]}" "${rows[4]}"; do
        split_tabs "$row"
        [ "${FIELDS[0]}" = S ]
    done
}

@test "NOREC and EXT shells journal nothing, and no E line comes before a command or after an empty line" {
    # NOREC through the fake /proc: a TLOGGER_SESSION set after loading changes nothing, since
    # the hooks go by the state.
    run_hooks "$NOREC_TREE" '
        mkdir -p ${TLOGGER_PROC:h}/session
        export TLOGGER_SESSION=${TLOGGER_PROC:h}/session
        _tlogger_preexec ls ls ls
        false
        _tlogger_precmd
        print -r -- $_tlogger_state'
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    [ "$output" = NOREC ]
    [ ! -e "$SESSION/commands.tsv" ]
    # EXT: another script process records the terminal, and the session of tlogger's own that the
    # shell inherited is dropped as it loads.
    run_hooks "$EXT_TREE; fake_session 9000001 5000 34819" '
        _tlogger_preexec ls ls ls
        false
        _tlogger_precmd
        print -r -- "$_tlogger_state ${TLOGGER_SESSION-unset}"'
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    [ "$output" = 'EXT unset' ]
    [ ! -e "$SESSION/commands.tsv" ]
    # REC through the fake /proc: two prompts before the first command, then one command and the
    # prompts of two empty lines.
    run_hooks "$REC_TREE" '
        _tlogger_precmd
        _tlogger_precmd
        [[ -e $TLOGGER_SESSION/commands.tsv ]] && print -r -- "a line before any command"
        _tlogger_preexec ls ls ls
        false
        _tlogger_precmd
        _tlogger_precmd
        _tlogger_precmd
        print -r -- finished'
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    [ "$output" = finished ]
    [ "$(wc -l < "$SESSION/commands.tsv")" -eq 2 ]
    [ "$(grep -c '^E' "$SESSION/commands.tsv")" -eq 1 ]
}

@test "the hooks print nothing and go on when the session folder is missing or read-only" {
    need modes
    # Missing: REC forced after loading, with _tlogger_state=REC and TLOGGER_SESSION set by hand,
    # since the process walk does not count a session folder that does not exist. precmd then
    # finds the terminal recorded by a script process that is not tlogger's, EXT.
    run_hooks "$REC_TREE" '
        export TLOGGER_SESSION=${TLOGGER_PROC:h}/missing
        _tlogger_state=REC
        _tlogger_preexec ls ls ls
        false
        _tlogger_precmd
        print -r -- "done $_tlogger_state"'
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    [ "$output" = 'done EXT' ]
    [ ! -e "$BATS_TEST_TMPDIR/missing" ]
    # Read-only: the fake /proc keeps the shell REC, and the folder refuses the journal.
    run_hooks "$REC_TREE" '
        chmod 500 $TLOGGER_SESSION
        _tlogger_preexec ls ls ls
        false
        _tlogger_precmd
        print -r -- "done $_tlogger_state"
        chmod 700 $TLOGGER_SESSION'
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    [ "$output" = 'done REC' ]
    [ ! -e "$SESSION/commands.tsv" ]
}

@test "a commands.tsv that is read-only or a symlink stays as it is, and the hooks print nothing" {
    need modes
    need symlinks
    # REC through the fake /proc.
    run_hooks "$REC_TREE" '
        print -rn >| $TLOGGER_SESSION/commands.tsv
        chmod 400 $TLOGGER_SESSION/commands.tsv
        _tlogger_preexec ls ls ls
        false
        _tlogger_precmd
        print -r -- finished'
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    [ "$output" = finished ]
    [ ! -s "$SESSION/commands.tsv" ]
    chmod 600 "$SESSION/commands.tsv"
    rm "$SESSION/commands.tsv"
    # A symlink is never followed, not even to a file of the user's own.
    printf 'kept\n' > "$BATS_TEST_TMPDIR/target"
    ln -s "$BATS_TEST_TMPDIR/target" "$SESSION/commands.tsv"
    run_hooks "$REC_TREE" '
        _tlogger_preexec ls ls ls
        false
        _tlogger_precmd
        print -r -- finished'
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    [ "$output" = finished ]
    [ -L "$SESSION/commands.tsv" ]
    [ "$(cat "$BATS_TEST_TMPDIR/target")" = kept ]
}

@test "a commands.tsv that is a FIFO without a reader holds up no hook, and the hooks print nothing" {
    # REC through the fake /proc. An open for writing waits for a reader of the FIFO unless it is
    # nonblocking; run_hooks kills a shell that waits. mkfifo comes with coreutils, as in CI.
    run_hooks "$REC_TREE" '
        command mkfifo -m 600 -- $TLOGGER_SESSION/commands.tsv || exit 1
        _tlogger_preexec ls ls ls
        false
        _tlogger_precmd
        print -r -- finished'
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    [ "$output" = finished ]
    [ -p "$SESSION/commands.tsv" ]
}

@test "a REC shell's precmd warns at most every 300 seconds while its session has less than min_free_mb" {
    local warning='tlogger: warning: less than 999999999999 MB free in ~/.local/state/tlogger/sessions; the recording goes on'
    # REC through the fake /proc. _tlogger_df_time starts at the load, so the first precmd checks
    # nothing; setting it back stands for the time that has passed.
    run_hooks "$REC_TREE" '
        _tlogger_cfg[min_free_mb]=999999999999
        _tlogger_precmd
        _tlogger_df_time=0
        _tlogger_precmd
        _tlogger_precmd
        _tlogger_df_time=$(( EPOCHSECONDS - 300 ))
        _tlogger_precmd
        _tlogger_cfg[min_free_mb]=0
        _tlogger_df_time=0
        _tlogger_precmd
        print -r -- $_tlogger_state'
    [ "$status" -eq 0 ]
    [ "$output" = REC ]
    [ "${#stderr_lines[@]}" -eq 2 ]
    [ "${stderr_lines[0]}" = "$warning" ]
    [ "${stderr_lines[1]}" = "$warning" ]
    # A NOREC shell checks nothing.
    run_hooks "$NOREC_TREE" '
        _tlogger_cfg[min_free_mb]=999999999999
        _tlogger_df_time=0
        _tlogger_precmd'
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
}

@test "the VPN list holds the counted interfaces in name order with their addresses, and runs no name" {
    local re
    # tun$(id) and tun$(touch pwned) match tun*, but no name with $, ( or a space counts.
    fake_sysfs "$SYS" lo=1 eth0=2 tun0=5 wg0=6 '$(id)=7' 'tun$(id)=8' 'tun$(touch pwned)=9'
    cd "$WORK"
    TLOGGER_IP=$STUB_IP run_hooks "$NOREC_TREE" '
        _tlogger_vpn_update
        print -r -- "list: $_tlogger_vpn"
        _tlogger_precmd
        print -r -- "segment: $TLOGGER_SEGMENT"'
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    [ "${lines[0]}" = "list: $VPN" ]
    re="^segment: \\[$UTC_RE $VPN_RE NOREC\\]\$"
    [[ ${lines[1]} =~ $re ]]
    [[ $output != *uid=* ]]
    [ ! -e "$WORK/pwned" ]
    # Without ip, the names alone.
    run_hooks "$NOREC_TREE" '_tlogger_vpn_update; print -r -- "list: $_tlogger_vpn"'
    [ "$output" = 'list: tun0 wg0' ]
    # tap0 has IPv6 addresses only, the first of which holds a % and does not count; ip shows
    # wg1 as wg1@NONE; tun9 has no address.
    fake_sysfs "$SYS" tap0=10 wg1=11 tun9=12
    TLOGGER_IP=$STUB_IP run_hooks "$NOREC_TREE" '_tlogger_vpn_update; print -r -- "list: $_tlogger_vpn"'
    [ "$output" = 'list: tap0 ::ffff:198.51.100.9 tun0 192.0.2.10 tun9 wg0 198.51.100.7 wg1 203.0.113.5' ]
    # vpn_ifaces sets the patterns; the list stays in name order.
    TLOGGER_VPN_IFACES='wg*, tap0' TLOGGER_IP=$STUB_IP run_hooks "$NOREC_TREE" '
        _tlogger_vpn_update; print -r -- "list: $_tlogger_vpn"'
    [ "$output" = 'list: tap0 ::ffff:198.51.100.9 wg0 198.51.100.7 wg1 203.0.113.5' ]
}

@test "the VPN list runs ip again only when the counted interfaces change or 60 seconds have passed" {
    fake_sysfs "$SYS" tun0=5 wg0=6
    # Each line: the step, how often ip has run, and the list. Setting _tlogger_vpn_time back, or
    # ahead as a clock set back would, stands for the time that has passed.
    TLOGGER_IP=$STUB_IP run_hooks "$NOREC_TREE" '
        runs() {
            local -a r
            if [[ -f $TLOGGER_TEST_IP_LOG ]]; then r=("${(@f)$(<$TLOGGER_TEST_IP_LOG)}"); fi
            print -r -- "$1: $#r [$_tlogger_vpn]"
        }
        _tlogger_vpn_update; runs first
        _tlogger_vpn_update; runs again
        _tlogger_vpn_time=$(( EPOCHSECONDS - 30 )); _tlogger_vpn_update; runs 30s
        _tlogger_vpn_time=$(( EPOCHSECONDS - 60 )); _tlogger_vpn_update; runs 60s
        print -r -- 9 >| $TLOGGER_SYSFS/class/net/tun0/ifindex
        _tlogger_vpn_update; runs new-ifindex
        mkdir $TLOGGER_SYSFS/class/net/tap0 && print -r -- 7 > $TLOGGER_SYSFS/class/net/tap0/ifindex
        _tlogger_vpn_update; runs added
        _tlogger_vpn_time=$(( EPOCHSECONDS + 600 )); _tlogger_vpn_update; runs clock-back
        TLOGGER_SYSFS=${TLOGGER_PROC:h}/no-vpn
        mkdir -p $TLOGGER_SYSFS/class/net/eth0
        _tlogger_vpn_update; runs gone
        _tlogger_vpn_time=0; _tlogger_vpn_update; runs gone-60s'
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    [ "$output" = "first: 1 [$VPN]
again: 1 [$VPN]
30s: 1 [$VPN]
60s: 2 [$VPN]
new-ifindex: 3 [$VPN]
added: 4 [tap0 ::ffff:198.51.100.9 $VPN]
clock-back: 5 [tap0 ::ffff:198.51.100.9 $VPN]
gone: 5 []
gone-60s: 5 []" ]
}

@test "a VPN interface that ip shows without an address makes ip run again after 5 seconds, not 60" {
    fake_sysfs "$SYS" tun0=5 tun9=12
    fake_sysfs "$BATS_TEST_TMPDIR/sys-tun0" tun0=5
    # The stub ip shows no address for tun9, as for a tunnel that has just come up. Each line: the
    # step, how often ip has run, and the list. Moving _tlogger_vpn_time back stands for the time
    # that has passed. Once every interface has its address, the minute holds again.
    J_SYS2="$BATS_TEST_TMPDIR/sys-tun0" TLOGGER_IP=$STUB_IP run_hooks "$NOREC_TREE" '
        runs() {
            local -a r
            if [[ -f $TLOGGER_TEST_IP_LOG ]]; then r=("${(@f)$(<$TLOGGER_TEST_IP_LOG)}"); fi
            print -r -- "$1: $#r [$_tlogger_vpn]"
        }
        _tlogger_vpn_update; runs first
        _tlogger_vpn_update; runs again
        (( _tlogger_vpn_time -= 5 )); _tlogger_vpn_update; runs 5s
        _tlogger_vpn_update; runs again-5s
        TLOGGER_SYSFS=$J_SYS2
        _tlogger_vpn_update; runs addressed
        (( _tlogger_vpn_time -= 5 )); _tlogger_vpn_update; runs addressed-5s'
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    [ "$output" = "first: 1 [tun0 192.0.2.10 tun9]
again: 1 [tun0 192.0.2.10 tun9]
5s: 2 [tun0 192.0.2.10 tun9]
again-5s: 2 [tun0 192.0.2.10 tun9]
addressed: 3 [tun0 192.0.2.10]
addressed-5s: 3 [tun0 192.0.2.10]" ]
    # Without ip there is no address to wait for: the list keeps the time of its run.
    run_hooks "$NOREC_TREE" '
        t=$EPOCHSECONDS
        _tlogger_vpn_update
        (( _tlogger_vpn_time >= t )) && print -r -- "list: $_tlogger_vpn"'
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    [ "$output" = 'list: tun0 tun9' ]
}

@test "stamp_vpn=off keeps the VPN list out of the S lines, the segment and tlogger status, and runs no ip" {
    local re="^segment: \\[$UTC_RE REC\\]\$"
    fake_sysfs "$SYS" tun0=5 wg0=6
    # REC through the fake /proc.
    TLOGGER_STAMP_VPN=off TLOGGER_IP=$STUB_IP run_hooks "$REC_TREE" '
        _tlogger_preexec ls ls ls
        true
        _tlogger_precmd
        print -r -- "segment: $TLOGGER_SEGMENT"
        tlogger status'
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    [[ ${lines[0]} =~ $re ]]
    grep -qx '  vpn: *off' <<< "$output"
    split_tabs "$(head -n 1 "$SESSION/commands.tsv")"
    [ "${FIELDS[5]}" = - ]
    [ ! -e "$TLOGGER_TEST_IP_LOG" ]
}

@test "the segment names the state, REC, NOREC or EXT, and precmd exports it as TLOGGER_SEGMENT" {
    local state tree re
    for state in REC NOREC EXT; do
        tree=${state}_TREE
        run_hooks "${!tree}" '
            print -r -- "before: ${+TLOGGER_SEGMENT}"
            _tlogger_precmd
            print -r -- "after: ${(t)TLOGGER_SEGMENT} $TLOGGER_SEGMENT"'
        [ "$status" -eq 0 ]
        [ -z "$stderr" ]
        [ "${lines[0]}" = 'before: 0' ]
        re="^after: scalar-export \\[$UTC_RE $state\\]\$"
        [[ ${lines[1]} =~ $re ]]
    done
}

@test "precmd puts the segment at the end of a two-line PROMPT's first line, or before a one-line PROMPT, once" {
    local line label seg shown right want re="^\\[$UTC_RE (NOREC|EXT)\\]\$"
    # Each line: a label, the segment, PROMPT with its newline shown as <NL>, and RPROMPT. The
    # fake /proc turns the shell from NOREC to EXT on the way, so that the segment changes. A
    # space and the segment end the first line of the two-line PROMPT; the segment and a space
    # open the one-line PROMPT.
    J_TWO=$'top %~\nnext %# ' J_ONE='one %# ' run_hooks "$NOREC_TREE" '
        printf -v nl "\n"
        show() { print -r -- "$1|$TLOGGER_SEGMENT|${PROMPT//$nl/<NL>}|$RPROMPT"; }
        RPROMPT=right
        PROMPT=$J_TWO
        _tlogger_precmd; show two-NOREC
        _tlogger_precmd; show two-NOREC
        fake_proc 9000020 script 9000019 34816 8000
        fake_proc $$ zsh 9000020 34819 8001
        _tlogger_precmd; show two-EXT
        PROMPT=$J_ONE
        _tlogger_precmd; show one-EXT
        _tlogger_precmd; show one-EXT'
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    [ "${#lines[@]}" -eq 5 ]
    for line in "${lines[@]}"; do
        IFS='|' read -r label seg shown right <<< "$line"
        [[ $seg =~ $re && $seg == *" ${label#*-}]" ]]
        [ "$right" = right ]
        case $label in
            two-*) want="top %~ $seg<NL>next %# " ;;
            *) want="$seg one %# " ;;
        esac
        if [[ $shown != "$want" ]]; then
            printf '%s: expected PROMPT\n%s\ngot\n%s\n' "$label" "$want" "$shown" >&2
            return 1
        fi
    done
}

@test "a % in the segment is doubled, prompt=off adds none and takes the last one out, and a read-only PROMPT stays" {
    J_P='p> ' run_hooks "$NOREC_TREE" '
        PROMPT=$J_P
        _tlogger_prompt "[50%]"
        print -r -- "$PROMPT|${(%)PROMPT}|"
        _tlogger_prompt "[60%]"
        print -r -- "$PROMPT|"
        _tlogger_cfg[prompt]=off
        _tlogger_precmd
        print -r -- "$PROMPT|${(t)TLOGGER_SEGMENT}"
        _tlogger_cfg[prompt]=on
        typeset -r PROMPT
        _tlogger_precmd
        print -r -- "$PROMPT|"'
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    [ "${lines[0]}" = '[50%%] p> |[50%] p> |' ]
    [ "${lines[1]}" = '[60%%] p> |' ]
    [ "${lines[2]}" = 'p> |scalar-export' ]
    [ "${lines[3]}" = 'p> |' ]
    # prompt=off in the config: no segment from the first prompt on, and TLOGGER_SEGMENT all the
    # same.
    printf 'prompt=off\n' > "$CONFIG"
    J_TWO=$'top\nnext> ' run_hooks "$NOREC_TREE" '
        PROMPT=$J_TWO
        _tlogger_precmd
        [[ $PROMPT == "$J_TWO" ]] && print -r -- "PROMPT as it was"
        print -r -- "${(t)TLOGGER_SEGMENT}"'
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    [ "$output" = $'PROMPT as it was\nscalar-export' ]
}

@test "the segment goes into the PROMPT that /etc/skel/.zshrc builds, in both of its Ctrl+P states" {
    need file /etc/skel/.zshrc
    local fn="$BATS_TEST_TMPDIR/configure_prompt.zsh"
    # Kali's configure_prompt, from its first line to the closing brace in the first column. Its
    # Ctrl+P widget switches PROMPT_ALTERNATIVE between twoline and oneline and calls it.
    awk '/^configure_prompt\(\) *\{/, /^\}/' /etc/skel/.zshrc > "$fn"
    grep -q 'twoline)' "$fn"
    grep -q 'oneline)' "$fn"
    # PROMPT_SUBST is on, as Kali sets it; (%%) expands PROMPT as zsh shows it.
    J_FN=$fn run_hooks "$NOREC_TREE" '
        source $J_FN || exit 1
        setopt promptsubst
        printf -v nl "\n"
        PROMPT_ALTERNATIVE=twoline; configure_prompt; two=$PROMPT
        PROMPT_ALTERNATIVE=oneline; configure_prompt; one=$PROMPT
        [[ $two == *$nl* && $one != *$nl* ]] && print -r -- "kali prompts"
        PROMPT_ALTERNATIVE=twoline; configure_prompt
        _tlogger_precmd
        seg=$TLOGGER_SEGMENT
        [[ ${PROMPT%%$nl*} == "${two%%$nl*} $seg" && ${PROMPT#*$nl} == "${two#*$nl}" ]] &&
            print -r -- "twoline: at the end of the first line"
        [[ ${${(%%)PROMPT}%%$nl*} == *"] $seg" ]] && print -r -- "twoline: shown after the ]"
        PROMPT_ALTERNATIVE=oneline; configure_prompt
        _tlogger_precmd
        [[ $PROMPT == "$TLOGGER_SEGMENT $one" ]] && print -r -- "oneline: in front"
        [[ ${(%%)PROMPT} == "$TLOGGER_SEGMENT "* ]] && print -r -- "oneline: shown in front"
        PROMPT_ALTERNATIVE=twoline; configure_prompt
        _tlogger_precmd
        [[ $PROMPT == "${two%%$nl*} $TLOGGER_SEGMENT$nl${two#*$nl}" ]] && print -r -- "twoline again"'
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    [ "$output" = 'kali prompts
twoline: at the end of the first line
twoline: shown after the ]
oneline: in front
oneline: shown in front
twoline again' ]
}

@test "history_timestamps=yes sets extended_history and no other option, and no, the default, sets none" {
    # The options before the plugin loads, then the ones it added and removed. The differences
    # are taken outside double quotes: inside them, ${a:|b} joins a first and tests the whole
    # string against each element of b, which removes nothing.
    local tree="$NOREC_TREE"'
        o0=(${(f)"$(setopt)"})'
    local code='o1=(${(f)"$(setopt)"})
        added=(${o1:|o0})
        removed=(${o0:|o1})
        print -r -- "added: $added; removed: $removed"'
    run_hooks "$tree" "$code"
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    [ "$output" = 'added: ; removed: ' ]
    TLOGGER_HISTORY_TIMESTAMPS=yes run_hooks "$tree" "$code"
    [ "$output" = 'added: extendedhistory; removed: ' ]
    printf 'history_timestamps=yes\n' > "$CONFIG"
    run_hooks "$tree" "$code"
    [ "$output" = 'added: extendedhistory; removed: ' ]
    TLOGGER_HISTORY_TIMESTAMPS=no run_hooks "$tree" "$code"
    [ "$output" = 'added: ; removed: ' ]
    printf 'history_timestamps=always\n' > "$CONFIG"
    run_hooks "$tree" "$code"
    [ "$output" = 'added: ; removed: ' ]
    [ "$stderr" = 'tlogger: warning: ~/.config/tlogger/config line 1: history_timestamps must be yes or no; using no' ]
}

@test "tlogger status shows prompt, stamp and the VPN list: none without VPN interfaces, off with stamp_vpn=off" {
    fake_sysfs "$SYS" tun0=5 wg0=6
    TLOGGER_IP=$STUB_IP run_hooks "$NOREC_TREE" 'tlogger status'
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    grep -qx '  prompt: *on' <<< "$output"
    grep -qx '  stamp: *on' <<< "$output"
    grep -qx "  vpn: *$VPN_RE" <<< "$output"
    fake_sysfs "$BATS_TEST_TMPDIR/no-vpn" lo=1 eth0=2
    TLOGGER_SYSFS="$BATS_TEST_TMPDIR/no-vpn" run_hooks "$NOREC_TREE" 'tlogger status'
    grep -qx '  vpn: *none' <<< "$output"
    printf 'prompt=off\nstamp=off\nstamp_vpn=off\n' > "$CONFIG"
    TLOGGER_IP=$STUB_IP run_hooks "$NOREC_TREE" 'tlogger status'
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    grep -qx '  prompt: *off' <<< "$output"
    grep -qx '  stamp: *off' <<< "$output"
    grep -qx '  vpn: *off' <<< "$output"
}

@test "_tlogger_drop_empty removes a session folder whose commands.tsv is empty too, and keeps a journal" {
    run_hooks "$NOREC_TREE" '
        d=${TLOGGER_PROC:h}/never-started
        mkdir -p $d
        print -rn >| $d/output.raw; print -rn >| $d/timing; print -rn >| $d/commands.tsv
        _tlogger_drop_empty $d && [[ ! -e $d ]] && print -r -- dropped
        mkdir -p $d
        print -rn >| $d/output.raw
        print -r -- "E 1 2 0" >| $d/commands.tsv
        _tlogger_drop_empty $d || [[ ! -s $d/commands.tsv ]] || print -r -- kept'
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    [ "$output" = $'dropped\nkept' ]
}
