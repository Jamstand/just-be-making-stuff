"""
props/bookshelf.py - the Bookshelf prop (ReplicatedStorage.MapMeshes.Bookshelf): the open wooden
bookshelf against the bedroom wall. See props/__init__.py for the conventions every prop follows.

Art (docs/concept/bedroom_keyframe.png, right edge behind the clothesline socks; the brightened
crop shows it best): one chunky carcass with softly rounded edges - wide side stiles, a thick top,
one thick middle shelf and a bottom board, the carcass closed along an inked bottom edge and standing
on four separate short block feet set in from the sides - so two open compartments, each a little
wider than tall. Warm reddish-brown wood, lighter top edges, dark maroon insides. Top compartment:
a red and a taller orange-brown book standing upright, then a green book and a dark green one
leaning left onto them; the right half is empty. The lower compartment is hidden by the dresser in
the art; it gets a few upright books and a lying stack. Ink lines on the silhouette, round every
book and round both compartment openings.

Floor-standing: origin = floor centre, front -Y, back flat at +Y against the wall. The art's shelf
is taller than wide (about 0.8 : 1 : 0.33); Map.luau's fit box (72 x 62 x 30) then makes it ~49
studs wide and 62 tall.
"""
import math
import bmesh
import bpy
import sockkit as K
from sockkit import M, hexcol
from props.common import *  # noqa: F401,F403 - shared colours (read-only)

NAME = "Bookshelf"
EXPORT_DIR = "map"

# wood (hue sampled from the keyframe's shelf, lifted out of the night shadow it sits in there)
WOOD = hexcol("shelf_wood", "#A44A30")          # front faces of the carcass
WOOD_L = hexcol("shelf_wood_light", "#C9693F")  # top-facing edges
WOOD_S = hexcol("shelf_wood_side", "#86392A")   # outer side panels
WOOD_D = hexcol("shelf_wood_dark", "#652A21")   # undersides
# insides: near-black maroon as in the art (#421E1E upper, #2E171F lower) - the nightstand cubby's
# values, so the furniture matches and the books pop
IN = hexcol("shelf_inside", "#53231E")          # compartment walls and ceilings
IN_F = hexcol("shelf_inside_floor", "#8C4430")  # compartment floors (catch a little light)
IN_B = hexcol("shelf_back", "#3F1B1B")          # back panel
# books: (spine, covers/sides, top) - the art's red, orange-brown, green, dark green, plus blue
BOOKS = {
    "red": (hexcol("shelf_book_red", "#C2353C"), hexcol("shelf_book_red_side", "#8E2530"), hexcol("shelf_book_red_top", "#DC5650")),
    "orange": (hexcol("shelf_book_orange", "#C7692F"), hexcol("shelf_book_orange_side", "#94481F"), hexcol("shelf_book_orange_top", "#DE8A48")),
    # the art's greens are darker and cooler than the red / orange books (forest green and slate)
    "green": (hexcol("shelf_book_green", "#3D6B45"), hexcol("shelf_book_green_side", "#2C5034"), hexcol("shelf_book_green_top", "#4E8457")),
    "dkgreen": (hexcol("shelf_book_dkgreen", "#2A4E4C"), hexcol("shelf_book_dkgreen_side", "#1F3A3A"), hexcol("shelf_book_dkgreen_top", "#3A6662")),
    "blue": (hexcol("shelf_book_blue", "#3F64B2"), hexcol("shelf_book_blue_side", "#2D4A88"), hexcol("shelf_book_blue_top", "#5A7DC8")),
}

W, H, D = 4.0, 5.15, 1.7
S = 0.42          # side stile width
FOOT = 0.3        # feet height: the carcass's bottom edge sits at z = FOOT
FOOT_W = 0.35     # square block feet ...
FOOT_IN = 0.12    # ... set in from the sides, front and back
BOT = 0.62        # top of the bottom board
MID0, MID1 = 2.44, 2.84  # middle shelf
TOP0 = 4.76       # underside of the top
BACK = 0.12       # back panel thickness
BEVEL = 0.085
OUTLINE = 0.075

FY = -D / 2                 # front plane
PY = D / 2 - BACK           # front of the back panel (compartment depth = PY - FY)
IX = W / 2 - S              # inner half width
BOOK_Y = FY + 0.14          # books' spines sit a little behind the front edge


