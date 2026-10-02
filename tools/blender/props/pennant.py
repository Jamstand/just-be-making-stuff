"""
props/pennant.py - the Pennant prop (ReplicatedStorage.MapMeshes.Pennant): a red felt pennant on the
bedroom wall. See props/__init__.py for the conventions every prop follows.

Art: a long red felt triangle wrapped round a little wooden dowel with round knob ends, a cream trim
band by the dowel and chunky cream felt letters "SOCKS!" that shrink with the triangle toward the
tip; the felt bellies gently off the wall. It hangs a little crooked (tip down) from a cord looped
over a blue push pin, and a golden tassel dangles from the tip.

The lettering is cut with the poster kit's chunky glyphs (props/posterrocket.py) and laid flat on
the felt, then bent and tilted with it. Wall-mounted: the back is on the wall at y = 0, the front
faces -Y; origin = bottom centre of the back plane. About 11.7 x 5.1 x 0.53 units with the hull (Map fit
box 120 x 50 x 6 studs: the height fits it).
"""
import math
import bmesh
import bpy
from mathutils import Matrix, Vector
import sockkit as K
from sockkit import M, hexcol
from props.posterrocket import Art, push_pin, camera_only, PIN_BLUE, RED, RED_D, _glyph_mesh, xform
from props.common import WOOD, WOOD_D, WOOD_L, CREAM, YELLOW

NAME = "Pennant"

# texture classes for tools/blender/texturing.py where the colour names alone guess wrong
MATERIALS = {"posterrocket_red": "felt", "cream": "felt", "block_yellow": "felt", "posterrocket_pin": "plastic"}
EXPORT_DIR = "map"

# mostly shared tones (the room's wood, the posters' reds): one 32 x 32 palette serves the whole game
FELT, FELT_D = RED, RED_D                              # felt / rims, the sleeve's shaded side
FELT_L = hexcol("pennant_felt_light", "#F0634F")     # the sleeve's lit front
TRIM = LETTER = CORD = CREAM
LETTER_SH = hexcol("pennant_letter_shadow", "#8E2430")
TASSEL = YELLOW
TASSEL_D = hexcol("pennant_tassel_dark", "#C98E2E")
INK = K.OUTLINE

OUTLINE = 0.075       # hull width (~1.5% of its height)
XS = -5.55            # dowel axis
XT = 5.55             # felt tip
Z_LO, Z_HI = 0.85, 4.15   # felt at the dowel
ZC = (Z_LO + Z_HI) / 2
DOWEL_Y = -0.2        # dowel axis in front of the wall
DOWEL_R = 0.1
SLEEVE_R = 0.17
FELT_T = 0.05         # felt thickness
FELT_Y = -0.03        # felt back
BELLY = 0.06          # how far the felt bellies off the wall mid-way
TILT = -0.09          # radians (tip down)
PIVOT = (XS, 4.45)    # it hangs from the top of the dowel
DY = 0.012            # paint layer step on the felt


def _wave(x):
    """How far the felt stands off its rest plane at x (a soft belly between dowel and tip)."""
    t = min(max((x - XS) / (XT - XS), 0.0), 1.0)
    return BELLY * math.sin(math.pi * t) ** 1.5


def _felt_z(x):
    """Bottom and top edge of the felt at x."""
    t = min(max((x - XS) / (XT - XS), 0.0), 1.0)
    return ZC + (Z_LO - ZC) * (1 - t), ZC + (Z_HI - ZC) * (1 - t)


