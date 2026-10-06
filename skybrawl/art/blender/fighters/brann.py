"""Brann, forge smith. Hammer + Gauntlets. Slow, heavy tank.

From the approved concept (art/concepts/Brann_v1.jpg): a red bandana knotted
over a shaved head, a huge rust-red beard ending in two braids with iron
rings, a bushy mustache over a hearty grin, soot on his cheeks. A sleeveless
charcoal work shirt under a heavy leather smith's apron (bib, tool pockets
with a hammer and tongs, straps crossing on his back through an iron ring, a
back flap), a wide belt with an iron buckle, bare muscular arms with riveted
iron bracers carved with glowing runes, thick leather work gloves, roomy tan
canvas trousers and heavy boots with steel toe caps.
"""

import math

from mathutils import Matrix, Vector

from sky.hero import Sway, Where, smoothstep, surface_frame

NAME = "Brann"
HERO = True

COLORS = {
    "skin": ("#e3a27c", "skin"),
    "stubble": ("#b8764e", "hair"),
    "beard": ("#b4501e", "hair"),
    "beard_dark": ("#86391a", "hair"),
    "bandana": ("#c32f27", "cloth"),
    "bandana_dark": ("#8a1f1a", "cloth"),
    "shirt": ("#3b3b41", "cloth"),
    "shirt_dark": ("#29292e", "cloth"),
    "apron": ("#7c4a2a", "leather"),
    "apron_dark": ("#58311b", "leather"),
    "belt": ("#3e2716", "leather"),
    "iron": ("#737a83", "metal"),
    "iron_dark": ("#4e535a", "metal"),
    "ember": ("#ff8a1c", "glow"),
    "glove": ("#4d3423", "leather"),
    "pants": ("#bc9d6c", "cloth"),
    "boot": ("#5e3c26", "leather"),
    "sole": ("#2a201a", "leather"),
    "steel": ("#8c939b", "metal"),
    "wood": ("#7a5232", "leather"),
}

BODY = {"shoulders": 1.1, "chest": 1.15, "waist": 1.02, "hips": 1.0, "arms": 1.18, "legs": 1.06, "neck": 1.3,
        "jaw": 1.12}

APRON_Z = -0.5  # the apron skirt's front plane, clear of the thighs

SWAYS = [
    Sway("Apron", "Root", [(0, 3.46, -0.46), (0, 2.7, APRON_Z), (0, 1.98, APRON_Z - 0.02)], stiffness=0.4,
         damping=0.25, limit=50, behind=-1),
    Sway("ApronBack", "Root", [(0, 3.46, 0.44), (0, 3.0, 0.5), (0, 2.56, 0.5)], stiffness=0.4, damping=0.25,
         limit=50, behind=1),
    Sway("BraidLeft", "Neck", [(-0.11, 4.72, -0.5), (-0.12, 4.42, -0.62), (-0.13, 4.1, -0.64)], stiffness=0.3,
         damping=0.2, limit=55, behind=-1),
    Sway("BraidRight", "Neck", [(0.11, 4.72, -0.5), (0.12, 4.42, -0.62), (0.13, 4.1, -0.64)], stiffness=0.3,
         damping=0.2, limit=55, behind=-1),
    Sway("Bandana", "Neck", [(0, 5.56, 0.46), (0, 5.32, 0.56), (0, 5.08, 0.58)], stiffness=0.25, damping=0.15,
         limit=70, behind=1),
]


def face(h):
    def extras(c, cx, ey):
        for x, y, rx, ry in ((cx - 0.22, ey - 0.12, 0.07, 0.035), (cx + 0.25, ey - 0.08, 0.05, 0.03),
                             (cx + 0.12, ey + 0.2, 0.06, 0.025)):  # soot
            c.ellipse(x, y, rx, ry, "#3a2c28", alpha=0.3, rotation=15)
        for s in (-1, 1):
            c.ellipse(cx + s * 0.21, ey - 0.14, 0.07, 0.04, "#d0604a", alpha=0.25)
    h.face(eyes="#4a6a8c", brows="#8a3818", lips="#7a3326", mouth="grin", brow_tilt=(0.02, 0.02), extras=extras)


def model(h):
    h.body(garment_tris=2900)
    face(h)
    torso = lambda p: Where(p).kind == "torso"
    # sleeveless work shirt
    h.garment(lambda p: torso(p) and 3.4 < p[1] < 4.98 and not (p[2] < -0.1 and p[1] > 4.86), "shirt", gap=0.03,
              thickness=0.03, hem="shirt_dark", hem_radius=0.02, name="Shirt")
    apron(h)
    bracers(h)
    h.hands(palm="glove", fingers="glove", cuff="glove", scale=1.24)
    # roomy canvas trousers, tucked into the boots
    h.garment(lambda p: (torso(p) and p[1] < 3.56) or (Where(p).kind == "leg" and p[1] > 0.95), "pants", gap=0.03,
              thickness=0.035, name="Trousers",
              inflate=lambda p: 0.07 * math.exp(-((p[1] - 1.8) / 0.45) ** 2) + 0.03 * smoothstep(3.2, 2.6, p[1]))
    h.boots("boot", "sole", top=1.22, toe="steel", cuff="boot", cuff_height=0.2, width=1.14, gap=0.085, flare=0.03)
    for s in (-1, 1):
        x = s * 0.37
        h.band((x, 0.84, 0.0), (0, 1, 0), 0.08, "belt", thickness=0.03, name="BootStrap")
        mb = h.builder()
        mb.box((x + s * 0.28, 0.84, -0.04), (0.04, 0.11, 0.12), "iron", bevel=0.012)
        h.piece(mb, name="Buckle")
    head(h)


