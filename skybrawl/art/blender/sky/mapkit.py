"""
Map kits: the stage visuals and 3D scenery for one arena, in arena space
(X right as the camera sees it, Y up, Z toward the camera; fighters walk on
the Z = 0 lane). The game's collision comes from src/shared/Maps.luau, so
every platform's walkable top must sit exactly on its rectangle's Y2.

A map script (art/blender/maps/<name>.py) defines:
    MAP_ID     "SkyShip"                       (matches Maps.luau)
    COLORS     {"key": "#rrggbb"}              (one palette texture per map)
    PLATFORMS  [(x1, y1, x2, y2, soft), ...]   (copied from Maps.luau)
    SKY        ("#top", "#bottom")             (preview background)
    model(mb)  adds geometry with mb.piece("Name").box(...), etc.
"""

import json
import math
import os

import bpy
from mathutils import Vector

from . import common
from .common import ARENA_TO_BLENDER, MeshBuilder, Palette, arena_to_blender

MAP_EXPORT_DIR = os.path.join(common.EXPORT_DIR, "maps")
MAX_PIECE_TRIANGLES = 10000  # Roblox allows 20k per MeshPart; stay well under


class MapBuilder:
    def __init__(self, map_id, colors):
        self.map_id = map_id
        self.palette = Palette(map_id, colors)
        self.pieces = {}
        self.objects = []
        self.markers = []
        self.collection = None

    def piece(self, name):
        """A named mesh in the kit (one MeshPart in Studio). Split big kits into
        several pieces so each stays under MAX_PIECE_TRIANGLES."""
        if name not in self.pieces:
            self.pieces[name] = MeshBuilder(name, self.palette, space=ARENA_TO_BLENDER)
        return self.pieces[name]

    def build(self):
        col = bpy.data.collections.new(self.map_id)
        bpy.context.scene.collection.children.link(col)
        self.collection = col
        for name, builder in self.pieces.items():
            if builder.count == 0:
                continue
            obj = builder.build(col)
            tris = common.triangle_count(obj)
            if tris > MAX_PIECE_TRIANGLES:
                raise ValueError(f"{self.map_id}: piece {name} has {tris} triangles (max {MAX_PIECE_TRIANGLES})")
            self.objects.append(obj)
        self.markers = common.add_markers(ARENA_TO_BLENDER, col)
        bpy.context.view_layer.update()
        return self

    def export(self):
        out = common.ensure_dir(MAP_EXPORT_DIR)
        self.palette.save(os.path.join(out, f"{self.map_id}_palette.png"))
        path = common.export_fbx(os.path.join(out, f"{self.map_id}.fbx"), self.objects + self.markers,
                                 space=ARENA_TO_BLENDER)
        tris = {o.name: common.triangle_count(o) for o in self.objects}
        info = {"map": self.map_id, "pieces": tris, "triangles": sum(tris.values())}
        with open(os.path.join(out, f"{self.map_id}.json"), "w") as f:
            json.dump(info, f, indent=1, sort_keys=True)
        print(f"[{self.map_id}] {path} ({info['triangles']} triangles in {len(tris)} pieces)")
        return path, info


def _emission_material(name, rgb):
    mat = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    mat.use_nodes = True
    nodes = mat.node_tree.nodes
    nodes.clear()
    out = nodes.new("ShaderNodeOutputMaterial")
    emit = nodes.new("ShaderNodeEmission")
    emit.inputs["Color"].default_value = (*rgb, 1)
    mat.node_tree.links.new(emit.outputs[0], out.inputs[0])
    return mat


def collision_overlay(platforms, z=9.0):
    """Bright outlines of the collision rectangles, drawn in front of the stage
    (red = solid, yellow = soft), to check that the art lines up."""
    objs = []
    for i, (x1, y1, x2, y2, soft) in enumerate(platforms):
        mat = _emission_material("OverlaySoft" if soft else "OverlaySolid", (1, 0.85, 0) if soft else (1, 0.1, 0.1))
        t = 0.25
        bars = [
            ((x1 + x2) / 2, y2, x2 - x1, t), ((x1 + x2) / 2, y1, x2 - x1, t),
            (x1, (y1 + y2) / 2, t, y2 - y1), (x2, (y1 + y2) / 2, t, y2 - y1),
        ]
        for j, (cx, cy, w, h) in enumerate(bars):
            bpy.ops.mesh.primitive_cube_add(size=1, location=arena_to_blender((cx, cy, z)))
            bar = bpy.context.active_object
            bar.name = f"Overlay{i}_{j}"
            bar.scale = (w, 0.1, h)
            bar.data.materials.append(mat)
            objs.append(bar)
    return objs


def game_camera(platforms, fov=36.0, margin=1.25):
    """Perspective camera roughly where the game's follow camera sits."""
    xs = [p[0] for p in platforms] + [p[2] for p in platforms]
    ys = [p[1] for p in platforms] + [p[3] for p in platforms]
    cx = (min(xs) + max(xs)) / 2
    cy = max(ys) / 2
    width = (max(xs) - min(xs)) * margin + 20
    dist = (width / 2) / math.tan(math.radians(fov) / 2)
    loc = arena_to_blender((cx, cy + 4, dist))
    target = arena_to_blender((cx, cy, 0))
    return common.perspective_camera("GameCam", loc, target, fov)


def render_preview(mb, module):
    previews = common.ensure_dir(os.path.join(common.PREVIEW_DIR, "maps"))
    common.toon_preview_materials(mb.objects, outline=0.12)
    for m in mb.markers:
        m.hide_render = True
    top, bottom = (common.hex_color(c) for c in module.SKY)
    sky = tuple((a + b) / 2 for a, b in zip(top, bottom))
    path = os.path.join(previews, f"{mb.map_id}.png")
    common.setup_preview_render(path, 1600, 900, background=sky)
    bpy.context.scene.world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.8
    game_camera(module.PLATFORMS)
    common.render(path)
    collision_overlay(module.PLATFORMS)
    return common.render(os.path.join(previews, f"{mb.map_id}_collision.png"))


def build_map(module):
    common.reset_scene()
    mb = MapBuilder(module.MAP_ID, module.COLORS)
    module.model(mb)
    mb.build()
    _, info = mb.export()
    render_preview(mb, module)
    return info


__all__ = ["MapBuilder", "build_map", "render_preview", "collision_overlay", "Vector"]
