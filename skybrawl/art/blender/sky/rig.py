"""
The SkyRig: 15 rigid parts named like Roblox R15 parts, on one R6-proportioned
skeleton (sky/skeleton.py) that every fighter shares, so every animation
works on every fighter.

In Blender each joint is an empty (J_<Joint>) at its pivot, parented down the
chain, and each part is parented to the joint that moves it. Animations rotate
the empties. The game rebuilds the same joints as Motor6Ds from
src/shared/FighterRigs.luau, so the FBX carries meshes only.
"""

import json
import math
import os

import bpy
from mathutils import Matrix, Vector

from . import common, skeleton
from .common import RIG_TO_BLENDER, MeshBuilder, Palette, rig_to_blender

PARTS = [
    "LowerTorso", "UpperTorso", "Head",
    "LeftUpperArm", "LeftLowerArm", "LeftHand",
    "RightUpperArm", "RightLowerArm", "RightHand",
    "LeftUpperLeg", "LeftLowerLeg", "LeftFoot",
    "RightUpperLeg", "RightLowerLeg", "RightFoot",
]

# (joint, part0, part1, pivot in rig space), parents first, and the grips:
# see sky/skeleton.py.
JOINTS = skeleton.JOINTS
JOINT_BY_NAME = {j[0]: j for j in JOINTS}
JOINT_OF_PART = {j[2]: j[0] for j in JOINTS}  # the joint that moves each part
PIVOT = skeleton.PIVOT

# Where a held weapon's grip sits, in rig space at rest (center of the fist).
# The weapon's +Y points forward (-Z) and its broad side (Z) points up, the
# same grip WeaponModels uses.
GRIP = skeleton.GRIP

FIGHTER_EXPORT_DIR = os.path.join(common.EXPORT_DIR, "fighters")


def sides():
    """("Left", -1), ("Right", 1): mirror helpers for symmetric parts."""
    return (("Left", -1), ("Right", 1))


def pivot(joint, dx=0.0, dy=0.0, dz=0.0):
    x, y, z = PIVOT[joint]
    return (x + dx, y + dy, z + dz)


class FighterBuilder:
    """Collects geometry per part, then builds the rigged fighter in Blender."""

    def __init__(self, name, colors, unit=1.0):
        self.name = name
        self.unit = unit  # the fighter script's units -> rig units (R6 studs: skeleton.R6_SCALE)
        self.palette = Palette(name, colors)
        self.parts = {p: MeshBuilder(p, self.palette) for p in PARTS}
        self.objects = {}
        self.empties = {}
        self.markers = []
        self.collection = None

    def __getitem__(self, part):
        return self.parts[part]

    def build(self):
        """Creates the joint empties, part objects and import markers."""
        col = bpy.data.collections.new(self.name)
        bpy.context.scene.collection.children.link(col)
        self.collection = col

        for joint, part0, _part1, pv in JOINTS:
            empty = bpy.data.objects.new("J_" + joint, None)
            empty.empty_display_type = "SPHERE"
            empty.empty_display_size = 0.12
            empty.rotation_mode = "QUATERNION"
            col.objects.link(empty)
            parent_joint = JOINT_OF_PART.get(part0)
            if parent_joint:
                empty.parent = self.empties[parent_joint]
                empty.location = rig_to_blender(pv) - rig_to_blender(PIVOT[parent_joint])
            else:
                empty.location = rig_to_blender(pv)
            self.empties[joint] = empty

        for part in PARTS:
            joint = JOINT_OF_PART[part]
            builder = self.parts[part]
            if self.unit != 1.0:
                builder.scale(self.unit)
            if builder.count == 0:
                raise ValueError(f"{self.name}: part {part} has no geometry")
            obj = builder.build(col, origin=PIVOT[joint])
            obj.parent = self.empties[joint]
            obj.location = (0, 0, 0)
            self.objects[part] = obj

        self.markers = common.add_markers(RIG_TO_BLENDER, col)
        bpy.context.view_layer.update()
        return self

    def rest_bounds(self):
        """Rig-space bounding box (center, size) of every part at rest."""
        to_rig = RIG_TO_BLENDER.transposed()
        bounds = {}
        lo_all = [math.inf] * 3
        hi_all = [-math.inf] * 3
        for part, obj in self.objects.items():
            lo = [math.inf] * 3
            hi = [-math.inf] * 3
            world = obj.matrix_world
            for v in obj.data.vertices:
                p = to_rig @ (world @ v.co)
                for i in range(3):
                    lo[i] = min(lo[i], p[i])
                    hi[i] = max(hi[i], p[i])
                    lo_all[i] = min(lo_all[i], p[i])
                    hi_all[i] = max(hi_all[i], p[i])
            bounds[part] = {
                "center": [round((lo[i] + hi[i]) / 2, 3) for i in range(3)],
                "size": [round(hi[i] - lo[i], 3) for i in range(3)],
            }
        return bounds, (lo_all, hi_all)

    def export(self):
        """Writes <Name>.fbx, <Name>_palette.png and <Name>.json (rig data)."""
        out = common.ensure_dir(FIGHTER_EXPORT_DIR)
        palette_path = self.palette.save(os.path.join(out, f"{self.name}_palette.png"))
        fbx_path = common.export_fbx(os.path.join(out, f"{self.name}.fbx"),
                                     list(self.objects.values()) + self.markers)
        bounds, (lo, hi) = self.rest_bounds()
        tris = {part: common.triangle_count(obj) for part, obj in self.objects.items()}
        info = {
            "name": self.name,
            "height": round(hi[1], 3),
            "parts": bounds,
            "triangles": sum(tris.values()),
        }
        with open(os.path.join(out, f"{self.name}.json"), "w") as f:
            json.dump(info, f, indent=1, sort_keys=True)
        print(f"[{self.name}] {fbx_path} ({info['triangles']} triangles, height {info['height']})")
        return fbx_path, palette_path, info

    def pose(self, rotations, root_offset=(0, 0, 0)):
        """Poses the rig: {joint: (rx, ry, rz) degrees in rig space}."""
        for joint, empty in self.empties.items():
            empty.rotation_quaternion = joint_quaternion(rotations.get(joint, (0, 0, 0)))
        root = self.empties["Root"]
        root.location = rig_to_blender(PIVOT["Root"]) + rig_to_blender(root_offset)
        bpy.context.view_layer.update()


