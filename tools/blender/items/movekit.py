"""
items/movekit.py - shared helpers for the movement items (dashslippers, dryersheet, laundrybasket,
staticballoon): the golden versions' palette, gems and sparkles, and the item skeletons' skinning.

- `gold(item)`: registers the polished-gold ramp of one item (call it inside build(), like every
  colour) and returns its palette indices: light / base / dark / deep, `shine` (white glints) and
  `glitter` (pale flecks). The colour names are `<item>_gold...`, so a module's
  MATERIALS = {"<item>_gold": "metal", ...} makes the bake paint them as polished metal.
- `gem(...)`: a small faceted gem (a table, eight crown facets and a short pavilion) standing on a
  surface, its facets toned by the cartoon key light; `sparkle(r)`: a four-point twinkle outline for
  decals; `dots(...)`: scattered glitter positions.
- `skin(name, objs, bones, weigh, extra=None)`: the item's armature `<name>_Rig` (rigging.Bone
  dict), the body weighted piece by piece (`weigh(piece name, piece tag, vertex) -> {bone: w}`; a
  piece's tag is whatever was set as `piece.rig` before K.finish), the `_Outline` hull copying the
  body's weights vertex for vertex, outline-only pieces and thin hulls added after K.finish weighted
  by `extra(vertex)` (default: `weigh(None, None, vertex)`). Root never gets a weight; at most four
  bones per vertex, normalised (rigging._finalise). Bones: head -> tail = local +Y.
"""
import math
from types import SimpleNamespace

import bmesh
import bpy
from mathutils import Vector

import rigging
import sockkit as K
from sockkit import hexcol

KEY = Vector((-0.35, -0.55, 0.76)).normalized()     # the cartoon key light (texturing._highlight's)


# ---------------------------------------------------------------- gold
def gold(item):
    """The polished-gold ramp of one item (palette indices). Register inside build()."""
    p = item + "_gold"
    return SimpleNamespace(
        light=hexcol(p + "_light", "#FFE07E"), base=hexcol(p, "#F2B230"), dark=hexcol(p + "_dark", "#D3801A"),
        deep=hexcol(p + "_deep", "#9A5310"), shine=hexcol(p + "_shine", "#FFFCEB"),
        glitter=hexcol(p + "_glitter", "#FFF8D6"))


def gem_colours(item, what, light, base, dark):
    """(light, base, dark) of one gem colour, named `<item>_gold_gem_<what>` (glass in the bake)."""
    p = f"{item}_gold_gem_{what}"
    return hexcol(p + "_light", light), hexcol(p, base), hexcol(p + "_dark", dark)


# ---------------------------------------------------------------- gems, sparkles, glitter
def gem(cols, centre, normal, r, up=None, n=8, height=0.55, name="gem", outline=False):
    """A faceted gem of radius r standing on a surface at `centre`, its table facing `normal`: a flat
    table (light), n crown facets toned by the key light, a short pavilion sunk into the surface.
    cols = (light, base, dark). Flat shaded."""
    nrm = Vector(normal).normalized()
    up = Vector(up) if up is not None else (Vector((0, 0, 1)) if abs(nrm.z) < 0.9 else Vector((0, 1, 0)))
    side = up.cross(nrm).normalized()
    up = nrm.cross(side).normalized()
    c = Vector(centre)
    bm = bmesh.new()
    girdle, table = [], []
    for i in range(n):
        a = math.tau * (i + 0.5) / n
        d = side * math.cos(a) + up * math.sin(a)
        girdle.append(bm.verts.new(c + d * r + nrm * (r * 0.12)))
        table.append(bm.verts.new(c + d * (r * 0.58) + nrm * (r * height)))
    culet = bm.verts.new(c - nrm * (r * 0.35))
    faces = [bm.faces.new(table)]
    for i in range(n):
        j = (i + 1) % n
        faces.append(bm.faces.new((girdle[i], girdle[j], table[j], table[i])))
        faces.append(bm.faces.new((girdle[j], girdle[i], culet)))
    bm.normal_update()
    for f in bm.faces:                        # outward from the gem's middle
        if f.normal.dot(f.calc_center_median() - (c + nrm * (r * 0.15))) < 0:
            f.normal_flip()
    bm.normal_update()
    pal = []
    for k, f in enumerate(bm.faces):
        if k == 0:
            pal.append(cols[0])
        else:
            lit = f.normal.dot(KEY)
            pal.append(cols[0] if lit > 0.62 else (cols[1] if lit > 0.05 else cols[2]))
    pc = K.Piece(K._bm_to_mesh(bm, name), pal, outline, False, name)
    pc.flat_faces = list(range(len(pal)))
    return pc


