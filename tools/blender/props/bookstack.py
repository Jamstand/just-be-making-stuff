"""
props/bookstack.py - the BookStack prop (ReplicatedStorage.MapMeshes.BookStack): five chunky
hardcover books stacked unevenly on the bedroom floor, a gold ribbon bookmark hanging out of one and
a little striped sock tucked into the top one as a bookmark. See props/__init__.py for the
conventions every prop follows.

Every book is four pieces: two cover boards, a rounded spine (an elliptic tube along the spine edge,
with two gold bands near its ends and a cream title label on its outer face) and a cream page block
recessed under the boards on the three open sides, with two thin page lines cut into its edges.
Their outline hulls meet at the hinges and round the pages, which draws the ink lines a cartoon book
has there. The books alternate spine-out / pages-out (one shows its spine to the side) and are each
turned a little. The top book is a navy bedtime-story book with a yellow moon and star on its cover.
"""
import math
import bmesh
from mathutils import Matrix, Vector
import sockkit as K
from sockkit import M, hexcol
from props.common import *  # noqa: F401,F403 - shared colours (read-only)

NAME = "BookStack"


def _cols(name, light, base, dark):
    return (hexcol(f"bookstack_{name}_light", light), hexcol(f"bookstack_{name}", base), hexcol(f"bookstack_{name}_dark", dark))


C_RED = _cols("red", "#F2665A", "#D9443D", "#A83030")
C_BLUE = _cols("blue", "#6F97EC", "#4570D2", "#3152A6")
C_YELLOW = _cols("yellow", "#FFD267", "#F5AE33", "#C9831F")
C_GREEN = _cols("green", "#7CCB5F", "#4FA645", "#367C34")
C_NAVY = _cols("navy", "#5A5BB8", "#40408F", "#2C2B68")
PAGE = _cols("page", "#FFF8E6", "#F5E8C8", "#D8C49C")
PAGE_LINE = hexcol("bookstack_page_line", "#CDB78E")
GOLD = hexcol("bookstack_gold", "#F7C948")
GOLD_D = hexcol("bookstack_gold_dark", "#CF9A2C")
LABEL = hexcol("bookstack_label", "#F8EDD3")
RIBBON = _cols("ribbon", "#FFD95E", "#F5BD32", "#C98D1E")
MOON = hexcol("bookstack_moon", "#FFDB5C")
SOCK = _cols("sock", "#FFFFFF", "#F6F0F4", "#D4C8DA")
SOCK_STRIPE = _cols("sock_stripe", "#FF8FB5", "#F2638F", "#C44670")

BOARD = 0.1      # cover board thickness
OVER = 0.08      # how far the boards overhang the pages
SPINE_OUT = 0.07  # how far the rounded spine bulges past the boards

# (colours, footprint (x, y), thickness, which side the spine faces, yaw, (x, y) offset) - bottom to top
STACK = [
    (C_RED, (3.7, 2.62), 0.98, "front", 0.04, (0.0, 0.06)),
    (C_BLUE, (3.3, 2.42), 0.78, "back", -0.15, (0.16, 0.12)),
    (C_YELLOW, (3.45, 2.48), 0.9, "front", 0.12, (-0.14, 0.04)),
    (C_GREEN, (2.95, 2.25), 0.72, "right", -0.2, (0.2, 0.16)),
    (C_NAVY, (2.7, 2.0), 0.72, "back", 0.26, (-0.1, 0.04)),
]


def _tone(cols, nz):
    return cols[0] if nz > 0.6 else (cols[2] if nz < -0.4 else cols[1])


def _box(size, center, bevel, segs, cuts_z=()):
    """A bevelled box bmesh (local), optionally cut by horizontal planes at `cuts_z`."""
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    bmesh.ops.scale(bm, vec=Vector(size), verts=bm.verts)
    bmesh.ops.bevel(bm, geom=list(bm.edges) + list(bm.verts), offset=bevel, segments=segs, profile=0.5, affect="EDGES",
                    clamp_overlap=True)
    for z in cuts_z:
        geom = list(bm.verts) + list(bm.edges) + list(bm.faces)
        bmesh.ops.bisect_plane(bm, geom=geom, plane_co=(0, 0, z - center[2]), plane_no=(0, 0, 1))
    bmesh.ops.translate(bm, vec=Vector(center), verts=bm.verts)
    bm.normal_update()
    return bm


def _piece(bm, pal_fn, name, outline=True, flat_fn=None):
    pal, flat = [], []
    for i, f in enumerate(bm.faces):
        pal.append(pal_fn(f))
        if flat_fn and flat_fn(f):
            flat.append(i)
    p = K.Piece(K._bm_to_mesh(bm, name), pal, outline, True, name)
    p.flat_faces = flat
    return p


