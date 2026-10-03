"""
items - the item bar's items for Steal a Sock (ReplicatedStorage.ItemMeshes), in the same cartoon
style as the socks and props: the Towel Snap's towels and the eight items players unlock.

Conventions every item module follows (like props/, with three additions):
- `BUILDERS = {NAME: build}`: one module may build several GLBs (towel.py builds one per look).
  Each build() returns `[body, body_Outline, (extra parts...), *K.markers(NAME), grip marker]`.
- Blender Z-up, origin = the item's floor centre (placed items: where it rests on the floor),
  FRONT faces -Y (becomes +Z in Roblox). Sizes are in units = studs (the game does not rescale
  items except to its own sizes in ItemConfig).
- `<NAME>_Grip`: a marker where the player's right hand holds it (held items), made with
  `grip(NAME, pos)` below. The game turns it into the Tool's grip: the hand at the marker, the
  item's FRONT (-Y) pointing forward out of the fist.
- Colours: `hexcol("<item>_<what>", "#RRGGBB")`, item-prefixed (first registration wins).
- `MATERIALS` / `TEXTURE_SIZE` as in props; optional `rig(name, objs) -> armature or None`, called
  after the bake (bones + weights only, like rigging.rig_sock), for items that bend (the towel).
- Keep each exported object under ~10k triangles (body and outline separately).

build_all.py builds every item AFTER the socks and props in its first pass (palette order: older
GLBs keep their colours' cells). Append new modules to MODULE_NAMES; never reorder it.
"""
import importlib

import sockkit as K

MODULE_NAMES = ["towel", "bananapeel", "bubbleblaster", "alarmduck", "softener", "dashslippers",
                "dryersheet", "laundrybasket", "staticballoon"]


def grip(name: str, pos):
    """The `<name>_Grip` marker at `pos` (where the right hand holds the item)."""
    return K.marker(name + "_Grip", pos)


def load(module: str):
    return importlib.import_module("items." + module)


def load_all():
    """-> (BUILDERS {NAME: build}, MODULE {NAME: module}) for every item GLB, in export order."""
    builders, owner = {}, {}
    for m in (load(n) for n in MODULE_NAMES):
        for name, fn in getattr(m, "BUILDERS", {}).items():
            builders[name] = fn
            owner[name] = m
    return builders, owner
