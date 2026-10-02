"""
props/wardrobe.py - the Wardrobe prop (ReplicatedStorage.MapMeshes.Wardrobe): a tall two-door wardrobe that
stands against a wall of the bedroom. See props/__init__.py for the conventions every prop follows.

Same furniture language as the dresser / nightstand / bed (docs/concept/bedroom_keyframe.png): warm
orange-brown wood in 2-3 flat tones (lit top faces, darker undersides), flat 45-degree chamfers, chunky
chamfered block handles and dark ink plates behind every door / drawer / panel (the inverted hull only
draws silhouettes, so a door seen head-on needs its own ink line).
- crown: a fat rounded cornice, a chamfered top slab and an arched crest (like the bed's arched panels) with a
  raised panel and a chunky yellow moon and star on it;
- two tall doors with raised panels (an arched one above, a square one below) and tall block handles;
  the right door stands ajar (20 degrees) on its hinge, showing the dark inside: a hanging rail with a
  red / cream striped shirt (one sleeve flopped out through the gap), a little teal hoodie and a yellow
  raincoat on wooden hangers;
- a deep drawer at the bottom (two block handles) with a sock caught in it, its foot dangling down the front;
- a green sock draped over the top of the ajar door; short tapered block feet; raised panels on the sides;
- on top: a pink striped hat box with a ribbon and a blue baseball cap sitting on its lid (left), two stacked
  board-game boxes (right).

Units: 1 unit = 10 studs. Map.luau fits the prop into 180 x 300 x 95 studs (W x H x D), so the whole thing -
crown, ajar door and the things on top included - is 18.0 x 30.0 x 9.4 units. The back is flat (it stands
against a wall). Origin = floor centre of the carcass, front faces -Y.

Shared helpers (`tone`, `chamfer_box`, `prism`, `lathe`, `shape`, `plate`, ...) are also used by
props/desk.py and props/deskchair.py, so the three pieces read as one furniture set.
"""
import math
import bmesh
import bpy
from mathutils import Matrix, Vector
import sockkit as K
from sockkit import M, hexcol
from props.dresser import sock, sweep

NAME = "Wardrobe"

# texture classes for tools/blender/texturing.py where the colour names alone guess wrong
MATERIALS = {"wardrobe_game": "paper", "wardrobe_rail": "metal", "wardrobe_coat_button": "plastic"}

# ---- colours: the dresser's wood (sampled from the concept's dressers), its own names
WOOD = hexcol("wardrobe_wood", "#C4633A")          # fronts, sides
WOOD_L = hexcol("wardrobe_wood_light", "#E8914A")  # top-facing faces and top chamfers
WOOD_D = hexcol("wardrobe_wood_dark", "#8A3E2A")   # undersides, bottom chamfers
PANEL = hexcol("wardrobe_panel", "#B2552F")        # raised door / side panels: a touch deeper than the frame
IN_BACK = hexcol("wardrobe_inside", "#3A1719")     # inside: back wall + ceiling
IN_SIDE = hexcol("wardrobe_inside_side", "#55231F")  # inside side walls
IN_FLOOR = hexcol("wardrobe_inside_floor", "#7E3B2B")  # inside floor (gets a little light)
DOOR_IN = hexcol("wardrobe_door_inside", "#9C4A2E")  # inside face of the ajar door (in its own shadow)
INK = K.OUTLINE
MOON = hexcol("wardrobe_moon", "#FFD95A")
MOON_D = hexcol("wardrobe_moon_dark", "#E8B53A")
HANGER = hexcol("wardrobe_hanger", "#EBB56E")
HANGER_D = hexcol("wardrobe_hanger_dark", "#C28A48")
RAIL = hexcol("wardrobe_rail", "#D8C49A")
# clothes
SHIRT_R = hexcol("wardrobe_shirt_red", "#E0483F")
SHIRT_RD = hexcol("wardrobe_shirt_red_dark", "#B8323A")
SHIRT_W = hexcol("wardrobe_shirt_cream", "#FFF0D8")
SHIRT_WD = hexcol("wardrobe_shirt_cream_dark", "#E3CDB4")
HOOD = hexcol("wardrobe_hoodie", "#2FA8A0")
HOOD_L = hexcol("wardrobe_hoodie_light", "#4FC6BA")
HOOD_D = hexcol("wardrobe_hoodie_dark", "#1F7D7A")
HOOD_IN = hexcol("wardrobe_hoodie_lining", "#F2C14E")
CORD = hexcol("wardrobe_hoodie_cord", "#FFF4DC")
COAT = hexcol("wardrobe_coat", "#F5C33B")
COAT_D = hexcol("wardrobe_coat_dark", "#D99A26")
BUTTON = hexcol("wardrobe_coat_button", "#3F5BB0")
# socks (body, accent, inner)
SK_GRN = hexcol("wardrobe_sock_green", "#6CCB5A")
SK_GRN_D = hexcol("wardrobe_sock_green_dark", "#3F9A44")
SK_GRN_S = hexcol("wardrobe_sock_green_stripe", "#FFF0D8")
SK_PUR = hexcol("wardrobe_sock_purple", "#B88AE6")
SK_PUR_D = hexcol("wardrobe_sock_purple_dark", "#8455C4")
SK_IN = hexcol("wardrobe_sock_inner", "#3A2F4E")
# top: hat box and cap
BOX = hexcol("wardrobe_hatbox", "#F49AB8")
BOX_L = hexcol("wardrobe_hatbox_light", "#FFC0D4")
BOX_D = hexcol("wardrobe_hatbox_dark", "#D2708F")
BOX_S = hexcol("wardrobe_hatbox_stripe", "#FFF4E6")
RIBBON = hexcol("wardrobe_ribbon", "#7A5CD6")
CAP = hexcol("wardrobe_cap", "#3E6FD0")
CAP_L = hexcol("wardrobe_cap_light", "#5F8DEA")
CAP_D = hexcol("wardrobe_cap_dark", "#2C4F9E")
CAP_B = hexcol("wardrobe_cap_button", "#FFD24A")
GAME_G = hexcol("wardrobe_game_green", "#5DB24F")
GAME_G_L = hexcol("wardrobe_game_green_light", "#7ECB61")
GAME_G_D = hexcol("wardrobe_game_green_dark", "#3E8C3D")
GAME_R = hexcol("wardrobe_game_red", "#D9473F")
GAME_R_L = hexcol("wardrobe_game_red_light", "#F06A58")
GAME_R_D = hexcol("wardrobe_game_red_dark", "#A8302E")
GAME_BAND = hexcol("wardrobe_game_band", "#FFF0D0")

