"""
JungleTemple background: temple ruins and waterfalls on a teal and cream
morning. A great stepped temple with a jade-lit shrine rises out of the
jungle on the left; on the right, tall cliffs pour three waterfalls (one
from a giant idol's mouth) into the mist, with a rope bridge to a ruined
arch on a lone pillar. Misty karst towers stand along the horizon around
the low morning sun, and near mist, fronds and fireflies frame the bottom.
"""

import math

from mathutils import Matrix, Vector

from maps import _props_a as P
from maps import _props_b as B
from vistas import _kit as K

MAP_ID = "JungleTemple"
SEED = 23

COLORS = {
    # temple stone (warm cream)
    "stone": "#e2d2a6",
    "stone_light": "#f3e8c4",
    "stone_mid": "#c7b48b",
    "stone_dark": "#988567",
    "stone_deep": "#4c4638",
    # moss and jungle
    "moss": "#7cb84e",
    "moss_dark": "#4f8f3d",
    "leaf": "#3f9c4b",
    "leaf_dark": "#2b7a3f",
    "leaf_light": "#66c15a",
    "leaf_yellow": "#a9cf4f",
    "palm": "#4fae52",
    "leaf_near": "#2c7444",
    "leaf_deep": "#1f5a3b",
    "rib": "#2a6634",
    "trunk": "#8b6a4b",
    "trunk_dark": "#6b4f37",
    "vine": "#3a8a3e",
    "root": "#74513a",
    # cliffs
    "cliff": "#d6ad7e",
    "cliff_mid": "#b78f68",
    "cliff_dark": "#86735d",
    # far karst towers
    "karst": "#86a892",
    "karst_dark": "#6f9484",
    "karst_top": "#4f9c66",
    "karst_top2": "#6cb276",
    "far_leaf": "#5ea47a",
    "far_leaf2": "#79b98c",
    # water
    "water": "#b4ecf2",
    "water_light": "#e0fafb",
    "foam": "#ffffff",
    "spray": "#f6fcf7",
    # wood and rope
    "plank": "#b07d4d",
    "plank_dark": "#86603d",
    "rope": "#d8b97f",
    # glow
    "jade": "#52ffb6",
    "jade_deep": "#26e0a0",
    "firefly": "#f4ff9e",
    "sun_gold": "#ffe08a",
    # flowers and birds
    "flower_pink": "#f2709a",
    "blossom": "#f59bbb",
    "blossom_dark": "#de7199",
    "flower_yellow": "#ffd24f",
    "flower_orange": "#ff9445",
    "macaw": "#e4553f",
    "bird": "#2e4d4a",
    # sky stuff
    "cloud": "#fffdf2",
    "mist": "#f4f1d6",
    "mist_teal": "#d6ecdf",
}

LOOK = {
    "dome": [(-0.35, "#d8e6bc"), (-0.02, "#fbefc2"), (0.04, "#f4edc0"), (0.11, "#bde4c8"), (0.22, "#62b6a0"),
             (0.42, "#2a8574")],
    "sun": (-0.18, 0.5),
    "sun_color": "#fffbe8",
    "sun_size": 2.6,
    "glow": "#fff0b4",
    "light_dir": (-0.45, 0.7, 0.55),
    "light": "#fff5d8",
    "mid": "#d9dcbc",
    "shadow": "#4b8489",
    "cloud_light": "#fffdf0",
    "cloud_mid": "#f2f0d8",
    "cloud_shadow": "#aed4c6",
    "rim": "#ffd98a",
    "ambient": "#a9d3c2",
    "fog_near": 400.0,
    "fog_far": 16000.0,
    "fog_max": 0.74,
    "sky_fog_scale": 2.3,
    "halo_size": 28.0,
    "halo_strength": 0.45,
    "ink": "#173330",
    "ink_soft": "#2a4a44",
    "glow_strength": 2.4,
}

LEAVES = ("leaf", "leaf_dark", "leaf_light")


def scene(v):
    r = K.rng(SEED)
    sky(v, r)
    canopy(v, r)
    temple(v, r)
    cliffs(v, r)
    haze(v, r)


# Props ----------------------------------------------------------------------


def sub(r):
    return K.rng(r.randrange(1 << 30))


def karst(p, base, height, width, r, rock="karst", top=("karst_top", "karst_top2"), lean=0.0, segments=10,
          pinch=None, smooth=True):
    """Limestone tower: a tall rounded column, bulging and pinched, with a
    jungle cap and a few green ledges. `pinch` (0..1) narrows its waist."""
    x, y, z = base
    w, h = width, height
    k = r.uniform(0.6, 0.95) if pinch is None else pinch
    prof = [(h, w * 0.24), (h * 0.97, w * 0.44), (h * 0.9, w * 0.52), (h * 0.78, w * 0.5 * (0.6 + 0.4 * k)),
            (h * 0.62, w * 0.42 * k + w * 0.06), (h * 0.46, w * 0.44 * k + w * 0.08), (h * 0.26, w * 0.56),
            (0.0, w * 0.7)]
    P.lathe(p, (x, y, z), prof, rock, segments=segments, jitter=0.14, rng=sub(r), spin=r.uniform(0, 40),
            smooth=smooth, lean=(lean, 0.0))
    tx = x - lean * h
    # jungle cap draping over the rounded top
    p.sphere((tx, y + h * 0.94, z), (w * 0.56, w * 0.3, w * 0.52), top[0], segments=12, rings=8)
    for side in (-1, 1):
        p.sphere((tx + side * w * 0.36, y + h * 0.9 - r.uniform(0, 0.04) * h, z + w * 0.12),
                 (w * 0.26, w * 0.2, w * 0.3), top[1], segments=10, rings=6)
    for k in range(3):
        t = k - 1
        rad = w * r.uniform(0.2, 0.26)
        p.sphere((tx + t * w * 0.24, y + h + rad * 0.3 - abs(t) * w * 0.08, z + r.uniform(-0.1, 0.15) * w),
                 (rad, rad * 0.85, rad), top[k % 2], segments=10, rings=6)
    for k in range(r.randint(1, 3)):
        f = r.uniform(0.3, 0.7)
        side = r.choice((-1, 1))
        ledge_x = tx + lean * h * (1 - f) + side * w * 0.4
        p.sphere((ledge_x, y + h * f, z + w * 0.2), (w * 0.2, w * 0.09, w * 0.18), top[1], segments=8, rings=5)


