"""
Hero fighters: one skinned mesh per legend on the shared SkyRig skeleton.

A legend script (fighters/<name>.py) describes its body tweaks, outfit,
accessories, sway chains and paint. This module turns that into:

  * an armature whose bones are the skeleton's joints (same names as the
    game's joints) plus the legend's sway bones (capes, hair, tails);
  * a body: lofted shapes melted into one organic surface (voxel remesh),
    with outfit layers grown off it (so cloth follows the body and never
    pokes through), and accessories;
  * skin weights by body region, blended across each joint, so everything
    bends together;
  * a painted 1024 texture (color with baked light, wear and edges, plus a
    metalness and a roughness map for Roblox's SurfaceAppearance);
  * an FBX (armature + skinned "Body" + import markers) and rig data for
    src/shared/FighterRigs.luau.
"""

import json
import math
import os

import bmesh
import bpy
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree

from . import common, skeleton
from .common import RIG_TO_BLENDER, MeshBuilder, Palette, rig_to_blender

TO_RIG = RIG_TO_BLENDER.transposed()
EXPORT_DIR = os.path.join(common.EXPORT_DIR, "fighters")
TRI_BUDGET = 20000


def to_rig(v):
    return TO_RIG @ Vector(v)


def B(p):
    """Rig space -> Blender."""
    return rig_to_blender(p)


