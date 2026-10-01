"""
props/clothespin.py - the Clothespin every hanging sock wears (docs/concept/bedroom_keyframe.png,
the clothesline): a classic wooden spring clothespin seen face-on.

What the art shows (and what is built here):
- two long flat wooden prongs: the FRONT prong faces the viewer and leans a touch to the left; the
  BACK prong sits behind it, peeks out on the right and leans to the right, so the top ends fan apart
  while the jaws meet at the bottom. The back prong is a little shorter. Both ends of each prong are
  cut on a slant rising to the right (the art: top ~18, bottom ~15 degrees on screen), and the wire
  band runs nearly parallel to them (~16). In 3D the bottom cut is a little steeper than the top one:
  the close 50 mm preview camera adds ~+6 degrees to the top cut and ~-6 to the bottom one; at game
  distances they read ~17 and ~15, as in the art (a far, 300 mm render: top 13, bottom 17.5, band 17.5).
- pale warm wood (#E8A95A) with a lighter top end and left edge, a reddish-brown right side strip
  (#84462F, ~15% of the face) on both prongs, and the back prong's face in the front prong's shadow
  below its lit top third. The visible right edge of the front prong is a deep rounded corner
  (SIDE_BEVEL), so that strip is a lit facet - a flat side in shade renders near-black and reads as a
  doubled ink seam. From behind, the back prong's outer face is the same pale wood with the same lit
  edge and side strip, mirrored.
- a mauve-grey wire spring: a band across the front prong's face about a third of the way up, drawn
  in two pieces with a break about half way (as on every pin in the art), its left tip a light tick in
  the outline, round the right edge to the side strip, then a short knee and a steep, straight arm up
  to the coil: a narrow upright loop like the art's "9" (leaning right, its wire a little thinner),
  one turn that tucks its end back in beside the arm, round a dark slit of an eye. The curl faces the
  viewer squarely and sits just right of the front prong where it overlaps the back prong's face, its
  ink meeting the prong's outline; band, arm and coil get cooler and darker in turn, as in the art.
  The same band wraps the back prong's outer face (seen from behind), over both its edges.
- the wire's ink is as bold as the art's (~0.6 wire width each side), and even on both sides of the
  wire: it is a flat strip of ink through the wire's centre line - under the bands it lies on the
  wood, along the arm and the curl it faces the viewer, the arm's edges lifted clear of the wood where
  it crosses the side strip. One-sided, so seen edge-on (from the line's ends) it vanishes instead of
  showing as a black tab; there the spring reads as grey wire on the wood.
- each prong's side profile is a real clothespin's: straight outer face, inner face tapering to a
  narrow jaw tip with a small grip groove, a gap between the handle ends.

The pin is turned 23 degrees about its long axis (TURN) so the prongs' right sides show from the
front, like every pin on the line in the art.

Game scale (NOT fitted by Map): 1 unit = 1 stud at sock scale 1. Front prong PIN_H = 2.5 long; the
whole pin is ~2.66 tall x 1.12 wide x 0.79 deep, outline ~0.047 (the art's pins are ~0.6x the height
of the 4.2-tall sock they hold; at the brief's 1.6 the clothesline would cross the pin halfway up
instead of at the wire band, and the pin would look small next to the sock). Origin
(Clothespin_Base) at the lowest jaw tip (the slanted jaw end's left corner), front -Y.
Factory.addClothespin puts that origin 0.3 below the top of the sock leg, so the jaws overlap the
cuff; with the sock layout in Map that puts the clothesline across the pin about a third of the way up
(the wire band), as in the art. Every number below is in "design units" (front prong 1.6 long) and the
finished pin is scaled by PIN_H / 1.6. Kept well under 1,500 triangles for body + outline together (it
is cloned onto every sock): the wood's outline hulls use a one-segment bevel, the wire has no hull.
"""
import math
import bmesh
import bpy
from mathutils import Matrix, Vector
import sockkit as K
from sockkit import M, hexcol
from props.common import *  # noqa: F401,F403 - shared colours (read-only)

NAME = "Clothespin"
EXPORT_DIR = "socks"

