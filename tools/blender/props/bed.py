"""
props/bed.py - the Bed prop (ReplicatedStorage.MapMeshes.Bed). See props/__init__.py for
the conventions every prop follows.

Concept (docs/concept/bedroom_keyframe.png, seen there from the foot end): a chunky cartoon
wooden bed - four thick turned posts, each with a rounded shoulder, a collar ring and a BIG ball
finial; SOLID arched headboard and footboard panels (no slats); a thick side rail; a white
mattress with soft rounded edges and puffy white pillows with pinched corner points; a thick
slate-blue blanket with bold red stripes and a thin light line between them, hanging down the
front almost to the floor (only a thin strip of the tall side board shows under its hem); its head
end is turned down over itself as a thick, soft pale-blue roll (the lit fold in the art, between
the pillows and the stripes) that lies on top of the stripes and casts a darker band onto them.
At the head end, under the fold's rounded hem corner, the side board is a tall solid plank under a
white mattress band almost as tall.
Wood is 2-3 flat tones: lighter on top-facing faces and a lit strip along the top of the headboard /
footboard (the art's lit top edges), darker undersides; the panels are a deeper red-brown than the
posts.
Lived-in dressing (players look down on it from the play area): two plump pillows side by side
leaning on the headboard, a little pink plush bunny sitting on the fold and leaning on them, two
socks lying on the blanket, soft lumps in the blanket top and gentle vertical folds in the drape.

Game layout: the long side stands against the north wall, outside the play area; the front (-Y)
faces the room. Head end at -X (tall posts, next to the nightstand), foot end at +X (lower posts).
Map.luau fits it into 290 x 110 x 140 studs, so the model is a real single bed of about
29 x 11 x 14 units (length X : height Z : depth Y). Origin = floor centre.
"""
import math
import bmesh
import bpy
from mathutils import Matrix, Vector
import sockkit as K
from sockkit import M, hexcol
from props.common import *  # noqa: F401,F403 - shared colours (read-only)

NAME = "Bed"

# texture classes for tools/blender/texturing.py where the colour names alone guess wrong
MATERIALS = {"bed_cuff": "fabric"}  # the turned-down blanket fold, not a sock cuff

# colours sampled from the keyframe (lit areas), nudged to albedo where the night light tints them
POST = hexcol("bed_post", "#CF703D")         # posts and finials: warm orange-brown
POST_L = hexcol("bed_post_light", "#EA9454")  # top-facing faces (lit top edges)
POST_D = hexcol("bed_post_dark", "#94482D")   # undersides
# headboard / footboard: clearly a deeper red-brown than the posts (art: panels #883A2B-#AF4D2D vs
# posts #C05F42-#D26730, ~25% darker), with a lit strip along the arched top that still pops
PANEL = hexcol("bed_panel", "#A04A32")
PANEL_L = hexcol("bed_panel_light", "#D27449")
PANEL_D = hexcol("bed_panel_dark", "#7A3826")
SHEET = hexcol("bed_sheet", "#F6F2EA")        # mattress / pillow top
SHEET_S = hexcol("bed_sheet_side", "#E3DDE3")
SHEET_D = hexcol("bed_sheet_dark", "#C4BCCD")  # lavender shadow under the pillow / mattress
BL = hexcol("bed_blanket", "#5A6B9E")          # slate blue (drape)
BL_T = hexcol("bed_blanket_top", "#6879AD")    # blanket top (lit)
BL_LINE = hexcol("bed_blanket_line", "#7385B8")  # thin light line between the red stripes
BL_D = hexcol("bed_blanket_hem", "#4F5E90")    # hem underside / inside: only a slight darkening
BL_SH = hexcol("bed_blanket_shade", "#46507C")  # shadow the fold casts on the stripes
RD = hexcol("bed_stripe", "#E04840")         # vivid enough to hold up under the bluish night light
RD_T = hexcol("bed_stripe_top", "#E85246")
RD_D = hexcol("bed_stripe_hem", "#C63E37")
RD_SH = hexcol("bed_stripe_shade", "#B0322D")
CUFF = hexcol("bed_cuff", "#9DB2DC")           # pale-blue lining of the turned-down fold
CUFF_T = hexcol("bed_cuff_top", "#B6C8EA")
RAIL = hexcol("bed_rail", "#A04C31")          # side rails sit in the shadow of the mattress
# the plush bunny: soft pink with a cream tummy, rose inner ears / nose / cheeks
BUN = hexcol("bed_bunny", "#F2AFC2")
BUN_L = hexcol("bed_bunny_light", "#FBCCD8")
BUN_D = hexcol("bed_bunny_dark", "#D1879E")
BUN_BELLY = hexcol("bed_bunny_belly", "#FFE4EA")
BUN_IN = hexcol("bed_bunny_inner", "#E6728F")
BUN_EYE = hexcol("bed_bunny_eye", "#2A1A2C")
# socks lying on the blanket (body, lit top, heel/toe patch, lit patch, cuff, cuff rib, inside)
SOCK_Y = tuple(hexcol("bed_sock_y" + k, v) for k, v in (
    ("", "#F5BF3A"), ("_top", "#FFD764"), ("_patch", "#EC7434"), ("_patch_top", "#FF9150"),
    ("_cuff", "#FFF0C4"), ("_rib", "#EBD69A"), ("_in", "#7A3F22")))