def sparkle(r, inner=0.26, cx=0.0, cy=0.0, rot=0.0, n=4):
    """A twinkle: an n-point star outline (CCW) of radius r, the points pinched thin."""
    out = []
    for i in range(2 * n):
        a = rot + math.pi / 2 + math.pi * i / n
        rr = r if i % 2 == 0 else r * inner
        out.append((cx + rr * math.cos(a), cy + rr * math.sin(a)))
    return out


def circle(r, n=10, cx=0.0, cy=0.0, sx=1.0):
    return [(cx + r * sx * math.cos(a), cy + r * math.sin(a)) for a in (k / n * math.tau for k in range(n))]


def dots(count, seed, lo=(-1.0, -1.0), hi=(1.0, 1.0), gap=0.2):
    """`count` scattered 2D points in the box lo..hi, at least ~gap apart (a fixed little hash: the
    same layout every build)."""
    out, k = [], 0
    while len(out) < count and k < count * 60:
        k += 1
        u = (math.sin(seed * 12.9898 + k * 78.233) * 43758.5453) % 1.0
        v = (math.sin(seed * 39.3468 + k * 11.135) * 24634.6345) % 1.0
        p = (lo[0] + (hi[0] - lo[0]) * u, lo[1] + (hi[1] - lo[1]) * v)
        if all((p[0] - q[0]) ** 2 + (p[1] - q[1]) ** 2 > gap * gap for q in out):
            out.append(p)
    return out


# ---------------------------------------------------------------- skeleton
def smooth(e0, e1, x):
    t = max(0.0, min(1.0, (x - e0) / (e1 - e0)))
    return t * t * (3 - 2 * t)


def mix(a, b, t):
    """Weights a * (1 - t) + b * t."""
    return rigging._mix(a, b, t)


def skin(name, objs, bones, weigh, extra=None, rolls=None):
    """`<name>_Rig` from `bones` ({name: rigging.Bone}); skins objs[0] (the body) piece by piece and
    objs[1] (the `_Outline`) with the body's weights. `rolls` = {bone: direction}: those bones' local
    +Z is turned toward that direction (rigging's default: toward the front, -Y). Returns the
    armature object."""
    body = objs[0]
    outline = objs[1] if len(objs) > 1 and objs[1].name == name + "_Outline" else None
    info = K.PIECE_MAP[name]
    names, tags = info["names"], info["tags"]
    W = [None] * len(body.data.vertices)
    bv = body.data.vertices
    for i, rng in enumerate(info["body"]):
        if rng is None:
            continue
        s, n = rng
        for k in range(s, s + n):
            W[k] = rigging._finalise(weigh(names[i], tags[i], bv[k].co.copy()))
    assert all(w is not None for w in W), f"{name}: body vertices without weights"
    ao = rigging.build_armature(name + "_Rig", bones)
    if rolls:
        bpy.ops.object.mode_set(mode="EDIT")
        for b, ref in rolls.items():
            ao.data.edit_bones[b].align_roll(Vector(ref))
        bpy.ops.object.mode_set(mode="OBJECT")
    ao.matrix_world = body.matrix_world.copy()     # preview.py moves items apart before rigging
    rigging._skin(body, ao, W)
    if outline is not None:
        ov = outline.data.vertices
        WO = [None] * len(ov)
        for pi, s, n in info["outline"]:
            br = info["body"][pi]
            for k in range(n):
                WO[s + k] = W[br[0] + k] if br is not None else \
                    rigging._finalise(weigh(names[pi], tags[pi], ov[s + k].co.copy()))
        for k, w in enumerate(WO):                 # thin hulls appended after K.finish
            if w is None:
                co = ov[k].co.copy()
                WO[k] = rigging._finalise(extra(co) if extra else weigh(None, None, co))
        rigging._skin(outline, ao, WO)
    return ao


def bone(name, parent, head, tail, role="item"):
    return rigging.Bone(name, parent, head, tail, role)

