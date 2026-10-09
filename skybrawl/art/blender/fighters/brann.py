"""Brann, cyborg brawler with huge mech arms. Hammer + Gauntlets. Slow, sturdy, devastating.

A classic blocky avatar: short spiky rust-red hair over a buzzed fade, a short
rust beard with a heavy horseshoe mustache and a big toothy grin, one fierce
steel-blue eye and one glowing orange cybernetic eye set in a steel plate that
runs back to a bolted temple plate. A charcoal tank top under a
hazard-striped harness (with oily finger smears), a heavy tool belt, olive
cargo pants with knee pads and steel-toe boots. His arms are chunky gunmetal
mech arms: wedge pauldrons that sweep back (low in front, so the side view
still shows his grin) with a hazard-striped chamfer, glowing vents and two
staggered exhaust stacks; a hub at each elbow; tapered, hazard-banded
forearms with pistons; and huge fists with a wrapped thumb, glowing knuckles
and lit finger pads.
"""

import math

import bmesh
import numpy as np
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree

from sky import avatar as A
from sky import skeleton
from sky.avatar import Glow, Hair, Style, anime_brow, lock, mix, shade, shell

NAME = "Brann"

SKIN = "#d9a07c"
HAIR = "#9a3018"
BEARD = "#8f3416"
BROW = "#7a2a12"
EYE = "#3f78b0"  # his own eye: steel blue
CYBER = "#ff8a1c"  # the cybernetic eye and every glow on the arms
TANK = "#2c2d33"
HAZARD = "#f2b418"
HAZARD_DARK = "#1c1c21"
LEATHER = "#3e2b1f"
PANTS = "#474a3a"
PAD = "#26272c"
BOOT = "#2a2421"
SOLE = "#4c443e"
LACE = "#b49a72"
GUNMETAL = "#5d6673"
GUNMETAL_DARK = "#373c45"
STEEL = "#9aa3ae"
LINE = "#1a1a20"
OIL = "#0e0e12"


# Accessory swatches -------------------------------------------------------------------------


class Armor(Style):
    """Gunmetal plate: lit from above, faint brushed streaks and scratches,
    and optional plate seams (heights 0..1) running all the way around."""

    metal = 0.7
    rough = 0.38

    def __init__(self, color, seams=(), **kw):
        super().__init__(color, **kw)
        self.seams = seams

    def paint(self, c):
        c.gradient((0.5, 0.0), (0.5, 1.0), shade(self.color, -0.3), shade(self.color, 0.16))
        rng = np.random.default_rng(len(self.color) * 5 + len(self.seams))
        for _ in range(24):  # brushed streaks
            u, v = rng.uniform(-0.1, 1.0), rng.uniform(0.04, 0.96)
            c.stroke([(u, v), (u + rng.uniform(0.15, 0.4), v + rng.uniform(-0.01, 0.01))], 0.01,
                     shade(self.color, 0.28), alpha=0.22)
        for _ in range(8):  # scratches
            u, v = rng.uniform(0, 1), rng.uniform(0.1, 0.9)
            c.stroke([(u, v), (u + rng.uniform(-0.08, 0.08), v + rng.uniform(-0.06, 0.06))], 0.008,
                     shade(self.color, 0.45), alpha=0.5)
        for v in self.seams:
            c.rect_(0, v - 0.014, 1, v + 0.014, shade(self.color, -0.5))
            c.rect_(0, v + 0.014, 1, v + 0.03, shade(self.color, 0.35), alpha=0.6)
        c.material(self.metal, self.rough)


class Hazard(Style):
    """Yellow and black warning stripes, wrapped around a band."""

    size = (256, 48)
    metal = 0.15
    rough = 0.45

    def __init__(self, color=HAZARD, stripes=16, slant=0.035, **kw):
        super().__init__(color, **kw)
        self.stripes, self.slant = stripes, slant

    def paint(self, c):
        c.fill(HAZARD_DARK)
        w = 1.0 / self.stripes
        for k in range(-1, self.stripes + 1):
            u = k * w
            c.poly([(u, 0), (u + w / 2, 0), (u + w / 2 + self.slant, 1), (u + self.slant, 1)], self.color)
        c.rect_(0, 0, 1, 0.12, "#000000", alpha=0.25)  # worn edges
        c.rect_(0, 0.88, 1, 1, "#ffffff", alpha=0.12)
        c.material(self.metal, self.rough)


# Painting helpers ----------------------------------------------------------------------------


def arc(cx, cy, rx, ry, a0, a1, n=16):
    return [(cx + rx * math.cos(math.radians(a)), cy + ry * math.sin(math.radians(a)))
            for a in np.linspace(a0, a1, n)]


def quad(a, b, w):
    """A strip `w` wide from point a to point b."""
    dx, dy = b[0] - a[0], b[1] - a[1]
    ln = math.hypot(dx, dy) or 1.0
    nx, ny = -dy / ln * w / 2, dx / ln * w / 2
    return [(a[0] + nx, a[1] + ny), (b[0] + nx, b[1] + ny), (b[0] - nx, b[1] - ny), (a[0] - nx, a[1] - ny)]


def hazard_fill(c, clip, period=0.15, angle=50.0):
    """Yellow and black warning stripes inside the polygon `clip`."""
    xs, ys = [p[0] for p in clip], [p[1] for p in clip]
    cx, cy = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2
    span = max(max(xs) - min(xs), max(ys) - min(ys)) + 0.4
    c.poly(clip, HAZARD_DARK)
    a = math.radians(angle)
    n, d = (math.cos(a), math.sin(a)), (-math.sin(a), math.cos(a))
    k = -span
    while k < span:
        pts = [(cx + n[0] * t + d[0] * s, cy + n[1] * t + d[1] * s)
               for t, s in ((k, -span), (k + period / 2, -span), (k + period / 2, span), (k, span))]
        c.poly(pts, HAZARD, clip=clip)
        k += period
    c.stroke(clip + [clip[0]], 0.022, LINE, alpha=0.55)


def stitches(c, pts, color, dash=0.045, gap=0.035, width=0.012, alpha=0.8):
    """A dashed seam along a polyline."""
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        ln = math.hypot(x1 - x0, y1 - y0)
        t = 0.0
        while t < ln:
            t1 = min(ln, t + dash)
            c.stroke([(x0 + (x1 - x0) * t / ln, y0 + (y1 - y0) * t / ln),
                      (x0 + (x1 - x0) * t1 / ln, y0 + (y1 - y0) * t1 / ln)], width, color, alpha=alpha)
            t = t1 + gap