SOCK_G = tuple(hexcol("bed_sock_g" + k, v) for k, v in (
    ("", "#55C07E"), ("_top", "#7AD99B"), ("_patch", "#2D8A70"), ("_patch_top", "#3AA585"),
    ("_cuff", "#E2F7E8"), ("_rib", "#BEE6CB"), ("_in", "#1C4A3A")))

# ---------------------------------------------------------------- dimensions (units)
LEN = 29.0                  # overall X
DEP = 14.0                  # overall Y: a real single bed (was a 8.6-deep bench)
R = 1.2                     # post radius: fat columns, ~0.9 of the ball width
RB = 1.35                   # ball finial radius (X/Y); squashed a little in Z
BALL_SQ = 0.85              # balls a little squashed (art: height / width ~0.8-0.87)
XP = LEN / 2 - RB           # post centres
YP = DEP / 2 - RB
COLLAR_H = 0.46
BALL_SINK = 0.1             # how far the ball sits down into its collar
HEAD_TOP, FOOT_TOP = 11.0, 9.5          # ball tops: foot posts ~86% of the head posts (the hero column)
POST_SEG = 14               # segments round the posts, collars and balls


def _post_height(top):
    """post body height (shoulder top) so that the ball top lands on `top`"""
    return top - (COLLAR_H - 0.06) - 2 * RB * BALL_SQ + BALL_SINK


# the side rail is a tall solid board reaching almost to the floor (a thin shadow gap under it); at
# the head end the white mattress band above it is ~0.83x as tall as the wood band (art ~0.85)
RAIL_Z0, RAIL_Z1, RAIL_T = 0.25, 2.55, 0.62
MAT_Z0, MAT_Z1 = 2.1, 4.45
MAT_HY = YP + 0.26          # mattress side sits 0.05 behind the rail face (no z-fighting where they meet)
MAT_BEVEL = 0.65            # soft, rounded mattress edge
DRAPE_Z = 1.05               # bottom of the striped drape; its flattened hem bottoms out HEM_DEPTH lower,
HEM_DEPTH = 0.15             # ~8.5% of the head-post height above the floor, as in the art
PALE_Z = 0.97                # the pale fold hangs a touch lower: it covers the stripes' hidden head end
RC = 0.85                    # radius of the cloth's roll over the mattress edge
CLOTH_ZT = MAT_Z1 + 0.05     # cloth profile height on top of the mattress (before the bow)
BOW = 0.16                   # the cloth top bows up a little toward the middle
BL_IN, BL_OUT = -0.06, 0.55  # blanket thickness: inner surface 0.06 above the profile, outer 0.55
FOLD_IN, FOLD_OUT = 0.03, 0.8  # the turned-down fold: a thicker, softer roll on top of the stripes
# blanket layout along X
FOLD_X0, FOLD_XF = -9.05, -5.15   # the turned-down fold: head end (under the pillows' front edge) / free edge
BL_X1 = XP - 0.42                 # blanket foot end (inside the foot posts)
# lived-in lumps in the blanket top: (x, y, sx, sy, height) soft gaussian humps
LUMPS = ((-0.4, 1.3, 3.4, 2.6, 0.42), (6.4, -1.0, 2.8, 3.0, 0.32), (11.0, 2.2, 2.0, 2.2, 0.18))
DRAPE_FOLD = 0.3                  # depth of the drape's soft vertical folds at the hem
STRIPE = (2.55, 0.92, 0.14)       # blanket stripes: target period, red width, light line width


# ---------------------------------------------------------------- helpers
def _tone(piece, base, light=None, dark=None, up=0.6, down=-0.55):
    """flat toon shading: top-facing faces `light`, undersides `dark`, everything else `base`"""
    pals = []
    for f in piece.mesh.polygons:
        nz = f.normal.z
        if light is not None and nz > up:
            pals.append(light)
        elif dark is not None and nz < down:
            pals.append(dark)
        else:
            pals.append(base)
    piece.face_pal = pals
    return piece


def _outward(bm):
    """recalc normals, then make sure the closed shell faces OUT (signed volume > 0) - the inverted-
    hull outline and Roblox back-face culling both depend on it"""
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    vol = 0.0
    for f in bm.faces:
        v = [l.vert.co for l in f.loops]
        for k in range(1, len(v) - 1):
            vol += v[0].dot(v[k].cross(v[k + 1]))
    if vol < 0:
        bmesh.ops.reverse_faces(bm, faces=bm.faces)


def _lathe(profile, loc, seg=18, name="lathe"):
    """surface of revolution around Z: profile = [(radius, z)], bottom to top; r == 0 closes the end"""
    bm = bmesh.new()
    cx, cy, cz = loc
    pts = list(profile)
    bot = top = None
    if pts[0][0] == 0:
        bot = bm.verts.new((cx, cy, cz + pts[0][1]))
        pts = pts[1:]
    if pts[-1][0] == 0:
        top = bm.verts.new((cx, cy, cz + pts[-1][1]))
        pts = pts[:-1]
    rings = []
    for r, z in pts:
        rings.append([bm.verts.new((cx + r * math.cos(i / seg * math.tau), cy + r * math.sin(i / seg * math.tau), cz + z))
                      for i in range(seg)])
    for a, b in zip(rings, rings[1:]):
        for i in range(seg):
            j = (i + 1) % seg
            bm.faces.new((a[i], a[j], b[j], b[i]))
    if bot is not None:
        for i in range(seg):
            bm.faces.new((bot, rings[0][(i + 1) % seg], rings[0][i]))
    if top is not None:
        for i in range(seg):
            bm.faces.new((top, rings[-1][i], rings[-1][(i + 1) % seg]))
    _outward(bm)
    return K.Piece(K._bm_to_mesh(bm, name), 0, True, True, name)