# colours sampled from the clothesline pins in the keyframe (side/shadow tones lifted so they land on
# the art's values under the preview's lighting instead of going near-black)
C_WOOD = hexcol("pin_wood", "#EEB063")        # lit face
C_WOOD_L = hexcol("pin_wood_light", "#F4C88E")  # top end, left edge
C_WOOD_M = hexcol("pin_wood_mid", "#C7885F")    # narrow bevel facets, inner faces in the gap
C_WOOD_D = hexcol("pin_wood_side", "#D0765A")   # right side strip, underside (art #84462F in shade)
C_WOOD_S = hexcol("pin_wood_shade", "#9A5A45")  # back prong in the front prong's shadow
C_WIRE = hexcol("pin_wire", "#B9A39B")         # the band (art #B59994)
C_WIRE_D = hexcol("pin_wire_dark", "#7A6876")
C_ARM = hexcol("pin_wire_arm", "#958186")       # the arm: cooler than the band (art #9A8189)
C_ARM_D = hexcol("pin_wire_arm_dark", "#6A5E72")
C_COIL = hexcol("pin_coil", "#72697C")          # the coil: cooler and darker still (art #73667A)
C_COIL_D = hexcol("pin_coil_dark", "#4E4658")

PIN_H = 2.5        # final height in studs (sock scale 1); everything else is in design units
OW = 0.03          # outline width (wood), ~1.9% of the height like the art's ink
WIRE_R = 0.024     # wire radius (art: the light wire is ~2.2% of the pin's height)
WIRE_LINE = 0.028  # ink line each side of the wire: about the wood's weight (art: ink ~ wire width)
WIRE_OUT = WIRE_R + WIRE_LINE  # wire centre to the outside of its ink
INK_OFF = 0.012    # the bands' ink strips sit this far off the wood (~0.04 studs in game at sock scale 2)

W = 0.40           # prong width (X, the face the viewer sees)
H_A = 1.60         # front prong length
H_B = 1.48         # back prong length (its top sits lower in the art)
TILT_A = math.radians(5.0)   # front prong leans left
TILT_B = math.radians(4.0)   # back prong leans right (~0.6 of its top shows beside the front one's)
TOP_A = math.radians(8.0)    # extra cut on the front prong's top end (rises to the right)
BOT_A = math.radians(14.5)   # ... and on its bottom end (rises to the right too, as in the art)
TOP_B = math.radians(20.0)   # back prong's top cut: rises to the right like the front's
BOT_B = TILT_A + BOT_A + TILT_B  # back prong's jaw end: parallel to the front one's
X_A = -0.03        # prong centres at the jaw tips
X_B = -0.045
Y_OUT = 0.19       # outer face distance from the centre plane
BEVEL = 0.035      # every edge
SIDE_BEVEL = 0.10  # the visible right edge (front face -> right side): a deep rounded corner, so the side
                   # strip the art shows is a lit facet (reddish brown) instead of a flat side in shade
BAND_Z0, BAND_K = 0.466, 0.24   # the band (front prong's frame): height at the left edge, slope

# the coil: centre-line semi-axes on screen (the light wire ~0.11 x 0.17 outside, a narrow upright
# loop with a slit of an eye, like the art's "9"), its wire a little thinner than the band's, and its
# centre (front prong's frame) - just past the front prong's right side, in the gap between the
# prongs, where it overlaps the back prong's face from the front; its ink meets the prong's outline
COIL_A, COIL_B, COIL_R = 0.034, 0.080, 0.020
COIL_X, COIL_Y, COIL_Z = W / 2 + 0.062, -0.022, 0.928
COIL_TILT = math.radians(10.0)  # the curl leans right on screen, so the arm runs straight on up into it
COIL_TURN = math.radians(345.0)  # one turn, less a little: the end tucks in beside the arm

TURN = math.radians(-23.0)   # the whole pin is turned a little so its right sides show, as in the art
# screen axes in the build frame (before TURN): right, up, and toward the front viewer
EX = Vector((math.cos(TURN), -math.sin(TURN), 0.0))
EZ = Vector((0.0, 0.0, 1.0))
VIEW = Vector((-math.sin(TURN), -math.cos(TURN), 0.0))