def bolt(c, x, y, r=0.03, color=STEEL):
    c.ellipse(x, y, r * 1.25, r * 1.25, shade(color, -0.6), metal=0.8, rough=0.3)
    c.ellipse(x, y, r, r, color, metal=0.8, rough=0.3)
    c.ellipse(x - r * 0.3, y + r * 0.3, r * 0.4, r * 0.4, "#ffffff", alpha=0.6)


def gear(c, x, y, r, color, teeth=8, alpha=1.0):
    """A cog: a ring with square teeth and a hole."""
    w = r * 0.22
    for k in range(teeth):
        a = 2 * math.pi * k / teeth
        ca, sa = math.cos(a), math.sin(a)
        pts = [(x + ca * r * t - sa * w * e, y + sa * r * t + ca * w * e) for t, e in ((0.8, 1), (1.22, 1), (1.22, -1),
                                                                                    (0.8, -1))]
        c.poly(pts, color, alpha=alpha)
    c.ellipse(x, y, r, r, color, alpha=alpha)


def rrect(x0, y0, x1, y1, r, n=4):
    """A rounded rectangle outline."""
    pts = []
    for cx, cy, a0 in ((x1 - r, y0 + r, -90), (x1 - r, y1 - r, 0), (x0 + r, y1 - r, 90), (x0 + r, y0 + r, 180)):
        pts += arc(cx, cy, r, r, a0, a0 + 90, n)
    return pts


def mirror(pts):
    """The left-hand copy of a shape drawn on the right (face coordinates)."""
    return [(-x, y) for x, y in reversed(pts)]


# The face --------------------------------------------------------------------------------------


def brawler_eye(c, side, iris, glow=None, sclera="#fbfaf7"):
    """A hard, narrow anime eye (no lashes): the outer corner sweeps up, a
    heavy upper lid cuts the top of the iris, a short line under the outer
    half. side = +1 (the fighter's right) or -1. A glowing eye gets a round
    white-hot core in a bright ring instead of a pupil."""
    s = side
    cx, cy = s * A.EYE_X, A.EYE_Y
    top = [(cx - s * 0.135, cy - 0.012), (cx - s * 0.07, cy + 0.04), (cx + s * 0.02, cy + 0.066),
           (cx + s * 0.1, cy + 0.066), (cx + s * 0.152, cy + 0.04)]
    bottom = [(cx + s * 0.112, cy - 0.022), (cx + s * 0.02, cy - 0.052), (cx - s * 0.07, cy - 0.044)]
    white = top + bottom
    c.poly(white, sclera)
    ix, iy = cx + s * 0.012, cy + 0.004
    color = glow or iris
    c.ellipse(ix, iy, 0.064, 0.08, shade(color, -0.45), clip=white)
    c.ellipse(ix, iy - 0.012, 0.052, 0.062, color, clip=white)
    c.ellipse(ix, iy - 0.036, 0.036, 0.024, shade(color, 0.4), clip=white)
    if glow:
        c.stroke(arc(ix, iy, 0.042, 0.042, 0, 360, 24), 0.008, shade(color, 0.35), clip=white)
        c.ellipse(ix, iy, 0.026, 0.026, "#fffbe8", clip=white)
        c.ellipse(ix - s * 0.045, iy + 0.04, 0.01, 0.01, "#ffffff", alpha=0.9, clip=white)
    else:
        c.ellipse(ix, iy + 0.004, 0.026, 0.034, "#100c14", clip=white)
        c.ellipse(ix - s * 0.022, iy + 0.028, 0.017, 0.014, "#ffffff", clip=white)
    c.stroke([(x, y - 0.014) for x, y in top], 0.026, "#000000", alpha=0.18, clip=white)  # lid shadow
    c.stroke([(cx - s * 0.15, cy - 0.024)] + top[1:] + [(cx + s * 0.18, cy + 0.026)], 0.036, LINE, taper=(0.35, 1.0))
    c.stroke([(cx + s * 0.15, cy + 0.024), bottom[0], bottom[1]], 0.014, LINE, alpha=0.85, taper=(1.0, 0.25))
    return white


def toothy_grin(c, y=4.29):
    """A wide clenched-teeth grin, the right corner hitched up."""
    mouth = [(-0.185, y + 0.03), (-0.06, y + 0.04), (0.08, y + 0.044), (0.205, y + 0.056), (0.17, y + 0.006),
             (0.09, y - 0.03), (0.0, y - 0.042), (-0.1, y - 0.032), (-0.16, y + 0.0)]
    c.poly(mouth, "#fffdf8")
    c.stroke([(-0.17, y + 0.004), (-0.05, y + 0.0), (0.06, y + 0.004), (0.18, y + 0.02)], 0.012, "#6a2a2c", clip=mouth)
    for x in (-0.11, -0.04, 0.035, 0.11):  # the gaps between teeth
        c.stroke([(x, y - 0.04), (x + 0.004, y + 0.05)], 0.007, "#9a8a88", alpha=0.7, clip=mouth)
    c.stroke(mouth + [mouth[0]], 0.017, "#3a1c1c")


def beard(c):
    """A short rust beard along the jaw, thick at the chin, the lip shaved
    under the grin."""
    edge = [(0.66, 4.84), (0.57, 4.82), (0.555, 4.64), (0.52, 4.56), (0.535, 4.5), (0.47, 4.42), (0.42, 4.33),
            (0.33, 4.25), (0.22, 4.205), (0.1, 4.215), (0.0, 4.2)]
    shape = edge + mirror(edge) + [(-0.72, 3.97), (0.72, 3.97)]
    c.poly(shape, BEARD)
    c.gradient((0, 3.98), (0, 4.4), shade(BEARD, -0.25), shade(BEARD, 0.08), clip=shape)
    for k in range(11):  # strands
        x = -0.55 + k * 0.11
        c.stroke([(x, 3.99), (x * 1.04, 4.12 + 0.1 * abs(x))], 0.02, shade(BEARD, -0.4), alpha=0.55, taper=(1.0, 0.2),
                 clip=shape)
    for sx in (-1, 1):
        c.stroke([(sx * 0.53, 4.66), (sx * 0.47, 4.46), (sx * 0.34, 4.3)], 0.02, shade(BEARD, 0.3), alpha=0.55,
                 clip=shape)
    c.stroke([(-0.12, 4.18), (0.0, 4.165), (0.12, 4.18)], 0.02, shade(BEARD, 0.3), alpha=0.5, clip=shape)