def _arc(cy, cz, r, a0, a1, n):
    """points on a circle arc (angles in degrees, inclusive)"""
    return [(cy + r * math.cos(math.radians(a0 + (a1 - a0) * i / n)),
             cz + r * math.sin(math.radians(a0 + (a1 - a0) * i / n))) for i in range(n + 1)]


def _smooth01(t):
    t = min(1.0, max(0.0, t))
    return t * t * (3 - 2 * t)


def _post(x, y, top, name):
    """turned corner post: base bead, straight shaft, rounded shoulder, collar ring, big ball"""
    h = _post_height(top)
    shoulder = [(0.55 * R + 0.45 * R * math.cos(math.radians(a)), h - 0.5 * R + 0.5 * R * math.sin(math.radians(a)))
                for a in (0, 45, 90)]
    prof = [(0, 0), (1.06 * R, 0), (1.08 * R, 0.5), (R, 0.66)] + shoulder + [(0, h)]
    body = _tone(_lathe(prof, (x, y, 0), seg=POST_SEG, name=name), POST, POST_L, POST_D, up=0.75)
    collar = [(0, 0), (0.6 * R, 0), (0.76 * R, 0.1), (0.76 * R, COLLAR_H - 0.1), (0.6 * R, COLLAR_H), (0, COLLAR_H)]
    ring = _tone(_lathe(collar, (x, y, h - 0.06), seg=POST_SEG, name=name + "_collar"), POST, POST_L, POST_D)
    bz = h - 0.06 + COLLAR_H + RB * BALL_SQ - BALL_SINK
    ball = _tone(K.sphere(POST, RB, M((x, y, bz), scale=(1, 1, BALL_SQ)), seg=POST_SEG, rings=9, name=name + "_ball"),
                 POST, POST_L, POST_D, up=0.62, down=-0.72)
    return [body, ring, ball]


def _arch_panel(x, half, zb, ze, zp, thick, power, name, n=14, bevel=0.2, band=0.22):
    """solid panel in the YZ plane, centred on x, spanning y = +-half (the post centres): flat
    bottom at zb, arched top that is zp in the middle and ze where it meets the post surfaces
    (|y| = half - R) - kept below the posts' rounded shoulders; `power` 2 = round arch, more = flatter
    top with rounder ends. Both big faces carry a lighter strip `band` tall that follows the arch just
    under the rounded top edge (the art's lit top line)."""
    def top(y):
        return zp - (zp - ze) * min(1.0, abs(y) / (half - R)) ** power

    ys = [half * (1 - 2 * i / n) for i in range(n + 1)]
    drop = bevel + band  # the strip's lower edge, measured down from the top
    outline = [(-half, zb), (half, zb)] + [(y, top(y)) for y in ys]
    inner = [(y, top(y) - drop) for y in ys]
    bm = bmesh.new()
    rims = []
    for sx in (x - thick / 2, x + thick / 2):
        ov = [bm.verts.new((sx, y, z)) for y, z in outline]
        iv = [bm.verts.new((sx, y, z)) for y, z in inner]
        # main face: bottom corners + the inner (lowered) arch; then the strip of quads above it
        bm.faces.new([ov[0], ov[1]] + iv)
        for i in range(n):
            bm.faces.new((ov[2 + i], ov[3 + i], iv[i + 1], iv[i]))
        # perimeter, including the strip's end points on the two vertical sides (no T-junctions)
        rims.append([ov[0], ov[1], iv[0]] + ov[2:] + [iv[-1]])
    fo, bo = rims
    m = len(fo)
    for i in range(m):
        j = (i + 1) % m
        bm.faces.new((fo[i], bo[i], bo[j], fo[j]))
    _outward(bm)
    me = K._bm_to_mesh(bm, name)
    obj = bpy.data.objects.new(name, me)
    K.link(obj)
    mod = obj.modifiers.new("bevel", "BEVEL")
    mod.width = bevel
    mod.segments = 2
    mod.limit_method = "ANGLE"
    mod.angle_limit = math.radians(35)
    p = K.Piece(K.bake_object(obj), PANEL, True, True, name)
    _tone(p, PANEL, PANEL_L, PANEL_D, up=0.25)

    def strip(c, cur):  # the flat-face strip under the arch (any face whose centre lies in it)
        return PANEL_L if cur == PANEL and c.z > top(c.y) - drop - 0.01 else cur
    return K.recolor_by(p, strip)


def _offset(poly, d):
    """offsets an open (y, z) polyline by d along its left-hand normal (outward for our profile)"""
    out = []
    n = len(poly)
    for i in range(n):
        y0, z0 = poly[max(i - 1, 0)]
        y1, z1 = poly[min(i + 1, n - 1)]
        dy, dz = y1 - y0, z1 - z0
        ln = math.hypot(dy, dz) or 1.0
        out.append((poly[i][0] - dz / ln * d, poly[i][1] + dy / ln * d))
    return out