def _spine(length, t, cols, x0, z0):
    """Rounded spine along local X at y = y0 (the book's front edge), elliptic section (bulging
    toward -Y), gold bands near the ends, cream label on the outer face in the middle."""
    seg = 16
    sy, sz = 0.2, t / 2
    h = length / 2 - 0.02
    stations = [(-h, "cap"), (-h + 0.18, "band"), (-h + 0.32, "cover"), (-0.42 * h, "label"), (0.42 * h, "cover"),
                (h - 0.32, "band"), (h - 0.18, "cover"), (h, None)]
    bm = bmesh.new()
    rings = []
    for x, _tag in stations:
        rings.append([bm.verts.new((x, -sy * math.cos(a), sz * math.sin(a))) for a in (j / seg * math.tau for j in range(seg))])
    tags = []
    for i in range(len(rings) - 1):
        for j in range(seg):
            k = (j + 1) % seg
            bm.faces.new((rings[i][j], rings[i][k], rings[i + 1][k], rings[i + 1][j]))
            a = (j + 0.5) / seg * math.tau
            tag = stations[i][1]
            if tag == "label" and math.cos(a) < math.cos(math.radians(50)):
                tag = "cover"
            tags.append(tag)
    bm.faces.new(rings[0][::-1])
    bm.faces.new(rings[-1])
    tags += ["end", "end"]
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    bmesh.ops.translate(bm, vec=Vector((0, x0, z0)), verts=bm.verts)
    bm.normal_update()

    def pal(f):
        tag = tags[f.index]
        nz = f.normal.z
        if tag == "band":
            return GOLD if nz > -0.4 else GOLD_D
        if tag == "label":
            return LABEL
        return _tone(cols, nz)
    bm.faces.ensure_lookup_table()
    for i, f in enumerate(bm.faces):
        f.index = i
    return _piece(bm, pal, "spine", flat_fn=lambda f: tags[f.index] == "end")


def _book(cols, size, t):
    """One book, local frame: spine along the FRONT edge (-Y), footprint `size` (x, y), bottom at
    z = 0, centred on the origin. Returns (pieces, info)."""
    sx, sy = size
    p = []
    for z in (BOARD / 2, t - BOARD / 2):
        bm = _box((sx, sy - 0.1, BOARD), (0, 0.05, z), 0.035, 2)
        p.append(_piece(bm, lambda f: _tone(cols, f.normal.z), "board"))
    # pages: recessed on the three open sides, two page lines cut into their edges
    ph = t - 2 * BOARD + 0.02
    py0 = -sy / 2 + 0.12
    py1 = sy / 2 - OVER
    lines = [(BOARD + ph * f) for f in (0.34, 0.68)]
    cuts = []
    for z in lines:
        cuts += [z - 0.012, z + 0.012]
    bm = _box((sx - 2 * OVER, py1 - py0, ph), (0, (py0 + py1) / 2, t / 2), 0.04, 1, cuts)

    def page_pal(f):
        c = f.calc_center_median()
        if abs(f.normal.z) < 0.5 and any(abs(c.z - z) < 0.012 for z in lines):
            return PAGE_LINE
        return _tone(PAGE, f.normal.z)
    p.append(_piece(bm, page_pal, "pages", flat_fn=lambda f: max(abs(f.normal.x), abs(f.normal.y), abs(f.normal.z)) > 0.999))
    p.append(_spine(sx, t, cols, -sy / 2 + 0.2 - SPINE_OUT, t / 2))
    return p, {"pages_y1": py1, "pages_z": (BOARD, t - BOARD), "t": t}


SIDE_SPIN = {"front": 0.0, "back": math.pi, "right": math.pi / 2, "left": -math.pi / 2}


def _xf(pieces, m):
    for pc in pieces:
        pc.mesh.transform(m)
    return pieces


def _flat_poly(pts, z, pal, name, m):
    bm = bmesh.new()
    f = bm.faces.new([bm.verts.new((x, y, z)) for x, y in pts])
    bm.normal_update()
    if f.normal.z < 0:
        bmesh.ops.reverse_faces(bm, faces=[f])
    bmesh.ops.transform(bm, matrix=m, verts=bm.verts)
    return K.Piece(K._bm_to_mesh(bm, name), pal, False, False, name)


