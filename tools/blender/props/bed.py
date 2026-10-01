"""
props/bed.py - the Bed prop (ReplicatedStorage.MapMeshes.Bed). See props/__init__.py for
the conventions every prop follows.

Concept (docs/concept/bedroom_keyframe.png, seen there from the foot end): a chunky cartoon
wooden bed - four thick turned posts, each with a rounded shoulder, a collar ring and a BIG ball
finial; SOLID arched headboard and footboard panels (no slats); a thick side rail; a white
mattress and one puffy white pillow with pinched corner points; a thick slate-blue blanket with bold
red stripes and a thin light line between them, hanging down the front almost to the floor (only a
thin strip of the tall side board shows under its hem); its head end is turned down over itself as
a thick, soft pale-blue roll (the lit fold in the art, between the pillow and the stripes) that lies
on top of the stripes and casts a darker band onto them. At the head end, under the fold's rounded
hem corner, the side board is a tall solid plank under a white mattress band almost as tall.
Wood is 2-3 flat tones: lighter on top-facing faces and a lit strip along the top of the headboard /
footboard (the art's lit top edges), darker undersides; the panels are a deeper red-brown than the
posts.

Game layout: the long side faces the room (front = -Y). Head end at -X (tall posts, next to the
nightstand), foot end at +X (lower posts). Map.luau fits it into 290 x 100 x 86 studs, so the
model is 29 x 10 x 8.6 units (length X : height Z : depth Y). Origin = floor centre.
"""
import math
import bmesh
import bpy
import sockkit as K
from sockkit import M, hexcol
from props.common import *  # noqa: F401,F403 - shared colours (read-only)

NAME = "Bed"

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

# ---------------------------------------------------------------- dimensions (units)
LEN = 29.0                  # overall X
DEP = 8.6                   # overall Y
R = 1.15                    # post radius: fat columns, ~0.93 of the ball width
RB = 1.25                   # ball finial radius (X/Y); squashed a little in Z
BALL_SQ = 0.85              # balls a little squashed (art: height / width ~0.8-0.87)
XP = LEN / 2 - RB           # post centres
YP = DEP / 2 - RB
COLLAR_H = 0.44
BALL_SINK = 0.1            # how far the ball sits down into its collar
HEAD_TOP, FOOT_TOP = 10.0, 8.75         # ball tops: foot posts ~88% of the head posts (the hero column)


def _post_height(top):
    """post body height (shoulder top) so that the ball top lands on `top`"""
    return top - (COLLAR_H - 0.06) - 2 * RB * BALL_SQ + BALL_SINK


RAIL = hexcol("bed_rail", "#A04C31")          # side rails sit in the shadow of the mattress

# the side rail is a tall solid board reaching almost to the floor (a thin shadow gap under it); at
# the head end the white mattress band above it is ~0.83x as tall as the wood band (art ~0.85)
RAIL_Z0, RAIL_Z1, RAIL_T = 0.25, 2.3, 0.62
MAT_Z0, MAT_Z1 = 1.85, 4.0
MAT_HY = YP + 0.26          # mattress side sits 0.05 behind the rail face (no z-fighting where they meet)
DRAPE_Z = 1.0                # bottom of the striped drape; its flattened hem bottoms out HEM_DEPTH lower,
HEM_DEPTH = 0.14             # ~8.5% of the head-post height above the floor, as in the art
PALE_Z = 0.92                # the pale fold hangs a touch lower: it covers the stripes' hidden head end


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


