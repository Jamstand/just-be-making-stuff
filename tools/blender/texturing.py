"""
texturing.py - bakes a hand-painted texture onto every textured body of the Steal a Sock kit.

The flat palette look (one colour per face) becomes a painted one. Every face keeps its palette
colour; the texture only modulates it:
- a material pattern picked from the colour's NAME (wood grain, woven fabric, knit stitches, plush
  fur, paper fibre, brushed metal, rope twist, felt fuzz, leaf veins, glaze speckle ...),
- soft hand-painted shading: baked ambient occlusion mixed in gently (darker, slightly cooler
  crevices), lighter rounded edges and up-facing surfaces, a little large-scale colour variation.
Ink (outline-coloured faces, pupils, drawn lines), googly-eye whites and glints stay flat.

How, per textured body (`bake(objs, name)`, called by build_all.py right before export):
1. a second UV map: Smart UV Project on a welded copy (loose triangles that touch - the posters'
   lettering - make one island), islands brought to one texel density and then scaled by a texel
   budget per material (TEXEL_WEIGHT: knit and weave get more, smooth plastic less, a one-colour
   ink shape almost none), faces buried inside other pieces (every ray from them leaves through a
   back face) shrunk to slivers, packed with a small gap,
2. Cycles bakes helper maps on it (EMIT passes of a helper shader): palette colour, ambient
   occlusion (two radii, cast by a copy without the ink), object-space position and normal,
   palette index + part id,
3. numpy paints the texture from them - patterns are evaluated in 3D, in "pattern studs" (game studs
   for the room props, see FIT; finer for the socks and the drawer bases, see NEAR), so they run
   across UV seams and wood grain is the same size on the bed as on the dresser; a pattern too fine
   for the texel size fades out instead of aliasing - fills the gutters, saves a JPEG,
4. the body gets one material with that image on the bake UV, which becomes its only UV map.
Outline hulls (`_Outline`), glow parts (`K.plain_object`), markers and parts made only of flat
colours (the dryer's galaxy layers) keep the flat palette.

Classes come from keywords in the colour name (RULES); a prop module can override them with
`MATERIALS = {"colour_name_prefix_or_glob": "class"}` (the longest matching key wins) and pick its
texture size with `TEXTURE_SIZE = 1024`. `bake` prints the colours that fell through to the default
class, so new colours can be given a rule.
"""
import fnmatch
import math
import os
import tempfile
import time
import zlib

import bmesh
import bpy
import numpy as np
from bpy_extras.bmesh_utils import bmesh_linked_uv_islands
from mathutils import Vector
from mathutils.bvhtree import BVHTree

import sockkit as K

# ---------------------------------------------------------------- scale (pattern studs per unit)
# Map.luau fits each prop into a box (X wide, Y high, Z deep in Roblox = Blender X, Z, Y) with a
# uniform scale; copied here only to size the patterns in game studs. A prop missing here uses 10.
FIT = {
    "CeilingFan": (220, 110, 220), "Bed": (290, 110, 140), "Curtains": (320, 240, 24), "Window": (140, 140, 24),
    "Nightstand": (72, 80, 72), "Lamp": (46, 56, 46), "AlarmClock": (22, 25, 14), "ToyChest": (116, 78, 72),
    "PottedPlant": (90, 170, 90), "PosterRocket": (90, 130, 4), "Wardrobe": (180, 300, 95), "Pennant": (120, 50, 6),
    "Desk": (200, 115, 100), "DeskChair": (80, 140, 80), "Picture": (110, 82, 10), "TrashCan": (50, 64, 50),
    "BookStack": (40, 42, 32), "Bookshelf": (150, 125, 56), "PosterDino": (130, 90, 4), "BeanBag": (120, 80, 110),
    "BeachBall": (58, 55, 58), "Hamper": (90, 110, 90), "Door": (140, 300, 16), "Dresser": (175, 150, 82),
    "Slippers": (60, 20, 50), "ToyCar": (44, 32, 70), "Blocks": (90, 40, 60), "Crayons": (80, 20, 60),
    "Duck": (44, 46, 44), "Teddy": (72, 90, 72), "Dryer": (56, 42, 38), "Basket": (34, 30, 34),
    "Drawer": (52, 15, 48), "DrawerFront": (48, 9, 4.2), "SlotCushion": (7, 2.2, 7), "CollectTray": (13.6, 2.4, 6.9),
    "SlamButton": (3.6, 3.0, 3.6),
}
SOCK_STUDS = 2.0  # EconomyConfig.SockScale: sock meshes are 1 unit = 1 stud, then scaled x2 (Clothespin too)
# Pattern sizes below are for the giant bedroom: features of ~4+ studs, so they still resolve on the
# biggest props (the wardrobe gets ~1 texel per stud). Things the player sees from a few studs away
# use finer patterns, or a knit stitch would be as big as a sock's eye: NEAR_DETAIL x finer for the
# socks and their clothespin, DRAWER_DETAIL x for the drawer bases the player stands in. Each group
# shares one pattern size in studs.
NEAR_DETAIL = 10.0
DRAWER_DETAIL = 3.0
NEAR = {"Clothespin": NEAR_DETAIL, "Drawer": DRAWER_DETAIL, "DrawerFront": DRAWER_DETAIL,
        "SlotCushion": DRAWER_DETAIL, "SlamButton": DRAWER_DETAIL, "CollectTray": DRAWER_DETAIL}


def pattern_scale(name: str, objs, sock: bool) -> float:
    """Pattern studs per model unit for asset `name`."""
    if sock or name == "Clothespin":
        return SOCK_STUDS * NEAR_DETAIL
    lo, hi = _bounds([o for o in objs if not o.hide_render])
    size = hi - lo
    fit = FIT.get(name)
    spu = 10.0
    if fit and min(size) > 1e-6:
        spu = min(fit[0] / size.x, fit[1] / size.z, fit[2] / max(size.y, 1e-6))
    return spu * NEAR.get(name, 1.0)


def _bounds(objs):
    lo = Vector((1e9, 1e9, 1e9))
    hi = Vector((-1e9, -1e9, -1e9))
    for o in objs:
        if o.type != "MESH":
            continue
        for v in o.data.vertices:
            w = o.matrix_world @ v.co
            lo = Vector((min(lo[i], w[i]) for i in range(3)))
            hi = Vector((max(hi[i], w[i]) for i in range(3)))
    return lo, hi


# ---------------------------------------------------------------- material classes
# class -> (pattern strength, ambient occlusion strength); the patterns are in PATTERNS below
CLASSES = {
    "painted": (1.0, 0.55),   # default: soft brush mottling
    "wood": (1.0, 0.55),      # grain streaks + growth-ring figure along each piece's long axis
    "paintwood": (1.0, 0.55),  # painted wood (blue door, teal chest, letter blocks): faint grain
    "fabric": (1.0, 0.6),     # woven: crosshatch threads + mottling
    "knit": (1.0, 0.55),      # stockinette V stitches (socks: around the leg / foot tube)
    "fur": (1.0, 0.6),        # plush: short strands combed downward + clumps
    "fluff": (1.0, 0.45),     # lint, foam, clouds, smoke: soft puffs
    "paper": (1.0, 0.4),      # pages, books, labels, cash: fibre + faint mottle
    "print": (1.0, 0.12),     # flat printed art in stacked layers (posters, the picture): paper, almost no AO
    "plastic": (1.0, 0.5),    # glossy painted plastic toys: smooth, a painted highlight
    "rubber": (1.0, 0.55),    # tyres, soles, grips: fine speckle
    "metal": (1.0, 0.5),      # brass / gold / chrome / steel: brushed streaks + highlight
    "glass": (1.0, 0.3),      # lenses, screens: just a soft sheen
    "ceramic": (1.0, 0.5),    # the plant pot, mugs: glaze speckle + sheen
    "leaf": (1.0, 0.55),      # leaves, stems: veins along the leaf + mottling
    "rope": (1.0, 0.6),       # the hamper's rope coils: twisted strands
    "felt": (1.0, 0.5),       # drawer liner, pennant: fuzzy felt
    "wicker": (1.0, 0.6),     # the basket weave: fine grain
    "soil": (1.0, 0.5),       # soil, crumbs, crust: grainy speckle
    "decal": (0.0, 0.25),     # stars, moons, sparkles, glints, flames: flat and bright
    "eye": (0.0, 0.3),        # googly-eye whites: flat
    "ink": (0.0, 0.0),        # outline-coloured faces, pupils, drawn lines: exactly the palette colour
}
DEFAULT_CLASS = "painted"
FLAT = {"decal", "eye", "ink"}  # no pattern: a body made only of these keeps the flat palette
# texel budget: UV islands are scaled by this (the island's largest) before packing. Fine patterns
# (knit, weave, grain) keep full density, smooth materials need less; SMALL ink / eye / glint islands
# get more, so a sock's mouth line or pupil rim stays crisp (a big ink area, like the fan blades'
# merged hull, stays at 1).
TEXEL_WEIGHT = {"ink": 2.5, "eye": 2.0, "decal": 1.4, "knit": 1.3, "fabric": 1.1, "rope": 1.0, "wicker": 1.0,
                "wood": 0.95, "fur": 0.95, "paintwood": 0.9, "felt": 0.85, "leaf": 0.85, "paper": 0.85, "print": 0.85,
                "painted": 0.8, "metal": 0.8, "ceramic": 0.8, "plastic": 0.75, "rubber": 0.75, "soil": 0.7,
                "glass": 0.7, "fluff": 0.6}

