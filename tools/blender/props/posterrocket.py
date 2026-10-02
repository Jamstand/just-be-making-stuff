"""
props/posterrocket.py - the PosterRocket prop (ReplicatedStorage.MapMeshes.PosterRocket): a portrait
space poster pinned to the bedroom wall. See props/__init__.py for the conventions every prop follows.

Art: a cartoon rocket (white body, red nose cone and fins, a round porthole) blasting off on a fat
three-tone flame out of a bank of smoke puffs into a banded purple night sky, past a ringed orange
planet, a cratered moon and a scatter of yellow stars; the chunky arched title "BLAST OFF!" in yellow
with a red drop shadow across the top. The print sits on cream paper with a narrow cream border and
an ink line round the print; four coloured push pins hold it up, and its top-right corner has peeled
forward and curled over (showing the paper's plain back), so that pin sits further along the top edge.

How it is built (the "poster kit" below is shared with props/posterdino.py):
- `paper()`: one closed sheet (front, back and rim, welded, so the inverted hull inks its edge) with
  per-face colours looked up from the flat layout; an optional page-curl corner rolls round a small
  cylinder and lies back over the poster (it only stands 2 x CURL_R off the paper - the wall fit box
  is only 4 studs deep).
- `Art`: the print is flat, front-only n-gons stacked a hair apart in front of the paper (no sides,
  no backs - nobody sees them). Every shape group draws its ink first (each shape grown by the ink
  width), then its fills, so a group of overlapping puffs reads as ONE inked silhouette. Each new
  shape goes one step in front of the frontmost shape it overlaps, so the stack stays shallow.
- `glyph_polys()`: Blender's built-in font, thickened with the curve offset (bold), laid out one
  letter at a time (arched titles, bouncy titles) and drawn through `Art` like any other shape.
  Blender fills a text outline even-odd, so a thickened S or M gets false holes where its outline
  crosses itself; `nonzero_fill()` refills the outline as a proper union instead.
- `push_pin()`: a chunky coloured push pin (also hangs the Pennant).

Paint layers sit DY apart (0.1 studs in game, enough against z-fighting at room distances). The
hull's inflated front plate (invisible in game: Roblox culls it) must not land exactly on a paint
layer, or the Cycles previews speckle there - hence OUTLINE is not a multiple of DY.

Wall-mounted: the paper's back is on the wall at y = 0, the front faces -Y; origin = bottom centre
of the back plane. 9 x 13 units (Map fit box 90 x 130 x 4 studs): the whole prop incl. the hull is
under 0.41 deep, so the 4-stud depth never limits the fit.
"""
import math
import bmesh
import bpy
from mathutils import Vector
import sockkit as K
from sockkit import M, hexcol

NAME = "PosterRocket"

# texture classes for tools/blender/texturing.py where the colour names alone guess wrong
MATERIALS = {"posterrocket_": "print", "posterrocket_paper": "paper", "posterrocket_pin": "plastic"}  # print on paper, push pins
EXPORT_DIR = "map"

# paper
PAPER = hexcol("posterrocket_paper", "#F7EEDA")        # cream border and the rim
PAPER_B = hexcol("posterrocket_paper_back", "#D9CDB4")  # the back of the sheet (seen on the curl)
# sky (three flat bands, darkest at the top)
SKY1 = hexcol("posterrocket_sky_top", "#2B2063")
SKY2 = hexcol("posterrocket_sky_mid", "#43308E")
SKY3 = hexcol("posterrocket_sky_low", "#6440A8")
STAR_W = hexcol("posterrocket_sparkle", "#FFF6DC")
# planet and moon
PLANET = hexcol("posterrocket_planet", "#F79A4A")
PLANET_D = hexcol("posterrocket_planet_shade", "#D8672E")
PLANET_B = hexcol("posterrocket_planet_band", "#E77B3A")
RING = hexcol("posterrocket_ring", "#FFE08C")
RING_D = hexcol("posterrocket_ring_dark", "#E2B455")
MOON = hexcol("posterrocket_moon", "#E9E4F7")
# rocket
HULL = hexcol("posterrocket_hull", "#F5F3FA")       # also the smoke
HULL_D = hexcol("posterrocket_hull_shade", "#C2BCE6")  # also the smoke's shade and the moon's
RED = hexcol("posterrocket_red", "#E8453C")
RED_D = hexcol("posterrocket_red_dark", "#B32D3A")
METAL = hexcol("posterrocket_metal", "#9CA2C8")
GLASS = hexcol("posterrocket_glass", "#5DC3F0")
NOZZLE = hexcol("posterrocket_nozzle", "#4E5175")
FLAME_O = hexcol("posterrocket_flame_out", "#F2502E")
FLAME_M = hexcol("posterrocket_flame_mid", "#FF9B2F")
FLAME_Y = hexcol("posterrocket_flame_core", "#FFE65C")
TITLE = hexcol("posterrocket_title", "#FFD83F")   # also the stars
# a few tones are shared to keep the palette small (one 32 x 32 swatch grid for the whole game)
SMOKE, SMOKE_D, MOON_D, GLASS_L, STAR, TITLE_SH = HULL, HULL_D, HULL_D, STAR_W, TITLE, RED
# push pins (cap, side, highlight)
PIN_RED = (RED, RED_D, STAR_W)
PIN_BLUE = (hexcol("posterrocket_pin_blue", "#3F86E8"), hexcol("posterrocket_pin_blue_d", "#2A58A8"), STAR_W)
PIN_YEL = (TITLE, hexcol("posterrocket_pin_yellow_d", "#D9902A"), STAR_W)
PIN_GRN = (hexcol("posterrocket_pin_green", "#4CC05E"), hexcol("posterrocket_pin_green_d", "#2E8A48"), STAR_W)
INK = K.OUTLINE

