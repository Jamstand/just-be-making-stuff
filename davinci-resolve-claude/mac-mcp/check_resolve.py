#!/usr/bin/env python3
"""Step 1: verify this Mac can talk to DaVinci Resolve — before building anything.

Run me with Resolve OPEN (any project):

    python3 check_resolve.py

I check, in order, and stop at the first failure with the exact fix:
  1. The scripting API folder and fusionscript library exist where
     Blackmagic installs them.
  2. This Python can import the fusionscript bridge module.
  3. A running Resolve accepts the connection (this is the step that
     needs Preferences > System > General > "External scripting using"
     set to Local, and Resolve Studio — the free edition refuses
     external scripting).
  4. Basic reads work: product, version, current project and timeline.

Nothing is installed and nothing in Resolve is modified — every call
here is a read.
"""
import os
import sys

# Where Blackmagic puts things on macOS. These are the documented install
# locations; we check both the shared /Library one and the per-user one.
API_CANDIDATES = [
    "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting",
    os.path.expanduser("~/Library/Application Support/Blackmagic Design/"
                       "DaVinci Resolve/Developer/Scripting"),
]
LIB_CANDIDATES = [
    "/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/"
    "Fusion/fusionscript.so",
]


def fail(msg):
    print("\n[FAIL] %s" % msg)
    sys.exit(1)


def main():
    print("== 1/4: locating the scripting API ==")
    api = next((p for p in API_CANDIDATES if os.path.isdir(p)), None)
    lib = next((p for p in LIB_CANDIDATES if os.path.isfile(p)), None)
    if not api:
        fail("Scripting API folder not found. Looked in:\n  %s\n"
             "Is DaVinci Resolve actually installed from blackmagicdesign.com "
             "(the App Store build hides these paths)?"
             % "\n  ".join(API_CANDIDATES))
    if not lib:
        fail("fusionscript.so not found at:\n  %s\n"
             "Expected inside the DaVinci Resolve app bundle." % LIB_CANDIDATES[0])
    print("  API : %s" % api)
    print("  LIB : %s" % lib)

    # The three env vars Blackmagic's own README prescribes. Setting them
    # here affects only THIS process — your shell profile is untouched.
    os.environ["RESOLVE_SCRIPT_API"] = api
    os.environ["RESOLVE_SCRIPT_LIB"] = lib
    modules = os.path.join(api, "Modules")
    sys.path.insert(0, modules)
    print("  (env set for this process only: RESOLVE_SCRIPT_API, "
          "RESOLVE_SCRIPT_LIB, PYTHONPATH += %s)" % modules)

    print("== 2/4: importing the bridge module ==")
    try:
        import DaVinciResolveScript as dvr  # thin wrapper that loads fusionscript.so
    except ImportError as exc:
        fail("Could not import DaVinciResolveScript: %s\n"
             "The Modules folder exists but this Python can't load it — "
             "check you're on the Mac's arm64 python3 (`python3 -c \"import "
             "platform; print(platform.machine())\"` should say arm64)." % exc)
    print("  DaVinciResolveScript imported OK")

    print("== 3/4: connecting to Resolve ==")
    resolve = dvr.scriptapp("Resolve")
    if resolve is None:
        fail("Resolve refused the connection. In order of likelihood:\n"
             "  1. Resolve isn't running — open it and re-run me.\n"
             "  2. Preferences > System > General > 'External scripting using'\n"
             "     is Disabled — set it to Local (needs a Resolve restart).\n"
             "  3. This is the free edition — external scripting is Studio-only.")
    print("  Connected.")

    print("== 4/4: reading basic state ==")
    print("  Product : %s %s" % (resolve.GetProductName(), resolve.GetVersionString()))
    pm = resolve.GetProjectManager()
    project = pm.GetCurrentProject() if pm else None
    if project is None:
        print("  Project : (none open — open any project before the smoke test)")
    else:
        print("  Project : %s" % project.GetName())
        timeline = project.GetCurrentTimeline()
        print("  Timeline: %s" % (timeline.GetName() if timeline else "(none)"))
        if timeline:
            print("  FPS     : %s" % timeline.GetSetting("timelineFrameRate"))

    print("\n[OK] This Mac can drive Resolve. Next: register the MCP server "
          "(see README.md step 2).")


if __name__ == "__main__":
    main()
