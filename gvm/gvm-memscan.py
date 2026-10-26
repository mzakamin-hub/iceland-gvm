#!/usr/bin/python3
# SPDX-License-Identifier: GPL-2.0-only
"""gvm-memscan.py PID HOSTADDR SIZE MARKER - parity step 4 row PV6: show that the host can read the guest RAM of a
pseudo-unprotected (shared memory mode) VM.

Reads crosvm's own mapping of the shared window, [HOSTADDR, HOSTADDR + SIZE) as printed in crosvm's
"GH-SHIM: window ... host=0x..." line, through /proc/PID/mem and looks for MARKER (ASCII). Never anything else:
the lent boot region of the same VM, or the RAM of an ordinary protected VM, must not be touched from the host.
Prints "FOUND <offset> <MiB/s>" or "NOTFOUND <MiB read>"; exit 0 when found."""
import sys
import time

CHUNK = 16 << 20


def main(argv):
    if len(argv) != 5:
        print(__doc__)
        return 2
    pid, base, size, marker = int(argv[1]), int(argv[2], 0), int(argv[3], 0), argv[4].encode()
    if not 16 <= len(marker) <= 64:
        print("marker must be 16..64 characters")
        return 2
    # the mapping must be one of crosvm's shared (memfd) mappings and cover the whole window
    ok = False
    with open("/proc/%d/maps" % pid) as f:
        for line in f:
            r, perms = line.split()[:2]
            lo, hi = (int(x, 16) for x in r.split("-"))
            if lo <= base and base + size <= hi and perms.startswith("rw") and perms[3] == "s":
                ok = True
                break
    if not ok:
        print("NOMAP no shared rw mapping covers %#x+%#x" % (base, size))
        return 3
    t0 = time.monotonic()
    done = 0
    tail = b""
    with open("/proc/%d/mem" % pid, "rb", buffering=0) as m:
        while done < size:
            n = min(CHUNK, size - done)
            m.seek(base + done)
            data = m.read(n)
            if not data:
                break
            buf = tail + data
            i = buf.find(marker)
            if i >= 0:
                dt = max(time.monotonic() - t0, 1e-6)
                print("FOUND %#x %.0f" % (done - len(tail) + i, (done + len(data)) / dt / (1 << 20)))
                return 0
            tail = buf[-(len(marker) - 1):]
            done += len(data)
    print("NOTFOUND %d" % (done >> 20))
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
