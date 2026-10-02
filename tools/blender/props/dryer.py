"""
props/dryer.py - the Dryer prop (ReplicatedStorage.MapMeshes.Dryer). See props/__init__.py for
the conventions every prop follows.

Matches the machine in docs/concept/bedroom_keyframe.png: a chunky front-loader with a white front,
periwinkle sides, one light-blue control band (detergent slot | dial + dark display, split by an ink
line on its front), a blue plinth with a filter hatch, a thick blue bezel round a purple galaxy
vortex, and the round door swung open ~178 degrees to the viewer's left, lying just in front of the
face (silver ring round a glass bowl). Body 3.4 W x 3.4 D x 4.2 H: 4.2 matches the art's W:H (~0.78)
better than 3.6 would; Map.luau fits it uniformly, and the door's extra width is what limits that fit.

Exported objects: `Dryer` (textured body), `Dryer_Outline` (inverted hull), `DryerVortex` and
`DryerStars` (the galaxy's spiral arms/void and its stars as two textured layers without outline -
the client spins them about the porthole axis at different speeds), `DryerPortal` (untextured
back disc of the vortex - Map.luau makes it Neon purple; the spiral arms and stars sit just
in front of it, so the glow shows between the arms), `DryerGlass` (untextured glass bowl of the door,
for a light-blue Glass material) and the markers: `Dryer_Base`, `Dryer_Unit` and `Dryer_Pin` at the
porthole centre on the front plane (the open door makes the bounding box off-centre, so the game can
put the portal light / spin parts here instead of at the box centre). The two untextured parts carry
a UV pointing at a swatch of their in-game colour only so previews look like the game; they have no
material.
"""
import math
import random
import bpy
from mathutils import Vector
import sockkit as K
from sockkit import M, hexcol
from props.common import *  # noqa: F401,F403 - shared colours (read-only)

NAME = "Dryer"

# texture classes for tools/blender/texturing.py where the colour names alone guess wrong
MATERIALS = {"dryer_band": "plastic", "dryer_door": "plastic",  # enamel / white plastic, not fabric or wood
             "dryer_lane": "decal", "dryer_void": "decal", "dryer_arm": "decal"}  # the galaxy stays flat and bright
TEXTURE_SIZE = 1024  # the map's centrepiece: the full texture size even though it's small

# ---------------------------------------------------------------- palette (sampled from the keyframe)
FRONT = hexcol("dryer_front", "#ECF1FE")          # cool white front face (stays white, not cream, under warm lamps)
SIDE = hexcol("dryer_side", "#8FA6F0")            # light periwinkle body sides
SIDE_L = hexcol("dryer_side_light", "#94BCEE")    # light-blue frame edge round the front
BAND = hexcol("dryer_band", "#96D6FF")            # light-blue control band
BAND_L = hexcol("dryer_band_light", "#CDEBFA")
BAND_S = hexcol("dryer_band_side", "#3558C8")     # deeper royal-blue band / plinth sides
PLINTH = hexcol("dryer_plinth", "#5C94DC")
PLINTH_L = hexcol("dryer_plinth_light", "#8ABAEC")
PLINTH_S = hexcol("dryer_plinth_side", "#3558C8")
BEZEL = hexcol("dryer_bezel", "#6CA8F0")
BEZEL_L = hexcol("dryer_bezel_light", "#94C6F6")
HATCH = hexcol("dryer_hatch", "#C4D0E4")
HATCH_D = hexcol("dryer_hatch_dark", "#8F9CC4")
SLOT = hexcol("dryer_slot", "#3A62B2")
SLOT_L = hexcol("dryer_slot_lip", "#7FB0DC")
SCREEN = hexcol("dryer_screen", "#4E4361")
SCREEN_L = hexcol("dryer_screen_glare", "#8F82A4")
DIAL = hexcol("dryer_dial", "#EEEFE6")
DIAL_D = hexcol("dryer_dial_shade", "#A6A8CC")
DIAL_T = hexcol("dryer_dial_tick", "#B4B8CA")
DOOR = hexcol("dryer_door", "#E4E6FA")
DOOR_L = hexcol("dryer_door_light", "#F4F4FC")
DOOR_D = hexcol("dryer_door_shade", "#C8CBE0")
DOOR_IN = hexcol("dryer_door_inner", "#D2DAEC")
LATCH = hexcol("dryer_latch", "#55566E")
HINGE = hexcol("dryer_hinge", "#C4C8EA")
HINGE_D = hexcol("dryer_hinge_shade", "#9094C6")
INK = K.OUTLINE
G_CORE = hexcol("dryer_void", "#0C0320")
G_DEEP = hexcol("dryer_void_ring", "#1A0A5A")    # deep indigo lane middle
G_LANE = hexcol("dryer_lane", "#4A2294")
G_MID = hexcol("dryer_lane_edge", "#6E2EBA")
G_ARM = hexcol("dryer_arm", "#9C40D0")
G_PINK = hexcol("dryer_arm_core", "#B45CE4")     # soft lavender-pink arm core, 2 steps
G_PINK_L = hexcol("dryer_arm_core_light", "#CC84EE")
G_STAR = hexcol("dryer_star", "#FFF6FF")
GLOW_TINT = hexcol("dryer_portal_glow", "#965AFF")  # = Map.luau GLOW_PARTS.DryerPortal (150, 90, 255)
GLASS_TINT = hexcol("dryer_glass_tint", "#AFD6F2")
GLINT = hexcol("dryer_glint", "#F2F8FF")

