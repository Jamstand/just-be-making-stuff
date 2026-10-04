"""
Scene setup, coordinate conversion, palette textures and export helpers.

Coordinate spaces (see art/README.md):
  rig space    X = character's right, Y = up, Z = behind (faces -Z)
  arena space  X = right as the 2D camera sees it, Y = up, Z = toward camera
Blender is Z-up; fighters face Blender -Y, map kits are viewed from Blender -Y.
"""

import math
import os

import bmesh
import bpy
from mathutils import Matrix, Vector

HERE = os.path.dirname(os.path.abspath(__file__))
ART_DIR = os.path.normpath(os.path.join(HERE, "..", ".."))
PROJECT_DIR = os.path.normpath(os.path.join(ART_DIR, ".."))
EXPORT_DIR = os.path.join(ART_DIR, "export")
PREVIEW_DIR = os.path.join(ART_DIR, "previews")
SHARED_SRC = os.path.join(PROJECT_DIR, "src", "shared")

MARKER_DISTANCE = 10.0  # studs between Marker_Origin and Marker_Up / Marker_Front

# Rig space -> Blender: right = -X, up = +Z, behind = +Y
RIG_TO_BLENDER = Matrix(((-1, 0, 0), (0, 0, 1), (0, 1, 0)))
# Arena space -> Blender: right = +X, up = +Z, toward camera = -Y
ARENA_TO_BLENDER = Matrix(((1, 0, 0), (0, 0, -1), (0, 1, 0)))


def rig_to_blender(v):
    return RIG_TO_BLENDER @ Vector(v)


def arena_to_blender(v):
    return ARENA_TO_BLENDER @ Vector(v)


def rotation_matrix(space_matrix, degrees):
    """Roblox-style CFrame.Angles(rx, ry, rz) (= Rx * Ry * Rz) given in rig or
    arena space, converted to a Blender rotation matrix."""
    rx, ry, rz = (math.radians(d) for d in degrees)
    r = Matrix.Rotation(rx, 3, "X") @ Matrix.Rotation(ry, 3, "Y") @ Matrix.Rotation(rz, 3, "Z")
    return space_matrix @ r @ space_matrix.inverted()


def ensure_dir(path):
    os.makedirs(path, exist_ok=True)
    return path


def reset_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.unit_settings.system = "NONE"
    scene.render.fps = 30
    return scene


def hex_color(value):
    value = value.lstrip("#")
    return tuple(int(value[i : i + 2], 16) / 255 for i in (0, 2, 4))


# Palette -------------------------------------------------------------------


class Palette:
    """A grid of flat color swatches in one small texture. Faces are UV-mapped
    to the center of their swatch, so a whole model needs one image."""

    GRID = 8
    CELL = 16

    def __init__(self, name, colors):
        if len(colors) > self.GRID * self.GRID:
            raise ValueError("too many palette colors")
        self.name = name
        self.colors = dict(colors)
        self.index = {key: i for i, key in enumerate(self.colors)}
        size = self.GRID * self.CELL
        image = bpy.data.images.new(f"{name}_palette", width=size, height=size, alpha=False)
        pixels = [0.0] * (size * size * 4)
        for key, i in self.index.items():
            r, g, b = hex_color(self.colors[key])
            cx, cy = i % self.GRID, i // self.GRID
            for y in range(cy * self.CELL, (cy + 1) * self.CELL):
                for x in range(cx * self.CELL, (cx + 1) * self.CELL):
                    o = (y * size + x) * 4
                    pixels[o : o + 4] = (r, g, b, 1.0)
        image.pixels[:] = pixels
        self.image = image

        mat = bpy.data.materials.new(f"{name}_mat")
        mat.use_nodes = True
        nodes = mat.node_tree.nodes
        bsdf = nodes.get("Principled BSDF")
        tex = nodes.new("ShaderNodeTexImage")
        tex.image = image
        tex.interpolation = "Closest"
        mat.node_tree.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
        bsdf.inputs["Roughness"].default_value = 0.85
        self.material = mat

    def uv(self, key):
        i = self.index[key]
        cx, cy = i % self.GRID, i // self.GRID
        return ((cx + 0.5) / self.GRID, (cy + 0.5) / self.GRID)

    def save(self, path):
        ensure_dir(os.path.dirname(path))
        self.image.filepath_raw = path
        self.image.file_format = "PNG"
        self.image.save()
        return path


