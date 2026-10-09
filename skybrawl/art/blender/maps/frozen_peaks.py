"""
FrozenPeaks ("Frozen peaks"): a snowy mountaintop broken off and floating in a
cold twilight sky.

The stage is a slab of icy blue rock capped with snow, with a raised rock step
on the left. Behind the lane a great ice arch springs from the summit: the two
ice shelves grow out of its legs and the bridge platform sits on its crown.
Snowy peaks rise behind on both sides; a frozen waterfall spills off the right
one past the island's edge. Glowing ice crystals grow along the back and
hang from the island's root.
"""

import math

from . import _props_a as P

MAP_ID = "FrozenPeaks"
SKY = ("#3b4f9a", "#c9d8f5")

PLATFORMS = [
    (-34, -14, 34, 0, False),  # snowy cliff
    (-34, 0, -24, 5, False),  # raised rock step
    (-22, 12, -8, 13, True),  # left ice shelf
    (8, 12, 22, 13, True),  # right ice shelf
    (-6, 22, 6, 23, True),  # frozen arch / bridge top
]

COLORS = {
    "snow": "#f4f8ff",
    "snow_shade": "#d6e3f6",
    "rock_light": "#7fa0da",
    "rock": "#6384c5",
    "rock_dark": "#4b67a7",
    "rock_deep": "#394f89",
    "ice": "#9fe0f2",
    "ice_light": "#d6f6ff",
    "ice_deep": "#66bde0",
    "crystal": "#7af4ff",
    "crystal_violet": "#c6a8ff",
    "pine": "#2f7569",
    "pine_dark": "#235b53",
    "trunk": "#6e4b3a",
    "mid_rock": "#7b93d0",
    "mid_rock_dark": "#6779bb",
    "mid_rock_deep": "#5869aa",
    "mid_snow": "#e9f0ff",
    "far_rock": "#8a9bd2",
    "far_rock_dark": "#7587c5",
    "far_rock_deep": "#6677b8",
    "far_snow": "#d3defa",
    "far_snow_shade": "#b8c7ea",
    "cloud": "#eef3ff",
    "cloud_far": "#dde5fa",
    "fall": "#bdeefc",
    "fall_light": "#effcff",
}

W0 = 8.5  # half depth of the island top along z
ROCK_HI = ("rock_light", "rock", "rock_dark")
ROCK_LO = ("rock", "rock_dark", "rock_deep")
ICE = ("ice_light", "ice", "ice_deep")
SNOW = ("snow", "snow_shade", "snow_shade")
FAR_ROCK = ("far_rock", "far_rock_dark", "far_rock_deep")
FAR_SNOW = ("far_snow", "far_snow_shade", "far_snow_shade")
MID_ROCK = ("mid_rock", "mid_rock_dark", "mid_rock_deep")
ARCH_Z = -8.0
ARCH_A, ARCH_B = 25.5, 20.5  # arch centerline radii (x, y)

LEFT = [(-46.0, -0.6), (-42.0, -4.0), (-37.0, -9.0), (-32.0, -14.5), (-27.0, -20.0), (-22.0, -26.0),
        (-17.5, -31.2), (-14.0, -34.2), (-11.0, -34.3), (-7.0, -34.35), (-3.0, -34.3), (0.0, -34.3),
        (6.0, -34.3)]
RIGHT = [(-46.0, 1.2), (-42.0, 4.6), (-37.0, 9.8), (-32.0, 15.2), (-27.0, 21.0), (-22.0, 26.8),
         (-17.5, 31.8), (-14.0, 34.2), (-11.0, 34.3), (-7.0, 34.35), (-3.0, 34.3), (0.0, 34.3),
         (6.0, 34.3)]


def x_left(y):
    return P.catmull(LEFT, y)


def x_right(y):
    return P.catmull(RIGHT, y)


def half_depth(y):
    if y >= -14:
        return W0 - 0.02 * -y
    f = min((-y - 14) / 33.0, 1.0)
    return (W0 - 0.28) * math.sqrt(max(1 - f ** 1.6, 0.0)) + 0.4