# exact colour names first, then keywords: a whole token of the "_"-split name (or its plural)
EXACT = {"outline": "ink", "black": "ink", "white": "eye", "mouth": "ink", "dark": "ink", "gold": "metal",
         "gold_dark": "metal", "silver": "metal", "silver_dark": "metal", "bolt": "decal", "cash": "paper",
         "beard": "fur", "stink": "fluff", "sock_inner": "knit", "tongue": "painted"}
RULES = [  # (class, keywords) - checked in this order
    ("ink", ("ink", "outline", "pupil", "eye", "nostril", "hole", "tick", "mark", "slot", "text", "number",
             "letter", "scribble", "smile", "brow", "stitch", "tash", "mouth", "lip")),
    ("decal", ("glint", "gloss", "glare", "sparkle", "star", "moon", "sun", "flame", "glow", "halo", "bolt",
               "crater", "heart", "spark", "shine", "dot")),
    ("glass", ("glass", "lens", "screen", "visor", "bubble", "jewel", "ruby", "sapphire", "gem", "sweat", "drop")),
    ("metal", ("brass", "gold", "chrome", "steel", "silver", "metal", "knob", "hinge", "latch", "coin", "wire",
               "coil", "tray", "nozzle", "spring", "buckle", "bell", "hammer", "rivet", "armour", "armor",
               "crown", "zip", "hanger", "hub", "chain")),
    ("rubber", ("tyre", "tire", "rubber", "sole", "grip", "hose", "bumper")),
    ("knit", ("sock", "yarn", "rib", "knit", "cuff")),
    ("fur", ("fur", "teddy", "plush", "beard", "hair", "plume", "bunny", "mane", "whisker", "fleece")),
    ("fluff", ("lint", "foam", "fluff", "smoke", "gas", "cotton", "puff", "steam", "ghost", "fibre", "fiber")),
    ("felt", ("felt", "liner", "pennant", "tassel")),
    ("rope", ("rope", "twine", "string", "cord", "thread")),
    ("wicker", ("wicker", "basket", "weave", "straw")),
    ("leaf", ("leaf", "plant", "stem", "cactus", "vine", "vein", "grass", "flower", "fern", "frond")),
    ("ceramic", ("pot", "ceramic", "vase", "mug", "glaze", "cup", "porcelain")),
    ("soil", ("soil", "dirt", "crust", "crumb", "sand", "pebble", "stain")),
    ("paper", ("paper", "poster", "page", "book", "notebook", "label", "cash", "card", "sticker", "bookstack",
               "posterrocket", "posterdino", "picture", "sky", "hill", "cloud", "wrap", "wrapper",
               "comic", "tape", "ticket", "sign", "ruler", "map", "note", "photo", "pic", "hatbox", "box")),
    ("fabric", ("fabric", "blanket", "sheet", "pillow", "cushion", "curtain", "curtains", "cloth", "rug",
                "toga", "shirt", "coat", "hoodie", "lining", "ribbon", "velvet", "mattress", "cap", "piping",
                "towel", "hat", "band", "scarf", "cape", "fold", "stripe", "bow")),
    ("wood", ("wood", "plank", "post", "panel", "leg", "frame", "drawer", "desk", "shelf", "door", "board",
              "finial", "headboard", "casing", "jamb", "pencil", "rod", "stick", "log", "trunk", "chair",
              "stool", "table", "nightstand", "dresser", "wardrobe", "bookshelf", "branch", "rail",
              "deskchair", "reveal", "pinewood")),
    ("plastic", ("plastic", "toy", "ball", "beachball", "car", "toycar", "block", "blocks", "duck", "crayon",
                 "crayons", "button", "valve", "dial", "bezel", "slam", "lamp", "globe", "bucket", "bin",
                 "trashcan", "can", "dryer", "clock", "alarmclock", "cockpit", "seat", "roundel", "sword",
                 "shield", "helmet", "fan", "ceilingfan", "beak", "bill", "nose", "horn", "phone", "remote")),
]
# sock bodies: "<TypeId>_<suffix>" colours that are part of the knitted sock itself
SOCK_KNIT = {"body", "dark", "inner", "accent", "light", "rib", "fold", "diamond", "line", "extra", "stripe",
             "cuff", "toe", "heel", "patch", "band", "bandw", "belly"}
# sock features whose names don't say what they are (a token of "<TypeId>_<...>")
SOCK_FEATURES = {"pogo": "plastic", "stink": "fluff", "fly": "plastic", "wing": "glass", "sick": "glass",
                 "tear": "glass", "cheek": "felt", "tongue": "felt", "foam": "fluff", "steel": "metal",
                 "crease": "knit", "thread": "knit", "strap": "painted"}


def _rule_class(name: str):
    if name in EXACT:
        return EXACT[name]
    toks = [t.rstrip("0123456789") for t in name.lower().split("_")]  # "leaf2" -> "leaf"
    for cls, keys in RULES:
        for t in toks:
            for k in keys:
                if t == k or t == k + "s" or t == k + "es":
                    return cls
    return None


def classify(name: str, overrides: dict | None = None, sock_id: str | None = None) -> tuple[str, bool]:
    """-> (class, matched_a_rule) for a palette colour name. `overrides` = a prop's MATERIALS:
    {"pattern": "class"}, the pattern a name prefix or an fnmatch glob ("crayons_*_wrap"); the longest
    matching pattern wins. Ink (drawn lines, pupils) stays ink whatever the overrides say."""
    rule = _rule_class(name)
    if rule == "ink":
        return rule, True
    if overrides:
        best = None
        for pat, cls in overrides.items():
            if (name.startswith(pat) or fnmatch.fnmatchcase(name, pat) or fnmatch.fnmatchcase(name, pat + "*")) \
                    and (best is None or len(pat) > len(best[0])):
                best = (pat, cls)
        if best:
            return best[1], True
    if sock_id and name.startswith(sock_id + "_"):
        suffix = name[len(sock_id) + 1:]
        if suffix in SOCK_KNIT:
            return "knit", True
        for t in suffix.split("_"):
            if t.rstrip("0123456789") in SOCK_FEATURES:
                return SOCK_FEATURES[t.rstrip("0123456789")], True
    if rule:
        return rule, True
    return DEFAULT_CLASS, False


# ---------------------------------------------------------------- noise (numpy)
_RNG = np.random.RandomState(1234)
_PERM = np.concatenate([_RNG.permutation(256)] * 2).astype(np.int32)
_GRAD = np.array([[1, 1, 0], [-1, 1, 0], [1, -1, 0], [-1, -1, 0], [1, 0, 1], [-1, 0, 1], [1, 0, -1], [-1, 0, -1],
                  [0, 1, 1], [0, -1, 1], [0, 1, -1], [0, -1, -1], [1, 1, 0], [-1, 1, 0], [0, -1, 1], [0, -1, -1]],
                 dtype=np.float32)


