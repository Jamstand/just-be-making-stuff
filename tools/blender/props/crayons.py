"""
props/crayons.py - the Crayons prop (ReplicatedStorage.MapMeshes.Crayons): a small pile of three
big chunky crayons lying on the floor (blue, green, orange), as in docs/concept/bedroom_keyframe.png.
See props/__init__.py for the conventions every prop follows.

Each crayon is one welded lathe mesh along its axis (so the outline hull is watertight), read from
the art from back to tip: a short wax-coloured back end with a rounded flat end, a pale paper
wrapper with one dark band near each end and a pale strip outside it, a small step down to a wax
collar, a ledge, then the sharpened cone with a blunt flat tip. A big dark oval label sits on the
wrapper (one curved patch just above the surface, turned toward the front).
"""
import math
import bmesh
import bpy
from mathutils import Vector
import sockkit as K
from sockkit import M, hexcol
from props.common import *  # noqa: F401,F403 - shared colours (read-only)

NAME = "Crayons"

# (wax base, wax dark, wax light, wrapper, wrapper light, wrapper shade, ink) - sampled from the art
BLUE = (hexcol("crayons_blue", "#3D46B4"), hexcol("crayons_blue_dark", "#2C318C"), hexcol("crayons_blue_light", "#5A64CE"),
        hexcol("crayons_blue_wrap", "#6C80D2"), hexcol("crayons_blue_wrap_l", "#B8C6F0"),
        hexcol("crayons_blue_wrap_d", "#4A5CB8"), hexcol("crayons_blue_ink", "#2A2232"))
GREEN = (hexcol("crayons_green", "#46A524"), hexcol("crayons_green_dark", "#2F7E18"), hexcol("crayons_green_light", "#6CC23E"),
         hexcol("crayons_green_wrap", "#CFD972"), hexcol("crayons_green_wrap_l", "#E2E59A"),
         hexcol("crayons_green_wrap_d", "#A3AC56"), hexcol("crayons_green_ink", "#3A2E26"))
ORANGE = (hexcol("crayons_orange", "#EE7812"), hexcol("crayons_orange_dark", "#C8560C"), hexcol("crayons_orange_light", "#F89A3C"),
          hexcol("crayons_orange_wrap", "#F7D46A"), hexcol("crayons_orange_wrap_l", "#FDE27C"),
          hexcol("crayons_orange_wrap_d", "#E6B248"), hexcol("crayons_orange_ink", "#482C24"))

R = 0.5     # wrapper radius (the crayon is 1 unit thick)
L = 5.0     # length, back end to tip (chunky: the art's crayons are ~5 diameters long)
SEG = 24    # segments round the axis
LIFT = 0.012  # label patch height above the wrapper

# lathe profile: (x from the back end, radius, tag of the span that STARTS here). Proportions measured
# on the art: back cap 4%, pale strip 4%, dark band 7%, body 47%, dark band 7%, pale strip 5%, collar 5%,
# cone 20% narrowing to a blunt flat tip about a third of the radius.
PROFILE = [
    (0.0, 0.0, "cap"), (0.0, 0.34, "cap"), (0.025, 0.43, "cap"), (0.07, 0.475, "cap"), (0.13, 0.485, "cap"),
    (0.2, 0.485, "step"), (0.2, R, "pale"), (0.42, R, "band"), (0.78, R, "body"), (3.14, R, "band"),
    (3.48, R, "pale"), (3.74, R, "step"), (3.74, 0.47, "collar"), (3.98, 0.47, "ledge"), (3.98, 0.44, "cone"),
    (4.94, 0.185, "cone"), (5.0, 0.14, "tip"), (5.0, 0.0, None),
]
LABEL_X, LABEL_A, LABEL_B = 1.96, 0.84, 0.65 # label centre along the axis, half length, half angle (rad)


