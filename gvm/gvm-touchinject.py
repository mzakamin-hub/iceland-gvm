#!/usr/bin/python3
# SPDX-License-Identifier: GPL-2.0-only
"""gvm-touchinject.py - host-side touch injector and judge for the VM window input rows (iceland-vms 0.2-6, VIN).

  serve FIFO LOG   (root) create a uinput multi-touch screen ("gvm touch injector"), read gesture lines from FIFO,
                   append "DONE <line>" / "ERR <line>: why" to LOG; "quit" (or EOF) removes the device.
                   KWin takes it like the tablet's own touch screen (libinput), maps it to the internal output and
                   delivers wl_touch to the window under the finger: the same path a real finger takes.
  judge MODE GESTURE W H EVENTS [EX EY]
                   judge one gesture from the guest recorder's output (gvm-evrec.py, JSON lines); prints
                   "PASS text" or "FAIL text" (exit 0 / 1). MODE tablet|touchpad|touch; W H = the guest display
                   size; EX EY = where the gesture should land (0..1 of the guest display; tap / press / tap2);
                   GESTURE key = the V9-3 keyboard check (KEY_A down + up)
  fit FILE P1 P2 P3 [P4..]  affine map (least squares) from injector (device) coordinates to output coordinates,
                   from three or more calibration taps: Pk = "dx,dy,sx,sy" (device point, where it landed, both 0..1); writes FILE
  inv FILE SX SY   device coordinates for an output point (0..1) with the fit in FILE (identity without one)

Gesture lines (coordinates 0..1 of the injector's surface, i.e. the output before KWin's rotation):
  tap X Y [MS]                      one finger, MS down (default 80)
  press X Y MS                      long press
  drag X1 Y1 X2 Y2 MS               one finger moved in 20 steps
  tap2 X1 Y1 X2 Y2 [MS]             two fingers down / up together
  scroll2 X1 Y1 X2 Y2 DX DY MS      two fingers down, both moved by DX DY in 20 steps, up
  wait MS
Needs: /dev/uinput (modprobe uinput), root. Nothing persistent: the device exists only while serve runs."""
import fcntl
import json
import os
import struct
import sys
import time

EV_SYN, EV_KEY, EV_ABS, EV_REL = 0, 1, 3, 2
SYN_REPORT = 0
BTN_LEFT, BTN_RIGHT, BTN_TOUCH = 0x110, 0x111, 0x14a
BTN_TOOL_FINGER, BTN_TOOL_DOUBLETAP = 0x145, 0x14d
ABS_X, ABS_Y = 0x00, 0x01
ABS_MT_SLOT, ABS_MT_POSITION_X, ABS_MT_POSITION_Y, ABS_MT_TRACKING_ID = 0x2f, 0x35, 0x36, 0x39
REL_X, REL_Y, REL_HWHEEL, REL_WHEEL = 0x00, 0x01, 0x06, 0x08
KEY_A = 30
INPUT_PROP_DIRECT = 0x01
MAXV = 32767


def _ioc(d, t, nr, size):
    return (d << 30) | (size << 16) | (ord(t) << 8) | nr


UI_DEV_CREATE = _ioc(0, "U", 1, 0)
UI_DEV_DESTROY = _ioc(0, "U", 2, 0)
UI_DEV_SETUP = _ioc(1, "U", 3, 92)       # struct uinput_setup: input_id (8) + name[80] + ff_effects_max (4)
UI_ABS_SETUP = _ioc(1, "U", 4, 28)       # struct uinput_abs_setup: code (u16 + pad) + input_absinfo (6 x s32)
UI_SET_EVBIT = _ioc(1, "U", 100, 4)
UI_SET_KEYBIT = _ioc(1, "U", 101, 4)
UI_SET_ABSBIT = _ioc(1, "U", 103, 4)
UI_SET_PROPBIT = _ioc(1, "U", 110, 4)


