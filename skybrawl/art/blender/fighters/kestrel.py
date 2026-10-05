"""Kestrel, sky-corsair. Sword + Bow. Fast, nimble duelist.

From the approved concept (art/concepts/Kestrel_v1.jpg): copper undercut swept
up and back, brass flight goggles pushed up on her brow, a small scar over
her left eyebrow and a confident smirk. A cropped teal corsair jacket with
gold piping and a high open collar, sleeves rolled to the forearm over a
cream shirt; a leather bandolier with a brass compass; a wine-red sash with
long tails at her right hip over a brown belt; charcoal cargo trousers with
grey thigh pouches; fingerless leather gloves; tan knee-high flight boots
with buckled straps and dark soles.
"""

import math

from sky.hero import Sway, Where, align_y

NAME = "Kestrel"
HERO = True

COLORS = {
    "skin": ("#b9784c", "skin"),
    "hair": ("#d65a1c", "hair"),
    "hair_dark": ("#7a3215", "hair"),
    "teal": ("#1e8189", "cloth"),
    "gold": ("#e2ac40", "gold"),
    "cream": ("#efe1c4", "cloth"),
    "sash": ("#98203f", "cloth"),
    "leather": ("#6b4228", "leather"),
    "glove": ("#3e2a1f", "leather"),
    "pants": ("#3a3a40", "cloth"),
    "pouch": ("#5b5e63", "cloth"),
    "boot": ("#c18a4f", "leather"),
    "sole": ("#2b211c", "leather"),
    "brass": ("#c99a3a", "metal"),
    "lens": ("#56d3d6", "gem"),
}

BODY = {"shoulders": 0.92, "chest": 0.95, "bust": 0.55, "waist": 0.88, "hips": 1.04, "arms": 0.86, "legs": 0.95,
        "neck": 0.85, "jaw": 0.86}