def smoothstep(a, b, x):
    if b == a:
        return 1.0 if x >= b else 0.0
    t = max(0.0, min(1.0, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)


def lerp(a, b, t):
    return a + (b - a) * t


def vlerp(a, b, t):
    return tuple(x + (y - x) * t for x, y in zip(a, b))


# Armature -----------------------------------------------------------------------------


class Sway:
    """A chain of sway bones (cape, ponytail, tails): `points` in rig space
    from the attach point down to the tip; one bone per segment, named
    <name>1, <name>2, ... The game swings them with springs."""

    def __init__(self, name, parent, points, stiffness=0.35, damping=0.18, limit=70.0, behind=None, width=0.3):
        self.name = name
        self.parent = parent
        self.points = [tuple(p) for p in points]
        self.stiffness = stiffness
        self.damping = damping
        self.limit = limit
        self.behind = behind  # keep the chain behind (+1) or in front (-1) of the body
        self.width = width  # how far sideways the weights spread

    @property
    def bones(self):
        return [f"{self.name}{i + 1}" for i in range(len(self.points) - 1)]


def build_armature(name, sways, collection):
    arm_data = bpy.data.armatures.new(name + "Rig")
    arm = bpy.data.objects.new(name + "Rig", arm_data)
    collection.objects.link(arm)
    bpy.context.view_layer.objects.active = arm
    for o in bpy.context.view_layer.objects:
        o.select_set(o is arm)
    bpy.ops.object.mode_set(mode="EDIT")
    eb = arm_data.edit_bones
    for joint, _, _, pivot in skeleton.JOINTS:
        b = eb.new(joint)
        b.head = B(pivot)
        b.tail = B(skeleton.tail(joint))
        b.roll = 0.0
    for joint, _, _, _ in skeleton.JOINTS:
        parent = skeleton.PARENT_JOINT[joint]
        if parent:
            eb[joint].parent = eb[parent]
            eb[joint].use_connect = False
    for sw in sways:
        prev = sw.parent
        for bone, (a, b_) in zip(sw.bones, zip(sw.points, sw.points[1:])):
            e = eb.new(bone)
            e.head = B(a)
            e.tail = B(b_)
            e.parent = eb[prev]
            e.use_connect = prev != sw.parent
            prev = bone
    bpy.ops.object.mode_set(mode="OBJECT")
    arm.data.display_type = "STICK"
    return arm


# Body -----------------------------------------------------------------------------------

BASE_BODY = {
    "shoulders": 1.0,  # chest/shoulder width
    "chest": 1.0,  # chest depth (pecs)
    "bust": 0.0,  # 0..1 feminine chest shape
    "waist": 1.0,
    "hips": 1.0,
    "arms": 1.0,  # arm thickness
    "legs": 1.0,
    "neck": 1.0,
    "jaw": 1.0,  # jaw width
    "head": 1.0,
}


P = skeleton.PIVOT
META_STIFF = 2.0
META_THRESHOLD = 0.6
META_K = 0.575  # surface radius / element radius for an isolated element at these settings


class Meta:
    """Collects metaball elements (rig space, surface sizes) for one
    smoothly blended surface."""

    def __init__(self):
        self.elements = []

    def ball(self, center, radii, stiffness=META_STIFF, negative=False):
        if isinstance(radii, (int, float)):
            radii = (radii, radii, radii)
        r = max(radii)
        self.elements.append(("ELLIPSOID", tuple(center), r / META_K, tuple(x / r for x in radii), None, 0.0,
                              -stiffness if negative else stiffness))

    def capsule(self, a, b, radius, stiffness=META_STIFF):
        a, b = Vector(a), Vector(b)
        self.elements.append(("CAPSULE", tuple((a + b) / 2), radius / META_K, (1, 1, 1), tuple(b - a),
                              (b - a).length / 2, stiffness))

    def limb(self, points, radii, stiffness=META_STIFF):
        """Capsules through `points` with tapering `radii` (one per point)."""
        for (a, b), (ra, rb) in zip(zip(points, points[1:]), zip(radii, radii[1:])):
            steps = max(1, int((Vector(b) - Vector(a)).length / 0.12))
            for i in range(steps):
                t0, t1 = i / steps, (i + 1) / steps
                self.capsule(vlerp(a, b, t0), vlerp(a, b, t1), lerp(ra, rb, (t0 + t1) / 2), stiffness)

    def build(self, name, collection, resolution=0.026):
        mb = bpy.data.metaballs.new(name + "Meta")
        mb.resolution = resolution
        mb.render_resolution = resolution
        mb.threshold = META_THRESHOLD
        obj = bpy.data.objects.new(name + "Meta", mb)
        collection.objects.link(obj)
        for kind, center, radius, size, axis, half, stiffness in self.elements:
            e = mb.elements.new(type=kind)
            e.co = B(center)
            e.radius = radius
            e.stiffness = abs(stiffness)
            e.use_negative = stiffness < 0
            if kind == "CAPSULE":
                e.size_x = half
                d = (RIG_TO_BLENDER @ Vector(axis)).normalized()
                e.rotation = Vector((1, 0, 0)).rotation_difference(d)
            else:
                # rig (x, y, z) sizes -> Blender axes (x, z, y)
                e.size_x, e.size_y, e.size_z = size[0], size[2], size[1]
        bpy.context.view_layer.update()
        dg = bpy.context.evaluated_depsgraph_get()
        me = bpy.data.meshes.new_from_object(obj.evaluated_get(dg))
        out = bpy.data.objects.new(name, me)
        collection.objects.link(out)
        bpy.data.objects.remove(obj)
        bpy.data.metaballs.remove(mb)
        return out


def body_meta(cfg):
    """The bare body as blended metaball elements (rig space)."""
    m = Meta()
    sw, ch, wa, hp = cfg["shoulders"], cfg["chest"], cfg["waist"], cfg["hips"]
    ar, lg, nk = cfg["arms"], cfg["legs"], cfg["neck"]
    hip_y, sh_y = P["RightHip"][1], P["RightShoulder"][1]
    k = (sh_y - hip_y) / 1.56

    def T(y):  # torso heights, laid out for a hip at 3.0 and shoulders at 4.56
        return hip_y + (y - 3.0) * k

    # torso: overlapping ellipsoids (y, rx, ry, rz, z)
    for y, rx, ry, rz, z in ((2.92, 0.46 * hp, 0.26, 0.32, 0.04), (3.25, 0.46 * hp, 0.28, 0.31, 0.02),
                             (3.6, 0.44 * wa, 0.3, 0.31, 0.02), (3.95, 0.58 * lerp(wa, sw, 0.7), 0.32, 0.37 * ch, 0.0),
                             (4.28, 0.72 * sw, 0.3, 0.4 * ch, 0.0), (4.54, 0.7 * sw, 0.2, 0.33, 0.04)):
        m.ball((0, T(y), z), (rx, ry * k, rz))
    for s in (-1, 1):
        if cfg["bust"] > 0:
            b = cfg["bust"]
            m.ball((s * 0.24, T(4.05), -0.2 * ch), (0.2, 0.18 + 0.03 * b, 0.16 + 0.07 * b))
        else:
            m.ball((s * 0.28, T(4.2), -0.18 * ch), (0.27 * sw, 0.19, 0.17 * ch))
        m.ball((s * 0.42 * sw, T(4.05), 0.12), (0.2, 0.36 * k, 0.2))  # lats
        m.ball((s * 0.22 * hp, T(2.95), 0.18), (0.24 * hp, 0.24, 0.22))  # glutes
        m.capsule((s * 0.1, 5.02, 0.1), (s * 0.62 * sw, sh_y + 0.1, 0.06), 0.15)  # trapezius
    m.capsule((0, sh_y + 0.06, 0.06), (0, 5.12, 0.03), 0.2 * nk)  # neck
    for side, s in skeleton.SIDES:
        sh = skeleton.PIVOT[f"{side}Shoulder"]
        el = skeleton.PIVOT[f"{side}Elbow"]
        wr = skeleton.PIVOT[f"{side}Wrist"]
        m.ball((sh[0] - s * 0.04, sh[1] - 0.06, sh[2]), (0.25 * ar, 0.27 * ar, 0.25 * ar))  # deltoid
        m.limb([(sh[0], sh[1] - 0.12, sh[2]), vlerp(sh, el, 0.5), el], [0.2 * ar, 0.19 * ar, 0.15 * ar])
        m.ball(vlerp(sh, el, 0.5), (0.13 * ar, 0.2, 0.13 * ar))  # biceps/triceps
        m.limb([el, vlerp(el, wr, 0.3), wr], [0.16 * ar, 0.17 * ar, 0.12 * ar])
        m.ball((wr[0], wr[1] - 0.02, wr[2]), (0.11, 0.1, 0.12))  # wrist
    for side, s in skeleton.SIDES:
        hip = skeleton.PIVOT[f"{side}Hip"]
        kn = skeleton.PIVOT[f"{side}Knee"]
        an = skeleton.PIVOT[f"{side}Ankle"]
        m.limb([(hip[0] + s * 0.02, hip[1] - 0.05, 0.0), vlerp(hip, kn, 0.45), kn],
               [0.27 * lg, 0.24 * lg, 0.17 * lg])
        m.ball((hip[0] + s * 0.04, lerp(hip[1], kn[1], 0.4), -0.06), (0.19 * lg, 0.4, 0.2 * lg))  # quads
        m.limb([kn, vlerp(kn, an, 0.3), an], [0.17 * lg, 0.18 * lg, 0.12 * lg])
        m.ball((kn[0], lerp(kn[1], an[1], 0.3), 0.07), (0.15 * lg, 0.3, 0.16 * lg))  # calf
        # foot
        m.capsule((an[0], 0.15, 0.1), (an[0] + s * 0.01, 0.13, -0.42), 0.15)
        m.ball((an[0], 0.24, 0.0), (0.15, 0.16, 0.2))
    head_meta(m, cfg)
    return m


def head_meta(m, cfg):
    """Stylized heroic head: skull, strong jaw and chin, brow, cheekbones,
    nose and ears. The face looks toward -Z."""
    jw, hd = cfg["jaw"], cfg["head"]
    m.ball((0, 5.58, 0.04), (0.34 * hd, 0.4 * hd, 0.38 * hd))
    m.ball((0, 5.3, -0.08), (0.27 * jw, 0.24, 0.28))  # jaw
    m.ball((0, 5.14, -0.22), (0.12 * jw, 0.08, 0.09))  # chin
    m.ball((0, 5.62, -0.28), (0.26 * hd, 0.06, 0.06), stiffness=1.6)  # brow
    for s in (-1, 1):
        m.ball((s * 0.18, 5.42, -0.24), (0.1, 0.07, 0.07), stiffness=1.5)  # cheekbones
        m.ball((s * 0.34 * hd, 5.48, 0.06), (0.05, 0.1, 0.07), stiffness=2.5)  # ears
    m.capsule((0, 5.54, -0.33), (0, 5.4, -0.4), 0.045, stiffness=2.5)  # nose
    m.ball((0, 5.37, -0.39), (0.06, 0.04, 0.04), stiffness=2.5)


# Building and melting pieces into one object -----------------------------------------------


def builder_object(mb, name, collection):
    obj = mb.build(collection)
    obj.name = name
    return obj


def remesh(obj, voxel=0.024, smooth=4, smooth_factor=0.5):
    """Melts overlapping pieces into one surface and softens the voxel steps
    (keeping the volume)."""
    m = obj.modifiers.new("Remesh", "REMESH")
    m.mode = "VOXEL"
    m.voxel_size = voxel
    m.adaptivity = 0.0
    if smooth:
        sm = obj.modifiers.new("Smooth", "LAPLACIANSMOOTH")
        sm.iterations = smooth
        sm.lambda_factor = smooth_factor
        sm.use_volume_preserve = True
        sm.use_normalized = True
    apply_modifiers(obj)
    return obj


def apply_modifiers(obj):
    dg = bpy.context.evaluated_depsgraph_get()
    me = bpy.data.meshes.new_from_object(obj.evaluated_get(dg))
    old = obj.data
    obj.modifiers.clear()
    obj.data = me
    bpy.data.meshes.remove(old)
    return obj


def decimate(obj, tris):
    """Collapses `obj` down to about `tris` triangles."""
    n = triangles(obj)
    if n <= tris:
        return obj
    m = obj.modifiers.new("Decimate", "DECIMATE")
    m.ratio = tris / n
    m.use_collapse_triangulate = True
    apply_modifiers(obj)
    return obj


def triangles(obj):
    return sum(len(p.vertices) - 2 for p in obj.data.polygons)


__all__ = ["Sway", "build_armature", "BASE_BODY", "body_pieces", "remesh", "decimate", "apply_modifiers",
           "triangles", "to_rig", "B", "smoothstep", "lerp", "vlerp", "MeshBuilder", "Palette", "Matrix", "Vector",
           "BVHTree", "bmesh", "json", "math", "os", "TRI_BUDGET", "EXPORT_DIR"]


# Skin weights ----------------------------------------------------------------------------
#
# Every vertex (body, clothes, accessories) gets weights from its rig-space
# position: it belongs to the arm, leg or spine chain nearest it, and blends
# between consecutive bones across each joint, so layers bend together.

BLEND = 0.12  # half-width (studs) of the blend across a joint


def _project(p, a, b):
    """(t along a->b in studs, distance to the segment)."""
    p, a, b = Vector(p), Vector(a), Vector(b)
    ab = b - a
    length = ab.length
    t = (p - a).dot(ab) / length
    tc = max(0.0, min(length, t))
    return t, (p - (a + ab * (tc / length))).length


def _chain_weights(p, chain):
    """chain = [(bone, a, b), ...] consecutive segments. Arc-length blend
    between consecutive bones; returns ({bone: w}, distance, t of the first
    segment)."""
    best = None
    offset = 0.0
    for i, (bone, a, b) in enumerate(chain):
        t, d = _project(p, a, b)
        length = (Vector(b) - Vector(a)).length
        if best is None or d < best[1]:
            best = (i, d, offset + t)
        offset += length
    _, dist, s = best
    weights = {}
    joint_s = 0.0
    bones = [c[0] for c in chain]
    lengths = [(Vector(c[2]) - Vector(c[1])).length for c in chain]
    w_prev = 1.0
    for i, bone in enumerate(bones):
        start = joint_s
        joint_s += lengths[i]
        # share of this bone: from its start joint to the next
        w_in = smoothstep(start - BLEND, start + BLEND, s) if i > 0 else 1.0
        w_out = 1.0 - smoothstep(joint_s - BLEND, joint_s + BLEND, s) if i < len(bones) - 1 else 1.0
        w = min(w_in, w_out)
        if w > 1e-4:
            weights[bone] = w
        w_prev = w
    first_t, _ = _project(p, chain[0][1], chain[0][2])
    return weights, dist, first_t


def _arm_chain(side):
    g = skeleton.GRIP[side]
    return [(f"{side}Shoulder", P[f"{side}Shoulder"], P[f"{side}Elbow"]),
            (f"{side}Elbow", P[f"{side}Elbow"], P[f"{side}Wrist"]),
            (f"{side}Wrist", P[f"{side}Wrist"], (g[0], g[1] - 0.25, g[2]))]


def _leg_chain(side):
    an = P[f"{side}Ankle"]
    return [(f"{side}Hip", P[f"{side}Hip"], P[f"{side}Knee"]),
            (f"{side}Knee", P[f"{side}Knee"], an),
            (f"{side}Ankle", an, (an[0], 0.1, an[2] - 0.6))]


def _spine_weights(p):
    y = p[1]
    w_low = 1.0 - smoothstep(P["Waist"][1] - 0.16, P["Waist"][1] + 0.12, y)
    w_head = smoothstep(P["Neck"][1] - 0.06, P["Neck"][1] + 0.1, y)
    w_up = max(0.0, 1.0 - w_low - w_head)
    out = {}
    for bone, w in (("Root", w_low), ("Waist", w_up), ("Neck", w_head)):
        if w > 1e-4:
            out[bone] = w
    return out


def _mix(a, b, t):
    out = {}
    for k, v in a.items():
        out[k] = out.get(k, 0.0) + v * (1 - t)
    for k, v in b.items():
        out[k] = out.get(k, 0.0) + v * t
    return out


def body_weights(p):
    """{bone: weight} for a rig-space point near the body (normalized, at
    most 4 influences)."""
    x, y, z = p
    side = "Right" if x >= 0 else "Left"
    spine = _spine_weights(p)
    # arms: the point must sit off the torso, past the shoulder
    arm_w, arm_d, arm_t = _chain_weights(p, _arm_chain(side))
    sh = P[f"{side}Shoulder"]
    out_x = abs(x) - (abs(sh[0]) - 0.32)
    arm_share = 0.0
    if arm_d < 0.42 and out_x > 0:
        arm_share = smoothstep(-0.2, 0.06, arm_t) * smoothstep(0.0, 0.16, out_x) * (1.0 - smoothstep(0.3, 0.42, arm_d))
    # legs: below the hips
    leg_w, leg_d, leg_t = _chain_weights(p, _leg_chain(side))
    hip = P[f"{side}Hip"]
    leg_share = 0.0
    if leg_d < 0.5 and y < hip[1] + 0.12:
        leg_share = smoothstep(-0.02, 0.2, leg_t) * (1.0 - smoothstep(0.4, 0.5, leg_d))
        # the crotch and the inner thigh stay with their own leg; the buttocks blend
        leg_share = max(leg_share, smoothstep(hip[1] - 0.05, hip[1] - 0.3, y))
    w = spine
    if leg_share > 0:
        w = _mix(w, leg_w, min(1.0, leg_share))
    if arm_share > 0:
        w = _mix(w, arm_w, min(1.0, arm_share))
    return normalize_weights(w)


class Where:
    """Which body region a rig point belongs to: kind is "head", "torso",
    "arm" or "leg"; s is the distance along the limb from its root joint
    (shoulder or hip)."""

    def __init__(self, p):
        x, y, z = p
        self.x, self.y, self.z = x, y, z
        self.side = "Right" if x >= 0 else "Left"
        w = body_weights(p)
        arm = sum(v for k, v in w.items() if k.endswith(("Shoulder", "Elbow", "Wrist")))
        leg = sum(v for k, v in w.items() if k.endswith(("Hip", "Knee", "Ankle")))
        if arm >= 0.5:
            self.kind = "arm"
            self.s = _chain_arc(p, _arm_chain(self.side))
        elif leg >= 0.5:
            self.kind = "leg"
            self.s = _chain_arc(p, _leg_chain(self.side))
        elif y > P["Neck"][1] + 0.12:
            self.kind = "head"
            self.s = 0.0
        else:
            self.kind = "torso"
            self.s = 0.0


def _chain_arc(p, chain):
    best = None
    offset = 0.0
    for bone, a, b in chain:
        t, d = _project(p, a, b)
        if best is None or d < best[1]:
            best = (offset + t, d)
        offset += (Vector(b) - Vector(a)).length
    return best[0]


def normalize_weights(w, limit=4):
    items = sorted(((k, v) for k, v in w.items() if v > 1e-3), key=lambda kv: -kv[1])[:limit]
    total = sum(v for _, v in items) or 1.0
    return {k: v / total for k, v in items}


def sway_weights(p, sway, root_share=0.15):
    """Weights for a piece hanging from a sway chain: blend down the chain
    by the nearest segment, with a little of the parent bone at the top."""
    best = None
    for i, (a, b) in enumerate(zip(sway.points, sway.points[1:])):
        t, d = _project(p, a, b)
        if best is None or d < best[1]:
            best = (i, d, t, (Vector(b) - Vector(a)).length)
    i, _, t, length = best
    frac = max(0.0, min(1.0, t / length))
    bones = sway.bones
    w = {}
    if i == 0:
        w[sway.parent] = root_share * (1 - frac)
    w[bones[i]] = 1.0
    if i + 1 < len(bones) and frac > 0.6:
        w[bones[i + 1]] = (frac - 0.6) / 0.4 * 0.5
    if i > 0 and frac < 0.4:
        w[bones[i - 1]] = (0.4 - frac) / 0.4 * 0.5
    return normalize_weights(w)


def skirt_weights(p, top, bottom):
    """A skirt hangs from the hips and follows both thighs partway: its
    lower rows blend toward the hip bone on their side, so it neither
    splits between the legs nor stays stiff when a knee comes up."""
    x, y, z = p
    t = 0.65 * smoothstep(top, bottom, y)
    right = smoothstep(-0.25, 0.25, x)
    w = {"Root": 1.0 - t}
    if t * right > 1e-3:
        w["RightHip"] = t * right
    if t * (1 - right) > 1e-3:
        w["LeftHip"] = t * (1 - right)
    return normalize_weights(w)


# Materials (paint zones) ---------------------------------------------------------------------
#
# Each palette color is a paint zone: a base color plus how it is painted
# (cloth, leather, metal, skin, hair, fur, ...), its metalness and roughness.

FINISH = {
    "cloth": dict(metal=0.0, rough=0.85, grain=0.12, scale=60.0, edge=0.25),
    "quilt": dict(metal=0.0, rough=0.8, grain=0.1, scale=40.0, edge=0.3),
    "leather": dict(metal=0.0, rough=0.55, grain=0.18, scale=28.0, edge=0.45),
    "metal": dict(metal=1.0, rough=0.32, grain=0.1, scale=80.0, edge=0.8),
    "gold": dict(metal=1.0, rough=0.25, grain=0.06, scale=80.0, edge=0.9),
    "skin": dict(metal=0.0, rough=0.6, grain=0.05, scale=18.0, edge=0.15),
    "hair": dict(metal=0.0, rough=0.5, grain=0.25, scale=14.0, edge=0.35),
    "fur": dict(metal=0.0, rough=0.9, grain=0.3, scale=45.0, edge=0.2),
    "plate": dict(metal=0.3, rough=0.35, grain=0.06, scale=40.0, edge=0.7),
    "glow": dict(metal=0.0, rough=0.4, grain=0.0, scale=10.0, edge=0.0),
    "gem": dict(metal=0.2, rough=0.15, grain=0.0, scale=10.0, edge=0.6),
}


class Zone:
    def __init__(self, key, color, finish="cloth", **over):
        self.key = key
        self.color = color
        self.finish = dict(FINISH[finish], **over)
        self.kind = finish


def linear(hexcolor):
    """sRGB hex -> scene-linear RGB (what shader color inputs expect)."""
    out = []
    for c in common.hex_color(hexcolor):
        out.append(c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4)
    return tuple(out)


def zones_from(colors):
    """COLORS entries are "#hex" or ("#hex", finish, {overrides})."""
    out = {}
    for key, spec in colors.items():
        if isinstance(spec, str):
            out[key] = Zone(key, spec, "cloth")
        else:
            out[key] = Zone(key, spec[0], spec[1], **(spec[2] if len(spec) > 2 else {}))
    return out


# Geometry helpers ------------------------------------------------------------------------------


def bm_to_object(bm, name, collection, material_index=0):
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    obj = bpy.data.objects.new(name, me)
    collection.objects.link(obj)
    for p in obj.data.polygons:
        p.material_index = material_index
    return obj


def boundary_loops(bm):
    """Ordered vertex loops along the open edges of a bmesh."""
    edges = {e for e in bm.edges if e.is_boundary}
    loops = []
    while edges:
        e = edges.pop()
        loop = [e.verts[0], e.verts[1]]
        closed = False
        while True:
            v = loop[-1]
            nxt = [x for x in v.link_edges if x in edges]
            if not nxt:
                break
            e2 = nxt[0]
            edges.discard(e2)
            w = e2.other_vert(v)
            if w is loop[0]:
                closed = True
                break
            loop.append(w)
        if len(loop) >= 3:
            loops.append((loop, closed))
    return loops


def smooth_polyline(points, iterations, closed):
    pts = [Vector(p) for p in points]
    n = len(pts)
    for _ in range(iterations):
        new = list(pts)
        for i in range(n):
            if not closed and (i == 0 or i == n - 1):
                continue
            a, b = pts[(i - 1) % n], pts[(i + 1) % n]
            new[i] = pts[i] * 0.5 + (a + b) * 0.25
        pts = new
    return pts


def tube_bm(points, radius, closed=True, sides=6, normals=None):
    """bmesh tube along a polyline (Blender coords)."""
    bm = bmesh.new()
    pts = [Vector(p) for p in points]
    n = len(pts)
    rings = []
    for i in range(n):
        a = pts[(i - 1) % n] if (closed or i > 0) else pts[i]
        b = pts[(i + 1) % n] if (closed or i < n - 1) else pts[i]
        t = (b - a).normalized()
        ref = normals[i] if normals else Vector((0, 0, 1))
        u = (ref - t * ref.dot(t))
        u = u.normalized() if u.length > 1e-6 else t.orthogonal().normalized()
        w = t.cross(u)
        r = radius(i / max(1, n - 1)) if callable(radius) else radius
        ring = []
        for k in range(sides):
            ang = 2 * math.pi * k / sides
            ring.append(bm.verts.new(pts[i] + (u * math.cos(ang) + w * math.sin(ang)) * r))
        rings.append(ring)
    count = n if closed else n - 1
    for i in range(count):
        r0, r1 = rings[i], rings[(i + 1) % n]
        for k in range(sides):
            bm.faces.new((r0[k], r0[(k + 1) % sides], r1[(k + 1) % sides], r1[k]))
    if not closed:
        bm.faces.new(list(reversed(rings[0])))
        bm.faces.new(rings[-1])
    return bm


def _loft_rings(rings, caps=True):
    """bmesh through closed rings of Blender points (same count each)."""
    bm = bmesh.new()
    made = [[bm.verts.new(p) for p in ring] for ring in rings]
    n = len(made[0])
    for r0, r1 in zip(made, made[1:]):
        for k in range(n):
            bm.faces.new((r0[k], r0[(k + 1) % n], r1[(k + 1) % n], r1[k]))
    if caps:
        bm.faces.new(list(reversed(made[0])))
        bm.faces.new(made[-1])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return bm


def ribbon_bm(points, normals, width, thickness):
    """A flat strap along a polyline lying on a surface (Blender coords)."""
    bm = bmesh.new()
    n = len(points)
    top, bot = [], []
    for i in range(n):
        a = points[max(0, i - 1)]
        b = points[min(n - 1, i + 1)]
        t = (b - a).normalized()
        nrm = normals[i]
        side = t.cross(nrm).normalized()
        w = width(i / max(1, n - 1)) if callable(width) else width
        p = points[i]
        top.append((bm.verts.new(p + side * w / 2 + nrm * thickness), bm.verts.new(p - side * w / 2 + nrm * thickness)))
        bot.append((bm.verts.new(p + side * w / 2), bm.verts.new(p - side * w / 2)))
    for i in range(n - 1):
        (a1, a2), (b1, b2) = top[i], top[i + 1]
        (c1, c2), (d1, d2) = bot[i], bot[i + 1]
        bm.faces.new((a1, b1, b2, a2))
        bm.faces.new((c2, d2, d1, c1))
        bm.faces.new((a1, c1, d1, b1))
        bm.faces.new((a2, b2, d2, c2))
    for (a1, a2), (c1, c2), flip in ((top[0], bot[0], False), (top[-1], bot[-1], True)):
        f = (a1, a2, c2, c1)
        bm.faces.new(tuple(reversed(f)) if flip else f)
    return bm


class Surface:
    """Raycasts and nearest-point queries against everything built so far."""

    def __init__(self, objects):
        bm = bmesh.new()
        for obj in objects:
            tmp = obj.data.copy()
            tmp.transform(obj.matrix_world)
            bm.from_mesh(tmp)
            bpy.data.meshes.remove(tmp)
        bmesh.ops.triangulate(bm, faces=bm.faces)
        self.tree = BVHTree.FromBMesh(bm)
        bm.free()

    def nearest(self, p):
        """Rig-space point -> (Blender point on surface, Blender normal)."""
        loc, nrm, _, _ = self.tree.find_nearest(B(p))
        return loc, nrm

    def ring(self, center, axis, radial_ref, count=32, reach=0.8, max_gap=0.1):
        """Cross-section of the outfit around `axis` through `center` (rig
        space): marching out from the axis, the outermost surface within
        `reach` in each direction (so arms or the other leg don't count)."""
        c = B(center)
        ax = (RIG_TO_BLENDER @ Vector(axis)).normalized()
        ref = (RIG_TO_BLENDER @ Vector(radial_ref))
        u = (ref - ax * ref.dot(ax)).normalized()
        w = ax.cross(u)
        pts, nrms = [], []
        for k in range(count):
            ang = 2 * math.pi * k / count
            d = u * math.cos(ang) + w * math.sin(ang)
            origin, last, gone = c, None, 0.0
            while gone < reach:
                hit = self.tree.ray_cast(origin + d * 1e-4, d, reach - gone)
                if hit[0] is None:
                    break
                if last is not None and (hit[0] - last).length > max_gap:
                    break  # past a gap: that's another limb, not this layer stack
                last = hit[0]
                gone = (last - c).length
                origin = last
            pts.append(last if last is not None else c + d * 0.1)
            nrms.append(d)
        return pts, nrms


# The hero builder --------------------------------------------------------------------------------


def _rig_dir(v):
    return TO_RIG @ Vector(v)


def align_y(normal_rig):
    """Rotation matrix taking +Y to a rig-space direction (for MeshBuilder)."""
    return Vector((0, 1, 0)).rotation_difference(Vector(normal_rig).normalized()).to_matrix()


def surface_frame(normal, along):
    """Rotation for MeshBuilder pieces lying on a surface: local Y points
    out along `normal`, local Z runs `along` the surface (rig directions)."""
    n = Vector(normal).normalized()
    a = Vector(along)
    a = (a - n * a.dot(n)).normalized()
    x = n.cross(a)
    return Matrix((x, n, a)).transposed()


class Hero:
    """Builds one legend. Fighter scripts call these in order: body(),
    garments, bands, straps and pieces, then the pipeline calls finish()."""

    def __init__(self, module):
        self.name = module.NAME
        self.module = module
        self.zones = zones_from(module.COLORS)
        self.cfg = dict(BASE_BODY, **getattr(module, "BODY", {}))
        self.sways = list(getattr(module, "SWAYS", []))
        self.col = bpy.data.collections.new(self.name)
        bpy.context.scene.collection.children.link(self.col)
        self.palette = Palette(self.name, {k: z.color for k, z in self.zones.items()})
        self.materials = {}
        self.pieces = []  # (object, binding): None = body weights, ("bone", name), ("sway", Sway)
        self.covers = []  # (keep, hem points) for deleting skin under clothes
        self.body_obj = None
        self.body_lo = None  # a lighter copy of the body that garments grow from
        self.decals = []

    def export_path(self, filename):
        return os.path.join(common.ensure_dir(os.path.join(EXPORT_DIR, "decals")), filename)

    # materials
    def mat(self, key):
        if key not in self.materials:
            z = self.zones[key]
            m = bpy.data.materials.new(f"{self.name}_{key}")
            m.use_nodes = True
            bsdf = m.node_tree.nodes.get("Principled BSDF")
            bsdf.inputs["Base Color"].default_value = (*linear(z.color), 1)
            bsdf.inputs["Metallic"].default_value = z.finish["metal"]
            bsdf.inputs["Roughness"].default_value = z.finish["rough"]
            m["zone"] = key
            self.materials[key] = m
        return self.materials[key]

    def paint(self, obj, key):
        obj.data.materials.clear()
        obj.data.materials.append(self.mat(key))
        for p in obj.data.polygons:
            p.material_index = 0
            p.use_smooth = True

    def add(self, obj, binding=None, decimate=False):
        obj["decimate"] = decimate
        self.pieces.append((obj, binding))
        return obj

    # body
    def body(self, tris=7000, garment_tris=3400):
        obj = body_meta(self.cfg).build(self.name + "Skin", self.col)
        lo = obj.copy()
        lo.data = obj.data.copy()
        lo.name = self.name + "SkinLo"
        self.col.objects.link(lo)  # modifiers only evaluate on linked objects
        decimate(lo, garment_tris)
        lo.hide_render = True
        lo.hide_viewport = True
        decimate(obj, tris)
        self.paint(obj, "skin")
        self.body_obj = obj
        self.body_lo = lo
        return self.add(obj, decimate=True)

    # MeshBuilder pieces (rig-space primitives)
    def builder(self):
        return MeshBuilder("Piece", self.palette)

    def piece(self, mb, binding=None, name="Piece"):
        obj = mb.build(self.col)
        obj.name = name
        attr = obj.data.attributes.get("color")
        keys = list(self.palette.colors)
        obj.data.materials.clear()
        slots = {}
        for p in obj.data.polygons:
            key = keys[attr.data[p.index].value] if attr else keys[0]
            if key not in slots:
                slots[key] = len(obj.data.materials)
                obj.data.materials.append(self.mat(key))
            p.material_index = slots[key]
        return self.add(obj, binding)

    def outer(self):
        return [o for o, _ in self.pieces]

    def surface(self):
        return Surface(self.outer())

    # garments grown off the body
    def garment(self, keep, color, gap=0.03, thickness=0.035, smooth=3, hem=None, hem_radius=0.03, cover=True,
                name="Garment", inflate=None):
        """Cloth over the body faces where keep(rig point) is true, `gap`
        studs off the skin (a number or f(rig point)), `thickness` thick.
        `hem` adds a rolled hem in that color along every open edge."""
        bm = bmesh.new()
        bm.from_mesh(self.body_lo.data)
        _cut(bm, keep)
        gone = [f for f in bm.faces if not keep(to_rig(f.calc_center_median()))]
        bmesh.ops.delete(bm, geom=gone, context="FACES")
        bmesh.ops.delete(bm, geom=[v for v in bm.verts if not v.link_faces], context="VERTS")
        _unpinch(bm)
        # drop specks
        islands = _islands(bm)
        for isl in islands:
            if len(isl) < 12:
                bmesh.ops.delete(bm, geom=list(isl), context="FACES")
        bmesh.ops.delete(bm, geom=[v for v in bm.verts if not v.link_faces], context="VERTS")
        bm.normal_update()
        for v in bm.verts:
            off = gap(to_rig(v.co)) if callable(gap) else gap
            if inflate:
                off += inflate(to_rig(v.co))
            v.co += v.normal * off
        for _ in range(smooth):
            bmesh.ops.smooth_vert(bm, verts=[v for v in bm.verts if not v.is_boundary], factor=0.5,
                                  use_axis_x=True, use_axis_y=True, use_axis_z=True)
        _unpinch(bm)
        loops = boundary_loops(bm)
        for loop, closed in loops:
            pts = smooth_polyline([v.co for v in loop], 4, closed)
            for v, p in zip(loop, pts):
                move = p - v.co
                if move.length > 0.03:  # a hem only straightens, it never travels
                    move = move.normalized() * 0.03
                v.co = v.co + move
        bm.normal_update()
        hems = [([v.co.copy() for v in loop], [v.normal.copy() for v in loop], closed) for loop, closed in loops]
        obj = bm_to_object(bm, name, self.col)
        if thickness:
            mod = obj.modifiers.new("Solidify", "SOLIDIFY")
            mod.thickness = thickness
            mod.offset = 1.0
            mod.use_even_offset = False  # even thickness can shoot vertices out at sharp folds
            mod.thickness_clamp = 1.0
            mod.use_rim = True
            apply_modifiers(obj)
        self.paint(obj, color)
        self.add(obj, decimate=True)
        if hem:
            for pts, nrms, closed in hems:
                if len(pts) < 4:
                    continue
                pts = [p + n * (thickness * 0.5) for p, n in zip(pts, nrms)]
                keep_every = max(1, int(len(pts) / max(8, _length(pts, closed) / 0.13)))
                pts, nrms = pts[::keep_every], nrms[::keep_every]
                tb = tube_bm(pts, hem_radius, closed=closed, sides=4, normals=nrms)
                t = bm_to_object(tb, name + "Hem", self.col)
                self.paint(t, hem)
                self.add(t)
        if cover:
            self.covers.append((keep, [p for pts, _, _ in hems for p in pts]))
        return obj

    # bands around the body or a limb (belts, cuffs, boot tops, collars)
    def band(self, center, axis, height, color, thickness=0.035, offset=0.0, ref=(0, 0, -1), count=None, bevel=False,
             binding=None, name="Band", flare=0.0, arc=None, reach=None):
        """A band hugging the outfit around `axis` through `center`. `flare`
        widens its lower edge (cuffs, collars); `arc` = (a0, a1) degrees from
        `ref` makes it an open band (an open-front collar)."""
        surf = self.surface()
        around_torso = abs(center[0]) < 0.2 and center[1] > 2.7
        if reach is None:
            reach = 0.9 if around_torso else 0.5
        if count is None:
            count = 24
        pts, nrms = surf.ring(center, axis, ref, count, reach)
        closed = arc is None
        if not closed:
            a0, a1 = arc
            idx = [k for k in range(count) if a0 <= (360.0 * k / count) <= a1]
            pts, nrms = [pts[k] for k in idx], [nrms[k] for k in idx]
        pts = smooth_polyline(pts, 2, closed)
        ax = (RIG_TO_BLENDER @ Vector(axis)).normalized()
        bm = bmesh.new()
        h = height / 2
        rows = []
        for dy, out in ((-h, offset), (-h, offset + thickness + flare), (h, offset + thickness),
                        (h, offset)):
            rows.append([bm.verts.new(p + ax * dy + n * out) for p, n in zip(pts, nrms)])
        n = len(pts)
        for r in range(4):
            a, b = rows[r], rows[(r + 1) % 4]
            for k in range(n if closed else n - 1):
                bm.faces.new((a[k], a[(k + 1) % n], b[(k + 1) % n], b[k]))
        if not closed:
            bm.faces.new([rows[r][0] for r in range(4)])
            bm.faces.new([rows[r][-1] for r in reversed(range(4))])
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
        obj = bm_to_object(bm, name, self.col)
        if bevel:
            mod = obj.modifiers.new("Bevel", "BEVEL")
            mod.width = min(0.012, thickness * 0.4)
            mod.segments = 2
            apply_modifiers(obj)
        self.paint(obj, color)
        return self.add(obj, binding)

    # straps lying on the surface
    def strap(self, points, width, color, thickness=0.025, offset=0.006, samples=34, binding=None, name="Strap"):
        pts = _resample([Vector(p) for p in points], samples)
        surf = self.surface()
        on, nrms = [], []
        for p in pts:
            loc, nrm = surf.nearest(p)
            on.append(loc + nrm * offset)
            nrms.append(nrm)
        on = smooth_polyline(on, 3, False)
        bm = ribbon_bm(on, nrms, width, thickness)
        obj = bm_to_object(bm, name, self.col)
        self.paint(obj, color)
        return self.add(obj, binding)

    def ribbon(self, points, facing, width, color, thickness=0.03, samples=24, binding=None, name="Ribbon"):
        """A free-hanging flat ribbon (sash tails, scarf ends) through rig
        points, its broad side facing `facing` (rig direction)."""
        pts = [B(p) for p in _resample([Vector(p) for p in points], samples)]
        nrm = (RIG_TO_BLENDER @ Vector(facing)).normalized()
        bm = ribbon_bm(pts, [nrm] * len(pts), width, thickness)
        obj = bm_to_object(bm, name, self.col)
        self.paint(obj, color)
        return self.add(obj, binding)

    def hands(self, palm="skin", fingers=None, cuff=None, scale=1.12):
        """Big stylized fists around the grips (a weapon handle runs through
        them front to back): back of the hand, a row of curled fingers along
        the bottom, a thumb on top. `fingers` colors the fingers (fingerless
        gloves), `cuff` adds a glove cuff at the wrist."""
        fingers = fingers or palm
        k = scale
        for side, s in skeleton.SIDES:
            gx, gy, gz = skeleton.GRIP[side]
            mb = self.builder()
            mb.box((gx + s * 0.02, gy + 0.05, gz + 0.01), (0.22 * k, 0.27 * k, 0.29 * k), palm, bevel=0.07 * k,
                   segments=2)
            for i in range(4):  # index (front) to little finger (back): one rounded knuckle-to-tip roll each
                z = gz - 0.105 * k + i * 0.07 * k
                r = (0.045 - 0.004 * i) * k
                mb.capsule((gx + s * 0.08 * k, gy - 0.05 * k, z), (gx - s * 0.07 * k, gy - 0.07 * k, z), r, fingers,
                           segments=6)
            mb.capsule((gx - s * 0.04 * k, gy + 0.12 * k, gz - 0.12 * k), (gx - s * 0.09 * k, gy + 0.0, gz - 0.17 * k),
                       0.05 * k, fingers, segments=6)
            wr = skeleton.PIVOT[f"{side}Wrist"]
            mb.limb((wr[0], wr[1] + 0.03, wr[2]), (gx + s * 0.01, gy + 0.12, gz + 0.01), 0.11 * k, 0.12 * k, palm,
                    segments=10, caps=False)
            if cuff:
                mb.cylinder((wr[0], wr[1] + 0.02, wr[2]), 0.14 * k, 0.12, cuff, segments=12)
            self.piece(mb, name=f"{side}Fist")

    def face(self, eyes="#3b2414", brows="#3a2418", lips="#8a3d33", skin_shadow="#00000000", mouth="smile",
             brow_tilt=(0.0, 0.0), eye_size=1.0, extras=None, lids="#20140f", lashes=False, y_eyes=5.56):
        """Paints a stylized heroic face from the front: eyes with lids and
        highlights, brows, mouth. `brow_tilt` (her right, her left) raises
        the outer end of each brow; extras(canvas, cx, ey) paints more."""
        w, hgt = 0.8, 0.7
        c = Canvas(w, hgt, px=700)
        cx = w / 2
        y0 = y_eyes - 0.36  # canvas y 0 in rig space
        ey = 0.36
        k = eye_size
        for s, tilt in ((1, brow_tilt[0]), (-1, brow_tilt[1])):
            ex = cx - s * 0.16  # her right eye is on the canvas left
            c.ellipse(ex, ey, 0.085 * k, 0.05 * k, "#f7f1ea")
            c.ellipse(ex - s * 0.006, ey - 0.002, 0.042 * k, 0.047 * k, eyes)
            c.ellipse(ex - s * 0.006, ey - 0.002, 0.02 * k, 0.025 * k, "#100a08")
            c.ellipse(ex - s * 0.006 + 0.014, ey + 0.016, 0.01 * k, 0.01 * k, "#ffffff")
            lid = curve_pts((ex - 0.095 * k, ey + 0.008), (ex + 0.095 * k, ey + 0.008), -0.05 * k)
            c.stroke(lid, 0.02 * k, lids)
            if lashes:
                c.stroke([(ex - s * 0.09 * k, ey + 0.02), (ex - s * 0.12 * k, ey + 0.045)], 0.014, lids)
            # brow: inner end low, outer end raised by `tilt`
            inner, outer = (ex + s * 0.07, ey + 0.085), (ex - s * 0.1, ey + 0.09 + tilt)
            c.stroke(curve_pts(inner, outer, -0.02), 0.034, brows)
        mouths = {
            "smile": [curve_pts((cx - 0.1, 0.07), (cx + 0.1, 0.07), 0.03)],
            "smirk": [[(cx - 0.11, 0.075), (cx - 0.02, 0.064), (cx + 0.06, 0.068), (cx + 0.12, 0.09)]],
            "neutral": [[(cx - 0.08, 0.07), (cx + 0.08, 0.07)]],
        }
        if mouth == "grin":
            c.polygon(curve_pts((cx - 0.12, 0.085), (cx + 0.12, 0.085), 0.0, 6)
                      + list(reversed(curve_pts((cx - 0.12, 0.085), (cx + 0.12, 0.085), 0.11, 10))), "#4a1712")
            c.polygon(curve_pts((cx - 0.105, 0.08), (cx + 0.105, 0.08), 0.0, 4)
                      + list(reversed(curve_pts((cx - 0.1, 0.058), (cx + 0.1, 0.058), 0.012, 4))), "#fbf6ee")
        elif mouth in mouths:
            for line in mouths[mouth]:
                c.stroke(line, 0.022, lips)
        if extras:
            extras(c, cx, ey)
        img = c.save(self.export_path(f"{self.name}_face.png"))
        self.decals.append(Decal(img, (0.0, y0 + hgt / 2, -0.3), (w, hgt), zones={"skin"}))

    def lock(self, points, width, thickness, color, binding=None, sides=7, name="Lock", taper=0.15):
        """A stylized hair lock (or braid, tail, tassel): a smooth flattened
        tube along a curve through rig points, tapering to a tip. Its flat
        side faces away from the head."""
        pts = _resample([Vector(p) for p in points], max(6, int(_length([Vector(p) for p in points], False) / 0.08)))
        head = Vector((0, 5.55, 0.02))
        bm = bmesh.new()
        rings = []
        n = len(pts)
        for i, p in enumerate(pts):
            a, b = pts[max(0, i - 1)], pts[min(n - 1, i + 1)]
            t = (b - a).normalized()
            out = p - head
            out = (out - t * out.dot(t))
            out = out.normalized() if out.length > 1e-6 else t.orthogonal().normalized()
            side = t.cross(out).normalized()
            f = i / (n - 1)
            scale = max(0.0, 1 - f ** 1.8) * (1 - taper) + taper * (1 - f)
            wi = (width(f) if callable(width) else width) * max(scale, 0.02) / 2
            th = (thickness(f) if callable(thickness) else thickness) * max(scale, 0.02) / 2
            ring = []
            for k in range(sides):
                ang = 2 * math.pi * k / sides
                q = p + side * math.cos(ang) * wi + out * math.sin(ang) * th
                ring.append(bm.verts.new(B(q)))
            rings.append(ring)
        for i in range(n - 1):
            r0, r1 = rings[i], rings[i + 1]
            for k in range(sides):
                bm.faces.new((r0[k], r0[(k + 1) % sides], r1[(k + 1) % sides], r1[k]))
        bm.faces.new(list(reversed(rings[0])))
        bm.faces.new(rings[-1])
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
        obj = bm_to_object(bm, name, self.col)
        self.paint(obj, color)
        return self.add(obj, binding)

    def tint(self, keep, color, target=None):
        """Paints part of the body (or `target`) in another color with a
        clean edge: stubble, tight sleeves, socks, tattoos. No extra layer,
        so nothing can poke through."""
        obj = target or self.body_obj
        bm = bmesh.new()
        bm.from_mesh(obj.data)
        _cut(bm, keep)
        mats = obj.data.materials
        mat = self.mat(color)
        if mat.name not in [m.name for m in mats]:
            mats.append(mat)
        index = [m.name for m in mats].index(mat.name)
        for f in _faces_where(bm, keep):
            f.material_index = index
            f.smooth = True
        bm.to_mesh(obj.data)
        bm.free()
        return obj

    def blob(self, shape, color, tris=900, name="Blob", binding=None, resolution=0.03, cover=None):
        """An organic piece from blended metaball shapes: shape(meta) adds
        balls and capsules (hair masses, beards, fur, pauldrons)."""
        m = Meta()
        shape(m)
        obj = m.build(name, self.col, resolution)
        decimate(obj, tris)
        self.paint(obj, color)
        if cover:
            self.covers.append((cover, []))
        return self.add(obj, binding)

    def boots(self, color, sole, top=None, toe=None, cuff=None, cuff_height=0.2, width=1.0, gap=0.07,
              thickness=0.04, flare=0.0):
        """Boots: a shaft grown off the leg from `top` (rig y) down, a
        shaped foot (flat sole, heel, rounded toe), a sole, and optionally a
        capped toe and a folded cuff."""
        top = top if top is not None else P["RightKnee"][1] - 0.2
        keep = lambda p: Where(p).kind == "leg" and p[1] < top and p[1] > 0.5
        self.garment(keep, color, gap=gap, thickness=thickness, name="BootShaft",
                     inflate=lambda p: flare * smoothstep(top - 0.5, top, p[1]))
        for side, s in skeleton.SIDES:
            an = P[f"{side}Ankle"]
            x = an[0]
            w = width
            # heel to toe: (z, center y, half width, half height); the bottom is flat
            sections = [(0.27, 0.27, 0.13 * w, 0.2), (0.2, 0.3, 0.19 * w, 0.3), (0.02, 0.32, 0.215 * w, 0.32),
                        (-0.18, 0.26, 0.21 * w, 0.22), (-0.38, 0.19, 0.2 * w, 0.14), (-0.54, 0.15, 0.17 * w, 0.1),
                        (-0.64, 0.13, 0.1 * w, 0.07)]

            def ring(z, cy, hw, hh, grow=0.0):
                out = []
                for k in range(16):
                    a = 2 * math.pi * k / 16
                    c, sn = math.cos(a), math.sin(a)
                    px = (hw + grow) * math.copysign(abs(c) ** 0.7, c)
                    py = (hh + grow) * math.copysign(abs(sn) ** (0.5 if sn < 0 else 0.9), sn)
                    out.append(B((x + s * 0.005 + px, max(0.07, cy + py), z)))
                return out

            obj = bm_to_object(_loft_rings([ring(*sec) for sec in sections]), f"{side}Boot", self.col)
            self.paint(obj, color)
            self.add(obj)
            if toe:  # a capped toe hugging the front of the foot
                front = [sec for sec in sections if sec[0] <= -0.18]
                obj = bm_to_object(_loft_rings([ring(*sec, grow=0.014) for sec in front]), f"{side}ToeCap", self.col)
                self.paint(obj, toe)
                self.add(obj)
            mb = self.builder()
            mb.box((x + s * 0.005, 0.045, -0.19), (0.46 * w, 0.09, 0.98), sole, bevel=0.03, segments=1)
            mb.box((x + s * 0.005, 0.07, 0.19), (0.36 * w, 0.14, 0.2), sole, bevel=0.03, segments=1)  # heel
            self.piece(mb, name=f"{side}Sole")
            if cuff:
                self.band((x, top + cuff_height * 0.3, 0.0), (0, 1, 0), cuff_height, cuff, thickness=0.05,
                          flare=0.05, name="BootCuff")
        self.covers.append((lambda p: Where(p).kind == "leg" and p[1] < 0.5, []))

    def panel(self, rows, color, thickness=0.04, binding=None, name="Panel", hem=None, hem_radius=0.022, cols=10,
              steps=10, hem_edges=("left", "bottom", "right"), jag=0.0):
        """A free cloth sheet (apron skirt, tabard, cape, loincloth) through
        a grid of rig points: `rows` top to bottom, each listing the same
        number of points left to right. `hem` rolls the open edges; `jag`
        tatters the bottom edge."""
        rs = [_resample([Vector(p) for p in row], cols) for row in rows]
        grid = [_resample([r[c] for r in rs], steps) for c in range(cols)]  # grid[column][row]
        if jag:  # a tattered bottom edge: ragged teeth of uneven length
            for c in range(cols):
                drop = _tooth(c) * jag
                grid[c][-1] = grid[c][-1] + Vector((0, -drop, 0))
                grid[c][-2] = grid[c][-2] + Vector((0, -drop * 0.35, 0))
        bm = bmesh.new()
        verts = [[bm.verts.new(B(q)) for q in col] for col in grid]
        for c in range(cols - 1):
            for r in range(steps - 1):
                bm.faces.new((verts[c][r], verts[c + 1][r], verts[c + 1][r + 1], verts[c][r + 1]))
        bm.normal_update()
        line = []  # the hem runs down the left edge, along the bottom and up the right
        if "left" in hem_edges:
            line += [verts[0][r] for r in range(steps)]
        if "bottom" in hem_edges:
            line += [verts[c][-1] for c in range(cols)]
        if "right" in hem_edges:
            line += [verts[-1][r] for r in reversed(range(steps))]
        line = [(v.co.copy(), v.normal.copy()) for v in line]
        obj = bm_to_object(bm, name, self.col)
        mod = obj.modifiers.new("Solidify", "SOLIDIFY")
        mod.thickness = thickness
        mod.offset = 0.0
        mod.use_rim = True
        apply_modifiers(obj)
        self.paint(obj, color)
        self.add(obj, binding)
        if hem and line:
            pts, nrms = [], []
            for co, nrm in line:
                if not pts or (co - pts[-1]).length > 1e-5:
                    pts.append(co)
                    nrms.append(nrm)
            t = bm_to_object(tube_bm(pts, hem_radius, closed=False, sides=4, normals=nrms), name + "Hem", self.col)
            self.paint(t, hem)
            self.add(t, binding)
        return obj

    def skirt(self, top, bottom, color, gap=0.02, thickness=0.035, flare=0.1, arc=None, hem=None, hem_radius=0.024,
              rows=7, count=40, name="Skirt", center=(0.0, 0.02), binding=None, hem_sides=4, reach=0.75, jag=0.0):
        """Cloth hanging around the body from `top` down to `bottom` (rig y),
        draped over everything built so far like a hull (so it bridges the
        legs instead of wrapping each one) and flaring out `flare` at the
        hem. `arc` = (a0, a1) degrees (0 = front, 90 = her right) leaves the
        rest open: an open-front coat (20, 340), a cloak or capelet (95, 265).
        It sways with the hips unless `binding` says otherwise. Anything
        farther than `reach` from the body's axis (the arms) is ignored."""
        cx, cz = center
        pts = []
        for obj in self.outer():
            for v in obj.data.vertices:
                q = to_rig(v.co)
                if bottom - 0.1 < q.y < top + 0.1 and math.hypot(q.x - cx, q.z - cz) < reach:
                    pts.append(q)
        a0, a1 = arc if arc else (0.0, 360.0)
        span = (a1 - a0) % 360.0 or 360.0
        closed = arc is None
        n = count if closed else count + 1
        angles = [a0 + span * k / (count if closed else count) for k in range(n)]
        rings = []
        prev = None
        for i in range(rows):
            y = lerp(top, bottom, i / (rows - 1))
            bins = [0.0] * 72
            for q in pts:
                if abs(q.y - y) < 0.07:
                    a = math.degrees(math.atan2(q.x - cx, -(q.z - cz))) % 360.0
                    d = math.hypot(q.x - cx, q.z - cz)
                    k = int(a / 5.0) % 72
                    bins[k] = max(bins[k], d)
            for _ in range(3):  # fill gaps and soften
                bins = [max(bins[k], (bins[k - 1] + bins[(k + 1) % 72]) / 2) for k in range(72)]
            radii = []
            for a in angles:
                f = (a % 360.0) / 5.0
                k = int(f) % 72
                r = lerp(bins[k], bins[(k + 1) % 72], f - int(f))
                radii.append(r)
            if prev:
                radii = [max(r, pr) for r, pr in zip(radii, prev)]
            prev = radii
            t = i / (rows - 1)
            ring = []
            for k, (a, r) in enumerate(zip(angles, radii)):
                rr = r + gap + flare * t ** 1.4
                ar = math.radians(a)
                yy = y - (jag * _tooth(k) * (1.0 if i == rows - 1 else 0.35 if i == rows - 2 else 0.0))
                ring.append(B((cx + math.sin(ar) * rr, yy, cz - math.cos(ar) * rr)))
            rings.append(ring)
        bm = bmesh.new()
        made = [[bm.verts.new(q) for q in ring] for ring in rings]
        m = len(made[0])
        for r0, r1 in zip(made, made[1:]):
            for k in range(m if closed else m - 1):
                bm.faces.new((r0[k], r0[(k + 1) % m], r1[(k + 1) % m], r1[k]))
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
        bm.normal_update()
        edge = [v for v in made[-1]]
        if not closed:
            edge = [r[0] for r in made] + edge + [r[-1] for r in reversed(made)]
        line = [(v.co.copy(), v.normal.copy()) for v in edge]
        obj = bm_to_object(bm, name, self.col)
        mod = obj.modifiers.new("Solidify", "SOLIDIFY")
        mod.thickness = thickness
        mod.offset = 1.0
        mod.use_rim = True
        mod.use_even_offset = False
        apply_modifiers(obj)
        self.paint(obj, color)
        binding = binding or ("skirt", top, bottom)
        self.add(obj, binding)
        if hem:
            pts_, nrms = [], []
            for co, nrm in line:
                if not pts_ or (co - pts_[-1]).length > 1e-5:
                    pts_.append(co + nrm * thickness * 0.5)
                    nrms.append(nrm)
            t = bm_to_object(tube_bm(pts_, hem_radius, closed=closed, sides=hem_sides, normals=nrms), name + "Hem",
                             self.col)
            self.paint(t, hem)
            self.add(t, binding)
        return obj

    def fur(self, path, radius, color, tris=500, name="Fur", binding=None, closed=True, lumps=2.2):
        """A fluffy roll of fur along a rig-space path (collar ruffs, cuffs,
        trims): lumpy blended balls."""
        pts = _resample([Vector(p) for p in path] + ([Vector(path[0])] if closed else []),
                        max(6, int(_length([Vector(p) for p in path], closed) / (radius * 0.9))))

        def shape(m):
            for i, q in enumerate(pts):
                k = 1.0 + 0.12 * math.sin(i * lumps)
                m.ball(tuple(q), radius * k)
        return self.blob(shape, color, tris=tris, name=name, binding=binding, resolution=min(0.03, radius * 0.5))

    def on_surface(self, p):
        """Nearest point on the outfit so far (rig space) and its normal."""
        loc, nrm = self.surface().nearest(p)
        return tuple(to_rig(loc)), tuple(to_rig(nrm))


def _cut(bm, keep, steps=7):
    """Splits faces along the edge of the region where keep(rig point) is
    true, so deleting the rest leaves a clean line instead of a zig-zag of
    whole triangles."""
    inside = {v: bool(keep(to_rig(v.co))) for v in bm.verts}
    made = set()
    for e in [e for e in bm.edges if inside[e.verts[0]] != inside[e.verts[1]]]:
        a, b = e.verts
        pa, pb, ka = a.co.copy(), b.co.copy(), inside[a]
        lo, hi = 0.0, 1.0
        for _ in range(steps):
            mid = (lo + hi) / 2
            if bool(keep(to_rig(pa.lerp(pb, mid)))) == ka:
                lo = mid
            else:
                hi = mid
        t = min(0.9, max(0.1, (lo + hi) / 2))
        _, v = bmesh.utils.edge_split(e, a, t)
        made.add(v)
    for f in list(bm.faces):
        on = [v for v in f.verts if v in made]
        if len(on) == 2 and not any(e for e in on[0].link_edges if e.other_vert(on[0]) is on[1]):
            bmesh.utils.face_split(f, on[0], on[1])
    return made


def _faces_where(bm, keep):
    return [f for f in bm.faces if keep(to_rig(f.calc_center_median()))]


def _unpinch(bm, rounds=6):
    """Removes faces around vertices where open edges meet more than twice
    (a hem can't run through a pinch)."""
    for _ in range(rounds):
        bad = [v for v in bm.verts if sum(1 for e in v.link_edges if e.is_boundary) > 2
               or (v.link_faces and not v.is_manifold and sum(1 for e in v.link_edges if e.is_boundary) == 0
                   and len(v.link_faces) < 3)]
        if not bad:
            return
        faces = {f for v in bad for f in v.link_faces}
        bmesh.ops.delete(bm, geom=list(faces), context="FACES")
        bmesh.ops.delete(bm, geom=[v for v in bm.verts if not v.link_faces], context="VERTS")


def _tooth(k):
    """Uneven ragged teeth for tattered hems: 0..1 for column k."""
    return (0.55 + 0.45 * math.sin(k * 2.39 + 0.7)) if k % 2 == 0 else 0.08 * (1 + math.sin(k * 1.3))


def _length(pts, closed):
    total = sum((b - a).length for a, b in zip(pts, pts[1:]))
    return total + ((pts[0] - pts[-1]).length if closed else 0.0)


def _islands(bm):
    seen = set()
    out = []
    for f in bm.faces:
        if f in seen:
            continue
        stack = [f]
        isl = []
        seen.add(f)
        while stack:
            g = stack.pop()
            isl.append(g)
            for e in g.edges:
                for h in e.link_faces:
                    if h not in seen:
                        seen.add(h)
                        stack.append(h)
        out.append(isl)
    return out


def _resample(pts, count):
    """Even points along a polyline (Catmull-Rom through the given points)."""
    if len(pts) == 2:
        return [pts[0].lerp(pts[1], i / (count - 1)) for i in range(count)]
    dense = []
    for i in range(len(pts) - 1):
        p0 = pts[max(0, i - 1)]
        p1, p2 = pts[i], pts[i + 1]
        p3 = pts[min(len(pts) - 1, i + 2)]
        for k in range(12):
            t = k / 12
            t2, t3 = t * t, t * t * t
            dense.append(0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2
                                + (-p0 + 3 * p1 - 3 * p2 + p3) * t3))
    dense.append(pts[-1])
    lengths = [0.0]
    for a, b in zip(dense, dense[1:]):
        lengths.append(lengths[-1] + (b - a).length)
    total = lengths[-1]
    out = []
    j = 0
    for i in range(count):
        target = total * i / (count - 1)
        while j < len(lengths) - 2 and lengths[j + 1] < target:
            j += 1
        seg = lengths[j + 1] - lengths[j] or 1.0
        out.append(dense[j].lerp(dense[j + 1], (target - lengths[j]) / seg))
    return out


