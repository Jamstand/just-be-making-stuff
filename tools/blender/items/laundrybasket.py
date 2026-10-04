"""
items/laundrybasket.py - the LaundryBasket item (ReplicatedStorage.ItemMeshes.LaundryBasket, and its
max-level LaundryBasket_Gold): a big plastic laundry basket turned upside down over a hiding
player. See items/__init__.py for the conventions (and props/basket.py / props/hamper.py for the
wicker ones: this one is plastic).

One swept shell (a rounded-rectangle outline, tapering toward the top, swept along a profile: a fat
rolled lip on the floor, a solid band with a handle slot on each short side, six rows of big hole
slots, a solid top band with a moulded ridge and the rounded-over base on top). The holes sit in
staggered rows like a weave; each is a real pocket (dark sides and back) so it reads as a hole from
any angle. On the front and the back of the lower band a white label with an ink rim shows a little
blue sock and two printed lines; a toon highlight (a dash and a dot) sits on the top band, a few pale
scuffs mark the lip, and the base on top has a ring of round holes round a middle one; inside (seen
only under the lip) is a darker wall.
The ink outline is the hull of a hole-free copy of the shell (so holes never get ink inside them).

LaundryBasket_Gold: the same shape, skeleton and markers in polished gold (the bake paints it as
metal): a ring of faceted aqua gems round the top band, a white-gold label with a gem-studded crown
instead of the sock, twinkles and glitter flecks on the bands.

1 unit = 1 stud: ~4.5 wide (X; 4.8 over the lip), ~3.4 deep (Y), ~5.5 tall - big enough to hide a
player. Origin = the floor centre (the open side down); `_Grip` = the handle slot on the +X side (the
game scales it down and turns it for carrying).

The skeleton (`rig`): `Root` at the floor centre (unweighted), `Top` (child of Root) from half
height up to the top: the upper half. `Bottom` (child of Root, from the floor up to half height) only
holds the lip and the lower wall still: Root must stay unweighted, so the lower half needs a bone of
its own; the game never moves it. The walls hand over from Bottom to Top smoothly all the way from
the lip to the top band (nearly linearly), so sliding Top down along its axis squashes the basket
evenly and sliding it up stretches it (local +Y = up), turning it about its head leans the upper half
over as one soft bend. `POSES` holds preview.py's test poses.
"""
import math
import bmesh
from mathutils import Vector
import sockkit as K
from sockkit import hexcol
import items
from items import movekit
from props.slippers import _outward
from items.staticballoon import bvh_of, decal, no_bounce, offset_poly, tone

NAME = "LaundryBasket"

MATERIALS = {"laundrybasket_plastic": "plastic", "laundrybasket_inside": "plastic", "laundrybasket_hole": "ink",
             "laundrybasket_pocket": "plastic", "laundrybasket_label": "paper", "laundrybasket_sock": "print",
             "laundrybasket_scuff": "plastic", "laundrybasket_gloss": "decal",
             "laundrybasket_gold": "metal", "laundrybasket_gold_label": "paper", "laundrybasket_gold_gem": "glass",
             "laundrybasket_gold_shine": "decal", "laundrybasket_gold_glitter": "decal"}


