"""
items/laundrybasket.py - the LaundryBasket item (ReplicatedStorage.ItemMeshes.LaundryBasket): a big
plastic laundry basket turned upside down over a hiding player. See items/__init__.py for the
conventions (and props/basket.py / props/hamper.py for the wicker ones: this one is plastic).

One swept shell (a rounded-rectangle outline, tapering toward the top, swept along a profile: the
rolled lip on the floor, a solid band with a handle slot on each short side, eight rows of wide hole
slots, a solid band and the rounded-over base on top). The holes sit in staggered rows like a weave;
each is a real pocket (dark sides and back) so it reads as a hole from any angle. The base on top
has a ring of small round holes; inside (seen only under the lip) is a darker wall. The ink outline
is the hull of a hole-free copy of the shell (so holes never get ink inside them).

1 unit = 1 stud: ~4.5 wide (X; 4.7 over the lip), ~3.4 deep (Y), ~5.5 tall - big enough to hide a player. Origin =
the floor centre (the open side down); `_Grip` = the handle slot on the +X side (the game scales it
down and turns it for carrying).
"""
import math
import bmesh
from mathutils import Vector
import sockkit as K
from sockkit import hexcol
import items
from props.slippers import _outward
from items.staticballoon import bvh_of, decal, no_bounce, tone

NAME = "LaundryBasket"

MATERIALS = {"laundrybasket_plastic": "plastic", "laundrybasket_inside": "plastic", "laundrybasket_hole": "ink",
             "laundrybasket_pocket": "plastic"}


def _colours():
    """Registers this item's palette colours. Called by build(), not at import: build_all.py imports
    every item module before it builds the socks, so colours registered at import would take palette
    cells ahead of the socks' (items must come last, see items/__init__.py)."""
    global PLASTIC, POCKET, HOLE, INSIDE
    PLASTIC = (hexcol("laundrybasket_plastic_light", "#8FE8F2"), hexcol("laundrybasket_plastic", "#45C6DF"),
               hexcol("laundrybasket_plastic_dark", "#2C98BD"), hexcol("laundrybasket_plastic_deep", "#20729A"))
    POCKET = (hexcol("laundrybasket_pocket", "#2580A8"), hexcol("laundrybasket_pocket_dark", "#1A5C84"))
    HOLE = hexcol("laundrybasket_hole", "#14324E")
    INSIDE = hexcol("laundrybasket_inside", "#1E6E93")


H = 5.5                          # height
A0, B0 = 2.25, 1.7               # half width / depth at the floor (the rim) ...
A1, B1 = 1.86, 1.38              # ... and at the top (the base)
RC = 0.62                        # corner radius
WALL = 0.14                      # wall thickness (the inside wall, under the lip)
DEPTH = 0.075                    # hole pocket depth
NH = 22                          # holes round each row
NU = NH * 4                      # columns round the basket: a hole is 3 columns, the bar between 1
ROW0, RIB, HOLE_H, ROWS = 1.15, 0.19, 0.29, 8
HANDLE = (0.56, 0.98, 0.62)      # handle slot: bottom, top, half width (y)
OUTLINE_W = 0.07
CUTS = (-0.5, -0.12, 0.6)


def _ab(z):
    t = max(0.0, min(1.0, z / H))
    return A0 + (A1 - A0) * t, B0 + (B1 - B0) * t


def _perim(a, b, rc, s):
    """Point and outward normal on the rounded rectangle (half a x b, corner rc) at fraction s of its
    perimeter, from the middle of the +X side round toward +Y."""
    sx, sy = a - rc, b - rc
    segs = [("l", (a, 0.0), (a, sy)), ("c", (sx, sy), 0.0), ("l", (sx, b), (-sx, b)), ("c", (-sx, sy), math.pi / 2),
            ("l", (-a, sy), (-a, -sy)), ("c", (-sx, -sy), math.pi), ("l", (-sx, -b), (sx, -b)),
            ("c", (sx, -sy), 1.5 * math.pi), ("l", (a, -sy), (a, 0.0))]
    lens = [(Vector(e) - Vector(st)).length if k == "l" else rc * math.pi / 2 for k, st, e in segs]
    d = (s % 1.0) * sum(lens)
    for (k, st, e), ln in zip(segs, lens):
        if d <= ln + 1e-9:
            t = d / ln if ln > 0 else 0.0
            if k == "l":
                p = Vector(st).lerp(Vector(e), t)
                dirv = (Vector(e) - Vector(st)).normalized()
                n = Vector((dirv.y, -dirv.x))
            else:
                ang = e + t * math.pi / 2
                n = Vector((math.cos(ang), math.sin(ang)))
                p = Vector(st) + n * rc
            return p, n
        d -= ln
    return Vector((a, 0.0)), Vector((1.0, 0.0))