def mist_bank(p, center, length, height, r, colors=("mist",), puffs=None):
    """A low bank of mist: long flat overlapping puffs, highest mid-bank."""
    cx, cy, cz = center
    n = puffs or max(3, int(length / (height * 2.2)))
    for i in range(n):
        t = (i / (n - 1)) * 2 - 1
        rad = height * (0.75 + r.random() * 0.4) * (1 - 0.45 * t * t)
        p.sphere((cx + t * length / 2, cy + rad * 0.25, cz + r.uniform(-0.3, 0.3) * height),
                 (rad * 2.2, rad * 0.7, rad * 1.2), colors[i % len(colors)], segments=14, rings=7)


def jungle_tree(p, base, height, crown, r, colors=LEAVES, lean=0.0, trunk="trunk"):
    """Broadleaf jungle tree scaled by `crown` (about the crown's half
    width): tapered trunk with buttress roots and a puffy crown."""
    x, y, z = base
    c = crown
    top = Vector((x + lean, y + height, z))
    p.limb((x, y, z), tuple(top), c * 0.09, c * 0.06, trunk, segments=7, caps=False)
    for side in (-1, 1):
        p.limb((x + side * c * 0.17, y - c * 0.03, z + c * 0.04), (x, y + height * 0.3, z), c * 0.05, c * 0.02,
               "trunk_dark", segments=5, caps=False)
        p.limb(tuple(top), tuple(top + Vector((side * c * 0.32, c * 0.22, 0))), c * 0.05, c * 0.03, trunk,
               segments=6, caps=False)
    out = []
    n = 5
    for i in range(n):
        t = (i / (n - 1)) * 2 - 1
        rad = c * (0.34 + r.random() * 0.1) * (1 - 0.25 * abs(t))
        cc = (top.x + t * c * 0.5, top.y + c * 0.22 + (1 - abs(t)) * c * 0.16 + r.uniform(-0.04, 0.04) * c,
              z + r.uniform(-0.15, 0.1) * c)
        p.sphere(cc, (rad * 1.05, rad * 0.75, rad * 0.85), colors[i % len(colors)], segments=12, rings=7)
        out.append((cc, rad))
    return out


def palm(p, base, height, lean, r, colors=("palm", "leaf_light", "leaf")):
    """Curved palm scaled by `height`."""
    x0, y0, z0 = base
    steps = 6
    pts = [Vector((x0 + lean * (i / steps) ** 2, y0 + height * i / steps, z0)) for i in range(steps + 1)]
    rad = height * 0.028
    for i, (a, b) in enumerate(zip(pts, pts[1:])):
        r1 = rad * (1 - 0.35 * i / steps)
        p.limb(tuple(a), tuple(b), r1, r1 * 0.93, "trunk" if i % 2 == 0 else "trunk_dark", segments=6, caps=False)
    top = pts[-1]
    p.sphere(tuple(top), rad * 1.4, "trunk_dark", segments=8, rings=5)
    fl = height * 0.42
    fronds = 7
    for i in range(fronds):
        a = -150 + i * 300 / (fronds - 1) + r.uniform(-10, 10)
        tilt = r.uniform(-30, 30)
        col = colors[i % len(colors)]
        B.leaf(p, tuple(top), fl * 0.55, fl * 0.2, col, angle=a * 0.55, tilt=tilt, thick=fl * 0.02)
        m = B.euler_matrix((tilt, 0.0, a * 0.55))
        tip = top + m @ Vector((0, fl * 0.5, 0))
        B.leaf(p, tuple(tip), fl * 0.6, fl * 0.18, col, angle=a * 0.55 + math.copysign(55, a), tilt=tilt,
               thick=fl * 0.02)
    return top


def vine(p, top, length, r, thick, leaf_size, color="vine", leaf_color="leaf_light", leaves=4, sway=None):
    """Hanging vine scaled by `thick` and `leaf_size`."""
    x, y, z = top
    sway = length * 0.06 if sway is None else sway
    n = 5
    ph = r.uniform(0, 6)
    pts = [(x + math.sin(i / n * 3.0 + ph) * sway * i / n, y - length * i / n, z) for i in range(n + 1)]
    for a, b in zip(pts, pts[1:]):
        p.limb(a, b, thick, thick * 0.9, color, segments=5, caps=False)
    for i in range(leaves):
        t = (i + 0.7) / (leaves + 0.5)
        k = min(n - 1, int(t * n))
        q = Vector(pts[k]).lerp(Vector(pts[k + 1]), t * n - k)
        side = 1 if i % 2 else -1
        B.leaf(p, (q.x, q.y, q.z + thick), leaf_size * r.uniform(0.8, 1.2), leaf_size * 0.55, leaf_color,
               angle=side * 115, tilt=0, thick=leaf_size * 0.08)


