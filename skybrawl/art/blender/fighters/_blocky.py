"""
Blocky R6 bodies: the building blocks every legend is made of. Legends
author in R6 studs (UNIT = R6_SCALE scales them to the SkyRig, see
sky/skeleton.py); all coordinates below are R6 studs, rig space (X = the
fighter's right, Y = up, Z = behind: the face looks toward -Z).

  body()     the classic R6 body as outfit color blocks: 1x2x1 legs, a 2x2x1
             torso, 1x2x1 arms and a rounded-cylinder head, cut at the
             elbows and knees, with round joint fillers so bends stay solid
  panel(), band(), strap()
             "printed" outfit details: flat plates a hair above the surface
  eye(), line(), shape()
             classic decal faces: thin shapes wrapped onto the head
  wrapped()  thicker wrapped shapes: fringes, beards, masks, goggle straps
  shell()    a cap around the head (hair, helmets, hoods)
"""

import math

from mathutils import Vector
from mathutils.geometry import delaunay_2d_cdt

from sky.skeleton import R6_PIVOT, R6_SCALE, SIDES

UNIT = R6_SCALE

BEVEL = 0.035  # plastic-soft edges on every block
SEG = 3
PROUD = 0.018  # how far printed details stand off a surface
JOINT_R = 0.49  # joint fillers: just inside the 1-stud-thick limbs
HAND_W = 0.88

HEAD_R = 0.6
HEAD_Y0 = 4.0
HEAD_H = 1.2
HEAD_CORNER = 0.24
HEAD_TOP = HEAD_Y0 + HEAD_H

# Main block of each body part: (x center, width, y0, y1). Limbs are 1 stud
# deep and centered on z = 0, the torso 1 deep.
LIMBS = {
    "UpperArm": (1.5, 1.0, 2.9, 4.0),
    "LowerArm": (1.5, 1.0, 2.45, 2.9),
    "Hand": (1.5, 0.88, 1.95, 2.45),
    "UpperLeg": (0.5, 1.0, 1.25, 2.0),
    "LowerLeg": (0.5, 1.0, 0.5, 1.25),
    "Foot": (0.5, 1.0, 0.0, 0.5),
}
TORSO = {"UpperTorso": (0.0, 2.0, 2.5, 4.0), "LowerTorso": (0.0, 2.0, 2.0, 2.5)}


def pivot(joint):
    return R6_PIVOT[joint]


def block(part):
    """(x center, width, y0, y1) of a part's main block."""
    if part in TORSO:
        return TORSO[part]
    for side, s in SIDES:
        if part.startswith(side):
            x, w, y0, y1 = LIMBS[part[len(side):]]
            return (s * x, w, y0, y1)
    raise KeyError(part)


def side_sign(part):
    return -1 if part.startswith("Left") else 1


# Body ---------------------------------------------------------------------------


def _roll(mb, center, color, radius=JOINT_R, length=0.98, segments=24):
    """Cylinder along X: a joint filler (or anything round in the side view)."""
    mb.cylinder(center, radius, length, color, rotation=(0, 0, 90), segments=segments)


def _upper_arm(mb, x, color):
    """Side profile of an R6 upper arm: square below, round over the shoulder
    (the arm swings about the shoulder without its corner poking up)."""
    outline = []
    for i in range(13):
        a = math.pi * i / 12
        outline.append((0.5 * math.cos(a), 3.5 + 0.5 * math.sin(a)))
    outline = [(-0.5, 2.9), (0.5, 2.9)] + outline[:]
    # local x is -z after the turn below
    mb.prism([(lx, ly) for lx, ly in outline], 1.0, color, center=(x, 0, 0), rotation=(0, 90, 0), bevel=0.03,
             smooth=False)


