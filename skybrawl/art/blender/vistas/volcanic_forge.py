"""
VolcanicForge background: a dwarven forge-city at a plum-and-ember ash dusk.
The city crowns a basalt-column cliff on the left (forge halls, smoking
chimneys, a giant anvil monument, lava falls pouring off the cliff), a great
volcano smokes on the right with lava rivers down its flanks, a foundry
outpost stands on a crag at the right edge, and a crusted lava sea runs out
to a horizon of far volcanoes and a dwarven stronghold under dark ash clouds
and a low smoldering sun.
Ash banks and embers drift along the bottom.
"""

import math
import random

from maps import _props_a as P
from maps import _props_b as B
from vistas import _kit as K

MAP_ID = "VolcanicForge"
SEED = 23

COLORS = {
    # basalt
    "basalt": "#4a4068",
    "basalt_mid": "#5a4c78",
    "basalt_dark": "#302848",
    "basalt_top": "#8a7aa0",
    # forge buildings
    "stone": "#9a7c78",
    "stone_dark": "#6a5260",
    "brick": "#94584e",
    "slate": "#45364f",
    # metal
    "iron": "#5f6478",
    "iron_dark": "#3b3c4c",
    "steel": "#a9b0c4",
    "brass": "#e0a645",
    "brass_dark": "#a06e2e",
    "wood": "#7a4a2c",
    "banner": "#c8402e",
    # volcanoes and far land
    "volcano": "#4a2c52",
    "volcano_dark": "#36203e",
    "volcano_ash": "#5e3c62",
    "far_rock": "#6e3654",
    "far_rock2": "#7e4058",
    "crust": "#33222c",
    "crust_light": "#4a2e38",
    # molten things (Glow)
    "lava": "#ff7a1a",
    "lava_hot": "#ffd34d",
    "lava_deep": "#f2541e",
    "lava_sea": "#8e2a16",
    "magma": "#ff6d2a",
    "rune": "#ffb347",
    "window": "#ffb84e",
    "ember": "#ffcf6a",
    # smoke and ash (Cloud)
    "smoke": "#5a4256",
    "smoke_dark": "#3e2c3c",
    "smoke_light": "#7e5e6e",
    "smoke_hot": "#c8643e",
    "ash": "#8c6a78",
    "ash_cloud": "#6a4660",
    "ash_far": "#a0606a",
    "steam": "#9c8494",
    "steam_light": "#b89cac",
    "haze": "#8a6a84",
    "haze_light": "#a68098",
    "bird": "#2a1826",  # K.flock's default color
}

LOOK = {
    "dome": [(-0.25, "#c04a2c"), (-0.01, "#f2843c"), (0.04, "#ec7442"), (0.1, "#c84c4c"), (0.18, "#963a58"),
             (0.28, "#5e2648"), (0.42, "#33172c")],
    "sun": (0.08, 0.36),
    "sun_color": "#ff6a2a",
    "sun_size": 4.6,
    "glow": "#ff6a3a",
    "halo_size": 26.0,
    "halo_strength": 0.45,
    "light_dir": (-0.35, 0.75, 0.45),
    "light": "#ffe0c8",
    "mid": "#d8a0a8",
    "shadow": "#5a3466",
    "cloud_light": "#ffc49a",
    "cloud_mid": "#d8949a",
    "cloud_shadow": "#5a3458",
    "rim": "#e87444",
    "ambient": "#7a3a5a",
    "fog_near": 800.0,
    "fog_far": 24000.0,
    "fog_max": 0.75,
    "sky_fog_scale": 1.3,
    "ink": "#1e0f1c",
    "ink_soft": "#2e1426",
    "glow_strength": 2.0,
}

GROUND = -600.0  # the lava sea, in arena units below the camera


def scene(v):
    r = K.rng(SEED)
    sky(v, r)
    lava_sea(v, r)
    far_range(v, r)
    far_fortress(v, r)
    great_volcano(v, r)
    forge_city(v, r)
    crag_outpost(v, r)
    birds(v, r)
    haze(v, r)


# Helpers --------------------------------------------------------------------


class Frame:
    """Screen-sized measures at one depth: hu world units per 1.0 of u (half
    the screen's width), hv per 1.0 of v (half its height)."""

    def __init__(self, v, d):
        self.v, self.d = v, d
        self.hu = v.unit(d) / 2
        self.hv = self.hu * v.tan_v / v.tan_h

    def x(self, u):
        return self.v.at(u, 0.0, self.d)[0]

    def y(self, u, sv):
        return self.v.at(u, sv, self.d)[1]

    def z(self):
        return self.v.at(0.0, 0.0, self.d)[2]