def _profile(h):
    """Side profile (y, z) of the FRONT prong (outer face at -Y_OUT); the back prong mirrors y. The
    outer face runs nearly to the jaw tip (a small chamfer), so the bottom corners read crisp."""
    return [(-Y_OUT, 0.03), (-Y_OUT, h), (-0.05, h), (-0.018, 0.58), (-0.018, 0.34),
            (-0.045, 0.27), (-0.016, 0.20), (-0.008, 0.0), (-0.16, 0.0)]


def _inner_y(z, h):
    """|y| of the front prong's inner face at height z (the profile's inner side)."""
    pts = [(0.0, 0.008), (0.20, 0.016), (0.27, 0.045), (0.34, 0.018), (0.58, 0.018), (h, 0.05)]
    for (z0, y0), (z1, y1) in zip(pts, pts[1:]):
        if z <= z1:
            return y0 + (y1 - y0) * max(0.0, z - z0) / (z1 - z0)
    return pts[-1][1]


def _shear(v, h, top_cut, bot_cut):
    """Both ends cut on a slant rising to the right: top_cut at the top end, bot_cut at the jaws."""
    kt, kb = math.tan(top_cut), math.tan(bot_cut)
    v.z += v.x * (kb + (kt - kb) * v.z / h)


def _prong(h, mirror, mat, name, top_cut, bot_cut, segments, trim=0.0):
    """Profile extruded across the width, both ends cut on a slant (rising to the right), the visible
    right edge rounded deep (SIDE_BEVEL), every other edge bevelled -> world-space mesh. `trim` pulls
    the inner face and the right side in (outline hulls only, see build)."""
    prof = [(-y if mirror else y, z) for y, z in _profile(h)]
    if trim:
        prof = [(y - trim if i in (2, 3, 4, 5, 6) else y, z) for i, (y, z) in enumerate(prof)]
    bm = bmesh.new()
    a = [bm.verts.new((-W / 2, y, z)) for y, z in prof]
    b = [bm.verts.new((W / 2 - 0.7 * trim, y, z)) for y, z in prof]
    n = len(prof)
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((a[i], a[j], b[j], b[i]))
    bm.faces.new(a[::-1])
    bm.faces.new(b)
    # the edge between the face the viewer sees and the right side: the front prong's outer face,
    # the back prong's inner face (the whole way down, so the bevel isn't clamped by the groove)
    bw = bm.edges.layers.float.new("bevel_weight_edge")
    for i, j in ([(2, 3), (3, 4), (4, 5), (5, 6), (6, 7)] if mirror else [(8, 0), (0, 1)]):
        bm.edges.get((b[i], b[j]))[bw] = 1.0
    for v in bm.verts:
        _shear(v.co, h, top_cut, bot_cut)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    obj = bpy.data.objects.new(name, me)
    K.link(obj)
    obj.matrix_world = mat
    side = obj.modifiers.new("side", "BEVEL")
    side.width = SIDE_BEVEL
    side.segments = 2
    side.limit_method = "WEIGHT"
    side.use_clamp_overlap = True
    mod = obj.modifiers.new("bevel", "BEVEL")
    mod.width = BEVEL
    mod.segments = segments
    mod.limit_method = "ANGLE"   # leaves the soft edges of the deep corner alone
    mod.angle_limit = math.radians(30.0)
    mod.use_clamp_overlap = True
    return K.bake_object(obj)


def _inside(p, mat_inv, h, mirror, margin):
    """Is world point p inside (or within `margin` of) a prong? (its local frame, ends ignored)"""
    q = mat_inv @ Vector(p)
    x, y, z = q.x, (-q.y if mirror else q.y), q.z
    if not (-W / 2 - margin < x < W / 2 + margin and -0.05 < z < h + 0.1):
        return False
    if not (-Y_OUT - margin < y < -_inner_y(z, h) + margin):
        return False
    if not mirror and x > W / 2 - SIDE_BEVEL and y < -Y_OUT + SIDE_BEVEL:  # the deep round corner
        cx, cy = W / 2 - SIDE_BEVEL, -Y_OUT + SIDE_BEVEL
        return math.hypot(x - cx, y - cy) < SIDE_BEVEL + margin
    return True