def noise3(p):
    """Perlin gradient noise, p: (n, 3) -> (n,) in about [-1, 1]."""
    pi = np.floor(p)
    pf = (p - pi).astype(np.float32)
    pi = pi.astype(np.int64) & 255
    x, y, z = pi[:, 0], pi[:, 1], pi[:, 2]
    fx, fy, fz = pf[:, 0], pf[:, 1], pf[:, 2]
    u = fx * fx * fx * (fx * (fx * 6 - 15) + 10)
    v = fy * fy * fy * (fy * (fy * 6 - 15) + 10)
    w = fz * fz * fz * (fz * (fz * 6 - 15) + 10)
    P = _PERM
    a = P[x] + y
    b = P[x + 1] + y
    aa, ab, ba, bb = P[a] + z, P[a + 1] + z, P[b] + z, P[b + 1] + z

    def g(h, dx, dy, dz):
        gr = _GRAD[P[h] & 15]
        return gr[:, 0] * dx + gr[:, 1] * dy + gr[:, 2] * dz

    x1 = g(aa, fx, fy, fz) * (1 - u) + g(ba, fx - 1, fy, fz) * u
    x2 = g(ab, fx, fy - 1, fz) * (1 - u) + g(bb, fx - 1, fy - 1, fz) * u
    y1 = x1 * (1 - v) + x2 * v
    x3 = g(aa + 1, fx, fy, fz - 1) * (1 - u) + g(ba + 1, fx - 1, fy, fz - 1) * u
    x4 = g(ab + 1, fx, fy - 1, fz - 1) * (1 - u) + g(bb + 1, fx - 1, fy - 1, fz - 1) * u
    y2 = x3 * (1 - v) + x4 * v
    return (y1 * (1 - w) + y2 * w) * 1.4


def fbm(p, size, ts, octaves=4, gain=0.5, seed=0.0):
    """Fractal noise with features `size` pattern studs big; octaves finer than ~2.5 texels (ts =
    texel size in pattern studs) fade out, so a coarse texture never aliases into speckle."""
    out = np.zeros(len(p), np.float32)
    amp, f, norm = 1.0, 1.0 / size, 0.0
    for i in range(octaves):
        k = _aa(1.0 / f, ts)
        if k <= 0.0:
            break
        out += amp * k * noise3(p * f + (seed + 17.3 * i))
        norm += amp
        amp *= gain
        f *= 2.03
    return out / max(norm, 1e-6)


def _aa(wavelength, ts, lo=2.0, hi=4.0):
    """1 when a feature `wavelength` pattern studs long spans >= hi texels, 0 below lo texels."""
    t = (wavelength / max(ts, 1e-6) - lo) / (hi - lo)
    return float(min(1.0, max(0.0, t)))


