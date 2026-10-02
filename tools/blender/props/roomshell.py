"""
props/roomshell.py - the RoomShell prop (ReplicatedStorage.MapMeshes.RoomShell): the bedroom's
textured surfaces - floor, walls, trim, ceiling and the play rug - plus the glow-in-the-dark star
stickers on the ceiling. See props/__init__.py for the conventions every prop follows; this one
differs in two ways:

- It is built at 1 unit = 1 stud, exactly the size of Map.luau's room (LAYOUT FloorX 1100, FloorZ 900,
  WallHeight 400), and Map places it with a fit box of that exact size (a uniform scale of 1). Origin
  = the floor centre; Blender -Y = Roblox +Z (south), so the north wall (the bed's) is at y = +450.
- Its objects carry their own hand-painted textures (tools/blender/roomtex.py, embedded as JPEG)
  instead of the shared palette, with UVs past 0..1 so Roblox repeats them, and no ink outline.

Exported objects (every face points INTO the room - Roblox culls back faces):
- `RoomFloor`   1100 x 900 plane at height 0 (the top of Map's plank Parts); warm wood planks, one
                texture repeat = 160 studs = 4 boards of 40 (lined up with the old Part planks).
- `RoomWalls`   the inner faces of the four walls (flush with the wall Parts), 0..400 high; starry
                night wallpaper, one repeat = 100 studs, running on round the corners.
- `RoomTrim`    a 14-stud baseboard and a 10-stud crown moulding round the room, chunky rounded
                profiles with mitred corners; cream-painted wood, 40 studs per repeat along the trim.
- `RoomCeiling` plane at height 400 facing down; soft mottled plaster, one repeat = 220 studs.
- `PlayRug`     the 440 x 260 knitted checker (22 x 13 cells of 20 studs, cream / coral as Map's
                Part tiles) with a 4-stud dark-red bound border (448 x 268 overall); top at 0.4 like
                the Part tiles, the border's outer 1.2 studs roll down to the floor. Each cell and
                border piece samples its own slot of the PlayRug atlas.
- `CeilingStars` untextured: flat 5-point stars and crescent moons stuck to the ceiling (a few loose
                constellations, none within 125 studs of the ceiling fan); the game makes it a soft
                glow-in-the-dark Neon (Map.luau GLOW_PARTS.CeilingStars).
- Markers `RoomShell_Base` (floor centre) and `RoomShell_Unit`.
"""
import math
import random

import bpy
from mathutils import Vector

import roomtex as T
import sockkit as K

NAME = "RoomShell"
EXPORT_DIR = "map"

FX, FZ, H = 1100.0, 900.0, 400.0   # Map LAYOUT FloorX, FloorZ, WallHeight
HX, HY = FX / 2, FZ / 2
RUG_X, RUG_Z = 440, 260            # Map LAYOUT RugX, RugZ
RUG_TOP = 0.4                      # top of Map's rug tiles
STAR_Z = H - 0.3                   # star stickers: 0.3 thick, stuck to the ceiling
FAN_CLEAR = 125.0                  # keep the stickers out from under the ceiling fan (blade tips ~110)


# ---------------------------------------------------------------- mesh helpers
class _Builder:
    """Collects vertices, faces (each with a wanted normal) and per-corner UVs, then makes one object."""

    def __init__(self):
        self.verts = []
        self.faces = []
        self.uvs = []
        self.smooth = []

    def v(self, co):
        self.verts.append(tuple(co))
        return len(self.verts) - 1

    def face(self, idx, uvs, normal, smooth=False):
        """idx/uvs in any winding; flipped so the face's normal agrees with `normal`."""
        pts = [Vector(self.verts[i]) for i in idx]
        n = Vector((0.0, 0.0, 0.0))
        for k in range(len(pts)):  # Newell's method (robust for the odd degenerate corner)
            a, b = pts[k], pts[(k + 1) % len(pts)]
            n += Vector(((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y)))
        if n.dot(Vector(normal)) < 0:
            idx, uvs = idx[::-1], uvs[::-1]
        # drop repeated corners (a mitre's first ring is a triangle)
        out_i, out_uv = [], []
        for i, uv in zip(idx, uvs):
            if not out_i or Vector(self.verts[i]) != Vector(self.verts[out_i[-1]]):
                out_i.append(i)
                out_uv.append(uv)
        if len(out_i) > 2 and Vector(self.verts[out_i[0]]) == Vector(self.verts[out_i[-1]]):
            out_i.pop()
            out_uv.pop()
        if len(out_i) < 3:
            return
        self.faces.append(out_i)
        self.uvs.append(out_uv)
        self.smooth.append(smooth)

    def build(self, name, material=None, sharp_deg=None):
        me = bpy.data.meshes.new(name)
        me.from_pydata(self.verts, [], self.faces)
        uv = me.uv_layers.new(name="UVMap")
        for poly, fuv in zip(me.polygons, self.uvs):
            for li, t in zip(poly.loop_indices, fuv):
                uv.data[li].uv = t
        me.polygons.foreach_set("use_smooth", self.smooth)
        if sharp_deg is not None:
            me.set_sharp_from_angle(angle=math.radians(sharp_deg))
        me.validate()
        me.update()
        obj = bpy.data.objects.new(name, me)
        K.link(obj)
        if material is not None:
            obj.data.materials.append(material)
        return obj