W, H = 9.0, 13.0      # paper size
T = 0.03              # paper thickness
MARGIN = 0.36         # cream border round the print
FRAME = 0.06          # ink line round the print
OUTLINE = 0.085       # hull width (~1% of the poster's height; not a multiple of DY, see above)
INK_W = 0.075         # painted ink in the artwork
DY = 0.01             # depth step between stacked paint layers (0.1 studs in game)
CURL_L = 1.3          # the peeled corner: leg of the triangle that lifted off
CURL_R = 0.075        # radius of the roll


# ============================================================== poster kit (shared with PosterDino)
def area2(pts):
    return sum(pts[i][0] * pts[(i + 1) % len(pts)][1] - pts[(i + 1) % len(pts)][0] * pts[i][1] for i in range(len(pts)))


def ccw(pts):
    """Counter-clockwise in (x, z) seen from the front (-Y) = the face looks at the viewer."""
    pts = clean(pts)
    return pts if area2(pts) > 0 else list(reversed(pts))


def clean(pts, eps=1e-5):
    out = []
    for p in pts:
        if not out or abs(p[0] - out[-1][0]) + abs(p[1] - out[-1][1]) > eps:
            out.append((p[0], p[1]))
    while len(out) > 2 and abs(out[0][0] - out[-1][0]) + abs(out[0][1] - out[-1][1]) <= eps:
        out.pop()
    return out


def circle(cx, cz, r, n=24, a0=0.0):
    return [(cx + r * math.cos(a0 + math.tau * k / n), cz + r * math.sin(a0 + math.tau * k / n)) for k in range(n)]


def ellipse(cx, cz, rx, rz, rot=0.0, n=28):
    c, s = math.cos(rot), math.sin(rot)
    out = []
    for k in range(n):
        a = math.tau * k / n
        x, z = rx * math.cos(a), rz * math.sin(a)
        out.append((cx + x * c - z * s, cz + x * s + z * c))
    return out


def star(cx, cz, ro, ri, k=5, rot=0.0):
    out = []
    for i in range(2 * k):
        r = ro if i % 2 == 0 else ri
        a = rot + math.pi / 2 + math.pi * i / k
        out.append((cx + r * math.cos(a), cz + r * math.sin(a)))
    return out


def xform(pts, ox=0.0, oz=0.0, ang=0.0, s=1.0, mirror=False):
    """Scale, (mirror in x), rotate counter-clockwise by `ang`, then move to (ox, oz)."""
    c, si = math.cos(ang), math.sin(ang)
    out = []
    for x, z in pts:
        x, z = (-x if mirror else x) * s, z * s
        out.append((ox + x * c - z * si, oz + x * si + z * c))
    return list(reversed(out)) if mirror else out


def offset(pts, w, limit=2.5):
    """Grows a counter-clockwise polygon by w (mitred corners, clamped at `limit` x w)."""
    pts = ccw(pts)
    n = len(pts)
    out = []
    for i in range(n):
        p0, p1, p2 = pts[i - 1], pts[i], pts[(i + 1) % n]
        e1 = (p1[0] - p0[0], p1[1] - p0[1])
        e2 = (p2[0] - p1[0], p2[1] - p1[1])
        l1 = math.hypot(*e1) or 1.0
        l2 = math.hypot(*e2) or 1.0
        n1 = (e1[1] / l1, -e1[0] / l1)
        n2 = (e2[1] / l2, -e2[0] / l2)
        b = (n1[0] + n2[0], n1[1] + n2[1])
        bl = math.hypot(*b)
        if bl < 1e-6:
            b, bl = n1, 1.0
        b = (b[0] / bl, b[1] / bl)
        cos_h = max(b[0] * n1[0] + b[1] * n1[1], 1.0 / limit)
        d = w / cos_h
        out.append((p1[0] + b[0] * d, p1[1] + b[1] * d))
    return out


def smooth_loop(ctrl, per=6):
    """A closed Catmull-Rom curve through the control points."""
    out = []
    n = len(ctrl)
    for i in range(n):
        p0, p1, p2, p3 = ctrl[i - 1], ctrl[i], ctrl[(i + 1) % n], ctrl[(i + 2) % n]
        for k in range(per):
            t = k / per
            t2, t3 = t * t, t * t * t
            out.append(tuple(0.5 * ((2 * p1[j]) + (-p0[j] + p2[j]) * t + (2 * p0[j] - 5 * p1[j] + 4 * p2[j] - p3[j]) * t2
                                    + (-p0[j] + 3 * p1[j] - 3 * p2[j] + p3[j]) * t3) for j in range(2)))
    return out


def ellipse_band(cx, cz, rxo, rzo, rxi, rzi, a0, a1, rot=0.0, n=20):
    outer = [(rxo * math.cos(a0 + (a1 - a0) * k / n), rzo * math.sin(a0 + (a1 - a0) * k / n)) for k in range(n + 1)]
    inner = [(rxi * math.cos(a1 - (a1 - a0) * k / n), rzi * math.sin(a1 - (a1 - a0) * k / n)) for k in range(n + 1)]
    return xform(outer + inner, cx, cz, rot)


def disc_band(cx, cz, r, z0, z1, rot=0.0, n=12):
    """The part of a disc between the (rotated) lines z = z0 and z = z1 of its own frame."""
    z0, z1 = max(z0, -r + 1e-4), min(z1, r - 1e-4)
    a0, a1 = math.asin(z0 / r), math.asin(z1 / r)
    right = [(r * math.cos(a0 + (a1 - a0) * k / n), r * math.sin(a0 + (a1 - a0) * k / n)) for k in range(n + 1)]
    left = [(-x, z) for x, z in reversed(right)]
    return xform(right + left, cx, cz, rot)


def _bbox(polys):
    xs = [p[0] for poly in polys for p in poly]
    zs = [p[1] for poly in polys for p in poly]
    return (min(xs), min(zs), max(xs), max(zs))


