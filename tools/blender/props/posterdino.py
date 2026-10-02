"""
props/posterdino.py - the PosterDino prop (ReplicatedStorage.MapMeshes.PosterDino): a landscape dinosaur
poster taped to the bedroom wall. See props/__init__.py for the conventions every prop follows.

Art: a friendly round green long-neck dinosaur (big eyes, rosy cheeks, a smile, orange back plates,
a pale belly) walking across a sandy plain - wearing a striped sock on the tip of its tail - between a
big and a small purple volcano, each oozing lava and puffing smoke, with a palm tree at each side
under a pale blue sky and a sun. The bouncy two-tone title "DINO-MITE!" runs across the top. The
print sits on cream paper with an ink line round it; a strip of tape across each corner holds it up
(the tape bends down over the paper's edge onto the wall).

Built with the poster kit in props/posterrocket.py (paper sheet with an inked edge, flat stacked
paint, chunky letters). Wall-mounted: the paper's back is on the wall at y = 0, the front faces -Y;
origin = bottom centre of the back plane. 13 x 9 units (Map fit box 130 x 90 x 4 studs).
"""
import math
import bmesh
import bpy
import sockkit as K
from sockkit import hexcol
from props.posterrocket import (Art, paper, glyph_polys, camera_only, circle, ellipse, xform, offset,
                                smooth_loop, INK, T, DY)
from props import posterrocket as R

NAME = "PosterDino"
EXPORT_DIR = "map"

PAPER, PAPER_B = R.PAPER, R.PAPER_B  # the same poster paper
SKY = hexcol("posterdino_sky", "#7CCDEB")
SKY_L = hexcol("posterdino_sky_low", "#B4E4EF")
SUN = hexcol("posterdino_sun", "#FFE27A")
SUN_L = hexcol("posterdino_sun_glow", "#FFF2B8")
VOLC = hexcol("posterdino_volcano", "#91597C")
VOLC_D = hexcol("posterdino_volcano_shade", "#6C3E61")
LAVA, LAVA_L = R.FLAME_O, R.TITLE
PUFF = hexcol("posterdino_smoke", "#D9D2E6")
PUFF_D = R.SMOKE_D
SAND = hexcol("posterdino_sand", "#EBC870")
SAND_D = hexcol("posterdino_sand_dark", "#CFA453")
PEBBLE = hexcol("posterdino_pebble", "#B98A49")
TRUNK = hexcol("posterdino_trunk", "#A86A3A")
TRUNK_D = hexcol("posterdino_trunk_dark", "#7D4A28")
COCO = TRUNK_D
LEAF = hexcol("posterdino_leaf", "#2FA05C")
LEAF_D = hexcol("posterdino_leaf_dark", "#1F7744")
DINO = hexcol("posterdino_dino", "#5DBB4A")
DINO_D = hexcol("posterdino_dino_shade", "#3F9440")
DINO_B = hexcol("posterdino_belly", "#C9E58A")
PLATE = hexcol("posterdino_plate", "#F59A3C")
EYE = K.WHITE
PUPIL = hexcol("posterdino_pupil", "#231733")
CHEEK = hexcol("posterdino_cheek", "#F48BA0")
NAIL = PAPER
SOCK, SOCK_W, SOCK_D = R.RED, R.STAR_W, R.PIN_BLUE[0]          # red sock, cream stripes, blue patches
TITLE_A, TITLE_B, TITLE_SH = R.FLAME_M, R.TITLE, R.RED_D       # orange / yellow letters, dark red shadow
TAPE = hexcol("posterdino_tape", "#EFE4B0")
TAPE_L = PAPER

W, H = 13.0, 9.0
MARGIN = 0.36
FRAME = 0.06
OUTLINE = 0.0825     # hull width (~1% of the poster's width; its inflated front stays between paint layers)
INK_W = 0.07
WALL_Y = OUTLINE - 0.006  # where the game's wall is (the hull's back goes flat on it)
X0, X1 = -W / 2 + MARGIN, W / 2 - MARGIN
Z0, Z1 = MARGIN, H - MARGIN


def _front(x, z):
    if x < X0 or x > X1 or z < Z0 or z > Z1:
        return PAPER
    if x < X0 + FRAME or x > X1 - FRAME or z < Z0 + FRAME or z > Z1 - FRAME:
        return INK
    return SKY


