"""
Private helpers for the SkyShip and FrozenPeaks map kits (sky_ship.py,
frozen_peaks.py). Everything here works in arena space on a MeshBuilder piece
(mb.piece(...)) and only adds geometry through the builder's own primitives
or its _finish() step, so faces get palette colors like any other primitive.
"""

import math
import random

import bmesh
from mathutils import Matrix, Vector


# Generic meshes -------------------------------------------------------------


# Key light used to bake facet tones into the palette (arena space: from the
# upper left, in front). Baked tones read the same in the toon preview and
# under Roblox lighting.
LIGHT = Vector((-0.45, 0.75, 0.55)).normalized()


def _raw_mesh(p, verts, faces, color, smooth=False, clip=None):
    tmp = bmesh.new()
    vs = [tmp.verts.new(v) for v in verts]
    for f in faces:
        try:
            tmp.faces.new([vs[i] for i in f])
        except ValueError:
            pass  # duplicate / degenerate face
    loose = [v for v in tmp.verts if not v.link_faces]
    if loose:
        bmesh.ops.delete(tmp, geom=loose, context="VERTS")
    bmesh.ops.remove_doubles(tmp, verts=tmp.verts, dist=1e-5)
    ngons = [f for f in tmp.faces if len(f.verts) > 4]
    if ngons:
        bmesh.ops.triangulate(tmp, faces=ngons, quad_method="BEAUTY", ngon_method="EAR_CLIP")
    p._finish(tmp, color, (0, 0, 0), None, smooth, clip)


def shade_groups(verts, faces, shade):
    """Split faces by baked tone. shade = (light, mid, dark) palette keys, or
    ((light, mid, dark), (cut_light, cut_mid))."""
    if isinstance(shade[0], str):
        colors, cuts = shade, (0.62, 0.3)
    else:
        colors, cuts = shade
    vv = [Vector(v) for v in verts]
    centroid = sum(vv, Vector()) / max(len(vv), 1)
    groups = {}
    for f in faces:
        pts = [vv[i] for i in f]
        n = Vector((0.0, 0.0, 0.0))
        for a, b in zip(pts, pts[1:] + pts[:1]):
            n.x += (a.y - b.y) * (a.z + b.z)
            n.y += (a.z - b.z) * (a.x + b.x)
            n.z += (a.x - b.x) * (a.y + b.y)
        if n.length < 1e-9:
            col = colors[1]
        else:
            n.normalize()
            c = sum(pts, Vector()) / len(pts)
            if n.dot(c - centroid) < 0:
                n = -n
            t = n.dot(LIGHT)
            col = colors[0] if t > cuts[0] else colors[1] if t > cuts[1] else colors[2]
        groups.setdefault(col, []).append(f)
    return groups


def mesh(p, verts, faces, color, smooth=False, clip=None, shade=None):
    """Raw mesh from vertex positions and index faces (arena space). With
    `shade`, faces get light/mid/dark palette keys by their normal instead."""
    if shade:
        for col, fs in shade_groups(verts, faces, shade).items():
            _raw_mesh(p, verts, fs, col, smooth, clip)
    else:
        _raw_mesh(p, verts, faces, color, smooth, clip)


def loft_rings(p, rings, color, closed=True, caps=True, smooth=False, clip=None, shade=None):
    """Skin consecutive rings (lists of 3D points, all the same length)."""
    n = len(rings[0])
    verts = [v for r in rings for v in r]
    faces = []
    m = n if closed else n - 1
    for i in range(len(rings) - 1):
        a, b = i * n, (i + 1) * n
        for j in range(m):
            k = (j + 1) % n
            faces.append((a + j, a + k, b + k, b + j))
    if caps and closed:
        faces.append(tuple(reversed(range(n))))
        last = (len(rings) - 1) * n
        faces.append(tuple(last + j for j in range(n)))
    mesh(p, verts, faces, color, smooth, clip, shade)


def sweep(p, path, profile, color, up=(0, 1, 0), smooth=False, caps=True, shade=None):
    """Sweep a closed 2D cross-section [(side, up), ...] along a 3D path."""
    path = [Vector(q) for q in path]
    upv = Vector(up)
    rings = []
    for i, q in enumerate(path):
        a = path[max(i - 1, 0)]
        b = path[min(i + 1, len(path) - 1)]
        t = (b - a).normalized()
        s = t.cross(upv)
        if s.length < 1e-6:
            s = t.orthogonal()
        s.normalize()
        u = s.cross(t).normalized()
        rings.append([q + s * ps + u * pu for ps, pu in profile])
    loft_rings(p, rings, color, closed=True, caps=caps, smooth=smooth, shade=shade)