def _moon_and_star(m, z):
    """A yellow crescent moon and a little star on the top cover (book-local coords via m)."""
    out = []
    n = 14
    r1, off = 0.5, Vector((0.2, 0.12))   # outer radius; the inner arc's centre is offset up and right
    cx, cy = -0.35, 0.15
    pts = []
    # outer arc of the crescent (the lit side faces lower-left), then back along the inner arc
    for i in range(n + 1):
        a = math.radians(40 + 280 * i / n)
        pts.append((cx + r1 * math.cos(a), cy + r1 * math.sin(a)))
    a_end, a_start = math.radians(320), math.radians(40)
    p_end = Vector((cx + r1 * math.cos(a_end), cy + r1 * math.sin(a_end)))
    p_start = Vector((cx + r1 * math.cos(a_start), cy + r1 * math.sin(a_start)))
    c2 = Vector((cx, cy)) + off
    b0 = math.atan2(p_end.y - c2.y, p_end.x - c2.x)
    b1 = math.atan2(p_start.y - c2.y, p_start.x - c2.x)
    if b1 > b0:
        b1 -= math.tau
    for i in range(1, n):
        b = b0 + (b1 - b0) * i / n
        rr = (p_end - c2).length + ((p_start - c2).length - (p_end - c2).length) * i / n
        pts.append((c2.x + rr * math.cos(b), c2.y + rr * math.sin(b)))
    out.append(_flat_poly(pts, z, MOON, "moon", m))
    star = []
    sx, sy = 0.55, -0.2
    for i in range(10):
        a = math.pi / 2 + i * math.pi / 5
        r = 0.24 if i % 2 == 0 else 0.1
        star.append((sx + r * math.cos(a), sy + r * math.sin(a)))
    out.append(_flat_poly(star, z, MOON, "star", m))
    return out


def _strip(points, width, thick, cols, name, notch=0.0, across=Vector((1, 0, 0))):
    """A flat ribbon (rectangular section) through `points`, `width` along `across`; the last end
    is cut into a V (`notch` deep)."""
    bm = bmesh.new()
    n = len(points)
    secs = []
    for i, pt in enumerate(points):
        pt = Vector(pt)
        tan = (Vector(points[min(i + 1, n - 1)]) - Vector(points[max(i - 1, 0)])).normalized()
        nrm = tan.cross(across).normalized()
        sec = []
        for u in (-1.0, 0.0, 1.0):
            c = pt + across * (u * width / 2)
            if i == n - 1 and u == 0.0:
                c -= tan * notch
            sec.append((bm.verts.new(c + nrm * thick / 2), bm.verts.new(c - nrm * thick / 2)))
        secs.append(sec)
    for i in range(n - 1):
        a, b = secs[i], secs[i + 1]
        for k in range(2):
            bm.faces.new((a[k][0], a[k + 1][0], b[k + 1][0], b[k][0]))
            bm.faces.new((a[k][1], b[k][1], b[k + 1][1], a[k + 1][1]))
        bm.faces.new((a[0][0], b[0][0], b[0][1], a[0][1]))
        bm.faces.new((a[2][0], a[2][1], b[2][1], b[2][0]))
    for sec, flip in ((secs[0], False), (secs[-1], True)):
        for k in range(2):
            q = (sec[k][0], sec[k][1], sec[k + 1][1], sec[k + 1][0])
            bm.faces.new(q[::-1] if flip else q)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    bm.normal_update()
    return _piece(bm, lambda f: _tone(cols, f.normal.z), name)


def _catmull(points, n=6):
    out = []
    pts = [Vector(p) for p in points]
    for i in range(len(pts) - 1):
        p0, p1, p2, p3 = pts[max(i - 1, 0)], pts[i], pts[i + 1], pts[min(i + 2, len(pts) - 1)]
        for s in range(n):
            t = s / n
            out.append(0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t
                              + (-p0 + 3 * p1 - 3 * p2 + p3) * t * t * t))
    out.append(pts[-1])
    return out


