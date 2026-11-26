#!/usr/bin/env bats
# The hidden stamp in real terminal multiplexers: tmux and GNU screen read the bytes that
# stamp=hidden writes, an OSC 7711 string, and must show none of it, neither on the screen nor in
# the pane or window title nor in tmux's status line. QTerminal, xterm and VTE terminals need a
# display; CONTRIBUTING.md says how to check them by hand.

bats_require_minimum_version 1.5.0

load helpers

# The stamp exactly as the plugin writes it in a shell with a VPN list, between A and B.
STAMP=$'\e]7711;tlogger-stamp 2026-11-26T13:20:52Z tun0 192.0.2.10\e\\'

# Run before each test by bats.
# Gives the test its own home and a probe script that prints A, the stamp and B on one line, then
# done, and waits PROBE_WAIT seconds (default 60), so that the multiplexer keeps its pane or
# window open while the test reads it.
setup() {
    isolate_home
    isolate_tlogger
    unset TMUX STY
    PROBE="$BATS_TEST_TMPDIR/probe.sh"
    {
        printf '#!/bin/sh\n'
        printf "printf '%%s\\\\n' '%s'\n" "A${STAMP}B"
        printf "printf 'done\\\\n'\n"
        # shellcheck disable=SC2016 # The probe expands it, not this shell.
        printf 'sleep "${PROBE_WAIT:-60}"\n'
    } > "$PROBE"
    chmod 755 "$PROBE"
}

@test "the probe prints A, the stamp and B on one line, then done" {
    run --separate-stderr env PROBE_WAIT=0 sh "$PROBE"
    [ "$status" -eq 0 ]
    [ "$output" = "A${STAMP}B"$'\n'done ]
}

@test "tmux shows nothing of a hidden stamp: not in the pane, its title or the status line" {
    need command tmux
    local sock="$BATS_TEST_TMPDIR/tmux.sock" pane='' title status_line i
    tmux -S "$sock" -f /dev/null new-session -d -x 100 -y 10 "$PROBE"
    for (( i = 0; i < 100; i++ )); do
        pane=$(tmux -S "$sock" capture-pane -p 2> /dev/null) || pane=''
        if [[ $pane == *done* ]]; then
            break
        fi
        sleep 0.1
    done
    title=$(tmux -S "$sock" display-message -p '#{pane_title}')
    status_line=$(tmux -S "$sock" display-message -p '#{T:status-left}#{T:status-right}')
    tmux -S "$sock" kill-server
    [[ $pane == *done* ]]
    [ "$(sed -n 1p <<< "$pane")" = AB ]
    [[ $title != *stamp* && $title != *7711* ]]
    [[ $status_line != *stamp* && $status_line != *7711* ]]
}

@test "GNU screen shows nothing of a hidden stamp: not in the window or its title" {
    need command screen
    local copy="$BATS_TEST_TMPDIR/hardcopy" title i
    export SCREENDIR="$BATS_TEST_TMPDIR/screens" SYSSCREENRC=/dev/null
    mkdir -m 700 "$SCREENDIR"
    screen -c /dev/null -dmS probe "$PROBE"
    for (( i = 0; i < 100; i++ )); do
        rm -f "$copy"
        screen -S probe -X hardcopy "$copy" 2> /dev/null || true
        if [[ -f $copy ]] && grep -q 'done' "$copy"; then
            break
        fi
        sleep 0.1
    done
    title=$(screen -S probe -Q title)
    screen -S probe -X quit
    grep -q 'done' "$copy"
    [ "$(sed -n 1p "$copy")" = AB ]
    [[ $title != *stamp* && $title != *7711* ]]
}