class Touch:
    def __init__(self):
        self.fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
        for ev in (EV_SYN, EV_KEY, EV_ABS):
            fcntl.ioctl(self.fd, UI_SET_EVBIT, ev)
        for k in (BTN_TOUCH, BTN_TOOL_FINGER, BTN_TOOL_DOUBLETAP):
            fcntl.ioctl(self.fd, UI_SET_KEYBIT, k)
        fcntl.ioctl(self.fd, UI_SET_PROPBIT, INPUT_PROP_DIRECT)
        for code, mx in ((ABS_X, MAXV), (ABS_Y, MAXV), (ABS_MT_SLOT, 9), (ABS_MT_POSITION_X, MAXV),
                         (ABS_MT_POSITION_Y, MAXV), (ABS_MT_TRACKING_ID, 65535)):
            fcntl.ioctl(self.fd, UI_SET_ABSBIT, code)
            fcntl.ioctl(self.fd, UI_ABS_SETUP, struct.pack("HHiiiiii", code, 0, 0, 0, mx, 0, 0, 0))
        name = b"gvm touch injector"
        fcntl.ioctl(self.fd, UI_DEV_SETUP, struct.pack("HHHH80sI", 0x06, 0x1d6b, 0x0104, 1, name, 0))
        fcntl.ioctl(self.fd, UI_DEV_CREATE)
        self.tid = 100
        self.down = {}     # slot -> (x, y)

    def close(self):
        try:
            fcntl.ioctl(self.fd, UI_DEV_DESTROY)
        finally:
            os.close(self.fd)

    def _ev(self, t, c, v):
        now = time.time()
        os.write(self.fd, struct.pack("qqHHi", int(now), int((now % 1) * 1e6), t, c, v))

    def _syn(self):
        self._ev(EV_SYN, SYN_REPORT, 0)

    @staticmethod
    def _px(v):
        return max(0, min(MAXV, int(round(float(v) * MAXV))))

    def frame(self, fingers):
        """fingers: {slot: (x, y) or None}; None lifts the finger."""
        was = len(self.down)
        for slot, p in sorted(fingers.items()):
            self._ev(EV_ABS, ABS_MT_SLOT, slot)
            if p is None:
                self._ev(EV_ABS, ABS_MT_TRACKING_ID, -1)
                self.down.pop(slot, None)
                continue
            if slot not in self.down:
                self.tid = (self.tid + 1) % 65535
                self._ev(EV_ABS, ABS_MT_TRACKING_ID, self.tid)
            x, y = self._px(p[0]), self._px(p[1])
            self._ev(EV_ABS, ABS_MT_POSITION_X, x)
            self._ev(EV_ABS, ABS_MT_POSITION_Y, y)
            self.down[slot] = (x, y)
        now = len(self.down)
        if (was == 0) != (now == 0):
            self._ev(EV_KEY, BTN_TOUCH, 1 if now else 0)
        if was != now:
            self._ev(EV_KEY, BTN_TOOL_FINGER, 1 if now == 1 else 0)
            self._ev(EV_KEY, BTN_TOOL_DOUBLETAP, 1 if now == 2 else 0)
        if self.down:   # single-touch emulation: the first finger
            x, y = self.down[min(self.down)]
            self._ev(EV_ABS, ABS_X, x)
            self._ev(EV_ABS, ABS_Y, y)
        self._syn()

    def gesture(self, words):
        g = words[0]
        a = [float(w) for w in words[1:]]
        if g == "wait":
            time.sleep(a[0] / 1000.0)
        elif g in ("tap", "press"):
            ms = a[2] if len(a) > 2 else 80
            self.frame({0: (a[0], a[1])})
            time.sleep(ms / 1000.0)
            self.frame({0: None})
        elif g == "drag":
            x1, y1, x2, y2, ms = a[:5]
            self.frame({0: (x1, y1)})
            for i in range(1, 21):
                time.sleep(ms / 1000.0 / 20)
                self.frame({0: (x1 + (x2 - x1) * i / 20, y1 + (y2 - y1) * i / 20)})
            time.sleep(0.03)
            self.frame({0: None})
        elif g == "tap2":
            ms = a[4] if len(a) > 4 else 100
            self.frame({0: (a[0], a[1]), 1: (a[2], a[3])})
            time.sleep(ms / 1000.0)
            self.frame({0: None, 1: None})
        elif g == "scroll2":
            x1, y1, x2, y2, dx, dy, ms = a[:7]
            self.frame({0: (x1, y1), 1: (x2, y2)})
            for i in range(1, 21):
                time.sleep(ms / 1000.0 / 20)
                f = i / 20.0
                self.frame({0: (x1 + dx * f, y1 + dy * f), 1: (x2 + dx * f, y2 + dy * f)})
            time.sleep(0.03)
            self.frame({0: None, 1: None})
        else:
            raise ValueError("unknown gesture %r" % g)