# Painted decals (faces, emblems) -------------------------------------------------------------------


class Canvas:
    """A tiny anti-aliased RGBA rasterizer (numpy) for painted decals.
    Coordinates are in decal units: (0, 0) bottom-left .. (w, h)."""

    def __init__(self, width, height, px=512):
        import numpy as np
        self.np = np
        self.w, self.h = width, height
        self.px = px
        self.py = max(8, int(round(px * height / width)))
        ss = 3
        xs = (np.arange(self.px * ss) + 0.5) / (self.px * ss) * width
        ys = (np.arange(self.py * ss) + 0.5) / (self.py * ss) * height
        self.X, self.Y = np.meshgrid(xs, ys)
        self.ss = ss
        self.rgba = np.zeros((self.py * ss, self.px * ss, 4), dtype=np.float32)

    def _put(self, mask, color, alpha=1.0):
        np = self.np
        r, g, b = common.hex_color(color)
        a = mask.astype(np.float32) * alpha
        for i, c in enumerate((r, g, b)):
            self.rgba[..., i] = self.rgba[..., i] * (1 - a) + c * a
        self.rgba[..., 3] = self.rgba[..., 3] * (1 - a) + a

    def ellipse(self, cx, cy, rx, ry, color, rotation=0.0, alpha=1.0):
        np = self.np
        c, s = math.cos(math.radians(rotation)), math.sin(math.radians(rotation))
        dx, dy = self.X - cx, self.Y - cy
        u = (dx * c + dy * s) / rx
        v = (-dx * s + dy * c) / ry
        self._put(u * u + v * v <= 1.0, color, alpha)

    def polygon(self, pts, color, alpha=1.0):
        np = self.np
        inside = np.zeros(self.X.shape, dtype=bool)
        n = len(pts)
        for i in range(n):
            (x1, y1), (x2, y2) = pts[i], pts[(i + 1) % n]
            cond = ((y1 > self.Y) != (y2 > self.Y)) & (self.X < (x2 - x1) * (self.Y - y1) / ((y2 - y1) or 1e-9) + x1)
            inside ^= cond
        self._put(inside, color, alpha)

    def stroke(self, pts, width, color, alpha=1.0):
        np = self.np
        mask = np.zeros(self.X.shape, dtype=bool)
        for (x1, y1), (x2, y2) in zip(pts, pts[1:]):
            dx, dy = x2 - x1, y2 - y1
            ll = dx * dx + dy * dy or 1e-9
            t = np.clip(((self.X - x1) * dx + (self.Y - y1) * dy) / ll, 0, 1)
            d2 = (self.X - x1 - t * dx) ** 2 + (self.Y - y1 - t * dy) ** 2
            w = width(0) if callable(width) else width
            mask |= d2 <= (w / 2) ** 2
        self._put(mask, color, alpha)

    def save(self, path):
        np = self.np
        ss = self.ss
        img = self.rgba.reshape(self.py, ss, self.px, ss, 4).mean(axis=(1, 3))
        image = bpy.data.images.new(os.path.basename(path), self.px, self.py, alpha=True)
        image.pixels[:] = img.ravel().tolist()
        image.filepath_raw = path
        image.file_format = "PNG"
        common.ensure_dir(os.path.dirname(path))
        image.save()
        return image


