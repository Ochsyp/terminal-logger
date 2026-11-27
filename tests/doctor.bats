#!/usr/bin/env bats
# Tests for tlogger doctor in bin/tlogger, run as a subprocess in the test's own HOME. Doctor
# reads three trees that the tests fake, through variables that exist for the tests only and that
# bin/tlogger's header comment names:
#   TLOGGER_PROC   the /proc whose self/mountinfo doctor reads (bin already has it, for seal);
#   TLOGGER_SYSFS  the /sys whose dev/block, class/block and devices doctor follows (new in bin;
#                  the plugin has it for its VPN list);
#   TLOGGER_FSTAB  the file doctor reads instead of /etc/fstab (new, for the tests only).
# Logging stand-ins first on PATH (log_calls) record which tools doctor runs on which paths.
#
# The output these tests pin, on stdout:
#   tlogger doctor: <the log folder, as ~/... under HOME>
#   one line per check, printf '  %-8s %-12s %s\n' VERDICT CHECK TEXT, VERDICT ok, warn or
#   unknown, CHECK config, volume, folder, permissions or encryption;
#   the engagement line, printf '  %-21s %s\n' engagement TEXT, TEXT 'none; new sessions go into
#   the log folder' or 'NAME; new sessions go into <log folder>/NAME', followed by the check
#   lines of the engagement folder: folder, and volume, permissions and encryption too when it
#   lies on another mount than the log folder;
#   last 'No warnings. Nothing was changed.' when every check is ok, else a line that ends with
#   ' Nothing was changed.'
# Exit 0 when every check is ok, 1 on any warn or unknown, 2 on a usage error. Notes go to stderr.

bats_require_minimum_version 1.5.0

load helpers

# The last line of a run in which every check passed.
ALL_OK='No warnings. Nothing was changed.'

# The engagement line for the engagement acme in the default log folder.
ACME_LINE='  engagement            acme; new sessions go into ~/.local/state/tlogger/sessions/acme'

# The dm uuids of the fake device-mapper devices: LUKS2, two LVM volumes and a dm-verity one.
LUKS_UUID=CRYPT-LUKS2-5ca1ab1e000000000000000000000001-luks-test
LVM_UUID=LVM-5ca1ab1e00000000000000000000000000000000000000000000000000000001
LVM2_UUID=LVM-5ca1ab1e00000000000000000000000000000000000000000000000000000002
VERITY_UUID=CRYPT-VERITY-5ca1ab1e000000000000000000000003-verity-test

# The mount source of the LUKS volume, as /dev/mapper names it.
LUKS_SOURCE=/dev/mapper/luks-5ca1ab1e-0000-4000-8000-000000000001

# Run before each test by bats.
# Gives the test its own HOME with the default layout and a log folder of mode 0700, a folder V
# outside HOME for volumes, an empty fake mountinfo and fstab, and a fake sysfs with two disks
# and the device-mapper devices above them.
setup() {
    isolate_home
    isolate_tlogger
    need modes
    need symlinks
    # Doctor resolves paths, so the test's own folder must be its real path.
    if [[ $(readlink -f "$BATS_TEST_TMPDIR") != "$BATS_TEST_TMPDIR" ]]; then
        printf 'BATS_TEST_TMPDIR %s lies under a symlink\n' "$BATS_TEST_TMPDIR" >&2
        return 1
    fi
    LOGS="$HOME/.local/state/tlogger/sessions"
    CONF="$HOME/.config/tlogger"
    V="$BATS_TEST_TMPDIR/srv"
    PROC="$BATS_TEST_TMPDIR/proc"
    SYS="$BATS_TEST_TMPDIR/sys"
    FSTAB="$BATS_TEST_TMPDIR/fstab"
    MOUNT_ID=20
    mkdir -p "$LOGS" "$V" "$PROC/self"
    chmod 700 "$LOGS"
    : > "$PROC/self/mountinfo"
    : > "$FSTAB"
    fake_disks
    export TLOGGER_PROC="$PROC" TLOGGER_SYSFS="$SYS" TLOGGER_FSTAB="$FSTAB"
}