def plan(x, y, xl=None, xr=None, rl=6.0):
    """Rounded ends in plan view (over a length rl at each end)."""
    xl = x_left(y) if xl is None else xl
    xr = x_right(y) if xr is None else xr
    u = min(max(min(x - xl, xr - x) / rl, 0.0), 1.0)
    return 0.45 + 0.55 * math.sqrt(u)


def linspace(a, b, n):
    return [a + (b - a) * i / n for i in range(n + 1)]


# Island ----------------------------------------------------------------------


def rock_band(p, ya, yb, color, rng, wa=None, wb=None, xr_a=None, xr_b=None, nu=18, jit=0.55, step=0.25,
              xl_a=None, xl_b=None, rl=6.0):
    """One stratum of the island: a faceted slab between heights ya > yb."""
    wa = half_depth(ya) if wa is None else wa
    wb = half_depth(yb) + step if wb is None else wb
    xa0, xa1 = (x_left(ya) if xl_a is None else xl_a), (x_right(ya) if xr_a is None else xr_a)
    xb0, xb1 = (x_left(yb) if xl_b is None else xl_b), (x_right(yb) if xr_b is None else xr_b)
    rings = []
    for i in range(nu + 1):
        u = i / nu
        inner = 0 < i < nu
        xt = xa0 + (xa1 - xa0) * u + (rng.uniform(-0.5, 0.5) if inner else 0.0)
        xb = xb0 + (xb1 - xb0) * u + (rng.uniform(-0.8, 0.8) if inner else 0.0)
        yj = yb + (rng.uniform(-0.45, 0.45) if inner else 0.0)
        ft = wa * plan(xt, ya, xa0, xa1, rl) + (rng.uniform(-jit, jit) * 0.4 if inner else 0.0)
        fb = wb * plan(xb, yb, xb0, xb1, rl) + (rng.uniform(-jit, jit) if inner else 0.0)
        bt = wa * plan(xt, ya, xa0, xa1, rl)
        bb = wb * plan(xb, yb, xb0, xb1, rl)
        rings.append([(xt, ya, ft), (xb, yj, fb), (xb, yj, -bb), (xt, ya, -bt)])
    P.loft_rings(p, rings, color)
    return rings


def icicle(p, top, length, radius, color="ice_light"):
    x, y, z = top
    p.cone((x, y - length / 2, z), radius, length, color, rotation=(180, 0, 0), segments=5)


def snow_slab(p, y_top, x0, x1, hw, thick=0.7, over=0.3, nu=24, xl=None, xr=None, rl=6.0):
    rings = []
    for x in linspace(x0, x1, nu):
        f = hw * plan(x, 0.0, xl if xl is not None else x0, xr if xr is not None else x1, rl) + over
        rings.append([(x, y_top, f), (x, y_top - thick, f), (x, y_top - thick, -f), (x, y_top, -f)])
    P.loft_rings(p, rings, "snow")


def snow_lip(p, y_top, x0, x1, z_of, rng, step=2.2, x_min=-1e9, x_max=1e9):
    """Rounded snow drips along a front edge; tops stay within 0.1 of y_top and
    never reach past x_min / x_max (the platform ends + 0.4)."""
    n = max(2, round((x1 - x0) / step))
    for i in range(n):
        x = x0 + (i + 0.5) * (x1 - x0) / n + rng.uniform(-0.3, 0.3)
        rx = (x1 - x0) / n * rng.uniform(0.5, 0.95)
        rx = max(0.4, min(rx, x_max - x, x - x_min))
        ry = rng.uniform(0.6, 1.25)
        p.sphere((x, y_top + 0.08 - ry, z_of(x) + 0.05), (rx, ry, 0.55), "snow", segments=10, rings=6)


