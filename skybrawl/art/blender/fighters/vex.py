"""Vex, shadow rogue. Scythe + Gauntlets. Tricky, fast.

From the approved concept (art/concepts/Vex_v1.jpg): a pale young man with
glowing violet eyes and messy black hair with one purple streak, under a
deep-purple hood with a drooping point, a black mask over his nose and
mouth, and a tattered purple mantle over his shoulders. A black leather vest
with crossed straps and silver buckles over a black shirt, bandage-wrapped
forearms and fingerless gloves, a ragged purple tabard hanging front and
back from his belt, charcoal trousers with thigh straps, angular black knee
guards and black strapped boots with silver toe caps.
"""

import math

from sky.hero import Sway, Where, smoothstep

NAME = "Vex"
HERO = True

COLORS = {
    "skin": ("#e6c7b6", "skin"),
    "hair": ("#1d1a22", "hair"),
    "streak": ("#8a3ad6", "hair"),
    "purple": ("#4c2672", "cloth"),
    "purple_dark": ("#321850", "cloth"),
    "mask": ("#1f1e24", "cloth"),
    "shirt": ("#26252b", "cloth"),
    "vest": ("#2b2524", "leather"),
    "strap": ("#3b2a24", "leather"),
    "silver": ("#b9c0c8", "metal"),
    "wraps": ("#55545c", "cloth"),
    "wraps_dark": ("#3a3940", "cloth"),
    "glove": ("#1e1c20", "leather"),
    "pants": ("#34333a", "cloth"),
    "plate": ("#25242a", "plate"),
    "boot": ("#222026", "leather"),
    "sole": ("#141316", "leather"),
}

BODY = {"shoulders": 0.95, "chest": 0.95, "waist": 0.84, "hips": 0.94, "arms": 0.88, "legs": 0.95, "neck": 0.95,
        "jaw": 0.95}

SWAYS = [
    Sway("HoodTip", "Neck", [(0, 6.06, 0.3), (0, 6.02, 0.56), (0, 5.8, 0.74)], stiffness=0.3, damping=0.2, limit=50,
         behind=1),
    Sway("TabardFront", "Root", [(0, 3.44, -0.4), (0, 2.86, -0.44), (0, 2.0, -0.44)], stiffness=0.35, damping=0.22,
         limit=60, behind=-1),
    Sway("TabardBack", "Root", [(0, 3.44, 0.4), (0, 2.86, 0.46), (0, 2.0, 0.46)], stiffness=0.35, damping=0.22,
         limit=60, behind=1),
]


def face(h):
    def extras(c, cx, ey):
        for s in (-1, 1):  # the eyes glow
            c.ellipse(cx - s * 0.16, ey, 0.12, 0.075, "#b04cff", alpha=0.22)
    h.face(eyes="#b04cff", brows="#1d1a22", lips="#8a5a5a", mouth="neutral", brow_tilt=(-0.03, -0.03),
           extras=extras)


