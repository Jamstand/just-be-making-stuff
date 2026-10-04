"""
items/softener.py - the Softener Cloud's models and their golden versions (see items/__init__.py
for the conventions, items/defencekit.py for the shared helpers):

SoftenerBottle (ReplicatedStorage.ItemMeshes.SoftenerBottle): a pink fabric-softener spray bottle. A
plump bottle with a soft squarish cross-section (one loft of superellipse rings: a rounded foot, a
slight waist, sloping shoulders, a short neck), a screw collar with painted grip lines, a big lilac
trigger-sprayer head with its nozzle pointing FRONT (-Y), a chunky flat purple trigger under it, and
a cute label front and back: a smiling white cloud (the front one smiles) on a sky-blue patch with a
few sparkles. Painted on: white soap bubbles down both narrow sides, a glossy streak on the front
shoulder, a pink heart on both sides of the sprayer head. 1 unit = 1 stud: ~1.65 tall, ~0.9 wide.
Origin = floor centre; `_Grip` = the neck under the sprayer head (the fist round the neck, the
nozzle pointing forward out of it), `_Tip` = the nozzle's mouth (where the spray comes out).
SoftenerBottle_Gold: the same bottle in polished gold, a ruby-red trigger, gems round the collar, a
diamond on the sprayer head, an ivory label in a gold frame (the cloud wears a little crown), shine
bars and glitter.

The bottle's skeleton (`rig`): `Root` at the grip (unweighted); `Body` (child of Root, from the grip
straight up, local +Y = up, +Z = front, +X = model +X: the bottle, head, label - everything but the
trigger - rigidly; an extra bone the contract doesn't list: Root must stay unweighted, so the static
parts need a bone of their own; the game may leave it alone or wobble it for a squeeze); `Trigger` (child of Body) from the trigger's pivot under the sprayer's nose down the lever
(local +Z = front; turning it about its local -X, i.e. model +X, swings the lever back toward the
bottle: a pump, clean up to ~16 degrees, where it meets the bottle's shoulder). Each part is
weighted 100% to one bone.

SoftenerPuff (ReplicatedStorage.ItemMeshes.SoftenerPuff): one fluffy cloud puff, ~3 wide; the game
places several, scaled, to make the softener cloud (no skeleton: the game drifts and grows it). One
closed lumpy surface: every vertex of an icosphere is pushed out to a smooth union of a dozen round
lobes (seen from the middle), so the lumps blend with soft creases. The ink hull is a softer-creased
copy of the same heap (an exact copy's hull folds through the surface in the creases). Pastel pink on
top fading to lavender underneath, cut along normal iso-lines; painted on: a few freshness
sparkles. SoftenerPuff_Gold: the same puff in warm gold-cream fluff fading to apricot gold
underneath, covered in gold and white glitter stars (a cloud stays soft: it is fluff, not metal).
No grip; origin = the bottom centre.
"""
import math

import bmesh
from mathutils import Matrix, Vector

import items
import sockkit as K
from sockkit import M, hexcol
from items import defencekit as DK

BOTTLE = "SoftenerBottle"
PUFF = "SoftenerPuff"

MATERIALS = {"softener_bottle": "plastic", "softener_head": "plastic", "softener_trigger": "plastic",
             "softener_nozzle": "plastic", "softener_label": "paper", "softener_cloud": "paper",
             "softener_spark": "decal", "softener_puff": "fluff", "softener_bubble": "decal", "softener_gloss": "decal",
             "softener_heart": "decal", "softener_gold": "metal", "softener_gem": "glass", "softener_sparkle": "decal",
             "softener_gold_shine": "decal", "softener_gold_trigger": "plastic", "softener_gold_label": "paper",
             "softener_gold_puff": "fluff", "softener_gold_crown": "decal", "softener_puff_sparkle": "decal",
             "softener_gold_sparkle": "decal"}


