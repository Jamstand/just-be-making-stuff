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


def main():
    if len(sys.argv) < 2:
        fail("usage: mocha_job.py job.json")
    with open(sys.argv[1]) as fh:
        job = json.load(fh)
    action = job.get("action", "probe")

    try:
        try:
            from PySide6.QtCore import QCoreApplication
        except ImportError:
            from PySide2.QtCore import QCoreApplication  # older bundles
        app = QCoreApplication.instance() or QCoreApplication(sys.argv)  # noqa: F841
        import mocha
        from mocha.project import Clip, Project, View, XControlPointData
        from mocha import exporters as mexp
    except Exception as e:
        fail("Mocha's Python modules did not load (%s: %s). Is this Mocha's own "
             "python3, and is the license active?" % (type(e).__name__, e))

    if action == "probe":
        info = {"python": sys.version.split()[0],
                "executable": sys.executable,
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
        emit({"ok": True, "data": info})
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

    # The planar surface is what the corner-pin exporters follow.
    surface = job.get("surface")
    if surface and len(surface) == 4:
        for idx, (x, y) in enumerate(surface):
            for axis, val in (("X", x), ("Y", y)):
                try:
                    proj.parameter([layer.name, "Surface%d%s" % (idx, axis)]).set(float(val))
                except Exception as e:
                    notes.append("surface%d%s not set: %s" % (idx, axis, e))
                    break

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