def waterfall(solid, spray, top, y_bot, width, r, spread=1.6, lip=True, mist=True):
    """A bright falling sheet from `top` down to y_bot with foam streaks, a
    curling lip and a cloud of spray at the foot."""
    x, y_top, z = top
    drop = y_top - y_bot
    B.fall(solid, x, y_top, y_bot, z, width, "water", r, wobble=width * 0.05, depth=width * 0.16, steps=8,
           spread=spread)
    for k in range(4):
        f = (k + 0.5) / 4 - 0.5
        length = drop * r.uniform(0.45, 0.95)
        secs = []
        for i in range(6):
            t = i / 5
            yy = y_top - length * t
            ww = width * (1 + (spread - 1) * (length * t / drop))
            secs.append((x + f * ww * 0.72, yy, z + width * 0.17, width * 0.05 * (1 - 0.6 * t), width * 0.02))
        solid.loft(secs, "foam" if k % 2 else "water_light", segments=6)
    if lip:
        solid.sphere((x, y_top, z + width * 0.06), (width * 0.56, width * 0.1, width * 0.2), "foam", segments=10,
                     rings=6)
    if mist:
        wb = width * spread
        for i in range(5):
            t = (i / 4) * 2 - 1
            rad = wb * (0.5 + r.random() * 0.3) * (1 - 0.3 * abs(t))
            spray.sphere((x + t * wb * 0.9, y_bot + rad * 0.25 + r.uniform(0, wb * 0.2),
                          z + wb * 0.3 + r.uniform(-1, 1) * wb * 0.1), (rad * 1.25, rad * 0.85, rad * 0.8), "spray",
                         segments=12, rings=8)


def rope_bridge(p, a, b, r, sag=0.12, count=12, planks=("plank", "plank_dark"), rope="rope", post="trunk_dark"):
    """Chunky sagging rope bridge from a to b: plank deck, two handrail ropes
    with hangers, and a post at each end."""
    a, b = Vector(a), Vector(b)
    span = (b - a).length
    width = span * 0.09
    deck = span * 0.03
    rail = span * 0.11
    pts = [a.lerp(b, i / count) - Vector((0, span * sag * 4 * (i / count) * (1 - i / count), 0))
           for i in range(count + 1)]
    for i, (q0, q1) in enumerate(zip(pts, pts[1:])):
        d = (q1 - q0).normalized()
        side = d.cross(Vector((0, 1, 0))).normalized()
        rot = Matrix((d, side.cross(d), side)).transposed()
        p.box(tuple((q0 + q1) / 2), ((q1 - q0).length * 0.86, deck, width), planks[i % 3 == 2], bevel=0,
              rotation=rot)
    for dz in (-0.5, 0.5):
        off = Vector((0, rail, dz * width))
        for q0, q1 in zip(pts, pts[1:]):
            P.rod(p, q0 + off, q1 + off, span * 0.008, rope, segments=5)
        for q in pts[1:-1]:
            P.rod(p, q + Vector((0, 0, dz * width)), q + off, span * 0.005, rope, segments=4)
        for q in (pts[0], pts[-1]):
            P.rod(p, q + Vector((0, -deck * 2, dz * width)), q + off * 1.35, span * 0.009, post, segments=6)


def idol_head(p, glow, chin, s, stone="stone", dark="stone_dark", spout=False):
    """Giant carved idol: a blocky face with a feathered headdress, ear plugs
    and glowing jade eyes. `chin` is the chin's center; the face is 8s wide."""
    cx, cy, cz = chin

    def at(x, y, z=0.0):
        return (cx + x * s, cy + y * s, cz + z * s)

    p.box(at(0, 4.2, 0), (8.0 * s, 8.4 * s, 6.6 * s), stone, bevel=0.5 * s, segments=1)
    p.box(at(0, 8.9, 0.2), (9.6 * s, 1.8 * s, 7.2 * s), dark, bevel=0.3 * s, segments=1)
    for i in range(5):
        x = (i - 2) * 1.9
        h = 2.6 - abs(i - 2) * 0.5
        p.prism([(-0.8 * s, 0), (0.8 * s, 0), (0.45 * s, h * s), (-0.45 * s, h * s)], 1.0 * s, stone,
                center=at(x, 9.7, 2.6), rotation=(0, 0, -x * 4))
    for side in (-1, 1):
        p.box(at(side * 4.5, 4.6, 0), (1.4 * s, 3.4 * s, 3.4 * s), dark, bevel=0.3 * s, segments=1)
        p.cylinder(at(side * 4.9, 4.6, 0.6), 1.0 * s, 0.6 * s, stone, rotation=(0, 0, 90), segments=8)
    p.box(at(0, 6.3, 3.4), (7.4 * s, 1.0 * s, 0.6 * s), dark, bevel=0.15 * s, segments=1)
    for side in (-1, 1):
        p.box(at(side * 1.9, 5.2, 3.3), (2.2 * s, 1.3 * s, 0.4 * s), dark, bevel=0.1 * s, segments=1)
        glow.box(at(side * 1.9, 5.2, 3.5), (1.5 * s, 0.7 * s, 0.2 * s), "jade", bevel=0)
    p.prism([(-0.9 * s, 0), (0.9 * s, 0), (0.5 * s, 2.6 * s), (-0.5 * s, 2.6 * s)], 1.4 * s, stone,
            center=at(0, 2.7, 3.6))
    p.box(at(0, 1.7, 3.35), (4.4 * s, 1.3 * s, 0.4 * s), dark, bevel=0.1 * s, segments=1)
    p.box(at(0, 1.7, 3.5), (3.4 * s, 0.6 * s, 0.2 * s), "water" if spout else "stone_deep", bevel=0)
    for side in (-1, 1):
        p.box(at(side * 0.9, 0.55, 3.2), (1.2 * s, 0.6 * s, 0.5 * s), dark, bevel=0.1 * s, segments=1)
    p.sphere(at(-1.5, 10.3, 0), (3.6 * s, 1.3 * s, 3.2 * s), "moss", segments=10, rings=5)
    p.sphere(at(2.2, 10.1, 0.5), (2.4 * s, 1.0 * s, 2.4 * s), "moss_dark", segments=10, rings=5)
    return at(0, 1.7, 3.6)


