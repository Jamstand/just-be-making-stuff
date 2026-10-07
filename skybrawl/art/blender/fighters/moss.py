"""Moss, feral jungle berserker. Scythe + Spear. Long reach, steady.

A classic blocky avatar: deep brown skin and a huge wild mane of dark
green-black hair in big clumps swept up and back, two leaves caught in it
and a bundle of beaded dreadlocks falling down his back; half of a cracked
white beast skull over his right eye (a heavy brow, a snout with a nostril,
a row of teeth along the cheek and three glowing claw marks on the temple);
wild amber eyes with pinprick pupils and a fanged snarl; glowing green
tribal marks on his face, chest and arms (a fang band round each arm and a
thorny vine down his scythe arm). A torn olive sleeveless top with claw
rips, a ragged V neck and a hem torn on a slant, ragged olive shorts under a
twisted rope belt with a bone charm, linen-wrapped shins and wrists, bare
feet, and a shaggy beast pelt slung over his right shoulder, held by a
leather strap across his chest.
"""

import math

import bmesh
import numpy as np
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree
from mathutils.geometry import delaunay_2d_cdt

from sky import avatar as A
from sky.avatar import Hair, Style, shade, sheet

NAME = "Moss"

SKIN = "#5f3a25"
TOP = "#67733a"
SHORTS = "#4f4b2c"
WRAP = "#b3a384"  # dirty linen
CORD = "#4b2f1d"  # leather cord
ROPE = "#a3804d"
BONE = "#ece4d0"
FUR = "#86663f"
FUR_ROOT = "#5e4429"
FUR_TIP = "#c7a477"
MANE = "#223126"
MANE_SHINE = "#3e5640"
MOSS_TINT = "#33502f"  # moss caught in the dreads
LEAF = "#3d6a2a"
LEAF_SHADE = "#2c4f1f"
LEAF_TIP = "#7d9a3e"
GLOW = "#5cff7a"
GLOW_DEEP = "#1d9e48"
GLOW_HOT = "#eaffea"
IRIS = "#ffa915"
LINE = "#170f0b"
INSIDE = "#3b1214"
TEETH = "#f3eee2"
WHITE = "#fbf8f1"
UNDER = "#7a6868"  # multiplied in for contact shadows

# The mask, drawn around his right eye in head-band coordinates (s, y): s is
# the distance around the head from the front center (his right is +).
MASK_OUTLINE = [
    # the top edge, inner to outer, and the outer edge down the side of his head
    (0.03, 4.895), (0.12, 4.91), (0.21, 4.9), (0.3, 4.91), (0.42, 4.895), (0.55, 4.87), (0.66, 4.83),
    (0.74, 4.775), (0.78, 4.69), (0.79, 4.58), (0.775, 4.5),
    # the upper jaw along his cheek: a row of teeth, the fang in the middle
    (0.72, 4.46), (0.67, 4.455), (0.635, 4.4), (0.6, 4.455), (0.54, 4.46), (0.48, 4.37), (0.43, 4.455),
    (0.37, 4.46), (0.33, 4.395), (0.295, 4.455), (0.23, 4.445), (0.16, 4.44),
    # the snout beside his nose, then the broken edge up the middle of his face
    (0.12, 4.45), (0.06, 4.44), (0.05, 4.5), (-0.01, 4.55), (0.02, 4.6), (-0.04, 4.66), (0.0, 4.72),
    (-0.04, 4.78), (0.01, 4.83), (-0.03, 4.86),
]
MASK_HOLE = [  # the eye socket, angled like a scowling brow
    (0.075, 4.6), (0.1, 4.665), (0.2, 4.715), (0.33, 4.755), (0.455, 4.775), (0.45, 4.66), (0.4, 4.555),
    (0.3, 4.5), (0.18, 4.5), (0.1, 4.535),
]
MASK_IN = 0.028  # the mask's inner surface, this far off the face
MASK_SNOUT = (0.1, 4.49)  # the swelling of the snout, with its nostril
MASK_CRACKS = [  # (s, y) polylines painted on the bone
    [(0.25, 4.905), (0.27, 4.86), (0.24, 4.81), (0.265, 4.735)],
    [(0.44, 4.6), (0.5, 4.565), (0.55, 4.52), (0.575, 4.475)],
    [(0.5, 4.565), (0.58, 4.59), (0.66, 4.57)],
    [(0.785, 4.64), (0.73, 4.61), (0.74, 4.55)],
]
MASK_CLAWS = [  # three glowing claw marks raked across the temple
    [(0.475, 4.87), (0.52, 4.79), (0.545, 4.74)],
    [(0.56, 4.855), (0.605, 4.775), (0.63, 4.715)],
    [(0.645, 4.82), (0.685, 4.745), (0.705, 4.69)],
]
MASK_JAW = [(0.73, 4.468), (0.6, 4.465), (0.48, 4.468), (0.37, 4.468), (0.25, 4.457)]  # above the teeth


# Painting helpers ---------------------------------------------------------------------------


def mark(c, pts, width, taper=None, alpha=1.0, clip=None):
    """A glowing tribal mark: a soft green halo, the bright core and a hot
    center line."""
    c.stroke(pts, width * 1.8, GLOW_DEEP, alpha=0.32 * alpha, taper=taper, clip=clip)
    c.stroke(pts, width, GLOW, alpha=alpha, taper=taper, clip=clip)
    c.stroke(pts, width * 0.36, GLOW_HOT, alpha=0.75 * alpha, taper=taper, clip=clip)


def folds(c, lines, color, width=0.035, alpha=0.6):
    """Cel-shaded cloth folds: a dark tapered crease with a lit edge."""
    for pts in lines:
        c.stroke(pts, width, shade(color, -0.36), alpha=alpha, taper=(1.3, 0.2))
        c.stroke([(x + 0.024, y + 0.012) for x, y in pts], width * 0.45, shade(color, 0.28), alpha=alpha * 0.6,
                 taper=(1.0, 0.1))


def around(limb):
    """Each side face of a limb with t(a), how far around the limb (front ->
    right -> back -> left) its coordinate a sits, and the inverse a(t), so
    patterns painted around a limb meet at the corners."""
    w, d = limb.w, A.DEPTH
    hw, hd = w / 2, d / 2
    return [
        (limb.front, lambda a: a + hw, lambda t: t - hw),
        (limb.right, lambda a: w + a + hd, lambda t: t - w - hd),
        (limb.back, lambda a: w + d + hw - a, lambda t: w + d + hw - t),
        (limb.left, lambda a: 2 * w + d + hd - a, lambda t: 2 * w + d + hd - t),
    ]


def across_at(limb, t):
    """How far toward the fighter's right (from the limb's center) the point t
    around the limb sits: the front and back run across, the sides are at the
    edges."""
    w, d = limb.w, A.DEPTH
    t %= 2 * (w + d)
    if t < w:
        return t - w / 2
    if t < w + d:
        return w / 2
    if t < 2 * w + d:
        return w + d + w / 2 - t
    return -w / 2


def ragged(per, y, amp, teeth, seed, tilt=None):
    """A torn edge running all the way around a limb (perimeter `per`):
    irregular teeth between about y - amp and y + amp, raised by tilt(t).
    Returns the height function h(t) and its corners."""
    rng = np.random.default_rng(seed)
    n = teeth * 2
    ts = np.array([(k + rng.uniform(-0.3, 0.3)) * per / n for k in range(n)])
    hs = np.array([y + (1 if k % 2 else -1) * amp * rng.uniform(0.35, 1.0) for k in range(n)])
    return (lambda t: float(np.interp(t, ts, hs, period=per)) + (tilt(t) if tilt else 0.0)), list(ts % per)


def edge_points(face, t_of, a_of, h, knots):
    """A torn edge across one face, through every corner that falls on it."""
    a0, _, a1, _ = face.bounds()
    t_lo, t_hi = sorted((t_of(a0), t_of(a1)))
    aa = sorted([a0, a1] + [a_of(t) for t in knots if t_lo < t < t_hi])
    return [(a, h(t_of(a))) for a in aa]


def torn_region(limb, y, amp, teeth, seed, top, color, threads=True, slope=0.0):
    """Printed cloth from a torn hem (around y, rising `slope` per stud
    toward his right) up to `top`, with the hem's shadow on the skin below, a
    dark frayed edge and loose threads."""
    per = 2 * (limb.w + A.DEPTH)
    h, knots = ragged(per, y, amp, teeth, seed, tilt=lambda t: slope * across_at(limb, t))
    rng = np.random.default_rng(seed + 50)
    for f, t_of, a_of in around(limb):
        a0, _, a1, _ = f.bounds()
        edge = edge_points(f, t_of, a_of, h, knots)
        region = edge + [(a1, top), (a0, top)]
        f.poly([(a, yy - 0.035) for a, yy in edge] + [(a1, top), (a0, top)], shade(SKIN, -0.5), alpha=0.45)
        f.poly(region, color)
        lo = min(yy for _, yy in edge)
        f.gradient((0, lo - amp), (0, top), shade(color, -0.3), shade(color, 0.1), clip=region)
        for _ in range(4):  # dirt and stains
            a, b = rng.uniform(a0, a1), rng.uniform(lo + amp, min(top, lo + 1.2))
            f.ellipse(a, b, rng.uniform(0.06, 0.14), rng.uniform(0.04, 0.08), shade(color, -0.4), alpha=0.16,
                      rotation=rng.uniform(-30, 30), clip=region)
        f.stroke(edge, 0.04, shade(color, -0.3), alpha=0.6, clip=region)
        f.stroke(edge, 0.016, shade(color, -0.55), alpha=0.9)
        if threads:
            for (a, yy), (_, py), (_, ny) in zip(edge[1:-1], edge, edge[2:]):
                if yy < min(py, ny) and rng.uniform() < 0.7:  # loose threads at the low points
                    f.stroke([(a, yy), (a + rng.uniform(-0.02, 0.02), yy - rng.uniform(0.03, 0.07))], 0.008,
                             shade(color, -0.15), alpha=0.9)
    return h