def _palette(gold):
    """Registers the bottle's palette colours (called by build, never at import: see items/__init__.py)."""
    P = {"metal": gold}
    P["hole"] = hexcol("softener_nozzle_hole", "#3A2550")
    P["cloud"] = (hexcol("softener_cloud", "#FFFFFF"), hexcol("softener_cloud_shade", "#E3EEFC"))
    P["face"] = hexcol("softener_cloud_mouth", "#4A2E5E")      # "mouth" -> ink: eyes and smile stay crisp
    P["cheek"] = hexcol("softener_cloud_cheek", "#FFA8CC")
    P["spark"] = hexcol("softener_spark", "#FFE27A")
    P["gloss"] = hexcol("softener_gloss", "#FFF4FA")
    if not gold:
        P["bottle"] = (hexcol("softener_bottle_light", "#FFC4E0"), hexcol("softener_bottle", "#FF8DC3"),
                       hexcol("softener_bottle_dark", "#E35E9F"))
        P["head"] = (hexcol("softener_head_light", "#FBF7FF"), hexcol("softener_head", "#E4D9F7"),
                     hexcol("softener_head_dark", "#B9A9DE"))
        P["trigger"] = (hexcol("softener_trigger_light", "#C9A6FF"), hexcol("softener_trigger", "#A57BEB"),
                        hexcol("softener_trigger_dark", "#7C55C4"))
        P["label"] = (hexcol("softener_label", "#BDE7FF"), hexcol("softener_label_rim", "#FFFFFF"))
        P["bubble"] = hexcol("softener_bubble", "#FFFFFF")
        P["heart"] = hexcol("softener_heart", "#FF5FA8")
        P["collar_line"] = P["head"][2]
    else:
        G = DK.gold_colours("softener")
        P.update(G)
        P["bottle"] = P["head"] = G["gold"]
        P["trigger"] = (hexcol("softener_gold_trigger_light", "#FF8AA6"), hexcol("softener_gold_trigger", "#E8244E"),
                        hexcol("softener_gold_trigger_dark", "#A3123A"))
        P["label"] = (hexcol("softener_gold_label", "#FFF8E4"), G["gold"][2])
        P["crown"] = hexcol("softener_gold_crown", "#FFC83A")
        P["heart"] = G["ruby"][1]
        P["collar_line"] = G["gold"][3]
    return P


def _tone_fn(P, cols):
    """tone(normal) for a part: plastic tones by normal z, or (golden) polished metal."""
    if P["metal"] and len(cols) == 4:
        return lambda n: DK.metal_tone(cols, DK.metal_value(n))
    return lambda n: DK.tone(cols, n.z, CUTS)


OUTLINE_W = 0.04
CUTS = (-0.4, 0.62)
# bottle loft stations: (z, half width x, half depth y)
STATIONS = [(0.0, 0.3, 0.2), (0.035, 0.385, 0.262), (0.11, 0.418, 0.29), (0.42, 0.397, 0.276), (0.78, 0.413, 0.288),
            (0.9, 0.378, 0.266), (0.98, 0.27, 0.205), (1.03, 0.17, 0.16), (1.06, 0.14, 0.14), (1.09, 0.14, 0.14)]
SQ = 3.0                      # superellipse exponent of the cross-section
NECK_Z = 1.09
HEAD_Z = 1.35                 # sprayer head centre height
NOZZLE = Vector((0.0, -0.47, 1.39))
TRIGGER = [(0.0, -0.31, HEAD_Z - 0.08), (0.0, -0.375, HEAD_Z - 0.19), (0.0, -0.375, HEAD_Z - 0.31), (0.0, -0.335, HEAD_Z - 0.41)]
GRIP_B = Vector((0.0, 0.0, 1.02))
SCALE_B = 1.09                # the whole bottle (built ~1.5 tall) -> ~1.65


def _interp(z, col):
    st = STATIONS
    if z <= st[0][0]:
        return st[0][col]
    i = max(k for k in range(len(st) - 1) if st[k][0] <= z)
    i = min(i, len(st) - 2)
    a, b, c, d = (st[min(max(k, 0), len(st) - 1)][col] for k in (i - 1, i, i + 1, i + 2))
    t = (z - st[i][0]) / (st[i + 1][0] - st[i][0])
    return 0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t * t + (-a + 3 * b - 3 * c + d) * t ** 3)