def _colours(gold=False):
    """Registers this item's palette colours and returns them. Called by build(), not at import:
    build_all.py imports every item module before it builds the socks, so colours registered at
    import would take palette cells ahead of the socks' (items must come last, see items/__init__.py)."""
    if not gold:
        return dict(
            plastic=(hexcol("laundrybasket_plastic_light", "#8FE8F2"), hexcol("laundrybasket_plastic", "#45C6DF"),
                     hexcol("laundrybasket_plastic_dark", "#2C98BD"), hexcol("laundrybasket_plastic_deep", "#20729A")),
            pocket=(hexcol("laundrybasket_pocket", "#2580A8"), hexcol("laundrybasket_pocket_dark", "#1A5C84")),
            hole=hexcol("laundrybasket_hole", "#14324E"),
            inside=hexcol("laundrybasket_inside", "#1E6E93"),
            label=(hexcol("laundrybasket_label", "#FFFFFF"), hexcol("laundrybasket_label_shade", "#E4EEF4")),
            ink=hexcol("laundrybasket_label_ink", "#173A55"),
            art=(hexcol("laundrybasket_sock", "#4E8FE8"), hexcol("laundrybasket_sock_cuff", "#FF6F8E"),
                 hexcol("laundrybasket_sock_heel", "#2E64C2")),
            gloss=hexcol("laundrybasket_gloss", "#D8FBFF"),
            scuff=hexcol("laundrybasket_scuff", "#B7EDF6"))
    G = movekit.gold("laundrybasket")
    return dict(
        plastic=(G.light, G.base, G.dark, G.deep),
        pocket=(hexcol("laundrybasket_gold_pocket", "#B87418"), hexcol("laundrybasket_gold_pocket_dark", "#7E4A0C")),
        hole=hexcol("laundrybasket_gold_hole", "#3E2206"),
        inside=hexcol("laundrybasket_gold_inside", "#8E5410"),
        label=(hexcol("laundrybasket_gold_label", "#FFF8E0"), hexcol("laundrybasket_gold_label_shade", "#F3E2B4")),
        ink=hexcol("laundrybasket_gold_ink", "#5A3008"),
        art=(G.base, G.light, G.dark),
        gem=movekit.gem_colours("laundrybasket", "aqua", "#B6FBFF", "#2FD3E6", "#1489A8"),
        gloss=G.shine, scuff=G.light, glitter=G.glitter)


H = 5.5                          # height
A0, B0 = 2.25, 1.7               # half width / depth at the floor (the rim) ...
A1, B1 = 1.86, 1.38              # ... and at the top (the base)
RC = 0.62                        # corner radius
WALL = 0.14                      # wall thickness (the inside wall, under the lip)
DEPTH = 0.09                     # hole pocket depth
NH = 16                          # holes round each row
NU = NH * 4                      # columns round the basket: a hole is 3 columns, the bar between 1
ROW0, RIB, HOLE_H, ROWS = 1.15, 0.2, 0.4, 6
HANDLE = (0.56, 0.98, 0.62)      # handle slot: bottom, top, half width (y)
LIP = (-0.09, -0.15)             # the rolled lip bulges this far out (low, middle)
OUTLINE_W = 0.07
CUTS = (-0.5, -0.12, 0.6)
GOLD_CUTS = (-0.2, 0.22, 0.7)   # the golden walls: tones by facing the key light (deep / dark / base / lit)
LABEL_Z = 0.8                    # the label's centre height (on the lower band, front and back)


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


def _rows_top():
    return ROW0 + ROWS * (RIB + HOLE_H)


def _lip():
    """The rolled lip's profile (inset, z), from the floor up."""
    lo, mid = LIP
    return [(0.0, 0.0), (lo, 0.04), (mid, 0.15), (mid, 0.31), (lo, 0.42), (0.0, 0.47)]


def _top_band(z):
    """The solid top band from z (a moulded ridge round it) and the rounding over into the base."""
    return [(0.0, z, "top"), (0.0, z + 0.08, "top"), (-0.045, z + 0.13, "top"), (-0.045, z + 0.22, "top"),
            (0.0, z + 0.27, "top"), (0.0, H - 0.3, "top"), (0.04, H - 0.14, "top"), (0.11, H - 0.05, "top"),
            (0.2, H, "top")]


def _profile():
    """(inset, z, tag) up the outside: the rolled lip, the handle band, the hole rows, the top band,
    the rounding over into the base. Tags: 'lip', 'band', 'handle', 'rib', 'hole', 'top'."""
    pr = [(WALL, 0.0, "lip")] + [(i, z, "lip") for i, z in _lip()[:-1]]
    pr += [(0.0, 0.47, "band"), (0.0, HANDLE[0], "handle"), (0.0, HANDLE[1], "band")]
    z = ROW0
    for r in range(ROWS):
        pr.append((0.0, z, "rib"))
        pr.append((0.0, z + RIB, "hole"))
        z += RIB + HOLE_H
    pr += _top_band(z)
    return pr