def wraps(limb, y0, y1, color, spacing=0.1, seed=1):
    """Linen bandages wound up a limb between y0 and y1: one strip climbing
    as it goes around (a helix), each turn overlapping the last."""
    per = 2 * (limb.w + A.DEPTH)
    rng = np.random.default_rng(seed)
    n = int((y1 - y0) / spacing) + 4
    tones = [shade(color, rng.uniform(-0.12, 0.05)) for _ in range(n + 2)]
    for f, t_of, _ in around(limb):
        a0, _, a1, _ = f.bounds()
        box = [(a0, y0), (a1, y0), (a1, y1), (a0, y1)]
        f.rect_(a0, y0, a1, y1, shade(color, -0.1))

        def edge(k, a):
            return y0 + (k - 1) * spacing + spacing * t_of(a) / per

        def inside(pts):
            return [(a, min(max(b, y0), y1)) for a, b in pts]

        for k in range(n):
            lo0, lo1 = edge(k, a0), edge(k, a1)
            band = inside([(a0, lo0), (a1, lo1), (a1, lo1 + spacing), (a0, lo0 + spacing)])
            f.poly(band, tones[k])
            f.gradient((0, lo0 + spacing * 0.3), (0, lo0 + spacing), tones[k], shade(tones[k], 0.14), alpha=0.6,
                       clip=band)
            f.stroke([(a0, lo0), (a1, lo1)], 0.02, shade(color, -0.5), alpha=0.85, clip=box)
            f.stroke([(a0, lo0 + 0.018), (a1, lo1 + 0.018)], 0.01, shade(color, 0.3), alpha=0.6, clip=box)
        for _ in range(3):  # grime
            a, b = rng.uniform(a0, a1), rng.uniform(y0, y1)
            f.ellipse(a, b, rng.uniform(0.04, 0.09), rng.uniform(0.02, 0.04), shade(color, -0.35), alpha=0.18,
                      clip=box)
        f.stroke([(a0, y1), (a1, y1)], 0.026, shade(color, -0.6), alpha=0.75)
        f.stroke([(a0, y0), (a1, y0)], 0.02, shade(color, -0.6), alpha=0.6)


def rope(limb, y0, y1, color=ROPE, period=0.07):
    """A twisted rope wound around a limb: plump strands slanting one way."""
    limb.band(y0, y1, shade(color, -0.4))
    slant = (y1 - y0) * 0.8
    for f, t_of, a_of in around(limb):
        a0, _, a1, _ = f.bounds()
        box = [(a0, y0), (a1, y0), (a1, y1), (a0, y1)]
        t_lo, t_hi = sorted((t_of(a0), t_of(a1)))
        for k in range(int((t_lo - slant) / period) - 1, int(t_hi / period) + 2):
            t = k * period
            p0, p1 = (a_of(t), y0 - 0.01), (a_of(t + slant), y1 + 0.01)
            f.stroke([p0, p1], period * 0.8, color, clip=box)
            f.stroke([(p0[0], p0[1] + 0.02), (p1[0], p1[1] - 0.03)], period * 0.25, shade(color, 0.35),
                     alpha=0.7, clip=box)
        f.stroke([(a0, y1), (a1, y1)], 0.012, shade(color, -0.6), alpha=0.6)
        f.stroke([(a0, y0), (a1, y0)], 0.016, shade(color, -0.6), alpha=0.7)


def fangs(limb, y, seed, width=0.024):
    """A glowing band round a limb with fangs of uneven sizes hanging from it,
    meeting at the corners."""
    per = 2 * (limb.w + A.DEPTH)
    rng = np.random.default_rng(seed)
    teeth, t = [], rng.uniform(0.0, 0.05)
    while t < per - 0.08:
        w = rng.uniform(0.07, 0.15)
        teeth.append((t, t + w, rng.uniform(0.07, 0.2)))
        t += w + rng.uniform(0.01, 0.05)
    for f, t_of, a_of in around(limb):
        a0, _, a1, _ = f.bounds()
        lo, hi = sorted((t_of(a0), t_of(a1)))
        tris = []
        for t0, t1, ln in teeth:
            for off in (-per, 0.0, per):
                if t1 + off > lo and t0 + off < hi:
                    tm = (t0 + t1) / 2 + off
                    tris.append([(a_of(t0 + off), y + 0.005), (a_of(t1 + off), y + 0.005), (a_of(tm), y - ln)])
        for tri in tris:  # the halo, then the fangs, then their hot cores
            f.stroke(tri + tri[:1], width * 1.4, GLOW_DEEP, alpha=0.3)
        for tri in tris:
            f.poly(tri, GLOW)
        for tri in tris:
            base = ((tri[0][0] + tri[1][0]) / 2, y)
            f.stroke([base, (base[0] * 0.3 + tri[2][0] * 0.7, y * 0.3 + tri[2][1] * 0.7)], width * 0.5, GLOW_HOT,
                     alpha=0.7, taper=(1.0, 0.2))
        mark(f, [(a0, y), (a1, y)], width)


def thorns(f, y0, y1, seed):
    """A glowing thorny vine down the middle of a face, thorns alternating."""
    rng = np.random.default_rng(seed)

    def x_at(y):
        return 0.035 * math.sin((y - y1) * 7.0)

    mark(f, [(x_at(y), y) for y in np.linspace(y0, y1, 12)], 0.032, taper=(1.0, 0.5))
    y, side = y0 - 0.1, 1
    while y > y1 + 0.1:
        x = x_at(y)
        mark(f, [(x, y), (x + side * 0.06, y + 0.035), (x + side * 0.1, y + 0.085)], 0.024, taper=(1.0, 0.1))
        side = -side
        y -= rng.uniform(0.11, 0.14)


def rip(c, p0, p1, width, cloth, seed=0):
    """A claw tear through printed cloth, showing the skin beneath."""
    (x0, y0), (x1, y1) = p0, p1
    dx, dy = x1 - x0, y1 - y0
    ln = math.hypot(dx, dy)
    nx, ny = -dy / ln, dx / ln
    rng = np.random.default_rng(seed)
    top, bot = [], []
    for i in range(13):
        t = i / 12
        w = width * math.sin(math.pi * t) ** 0.8
        cx, cy = x0 + dx * t, y0 + dy * t
        top.append((cx + nx * w * rng.uniform(0.7, 1.1), cy + ny * w * rng.uniform(0.7, 1.1)))
        bot.append((cx - nx * w * rng.uniform(0.7, 1.1), cy - ny * w * rng.uniform(0.7, 1.1)))
    hole = top + bot[::-1]
    c.poly(hole, shade(SKIN, 0.02))
    c.stroke(top, width * 0.7, shade(SKIN, -0.55), alpha=0.55, clip=hole)  # the flap's shadow
    c.stroke(hole + [hole[0]], 0.016, shade(cloth, -0.6), alpha=0.95)
    c.stroke([(x + nx * 0.014, y + ny * 0.014) for x, y in top], 0.008, shade(cloth, 0.3), alpha=0.6)
    for i in (3, 6, 9):  # threads across the tear
        c.stroke([top[i], bot[i + rng.integers(-1, 2)]], 0.006, shade(cloth, -0.1), alpha=0.8)
    return hole


def stitches(c, p0, p1, color=ROPE, step=0.06, size=0.03):
    """A crude cross-stitched repair along p0 -> p1."""
    (x0, y0), (x1, y1) = p0, p1
    ln = math.hypot(x1 - x0, y1 - y0)
    ux, uy = (x1 - x0) / ln, (y1 - y0) / ln
    nx, ny = -uy, ux
    c.stroke([p0, p1], 0.014, LINE, alpha=0.55)
    k = step / 2
    while k < ln:
        cx, cy = x0 + ux * k, y0 + uy * k
        for sgn in (1, -1):
            a = (cx - ux * size * 0.5 + nx * size * sgn, cy - uy * size * 0.5 + ny * size * sgn)
            b = (cx + ux * size * 0.5 - nx * size * sgn, cy + uy * size * 0.5 - ny * size * sgn)
            c.stroke([a, b], 0.012, color)
        k += step


def vgrad(f, y0, y1, c0, c1, alpha=1.0):
    """A vertical gradient between two heights only."""
    a0, _, a1, _ = f.bounds()
    f.gradient((0, y0), (0, y1), c0, c1, alpha=alpha, clip=[(a0, y0), (a1, y0), (a1, y1), (a0, y1)])


def shadow_band(f, y0, y1, strength=0.4, steps=8, x0=None, x1=None):
    """A soft painted contact shadow, darkest at y1 (under an accessory),
    across the face or from x0 to x1."""
    a0, _, a1, _ = f.bounds()
    a0, a1 = a0 if x0 is None else x0, a1 if x1 is None else x1
    for k in range(steps):
        lo = y0 + (y1 - y0) * k / steps
        f.rect_(a0, lo, a1, y1, UNDER, alpha=strength / steps * 1.6, blend="multiply")


# The face -------------------------------------------------------------------------------------------


def feral_eye(c, side, glow=None):
    """A wild anime eye: narrow and slanted under a heavy scowling lid, a big
    amber iris with a dark ring and a pinprick pupil."""
    s = side
    y = A.EYE_Y
    cx = s * A.EYE_X
    w, h = 0.155, 0.1
    inner, outer = cx - s * w, cx + s * w
    top, bot = [], []
    for i in range(15):
        t = i / 14
        xx = inner + (outer - inner) * t
        bump = math.sin(math.pi * t)
        arc = y + h * bump ** 0.6 + 0.04 * (t - 0.5)
        lid = y + 0.012 + 0.085 * t  # the scowl: the lid slants down toward the nose
        top.append((xx, min(arc, lid)))
        bot.append((xx, y - h * 0.72 * bump ** 1.3 + 0.015 * (t - 0.5)))
    eye = top + bot[::-1]
    c.poly(eye, WHITE)
    c.gradient((0, y + 0.08), (0, y), "#c9bfb6", WHITE, alpha=0.7, clip=eye)  # the lid's shadow
    ix, iy, ir = cx + s * 0.012, y - 0.004, 0.068
    color = glow or IRIS
    c.ellipse(ix, iy, ir, ir * 1.12, LINE, clip=eye)  # dark ring
    c.ellipse(ix, iy, ir * 0.84, ir * 0.96, shade(color, -0.3), clip=eye)
    c.ellipse(ix, iy - ir * 0.22, ir * 0.7, ir * 0.66, color, clip=eye)
    c.ellipse(ix, iy - ir * 0.5, ir * 0.42, ir * 0.3, shade(color, 0.5), clip=eye)
    if glow:
        c.ellipse(ix, iy, ir * 0.2, ir * 0.5, "#ffffff", clip=eye)
    else:
        c.ellipse(ix, iy + ir * 0.04, ir * 0.17, ir * 0.24, LINE, clip=eye)  # the pinprick pupil
    c.ellipse(ix - s * ir * 0.45, iy + ir * 0.4, ir * 0.2, ir * 0.16, "#ffffff", clip=eye)
    # a heavy lash line with a flick, a thin lower lid, a crease under the eye
    c.stroke(top + [(outer + s * 0.05, top[-1][1] + 0.025)], 0.04, LINE, taper=(0.7, 1.0))
    c.stroke(bot[6:14], 0.013, LINE, alpha=0.85, taper=(0.3, 1.0))
    c.stroke([(cx - s * 0.1, y - 0.105), (cx + s * 0.02, y - 0.118), (cx + s * 0.1, y - 0.1)], 0.011,
             shade(SKIN, -0.55), alpha=0.6, taper=(0.3, 1.0))
    # the brow: thick, low, angled hard down toward the nose
    c.stroke([(s * 0.1, 4.735), (s * 0.24, 4.8), (s * 0.4, 4.835)], 0.058, LINE, taper=(1.25, 0.45))
    return eye


