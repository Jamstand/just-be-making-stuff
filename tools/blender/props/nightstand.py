"""
props/nightstand.py - the Nightstand prop (ReplicatedStorage.MapMeshes.Nightstand). See props/__init__.py for
the conventions every prop follows.

Matches the bedside table in docs/concept/bedroom_keyframe.png (left of the bed, under the globe lamp):
- a thick top slab with chamfered edges that overhangs the body on every side (lit, lighter top faces),
- one wide drawer just under the slab with a chunky rounded-rectangle block handle,
- an open cubby below the drawer (dark inside, lit floor lip), a chunky bottom rail,
- four short, slightly tapered square feet set in from the corners,
- a lived-in cubby: three books standing on the left (the last one leaning), two lying flat on the right
  (cream page edges facing the room) and a blue sock whose foot dangles over the front lip.
Ink lines between parts come from the inverted hull plus dark "gap" plates behind the drawer front and
the handle (the art draws a dark line all the way round both).
The wood uses the bed's warm orange-brown (props/bed.py posts), so the two read as one furniture set.
Proportions are measured from the keyframe (364 px tall there = 7.8 units here, wide-angle stretch taken
out): about as wide as it is tall; Map.luau fits it into 52 x 54 x 52 studs, next to the bed's head end.
The Lamp and the AlarmClock stand on the top, which stays flat and clear. Vertical stack (units, art in
brackets): slab 1.3 (1.32) / strip 0.33 (0.36) / drawer 2.3 (2.28) / rail 0.32 (0.32) / cubby 1.75 (1.68) /
bottom rail 1.05 (1.09) / feet 0.75 (0.75).
"""
import math
import bmesh
import bpy
import sockkit as K
from mathutils import Vector
from sockkit import M, hexcol
from props.common import *  # noqa: F401,F403 - shared colours (read-only)

NAME = "Nightstand"

# colours sampled from the keyframe (lit faces of the nightstand / dressers), nudged toward the bed's posts
# (bed_post #CF703D / #EA9454 / #94482D) so bed and nightstand read as one set; the top stays a little
# darker than the lamp plinth (#DB8240 / #F4B44C) so the lamp still stands out on it
NS_WOOD = hexcol("nightstand_wood", "#C46A3C")      # front / side faces
NS_WOOD_L = hexcol("nightstand_wood_light", "#E28C4A")  # top-facing faces and chamfers (lamp-lit)
NS_WOOD_D = hexcol("nightstand_wood_dark", "#904A2D")   # undersides, shaded patches
NS_CUBBY = hexcol("nightstand_cubby", "#3F1B1B")    # back wall + ceiling of the open shelf (art #2B1215:
#                                                      near black-brown; Roblox has no ambient occlusion)
NS_CUBBY_S = hexcol("nightstand_cubby_side", "#53231E")  # the shelf's inner side walls (art: lit one #5E251E)
NS_CUBBY_F = hexcol("nightstand_cubby_floor", "#8C4430")  # shelf floor (gets a little light)
INK = K.OUTLINE
# cubby dressing: book covers (base, lit top), page edges, the blue sock (body, lit, heel/toe, cuff, rib, inside)
BOOKS = [(hexcol("nightstand_book_red", "#D9473F"), hexcol("nightstand_book_red_top", "#EE6A5C")),
         (hexcol("nightstand_book_teal", "#2FA39B"), hexcol("nightstand_book_teal_top", "#4CC2B8")),
         (hexcol("nightstand_book_yellow", "#F0B83C"), hexcol("nightstand_book_yellow_top", "#FFD463")),
         (hexcol("nightstand_book_blue", "#4A63C4"), hexcol("nightstand_book_blue_top", "#6A82DE")),
         (hexcol("nightstand_book_green", "#5FAE4E"), hexcol("nightstand_book_green_top", "#7CCB69"))]
