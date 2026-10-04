"""
Painted map backgrounds ("vistas"). Each map's background is a small 3D
scene rendered in a stylized, painted look and split into the three layers
the game stacks with parallax (Config.Art.SkyLayers):

    Sky        the sky dome, the sun and the farthest clouds (opaque)
    Landmarks  the map's themed vista: towns, ships, ruins (transparent)
    Haze       near clouds, smoke or mist, mostly along the bottom (transparent)

Two looks (STYLES):
    graphic    flat cel tones with ink outlines and a banded sun halo
    painterly  soft light with a warm rim glow, a brush-stroke filter
               (Kuwahara), bloom and light shafts

Scenes are built in arena space (x right, y up, z toward the camera; the
camera sits at the origin looking down -z, tilted up by the look's pitch so
the horizon sits low) and composed in screen terms: Vista.at(u, v, depth) is
the point at screen position (u, v) (-1..1, left to right and bottom to top)
`depth` units in front of the camera. Everything fades into the sky's colors
with distance, so depth reads like a painting.

Outputs art/export/skies/painted/<MapId>_<Layer>.png (2048x1152) and a
preview of the three layers stacked the way the game shows them,
art/previews/vistas/<MapId>_<style>.jpg.
"""

import math
import os

import bpy
from mathutils import Vector

from sky import common
from sky.common import ARENA_TO_BLENDER, MeshBuilder, Palette, arena_to_blender

W, H = 2048, 1152
FOV = 64.0  # horizontal, degrees: what the player sees of each layer
LAYERS = ("Sky", "Landmarks", "Haze")
# Config.Art.SkyLayers' parallax speeds. The game draws each layer this much
# bigger than the screen so it can slide (SkyBackdrop.margin), so each layer
# is rendered with a matching wider view: its middle is the composed picture
# and the extra border is real painting for the slide to reveal.
PARALLAX = {"Sky": 0.03, "Landmarks": 0.09, "Haze": 0.2}


def margin(layer):
    return 1 + PARALLAX[layer] * 1.5 + 0.06

GROUPS = ("Solid", "Cloud", "Glow")
OUT_DIR = os.path.join(common.EXPORT_DIR, "skies", "painted")
PREVIEW_DIR = os.path.join(common.PREVIEW_DIR, "vistas")

STYLES = {
    "graphic": {
        "ramp": "CONSTANT",  # light -> tone steps
        "steps": (0.0, 0.38, 0.72),  # where shadow, mid and lit tones start
        "ink": True,
        "rim": 0.0,
        "brush": 0,
        "grain": 0.0,
        "bloom": 0.35,
        "sun_bands": True,
        "beams": 0.0,
    },
    "painterly": {
        "ramp": "EASE",
        "steps": (0.05, 0.42, 0.85),
        "ink": False,
        "rim": 0.9,
        "brush": 10,
        "grain": 0.14,  # paint grain the brush filter smears into strokes
        "bloom": 0.45,
        "sun_bands": False,
        "beams": 0.22,
    },
}

# Each map's colors and light. Colors are '#rrggbb' sRGB.
DEFAULT_LOOK = {
    "dome": [(-0.3, "#f2b48a"), (0.0, "#ffd99a"), (0.12, "#ffe6b0"), (0.35, "#8fd0e6"), (0.8, "#2f78b8")],
    "sun": (-0.55, 0.5),  # screen position
    "sun_color": "#fff6d8",
    "glow": "#ffcf7a",
    "light_dir": (-0.55, 0.7, 0.45),  # toward the key light, arena space
    "light": "#fff4e2",
    "mid": "#e2c9c8",
    "shadow": "#6c64b0",
    "cloud_light": "#fffaf0",
    "cloud_mid": "#f6dccf",
    "cloud_shadow": "#9d93d6",
    "rim": "#ffd27a",
    "ambient": "#9fb8d8",
    "fog_near": 400.0,
    "fog_far": 14000.0,
    "fog_max": 0.85,
    "sky_fog_scale": 2.2,
    "halo_size": 38.0,  # degrees around the sun the glow reaches
    "halo_strength": 0.6,
    "ink": "#1b2346",
    "glow_strength": 2.6,
    "pitch": 6.0,  # camera tilt up, degrees
}


