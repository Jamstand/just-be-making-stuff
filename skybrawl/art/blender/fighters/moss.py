"""Moss, jungle druid. Scythe + Spear. Tricky, mobile.

PROVISIONAL: built from the concept brief while the concept sheet waits on
the image generator; revisit once the concept is approved.

Deep brown skin, dreadlocks tied up high with a green vine band and a pink
blossom, softly glowing green marks on the cheeks, a big friendly grin. A
layered poncho of overlapping green leaves with jagged edges over a linen
shirt, one carved-wood shoulder guard with a tiny sprouting seedling, linen
wraps on the forearms, a rope belt with seed pouches, olive trousers with
patched knees, leather-wrapped sandal-boots.
"""

import math

from sky.hero import Sway, Where

NAME = "Moss"
HERO = True

COLORS = {
    "skin": ("#5a3622", "skin"),
    "hair": ("#2c1e16", "hair"),
    "vine": ("#3f8a3a", "cloth"),
    "blossom": ("#f08ab8", "cloth"),
    "pollen": ("#ffd75a", "cloth"),
    "leaf": ("#4f9d40", "cloth"),
    "leaf_dark": ("#2f6e2c", "cloth"),
    "linen": ("#d9ccb0", "cloth"),
    "linen_dark": ("#b3a582", "cloth"),
    "wood": ("#8a5a34", "leather"),
    "sprout": ("#8ad65a", "cloth"),
    "rope": ("#b08a5a", "cloth"),
    "pouch": ("#7a5a3a", "leather"),
    "pants": ("#6b7040", "cloth"),
    "patch": ("#8c7c52", "cloth"),
    "boot": ("#6a4a30", "leather"),
    "sole": ("#3a281c", "leather"),
}

BODY = {"shoulders": 0.95, "chest": 0.92, "waist": 0.84, "hips": 0.92, "arms": 0.85, "legs": 0.92, "neck": 0.9,
        "jaw": 0.95}

SWAYS = [
    Sway("Dreads", "Neck", [(0, 6.2, 0.18), (0, 5.95, 0.5), (0, 5.5, 0.62), (0, 5.1, 0.6)], stiffness=0.25,
         damping=0.15, limit=70, behind=1, width=0.5),
]


def face(h):
    def extras(c, cx, ey):
        for s in (-1, 1):  # glowing leaf marks on the cheeks
            x = cx - s * 0.2
            c.stroke([(x - s * 0.06, ey - 0.08), (x, ey - 0.13), (x + s * 0.05, ey - 0.2)], 0.018, "#7cff9a")
            c.ellipse(x - s * 0.01, ey - 0.13, 0.025, 0.012, "#7cff9a", rotation=s * 40)
    h.face(eyes="#3b2414", brows="#1f1510", lips="#4a2218", mouth="grin", brow_tilt=(0.03, 0.03), extras=extras)


