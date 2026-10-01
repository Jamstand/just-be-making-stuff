"""
sockkit.py - shared helpers for building Steal a Sock assets in Blender (bpy 4.5 LTS).

Style (docs/concept/bedroom_keyframe.png): chunky rounded shapes, flat palette colours, thick
dark outlines. Every asset is assembled from simple "pieces"; each piece carries a palette colour
per face, an outline flag and a smooth/flat flag. `finish()` merges the pieces into one mesh,
adds an inverted-hull outline (a slightly inflated, inside-out black copy - Roblox culls back
faces, so only the silhouette edge shows), and maps every face to its colour swatch in one shared
512x512 palette texture. Coordinates: Blender Z-up; the asset's FRONT faces -Y (becomes +Z in
glTF/Roblox).
"""
import math
import bmesh
import bpy
from mathutils import Matrix, Vector

# ---------------------------------------------------------------- palette
PALETTE: dict[str, tuple[int, int, int]] = {}
_ORDER: list[str] = []
SWATCH = 16  # px per swatch; 32x32 grid -> 1024 colours in a 512x512 image
GRID = 32


def color(name: str, rgb: tuple[int, int, int] | None = None) -> int:
    """Registers (or looks up) a named palette colour and returns its index."""
    if name not in PALETTE:
        if rgb is None:
            raise KeyError(f"unknown colour {name}")
        PALETTE[name] = rgb
        _ORDER.append(name)
    return _ORDER.index(name)


def hexcol(name: str, hexstr: str) -> int:
    h = hexstr.lstrip("#")
    return color(name, (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)))


OUTLINE = color("outline", (34, 22, 48))
WHITE = color("white", (250, 250, 248))
BLACK = color("black", (18, 14, 24))


def swatch_uv(index: int) -> tuple[float, float]:
    col, row = index % GRID, index // GRID
    u = (col + 0.5) / GRID
    v = 1.0 - (row + 0.5) / GRID  # image row 0 is the top
    return u, v


def write_palette(path: str):
    size = SWATCH * GRID
    img = bpy.data.images.new("Palette", size, size, alpha=False)
    px = [0.0] * (size * size * 4)
    for i, name in enumerate(_ORDER):
        r, g, b = PALETTE[name]
        col, row = i % GRID, i // GRID
        for y in range(SWATCH):
            for x in range(SWATCH):
                py = size - 1 - (row * SWATCH + y)  # Blender images are bottom-up
                pxx = col * SWATCH + x
                o = (py * size + pxx) * 4
                px[o:o + 4] = [r / 255, g / 255, b / 255, 1.0]
    img.pixels[:] = px
    img.filepath_raw = path
    img.file_format = "PNG"
    img.save()
    return img


# ---------------------------------------------------------------- scene
def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    PALETTE_KEEP = dict(PALETTE)
    return PALETTE_KEEP


def link(obj):
    bpy.context.scene.collection.objects.link(obj)
    return obj


class Piece:
    """One building block: a mesh in world space plus per-face colours and flags."""

    def __init__(self, mesh: bpy.types.Mesh, pal, outline=True, smooth=True, name="piece"):
        self.mesh = mesh
        self.outline = outline
        self.smooth = smooth
        self.name = name
        n = len(mesh.polygons)
        if isinstance(pal, int):
            self.face_pal = [pal] * n
        else:
            self.face_pal = list(pal)
            assert len(self.face_pal) == n


def _bm_to_mesh(bm: bmesh.types.BMesh, name: str) -> bpy.types.Mesh:
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    return me


def _evaluated_mesh(obj) -> bpy.types.Mesh:
    dg = bpy.context.evaluated_depsgraph_get()
    ev = obj.evaluated_get(dg)
    me = bpy.data.meshes.new_from_object(ev)
    me.transform(obj.matrix_world)
    return me