def volcano(p, glow, v, u, d, peak, width, r, rock="volcano", rim="volcano_dark", cap="volcano_ash",
            crater=0.16, rivers=(), lava="lava", core="lava_hot", segments=18, jitter=0.08, gullies=5, curve=1.4,
            vents=(), teeth=6, fountain=0, foot=None):
    """A volcano standing on the lava sea at screen column u, depth d: its
    crater at screen height `peak`, its foot `width` across in u. `rivers`
    are (angle from the camera-facing side, length 0..1, width, phase);
    `vents` are small side cones (angle, height 0..1 down the slope, size).
    Returns (crater center, crater radius, height)."""
    f = Frame(v, d)
    cx, cz = f.x(u), f.z()
    top = f.y(u, peak)
    H = top - GROUND
    R = width * f.hu / 2
    rc = R * crater

    def rad(t):  # t: 0 at the crater .. 1 at the foot
        return rc + (R - rc) * t ** curve * (1 + 0.07 * math.sin(t * math.pi * 2.5))

    def surface(a_deg, t, lift=1.0):
        a = math.radians(a_deg)
        rr = rad(t) * lift
        return (cx + math.cos(a) * rr, GROUND + H * (1 - t), cz + math.sin(a) * rr)

    steps = 12
    seed = r.randrange(1 << 30)
    P.lathe(p, (cx, GROUND, cz), [(H * (1 - i / steps), rad(i / steps)) for i in range(steps + 1)], rock,
            segments, jitter, random.Random(seed))
    if cap:
        P.lathe(p, (cx, GROUND, cz), [(H * (1 - i / 8 * 0.26), rad(i / 8 * 0.26) * 1.02 + R * 0.004)
                                      for i in range(9)], cap, segments, jitter, random.Random(seed))
    # broken crater rim and the lava light on its lip
    P.lathe(p, (cx, GROUND, cz), [(H * 1.01, rc * 0.93), (H * 0.975, rad(0.025) * 1.05)], rim, segments, 0.06,
            random.Random(seed + 1))
    glow.cylinder((cx, top + H * 0.012, cz), rc * 0.88, H * 0.008, core, segments=segments)
    if foot:  # molten shore where the cone meets the lava sea
        glow.cylinder((cx, GROUND + R * 0.004, cz), rad(1.0) * 1.1, R * 0.008, foot, segments=segments)
    if fountain:
        # molten dome welling over the lip, with bombs thrown up
        glow.sphere((cx, top + H * 0.005, cz), (rc * 0.8, rc * 0.32, rc * 0.8), lava, segments=16, rings=8)
        glow.sphere((cx, top + H * 0.012, cz + rc * 0.1), (rc * 0.45, rc * 0.22, rc * 0.45), core, segments=12,
                    rings=6)
        for k in range(fountain):
            a = r.uniform(-1, 1)
            h = rc * r.uniform(0.6, 1.6)
            for j in range(4):
                t = (j + 1) / 4
                B.star(glow, (cx + a * rc * 1.4 * t, top + h * (1 - (1 - t * 1.6) ** 2) + rc * 0.2,
                              cz + rc * 0.5), rc * 0.07 * (1.2 - t * 0.5), core if j < 2 else lava)
    front = math.degrees(math.atan2(-cz, -cx))
    for k in range(teeth):
        a = front + (k / max(1, teeth - 1) - 0.5) * 200 + r.uniform(-12, 12)
        base = surface(a, 0.0, 0.97)
        th = H * r.uniform(0.02, 0.06)
        P.lathe(p, (base[0], top - H * 0.01, base[2]), [(th, 0.0), (0.0, rc * r.uniform(0.18, 0.3))], rim, 5, 0.2,
                random.Random(seed + 7 + k), spin=r.uniform(0, 60))
    # dark gullies on the flanks
    for k in range(gullies):
        off = r.uniform(-85, 85)
        t0 = r.uniform(0.05, 0.3)
        t1 = min(0.95, t0 + r.uniform(0.25, 0.5))
        pts = []
        for i in range(7):
            t = t0 + (t1 - t0) * i / 6
            q = surface(front + off + 3 * math.sin(i), t, 1.004)
            w = R * 0.01 * (0.4 + 1.6 * math.sin(math.pi * i / 6))
            pts.append((q[0], q[1], q[2], w, w))
        B.stream(p, pts, rim, segments=5)
    # parasitic vents on the slopes
    for off, t, size in vents:
        q = surface(front + off, t, 0.97)
        vr = R * size
        P.lathe(p, q, [(vr * 0.9, vr * 0.3), (vr * 0.75, vr * 0.38), (0.0, vr)], rock, 9, 0.1,
                random.Random(seed + 31))
        glow.cylinder((q[0], q[1] + vr * 0.91, q[2]), vr * 0.27, vr * 0.03, core, segments=9)
    # lava rivers down the slopes
    for off, length, wf, ph in rivers:
        for color, scale, lift in ((lava, 1.0, 1.04), (core, 0.4, 1.055)):
            pts = []
            n = 14
            for i in range(n + 1):
                t = 0.01 + length * i / n
                q = surface(front + off + 7 * math.sin(t * 10 + ph), t, lift)
                w = R * wf * (0.45 + 1.4 * t) * scale
                pts.append((q[0], q[1], q[2], w, w * 0.6))
            B.stream(glow, pts, color, segments=6)
    return (cx, top, cz), rc, H