def _material(name, img):
    """A plain textured material (what the glTF exporter and Roblox read): image -> base colour."""
    mat = bpy.data.materials.new(name)
    mat.use_backface_culling = True
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = nt.nodes.get("Principled BSDF")
    bsdf.inputs["Roughness"].default_value = 0.9
    if "Specular IOR Level" in bsdf.inputs:
        bsdf.inputs["Specular IOR Level"].default_value = 0.15
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = img
    tex.interpolation = "Linear"
    tex.extension = "REPEAT"
    nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    return mat


def _px_uv(x, row):
    """Atlas pixel (x right, row down from the top) -> Blender UV (v up)."""
    return (x / T.SIZE, 1.0 - row / T.SIZE)


# ---------------------------------------------------------------- floor, walls, ceiling
def _floor(mat):
    b = _Builder()
    t = T.FLOOR_TILE
    corners = [(-HX, -HY), (HX, -HY), (HX, HY), (-HX, HY)]
    idx = [b.v((x, y, 0.0)) for x, y in corners]
    # u from the west wall: board seams every 40 studs from x = -550, like Map's Part planks
    b.face(idx, [((x + HX) / t, (y + HY) / t) for x, y in corners], (0, 0, 1))
    return b.build("RoomFloor", mat)


# walls in the order the wallpaper runs (left to right as seen from inside the room):
# (start corner, end corner, inward normal), Blender XY
WALLS = [
    ((-HX, HY), (HX, HY), (0, -1)),    # north (Roblox z = -450): the bed and the window
    ((HX, HY), (HX, -HY), (-1, 0)),    # east
    ((HX, -HY), (-HX, -HY), (0, 1)),   # south: the door
    ((-HX, -HY), (-HX, HY), (1, 0)),   # west
]


def _walls(mat):
    b = _Builder()
    t = T.WALL_TILE
    p0 = 0.0  # perimeter position: the print runs on round the corners
    for (ax, ay), (bx, by), (nx, ny) in WALLS:
        length = math.hypot(bx - ax, by - ay)
        idx = [b.v((ax, ay, 0.0)), b.v((bx, by, 0.0)), b.v((bx, by, H)), b.v((ax, ay, H))]
        uvs = [(p0 / t, 0.0), ((p0 + length) / t, 0.0), ((p0 + length) / t, H / t), (p0 / t, H / t)]
        b.face(idx, uvs, (nx, ny, 0))
        p0 += length
    return b.build("RoomWalls", mat)


def _ceiling(mat):
    b = _Builder()
    t = T.CEIL_TILE
    corners = [(-HX, -HY), (HX, -HY), (HX, HY), (-HX, HY)]
    idx = [b.v((x, y, H)) for x, y in corners]
    b.face(idx, [((x + HX) / t, (y + HY) / t) for x, y in corners], (0, 0, -1))
    return b.build("RoomCeiling", mat)


# ---------------------------------------------------------------- trim (baseboard + crown, mitred corners)
def _profile_normals(prof):
    """Outward 2D normal (depth, height) per profile point: the profile runs with the solid on its
    left (floor -> wall for the baseboard, wall -> ceiling for the crown), so the outside is its right."""
    out = []
    for i in range(len(prof)):
        a = prof[max(i - 1, 0)]
        c = prof[min(i + 1, len(prof) - 1)]
        td, th = c[0] - a[0], c[1] - a[1]
        ln = math.hypot(td, th) or 1.0
        out.append((th / ln, -td / ln))
    return out


