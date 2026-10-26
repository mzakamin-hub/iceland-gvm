#!/usr/bin/python3
# SPDX-License-Identifier: GPL-2.0-only
"""gvm-vncprobe.py - a minimal RFB (VNC) client for the V9 rows (iceland-vms 0.2-7): no dependencies.

  frame HOST PORT [PPM]       handshake (RFB 3.8 / 3.7 / 3.3, security None), one full raw framebuffer;
                              prints "VNCPROBE frame w= h= name= mean= nonzero= secs=" (and writes PPM)
  key HOST PORT KEYSYM        a key press + release (KEYSYM hex, e.g. 0x61 = a)
  pointer HOST PORT X Y [MASK] [HOLD_MS]   pointer to X,Y, buttons MASK (1 left, 4 right) down, then up
  security HOST PORT          prints the security types the server offers ("VNCPROBE security 1 2")
Exit 0 on success. Only the "None" security type is spoken (the rows run on 127.0.0.1); a server that
asks for a password is reported as "VNCPROBE needs-password" (exit 3)."""
import socket
import struct
import sys
import time


def recvn(s, n):
    b = b""
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c:
            raise EOFError("server closed the connection after %d of %d bytes" % (len(b), n))
        b += c
    return b


def handshake(host, port, want_types=False):
    s = socket.create_connection((host, int(port)), timeout=15)
    ver = recvn(s, 12)
    if not ver.startswith(b"RFB "):
        raise ValueError("not an RFB server: %r" % ver)
    major, minor = int(ver[4:7]), int(ver[8:11])
    minor = 8 if (major, minor) >= (3, 8) else (7 if (major, minor) >= (3, 7) else 3)
    s.sendall(b"RFB 003.%03d\n" % minor)
    if minor >= 7:
        n = recvn(s, 1)[0]
        if n == 0:
            ln = struct.unpack(">I", recvn(s, 4))[0]
            raise ValueError("server refused: %s" % recvn(s, ln).decode("utf-8", "replace"))
        types = list(recvn(s, n))
        if want_types:
            return s, types
        if 1 not in types:
            print("VNCPROBE needs-password types=%s" % types)
            sys.exit(3)
        s.sendall(b"\x01")
        if minor == 8:
            if struct.unpack(">I", recvn(s, 4))[0] != 0:
                raise ValueError("security handshake failed")
    else:
        t = struct.unpack(">I", recvn(s, 4))[0]
        if want_types:
            return s, [t]
        if t != 1:
            print("VNCPROBE needs-password type=%d" % t)
            sys.exit(3)
    s.sendall(b"\x01")                                   # ClientInit: shared
    w, h = struct.unpack(">HH", recvn(s, 4))
    pf = recvn(s, 16)
    ln = struct.unpack(">I", recvn(s, 4))[0]
    name = recvn(s, ln).decode("utf-8", "replace")
    return s, (w, h, pf, name)