def _at(j, z, inset):
    """World point of column j at height z, moved `inset` inward (negative: outward)."""
    a, b = _ab(z)
    p, n = _perim(a, b, RC, j / NU)
    q = p - n * inset
    return Vector((q.x, q.y, z)), Vector((n.x, n.y, 0.0))


def _profile():
    """(inset, z, tag) up the outside: the rolled lip, the handle band, the hole rows, the top band,
    the rounding over into the base. Tags: 'lip', 'band', 'handle', 'rib', 'hole', 'top'."""
    pr = [(WALL, 0.0, "lip"), (0.0, 0.0, "lip"), (-0.07, 0.04, "lip"), (-0.11, 0.14, "lip"), (-0.11, 0.3, "lip"),
          (-0.07, 0.4, "lip"), (0.0, 0.45, "band"), (0.0, HANDLE[0], "handle"), (0.0, HANDLE[1], "band")]
    z = ROW0
    for r in range(ROWS):
        pr.append((0.0, z, "rib"))
        pr.append((0.0, z + RIB, "hole"))
        z += RIB + HOLE_H
    pr += [(0.0, z, "top"), (0.0, H - 0.3, "top"), (0.04, H - 0.14, "top"), (0.11, H - 0.05, "top"), (0.2, H, "top")]
    return pr


def _is_hole(tag, row, j):
    if tag == "hole":
        return (j + (2 if row % 2 else 0)) % 4 != 3   # wide slots, every other row shifted half a slot
    if tag == "handle":
        p, _n = _at(j + 0.5, (HANDLE[0] + HANDLE[1]) / 2, 0.0)
        return abs(p.y) < HANDLE[2] and abs(p.x) > 1.0
    return False


def _shell():
    pr = _profile()
    bm = bmesh.new()
    kind = bm.faces.layers.int.new("kind")   # 0 plastic, 1 pocket side, 2 pocket back
    grid = []
    for inset, z, _t in pr:
        grid.append([bm.verts.new(_at(j, z, inset)[0]) for j in range(NU)])
    row = -1
    holes = []
    for i in range(len(pr) - 1):
        tag = pr[i][2]
        if tag == "hole":
            row += 1
        for j in range(NU):
            k = (j + 1) % NU
            if _is_hole(tag, row, j):
                holes.append((i, j))
                continue
            bm.faces.new((grid[i][j], grid[i][k], grid[i + 1][k], grid[i + 1][j]))
    # pockets: each hole cell gets sides + a back, sunk DEPTH into the wall. Their verts are their own
    # (not the wall's), so the wall's smooth shading isn't bent round every hole's edge.
    open_cells = set(holes)
    for i, j in holes:
        k = (j + 1) % NU
        z0, z1 = pr[i][1], pr[i + 1][1]
        inner, rim = {}, {}
        for jj in (j, k):
            for ii, zz in ((i, z0), (i + 1, z1)):
                inner[ii, jj] = bm.verts.new(_at(jj, zz, DEPTH)[0])
                rim[ii, jj] = bm.verts.new(grid[ii][jj].co)
        back = bm.faces.new((inner[i, j], inner[i, k], inner[i + 1, k], inner[i + 1, j]))
        back[kind] = 2
        # a side wall wherever the neighbouring cell isn't part of the same opening
        sides = [((i, j), (i, k), (i - 1, j)), ((i + 1, k), (i + 1, j), (i + 1, j)),
                 ((i, k), (i + 1, k), (i, k)), ((i + 1, j), (i, j), (i, (j - 1) % NU))]
        for (a, b, nb) in sides:
            if nb in open_cells and nb != (i, j):
                continue
            f = bm.faces.new((rim[a], rim[b], inner[b], inner[a]))
            f[kind] = 1
    # the two cells of one hole share their middle column: weld their pocket verts (only those)
    pocket = [v for v in bm.verts if all(f[kind] != 0 for f in v.link_faces) and v.link_faces]
    bmesh.ops.remove_doubles(bm, verts=pocket, dist=1e-5)
    # on the flat sides a hole's three cells are coplanar: merge them (and drop the in-between verts)
    pf = [f for f in bm.faces if f[kind] != 0]
    pv = list({v for f in pf for v in f.verts})
    pe = list({e for f in pf for e in f.edges})
    bmesh.ops.dissolve_limit(bm, angle_limit=math.radians(0.5), use_dissolve_boundaries=False, verts=pv, edges=pe,
                             delimit={"NORMAL"})
    # the top: rings shrinking to the middle
    last = grid[-1]
    centre = Vector((0.0, 0.0, H))
    prev = last
    for s in (0.8, 0.55, 0.3):
        ring = [bm.verts.new(centre + (v.co - centre) * s) for v in last]
        for j in range(NU):
            k = (j + 1) % NU
            bm.faces.new((prev[j], prev[k], ring[k], ring[j]))
        prev = ring
    cv = bm.verts.new(centre)
    for j in range(NU):
        bm.faces.new((prev[j], prev[(j + 1) % NU], cv))
    _outward(bm)
    bm.normal_update()
    pal = []
    for f in bm.faces:
        if f[kind] == 2:
            pal.append(HOLE)
        elif f[kind] == 1:
            # the sill (facing up) and the side facing the light are lit, the lintel and far side shaded
            pal.append(POCKET[0] if f.normal.z > 0.5 or f.normal.dot(Vector((-0.6, -0.6, 0.5))) > 0.45 else POCKET[1])
        else:
            pal.append(tone(PLASTIC, f.normal.z, CUTS))
    flat = [i for i, f in enumerate(bm.faces) if f[kind] != 0]
    pc = K.Piece(K._bm_to_mesh(bm, "basket"), pal, False, True, "basket")
    pc.flat_faces = flat
    return pc