class Decal:
    """An image painted onto zones of the model by projection: centered at
    `center` (rig space), spanning `size` along `right` and `up`, painting
    surfaces that face `normal`."""

    def __init__(self, image, center, size, right=(-1, 0, 0), up=(0, 1, 0), normal=(0, 0, -1), zones=None,
                 strength=1.0):
        self.image = image
        self.center = center
        self.size = size
        self.right = right
        self.up = up
        self.normal = normal
        self.zones = zones
        self.strength = strength


def curve_pts(a, b, bend, n=10):
    """Points from a to b bowed by `bend` (positive = down in the middle)."""
    (x0, y0), (x1, y1) = a, b
    return [(x0 + (x1 - x0) * i / n, y0 + (y1 - y0) * i / n - bend * 4 * (i / n) * (1 - i / n)) for i in range(n + 1)]


# Finishing: weights, UVs, painted bake, export ---------------------------------------------------------

PART_OF = {j[0]: j[2] for j in skeleton.JOINTS}  # joint -> the proxy part it moves


def _cover_skin(hero, margin=0.07):
    """Deletes skin faces hidden under clothes (well inside a garment)."""
    from mathutils.kdtree import KDTree
    body = hero.body_obj
    if not hero.covers:
        return
    bm = bmesh.new()
    bm.from_mesh(body.data)
    kills = set()
    for keep, hem_pts in hero.covers:
        kd = None
        if hem_pts:
            kd = KDTree(len(hem_pts))
            for i, p in enumerate(hem_pts):
                kd.insert(p, i)
            kd.balance()
        for f in bm.faces:
            if f in kills:
                continue
            if all(keep(to_rig(v.co)) for v in f.verts):
                if kd is None or kd.find(f.calc_center_median())[2] > margin:
                    kills.add(f)
    bmesh.ops.delete(bm, geom=list(kills), context="FACES")
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if not v.link_faces], context="VERTS")
    bm.to_mesh(body.data)
    bm.free()


