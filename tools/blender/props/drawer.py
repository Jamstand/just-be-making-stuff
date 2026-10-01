"""
props/drawer.py - the Drawer prop (ReplicatedStorage.MapMeshes.Drawer): each player's base, one big
wooden dresser drawer pulled out onto the floor. See props/__init__.py for the conventions every
prop follows.

Art (docs/concept/bedroom_keyframe.png, the two open drawers left and right): a bright orange-brown
front board with a thin 45-degree chamfered border that overhangs the box sides, a compact chunky
chamfered block handle, a box behind it in a much darker, cooler plum-brown, light top edges, very
dark insides and dusty blue liner paper inside, inked where the paper meets the wood.

Gameplay shape: players and socks walk in over the front, so the front panel stays LOW (30% of the
wall height) and carries the handle; back and side walls are full height. No floor - Map.luau
draws the floor and the felt. Dimensions below are in studs (Map.luau: 46 x 32 footprint inside
9-stud invisible walls, fit box 52 x 15 x 38) and scaled by S into model units.
"""
import bmesh
import bpy
from mathutils import Vector
import sockkit as K
from sockkit import M, hexcol
from props.common import *  # noqa: F401,F403 - shared colours (read-only)

NAME = "Drawer"
S = 0.1  # model units per stud

# colours sampled from the open drawers in the keyframe (lit front face, lit top edges, box, inside)
WOOD_B = hexcol("drawer_wood", "#CC6236")        # front slab and handle
WOOD_T = hexcol("drawer_wood_top", "#E2894A")    # top chamfers of the front slab and handle (the brightest)
WOOD_TM = hexcol("drawer_wood_rim", "#B8643A")   # flat tops of the box walls (art: a thin mid-light line)
WOOD_S = hexcol("drawer_wood_shade", "#8A3F2E")  # undersides
WOOD_X = hexcol("drawer_wood_box", "#63303A")    # outside of the box walls (art: #582A30-#5A2B31, cool plum)
WOOD_IN = hexcol("drawer_wood_inner", "#4A1E1C")  # inside faces above the liner (art: #38151A-#491C1D)
FELT = hexcol("drawer_felt", "#5272A8")          # blue liner paper (art: dusty denim #5976A0-#6A85A8)
INK = K.OUTLINE                                  # drawn ink lines inside the drawer

# layout (studs). The game fits the bounding box (outline hull included: +OUTLINE all round) into
# 52 x 15 x 38 and centres it, so:
#  - width: FX + OUTLINE = 26 keeps the scale at exactly 1 and puts the side liner face (IX - LINER
#    = 22) on the inner face of the game's invisible side walls (x 22..23);
#  - depth: the back outer face and the handle's tip sit at -/+ 18.0 (37.0 with the outline, < 38,
#    centred), the back liner face lands at y 15 (the invisible back wall). The front slab and the
#    deep handle fit because the front slab's inner face sits at YF, 1.3 studs inside the
#    footprint edge, still clear of the CollectPad (y -13.5).
IX = 22.3           # side wall inner faces at x +-IX
IYB = 15.3          # back wall inner face
YF = -13.7          # front slab inner face (side walls end here)
LINER = 0.3         # blue liner thickness
OUTLINE = 0.52      # ink line width (~1% of the front, like the art's ink)
WALL = 1.8          # side wall thickness
H = 11.0            # wall height (Map: floor 1 + 9-stud invisible walls)
FH = 3.3            # front panel height (30% of H - players step over it)
FT = 1.9            # front slab thickness (a flat board, not a beam)
FB = 0.38           # front slab chamfer (thin 45-degree border, ~12% of its height)
FX = 26.0 - OUTLINE  # front panel half width (overhangs the box sides by 1.5)
HW, HH, HD = 6.0, 2.2, 2.4  # handle width / height / protrusion: a compact block with slab showing all round
HB = 0.48           # handle chamfer
BACK = YF * -1 + FT + HD - IYB  # back wall thickness: back outer face mirrors the handle tip (2.7)


