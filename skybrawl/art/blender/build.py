"""
Builds Skybrawl's art. Run inside Blender or with the bpy module:

    blender -b -P art/blender/build.py -- all
    blender -b -P art/blender/build.py -- fighter kestrel brann
    python art/blender/build.py fighters | weapons | maps | anims | skies

Outputs go to art/export (import these into Studio), art/previews (renders)
and src/shared (generated Luau data).
"""

import importlib
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

FIGHTERS = ["kestrel", "brann", "yuki", "moss", "vex", "sol"]
MAPS = ["sky_ship", "volcanic_forge", "frozen_peaks", "jungle_temple"]


def available(package, names):
    return [n for n in names if os.path.exists(os.path.join(HERE, package, n + ".py"))]


def build_fighters(names=None):
    from sky import rig

    for name in names or available("fighters", FIGHTERS):
        rig.build_fighter(importlib.import_module(f"fighters.{name}"))
    rig.write_fighter_rigs_luau()


def build_weapons(names=None):
    import weapons

    weapons.build_all(names)


def build_maps(names=None):
    from sky import mapkit

    for name in names or available("maps", MAPS):
        mapkit.build_map(importlib.import_module(f"maps.{name}"))


def build_anims(names=None):
    import anims

    anims.build_all(names)


def build_skies(names=None):
    import skies

    skies.build_all(names)


COMMANDS = {
    "fighter": build_fighters,
    "fighters": build_fighters,
    "weapon": build_weapons,
    "weapons": build_weapons,
    "map": build_maps,
    "maps": build_maps,
    "anim": build_anims,
    "anims": build_anims,
    "sky": build_skies,
    "skies": build_skies,
}


def main(argv):
    if not argv or argv[0] == "all":
        build_fighters()
        build_weapons()
        build_maps()
        build_skies()
        build_anims()
        return
    command, names = argv[0], argv[1:]
    if command not in COMMANDS:
        raise SystemExit(f"unknown command {command!r}; use one of: all, {', '.join(sorted(COMMANDS))}")
    COMMANDS[command](names or None)


if __name__ == "__main__":
    main(sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else sys.argv[1:])