def _is_hole(tag, row, j):
    if tag == "hole":
        return (j + (2 if row % 2 else 0)) % 4 != 3   # wide slots, every other row shifted half a slot
    if tag == "handle":
        p, _n = _at(j + 0.5, (HANDLE[0] + HANDLE[1]) / 2, 0.0)
        return abs(p.y) < HANDLE[2] and abs(p.x) > 1.0
    return False


def _shell(P, gold):
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
            pal.append(P["hole"])
        elif f[kind] == 1:
            # the sill (facing up) and the side facing the light are lit, the lintel and far side shaded
            pal.append(P["pocket"][0] if f.normal.z > 0.5 or f.normal.dot(Vector((-0.6, -0.6, 0.5))) > 0.45
                       else P["pocket"][1])
        elif gold and abs(f.normal.z) < 0.6:     # polished walls: lit toward the key light
            pal.append(tone(P["plastic"], f.normal.dot(movekit.KEY), GOLD_CUTS))
        else:
            pal.append(tone(P["plastic"], f.normal.z, CUTS))
    flat = [i for i, f in enumerate(bm.faces) if f[kind] != 0]
    pc = K.Piece(K._bm_to_mesh(bm, "basket"), pal, False, True, "basket")
    pc.flat_faces = flat
    return pc


def _heights(step=0.35):
    """Ring heights for the inside wall and the hull: the lip's, then every `step` up to the top
    band's ridge (enough rows that both bend with the shell)."""
    zs = [z for _i, z in _lip()]
    top = _rows_top() + 0.08
    n = max(1, int(math.ceil((top - zs[-1]) / step)))
    return zs + [zs[-1] + (top - zs[-1]) * k / n for k in range(1, n + 1)]


def _inside(P):
    """The inside wall and ceiling (only seen under the lip): a darker plastic, facing inward (half
    the outside's columns; rows every ~0.5 so it bends with the shell)."""
    bm = bmesh.new()
    rings = []
    cols = NU // 2
    zs = [0.0, 0.47] + [z for z in _heights(0.5) if z > 0.5] + [H - 0.3, H - WALL]
    for z in zs:
        rings.append([bm.verts.new(_at(j * 2, z, WALL)[0]) for j in range(cols)])
    for i in range(len(rings) - 1):
        for j in range(cols):
            k = (j + 1) % cols
            bm.faces.new((rings[i][j], rings[i + 1][j], rings[i + 1][k], rings[i][k]))
    cv = bm.verts.new((0.0, 0.0, H - WALL))
    for j in range(cols):
        bm.faces.new((rings[-1][j], cv, rings[-1][(j + 1) % cols]))
    _outward(bm)
    bmesh.ops.reverse_faces(bm, faces=bm.faces[:])   # it faces the hollow inside
    return K.Piece(K._bm_to_mesh(bm, "inside"), P["inside"], False, True, "inside")


def _envelope():
    """The hole-free outside (for the ink hull only), closed underneath."""
    cols = 64
    bm = bmesh.new()
    pr = _lip() + [(0.0, z) for z in _heights()[len(_lip()):]]
    pr += [(i, z) for i, z, _t in _top_band(_rows_top())[2:]]        # the ridge and the rounding
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


def _top_holes(P, bvh):
    """A ring of round holes round a middle one in the base (on top, upside down)."""
    out = []
    down = Vector((0, 0, -1))
    pts = [(1.12 * math.cos(a), 0.76 * math.sin(a)) for a in (k / 10 * math.tau for k in range(10))]
    pts += [(0.0, 0.0)]
    for (x, y) in pts:
        r = 0.2 if (x, y) == (0.0, 0.0) else 0.14
        out.append(decal(bvh, movekit.circle(r, 14), Vector((x, y, H)), Vector((1, 0, 0)), Vector((0, 1, 0)), down,
                         0.006, P["hole"], "hole", step=0.2))
    return out