def rect(w_out, w_in, h_top, h_bot):
    """Rectangle cross-section for sweep(): side offsets and up offsets."""
    return [(w_out, h_top), (w_out, h_bot), (-w_in, h_bot), (-w_in, h_top)]


def shell(p, grid, thickness, color, smooth=True, normal=(0, 0, -1), shade=None):
    """Thin surface from a grid of points (rows x cols) given thickness, offset
    along `normal`. Used for sails, flags and waterfalls. With `shade`, the
    front faces (facing away from `normal`) get baked light/mid/dark tones."""
    nr, nc = len(grid), len(grid[0])
    nvec = Vector(normal)
    off = nvec * thickness
    verts = [Vector(v) for row in grid for v in row] + [Vector(v) + off for row in grid for v in row]
    back = nr * nc
    front_faces, other = [], []
    for r in range(nr - 1):
        for c in range(nc - 1):
            a, b, cc, d = r * nc + c, r * nc + c + 1, (r + 1) * nc + c + 1, (r + 1) * nc + c
            front_faces.append((a, b, cc, d))
            other.append((back + d, back + cc, back + b, back + a))
    border = ([c for c in range(nc)] + [r * nc + nc - 1 for r in range(1, nr)] +
              [(nr - 1) * nc + c for c in range(nc - 2, -1, -1)] + [r * nc for r in range(nr - 2, 0, -1)])
    for i in range(len(border)):
        a, b = border[i], border[(i + 1) % len(border)]
        other.append((b, a, back + a, back + b))
    if not shade:
        mesh(p, verts, front_faces + other, color, smooth)
        return
    colors, cuts = (shade, (0.62, 0.3)) if isinstance(shade[0], str) else shade
    groups = {colors[1]: list(other)}
    for f in front_faces:
        pts = [verts[i] for i in f]
        n = (pts[2] - pts[0]).cross(pts[3] - pts[1])
        if n.length < 1e-9:
            col = colors[1]
        else:
            n.normalize()
            if n.dot(-nvec) < 0:
                n = -n
            t = n.dot(LIGHT)
            col = colors[0] if t > cuts[0] else colors[1] if t > cuts[1] else colors[2]
        groups.setdefault(col, []).append(f)
    for col, fs in groups.items():
        _raw_mesh(p, verts, fs, col, smooth)


def along(a, b):
    """Rotation matrix turning local +Y toward b - a."""
    axis = (Vector(b) - Vector(a)).normalized()
    return Vector((0, 1, 0)).rotation_difference(axis).to_matrix()


def rod(p, a, b, radius, color, segments=6, radius_b=None, smooth=True):
    """Cylinder from point a to point b (no end spheres)."""
    a, b = Vector(a), Vector(b)
    p.cylinder((a + b) / 2, radius, (b - a).length, color, along(a, b), segments,
               radius_top=radius if radius_b is None else radius_b, smooth=smooth)


def rope(p, a, b, color, radius=0.12, sag=0.0, pieces=1):
    """Thin rope, optionally sagging in a few straight pieces."""
    a, b = Vector(a), Vector(b)
    pts = []
    for i in range(pieces + 1):
        t = i / pieces
        q = a.lerp(b, t)
        q.y -= sag * 4 * t * (1 - t)
        pts.append(q)
    for q0, q1 in zip(pts, pts[1:]):
        rod(p, q0, q1, radius, color, segments=5)


def catmull(table, key):
    """Catmull-Rom through [(key, value), ...] sorted by key; clamped ends."""
    if key <= table[0][0]:
        return table[0][1]
    if key >= table[-1][0]:
        return table[-1][1]
    for i in range(len(table) - 1):
        k1, v1 = table[i]
        k2, v2 = table[i + 1]
        if k1 <= key <= k2:
            k0, v0 = table[max(i - 1, 0)]
            k3, v3 = table[min(i + 2, len(table) - 1)]
            t = (key - k1) / (k2 - k1)
            m1 = (v2 - v0) / (k2 - k0) * (k2 - k1) if k2 != k0 else 0
            m2 = (v3 - v1) / (k3 - k1) * (k2 - k1) if k3 != k1 else 0
            t2, t3 = t * t, t * t * t
            return ((2 * t3 - 3 * t2 + 1) * v1 + (t3 - 2 * t2 + t) * m1 +
                    (-2 * t3 + 3 * t2) * v2 + (t3 - t2) * m2)
    return table[-1][1]