def column(p, base, height, radius, r, stone="stone", dark="stone_dark", capital=True, drums=4):
    """Stacked-drum stone column on a plinth; without a capital it reads as
    broken."""
    x, y, z = base
    p.box((x, y + radius * 0.3, z), (radius * 2.8, radius * 0.6, radius * 2.8), dark, bevel=radius * 0.1, segments=1)
    hh = height / drums
    for i in range(drums):
        tilt = r.uniform(-4, 4) if not capital and i == drums - 1 else 0
        p.cylinder((x, y + radius * 0.6 + hh * (i + 0.5), z), radius * (1 - 0.03 * i), hh * 0.96,
                   stone if i % 2 == 0 else "stone_light", rotation=(tilt, r.uniform(0, 30), tilt), segments=10,
                   smooth=True)
    top = y + radius * 0.6 + height
    if capital:
        p.box((x, top + radius * 0.25, z), (radius * 2.6, radius * 0.5, radius * 2.6), dark, bevel=radius * 0.1,
              segments=1)
        top += radius * 0.5
    return top


def ruin_arch(p, glow, base, height, width, r):
    """An old stone gateway: two columns under a heavy, slipped lintel with a
    jade glyph, a fallen block at its foot."""
    x, y, z = base
    rad = width * 0.1
    top = column(p, (x - width / 2, y, z), height, rad, r)
    column(p, (x + width / 2, y, z), height, rad, r)
    p.box((x + width * 0.04, top + rad * 0.75, z), (width * 1.35, rad * 1.5, rad * 2.4), "stone_light",
          bevel=rad * 0.12, segments=1, rotation=(0, 0, -3))
    p.box((x + width * 0.04, top + rad * 1.85, z), (width * 0.7, rad * 0.8, rad * 2.0), "stone_mid",
          bevel=rad * 0.1, segments=1, rotation=(0, 0, -3))
    glow.box((x + width * 0.04, top + rad * 0.72, z + rad * 1.22), (rad * 1.1, rad * 0.8, rad * 0.05), "jade", bevel=0)
    p.box((x + width * 0.82, y + rad * 0.55, z + rad * 1.5), (rad * 2.2, rad * 1.1, rad * 2.0), "stone_mid",
          bevel=rad * 0.15, segments=1, rotation=(0, 25, 12))


# Sky ------------------------------------------------------------------------


def sky(v, r):
    """Sky layer: karst towers along the horizon around the sun, far misty
    ziggurats, a sea of morning mist and soft clouds."""
    solid = v.piece("Sky", "Solid")
    clouds = v.piece("Sky", "Cloud")
    glow = v.piece("Sky", "Glow")
    # karst towers: (u, top v, depth, width frac, lean)
    towers = [(-0.27, 0.56, 13000, 0.04, -0.02), (-1.12, 0.3, 9000, 0.08, 0.02), (-0.97, 0.52, 12500, 0.055, -0.03),
              (-0.84, 0.2, 15000, 0.045, 0.02), (-0.44, 0.26, 13500, 0.045, 0.03), (-0.31, 0.1, 15500, 0.036, -0.02),
              (-0.18, -0.02, 16500, 0.03, 0.0), (-0.04, -0.12, 17000, 0.026, 0.03), (0.12, -0.08, 16000, 0.03, -0.02),
              (0.26, 0.08, 14500, 0.038, 0.0), (0.4, 0.3, 13000, 0.05, 0.03), (0.56, 0.5, 15000, 0.045, -0.02),
              (0.7, 0.68, 12500, 0.06, 0.02), (0.88, 0.58, 14500, 0.05, -0.03), (1.04, 0.76, 11000, 0.07, 0.02)]
    for u, top_v, d, w, lean in towers:
        bottom = v.at(u, -0.45, d)
        top_y = v.at(u, top_v, d)[1]
        karst(solid, bottom, top_y - bottom[1], w * v.unit(d), r, lean=lean)
    # a farther, hazier row of towers in between
    for u, top_v, d, w in ((-0.66, 0.02, 16500, 0.035), (-0.5, -0.06, 17000, 0.03), (0.04, -0.2, 17500, 0.04),
                           (0.2, -0.16, 17000, 0.028), (0.48, 0.0, 16500, 0.035), (-1.02, 0.08, 15500, 0.04)):
        bottom = v.at(u, -0.45, d)
        top_y = v.at(u, top_v, d)[1]
        karst(solid, bottom, top_y - bottom[1], w * v.unit(d), r, rock="karst_dark")
    # thin far waterfalls down two of the towers
    for u, top_v, d in ((0.4, 0.3, 13000), (-0.97, 0.52, 12500)):
        x, y, z = v.at(u, top_v - 0.04, d)
        w = 0.055 * v.unit(d)
        waterfall(solid, clouds, (x + w * 0.05, y, z + w * 0.45), v.at(u, -0.38, d)[1], w * 0.2, r, spread=1.5,
                  lip=False)
    # far ziggurats rising out of the mist in the middle distance
    for u, d, w in ((0.05, 8000, 0.05), (-0.12, 10000, 0.032)):
        base = v.at(u, -0.33, d)
        ziggurat(solid, glow, base, w * v.unit(d), 5)
    # sea of morning mist hiding the towers' feet
    for _ in range(40):
        d = r.uniform(6500, 17000)
        u = r.uniform(-1.2, 1.2)
        c = v.at(u, r.uniform(-0.4, -0.33), d)
        mist_bank(clouds, c, r.uniform(0.12, 0.26) * v.unit(d), r.uniform(0.012, 0.022) * v.unit(d), r,
                  colors=("cloud", "mist"))
    # soft cumulus and high streaks, kept off the sun
    for u, sv, d, w, h in ((0.3, 0.52, 11000, 0.2, 0.9), (0.72, 0.68, 12000, 0.24, 1.0),
                           (-0.95, 0.75, 13000, 0.18, 0.8), (1.05, 0.25, 10500, 0.16, 0.8),
                           (0.05, 0.85, 14000, 0.14, 0.7)):
        K.cumulus(clouds, v.at(u, sv, d), w * v.unit(d), "cloud", r, height=h, depth=0.5)
    for u, sv, d, length in ((0.2, 0.92, 9000, 0.16), (0.55, 0.82, 9500, 0.2), (0.92, 0.95, 8500, 0.12),
                             (-0.7, 0.95, 9000, 0.12)):
        for k in range(3):
            K.streak(clouds, v.at(u + (k - 1) * length * 0.55 + r.uniform(-0.02, 0.02), sv + r.uniform(-0.03, 0.03),
                                  d), length * r.uniform(0.6, 1.0) * v.unit(d), "cloud")