def serve(fifo, log):
    t = Touch()
    with open(log, "a", buffering=1) as lg:
        lg.write("READY gvm touch injector (uinput, %d steps)\n" % MAXV)
        try:
            while True:
                with open(fifo) as f:      # blocks until a writer opens it; EOF when the last writer closes
                    for line in f:
                        w = line.split()
                        if not w:
                            continue
                        if w[0] == "quit":
                            lg.write("DONE quit\n")
                            return
                        try:
                            t.gesture(w)
                            lg.write("DONE %s\n" % line.strip())
                        except Exception as e:  # noqa: BLE001 - reported to the caller, the device stays
                            lg.write("ERR %s: %s\n" % (line.strip(), e))
        finally:
            t.close()


# ---- judge ------------------------------------------------------------------------------------------------
def load_events(path):
    devs, evs, inits = [], [], []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                o = json.loads(line)
            except ValueError:
                continue
            if "dev" in o:
                devs.append(o["dev"])
            elif "init" in o:
                inits.append(o)
            elif "d" in o:
                evs.append(o)
    return devs, inits + evs


def kind(name):
    n = name.lower()
    if "tablet" in n:
        return "tablet"
    if "mouse" in n:
        return "mouse"
    if "keyboard" in n:
        return "keyboard"
    if "touch" in n:
        return "touch"
    return "other"


class Dev:
    def __init__(self):
        self.keys = []          # (t, code, value)
        self.absv = {}          # code -> last value
        self.abs_at_key = {}    # (code, value) -> (x, y) at the first such key event
        self.abs_moves = 0
        self.abs_path = []      # (x, y) while BTN_LEFT / BTN_TOUCH is down
        self.rel = {}           # code -> sum
        self.wheel_events = 0
        self.slot = 0
        self.ids = {}           # slot -> tracking id
        self.max_ids = 0
        self.n = 0


def pos(d, k):
    """Current (x, y) of a device: the MT slot position for a touch screen (p4 VINX: it has no ABS_X events),
    ABS_X / ABS_Y otherwise, each falling back to the other."""
    mt = (d.absv.get(ABS_MT_POSITION_X), d.absv.get(ABS_MT_POSITION_Y))
    st = (d.absv.get(ABS_X), d.absv.get(ABS_Y))
    first, second = (mt, st) if k == "touch" else (st, mt)
    return tuple(a if a is not None else b for a, b in zip(first, second))


def analyse(evs):
    out = {}
    for e in evs:
        if "init" in e:      # recorder start state: the current axis values, not an event
            out.setdefault(kind(e["init"]), Dev()).absv[e["c"]] = e["v"]
            continue
        k = kind(e["d"])
        d = out.setdefault(k, Dev())
        d.n += 1
        ty, c, v = e["ty"], e["c"], e["v"]
        if ty == EV_KEY:
            d.keys.append((e["t"], c, v))
            if (c, v) not in d.abs_at_key:
                d.abs_at_key[(c, v)] = pos(d, k)
        elif ty == EV_ABS:
            if c == ABS_MT_SLOT:
                d.slot = v
            elif c == ABS_MT_TRACKING_ID:
                if v < 0:
                    d.ids.pop(d.slot, None)
                else:
                    d.ids[d.slot] = v
                d.max_ids = max(d.max_ids, len(d.ids))
            else:
                d.absv[c] = v
                if c in (ABS_X, ABS_Y, ABS_MT_POSITION_X, ABS_MT_POSITION_Y):
                    d.abs_moves += 1
                    held = any(k for k in d.keys if k[1] in (BTN_LEFT, BTN_TOUCH)) and \
                        [k for k in d.keys if k[1] in (BTN_LEFT, BTN_TOUCH)][-1][2] == 1
                    if held:
                        d.abs_path.append(tuple(a or 0 for a in pos(d, k)))
        elif ty == EV_REL:
            d.rel[c] = d.rel.get(c, 0) + v
            if c in (REL_WHEEL, REL_HWHEEL):
                d.wheel_events += 1
    return out


