"""
Jungle Temple: an overgrown stepped temple on a floating jungle island. The
fight happens on the temple's mossy front terrace and its central dais; rope
bridges hang from two giant trees and a carved lintel stands on pillars
behind the lane. Idol-head spouts pour waterfalls off the island's sides,
and misty ziggurats float far behind.
"""

import math

from . import _props_b as pb

MAP_ID = "JungleTemple"

COLORS = {
    # temple stone
    "stone": "#bdb291",
    "stone_mid": "#a19679",
    "stone_dark": "#7c735f",
    "stone_light": "#d8cfaa",
    "stone_deep": "#5f584b",
    # moss and grass
    "moss": "#6fb04a",
    "moss_dark": "#4d8b3a",
    "moss_light": "#94cb5c",
    "grass": "#7cc350",
    # island earth and rock
    "earth": "#8c5d3e",
    "earth_dark": "#6a4431",
    "rock": "#7f7267",
    "rock_dark": "#605651",
    "root": "#74513a",
    # leaves
    "leaf": "#3f9c4b",
    "leaf_dark": "#2b7a3f",
    "leaf_light": "#66c15a",
    "leaf_yellow": "#a9cf4f",
    "palm": "#4fae52",
    "rib": "#2a6634",
    "trunk": "#8b6a4b",
    "trunk_dark": "#6b4f37",
    "vine": "#3a8a3e",
    # wood and rope
    "plank": "#b07d4d",
    "plank_dark": "#86603d",
    "rope": "#d8b97f",
    # water
    "water": "#7fd6e8",
    "water_light": "#c8f2f7",
    "foam": "#f1fdff",
    # glowing jade and fireflies
    "jade": "#52ffb6",
    "jade_deep": "#26e0a0",
    "firefly": "#e9ff8a",
    # flowers
    "flower_pink": "#f2709a",
    "flower_yellow": "#ffd24f",
    "flower_orange": "#ff9445",
    # distance
    "far_stone": "#79ae9b",
    "far_stone2": "#93c2ad",
    "far_leaf": "#5c9e83",
    "far_leaf2": "#74b296",
    "far_isle": "#6a9f8b",
    "mist": "#d7eedc",
    "mist2": "#c2e4d3",
    "dev": "#ff4fb0",
}

PLATFORMS = [
    (-38, -12, 38, 0, False),
    (-12, 0, 12, 4, False),
    (-32, 13, -18, 14, True),
    (18, 13, 32, 14, True),
    (-8, 20, 8, 21, True),
]

SKY = ("#2f8f7a", "#f2e6a8")

GROUND_Y = -0.6  # jungle floor behind the temple terrace


# Stage ----------------------------------------------------------------------


def moss_cap(stage, x1, x2, y_top, depth, r, z=0.0, color="moss", drip=(0.9, 2.2)):
    """Mossy top slab whose front edge drips down over the stone. Its top is
    exactly y_top from x1 to x2 (overhangs 0.3 at each end)."""
    a, b = x1 - 0.3, x2 + 0.3
    pts = [(a, y_top), (a, y_top - 1.0)]
    x = a + 0.8
    i = 0
    while x < b - 0.8:
        d = drip[0] + (r.random() * (drip[1] - drip[0]) if i % 2 else 0.0)
        pts.append((x, y_top - d))
        x += 0.8 + r.random() * 1.4
        i += 1
    pts += [(b, y_top - 1.0), (b, y_top)]
    stage.prism(pts, depth, color, center=(0, 0, z))