def _carcass():
    """One solid: an xz grid of cells extruded from their own front depth to the back plane, so the
    compartments are pockets in a single mesh (no seams on the front frame); then all real edges are
    rounded by an angle-limited bevel. The bottom is closed at z = FOOT (the feet are separate)."""
    xs = [-W / 2, -IX, IX, W / 2]
    zs = [FOOT, BOT, MID0, MID1, TOP0, H]
    front = {}
    for i in range(3):
        for k in range(5):
            front[i, k] = PY if (i == 1 and k in (1, 3)) else FY   # the two compartments
    bm = bmesh.new()
    vmap = {}

    def v(x, y, z):
        key = (round(x, 5), round(y, 5), round(z, 5))
        if key not in vmap:
            vmap[key] = bm.verts.new(key)
        return vmap[key]

    by = D / 2
    for (i, k), f in front.items():
        x0, x1, z0, z1 = xs[i], xs[i + 1], zs[k], zs[k + 1]
        bm.faces.new((v(x0, f, z0), v(x1, f, z0), v(x1, f, z1), v(x0, f, z1)))   # front (-Y)
        bm.faces.new((v(x0, by, z0), v(x0, by, z1), v(x1, by, z1), v(x1, by, z0)))  # back (+Y)
        # walls toward each neighbour (or the outside) that stands further back than this cell
        for di, dk in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nb = front.get((i + di, k + dk))
            g = by if nb is None else nb
            if g <= f:
                continue
            # the edge of this cell shared with the neighbour, as two points in xz
            if di == 1:
                a, b = (x1, z0), (x1, z1)
            elif di == -1:
                a, b = (x0, z1), (x0, z0)
            elif dk == 1:
                a, b = (x1, z1), (x0, z1)
            else:
                a, b = (x0, z0), (x1, z0)
            bm.faces.new((v(a[0], f, a[1]), v(a[0], g, a[1]), v(b[0], g, b[1]), v(b[0], f, b[1])))
    bm.normal_update()
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new("carcass")
    bm.to_mesh(me)
    bm.free()
    obj = bpy.data.objects.new("carcass", me)
    K.link(obj)
    mod = obj.modifiers.new("bevel", "BEVEL")
    mod.width = BEVEL
    mod.segments = 2
    mod.limit_method = "ANGLE"
    mod.angle_limit = math.radians(30)
    mod.harden_normals = False
    me = K.bake_object(obj)

    pal = []
    for poly in me.polygons:
        n, c = poly.normal, poly.center
        in_pocket = abs(c.x) < IX + 0.01 and c.y > FY + BEVEL + 0.02 and (
            BOT - 0.01 < c.z < MID0 + 0.01 or MID1 - 0.01 < c.z < TOP0 + 0.01)
        # the rim of an opening: the inner of the two bevel faces rounding into a compartment is inked
        # (the art draws a thin dark line round both openings, on the shelf lip too)
        on_rim = (c.y < FY + BEVEL + 0.01 and abs(c.x) < IX + BEVEL and -0.75 < n.y < -0.12 and (
            BOT - BEVEL < c.z < MID0 + BEVEL or MID1 - BEVEL < c.z < TOP0 + BEVEL))
        if on_rim:
            pal.append(K.OUTLINE)
        elif in_pocket:
            if n.y < -0.6:
                pal.append(IN_B)
            elif n.z > 0.6:
                pal.append(IN_F)
            else:
                pal.append(IN)
        elif n.z > 0.6:
            pal.append(WOOD_L)
        elif n.z < -0.6 or n.y > 0.6:
            pal.append(WOOD_D)
        elif abs(n.x) > 0.6 and abs(c.x) > W / 2 - 0.05:
            pal.append(WOOD_S)
        else:
            pal.append(WOOD)
    return K.Piece(me, pal, outline=True, smooth=False, name="carcass")


def _feet():
    """Four separate short block feet under the closed carcass, set in from the sides and front."""
    out = []
    fx = W / 2 - FOOT_IN - FOOT_W / 2
    fy = D / 2 - FOOT_IN - FOOT_W / 2
    h = FOOT + 0.06  # tucked 0.06 up into the carcass
    for x in (-fx, fx):
        for y in (-fy, fy):
            f = K.rounded_box(WOOD_S, (FOOT_W, FOOT_W, h), M((x, y, h / 2)), bevel=0.06, segments=2, name="foot")
            f.face_pal = [WOOD_S if poly.normal.y < -0.6 else WOOD_D for poly in f.mesh.polygons]
            f.smooth = False
            out.append(f)
    return out


