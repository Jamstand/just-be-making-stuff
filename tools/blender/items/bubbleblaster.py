"""
items/bubbleblaster.py - the BubbleBlaster item (ReplicatedStorage.ItemMeshes.BubbleBlaster) and its
golden version BubbleBlaster_Gold: a chunky toy bubble gun in bright plastic. See items/__init__.py
for the conventions, items/defencekit.py for the shared helpers.

A boxy sky-blue body (one superellipsoid block with flat sides and soft corners, no round barrel)
with a yellow waist band, a yellow squarish muzzle block and a short round pink nozzle collar at the
FRONT (-Y), two flat yellow wings swept back low on its sides (squared tips with a pink stripe, a
pink chevron on top: seen from above the blaster is a wide, angular toy shape, never a long rounded
capsule - the moderation rule in items/__init__.py), a big pink bubble-wand ring in front of it on
three flat spokes (eight little bumps round its front face), a yellow end cap on the back with a
pink dial, a fat see-through soap tank on top in a yellow socket (purple soap in its lower half, a
liquid line, bubbles and a glassy highlight, a ribbed yellow screw cap), a chunky yellow pistol
handle raked back (finger ribs, pink grip pads on both sides, a foot pad), a chunky flat trigger
inside a flat trigger guard. Painted on: white bubble stickers and a yellow star on both sides, a
glossy highlight streak along the top, rivets on the band. Tones are cut along the surface normal;
the bake paints the glossy plastic.

The golden one: the same blaster in polished gold, the waist band and grip pads ruby red, a gem on
each of the ring's bumps, a big sapphire for the dial, a diamond on the tank's cap, magenta soap
with glitter, a gem-centred star badge, a gem on each wing, diagonal shine bars and glitter
sparkles.

1 unit = 1 stud: ~1.9 long, ~1.9 tall (handle foot to tank cap), ~1.45 wide across the wings. Origin
= the floor under it (the handle's foot rests on z = 0); `_Grip` = the middle of the handle (the
fist; the body points forward out of it), `_Tip` = the centre of the wand ring (where the bubble
comes out).

The skeleton (`rig`): `Root` at the grip (unweighted); `Body` (child of Root, from the grip straight
up, local +Y = up, +Z = front, +X = model +X: the whole shell, wings, handle and stickers ride it
rigidly - an extra bone the contract doesn't list: Root must stay unweighted, so the static parts
need a bone of their own; the game may leave it alone, or kick it about its local X for recoil);
`Trigger` (child of Body) from the trigger's pivot under the body down the lever (local +Z = front:
turning it about its local -X swings the lever back toward the handle, a pull); `Ring` (child of
Body) from the wand ring's centre forward along the shot (local +Y = forward -Y, local +Z = up:
spinning it about its own Y spins the ring, about X / Z wobbles it; the spokes and bumps ride it);
`Tank` (child of Body) from the tank's floor up through its cap (local +Z = front: small turns about
X / Z slosh it). Every part is weighted 100% to one bone (rigid). `POSES` holds preview.py's test
poses.
"""
import math

import bmesh
from mathutils import Matrix, Vector

import items
import sockkit as K
from sockkit import M, hexcol
from items import defencekit as DK

NAME = "BubbleBlaster"

MATERIALS = {"bubbleblaster_body": "plastic", "bubbleblaster_accent": "plastic", "bubbleblaster_ring": "plastic",
             "bubbleblaster_tank": "glass", "bubbleblaster_soap": "glass", "bubbleblaster_sticker": "decal",
             "bubbleblaster_rib": "plastic", "bubbleblaster_pad": "rubber", "bubbleblaster_gloss": "decal",
             "bubbleblaster_star": "decal", "bubbleblaster_rivet": "metal", "bubbleblaster_dial": "plastic",
             "bubbleblaster_gold": "metal", "bubbleblaster_gem": "glass", "bubbleblaster_sparkle": "decal",
             "bubbleblaster_gold_shine": "decal", "bubbleblaster_gold_soap": "glass", "bubbleblaster_gold_pad": "rubber",
             "bubbleblaster_gold_band": "plastic"}