def plume(p, base, size, rise, drift, r, colors, count=10, flat=0.8, grow=2.4, fan=1.0):
    """A smoke column rising from `base`, growing, fanning out and bending
    toward -x (drift > 0) or +x (drift < 0) as it climbs."""
    x, y, z = base
    for i in range(count):
        t = i / (count - 1)
        k = t ** 1.5  # puffs crowd near the source, where they are small
        s = size * (0.5 + grow * t)
        c = (x - drift * k ** 1.4, y + rise * k, z - size * 0.4 * t)
        col = colors[min(len(colors) - 1, int(t * len(colors)))]
        B.puffs(p, c, s * 0.55, col, r, count=3 if t < 0.5 else 4, flat=flat,
                spread=(0.7 + 0.9 * t * fan, 0.25, 0.35), segments=12, rings=8)


def smoke_trail(p, base, size, rise, drift, r, colors, grow=2.0):
    """Chimney smoke: a continuous chain of overlapping puffs along a curve
    that rises and bends toward -x (drift > 0) or +x (drift < 0), growing as
    it goes, with smaller puffs lumping its outline."""
    x, y, z = base
    k, i = 0.0, 0
    while k <= 1.0:
        rad = size * (0.5 + grow * k)
        c = (x - drift * k ** 1.4, y + rise * k, z - size * 0.3 * k)
        col = colors[min(len(colors) - 1, int(k * len(colors)))]
        p.sphere(c, (rad * 1.15, rad * 0.85, rad * 0.9), col, segments=14, rings=8)
        side = 1 if i % 2 else -1
        lump = rad * r.uniform(0.5, 0.7)
        p.sphere((c[0] + side * rad * 0.75, c[1] + rad * r.uniform(0.0, 0.35), c[2] + rad * 0.1),
                 (lump * 1.1, lump * 0.85, lump * 0.9), col, segments=12, rings=7)
        speed = math.hypot(rise, 1.4 * drift * max(k, 0.05) ** 0.4)
        k += 0.75 * rad / speed
        i += 1


def lava_fall(glow, x, y_top, y_bot, z, width, r, wobble=0.15, spread=2.0, steps=8):
    """A lava fall: an orange ribbon that widens as it drops, with a hot core."""
    for color, scale, dz in (("lava", 1.0, 0.0), ("lava_hot", 0.2, width * 0.22)):
        pts = []
        for i in range(steps + 1):
            t = i / steps
            w = width * scale * (1 + (spread - 1) * t ** 1.3)
            dx = math.sin(t * 5 + x) * wobble * width * t
            pts.append((x + dx, y_top + (y_bot - y_top) * t, z + dz, w / 2, w * 0.22))
        B.stream(glow, pts, color, segments=8, power=3.0)


def arch(w, h):
    """Round-topped doorway outline, base at y = 0."""
    rr = w / 2
    pts = [(-rr, 0.0), (rr, 0.0), (rr, h - rr)]
    pts += [(rr * math.cos(a), h - rr + rr * math.sin(a)) for a in [math.pi * k / 10 for k in range(1, 10)]]
    pts.append((-rr, h - rr))
    return pts


def diamond(w, h):
    return [(0, -h / 2), (w / 2, 0), (0, h / 2), (-w / 2, 0)]


# Buildings ------------------------------------------------------------------