def _rrect(w, h, r, n=4):
    """A 2D rounded rectangle (CCW), half sizes w x h, corner radius r."""
    out = []
    for cx, cy, a0 in ((w - r, -h + r, -math.pi / 2), (w - r, h - r, 0.0), (-w + r, h - r, math.pi / 2),
                       (-w + r, -h + r, math.pi)):
        out += [(cx + r * math.cos(a0 + math.pi / 2 * k / n), cy + r * math.sin(a0 + math.pi / 2 * k / n))
                for k in range(n + 1)]
    return out


SOCK = [(-0.13, 0.26), (0.09, 0.26), (0.09, -0.03), (0.2, -0.1), (0.25, -0.18), (0.2, -0.25), (0.06, -0.26),
        (-0.1, -0.2), (-0.13, -0.08)]          # a little sock (cuff up, toe right), CCW
CROWN = [(-0.24, -0.16), (0.24, -0.16), (0.29, 0.17), (0.12, 0.02), (0.0, 0.22), (-0.12, 0.02), (-0.29, 0.17)]


def _labels(P, bvh, gold):
    """A label on the front and the back of the lower band: white with an ink rim, a little sock and
    two printed lines (gold: a crown studded with gems)."""
    out = []
    for face in (-1, 1):
        along = Vector((0, -face, 0))
        du, dv = Vector((-face, 0, 0)), Vector((0, 0, 1))
        o = Vector((0, 0, LABEL_Z))
        plate = _rrect(0.72, 0.26, 0.09)
        out.append(decal(bvh, offset_poly(plate, 0.035, miter=1.5), o, du, dv, along, 0.006, P["ink"], "label_ink",
                         step=0.1))
        out.append(decal(bvh, plate, o, du, dv, along, 0.01, lambda q, n: P["label"][1] if q.y < -0.16 else
                         P["label"][0], "label", step=0.1))
        if gold:
            crown = [(x * 0.95 - 0.36, y * 0.95) for x, y in CROWN]
            out.append(decal(bvh, offset_poly(crown, 0.024, miter=1.6), o, du, dv, along, 0.013, P["ink"], "label_ink",
                             step=0.06))
            out.append(decal(bvh, crown, o, du, dv, along, 0.016, lambda q, n: P["art"][1] if q.y > 0.04 else
                             P["art"][0], "art", step=0.06))
            for gx in (-0.14, 0.0, 0.14):
                out.append(decal(bvh, movekit.circle(0.036, 8, gx - 0.36, -0.07), o, du, dv, along, 0.019, P["gem"][1],
                                 "gem", step=0.1))
        else:
            sock = [(x * 1.02 - 0.38, y * 0.86) for x, y in SOCK]
            out.append(decal(bvh, offset_poly(sock, 0.024, miter=1.6), o, du, dv, along, 0.013, P["ink"], "label_ink",
                             step=0.05))
            out.append(decal(bvh, sock, o, du, dv, along, 0.016, lambda q, n: P["art"][1] if q.y > 0.13 else
                             (P["art"][2] if q.x > -0.3 and q.y < -0.08 else P["art"][0]), "art", step=0.05))
        for x0, x1, y in ((-0.02, 0.5, 0.08), (-0.02, 0.32, -0.09)):     # two printed lines (the brand)
            out.append(decal(bvh, _rrect((x1 - x0) / 2, 0.045, 0.04, 2), o + dv * y + du * ((x0 + x1) / 2), du, dv,
                             along, 0.013, P["art"][0] if not gold else P["art"][2], "art", step=0.2))
    return out