def _palette(gold):
    """Registers this item's palette colours (called by build(), never at import: see
    items/__init__.py) -> {part: colour or tones}; "metal" = True: hard parts get gold metal banding."""
    P = {"metal": gold}
    if not gold:
        P["body"] = (hexcol("bubbleblaster_body_light", "#86E3FF"), hexcol("bubbleblaster_body", "#35B6EE"),
                     hexcol("bubbleblaster_body_dark", "#1F7FC4"))
        P["accent"] = (hexcol("bubbleblaster_accent_light", "#FFE56B"), hexcol("bubbleblaster_accent", "#FFC22E"),
                       hexcol("bubbleblaster_accent_dark", "#E3891A"))
        P["ring"] = (hexcol("bubbleblaster_ring_light", "#FF9DCD"), hexcol("bubbleblaster_ring", "#FF5AA5"),
                     hexcol("bubbleblaster_ring_dark", "#CF3881"))
        P["band"] = P["accent"]
        P["pad"] = (hexcol("bubbleblaster_pad", "#FF6FB1"), hexcol("bubbleblaster_pad_dot", "#FFD3E8"))
        P["sticker"] = hexcol("bubbleblaster_sticker", "#FFFFFF")
        P["star"] = hexcol("bubbleblaster_star", "#FFD84A")
        P["rivet"] = hexcol("bubbleblaster_rivet", "#1A5E9E")
        P["dial"] = P["ring"]
        P["soap"] = (hexcol("bubbleblaster_soap_light", "#E3B2FF"), hexcol("bubbleblaster_soap", "#B978EE"),
                     hexcol("bubbleblaster_soap_dark", "#8C4FCB"))
    else:
        G = DK.gold_colours("bubbleblaster")
        P.update(G)
        P["body"] = P["accent"] = P["ring"] = G["gold"]
        P["band"] = (hexcol("bubbleblaster_gold_band_light", "#FF8AA6"), hexcol("bubbleblaster_gold_band", "#E8244E"),
                     hexcol("bubbleblaster_gold_band_dark", "#A3123A"))
        P["pad"] = (hexcol("bubbleblaster_gold_pad", "#E8244E"), hexcol("bubbleblaster_gold_pad_dot", "#FFE27A"))
        P["sticker"] = G["glitter"]
        P["star"] = G["gold"][0]
        P["rivet"] = G["diamond"][0]
        P["dial"] = G["gold"]
        P["soap"] = (hexcol("bubbleblaster_gold_soap_light", "#FFB8EC"), hexcol("bubbleblaster_gold_soap", "#F25BD0"),
                     hexcol("bubbleblaster_gold_soap_dark", "#B02E9C"))
    P["tank"] = (hexcol("bubbleblaster_tank_light", "#EEFBFF"), hexcol("bubbleblaster_tank", "#C2EEFF"),
                 hexcol("bubbleblaster_tank_dark", "#90CDEA"))
    P["hole"] = hexcol("bubbleblaster_hole", "#24304E")
    P["gloss"] = hexcol("bubbleblaster_gloss", "#FFFFFF")
    return P


OUTLINE_W = 0.04
CUTS = (-0.4, 0.62)            # normal z: shade / base / lit
AXIS_Z = 1.02                  # the body's centre height (before standing the foot on the floor)
BODY_C = Vector((0.0, 0.06, AXIS_Z))
BODY_S = (0.3, 0.6, 0.29)      # the body's half sizes
RING_Y = -1.0                  # wand ring centre (y)
RING_R, RING_T = 0.4, 0.085    # wand ring radius, tube radius
TANK_Y, TANK_R, TANK_H = 0.12, 0.22, 0.42
# the side wings' plan outline (x, y) for the right wing (the left is its mirror): root at the body's
# side, swept back to a squared tip; their mid height, half thickness and droop toward the tip
WING = [(0.26, -0.38), (0.72, 0.1), (0.72, 0.46), (0.26, 0.62)]
WING_Z, WING_T, WING_DROP = AXIS_Z - 0.18, 0.036, 0.05
HANDLE_Y, HANDLE_RAKE, HANDLE_L = 0.37, 0.27, 0.94   # handle top (y at the body), backward lean (rad), length
TRIGGER = [(0.0, 0.07, AXIS_Z - 0.24), (0.0, 0.01, AXIS_Z - 0.36), (0.0, 0.03, AXIS_Z - 0.47), (0.0, 0.09, AXIS_Z - 0.52)]
GRIP = Vector((0.0, 0.47, 0.5))
TIP = Vector((0.0, RING_Y, AXIS_Z))
SHIFT = {}                     # name -> how far the build lifted everything (the foot onto z = 0)


