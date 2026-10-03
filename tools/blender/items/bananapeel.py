"""
items/bananapeel.py - the BananaPeel item (ReplicatedStorage.ItemMeshes.BananaPeel): a cartoon banana
peel lying flat on the floor, the trap a player drops. See items/__init__.py for the conventions.

A round, softly ridged yellow nub in the middle (where the peel's strips still hang together) with
the stem standing up out of it, a dark cut end on top; four floppy peel strips splay out from low on
the nub onto the floor, yellow side up with a few brown speckles, their edges arched down and their
rounded ends rolling up, so the pale inside of the peel shows along the rims and under each end.
Each strip is one closed sweep (a rounded cross-section along a centre line that leaves the nub,
drops onto the floor and rolls up in an arc at the end); the yellow / pale sides meet exactly on the
rim, and every tone band is cut along an iso-line of the surface normal (clean curved borders).

1 unit = 1 stud: about 1.8 across, 0.42 tall. Origin = floor centre (the peel rests on it, `_Base`);
`_Grip` = the middle of the stem (the hand holds it by the stem while dropping it; the game turns
it for holding).
"""
import math
import bmesh
from mathutils import Vector
import sockkit as K
from sockkit import M, hexcol
import items
from props.slippers import _iso_cut, _outward, _smooth

NAME = "BananaPeel"

# texture classes (tools/blender/texturing.py): the skin gets the leaf pattern (fibres running along
# each strip), the pale inside a soft paper fibre
MATERIALS = {"bananapeel_skin": "leaf", "bananapeel_inside": "paper", "bananapeel_spot": "leaf",
             "bananapeel_stem": "leaf", "bananapeel_cut": "rubber"}


def _colours():
    """Registers this item's palette colours. Called by build(), not at import: build_all.py imports
    every item module before it builds the socks, so colours registered at import would take palette
    cells ahead of the socks' (items must come last, see items/__init__.py)."""
    global SKIN, INSIDE, SPOT, STEM, CUT
    SKIN = (hexcol("bananapeel_skin_light", "#FFE866"), hexcol("bananapeel_skin", "#FFCB2B"),
            hexcol("bananapeel_skin_dark", "#E9A11B"), hexcol("bananapeel_skin_deep", "#BF7A17"))
    # the inside: a bright pale yellow (it mostly faces away from the light, and cream read as grey there)
    INSIDE = (hexcol("bananapeel_inside_light", "#FFFBD8"), hexcol("bananapeel_inside", "#FFF1AE"),
              hexcol("bananapeel_inside_dark", "#FCE38E"))
    SPOT = hexcol("bananapeel_spot", "#8A5426")
    STEM = (hexcol("bananapeel_stem_light", "#C9C452"), hexcol("bananapeel_stem", "#9AA034"),
            hexcol("bananapeel_stem_dark", "#6F7A24"))
    CUT = hexcol("bananapeel_cut", "#4E3218")


TONE_CUTS = (-0.35, 0.78)     # normal z: shade / base / lit
OUTLINE_W = 0.032
# the nub: the still-whole bottom of the peel, (radius, z) bottom to top, five soft ridges round it
NUB = [(0.0, 0.0), (0.19, 0.0), (0.205, 0.05), (0.19, 0.13), (0.15, 0.2), (0.1, 0.245), (0.05, 0.265), (0.0, 0.27)]
STEM_PTS = [(0.0, 0.0, 0.22), (0.0, 0.015, 0.32), (0.0, 0.05, 0.42)]
GRIP = (0.0, 0.025, 0.35)

# (heading in degrees from the front -Y toward +X, length from the centre, half width, how far the end
#  rolls up (radians), sideways sway): four strips, a little irregular so the peel looks dropped, not placed
PETALS = [(-22.0, 1.04, 0.155, 0.95, 0.08), (64.0, 0.96, 0.145, 0.75, -0.07), (150.0, 1.02, 0.15, 1.05, 0.07),
          (244.0, 0.98, 0.145, 0.8, -0.09)]
CURL_AT = 0.62                # the strip lies flat up to here, then its end rolls up
THICK = 0.026                 # half thickness of a strip
ARCH = 0.035                  # how far a strip's edges droop below its middle
LIFT = 0.085                  # how high a strip leaves the nub (low: its underside stays out of sight)


def _tone(cols, nz):
    if nz > TONE_CUTS[1]:
        return cols[0]
    if nz > TONE_CUTS[0] or len(cols) < 3:
        return cols[1]
    if nz > -0.8 or len(cols) < 4:
        return cols[2]
    return cols[3]