def _sheet(outer, t_in, t_out, xs, pal_fn, name, taper=None, hem_depth=HEM_DEPTH, inner_idx=None):
    """A thick cloth sheet: the (y, z) profile `outer` (front-bottom -> over the top -> back-bottom;
    a list, or a function x -> list with the same point count, e.g. a hem that rises toward a rounded
    corner) thickened by t_out outward / t_in inward (negative t_in = starts above the profile), with
    soft, flattened hems at both ends (half-ellipses at most `hem_depth` deep, so a thick hem reads as
    a rounded edge, not a keel), extruded along X through the cut positions `xs` (cuts = where colours
    may change, e.g. stripes). pal_fn(x_mid, part, nz, z_mid) -> palette index; part is "out", "in",
    "hem" or "end" (the two X end caps); nz = the face normal's z. taper(x) -> 0..1 scales the
    thickness at a cut (the inner surface stays put, the outer one comes down) - rolls an end over.
    inner_idx = the profile points the (hidden) inner surface keeps (first and last included) - saves
    triangles where nobody can see them."""
    hem_n = 3

    def hem(a, b):  # half-ellipse from a to b bulging away from the profile (to the right of a->b)
        my, mz = (a[0] + b[0]) / 2, (a[1] + b[1]) / 2
        r = math.hypot(a[0] - b[0], a[1] - b[1]) / 2 or 1e-6
        uy, uz = (a[0] - my) / r, (a[1] - mz) / r
        wy, wz = uz, -uy
        h = min(r, hem_depth)
        pts = []
        for k in range(1, hem_n):
            t = math.pi * k / hem_n
            pts.append((my + r * math.cos(t) * uy + h * math.sin(t) * wy,
                        mz + r * math.cos(t) * uz + h * math.sin(t) * wz))
        return pts

    def section(x):
        k = 1.0 if taper is None else taper(x)
        prof = outer(x) if callable(outer) else outer
        po = _offset(prof, -t_in + (t_out + t_in) * k)
        pi = _offset(prof, -t_in)
        if inner_idx is not None:
            pi = [pi[i] for i in inner_idx]
        cap_b = hem(po[-1], pi[-1])
        cap_f = hem(pi[0], po[0])
        return po + cap_b + list(reversed(pi)) + cap_f, len(po), len(cap_b), len(pi), len(cap_f)

    loop, n, nb, ni, nf = section(xs[0])
    idx = list(inner_idx) if inner_idx is not None else list(range(n))
    kinds = ["out"] * (n - 1) + ["hem"] * (nb + 1) + ["in"] * (ni - 1) + ["hem"] * (nf + 1)
    L = len(loop)
    bm = bmesh.new()
    loops = [section(x)[0] for x in xs]
    secs = [[bm.verts.new((x, y, z)) for y, z in lp] for x, lp in zip(xs, loops)]
    pals = []
    for s in range(len(xs) - 1):
        a, b = secs[s], secs[s + 1]
        xm = (xs[s] + xs[s + 1]) / 2
        lp = loops[s]
        for i in range(L):
            j = (i + 1) % L
            bm.faces.new((a[i], a[j], b[j], b[i]))
            nz = (lp[j][0] - lp[i][0])  # left normal of the segment, z part = dy
            ln = math.hypot(lp[j][0] - lp[i][0], lp[j][1] - lp[i][1]) or 1.0
            pals.append(pal_fn(xm, kinds[i], nz / ln, (lp[i][1] + lp[j][1]) / 2))
    # end caps: between the outer and the inner profile (each inner segment fans to the outer points it
    # spans), plus the two hem fans
    def ii(q):  # vertex index of the q-th inner point
        return n + nb + (ni - 1 - q)
    for sec, xe, lp in ((secs[0], xs[0], loops[0]), (secs[-1], xs[-1], loops[-1])):
        for q in range(ni - 1):
            bm.faces.new([sec[k] for k in range(idx[q], idx[q + 1] + 1)] + [sec[ii(q + 1)], sec[ii(q)]])
            pals.append(pal_fn(xe, "end", 0.0, lp[idx[q]][1]))
        bm.faces.new([sec[n - 1]] + [sec[n + q] for q in range(nb)] + [sec[ii(ni - 1)]])
        pals.append(pal_fn(xe, "end", 0.0, lp[n - 1][1]))
        bm.faces.new([sec[ii(0)]] + [sec[n + nb + ni + q] for q in range(nf)] + [sec[0]])
        pals.append(pal_fn(xe, "end", 0.0, lp[0][1]))
    _outward(bm)
    me = K._bm_to_mesh(bm, name)
    return K.Piece(me, pals, True, True, name)


def _pillow(center, a, b, h, hb, rot, nu=8, nv=10, pinch=(0.13, 0.1), seam=0.6, name="pillow"):
    """puffy pillow: half-sizes a (X), b (Y); dome height h above / hb below the seam (centre = seam).
    The sides are pulled in (`pinch`) and the dome thins out toward the edges (`seam` exponent: higher
    = sharper seam), so each corner ends in a pinched point like a stuffed pillow's "ears"."""
    bm = bmesh.new()
    vt = {}

    def vert(i, j, side):
        edge = i in (0, nu) or j in (0, nv)
        key = (i, j, 0 if edge else side)
        if key not in vt:
            u = math.sin(math.pi / 2 * (-1 + 2 * i / nu))  # denser near the edges, where it curves most
            v = math.sin(math.pi / 2 * (-1 + 2 * j / nv))
            x = a * u * (1 - pinch[0] * (1 - v * v))
            y = b * v * (1 - pinch[1] * (1 - u * u))
            f = max(0.0, (1 - u * u) * (1 - v * v)) ** seam
            z = (h if side > 0 else hb) * side * f
            vt[key] = bm.verts.new((x, y, z))
        return vt[key]

    for side in (1, -1):
        for i in range(nu):
            for j in range(nv):
                q = [vert(i, j, side), vert(i + 1, j, side), vert(i + 1, j + 1, side), vert(i, j + 1, side)]
                bm.faces.new(q if side == 1 else list(reversed(q)))
    _outward(bm)
    bmesh.ops.transform(bm, matrix=M(center, rot), verts=bm.verts)
    p = K.Piece(K._bm_to_mesh(bm, name), SHEET, True, True, name)
    return _tone(p, SHEET_S, SHEET, SHEET_D, up=0.5, down=-0.35)