def mustache(c):
    """A heavy chevron over the grin (a notch in the middle), its ends
    drooping past the mouth corners into the chin beard: a horseshoe. A
    thin line of skin stays between it and the teeth."""
    right = [(0.0, 4.425), (0.06, 4.448), (0.16, 4.44), (0.25, 4.408), (0.3, 4.34), (0.31, 4.27), (0.285, 4.228),
             (0.248, 4.27), (0.24, 4.34), (0.222, 4.378), (0.16, 4.374), (0.08, 4.364), (0.0, 4.357)]
    must = right + [(-x, y) for x, y in reversed(right[1:-1])]
    color = shade(BEARD, -0.1)
    c.poly(must, color)
    c.gradient((0, 4.25), (0, 4.45), shade(color, -0.2), shade(color, 0.1), clip=must)
    for sx in (-1, 1):  # strands combed out from the middle
        for pts in (((0.03, 4.428), (0.13, 4.418)), ((0.15, 4.42), (0.23, 4.39)), ((0.255, 4.37), (0.272, 4.29))):
            c.stroke([(sx * x, y) for x, y in pts], 0.011, shade(BEARD, 0.3), alpha=0.5, taper=(1.0, 0.3), clip=must)


def face(c, glow=None):
    beard(c)
    # the cyber plate: steel set into his left cheekbone and brow, running back
    # to the temple plate (its top stays under the brow)
    plate = [(-0.11, 4.665), (-0.3, 4.705), (-0.56, 4.705), (-0.86, 4.69), (-0.86, 4.48), (-0.56, 4.455),
             (-0.38, 4.44), (-0.13, 4.49)]
    c.poly(plate, GUNMETAL, metal=0.7, rough=0.35)
    c.gradient((0, 4.44), (0, 4.705), shade(GUNMETAL, -0.3), shade(GUNMETAL, 0.28), clip=plate)
    c.stroke([(-0.13, 4.67), (-0.3, 4.697), (-0.56, 4.697), (-0.86, 4.682)], 0.012, shade(GUNMETAL, 0.55), alpha=0.8)
    c.stroke(plate + [plate[0]], 0.016, LINE, alpha=0.85)
    for x, y in ((-0.7, 4.64), (-0.7, 4.53), (-0.15, 4.6)):
        bolt(c, x, y, 0.017)
    c.stroke([(-0.44, 4.585), (-0.58, 4.585), (-0.62, 4.6), (-0.86, 4.6)], 0.012, CYBER)
    # eyes: his own (blue) and the cybernetic one (dark lens, orange glow, a
    # targeting ring); with `glow`, both burn that color
    brawler_eye(c, 1, EYE, glow=glow)
    brawler_eye(c, -1, EYE, glow=glow or CYBER, sclera="#25222b")
    ix = -A.EYE_X - 0.012
    for a in (25, 115, 205, 295):  # a segmented targeting ring
        c.stroke(arc(ix, A.EYE_Y + 0.004, 0.122, 0.122, a, a + 40, 8), 0.011, CYBER, alpha=0.9)
    # thick angry brows pressed down on the lids, a scar, a nose, the mustache
    # and the grin
    for side in (1, -1):
        anime_brow(c, side, BROW, y=4.765, angle=0.09, width=0.068, length=0.25, arch=0.004)
    c.stroke([(0.37, 4.52), (0.44, 4.41)], 0.02, shade(SKIN, -0.2), alpha=0.6)
    c.stroke([(0.37, 4.52), (0.44, 4.41)], 0.011, mix(SKIN, "#ffffff", 0.4))
    c.stroke([(0.022, 4.53), (0.0, 4.48), (-0.03, 4.474)], 0.015, shade(SKIN, -0.38), alpha=0.65)
    mustache(c)
    toothy_grin(c)


# Accessories -------------------------------------------------------------------------------------

ALONG_X = (0, 0, 90)  # cylinders across the arm (hubs, bolts on the outside)
ALONG_Z = (90, 0, 0)  # cylinders pointing forward (bolts on the front)
ELBOW = skeleton.R6_PIVOT["RightElbow"]  # (1.5, 2.9, 0)

# The pauldron's side profile (z, y): low in front so his face shows in the
# side view, rising and sweeping back, with a skirt that hangs lower behind
# the arm (the forearm folds forward, never back). Its bottom in front sits
# above everything the forearm brings up while the elbow bends to ~100
# degrees (see posed_check).
PAULDRON = [(-0.56, 3.62), (0.22, 3.62), (0.73, 3.4), (0.73, 4.36), (0.19, 4.3), (-0.56, 4.02)]
PAULDRON_X = (1.01, 2.42)  # never inside x = 1 (the torso), so a swinging arm never clips it
CHAMFER = ((2.42, 3.86), (2.04, 4.32))  # the outer top edge is cut along this line (front view)


def model(av):
    av.style("hair", Hair(HAIR, shine=0.5, strands=20, shine_color=shade(HAIR, 0.24)))
    av.style("plate", Armor(GUNMETAL, seams=(0.2,)))
    av.style("armor", Armor(GUNMETAL))
    av.style("joint", Armor(GUNMETAL_DARK, rough=0.45))
    av.style("finger", Armor(shade(GUNMETAL, -0.16)))
    av.style("steel", Armor(STEEL, rough=0.3))
    av.style("glow", Glow(CYBER))
    av.style("hazard", Hazard())
    av.style("hazard_strip", Hazard(projection="side", stripes=9, slant=0.2))
    hair(av)
    temple_plate(av)
    right = mech_arm(av, "Right", 1)
    mech_arm(av, "Left", -1)
    posed_check(av, *right)  # the left arm mirrors it