def joint_quaternion(degrees):
    """Rig-space CFrame.Angles(rx, ry, rz) as a Blender quaternion."""
    return common.rotation_matrix(RIG_TO_BLENDER, degrees).to_quaternion()


def joint_angles(quaternion):
    """Inverse of joint_quaternion: Blender quaternion -> rig-space XYZ degrees."""
    m = RIG_TO_BLENDER.transposed() @ quaternion.to_matrix() @ RIG_TO_BLENDER
    # CFrame.Angles order is Rx * Ry * Rz, which is Blender's "ZYX" euler order.
    e = m.to_euler("ZYX")
    return (math.degrees(e.x), math.degrees(e.y), math.degrees(e.z))


# Previews -------------------------------------------------------------------

TURNAROUND_ANGLES = (0, 45, 90, 180)  # front, three-quarter, side (game view), back


def render_turnaround(fb, path, extra=None, spacing=5.4, size=(2000, 700)):
    """Front / 3-4 / side / back views of the fighter side by side, in Roblox
    plastic. `extra` is a list of collections rendered to the right (weapons,
    poses)."""
    common.plastic_preview_materials(fb.objects.values())
    for m in fb.markers:
        m.hide_render = True
    layer_col = bpy.context.view_layer.layer_collection.children[fb.collection.name]
    layer_col.exclude = True

    slots = [(fb.collection, a) for a in TURNAROUND_ANGLES] + [(c, 0) for c in (extra or [])]
    for i, (col, angle) in enumerate(slots):
        inst = bpy.data.objects.new(f"View{i}", None)
        inst.instance_type = "COLLECTION"
        inst.instance_collection = col
        inst.location = (i * spacing, 0, 0)
        inst.rotation_euler = (0, 0, math.radians(angle))
        bpy.context.scene.collection.objects.link(inst)

    width = (len(slots) - 1) * spacing + spacing
    w, h = size
    common.setup_preview_render(path, w, h)
    ortho = max(width, 7.2 * w / h)
    common.ortho_camera("PreviewCam", ((len(slots) - 1) * spacing / 2, -40, 3.2),
                        ((len(slots) - 1) * spacing / 2, 0, 3.2), ortho)
    return common.render(path)


# FighterRigs.luau ---------------------------------------------------------------


def _lua_vec(v):
    return "{ " + ", ".join(_num(x) for x in v) + " }"


def _num(x):
    x = round(float(x), 3)
    if x == 0:
        x = 0.0
    text = f"{x:.3f}".rstrip("0").rstrip(".")
    return text if text not in ("-0", "") else "0"


