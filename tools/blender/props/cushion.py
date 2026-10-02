"""
props/cushion.py - SlotCushion (ReplicatedStorage.MapMeshes.SlotCushion): the puffy little pillow
every sock sits on in a drawer. Map.luau puts one on each SockSlot part (and hides the flat pad).

A square cushion squashed out of a sphere (round puffy edges, pointy pillow corners), domed and
tufted with a sunken button in the middle, piping cord round its seam. Studs: 6 x 6 x 1.8 (Map
scales it to 7 x 7, as big as fits beside the Slam button). Front -Y, origin floor centre.
"""
import math

import bmesh
import bpy
from mathutils import Vector

import sockkit as K
from sockkit import M, hexcol

NAME = "SlotCushion"

TOP = hexcol("cushion_top", "#F8E8C8")       # cream, lit
SIDE = hexcol("cushion_side", "#EFD3A8")     # cream, round the sides
UNDER = hexcol("cushion_under", "#D8B582")   # shaded underside
PIPING = hexcol("cushion_piping", "#E8798F")  # pink cord
BUTTON = hexcol("cushion_button", "#D9506B")
BUTTON_L = hexcol("cushion_button_light", "#F28CA0")

W = 2.8   # half width (studs)
H = 1.5   # height of the rim (the dome adds DOME on top)
DOME = 0.35
DIP = 0.3  # how deep the tuft pulls the middle of the top down


def _square(x, y):
    """Disc -> square (elliptical grid mapping), so a squashed sphere becomes a pillow."""
    t = 2 * math.sqrt(2)
    a = 2 + x * x - y * y
    sx = 0.5 * math.sqrt(max(a + t * x, 0)) - 0.5 * math.sqrt(max(a - t * x, 0))
    a = 2 - x * x + y * y
    sy = 0.5 * math.sqrt(max(a + t * y, 0)) - 0.5 * math.sqrt(max(a - t * y, 0))
    return sx, sy


def _pillow():
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=20, v_segments=10, radius=1.0)
    for v in bm.verts:
        x, y, z = v.co
        sx, sy = _square(x, y)
        r2 = sx * sx + sy * sy
        # flatter top/bottom with fat round sides; the tuft pulls the top's middle down
        zz = math.copysign(abs(z) ** 0.5, z) * H / 2
        if z > 0:  # puffy dome, pulled down in the middle by the tuft
            zz += DOME * max(0.0, 1 - r2) * z - DIP * math.exp(-r2 / 0.06) * z
        v.co = Vector((sx * W, sy * W, zz + H / 2))
    me = bpy.data.meshes.new("pillow")
    bm.to_mesh(me)
    bm.free()
    pal = []
    for p in me.polygons:
        nz = p.normal.z
        pal.append(TOP if nz > 0.55 else (UNDER if nz < -0.35 else SIDE))
    return K.Piece(me, pal, outline=True, smooth=True, name="pillow")


def _piping():
    """Cord round the seam (the squircle equator), slightly proud of the side."""
    pts = []
    n = 24
    for i in range(n + 1):
        a = i / n * math.tau
        sx, sy = _square(math.cos(a) * 0.999, math.sin(a) * 0.999)
        pts.append((sx * (W + 0.03), sy * (W + 0.03), H / 2))
    return K.tube(PIPING, pts, radius=0.15, res=2, bevel_res=1, caps=False, name="piping")


def build():
    p = [_pillow(), _piping()]
    # tuft button sitting in the dip
    bz = H + DOME - DIP * 0.85
    btn = K.sphere(BUTTON, 0.45, M((0, 0, bz), scale=(1, 1, 0.5)), seg=12, rings=6, name="button")
    btn.face_pal = [BUTTON_L if f.normal.z > 0.8 else BUTTON for f in btn.mesh.polygons]
    p.append(btn)
    body, outline = K.finish(p, NAME, outline_width=0.07)
    return [body, outline] + K.markers(NAME)