def _metal(P, cols):
    """True for a golden part (four gold tones: drawn with polished metal banding)."""
    return P["metal"] and len(cols) == 4


def _box(P, part, size, mat, name, e=3.2, seg=24, rows=10, bulge=0.0, outline=True):
    cols = P[part]
    return DK.superbox(cols, size, mat, CUTS, e=e, seg=seg, rows=rows, name=name, bulge=bulge, outline=outline,
                       metal=_metal(P, cols))


def _col(P, part):
    """colour(tag, normal) for DK.lathe: the part's tones by normal z (gold: metal banding)."""
    cols = P[part]
    if _metal(P, cols):
        return lambda tag, n: DK.metal_tone(cols, DK.metal_value(n))
    return lambda tag, n: DK.tone(cols, n.z, CUTS)


def _body(P):
    """The shell, band, muzzle, nozzle collar, rear cap with its dial, tank socket -> pieces (Body)."""
    out = [_box(P, "body", BODY_S, Matrix.Translation(BODY_C), "body", e=4.6, seg=28, rows=12, bulge=0.03)]
    out.append(_box(P, "band", (BODY_S[0] + 0.03, 0.075, BODY_S[2] + 0.03), Matrix.Translation((0, -0.2, AXIS_Z)), "band",
                    e=4.6, seg=24, rows=6))
    out.append(_box(P, "accent", (0.245, 0.14, 0.24), Matrix.Translation((0, -0.6, AXIS_Z)), "muzzle", e=4.0, seg=16,
                    rows=6))
    rot = M((0, 0, AXIS_Z), rot=(0, 0, -math.pi / 2))     # lathe +X -> world -Y
    out.append(DK.lathe([(0.66, 0.0, "c"), (0.66, 0.15, "c"), (0.7, 0.175, "c"), (0.8, 0.175, "c"), (0.84, 0.15, "c"),
                         (0.84, 0.1, "h"), (0.82, 0.0, None)], 22, rot,
                        lambda tag, n: P["hole"] if tag == "h" else _col(P, "ring")(tag, n), "collar"))
    out.append(_box(P, "accent", (0.27, 0.075, 0.27), Matrix.Translation((0, 0.68, AXIS_Z)), "rearcap", e=4.2, seg=16,
                    rows=6))
    # the dial on the back: a flat disc (the golden one: a big sapphire set in a gold bezel)
    back = M((0, 0.755, AXIS_Z), rot=(-math.pi / 2, 0, 0))
    out.append(K.cylinder(P["dial"][1], 0.14, 0.04, back, seg=16, outline=False, name="dial"))
    if P["metal"]:
        out.append(DK.gem(P["sapphire"], Vector((0, 0.775, AXIS_Z)), Vector((0, 1, 0)), 0.1, 0.06, facets=8,
                          name="gem_sapphire"))
    else:
        needle = [(-0.018, -0.02), (0.018, -0.02), (0.008, 0.1), (-0.008, 0.1)]
        out.append(DK.flat_poly(P["sticker"], [(0.06 * math.cos(a), 0.06 * math.sin(a)) for a in
                                               (k / 12 * math.tau for k in range(12))], Vector((0, 0.775, AXIS_Z)),
                                Vector((0, 1, 0)), lift=0.001, name="dial_face"))
        out.append(DK.flat_poly(P["hole"], needle, Vector((0, 0.778, AXIS_Z)), Vector((0, 1, 0)), spin=0.6, lift=0.001,
                                name="dial_needle_hole"))
    # the tank's socket on top of the body
    z = AXIS_Z + BODY_S[2] - 0.03
    out.append(DK.lathe([(z - 0.04, 0.0, "a"), (z - 0.04, TANK_R + 0.05, "a"), (z + 0.05, TANK_R + 0.05, "a"),
                         (z + 0.07, TANK_R + 0.03, "a"), (z + 0.07, 0.0, None)], 24, M((0, TANK_Y, 0), rot=(0, -math.pi / 2, 0)),
                        _col(P, "accent"), "socket"))
    return out