def model(h):
    h.body(garment_tris=3000)
    face(h)
    torso = lambda p: Where(p).kind == "torso"
    arm = lambda p, lo, hi: Where(p).kind == "arm" and lo <= Where(p).s < hi
    # black shirt with sleeves to the elbow, bandage wraps on the forearms
    h.tint(lambda p: torso(p) or arm(p, 0, 0.98), "shirt")
    h.tint(lambda p: arm(p, 0.98, 1.66), "wraps")
    h.tint(lambda p: arm(p, 0.98, 1.66) and (Where(p).s * 6 + p[2] * 2) % 1.0 < 0.3, "wraps_dark")
    # leather vest with a high collar
    h.garment(lambda p: torso(p) and 3.5 < p[1] < 5.0 and not (p[2] < -0.1 and p[1] > 4.9), "vest", gap=0.03,
              thickness=0.035, hem="strap", hem_radius=0.018, name="Vest")
    # crossed straps with silver buckles, and the belt
    for s in (-1, 1):
        h.strap([(s * 0.5, 4.86, -0.1), (s * 0.18, 4.4, -0.46), (-s * 0.2, 3.95, -0.44), (-s * 0.5, 3.62, -0.2)],
                0.1, "strap", thickness=0.025, offset=0.012, name="ChestStrap")
    h.band((0, 3.5, 0.02), (0, 1, 0), 0.12, "strap", thickness=0.05, name="Belt")
    mb = h.builder()
    for x, y in ((0.0, 3.5), (-0.24, 4.26), (0.24, 4.26)):
        (bx, by, bz), n = h.on_surface((x, y, -0.9))
        mb.box((x, y, bz - 0.02), (0.14, 0.12, 0.03), "silver", bevel=0.01, segments=1)
        mb.box((x, y, bz - 0.035), (0.08, 0.06, 0.02), "strap", bevel=0)
    h.piece(mb, name="Buckles")
    # ragged tabard front and back
    xs = (-0.42, -0.21, 0.0, 0.21, 0.42)
    for sway, side in ((SWAYS[1], -1), (SWAYS[2], 1)):
        top = [h.on_surface((x, 3.42, side * 0.9))[0] for x in xs]
        rows = [[(x, 3.42, z + side * 0.005) for x, (_, _, z) in zip(xs, top)],
                [(x * 1.06, 2.86, side * (0.44 - 0.15 * x * x)) for x in xs],
                [(x * 1.12, 2.0, side * (0.44 - 0.15 * x * x)) for x in xs]]
        h.panel(rows, "purple", thickness=0.035, binding=("sway", sway), name="Tabard", cols=14, jag=0.22)
    # fingerless gloves
    h.hands(palm="glove", fingers="skin", cuff="glove")
    # trousers with thigh straps, angular knee guards, strapped boots with silver toe caps
    h.garment(lambda p: (torso(p) and p[1] < 3.56) or (Where(p).kind == "leg" and p[1] > 0.95), "pants", gap=0.03,
              thickness=0.03, name="Trousers", inflate=lambda p: 0.03 * math.exp(-((p[1] - 1.5) / 0.5) ** 2))
    for s in (-1, 1):
        h.band((s * 0.36, 2.55, 0.0), (0, 1, 0), 0.07, "strap", thickness=0.03, name="ThighStrap")
    mb = h.builder()
    for s in (-1, 1):
        (kx, ky, kz), n = h.on_surface((s * 0.35, 1.84, -0.3))
        mb.box((kx, ky, kz + 0.0), (0.24, 0.24, 0.06), "silver", rotation=(0, 0, 45), bevel=0.01, segments=1)
        mb.box((kx, ky, kz - 0.02), (0.2, 0.2, 0.06), "plate", rotation=(0, 0, 45), bevel=0.015, segments=1)
    h.piece(mb, name="KneeGuards")
    h.boots("boot", "sole", top=1.3, toe="silver", gap=0.06)
    for s in (-1, 1):
        x = s * 0.37
        for y in (1.1, 0.78):
            h.band((x, y, 0.0), (0, 1, 0), 0.08, "strap", thickness=0.03, name="BootStrap")
            mb = h.builder()
            mb.box((x + s * 0.24, y, -0.06), (0.04, 0.09, 0.1), "silver", bevel=0.01, segments=1)
            h.piece(mb, name="Buckle")
    head(h)


def head(h):
    def ear(p):
        return ((abs(p[0]) - 0.34) / 0.09) ** 2 + ((p[1] - 5.48) / 0.15) ** 2 + ((p[2] - 0.06) / 0.11) ** 2 < 1
    # the mask over his nose and mouth, up to the bridge of the nose
    h.garment(lambda p: (Where(p).kind == "head" and p[1] < 5.47 - 0.15 * smoothstep(-0.1, 0.2, p[2])
                         and not ear(p)) or (Where(p).kind == "torso" and p[1] > 4.86),
              "mask", gap=0.03, thickness=0.03, smooth=3, name="Mask")
    # messy black hair under the hood
    h.garment(lambda p: Where(p).kind == "head" and p[1] > 5.72 - 0.3 * smoothstep(-0.2, 0.25, p[2]),
              "hair", gap=0.03, thickness=0.03, smooth=3, name="HairCap", cover=True)
    for x, color in ((-0.22, "hair"), (-0.1, "hair"), (0.04, "streak"), (0.17, "hair"), (0.27, "hair")):
        h.lock([(x * 0.9, 5.98, -0.26), (x, 5.88, -0.38), (x * 1.15, 5.68, -0.38)], 0.13, 0.06, color,
               name="Fringe", sides=5, taper=0.3)
    # the hood: loose around the head, open for the face, a drooping point at the back
    face_hole = lambda p: p[2] < 0.02 and (p[0] / 0.34) ** 2 + ((p[1] - 5.5) / 0.46) ** 2 < 1
    h.garment(lambda p: Where(p).kind == "head" and p[1] > 5.1 and not face_hole(p), "purple", gap=0.12,
              thickness=0.04, smooth=4, hem="purple_dark", hem_radius=0.022, name="Hood", cover=False)
    h.lock([(0, 6.04, 0.16), (0, 6.12, 0.36), (0, 6.02, 0.58), (0, 5.8, 0.76)], 0.34, 0.2, "purple",
           binding=("sway", SWAYS[0]), name="HoodTip", sides=6, taper=0.05)
    # the ragged mantle over his shoulders, open in a V at the front
    h.skirt(5.06, 4.24, "purple", gap=0.04, thickness=0.035, flare=0.14, arc=(28, 332), name="Mantle",
            binding=("bone", "Waist"), reach=1.02, rows=6, count=34, jag=0.2)