def lathe(p, center, profile, color, segments=8, jitter=0.0, rng=None, spin=0.0, depth=1.0, smooth=False,
          lean=(0.0, 0.0), shade=None):
    """Revolve [(dy, radius), ...] (top to bottom) about a vertical axis through
    center. A radius of 0 makes a point. `jitter` randomizes radii per spoke
    (shared by all rings, so facets stay coherent); `depth` squashes z; `lean`
    shifts each ring by (dx, dz) * (-dy) for bent spikes."""
    rng = rng or random.Random(1)
    cx, cy, cz = center
    spokes = [1.0 + rng.uniform(-jitter, jitter) for _ in range(segments)]
    verts, rings = [], []
    for dy, r in profile:
        ox, oz = lean[0] * -dy, lean[1] * -dy
        if r <= 1e-6:
            rings.append([len(verts)])
            verts.append((cx + ox, cy + dy, cz + oz))
            continue
        ring = []
        for k in range(segments):
            a = 2 * math.pi * k / segments + math.radians(spin)
            rr = r * spokes[k] * (1.0 + rng.uniform(-jitter, jitter) * 0.35)
            ring.append(len(verts))
            verts.append((cx + ox + math.cos(a) * rr, cy + dy, cz + oz + math.sin(a) * rr * depth))
        rings.append(ring)
    faces = []
    for r0, r1 in zip(rings, rings[1:]):
        if len(r0) == 1 and len(r1) == 1:
            continue
        if len(r0) == 1 or len(r1) == 1:
            tip, ring = (r0[0], r1) if len(r0) == 1 else (r1[0], r0)
            for k in range(len(ring)):
                faces.append((tip, ring[k], ring[(k + 1) % len(ring)]))
            continue
        for k in range(segments):
            j = (k + 1) % segments
            faces.append((r0[k], r0[j], r1[j], r1[k]))
    if len(rings[0]) > 2:
        faces.append(tuple(reversed(rings[0])))
    if len(rings[-1]) > 2:
        faces.append(tuple(rings[-1]))
    mesh(p, verts, faces, color, smooth, shade=shade)


# Set dressing ---------------------------------------------------------------


def cloud(p, center, size, color, rng, puffs=5, segments=10, rings=7, depth=0.75, flat=True):
    """Toon cloud: a row of puffs over a wide flat-bottomed base."""
    cx, cy, cz = center
    p.sphere((cx, cy, cz), (size * 1.7, size * 0.42, size * depth), color, segments=segments + 2, rings=rings)
    for i in range(puffs):
        t = (i + 0.5) / puffs - 0.5
        hump = 1 - abs(t) * 1.7
        r = size * (0.42 + 0.5 * hump) * rng.uniform(0.85, 1.12)
        x = cx + t * size * 2.7 + rng.uniform(-0.12, 0.12) * size
        y = cy + r * 0.45 + size * 0.05
        z = cz + rng.uniform(-0.25, 0.25) * size * depth
        p.sphere((x, y, z), (r * 1.05, r * 0.9, r * depth * 1.1), color, segments=segments, rings=rings)


