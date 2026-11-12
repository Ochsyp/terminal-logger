# tlogger config parser for zsh, sourced by lib/tlogger.zsh and by the tests. It defines only
# _tlogger_load_config, which reads ${XDG_CONFIG_HOME:-$HOME/.config}/tlogger/config as data and
# never runs or expands a value. bin/tlogger's read_config follows the same line rules.

# Fill the global associative array _tlogger_cfg with mode, logdir, record_input, min_free_mb,
# recorder, record_ssh, record_tmux, prompt, stamp, stamp_vpn, vpn_ifaces and history_timestamps,
# and with config_dir, the folder that holds the config and the disable file. Lines are key=value,
# blank or '#' comments; whitespace around a value is trimmed, a repeated key keeps its first
# value and an unknown key is ignored. An exported TLOGGER_<KEY in upper case> that is not empty
# wins over the file. An invalid value, or a line that is not key=value, gets one warning on
# stderr, and the key keeps its default. vpn_ifaces is kept as its patterns joined by single
# spaces. A file that is a symlink, not a regular file, another user's or unreadable is not read.
# recorder= and TLOGGER_RECORDER exist for the tests. Always returns 0, and runs no command.
_tlogger_load_config() {
    emulate -L zsh
    setopt extendedglob
    local home=${${HOME-}%%/##} base cfg_dir state_dir file shown_file content line key value why
    local shown_default name
    local -i n
    local -a lines keys pats bad
    local -A def raw origin

    # XDG base folders: unset, empty or relative values fall back to the defaults under HOME.
    base=${XDG_CONFIG_HOME-}
    if [[ $base != /* ]]; then
        base=$home/.config
    fi
    while [[ $base == ?*/ ]]; do
        base=${base%/}
    done
    cfg_dir=$base/tlogger
    base=${XDG_STATE_HOME-}
    if [[ $base != /* ]]; then
        base=$home/.local/state
    fi
    while [[ $base == ?*/ ]]; do
        base=${base%/}
    done
    state_dir=$base/tlogger
    # The keys in the order of their checks, and so of their warnings.
    keys=(mode logdir record_input min_free_mb recorder record_ssh record_tmux prompt stamp
        stamp_vpn vpn_ifaces history_timestamps)
    def=(mode manual logdir "$state_dir/sessions" record_input yes min_free_mb 200
        recorder /usr/bin/script record_ssh yes record_tmux yes prompt on stamp on stamp_vpn on
        vpn_ifaces 'tun* wg* tap*' history_timestamps no)

    file=$cfg_dir/config
    shown_file=$file
    if [[ -n $home && $file == "$home"/* ]]; then
        shown_file="~${file#"$home"}"
    fi
    # content stays empty unless the file passes these checks and is read; $(<file) reads it
    # without a fork.
    content=
    if [[ -L $file || ( -e $file && ! -f $file ) ]]; then
        print -ru2 -- "tlogger: warning: $shown_file is a symlink or not a regular file; using the defaults"
    elif [[ -e $file && ! -O $file ]]; then
        print -ru2 -- "tlogger: warning: $shown_file belongs to another user; using the defaults"
    elif [[ -e $file ]] && ! { content=$(<$file); } 2> /dev/null; then
        content=
        print -ru2 -- "tlogger: warning: $shown_file is not readable; using the defaults"
    fi
    lines=("${(@f)content}")
    for (( n = 1; n <= $#lines; n++ )); do
        line=$lines[n]
        if [[ $line == [[:space:]]#('#'*|) ]]; then
            continue
        fi
        if [[ $line != [a-z][a-z0-9_]#=* ]]; then
            print -ru2 -- "tlogger: warning: $shown_file line $n is not a key=value line; ignored"
            continue
        fi
        key=${line%%=*}
        if (( ! ${+def[$key]} )); then
            continue
        fi
        if (( ${+raw[$key]} )); then
            print -ru2 -- "tlogger: warning: $shown_file line $n repeats the key $key; ignored"
            continue
        fi
        value=${line#*=}
        raw[$key]=${${value##[[:space:]]#}%%[[:space:]]#}
        origin[$key]="$shown_file line $n"
    done

    # Only an exported variable counts, so that this shell and the shells it starts agree.
    for key in $keys; do
        name=TLOGGER_${(U)key}
        if [[ ${(tP)name} == *export* && -n ${(P)name} ]]; then
            value=${(P)name}
            raw[$key]=${${value##[[:space:]]#}%%[[:space:]]#}
            origin[$key]=$name
        fi
    done

    typeset -gA _tlogger_cfg
    _tlogger_cfg=(config_dir "$cfg_dir")
    for key in $keys; do
        if (( ! ${+raw[$key]} )); then
            _tlogger_cfg[$key]=$def[$key]
            continue
        fi
        value=$raw[$key]
        why=
        case $key in
            mode)
                if [[ $value != (auto|manual) ]]; then
                    why='must be auto or manual'
                fi
                ;;
            record_input | record_ssh | record_tmux | history_timestamps)
                if [[ $value != (yes|no) ]]; then
                    why='must be yes or no'
                fi
                ;;
            prompt | stamp | stamp_vpn)
                if [[ $value != (on|off) ]]; then
                    why='must be on or off'
                fi
                ;;
            vpn_ifaces)
                # Spaces, tabs and commas separate the patterns. A pattern holds only letters,
                # digits, _ . - and the wildcard *, so that the plugin can match interface names
                # with it as it is, and nothing in it can run.
                pats=(${(s:,:)${value//[[:space:]]/,}})
                bad=(${pats:#[A-Za-z0-9_.*-]##})
                if (( $#pats == 0 || $#bad )); then
                    why='must list interface name patterns made of letters, digits, _ . - and *'
                else
                    value=${(j: :)pats}
                fi
                ;;
            min_free_mb)
                # Checked as digits before the arithmetic, which would run code in a value.
                if [[ $value == [0-9](#c1,12) ]]; then
                    value=$(( 10#$value ))
                else
                    why='must be a whole number of MB'
                fi
                ;;
            logdir)
                while [[ $value == ?*/ ]]; do
                    value=${value%/}
                done
                if [[ $value != /* || $value == *[[:cntrl:]]* ]]; then
                    why='must be an absolute path'
                fi
                ;;
            recorder)
                if [[ $value != /* || $value == *[[:cntrl:]]* ]]; then
                    why='must be an absolute path'
                fi
                ;;
        esac
        if [[ -n $why ]]; then
            value=$def[$key]
            shown_default=$value
            if [[ -n $home && $value == "$home"/* ]]; then
                shown_default="~${value#"$home"}"
            fi
            print -ru2 -- "tlogger: warning: ${origin[$key]}: $key $why; using $shown_default"
        fi
        _tlogger_cfg[$key]=$value
    done
    return 0
}
