"""Kestrel, wandering blade master. Sword + Bow. Fast, slippery duelist.

A classic blocky avatar: copper-orange hair swept up from the nape into a
long high ponytail tied with a wine-red cord, its spiky ends springing up
over her head like a fountain; a side-swept fringe and long face-framing
locks; calm, sharp teal eyes, a thin scar through her left brow and a
faint confident smirk. A long teal travel coat printed on, a little worn
(darned in places, dusty at the hems), with gold trim and a rolled shawl
collar open over a cream wrap shirt, a leather bow strap across the chest
and a gold kestrel crest on the back; sleeves with turned cuffs, padded
fingerless gloves and a leather archer's bracer on her bow arm; a wine-red
sash at the waist; charcoal trousers, grey linen shin wraps tied off with
wine-red bands and strapped sandal-boots. The coat's split swallow tails
hang behind her legs on sway chains, cupped so they read from the side,
and the sash is knotted at the back of her right hip, its two tails riding
the right coat tail.
"""

import math

from mathutils import Vector

from sky import avatar as A
from sky.avatar import Cloth, Hair, Metal, Style, shade

NAME = "Kestrel"

SKIN = "#e4a77c"
HAIR = "#e2622a"
TEAL = "#1f8588"
TEAL_DEEP = "#145a62"
GOLD = "#e8b44c"
CREAM = "#f0e4ca"
WINE = "#8f1f3d"
CHAR = "#3b3a44"
LEATHER = "#6f4629"
GLOVE = "#3f2a22"
STRAP = "#a57444"
WRAP = "#bcb29e"  # dusty grey linen
DUST = "#b9a98a"
IRIS = "#24c3b5"
LASH = "#2a1719"
BROW = "#8c3417"
LINE = "#25232e"

SASH = (2.1, 2.46)  # the sash around the waist
HEM = 1.42  # the printed coat skirt's hem on the legs
CUFF = (2.48, 2.74)  # the turned-back sleeve cuffs
WRAPS = (0.44, 1.04)  # the linen shin wraps
TAIL_TOP = 2.12  # the coat tails hang from just under the sash
KNOT = (0.55, 2.3)  # the sash knot, at the back of her right hip


# Small helpers ---------------------------------------------------------------------------------


def smoothstep(e0, e1, x):
    t = max(0.0, min(1.0, (x - e0) / (e1 - e0)))
    return t * t * (3 - 2 * t)


def box(a0, b0, a1, b1):
    return [(a0, b0), (a1, b0), (a1, b1), (a0, b1)]


def bezier(p0, p1, p2, p3, n=12):
    """Points along a cubic Bezier curve."""
    out = []
    for i in range(n + 1):
        t = i / n
        a, b, c, d = (1 - t) ** 3, 3 * (1 - t) ** 2 * t, 3 * (1 - t) * t * t, t ** 3
        out.append((a * p0[0] + b * p1[0] + c * p2[0] + d * p3[0], a * p0[1] + b * p1[1] + c * p2[1] + d * p3[1]))
    return out


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


def stitches(c, pts, color, step=0.07, length=0.035, width=0.012, alpha=0.8):
    """A dashed stitch line along a polyline."""
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        ln = math.hypot(x1 - x0, y1 - y0) or 1.0
        ux, uy = (x1 - x0) / ln, (y1 - y0) / ln
        k = step / 2
        while k < ln:
            x, y = x0 + ux * k, y0 + uy * k
            c.stroke([(x - ux * length / 2, y - uy * length / 2), (x + ux * length / 2, y + uy * length / 2)], width,
                     color, alpha)
            k += step


def trim(c, pts, width=0.05, color=GOLD):
    """A gold trimmed edge: a band with a dark outer line and a lit stripe."""
    c.stroke(offset(pts, -width * 0.5 - 0.012), 0.03, shade(TEAL, -0.45), alpha=0.35)
    c.stroke(pts, width, color)
    c.stroke(offset(pts, width * 0.18), width * 0.3, shade(color, 0.4), alpha=0.7)
    for d in (-width / 2, width / 2):
        c.stroke(offset(pts, d), 0.011, shade(color, -0.45), alpha=0.9)


def fold(c, pts, color, width=0.035, alpha=0.5, light=None):
    """A soft cloth fold: a tapered shadow line with an optional lit edge."""
    c.stroke(pts, width, shade(color, -0.22), alpha, taper=(0.25, 1.0))
    if light is not False:
        c.stroke(offset(pts, width * 0.9), width * 0.45, shade(color, 0.22), alpha * 0.7, taper=(0.2, 0.8))


def dust(c, region, y0, height=0.15, steps=5):
    """Road dust settled on a hem at y0, fading out over `height`."""
    a0 = min(a for a, _ in region)
    a1 = max(a for a, _ in region)
    for k in range(steps):
        c.rect_(a0, y0 - 0.05, a1, y0 + height * (k + 1) / steps, DUST, alpha=0.06, clip=region)


def darn(c, x, y, w, h, color, thread=None):
    """A darned tear: a slightly lighter mend, rows of thread across it and
    overcast stitches around its edge."""
    thread = thread or shade(color, 0.3)
    pts = [(x + w / 2 * math.cos(a) * (1 + 0.08 * math.sin(3 * a)), y + h / 2 * math.sin(a))
           for a in (2 * math.pi * i / 20 for i in range(20))]
    c.poly(pts, shade(color, 0.07))
    for k in range(4):
        yy = y - h * 0.32 + h * 0.64 * k / 3
        c.stroke([(x - w * 0.4, yy), (x + w * 0.4, yy + 0.004)], 0.008, thread, alpha=0.7)
    for i in range(0, 20, 2):
        px, py = pts[i]
        c.stroke([(px + (px - x) * 0.18, py + (py - y) * 0.18), (px - (px - x) * 0.18, py - (py - y) * 0.18)], 0.008,
                 shade(thread, -0.1), alpha=0.85)


def button(c, x, y, r=0.035):
    c.ellipse(x, y - 0.006, r * 1.15, r * 1.15, shade(GOLD, -0.55), alpha=0.7)
    c.ellipse(x, y, r, r, GOLD)
    c.ellipse(x - r * 0.3, y + r * 0.3, r * 0.4, r * 0.4, shade(GOLD, 0.6))


def crest(c, x, y, r, color=GOLD, dark=None):
    """The kestrel crest: a falcon rising, wings swept back, in a ring."""
    dark = dark or shade(color, -0.5)

    def shapes(dx, dy, col):
        for sx in (-1, 1):
            c.poly([(x + dx + sx * 0.1 * r, y + dy + 0.3 * r), (x + dx + sx * 0.55 * r, y + dy + 0.36 * r),
                    (x + dx + sx * 0.98 * r, y + dy - 0.32 * r), (x + dx + sx * 0.52 * r, y + dy - 0.02 * r),
                    (x + dx + sx * 0.1 * r, y + dy - 0.08 * r)], col)
        c.poly([(x + dx - 0.09 * r, y + dy - 0.2 * r), (x + dx + 0.09 * r, y + dy - 0.2 * r),
                (x + dx + 0.2 * r, y + dy - 0.78 * r), (x + dx, y + dy - 0.66 * r),
                (x + dx - 0.2 * r, y + dy - 0.78 * r)], col)
        c.ellipse(x + dx, y + dy + 0.05 * r, 0.13 * r, 0.4 * r, col)
        c.ellipse(x + dx, y + dy + 0.5 * r, 0.12 * r, 0.12 * r, col)
        c.poly([(x + dx - 0.04 * r, y + dy + 0.58 * r), (x + dx + 0.04 * r, y + dy + 0.58 * r),
                (x + dx, y + dy + 0.72 * r)], col)
    shapes(0.0, -0.012, dark)
    shapes(0.0, 0.0, color)
    ring = A._arc(x, y, r * 1.18, r * 1.18, 0, 360, 48)
    c.stroke(ring, 0.03 * r / 0.3, dark, alpha=0.8)
    c.stroke(ring, 0.018 * r / 0.3, color)
    for sx in (-1, 1):  # wing bars
        c.stroke([(x + sx * 0.2 * r, y + 0.18 * r), (x + sx * 0.6 * r, y + 0.12 * r)], 0.012, dark, alpha=0.7)
        c.stroke([(x + sx * 0.22 * r, y + 0.04 * r), (x + sx * 0.66 * r, y - 0.08 * r)], 0.012, dark, alpha=0.7)