def head(fb, color, radius=HEAD_R, corner=HEAD_CORNER, segments=32):
    """The classic R6 head: a cylinder with well-rounded top and bottom."""
    sections = []
    steps = 6
    for i in range(steps + 1):  # bottom corner
        a = math.pi / 2 * i / steps
        sections.append((0, HEAD_Y0 + corner - corner * math.cos(a), 0, radius - corner + corner * math.sin(a)))
    for i in range(steps + 1):  # top corner
        a = math.pi / 2 * i / steps
        sections.append((0, HEAD_TOP - corner + corner * math.sin(a), 0, radius - corner + corner * math.cos(a)))
    fb["Head"].loft([(x, y, z, r, r) for x, y, z, r in sections], color, segments=segments)


def body(fb, skin, shirt, pants, shoes, sleeves=None, forearms=None, hands=None, belt=None, shins=None,
         head_color=None):
    """The R6 body in outfit colors. Defaults: sleeves = shirt, forearms =
    sleeves, hands = skin, belt (lower torso) = pants, shins = pants."""
    sleeves = sleeves or shirt
    forearms = forearms or sleeves
    hands = hands or skin
    belt = belt or pants
    shins = shins or pants
    head(fb, head_color or skin)
    fb["UpperTorso"].box((0, 3.25, 0), (2, 1.5, 1), shirt, bevel=BEVEL, segments=SEG)
    # hidden tail under the waist: fills the gap when the chest bends or twists
    fb["UpperTorso"].box((0, 2.4, 0), (1.96, 0.24, 0.96), shirt, bevel=0.01, segments=1)
    fb["LowerTorso"].box((0, 2.25, 0), (2, 0.5, 1), belt, bevel=BEVEL, segments=SEG)
    for side, s in SIDES:
        x = 1.5 * s
        _upper_arm(fb[f"{side}UpperArm"], x, sleeves)
        _roll(fb[f"{side}UpperArm"], (x, 2.9, 0), sleeves)
        fb[f"{side}LowerArm"].box((x, 2.675, 0), (1, 0.45, 1), forearms, bevel=BEVEL, segments=SEG)
        # the fist is a touch narrower than the arm: reads as a hand, and fits inside gauntlets
        fb[f"{side}Hand"].box((x, 2.2, 0), (HAND_W, 0.5, HAND_W), hands, bevel=0.08, segments=SEG)
        lx = 0.5 * s
        _roll(fb[f"{side}UpperLeg"], (lx, 2.0, 0), pants)
        fb[f"{side}UpperLeg"].box((lx, 1.625, 0), (1, 0.75, 1), pants, bevel=BEVEL, segments=SEG)
        _roll(fb[f"{side}UpperLeg"], (lx, 1.25, 0), pants)
        fb[f"{side}LowerLeg"].box((lx, 0.875, 0), (1, 0.75, 1), shins, bevel=BEVEL, segments=SEG)
        _roll(fb[f"{side}LowerLeg"], (lx, 0.5, 0), shins)
        fb[f"{side}Foot"].box((lx, 0.25, 0), (1, 0.5, 1), shoes, bevel=BEVEL, segments=SEG)


def roll(fb, part, center, color, radius=JOINT_R, length=0.98):
    _roll(fb[part], center, color, radius, length)


# Printed outfit details -----------------------------------------------------------


def panel(fb, part, x0, y0, x1, y1, color, face="front", layer=1, bevel=0.012, z=None):
    """A flat plate on a block's front (-Z) or back (+Z) face, x0..x1 by
    y0..y1. `layer` stacks plates on plates."""
    _, w, _, _ = block(part)
    depth_face = 0.5 if z is None else abs(z)
    proud = PROUD * layer
    zc = (depth_face + proud / 2 - 0.01) * (-1 if face == "front" else 1)
    fb[part].box(((x0 + x1) / 2, (y0 + y1) / 2, zc), (abs(x1 - x0), abs(y1 - y0), proud + 0.02), color,
                 bevel=bevel, segments=1)