def _v(x, y, z):
    return Vector((x * S, y * S, z * S))


def _slab(quads, z0, z1, bevel, segs, name):
    """Extrudes plan quads (lists of (x, y) studs, CCW from above, sharing whole edges) from z0 to
    z1 into one closed solid and rounds every real edge with an angle-limited bevel - so an L or U
    of walls is one piece with no seams at the corners."""
    bm = bmesh.new()
    vmap = {}

    def vert(x, y, z):
        k = (round(x, 4), round(y, 4), round(z, 4))
        if k not in vmap:
            vmap[k] = bm.verts.new(_v(*k))
        return vmap[k]

    uses = {}
    for q in quads:
        for i in range(len(q)):
            a, b = q[i], q[(i + 1) % len(q)]
            uses.setdefault(tuple(sorted((a, b))), []).append((a, b))
    for q in quads:
        bm.faces.new([vert(x, y, z1) for x, y in q])
        bm.faces.new([vert(x, y, z0) for x, y in reversed(q)])
    for edge in uses.values():
        if len(edge) == 1:
            (ax, ay), (bx, by) = edge[0]
            bm.faces.new([vert(ax, ay, z0), vert(bx, by, z0), vert(bx, by, z1), vert(ax, ay, z1)])
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    obj = bpy.data.objects.new(name, me)
    K.link(obj)
    mod = obj.modifiers.new("bevel", "BEVEL")
    mod.width = bevel * S
    mod.segments = segs
    mod.limit_method = "ANGLE"
    mod.harden_normals = False
    return K.bake_object(obj)


def _u(x_in, y_back, y_front, t, e):
    """Plan quads of a U (two sides + back) whose inner faces are at x +-x_in / y_back, `t` thick
    toward the inside, sunk `e` into the wood behind it; the sides run from y_front to the back."""
    xo, yo = x_in + e, y_back + e
    xi, yi = x_in - t, y_back - t
    return [
        [(-xo, y_front), (-xi, y_front), (-xi, yi), (-xo, yi)],
        [(-xo, yi), (-xi, yi), (-xi, yo), (-xo, yo)],
        [(-xi, yi), (xi, yi), (xi, yo), (-xi, yo)],
        [(xi, yi), (xo, yi), (xo, yo), (xi, yo)],
        [(xi, y_front), (xo, y_front), (xo, yi), (xi, yi)],
    ]


def _box(size, center, bevel, segs, name):
    """A bevelled box in studs; segs=1 gives the art's crisp 45-degree chamfer."""
    p = K.rounded_box(WOOD_B, (size[0] * S, size[1] * S, size[2] * S), M(_v(*center)),
                      bevel=bevel * S, segments=segs, name=name)
    return p.mesh


def _paint(me, fn, smooth=False, outline=True, name="piece"):
    pal = [fn(Vector(p.normal), Vector(p.center) / S) for p in me.polygons]
    return K.Piece(me, pal, outline=outline, smooth=smooth, name=name)


def _inward(n, c):
    """True for faces that look into the drawer (normal points back toward its centre)."""
    return n.x * c.x + n.y * c.y < 0 and abs(c.x) < FX - 0.5


def _front_wood(n, c):
    """Front slab: light on top-facing faces, shade underneath, dark on the inside face."""
    if n.z > 0.6:
        return WOOD_T
    if n.z < -0.6:
        return WOOD_S
    return WOOD_IN if _inward(n, c) else WOOD_B


def _box_wood(n, c):
    """Box walls: a mid-light rim on the flat tops (one test, n.z > 0.75, for the whole top bevel
    row so the corner patches match their neighbours), very dark inside, the darker box wood on
    every outward face - except each side wall's front end, which carries the front's bright wood
    (with a lit top chamfer) so the end posts tie into the front slab like the art's panel edges."""
    if n.z < -0.6:
        return WOOD_S
    if c.y < YF + 0.7 and n.y < -0.3 and abs(c.x) > IX:
        return WOOD_T if n.z > 0.3 else WOOD_B
    if n.z > 0.75:
        return WOOD_TM
    return WOOD_IN if _inward(n, c) else WOOD_X