def _wavy_band(art, top, bottom, pal, n=30):
    xs = [X0 + (X1 - X0) * k / n for k in range(n + 1)]
    art.add([[(x, bottom(x)) for x in xs] + [(x, top(x)) for x in reversed(xs)]], pal)


def _sky(art):
    _wavy_band(art, lambda x: 4.3 + 0.18 * math.sin(x * 0.8 + 1.0), lambda x: Z0, SKY_L)
    art.group([(circle(5.0, 7.55, 0.95, 28), SUN_L, None)])
    art.group([(circle(5.0, 7.55, 0.7, 26), SUN)], ink=0.06)


def _volcano(art, cx, base, peak_h, half_w, crater_w, lean=0.0):
    """A wide cone with a flat crater top: lit left half and shaded right half side by side, a lava
    cap with drips, and a few smoke puffs."""
    top = base + peak_h

    def edge(side, t):  # t: 0 at the crater rim .. 1 at the base; concave flanks
        x0 = cx + lean + side * crater_w / 2
        x1 = cx + side * half_w
        k = t ** 0.6
        return (x0 + (x1 - x0) * k, top - peak_h * t)
    ts = [k / 10 for k in range(11)]
    right = [edge(1, t) for t in ts]
    left = [edge(-1, t) for t in ts]
    shape = [left[0], right[0]] + right[1:] + list(reversed(left[1:]))
    # split down the middle from the crater's centre to the base
    mid_top = (cx + lean, top)
    mid_bot = (cx + half_w * 0.15, base)
    lit = [mid_top] + [mid_bot] + list(reversed(left[1:])) + [left[0]]
    dark = [mid_top, right[0]] + right[1:] + [mid_bot]
    art.add([offset(shape, INK_W)], INK)
    art.add([lit], VOLC)
    art.add([dark], VOLC_D)
    # lava: a cap over the crater rim with three drips running down the flanks
    cap = []
    drips = ((-0.62, 0.32), (-0.1, 0.48), (0.5, 0.26))
    n = 30
    for k in range(n + 1):
        u = -1 + 2 * k / n
        x = cx + lean + u * (crater_w / 2 + 0.12)
        d = 0.18 + sum(dl * max(0.0, 1 - ((u - du) / 0.16) ** 2) for du, dl in drips)
        cap.append((x + (0.06 * u * d), top - d))
    cap = cap + [(cx + lean + crater_w / 2 + 0.05, top + 0.06), (cx + lean - crater_w / 2 - 0.05, top + 0.06)]
    art.group([(cap, LAVA)], ink=0.05)
    art.add([ellipse(cx + lean, top + 0.02, crater_w * 0.42, 0.09, n=14)], LAVA_L)
    return top


def _puffs(art, x, z, scale, drift):
    shapes = []
    for i, (dx, dz, r) in enumerate(((0.0, 0.35, 0.3), (0.25, 0.75, 0.36), (0.02, 1.2, 0.42), (0.38, 1.6, 0.34))):
        shapes.append((circle(x + (dx + drift * dz) * scale, z + dz * scale, r * scale, 18), PUFF))
    art.group(shapes, ink=0.05)
    for dx, dz, r in ((0.08, 1.12, 0.22), (0.4, 1.55, 0.16)):
        art.add([circle(x + (dx + drift * dz) * scale + 0.08 * scale, z + dz * scale - 0.1 * scale, r * scale, 14)], PUFF_D)


def _ground(art):
    hz = lambda x: 2.35 + 0.22 * math.sin(x * 0.55 + 0.4) + 0.1 * math.sin(x * 1.7)
    xs = [X0 - 0.1 + (X1 - X0 + 0.2) * k / 40 for k in range(41)]
    sand = [(xs[0], Z0 - 0.2), (xs[-1], Z0 - 0.2)] + [(x, hz(x)) for x in reversed(xs)]
    art.group([(sand, SAND)])
    front = lambda x: 1.0 + 0.15 * math.sin(x * 0.9 + 2.0)
    _wavy_band(art, front, lambda x: Z0, SAND_D)
    for x, z, rx in ((-4.9, 1.6, 0.15), (3.9, 1.55, 0.15), (4.75, 1.95, 0.11), (2.6, 1.85, 0.1),
                     (0.4, 0.62, 0.17), (-2.5, 0.7, 0.14), (3.2, 0.6, 0.16), (-4.2, 0.75, 0.12)):
        art.add([ellipse(x, z, rx, rx * 0.6, n=10)], PEBBLE)