def side_panel(fb, part, z0, y0, z1, y1, color, layer=1, bevel=0.012, outer=True):
    """A flat plate on a limb's outer (or inner) side face."""
    x, w, _, _ = block(part)
    s = side_sign(part) if outer else -side_sign(part)
    proud = PROUD * layer
    xc = x + s * (w / 2 + proud / 2 - 0.01)
    fb[part].box((xc, (y0 + y1) / 2, (z0 + z1) / 2), (proud + 0.02, abs(y1 - y0), abs(z1 - z0)), color,
                 bevel=bevel, segments=1)


def band(fb, part, y0, y1, color, grow=None, layer=1, bevel=0.015, depth=None):
    """A ring around a block (belts, cuffs, boot tops, trim)."""
    x, w, _, _ = block(part)
    g = PROUD * layer if grow is None else grow
    depth = depth or (1.0 if part in TORSO else w)
    fb[part].box((x, (y0 + y1) / 2, 0), (w + 2 * g, abs(y1 - y0), depth + 2 * g), color, bevel=bevel, segments=1)


def print_shape(fb, part, outline, color, face="front", layer=1, z=None, bevel=0.0):
    """Any flat shape [(x, y), ...] printed on a front (-Z) or back (+Z) face."""
    depth_face = 0.5 if z is None else abs(z)
    proud = PROUD * layer
    zc = (depth_face + proud / 2 - 0.01) * (-1 if face == "front" else 1)
    fb[part].prism(outline, proud + 0.02, color, center=(0, 0, zc), bevel=bevel)


def profile(fb, part, outline, x0, x1, color, bevel=0.02, smooth=False):
    """A shape seen from the side: `outline` [(z, y), ...] extruded across
    x0..x1 (spikes, crests, capes, hair tufts)."""
    fb[part].prism([(-z, y) for z, y in outline], abs(x1 - x0), color, center=((x0 + x1) / 2, 0, 0),
                   rotation=(0, 90, 0), bevel=bevel, smooth=smooth)


def front_profile(fb, part, outline, z0, z1, color, bevel=0.02, smooth=False):
    """A shape seen from the front: `outline` [(x, y), ...] extruded z0..z1."""
    fb[part].prism(outline, abs(z1 - z0), color, center=(0, 0, (z0 + z1) / 2), bevel=bevel, smooth=smooth)


def strap(fb, part, a, b, width, color, face="front", layer=1, z=None):
    """A straight strap across a front/back face from point a to b (x, y)."""
    (ax, ay), (bx, by) = a, b
    length = math.hypot(bx - ax, by - ay)
    angle = math.degrees(math.atan2(by - ay, bx - ax))
    depth_face = 0.5 if z is None else abs(z)
    proud = PROUD * layer
    zc = (depth_face + proud / 2 - 0.01) * (-1 if face == "front" else 1)
    fb[part].box(((ax + bx) / 2, (ay + by) / 2, zc), (length, width, proud + 0.02), color, bevel=0.01, segments=1,
                 rotation=(0, 0, angle))


# Wrapped shapes (faces, fringes, masks) -----------------------------------------------


def _wrap(u, v, h, radius):
    """Head-surface coordinates -> rig space: u is arc length around the head
    from the middle of the face (positive toward the fighter's right), v is
    height, h is distance off the surface."""
    a = u / radius
    return ((radius + h) * math.sin(a), v, -(radius + h) * math.cos(a))


def _inside(x, y, poly):
    hit = False
    for (ax, ay), (bx, by) in zip(poly, poly[1:] + poly[:1]):
        if (ay > y) != (by > y) and x < ax + (y - ay) * (bx - ax) / (by - ay):
            hit = not hit
    return hit


def _seg_dist(x, y, a, b):
    (ax, ay), (bx, by) = a, b
    dx, dy = bx - ax, by - ay
    t = max(0.0, min(1.0, ((x - ax) * dx + (y - ay) * dy) / ((dx * dx + dy * dy) or 1.0)))
    return math.hypot(x - ax - t * dx, y - ay - t * dy)