def _seg_hit(a, b, c, d):
    def orient(p, q, r):
        return (q[0] - p[0]) * (r[1] - p[1]) - (q[1] - p[1]) * (r[0] - p[0])
    o1, o2, o3, o4 = orient(a, b, c), orient(a, b, d), orient(c, d, a), orient(c, d, b)
    return (o1 > 0) != (o2 > 0) and (o3 > 0) != (o4 > 0)


def _inside(p, poly):
    x, z = p
    hit = False
    n = len(poly)
    for i in range(n):
        x1, z1 = poly[i]
        x2, z2 = poly[(i + 1) % n]
        if (z1 > z) != (z2 > z) and x < x1 + (z - z1) * (x2 - x1) / (z2 - z1):
            hit = not hit
    return hit


def _poly_overlap(a, b):
    if _inside(a[0], b) or _inside(b[0], a):
        return True
    for i in range(len(a)):
        for j in range(len(b)):
            if _seg_hit(a[i], a[(i + 1) % len(a)], b[j], b[(j + 1) % len(b)]):
                return True
    return False


class Art:
    """Flat painted artwork: front-only n-gons stacked in depth slots in front of the paper."""

    def __init__(self, clip=None):
        self.items = []  # [polys, pal, slot, bbox]
        self.clip = clip  # (x0, z0, x1, z1): everything is cut to this rectangle (the print)

    def _overlaps(self, it, polys, bb):
        b = it[3]
        if b[0] > bb[2] or bb[0] > b[2] or b[1] > bb[3] or bb[1] > b[3]:
            return False
        for pa in it[0]:
            ba = _bbox([pa])
            for pb in polys:
                bp = _bbox([pb])
                if ba[0] > bp[2] or bp[0] > ba[2] or ba[1] > bp[3] or bp[1] > ba[3]:
                    continue
                if _poly_overlap(pa, pb):
                    return True
        return False

    @staticmethod
    def _shrunk(p):
        """The shape pulled in a hair, so shapes that only touch (side-by-side shading) don't count
        as overlapping."""
        q = offset(p, -0.004, limit=1.5)
        return q if area2(q) > 0 else p

    def add(self, polys, pal, min_slot=1):
        """Paints polys over everything added before: one slot in front of every overlapping shape of
        another colour (a same-colour overlap may share its slot - coplanar twins look identical)."""
        polys = [ccw(p) for p in polys]
        if self.clip:
            polys = [ccw(_clip_rect(p, self.clip)) for p in polys]
        polys = [p for p in polys if len(p) >= 3 and abs(area2(p)) > 1e-7]
        if not polys:
            return
        bb = _bbox(polys)
        test = [self._shrunk(p) for p in polys]
        slot = min_slot
        for it in self.items:
            need = it[2] if it[1] == pal else it[2] + 1
            if need > slot and self._overlaps(it, test, bb):
                slot = need
        self.items.append([polys, pal, slot, bb])

    def slot_at(self, pts):
        """The frontmost slot under the shape pts (0 = bare paper)."""
        pts = ccw(pts)
        bb = _bbox([pts])
        return max([it[2] for it in self.items if self._overlaps(it, [pts], bb)] + [0])

    def group(self, shapes, ink=INK_W, ink_pal=INK):
        """shapes: [(pts, pal)] or [(pts, pal, ink_pts)] (ink_pts None = no ink): all inks, then all fills."""
        for s in shapes:
            ink_pts = s[2] if len(s) > 2 else offset(s[0], ink)
            if ink_pts is not None:
                self.add([ink_pts], ink_pal)
        for s in shapes:
            self.add([s[0]], s[1])

    def text(self, glyphs, pal, shadow=None, shadow_pal=None, ink=0.0):
        """glyphs: [(fill_polys, ink_polys)] from glyph_polys(); optional drop shadow (dx, dz). `pal`
        may be a tuple of colours, used letter by letter in turn."""
        if ink:
            for fill, inkp in glyphs:
                self.add(inkp, INK)
                if shadow:
                    self.add([xform(p, shadow[0], shadow[1]) for p in inkp], INK)
        if shadow:
            for fill, inkp in glyphs:
                self.add([xform(p, shadow[0], shadow[1]) for p in fill], shadow_pal)
        pals = pal if isinstance(pal, (tuple, list)) else (pal,)
        for i, (fill, inkp) in enumerate(glyphs):
            self.add(fill, pals[i % len(pals)])

    def max_slot(self):
        return max(it[2] for it in self.items)

    def piece(self, y_front, dy=DY, name="art"):
        bm = bmesh.new()
        pals = []
        for polys, pal, slot, bb in self.items:
            y = y_front - dy * slot
            for pts in polys:
                vs = [bm.verts.new((x, y, z)) for x, z in pts]
                try:
                    bm.faces.new(vs)
                except ValueError:
                    continue
                pals.append(pal)
        me = bpy.data.meshes.new(name)
        bm.to_mesh(me)
        bm.free()
        return K.Piece(me, pals, outline=False, smooth=False, name=name)


_GLYPHS = {}


def _glyph_outline(ch, offset_w, res):
    """The (offset) outline loops of one character at size 1, baseline at z = 0."""
    cu = bpy.data.curves.new("glyph", "FONT")
    cu.body = ch
    cu.size = 1.0
    cu.extrude = 0.1  # just the side walls (they follow the offset outline): we fill it ourselves
    cu.offset = offset_w
    cu.resolution_u = res
    cu.fill_mode = "NONE"
    cu.align_x = "LEFT"
    cu.align_y = "BOTTOM_BASELINE"
    ob = bpy.data.objects.new("glyph", cu)
    me = K.bake_object(ob)
    pos = [(v.co.x, v.co.y) for v in me.vertices]
    top = {v.index for v in me.vertices if v.co.z > 0.05}
    nbr = {}
    for e in me.edges:
        a, b = e.vertices
        if a in top and b in top:
            nbr.setdefault(a, []).append(b)
            nbr.setdefault(b, []).append(a)
    bpy.data.meshes.remove(me)
    loops, seen = [], set()
    for start in nbr:
        if start in seen:
            continue
        loop, prev, v = [], None, start
        while v not in seen:
            seen.add(v)
            loop.append(pos[v])
            nxt = [w for w in nbr[v] if w != prev and w not in seen]
            if not nxt:
                break
            prev, v = v, nxt[0]
        if len(loop) >= 3:
            loops.append(loop)
    return loops


