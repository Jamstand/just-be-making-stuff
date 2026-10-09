"""
Volcanic Forge: a dwarven forge built on two floating basalt ledges over a
lava sea. A giant anvil rises on a rune pillar out of the gap between the
ledges, iron grates and a crane girder hang from an overhead gantry, and a
volcano smokes far behind.
"""

import math

from . import _props_b as pb

MAP_ID = "VolcanicForge"

COLORS = {
    # basalt
    "basalt": "#3e3546",
    "basalt_mid": "#4c4255",
    "basalt_dark": "#2c2533",
    "basalt_top": "#6e6070",
    # walkable forge floor
    "floor": "#9b7f6c",
    "floor_dark": "#715a50",
    # metal
    "iron": "#525868",
    "iron_dark": "#33363f",
    "iron_light": "#7d879a",
    "steel": "#a8b1c2",
    "brass": "#d49b3d",
    "brass_dark": "#9a6a28",
    "copper": "#b8663b",
    # forge buildings
    "brick": "#7d5c55",
    "brick_dark": "#5c4442",
    "stone": "#93807a",
    "wood": "#7a4a2c",
    "leather": "#a2603a",
    "coal": "#25202a",
    "gold": "#f4c54c",
    # molten things (Glow pieces)
    "lava": "#ff8c1f",
    "lava_hot": "#ffd34d",
    "lava_deep": "#f2541e",
    "magma": "#ff6d2a",
    "rune": "#ffb347",
    # lava sea crust
    "crust": "#2b1e25",
    "crust_light": "#40292f",
    # smoke and distance
    "smoke": "#4e3c4a",
    "smoke_light": "#6f5563",
    "smoke_far": "#7d4c55",
    "far_rock": "#58334a",
    "far_rock2": "#6c3b4b",
    "far_haze": "#8a4a50",
    "volcano": "#4d2c40",
    "volcano_dark": "#3a2133",
    "dev": "#3fb0ff",
}

PLATFORMS = [
    (-42, -12, -12, 0, False),
    (12, -12, 42, 0, False),
    (-8, 6, 8, 7, True),
    (-32, 15, -20, 16, True),
    (20, 15, 32, 16, True),
    (-10, 26, 10, 27, True),
]

SKY = ("#3a1b2e", "#e0663a")

GANTRY_Y = 50.0  # underside of the overhead gantry beam
GANTRY_Z = -2.6
SEA_Y = -42.0


# Stage ------------------------------------------------------------------