def _sq(a):
    c, s = math.cos(a), math.sin(a)
    return math.copysign(abs(c) ** (2 / SQ), c), math.copysign(abs(s) ** (2 / SQ), s)


def _bottle(P, seg=28, rows=22):
    bm = bmesh.new()
    rings = []
    for i in range(rows + 1):
        z = NECK_Z * (i / rows)
        hx, hy = _interp(z, 1), _interp(z, 2)
        ring = []
        for j in range(seg):
            cx, cy = _sq(j / seg * math.tau)
            ring.append(bm.verts.new((cx * hx, cy * hy, z)))
        rings.append(ring)
    for i in range(rows):
        a, b = rings[i], rings[i + 1]
        for j in range(seg):
            k = (j + 1) % seg
            bm.faces.new((a[j], a[k], b[k], b[j]))
    bm.faces.new(rings[0][::-1])
    bm.faces.new(rings[-1])
    pc = DK.toned(bm, P["bottle"], CUTS, "bottle", metal=P["metal"])
    pc.flat_faces = [i for i, f in enumerate(pc.mesh.polygons) if len(f.vertices) > 4]
    return pc


def _cyl(P, cols, r, z0, z1, seg=18, name="cyl", r2=None, outline=True):
    pc = K.cylinder(cols[1], r, z1 - z0, M((0, 0, (z0 + z1) / 2)), seg=seg, radius2=r2, name=name, outline=outline)
    if P["metal"] and len(cols) == 4:
        tn = _tone_fn(P, cols)
        DK.recolor_normals(pc, lambda n, c: tn(n))
    else:
        K.recolor_by(pc, lambda c, cur: cols[0] if c.z > z1 - 1e-4 else cur)
    return pc


def _head(P):
    """The trigger sprayer (Body): the collar, the head (a chunky shroud, taller at the back, its nose
    reaching forward over the trigger), the nozzle. -> (pieces, trigger pieces)."""
    out = []
    H = P["head"]
    out.append(_cyl(P, H, 0.175, NECK_Z - 0.04, NECK_Z + 0.11, seg=22, name="collar"))
    for k in range(14):   # grip lines painted round the collar
        a = k / 14 * math.tau
        c = Vector((math.cos(a) * 0.175, math.sin(a) * 0.175, NECK_Z + 0.035))
        out.append(DK.flat_poly(P["collar_line"], [(-0.008, -0.06), (0.008, -0.06), (0.008, 0.06), (-0.008, 0.06)], c,
                                Vector((math.cos(a), math.sin(a), 0)), lift=0.003, name="collar_line"))
    out.append(_cyl(P, H, 0.13, NECK_Z + 0.1, NECK_Z + 0.18, seg=16, name="stem"))
    tn = _tone_fn(P, H)
    if P["metal"]:
        tone = (lambda n, c: tn(n))
    else:
        tone = (lambda n, c: H[0] if c.z > HEAD_Z + 0.11 else (H[2] if c.z < HEAD_Z - 0.11 else H[1]))
    shroud = K.rounded_box(H[1], (0.3, 0.54, 0.29), M((0, -0.08, HEAD_Z)), bevel=0.125, segments=3, name="head")
    out.append(DK.recolor_normals(shroud, tone))
    nose = K.rounded_box(H[1], (0.22, 0.18, 0.19), M((0, -0.355, NOZZLE.z), rot=(0.12, 0, 0)), bevel=0.08, segments=3,
                         name="head_nose")
    out.append(DK.recolor_normals(nose, (lambda n, c: tn(n)) if P["metal"] else
                                  (lambda n, c: H[0] if c.z > NOZZLE.z + 0.07 else H[1])))
    T = P["trigger"] if not P["metal"] else P["gold"]
    noz = K.rounded_box(T[1], (0.165, 0.065, 0.165), M((NOZZLE.x, NOZZLE.y + 0.032, NOZZLE.z)), bevel=0.045, segments=2,
                        name="softener_nozzle")
    tnz = _tone_fn(P, T)
    out.append(DK.recolor_normals(noz, (lambda n, c: tnz(n)) if P["metal"] else
                                  (lambda n, c: T[0] if c.z > NOZZLE.z + 0.055 else T[1])))
    out.append(K.cylinder(P["hole"], 0.032, 0.01, Matrix.Translation(NOZZLE) @ Matrix.Rotation(math.pi / 2, 4, "X"),
                          seg=10, outline=False, name="nozzle_hole"))
    if P["metal"]:
        out.append(DK.gem(P["diamond"], Vector((0, -0.02, HEAD_Z + 0.145)), Vector((0, 0, 1)), 0.075, 0.06, facets=8,
                          name="gem_diamond"))
        for k in range(6):         # gems round the collar
            a = k / 6 * math.tau + 0.26
            c = Vector((math.cos(a) * 0.178, math.sin(a) * 0.178, NECK_Z + 0.035))
            out.append(DK.gem(P[DK.GEM_ORDER[k % 5]], c, Vector((math.cos(a), math.sin(a), 0)), 0.032, 0.025, facets=5,
                              name="gem"))
    # the trigger: a chunky flat lever hanging under the nose, flared at the bottom
    trig = DK.toned(DK.sweep_bm(TRIGGER, 0.07, 0.052, side=(1, 0, 0), e=3.2, seg=10, res=8,
                                scale=lambda t: 1.0 + 0.22 * DK.smooth(0.55, 1.0, t)),
                    P["trigger"], CUTS, "trigger")
    return out, [trig]