def snarl(c, y=4.295, k=1.12):
    """A wide fanged snarl: lips pulled back, long upper and lower fangs.
    Shapes are given around (0, y) and drawn `k` times larger."""

    def P(*pts):
        return [(x * k, y + dy * k) for x, dy in pts]

    mouth = P((-0.15, 0.008), (-0.118, 0.045), (-0.078, 0.062), (-0.036, 0.05), (0.0, 0.056), (0.036, 0.05),
              (0.078, 0.062), (0.118, 0.045), (0.15, 0.008), (0.12, -0.032), (0.06, -0.052), (0.0, -0.057),
              (-0.06, -0.052), (-0.12, -0.032))
    c.poly(mouth, INSIDE)
    c.ellipse(0, y - 0.05 * k, 0.07 * k, 0.026 * k, "#7c2a30", clip=mouth)  # tongue
    c.poly(P((-0.16, 0.08), (0.16, 0.08), (0.16, 0.03), (-0.16, 0.03)), TEETH, clip=mouth)
    c.poly(P((-0.12, -0.07), (0.12, -0.07), (0.12, -0.036), (-0.12, -0.036)), TEETH, clip=mouth)
    for sx in (-1, 1):  # the fangs
        c.poly(P((sx * 0.052, 0.05), (sx * 0.102, 0.05), (sx * 0.08, -0.03)), TEETH, clip=mouth)
        c.poly(P((sx * 0.088, -0.06), (sx * 0.13, -0.06), (sx * 0.112, 0.008)), TEETH, clip=mouth)
        c.stroke(P((sx * 0.08, 0.045), (sx * 0.08, -0.02)), 0.006 * k, shade(TEETH, -0.25), alpha=0.5)
    for x in (-0.026, 0.0, 0.026):  # gaps between the front teeth
        c.stroke(P((x, 0.05), (x, 0.032)), 0.005 * k, shade(TEETH, -0.4), alpha=0.6)
    c.stroke(mouth + mouth[:1], 0.017 * k, LINE)
    for sx in (-1, 1):  # snarl creases at the corners and down from the nose
        c.stroke(P((sx * 0.15, 0.008), (sx * 0.185, 0.045)), 0.013 * k, LINE, alpha=0.75, taper=(1.0, 0.3))
        c.stroke(P((sx * 0.07, 0.12), (sx * 0.12, 0.085), (sx * 0.145, 0.04)), 0.011 * k, shade(SKIN, -0.6),
                 alpha=0.6, taper=(0.3, 1.0))
    c.stroke(P((-0.05, -0.085), (0.0, -0.092), (0.05, -0.085)), 0.012 * k, shade(SKIN, -0.5), alpha=0.5)


def face(c, glow=None):
    """The face on the head band (also exported as a decal); `glow` replaces
    the iris color with a glowing one."""
    # glowing marks: two slashes across his left cheek (the mask carries the
    # claw marks on his right) and a stripe down the chin
    for k in range(2):
        mark(c, [(-0.41, 4.5 - k * 0.07), (-0.27, 4.44 - k * 0.07)], 0.03, taper=(1.0, 0.3))
    mark(c, [(0.0, 4.2), (0.0, 4.1)], 0.026, taper=(1.0, 0.4))
    for side in (1, -1):
        feral_eye(c, side, glow)
    # a broad nose, scrunched into the snarl
    for sx in (-1, 1):
        c.stroke([(sx * 0.055, 4.44), (sx * 0.03, 4.42)], 0.018, LINE, alpha=0.8)
        c.stroke([(sx * 0.045, 4.57), (sx * 0.08, 4.545)], 0.01, shade(SKIN, -0.6), alpha=0.6)
    c.stroke([(-0.06, 4.475), (0.0, 4.462), (0.06, 4.475)], 0.012, shade(SKIN, -0.5), alpha=0.45)
    c.stroke([(0.0, 4.545), (0.0, 4.495)], 0.012, shade(SKIN, 0.3), alpha=0.4, taper=(0.4, 1.0))  # the bridge
    snarl(c)


# Accessory styles -------------------------------------------------------------------------------------


class Mane(Hair):
    """Dark green-black hair: a gradient up to green-lit tips and fine darker
    strands. No shine band: projected around the mane it would be one level
    ring across every clump, so the clumps' own shading does the work."""

    def paint(self, c):
        c.gradient((0.5, 0.0), (0.5, 1.0), shade(self.color, -0.35), shade(self.shine_color, -0.25))
        rng = np.random.default_rng(41)
        for _ in range(self.strands):
            x = rng.uniform(0, 1)
            c.stroke([(x, 0.0), (x + rng.uniform(-0.03, 0.03), rng.uniform(0.4, 0.95))], 0.012,
                     shade(self.color, -0.45), alpha=0.6, taper=(1.0, 0.2))
        c.material(0.0, 0.55)


class Dreads(Style):
    """Matted locks: dark, lumpy with irregular twists, a little moss."""

    size = (128, 256)

    def paint(self, c):
        c.gradient((0.5, 0.0), (0.5, 1.0), shade(self.color, -0.3), shade(self.color, 0.1))
        rng = np.random.default_rng(7)
        for _ in range(90):
            u, v = rng.uniform(-0.05, 1.0), rng.uniform(0.0, 1.0)
            ln = rng.uniform(0.06, 0.16)
            slant = rng.uniform(0.01, 0.03)
            c.stroke([(u, v), (u + ln, v + slant)], rng.uniform(0.008, 0.014), shade(self.color, -0.5),
                     alpha=rng.uniform(0.3, 0.6), taper=(0.3, 0.3))
            c.stroke([(u + 0.01, v + 0.01), (u + ln * 0.8, v + slant + 0.01)], 0.007, shade(self.color, 0.35),
                     alpha=rng.uniform(0.2, 0.4), taper=(0.3, 0.3))
        for _ in range(8):
            x, v = rng.uniform(0, 1), rng.uniform(0.2, 0.9)
            c.ellipse(x, v, 0.06, 0.02, MOSS_TINT, alpha=0.4)
        c.material(0.0, 0.62)


class Bone(Style):
    """Old bone: creamy, grimy at the edges and in the cracks, a dark socket,
    a nostril, a jaw line over the teeth and three glowing claw marks. `uv`
    (set once the mask is built) maps head-band (s, y) to the swatch, so the
    paint lands where it belongs."""

    projection = "front"
    size = (224, 224)
    rough = 0.5

    def __init__(self, color, **kw):
        super().__init__(color, **kw)
        self.uv = None
        self.span = 1.0

    def paint(self, c):
        c.gradient((0.5, 0.0), (0.5, 1.0), shade(self.color, -0.2), shade(self.color, 0.06))
        if self.uv:
            def P(pts):
                return [self.uv(s, y) for s, y in pts]

            k = 1.0 / self.span  # studs -> swatch units
            # grime along the broken edge and the outer rim, a dark hollow socket
            c.stroke(P(MASK_OUTLINE[24:] + MASK_OUTLINE[:1]), 0.07 * k, shade(self.color, -0.45), alpha=0.35)
            c.stroke(P(MASK_OUTLINE[6:12]), 0.06 * k, shade(self.color, -0.4), alpha=0.3)
            # (shifted toward his right: the front projection moves the socket's
            # inner wall that way, so it gets the dark and the plate mostly doesn't)
            c.stroke(P([(s + 0.02, y) for s, y in MASK_HOLE + MASK_HOLE[:1]]), 0.06 * k, "#2a211c", alpha=0.95)
            # the upper jaw: shadow over the teeth and the gaps between them
            c.stroke(P(MASK_JAW), 0.016 * k, shade(self.color, -0.6), alpha=0.8)
            for s, y in ((0.65, 4.455), (0.585, 4.455), (0.455, 4.455), (0.35, 4.455)):
                c.stroke(P([(s, y + 0.005), (s + 0.004, y - 0.025)]), 0.008 * k, shade(self.color, -0.55),
                         alpha=0.6)
            # the snout: a nostril slit with a lit rim
            sx, sy = MASK_SNOUT
            c.stroke(P([(sx - 0.03, sy + 0.012), (sx, sy - 0.002), (sx + 0.025, sy - 0.022)]), 0.02 * k,
                     shade(self.color, -0.85), taper=(0.5, 1.0))
            c.stroke(P([(sx - 0.03, sy + 0.03), (sx + 0.005, sy + 0.017), (sx + 0.035, sy - 0.005)]), 0.008 * k,
                     shade(self.color, 0.4), alpha=0.7)
            for pts in MASK_CRACKS:
                c.stroke(P(pts), 0.016 * k, shade(self.color, -0.75), taper=(1.0, 0.25))
                c.stroke(P([(s + 0.008, y - 0.006) for s, y in pts]), 0.007 * k, shade(self.color, 0.4),
                         alpha=0.6, taper=(1.0, 0.2))
            for pts in MASK_CLAWS:  # war paint: three claw marks
                c.stroke(P(pts), 0.05 * k, GLOW_DEEP, alpha=0.4, taper=(0.4, 0.3))
                c.stroke(P(pts), 0.03 * k, GLOW, taper=(0.5, 0.25))
                c.stroke(P(pts), 0.011 * k, GLOW_HOT, alpha=0.7, taper=(0.5, 0.2))
        c.material(self.metal, self.rough)


class Pelt(Style):
    """Shaggy fur, projected from the front: strands hanging down, dark at
    the root and light at the tip. `span` (set once the pelt is built) is the
    studs the swatch covers across and up, so the strands come out the same
    size."""

    projection = "front"
    size = (192, 224)

    def __init__(self, color, **kw):
        super().__init__(color, **kw)
        self.span = (1.0, 1.0)

    def paint(self, c):
        su, sv = self.span
        c.gradient((0.5, 0.0), (0.5, 1.0), shade(FUR, -0.3), shade(FUR, 0.1))
        rng = np.random.default_rng(13)
        for _ in range(int(su * sv * 1100)):  # strands hanging down: dark roots, light tips
            u, v = rng.uniform(-0.05, 1.05), rng.uniform(-0.05, 1.12)
            ln, lean = rng.uniform(0.06, 0.15) / sv, rng.uniform(-0.025, 0.025) / su
            w = rng.uniform(0.014, 0.028) / su
            tone = rng.uniform(-0.25, 0.25)
            c.stroke([(u, v), (u + lean, v - ln)], w, shade(FUR_ROOT, tone), alpha=0.55, taper=(1.0, 0.2))
            c.stroke([(u + lean * 0.3, v - ln * 0.35), (u + lean, v - ln)], w * 0.6, shade(FUR_TIP, tone),
                     alpha=0.55, taper=(1.0, 0.1))
        c.material(0.0, 0.9)