def _flat(outline, max_edge, max_inner=0.2):
    """Triangulates a 2D outline (any simple polygon) into well-shaped
    triangles about `max_inner` across (constrained Delaunay over a grid of
    inside points), its edges split to `max_edge` so the result can bend
    around the head. Returns (points, triangles, boundary edges)."""
    pts = []
    n = len(outline)
    for i in range(n):  # densify the outline
        (ax, ay), (bx, by) = outline[i], outline[(i + 1) % n]
        k = max(1, math.ceil(math.hypot(bx - ax, by - ay) / max_edge))
        for j in range(k):
            pts.append((ax + (bx - ax) * j / k, ay + (by - ay) * j / k))
    xs, ys = [p[0] for p in outline], [p[1] for p in outline]
    g = max_inner
    inner = []
    gy = min(ys) + g / 2
    while gy < max(ys):
        gx = min(xs) + g / 2
        while gx < max(xs):
            if _inside(gx, gy, outline) and min(_seg_dist(gx, gy, a, b) for a, b in
                                               zip(outline, outline[1:] + outline[:1])) > 0.45 * g:
                inner.append((gx, gy))
            gx += g
        gy += g
    m = len(pts)
    out = delaunay_2d_cdt([Vector(p) for p in pts + inner], [(i, (i + 1) % m) for i in range(m)],
                          [list(range(m))], 1, 1e-7)
    points = [(v.x, v.y) for v in out[0]]
    tris = [tuple(f) for f in out[2] if len(f) == 3]
    counts = {}
    for t in tris:
        for k in range(3):
            e = frozenset((t[k], t[(k + 1) % 3]))
            counts[e] = counts.get(e, 0) + 1
    boundary = [tuple(e) for e, c in counts.items() if c == 1]
    return points, tris, boundary


def wrapped(fb, outline, color, out=PROUD, inner=-0.03, radius=HEAD_R, part="Head", max_edge=0.08):
    """A shape drawn on the head's (or any vertical cylinder about the rig's
    Y axis) surface, from `inner` to `out` off it. `outline` is [(u, v)];
    `max_edge` is how finely it follows the curve."""
    points, tris, boundary = _flat(outline, max_edge, max(0.2, 2 * max_edge))
    n = len(points)
    verts = [_wrap(u, v, out, radius) for u, v in points] + [_wrap(u, v, inner, radius) for u, v in points]
    faces = list(tris) + [tuple(i + n for i in reversed(t)) for t in tris]
    faces += [(a, b, b + n, a + n) for a, b in boundary]
    fb[part].polys(verts, faces, color, smooth=True)


def ellipse(cu, cv, ru, rv, rotation=0.0, n=16):
    c, s = math.cos(math.radians(rotation)), math.sin(math.radians(rotation))
    out = []
    for i in range(n):
        a = 2 * math.pi * i / n
        x, y = ru * math.cos(a), rv * math.sin(a)
        out.append((cu + x * c - y * s, cv + x * s + y * c))
    return out


def shape(fb, outline, color, layer=1, **kw):
    """A flat decal on the face (eyes, brows, cheeks, marks)."""
    wrapped(fb, outline, color, out=0.008 * layer + 0.004, inner=-0.02, **kw)


def eye(fb, u, v, color, ru=0.055, rv=0.095, shine="eye_shine", rotation=0.0):
    """Classic Roblox eye: a dark upright oval with a little highlight."""
    shape(fb, ellipse(u, v, ru, rv, rotation), color)
    if shine:
        shape(fb, ellipse(u + 0.018, v + 0.035, ru * 0.36, rv * 0.24), shine, layer=2, max_edge=0.02)


def star(cx, cy, r_out, r_in, points=5, rotation=90.0):
    """Outline of a star (sun emblems, snowflakes, sparkles)."""
    out = []
    for i in range(points * 2):
        a = math.radians(rotation) + math.pi * i / points
        r = r_out if i % 2 == 0 else r_in
        out.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return out


