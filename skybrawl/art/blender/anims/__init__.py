"""
Skybrawl's animation set, keyed in Blender on the SkyRig armature.

    python art/blender/build.py anims                 bake + export everything
    python art/blender/build.py anims preview Sword   also render contact sheets
                                                      for clip groups (Sword, Loco,
                                                      Kestrel, ... or "all")

Each clip in the anims.* modules becomes a Blender action on an armature
whose bones sit on the SkyRig joints, with every bone's rest frame aligned
to rig space (so a bone's local rotation is the game's Motor6D.Transform).
The export then reads the keys back out of those actions into
src/shared/AnimationData.luau, which the game plays on every client.
"""

import importlib
import json
import math
import os

import bpy
from mathutils import Matrix, Quaternion, Vector

from sky import common, rig

from . import core

MODULES = ["locomotion", "unarmed", "sword", "hammer", "spear", "gauntlets", "scythe", "bow", "signatures"]
PHASE_FRAMES = 10  # Blender frames per move phase in phased clips
FPS = 30

BLENDER_EASE = {
    "Linear": "LINEAR", "Constant": "CONSTANT", "Quad": "QUAD", "Cubic": "CUBIC", "Quart": "QUART",
    "Quint": "QUINT", "Sine": "SINE", "Exponential": "EXPO", "Circular": "CIRC",
}
BLENDER_DIR = {"In": "EASE_IN", "Out": "EASE_OUT", "InOut": "EASE_IN_OUT"}


def load_clips():
    import sys

    core.CLIPS.clear()
    for name in MODULES:
        full = f"anims.{name}"
        if full in sys.modules:
            importlib.reload(sys.modules[full])
        else:
            importlib.import_module(full)
    problems = [p for c in core.CLIPS.values() for p in core.check_clip(c)]
    for problem in problems:
        print("WARNING", problem)
    return dict(core.CLIPS)


# Armature ---------------------------------------------------------------------


def build_armature(name="SkyRig"):
    data = bpy.data.armatures.new(name)
    arm = bpy.data.objects.new(name, data)
    bpy.context.scene.collection.objects.link(arm)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode="EDIT")
    for joint, part0, _part1, pv in rig.JOINTS:
        bone = data.edit_bones.new(joint)
        head = common.rig_to_blender(pv)
        bone.head = head
        bone.tail = head + Vector((0, 0, 0.3))
        bone.roll = math.pi  # bone axes == rig axes (see rig.RIG_TO_BLENDER)
        parent = rig.JOINT_OF_PART.get(part0)
        if parent:
            bone.parent = data.edit_bones[parent]
    bpy.ops.object.mode_set(mode="OBJECT")
    for pb in arm.pose.bones:
        pb.rotation_mode = "QUATERNION"
    return arm


def rig_quaternion(degrees):
    rx, ry, rz = (math.radians(d) for d in degrees)
    return (Matrix.Rotation(rx, 3, "X") @ Matrix.Rotation(ry, 3, "Y") @ Matrix.Rotation(rz, 3, "Z")).to_quaternion()


def rig_degrees(quaternion):
    e = quaternion.to_matrix().to_euler("ZYX")  # == Rx * Ry * Rz
    return (math.degrees(e.x), math.degrees(e.y), math.degrees(e.z))


def apply_pose(arm, pose):
    for pb in arm.pose.bones:
        pb.rotation_quaternion = rig_quaternion(pose.get(pb.name))
        pb.location = Vector(pose.offset) if pb.name == "Root" else Vector((0, 0, 0))


def frame_of(clip, t):
    # Fractional frames, so keys closer together than a Blender frame stay
    # separate (rounding merged them, and the later pose won).
    return 1 + t * (PHASE_FRAMES if clip.phased else FPS)


