# Scan a zsh rc on stdin for the tlogger block and report it on stdout; change nothing. Runs
# under POSIX awk, mawk and gawk. bin/tlogger edits the rc with head and tail around the line
# numbers reported here, so every byte outside the block stays as it is.

# Output, one item per line:
#   none               no tlogger marker anywhere
#   block START END    one well-formed block, from line START to line END
#   foreign LINE       a line outside the block runs script or /usr/bin/script as a command
#   error KIND LINE    a marker problem; KIND is unpaired, duplicate, reversed or altered
# The none or block line comes first and only when there is no error, then the foreign lines,
# then the error lines in line order. Lines are compared whole after one trailing CR is removed.
# The exit status is 1 when an error line is printed, else 0.

BEGIN {
    start_mark = "# >>> tlogger >>>"
    end_mark = "# <<< tlogger <<<"
    # A line holding either text without being exactly its marker is an altered marker.
    start_text = ">>> tlogger >>>"
    end_text = "<<< tlogger <<<"
    n_start = 0
    n_end = 0
    n_foreign = 0
    n_error = 0
    inside = 0
}

# Record an error of KIND at line number LINE_NO; END prints them sorted by line.
# Keeps them in err_kind and err_line, indexed from 1 to n_error.
function add_error(error_kind, line_no) {
    n_error++
    err_kind[n_error] = error_kind
    err_line[n_error] = line_no
}

# Return 1 when TEXT runs script or /usr/bin/script as a command, else 0. The word must start
# the line or follow whitespace, ;, |, &, (, {, a backquote or $(, and end at whitespace or the
# line end. A comment line never counts, nor does the part of a line from a # that starts a word,
# after whitespace, ;, | or &, as zsh reads it.
function runs_script(text) {
    if (text ~ /^[ \t]*#/)
        return 0
    if (match(text, /[ \t;|&]#/))
        text = substr(text, 1, RSTART)
    # Each pattern comes twice, for the two ends the word may have, since some awks do not
    # take $ inside a group.
    if (text ~ /^(\/usr\/bin\/)?script$/ || text ~ /^(\/usr\/bin\/)?script[ \t]/)
        return 1
    if (text ~ /[ \t;|&({`](\/usr\/bin\/)?script$/ || text ~ /[ \t;|&({`](\/usr\/bin\/)?script[ \t]/)
        return 1
    if (text ~ /[$][(](\/usr\/bin\/)?script$/ || text ~ /[$][(](\/usr\/bin\/)?script[ \t]/)
        return 1
    return 0
}

{
    line = $0
    sub(/\r$/, "", line)
    if (line == start_mark) {
        n_start++
        start_line[n_start] = NR
        inside = 1
    } else if (line == end_mark) {
        n_end++
        end_line[n_end] = NR
        inside = 0
    } else if (index(line, start_text) || index(line, end_text)) {
        add_error("altered", NR)
    } else if (!inside && runs_script(line)) {
        n_foreign++
        foreign[n_foreign] = NR
    }
}

END {
    for (i = 2; i <= n_start; i++)
        add_error("duplicate", start_line[i])
    for (i = 2; i <= n_end; i++)
        add_error("duplicate", end_line[i])
    if (n_start > 0 && n_end == 0)
        add_error("unpaired", start_line[1])
    if (n_end > 0 && n_start == 0)
        add_error("unpaired", end_line[1])
    if (n_start > 0 && n_end > 0 && end_line[1] < start_line[1])
        add_error("reversed", end_line[1])

    if (n_error == 0) {
        if (n_start == 1)
            print "block " start_line[1] " " end_line[1]
        else
            print "none"
    }
    for (i = 1; i <= n_foreign; i++)
        print "foreign " foreign[i]

    # Insertion sort by line number; a file holds only a handful of marker problems.
    for (i = 2; i <= n_error; i++) {
        kind = err_kind[i]
        at = err_line[i]
        for (j = i - 1; j >= 1 && err_line[j] > at; j--) {
            err_kind[j + 1] = err_kind[j]
            err_line[j + 1] = err_line[j]
        }
        err_kind[j + 1] = kind
        err_line[j + 1] = at
    }
    for (i = 1; i <= n_error; i++)
        print "error " err_kind[i] " " err_line[i]
    exit (n_error > 0)
}
