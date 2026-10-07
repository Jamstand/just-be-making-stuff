"""Vex, shadow ninja. Scythe + Gauntlets. Hits hard and fast, but fragile.

A classic blocky avatar: messy spiky black hair swept back with one violet
streak down a bang, narrow glowing violet eyes over a dark cloth mask, and a
small scar through his left brow. A charcoal ninja jacket printed with a
purple wrap collar, crossed straps with a silver buckle and a purple sash
knotted at the hip; bandage-wrapped forearms and dark gloves with silver
knuckle plates; tapered trousers with purple piping, shin wraps and
split-toe ninja shoes. A long tattered purple scarf is wound twice around his
neck and knotted at the back, its two torn tails trailing behind him.
"""

import math

import numpy as np

from sky import avatar as A
from sky.avatar import Hair, Style, Vector, anime_eye, lock, shade, sheet, spike

NAME = "Vex"

SKIN = "#efc8a8"
GARB = "#2a2834"
PANTS = "#25232e"
UNDER = "#3b3947"  # the mesh undershirt in the collar's V
PURPLE = "#6c2fb8"
PURPLE_DEEP = "#43207a"
STRAP = "#453c52"
SILVER = "#c9ced8"
WRAP = "#bdb5a9"  # forearm bandages
SHIN = "#5f5a6b"  # shin wraps
GLOVE = "#1f1d27"
SHOE = "#1b1a22"
MASK = "#26242f"
HAIR = "#1e1c28"
STREAK = "#9a4dff"
IRIS = "#a65cff"
LINE = "#15131b"

STREAK_ANGLE = 27  # the violet bang, on his right
KNOT_X = -0.56  # the sash knot, on his left hip
SASH_ENDS = ((-0.05, 0.15), (0.1, 0.13))  # (x from the knot, width) of its two hanging ends
STRAP_X = 0.72  # where the crossed straps come over the shoulders
BACK_S = math.pi * A.HEAD_R  # the back of the head on the band (s = +-BACK_S)


# Painting helpers ---------------------------------------------------------------------------


def strip(c, p0, p1, width, color, alpha=1.0, clip=None):
    """A band from the segment p0 -> p1 out to its left (width > 0) or
    right (width < 0)."""
    dx, dy = p1[0] - p0[0], p1[1] - p0[1]
    ln = math.hypot(dx, dy) or 1.0
    nx, ny = -dy / ln * width, dx / ln * width
    c.poly([p0, p1, (p1[0] + nx, p1[1] + ny), (p0[0] + nx, p0[1] + ny)], color, alpha, clip=clip)


def strap(c, p0, p1, width=0.13, color=STRAP):
    """A leather strap centered on p0 -> p1: a dark lower edge, a lit upper
    edge and stitching down both sides."""
    strip(c, p0, p1, -width / 2, shade(color, -0.3))
    strip(c, p0, p1, -width / 2 + 0.03, color)
    strip(c, p0, p1, width / 2, shade(color, 0.16))
    strip(c, p0, p1, width / 2 - 0.02, color)
    dx, dy = p1[0] - p0[0], p1[1] - p0[1]
    ln = math.hypot(dx, dy)
    ux, uy = dx / ln, dy / ln
    for side in (1, -1):  # stitching
        off = side * (width / 2 - 0.035)
        ox, oy = -uy * off, ux * off
        k = 0.03
        while k < ln - 0.03:
            a = (p0[0] + ux * k + ox, p0[1] + uy * k + oy)
            b = (p0[0] + ux * (k + 0.035) + ox, p0[1] + uy * (k + 0.035) + oy)
            c.stroke([a, b], 0.012, shade(color, 0.35), alpha=0.8)
            k += 0.075


def diamond(c, x, y, r, color, alpha=1.0):
    c.poly([(x, y + r), (x + r, y), (x, y - r), (x - r, y)], color, alpha)


def crescent(c, x, y, r, color, cut=(0.42, 0.22), inner=0.8, alpha=1.0):
    """A crescent moon: a disc of radius r minus a disc of radius r * inner
    shifted by `cut` (in units of r)."""
    cx2, cy2, r2 = x + cut[0] * r, y + cut[1] * r, r * inner
    phi = math.atan2(cut[1], cut[0])
    outer = []
    for th in np.linspace(phi, phi + 2 * math.pi, 73):
        px_, py_ = x + r * math.cos(th), y + r * math.sin(th)
        if math.hypot(px_ - cx2, py_ - cy2) > r2:
            outer.append((px_, py_))
    inner_pts = []
    for th in np.linspace(phi, phi + 2 * math.pi, 73):
        px_, py_ = cx2 + r2 * math.cos(th), cy2 + r2 * math.sin(th)
        if math.hypot(px_ - x, py_ - y) < r:
            inner_pts.append((px_, py_))
    if math.dist(inner_pts[0], outer[-1]) > math.dist(inner_pts[-1], outer[-1]):
        inner_pts.reverse()
    c.poly(outer + inner_pts, color, alpha)


def perimeter(limb):
    """Each side face of a limb with t(a): how far along the way around the
    limb (front -> right -> back -> left) its coordinate a sits, so painted
    wraps meet at the corners."""
    w, d = limb.w, A.DEPTH
    hw, hd = w / 2, d / 2
    return [(limb.front, lambda a: a + hw), (limb.right, lambda a: w + a + hd),
            (limb.back, lambda a: w + d + hw - a), (limb.left, lambda a: 2 * w + d + hd - a)]


def wraps(limb, y0, y1, color, spacing=0.105, seed=1, climb=(1.4, 1.2, 1.4, -3.0)):
    """Bandages wound up a limb between y0 and y1: one strip spiralling up,
    each turn overlapping the last. `climb` shares each turn's rise between
    the front, outer side, back and inner side (summing to 1): it climbs
    steeply across the faces you see and drops back a little on the hidden
    inner side, so the turns read as slanted overlaps rather than stripes.
    The strip's end is tucked in on the inner side."""
    w, d = limb.w, A.DEPTH
    outer_right = limb.cx > 0
    shares = (climb[0], climb[1] if outer_right else climb[3], climb[2], climb[3] if outer_right else climb[1])
    lens = (w, d, w, d)
    starts = (0.0, w, w + d, 2 * w + d)
    cum = np.cumsum((0.0,) + shares[:-1])
    rng = np.random.default_rng(seed)
    n = int((y1 - y0) / spacing) + 4
    tones = [shade(color, rng.uniform(-0.1, 0.05)) for _ in range(n + 4)]
    for i, (f, t) in enumerate(perimeter(limb)):
        a0, _, a1, _ = f.bounds()
        box = [(a0, y0), (a1, y0), (a1, y1), (a0, y1)]
        f.rect_(a0, y0, a1, y1, color)

        def edge(k, a, i=i, t=t):
            return y0 + (k - 1 + cum[i] + shares[i] * (t(a) - starts[i]) / lens[i]) * spacing

        def inside(pts):  # keeps a band's shape within the wrapped stretch
            return [(a, min(max(b, y0), y1)) for a, b in pts]

        for k in range(0, n):
            lo0, lo1 = edge(k, a0), edge(k, a1)
            f.poly(inside([(a0, lo0), (a1, lo1), (a1, lo1 + spacing), (a0, lo0 + spacing)]), tones[k])
            f.gradient((0, lo0 + spacing * 0.5), (0, lo0 + spacing * 1.05), tones[k], shade(tones[k], 0.12),
                       alpha=0.5, clip=inside([(a0, lo0 + spacing * 0.5), (a1, lo1 + spacing * 0.5),
                                               (a1, lo1 + spacing), (a0, lo0 + spacing)]))
            # the turn below tucks under this one: a shadow under its edge, a
            # lit lip along it
            f.poly(inside([(a0, lo0 - 0.03), (a1, lo1 - 0.03), (a1, lo1), (a0, lo0)]), shade(color, -0.4),
                   alpha=0.35)
            f.stroke([(a0, lo0), (a1, lo1)], 0.022, shade(color, -0.45), alpha=0.85, clip=box)
            f.stroke([(a0, lo0 + 0.02), (a1, lo1 + 0.02)], 0.01, shade(color, 0.3), alpha=0.6, clip=box)
        f.stroke([(a0, y1), (a1, y1)], 0.03, shade(color, -0.5), alpha=0.8)
        f.stroke([(a0, y0), (a1, y0)], 0.02, shade(color, -0.5), alpha=0.6)
    # the tucked end, on the inner side near the top: a short tab with a
    # slanted cut, lifting off the turn beneath
    i = 3 if outer_right else 1
    f, t = perimeter(limb)[i]
    a0, _, a1, _ = f.bounds()
    k = math.floor((y1 - y0) / spacing - cum[i])  # the turn that comes in just under the top edge

    def ey(a):
        return y0 + (k - 1 + cum[i] + shares[i] * (t(a) - starts[i]) / lens[i]) * spacing

    tip = 0.08 * (1 if a1 > 0 else -1)
    root = a0 if t(a0) < t(a1) else a1  # where this turn comes in
    cut0, cut1 = tip - 0.06 * (1 if root < 0 else -1), tip + 0.06 * (1 if root < 0 else -1)
    tab = [(root, ey(root) + 0.012), (cut0, ey(cut0) + 0.012), (cut1, ey(cut1) + spacing * 0.9),
           (root, ey(root) + spacing * 0.9)]
    f.poly([(a + 0.02 * (1 if root < 0 else -1), b - 0.02) for a, b in tab], LINE, alpha=0.35)
    f.poly(tab, shade(color, 0.1))
    f.stroke([tab[1], tab[2]], 0.016, shade(color, -0.5), alpha=0.85)
    f.stroke([tab[0], tab[1]], 0.012, shade(color, -0.45), alpha=0.7)