# ---------------------------------------------------------------- layout (units; Z up, front = -Y)
W, D, H = 3.4, 3.4, 4.2        # machine body (the open door adds width on -X only)
FY = -D / 2                    # front plane of the white face
PLINTH_H = 0.52                # blue base band
BAND_Z0 = 3.38                 # light-blue control band from here to the top
PZ = 1.89                      # porthole centre height (bezel top ~0.18 under the band, bottom ~0.06 over the plinth)
R_GAL = 0.99                   # galaxy radius (inside the bezel; art vortex/bezel ~0.75)
R_BEZ = 1.31                   # bezel outer radius (~77% of the front width, as in the art)
R_DOOR = 1.25                  # door ring outer radius (door ~0.95x the bezel)
DS = R_DOOR / 1.20             # door detail scale (door radii below were tuned at R_DOOR 1.20)
GS = R_GAL / 0.93              # galaxy detail scale (vortex radii below were tuned at R_GAL 0.93)
VZ = 0.08                      # the vortex layers sit this far in front of the white face (only ~0.1
                               # behind the bezel front, so the bezel's shadow on them stays thin)
HINGE_X, HINGE_Y = -(R_BEZ + 0.02), FY - 0.10
DOOR_SWING = 177.5             # degrees the door has swung open (180 = flat against the front); the
                               # free edge comes only ~0.35 in front of the face, so depth barely grows


# ---------------------------------------------------------------- mesh helpers
def _mesh(verts, faces, name):
    me = bpy.data.meshes.new(name)
    me.from_pydata([tuple(v) for v in verts], [], faces)
    me.update()
    return me


def _wind(verts, face, want):
    """`face` ordered so its normal points along `want`."""
    a, b, c = (Vector(verts[i]) for i in face[:3])
    n = (b - a).cross(c - a) if len(face) == 3 else (c - a).cross(Vector(verts[face[3]]) - b)
    return face if n.dot(want) >= 0 else face[::-1]