# The face ----------------------------------------------------------------------------------------


def eye(c, side, glow=None):
    """A calm, sharp anime eye: an almond tilted up at the outer corner, the
    upper lid resting low over a big teal iris, a heavy lash line with a
    flick, a lid crease above."""
    s = side
    cx, cy = s * 0.235, 4.6
    w = 0.172
    inner, outer = cx - s * w * 0.9, cx + s * w
    top, bot = [], []
    n = 16
    for i in range(n + 1):
        t = i / n
        x = inner + (outer - inner) * t
        b = math.sin(math.pi * t)
        top.append((x, cy - 0.014 + 0.076 * b ** 0.55 + 0.05 * t))
        bot.append((x, cy - 0.014 - 0.052 * b ** 1.3 + 0.044 * t))
    white = top + bot[::-1]
    c.poly(white, "#fbf8f3")
    # the upper lid's shadow on the white (the iris darkens at its top itself)
    c.stroke(offset(top, -0.018 * s), 0.04, "#c9b4a8", alpha=0.6, clip=white)
    color = glow or IRIS
    ix, iy = cx + s * 0.006, cy + 0.014
    rx, ry = 0.082, 0.104
    c.ellipse(ix, iy, rx, ry, shade(color, -0.6), clip=white)
    c.ellipse(ix, iy - 0.006, rx * 0.86, ry * 0.87, color, clip=white)
    c.ellipse(ix, iy - ry * 0.48, rx * 0.66, ry * 0.36, shade(color, 0.5), alpha=0.9, clip=white)
    c.ellipse(ix, iy + ry * 0.48, rx * 0.98, ry * 0.52, shade(color, -0.5), alpha=0.75, clip=white)
    if glow:
        # glowing: a lit rim inside the iris edge, a dark-edged white slit, the
        # catchlight lifted clear of it
        c.stroke(A._arc(ix, iy - 0.004, rx * 0.84, ry * 0.86, 0, 360, 40), 0.012, shade(glow, 0.5), clip=white)
        c.ellipse(ix, iy, rx * 0.2, ry * 0.66, shade(glow, -0.65), clip=white)
        c.ellipse(ix, iy, rx * 0.1, ry * 0.6, "#ffffff", clip=white)
        c.ellipse(ix - s * rx * 0.55, iy + ry * 0.42, rx * 0.22, ry * 0.16, "#ffffff", clip=white)
    else:
        c.ellipse(ix, iy + 0.002, rx * 0.34, ry * 0.44, "#0f2a2c", clip=white)
        c.ellipse(ix - s * rx * 0.36, iy + ry * 0.12, rx * 0.3, ry * 0.21, "#ffffff", clip=white)
    c.ellipse(ix + s * rx * 0.34, iy - ry * 0.38, rx * 0.13, ry * 0.09, "#ffffff", alpha=0.9, clip=white)
    # the lash line, heavier toward the outer corner, with a sharp flick
    lid = [(x, y + 0.004) for x, y in top]
    c.stroke(lid[:-1], 0.034, LASH, taper=(0.35, 1.1))
    tip = (outer + s * 0.055, lid[-1][1] + 0.032)
    c.stroke([lid[-4], lid[-2], tip], 0.036, LASH, taper=(1.05, 0.12))
    c.stroke([lid[-5], (outer + s * 0.025, lid[-1][1] + 0.045)], 0.016, LASH, taper=(1.0, 0.1))
    c.stroke([lid[0], (inner - s * 0.012, lid[0][1] - 0.012)], 0.016, LASH, taper=(1.0, 0.3))
    # lid crease and the lower lash
    c.stroke([(x, y + 0.036) for x, y in top[4:14]], 0.01, shade(SKIN, -0.35), alpha=0.6, taper=(0.3, 1.0))
    c.stroke(bot[8:17], 0.012, LASH, alpha=0.65, taper=(0.2, 1.0))


SCAR_GAP = (0.296, 0.328)  # where the scar cuts her left brow (distance from the middle)


def brow(c, side, y=4.815, gap=None):
    """A thin, nearly straight brow lifting a little at the outer end; `gap`
    leaves a break in it (|x| from, to)."""
    s = side
    n = 40
    pts = [(s * (0.1 + 0.28 * t), y - 0.016 + 0.03 * math.sin(math.pi * (0.2 + 0.7 * t)) + 0.026 * t)
           for t in (i / n for i in range(n + 1))]
    runs = [list(range(n + 1))]
    if gap:
        runs = [[i for i in runs[0] if abs(pts[i][0]) < gap[0]], [i for i in runs[0] if abs(pts[i][0]) > gap[1]]]
    for run in runs:  # each piece keeps its share of the taper
        w0, w1 = (1.25 - 0.9 * run[k] / n for k in (0, -1))
        c.stroke([pts[i] for i in run], 0.034, BROW, taper=(w0, w1))


def face(c, glow=None):
    for side in (1, -1):
        eye(c, side, glow=glow)
        brow(c, side, gap=SCAR_GAP if side < 0 else None)
        c.ellipse(side * 0.25, 4.445, 0.07, 0.026, "#ec8a72", alpha=0.2)  # a faint blush
    # a thin pale scar through her left brow, crossing its gap
    c.stroke([(-0.336, 4.895), (-0.28, 4.74)], 0.013, "#f7d3ba", taper=(0.6, 1.0))
    c.stroke([(-0.326, 4.895), (-0.27, 4.74)], 0.006, shade(SKIN, -0.3), alpha=0.6)
    # freckles across the nose
    for x, y in ((-0.1, 4.47), (-0.065, 4.455), (-0.12, 4.445), (0.1, 4.47), (0.065, 4.455), (0.12, 4.445)):
        c.ellipse(x, y, 0.007, 0.007, "#b4603a", alpha=0.55)
    c.stroke([(0.012, 4.48), (0.0, 4.45)], 0.011, shade(SKIN, -0.32), alpha=0.55)  # nose hint
    # a faint confident smirk, raised at her left corner
    mouth = [(0.075, 4.33), (0.02, 4.322), (-0.04, 4.328), (-0.085, 4.352)]
    c.stroke(mouth, 0.016, "#5c2523", taper=(0.5, 1.0))
    c.stroke([(-0.085, 4.352), (-0.098, 4.342)], 0.01, "#5c2523", alpha=0.6)
    c.ellipse(-0.005, 4.302, 0.03, 0.008, "#c9786a", alpha=0.35)


# Accessory styles ----------------------------------------------------------------------------------