# ---------------------------------------------------------------- cloth
def _bow(y):
    return BOW * max(0.0, 1 - (y / (MAT_HY + 0.08)) ** 2)


def _cloth_profile(drape_z, back_z, flare):
    """(y, z) profile of a cloth layer over the mattress: front hem -> up the front drape (flaring out a
    little toward the hem) -> round the mattress edge (5-segment arc: a soft, puffy roll)
    -> over a slightly bowed top (4 points: room for the lumps) -> down the back (2 segments: that
    side faces the wall). 16 points;
    CLOTH_INNER lists the ones the hidden inner surface keeps."""
    yf, yb, zt, rc = -(MAT_HY + 0.08), MAT_HY + 0.08, CLOTH_ZT, RC
    za = zt - rc  # where the rounded mattress edge starts

    def fy(z):
        return yf - flare * ((za - z) / (za - drape_z)) ** 1.5
    zm = (drape_z + za) / 2
    tops = [-3.7, -1.25, 1.25, 3.7]
    return ([(fy(drape_z), drape_z), (fy(zm), zm)]
            + _arc(yf + rc, za, rc, 180, 90, 5)
            + [(y, zt + _bow(y)) for y in tops]
            + _arc(yb - rc, za, rc, 90, 0, 2)
            + [(yb, back_z)])


CLOTH_INNER = [0, 1, 2, 4, 7, 9, 10, 12, 14, 15]
CLOTH_ZA = CLOTH_ZT - RC          # where the cloth's roll over the mattress edge starts
BACK_Z = MAT_Z1 - 1.55            # how far the cloth hangs down the back (wall) side


def _fold(x0, xf):
    """The blanket's head end turned down over itself: a thick, soft roll of pale-blue lining lying ON
    TOP of the stripes' head end (it encloses their hidden end and stands ~0.25 proud of their surface,
    as high as the stripes or a little higher, like the art). Its +X free edge rolls over (quarter
    round: the art's inked edge, with the shadow band on the stripes past it), its head end creases
    down softly onto the mattress, the front drape flares out toward -X near the hem and the hem corner
    at the head end is rounded."""
    roll0, roll1 = 0.6, 0.55    # crease at the head end / rolled free edge
    rc0, rc1 = 0.6, 0.4         # hem corner radii (head end / free edge)
    flx, span = 0.6, 2.2        # the drape flares out toward -X by flx at the hem, fading out over span

    def taper(x):
        k = 1.0
        for d, r in ((x - x0, roll0), (xf - x, roll1)):
            if d < r:
                u = max(0.0, d / r)
                k = min(k, math.sqrt(max(0.0, 1 - (1 - u) ** 2)))
        return max(0.12, k)

    def hem_z(x):
        z = PALE_Z
        for d, r in ((x - x0, rc0), (xf - x, rc1)):
            if d < r:
                z += r - math.sqrt(max(0.0, r * r - (r - max(0.0, d)) ** 2))
        return z

    cuts = {x0, xf}
    for a in (30, 60, 90):  # the crease and the head-end hem corner share their cuts
        c = 1 - math.cos(math.radians(a))
        cuts.update((x0 + roll0 * c, xf - roll1 * c))
    xs = sorted(cuts)

    def pal(xm, part, nz, zm):  # lining colour everywhere (no dark inside showing at the hem)
        return CUFF_T if (part == "out" and nz > 0.6) else CUFF

    piece = _sheet(lambda x: _cloth_profile(hem_z(x), BACK_Z - 0.15, 0.16), FOLD_IN, FOLD_OUT, xs, pal, "fold",
                   taper=taper, inner_idx=CLOTH_INNER)
    me = piece.mesh
    for v in me.vertices:
        if v.co.y < 0:
            s = min(1.0, max(0.0, (CLOTH_ZA - v.co.z) / (CLOTH_ZA - PALE_Z))) ** 1.3
            w = min(1.0, max(0.0, 1 - (v.co.x - x0) / span))
            v.co.x -= flx * s * w
    me.update()
    # faces turned toward the head end (the flared drape, the crease) catch the lamp light
    piece.face_pal = [CUFF_T if (f.normal.x < -0.45 and f.normal.z > -0.3) else c
                      for f, c in zip(me.polygons, piece.face_pal)]
    return piece


def _lump(x, y):
    """lived-in lumps in the blanket top (0 under the fold, so fold and stripes stay together)"""
    h = sum(a * math.exp(-((x - cx) / sx) ** 2 - ((y - cy) / sy) ** 2) for cx, cy, sx, sy, a in LUMPS)
    return h * _smooth01((x - FOLD_XF - 0.4) / 1.6)


def blanket_top(x, y):
    """height of the blanket's top surface at (x, y) - things lying on the blanket sit on it"""
    return CLOTH_ZT + _bow(y) + BL_OUT + _lump(x, y)


