#!/usr/bin/env bats
# shellcheck disable=SC2016 # The tests hand zsh code to zsh in single quotes; zsh expands it.
# End-to-end tests of the command journal, the stamp and the prompt segment: tlogger, installed
# from the work tree in manual mode on the e2e fixture rc, or on the rc built from /etc/skel/.zshrc,
# runs in a real zsh in a pseudo-terminal that zsh's zpty module drives (tests/helpers/pty.zsh),
# without tmux. They need Linux, zsh with zpty, script 2.35 or newer, symlinks and POSIX modes.

bats_require_minimum_version 1.5.0

load helpers

# Run before each test by bats.
# Gives the test its own HOME, with tlogger installed in manual mode on top of the e2e fixture rc,
# and two fake sysfs trees: SYS_NONE without VPN interfaces, SYS_VPN with tun0, whose address the
# stub ip gives. The tests name one, so that the interfaces of the machine stay out.
setup() {
    isolate_home
    isolate_tlogger
    need zsh
    need zpty
    need script
    need proc
    need symlinks
    need modes
    SESSIONS="$HOME/.local/state/tlogger/sessions"
    # shellcheck disable=SC2034 # drive reads it.
    SCREEN="$BATS_TEST_TMPDIR/screen"
    SYS_NONE="$BATS_TEST_TMPDIR/sys-none"
    SYS_VPN="$BATS_TEST_TMPDIR/sys-vpn"
    fake_sysfs "$SYS_NONE" lo=1 eth0=2
    fake_sysfs "$SYS_VPN" lo=1 eth0=2 tun0=5
    cp "$REPO_ROOT/tests/fixtures/e2e-zshrc" "$HOME/.zshrc"
    run_tlogger install --mode manual --yes
    [ "$status" -eq 0 ]
}

# Print the names in the sessions folder, one per line, sorted.
session_names() {
    find "$SESSIONS" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort
}