def _no_bounce(outline):
    """Preview only (Cycles ray flags, not exported): the inverted hull must not block bounce light,
    or renders show black wedges in corners and darkened insides that Roblox never draws."""
    outline.visible_diffuse = False
    outline.visible_glossy = False
    outline.visible_transmission = False


def build():
    ox, by = IX + WALL, IYB + BACK
    # back + side walls: one U-shaped solid with rounded edges; the sides end at the front slab
    walls = _slab([
        [(-ox, YF), (-IX, YF), (-IX, IYB), (-ox, IYB)],
        [(-ox, IYB), (-IX, IYB), (-IX, by), (-ox, by)],
        [(-IX, IYB), (IX, IYB), (IX, by), (-IX, by)],
        [(IX, IYB), (ox, IYB), (ox, by), (IX, by)],
        [(IX, YF), (ox, YF), (ox, IYB), (IX, IYB)],
    ], 0.0, H, bevel=0.55, segs=2, name="walls")
    p = [_paint(walls, _box_wood, name="walls")]

    # blue liner paper on the inner faces (sunk 0.05 into the wood so nothing z-fights). Its front
    # ends stop 1.5 behind the walls' rounded front ends so no square blue corner pokes out.
    lh, e, ly0 = H * 0.66, 0.05, YF + 1.5
    liner = _slab(_u(IX, IYB, ly0, LINER, e), 0.3, lh, bevel=0.12, segs=1, name="liner")
    p.append(_paint(liner, lambda n, c: FELT, name="liner"))
    # the art's ink line where the paper meets the wood: a dark strip capping the liner's top edge,
    # standing 0.1 proud of the paper so it reads from above and from the side
    ink = _slab(_u(IX, IYB, ly0 - 0.05, LINER + 0.1, e), lh - 0.12, lh + 0.2, bevel=0.06, segs=1, name="ink")
    p.append(_paint(ink, lambda n, c: INK, outline=False, name="ink"))
    # ink along the inner top edge of the U walls, just under the rounded top; a mitre wedge in
    # each back corner bridges the walls' concave corner fillet so the line runs round unbroken
    rim_z = H - 0.55 - 0.3
    ink2 = _slab(_u(IX, IYB, YF + 0.6, 0.12, e), rim_z, rim_z + 0.26, bevel=0.04, segs=1, name="ink2")
    p.append(_paint(ink2, lambda n, c: INK, outline=False, name="ink2"))
    for sx in (-1, 1):
        tri = [(sx * (IX + e), IYB + e), (sx * (IX - 0.12), IYB - 0.8), (sx * (IX - 0.8), IYB - 0.12)]
        wedge = _slab([tri if sx < 0 else tri[::-1]], rim_z, rim_z + 0.26, bevel=0.04, segs=1, name="ink2c")
        p.append(_paint(wedge, lambda n, c: INK, outline=False, name="ink2c"))

    # the low front slab: a flat board with a thin 45-degree chamfered border, overhanging the box sides
    fy = YF - FT / 2
    front = _box((FX * 2, FT, FH), (0, fy, FH / 2), bevel=FB, segs=1, name="front")
    p.append(_paint(front, _front_wood, name="front"))

    # compact chunky chamfered block handle (sunk 0.2 into the slab) with slab showing all round it,
    # light top chamfer, dark underside
    hy = YF - FT - HD / 2 + 0.1
    handle = _box((HW, HD + 0.2, HH), (0, hy, FH / 2), bevel=HB, segs=1, name="handle")
    p.append(_paint(handle, lambda n, c: WOOD_T if n.z > 0.6 else (WOOD_S if n.z < -0.6 else WOOD_B), name="handle"))

    body, outline = K.finish(p, NAME, outline_width=OUTLINE * S)
    _no_bounce(outline)
    return [body, outline] + K.markers(NAME)