def apron(h):
    # bib over the chest
    def bib(p):
        return Where(p).kind == "torso" and p[2] < -0.1 and 3.42 < p[1] < 4.66 and abs(p[0]) < 0.34 + (4.66 - p[1]) * 0.12
    h.garment(bib, "apron", gap=0.075, thickness=0.045, hem="apron_dark", hem_radius=0.02, name="ApronBib", cover=False)
    # wide belt with an iron buckle
    h.band((0, 3.5, 0.02), (0, 1, 0), 0.14, "belt", thickness=0.06, name="Belt")
    (bx, by, bz), _ = h.on_surface((0, 3.5, -0.9))
    mb = h.builder()
    mb.box((0, 3.5, bz - 0.02), (0.22, 0.17, 0.05), "iron", bevel=0.02)
    mb.box((0, 3.5, bz - 0.045), (0.12, 0.08, 0.02), "belt", bevel=0.005)
    h.piece(mb, name="BeltBuckle")
    # the skirt hangs free from the belt to below the knees, swinging on its own bones
    front = SWAYS[0]
    xs = (-0.52, -0.26, 0.0, 0.26, 0.52)
    top = [h.on_surface((x, 3.44, -0.9))[0] for x in xs]
    rows = [[(x, 3.44, min(z - 0.005, -0.4)) for x, (_, _, z) in zip(xs, top)],
            [(x * 1.02, 2.7, APRON_Z + 0.22 * x * x) for x in xs],
            [(x * 1.06, 1.98, APRON_Z - 0.02 + 0.22 * x * x) for x in xs]]
    h.panel(rows, "apron", thickness=0.045, binding=("sway", front), name="ApronSkirt", hem="apron_dark")
    # tool pockets: a hammer on his right, tongs on his left
    mb = h.builder()
    for s in (-1, 1):
        x = s * 0.25
        z = APRON_Z + 0.22 * x * x - 0.04
        mb.box((x, 2.86, z), (0.3, 0.36, 0.05), "apron_dark", bevel=0.015, segments=1)
        mb.box((x, 3.0, z - 0.03), (0.3, 0.06, 0.02), "apron", bevel=0)
    mb.cylinder((0.22, 3.04, APRON_Z - 0.09), 0.03, 0.34, "wood", segments=8)
    mb.box((0.22, 3.24, APRON_Z - 0.09), (0.18, 0.08, 0.08), "iron", bevel=0.015, segments=1)
    for d in (-1, 1):
        mb.cylinder((-0.25 + d * 0.03, 3.08, APRON_Z - 0.09), 0.016, 0.4, "iron_dark", rotation=(0, 0, d * 6),
                    segments=6)
    h.piece(mb, binding=("sway", front), name="Pockets")
    # back flap
    back = SWAYS[1]
    xs = (-0.4, -0.2, 0.0, 0.2, 0.4)
    top = [h.on_surface((x, 3.44, 0.9))[0] for x in xs]
    rows = [[(x, 3.44, max(z + 0.005, 0.38)) for x, (_, _, z) in zip(xs, top)],
            [(x * 1.04, 3.0, 0.5 - 0.2 * x * x) for x in xs],
            [(x * 1.08, 2.56, 0.52 - 0.2 * x * x) for x in xs]]
    h.panel(rows, "apron", thickness=0.045, binding=("sway", back), name="ApronBack", hem="apron_dark")
    # straps over the shoulders, crossing on the back through an iron ring
    for s in (-1, 1):
        h.strap([(s * 0.3, 4.62, -0.5), (s * 0.44, 4.96, -0.1), (s * 0.36, 4.82, 0.3), (0.0, 4.3, 0.46),
                 (-s * 0.34, 3.62, 0.42)], 0.12, "apron_dark", thickness=0.03, offset=0.01, name="ApronStrap")
        (rx, ry, rz), n = h.on_surface((s * 0.3, 4.62, -0.8))
        mb = h.builder()
        mb.box((rx, ry - 0.02, rz - 0.02), (0.14, 0.1, 0.04), "iron", bevel=0.012)
        h.piece(mb, name="StrapClip")
    (rx, ry, rz), n = h.on_surface((0, 4.3, 0.9))
    mb = h.builder()
    mb.torus((rx, ry, rz + 0.03), 0.08, 0.022, "iron", rotation=(90, 0, 0), segments=12, sides=5)
    h.piece(mb, name="StrapRing")