def cliff_wall(p, x0, x1, y_top, y_bot, rng, shade, nx=10, ny=3, disp=1.1, hw=W0, rl=4.0, back=None):
    """Faceted slab: a coarse triangulated front with chiselled facets whose
    tones are baked from their normals; flat top, back and ends."""
    back = hw if back is None else back
    xs = linspace(x0, x1, nx)
    ys = linspace(y_top, y_bot, ny)
    verts, grid = [], []
    for i, x in enumerate(xs):
        col = []
        for j, y in enumerate(ys):
            inner_x, inner_y = 0 < i < nx, 0 < j < ny
            jx = rng.uniform(-1.4, 1.4) if inner_x else 0.0
            jy = rng.uniform(-0.7, 0.7) if inner_y else 0.0
            if inner_x and inner_y:
                jz = rng.uniform(-disp, disp * 0.5)
            elif inner_x or inner_y:
                jz = rng.uniform(-disp * 0.5, 0.0)
            else:
                jz = 0.0
            if j == 0:
                jz = min(jz, 0.0) - 0.05  # top edge tucked under the snow
            xx = x + jx
            col.append(len(verts))
            verts.append((xx, y + jy, hw * plan(xx, 0.0, x0, x1, rl) + jz))
        grid.append(col)
    backs = []
    for x in xs:
        bz = -back * plan(x, 0.0, x0, x1, rl)
        backs.append((len(verts), len(verts) + 1))
        verts += [(x, y_top, bz), (x, y_bot, bz)]
    faces = []
    for i in range(nx):
        for j in range(ny):
            a, b, c, d = grid[i][j], grid[i + 1][j], grid[i + 1][j + 1], grid[i][j + 1]
            faces += [(a, b, c), (a, c, d)] if (i + j) % 2 == 0 else [(a, b, d), (b, c, d)]
        faces.append((grid[i][0], backs[i][0], backs[i + 1][0], grid[i + 1][0]))
        faces.append((grid[i][ny], grid[i + 1][ny], backs[i + 1][1], backs[i][1]))
        faces.append((backs[i][0], backs[i][1], backs[i + 1][1], backs[i + 1][0]))
    faces.append(tuple([grid[0][j] for j in range(ny + 1)] + [backs[0][1], backs[0][0]]))
    faces.append(tuple([backs[nx][0], backs[nx][1]] + [grid[nx][j] for j in reversed(range(ny + 1))]))
    P.mesh(p, verts, faces, shade[1], shade=shade)


def underside(stage, trim, glow, rng):
    """Jagged inverted spires under the cliff, with icicles and crystals."""
    spires = [(-29.0, 0.5, 6.0, 9.0, "rock"), (-20.5, -0.5, 8.0, 14.0, "rock_dark"), (-10.0, 0.8, 9.0, 20.0, "rock"),
              (0.5, -0.4, 10.5, 27.0, "rock_dark"), (11.0, 0.6, 9.0, 19.0, "rock"), (21.0, -0.6, 8.0, 13.0, "rock_dark"),
              (29.5, 0.4, 6.0, 8.5, "rock"), (-15.0, -3.0, 7.0, 16.0, "rock_deep"), (6.0, -3.0, 8.0, 22.0, "rock_deep"),
              (16.0, -3.5, 6.5, 14.0, "rock_deep"), (-4.0, -2.0, 6.0, 17.0, "rock_dark")]
    tips = []
    for x, z, r, ln, color in spires:
        prof = [(0.8, r), (-ln * 0.3, r * 0.74), (-ln * 0.62, r * 0.38), (-ln, 0.0)]
        P.lathe(stage, (x, -14.2, z), prof, color, 7, 0.22, P.seeded(int(x * 11 + ln)), rng.uniform(0, 50), 0.72,
                shade=ROCK_LO if color != "rock_deep" else ("rock_dark", "rock_deep", "rock_deep"))
        tips.append((x, z, r, ln))
    for x, z, r, ln in tips:
        if z < -1:
            continue
        for k in range(3):
            t = rng.uniform(0.15, 0.7)
            y = -14.2 - ln * t
            rr = r * (1 - t) * 0.8
            xx = x + rng.choice((-1, 1)) * rr * rng.uniform(0.3, 0.8)
            icicle(trim, (xx, y, z + rr * 0.62), rng.uniform(1.5, 4.0), rng.uniform(0.3, 0.5))
    for x, y, s, c, d in ((-17.0, -19.0, 2.4, "crystal", (-0.6, -0.6, 0.5)),
                          (15.5, -21.0, 2.2, "crystal_violet", (0.6, -0.6, 0.5)),
                          (-5.0, -27.0, 2.6, "crystal_violet", (-0.4, -0.8, 0.4)),
                          (6.5, -31.0, 2.0, "crystal", (0.4, -0.8, 0.4))):
        P.crystal_cluster(glow, (x, y, 3.2), s, c, P.seeded(int(x * 13 + y)), count=3, direction=d, spread=25)
    P.crystal_cluster(glow, (0.5, -39.0, -0.4), 6.0, "crystal", P.seeded(9), count=5, direction=(0, -1, 0),
                      spread=28)