def vgrad(f, y0, y1, c0, c1, alpha=1.0):
    """A vertical gradient over a face between two heights only (a bare
    gradient() covers the whole face)."""
    a0, _, a1, _ = f.bounds()
    f.gradient((0, y0), (0, y1), c0, c1, alpha=alpha, clip=[(a0, y0), (a1, y0), (a1, y1), (a0, y1)])


def folds(c, lines, color, width=0.035, alpha=0.6, light=True):
    """Cel-shaded cloth folds: a dark tapered crease with a lit edge beside
    it."""
    for pts in lines:
        c.stroke(pts, width, shade(color, -0.32), alpha=alpha, taper=(1.3, 0.2))
        if light:
            c.stroke([(x + 0.025, y + 0.012) for x, y in pts], width * 0.45, shade(color, 0.28),
                     alpha=alpha * 0.6, taper=(1.0, 0.1))


def unwrap(pts):
    """Points on a wrapped swatch (u in 0..1 around) made continuous, with
    the shifts (-1, 0, +1) that bring every part of them onto the swatch."""
    out = [pts[0]]
    for u, v in pts[1:]:
        pu = out[-1][0]
        u += round(pu - u)
        out.append((u, v))
    lo, hi = min(p[0] for p in out), max(p[0] for p in out)
    return out, [s for s in (-1, 0, 1) if lo + s < 1 and hi + s > 0]


def wpoly(c, pts, color, alpha=1.0, clip=None):
    pts, shifts = unwrap(pts)
    for s in shifts:
        c.poly([(u + s, v) for u, v in pts], color, alpha,
               clip=[(u + s, v) for u, v in clip] if clip else None)


def wstroke(c, pts, width, color, alpha=1.0, taper=None):
    pts, shifts = unwrap(pts)
    for s in shifts:
        c.stroke([(u + s, v) for u, v in pts], width, color, alpha, taper=taper)


# The face ---------------------------------------------------------------------------------------


def brow(c, side, color, y, angle, width, length, arch, x=A.EYE_X, clip=None):
    """anime_brow's stroke, with an optional clip polygon."""
    inner = (side * (x - length * 0.55), y - angle * 0.5)
    outer = (side * (x + length * 0.5), y + angle * 0.5)
    mid = ((inner[0] + outer[0]) / 2, (inner[1] + outer[1]) / 2 + arch)
    c.stroke([inner, mid, outer], width, color, taper=(1.2, 0.45), clip=clip)


def mask_top(s):
    """Height of the mask's upper edge around the head: up over the bridge
    of the nose, down under the cheekbones, level around the back."""
    return 4.455 + 0.05 * math.exp(-(s / 0.11) ** 2) - 0.015 * math.exp(-((abs(s) - 0.3) / 0.14) ** 2)


def face(c, glow=None):
    # the dark cloth mask over the nose and mouth, all the way around
    s_all = np.linspace(-1.95, 1.95, 97)
    top = [(s, mask_top(s)) for s in s_all]
    region = top + [(1.95, 3.9), (-1.95, 3.9)]
    c.poly(region, MASK)
    c.gradient((0, 4.0), (0, 4.5), shade(MASK, -0.18), shade(MASK, 0.12), clip=region)
    # the cloth pulled over the nose: lit along the bridge, falling away in
    # soft shadow to either side and sagging in a fold under it
    c.stroke([(0.0, 4.47), (0.0, 4.37)], 0.05, shade(MASK, 0.2), alpha=0.6, taper=(0.5, 1.0))
    for sx in (1, -1):
        c.poly([(sx * 0.035, 4.45), (sx * 0.08, 4.36), (sx * 0.34, 4.25), (sx * 0.4, 4.33), (sx * 0.2, 4.41)],
               shade(MASK, -0.35), alpha=0.35)
        c.stroke([(sx * 0.05, 4.3), (sx * 0.16, 4.25), (sx * 0.24, 4.18)], 0.04, shade(MASK, -0.3), alpha=0.35,
                 taper=(1.0, 0.2))
    c.stroke([(-0.1, 4.31), (0.0, 4.29), (0.1, 4.31)], 0.03, shade(MASK, -0.35), alpha=0.4, taper=(0.3, 0.3))
    # purple hem along the top edge, and its shadow on the skin above
    c.stroke([(s, y + 0.012) for s, y in top], 0.022, LINE, alpha=0.25)
    c.stroke(top, 0.03, PURPLE)
    c.stroke([(s, y - 0.012) for s, y in top], 0.008, shade(PURPLE, -0.4), alpha=0.8)
    # eyes: narrow, cold and violet (or glowing, with `glow`) under low, hard
    # brows; a short scar cuts through the middle of his left brow (the brow
    # is clipped either side of it, so the decal stays transparent there)
    p0, p1 = (-0.288, 4.885), (-0.226, 4.728)
    dx, dy = p1[0] - p0[0], p1[1] - p0[1]
    ln = math.hypot(dx, dy)
    ux, uy, nx, ny = dx / ln, dy / ln, -dy / ln, dx / ln
    a0, a1 = (p0[0] - ux * 0.3, p0[1] - uy * 0.3), (p1[0] + ux * 0.3, p1[1] + uy * 0.3)
    halves = [[(a0[0] + k * nx * g, a0[1] + k * ny * g), (a1[0] + k * nx * g, a1[1] + k * ny * g),
               (a1[0] + k * nx, a1[1] + k * ny), (a0[0] + k * nx, a0[1] + k * ny)] for k, g in ((1, 0.024), (-1, 0.024))]
    for side in (1, -1):
        anime_eye(c, side, IRIS, shape="narrow", glow=glow, size=1.15, look=-side * 0.004)
        for clip in ([None] if side > 0 else halves):
            brow(c, side, LINE, y=4.765, angle=0.09, width=0.044, length=0.21, arch=0.006, clip=clip)
    c.stroke([p0, p1], 0.026, "#b9706c", taper=(0.35, 0.7))
    c.stroke([(p0[0] + 0.003, p0[1] - 0.01), (p1[0] - 0.004, p1[1] + 0.014)], 0.011, "#f3c9bd", alpha=0.75,
             taper=(0.3, 0.5))


# Accessory styles ---------------------------------------------------------------------------------