def _crayon(cols, mat):
    """One crayon lying along its local +X (tip at +X), centred on its middle, axis on local origin."""
    wax, wax_d, wax_l, wrap, wrap_l, wrap_d, ink = cols
    bm = bmesh.new()
    rings = []
    for x, r, _ in PROFILE:
        if r == 0.0:
            rings.append([bm.verts.new((x - L / 2, 0, 0))])
        else:
            rings.append([bm.verts.new((x - L / 2, r * math.cos(a), r * math.sin(a)))
                          for a in (j / SEG * math.tau for j in range(SEG))])
    tags = []
    for i in range(len(rings) - 1):
        a, b, tag = rings[i], rings[i + 1], PROFILE[i][2]
        if len(a) == 1 or len(b) == 1:  # end disc: one n-gon
            ring = b if len(a) == 1 else a
            bm.faces.new(ring)
            tags.append(tag + "_disc")
            continue
        for j in range(SEG):
            k = (j + 1) % SEG
            bm.faces.new((a[j], a[k], b[k], b[j]))
            tags.append(tag)
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if not v.link_faces], context="VERTS")
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    bmesh.ops.transform(bm, matrix=mat, verts=bm.verts)
    bm.normal_update()
    pal, flat = [], []
    for i, (f, t) in enumerate(zip(bm.faces, tags)):
        nz = f.normal.z
        if t in ("cap_disc", "tip_disc", "step", "ledge"):
            flat.append(i)
        if t in ("pale", "body"):  # like the art: pale lit top, base, then a saturated shade on the lower half
            pal.append(wrap_l if nz > 0.7 else (wrap_d if nz < 0.0 else wrap))
        elif t in ("band", "step"):
            pal.append(ink)
        elif t == "ledge":
            pal.append(wax_d)
        else:  # wax: cap, collar, cone, tip
            pal.append(wax_l if nz > 0.75 else (wax_d if nz < -0.35 else wax))
    me = bpy.data.meshes.new("crayon")
    bm.to_mesh(me)
    bm.free()
    p = K.Piece(me, pal, outline=True, smooth=True, name="crayon")
    p.flat_faces = flat
    return p


def _label(ink, mat, roll):
    """The dark oval: an elliptical patch (polar grid) wrapped on the wrapper, turned `roll` rad round
    the axis from straight up (+ toward local -Y)."""
    bm = bmesh.new()
    n, rings_n = 28, 3
    rr = R + LIFT
    centre = bm.verts.new((LABEL_X - L / 2, -rr * math.sin(roll), rr * math.cos(roll)))
    rings = []
    for k in range(1, rings_n + 1):
        s = k / rings_n
        ring = []
        for j in range(n):
            t = j / n * math.tau
            x = LABEL_X - L / 2 + LABEL_A * s * math.cos(t)
            th = roll + LABEL_B * s * math.sin(t)
            ring.append(bm.verts.new((x, -rr * math.sin(th), rr * math.cos(th))))
        rings.append(ring)
    for j in range(n):
        bm.faces.new((centre, rings[0][j], rings[0][(j + 1) % n]))
    for k in range(rings_n - 1):
        a, b = rings[k], rings[k + 1]
        for j in range(n):
            bm.faces.new((a[j], b[j], b[(j + 1) % n], a[(j + 1) % n]))
    bm.normal_update()
    for f in bm.faces:  # face away from the axis
        c = f.calc_center_median()
        if f.normal.dot(Vector((0, c.y, c.z))) < 0:
            f.normal_flip()
    bmesh.ops.transform(bm, matrix=mat, verts=bm.verts)
    me = bpy.data.meshes.new("label")
    bm.to_mesh(me)
    bm.free()
    return K.Piece(me, ink, outline=False, smooth=True, name="label")


# colours, centre (x, y), yaw (local +X = tip direction), label roll (rad from straight up, + toward
# the crayon's local -Y, so a crayon turned round needs a negative roll to face the front). Each crayon
# has ONE oval, like the art: turned toward the front (-Y here = +Z in Roblox, the side players see
# most), centred on the visible side with wrapper above and below it. The green one lies behind the
# orange, so its oval is turned further up, onto the part that shows above the orange (as in the art);
# from straight above every crayon shows a single spot.
# Like the art: green and orange side by side and touching (same yaw, axes 1.05 apart), tips to the
# left, orange in front and pushed back toward its tail end; blue in front pointing the other way.
PILE = [(GREEN, (-0.29, 0.69), math.pi + 0.24, -0.55), (ORANGE, (1.24, -0.01), math.pi + 0.24, -0.95),
        (BLUE, (-0.35, -2.05), -0.16, 0.95)]


def build():
    pieces = []
    for cols, (x, y), yaw, roll in PILE:
        mat = M((x, y, R), rot=(0, 0, yaw))
        pieces.append(_crayon(cols, mat))
        pieces.append(_label(cols[6], mat, roll))
    body, outline = K.finish(pieces, NAME, outline_width=0.055)
    return [body, outline] + K.markers(NAME)