def leaf(base, tip, width, n=6):
    """Outline of a pointed leaf from `base` to `tip` (2D)."""
    (bx, by), (tx, ty) = base, tip
    dx, dy = tx - bx, ty - by
    length = math.hypot(dx, dy) or 1.0
    nx, ny = -dy / length, dx / length
    left, right = [], []
    for i in range(1, n):
        t = i / n
        w = width / 2 * math.sin(math.pi * t) ** 0.8
        px, py = bx + dx * t, by + dy * t
        left.append((px + nx * w, py + ny * w))
        right.append((px - nx * w, py - ny * w))
    return [(bx, by)] + right + [(tx, ty)] + list(reversed(left))


def stroke(points, width):
    """Outline of a thick polyline (width may be a number or a list)."""
    widths = width if isinstance(width, (list, tuple)) else [width] * len(points)
    left, right = [], []
    for i, (x, y) in enumerate(points):
        a = points[max(0, i - 1)]
        b = points[min(len(points) - 1, i + 1)]
        dx, dy = b[0] - a[0], b[1] - a[1]
        length = math.hypot(dx, dy) or 1.0
        nx, ny = -dy / length, dx / length
        h = widths[i] / 2
        left.append((x + nx * h, y + ny * h))
        right.append((x - nx * h, y - ny * h))
    return left + list(reversed(right))


def curve(u0, v0, u1, v1, bend, n=10):
    """Points from (u0, v0) to (u1, v1) bowed by `bend` (positive = down in
    the middle, a smile)."""
    pts = []
    for i in range(n + 1):
        t = i / n
        pts.append((u0 + (u1 - u0) * t, v0 + (v1 - v0) * t - bend * 4 * t * (1 - t)))
    return pts


def line(fb, points, width, color, layer=1):
    """A drawn line on the face: mouths, brows, lashes, scars."""
    shape(fb, stroke(points, width), color, layer=layer, max_edge=0.03)


# Accessories -------------------------------------------------------------------------


def shell(fb, color, grow=0.06, bottom=4.95, back_bottom=None, part="Head", top_grow=None, corner=HEAD_CORNER,
          center=(0.0, 0.0), segments=32):
    """A solid cap around the top of the head (hair, helmet, hood top), from
    `bottom` at the front to `back_bottom` at the back."""
    r = HEAD_R + grow
    t = HEAD_TOP + (grow if top_grow is None else top_grow)
    c = corner + grow * 0.5
    y0 = min(bottom, back_bottom or bottom) - 0.05
    sections = [(0, y0, 0, r)]
    steps = 6
    for i in range(steps + 1):
        a = math.pi / 2 * i / steps
        sections.append((0, t - c + c * math.sin(a), 0, r - c + c * math.cos(a)))
    cx, cz = center
    clip = []
    if back_bottom is None or abs(back_bottom - bottom) < 1e-6:
        clip.append(((0, bottom, 0), (0, 1, 0)))
    else:
        # slanted cut: `bottom` at the front of the head, `back_bottom` behind
        clip.append(((0, bottom, -r), (0, 2 * r, -(back_bottom - bottom))))
    fb[part].loft([(cx, y, cz, rr, rr) for _, y, _, rr in sections], color, segments=segments, clip=clip,
                  fill=True)


def ring(fb, part, y0, y1, color, radius=HEAD_R + 0.03, segments=32):
    """A band around the head (headbands, circlets, hat bands)."""
    fb[part].loft([(0, y0, 0, radius, radius), (0, y1, 0, radius, radius)], color, segments=segments)


__all__ = [
    "UNIT", "BEVEL", "SEG", "PROUD", "HEAD_R", "HEAD_Y0", "HEAD_TOP", "SIDES", "pivot", "block", "side_sign",
    "head", "body", "roll", "panel", "side_panel", "band", "strap", "print_shape", "profile", "front_profile",
    "wrapped", "ellipse", "shape", "eye", "star", "leaf", "stroke",
    "curve", "line", "shell", "ring",
]