class Leaf(Style):
    """A jungle leaf: darker at the stem, warm toward the tip, one half in
    shade, a pale midrib and veins. `uv` (set once the leaf is built) maps
    points on it to the swatch."""

    size = (64, 96)
    rough = 0.45

    def __init__(self, color, **kw):
        super().__init__(color, **kw)
        self.uv = None

    def paint(self, c):
        c.fill(self.color)
        if self.uv:
            def P(pts):
                return [self.uv(p) for p in pts]

            k = 1.0 / self.span  # studs -> swatch units
            c.gradient(self.uv(self.stem), self.uv(self.tip), LEAF_SHADE, LEAF_TIP)
            c.poly(P(self.half), LEAF_SHADE, alpha=0.45)
            for vein in self.veins:
                c.stroke(P(vein), 0.008 * k, shade(LEAF_TIP, 0.15), alpha=0.5, taper=(1.0, 0.2))
            c.stroke(P(self.midrib), 0.014 * k, shade(LEAF_TIP, 0.35), alpha=0.85, taper=(1.0, 0.3))
            c.stroke(P(self.outline + self.outline[:1]), 0.01 * k, shade(LEAF_SHADE, -0.35), alpha=0.7)
        c.material(self.metal, self.rough)


# Accessory geometry -----------------------------------------------------------------------------------

UP = Vector((0, 1, 0))


def band_point(s, y, out):
    """A point off the head at band coordinates (s, y)."""
    return A.Avatar.head_point(math.degrees(s / A.HEAD_R), y, out)[0]


def head_tangent(angle):
    """The head's horizontal tangent at `angle`, toward the fighter's right."""
    a = math.radians(angle)
    return Vector((math.cos(a), 0.0, math.sin(a)))


def spline(points, steps=6):
    """A smooth Catmull-Rom curve through `points`."""
    P = [Vector(p) for p in points]
    ext = [2 * P[0] - P[1]] + P + [2 * P[-1] - P[-2]]
    out = []
    for i in range(1, len(ext) - 2):
        p0, p1, p2, p3 = ext[i - 1], ext[i], ext[i + 1], ext[i + 2]
        for k in range(steps):
            t = k / steps
            out.append(0.5 * (2 * p1 + (p2 - p0) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t
                              + (3 * p1 - p0 - 3 * p2 + p3) * t ** 3))
    out.append(P[-1])
    return out


def taper(tip):
    """A radius profile from 1 at the root to `tip` at the end."""
    return lambda f: tip + (1.0 - tip) * (1.0 - f) ** 0.75


def tube(mb, points, radius, style, across=None, flat=1.0, profile=None, segments=8, steps=6):
    """A smooth tube along a curve through `points`, closing to a point at
    the end: round, or `flat` times as thick as it is wide, lying flat along
    `across` (an anime hair clump); `profile(f)` scales the radius from the
    root (f = 0) to the end (f = 1). Returns the curve."""
    path = spline(points, steps)
    run = [0.0]
    for a, b in zip(path, path[1:]):
        run.append(run[-1] + (b - a).length)
    total = run[-1] or 1.0
    ref = Vector(across) if across is not None else None
    verts, faces = [], []
    for i, p in enumerate(path[:-1]):
        tan = (path[i + 1] - path[max(i - 1, 0)]).normalized()
        a = ref.copy() if ref is not None else UP.cross(tan)
        a = a - tan * a.dot(tan)
        if a.length < 1e-4:
            a = Vector((1, 0, 0)) - tan * tan.x
        a.normalize()
        b = tan.cross(a)
        r = radius * (profile(run[i] / total) if profile else 1.0)
        for k in range(segments):
            ph = 2 * math.pi * k / segments
            verts.append(tuple(p + a * (r * math.cos(ph)) + b * (r * flat * math.sin(ph))))
    rings = len(path) - 1
    verts.append(tuple(path[-1]))
    for i in range(rings - 1):
        for k in range(segments):
            q = (k + 1) % segments
            faces.append((i * segments + k, i * segments + q, (i + 1) * segments + q, (i + 1) * segments + k))
    tip = len(verts) - 1
    last = (rings - 1) * segments
    for k in range(segments):
        faces.append((last + k, last + (k + 1) % segments, tip))
    faces.append(tuple(reversed(range(segments))))
    mb.polys(verts, faces, style, smooth=True)
    return path


def inside(poly, p):
    """Whether point p is inside polygon `poly` (even-odd)."""
    x, y = p
    hit = False
    for (x1, y1), (x2, y2) in zip(poly, poly[1:] + poly[:1]):
        if (y1 > y) != (y2 > y) and x < (x2 - x1) * (y - y1) / (y2 - y1) + x1:
            hit = not hit
    return hit


def edge_distance(poly, p):
    """The distance from p to the outline of `poly`."""
    best = 1e9
    for a, b in zip(poly, poly[1:] + poly[:1]):
        ax, ay = b[0] - a[0], b[1] - a[1]
        t = max(0.0, min(1.0, ((p[0] - a[0]) * ax + (p[1] - a[1]) * ay) / (ax * ax + ay * ay or 1e-12)))
        best = min(best, math.hypot(p[0] - a[0] - t * ax, p[1] - a[1] - t * ay))
    return best


def densify(poly, step):
    """The closed outline with extra points so no edge is longer than `step`."""
    out = []
    for a, b in zip(poly, poly[1:] + poly[:1]):
        n = max(1, int(math.ceil(math.dist(a, b) / step)))
        out += [(a[0] + (b[0] - a[0]) * k / n, a[1] + (b[1] - a[1]) * k / n) for k in range(n)]
    return out


def mask(av):
    """Half a cracked beast-skull mask over his right eye: a bone plate
    following the head just off its surface (triangulated in head-band
    coordinates, so any outline works), thick around the socket and heaviest
    over the brow, swelling into a snout beside the broken edge and ending
    in a row of teeth along his cheek."""
    outline, hole = densify(MASK_OUTLINE, 0.04), densify(MASK_HOLE, 0.04)
    pts = outline + hole
    edges = [(i, (i + 1) % len(outline)) for i in range(len(outline))]
    edges += [(len(outline) + i, len(outline) + (i + 1) % len(hole)) for i in range(len(hole))]
    step = 0.05
    for j, y in enumerate(np.arange(4.36, 4.93, step * 0.87)):
        for s in np.arange(-0.06, 0.82, step):
            q = (s + (step / 2 if j % 2 else 0.0), y)
            if inside(MASK_OUTLINE, q) and not inside(MASK_HOLE, q) and \
                    min(edge_distance(MASK_OUTLINE, q), edge_distance(MASK_HOLE, q)) > step * 0.55:
                pts.append(q)
    coords, _, tris, *_ = delaunay_2d_cdt([Vector(p) for p in pts], edges, [], 0, 1e-6)
    flat = [(v.x, v.y) for v in coords]

    def kept(f):
        c = (sum(flat[i][0] for i in f) / len(f), sum(flat[i][1] for i in f) / len(f))
        return inside(MASK_OUTLINE, c) and not inside(MASK_HOLE, c)

    tris = [f for f in tris if kept(f)]

    def thick(s, y):
        brow = max(0.0, min(1.0, (y - 4.6) / 0.12))
        rim = math.exp(-(edge_distance(MASK_HOLE, (s, y)) / 0.075) ** 2) * (0.028 + 0.028 * brow)
        sx, sy = MASK_SNOUT
        snout = 0.03 * math.exp(-((s - sx) / 0.06) ** 2 - ((y - sy) / 0.05) ** 2)
        return 0.026 + rim + snout

    n = len(flat)
    verts = [tuple(band_point(s, y, MASK_IN)) for s, y in flat]
    verts += [tuple(band_point(s, y, MASK_IN + thick(s, y))) for s, y in flat]
    faces, count = [], {}
    for f in tris:
        faces.append(tuple(i + n for i in f))
        faces.append(tuple(reversed(f)))
        for a, b in zip(f, f[1:] + f[:1]):
            count[frozenset((a, b))] = count.get(frozenset((a, b)), 0) + 1
    for e, k in count.items():
        if k == 1:  # the rims: around the outline and the socket
            a, b = tuple(e)
            faces.append((a, b, b + n, a + n))
    mb = av.builder()
    mb.polys(verts, faces, "bone", smooth=True)
    bmesh.ops.recalc_face_normals(mb.bm, faces=mb.bm.faces)

    # paint the details where they belong: the swatch is projected across x
    xs = [v.co.x for v in mb.bm.verts]
    ys = [v.co.y for v in mb.bm.verts]
    lo_x, hi_x, lo_y, hi_y = min(xs), max(xs), min(ys), max(ys)
    st = av.styles["bone"]
    st.span = hi_x - lo_x

    def uv(s, y):
        p = band_point(s, y, MASK_IN + 0.04)
        return ((hi_x - p.x) / (hi_x - lo_x), (y - lo_y) / (hi_y - lo_y))

    st.uv = uv
    av.piece(mb, bone="Neck", name="Mask")
    return mb


MANE_LOCKS = [  # (angle from the front, height, (up, out, back), length, radius, droop)
    # the crown: big clumps standing up and sweeping back
    (0, 5.2, (0.8, 0.5, 0.35), 0.6, 0.2, 0.0), (32, 5.18, (0.75, 0.5, 0.5), 0.6, 0.19, 0.03),
    (-32, 5.18, (0.75, 0.5, 0.5), 0.62, 0.19, 0.03), (12, 5.3, (0.85, 0.1, 0.85), 0.68, 0.2, 0.05),
    (-20, 5.3, (0.85, 0.1, 0.9), 0.64, 0.2, 0.05), (65, 5.15, (0.6, 0.45, 0.55), 0.56, 0.19, 0.04),
    (-65, 5.15, (0.6, 0.45, 0.55), 0.58, 0.19, 0.04),
    # the sides: swept back, staying out of the space the raised arms swing through
    (92, 5.04, (0.3, 0.42, 0.85), 0.62, 0.19, 0.05), (-92, 5.04, (0.3, 0.42, 0.85), 0.62, 0.19, 0.05),
    (118, 5.18, (0.5, 0.35, 0.85), 0.64, 0.19, 0.05), (-118, 5.18, (0.5, 0.35, 0.85), 0.64, 0.19, 0.05),
    # the back: long clumps fanning out and back, the lower ones drooping over
    # the dreads (the pelt only covers his right shoulder, well below them)
    (150, 5.2, (0.45, 0.6, 0.8), 0.66, 0.2, 0.06), (-150, 5.2, (0.45, 0.6, 0.8), 0.66, 0.2, 0.06),
    (180, 5.24, (0.6, 0.2, 1.0), 0.66, 0.2, 0.06),
    (135, 4.95, (-0.25, 0.5, 0.8), 0.58, 0.19, 0.12), (-135, 4.95, (-0.25, 0.5, 0.8), 0.58, 0.19, 0.12),
    (162, 4.92, (-0.4, 0.35, 0.85), 0.62, 0.2, 0.15), (-162, 4.92, (-0.4, 0.35, 0.85), 0.6, 0.2, 0.15),
]