def hair(av):
    """Short spiky crop over the top; the undercut on the sides is painted.
    Slim tufts rise from the cap and sweep up and back (not out, so the
    front view stays a crest instead of a bush)."""
    mb = av.builder()
    mb.sphere((0, 5.08, 0.03), (0.645, 0.29, 0.67), "hair", segments=28, rings=14)
    # (x, z) on the cap, the tip's offset (sideways, up, back), radius
    tufts = [
        (-0.34, -0.4, (-0.1, 0.36, 0.3), 0.14), (-0.12, -0.46, (-0.04, 0.5, 0.32), 0.15),
        (0.12, -0.46, (0.05, 0.48, 0.34), 0.15), (0.35, -0.4, (0.1, 0.34, 0.32), 0.14),
        (-0.24, -0.08, (-0.08, 0.48, 0.5), 0.15), (0.02, -0.12, (0.0, 0.56, 0.5), 0.15),
        (0.26, -0.08, (0.08, 0.46, 0.52), 0.15),
        (-0.4, 0.24, (-0.1, 0.3, 0.48), 0.14), (-0.12, 0.28, (-0.04, 0.4, 0.58), 0.15),
        (0.15, 0.28, (0.05, 0.38, 0.58), 0.15), (0.42, 0.24, (0.1, 0.28, 0.48), 0.14),
        (-0.24, 0.55, (-0.08, 0.2, 0.5), 0.14), (0.03, 0.6, (0.0, 0.22, 0.54), 0.14),
        (0.28, 0.55, (0.08, 0.18, 0.5), 0.14),
    ]
    for x, z, (dx, dy, dz), radius in tufts:
        q = 1 - (x / 0.645) ** 2 - ((z - 0.03) / 0.67) ** 2
        base = Vector((x, 5.08 + 0.29 * math.sqrt(max(q, 0.0)) - 0.07, z))
        mid = base + Vector((dx * 0.4, dy * 0.7, dz * 0.25))
        tip = base + Vector((dx, dy, dz))
        lock(mb, [tuple(base), tuple(mid), tuple(tip)], radius, "hair", segments=8)
    # short tufts along the front hairline, flat to the head, so the cap ends
    # in spikes over the brow (the painted fade covers the edge elsewhere)
    for ang in (-75, -52, -30, -10, 10, 30, 52, 75):
        p, n = av.head_point(ang, 4.99, out=0.0)
        up = Vector((0, 1, 0))
        lock(mb, [tuple(p), tuple(p + n * 0.07 + up * 0.13), tuple(p + n * 0.06 + up * 0.27 - n * 0.02)], 0.12,
             "hair", segments=7)
    av.piece(A.melt(mb, voxel=0.022, smooth=3, tris=3400, carve_head=True), bone="Neck", name="Hair")


def temple_plate(av):
    """A bolted steel plate on his left temple, set into the head, with a
    status light."""
    mb = av.builder()
    shell(mb, "armor", -112, -70, 4.47, 4.86, r_in=A.HEAD_R - 0.02, r_out=A.HEAD_R + 0.045, steps=10, rows=2)
    for ang, y in ((-78, 4.79), (-78, 4.54), (-104, 4.79), (-104, 4.54)):
        p, n = av.head_point(ang, y, out=0.045)
        mb.sphere(tuple(p), 0.024, "steel", segments=8, rings=5)
    p, n = av.head_point(-91, 4.665, out=0.045)
    rot = Vector((0, 1, 0)).rotation_difference(n).to_matrix()
    mb.cylinder(tuple(p), 0.05, 0.04, "glow", rotation=rot, segments=10)
    av.piece(mb, bone="Neck", name="TemplePlate")


def slab(mb, profile, x0, x1, style, bevel=0.07, segments=2, clip=None):
    """A plate through the side profile [(z, y), ...], extruded across x
    from x0 to x1, its edges rounded; `clip` planes cut it like
    MeshBuilder's, and the cuts are capped (MeshBuilder.prism can't cap)."""
    tmp = bmesh.new()
    a = [tmp.verts.new((x0, y, z)) for z, y in profile]
    b = [tmp.verts.new((x1, y, z)) for z, y in profile]
    tmp.faces.new(a)
    tmp.faces.new(b[::-1])
    for i in range(len(profile)):
        j = (i + 1) % len(profile)
        tmp.faces.new((a[i], a[j], b[j], b[i]))
    bmesh.ops.recalc_face_normals(tmp, faces=tmp.faces)
    bmesh.ops.bevel(tmp, geom=list(tmp.edges), offset=bevel, segments=segments, affect="EDGES", profile=0.5,
                    clamp_overlap=True)
    caps = [f for f in tmp.faces if len(f.verts) > 4]
    bmesh.ops.triangulate(tmp, faces=caps, quad_method="BEAUTY", ngon_method="EAR_CLIP")
    mb._finish(tmp, style, (0, 0, 0), None, True, clip, fill=True)


def pauldron_shape(mb, s, style="plate"):
    """The pauldron plate itself (also built alone for the posed check)."""
    (cx0, cy0), (cx1, cy1) = CHAMFER
    keep = Vector((-(cy1 - cy0), cx1 - cx0, 0)).normalized()  # points inward-down, onto the kept side
    x0, x1 = PAULDRON_X
    slab(mb, PAULDRON, min(s * x0, s * x1), max(s * x0, s * x1), style,
         clip=[((s * cx0, cy0, 0), (s * keep.x, keep.y, 0))])


def stack(mb, exit_point, d, length):
    """An exhaust stack leaving the pauldron's top at `exit_point` along `d`:
    a collar at the surface, the pipe, a steel lip and a hot core."""
    p = Vector(exit_point)
    rot = Vector((0, 1, 0)).rotation_difference(d).to_matrix()
    mb.cylinder(tuple(p + d * 0.02), 0.14, 0.1, "joint", rotation=rot, segments=14)
    mb.cylinder(tuple(p + d * (length - 0.12) / 2), 0.1, length + 0.12, "armor", rotation=rot, segments=14)
    mb.cylinder(tuple(p + d * length), 0.124, 0.07, "steel", rotation=rot, segments=14)
    mb.cylinder(tuple(p + d * (length + 0.036)), 0.08, 0.02, "glow", rotation=rot, segments=14)