def lin(color):
    """sRGB '#rrggbb' -> linear RGBA."""
    r, g, b = common.hex_color(color) if isinstance(color, str) else color

    def f(c):
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4

    return (f(r), f(g), f(b), 1.0)


class _Graph:
    """Small helper for building node trees."""

    def __init__(self, tree):
        self.tree = tree
        self.nodes = tree.nodes
        self.nodes.clear()

    def new(self, kind, **props):
        node = self.nodes.new(kind)
        for key, value in props.items():
            setattr(node, key, value)
        return node

    def link(self, out, into):
        self.tree.links.new(out, into)

    def math(self, op, a, b=None, clamp=False):
        node = self.new("ShaderNodeMath", operation=op, use_clamp=clamp)
        for i, value in enumerate((a, b)):
            if value is None:
                continue
            if isinstance(value, (int, float)):
                node.inputs[i].default_value = value
            else:
                self.link(value, node.inputs[i])
        return node.outputs[0]

    def map_range(self, value, lo, hi, to_lo=0.0, to_hi=1.0, interpolation="LINEAR"):
        node = self.new("ShaderNodeMapRange", interpolation_type=interpolation, clamp=True)
        self.link(value, node.inputs["Value"])
        node.inputs["From Min"].default_value = lo
        node.inputs["From Max"].default_value = hi
        node.inputs["To Min"].default_value = to_lo
        node.inputs["To Max"].default_value = to_hi
        return node.outputs["Result"]

    def ramp(self, fac, stops, interpolation="LINEAR"):
        node = self.new("ShaderNodeValToRGB")
        cr = node.color_ramp
        cr.interpolation = interpolation
        while len(cr.elements) > 1:
            cr.elements.remove(cr.elements[-1])
        for i, (pos, color) in enumerate(stops):
            el = cr.elements[0] if i == 0 else cr.elements.new(pos)
            el.position = pos
            el.color = lin(color) if isinstance(color, str) else color
        self.link(fac, node.inputs["Fac"])
        return node.outputs["Color"]

    def combine(self, value):
        """A gray color from a float socket."""
        node = self.new("ShaderNodeCombineColor")
        for i in range(3):
            self.link(value, node.inputs[i])
        return node.outputs[0]

    def mix(self, blend, fac, a, b):
        node = self.new("ShaderNodeMix", data_type="RGBA", blend_type=blend, clamp_result=False)
        for socket, value in ((node.inputs[0], fac), (node.inputs[6], a), (node.inputs[7], b)):
            if isinstance(value, (int, float)):
                socket.default_value = value
            elif isinstance(value, tuple):
                socket.default_value = value
            else:
                self.link(value, socket)
        return node.outputs[2]


