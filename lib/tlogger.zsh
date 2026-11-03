# tlogger plugin for zsh, sourced by the tlogger block at the top of the zsh rc. This version
# records nothing: it defines the tlogger command, whose status says so, and hands every other
# subcommand to bin/tlogger of the release this file belongs to. It changes no zsh option, never
# touches PROMPT, and defines only the tlogger function and the _tlogger_release variable.

# Only an interactive shell gets the command.
[[ -o interactive ]] || return 0

# A root shell whose HOME is not root's own, as 'sudo -s' can leave it, reads another user's rc.
# It defines nothing, so that root never runs that user's tlogger. userdirs maps a user name to
# the home in the passwd database without a fork.
if (( EUID == 0 )) && [[ ${HOME%/} != "${${userdirs[root]:-/root}%/}" ]]; then
    return 0
fi

# The release folder: the folder above the lib/ that holds this file, with the current symlink
# resolved, so that this shell keeps using the release it loaded.
typeset -g _tlogger_release=${${(%):-%x}:A:h:h}

# tlogger status: print the plugin version and that this terminal is not recorded.
# Every other subcommand runs <release>/bin/tlogger with the same arguments and returns its exit
# status. The function keyword keeps an alias named tlogger from changing this definition.
function tlogger {
    # Confines option changes to this function; the shell's own options stay as they are.
    emulate -L zsh
    local version=unknown
    if [[ ${1-} == status ]]; then
        if [[ -r $_tlogger_release/VERSION ]]; then
            IFS= read -r version < $_tlogger_release/VERSION || :
        fi
        print -r -- "tlogger plugin ${version:-unknown}"
        print -r -- "this terminal is NOT recorded (recording arrives in a later version)"
        return 0
    fi
    if [[ -z $_tlogger_release || ! -x $_tlogger_release/bin/tlogger ]]; then
        print -ru2 -- "tlogger: ${(D)_tlogger_release:-the release folder}/bin/tlogger is missing; run tlogger install from a checkout"
        return 1
    fi
    "$_tlogger_release/bin/tlogger" "$@"
}