def _seg_dist(p, a, b):
    ex, ez = b[0] - a[0], b[1] - a[1]
    ll = ex * ex + ez * ez or 1e-12
    t = max(0.0, min(1.0, ((p[0] - a[0]) * ex + (p[1] - a[1]) * ez) / ll))
    return math.hypot(p[0] - a[0] - ex * t, p[1] - a[1] - ez * t)


def _winding(p, segs):
    w = 0
    x, z = p
    for (x1, z1), (x2, z2) in segs:
        if z1 <= z < z2 or z2 <= z < z1:
            xc = x1 + (z - z1) * (x2 - x1) / (z2 - z1)
            if xc > x:
                w += 1 if z2 > z1 else -1
    return w


def nonzero_fill(loops, inside=None):
    """Triangles covering the region where the loops' winding number is not zero (or `inside(p)`
    says so) - the union of self-overlapping outlines. (Blender fills a text outline even-odd, which
    punches false holes where a thickened outline crosses itself: the spine of an S, an M's crotch.)"""
    from mathutils.geometry import tessellate_polygon
    segs = [(l[i], l[(i + 1) % len(l)]) for l in loops for i in range(len(l))]
    if inside is None:
        inside = lambda q: _winding(q, segs) != 0
    cuts = [[(0.0, a), (1.0, b)] for a, b in segs]
    inner = lambda t: 1e-9 < t < 1 - 1e-9
    on = lambda t: -1e-9 <= t <= 1 + 1e-9
    for i, (a, b) in enumerate(segs):
        rx, rz = b[0] - a[0], b[1] - a[1]
        rr = rx * rx + rz * rz or 1e-18
        for j in range(i + 1, len(segs)):
            c, d = segs[j]
            sx, sz = d[0] - c[0], d[1] - c[1]
            ss = sx * sx + sz * sz or 1e-18
            den = rx * sz - rz * sx
            if abs(den) < 1e-12:
                # parallel: when collinear, each cuts the other at its own ends (overlapping runs)
                if abs((c[0] - a[0]) * rz - (c[1] - a[1]) * rx) < 1e-9 * math.sqrt(rr):
                    for q in (c, d):
                        t = ((q[0] - a[0]) * rx + (q[1] - a[1]) * rz) / rr
                        if inner(t):
                            cuts[i].append((t, q))
                    for q in (a, b):
                        u = ((q[0] - c[0]) * sx + (q[1] - c[1]) * sz) / ss
                        if inner(u):
                            cuts[j].append((u, q))
                continue
            t = ((c[0] - a[0]) * sz - (c[1] - a[1]) * sx) / den
            u = ((c[0] - a[0]) * rz - (c[1] - a[1]) * rx) / den
            if on(t) and on(u) and (inner(t) or inner(u)):  # crossings and T-touches
                q = (a[0] + rx * t, a[1] + rz * t)
                if inner(t):
                    cuts[i].append((t, q))
                if inner(u):
                    cuts[j].append((u, q))
    key = lambda q: (round(q[0], 6), round(q[1], 6))
    nxt = {}
    pts = {}
    done = set()
    for cs in cuts:
        cs.sort()
        for (t0, p0), (t1, p1) in zip(cs, cs[1:]):
            if abs(p0[0] - p1[0]) + abs(p0[1] - p1[1]) < 1e-9:
                continue
            und = frozenset((key(p0), key(p1)))
            if und in done:  # a collinear run shared by two edges: once is enough
                continue
            done.add(und)
            mx, mz = (p0[0] + p1[0]) / 2, (p0[1] + p1[1]) / 2
            ln = math.hypot(p1[0] - p0[0], p1[1] - p0[1])
            nx, nz = -(p1[1] - p0[1]) / ln * 1e-5, (p1[0] - p0[0]) / ln * 1e-5
            left = inside((mx + nx, mz + nz))
            right = inside((mx - nx, mz - nz))
            if left == right:
                continue  # inside or outside on both sides: not on the boundary of the union
            a, b = (p0, p1) if left else (p1, p0)
            pts[key(a)], pts[key(b)] = a, b
            nxt.setdefault(key(a), []).append(key(b))
    out = []
    while nxt:
        start = next(iter(nxt))
        loop, k = [], start
        while k in nxt:
            loop.append(pts[k])
            k2 = nxt[k].pop()
            if not nxt[k]:
                del nxt[k]
            k = k2
            if k == start:
                break
        if len(loop) >= 3:
            out.append(loop)
    if not out:
        return []
    flat = [p for l in out for p in l]
    tris = tessellate_polygon([[Vector((x, z, 0.0)) for x, z in l] for l in out])
    return [[flat[i] for i in t] for t in tris]


def _glyph_mesh(ch, offset_w, res=4):
    """2D triangles (x, z) of one character at size 1, baseline at z = 0, thickened by offset_w."""
    key = (ch, round(offset_w, 4), res)
    if key not in _GLYPHS:
        loops = _glyph_outline(ch, offset_w, res)
        segs = [(l[i], l[(i + 1) % len(l)]) for l in loops for i in range(len(l))]
        plain = _glyph_outline(ch, 0.0, res)
        psegs = [(l[i], l[(i + 1) % len(l)]) for l in plain for i in range(len(l))]

        def inside(q):
            """In the thickened letter: inside its offset outline, or (where the offset outline
            folds back on itself in a tight inner curve) within offset_w of the plain letter."""
            if _winding(q, segs) != 0 or _winding(q, psegs) != 0:
                return True
            return min(_seg_dist(q, a, b) for a, b in psegs) < 0.97 * offset_w
        _GLYPHS[key] = nonzero_fill(loops, inside if offset_w > 0 else None)
    return _GLYPHS[key]