def clicks(d, code):
    """(downs, ups) of one button."""
    if d is None:
        return 0, 0
    return (sum(1 for k in d.keys if k[1] == code and k[2] == 1), sum(1 for k in d.keys if k[1] == code and k[2] == 0))


def landed(d, code, w, h):
    if d is None or (code, 1) not in d.abs_at_key:
        return None
    x, y = d.abs_at_key[(code, 1)]
    if x is None or y is None:
        return None
    return (x / float(w), y / float(h))


def near(p, ex, tol=0.04):
    return p is not None and abs(p[0] - ex[0]) <= tol and abs(p[1] - ex[1]) <= tol


def fmt(p):
    return "(%.3f,%.3f)" % p if p else "(none)"


def judge(mode, gesture, w, h, path, expect=None):
    devs, evs = load_events(path)
    a = analyse(evs)
    tab, mou, tch = a.get("tablet"), a.get("mouse"), a.get("touch")
    summary = "events: %s" % ", ".join("%s=%d" % (k, v.n) for k, v in sorted(a.items()) if v.n) or "no events"
    if gesture == "devices":
        kinds = sorted(set(kind(n) for n in devs))
        want = {"tablet": ["mouse", "tablet", "touch"], "touchpad": ["mouse", "tablet", "touch"], "touch": ["touch"]}[mode]
        have = [k for k in kinds if k in ("mouse", "tablet", "touch")]
        ok = have == want
        return ok, "guest input devices %s (want %s): %s" % (have, want, "; ".join(devs))
    if not [e for e in evs if "d" in e]:
        return False, "no guest input events (%d devices: %s)" % (len(devs), "; ".join(devs))
    if gesture == "key":     # 0.2-7 V9-3: one RFB key (a) -> the guest keyboard: KEY_A down + up
        kb = a.get("keyboard")
        dn = sum(1 for k in (kb.keys if kb else []) if k[1] == KEY_A and k[2] == 1)
        up = sum(1 for k in (kb.keys if kb else []) if k[1] == KEY_A and k[2] == 0)
        return dn == 1 and up == 1, "keyboard KEY_A %d/%d; %s" % (dn, up, summary)
    if mode == "tablet":
        pad = tch.n if tch else 0
        if gesture in ("tap", "press", "tap2"):
            code = BTN_RIGHT if gesture != "tap" else BTN_LEFT
            other = BTN_LEFT if code == BTN_RIGHT else BTN_RIGHT
            dn, up = clicks(tab, code)
            odn, _ = clicks(tab, other)
            p = landed(tab, code, w, h)
            ok = dn == 1 and up == 1 and odn == 0 and pad == 0
            if ok and expect and gesture != "tap2":
                ok = near(p, expect)
            return ok, "tablet %s: %s %d/%d, other button %d, at %s%s, touch-screen events %d; %s" % (
                gesture, "BTN_LEFT" if code == BTN_LEFT else "BTN_RIGHT", dn, up, odn, fmt(p),
                (" (want %s)" % fmt(tuple(expect))) if expect else "", pad, summary)
        if gesture == "drag":
            dn, up = clicks(tab, BTN_LEFT)
            path_ = tab.abs_path if tab else []
            trav = 0.0
            if len(path_) >= 2:
                trav = max(abs(path_[-1][0] - path_[0][0]) / float(w), abs(path_[-1][1] - path_[0][1]) / float(h))
            ok = dn == 1 and up == 1 and len(path_) >= 3 and trav >= 0.05 and clicks(tab, BTN_RIGHT)[0] == 0
            return ok, "tablet drag: BTN_LEFT %d/%d, %d moves while held, travel %.3f; %s" % (dn, up, len(path_), trav, summary)
        if gesture == "scroll2":
            wv, wh = (tab.rel.get(REL_WHEEL, 0), tab.rel.get(REL_HWHEEL, 0)) if tab else (0, 0)
            btn = sum(clicks(tab, c)[0] for c in (BTN_LEFT, BTN_RIGHT))
            ok = (abs(wv) + abs(wh)) >= 2 and btn == 0
            return ok, "tablet two-finger scroll: wheel %d, hwheel %d (%d events), buttons %d; %s" % (
                wv, wh, tab.wheel_events if tab else 0, btn, summary)
    if mode == "touchpad":
        if gesture in ("tap", "press", "tap2"):
            code = BTN_RIGHT if gesture != "tap" else BTN_LEFT
            other = BTN_LEFT if code == BTN_RIGHT else BTN_RIGHT
            dn, up = clicks(mou, code)
            odn, _ = clicks(mou, other)
            tb = sum(clicks(tab, c)[0] for c in (BTN_LEFT, BTN_RIGHT))
            ok = dn == 1 and up == 1 and odn == 0 and tb == 0
            return ok, "touchpad %s: mouse %s %d/%d, other button %d, tablet buttons %d; %s" % (
                gesture, "BTN_LEFT" if code == BTN_LEFT else "BTN_RIGHT", dn, up, odn, tb, summary)
        if gesture == "drag":
            dx, dy = (mou.rel.get(REL_X, 0), mou.rel.get(REL_Y, 0)) if mou else (0, 0)
            btn = sum(clicks(mou, c)[0] for c in (BTN_LEFT, BTN_RIGHT))
            ok = max(abs(dx), abs(dy)) >= 20 and btn == 0
            return ok, "touchpad drag: relative motion %+d,%+d px, buttons %d; %s" % (dx, dy, btn, summary)
        if gesture == "scroll2":
            wv = mou.rel.get(REL_WHEEL, 0) if mou else 0
            wh = tab.rel.get(REL_HWHEEL, 0) if tab else 0     # 0.3-35: horizontal scroll on the tablet's hwheel
            btn = sum(clicks(mou, c)[0] for c in (BTN_LEFT, BTN_RIGHT))
            mv = (abs(mou.rel.get(REL_X, 0)) + abs(mou.rel.get(REL_Y, 0))) if mou else 0
            ok = (abs(wv) + abs(wh)) >= 2 and btn == 0
            return ok, "touchpad two-finger scroll: wheel %d, hwheel %d, buttons %d, pointer motion %d; %s" % (
                wv, wh, btn, mv, summary)
    if mode == "touch":
        oth = (tab.n if tab else 0) + (mou.n if mou else 0)
        if gesture in ("tap", "press"):
            dn, up = clicks(tch, BTN_TOUCH)
            p = landed(tch, BTN_TOUCH, w, h)
            held = 0.0
            if tch:
                td = [k[0] for k in tch.keys if k[1] == BTN_TOUCH and k[2] == 1]
                tu = [k[0] for k in tch.keys if k[1] == BTN_TOUCH and k[2] == 0]
                if td and tu:
                    held = tu[-1] - td[0]
            ok = dn == 1 and up == 1 and oth == 0
            if gesture == "press":
                ok = ok and held >= 0.8
            if ok and expect:
                ok = near(p, expect)
            return ok, "touch %s: BTN_TOUCH %d/%d held %.2f s at %s%s, pointer events %d; %s" % (
                gesture, dn, up, held, fmt(p), (" (want %s)" % fmt(tuple(expect))) if expect else "", oth, summary)
        if gesture == "drag":
            path_ = tch.abs_path if tch else []
            trav = 0.0
            if len(path_) >= 2:
                trav = max(abs(path_[-1][0] - path_[0][0]) / float(w), abs(path_[-1][1] - path_[0][1]) / float(h))
            ok = len(path_) >= 3 and trav >= 0.05
            return ok, "touch drag: %d positions while touching, travel %.3f; %s" % (len(path_), trav, summary)
        if gesture in ("tap2", "scroll2"):
            m = tch.max_ids if tch else 0
            ok = m >= 2 and oth == 0
            return ok, "touch two fingers (%s): %d contacts at once (multi-touch slots), pointer events %d; %s" % (
                gesture, m, oth, summary)
    return False, "unknown mode / gesture %s / %s" % (mode, gesture)