def _sock(points, flat_below_y):
    """A little striped sock (white, pink stripes round the leg, pink heel and toe) along `points`:
    the cuff end first (tucked into the book), then the leg hanging over the edge, a heel bend at
    points[-2] and the foot ending at points[-1]. The part hanging in front of the stack is
    flattened front-to-back, like an empty sock, so it shows its sock outline to the room."""
    n = 12
    dense = _catmull(points, n)
    acc = [0.0]
    for a, b in zip(dense, dense[1:]):
        acc.append(acc[-1] + (b - a).length)
    heel = acc[n * (len(points) - 2)]
    total = acc[-1]

    def nearest(c):
        i = min(range(len(dense)), key=lambda k: (dense[k] - c).length_squared)
        return i

    def pal(c):
        a = acc[nearest(c)]
        if a > total - 0.3 or abs(a - heel) < 0.17:
            return SOCK_STRIPE[1]
        leg = heel - a
        if 0.3 < leg < 1.05 and int((leg - 0.3) / 0.13) % 2 == 0:
            return SOCK_STRIPE[1]
        return SOCK[1]
    radii = [1.0] * len(points)
    radii[-2] = 1.12   # a fuller heel
    radii[-1] = 0.9
    pc = K.tube(SOCK[1], [tuple(q) for q in points], radius=0.21, radii=radii, res=7, bevel_res=2, name="sock",
                face_pal=pal)
    me = pc.mesh
    for v in me.vertices:
        c = dense[nearest(v.co)]
        if c.y < flat_below_y:
            d = v.co - c
            v.co = c + Vector((d.x, d.y * 0.5, d.z))
    me.update()
    # tones after flattening: lit top / base / shade
    for i, f in enumerate(me.polygons):
        cur = pc.face_pal[i]
        cols = SOCK_STRIPE if cur == SOCK_STRIPE[1] else SOCK
        pc.face_pal[i] = _tone(cols, f.normal.z)
    return pc


def build():
    p = []
    z = 0.0
    mats, infos = [], []
    for cols, size, t, side, yaw, (ox, oy) in STACK:
        spin = SIDE_SPIN[side]
        bsize = size if side in ("front", "back") else (size[1], size[0])
        pieces, info = _book(cols, bsize, t)
        m = M((ox, oy, z), rot=(0, 0, yaw + spin))
        p += _xf(pieces, m)
        mats.append(m)
        infos.append(info)
        z += t
    # moon and star on the top cover
    top_m, top_info = mats[-1], infos[-1]
    p += _moon_and_star(top_m @ Matrix.Rotation(math.pi, 4, "Z"), top_info["t"] + 0.003)
    # gold ribbon from the blue book's pages (book 2: pages face front), draped down the red one
    m2, i2 = mats[1], infos[1]
    zr = (i2["pages_z"][0] + i2["pages_z"][1]) / 2
    # in book 2's frame the pages face +Y (it is spun 180 degrees), so walk out along +Y
    x_r = 0.55
    start = m2 @ Vector((x_r, i2["pages_y1"] - 0.25, zr))
    out = m2 @ Vector((x_r, i2["pages_y1"] + 0.06, zr))
    red_top = STACK[0][2]
    red_front = -STACK[0][1][1] / 2 - SPINE_OUT - 0.02
    pts = [start, out, Vector((out.x, out.y - 0.12, red_top + 0.05)),
           Vector((out.x - 0.02, red_front - 0.05, red_top - 0.08)), Vector((out.x - 0.05, red_front - 0.09, red_top * 0.42))]
    p.append(_strip(_catmull(pts, 4), 0.26, 0.035, RIBBON, "ribbon", notch=0.12))
    # a little sock tucked into the top book's pages: its leg flops over the front, the foot points right
    m5, i5 = mats[-1], infos[-1]
    zs = (i5["pages_z"][0] + i5["pages_z"][1]) / 2
    xs = -0.5
    s0 = m5 @ Vector((-xs, i5["pages_y1"] - 0.55, zs))      # (book 5 is spun 180 degrees)
    s1 = m5 @ Vector((-xs, i5["pages_y1"] + 0.1, zs))
    z5 = sum(b[2] for b in STACK[:4])                          # the top book's underside
    zh = z5 - 1.25                                              # heel height
    # hang just in front of whatever lies below, along the sock's path
    below = [v.co for pc in p for v in pc.mesh.vertices if s1.x - 0.4 < v.co.x < s1.x + 1.0 and zh - 0.3 < v.co.z < z5]
    yf = min(v.y for v in below) - 0.12
    pts = [s0, s1, Vector((s1.x, min(s1.y - 0.12, yf + 0.12), s1.z - 0.3)), Vector((s1.x + 0.02, yf, z5 - 0.6)),
           Vector((s1.x + 0.06, yf, zh)), Vector((s1.x + 0.78, yf - 0.02, zh - 0.06))]
    p.append(_sock(pts, s1.y - 0.05))
    body, outline = K.finish(p, NAME, outline_width=0.065)
    for attr in ("visible_shadow", "visible_diffuse", "visible_glossy", "visible_transmission", "visible_volume_scatter"):
        if hasattr(outline, attr):  # preview only: the hull must not block light (it doesn't in Roblox)
            setattr(outline, attr, False)
    return [body, outline] + K.markers(NAME)