def glyph_polys(text, size, bold, ink, place, spacing=0.04):
    """Lays `text` out letter by letter. bold / ink = curve offsets (in units of size) for the fill and
    for the ink copy. place(x_along, width) -> (x, z, ang, scale) puts the letter whose centre is
    x_along into the line (x_along runs over 0..total width, in units of size).
    Returns [(fill_polys, ink_polys)] per letter, in world (x, z)."""
    widths = []
    for ch in text:
        if ch == " ":
            widths.append((None, 0.32))
            continue
        polys = _glyph_mesh(ch, bold)
        xs = [p[0] for poly in polys for p in poly]
        widths.append(((min(xs) + max(xs)) / 2, max(xs) - min(xs)))
    total = sum(w for _, w in widths) + spacing * (len(text) - 1)
    out = []
    x = 0.0
    for ch, (cx, w) in zip(text, widths):
        if cx is not None:
            mid = x + w / 2
            px, pz, ang, sc = place(mid, total)
            fill = [xform([(u - cx, v) for u, v in poly], px, pz, ang, size * sc) for poly in _glyph_mesh(ch, bold)]
            inkp = [xform([(u - cx, v) for u, v in poly], px, pz, ang, size * sc) for poly in _glyph_mesh(ch, bold + ink)]
            out.append((fill, inkp))
        x += w + spacing
    return out


def _clip_half(poly, f):
    """Sutherland-Hodgman: the part of `poly` where f(p) <= 0 (f linear)."""
    out = []
    n = len(poly)
    for i in range(n):
        a, b = poly[i], poly[(i + 1) % n]
        fa, fb = f(a), f(b)
        if fa <= 0:
            out.append(a)
        if (fa <= 0) != (fb <= 0):
            t = fa / (fa - fb)
            out.append((a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t))
    return out


def _clip_rect(poly, rect):
    x0, z0, x1, z1 = rect
    for f in (lambda p: x0 - p[0], lambda p: p[0] - x1, lambda p: z0 - p[1], lambda p: p[1] - z1):
        poly = _clip_half(poly, f) if len(poly) >= 3 else poly
    return clean(poly) if len(poly) >= 3 else []


def paper(w, h, xs, zs, front_pal, back_pal, rim_pal, thick=T, curl=None, name="paper"):
    """The sheet: a closed slab (front faces -Y, back on the wall at y = 0) cut into the cells of the
    grid lines xs / zs (colour borders), coloured front_pal(x, z) at each cell's centre.
    curl = (sx, sz, leg, radius): that corner (sx, sz = +-1) has peeled off along the diagonal fold
    `leg` from the corner, rolled round a cylinder of `radius` and lies back over the front."""
    xs, zs = sorted(set(xs)), sorted(set(zs))
    if curl:
        sx, sz, leg, rad = curl
        nx, nz = sx / math.sqrt(2), sz / math.sqrt(2)
        corner = (sx * w / 2, h if sz > 0 else 0.0)
        smax = leg / math.sqrt(2)
        c0 = nx * corner[0] + nz * corner[1] - smax  # fold line: nx x + nz z = c0

        def dist(p):
            return nx * p[0] + nz * p[1] - c0
    cells = []
    for i in range(len(xs) - 1):
        for j in range(len(zs) - 1):
            poly = [(xs[i], zs[j]), (xs[i + 1], zs[j]), (xs[i + 1], zs[j + 1]), (xs[i], zs[j + 1])]
            if curl:
                poly = clean(_clip_half(poly, dist))
                if len(poly) < 3:
                    continue
            cells.append(poly)
    # welded vertices keyed by their flat position
    key = lambda p: (round(p[0], 5), round(p[1], 5))
    flat = {}
    for poly in cells:
        for p in poly:
            flat.setdefault(key(p), p)
    # cells must contain every vertex lying on their edges (no T-junctions -> a closed sheet)
    def with_edge_verts(poly):
        out = []
        n = len(poly)
        for i in range(n):
            a, b = poly[i], poly[(i + 1) % n]
            out.append(a)
            ex, ez = b[0] - a[0], b[1] - a[1]
            ll = ex * ex + ez * ez
            mids = []
            for q in flat.values():
                t = ((q[0] - a[0]) * ex + (q[1] - a[1]) * ez) / ll
                if 1e-6 < t < 1 - 1e-6:
                    px, pz = a[0] + ex * t, a[1] + ez * t
                    if abs(px - q[0]) + abs(pz - q[1]) < 1e-5:
                        mids.append((t, q))
            out += [q for t, q in sorted(mids)]
        return out
    faces2d = [with_edge_verts(c) for c in cells]
    if curl:
        # the curl strip: rows across the fold (straight along it, so only the rows need detail)
        tx, tz = -nz, nx
        fold = sorted([q for q in flat.values() if abs(dist(q)) < 1e-5], key=lambda q: q[0] * tx + q[1] * tz)
        foot = (corner[0] - nx * smax, corner[1] - nz * smax)  # fold point on the diagonal
        ts = [(q[0] - foot[0]) * tx + (q[1] - foot[1]) * tz for q in fold]
        n_roll = 8
        srows = [math.pi * rad * k / n_roll for k in range(n_roll + 1)]
        rest = smax - math.pi * rad
        srows += [math.pi * rad + rest * k / 3 for k in range(1, 4)]
        rows = []
        for s in srows:
            f = max(0.0, 1.0 - s / smax)
            row = [(foot[0] + nx * s + tx * t * f, foot[1] + nz * s + tz * t * f) for t in ts]
            rows.append(row)
        rows[0] = fold
        for r0, r1 in zip(rows, rows[1:]):
            for k in range(len(ts) - 1):
                quad = clean([r0[k], r0[k + 1], r1[k + 1], r1[k]], 1e-7)
                if len(quad) >= 3:
                    faces2d.append(quad)

    def place(p):
        """flat (x, z) -> (mid-surface position, front normal)"""
        if not curl or dist(p) <= 1e-9:
            return Vector((p[0], -thick / 2, p[1])), Vector((0, -1, 0))
        s = dist(p)
        if s <= math.pi * rad:
            th = s / rad
            u, wv = rad * math.sin(th), rad * (1 - math.cos(th))
        else:
            sig = s - math.pi * rad
            k = 0.06  # the flap lifts a little toward its tip
            u, wv = -sig, 2 * rad + k * sig * sig
            th = math.atan2(2 * k * sig, -1.0)
        bx, bz = p[0] - nx * s, p[1] - nz * s
        mid = Vector((bx + nx * u, -thick / 2 - wv, bz + nz * u))
        nrm = Vector((-nx * math.sin(th), -math.cos(th), -nz * math.sin(th)))
        return mid, nrm

    bm = bmesh.new()
    front, back = {}, {}
    for k2, p in list(flat.items()) + [(key(q), q) for f in faces2d for q in f]:
        if k2 in front:
            continue
        mid, nrm = place(p)
        front[k2] = bm.verts.new(mid + nrm * thick / 2)
        back[k2] = bm.verts.new(mid - nrm * thick / 2)
    pals = []
    edge_use = {}
    for f in faces2d:
        ks = [key(q) for q in f]
        ks = [k2 for i, k2 in enumerate(ks) if k2 != ks[i - 1]]
        if len(ks) < 3:
            continue
        if area2(f) < 0:
            ks.reverse()
        cx = sum(q[0] for q in f) / len(f)
        cz = sum(q[1] for q in f) / len(f)
        bm.faces.new([front[k2] for k2 in ks])
        pals.append(front_pal(cx, cz))
        bm.faces.new([back[k2] for k2 in reversed(ks)])
        pals.append(back_pal)
        for i in range(len(ks)):
            e = (ks[i], ks[(i + 1) % len(ks)])
            edge_use[e] = edge_use.get(e, 0) + 1
    for (a, b), cnt in edge_use.items():
        if (b, a) not in edge_use:  # boundary edge: a rim quad
            bm.faces.new((front[b], front[a], back[a], back[b]))
            pals.append(rim_pal)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    return K.Piece(me, pals, outline=True, smooth=False, name=name)