def island(stage, trim, glow, rng):
    # chiselled cliff: upper rock, a frozen vein, lower rock (front covers y 0..-14 over x -34..34)
    cliff_wall(stage, -34.3, 34.3, -0.4, -7.2, rng, ROCK_HI, nx=11, ny=2)
    cliff_wall(stage, -34.3, 34.3, -7.0, -8.3, rng, ICE, nx=12, ny=1, disp=0.3, hw=W0 + 0.2)
    cliff_wall(stage, -34.3, 34.3, -8.1, -15.2, rng, ROCK_LO, nx=11, ny=2, hw=W0 - 0.1)
    underside(stage, trim, glow, rng)
    # small icicles along the snow lip and under the frozen vein
    for x in linspace(-23.0, 32.0, 22):
        if rng.random() < 0.6:
            x += rng.uniform(-0.8, 0.8)
            icicle(trim, (x, -1.0, W0 * plan(x, 0.0, -34.4, 34.4) - 0.1), rng.uniform(0.9, 2.2),
                   rng.uniform(0.22, 0.36))
    for x in linspace(-31.0, 31.0, 14):
        if rng.random() < 0.7:
            x += rng.uniform(-1.0, 1.0)
            icicle(trim, (x, -8.1, (W0 + 0.2) * plan(x, 0.0, -34.3, 34.3, 4.0) - 0.15), rng.uniform(0.8, 1.8),
                   rng.uniform(0.25, 0.4), "ice")

    # snow cap: main top exactly at y = 0, step top exactly at y = 5
    snow_slab(trim, 0.0, -24.6, 34.4, W0, xl=-34.4, xr=34.4, rl=4.0, nu=22)  # starts at the step's right wall
    snow_lip(trim, 0.0, -24.0, 34.0, lambda x: W0 * plan(x, 0.0, -34.4, 34.4, 4.0) + 0.3, rng, x_max=34.4)
    cliff_wall(stage, -34.3, -24.0, 4.6, -0.6, P.seeded(17), ROCK_HI, nx=3, ny=2, disp=0.9, hw=W0 - 0.1, rl=2.0)
    snow_slab(trim, 5.0, -34.4, -23.9, W0 - 0.1, xl=-34.4, xr=-23.9, nu=10, rl=2.0)
    snow_lip(trim, 5.0, -34.0, -24.2, lambda x: (W0 - 0.1) * plan(x, 0.0, -34.4, -23.9, 2.0) + 0.3, rng,
             step=2.0, x_min=-34.4, x_max=-23.6)

    # glowing crystals in the cliff face (below the walkable top)
    for x, y, s, c, d in ((-16.5, -10.5, 2.6, "crystal", (-0.6, 0.5, 0.6)),
                          (25.0, -11.5, 2.4, "crystal_violet", (0.6, 0.5, 0.6)),
                          (4.5, -4.8, 2.0, "crystal", (-0.5, 0.6, 0.6))):
        zf = W0 * plan(x, 0.0, -34.4, 34.4, 4.0) - 0.9
        P.crystal_cluster(glow, (x, y, zf), s, c, P.seeded(int(x * 13 + y)), count=3, direction=d, spread=25)


# Ice arch and soft platforms ---------------------------------------------------


def arch_point(t):
    a = math.pi * t
    return (ARCH_A * math.cos(a), ARCH_B * math.sin(a), ARCH_Z)