def mech_arm(av, side, s):
    """One mech arm, in three rigid parts on the arm's bones. Every part
    stays outside x = 1 (the arm's inner face) so nothing reaches the torso.
    Returns (pauldron plate alone, forearm builders) for the posed check."""
    encases = [f"{side}Arm"]

    # shoulder: the swept wedge pauldron, a hazard strip along its outer
    # chamfer, a vent on the outside, a glowing slit in front with bolts, and
    # two exhaust stacks (one low in front, one tall behind, so both read in
    # the side view) leaning back
    mb = av.builder()
    pauldron_shape(mb, s)
    (cx0, cy0), (cx1, cy1) = CHAMFER
    along = Vector((cx1 - cx0, cy1 - cy0, 0)).normalized()  # up the chamfer (right side)
    out = Vector((-along.y, along.x, 0))
    out = out if out.x > 0 else -out  # the chamfer's outward normal
    mid = Vector((cx0, cy0, 0)) + along * 0.11 + out * 0.01
    tilt = math.degrees(math.atan2(along.y, s * along.x))
    mb.box((s * mid.x, mid.y, 0.085), (0.18, 0.03, 1.12), "hazard_strip", bevel=0.008, segments=1,
           rotation=(0, 0, tilt))
    mb.box((s * 2.435, 3.73, 0.28), (0.05, 0.2, 0.7), "joint", bevel=0.02, segments=1)  # vent
    for y in (3.68, 3.78):
        mb.box((s * 2.46, y, 0.28), (0.03, 0.045, 0.6), "glow", bevel=0)
    mb.box((s * 1.71, 3.81, -0.575), (0.8, 0.12, 0.05), "joint", bevel=0.02, segments=1)  # front slit
    mb.box((s * 1.71, 3.81, -0.598), (0.7, 0.05, 0.03), "glow", bevel=0)
    for x in (1.18, 2.24):
        mb.cylinder((s * x, 3.81, -0.585), 0.045, 0.05, "steel", rotation=ALONG_Z, segments=8)
    d = Vector((s * 0.2, math.cos(math.radians(35)), math.sin(math.radians(35)))).normalized()
    stack(mb, (s * 1.45, 4.29, 0.17), d, 0.28)
    stack(mb, (s * 1.82, 4.32, 0.5), d, 0.44)
    av.piece(mb, bone=f"{side}Shoulder", name=f"{side}Pauldron", encases=encases)
    alone = av.builder()
    pauldron_shape(alone, s)

    # elbow: a round hub on the outside (round about the hinge, so it turns
    # cleanly); a forearm gauntlet tapering toward the elbow (so it folds
    # under the pauldron), a hazard band framing the wrist, a glowing slit on
    # the sloped front and pistons running up to the hub
    gauntlet = av.builder()
    mb = gauntlet
    mb.cylinder((s * 2.19, 2.9, 0.0), 0.3, 0.28, "joint", rotation=ALONG_X, segments=16)
    mb.cylinder((s * 2.35, 2.9, 0.0), 0.2, 0.05, "steel", rotation=ALONG_X, segments=16)
    mb.cylinder((s * 2.38, 2.9, 0.0), 0.09, 0.03, "glow", rotation=ALONG_X, segments=12)
    gy, gh, gd, taper = 2.68, 0.5, 1.26, 0.75  # center height, height, depth, top depth / bottom depth
    mb.box((s * 1.63, gy, 0.0), (1.18, gh, gd), "armor", bevel=0.08, segments=2, taper=(1.0, taper))
    mb.box((s * 1.63, 2.52, 0.0), (1.22, 0.16, 1.3), "hazard", bevel=0.012, segments=1)
    inset = gd / 2 * (1 - taper)  # how far the front leans back over the gauntlet's height
    slope = math.degrees(math.atan2(inset, gh))
    zf = -(gd / 2 - inset * (2.75 - (gy - gh / 2)) / gh)  # the front face at y 2.75
    mb.box((s * 1.63, 2.75, zf - 0.008), (0.78, 0.09, 0.04), "joint", bevel=0.012, segments=1, rotation=(slope, 0, 0))
    mb.box((s * 1.63, 2.75, zf - 0.028), (0.68, 0.04, 0.02), "glow", bevel=0, rotation=(slope, 0, 0))
    for z in (-0.38, 0.38):
        mb.cylinder((s * 2.26, 2.67, z), 0.07, 0.12, "joint", segments=10)  # piston sleeve
        mb.cylinder((s * 2.26, 2.74, z), 0.04, 0.26, "steel", segments=10)  # rod
    av.piece(mb, bone=f"{side}Elbow", name=f"{side}Gauntlet", encases=encases)

    # wrist: the big mechanical fist, palm in like the hand inside it. The
    # back of the hand on top, ribbed down to the knuckles; four fingers
    # curled under it, front to back, with dark gaps, knuckle caps (glowing
    # on the outside, so they lead when he punches) and lit pads underneath;
    # a thumb wrapped diagonally across the front of the index finger from a
    # knuckle at the palm
    fist = av.builder()
    mb = fist
    mb.box((s * 1.66, 2.15, 0.08), (1.3, 0.62, 1.4), "armor", bevel=0.12, segments=2)
    fingers = [-0.48 + i * 0.36 for i in range(4)]  # the index finger stands a little proud in front
    for z in fingers:
        mb.box((s * 1.65, 1.8, z), (1.18, 0.42, 0.32), "finger", bevel=0.1, segments=2)
        mb.box((s * 2.23, 1.68, z), (0.16, 0.2, 0.29), "joint", bevel=0.045, segments=1)  # knuckle cap
        mb.cylinder((s * 2.315, 1.68, z), 0.042, 0.03, "glow", rotation=ALONG_X, segments=10)
        mb.box((s * 1.6, 1.583, z), (0.6, 0.03, 0.2), "glow", bevel=0)  # pad underneath
    for z in fingers[:-1]:
        mb.box((s * 1.63, 1.82, z + 0.18), (1.1, 0.36, 0.06), "joint", bevel=0)  # the gap between two fingers
    mb.box((s * 1.38, 2.04, -0.69), (0.26, 0.24, 0.2), "joint", bevel=0.07, segments=2)  # thumb knuckle
    mb.box((s * 1.7, 1.9, -0.72), (0.62, 0.2, 0.2), "finger", bevel=0.08, segments=2, rotation=(0, 0, s * -28))
    for z in fingers:  # the back of the hand: a rib down to each knuckle, riveted at the wrist
        mb.box((s * 2.31, 2.11, z), (0.08, 0.42, 0.13), "joint", bevel=0.03, segments=1)
        mb.cylinder((s * 2.355, 2.27, z), 0.03, 0.03, "steel", rotation=ALONG_X, segments=8)
    av.piece(mb, bone=f"{side}Wrist", name=f"{side}Fist", encases=encases)
    return alone, [gauntlet, fist]