def ziggurat(p, glow, base, width, tiers):
    x, y, z = base
    w = width
    th = width * 0.13
    for i in range(tiers):
        p.box((x, y + th / 2, z), (w, th, w * 0.7), "stone" if i % 2 == 0 else "stone_mid", bevel=th * 0.05,
              segments=1)
        y += th
        w *= 0.8
    p.box((x, y + th * 0.6, z), (w * 0.6, th * 1.2, w * 0.4), "stone_light", bevel=th * 0.05, segments=1)
    glow.box((x, y + th * 0.5, z + w * 0.2), (w * 0.16, th * 0.6, th * 0.05), "jade", bevel=0)
    p.box((x, base[1] + (y - base[1]) / 2, z + width * 0.3), (width * 0.12, y - base[1], width * 0.12),
          "stone_light", bevel=0, taper=(0.7, 0.3))


# Landmarks ------------------------------------------------------------------


def canopy(v, r):
    """The jungle roof between the landmarks, low along the horizon."""
    solid = v.piece("Landmarks", "Solid")
    clouds = v.piece("Landmarks", "Cloud")
    for row, (d, vv, size, cols) in enumerate(((3800, -0.39, 0.022, ("far_leaf", "far_leaf", "far_leaf2")),
                                                (3000, -0.45, 0.028, ("leaf_dark", "leaf_dark", "leaf")),
                                                (2400, -0.53, 0.036, ("leaf", "leaf", "leaf_light")))):
        u = -1.25 + row * 0.02
        while u < 1.25:
            dd = d * r.uniform(0.97, 1.03)
            rad = size * v.unit(dd) * r.uniform(0.75, 1.2)
            c = v.at(u, vv + r.uniform(-0.02, 0.02), dd)
            solid.sphere(c, (rad * 1.15, rad * 0.62, rad * 0.85), r.choice(cols), segments=12, rings=7)
            u += size * r.uniform(0.9, 1.3)
    # palms poking out of the canopy
    for u, sv, d, h, lean in ((-0.36, -0.44, 2700, 0.1, 0.02), (0.36, -0.46, 2700, 0.09, -0.02)):
        hh = h * v.unit(d)
        palm(solid, v.at(u, sv, d), hh, lean * v.unit(d), r)
    # broken columns rising from the canopy in the middle distance
    for u, sv, d, h in ((-0.2, -0.42, 3300, 0.045), (0.16, -0.41, 3500, 0.04)):
        column(solid, v.at(u, sv, d), h * v.unit(d), 0.006 * v.unit(d), r, capital=r.random() < 0.5, drums=3)
    # mist drifting over the jungle roof and around the feet of the rocks
    for u, sv, d, w in ((-0.12, -0.5, 2600, 0.14), (0.1, -0.52, 2500, 0.12), (-0.5, -0.64, 2000, 0.16),
                        (0.24, -0.6, 1800, 0.14), (0.5, -0.62, 1700, 0.16), (0.78, -0.66, 1700, 0.16),
                        (1.05, -0.62, 1700, 0.16), (-1.05, -0.62, 2000, 0.15)):
        K.cumulus(clouds, v.at(u, sv, d), w * v.unit(d), "mist", r, height=0.5, depth=0.5, puffs=6)