def _smooth(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def _dot(a, b):
    return np.einsum("ij,ij->i", a, b)


def _norm(v):
    return v / np.maximum(np.linalg.norm(v, axis=1, keepdims=True), 1e-8)


def _squash(p, axis, k):
    """Positions with the component along `axis` (per row) divided by k: noise stretched k x along it."""
    along = _dot(p, axis)[:, None]
    return p - axis * along * (1.0 - 1.0 / k)


def _tri(fn, p, n, sharp=4.0):
    """Triplanar: fn(s, t) on the three axis planes (t = z on the side planes), blended by the normal."""
    w = np.abs(n) ** sharp
    w /= np.maximum(w.sum(axis=1, keepdims=True), 1e-8)
    return (w[:, 0] * fn(p[:, 1], p[:, 2]) + w[:, 1] * fn(p[:, 0], p[:, 2]) + w[:, 2] * fn(p[:, 0], p[:, 1]))


# ---------------------------------------------------------------- patterns
# Each returns a brightness multiplier (n,) around 1 for the texels of one class. `c` holds: p
# (pattern-stud positions), n (normals), axis / centre / rand (of the texel's connected piece),
# ts (texel size in pattern studs), sock (tube coordinates for sock bodies or None).
def _wood(c, figure=1.0, streak=1.0, ring=7.0):
    a, rel = c["axis"], c["p"] - c["centre"]
    ps = _squash(rel, a, 7.0)
    warp = fbm(ps, 9.0, c["ts"], 3, seed=3.1)
    radial = rel - a * _dot(rel, a)[:, None]
    r = np.linalg.norm(radial, axis=1) / ring + 0.9 * warp + c["rand"] * 7.0
    d = np.abs(r - np.round(r))                       # distance to the nearest ring line, in rings
    lw = 0.09
    lines = (1.0 - _smooth(lw * 0.4, lw, d)) * _aa(ring * lw * 2.5, c["ts"], 1.0, 2.5)
    st = fbm(_squash(rel, a, 9.0), 1.6, c["ts"], 3, seed=7.7)
    late = 0.5 + 0.5 * np.cos(2 * np.pi * r)            # latewood: the half of each ring nearer the line
    return 1.0 + streak * 0.06 * st - figure * (0.075 * lines + 0.03 * late - 0.025)  # ~ zero mean


def _paintwood(c):
    return _wood(c, figure=0.35, streak=0.4) + 0.02 * fbm(c["p"], 6.0, c["ts"], 3, seed=4.0)


def _weave(s, t, cell, mean=None):
    """Plain weave: in each cell either the warp or the weft thread is on top (checkerboard); a
    thread is bright along its middle and dips where it goes under its neighbour."""
    if mean is None:
        return _weave(s, t, cell, 0.0) - _WEAVE_MEAN
    u, v = s / cell, t / cell
    i, j = np.floor(u), np.floor(v)
    fu, fv = u - i, v - j
    warp_up = ((i + j) % 2) == 0
    across_v = np.clip(np.sin(np.pi * fv), 0, 1) ** 0.7  # a horizontal thread's profile (float32
    across_u = np.clip(np.sin(np.pi * fu), 0, 1) ** 0.7  # sin(pi * 1.0) is a hair below 0: clip)
    along_u = 0.75 + 0.25 * np.sin(np.pi * fu)  # ... rising out of / dipping under the crossing
    along_v = 0.75 + 0.25 * np.sin(np.pi * fv)
    top = np.where(warp_up, across_v * along_u, across_u * along_v)
    return top * 2.0 - 1.2


_WEAVE_MEAN = float(_weave(*np.meshgrid((np.arange(128) + 0.5) / 64, (np.arange(128) + 0.5) / 64), 1.0, 0.0).mean())


def _fabric(c):
    p, ts = c["p"], c["ts"]
    cell = 2.4  # one thread crossing, in pattern studs
    weave = _tri(lambda s, t: _weave(s, t, cell), p, c["n"]) * _aa(cell * 2, ts, 3.0, 6.0)
    mott = fbm(p, 16.0, ts, 3, seed=11.0)
    fuzz = fbm(p, 1.5, ts, 2, seed=5.0)
    return 1.0 + 0.05 * weave + 0.045 * mott + 0.025 * fuzz


def _cell_mean(fn):
    """Mean of a periodic 2D pattern over one period (so a pattern never shifts the colour's average)."""
    g = (np.arange(64, dtype=np.float32) + 0.5) / 64
    s, t = np.meshgrid(g, g)
    return float(fn(s.ravel(), t.ravel(), 0.0).mean())


def _stitch(s, t, mean=None, detail=1.0):
    """Stockinette in stitch units: s across columns, t up rows. Two slanted strands per stitch (a V);
    with less `detail` (too few texels for the V) it eases into plain ribs: rounded columns."""
    fs = s - np.floor(s) - 0.5
    ft = t - np.floor(t)
    off = np.abs(fs) - (0.07 + 0.24 * ft)            # the strands lean out toward the top of the V
    leg = 1.0 - _smooth(0.05, 0.2, np.abs(off))
    row = np.clip(np.sin(np.pi * ft), 0, 1) ** 0.6    # rows meet in a soft dark seam
    groove = _smooth(0.36, 0.5, np.abs(fs))           # dark gap between columns
    v = 0.9 * leg * row - 0.55 * groove - 0.25 * (1 - row)
    if mean is None:
        v = v - _STITCH_MEAN
    if np.all(np.asarray(detail) >= 1.0):
        return v
    rib = np.cos(2 * np.pi * fs) * 0.55 - 0.08 * np.cos(2 * np.pi * ft)  # zero mean
    return detail * v + (1.0 - detail) * rib


_STITCH_MEAN = _cell_mean(_stitch)


def _knit(c):
    p, ts = c["p"], c["ts"]
    col_w, row_h = 4.0, 3.2  # stitch size in pattern studs (sock bodies: 22 columns round the leg)
    # sock bodies: 22 columns round a 0.7 leg ~ the same 4 pattern studs
    k = _aa(col_w, ts, 2.0, 3.5)            # ribs need ~3 texels a column ...
    d = _aa(col_w, ts, 5.0, 8.0)            # ... the V stitches ~7
    if c.get("sock") is not None:
        sk = c["sock"]
        v = sk["w_leg"] * _stitch(sk["s_leg"], sk["t_leg"], detail=d) \
            + (1 - sk["w_leg"]) * _stitch(sk["s_foot"], sk["t_foot"], detail=d)
    else:
        v = _tri(lambda s, t: _stitch(s / col_w, t / row_h, detail=d), p, c["n"])
    mott = fbm(p, 10.0, ts, 3, seed=21.0)
    return 1.0 + k * 0.11 * v + 0.035 * mott


def _fur(c):
    p, n, ts = c["p"], c["n"], c["ts"]
    down = np.array([0.0, 0.0, -1.0], np.float32)
    flow = down[None, :] - n * _dot(n, np.broadcast_to(down, n.shape))[:, None]
    bad = np.linalg.norm(flow, axis=1) < 0.25
    flow[bad] = c["axis"][bad]
    flow = _norm(flow)
    strands = fbm(_squash(p, flow, 4.0), 1.8, ts, 3, seed=31.0)
    clumps = fbm(p, 6.0, ts, 2, seed=37.0)
    tips = _smooth(0.15, 0.7, strands)
    return 1.0 + 0.09 * strands + 0.06 * clumps + 0.03 * tips


def _fluff(c):
    p, ts = c["p"], c["ts"]
    puffs = fbm(p, 3.5, ts, 3, seed=41.0)
    big = fbm(p, 10.0, ts, 2, seed=43.0)
    return 1.0 + 0.07 * puffs + 0.05 * big


def _paper(c):
    p, ts = c["p"], c["ts"]
    fibre = fbm(_squash(p, c["axis"], 3.0), 1.5, ts, 2, seed=51.0)
    mott = fbm(p, 16.0, ts, 3, seed=53.0)
    return 1.0 + 0.025 * fibre + 0.03 * mott


def _highlight(c, power=10.0, amount=0.08):
    """A painted glossy highlight on the parts facing a fixed key light (front-left, high)."""
    key = np.array([-0.35, -0.55, 0.76], np.float32)
    key /= np.linalg.norm(key)
    h = np.clip(c["n"] @ key, 0.0, 1.0) ** power
    return amount * h


def _plastic(c):
    p, ts = c["p"], c["ts"]
    return 1.0 + 0.018 * fbm(p, 9.0, ts, 3, seed=61.0) + _highlight(c, 12.0, 0.07)


def _rubber(c):
    p, ts = c["p"], c["ts"]
    return 1.0 + 0.04 * fbm(p, 1.6, ts, 2, seed=71.0) + 0.03 * fbm(p, 10.0, ts, 2, seed=73.0)


def _metal(c):
    p, ts = c["p"], c["ts"]
    brushed = fbm(_squash(p - c["centre"], c["axis"], 8.0), 1.5, ts, 3, seed=81.0)
    return 1.0 + 0.07 * brushed + 0.025 * fbm(p, 8.0, ts, 2, seed=83.0) + _highlight(c, 8.0, 0.1)


def _glass(c):
    return 1.0 + _highlight(c, 16.0, 0.06)


def _ceramic(c):
    p, ts = c["p"], c["ts"]
    sp = noise3(p / 1.1 + 91.0)
    speck = _smooth(0.45, 0.6, sp) * _aa(1.1, ts, 1.5, 3.0)
    return 1.0 - 0.07 * speck + 0.03 * fbm(p, 12.0, ts, 3, seed=93.0) + _highlight(c, 10.0, 0.07)


def _leaf(c):
    p, ts = c["p"], c["ts"]
    rel = p - c["centre"]
    veins = fbm(_squash(rel, c["axis"], 6.0), 2.4, ts, 3, seed=101.0)
    return 1.0 + 0.07 * veins + 0.04 * fbm(p, 10.0, ts, 3, seed=103.0) + _highlight(c, 10.0, 0.05)


def _rope(c):
    p, ts = c["p"], c["ts"]
    period = 4.0
    warp = fbm(p, 6.0, ts, 2, seed=115.0) * 0.6
    hatch = _tri(lambda s, t: np.sin(2 * np.pi * ((s + t) / period + warp)), p, c["n"])
    hatch = np.sign(hatch) * np.abs(hatch) ** 0.5 * _aa(period, ts, 2.5, 5.0)
    return 1.0 + 0.06 * hatch + 0.035 * fbm(p, 1.5, ts, 2, seed=111.0) + 0.03 * fbm(p, 12.0, ts, 2, seed=113.0)


def _felt(c):
    p, ts = c["p"], c["ts"]
    return 1.0 + 0.05 * fbm(p, 1.2, ts, 3, seed=121.0) + 0.04 * fbm(p, 8.0, ts, 2, seed=123.0)


def _wicker(c):
    return _wood(c, figure=0.6, streak=1.4, ring=2.5)


def _soil(c):
    p, ts = c["p"], c["ts"]
    sp = noise3(p / 0.9 + 131.0)
    return 1.0 + 0.09 * np.tanh(3 * sp) * _aa(0.9, ts, 1.5, 3.0) + 0.05 * fbm(p, 5.0, ts, 2, seed=133.0)


def _painted(c):
    p, ts = c["p"], c["ts"]
    strokes = fbm(_squash(p - c["centre"], c["axis"], 3.0), 5.0, ts, 3, seed=141.0)
    return 1.0 + 0.035 * strokes + 0.025 * fbm(p, 20.0, ts, 2, seed=143.0)


def _flat(c):
    return np.ones(len(c["p"]), np.float32)


PATTERNS = {"painted": _painted, "wood": _wood, "paintwood": _paintwood, "fabric": _fabric, "knit": _knit,
            "fur": _fur, "fluff": _fluff, "paper": _paper, "plastic": _plastic, "rubber": _rubber, "metal": _metal,
            "glass": _glass, "ceramic": _ceramic, "leaf": _leaf, "rope": _rope, "felt": _felt, "wicker": _wicker,
            "print": _paper,
            "soil": _soil, "decal": _flat, "eye": _flat, "ink": _flat}


# ---------------------------------------------------------------- mesh preparation
def _is_target(o) -> bool:
    """Bodies textured from the palette: the main body and K.textured_object parts."""
    if o.type != "MESH" or o.hide_render or o.name.endswith(("_Outline", "_Base", "_Unit", "_Pin")):
        return False
    if "pal" not in o.data.attributes or not o.data.materials:
        return False
    m = o.data.materials[0]
    return m is not None and m.name.startswith("Palette")


def _parts(me):
    """Connected pieces -> (part id per face, number of parts)."""
    nv = len(me.vertices)
    parent = np.arange(nv)

    def find(i):
        root = i
        while parent[root] != root:
            root = parent[root]
        while parent[i] != root:
            parent[i], i = root, parent[i]
        return root

    for poly in me.polygons:
        vs = poly.vertices
        r0 = find(vs[0])
        for v in vs[1:]:
            r = find(v)
            if r != r0:
                parent[r] = r0
    roots = np.array([find(i) for i in range(nv)])
    uniq, vpart = np.unique(roots, return_inverse=True)
    fpart = np.array([vpart[p.vertices[0]] for p in me.polygons], np.int64)
    return fpart, len(uniq)


def _part_frames(me, fpart, nparts, seed):
    """Per part: area-weighted centre, principal (long) axis and a random number."""
    nf = len(me.polygons)
    cen = np.zeros((nf, 3))
    area = np.zeros(nf)
    me.polygons.foreach_get("center", cen.ravel())
    me.polygons.foreach_get("area", area)
    area = np.maximum(area, 1e-9)
    centres = np.zeros((nparts, 3))
    axes = np.zeros((nparts, 3))
    rng = np.random.RandomState(seed)
    rand = rng.random_sample(nparts)
    order = np.argsort(fpart)
    bounds = np.searchsorted(fpart[order], np.arange(nparts + 1))
    for k in range(nparts):
        idx = order[bounds[k]:bounds[k + 1]]
        w = area[idx]
        c = (cen[idx] * w[:, None]).sum(0) / w.sum()
        d = cen[idx] - c
        cov = (d * w[:, None]).T @ d / w.sum()
        if len(idx) < 3 or np.trace(cov) < 1e-12:
            ax = np.array([0.0, 0.0, 1.0])
        else:
            vals, vecs = np.linalg.eigh(cov)
            ax = vecs[:, 2]
            if vals[2] < 1.15 * vals[1]:  # no clear long axis (balls, squares): vertical
                ax = np.array([0.0, 0.0, 1.0]) if abs(vecs[2, 0]) < 0.9 else vecs[:, 1]
        centres[k] = c
        axes[k] = ax / max(np.linalg.norm(ax), 1e-9)
    return centres.astype(np.float32), axes.astype(np.float32), rand.astype(np.float32)


def _hidden_faces(obj) -> np.ndarray:
    """Faces fully buried inside other pieces: every test ray leaves them through a back face."""
    me = obj.data
    verts = [v.co.copy() for v in me.vertices]
    polys = [tuple(p.vertices) for p in me.polygons]
    bvh = BVHTree.FromPolygons(verts, polys, all_triangles=False, epsilon=0.0)
    size = max((Vector(np.max([v[:] for v in verts], 0)) - Vector(np.min([v[:] for v in verts], 0))).length, 1e-3)
    eps = size * 2e-4
    hidden = np.zeros(len(polys), bool)
    for f in me.polygons:
        n = f.normal
        if n.length < 0.5:
            continue
        t1 = n.orthogonal().normalized()
        t2 = n.cross(t1)
        dirs = [n] + [(n + 0.9 * t).normalized() for t in (t1, -t1, t2, -t2)]
        c = Vector(f.center)
        vs = [verts[v] for v in f.vertices]
        pts = [c] + [c.lerp(v, 0.95) for v in vs] + [c.lerp((a + b) / 2, 0.95) for a, b in zip(vs, vs[1:] + vs[:1])]
        buried = True
        for pt in pts:
            o = pt + n * eps
            for d in dirs:
                loc, nrm, idx, dist = bvh.ray_cast(o, d)
                if loc is None or nrm.dot(d) <= 0.0:
                    buried = False
                    break
            if not buried:
                break
        hidden[f.index] = buried
    return hidden


def _welded_copy(me):
    """A copy of the mesh with coincident vertices merged (same faces, same corner order), so pieces
    built from loose triangles (the posters' lettering) unwrap as one island instead of hundreds;
    a plain copy if welding changed the faces."""
    co = np.empty(len(me.vertices) * 3, np.float32)
    me.vertices.foreach_get("co", co)
    co = co.reshape(-1, 3)
    dist = float(np.linalg.norm(co.max(0) - co.min(0))) * 1e-5 + 1e-7
    bm = bmesh.new()
    bm.from_mesh(me)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=dist)
    w = bpy.data.meshes.new("_unwrap")
    bm.to_mesh(w)
    bm.free()
    if len(w.polygons) == len(me.polygons) and len(w.loops) == len(me.loops):
        lv, lw = np.empty(len(me.loops), np.int32), np.empty(len(w.loops), np.int32)
        me.loops.foreach_get("vertex_index", lv)
        w.loops.foreach_get("vertex_index", lw)
        cw = np.empty(len(w.vertices) * 3, np.float32)
        w.vertices.foreach_get("co", cw)
        if np.allclose(co[lv], cw.reshape(-1, 3)[lw], atol=dist * 4 + 1e-6):
            return w
    bpy.data.meshes.remove(w)
    return me.copy()