def _weight(obj, binding):
    groups = {}
    for v in obj.data.vertices:
        p = to_rig(v.co)
        if binding is None:
            w = body_weights(p)
        elif binding[0] == "bone":
            w = {binding[1]: 1.0}
        elif binding[0] == "sway":
            w = sway_weights(p, binding[1])
        elif binding[0] == "skirt":
            w = skirt_weights(p, binding[1], binding[2])
        else:
            raise ValueError(binding)
        for bone, val in w.items():
            g = groups.get(bone)
            if g is None:
                g = groups[bone] = obj.vertex_groups.get(bone) or obj.vertex_groups.new(name=bone)
            g.add([v.index], val, "REPLACE")


def _join(objects, name):
    bpy.ops.object.select_all(action="DESELECT")
    for o in objects:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objects[0]
    bpy.ops.object.join()
    obj = bpy.context.view_layer.objects.active
    obj.name = name
    obj.data.name = name
    return obj


def _uv(obj, face_boost=2.4):
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.smart_project(angle_limit=math.radians(60), island_margin=0.004)
    bpy.ops.object.mode_set(mode="OBJECT")
    # give the face more texels: scale the UV islands of the front of the head
    me = obj.data
    uv = me.uv_layers.active.data
    bm = bmesh.new()
    bm.from_mesh(me)
    layer = bm.loops.layers.uv.active
    face_set = set()
    for f in bm.faces:
        c = to_rig(f.calc_center_median())
        if c.y > 5.05 and c.z < 0.05 and abs(c.x) < 0.45:
            face_set.add(f)
    # grow to whole UV islands
    islands = _uv_islands(bm, layer)
    for isl in islands:
        if any(f in face_set for f in isl):
            pts = [l[layer].uv.copy() for f in isl for l in f.loops]
            cx = sum(p.x for p in pts) / len(pts)
            cy = sum(p.y for p in pts) / len(pts)
            for f in isl:
                for l in f.loops:
                    l[layer].uv = Vector((cx + (l[layer].uv.x - cx) * face_boost, cy + (l[layer].uv.y - cy) * face_boost))
    bm.to_mesh(me)
    bm.free()
    bpy.context.scene.tool_settings.use_uv_select_sync = True  # pack every island
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.select_all(action="SELECT")
    bpy.ops.uv.pack_islands(margin=0.008, rotate=True)
    bpy.ops.object.mode_set(mode="OBJECT")