def _wand(P):
    """The big ring, its bumps and three flat spokes from the collar (Ring)."""
    m = M((0, RING_Y, AXIS_Z), rot=(math.pi / 2, 0, 0))
    ring = K.torus(P["ring"][1], RING_R, RING_T, m, seg=28, mseg=8, name="ring")
    cen = Vector((0, RING_Y, AXIS_Z))
    if P["metal"]:
        K.recolor_by(ring, lambda c, cur: DK.metal_tone(P["ring"], DK.metal_value(c - cen)))
    else:
        K.recolor_by(ring, lambda c, cur: DK.tone(P["ring"], (c - cen).normalized().z * 0.9, CUTS))
    out = [ring]
    for k in range(8):
        a = math.radians(22.5 + 45 * k)
        d = Vector((math.cos(a), 0, math.sin(a)))
        p = cen + d * RING_R + Vector((0, -RING_T * 0.85, 0))
        if P["metal"]:
            g = DK.GEM_ORDER[k % 5]
            out.append(DK.gem(P[g], p, Vector((0, -1, 0)), 0.05, 0.04, facets=6, spin=a, name="gem_" + g))
        else:     # little painted dots on its front face
            out.append(DK.flat_poly(P["ring"][0], DK.circle(0, 0, 0.042, 10), p - Vector((0, RING_T * 0.15, 0)),
                                    Vector((0, -1, 0)), lift=0.003, name="ring_dot"))
    for k in range(3):
        a = math.radians(90 + 120 * k)
        d = Vector((math.cos(a), 0, math.sin(a)))
        p0 = Vector((0, -0.76, AXIS_Z)) + d * 0.11
        p1 = cen + d * (RING_R - 0.03)
        bm = DK.sweep_bm([p0, (p0 + p1) / 2 + Vector((0, 0, 0)), p1], 0.045, 0.02, side=d.cross(Vector((0, 1, 0))),
                         e=3.0, seg=6, res=2)
        out.append(DK.toned(bm, P["ring"], CUTS, "spoke", metal=_metal(P, P["ring"])))
    return out


def _tank(P):
    """A fat see-through soap bottle in the socket: glass above, soap below, a ribbed screw cap (Tank)."""
    z0 = AXIS_Z + BODY_S[2] - 0.02
    zl = z0 + TANK_H * 0.55       # soap level
    zt = z0 + TANK_H
    rot = M((0, TANK_Y, 0), rot=(0, -math.pi / 2, 0))   # lathe +X -> world +Z
    r = TANK_R

    def col(tag, n):
        if tag == "soap":
            return DK.tone(P["soap"], n.z, CUTS)
        if tag == "line":
            return P["soap"][0]
        return DK.tone(P["tank"], n.z, CUTS)
    out = [DK.lathe([(z0 - 0.06, 0.0, "soap"), (z0 - 0.06, r * 0.86, "soap"), (z0 + 0.02, r, "soap"), (zl - 0.014, r, "line"),
                     (zl + 0.014, r, "glass"), (zt - 0.07, r, "glass"), (zt - 0.02, r * 0.82, "glass"),
                     (zt, r * 0.66, "glass"), (zt, 0.0, None)], 24, rot, col, "tank")]
    rc = r * 0.74
    out.append(DK.lathe([(zt - 0.03, 0.0, "a"), (zt - 0.03, rc, "a"), (zt + 0.1, rc, "a"), (zt + 0.125, rc * 0.84, "a"),
                         (zt + 0.125, 0.0, None)], 20, rot, _col(P, "accent"), "cap"))
    for k in range(10):            # grip lines painted round the cap
        a = k / 10 * math.tau
        c = Vector((math.cos(a) * rc, TANK_Y + math.sin(a) * rc, zt + 0.045))
        out.append(DK.flat_poly(P["accent"][2], [(-0.012, -0.045), (0.012, -0.045), (0.012, 0.045), (-0.012, 0.045)], c,
                                Vector((math.cos(a), math.sin(a), 0)), spin=0.0, lift=0.003, name="cap_line"))
    if P["metal"]:
        out.append(DK.gem(P["diamond"], Vector((0, TANK_Y, zt + 0.125)), Vector((0, 0, 1)), 0.075, 0.06, facets=8,
                          name="gem_diamond"))
    # bubbles floating in the soap and a glassy highlight streak, on the side facing out front-left
    for (a, z, rr) in ((-2.2, zl - 0.07, 0.034), (-1.75, zl - 0.13, 0.024), (-2.6, zl - 0.16, 0.02), (-1.3, zl - 0.06, 0.018)):
        c = Vector((math.cos(a) * (r + 0.004), TANK_Y + math.sin(a) * (r + 0.004), z))
        n = Vector((math.cos(a), math.sin(a), 0))
        if P["metal"]:
            out.append(DK.sparkle(P["sparkle"], c, n, rr * 1.6, spin=a, lift=0.002))
        else:
            out.append(DK.flat_poly(P["soap"][0], [(rr * math.cos(t), rr * math.sin(t)) for t in
                                                   (k / 10 * math.tau for k in range(10))], c, n, lift=0.002,
                                    name="soap_bubble"))
    for (a, z0g, z1g, w) in ((-2.05, zl + 0.03, zt - 0.08, 0.035), (-2.45, zl + 0.05, zl + 0.13, 0.022)):
        pts = []
        for k in range(6):
            zz = z0g + (z1g - z0g) * k / 5
            hw = w * math.sin(math.pi * (k + 0.5) / 6) ** 0.5
            pts.append((zz, hw))
        n = Vector((math.cos(a), math.sin(a), 0))
        side = Vector((-math.sin(a), math.cos(a), 0))
        c0 = Vector((math.cos(a) * r, TANK_Y + math.sin(a) * r, 0))
        poly = [(c0 + side * hw + Vector((0, 0, zz))) for zz, hw in pts] + \
               [(c0 - side * hw + Vector((0, 0, zz))) for zz, hw in reversed(pts)]
        out.append(_strip(P["gloss"], poly, n, "tank_gloss"))
    return out