def push_pin(x, z, y0, cols, name="pin"):
    """A chunky push pin standing on the paper front y0: base flange, waisted grip, round cap with a
    highlight. cols = (main, dark, light)."""
    main, dark, light = cols
    rx = (math.pi / 2, 0, 0)
    flange = K.cylinder(dark, 0.19, 0.035, M((x, y0 - 0.0175, z), rx), seg=16, smooth=False, name=name)
    grip = K.cylinder(main, 0.1, 0.08, M((x, y0 - 0.035 - 0.04, z), rx), seg=12, smooth=False, name=name)
    cap = K.cylinder(main, 0.24, 0.06, M((x, y0 - 0.115 - 0.03, z), rx), radius2=0.21, seg=18, smooth=False, name=name)
    cap.face_pal = [main if f.normal.y < -0.7 else dark for f in cap.mesh.polygons]
    # highlight: a small flat dot on the cap's upper left
    hl = Art()
    hl.add([ellipse(x - 0.075, z + 0.075, 0.08, 0.05, rot=0.7, n=10)], light)
    glint = hl.piece(y0 - 0.175 - 0.01, name=name + "_hl")
    return [flange, grip, cap, glint]


def camera_only(outline):
    """Cycles-only flags (no effect on the GLB or the game): stops the inverted hull blocking bounce
    and sky light in the preview renders (as props/picture.py does)."""
    outline.visible_diffuse = False
    outline.visible_glossy = False
    outline.visible_transmission = False


# ============================================================== the rocket poster
X0, X1 = -W / 2 + MARGIN, W / 2 - MARGIN   # the print
Z0, Z1 = MARGIN, H - MARGIN


def _front(x, z):
    if x < X0 or x > X1 or z < Z0 or z > Z1:
        return PAPER
    if x < X0 + FRAME or x > X1 - FRAME or z < Z0 + FRAME or z > Z1 - FRAME:
        return INK
    return SKY1


def _sky(art):
    """Two lower sky bands with wavy tops (the top band is the paper itself)."""
    def band(top, bottom, pal):
        xs = [X0 + FRAME + (X1 - X0 - 2 * FRAME) * k / 24 for k in range(25)]
        pts = [(x, bottom(x)) for x in xs] + [(x, top(x)) for x in reversed(xs)]
        art.add([pts], pal)
    w1 = lambda x: 8.6 + 0.25 * math.sin(x * 0.9 + 0.6)
    w2 = lambda x: 4.9 + 0.22 * math.sin(x * 1.1 + 2.0)
    band(w1, w2, SKY2)
    band(w2, lambda x: Z0 + FRAME, SKY3)


