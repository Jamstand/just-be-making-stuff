"""Yuki, ice psychic who floats. Spear + Bow. Keeps foes at range.

A classic blocky avatar: long straight pale ice-blue hair (a sleek cap with a
softly pointed fringe, flat side locks hanging past the cheeks, and a long
heavy curtain down her back that deepens to icy cyan at the tips), with a
deep-ice snowflake clip over her left temple. Calm half-lidded pale-cyan eyes
with long lashes, a small serene smile and frost sparkles on her cheeks. A
fitted high-collar long coat printed on: a white bodice with a deep-ice
collar and shoulder yoke, a diagonal closure trimmed in snowflakes with
crystal toggles, a deep-blue sash knotted on her right hip whose tails run
down onto the leg, then an ice-blue skirt that splits over white leggings,
frost creeping up from its navy hem; soft white boots with deep-ice cuffs,
ribbon lacing and faintly glowing soles. Three big faceted ice crystals hover
in a fan behind her upper back.

Clearances (checked with anims/posecheck.py): nothing on the head goes below
y 4.1 at the back (the upper back rises into it when she looks around), and
nothing on the head's left side goes below y 4.8 forward of 76 degrees (her
left hand sits there in the spear block). Everything lower rides the hair's
sway chain.
"""

import math

from mathutils import Matrix, Vector

from sky import avatar as A
from sky.avatar import Hair, Style, shade

np = A.np

NAME = "Yuki"

SKIN = "#f8e1d4"
WHITE = "#eef3f9"  # the coat's bodice and sleeves
BODICE_LOW = "#d9e6f3"  # the bodice cools toward the waist
ICE = "#7fc6ec"  # trim, cuffs
SKIRT = "#62b2e8"  # the coat's skirt
ICE_DEEP = "#3a86c8"  # collar, shoulder yoke, boot cuffs
NAVY = "#2b4778"  # piping, hem, soles
SASH = "#3e5aa8"
LEGGING = "#eef2f8"
BOOT = "#fbfdff"
HAIR = "#93cdec"
HAIR_TIP = "#2f9be0"  # the long hair deepens to icy cyan at the tips
IRIS = "#6fd6e8"
LASH = "#26324a"
BROW = "#6f93b8"
FROST = "#62c8ee"
CRYSTAL = "#58c4f0"
SOLE_GLOW = "#9ff4ff"

HEM = 1.0  # the coat's hem on the legs
SPLIT = 0.22  # the skirt opens between x = -SPLIT and SPLIT (world)
KNOT_X = 0.56  # the sash knot, on her right hip
WAIST = (2.14, 2.42)  # the sash
FRINGE = 4.9  # the fringe's lower edge
SIDE = 4.32  # the hair's lower edge over the ears
NAPE = 4.14  # the hair's lower edge at the back of the head
TIPS = 2.36  # the long hair's outer tips (the middle hangs lower)


# Small math helpers (floats or numpy arrays) ----------------------------------------------------


def ramp(x, x0, x1):
    """0 at x0 rising linearly to 1 at x1, clamped."""
    return np.clip((x - x0) / (x1 - x0), 0.0, 1.0)


def sstep(e0, e1, x):
    t = ramp(x, e0, e1)
    return t * t * (3 - 2 * t)


def box(a0, b0, a1, b1):
    return [(a0, b0), (a1, b0), (a1, b1), (a0, b1)]


# Painting helpers ---------------------------------------------------------------------------


def soft(c, color, weight, region=None):
    """Paints `color` over a canvas with a per-pixel opacity: weight(a, b)
    gets numpy arrays of face coordinates and returns 0..1 (soft shadows,
    glows and fades the hard-edged shapes can't do)."""
    a0, b0, a1, b1 = region or c.bounds()
    (x0, y0), (x1, y1) = c.px(a0, b0), c.px(a1, b1)
    win = c._window([x0, x1], [y0, y1])
    if not win:
        return
    X, Y = win[4], win[5]
    ss, r = c.atlas.ss, c.rect
    a = ((X / ss - r.x) / r.w - c.bu) / c.au
    b = ((Y / ss - r.y) / r.h - c.bv) / c.av
    c._put(win, np.clip(weight(a, b), 0.0, 1.0).astype(np.float32), color)


def offset(pts, d):
    """The polyline moved sideways by d (to its left, walking along it)."""
    out = []
    n = len(pts)
    for i, (x, y) in enumerate(pts):
        a, b = pts[max(i - 1, 0)], pts[min(i + 1, n - 1)]
        dx, dy = b[0] - a[0], b[1] - a[1]
        ln = math.hypot(dx, dy) or 1.0
        out.append((x - dy / ln * d, y + dx / ln * d))
    return out


def resample(pts, step):
    """Points every `step` along a polyline."""
    out = []
    run = 0.0
    nxt = step / 2
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        ln = math.hypot(x1 - x0, y1 - y0)
        while nxt <= run + ln:
            t = (nxt - run) / ln
            out.append((x0 + (x1 - x0) * t, y0 + (y1 - y0) * t))
            nxt += step
        run += ln
    return out


def flake(c, x, y, r, color, alpha=1.0, width=None, rotation=90):
    """A six-armed snowflake: spokes with a pair of side branches each."""
    w = width or max(r * 0.17, 0.012)
    for k in range(6):
        a = math.radians(rotation + 60 * k)
        ux, uy = math.cos(a), math.sin(a)
        c.stroke([(x, y), (x + ux * r, y + uy * r)], w, color, alpha, taper=(1.0, 0.55))
        bx, by = x + ux * r * 0.55, y + uy * r * 0.55
        for d in (-1, 1):
            b = a + d * math.radians(52)
            c.stroke([(bx, by), (bx + math.cos(b) * r * 0.36, by + math.sin(b) * r * 0.36)], w * 0.8, color, alpha,
                     taper=(1.0, 0.5))
    c.ellipse(x, y, w * 1.2, w * 1.2, color, alpha)


def sparkle(c, x, y, r, color, alpha=1.0):
    """A four-pointed glint."""
    k = r * 0.22
    c.poly([(x, y + r), (x + k, y + k), (x + r * 0.7, y), (x + k, y - k), (x, y - r), (x - k, y - k),
            (x - r * 0.7, y), (x - k, y + k)], color, alpha)


