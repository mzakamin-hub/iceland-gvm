#!/usr/bin/python3
"""gvm-kwinprobe.py list|close|activate|fullscreen|unfullscreen|watch CAPTION - run in the Plasma session (as its user, with its session bus):
loads a KWin script that reports every window whose caption contains CAPTION back over D-Bus
(callDBus to a name this program owns, org.iceland.GvmProbe) and, for "close", closes it; "activate" raises it,
"fullscreen" / "unfullscreen" (0.2-6, the app's fullscreen toggle and the VIN rows) change its fullscreen state
(the line reports the state before the change); "watch" streams GVMEV lines (activations, fullscreen /
geometry / minimized changes of the matching windows, windows added / removed) for WATCH_SECONDS (default 600).
Prints one line per window: GVMWIN caption=.. class=.. desktopFile=.. noBorder=.. size=WxH
client=X,Y,W,H (logical px, the content area) fullscreen=true|false output=<connector>
KWin's print() output does not reliably reach the journal (vm-run 24 Oct), so the answer comes back over D-Bus.
Exit 0 = KWin answered (even with no window), 1 = KWin scripting not reachable."""
import json
import os
import sys

from gi.repository import Gio, GLib

action, caption = sys.argv[1], sys.argv[2]
NAME = "org.iceland.GvmProbe"
# p3: one bus name per process (the VIN watch and the one-shot probes ran at the same time and the watcher took
# every answer: VI-0 / VI-W1 / VI-F1 "no window")
SVC = "%s.p%d" % (NAME, os.getpid())
XML = ('<node><interface name="org.iceland.GvmProbe"><method name="Report">'
       '<arg type="s" name="line" direction="in"/></method></interface></node>')
lines = []


def on_call(conn, sender, path, iface, method, params, inv):
    lines.append(params.unpack()[0])
    inv.return_value(None)


bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
bus.register_object("/", Gio.DBusNodeInfo.new_for_xml(XML).interfaces[0], on_call, None, None)
Gio.bus_own_name_on_connection(bus, SVC, Gio.BusNameOwnerFlags.NONE, None, None)
js_path = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "gvm-kwinprobe-%d.js" % os.getpid())
with open(js_path, "w") as f:
    f.write("""var t = %s; var act = %s; var n = 0;
workspace.windowList().forEach(function (w) {
    if (String(w.caption).indexOf(t) < 0) return;
    n++;
    callDBus("%s", "/", "%s", "Report", "GVMWIN caption=" + w.caption + " class=" + w.resourceClass +
        " desktopFile=" + w.desktopFileName + " noBorder=" + w.noBorder + " size=" +
        w.frameGeometry.width + "x" + w.frameGeometry.height +
        " client=" + w.clientGeometry.x + "," + w.clientGeometry.y + "," + w.clientGeometry.width + "," +
        w.clientGeometry.height + " fullscreen=" + w.fullScreen + " active=" + w.active +
        " activeWindow=" + (workspace.activeWindow ? String(workspace.activeWindow.caption).replace(/ /g, "_") : "none") + " output=" + (w.output ? w.output.name + " outgeo=" + w.output.geometry.x + "," + w.output.geometry.y + "," + w.output.geometry.width + "," + w.output.geometry.height : "?"));
    if (act == "close") w.closeWindow();
    if (act == "activate") { w.minimized = false; workspace.activeWindow = w; }
    if (act == "fullscreen") { w.minimized = false; w.fullScreen = true; workspace.activeWindow = w; }
    if (act == "unfullscreen") { w.fullScreen = false; workspace.activeWindow = w; }
});
if (act != "watch") callDBus("%s", "/", "%s", "Report", "GVMEND windows=" + n);
""" % (json.dumps(caption), json.dumps(action), SVC, NAME, SVC, NAME))
    if action == "watch":
        # p1 (VIN interference vs bug): every activation, fullscreen change, new / closed window and output change,
        # time-stamped, for the whole test (WATCH_SECONDS); one line each: GVMEV <ms> <what> <caption> ...
        f.write("""
var t0 = Date.now();
function ev(what, w, extra) {
    callDBus("%s", "/", "%s", "Report", "GVMEV " + (Date.now() - t0) + " " + what + " " +
        (w ? String(w.caption).replace(/ /g, "_") : "none") + (extra ? " " + extra : ""));
}
function hook(w) {
    if (String(w.caption).indexOf(t) < 0) return;
    w.fullScreenChanged.connect(function () { ev("fullscreen=" + w.fullScreen, w, "client=" + w.clientGeometry.width + "x" + w.clientGeometry.height); });
    w.frameGeometryChanged.connect(function () { ev("geometry", w, w.clientGeometry.x + "," + w.clientGeometry.y + "," + w.clientGeometry.width + "," + w.clientGeometry.height); });
    w.minimizedChanged.connect(function () { ev("minimized=" + w.minimized, w); });
}
workspace.windowList().forEach(hook);
workspace.windowAdded.connect(function (w) { ev("added", w); hook(w); });
workspace.windowRemoved.connect(function (w) { ev("removed", w); });
workspace.windowActivated.connect(function (w) { ev("activated", w); });
ev("watching", workspace.activeWindow, "");
""" % (SVC, NAME))
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
    if action == "watch":
        # stream the events as they come (a caller reads them from a file), stop after the given seconds
        printed = [0]

        def flush():
            while printed[0] < len(lines):
                print(lines[printed[0]], flush=True)
                printed[0] += 1
            return True
        GLib.timeout_add(250, flush)
        GLib.timeout_add(int(float(os.environ.get("WATCH_SECONDS", "600")) * 1000), loop.quit)
        loop.run()
        flush()
        lines = []
        rc = 0
    else:
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