def _strip(pal, poly3d, n, name):
    """A flat little shape from 3D points (a convex-ish ring) lifted along n."""
    bm = bmesh.new()
    vs = [bm.verts.new(p + n * 0.004) for p in poly3d]
    cen = bm.verts.new(sum((p for p in poly3d), Vector()) / len(poly3d) + n * 0.004)
    for i in range(len(vs)):
        bm.faces.new((cen, vs[i], vs[(i + 1) % len(vs)]))
    bm.normal_update()
    if sum(f.normal.dot(n) for f in bm.faces) < 0:
        bmesh.ops.reverse_faces(bm, faces=bm.faces[:])
    return DK.piece(bm, pal, name, outline=False)


def _handle_frame(s):
    """Point on the handle's centre line s studs down from its top, and its down / front directions."""
    top = Vector((0, HANDLE_Y, AXIS_Z - 0.1))
    d = Vector((0, math.sin(HANDLE_RAKE), -math.cos(HANDLE_RAKE)))
    front = Vector((0, -math.cos(HANDLE_RAKE), -math.sin(HANDLE_RAKE)))
    return top + d * s, d, front


def _handle(P):
    """A chunky pistol grip raked back: finger ribs down its front, a foot pad (Body)."""
    c, d, front = _handle_frame(HANDLE_L / 2)
    m = Matrix.Translation(c) @ Matrix.Rotation(HANDLE_RAKE, 4, "X")
    out = [_box(P, "accent", (0.135, 0.175, HANDLE_L / 2), m, "handle", e=3.0, seg=18, rows=10)]
    for k in range(3):
        q, _d, _f = _handle_frame(0.36 + 0.15 * k)
        q = q + front * 0.165
        mm = Matrix.Translation(q) @ Matrix.Rotation(HANDLE_RAKE, 4, "X")
        out.append(_box(P, "accent", (0.12, 0.035, 0.038), mm, "rib", e=2.6, seg=8, rows=4, outline=False))
    q, _d, _f = _handle_frame(HANDLE_L - 0.02)
    mm = Matrix.Translation(q) @ Matrix.Rotation(HANDLE_RAKE, 4, "X")
    out.append(_box(P, "band" if P["metal"] else "accent", (0.16, 0.21, 0.055), mm, "foot", e=3.0, seg=14, rows=6))
    return out