# ---- dimensions (units)
TOP_Z1 = 27.65                  # top of the crown slab (the crest and the hat box reach 30)
TOP_W, TOP_T = 18.0, 0.7
BODY_W = 16.4
BY0, BY1 = -2.95, 2.95          # carcass front / back
FOOT_H = 0.7
BODY_Z0, BODY_Z1 = FOOT_H, 26.0
STILE = 0.45                    # frame width left / right of the doors
ROW_W = BODY_W - 2 * STILE      # 15.5
DRAWER_Z0, DRAWER_Z1 = 1.45, 4.95
DOOR_Z0, DOOR_Z1 = 5.4, 24.85
DOOR_GAP = 0.12
DW = (ROW_W - DOOR_GAP) / 2     # door width
DT = 0.45                       # door thickness
FB = 0.2                        # door / drawer front chamfer
GAP = 0.07                      # ink margin round a door / drawer front
AJAR = math.radians(20)         # the right door's opening angle
HINGE = Vector((DOOR_GAP / 2 + DW, BY0 - 0.04, 0))  # the right door's hinge line (its back outer edge)
CAV_X0, CAV_X1 = DOOR_GAP / 2 + 0.12, ROW_W / 2 - 0.1   # the cavity behind the right door
CAV_Z0, CAV_Z1 = DOOR_Z0 + 0.12, DOOR_Z1 - 0.12
CAV_Y1 = BY1 - 0.45
OUTLINE_W = 0.16                # ~the dresser's ink weight (0.14): same 10 studs/unit scale


# ---------------------------------------------------------------- shared helpers (desk / chair use them too)
def tone(piece, base, light, dark, up=0.6, down=-0.6):
    """2-3 tone paint: faces looking up get the light tone, faces looking down the dark one."""
    piece.face_pal = [light if f.normal.z > up else (dark if f.normal.z < down else base) for f in piece.mesh.polygons]
    return piece


def flat(piece):
    piece.smooth = False
    return piece


def flat_big_faces(piece, min_area):
    """Large flat faces shade flat (no smooth-shading smears); small bevel faces stay smooth."""
    piece.flat_faces = [i for i, f in enumerate(piece.mesh.polygons) if f.area >= min_area]
    return piece


def bevel_bake(bm, name, width, segments=1, angle=30.0, mat=None):
    """bmesh -> world-space mesh with a bevel modifier on its sharp edges (angle limit)."""
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    obj = bpy.data.objects.new(name, me)
    K.link(obj)
    if mat is not None:
        obj.matrix_world = mat
    if width > 0:
        mod = obj.modifiers.new("bevel", "BEVEL")
        mod.width = width
        mod.segments = segments
        mod.limit_method = "ANGLE"
        mod.angle_limit = math.radians(angle)
        mod.harden_normals = False
    return K.bake_object(obj)


def chamfer_box(pal, size, mat, chamfer, name="box", taper=None, segments=1, outline=True):
    """A box (optionally narrower at the bottom: taper=(sx, sy)) with flat 45-degree chamfers, flat shaded."""
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    bmesh.ops.scale(bm, vec=Vector(size), verts=bm.verts)
    if taper:
        for v in bm.verts:
            if v.co.z < 0:
                v.co.x *= taper[0]
                v.co.y *= taper[1]
    return K.Piece(bevel_bake(bm, name, chamfer, segments, mat=mat), pal, outline=outline, smooth=False, name=name)