def mane(av):
    """The wild mane: a cap and a mass over the back of the head, big
    flattened clumps that bulge out and sweep up and back, thick locks
    falling over his left brow, two locks flicking up over the mask and a
    sideburn, melted into one and carved off the scalp."""
    mb = av.builder()
    mb.sphere((0, 5.12, 0.08), (0.68, 0.38, 0.7), "mane", segments=28, rings=14)
    mb.sphere((0, 4.96, 0.28), (0.7, 0.42, 0.58), "mane", segments=28, rings=14)
    rng = np.random.default_rng(5)
    for ang, y, (up, out, back), length, radius, droop in MANE_LOCKS:
        ang += rng.uniform(-4, 4)
        p, n = av.head_point(ang, min(y, A.HEAD_TOP - 0.02), out=0.04)
        d = (n * out + Vector((0, up, back))).normalized()
        length *= rng.uniform(0.92, 1.08)
        pts = [p, p + d * (length * 0.4) + n * 0.08 - UP * (droop * 0.15),
               p + d * (length * 0.75) + n * 0.05 - UP * (droop * 0.5), p + d * length - UP * droop]
        across = d.cross(n)
        tube(mb, pts, radius, "mane", across=across if across.length > 0.25 else head_tangent(ang), flat=0.72,
             profile=taper(0.04 / radius))
    for ang, swing, drop, radius in ((-4, -14, 0.38, 0.15), (-24, -14, 0.4, 0.16), (-44, -12, 0.36, 0.15)):
        root, n = av.head_point(ang, 5.22, out=0.05)  # locks falling over his left brow
        tip, _ = av.head_point(ang + swing, 5.22 - drop, out=0.13)
        tube(mb, [root, (root + tip) / 2 + n * 0.1, tip], radius, "mane", across=head_tangent(ang), flat=0.5,
             profile=taper(0.04 / radius))
    for ang, swing in ((14, 18), (38, 16)):  # flicking up and out over the mask
        root, n = av.head_point(ang, 5.18, out=0.05)
        tip, _ = av.head_point(ang + swing, 5.12, out=0.32)
        tube(mb, [root, (root + tip) / 2 + n * 0.03 + UP * 0.04, tip], 0.14, "mane", across=head_tangent(ang),
             flat=0.55, profile=taper(0.04 / 0.14))
    top, n = av.head_point(-82, 5.0, out=0.045)  # the sideburn on his left, lying close to the head
    tip, _ = av.head_point(-76, 4.52, out=0.03)
    tube(mb, [top, (top + tip) / 2 + n * 0.015, tip], 0.1, "mane", across=head_tangent(-80), flat=0.45,
         profile=taper(0.03 / 0.1))
    out = A.melt(mb, voxel=0.022, smooth=4, tris=3400, carve_head=True)
    av.piece(out, bone="Neck", name="Mane")
    return out


LEAVES = [  # (angle around the head, height, turn from straight up the hair, length)
    (-58, 5.08, -62, 0.34), (146, 5.28, 48, 0.34),
]


def leaf(mb, base, d, side, up, length, width, style, dip=0.05):
    """An ovate jungle leaf from `base` along `d`, spread along `side`,
    folded a little along the midrib and curling up (`up`) toward the tip,
    its stem diving `dip` into the hair (steeply, so the two never lie flat
    on each other). Returns its outline, midrib, veins and shaded half (for
    the paint)."""
    cols = (-1.0, -0.5, 0.0, 0.5, 1.0)
    rows = []
    for i in range(9):
        t = i / 8
        half = width * 0.5 * max(0.04, math.sin(math.pi * t ** 0.8)) ** 0.85
        c = base + d * (length * t) + up * (0.07 * t * t - dip * max(0.0, 1.0 - t / 0.3) ** 2)
        rows.append([tuple(c + side * (half * k) + up * (0.022 * (1 - abs(k)) * math.sin(math.pi * t)))
                     for k in cols])
    sheet(mb, rows, 0.014, style)
    V = [[Vector(p) for p in row] for row in rows]
    outline = [r[0] for r in V] + [r[-1] for r in reversed(V)]
    midrib = [r[2] for r in V]
    veins = [[V[i][2], V[i + 1][0] * 0.75 + V[i + 1][2] * 0.25] for i in (2, 4, 6)]
    veins += [[V[i][2], V[i + 1][-1] * 0.75 + V[i + 1][2] * 0.25] for i in (2, 4, 6)]
    return outline, midrib, veins, midrib + [r[-1] for r in reversed(V)]


def leaves(av, mane_mb):
    """Two leaves caught in the mane, lying along the hair with their stems
    tucked in: one over his left temple, one at the back of his crown. Each
    has its own swatch, projected the way it faces, so the midrib and veins
    are painted along it."""
    tree = BVHTree.FromBMesh(mane_mb.bm)
    mb = av.builder()
    for k, (ang, y, spin, length) in enumerate(LEAVES):
        key = f"leaf{k}"
        st = av.styles[key]
        a = math.radians(ang)
        far = Vector((1.8 * math.sin(a), y, -1.8 * math.cos(a)))
        hit, normal, _, _ = tree.ray_cast(far, (Vector((0, y, 0.1)) - far).normalized())
        if hit is None:
            av.warnings.append(f"leaf at {ang} found no hair")
            continue
        normal = normal.normalized()
        tangent = (UP - normal * normal.y).normalized()
        d = Matrix.Rotation(math.radians(spin), 3, normal) @ tangent
        d = (d * math.cos(0.08) + normal * math.sin(0.08)).normalized()  # lying almost flat on the hair
        side = d.cross(normal).normalized()
        up = side.cross(d).normalized()
        before = set(mb.bm.verts)
        outline, midrib, veins, half = leaf(mb, hit + normal * 0.025 - d * 0.03, d, side, up, length, length * 0.7,
                                            key)
        verts = [v.co.copy() for v in set(mb.bm.verts) - before]
        lo = Vector([min(v[i] for v in verts) for i in range(3)])
        hi = Vector([max(v[i] for v in verts) for i in range(3)])
        st.projection = "side" if abs(up.x) > abs(up.z) else "front"
        ax = 2 if st.projection == "side" else 0
        st.span = hi[ax] - lo[ax]
        st.uv = lambda p, lo=lo, hi=hi, ax=ax: ((hi[ax] - p[ax]) / (hi[ax] - lo[ax]), (p.y - lo.y) / (hi.y - lo.y))
        st.stem, st.tip, st.outline, st.midrib, st.veins, st.half = midrib[0], midrib[-1], outline, midrib, veins, half
    av.piece(mb, bone="Neck", name="Leaves")
    return mb


DREAD_CHAIN = [(0, 4.62, 0.74), (0, 4.2, 0.95), (0, 3.6, 0.95), (0, 2.95, 0.85)]
DREADS = [  # (x at the root, x at the end, z offset, end height, radius)
    (-0.17, -0.4, 0.03, 2.95, 0.1), (-0.1, -0.22, 0.13, 2.62, 0.115), (-0.03, -0.08, -0.03, 3.18, 0.12),
    (0.05, 0.12, 0.1, 2.78, 0.1), (0.12, 0.27, -0.02, 3.05, 0.11), (0.19, 0.42, 0.08, 2.7, 0.085),
]
BEADS = [  # (dread, height, kind)
    (1, 3.3, "bead"), (4, 3.55, "cord"), (3, 3.05, "bead"),
]


def dreads(av):
    """The heaviest dreadlocks falling from the back of the mane and down his
    back on a sway chain from the head (clear of the pelt): a bundle with
    depth (each lock at its own distance from the back), fanning out toward
    lumpy, tapering ends of different lengths, with two bone beads and a cord
    wrap on separate locks (a piece of their own: a melted mesh keeps one
    style)."""
    sw = av.sway("Dreads", "Neck", DREAD_CHAIN, stiffness=0.3, damping=0.16, limit=55, behind=1)
    mb = av.builder()
    paths = []
    for x0, x1, dz, end, radius in DREADS:
        pts = [(x0 * 0.8, 4.74, 0.58 + dz * 0.3), (x0 + (x1 - x0) * 0.3, 4.22, 0.95 + dz),
               (x0 + (x1 - x0) * 0.65, 3.6, 0.95 + dz), (x1, end, 0.85 + dz + (end - 2.95) * 0.25)]

        def lumpy(f, seed=len(paths) * 1.7, radius=radius):
            ends = 1.0 if f < 0.72 else 1.0 - (f - 0.72) / 0.28 * (1.0 - 0.04 / radius)
            return (1.0 + 0.07 * math.sin(f * 40.0 + seed)) * ends

        paths.append((tube(mb, pts, radius, "dreads", across=(1, 0, 0), profile=lumpy, segments=8, steps=8),
                      radius, lumpy))
    out = A.melt(mb, voxel=0.018, smooth=3, tris=1500, carve_head=True)  # the roots end in the mane
    av.piece(out, sway=sw, name="Dreads")

    beads = av.builder()
    for i, y, kind in BEADS:
        path, radius, lumpy = paths[i]
        j = min(range(1, len(path) - 1), key=lambda j: abs(path[j].y - y))
        tan = (path[j + 1] - path[j - 1]).normalized()
        rot = UP.rotation_difference(tan).to_matrix()
        r = radius * lumpy(j / (len(path) - 1)) * 1.07
        if kind == "bead":
            beads.sphere(tuple(path[j]), (r + 0.04, 0.07, r + 0.04), "bead", rotation=rot, segments=10, rings=7)
        else:
            for k in (-1, 0, 1):
                beads.torus(tuple(path[j] + tan * (k * 0.045)), r * 0.93, 0.032, "cord", rotation=rot,
                            segments=12, sides=6)
    av.piece(beads, sway=sw, name="Beads")
    return out, beads


PELT_FRONT, PELT_BACK = 3.32, 3.26  # where the pelt's flaps end, in front and behind
PELT_OUT = 0.86  # its outer edge: its edge tufts reach toward the arm, never into it


def drape(s, front, back, gap, r):
    """The path over his right shoulder, `gap` off the body: up the front of
    the chest from y = front, over the rounded edges and the top, down the
    back to y = back. Returns (z, y) and the outward normal (nz, ny) at
    distance s along it, and the total length."""
    R = r + gap
    parts = [(4.0 - r - front, "front"), (math.pi / 2 * R, "arc0"), (1.0 - 2 * r, "top"),
             (math.pi / 2 * R, "arc1"), (4.0 - r - back, "back")]
    total = sum(ln for ln, _ in parts)
    if s is None:
        return total
    for ln, kind in parts:
        if s <= ln or kind == "back":
            break
        s -= ln
    if kind == "front":
        return (-0.5 - gap, front + s), (-1.0, 0.0)
    if kind == "arc0":
        a = math.pi - s / R
        return (-0.5 + r + R * math.cos(a), 4.0 - r + R * math.sin(a)), (math.cos(a), math.sin(a))
    if kind == "top":
        return (-0.5 + r + s, 4.0 + gap), (0.0, 1.0)
    if kind == "arc1":
        a = math.pi / 2 - s / R
        return (0.5 - r + R * math.cos(a), 4.0 - r + R * math.sin(a)), (math.cos(a), math.sin(a))
    return (0.5 + gap, 4.0 - r - s), (1.0, 0.0)