def _unwrap(obj, hidden, res, margin_px, weight, flat, pal, hidden_scale=0.12):
    """Adds the bake UV map 'BakeUV' (made active): visible and hidden faces unwrapped separately (on
    a welded copy, see _welded_copy), islands brought to one texel density, then scaled by their
    texel budget (`weight` per face; small flat islands get more, big ones less), hidden ones
    shrunk, everything packed with a margin."""
    work = _welded_copy(obj.data)
    tmp = bpy.data.objects.new("_unwrap", work)
    K.link(tmp)
    tmp.matrix_world = obj.matrix_world.copy()
    _unwrap_mesh(tmp, hidden, res, margin_px, weight, flat, pal, hidden_scale)
    uvs = np.empty(len(work.loops) * 2, np.float32)
    work.uv_layers["BakeUV"].data.foreach_get("uv", uvs)
    bpy.data.objects.remove(tmp)
    bpy.data.meshes.remove(work)
    me = obj.data
    uv = me.uv_layers.new(name="BakeUV")
    uv.data.foreach_set("uv", uvs)
    me.uv_layers.active = uv


def _unwrap_mesh(obj, hidden, res, margin_px, weight, flat, pal, hidden_scale):
    me = obj.data
    for old in list(me.uv_layers):
        me.uv_layers.remove(old)
    uv = me.uv_layers.new(name="BakeUV")
    me.uv_layers.active = uv
    vl = bpy.context.view_layer
    for o in vl.objects:
        o.select_set(False)
    obj.select_set(True)
    vl.objects.active = obj
    ts = bpy.context.scene.tool_settings
    ts.use_uv_select_sync = True
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_mode(type="FACE")
    bm = bmesh.from_edit_mesh(me)
    bm.faces.ensure_lookup_table()
    groups = [np.where(~hidden)[0], np.where(hidden)[0]]
    for g in groups:
        if len(g) == 0:
            continue
        for f in bm.faces:
            f.select = False
        for i in g:
            bm.faces[int(i)].select = True
        bmesh.update_edit_mesh(me)
        bpy.ops.uv.smart_project(angle_limit=math.radians(62), island_margin=0.0, area_weight=0.0,
                                 correct_aspect=True, scale_to_bounds=False)
        bm = bmesh.from_edit_mesh(me)
        bm.faces.ensure_lookup_table()
    for f in bm.faces:
        f.select = True
    bmesh.update_edit_mesh(me)
    bpy.ops.uv.average_islands_scale()
    bm = bmesh.from_edit_mesh(me)
    bm.faces.ensure_lookup_table()
    lay = bm.loops.layers.uv["BakeUV"]
    total = max(sum(f.calc_area() for f in bm.faces), 1e-9)
    for isl in bmesh_linked_uv_islands(bm, lay):
        idx = [f.index for f in isl]
        if hidden[idx].all():
            k = hidden_scale
        else:
            wi = weight[idx]
            pat = wi[~flat[idx]]
            k = float(pat.max()) if len(pat) else 0.5      # the island's finest pattern
            fl = wi[flat[idx]]
            if len(fl) and len(set(pal[idx].tolist())) == 1:
                k = max(k, 0.2)  # one flat colour (a pupil, a poster's ink backing): any size shows it
            elif len(fl):  # flat colours meeting other colours inside the island (a mouth stroke, an
                frac = sum(f.calc_area() for f in isl) / total  # eye's rim): small islands get extra
                boost = float(fl.max())                          # texels so the line stays crisp
                boost = 1.0 + (boost - 1.0) * min(1.0, max(0.0, 1.0 - frac / 0.02))  # tapers off by 2%
                t = min(1.0, max(0.0, frac / 0.02 - 1.0))                         # ... then to 0.5 by 4%
                k = max(k, boost * (1 - t) + 0.5 * t)
        if abs(k - 1.0) < 1e-3:
            continue
        loops = [lp for f in isl for lp in f.loops]
        c = sum((lp[lay].uv for lp in loops), Vector((0.0, 0.0))) / len(loops)
        for lp in loops:
            lp[lay].uv = c + (lp[lay].uv - c) * k
    bmesh.update_edit_mesh(me)
    # islands sit margin_px / 2 apart: the bake still dilates each one margin_px into the gaps (so
    # bilinear filtering and the first mip levels never see an empty gutter), but a full margin_px
    # gap round each of a prop's hundreds of small islands would leave a third of the texture empty
    bpy.ops.uv.pack_islands(rotate=True, rotate_method="ANY", scale=True, margin_method="FRACTION",
                            margin=0.5 * margin_px / res, shape_method="AABB")  # CONCAVE: ~3% denser, 30 s slower
    bpy.ops.object.mode_set(mode="OBJECT")
    obj.select_set(False)