def hall(p, glow, base, w, h, d, wall="stone", roof="slate", trim="brass_dark", door=True, windows=2,
         gable=True):
    """Blocky dwarven forge hall: plinth, thick walls, a brass band, a low
    gable facing the camera and a glowing round-topped door."""
    x, y, z = base
    front = z + d / 2
    p.box((x, y + h * 0.07, z), (w * 1.08, h * 0.14, d * 1.06), "stone_dark", bevel=0)
    p.box((x, y + h / 2, z), (w, h, d), wall, bevel=w * 0.02, segments=1, taper=(0.95, 0.95))
    p.box((x, y + h * 0.98, z), (w * 1.04, h * 0.08, d * 1.04), trim, bevel=0)
    if gable:
        rh = w * 0.32
        p.wedge((x, y + h + rh / 2, z), (d * 1.1, rh, w * 1.12), roof, rotation=(0, 90, 0))
    else:
        p.box((x, y + h + h * 0.06, z), (w * 0.9, h * 0.12, d * 0.9), roof, bevel=0)
        for k in range(5):
            p.box((x + (k / 4 - 0.5) * w * 0.9, y + h + h * 0.16, z + d * 0.42), (w * 0.1, h * 0.12, d * 0.1),
                  roof, bevel=0)
    if door:
        dw, dh = w * 0.3, h * 0.6
        p.prism(arch(dw * 1.3, dh * 1.12), w * 0.03, "stone_dark", center=(x, y + h * 0.1, front + w * 0.01))
        glow.prism(arch(dw, dh), w * 0.02, "lava_hot", center=(x, y + h * 0.12, front + w * 0.03))
    for k in range(windows):
        if door:
            side = -1 if k % 2 == 0 else 1
            wx = x + side * w * (0.3 + 0.12 * (k // 2))
        else:
            wx = x + (k - (windows - 1) / 2) * w * 0.26
        glow.box((wx, y + h * 0.6, front + w * 0.01), (w * 0.06, h * 0.24, w * 0.02), "window", bevel=0)


def keep(p, glow, base, w, h, wall="stone", cap="slate"):
    """Tall square tower with a battlemented top, slit windows and a spire.
    Returns the spire's tip."""
    x, y, z = base
    p.box((x, y + h / 2, z), (w, h, w), wall, bevel=w * 0.03, segments=1, taper=(0.9, 0.9))
    p.box((x, y + h * 0.66, z), (w * 0.95, h * 0.025, w * 0.95), "brass_dark", bevel=0)
    p.box((x, y + h + w * 0.08, z), (w * 1.18, w * 0.16, w * 1.18), "stone_dark", bevel=0)
    for k in range(4):
        p.box((x + (k / 3 - 0.5) * w * 0.95, y + h + w * 0.24, z + w * 0.5), (w * 0.18, w * 0.18, w * 0.16),
              "stone_dark", bevel=0)
    p.cone((x, y + h + w * 0.16 + w * 0.6, z), w * 0.55, w * 1.2, cap, segments=4, rotation=(0, 45, 0))
    for k in range(3):
        glow.box((x, y + h * (0.3 + k * 0.17), z + w * 0.46), (w * 0.12, h * 0.06, w * 0.04), "window", bevel=0)
    return (x, y + h + w * 0.16 + w * 1.2, z)


def chimney(p, glow, smoke, base, radius, height, r, wall="brick", drift=-1.0, smoke_scale=1.0):
    """Tall tapering forge chimney with iron bands, a glowing mouth and dark
    smoke drifting off with the wind (to the right)."""
    x, y, z = base
    rt = radius * 0.78
    p.cylinder((x, y + height / 2, z), radius, height, wall, segments=8, radius_top=rt, smooth=False)
    for k in (0.22, 0.5, 0.78):
        rr = radius + (rt - radius) * k + radius * 0.07
        p.cylinder((x, y + height * k, z), rr, height * 0.022, "iron_dark", segments=8, smooth=False)
    top = y + height
    p.cylinder((x, top + rt * 0.22, z), rt * 1.28, rt * 0.44, "iron_dark", segments=8, smooth=False)
    glow.cylinder((x, top + rt * 0.5, z), rt * 0.98, rt * 0.16, "lava_hot", segments=8)
    sz = rt * smoke_scale
    smoke_trail(smoke, (x, top + rt * 1.4, z - rt * 0.5), sz * 1.3, sz * 13 * smoke_scale,
                drift * sz * 12 * smoke_scale, r, ("smoke_hot", "steam", "steam", "steam_light"), grow=2.4)


def anvil_monument(p, glow, base, s):
    """Giant anvil on a stepped pedestal with glowing runes; `s` is the
    width of the anvil's face."""
    x, y, z = base
    p.box((x, y + s * 0.07, z), (s * 1.35, s * 0.14, s * 0.75), "stone_dark", bevel=s * 0.02, segments=1)
    p.box((x, y + s * 0.25, z), (s * 1.05, s * 0.22, s * 0.6), "stone", bevel=s * 0.02, segments=1)
    for k in (-1, 0, 1):
        glow.prism(diamond(s * 0.09, s * 0.12), s * 0.02, "rune", center=(x + k * s * 0.3, y + s * 0.25,
                                                                           z + s * 0.31))
    yb = y + s * 0.36
    p.box((x, yb + s * 0.08, z), (s * 0.66, s * 0.16, s * 0.44), "iron", bevel=s * 0.02, segments=1,
          taper=(0.7, 0.8))
    p.box((x, yb + s * 0.27, z), (s * 0.3, s * 0.24, s * 0.26), "iron_dark", bevel=0, taper=(1.6, 1.25))
    p.box((x - s * 0.04, yb + s * 0.46, z), (s * 0.74, s * 0.15, s * 0.32), "steel", bevel=s * 0.02, segments=1)
    p.box((x - s * 0.04, yb + s * 0.38, z), (s * 0.7, s * 0.03, s * 0.3), "brass", bevel=0)
    p.cone((x + s * 0.33 + s * 0.17, yb + s * 0.475, z), s * 0.085, s * 0.34, "steel", rotation=(0, 0, -90),
           segments=10, smooth=True)
    p.box((x - s * 0.46, yb + s * 0.46, z), (s * 0.14, s * 0.1, s * 0.22), "steel", bevel=s * 0.015, segments=1)
    # hot ingot on the face
    glow.box((x - s * 0.05, yb + s * 0.56, z + s * 0.02), (s * 0.22, s * 0.05, s * 0.1), "lava_hot", bevel=0)
    # giant hammer leaning on it
    hx = x - s * 0.62
    p.box((hx, y + s * 0.62, z + s * 0.2), (s * 0.06, s * 1.1, s * 0.06), "wood", bevel=0, rotation=(0, 0, -16))
    p.box((hx + s * 0.16, y + s * 1.14, z + s * 0.2), (s * 0.34, s * 0.2, s * 0.2), "iron", bevel=s * 0.02,
          segments=1, rotation=(0, 0, -16))
    p.box((hx + s * 0.16, y + s * 1.14, z + s * 0.2), (s * 0.1, s * 0.22, s * 0.22), "brass", bevel=0,
          rotation=(0, 0, -16))


# Sky ------------------------------------------------------------------------


def sky(v, r):
    """Ash clouds: dark stratus bands high up and low ash banks on the
    horizon behind the far volcanoes."""
    clouds = v.piece("Sky", "Cloud")
    for u, sv, d, length in ((-0.8, 0.9, 9000, 0.6), (-0.05, 0.98, 9500, 0.6), (0.6, 0.9, 8500, 0.55),
                             (-0.45, 0.6, 11000, 0.4), (0.4, 0.58, 12000, 0.36), (1.0, 0.7, 9000, 0.4),
                             (0.12, 0.27, 13000, 0.3), (-1.0, 1.04, 8000, 0.5)):
        ash_band(clouds, v, u, sv, d, length, r)
    # low ash banks along the horizon
    for i in range(9):
        u = -1.1 + i * 0.27 + r.uniform(-0.05, 0.05)
        d = r.uniform(12500, 15000)
        c = v.at(u, -0.3, d)
        K.cumulus(clouds, (c[0], GROUND + r.uniform(250, 450), c[2]), r.uniform(0.1, 0.16) * v.unit(d), "ash_far",
                  r, height=0.6, depth=0.6)


def ash_band(p, v, u, sv, d, length, r, colors=("ash_cloud", "smoke", "ash_cloud")):
    """A drifting band of ash cloud `length` of the screen (in u) long: thin
    overlapping streaks, thickest in the middle, with a few lumps on top."""
    unit = v.unit(d)
    n = max(4, int(length * 12))
    for k in range(n):
        t = (k + 0.5) / n - 0.5
        hump = 1 - abs(t) * 1.6
        c = v.at(u + t * length + r.uniform(-0.02, 0.02), sv + r.uniform(-0.012, 0.012) - abs(t) * 0.05, d)
        ln = length * unit * 0.5 * r.uniform(0.28, 0.42)
        K.streak(p, c, ln, colors[k % len(colors)], thickness=0.05 + 0.04 * max(0.0, hump), depth=0.06)
        if hump > 0.3 and r.random() < 0.6:
            rad = ln * r.uniform(0.07, 0.12)
            p.sphere((c[0] + r.uniform(-0.2, 0.2) * ln, c[1] + rad * 0.5, c[2]), (rad * 1.6, rad, rad), colors[1],
                     segments=14, rings=8)


def lava_sea(v, r):
    """Glowing lava sea out to the horizon, broken by dark crust plates."""
    glow = v.piece("Sky", "Glow")
    glow.box((0, GROUND - 2, -11000), (40000, 4, 18000), "lava_sea", bevel=0)
    d = 2200.0
    while d < 15000:
        step = d * 0.14
        n = int(34 + d / 1500)
        for _ in range(n):
            dd = d + r.uniform(0, step)
            u = r.uniform(-1.25, 1.25)
            x, _, z = v.at(u, 0.0, dd)
            s = 0.045 * v.unit(dd) * r.uniform(0.6, 1.4)
            k = r.randint(5, 7)
            pts = []
            for j in range(k):
                a = 2 * math.pi * j / k + r.uniform(-0.25, 0.25)
                rr = s * r.uniform(0.7, 1.0)
                pts.append((math.cos(a) * rr * 1.4, math.sin(a) * rr * 0.9))
            glow.prism(pts, 6.0, "crust" if r.random() < 0.7 else "crust_light", center=(x, GROUND + 3, z),
                        rotation=(-90, 0, 0))
        d += step


def far_range(v, r):
    """Far volcano silhouettes and a jagged ridge on the horizon."""
    solid = v.piece("Sky", "Solid")
    glow = v.piece("Sky", "Glow")
    clouds = v.piece("Sky", "Cloud")
    for u, d, peak, width, rivers in ((-0.42, 15500, -0.07, 0.55, ((-10, 0.35, 0.02, 1.0),)),
                                      (-0.08, 17000, -0.2, 0.3, ()),
                                      (0.3, 16000, -0.14, 0.4, ((15, 0.3, 0.02, 2.0),)),
                                      (-0.95, 14000, 0.02, 0.5, ())):
        c, rc, H = volcano(solid, glow, v, u, d, peak, width, r, rock="far_rock", rim="far_rock2", cap=None,
                           rivers=rivers, lava="lava_deep", core="lava", segments=14, gullies=0, curve=1.3,
                           teeth=3)
        if peak > -0.1:
            plume(clouds, (c[0], c[1] + H * 0.05, c[2]), rc * 1.3, H * 0.45, -rc * 3, r,
                  ("ash_far", "ash_far", "ash_cloud"), count=6, grow=1.8)
    # ridge line
    for x1, x2, peaks_n in ((-1.15, -0.2, 9), (0.15, 1.15, 8)):
        d = 15500
        pts = [(v.at(x1, 0, d)[0], GROUND)]
        for i in range(peaks_n):
            u = x1 + (x2 - x1) * (i + 0.5) / peaks_n
            pts.append((v.at(u, 0, d)[0], v.at(u, r.uniform(-0.3, -0.24), d)[1]))
        pts.append((v.at(x2, 0, d)[0], GROUND))
        solid.prism(pts, 200.0, "far_rock2", center=(0, 0, v.at(0, 0, d)[2]))


def far_fortress(v, r):
    """A far dwarven stronghold on the horizon: dark spires with a few lit
    windows, soft with distance."""
    solid = v.piece("Sky", "Solid")
    glow = v.piece("Sky", "Glow")
    f = Frame(v, 11000)
    u = -0.2
    for du, top_v, w in ((-0.045, -0.2, 0.018), (-0.015, -0.13, 0.028), (0.02, -0.17, 0.022),
                         (0.05, -0.23, 0.016)):
        x, z = f.x(u + du), f.z()
        top = f.y(u + du, top_v)
        ww = w * f.hu
        solid.box((x, (top + GROUND) / 2, z), (ww, top - GROUND, ww), "far_rock", bevel=0, taper=(0.85, 0.85))
        solid.box((x, top, z), (ww * 1.15, ww * 0.18, ww * 1.15), "far_rock2", bevel=0)
        solid.cone((x, top + ww * 0.7, z), ww * 0.62, ww * 1.3, "far_rock", segments=4, rotation=(0, 45, 0))
        for j in range(2):
            glow.box((x, top - (0.035 + j * 0.045) * f.hv, z + ww * 0.45), (ww * 0.2, 0.018 * f.hv, ww * 0.1),
                     "window", bevel=0)


# Landmarks ------------------------------------------------------------------


def great_volcano(v, r):
    solid = v.piece("Landmarks", "Solid")
    glow = v.piece("Landmarks", "Glow")
    smoke = v.piece("Landmarks", "Cloud")
    c, rc, H = volcano(solid, glow, v, 0.64, 6000, 0.34, 0.76, r, cap=None, jitter=0.05,
                       rivers=((-32, 0.6, 0.016, 0.0), (6, 0.85, 0.02, 1.7), (36, 0.5, 0.014, 3.1)),
                       fountain=7, foot="lava_deep")
    plume(smoke, (c[0], c[1] + H * 0.02, c[2]), rc * 1.0, H * 0.6, -rc * 3.0, r,
          ("smoke_hot", "smoke_hot", "smoke_dark", "smoke", "smoke", "smoke_light", "ash"), count=11, grow=2.2)
    # embers thrown up from the crater
    for _ in range(22):
        e = (c[0] + r.uniform(-1.2, 1.2) * rc * 2, c[1] + r.uniform(0.0, 0.35) * H, c[2] + rc)
        B.star(glow, e, rc * r.uniform(0.04, 0.08), "ember" if r.random() < 0.6 else "lava")


def forge_city(v, r):
    """The forge-city on its basalt cliff, left of the stage: halls and
    chimneys on the plateau, a great gate in the cliff face, lava falls, and
    the giant anvil where the columns step down toward the stage."""
    solid = v.piece("Landmarks", "Solid")
    glow = v.piece("Landmarks", "Glow")
    smoke = v.piece("Landmarks", "Cloud")
    f = Frame(v, 1650)  # the depth of the cliff face
    hu, hv = f.hu, f.hv
    z_front = f.z()
    X = f.x
    plateau = -0.55  # the plateau ends here; basalt steps run down toward the stage
    y_top = f.y(-0.9, -0.05)
    steps = [(-0.55, -0.09), (-0.5, -0.12), (-0.46, -0.19), (-0.42, -0.24), (-0.38, -0.33), (-0.34, -0.42)]

    def edge(u):
        if u < plateau:
            return y_top
        top = steps[-1][1]
        for su, sv in steps:
            if u >= su:
                top = sv
        return f.y(u, top)

    # cliff body
    x1, x2 = X(-1.3), X(plateau)
    solid.box(((x1 + x2) / 2, (y_top + GROUND) / 2, z_front - 380), (x2 - x1, y_top - GROUND, 700), "basalt_dark",
              bevel=0)
    # basalt columns along the front
    rc = 0.02 * hu
    u, i = -1.3, 0
    while u < -0.32:
        top = edge(u) - r.uniform(0.0, 0.03) * hv
        col = "basalt" if i % 2 == 0 else "basalt_mid"
        B.hexcol(solid, X(u), z_front + (i % 2) * rc * 0.5, rc, GROUND, top, col, top="basalt_top", top_h=rc * 0.45)
        for _ in range(r.randint(1, 2)):  # joints across the column
            solid.cylinder((X(u), top - r.uniform(0.12, 0.7) * hv, z_front + (i % 2) * rc * 0.5), rc * 1.04,
                           rc * 0.12, "basalt_dark", segments=6, smooth=False)
        if u > plateau:  # a taller back row behind the steps
            B.hexcol(solid, X(u) + rc * 0.9, z_front - rc * 1.6, rc, GROUND, top + r.uniform(0.04, 0.1) * hv,
                     "basalt_mid" if i % 2 == 0 else "basalt", top="basalt_top", top_h=rc * 0.45)
        u += rc * 1.74 / hu
        i += 1
    # molten seams between the columns
    for uu in (-1.12, -0.95, -0.6, -0.41):
        glow.prism(B.zigzag(r, X(uu), edge(uu) - 0.06 * hv, edge(uu) - 0.45 * hv, width=rc * 0.45, kinks=6,
                            amp=rc * 0.4), rc * 0.2, "magma", center=(0, 0, z_front + rc * 1.05))
    # great gate carved into the cliff, glowing from the forges inside
    gx, gy = X(-0.8), f.y(-0.8, -0.52)
    gz = z_front + rc * 1.2
    solid.prism(arch(0.2 * hu, 0.36 * hv), rc * 0.8, "stone_dark", center=(gx, gy - 0.02 * hv, gz))
    solid.prism(arch(0.16 * hu, 0.31 * hv), rc * 0.8, "basalt_dark", center=(gx, gy, gz + rc * 0.3))
    glow.prism(arch(0.12 * hu, 0.27 * hv), rc * 0.4, "lava", center=(gx, gy, gz + rc * 0.6))
    glow.prism(arch(0.07 * hu, 0.19 * hv), rc * 0.4, "lava_hot", center=(gx, gy, gz + rc * 0.8))
    solid.prism(diamond(0.04 * hu, 0.06 * hv), rc * 0.5, "brass", center=(gx, gy + 0.36 * hv, gz + rc * 0.3))
    for side in (-1, 1):
        solid.box((gx + side * 0.12 * hu, gy + 0.17 * hv, gz), (0.035 * hu, 0.36 * hv, rc * 1.2), "stone",
                  bevel=rc * 0.1, segments=1, taper=(0.8, 0.8))
        solid.box((gx + side * 0.12 * hu, gy + 0.37 * hv, gz), (0.05 * hu, 0.03 * hv, rc * 1.4), "brass_dark",
                  bevel=0)
    # lava falls from sluices in the cliff face
    for uu, w in ((-1.04, 0.022), (-0.64, 0.028), (-0.44, 0.02)):
        x = X(uu)
        yt = edge(uu) - 0.07 * hv
        solid.box((x, yt + 0.012 * hv, z_front + rc * 1.4), (w * hu * 1.6, 0.04 * hv, rc * 1.4), "stone_dark",
                  bevel=0)
        glow.box((x, yt, z_front + rc * 1.6), (w * hu * 1.2, 0.012 * hv, rc * 1.2), "lava_hot", bevel=0)
        lava_fall(glow, x, yt, GROUND, z_front + rc * 2.0, w * hu, r)

    # the city on top, back to front
    yt = y_top
    back = z_front - 140
    for uu, w, h, wall in ((-1.05, 0.1, 0.12, "stone"), (-0.89, 0.09, 0.1, "brick"), (-0.61, 0.1, 0.12, "stone")):
        hall(solid, glow, (X(uu), yt, back - 240), w * hu, h * hv, 0.1 * hu, wall=wall, door=False, windows=2)
    chimney(solid, glow, smoke, (X(-1.08), yt, back - 200), 0.018 * hu, 0.6 * hv, r)
    chimney(solid, glow, smoke, (X(-0.7), yt, back - 120), 0.022 * hu, 0.72 * hv, r, smoke_scale=1.2)
    chimney(solid, glow, smoke, (X(-0.63), yt, back - 180), 0.016 * hu, 0.56 * hv, r)
    # great forge hall
    hall(solid, glow, (X(-0.8), yt, back), 0.24 * hu, 0.2 * hv, 0.16 * hu, wall="stone", windows=4)
    # keep with a banner
    tip = keep(solid, glow, (X(-0.98), yt, back + 30), 0.06 * hu, 0.52 * hv)
    K.pennant(solid, (tip[0], tip[1] + 0.06 * hv, tip[2]), 0.06 * hu, "banner", pole="iron_dark", direction=1)
    # side halls
    hall(solid, glow, (X(-1.13), yt, back + 50), 0.12 * hu, 0.12 * hv, 0.1 * hu, wall="brick", windows=2)
    hall(solid, glow, (X(-0.6), yt, back + 40), 0.13 * hu, 0.13 * hv, 0.1 * hu, wall="brick", gable=False,
         windows=2)
    # the giant anvil at the head of the steps
    anvil_monument(solid, glow, (X(-0.45), edge(-0.45), z_front - 30), 0.2 * hu)
    # embers drifting over the city
    for _ in range(26):
        e = v.at(r.uniform(-1.2, -0.4), r.uniform(-0.1, 0.55), f.d * r.uniform(0.9, 1.1))
        B.star(glow, e, 0.005 * hu * r.uniform(0.6, 1.2), "ember" if r.random() < 0.6 else "lava")


def crag_outpost(v, r):
    """A foundry outpost on a basalt crag at the right edge."""
    solid = v.piece("Landmarks", "Solid")
    glow = v.piece("Landmarks", "Glow")
    smoke = v.piece("Landmarks", "Cloud")
    f = Frame(v, 1500)
    hu, hv = f.hu, f.hv
    cu = 0.94
    cx, cz = f.x(cu), f.z()
    y_top = f.y(cu, -0.2)
    rc = 0.02 * hu
    for i in range(13):
        t = i / 12 - 0.5
        x = cx + t * 0.36 * hu
        top = y_top - abs(t) * 0.12 * hv - r.uniform(0, 0.03) * hv
        B.hexcol(solid, x, cz + (i % 3) * rc * 0.6, rc, GROUND, top, "basalt" if i % 2 else "basalt_mid",
                 top="basalt_top", top_h=rc * 0.45)
    # smelter: a squat round furnace with a tall stack
    sx = cx - 0.05 * hu
    solid.cylinder((sx, y_top + 0.06 * hv, cz - rc), 0.05 * hu, 0.12 * hv, "brick", segments=10,
                   radius_top=0.042 * hu, smooth=False)
    solid.cylinder((sx, y_top + 0.125 * hv, cz - rc), 0.045 * hu, 0.012 * hv, "iron_dark", segments=10,
                   smooth=False)
    glow.prism(arch(0.03 * hu, 0.07 * hv), 0.006 * hu, "lava_hot", center=(sx, y_top + 0.005 * hv,
                                                                          cz - rc + 0.05 * hu))
    chimney(solid, glow, smoke, (sx + 0.05 * hu, y_top, cz - rc * 2), 0.016 * hu, 0.42 * hv, r)
    hall(solid, glow, (cx + 0.11 * hu, y_top - 0.02 * hv, cz), 0.09 * hu, 0.08 * hv, 0.08 * hu, wall="stone",
         windows=2)
    # spill off the crag
    lava_fall(glow, cx - 0.17 * hu, y_top - 0.08 * hv, GROUND, cz + rc * 1.8, 0.025 * hu, r)


def birds(v, r):
    """Dark birds wheeling around the volcano's plume and over the city."""
    solid = v.piece("Landmarks", "Solid")
    K.flock(solid, v.at(0.4, 0.6, 2600), 17.0, r, count=5)
    K.flock(solid, v.at(-0.22, 0.56, 2000), 11.0, r, count=3)


# Haze -----------------------------------------------------------------------


def haze(v, r):
    """Ash banks drifting along the bottom and embers floating up."""
    clouds = v.piece("Haze", "Cloud")
    glow = v.piece("Haze", "Glow")
    us = [-1.34, -1.1, -0.86, -0.62, -0.38, -0.12, 0.14, 0.4, 0.66, 0.9, 1.14, 1.38]
    vs = [-0.66, -0.78, -0.9, -1.0, -1.08, -1.12, -1.12, -1.08, -0.98, -0.86, -0.74, -0.66]
    K.cloud_row(clouds, v, us, vs, 720, 0.2, "haze", r, height=0.5)
    K.cloud_row(clouds, v, [u + 0.12 for u in us[:-1]], [sv - 0.1 for sv in vs[:-1]], 560, 0.17, "haze_light",
                r, height=0.45)
    for u, sv, d, w in ((-1.32, 0.92, 900, 0.24), (1.34, 0.96, 1000, 0.22)):
        K.cumulus(clouds, v.at(u, sv, d), w * v.unit(d), "steam", r, height=0.7)
    for _ in range(60):
        u = r.uniform(-1.3, 1.3)
        sv = r.uniform(-0.9, 0.7)
        if abs(u) < 0.4 and sv < 0.2 and r.random() < 0.7:
            continue  # keep the stage area calm
        d = r.uniform(450, 900)
        B.star(glow, v.at(u, sv, d), 0.0028 * v.unit(d) * r.uniform(0.6, 1.3), "ember" if r.random() < 0.6 else
               "lava")