def _uv_islands(bm, layer):
    seen = set()
    out = []
    for f in bm.faces:
        if f in seen:
            continue
        isl = []
        stack = [f]
        seen.add(f)
        while stack:
            g = stack.pop()
            isl.append(g)
            for l in g.loops:
                e = l.edge
                for h in e.link_faces:
                    if h in seen:
                        continue
                    # same island if the shared edge has matching UVs on both sides
                    la = [x for x in h.loops if x.edge == e]
                    if la and (la[0].link_loop_next[layer].uv - l[layer].uv).length < 1e-5:
                        seen.add(h)
                        stack.append(h)
        out.append(isl)
    return out


def _node(nt, kind, loc=(0, 0), **inputs):
    n = nt.nodes.new(kind)
    n.location = loc
    for k, v in inputs.items():
        if k in n.inputs:
            n.inputs[k].default_value = v
        else:
            setattr(n, k, v)
    return n


def _math(nt, op, a, b=None, clamp=False):
    n = nt.nodes.new("ShaderNodeMath")
    n.operation = op
    n.use_clamp = clamp
    for i, x in enumerate((a, b)):
        if x is None:
            continue
        if isinstance(x, (int, float)):
            n.inputs[i].default_value = x
        else:
            nt.links.new(x, n.inputs[i])
    return n.outputs[0]