def posed_check(av, pauldron, forearm, angles=(60, 95, 98, 100, 118)):
    """The rest-pose clipping check can't see the elbow bend, so this bends
    copies of the forearm pieces (gauntlet and fist) forward about the elbow
    and tests them against the pauldron plate: they must clear it up to ~100
    degrees. Deeper folds (the shared fist guard bends 118, the fist block
    132-138) bury the fist in any shoulder armor, so Brann's guard and block
    should keep his elbows at 95 or less."""
    tree = BVHTree.FromBMesh(pauldron.bm)
    pivot = Vector(ELBOW)
    report = []
    for ang in angles:
        m = Matrix.Translation(pivot) @ Matrix.Rotation(math.radians(ang), 4, "X") @ Matrix.Translation(-pivot)
        hits, depth = 0, 0.0
        for mb in forearm:
            bm = mb.bm.copy()
            bm.transform(m)
            hits += len(BVHTree.FromBMesh(bm).overlap(tree))
            for v in bm.verts:  # how deep inside the (convex) plate a corner gets
                loc, normal, _, dist = tree.find_nearest(v.co)
                if loc is not None and (v.co - loc).dot(normal) < 0:
                    depth = max(depth, dist)
            bm.free()
        report.append(f"{ang}: " + ("clear" if not hits else f"{hits} hits, {depth:.2f} deep"))
    print(f"[{av.name}] elbow bend vs pauldron: " + ", ".join(report))
    pauldron.bm.free()


# The printed clothing --------------------------------------------------------------------------


def paint(av, p):
    p.head.fill(SKIN)
    for limb in p.limbs.values():
        limb.fill(TANK)
    paint_torso(p)
    paint_arms(p)
    paint_legs(p)
    paint_head(p)


def paint_torso(p):
    t = p.torso
    for f in t.sides:
        f.gradient((0, 2.0), (0, 4.0), shade(TANK, -0.12), shade(TANK, 0.07))
    f, b = t.front, t.back
    neck = [(-0.38, 4.0), (-0.32, 3.84), (-0.17, 3.73), (0, 3.7), (0.17, 3.73), (0.32, 3.84), (0.38, 4.0)]
    f.poly(neck, SKIN)
    f.stroke(neck, 0.05, shade(TANK, -0.35))
    bneck = [(-0.36, 4.0), (-0.2, 3.9), (0, 3.87), (0.2, 3.9), (0.36, 4.0)]
    b.poly(bneck, SKIN)
    b.stroke(bneck, 0.05, shade(TANK, -0.35))
    for fc in (f, b):
        for sx in (-1, 1):
            hole = [(sx * 0.66, 4.0), (sx * 0.7, 3.84), (sx * 0.8, 3.7), (sx * 1.0, 3.62), (sx * 1.0, 4.0)]
            fc.poly(hole, SKIN)
            fc.stroke(hole[:4], 0.05, shade(TANK, -0.35))
    # chest and belly shading on the tight tank top
    for sx in (-1, 1):
        f.stroke([(sx * 0.82, 3.42), (sx * 0.45, 3.3), (sx * 0.06, 3.38)], 0.05, shade(TANK, -0.4), alpha=0.7)
        f.stroke([(sx * 0.75, 3.55), (sx * 0.4, 3.48)], 0.03, shade(TANK, 0.2), alpha=0.45)
        for y in (3.0, 2.76):
            f.stroke([(sx * 0.08, y), (sx * 0.3, y + 0.02)], 0.03, shade(TANK, -0.35), alpha=0.6)
    f.stroke([(0, 2.62), (0, 3.24)], 0.025, shade(TANK, -0.35), alpha=0.5)
    # oil: an irregular stain low on his right, and three short greasy finger
    # smears on his left where he wiped his hands
    f.ellipse(0.74, 2.6, 0.11, 0.07, OIL, alpha=0.35, rotation=-12, rough=0.18)
    f.ellipse(0.82, 2.66, 0.065, 0.05, OIL, alpha=0.35, rotation=20, rough=0.18)
    f.ellipse(0.69, 2.54, 0.04, 0.03, OIL, alpha=0.3, rough=0.18)
    f.ellipse(-0.77, 2.83, 0.16, 0.11, OIL, alpha=0.2, rotation=-25, rough=0.2)
    for k, (dx, ln) in enumerate(((0.1, 0.17), (0.05, 0.24), (0.0, 0.15))):  # fanned, uneven, soft-edged
        x, y = -0.9 + k * 0.075, 2.95 - k * 0.015
        pts = [(x, y), (x + dx * 0.35, y - ln * 0.5), (x + dx, y - ln)]
        f.stroke(pts, 0.075, OIL, alpha=0.18, taper=(1.0, 0.3), rough=0.2)
        f.stroke(pts, 0.05, OIL, alpha=0.3, taper=(1.0, 0.1), rough=0.2)
    # hazard-striped harness: straight down the front, crossed on the back
    for sx in (-1, 1):
        hazard_fill(f, quad((sx * 0.5, 4.02), (sx * 0.44, 2.36), 0.2))
    for sx in (-1, 1):
        hazard_fill(b, quad((sx * 0.5, 4.02), (-sx * 0.44, 2.36), 0.2), angle=-50)
    chest = [(-0.46, 3.16), (0.46, 3.16), (0.46, 3.3), (-0.46, 3.3)]
    f.poly(chest, LEATHER)
    stitches(f, [(-0.44, 3.185), (0.44, 3.185)], shade(LEATHER, 0.4))
    stitches(f, [(-0.44, 3.275), (0.44, 3.275)], shade(LEATHER, 0.4))
    f.poly(rrect(-0.13, 3.1, 0.13, 3.36, 0.04), shade(STEEL, -0.15), metal=0.8, rough=0.3)
    gear(f, 0.0, 3.23, 0.06, shade(GUNMETAL, -0.2))
    f.ellipse(0, 3.23, 0.025, 0.025, shade(STEEL, 0.3))
    b.ellipse(0, 3.2, 0.13, 0.13, STEEL, metal=0.8, rough=0.3)
    b.ellipse(0, 3.2, 0.08, 0.08, shade(STEEL, -0.45))
    gear(b, 0.0, 2.62, 0.11, shade(CYBER, -0.15), alpha=0.6)  # a stenciled cog
    b.ellipse(0, 2.62, 0.05, 0.05, shade(TANK, -0.05))
    # metal sockets on the shoulders, where the mech arms are bolted on
    for fc in (f, b):
        for sx in (-1, 1):
            plate = [(sx * 0.74, 4.0), (sx * 0.77, 3.86), (sx * 0.87, 3.75), (sx * 1.0, 3.71), (sx * 1.0, 4.0)]
            fc.poly(plate, GUNMETAL, metal=0.7, rough=0.35)
            fc.stroke(plate[:4], 0.022, LINE, alpha=0.8)
            fc.stroke([(sx * 0.8, 3.9), (sx * 0.9, 3.82), (sx * 1.0, 3.8)], 0.012, CYBER)
            bolt(fc, sx * 0.86, 3.93, 0.022)
    # sides: seams, the harness hangs off the sockets
    for side in (t.right, t.left):
        side.stroke([(0, 2.0), (0, 3.6)], 0.02, shade(TANK, -0.4), alpha=0.6)
        side.rect_(-0.5, 3.71, 0.5, 4.0, GUNMETAL, metal=0.7, rough=0.35)
        side.stroke([(-0.5, 3.71), (0.5, 3.71)], 0.022, LINE, alpha=0.8)
    # top: tank straps and harness over the shoulders, skin, the sockets
    top = t.top
    top.fill(SKIN)
    for sx in (-1, 1):
        top.rect_(sx * 0.36, -0.5, sx * 0.68, 0.5, TANK)
        hazard_fill(top, quad((sx * 0.5, -0.52), (sx * 0.5, 0.52), 0.2), angle=0)
        top.rect_(sx * 0.74, -0.5, sx * 1.0, 0.5, GUNMETAL, metal=0.7, rough=0.35)
    # tool belt with a heavy buckle and pouches, pants below it
    t.band(2.0, 2.16, PANTS)
    t.band(2.16, 2.38, LEATHER)
    t.band(2.16, 2.19, shade(LEATHER, -0.35))
    t.band(2.35, 2.38, shade(LEATHER, 0.2))
    for fc in t.sides:
        a0, _, a1, _ = fc.bounds()
        stitches(fc, [(a0, 2.21), (a1, 2.21)], shade(LEATHER, 0.45), alpha=0.6)
        stitches(fc, [(a0, 2.33), (a1, 2.33)], shade(LEATHER, 0.45), alpha=0.6)
    f.poly(rrect(-0.15, 2.15, 0.15, 2.39, 0.03), STEEL, metal=0.85, rough=0.28)
    f.poly(rrect(-0.09, 2.2, 0.09, 2.34, 0.02), shade(LEATHER, -0.2))
    f.rect_(-0.015, 2.2, 0.015, 2.34, shade(STEEL, 0.2), metal=0.85, rough=0.28)
    for fc, xs in ((f, (-0.72, 0.72)), (b, (-0.55, 0.55))):
        for x in xs:
            fc.poly(rrect(x - 0.15, 2.06, x + 0.15, 2.34, 0.035), shade(LEATHER, 0.12))
            fc.poly(rrect(x - 0.16, 2.24, x + 0.16, 2.36, 0.03), shade(LEATHER, -0.1))
            fc.ellipse(x, 2.27, 0.022, 0.022, STEEL, metal=0.8, rough=0.3)
    f.stroke([(0, 2.0), (0, 2.15)], 0.02, shade(PANTS, -0.35))