def temple(v, r):
    """The great stepped temple on the left, half swallowed by the jungle."""
    solid = v.piece("Landmarks", "Solid")
    glow = v.piece("Landmarks", "Glow")
    d = 2300
    x0, y0, z0 = v.at(-0.6, -0.62, d)
    W = 0.36 * v.unit(d)
    tiers = 6
    th = W * 0.085
    shrink = 0.115
    widths = [W * (1 - shrink * i) for i in range(tiers)]
    for i, w in enumerate(widths):
        y = y0 + i * th
        solid.box((x0, y + th * 0.41, z0), (w, th * 0.82, w), "stone", bevel=th * 0.04, segments=1,
                  taper=(0.97, 0.97))
        solid.box((x0, y + th * 0.9, z0), (w * 0.995, th * 0.2, w * 0.995), "stone_light", bevel=th * 0.03,
                  segments=1)
    top_y = y0 + tiers * th
    wt = widths[-1]
    # the grand stair up the front, with balustrades and jade glyphs
    sw = W * 0.2
    n = 24
    z_bot, z_top = z0 + W / 2 * 1.08, z0 + wt / 2 * 1.04
    for k in range(n):
        f = (k + 1) / n
        zf = z_bot + (z_top - z_bot) * f
        sh = (top_y - y0) / n
        solid.box((x0, y0 + sh * (k + 0.5), (zf + z0) / 2), (sw, sh * 1.02, zf - z0),
                  "stone_light" if k % 2 == 0 else "stone", bevel=0)
    for side in (-1, 1):
        a = Vector((x0 + side * sw * 0.55, y0 + th * 0.25, z_bot + th * 0.1))
        b = Vector((x0 + side * sw * 0.55, top_y + th * 0.25, z_top + th * 0.1))
        solid.box(tuple((a + b) / 2), (sw * 0.12, (b - a).length, th * 0.55), "stone_mid", bevel=0,
                  rotation=P.along(a, b))
        for i in range(tiers):
            zf = z0 + widths[i] / 2
            glow.box((x0 + side * sw * 0.95, y0 + (i + 0.45) * th, zf + th * 0.02), (th * 0.28, th * 0.32, th * 0.05),
                     "jade", bevel=0)
    # the shrine on top: doorways, a stepped roof, a roof comb and a jade sun gem
    sy = top_y
    solid.box((x0, sy + th * 0.8, z0), (wt * 0.72, th * 1.6, wt * 0.6), "stone_light", bevel=th * 0.05, segments=1)
    front = z0 + wt * 0.3
    glow.box((x0, sy + th * 0.62, front + th * 0.01), (wt * 0.15, th * 1.0, th * 0.05), "jade_deep", bevel=0)
    for side in (-1, 1):
        solid.box((x0 + side * wt * 0.22, sy + th * 0.55, front + th * 0.01), (wt * 0.09, th * 0.75, th * 0.05),
                  "stone_deep", bevel=0)
    solid.box((x0, sy + th * 1.72, z0), (wt * 0.8, th * 0.3, wt * 0.66), "stone_mid", bevel=th * 0.04, segments=1)
    solid.box((x0, sy + th * 2.2, z0), (wt * 0.62, th * 0.7, wt * 0.5), "stone", bevel=th * 0.04, segments=1,
              taper=(0.8, 0.8))
    comb_y = sy + th * 3.1
    solid.box((x0, comb_y, z0 - wt * 0.05), (wt * 0.44, th * 1.3, wt * 0.08), "stone_light", bevel=th * 0.04,
              segments=1, taper=(0.75, 1.0))
    for side in (-1, 1):
        solid.box((x0 + side * wt * 0.1, comb_y - th * 0.05, z0 - wt * 0.005), (wt * 0.05, th * 0.5, th * 0.05),
                  "stone_deep", bevel=0)
    glow.sphere((x0, comb_y + th * 0.15, z0 + wt * 0.0), (th * 0.32, th * 0.42, th * 0.32), "jade", segments=4,
                rings=3)
    glow.sphere((x0, sy + th * 1.72, z0 + wt * 0.335), (th * 0.18, th * 0.12, th * 0.05), "sun_gold", segments=6,
                rings=4)
    # moss draped over the tier lips, vines hanging from them
    for i, w in enumerate(widths):
        y = y0 + (i + 1) * th
        zf = z0 + w / 2
        for k in range(r.randint(2, 4)):
            fx = r.uniform(-0.48, 0.48) * w
            if abs(fx) < sw * 0.75:
                continue
            # a clinging clump of moss tufts over the lip, a vine or two below
            n = r.randint(3, 5)
            for j in range(n):
                rad = th * r.uniform(0.13, 0.22)
                jx = x0 + fx + (j - (n - 1) / 2) * th * 0.24
                solid.sphere((jx, y - th * 0.02 - r.uniform(0, 0.25) * th, zf + th * 0.04), (rad * 1.2, rad, rad * 0.6),
                             r.choice(("moss", "moss_dark", "leaf")), segments=10, rings=6)
            if r.random() < 0.6:
                vine(solid, (x0 + fx + r.uniform(-0.5, 0.5) * n * th * 0.24, y - th * 0.15, zf + th * 0.08),
                     th * r.uniform(0.5, 1.2), r, th * 0.022, th * 0.16, leaves=3)
    # jungle swallowing the left flank and the foot: a giant emergent tree,
    # smaller trees climbing the tiers, and a dense canopy at the base
    jungle_tree(solid, (x0 - W * 0.62, y0 - th * 0.5, z0 + W * 0.25), th * 6.2, W * 0.3, r, lean=W * 0.05,
                colors=("leaf_dark", "leaf", "leaf_dark", "leaf_light"))
    jungle_tree(solid, (x0 - W * 0.3, y0 + th * 2.0, z0 + W * 0.4), th * 2.2, W * 0.16, r, lean=W * 0.03,
                colors=("blossom", "blossom_dark", "blossom"))
    jungle_tree(solid, (x0 + W * 0.42, y0 - th * 0.8, z0 + W * 0.5), th * 1.6, W * 0.15, r, lean=-W * 0.02,
                colors=("leaf", "leaf_dark", "leaf_light"))
    palm(solid, (x0 + wt * 0.42, top_y - th * 0.1, z0 + wt * 0.3), th * 2.4, th * 0.6, r)
    palm(solid, (x0 - widths[3] * 0.44, y0 + th * 4, z0 + widths[3] * 0.4), th * 2.0, -th * 0.5, r)
    palm(solid, (x0 + widths[1] * 0.46, y0 + th * 2, z0 + widths[1] * 0.45), th * 1.8, th * 0.5, r)
    for k in range(14):
        t = k / 13
        rad = W * r.uniform(0.06, 0.1) * (1.25 - 0.5 * t)
        c = (x0 - W * 0.85 + t * W * 1.45, y0 + r.uniform(-0.3, 0.9) * th * (1.6 - t),
             z0 + W * 0.55 + r.uniform(-0.05, 0.08) * W)
        solid.sphere(c, (rad * 1.15, rad * 0.75, rad * 0.8), r.choice(("leaf_dark", "leaf", "leaf_light", "leaf_dark")),
                     segments=12, rings=7)
    # jungle spilling over the lower tiers' right corner
    for k in range(6):
        rad = W * r.uniform(0.055, 0.08)
        c = (x0 + W * r.uniform(0.3, 0.56), y0 + th * r.uniform(0.6, 1.6), z0 + W * r.uniform(0.0, 0.42))
        solid.sphere(c, (rad * 1.15, rad * 0.75, rad * 0.9), r.choice(("leaf", "leaf_dark", "leaf_light")),
                     segments=12, rings=7)
    # roots creeping up the side
    for k in range(3):
        a = Vector((x0 - W * 0.5 + k * W * 0.05, y0 + th * 0.4, z0 + W * 0.5))
        b = Vector((x0 - widths[2] * 0.5 + k * W * 0.04, y0 + th * (2.5 + k * 0.6), z0 + widths[2] * 0.5))
        solid.limb(tuple(a), tuple(b), th * 0.1, th * 0.05, "root", segments=6, caps=False)
    # fireflies around the shrine
    for _ in range(14):
        B.star(glow, (x0 + r.uniform(-0.6, 0.6) * W, y0 + r.uniform(0.5, 8.5) * th, z0 + W * 0.6),
               th * r.uniform(0.1, 0.16), "firefly")