def _trigger(P):
    """A chunky flat trigger (Trigger) and the flat guard round it (Body)."""
    trig = DK.toned(DK.sweep_bm(TRIGGER, 0.055, 0.045, side=(1, 0, 0), e=3.0, seg=8, res=8,
                                scale=lambda t: 1.0 + 0.25 * DK.smooth(0.5, 1.0, t)),
                    P["accent"], CUTS, "trigger", metal=_metal(P, P["accent"]))
    A = AXIS_Z
    guard_path = [(0, -0.23, A - 0.24), (0, -0.25, A - 0.45), (0, -0.1, A - 0.6), (0, 0.15, A - 0.62), (0, 0.36, A - 0.57)]
    guard = DK.toned(DK.sweep_bm(guard_path, 0.05, 0.03, side=(1, 0, 0), e=3.0, seg=8, res=10),
                     P["body"], CUTS, "guard", metal=_metal(P, P["body"]))
    return [trig], [guard]


def _fillet(poly, r, n=3):
    """A convex CCW 2D polygon with its corners rounded (radius r, n + 1 points per corner)."""
    pts = [Vector(p) for p in poly]
    out = []
    for i in range(len(pts)):
        a, b, c = pts[i - 1], pts[i], pts[(i + 1) % len(pts)]
        d1, d2 = (a - b).normalized(), (c - b).normalized()
        half = math.acos(max(-1.0, min(1.0, d1.dot(d2)))) / 2
        t = r / math.tan(half)
        p0, p1 = b + d1 * t, b + d2 * t
        cen = b + (d1 + d2).normalized() * (r / math.sin(half))
        a0, a1 = math.atan2(p0.y - cen.y, p0.x - cen.x), math.atan2(p1.y - cen.y, p1.x - cen.x)
        da = (a1 - a0 + math.pi) % math.tau - math.pi
        for k in range(n + 1):
            ang = a0 + da * k / n
            out.append((cen.x + r * math.cos(ang), cen.y + r * math.sin(ang)))
    return out


def _wing_z(x):
    """The wings' mid height: level at the body, drooping a little toward the tip."""
    return WING_Z - WING_DROP * max(0.0, abs(x) - WING[0][0]) / (WING[1][0] - WING[0][0])


def _wings(P):
    """Two flat swept-back side wings low on the body (the toy-blaster look, and a wide, angular plan
    view: never a long rounded capsule), each with a stripe along its squared tip and a chevron on top
    (the golden one: a gem) (Body)."""
    out = []
    for s in (-1, 1):
        poly = _fillet([(s * x, y) for x, y in WING], 0.06)
        if s < 0:
            poly.reverse()                       # keep it CCW
        inset = DK.offset_poly(poly, -WING_T * 0.8)
        bm = bmesh.new()
        top = [bm.verts.new((x, y, _wing_z(x) + WING_T)) for x, y in inset]
        mid = [bm.verts.new((x, y, _wing_z(x))) for x, y in poly]
        bot = [bm.verts.new((x, y, _wing_z(x) - WING_T)) for x, y in inset]
        n = len(poly)
        for i in range(n):
            j = (i + 1) % n
            bm.faces.new((mid[i], mid[j], top[j], top[i]))
            bm.faces.new((bot[i], bot[j], mid[j], mid[i]))
        ct = bm.verts.new(sum((v.co for v in top), Vector()) / n)
        cb = bm.verts.new(sum((v.co for v in bot), Vector()) / n)
        for i in range(n):
            j = (i + 1) % n
            bm.faces.new((ct, top[i], top[j]))
            bm.faces.new((cb, bot[j], bot[i]))
        out.append(DK.toned(bm, P["accent"], CUTS, "wing", metal=_metal(P, P["accent"])))
        # a pink stripe along the wing's squared tip
        x0 = s * (WING[1][0] - 0.07)
        y0, y1 = WING[1][1] + 0.09, WING[2][1] - 0.04
        stripe = [(-0.028, -(y1 - y0) / 2), (0.028, -(y1 - y0) / 2), (0.028, (y1 - y0) / 2), (-0.028, (y1 - y0) / 2)]
        c = Vector((x0, (y0 + y1) / 2, _wing_z(x0) + WING_T + 0.002))
        out.append(DK.flat_poly(P["pad"][0] if not P["metal"] else P["shine"], stripe, c, Vector((0, 0, 1)), lift=0.002,
                                name="wing_stripe"))
        # a chevron on top of the wing (the golden one: a gem)
        c = Vector((s * 0.45, 0.25, 0.0))
        c.z = _wing_z(c.x) + WING_T + 0.002
        if P["metal"]:
            out.append(DK.gem(P["ruby" if s < 0 else "sapphire"], c, Vector((0, 0, 1)), 0.055, 0.04, facets=6, name="gem"))
        else:
            chev = [(-0.075, -0.02), (0.0, 0.06), (0.075, -0.02), (0.075, -0.075), (0.0, 0.005), (-0.075, -0.075)]
            out.append(DK.flat_poly(P["pad"][0], chev, c, Vector((0, 0, 1)), spin=0.0, lift=0.002, name="wing_chevron"))
    return out