class Vista:
    def __init__(self, map_id, colors, style="painterly", look=None, seed=1):
        common.reset_scene()
        self.map_id = map_id
        self.style_name = style
        self.style = STYLES[style]
        self.look = dict(DEFAULT_LOOK, **(look or {}))
        self.palette = Palette(f"{map_id}Vista", colors)
        self.builders = {}
        self.collections = {}
        self.tan_h = math.tan(math.radians(FOV) / 2)
        self.tan_v = self.tan_h * H / W
        self.seed = seed
        pitch = math.radians(self.look["pitch"])
        self.up = Vector((0.0, math.cos(pitch), math.sin(pitch)))
        self.forward = Vector((0.0, math.sin(pitch), -math.cos(pitch)))

    # Composition -----------------------------------------------------------

    def at(self, u, v, depth, dy=0.0):
        """The arena point at screen (u, v), `depth` units in front of the
        camera (dy lifts it in world units)."""
        p = depth * (self.forward + Vector((u * self.tan_h, 0, 0)) + self.up * (v * self.tan_v))
        return (p.x, p.y + dy, p.z)

    def direction(self, u, v):
        return Vector(self.at(u, v, 1.0)).normalized()

    def unit(self, depth):
        """World units per screen width fraction at `depth` (a thing 0.1 of
        the screen wide at depth d is 0.1 * unit(d) across)."""
        return 2 * depth * self.tan_h

    def piece(self, layer, group="Solid"):
        key = (layer, group)
        if key not in self.builders:
            self.builders[key] = MeshBuilder(f"{layer}{group}", self.palette, space=ARENA_TO_BLENDER)
        return self.builders[key]

    # Build -----------------------------------------------------------------

    def _collections(self):
        scene = bpy.context.scene
        for layer in LAYERS:
            parent = bpy.data.collections.new(layer)
            scene.collection.children.link(parent)
            self.collections[layer] = parent
            for group in GROUPS + (("Dome",) if layer == "Sky" else ()):
                child = bpy.data.collections.new(f"{layer}_{group}")
                parent.children.link(child)
                self.collections[(layer, group)] = child

    def _paint_material(self, layer, group):
        look, style = self.look, self.style
        mat = bpy.data.materials.new(f"Vista{layer}{group}")
        mat.use_nodes = True
        g = _Graph(mat.node_tree)
        out = g.new("ShaderNodeOutputMaterial")
        tex = g.new("ShaderNodeTexImage", image=self.palette.image, interpolation="Closest")
        base = tex.outputs["Color"]

        if group == "Glow":
            color = g.mix("MULTIPLY", 1.0, base, (look["glow_strength"],) * 3 + (1.0,))
        else:
            cloud = group == "Cloud"
            diffuse = g.new("ShaderNodeBsdfDiffuse")
            to_rgb = g.new("ShaderNodeShaderToRGB")
            g.link(diffuse.outputs[0], to_rgb.inputs[0])
            light = g.new("ShaderNodeRGBToBW")
            g.link(to_rgb.outputs["Color"], light.inputs[0])
            s0, s1, s2 = style["steps"]
            names = ("cloud_shadow", "cloud_mid", "cloud_light") if cloud else ("shadow", "mid", "light")
            tones = g.ramp(light.outputs[0], [(s0, look[names[0]]), (s1, look[names[1]]), (s2, look[names[2]])],
                           style["ramp"])
            color = g.mix("MULTIPLY", 1.0, base, tones)
            if style["rim"] > 0:
                # warm rim on the edges that face the sun's side of the screen
                weight = g.new("ShaderNodeLayerWeight")
                weight.inputs["Blend"].default_value = 0.35
                edge = g.map_range(weight.outputs["Facing"], 0.45, 0.92)
                geo = g.new("ShaderNodeNewGeometry")
                to_cam = g.new("ShaderNodeVectorTransform", vector_type="NORMAL", convert_from="WORLD",
                               convert_to="CAMERA")
                g.link(geo.outputs["Normal"], to_cam.inputs[0])
                su, sv = look["sun"]
                n = math.hypot(su, sv) or 1.0
                dot = g.new("ShaderNodeVectorMath", operation="DOT_PRODUCT")
                g.link(to_cam.outputs[0], dot.inputs[0])
                dot.inputs[1].default_value = (su / n, sv / n, 0.0)
                side = g.map_range(dot.outputs["Value"], -0.15, 0.6)
                rim = g.math("MULTIPLY", g.math("MULTIPLY", edge, side), style["rim"] * (0.6 if cloud else 1.0))
                color = g.mix("ADD", rim, color, lin(look["rim"]))

        if style["grain"] and group != "Glow":
            # screen-space grain, so strokes are the same size on near and far things
            coord = g.new("ShaderNodeTexCoord")
            for scale, amount in ((55.0, style["grain"]), (9.0, style["grain"] * 0.7)):
                noise = g.new("ShaderNodeTexNoise")
                noise.inputs["Scale"].default_value = scale
                noise.inputs["Detail"].default_value = 3.0
                g.link(coord.outputs["Window"], noise.inputs["Vector"])
                k = g.map_range(noise.outputs["Fac"], 0.3, 0.7, 1 - amount, 1 + amount)
                color = g.mix("MULTIPLY", 1.0, color, g.combine(k))
        # Distance haze toward the sky's color at that height.
        cam = g.new("ShaderNodeCameraData")
        # The sky layer's things are far by design; thin their haze so the
        # horizon keeps its shapes.
        reach = look["sky_fog_scale"] if layer == "Sky" else 1.0
        fog = g.map_range(cam.outputs["View Distance"], look["fog_near"] * reach, look["fog_far"] * reach, 0.0,
                          look["fog_max"])
        fog = g.math("POWER", fog, 0.8)
        if group == "Glow":
            fog = g.math("MULTIPLY", fog, 0.55)
        # The camera sits at the origin, so the point's direction picks the
        # sky color right behind it.
        geo = g.new("ShaderNodeNewGeometry")
        color = g.mix("MIX", fog, color, self._sky_color(g, geo.outputs["Position"], halo=0.5))

        emit = g.new("ShaderNodeEmission")
        g.link(color, emit.inputs["Color"])
        g.link(emit.outputs[0], out.inputs["Surface"])
        return mat

    def _sky_color(self, g, position, halo=1.0):
        """The sky's color in the direction of `position` (from the camera at
        the origin): the dome gradient plus the glow around the sun. Returns
        (color, dot with the sun direction)."""
        look, style = self.look, self.style
        norm = g.new("ShaderNodeVectorMath", operation="NORMALIZE")
        g.link(position, norm.inputs[0])
        sep = g.new("ShaderNodeSeparateXYZ")
        g.link(norm.outputs["Vector"], sep.inputs[0])
        stops = look["dome"]
        lo, hi = stops[0][0], stops[-1][0]
        elevation = g.map_range(sep.outputs["Z"], lo, hi)  # Blender Z is up
        sky = g.ramp(elevation, [((e - lo) / (hi - lo), c) for e, c in stops], "B_SPLINE")
        sun_dir = Vector(arena_to_blender(self.direction(*look["sun"])))
        dot = g.new("ShaderNodeVectorMath", operation="DOT_PRODUCT")
        g.link(norm.outputs["Vector"], dot.inputs[0])
        dot.inputs[1].default_value = tuple(sun_dir)
        size = look["halo_size"] * (0.7 if style["sun_bands"] else 1.0)
        closeness = g.map_range(dot.outputs["Value"], math.cos(math.radians(size)), 1.0)
        if style["sun_bands"]:
            glow = g.ramp(closeness, [(0.0, (0, 0, 0, 1)), (0.55, (0.07, 0.07, 0.07, 1)),
                                      (0.8, (0.17, 0.17, 0.17, 1)), (0.93, (0.32, 0.32, 0.32, 1))], "CONSTANT")
        else:
            glow = g.math("MULTIPLY", g.math("POWER", closeness, 2.2), look["halo_strength"])
        if halo != 1.0:
            glow = g.mix("MULTIPLY", 1.0, glow, (halo, halo, halo, 1.0)) if style["sun_bands"] else \
                g.math("MULTIPLY", glow, halo)
        sky = g.mix("ADD", glow, sky, lin(look["glow"]))
        self._sun_dot = dot.outputs["Value"]
        return sky

    def _dome(self):
        look = self.look
        mat = bpy.data.materials.new("VistaDome")
        mat.use_nodes = True
        g = _Graph(mat.node_tree)
        out = g.new("ShaderNodeOutputMaterial")
        coord = g.new("ShaderNodeTexCoord")
        sky = self._sky_color(g, coord.outputs["Object"])
        dot = self._sun_dot
        disc = g.map_range(dot, math.cos(math.radians(3.3)), math.cos(math.radians(3.0)))
        sun = lin(look["sun_color"])
        sky = g.mix("MIX", disc, sky, (sun[0] * 2.5, sun[1] * 2.5, sun[2] * 2.5, 1.0))
        emit = g.new("ShaderNodeEmission")
        g.link(sky, emit.inputs["Color"])
        g.link(emit.outputs[0], out.inputs["Surface"])

        bpy.ops.mesh.primitive_uv_sphere_add(segments=64, ring_count=32, radius=20000, location=(0, 0, 0))
        dome = bpy.context.active_object
        dome.name = "SkyDome"
        dome.data.materials.append(mat)
        for col in dome.users_collection:
            col.objects.unlink(dome)
        self.collections[("Sky", "Dome")].objects.link(dome)
        dome.visible_shadow = False
        return dome

    def _lights(self):
        scene = bpy.context.scene
        world = bpy.data.worlds.new("VistaWorld")
        scene.world = world
        world.use_nodes = True
        bg = world.node_tree.nodes["Background"]
        bg.inputs["Color"].default_value = lin(self.look["ambient"])
        bg.inputs["Strength"].default_value = 0.3
        sun = bpy.data.lights.new("VistaSun", "SUN")
        sun.energy = 3.4
        sun.angle = math.radians(2)
        obj = bpy.data.objects.new("VistaSun", sun)
        toward = Vector(arena_to_blender(self.look["light_dir"])).normalized()
        obj.rotation_euler = (-toward).to_track_quat("-Z", "Y").to_euler()
        scene.collection.objects.link(obj)

    def _camera(self):
        cam = common.perspective_camera("VistaCam", (0, 0, 0), arena_to_blender(tuple(self.forward * 100)), FOV)
        cam.data.clip_start = 1.0
        cam.data.clip_end = 60000
        cam.data.sensor_fit = "HORIZONTAL"
        return cam

    def _view_layers(self):
        scene = bpy.context.scene
        first = scene.view_layers[0]
        first.name = LAYERS[0]
        for name in LAYERS[1:]:
            scene.view_layers.new(name)
        for vl in scene.view_layers:
            for layer in LAYERS:
                vl.layer_collection.children[layer].exclude = layer != vl.name
            vl.use_freestyle = self.style["ink"]
            if self.style["ink"]:
                self._ink(vl, margin(vl.name))

    def _ink(self, vl, m):
        look = self.look
        fs = vl.freestyle_settings
        fs.crease_angle = math.radians(110)
        for ls in list(fs.linesets):
            fs.linesets.remove(ls)
        for group, width, alpha in (("Solid", 2.6, 1.0), ("Cloud", 1.7, 0.55)):
            ls = fs.linesets.new(f"{vl.name}{group}Ink")
            ls.select_by_visibility = True
            ls.select_by_edge_types = True
            ls.select_by_collection = True
            ls.collection = self.collections[(vl.name, group)]
            ls.select_silhouette = True
            ls.select_border = True
            ls.select_crease = group == "Solid"
            ls.select_external_contour = True
            style = ls.linestyle
            r, gr, b, _ = lin(look["ink"])
            style.color = (r, gr, b)
            style.alpha = alpha
            style.thickness = width / m  # the game zooms the layer back up by m
            style.chaining = "PLAIN"
            fade = style.alpha_modifiers.new("Fade", type="DISTANCE_FROM_CAMERA")
            fade.range_min = look["fog_near"]
            fade.range_max = look["fog_far"] * 0.8
            fade.mapping = "LINEAR"
            fade.invert = True
            thin = style.thickness_modifiers.new("Thin", type="DISTANCE_FROM_CAMERA")
            thin.range_min = look["fog_near"]
            thin.range_max = look["fog_far"]
            thin.value_min = 1.0
            thin.value_max = 0.35
            thin.blend = "MULTIPLY"

    def _compositor(self, layer, m):
        """One layer's post: brush strokes, light shafts and bloom."""
        scene = bpy.context.scene
        scene.use_nodes = True
        g = _Graph(scene.node_tree)
        style = self.style
        img = g.new("CompositorNodeRLayers", layer=layer).outputs["Image"]
        if style["brush"]:
            k = g.new("CompositorNodeKuwahara", variation="ANISOTROPIC")
            g.link(img, k.inputs["Image"])
            k.inputs["Size"].default_value = style["brush"] / m
            k.inputs["Uniformity"].default_value = 4
            k.inputs["Sharpness"].default_value = 0.6
            k.inputs["Eccentricity"].default_value = 1.0
            img = k.outputs["Image"]
        if layer == "Sky" and style["beams"]:
            su, sv = self.look["sun"]
            beams = g.new("CompositorNodeSunBeams")
            beams.source = ((su / m + 1) / 2, (sv / m + 1) / 2)
            beams.ray_length = style["beams"]
            g.link(img, beams.inputs["Image"])
            mix = g.new("CompositorNodeMixRGB", blend_type="SCREEN")
            mix.inputs[0].default_value = 0.35
            g.link(img, mix.inputs[1])
            g.link(beams.outputs["Image"], mix.inputs[2])
            img = mix.outputs["Image"]
        if style["bloom"]:
            glare = g.new("CompositorNodeGlare", glare_type="BLOOM")
            g.link(img, glare.inputs["Image"])
            glare.inputs["Threshold"].default_value = 1.0
            glare.inputs["Strength"].default_value = style["bloom"]
            glare.inputs["Size"].default_value = 0.6
            img = glare.outputs["Image"]
        comp = g.new("CompositorNodeComposite")
        g.link(img, comp.inputs["Image"])

    def build(self):
        self._collections()
        for (layer, group), builder in self.builders.items():
            if builder.count:
                obj = builder.build(self.collections[(layer, group)])
                obj.data.materials[0] = self._material(layer, group)
                obj.visible_shadow = group == "Solid"
        self._dome()
        self._lights()
        self._camera()
        self._view_layers()

    _materials = None

    def _material(self, layer, group):
        if self._materials is None:
            self._materials = {}
        key = (layer, group)
        if key not in self._materials:
            self._materials[key] = self._paint_material(layer, group)
        return self._materials[key]

    def render(self, out_dir=OUT_DIR, scale=1.0):
        """Renders each layer to <out_dir>/<MapId>_<Layer>.png, then the
        stacked preview. Returns the preview's path."""
        scene = bpy.context.scene
        scene.render.engine = "BLENDER_EEVEE_NEXT"
        scene.eevee.taa_render_samples = 24
        scene.render.resolution_x = W
        scene.render.resolution_y = H
        scene.render.resolution_percentage = int(scale * 100)
        scene.render.film_transparent = True
        scene.render.use_freestyle = self.style["ink"]
        scene.render.line_thickness_mode = "RELATIVE"
        scene.view_settings.view_transform = "Standard"
        scene.view_settings.look = "None"
        scene.render.use_single_layer = False
        scene.render.image_settings.color_mode = "RGBA"
        cam = scene.camera
        paths = {}
        for layer in LAYERS:
            m = margin(layer)
            cam.data.angle = 2 * math.atan(self.tan_h * m)
            for vl in scene.view_layers:
                vl.use = vl.name == layer
            self._compositor(layer, m)
            paths[layer] = common.render(os.path.join(common.ensure_dir(out_dir), f"{self.map_id}_{layer}.png"))
        preview = os.path.join(common.ensure_dir(PREVIEW_DIR), f"{self.map_id}_{self.style_name}.jpg")
        stack_preview(paths, preview)
        print(f"[{self.map_id}] {self.style_name} vista -> {preview}")
        return preview