BOOK_BAND = hexcol("nightstand_book_band", "#FBE7B5")  # gold-ish bands on the spines
PAGES = hexcol("nightstand_pages", "#F6ECD2")
PAGES_D = hexcol("nightstand_pages_dark", "#D9C9A6")
SOCK = tuple(hexcol("nightstand_sock" + k, v) for k, v in (
    ("", "#5FA8EE"), ("_top", "#86C4FA"), ("_patch", "#3A6FCB"), ("_patch_top", "#4E86E0"),
    ("_cuff", "#EEF5FF"), ("_rib", "#C9DCF4"), ("_in", "#1E2F5A")))

# ---- dimensions (units), measured off the keyframe (perspective taken out) ----
H = 7.8            # total height
TOP_W, TOP_D = 7.5, 6.9      # slab: overhangs the body 0.5 all round
TOP_T = 1.3        # slab thickness (art: 0.17 of the height)
BODY_W, BODY_D = 6.5, 5.9
FOOT_H = 0.75
BODY_Z0 = FOOT_H
BODY_Z1 = H - TOP_T + 0.05   # tucked a hair under the slab
FRONT = -BODY_D / 2          # body front plane (y)
DRAWER_W, DRAWER_H, DRAWER_T = 5.3, 2.3, 0.26
DRAWER_Z = BODY_Z1 - 0.38 - DRAWER_H / 2
HOLE_X = 2.57                # cubby opening half width
HOLE_Z1 = DRAWER_Z - DRAWER_H / 2 - 0.32
HOLE_Z0 = BODY_Z0 + 1.05
HOLE_DEPTH = BODY_D - 1.3
FOOT_W = 1.2
HANDLE_BEVEL = 0.17          # drawer handle corner radius (art: ~0.2 of the handle's 0.86 height)
OUTLINE_W = 0.1


def _tone(piece, base, light=NS_WOOD_L, dark=NS_WOOD_D, up=0.6, down=-0.6):
    """2-3 tone wood: faces looking up get the light tone, faces looking down the dark one."""
    pal = []
    for f in piece.mesh.polygons:
        nz = f.normal.z
        pal.append(light if nz > up else (dark if nz < down else base))
    piece.face_pal = pal
    return piece


def _bevelled(bm, name, width, segments, angle_deg=30.0):
    """bmesh -> baked world-space mesh with a bevel modifier on its sharp edges only."""
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    obj = bpy.data.objects.new(name, me)
    K.link(obj)
    mod = obj.modifiers.new("bevel", "BEVEL")
    mod.width = width
    mod.segments = segments
    mod.limit_method = "ANGLE"
    mod.angle_limit = math.radians(angle_deg)
    mod.harden_normals = False
    return K.bake_object(obj)


def _flat_big_faces(piece, min_area):
    """Large flat faces shade flat (no smooth-shading smears); small bevel faces stay smooth."""
    piece.flat_faces = [i for i, f in enumerate(piece.mesh.polygons) if f.area >= min_area]
    return piece


def _chamfer_box(pal, size, loc, chamfer, name, taper=None):
    """A box (optionally narrower at the bottom: taper=(sx, sy)) with flat chamfered edges, flat shaded."""
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    bmesh.ops.scale(bm, vec=Vector(size), verts=bm.verts)
    if taper:
        for v in bm.verts:
            if v.co.z < 0:
                v.co.x *= taper[0]
                v.co.y *= taper[1]
    bmesh.ops.translate(bm, vec=Vector(loc), verts=bm.verts)
    p = K.Piece(_bevelled(bm, name, chamfer, 1), pal, outline=True, smooth=False, name=name)
    return p