def paint_arms(p):
    """The arms under the armor are mechanical too: dark ribbed conduit
    shows between the pauldron and the elbow, with two glowing rings."""
    for arm in p.arms():
        for fc in arm.sides:
            a0, _, a1, _ = fc.bounds()
            fc.gradient((0, 2.0), (0, 4.0), shade(GUNMETAL_DARK, -0.25), shade(GUNMETAL_DARK, 0.12))
            fc.material(0.6, 0.42)
            for y in np.arange(2.95, 3.66, 0.065):
                fc.rect_(a0, y, a1, y + 0.02, shade(GUNMETAL_DARK, -0.5))
                fc.rect_(a0, y + 0.02, a1, y + 0.03, shade(GUNMETAL_DARK, 0.35), alpha=0.6)
            for y in (3.1, 3.4):
                fc.rect_(a0, y, a1, y + 0.03, CYBER, rough=0.2)
        for fc in (arm.front, arm.back):  # cables down the conduit
            for x in (-0.25, 0.22):
                fc.stroke([(x, 2.9), (x + 0.04, 3.66)], 0.05, "#16161b")
        arm.top.fill(GUNMETAL_DARK)
        arm.bottom.fill(GUNMETAL_DARK)


def paint_legs(p):
    for leg in p.legs():
        for fc in leg.sides:
            fc.gradient((0, 0.6), (0, 2.0), shade(PANTS, -0.18), shade(PANTS, 0.06))
        o, fr = leg.outer, leg.front
        # seams and folds
        o.stroke([(0, 0.7), (0, 2.0)], 0.018, shade(PANTS, -0.35), alpha=0.6)
        leg.inner.stroke([(0, 0.7), (0, 2.0)], 0.018, shade(PANTS, -0.35), alpha=0.6)
        for fc in (leg.front, leg.back):
            fc.stroke([(-0.3, 1.72), (0.0, 1.66), (0.3, 1.7)], 0.03, shade(PANTS, -0.3), alpha=0.5)
            fc.stroke([(-0.25, 0.86), (0.2, 0.8)], 0.03, shade(PANTS, -0.3), alpha=0.5)
        leg.back.stroke([(-0.3, 1.25), (0.0, 1.2), (0.3, 1.26)], 0.035, shade(PANTS, -0.35), alpha=0.6)
        # cargo pocket on the outside of the thigh
        o.poly(rrect(-0.3, 1.1, 0.3, 1.6, 0.04), shade(PANTS, -0.04))
        stitches(o, [(-0.26, 1.14), (0.26, 1.14)], shade(PANTS, 0.3), alpha=0.6)
        if leg is p.leg("Left"):  # a wrench stuck in the pocket, under the flap
            o.stroke([(0.13, 1.56), (0.16, 1.8)], 0.065, STEEL, metal=0.8, rough=0.3)
            o.ellipse(0.163, 1.84, 0.08, 0.068, STEEL, metal=0.8, rough=0.3)
            o.poly([(0.13, 1.875), (0.2, 1.88), (0.18, 1.93), (0.14, 1.93)], shade(PANTS, 0.04))
            o.stroke([(0.14, 1.6), (0.16, 1.79)], 0.018, shade(STEEL, 0.4), alpha=0.7)
        o.poly(rrect(-0.32, 1.48, 0.32, 1.64, 0.04), shade(PANTS, 0.08))  # the pocket flap
        o.stroke([(-0.32, 1.48), (0.32, 1.48)], 0.018, shade(PANTS, -0.4), alpha=0.7)
        o.ellipse(0, 1.53, 0.03, 0.03, shade(PANTS, -0.45))
        # knee pad, strapped around the leg
        leg.band(1.08, 1.12, PAD)
        leg.band(1.34, 1.38, PAD)
        pad = [(-0.33, 1.02), (0.33, 1.02), (0.37, 1.3)] + arc(0, 1.3, 0.37, 0.17, 0, 180, 14) + [(-0.37, 1.3)]
        fr.poly(pad, PAD, rough=0.42)
        fr.gradient((0, 1.02), (0, 1.47), shade(PAD, -0.2), shade(PAD, 0.18), clip=pad)
        fr.stroke(arc(0, 1.3, 0.3, 0.12, 20, 160, 12), 0.03, shade(PAD, 0.55), alpha=0.6)  # shine on the dome
        for x in (-0.13, 0.13):
            fr.stroke([(x, 1.06), (x, 1.36)], 0.022, shade(PAD, -0.45), alpha=0.8)  # ridges
        fr.stroke(pad + [pad[0]], 0.02, LINE, alpha=0.6)
        fr.rect_(-0.33, 1.02, 0.33, 1.06, CYBER, rough=0.3)
        # bloused cuffs over heavy boots with laces, steel toe caps and thick
        # soles
        leg.band(0.0, 0.66, BOOT)
        for fc in leg.sides:
            fc.gradient((0, 0.1), (0, 0.66), shade(BOOT, -0.15), shade(BOOT, 0.12), clip=[
                (-0.6, 0.1), (0.6, 0.1), (0.6, 0.66), (-0.6, 0.66)])
        leg.band(0.6, 0.66, shade(BOOT, 0.2))
        leg.band(0.66, 0.76, shade(PANTS, -0.08))
        for fc in leg.sides:
            for x in (-0.3, 0.0, 0.3):
                fc.stroke([(x, 0.67), (x + 0.04, 0.76)], 0.02, shade(PANTS, -0.35), alpha=0.6)
        leg.band(0.0, 0.11, SOLE)
        for fc in leg.sides:
            for x in np.arange(-0.45, 0.5, 0.1):
                fc.rect_(x, 0.0, x + 0.04, 0.05, shade(SOLE, -0.4))
        toe = [(-0.44, 0.11), (0.44, 0.11), (0.44, 0.2)] + arc(0, 0.2, 0.44, 0.15, 0, 180, 18)[1:]
        fr.poly(toe, GUNMETAL, metal=0.8, rough=0.3)
        fr.gradient((0, 0.11), (0, 0.35), shade(GUNMETAL, -0.3), shade(GUNMETAL, 0.2), clip=toe)
        fr.stroke(arc(0, 0.2, 0.36, 0.1, 35, 145, 10), 0.018, shade(GUNMETAL, 0.6), alpha=0.7)  # shine
        fr.stroke(toe + [toe[0]], 0.018, LINE, alpha=0.7)
        tongue = rrect(-0.13, 0.33, 0.13, 0.64, 0.04)
        fr.poly(tongue, shade(BOOT, 0.15))
        rows = [0.38 + k * 0.075 for k in range(4)]
        for y0, y1 in zip(rows, rows[1:]):  # criss-cross laces between the eyelets
            fr.stroke([(-0.17, y0), (0.17, y1)], 0.024, LACE)
            fr.stroke([(0.17, y0), (-0.17, y1)], 0.024, shade(LACE, -0.15))
        for y in rows:
            for x in (-0.19, 0.19):
                fr.ellipse(x, y, 0.024, 0.024, shade(STEEL, -0.5), metal=0.8, rough=0.3)
                fr.ellipse(x, y, 0.014, 0.014, STEEL, metal=0.8, rough=0.3)
        leg.back.rect_(-0.42, 0.11, 0.42, 0.24, shade(BOOT, 0.1))
        leg.bottom.fill(shade(SOLE, -0.3))
    p.torso.bottom.fill(PANTS)