# Set DIR to the only session folder. Fails unless there is exactly one, named as tlogger names
# sessions: the UTC time, then 6 random characters.
one_session() {
    local -a names
    mapfile -t names < <(session_names)
    if (( ${#names[@]} != 1 )); then
        printf 'expected one session folder, found %s: %s\n' "${#names[@]}" "${names[*]}" >&2
        return 1
    fi
    [[ ${names[0]} =~ ^[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9]{6}$ ]]
    DIR="$SESSIONS/${names[0]}"
}

# Print the line that pty_begin types for frame N around COMMAND, as the journal quotes it: in
# single quotes, since it holds no single quote and no control character.
frame_text() {
    printf "'echo \"<b:\$((%s+0))>\"; %s; echo \"<e:\$?:\$((%s+0))>\"'" "$1" "$2" "$1"
}

# Print the folder HOME as the journal writes it, from the shell that zsh starts there.
journal_home() {
    zsh -f -c 'print -r -- ${(q+)1}' zsh "$(cd "$HOME" && pwd -P)"
}

@test "commands typed in a recorded terminal get S and E lines with their status, and a hidden stamp each" {
    local pid home row vpn='tun0 192.0.2.10'
    local -a rows
    # Frames 1 and 2 run in the outer shell, which journals nothing; 3 and 4 in the recorded one.
    E2E_SYS=$SYS_VPN E2E_IP=$STUB_IP drive << 'EOF'
cd ~ || pty_fail 'cannot change to HOME'
pty_shell TLOGGER_SYSFS=$E2E_SYS TLOGGER_IP=$E2E_IP
pty_begin 'tlogger start'
start=$REPLY
pty_session
[[ $PTY_BANNER_SGR == $'\e[32m' ]] || pty_fail "the banner is not green: ${(V)PTY_BANNER_SGR}"
pty_run 'print -r -- $$'
print -r -- ${PTY_OUT%$'\n'} >| ~/recorded-pid
pty_send '(exit 42)'
pty_send false
pty_run 'tlogger status'
pty_out_has 'vpn: tun0 192.0.2.10' || pty_fail 'tlogger status shows no VPN list'
pty_send exit
pty_end $start
(( PTY_STATUS == 0 )) || pty_fail "tlogger start returned $PTY_STATUS"
EOF
    one_session
    pid=$(cat "$HOME/recorded-pid")
    home=$(journal_home)
    mapfile -t rows < "$DIR/commands.tsv"
    [ "${#rows[@]}" -eq 9 ]
    assert_s_line "${rows[0]}" "$pid" "$home" "$vpn" "$(frame_text 3 'print -r -- $$')"
    assert_e_line "${rows[1]}" "$pid" 0
    assert_s_line "${rows[2]}" "$pid" "$home" "$vpn" "'(exit 42)'"
    assert_e_line "${rows[3]}" "$pid" 42
    assert_s_line "${rows[4]}" "$pid" "$home" "$vpn" false
    assert_e_line "${rows[5]}" "$pid" 1
    assert_s_line "${rows[6]}" "$pid" "$home" "$vpn" "$(frame_text 4 'tlogger status')"
    assert_e_line "${rows[7]}" "$pid" 0
    # exit ends the shell, so no E line follows its S line.
    assert_s_line "${rows[8]}" "$pid" "$home" "$vpn" exit
    # Each S line has its stamp in output.raw, hidden in an OSC 7711 string, with the same UTC
    # time, and no visible stamp line, which stamp=hidden, the default, does not print.
    for row in "${rows[@]}"; do
        split_tabs "$row"
        if [[ ${FIELDS[0]} == S ]]; then
            grep -qaF $'\e]7711;tlogger-stamp '"${FIELDS[2]} $vpn"$'\e\\' "$DIR/output.raw"
            run ! grep -qaF -- "-- ${FIELDS[2]}" "$DIR/output.raw"
        fi
    done
}

@test "a nested zsh journals its commands with its own pid, between the lines of the shell that ran it" {
    local main inner home
    local -a rows
    E2E_SYS=$SYS_NONE drive << 'EOF'
cd ~ || pty_fail 'cannot change to HOME'
pty_shell TLOGGER_SYSFS=$E2E_SYS
pty_begin 'tlogger start'
start=$REPLY
pty_session
pty_run 'print -r -- $$'
main=${PTY_OUT%$'\n'}
pty_begin zsh
nested=$REPLY
pty_run 'print -r -- $$'
print -r -- "$main ${PTY_OUT%$'\n'}" >| ~/pids
pty_send '(exit 5)'
pty_send exit
pty_end $nested
pty_send exit
pty_end $start
(( PTY_STATUS == 0 )) || pty_fail "tlogger start returned $PTY_STATUS"
EOF
    one_session
    read -r main inner < "$HOME/pids"
    [ "$main" != "$inner" ]
    home=$(journal_home)
    mapfile -t rows < "$DIR/commands.tsv"
    [ "${#rows[@]}" -eq 10 ]
    assert_s_line "${rows[0]}" "$main" "$home" - "$(frame_text 3 'print -r -- $$')"
    assert_e_line "${rows[1]}" "$main" 0
    assert_s_line "${rows[2]}" "$main" "$home" - "$(frame_text 4 zsh)"
    assert_s_line "${rows[3]}" "$inner" "$home" - "$(frame_text 5 'print -r -- $$')"
    assert_e_line "${rows[4]}" "$inner" 0
    assert_s_line "${rows[5]}" "$inner" "$home" - "'(exit 5)'"
    assert_e_line "${rows[6]}" "$inner" 5
    assert_s_line "${rows[7]}" "$inner" "$home" - exit
    # The frame around zsh ends in the main shell once the nested one has gone.
    assert_e_line "${rows[8]}" "$main" 0
    assert_s_line "${rows[9]}" "$main" "$home" - exit
}

@test "the prompt shows NOREC in a shell that is not recorded, EXT under another script and REC in a recording" {
    E2E_SYS=$SYS_NONE drive << 'EOF'
pty_shell TLOGGER_SYSFS=$E2E_SYS
pty_segment NOREC ' e2e% '
# A zsh under a script process that tlogger did not start.
pty_begin '/usr/bin/script -q -c zsh /dev/null'
foreign=$REPLY
pty_segment EXT ' e2e% '
pty_send exit
pty_end $foreign
pty_segment NOREC ' e2e% '
pty_begin 'tlogger start'
start=$REPLY
pty_session
pty_segment REC ' e2e% '
pty_run 'print -r -- "${(t)TLOGGER_SEGMENT} $TLOGGER_SEGMENT"'
[[ $PTY_OUT == 'scalar-export ['*' REC]'$'\n' ]] || pty_fail "the recorded shell has: $PTY_OUT"
pty_send exit
pty_end $start
pty_segment NOREC ' e2e% '
EOF
}

@test "prompt=off shows no segment, while TLOGGER_SEGMENT and the stamps stay" {
    E2E_SYS=$SYS_NONE drive << 'EOF'
pty_shell TLOGGER_PROMPT=off TLOGGER_SYSFS=$E2E_SYS
pty_run 'print -r -- "$PROMPT|${(t)TLOGGER_SEGMENT}|$TLOGGER_SEGMENT"'
[[ $PTY_OUT == 'e2e%# |scalar-export|['*' NOREC]'$'\n' ]] || pty_fail "the shell has: $PTY_OUT"
pty_begin 'tlogger start'
start=$REPLY
pty_session
pty_run 'print -r -- "$PROMPT|$TLOGGER_SEGMENT"'
[[ $PTY_OUT == 'e2e%# |['*' REC]'$'\n' ]] || pty_fail "the recorded shell has: $PTY_OUT"
pty_send exit
pty_end $start
[[ $PTY_LOG != *'] e2e% '* ]] || pty_fail 'a prompt shows a segment'
[[ $PTY_LOG == *$'\e]7711;tlogger-stamp '* ]] || pty_fail 'the recorded shell wrote no hidden stamp'
EOF
}

@test "NO_COLOR prints the banner and stamp=on's stamp without colour, and stamp=off writes none while the journal goes on" {
    local id row
    local -a rows
    E2E_SYS=$SYS_NONE drive << 'EOF'
pty_shell NO_COLOR=1 TLOGGER_STAMP=on TLOGGER_SYSFS=$E2E_SYS
pty_begin 'tlogger start'
start=$REPLY
pty_session
[[ -z $PTY_BANNER_SGR ]] || pty_fail "the banner has a colour: ${(V)PTY_BANNER_SGR}"
print -r -- $PTY_ID >| ~/no-color-id
pty_run true
pty_send exit
pty_end $start
pty_close
pty_shell TLOGGER_STAMP=off TLOGGER_SYSFS=$E2E_SYS
pty_begin 'tlogger start'
start=$REPLY
pty_session
print -r -- $PTY_ID >| ~/no-stamp-id
pty_run true
pty_send exit
pty_end $start
EOF
    [ "$(session_names | wc -l)" -eq 2 ]
    id=$(cat "$HOME/no-color-id")
    mapfile -t rows < "$SESSIONS/$id/commands.tsv"
    [ "${#rows[@]}" -eq 3 ]
    for row in "${rows[0]}" "${rows[2]}"; do
        split_tabs "$row"
        [ "${FIELDS[0]}" = S ]
        grep -qaF -- "-- ${FIELDS[2]} REC" "$SESSIONS/$id/output.raw"
    done
    run ! grep -qaF $'\e[2m' "$SESSIONS/$id/output.raw"
    id=$(cat "$HOME/no-stamp-id")
    mapfile -t rows < "$SESSIONS/$id/commands.tsv"
    [ "${#rows[@]}" -eq 3 ]
    for row in "${rows[0]}" "${rows[2]}"; do
        split_tabs "$row"
        [ "${FIELDS[0]}" = S ]
        run ! grep -qaF -- "-- ${FIELDS[2]} REC" "$SESSIONS/$id/output.raw"
    done
    run ! grep -qaF 'tlogger-stamp' "$SESSIONS/$id/output.raw"
}

@test "under the rc built from /etc/skel/.zshrc, the segment is back on the prompt after Ctrl+P twice" {
    need file /etc/skel/.zshrc
    # The rc that install builds from Kali's own: the block, then /etc/skel/.zshrc as it is, with
    # its precmd, its Ctrl+P widget and the line editor on. Under TERM=dumb it starts with its
    # plain one-line prompt; Ctrl+P builds the one-line, then the two-line prompt, each without
    # the segment, which the next precmd adds at the end of the first line. The test reads PROMPT
    # itself, not the screen: under TERM=dumb the line editor runs in single-line mode and scrolls
    # long lines sideways, so what it draws of a two-line prompt is no reliable text.
    cat "$GOLDEN_BLOCK" /etc/skel/.zshrc > "$HOME/.zshrc"
    E2E_SYS=$SYS_NONE drive << 'EOF'
pty_shell TLOGGER_SYSFS=$E2E_SYS
pty_run 'prompt_lines=(${(f)PROMPT}); print -r -- "$PROMPT_ALTERNATIVE $#prompt_lines"'
pty_out_is 'twoline 1' || pty_fail "the rc starts with: $PTY_OUT"
pty_type $'\x10'
pty_type $'\x10'
# Enter on the empty line runs precmd, which puts the segment back into the PROMPT that Ctrl+P
# rebuilt; the next command prints the end of PROMPT's first line, as long as the text that
# precmd inserted, and that text, which _tlogger_seg keeps.
pty_send ''
pty_run 'prompt_lines=(${(f)PROMPT}); print -r -- "$PROMPT_ALTERNATIVE $#prompt_lines ${prompt_lines[1][-$#_tlogger_seg,-1]}|$_tlogger_seg"'
[[ $PTY_OUT == (#b)'twoline 2 '(*)'|'(*)$'\n' && $match[1] == "$match[2]" &&
    $match[2] == ' ['*'] [%F{red}NOREC%f]' ]] || pty_fail "after Ctrl+P twice the shell has: $PTY_OUT"
EOF
}