def _bisect(me, co, no):
    bm = bmesh.new()
    bm.from_mesh(me)
    bmesh.ops.bisect_plane(bm, geom=bm.verts[:] + bm.edges[:] + bm.faces[:], dist=1e-5,
                           plane_co=Vector(co), plane_no=Vector(no).normalized())
    bm.to_mesh(me)
    bm.free()
    return me


def _colour_front(n):
    """The front prong: lit face (with its jaw chamfer and the first facet of the deep corner), light
    left edge and top, reddish right side strip; its inner face (seen from behind, in the V) mid."""
    if n.z > 0.6:
        return C_WOOD_L
    if n.y < -0.5:
        return C_WOOD_L if n.x < -0.3 else C_WOOD
    if n.z < -0.6:
        return C_WOOD_D
    if n.x > 0.6:
        return C_WOOD_D              # the right side strip
    if n.x < -0.3:
        return C_WOOD_L              # lit left edge
    return C_WOOD_M


def _colour_back(n, c, shadow_fn):
    """The back prong: seen from the front, its inner face (lit top, shadowed below) and its right side
    strip; seen from behind, its outer face is the same pale wood as the front prong's face, with the
    light edge on the viewer's left (+X) and the side strip on the right (-X)."""
    if n.z > 0.6:
        return C_WOOD_L
    if n.y > 0.8 or (n.y > 0.5 and abs(n.x) < 0.3):
        return C_WOOD                # outer face (and its jaw chamfer)
    if n.y > 0.3:
        return C_WOOD_L if n.x > 0 else C_WOOD_D
    if n.z < -0.6:
        return C_WOOD_D
    if abs(n.x) > 0.6:
        return C_WOOD_D              # side strips (+X seen from the front, -X from behind)
    if n.y < -0.3:
        if shadow_fn(c):
            return C_WOOD_S
        return C_WOOD if n.y < -0.8 else C_WOOD_M
    return C_WOOD_M


LIGHT = Vector((-0.45, -0.55, 0.70)).normalized()


def _poly_tube(pts, radius, pal, outline, name, sides=6, caps=True):
    """A tube swept along a polyline (exact corners where the points say so, no bezier bowing) with
    flat end caps (or open ends); frames are parallel-transported so the tube doesn't twist. `radius`
    is one number or one per point."""
    pts = [Vector(p) for p in pts]
    n = len(pts)
    radii = list(radius) if isinstance(radius, (list, tuple)) else [radius] * n
    tans = []
    for i in range(n):
        d = pts[min(i + 1, n - 1)] - pts[max(i - 1, 0)]
        tans.append(d.normalized())
    nrm = tans[0].cross(Vector((0, 0, 1)))
    if nrm.length < 1e-4:
        nrm = tans[0].cross(Vector((1, 0, 0)))
    nrm.normalize()
    bm = bmesh.new()
    rings = []
    for i, (p, t) in enumerate(zip(pts, tans)):
        nrm = (nrm - t * nrm.dot(t)).normalized()
        bi = t.cross(nrm)
        # mitre: widen the ring across a bend so the tube keeps its thickness at corners
        scale, bend = 1.0, Vector((0, 0, 0))
        if 0 < i < n - 1:
            d0 = (p - pts[i - 1]).normalized()
            d1 = (pts[i + 1] - p).normalized()
            scale = 1.0 / max(0.6, math.sqrt((1 + d0.dot(d1)) / 2))
            bend = d1 - d0
            bend -= t * bend.dot(t)
            if bend.length > 1e-6:
                bend.normalize()
        ring = []
        for k in range(sides):
            ang = math.tau * k / sides
            off = nrm * math.cos(ang) + bi * math.sin(ang)
            ring.append(bm.verts.new(p + off * radii[i] * (1.0 + (scale - 1.0) * abs(off.dot(bend)))))
        rings.append(ring)
    for i in range(n - 1):
        r0, r1 = rings[i], rings[i + 1]
        for k in range(sides):
            k1 = (k + 1) % sides
            bm.faces.new((r0[k], r0[k1], r1[k1], r1[k]))
    if caps:
        bm.faces.new(rings[0][::-1])
        bm.faces.new(rings[-1])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    return K.Piece(me, pal, outline=outline, smooth=True, name=name)