def _palm(art, base, top, bend, flip=1.0):
    """A curved, segmented trunk (alternating tones side by side) and a crown of drooping fronds."""
    bx, bz = base
    tx, tz = top
    pts = []
    n = 7
    for k in range(n + 1):
        t = k / n
        x = bx + (tx - bx) * t + bend * math.sin(math.pi * t)
        z = bz + (tz - bz) * t
        pts.append((x, z))

    def wid(t):
        return 0.3 - 0.11 * t
    left, right = [], []
    for k, (x, z) in enumerate(pts):
        a = pts[min(k + 1, n)]
        b = pts[max(k - 1, 0)]
        dx, dz = a[0] - b[0], a[1] - b[1]
        ln = math.hypot(dx, dz)
        nx, nz = -dz / ln, dx / ln
        w = wid(k / n)
        left.append((x + nx * w, z + nz * w))
        right.append((x - nx * w, z - nz * w))
    trunk = right + list(reversed(left))
    art.add([offset(trunk, INK_W)], INK)
    for k in range(n):
        seg = [right[k], right[k + 1], left[k + 1], left[k]]
        art.add([seg], TRUNK if k % 2 == 0 else TRUNK_D)
    # fronds: long leaves drooping out of the crown, each with a darker vein
    fronds, veins = [], []
    for ang, length, droop in ((0.25, 1.9, 0.55), (0.95, 1.6, 0.35), (1.65, 1.2, 0.1), (2.3, 1.7, -0.4),
                               (2.95, 1.9, -0.6), (-0.4, 1.4, 0.7)):
        a = ang if flip > 0 else math.pi - ang
        segs = 6
        sp = []
        for k in range(1, segs + 1):
            t = k / segs
            d = length * t
            sag = droop * t * t
            x = tx + math.cos(a) * d
            z = tz + math.sin(a) * d - abs(sag) - 0.35 * t * t * length * 0.4
            sp.append((x, z))
        spine = [(tx, tz)] + sp
        up, dn = [], []
        for k, (x, z) in enumerate(spine):
            a2 = spine[min(k + 1, segs)]
            b2 = spine[max(k - 1, 0)]
            dx, dz = a2[0] - b2[0], a2[1] - b2[1]
            ln = math.hypot(dx, dz) or 1
            nx, nz = -dz / ln, dx / ln
            w = 0.26 * math.sin(math.pi * min(k / segs, 0.999) ** 0.8)
            up.append((x + nx * w, z + nz * w))
            dn.append((x - nx * w, z - nz * w))
        fronds.append((dn + list(reversed(up[1:])), LEAF))
        veins.append(_tube(spine[1:-1], [0.035] * (len(spine) - 2))[0])
    art.group(fronds, ink=0.06)  # one inked crown
    for v in veins:
        art.add([v], LEAF_D)
    art.group([(circle(tx + dx, tz + dz, 0.17, 12), COCO) for dx, dz in ((-0.15, -0.12), (0.14, -0.15), (0.0, -0.3))],
              ink=0.05)


def _tube(spine, widths):
    """Outline polygon of a tapering band along a polyline spine."""
    left, right = [], []
    n = len(spine)
    for k, (x, z) in enumerate(spine):
        a = spine[min(k + 1, n - 1)]
        b = spine[max(k - 1, 0)]
        dx, dz = a[0] - b[0], a[1] - b[1]
        ln = math.hypot(dx, dz) or 1
        nx, nz = -dz / ln, dx / ln
        w = widths[k]
        left.append((x + nx * w, z + nz * w))
        right.append((x - nx * w, z - nz * w))
    return right + list(reversed(left)), left, right