def bake_object(obj) -> bpy.types.Mesh:
    """Applies modifiers / converts curve or text to a world-space mesh and deletes the object."""
    link(obj) if obj.name not in bpy.context.scene.collection.objects else None
    bpy.context.view_layer.update()
    me = _evaluated_mesh(obj)
    data = obj.data
    bpy.data.objects.remove(obj)
    if data and data.users == 0:
        if isinstance(data, bpy.types.Mesh):
            bpy.data.meshes.remove(data)
        elif isinstance(data, bpy.types.Curve):
            bpy.data.curves.remove(data)
    return me


# ---------------------------------------------------------------- primitives (world space)
def M(loc=(0, 0, 0), rot=(0, 0, 0), scale=(1, 1, 1)) -> Matrix:
    return (Matrix.Translation(Vector(loc))
            @ Matrix.Rotation(rot[2], 4, "Z") @ Matrix.Rotation(rot[1], 4, "Y") @ Matrix.Rotation(rot[0], 4, "X")
            @ Matrix.Diagonal(Vector((scale[0], scale[1], scale[2], 1.0))))


def sphere(pal, radius=1.0, mat=None, seg=16, rings=10, outline=True, smooth=True, name="sphere") -> Piece:
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=seg, v_segments=rings, radius=radius)
    if mat is not None:
        bmesh.ops.transform(bm, matrix=mat, verts=bm.verts)
    return Piece(_bm_to_mesh(bm, name), pal, outline, smooth, name)


def cylinder(pal, radius=1.0, depth=1.0, mat=None, seg=16, outline=True, smooth=True, cap=True, radius2=None, name="cyl") -> Piece:
    """Z-axis cylinder (or cone when radius2 is given) centred on the origin before `mat`."""
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=cap, cap_tris=False, segments=seg,
                          radius1=radius, radius2=radius if radius2 is None else radius2, depth=depth)
    if mat is not None:
        bmesh.ops.transform(bm, matrix=mat, verts=bm.verts)
    p = Piece(_bm_to_mesh(bm, name), pal, outline, smooth, name)
    if smooth:
        # keep the caps flat-looking: mark cap faces flat via a per-face smooth list
        p.flat_faces = [i for i, f in enumerate(p.mesh.polygons) if len(f.vertices) > 4]
    return p


def rounded_box(pal, size=(1, 1, 1), mat=None, bevel=0.15, segments=3, outline=True, name="box") -> Piece:
    """A box with rounded edges (bevel modifier) - the chunky toy look."""
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    bmesh.ops.scale(bm, vec=Vector(size), verts=bm.verts)
    me = _bm_to_mesh(bm, name)
    obj = bpy.data.objects.new(name, me)
    link(obj)
    if mat is not None:
        obj.matrix_world = mat
    mod = obj.modifiers.new("bevel", "BEVEL")
    mod.width = min(bevel, min(size) * 0.45)
    mod.segments = segments
    mod.limit_method = "NONE"
    mod.harden_normals = False
    return Piece(bake_object(obj), pal, outline, True, name)


def torus(pal, major=1.0, minor=0.25, mat=None, seg=24, mseg=10, outline=True, name="torus") -> Piece:
    bm = bmesh.new()
    verts = []
    for i in range(seg):
        a = i / seg * math.tau
        for j in range(mseg):
            b = j / mseg * math.tau
            r = major + minor * math.cos(b)
            verts.append(bm.verts.new((r * math.cos(a), r * math.sin(a), minor * math.sin(b))))
    for i in range(seg):
        for j in range(mseg):
            a = verts[i * mseg + j]
            b = verts[((i + 1) % seg) * mseg + j]
            c = verts[((i + 1) % seg) * mseg + (j + 1) % mseg]
            d = verts[i * mseg + (j + 1) % mseg]
            bm.faces.new((a, b, c, d))
    if mat is not None:
        bmesh.ops.transform(bm, matrix=mat, verts=bm.verts)
    return Piece(_bm_to_mesh(bm, name), pal, outline, True, name)