def ice_arch(p, trim, glow, rng):
    n = 22
    ts = [-0.06 + 1.12 * i / n for i in range(n + 1)]
    path = [arch_point(t) for t in ts]  # right foot, over the crown, to the left foot
    P.sweep(p, path, P.rect(1.5, 1.5, 2.0, -2.0), "ice", up=(0, 0, 1), shade=ICE)
    # lighter frosty crust on the crown and down the shoulders
    crown = [arch_point(t) for t in linspace(0.2, 0.8, 14)]
    P.sweep(trim, crown, P.rect(1.85, -1.3, 1.6, -2.15), "ice_light", up=(0, 0, 1))
    top = [arch_point(t) for t in linspace(0.36, 0.64, 8)]
    P.sweep(trim, top, P.rect(2.1, -1.65, 1.2, -1.6), "snow", up=(0, 0, 1))
    # icicles under the inner curve
    for t in linspace(0.18, 0.82, 16):
        x, y, z = arch_point(t)
        a = math.pi * t
        nx, ny = math.cos(a) * ARCH_B, math.sin(a) * ARCH_A
        ln_ = math.hypot(nx, ny)
        ix, iy = x - nx / ln_ * 1.5, y - ny / ln_ * 1.5
        if rng.random() < 0.8:
            icicle(trim, (ix, iy + 0.2, z + rng.uniform(-1.2, 1.4)), rng.uniform(1.2, 3.6) * (1.3 if 0.35 < t < 0.65
                                                                                                else 0.8),
                   rng.uniform(0.25, 0.45))
    # crystals at the feet
    for x in (-ARCH_A, ARCH_A):
        P.crystal_cluster(glow, (x + (1.8 if x < 0 else -1.8), 5.2 if x < 0 else 0.2, ARCH_Z + 1.4), 3.2,
                          "crystal_violet" if x < 0 else "crystal", P.seeded(int(x + 40)), count=4,
                          direction=(0.3 if x < 0 else -0.3, 1, 0.2))


def ice_shelf(plat, x1, y2, x2, rng, z_front=2.6, z_back=-5.4, side=1):
    """Thin jagged ice slab, walkable top exactly at y2 over x1..x2."""
    n = 9
    front = []
    for i in range(n + 1):
        x = x1 + (x2 - x1) * i / n
        z = z_front + (0.0 if i in (0, n) else rng.uniform(-0.7, 0.5))
        front.append((x, z))
    back = [(x2, z_back), (x1 + (x2 - x1) * 0.5, z_back - 0.6), (x1, z_back)]
    outline = [(x, -z) for x, z in front] + [(x, -z) for x, z in back]
    # prism outline lives in local XY; rotate so local y -> arena z (sign flipped above)
    plat.prism([(x, z) for x, z in outline], 0.6, "ice_light", center=(0, y2 - 0.3, 0), rotation=(-90, 0, 0))
    inner = [(x1 + 0.5, -(z_front - 0.5)), (x2 - 0.5, -(z_front - 0.4)), (x2 - 0.7, -(z_back + 0.4)),
             (x1 + 0.7, -(z_back + 0.4))]
    plat.prism(inner, 0.55, "ice", center=(0, y2 - 0.85, 0), rotation=(-90, 0, 0))
    for x, z in front[1:-1]:
        if rng.random() < 0.55:
            icicle(plat, (x + rng.uniform(-0.3, 0.3), y2 - 0.9, z - 0.45), rng.uniform(0.8, 1.9),
                   rng.uniform(0.2, 0.32), "ice")


def platforms(plat, trim, glow, rng):
    ice_shelf(plat, -22.0, 13.0, -8.0, rng)
    ice_shelf(plat, 8.0, 13.0, 22.0, rng)
    # brackets from the shelves back to the arch legs
    for x in (-19.5, 19.5):
        P.lathe(plat, (x, 12.2, -6.2), [(0.0, 1.4), (-2.8, 0.0)], "ice", 6, 0.15, P.seeded(int(x + 3)), 0, 1.0,
                lean=(0.0, -0.5))
    # bridge slab on the arch crown: snow skin over ice
    plat.prism([(-6.0, -2.5), (6.0, -2.5), (6.0, 5.6), (-6.0, 5.6)], 0.4, "snow", center=(0, 22.8, 0),
               rotation=(-90, 0, 0), bevel=0.06)
    outline = [(-5.8, -2.3), (-3.0, -2.9), (0.4, -2.2), (3.4, -2.8), (5.8, -2.3), (5.6, 5.6), (-5.6, 5.6)]
    plat.prism(outline, 0.62, "ice", center=(0, 22.29, 0), rotation=(-90, 0, 0))
    for x in (-4.6, -1.2, 2.0, 4.4):
        icicle(plat, (x, 22.0, 2.2), rng.uniform(1.0, 2.2), rng.uniform(0.25, 0.4), "ice_light")