def paint_head(p):
    h = p.head
    h.top.fill(HAIR)
    # the buzzed fade on the sides and back, under the spiky top: denser
    # toward the top, fading out into skin at the line (lower at the nape),
    # flecked with stubble
    c = h.band
    buzz = shade(mix(HAIR, SKIN, 0.32), -0.06)
    regions = []
    for sx in (-1, 1):
        line = [(sx * 0.57, 4.86), (sx * 0.62, 4.68), (sx * 0.8, 4.7), (sx * 1.1, 4.6), (sx * 1.5, 4.4),
                (sx * 1.9, 4.32)]
        covered = 0.0
        for k, target in enumerate((0.15, 0.3, 0.45, 0.6, 0.75, 0.85)):  # how much buzz shows, step by step up
            region = [(sx * 0.52, 5.3), (sx * 0.52, 4.95)] + [(x, y + 0.03 * k) for x, y in line] + [(sx * 1.9, 5.3)]
            c.poly(region, buzz, alpha=1 - (1 - target) / (1 - covered))
            covered = target
            if not k:
                regions.append(region)
        c.poly([(sx * 0.52, 5.3), (sx * 0.52, 4.96), (sx * 1.9, 4.96), (sx * 1.9, 5.3)], HAIR)
    for x, w, tip, lean in ((-0.4, 0.09, 4.92, -0.03), (-0.17, 0.11, 4.9, -0.02), (0.06, 0.1, 4.915, 0.02),
                            (0.3, 0.11, 4.9, 0.03), (0.5, 0.08, 4.93, 0.03)):  # a few points under the 3D hair
        c.poly([(x - w, 5.0), (x + w, 5.0), (x + lean, tip)], HAIR)
    rng = np.random.default_rng(11)
    for _ in range(420):
        s, y = rng.uniform(-1.9, 1.9), rng.uniform(4.3, 4.97)
        region = regions[0] if s < 0 else regions[1]
        c.ellipse(s, y, 0.007, 0.007, shade(HAIR, -0.25), alpha=0.5, clip=region)
    face(c)