SWAYS = [
    Sway("Sash", "Root", [(0.5, 3.3, -0.36), (0.56, 2.85, -0.38), (0.6, 2.35, -0.34)], stiffness=0.3, damping=0.2,
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

    # cream shirt (shows at the open collar and the rolled cuffs)
    h.garment(lambda p: (torso(p, 3.55, 4.95) and p[2] < 0.0 and abs(p[0]) < 0.45)
              or (Where(p).kind == "arm" and 0.85 < Where(p).s < 1.3), "cream", gap=0.02, thickness=0.02, name="Shirt")
    # cropped jacket, open V at the front, sleeves rolled below the elbow
    def jacket(p):
        w = Where(p)
        if w.kind == "arm":
            return w.s < 1.18
        if w.kind != "torso" or not (3.62 <= p[1] <= 4.92):
            return False
        open_front = p[2] < -0.12 and abs(p[0]) < 0.06 + (p[1] - 3.62) * 0.22
        return not open_front
    h.garment(jacket, "teal", gap=0.055, thickness=0.035, hem="gold", hem_radius=0.022, name="Jacket")
    # rolled cream cuffs
    for side, s in (("Left", -1), ("Right", 1)):
        el = (s * 1.1, 3.38, 0.03)
        h.band(el, (s * 0.1, -0.9, 0.0), 0.12, "cream", thickness=0.05, flare=0.02, name="Cuff")
    # high open collar and lapels
    h.band((0, 5.0, 0.05), (0, 1, 0), 0.3, "teal", thickness=0.05, offset=0.05, flare=-0.04, arc=(75, 285),
           name="Collar")
    h.band((0, 5.15, 0.05), (0, 1, 0), 0.035, "gold", thickness=0.06, offset=0.06, arc=(75, 285), name="CollarRim")
    for s in (-1, 1):
        (lx, ly, lz), n = h.on_surface((s * 0.2, 4.5, -0.5))
        mb = h.builder()
        mb.prism([(0.0, 0.0), (s * 0.2, 0.06), (s * 0.24, -0.22), (s * 0.06, -0.5)], 0.03, "teal",
                 center=(lx + s * 0.02, ly + 0.25, lz - 0.02), rotation=(0, 0, 0), bevel=0.008)
        h.piece(mb, name="Lapel")
    # trousers
    def trousers(p):
        w = Where(p)
        return (w.kind == "torso" and p[1] < 3.45) or (w.kind == "leg" and w.s < 1.5)
    h.garment(trousers, "pants", gap=0.035, thickness=0.03, name="Trousers",
              inflate=lambda p: 0.04 * math.exp(-((p[1] - 2.2) / 0.5) ** 2))
    # knee-high boots with a folded cuff
    h.garment(lambda p: Where(p).kind == "leg" and Where(p).s > 1.25, "boot", gap=0.06, thickness=0.04, name="Boots",
              inflate=lambda p: 0.02 if p[1] < 0.45 else 0.0)
    for side, s in (("Left", -1), ("Right", 1)):
        x = s * 0.36
        h.band((x, 1.76, 0.0), (0, 1, 0), 0.24, "boot", thickness=0.05, flare=0.05, name="BootCuff")
        for y in (1.15, 0.62):
            h.band((x, y, 0.0), (0, 1, 0), 0.07, "leather", thickness=0.03, name="BootStrap")
            mb = h.builder()
            mb.box((x + s * 0.2, y, -0.06), (0.04, 0.09, 0.1), "brass", bevel=0.012)
            h.piece(mb)
        mb = h.builder()
        mb.box((x + s * 0.01, 0.05, -0.15), (0.4, 0.1, 0.9), "sole", bevel=0.03)
        h.piece(mb)
    # fists in fingerless gloves
    h.hands(palm="glove", fingers="skin", cuff="glove")
    # sash and belt
    h.band((0, 3.36, 0.02), (0, 1, 0), 0.26, "sash", thickness=0.05, flare=0.02, name="Sash")
    h.band((0, 3.24, 0.02), (0, 1, 0), 0.09, "leather", thickness=0.07, name="Belt")
    mb = h.builder()
    mb.box((0, 3.24, -0.44), (0.16, 0.12, 0.05), "brass", bevel=0.02)
    mb.sphere((0.46, 3.33, -0.36), (0.12, 0.1, 0.09), "sash", segments=12, rings=8)
    h.piece(mb, name="Buckle")
    for k, dx in enumerate((0.0, 0.08)):
        h.ribbon([(0.48 + dx, 3.3, -0.36), (0.53 + dx, 2.85, -0.38 + 0.02 * k), (0.57 + dx, 2.38 + 0.08 * k, -0.33)],
                 (0, 0, -1), 0.12, "sash", thickness=0.025, binding=("sway", SWAYS[0]), name="SashTail")
    # bandolier with a brass compass
    h.strap([(-0.6, 4.82, 0.02), (-0.2, 4.4, -0.42), (0.25, 3.8, -0.42), (0.58, 3.38, -0.32)], 0.15, "leather",
            thickness=0.03, name="Bandolier")
    h.strap([(-0.6, 4.82, 0.08), (-0.1, 4.3, 0.42), (0.3, 3.75, 0.38), (0.58, 3.38, 0.28)], 0.15, "leather",
            thickness=0.03, name="BandolierBack")
    (cx, cy, cz), n = h.on_surface((-0.24, 4.3, -0.5))
    mb = h.builder()
    rot = align_y(n)
    mb.cylinder((cx + n[0] * 0.04, cy + n[1] * 0.04, cz + n[2] * 0.04), 0.13, 0.06, "brass", rotation=rot, segments=20)
    mb.cylinder((cx + n[0] * 0.07, cy + n[1] * 0.07, cz + n[2] * 0.07), 0.1, 0.02, "cream", rotation=rot, segments=20)
    h.piece(mb, name="Compass")
    # thigh pouches
    for s in (-1, 1):
        (px, py, pz), n = h.on_surface((s * 0.62, 2.45, -0.05))
        mb = h.builder()
        mb.box((px + s * 0.07, py, pz), (0.14, 0.34, 0.3), "pouch", bevel=0.04)
        mb.box((px + s * 0.12, py + 0.12, pz), (0.06, 0.08, 0.31), "pouch", bevel=0.02)
        h.piece(mb, name="Pouch")
        h.band((s * 0.38, 2.62, 0.0), (0, 1, 0), 0.05, "leather", thickness=0.03, name="PouchStrap")
    hair(h)
    goggles(h)


def hair(h):
    # undercut: short dark fuzz on the sides and back, the long copper top swept back
    h.garment(lambda p: Where(p).kind == "head" and p[1] > 5.42 and (p[2] > -0.18 or p[1] > 5.8), "hair_dark",
              gap=0.012, thickness=0.012, smooth=3, name="Stubble", cover=False)
    h.garment(lambda p: Where(p).kind == "head" and p[1] > 5.72 and abs(p[0]) < 0.34, "hair", gap=0.05,
              thickness=0.05, smooth=4, name="HairCap", cover=False)
    # big swept-back locks: up off the hairline, back over the crown, flicking up at the nape
    for x, lift, back in ((-0.2, 0.1, 0.42), (-0.07, 0.18, 0.5), (0.07, 0.2, 0.52), (0.2, 0.12, 0.46),
                          (0.0, 0.26, 0.3)):
        h.lock([(x, 5.82, -0.36), (x * 1.1, 6.02 + lift * 0.5, -0.16), (x * 1.15, 6.08 + lift * 0.4, back * 0.3),
                (x * 1.2, 5.96 + lift * 0.3, back), (x * 1.3, 6.04 + lift * 0.3, back + 0.18)],
               0.3, 0.22, "hair", name="Lock")
    # a fringe falling over her right brow
    h.lock([(0.1, 5.92, -0.36), (0.24, 5.88, -0.43), (0.34, 5.72, -0.41), (0.38, 5.6, -0.34)], 0.2, 0.1, "hair",
           name="Fringe")
    h.lock([(0.0, 5.95, -0.38), (0.12, 5.88, -0.45), (0.2, 5.76, -0.44)], 0.16, 0.08, "hair", name="Fringe")


def goggles(h):
    h.band((0, 5.78, 0.02), (0, 1, 0.12), 0.07, "leather", thickness=0.035, name="GoggleStrap")
    mb = h.builder()
    for s in (-1, 1):
        rot = (70, 0, s * 8)
        mb.cylinder((s * 0.15, 5.86, -0.36), 0.11, 0.1, "brass", rotation=rot, segments=16)
        mb.cylinder((s * 0.15, 5.875, -0.4), 0.085, 0.04, "lens", rotation=rot, segments=16)
    mb.box((0, 5.85, -0.4), (0.08, 0.05, 0.05), "brass", bevel=0.015)
    h.piece(mb, name="Goggles")
