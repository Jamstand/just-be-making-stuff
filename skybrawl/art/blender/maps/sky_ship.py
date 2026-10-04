"""
SkyShip ("Sky-ship deck"): a fantasy flying galleon sailing above the clouds.

The bow points left (figurehead, bowsprit), the raised quarterdeck and the
propeller are at the stern on the right. The three masts stand behind the
lane (z = -7.2) and carry the soft platforms as slatted yard tops; sails hang
behind the masts. A glowing aether crystal under the keel keeps her aloft.
"""

import math

from . import _props_a as P

MAP_ID = "SkyShip"
SKY = ("#5c9ee6", "#ffd6aa")

PLATFORMS = [
    (-40, -10, 40, 0, False),  # main deck
    (24, 0, 40, 6, False),  # quarterdeck
    (-6, 26, 6, 27, True),  # crow's-nest top yard
    (-26, 14, -12, 15, True),  # fore yardarm
    (10, 16, 22, 17, True),  # mizzen yardarm
]

COLORS = {
    "deck": "#dba766",
    "deck_dark": "#c08b50",
    "hull": "#a6683b",
    "hull_dark": "#8b5331",
    "hull_deep": "#6c3e23",
    "keel": "#3f2515",
    "paint": "#2c8c9c",
    "paint_dark": "#1f6674",
    "gold": "#f3bf4c",
    "brass": "#cf9a3c",
    "iron": "#3a3c49",
    "mast": "#8f5c33",
    "mast_dark": "#6f4527",
    "sail": "#f8eed6",
    "sail_red": "#d4493f",
    "rope": "#d2ab70",
    "flag": "#e04a3c",
    "lamp": "#ffd56e",
    "window": "#ffe6a0",
    "aether": "#8ef3ff",
    "barrel": "#ad703d",
    "cloud": "#ffffff",
    "cloud_warm": "#fff0e2",
    "cloud_far": "#f6eef0",
    "grass": "#7cc35b",
    "grass_dark": "#5aa44c",
    "rock": "#9d91aa",
    "rock_dark": "#786d88",
    "rock_deep": "#5f5571",
    "far_grass": "#a9d79e",
    "far_grass_dark": "#91c48f",
    "far_rock": "#bdb7d2",
    "far_rock_dark": "#a59fc4",
    "far_rock_deep": "#918ab3",
    "trunk": "#7a5236",
    "leaves": "#5fb860",
    "leaves_dark": "#4a9f55",
    "blossom": "#f4a9c8",
    "far_leaves": "#95d09a",
    "balloon": "#d9493e",
    "balloon_far": "#e8907e",
    "ship_far": "#b98f6e",
    "gull": "#ffffff",
    "gull_tip": "#4b4b5c",
}

MAST_Z = -7.2
W0 = 8.75  # half depth of the deck along z
LAP = 0.22  # clinker step between hull strakes

# Hull side profile: x of the bow (left) and stern (right) edge at height y.
BOW = [(-22.0, -19.0), (-20.2, -29.0), (-17.5, -37.0), (-14.5, -42.2), (-11.5, -44.9), (-9.0, -45.6),
       (-6.0, -44.8), (-3.0, -42.7), (0.0, -40.3), (8.0, -40.3)]
STERN = [(-22.0, 17.0), (-20.5, 24.0), (-18.0, 30.5), (-15.0, 35.5), (-12.0, 39.0), (-9.0, 41.3),
         (-6.0, 42.5), (-3.0, 42.9), (0.0, 42.6), (3.0, 41.7), (6.0, 40.3), (8.0, 40.0)]


def bow_x(y):
    return P.catmull(BOW, y)


def stern_x(y):
    return P.catmull(STERN, y)


def half_width(y):
    """Hull half depth (z) at height y: full at the deck, rounding to the keel."""
    f = min(max(-y / 23.5, 0.0), 1.0)
    return W0 * math.sqrt(max(1 - f ** 2.4, 0.02))


def plan(x, y):
    """Plan-view taper: pointed bow, wide transom."""
    u = (x - bow_x(y)) / 15.0
    b = math.sqrt(min(max(u, 0.0), 1.0))
    v = (stern_x(y) - x) / 12.0
    s = 0.8 + 0.2 * math.sqrt(min(max(v, 0.0), 1.0))
    return max(0.04, min(b, s))


def edge_z(x, y, inset=0.0):
    return W0 * plan(x, y) - inset


def bisect_x(fn, lo, hi, steps=30):
    """Smallest x in [lo, hi] with fn(x) True, assuming fn flips once."""
    for _ in range(steps):
        mid = (lo + hi) / 2
        if fn(mid):
            hi = mid
        else:
            lo = mid
    return hi


# Hull ----------------------------------------------------------------------


def band(p, ya, yb, color, wa=None, wb=None, x0=None, nu=40):
    wa = half_width(ya) if wa is None else wa
    wb = half_width(yb) + LAP if wb is None else wb
    xa0 = bow_x(ya) if x0 is None else x0
    xb0 = bow_x(yb) if x0 is None else x0
    xa1, xb1 = stern_x(ya), stern_x(yb)
    rings = []
    for i in range(nu + 1):
        u = 0.5 - 0.5 * math.cos(math.pi * i / nu)
        xt = xa0 + (xa1 - xa0) * u
        xb = xb0 + (xb1 - xb0) * u
        ft, fb = wa * plan(xt, ya), wb * plan(xb, yb)
        rings.append([(xt, ya, ft), (xb, yb, fb), (xb, yb, -fb), (xt, ya, -ft)])
    P.loft_rings(p, rings, color)