def _body():
    """The carcass: one closed block with the cubby recessed into its front, softly bevelled edges."""
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    bmesh.ops.scale(bm, vec=Vector((BODY_W, BODY_D, BODY_Z1 - BODY_Z0)), verts=bm.verts)
    bmesh.ops.translate(bm, vec=Vector((0, 0, (BODY_Z0 + BODY_Z1) / 2)), verts=bm.verts)
    for co, no in (((HOLE_X, 0, 0), (1, 0, 0)), ((-HOLE_X, 0, 0), (1, 0, 0)),
                   ((0, 0, HOLE_Z0), (0, 0, 1)), ((0, 0, HOLE_Z1), (0, 0, 1))):
        geom = bm.verts[:] + bm.edges[:] + bm.faces[:]
        bmesh.ops.bisect_plane(bm, geom=geom, plane_co=co, plane_no=no)
    bm.normal_update()
    front = [f for f in bm.faces if f.normal.y < -0.9 and abs(f.calc_center_median().x) < HOLE_X
             and HOLE_Z0 < f.calc_center_median().z < HOLE_Z1]
    ret = bmesh.ops.extrude_face_region(bm, geom=front)
    verts = [e for e in ret["geom"] if isinstance(e, bmesh.types.BMVert)]
    bmesh.ops.translate(bm, vec=Vector((0, HOLE_DEPTH, 0)), verts=verts)
    bmesh.ops.delete(bm, geom=[f for f in front if f.is_valid], context="FACES")
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = _bevelled(bm, "ns_body", 0.16, 2)
    pal = []
    for f in me.polygons:
        c, n = f.center, f.normal
        inside = (FRONT + 0.06 < c.y < FRONT + HOLE_DEPTH + 0.05 and abs(c.x) < HOLE_X + 0.01
                  and HOLE_Z0 - 0.01 < c.z < HOLE_Z1 + 0.01)
        if inside:
            # 3 tones read as depth without ray-traced shadow: lit floor, mid side walls, near-black back
            pal.append(NS_CUBBY_F if n.z > 0.6 else (NS_CUBBY_S if abs(n.x) > 0.6 else NS_CUBBY))
        elif n.z > 0.6:
            pal.append(NS_WOOD_L)
        elif n.z < -0.6:
            pal.append(NS_WOOD_D)
        else:
            pal.append(NS_WOOD)
    p = K.Piece(me, pal, outline=True, smooth=True, name="body")
    return _flat_big_faces(p, 0.5)


def _plate(size, loc, name):
    """A dark slab just proud of a face, a little bigger than the part in front of it: reads as the ink
    line drawn round a drawer front / handle from every angle."""
    return K.Piece(K.rounded_box(INK, size, M(loc), bevel=0.04, segments=1).mesh, INK, outline=False,
                   smooth=False, name=name)


def _round_plate(size, loc, radius, name, segments=3):
    """Like _plate, but with its four front-view corners rounded (radius) so the ink margin follows a
    rounded part (the drawer handle) instead of poking out as square dark corners."""
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    bmesh.ops.scale(bm, vec=Vector(size), verts=bm.verts)
    corners = [e for e in bm.edges if abs((e.verts[0].co - e.verts[1].co).normalized().y) > 0.9]
    bmesh.ops.bevel(bm, geom=corners, offset=radius, offset_type="OFFSET", segments=segments,
                    profile=0.5, affect="EDGES")
    bmesh.ops.translate(bm, vec=Vector(loc), verts=bm.verts)
    return K.Piece(K._bm_to_mesh(bm, name), INK, outline=False, smooth=False, name=name)


def _book(pal, top_pal, size, loc, rot=(0, 0, 0), name="book"):
    """a standing book, spine to the front (-Y): a softly rounded cover block with two light bands across
    the spine (thin plates, no outline - painted on)"""
    w, d, h = size
    cover = K.rounded_box(pal, size, M(loc, rot), bevel=0.07, segments=1, name=name)
    _tone(cover, pal, top_pal, pal, up=0.6, down=-2)
    out = [cover]
    mat = M(loc, rot)
    for bz in (h * 0.3, -h * 0.3):
        bm = bmesh.new()
        bmesh.ops.create_cube(bm, size=1.0)
        bmesh.ops.transform(bm, matrix=mat @ M((0, -d / 2 - 0.005, bz), scale=(w * 0.86, 0.04, 0.07)), verts=bm.verts)
        out.append(K.Piece(K._bm_to_mesh(bm, "book_band"), BOOK_BAND, outline=False, smooth=False, name="book_band"))
    return out