def _felt():
    """The felt triangle as a closed slab (front, back, rims), bellying off the wall: front faces in
    felt red, the back and the cut edges in the darker red."""
    nx, nz = 22, 4
    bm = bmesh.new()
    front, back = [], []
    for i in range(nx + 1):
        x = XS + (XT - XS) * i / nx
        lo, hi = _felt_z(x)
        w = _wave(x)
        fr, bk = [], []
        for j in range(nz + 1):
            z = ZC if i == nx else lo + (hi - lo) * j / nz
            fr.append(bm.verts.new((x, FELT_Y - FELT_T - w, z)))
            bk.append(bm.verts.new((x, FELT_Y - w, z)))
        front.append(fr)
        back.append(bk)
    tip = lambda grid, j: grid[nx][0]  # the tip column collapses to one point per side
    for i in range(nx):
        for j in range(nz):
            for grid in (front, back):
                if i + 1 == nx:
                    bm.faces.new((grid[i][j], tip(grid, j), grid[i][j + 1]))
                else:
                    bm.faces.new((grid[i][j], grid[i + 1][j], grid[i + 1][j + 1], grid[i][j + 1]))
    for i in range(nx):  # top and bottom edges
        for j in (0, nz):
            a, d = front[i][j], back[i][j]
            b, c = (tip(front, j), tip(back, j)) if i + 1 == nx else (front[i + 1][j], back[i + 1][j])
            bm.faces.new((a, b, c, d))
    for j in range(nz):  # the end round the dowel
        bm.faces.new((front[0][j], front[0][j + 1], back[0][j + 1], back[0][j]))
    for col in front[nx][1:] + back[nx][1:]:  # unused duplicate tip verts
        bm.verts.remove(col)
    bm.normal_update()
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new("felt")
    bm.to_mesh(me)
    bm.free()
    pal = [FELT if f.normal.y < -0.6 else FELT_D for f in me.polygons]
    return K.Piece(me, pal, outline=True, smooth=False, name="felt")


def _lettering():
    """Cream trim band and "SOCKS!" (shrinking toward the tip), flat paint in front of the felt."""
    art = Art()
    lo0, hi0 = _felt_z(XS + 0.45)
    lo1, hi1 = _felt_z(XS + 0.75)
    art.add([[(XS + 0.45, lo0 + 0.02), (XS + 0.75, lo1 + 0.02), (XS + 0.75, hi1 - 0.02), (XS + 0.45, hi0 - 0.02)]], TRIM)
    x = XS + 1.1
    letters = []
    for ch in "SOCKS!":
        # each letter as tall as the felt allows where it stands (cap height ~0.73 of the size)
        lo, hi = _felt_z(x + 0.3)
        size = (hi - lo) * 0.78
        polys = _glyph_mesh(ch, 0.06)
        xs = [p[0] for poly in polys for p in poly]
        w = (max(xs) - min(xs)) * size
        cx = (min(xs) + max(xs)) / 2
        base = ZC - 0.37 * size
        fill = [xform([(u - cx, v) for u, v in poly], x + w / 2, base, 0.0, size) for poly in polys]
        ink = [xform([(u - cx, v) for u, v in poly], x + w / 2, base, 0.0, size) for poly in _glyph_mesh(ch, 0.06 + 0.05)]
        letters.append((fill, ink))
        x += w + 0.1 * size
    for fill, ink in letters:
        art.add(ink, INK)
        art.add([xform(p, 0.07, -0.08) for p in ink], INK)
    for fill, ink in letters:
        art.add([xform(p, 0.07, -0.08) for p in fill], LETTER_SH)
    for fill, ink in letters:
        art.add(fill, LETTER)
    pc = art.piece(0.0, DY, name="letters")
    for v in pc.mesh.vertices:  # onto the bellied felt front
        v.co.y += FELT_Y - FELT_T - _wave(v.co.x) - 0.004
    return pc