def pelt(av):
    """A shaggy beast pelt slung over his right shoulder: a thick hide
    draped over the shoulder's rounded edges, one flap hanging down his
    chest and one down his back, each ending in a ragged edge with two
    paws, curving around his neck on the inside. Rows of short tufts lie
    over it, flowing down the flaps and out over the shoulder, and a fringe
    hangs from the flaps. It covers his right shoulder only: in his weapon
    stances (idle, block, jump) the support forearm rests across the left
    shoulder and in front of his neck, where a collar would always be cut."""
    gap, r = 0.04, 0.15
    rows, cols = 22, 8
    total = drape(None, PELT_FRONT, PELT_BACK, gap, r)

    def inner_x(z, y):
        """The inner edge: around the neck on top, running down toward the
        middle of the chest and back on the flaps."""
        flap = 0.2 + 0.26 * max(0.0, min(1.0, (y - 3.45) / 0.45))
        neck = math.sqrt(max(0.0, 0.66 ** 2 - z * z)) if y > 3.9 else 0.0
        return max(flap, neck)

    def paws(v):  # the ragged bottom edge: two paws, the inner one longer
        return 0.13 * math.exp(-((v - 0.16) / 0.1) ** 2) + 0.09 * math.exp(-((v - 0.78) / 0.09) ** 2)

    inner, outer = [], []
    for i in range(rows + 1):
        s = total * i / rows
        (z, y), (nz, ny) = drape(s, PELT_FRONT, PELT_BACK, gap, r)
        n = Vector((0.0, ny, nz))
        end = abs(i - rows / 2) / (rows / 2)  # 0 on top of the shoulder, 1 at the flap ends
        row_in, row_out = [], []
        for j in range(cols + 1):
            v = j / cols
            x = inner_x(z, y) + (PELT_OUT - inner_x(z, y)) * v
            drop = paws(v) if i in (0, rows) else 0.0
            p = Vector((x, y - drop, z))
            t = 0.05 + 0.1 * math.sin(math.pi * (0.08 + v * 0.84)) ** 0.6 * (1.0 - 0.4 * end ** 2)
            row_in.append(p)
            row_out.append(p + n * t)
        inner.append(row_in)
        outer.append(row_out)
    verts = [tuple(p) for row in inner for p in row] + [tuple(p) for row in outer for p in row]
    m = (rows + 1) * (cols + 1)

    def idx(i, j, side):
        return side * m + i * (cols + 1) + j

    faces = []
    for i in range(rows):
        for j in range(cols):
            faces.append((idx(i, j, 1), idx(i, j + 1, 1), idx(i + 1, j + 1, 1), idx(i + 1, j, 1)))
            faces.append((idx(i + 1, j, 0), idx(i + 1, j + 1, 0), idx(i, j + 1, 0), idx(i, j, 0)))
    for i in range(rows):  # the rims along the inner and outer edges
        faces.append((idx(i, 0, 0), idx(i, 0, 1), idx(i + 1, 0, 1), idx(i + 1, 0, 0)))
        faces.append((idx(i + 1, cols, 0), idx(i + 1, cols, 1), idx(i, cols, 1), idx(i, cols, 0)))
    for j in range(cols):  # and across the flap ends
        faces.append((idx(0, j + 1, 0), idx(0, j + 1, 1), idx(0, j, 1), idx(0, j, 0)))
        faces.append((idx(rows, j, 0), idx(rows, j, 1), idx(rows, j + 1, 1), idx(rows, j + 1, 0)))
    mb = av.builder()
    mb.polys(verts, faces, "fur", smooth=True)
    bmesh.ops.recalc_face_normals(mb.bm, faces=mb.bm.faces)

    def normal(u):
        _, (nz, ny) = drape(total * u, PELT_FRONT, PELT_BACK, gap, r)
        return Vector((0.0, ny, nz))

    def surface(u, v):
        """A point on the pelt's outer surface, the outward normal and the way
        down the drape toward the nearer flap end."""
        i = min(rows - 1, int(u * rows))
        j = min(cols - 1, int(v * cols))
        a, b = (outer[k][j].lerp(outer[k][j + 1], v * cols - j) for k in (i, i + 1))
        return a.lerp(b, u * rows - i), normal(u), (a - b if u < 0.5 else b - a).normalized()

    def tuft(root, d, across, length, width, depth):
        """A pointed, flattened tuft from `root` along `d`, spread `across`."""
        across = (across - d * across.dot(d)).normalized()
        rot = Matrix((across, d, across.cross(d))).transposed()
        mb.loft([(0, -0.05, 0, width, depth), (0, length * 0.45, 0, width * 0.78, depth * 0.85),
                 (0, length, 0, 0, 0)], "fur", center=tuple(root), rotation=rot, segments=8)

    def fits(path, near=0.05):
        return all(abs(p.x) < 0.93 for p in path) and min(A.body_sdf(tuple(p)) for p in path) > near

    rng = np.random.default_rng(3)
    xaxis = Vector((1, 0, 0))
    for k in range(5):  # staggered rows of tufts, flowing down the flaps and out over the shoulder
        for u in np.arange(0.05 + 0.08 * (k % 2), 0.97, 0.16):
            v = 0.14 + k * 0.18 + rng.uniform(-0.04, 0.04)
            u += rng.uniform(-0.025, 0.025)
            root, n, down = surface(u, v)
            d = (down * 0.8 + xaxis * (0.2 + 0.3 * v) + n * 0.28).normalized()
            length = rng.uniform(0.14, 0.2)
            if fits([root + d * (length * f) for f in (0.3, 0.6, 1.0)]):
                tuft(root - n * 0.03, d, n.cross(d), length, rng.uniform(0.1, 0.12), 0.05)
    for i in range(1, rows):  # ragged edges: tufts sticking out sideways and down along both edges
        for j, sx in ((cols, 1), (0, -1)):
            p, n = outer[i][j], normal(i / rows)
            down = (outer[i - 1][j] - outer[i + 1][j]) if i < rows / 2 else (outer[i + 1][j] - outer[i - 1][j])
            d = (xaxis * (0.75 * sx) + down.normalized() * 0.65 + n * 0.1).normalized()
            length = rng.uniform(0.1, 0.17)
            if i % 2 == (0 if sx > 0 else 1) and fits([p + d * (length * f) for f in (0.3, 0.6, 1.0)]):
                tuft(p - n * 0.04 - xaxis * (0.04 * sx), d, n, length, rng.uniform(0.08, 0.1), 0.05)
    for i in (0, rows):  # a fringe hanging from the ragged flap ends
        for v in np.linspace(0.04, 0.96, 8):
            v += rng.uniform(-0.02, 0.02)
            p = inner[i][0].lerp(inner[i][cols], v) * 0.5 + outer[i][0].lerp(outer[i][cols], v) * 0.5
            p.y -= paws(v)
            d = (Vector((0, -1, 0)) + normal(i / rows) * 0.15).normalized()
            length = rng.uniform(0.12, 0.2)
            if fits([p + d * (length * f) for f in (0.3, 0.6, 1.0)], near=0.04):
                tuft(p + Vector((0, 0.05, 0)), d, xaxis, length, rng.uniform(0.09, 0.11), 0.05)
    out = A.melt(mb, voxel=0.02, smooth=3, tris=2000)
    widest = max(v.co.x for v in out.bm.verts)
    if widest > 0.95:
        av.warnings.append(f"Pelt reaches x = {widest:.2f}, where the arm swings")
    av.piece(out, bone="Waist", name="Pelt")
    st = av.styles["fur"]  # the swatch is projected across x: strands sized in studs
    xs = [v.co.x for v in out.bm.verts]
    ys = [v.co.y for v in out.bm.verts]
    st.span = (max(xs) - min(xs), max(ys) - min(ys))
    return out


# Checks between accessories: the builder only checks that pieces don't lie
# flat on each other; these need real clearance, since the head turns
# against the pelt and the dreads swing over it.


def gap(a, b):
    """The smallest distance from a's vertices to b's surface, or -1 when an
    edge of a passes through b."""
    tree = BVHTree.FromBMesh(b.bm)
    for e in a.bm.edges:
        p, q = e.verts[0].co, e.verts[1].co
        if (q - p).length > 1e-6 and tree.ray_cast(p, q - p, (q - p).length)[0] is not None:
            return -1.0
    return min(tree.find_nearest(v.co)[3] for v in a.bm.verts)


CLEARANCE = [("Mask", "Mane", 0.02), ("Mask", "Pelt", 0.15), ("Mane", "Pelt", 0.2),
             ("Dreads", "Pelt", 0.12), ("Beads", "Pelt", 0.12), ("Leaves", "Mask", 0.02)]


def check(av, pieces):
    for a, b, need in CLEARANCE:
        g = min(gap(pieces[a], pieces[b]), gap(pieces[b], pieces[a]))
        print(f"[{NAME}] {a} <-> {b}: {g:.3f}")
        if g < need:
            av.warnings.append(f"{a} and {b} come within {g:.3f} studs of each other (need {need})")


def model(av):
    av.style("mane", Mane(MANE, shine=0, strands=26, shine_color=MANE_SHINE))
    av.style("dreads", Dreads(MANE))
    av.style("bone", Bone(BONE))
    av.style("fur", Pelt(FUR))
    av.style("bead", Style(BONE, rough=0.5, light=0.1, dark=-0.25, size=(32, 64)))
    av.style("cord", Style(ROPE, rough=0.85, light=0.2, dark=-0.35, size=(32, 64)))
    for k in range(len(LEAVES)):
        av.style(f"leaf{k}", Leaf(LEAF))
    pieces = {"Mane": mane(av), "Mask": mask(av), "Pelt": pelt(av)}
    pieces["Dreads"], pieces["Beads"] = dreads(av)
    pieces["Leaves"] = leaves(av, pieces["Mane"])
    check(av, pieces)


# The printed outfit -------------------------------------------------------------------------------------


V_NECK = [(-0.52, 4.05), (-0.45, 3.9), (-0.39, 3.84), (-0.34, 3.68), (-0.25, 3.58), (-0.22, 3.42), (-0.13, 3.33),
          (-0.09, 3.16), (0.0, 3.0), (0.06, 3.13), (0.13, 3.22), (0.18, 3.39), (0.27, 3.47), (0.31, 3.63),
          (0.39, 3.74), (0.43, 3.89), (0.52, 4.05)]
KNOT_X = -0.45  # the rope belt's knot, on his left hip