def _mix_rgb(nt, mode, fac, a, b):
    n = nt.nodes.new("ShaderNodeMix")
    n.data_type = "RGBA"
    n.blend_type = mode
    for sock, x in ((n.inputs[0], fac), (n.inputs[6], a), (n.inputs[7], b)):
        if isinstance(x, (int, float)):
            sock.default_value = x
        elif isinstance(x, tuple):
            sock.default_value = x
        else:
            nt.links.new(x, sock)
    return n.outputs[2]


def _bake_material(hero, mat, zone, target, channel):
    """Rebuilds `mat` to emit its painted color (or metal/rough value)."""
    nt = mat.node_tree
    nt.nodes.clear()
    out = _node(nt, "ShaderNodeOutputMaterial")
    emit = _node(nt, "ShaderNodeEmission")
    nt.links.new(emit.outputs[0], out.inputs[0])
    img = _node(nt, "ShaderNodeTexImage")
    img.image = target
    nt.nodes.active = img
    f = zone.finish
    coord = _node(nt, "ShaderNodeTexCoord")
    noise = _node(nt, "ShaderNodeTexNoise", Scale=f["scale"], Detail=6.0, Roughness=0.6)
    nt.links.new(coord.outputs["Object"], noise.inputs["Vector"])
    if channel == "metal":
        nt.links.new(_math(nt, "ADD", f["metal"], 0.0), emit.inputs["Color"])
        return
    if channel == "rough":
        rough = _math(nt, "ADD", f["rough"], _math(nt, "MULTIPLY", _math(nt, "SUBTRACT", noise.outputs["Fac"], 0.5),
                                                    0.2), clamp=True)
        nt.links.new(rough, emit.inputs["Color"])
        return
    base = (*linear(zone.color), 1.0)
    color = _node(nt, "ShaderNodeRGB")
    color.outputs[0].default_value = base
    col = color.outputs[0]
    # painted grain
    grain = _math(nt, "ADD", 1.0, _math(nt, "MULTIPLY", _math(nt, "SUBTRACT", noise.outputs["Fac"], 0.5),
                                         f["grain"] * 2))
    col = _mix_rgb(nt, "MULTIPLY", 1.0, col, _gray(nt, grain))
    # broad painted color variation
    blot = _node(nt, "ShaderNodeTexNoise", Scale=3.0, Detail=2.0, Roughness=0.5)
    nt.links.new(coord.outputs["Object"], blot.inputs["Vector"])
    vary = _math(nt, "ADD", 0.92, _math(nt, "MULTIPLY", blot.outputs["Fac"], 0.16))
    col = _mix_rgb(nt, "MULTIPLY", 1.0, col, _gray(nt, vary))
    if zone.kind == "quilt":  # diamond quilting stitched into the cloth
        sep_p = _node(nt, "ShaderNodeSeparateXYZ")
        nt.links.new(coord.outputs["Object"], sep_p.inputs[0])
        u = _math(nt, "ADD", sep_p.outputs["X"], sep_p.outputs["Y"])
        lines = None
        for sign in (1.0, -1.0):
            d = _math(nt, "ADD", u, _math(nt, "MULTIPLY", sep_p.outputs["Z"], sign))
            wave = _math(nt, "ABSOLUTE", _math(nt, "SINE", _math(nt, "MULTIPLY", d, 13.0)))
            seam = _math(nt, "SUBTRACT", 1.0, _math(nt, "MULTIPLY", _math(nt, "SUBTRACT", 0.22, wave), 6.0,
                                                    clamp=True))
            lines = seam if lines is None else _math(nt, "MULTIPLY", lines, seam)
        puff = _math(nt, "ADD", 0.72, _math(nt, "MULTIPLY", lines, 0.28))
        col = _mix_rgb(nt, "MULTIPLY", 1.0, col, _gray(nt, puff))
    # crevices darken (ambient occlusion), toward a cool shadow tint
    ao = _node(nt, "ShaderNodeAmbientOcclusion", Distance=0.4, samples=16)
    shade = _math(nt, "ADD", 0.38, _math(nt, "MULTIPLY", ao.outputs["AO"], 0.62))
    col = _mix_rgb(nt, "MULTIPLY", 1.0, col, _gray(nt, shade))
    dark = _math(nt, "SUBTRACT", 1.0, ao.outputs["AO"], clamp=True)
    col = _mix_rgb(nt, "MULTIPLY", _math(nt, "MULTIPLY", dark, 0.5), col, (0.55, 0.6, 0.85, 1.0))
    # painted top light
    geo = _node(nt, "ShaderNodeNewGeometry")
    sep = _node(nt, "ShaderNodeSeparateXYZ")
    nt.links.new(geo.outputs["Normal"], sep.inputs[0])
    top = _math(nt, "ADD", 0.84, _math(nt, "MULTIPLY", sep.outputs["Z"], 0.2))
    col = _mix_rgb(nt, "MULTIPLY", 1.0, col, _gray(nt, top))
    # worn, lit edges and dark creases
    edge = _math(nt, "MULTIPLY", _math(nt, "SUBTRACT", geo.outputs["Pointiness"], 0.52), 7.0, clamp=True)
    col = _mix_rgb(nt, "SCREEN", _math(nt, "MULTIPLY", edge, f["edge"] * 0.4), col, (1.0, 0.95, 0.85, 1.0))
    crease = _math(nt, "MULTIPLY", _math(nt, "SUBTRACT", 0.48, geo.outputs["Pointiness"]), 6.0, clamp=True)
    col = _mix_rgb(nt, "MULTIPLY", _math(nt, "MULTIPLY", crease, 0.45), col, (0.35, 0.3, 0.35, 1.0))
    # decals
    for d in hero.decals:
        if d.zones and zone.key not in d.zones:
            continue
        col = _decal_nodes(nt, d, col, geo)
    if zone.kind == "glow":
        col = _mix_rgb(nt, "SCREEN", 0.25, col, (1, 1, 1, 1))
    nt.links.new(col, emit.inputs["Color"])