def _lathe(pal, profile, mat, seg=32, closed=False, outline=True, smooth=True, name="lathe"):
    """Revolves `profile` [(r, d), ...] about the local Y axis; d is measured toward the FRONT (-Y).
    Open profiles run with the visible side on their LEFT in (r, d) (inner edge -> front -> outer
    edge); closed loops are oriented automatically. `pal`: int or one entry per profile segment."""
    n = len(profile)
    if closed:
        area = sum(profile[i][0] * profile[(i + 1) % n][1] - profile[(i + 1) % n][0] * profile[i][1] for i in range(n))
        left_out = area < 0
    else:
        left_out = True
    verts, rings = [], []
    for r, d in profile:
        if r < 1e-6:
            rings.append([len(verts)] * seg)
            verts.append(Vector((0.0, -d, 0.0)))
            continue
        ids = []
        for j in range(seg):
            a = j / seg * math.tau
            ids.append(len(verts))
            verts.append(Vector((r * math.cos(a), -d, r * math.sin(a))))
        rings.append(ids)
    faces, fpal = [], []
    for i in range(n if closed else n - 1):
        i2 = (i + 1) % n
        tr, td = profile[i2][0] - profile[i][0], profile[i2][1] - profile[i][1]
        nr, nd = (-td, tr) if left_out else (td, -tr)
        for j in range(seg):
            j2 = (j + 1) % seg
            a = (j + 0.5) / seg * math.tau
            q = [rings[i][j], rings[i][j2], rings[i2][j2], rings[i2][j]]
            q = [v for k, v in enumerate(q) if v not in q[:k]]
            if len(q) < 3:
                continue
            faces.append(_wind(verts, q, Vector((nr * math.cos(a), -nd, nr * math.sin(a)))))
            fpal.append(pal if isinstance(pal, int) else pal[i])
    return K.Piece(_mesh([mat @ v for v in verts], faces, name), fpal, outline, smooth, name)


def _rrect(r0, r1, d0, d1, rad, n=2):
    """Closed rounded-rectangle profile in (r, d) for `_lathe` (a ring with a chunky rounded section)."""
    pts = []
    corners = [((r1 - rad, d0 + rad), -90), ((r1 - rad, d1 - rad), 0), ((r0 + rad, d1 - rad), 90), ((r0 + rad, d0 + rad), 180)]
    for (cr, cd), a0 in corners:
        for k in range(n + 1):
            a = math.radians(a0 + 90 * k / n)
            pts.append((cr + rad * math.cos(a), cd + rad * math.sin(a)))
    return pts


def _disc(pal, r_out, cx, cz, y, r_in=0.0, seg=24, name="disc"):
    """A flat disc / annulus in the plane y, facing the front (-Y). No outline."""
    verts, faces = [], []
    if r_in <= 0:
        verts.append(Vector((cx, y, cz)))
    for j in range(seg):
        a = j / seg * math.tau
        verts.append(Vector((cx + r_out * math.cos(a), y, cz + r_out * math.sin(a))))
        if r_in > 0:
            verts.append(Vector((cx + r_in * math.cos(a), y, cz + r_in * math.sin(a))))
    want = Vector((0, -1, 0))
    for j in range(seg):
        j2 = (j + 1) % seg
        if r_in <= 0:
            faces.append(_wind(verts, [0, 1 + j, 1 + j2], want))
        else:
            faces.append(_wind(verts, [2 * j, 2 * j2, 2 * j2 + 1, 2 * j + 1], want))
    return K.Piece(_mesh(verts, faces, name), pal, False, False, name)


def _strip(cols, theta0, ra, rb, twist, edges, y, cx, cz, steps=22, name="arm"):
    """A flat ribbon from radius ra to rb along the spiral theta(r) = theta0 + twist * ln(r / R_GAL)
    (clockwise going inward, as in the art), facing the front. edges(r) = (a0, a1): angular offsets of
    its two edges from the spiral at radius r; `cols` = palette index per column across the ribbon, or
    cols(r) -> that list for the row at radius r (same length every row)."""
    colf = cols if callable(cols) else (lambda r: cols)
    nc = len(colf(ra))
    verts, faces, pal = [], [], []
    for s in range(steps + 1):
        r = ra + (rb - ra) * s / steps
        th = theta0 + twist * math.log(r / R_GAL)
        a0, a1 = edges(r)
        for c in range(nc + 1):
            a = th + a0 + (a1 - a0) * c / nc
            verts.append(Vector((cx + r * math.cos(a), y, cz + r * math.sin(a))))
    want = Vector((0, -1, 0))
    for s in range(steps):
        row = colf(ra + (rb - ra) * (s + 0.5) / steps)
        for c in range(nc):
            i0 = s * (nc + 1) + c
            faces.append(_wind(verts, [i0, i0 + 1, i0 + nc + 2, i0 + nc + 1], want))
            pal.append(row[c])
    return K.Piece(_mesh(verts, faces, name), pal, False, False, name)