def frost(c, x0, x1, y, color="#ffffff", alpha=0.32, height=(0.06, 0.2), step=0.06, seed=0, glints=2,
          down=False):
    """Frost creeping from an edge at height y between x0 and x1: two layers
    of translucent, jagged ice spikes (a tall faint one and a short brighter
    one) with a few glints above. `down` grows it downward instead."""
    rng = np.random.default_rng(seed)
    k = -1 if down else 1
    for scale, a in ((1.0, alpha * 0.7), (0.5, alpha * 1.3)):
        pts, x = [(x0, y)], x0
        while x < x1 - 1e-6:
            w = step * rng.uniform(0.6, 1.4) * (0.7 + 0.3 * scale)
            pts.append((min(x + w * rng.uniform(0.35, 0.65), x1), y + k * scale * rng.uniform(*height)))
            x = min(x + w, x1)
            pts.append((x, y + k * scale * rng.uniform(0.0, 0.025)))
        pts.append((x1, y))
        c.poly(pts, color, min(a, 1.0))
    for _ in range(glints):
        sparkle(c, rng.uniform(x0 + 0.05, x1 - 0.05), y + k * rng.uniform(height[1] * 0.8, height[1] * 1.4),
                rng.uniform(0.025, 0.04), color, alpha=min(alpha * 2, 1.0))


def trim(c, pts, width=0.1, color=ICE, flakes=0.0, flake_color="#ffffff", shadow=WHITE):
    """A trimmed edge along a polyline: a band with navy piping, a lit
    stripe and (optionally) little snowflakes every `flakes`."""
    if shadow:
        c.stroke(offset(pts, -width / 2 - 0.02), 0.05, shade(shadow, -0.3), alpha=0.3)
    c.stroke(pts, width, color)
    c.stroke(offset(pts, width * 0.2), width * 0.28, shade(color, 0.3), alpha=0.55)
    for d in (-width / 2, width / 2):
        c.stroke(offset(pts, d), 0.016, NAVY, alpha=0.9)
    if flakes:
        for x, y in resample(pts, flakes):
            flake(c, x, y, width * 0.3, flake_color, alpha=0.95)


def hem_band(faces, y0, y1, color=ICE, flake_color="#ffffff", flakes=0.2, piping=NAVY):
    """A trim band across faces: piping top and bottom, a lit stripe,
    snowflakes along it."""
    for f in faces:
        a0, _, a1, _ = f.bounds()
        f.rect_(a0, y0, a1, y1, color)
        f.rect_(a0, (y0 + y1) / 2, a1, y1 - 0.02, shade(color, 0.25), alpha=0.45)
        f.rect_(a0, y0, a1, y0 + 0.022, piping)
        f.rect_(a0, y1 - 0.018, a1, y1, piping, alpha=0.9)
        if flakes:
            k = a0 + flakes / 2
            while k < a1:
                flake(f, k, (y0 + y1) / 2, (y1 - y0) * 0.3, flake_color)
                k += flakes


def creases(f, y, color, alpha=0.7, spread=0.3, width=0.035):
    """A soft fold line across a face."""
    f.stroke([(-spread, y + 0.02), (0.0, y - 0.02), (spread, y + 0.015)], width, color, alpha, taper=(0.3, 0.6))


# The face ----------------------------------------------------------------------------------------


def calm_eye(c, side, iris, glow=None):
    """A calm, half-lidded anime eye with long lashes: a heavy, flat upper
    lid that cuts the top of a big pale iris, a lid crease above it."""
    s = side
    cx, cy = s * 0.235, 4.6
    w = 0.158
    inner, outer = cx - s * w * 0.92, cx + s * w
    top, bot = [], []
    for i in range(15):
        t = i / 14
        x = inner + (outer - inner) * t
        bump = math.sin(math.pi * t)
        top.append((x, cy - 0.004 + 0.054 * bump ** 0.55 + 0.034 * t))
        bot.append((x, cy - 0.012 - 0.064 * bump ** 1.2 + 0.03 * t))
    white = top + bot[::-1]
    c.poly(white, "#f6fbff")
    c.stroke(offset(top, -0.022), 0.05, "#b6cadf", alpha=0.75, clip=white)  # the lid's shadow on the white
    color = glow or iris
    ix, iy = cx + s * 0.006, cy + 0.002
    rx, ry = 0.079, 0.096
    c.ellipse(ix, iy, rx, ry, shade(color, -0.6), clip=white)
    c.ellipse(ix, iy - 0.006, rx * 0.84, ry * 0.86, shade(color, -0.12), clip=white)
    c.ellipse(ix, iy - ry * 0.42, rx * 0.66, ry * 0.42, shade(color, 0.42), alpha=0.9, clip=white)
    c.ellipse(ix, iy + ry * 0.5, rx * 0.95, ry * 0.5, shade(color, -0.45), alpha=0.6, clip=white)
    if glow:  # glowing: a thin bright slit instead of the pupil
        c.ellipse(ix, iy - ry * 0.05, rx * 0.16, ry * 0.5, "#ffffff", clip=white)
    else:
        c.ellipse(ix, iy + 0.004, rx * 0.36, ry * 0.42, "#173447", clip=white)
    hx, hy = (0.5, 0.36) if glow else (0.42, 0.24)  # kept clear of the glowing slit
    c.ellipse(ix - s * rx * hx, iy + ry * hy, rx * 0.28, ry * 0.19, "#ffffff", clip=white)
    c.ellipse(ix + s * rx * 0.38, iy - ry * 0.42, rx * 0.12, ry * 0.08, "#ffffff", alpha=0.9, clip=white)
    # the lash line, heavier toward the outer corner, and long outer lashes
    lid = [(x, y + 0.004) for x, y in top]
    c.stroke(lid, 0.034, LASH, taper=(0.35, 1.1))
    c.stroke([lid[-2], lid[-1], (outer + s * 0.04, lid[-1][1] + 0.008)], 0.034 * 1.1, LASH, taper=(1.0, 0.25))
    for t, (dx, dy), ln in ((0.74, (0.45, 1.0), 0.05), (0.86, (0.8, 0.85), 0.06), (0.97, (1.0, 0.35), 0.07)):
        bx, by = top[int(t * 14)]
        k = math.hypot(dx, dy)
        c.stroke([(bx, by + 0.008), (bx + s * dx / k * ln, by + 0.008 + dy / k * ln)], 0.018, LASH,
                 taper=(1.0, 0.1))
    crease = [(x, y + 0.044) for x, y in top[3:13]]
    c.stroke(crease, 0.011, shade(SKIN, -0.32), alpha=0.65, taper=(0.3, 1.0))
    c.stroke(bot[7:14], 0.012, LASH, alpha=0.6, taper=(0.2, 1.0))  # the lower lash line