def _blanket():
    """the striped blanket: hangs down the front (-Y), lumps on top; its head end is hidden under the
    fold. The drape falls in soft vertical folds that follow the stripes: every red stripe bellies
    out (a ridge), the thin light line between two of them sits in the valley - so the folds need no
    extra cuts."""
    xf = FOLD_XF
    x1 = BL_X1
    shade = (xf - 0.25, xf + 0.28)  # the fold casts a darker band onto the stripes past its edge
    period, red_w, line_w = STRIPE
    xs_a, xs_b = shade[1], x1 - 0.35   # stripes evenly spaced from the shadow band to the foot end
    nper = max(1, round((xs_b - xs_a) / period))
    per = (xs_b - xs_a) / nper
    stripes = []  # (start, end, colour kind)
    for k in range(nper):
        e = xs_a + (k + 1) * per
        stripes.append((e - red_w, e, "red"))
        mid = e - red_w - (per - red_w) / 2
        stripes.append((mid - line_w / 2, mid + line_w / 2, "line"))
    xb0 = xf - 0.6              # the striped blanket's head end, hidden under the fold
    cuts = {xb0, x1, shade[1]}  # (shade[0] lies under the fold: no cut needed)
    for s0, s1, _ in stripes:
        cuts.update((s0, s1))
    xs = sorted(c for c in cuts if xb0 <= c <= x1)
    # fold height (0..1) at each cut: red edges out, line edges in; faded out toward both blanket ends
    ridge = {"red": 1.0, "line": 0.0}
    fold_at = []
    for c in xs:
        kind = next((k for s0, s1, k in stripes if abs(c - s0) < 1e-6 or abs(c - s1) < 1e-6), None)
        f = ridge.get(kind, 0.0)
        fold_at.append(f * _smooth01((c - xf - 0.3) / 1.4) * _smooth01((x1 - c) / 0.9))

    def fold(x):  # mesh coordinates are float32: look the cut up by nearest
        i = min(range(len(xs)), key=lambda k: abs(xs[k] - x))
        return fold_at[i]

    def blanket_pal(xm, part, nz, zm):
        kind = next((k for s0, s1, k in stripes if s0 <= xm <= s1), "blue")
        if part in ("in", "hem", "end"):  # hem underside and the inside under the flare: a slight darkening
            return RD_D if kind == "red" else BL_D
        if shade[0] <= xm <= shade[1]:
            return RD_SH if kind == "red" else BL_SH
        top = nz > 0.6
        if kind == "red":
            return RD_T if top else RD
        if kind == "line":
            return BL_LINE
        return BL_T if top else BL

    piece = _sheet(_cloth_profile(DRAPE_Z, BACK_Z, 0.1), BL_IN, BL_OUT, xs, blanket_pal, "blanket",
                   inner_idx=CLOTH_INNER)
    me = piece.mesh
    za = CLOTH_ZA
    for v in me.vertices:
        x, y, z = v.co
        # lumps on top (fade out down the rolled edges)
        w = _smooth01((z - (za - 0.1)) / (CLOTH_ZT - za + 0.1))
        lift = _lump(x, y) * w
        # vertical folds in the front drape, deepest at the hem
        if y < 0 and z < za + 0.2:
            s = min(1.0, max(0.0, (za - z) / (za - DRAPE_Z))) ** 1.2
            f = fold(x)
            v.co.y -= DRAPE_FOLD * s * f
            lift += 0.08 * s ** 3 * f  # a pulled-out fold lifts its hem a little
        v.co.z += lift
    me.update()
    return piece


