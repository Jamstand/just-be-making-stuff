#!/usr/bin/env python3
"""Claude Assistant -> Mocha Pro bridge.

Runs under Mocha's OWN python3 (the standalone app's or the Adobe plug-in
bundle's), never the system Python: that interpreter is the only one with
the `mocha` modules. Reads one job JSON (path in argv[1]) and prints a
single line starting with "CA_RESULT " that the panel parses; everything
else on stdout/stderr is Mocha chatter kept in mocha.log.

Only calls documented in the Mocha 2026.5 Python Scripting Guide are used:
  Clip(path, name) / Project(clip) / Project(path)
  Project.add_layer(clip, name=, frame_number=, view=)
  Layer.add_xspline_contour(time, points, view)
  Project.track_layers(start_index=, stop_index=, layers=)
  Project.save_as / save
  AbstractShapeDataExporter.registered_exporters()[name].do_export(...)
  AbstractTrackingDataExporter.registered_exporters()[name].do_export(...)

Jobs:
  {"action": "probe"}
  {"action": "track", "footage", "project_path", "out_dir", "layer_name",
   "shape": [{"x","y"}...], "surface": [[x,y]x4]?, "start_frame",
   "end_frame", "exports": ["mask","corner_pin","transform",...]}
  {"action": "export", "project_path", "out_dir", "layer_name"?,
   "exports": [...], "start_frame"?}
"""
import json
import os
import sys
import time
import traceback

TRACKING_EXPORTERS = {
    "corner_pin": "after_effects_corner_pin",
    "corner_pin_motion_blur": "after_effects_corner_pin_with_motion_blur",
    "power_pin": "after_effects_cc_power_pin",
    "transform": "after_effects_transform",
}


def emit(obj):
    sys.stdout.write("CA_RESULT " + json.dumps(obj) + "\n")
    sys.stdout.flush()


def fail(msg):
    emit({"ok": False, "error": msg, "traceback": traceback.format_exc()})
    sys.exit(1)


def qbytes(data):
    """QByteArray (PySide) -> bytes; tolerate str/bytes too."""
    if hasattr(data, "data"):
        return bytes(data.data())
    if isinstance(data, str):
        return data.encode("utf-8")
    return bytes(data)


def write_export(result, out_dir, fallback_path):
    """Exporters hand back {file_name: QByteArray} and do NOT write files
    ("The exporter should not create those files") -- we do."""
    written = []
    for name, data in (result or {}).items():
        name = str(name)
        if os.path.isabs(name):
            target = name
        else:
            target = os.path.join(out_dir, os.path.basename(name) or
                                  os.path.basename(fallback_path))
        with open(target, "wb") as fh:
            fh.write(qbytes(data))
        written.append(target)
    if not written:
        raise RuntimeError("exporter returned no data")
    return written


def do_exports(mexp, proj, layer, out_dir, kinds, at_frame):
    from mocha.project import View
    exports = {}
    for kind in kinds:
        try:
            if kind == "mask":
                exp = mexp.AbstractShapeDataExporter.registered_exporters()["after_effects_mask"]
                target = os.path.join(out_dir, "mask.shape4ae")
                exports[kind] = write_export(
                    exp.do_export(proj, [layer], target, [View(0)]), out_dir, target)
            elif kind in TRACKING_EXPORTERS:
                exp = mexp.AbstractTrackingDataExporter.registered_exporters()[TRACKING_EXPORTERS[kind]]
                target = os.path.join(out_dir, kind + ".txt")
                opts = {"Invert": False, "Stabilize": False, "RemoveLensDistortion": False}
                try:
                    res = exp.do_export(proj, layer, target, float(at_frame), View(0), opts)
                except TypeError:
                    res = exp.do_export(proj, layer, target, float(at_frame), View(0))
                exports[kind] = write_export(res, out_dir, target)
            else:
                exports[kind] = {"error": "unknown export kind"}
        except Exception as e:  # keep going: one bad exporter must not lose the track
            exports[kind] = {"error": "%s: %s" % (type(e).__name__, e)}
    return exports


def tiny_png(w, h):
    """A grey 8-bit RGB PNG with no dependencies: enough of a clip for
    Mocha to open a Project on, which is where RLM checks the license."""
    import struct
    import zlib
    raw = b"".join(b"\x00" + bytes([128, 128, 128]) * w for _ in range(h))

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def noise_png(w, h, seed, shift):
    """Deterministic textured RGB PNG; `shift` slides the texture so a
    3-frame sequence has real motion for the tracker to lock on to."""
    import struct
    import zlib
    rows = []
    for y in range(h):
        row = bytearray(b"\x00")
        for x in range(w):
            v = (((x + shift) * 73856093) ^ (y * 19349663) ^ seed) & 0xFF
            row += bytes([v, (v * 3) & 0xFF, (v * 7) & 0xFF])
        rows.append(bytes(row))

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"".join(rows))) + chunk(b"IEND", b""))