def bracers(h):
    """Riveted iron bracers on the forearms, carved with glowing runes."""
    for side, s in (("Left", -1), ("Right", 1)):
        el = (s * 1.04, 3.74, 0.04)
        wr = (s * 1.13, 2.98, 0.04)
        axis = (wr[0] - el[0], wr[1] - el[1], 0.0)
        mid = lambda t: (el[0] + (wr[0] - el[0]) * t, el[1] + (wr[1] - el[1]) * t, 0.04)
        h.band(mid(0.58), axis, 0.5, "iron", thickness=0.03, flare=0.04, name="Bracer")
        for t, flare in ((0.28, 0.04), (0.88, 0.0)):
            h.band(mid(t), axis, 0.045, "iron_dark", thickness=0.04 + flare, name="BracerRim")
        # runes on the outside of the forearm, facing forward
        (cx, cy, cz), n = h.on_surface((mid(0.58)[0] + s * 0.1, mid(0.58)[1], -0.4))
        rot = surface_frame(n, (0, 1, 0))
        mb = h.builder()
        for du, dv, ang, length in ((0.0, 0.0, 0, 0.28), (0.045, 0.06, 40, 0.13), (0.045, -0.03, -40, 0.13),
                                    (-0.075, 0.11, 0, 0.07), (-0.075, -0.11, 0, 0.07)):
            r = rot @ Matrix.Rotation(math.radians(ang), 3, "Y")
            off = rot @ Vector((du, 0.0, dv))
            mb.box((cx + n[0] * 0.012 + off[0], cy + n[1] * 0.012 + off[1], cz + n[2] * 0.012 + off[2]),
                   (0.03, 0.02, length), "ember", rotation=r, bevel=0)
        for t in (0.35, 0.82):
            (px, py, pz), pn = h.on_surface((mid(t)[0] + s * 0.06, mid(t)[1], -0.4))
            mb.sphere((px, py, pz), 0.022, "steel", segments=6, rings=4)  # rivets
        h.piece(mb, name="Runes")


def head(h):
    # ginger stubble on the shaved sides
    def ear(p):
        return ((abs(p[0]) - 0.34) / 0.09) ** 2 + ((p[1] - 5.48) / 0.15) ** 2 + ((p[2] - 0.06) / 0.11) ** 2 < 1
    h.tint(lambda p: Where(p).kind == "head" and p[1] > 5.34 and p[2] > -0.2 and not ear(p), "stubble")
    # the bandana over the top of the head, lower at the back where it's tied
    edge = lambda p: 5.72 - 0.24 * smoothstep(-0.1, 0.35, p[2])
    h.garment(lambda p: Where(p).kind == "head" and p[1] > edge(p), "bandana", gap=0.025, thickness=0.035,
              smooth=3, hem="bandana_dark", hem_radius=0.02, name="Bandana")

    def knot(m):
        m.ball((0, 5.56, 0.44), (0.1, 0.08, 0.08))
        for s in (-1, 1):
            m.ball((s * 0.1, 5.58, 0.42), (0.08, 0.06, 0.06))
    h.blob(knot, "bandana", tris=240, name="BandanaKnot", binding=("bone", "Neck"))
    for s in (-1, 1):
        h.ribbon([(s * 0.04, 5.56, 0.47), (s * 0.09, 5.32, 0.57), (s * 0.13, 5.08, 0.58)], (0, 0, 1), 0.12,
                 "bandana", thickness=0.025, binding=("sway", SWAYS[4]), name="BandanaTail")

    # a big beard: sideburns, the jaw, hanging onto the chest
    def beard(m):
        m.ball((0, 5.18, -0.17), (0.34, 0.24, 0.28))
        m.ball((0, 4.98, -0.3), (0.28, 0.22, 0.2))
        m.ball((0, 4.78, -0.4), (0.21, 0.18, 0.14))
        for s in (-1, 1):
            m.capsule((s * 0.31, 5.62, 0.0), (s * 0.3, 5.28, -0.1), 0.07)
        m.ball((0, 5.27, -0.46), (0.16, 0.075, 0.14), negative=True)  # the mouth stays clear
    h.blob(beard, "beard", tris=900, name="Beard", binding=("bone", "Neck"))
    # bushy mustache
    for s in (-1, 1):
        h.lock([(s * 0.01, 5.37, -0.44), (s * 0.15, 5.34, -0.44), (s * 0.27, 5.22, -0.38)], 0.15, 0.09, "beard",
               binding=("bone", "Neck"), name="Mustache", sides=6, taper=0.3)
    # braids with iron rings
    for s, sway in ((-1, SWAYS[2]), (1, SWAYS[3])):
        pts = sway.points
        h.lock(pts, lambda f: 0.15 * (0.82 + 0.18 * abs(math.sin(f * math.pi * 5))),
               lambda f: 0.13 * (0.82 + 0.18 * abs(math.sin(f * math.pi * 5))), "beard_dark",
               binding=("sway", sway), name="Braid", sides=6, taper=0.4)
        mb = h.builder()
        for x, y, z in ((0.12, 4.42, -0.62), (0.125, 4.2, -0.635)):
            mb.torus((s * x, y, z), 0.06, 0.022, "iron", segments=10, sides=5)
        h.piece(mb, binding=("sway", sway), name="BraidRings")