def bake(arm, clips):
    """One Blender action per clip, keyed on the armature."""
    arm.animation_data_create()
    actions = {}
    for name, clip in clips.items():
        action = bpy.data.actions.new(name)
        action.use_fake_user = True
        arm.animation_data.action = action
        keys = []
        for t, pose, ease in clip.keys:
            frame = frame_of(clip, t)
            apply_pose(arm, pose)
            for pb in arm.pose.bones:
                pb.keyframe_insert("rotation_quaternion", frame=frame, group=pb.name)
                if pb.name == "Root":
                    pb.keyframe_insert("location", frame=frame, group=pb.name)
            keys.append([frame, t, ease])
        # interpolation of each key = the ease toward the next key
        by_frame = {round(k[0], 4): k[2] for k in keys}
        for fc in action.fcurves:
            for kp in fc.keyframe_points:
                ease = by_frame.get(round(kp.co.x, 4), "Linear")
                style, _, direction = ease.partition(".")
                kp.interpolation = BLENDER_EASE[style]
                if direction:
                    kp.easing = BLENDER_DIR[direction]
        action["sky_keys"] = json.dumps(keys)
        action["sky_meta"] = json.dumps({"phased": clip.phased, "loop": clip.loop, "length": clip.length})
        actions[name] = action
    arm.animation_data.action = None
    return actions


def read_action(arm, action):
    """Reads an action's keys back as rig-space data (what gets exported)."""
    scene = bpy.context.scene
    arm.animation_data.action = action
    keys = json.loads(action["sky_keys"])
    meta = json.loads(action["sky_meta"])
    out = []
    for frame, t, ease in keys:
        whole = math.floor(frame)
        scene.frame_set(whole, subframe=frame - whole)
        rot = {}
        for pb in arm.pose.bones:
            deg = rig_degrees(pb.rotation_quaternion.normalized())
            if max(abs(d) for d in deg) > 0.05:
                rot[pb.name] = tuple(round(d, 1) for d in deg)
        loc = arm.pose.bones["Root"].location
        offset = tuple(round(v, 3) for v in loc)
        out.append({"t": t, "ease": ease, "rot": rot, "offset": offset})
    arm.animation_data.action = None
    return meta, out


# Luau export ----------------------------------------------------------------------


def _num(x, digits):
    x = round(float(x), digits)
    if x == 0:
        return "0"
    text = f"{x:.{digits}f}".rstrip("0").rstrip(".")
    return text


def _clip_lines(meta, keys):
    lines = [f'\t["{{name}}"] = {{ Phased = {str(meta["phased"]).lower()}, Loop = {str(meta["loop"]).lower()}, '
             f'Length = {_num(meta["length"], 3)}, Keys = {{']
    for key in keys:
        flat = []
        for joint in core.JOINTS:
            flat += [str(int(round(v))) for v in key["rot"].get(joint, (0, 0, 0))]
        parts = [f'T = {_num(key["t"], 3)}', f'E = "{key["ease"]}"', "R = {" + ",".join(flat) + "}"]
        if any(abs(v) > 1e-3 for v in key["offset"]):
            parts.append("O = {" + ",".join(_num(v, 2) for v in key["offset"]) + "}")
        lines.append("\t\t{ " + ", ".join(parts) + " },")
    lines.append("\t} },")
    return lines


HEADER = [
    "--[[",
    "    GENERATED by art/blender/build.py anims from the Blender actions on the",
    "    SkyRig armature. Do not edit by hand; edit art/blender/anims/*.py.",
    "]]",
    "",
]


def write_luau(arm, actions, folder=None):
    """src/shared/AnimationData/ (one module per clip group, merged by init)."""
    folder = folder or os.path.join(common.SHARED_SRC, "AnimationData")
    os.makedirs(folder, exist_ok=True)
    for old in os.listdir(folder):
        if old.endswith(".luau"):
            os.remove(os.path.join(folder, old))
    groups = {}
    for name in sorted(actions):
        groups.setdefault(group_of(name), []).append(name)
    total = 0
    for group, names in groups.items():
        lines = HEADER + ["-- stylua: ignore start", "return {"]
        for name in names:
            meta, keys = read_action(arm, actions[name])
            lines += [line.replace("{name}", name) for line in _clip_lines(meta, keys)]
        lines += ["}", "-- stylua: ignore end", ""]
        path = os.path.join(folder, f"{group}.luau")
        with open(path, "w") as f:
            f.write("\n".join(lines))
        total += os.path.getsize(path)
    init = HEADER[:-2] + [
        "",
        "    Clips[name] = { Phased, Loop, Length, Keys }",
        "      Phased  key times are move phases: 0-1 startup, 1-2 active, 2-3 recovery",
        "              (otherwise seconds)",
        "      Keys    { T, E = \"Style.Direction\" easing toward the next key,",
        "                R = flat { x, y, z, ... } degrees per joint in Joints order",
        "                (CFrame.Angles on the joint, rig space), O = root offset }",
        "    Clips are authored facing right; the game mirrors them for facing left.",
        "]]",
        "",
        "-- stylua: ignore start",
        "local Data = {",
        "\tVersion = 2,",
        "\tJoints = { " + ", ".join(f'"{j}"' for j in core.JOINTS) + " },",
        "\tClips = {},",
        "}",
        "",
        "for _, group in {",
    ]
    init += [f"\trequire(script.{group})," for group in groups]
    init += [
        "} do",
        "\tfor name, clip in group do",
        "\t\tData.Clips[name] = clip",
        "\tend",
        "end",
        "-- stylua: ignore end",
        "",
        "return Data",
        "",
    ]
    with open(os.path.join(folder, "init.luau"), "w") as f:
        f.write("\n".join(init))
    print(f"wrote {folder} ({len(actions)} clips in {len(groups)} modules, {total // 1024} KB)")
    return folder