def floating_island(p, center, size, colors, rng, tree=None, segments=9, spin=None, depth=0.8, shade=None):
    """Grass-topped (or snow-topped) floating rock: colors = (top, top_dark,
    rock, rock_dark). `tree` is a callback(p, base, scale) for a prop on top."""
    top, top_dark, rock, rock_dark = colors
    x, y, z = center
    s = size
    sp = rng.uniform(0, 40) if spin is None else spin
    jit = 0.12
    seed = rng.randrange(1 << 30)
    lathe(p, (x, y, z), [(0.09 * s, 0.46 * s), (0.0, 0.5 * s), (-0.07 * s, 0.47 * s)], top, segments, jit,
          random.Random(seed), sp, depth)
    lathe(p, (x, y, z), [(-0.06 * s, 0.475 * s), (-0.13 * s, 0.42 * s)], top_dark, segments, jit,
          random.Random(seed), sp, depth)
    lathe(p, (x, y, z), [(-0.1 * s, 0.44 * s), (-0.36 * s, 0.36 * s), (-0.62 * s, 0.2 * s), (-0.78 * s, 0.1 * s)],
          rock, segments, jit, random.Random(seed + 1), sp + 11, depth, shade=shade)
    lathe(p, (x + 0.03 * s, y, z), [(-0.74 * s, 0.13 * s), (-1.02 * s, 0.0)], rock_dark, max(5, segments - 3),
          0.15, random.Random(seed + 2), sp, depth, shade=shade)
    for k in range(3):
        a = math.radians(sp + 40 + k * 110 + rng.uniform(-20, 20))
        rx, rz = math.cos(a) * 0.3 * s, math.sin(a) * 0.3 * s * depth
        if rz > -0.1 * s:
            lathe(p, (x + rx, y - 0.3 * s, z + rz), [(0.0, 0.09 * s), (-0.25 * s, 0.0)], rock_dark, 5, 0.2,
                  random.Random(seed + 5 + k))
    if tree:
        tree(p, (x + rng.uniform(-0.18, 0.18) * s, y + 0.08 * s, z + rng.uniform(-0.1, 0.05) * s), s)


def round_tree(p, base, scale, trunk, leaves, leaves_dark, rng):
    x, y, z = base
    h = scale * 0.32
    p.cylinder((x, y + h / 2, z), scale * 0.045, h, trunk, segments=6, radius_top=scale * 0.03)
    for i in range(3):
        r = scale * (0.16 - i * 0.025)
        p.sphere((x + rng.uniform(-0.06, 0.06) * scale, y + h + i * scale * 0.09, z),
                 (r * 1.15, r, r), leaves if i else leaves_dark, segments=8, rings=6)


def pine(p, base, height, green, green_dark, snow, trunk, tiers=3, segments=7, snow_frac=0.45):
    """Snowy toon pine: stacked cones, each with a snow cap on its top half."""
    x, y, z = base
    w = height * 0.36
    p.cylinder((x, y + height * 0.06, z), w * 0.12, height * 0.14, trunk, segments=5, smooth=False)
    for i in range(tiers):
        f = i / max(tiers - 1, 1)
        r = w * (1.0 - 0.38 * f)
        h = height * (0.46 - 0.08 * f)
        cy = y + height * 0.1 + i * height * 0.24
        p.cone((x, cy + h / 2, z), r, h, green_dark if i % 2 == 0 else green, segments=segments,
               rotation=(0, i * 23, 0))
        sh = h * snow_frac
        p.cone((x, cy + h - sh / 2 + 0.02 * height, z), r * snow_frac * 1.08, sh, snow, segments=segments,
               rotation=(0, i * 23 + 9, 0))


def crystal(p, base, tip, radius, color, segments=6):
    """Pointed hexagonal crystal from base point toward tip."""
    a, b = Vector(base), Vector(tip)
    axis = b - a
    length = axis.length
    rot = along(a, b)
    body = length * 0.72
    p.cylinder(a + axis.normalized() * body / 2, radius, body, color, rot, segments, radius_top=radius * 0.92,
               smooth=False)
    p.cylinder(a + axis.normalized() * (body + (length - body) / 2), radius * 0.92, length - body, color, rot,
               segments, radius_top=0.0, smooth=False)


def crystal_cluster(p, base, size, color, rng, count=4, direction=(0, 1, 0), spread=35):
    d = Vector(direction).normalized()
    crystal(p, base, Vector(base) + d * size, size * 0.2, color)
    for i in range(count - 1):
        ang = math.radians(rng.uniform(-spread, spread))
        side = Vector((math.cos(i * 2.1), 0, math.sin(i * 2.1))) * 0.25
        dd = (Matrix.Rotation(ang, 3, "Z") @ d + side).normalized()
        s = size * rng.uniform(0.45, 0.75)
        off = Vector((rng.uniform(-0.25, 0.25) * size, 0, rng.uniform(-0.15, 0.15) * size))
        crystal(p, Vector(base) + off, Vector(base) + off + dd * s, s * 0.22, color)


def seeded(seed):
    return random.Random(seed)