def brow(c, side, y=4.79):
    """A thin, softly arched brow, thinning toward the outer end."""
    s = side
    pts = [(s * (0.12 + 0.2 * t), y + 0.032 * math.sin(math.pi * (0.15 + 0.75 * t)) - 0.012 * t) for t in
           (i / 10 for i in range(11))]
    c.stroke(pts, 0.021, BROW, taper=(1.15, 0.35))


def face(c, glow=None):
    for side in (1, -1):
        calm_eye(c, side, IRIS, glow=glow)
        brow(c, side)
        # a soft blush and frost sparkles under the outer corners
        c.ellipse(side * 0.24, 4.455, 0.075, 0.03, "#f39aa8", alpha=0.32)
        for k in range(3):
            x = side * (0.2 + 0.035 * k)
            c.stroke([(x + side * 0.02, 4.47), (x, 4.44)], 0.008, "#e88a98", alpha=0.45)
        mark = glow or FROST
        sparkle(c, side * 0.39, 4.45, 0.05, mark, alpha=0.9)
        sparkle(c, side * 0.43, 4.39, 0.026, mark, alpha=0.75)
    c.stroke([(0.012, 4.47), (0.0, 4.445)], 0.011, shade(SKIN, -0.3), alpha=0.5)  # nose hint
    # a small serene smile (wide enough to read at game distance) and a lower lip
    c.stroke(A._arc(0, 4.355, 0.065, 0.024, 205, 335, 12), 0.017, "#8a4a52", taper=(0.6, 0.6))
    c.ellipse(0, 4.318, 0.032, 0.01, "#e79aa3", alpha=0.45)


# Accessory styles ----------------------------------------------------------------------------------