def _cloud_poly(w, h, n=60):
    """A cartoon cloud outline (CCW): the boundary of a few overlapping circles, flat-ish bottom."""
    circles = [((-0.55, -0.1), 0.42), ((0.55, -0.12), 0.4), ((-0.15, 0.2), 0.5), ((0.3, 0.18), 0.42),
               ((0.0, -0.18), 0.45), ((-0.85, -0.22), 0.25), ((0.85, -0.24), 0.24)]
    out = []
    for i in range(n):
        a = i / n * math.tau
        u = Vector((math.cos(a), math.sin(a)))
        best = 0.0
        for (cx, cy), r in circles:
            c = Vector((cx, cy))
            b = u.dot(c)
            disc = r * r - (c - u * b).length_squared
            if disc >= 0:
                best = max(best, b + math.sqrt(disc))
        out.append((u.x * best * w, u.y * best * h))
    return out


def _labels(P, bvh):
    out = []
    for face in (-1, 1):            # front (-Y) and back (+Y)
        along = Vector((0, -face, 0))
        du = Vector((-face, 0, 0))
        dv = Vector((0, 0, 1))
        o = Vector((0, face * 0.1, 0.5))
        rect = DK.rounded_rect(0.3, 0.27, 0.11, n=5)
        out.append(DK.decal(bvh, DK.offset_poly(rect, 0.035), o, du, dv, along, 0.004, P["label"][1], "label_rim", step=0.08))
        out.append(DK.decal(bvh, rect, o, du, dv, along, 0.008, P["label"][0], "label", step=0.08))
        cloud = _cloud_poly(0.19, 0.17)
        oc = o + Vector((0, 0, -0.025))
        out.append(DK.decal(bvh, cloud, oc, du, dv, along, 0.012,
                            lambda q, n: P["cloud"][1] if q.y < -0.07 else P["cloud"][0], "cloud", step=0.04))
        if face < 0:   # the front cloud smiles: two eyes, a smile, pink cheeks
            for sx in (-1, 1):
                eye = [(sx * 0.062 + 0.018 * math.cos(a), 0.012 + 0.025 * math.sin(a)) for a in
                       (j / 10 * math.tau for j in range(10))]
                out.append(DK.decal(bvh, eye, oc, du, dv, along, 0.016, P["face"], "eye", step=0.05))
                ck = [(sx * 0.118 + 0.03 * math.cos(a), -0.04 + 0.018 * math.sin(a)) for a in
                      (j / 10 * math.tau for j in range(10))]
                out.append(DK.decal(bvh, ck, oc, du, dv, along, 0.015, P["cheek"], "cheek", step=0.05))
            smile = []
            for k in range(9):   # a thin crescent
                a = math.radians(200 + 140 * k / 8)
                smile.append((0.045 * math.cos(a), -0.022 + 0.034 * math.sin(a)))
            for k in range(9):
                a = math.radians(340 - 140 * k / 8)
                smile.append((0.038 * math.cos(a), -0.013 + 0.025 * math.sin(a)))
            out.append(DK.decal(bvh, smile, oc, du, dv, along, 0.016, P["face"], "smile", step=0.05))
            if P["metal"]:        # a little crown on the cloud
                crown = [(-0.07, 0.0), (0.07, 0.0), (0.085, 0.07), (0.04, 0.035), (0.0, 0.085), (-0.04, 0.035), (-0.085, 0.07)]
                out.append(DK.decal(bvh, crown, oc + Vector((0, 0, 0.115)), du, dv, along, 0.016, P["crown"], "crown",
                                    step=0.05))
        for (sx, sy, r) in ((-0.22, 0.17, 0.05), (0.23, 0.14, 0.04), (0.21, -0.18, 0.034)):   # sparkles
            star = []
            for k in range(8):
                a = k / 8 * math.tau + math.pi / 2
                rr = r if k % 2 == 0 else r * 0.32
                star.append((sx + rr * math.cos(a), sy + rr * math.sin(a)))
            out.append(DK.decal(bvh, star, o, du, dv, along, 0.012, P["spark"], "spark", step=0.05))
    return out