def make_qt_app(kind):
    """Mocha's tracker needs an OpenGL rendering context. The Python guide's
    bare QCoreApplication has no platform plugin and cannot provide one
    ("Can't obtain rendering context"), so default to a full QApplication
    and fall back down the ladder. Returns (app, kind_used)."""
    order = {"widgets": ["widgets", "gui", "core"],
             "gui": ["gui", "core"], "core": ["core"]}[kind or "widgets"]
    errors = []
    for k in order:
        for binding in ("PySide6", "PySide2"):
            try:
                core = __import__(binding + ".QtCore", fromlist=["QCoreApplication"])
                inst = core.QCoreApplication.instance()
                if inst is not None:
                    return inst, "existing"
                if k == "widgets":
                    mod = __import__(binding + ".QtWidgets", fromlist=["QApplication"])
                    return mod.QApplication(sys.argv), k
                if k == "gui":
                    mod = __import__(binding + ".QtGui", fromlist=["QGuiApplication"])
                    return mod.QGuiApplication(sys.argv), k
                return core.QCoreApplication(sys.argv), k
            except Exception as e:
                errors.append("%s/%s: %s" % (binding, k, e))
    raise RuntimeError("no Qt application could be created: " + "; ".join(errors))


def license_state():
    """Where RLM looks, per Mocha's own error listing, so a missing license
    is visible before anyone waits on a track."""
    home = os.path.expanduser("~")
    dirs = [os.path.join(home, "Library/Application Support/GenArts/rlm"),
            os.path.join(home, "Library/Application Support/BorisFX/rlm"),
            "/Library/Application Support/BorisFX/rlm",
            "/Library/Application Support/GenArts/rlm"]
    files = {}
    for d in dirs:
        try:
            files[d] = sorted(os.listdir(d)) if os.path.isdir(d) else None
        except Exception as e:
            files[d] = "unreadable: %s" % e
    env = {k: os.environ.get(k) for k in
           ("RLM_LICENSE", "genarts_LICENSE", "GENARTS_LICENSE", "BORISFX_LICENSE")
           if os.environ.get(k)}
    return {"license_files": files, "license_env": env}