def perimeter(y, x_end, hw=W0, out=0.0, n=34):
    """Hull edge at height y (half depth hw * plan + out) from the back side at
    x_end, around the bow, to the front side at x_end."""
    x_tip = bow_x(y) + 0.05
    xs = [x_tip + (x_end - x_tip) * (1 - math.cos(math.pi / 2 * i / n)) for i in range(n + 1)]
    back = [(x, y, -(hw * plan(x, y) + out)) for x in reversed(xs)]
    front = [(x, y, hw * plan(x, y) + out) for x in xs]
    return back + front[1:]


def linspace(a, b, n):
    return [a + (b - a) * i / n for i in range(n + 1)]


def hull(p, trim, glow):
    levels = [-0.25, -2.6, -5.0, -7.4, -9.8, -12.2, -14.6, -17.0, -19.4, -21.7]
    colors = ["paint", "hull", "hull_dark", "hull", "hull_dark", "hull", "hull_dark", "hull_deep", "hull_deep"]
    for (ya, yb), c in zip(zip(levels, levels[1:]), colors):
        band(p, ya, yb, c, wa=half_width(ya) + (0.25 if c == "paint" else 0.0))

    # deck plate following the pointed bow (fills in round the square board ends)
    band(p, -0.01, -0.3, "deck_dark", wa=W0 - 0.3, wb=W0 - 0.3, nu=48)
    # deck boards (top exactly at y = 0, between the bow and the quarterdeck)
    n = 7  # odd, so a board (not a seam) runs under the fighters at z = 0
    zw = (W0 - 0.45) * 2 / n
    for i in range(n):
        z0 = -(W0 - 0.45) + i * zw
        z1 = z0 + zw
        edge = max(abs(z0), abs(z1))
        xs = bisect_x(lambda x: edge_z(x, 0.0, 0.45) >= edge, bow_x(0.0), 0.0)
        p.box(((xs + 24.1) / 2, -0.25, (z0 + z1) / 2), (24.1 - xs, 0.5, zw),
              "deck" if i % 2 else "deck_dark", bevel=0.03, segments=1)

    # gunwale cap along the deck edge (0.12 proud of the deck at most)
    trim_path = perimeter(0.0, 24.2, hw=W0 + 0.25, n=48)
    P.sweep(trim, trim_path, P.rect(0.16, 0.7, 0.12, -0.85), "gold")
    # gold wale under the painted band
    P.sweep(trim, perimeter(-2.6, stern_x(-2.6) - 0.6, hw=half_width(-2.6) + LAP),
            P.rect(0.2, 0.15, 0.22, -0.22), "gold")

    # stem post + keel + stern post
    path = [(bow_x(y) - 0.1, y, 0.0) for y in [-0.6 - i * 1.5 for i in range(15)]]
    path += [(x, -22.0, 0.0) for x in [bow_x(-22.0) + 3 + i * 5.0 for i in range(8)]]
    path += [(stern_x(y) + 0.1, y, 0.0) for y in [-21.5 + i * 1.5 for i in range(12)]]
    P.sweep(trim, path, P.rect(0.55, 0.45, 0.6, -0.6), "keel", up=(0, 0, 1))

    # portholes on the second strake
    for x in (-30, -20, -10, 0, 10, 18):
        y = -3.9
        z = (half_width(-2.6) + half_width(-5.0) + LAP) / 2 * plan(x, y) + 0.12
        trim.torus((x, y, z), 0.78, 0.2, "brass", rotation=(90, 0, 0), segments=14, sides=5)
        glow.cylinder((x, y, z - 0.05), 0.66, 0.2, "window", rotation=(90, 0, 0), segments=12)


