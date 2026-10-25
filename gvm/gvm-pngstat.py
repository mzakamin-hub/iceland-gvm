#!/usr/bin/python3
"""gvm-pngstat.py FILE.png|FILE.ppm - print "PNG w=.. h=.. mean=.. nonzero=.." (RGB mean 0..1, fraction of non-black
pixels, every 4th pixel of every 4th row). Plain zlib decoder for 8-bit RGB / RGBA PNGs (Spectacle's output),
so the V5 screenshot row needs no Python imaging package on the host."""
import struct
import sys
import zlib


def ppm(d):
    """binary P6 (QEMU screendump / crosvm frame dumps), maxval 255"""
    tok, pos = [], 2
    while len(tok) < 3:
        while d[pos:pos + 1].isspace():
            pos += 1
        if d[pos:pos + 1] == b"#":
            pos = d.index(b"\n", pos) + 1
            continue
        e = pos
        while not d[e:e + 1].isspace():
            e += 1
        tok.append(int(d[pos:e]))
        pos = e
    w, h, _ = tok
    px = d[pos + 1:]
    s = nz = tot = 0
    for y in range(0, h, 4):
        row = px[y * w * 3:(y + 1) * w * 3]
        for x in range(0, len(row) - 2, 12):
            r, g, b = row[x], row[x + 1], row[x + 2]
            s += r + g + b
            nz += 1 if (r or g or b) else 0
            tot += 1
    print("PPM w=%d h=%d mean=%.3f nonzero=%.3f" % (w, h, s / 765.0 / max(tot, 1), nz / max(tot, 1)))


def main(path):
    d = open(path, "rb").read()
    if d[:2] == b"P6":
        return ppm(d)
    if d[:8] != b"\x89PNG\r\n\x1a\n":
        sys.exit("PNG error: not a PNG")
    pos, idat, w = 8, b"", 0
    while pos < len(d):
        n, typ = struct.unpack(">I4s", d[pos:pos + 8])
        body = d[pos + 8:pos + 8 + n]
        if typ == b"IHDR":
            w, h, depth, ctype, _, _, inter = struct.unpack(">IIBBBBB", body)
        elif typ == b"IDAT":
            idat += body
        elif typ == b"IEND":
            break
        pos += 12 + n
    if depth != 8 or ctype not in (2, 6) or inter:
        sys.exit("PNG error: depth %d color type %d interlace %d not handled" % (depth, ctype, inter))
    bpp = 3 if ctype == 2 else 4
    raw = zlib.decompress(idat)
    stride = w * bpp
    prev = bytearray(stride)
    s = nz = tot = 0
    mg = 0   # v10e: pure magenta pixels (the opacity check, gvm-solid.py)
    i = 0
    for y in range(h):
        f = raw[i]
        line = bytearray(raw[i + 1:i + 1 + stride])
        i += 1 + stride
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if f == 1:
                line[x] = (line[x] + a) & 255
            elif f == 2:
                line[x] = (line[x] + b) & 255
            elif f == 3:
                line[x] = (line[x] + ((a + b) >> 1)) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        prev = line
        if y % 4:
            continue
        for x in range(0, stride - bpp + 1, 4 * bpp):
            r, g, bl = line[x], line[x + 1], line[x + 2]
            s += r + g + bl
            nz += 1 if (r or g or bl) else 0
            mg += 1 if (r >= 235 and g <= 20 and bl >= 235) else 0
            tot += 1
    print("PNG w=%d h=%d mean=%.3f nonzero=%.3f magenta=%.3f" % (w, h, s / 765.0 / max(tot, 1), nz / max(tot, 1), mg / max(tot, 1)))


if __name__ == "__main__":
    main(sys.argv[1])