def _dowel():
    """The wooden dowel (wood above and below the felt sleeve) with round knobs, and the sleeve: the
    felt wrapped round it (lit front, shaded sides)."""
    out = []
    dowel = K.cylinder(WOOD, DOWEL_R, 3.9, M((XS, DOWEL_Y, 2.5)), seg=12, smooth=True, name="dowel")
    out.append(dowel)
    for z in (0.5, 4.5):
        knob = K.sphere(WOOD, 0.19, M((XS, DOWEL_Y, z), scale=(1, 1, 0.9)), seg=14, rings=8, name="knob")
        knob.face_pal = [WOOD_L if f.center.z > z + 0.08 else WOOD_D if f.center.z < z - 0.08 else WOOD
                         for f in knob.mesh.polygons]
        out.append(knob)
    sleeve = K.cylinder(FELT, SLEEVE_R, Z_HI - Z_LO, M((XS, DOWEL_Y, ZC)), seg=16, smooth=True, name="sleeve")
    sleeve.face_pal = [FELT_D if abs(f.normal.z) > 0.9 else (FELT_L if f.normal.y < -0.5 else FELT if f.normal.y < 0.3 else FELT_D)
                       for f in sleeve.mesh.polygons]
    out.append(sleeve)
    return out


def _tilt_matrix():
    px, pz = PIVOT
    return Matrix.Translation((px, 0, pz)) @ Matrix.Rotation(-TILT, 4, "Y") @ Matrix.Translation((-px, 0, -pz))


def _tassel(top, k=1.15):
    """Hangs straight down from `top` (world): a short cord, a knot ball, a wrapped neck and a flared
    skirt of strands (alternating tones). k scales it."""
    x, y, z = top
    out = [K.tube(CORD, [(x, y, z), (x + 0.01, y, z - 0.15 * k), (x, y, z - 0.28 * k)], radius=0.035, res=4,
                  bevel_res=1, name="tassel_cord")]
    out.append(K.sphere(TASSEL, 0.12 * k, M((x, y, z - 0.36 * k)), seg=12, rings=8, name="tassel_knot"))
    out.append(K.cylinder(TASSEL_D, 0.11 * k, 0.12 * k, M((x, y, z - 0.52 * k)), seg=12, smooth=False, name="tassel_wrap"))
    seg = 12
    zc, h = z - 0.88 * k, 0.62 * k
    skirt = K.cylinder(TASSEL, 0.1 * k, h, M((x, y, zc)), radius2=0.08 * k, seg=seg, smooth=False, name="tassel_skirt")
    for v in skirt.mesh.vertices:  # flare the bottom (radius1 is the bottom ring)
        if v.co.z < zc - h / 4:
            v.co.x, v.co.y = x + (v.co.x - x) * 2.1, y + (v.co.y - y) * 1.5  # flatter toward the wall
    skirt.face_pal = []
    for f in skirt.mesh.polygons:  # strands in two tones, dark caps
        a = math.atan2(f.center.y - y, f.center.x - x)
        strand = int((a + math.pi) / math.tau * seg) % 2 == 0
        skirt.face_pal.append(TASSEL_D if len(f.vertices) > 4 or not strand else TASSEL)
    out.append(skirt)
    return out


def build():
    tilt = _tilt_matrix()
    p = [_felt(), _lettering()] + _dowel()
    for pc in p:
        pc.mesh.transform(tilt)
    # the tip after tilting: the tassel hangs straight down from it
    tip = tilt @ Vector((XT - 0.05, FELT_Y - FELT_T / 2 - _wave(XT), ZC))
    p += _tassel((tip.x, -0.21, tip.z))
    # the cord from the top knob up to a push pin in the wall
    knob = tilt @ Vector((XS, DOWEL_Y, 4.5))
    pin_at = (knob.x + 0.05, knob.z + 0.42)
    p.append(K.tube(CORD, [(knob.x - 0.1, DOWEL_Y + 0.06, knob.z + 0.1), (pin_at[0] - 0.04, -0.06, pin_at[1] - 0.05),
                           (pin_at[0] + 0.04, -0.06, pin_at[1] - 0.05), (knob.x + 0.12, DOWEL_Y + 0.06, knob.z + 0.12)],
                    radius=0.03, res=6, bevel_res=1, name="cord"))
    p += push_pin(pin_at[0], pin_at[1], 0.0, PIN_BLUE)
    body, outline = K.finish(p, NAME, outline_width=OUTLINE)
    camera_only(outline)
    return [body, outline] + K.markers(NAME)