def _flat_book(pal, top_pal, size, loc, rot_z=0.0, name="flatbook"):
    """a book lying flat, its cream page edges toward the room: top and bottom boards, the spine at the
    back, the page block between them (set back a little from the board edges)"""
    w, d, t = size
    mat = M(loc, (0, 0, rot_z))
    board = 0.07
    out = []
    for z in (-t / 2 + board / 2, t / 2 - board / 2):
        b = K.rounded_box(pal, (w, d, board), mat @ M((0, 0, z)), bevel=0.03, segments=1, name=name)
        out.append(_tone(b, pal, top_pal, pal, up=0.6, down=-2))
    spine = K.rounded_box(pal, (w, board * 1.6, t), mat @ M((0, d / 2 - board * 0.8, 0)), bevel=0.04, segments=1,
                          name=name)
    out.append(_tone(spine, pal, top_pal, pal, up=0.6, down=-2))
    pages = K.rounded_box(PAGES, (w - 0.1, d - 0.08, t - 2 * board + 0.02), mat @ M((0, -0.01, 0)), bevel=0.02,
                          segments=1, name=name + "_pages")
    out.append(_tone(pages, PAGES, PAGES, PAGES_D, up=0.6, down=-0.6))
    return out


def _catmull(pts, n_per):
    """centripetal-free Catmull-Rom through the points (3D), n_per samples per span, end point included"""
    P = [Vector(pts[0])] + [Vector(q) for q in pts] + [Vector(pts[-1])]
    out = []
    for i in range(1, len(P) - 2):
        p0, p1, p2, p3 = P[i - 1], P[i], P[i + 1], P[i + 2]
        for k in range(n_per):
            t = k / n_per
            out.append(0.5 * (2 * p1 + (p2 - p0) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t
                              + (3 * p1 - p0 - 3 * p2 + p3) * t ** 3))
    out.append(Vector(pts[-1]))
    return out