def _trim(mat):
    b = _Builder()
    t = T.TRIM_TILE
    for kind, prof in (("baseboard", T.baseboard_profile()), ("crown", T.crown_profile(H))):
        s = T.arclen(prof)
        r0, r1 = T.TRIM_BANDS[kind]
        rows = [r0 + si / s[-1] * (r1 - r0) for si in s]
        normals = _profile_normals(prof)
        p0 = 0.0
        for (ax, ay), (bx, by), (nx, ny) in WALLS:
            length = math.hypot(bx - ax, by - ay)
            dx, dy = (bx - ax) / length, (by - ay) / length  # along the wall (left to right from inside)
            starts, ends = [], []
            for d, h, _ in prof:
                # mitred inside corners: depth d starts d further along and stops d short
                sx, sy = ax + nx * d + dx * d, ay + ny * d + dy * d
                ex, ey = bx + nx * d - dx * d, by + ny * d - dy * d
                starts.append(b.v((sx, sy, h)))
                ends.append(b.v((ex, ey, h)))
            for i in range(len(prof) - 1):
                d0, d1 = prof[i][0], prof[i + 1][0]
                nd = (normals[i][0] + normals[i + 1][0]) / 2
                nh = (normals[i][1] + normals[i + 1][1]) / 2
                idx = [starts[i], ends[i], ends[i + 1], starts[i + 1]]
                uvs = [((p0 + d0) / t, 0), ((p0 + length - d0) / t, 0), ((p0 + length - d1) / t, 0), ((p0 + d1) / t, 0)]
                v0, v1 = 1.0 - rows[i] / T.SIZE, 1.0 - rows[i + 1] / T.SIZE
                uvs = [(uvs[0][0], v0), (uvs[1][0], v0), (uvs[2][0], v1), (uvs[3][0], v1)]
                b.face(idx, uvs, (nx * nd, ny * nd, nh), smooth=True)
            p0 += length
    return b.build("RoomTrim", mat, sharp_deg=38)


# ---------------------------------------------------------------- the play rug
def _rug_profile():
    """(depth past the checker, height) across the border: flat, then a quarter roll to the floor."""
    pts = [(0.0, RUG_TOP), (T.RUG_FLAT, RUG_TOP)]
    roll = T.RUG_BORDER - T.RUG_FLAT
    for k in range(1, 5):
        a = math.radians(90 * k / 4)
        pts.append((T.RUG_FLAT + roll * math.sin(a), RUG_TOP * math.cos(a)))
    return pts