def top(t):
    """The torn sleeveless top: a ragged hem torn on a slant over his bare
    midriff, a ragged V neck showing the glowing mark on his chest, claw
    rips, a crude repair, the pelt's shadow under its flaps and the head's
    round the neck."""
    for f in t.sides:  # skin first: the midriff, the chest
        f.gradient((0, 2.0), (0, 4.0), shade(SKIN, -0.14), shade(SKIN, 0.1))
    f = t.front
    f.stroke([(0, 2.3), (0, 2.78)], 0.022, shade(SKIN, -0.45), alpha=0.6)  # abs
    for y in (2.44, 2.62):
        for sx in (-1, 1):
            f.stroke([(sx * 0.05, y), (sx * 0.26, y + 0.025)], 0.02, shade(SKIN, -0.45), alpha=0.5)
            f.stroke([(sx * 0.07, y + 0.03), (sx * 0.24, y + 0.05)], 0.012, shade(SKIN, 0.25), alpha=0.4)
    for sx in (-1, 1):
        f.stroke([(sx * 0.6, 2.28), (sx * 0.45, 2.75)], 0.03, shade(SKIN, -0.4), alpha=0.4)
    torn_region(t, 2.6, 0.075, 26, 4, 4.1, TOP, slope=0.15)  # 2.75 on his right down to 2.45 on his left
    # light across the chest and shoulders, folds pulling toward the waist
    for f in (t.front, t.back):
        vgrad(f, 3.4, 4.0, shade(TOP, 0.0), shade(TOP, 0.14), alpha=0.6)
    folds(t.front, [[(-0.85, 3.3), (-0.7, 3.05), (-0.62, 2.8)], [(0.82, 3.2), (0.7, 2.98), (0.66, 2.85)],
                    [(0.45, 2.95), (0.38, 2.8)], [(-0.3, 2.95), (-0.22, 2.75)]], TOP, alpha=0.7)
    # the V neck: skin, a shadow under the cloth's edge, the glowing mark
    f = t.front
    f.poly(V_NECK, SKIN)
    f.gradient((0, 3.0), (0, 3.9), shade(SKIN, -0.1), shade(SKIN, 0.14), clip=V_NECK)
    f.stroke([(-0.32, 3.52), (-0.12, 3.42), (0.0, 3.46), (0.12, 3.42), (0.32, 3.52)], 0.03, shade(SKIN, -0.5),
             alpha=0.55, clip=V_NECK)  # under the pecs
    f.stroke(V_NECK, 0.06, shade(SKIN, -0.6), alpha=0.5, clip=V_NECK)
    mark(f, [(0.0, 3.75), (0.0, 3.08)], 0.034, taper=(1.0, 0.35), clip=V_NECK)
    mark(f, [(-0.17, 3.44), (0.0, 3.34), (0.17, 3.44)], 0.028, clip=V_NECK)
    mark(f, [(-0.12, 3.27), (0.0, 3.19), (0.12, 3.27)], 0.024, clip=V_NECK)
    mark(f, [(-0.3, 3.62), (-0.14, 3.55)], 0.026, taper=(0.4, 1.0), clip=V_NECK)
    mark(f, [(0.3, 3.62), (0.14, 3.55)], 0.026, taper=(0.4, 1.0), clip=V_NECK)
    f.stroke(V_NECK, 0.018, shade(TOP, -0.6))
    f.stroke([(x * 1.06, y + 0.01) for x, y in V_NECK], 0.01, shade(TOP, 0.3), alpha=0.6)
    for k in range(3):  # claw rips across his left side
        rip(f, (-0.92 + k * 0.05, 3.28 - k * 0.15), (-0.5 + k * 0.05, 3.02 - k * 0.15), 0.055, TOP, seed=k)
    stitches(f, (0.5, 3.4), (0.8, 3.08))  # a crude repair on his right
    # the back: shoulder blades, a seam, a rip low on the right
    b = t.back
    for sx in (-1, 1):
        b.stroke([(sx * 0.15, 3.78), (sx * 0.5, 3.42), (sx * 0.82, 3.42)], 0.05, shade(TOP, -0.3), alpha=0.5,
                 taper=(0.3, 1.0))
    folds(b, [[(-0.7, 2.75), (-0.58, 3.0)], [(0.62, 2.85), (0.52, 3.05)]], TOP)
    stitches(b, (0.0, 3.95), (0.0, 2.85), step=0.08, size=0.025)
    rip(b, (0.42, 3.05), (0.86, 2.92), 0.05, TOP, seed=9)
    rip(b, (-0.85, 3.6), (-0.55, 3.42), 0.04, TOP, seed=11)
    for side in (t.right, t.left):  # rough side seams
        stitches(side, (0.0, 3.98), (0.0, 2.85 if side is t.right else 2.6), step=0.09, size=0.022)
    for f, end in ((t.front, PELT_FRONT), (t.back, PELT_BACK)):  # the pelt's shadow under its flaps
        shadow_band(f, end - 0.14, end - 0.01, 0.45, x0=0.18, x1=0.92)
    t.top.fill(TOP)
    t.top.gradient((0, -0.5), (0, 0.5), shade(TOP, 0.1), shade(TOP, -0.1))
    t.top.ellipse(0.0, 0.0, 0.64, 0.5, UNDER, alpha=0.35, blend="multiply")  # the head's shadow round the neck


STRAP_W = 0.1


def strap(t):
    """The pelt's leather strap: from under its front flap across his chest
    to his left hip, round his side and back up to the back flap."""
    runs = [(t.front, (0.86, PELT_FRONT - 0.02), (-1.0, 2.33)), (t.left, (-0.5, 2.33), (0.5, 2.3)),
            (t.back, (-1.0, 2.3), (0.86, PELT_BACK - 0.02))]
    for f, p0, p1 in runs:
        dx, dy = p1[0] - p0[0], p1[1] - p0[1]
        ln = math.hypot(dx, dy)
        nx, ny = -dy / ln, dx / ln
        if ny < 0:
            nx, ny = -nx, -ny

        def off(k):
            return [(p0[0] + nx * k, p0[1] + ny * k), (p1[0] + nx * k, p1[1] + ny * k)]

        f.stroke(off(-0.035), STRAP_W, LINE, alpha=0.3)  # its shadow on the body
        f.stroke(off(0.0), STRAP_W, CORD)
        f.stroke(off(STRAP_W * 0.36), 0.014, shade(CORD, 0.4), alpha=0.7)
        f.stroke(off(-STRAP_W * 0.42), 0.014, shade(CORD, -0.55), alpha=0.85)
        k = 0.02
        while k < ln:  # running stitches down the middle
            a, b = k / ln, min(1.0, (k + 0.028) / ln)
            f.stroke([(p0[0] + dx * a, p0[1] + dy * a), (p0[0] + dx * b, p0[1] + dy * b)], 0.008, ROPE, alpha=0.75)
            k += 0.055


def belt(t):
    """Shorts waistband, the twisted rope belt and its knot on his left hip."""
    t.band(2.0, 2.15, SHORTS)
    t.band(2.0, 2.15, shade(SHORTS, -0.15), alpha=0.5)
    rope(t, 2.12, 2.27)
    f = t.front
    f.ellipse(KNOT_X + 0.015, 2.18, 0.1, 0.085, LINE, alpha=0.4)
    f.ellipse(KNOT_X, 2.195, 0.09, 0.08, ROPE)
    f.stroke([(KNOT_X - 0.07, 2.15), (KNOT_X + 0.06, 2.25)], 0.03, shade(ROPE, -0.35), alpha=0.8)
    f.stroke([(KNOT_X - 0.06, 2.23), (KNOT_X + 0.03, 2.27)], 0.02, shade(ROPE, 0.35), alpha=0.7)
    for x in (KNOT_X - 0.05, KNOT_X + 0.04):  # the ends start down from the knot
        f.stroke([(x, 2.13), (x + 0.01, 1.98)], 0.05, ROPE)
        f.stroke([(x - 0.012, 2.12), (x, 1.98)], 0.012, shade(ROPE, 0.35), alpha=0.7)
    f.stroke([(KNOT_X + 0.1, 2.13), (KNOT_X + 0.12, 1.98)], 0.012, LINE, alpha=0.8)  # the charm's cord
    t.bottom.fill(shade(SHORTS, -0.25))


def charm(leg):
    """The rope ends and the bone charm hanging over his left thigh."""
    f = leg.front
    kx = KNOT_X - leg.cx
    for x, ln in ((kx - 0.05, 0.3), (kx + 0.04, 0.22)):
        f.stroke([(x + 0.01, 2.0), (x + 0.02, 2.0 - ln)], 0.05, ROPE)
        f.stroke([(x, 2.0), (x + 0.008, 2.0 - ln)], 0.012, shade(ROPE, 0.35), alpha=0.7)
        f.stroke([(x + 0.035, 2.0), (x + 0.04, 2.0 - ln)], 0.01, shade(ROPE, -0.4), alpha=0.6)
        for dx in (-0.018, 0.0, 0.018):  # frayed ends
            f.stroke([(x + 0.02 + dx, 2.0 - ln), (x + 0.02 + dx * 1.6, 2.0 - ln - 0.05)], 0.008,
                     shade(ROPE, 0.15))
    cx = kx + 0.12
    f.stroke([(cx, 2.0), (cx + 0.01, 1.86)], 0.012, LINE, alpha=0.8)
    fang = [(cx - 0.05, 1.87), (cx + 0.06, 1.87), (cx + 0.03, 1.75), (cx - 0.005, 1.63), (cx - 0.035, 1.75)]
    f.poly([(x + 0.015, y - 0.02) for x, y in fang], LINE, alpha=0.4)
    f.poly(fang, BONE)
    f.gradient((cx - 0.05, 1.8), (cx + 0.06, 1.8), shade(BONE, 0.1), shade(BONE, -0.3), clip=fang)
    f.stroke(fang + [fang[0]], 0.01, shade(BONE, -0.6))
    f.rect_(cx - 0.05, 1.86, cx + 0.06, 1.89, shade(ROPE, -0.2))
    mark(f, [(cx + 0.005, 1.82), (cx + 0.002, 1.7)], 0.014, taper=(1.0, 0.3))


def shorts(leg, side):
    """Ragged olive shorts frayed at mid-thigh, with a patch sewn over a hole
    on his right thigh."""
    for f in leg.sides:
        f.gradient((0, 0.0), (0, 2.0), shade(SKIN, -0.16), shade(SKIN, 0.08))
    torn_region(leg, 1.42, 0.08, 14, 20 + side, 2.05, SHORTS)
    inner = -side  # toward the other leg
    for f in (leg.front, leg.back):
        folds(f, [[(inner * 0.4, 1.98), (inner * 0.22, 1.78)], [(-inner * 0.35, 1.9), (-inner * 0.2, 1.62)],
                  [(0.1, 1.68), (0.0, 1.52)]], SHORTS, alpha=0.75)
    folds(leg.outer, [[(-0.3, 1.9), (-0.12, 1.7)], [(0.3, 1.8), (0.15, 1.6)]], SHORTS)
    leg.outer.stroke([(0.0, 2.0), (0.0, 1.5)], 0.016, shade(SHORTS, -0.5), alpha=0.7)
    if side > 0:
        f = leg.front
        patch = [(-0.05, 1.86), (0.3, 1.88), (0.32, 1.6), (-0.04, 1.58)]
        f.poly([(x + 0.012, y - 0.015) for x, y in patch], LINE, alpha=0.35)
        f.poly(patch, shade(TOP, -0.05))
        f.gradient((0, 1.58), (0, 1.88), shade(TOP, -0.2), shade(TOP, 0.1), clip=patch)
        for p0, p1 in zip(patch, patch[1:] + patch[:1]):
            stitches(f, p0, p1, step=0.055, size=0.018)
    leg.top.fill(shade(SHORTS, -0.1))