def model(h):
    h.body(garment_tris=3000)
    face(h)
    torso = lambda p: Where(p).kind == "torso"
    arm = lambda p, lo, hi: Where(p).kind == "arm" and lo <= Where(p).s < hi
    # linen shirt (short sleeves) and forearm wraps, painted on
    h.tint(lambda p: torso(p) or arm(p, 0, 0.7), "linen")
    h.tint(lambda p: arm(p, 1.0, 1.66), "linen")
    h.tint(lambda p: arm(p, 1.0, 1.66) and (Where(p).s * 6 - p[2] * 2) % 1.0 < 0.28, "linen_dark")
    # olive trousers with patched knees
    trousers = h.garment(lambda p: (torso(p) and p[1] < 3.56) or (Where(p).kind == "leg" and p[1] > 0.95), "pants",
                         gap=0.03, thickness=0.03, name="Trousers",
                         inflate=lambda p: 0.04 * math.exp(-((p[1] - 2.2) / 0.6) ** 2))
    h.tint(lambda p: abs(abs(p[0]) - 0.35) < 0.13 and abs(p[1] - 1.82) < 0.15 and p[2] < 0.0, "patch",
           target=trousers)
    # rope belt with seed pouches
    h.band((0, 3.5, 0.02), (0, 1, 0), 0.07, "rope", thickness=0.05, name="Rope")
    mb = h.builder()
    for s in (-1, 1):
        (px, py, pz), n = h.on_surface((s * 0.42, 3.36, -0.5))
        mb.sphere((px, py - 0.04, pz - 0.05), (0.1, 0.12, 0.08), "pouch", segments=10, rings=6)
        mb.cylinder((px, py + 0.07, pz - 0.05), 0.05, 0.04, "rope", segments=8)
    h.piece(mb, name="Pouches")
    # the layered leaf poncho: two ragged tiers over the shoulders and chest
    h.skirt(5.04, 3.98, "leaf_dark", gap=0.03, thickness=0.03, flare=0.12, name="PonchoUnder",
            binding=("bone", "Waist"), reach=0.98, rows=6, count=34, jag=0.2)
    h.skirt(5.06, 4.36, "leaf", gap=0.07, thickness=0.03, flare=0.1, name="Poncho", binding=("bone", "Waist"),
            reach=0.98, rows=5, count=30, jag=0.16)
    # carved wood shoulder guard with a sprouting seedling, on the left
    mb = h.builder()
    mb.sphere((-0.92, 4.62, 0.04), (0.36, 0.26, 0.38), "wood", segments=14, rings=8, clip=[((0, 4.44, 0), (0, 1, 0))])
    mb.torus((-0.92, 4.46, 0.04), 0.3, 0.03, "vine", segments=14, sides=5, scale=(1.0, 1.05))
    mb.cylinder((-0.98, 4.95, 0.02), 0.012, 0.16, "sprout", segments=5)
    for d in (-1, 1):
        mb.sphere((-0.98 + d * 0.05, 5.03, 0.02), (0.055, 0.018, 0.03), "sprout", rotation=(0, 0, d * 25), segments=8,
                  rings=4)
    h.piece(mb, binding=("bone", "LeftShoulder"), name="ShoulderGuard")
    # wrapped sandal-boots
    h.boots("boot", "sole", top=1.05, width=1.02, gap=0.06)
    for s in (-1, 1):
        for y in (0.95, 0.75, 0.55):
            h.band((s * 0.37, y, 0.0), (0, 1, 0.15 * (1 if y > 0.7 else -1)), 0.05, "rope", thickness=0.025,
                   name="Wrap")
    h.hands(palm="skin", fingers="skin", cuff=None)
    hair(h)


def hair(h):
    # dreadlocks gathered high in a knot, falling down the back
    h.garment(lambda p: Where(p).kind == "head" and p[1] > 5.74 - 0.3 * max(0.0, min(1.0, (p[2] + 0.1) / 0.4)),
              "hair", gap=0.03, thickness=0.03, smooth=3, name="HairCap")

    def knot(m):
        m.ball((0, 6.12, 0.08), (0.2, 0.15, 0.2))
        m.ball((0.06, 6.2, 0.14), (0.14, 0.12, 0.14))
    h.blob(knot, "hair", tris=400, name="TopKnot", binding=("bone", "Neck"))
    h.band((0, 6.03, 0.08), (0, 1, 0), 0.07, "vine", thickness=0.03, name="VineBand", reach=0.4)
    dreads = SWAYS[0]
    for k, (dx, dz) in enumerate(((-0.16, 0.0), (-0.06, 0.05), (0.06, 0.05), (0.16, 0.0), (-0.1, -0.06),
                                  (0.1, -0.06))):
        pts = [(x + dx * (0.4 + 0.6 * i / 3), y - 0.04 * (k % 2) * i, z + dz * (i / 3))
               for i, (x, y, z) in enumerate(dreads.points)]
        h.lock(pts, 0.1, 0.09, "hair", binding=("sway", dreads), name="Dread", sides=5, taper=0.5)
    # a pink blossom tucked in the band
    mb = h.builder()
    c = (0.2, 6.06, -0.08)
    for k in range(5):
        a = 2 * math.pi * k / 5
        mb.sphere((c[0] + 0.05 * math.cos(a), c[1] + 0.05 * math.sin(a), c[2] - 0.02), (0.045, 0.045, 0.02), "blossom",
                  segments=8, rings=4)
    mb.sphere((c[0], c[1], c[2] - 0.035), 0.025, "pollen", segments=6, rings=4)
    h.piece(mb, binding=("bone", "Neck"), name="Blossom")