def tube(pal, points, radius=0.5, radii=None, mat=None, res=10, bevel_res=3, caps=True, outline=True, name="tube", face_pal=None) -> Piece:
    """A smooth bezier tube through `points` (world space). `radii` scales per point.
    `face_pal(center: Vector) -> int` colours faces by position (e.g. sock cuff/heel/toe)."""
    cu = bpy.data.curves.new(name, "CURVE")
    cu.dimensions = "3D"
    cu.resolution_u = res
    cu.bevel_depth = radius
    cu.bevel_resolution = bevel_res
    cu.use_fill_caps = caps
    sp = cu.splines.new("BEZIER")
    sp.bezier_points.add(len(points) - 1)
    for i, p in enumerate(points):
        bp = sp.bezier_points[i]
        bp.co = Vector(p)
        bp.handle_left_type = "AUTO"
        bp.handle_right_type = "AUTO"
        bp.radius = radii[i] if radii else 1.0
    obj = bpy.data.objects.new(name, cu)
    link(obj)
    if mat is not None:
        obj.matrix_world = mat
    me = bake_object(obj)
    if face_pal is not None:
        pals = [face_pal(Vector(f.center)) for f in me.polygons]
        return Piece(me, pals, outline, True, name)
    return Piece(me, pal, outline, True, name)


def text(pal, body, size=1.0, depth=0.1, mat=None, outline=False, name="text") -> Piece:
    cu = bpy.data.curves.new(name, "FONT")
    cu.body = body
    cu.size = size
    cu.extrude = depth
    cu.align_x = "CENTER"
    cu.align_y = "CENTER"
    cu.resolution_u = 4
    obj = bpy.data.objects.new(name, cu)
    link(obj)
    if mat is not None:
        obj.matrix_world = mat
    return Piece(bake_object(obj), pal, outline, False, name)


def recolor_by(piece: Piece, fn):
    """Re-colours a piece's faces with fn(center: Vector, current: int) -> int."""
    piece.face_pal = [fn(Vector(f.center), piece.face_pal[i]) for i, f in enumerate(piece.mesh.polygons)]
    return piece


# ---------------------------------------------------------------- finishing
def _merge(pieces_with_mode, name):
    """pieces_with_mode: [(Piece, inflate, flip)] -> one textured mesh object."""
    bm = bmesh.new()
    pal_layer = bm.faces.layers.int.new("pal")
    smooth_layer = bm.faces.layers.int.new("smooth")
    for p, inflate, flip in pieces_with_mode:
        tmp = bmesh.new()
        tmp.from_mesh(p.mesh)
        tmp.normal_update()
        if inflate:
            for v in tmp.verts:  # inflate along the vertex normal -> a slightly bigger shell
                v.co += v.normal * inflate
        if flip:
            bmesh.ops.reverse_faces(tmp, faces=tmp.faces)
        vmap = {v: bm.verts.new(v.co) for v in tmp.verts}
        flat = set(getattr(p, "flat_faces", None) or [])
        for i, f in enumerate(tmp.faces):
            try:
                nf = bm.faces.new([vmap[v] for v in f.verts])
            except ValueError:
                continue
            nf[pal_layer] = OUTLINE if flip else p.face_pal[i]
            nf[smooth_layer] = 0 if (flip or i in flat) else (1 if p.smooth else 0)
        tmp.free()
    uv_layer = bm.loops.layers.uv.new("UVMap")
    for f in bm.faces:
        u, v = swatch_uv(f[pal_layer])
        for loop in f.loops:
            loop[uv_layer].uv = (u, v)
        f.smooth = bool(f[smooth_layer])
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    obj = bpy.data.objects.new(name, me)
    link(obj)
    obj.data.materials.append(palette_material())
    return obj


def finish(pieces: list[Piece], name: str, outline_width=0.05, outline_only: list | None = None):
    """Merges pieces into the textured body `name` plus a separate `name_Outline` inverted hull.

    The outline is its own object so the game can turn CastShadow off on it - otherwise the
    shell would shadow the whole model (Roblox shadow maps don't respect back-face culling)."""
    body = _merge([(p, 0.0, False) for p in pieces], name)
    outline = _merge([(p, outline_width, True) for p in pieces + (outline_only or []) if p.outline], name + "_Outline")
    outline.visible_shadow = False  # preview renders behave like the game
    for p in pieces + (outline_only or []):
        if p.mesh.users == 0:
            bpy.data.meshes.remove(p.mesh)
    return body, outline


