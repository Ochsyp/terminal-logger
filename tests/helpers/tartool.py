# tartool.py: build and list .tar.gz archives for tests/retention.bats, so that the tests can give
# tlogger archive --verify archives that tlogger did not write, well formed or tampered, and look
# at the members of the archives that tlogger archive writes. Run it as python3 -I; stdlib only.
#
# python3 -I tartool.py pack DIR NAME OUT [OP...]
#   Write OUT, a gzip stream of a tar whose members are DIR/MANIFEST, as NAME/MANIFEST, then every
#   entry of each session folder of DIR (a folder named like a session id), as NAME/<id>/<entry>,
#   in byte order: a regular file as a regular member, a symlink as a symlink member. Each member
#   has owner 0, no user or group name, the file's mode and its time in whole seconds. Then write
#   OUT.sha256, the line '<SHA-256 of OUT>  <last part of OUT>', as sha256sum writes it. Each OP
#   adds to the archive, after the members above:
#     --add MEMBER TEXT     a regular member MEMBER that holds TEXT, mode 0400
#     --dup MEMBER          a second copy of the member MEMBER
#     --hardlink MEMBER TO  a hard link member MEMBER that names TO
#     --device MEMBER       a character device member MEMBER, mode 0400
#     --dir MEMBER          a folder member MEMBER, mode 0700
#     --trailing-same       non-zero bytes after the end of the tar, in the same gzip stream
#     --trailing-gzip       a second gzip stream of non-zero bytes after the first
#
# python3 -I tartool.py list FILE
#   Print one line per member of the .tar.gz FILE, in archive order, its fields split by tabs:
#   name, type (file, dir, symlink, hardlink, char, block, fifo or other), mode in octal, uid,
#   gid, user name, group name, size, time in whole seconds, and the SHA-256 of the data of a
#   regular member, else -.

import gzip
import hashlib
import io
import os
import re
import stat
import sys
import tarfile

SESSION_RE = re.compile(r"[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9]{6}")

TYPES = {
    tarfile.REGTYPE: "file",
    tarfile.AREGTYPE: "file",
    tarfile.DIRTYPE: "dir",
    tarfile.SYMTYPE: "symlink",
    tarfile.LNKTYPE: "hardlink",
    tarfile.CHRTYPE: "char",
    tarfile.BLKTYPE: "block",
    tarfile.FIFOTYPE: "fifo",
}


def member(name, kind=tarfile.REGTYPE, mode=0o400, mtime=1794391200, size=0):
    """Return a TarInfo NAME of the type KIND with owner 0 and no user or group name."""
    info = tarfile.TarInfo(name)
    info.type = kind
    info.mode = mode
    info.mtime = mtime
    info.size = size
    info.uid = info.gid = 0
    info.uname = info.gname = ""
    return info


def from_file(path, name):
    """Return the TarInfo and data for the file or symlink PATH as the member NAME."""
    st = os.lstat(path)
    if stat.S_ISLNK(st.st_mode):
        info = member(name, tarfile.SYMTYPE, stat.S_IMODE(st.st_mode), int(st.st_mtime))
        info.linkname = os.readlink(path)
        return info, b""
    if not stat.S_ISREG(st.st_mode):
        raise SystemExit("tartool: %s is neither a regular file nor a symlink" % path)
    with open(path, "rb") as f:
        data = f.read()
    info = member(name, tarfile.REGTYPE, stat.S_IMODE(st.st_mode), int(st.st_mtime), len(data))
    return info, data


def pack(folder, name, out, ops):
    """Write OUT and OUT.sha256 from FOLDER, with the members named NAME/..., and apply OPS."""
    items = []
    manifest = os.path.join(folder, "MANIFEST")
    if os.path.lexists(manifest):
        items.append(from_file(manifest, name + "/MANIFEST"))
    for sid in sorted(os.listdir(folder)):
        path = os.path.join(folder, sid)
        if not SESSION_RE.fullmatch(sid) or not os.path.isdir(path) or os.path.islink(path):
            continue
        for entry in sorted(os.listdir(path)):
            items.append(from_file(os.path.join(path, entry), "%s/%s/%s" % (name, sid, entry)))
    trailing_same = trailing_gzip = False
    i = 0
    while i < len(ops):
        op = ops[i]
        if op == "--add":
            data = ops[i + 2].encode("utf-8")
            items.append((member(ops[i + 1], size=len(data)), data))
            i += 3
        elif op == "--dup":
            items.extend([item for item in items if item[0].name == ops[i + 1]][:1])
            i += 2
        elif op == "--hardlink":
            info = member(ops[i + 1], tarfile.LNKTYPE)
            info.linkname = ops[i + 2]
            items.append((info, b""))
            i += 3
        elif op == "--device":
            info = member(ops[i + 1], tarfile.CHRTYPE)
            info.devmajor, info.devminor = 1, 3
            items.append((info, b""))
            i += 2
        elif op == "--dir":
            items.append((member(ops[i + 1], tarfile.DIRTYPE, 0o700), b""))
            i += 2
        elif op == "--trailing-same":
            trailing_same = True
            i += 1
        elif op == "--trailing-gzip":
            trailing_gzip = True
            i += 1
        else:
            raise SystemExit("tartool: unknown op %s" % op)
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tar:
        for info, data in items:
            tar.addfile(info, io.BytesIO(data) if info.type == tarfile.REGTYPE else None)
    raw = buf.getvalue()
    if trailing_same:
        raw += b"tlogger-trailing-data\n" * 4
    blob = gzip.compress(raw, mtime=0)
    if trailing_gzip:
        blob += gzip.compress(b"tlogger-trailing-data\n", mtime=0)
    with open(out, "wb") as f:
        f.write(blob)
    line = "%s  %s\n" % (hashlib.sha256(blob).hexdigest(), os.path.basename(out))
    with open(out + ".sha256", "wb") as f:
        f.write(line.encode("utf-8"))


def list_members(path):
    """Print one line per member of the .tar.gz PATH, as the usage above says."""
    with tarfile.open(path, mode="r:gz") as tar:
        for info in tar:
            digest = "-"
            if info.isreg():
                member = tar.extractfile(info)
                assert member is not None
                digest = hashlib.sha256(member.read()).hexdigest()
            fields = [info.name, TYPES.get(info.type, "other"), "%o" % info.mode, info.uid,
                      info.gid, info.uname, info.gname, info.size, int(info.mtime), digest]
            sys.stdout.write("\t".join(str(f) for f in fields) + "\n")


def main(argv):
    if len(argv) >= 4 and argv[0] == "pack":
        pack(argv[1], argv[2], argv[3], argv[4:])
    elif len(argv) == 2 and argv[0] == "list":
        list_members(argv[1])
    else:
        raise SystemExit("usage: tartool.py pack DIR NAME OUT [OP...] | list FILE")


if __name__ == "__main__":
    main(sys.argv[1:])