def _decor(P, bvh, hbvh):
    """Bubbles (or shine bars) down the narrow sides, the shoulder gloss, hearts on the sprayer head."""
    out = []
    for s in (-1, 1):
        along = Vector((-s, 0, 0))
        du, dv = Vector((0, s, 0)), Vector((0, 0, 1))
        if P["metal"]:
            out += DK.shine_bars(bvh, Vector((s * 0.4, 0.0, 0.5)), du, dv, along, (0.2, 0.34), P["shine"], step=0.05)
            for (y, z, r) in ((0.1, 0.82, 0.05), (-0.12, 0.2, 0.04)):
                hit = bvh.ray_cast(Vector((s * 2.0, y, z)), along)
                if hit[0] is not None:
                    out.append(DK.sparkle(P["sparkle"], hit[0], hit[1], r, spin=y))
        else:
            for (y, z, r) in ((0.02, 0.72, 0.075), (-0.08, 0.5, 0.05), (0.07, 0.36, 0.036), (-0.04, 0.22, 0.028)):
                o = Vector((s * 0.4, y, z))
                out.append(DK.decal(bvh, DK.circle(0, 0, r, 16), o, du, dv, along, 0.005, P["bubble"], "bubble", step=0.05))
                out.append(DK.decal(bvh, DK.circle(0, 0, r * 0.72, 16), o, du, dv, along, 0.008, P["bottle"][1],
                                    "bubble_hole", step=0.05))
                out.append(DK.decal(bvh, DK.circle(-r * 0.38, r * 0.4, r * 0.15, 8), o, du, dv, along, 0.011, P["bubble"],
                                    "bubble_glint", step=0.05))
        # a heart on each side of the sprayer head
        heart = []
        for k in range(24):
            t = k / 24 * math.tau
            heart.append((0.0055 * 16 * math.sin(t) ** 3,
                           0.0055 * (13 * math.cos(t) - 5 * math.cos(2 * t) - 2 * math.cos(3 * t) - math.cos(4 * t))))
        out.append(DK.decal(hbvh, heart, Vector((s * 0.15, -0.06, HEAD_Z + 0.01)), du, dv, along, 0.006, P["heart"], "heart",
                            step=0.03))
    # a glossy streak down the front-left shoulder
    streak = [(-0.025, -0.3), (0.025, -0.3), (0.035, 0.22), (0.0, 0.3), (-0.035, 0.22)]
    out.append(DK.decal(bvh, streak, Vector((-0.27, -0.2, 0.55)), Vector((0.3, -1, 0)).normalized(), Vector((0, 0, 1)),
                        Vector((0.55, 0.83, 0)).normalized(), 0.006, P["gloss"], "gloss", step=0.06))
    return out