def _wire_body(points, name, arm_from=None, coil_from=None, sides=6, radii=None):
    """The wire itself (no hull: its ink is the strips below). Segments from `arm_from` on take the
    arm's cooler tones, from `coil_from` on the coil's. Every facet that faces the viewer is the light
    tone; only the underside (and the far side) goes dark, so the light wire is as wide as the art's."""
    body = _poly_tube(points, radii or WIRE_R, C_WIRE, False, name, sides)
    pals = []
    n_side = (len(points) - 1) * sides
    for i, f in enumerate(body.mesh.polygons):
        seg = i // sides if i < n_side else (0 if i == n_side else len(points))
        n = Vector(f.normal)
        lit = n.z > -0.6 and (n.dot(VIEW) > -0.2 or n.dot(LIGHT) > 0.3)
        if coil_from is not None and seg >= coil_from:
            pals.append(C_COIL if lit else C_COIL_D)
        elif arm_from is not None and seg >= arm_from:
            pals.append(C_ARM if lit else C_ARM_D)
        else:
            pals.append(C_WIRE if lit else C_WIRE_D)
    body.face_pal = pals
    return body


def _ribbon(pts, normals, name):
    """A flat strip of ink lying on the wood under a band, as wide as the wire plus its two ink lines:
    painted on, so the lines hug the wire from every angle (an inflated hull floats off the face with
    the wire and parts from it in low and side views). pts are on the surface, normals point out of it;
    one-sided, facing out."""
    bm = bmesh.new()
    rows, n = [], len(pts)
    for i in range(n):
        p, nr = Vector(pts[i]), Vector(normals[i]).normalized()
        d = Vector(pts[min(i + 1, n - 1)]) - Vector(pts[max(i - 1, 0)])
        w = nr.cross(d).normalized() * WIRE_OUT
        q = p + nr * INK_OFF
        rows.append((bm.verts.new(q + w), bm.verts.new(q - w), nr))
    for i in range(n - 1):
        (a0, a1, na), (b0, b1, _) = rows[i], rows[i + 1]
        f = bm.faces.new((a0, b0, b1, a1))
        f.normal_update()
        if f.normal.dot(na) < 0:
            f.normal_flip()
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    return K.Piece(me, K.OUTLINE, outline=False, smooth=False, name=name)


def _view_ribbon(pts, name, solid, extend=0.0, radii=None, first_dir=None, lift_n=None):
    """The ink of the arm and the curl: a flat strip through the wire's centre line, facing the front
    viewer (VIEW), WIRE_LINE wider than the wire on each side - so from the front the ink is even on
    both sides of the wire whatever lies behind it. The wire hides its middle. Where an edge of the
    strip would sink into the wood (the arm crosses the side strip close to it), that edge is lifted
    straight toward the viewer until it is clear (`solid(p)`), which leaves it where it was on screen.
    `extend` runs the strip on past the last point (ink round the wire's end); `radii` = the wire's
    radius at each point; `first_dir` squares the first row to that direction (to butt up against the
    band's ink strip); only the first `lift_n` rows are lifted (the curl's ink tucks under the prong's
    outline instead: lifted, it would swing out sideways in 3/4 views). One-sided."""
    pts = [Vector(p) for p in pts]
    radii = list(radii) if radii else [WIRE_R] * len(pts)
    if extend:
        pts.append(pts[-1] + (pts[-1] - pts[-2]).normalized() * extend)
        radii.append(radii[-1])
    n = len(pts)
    bm = bmesh.new()
    rows = []
    for i in range(n):
        p = pts[i]
        d = pts[min(i + 1, n - 1)] - pts[max(i - 1, 0)]
        if i == 0 and first_dir is not None:
            d = Vector(first_dir)
        w = VIEW.cross(d).normalized()
        r = radii[i]
        scale = 1.0
        if 0 < i < n - 1:   # mitre, measured on screen
            d0 = pts[i] - pts[i - 1]
            d1 = pts[i + 1] - pts[i]
            d0 = (d0 - VIEW * d0.dot(VIEW)).normalized()
            d1 = (d1 - VIEW * d1.dot(VIEW)).normalized()
            scale = 1.0 / max(0.7, math.sqrt((1 + d0.dot(d1)) / 2))
        row = []
        for f in (-(r + WIRE_LINE) * scale, -0.95 * r, 0.95 * r, (r + WIRE_LINE) * scale):
            q = p + w * f
            if abs(f) > r and (lift_n is None or i < lift_n):
                for _ in range(40):
                    if not solid(q):
                        break
                    q = q + VIEW * 0.003
            row.append(bm.verts.new(q))
        rows.append(row)
    for i in range(n - 1):
        for j in range(3):
            f = bm.faces.new((rows[i][j], rows[i + 1][j], rows[i + 1][j + 1], rows[i][j + 1]))
            f.normal_update()
            if f.normal.dot(VIEW) < 0:
                f.normal_flip()
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    return K.Piece(me, K.OUTLINE, outline=False, smooth=False, name=name)