def quarterdeck(p, trim, glow):
    # castle body: x from 24 to the stern, y 0..6
    band(p, 5.75, -0.3, "paint", wa=W0 + 0.12, wb=W0 + 0.12, x0=24.0, nu=24)
    # boards on top, flush at y = 6
    n = 7
    zw = (W0 - 0.35) * 2 / n
    for i in range(n):
        z0 = -(W0 - 0.35) + i * zw
        z1 = z0 + zw
        edge = max(abs(z0), abs(z1))
        xe = bisect_x(lambda x: edge_z(x, 6.0, 0.35) < edge, 24.0, stern_x(6.0))
        p.box(((24.0 + xe) / 2, 5.75, (z0 + z1) / 2), (xe - 24.0, 0.5, zw),
              "deck" if i % 2 else "deck_dark", bevel=0.03, segments=1)
    # cap trim round the top edge
    x_s = stern_x(6.0)
    xs = [24.0 + (x_s - 24.0) * (1 - math.cos(math.pi / 2 * i / 16)) for i in range(17)]
    front = [(x, 6.0, edge_z(x, 6.0) + 0.12) for x in xs]
    back = [(x, 6.0, -(edge_z(x, 6.0) + 0.12)) for x in reversed(xs)]
    path = [(24.0, 6.0, -(W0 + 0.12)), (24.0, 6.0, 0.0)] + front + back[1:]
    P.sweep(trim, path, P.rect(0.15, 0.5, 0.12, -0.7), "gold")
    # trim strips and stern-gallery windows on the castle front
    zf = W0 + 0.12
    path = [(x, 0.3, (W0 + 0.12) * plan(x, 0.3)) for x in linspace(23.9, stern_x(0.3) - 0.3, 16)]
    P.sweep(trim, path, P.rect(0.2, 0.1, 0.25, -0.25), "gold")
    trim.box((24.05, 3.0, zf - 0.1), (0.4, 6.0, 0.4), "gold", bevel=0.08)
    for x in (27.4, 31.6, 35.8):
        z = edge_z(x, 3.0) + 0.12
        trim.box((x, 2.9, z + 0.05), (2.5, 3.5, 0.3), "gold", bevel=0.1)
        glow.box((x, 2.75, z + 0.18), (1.8, 2.5, 0.2), "window", bevel=0.05, segments=1)
        trim.box((x, 2.75, z + 0.3), (0.18, 2.5, 0.12), "paint_dark", bevel=0.02, segments=1)
        trim.box((x, 2.6, z + 0.3), (1.8, 0.16, 0.12), "paint_dark", bevel=0.02, segments=1)


def railing(p, path_pts, height=2.6, post_every=2.4, color="mast", cap="gold"):
    """Back-edge railing: posts + top and mid rails along path (all z < -6)."""
    P.sweep(p, [(x, y + height, z) for x, y, z in path_pts], P.rect(0.22, 0.22, 0.16, -0.16), cap)
    P.sweep(p, [(x, y + height * 0.5, z) for x, y, z in path_pts], P.rect(0.12, 0.12, 0.1, -0.1), color)
    length = 0.0
    last = None
    for q in path_pts:
        if last is not None:
            length += math.dist(q, last)
        if last is None or length >= post_every:
            p.box((q[0], q[1] + height / 2, q[2]), (0.32, height, 0.32), color, bevel=0.05, segments=1)
            length = 0.0
        last = q
    q = path_pts[-1]
    p.box((q[0], q[1] + height / 2, q[2]), (0.32, height, 0.32), color, bevel=0.05, segments=1)


def bow_and_stern(p, trim, glow, rig):
    # figurehead: a golden griffin leaning out from the stem, wings swept along the bow
    trim.limb((-44.0, -7.4, 0), (-47.3, -4.5, 0), 1.25, 0.95, "gold", segments=10)
    trim.sphere((-48.2, -3.7, 0), (1.25, 1.05, 1.0), "gold", segments=12, rings=8)
    trim.cone((-50.0, -3.95, 0), 0.6, 1.9, "brass", rotation=(0, 0, 100), segments=6)
    trim.sphere((-49.1, -4.15, 0), (0.55, 0.35, 0.45), "brass", segments=8, rings=5)
    for s_ in (1, -1):
        trim.sphere((-48.75, -3.35, s_ * 0.86), 0.17, "iron", segments=6, rings=4)
    for a, b in (((-47.6, -2.9), (-45.8, -1.5)), ((-48.2, -2.8), (-46.9, -1.15)), ((-47.1, -3.2), (-45.0, -2.3))):
        P.rod(trim, (a[0], a[1], 0), (b[0], b[1], 0), 0.36, "gold", segments=6, radius_b=0.02)
    wing = [(0, -1.2), (0.8, 1.2), (3.0, 2.6), (6.4, 2.9), (4.8, 1.7), (7.4, 1.3), (5.2, 0.3), (7.0, -0.7),
            (4.4, -1.1), (2.0, -2.2)]
    for s_ in (1, -1):
        trim.prism(wing, 0.3, "gold", center=(-44.6, -4.2, s_ * 0.9), rotation=(0, -s_ * 40, 0), bevel=0.06)
    # bowsprit
    P.rod(rig, (-41.0, -1.8, 0), (-57.0, 7.2, 0), 0.6, "mast", segments=8, radius_b=0.32)
    rig.cylinder((-44.5, 0.17, 0), 0.72, 0.5, "iron", rotation=(0, 0, 60.6), segments=8)
    rig.cylinder((-50.0, 3.3, 0), 0.62, 0.45, "iron", rotation=(0, 0, 60.6), segments=8)
    lantern(rig, glow, (-56.2, 5.3, 0), 0.8)
    P.rope(rig, (-56.4, 7.0, 0), (-56.2, 6.0, 0), "rope", radius=0.08)

    # tail fin under the stern (teal with a gold leading edge)
    fin = [(40.6, -9.6), (44.6, -10.6), (49.4, -14.6), (51.2, -20.2), (46.2, -20.4), (38.0, -19.4),
           (31.0, -18.6), (35.6, -15.6)]
    trim.prism(fin, 0.8, "paint", bevel=0.1)
    P.sweep(trim, [(40.4, -9.5, 0), (44.6, -10.5, 0), (49.4, -14.5, 0), (51.3, -20.3, 0)],
            P.rect(0.3, 0.1, 0.5, -0.5), "gold", up=(0, 0, 1))
    for x, y in ((45.0, -15.2), (40.2, -16.6)):
        trim.cylinder((x, y, 0), 0.35, 1.0, "brass", rotation=(90, 0, 0), segments=8)
    # propeller
    hub = (47.2, -3.2, 0.0)
    P.rod(trim, (42.0, -3.2, 0), hub, 0.42, "iron", segments=8)
    trim.cylinder(hub, 0.75, 1.5, "brass", rotation=(0, 0, -90), segments=10)
    trim.cone((hub[0] + 1.25, hub[1], 0), 0.75, 1.1, "gold", rotation=(0, 0, -90), segments=10, smooth=True)
    for k in range(3):
        a = 90 + k * 120
        d = (0, math.cos(math.radians(a)), math.sin(math.radians(a)))
        c = (hub[0], hub[1] + d[1] * 2.9, d[2] * 2.9)
        trim.box(c, (0.25, 4.0, 1.9), "brass", bevel=0.14, rotation=(a - 90, 50, 0))

    # stern lantern on an iron post, stern flag
    zb = -(edge_z(39.0, 6.0) - 0.6)
    P.rod(rig, (39.0, 6.0, zb), (39.0, 10.2, zb), 0.18, "iron", segments=6)
    P.rod(rig, (39.0, 10.2, zb), (40.4, 10.6, zb), 0.14, "iron", segments=6)
    lantern(rig, glow, (40.4, 9.6, zb), 1.2)
    zf = -(edge_z(37.0, 6.0) - 0.5)
    P.rod(rig, (37.0, 6.0, zf), (37.0, 19.0, zf), 0.2, "mast", segments=6)
    rig.sphere((37.0, 19.2, zf), 0.35, "gold", segments=8, rings=6)
    flag(rig, (37.2, 18.6, zf), 7.5, 4.2, "flag")