class CoatTail(Cloth):
    """One coat tail: teal with soft folds, a gold-trimmed inner edge, outer
    edge and swallowtail hem. The trim follows the tail's real outline: the
    UVs are a front projection over the piece's extents, measured in
    model() (fit)."""

    size = (176, 240)

    def __init__(self, color, side, **kw):
        super().__init__(color, folds=4, **kw)
        self.side = side
        self.lo = self.hi = None

    def fit(self, mb):
        vs = [v.co for v in mb.bm.verts]
        self.lo = Vector([min(v[i] for v in vs) for i in range(3)])
        self.hi = Vector([max(v[i] for v in vs) for i in range(3)])

    def uv(self, p):
        return ((self.hi.x - p.x) / (self.hi.x - self.lo.x), (p.y - self.lo.y) / (self.hi.y - self.lo.y))

    def paint(self, c):
        c.gradient((0.5, 0.0), (0.5, 1.0), shade(self.color, -0.22), shade(self.color, 0.06))
        ts = [i / 20 for i in range(21)]
        us = [i / 20 for i in range(21)]
        for k, u in enumerate((0.22, 0.48, 0.74)):  # folds hanging from the waist
            pts = [self.uv(tail_point(self.side, u + 0.03 * math.sin(t * 3 + k), t)) for t in ts[2:19]]
            c.stroke(pts, 0.05, shade(self.color, -0.28), alpha=0.5, taper=(0.2, 1.3))
            c.stroke(offset(pts, 0.04), 0.018, shade(self.color, 0.25), alpha=0.4, taper=(0.2, 1.0))
        for k in range(5):  # road dust settled along the hem
            t0 = 1.0 - 0.12 * (k + 1) / 5
            band = ([self.uv(tail_point(self.side, u, t0)) for u in us] +
                    [self.uv(tail_point(self.side, u, 1.05)) for u in us[::-1]])
            c.poly(band, DUST, alpha=0.06)
        inner = [self.uv(tail_point(self.side, 0.0, t)) for t in ts]
        outer = [self.uv(tail_point(self.side, 1.0, t)) for t in ts]
        hem = [self.uv(tail_point(self.side, u, 1.0)) for u in us]
        for edge in (inner, outer, hem):
            c.stroke(edge, 0.09, GOLD)
            c.stroke(edge, 0.03, shade(GOLD, 0.4), alpha=0.7)
        c.stroke([self.uv(tail_point(self.side, u, 0.93)) for u in us], 0.014, shade(GOLD, -0.4), alpha=0.8)
        c.material(0.0, 0.62)


def lens(c, u, v, w, h, color, alpha, bend=0.0, vertical=False):
    """A streak of light pointed at both ends: w long, h thick at the middle,
    its middle line bowed by `bend`; along u, or along v if `vertical`."""
    top, bot = [], []
    for i in range(17):
        s = i / 16
        k = math.sin(math.pi * s)
        along = (s - 0.5) * w
        mid = bend * (1 - (2 * s - 1) ** 2)
        top.append((along, mid + h * 0.5 * k))
        bot.append((along, mid - h * 0.5 * k ** 1.6))
    pts = top + bot[::-1]
    c.poly([(u + b, v + a) if vertical else (u + a, v + b) for a, b in pts], color, alpha)


# The cap's shine: separate crescents around the front and sides (u = 0.5 is
# the front; the back, near 0 and 1, stays unlit): (u, v offset, length).
STREAKS = [(0.25, 0.012, 0.06), (0.34, -0.016, 0.085), (0.435, 0.02, 0.08), (0.53, -0.01, 0.095),
           (0.625, 0.018, 0.08), (0.715, -0.016, 0.075), (0.79, 0.008, 0.055)]