def marker(name: str, loc) -> bpy.types.Object:
    """A tiny hidden tetrahedron the game reads by name (see Factory/Map `_Base`, `_Unit`, `_Pin`)."""
    bm = bmesh.new()
    s = 0.04
    v = [bm.verts.new(Vector(loc) + Vector(o)) for o in ((s, s, s), (-s, -s, s), (-s, s, -s), (s, -s, -s))]
    for f in ((0, 1, 2), (0, 3, 1), (0, 2, 3), (1, 3, 2)):
        bm.faces.new([v[i] for i in f])
    me = _bm_to_mesh(bm, name)
    obj = bpy.data.objects.new(name, me)
    link(obj)
    obj.data.materials.append(palette_material())
    obj.hide_render = True
    return obj


def markers(name: str, pin=None) -> list:
    """`_Base` at the origin (floor centre / leg axis), `_Unit` 1 unit toward the FRONT (-Y), and
    optionally `_Pin` (where a sock hangs from the clothespin). The game uses Base->Unit for the
    import scale (1 unit = 1 stud) and to turn the model so its front faces +Z."""
    out = [marker(name + "_Base", (0, 0, 0)), marker(name + "_Unit", (0, -1, 0))]
    if pin is not None:
        out.append(marker(name + "_Pin", pin))
    return out


_PALETTE_MAT = None
_PALETTE_IMG = None


def set_palette_image(img):
    global _PALETTE_IMG, _PALETTE_MAT
    _PALETTE_IMG = img
    _PALETTE_MAT = None


def palette_material():
    global _PALETTE_MAT
    if _PALETTE_MAT is not None and _PALETTE_MAT.name in bpy.data.materials:
        return _PALETTE_MAT
    mat = bpy.data.materials.new("Palette")
    mat.use_backface_culling = True  # glTF doubleSided=false: the outline hull must be single-sided
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = nt.nodes.get("Principled BSDF")
    bsdf.inputs["Roughness"].default_value = 0.85
    if "Specular IOR Level" in bsdf.inputs:
        bsdf.inputs["Specular IOR Level"].default_value = 0.2
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = _PALETTE_IMG
    tex.interpolation = "Closest"
    nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    _PALETTE_MAT = mat
    return mat


def plain_object(pieces: list[Piece], name: str) -> bpy.types.Object:
    """Merges pieces WITHOUT texture/outline - for parts the game recolours (glow parts)."""
    bm = bmesh.new()
    for p in pieces:
        tmp = bmesh.new()
        tmp.from_mesh(p.mesh)
        vmap = {v: bm.verts.new(v.co) for v in tmp.verts}
        for f in tmp.faces:
            try:
                nf = bm.faces.new([vmap[v] for v in f.verts])
                nf.smooth = p.smooth
            except ValueError:
                pass
        tmp.free()
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    obj = bpy.data.objects.new(name, me)
    link(obj)
    return obj


def tri_count(obj) -> int:
    return sum(len(p.vertices) - 2 for p in obj.data.polygons)


def export_glb(objs: list, path: str):
    for o in bpy.context.scene.objects:
        o.select_set(False)
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLB", use_selection=True,
                              export_yup=True, export_apply=True, export_texcoords=True,
                              export_normals=True, export_materials="EXPORT",
                              export_image_format="AUTO")