def _rocket(art, ox, oz, ang, s):
    """The rocket in its own frame (u across, v up the axis, v = 0 at the bottom of the body). Shaded
    parts are cut side by side (light left, shade right) instead of stacked, to keep the paint thin."""
    L = 4.4      # nose tip
    VB = 3.0     # nose cone starts here (its bottom edge sags like a band round a cylinder)
    SPLIT = 0.46  # light | shade border, as a fraction of the half width

    def hw(v):
        if v >= 1.5:
            t = min((v - 1.5) / (L - 1.5), 1.0)
            return 0.86 * (1 - t * t)
        return 0.86 - 0.16 * ((1.5 - v) / 1.5) ** 2

    def sag(v0, depth):
        """A band edge round the body: v0 at the sides, `depth` lower in the middle."""
        return lambda u: v0 - depth * max(0.0, 1 - (u / max(hw(v0), 1e-3)) ** 2)

    def region(f0, f1, vbot, vtop, n=10):
        """Between the side curves u = f0 hw(v) and u = f1 hw(v), above vbot(u) and below vtop(u)."""
        def corner(f, curve):
            v = curve(0.0)
            for _ in range(30):
                v = curve(f * hw(v))
            return v
        b0, b1 = corner(f0, vbot), corner(f1, vbot)
        t0, t1 = corner(f0, vtop), corner(f1, vtop)
        pts = [(f0 * hw(b0) + (f1 * hw(b1) - f0 * hw(b0)) * k / n, 0.0) for k in range(n + 1)]
        pts = [(u, vbot(u)) for u, _ in pts]
        pts += [(f1 * hw(b1 + (t1 - b1) * k / n), b1 + (t1 - b1) * k / n) for k in range(1, n + 1)]
        top = [(f1 * hw(t1) + (f0 * hw(t0) - f1 * hw(t1)) * k / n, 0.0) for k in range(1, n + 1)]
        pts += [(u, vtop(u)) for u, _ in top]
        pts += [(f0 * hw(t0 + (b0 - t0) * k / n), t0 + (b0 - t0) * k / n) for k in range(1, n)]
        return pts

    X = lambda pts: xform(pts, ox, oz, ang, s)
    tip = lambda u: L
    bottom = sag(0.0, -0.0)
    bottom = lambda u: -0.08 * max(0.0, 1 - (u / hw(0.0)) ** 2)
    # fins behind the body (the far one in shade) and the engine nozzle
    fin = smooth_loop([(0.6, 1.75), (1.2, 0.95), (1.62, -0.05), (1.62, -0.62), (1.2, -0.38), (0.55, -0.05)], 5)
    nozzle = [(-0.42, 0.05), (0.42, 0.05), (0.58, -0.42), (-0.58, -0.42)]
    art.group([(X(fin), RED_D), (X(xform(fin, mirror=True)), RED), (X(nozzle), NOZZLE)])
    # the flame comes out of the nozzle: three nested tongues, only the outer one inked
    def flame(top_w, width, length, wob, v_top=-0.42, n=30):
        pts = []
        for k in range(n + 1):
            t = k / n
            tau = 1 - abs(1 - 2 * t)  # 0 at the top corners .. 1 at the tip
            bulge = math.sin(min(tau * 2.2, 1.0) * math.pi / 2)
            hwf = (top_w + (width - top_w) * bulge) * (1 - tau) ** 0.9 * (1 + wob * math.sin(tau * 3.0 * math.pi))
            pts.append((hwf if t < 0.5 else -hwf, v_top - length * tau))
        return pts
    art.group([(X(flame(0.56, 0.86, 3.0, 0.1)), FLAME_O)])
    art.add([X(flame(0.38, 0.6, 2.25, 0.12, -0.45))], FLAME_M)
    art.add([X(flame(0.2, 0.34, 1.45, 0.1, -0.45))], FLAME_Y)
    def shaded(vbot, vtop, light, shade, ink=INK_W, n=14):
        """One inked part of the body, cut into a light left and a shaded right side by side."""
        art.add([X(offset(region(-1, 1, vbot, vtop, n), ink))], INK)
        art.add([X(region(-1, SPLIT, vbot, vtop, n))], light)
        art.add([X(region(SPLIT, 1, vbot, vtop, n))], shade)
    shaded(bottom, tip, HULL, HULL_D, n=24)
    # the nose cone and a band near the bottom
    shaded(sag(VB, 0.14), tip, RED, RED_D)
    shaded(sag(0.42, 0.1), sag(0.72, 0.1), RED, RED_D, ink=0.05, n=10)
    # the centre fin in front: light left half, shade right half
    half = [(0.0, 1.05), (0.1, 0.85), (0.17, 0.55), (0.24, -0.25), (0.22, -0.5), (0.16, -0.6), (0.0, -0.6)]
    cfin = half + [(-u, v) for u, v in reversed(half[1:-1])]
    art.add([X(offset(cfin, INK_W))], INK)
    art.add([X([(-u, v) for u, v in half])], RED)
    art.add([X(half)], RED_D)
    # porthole
    wv = 2.2
    art.group([(X(circle(0, wv, 0.5, 22)), METAL)])
    art.add([X(circle(0, wv, 0.36, 20))], GLASS)
    art.add([X(ellipse(-0.1, wv + 0.12, 0.13, 0.08, rot=0.6, n=12))], GLASS_L)
    # speed lines beside the rocket
    for u, v0, v1 in ((-1.25, 2.1, 3.5), (-1.55, 0.9, 1.9), (1.3, 2.5, 3.6)):
        art.add([X(smooth_loop([(u - 0.05, v0), (u + 0.05, v0), (u + 0.05, v1), (u - 0.05, v1)], 3))], STAR_W)


def _smoke(art, front_row):
    """The bank of puffs the rocket rises out of: a shaded back row behind the flame, a white front
    row over it. Each row is one inked silhouette."""
    back = [(-3.75, 1.2, 0.8), (-2.45, 1.45, 0.72), (-1.0, 1.05, 0.6), (0.35, 1.35, 0.68), (1.75, 1.45, 0.75),
            (3.3, 1.25, 0.82)]
    front = [(-3.9, 0.5, 0.8), (-2.65, 0.6, 0.75), (-1.15, 0.55, 0.8), (0.4, 0.6, 0.8), (1.9, 0.55, 0.78),
             (3.4, 0.5, 0.8), (-2.0, 1.2, 0.45), (-0.1, 1.15, 0.47)]
    base = [(X0, Z0), (X1, Z0), (X1, 0.6), (X0, 0.6)]  # no sky between the puffs' bottoms
    if front_row:
        art.group([(circle(x, z, r, 26), SMOKE) for x, z, r in front] + [(base, SMOKE)])
    else:
        art.group([(circle(x, z, r, 26), SMOKE_D) for x, z, r in back])