def _texel_size(me, scale, hidden, res, face_class):
    """Texel size in pattern studs over the visible faces: {class: size} and the overall average."""
    uv = me.uv_layers["BakeUV"].data
    a3, a2 = {}, {}
    for f in me.polygons:
        if hidden[f.index]:
            continue
        c = face_class[f.index]
        pts = [uv[li].uv for li in f.loop_indices]
        s = 0.0
        for i in range(1, len(pts) - 1):
            e1, e2 = pts[i] - pts[0], pts[i + 1] - pts[0]
            s += abs(e1.x * e2.y - e1.y * e2.x) / 2
        a3[c] = a3.get(c, 0.0) + f.area
        a2[c] = a2.get(c, 0.0) + s

    def size(x3, x2):
        return math.sqrt(x3 * scale * scale / (x2 * res * res)) if x2 > 0 else 1.0

    per = {c: size(a3[c], a2[c]) for c in a3}
    return per, size(sum(a3.values()), sum(a2.values()))


# ---------------------------------------------------------------- Cycles helper bakes
def _occluder(obj, skip_pal: set, eps):
    """A copy of obj without the outline-coloured faces (ink, merged hulls), pulled in by eps, that
    casts the AO (obj itself is invisible to AO rays during the bake)."""
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    lay = bm.faces.layers.int.get("pal")
    bmesh.ops.delete(bm, geom=[f for f in bm.faces if f[lay] in skip_pal], context="FACES")
    bm.normal_update()
    for v in bm.verts:
        v.co -= v.normal * eps
    me = bpy.data.meshes.new(obj.name + "_occ")
    bm.to_mesh(me)
    bm.free()
    occ = bpy.data.objects.new(obj.name + "_occ", me)
    K.link(occ)
    occ.matrix_world = obj.matrix_world.copy()
    return occ


def _bake_maps(obj, res, margin_px, ao_near, ao_far, samples, skip_pal):
    """Bakes the helper maps on obj's BakeUV -> dict of float arrays (res, res, 4)."""
    scn = bpy.context.scene
    scn.render.engine = "CYCLES"
    scn.cycles.device = "CPU"
    scn.cycles.use_denoising = False
    scn.render.bake.margin = margin_px
    scn.render.bake.margin_type = "ADJACENT_FACES"
    me = obj.data
    co = np.empty(len(me.vertices) * 3, np.float32)
    me.vertices.foreach_get("co", co)
    co = co.reshape(-1, 3)
    lo, hi = Vector(co.min(0)), Vector(co.max(0))  # object space, like the Object texture coordinate
    lo -= Vector((0.01, 0.01, 0.01))
    span = (hi - lo) + Vector((0.02, 0.02, 0.02))
    size = max(span)
    occ = _occluder(obj, skip_pal, size * 3e-4)

    mat = bpy.data.materials.new("TexBake")
    mat.use_nodes = True
    nt = mat.node_tree
    for nd in list(nt.nodes):
        nt.nodes.remove(nd)
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    emit = nt.nodes.new("ShaderNodeEmission")
    nt.links.new(emit.outputs[0], out.inputs["Surface"])
    uvn = nt.nodes.new("ShaderNodeUVMap")
    uvn.uv_map = "UVMap"
    pal = nt.nodes.new("ShaderNodeTexImage")
    pal.image = K._PALETTE_IMG
    pal.interpolation = "Closest"
    nt.links.new(uvn.outputs[0], pal.inputs[0])
    texco = nt.nodes.new("ShaderNodeTexCoord")
    geo = nt.nodes.new("ShaderNodeNewGeometry")
    sub = nt.nodes.new("ShaderNodeVectorMath")
    sub.operation = "SUBTRACT"
    sub.inputs[1].default_value = lo
    nt.links.new(texco.outputs["Object"], sub.inputs[0])
    div = nt.nodes.new("ShaderNodeVectorMath")
    div.operation = "DIVIDE"
    div.inputs[1].default_value = span
    nt.links.new(sub.outputs[0], div.inputs[0])
    vt = nt.nodes.new("ShaderNodeVectorTransform")
    vt.vector_type = "NORMAL"
    vt.convert_from = "WORLD"
    vt.convert_to = "OBJECT"
    nt.links.new(geo.outputs["Normal"], vt.inputs[0])
    nrm = nt.nodes.new("ShaderNodeVectorMath")
    nrm.operation = "MULTIPLY_ADD"
    nrm.inputs[1].default_value = (0.5, 0.5, 0.5)
    nrm.inputs[2].default_value = (0.5, 0.5, 0.5)
    nt.links.new(vt.outputs[0], nrm.inputs[0])
    aos = []
    for d in (ao_near, ao_far):
        ao = nt.nodes.new("ShaderNodeAmbientOcclusion")
        ao.only_local = False
        ao.inside = False
        ao.samples = 8
        ao.inputs["Distance"].default_value = d
        aos.append(ao)
    ao_c = nt.nodes.new("ShaderNodeCombineXYZ")
    nt.links.new(aos[0].outputs["AO"], ao_c.inputs[0])
    nt.links.new(aos[1].outputs["AO"], ao_c.inputs[1])
    a_pal = nt.nodes.new("ShaderNodeAttribute")
    a_pal.attribute_name = "tex_pal"
    a_part = nt.nodes.new("ShaderNodeAttribute")
    a_part.attribute_name = "tex_part"
    id_c = nt.nodes.new("ShaderNodeCombineXYZ")
    nt.links.new(a_pal.outputs["Fac"], id_c.inputs[0])
    nt.links.new(a_part.outputs["Fac"], id_c.inputs[1])
    id_c.inputs[2].default_value = 1.0  # coverage: 1 on faces and their margin, 0 where nothing was baked
    target = nt.nodes.new("ShaderNodeTexImage")

    saved_mats = list(me.materials)
    me.materials.clear()
    me.materials.append(mat)
    saved_hide = {o.name: o.hide_render for o in scn.objects}
    for o in scn.objects:
        if o not in (obj, occ):
            o.hide_render = True
    saved_shadow = obj.visible_shadow
    obj.visible_shadow = False
    vl = bpy.context.view_layer
    for o in vl.objects:
        o.select_set(False)
    obj.select_set(True)
    vl.objects.active = obj

    passes = [("col", pal.outputs["Color"], 8), ("ao", ao_c.outputs[0], samples),
              ("pos", div.outputs[0], 4), ("nrm", nrm.outputs[0], 4), ("id", id_c.outputs[0], 1)]
    maps = {}
    try:
        for key, sock, spp in passes:
            img = bpy.data.images.new(f"bake_{key}", res, res, alpha=True, float_buffer=True)
            img.colorspace_settings.name = "Non-Color" if key != "col" else "Linear Rec.709"
            target.image = img
            nt.nodes.active = target
            nt.links.new(sock, emit.inputs["Color"])
            scn.cycles.samples = spp
            bpy.ops.object.bake(type="EMIT", uv_layer="BakeUV", margin=margin_px, margin_type="ADJACENT_FACES",
                                use_clear=True, target="IMAGE_TEXTURES")
            arr = np.empty(res * res * 4, np.float32)
            img.pixels.foreach_get(arr)
            maps[key] = arr.reshape(res, res, 4)
            bpy.data.images.remove(img)
    finally:
        me.materials.clear()
        for m in saved_mats:
            me.materials.append(m)
        for o in scn.objects:
            if o.name in saved_hide:
                o.hide_render = saved_hide[o.name]
        obj.visible_shadow = saved_shadow
        bpy.data.objects.remove(occ)
        bpy.data.materials.remove(mat)
    maps["pos"][..., :3] = maps["pos"][..., :3] * np.array(span, np.float32) + np.array(lo, np.float32)
    maps["nrm"][..., :3] = maps["nrm"][..., :3] * 2.0 - 1.0
    return maps


# ---------------------------------------------------------------- painting
def _srgb(lin):
    lin = np.clip(lin, 0.0, 1.0)
    return np.where(lin <= 0.0031308, lin * 12.92, 1.055 * np.power(lin, 1 / 2.4) - 0.055)