# ---------------------------------------------------------------- dressing
def _sock(cols, place, rot, name, leg=1.75, foot=1.1, r=0.47, flat=0.5, bend=0.58, seg=8):
    """a sock lying flat on the blanket: a soft tube swept along an L-shaped path (leg straight down,
    a round heel turn, the foot) - squashed to `flat` of its width, a round toe, a recessed dark opening
    at the cuff, a ribbed light cuff band, heel and toe patches. `place` = (x, y) of the opening,
    `rot` = how far the leg is turned from -Y (radians, around Z); it follows the blanket surface."""
    body, body_t, patch, patch_t, cuff, rib, inner = cols
    # path samples: (2D centre, 2D tangent, arc length) in the sock's local plane
    samples = []
    n_leg = 5
    for i in range(n_leg):
        t = i / n_leg * leg
        samples.append(((0.0, -t), (0.0, -1.0), t))
    turn = math.radians(95)
    n_arc = 4
    for i in range(n_arc + 1):
        a = turn * i / n_arc
        c = (bend - bend * math.cos(a), -leg - bend * math.sin(a))
        samples.append((c, (math.sin(a), -math.cos(a)), leg + bend * a))
    (ex, ey), (tx, ty), s_end = samples[-1]
    n_foot = 3
    for i in range(1, n_foot + 1):
        t = foot * i / n_foot
        samples.append(((ex + tx * t, ey + ty * t), (tx, ty), s_end + t))
    total = samples[-1][2]
    # the round toe: the last 0.9 r of the foot shrinks along a quarter circle (extra rings), then a tip
    toe0 = total - r * 0.9
    rings_def = []  # (2D centre, 2D tangent, arc length, radius factor)
    for c, tng, sl in samples:
        if sl <= toe0:
            rings_def.append((c, tng, sl, 1.0))
    (ex, ey), (tx, ty), _ = samples[-1]
    for a in (25, 50, 72, 88):
        u = math.sin(math.radians(a))
        d = (total - toe0) * u
        rings_def.append(((ex + tx * (d - (total - toe0)), ey + ty * (d - (total - toe0))), (tx, ty),
                          toe0 + d, math.cos(math.radians(a))))
    cr, sr = math.cos(rot), math.sin(rot)
    px, py = place

    def world(lx, ly):
        return px + lx * cr - ly * sr, py + lx * sr + ly * cr

    bm = bmesh.new()
    rings = []
    meta = []  # per ring: arc length
    for (cx, cy), (tx, ty), sl, k in rings_def:
        nx, ny = -ty, tx  # left normal in the local plane (toward the inside of the turn)
        rr = r * k * (1.06 if leg < sl < leg + bend * turn else 1.0)  # the heel bulges a touch
        zc = blanket_top(*world(cx, cy)) + r * flat - 0.05  # rests on the blanket, sunk in a little
        ring = []
        for j in range(seg):
            a = j / seg * math.tau
            wx, wy = world(cx + nx * rr * math.cos(a), cy + ny * rr * math.cos(a))
            ring.append(bm.verts.new((wx, wy, zc + rr * flat * math.sin(a))))
        rings.append(ring)
        meta.append(sl)
    pals = []
    for ri in range(len(rings) - 1):
        a, b = rings[ri], rings[ri + 1]
        sm = (meta[ri] + meta[ri + 1]) / 2
        for j in range(seg):
            jj = (j + 1) % seg
            bm.faces.new((a[j], a[jj], b[jj], b[j]))
            am = (j + 0.5) / seg * math.tau
            top = math.sin(am) > 0.5
            outer = math.cos(am) < -0.2  # right side = outside of the heel turn
            if sm < 0.5:
                pals.append(cuff if j % 2 == 0 else rib)
            elif sm > total - 0.7:
                pals.append(patch_t if top else patch)
            elif leg - 0.05 < sm < leg + bend * turn + 0.1 and outer:
                pals.append(patch_t if top else patch)
            else:
                pals.append(body_t if top else body)
    # toe tip
    (cx, cy), (tx, ty), _, _ = rings_def[-1]
    tipx, tipy = world(cx + tx * r * 0.08, cy + ty * r * 0.08)
    tip = bm.verts.new((tipx, tipy, rings[-1][0].co.z))
    for j in range(seg):
        bm.faces.new((rings[-1][j], rings[-1][(j + 1) % seg], tip))
        pals.append(patch_t if math.sin((j + 0.5) / seg * math.tau) > 0.3 else patch)
    # the opening: a dark dip at the cuff end
    (cx, cy), (tx, ty), _, _ = rings_def[0]
    ox, oy = world(cx + tx * 0.12, cy + ty * 0.12)  # pushed into the leg
    ctr = bm.verts.new((ox, oy, rings[0][0].co.z))
    for j in range(seg):
        bm.faces.new((rings[0][(j + 1) % seg], rings[0][j], ctr))
        pals.append(inner)
    _outward(bm)  # flips in place: the face order (and so `pals`) is kept
    return K.Piece(K._bm_to_mesh(bm, name), pals, True, True, name)


def _bunny(base, face, lean, s=1.25):
    """a little pink plush bunny sitting at `base`, its face turned to `face` (radians around Z from
    -Y), leaning back by `lean` (radians) onto the pillows. Local model: sits on z = 0, faces -Y."""
    T = M(base, (0, 0, face)) @ Matrix.Rotation(-lean, 4, "X") @ Matrix.Diagonal((s, s, s, 1.0))
    front = (T.to_3x3() @ Vector((0, -1, 0))).normalized()
    parts = []

    def ell(pal, loc, radii, rot=(0, 0, 0), seg=12, rings=8, outline=True, name="bunny"):
        return K.sphere(pal, 1.0, T @ M(loc, rot, radii), seg=seg, rings=rings, outline=outline, name=name)

    def toned(p, belly=None):
        pals = []
        for f in p.mesh.polygons:
            n = f.normal
            if belly is not None and n.dot(front) > belly and n.z < 0.5:
                pals.append(BUN_BELLY)
            elif n.z > 0.55:
                pals.append(BUN_L)
            elif n.z < -0.5:
                pals.append(BUN_D)
            else:
                pals.append(BUN)
        p.face_pal = pals
        return p

    HC, HR = (0.0, -0.04, 1.42), (0.6, 0.52, 0.5)   # head centre / radii

    def on_head(u, w, out=0.0):
        """local point on the head's front surface: u across (x), w up (z), both in head radii"""
        y = -HR[1] * math.sqrt(max(0.0, 1 - u * u - w * w))
        return (HC[0] + HR[0] * u, HC[1] + y - out, HC[2] + HR[2] * w)

    parts.append(toned(ell(BUN, (0, 0.02, 0.56), (0.56, 0.5, 0.6), seg=12, rings=8), belly=0.55))
    parts.append(toned(ell(BUN, HC, HR, seg=14, rings=9)))
    # ears: the left one stands up, the right one flops forward a little; rose inside
    for sx, rot in ((-1, (0.08, -0.22, 0)), (1, (0.42, 0.42, 0))):
        ear = ell(BUN, (0.22 * sx, 0.04, 2.08), (0.15, 0.09, 0.5), rot, seg=8, rings=7)
        toned(ear)
        ear.face_pal = [BUN_IN if f.normal.dot(front) > 0.45 else c for f, c in zip(ear.mesh.polygons, ear.face_pal)]
        parts.append(ear)
    # arms (paws resting on the tummy) and feet sticking out in front
    for sx in (-1, 1):
        parts.append(toned(ell(BUN, (0.46 * sx, -0.22, 0.66), (0.16, 0.17, 0.28), (0.55, -0.3 * sx, 0), seg=8, rings=5)))
        foot = ell(BUN, (0.27 * sx, -0.42, 0.13), (0.19, 0.3, 0.15), (0, 0, 0.15 * sx), seg=8, rings=5)
        parts.append(toned(foot))
    # face: eyes with a glint, nose, rosy cheeks (no outline - they're painted on)
    for sx in (-1, 1):
        ex, ey, ez = on_head(0.36 * sx, 0.12, -0.01)
        parts.append(ell(BUN_EYE, (ex, ey, ez), (0.075, 0.05, 0.09), (0, 0, 0.45 * sx), seg=6, rings=5,
                         outline=False, name="bunny_eye"))
        gx, gy, gz = on_head(0.36 * sx - 0.03, 0.18, 0.03)
        parts.append(ell(K.WHITE, (gx, gy, gz), (0.025, 0.02, 0.03), seg=4, rings=3, outline=False, name="bunny_glint"))
        cx, cy, cz = on_head(0.55 * sx, -0.2, -0.0)
        parts.append(ell(BUN_IN, (cx, cy, cz), (0.1, 0.035, 0.065), (0, 0, 0.75 * sx), seg=6, rings=4,
                         outline=False, name="bunny_cheek"))
    nx, ny, nz = on_head(0.0, -0.08, 0.0)
    parts.append(ell(BUN_IN, (nx, ny, nz), (0.085, 0.06, 0.06), seg=6, rings=4, outline=False, name="bunny_nose"))
    return parts