class StreakHair(Hair):
    """Black anime hair with one violet streak: a stripe at `u` down one
    bang, from its tip (`tip`) to its root (`top`), set once the hair is
    built. Soft and matte, so the dark hair reads as hair, not foil."""

    def __init__(self, color, streak, **kw):
        super().__init__(color, **kw)
        self.streak, self.u, self.width, self.tip, self.top = streak, None, 0.07, 0.0, 1.0

    def paint(self, c):
        c.gradient((0.5, 0.0), (0.5, 1.0), shade(self.color, -0.3), shade(self.color, 0.1))
        rng = np.random.default_rng(23)
        for _ in range(self.strands):
            x = rng.uniform(0, 1)
            c.stroke([(x, 0.0), (x + rng.uniform(-0.03, 0.03), rng.uniform(0.45, 0.95))], 0.012,
                     shade(self.color, -0.38), alpha=0.6, taper=(1.0, 0.2))
        # the shine: short slivers along the locks over the bangs and the
        # front of the cap (fewer round the back), never a ring
        x = 0.0
        while x < 1.0:
            front = abs(x - 0.5) < 0.3
            if front or rng.uniform() < 0.4:
                ln = rng.uniform(0.06, 0.1)
                y = self.shine + rng.uniform(-0.035, 0.035)
                lean = rng.uniform(-0.012, 0.012)
                c.stroke([(x + lean, y - ln / 2), (x, y), (x - lean * 0.5, y + ln / 2)], rng.uniform(0.018, 0.026),
                         self.shine_color, alpha=0.75, taper=(0.15, 0.15))
            x += rng.uniform(0.03, 0.055)
        c.material(0.0, 0.75)
        if self.u is None:
            return
        u, w, tip, top = self.u, self.width, self.tip, self.top

        def half(v):  # the lock's shape: pointed at the tip, pinched in at the root
            q = min(max((v - tip) / max(top - tip, 1e-3), 0.0), 1.0)
            return w / 2 * (0.75 + 0.25 * q if q < 0.7 else 0.925 - 0.55 * (q - 0.7) / 0.3)

        vs = np.linspace(0, top, 24)
        pts = [(u - half(v) + 0.006 * math.sin(v * 9), v) for v in vs]
        pts += [(u + half(v) + 0.006 * math.sin(v * 9 + 1), v) for v in vs[::-1]]
        c.poly(pts, self.streak)
        c.gradient((u, tip), (u, top), shade(self.streak, 0.12), shade(self.streak, -0.2), clip=pts)
        fade = [(a, max(b, top - 0.07)) for a, b in pts]  # a short fade into the black at its root
        c.gradient((u, top - 0.07), (u, top), shade(self.streak, -0.2), shade(self.color, 0.05), clip=fade)
        c.stroke([(u - 0.006, tip), (u - 0.003, top - 0.03)], 0.007, shade(self.streak, -0.45), alpha=0.6)
        c.stroke([(u + 0.008, tip + 0.03), (u + 0.006, top - 0.08)], 0.006, shade(self.streak, 0.35), alpha=0.6)


class Turn:
    """One turn of the scarf around the neck: a flat band (about `thick`
    deep and 2 * `half` tall, its top tucked in toward the neck and its
    bottom flared) along an oval of radii rx, rz, gently bunched. `ys` (its
    height all the way round) is settled when it is built."""

    def __init__(self, rx, rz, thick, half, seed, lean=0.05, bunch=(0.06, 0.03), segs=48):
        rng = np.random.default_rng(seed)
        self.p1, self.p2 = rng.uniform(0, 2 * math.pi, 2)
        self.rx, self.rz, self.thick, self.half, self.lean, self.bunch, self.segs = rx, rz, thick, half, lean, bunch, segs
        self.ths = [2 * math.pi * i / segs for i in range(segs)]
        self.ys = None

    def y(self, th):
        f = (th % (2 * math.pi)) / (2 * math.pi) * self.segs
        i = int(f) % self.segs
        return self.ys[i] + (self.ys[(i + 1) % self.segs] - self.ys[i]) * (f - int(f))

    def point(self, th, ph, y=None):
        """The point at angle th around the neck and ph around the band's
        section (-pi/2 its bottom edge, 0 its outer face, pi/2 its top)."""
        y = self.y(th) if y is None else y
        c = Vector((self.rx * math.sin(th), y, -self.rz * math.cos(th)))
        n = Vector((math.sin(th) / self.rx, 0.0, -math.cos(th) / self.rz)).normalized()
        k = self.thick * (1 + self.bunch[0] * math.sin(3 * th + self.p1) + self.bunch[1] * math.sin(5 * th + self.p2))
        return c + n * (k * math.cos(ph) - self.lean * math.sin(ph)) + Vector((0, self.half * math.sin(ph), 0))