# Write the bytes TEXT as the config, in a config folder of mode 0700, as install leaves it.
write_config() {
    mkdir -p "$CONF"
    chmod 700 "$CONF"
    printf '%s' "$1" > "$CONF/config"
    chmod 600 "$CONF/config"
}

# Link the device folder DIR of the block device NAME, MAJ:MIN, into the fake sysfs as Linux
# does: class/block/NAME and dev/block/MAJ:MIN, and give it its dev and uevent files.
fake_links() {
    local dir=$1 name=$2 majmin=$3 type=$4
    mkdir -p "$SYS/class/block" "$SYS/dev/block" "$dir/holders"
    printf '%s\n' "$majmin" > "$dir/dev"
    printf 'MAJOR=%s\nMINOR=%s\nDEVNAME=%s\nDEVTYPE=%s\n' "${majmin%%:*}" "${majmin#*:}" \
        "$name" "$type" > "$dir/uevent"
    ln -s "$dir" "$SYS/class/block/$name"
    ln -s "$dir" "$SYS/dev/block/$majmin"
}

# Make the whole disk NAME, MAJ:MIN, in the fake sysfs, with an empty slaves folder.
fake_disk() {
    local dir="$SYS/devices/pci0000:00/0000:00:17.0/block/$1"
    mkdir -p "$dir/slaves"
    fake_links "$dir" "$1" "$2" disk
}

# Make the partition NAME, MAJ:MIN, number N, of the disk DISK in the fake sysfs, inside the
# disk's folder, as Linux lays it out.
fake_part() {
    local dir
    dir="$(readlink -f "$SYS/class/block/$1")/$2"
    mkdir -p "$dir"
    printf '%s\n' "$4" > "$dir/partition"
    fake_links "$dir" "$2" "$3" partition
}

# Make the device-mapper device NAME, MAJ:MIN, with the dm uuid UUID, on the devices SLAVE...:
# dm/uuid, dm/name, and a link in slaves/ to each SLAVE, whose holders/ link back.
fake_dm() {
    local name=$1 majmin=$2 uuid=$3 dir="$SYS/devices/virtual/block/$1" slave target
    shift 3
    mkdir -p "$dir/slaves" "$dir/dm"
    printf '%s\n' "$uuid" > "$dir/dm/uuid"
    printf '%s\n' "${uuid##*-}" > "$dir/dm/name"
    fake_links "$dir" "$name" "$majmin" disk
    for slave in "$@"; do
        target=$(readlink -f "$SYS/class/block/$slave")
        ln -s "$target" "$dir/slaves/$slave"
        ln -s "$dir" "$target/holders/$name"
    done
}

# The fake sysfs: the disks sda (partitions sda1, sda2) and sdb (sdb1); dm-0, LUKS2 on sda2;
# dm-1, LVM on dm-0, the Kali installer's encrypted LVM; dm-2, LVM over dm-0 and the plain sdb1;
# dm-3, dm-verity on sdb1. 254:9 is a device that sysfs does not have.
fake_disks() {
    fake_disk sda 8:0
    fake_part sda sda1 8:1 1
    fake_part sda sda2 8:2 2
    fake_disk sdb 8:16
    fake_part sdb sdb1 8:17 1
    fake_dm dm-0 254:0 "$LUKS_UUID" sda2
    fake_dm dm-1 254:1 "$LVM_UUID" dm-0
    fake_dm dm-2 254:2 "$LVM2_UUID" dm-0 sdb1
    fake_dm dm-3 254:3 "$VERITY_UUID" sdb1
}