def _sheen(P, bvh, gold):
    """A toon highlight on the top band, front-left; a few pale scuffs on the lip (gold:
    twinkles and glitter flecks on the bands instead of scuffs)."""
    out = []
    z = _rows_top() + 0.37
    for face in (-1, 1):
        along = Vector((0, -face, 0))
        du, dv = Vector((-face, 0, 0)), Vector((0, 0, 1))
        o = Vector((0, 0, z))
        if face < 0:     # a toon highlight on the front-left: a dash and a dot
            out.append(decal(bvh, _rrect(0.34, 0.035, 0.034, 3), o + du * -0.85, du, dv, along, 0.006, P["gloss"],
                             "gloss", step=0.2))
            out.append(decal(bvh, movekit.circle(0.036, 8, -0.38, 0.0), o, du, dv, along, 0.006, P["gloss"], "gloss",
                             step=0.2))
        if gold:
            for x, y, r in ((0.45, 0.0, 0.07), (-1.3, 0.0, 0.055), (1.25, 0.0, 0.05)):
                out.append(decal(bvh, movekit.sparkle(r, 0.25, x, y), o, du, dv, along, 0.008, P["gloss"], "shine",
                                 step=0.1))
            for x, y in movekit.dots(10, 2.0 + face, (-1.2, -0.04), (1.2, 0.04), 0.18):
                out.append(decal(bvh, movekit.circle(0.02, 6, x, y), o, du, dv, along, 0.008, P["glitter"], "glitter",
                                 step=0.2))
        else:
            for x, y, ang, ln in ((0.9, 0.22, 0.3, 0.16), (-0.75, 0.24, -0.2, 0.12), (0.1, 0.2, 0.1, 0.1)):
                c, s = math.cos(ang), math.sin(ang)
                sc = [(x + c * u - s * v, y + s * u + c * v) for u, v in
                      ((-ln, -0.008), (ln, -0.008), (ln, 0.008), (-ln, 0.008))]
                out.append(decal(bvh, sc, Vector((0, 0, 0.0)), du, dv, along, 0.006, P["scuff"], "scuff", step=1.0))
    return out


def _gems(P):
    """Gold only: a ring of faceted aqua gems round the top band's ridge."""
    out = []
    z = _rows_top() + 0.175
    for k in range(12):
        p, n = _at(NU * (k + 0.5) / 12, z, -0.045)
        out.append(movekit.gem(P["gem"], p, n, 0.11, up=(0, 0, 1), name="gem"))
    return out


def build(gold=False):
    name = NAME + ("_Gold" if gold else "")
    P = _colours(gold)
    shell = _shell(P, gold)
    bvh = bvh_of([shell])
    p = [shell, _inside(P)] + _top_holes(P, bvh) + _labels(P, bvh, gold) + _sheen(P, bvh, gold)
    if gold:
        p += _gems(P)
    body, outline = K.finish(p, name, outline_width=OUTLINE_W, outline_only=[_envelope()])
    no_bounce(outline)
    gz = (HANDLE[0] + HANDLE[1]) / 2
    grip, _n = _at(0, gz, DEPTH * 0.5)
    return [body, outline] + K.markers(name) + [items.grip(name, grip)]


BUILDERS = {NAME: build, NAME + "_Gold": lambda: build(True)}


# ---------------------------------------------------------------- skeleton
LO, HI = 0.47, H - 0.42          # Bottom alone below LO (the lip), Top alone above HI (the top band)


def _field(z):
    """Bottom -> Top up the wall: half linear, half smoothstep (an even squash, soft at both ends)."""
    t = max(0.0, min(1.0, (z - LO) / (HI - LO)))
    w = 0.5 * t + 0.5 * t * t * (3 - 2 * t)
    return {"Bottom": 1.0 - w, "Top": w}


def rig(name, objs):
    """`<Name>_Rig`: Root at the floor centre, Bottom (the lower half, held still), Top (the upper half)."""
    bones = {"Root": movekit.bone("Root", None, (0, 0, 0), (0, 0, 0.5), "root"),
             "Bottom": movekit.bone("Bottom", "Root", (0, 0, 0), (0, 0, H * 0.5), "bottom"),
             "Top": movekit.bone("Top", "Root", (0, 0, H * 0.5), (0, 0, H), "top")}
    return movekit.skin(name, objs, bones, lambda piece, tag, co: _field(co.z))


# test poses for preview.py --pose (rigging.apply_pose: world axes, degrees; "slide" = studs along the
# bone, here up)
POSES = {
    "rest": {},
    "squash": {"Top": [("slide", -1.1)]},
    "stretch": {"Top": [("slide", 0.8)]},
    "lean": {"Top": [((1, 0, 0), 12)]},
    "pounce": {"Top": [("slide", 0.5), ((0, 1, 0), -8)]},
}