def _fill(img, mask):
    """Push-pull fill of the texels outside `mask` (so mip levels and JPEG blocks stay calm)."""
    levels = []
    cur = img * mask[..., None]
    w = mask.astype(np.float32)
    while cur.shape[0] > 1:
        levels.append((cur, w))
        h = cur.shape[0] // 2
        cur = cur[:2 * h, :2 * h].reshape(h, 2, h, 2, -1).sum((1, 3))
        w = w[:2 * h, :2 * h].reshape(h, 2, h, 2).sum((1, 3))
    filled = cur / np.maximum(w, 1e-6)[..., None]
    for cur, w in reversed(levels):
        up = np.repeat(np.repeat(filled, 2, 0), 2, 1)
        col = cur / np.maximum(w, 1e-6)[..., None]
        filled = np.where((w > 0)[..., None], col, up)
    return np.where(mask[..., None], img, filled)


def _curvature(pos, nrm, cov, scale):
    """Mean curvature (1 / pattern stud, + = convex) from neighbouring texels."""
    k = np.zeros(pos.shape[:2], np.float32)
    cnt = np.zeros(pos.shape[:2], np.float32)
    for ax in (0, 1):
        dp = (np.roll(pos, -1, ax) - pos) * scale
        dn = np.roll(nrm, -1, ax) - nrm
        ok = cov & np.roll(cov, -1, ax)
        l2 = (dp * dp).sum(-1)
        kk = (dn * dp).sum(-1) / np.maximum(l2, 1e-9)
        ok &= l2 > 1e-10
        k += np.where(ok, kk, 0)
        cnt += ok
    return k / np.maximum(cnt, 1)


def _blur(a, r=1):
    out = a.copy()
    for ax in (0, 1):
        acc = out.copy()
        for s in range(1, r + 1):
            acc += np.roll(out, s, ax) + np.roll(out, -s, ax)
        out = acc / (2 * r + 1)
    return out


def _sock_coords(p, kmask, side, scale):
    """Tube coordinates for a sock body: stitch columns around the leg (axis = z through the origin)
    and around the foot (axis ~ x), rows along them; w_leg blends the two at the heel / instep."""
    cols = 22
    row_h = 1.6 / scale  # rows in model units
    x, y, z = p[:, 0], p[:, 1], p[:, 2]
    s_leg = np.arctan2(y, x) / (2 * np.pi) * cols
    t_leg = z / row_h
    if side == "S":
        w = np.ones(len(p), np.float32)
        return dict(s_leg=s_leg, t_leg=t_leg, s_foot=s_leg, t_foot=t_leg, w_leg=w)
    sgn = -1.0 if side == "L" else 1.0
    foot = kmask & (z < 1.3) & (x * sgn > 0.9)
    if foot.sum() > 50:
        yf, zf = float(np.median(y[foot])), float(np.median(z[foot]))
    else:
        yf, zf = 0.0, 0.62
    rf = 0.62
    s_foot = np.arctan2(z - zf, y - yf) / (2 * np.pi) * cols
    t_foot = (x * sgn) / row_h
    d_leg = np.sqrt(x * x + y * y) / 0.7 - 1.0
    d_foot = np.sqrt((y - yf) ** 2 + (z - zf) ** 2) / rf - 1.0
    w_leg = _smooth(-0.2, 0.2, d_foot - d_leg + 0.6 * (z - 1.4))
    return dict(s_leg=s_leg, t_leg=t_leg, s_foot=s_foot, t_foot=t_foot, w_leg=w_leg)


def paint(maps, classes_by_pal, part_info, scale, ts_class, sock_side=None, ao_k=1.0, seed=0):
    """Paints the texture (res, res, 3) sRGB floats from the helper maps. `ts_class`: texel size in
    pattern studs per class (patterns too fine for it fade out instead of aliasing)."""
    ts = max(ts_class.values()) if ts_class else 1.0
    cov = maps["id"][..., 2] > 0.5
    col = _srgb(maps["col"][..., :3])
    pos = maps["pos"][..., :3]
    nrm = maps["nrm"][..., :3]
    nrm = nrm / np.maximum(np.linalg.norm(nrm, axis=-1, keepdims=True), 1e-6)
    pal_id = np.rint(maps["id"][..., 0]).astype(np.int64)
    part = np.clip(np.rint(maps["id"][..., 1]).astype(np.int64), 0, len(part_info[0]) - 1)
    # soft AO: mostly the near radius, and a gamma so half-open surfaces barely darken while real
    # crevices still do (a straight mix took ~20% off a whole prop's brightness)
    ao = np.clip(maps["ao"][..., 0] * 0.65 + maps["ao"][..., 1] * 0.35, 0.0, 1.0) ** 0.6

    curv = _blur(_curvature(pos, nrm, cov, scale), 1)

    idx = np.where(cov.ravel())[0]
    P = pos.reshape(-1, 3)[idx] * scale
    N = nrm.reshape(-1, 3)[idx]
    pid = part.ravel()[idx]
    pal = pal_id.ravel()[idx]
    cls_names = list(CLASSES)
    cls_of_pal = np.full(max(pal.max() + 1, max(classes_by_pal, default=0) + 1), cls_names.index(DEFAULT_CLASS))
    for k, v in classes_by_pal.items():
        cls_of_pal[k] = cls_names.index(v)
    cls = cls_of_pal[np.clip(pal, 0, len(cls_of_pal) - 1)]
    soft = ("fabric", "fur", "fluff", "felt")
    EDGE_LIGHT = np.array([0.0 if c in ("paper", "print", "decal", "eye", "ink") else (0.6 if c in soft else 1.0)
                           for c in cls_names], np.float32)
    centres, axes, rands = part_info
    mult = np.ones(len(idx), np.float32)
    ao_strength = np.zeros(len(idx), np.float32)
    painted = np.zeros(len(idx), bool)
    sock_all = None
    if sock_side:
        sock_all = _sock_coords(pos.reshape(-1, 3)[idx], cls == cls_names.index("knit"), sock_side, scale)
    for ci, cname in enumerate(cls_names):
        sel = np.where(cls == ci)[0]
        if len(sel) == 0:
            continue
        strength, aok = CLASSES[cname]
        ao_strength[sel] = aok
        if cname in ("ink",):
            continue
        painted[sel] = True
        c = dict(p=P[sel], n=N[sel], axis=axes[pid[sel]], centre=centres[pid[sel]] * scale,
                 rand=rands[pid[sel]], ts=ts_class.get(cname, ts))
        if sock_all is not None and cname == "knit":
            c["sock"] = {k: v[sel] for k, v in sock_all.items()}
        mult[sel] = 1.0 + strength * (PATTERNS[cname](c) - 1.0)

    # hand-painted shading on top of the pattern (everything but ink)
    a = ao.ravel()[idx]
    occl = 1.0 - ao_k * ao_strength * (1.0 - a)
    nz = N[:, 2]
    light = 1.0 + np.where(painted, 0.035 * np.clip(nz, 0, 1) - 0.03 * np.clip(-nz, 0, 1), 0.0)
    kv = curv.ravel()[idx]
    ek = EDGE_LIGHT[cls]  # no rim light on flat print (posters, labels): the layer edges would sparkle
    edge = ek * (0.07 * _smooth(0.12, 0.5, kv) - 0.04 * _smooth(0.15, 0.6, -kv))
    var = np.where(painted, 0.03 * fbm(P, 30.0, ts, 2, seed=seed + 0.5) + 0.02 * (rands[pid] - 0.5), 0.0)
    value = mult * light * (1.0 + edge + var)
    base = col.reshape(-1, 3)[idx]
    # occlusion darkens with a slightly cool tint (the night palette), never shifts the hue much
    tint = np.array([1.08, 1.04, 0.9], np.float32)
    shade = np.power(np.clip(occl, 1e-3, 1.0)[:, None], tint[None, :])
    out = np.clip(base * value[:, None] * shade, 0.0, 1.0)
    out = np.nan_to_num(out, nan=0.5)
    img = col.copy()
    img.reshape(-1, 3)[idx] = out
    seen = maps["ao"][..., 0].ravel()[idx] > 0.35  # leave out texels buried in crevices / inside pieces
    return _fill(img, cov), _colour_shift(base[seen], out[seen])


