"""
props - the bedroom props for Steal a Sock, one module per prop, in the concept-art style
(docs/concept/bedroom_keyframe.png).

Conventions every prop module follows:
- `NAME` = the exact object name the game looks for; `build()` returns the Blender objects:
  `[body, body_Outline, (glow parts...), *K.markers(NAME)]`.
- Blender Z-up, origin = floor centre of the prop, FRONT faces -Y (becomes +Z in Roblox).
- Sizes are "units"; Map.luau fits each prop into its slot (uniform scale), so only proportions
  matter - except `Clothespin`, which the game scales itself (see its module).
- Colours: `hexcol("<prop>_<what>", "#RRGGBB")` with a prop-prefixed name (the palette is keyed by
  name; the first registration wins). `props/common.py` holds a few shared colours, read-only.
- Glow parts the game turns into Neon are exported untextured via `K.plain_object` and named
  exactly as Map.luau expects (`LampGlow`, `DryerPortal`, `MoonGlow`, `FanLight`). Parts the client spins
  (`DryerVortex`, `DryerStars`, `FanBlades`) are separate textured objects turning about the `_Pin` marker.
- Roblox limit: keep each exported object under ~10k triangles (body and outline separately).

`EXPORT_DIR` says which folder the GLB goes to: "map" -> ReplicatedStorage.MapMeshes,
"socks" -> ReplicatedStorage.SockMeshes (used by the sock Factory).
"""
import importlib

# module name = NAME.lower(); order = export order
MODULE_NAMES = ["dryer", "bed", "nightstand", "lamp", "blocks", "duck", "teddy", "crayons", "basket", "drawer",
                "window", "bookshelf", "picture", "clothespin", "cushion", "slambutton", "cointray", "drawerfront",
                "alarmclock", "dresser", "toychest", "beachball", "toycar", "slippers", "bookstack", "ceilingfan",
                "curtains", "door", "wardrobe", "desk", "deskchair", "beanbag", "plant", "hamper", "posterrocket",
                "posterdino", "pennant", "trashcan"]


# NAME -> module for props whose module name isn't just NAME.lower()
ALIASES = {"slotcushion": "cushion", "collecttray": "cointray", "pottedplant": "plant"}


def load(name: str):
    """Imports just one prop module (by NAME or module name) - a broken module elsewhere can't stop it."""
    key = name.lower()
    return importlib.import_module("props." + ALIASES.get(key, key))


def load_all():
    """-> (BUILDERS {NAME: build}, EXPORT_DIR {NAME: "map"|"socks"}) for every prop, in export order."""
    mods = [load(n) for n in MODULE_NAMES]
    return {m.NAME: m.build for m in mods}, {m.NAME: getattr(m, "EXPORT_DIR", "map") for m in mods}