class Scarf(Style):
    """The wound scarf (around a vertical axis), painted turn by turn from
    its geometry: each band cel-shaded (a dark underside where it curls
    under, a lit top edge) with long diagonal folds where the cloth twists,
    a crease shadow where the upper turn laps over the lower, and the knot
    at the back gathered in folds."""

    size = (384, 112)

    def __init__(self, color, **kw):
        super().__init__(color, **kw)
        self.turns, self.frame, self.knot = [], None, None

    def uv(self, p):
        """Where a point of the scarf lands on the swatch: the builder's wrap
        projection about the piece's center."""
        cx, cz, lo, hy = self.frame
        th = math.atan2(p.x - cx, -(p.z - cz))
        return (0.5 - th / (2 * math.pi), (p.y - lo) / hy)

    def band(self, c, turn, ph0, ph1, color, alpha=1.0, n=96):
        """Paints the stretch of a turn's section between ph0 and ph1 all the
        way around."""
        for k in range(8):
            ths = np.linspace(2 * math.pi * k / 8, 2 * math.pi * (k + 1) / 8, n // 8 + 1)
            pts = [self.uv(turn.point(th, ph0)) for th in ths] + [self.uv(turn.point(th, ph1)) for th in ths[::-1]]
            wpoly(c, pts, color, alpha)

    def paint(self, c):
        col = self.color
        c.fill(shade(col, -0.05))
        if not self.frame:
            c.material(0.0, 0.8)
            return
        rng = np.random.default_rng(5)
        for turn in self.turns:  # lower turn first: the upper one laps over it
            self.band(c, turn, -1.75, 1.75, col)
            self.band(c, turn, 0.55, 1.75, shade(col, 0.1), alpha=0.8)  # lit toward the top
            self.band(c, turn, -1.75, -0.55, shade(col, -0.4))  # cel-shaded underside
            self.band(c, turn, -0.55, -0.4, shade(col, -0.4), alpha=0.45)
            # long twist folds, angled across the band
            th = rng.uniform(0, 0.5)
            while th < 2 * math.pi:
                sweep = rng.uniform(0.22, 0.32)
                pts = [self.uv(turn.point(th + sweep * q, -1.2 + 2.3 * q)) for q in np.linspace(0, 1, 9)]
                lit = [self.uv(turn.point(th + 0.045 + sweep * q, -1.0 + 2.1 * q)) for q in np.linspace(0, 1, 9)]
                wstroke(c, pts, rng.uniform(0.01, 0.014), shade(col, -0.35), alpha=0.6, taper=(0.2, 0.5))
                wstroke(c, lit, 0.006, shade(col, 0.25), alpha=0.5, taper=(0.2, 0.3))
                th += 2 * math.pi / 7 * rng.uniform(0.8, 1.2)
        if self.knot:  # the knot at the back: rounded, lit on top, folds gathered into it
            (ku, kv), ru, rv = self.knot
            for s in (-1, 0, 1):
                k = (ku + s, kv)
                c.ellipse(k[0], k[1] - rv * 0.08, ru * 1.04, rv * 1.04, shade(col, -0.45))
                c.ellipse(k[0], k[1], ru, rv, shade(col, -0.02))
                c.ellipse(k[0] - ru * 0.1, k[1] + rv * 0.28, ru * 0.75, rv * 0.55, shade(col, 0.14))
                c.ellipse(k[0] + ru * 0.1, k[1] - rv * 0.55, ru * 0.8, rv * 0.4, shade(col, -0.35), alpha=0.7)
                for a in (-50, -15, 20, 150, 190, 220):
                    ca, sa = math.cos(math.radians(a)), math.sin(math.radians(a))
                    c.stroke([(k[0] + ca * ru * 0.25, k[1] + sa * rv * 0.25), (k[0] + ca * ru * 0.9, k[1] + sa * rv * 0.9)],
                             0.01, shade(col, -0.4), alpha=0.7, taper=(0.3, 1.0))
        c.material(0.0, 0.8)


class ScarfTail(Style):
    """A trailing tail, painted in the ribbon's own coordinates (s across,
    v up from the hem; see sheet_uvs): lengthwise folds, a shadowed edge, two
    dark stripes near the end, a frayed darker hem, and optionally a tear in
    its outer edge (s = 1) between heights `tear`."""

    projection = "front"  # replaced by the ribbon's own grid
    size = (96, 288)

    def __init__(self, color, grid, tear=None, **kw):
        super().__init__(color, **kw)
        self.grid, self.tear = grid, tear

    def paint(self, c):
        col = self.color
        c.gradient((0.5, 1.0), (0.5, 0.0), shade(col, -0.04), shade(col, -0.24))
        c.gradient((0.0, 0.5), (0.3, 0.5), shade(col, -0.32), shade(col, -0.04), alpha=0.6,
                   clip=[(0, 0), (0.3, 0), (0.3, 1), (0, 1)])  # the edge turning away from the light
        rng = np.random.default_rng(9)
        for u in (0.3, 0.56, 0.78):  # lengthwise folds
            pts = [(u + 0.04 * math.sin(v * 7 + u * 9), v) for v in np.linspace(0.96, 0.04, 12)]
            c.stroke(pts, 0.06, shade(col, -0.3), alpha=0.45, taper=(0.3, 1.2))
            c.stroke([(x + 0.06, v) for x, v in pts], 0.022, shade(col, 0.28), alpha=0.4, taper=(0.2, 1.0))
        for v in (0.16, 0.235):  # two dark stripes near the end
            c.rect_(0, v, 1, v + 0.035, PURPLE_DEEP, alpha=0.9)
            c.rect_(0, v + 0.035, 1, v + 0.042, shade(col, 0.2), alpha=0.5)
        c.gradient((0.5, 0.0), (0.5, 0.1), shade(col, -0.55), shade(col, -0.2),
                   clip=[(0, 0), (1, 0), (1, 0.1), (0, 0.1)])  # the frayed hem
        for _ in range(9):
            u = rng.uniform(0.05, 0.95)
            c.stroke([(u, 0.0), (u + rng.uniform(-0.03, 0.03), rng.uniform(0.05, 0.11))], 0.014,
                     shade(col, -0.6), alpha=0.7, taper=(1.0, 0.2))
        if self.tear:  # a ragged, darker edge where it was torn
            v0, v1 = self.tear
            vs = np.linspace(v0, v1, 11)
            rag = [(1.0, v0)] + [(0.86 + (0.05 if i % 2 else 0.0) + rng.uniform(-0.02, 0.02), v)
                                 for i, v in enumerate(vs)] + [(1.0, v1)]
            c.poly(rag, shade(col, -0.5))
            c.poly([(min(1.0, u + 0.06), v) for u, v in rag], shade(col, -0.68))
            for v in vs[1:-1:2]:
                c.stroke([(0.9, v), (0.78, v - rng.uniform(0.01, 0.03))], 0.012, shade(col, -0.55), alpha=0.7,
                         taper=(1.0, 0.2))
        c.material(0.0, 0.8)


def sheet_uvs():
    """A builder workaround: Build._piece_uvs only projects swatches (wrap,
    front, side), and any projection smears a ribbon that twists as it falls.
    A style with a `grid` (rows, cols) is instead mapped by the sheet's own
    rows and columns (sheet() makes its vertices in grid order: row by row,
    column by column, two layers each): s = column across, v = 1 at the top
    row. Installed once; every other style keeps the builder's projection."""
    if getattr(A.Build._piece_uvs, "grid_aware", False):
        return
    project = A.Build._piece_uvs

    def piece_uvs(self, bm, palette, *args, **kw):
        project(self, bm, palette, *args, **kw)
        keys = list(palette.colors)
        layer = bm.faces.layers.int.get("color")
        uv = bm.loops.layers.uv.get("UVMap")
        bm.verts.index_update()
        for f in bm.faces:
            key = keys[f[layer]]
            grid = getattr(self.av.styles.get(key), "grid", None)
            if not grid:
                continue
            rows, cols = grid
            canvas = self.painter.swatches[key]
            for loop in f.loops:
                i, j = divmod(loop.vert.index // 2, cols)
                loop[uv].uv = canvas.uv(j / (cols - 1), 1 - i / (rows - 1))

    piece_uvs.grid_aware = True
    A.Build._piece_uvs = piece_uvs


# Accessory geometry ---------------------------------------------------------------------------------


def piece_frame(mb):
    """(center, lowest, highest) of a built piece, the way the builder's
    swatch projection measures them."""
    total, count = Vector(), 0
    for f in mb.bm.faces:
        for v in f.verts:
            total += v.co
            count += 1
    ys = [v.co.y for v in mb.bm.verts]
    return total / count, min(ys), max(ys)


def hair(av):
    """Messy spiky black hair swept back: a cap and a mass over the back of
    the head, spikes all over (leaning back, as if he never stops running,
    longer and wilder on his right), sharp bangs and sideburns, melted into
    one and carved off the scalp."""
    mb = av.builder()
    mb.sphere((0, 5.03, 0.06), (0.7, 0.37, 0.71), "hair", segments=28, rings=14)
    mb.sphere((0, 4.8, 0.12), (0.67, 0.46, 0.52), "hair", segments=28, rings=14)
    rng = np.random.default_rng(17)
    spikes = [  # (angle around from the front, height, up, out, back, length, radius)
        # the crown: up and swept back; his right side longer and swept harder
        (8, 5.3, 0.8, 0.1, 0.75, 0.52, 0.17), (44, 5.27, 0.75, 0.35, 0.9, 0.58, 0.16),
        (-26, 5.27, 0.75, 0.35, 0.7, 0.45, 0.16), (24, 5.33, 1.0, 0.0, 0.9, 0.3, 0.13),
        (-12, 5.33, 1.0, 0.0, 0.6, 0.38, 0.15), (72, 5.3, 0.9, 0.3, 0.9, 0.46, 0.14),
        (-54, 5.3, 0.9, 0.3, 0.55, 0.36, 0.14),
        # the sides: out and back
        (82, 5.12, 0.35, 1.0, 0.9, 0.55, 0.16), (-84, 5.12, 0.35, 1.0, 0.65, 0.41, 0.16),
        (115, 5.02, 0.2, 1.0, 0.9, 0.6, 0.16), (-117, 5.02, 0.2, 1.0, 0.7, 0.47, 0.16),
        # over the back of the crown: swept straight back (the side silhouette)
        (150, 5.22, 0.35, 0.3, 0.9, 0.55, 0.15), (175, 5.22, 0.35, 0.3, 0.9, 0.5, 0.15),
        (-160, 5.22, 0.35, 0.3, 0.9, 0.5, 0.15), (-135, 5.22, 0.35, 0.3, 0.9, 0.45, 0.15),
        # the back: fanning out and down over the nape, never straight at you
        (150, 5.0, 0.45, 0.6, 0.0, 0.42, 0.16), (-150, 5.0, 0.45, 0.6, 0.0, 0.38, 0.16),
        (140, 4.85, -0.75, 0.75, 0.0, 0.34, 0.15), (-140, 4.85, -0.75, 0.75, 0.0, 0.31, 0.15),
        (165, 4.85, -0.9, 0.55, 0.0, 0.34, 0.15), (-165, 4.85, -0.9, 0.55, 0.0, 0.31, 0.15),
        (118, 4.85, -0.7, 0.8, 0.15, 0.3, 0.14), (-118, 4.85, -0.7, 0.8, 0.15, 0.28, 0.14),
    ]
    for ang, y, up, out, back, length, radius in spikes:
        ang += rng.uniform(-10, 10)
        p, n = av.head_point(ang, min(y, A.HEAD_TOP - 0.02), out=0.04)
        d = n * out + Vector((0, up, back))
        spike(mb, tuple(p), tuple(d), length * rng.uniform(0.85, 1.12), radius, "hair", segments=6)
    for ang in (138, 166, 196, 226):  # layered locks down the back of the head
        a = ang + rng.uniform(-4, 4)
        pts = [av.head_point(a, 5.14, out=0.09)[0], av.head_point(a + 5, 4.94, out=0.13)[0],
               av.head_point(a + 9, 4.75, out=0.18)[0]]
        lock(mb, [tuple(q) for q in pts], 0.16, "hair", segments=6, tip=0.02)
    for sx in (-1, 1):  # sideburns down to the mask's edge (clear of the scarf)
        top, n = av.head_point(sx * 80, 4.98, out=0.06)
        tip, _ = av.head_point(sx * 74, 4.6, out=0.05)
        lock(mb, [tuple(top), tuple((top + tip) / 2 + n * 0.03), tuple(tip)], 0.11, "hair", segments=6)
    bangs = [(-50, 0.2, 18), (-28, 0.34, -16), (-2, 0.48, 9), (STREAK_ANGLE, 0.42, 3), (50, 0.24, 17)]
    for ang, drop, swing in bangs:  # sharp bangs; the middle one falls between the eyes
        top, n = av.head_point(ang, 5.14, out=0.07)
        tip, _ = av.head_point(ang + swing, 5.14 - drop, out=0.085)
        mid = (top + tip) / 2 + n * 0.055
        lock(mb, [tuple(top), tuple(mid), tuple(tip)], 0.11, "hair", segments=6, tip=0.03)
    out = A.melt(mb, voxel=0.022, smooth=5, tris=3800, carve_head=True)
    # the streak runs down the straight bang, from its tip to its root (not
    # over the crown, where it would read as a hairband)
    center, lo, hi = piece_frame(out)
    p, _ = av.head_point(STREAK_ANGLE, 4.95)
    th = math.atan2(p.x - center.x, -(p.z - center.z))
    st = av.styles["hair"]
    st.u = 0.5 - th / (2 * math.pi)
    st.tip = (5.14 - 0.42 - lo) / (hi - lo)
    st.top = (5.12 - lo) / (hi - lo)
    st.shine = (5.0 - lo) / (hi - lo)  # over the bangs and the front of the cap
    av.piece(out, bone="Neck", name="Hair")


def wind(mb, style, turn, want, clear=0.025, smooth=6):
    """Builds one turn of scarf at height want(i, angle), lifted wherever it
    would touch the torso and then smoothed, so it drapes over the shoulders
    and hangs lower in front and behind. Settles turn.ys."""
    sides = 12
    phs = np.linspace(0, 2 * math.pi, sides, endpoint=False)
    floor = []
    for i, th in enumerate(turn.ths):
        y = want(i, th)
        while min(A.body_sdf(tuple(turn.point(th, ph, y)), skip=("Head",)) for ph in phs) < clear:
            y += 0.004
        floor.append(y)
    ys = list(floor)
    n = turn.segs
    for _ in range(smooth):
        ys = [max(floor[i], (ys[i - 1] + 2 * ys[i] + ys[(i + 1) % n]) / 4) for i in range(n)]
    turn.ys = ys
    rings = [[turn.point(th, ph) for ph in phs] for th in turn.ths]
    gap = min(A.head_sdf(tuple(p)) for r in rings for p in r)
    if gap < clear:
        print(f"[Vex] scarf turn comes within {gap:.3f} studs of the head")
    verts = [tuple(p) for r in rings for p in r]
    faces = []
    for i in range(n):
        j = (i + 1) % n
        for k in range(sides):
            m = (k + 1) % sides
            faces.append((i * sides + k, i * sides + m, j * sides + m, j * sides + k))
    mb.polys(verts, faces, style, smooth=True)


def tail_rows(points, widths, base, twist, rows=12, cols=6, hem=None, tear=None):
    """Grid rows for a scarf tail: down a smooth curve through `points`,
    `widths` from top to bottom, the cloth turned `base` degrees about the
    curve and twisting `twist` more as it falls (so it shows its face to the
    side camera all the way down), with a torn hem; `tear` = (rows, pull)
    pulls the outer edge (the last column) in on those rows."""
    pts = [Vector(p) for p in points]

    def at(t):  # Catmull-Rom through the points
        n = len(pts) - 1
        f = min(t * n, n - 1e-6)
        i = int(f)
        u = f - i
        p0, p1, p2 = pts[max(i - 1, 0)], pts[i], pts[i + 1]
        p3 = pts[min(i + 2, n)]
        return 0.5 * ((2 * p1) + (-p0 + p2) * u + (2 * p0 - 5 * p1 + 4 * p2 - p3) * u * u
                      + (-p0 + 3 * p1 - 3 * p2 + p3) * u * u * u)

    out = []
    for i in range(rows):
        t = i / (rows - 1)
        c = at(t)
        w = widths[0] + (widths[1] - widths[0]) * t ** 0.6
        a = math.radians(base + twist * t ** 1.4)
        across = Vector((math.cos(a), 0.0, math.sin(a)))
        row = []
        for j in range(cols):
            u = j / (cols - 1)
            off = w * (u - 0.5)
            if tear and i in tear[0] and u > 0.5:
                off -= tear[1] * ((u - 0.5) / 0.5) ** 1.5
            p = c + across * off
            if hem and i == rows - 1:
                p.y -= hem[j]
            row.append(tuple(p))
        out.append(row)
    return out


def scarf(av):
    """The tattered scarf: two flat turns around the neck and a knot at the
    back (melted into one, riding the upper torso) and two torn tails on
    sway chains trailing behind, splayed into a V from the side."""
    mb = av.builder()
    st = av.styles["scarf"]
    # the first turn sags in front and rises behind; the second rides on it
    low = Turn(0.74, 0.70, 0.058, 0.14, seed=1)
    wind(mb, "scarf", low, lambda i, th: 3.93 - 0.04 * math.cos(th))
    high = Turn(0.73, 0.70, 0.056, 0.135, seed=2)
    wind(mb, "scarf", high, lambda i, th: low.ys[i] + 0.19 - 0.035 * math.sin(th) ** 2 + 0.02 * math.sin(th + 0.6))
    # the knot at the back: flat, so it doesn't stick out from the side
    back = low.point(math.pi, 0.0)
    knot = Vector((0.14, (low.y(math.pi) + high.y(math.pi)) / 2 - 0.02, back.z + 0.035))
    mb.sphere(tuple(knot), (0.15, 0.12, 0.07), "scarf", segments=16, rings=10)
    for sx in (-1, 1):  # the cloth pulled into it from both sides
        mb.sphere(tuple(knot + Vector((sx * 0.13, -0.06, -0.01))), (0.1, 0.06, 0.055), "scarf", segments=12,
                  rings=8, rotation=(0, 0, -sx * 35))
    out = A.melt(mb, voxel=0.02, smooth=3, tris=2400)
    center, lo, hi = piece_frame(out)
    st.turns = [low, high]
    st.frame = (center.x, center.z, lo, hi - lo)
    ku, kv = st.uv(knot + Vector((0, 0, 0.07)))
    st.knot = ((ku, kv), 0.21 / (2 * math.pi * 0.8), 0.12 / (hi - lo))
    av.piece(out, bone="Waist", name="Scarf")

    # the tails: the longer one on his right hangs nearly straight, the short
    # one flies further back; both turn their faces to the side
    rows, cols = 12, 6
    kz = knot.z - 0.01
    tails = [
        ("ScarfTailR", [(knot.x + 0.08, 3.98, kz), (0.3, 3.25, kz + 0.16), (0.4, 2.5, kz + 0.33),
                        (0.47, 1.8, kz + 0.51), (0.52, 1.2, kz + 0.68)], (0.26, 0.46), 37, 35,
         [0.12, 0.0, 0.2, 0.05, 0.26, 0.08], ((6, 7), 0.08)),
        ("ScarfTailL", [(knot.x - 0.1, 3.98, kz), (-0.06, 3.42, kz + 0.25), (-0.14, 2.92, kz + 0.6),
                        (-0.2, 2.5, kz + 0.98)], (0.24, 0.40), -37, -35, [0.2, 0.04, 0.16, 0.0, 0.22, 0.1], None),
    ]
    for name, pts, widths, base, twist, hem, tear in tails:
        torn = (1 - max(tear[0]) / (rows - 1) - 0.05, 1 - min(tear[0]) / (rows - 1) + 0.05) if tear else None
        key = av.style(name, ScarfTail(PURPLE, (rows, cols), tear=torn))
        sw = av.sway(name, "Waist", pts, stiffness=0.22, damping=0.14, limit=70, behind=1)
        mb = av.builder()
        sheet(mb, tail_rows(pts, widths, base, twist, rows, cols, hem=hem, tear=tear), 0.05, key)
        av.piece(mb, sway=sw, name=name)


def model(av):
    sheet_uvs()
    av.style("hair", StreakHair(HAIR, STREAK, shine=0.5, strands=22, shine_color="#3a3a4e"))
    av.style("scarf", Scarf(PURPLE))
    hair(av)
    scarf(av)


# The printed outfit ---------------------------------------------------------------------------------


def sash_knot(f, x, y):
    """The sash tied at the hip: two rounded loops angled up either side of
    a square center, lit on top and dark underneath."""
    for sx in (-1, 1):
        a = math.radians(35)
        d = (sx * math.cos(a), math.sin(a))
        n = (-d[1], d[0]) if sx > 0 else (d[1], -d[0])  # the loop's upper side
        length, r, neck = 0.16, 0.06, 0.035
        tip = (x + d[0] * length, y + d[1] * length)
        loop = [(x + n[0] * neck, y + n[1] * neck)]
        for g in np.linspace(90, -90, 13):
            ca, sa = math.cos(math.radians(g)), math.sin(math.radians(g))
            loop.append((tip[0] + r * (ca * d[0] + sa * n[0]), tip[1] + r * (ca * d[1] + sa * n[1])))
        loop.append((x - n[0] * neck, y - n[1] * neck))
        f.poly([(px + 0.015, py - 0.022) for px, py in loop], LINE, alpha=0.4)
        f.poly(loop, PURPLE)
        upper = [(x, y), (tip[0] + d[0] * 0.1, tip[1] + d[1] * 0.1),
                 (tip[0] + d[0] * 0.1 + n[0] * 0.2, tip[1] + d[1] * 0.1 + n[1] * 0.2), (x + n[0] * 0.2, y + n[1] * 0.2)]
        lower = [(x, y), (tip[0] + d[0] * 0.1, tip[1] + d[1] * 0.1),
                 (tip[0] + d[0] * 0.1 - n[0] * 0.2, tip[1] + d[1] * 0.1 - n[1] * 0.2), (x - n[0] * 0.2, y - n[1] * 0.2)]
        f.poly(upper, shade(PURPLE, 0.3), alpha=0.75, clip=loop)
        f.poly(lower, shade(PURPLE, -0.4), alpha=0.85, clip=loop)
        f.stroke([(x + d[0] * 0.05, y + d[1] * 0.05), (tip[0] - d[0] * 0.01, tip[1] - d[1] * 0.01)], 0.012,
                 shade(PURPLE, -0.5), alpha=0.6)  # the fold down the loop
        f.stroke(loop, 0.01, shade(PURPLE, -0.55), alpha=0.7)
    sq = [(x - 0.06, y - 0.065), (x + 0.065, y - 0.06), (x + 0.06, y + 0.065), (x - 0.065, y + 0.06)]
    f.poly([(px + 0.012, py - 0.018) for px, py in sq], LINE, alpha=0.45)
    f.poly(sq, PURPLE)
    f.gradient((x, y + 0.065), (x, y - 0.065), shade(PURPLE, 0.3), shade(PURPLE, -0.4), clip=sq)
    f.stroke([(x - 0.045, y + 0.01), (x + 0.045, y - 0.012)], 0.012, shade(PURPLE, -0.55), alpha=0.8)
    f.stroke(sq + sq[:1], 0.01, shade(PURPLE, -0.55), alpha=0.8)


def jacket(t):
    """The ninja jacket: wrapped left over right with a purple collar, the
    mesh undershirt in its V, crossed straps with a silver buckle, the
    purple sash knotted at his left hip."""
    for f in t.sides:  # one light pass all the way round: brighter over the chest and shoulders
        f.gradient((0, 2.0), (0, 4.0), shade(GARB, -0.14), shade(GARB, 0.1))
        vgrad(f, 3.35, 4.0, shade(GARB, 0.02), shade(GARB, 0.14), alpha=0.8)
    f = t.front
    # the V of the collar, the mesh undershirt inside it
    m = (0.03, 3.33)
    v_shape = [(-0.4, 4.1), (0.4, 4.1), m]
    f.poly(v_shape, UNDER)
    for k in np.arange(-0.6, 0.6, 0.06):
        f.stroke([(k, 3.3), (k + 0.8, 4.1)], 0.008, shade(UNDER, -0.4), alpha=0.8, clip=v_shape)
        f.stroke([(k, 3.3), (k - 0.8, 4.1)], 0.008, shade(UNDER, -0.4), alpha=0.8, clip=v_shape)
    f.gradient((0, 4.0), (0, 3.4), shade(UNDER, -0.3), UNDER, alpha=0.5, clip=v_shape)
    # chest and waist shading, folds toward the sash
    for sx in (-1, 1):
        f.stroke([(sx * 0.82, 3.42), (sx * 0.45, 3.3), (sx * 0.12, 3.36)], 0.05, shade(GARB, -0.32), alpha=0.7,
                 taper=(0.4, 1.0))
        f.stroke([(sx * 0.8, 3.47), (sx * 0.45, 3.36), (sx * 0.14, 3.41)], 0.016, shade(GARB, 0.3), alpha=0.45,
                 taper=(0.3, 1.0))
    vgrad(f, 2.44, 2.9, shade(GARB, -0.18), GARB, alpha=0.7)  # the jacket bunches into the sash
    folds(f, [[(-0.74, 2.44), (-0.6, 2.72), (-0.42, 2.92)], [(-0.42, 2.44), (-0.3, 2.64)],
              [(0.8, 2.44), (0.64, 2.7), (0.5, 2.86)], [(0.36, 2.44), (0.26, 2.62)], [(0.02, 2.44), (0.08, 2.58)]],
          GARB, alpha=0.75)
    # the collar: the right side tucks under the left, which runs on down
    # to the sash near the middle (its own V, apart from the straps' X)
    right0 = (0.4, 4.1)
    strip(f, right0, m, 0.14, PURPLE)
    strip(f, right0, m, 0.025, shade(PURPLE, 0.3))
    left0, left1 = (-0.42, 4.12), (0.32, 2.44)
    strip(f, left0, left1, -0.15, PURPLE)
    strip(f, left0, left1, -0.025, shade(PURPLE, 0.3))
    dx, dy = left1[0] - left0[0], left1[1] - left0[1]
    ox, oy = dy / math.hypot(dx, dy) * 0.15, -dx / math.hypot(dx, dy) * 0.15
    strip(f, (left0[0] + ox, left0[1] + oy), (left1[0] + ox, left1[1] + oy), 0.022, shade(PURPLE, -0.45))
    f.stroke([left0, left1], 0.012, shade(PURPLE, -0.5), alpha=0.7)
    # crossed straps and the buckle where they meet
    x0, y0, x1, y1 = STRAP_X, 4.08, 0.9, 2.3
    strap(f, (x0, y0), (-x1, y1))
    strap(f, (-x0, y0), (x1, y1))
    yc = y0 + (y1 - y0) * x0 / (x0 + x1)
    diamond(f, 0.0, yc - 0.025, 0.17, LINE, alpha=0.35)
    diamond(f, 0.0, yc, 0.16, SILVER)
    diamond(f, 0.0, yc, 0.16, shade(SILVER, -0.3), alpha=0.6)
    diamond(f, -0.01, yc + 0.012, 0.13, SILVER)
    diamond(f, 0.0, yc, 0.08, shade(SILVER, -0.55))
    diamond(f, 0.0, yc, 0.05, PURPLE)
    f.ellipse(-0.012, yc + 0.014, 0.018, 0.018, "#d9b8ff")
    f.stroke([(-0.12, yc + 0.03), (-0.03, yc + 0.12)], 0.016, "#ffffff", alpha=0.7)

    b = t.back
    b.stroke([(0, 2.42), (0, 4.0)], 0.02, shade(GARB, -0.4), alpha=0.6)  # center seam
    for sx in (-1, 1):  # shoulder blades
        b.stroke([(sx * 0.18, 3.75), (sx * 0.5, 3.4), (sx * 0.78, 3.38)], 0.045, shade(GARB, -0.28), alpha=0.55,
                 taper=(0.3, 1.0))
    folds(b, [[(-0.7, 2.44), (-0.55, 2.75)], [(0.6, 2.44), (0.48, 2.7)], [(-0.25, 2.44), (-0.2, 2.6)]], GARB)
    strap(b, (x0, y0), (-x1, y1))
    strap(b, (-x0, y0), (x1, y1))
    diamond(b, 0.0, yc, 0.07, shade(STRAP, -0.4))  # a rivet where they cross
    diamond(b, 0.0, yc, 0.045, shade(SILVER, -0.3))

    for side in (t.right, t.left):  # side seams
        side.stroke([(0, 2.42), (0, 4.0)], 0.022, shade(GARB, -0.45), alpha=0.7)
        side.stroke([(0.02, 2.42), (0.02, 4.0)], 0.008, shade(GARB, 0.25), alpha=0.5)
    # over the shoulders: the straps and the collar's back
    t.top.fill(shade(GARB, 0.14))
    for sx in (-1, 1):
        t.top.rect_(sx * x0 - 0.085, -0.5, sx * x0 + 0.085, 0.5, STRAP)
        t.top.rect_(sx * x0 - 0.085, -0.5, sx * x0 - 0.06, 0.5, shade(STRAP, -0.3))
    t.top.ellipse(0, 0, 0.62, 0.42, PURPLE)

    # the sash: wound twice, knotted at his left hip
    t.band(2.04, 2.44, PURPLE)
    t.band(2.04, 2.09, shade(PURPLE, -0.45))
    t.band(2.24, 2.27, shade(PURPLE, -0.35), alpha=0.7)
    t.band(2.27, 2.3, shade(PURPLE, 0.2), alpha=0.6)
    t.band(2.4, 2.44, shade(PURPLE, 0.3))
    for f in t.sides:
        a0, _, a1, _ = f.bounds()
        for a in np.linspace(a0, a1, 7)[1:-1]:  # creases where it's wound
            f.stroke([(a - 0.04, 2.1), (a + 0.05, 2.22)], 0.016, shade(PURPLE, -0.35), alpha=0.6)
            f.stroke([(a + 0.02, 2.31), (a + 0.08, 2.4)], 0.012, shade(PURPLE, -0.3), alpha=0.5)
    f = t.front
    # the ends drop from the knot to the hem (they carry on down the thigh)
    for x, w in SASH_ENDS:
        x += KNOT_X
        f.poly([(x - w / 2 + 0.012, 2.2), (x + w / 2 + 0.012, 2.2), (x + w / 2 + 0.012, 1.9),
                (x - w / 2 + 0.012, 1.9)], LINE, alpha=0.35)
        f.rect_(x - w / 2, 1.95, x + w / 2, 2.2, PURPLE)
        f.stroke([(x - 0.01, 2.18), (x - 0.01, 1.95)], 0.02, shade(PURPLE, -0.35), alpha=0.7)
        f.stroke([(x + w / 2 - 0.015, 2.18), (x + w / 2 - 0.015, 1.95)], 0.01, shade(PURPLE, 0.3), alpha=0.7)
    # the sash's folds gathering in toward the knot from both sides
    for sx, d in ((-1, 0.05), (-1, -0.06), (1, 0.06), (1, -0.05)):
        f.stroke([(KNOT_X + sx * 0.36, 2.24 + d * 1.6), (KNOT_X + sx * 0.12, 2.24 + d * 0.3)], 0.02,
                 shade(PURPLE, -0.4), alpha=0.7, taper=(0.2, 1.2))
    sash_knot(f, KNOT_X, 2.23)
    t.bottom.fill(shade(PANTS, -0.2))


def sleeve(arm, side):
    """Charcoal sleeves gathered into bandaged forearms, dark gloves with a
    silver plate over the knuckles, a crescent clan mark on the shoulder."""
    for f in arm.sides:  # one light pass all the way round, brightest at the shoulder
        vgrad(f, 2.9, 3.7, shade(GARB, -0.16), shade(GARB, 0.04))
        vgrad(f, 3.7, 4.0, shade(GARB, 0.04), shade(GARB, 0.16))
    for f in (arm.front, arm.back):  # loose sleeve folds
        folds(f, [[(-0.36, 3.36), (-0.05, 3.24), (0.34, 3.3)], [(-0.26, 3.08), (0.18, 3.04)]], GARB, alpha=0.7)
    for f in (arm.outer, arm.inner):
        folds(f, [[(-0.34, 3.26), (0.0, 3.17), (0.36, 3.22)]], GARB, alpha=0.7)
    arm.inner.gradient((0, 3.0), (0, 4.0), shade(GARB, -0.25), shade(GARB, -0.05), alpha=0.6)
    # the clan mark: a violet crescent in a ring
    o = arm.outer
    o.ellipse(0.0, 3.58, 0.2, 0.2, shade(GARB, -0.35))
    o.ellipse(0.0, 3.58, 0.18, 0.18, PURPLE)
    o.ellipse(0.0, 3.58, 0.155, 0.155, shade(GARB, -0.2))
    crescent(o, 0.01, 3.58, 0.12, shade(PURPLE, 0.25), cut=(-0.45, 0.25))
    # the sleeve's purple cuff over the wraps
    arm.band(2.92, 3.0, PURPLE)
    arm.band(2.97, 3.0, shade(PURPLE, 0.3))
    arm.band(2.92, 2.935, shade(PURPLE, -0.5))
    wraps(arm, 2.48, 2.92, WRAP, seed=3 if side > 0 else 4)
    # the glove, its cuff and the knuckle plate
    for f in arm.sides:
        vgrad(f, 2.0, 2.48, shade(GLOVE, -0.2), shade(GLOVE, 0.18))
    arm.band(2.4, 2.48, shade(GLOVE, 0.25))
    arm.band(2.395, 2.41, LINE, alpha=0.6)
    f = arm.outer  # a silver plate over the back of the hand
    plate = [(-0.3, 2.12), (0.3, 2.12), (0.32, 2.3), (0.0, 2.36), (-0.32, 2.3)]
    f.poly([(x + 0.012, y - 0.022) for x, y in plate], LINE, alpha=0.5)
    f.poly(plate, SILVER)
    f.gradient((0, 2.12), (0, 2.36), shade(SILVER, -0.3), shade(SILVER, 0.2), clip=plate)
    f.stroke([(-0.28, 2.215), (0.0, 2.255), (0.28, 2.215)], 0.016, shade(SILVER, -0.45))
    f.stroke([(-0.27, 2.3), (0.0, 2.345)], 0.012, "#ffffff", alpha=0.7)
    for x in (-0.2, 0.2):
        f.ellipse(x, 2.16, 0.022, 0.022, shade(SILVER, -0.5))
        f.ellipse(x - 0.006, 2.166, 0.01, 0.01, "#ffffff", alpha=0.8)
    f = arm.front  # a steel guard across the knuckles: matte studs, not pearls
    f.rect_(-0.42, 2.13, 0.42, 2.29, shade(SILVER, -0.55))
    f.rect_(-0.4, 2.15, 0.4, 2.28, shade(SILVER, -0.3))
    for x in (-0.3, -0.1, 0.1, 0.3):
        f.ellipse(x, 2.215, 0.085, 0.07, shade(SILVER, -0.5))
        f.ellipse(x, 2.222, 0.075, 0.06, shade(SILVER, -0.2))
        f.ellipse(x - 0.02, 2.245, 0.03, 0.017, "#ffffff", alpha=0.45)
    arm.top.fill(shade(GARB, 0.16))
    arm.bottom.fill(shade(GLOVE, -0.1))


def trousers(leg, side):
    """Tapered trousers with purple piping, bloused over the shin wraps;
    split-toe ninja shoes."""
    for f in leg.sides:
        f.gradient((0, 1.2), (0, 2.0), shade(PANTS, -0.16), shade(PANTS, 0.1))
    for f in (leg.front, leg.back):  # two pleats each side, bunching at the knee
        for x in (-0.2, 0.18):
            f.stroke([(x, 1.98), (x * 0.8, 1.32)], 0.03, shade(PANTS, -0.4), alpha=0.7, taper=(1.0, 0.4))
            f.stroke([(x + 0.035, 1.98), (x * 0.8 + 0.03, 1.32)], 0.012, shade(PANTS, 0.3), alpha=0.5,
                     taper=(1.0, 0.3))
        folds(f, [[(-0.4, 1.62), (-0.26, 1.5)], [(0.38, 1.7), (0.26, 1.56)],
                  [(-0.3, 1.36), (0.0, 1.31), (0.3, 1.36)]], PANTS, alpha=0.75)
    for f in leg.sides:  # the blouse over the wraps
        a0, _, a1, _ = f.bounds()
        f.rect_(a0, 1.2, a1, 1.26, shade(PANTS, -0.4), alpha=0.8)
    o = leg.outer
    o.rect_(-0.05, 1.26, 0.05, 2.0, PURPLE)  # piping down the outer seam
    o.rect_(-0.05, 1.26, -0.03, 2.0, shade(PURPLE, 0.3))
    folds(o, [[(-0.3, 1.7), (-0.1, 1.55)], [(0.32, 1.62), (0.12, 1.45)]], PANTS)
    wraps(leg, 0.5, 1.2, SHIN, spacing=0.11, seed=7 if side > 0 else 8)
    # tabi shoes: a split toe, a sole, clasps up the back
    for f in leg.sides:
        vgrad(f, 0.0, 0.5, shade(SHOE, -0.15), shade(SHOE, 0.1))
    leg.band(0.0, 0.08, "#4a4756")  # rubber sole
    leg.band(0.0, 0.025, shade(SHOE, -0.3))
    leg.band(0.075, 0.09, LINE, alpha=0.7)
    leg.band(0.44, 0.5, shade(SHOE, 0.18))  # the ankle cuff under the wraps
    leg.band(0.44, 0.452, LINE, alpha=0.7)
    f = leg.front
    toe = 0.16 * side  # the split sits toward the inside of each foot
    f.stroke([(toe, 0.09), (toe, 0.27)], 0.03, LINE)
    for a0, a1 in ((toe - 0.5 * side, toe - 0.02 * side), (toe + 0.02 * side, toe + 0.5 * side)):
        lo, hi = sorted((a0, a1))  # a soft shine over each half of the toe
        f.stroke([(lo + 0.06, 0.24), ((lo + hi) / 2, 0.27), (hi - 0.06, 0.24)], 0.018, shade(SHOE, 0.45),
                 alpha=0.5, taper=(0.3, 0.3))
    for y in (0.2, 0.3, 0.4):  # clasps up the back
        leg.back.rect_(-0.05, y - 0.018, 0.05, y + 0.018, shade(SILVER, -0.4))
        leg.back.rect_(-0.045, y - 0.012, 0.045, y + 0.016, SILVER)
    leg.top.fill(shade(PANTS, -0.1))
    leg.bottom.fill(shade(SHOE, -0.3))


def sash_ends(leg):
    """The sash's knotted ends, hanging over the front of his left thigh."""
    f = leg.front
    for (x, w), ln in zip(SASH_ENDS, (0.62, 0.48)):
        x += KNOT_X - leg.cx
        y1 = 2.0 - ln
        pts = [(x - w / 2, 2.0), (x + w / 2, 2.0), (x + w / 2 + 0.02, y1 + 0.03), (x + w * 0.1, y1 + 0.09),
               (x - w * 0.15, y1), (x - w / 2 + 0.01, y1 + 0.06)]
        f.poly([(px + 0.012, py - 0.02) for px, py in pts], LINE, alpha=0.35)
        f.poly(pts, PURPLE)
        f.stroke([(x - 0.01, 1.98), (x + 0.01, y1 + 0.12)], 0.02, shade(PURPLE, -0.35), alpha=0.7,
                 taper=(1.0, 0.3))
        f.stroke([(x + w / 2 - 0.015, 1.98), (x + w / 2 - 0.005, y1 + 0.1)], 0.01, shade(PURPLE, 0.3), alpha=0.7)
        f.rect_(x - w / 2, y1 + 0.12, x + w / 2 + 0.02, y1 + 0.15, PURPLE_DEEP, alpha=0.9)


def nape(band):
    """Below the 3D hair at the back: pointed locks painted down the nape,
    continuing its tips, and the mask's tie at the back of the head."""
    rng = np.random.default_rng(11)
    count = 6
    span = 2 * BACK_S - 2 * 0.95
    wid = span / count
    for k in range(count):
        sc = 0.95 + wid * (k + 0.5)
        sc = sc - 2 * BACK_S if sc > BACK_S else sc
        tip = (sc + rng.uniform(-0.05, 0.05), 4.5 + rng.uniform(-0.015, 0.03))
        for off in (0.0, 2 * BACK_S, -2 * BACK_S):  # across the band's seam
            l0, l1 = (sc - wid * 0.62 + off, 4.67), (sc + wid * 0.62 + off, 4.67)
            t = (tip[0] + off, tip[1])
            lock_ = [l0, ((l0[0] + t[0]) / 2 - 0.02, (l0[1] + t[1]) / 2), t, ((l1[0] + t[0]) / 2 + 0.02,
                                                                             (l1[1] + t[1]) / 2), l1]
            band.poly([(a, b - 0.018) for a, b in lock_], shade(HAIR, -0.3))
            band.poly(lock_, HAIR)
            band.stroke([(sc + off, 4.66), (t[0] + 0.01, t[1] + 0.05)], 0.02, shade(HAIR, 0.18), alpha=0.5,
                        taper=(1.0, 0.2))
    for off in (BACK_S, -BACK_S):  # the mask's tie: a small knot, two short ends above the scarf
        y = 4.43
        for sx in (-1, 1):
            end = [(off + sx * 0.02, y - 0.01), (off + sx * 0.075, y - 0.02), (off + sx * 0.13, y - 0.13),
                   (off + sx * 0.07, y - 0.12)]
            band.poly([(a + 0.01, b - 0.012) for a, b in end], LINE, alpha=0.4)
            band.poly(end, MASK)
            band.stroke([end[1], end[2]], 0.012, PURPLE, alpha=0.9)
        band.ellipse(off + 0.006, y - 0.01, 0.06, 0.045, LINE, alpha=0.4)
        band.ellipse(off, y, 0.055, 0.04, shade(MASK, 0.08))
        band.ellipse(off - 0.012, y + 0.012, 0.03, 0.016, shade(MASK, 0.3), alpha=0.7)
        band.stroke([(off - 0.055, y), (off + 0.055, y)], 0.01, PURPLE, alpha=0.8)


def paint(av, p):
    p.head.fill(SKIN)
    band = p.head.band
    # hair color under the hairdo, down to a hairline lower at the back
    line = [(s, 4.98 - 0.33 * math.sin(min(abs(s) / 1.0, 1) * math.pi / 2) ** 2) for s in
            np.linspace(-1.95, 1.95, 60)]
    band.poly(line + [(1.95, 5.3), (-1.95, 5.3)], HAIR)
    p.head.top.fill(HAIR)
    p.head.bottom.fill(MASK)
    face(band)
    nape(band)
    jacket(p.torso)
    for side, s in (("Right", 1), ("Left", -1)):
        sleeve(p.arm(side), s)
        trousers(p.leg(side), s)
    sash_ends(p.leg("Left"))
