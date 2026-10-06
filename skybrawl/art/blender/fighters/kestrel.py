"""Kestrel, sky-corsair. Sword + Bow. Fast, nimble duelist.

From the approved concept (art/concepts/Kestrel_v1.jpg): copper undercut swept
up and back, brass flight goggles pushed up on her brow, a small scar over
her left eyebrow and a confident smirk. A cropped teal corsair jacket with
gold piping and a high open collar, sleeves rolled to the elbow over a
cream shirt; a leather bandolier with a brass compass; a wine-red sash
knotted at her right hip over a brown belt; charcoal cargo trousers with
grey thigh pouches; fingerless leather gloves; tan knee-high flight boots
with folded cuffs, buckled straps, dark toe caps and lug soles.
"""

import math

from sky.hero import Sway, Where, align_y, smoothstep

NAME = "Kestrel"
HERO = True

COLORS = {
    "skin": ("#b9784c", "skin"),
    "hair": ("#d65a1c", "hair"),
    "hair_dark": ("#7e4a30", "hair"),
    "teal": ("#1e8189", "cloth"),
    "gold": ("#e2ac40", "gold"),
    "cream": ("#efe1c4", "cloth"),
    "sash": ("#98203f", "cloth"),
    "leather": ("#6b4228", "leather"),
    "glove": ("#3e2a1f", "leather"),
    "pants": ("#3d3a3c", "cloth"),
    "pouch": ("#5b5e63", "cloth"),
    "boot": ("#b98652", "leather"),
    "toe": ("#4a3122", "leather"),
    "sole": ("#2b211c", "leather"),
    "brass": ("#c99a3a", "metal"),
    "lens": ("#56d3d6", "gem"),
}

BODY = {"shoulders": 0.9, "chest": 0.95, "bust": 0.55, "waist": 0.74, "hips": 1.04, "arms": 0.84, "legs": 0.95,
        "neck": 0.85, "jaw": 0.86}

SWAYS = [
    Sway("Sash", "Root", [(0.5, 3.56, -0.36), (0.56, 3.05, -0.38), (0.6, 2.5, -0.34)], stiffness=0.3, damping=0.2,
         limit=75),
]


def face(h):
    def extras(c, cx, ey):
        c.stroke([(cx + 0.2, ey + 0.17), (cx + 0.15, ey + 0.05)], 0.016, "#e2a789")  # scar over her left brow
        for dx, dy in ((-0.21, -0.09), (-0.17, -0.11), (-0.24, -0.12), (0.21, -0.09), (0.17, -0.11), (0.24, -0.12)):
            c.ellipse(cx + dx, ey + dy, 0.008, 0.008, "#7e4326", alpha=0.65)
        for s in (-1, 1):
            c.ellipse(cx + s * 0.21, ey - 0.15, 0.075, 0.04, "#d36d55", alpha=0.22)
    h.face(eyes="#8a5420", brows="#8c3414", lips="#7a2e25", mouth="smirk", brow_tilt=(0.0, 0.03), extras=extras)