def build_bottle(gold=False):
    name = BOTTLE + ("_Gold" if gold else "")
    P = _palette(gold)
    bottle = _bottle(P)
    bvh = DK.bvh_of([bottle])
    head, trig = _head(P)
    hbvh = DK.bvh_of([pc for pc in head if pc.name == "head"])
    p = DK.tag_all([bottle] + head + _labels(P, bvh) + _decor(P, bvh, hbvh), "Body") + DK.tag_all(trig, "Trigger")
    DK.transform(p, Matrix.Scale(SCALE_B, 4))
    body, outline = K.finish(p, name, outline_width=OUTLINE_W)
    DK.no_bounce(outline)
    tip = K.marker(name + "_Tip", (NOZZLE + Vector((0, -0.01, 0))) * SCALE_B)
    return [body, outline] + K.markers(name) + [items.grip(name, GRIP_B * SCALE_B), tip]


# ---------------------------------------------------------------- the puff
PUFF_C = Vector((0.0, 0.0, 0.85))   # rays start here
# (centre, radius): a wide, soft heap of lobes, the biggest in the middle
LOBES = [((0.0, 0.0, 0.95), 0.82), ((0.82, 0.12, 0.72), 0.62), ((-0.85, -0.05, 0.7), 0.6), ((0.25, -0.62, 0.72), 0.55),
         ((-0.35, 0.6, 0.78), 0.55), ((0.4, 0.05, 1.35), 0.55), ((-0.38, -0.12, 1.3), 0.5), ((1.2, -0.25, 0.55), 0.38),
         ((-1.2, 0.3, 0.55), 0.4), ((0.6, 0.62, 0.62), 0.42), ((-0.6, -0.6, 0.58), 0.42), ((0.05, 0.25, 1.62), 0.3)]
PUFF_CUTS = (-0.6, -0.15, 0.5)


def _puff_palette(gold):
    if not gold:
        return {"puff": (hexcol("softener_puff_light", "#FFDFF0"), hexcol("softener_puff", "#F8C2E2"),
                         hexcol("softener_puff_dark", "#DDB2EC"), hexcol("softener_puff_deep", "#BFA2E4")),
                "spark": hexcol("softener_puff_sparkle", "#FFFFFF"),
                "spark2": hexcol("softener_puff_sparkle_pink", "#FFE3F2")}
    return {"puff": (hexcol("softener_gold_puff_light", "#FFF1BE"), hexcol("softener_gold_puff", "#FFD160"),
                     hexcol("softener_gold_puff_dark", "#F2A93E"), hexcol("softener_gold_puff_deep", "#D9853A")),
            "spark": hexcol("softener_gold_sparkle", "#FFFFFF"),
            "spark2": hexcol("softener_gold_sparkle_amber", "#FF9F1C")}


def _puff_radius(u, k):
    """Distance from PUFF_C to the surface along u: a smooth max (sharpness k) of the lobes' far hits."""
    acc, vals = 0.0, []
    for c, r in LOBES:
        c = Vector(c) - PUFF_C
        b = u.dot(c)
        disc = r * r - (c - u * b).length_squared
        # far hit of the ray with the lobe; a ray that misses falls off smoothly instead of jumping
        vals.append(b + math.copysign(math.sqrt(abs(disc)), disc))
    m = max(vals)
    for v in vals:
        acc += math.exp(k * (v - m))
    return m + math.log(acc) / k


def _puff_point(u, k=9.0):
    p = PUFF_C + u * _puff_radius(u, k)
    if p.z < 0.12:   # a softly flattened underside
        p.z = 0.12 - (0.12 - p.z) * 0.5
    return p