def _post(x, y, top, name):
    """turned corner post: base bead, straight shaft, rounded shoulder, collar ring, big ball"""
    h = _post_height(top)
    shoulder = [(0.55 * R + 0.45 * R * math.cos(math.radians(a)), h - 0.5 * R + 0.5 * R * math.sin(math.radians(a)))
                for a in (0, 30, 60, 90)]
    prof = [(0, 0), (1.03 * R, 0), (1.08 * R, 0.14), (1.08 * R, 0.5), (1.04 * R, 0.62), (R, 0.7)] + shoulder + [(0, h)]
    body = _tone(_lathe(prof, (x, y, 0), seg=16, name=name), POST, POST_L, POST_D, up=0.75)
    collar = [(0, 0), (0.6 * R, 0), (0.76 * R, 0.1), (0.76 * R, COLLAR_H - 0.1), (0.6 * R, COLLAR_H), (0, COLLAR_H)]
    ring = _tone(_lathe(collar, (x, y, h - 0.06), seg=16, name=name + "_collar"), POST, POST_L, POST_D)
    bz = h - 0.06 + COLLAR_H + RB * BALL_SQ - BALL_SINK
    ball = _tone(K.sphere(POST, RB, M((x, y, bz), scale=(1, 1, BALL_SQ)), seg=16, rings=10, name=name + "_ball"),
                 POST, POST_L, POST_D, up=0.62, down=-0.72)
    return [body, ring, ball]


def _arch_panel(x, half, zb, ze, zp, thick, power, name, n=22, bevel=0.2, band=0.2):
    """solid panel in the YZ plane, centred on x, spanning y = +-half (the post centres): flat
    bottom at zb, arched top that is zp in the middle and ze where it meets the post surfaces
    (|y| = half - R) - kept below the posts' rounded shoulders; `power` 2 = round arch, more = flatter
    top with rounder ends. Both big faces carry a lighter strip `band` tall that follows the arch just
    under the rounded top edge (the art's lit top line)."""
    def top(y):
        return zp - (zp - ze) * (abs(y) / (half - R)) ** power

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
    mod.segments = 3
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


def _pillow(center, a, b, h, hb, rot, nu=12, nv=10, pinch=(0.13, 0.1), seam=0.6, name="pillow"):
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


def _cloth_profile(drape_z, back_z, flare):
    """(y, z) profile of a cloth layer over the mattress: front hem -> up the front drape (flaring out a
    little toward the hem) -> round the mattress edge (6-segment arcs: a soft, puffy roll, no facets)
    -> over a slightly bowed top -> down the back (3 segments: that side faces the wall). 17 points;
    CLOTH_INNER lists the ones the hidden inner surface keeps."""
    yf, yb, zt, rc = -(MAT_HY + 0.08), MAT_HY + 0.08, MAT_Z1 + 0.05, 0.8
    za = zt - rc  # where the rounded mattress edge starts

    def fy(z):
        return yf - flare * ((za - z) / (za - drape_z)) ** 1.5
    zm = (drape_z + za) / 2
    return ([(fy(drape_z), drape_z), (fy(zm), zm)]
            + _arc(yf + rc, za, rc, 180, 90, 6)
            + [(-1.6, zt + 0.08), (0.0, zt + 0.14), (1.6, zt + 0.08)]
            + _arc(yb - rc, za, rc, 90, 0, 3)
            + [(yb, back_z)])


CLOTH_INNER = [0, 1, 2, 4, 6, 8, 10, 12, 14, 16]


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
    for a in (25, 50, 70, 90):  # the crease and the head-end hem corner share their cuts
        c = 1 - math.cos(math.radians(a))
        cuts.update((x0 + roll0 * c, xf - roll1 * c))
    xs = sorted(cuts)

    def pal(xm, part, nz, zm):  # lining colour everywhere (no dark inside showing at the hem)
        return CUFF_T if (part == "out" and nz > 0.6) else CUFF

    piece = _sheet(lambda x: _cloth_profile(hem_z(x), 2.75, 0.16), 0.03, 0.8, xs, pal, "fold", taper=taper,
                   inner_idx=CLOTH_INNER)
    me = piece.mesh
    za = MAT_Z1 + 0.05 - 0.8
    for v in me.vertices:
        if v.co.y < 0:
            s = min(1.0, max(0.0, (za - v.co.z) / (za - PALE_Z))) ** 1.3
            w = min(1.0, max(0.0, 1 - (v.co.x - x0) / span))
            v.co.x -= flx * s * w
    me.update()
    # faces turned toward the head end (the flared drape, the crease) catch the lamp light
    piece.face_pal = [CUFF_T if (f.normal.x < -0.45 and f.normal.z > -0.3) else c
                      for f, c in zip(me.polygons, piece.face_pal)]
    return piece