def _paint(piece, front, side, top=None, bottom=None, edge=None, front_cut=-0.9, top_cut=0.6):
    """Colours a piece by world face normal: top-facing -> `top` (lit edge), down -> `bottom`,
    facing the front -> `front`, front bevels -> `edge`, everything else -> `side`."""
    for i, f in enumerate(piece.mesh.polygons):
        n = f.normal
        if top is not None and n.z > top_cut:
            c = top
        elif bottom is not None and n.z < -top_cut:
            c = bottom
        elif n.y < front_cut:
            c = front
        elif edge is not None and n.y < -0.3:
            c = edge
        else:
            c = side
        piece.face_pal[i] = c
    return piece


def _tone(piece, base, light=None, dark=None, cut=0.55):
    """Faces of colour `base` facing up get `light`, facing down get `dark` (lit tops, shaded undersides)."""
    for i, f in enumerate(piece.mesh.polygons):
        if piece.face_pal[i] != base:
            continue
        if light is not None and f.normal.z > cut:
            piece.face_pal[i] = light
        elif dark is not None and f.normal.z < -cut:
            piece.face_pal[i] = dark
    return piece


def _preview_tint(obj, pal):
    """UVs on an untextured part, pointing at the swatch of its in-game colour: previews only (the
    part has no material, so nothing is textured in game)."""
    uv = obj.data.uv_layers.new(name="UVMap")
    u, v = K.swatch_uv(pal)
    for loop in uv.data:
        loop.uv = (u, v)
    return obj


