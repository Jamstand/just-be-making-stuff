"""
props/lamp.py - the Lamp prop (ReplicatedStorage.MapMeshes.Lamp). See props/__init__.py for
the conventions every prop follows.

Matches the globe lamp on the nightstand in docs/concept/bedroom_keyframe.png: a BIG, slightly squashed
glowing globe sunk into a low, wide wooden plinth - a short vertical skirt with a 45-degree chamfer up to
the rim the globe sits in (measured from the art: plinth 0.83 x the globe's width at the floor,
0.65 x at the rim, 0.155 x its height; globe 0.9 as tall as wide).
- `LampGlow` = the globe, untextured; Map.luau turns it Neon pale yellow (255, 229, 138).
- Ink as in the art: amber round the globe and along the globe/plinth seam, glow-tinted dark brown
  round the plinth (the plinth colours bake in the glow, so it stands out from the nightstand top).
Map.luau fits the model into 36 x 44 x 36 studs and stands it on the Nightstand's top centre.
"""
import math
import bmesh
import sockkit as K
from mathutils import Vector
from sockkit import M, hexcol
from props.common import *  # noqa: F401,F403 - shared colours (read-only)

NAME = "Lamp"

# the globe's glow is baked into the plinth (in game the bulb's SpotLight points down from inside the globe
# and barely reaches it): brighter and yellower than the nightstand it stands on (art skirt #EA8A3D,
# chamfer/rim #F8B646, against the slab front #B65733)
LAMP_WOOD = hexcol("lamp_wood", "#DB8240")         # plinth skirt
LAMP_WOOD_L = hexcol("lamp_wood_light", "#F4B44C")  # chamfer + rim (lit by the globe)
LAMP_WOOD_D = hexcol("lamp_wood_dark", "#8A4329")   # underside
GLOBE_INK = hexcol("lamp_globe_ink", "#D29A26")     # the globe's amber ink line in the art (#D8A122), also
#                                                     the globe/plinth seam (art #EBB535)
LAMP_INK = hexcol("lamp_plinth_ink", "#5A1E08")     # the plinth's ink: glow-tinted dark brown (art #8C310A)

R = 1.5                 # globe radius (width 3.0)
SQUASH = 0.9            # globe height / width
BASE_R = 1.25           # plinth radius at the floor
RIM_R = 0.98            # plinth radius at the rim (where the globe sits)
SKIRT_H = 0.2
TOP = 0.5               # plinth height
# globe centre: the squashed sphere passes through the rim corner (RIM_R, TOP)
CZ = TOP + R * SQUASH * math.sqrt(1 - (RIM_R / R) ** 2) - 0.02
SEG = 40
OUTLINE_W = 0.065

# plinth profile, bottom to top, in sections: (r, z) points; sections meet with a crisp corner
SECTIONS = [
    [(BASE_R - 0.05, 0.0), (BASE_R - 0.012, 0.012), (BASE_R, 0.05), (BASE_R, SKIRT_H)],  # skirt
    [(BASE_R, SKIRT_H), (RIM_R + 0.02, TOP - 0.03)],                                       # chamfer
    [(RIM_R + 0.02, TOP - 0.03), (RIM_R - 0.005, TOP - 0.004), (RIM_R - 0.06, TOP)],      # rim
]


def _ring(bm, r, z):
    return [bm.verts.new((r * math.cos(i / SEG * math.tau), r * math.sin(i / SEG * math.tau), z)) for i in range(SEG)]


def _lathe(sections, split):
    """Revolves the profile. split=True: every section gets its own vertices (crisp profile corners for
    the visible mesh); split=False: one welded shell (for the inverted-hull outline - no cracks)."""
    bm = bmesh.new()
    rings = []  # (ring, section index)
    for si, sec in enumerate(sections):
        for pi, (r, z) in enumerate(sec):
            if pi == 0 and si > 0 and not split:
                continue  # welded: reuse the previous section's last ring
            rings.append((_ring(bm, r, z), si, pi == 0))
    for k in range(1, len(rings)):
        ring, si, first = rings[k]
        if split and first:
            continue  # new section starts: no faces back to the previous one
        prev = rings[k - 1][0]
        for i in range(SEG):
            j = (i + 1) % SEG
            bm.faces.new((prev[i], prev[j], ring[j], ring[i]))
    bm.faces.new(list(reversed(rings[0][0])))  # bottom cap
    bm.faces.new(rings[-1][0])  # top cap (hidden under the globe)
    # winding is outward by construction (an open split strip would confuse recalc_face_normals)
    return K._bm_to_mesh(bm, "lamp_plinth")


def _plinth():
    me = _lathe(SECTIONS, split=True)
    pal, flat = [], []
    for i, f in enumerate(me.polygons):
        nz = f.normal.z
        pal.append(LAMP_WOOD_L if nz > 0.5 else (LAMP_WOOD_D if nz < -0.6 else LAMP_WOOD))
        if len(f.vertices) > 4:
            flat.append(i)
    p = K.Piece(me, pal, outline=False, smooth=True, name="plinth")
    p.flat_faces = flat
    hull = K.Piece(_lathe(SECTIONS, split=False), K.OUTLINE, outline=True, smooth=True, name="plinth_hull")
    return p, hull


def _globe(pal=0):
    return K.sphere(pal, R, M((0, 0, CZ), scale=(1, 1, SQUASH)), seg=32, rings=18, name="globe")


def _globe_r(z):
    """Radius of the (squashed) globe at height z."""
    t = (z - CZ) / (R * SQUASH)
    return R * math.sqrt(max(0.0, 1 - t * t))


def _seam():
    """The ink line where the globe meets the plinth rim (the hull only draws silhouettes, and this
    seam is not one): a thin amber cone hugging the globe just above the rim (amber like the art's)."""
    z0, z1 = TOP - 0.03, TOP + 0.07
    return K.cylinder(GLOBE_INK, _globe_r(z0) + 0.012, z1 - z0, M((0, 0, (z0 + z1) / 2)), seg=SEG,
                      outline=False, cap=False, radius2=_globe_r(z1) + 0.012, name="seam")


def build():
    plinth, plinth_hull = _plinth()
    n_plinth = len(plinth_hull.mesh.polygons)  # the outline merges plinth_hull's faces first, then the globe's
    body, outline = K.finish([plinth, _seam()], NAME, outline_width=OUTLINE_W, outline_only=[plinth_hull, _globe()])
    # ink colours as in the art: the globe's line is amber all the way round (also where it meets the
    # plinth), the plinth's is a glow-tinted dark brown
    uv = outline.data.uv_layers["UVMap"].data
    globe_uv, plinth_uv = K.swatch_uv(GLOBE_INK), K.swatch_uv(LAMP_INK)
    for f in outline.data.polygons:
        for li in f.loop_indices:
            uv[li].uv = plinth_uv if f.index < n_plinth else globe_uv
    # Cycles-only (no effect on the GLB / game): keep the hull from blocking bounce/sky light in previews
    outline.visible_diffuse = False
    outline.visible_glossy = False
    outline.visible_transmission = False
    glow = K.plain_object([_globe()], "LampGlow")
    # no material / texture (the game colours it), but a UV map on the globe swatch so the preview and
    # Studio show it pale yellow instead of black before Map.luau recolours it
    gu, gv = K.swatch_uv(GLOBE)
    for d in glow.data.uv_layers.new(name="UVMap").data:
        d.uv = (gu, gv)
    for f in glow.data.polygons:
        f.use_smooth = True
    return [body, outline, glow] + K.markers(NAME)