def lantern(frame, glow, pos, s=1.0):
    x, y, z = pos
    glow.box((x, y, z), (0.8 * s, 1.05 * s, 0.8 * s), "lamp", bevel=0.14 * s, segments=1)
    frame.cylinder((x, y + 0.66 * s, z), 0.62 * s, 0.32 * s, "iron", segments=8, radius_top=0.24 * s)
    frame.box((x, y - 0.6 * s, z), (0.9 * s, 0.18 * s, 0.9 * s), "iron", bevel=0.04 * s, segments=1)
    frame.torus((x, y + 0.95 * s, z), 0.22 * s, 0.06 * s, "iron", rotation=(90, 0, 0), segments=8, sides=4)
    for dx in (-0.42, 0.42):
        frame.box((x + dx * s, y, z + 0.42 * s), (0.1 * s, 1.1 * s, 0.1 * s), "iron", bevel=0)


def flag(p, top, length, height, color, waves=1.6, amp=0.6, rows=4, cols=8):
    x0, y0, z0 = top
    grid = []
    for r in range(rows + 1):
        v = r / rows
        row = []
        for c in range(cols + 1):
            u = c / cols
            x = x0 + u * length
            y = y0 - v * height * (1 - 0.35 * u) - u * 0.8
            z = z0 + amp * u * math.sin(u * math.pi * 2 * waves * 0.5 + 0.4)
            row.append((x, y, z))
        grid.append(row)
    P.shell(p, grid, 0.12, color)


# Masts, yards and sails ------------------------------------------------------


MASTS = {"fore": (-19.0, 45.0), "main": (0.0, 51.0), "mizzen": (16.0, 40.0)}


def mast(rig, x, top):
    rig.cylinder((x, (top - 0.5) / 2, MAST_Z), 0.95, top + 0.5, "mast", segments=10, radius_top=0.55)
    for y in range(4, int(top) - 2, 7):
        r = 0.95 - (0.4 * y / top) + 0.1
        rig.cylinder((x, y, MAST_Z), r, 0.4, "iron", segments=10)
    rig.sphere((x, top + 0.4, MAST_Z), 0.6, "gold", segments=10, rings=6)
    rig.cylinder((x, 0.25, MAST_Z), 1.5, 0.6, "mast_dark", segments=10, radius_top=1.1)


def yard(rig, x0, x1, y):
    z = MAST_Z - 1.3
    P.rod(rig, (x0, y, z), (x1, y, z), 0.36, "mast_dark", segments=8)
    for x in (x0, x1):
        rig.sphere((x, y, z), 0.42, "mast_dark", segments=8, rings=5)
    rig.box(((x0 + x1) / 2, y, (z + MAST_Z) / 2), (1.0, 0.9, 1.6), "iron", bevel=0.05, segments=1)


def sail_point(x0, x1, yt, yb, flare, bulge, u, v, z0):
    xl = x0 - flare * v
    xr = x1 + flare * v
    x = xl + (xr - xl) * u + (u - 0.5) * 2 * 0.6 * math.sin(math.pi * v)
    y = yt + (yb - yt) * v + 1.1 * math.sin(math.pi * u) * v ** 3
    z = z0 - bulge * math.sin(math.pi * u) * math.sin(math.pi * 0.5 * v) ** 0.8
    return (x, y, z)