# ---------------------------------------------------------------- parts
def _cabinet(p):
    # plinth: blue base band, lit top edge, filter hatch at the bottom right
    p.append(_paint(K.rounded_box(PLINTH, (W + 0.06, D + 0.06, PLINTH_H), M((0, 0, PLINTH_H / 2)), bevel=0.08, segments=2, name="plinth"),
                    PLINTH, PLINTH_S, top=PLINTH_L, front_cut=-0.6))
    # white front section; its rounded front corners read as the light-blue frame edge in the art
    zc = (PLINTH_H - 0.04 + BAND_Z0 + 0.04) / 2
    p.append(_paint(K.rounded_box(FRONT, (W, D, BAND_Z0 - PLINTH_H + 0.08), M((0, 0, zc)), bevel=0.11, segments=3, name="body"),
                    FRONT, SIDE, edge=SIDE_L))
    # control band: ONE light-blue block with a straight top edge (the drawer | dial divider is only an
    # ink line on its front face, below)
    bz = (BAND_Z0 + H) / 2
    seam_x = -W / 2 + 0.305 * W
    p.append(_paint(K.rounded_box(BAND, (W + 0.06, D + 0.06, H - BAND_Z0), M((0, 0, bz)), bevel=0.08, segments=2, name="band"),
                    BAND, BAND_S, top=BAND_L, front_cut=-0.6))
    bf = FY - 0.03  # band / plinth front plane
    # ink: the drawer | dial divider (front face only, bottom of the band up to under the top bevel)
    # and the two horizontal seams (band / front / plinth)
    sz0, sz1 = BAND_Z0 + 0.01, H - 0.085
    p.append(K.rounded_box(INK, (0.03, 0.02, sz1 - sz0), M((seam_x, bf - 0.005, (sz0 + sz1) / 2)), bevel=0.008, segments=1, outline=False, name="seam"))
    p.append(K.rounded_box(INK, (W + 0.01, D + 0.01, 0.04), M((0, 0, BAND_Z0 - 0.005)), bevel=0.015, segments=1, outline=False, name="belt_top"))
    p.append(K.rounded_box(INK, (W + 0.02, D + 0.02, 0.04), M((0, 0, PLINTH_H + 0.015)), bevel=0.015, segments=1, outline=False, name="belt_low"))
    # filter hatch on the plinth
    hx, hz = -W / 2 + 0.795 * W, 0.22
    p.append(K.rounded_box(INK, (0.72, 0.03, 0.34), M((hx, bf - 0.005, hz)), bevel=0.012, segments=1, outline=False, name="hatch_ink"))
    p.append(_tone(K.rounded_box(HATCH, (0.66, 0.05, 0.28), M((hx, bf - 0.02, hz)), bevel=0.03, segments=2, outline=False, name="hatch"),
                   HATCH, None, HATCH_D))
    # detergent drawer slot (left section)
    bh = H - BAND_Z0
    sx, sz = -W / 2 + 0.128 * W, H - 0.69 * bh
    p.append(K.rounded_box(INK, (0.76, 0.03, 0.24), M((sx, bf - 0.005, sz)), bevel=0.012, segments=1, outline=False, name="slot_ink"))
    p.append(K.rounded_box(SLOT, (0.70, 0.03, 0.18), M((sx, bf - 0.015, sz)), bevel=0.02, segments=1, outline=False, name="slot"))
    p.append(K.rounded_box(SLOT_L, (0.66, 0.03, 0.045), M((sx, bf - 0.025, sz - 0.055)), bevel=0.012, segments=1, outline=False, name="slot_lip"))
    # round white dial with its tick
    dx, dz = -W / 2 + 0.44 * W, H - 0.53 * bh
    p.append(_disc(INK, 0.29, dx, dz, bf - 0.012, seg=24, name="dial_ink"))
    dial = _lathe(DIAL, [(0, 0.17), (0.15, 0.17), (0.21, 0.155), (0.245, 0.12), (0.255, 0.06), (0.255, -0.01)],
                  M((dx, bf, dz)), seg=24, outline=False, name="dial")
    p.append(_tone(dial, DIAL, None, DIAL_D, cut=0.35))
    p.append(K.rounded_box(DIAL_T, (0.035, 0.03, 0.15), M((dx, bf - 0.175, dz + 0.13)), bevel=0.012, segments=1, outline=False, name="tick"))
    # dark display with a diagonal glare
    sx2, sz2 = -W / 2 + 0.765 * W, H - 0.55 * bh
    p.append(K.rounded_box(INK, (1.11, 0.03, 0.52), M((sx2, bf - 0.005, sz2)), bevel=0.02, segments=1, outline=False, name="screen_ink"))
    p.append(K.rounded_box(SCREEN, (1.05, 0.03, 0.46), M((sx2, bf - 0.015, sz2)), bevel=0.03, segments=1, outline=False, name="screen"))
    gy = bf - 0.042
    g = [Vector((sx2 - 0.38, gy, sz2 - 0.21)), Vector((sx2 - 0.22, gy, sz2 - 0.21)),
         Vector((sx2 + 0.10, gy, sz2 + 0.21)), Vector((sx2 - 0.06, gy, sz2 + 0.21))]
    p.append(K.Piece(_mesh(g, [_wind(g, [0, 1, 2, 3], Vector((0, -1, 0)))], "glare"), SCREEN_L, False, False, "glare"))


def _annulus(pal, r_in, r_out, y, off=(0.0, 0.0), seg=64, name="annulus"):
    """Flat ring facing the front round the porthole centre; the outer edge's centre is shifted by
    `off` (x, z), so the ring can be thicker on one side (an ink line heavier on the shaded side)."""
    verts = []
    for j in range(seg):
        a = j / seg * math.tau
        verts.append(Vector((r_out * math.cos(a) + off[0], y, PZ + r_out * math.sin(a) + off[1])))
        verts.append(Vector((r_in * math.cos(a), y, PZ + r_in * math.sin(a))))
    want = Vector((0, -1, 0))
    faces = [_wind(verts, [2 * j, 2 * ((j + 1) % seg), 2 * ((j + 1) % seg) + 1, 2 * j + 1], want) for j in range(seg)]
    return K.Piece(_mesh(verts, faces, name), pal, False, False, name)