def cliffs(v, r):
    """Tall jungle cliffs on the right pouring three waterfalls (one from a
    giant idol's mouth), with a rope bridge to a ruined arch on a pillar."""
    solid = v.piece("Landmarks", "Solid")
    glow = v.piece("Landmarks", "Glow")
    clouds = v.piece("Landmarks", "Cloud")
    d = 2000
    unit = v.unit(d)
    bottom_v = -0.85
    cols = [(0.49, 0.1, 0.1, 1850), (0.63, 0.46, 0.12, 1850), (0.78, 0.34, 0.15, 1950), (0.95, 0.52, 0.14, 2050),
            (1.1, 0.4, 0.15, 1850), (1.25, 0.56, 0.13, 2150)]
    tops = []
    for u, top_v, w, dd in cols:
        base = v.at(u, bottom_v, dd)
        top_y = v.at(u, top_v, dd)[1]
        wd = w * v.unit(dd)
        h = top_y - base[1]
        prof = [(h, wd * 0.36), (h * 0.985, wd * 0.48), (h * 0.9, wd * 0.5), (h * 0.7, wd * 0.47),
                (h * 0.5, wd * 0.5), (h * 0.3, wd * 0.54), (0.0, wd * 0.6)]
        P.lathe(solid, base, prof, r.choice(("cliff", "cliff_mid")), segments=7, jitter=0.16, rng=sub(r),
                spin=r.uniform(0, 50), smooth=False)
        # strata ledges with moss
        for f in (0.35, 0.62, 0.84):
            if r.random() < 0.6:
                y = base[1] + h * (f + r.uniform(-0.04, 0.04))
                side = r.uniform(-0.3, 0.3)
                for k in range(2):
                    rad = wd * r.uniform(0.07, 0.1)
                    solid.sphere((base[0] + (side + (k - 0.5) * 0.12) * wd, y + k * rad * 0.4, base[2] + wd * 0.46),
                                 (rad, rad * 0.8, rad * 0.7), r.choice(("leaf", "leaf_dark", "moss_dark")),
                                 segments=10, rings=6)
                vine(solid, (base[0] + side * wd, y, base[2] + wd * 0.5), wd * r.uniform(0.2, 0.45), r, wd * 0.007,
                     wd * 0.04, leaves=3)
        # jungle cap
        for k in range(4):
            t = k / 3 * 2 - 1
            rad = wd * r.uniform(0.2, 0.28)
            solid.sphere((base[0] + t * wd * 0.33, top_y + rad * 0.35, base[2] + r.uniform(-0.1, 0.25) * wd),
                         (rad * 1.1, rad * 0.75, rad * 0.9), r.choice(LEAVES), segments=12, rings=7)
        for k in range(r.randint(2, 4)):
            vine(solid, (base[0] + r.uniform(-0.4, 0.4) * wd, top_y - wd * 0.02, base[2] + wd * 0.45),
                 wd * r.uniform(0.3, 0.9), r, wd * 0.008, wd * 0.05, leaves=4)
        tops.append((base, top_y, wd))
    base, top_y, wd = tops[1]
    jungle_tree(solid, (base[0] - wd * 0.28, top_y, base[2] + wd * 0.15), wd * 0.22, wd * 0.3, r,
                colors=("blossom", "blossom_dark", "blossom"))
    # palms on the cliff tops
    for i, (h, lean) in ((0, (0.07, -0.25)), (1, (0.09, 0.25)), (3, (0.08, -0.2)), (4, (0.09, 0.15))):
        base, top_y, wd = tops[i]
        palm(solid, (base[0] + lean * wd, top_y + wd * 0.05, base[2] + wd * 0.1), h * unit, -lean * wd * 0.6, r)
    # giant idol carved into the third column, pouring a waterfall from its mouth
    base, top_y, wd = tops[2]
    s = wd * 0.075
    chin = (base[0] - wd * 0.02, v.at(0.78, -0.08, 1950)[1], base[2] + wd * 0.42)
    mouth = idol_head(solid, glow, chin, s, spout=True)
    y_bot = v.at(0.78, -0.62, 1950)[1]
    waterfall(solid, clouds, (mouth[0], mouth[1], mouth[2] + s * 0.4), y_bot, s * 3.2, r, spread=2.2)
    # waterfalls pouring off the cliff tops
    for i, frac, width, spread in ((0, -0.12, 0.12, 1.7), (1, 0.06, 0.2, 1.8), (4, -0.2, 0.16, 1.7)):
        base, top_y, wd = tops[i]
        x = base[0] + frac * wd
        waterfall(solid, clouds, (x, top_y - wd * 0.04, base[2] + wd * 0.5), v.at(0.6, -0.62, 1950)[1],
                  wd * width, r, spread=spread)
    # a jungle-capped rock spire toward the middle with a ruined gateway,
    # bridged to the cliffs
    pd = 1950
    pu = 0.22
    pbase = v.at(pu, -0.6, pd)
    ptop = v.at(pu, -0.02, pd)[1]
    pw = 0.07 * v.unit(pd)
    karst(solid, pbase, ptop - pbase[1], pw, r, rock="cliff_mid", top=("leaf", "leaf_dark"), pinch=0.75,
          segments=7, smooth=False)
    ptop += pw * 0.08
    ruin_arch(solid, glow, (pbase[0] - pw * 0.05, ptop, pbase[2] + pw * 0.05), pw * 0.75, pw * 0.6, r)
    for k in range(2):
        vine(solid, (pbase[0] + (k - 0.5) * pw * 0.6, ptop - pw * 0.12, pbase[2] + pw * 0.5),
             pw * r.uniform(0.5, 1.0), r, pw * 0.012, pw * 0.07)
    base, top_y, wd = tops[0]
    rope_bridge(solid, (pbase[0] + pw * 0.36, ptop + pw * 0.02, pbase[2] + pw * 0.15),
                (base[0] - wd * 0.3, top_y + wd * 0.04, base[2] + wd * 0.2), r, sag=0.1, count=13)
    # macaws and a flock wheeling between the landmarks
    for (u, sv, d, s, n) in ((0.2, 0.5, 1700, 6.5, 5), (-0.34, 0.68, 2200, 6.0, 3)):
        x, y, z = v.at(u, sv, d)
        for i in range(n):
            k = i - (n - 1) / 2
            K.bird(solid, (x + k * 5.5 * s + r.uniform(-1, 1) * s, y - abs(k) * 2.2 * s + r.uniform(-0.8, 0.8) * s,
                           z + r.uniform(-2, 2) * s), s * r.uniform(0.8, 1.05))