class Copper(Hair):
    """Copper anime hair: darker toward the ends, fine dark and light
    strands, separate tapered crescents of shine around the front and sides
    at `shine` (the back stays unlit) and, with `gather` = (v at the nape, v
    at the tie), strands at the back sweeping up into the ponytail's tie."""

    def __init__(self, color, gather=None, **kw):
        super().__init__(color, **kw)
        self.gather = gather

    def base_coat(self, c):
        """The gradient and the fine strands."""
        c.gradient((0.5, 0.0), (0.5, 1.0), shade(self.color, -0.32), shade(self.color, 0.12))
        rng = A.np.random.default_rng(self.strands)
        for _ in range(self.strands):
            x = rng.uniform(0, 1)
            c.stroke([(x, 0.0), (x + rng.uniform(-0.02, 0.02), rng.uniform(0.5, 0.97))], 0.01,
                     shade(self.color, -0.4), alpha=0.5, taper=(1.0, 0.2))
        for _ in range(self.strands // 2):
            x = rng.uniform(0, 1)
            c.stroke([(x, 0.2), (x + rng.uniform(-0.02, 0.02), rng.uniform(0.6, 0.95))], 0.008,
                     shade(self.color, 0.35), alpha=0.35, taper=(0.2, 1.0))

    def paint(self, c):
        self.base_coat(c)
        if self.gather:
            v0, v1 = self.gather
            for k in range(5):  # converging on the back seam (u = 0 = 1) as they rise
                u = 0.03 + 0.036 * k
                for x0, sgn in ((u, 1), (1 - u, -1)):
                    x1 = x0 - sgn * u * 0.8
                    pts = [(x0, v0 - 0.04), (x0 - sgn * u * 0.25, (v0 + v1) / 2), (x1, v1)]
                    c.stroke(pts, 0.011, shade(self.color, -0.42), alpha=0.6, taper=(1.0, 0.3))
                    c.stroke(offset(pts, 0.012), 0.006, shade(self.color, 0.3), alpha=0.35, taper=(0.3, 1.0))
        for u, dv, w in STREAKS:
            lens(c, u, self.shine + dv, w, 0.036, self.shine_color, 0.58, bend=0.008)
            lens(c, u - 0.004, self.shine + dv + 0.007, w * 0.5, 0.012, shade(self.shine_color, 0.4), 0.5)
        c.material(0.0, 0.5)


class PonyHair(Copper):
    """The ponytail: the same copper, its shine in long streaks down the
    sides (u near 0.25 and 0.75 face a side camera) instead of a band."""

    size = (128, 256)

    def paint(self, c):
        self.base_coat(c)
        for u, w in ((0.22, 0.03), (0.3, 0.026), (0.7, 0.026), (0.78, 0.03)):
            lens(c, u, 0.61, 0.62, w, self.shine_color, 0.5, vertical=True)
        c.material(0.0, 0.5)


class Knot(Style):
    """Wine-red silk gathered into a knot: shaded with fine creases."""

    size = (96, 64)

    def paint(self, c):
        c.gradient((0.5, 0.0), (0.5, 1.0), shade(self.color, -0.3), shade(self.color, 0.15))
        for u in (0.1, 0.27, 0.43, 0.6, 0.78, 0.92):
            c.stroke([(u, 0.15), (u + 0.04, 0.85)], 0.025, shade(self.color, -0.35), alpha=0.5, taper=(0.3, 1.0))
        c.material(0.0, 0.45)


# Geometry ---------------------------------------------------------------------------------------------


def tail_point(side, u, t):
    """A point on the middle surface of one coat tail. side +1 is her right;
    u runs from the inner (split) edge at 0 to the outer edge at 1; t from
    the top (0) to the hem (1), extrapolating beyond. The tail flares out a
    little (staying inside the legs' outer faces) and falls well away from
    the legs, cupped so its middle billows back while its outer edge curls
    forward around them (it reads as a broad teal swallowtail from the
    side); its hem is cut on a slant, longest at the split."""
    tt = max(t, 0.0)
    x_in = 0.07 + 0.06 * t
    x_out = 0.92 + 0.06 * t
    x = side * (x_in + (x_out - x_in) * u)
    hem = 0.72 + 0.3 * u ** 0.85
    y = TAIL_TOP + (hem - TAIL_TOP) * t
    z = 0.585 + 0.42 * tt ** 1.3 + 0.16 * math.sin(math.pi * u) * tt ** 0.6 - 0.32 * u * u * tt
    return Vector((x, y, z))


def tail_normal(side, u, t):
    e = 0.01
    du = tail_point(side, u + e, t) - tail_point(side, u - e, t)
    dt = tail_point(side, u, t + e) - tail_point(side, u, t - e)
    n = du.cross(dt).normalized()
    return n if n.z > 0 else -n


def model(av):
    av.style("hair", Copper(HAIR, shine=0.8, strands=34, shine_color="#ffa66a"))
    av.style("pony", PonyHair(HAIR, strands=30, shine_color="#ffa66a"))
    av.style("cord", Knot(WINE))
    av.style("bead", Metal(GOLD, size=(32, 32)))
    av.style("coatR", CoatTail(TEAL, 1))
    av.style("coatL", CoatTail(TEAL, -1))
    av.style("ribbon", Cloth(WINE, folds=6, size=(96, 192)))
    av.style("knot", Knot(WINE))
    hairdo(av)
    ponytail(av)
    coat_tails(av)


def hairline(angle):
    """How low the hair reaches around the head (degrees from the front):
    the fringe's base at the front, above the temples, over the ears at the
    sides, and lifting again at the back where it is all swept up into the
    ponytail (the nape shows below it)."""
    d = abs((angle + 180) % 360 - 180)
    return 5.0 - 0.44 * smoothstep(48, 85, d) + 0.12 * smoothstep(115, 180, d)


# The fringe: (from: angle, height), (to: angle, height), half width. Parted
# on her right and swept toward her left in pointed locks that lift a little
# off the forehead; the tips stop at the brows, with clear gaps between.
BANGS = [
    ((24, 5.2), (-4, 4.85), 0.135),
    ((8, 5.2), (-26, 4.875), 0.13),
    ((-10, 5.18), (-46, 4.91), 0.125),
    ((-28, 5.15), (-64, 4.95), 0.11),
    ((38, 5.18), (22, 4.87), 0.125),
    ((52, 5.12), (52, 4.85), 0.11),
]
# Long locks framing the face, (angle, height) down each side (her right; mirrored).
SIDELOCKS = [([(62, 5.08), (67, 4.76), (65, 4.44), (57, 4.14)], 0.14),
             ([(82, 5.02), (86, 4.68), (82, 4.36)], 0.13)]

# The ponytail's tie sits on the back of the crown, facing up and back.
TIE_P, TIE_N = A.Avatar.head_point(180, 5.1, out=0.24)


def head_normal(p, e=0.003):
    """The head's outward normal near p."""
    g = Vector([A.head_sdf(p + d * e) - A.head_sdf(p - d * e) for d in (Vector((1, 0, 0)), Vector((0, 1, 0)),
                                                                          Vector((0, 0, 1)))])
    return g.normalized()


def blade(mb, pts, half_width, half_thick, style, sub=3, ring=10, normal=head_normal):
    """A flat, pointed lock of hair along `pts`: an elliptical section wide
    across `normal(p)` (by default along the head's surface) and thin along
    it, tapering to a point: bangs, side locks, the ponytail's spiky tips."""
    pts = [Vector(p) for p in pts]
    path = []
    for a, b in zip(pts, pts[1:]):
        for k in range(sub):
            path.append(a.lerp(b, k / sub))
    path.append(pts[-1])
    n = len(path)
    verts, faces = [], []
    for i, p in enumerate(path[:-1]):
        s = i / (n - 1)
        t = (path[i + 1] - path[max(i - 1, 0)]).normalized()
        nrm = normal(p)
        nrm = (nrm - t * nrm.dot(t)).normalized()
        bi = t.cross(nrm).normalized()
        w = half_width * (1 - s) ** 0.75 + 0.004
        h = half_thick * (1 - 0.55 * s) + 0.003
        for k in range(ring):
            a = 2 * math.pi * k / ring
            verts.append(tuple(p + bi * w * math.cos(a) + nrm * h * math.sin(a)))
    verts.append(tuple(path[-1]))
    tip = len(verts) - 1
    for i in range(n - 2):
        for k in range(ring):
            j = (k + 1) % ring
            faces.append((i * ring + k, i * ring + j, (i + 1) * ring + j, (i + 1) * ring + k))
    last = (n - 2) * ring
    for k in range(ring):
        faces.append((last + k, last + (k + 1) % ring, tip))
    faces.append(tuple(reversed(range(ring))))
    mb.polys(verts, faces, style, smooth=True)


def hairdo(av):
    """Sleek hair swept back from the brow: a rounded dome and a shell over
    the sides and back (lifting at the nape), wide flat pointed locks for
    the fringe and the side locks, and a cone gathering it all at the back
    of the crown into the ponytail's tie; melted into one and carved off
    the scalp."""
    mb = av.builder()
    # the dome's widest ring sits in the head's rounded top corner, so it
    # meets the scalp at an angle everywhere (never grazing it)
    mb.sphere((0, 5.08, 0.03), (0.665, 0.34, 0.65), "hair", segments=32, rings=16)
    before = set(mb.bm.verts)
    A.shell(mb, "hair", 48, 312, hairline, 5.0, r_in=0.56, r_out=0.655, steps=40, rows=6)
    for v in set(mb.bm.verts) - before:  # pulled tight to the scalp toward the nape
        r = math.hypot(v.co.x, v.co.z)
        if r > A.HEAD_R:
            ang = math.degrees(math.atan2(v.co.x, -v.co.z))
            k = smoothstep(105, 150, abs(ang)) * (1 - smoothstep(hairline(ang), hairline(ang) + 0.24, v.co.y))
            v.co.x, v.co.z = (c * (r - (r - 0.618) * k) / r for c in (v.co.x, v.co.z))
    for (a0, y0), (a1, y1), hw in BANGS:
        pts = []
        for i in range(7):
            s = i / 6
            ang = a0 + (a1 - a0) * (1 - (1 - s) ** 1.6)
            y = y0 + (y1 - y0) * s ** 1.3
            out = 0.035 + 0.045 * s + 0.03 * math.sin(math.pi * s)
            pts.append(av.head_point(ang, y, out=out)[0])
        blade(mb, pts, hw, 0.042, "hair")
    for sx in (-1, 1):
        for ctrl, hw in SIDELOCKS:
            pts = [av.head_point(sx * ang, y, out=0.045 + 0.04 * min(k, 1))[0] for k, (ang, y) in enumerate(ctrl)]
            blade(mb, pts, hw, 0.042, "hair", sub=4)
    # gathered toward the tie along the crown's normal; a neck of gathered
    # hair runs on through the cord (thicker than the cord's hole, so the
    # cord bites into it) into the ponytail
    base, _ = av.head_point(180, 4.98, out=-0.25)
    A.lock(mb, [tuple(base), tuple(TIE_P - TIE_N * 0.17), tuple(TIE_P - TIE_N * 0.1)], 0.21, "hair",
           segments=14, tip=0.1)
    mb.cylinder(tuple(TIE_P + TIE_N * 0.01), 0.095, 0.24, "hair", rotation=_along(TIE_N), segments=16)
    cap = A.melt(mb, voxel=0.018, smooth=3, tris=3800, carve_head=True)
    style = av.styles["hair"]
    style.shine = _v(cap, 5.25)  # the shine sits on the dome's upper curve
    style.gather = (_v(cap, hairline(180)), _v(cap, 5.2))
    av.piece(cap, bone="Neck", name="Hair")

    # the tie: a wine-red cord wound twice around the gathered hair, half
    # sunk into it, a gold bead on each side
    rot = _along(TIE_N)
    mb = av.builder()
    mb.torus(tuple(TIE_P - TIE_N * 0.035), 0.105, 0.045, "cord", rotation=rot, segments=22, sides=8)
    mb.torus(tuple(TIE_P + TIE_N * 0.035), 0.098, 0.038, "cord", rotation=rot, segments=22, sides=8)
    for sx in (-1, 1):
        mb.sphere(tuple(TIE_P - TIE_N * 0.035 + Vector((sx * 0.16, 0, 0))), 0.04, "bead", segments=12, rings=8)
    av.piece(mb, bone="Neck", name="HairTie")


def _along(direction):
    return Vector((0, 1, 0)).rotation_difference(Vector(direction).normalized()).to_matrix()


def _v(mb, y):
    """The swatch v of height y on a piece with wrap UVs (v runs over the
    piece's height)."""
    ys = [v.co.y for v in mb.bm.verts]
    return (y - min(ys)) / (max(ys) - min(ys))


# The ponytail's center line (from inside the tie) and its radius there: it
# springs up out of the tie thick, arcs smoothly over and falls well behind
# her back, ending clear above the crest on her coat.
PONY = [(TIE_P + TIE_N * 0.09, 0.115), (TIE_P + TIE_N * 0.27, 0.17), (Vector((0, 5.47, 1.0)), 0.19),
        (Vector((0, 5.17, 1.29)), 0.19), (Vector((0, 4.66, 1.32)), 0.2), (Vector((0, 4.1, 1.23)), 0.165),
        (Vector((0, 3.66, 1.12)), 0.125), (Vector((0, 3.3, 1.02)), 0.04)]
# Spiky tips springing out of the top of the arc and curling over, a
# fountain of hair above her head from the front: (angle from straight up,
# toward her right; length from the arc's middle; half width; lean back).
FOUNTAIN_AT = Vector((0, 5.47, 1.01))
FOUNTAIN = [(-58, 0.42, 0.08, 0.1), (-26, 0.4, 0.09, 0.2), (6, 0.36, 0.085, 0.15), (32, 0.41, 0.09, 0.18),
            (62, 0.4, 0.08, 0.06)]


def ponytail(av):
    """The long high ponytail on a sway chain from the head, ending in a few
    points; its tip hangs well clear of her back."""
    chain = av.sway("Pony", "Neck", [tuple(TIE_P), (0, 5.47, 1.02), (0, 5.02, 1.31), (0, 4.3, 1.29),
                                     (0, 3.75, 1.14), (0, 3.2, 1.0)], stiffness=0.3, damping=0.2, limit=45,
                    behind=1)
    mb = av.builder()
    for (a, ra), (b, rb) in zip(PONY, PONY[1:]):
        mb.limb(tuple(a), tuple(b), ra, rb, "pony", segments=14)
    for pts, r in (([(0.05, 4.05, 1.25), (0.13, 3.62, 1.15), (0.14, 3.3, 1.06)], 0.095),
                   ([(-0.06, 4.0, 1.24), (-0.13, 3.62, 1.13), (-0.11, 3.36, 1.06)], 0.085),
                   ([(0.0, 3.8, 1.16), (0.02, 3.42, 1.07), (0.0, 3.2, 1.0)], 0.075)):
        A.lock(mb, pts, r, "pony", segments=8, tip=0.01)
    pony = A.melt(mb, voxel=0.02, smooth=4, tris=2000)
    for ang, length, hw, back in FOUNTAIN:  # added after the melt, so they stay crisp
        pts, p = [], FOUNTAIN_AT.copy()
        for k, (bend, run) in enumerate(((0.6, 0.05), (0.85, 0.12), (1.15, 0.13), (1.5, 0.12), (1.9, 0.1))):
            a = math.radians(ang * bend)  # each step turns further out: the tips curl over
            p = p + Vector((math.sin(a), math.cos(a), back)).normalized() * run * length / 0.52
            pts.append(p.copy())
        blade(pony, pts, hw, hw * 0.65, "pony", sub=3, ring=8, normal=lambda p: Vector((0, 0, -1)))
    av.piece(pony, sway=chain, name="Ponytail")


def coat_tails(av):
    """The coat's two swallow tails behind her legs, each on its own sway
    chain from the hips; the sash knot at the back of her right hip and its
    two tails, which ride the right coat tail (one chain, so they never
    pass through it)."""
    for side, key in ((1, "R"), (-1, "L")):
        chain = av.sway(f"Coat{key}", "Root", [tuple(tail_point(side, 0.5, t)) for t in (0.0, 0.34, 0.67, 1.0)],
                        stiffness=0.28, damping=0.2, limit=55, behind=1)
        rows = []
        for i in range(13):
            t = i / 12
            us = [j / 8 for j in range(9)]
            rows.append([tuple(tail_point(side, u, t)) for u in (us if side > 0 else us[::-1])])
        mb = av.builder()
        A.sheet(mb, rows, 0.05, f"coat{key}")
        av.styles[f"coat{key}"].fit(mb)
        av.piece(mb, sway=chain, name=f"CoatTail{key}")
        if side > 0:
            mb = av.builder()
            # over the inner half, so the tail's outer half shows teal from the side
            for u0, u1, t1, out, wave in ((0.5, 0.3, 1.2, 0.052, 0.03), (0.62, 0.44, 1.07, 0.1, -0.03)):
                ribbon(mb, u0, u1, -0.15, t1, 0.2, out, wave)
            av.piece(mb, sway=chain, name="SashTails")
    # the knot: two soft loops (deep enough to show from the side) and the
    # gathered middle, a little sunk into the sash
    x, y = KNOT
    mb = av.builder()
    for sx, rot in ((-1, -18), (1, 14)):
        mb.sphere((x + sx * 0.16, y + 0.03, 0.6), (0.15, 0.1, 0.11), "knot", rotation=(0, 0, rot),
                  segments=16, rings=10)
    mb.sphere((x, y, 0.61), (0.085, 0.105, 0.1), "knot", segments=16, rings=10)
    av.piece(mb, bone="Root", name="SashKnot")


def ribbon(mb, u0, u1, t0, t1, width, out, wave):
    """One sash tail lying over the right coat tail (offset `out` from its
    middle surface), drifting from u0 to u1 and ending in a notched cut."""
    rows = []
    n = 16
    for i in range(n + 1):
        k = (i / n) ** 1.15
        t = t0 + (t1 - t0) * k
        uc = u0 + (u1 - u0) * k + wave * math.sin(k * math.pi * 1.6)
        du = width / (0.85 + 0.04 * t) / 2
        lift = 0.03 + (out - 0.03) * smoothstep(0.0, 0.09, k)  # tucked into the knot at the top
        row = []
        for j in (-1, 0, 1):
            u = uc + j * du
            tt = t - (0.05 if i == n and j == 0 else 0.0)
            p = tail_point(1, u, tt) + tail_normal(1, u, tt) * lift
            row.append(tuple(p))
        rows.append(row)
    A.sheet(mb, rows, 0.026, "ribbon")


# The painted outfit -------------------------------------------------------------------------------


def paint(av, p):
    p.head.fill(SKIN)
    for limb in p.limbs.values():
        limb.fill(TEAL)
    paint_torso(p)
    paint_arms(p)
    paint_legs(p)
    paint_head(p)


def opening_x(y):
    """Where the coat's open front edge is (her right; mirror for the left):
    wide at the collar, closing to the sash, opening again below it."""
    lo, hi = SASH
    if y >= hi:
        return 0.11 + (0.38 - 0.11) * (y - hi) / (4.0 - hi)
    return 0.11 + 0.02 * (hi - y) / (hi - 2.0)


def sash_band(faces, knot_face=None):
    lo, hi = SASH
    for f in faces:
        a0, _, a1, _ = f.bounds()
        f.rect_(a0, lo, a1, hi, WINE)
        f.gradient((0, hi), (0, lo), shade(WINE, 0.14), shade(WINE, -0.22), clip=box(a0, lo, a1, hi))
        f.rect_(a0, lo, a1, lo + 0.025, shade(WINE, -0.45))
        f.rect_(a0, hi - 0.02, a1, hi, shade(WINE, 0.32), alpha=0.8)
        if f is knot_face:
            continue
        for k, y in enumerate((2.19, 2.29, 2.38)):  # wrapped folds
            f.stroke([(a0, y + 0.012 * k), ((a0 + a1) / 2, y - 0.012), (a1, y + 0.01)], 0.022, shade(WINE, -0.32),
                     alpha=0.55)
            f.stroke([(a0, y + 0.03), (a1, y + 0.026)], 0.01, shade(WINE, 0.3), alpha=0.4)


def strap_line(f, a, b, width=0.16):
    """The leather bow strap across a face, from a to b."""
    f.stroke([a, b], width + 0.03, shade(TEAL, -0.5), alpha=0.35)
    f.stroke([a, b], width, LEATHER)
    f.stroke(offset([a, b], width * 0.25), width * 0.3, shade(LEATHER, 0.2), alpha=0.6)
    for d in (-width * 0.36, width * 0.36):
        stitches(f, offset([a, b], d), shade(STRAP, 0.3), step=0.06, length=0.03, width=0.01, alpha=0.8)
    for d in (-width / 2, width / 2):
        f.stroke(offset([a, b], d), 0.012, shade(LEATHER, -0.5), alpha=0.9)


STRAP_A, STRAP_B = (-0.74, 4.0), (1.0, 2.56)  # from her left shoulder to her right hip, front and back


def paint_torso(p):
    t = p.torso
    lo, hi = SASH
    for f in t.sides:
        f.gradient((0, 4.0), (0, 2.0), shade(TEAL, 0.12), shade(TEAL, -0.16))
    f = t.front
    # the shirt between the lapels: a cream wrap shirt, crossed left over right
    shirt = [(-opening_x(4.0), 4.0), (opening_x(4.0), 4.0), (opening_x(hi), hi), (-opening_x(hi), hi)]
    f.poly(shirt, CREAM)
    f.gradient((0, 4.0), (0, hi), CREAM, shade(CREAM, -0.16), clip=shirt)
    f.poly([(-0.2, 4.0), (0.2, 4.0), (0.05, 3.62)], SKIN)
    f.gradient((0, 4.0), (0, 3.7), shade(SKIN, -0.3), SKIN, clip=[(-0.2, 4.0), (0.2, 4.0), (0.05, 3.62)])
    f.stroke([(0.2, 4.0), (0.05, 3.62)], 0.06, shade(CREAM, -0.08))  # the under collar
    f.stroke([(-0.21, 4.0), (0.05, 3.6), (0.11, 3.42)], 0.07, shade(CREAM, 0.12))  # the over collar
    f.stroke(offset([(-0.21, 4.0), (0.05, 3.6), (0.11, 3.42)], -0.04), 0.012, shade(CREAM, -0.45), alpha=0.8)
    f.stroke([(0.11, 3.42), (0.04, 2.9), (0.0, hi)], 0.014, shade(CREAM, -0.4), alpha=0.7)  # the wrap's edge
    fold(f, [(-0.2, 3.3), (-0.08, 3.05), (-0.06, 2.75)], CREAM, alpha=0.45)
    fold(f, [(0.2, 3.2), (0.1, 2.9)], CREAM, alpha=0.4)
    # a broad rolled shawl collar with gold edges, and the gold-trimmed open front
    for sx in (-1, 1):
        lapel = [(sx * opening_x(4.0), 4.0)] + [(sx * x, y) for x, y in bezier((0.72, 4.0), (0.71, 3.62), (0.5, 3.12),
                                                                          (opening_x(2.92), 2.92))]
        f.poly(lapel, shade(TEAL, -0.12))
        f.gradient((sx * 0.3, 3.6), (sx * 0.6, 3.6), shade(TEAL, 0.12), shade(TEAL, -0.2), clip=lapel)
        f.stroke(lapel[1:], 0.07, shade(TEAL, -0.5), alpha=0.3)  # the collar's shadow on the coat
        fold(f, [(sx * 0.5, 3.95), (sx * 0.47, 3.6), (sx * 0.34, 3.22)], shade(TEAL, -0.12), alpha=0.4)  # its roll
        trim(f, lapel[1:], 0.035)
        trim(f, [(sx * opening_x(4.0), 4.0), (sx * opening_x(hi), hi)], 0.05)
        button(f, sx * 0.52, 3.22)
        # soft shaping below the lapels
        fold(f, [(sx * 0.86, 3.55), (sx * 0.7, 3.1), (sx * 0.72, hi)], TEAL, alpha=0.45, light=False)
    # a small gold feather pin on her left lapel
    f.poly([(-0.6, 3.86), (-0.53, 3.72), (-0.565, 3.7)], GOLD)
    f.stroke([(-0.6, 3.86), (-0.55, 3.7)], 0.01, shade(GOLD, -0.5))
    strap_line(f, STRAP_A, STRAP_B)
    bx, by = 0.16, 3.33  # its buckle on the chest
    f.poly([(bx - 0.09, by + 0.1), (bx + 0.11, by + 0.04), (bx + 0.09, by - 0.1), (bx - 0.11, by - 0.04)],
           shade(GOLD, -0.4))
    f.poly([(bx - 0.06, by + 0.065), (bx + 0.08, by + 0.025), (bx + 0.06, by - 0.065), (bx - 0.08, by - 0.025)],
           LEATHER)
    f.stroke([(bx - 0.08, by + 0.085), (bx + 0.1, by + 0.03)], 0.02, shade(GOLD, 0.3))
    # below the sash the coat opens over the trousers
    f.poly([(-opening_x(lo), lo), (opening_x(lo), lo), (opening_x(2.0), 2.0), (-opening_x(2.0), 2.0)], CHAR)
    for sx in (-1, 1):
        trim(f, [(sx * opening_x(lo), lo), (sx * opening_x(2.0), 2.0)], 0.05)
    sash_band(t.sides, knot_face=t.back)
    # the sash on the front: folds drawn toward a flat gold-bordered middle
    tuck = [(0.1, hi), (-0.14, lo)]
    for k in range(8):  # the wrapped-over layer, lit at the tuck and fading out around her
        x = -0.12 - 0.6 * (k + 1) / 8
        f.poly([(0.1, hi), (-0.14, lo), (x - 0.12, lo), (x, hi)], shade(WINE, 0.1), alpha=0.08)
    f.stroke(offset(tuck, 0.02), 0.04, shade(WINE, -0.45), alpha=0.6)
    f.stroke(offset(tuck, -0.012), 0.016, shade(WINE, 0.35), alpha=0.7)
    for y in (2.2, 2.33):
        f.stroke([(-0.02 - (y - lo) * 0.6, y), (-0.45, y + 0.03)], 0.02, shade(WINE, -0.3), alpha=0.5)
    f.ellipse(-0.04, 2.29, 0.075, 0.075, shade(GOLD, -0.5))
    f.ellipse(-0.04, 2.29, 0.064, 0.064, GOLD)
    f.ellipse(-0.04, 2.29, 0.036, 0.036, WINE)
    f.ellipse(-0.06, 2.315, 0.02, 0.014, shade(GOLD, 0.6))
    # sides: a side seam and the strap's end at her right hip
    for side in (t.right, t.left):
        side.stroke([(0.0, hi), (0.0, 3.9)], 0.02, shade(TEAL, -0.35), alpha=0.6)
    t.right.rect_(-0.5, 2.48, 0.5, 2.64, LEATHER)
    t.right.rect_(-0.5, 2.48, 0.5, 2.495, shade(LEATHER, -0.5))
    t.right.rect_(-0.5, 2.625, 0.5, 2.64, shade(LEATHER, -0.5))
    # back: a curved yoke with gold piping, seams, the crest, the strap, the knot's gathers
    b = t.back
    yoke = [(-1.0, 3.62), (-0.5, 3.55), (0.0, 3.52), (0.5, 3.55), (1.0, 3.62)]
    b.poly(yoke + [(1.0, 4.0), (-1.0, 4.0)], shade(TEAL, 0.05))
    b.stroke(yoke, 0.03, GOLD)
    b.stroke(offset(yoke, -0.03), 0.02, shade(TEAL, -0.4), alpha=0.4)
    b.stroke([(0.0, hi), (0.0, 3.52)], 0.022, shade(TEAL, -0.35), alpha=0.6)
    for sx in (-1, 1):
        b.stroke([(sx * 0.82, 3.6), (sx * 0.62, 3.1), (sx * 0.66, hi)], 0.024, shade(TEAL, -0.3), alpha=0.55)
    crest(b, 0.0, 2.8, 0.21)  # low enough to leave a gap under the ponytail's tip
    strap_line(b, STRAP_A, STRAP_B)
    kx, ky = KNOT
    for ang in (150, 170, 190, 210, 20, 0, -20):  # silk gathered into the knot
        a = math.radians(ang)
        b.stroke([(kx + math.cos(a) * 0.12, ky + math.sin(a) * 0.05), (kx + math.cos(a) * 0.5, ky + math.sin(a) * 0.1)],
                 0.024, shade(WINE, -0.35), alpha=0.6, taper=(1.0, 0.2))
    b.rect_(-1.0, 2.0, 1.0, lo, shade(TEAL, -0.08))
    # top: the shoulders, a stand collar around the neck, the strap over her left shoulder
    top = t.top
    top.ellipse(0, 0, 0.7, 0.5, shade(TEAL, -0.1))
    top.ellipse(0, 0, 0.62, 0.44, shade(TEAL, -0.3))
    top.rect_(STRAP_A[0] - 0.09, -0.5, STRAP_A[0] + 0.09, 0.5, LEATHER)
    t.bottom.fill(CHAR)


def paint_arms(p):
    lo, hi = CUFF
    for arm in p.arms():
        sx = 1 if arm.cx > 0 else -1
        bow_arm = sx < 0  # the bracer is on her left (bow) arm
        for f in arm.sides:
            f.gradient((0, 4.0), (0, 2.5), shade(TEAL, 0.14), shade(TEAL, -0.12))
        for f in (arm.front, arm.back):  # shadowed toward the body
            f.gradient((-sx * 0.5, 3.0), (-sx * 0.1, 3.0), shade(TEAL, -0.3), shade(TEAL, -0.05), alpha=0.5,
                       clip=box(-0.5, 2.0, 0.5, 4.0))
        # gold piping down the outer seam and around the shoulder
        o = arm.outer
        o.stroke([(0.0, 2.75), (0.0, 4.0)], 0.035, GOLD)
        o.stroke([(-0.012, 2.75), (-0.012, 4.0)], 0.01, shade(GOLD, 0.5), alpha=0.7)
        arm.top.fill(shade(TEAL, 0.1))
        arm.top.rect_(-0.5, -0.018, 0.5, 0.018, GOLD)  # the piping runs on over the shoulder
        for f in (arm.front, arm.back):  # sleeve folds and the elbow crease
            fold(f, [(-0.32, 3.24), (0.05, 3.12), (0.32, 3.2)], TEAL, alpha=0.5)
            fold(f, [(-0.28, 2.94), (0.24, 2.88)], TEAL, alpha=0.45)
        fold(arm.inner, [(-0.35, 2.92), (0.0, 2.88), (0.35, 2.94)], TEAL, alpha=0.5)
        # the turned-back cuff (on the bow arm, the bracer covers the forearm)
        for f in arm.sides:
            a0, _, a1, _ = f.bounds()
            top_y = 2.62 if bow_arm else hi
            f.rect_(a0, lo, a1, top_y, TEAL_DEEP)
            f.gradient((0, top_y), (0, lo), shade(TEAL_DEEP, 0.25), shade(TEAL_DEEP, -0.1),
                       clip=box(a0, lo, a1, top_y))
            f.rect_(a0, top_y - 0.03, a1, top_y, GOLD)
            f.rect_(a0, lo, a1, lo + 0.025, GOLD)
            f.rect_(a0, top_y - 0.04, a1, top_y - 0.03, shade(TEAL, -0.5), alpha=0.5)
        if not bow_arm:
            button(o, -0.18, 2.61, 0.028)
            button(o, 0.18, 2.61, 0.028)
        else:
            # the archer's bracer: stiff leather laced on the inner side, gold rivets
            for f in arm.sides:
                a0, _, a1, _ = f.bounds()
                f.rect_(a0, 2.6, a1, 2.92, LEATHER)
                f.gradient((0, 2.92), (0, 2.6), shade(LEATHER, 0.2), shade(LEATHER, -0.2), clip=box(a0, 2.6, a1, 2.92))
                f.rect_(a0, 2.6, a1, 2.62, shade(LEATHER, -0.5))
                f.rect_(a0, 2.9, a1, 2.92, shade(LEATHER, -0.5))
                stitches(f, [(a0, 2.64), (a1, 2.64)], shade(STRAP, 0.3), step=0.06, length=0.03)
                stitches(f, [(a0, 2.88), (a1, 2.88)], shade(STRAP, 0.3), step=0.06, length=0.03)
            for y in (2.67, 2.76, 2.85):
                arm.inner.stroke([(-0.12, y), (0.12, y + 0.06)], 0.016, CREAM)
                arm.inner.stroke([(-0.12, y + 0.06), (0.12, y)], 0.016, shade(CREAM, -0.15))
            arm.inner.rect_(-0.03, 2.62, 0.03, 2.9, shade(LEATHER, -0.45))
            for y in (2.69, 2.83):
                for z in (-0.25, 0.25):
                    button(o, z, y, 0.022)
            o.poly([(-0.12, 2.74), (0.0, 2.81), (0.12, 2.74), (0.0, 2.68)], shade(LEATHER, 0.25))  # tooled diamond
        # fingerless gloves: dark leather over the hand, bare fingers below
        for f in arm.sides:
            a0, _, a1, _ = f.bounds()
            f.rect_(a0, 2.0, a1, lo, GLOVE)
            f.gradient((0, lo), (0, 2.1), shade(GLOVE, 0.18), shade(GLOVE, -0.1), clip=box(a0, 2.1, a1, lo))
            f.rect_(a0, 2.32, a1, 2.35, shade(GLOVE, 0.25))  # a thin wrist strap
            f.rect_(a0, 2.0, a1, 2.13, SKIN)
            f.rect_(a0, 2.13, a1, 2.15, shade(GLOVE, -0.4))
        for f in (arm.front, arm.back):  # a padded knuckle plate over the back of the hand
            f.rect_(-0.42, 2.15, 0.42, 2.24, shade(GLOVE, 0.15))
            f.gradient((0, 2.24), (0, 2.15), shade(GLOVE, 0.24), shade(GLOVE, 0.04), clip=box(-0.42, 2.15, 0.42, 2.24))
            for x in (-0.14, 0.14):
                f.stroke([(x, 2.155), (x, 2.235)], 0.012, shade(GLOVE, -0.35), alpha=0.7)
            f.rect_(-0.42, 2.24, 0.42, 2.25, shade(GLOVE, -0.4), alpha=0.7)
            stitches(f, [(-0.4, 2.235), (0.4, 2.235)], shade(STRAP, 0.2), step=0.06, length=0.028, width=0.009)
        for f in (arm.front, arm.back, arm.outer):
            for x in (-0.25, 0.0, 0.25):
                f.stroke([(x, 2.0), (x, 2.12)], 0.012, shade(SKIN, -0.3), alpha=0.6)
        o.rect_(-0.07, 2.305, 0.07, 2.365, GOLD)  # the strap's buckle, on the outside only
        o.rect_(-0.04, 2.32, 0.04, 2.35, GLOVE)
        if not bow_arm:  # a darned tear on her sword arm's sleeve
            darn(o, 0.12, 3.42, 0.17, 0.11, TEAL)
        arm.bottom.fill(shade(SKIN, -0.08))


def paint_legs(p):
    w0, w1 = WRAPS
    for leg in p.legs():
        sx = 1 if leg.cx > 0 else -1  # +1 on her right leg
        for f in leg.sides:
            f.gradient((0, 2.0), (0, w1), shade(CHAR, 0.1), shade(CHAR, -0.15))
        # trouser folds and the knee crease
        for f in leg.sides:
            fold(f, [(-0.3, 1.3), (0.0, 1.24), (0.3, 1.3)], CHAR, alpha=0.6)
            fold(f, [(-0.25, 1.62), (0.2, 1.55)], CHAR, alpha=0.45)
        # the coat skirt: over the outer side and the back, and the outer part
        # of the front; open toward the middle, gold-trimmed, a pocket flap
        f = leg.front
        edge = [(sx * opening_x(2.0) - leg.cx, 2.0), (sx * 0.3 - leg.cx, HEM)]
        front = [edge[0], (sx * 0.5, 2.0), (sx * 0.5, HEM), edge[1]]
        coat_skirt(f, front)
        for face in (leg.outer, leg.back):
            a0, _, a1, _ = face.bounds()
            coat_skirt(face, box(a0, HEM, a1, 2.0))
        trim(f, edge, 0.05)
        for face in (f, leg.outer, leg.back):  # the gold hem
            a0, _, a1, _ = face.bounds()
            region = front if face is f else box(a0, HEM, a1, 2.0)
            face.rect_(a0, HEM, a1, HEM + 0.07, GOLD, clip=region)
            face.rect_(a0, HEM + 0.045, a1, HEM + 0.07, shade(GOLD, 0.4), alpha=0.6, clip=region)
            face.rect_(a0, HEM - 0.01, a1, HEM, shade(GOLD, -0.5), clip=box(a0, HEM - 0.01, a1, HEM + 0.02))
            face.rect_(a0, HEM - 0.04, a1, HEM - 0.01, LINE, alpha=0.25)  # its shadow on the trousers
        f.rect_(sx * 0.02, 1.72, sx * 0.4, 1.86, shade(TEAL, -0.08))  # the pocket flap
        f.stroke([(sx * 0.02, 1.72), (sx * 0.4, 1.72)], 0.016, GOLD)
        f.stroke([(sx * 0.02, 1.71), (sx * 0.4, 1.71)], 0.01, shade(TEAL, -0.5), alpha=0.6)
        if sx < 0:  # a darned tear in the skirt
            darn(leg.outer, 0.16, 1.68, 0.16, 0.1, TEAL)
        # the back vent between the coat tails
        leg.back.stroke([(-sx * 0.5, 2.0), (-sx * 0.5, HEM)], 0.03, shade(TEAL, -0.4), alpha=0.6)
        # linen shin wraps, wound in a spiral that runs on around all four faces
        for face in leg.sides:
            a0, _, a1, _ = face.bounds()
            face.rect_(a0, w0, a1, w1, WRAP)
            face.gradient((0, w1), (0, w0), shade(WRAP, 0.1), shade(WRAP, -0.16), clip=box(a0, w0, a1, w1))
        pitch = 0.12
        for face, start, flip in ((leg.front, 0.0, False), (leg.right, 1.0, False), (leg.back, 2.0, True),
                                  (leg.left, 3.0, True)):
            a0, _, a1, _ = face.bounds()
            ends = (a1, a0) if flip else (a0, a1)
            for k in range(-2, 9):
                ya = w0 + k * pitch + pitch * start / 4
                yb = ya + pitch / 4
                line = [(ends[0], ya), (ends[1], yb)]
                face.stroke(offset(line, -0.022), 0.034, shade(WRAP, -0.38), alpha=0.65, clip=box(a0, w0, a1, w1))
                face.stroke(offset(line, 0.012), 0.014, shade(WRAP, 0.3), alpha=0.7, clip=box(a0, w0, a1, w1))
            face.rect_(a0, w1, a1, w1 + 0.025, LINE, alpha=0.3)
            # the wraps tied off at the top with a wine-red band
            face.rect_(a0, w1 - 0.06, a1, w1, WINE)
            face.rect_(a0, w1 - 0.06, a1, w1 - 0.05, shade(WINE, -0.45))
            face.rect_(a0, w1 - 0.016, a1, w1, shade(WINE, 0.3))
        leg.outer.ellipse(0.0, w1 - 0.03, 0.036, 0.036, shade(GOLD, -0.5))  # a gold bead on the tie
        leg.outer.ellipse(0.0, w1 - 0.03, 0.03, 0.03, GOLD)
        leg.outer.ellipse(-0.008, w1 - 0.022, 0.011, 0.011, shade(GOLD, 0.6))
        # strapped sandal-boots: a thick sole, dark leather, tan straps
        for face in leg.sides:
            a0, _, a1, _ = face.bounds()
            face.rect_(a0, 0.0, a1, w0, LEATHER)
            face.gradient((0, w0), (0, 0.08), shade(LEATHER, 0.15), shade(LEATHER, -0.25), clip=box(a0, 0.08, a1, w0))
            face.rect_(a0, 0.0, a1, 0.08, shade(GLOVE, -0.2))
            face.rect_(a0, 0.08, a1, 0.095, shade(LEATHER, 0.3), alpha=0.6)
            face.rect_(a0, w0 - 0.07, a1, w0, shade(LEATHER, -0.2))
            face.rect_(a0, w0 - 0.055, a1, w0 - 0.02, STRAP)
            face.rect_(a0, 0.14, a1, 0.2, STRAP)
            face.rect_(a0, 0.14, a1, 0.15, shade(STRAP, -0.4), alpha=0.7)
        leg.front.ellipse(0, 0.12, 0.34, 0.025, shade(LEATHER, 0.35), alpha=0.5)  # toe shine
        lo_ = leg.outer
        lo_.rect_(-0.09, w0 - 0.06, 0.05, w0, GOLD)  # an ankle buckle
        lo_.rect_(-0.06, w0 - 0.04, 0.02, w0 - 0.02, LEATHER)
        leg.bottom.fill(shade(GLOVE, -0.3))


def coat_skirt(face, region):
    """The teal coat fabric on one leg face, with shading and folds."""
    a0 = min(a for a, _ in region)
    a1 = max(a for a, _ in region)
    face.poly(region, TEAL)
    face.gradient((0, 2.0), (0, HEM), shade(TEAL, 0.0), shade(TEAL, -0.2), clip=region)
    for k, x in enumerate((0.3, 0.72)):
        xx = a0 + (a1 - a0) * x
        face.stroke([(xx, 1.95), (xx + 0.03, HEM + 0.1)], 0.05, shade(TEAL, -0.3), alpha=0.45, taper=(0.2, 1.3),
                    clip=region)
        face.stroke([(xx + 0.06, 1.9), (xx + 0.08, HEM + 0.18)], 0.018, shade(TEAL, 0.25), alpha=0.4,
                    taper=(0.2, 1.0), clip=region)
    dust(face, region, HEM)


def paint_head(p):
    h = p.head
    h.top.fill(shade(HAIR, -0.2))
    band = h.band
    circ = 2 * math.pi * A.HEAD_R
    # hair color under the hairdo, so no skin shows at its edges
    pts = []
    n = 72
    for i in range(n + 1):
        s = -circ / 2 + circ * i / n
        ang = math.degrees(s / A.HEAD_R)
        pts.append((s, hairline(ang) - 0.03))
    band.poly(pts + [(circ / 2, 5.25), (-circ / 2, 5.25)], shade(HAIR, -0.25))
    # fine wisps at the nape, left loose below the swept-up hair
    for s, ln, lean in ((0.1, 0.13, 0.015), (0.22, 0.09, 0.025), (0.34, 0.14, 0.02), (0.48, 0.08, 0.03)):
        for sgn in (1, -1):
            x = sgn * (circ / 2 - s)
            y = hairline(math.degrees(x / A.HEAD_R)) - 0.02
            band.stroke([(x, y), (x - sgn * lean * 0.4, y - ln * 0.6), (x - sgn * lean, y - ln)], 0.024,
                        shade(HAIR, -0.1), taper=(1.0, 0.12))
    # the fringe's soft shadow on the forehead
    band.gradient((0, 5.0), (0, 4.86), shade(SKIN, -0.25), SKIN, clip=box(-0.6, 4.86, 0.6, 5.0))
    h.bottom.fill(shade(SKIN, -0.2))
    face(band)