# Mesh building -----------------------------------------------------------


class MeshBuilder:
    """Accumulates simple primitives into one mesh. Coordinates are in the
    builder's space (rig or arena); `space` converts them to Blender."""

    def __init__(self, name, palette, space=RIG_TO_BLENDER):
        self.name = name
        self.palette = palette
        self.space = space
        self.bm = bmesh.new()
        self.color_layer = self.bm.faces.layers.int.new("color")
        self.count = 0

    # Each primitive is built at the local origin, shaped, then moved.
    # `clip` is a list of (point, normal) planes in builder space; geometry on
    # the side the normal points away from is cut off.
    def _finish(self, tmp, color, center, rotation, smooth, clip=None):
        rot = Matrix.Identity(4)
        if isinstance(rotation, Matrix):
            rot = rotation.to_4x4()
        elif rotation:
            rx, ry, rz = (math.radians(d) for d in rotation)
            rot = Matrix.Rotation(rx, 4, "X") @ Matrix.Rotation(ry, 4, "Y") @ Matrix.Rotation(rz, 4, "Z")
        bmesh.ops.transform(tmp, matrix=Matrix.Translation(Vector(center)) @ rot, verts=tmp.verts)
        for point, normal in clip or ():
            geom = tmp.verts[:] + tmp.edges[:] + tmp.faces[:]
            bmesh.ops.bisect_plane(tmp, geom=geom, dist=1e-5, plane_co=Vector(point),
                                   plane_no=Vector(normal).normalized(), clear_inner=True)
        layer = tmp.faces.layers.int.get("color") or tmp.faces.layers.int.new("color")
        cindex = self.palette.index[color]
        for face in tmp.faces:
            face[layer] = cindex
            face.smooth = smooth
        bmesh.ops.transform(tmp, matrix=self.space.to_4x4(), verts=tmp.verts)
        mesh = bpy.data.meshes.new("tmp")
        tmp.to_mesh(mesh)
        tmp.free()
        self.bm.from_mesh(mesh)
        bpy.data.meshes.remove(mesh)
        self.count += 1

    def box(self, center, size, color, bevel=0.08, rotation=None, taper=None, segments=2, smooth=False, clip=None):
        """Box of `size` (x, y, z). `taper` = (sx, sz) scales the top face."""
        tmp = bmesh.new()
        bmesh.ops.create_cube(tmp, size=1.0)
        sx, sy, sz = size
        for v in tmp.verts:
            v.co = Vector((v.co.x * sx, v.co.y * sy, v.co.z * sz))
            if taper and v.co.y > 0:
                v.co.x *= taper[0]
                v.co.z *= taper[1]
        if bevel and bevel > 0:
            limit = min(sx, sy, sz) * 0.45
            bmesh.ops.bevel(tmp, geom=list(tmp.edges), offset=min(bevel, limit), segments=segments,
                            affect="EDGES", profile=0.5)
        self._finish(tmp, color, center, rotation, smooth or (bevel and segments > 1), clip)

    def sphere(self, center, radius, color, rotation=None, segments=14, rings=9, clip=None):
        """Ellipsoid; `radius` is a number or (rx, ry, rz)."""
        rx, ry, rz = (radius, radius, radius) if isinstance(radius, (int, float)) else radius
        tmp = bmesh.new()
        bmesh.ops.create_uvsphere(tmp, u_segments=segments, v_segments=rings, radius=1.0)
        for v in tmp.verts:
            v.co = Vector((v.co.x * rx, v.co.y * ry, v.co.z * rz))
        self._finish(tmp, color, center, rotation, True, clip)

    def cylinder(self, center, radius, height, color, rotation=None, segments=12, radius_top=None, smooth=True,
                 clip=None):
        """Cylinder (or cone/frustum with `radius_top`) along local +Y."""
        tmp = bmesh.new()
        r2 = radius if radius_top is None else radius_top
        bmesh.ops.create_cone(tmp, cap_ends=True, cap_tris=False, segments=segments,
                              radius1=radius, radius2=r2, depth=height)
        # create_cone builds along Z; turn it to Y
        bmesh.ops.rotate(tmp, verts=tmp.verts, cent=(0, 0, 0), matrix=Matrix.Rotation(math.radians(-90), 3, "X"))
        self._finish(tmp, color, center, rotation, smooth, clip)

    def cone(self, center, radius, height, color, rotation=None, segments=10, smooth=False):
        self.cylinder(center, radius, height, color, rotation, segments, radius_top=0.0, smooth=smooth)

    def capsule(self, a, b, radius, color, segments=12):
        """Rounded limb between points a and b."""
        a, b = Vector(a), Vector(b)
        axis = b - a
        length = axis.length
        tmp = bmesh.new()
        bmesh.ops.create_uvsphere(tmp, u_segments=segments, v_segments=max(6, segments // 2 + 2), radius=radius)
        # poles on Y, then pull the two hemispheres apart
        bmesh.ops.rotate(tmp, verts=tmp.verts, cent=(0, 0, 0), matrix=Matrix.Rotation(math.radians(-90), 3, "X"))
        for v in tmp.verts:
            if v.co.y > 1e-6:
                v.co.y += length / 2
            elif v.co.y < -1e-6:
                v.co.y -= length / 2
        rot = Vector((0, 1, 0)).rotation_difference(axis.normalized()).to_matrix()
        self._finish(tmp, color, (a + b) / 2, rot, True)

    def loft(self, sections, color, center=(0, 0, 0), rotation=None, segments=14, power=2.0,
             caps=(True, True), smooth=True, clip=None):
        """Tube through cross-sections [(x, y, z, rx, rz), ...] given in local
        space. Each section is a ring in the XZ plane; a section with zero radii
        is a point (a pointed end). `power` above 2 squares the rings off."""
        tmp = bmesh.new()
        rings = []
        ex = 2.0 / power
        for x, y, z, rx, rz in sections:
            if rx <= 1e-6 and rz <= 1e-6:
                rings.append([tmp.verts.new((x, y, z))])
                continue
            ring = []
            for i in range(segments):
                a = 2 * math.pi * i / segments
                c, s_ = math.cos(a), math.sin(a)
                ring.append(tmp.verts.new((x + rx * math.copysign(abs(c) ** ex, c), y,
                                           z + rz * math.copysign(abs(s_) ** ex, s_))))
            rings.append(ring)
        for r0, r1 in zip(rings, rings[1:]):
            if len(r0) == 1 and len(r1) == 1:
                continue
            if len(r0) == 1 or len(r1) == 1:
                tip, ring = (r0[0], r1) if len(r0) == 1 else (r1[0], r0)
                for i in range(len(ring)):
                    tmp.faces.new((tip, ring[i], ring[(i + 1) % len(ring)]))
                continue
            for i in range(segments):
                j = (i + 1) % segments
                tmp.faces.new((r0[i], r0[j], r1[j], r1[i]))
        if caps[0] and len(rings[0]) > 2:
            tmp.faces.new(list(reversed(rings[0])))
        if caps[1] and len(rings[-1]) > 2:
            tmp.faces.new(rings[-1])
        self._finish(tmp, color, center, rotation, smooth, clip)

    def torus(self, center, radius, tube, color, rotation=None, segments=16, sides=6, scale=(1, 1), clip=None):
        """Ring lying in the local XZ plane. `scale` stretches it to an oval."""
        tmp = bmesh.new()
        grid = []
        for i in range(segments):
            a = 2 * math.pi * i / segments
            ring = []
            for j in range(sides):
                b = 2 * math.pi * j / sides
                r = radius + tube * math.cos(b)
                ring.append(tmp.verts.new((r * math.cos(a) * scale[0], tube * math.sin(b), r * math.sin(a) * scale[1])))
            grid.append(ring)
        for i in range(segments):
            a, b = grid[i], grid[(i + 1) % segments]
            for j in range(sides):
                k = (j + 1) % sides
                tmp.faces.new((a[j], b[j], b[k], a[k]))
        self._finish(tmp, color, center, rotation, True, clip)

    def limb(self, a, b, r1, r2, color, segments=12, caps=True):
        """Tapered capsule from point a (radius r1) to point b (radius r2)."""
        a, b = Vector(a), Vector(b)
        axis = b - a
        rot = Vector((0, 1, 0)).rotation_difference(axis.normalized()).to_matrix()
        self.cylinder((a + b) / 2, r1, axis.length, color, rot, segments, radius_top=r2)
        if caps:
            self.sphere(a, r1, color, segments=segments, rings=max(6, segments // 2 + 1))
            if r2 > 0.02:
                self.sphere(b, r2, color, segments=segments, rings=max(6, segments // 2 + 1))

    def prism(self, outline, depth, color, center=(0, 0, 0), rotation=None, bevel=0.0, smooth=False, clip=None):
        """Flat shape: the 2D `outline` [(x, y), ...] in the local XY plane,
        extruded `depth` along Z and centered on it."""
        tmp = bmesh.new()
        front = [tmp.verts.new((x, y, -depth / 2)) for x, y in outline]
        face = tmp.faces.new(front)
        ext = bmesh.ops.extrude_face_region(tmp, geom=[face])
        moved = [e for e in ext["geom"] if isinstance(e, bmesh.types.BMVert)]
        bmesh.ops.translate(tmp, verts=moved, vec=(0, 0, depth))
        bmesh.ops.recalc_face_normals(tmp, faces=tmp.faces)
        if bevel:
            bmesh.ops.bevel(tmp, geom=list(tmp.edges), offset=bevel, segments=1, affect="EDGES", profile=0.5,
                            clamp_overlap=True)
        caps = [f for f in tmp.faces if len(f.verts) > 4]
        if caps:
            bmesh.ops.triangulate(tmp, faces=caps, quad_method="BEAUTY", ngon_method="EAR_CLIP")
        self._finish(tmp, color, center, rotation, smooth, clip)

    def wedge(self, center, size, color, rotation=None, bevel=0.0):
        """Triangular prism: full width at the bottom (-Y), a ridge at the top."""
        tmp = bmesh.new()
        bmesh.ops.create_cube(tmp, size=1.0)
        sx, sy, sz = size
        for v in tmp.verts:
            v.co = Vector((v.co.x * sx, v.co.y * sy, v.co.z * sz))
            if v.co.y > 0:
                v.co.z = 0.0
        bmesh.ops.remove_doubles(tmp, verts=tmp.verts, dist=1e-5)
        if bevel:
            bmesh.ops.bevel(tmp, geom=list(tmp.edges), offset=bevel, segments=1, affect="EDGES", profile=0.5)
        self._finish(tmp, color, center, rotation, False)

    def build(self, collection=None, smooth_angle=40, origin=None):
        """Creates the object: UVs every face onto its palette swatch. `origin`
        (builder space) becomes the object's origin."""
        bm = self.bm
        offset = self.space @ Vector(origin) if origin is not None else Vector((0, 0, 0))
        if origin is not None:
            bmesh.ops.translate(bm, verts=bm.verts, vec=-offset)
        bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
        uv_layer = bm.loops.layers.uv.new("UVMap")
        color_layer = bm.faces.layers.int.get("color")
        keys = list(self.palette.colors)
        for face in bm.faces:
            u, v = self.palette.uv(keys[face[color_layer]])
            for loop in face.loops:
                loop[uv_layer].uv = (u, v)
        mesh = bpy.data.meshes.new(self.name)
        bm.to_mesh(mesh)
        bm.free()
        mesh.materials.append(self.palette.material)
        try:
            mesh.set_sharp_from_angle(angle=math.radians(smooth_angle))
        except AttributeError:
            pass
        obj = bpy.data.objects.new(self.name, mesh)
        obj.location = offset
        (collection or bpy.context.scene.collection).objects.link(obj)
        return obj


def triangle_count(obj):
    return sum(len(p.vertices) - 2 for p in obj.data.polygons)


def marker(name, location_blender, collection=None, size=0.2):
    mesh = bpy.data.meshes.new(name)
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=size)
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new(name, mesh)
    obj.location = location_blender
    (collection or bpy.context.scene.collection).objects.link(obj)
    return obj


def add_markers(space, collection=None):
    """Marker_Origin / Marker_Up / Marker_Front (see art/README.md)."""
    if space is RIG_TO_BLENDER:
        up, front = rig_to_blender((0, MARKER_DISTANCE, 0)), rig_to_blender((0, 0, -MARKER_DISTANCE))
    else:
        up, front = arena_to_blender((0, MARKER_DISTANCE, 0)), arena_to_blender((0, 0, MARKER_DISTANCE))
    return [
        marker("Marker_Origin", Vector((0, 0, 0)), collection),
        marker("Marker_Up", up, collection),
        marker("Marker_Front", front, collection),
    ]


def export_fbx(path, objects, space=RIG_TO_BLENDER):
    """FBX whose axes match rig space (fighters, weapons) or arena space (maps),
    so Studio sees +Y up and the model's own axes."""
    ensure_dir(os.path.dirname(path))
    bpy.ops.object.select_all(action="DESELECT")
    for obj in objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = objects[0]
    bpy.ops.export_scene.fbx(
        filepath=path,
        use_selection=True,
        object_types={"MESH"},
        apply_unit_scale=True,
        apply_scale_options="FBX_SCALE_ALL",
        mesh_smooth_type="FACE",
        use_mesh_modifiers=True,
        add_leaf_bones=False,
        bake_anim=False,
        path_mode="COPY",
        embed_textures=True,
        axis_forward="Z" if space is RIG_TO_BLENDER else "-Z",
        axis_up="Y",
    )
    return path


# Preview rendering ------------------------------------------------------


def toon_preview_materials(objects, outline=0.045):
    """Swap materials for cel-shaded preview copies with inverted-hull outlines."""
    outline_mat = bpy.data.materials.get("PreviewOutline")
    if not outline_mat:
        outline_mat = bpy.data.materials.new("PreviewOutline")
        outline_mat.use_nodes = True
        nodes = outline_mat.node_tree.nodes
        nodes.clear()
        out = nodes.new("ShaderNodeOutputMaterial")
        emit = nodes.new("ShaderNodeEmission")
        emit.inputs["Color"].default_value = (0.02, 0.02, 0.04, 1)
        outline_mat.node_tree.links.new(emit.outputs[0], out.inputs[0])
        outline_mat.use_backface_culling = True
    toon_cache = {}
    for obj in objects:
        if obj.type != "MESH" or obj.name.startswith("Marker_"):
            continue
        base = obj.data.materials[0] if obj.data.materials else None
        if base and base.name not in toon_cache:
            toon = bpy.data.materials.new(base.name + "_toon")
            toon.use_nodes = True
            nt = toon.node_tree
            nt.nodes.clear()
            out = nt.nodes.new("ShaderNodeOutputMaterial")
            tex = nt.nodes.new("ShaderNodeTexImage")
            src_tex = next(n for n in base.node_tree.nodes if n.type == "TEX_IMAGE")
            tex.image = src_tex.image
            tex.interpolation = "Closest"
            diffuse = nt.nodes.new("ShaderNodeBsdfDiffuse")
            to_rgb = nt.nodes.new("ShaderNodeShaderToRGB")
            ramp = nt.nodes.new("ShaderNodeValToRGB")
            ramp.color_ramp.interpolation = "CONSTANT"
            ramp.color_ramp.elements[0].position = 0.0
            ramp.color_ramp.elements[0].color = (0.62, 0.62, 0.7, 1)
            ramp.color_ramp.elements[1].position = 0.35
            ramp.color_ramp.elements[1].color = (1, 1, 1, 1)
            mix = nt.nodes.new("ShaderNodeMix")
            mix.data_type = "RGBA"
            mix.blend_type = "MULTIPLY"
            mix.inputs[0].default_value = 1.0
            emit = nt.nodes.new("ShaderNodeEmission")
            nt.links.new(diffuse.outputs[0], to_rgb.inputs[0])
            nt.links.new(to_rgb.outputs["Color"], ramp.inputs["Fac"])
            nt.links.new(tex.outputs["Color"], mix.inputs[6])
            nt.links.new(ramp.outputs["Color"], mix.inputs[7])
            nt.links.new(mix.outputs[2], emit.inputs["Color"])
            nt.links.new(emit.outputs[0], out.inputs[0])
            toon_cache[base.name] = toon
        if base:
            obj.data.materials[0] = toon_cache[base.name]
        if outline:
            obj.data.materials.append(outline_mat)
            mod = obj.modifiers.new("Outline", "SOLIDIFY")
            mod.thickness = outline
            mod.offset = 1.0
            mod.use_flip_normals = True
            mod.material_offset = len(obj.data.materials) - 1
            mod.use_rim = False


def setup_preview_render(path, width, height, background=(0.86, 0.87, 0.9)):
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE_NEXT"
    scene.eevee.taa_render_samples = 16
    scene.render.resolution_x = width
    scene.render.resolution_y = height
    scene.render.film_transparent = False
    scene.view_settings.view_transform = "Standard"
    scene.render.filepath = path
    world = scene.world or bpy.data.worlds.new("World")
    scene.world = world
    world.use_nodes = True
    bg = world.node_tree.nodes.get("Background")
    bg.inputs["Color"].default_value = (*background, 1)
    bg.inputs["Strength"].default_value = 1.0
    sun = bpy.data.lights.new("PreviewSun", "SUN")
    sun.energy = 3.0
    sun_obj = bpy.data.objects.new("PreviewSun", sun)
    sun_obj.rotation_euler = (math.radians(50), math.radians(10), math.radians(-35))
    scene.collection.objects.link(sun_obj)
    return scene


def ortho_camera(name, location, look_at, ortho_scale):
    cam_data = bpy.data.cameras.new(name)
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = ortho_scale
    cam_data.clip_end = 2000
    cam = bpy.data.objects.new(name, cam_data)
    bpy.context.scene.collection.objects.link(cam)
    cam.location = location
    direction = Vector(look_at) - Vector(location)
    cam.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()
    bpy.context.scene.camera = cam
    return cam


def perspective_camera(name, location, look_at, fov_degrees=40):
    cam_data = bpy.data.cameras.new(name)
    cam_data.angle = math.radians(fov_degrees)
    cam_data.clip_end = 5000
    cam = bpy.data.objects.new(name, cam_data)
    bpy.context.scene.collection.objects.link(cam)
    cam.location = location
    direction = Vector(look_at) - Vector(location)
    cam.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()
    bpy.context.scene.camera = cam
    return cam


def render(path):
    """Renders the scene camera to `path`. Previews (anything under
    art/previews) are saved as JPEG to keep the repo small."""
    settings = bpy.context.scene.render.image_settings
    if os.path.abspath(path).startswith(os.path.abspath(PREVIEW_DIR)):
        path = os.path.splitext(path)[0] + ".jpg"
        settings.file_format = "JPEG"
        settings.quality = 88
    else:
        settings.file_format = "PNG"
    ensure_dir(os.path.dirname(path))
    bpy.context.scene.render.filepath = path
    bpy.ops.render.render(write_still=True)
    return path