def _curve(ctrl, n=24):
    """An open Catmull-Rom curve through the control points (ends clamped)."""
    pts = [ctrl[0]] + list(ctrl) + [ctrl[-1]]
    out = []
    for i in range(1, len(pts) - 2):
        p0, p1, p2, p3 = pts[i - 1], pts[i], pts[i + 1], pts[i + 2]
        steps = max(2, n // (len(ctrl) - 1))
        for k in range(steps):
            t = k / steps
            t2, t3 = t * t, t * t * t
            out.append(tuple(0.5 * ((2 * p1[j]) + (-p0[j] + p2[j]) * t + (2 * p0[j] - 5 * p1[j] + 4 * p2[j] - p3[j]) * t2
                                    + (-p0[j] + 3 * p1[j] - 3 * p2[j] + p3[j]) * t3) for j in range(2)))
    out.append(ctrl[-1])
    return out


def _sock(art, at, ang):
    """A red striped sock (white cuff and stripes, blue heel and toe) whose leg is pulled over the tail
    tip: local x runs from the opening along the leg, the foot droops down (-z). The sock is mirrored
    when it points left, so the foot always hangs down."""
    leg_l, hw = 1.0, 0.36
    outline = smooth_loop([(0.0, hw), (leg_l * 0.55, hw), (leg_l, hw * 0.95), (leg_l + 0.32, hw * 0.55),
                           (leg_l + 0.4, -0.15), (leg_l + 0.3, -0.75), (leg_l + 0.05, -1.05), (leg_l - 0.35, -0.98),
                           (leg_l - 0.42, -0.62), (leg_l - 0.45, -hw), (leg_l * 0.4, -hw), (0.0, -hw)], 4)
    left = math.cos(ang) < 0
    X = lambda pts: xform(pts, at[0], at[1], ang - math.pi if left else ang, mirror=left)
    art.add([X(offset(outline, INK_W))], INK)
    art.add([X(outline)], SOCK)
    # cuff and stripes: bands across the leg
    for x0, x1 in ((-0.02, 0.24), (0.42, 0.56), (0.72, 0.86)):
        art.add([X([(x0, -hw + 0.01), (x1, -hw + 0.01), (x1, hw - 0.01), (x0, hw - 0.01)])], SOCK_W)
    # heel (the outer corner) and toe (the bottom), as patches
    heel = smooth_loop([(leg_l + 0.05, hw * 0.75), (leg_l + 0.3, hw * 0.45), (leg_l + 0.35, -0.12), (leg_l + 0.08, -0.05)], 4)
    toe = smooth_loop([(leg_l + 0.31, -0.72), (leg_l + 0.04, -1.01), (leg_l - 0.33, -0.95), (leg_l - 0.4, -0.72),
                       (leg_l - 0.05, -0.62)], 4)
    art.add([X(heel)], SOCK_D)
    art.add([X(toe)], SOCK_D)


def _dino(art, ox):
    """The dinosaur, walking right; ox shifts it sideways."""
    P = lambda pts: [(x + ox, z) for x, z in pts]
    leg = lambda x, z, w, h: P(smooth_loop([(x - w, z + h), (x + w, z + h), (x + w + 0.03, z + 0.12),
                                             (x + w - 0.1, z - 0.1), (x - w + 0.1, z - 0.1), (x - w - 0.03, z + 0.12)], 4))
    legs_far = [(-0.55, 1.5), (1.75, 1.45)]
    legs_near = [(-1.05, 1.15), (1.25, 1.1)]
    art.group([(leg(x, z, 0.36, 1.25), DINO_D) for x, z in legs_far])
    neck = _curve(P([(1.15, 3.35), (1.75, 4.0), (2.05, 4.75), (2.3, 5.35)]), 16)
    neck_poly, _, _ = _tube(neck, [0.72 - 0.3 * k / (len(neck) - 1) for k in range(len(neck))])
    tail = _curve(P([(-1.5, 2.95), (-2.55, 2.6), (-3.45, 2.75), (-4.1, 3.2)]), 18)
    tail_w = [0.66 * (1 - k / (len(tail) - 1)) ** 0.8 + 0.12 for k in range(len(tail))]
    tail_poly, _, _ = _tube(tail, tail_w)
    body = P(ellipse(0.0, 3.0, 2.0, 1.28, rot=0.04, n=36))
    hx, hz = 2.55 + ox, 5.72
    head = smooth_loop([(hx - 0.4, hz - 0.12), (hx - 0.22, hz + 0.3), (hx + 0.35, hz + 0.4), (hx + 0.95, hz + 0.18),
                        (hx + 1.17, hz - 0.18), (hx + 0.95, hz - 0.5), (hx + 0.35, hz - 0.58), (hx - 0.25, hz - 0.48)], 5)
    # back plates: rounded triangles along the back, the neck and the tail
    plates = []
    for (x, z, sz, a) in ((-1.45, 3.85, 0.32, 0.6), (-0.65, 4.2, 0.4, 0.25), (0.25, 4.3, 0.42, -0.05),
                          (1.1, 4.1, 0.36, -0.4), (1.65, 4.65, 0.28, -0.65), (1.95, 5.25, 0.22, -0.8),
                          (-2.4, 3.2, 0.26, 0.85), (-3.25, 3.15, 0.2, 0.75)):
        pl = smooth_loop([(-0.85, 0.0), (0.0, 1.3), (0.85, 0.0), (0.0, -0.4)], 4)
        plates.append((xform(pl, x + ox, z, a, sz), PLATE))
    art.group(plates, ink=0.06)
    # one inked silhouette: tail, body, neck, head
    art.group([(tail_poly, DINO), (body, DINO), (neck_poly, DINO), (head, DINO)])
    # pale belly along the underside of the body and neck, a few spots on the back
    belly = P(smooth_loop([(-1.3, 2.05), (0.0, 1.78), (1.25, 2.05), (1.95, 2.85), (2.25, 3.75), (2.55, 4.6),
                           (2.75, 5.15), (2.45, 5.05), (2.05, 4.3), (1.45, 3.4), (0.6, 2.65), (-0.6, 2.4),
                           (-1.45, 2.45)], 4))
    art.add([belly], DINO_B)
    for x, z, r in ((-0.9, 3.65, 0.24), (-0.05, 3.85, 0.18), (-1.75, 3.25, 0.15), (0.7, 3.6, 0.14), (-2.9, 2.95, 0.12)):
        art.add([P(ellipse(x, z, r, r * 0.8, 0.3, 12))], DINO_D)
    # near legs with toenails
    art.group([(leg(x, z, 0.4, 1.3), DINO) for x, z in legs_near])
    for x, z in legs_near:
        for dx in (-0.22, 0.02, 0.26):
            art.add([P(ellipse(x + dx, z - 0.01, 0.1, 0.085, n=10))], NAIL)
    # the sock on the tail tip
    tip = tail[-4]
    d = (tail[-1][0] - tail[-6][0], tail[-1][1] - tail[-6][1])
    _sock(art, tip, math.atan2(d[1], d[0]))
    # face: two big eyes, cheeks, smile, nostrils
    for ex, ez, r in ((hx + 0.18, hz + 0.02, 0.28), (hx + 0.8, hz + 0.0, 0.3)):
        art.group([(ellipse(ex, ez, r * 0.9, r, n=20), EYE)], ink=0.05)
        art.add([ellipse(ex + 0.06, ez - 0.04, r * 0.5, r * 0.58, n=16)], PUPIL)
        art.add([circle(ex + 0.12, ez + 0.08, r * 0.17, 10)], EYE)
    for cx, cz in ((hx - 0.05, hz - 0.35), (hx + 1.0, hz - 0.33)):
        art.add([ellipse(cx, cz, 0.15, 0.09, n=12)], CHEEK)
    smile = [(hx + 0.5 + 0.36 * math.cos(a), hz - 0.2 + 0.24 * math.sin(a)) for a in [math.pi * (1.18 + 0.64 * k / 10) for k in range(11)]]
    smile_poly, _, _ = _tube(smile, [0.032] * len(smile))
    art.add([smile_poly], INK)
    for nx in (hx + 1.02, hx + 1.12):
        art.add([ellipse(nx, hz - 0.02, 0.03, 0.045, n=8)], INK)


def _title(art):
    def bounce(mid, total):
        i = int(mid * 3.1)
        return (mid - total / 2) * size - 0.45, 7.15 + 0.13 * math.sin(i * 2.1), 0.09 * math.sin(i * 1.7 + 0.6), 1.0
    size = 1.48
    glyphs = glyph_polys("DINO-MITE!", size, 0.055, 0.08, bounce, spacing=0.13)
    art.text(glyphs, (TITLE_A, TITLE_B), shadow=(0.08, -0.11), shadow_pal=TITLE_SH, ink=True)


def paint():
    art = Art(clip=(X0 + FRAME, Z0 + FRAME, X1 - FRAME, Z1 - FRAME))
    _sky(art)
    _volcano(art, -3.2, 2.2, 3.4, 2.8, 0.8, lean=0.1)
    _puffs(art, -3.1, 5.6, 0.85, 0.15)
    _volcano(art, 4.25, 2.2, 2.3, 2.0, 0.6, lean=-0.05)
    _ground(art)
    _palm(art, (-5.75, 0.9), (-5.25, 5.55), 0.35, 1.0)
    _palm(art, (5.65, 0.95), (5.3, 5.05), -0.35, -1.0)
    _dino(art, -0.55)
    _title(art)
    return art


def _tape(cx, cz, ang, y_paper, length=1.7, width=0.52, name="tape"):
    """A strip of tape across a corner: flat on the paint, bending down past the paper's edge onto
    the wall; torn zigzag ends, a lighter band along one side, a painted ink line round it."""
    nu, teeth = 12, 4
    bm = bmesh.new()
    pals = []
    ca, sa = math.cos(ang), math.sin(ang)

    def height(x, z, y_top, y_wall):
        out = max(abs(x) - W / 2, abs(z - H / 2) - H / 2, 0.0)
        t = min(out / 0.14, 1.0)
        t = t * t * (3 - 2 * t)
        return y_top + (y_wall - y_top) * t

    def grid(grow, y_top, y_wall, pal_fn):
        rows = []
        for j in range(teeth * 2 + 1):
            wv = -width / 2 - grow + (width + 2 * grow) * j / (teeth * 2)
            row = []
            for i in range(nu + 1):
                uu = -length / 2 - grow + (length + 2 * grow) * i / nu
                if i in (0, nu):  # torn ends
                    uu += (1 if i == 0 else -1) * (0.07 if j % 2 else 0.0)
                x, z = cx + uu * ca - wv * sa, cz + uu * sa + wv * ca
                row.append(bm.verts.new((x, height(x, z, y_top, y_wall), z)))
            rows.append(row)
        for j in range(len(rows) - 1):
            for i in range(nu):
                bm.faces.new((rows[j][i], rows[j][i + 1], rows[j + 1][i + 1], rows[j + 1][i]))
                pals.append(pal_fn(j))
    grid(0.035, y_paper + DY * 0.5, WALL_Y, lambda j: INK)
    grid(0.0, y_paper - DY * 0.5, WALL_Y - DY, lambda j: TAPE_L if j >= teeth * 2 - 2 else TAPE)
    bm.normal_update()
    for f in bm.faces:
        if f.normal.y > 0:
            f.normal_flip()
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    return K.Piece(me, pals, outline=False, smooth=False, name=name)


def build():
    xs = [-W / 2, X0, X0 + FRAME, X1 - FRAME, X1, W / 2]
    zs = [0.0, Z0, Z0 + FRAME, Z1 - FRAME, Z1, H]
    p = [paper(W, H, xs, zs, _front, PAPER_B, PAPER)]
    art = paint()
    p.append(art.piece(-T))
    # a strip of tape over each corner along its diagonal (a bit more on the paper than the wall),
    # on top of whatever paint is under it
    for sx, sz, tilt in ((-1, 1, 0.12), (1, 1, -0.08), (-1, -1, -0.1), (1, -1, 0.06)):
        ang = math.atan2(sz, sx) + tilt
        cx = sx * W / 2 - 0.3 * math.cos(ang)
        cz = (H if sz > 0 else 0.0) - 0.3 * math.sin(ang)
        y = -T - DY * (art.slot_at(circle(cx, cz, 0.8, 12)) + 1.5)
        p.append(_tape(cx, cz, ang, y, length=1.35, width=0.48))
    body, outline = K.finish(p, NAME, outline_width=OUTLINE)
    camera_only(outline)
    print(f"{NAME}: {art.max_slot()} paint layers (art front at y = {-T - DY * art.max_slot():.3f})")
    return [body, outline] + K.markers(NAME)