def _inside():
    """The inside wall and ceiling (only seen under the lip): a darker plastic, facing inward."""
    bm = bmesh.new()
    rings = []
    for z in (0.0, H * 0.5, H - WALL):
        rings.append([bm.verts.new(_at(j, z, WALL)[0]) for j in range(NU)])
    for i in range(len(rings) - 1):
        for j in range(NU):
            k = (j + 1) % NU
            bm.faces.new((rings[i][j], rings[i + 1][j], rings[i + 1][k], rings[i][k]))
    cv = bm.verts.new((0.0, 0.0, H - WALL))
    for j in range(NU):
        bm.faces.new((rings[-1][j], cv, rings[-1][(j + 1) % NU]))
    _outward(bm)
    bmesh.ops.reverse_faces(bm, faces=bm.faces[:])   # it faces the hollow inside
    return K.Piece(K._bm_to_mesh(bm, "inside"), INSIDE, False, True, "inside")


def _envelope():
    """The hole-free outside (for the ink hull only), closed underneath."""
    cols = 64
    bm = bmesh.new()
    pr = [(0.0, 0.0), (-0.07, 0.04), (-0.11, 0.14), (-0.11, 0.3), (-0.07, 0.4), (0.0, 0.45), (0.0, 2.0),
          (0.0, 4.0), (0.0, H - 0.3), (0.04, H - 0.14), (0.11, H - 0.05), (0.2, H)]
    rings = []
    for inset, z in pr:
        ring = []
        for j in range(cols):
            a, b = _ab(z)
            p, n = _perim(a, b, RC, j / cols)
            q = p - n * inset
            ring.append(bm.verts.new((q.x, q.y, z)))
        rings.append(ring)
    for i in range(len(rings) - 1):
        for j in range(cols):
            k = (j + 1) % cols
            bm.faces.new((rings[i][j], rings[i][k], rings[i + 1][k], rings[i + 1][j]))
    for ring, z, flip in ((rings[0], 0.0, True), (rings[-1], H, False)):   # caps wound like the side quads
        cv = bm.verts.new((0.0, 0.0, z))
        for j in range(cols):
            k = (j + 1) % cols
            bm.faces.new((ring[k], ring[j], cv) if flip else (ring[j], ring[k], cv))
    _outward(bm)
    return K.Piece(K._bm_to_mesh(bm, "envelope"), K.OUTLINE, True, True, "envelope")


def _top_holes(bvh):
    """A ring of small round holes in the base (on top, upside down)."""
    out = []
    down = Vector((0, 0, -1))
    pts = []
    for k in range(12):
        a = k / 12 * math.tau
        pts.append((1.15 * math.cos(a), 0.78 * math.sin(a)))
    pts += [(0.0, 0.0), (0.5, 0.0), (-0.5, 0.0)]
    for (x, y) in pts:
        circ = [(0.11 * math.cos(t), 0.11 * math.sin(t)) for t in (j / 12 * math.tau for j in range(12))]
        out.append(decal(bvh, circ, Vector((x, y, H)), Vector((1, 0, 0)), Vector((0, 1, 0)), down, 0.006, HOLE,
                         "hole", step=0.2))
    return out


def build():
    _colours()
    shell = _shell()
    bvh = bvh_of([shell])
    p = [shell, _inside()] + _top_holes(bvh)
    body, outline = K.finish(p, NAME, outline_width=OUTLINE_W, outline_only=[_envelope()])
    no_bounce(outline)
    gz = (HANDLE[0] + HANDLE[1]) / 2
    grip, _n = _at(0, gz, DEPTH * 0.5)
    return [body, outline] + K.markers(NAME) + [items.grip(NAME, grip)]


BUILDERS = {NAME: build}