def _sock(cols, pts, nrm_fn, r=0.3, flat=0.55, seg=8, heel=(0.45, 0.62), name="sock"):
    """a soft sock tube swept along `pts` (cuff opening first, toe last), squashed to `flat` along the
    surface normal nrm_fn(i, n) -> Vector it lies on / hangs against: a recessed dark opening, a ribbed light
    cuff band, a heel patch (the outside of the bend between the `heel` fractions of its length) and a
    round toe patch"""
    body, body_t, patch, patch_t, cuff, rib, inner = cols
    cs = _catmull(pts, 4)
    n = len(cs)
    lens = [0.0]
    for i in range(1, n):
        lens.append(lens[-1] + (cs[i] - cs[i - 1]).length)
    total = lens[-1]
    bm = bmesh.new()
    rings, fr, offs, outs = [], [], [], []
    for i, c in enumerate(cs):
        t = (cs[min(i + 1, n - 1)] - cs[max(i - 1, 0)]).normalized()
        nv = nrm_fn(i, n)
        side = t.cross(nv).normalized()
        nv = side.cross(t).normalized()
        f = lens[i] / total
        k = 1.0
        toe = 1 - (total - lens[i]) / (r * 1.6) if total - lens[i] < r * 1.6 else 0.0
        if toe > 0:  # the round toe: the last 1.6 r shrinks along a quarter circle
            k = math.sqrt(max(0.0, 1 - toe * toe))
        if i == n - 1:
            rings.append([bm.verts.new(c)] * seg)  # the toe tip: one vertex (the last span becomes a fan)
        else:
            rings.append([bm.verts.new(c + side * (r * k * math.cos(a)) + nv * (r * k * flat * math.sin(a)))
                          for a in (j / seg * math.tau for j in range(seg))])
        fr.append(f)
        # the bend's outside (away from the curvature) - where the heel patch goes
        kv = cs[min(i + 1, n - 1)] - 2 * c + cs[max(i - 1, 0)]
        outs.append(-kv.normalized() if kv.length > 1e-6 else Vector((0, 0, 0)))
        offs.append((side.copy(), nv.copy()))
    pals = []
    for i in range(n - 1):
        fm = (fr[i] + fr[i + 1]) / 2
        for j in range(seg):
            jj = (j + 1) % seg
            if i == n - 2:
                bm.faces.new((rings[i][j], rings[i][jj], rings[i + 1][0]))
            else:
                bm.faces.new((rings[i][j], rings[i][jj], rings[i + 1][jj], rings[i + 1][j]))
            am = (j + 0.5) / seg * math.tau
            sd, nv = offs[i]
            off = sd * math.cos(am) + nv * math.sin(am)
            up = off.z > 0.5 or math.sin(am) > 0.5
            if lens[i] < 0.42:
                pals.append(cuff if j % 2 == 0 else rib)
            elif fm > 1 - 0.55 / total:
                pals.append(patch_t if up else patch)
            elif heel[0] < fm < heel[1] and off.dot(outs[i] + outs[i + 1]) > 0.5:
                pals.append(patch_t if up else patch)
            else:
                pals.append(body_t if up else body)
    # opening: a dark dip at the cuff end
    t0 = (cs[1] - cs[0]).normalized()
    ctr = bm.verts.new(cs[0] + t0 * 0.12)
    for j in range(seg):
        bm.faces.new((rings[0][(j + 1) % seg], rings[0][j], ctr))
        pals.append(inner)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)  # closed shell: in-place flips keep the face order
    return K.Piece(K._bm_to_mesh(bm, name), pals, True, True, name)


def _cubby_dressing():
    """books and a sock in the open shelf, kept near its front so they read from the room"""
    p = []
    floor = HOLE_Z0
    yb = FRONT + 0.25 + 0.55  # book centre depth: spines ~0.25 inside the opening
    x = -HOLE_X + 0.12
    for (pal, top), (w, h) in zip(BOOKS[:2], ((0.42, 1.48), (0.34, 1.32))):
        p += _book(pal, top, (w, 1.1, h), (x + w / 2, yb, floor + h / 2))
        x += w + 0.03
    # the third one leans on its neighbours
    w, h, lean = 0.38, 1.4, math.radians(17)
    cx = x + w / 2 * math.cos(lean) + h / 2 * math.sin(lean)
    p += _book(BOOKS[2][0], BOOKS[2][1], (w, 1.1, h), (cx, yb, floor + h / 2 * math.cos(lean) + w / 2 * math.sin(lean) - 0.04),
               rot=(0, lean, 0))
    # two lying flat on the right
    p += _flat_book(BOOKS[3][0], BOOKS[3][1], (1.55, 1.15, 0.34), (HOLE_X - 0.95, yb + 0.05, floor + 0.17), 0.05)
    p += _flat_book(BOOKS[4][0], BOOKS[4][1], (1.3, 1.0, 0.28), (HOLE_X - 1.0, yb + 0.02, floor + 0.34 + 0.14), -0.12)
    # a blue sock: its cuff lies on the shelf floor, the leg hangs over the front lip and the foot kicks
    # out sideways at the bottom - the classic sock "L" seen from the room
    r, fl = 0.33, 0.55
    zf = floor + r * fl
    hy = FRONT - r * fl - 0.02  # hanging against the bottom rail
    pts = [(-0.55, FRONT + 0.95, zf), (-0.42, FRONT + 0.25, zf), (-0.35, hy + 0.05, floor - 0.2),
           (-0.33, hy, floor - 0.75), (-0.2, hy, floor - 1.2), (0.25, hy, floor - 1.38), (0.8, hy, floor - 1.32)]

    def nrm(i, n):  # lies on the floor (normal +Z), then hangs against the bottom rail (normal -Y)
        u = min(1.0, max(0.0, (i / (n - 1) - 0.12) / 0.2))
        return Vector((0, -u, 1 - u)).normalized()
    p.append(_sock(SOCK, pts, nrm, r=r, flat=fl, heel=(0.6, 0.8)))
    return p