def _petal_frame(ang, length, curl, sway, t):
    """Centre point, tangent, side and up of a strip at t (0 = inside the nub, 1 = the tip)."""
    d = Vector((math.sin(ang), -math.cos(ang), 0.0))
    side = Vector((math.cos(ang), math.sin(ang), 0.0))
    span = length - 0.06

    def centre(s):
        flat = min(s, CURL_AT)
        r = 0.06 + span * flat
        z = THICK + ARCH + LIFT * (1.0 - _smooth(0.05, 0.48, flat))   # leaves the nub, flops onto the floor
        if s > CURL_AT:   # ... then the end rolls up in an arc (`curl` radians), its cream inside facing out
            rc = (1.0 - CURL_AT) * span / curl
            phi = (s - CURL_AT) / (1.0 - CURL_AT) * curl
            r += rc * math.sin(phi)
            z += rc * (1.0 - math.cos(phi))
        return d * r + side * (sway * math.sin(math.pi * s)) + Vector((0, 0, z))
    c = centre(t)
    tan = (centre(min(1.0, t + 0.01)) - centre(max(0.0, t - 0.01))).normalized()
    s = (side - tan * tan.dot(side)).normalized()   # the strip only bends up / down: its side stays put
    up = tan.cross(s)
    return c, tan, s, up


def _width(w, t):
    """Strip half width: narrow under the nub, full in the middle, a rounded end."""
    k = 0.7 + 0.3 * _smooth(0.0, 0.4, t)
    if t > 0.55:
        k *= max(0.0, 1.0 - ((t - 0.55) / 0.45) ** 2) ** 0.45   # a rounded end
    return w * k


def _petal(ang_deg, length, width, curl, sway, rows=18, ring=14):
    ang = math.radians(ang_deg)
    bm = bmesh.new()
    side_val = {}
    rings = []
    for i in range(rows):   # rings up to just short of the tip (closer together there), which is a single point
        t = 1.0 - (1.0 - i / rows) ** 1.6
        c, _tan, s, up = _petal_frame(ang, length, curl, sway, t)
        w = max(_width(width, t), 0.012)
        th = THICK * (1.0 - 0.45 * _smooth(0.75, 1.0, t))
        r = []
        for j in range(ring):
            a = j / ring * math.tau
            ca, sa = math.cos(a), math.sin(a)
            p = c + s * (ca * w) + up * (sa * th - ARCH * ca * ca * (w / width))
            v = bm.verts.new(p)
            side_val[v] = sa
            r.append(v)
        rings.append(r)
    for i in range(rows - 1):
        a, b = rings[i], rings[i + 1]
        for j in range(ring):
            k = (j + 1) % ring
            bm.faces.new((a[j], a[k], b[k], b[j]))
    cen = sum((v.co for v in rings[0]), Vector()) / ring   # the end buried in the nub: a flat cap
    tip = _petal_frame(ang, length, curl, sway, 1.0)[0]    # the other end: a soft point
    for r, cv, sign in ((rings[0], bm.verts.new(cen), 1), (rings[-1], bm.verts.new(tip), -1)):
        side_val[cv] = 0.0
        for j in range(ring):
            k = (j + 1) % ring
            bm.faces.new((cv, r[k], r[j]) if sign > 0 else (cv, r[j], r[k]))   # wound like the strip's quads
    _outward(bm)
    top = bm.faces.layers.int.new("top")
    for f in bm.faces:
        f[top] = 1 if sum(side_val[v] for v in f.verts) / len(f.verts) > 0 else 0
    bm.normal_update()
    nz = {v: v.normal.z for v in bm.verts}
    _iso_cut(bm, nz, (TONE_CUTS[0], TONE_CUTS[1]))
    pal = []
    for f in bm.faces:
        n = sum(nz[v] for v in f.verts) / len(f.verts)
        pal.append(_tone(SKIN, n) if f[top] else _tone(INSIDE, n))
    pc = K.Piece(K._bm_to_mesh(bm, "petal"), pal, True, True, "petal")
    return pc


def _surface_point(ang_deg, length, width, curl, sway, t, a):
    """Point and normal on a strip's yellow top at t, across position a (-1..1)."""
    ang = math.radians(ang_deg)
    c, _tan, s, up = _petal_frame(ang, length, curl, sway, t)
    w = _width(width, t)
    th = THICK * (1.0 - 0.45 * _smooth(0.75, 1.0, t))
    ca = max(-1.0, min(1.0, a))
    sa = math.sqrt(max(0.0, 1.0 - ca * ca))
    p = c + s * (ca * w) + up * (sa * th - ARCH * ca * ca * (w / width))
    return p, up