# ---------------------------------------------------------------- the bed
def build():
    p = []
    hx = XP  # panel / post x
    # four posts: tall at the head (-X), lower at the foot (+X)
    for x, top in ((-hx, HEAD_TOP), (hx, FOOT_TOP)):
        for y in (-YP, YP):
            p += _post(x, y, top, "post")
    hh, hf = _post_height(HEAD_TOP), _post_height(FOOT_TOP)
    # solid arched headboard and footboard
    # broad, gentle domes whose crest stays just under the posts' shoulder line, so every collar and
    # ball stands clear above the panel; ends meet the posts a little lower with rounded shoulders
    p.append(_arch_panel(-hx, YP, RAIL_Z0 + 0.1, hh - 0.55, hh - 0.15, 0.78, 3.5, "headboard"))
    p.append(_arch_panel(hx, YP, RAIL_Z0 + 0.1, hf - 0.55, hf - 0.15, 0.78, 3.5, "footboard"))
    # thick side rails (front and back)
    for y in (-YP, YP):
        rail = K.rounded_box(RAIL, (2 * hx, RAIL_T, RAIL_Z1 - RAIL_Z0), M((0, y, (RAIL_Z0 + RAIL_Z1) / 2)),
                             bevel=0.2, segments=2, name="rail")
        p.append(_tone(rail, RAIL, PANEL_L, PANEL_D, up=0.25))
    # the art inks the line where the white mattress meets the side board (at the head end, where it
    # shows); the two faces are nearly flush, so the hull can't draw it - a thin dark seam does
    p.append(K.cylinder(K.OUTLINE, 0.06, 2 * hx, M((0, -MAT_HY, RAIL_Z1 - 0.06), rot=(0, math.pi / 2, 0)),
                        seg=6, outline=False, name="seam"))
    # mattress
    mat = K.rounded_box(SHEET, (2 * hx - 0.6, 2 * MAT_HY, MAT_Z1 - MAT_Z0), M((0, 0, (MAT_Z0 + MAT_Z1) / 2)),
                        bevel=0.5, segments=3, name="mattress")
    p.append(_tone(mat, SHEET_S, SHEET, SHEET_D))
    # the blanket hangs down the front (-Y): a thick slate-blue blanket with bold red stripes running
    # across the bed, whose head end is turned down over itself (the pale-blue lining shows) - the fold
    # is its own thick, soft roll lying ON TOP of the stripes' head end
    x0, x1 = -7.9, hx - 0.42    # head end of the fold (just past the pillow) / foot end (inside the posts)
    xf = -4.6                   # the fold's free (+X) edge
    shade = (xf - 0.25, xf + 0.28)  # the fold casts a darker band onto the stripes past its edge
    period, red_w, line_w = 2.05, 0.78, 0.13
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

    p.append(_sheet(_cloth_profile(DRAPE_Z, 2.9, 0.1), -0.06, 0.55, xs, blanket_pal, "blanket",
                    inner_idx=CLOTH_INNER))
    p.append(_fold(x0, xf))
    # one big puffy pillow across the head end, leaning on the headboard
    p.append(_pillow((-hx + 3.25, 0.0, MAT_Z1 + 0.2), 2.0, 3.1, 1.4, 0.3, (0, 0.06, 0)))
    body, outline = K.finish(p, NAME, outline_width=0.095)
    return [body, outline] + K.markers(NAME)