# ---------------------------------------------------------------- preview render
def render_preview(objs: list, path: str, res=420, angle=-0.55, elev=0.28, samples=24):
    scn = bpy.context.scene
    bpy.context.view_layer.update()  # objects moved since they were built: refresh matrix_world
    scn.render.engine = "CYCLES"
    scn.cycles.samples = samples
    scn.cycles.use_denoising = False
    scn.render.resolution_x = res
    scn.render.resolution_y = res
    scn.render.film_transparent = False
    scn.view_settings.view_transform = "Standard"
    world = bpy.data.worlds.new("w") if not scn.world else scn.world
    scn.world = world
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs[0].default_value = (0.42, 0.40, 0.58, 1)
    world.node_tree.nodes["Background"].inputs[1].default_value = 0.9
    # frame the selection
    mins = Vector((1e9, 1e9, 1e9))
    maxs = Vector((-1e9, -1e9, -1e9))
    for o in objs:
        for v in o.data.vertices:
            w = o.matrix_world @ v.co
            mins = Vector((min(mins[i], w[i]) for i in range(3)))
            maxs = Vector((max(maxs[i], w[i]) for i in range(3)))
    center = (mins + maxs) / 2
    radius = (maxs - mins).length / 2
    cam_data = bpy.data.cameras.new("cam")
    cam_data.lens = 50
    cam = bpy.data.objects.new("cam", cam_data)
    link(cam)
    dist = radius / math.tan(cam_data.angle / 2) * 1.08
    direction = Vector((math.sin(angle) * math.cos(elev), -math.cos(angle) * math.cos(elev), math.sin(elev)))
    cam.location = center + direction * dist
    cam.rotation_euler = (center - cam.location).to_track_quat("-Z", "Y").to_euler()
    scn.camera = cam
    sun_data = bpy.data.lights.new("sun", "SUN")
    sun_data.energy = 3.2
    sun_data.color = (1.0, 0.92, 0.78)
    sun = bpy.data.objects.new("sun", sun_data)
    sun.rotation_euler = (math.radians(50), math.radians(10), math.radians(-35))
    link(sun)
    fill_data = bpy.data.lights.new("fill", "SUN")
    fill_data.energy = 1.0
    fill_data.color = (0.7, 0.72, 1.0)
    fill = bpy.data.objects.new("fill", fill_data)
    fill.rotation_euler = (math.radians(60), 0, math.radians(150))
    link(fill)
    # Cycles draws back faces; Roblox doesn't. Swap in a preview material that makes back faces
    # transparent so the inverted-hull outline renders the way it will in game.
    prev = _preview_material()
    saved = {}
    for o in objs:
        saved[o.name] = list(o.data.materials)
        o.data.materials.clear()
        o.data.materials.append(prev)
    scn.render.filepath = path
    if path.lower().endswith(".jpg"):
        scn.render.image_settings.file_format = "JPEG"
        scn.render.image_settings.quality = 88
    bpy.ops.render.render(write_still=True)
    for o in objs:
        o.data.materials.clear()
        for m in saved[o.name]:
            o.data.materials.append(m)
    for o in (cam, sun, fill):
        bpy.data.objects.remove(o)


def _preview_material():
    mat = bpy.data.materials.get("PalettePreview")
    if mat:
        return mat
    mat = bpy.data.materials.new("PalettePreview")
    mat.use_nodes = True
    nt = mat.node_tree
    out = nt.nodes.get("Material Output")
    bsdf = nt.nodes.get("Principled BSDF")
    bsdf.inputs["Roughness"].default_value = 0.85
    if "Specular IOR Level" in bsdf.inputs:
        bsdf.inputs["Specular IOR Level"].default_value = 0.2
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = _PALETTE_IMG
    tex.interpolation = "Closest"
    nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    geo = nt.nodes.new("ShaderNodeNewGeometry")
    transp = nt.nodes.new("ShaderNodeBsdfTransparent")
    mix = nt.nodes.new("ShaderNodeMixShader")
    nt.links.new(geo.outputs["Backfacing"], mix.inputs[0])
    nt.links.new(bsdf.outputs[0], mix.inputs[1])
    nt.links.new(transp.outputs[0], mix.inputs[2])
    nt.links.new(mix.outputs[0], out.inputs["Surface"])
    return mat