def ledge(stage, glow, x1, x2, r, side):
    """Solid basalt ledge, walkable top at y = 0 from x1 to x2."""
    w = x2 - x1
    cx = (x1 + x2) / 2
    # flagstone forge floor: the walkable top
    stage.box((cx, -0.6, 0.0), (w + 0.6, 1.2, 17.0), "floor", bevel=0.22, segments=1)
    # floor tiles seen on the front lip
    for i in range(int(w // 3)):
        x = x1 + 1.5 + i * 3
        stage.box((x, -0.62, 8.42), (2.7, 0.9, 0.2), "floor_dark", bevel=0.06, segments=1)
    # iron trim under the lip
    stage.box((cx, -1.5, 8.0), (w + 0.2, 0.55, 0.9), "iron_dark", bevel=0.08, segments=1)
    # the basalt body
    stage.box((cx, -7.2, -1.0), (w - 0.3, 12.0, 17.5), "basalt_dark", bevel=0)
    # columns along the front, flat side to the camera
    n = int(round(w / 3.0))
    for i in range(n):
        x = x1 + 1.5 + i * (w - 3) / (n - 1)
        top = -1.8 - r.random() * 1.4
        bot = -12.6 - r.random() * 4.0 - (2.5 if i % 3 == 1 else 0)
        col = "basalt" if i % 2 == 0 else "basalt_mid"
        pb.hexcol(stage, x, 7.0, 1.5, bot, top, col, top="basalt_top")
        if i % 3 == 2:
            glow.prism(pb.zigzag(r, x + r.uniform(-0.3, 0.3), top - 1.2, bot + 1.5, width=0.45, kinks=5, amp=0.35),
                       0.12, "magma", center=(0, 0, 8.33))
    # basalt under the ledge, with molten veins
    secs = pb.rock_bottom(stage, cx + side * 2.0, -1.0, -12.5, w + 1.0, 17.0, 22.0, "basalt_dark", r, segments=9)
    for k in (-0.38, 0.12, 0.5):
        pts = []
        for sx, sy, sz, srx, srz in secs[:-1]:
            pts.append((sx + k * srx, sy - 0.3, sz + srz * math.sqrt(1 - k * k) * 0.93, 0.32, 0.32))
        tip = secs[-1]
        pts.append((tip[0], tip[1] + 2.0, tip[2] + 0.4, 0.15, 0.15))
        pb.stream(glow, pts, "magma", segments=5)
    # hanging basalt columns
    for i in range(6):
        x = x1 + 2.5 + i * (w - 5) / 5
        length = 4 + r.random() * 6 * (1 - abs(i - 2.5) / 3)
        stage.cylinder((x, -12.4 - length / 2, 4.5 - (i % 2) * 1.5), 1.25, length, "basalt",
                       segments=6, radius_top=1.25, smooth=False)
        stage.cone((x, -12.4 - length - 0.9, 4.5 - (i % 2) * 1.5), 1.25, 1.8, "basalt", rotation=(180, 0, 0),
                   segments=6)
    # lava dripping from the tip into the sea
    tip = secs[-1]
    pb.fall(glow, tip[0], tip[1] + 1.5, SEA_Y, tip[2] + 0.3, 0.7, "lava", r, wobble=0.3, spread=1.5)


def back_terrace(stage, x1, x2, z1, z2, height=0.0):
    """Raised basalt shelf behind the lane that the forge buildings sit on."""
    cx = (x1 + x2) / 2
    stage.box((cx, height - 6.0, (z1 + z2) / 2), (x2 - x1, 12.0, z2 - z1), "basalt", bevel=0.3, segments=1)
    stage.box((cx, height - 0.4, (z1 + z2) / 2), (x2 - x1 + 0.4, 0.8, z2 - z1 + 0.4), "basalt_mid", bevel=0.15,
              segments=1)


# Platforms ----------------------------------------------------------------


def anvil(plats, glow, r):
    """Soft platform (-8, 6, 8, 7): the anvil face. The anvil's body sits
    behind the lane and stands on a rune pillar rising out of the abyss."""
    plats.box((0, 6.5, 0), (16.6, 1.0, 7.0), "steel", bevel=0.2, segments=1)
    plats.box((0, 5.8, -0.4), (15.4, 0.5, 6.0), "iron_light", bevel=0.1, segments=1)
    # horn and heel
    plats.cylinder((9.6, 6.25, -0.4), 0.6, 3.4, "steel", rotation=(0, 0, -90), radius_top=0.08, segments=8)
    plats.box((-8.6, 6.1, -0.4), (1.2, 0.7, 5.0), "iron_light", bevel=0.1, segments=1)
    # body behind the lane: flared top, narrow waist, wide feet
    plats.box((0, 4.9, -5.6), (13.0, 1.4, 5.0), "iron", bevel=0.25, segments=1, taper=(1.12, 1.0))
    plats.box((0, 2.8, -5.6), (6.4, 2.8, 4.2), "iron", bevel=0.2, segments=1)
    plats.box((0, 0.7, -5.6), (11.0, 1.6, 6.0), "iron", bevel=0.25, segments=1, taper=(0.62, 0.75))
    glow.prism(diamond(0.9, 0.9), 0.12, "rune", center=(0, 2.8, -3.45))
    glow.cylinder((0, SEA_Y + 0.15, -5.6), 5.5, 0.5, "lava_hot", segments=10)
    # rune pillar into the abyss
    plats.cylinder((0, -0.45, -5.6), 4.0, 0.9, "brass_dark", segments=8, smooth=False, rotation=(0, 22.5, 0))
    y = -0.9
    i = 0
    while y > SEA_Y:
        h = 5.0
        plats.cylinder((0, y - h / 2, -5.6), 3.0, h - 0.5, "stone", segments=8, smooth=False, rotation=(0, 22.5, 0))
        plats.cylinder((0, y - h + 0.25, -5.6), 3.3, 0.5, "brass_dark", segments=8, smooth=False,
                       rotation=(0, 22.5, 0))
        glow.prism(diamond(0.75, 1.2), 0.2, "rune", center=(0, y - h / 2, -2.78))
        y -= h
        i += 1


def diamond(w, h):
    return [(0, h), (-w, 0), (0, -h), (w, 0)]


def grate(plats, chains, x1, x2, y2):
    """Hanging iron grate, soft platform with its top at y2."""
    w = x2 - x1
    cx = (x1 + x2) / 2
    for z in (3.15, -3.15):
        plats.box((cx, y2 - 0.42, z), (w + 0.4, 0.84, 0.6), "iron", bevel=0.1, segments=1)
    for x in (x1 + 0.3, x2 - 0.3):
        plats.box((x, y2 - 0.42, 0), (0.6, 0.84, 6.2), "iron", bevel=0.1, segments=1)
    n = int(w / 1.2)
    for i in range(1, n):
        x = x1 + i * w / n
        plats.box((x, y2 - 0.3, 0), (0.28, 0.6, 6.0), "iron_dark", bevel=0)
    plats.box((cx, y2 - 0.55, 0), (w - 0.6, 0.3, 0.3), "iron_dark", bevel=0)
    # rivets
    for x in (x1 + 0.3, cx, x2 - 0.3):
        plats.sphere((x, y2 - 0.42, 3.5), 0.16, "brass", segments=6, rings=4)
    # chains up to the gantry
    for x in (x1 + 0.6, x2 - 0.6):
        pb.chain(chains, (x, y2 - 0.2, -2.6), (x, GANTRY_Y + 0.4, GANTRY_Z), "iron_dark", pitch=1.15)


def girder(plats, chains):
    """Crane girder at the top, soft platform (-10, 26, 10, 27)."""
    plats.box((0, 26.8, 0), (20.6, 0.4, 6.6), "iron", bevel=0.08, segments=1)
    plats.box((0, 25.7, 0), (20.0, 0.4, 6.0), "iron", bevel=0.08, segments=1)
    for z in (2.6, -2.6):
        for i in range(9):
            x = -9.6 + i * 2.4
            plats.box((x, 26.25, z), (0.35, 0.8, 0.35), "iron_dark", bevel=0)
            if i < 8:
                plats.box((x + 1.2, 26.25, z), (0.25, 1.15, 0.25), "iron_dark", bevel=0,
                          rotation=(0, 0, 63 if i % 2 == 0 else -63))
    plats.box((0, 26.8, 3.35), (20.0, 0.25, 0.1), "brass", bevel=0)
    for x in (-9.0, 9.0):
        pb.chain(chains, (x, 27.0, GANTRY_Z), (x, GANTRY_Y + 0.4, GANTRY_Z), "iron_dark", pitch=1.15, phase=1)


# Structures -----------------------------------------------------------------


def gantry(near, glow, r):
    """Overhead gantry beam spanning between two basalt spires that rise out
    of the lava sea. The grates and girder hang from trolleys on it."""
    span = 164.0
    near.box((0, GANTRY_Y + 1.2, GANTRY_Z), (span, 2.4, 2.0), "iron", bevel=0.15, segments=1)
    near.box((0, GANTRY_Y + 0.15, GANTRY_Z), (span, 0.3, 2.6), "iron_dark", bevel=0.05, segments=1)
    near.box((0, GANTRY_Y + 2.55, GANTRY_Z), (span, 0.3, 2.6), "iron_dark", bevel=0.05, segments=1)
    for i in range(-20, 21):
        near.sphere((i * 4.0, GANTRY_Y + 1.2, GANTRY_Z + 1.05), 0.2, "brass", segments=6, rings=4)
    # trolleys the chains hang from
    for x in (-31.4, -20.6, -9.0, 9.0, 20.6, 31.4):
        near.box((x, GANTRY_Y - 0.2, GANTRY_Z), (1.6, 0.8, 1.4), "brass_dark", bevel=0.12, segments=1)
    for side in (-1, 1):
        sx = side * 82
        # spire of stacked columns standing in the sea
        cols = [(0, 0, 4.0, 62), (side * 4.5, -3, 3.4, 52), (-side * 4.0, -4, 3.2, 44), (side * 1.5, -7, 3.6, 64),
                (-side * 2.5, 3.0, 2.6, 30)]
        for dx, dz, rad, top in cols:
            pb.hexcol(near, sx + dx, -10 + dz, rad, SEA_Y - 3, top + r.uniform(-1, 1), "basalt_mid" if rad < 3.5
                      else "basalt", turn=r.uniform(0, 30), top="basalt_top", top_h=0.6)
        # lava welling up around the base
        glow.cylinder((sx, SEA_Y + 0.15, -10), 9.0, 0.5, "lava_hot", segments=10)
        # collar where the beam meets the spire, with braces
        near.cylinder((sx, GANTRY_Y + 1.2, -10), 5.2, 3.2, "brass_dark", segments=8, smooth=False)
        near.box((sx - side * 8.0, GANTRY_Y - 3.0, GANTRY_Z), (0.9, 11.0, 0.9), "iron", bevel=0.1, segments=1,
                 rotation=(0, 0, side * 45))
        # brazier on top of the tallest column
        bx, by = sx + side * 1.5, 65.0
        near.cylinder((bx, by, -17), 2.6, 1.6, "brass_dark", segments=8, radius_top=3.4, smooth=False)
        glow.cone((bx, by + 2.4, -17), 2.4, 3.6, "lava", segments=7)
        glow.cone((bx, by + 2.0, -16.2), 1.4, 2.2, "lava_hot", segments=6)


def forge_left(near, glow, r):
    """Big stone furnace with a tall chimney and bellows on the left ledge."""
    cx, cz = -31.0, -15.5
    # furnace body
    near.box((cx, 4.6, cz), (15.0, 8.4, 10.0), "brick", bevel=0.35, segments=1, taper=(0.9, 0.9))
    near.box((cx, 1.2, cz), (16.4, 1.2, 11.2), "stone", bevel=0.2, segments=1)
    near.box((cx, 9.2, cz), (14.0, 1.0, 9.4), "stone", bevel=0.2, segments=1)
    for dx in (-6.4, 6.4):
        near.box((cx + dx, 5.0, cz + 4.6), (1.4, 7.0, 1.2), "stone", bevel=0.2, segments=1)
    # hood
    near.box((cx, 11.4, cz - 0.5), (11.0, 3.4, 7.5), "brick_dark", bevel=0.3, segments=1, taper=(0.55, 0.6))
    # furnace mouth: arch with fire
    arch = [(-3.0, 0.0), (3.0, 0.0), (3.0, 3.2)] + [
        (3.0 * math.cos(a), 3.2 + 3.0 * math.sin(a)) for a in [math.pi * k / 8 for k in range(1, 8)]] + [
        (-3.0, 3.2)]
    near.prism([(x * 1.3, y * 1.12) for x, y in arch], 0.5, "stone", center=(cx, 1.6, cz + 5.0))
    near.prism(arch, 0.5, "coal", center=(cx, 1.7, cz + 5.12))
    glow.prism([(x * 0.8, y * 0.75) for x, y in arch], 0.3, "lava_hot", center=(cx, 1.8, cz + 5.3))
    glow.prism([(-2.0, 0), (2.0, 0), (1.2, 1.4), (0.3, 0.8), (-0.6, 2.2), (-1.3, 1.0)], 0.3, "lava",
               center=(cx, 1.8, cz + 5.45))
    near.prism(diamond(0.9, 0.9), 0.4, "brass", center=(cx, 8.6, cz + 5.1))
    # chimney
    chx = cx - 4.0
    near.cylinder((chx, 27.0, cz - 1.0), 2.7, 30.0, "brick", segments=8, radius_top=2.2, smooth=False)
    for y in (16.0, 26.0, 36.0):
        rr = 2.7 - (y - 12) / 30 * 0.5 + 0.25
        near.cylinder((chx, y, cz - 1.0), rr, 0.9, "iron_dark", segments=8, smooth=False)
    near.cylinder((chx, 42.4, cz - 1.0), 3.0, 1.4, "brick_dark", segments=8, smooth=False)
    near.cylinder((chx, 43.4, cz - 1.0), 2.4, 0.8, "coal", segments=8, smooth=False)
    glow.cylinder((chx, 43.7, cz - 1.0), 1.8, 0.4, "lava", segments=8, smooth=False)
    for i, (dx, dy, s) in enumerate([(1.0, 46.5, 2.6), (3.5, 50.0, 3.2), (7.5, 53.5, 3.8), (13.0, 57.0, 4.4)]):
        pb.puffs(near, (chx + dx, dy, cz - 2.0), s, "smoke_light" if i % 2 else "smoke", r, count=3,
                 spread=(0.8, 0.3, 0.4))
    # bellows (seen from the side), pumping into the furnace
    bx, by, bz = -19.8, 3.6, -13.0
    near.prism([(-3.2, 0.15), (3.0, 1.9), (3.2, 1.5), (-3.2, -0.15)], 3.2, "wood", center=(bx, by, bz))
    near.prism([(-3.2, -0.15), (3.2, -1.5), (3.0, -1.9), (-3.2, 0.15)], 3.2, "wood", center=(bx, by, bz))
    near.prism([(-3.0, 0.2), (2.9, 1.6), (2.9, -1.6), (-3.0, -0.2)], 2.8, "leather", center=(bx, by, bz))
    for t in (-1.2, 0.6, 2.2):
        hh = 0.2 + (t + 3.0) / 6.0 * 1.4
        near.box((bx + t, by, bz + 1.45), (0.25, hh * 2, 0.1), "brass_dark", bevel=0)
    near.cylinder((bx - 4.2, by, bz), 0.5, 2.2, "brass", rotation=(0, 0, 90), radius_top=0.28, segments=8)
    near.box((bx + 0.2, 1.4, bz), (6.6, 1.6, 3.4), "stone", bevel=0.2, segments=1)
    # big dwarven hammer leaning by the furnace
    near.box((-41.0, 4.6, -11.5), (0.55, 8.4, 0.55), "wood", bevel=0.1, segments=1, rotation=(0, 0, -8))
    near.box((-40.4, 8.9, -11.5), (3.6, 2.0, 2.0), "iron", bevel=0.25, segments=1, rotation=(0, 0, -8))
    near.box((-40.4, 8.9, -11.5), (1.0, 2.3, 2.3), "brass", bevel=0.15, segments=1, rotation=(0, 0, -8))


def smelter_right(near, glow, chains, r):
    """Round smelter, a crucible on a jib pouring into a molten channel that
    spills off the back of the right ledge."""
    sx, sz = 37.0, -16.5
    near.cylinder((sx, 5.3, sz), 4.6, 9.0, "brick", segments=10, radius_top=3.8, smooth=False)
    near.cylinder((sx, 1.3, sz), 5.2, 1.0, "stone", segments=10, smooth=False)
    near.cylinder((sx, 10.1, sz), 4.0, 0.8, "iron_dark", segments=10, smooth=False)
    near.box((sx, 4.3, sz + 4.1), (2.6, 4.4, 0.6), "stone", bevel=0.15, segments=1)
    glow.box((sx, 4.3, sz + 4.4), (1.6, 3.4, 0.3), "lava_hot", bevel=0)
    near.cylinder((sx, 21.5, sz - 0.5), 1.8, 22.0, "brick_dark", segments=8, radius_top=1.5, smooth=False)
    near.cylinder((sx, 32.8, sz - 0.5), 2.2, 1.2, "iron_dark", segments=8, smooth=False)
    for i, (dx, dy, s) in enumerate([(0.8, 35.0, 1.8), (2.6, 37.6, 2.2)]):
        pb.puffs(near, (sx + dx, dy, sz - 1.5), s, "smoke_light", r, count=3, spread=(0.8, 0.3, 0.4))
    # jib crane holding a tilted crucible (kept below the grate)
    jx, jz = 30.5, -13.0
    near.box((jx, 6.4, jz), (1.2, 11.2, 1.2), "iron", bevel=0.12, segments=1)
    near.box((jx, 1.4, jz), (3.0, 1.2, 3.0), "stone", bevel=0.2, segments=1)
    near.box((jx - 3.6, 11.6, jz), (8.6, 0.9, 0.9), "iron", bevel=0.12, segments=1)
    near.box((jx - 1.5, 9.8, jz), (0.45, 4.0, 0.45), "iron_dark", bevel=0, rotation=(0, 0, 50))
    near.box((jx - 7.2, 11.0, jz), (1.0, 0.6, 1.2), "brass_dark", bevel=0.1, segments=1)
    cx, cy = jx - 7.2, 6.4
    pb.chain(chains, (cx, 10.8, jz), (cx, cy + 2.7, jz), "iron_dark", pitch=0.85)
    near.box((cx, cy + 2.5, jz), (5.2, 0.3, 0.3), "iron_dark", bevel=0)
    near.cylinder((cx, cy, jz), 2.0, 3.6, "iron_dark", rotation=(0, 0, 28), segments=10, radius_top=2.5)
    near.torus((cx - 0.85, cy + 1.6, jz), 2.5, 0.22, "brass", rotation=(0, 0, 28), segments=12, sides=4)
    glow.cylinder((cx - 0.85, cy + 1.62, jz), 2.25, 0.2, "lava_hot", rotation=(0, 0, 28), segments=10)
    pb.stream(glow, [(cx - 3.2, cy + 0.6, jz, 0.4, 0.4), (cx - 3.6, cy - 1.2, jz, 0.32, 0.32),
                     (cx - 3.7, cy - 3.0, jz, 0.36, 0.36), (cx - 3.7, cy - 4.2, jz, 0.55, 0.55)], "lava", segments=6)
    # molten trough along the back, glowing through vents in its front wall
    tz = -10.4
    near.box((30.5, 2.0, tz - 1.1), (25.0, 2.8, 0.6), "stone", bevel=0.1, segments=1)
    near.box((30.5, 0.95, tz), (25.0, 0.7, 2.6), "stone", bevel=0.1, segments=1)
    glow.box((30.5, 2.0, tz), (24.6, 2.0, 1.6), "lava", bevel=0)
    x = 18.0
    while x < 43.0:
        near.box((x + 0.9, 2.2, tz + 1.0), (1.8, 2.6, 0.6), "stone", bevel=0.12, segments=1)
        near.box((x + 0.9, 3.65, tz + 1.0), (2.0, 0.4, 0.8), "brass_dark", bevel=0.08, segments=1)
        x += 3.2
    glow.box((cx - 3.7, 3.1, tz), (2.0, 0.3, 1.6), "lava_hot", bevel=0)
    # spill off the end of the ledge
    pb.stream(glow, [(42.6, 2.8, tz, 0.75, 0.6), (43.8, 1.6, tz, 0.7, 0.55), (44.4, -6.0, tz, 0.9, 0.6),
                     (44.6, -20.0, tz, 1.3, 0.7), (44.4, SEA_Y + 0.5, tz, 1.8, 0.8)], "lava", segments=7)
    # stack of gold ingots
    for i, (dx, dy) in enumerate([(0, 0), (1.3, 0), (2.6, 0), (0.65, 0.55), (1.95, 0.55), (1.3, 1.1)]):
        near.box((14.0 + dx, 1.05 + dy, -12.5), (1.2, 0.5, 2.0), "gold", bevel=0.08, segments=1, taper=(0.8, 0.8))


# Scenery --------------------------------------------------------------------


def basalt_isle(p, glow, cx, cy, cz, width, depth, r, falls=1, tall=0.5):
    """Floating basalt chunk: a faceted rock under a crown of hex columns."""
    pb.rock_bottom(p, cx, cz, cy, width, depth, width * 0.85, "basalt_dark", r, segments=8)
    p.cylinder((cx, cy - 0.6, cz), width / 2, 1.2, "basalt", segments=8, smooth=False)
    cols = []
    rows = max(1, int(depth / 4))
    per = max(2, int(width / 3.6))
    for j in range(rows):
        for i in range(per):
            u = (i + 0.5) / per * 2 - 1
            v = (j + 0.5) / rows * 2 - 1
            if u * u + v * v > 1.05:
                continue
            x = cx + u * width * 0.42 + (0.9 if j % 2 else 0)
            z = cz + v * depth * 0.38
            h = 0.6 + (1 - abs(u)) * width * tall * (0.45 + r.random() * 0.4)
            col = "basalt_mid" if (i + j) % 2 else "basalt"
            pb.hexcol(p, x, z, 1.75, cy - 1.0, cy + h, col, top="basalt_top", top_h=0.4)
            cols.append((x, z, h))
    for k in range(falls):
        fx = cx + (k - (falls - 1) / 2) * width * 0.45 + r.uniform(-1, 1)
        pb.fall(glow, fx, cy + 0.2, SEA_Y, cz + depth / 2 + 0.3, 1.5, "lava", r, wobble=0.8, spread=2.0)
        glow.box((fx, cy + 0.25, cz + depth / 2 - 0.6), (1.6, 0.3, 1.6), "lava_hot", bevel=0)


def midground(near, glow, r):
    basalt_isle(near, glow, -76, -14, -44, 22, 14, r, falls=1)
    basalt_isle(near, glow, 84, -8, -52, 26, 14, r, falls=1, tall=0.35)
    basalt_isle(near, glow, -50, 30, -66, 12, 8, r, falls=0, tall=0.4)
    basalt_isle(near, glow, 56, 36, -74, 10, 8, r, falls=0, tall=0.4)
    # ember motes drifting behind the lane
    for i in range(46):
        x = r.uniform(-90, 90)
        y = r.uniform(-14, 60)
        z = r.uniform(-12, -50)
        pb.star(glow, (x, y, z), r.uniform(0.25, 0.5), "lava_hot" if i % 3 else "lava")


def dwarf_head(p, glow, cx, cy, cz, s):
    """Huge carved dwarf king's head on a basalt cliff, across the lava."""
    def at(x, y, z=0.0):
        return (cx + x * s, cy + y * s, cz + z * s)

    stone, dark = "far_rock2", "far_rock"
    # helmet dome, rim and horns
    p.sphere(at(0, 4.0, -0.5), (6.6 * s, 5.4 * s, 5.0 * s), dark, segments=12, rings=8,
             clip=[(at(0, 4.0), (0, 1, 0))])
    p.box(at(0, 4.0, 0), (14.4 * s, 1.6 * s, 10.4 * s), stone, bevel=0.3 * s, segments=1)
    p.box(at(0, 6.5, 4.4), (1.4 * s, 5.0 * s, 1.2 * s), stone, bevel=0.2 * s, segments=1)
    for side in (-1, 1):
        p.limb(at(side * 7.0, 5.0), at(side * 10.0, 9.5), 1.5 * s, 0.9 * s, dark, segments=7, caps=False)
        p.cone(at(side * 10.3, 11.5), 0.9 * s, 3.6 * s, dark, rotation=(0, 0, -side * 20), segments=7)
    # face
    p.box(at(0, 0.6, 0), (11.0 * s, 6.4 * s, 8.6 * s), stone, bevel=0.6 * s, segments=1)
    p.prism([(-5.4, 0.5), (-0.4, -0.2), (0.4, -0.2), (5.4, 0.5), (5.2, 1.6), (-5.2, 1.6)], 1.4 * s, dark,
            center=at(0, 1.7, 4.4))
    for side in (-1, 1):
        glow.prism([(-1.3, 0.35), (1.3, 0.35), (1.0, -0.35), (-1.0, -0.35)], 0.4 * s, "lava",
                   center=at(side * 2.6, 1.3, 4.3))
        p.sphere(at(side * 5.6, 0.6, 0), (0.9 * s, 1.6 * s, 1.1 * s), stone, segments=8, rings=5)
    p.prism([(-1.2, 0), (1.2, 0), (0.7, 3.0), (-0.7, 3.0)], 2.4 * s, dark, center=at(0, -1.8, 4.6))
    # moustache and beard with braids
    p.prism([(-5.5, -1.0), (-0.2, 0.6), (0.2, 0.6), (5.5, -1.0), (4.0, -2.0), (0, -0.8), (-4.0, -2.0)], 2.0 * s,
            dark, center=at(0, -2.2, 4.4))
    p.prism([(-5.8, 0), (5.8, 0), (5.0, -5.0), (2.4, -8.0), (0, -9.0), (-2.4, -8.0), (-5.0, -5.0)], 7.0 * s,
            stone, center=at(0, -2.4, 1.2))
    for x in (-2.6, 0.0, 2.6):
        p.cylinder(at(x, -11.4, 3.2), 0.9 * s, 4.6 * s, dark, radius_top=0.6 * s, segments=6, smooth=False)
        p.sphere(at(x, -14.0, 3.2), (1.0 * s, 0.8 * s, 1.0 * s), "brass_dark", segments=6, rings=4)
    # lava spilling from the cliff on both sides of the head
    rr = pb.rng(int(cx * 7))
    for side in (-1, 1):
        pb.fall(glow, cx + side * 11.5 * s, cy - 8 * s, SEA_Y, cz + 1.0 * s, 1.4 * s, "lava", rr, wobble=0.4,
                spread=1.8)
    # the cliff it is carved from
    p.prism([(-14, 6), (-9, 12), (9, 13), (15, 5), (16, -14), (10, -26), (0, -34), (-10, -27), (-16, -12)],
            6.0 * s, "volcano_dark", center=at(0, 0, -4.0))


def background(far, glow_far, r):
    # volcano off to the right
    vx, vz = 92.0, -188.0
    secs = [(vx, SEA_Y - 2, vz, 92.0, 26.0), (vx + 3, -5.0, vz, 64.0, 22.0), (vx + 5, 22.0, vz, 36.0, 15.0),
            (vx + 6, 42.0, vz, 17.0, 9.0), (vx + 6, 48.0, vz, 13.0, 7.0)]
    far.loft(secs, "volcano", segments=14, smooth=False, power=2.0)
    far.loft([(vx + 6, 47.2, vz, 13.6, 7.4), (vx + 6, 50.0, vz, 12.2, 6.6)], "volcano_dark", segments=14,
             smooth=False, caps=(False, False))
    glow_far.loft([(vx + 6, 48.0, vz, 11.0, 5.6), (vx + 6, 49.4, vz, 10.6, 5.4)], "lava_hot", segments=14)
    for k, start in ((-0.3, 0.0), (0.25, 0.4)):
        pts = []
        for i, (sx, sy, sz, srx, srz) in enumerate(secs[::-1]):
            if sy > 48.5:
                continue
            kk = k + 0.12 * math.sin(i * 1.7 + start * 5)
            pts.append((sx + kk * srx, sy + 0.5, sz + srz * math.sqrt(max(0.0, 1 - kk * kk)) * 0.99, 0.6 + i * 0.35,
                        0.6))
        pb.stream(glow_far, pts, "lava_deep", segments=6, power=3)
    # smoke plume leaning left over the sky
    for i in range(6):
        s = 7 + i * 3.0
        pb.puffs(far, (vx + 8 + i * 9, 56 + i * 10, vz - 4), s, "smoke_far" if i % 2 else "smoke_light", r, count=3,
                 spread=(0.9, 0.25, 0.3), segments=10, rings=6)
    # jagged ridges
    ridge_l = pb.ridge_outline(r, -280, -10, SEA_Y - 2,
                               [(-250, 44), (-225, 24), (-200, 56), (-178, 30), (-150, 42), (-128, 18),
                                (-100, 30), (-76, 12), (-50, 20), (-30, 6)])
    far.prism(ridge_l, 10.0, "far_rock", center=(0, 0, -175))
    ridge_r = pb.ridge_outline(r, 150, 300, SEA_Y - 2, [(170, 30), (196, 18), (220, 40), (250, 22), (275, 34)])
    far.prism(ridge_r, 10.0, "far_rock", center=(0, 0, -170))
    ridge_n = pb.ridge_outline(r, -240, 240, SEA_Y - 2,
                               [(-210, 14), (-180, 6), (-158, 18), (-130, 7), (-80, 3), (80, 3), (128, 9),
                                (156, 18), (182, 8), (212, 15)])
    far.prism(ridge_n, 6.0, "far_rock2", center=(0, 0, -125))
    # dwarven fortress spires with glowing windows
    for tx, th, tw in ((-150, 46, 8), (-134, 64, 10), (-118, 38, 7)):
        far.box((tx, SEA_Y + th / 2, -150), (tw, th, tw), "far_rock2", bevel=0.6, segments=1, taper=(0.8, 0.8))
        far.cone((tx, SEA_Y + th + 5, -150), tw * 0.62, 10, "far_rock", segments=4)
        for j in range(3):
            glow_far.box((tx, SEA_Y + th * (0.45 + j * 0.17), -150 + tw / 2 + 0.1), (1.2, 2.2, 0.3), "lava", bevel=0)
    dwarf_head(far, glow_far, -84, 2, -120, 1.5)


def lava_sea(sea, far, r):
    sea.box((0, SEA_Y - 0.5, -60), (900, 1.0, 320), "lava", bevel=0)
    # crust plates breaking up the glow into toon patches
    for i in range(90):
        x = r.uniform(-260, 260)
        z = r.uniform(-215, 60)
        s = r.uniform(6, 18) * (1 + max(0.0, -z - 30) / 200)
        k = r.randint(5, 7)
        pts = []
        for j in range(k):
            a = 2 * math.pi * j / k + r.uniform(-0.25, 0.25)
            rr = s * r.uniform(0.7, 1.0)
            pts.append((math.cos(a) * rr * 1.5, math.sin(a) * rr * 0.8))
        far.prism(pts, 0.6, "crust" if i % 3 else "crust_light", center=(x, SEA_Y + 0.25, z), rotation=(-90, 0, 0))
    # hot glow near the island bottoms
    sea.box((0, SEA_Y + 0.1, -40), (200, 0.2, 30), "lava_hot", bevel=0)


def model(mb):
    r = pb.rng(1337)
    stage = mb.piece("Stage")
    plats = mb.piece("Platforms")
    chains = mb.piece("Chains")
    near = mb.piece("SceneryNear")
    far = mb.piece("SceneryFar")
    glow = mb.piece("GlowLava")
    glow_far = mb.piece("GlowFar")
    sea = mb.piece("GlowSea")

    ledge(stage, glow, -42, -12, r, -1)
    ledge(stage, glow, 12, 42, r, 1)
    back_terrace(stage, -42, -12, -22, -9.0, 0.8)
    back_terrace(stage, 12, 42, -22, -9.0, 0.8)
    anvil(plats, glow, r)
    grate(plats, chains, -32, -20, 16)
    grate(plats, chains, 20, 32, 16)
    girder(plats, chains)
    gantry(near, glow, r)
    forge_left(near, glow, r)
    smelter_right(near, glow, chains, r)
    midground(near, glow, r)
    background(far, glow_far, r)
    lava_sea(sea, far, r)
    pb.dev_figures(mb, [(-30, 0), (-4, 7), (26, 16), (2, 27), (34, 0)], "dev")