def _decor(P, bvh, hbvh):
    """Stickers, gloss streak, rivets, grip pads (Body)."""
    out = []
    for s in (-1, 1):
        along = Vector((-s, 0, 0))
        du = Vector((0, s, 0))
        dv = Vector((0, 0, 1))
        stickers = ((0.36, AXIS_Z + 0.04, 0.1), (0.14, AXIS_Z - 0.04, 0.062), (0.02, AXIS_Z + 0.13, 0.044))
        if P["metal"]:          # one big badge, room for the shine bars
            stickers = ((0.38, AXIS_Z + 0.0, 0.12),)
        for (y, z, r) in stickers:
            o = Vector((s * 0.3, y, z))
            ring = DK.circle(0.0, 0.0, r, 20)
            if P["metal"]:      # a gem-centred star badge
                out.append(DK.decal(bvh, DK.star(0, 0, r * 1.1, r * 0.5, 5), o, du, dv, along, 0.006, P["star"],
                                    "badge_star", step=0.03))
                hit = bvh.ray_cast(o - along * 2.0, along)
                if hit[0] is not None:
                    g = DK.GEM_ORDER[int(y * 10) % 5]
                    out.append(DK.gem(P[g], hit[0], -along, r * 0.42, r * 0.32, facets=6, name="gem_" + g))
                continue
            hole = DK.circle(0.0, 0.0, r * 0.74, 20)
            out.append(DK.decal(bvh, ring, o, du, dv, along, 0.005, P["sticker"], "sticker", step=0.045))
            out.append(DK.decal(bvh, hole, o, du, dv, along, 0.008, P["body"][1], "sticker_hole", step=0.045))
            glint = DK.circle(-r * 0.4, r * 0.42, r * 0.13, 8)
            out.append(DK.decal(bvh, glint, o, du, dv, along, 0.01, P["sticker"], "sticker_glint", step=0.03))
        # a star sticker on the front of the side
        o = Vector((s * 0.3, -0.36, AXIS_Z + 0.04))
        out.append(DK.decal(bvh, DK.star(0, 0, 0.085, 0.04, 5), o, du, dv, along, 0.006,
                            P["sparkle"] if P["metal"] else P["star"], "star", step=0.03))
        # rivets on the band
        for z in (AXIS_Z + 0.02, AXIS_Z + 0.17):
            hit = bvh.ray_cast(Vector((s * 2.0, -0.2, z)), along)
            if hit[0] is not None:
                out.append(DK.flat_poly(P["rivet"], DK.circle(0, 0, 0.026, 8), hit[0], hit[1], lift=0.004,
                                        name="rivet"))
        # pink grip pads on the handle with three dots
        c, d, front = _handle_frame(0.55)
        o = c + Vector((s * 0.14, 0, 0))
        up = -d
        pad = DK.rounded_rect(0.1, 0.22, 0.07, n=4)
        hu = Vector((0, front.y, front.z)) * -s
        out.append(DK.decal(hbvh, pad, o, hu, up, along, 0.005, P["pad"][0], "pad", step=0.06))
        for k in (-1, 0, 1):
            out.append(DK.decal(hbvh, DK.circle(0, k * 0.11, 0.028, 8), o, hu, up, along, 0.009, P["pad"][1], "pad_dot",
                                step=0.04))
    # a glossy highlight streak along the top-left edge of the body
    streak = [(-0.03, -0.42), (0.03, -0.42), (0.04, 0.3), (0.0, 0.42), (-0.04, 0.3)]
    out.append(DK.decal(bvh, streak, Vector((-0.17, 0.0, AXIS_Z + 1.0)), Vector((1, 0, 0)), Vector((0, 1, 0)),
                        Vector((0, 0, -1)), 0.006, P["gloss"], "gloss", step=0.05))
    if P["metal"]:
        for s in (-1, 1):       # diagonal shine bars on both sides of the body and the handle
            along = Vector((-s, 0, 0))
            out += DK.shine_bars(bvh, Vector((s * 0.3, 0.06, AXIS_Z + 0.05)), Vector((0, s, 0)), Vector((0, 0, 1)), along,
                                 (0.12, 0.2), P["shine"], tilt=0.5)
            c, d, front = _handle_frame(0.3)
            out += DK.shine_bars(hbvh, c, Vector((0, -front.y, -front.z)) * s, -d, along, (0.13, 0.16), P["shine"],
                                 tilt=0.45)
        for (x, y, r) in ((0.12, -0.3, 0.05), (-0.05, 0.45, 0.04), (0.16, 0.25, 0.035)):
            hit = bvh.ray_cast(Vector((x, y, AXIS_Z + 2.0)), Vector((0, 0, -1)))
            if hit[0] is not None:
                out.append(DK.sparkle(P["sparkle"], hit[0], hit[1], r, spin=x * 7))
    return out


