"""
props/nightstand.py - the Nightstand prop (ReplicatedStorage.MapMeshes.Nightstand). See props/__init__.py for
the conventions every prop follows.

Matches the bedside table in docs/concept/bedroom_keyframe.png (left of the bed, under the globe lamp):
- a thick top slab with chamfered edges that overhangs the body on every side (lit, lighter top faces),
- one wide drawer just under the slab with a chunky rounded-rectangle block handle,
- an open cubby below the drawer (dark inside, lit floor lip), a chunky bottom rail,
- four short, slightly tapered square feet set in from the corners.
Ink lines between parts come from the inverted hull plus dark "gap" plates behind the drawer front and
the handle (the art draws a dark line all the way round both).
Proportions are measured from the keyframe (364 px tall there = 7.8 units here, wide-angle stretch taken
out): about as wide as it is tall, so Map.luau's 70 x 78 x 70 slot fits it by width (~70 x 73 x 68 studs);
the Lamp stands on the top centre. Vertical stack (units, art in brackets): slab 1.3 (1.32) / strip 0.33 (0.36)
/ drawer 2.3 (2.28) / rail 0.32 (0.32) / cubby 1.75 (1.68) / bottom rail 1.05 (1.09) / feet 0.75 (0.75).
"""
import math
import bmesh
import bpy
import sockkit as K
from mathutils import Vector
from sockkit import M, hexcol
from props.common import *  # noqa: F401,F403 - shared colours (read-only)

NAME = "Nightstand"

# colours sampled from the keyframe (lit faces of the nightstand / dressers), toned so the game's warm
# lamp light lands near the art
NS_WOOD = hexcol("nightstand_wood", "#B8633A")      # front / side faces
NS_WOOD_L = hexcol("nightstand_wood_light", "#DF8A3C")  # top-facing faces and chamfers (lamp-lit)
NS_WOOD_D = hexcol("nightstand_wood_dark", "#8A4329")   # undersides, shaded patches
NS_CUBBY = hexcol("nightstand_cubby", "#3F1B1B")    # back wall + ceiling of the open shelf (art #2B1215:
#                                                      near black-brown; Roblox has no ambient occlusion)
NS_CUBBY_S = hexcol("nightstand_cubby_side", "#53231E")  # the shelf's inner side walls (art: lit one #5E251E)
NS_CUBBY_F = hexcol("nightstand_cubby_floor", "#8C4430")  # shelf floor (gets a little light)
INK = K.OUTLINE

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