# Haze -----------------------------------------------------------------------


def haze(v, r):
    """Morning mist banks along the bottom, big fronds in the lower corners,
    vines hanging into the top corners and drifting fireflies."""
    clouds = v.piece("Haze", "Cloud")
    solid = v.piece("Haze", "Solid")
    glow = v.piece("Haze", "Glow")
    us = [-1.3, -0.95, -0.6, -0.25, 0.1, 0.45, 0.8, 1.15]
    vs = [-0.76, -0.9, -1.02, -1.1, -1.1, -1.02, -0.9, -0.76]
    for u, sv in zip(us, vs):
        d = 800 * r.uniform(0.92, 1.08)
        K.cumulus(clouds, v.at(u + r.uniform(-0.04, 0.04), sv, d), 0.3 * v.unit(d), "mist", r, height=0.55,
                  depth=0.5, puffs=6)
    for u, sv in zip(us[:-1], vs[:-1]):
        d = 620 * r.uniform(0.92, 1.08)
        K.cumulus(clouds, v.at(u + 0.17, sv - 0.16, d), 0.28 * v.unit(d), "cloud", r, height=0.5, depth=0.5,
                  puffs=6)
    # fronds framing the lower corners
    for side in (-1, 1):
        d = 520
        base = v.at(side * 1.22, -1.12, d)
        size = 0.24 * v.unit(d)
        cols = ("leaf_deep", "leaf_near", "leaf_dark")
        for i in range(6):
            t = i / 5 - 0.5
            ang = side * (50 + t * 110) + r.uniform(-6, 6)
            ln = size * (1.0 - abs(t) * 0.45) * r.uniform(0.85, 1.1)
            B.leaf(solid, (base[0], base[1], base[2] + i * size * 0.02), ln, ln * 0.5, cols[i % 3], angle=ang,
                   tilt=r.uniform(-15, 15), rib="rib", notch=i % 2 == 0, thick=size * 0.01)
    # vines hanging into the top corners
    for side in (-1, 1):
        for k in range(4):
            d = 650 * r.uniform(0.9, 1.1)
            top = v.at(side * r.uniform(0.84, 1.28), 1.12, d)
            vine(solid, top, r.uniform(0.18, 0.5) * v.unit(d) * 0.56, r, 0.0012 * v.unit(d), 0.028 * v.unit(d),
                 color="vine", leaf_color=r.choice(("leaf", "leaf_dark")), leaves=5)
        d = 620
        base = v.at(side * 1.12, 1.08, d)
        size = 0.16 * v.unit(d)
        for i in range(5):
            t = i / 4 - 0.5
            B.leaf(solid, (base[0], base[1], base[2] + i * size * 0.02), size * (1 - abs(t) * 0.4), size * 0.5,
                   ("leaf_near", "leaf_dark")[i % 2], angle=side * (130 + t * 70), tilt=r.uniform(-10, 10),
                   rib="rib", thick=size * 0.01)
    # fireflies and pollen glints, away from the middle
    for _ in range(26):
        side = r.choice((-1, 1))
        d = r.uniform(450, 900)
        c = v.at(side * r.uniform(0.45, 1.3), r.uniform(-0.75, 0.35), d)
        B.star(glow, c, 0.0034 * v.unit(d) * r.uniform(0.7, 1.3), "firefly")