def model(h):
    h.body()
    face(h)
    torso = lambda p, lo, hi: Where(p).kind == "torso" and lo <= p[1] <= hi

    # cream shirt painted on (it shows in the open front and below the jacket)
    h.tint(lambda p: torso(p, 3.5, 4.98) or (Where(p).kind == "arm" and Where(p).s < 1.0), "cream")
    # cropped jacket, open V at the front, sleeves rolled to the elbow
    def jacket(p):
        w = Where(p)
        if w.kind == "arm":
            return w.s < 0.9
        if w.kind != "torso" or not (3.86 <= p[1] <= 4.96):
            return False
        open_front = p[2] < -0.12 and abs(p[0]) < 0.07 + (p[1] - 3.86) * 0.2
        return not open_front
    h.garment(jacket, "teal", gap=0.04, thickness=0.03, hem="gold", hem_radius=0.02, name="Jacket")
    # rolled cream cuffs at the elbows
    for side, s in (("Left", -1), ("Right", 1)):
        h.band((s * 1.03, 3.84, 0.04), (s * 0.2, -0.9, 0.0), 0.13, "cream", thickness=0.045, flare=0.015,
               name="Cuff")
    # high open collar with a gold rim, shirt collar points
    h.band((0, 5.0, 0.05), (0, 1, 0), 0.3, "teal", thickness=0.045, offset=0.04, flare=-0.04, arc=(75, 285),
           name="Collar")
    h.band((0, 5.15, 0.05), (0, 1, 0), 0.03, "gold", thickness=0.055, offset=0.05, arc=(75, 285), name="CollarRim")
    for s in (-1, 1):
        (lx, ly, lz), n = h.on_surface((s * 0.2, 4.55, -0.5))
        mb = h.builder()
        mb.prism([(0.0, 0.0), (s * 0.2, 0.06), (s * 0.24, -0.22), (s * 0.06, -0.5)], 0.03, "teal",
                 center=(lx + s * 0.02, ly + 0.25, lz - 0.02), rotation=(0, 0, 0), bevel=0.008)
        mb.prism([(0.0, 0.0), (s * 0.13, 0.02), (s * 0.04, -0.17)], 0.02, "cream",
                 center=(s * 0.07, 4.94, -0.26), rotation=(-25, 0, 0), bevel=0.005)
        h.piece(mb, name="Lapel")
    # trousers, roomy at the thigh
    def trousers(p):
        w = Where(p)
        return (w.kind == "torso" and p[1] < 3.66) or (w.kind == "leg" and p[1] > 1.6)
    h.garment(trousers, "pants", gap=0.02, thickness=0.03, name="Trousers",
              inflate=lambda p: 0.05 * math.exp(-((p[1] - 2.4) / 0.6) ** 2))
    # knee-high boots with folded cuffs, two buckled straps each
    h.boots("boot", "sole", top=1.9, toe="toe", cuff="boot", cuff_height=0.26, flare=0.03)
    for s in (-1, 1):
        x = s * 0.36
        for y in (1.25, 0.7):
            h.band((x, y, 0.0), (0, 1, 0), 0.07, "leather", thickness=0.03, name="BootStrap")
            mb = h.builder()
            mb.box((x + s * 0.21, y, -0.06), (0.04, 0.09, 0.1), "brass", bevel=0.012)
            h.piece(mb, name="Buckle")
    # fists in fingerless gloves
    h.hands(palm="glove", fingers="skin", cuff="glove")
    # sash and belt
    h.band((0, 3.62, 0.02), (0, 1, 0), 0.26, "sash", thickness=0.05, flare=0.02, name="Sash")
    h.band((0, 3.5, 0.02), (0, 1, 0), 0.09, "leather", thickness=0.07, name="Belt")
    mb = h.builder()
    mb.box((0, 3.5, -0.43), (0.16, 0.12, 0.05), "brass", bevel=0.02)
    mb.sphere((0.46, 3.59, -0.36), (0.12, 0.1, 0.09), "sash", segments=12, rings=8)
    h.piece(mb, name="Buckle")
    for k, dx in enumerate((0.0, 0.08)):
        h.ribbon([(0.48 + dx, 3.56, -0.36), (0.53 + dx, 3.05, -0.38 + 0.02 * k), (0.57 + dx, 2.52 + 0.08 * k, -0.33)],
                 (0, 0, -1), 0.12, "sash", thickness=0.025, binding=("sway", SWAYS[0]), name="SashTail")
    # bandolier with a brass compass
    h.strap([(-0.6, 4.86, 0.02), (-0.2, 4.45, -0.42), (0.25, 3.98, -0.42), (0.58, 3.62, -0.32)], 0.15, "leather",
            thickness=0.03, name="Bandolier")
    h.strap([(-0.6, 4.86, 0.08), (-0.1, 4.4, 0.42), (0.3, 3.95, 0.38), (0.58, 3.62, 0.28)], 0.15, "leather",
            thickness=0.03, name="BandolierBack")
    (cx, cy, cz), n = h.on_surface((-0.24, 4.4, -0.5))
    mb = h.builder()
    rot = align_y(n)
    mb.cylinder((cx + n[0] * 0.04, cy + n[1] * 0.04, cz + n[2] * 0.04), 0.13, 0.06, "brass", rotation=rot, segments=20)
    mb.cylinder((cx + n[0] * 0.07, cy + n[1] * 0.07, cz + n[2] * 0.07), 0.1, 0.02, "cream", rotation=rot, segments=20)
    h.piece(mb, name="Compass")
    # thigh pouches
    for s in (-1, 1):
        (px, py, pz), n = h.on_surface((s * 0.62, 2.62, -0.05))
        mb = h.builder()
        mb.box((px + s * 0.07, py, pz), (0.14, 0.34, 0.3), "pouch", bevel=0.04)
        mb.box((px + s * 0.12, py + 0.12, pz), (0.06, 0.08, 0.31), "pouch", bevel=0.02)
        h.piece(mb, name="Pouch")
        h.band((s * 0.37, 2.8, 0.0), (0, 1, 0), 0.05, "leather", thickness=0.03, name="PouchStrap")
    hair(h)
    goggles(h)