def _colour_shift(base, out):
    """(mean brightness ratio painted / palette, mean hue shift in degrees over the coloured texels)."""
    if len(base) == 0:
        return 1.0, 0.0
    lum = np.array([0.2126, 0.7152, 0.0722], np.float32)
    ratio = float((out @ lum).mean() / max(float((base @ lum).mean()), 1e-6))

    def hue(c):
        mx, mn = c.max(1), c.min(1)
        d = np.maximum(mx - mn, 1e-6)
        r, g, b = c[:, 0], c[:, 1], c[:, 2]
        h = np.where(mx == r, (g - b) / d % 6, np.where(mx == g, (b - r) / d + 2, (r - g) / d + 4))
        return h * 60.0, (mx - mn) / np.maximum(mx, 1e-6)

    hb, sb = hue(base)
    ho, _ = hue(out)
    sel = sb > 0.2
    dh = np.abs((ho - hb + 180.0) % 360.0 - 180.0)
    return ratio, float(dh[sel].mean()) if sel.any() else 0.0


# ---------------------------------------------------------------- driver
def _res_for(scale, area_units, sock, main):
    """Texture size from how much surface there is: ~4 texels per pattern stud (so a room prop gets
    ~4 per game stud, a sock-sized thing ~40), 1024 at most (Roblox's cap), 512 for socks; main
    bodies get at least 512, small extra parts (the dryer's stars) may get 256."""
    need = math.sqrt(area_units * scale * scale * 16.0 / 0.6)  # packed islands fill ~60%
    r = 1024 if need > 600 else (512 if need > 250 else 256)
    if sock:
        r = min(r, 512)
    return max(r, 512) if main else r


def bake(objs, name, materials=None, sock_id=None, sock_side=None, res=None, samples=16, cache_dir=None,
         jpeg_quality=90, verbose=True):
    """Bakes the hand-painted texture onto every palette-textured body in `objs` (in place).
    `materials`: the prop module's MATERIALS overrides; `sock_id` / `sock_side` ("L", "R", "S") for
    sock bodies. Returns [(object name, texture size, class histogram)]."""
    sock = sock_id is not None
    scale = pattern_scale(name, objs, sock)
    report = []
    skip_pal = {K.OUTLINE}
    for obj in [o for o in objs if _is_target(o)]:
        me = obj.data
        pal_attr = me.attributes["pal"].data
        pal = np.array([d.value for d in pal_attr], np.int64)
        # classes of the colours this body uses
        classes, unknown = {}, []
        for pi in sorted(set(pal.tolist())):
            nm = K._ORDER[pi]
            c, ok = classify(nm, materials, sock_id)
            classes[pi] = c
            if not ok:
                unknown.append(nm)
        if all(c in FLAT for c in classes.values()):  # nothing to paint (the dryer's galaxy): keep the
            if verbose:                                 # crisp flat palette
                print(f"  bake {obj.name}: flat colours only, keeps the palette")
            report.append((obj.name, 0, {}))
            continue
        tick = [time.time()]
        fpart, nparts = _parts(me)
        seed = zlib.crc32(obj.name.encode())
        part_info = _part_frames(me, fpart, nparts, seed & 0xFFFF)
        hidden = _hidden_faces(obj)
        tick.append(time.time())
        area = np.zeros(len(me.polygons))
        me.polygons.foreach_get("area", area)
        weight = np.array([TEXEL_WEIGHT.get(classes[pi], 1.0) for pi in pal], np.float32)
        vis_area = float((area * np.minimum(weight, 1.0) ** 2)[~hidden].sum())  # area as packed
        r = res or _res_for(scale, vis_area, sock, obj is objs[0])
        margin = 8 if r >= 1024 else (6 if r >= 512 else 4)
        flat = np.array([classes[pi] in FLAT for pi in pal], bool)
        _unwrap(obj, hidden, r, margin, weight, flat, pal)
        tick.append(time.time())
        maps = None
        key = None
        if cache_dir:  # dev aid: reuse the Cycles maps (and the UV layout they belong to; packing varies)
            os.makedirs(cache_dir, exist_ok=True)
            used = ",".join(f"{pi}:{K._ORDER[pi]}" for pi in sorted(classes)) + repr(sorted(TEXEL_WEIGHT.items())) \
                + str(zlib.crc32(hidden.tobytes())) + "v2"
            lv = np.empty(len(me.loops), np.int32)
            me.loops.foreach_get("vertex_index", lv)
            co = np.empty(len(me.vertices) * 3, np.float32)
            me.vertices.foreach_get("co", co)
            geo = zlib.crc32(np.round(co.reshape(-1, 3)[lv], 4).tobytes())  # same mesh, same loop order
            key = os.path.join(cache_dir, f"{obj.name}_{r}_{samples}_{zlib.crc32(used.encode())}_{geo}.npz")
            if os.path.exists(key):
                maps = dict(np.load(key))
                me.uv_layers["BakeUV"].data.foreach_set("uv", maps.pop("uv").ravel())
        ts_class, ts = _texel_size(me, scale, hidden, r, [classes[pi] for pi in pal])
        a = me.attributes.new("tex_pal", "FLOAT", "FACE")
        a.data.foreach_set("value", pal.astype(np.float32))
        b = me.attributes.new("tex_part", "FLOAT", "FACE")
        b.data.foreach_set("value", fpart.astype(np.float32))
        lo, hi = _bounds([obj])
        dims = hi - lo
        cube = max((dims.x * dims.y * dims.z) ** (1 / 3), 0.25 * max(dims))
        ao_near = min(5.0 / scale, 0.1 * cube)
        if maps is None:
            maps = _bake_maps(obj, r, margin, ao_near, ao_near * 3.0, samples, skip_pal)
            if key:
                uvs = np.empty(len(me.loops) * 2, np.float32)
                me.uv_layers["BakeUV"].data.foreach_get("uv", uvs)
                np.savez_compressed(key, uv=uvs, **maps)
        tick.append(time.time())
        img, (bright, hue) = paint(maps, classes, part_info, scale, ts_class, sock_side=sock_side,
                                   seed=float(seed % 997))
        tick.append(time.time())
        _apply(obj, img, jpeg_quality)
        me.attributes.remove(me.attributes["tex_pal"])
        me.attributes.remove(me.attributes["tex_part"])
        hist = {}
        for pi, c in classes.items():
            hist[c] = hist.get(c, 0) + int((pal == pi).sum())
        report.append((obj.name, r, hist))
        if verbose:
            hid = int(hidden.sum())
            dt = np.diff(tick)
            print(f"  bake {obj.name}: {r}px, {scale:.1f} pattern studs/unit, texel {ts:.2f} studs, "
                  f"{hid}/{len(hidden)} faces hidden, classes "
                  + ", ".join(f"{k}:{v}" for k, v in sorted(hist.items())))
            print(f"  bake {obj.name}: {sum(dt):.0f}s (hidden {dt[0]:.0f}, unwrap {dt[1]:.0f}, cycles {dt[2]:.0f}, "
                  f"paint {dt[3]:.0f}); brightness x{bright:.3f}, hue shift {hue:.1f} deg")
            if unknown:
                print(f"  bake {obj.name}: default '{DEFAULT_CLASS}' for " + ", ".join(unknown))
    return report


def _apply(obj, img, quality):
    """One image material on the bake UV, which becomes the body's only UV map ("UVMap")."""
    from PIL import Image
    arr = (np.clip(img, 0, 1) * 255 + 0.5).astype(np.uint8)
    arr = arr[::-1]  # Blender rows are bottom-up
    fd, path = tempfile.mkstemp(suffix=".jpg", prefix=obj.name + "_")
    os.close(fd)
    Image.fromarray(arr, "RGB").save(path, quality=quality, subsampling=0, optimize=True)
    bimg = bpy.data.images.load(path)
    bimg.name = obj.name + "_Paint"
    bimg.pack()
    bimg.filepath_raw = "//" + obj.name + "_Paint.jpg"
    os.remove(path)
    me = obj.data
    me.uv_layers.remove(me.uv_layers["UVMap"])
    me.uv_layers["BakeUV"].name = "UVMap"
    me.uv_layers.active = me.uv_layers["UVMap"]
    mat = bpy.data.materials.new(obj.name + "_Paint")
    mat.use_backface_culling = True
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = nt.nodes.get("Principled BSDF")
    bsdf.inputs["Roughness"].default_value = 0.85
    if "Specular IOR Level" in bsdf.inputs:
        bsdf.inputs["Specular IOR Level"].default_value = 0.2
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = bimg
    tex.interpolation = "Linear"
    nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    me.materials.clear()
    me.materials.append(mat)
    obj["paint_image"] = bimg.name