def sail(rig, x0, x1, yt, yb, stripes=True, flare=1.4, bulge=2.2):
    z0 = MAST_Z - 1.75
    cuts = [(0.0, 0.36, "sail"), (0.36, 0.52, "sail_red"), (0.52, 1.0, "sail")] if stripes else [(0, 1, "sail")]
    for v0, v1, color in cuts:
        rows = max(2, round((v1 - v0) * 8))
        grid = [[sail_point(x0, x1, yt, yb, flare, bulge, c / 9, v0 + (v1 - v0) * r / rows, z0)
                 for c in range(10)] for r in range(rows + 1)]
        P.shell(rig, grid, 0.18, color)
    return z0


def furled(rig, x0, x1, y):
    z = MAST_Z - 1.45
    n = max(3, round((x1 - x0) / 2.3))
    for i in range(n):
        x = x0 + (i + 0.5) * (x1 - x0) / n
        rig.sphere((x, y - 0.62, z), ((x1 - x0) / n * 0.68, 0.72, 0.78), "sail", segments=10, rings=6)
    for i in range(1, n):
        x = x0 + i * (x1 - x0) / n
        rig.torus((x, y - 0.6, z), 0.62, 0.1, "rope", rotation=(0, 0, 90), segments=10, sides=4,
                  scale=(1.15, 1.25))


def emblem(rig, center):
    x, y, z = center
    rig.cylinder((x, y, z + 0.1), 2.6, 0.3, "gold", rotation=(90, 0, 0), segments=18)
    rig.cylinder((x, y, z + 0.28), 2.0, 0.2, "sail_red", rotation=(90, 0, 0), segments=18)
    wing = [(-1.6, 0.2), (-0.4, 1.3), (0.0, 0.5), (0.4, 1.3), (1.6, 0.2), (0.5, -0.2), (0.0, -1.2), (-0.5, -0.2)]
    rig.prism([(x + a, y + b) for a, b in wing], 0.16, "gold", center=(0, 0, z + 0.42))


def spanker(rig, sails):
    a, b, c, d = (16.9, 9.6), (33.8, 10.2), (31.0, 34.6), (16.9, 30.6)  # tack, clew, peak, throat
    z0 = MAST_Z - 1.2

    def pt(u, v):
        bx = a[0] + (b[0] - a[0]) * u
        by = a[1] + (b[1] - a[1]) * u
        tx = d[0] + (c[0] - d[0]) * u
        ty = d[1] + (c[1] - d[1]) * u
        x = bx + (tx - bx) * v + 1.3 * u * math.sin(math.pi * v)
        y = by + (ty - by) * v + 0.9 * math.sin(math.pi * u) * (1 - v) * 0.6
        z = z0 - 2.2 * math.sin(math.pi * u) ** 0.9 * math.sin(math.pi * v) ** 0.8
        return (x, y, z)

    for v0, v1, color in ((0.0, 0.42, "sail"), (0.42, 0.56, "sail_red"), (0.56, 1.0, "sail")):
        rows = max(2, round((v1 - v0) * 9))
        grid = [[pt(cc / 8, v0 + (v1 - v0) * r / rows) for cc in range(9)] for r in range(rows + 1)]
        P.shell(sails, grid, 0.18, color)
    zs = z0 + 0.35
    P.rod(rig, (16.4, a[1] - 0.4, zs), (b[0] + 0.8, b[1] - 0.4, zs), 0.32, "mast_dark", segments=8)
    P.rod(rig, (16.4, d[1] + 0.3, zs), (c[0] + 0.6, c[1] + 0.4, zs), 0.3, "mast_dark", segments=8)
    for q in ((b[0] + 0.8, b[1] - 0.4, zs), (c[0] + 0.6, c[1] + 0.4, zs)):
        rig.sphere(q, 0.36, "mast_dark", segments=8, rings=5)
    for k in range(5):
        y = a[1] + (d[1] - a[1]) * (k + 0.5) / 5
        rig.torus((16.9, y, MAST_Z - 0.2), 1.05, 0.12, "rope", segments=10, sides=4)