# ---- calibration --------------------------------------------------------------------------------------------
def _solve3(a, b):
    """Solve the 3x3 system a x = b (Cramer); None if singular."""
    def det(m):
        return (m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
                + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]))
    d = det(a)
    if abs(d) < 1e-12:
        return None
    out = []
    for k in range(3):
        m = [row[:] for row in a]
        for r in range(3):
            m[r][k] = b[r]
        out.append(det(m) / d)
    return out


def fit(path, pts):
    """pts: [(dx, dy, sx, sy)], at least 3 not on one line: least-squares affine s = M d + c."""
    ata = [[0.0] * 3 for _ in range(3)]
    atx, aty = [0.0] * 3, [0.0] * 3
    for dx, dy, sx, sy in pts:
        row = (dx, dy, 1.0)
        for r in range(3):
            for k in range(3):
                ata[r][k] += row[r] * row[k]
            atx[r] += row[r] * sx
            aty[r] += row[r] * sy
    px, py = _solve3(ata, atx), _solve3(ata, aty)
    if px is None or py is None:
        raise ValueError("calibration points are on one line")
    m = [[px[0], px[1]], [py[0], py[1]]]
    c = [px[2], py[2]]
    with open(path, "w") as f:
        json.dump({"m": m, "c": c}, f)
    # how the output is turned relative to the injector (KWin applies the output's transform to touch)
    r = [[int(round(v)) for v in row] for row in m]
    names = {((1, 0), (0, 1)): "normal", ((0, -1), (1, 0)): "rot90", ((-1, 0), (0, -1)): "rot180",
             ((0, 1), (-1, 0)): "rot270", ((0, 1), (1, 0)): "transpose", ((0, -1), (-1, 0)): "anti-transpose",
             ((-1, 0), (0, 1)): "flip-x", ((1, 0), (0, -1)): "flip-y"}
    return m, c, names.get(tuple(tuple(x) for x in r), "other")