# ---------------------------------------------------------------- the bed
def build():
    p = []
    hx = XP  # panel / post x
    # four posts: tall at the head (-X), lower at the foot (+X)
    for x, top in ((-hx, HEAD_TOP), (hx, FOOT_TOP)):
        for y in (-YP, YP):
            p += _post(x, y, top, "post")
    hh, hf = _post_height(HEAD_TOP), _post_height(FOOT_TOP)
    # solid arched headboard and footboard: the ends meet the posts below their shoulders, the crest
    # rises in the middle of the (now wide) panel, about as high as the collars
    p.append(_arch_panel(-hx, YP, RAIL_Z0 + 0.1, hh - 0.95, hh + 0.3, 0.8, 2.2, "headboard"))
    p.append(_arch_panel(hx, YP, RAIL_Z0 + 0.1, hf - 0.9, hf + 0.25, 0.8, 2.2, "footboard"))
    # thick side rails (front and back)
    for y in (-YP, YP):
        rail = K.rounded_box(RAIL, (2 * hx, RAIL_T, RAIL_Z1 - RAIL_Z0), M((0, y, (RAIL_Z0 + RAIL_Z1) / 2)),
                             bevel=0.2, segments=2, name="rail")
        p.append(_tone(rail, RAIL, PANEL_L, PANEL_D, up=0.25))
    # the art inks the line where the white mattress meets the side board (at the head end, where it
    # shows); the two faces are nearly flush, so the hull can't draw it - a thin dark seam does
    p.append(K.cylinder(K.OUTLINE, 0.06, 2 * hx, M((0, -MAT_HY, RAIL_Z1 - 0.06), rot=(0, math.pi / 2, 0)),
                        seg=6, outline=False, name="seam"))
    # mattress with a soft, round edge
    mat = K.rounded_box(SHEET, (2 * hx - 0.6, 2 * MAT_HY, MAT_Z1 - MAT_Z0), M((0, 0, (MAT_Z0 + MAT_Z1) / 2)),
                        bevel=MAT_BEVEL, segments=3, name="mattress")
    p.append(_tone(mat, SHEET_S, SHEET, SHEET_D))
    # the blanket hangs down the front (-Y): a thick slate-blue blanket with bold red stripes running
    # across the bed, whose head end is turned down over itself (the pale-blue lining shows) - the fold
    # is its own thick, soft roll lying ON TOP of the stripes' head end
    p.append(_blanket())
    p.append(_fold(FOLD_X0, FOLD_XF))
    # two plump pillows side by side across the head end, leaning back on the headboard
    px = -hx + 0.4 + 1.85
    # (deep bellies: the underside fills the wedge under the lean, no dark gap above the mattress)
    p.append(_pillow((px, -2.85, MAT_Z1 + 0.8), 1.95, 2.85, 1.55, 1.0, (0.0, 0.42, 0.05), name="pillow"))
    p.append(_pillow((px - 0.08, 2.9, MAT_Z1 + 0.9), 1.95, 2.9, 1.6, 1.1, (0.0, 0.5, -0.06), name="pillow"))
    # a little plush bunny sitting on the fold, leaning on the front pillow, looking into the room
    fy = -2.5
    p += _bunny((FOLD_X0 + 0.8, fy, CLOTH_ZT + _bow(fy) + FOLD_OUT - 0.05), math.radians(45), 0.3)
    # two socks lying on the blanket
    p.append(_sock(SOCK_Y, (0.6, -0.2), math.radians(-28), "sock"))
    p.append(_sock(SOCK_G, (8.8, 0.6), math.radians(160), "sock"))
    body, outline = K.finish(p, NAME, outline_width=0.095)
    return [body, outline] + K.markers(NAME)