def _book(colour, x, z, w, h, d, tilt=0.0, lying=False, name="book"):
    """A rounded book. Upright: (x, z) = bottom-left corner of the spine, tilt > 0 leans its top to
    the left, pivoting on that corner. Lying: the spine still faces front, w = length, h = thickness."""
    spine, side, top = BOOKS[colour]
    if lying:
        tilt = 0.0
    ct, st = math.cos(tilt), math.sin(tilt)
    cx = x + (w / 2) * ct - (h / 2) * st
    cz = z + (w / 2) * st + (h / 2) * ct
    p = K.rounded_box(spine, (w, d, h), M((cx, BOOK_Y + d / 2, cz), rot=(0, -tilt, 0)), bevel=0.045, segments=2, name=name)
    pal = []
    for f in p.mesh.polygons:
        n = f.normal
        if n.z > 0.6:
            pal.append(top)
        elif abs(n.x) > 0.6 or n.y > 0.6 or n.z < -0.6:
            pal.append(side)
        else:
            pal.append(spine)
    p.face_pal = pal
    p.smooth = False
    return p


def _corners(x, z, w, h, tilt):
    """Bottom-left, bottom-right, top-right, top-left of an upright book leaning by tilt."""
    ct, st = math.cos(tilt), math.sin(tilt)

    def r(px, pz):
        return (x + px * ct - pz * st, z + px * st + pz * ct)
    return r(0, 0), r(w, 0), r(w, h), r(0, h)


def _lean_on(prev, z, h, tilt):
    """x of the bottom-left corner that rests a book standing at z, of height h, leaning by tilt, with
    its top-left corner on the right face of `prev` (= its corners)."""
    br, tr = prev[1], prev[2]
    zc = z + h * math.cos(tilt)
    s = (zc - br[1]) / (tr[1] - br[1])
    xc = br[0] + s * (tr[0] - br[0])
    return xc + h * math.sin(tilt) + 0.005



def _camera_only(outline):
    """Cycles-only flags (no effect on the GLB or the game): in the preview renders the inverted hull
    otherwise blocks all bounce and sky light from the faces it wraps, so every face the sun misses
    (undersides, insets, the inside of recesses) renders black whatever its paint. Roblox doesn't
    ray-trace ambient light, so this is closer to how the game shows the prop."""
    outline.visible_diffuse = False
    outline.visible_glossy = False
    outline.visible_transmission = False

def build():
    p = [_carcass()] + _feet()

    # top compartment (as in the art): red, orange-brown upright, green and dark green leaning left
    z = MID1 + 0.005
    x = -IX + 0.02
    p.append(_book("red", x, z, 0.34, 1.04, 1.15, name="b_red"))
    x += 0.36
    p.append(_book("orange", x, z, 0.36, 1.14, 1.2, name="b_orange"))
    orange = _corners(x, z, 0.36, 1.14, 0.0)
    t = math.radians(9)
    xg = _lean_on(orange, z, 1.06, t)
    p.append(_book("green", xg, z, 0.42, 1.06, 1.12, tilt=t, name="b_green"))
    green = _corners(xg, z, 0.42, 1.06, t)
    t2 = math.radians(19)
    xt = _lean_on(green, z, 1.02, t2)
    p.append(_book("dkgreen", xt, z, 0.45, 1.02, 1.08, tilt=t2, name="b_dkgreen"))

    # lower compartment (hidden in the art): a row of upright books and a lying stack
    z = BOT + 0.005
    x = -IX + 0.02
    for colour, w, h, d in (("blue", 0.38, 1.14, 1.2), ("red", 0.36, 1.02, 1.15), ("orange", 0.34, 1.1, 1.1)):
        p.append(_book(colour, x, z, w, h, d, name="b_" + colour))
        x += w + 0.02
    last = _corners(x - 0.36, z, 0.34, 1.1, 0.0)
    t3 = math.radians(12)
    xl = _lean_on(last, z, 1.04, t3)
    p.append(_book("green", xl, z, 0.4, 1.04, 1.12, tilt=t3, name="b_green2"))
    zs = z
    for colour, ox, length, th, d in (("dkgreen", 0.48, 1.0, 0.24, 1.2), ("blue", 0.55, 0.88, 0.21, 1.1),
                                      ("red", 0.6, 0.78, 0.19, 1.05)):
        p.append(_book(colour, ox, zs, length, th, d, lying=True, name="b_stack"))
        zs += th + 0.004

    body, outline = K.finish(p, NAME, outline_width=OUTLINE)
    _camera_only(outline)
    return [body, outline] + K.markers(NAME)