def yard_platform(plat, rig, glow, x1, y2, x2, mast_x, z_front=3.4, z_back=-3.6):
    n = max(6, round((x2 - x1) / 1.15))
    w = (x2 - x1) / n
    for i in range(n):
        a = x1 + i * w + (0.07 if i > 0 else 0.0)
        b = x1 + (i + 1) * w - (0.07 if i < n - 1 else 0.0)
        plat.box(((a + b) / 2, y2 - 0.22, (z_front + z_back) / 2), (b - a, 0.44, z_front - z_back),
                 "deck" if i % 2 == 0 else "deck_dark", bevel=0.05, segments=1)
    for z in (z_front - 0.35, z_back + 0.35):
        plat.box(((x1 + x2) / 2, y2 - 0.72, z), (x2 - x1 + 0.7, 0.56, 0.5), "mast_dark", bevel=0.06, segments=1)
    for x in (x1 + 0.25, x2 - 0.25):
        plat.box((x, y2 - 0.72, (z_front + z_back) / 2), (0.5, 0.56, z_front - z_back - 0.4), "mast_dark",
                 bevel=0.06, segments=1)
    for z in (z_front - 0.1,):
        for x in (x1 + 0.6, x2 - 0.6):
            plat.sphere((x, y2 - 0.72, z), 0.14, "brass", segments=6, rings=4)
    # beam back to the mast and a knee brace under it
    plat.box((mast_x, y2 - 0.72, (z_back + MAST_Z) / 2), (0.7, 0.56, z_back - MAST_Z + 0.6), "mast_dark",
             bevel=0.06, segments=1)
    P.rod(rig, (mast_x, y2 - 4.2, MAST_Z + 0.6), (mast_x, y2 - 1.0, z_back + 0.7), 0.24, "mast_dark", segments=6)
    # rigging lifts from the back corners to the mast
    top = y2 + 11.0
    for x in (x1 + 0.4, x2 - 0.4):
        P.rope(rig, (x, y2 - 0.6, z_back + 0.3), (mast_x, top, MAST_Z + 0.4), "rope", radius=0.11)
        lantern(rig, glow, (x + (0.9 if x < mast_x else -0.9), y2 - 2.6, z_back + 0.6), 0.75)
        P.rope(rig, (x + (0.9 if x < mast_x else -0.9), y2 - 1.95, z_back + 0.6),
               (x + (0.9 if x < mast_x else -0.9), y2 - 1.0, z_back + 0.6), "iron", radius=0.06)


def crows_nest(rig, x, y):
    rig.cylinder((x, y + 1.5, MAST_Z), 2.0, 3.0, "hull_dark", segments=12, radius_top=2.25)
    rig.torus((x, y + 3.0, MAST_Z), 2.25, 0.22, "gold", segments=14, sides=5)
    rig.torus((x, y + 0.4, MAST_Z), 2.02, 0.18, "iron", segments=14, sides=5)


def rigging(rig, sails, plat, glow):
    for name, (x, top) in MASTS.items():
        mast(rig, x, top)
    zr = -(W0 - 0.35)
    # fore mast: course sail (billowing), furled topsail
    yard(rig, -30.0, -8.0, 31.0)
    sail(sails, -29.4, -8.6, 30.8, 17.8)
    yard(rig, -26.0, -12.0, 38.0)
    furled(sails, -25.5, -12.5, 38.0)
    # main mast: furled course, billowing topsail with the ship's crest, royal
    yard(rig, -12.5, 12.5, 21.2)
    furled(sails, -12.0, 12.0, 21.2)
    yard(rig, -10.0, 10.0, 44.0)
    z0 = sail(sails, -9.4, 9.4, 43.8, 29.6, stripes=False, bulge=2.0)
    c = sail_point(-9.4, 9.4, 43.8, 29.6, 1.4, 2.0, 0.5, 0.5, z0)
    emblem(sails, c)
    yard(rig, -6.0, 6.0, 48.5)
    furled(sails, -5.5, 5.5, 48.5)
    crows_nest(rig, 0.0, 27.3)
    # mizzen: fore-and-aft spanker sail with gaff and boom, furled topsail
    spanker(rig, sails)
    yard(rig, 10.0, 22.0, 37.5)
    furled(sails, 10.5, 21.5, 37.5)

    # soft platforms on the masts
    yard_platform(plat, rig, glow, -26.0, 15.0, -12.0, -19.0)
    yard_platform(plat, rig, glow, -6.0, 27.0, 6.0, 0.0)
    yard_platform(plat, rig, glow, 10.0, 17.0, 22.0, 16.0)

    # pennants
    flag(sails, (0.5, 50.6, MAST_Z), 11.0, 1.6, "flag", amp=0.5)
    flag(sails, (-18.5, 44.6, MAST_Z), 6.5, 1.2, "flag", amp=0.4)
    flag(sails, (16.5, 39.6, MAST_Z), 6.0, 1.1, "flag", amp=0.4)

    # shrouds down to the back rail and stays between the mast tops
    for x, top in MASTS.values():
        for dx in (-6.5, 6.5):
            for k in (0.0, 1.2):
                xx = x + dx + (k if dx < 0 else -k)
                P.rope(rig, (x + (0.4 if dx > 0 else -0.4), top - 8.0, MAST_Z - 0.3),
                       (xx, 2.7, zr), "rope", radius=0.1)
        lantern(rig, glow, (x + 1.5, 9.0, MAST_Z + 0.2), 0.85)
        P.rod(rig, (x + 0.6, 10.0, MAST_Z + 0.2), (x + 1.5, 10.0, MAST_Z + 0.2), 0.1, "iron", segments=5)
    P.rope(rig, (0.0, 49.0, MAST_Z), (-19.0, 41.0, MAST_Z), "rope", radius=0.11, sag=0.8, pieces=3)
    P.rope(rig, (16.0, 38.0, MAST_Z), (0.0, 38.0, MAST_Z), "rope", radius=0.11, sag=0.6, pieces=3)
    P.rope(rig, (-19.0, 43.0, MAST_Z), (-56.8, 7.4, 0.0), "rope", radius=0.11)
    P.rope(rig, (16.0, 38.5, MAST_Z), (37.0, 18.8, -(edge_z(37.0, 6.0) - 0.5)), "rope", radius=0.11)