def _porthole(p, g, s):
    """Bezel into `p`, the galaxy vortex into `g` (arms, lanes, void) and `s` (stars) - the game
    spins those two layers about the porthole axis at different speeds; returns the outline-only
    pieces for K.finish."""
    # thick blue bezel: a wide, nearly flat front ring with a short rounded inner lip and a straight
    # inner wall down to the galaxy (a deep sloping funnel would sit in its own shadow and read as a
    # second black ring round the vortex), and a rounded outer edge
    prof = [(R_GAL, -0.02), (R_GAL, 0.17), (R_GAL + 0.016, 0.200), (R_GAL + 0.05, 0.213), (R_GAL + 0.095, 0.216),
            (R_BEZ - 0.075, 0.212), (R_BEZ - 0.022, 0.178), (R_BEZ, 0.115), (R_BEZ + 0.005, 0.04), (R_BEZ + 0.005, -0.03)]
    seg = 64
    # no hull of its own: the inner wall's hull would sit in front of the vortex as a heavy black band
    # (top and left). Its ink line is a flat ink ring on the face round its foot (every view, firm on
    # the shaded lower-left), plus an outline-only copy of the front + outer rows, cut at the face
    # plane, for the silhouette in 3/4 views (no hull wall hangs behind the face, so nothing detached).
    bez = _lathe(BEZEL, prof, M((0, FY, PZ)), seg=seg, outline=False, name="bezel")
    line = _lathe(BEZEL, prof[4:-1] + [(R_BEZ + 0.005, 0.0)], M((0, FY, PZ)), seg=seg, name="bezel_line")
    # an even medium-blue ring; only the outer rounded edge is a touch lighter round the top, over a
    # wide arc (+-70 deg) so its ends fall where the ring curves away
    for i in range(len(bez.mesh.polygons)):
        row, j = divmod(i, seg)
        a = math.degrees((j + 0.5) / seg * math.tau)
        if row in (5, 6) and abs(a - 90.0) < 70.0:
            bez.face_pal[i] = BEZEL_L
    p.append(bez)
    p.append(_annulus(INK, R_BEZ - 0.01, R_BEZ + 0.06, FY - 0.004, off=(-0.012, -0.012), name="bezel_ink"))
    # galaxy vortex: 3 arms spiralling clockwise inward (~3/4 turn) into a near-black purple void. Per
    # arm, around the circle: a dark lane (violet edges, deep-indigo middle) that widens near the centre
    # until the lanes close into the void; a violet arm band with a soft 2-step lavender-pink core; then
    # a gap where the glowing DryerPortal disc shows through. The outer ~10% is darker (the arms dim to
    # violet and a violet rim ring hides the glow), as in the art. Depth stack (in front of the white
    # face, + VZ): portal 0.013, rim ring 0.025, arms 0.037, lanes + pink core 0.047 (they never
    # overlap), light core 0.057, void 0.067, stars 0.077, ink rim 0.087 - overlapping layers >= 0.01 apart.
    n, tw = 3, 3.4
    rc, rim, rg = 0.2 * GS, 0.9 * R_GAL, R_GAL - 0.005
    ARM = 0.34  # arm band width (fraction of a turn); the glow gap after it is ~23% of each turn
    per = math.tau / n

    def lane(r):  # lane half-width (radians)
        t = max(0.0, (r - 0.22 * GS) / (R_GAL - 0.22 * GS))
        return per * (0.19 + 0.05 * (1 - t) + 0.24 * math.exp(-t / 0.1))

    def lane_cols(r):
        if r < 0.34 * GS:
            return [G_DEEP, G_CORE, G_CORE, G_DEEP]
        return [G_LANE, G_DEEP, G_DEEP, G_LANE]

    def arm_cols(r):
        return [G_MID, G_ARM, G_ARM, G_ARM] if r < rim else [G_LANE, G_MID, G_MID, G_LANE]

    def core(r0, r1, w, pw=0.7):  # spindle-shaped band in the middle of the arm, tapering at both ends
        def edges(r):
            u = min(1.0, max(0.0, (r - r0) / (r1 - r0)))
            c, h = lane(r) + per * ARM * 0.52, per * ARM * w * math.sin(math.pi * u) ** pw
            return c - h, c + h
        return edges

    g.append(_annulus(G_LANE, rim - 0.01, R_GAL + 0.01, FY - VZ - 0.025, name="gal_rim"))
    for a in range(n):
        th = math.radians(140) + a * per
        for ra, rb in ((rc, 0.34 * GS), (0.34 * GS, rg)):
            g.append(_strip(lane_cols, th, ra, rb, tw, lambda r: (-lane(r), lane(r)), FY - VZ - 0.047, 0.0, PZ,
                            steps=max(4, int(30 * (rb - ra) / (R_GAL - rc))), name="lane"))
        g.append(_strip(arm_cols, th, 0.25 * GS, rg, tw, lambda r: (lane(r), lane(r) + per * ARM), FY - VZ - 0.037, 0.0, PZ,
                        steps=30, name="arm"))
        g.append(_strip([G_PINK], th, 0.36 * GS, 0.86 * R_GAL, tw, core(0.36 * GS, 0.86 * R_GAL, 0.30), FY - VZ - 0.047, 0.0, PZ,
                        steps=20, name="arm_core"))
        g.append(_strip([G_PINK_L], th, 0.46 * GS, 0.76 * R_GAL, tw, core(0.46 * GS, 0.76 * R_GAL, 0.12, 0.6), FY - VZ - 0.057, 0.0, PZ,
                        steps=14, name="arm_core_l"))
    g.append(_disc(G_CORE, 0.23 * GS, 0.0, PZ, FY - VZ - 0.067, seg=24, name="core"))
    # stars: many tiny pinpoints (a third of them strung along the arms) and four larger twinkles
    rnd = random.Random(11)
    sy = FY - VZ - 0.077
    for k in range(54):
        r = rnd.uniform(0.32 * GS, R_GAL - 0.06)
        if k % 3 == 0:  # on an arm: the arm band's angle at that radius
            arm_i = rnd.randrange(n)
            a = math.radians(140) + arm_i * per + tw * math.log(r / R_GAL) + lane(r) + per * ARM * rnd.uniform(0.15, 0.9)
        else:
            a = rnd.uniform(0, math.tau)
        rad = 0.025 if k < 4 else rnd.choice((0.009, 0.010, 0.011, 0.012, 0.013))
        s.append(_disc(G_STAR, rad, r * math.cos(a), PZ + r * math.sin(a), sy, seg=8 if rad > 0.02 else 6, name="star"))
    # the one thin ink line round the galaxy (its outer half is hidden inside the bezel wall)
    p.append(_disc(INK, R_GAL + 0.03, 0, PZ, FY - VZ - 0.087, r_in=R_GAL - 0.016, seg=64, name="gal_ink"))
    return [line]