def _coil(centre, th0, th1, steps=16):
    """The spring's curl, facing the viewer, drawn like the art's "9": the arm runs straight on up into
    the right side of a narrow upright oval, over the top, down the left side and round the bottom,
    spiralling in a little to end inside, against the arm - so the hole left in the middle is a slit
    of a dark eye. `centre` is the curl's centre (build frame); angles counter-clockwise from the right
    as seen from the front. Returns the points from th0 (exclusive) to th1."""
    c, sn = math.cos(COIL_TILT), math.sin(COIL_TILT)
    pts = []
    for i in range(1, steps + 1):
        t = i / steps
        s = 1.0 - 0.3 * max(0.0, (t - 0.6) / 0.4) ** 1.5    # inward over the last part
        th = th0 + t * (th1 - th0)
        u, v = COIL_A * s * math.cos(th), COIL_B * s * math.sin(th)
        pts.append(centre + EX * (u * c + v * sn) + EZ * (-u * sn + v * c))
    return pts


def _eye(centre, name, seg=10):
    """The dark eye inside the curl: an oval of ink behind the wire (at its centre line, so the wire
    covers its edge), facing the viewer, like the art's dark slit in the "9". One-sided."""
    c, sn = math.cos(COIL_TILT), math.sin(COIL_TILT)
    bm = bmesh.new()
    vs = []
    for i in range(seg):
        th = math.tau * i / seg
        u, v = COIL_A * 0.9 * math.cos(th), COIL_B * 0.9 * math.sin(th)
        vs.append(bm.verts.new(centre + EX * (u * c + v * sn) + EZ * (-u * sn + v * c)))
    f = bm.faces.new(vs)
    f.normal_update()
    if f.normal.dot(VIEW) < 0:
        f.normal_flip()
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    return K.Piece(me, K.OUTLINE, outline=False, smooth=False, name=name)


def _coil_pt(centre, th):
    c, sn = math.cos(COIL_TILT), math.sin(COIL_TILT)
    u, v = COIL_A * math.cos(th), COIL_B * math.sin(th)
    return centre + EX * (u * c + v * sn) + EZ * (-u * sn + v * c)


def _band_path(x_left, x_right, bevel_l, bevel_r, z_of, y_face, sgn, tail_l=0.0, tail_r=0.0):
    """Surface points (x, y, z) and outward normals of a wire band across a prong's face at y_face
    (sgn = -1: the face looks to -Y), round the bevels at both edges (bevel_l / bevel_r: the radius of
    each edge's rounding) and, with tails, a little way onto the sides."""
    c45, c11, s11 = math.sqrt(0.5), math.cos(math.radians(11.25)), math.sin(math.radians(11.25))
    out = []
    if tail_l:
        out.append(((x_left, y_face - sgn * (bevel_l + tail_l)), (-1.0, 0.0)))
        out.append(((x_left, y_face - sgn * bevel_l), (-1.0, 0.0)))
    out += [((x_left + bevel_l * (1 - c45), y_face - sgn * bevel_l * (1 - c45)), (-c45, sgn * c45)),
            ((x_left + bevel_l, y_face), (-s11, sgn * c11))]
    out += [((x_right - bevel_r, y_face), (s11, sgn * c11)),
            ((x_right - bevel_r * (1 - c45), y_face - sgn * bevel_r * (1 - c45)), (c45, sgn * c45))]
    if tail_r:
        out.append(((x_right, y_face - sgn * bevel_r), (1.0, 0.0)))
        out.append(((x_right, y_face - sgn * (bevel_r + tail_r)), (1.0, 0.0)))
    return [((x, y, z_of(x)), (nx, ny, 0.0)) for (x, y), (nx, ny) in out]