def hair(h):
    # undercut: the sides and back of the head painted short, the hairline
    # dropping from above the ears to the nape
    def ear(p):
        return ((abs(p[0]) - 0.34) / 0.09) ** 2 + ((p[1] - 5.48) / 0.15) ** 2 + ((p[2] - 0.06) / 0.11) ** 2 < 1

    def undercut(p):
        if Where(p).kind != "head" or p[2] < -0.24 + (5.62 - p[1]) * 0.25 or ear(p):
            return False
        return p[1] > 5.6 - 0.3 * smoothstep(-0.05, 0.35, p[2])
    h.tint(undercut, "hair_dark")

    # the long copper top, swept up and back
    def mass(m):
        m.ball((0.0, 5.84, 0.06), (0.36, 0.2, 0.42))
        m.ball((0.07, 5.96, -0.16), (0.31, 0.14, 0.2))  # quiff over the brow
        m.ball((0.0, 5.9, 0.32), (0.29, 0.13, 0.18))  # crown
        m.ball((0.22, 5.82, -0.24), (0.18, 0.1, 0.12))  # sweeping to her right
    h.blob(mass, "hair", tris=700, name="HairMass")
    # tousled locks breaking the silhouette: off the hairline, back over the crown, flicking out at the nape
    for x, lift, back in ((-0.3, 0.0, 0.34), (-0.16, 0.06, 0.44), (0.0, 0.1, 0.5), (0.15, 0.07, 0.46),
                          (0.3, 0.0, 0.38)):
        out = 1.0 + 0.6 * abs(x)
        h.lock([(x * 0.8, 5.96, -0.12), (x * out, 6.04 + lift, -0.04), (x * out * 1.08, 6.04 + lift * 0.8, back * 0.4),
                (x * out * 1.2, 5.94 + lift * 0.4, back), (x * out * 1.4, 5.98 + lift * 0.4, back + 0.14)],
               0.24, 0.13, "hair", name="Lock", sides=6)
    # strands falling to the sides, and a fringe over her right brow
    for s in (-1, 1):
        h.lock([(s * 0.22, 5.98, -0.12), (s * 0.36, 5.92, -0.08), (s * 0.42, 5.8, -0.02)], 0.16, 0.08, "hair",
               name="SideLock", sides=6)
    h.lock([(0.08, 5.96, -0.24), (0.22, 5.92, -0.38), (0.32, 5.76, -0.37), (0.36, 5.64, -0.32)], 0.18, 0.09, "hair",
           name="Fringe", sides=6)


def goggles(h):
    h.band((0, 5.8, 0.02), (0, 1, 0.12), 0.07, "leather", thickness=0.03, name="GoggleStrap", reach=0.6)
    mb = h.builder()
    for s in (-1, 1):
        rot = (70, 0, s * 8)
        mb.cylinder((s * 0.15, 5.9, -0.34), 0.11, 0.1, "brass", rotation=rot, segments=16)
        mb.cylinder((s * 0.15, 5.915, -0.38), 0.085, 0.04, "lens", rotation=rot, segments=16)
    mb.box((0, 5.89, -0.38), (0.08, 0.05, 0.05), "brass", bevel=0.015)
    h.piece(mb, name="Goggles")