# Previews ---------------------------------------------------------------------------

WEAPON_PROXY = {
    # weapon id: (hand, [(center in weapon frame, size, color)])
    "Sword": ("Right", [((0, 2.9, 0), (0.12, 4.2, 0.55), (0.8, 0.85, 0.95)), ((0, 0.75, 0), (0.3, 0.2, 1.3), (0.8, 0.6, 0.2))]),
    "Hammer": ("Right", [((0, 1.4, 0), (0.25, 4.4, 0.25), (0.5, 0.33, 0.2)), ((0, 3.7, 0), (1.3, 1.5, 2.9), (0.45, 0.45, 0.5))]),
    "Spear": ("Right", [((0, 2.4, 0), (0.2, 7.2, 0.2), (0.5, 0.33, 0.2)), ((0, 6.8, 0), (0.12, 1.5, 0.6), (0.8, 0.85, 0.95))]),
    "Gauntlets": ("Both", [((0, 0.1, 0), (1.0, 1.1, 1.0), (0.75, 0.3, 0.3))]),
    "Scythe": ("Right", [((0, 2.2, 0), (0.2, 6.4, 0.2), (0.4, 0.3, 0.25)), ((0, 5.1, -1.6), (0.12, 0.6, 3.3), (0.6, 0.5, 0.8))]),
    "Bow": ("Left", [((0, -0.3, 1.2), (0.2, 0.25, 2.3), (0.85, 0.75, 0.55)), ((0, -0.3, -1.2), (0.2, 0.25, 2.3), (0.85, 0.75, 0.55))]),
}


def _flat_material(name, rgb):
    mat = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    mat.use_nodes = True
    nt = mat.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    emit = nt.nodes.new("ShaderNodeEmission")
    emit.inputs["Color"].default_value = (*rgb, 1)
    nt.links.new(emit.outputs[0], out.inputs[0])
    return mat


def _grip_matrix(side):
    """Weapon frame -> Blender, at the rest grip: weapon +Y = rig forward (-Z),
    weapon +Z = rig up, weapon X = rig X."""
    gx, gy, gz = rig.GRIP[side]
    w2r = Matrix(((1, 0, 0), (0, 0, 1), (0, -1, 0)))  # columns: X->X, Y->-Z, Z->Y
    m = common.RIG_TO_BLENDER @ w2r
    return Matrix.Translation(common.rig_to_blender((gx, gy, gz))) @ m.to_4x4()


def weapon_proxy(weapon, arm, collection):
    spec = WEAPON_PROXY.get(weapon)
    if not spec:
        return []
    hand, boxes = spec
    sides = ["Right", "Left"] if hand == "Both" else [hand]
    objs = []
    for side in sides:
        grip = _grip_matrix(side)
        for i, (center, size, color) in enumerate(boxes):
            mesh = bpy.data.meshes.new(f"{weapon}{side}{i}")
            import bmesh

            bm = bmesh.new()
            bmesh.ops.create_cube(bm, size=1.0)
            for v in bm.verts:
                v.co = Vector((v.co.x * size[0] + center[0], v.co.y * size[1] + center[1], v.co.z * size[2] + center[2]))
            bm.to_mesh(mesh)
            bm.free()
            mesh.materials.append(_flat_material(f"Proxy{color}", color))
            obj = bpy.data.objects.new(mesh.name, mesh)
            collection.objects.link(obj)
            world = grip.copy()
            obj.parent = arm
            obj.parent_type = "BONE"
            obj.parent_bone = f"{side}Wrist"
            bpy.context.view_layer.update()
            obj.matrix_world = world
            objs.append(obj)
    return objs