# Add a line to the fake mountinfo for the file system TYPE from SOURCE on the device MAJ:MIN,
# mounted at MOUNT, as Linux writes it: a backslash, space, tab or newline in the mount point
# as \134, \040, \011 or \012.
mount_row() {
    local majmin=$1 mount=$2 type=$3 source=$4
    mount=${mount//\\/\\134}
    mount=${mount// /\\040}
    mount=${mount//$'\t'/\\011}
    mount=${mount//$'\n'/\\012}
    MOUNT_ID=$(( MOUNT_ID + 1 ))
    printf '%s 1 %s / %s rw,relatime shared:%s - %s %s rw\n' "$MOUNT_ID" "$majmin" "$mount" \
        "$MOUNT_ID" "$type" "$source" >> "$PROC/self/mountinfo"
}

# Mount / from the Kali installer's encrypted LVM: ext4 on dm-1, LVM on LUKS2.
root_on_lvm() {
    mount_row 254:1 / ext4 /dev/mapper/vg0-root
}

# Mount the file system TYPE from SOURCE on the device MAJ:MIN at V/evidence, with / on
# encrypted LVM, and set the config's logdir to V/evidence/tlogger, a folder of mode 0700, and
# its logdir_mount to V/evidence. The mountinfo holds only these two mounts.
volume_at() {
    : > "$PROC/self/mountinfo"
    root_on_lvm
    mount_row "$2" "$V/evidence" "$1" "$3"
    mkdir -p "$V/evidence/tlogger"
    chmod 700 "$V/evidence/tlogger"
    write_config "logdir=$V/evidence/tlogger"$'\n'"logdir_mount=$V/evidence"$'\n'
}

# Put logging stand-ins first on PATH, in a folder of the test's own: stat, df, ls, find, du,
# readlink and timeout append '<name>\t<arguments>' to CALLS and run the real tool; a tool that
# runs under the stand-in for timeout logs '<name> under timeout\t<arguments>'. cryptsetup,
# blkid, dmsetup, lsblk, findmnt, lsattr and sudo, which doctor must never run, only log.
log_calls() {
    local bin="$BATS_TEST_TMPDIR/calls-bin" name real extra
    CALLS="$BATS_TEST_TMPDIR/calls"
    mkdir -p "$bin"
    : > "$CALLS"
    for name in stat df ls find du readlink timeout; do
        real=$(command -v "$name") || continue
        extra=
        if [[ $name == timeout ]]; then
            extra='export TLOGGER_TEST_UNDER_TIMEOUT=1'
        fi
        cat > "$bin/$name" << EOF
#!/usr/bin/env bash
printf '%s%s\t%s\n' '$name' "\${TLOGGER_TEST_UNDER_TIMEOUT:+ under timeout}" "\$*" >> '$CALLS'
$extra
exec '$real' "\$@"
EOF
        chmod 755 "$bin/$name"
    done
    for name in cryptsetup blkid dmsetup lsblk findmnt lsattr sudo; do
        # The stand-in's sh expands $*, not bash.
        # shellcheck disable=SC2016
        printf '#!/bin/sh\nprintf "%%s\\t%%s\\n" %s "$*" >> '\''%s'\''\nexit 1\n' "$name" \
            "$CALLS" > "$bin/$name"
        chmod 755 "$bin/$name"
    done
    PATH="$bin:$PATH"
}

# Print the calls in CALLS of stat, df, ls, find or du that name PATH or a path below it; with
# DIRECT 1, only those that did not run under timeout.
calls_on() {
    local path=$1 direct=${2:-0} tools='^(stat|df|ls|find|du)'
    if (( ! direct )); then
        tools+='( under timeout)?'
    fi
    grep -E "$tools"$'\t' "$CALLS" | grep -F -- "$path" || true
}

# Set VERDICT and TEXT from the line of the check CHECK in PART of the last doctor run: log, the
# lines before the engagement line, or engagement, the lines after it. Fails unless exactly one
# such line is there, in the shape printf '  %-8s %-12s %s'.
doctor_check() {
    local part=$1 check=$2 line in=log want
    local -i found=0
    VERDICT='' TEXT=''
    while IFS= read -r line; do
        if [[ $line == '  engagement '* ]]; then
            in=engagement
            continue
        fi
        if [[ $in != "$part" || ! $line =~ ^\ \ ([a-z]+)\ +([a-z]+)\ +(.*)$ ||
            ${BASH_REMATCH[2]} != "$check" ]]; then
            continue
        fi
        found+=1
        VERDICT=${BASH_REMATCH[1]} TEXT=${BASH_REMATCH[3]}
        printf -v want '  %-8s %-12s %s' "$VERDICT" "$check" "$TEXT"
        if [[ $line != "$want" || ! $VERDICT =~ ^(ok|warn|unknown)$ ]]; then
            printf 'the %s line is not in the shape of a check line:\n%s\n' "$check" "$line" >&2
            return 1
        fi
    done <<< "$output"
    if (( found != 1 )); then
        printf 'expected one %s line in the %s part, found %s:\n%s\n' "$check" "$part" "$found" \
            "$output" >&2
        return 1
    fi
}

# Fail unless the line of CHECK in PART (see doctor_check) has the verdict VERDICT and its text
# holds each further argument.
assert_check() {
    local part=$1 check=$2 want=$3 piece
    shift 3
    doctor_check "$part" "$check" || return 1
    if [[ $VERDICT != "$want" ]]; then
        printf 'expected %s for %s in the %s part, got %s: %s\n%s\n' "$want" "$check" "$part" \
            "$VERDICT" "$TEXT" "$output" >&2
        return 1
    fi
    for piece in "$@"; do
        if [[ $TEXT != *"$piece"* ]]; then
            printf 'the %s line does not say %s:\n%s\n' "$check" "$piece" "$TEXT" >&2
            return 1
        fi
    done
}

# Print the checks of PART (see doctor_check) of the last doctor run, one per line, in order.
checks_of() {
    local line in=log
    while IFS= read -r line; do
        if [[ $line == '  engagement '* ]]; then
            in=engagement
        elif [[ $in == "$1" && $line =~ ^\ \ (ok|warn|unknown)\ +([a-z]+)\  ]]; then
            printf '%s\n' "${BASH_REMATCH[2]}"
        fi
    done <<< "$output"
}

# Fail unless the last doctor run exited STATUS and its output has doctor's shape: the header,
# then only check lines and one engagement line, then the last line, which is ALL_OK exactly
# when STATUS is 0. No home path may show in full.
assert_doctor() {
    local want=$1 line last i
    local -i engagement=0
    if [[ $status -ne $want ]]; then
        printf 'expected exit %s, got %s:\n%s\n%s\n' "$want" "$status" "$output" "$stderr" >&2
        return 1
    fi
    refute_home_shown || return 1
    last=${lines[${#lines[@]} - 1]}
    if [[ ${lines[0]} != 'tlogger doctor: '* ]]; then
        printf 'no doctor header:\n%s\n' "$output" >&2
        return 1
    fi
    if (( want == 0 )) && [[ $last != "$ALL_OK" ]]; then
        printf 'expected the last line %s, got:\n%s\n' "$ALL_OK" "$output" >&2
        return 1
    fi
    if (( want != 0 )) && [[ $last == "$ALL_OK" || $last != *' Nothing was changed.' ]]; then
        printf 'expected a last line that names the findings, got:\n%s\n' "$output" >&2
        return 1
    fi
    for (( i = 1; i < ${#lines[@]} - 1; i++ )); do
        line=${lines[i]}
        if [[ $line =~ ^\ \ engagement\ {12}[^\ ] ]]; then
            engagement+=1
        elif [[ ! $line =~ ^\ \ (ok\ {6}|warn\ {4}|unknown\ )\ [a-z] ]]; then
            printf 'line %s is neither a check line nor the engagement line:\n%s\n' "$i" \
                "$line" >&2
            return 1
        fi
    done
    if (( engagement != 1 )); then
        printf 'expected one engagement line, got %s:\n%s\n' "$engagement" "$output" >&2
        return 1
    fi
}

@test "doctor on a log folder on encrypted LVM prints every check ok and exits 0" {
    root_on_lvm
    printf '%s\n' '# /etc/fstab: static file system information.' \
        'UUID=5ca1ab1e-0000-4000-8000-000000000010 /     ext4 errors=remount-ro 0 1' \
        'UUID=5ca1ab1e-0000-4000-8000-000000000011 none  swap sw                0 0' > "$FSTAB"
    log_calls
    run_tlogger doctor
    assert_doctor 0
    [ "$output" = "$(printf '%s\n' 'tlogger doctor: ~/.local/state/tlogger/sessions' \
        '  ok       volume       on /, no unmounted fstab entry at or above the log folder' \
        '  ok       folder       exists, yours, mode 700' \
        '  ok       permissions  ext4 keeps Unix permissions' \
        '  ok       encryption   LUKS2, under LVM' \
        '  engagement            none; new sessions go into the log folder' \
        "$ALL_OK")" ]
    [ -z "$stderr" ]
    # The stand-ins ran, and no root tool did.
    grep -q '^readlink'$'\t' "$CALLS"
    [ "$(grep -cE '^(cryptsetup|blkid|dmsetup|lsblk|findmnt|lsattr|sudo)' "$CALLS")" -eq 0 ]
}

@test "LUKS2 without LVM counts as encrypted" {
    mount_row 254:0 / ext4 "$LUKS_SOURCE"
    run_tlogger doctor
    assert_doctor 0
    assert_check log encryption ok LUKS2
    [[ $TEXT != *LVM* ]]
}

@test "LVM over two disks, one of them plain, is a warning" {
    mount_row 254:2 / ext4 /dev/mapper/vg1-data
    run_tlogger doctor
    assert_doctor 1
    assert_check log encryption warn
    assert_check log volume ok
    assert_check log folder ok
    assert_check log permissions ok
}

@test "a plain disk is a warning that names what doctor cannot see" {
    mount_row 8:2 / ext4 /dev/sda2
    run_tlogger doctor
    assert_doctor 1
    assert_check log encryption warn 'virtual machine' self-encrypting fscrypt 'lsattr -d'
}

@test "a dm-verity layer does not count as encryption" {
    mount_row 254:3 / ext4 /dev/mapper/verity-test
    run_tlogger doctor
    assert_doctor 1
    assert_check log encryption warn
}

@test "ecryptfs and gocryptfs count as encrypted" {
    volume_at ecryptfs 0:74 "$V/.Private"
    run_tlogger doctor
    assert_doctor 0
    assert_check log encryption ok ecryptfs
    volume_at fuse.gocryptfs 0:75 "$V/.cipher"
    run_tlogger doctor
    assert_doctor 0
    assert_check log encryption ok gocryptfs
}

@test "tmpfs, nfs and sshfs are warnings, and nfs is touched only under timeout" {
    local args
    for args in 'tmpfs 0:71 tmpfs' 'nfs4 0:70 192.0.2.5:/export/evidence' \
        'fuse.sshfs 0:72 192.0.2.6:/srv/evidence'; do
        # The words are the type, the device and the source.
        # shellcheck disable=SC2086
        volume_at $args
        log_calls
        run_tlogger doctor
        assert_doctor 1
        assert_check log volume ok
        assert_check log encryption warn
        if [[ $args == nfs4* ]]; then
            [ -z "$(calls_on "$V/evidence" 1)" ]
        fi
    done
}

@test "an unknown fuse type, overlay, zfs or a device that sysfs lacks is unknown, and exits 1" {
    local args
    for args in 'fuse.foofs 0:76 foofs' 'overlay 0:77 overlay' 'zfs 0:78 rpool/evidence' \
        "ext4 254:9 /dev/mapper/gone"; do
        # The words are the type, the device and the source.
        # shellcheck disable=SC2086
        volume_at $args
        run_tlogger doctor
        assert_doctor 1
        assert_check log encryption unknown
        assert_check log volume ok
        assert_check log folder ok
        if [[ $args != fuse.* ]]; then
            assert_check log permissions ok
        fi
    done
}

@test "vfat, exfat and VMware's shared folders get the permissions warning" {
    local args
    for args in 'vfat 8:17 /dev/sdb1' 'exfat 8:17 /dev/sdb1' \
        'fuse.vmhgfs-fuse 0:73 vmhgfs-fuse'; do
        # The words are the type, the device and the source.
        # shellcheck disable=SC2086
        volume_at $args
        run_tlogger doctor
        assert_doctor 1
        assert_check log permissions warn "${args%% *}"
    done
}

@test "a log folder path through a symlink maps to the mount of its real path" {
    mount_row 8:2 / ext4 /dev/sda2
    mount_row 254:0 "$V/vault" ext4 "$LUKS_SOURCE"
    mkdir -p "$V/vault/tlogger"
    chmod 700 "$V/vault/tlogger"
    ln -s "$V/vault" "$V/link"
    write_config "logdir=$V/link/tlogger"$'\n'
    run_tlogger doctor
    assert_doctor 1
    [ "${lines[0]}" = "tlogger doctor: $V/link/tlogger" ]
    assert_check log encryption ok LUKS2
    assert_check log folder ok
    # The suggestion names the real path, which the guard at shell start compares as written.
    assert_check log volume warn "logdir_mount=$V/vault"
    [[ $TEXT != *"$V/link"* ]]
}

@test "a log folder on its own mount without logdir_mount gets the logdir_mount= line, with \\040" {
    mount_row 8:2 / ext4 /dev/sda2
    mount_row 254:0 "$V/my evidence" ext4 "$LUKS_SOURCE"
    mkdir -p "$V/my evidence/tlogger"
    chmod 700 "$V/my evidence/tlogger"
    write_config "logdir=$V/my evidence/tlogger"$'\n'
    run_tlogger doctor
    assert_doctor 1
    assert_check log volume warn "logdir_mount=$V/my evidence"
    assert_check log encryption ok LUKS2
    assert_check log permissions ok ext4
}

@test "a log folder of mode 750, a symlinked log folder and a symlinked engagement folder warn" {
    root_on_lvm
    chmod 750 "$LOGS"
    run_tlogger doctor
    assert_doctor 1
    assert_check log folder warn 750
    chmod 700 "$LOGS"
    mv "$LOGS" "$HOME/real-logs"
    ln -s "$HOME/real-logs" "$LOGS"
    run_tlogger doctor
    assert_doctor 1
    assert_check log folder warn symlink
    rm "$LOGS"
    mv "$HOME/real-logs" "$LOGS"
    mkdir -m 700 "$HOME/real-acme"
    ln -s "$HOME/real-acme" "$LOGS/acme"
    write_config $'engagement=acme\n'
    run_tlogger doctor
    assert_doctor 1
    assert_check log folder ok
    assert_check engagement folder warn symlink
}

@test "a log folder that belongs to another user is a warning" {
    if (( EUID == 0 )); then
        skip "it needs a user other than root"
    fi
    [ -d /root ]
    [ ! -O /root ]
    root_on_lvm
    write_config $'logdir=/root\n'
    run_tlogger doctor
    assert_doctor 1
    assert_check log folder warn 'another user'
}

@test "a logdir_mount with nothing mounted, or a log folder outside it, is a warning" {
    root_on_lvm
    mkdir -p "$V/evidence"
    write_config "logdir=$V/evidence/tlogger"$'\n'"logdir_mount=$V/evidence"$'\n'
    run_tlogger doctor
    assert_doctor 1
    assert_check log volume warn 'not mounted' "$V/evidence"
    [ ! -e "$V/evidence/tlogger" ]
    # Mounted, but the log folder lies elsewhere.
    mount_row 254:0 "$V/evidence" ext4 "$LUKS_SOURCE"
    mkdir -p "$V/other/tlogger"
    chmod 700 "$V/other/tlogger"
    write_config "logdir=$V/other/tlogger"$'\n'"logdir_mount=$V/evidence"$'\n'
    run_tlogger doctor
    assert_doctor 1
    assert_check log volume warn "$V/evidence"
}

@test "a logdir_mount on an automount that is not mounted: warn, unknown, and no stat or df on it" {
    root_on_lvm
    mount_row 0:60 "$V/evidence" autofs systemd-1
    mkdir -p "$V/evidence"
    write_config "logdir=$V/evidence/tlogger"$'\n'"logdir_mount=$V/evidence"$'\n'
    log_calls
    run_tlogger doctor
    assert_doctor 1
    assert_check log volume warn automount
    assert_check log folder unknown 'not mounted yet'
    assert_check log permissions unknown 'not mounted yet'
    assert_check log encryption unknown 'not mounted yet'
    # Touching the path would mount it, and for LUKS could ask for a passphrase.
    grep -q '^readlink'$'\t' "$CALLS"
    [ -z "$(calls_on "$V/evidence")" ]
}

@test "an unmounted fstab entry at or above the log folder warns with the logdir_mount= line" {
    root_on_lvm
    printf '%s\n' 'UUID=5ca1ab1e-0000-4000-8000-000000000010 / ext4 errors=remount-ro 0 1' \
        "/dev/mapper/evidence $V/evidence ext4 noauto,nofail 0 2" \
        "/dev/mapper/other $V/other ext4 noauto,nofail 0 2" \
        "/dev/mapper/old $V/evidence-old ext4 noauto,nofail 0 2" > "$FSTAB"
    mkdir -p "$V/evidence/tlogger"
    chmod 700 "$V/evidence/tlogger"
    write_config "logdir=$V/evidence/tlogger"$'\n'
    run_tlogger doctor
    assert_doctor 1
    assert_check log volume warn "logdir_mount=$V/evidence"
    [[ $TEXT != *"$V/other"* && $TEXT != *"$V/evidence-old"* ]]
    # An fstab mount point with a space, as fstab writes it.
    printf '%s\n' "/dev/mapper/evidence ${V// /\\040}/case\\040files ext4 noauto 0 2" > "$FSTAB"
    mkdir -p "$V/case files/tlogger"
    chmod 700 "$V/case files/tlogger"
    write_config "logdir=$V/case files/tlogger"$'\n'
    run_tlogger doctor
    assert_doctor 1
    assert_check log volume warn "logdir_mount=$V/case files"
}

@test "a log folder on the disk beneath an unmounted volume is named with its number of entries" {
    root_on_lvm
    mkdir -p "$V/evidence/tlogger/20261112T100000Z-a1B2c3"
    chmod 700 "$V/evidence/tlogger"
    printf 'x\n' > "$V/evidence/tlogger/MANIFEST"
    printf 'x\n' > "$V/evidence/tlogger/notes.txt"
    write_config "logdir=$V/evidence/tlogger"$'\n'"logdir_mount=$V/evidence"$'\n'
    run_tlogger doctor
    assert_doctor 1
    assert_check log volume warn
    [[ $output == *' 3 entries'* ]]
}

@test "the engagement folder gets the folder check, and a missing one is ok" {
    root_on_lvm
    write_config $'engagement=acme\n'
    run_tlogger doctor
    assert_doctor 0
    grep -qxF "$ACME_LINE" <<< "$output"
    assert_check engagement folder ok
    [[ $TEXT == 'does not exist yet'* ]]
    [ "$(checks_of engagement)" = folder ]
    [ ! -e "$LOGS/acme" ]
    mkdir -m 750 "$LOGS/acme"
    run_tlogger doctor
    assert_doctor 1
    assert_check log folder ok
    assert_check engagement folder warn 750
    chmod 700 "$LOGS/acme"
    run_tlogger doctor
    assert_doctor 0
    assert_check engagement folder ok 'exists, yours, mode 700'
}

@test "a missing engagement folder warns when no recording would create its log folder either" {
    root_on_lvm
    write_config "logdir=$V/work/tlogger"$'\n'$'engagement=acme\n'
    run_tlogger doctor
    assert_doctor 1
    assert_check log folder warn 'does not exist yet; a recording refuses'
    assert_check engagement folder warn 'does not exist yet; a recording refuses'
    [ ! -e "$V/work" ]
}

@test "an engagement folder on another mount gets the volume, permissions and encryption checks" {
    volume_at ext4 254:0 "$LUKS_SOURCE"
    printf 'engagement=acme\n' >> "$CONF/config"
    mkdir -m 700 "$V/evidence/tlogger/acme"
    mount_row 8:17 "$V/evidence/tlogger/acme" vfat /dev/sdb1
    run_tlogger doctor
    assert_doctor 1
    assert_check log volume ok
    assert_check log permissions ok
    assert_check log encryption ok LUKS2
    grep -qxF "  engagement            acme; new sessions go into $V/evidence/tlogger/acme" \
        <<< "$output"
    assert_check engagement volume warn
    assert_check engagement permissions warn vfat
    assert_check engagement encryption warn
    doctor_check engagement folder
}

@test "a config error is a warning, and doctor checks the default log folder" {
    root_on_lvm
    write_config $'mode=manual\njust text\nlogdir=/srv/work/evidence\n'
    run_tlogger doctor
    assert_doctor 1
    [ "${lines[0]}" = 'tlogger doctor: ~/.local/state/tlogger/sessions' ]
    assert_check log config warn 'has line 2, which is not a key=value line' 'default log folder'
    assert_check log folder ok
    write_config $'engagement=../x\n'
    run_tlogger doctor
    assert_doctor 1
    assert_check log config warn 'has an engagement on line 1 that is not a valid name'
    write_config $'logdir_mount=relative/evidence\n'
    run_tlogger doctor
    assert_doctor 1
    assert_check log config warn 'has a logdir_mount on line 1 that is not an absolute path'
}

@test "an exported TLOGGER_LOGDIR, TLOGGER_LOGDIR_MOUNT or TLOGGER_ENGAGEMENT gets a note" {
    local name note
    root_on_lvm
    mkdir -m 700 "$LOGS/acme"
    write_config $'engagement=acme\n'
    TLOGGER_LOGDIR=/srv/work/x TLOGGER_LOGDIR_MOUNT=/srv/work TLOGGER_ENGAGEMENT=demo \
        run_tlogger doctor
    # Doctor checked the config's values, which pass.
    assert_doctor 0
    grep -qxF "$ACME_LINE" <<< "$output"
    [ "${#stderr_lines[@]}" -eq 3 ]
    for name in TLOGGER_LOGDIR TLOGGER_LOGDIR_MOUNT TLOGGER_ENGAGEMENT; do
        note="tlogger: note: $name is set, and in this terminal it wins over the config;"
        note+=" doctor checked the config's value"
        grep -qxF "$note" <<< "$stderr"
    done
    TLOGGER_ENGAGEMENT='' run_tlogger doctor
    assert_doctor 0
    [ -z "$stderr" ]
}

@test "doctor changes nothing: a missing log folder stays missing, and a tree keeps every byte" {
    local before
    root_on_lvm
    rm -rf "$HOME/.local"
    run_tlogger doctor
    doctor_check log folder
    [[ $TEXT == 'does not exist yet'* ]]
    [ ! -e "$HOME/.local" ]
    refute_tlogger_folders
    # A missing log folder on a mounted logdir_mount is not made either.
    volume_at ext4 254:0 "$LUKS_SOURCE"
    rmdir "$V/evidence/tlogger"
    run_tlogger doctor
    [ ! -e "$V/evidence/tlogger" ]
    # A log folder with sessions, a MANIFEST and an engagement folder.
    mkdir -p "$LOGS/acme"
    chmod 700 "$LOGS" "$LOGS/acme"
    session_new "$LOGS/20261112T100000Z-a1B2c3"
    session_new "$LOGS/acme/20261112T110000Z-b2C3d4"
    printf '5ca1ab1e%056d  20261112T100000Z-a1B2c3/SHA256SUMS\n' 0 > "$LOGS/MANIFEST"
    chmod 600 "$LOGS/MANIFEST"
    write_config $'engagement=acme\n'
    before=$(find "$HOME" "$V" -printf '%p %m %s %T@\n' | LC_ALL=C sort
        sha_of "$LOGS/MANIFEST")
    run_tlogger doctor
    assert_doctor 0
    [ "$(find "$HOME" "$V" -printf '%p %m %s %T@\n' | LC_ALL=C sort
        sha_of "$LOGS/MANIFEST")" = "$before" ]
    refute_temp_left
}

@test "doctor exits 2 on an argument or an option, and -h prints the usage" {
    local arg
    root_on_lvm
    for arg in extra --fix -x; do
        run_tlogger doctor "$arg"
        [ "$status" -eq 2 ]
        [ -z "$output" ]
        [ "${stderr_lines[0]}" = 'tlogger: doctor takes no options' ]
        [[ $stderr == *$'\nUsage: tlogger <command> [options]\n'* ]]
    done
    for arg in -h --help; do
        run_tlogger doctor "$arg"
        [ "$status" -eq 0 ]
        [[ $output == "Usage: tlogger <command> [options]"* ]]
    done
}

@test "help and the usage name tlogger doctor" {
    run_tlogger help
    [ "$status" -eq 0 ]
    grep -qE '^  doctor +[A-Z]' <<< "$output"
    run_tlogger frobnicate
    [ "$status" -eq 2 ]
    grep -qE '^  doctor +[A-Z]' <<< "$stderr"
}