def _rug(mat):
    b = _Builder()
    rng = random.Random(4)
    pps, pad, cell = T.RUG_PPS, T.RUG_PAD, T.RUG_CELL
    nx, nz = RUG_X // cell, RUG_Z // cell
    # Roblox (x, z) -> Blender (x, -z); cells numbered like Map's Part tiles (ix from the west,
    # iz from the north): (ix + iz) even = cream
    for ix in range(nx):
        for iz in range(nz):
            x0, z0 = -RUG_X / 2 + ix * cell, -RUG_Z / 2 + iz * cell
            cream = (ix + iz) % 2 == 0
            key = ("cream" if cream else "coral") + rng.choice("AB")
            sx, sy = T.RUG_CELLS[key]
            corners = [(0, 0), (cell, 0), (cell, cell), (0, cell)]  # (along x, along z) in the cell
            idx = [b.v((x0 + lx, -(z0 + lz), RUG_TOP)) for lx, lz in corners]
            uvs = [_px_uv(sx + pad + lx * pps, sy + pad + lz * pps) for lx, lz in corners]
            b.face(idx, uvs, (0, 0, 1))
    prof = _rug_profile()
    # this profile runs with the solid on its right (inner edge -> floor), so flip the normals
    normals = [(-nd, -nh) for nd, nh in _profile_normals([(d, h, "") for d, h in prof])]
    stx, sty = T.RUG_STRIP
    hx, hz = RUG_X / 2, RUG_Z / 2

    def strip(along_axis, sign, fixed, a0):
        """One 20-stud border piece: along_axis "x" (north/south sides) or "z" (east/west);
        sign = +1/-1 which side; fixed = the checker's edge; a0 = where the piece starts."""
        rows = []
        for d, h in prof:
            row = []
            for a in (0.0, float(cell)):
                if along_axis == "x":
                    rx, rz = a0 + a, sign * (fixed + d)
                else:
                    rx, rz = sign * (fixed + d), a0 + a
                row.append(b.v((rx, -rz, h)))
            rows.append(row)
        for j in range(len(prof) - 1):
            (d0, _), (d1, _) = prof[j], prof[j + 1]
            nd, nh = (normals[j][0] + normals[j + 1][0]) / 2, (normals[j][1] + normals[j + 1][1]) / 2
            out = (0, -sign * nd, nh) if along_axis == "x" else (sign * nd, 0, nh)
            idx = [rows[j][0], rows[j][1], rows[j + 1][1], rows[j + 1][0]]
            uvs = [_px_uv(stx + d0 * pps, sty), _px_uv(stx + d0 * pps, sty + cell * pps),
                   _px_uv(stx + d1 * pps, sty + cell * pps), _px_uv(stx + d1 * pps, sty)]
            b.face(idx, uvs, out, smooth=True)

    for ix in range(nx):
        for sign in (-1, 1):
            strip("x", sign, hz, -hx + ix * cell)
    for iz in range(nz):
        for sign in (-1, 1):
            strip("z", sign, hx, -hz + iz * cell)
    # mitred corners: dx/dz = depth past the checker's corner along each axis
    cx0, cy0 = T.RUG_CORNER
    for sx in (-1, 1):
        for sz in (-1, 1):
            def P(dx, dz, h):
                return b.v((sx * (hx + dx), -sz * (hz + dz), h))

            for j in range(len(prof) - 1):
                (d0, h0), (d1, h1) = prof[j], prof[j + 1]
                nd, nh = (normals[j][0] + normals[j + 1][0]) / 2, (normals[j][1] + normals[j + 1][1]) / 2
                # the half that continues the north/south side (depth dz), then the east/west half
                for half in ("z", "x"):
                    if half == "z":
                        pts = [(0, d0, h0), (d0, d0, h0), (d1, d1, h1), (0, d1, h1)]
                        out = (0, sz * -nd, nh)
                    else:
                        pts = [(d0, 0, h0), (d0, d0, h0), (d1, d1, h1), (d1, 0, h1)]
                        out = (sx * nd, 0, nh)
                    idx = [P(dx, dz, h) for dx, dz, h in pts]
                    uvs = [_px_uv(cx0 + dx * pps, cy0 + dz * pps) for dx, dz, _ in pts]
                    b.face(idx, uvs, out, smooth=True)
    return b.build("PlayRug", mat, sharp_deg=40)


# ---------------------------------------------------------------- glow-in-the-dark ceiling stickers
# Roblox (x, z) positions on the ceiling, diameter in studs. Loose constellations plus singles.
CONSTELLATIONS = [
    # the Big Dipper (north-east), bowl toward the corner
    [(470, -385, 14), (418, -350, 12), (360, -330, 12), (318, -282, 13), (262, -268, 11), (250, -205, 12), (318, -205, 10)],
    # Cassiopeia's W (south-west)
    [(-470, 330, 13), (-420, 268, 11), (-370, 318, 15), (-312, 255, 11), (-262, 300, 13)],
    # an Orion-ish hunter (north-west): shoulders, belt, feet
    [(-440, -360, 16), (-305, -372, 12), (-392, -268, 9), (-370, -258, 9), (-348, -248, 9), (-452, -165, 12), (-300, -170, 15)],
    # a little kite (south-east)
    [(330, 220, 12), (395, 262, 10), (352, 318, 13), (290, 286, 9), (430, 360, 8)],
]
SINGLES = [(-150, -330, 10), (40, -400, 8), (170, -260, 16), (480, -120, 9), (205, -140, 7), (-210, -170, 8),
           (-490, -40, 10), (-230, 60, 12), (-140, 205, 7), (-60, 390, 11), (90, 300, 9), (190, 175, 12),
           (480, 90, 11), (500, 400, 7), (-500, 420, 8), (-90, -220, 6), (120, 395, 18), (-480, 120, 7),
           (300, 30, 9), (-330, 120, 6)]
MOONS = [(150, -390, 20, 0.6), (-200, 380, 17, -2.2), (460, 210, 15, 2.6)]  # x, z, size, turn


def _star_outline(r, rf, rot):
    pts = []
    for k in range(10):
        a = rot + math.pi / 2 + k * math.pi / 5
        rr = r if k % 2 == 0 else r * rf
        pts.append((rr * math.cos(a), rr * math.sin(a)))
    return pts