def write_fighter_rigs_luau():
    """Regenerates src/shared/FighterRigs.luau from every exported fighter."""
    fighters = {}
    if os.path.isdir(FIGHTER_EXPORT_DIR):
        for file in sorted(os.listdir(FIGHTER_EXPORT_DIR)):
            if file.endswith(".json"):
                with open(os.path.join(FIGHTER_EXPORT_DIR, file)) as f:
                    info = json.load(f)
                fighters[info["name"]] = info

    lines = [
        "--[[",
        "    GENERATED by art/blender/build.py from the SkyRig. Do not edit by hand.",
        "",
        "    Skinned fighters are one skinned mesh whose bones carry the joint names;",
        "    Parts are the invisible proxy parts the game animates and holds weapons",
        "    with, and Sways are chains of extra bones (capes, hair, tails) the game",
        "    swings with springs. Bones are named <Name>1, <Name>2, ... down a chain.",
        "",
        "    Rig space: X = the fighter's right, Y = up, Z = behind (it faces -Z),",
        "    origin between the feet, 1 unit = 1 stud. Positions are { x, y, z }.",
        "    Joints are listed parents first; Part0 \"RigRoot\" is the invisible",
        "    root part the game welds to the HumanoidRootPart.",
        "]]",
        "",
        "return {",
        "\tJoints = {",
    ]
    for joint, part0, part1, pv in JOINTS:
        lines.append(f'\t\t{{ Name = "{joint}", Part0 = "{part0}", Part1 = "{part1}", Pivot = {_lua_vec(pv)} }},')
    lines += ["\t},", "\tGrip = {"]
    for side in ("Left", "Right"):
        hand = f"{side}Hand"
        lines.append(f'\t\t{side} = {{ Part = "{hand}", Position = {_lua_vec(GRIP[side])} }},')
    lines += ["\t},", f"\tMarkerDistance = {_num(common.MARKER_DISTANCE)},", "\tFighters = {"]
    for name, info in fighters.items():
        lines.append(f"\t\t{name} = {{")
        lines.append(f"\t\t\tHeight = {_num(info['height'])},")
        if "sways" in info:
            lines.append("\t\t\tSkinned = true,")
        lines.append("\t\t\tParts = {")
        for part in PARTS:
            b = info["parts"].get(part, {"center": [0, 3, 0], "size": [0.2, 0.2, 0.2]})
            lines.append(f"\t\t\t\t{part} = {{ Center = {_lua_vec(b['center'])}, Size = {_lua_vec(b['size'])} }},")
        lines.append("\t\t\t},")
        if "sways" in info:
            lines.append("\t\t\tSways = {")
            for sw in info["sways"]:
                lines.append("\t\t\t\t{")
                lines.append(f'\t\t\t\t\tName = "{sw["name"]}",')
                lines.append(f'\t\t\t\t\tParent = "{sw["parent"]}",')
                pts = ", ".join(_lua_vec(p) for p in sw["points"])
                if 20 + len(f"Points = {{ {pts} }},") <= 120:  # five tabs, within StyLua's column width
                    lines.append(f"\t\t\t\t\tPoints = {{ {pts} }},")
                else:
                    lines.append("\t\t\t\t\tPoints = {")
                    lines += [f"\t\t\t\t\t\t{_lua_vec(p)}," for p in sw["points"]]
                    lines.append("\t\t\t\t\t},")
                lines.append(f'\t\t\t\t\tStiffness = {_num(sw["stiffness"])},')
                lines.append(f'\t\t\t\t\tDamping = {_num(sw["damping"])},')
                lines.append(f'\t\t\t\t\tLimit = {_num(sw["limit"])},')
                if sw.get("behind") is not None:
                    lines.append(f'\t\t\t\t\tBehind = {_num(sw["behind"])},')
                lines.append("\t\t\t\t},")
            lines.append("\t\t\t},")
        lines.append("\t\t},")
    lines += ["\t},", "}", ""]
    path = os.path.join(common.SHARED_SRC, "FighterRigs.luau")
    with open(path, "w") as f:
        f.write("\n".join(lines))
    print(f"wrote {path} ({len(fighters)} fighters)")
    return path


def model_fighter(module):
    """Builds a fighter script's (art/blender/fighters/<name>.py) rig in the
    current scene. Scripts may author in R6 studs (UNIT = skeleton.R6_SCALE)."""
    fb = FighterBuilder(module.NAME, module.COLORS, getattr(module, "UNIT", 1.0))
    module.model(fb)
    return fb.build()


def build_fighter(module):
    """Runs a fighter script: builds, exports and renders its turnaround.
    Returns the export info."""
    if getattr(module, "HERO", False):
        from . import hero
        return hero.build(module)
    common.reset_scene()
    fb = model_fighter(module)
    _, _, info = fb.export()
    extra = []
    if hasattr(module, "preview_extras"):
        extra = module.preview_extras(fb) or []
    render_turnaround(fb, os.path.join(common.PREVIEW_DIR, "fighters", f"{module.NAME}.png"), extra)
    return info


__all__ = [
    "PARTS", "JOINTS", "PIVOT", "GRIP", "FighterBuilder", "sides", "pivot", "model_fighter",
    "joint_quaternion", "joint_angles", "render_turnaround", "write_fighter_rigs_luau",
    "build_fighter", "Matrix", "Vector",
]