def frame(host, port, ppm=None):
    t0 = time.time()
    s, (w, h, _pf, name) = handshake(host, port)
    # SetPixelFormat: 32 bpp, depth 24, little endian, true colour, r/g/b max 255, shifts 16/8/0
    s.sendall(struct.pack(">BxxxBBBBHHHBBBxxx", 0, 32, 24, 0, 1, 255, 255, 255, 16, 8, 0))
    s.sendall(struct.pack(">BxHi", 2, 1, 0))             # SetEncodings: raw only
    s.sendall(struct.pack(">BBHHHH", 3, 0, 0, 0, w, h))  # FramebufferUpdateRequest, full
    fb = bytearray(w * h * 4)
    got = 0
    while got < w * h:
        mt = recvn(s, 1)[0]
        if mt == 2:                                      # Bell
            continue
        if mt == 3:                                      # ServerCutText
            recvn(s, 3)
            recvn(s, struct.unpack(">I", recvn(s, 4))[0])
            continue
        if mt == 1:                                      # SetColourMapEntries (not expected)
            _pad, _first, n = struct.unpack(">BHH", recvn(s, 5))
            recvn(s, n * 6)
            continue
        if mt != 0:
            raise ValueError("unexpected message type %d" % mt)
        nrect = struct.unpack(">xH", recvn(s, 3))[0]
        for _ in range(nrect):
            x, y, rw, rh, enc = struct.unpack(">HHHHi", recvn(s, 12))
            if enc == 0:
                data = recvn(s, rw * rh * 4)
                for r in range(rh):
                    o = ((y + r) * w + x) * 4
                    fb[o:o + rw * 4] = data[r * rw * 4:(r + 1) * rw * 4]
                got += rw * rh
            elif enc in (-239, -232, -223):              # cursor / pointer pos / desktop size pseudo
                if enc == -239:
                    recvn(s, rw * rh * 4 + ((rw + 7) // 8) * rh)
            else:
                raise ValueError("unexpected encoding %d" % enc)
        if got < w * h:                                  # ask for the rest
            s.sendall(struct.pack(">BBHHHH", 3, 0, 0, 0, w, h))
    s.close()
    step = max(1, (w * h) // 4096)
    tot = nz = n = 0
    for i in range(0, w * h, step):
        b, g, r = fb[i * 4], fb[i * 4 + 1], fb[i * 4 + 2]
        v = r + g + b
        tot += v
        nz += v > 24
        n += 1
    if ppm:
        with open(ppm, "wb") as f:
            f.write(b"P6\n%d %d\n255\n" % (w, h))
            out = bytearray(w * h * 3)
            out[0::3], out[1::3], out[2::3] = fb[2::4], fb[1::4], fb[0::4]
            f.write(out)
    print("VNCPROBE frame w=%d h=%d name=%s mean=%.3f nonzero=%.3f secs=%.1f" % (
        w, h, name.replace(" ", "_"), tot / (n * 765.0), nz / float(n), time.time() - t0))
    return 0


def key(host, port, keysym):
    s, (w, h, _pf, _name) = handshake(host, port)
    k = int(keysym, 0)
    s.sendall(struct.pack(">BBxxI", 4, 1, k))
    time.sleep(0.08)
    s.sendall(struct.pack(">BBxxI", 4, 0, k))
    time.sleep(0.3)
    s.close()
    print("VNCPROBE key 0x%x sent (%dx%d)" % (k, w, h))
    return 0


def pointer(host, port, x, y, mask=1, hold_ms=80):
    s, (w, h, _pf, _name) = handshake(host, port)
    x, y, mask = int(x), int(y), int(mask)
    s.sendall(struct.pack(">BBHH", 5, 0, x, y))          # move first (hover)
    time.sleep(0.05)
    s.sendall(struct.pack(">BBHH", 5, mask, x, y))
    time.sleep(int(hold_ms) / 1000.0)
    s.sendall(struct.pack(">BBHH", 5, 0, x, y))
    time.sleep(0.3)
    s.close()
    print("VNCPROBE pointer %d,%d mask %d sent (%dx%d)" % (x, y, mask, w, h))
    return 0


def security(host, port):
    s, types = handshake(host, port, want_types=True)
    s.close()
    print("VNCPROBE security %s" % " ".join(str(t) for t in types))
    return 0


def main(a):
    try:
        if len(a) >= 3 and a[0] == "frame":
            return frame(a[1], a[2], a[3] if len(a) > 3 else None)
        if len(a) == 4 and a[0] == "key":
            return key(a[1], a[2], a[3])
        if len(a) >= 5 and a[0] == "pointer":
            return pointer(*a[1:7])
        if len(a) == 3 and a[0] == "security":
            return security(a[1], a[2])
    except (OSError, EOFError, ValueError, struct.error) as e:
        print("VNCPROBE error %s" % e)
        return 1
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