def preview_fighter(arm):
    """Kestrel's meshes re-parented onto the armature's bones."""
    fb = rig.model_fighter(importlib.import_module("fighters.kestrel"))
    common.plastic_preview_materials(fb.objects.values())
    for part, obj in fb.objects.items():
        world = obj.matrix_world.copy()
        obj.parent = arm
        obj.parent_type = "BONE"
        obj.parent_bone = rig.JOINT_OF_PART[part]
        bpy.context.view_layer.update()
        obj.matrix_world = world
    for m in fb.markers:
        bpy.data.objects.remove(m)
    for e in fb.empties.values():
        bpy.data.objects.remove(e)
    return fb


def _pose_at(clip, t):
    keys = clip.keys
    if t <= keys[0][0]:
        return keys[0][1]
    for (t0, p0, _), (t1, p1, _) in zip(keys, keys[1:]):
        if t0 <= t <= t1:
            return core.lerp_pose(p0, p1, (t - t0) / max(t1 - t0, 1e-6))
    return keys[-1][1]


def weapon_of(name):
    for part in name.split("."):
        if part in WEAPON_PROXY:
            return part
    return None


def render_contact_sheet(clips, names, path, columns=None, cell=(180, 240)):
    """Rows = clips, columns = the clip's keys, seen from the game's side view."""
    common.reset_scene()
    src_arm = build_armature("Src")
    src_col = bpy.data.collections.new("Src")
    bpy.context.scene.collection.children.link(src_col)
    fb = preview_fighter(src_arm)
    for obj in fb.objects.values():
        for c in obj.users_collection:
            c.objects.unlink(obj)
        src_col.objects.link(obj)
    max_keys = max(len(clips[n].keys) for n in names)
    columns = columns or max_keys
    spacing_x, spacing_y = 7.5, 10.0
    for row, name in enumerate(names):
        clip = clips[name]
        weapon = weapon_of(name)
        times = [k[0] for k in clip.keys]
        for col, t in enumerate(times[:columns]):
            arm = src_arm.copy()
            bpy.context.scene.collection.objects.link(arm)
            arm.animation_data_clear()
            for obj in fb.objects.values():
                dup = obj.copy()
                bpy.context.scene.collection.objects.link(dup)
                dup.parent = arm
            if weapon:
                weapon_proxy(weapon, arm, bpy.context.scene.collection)
            apply_pose(arm, _pose_at(clip, t))
            arm.location = (col * spacing_x, 0, -row * spacing_y)
            arm.rotation_euler = (0, 0, math.radians(90))
    src_arm.hide_render = True
    bpy.context.view_layer.layer_collection.children["Src"].exclude = True
    w = columns * cell[0]
    h = len(names) * cell[1]
    common.setup_preview_render(path, w, h)
    width = columns * spacing_x
    height = len(names) * spacing_y
    scale = max(width, height * w / h) if w >= h else max(height, width * h / w)
    center = ((columns - 1) * spacing_x / 2, 0, 3.2 - (len(names) - 1) * spacing_y / 2)
    common.ortho_camera("Cam", (center[0], -60, center[2]), center, scale)
    return common.render(path)


GROUPS = ["Loco", "Unarmed", "Sword", "Hammer", "Spear", "Gauntlets", "Scythe", "Bow",
          "Kestrel", "Brann", "Yuki", "Moss", "Vex", "Sol"]


def group_of(name):
    return name.split(".")[0]


def build_all(names=None):
    names = list(names or [])
    preview = []
    if names and names[0] == "preview":
        preview = names[1:] or ["all"]
    clips = load_clips()
    common.reset_scene()
    arm = build_armature()
    actions = bake(arm, clips)
    write_luau(arm, actions)
    if preview:
        groups = GROUPS if "all" in preview else preview
        for group in groups:
            members = sorted(n for n in clips if group_of(n) == group)
            if not members:
                print(f"no clips in group {group}")
                continue
            out = os.path.join(common.PREVIEW_DIR, "anims", f"{group}.png")
            render_contact_sheet(clips, members, out)
    return clips