def _spot(p, n, rx, ry, spin, name="spot"):
    """A little flat brown speckle hugging the surface at p (normal n)."""
    rot = n.to_track_quat("Z", "Y").to_matrix().to_4x4()
    m = M(p + n * 0.004) @ rot @ M(rot=(0, 0, spin), scale=(rx, ry, 1.0))
    return K.cylinder(SPOT, 1.0, 0.004, m, seg=8, outline=False, name=name)


def _profile(pts, n):
    """Catmull-Rom through the (r, z) points -> n + 1 points (ends kept)."""
    out = []
    k = len(pts) - 1
    for i in range(n + 1):
        u = i / n * k
        j = min(int(u), k - 1)
        t = u - j
        p0, p1, p2, p3 = (Vector(pts[min(max(m, 0), k)]) for m in (j - 1, j, j + 1, j + 2))
        out.append(0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t
                          + (-p0 + 3 * p1 - 3 * p2 + p3) * t * t * t))
    return out


def _nub(seg=20):
    bm = bmesh.new()
    prof = _profile(NUB, 12)
    rings = []
    for q in prof:
        if q.x < 1e-6:
            rings.append([bm.verts.new((0.0, 0.0, q.y))])
            continue
        ring = []
        for j in range(seg):
            a = j / seg * math.tau
            r = q.x * (1.0 + 0.06 * math.cos(5 * a) * _smooth(0.0, 0.1, q.y))   # five soft ridges
            ring.append(bm.verts.new((r * math.cos(a), r * math.sin(a), q.y)))
        rings.append(ring)
    for i in range(len(rings) - 1):
        a, b = rings[i], rings[i + 1]
        for j in range(seg):
            k = (j + 1) % seg
            if len(a) == 1:
                bm.faces.new((a[0], b[k], b[j]))
            elif len(b) == 1:
                bm.faces.new((a[j], a[k], b[0]))
            else:
                bm.faces.new((a[j], a[k], b[k], b[j]))
    _outward(bm)
    bm.normal_update()
    nz = {v: v.normal.z for v in bm.verts}
    _iso_cut(bm, nz, (TONE_CUTS[0], TONE_CUTS[1]))
    pal = [_tone(SKIN, sum(nz[v] for v in f.verts) / len(f.verts)) for f in bm.faces]
    return K.Piece(K._bm_to_mesh(bm, "nub"), pal, True, True, "nub")


def _stem():
    pts = STEM_PTS
    stem = K.tube(STEM[1], pts, radius=0.062, radii=[1.25, 1.0, 0.86], res=4, bevel_res=2, name="stem")
    # tone it by the normal (lit top-left, shaded below)
    me = stem.mesh
    stem.face_pal = [STEM[0] if f.normal.z > 0.75 or f.normal.x < -0.6 else
                     (STEM[2] if f.normal.x > 0.55 or f.normal.z < -0.3 else STEM[1]) for f in me.polygons]
    top = Vector(pts[-1])
    axis = (Vector(pts[-1]) - Vector(pts[-2])).normalized()
    rot = axis.to_track_quat("Z", "Y").to_matrix().to_4x4()
    cut = K.cylinder(CUT, 0.047, 0.012, M(top + axis * 0.002) @ rot, seg=10, outline=False, name="cut")
    return [stem, cut]


def build():
    _colours()
    p = [_nub()]
    p += _stem()
    spots = [(0, 0.55, 0.3, 0.03, 0.018, 0.4), (0, 0.7, -0.3, 0.02, 0.014, 1.2), (1, 0.62, -0.2, 0.026, 0.016, 0.0),
             (2, 0.5, 0.2, 0.032, 0.02, 2.0), (2, 0.68, -0.35, 0.018, 0.013, 0.3), (3, 0.58, 0.3, 0.024, 0.016, 1.0)]
    for spec in PETALS:
        p.append(_petal(*spec))
    for k, t, a, rx, ry, spin in spots:
        pt, n = _surface_point(*PETALS[k], t, a)
        p.append(_spot(pt, n, rx, ry, spin))
    for a, rx in ((-1.2, 0.022), (2.6, 0.018)):   # a couple on the nub too
        d = Vector((math.cos(a), math.sin(a), 0.75)).normalized()   # ~ the nub's normal there
        q = Vector((math.cos(a) * 0.175, math.sin(a) * 0.175, 0.17))
        p.append(_spot(q, d, rx, rx * 0.7, a))
    body, outline = K.finish(p, NAME, outline_width=OUTLINE_W)
    for attr in ("visible_shadow", "visible_diffuse", "visible_glossy", "visible_transmission", "visible_volume_scatter"):
        if hasattr(outline, attr):  # preview only: the hull must not block light (it doesn't in Roblox)
            setattr(outline, attr, False)
    return [body, outline] + K.markers(NAME) + [items.grip(NAME, GRIP)]


BUILDERS = {NAME: build}