# Behind the lane ---------------------------------------------------------------


def peak(p, base, height, radius, rng, depth=0.5, snow_from=0.55, segments=7, rock=ROCK_LO, snow=SNOW,
         drip=0.14):
    """Faceted mountain with a snow cap whose lower edge zigzags in drips."""
    bx, by, bz = base
    prof = [(height, 0.0), (height * 0.8, radius * 0.24), (height * 0.55, radius * 0.5),
            (height * 0.3, radius * 0.75), (0.0, radius)]
    spokes = [1.0 + rng.uniform(-0.16, 0.16) for _ in range(segments)]
    spin = rng.uniform(0, 360)

    def rock_r(hh):
        pts = list(reversed(prof))
        for (h0, r0), (h1, r1) in zip(pts, pts[1:]):
            if h0 <= hh <= h1:
                return r0 + (r1 - r0) * (hh - h0) / (h1 - h0)
        return 0.0

    def pt(k, hh, grow=0.0):
        a = 2 * math.pi * k / segments + math.radians(spin)
        r = rock_r(hh) * spokes[k % segments] * (1 + grow) + (0.3 if grow else 0.0)
        return (bx + math.cos(a) * r, by + hh, bz + math.sin(a) * r * depth)

    def skin(rings_h, shade, grow, tip_h):
        verts = [(bx, by + tip_h, bz)]
        rings = []
        for hs in rings_h:
            ring = []
            for k in range(segments):
                ring.append(len(verts))
                verts.append(pt(k, hs[k] if isinstance(hs, list) else hs, grow))
            rings.append(ring)
        faces = [(0, rings[0][k], rings[0][(k + 1) % segments]) for k in range(segments)]
        for r0, r1 in zip(rings, rings[1:]):
            for k in range(segments):
                j = (k + 1) % segments
                faces.append((r0[k], r0[j], r1[j], r1[k]))
        faces.append(tuple(reversed(rings[-1])))
        P.mesh(p, verts, faces, shade[1], shade=shade)

    skin([height * 0.8, height * 0.55, height * 0.3, 0.0], rock, 0.0, height)
    cut = height * snow_from
    edge = [cut - (height * drip * rng.uniform(0.5, 1.0) if k % 2 == 0 else rng.uniform(-0.02, 0.03) * height)
            for k in range(segments)]
    skin([height * 0.8, (height * 0.8 + cut) / 2, edge], snow, 0.07, height + 0.4)


def backdrop(near, glow, rng):
    # left and right summits, a low snowy ridge between them
    peak(near, (-40.0, -3.0, -27.0), 34.0, 16.0, rng, rock=("rock", "rock_dark", "rock_deep"), snow_from=0.5)
    peak(near, (-58.0, -6.0, -42.0), 28.0, 15.0, rng, rock=("rock_dark", "rock_deep", "rock_deep"),
         snow=("snow_shade", "snow_shade", "far_snow_shade"), snow_from=0.45)
    peak(near, (38.0, -3.0, -28.0), 40.0, 17.0, rng, rock=("rock", "rock_dark", "rock_deep"), snow_from=0.52)
    peak(near, (60.0, -6.0, -44.0), 30.0, 15.0, rng, rock=("rock_dark", "rock_deep", "rock_deep"),
         snow=("snow_shade", "snow_shade", "far_snow_shade"), snow_from=0.45)
    P.lathe(near, (0.0, -6.0, -21.0), [(9.0, 0.0), (7.5, 7.0), (4.5, 15.0), (0.0, 26.0)], "snow_shade", 9, 0.12,
            P.seeded(4), 0, 0.42)
    P.lathe(near, (-15.0, -6.0, -16.0), [(8.0, 0.0), (5.5, 6.0), (0.0, 13.0)], "snow", 7, 0.15, P.seeded(6), 0, 0.5)
    P.lathe(near, (17.0, -6.0, -16.0), [(7.0, 0.0), (4.5, 6.0), (0.0, 12.0)], "snow", 7, 0.15, P.seeded(7), 0, 0.5)
    # glowing crystal clusters along the back edge, among the boulders
    for x, y, z, sz, c in ((-30.5, 4.7, -7.8, 3.2, "crystal_violet"), (-18.4, -0.3, -8.5, 3.6, "crystal"),
                           (2.0, -0.3, -9.2, 2.8, "crystal_violet"), (13.6, -0.3, -8.7, 3.4, "crystal"),
                           (30.5, -0.3, -8.2, 2.6, "crystal_violet")):
        P.crystal_cluster(glow, (x, y, z), sz, c, P.seeded(int(x * 17 + 300)), count=4,
                          direction=(0.15 if x < 0 else -0.15, 1.0, -0.25), spread=30)
    # boulders and snow drifts along the back edge
    for x, z, s in ((-20.0, -7.6, 1.6), (-3.5, -8.0, 1.2), (12.0, -7.8, 1.4), (27.5, -7.4, 1.8)):
        P.lathe(near, (x, -0.3, z), [(s * 1.1, 0.0), (s * 0.6, s * 1.0), (0.0, s * 1.2)], "rock_light", 6, 0.25,
                P.seeded(int(x * 3 + 50)), 20, 0.8, shade=ROCK_HI)
        near.sphere((x + 0.2, s * 0.95, z), (s * 0.85, s * 0.35, s * 0.75), "snow", segments=8, rings=5)