def build():
    ma = M((X_A, 0, 0), (0, -TILT_A, 0))
    mb = M((X_B, 0, 0), (0, TILT_B, 0))
    ma_inv, mb_inv = ma.inverted(), mb.inverted()
    rot_a, rot_b = ma.to_3x3(), mb.to_3x3()

    def a_pt(x, y, z):
        return ma @ Vector((x, y, z))

    # front prong (bevel 2 for the body, 1 for its outline hull - nobody sees the difference). Seen
    # turned, the hull's inner face would show past the right side as well as its side, an ink seam
    # between the prongs ~1.4x the outer line - its inner face and right side are pulled in a little
    # so the seam matches the outline, as in the art
    me_a = _prong(H_A, False, ma, "pinA", TOP_A, BOT_A, 2)
    me_a.update()
    a = K.Piece(me_a, [_colour_front(Vector(f.normal)) for f in me_a.polygons], outline=False, smooth=False,
                name="pinA")
    a_hull = K.Piece(_prong(H_A, False, ma, "pinA_hull", TOP_A, BOT_A, 1, trim=0.012), C_WOOD, outline=True,
                     name="pinA_hull")

    # back prong: its face is in the front prong's shadow below a shallow slanted line (art: the top
    # third lit across its full width, down to about the coil's top)
    s0 = a_pt(W / 2 + 0.02, 0, 1.12)
    sdir = Vector((0.3, 0, -0.12)).normalized()
    sno = Vector((sdir.z, 0, -sdir.x))  # perpendicular in XZ, pointing up-right
    if sno.z < 0:
        sno = -sno
    me_b = _prong(H_B, True, mb, "pinB", TOP_B, BOT_B, 2)
    _bisect(me_b, s0, sno)
    me_b.update()
    b = K.Piece(me_b, [_colour_back(Vector(f.normal), Vector(f.center), lambda c: (c - s0).dot(sno) < 0)
                       for f in me_b.polygons], outline=False, smooth=False, name="pinB")
    b_hull = K.Piece(_prong(H_B, True, mb, "pinB_hull", TOP_B, BOT_B, 1), C_WOOD, outline=True, name="pinB_hull")

    def solid(p):
        return _inside(p, ma_inv, H_A, False, 0.006) or _inside(p, mb_inv, H_B, True, 0.006)

    # ---- the wire. The band's path ON the front face (A's frame) with the surface normal there: from
    # the middle of the left bevel (on the silhouette from the front), across the face, round the first
    # facet of the deep right corner to where the side strip starts - there the arm leaves the wood
    band_z = lambda x: BAND_Z0 + (x + W / 2) * BAND_K
    on = _band_path(-W / 2, W / 2, BEVEL, SIDE_BEVEL, band_z, -Y_OUT, -1)
    on.insert(2, ((-0.012, -Y_OUT, band_z(-0.012)), (0.0, -1.0, 0.0)))   # the break in the band
    on.insert(3, ((0.004, -Y_OUT, band_z(0.004)), (0.0, -1.0, 0.0)))
    centre = [tuple(Vector(p) + Vector(n) * INK_OFF) for p, n in on]   # the wire half sunk in its ink
    ink = _ribbon([tuple(a_pt(*p)) for p, n in on], [tuple(rot_a @ Vector(n)) for p, n in on], "pinBandInk")

    # the curl's centre (build frame), facing the viewer
    cc = a_pt(COIL_X, COIL_Y, COIL_Z)
    th0 = math.radians(-20.0)                   # the arm runs on up into the coil's right side
    join = _coil_pt(cc, th0)
    coil = _coil(cc, th0, th0 + COIL_TURN)

    # the arm, in A's frame: from the band's end a short knee up and to the right, as in the art, then
    # steeply on up to the curl in one straight line (straight in 3D, so it stays straight on screen
    # from any distance); it leaves the wood's corner and runs back over the side strip to the curl
    cos_t, sin_t = math.cos(TURN), math.sin(-TURN)   # screen x = x * cos_t + y * sin_t (A's frame)
    sx = lambda p: p[0] * cos_t + p[1] * sin_t
    start = centre[-1]
    join_a = ma_inv @ join
    knee_sx, knee_z, knee_y = sx(start) + 0.035, start[2] + 0.035, -0.16
    knee = Vector(((knee_sx - knee_y * sin_t) / cos_t, knee_y, knee_z))
    p_a, mid = tuple(knee.lerp(join_a, 0.3)), tuple(knee.lerp(join_a, 0.62))
    knee = tuple(knee)

    # the band is drawn in two pieces with a small break (its ink strip shows through), as on every
    # pin in the art; the left piece's tip sits on the silhouette, a small light tick in the outline
    wire0 = _wire_body([tuple(a_pt(*p)) for p in centre[:3]], "pinWireEnd")
    loc = [tuple(a_pt(*p)) for p in centre[3:] + [knee, p_a, mid]] + [tuple(join)]
    arm_from, coil_from = len(loc) - 5, len(loc) - 1
    radii = [WIRE_R] * len(loc) + [COIL_R] * len(coil)
    wire = _wire_body(loc + [tuple(p) for p in coil], "pinWire", arm_from=arm_from, coil_from=coil_from,
                      radii=radii)
    band_dir = a_pt(*on[-1][0]) - a_pt(*on[-2][0])
    arm_ink = _view_ribbon([Vector(p) for p in loc[-5:]] + coil, "pinArmInk", solid, extend=WIRE_LINE * 0.6,
                           radii=radii[-(5 + len(coil)):], first_dir=band_dir, lift_n=5)
    eye = _eye(cc, "pinCoilEye")

    # the same band round the back prong's outer face (seen from behind), across its full width and
    # over both its edges: round the -X one onto that side, into the bevel of the +X one
    kb =math.tan(TILT_A + math.atan(BAND_K) + TILT_B)    # parallel to the front band in the world
    zb0 = (mb_inv @ a_pt(0.0, -Y_OUT, band_z(0.0))).z   # level with the front band in the middle
    bz = lambda x: zb0 + x * kb
    back_on = _band_path(-W / 2, W / 2, BEVEL, BEVEL, bz, Y_OUT, 1, tail_l=0.03)
    # (its +X end dives into the bevel on the silhouette, so from the front no wire end pokes out)
    back_c = [Vector(p) + Vector(n) * INK_OFF for p, n in back_on]
    back_c[-1] = Vector(back_on[-1][0]) - Vector(back_on[-1][1]) * WIRE_R
    wire2 = _wire_body([tuple(mb @ c) for c in back_c], "pinWireBack")
    ink2 = _ribbon([tuple(mb @ Vector(p)) for p, n in back_on], [tuple(rot_b @ Vector(n)) for p, n in back_on],
                   "pinBandInkBack")

    pieces = [a, b, wire, wire0, wire2, ink, arm_ink, eye, ink2]
    hulls = [a_hull, b_hull]
    # origin at the lowest jaw tip
    z_min = min(v.co.z for p in (a, b) for v in p.mesh.vertices)
    S = PIN_H / H_A  # design units -> studs, then the art's slight turn
    turn = Matrix.Diagonal((S, S, S, 1.0)) @ Matrix.Rotation(TURN, 4, "Z") @ Matrix.Translation((0, 0, -z_min))
    for p in pieces + hulls:
        p.mesh.transform(turn)
        p.mesh.update()
    body, outline = K.finish(pieces, NAME, outline_width=OW * S, outline_only=hulls)
    body.visible_shadow = False  # the game turns CastShadow off on every clothespin part
    return [body, outline] + K.markers(NAME)