def build(gold=False):
    name = NAME + ("_Gold" if gold else "")
    P = _palette(gold)
    body = _body(P)
    handle = _handle(P)
    trig, guard = _trigger(P)
    bvh = DK.bvh_of(body[:1])
    hbvh = DK.bvh_of(handle[:1])
    p = DK.tag_all(body + handle + guard + _wings(P) + _decor(P, bvh, hbvh), "Body")
    p += DK.tag_all(trig, "Trigger") + DK.tag_all(_wand(P), "Ring") + DK.tag_all(_tank(P), "Tank")
    low = min(v.co.z for pc in p for v in pc.mesh.vertices)   # stand the handle's foot on the floor
    SHIFT[name] = -low
    DK.transform(p, Matrix.Translation((0, 0, -low)))
    body_o, outline = K.finish(p, name, outline_width=OUTLINE_W)
    DK.no_bounce(outline)
    up = Vector((0, 0, -low))
    return [body_o, outline] + K.markers(name) + [items.grip(name, GRIP + up), K.marker(name + "_Tip", TIP + up)]


BUILDERS = {NAME: build, NAME + "_Gold": lambda: build(True)}


# ---------------------------------------------------------------- skeleton
def rig(name, objs):
    """`<Name>_Rig`: Root (grip) + Body + Trigger, Ring, Tank (see the module doc)."""
    up = Vector((0, 0, SHIFT.get(name, 0.0)))
    t0, t1 = Vector(TRIGGER[0]), Vector(TRIGGER[-1])
    z0 = AXIS_Z + BODY_S[2] - 0.02
    bones = [DK.Bone("Root", None, GRIP + up, GRIP + up + Vector((0, -0.3, 0)), deform=False),
             DK.Bone("Body", "Root", GRIP + up, GRIP + up + Vector((0, 0, 0.5))),
             DK.Bone("Trigger", "Body", t0 + up, Vector((0, t0.y, t1.z)) + up),
             DK.Bone("Ring", "Body", TIP + up, TIP + up + Vector((0, -0.3, 0)), z=(0, 0, 1)),
             DK.Bone("Tank", "Body", Vector((0, TANK_Y, z0 - 0.04)) + up, Vector((0, TANK_Y, z0 + TANK_H + 0.12)) + up)]
    return DK.skin(name, objs, bones, {})


POSES = {
    "rest": {},
    "pull": {"Trigger": [(("local", -1, 0, 0), 28)]},
    "shot": {"Trigger": [(("local", -1, 0, 0), 28)], "Ring": [("own", 40), (("local", 1, 0, 0), 15)],
             "Tank": [((1, 0, 0), -12)], "Body": [((1, 0, 0), -6)]},
    "wobble": {"Ring": [(("local", 0, 0, 1), 20)], "Tank": [((0, 1, 0), 14)]},
}