def pines(p, rng):
    for x, y, z, h in ((-22.0, 0.0, -10.5, 9.0), (-17.0, 1.0, -13.5, 12.5), (-29.0, 5.0, -11.5, 8.0),
                       (-34.0, 5.5, -14.5, 11.0), (-44.0, 6.0, -18.0, 9.5), (-9.0, 2.0, -17.5, 7.0),
                       (10.0, 2.0, -17.0, 7.5), (17.0, 0.5, -11.5, 8.5), (23.5, 0.5, -13.5, 12.0),
                       (29.5, 0.0, -10.5, 7.0), (31.5, 1.0, -16.0, 10.0), (46.0, 4.0, -20.0, 9.0)):
        P.pine(p, (x, y - 0.6, z), h, "pine", "pine_dark", "snow", "trunk", tiers=3)


def fall_sheet(p, trim, spine, rows, cols, y0, y1, rng, wave=0.8):
    """One frozen cascade: a gently curved sheet following `spine` (y, x, z, w)
    with wavy edges, bright streaks and an icicle fringe."""
    def at(y):
        for (ya, xa, za, wa), (yb, xb, zb, wb) in zip(spine, spine[1:]):
            if yb <= y <= ya:
                t = (ya - y) / (ya - yb)
                return xa + (xb - xa) * t, za + (zb - za) * t, wa + (wb - wa) * t
        return spine[-1][1:]

    grid = []
    for r in range(rows + 1):
        y = y0 - (y0 - y1) * r / rows
        cx, cz, w = at(y)
        left = cx - w / 2 + wave * math.sin(y * 0.31)
        right = cx + w / 2 + wave * math.sin(y * 0.27 + 1.3)
        row = []
        for c in range(cols + 1):
            u = c / cols
            row.append((left + (right - left) * u, y, cz + 0.7 * math.sin(math.pi * u) + 0.25 * math.sin(u * 13 + y * 0.3)))
        grid.append(row)
    P.shell(p, grid, 0.6, "fall")
    for u0 in [0.15 + 0.7 * k / max(cols // 2 - 1, 1) for k in range(cols // 2)]:
        stop = y1 + (y0 - y1) * rng.uniform(0.0, 0.45)
        pts = []
        for row in grid:
            if row[0][1] < stop:
                break
            c = u0 * cols
            i = int(c)
            f = c - i
            a, b = row[i], row[min(i + 1, cols)]
            pts.append((a[0] + (b[0] - a[0]) * f, row[0][1], a[2] + (b[2] - a[2]) * f + 0.3))
        if len(pts) > 2:
            P.sweep(trim, pts, P.rect(0.3, 0.3, 0.15, -0.15), "fall_light", up=(0, 0, 1))
    for c in range(cols + 1):
        x, y, z = grid[-1][c]
        icicle(trim, (x, y + 0.4, z + 0.2), rng.uniform(1.5, 6.0) * (1.0 if c % 2 else 0.55),
               rng.uniform(0.4, 0.75), "fall")
    return grid


def frozen_waterfall(p, trim, glow, rng):
    """A frozen cascade from under the right summit's snow cap, spilling past
    the island's right end, with a thinner side fall further right. The spines
    keep each sheet just in front of the summit's rock face."""
    fall_sheet(p, trim, [(19.5, 38.4, -23.6, 6.0), (10.0, 39.0, -21.0, 8.0), (0.0, 39.6, -18.4, 9.6),
                         (-14.0, 40.0, -16.6, 10.0), (-32.0, 40.2, -16.0, 8.6)], 16, 10, 19.5, -32.0, rng)
    fall_sheet(p, trim, [(12.0, 45.8, -23.2, 2.4), (0.0, 46.4, -21.0, 3.2), (-20.0, 46.8, -19.8, 3.6)], 9, 4,
               12.0, -20.0, rng, wave=0.4)
    trim.sphere((45.8, 12.2, -22.9), (1.9, 0.6, 0.9), "snow", segments=8, rings=5)
    P.crystal_cluster(glow, (34.8, 0.2, -11.5), 3.0, "crystal", P.seeded(77), count=4, direction=(0.2, 1, 0.3))


# Far scenery ---------------------------------------------------------------------


def far_scenery(far, clouds, rng):
    # distant snowy range along the horizon
    for x, z, h, r in ((-170, -200, 62, 46), (-112, -190, 78, 50), (-52, -205, 66, 50), (8, -195, 84, 54),
                       (66, -200, 70, 50), (126, -190, 82, 52), (182, -205, 64, 46), (-142, -160, 44, 30),
                       (98, -158, 48, 32)):
        peak(far, (x, -66.0, z), h, r, rng, depth=0.5, snow_from=0.6, segments=6, rock=FAR_ROCK, snow=FAR_SNOW)
    # floating icy islands
    ice_cols = ("snow", "snow_shade", "mid_rock", "mid_rock_dark")

    def tree(pp, base, s):
        P.pine(pp, base, s * 0.55, "pine", "pine_dark", "snow", "trunk", tiers=2, segments=6)

    for c, s, t in (((-64, 38, -95), 14, True), ((70, 44, -110), 18, True), ((-92, -14, -120), 20, True),
                    ((98, -4, -135), 16, False), ((-30, 56, -150), 10, False), ((40, -40, -100), 12, False),
                    ((-130, 34, -170), 14, True), ((140, 30, -175), 12, False)):
        P.floating_island(far, c, s, ice_cols, rng, tree=tree if t else None, segments=8, shade=MID_ROCK)
        x, y, z = c
        for k in range(3):
            P.lathe(far, (x + (k - 1) * s * 0.22, y - s * 0.55, z + s * 0.2), [(0.0, s * 0.05), (-s * 0.3, 0.0)],
                    "ice", 5, 0.1, P.seeded(k + int(x)))
    # cloud banks
    for i in range(8):
        x = -175 + i * 50 + rng.uniform(-8, 8)
        P.cloud(clouds, (x, -52 + rng.uniform(-4, 4), -130 + rng.uniform(-20, 20)), rng.uniform(13, 19),
                "cloud_far", rng, puffs=4, segments=9, rings=6)
    for c, s in (((-60, 14, -60), 6.5), ((64, 22, -70), 7.5), ((-38, -30, -45), 8.0), ((44, -34, -52), 8.5),
                 ((-110, 58, -160), 11.0), ((112, 62, -165), 11.0)):
        P.cloud(clouds, c, s, "cloud", rng, puffs=5, segments=10, rings=7)


def model(mb):
    rng = P.seeded(2024)
    stage = mb.piece("Stage")
    trim = mb.piece("StageTrim")
    plat = mb.piece("Platforms")
    glow = mb.piece("GlowCrystals")
    island(stage, trim, glow, rng)
    near = mb.piece("SceneryNear")
    arch = mb.piece("Arch")
    ice_arch(arch, arch, glow, rng)
    platforms(plat, trim, glow, rng)
    backdrop(near, glow, rng)
    pines(mb.piece("Pines"), rng)
    frozen_waterfall(mb.piece("Waterfall"), mb.piece("Waterfall"), glow, rng)
    far_scenery(mb.piece("SceneryFar"), mb.piece("SceneryClouds"), rng)