def prism(pal, pts, depth, mat, chamfer, name="prism", segments=1, outline=True):
    """A 2D outline pts [(x, z)] extruded `depth` along Y (centred on y = 0), chamfered round its front and
    back faces, then placed by `mat`. Used for arched panels and their ink plates."""
    bm = bmesh.new()
    front = [bm.verts.new((x, -depth / 2, z)) for x, z in pts]
    back = [bm.verts.new((x, depth / 2, z)) for x, z in pts]
    bm.faces.new(front)
    bm.faces.new(back)
    n = len(pts)
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((front[i], front[j], back[j], back[i]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return K.Piece(bevel_bake(bm, name, chamfer, segments, mat=mat), pal, outline=outline, smooth=False, name=name)


def outward(bm):
    """recalc normals, then make sure the closed shell faces OUT (signed volume > 0)."""
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    vol = 0.0
    for f in bm.faces:
        v = [lp.vert.co for lp in f.loops]
        for k in range(1, len(v) - 1):
            vol += v[0].dot(v[k].cross(v[k + 1]))
    if vol < 0:
        bmesh.ops.reverse_faces(bm, faces=bm.faces)


def lathe(pal, profile, mat, seg=16, name="lathe", outline=True):
    """Surface of revolution round the local Z axis: profile = [(radius, z)] bottom to top; r == 0 at an end
    closes it with a pole. Placed by `mat`. Smooth shaded."""
    bm = bmesh.new()
    pts = list(profile)
    bot = top = None
    if pts[0][0] == 0:
        bot = bm.verts.new((0, 0, pts[0][1]))
        pts = pts[1:]
    if pts[-1][0] == 0:
        top = bm.verts.new((0, 0, pts[-1][1]))
        pts = pts[:-1]
    rings = [[bm.verts.new((r * math.cos(i / seg * math.tau), r * math.sin(i / seg * math.tau), z)) for i in range(seg)]
             for r, z in pts]
    for a, b in zip(rings, rings[1:]):
        for i in range(seg):
            j = (i + 1) % seg
            bm.faces.new((a[i], a[j], b[j], b[i]))
    if bot is not None:
        for i in range(seg):
            bm.faces.new((bot, rings[0][(i + 1) % seg], rings[0][i]))
    else:
        bm.faces.new(list(reversed(rings[0])))
    if top is not None:
        for i in range(seg):
            bm.faces.new((top, rings[-1][i], rings[-1][(i + 1) % seg]))
    else:
        bm.faces.new(rings[-1])
    outward(bm)
    bmesh.ops.transform(bm, matrix=mat, verts=bm.verts)
    p = K.Piece(K._bm_to_mesh(bm, name), pal, outline, True, name)
    p.flat_faces = [i for i, f in enumerate(p.mesh.polygons) if len(f.vertices) > 4]
    return p


def shape(pal, loops, thick, bevel, mat, name="shape", bevel_res=2, outline=True):
    """Soft slab from 2D outlines in local XY (first loop = outline, more loops = holes), `thick` thick along
    local Z with round edges of radius `bevel` - a filled 2D curve. NB the bevel grows the outline (and shrinks
    the holes) by `bevel`. Placed by `mat`; welded, smooth shaded."""
    cu = bpy.data.curves.new(name, "CURVE")
    cu.dimensions = "2D"
    cu.fill_mode = "BOTH"
    cu.extrude = max(0.0, thick / 2 - bevel)
    cu.bevel_depth = bevel
    cu.bevel_resolution = bevel_res
    for loop in loops:
        sp = cu.splines.new("POLY")
        sp.points.add(len(loop) - 1)
        for i, (x, y) in enumerate(loop):
            sp.points[i].co = (x, y, 0, 1)
        sp.use_cyclic_u = True
    obj = bpy.data.objects.new(name, cu)
    K.link(obj)
    obj.matrix_world = mat
    me = K.bake_object(obj)
    bm = bmesh.new()
    bm.from_mesh(me)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-4)
    outward(bm)
    bm.to_mesh(me)
    bm.free()
    p = K.Piece(me, pal, outline, True, name)
    return p


def slice_mesh(piece, axis, cuts):
    """Cuts the piece's mesh with planes normal to `axis` (a Vector) at the given offsets, so bands can be
    painted with clean straight edges. Resets face_pal to the first colour (repaint afterwards)."""
    bm = bmesh.new()
    bm.from_mesh(piece.mesh)
    n = Vector(axis).normalized()
    for c in cuts:
        geom = bm.verts[:] + bm.edges[:] + bm.faces[:]
        bmesh.ops.bisect_plane(bm, geom=geom, plane_co=n * c, plane_no=n)
    bm.to_mesh(piece.mesh)
    bm.free()
    piece.face_pal = [piece.face_pal[0]] * len(piece.mesh.polygons)
    piece.flat_faces = []
    return piece


def plate(size, mat, pal=INK, name="gap"):
    """A dark slab just proud of a face, a little bigger than the part in front of it: the ink line drawn round
    a door / drawer front / handle, seen from every angle."""
    return chamfer_box(pal, size, mat, 0.0, name=name, outline=False)


def transform(pieces, mat):
    for p in pieces:
        p.mesh.transform(mat)
        p.mesh.update()
    return pieces


def no_bounce(outline):
    """Preview only (Cycles ray flags, not exported): the inverted hull must not block bounce light."""
    outline.visible_diffuse = False
    outline.visible_glossy = False
    outline.visible_transmission = False


def arch_pts(w, h, rise, n=10):
    """Outline (x, z) of a panel w wide, h tall (bottom at z = 0) whose top is an elliptical arch `rise` high."""
    pts = [(-w / 2, 0.0), (w / 2, 0.0)]
    for i in range(n + 1):
        a = i / n * math.pi
        pts.append((w / 2 * math.cos(a), h - rise + rise * math.sin(a)))
    return pts


def round_rect_pts(w, h, r, n=4):
    """Outline (x, z) of a rounded rectangle centred on the origin."""
    pts = []
    for cx, cz, a0 in ((w / 2 - r, -h / 2 + r, -90), (w / 2 - r, h / 2 - r, 0), (-w / 2 + r, h / 2 - r, 90),
                       (-w / 2 + r, -h / 2 + r, 180)):
        for i in range(n + 1):
            a = math.radians(a0 + 90 * i / n)
            pts.append((cx + r * math.cos(a), cz + r * math.sin(a)))
    return pts


# ---------------------------------------------------------------- wardrobe parts
def _body():
    """The carcass: one block with the cavity behind the right door recessed into its front."""
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    bmesh.ops.scale(bm, vec=Vector((BODY_W, BY1 - BY0, BODY_Z1 - BODY_Z0)), verts=bm.verts)
    bmesh.ops.translate(bm, vec=Vector((0, (BY0 + BY1) / 2, (BODY_Z0 + BODY_Z1) / 2)), verts=bm.verts)
    for co, no in (((CAV_X0, 0, 0), (1, 0, 0)), ((CAV_X1, 0, 0), (1, 0, 0)),
                   ((0, 0, CAV_Z0), (0, 0, 1)), ((0, 0, CAV_Z1), (0, 0, 1))):
        geom = bm.verts[:] + bm.edges[:] + bm.faces[:]
        bmesh.ops.bisect_plane(bm, geom=geom, plane_co=co, plane_no=no)
    bm.normal_update()
    front = [f for f in bm.faces if f.normal.y < -0.9 and CAV_X0 < f.calc_center_median().x < CAV_X1
             and CAV_Z0 < f.calc_center_median().z < CAV_Z1]
    ret = bmesh.ops.extrude_face_region(bm, geom=front)
    verts = [e for e in ret["geom"] if isinstance(e, bmesh.types.BMVert)]
    bmesh.ops.translate(bm, vec=Vector((0, CAV_Y1 - BY0, 0)), verts=verts)
    bmesh.ops.delete(bm, geom=[f for f in front if f.is_valid], context="FACES")
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bevel_bake(bm, "wardrobe_body", 0.16, 2)
    pal = []
    for f in me.polygons:
        c, n = f.center, f.normal
        inside = (BY0 + 0.05 < c.y < CAV_Y1 + 0.05 and CAV_X0 - 0.01 < c.x < CAV_X1 + 0.01
                  and CAV_Z0 - 0.01 < c.z < CAV_Z1 + 0.01)
        if inside:
            pal.append(IN_FLOOR if n.z > 0.6 else (IN_SIDE if abs(n.x) > 0.6 else IN_BACK))
        elif n.z > 0.6:
            pal.append(WOOD_L)
        elif n.z < -0.6:
            pal.append(WOOD_D)
        else:
            pal.append(WOOD)
    return flat_big_faces(K.Piece(me, pal, outline=True, smooth=True, name="body"), 0.5)


CREST_W, CREST_RISE, CREST_T = 8.4, 2.35, 0.55   # the arched crest on the crown (its top lands on 30)


def _crown():
    """A fat rounded cornice, the chamfered top slab and an arched crest with a yellow moon and star."""
    out = []
    z0 = BODY_Z1 - 0.12
    corn_h = TOP_Z1 - TOP_T + 0.05 - z0
    corn = K.rounded_box(WOOD, (BODY_W + 0.9, BY1 - BY0 + 0.45, corn_h),
                         M((0, (BY0 + BY1) / 2 - 0.22, z0 + corn_h / 2)), bevel=0.48, segments=3, name="cornice")
    out.append(tone(corn, WOOD, WOOD_L, WOOD_D, up=0.75, down=-0.75))
    slab = chamfer_box(WOOD, (TOP_W, BY1 - BY0 + 0.75, TOP_T),
                       M((0, (BY0 + BY1) / 2 - 0.37, TOP_Z1 - TOP_T / 2)), 0.22, name="top")
    out.append(tone(slab, WOOD, WOOD_L, WOOD_D))
    # the crest: an arched board standing on the slab's front edge (like the bed's arched panels)
    yc = BY0 - 0.1
    pts = [(-CREST_W / 2, 0.0), (CREST_W / 2, 0.0)]
    n = 12
    for i in range(n + 1):
        a = i / n * math.pi
        # a low shoulder at each end rising into the arch
        pts.append((CREST_W / 2 * math.cos(a), 0.45 + (CREST_RISE - 0.45) * math.sin(a) ** 0.8))
    crest = prism(WOOD, pts, CREST_T, M((0, yc, TOP_Z1 - 0.05)), 0.16, name="crest")
    out.append(tone(crest, WOOD, WOOD_L, WOOD_D, up=0.35, down=-0.5))
    # a raised arched panel on its front in the panel tone, with its ink plate
    yf = yc - CREST_T / 2
    inner = arch_pts(CREST_W - 1.6, CREST_RISE - 0.75, CREST_RISE - 1.15, n=10)
    ink = [(x * (CREST_W - 1.44) / (CREST_W - 1.6), z * (CREST_RISE - 0.59) / (CREST_RISE - 0.75) - 0.08) for x, z in inner]
    out.append(prism(INK, ink, 0.06, M((0, yf + 0.0, TOP_Z1 + 0.33)), 0.0, name="crest_gap", outline=False))
    pnl = prism(PANEL, inner, 0.14, M((0, yf - 0.05, TOP_Z1 + 0.33)), 0.06, name="crest_panel", outline=False)
    out.append(tone(pnl, PANEL, WOOD_L, WOOD_D, up=0.35, down=-0.5))
    # the moon and the star: chunky yellow cut-outs on the panel
    rot = Matrix.Rotation(math.pi / 2, 4, "X")
    ym = yf - 0.2
    zm = TOP_Z1 + 0.33 + (CREST_RISE - 0.75) * 0.47
    # crescent: the outer circle's arc between the two tips, back along an inner circle through both tips
    pts = []
    for i in range(11):
        a = math.radians(60 + 240 * i / 10)
        pts.append((0.6 * math.cos(a), 0.6 * math.sin(a)))
    for i in range(1, 8):
        a = math.radians(270 - 180 * i / 8)
        pts.append((0.3 + 0.52 * math.cos(a), 0.52 * math.sin(a)))
    tilt = math.radians(-25)
    pts = [(x * math.cos(tilt) - z * math.sin(tilt), x * math.sin(tilt) + z * math.cos(tilt)) for x, z in pts]
    moon = shape(MOON, [pts], 0.2, 0.06, Matrix.Translation((-0.7, ym, zm)) @ rot, name="moon", bevel_res=1)
    out.append(tone(moon, MOON, MOON, MOON_D, down=-0.5))
    star = []
    for i in range(10):
        a = math.pi / 2 + i / 10 * math.tau
        r = 0.55 if i % 2 == 0 else 0.25
        star.append((r * math.cos(a), r * math.sin(a)))
    st = shape(MOON, [star], 0.2, 0.06, Matrix.Translation((0.8, ym, zm + 0.08)) @ rot, name="star", bevel_res=1)
    out.append(tone(st, MOON, MOON, MOON_D, down=-0.5))
    return out


def _handle_v(x, zc, y_face, h=2.3):
    """Tall chunky chamfered block handle on a door face at y_face, with its ink plate."""
    hw, hd = 0.72, 0.5
    out = [plate((hw + 0.14, 0.08, h + 0.14), M((x, y_face - 0.02, zc)), name="handle_gap")]
    out.append(tone(chamfer_box(WOOD, (hw, hd + 0.06, h), M((x, y_face - 0.04 - hd / 2, zc)), 0.17, "handle"),
                    WOOD, WOOD_L, WOOD_D))
    return out


def _handle_h(x, zc, y_face):
    """Wide chunky chamfered block handle (the drawer's), with its ink plate."""
    hw, hh, hd = 1.75, 0.78, 0.5
    out = [plate((hw + 0.14, 0.08, hh + 0.14), M((x, y_face - 0.02, zc)), name="handle_gap")]
    out.append(tone(chamfer_box(WOOD, (hw, hd + 0.06, hh), M((x, y_face - 0.04 - hd / 2, zc)), 0.17, "handle"),
                    WOOD, WOOD_L, WOOD_D))
    return out


def _door(xc, free_side, inside_pal=WOOD):
    """One closed door at centre xc (free edge toward +1 / -1 * free_side): board, two raised panels with ink
    plates and the tall handle near the free edge. Returns pieces in the closed position."""
    out = []
    zc, h = (DOOR_Z0 + DOOR_Z1) / 2, DOOR_Z1 - DOOR_Z0
    y_back = BY0 - 0.04
    board = chamfer_box(WOOD, (DW, DT, h), M((xc, y_back - DT / 2, zc)), FB, "door")
    pal = []
    for f in board.mesh.polygons:
        n = f.normal
        pal.append(WOOD_L if n.z > 0.6 else (WOOD_D if n.z < -0.6 else (inside_pal if n.y > 0.9 else WOOD)))
    board.face_pal = pal
    out.append(board)
    yf = y_back - DT                      # door front face
    side = 1.05                           # panel margin left / right
    pw = DW - 2 * side
    lo_z0, lo_z1 = DOOR_Z0 + 1.0, DOOR_Z0 + 4.4
    up_z0, up_z1 = lo_z1 + 1.0, DOOR_Z1 - 1.0
    pt = 0.22                             # how far a panel stands proud
    for z0, z1, rise in ((lo_z0, lo_z1, 0.0), (up_z0, up_z1, 1.25)):
        ph = z1 - z0
        if rise:
            pts = arch_pts(pw, ph, rise, n=8)
            ink = arch_pts(pw + 0.16, ph + 0.16, rise + 0.08, n=8)
            ink = [(x, z - 0.08) for x, z in ink]
        else:
            pts = [(-pw / 2, 0), (pw / 2, 0), (pw / 2, ph), (-pw / 2, ph)]
            ink = [(-pw / 2 - 0.08, -0.08), (pw / 2 + 0.08, -0.08), (pw / 2 + 0.08, ph + 0.08), (-pw / 2 - 0.08, ph + 0.08)]
        out.append(prism(INK, ink, 0.08, M((xc, yf + 0.01, z0)), 0.02, name="panel_gap", outline=False))
        panel = prism(PANEL, pts, pt + 0.04, M((xc, yf - pt / 2 + 0.01, z0)), 0.14, name="panel")
        out.append(tone(panel, PANEL, WOOD_L, WOOD_D, up=0.5, down=-0.5))
    out += _handle_v(xc + free_side * (DW / 2 - 0.6), DOOR_Z0 + 8.2, yf)
    return out


def _drawer():
    zc, h = (DRAWER_Z0 + DRAWER_Z1) / 2, DRAWER_Z1 - DRAWER_Z0
    out = [plate((ROW_W + 2 * GAP, 0.1, h + 2 * GAP), M((0, BY0 - 0.02, zc)), name="drawer_gap")]
    y_back = BY0 - 0.04
    ft = 0.42
    board = chamfer_box(WOOD, (ROW_W, ft, h), M((0, y_back - ft / 2, zc)), FB, "drawer")
    out.append(tone(board, WOOD, WOOD_L, WOOD_D))
    for hx in (-3.7, 3.7):
        out += _handle_h(hx, zc, y_back - ft)
    return out


def _feet_and_sides():
    out = []
    fw = 1.2
    for x in (-(BODY_W / 2 - 0.3 - fw / 2), BODY_W / 2 - 0.3 - fw / 2):
        for y in (BY0 + 0.3 + fw / 2, BY1 - 0.3 - fw / 2):
            out.append(tone(chamfer_box(WOOD, (fw, fw, FOOT_H + 0.12), M((x, y, (FOOT_H + 0.12) / 2)), 0.13, "foot",
                                        taper=(0.82, 0.82)), WOOD, WOOD_L, WOOD_D))
    # raised panels on the carcass sides: a tall one beside the doors, a short one beside the drawer
    for sx in (-1, 1):
        for z0, z1 in ((DOOR_Z0 + 0.5, DOOR_Z1 - 0.5), (DRAWER_Z0 + 0.35, DRAWER_Z1 - 0.35)):
            p = chamfer_box(PANEL, (0.24, BY1 - BY0 - 1.3, z1 - z0), M((sx * BODY_W / 2, (BY0 + BY1) / 2, (z0 + z1) / 2)),
                            0.1, "side_panel")
            out.append(tone(p, PANEL, WOOD_L, WOOD_D))
    return out


def _hinge_mat():
    """Turns the right door (built closed) open by AJAR about its hinge line."""
    return Matrix.Translation(HINGE) @ Matrix.Rotation(AJAR, 4, "Z") @ Matrix.Translation(-HINGE)


# ---------------------------------------------------------------- inside: rail, hangers, clothes
RAIL_Z = CAV_Z1 - 1.05
RAIL_Y = (BY0 + CAV_Y1) / 2 - 0.1


def _garment_mat(x, y, z):
    """Garment-local (u across the shoulders, v up, w out of the chest) -> world: hangs on the X rail, chest
    toward -X (toward the gap of the ajar door), shoulders along Y."""
    rot = Matrix(((0, 0, -1, 0), (-1, 0, 0, 0), (0, 1, 0, 0), (0, 0, 0, 1)))
    return Matrix.Translation((x, y, z)) @ rot


def _hanger(x):
    """Wooden hanger: curved shoulder bar along Y and a wire hook over the rail."""
    out = []
    zb = RAIL_Z - 0.75
    bar = K.tube(HANGER, [(x, RAIL_Y - 2.0, zb - 0.32), (x, RAIL_Y, zb + 0.06), (x, RAIL_Y + 2.0, zb - 0.32)],
                 radius=0.11, res=4, bevel_res=1, name="hanger")
    out.append(tone(bar, HANGER, HANGER, HANGER_D))
    hook = K.tube(RAIL, [(x, RAIL_Y, zb), (x, RAIL_Y - 0.12, RAIL_Z + 0.22), (x, RAIL_Y + 0.16, RAIL_Z + 0.02)],
                  radius=0.045, res=3, bevel_res=0, name="hook")
    out.append(hook)
    return out


SHIRT_STRIPE = 0.5


def _stripe_pal(z, top, dark):
    band = int(math.floor((top - z) / SHIRT_STRIPE))
    if band % 2 == 0:
        return SHIRT_RD if dark else SHIRT_R
    return SHIRT_WD if dark else SHIRT_W


def _shirt(x):
    """Red / cream striped long-sleeved shirt: the back sleeve hangs at its side, the front one flops out
    through the gap of the ajar door (clothes caught in the door)."""
    zt = RAIL_Z - 0.75
    top = zt - 0.9
    # outline (u across the shoulders; -u = toward the back of the wardrobe): back sleeve hanging, the front
    # shoulder ends where the flopped-out sleeve tube starts
    loop = [(0.0, -0.42), (0.55, -0.12), (1.95, -0.42), (2.35, -0.95), (2.75, -4.2), (2.05, -4.4), (1.72, -1.85),
            (1.7, -6.1), (0.0, -6.2), (-1.7, -6.1), (-1.72, -1.9), (-2.1, -0.85), (-1.95, -0.42), (-0.55, -0.12)]
    loop = [(-u, v) for u, v in reversed(loop)]
    p = shape(SHIRT_R, [loop], 0.36, 0.13, _garment_mat(x, RAIL_Y, zt), name="shirt", bevel_res=1)
    slice_mesh(p, (0, 0, 1), [top - SHIRT_STRIPE * k for k in range(12)])
    p.face_pal = [_stripe_pal(f.center.z, top, f.normal.z < -0.5) for f in p.mesh.polygons]
    out = [p]
    # the front sleeve: from the front shoulder out through the gap, then hanging down in front of it
    ys = RAIL_Y - 1.75
    ctrl = [(x, ys, zt - 0.85), (x - 0.15, ys - 0.75, zt - 1.25), (x - 0.5, BY0 - 0.75, zt - 1.75),
            (x - 0.62, BY0 - 1.0, zt - 2.7), (x - 0.62, BY0 - 0.95, zt - 3.7), (x - 0.55, BY0 - 0.85, zt - 4.4)]
    hints = [(1, 0, 0), (1, 0, 0.3), (0.3, -1, 0.3), (0, -1, 0), (0, -1, 0), (0, -1, 0)]
    me, info, L = sweep(ctrl, hints, 0.42, 0.22, step=0.25, sides=8, tip=False, squash=2.4)
    pal = []
    for kind, r, k, d, hw in info:
        if kind == "cap":
            pal.append(SHIRT_W if d > 0 else SHIRT_R)
        elif d > L - 0.45:
            pal.append(SHIRT_W)  # cream cuff
        else:
            pal.append(SHIRT_R if int(d / SHIRT_STRIPE) % 2 == 0 else SHIRT_W)
    sl = K.Piece(me, pal, outline=True, smooth=True, name="sleeve")
    sl.flat_faces = [i for i, inf in enumerate(info) if inf[0] == "cap"]
    out.append(sl)
    return out


def _hoodie(x):
    """A little teal hoodie: hood behind the neck, kangaroo pocket, cream drawstrings, yellow lining in the hood."""
    zt = RAIL_Z - 0.75
    half = [(0.0, -0.5), (0.5, -0.2), (1.6, -0.45), (2.05, -0.95), (2.4, -3.6), (1.8, -3.75), (1.5, -1.7),
            (1.5, -4.6), (0.0, -4.7)]
    loop = half[:-1] + [(-u, v) for u, v in reversed(half[1:-1])]
    mat = _garment_mat(x, RAIL_Y, zt)
    body = shape(HOOD, [loop], 0.42, 0.15, mat, name="hoodie", bevel_res=1)
    out = [tone(body, HOOD, HOOD_L, HOOD_D, up=0.55, down=-0.55)]
    # ribbed hem and cuffs: darker bands
    slice_mesh(body, (0, 0, 1), [zt - 4.25, zt - 3.3])
    body.face_pal = [HOOD_D if (f.center.z < zt - 4.25 or (f.center.z < zt - 3.3 and abs(f.center.y - RAIL_Y) > 1.6))
                     else (HOOD_L if f.normal.z > 0.55 else HOOD) for f in body.mesh.polygons]
    # hood: a puffy rounded lump behind the neck, its yellow lining showing at the front
    hood = K.sphere(HOOD, 0.75, mat @ M((0, -0.25, -0.12), scale=(1.0, 0.95, 0.55)), seg=10, rings=6, name="hood")
    out.append(tone(hood, HOOD, HOOD_L, HOOD_D, up=0.5, down=-0.5))
    lining = K.sphere(HOOD_IN, 0.5, mat @ M((0, -0.3, 0.2), scale=(1.0, 0.85, 0.3)), seg=8, rings=4, outline=False,
                      name="hood_in")
    out.append(lining)
    # kangaroo pocket on the chest side (w > 0 = toward -X)
    pk = [(-1.0, -4.05), (1.0, -4.05), (0.75, -2.9), (-0.75, -2.9)]
    pocket = shape(HOOD_D, [pk], 0.1, 0.04, mat @ Matrix.Translation((0, 0, 0.22)), name="pocket", bevel_res=1,
                   outline=False)
    out.append(pocket)
    for s in (-1, 1):
        cord = K.tube(CORD, [mat @ Vector((s * 0.28, -0.75, 0.25)), mat @ Vector((s * 0.32, -1.35, 0.26)),
                             mat @ Vector((s * 0.3, -1.8, 0.25))], radius=0.05, res=2, bevel_res=0, outline=False,
                      name="cord")
        out.append(cord)
    return out


def _coat(x):
    """A yellow raincoat, mostly hidden behind the door - a splash of colour deeper in."""
    zt = RAIL_Z - 0.75
    half = [(0.0, -0.4), (0.55, -0.1), (1.9, -0.4), (2.3, -0.95), (2.6, -4.6), (1.95, -4.75), (1.7, -1.9),
            (1.95, -7.4), (0.0, -7.5)]
    loop = half[:-1] + [(-u, v) for u, v in reversed(half[1:-1])]
    mat = _garment_mat(x, RAIL_Y, zt)
    p = shape(COAT, [loop], 0.4, 0.14, mat, name="coat", bevel_res=1)
    out = [tone(p, COAT, COAT, COAT_D, up=0.6, down=-0.5)]
    for k in range(3):
        out.append(K.sphere(BUTTON, 0.16, mat @ M((0, -2.0 - 1.4 * k, 0.22), scale=(1, 1, 0.5)), seg=6, rings=3,
                            outline=False, name="button"))
    return out


def _inside():
    out = []
    # the rail runs side to side under the cavity ceiling, on two little brackets
    rail = K.cylinder(RAIL, 0.13, CAV_X1 - CAV_X0, M(((CAV_X0 + CAV_X1) / 2, RAIL_Y, RAIL_Z), (0, math.pi / 2, 0)),
                      seg=10, name="rail")
    out.append(rail)
    for x in (CAV_X0 + 0.15, CAV_X1 - 0.15):
        out.append(K.cylinder(RAIL, 0.22, 0.14, M((x, RAIL_Y, RAIL_Z), (0, math.pi / 2, 0)), seg=10, name="bracket"))
    for x, fn in ((0.95, _shirt), (2.05, _hoodie), (3.3, _coat)):
        out += _hanger(x)
        out += fn(x)
    return out


# ---------------------------------------------------------------- socks
def _door_sock():
    """A green striped sock draped over the top of the ajar door, its foot hanging down the door front.
    Built in the door's closed position (it is turned open with the door)."""
    yb = BY0 - 0.04                 # door back face
    yf = yb - DT                    # door front face
    t = 0.13
    x = 1.55
    top = DOOR_Z1
    UP, FRONT, BACK = (0, 0, 1), (0, -1, 0), (0, 1, 0)
    ctrl = [(x + 0.1, yb + t + 0.02, top - 1.3), (x + 0.05, yb + t + 0.02, top - 0.5), (x, (yb + yf) / 2, top + t + 0.03),
            (x - 0.02, yf - t - 0.02, top - 0.4), (x - 0.05, yf - t - 0.02, top - 1.3), (x + 0.0, yf - t - 0.02, top - 2.2),
            (x + 0.35, yf - t - 0.03, top - 2.75), (x + 1.0, yf - t - 0.03, top - 2.7), (x + 1.6, yf - t - 0.02, top - 2.5)]
    hints = [BACK, BACK, UP, FRONT, FRONT, FRONT, FRONT, FRONT, FRONT]
    return [sock(ctrl, hints, dict(body=SK_GRN, stripe=SK_GRN_S, accent=SK_GRN_D, inner=SK_IN), heel=6, stripe=0.3,
                 step=0.2, name="door_sock")]


def _drawer_sock():
    """A purple sock caught in the closed drawer: it comes out over the drawer front's top edge and hangs down,
    its foot kicking out to the left."""
    yf = BY0 - 0.04 - 0.42          # drawer front face
    t = 0.13
    x = -5.55
    top = DRAWER_Z1
    UP, FRONT = (0, 0, 1), (0, -1, 0)
    ctrl = [(x + 0.1, BY0 + 0.5, top - 0.3), (x + 0.05, BY0 - 0.2, top + 0.03), (x, yf - t - 0.03, top - 0.3),
            (x - 0.04, yf - t - 0.02, top - 1.1), (x - 0.02, yf - t - 0.02, top - 1.9), (x + 0.25, yf - t - 0.03, top - 2.55),
            (x + 0.95, yf - t - 0.03, top - 2.7)]
    hints = [UP, (0, -0.4, 1), (0, -1, 0.3), FRONT, FRONT, FRONT, FRONT]
    return [sock(ctrl, hints, dict(body=SK_PUR, accent=SK_PUR_D, inner=SK_IN), heel=4, step=0.2, name="drawer_sock")]


# ---------------------------------------------------------------- on top
def _hatbox(cx, cy):
    """A pink hat box with cream stripes, a lid and a purple ribbon - and a blue baseball cap on it."""
    out = []
    z0 = TOP_Z1
    r, h = 2.0, 1.13
    box = K.cylinder(BOX, r, h, M((cx, cy, z0 + h / 2)), seg=20, name="hatbox")
    box.face_pal = [BOX_L if f.normal.z > 0.6 else (BOX_D if f.normal.z < -0.6 else (BOX_S if i % 2 else BOX))
                    for i, f in enumerate(box.mesh.polygons)]
    out.append(box)
    lh = 0.46
    lid = K.cylinder(BOX, r + 0.14, lh, M((cx, cy, z0 + h + lh / 2 - 0.14)), seg=20, name="hatbox_lid")
    out.append(tone(lid, BOX, BOX_L, BOX_D))
    band = K.cylinder(RIBBON, r + 0.16, 0.22, M((cx, cy, z0 + h + 0.06)), seg=20, outline=False, name="ribbon")
    out.append(band)
    # the cap sits on the lid, a little turned, its brim poking out over the front edge
    out += _cap(cx + 0.15, cy - 0.2, z0 + h + lh - 0.14, 0.45)
    return out


def _cap(cx, cy, z0, rz):
    """A blue baseball cap: a squashed dome, a brim and a yellow button."""
    out = []
    m = M((cx, cy, z0), (0, 0, rz))
    crown = K.sphere(CAP, 1.2, m @ M((0, 0.15, 0), scale=(1.0, 1.05, 0.66)), seg=14, rings=7, name="cap")
    for v in crown.mesh.vertices:
        if v.co.z < z0 + 0.04:
            v.co.z = z0 + 0.04
    crown.mesh.update()
    out.append(tone(crown, CAP, CAP_L, CAP_D, up=0.75, down=-0.6))
    brim = K.cylinder(CAP, 1.0, 0.11, m @ M((0, -1.1, 0.16), (0.14, 0, 0), (1.05, 0.95, 1)), seg=14, name="brim")
    out.append(tone(brim, CAP, CAP_L, CAP_D))
    out.append(K.sphere(CAP_B, 0.17, m @ M((0, 0.15, 0.8), scale=(1, 1, 0.6)), seg=8, rings=4, name="cap_button"))
    return out


def _game_boxes(cx, cy):
    """Two board-game boxes stacked on the top (coloured lids, a cream band)."""
    out = []
    z = TOP_Z1
    for (w, d, t, col, col_l, col_d, rot) in ((4.0, 3.0, 0.62, GAME_G, GAME_G_L, GAME_G_D, 0.06),
                                             (3.5, 2.6, 0.55, GAME_R, GAME_R_L, GAME_R_D, -0.2)):
        m = M((cx, cy, z + t / 2), (0, 0, rot))
        lid = chamfer_box(col, (w, d, t), m, 0.08, name="game")
        out.append(tone(lid, col, col_l, col_d))
        band = chamfer_box(GAME_BAND, (w + 0.04, d + 0.04, 0.12), m @ M((0, 0, -t / 2 + 0.16)), 0.0, name="game_band",
                           outline=False)
        out.append(band)
        z += t
    return out


# ---------------------------------------------------------------- build
def build():
    p = [_body()]
    p += _crown()
    p += _feet_and_sides()
    # left door: closed on its ink plate
    xl = -(DOOR_GAP / 2 + DW / 2)
    zc, h = (DOOR_Z0 + DOOR_Z1) / 2, DOOR_Z1 - DOOR_Z0
    p.append(plate((DW + 2 * GAP, 0.1, h + 2 * GAP), M((xl, BY0 - 0.02, zc)), name="door_gap"))
    p += _door(xl, +1)
    # right door: ajar on its hinge, with the green sock over its top
    xr = DOOR_GAP / 2 + DW / 2
    right = _door(xr, -1, inside_pal=DOOR_IN) + _door_sock()
    p += transform(right, _hinge_mat())
    p += _drawer()
    p += _drawer_sock()
    p += _inside()
    p += _hatbox(-6.35, 0.55)
    p += _game_boxes(6.3, 0.5)
    body, outline = K.finish(p, NAME, outline_width=OUTLINE_W)
    no_bounce(outline)
    return [body, outline] + K.markers(NAME)
