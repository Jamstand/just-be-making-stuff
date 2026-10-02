"""
props/slambutton.py - SlamButton (ReplicatedStorage.MapMeshes.SlamButton): the big "Slam Drawer"
button in the back corner of every drawer. Map.luau puts it over the game's button part (which
keeps the prompt) and hides that part.

A chunky arcade button: a yellow-and-black hazard-striped box, a dark top plate, a chrome ring and
a fat glossy red dome with a white glint. Studs: 4 x 4 x 3.6 (the Map fit box). Front -Y, origin
floor centre.
"""
import math

import bmesh
import bpy
from mathutils import Vector

import sockkit as K
from sockkit import M, hexcol

NAME = "SlamButton"

YEL = hexcol("slam_yellow", "#F7C531")
YEL_T = hexcol("slam_yellow_top", "#FFD95C")
BLK = hexcol("slam_black", "#26222E")
PLATE = hexcol("slam_plate", "#3A3848")
PLATE_T = hexcol("slam_plate_top", "#55536A")
CHROME = hexcol("slam_chrome", "#D9DEE8")
CHROME_D = hexcol("slam_chrome_dark", "#9AA2B4")
RED = hexcol("slam_red", "#E3343E")
RED_T = hexcol("slam_red_top", "#FF5A5F")
RED_D = hexcol("slam_red_dark", "#A81E2E")
GLINT = hexcol("slam_glint", "#FFF2F0")

BW, BH = 3.8, 1.6     # base box width / height (studs)
STRIPE, GAP = 0.42, 0.42


def _clip(poly, x0, x1, y0, y1):
    """Sutherland-Hodgman clip of a 2D polygon to a rectangle."""
    def cut(pts, inside, inter):
        out = []
        for i, cur in enumerate(pts):
            prev = pts[i - 1]
            if inside(cur):
                if not inside(prev):
                    out.append(inter(prev, cur))
                out.append(cur)
            elif inside(prev):
                out.append(inter(prev, cur))
        return out

    def ix(xc):
        return lambda a, b: (xc, a[1] + (b[1] - a[1]) * (xc - a[0]) / (b[0] - a[0]))

    def iy(yc):
        return lambda a, b: (a[0] + (b[0] - a[0]) * (yc - a[1]) / (b[1] - a[1]), yc)

    for inside, inter in ((lambda p: p[0] >= x0, ix(x0)), (lambda p: p[0] <= x1, ix(x1)),
                          (lambda p: p[1] >= y0, iy(y0)), (lambda p: p[1] <= y1, iy(y1))):
        poly = cut(poly, inside, inter)
        if not poly:
            return []
    return poly


def _stripes():
    """Black 45-degree hazard stripes on the four sides of the base, as flat decals 0.012 proud."""
    verts, faces = [], []
    half = BW / 2
    lo, hi = 0.18, BH - 0.18          # stay off the bevelled edges
    for side in range(4):
        rot = M(rot=(0, 0, side * math.pi / 2))
        k = -6
        while k * (STRIPE + GAP) < BW + BH:
            u0 = -half - BH + k * (STRIPE + GAP)
            band = [(u0, lo), (u0 + STRIPE, lo), (u0 + STRIPE + (hi - lo), hi), (u0 + (hi - lo), hi)]
            poly = _clip(band, -half + 0.18, half - 0.18, lo, hi)
            k += 1
            if len(poly) < 3:
                continue
            base = len(verts)
            for u, z in poly:
                verts.append(rot @ Vector((u, -half - 0.012, z)))
            faces.append(list(range(base, base + len(poly)))[::-1])
    me = bpy.data.meshes.new("stripes")
    me.from_pydata([tuple(v) for v in verts], [], faces)
    me.update()
    # make every stripe face point outward (away from the box centre)
    bm = bmesh.new()
    bm.from_mesh(me)
    for f in bm.faces:
        c = f.calc_center_median()
        if f.normal.dot(Vector((c.x, c.y, 0))) < 0:
            f.normal_flip()
    bm.to_mesh(me)
    bm.free()
    return K.Piece(me, BLK, outline=False, smooth=False, name="stripes")


def build():
    p = []
    base = K.rounded_box(YEL, (BW, BW, BH), M((0, 0, BH / 2)), bevel=0.16, segments=2, name="base")
    base.face_pal = [YEL_T if f.normal.z > 0.6 else YEL for f in base.mesh.polygons]
    p.append(base)
    p.append(_stripes())
    plate = K.rounded_box(PLATE, (BW - 0.5, BW - 0.5, 0.3), M((0, 0, BH + 0.12)), bevel=0.1, segments=2, name="plate")
    plate.face_pal = [PLATE_T if f.normal.z > 0.6 else PLATE for f in plate.mesh.polygons]
    p.append(plate)
    ring = K.torus(CHROME, 1.35, 0.22, M((0, 0, BH + 0.36)), seg=32, mseg=10, name="ring")
    ring.face_pal = [CHROME if f.normal.z > -0.2 else CHROME_D for f in ring.mesh.polygons]
    p.append(ring)
    dome = K.sphere(RED, 1.2, M((0, 0, BH + 0.4), scale=(1, 1, 0.95)), seg=32, rings=14, name="dome")
    dome.face_pal = [(RED_T if f.normal.z > 0.75 else (RED if f.normal.z > -0.1 else RED_D)) for f in dome.mesh.polygons]
    p.append(dome)
    # glint: a small curved white streak upper-left on the dome
    pts = []
    for i in range(7):
        a = math.radians(110 + i * 9)
        r = 0.8
        pts.append((math.cos(a) * r * 0.8, math.sin(a) * r * 0.55 - 0.35, BH + 0.4 + 0.95 * math.sqrt(max(1.2 ** 2 - (r * 0.8) ** 2, 0)) * 0.9))
    p.append(K.tube(GLINT, pts, radius=0.07, radii=[0.5, 1, 1, 1, 1, 1, 0.5], res=4, bevel_res=1, outline=False, name="glint"))
    body, outline = K.finish(p, NAME, outline_width=0.06)
    return [body, outline] + K.markers(NAME)