def carved_blocks(stage, glow, vines, x1, x2, y_top, y_bot, z_front, r, row_h=3.7):
    """Front wall of big mossy carved blocks, with glyph panels and a few
    glowing jade runes."""
    y = y_top
    row = 0
    k = 0
    while y - row_h > y_bot - 0.01:
        x = x1 + (0.0 if row % 2 == 0 else -2.6)
        while x < x2:
            bw = (5.2, 6.4, 4.6, 7.0)[k % 4]
            xa, xb = max(x, x1), min(x + bw, x2)
            if xb - xa > 0.8:
                color = ("stone", "stone_mid", "stone_light", "stone", "stone_mid")[k % 5]
                cx = (xa + xb) / 2
                prot = 0.15 + (k % 3) * 0.12
                stage.box((cx, y - row_h / 2, z_front - 0.5 + prot / 2), (xb - xa - 0.24, row_h - 0.24, 1.0 + prot),
                          color, bevel=0.18, segments=1)
                zf = z_front + prot
                if k % 6 == 2 and xb - xa > 3:
                    stage.box((cx, y - row_h / 2, zf + 0.02), (2.6, 2.4, 0.12), "stone_dark", bevel=0)
                    rune(glow, cx, y - row_h / 2, zf + 0.1, k // 6)
                elif k % 4 == 1 and xb - xa > 3:
                    fret = [(-1.5, -0.9), (1.5, -0.9), (1.5, 0.9), (-0.5, 0.9), (-0.5, -0.1), (0.5, -0.1),
                            (0.5, 0.35), (0.9, 0.35), (0.9, -0.5), (-0.9, -0.5), (-0.9, 0.9), (-1.5, 0.9)]
                    stage.prism(fret, 0.1, "stone_dark", center=(cx, y - row_h / 2, zf + 0.03))
                if k % 5 == 3:
                    pb.blob(stage, (xa + 1.0 + r.random(), y - 0.95, zf - 0.05), (1.6, 0.7, 0.35), "moss_dark",
                            segments=8, rings=4)
            x += bw
            k += 1
        y -= row_h
        row += 1
    # vines draping over the wall
    x = x1 + 3.0
    while x < x2 - 2:
        pb.vine(vines, (x, y_top - 0.25, z_front + 0.75), 2.5 + r.random() * 5.5, "vine", "leaf_light", r, sway=0.4,
                leaves=3)
        x += 5.0 + r.random() * 6.0


def rune(glow, x, y, z, k):
    """One of a few jade glyph shapes, about 1.6 studs across."""
    shapes = [
        [(-0.8, -0.6), (0.8, -0.6), (0.8, -0.25), (-0.35, -0.25), (-0.35, 0.25), (0.8, 0.25), (0.8, 0.6),
         (-0.8, 0.6)],
        [(0, 0.8), (0.7, 0), (0, -0.8), (-0.7, 0), (-0.25, 0), (0, 0.3), (0.25, 0), (0, -0.3), (-0.25, 0),
         (-0.7, 0)],
        [(-0.8, -0.5), (-0.4, -0.5), (-0.4, 0.2), (0.4, 0.2), (0.4, -0.5), (0.8, -0.5), (0.8, 0.6), (-0.8, 0.6)],
        [(-0.6, -0.7), (0.6, -0.7), (0.15, 0.0), (0.6, 0.7), (-0.6, 0.7), (-0.15, 0.0)],
    ]
    glow.prism(shapes[k % len(shapes)], 0.12, "jade", center=(x, y, z))


def temple_base(stage, glow, vines, r):
    """Solid platform (-38, -12, 38, 0): mossy terrace over carved blocks,
    sitting on the floating island."""
    moss_cap(stage, -38, 38, 0.0, 18.8, r, drip=(1.0, 2.6))
    stage.box((0, -6.4, -0.2), (75.6, 11.6, 18.0), "stone_dark", bevel=0)
    carved_blocks(stage, glow, vines, -38, 38, -1.0, -12.2, 8.9, r)
    # stone footing band
    stage.box((0, -12.9, 0), (74.0, 1.4, 17.0), "stone_deep", bevel=0.2, segments=1)


def island(stage, foliage, r):
    """Floating jungle island under the temple: earth, rock strata, roots."""
    secs = pb.rock_bottom(stage, 1.0, -2.0, -13.0, 82.0, 26.0, 30.0, "earth", r, segments=10)
    pb.rock_bottom(stage, -3.0, -1.0, -19.0, 60.0, 20.0, 26.0, "rock", r, segments=9)
    pb.rock_bottom(stage, 6.0, 0.5, -26.0, 34.0, 14.0, 22.0, "rock_dark", r, segments=8)
    # grassy jungle floor behind the temple terrace
    # (flat prisms: outline y becomes depth behind the terrace)
    stage.prism([(-48, 0), (48, 0), (46, 12), (36, 20), (-38, 20), (-47, 12)], 3.0, "grass",
                center=(0, GROUND_Y - 1.5, -9.2), rotation=(-90, 0, 0))
    stage.prism([(-46, 0), (46, 0), (44, 11), (34, 19), (-36, 19), (-45, 11)], 8.0, "earth",
                center=(0, GROUND_Y - 6.9, -9.6), rotation=(-90, 0, 0))
    # hanging roots and vines under the island
    for i in range(10):
        x = -34 + i * 7.5 + r.uniform(-2, 2)
        y = -13.5 - r.random() * 3
        length = 5 + r.random() * 8
        pts = [(x, y, 6.0 - (i % 3) * 2.5)]
        for j in range(3):
            px, py, pz = pts[-1]
            pts.append((px + r.uniform(-1.2, 1.2), py - length / 3, pz))
        for a, b in zip(pts, pts[1:]):
            foliage.limb(a, b, 0.32 - 0.06 * pts.index(a), 0.26 - 0.06 * pts.index(a), "root", segments=5,
                         caps=False)
    for i in range(8):
        x = -36 + i * 10 + r.uniform(-2, 2)
        pb.vine(foliage, (x, -12.4, 9.3), 4 + r.random() * 6, "vine", "leaf_light", r, leaves=3)
    return secs


def dais(stage, glow, r):
    """Solid platform (-12, 0, 12, 4): carved altar dais with stepped tiers
    climbing behind the lane."""
    stage.box((0, 3.6, 0), (24.6, 0.8, 16.4), "stone_light", bevel=0.2, segments=1)
    stage.box((0, 1.6, -0.1), (24.0, 3.3, 16.0), "stone_mid", bevel=0)
    # carved frieze on the front
    stage.box((0, 1.6, 8.05), (23.6, 2.8, 0.4), "stone", bevel=0.12, segments=1)
    for i, x in enumerate((-9.0, -5.0, 5.0, 9.0)):
        stage.box((x, 1.65, 8.3), (3.2, 2.2, 0.2), "stone_dark", bevel=0.05, segments=1)
        rune(glow, x, 1.65, 8.44, i + 1)
    # stepped fret flanking a jade sun disc
    for side in (-1, 1):
        steps = [(0, 0), (1.6, 0), (1.6, 0.6), (1.0, 0.6), (1.0, 1.2), (0.4, 1.2), (0.4, 1.8), (0, 1.8)]
        stage.prism([(side * x, y) for x, y in steps], 0.2, "stone_dark", center=(side * 1.6, 0.75, 8.35))
    glow.cylinder((0, 1.7, 8.35), 1.0, 0.25, "jade", rotation=(90, 0, 0), segments=10)
    stage.cylinder((0, 1.7, 8.28), 1.35, 0.2, "stone_dark", rotation=(90, 0, 0), segments=10)
    # moss tufts on the dais edge
    for x in (-11.0, 7.5):
        pb.blob(stage, (x, 2.3, 8.25), (1.4, 0.5, 0.4), "moss", segments=8, rings=4)
    # tiers behind: these are the steps of the temple climbing away from the lane
    stage.box((0, 5.25, -15.0), (21.0, 2.5, 13.0), "stone", bevel=0.2, segments=1)
    stage.box((0, 6.55, -15.0), (21.4, 0.3, 13.4), "moss", bevel=0.1, segments=1)
    stage.box((0, 7.75, -16.5), (16.0, 2.5, 10.0), "stone_mid", bevel=0.2, segments=1)
    stage.box((0, 9.05, -16.5), (16.4, 0.3, 10.4), "moss", bevel=0.1, segments=1)
    for side in (-1, 1):
        rune(glow, side * 8.5, 5.2, -8.42, 2 + side)


def idol_head(p, glow, cx, cy, cz, s, color="stone_mid", dark="stone_dark", spout=False):
    """Carved temple idol: a blocky face with a feathered headdress, ear
    plugs and glowing jade eyes. (cx, cy, cz) is the chin center."""
    def at(x, y, z=0.0):
        return (cx + x * s, cy + y * s, cz + z * s)

    p.box(at(0, 4.2, 0), (8.0 * s, 8.4 * s, 6.6 * s), color, bevel=0.5 * s, segments=1)
    # headdress
    p.box(at(0, 8.9, 0.2), (9.6 * s, 1.8 * s, 7.2 * s), dark, bevel=0.3 * s, segments=1)
    for i in range(5):
        x = (i - 2) * 1.9
        h = 2.6 - abs(i - 2) * 0.5
        p.prism([(-0.8, 0), (0.8, 0), (0.45, h), (-0.45, h)], 1.0 * s, color, center=at(x, 9.7, 2.6),
                rotation=(0, 0, -x * 4))
    # ear plugs
    for side in (-1, 1):
        p.box(at(side * 4.5, 4.6, 0), (1.4 * s, 3.4 * s, 3.4 * s), dark, bevel=0.3 * s, segments=1)
        p.cylinder(at(side * 4.9, 4.6, 0.6), 1.0 * s, 0.6 * s, color, rotation=(0, 0, 90), segments=8)
    # brow, eyes, nose, mouth
    p.box(at(0, 6.3, 3.4), (7.4 * s, 1.0 * s, 0.6 * s), dark, bevel=0.15 * s, segments=1)
    for side in (-1, 1):
        p.box(at(side * 1.9, 5.2, 3.3), (2.2 * s, 1.3 * s, 0.4 * s), dark, bevel=0.1 * s, segments=1)
        glow.box(at(side * 1.9, 5.2, 3.5), (1.5 * s, 0.7 * s, 0.2 * s), "jade", bevel=0)
    p.prism([(-0.9, 0), (0.9, 0), (0.5, 2.6), (-0.5, 2.6)], 1.4 * s, color, center=at(0, 2.7, 3.6))
    p.box(at(0, 1.7, 3.35), (4.4 * s, 1.3 * s, 0.4 * s), dark, bevel=0.1 * s, segments=1)
    p.box(at(0, 1.7, 3.5), (3.4 * s, 0.6 * s, 0.2 * s), "stone_deep" if not spout else "water", bevel=0)
    for side in (-1, 1):
        p.box(at(side * 0.9, 0.55, 3.2), (1.2 * s, 0.6 * s, 0.5 * s), dark, bevel=0.1 * s, segments=1)
    # moss on top
    p.sphere(at(-1.5, 10.3, 0), (3.4 * s, 1.2 * s, 3.0 * s), "moss", segments=10, rings=5)


def pillars_and_lintel(plats, stage, glow, foliage, r):
    """Soft platform (-8, 20, 8, 21): a carved stone lintel resting on two
    pillars that stand behind the lane on the dais."""
    # the lintel slab (the platform): z -4.5 .. 3.0
    plats.box((0, 20.4, -0.75), (16.6, 1.2, 7.5), "stone_light", bevel=0.18, segments=1)
    plats.box((0, 20.15, 3.02), (15.6, 0.45, 0.12), "stone_dark", bevel=0)
    for i, x in enumerate((-5.6, -1.9, 1.9, 5.6)):
        rune(glow, x, 20.15, 3.1, i)
    # moss along its top back edge (behind the lane, lower than the top)
    for x in (-6.5, -2.0, 4.0):
        pb.blob(plats, (x, 20.45, -4.3), (1.6, 0.45, 0.5), "moss", segments=8, rings=4)
    # back beam on the pillars
    stage.box((0, 19.9, -6.3), (18.4, 1.0, 3.6), "stone_mid", bevel=0.2, segments=1)
    for side in (-1, 1):
        x = side * 6.9
        stage.box((x, 11.1, -6.6), (2.4, 14.2, 2.4), "stone", bevel=0.2, segments=1)
        stage.box((x, 4.6, -6.6), (3.2, 1.2, 3.2), "stone_mid", bevel=0.2, segments=1)
        stage.box((x, 18.6, -6.6), (3.2, 1.4, 3.2), "stone_mid", bevel=0.2, segments=1)
        for y in (8.0, 13.5):
            stage.box((x, y, -6.6), (2.6, 0.5, 2.6), "stone_dark", bevel=0.1, segments=1)
        glow.prism([(-0.35, -1.6), (0.35, -1.6), (0.35, 1.6), (-0.35, 1.6)], 0.1, "jade", center=(x, 10.8, -5.36))
        glow.prism([(-0.35, -0.9), (0.35, -0.9), (0.35, 0.9), (-0.35, 0.9)], 0.1, "jade", center=(x, 16.0, -5.36))
        # vines wrapping down the pillars
        pb.vine(foliage, (x + side * 1.3, 19.4, -5.2), 9.0, "vine", "leaf_light", r, sway=0.3, leaves=4)
    for x in (-4.0, 1.5, 5.0):
        pb.vine(foliage, (x, 19.4, -4.6), 2.5 + r.random() * 2.5, "vine", "leaf", r, sway=0.3, leaves=2)


def bridge(plats, foliage, x1, x2, y2, r, anchor_y):
    """Rope-and-plank bridge (soft platform) with its top at y2, hung by ropes
    from the big trees' boughs."""
    w = x2 - x1
    n = int(round(w / 1.05))
    pw = w / n
    for i in range(n):
        x = x1 + (i + 0.5) * pw
        plats.box((x, y2 - 0.25, 0.0), (pw - 0.2, 0.5, 6.6 + (i % 2) * 0.3), "plank" if i % 3 else "plank_dark",
                  bevel=0.06, segments=1)
    for z in (-3.0, 3.0):
        pb.rope(plats, (x1 - 0.3, y2 - 0.65, z), (x2 + 0.3, y2 - 0.65, z), "rope", radius=0.17, pieces=4)
    for x in (x1 + 0.35, x2 - 0.35):
        for z in (-3.2,):
            pb.rope(plats, (x, y2 - 0.3, z), (x, anchor_y, z - 1.6), "rope", radius=0.13, pieces=1)
        plats.box((x, y2 - 0.6, 0), (0.5, 0.5, 7.2), "plank_dark", bevel=0.08, segments=1)
    for i in range(3):
        x = x1 + 2.5 + i * (w - 5) / 2
        pb.vine(foliage, (x, y2 - 0.7, 2.6 - i * 2.0), 1.5 + r.random() * 2.0, "vine", "leaf_light", r, leaves=2)


def giant_tree(trees, x, z, side, r, bough_to, bough_y):
    """Huge jungle tree beside the temple; a long bough reaches over a bridge
    and holds its ropes."""
    g = GROUND_Y
    trunk = [(x + side * 0.5, g - 1.0, z, 2.6), (x, g + 9.0, z, 2.0), (x - side * 1.4, g + 19.0, z + 0.5, 1.6),
             (x - side * 2.4, g + 30.0, z + 0.5, 1.2)]
    for (ax, ay, az, ar), (bx, by, bz, br) in zip(trunk, trunk[1:]):
        trees.limb((ax, ay, az), (bx, by, bz), ar, br, "trunk", segments=9)
    # buttress roots
    for k, dz in ((-1, 1.5), (1, 1.0), (0, 2.6)):
        trees.limb((x + k * 4.0, g - 0.5, z + dz), (x, g + 7.0, z), 1.0, 0.5, "trunk_dark", segments=6)
    # canopy
    top = (x - side * 2.4, g + 30.0, z + 0.5)
    trees.limb(top, (top[0] + side * 4.0, top[1] + 4.0, z), 1.0, 0.6, "trunk", segments=7)
    for i in range(6):
        t = (i / 5) * 2 - 1
        rad = (5.6 + r.random() * 2.0) * (1 - 0.22 * abs(t))
        c = (top[0] + t * 8.5, top[1] + 5.5 + (1 - abs(t)) * 3.0 + r.uniform(-0.8, 0.8), z + r.uniform(-2.5, 1.0))
        trees.sphere(c, (rad, rad * 0.75, rad * 0.9), ("leaf", "leaf_dark", "leaf_light")[i % 3], segments=12,
                     rings=7)
    # the bough, curving out over the bridge
    pts = [(x - side * 1.6, bough_y - 6.0, z + 0.5, 1.4), (x + (bough_to - x) * 0.3, bough_y - 0.5, -10.5, 1.1),
           (x + (bough_to - x) * 0.68, bough_y + 1.0, -6.5, 0.8), (bough_to, bough_y + 0.2, -4.9, 0.5)]
    for (ax, ay, az, ar), (bx, by, bz, br) in zip(pts, pts[1:]):
        trees.limb((ax, ay, az), (bx, by, bz), ar, br, "trunk", segments=7)
    for t, s, dz in ((0.45, 3.0, -1.0), (0.8, 2.6, -0.5), (1.0, 2.1, -0.2)):
        c = (x + (bough_to - x) * t, bough_y + 2.6, -5.5 - (1 - t) * 5 + dz)
        pb.puffs(trees, c, s, "leaf_dark" if t < 0.9 else "leaf", r, count=3, spread=(0.9, 0.2, 0.3), segments=10,
                 rings=6)
    for t in (0.35, 0.6, 0.9):
        vx = x + (bough_to - x) * t
        pb.vine(trees, (vx, bough_y - 0.2, -5.6), 4 + r.random() * 5, "vine", "leaf_light", r, leaves=3)


def waterfall(water, foliage, glow, x, y_top, z, side, r):
    """Idol-head spout on the island's side pouring a waterfall into the sky."""
    pb.fall(water, x, y_top, -62.0, z + 1.0, 2.2, "water", r, wobble=0.4, spread=1.9, depth=0.6)
    for k, dx in enumerate((-0.5, 0.45)):
        water.box((x + dx * 1.2, (y_top - 40) / 2, z + 1.75), (0.25, abs(y_top + 40) - 4, 0.1), "water_light",
                  bevel=0)
    for i in range(4):
        pb.blob(water, (x + r.uniform(-2.5, 2.5), -44 - i * 4 + r.uniform(-1, 1), z + 1.5),
                (2.6 + i * 0.6, 1.8 + i * 0.4, 1.4), "mist", segments=8, rings=5)


def back_jungle(foliage, near, glow, water, r):
    """Mid-ground: palms, leaf clumps, flowers, idol heads, fireflies."""
    leaf_cols = ["leaf", "leaf_light", "leaf_dark"]
    # leaf clumps at the back corners of the terrace and between things
    for x, z, s in ((-36.5, -10.5, 6.0), (36.0, -10.5, 6.5), (-16.0, -11.0, 4.5), (16.5, -11.0, 4.5),
                    (-26.0, -12.5, 5.0), (27.0, -12.0, 5.0)):
        pb.leaf_fan(foliage, (x, GROUND_Y, z), s, leaf_cols, r, count=5, spread=120, tilt=-10, rib="rib", notch=True)
    for x, z, c in ((-20.5, -10.0, "flower_pink"), (22.0, -10.2, "flower_yellow"), (-31.0, -10.0, "flower_orange"),
                    (31.5, -10.0, "flower_pink")):
        for k in range(3):
            pb.blob(foliage, (x + k * 0.9 - 0.9, GROUND_Y + 1.8 + (k % 2) * 0.7, z + 0.6), 0.55, c, segments=6,
                    rings=4)
    # palms behind
    pb.palm(foliage, (-24.0, GROUND_Y, -22.0), 22.0, 4.0, "trunk", "trunk_dark", ["palm", "leaf_light", "leaf"], r)
    pb.palm(foliage, (25.0, GROUND_Y, -24.0), 19.0, -5.0, "trunk", "trunk_dark", ["palm", "leaf", "leaf_light"], r)
    pb.palm(foliage, (-46.0, GROUND_Y - 1.0, -16.0), 16.0, -4.0, "trunk", "trunk_dark", ["leaf", "palm"], r)
    pb.palm(foliage, (47.0, GROUND_Y - 1.0, -17.0), 15.0, 3.5, "trunk", "trunk_dark", ["palm", "leaf_light"], r)
    # idol heads flanking the temple's upper tier
    idol_head(near, glow, 0.0, 9.05, -23.0, 1.12)
    idol_head(near, glow, -54.0, GROUND_Y - 1.0, -26.0, 1.0)
    idol_head(near, glow, 55.0, GROUND_Y - 1.0, -28.0, 1.0)
    # fireflies
    for i in range(40):
        pb.star(glow, (r.uniform(-60, 60), r.uniform(-8, 40), r.uniform(-9, -40)), r.uniform(0.2, 0.38),
                "firefly" if i % 3 else "jade")


def ziggurat(far, glow, cx, base_y, cz, width, tiers, color, top_color, r, glow_top=True):
    w = width
    y = base_y
    th = width * 0.13
    for i in range(tiers):
        far.box((cx, y + th / 2, cz), (w, th, w * 0.5), color if i % 2 == 0 else top_color, bevel=0.4, segments=1)
        y += th
        w *= 0.78
    far.box((cx, y + th * 0.6, cz), (w * 0.6, th * 1.2, w * 0.4), top_color, bevel=0.3, segments=1)
    if glow_top:
        glow.box((cx, y + th * 0.5, cz + w * 0.2 + 0.05), (w * 0.18, th * 0.7, 0.2), "jade", bevel=0)
    # stairs up the front
    far.box((cx, base_y + (y - base_y) / 2, cz + width * 0.2), (width * 0.12, y - base_y, width * 0.12),
            top_color, bevel=0.2, segments=1, taper=(0.7, 0.3))
    return y


def far_isle(far, water, cx, cy, cz, width, r, fall=True, trees=2):
    """Misty floating island with a tuft of jungle on top."""
    pb.rock_bottom(far, cx, cz, cy - 0.5, width, width * 0.5, width * 0.9, "far_isle", r, segments=8, jitter=0.35)
    far.cylinder((cx, cy - 0.2, cz), width / 2 + 0.4, 1.2, "far_leaf2", segments=10, smooth=False)
    for i in range(trees + 2):
        t = (i / max(1, trees + 1)) * 2 - 1
        rad = width * (0.16 if i % 2 else 0.12) * (1 - 0.3 * abs(t))
        far.sphere((cx + t * width * 0.36, cy + rad * 0.7 + (1 - abs(t)) * width * 0.08, cz + r.uniform(-1, 1)),
                   (rad, rad * 0.85, rad * 0.8), "far_leaf" if i % 2 else "far_leaf2", segments=10, rings=6)
    if fall:
        pb.fall(water, cx + width * 0.22, cy - 0.4, cy - width * 1.8, cz + width * 0.25, width * 0.09,
                "water_light", r, wobble=0.2, spread=1.5, depth=0.3)


def cloud_bank(far, cx, cy, cz, length, height, r, colors=("mist", "mist2")):
    """A low, puffy toon cloud bank (mist drifting between the islands)."""
    n = max(3, int(length / (height * 1.4)))
    for i in range(n):
        t = (i / (n - 1)) * 2 - 1
        rad = height * (0.7 + r.random() * 0.5) * (1 - 0.45 * t * t)
        far.sphere((cx + t * length / 2, cy + rad * 0.35, cz + r.uniform(-3, 3)), (rad * 1.5, rad, rad * 0.9),
                   colors[i % len(colors)], segments=10, rings=5)


def far_scenery(far, haze, glow, water, r):
    # distant ziggurats rising out of the jungle haze
    ziggurat(far, glow, -100.0, -44.0, -178.0, 70.0, 5, "far_stone", "far_stone2", r)
    ziggurat(far, glow, 108.0, -46.0, -186.0, 62.0, 5, "far_stone", "far_stone2", r)
    ziggurat(far, glow, -36.0, -40.0, -150.0, 32.0, 4, "far_stone2", "far_stone", r, glow_top=False)
    # misty floating islands
    far_isle(far, water, -62.0, 32.0, -120.0, 22.0, r)
    far_isle(far, water, 70.0, 24.0, -130.0, 26.0, r)
    far_isle(far, water, 20.0, 48.0, -170.0, 15.0, r, fall=False, trees=1)
    far_isle(far, water, -132.0, 12.0, -140.0, 18.0, r)
    far_isle(far, water, 142.0, 42.0, -160.0, 20.0, r, trees=1)
    # jungle canopy far below: two staggered rows of uneven tree crowns
    for row, (z, y, c1, c2) in enumerate(((-120.0, -52.0, "far_leaf", "far_leaf2"),
                                          (-175.0, -44.0, "far_leaf2", "far_stone"))):
        x = -230.0 + row * 9
        while x < 230:
            rad = r.uniform(7, 14)
            haze.sphere((x, y + r.uniform(-4, 5) + rad * 0.2, z + r.uniform(-12, 12)), (rad, rad * 0.75, rad * 0.8),
                        c1 if r.random() < 0.5 else c2, segments=8, rings=5)
            x += rad * 1.4
    # mist banks drifting at the island's feet and around the far temples
    for cx, cy, cz, ln, h in ((-110, -36, -100, 70, 6), (60, -40, -96, 90, 7), (175, -30, -115, 60, 6),
                              (-30, -32, -165, 110, 8), (120, -24, -170, 80, 7), (-190, -20, -170, 70, 6),
                              (-75, 20, -128, 22, 3), (82, 12, -138, 26, 3)):
        cloud_bank(haze, cx, cy, cz, ln, h, r)


def model(mb):
    r = pb.rng(4242)
    stage = mb.piece("Stage")
    plats = mb.piece("Platforms")
    vines = mb.piece("Vines")
    trees = mb.piece("Trees")
    foliage = mb.piece("Foliage")
    near = mb.piece("SceneryNear")
    far = mb.piece("SceneryFar")
    haze = mb.piece("SceneryHaze")
    water = mb.piece("Water")
    glow = mb.piece("GlowJade")

    temple_base(stage, glow, vines, r)
    island(stage, vines, r)
    dais(stage, glow, r)
    pillars_and_lintel(plats, stage, glow, vines, r)
    bridge(plats, vines, -32, -18, 14, r, anchor_y=30.5)
    bridge(plats, vines, 18, 32, 14, r, anchor_y=30.5)
    giant_tree(trees, -42.0, -15.0, -1, r, -15.5, 31.0)
    giant_tree(trees, 42.0, -15.0, 1, r, 15.5, 31.0)
    for side in (-1, 1):
        sx = side * 44.5
        idol_head(near, glow, sx, -9.6, -8.5, 0.72, spout=True)
        waterfall(water, vines, glow, sx, -9.6 + 1.7 * 0.72, -8.5 + 0.72 * 3.5, side, r)
    # foreground leaves framing the bottom corners (well below the stage top)
    for side in (-1, 1):
        pb.leaf_fan(foliage, (side * 37.0, -13.0, 10.5), 7.5, ["leaf_dark", "leaf", "leaf_light"], r, count=5,
                    spread=100, tilt=8, rib="rib", notch=True, aim=side * -130)
    back_jungle(foliage, near, glow, water, r)
    far_scenery(far, haze, glow, water, r)
    pb.dev_figures(mb, [(-28, 0), (-4, 4), (24, 14), (2, 21), (30, 0)], "dev")