# Deck dressing ---------------------------------------------------------------


def deck_props(p, glow):
    # back railing on the main deck (from where the bow is wide enough) and quarterdeck
    x_start = bisect_x(lambda x: edge_z(x, 0.0, 0.35) >= 6.4, bow_x(0.0), 0.0)
    xs = [x_start + (23.8 - x_start) * i / 40 for i in range(41)]
    railing(p, [(x, 0.0, -edge_z(x, 0.0, 0.35)) for x in xs])
    x_end = bisect_x(lambda x: edge_z(x, 6.0, 0.35) < 6.4, 24.5, stern_x(6.0))
    xs = [24.3 + (x_end - 24.3) * i / 16 for i in range(17)]
    railing(p, [(x, 6.0, -edge_z(x, 6.0, 0.35)) for x in xs], height=2.2)
    # ladder up the quarterdeck wall, at the back
    for z in (-6.6, -7.9):
        p.box((23.5, 3.2, z), (0.3, 6.6, 0.3), "mast_dark", bevel=0.05, segments=1)
    for y in (1.0, 2.4, 3.8, 5.2):
        p.box((23.5, y, -7.25), (0.25, 0.22, 1.5), "mast_dark", bevel=0.04, segments=1)
    # barrels and crates
    for x, z, s in ((-30.5, -6.9, 1.0), (-28.6, -7.4, 0.9), (-11.5, -7.3, 1.0), (19.5, -7.2, 0.95)):
        barrel(p, (x, 0.0, z), s)
    for x, z, s, rot in ((-33.0, -6.8, 1.7, 10), (-9.0, -7.2, 1.5, -8), (21.5, -7.0, 1.8, 4)):
        p.box((x, s / 2, z), (s, s, s), "barrel", bevel=0.1, segments=1, rotation=(0, rot, 0))
        p.box((x, s / 2, z + s / 2 + 0.02), (s * 0.85, 0.2, 0.06), "mast_dark", bevel=0, rotation=(0, rot, 0))
    p.box((-33.2, 1.7 + 0.6, -7.0), (1.2, 1.2, 1.2), "barrel", bevel=0.1, segments=1, rotation=(0, 30, 0))
    p.torus((5.0, 0.2, -7.2), 1.0, 0.25, "rope", segments=12, sides=5)
    p.torus((5.0, 0.55, -7.2), 0.7, 0.25, "rope", segments=12, sides=5)
    # helm on the quarterdeck, near the back
    hx, hy, hz = 31.0, 8.6, -6.7
    p.box((hx, 7.0, hz - 0.5), (1.0, 2.0, 1.0), "mast_dark", bevel=0.1, segments=1)
    p.torus((hx, hy, hz), 1.7, 0.2, "mast", rotation=(90, 0, 0), segments=18, sides=5)
    p.cylinder((hx, hy, hz), 0.45, 0.6, "brass", rotation=(90, 0, 0), segments=10)
    for k in range(8):
        a = math.radians(k * 45 + 22.5)
        P.rod(p, (hx, hy, hz), (hx + math.cos(a) * 2.45, hy + math.sin(a) * 2.45, hz), 0.12, "mast", segments=5)
        p.sphere((hx + math.cos(a) * 2.5, hy + math.sin(a) * 2.5, hz), 0.2, "mast_dark", segments=6, rings=4)


def barrel(p, base, s=1.0):
    x, y, z = base
    p.cylinder((x, y + 0.75 * s, z), 0.7 * s, 1.5 * s, "barrel", segments=10)
    p.cylinder((x, y + 0.75 * s, z), 0.78 * s, 0.6 * s, "barrel", segments=10)
    for dy in (0.25, 1.25):
        p.cylinder((x, y + dy * s, z), 0.76 * s, 0.14 * s, "iron", segments=10)


def aether_crystal(trim, glow):
    trim.torus((0, -22.2, 0), 2.6, 0.32, "brass", segments=16, sides=5)
    for k in range(4):
        a = math.radians(45 + k * 90)
        P.rod(trim, (math.cos(a) * 2.6, -22.2, math.sin(a) * 2.6), (math.cos(a) * 1.4, -20.8, math.sin(a) * 1.4),
              0.22, "brass", segments=5)
    P.crystal(glow, (0, -21.5, 0), (0, -31.0, 0), 1.6, "aether")
    for dx, dz, ang, ln in ((-1.6, 0.6, -25, 5.0), (1.5, -0.4, 22, 5.5), (0.3, 1.4, 8, 3.6), (-0.6, -1.4, -10, 4.0)):
        a = math.radians(ang)
        base = (dx, -22.0, dz)
        tip = (dx + math.sin(a) * ln, -22.0 - math.cos(a) * ln, dz)
        P.crystal(glow, base, tip, 0.7, "aether")


# Scenery -----------------------------------------------------------------------