def inv(path, sx, sy):
    try:
        with open(path) as f:
            o = json.load(f)
    except (OSError, ValueError):
        return sx, sy
    (a, b), (cc, d) = o["m"]
    det = a * d - b * cc
    if abs(det) < 1e-6:
        return sx, sy
    x, y = sx - o["c"][0], sy - o["c"][1]
    return (d * x - b * y) / det, (-cc * x + a * y) / det


def main(argv):
    if len(argv) >= 3 and argv[0] == "serve":
        serve(argv[1], argv[2])
        return 0
    if len(argv) >= 6 and argv[0] == "judge":
        ex = (float(argv[6]), float(argv[7])) if len(argv) >= 8 else None
        ok, text = judge(argv[1], argv[2], int(argv[3]), int(argv[4]), argv[5], ex)
        print(("PASS " if ok else "FAIL ") + text)
        return 0 if ok else 1
    if len(argv) >= 5 and argv[0] == "fit":
        # p3: a malformed point (an empty landing position) gave a traceback; skip it, need >= 3
        pts = []
        for p in argv[2:]:
            try:
                v = tuple(float(x) for x in p.split(","))
            except ValueError:
                continue
            if len(v) == 4:
                pts.append(v)
        if len(pts) < 3:
            print("FAIL fit needs 3 points, got %d usable of %d" % (len(pts), len(argv) - 2))
            return 1
        try:
            m, c, name = fit(argv[1], pts)
        except ValueError as e:
            print("FAIL fit: %s" % e)
            return 1
        ok = name != "other"
        print("%s fit %s m=[[%.3f,%.3f],[%.3f,%.3f]] c=[%.3f,%.3f]" % ("PASS" if ok else "FAIL", name,
              m[0][0], m[0][1], m[1][0], m[1][1], c[0], c[1]))
        return 0 if ok else 1
    if len(argv) == 4 and argv[0] == "inv":
        x, y = inv(argv[1], float(argv[2]), float(argv[3]))
        print("%.4f %.4f" % (x, y))
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
