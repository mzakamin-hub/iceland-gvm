#!/usr/bin/python3
"""gvm-kwinprobe.py list|close CAPTION - run in the Plasma session (as its user, with its session bus):
loads a KWin script that reports every window whose caption contains CAPTION back over D-Bus
(callDBus to a name this program owns, org.iceland.GvmProbe) and, for "close", closes it.
Prints one line per window: GVMWIN caption=.. class=.. desktopFile=.. noBorder=.. size=WxH
KWin's print() output does not reliably reach the journal (vm-run 24 Oct), so the answer comes back over D-Bus.
Exit 0 = KWin answered (even with no window), 1 = KWin scripting not reachable."""
import json
import os
import sys

from gi.repository import Gio, GLib

action, caption = sys.argv[1], sys.argv[2]
NAME = "org.iceland.GvmProbe"
XML = ('<node><interface name="org.iceland.GvmProbe"><method name="Report">'
       '<arg type="s" name="line" direction="in"/></method></interface></node>')
lines = []


def on_call(conn, sender, path, iface, method, params, inv):
    lines.append(params.unpack()[0])
    inv.return_value(None)


bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
bus.register_object("/", Gio.DBusNodeInfo.new_for_xml(XML).interfaces[0], on_call, None, None)
Gio.bus_own_name_on_connection(bus, NAME, Gio.BusNameOwnerFlags.NONE, None, None)
js_path = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "gvm-kwinprobe-%d.js" % os.getpid())
with open(js_path, "w") as f:
    f.write("""var t = %s; var act = %s; var n = 0;
workspace.windowList().forEach(function (w) {
    if (String(w.caption).indexOf(t) < 0) return;
    n++;
    callDBus("%s", "/", "%s", "Report", "GVMWIN caption=" + w.caption + " class=" + w.resourceClass +
        " desktopFile=" + w.desktopFileName + " noBorder=" + w.noBorder + " size=" +
        w.frameGeometry.width + "x" + w.frameGeometry.height);
    if (act == "close") w.closeWindow();
});
callDBus("%s", "/", "%s", "Report", "GVMEND windows=" + n);
""" % (json.dumps(caption), json.dumps(action), NAME, NAME, NAME, NAME))
sname = "gvm-kwinprobe-%d" % os.getpid()
rc = 1
try:
    r = bus.call_sync("org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting", "loadScript",
                      GLib.Variant("(ss)", (js_path, sname)), GLib.VariantType("(i)"), 0, 5000, None)
    sid = r.unpack()[0]
    if sid < 0:
        raise GLib.Error("loadScript returned %d" % sid)
    for path in ("/Scripting/Script%d" % sid, "/%d" % sid):      # KWin 6 / older object paths
        try:
            bus.call_sync("org.kde.KWin", path, "org.kde.kwin.Script", "run", None, None, 0, 5000, None)
            break
        except GLib.Error:
            continue
    loop = GLib.MainLoop()
    GLib.timeout_add(200, lambda: (loop.quit() if any(x.startswith("GVMEND") for x in lines) else True))
    GLib.timeout_add(5000, loop.quit)
    loop.run()
    rc = 0 if any(x.startswith("GVMEND") for x in lines) else 1
except GLib.Error as e:
    print("GVMERR %s" % e.message)
finally:
    try:
        bus.call_sync("org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting", "unloadScript",
                      GLib.Variant("(s)", (sname,)), None, 0, 5000, None)
    except GLib.Error:
        pass
    os.unlink(js_path)
for x in lines:
    print(x)
sys.exit(rc)