def _planet(art, cx, cz, r):
    tilt = 0.32
    # back half of the ring, the planet, then the front half over it
    ro, ri = (r * 1.85, r * 0.5), (r * 1.32, r * 0.3)
    back_ring = ellipse_band(cx, cz, ro[0], ro[1], ri[0], ri[1], 0.0, math.pi, tilt)
    back_ink = ellipse_band(cx, cz, ro[0] + INK_W, ro[1] + INK_W, ri[0] - INK_W, ri[1] - INK_W, 0.0, math.pi, tilt)
    art.group([(back_ring, RING_D, back_ink)])
    art.group([(circle(cx, cz, r, 30), PLANET_D)])
    art.add([circle(cx - 0.13 * r, cz + 0.13 * r, r * 0.8, 28)], PLANET)
    for z0, z1 in ((0.15, 0.32), (-0.38, -0.22)):
        art.add([disc_band(cx, cz, r - 0.01, z0 * r, z1 * r, tilt)], PLANET_B)
    front_ring = ellipse_band(cx, cz, ro[0], ro[1], ri[0], ri[1], math.pi, math.tau, tilt)
    front_ink = ellipse_band(cx, cz, ro[0] + INK_W, ro[1] + INK_W, ri[0] - INK_W, ri[1] - INK_W, math.pi, math.tau, tilt)
    art.group([(front_ring, RING, front_ink)])


def _moon(art, cx, cz, r):
    art.group([(circle(cx, cz, r, 28), MOON_D)])
    art.add([circle(cx - 0.11 * r, cz + 0.11 * r, r * 0.82, 26)], MOON)
    for dx, dz, rr in ((-0.35, 0.3, 0.2), (0.25, -0.1, 0.26), (-0.2, -0.45, 0.13), (0.38, 0.45, 0.11)):
        art.add([ellipse(cx + dx * r, cz + dz * r, rr * r, rr * r * 0.85, 0.3, 12)], MOON_D)


def _stars(art):
    big = [(-3.5, 10.0, 0.3, 0.2), (3.55, 7.6, 0.28, -0.1), (-1.0, 9.6, 0.22, 0.3), (2.85, 5.25, 0.24, 0.15),
           (-3.7, 5.2, 0.26, -0.2), (-3.3, 3.3, 0.2, 0.1), (3.6, 3.7, 0.22, 0.3), (1.0, 9.9, 0.18, -0.2)]
    for x, z, r, rot in big:
        art.group([(star(x, z, r, r * 0.45, 5, rot), STAR)], ink=0.055)
    sparkles = [(-2.6, 11.0, 0.17), (2.4, 9.4, 0.15), (-0.2, 6.9, 0.12), (3.0, 6.4, 0.15), (-3.9, 8.2, 0.13),
                (-1.4, 4.5, 0.12), (3.8, 9.9, 0.12)]
    for x, z, r in sparkles:
        art.add([star(x, z, r, r * 0.3, 4)], STAR_W)
    dots = [(-3.0, 9.1), (-1.8, 10.3), (0.4, 10.5), (1.6, 7.2), (-3.3, 6.6), (-0.6, 5.4), (2.9, 4.6), (-3.95, 4.1),
            (3.9, 5.9), (-2.1, 6.0), (0.6, 7.9)]
    for x, z in dots:
        art.add([circle(x, z, 0.05, 8)], STAR_W)


def _title(art):
    # "BLAST" on an arch, "OFF!" under it, both chunky (curve offset) with a red drop shadow
    def arch(cx, top, radius, size):
        def place(mid, total):
            a = (mid - total / 2) * size / radius
            return cx + radius * math.sin(a), top - radius * (1 - math.cos(a)), -a, 1.0
        return place
    size = 1.85
    g1 = glyph_polys("BLAST", size, 0.055, 0.075, arch(0.0, 11.25, 7.0, size), spacing=0.05)
    g2 = glyph_polys("OFF!", size, 0.055, 0.075, arch(-0.35, 9.55, 9.0, size), spacing=0.05)
    art.text(g1 + g2, TITLE, shadow=(0.09, -0.12), shadow_pal=TITLE_SH, ink=True)


def paint():
    """The print, back to front."""
    art = Art(clip=(X0 + FRAME, Z0 + FRAME, X1 - FRAME, Z1 - FRAME))
    _sky(art)
    _stars(art)
    _moon(art, 3.1, 9.2, 0.8)
    _planet(art, -2.55, 7.35, 1.0)
    _smoke(art, False)
    _rocket(art, -0.35, 3.15, -0.36, 1.2)
    _smoke(art, True)
    _title(art)
    return art


def build():
    xs = [-W / 2, X0, X0 + FRAME, X1 - FRAME, X1, W / 2]
    zs = [0.0, Z0, Z0 + FRAME, Z1 - FRAME, Z1, H]
    p = [paper(W, H, xs, zs, _front, PAPER_B, PAPER, curl=(1, 1, CURL_L, CURL_R))]
    art = paint()
    p.append(art.piece(-T))
    # pins in the border: three in the corners, the top-right one further along the top edge (its
    # corner has curled off). Their caps clear the paint, which only reaches under a flange's rim.
    e = 0.21
    for (x, z), cols in (((-W / 2 + e, H - e), PIN_RED), ((W / 2 - CURL_L - 0.55, H - e), PIN_BLUE),
                         ((-W / 2 + e, e), PIN_YEL), ((W / 2 - e, e), PIN_GRN)):
        p += push_pin(x, z, -T, cols)
    print(f"{NAME}: {art.max_slot()} paint layers (art front at y = {-T - DY * art.max_slot():.3f})")
    body, outline = K.finish(p, NAME, outline_width=OUTLINE)
    camera_only(outline)
    return [body, outline] + K.markers(NAME)