def _door(p):
    """The open door, built flat (inner face toward -Y, hinge at the local origin, door toward -X)
    then swung so its free edge comes slightly forward: it lies near the front plane, left of the
    porthole. Returns the glass bowl piece (untextured, its own object)."""
    beta = math.radians(180.0 - DOOR_SWING)
    gap = 0.0
    dc = -(gap + R_DOOR)                       # door centre (local x)
    DM = M((HINGE_X, HINGE_Y, PZ), rot=(0, 0, beta)) @ M((dc, 0, 0))
    # near-white silver ring all round: lit top, a pale shade only on the strongly down-facing underside
    ring = _lathe(DOOR, _rrect(0.95 * DS, R_DOOR, -0.09, 0.12, 0.085, n=2), DM, seg=40, closed=True, name="door_ring")
    p.append(_tone(_tone(ring, DOOR, DOOR_L, None, cut=0.6), DOOR, None, DOOR_D, cut=0.85))
    inner = _lathe(DOOR_IN, _rrect(0.84 * DS, 0.98 * DS, -0.06, 0.085, 0.05, n=2), DM, seg=40, closed=True, name="door_inner")
    p.append(_tone(inner, DOOR_IN, None, DOOR_D, cut=0.85))
    # latch on the free edge, a little below the middle
    p.append(K.sphere(LATCH, 1.0, DM @ M((-1.075 * DS, -0.125, -0.08), scale=(0.045, 0.03, 0.08)), seg=10, rings=6, outline=False, name="latch"))
    # hinge plate bridging the door ring and the bezel
    hinge = K.rounded_box(HINGE, (0.16, 0.17, 0.76), M((HINGE_X + 0.02, HINGE_Y - 0.04, PZ), rot=(0, 0, beta * 0.5)), bevel=0.05, segments=2, name="hinge")
    p.append(_tone(hinge, HINGE, None, HINGE_D))
    # shallow glass bowl; its peak stays inside the ring's front so the door adds little depth
    gprof = [(r * DS, d) for r, d in ((0, 0.18), (0.45, 0.16), (0.72, 0.11), (0.88, 0.03), (0.89, -0.02), (0.6, -0.05), (0, -0.06))]
    glass = _lathe(0, gprof, DM, seg=32, outline=False, name="glass")
    # thin ink line where the glass meets the inner lip (just in front of the glass)
    p.append(_lathe(INK, [(0.835 * DS, 0.062), (0.88 * DS, 0.076), (0.92 * DS, 0.082)], DM, seg=40, outline=False, smooth=False, name="glass_ink"))

    def on_glass(r, a, lift=0.012):
        """Local point on the bowl's front at radius r, angle a (0 = toward the hinge, 90 = up)."""
        for (ra, da), (rb, db) in zip(gprof, gprof[1:4]):
            if ra <= r <= rb:
                d = da + (db - da) * (r - ra) / (rb - ra)
                break
        return DM @ Vector((r * math.cos(a), -(d + lift), r * math.sin(a)))
    # glints on the glass (the bowl itself is see-through in game): an arc upper-left, a dash lower-right
    arc = []
    for k in range(9):
        a = math.radians(105 + 55 * k / 8)
        w = 0.035 * math.sin(math.pi * k / 8) + 0.008
        arc += [on_glass((0.70 - w) * DS, a), on_glass((0.70 + w) * DS, a)]
    want = DM.to_3x3() @ Vector((0, -1, 0))
    faces = [_wind(arc, [2 * k, 2 * k + 1, 2 * k + 3, 2 * k + 2], want) for k in range(8)]
    p.append(K.Piece(_mesh(arc, faces, "glint_arc"), GLINT, False, False, "glint_arc"))
    a0, a1 = math.radians(-38), math.radians(-24)
    dash = [on_glass(0.55 * DS, a0), on_glass(0.68 * DS, a0), on_glass(0.68 * DS, a1), on_glass(0.55 * DS, a1)]
    p.append(K.Piece(_mesh(dash, [_wind(dash, [0, 1, 2, 3], want)], "glint_dash"), GLINT, False, False, "glint_dash"))
    return glass


def build():
    p, g, s = [], [], []
    _cabinet(p)
    lines = _porthole(p, g, s)
    glass = _door(p)
    body, outline = K.finish(p, "Dryer", outline_width=0.055, outline_only=lines)
    # the galaxy as two textured layers the game turns (client side) about the Dryer_Pin axis
    vortex = K.textured_object(g, "DryerVortex")
    stars = K.textured_object(s, "DryerStars")
    portal = K.plain_object([K.cylinder(0, R_GAL + 0.02, 0.01, M((0, FY - VZ - 0.008, PZ), rot=(math.pi / 2, 0, 0)), seg=40, smooth=False)], "DryerPortal")
    glass_obj = K.plain_object([glass], "DryerGlass")
    _preview_tint(portal, GLOW_TINT)
    _preview_tint(glass_obj, GLASS_TINT)
    return [body, outline, vortex, stars, portal, glass_obj] + K.markers("Dryer", pin=(0.0, FY, PZ))
