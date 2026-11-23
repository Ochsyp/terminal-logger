# Find the block of an older logger in a zsh rc on stdin and report it on stdout; change nothing.
# Runs under POSIX awk, mawk and gawk. The two marker lines come from ENVIRON["LEGACY_START"] and
# ENVIRON["LEGACY_END"], because awk's -v would rewrite a backslash in them.

# Prints "none", or "block START END", or one "error KIND LINE" per problem in line order, where
# KIND is unpaired, duplicate, reversed or altered. Exits 1 after an error, 2 on an empty marker.

# Lines are compared whole, as text, after one trailing CR is removed. A line that holds a marker's
# text without being exactly a marker is altered, unless it is exactly one of tlogger's own markers.

BEGIN {
    # The empty string forces a text comparison: "10" and "10.0" are different lines.
    start_mark = ENVIRON["LEGACY_START"] ""
    end_mark = ENVIRON["LEGACY_END"] ""
    own_start = "# >>> tlogger >>>"
    own_end = "# <<< tlogger <<<"
    n_start = 0
    n_end = 0
    n_error = 0
    bad_usage = 0
    if (start_mark == "" || end_mark == "") {
        bad_usage = 1
        exit 2
    }
}

# Record an error of KIND at line number LINE_NO; END prints them sorted by line.
function add_error(error_kind, line_no) {
    n_error++
    err_kind[n_error] = error_kind
    err_line[n_error] = line_no
}

{
    line = $0 ""
    sub(/\r$/, "", line)
    if (line == start_mark) {
        n_start++
        start_line[n_start] = NR
    } else if (line == end_mark) {
        n_end++
        end_line[n_end] = NR
    } else if (line != own_start && line != own_end &&
        (index(line, start_mark) || index(line, end_mark))) {
        add_error("altered", NR)
    }
}

END {
    if (bad_usage)
        exit 2
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