def ties(leg, crosses, color=CORD):
    """A leather cord criss-crossing over the shin wraps: an X on the front
    and back, running straight across the sides so it meets at the corners."""
    for y0, y1 in crosses:
        for f in (leg.front, leg.back):
            for p0, p1 in (((-0.5, y0), (0.5, y1)), ((0.5, y0), (-0.5, y1))):
                f.stroke([p0, p1], 0.05, shade(color, -0.4), alpha=0.5)
                f.stroke([p0, p1], 0.032, color)
                f.stroke([(p0[0], p0[1] + 0.01), (p1[0], p1[1] + 0.01)], 0.01, shade(color, 0.4), alpha=0.6)
        for f in (leg.right, leg.left):
            for y in (y0, y1):
                f.stroke([(-0.5, y), (0.5, y)], 0.032, color)
                f.stroke([(-0.5, y + 0.01), (0.5, y + 0.01)], 0.01, shade(color, 0.4), alpha=0.6)


def leg_wraps(leg, side):
    """Bare knees, linen-wrapped shins and ankles tied with a cord, bare feet."""
    f = leg.front
    f.ellipse(0.0, 1.16, 0.22, 0.12, shade(SKIN, 0.12), alpha=0.5)  # knee cap
    for fc in leg.sides:
        fc.stroke([(-0.5, 1.25), (0.5, 1.25)], 0.016, shade(SKIN, -0.4), alpha=0.35)
    wraps(leg, 0.27, 1.05, WRAP, spacing=0.1, seed=30 + side)
    ties(leg, [(0.36, 0.62), (0.62, 0.88)])
    # the foot: the wraps' shadow, then toes (the big toe on the inside)
    for fc in leg.sides:
        vgrad(fc, 0.0, 0.27, shade(SKIN, -0.08), shade(SKIN, -0.3))
    inner = -side
    widths = [0.25, 0.2, 0.19, 0.18, 0.16]
    x = inner * 0.49
    for k, w in enumerate(widths):
        x1 = x - inner * w
        lo, hi = sorted((x, x1))
        hgt = 0.22 - k * 0.012
        mid, r = (lo + hi) / 2, (hi - lo) / 2 - 0.006
        toe = [(lo + 0.006, 0.0), (hi - 0.006, 0.0)] + [(mid + r * math.cos(a), hgt - r * 0.7 * (1 - math.sin(a)))
                                                      for a in np.linspace(0, math.pi, 9)]
        f.poly(toe, shade(SKIN, 0.08))
        f.gradient((mid, 0.0), (mid, hgt), shade(SKIN, -0.12), shade(SKIN, 0.16), clip=toe)
        f.stroke(toe[1:] + toe[:1], 0.014, shade(SKIN, -0.6), alpha=0.85)
        nail = [(mid + r * 0.55 * math.cos(a), 0.035 + 0.06 * math.sin(a)) for a in np.linspace(0, math.pi, 7)]
        f.poly(nail + [(mid - r * 0.55, 0.03), (mid + r * 0.55, 0.03)], "#a87a5c")
        f.stroke([(mid - r * 0.25, 0.075), (mid, 0.088)], 0.01, "#d9b294", alpha=0.8)
        x = x1
    leg.band(0.0, 0.025, shade(SKIN, -0.55))  # the sole's dirty edge
    leg.bottom.fill(shade(SKIN, -0.45))


def fist(a, side):
    """A clenched fist on the hand: a row of knuckles along the top, four
    curled fingers with their second joints, the thumb laid across them from
    the inner side."""
    f = a.front
    inner = -side
    vgrad(f, 2.0, 2.4, shade(SKIN, -0.32), shade(SKIN, -0.04))
    for k in range(4):
        x0, x1 = -0.48 + k * 0.24, -0.24 + k * 0.24
        m = (x0 + x1) / 2
        finger = [(x0 + 0.012, 2.03), (x1 - 0.012, 2.03), (x1 - 0.012, 2.27), (m + 0.075, 2.335),
                  (m - 0.075, 2.335), (x0 + 0.012, 2.27)]
        f.poly(finger, shade(SKIN, 0.02))
        f.gradient((m, 2.03), (m, 2.335), shade(SKIN, -0.25), shade(SKIN, 0.14), clip=finger)
        f.rect_(x0, 2.0, x1, 2.145, shade(SKIN, -0.3), alpha=0.35, clip=finger)  # the tips, curled under
        f.ellipse(m, 2.3, 0.07, 0.026, shade(SKIN, 0.3), alpha=0.55, clip=finger)  # the knuckle's light
        f.stroke(finger + finger[:1], 0.012, shade(SKIN, -0.62), alpha=0.85)
        f.stroke([(x0 + 0.035, 2.15), (m, 2.142), (x1 - 0.035, 2.15)], 0.013, shade(SKIN, -0.6), alpha=0.65)

    def X(d):  # in from the inner edge
        return inner * (0.5 - d)

    thumb = [(X(-0.02), 2.262), (X(0.36), 2.252), (X(0.48), 2.232), (X(0.53), 2.2), (X(0.48), 2.166),
             (X(0.36), 2.152), (X(-0.02), 2.15)]
    f.poly([(x, y - 0.02) for x, y in thumb], LINE, alpha=0.3)  # its shadow on the fingers
    f.poly(thumb, shade(SKIN, 0.06))
    f.gradient((0, 2.15), (0, 2.262), shade(SKIN, -0.12), shade(SKIN, 0.2), clip=thumb)
    f.stroke(thumb, 0.013, shade(SKIN, -0.62), alpha=0.9)
    f.ellipse(X(0.44), 2.205, 0.05, 0.03, "#a87a5c")  # the nail
    f.stroke([(X(0.41), 2.22), (X(0.46), 2.225)], 0.008, "#d9b294", alpha=0.8)
    i = a.inner  # the thumb's base and the curled index finger
    base = [(-0.5, 2.262), (-0.22, 2.29), (-0.1, 2.21), (-0.2, 2.14), (-0.5, 2.15)]
    i.poly(base, shade(SKIN, 0.05))
    i.stroke(base, 0.014, shade(SKIN, -0.6), alpha=0.8)
    i.stroke([(-0.5, 2.1), (-0.3, 2.06), (-0.12, 2.08)], 0.012, shade(SKIN, -0.55), alpha=0.6)
    for x in (-0.15, 0.15):  # tendons on the back of the hand
        a.back.stroke([(x, 2.36), (x * 1.2, 2.1)], 0.016, shade(SKIN, 0.15), alpha=0.45)
    a.outer.stroke([(-0.5, 2.12), (-0.3, 2.07), (-0.1, 2.1)], 0.012, shade(SKIN, -0.55), alpha=0.55)  # the pinky


def arm(a, side):
    """Bare muscled arms with glowing tribal marks, wrapped wrists, fists. The
    scythe arm (his right) carries a thorny vine down its outer side."""
    for f in a.sides:
        f.gradient((0, 2.0), (0, 4.0), shade(SKIN, -0.18), shade(SKIN, 0.1))
        vgrad(f, 3.7, 4.0, shade(SKIN, 0.1), shade(SKIN, 0.2), alpha=0.7)
    f = a.front  # biceps, the elbow crease, forearm
    f.ellipse(0.0, 3.28, 0.3, 0.2, shade(SKIN, 0.18), alpha=0.35)
    f.stroke([(-0.32, 3.06), (0.0, 2.99), (0.32, 3.06)], 0.035, shade(SKIN, -0.45), alpha=0.45)
    f.stroke([(-0.2, 2.88), (0.2, 2.88)], 0.018, shade(SKIN, -0.5), alpha=0.5)
    o = a.outer
    o.stroke([(-0.42, 3.42), (0.0, 3.34), (0.42, 3.42)], 0.04, shade(SKIN, -0.45), alpha=0.4)  # deltoid
    o.stroke([(-0.38, 3.47), (0.0, 3.39), (0.38, 3.47)], 0.014, shade(SKIN, 0.3), alpha=0.4)
    a.inner.gradient((0, 2.6), (0, 4.0), shade(SKIN, -0.28), shade(SKIN, -0.08), alpha=0.6)
    fangs(a, 3.74, seed=60 + side)
    if side > 0:  # the scythe arm: a thorny vine down to the wrist, dots down the biceps
        thorns(o, 3.6, 2.7, seed=7)
        for y in (3.36, 3.24, 3.12):
            mark(a.front, [(0.0, y), (0.0, y + 0.002)], 0.045)
    else:  # three short claw stripes down the outside
        for k in range(3):
            z = -0.22 + k * 0.17
            mark(o, [(z - 0.04, 3.34), (z + 0.05, 3.06)], 0.03, taper=(1.0, 0.25))
    wraps(a, 2.4, 2.66, WRAP, spacing=0.075, seed=40 + side)
    fist(a, side)
    a.top.fill(shade(SKIN, 0.15))
    a.bottom.fill(shade(SKIN, -0.35))


def head(p):
    p.head.fill(SKIN)
    band = p.head.band
    band.gradient((0, 4.0), (0, 4.35), shade(SKIN, -0.3), SKIN, clip=[(-2, 4.0), (2, 4.0), (2, 4.35), (-2, 4.35)])
    # hair color under the mane, down to a hairline that drops toward the back,
    # with the mane's shadow just under it
    line = [(s, 4.99 - 0.6 * math.sin(min(abs(s) / 1.5, 1) * math.pi / 2) ** 2) for s in np.linspace(-1.95, 1.95, 60)]
    band.stroke([(s, y - 0.03) for s, y in line], 0.08, UNDER, alpha=0.45, blend="multiply")
    band.poly(line + [(1.95, 5.3), (-1.95, 5.3)], MANE)
    p.head.top.fill(MANE)
    # the mask's contact shadow (on the head, so the face decal stays clean)
    band.stroke(MASK_OUTLINE + MASK_OUTLINE[:1], 0.045, shade(SKIN, -0.5), alpha=0.35)
    face(band)
    p.head.bottom.fill(shade(SKIN, -0.3))


def paint(av, p):
    head(p)
    top(p.torso)
    strap(p.torso)
    belt(p.torso)
    for side, s in (("Right", 1), ("Left", -1)):
        arm(p.arm(side), s)
        shorts(p.leg(side), s)
        leg_wraps(p.leg(side), s)
    charm(p.leg("Left"))