def _crescent_outline(r, rot, n=10):
    """Crescent (disc r minus a disc 0.8 r shifted 0.45 r): (outer arc, inner arc) tip to tip."""
    o, rb = 0.45 * r, 0.8 * r
    xi = (r * r - rb * rb + o * o) / (2 * o)
    yi = math.sqrt(max(r * r - xi * xi, 0.0))
    a_tip = math.atan2(yi, xi)
    b_tip = math.atan2(yi, xi - o)
    outer = [(r * math.cos(a), r * math.sin(a)) for a in
             [a_tip + (2 * math.pi - 2 * a_tip) * k / n for k in range(n + 1)]]
    inner = [(o + rb * math.cos(a), rb * math.sin(a)) for a in
             [b_tip + (2 * math.pi - 2 * b_tip) * k / n for k in range(n + 1)]]
    c, s = math.cos(rot), math.sin(rot)
    turn = lambda p: (p[0] * c - p[1] * s, p[0] * s + p[1] * c)  # noqa: E731
    return [turn(p) for p in outer], [turn(p) for p in inner]


def _sticker_sides(b, cx, cy, pts, bottom):
    """Side walls of a sticker from its bottom outline (loop `pts`, vertex ids `bottom`) up to the
    ceiling, facing outward whichever way the outline runs."""
    area = sum(pts[k][0] * pts[(k + 1) % len(pts)][1] - pts[(k + 1) % len(pts)][0] * pts[k][1] for k in range(len(pts)))
    top = [b.v((cx + x, cy + y, H)) for x, y in pts]
    n = len(pts)
    for k in range(n):
        ex, ey = pts[(k + 1) % n][0] - pts[k][0], pts[(k + 1) % n][1] - pts[k][1]
        out = (ey, -ex, 0) if area > 0 else (-ey, ex, 0)
        b.face([bottom[k], bottom[(k + 1) % n], top[(k + 1) % n], top[k]], [(0, 0)] * 4, out)


def _star_sticker(b, cx, cy, pts):
    centre = b.v((cx, cy, STAR_Z))
    ring = [b.v((cx + x, cy + y, STAR_Z)) for x, y in pts]
    for k in range(len(pts)):
        b.face([centre, ring[k], ring[(k + 1) % len(pts)]], [(0, 0)] * 3, (0, 0, -1))
    _sticker_sides(b, cx, cy, pts, ring)


def _moon_sticker(b, cx, cy, outer, inner):
    """Crescent: a ribbon between the outer and inner arcs (they share the two tips)."""
    n = len(outer) - 1
    o = [b.v((cx + x, cy + y, STAR_Z)) for x, y in outer]
    i = [o[0]] + [b.v((cx + x, cy + y, STAR_Z)) for x, y in inner[1:-1]] + [o[n]]
    for k in range(n):
        b.face([o[k], o[k + 1], i[k + 1], i[k]], [(0, 0)] * 4, (0, 0, -1))
    loop_pts = outer + inner[1:-1][::-1]
    loop_ids = o + i[1:-1][::-1]
    _sticker_sides(b, cx, cy, loop_pts, loop_ids)


def _stars():
    b = _Builder()
    rng = random.Random(21)
    for x, z, size in [s for c in CONSTELLATIONS for s in c] + SINGLES:
        assert math.hypot(x, z) >= FAN_CLEAR and abs(x) <= HX - 30 and abs(z) <= HY - 30, (x, z)
        r = size / 2
        _star_sticker(b, x, -z, _star_outline(r, 0.46, rng.uniform(0, math.tau)))
    for x, z, size, rot in MOONS:
        assert math.hypot(x, z) >= FAN_CLEAR, (x, z)
        _moon_sticker(b, x, -z, *_crescent_outline(size / 2, rot))
    return b.build("CeilingStars")


# ---------------------------------------------------------------- build
def build(tex_dir=None):
    paths = T.texture_paths(tex_dir or T.OUT_DIR)
    imgs = {n: bpy.data.images.load(p, check_existing=True) for n, p in paths.items()}
    mats = {n: _material(n, img) for n, img in imgs.items()}
    objs = [
        _floor(mats["RoomFloor"]),
        _walls(mats["RoomWalls"]),
        _trim(mats["RoomTrim"]),
        _ceiling(mats["RoomCeiling"]),
        _rug(mats["PlayRug"]),
    ]
    for o in objs:
        o["paint_image"] = imgs[o.name].name  # K.render_preview shows an object's own image by this
    return objs + [_stars()] + K.markers(NAME)