def gull(p, center, s):
    x, y, z = center
    for side in (-1, 1):
        wing = [(0, 0), (side * 1.2 * s, 0.55 * s), (side * 2.4 * s, 0.25 * s), (side * 1.2 * s, 0.25 * s)]
        p.prism([(x + a, y + b) for a, b in wing], 0.2 * s, "gull", center=(0, 0, z))
        p.prism([(x + side * 2.4 * s, y + 0.25 * s), (x + side * 1.9 * s, y + 0.45 * s),
                 (x + side * 1.8 * s, y + 0.3 * s)], 0.22 * s, "gull_tip", center=(0, 0, z))


def scenery_near(p):
    rng = P.seeded(11)
    for c, s in (((-56, -27, -26), 8.5), ((60, -31, -30), 9.5), ((-22, -40, -44), 11.0), ((28, -44, -52), 10.0),
                 ((-64, 34, -42), 6.5), ((54, 41, -48), 7.0)):
        P.cloud(p, c, s, "cloud", rng, puffs=5, segments=12, rings=8)
    for c, s in (((-36, 41, -22), 1.4), ((-29, 43.5, -24), 1.1), ((-42, 45, -26), 1.0), ((47, 26, -20), 1.2),
                 ((52, 29, -24), 0.9)):
        gull(p, c, s)


def scenery_far(p, clouds):
    rng = P.seeded(29)
    near_cols = ("grass", "grass_dark", "rock", "rock_dark")
    far_cols = ("far_grass", "far_grass_dark", "far_rock", "far_rock_dark")

    def tree_near(pp, base, s):
        P.round_tree(pp, base, s * 0.9, "trunk", "leaves", "leaves_dark", rng)

    def tree_far(pp, base, s):
        P.round_tree(pp, base, s * 0.8, "trunk", "far_leaves", "far_grass_dark", rng)

    def tree_blossom(pp, base, s):
        P.round_tree(pp, base, s * 0.85, "trunk", "blossom", "leaves_dark", rng)

    shades = {near_cols: ("rock", "rock_dark", "rock_deep"), far_cols: ("far_rock", "far_rock_dark", "far_rock_deep")}
    for c, s, cols, tree in (
        ((-72, 52, -110), 17, near_cols, tree_near),
        ((78, 60, -150), 15, far_cols, tree_far),
        ((88, -28, -120), 24, near_cols, tree_blossom),
        ((-86, -32, -100), 19, near_cols, tree_near),
        ((-128, 14, -165), 22, far_cols, tree_far),
        ((118, 22, -150), 26, far_cols, tree_far),
        ((-38, 66, -170), 10, far_cols, None),
        ((150, -40, -195), 20, far_cols, None),
        ((-160, 52, -195), 16, far_cols, tree_far),
        ((30, -62, -150), 13, far_cols, None),
    ):
        P.floating_island(p, c, s, cols, rng, tree=tree, shade=shades[cols])
    # cloud sea under everything
    for i in range(9):
        x = -170 + i * 42 + rng.uniform(-8, 8)
        P.cloud(clouds, (x, -58 + rng.uniform(-4, 4), -140 + rng.uniform(-25, 25)), rng.uniform(14, 20), "cloud_far",
                rng, puffs=4, segments=9, rings=6)
    for c, s in (((-120, 62, -185), 12), ((128, 66, -190), 13), ((10, 72, -200), 11), ((-10, -64, -100), 14)):
        P.cloud(clouds, c, s, "cloud_warm", rng, puffs=4, segments=9, rings=6)
    distant_airship(p, (-64, 46, -160), 1.0)


def distant_airship(p, c, s):
    x, y, z = c
    p.sphere((x, y + 4.2 * s, z), (8.0 * s, 2.8 * s, 2.8 * s), "balloon_far", segments=14, rings=8)
    p.torus((x, y + 4.2 * s, z), 2.85 * s, 0.25 * s, "sail", rotation=(0, 0, 90), segments=12, sides=4)
    p.box((x, y, z), (7.0 * s, 1.4 * s, 2.0 * s), "ship_far", bevel=0.5 * s, taper=(1.2, 1.1))
    p.cone((x - 4.2 * s, y + 0.1 * s, z), 0.8 * s, 2.0 * s, "ship_far", rotation=(0, 0, 90), segments=6)
    for dx in (-2.5, 2.5):
        P.rod(p, (x + dx * s, y + 0.6 * s, z), (x + dx * 1.2 * s, y + 1.8 * s, z), 0.12 * s, "rope", segments=4)
    p.box((x + 4.6 * s, y + 0.5 * s, z), (0.3 * s, 2.2 * s, 0.3 * s), "iron", bevel=0)


def model(mb):
    stage = mb.piece("Stage")
    trim = mb.piece("StageTrim")
    plat = mb.piece("Platforms")
    rig = mb.piece("Rigging")
    glow = mb.piece("GlowLights")
    hull(stage, trim, glow)
    quarterdeck(stage, trim, glow)
    deck_props(mb.piece("Deck"), glow)
    bow_and_stern(stage, trim, glow, rig)
    aether_crystal(trim, glow)
    rigging(rig, mb.piece("Sails"), plat, glow)
    scenery_near(mb.piece("SceneryNear"))
    scenery_far(mb.piece("SceneryFar"), mb.piece("SceneryClouds"))