class FrostHair(Hair):
    """Pale ice-blue anime hair: darker toward the bottom (`base`) or fading
    to icy cyan tips (`tip`), lighter toward the top, fine strands and a
    shine band broken into clumps. `crown` darkens the top (a layer tucked
    under the one above it)."""

    def __init__(self, color, base=None, tip=None, fade=0.45, light=0.25, crown=0.0, shine_alpha=0.58,
                 band=0.07, wave=0.008, **kw):
        super().__init__(color, **kw)
        self.base, self.tip, self.fade, self.lit, self.crown = base, tip, fade, light, crown
        self.shine_alpha, self.band, self.wave = shine_alpha, band, wave

    def paint(self, c):
        c.gradient((0.5, self.fade), (0.5, 1.0), self.color, shade(self.color, self.lit))
        low = self.tip or self.base
        if low and self.fade:
            c.gradient((0.5, 0.0), (0.5, self.fade), low, self.color, clip=box(0, 0, 1, self.fade))
        if self.crown:
            c.gradient((0.5, 1 - self.crown), (0.5, 1.0), self.color, shade(self.color, -0.2),
                       clip=box(0, 1 - self.crown, 1, 1))
        rng = np.random.default_rng(int(self.shine * 100) + self.strands)
        for _ in range(self.strands):
            x = rng.uniform(0, 1)
            c.stroke([(x, 0.0), (x + rng.uniform(-0.02, 0.02), rng.uniform(0.5, 0.97))], 0.01,
                     shade(self.color, -0.35), alpha=0.6, taper=(1.0, 0.2))
        for _ in range(self.strands // 2):
            x = rng.uniform(0, 1)
            c.stroke([(x, 0.1), (x + rng.uniform(-0.02, 0.02), rng.uniform(0.6, 0.95))], 0.008,
                     shade(self.color, 0.45), alpha=0.35, taper=(0.2, 1.0))
        if self.shine:  # a ring of lens-shaped highlights, a few to each strand clump
            n = 18
            for k in range(n):
                u0, u1 = k / n + 0.006, (k + 1) / n - 0.016
                dv = rng.uniform(-0.012, 0.012)
                top, bot = [], []
                for i in range(9):
                    t = i / 8
                    u = u0 + (u1 - u0) * t
                    h = self.band * math.sin(math.pi * t) ** 0.6
                    v = self.shine + dv + self.wave * math.sin(u * math.pi * 14)
                    top.append((u, v + h * 0.4))
                    bot.append((u, v - h * 0.6))
                c.poly(top + bot[::-1], self.shine_color or shade(self.color, 0.4), alpha=self.shine_alpha)
        c.material(0.0, 0.5)


class Ice(Style):
    """Clear ice: deep below, bright at the top, with glints."""

    rough = 0.12

    def paint(self, c):
        c.gradient((0.5, 0.0), (0.5, 0.55), shade(self.color, -0.38), self.color, clip=box(0, 0, 1, 0.55))
        c.gradient((0.5, 0.55), (0.5, 1.0), self.color, shade(self.color, 0.55), clip=box(0, 0.55, 1, 1))
        for u, w in ((0.12, 0.06), (0.47, 0.03), (0.74, 0.07)):
            c.poly([(u, 0), (u + w, 0), (u + w + 0.18, 1), (u + 0.18, 1)], "#ffffff", alpha=0.28)
        c.material(0.0, self.rough)


# Geometry helpers ------------------------------------------------------------------------------


def frame(normal, up=(0, 1, 0)):
    """Rotation taking local Z to `normal` and local Y toward `up`."""
    z = Vector(normal).normalized()
    y = Vector(up) - z * z.dot(Vector(up))
    y = y.normalized() if y.length > 1e-6 else Vector((0, 1, 0))
    x = y.cross(z)
    return Matrix((x, y, z)).transposed()


def slab(mb, rows, thickness, style):
    """Like avatar.sheet, but with its own thickness per row (a number) or
    per point (a list): a solid through a grid of points (rows top to
    bottom, each row from her left to her right)."""
    grid = [[Vector(p) for p in row] for row in rows]
    nr, nc = len(grid), len(grid[0])

    def normal(i, j):
        a = grid[min(i + 1, nr - 1)][j] - grid[max(i - 1, 0)][j]
        b = grid[i][min(j + 1, nc - 1)] - grid[i][max(j - 1, 0)]
        n = b.cross(a)
        return n.normalized() if n.length > 1e-9 else Vector((0, 0, 1))

    verts = []
    for i in range(nr):
        for j in range(nc):
            th = thickness[i][j] if isinstance(thickness[i], (list, tuple)) else thickness[i]
            n = normal(i, j) * th / 2
            verts += [tuple(grid[i][j] + n), tuple(grid[i][j] - n)]

    def idx(i, j, k):
        return (i * nc + j) * 2 + k

    faces = []
    for i in range(nr - 1):
        for j in range(nc - 1):
            faces.append((idx(i, j, 0), idx(i + 1, j, 0), idx(i + 1, j + 1, 0), idx(i, j + 1, 0)))
            faces.append((idx(i, j, 1), idx(i, j + 1, 1), idx(i + 1, j + 1, 1), idx(i + 1, j, 1)))
        faces.append((idx(i, 0, 1), idx(i + 1, 0, 1), idx(i + 1, 0, 0), idx(i, 0, 0)))
        faces.append((idx(i, nc - 1, 0), idx(i + 1, nc - 1, 0), idx(i + 1, nc - 1, 1), idx(i, nc - 1, 1)))
    for j in range(nc - 1):
        faces.append((idx(0, j, 0), idx(0, j + 1, 0), idx(0, j + 1, 1), idx(0, j, 1)))
        faces.append((idx(nr - 1, j, 1), idx(nr - 1, j + 1, 1), idx(nr - 1, j + 1, 0), idx(nr - 1, j, 0)))
    mb.polys(verts, faces, style, smooth=True)


def shade_under(mb, key, inward=-0.7, down=-0.8):
    """Gives the faces of a melted piece that face the head or the ground
    the darker `key` style: the shadowed underside and inner side of hair.
    Only faces turned well away count (a looser test leaves jagged dark
    triangles along rounded edges)."""
    bm = mb.bm
    bm.normal_update()
    index = mb.palette.index[key]
    for f in bm.faces:
        c = f.calc_center_median()
        radial = Vector((c.x, 0.0, c.z))
        if radial.length < 1e-6:
            continue
        if f.normal.dot(radial.normalized()) < inward or f.normal.y < down:
            f[mb.color_layer] = index


def crystal(mb, center, length, radius, style, lean_out=0.0, lean_back=0.0, twist=0.0):
    """A faceted hexagonal ice crystal: a long point above, a short one below."""
    L, R = length, radius
    sections = [(0, -0.36 * L, 0, 0, 0), (0, -0.12 * L, 0, R, R), (0, 0.14 * L, 0, R * 0.92, R * 0.92),
                (0, 0.64 * L, 0, 0, 0)]
    rot = (Matrix.Rotation(math.radians(-lean_out), 3, "Z") @ Matrix.Rotation(math.radians(lean_back), 3, "X")
           @ Matrix.Rotation(math.radians(twist), 3, "Y"))
    mb.loft(sections, style, center=center, rotation=rot, segments=6, smooth=False)


# The model ---------------------------------------------------------------------------------------


def model(av):
    av.style("hair", FrostHair(HAIR, base=shade(HAIR, -0.22), fade=0.4, shine=0.74, strands=30))
    av.style("hairshade", FrostHair(shade(HAIR, -0.16), shine=0, strands=8, fade=0, light=0.06))
    av.style("hairback", FrostHair(HAIR, projection="front", size=(160, 256), tip=HAIR_TIP, fade=0.55, light=0.0,
                                   crown=0.1, shine=0, strands=34))
    av.style("clip", Ice(ICE_DEEP, size=(64, 64)))
    av.style("gem", Ice("#c8f6ff", size=(32, 32)))
    for k in range(3):
        av.style(f"ice{k}", Ice(CRYSTAL, size=(96, 128)))
    hairdo(av)
    long_hair(av)
    hair_clip(av)
    crystals(av)


def fringe_edge(angle):
    """The fringe's softly pointed lower edge (degrees from the front; a
    float or an array)."""
    y = FRINGE - 0.045 * np.abs(np.sin(np.radians(angle) * 9))
    return float(y) if np.ndim(y) == 0 else y


def hairline(angle):
    """How low the hair reaches around the head (degrees from the front; a
    float or an array): the fringe's height in front, then behind the cheek
    line it drops over the ears and sweeps on down to the nape, in soft
    pointed clumps."""
    d = np.abs((np.asarray(angle, dtype=float) + 180) % 360 - 180)
    base = 4.88 - (4.88 - SIDE) * sstep(74, 88, d) - (SIDE - NAPE) * sstep(88, 132, d)
    clumps = 0.035 * np.abs(np.sin((d - 86) * math.pi / 13)) * sstep(84, 90, d) * (1 - sstep(112, 124, d))
    y = base - clumps
    return float(y) if np.ndim(y) == 0 else y


def flat_lock(av, mb, angle, top, tip, width=0.15, out=0.085, flare=0.03, rows=9):
    """A flat strand of hair lying over the side hair from `top` and hanging
    below it to a blunt point at `tip`, standing a little off the cheek (a
    shadow gap behind it) and curling slightly away at the end."""
    s = 1 if angle > 0 else -1
    grid, thick = [], []
    for i in range(rows):
        t = i / (rows - 1)
        y = top + (tip - top) * t
        o = out + flare * t * t
        half = width / 2 * (1 - 0.6 * t ** 2.2)
        da = math.degrees(half / (A.HEAD_R + o))
        a = angle + s * 1.5 * t
        grid.append([tuple(av.head_point(a + k * da, y, out=o)[0]) for k in (-1, -0.5, 0, 0.5, 1)])
        th = 0.065 * (1 - 0.3 * t)
        thick.append([th * 0.55, th * 0.9, th, th * 0.9, th * 0.55])
    slab(mb, grid, thick, "hair")


def hairdo(av):
    """A sleek cap: a smooth dome, a softly pointed fringe, hair over the
    sides and back of the head ending in a short bob at the nape, and flat
    side locks; melted into one, carved off the scalp, with its underside
    in shadow."""
    mb = av.builder()
    mb.sphere((0, 4.99, 0.03), (0.69, 0.345, 0.7), "hair", segments=32, rings=16)
    A.shell(mb, "hair", 52, 308, hairline, 5.04, r_in=0.56, r_out=0.69, steps=64, rows=6)
    A.shell(mb, "hair", -56, 56, fringe_edge, 5.04, r_in=0.56, r_out=0.68, steps=48, rows=4)
    # a flat lock in front of each ear, over the side hair and hanging past
    # the jaw (behind the cheek line, clear of her hands)
    for s in (-1, 1):
        flat_lock(av, mb, s * 84, 5.0, 4.2, width=0.17)
    hair = A.melt(mb, voxel=0.018, smooth=4, tris=3400, carve_head=True)
    shade_under(hair, "hairshade")
    av.piece(hair, bone="Neck", name="Hair")


# The long hair's rows, top to bottom: (height, front, back, half width, hug).
# Front and back are z on the centre line; while `hug` is 1 they are radii
# and the row follows the back of the head. It starts inside the bob, comes
# out through its surface steeply (no coplanar band to flicker), wraps the
# nape, then hangs as a heavy wedge whose front stays 0.08 off her back.
CURTAIN = (
    (4.46, 0.625, 0.655, 0.38, 1.0),
    (4.36, 0.62, 0.72, 0.42, 1.0),
    (4.26, 0.605, 0.76, 0.45, 0.85),
    (4.14, 0.58, 0.785, 0.47, 0.55),
    (4.02, 0.56, 0.8, 0.49, 0.2),
    (3.9, 0.58, 0.82, 0.5, 0.0),
    (3.75, 0.58, 0.85, 0.53, 0.0),
    (3.6, 0.585, 0.89, 0.57, 0.0),
    (3.4, 0.59, 0.92, 0.6, 0.0),
    (3.2, 0.6, 0.93, 0.6, 0.0),
    (3.0, 0.61, 0.925, 0.58, 0.0),
    (2.8, 0.62, 0.91, 0.56, 0.0),
    (2.64, 0.63, 0.88, 0.52, 0.0),
    (2.5, 0.635, 0.84, 0.48, 0.0),
    (TIPS, 0.64, 0.79, 0.45, 0.0),
)


def _tips(u):
    """How far below TIPS each part of the hem hangs (u from -1 to 1 across):
    a V of five pointed clumps."""
    return 0.3 * (1 - abs(u)) + 0.12 * abs(math.cos(u * math.pi * 2.5))


def long_hair(av):
    """The long straight curtain down her back, on a sway chain from the
    head. Its top lies over the back of the bob (above the pivot, so a swing
    tucks it into the bob rather than lifting it off), then it falls behind
    her back as a heavy curtain ending in a V of points."""
    chain = av.sway("Hair", "Neck", [(0, 4.26, 0.69), (0, 3.4, 0.73), (0, 2.8, 0.74), (0, 2.1, 0.72)],
                    stiffness=0.3, damping=0.2, limit=50, behind=1)
    n = len(CURTAIN)
    drop = {n - 3: 0.33, n - 2: 0.66, n - 1: 1.0}
    rows, thick = [], []
    for i, (y, front, back, half, hug) in enumerate(CURTAIN):
        mid, th = (front + back) / 2, back - front
        row, trow = [], []
        for j in range(21):
            u = 2 * j / 20 - 1
            x = half * u
            z = hug * math.sqrt(max(mid * mid - x * x, 0.0)) + (1 - hug) * (mid - 0.03 * u * u)
            row.append((x, y - drop.get(i, 0.0) * _tips(u), z))
            trow.append(th * (1 - 0.45 * u * u * (1 - hug)))
        rows.append(row)
        thick.append(trow)
    mb = av.builder()
    slab(mb, rows, thick, "hairback")
    av.piece(A.melt(mb, voxel=0.02, smooth=4, tris=2400), sway=chain, name="LongHair")


def hair_clip(av):
    """A deep-ice snowflake clip over her left temple, half sunk into the
    hair, with a pale gem at its heart."""
    p, n = av.head_point(-50, 4.99, out=0.095)
    rot = frame(n)
    mb = av.builder()
    r = 0.15
    star = []
    for k in range(12):
        a = math.radians(90 + 30 * k)
        rr = r if k % 2 == 0 else r * 0.4
        star.append((math.cos(a) * rr, math.sin(a) * rr))
    # thick enough that both its faces stand clear of the curved hair surface
    mb.prism(star, 0.075, "clip", center=tuple(p), rotation=rot, bevel=0.008)
    gem = [(math.cos(math.radians(30 + 60 * k)) * 0.045, math.sin(math.radians(30 + 60 * k)) * 0.045)
           for k in range(6)]
    mb.prism(gem, 0.03, "gem", center=tuple(p + n * 0.042), rotation=rot, bevel=0.006)
    av.piece(mb, bone="Neck", name="HairClip")


def crystals(av):
    """Three faceted ice crystals hovering in a fan behind her upper back: a
    big upright shard behind her head (hidden from the front, a large floating
    shard from the side) and two smaller ones fanned out low like wing tips,
    clear of the arms' swing (|x| < 0.95) and of the head."""
    mb = av.builder()
    crystal(mb, (0.0, 4.55, 1.25), 0.9, 0.16, "ice0", lean_back=6, twist=15)
    for k, s in ((1, 1), (2, -1)):
        crystal(mb, (s * 0.6, 4.02, 1.15), 0.62, 0.12, f"ice{k}", lean_out=s * 60, lean_back=8, twist=s * 20)
    av.piece(mb, bone="Waist", name="Crystals")


# The painted outfit --------------------------------------------------------------------------------


def paint(av, p):
    p.head.fill(SKIN)
    for limb in p.limbs.values():
        limb.fill(WHITE)
    paint_torso(p)
    paint_arms(p)
    paint_legs(p)
    paint_head(p)


def sash_tails(f, dx):
    """The sash's two tails from under the knot down over the skirt, ending
    in V cuts; drawn in torso coordinates shifted by dx (so the same tails
    continue across the torso's and the right leg's front)."""
    for x0, lean, end in ((KNOT_X - 0.06, -0.1, 1.58), (KNOT_X + 0.08, 0.14, 1.48)):
        ys = (2.24, 2.0, end)
        centre = [(x0 + lean * (2.24 - y) + dx, y) for y in ys]
        half = [0.055 + 0.03 * (2.24 - y) for y in ys]  # widening a little as they fall
        left = [(x - w, y) for (x, y), w in zip(centre, half)]
        right = [(x + w, y) for (x, y), w in zip(centre, half)]
        shape = left + [(centre[-1][0], end + 0.08)] + right[::-1]
        f.poly(shape, shade(SASH, -0.2))
        fold = [(x0 + lean * (2.24 - y) + dx, y) for y in (2.22, 2.0, end + 0.12)]
        f.stroke(offset(fold, 0.02), 0.025, shade(SASH, 0.2), alpha=0.6)
        f.stroke(shape + [shape[0]], 0.014, NAVY, alpha=0.9)


def paint_torso(p):
    t = p.torso
    lo, hi = WAIST
    f, b = t.front, t.back
    # the bodice: white cooling toward the waist, a shadow under the collar,
    # cool-tinted flanks fading out up the ribs
    for fc in t.sides:
        fc.gradient((0, 4.0), (0, hi), WHITE, BODICE_LOW)
    soft(f, shade(WHITE, -0.3), lambda x, y: 0.45 * ramp(y, 3.6, 3.77) * ramp(0.66 - abs(x), 0, 0.14) * (y < 3.8))
    for fc in (f, b):
        soft(fc, shade(ICE, 0.15), lambda x, y: 0.5 * ramp(abs(x), 0.5, 1.0) * ramp(3.6 - y, 0, 0.7))
    # fitted shaping: princess seams and a soft bust line
    for sx in (-1, 1):
        f.stroke([(sx * 0.86, 3.7), (sx * 0.62, 3.25), (sx * 0.6, 2.85), (sx * 0.68, hi)], 0.03,
                 shade(WHITE, -0.28), alpha=0.7)
        f.stroke([(sx * 0.18, 3.3), (sx * 0.42, 3.24), (sx * 0.62, 3.3)], 0.04, shade(WHITE, -0.24), alpha=0.6,
                 taper=(0.4, 1.0))
        b.stroke([(sx * 0.86, 3.7), (sx * 0.62, 3.2), (sx * 0.64, hi)], 0.03, shade(WHITE, -0.28), alpha=0.7)
    # the diagonal closure from the collar to her left hip, with crystal toggles
    closure = [(0.0, 3.78), (-0.2, 3.66), (-0.38, 3.5), (-0.46, 3.3), (-0.48, 3.0), (-0.48, hi)]
    trim(f, closure, 0.1, flakes=0.2)
    for y in (3.12, 2.82, 2.56):
        f.stroke([(-0.62, y), (-0.34, y)], 0.03, NAVY)
        f.poly([(-0.48, y + 0.06), (-0.43, y), (-0.48, y - 0.06), (-0.53, y)], ICE_DEEP)
        f.poly([(-0.48, y + 0.06), (-0.43, y), (-0.48, y)], shade(ICE, 0.5))
    flake(f, 0.42, 3.05, 0.15, ICE_DEEP)
    flake(f, 0.42, 3.05, 0.06, ICE, width=0.02)
    # the high collar in deep ice (front, back and around the neck on top)
    collar = [(-0.46, 4.0), (0.46, 4.0), (0.44, 3.84), (0.34, 3.76), (-0.34, 3.76), (-0.44, 3.84)]
    f.poly(collar, ICE_DEEP)
    f.rect_(-0.46, 3.92, 0.46, 4.0, shade(ICE_DEEP, 0.3), alpha=0.6)
    f.stroke(collar[2:] + [collar[0]], 0.02, NAVY)
    f.stroke([(0.0, 3.77), (0.0, 4.0)], 0.016, NAVY)
    for x in (-0.24, 0.24):
        flake(f, x, 3.87, 0.05, "#ffffff")
    b.rect_(-0.46, 3.8, 0.46, 4.0, ICE_DEEP)
    b.rect_(-0.46, 3.92, 0.46, 4.0, shade(ICE_DEEP, 0.3), alpha=0.6)
    b.rect_(-0.46, 3.8, 0.46, 3.82, NAVY)
    for x in (-0.3, 0.0, 0.3):
        flake(b, x, 3.9, 0.05, "#ffffff")
    top = t.top
    top.ellipse(0, 0, 0.68, 0.5, ICE_DEEP)
    top.ellipse(0, 0, 0.6, 0.42, shade(ICE_DEEP, -0.2))
    top.ellipse(0, 0, 0.48, 0.34, SKIN)
    # below the sash the skirt begins, opening over the leggings at the front
    for fc in t.sides:
        a0, _, a1, _ = fc.bounds()
        fc.rect_(a0, 2.0, a1, lo, SKIRT)
    f.rect_(-SPLIT, 2.0, SPLIT, lo, LEGGING)
    for sx in (-1, 1):
        f.stroke([(sx * (SPLIT - 0.05), 2.0), (sx * (SPLIT - 0.05), lo)], 0.06, shade(LEGGING, -0.3), alpha=0.35)
        trim(f, [(sx * SPLIT, lo + 0.02), (sx * SPLIT, 2.0)], 0.08, color=ICE_DEEP, shadow=None)
    # the sash, knotted on her right hip
    t.band(lo, hi, SASH)
    t.band(lo, lo + 0.03, shade(SASH, -0.32))
    t.band(hi - 0.03, hi, shade(SASH, 0.3))
    t.band(lo, lo + 0.012, NAVY)
    t.band(hi - 0.012, hi, NAVY)
    for fc in t.sides:
        a0, _, a1, _ = fc.bounds()
        for y in (2.22, 2.31):
            fc.stroke([(a0, y), (a1, y + 0.01)], 0.02, shade(SASH, -0.25), alpha=0.6)
    sash_tails(f, 0.0)
    sash_knot(f, KNOT_X, 2.28)
    # frost creeping up from the sash
    frost(f, 0.6, 1.0, hi, ICE, alpha=0.4, height=(0.04, 0.16), seed=3, glints=1)
    frost(f, -1.0, -0.6, hi, ICE, alpha=0.4, height=(0.04, 0.14), seed=4, glints=1)
    # sides: a piped seam
    for side in (t.right, t.left):
        side.stroke([(0.0, hi), (0.0, 4.0)], 0.05, ICE)
        side.stroke([(0.0, hi), (0.0, 4.0)], 0.012, NAVY, alpha=0.8)
    # back: a seam and a large faint snowflake (seen as the hair swings)
    b.stroke([(0, hi), (0, 3.8)], 0.025, shade(WHITE, -0.22), alpha=0.6)
    flake(b, 0, 3.05, 0.36, ICE, alpha=0.6)
    t.bottom.fill(LEGGING)


def sash_knot(f, x, y):
    """A soft knot with two loops, lighter than the band so it stands out."""
    loop = shade(SASH, 0.25)
    for sx, rot in ((-1, 20), (1, -20)):
        f.ellipse(x + sx * 0.13, y + 0.02, 0.125, 0.075, NAVY, rotation=rot)
        f.ellipse(x + sx * 0.13, y + 0.02, 0.11, 0.06, loop, rotation=rot)
        f.ellipse(x + sx * 0.14, y + 0.03, 0.07, 0.03, shade(loop, 0.3), rotation=rot)
        f.ellipse(x + sx * 0.08, y + 0.015, 0.035, 0.022, shade(loop, -0.35), rotation=rot)
    f.ellipse(x, y, 0.065, 0.08, NAVY)
    f.ellipse(x, y, 0.052, 0.067, loop)
    f.ellipse(x - 0.01, y + 0.015, 0.03, 0.035, shade(loop, 0.35))


def yoke(arm):
    """A deep-ice shoulder yoke matching the collar: over the top of the
    arm, its lower edge curving down at the front and back, navy piped."""
    arm.top.fill(ICE_DEEP)
    arm.top.ellipse(0, 0, 0.42, 0.3, shade(ICE_DEEP, 0.18), alpha=0.6)

    def edge(x):
        return 3.76 - 0.07 * (1 - (x / 0.5) ** 2)

    xs = [k / 10 - 0.5 for k in range(11)]
    for fc in (arm.front, arm.back):
        lower = [(x, edge(x)) for x in xs]
        fc.poly(lower + [(0.5, 4.0), (-0.5, 4.0)], ICE_DEEP)
        fc.stroke(offset(lower, 0.04), 0.03, shade(ICE_DEEP, 0.28), alpha=0.6)
        fc.stroke(lower, 0.022, NAVY)
    for fc in (arm.outer, arm.inner):
        fc.rect_(-0.5, 3.76, 0.5, 4.0, ICE_DEEP)
        fc.rect_(-0.5, 3.79, 0.5, 3.82, shade(ICE_DEEP, 0.28), alpha=0.6)
        fc.rect_(-0.5, 3.75, 0.5, 3.77, NAVY)
    flake(arm.outer, 0.0, 3.88, 0.07, "#ffffff")


def paint_arms(p):
    for arm in p.arms():
        for f in arm.sides:
            f.gradient((0, 4.0), (0, 2.5), WHITE, BODICE_LOW)
        # an ice-blue stripe hanging from the yoke down the outer arm
        o = arm.outer
        o.rect_(-0.1, 2.78, 0.1, 3.76, ICE)
        o.rect_(-0.03, 2.78, 0.03, 3.76, shade(ICE, 0.3), alpha=0.6)
        for z in (-0.1, 0.1):
            o.stroke([(z, 2.78), (z, 3.76)], 0.016, NAVY, alpha=0.9)
        for y in (3.5, 3.2):
            flake(o, 0.0, y, 0.07, "#ffffff")
        # sleeve folds: at the elbow, over the upper arm, a pull toward the cuff
        for f in arm.sides:
            creases(f, 2.95, shade(WHITE, -0.28))
        for f in (arm.front, arm.back):
            creases(f, 3.3, shade(WHITE, -0.26), spread=0.32)
            f.stroke([(-0.28, 3.08), (0.05, 3.0), (0.3, 3.05)], 0.03, shade(WHITE, -0.24), alpha=0.6,
                     taper=(0.3, 1.0))
            f.stroke([(-0.25, 2.88), (0.2, 2.84)], 0.03, shade(WHITE, -0.24), alpha=0.6)
        # frost growing up from the cuffs
        for k, f in enumerate(arm.sides):
            frost(f, -0.5, 0.5, 2.78, ICE, alpha=0.45, height=(0.04, 0.17), seed=40 + 4 * k + int(arm.cx * 2),
                  glints=1)
        # wide ice-blue cuffs with a white snowflake band, then bare hands
        for f in arm.sides:
            a0, _, a1, _ = f.bounds()
            f.rect_(a0, 2.47, a1, 2.78, ICE)
            f.gradient((0, 2.78), (0, 2.47), shade(ICE, 0.15), shade(ICE, -0.12), clip=box(a0, 2.47, a1, 2.78))
        hem_band(arm.sides, 2.6, 2.72, color="#ffffff", flake_color=ICE_DEEP, flakes=0.2)
        for f in arm.sides:
            a0, _, a1, _ = f.bounds()
            f.rect_(a0, 2.47, a1, 2.49, NAVY)
            f.rect_(a0, 2.76, a1, 2.78, NAVY)
        arm.band(2.0, 2.47, SKIN)
        for f in arm.sides:
            f.rect_(-0.5, 2.44, 0.5, 2.47, shade(SKIN, -0.25), alpha=0.6)
        yoke(arm)
        arm.bottom.fill(shade(SKIN, -0.1))


def skirt(f, region, sx):
    """The ice-blue skirt fabric on one leg face: shading, soft folds and a
    frosty glow rising from the hem."""
    a0 = min(a for a, _ in region)
    a1 = max(a for a, _ in region)
    f.poly(region, SKIRT)
    f.gradient((0, 2.0), (0, HEM), shade(SKIRT, 0.12), shade(SKIRT, -0.12), clip=region)
    for x in (0.3, 0.7):
        xx = a0 + (a1 - a0) * x
        f.stroke([(xx, 1.92), (xx + 0.03 * sx, HEM + 0.16)], 0.05, shade(SKIRT, -0.3), alpha=0.5,
                 taper=(0.2, 1.3), clip=region)
        f.stroke([(xx + 0.06, 1.85), (xx + 0.08, HEM + 0.25)], 0.02, shade(SKIRT, 0.3), alpha=0.45,
                 taper=(0.2, 1.0), clip=region)
    soft(f, "#ffffff", lambda x, y: 0.4 * ramp(HEM + 0.55 - y, 0, 0.4) * (x >= a0) * (x <= a1),
         region=(a0, HEM, a1, HEM + 0.6))


def paint_legs(p):
    for leg in p.legs():
        sx = 1 if leg.cx > 0 else -1  # +1 for her right leg
        for f in leg.sides:
            f.fill(LEGGING)
            f.gradient((0, 2.0), (0, 0.7), LEGGING, shade(LEGGING, -0.1))
        # the coat's skirt: everywhere but the inner side, open toward the
        # middle at the front, with a trimmed edge and a navy hem
        inner_edge = -sx * (0.5 - SPLIT)
        f = leg.front
        f.stroke([(inner_edge - sx * 0.05, 2.0), (inner_edge - sx * 0.05, HEM + 0.1)], 0.06,
                 shade(LEGGING, -0.3), alpha=0.35)  # the skirt's shadow on the legging
        skirt(f, [(inner_edge, HEM + 0.08), (inner_edge, 2.0), (sx * 0.5, 2.0), (sx * 0.5, HEM),
                  (inner_edge + sx * 0.08, HEM)], sx)
        for face in (leg.outer, leg.back):
            a0, _, a1, _ = face.bounds()
            skirt(face, box(a0, HEM, a1, 2.0), sx)
        # frost creeping up from the hem
        lo = min(inner_edge + sx * 0.12, sx * 0.45)
        hi_ = max(inner_edge + sx * 0.12, sx * 0.45)
        frost(f, lo, hi_, HEM + 0.16, seed=10 + sx)
        frost(leg.outer, -0.5, 0.5, HEM + 0.16, seed=20 + sx)
        frost(leg.back, -0.5, 0.5, HEM + 0.16, seed=30 + sx)
        # the hem: a navy band with white snowflakes, piped in ice
        hem_band([leg.outer, leg.back], HEM, HEM + 0.16, color=NAVY, flake_color="#ffffff", flakes=0.25, piping=ICE)
        f.poly([(inner_edge, HEM + 0.16), (sx * 0.5, HEM + 0.16), (sx * 0.5, HEM), (inner_edge + sx * 0.08, HEM)],
               NAVY)
        f.poly([(inner_edge, HEM + 0.12), (sx * 0.5, HEM + 0.12), (sx * 0.5, HEM + 0.08),
                (inner_edge + sx * 0.04, HEM + 0.08)], shade(NAVY, 0.25), alpha=0.45)
        f.rect_(inner_edge + sx * 0.08, HEM, sx * 0.5, HEM + 0.022, ICE)
        f.rect_(inner_edge, HEM + 0.142, sx * 0.5, HEM + 0.16, ICE, alpha=0.9)
        for k in (0.16, 0.4):
            flake(f, sx * k, HEM + 0.08, 0.05, "#ffffff")
        edge = [(inner_edge, 2.0), (inner_edge, HEM + 0.1), (inner_edge + sx * 0.1, HEM + 0.02)]
        trim(f, edge, 0.08, color=ICE_DEEP, shadow=None)
        # a back vent between the legs
        leg.back.stroke([(-sx * 0.5, 2.0), (-sx * 0.5, HEM)], 0.035, shade(SKIRT, -0.4), alpha=0.7)
        # leggings: knee shading
        for fc in (leg.inner, leg.front):
            fc.stroke([(-0.3, 1.25), (0.3, 1.25)] if fc is leg.inner else
                      [(inner_edge - sx * 0.2, 1.25), (inner_edge, 1.25)], 0.03, shade(LEGGING, -0.22), alpha=0.6)
        # soft white boots with a fold-over deep-ice cuff, navy soles glowing
        # faintly cyan (she floats)
        for fc in leg.sides:
            a0, _, a1, _ = fc.bounds()
            fc.rect_(a0, 0.0, a1, 0.62, BOOT)
            fc.gradient((0, 0.62), (0, 0.06), BOOT, shade(BOOT, -0.12), clip=box(a0, 0.06, a1, 0.62))
            soft(fc, SOLE_GLOW, lambda x, y: 0.55 * ramp(0.2 - y, 0, 0.13), region=(a0, 0.07, a1, 0.2))
            fc.rect_(a0, 0.0, a1, 0.07, NAVY)
            fc.rect_(a0, 0.0, a1, 0.02, SOLE_GLOW, alpha=0.8)
            fc.stroke([(a0 * 0.7, 0.24), (0.0, 0.21), (a1 * 0.7, 0.25)], 0.025, shade(BOOT, -0.2), alpha=0.55)
            fc.stroke([(a0 * 0.6, 0.38), (a1 * 0.5, 0.36)], 0.02, shade(BOOT, -0.18), alpha=0.45)
        # ribbon lacing up the front
        lf = leg.front
        ys = [0.2 + 0.09 * k for k in range(5)]
        for k0 in (0, 1):
            zig = [((0.11 if (k + k0) % 2 else -0.11), y) for k, y in enumerate(ys)]
            lf.stroke(zig, 0.03, shade(ICE_DEEP, 0.1))
            lf.stroke(offset(zig, 0.007), 0.01, shade(ICE, 0.4), alpha=0.7)
        for y in ys:
            for x in (-0.13, 0.13):
                lf.ellipse(x, y, 0.02, 0.02, NAVY)
        lf.ellipse(0, 0.12, 0.3, 0.04, shade(BOOT, 0.4), alpha=0.5)  # toe shine
        # a soft turned-down cuff with a scalloped edge
        for fc in leg.sides:
            a0, _, a1, _ = fc.bounds()
            fc.rect_(a0, 0.6, a1, 0.74, ICE_DEEP)
            fc.gradient((0, 0.74), (0, 0.6), shade(ICE_DEEP, 0.25), shade(ICE_DEEP, -0.1),
                        clip=box(a0, 0.6, a1, 0.74))
            fc.rect_(a0, 0.72, a1, 0.74, NAVY, alpha=0.8)
            k = a0 + 0.05
            while k < a1:
                fc.ellipse(k, 0.6, 0.05, 0.03, shade(ICE_DEEP, -0.15))
                k += 0.1
        flake(leg.outer, 0.0, 0.4, 0.1, ICE)
        flake(leg.outer, 0.0, 0.67, 0.045, "#ffffff")
        lf.poly([(-0.07, 0.66), (0.0, 0.62), (0.07, 0.66), (0.07, 0.58), (0.0, 0.62), (-0.07, 0.58)],
                "#ffffff")  # a small bow at the top of the lacing
        leg.bottom.fill(SOLE_GLOW)
        if sx > 0:  # the sash's tails continue from the torso onto her right leg
            sash_tails(f, -leg.cx)


def paint_head(p):
    """Skin, a soft shadow just under the hair's edge all round (no flat
    hair-colored blocks: the hair covers everything above the edge), a
    shadow behind the side locks and on the neck below the hair."""
    h = p.head
    h.top.fill(shade(HAIR, -0.25))
    h.bottom.fill(shade(SKIN, -0.16))
    r = A.HEAD_R

    def edge(s):  # the hair's lower edge all round: the fringe, then the side and back hair
        d = np.abs(np.degrees(s / r))
        fringe, side = fringe_edge(d), hairline(d)
        return np.where(d < 52, fringe, np.where(d < 56, np.minimum(fringe, side), side))

    def angle(s):
        return np.abs(np.degrees(s / r))

    for c in (h.around, h.face):
        # under the hair: a darker hair tone, faded in just above its edge
        soft(c, shade(HAIR, -0.3), lambda s, y: ramp(y - edge(s), 0.03, 0.06))
        # a soft shadow on the skin just below the edge (deeper at the nape)
        soft(c, shade(SKIN, -0.22),
             lambda s, y: (0.45 + 0.3 * ramp(angle(s), 100, 130)) * (1 - ramp(edge(s) - y, 0.0, 0.1))
             * (y < edge(s) + 0.03))
        # behind the lock in front of each ear
        soft(c, shade(SKIN, -0.2),
             lambda s, y: 0.32 * ramp(angle(s), 75, 80) * ramp(96 - angle(s), 0, 5) * ramp(y, 4.16, 4.28))
    face(h.band)