def _gray(nt, value):
    n = nt.nodes.new("ShaderNodeCombineXYZ")
    for i in range(3):
        nt.links.new(value, n.inputs[i])
    return n.outputs[0]


def _decal_nodes(nt, d, col, geo):
    """Mixes a projected decal image over `col`."""
    right = (RIG_TO_BLENDER @ Vector(d.right)).normalized()
    up = (RIG_TO_BLENDER @ Vector(d.up)).normalized()
    normal = (RIG_TO_BLENDER @ Vector(d.normal)).normalized()
    center = B(d.center)
    w, h = d.size
    pos = geo.outputs["Position"]
    rel = nt.nodes.new("ShaderNodeVectorMath")
    rel.operation = "SUBTRACT"
    nt.links.new(pos, rel.inputs[0])
    rel.inputs[1].default_value = center

    def dot(vec, axis):
        n = nt.nodes.new("ShaderNodeVectorMath")
        n.operation = "DOT_PRODUCT"
        nt.links.new(vec, n.inputs[0])
        n.inputs[1].default_value = axis
        return n.outputs["Value"]

    u = _math(nt, "ADD", _math(nt, "DIVIDE", dot(rel.outputs[0], right), w), 0.5)
    v = _math(nt, "ADD", _math(nt, "DIVIDE", dot(rel.outputs[0], up), h), 0.5)
    uv = nt.nodes.new("ShaderNodeCombineXYZ")
    nt.links.new(u, uv.inputs[0])
    nt.links.new(v, uv.inputs[1])
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = d.image
    tex.extension = "CLIP"
    tex.interpolation = "Cubic"
    nt.links.new(uv.outputs[0], tex.inputs["Vector"])
    facing = _math(nt, "MULTIPLY", dot(geo.outputs["Normal"], normal), 3.0, clamp=True)
    depth = _math(nt, "LESS_THAN", _math(nt, "ABSOLUTE", dot(rel.outputs[0], normal)), 0.6)
    mask = _math(nt, "MULTIPLY", _math(nt, "MULTIPLY", tex.outputs["Alpha"], facing), depth)
    mask = _math(nt, "MULTIPLY", mask, d.strength)
    return _mix_rgb(nt, "MIX", mask, col, tex.outputs["Color"])


def _bake(hero, obj, size=1024):
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.samples = 16
    scene.cycles.device = "CPU"
    scene.render.bake.margin = 3
    scene.render.bake.use_clear = True
    out = {}
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    for channel in ("color", "metal", "rough"):
        img = bpy.data.images.new(f"{hero.name}_{channel}", size, size, alpha=False)
        if channel != "color":
            img.colorspace_settings.name = "Non-Color"
        for mat in obj.data.materials:
            _bake_material(hero, mat, hero.zones[mat["zone"]], img, channel)
        bpy.ops.object.bake(type="EMIT")
        path = os.path.join(common.ensure_dir(EXPORT_DIR), f"{hero.name}_{channel}.png")
        img.filepath_raw = path
        img.file_format = "PNG"
        img.save()
        out[channel] = img
    return out


def _final_material(hero, obj, maps):
    """One Principled material with the baked maps (the importer turns it
    into a SurfaceAppearance)."""
    m = bpy.data.materials.new(hero.name)
    m.use_nodes = True
    nt = m.node_tree
    bsdf = nt.nodes.get("Principled BSDF")
    for channel, sock in (("color", "Base Color"), ("metal", "Metallic"), ("rough", "Roughness")):
        t = nt.nodes.new("ShaderNodeTexImage")
        t.image = maps[channel]
        nt.links.new(t.outputs["Color"], bsdf.inputs[sock])
    obj.data.materials.clear()
    obj.data.materials.append(m)
    for p in obj.data.polygons:
        p.material_index = 0
    return m


def _part_boxes(obj):
    """Rig-space boxes of the vertices each joint moves most (for the game's
    invisible proxy parts)."""
    names = {g.index: g.name for g in obj.vertex_groups}
    lo, hi = {}, {}
    for v in obj.data.vertices:
        if not v.groups:
            continue
        g = max(v.groups, key=lambda x: x.weight)
        joint = names[g.group]
        part = PART_OF.get(joint)
        if part is None:
            continue
        p = to_rig(v.co)
        a = lo.setdefault(part, [math.inf] * 3)
        b = hi.setdefault(part, [-math.inf] * 3)
        for i in range(3):
            a[i] = min(a[i], p[i])
            b[i] = max(b[i], p[i])
    return {part: {"center": [round((lo[part][i] + hi[part][i]) / 2, 3) for i in range(3)],
                   "size": [round(max(0.05, hi[part][i] - lo[part][i]), 3) for i in range(3)]} for part in lo}


def finish(hero, budget=TRI_BUDGET):
    """Turns the built pieces into the exported, skinned, painted fighter."""
    _cover_skin(hero)
    if hero.body_lo is not None:
        bpy.data.objects.remove(hero.body_lo)
        hero.body_lo = None
    objs = []
    for obj, binding in hero.pieces:
        if not obj.data.polygons:
            continue
        _weight(obj, binding)
        dec = obj.vertex_groups.new(name="_Decimate")
        dec.add(list(range(len(obj.data.vertices))), 1.0 if obj.get("decimate", True) else 0.0, "REPLACE")
        objs.append(obj)
    report = sorted(((triangles(o), o.name) for o in objs), reverse=True)
    print(f"[{hero.name}] triangles by piece:", ", ".join(f"{n} {t}" for t, n in report[:24]))
    body = _join(objs, "Body")
    for p in body.data.polygons:
        p.use_smooth = True
    tris = triangles(body)
    if tris > budget:
        print(f"[{hero.name}] WARNING: {tris} triangles is over the {budget} budget")
    body.vertex_groups.remove(body.vertex_groups["_Decimate"])
    # limit to 4 influences
    bpy.ops.object.select_all(action="DESELECT")
    body.select_set(True)
    bpy.context.view_layer.objects.active = body
    bpy.ops.object.vertex_group_limit_total(limit=4)
    bpy.ops.object.vertex_group_normalize_all(lock_active=False)
    _uv(body)
    maps = _bake(hero, body)
    _final_material(hero, body, maps)
    arm = build_armature(hero.name, hero.sways, hero.col)
    arm.name = "SkyRig"
    arm.data.name = "SkyRig"
    body.parent = arm
    mod = body.modifiers.new("Armature", "ARMATURE")
    mod.object = arm
    markers = common.add_markers(RIG_TO_BLENDER, hero.col)
    path = export(hero, arm, body, markers)
    info = {
        "name": hero.name,
        "height": round(max(to_rig(v.co).y for v in body.data.vertices), 3),
        "triangles": triangles(body),
        "parts": _part_boxes(body),
        "sways": [{"name": s.name, "parent": s.parent, "points": [list(map(lambda x: round(x, 3), p)) for p in s.points],
                   "stiffness": s.stiffness, "damping": s.damping, "limit": s.limit, "behind": s.behind}
                  for s in hero.sways],
    }
    with open(os.path.join(EXPORT_DIR, f"{hero.name}.json"), "w") as f:
        json.dump(info, f, indent=1, sort_keys=True)
    print(f"[{hero.name}] {path} ({info['triangles']} triangles, height {info['height']})")
    return body, arm, markers, info


def preview_body(module):
    """A legend's skinned body without painting or export, for animation
    previews: sway pieces ride their parent bone."""
    hero = Hero(module)
    module.model(hero)
    _cover_skin(hero)
    bpy.data.objects.remove(hero.body_lo)
    hero.body_lo = None
    objs = []
    for obj, binding in hero.pieces:
        if not obj.data.polygons:
            continue
        if binding and binding[0] == "sway":
            binding = ("bone", binding[1].parent)
        _weight(obj, binding)
        objs.append(obj)
    body = _join(objs, "Body")
    for p in body.data.polygons:
        p.use_smooth = True
    return body


def export(hero, arm, body, markers):
    path = os.path.join(common.ensure_dir(EXPORT_DIR), f"{hero.name}.fbx")
    bpy.ops.object.select_all(action="DESELECT")
    for o in [arm, body] + markers:
        o.select_set(True)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.export_scene.fbx(
        filepath=path,
        use_selection=True,
        object_types={"ARMATURE", "MESH"},
        apply_unit_scale=True,
        apply_scale_options="FBX_SCALE_UNITS",
        mesh_smooth_type="FACE",
        use_mesh_modifiers=False,
        add_leaf_bones=False,
        primary_bone_axis="Y",
        secondary_bone_axis="X",
        use_armature_deform_only=True,
        armature_nodetype="NULL",
        bake_anim=False,
        path_mode="COPY",
        embed_textures=True,
        axis_forward="Z",
        axis_up="Y",
    )
    return path


# Preview -------------------------------------------------------------------------------------------


def render_turnaround(hero, body, path, size=(2000, 760), spacing=3.6, pose=None):
    """Front / 3-4 / side / back views with the painted texture and a thin
    dark outline (as the game draws it)."""
    common.toon_preview_materials([], outline=0)  # make sure the outline material exists
    outline = bpy.data.materials.get("PreviewOutline")
    body.data.materials.append(outline)
    mod = body.modifiers.new("Outline", "SOLIDIFY")
    mod.thickness = 0.022
    mod.offset = 1.0
    mod.use_flip_normals = True
    mod.material_offset = len(body.data.materials) - 1
    mod.use_rim = False
    for o in hero.col.objects:
        if o.name.startswith("Marker_"):
            o.hide_render = True
    layer = bpy.context.view_layer.layer_collection.children[hero.col.name]
    layer.exclude = True
    angles = (0, 45, 90, 180)
    for i, ang in enumerate(angles):
        inst = bpy.data.objects.new(f"View{i}", None)
        inst.instance_type = "COLLECTION"
        inst.instance_collection = hero.col
        inst.location = (i * spacing, 0, 0)
        inst.rotation_euler = (0, 0, math.radians(ang))
        bpy.context.scene.collection.objects.link(inst)
    w, h = size
    common.setup_preview_render(path, w, h)
    scene = bpy.context.scene
    scene.eevee.taa_render_samples = 32
    width = len(angles) * spacing
    ortho = max(width, 6.9 * w / h)
    cx = (len(angles) - 1) * spacing / 2
    common.ortho_camera("PreviewCam", (cx, -40, 3.15), (cx, 0, 3.15), ortho)
    return common.render(path)


def build(module, preview=True):
    """Runs a hero fighter script (fighters/<name>.py with model(hero))."""
    common.reset_scene()
    hero = Hero(module)
    module.model(hero)
    body, arm, markers, info = finish(hero)
    if preview:
        render_turnaround(hero, body, os.path.join(common.PREVIEW_DIR, "fighters", f"{hero.name}.png"))
    return info