def build():
    p = []
    # top slab: chamfered all round, lit top + chamfer, dark underside
    slab = _chamfer_box(NS_WOOD, (TOP_W, TOP_D, TOP_T), (0, 0, H - TOP_T / 2), 0.24, "top")
    p.append(_tone(slab, NS_WOOD))
    # carcass with the cubby
    p.append(_body())
    # drawer: dark gap plate, the front, the block handle (with its own gap plate). Each plate stands only
    # ~0.035 proud and the part in front sits on it, so from any angle just an even ink margin shows round
    # the drawer / handle - about the weight of the silhouette ink, like the art's single line.
    gap = 0.06
    plate_y = FRONT + 0.015  # 0.1 thick: front face 0.035 proud of the body
    p.append(_plate((DRAWER_W + 2 * gap, 0.1, DRAWER_H + 2 * gap), (0, plate_y, DRAWER_Z), "drawer_gap"))
    drawer_y = FRONT - 0.03 - DRAWER_T / 2
    drawer = K.rounded_box(NS_WOOD, (DRAWER_W, DRAWER_T, DRAWER_H), M((0, drawer_y, DRAWER_Z)),
                           bevel=0.12, segments=2, name="drawer")
    p.append(_flat_big_faces(_tone(drawer, NS_WOOD), 0.4))
    hw, hh, ht = 1.55, 0.86, 0.5
    face_y = drawer_y - DRAWER_T / 2
    p.append(_round_plate((hw + 0.12, 0.1, hh + 0.12), (0, face_y + 0.015, DRAWER_Z), HANDLE_BEVEL + 0.06,
                          "handle_gap"))
    # a rounded-rectangle block like the art's (and the dressers'): soft corners about 0.2 of its height,
    # a rounded, lit top edge; the big front / top faces stay flat shaded
    handle = K.rounded_box(NS_WOOD, (hw, ht, hh), M((0, face_y - 0.03 - ht / 2, DRAWER_Z)),
                           bevel=HANDLE_BEVEL, segments=3, name="handle")
    p.append(_flat_big_faces(_tone(handle, NS_WOOD), 0.15))
    # feet: short, square, a touch narrower at the floor, set in from the corners
    fx, fy = BODY_W / 2 - 0.2 - FOOT_W / 2, BODY_D / 2 - 0.2 - FOOT_W / 2
    for x in (-fx, fx):
        for y in (-fy, fy):
            foot = _chamfer_box(NS_WOOD, (FOOT_W, FOOT_W, FOOT_H + 0.1), (x, y, (FOOT_H + 0.1) / 2), 0.12, "foot",
                                taper=(0.84, 0.84))
            p.append(_tone(foot, NS_WOOD))
    p += _cubby_dressing()
    body, outline = K.finish(p, NAME, outline_width=OUTLINE_W)
    _camera_only(outline)
    return [body, outline] + K.markers(NAME)


def _camera_only(outline):
    """Cycles-only flags (no effect on the GLB / the game): in the preview renders the inverted hull
    otherwise blocks all bounce and sky light from the body it wraps, turning shaded areas black.
    Roblox doesn't ray-trace ambient light, so this is closer to how the game shows the prop."""
    outline.visible_diffuse = False
    outline.visible_glossy = False
    outline.visible_transmission = False
