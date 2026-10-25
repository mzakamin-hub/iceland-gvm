#!/usr/bin/python3 -I
"""mkcpio.py OUT.cpio.gz BUSYBOX INIT - minimal newc initramfs: /bin/busybox, /init, dirs, /dev/console."""
import gzip, os, sys, stat
out, bb, init = sys.argv[1:4]
ino = [1000]
def ent(name, mode, data=b"", rdev=(0, 0)):
    ino[0] += 1
    hdr = "070701" + "".join("%08X" % v for v in (ino[0], mode, 0, 0, 1, 0, len(data), 0, 0, rdev[0], rdev[1], len(name) + 1, 0))
    b = hdr.encode() + name.encode() + b"\0"
    b += b"\0" * ((4 - len(b) % 4) % 4)
    b += data + b"\0" * ((4 - len(data) % 4) % 4)
    return b
buf = b""
for d in ("bin", "dev", "proc", "sys", "tmp", "mnt", "root", "sbin", "usr", "usr/bin", "usr/sbin"):
    buf += ent(d, stat.S_IFDIR | 0o755)
buf += ent("dev/console", stat.S_IFCHR | 0o600, rdev=(5, 1))
buf += ent("bin/busybox", stat.S_IFREG | 0o755, open(bb, "rb").read())
buf += ent("init", stat.S_IFREG | 0o755, open(init, "rb").read())
buf += ent("TRAILER!!!", 0)
with gzip.GzipFile(out, "wb", mtime=0) as f:
    f.write(buf)