def _puff(cols=None, k=9.0, hull=False):
    """The puff (k: how crisp the creases between lobes are). hull=True: the same heap with much
    softer creases, for the outline hull only (it stays a hair outside the puff in every crease, so
    inflating it never folds it through the surface there)."""
    bm = bmesh.new()
    bmesh.ops.create_icosphere(bm, subdivisions=5 if not hull else 4, radius=1.0)
    for v in bm.verts:
        v.co = _puff_point(v.co.normalized(), k)
    DK.outward(bm)
    if hull:
        return K.Piece(K._bm_to_mesh(bm, "puff_hull"), K.OUTLINE, True, True, "puff_hull")
    bm.normal_update()
    nz = {v: v.normal.z for v in bm.verts}
    DK.iso_cut(bm, nz, PUFF_CUTS)
    pal = [DK.tone(cols, sum(nz[v] for v in f.verts) / len(f.verts), PUFF_CUTS) for f in bm.faces]
    return K.Piece(K._bm_to_mesh(bm, "puff"), pal, False, True, "puff")


def _puff_decor(Q, bvh, gold):
    """Freshness sparkles (lots of gold and white glitter on the golden one)."""
    out = []
    spots = [(0.4, -0.3, 0.12), (-0.5, -0.4, 0.09), (0.1, 0.5, 0.08), (0.9, -0.5, 0.07), (-0.9, 0.1, 0.1),
             (-0.2, -0.8, 0.07)]
    if gold:
        spots += [(0.6, 0.4, 0.09), (-0.6, 0.6, 0.07), (1.1, 0.0, 0.08), (-1.1, -0.3, 0.06), (0.2, -0.1, 0.1),
                  (-0.3, 0.2, 0.06), (0.5, 0.8, 0.05), (-0.8, -0.8, 0.06)]
    for i, (x, y, r) in enumerate(spots):
        hit = bvh.ray_cast(Vector((x, y - 0.6, 4.0)), Vector((0, 0.15, -1)).normalized())
        if hit[0] is not None:
            out.append(DK.sparkle(Q["spark2"] if i % 3 == 2 else Q["spark"], hit[0], hit[1], r * (1.6 if gold else 1.3),
                                  spin=x * 3, lift=0.015))
    return out


def build_puff(gold=False):
    name = PUFF + ("_Gold" if gold else "")
    Q = _puff_palette(gold)
    puff, hull = _puff(Q["puff"]), _puff(k=4.6, hull=True)
    bvh = DK.bvh_of([puff])
    p = [puff] + _puff_decor(Q, bvh, gold)
    low = min(v.co.z for v in puff.mesh.vertices)   # rest the underside on z = 0
    DK.transform(p + [hull], Matrix.Translation((0, 0, -low)))
    body, outline = K.finish(p, name, outline_width=0.06, outline_only=[hull])
    DK.no_bounce(outline)
    return [body, outline] + K.markers(name)


BUILDERS = {BOTTLE: build_bottle, BOTTLE + "_Gold": lambda: build_bottle(True),
            PUFF: build_puff, PUFF + "_Gold": lambda: build_puff(True)}


# ---------------------------------------------------------------- skeleton (the bottle only)
def rig(name, objs):
    """`<Name>_Rig` for the bottle: Root (grip) + Body + Trigger (see the module doc). The puff has no
    skeleton (None)."""
    if not name.startswith(BOTTLE):
        return None
    s = SCALE_B
    t0, t1 = Vector(TRIGGER[0]) * s, Vector(TRIGGER[-1]) * s
    bones = [DK.Bone("Root", None, GRIP_B * s, GRIP_B * s + Vector((0, -0.3, 0)), deform=False),
             DK.Bone("Body", "Root", GRIP_B * s, GRIP_B * s + Vector((0, 0, 0.5))),
             DK.Bone("Trigger", "Body", t0, Vector((0, t0.y, t1.z)))]
    return DK.skin(name, objs, bones, {})


POSES = {
    "rest": {},
    "pump": {"Trigger": [((1, 0, 0), 16)]},
    "squeeze": {"Trigger": [((1, 0, 0), 16)], "Body": [((1, 0, 0), 8)]},
}