def stack_preview(paths, out_path):
    """The three layers as the game first shows them: each cropped to its
    middle 1/margin and scaled back up, stacked back to front."""
    import numpy as np

    result = None
    for layer in LAYERS:
        img = bpy.data.images.load(paths[layer])
        w, h = img.size
        px = np.array(img.pixels[:], dtype=np.float32).reshape(h, w, 4)
        m = margin(layer)
        cw, ch = round(w / m), round(h / m)
        x0, y0 = (w - cw) // 2, (h - ch) // 2
        crop = px[y0 : y0 + ch, x0 : x0 + cw]
        # bilinear resize back to w x h
        ys = np.linspace(0, ch - 1, h)
        xs = np.linspace(0, cw - 1, w)
        y_lo, x_lo = np.floor(ys).astype(int), np.floor(xs).astype(int)
        y_hi, x_hi = np.minimum(y_lo + 1, ch - 1), np.minimum(x_lo + 1, cw - 1)
        fy, fx = (ys - y_lo)[:, None, None], (xs - x_lo)[None, :, None]
        top = crop[y_lo][:, x_lo] * (1 - fx) + crop[y_lo][:, x_hi] * fx
        bottom = crop[y_hi][:, x_lo] * (1 - fx) + crop[y_hi][:, x_hi] * fx
        layer_px = top * (1 - fy) + bottom * fy
        if result is None:
            result = layer_px
        else:
            a = layer_px[..., 3:4]
            result = layer_px * a + result * (1 - a)
            result[..., 3] = 1.0
        bpy.data.images.remove(img)
    out = bpy.data.images.new("VistaPreview", width=result.shape[1], height=result.shape[0], alpha=False)
    out.pixels[:] = result.ravel()
    out.filepath_raw = out_path
    out.file_format = "JPEG"
    bpy.context.scene.render.image_settings.quality = 88
    out.save()
    bpy.data.images.remove(out)
    return out_path


def build_vista(module, style="painterly", out_dir=OUT_DIR, scale=1.0):
    vista = Vista(module.MAP_ID, module.COLORS, style, getattr(module, "LOOK", None), getattr(module, "SEED", 1))
    module.scene(vista)
    vista.build()
    return vista.render(out_dir, scale)