def main():
    if len(sys.argv) < 2:
        fail("usage: mocha_job.py job.json")
    with open(sys.argv[1]) as fh:
        job = json.load(fh)
    action = job.get("action", "probe")

    if job.get("qpa"):
        os.environ["QT_QPA_PLATFORM"] = str(job["qpa"])
    try:
        app, qt_kind = make_qt_app(job.get("qt_app"))  # noqa: F841
        import mocha
        from mocha.project import Clip, Project, View, XControlPointData
        from mocha import exporters as mexp
    except Exception as e:
        fail("Mocha's Python modules did not load (%s: %s). Is this Mocha's own "
             "python3, and is the license active?" % (type(e).__name__, e))

    if action == "probe":
        info = {"python": sys.version.split()[0],
                "executable": sys.executable,
                "qt_app": qt_kind, "qpa": os.environ.get("QT_QPA_PLATFORM"),
                "mocha_version": getattr(mocha, "__version__", None)}
        try:
            info["exec_dir"] = mocha.get_mocha_exec_dir()
        except Exception as e:
            info["exec_dir_error"] = str(e)
        try:
            info["shape_exporters"] = sorted(mexp.AbstractShapeDataExporter.registered_exporters().keys())
            info["tracking_exporters"] = sorted(mexp.AbstractTrackingDataExporter.registered_exporters().keys())
            info["ae_exporters_present"] = all(
                n in info["shape_exporters"] + info["tracking_exporters"]
                for n in ["after_effects_mask", "after_effects_corner_pin", "after_effects_transform"])
        except Exception as e:
            info["exporters_error"] = "%s: %s" % (type(e).__name__, e)
        info.update(license_state())
        emit({"ok": True, "data": info})
        return

    if action == "license_check":
        # Separate job on purpose: if RLM makes Mocha bail out hard, the
        # probe above has already reported the exporters. Two gates live
        # here: the license (Project creation) and the rendering context
        # (a 3-frame track on a generated textured sequence).
        import tempfile
        d = tempfile.mkdtemp(prefix="ca-mocha-probe-")
        for i in range(3):
            with open(os.path.join(d, "probe.%04d.png" % i), "wb") as fh:
                fh.write(noise_png(96, 96, 12345, i * 2))
        first = os.path.join(d, "probe.0000.png")
        out = {"qt_app": qt_kind, "qpa": os.environ.get("QT_QPA_PLATFORM")}
        try:
            proj = Project(Clip(first, "probe"))
            out["license"] = "ok"
            out["detail"] = "Project created from a probe clip"
        except Exception as e:
            out["license"] = "failed"
            out["detail"] = "%s: %s" % (type(e).__name__, e)
            emit({"ok": True, "data": out})
            return
        try:
            clip = list(proj.clips.values())[0] if hasattr(proj.clips, "values") else proj.clips[0]
            layer = proj.add_layer(clip, name="probe", frame_number=0, view=0)
            pts = tuple(XControlPointData(corner=False, active=True, x=float(x), y=float(y),
                                          edge_width=0.0, edge_angle_ratio=0.5, weight=0.25)
                        for x, y in ((16, 16), (80, 16), (80, 80), (16, 80)))
            layer.add_xspline_contour(0.0, pts, View(0))
            t0 = time.time()
            proj.track_layers(start_index=0, stop_index=2, layers=[layer])
            out["tracking"] = "ok"
            out["tracking_detail"] = "3-frame probe track in %.1fs" % (time.time() - t0)
        except Exception as e:
            out["tracking"] = "failed"
            out["tracking_detail"] = "%s: %s" % (type(e).__name__, e)
        emit({"ok": True, "data": out})
        return

    out_dir = job["out_dir"]
    os.makedirs(out_dir, exist_ok=True)
    notes = []

    if action == "export":
        try:
            proj = Project(job["project_path"])
            layers = proj.find_layers(job["layer_name"]) if job.get("layer_name") else list(proj.layers)
            if not layers:
                fail("no layer %r in %s" % (job.get("layer_name"), job["project_path"]))
            layer = layers[0]
            at = int(job.get("start_frame", 0))
            emit({"ok": True, "data": {"project": job["project_path"], "layer": layer.name,
                                        "exports": do_exports(mexp, proj, layer, out_dir, job.get("exports", []), at),
                                        "notes": notes}})
        except SystemExit:
            raise
        except Exception as e:
            fail("export failed: %s: %s" % (type(e).__name__, e))
        return

    if action != "track":
        fail("unknown action %r" % action)

    footage = job["footage"]
    if not os.path.exists(footage):
        fail("footage not found: " + footage)
    start, stop = int(job["start_frame"]), int(job["end_frame"])
    shape = job.get("shape") or []
    if len(shape) < 3:
        fail("shape needs at least 3 points")

    try:
        clip = Clip(footage, "footage")
        proj = Project(clip)
        # Live: the exporters wrote a 24 fps header for 59.94 footage, so
        # tell the project the real rate (frames stay frames either way).
        if job.get("fps"):
            try:
                proj.frame_rate = float(job["fps"])
            except Exception as e:
                notes.append("could not set project frame_rate: %s" % e)
        proj.save_as(job["project_path"])
    except Exception as e:
        fail("could not open the footage in Mocha (%s: %s) -- a plug-in-only "
             "license may refuse external scripting; the standalone app's "
             "python3 is the workaround" % (type(e).__name__, e))

    try:
        layer = proj.add_layer(clip, name=job.get("layer_name", "Claude Track"),
                               frame_number=start, view=0)
        points = tuple(
            XControlPointData(corner=bool(p.get("corner", False)), active=True,
                              x=float(p["x"]), y=float(p["y"]), edge_width=0.0,
                              edge_angle_ratio=0.5, weight=0.25)
            for p in shape)
        layer.add_xspline_contour(float(start), points, View(0))
    except Exception as e:
        fail("could not build the tracking layer: %s: %s" % (type(e).__name__, e))

    # Keep the tracker and the exporters inside the requested range.
    for key, val in (("In_Point", start), ("Out_Point", stop)):
        try:
            layer.parameter(["Basic", key]).set(val)
        except Exception as e:
            notes.append("could not set %s: %s" % (key, e))

    # The planar surface is what the corner-pin exporters follow. The
    # guide's [layer, "Surface0X"] path did not resolve live ("No such
    # parameter"); try the plausible spellings, and if none takes, the panel
    # retargets the exported quad through the per-frame homography anyway.
    surface = job.get("surface")
    if surface and len(surface) == 4:
        set_any = False
        for path in ([layer.name, "Surface%d%s"], [layer.name, "Surface", "Surface%d%s"],
                     [layer.name, "Basic", "Surface%d%s"], ["Surface%d%s"]):
            try:
                for idx, (x, y) in enumerate(surface):
                    for axis, val in (("X", x), ("Y", y)):
                        comps = [c % (idx, axis) if "%d" in c else c for c in path]
                        proj.parameter(comps).set(float(val))
                set_any = True
                notes.append("surface set via %s" % "/".join(path))
                break
            except Exception as e:
                last_err = "%s: %s" % ("/".join(path), e)
        if not set_any:
            notes.append("surface not settable (%s) — panel retargets the export" % last_err)

    t0 = time.time()
    try:
        proj.track_layers(start_index=start, stop_index=stop, layers=[layer])
    except Exception as e:
        fail("tracking failed after %.1fs: %s: %s" % (time.time() - t0, type(e).__name__, e))
    track_seconds = round(time.time() - t0, 1)
    try:
        proj.save()
    except Exception as e:
        notes.append("project save failed: %s" % e)

    emit({"ok": True, "data": {
        "project": job["project_path"], "layer": layer.name,
        "frames": stop - start + 1, "track_seconds": track_seconds,
        "exports": do_exports(mexp, proj, layer, out_dir, job.get("exports", []), start),
        "notes": notes}})


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:
        fail("%s: %s" % (type(e).__name__, e))
