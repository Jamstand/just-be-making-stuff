"""Sol, sun knight. Sword + Hammer. Balanced, strong.

From the approved concept (art/concepts/Sol_v1.jpg): dark brown skin, short
black curls, a gold circlet with an amber sun gem, warm amber eyes and a
confident grin. White plate armor with gold trim: a breastplate with a high
collar, huge rounded pauldrons crowned with golden sun-ray spikes, armored
forearms and gauntlets, thigh plates, sun-stamped knee cops, greaves and
gold-toed sabatons, over a dark padded undersuit. A crimson tabard with a
golden sun hangs to a point below the knees; a cream cape with gold trim
and a sun falls behind; a gold sun brooch at the collar and a belt of gold
medallions.
"""

import math

from mathutils import Matrix, Vector

from sky.hero import Sway, Where, surface_frame

NAME = "Sol"
HERO = True

COLORS = {
    "skin": ("#6e4129", "skin"),
    "hair": ("#1b1513", "hair"),
    "plate": ("#f0ebe1", "plate"),
    "gold": ("#e2aa3c", "gold"),
    "red": ("#9e2124", "cloth"),
    "under": ("#272b3b", "quilt"),
    "cape": ("#efe4c9", "cloth"),
    "amber": ("#ff9d1c", "gem"),
    "leather": ("#5a3020", "leather"),
}

BODY = {"shoulders": 1.04, "chest": 1.1, "waist": 0.95, "hips": 1.0, "arms": 1.04, "legs": 1.04, "neck": 1.15,
        "jaw": 1.04}

SWAYS = [
    Sway("Cape", "Waist", [(0, 4.84, 0.4), (0, 3.86, 0.58), (0, 2.66, 0.68), (0, 1.38, 0.74)], stiffness=0.28,
         damping=0.16, limit=70, behind=1, width=0.8),
    Sway("Tabard", "Root", [(0, 3.46, -0.52), (0, 2.66, -0.56), (0, 1.86, -0.56)], stiffness=0.35, damping=0.22,
         limit=55, behind=-1),
]


def sun(mb, center, normal, up, radius, color, rays=8, length=None, gem=None, depth=0.03):
    """A sun emblem lying on a surface: a disk and pointed rays."""
    n = Vector(normal).normalized()
    rot = surface_frame(n, up)
    c = Vector(center) + n * depth * 0.5
    mb.cylinder(tuple(c), radius, depth, color, rotation=rot, segments=12)
    if gem:
        mb.sphere(tuple(c + n * depth * 0.6), (radius * 0.55, radius * 0.3, radius * 0.55), gem, rotation=rot,
                  segments=8, rings=5)
    length = length or radius * 1.3
    a, t1 = rot.col[2], rot.col[0]
    for k in range(rays):
        th = 2 * math.pi * k / rays
        d = a * math.cos(th) + t1 * math.sin(th)
        ln = length * (1.0 if k % 2 == 0 else 0.6)
        r = Matrix((d.cross(n).normalized(), d, n)).transposed()
        mb.box(tuple(c + d * (radius + ln / 2 - 0.01)), (radius * 0.5, ln, depth * 0.8), color, rotation=r,
               taper=(0.05, 1.0), bevel=0)


def face(h):
    def extras(c, cx, ey):
        for s in (-1, 1):
            c.ellipse(cx + s * 0.21, ey - 0.14, 0.07, 0.04, "#a04a32", alpha=0.25)
    h.face(eyes="#c98b1c", brows="#1b1513", lips="#4e2419", mouth="grin", brow_tilt=(0.03, 0.03), extras=extras)


def model(h):
    h.body(garment_tris=3000)
    face(h)
    torso = lambda p: Where(p).kind == "torso"
    h.tint(lambda p: Where(p).kind in ("torso", "arm", "leg"), "under")  # the padded undersuit
    # breastplate with a high collar
    h.garment(lambda p: torso(p) and 3.52 < p[1] < 4.98, "plate", gap=0.06, thickness=0.06, smooth=5, hem="gold",
              hem_radius=0.03, name="Breastplate")
    h.band((0, 5.02, 0.04), (0, 1, 0), 0.2, "plate", thickness=0.05, offset=0.02, flare=-0.02, name="Collar")
    h.band((0, 5.12, 0.04), (0, 1, 0), 0.035, "gold", thickness=0.07, offset=0.02, name="CollarRim")
    tabard(h)
    # belt of gold medallions
    h.band((0, 3.5, 0.02), (0, 1, 0), 0.12, "leather", thickness=0.06, name="Belt")
    mb = h.builder()
    for x, z in ((0.0, -1.0), (-0.5, -0.6), (0.5, -0.6)):
        (bx, by, bz), n = h.on_surface((x, 3.5, z))
        sun(mb, (bx, by, bz), n, (0, 1, 0), 0.075, "gold", rays=8, length=0.03)
    h.piece(mb, name="Medallions")
    arms(h)
    legs(h)
    cape(h)
    head(h)


def tabard(h):
    # the chest part lies on the breastplate; below the belt it hangs free to a point
    xs = (-0.27, -0.13, 0.0, 0.13, 0.27)
    chest = []
    for y in (4.66, 4.1, 3.5):
        row = []
        for x in xs:
            (sx, sy, sz), n = h.on_surface((x, y, -0.9))
            row.append((x, y, sz - 0.012))
        chest.append(row)
    h.panel(chest, "red", thickness=0.025, name="TabardChest", hem="gold", hem_edges=("left", "right"), cols=8,
            steps=8)
    low = SWAYS[1]
    rows = [[(x, 3.46, chest[-1][i][2] - 0.01) for i, x in enumerate(xs)],
            [(x * 1.04, 2.66, -0.56) for x in xs],
            [(x * 1.04, 2.1, -0.56) for x in xs],
            [(x * 0.08, 1.86 + 0.0 * x, -0.56) for x in xs]]
    h.panel(rows, "red", thickness=0.03, binding=("sway", low), name="Tabard", hem="gold", cols=9, steps=10)
    mb = h.builder()
    (cx, cy, cz), n = h.on_surface((0, 4.2, -0.9))
    sun(mb, (0, 4.2, cz - 0.01), (0, 0, -1), (0, 1, 0), 0.1, "gold", rays=8, length=0.17, depth=0.02)
    h.piece(mb, name="TabardSun")
    # sun brooch at the collar
    mb = h.builder()
    (bx, by, bz), n = h.on_surface((0.26, 4.8, -0.9))
    sun(mb, (bx, by, bz), n, (0, 1, 0), 0.07, "gold", rays=8, length=0.05, gem="amber")
    h.piece(mb, name="Brooch")


def arms(h):
    for side, s in (("Left", -1), ("Right", 1)):
        sh = (s * 0.84, 4.64, 0.04)
        el, wr = (s * 1.04, 3.74, 0.04), (s * 1.13, 2.98, 0.04)
        fore = lambda t: (el[0] + (wr[0] - el[0]) * t, el[1] + (wr[1] - el[1]) * t, 0.04)
        upper = lambda t: (sh[0] + (el[0] - sh[0]) * t, sh[1] + (el[1] - sh[1]) * t, 0.04)
        # vambrace and rerebrace with gold rims, an elbow cop
        h.band(fore(0.55), (s * 0.09, -0.76, 0), 0.56, "plate", thickness=0.035, flare=0.03, name="Vambrace")
        h.band(fore(0.27), (s * 0.09, -0.76, 0), 0.035, "gold", thickness=0.06, name="VambraceRim")
        h.band(upper(0.6), (s * 0.2, -0.9, 0), 0.3, "plate", thickness=0.03, name="Rerebrace")
        mb = h.builder()
        mb.sphere((el[0] + s * 0.02, el[1], el[2] + 0.12), (0.17, 0.17, 0.12), "plate", segments=10, rings=6)
        mb.cylinder((el[0] + s * 0.02, el[1], el[2] + 0.23), 0.07, 0.03, "gold", rotation=(90, 0, 0), segments=10)
        h.piece(mb, name="ElbowCop")
        # pauldron: a big rounded shell over the shoulder, crowned with sun rays
        mb = h.builder()
        c = Vector((s * 0.92, 4.58, 0.04))
        rx, ry, rz = 0.44, 0.34, 0.46
        mb.sphere(tuple(c), (rx, ry, rz), "plate", segments=16, rings=9, clip=[((0, 4.36, 0), (0, 1, 0))])
        f = math.sqrt(1 - ((4.37 - c.y) / ry) ** 2)
        mb.torus((c.x, 4.38, c.z), rx * f, 0.035, "gold", segments=16, sides=5, scale=(1.0, rz / rx))
        for k, (beta, dz) in enumerate(((12, 0.1), (38, -0.12), (62, 0.12), (86, -0.06))):  # rays fanning up and out
            b = math.radians(beta)
            d = Vector((s * math.sin(b), math.cos(b), dz)).normalized()
            base = c + Vector((d.x * rx * 0.85, d.y * ry * 0.85, d.z * rz * 0.85))
            ln = 0.34 if k % 2 == 0 else 0.28
            mb.cone(tuple(base + d * ln * 0.45), 0.075, ln, "gold",
                    rotation=Vector((0, 1, 0)).rotation_difference(d).to_matrix(), segments=6)
        sun(mb, tuple(c + Vector((s * rx * 0.97, -0.02, 0.0))), (s, 0.15, 0), (0, 1, 0), 0.09, "gold", rays=8,
            length=0.08)
        h.piece(mb, binding=("bone", f"{side}Shoulder"), name="Pauldron")
    h.hands(palm="plate", fingers="plate", cuff="gold", scale=1.2)


def legs(h):
    # thigh plates, knee cops with suns, greaves and sabatons
    h.garment(lambda p: Where(p).kind == "leg" and 2.25 < p[1] < 3.3 and p[2] < 0.12, "plate", gap=0.07,
              thickness=0.05, smooth=4, name="Tassets")
    mb = h.builder()
    for s in (-1, 1):
        (kx, ky, kz), n = h.on_surface((s * 0.35, 1.86, -0.3))
        mb.sphere((kx, ky, kz + 0.04), (0.2, 0.22, 0.12), "plate", segments=12, rings=7)
        sun(mb, (kx, ky, kz - 0.06), (0, 0, -1), (0, 1, 0), 0.07, "gold", rays=8, length=0.07)
    h.piece(mb, name="KneeCops")
    h.boots("plate", "gold", top=1.68, toe="gold", cuff="gold", cuff_height=0.05, width=1.14, gap=0.07)


def cape(h):
    sway = SWAYS[0]
    xs = (-0.56, -0.28, 0.0, 0.28, 0.56)
    top = []
    for x in xs:
        (sx, sy, sz), n = h.on_surface((x, 4.84, 0.9))
        top.append((x, 4.84, sz + 0.02))
    rows = [top,
            [(x * 1.12, 3.86, 0.58 - 0.1 * x * x) for x in xs],
            [(x * 1.3, 2.66, 0.68 - 0.12 * x * x) for x in xs],
            [(x * 1.36, 1.38, 0.74 - 0.12 * x * x) for x in xs]]
    h.panel(rows, "cape", thickness=0.035, binding=("sway", sway), name="Cape", hem="gold", cols=11, steps=14)
    mb = h.builder()
    sun(mb, (0.0, 3.3, 0.66), (0, 0, 1), (0, 1, 0), 0.13, "gold", rays=8, length=0.32, depth=0.02)
    h.piece(mb, binding=("sway", sway), name="CapeSun")


def head(h):
    # short black curls
    def curls(m):
        k = 0
        for row, (y, r) in enumerate(((5.98, 0.12), (5.9, 0.24), (5.78, 0.32), (5.64, 0.36))):
            n = max(1, int(2 * math.pi * r / 0.11))
            for i in range(n):
                a = 2 * math.pi * (i + 0.5 * (row % 2)) / n
                z = 0.04 + r * math.cos(a) * 1.06
                if y < 5.7 and z < -0.12:
                    continue  # keep the forehead and temples clear
                if y < 5.84 and z < -0.24:
                    continue
                m.ball((r * math.sin(a), y + 0.02 * math.sin(k * 1.7), z), 0.085)
                k += 1
    h.blob(curls, "hair", tris=900, name="Curls")
    # gold circlet with an amber sun gem
    h.band((0, 5.8, 0.04), (0, 1, 0.08), 0.05, "gold", thickness=0.035, name="Circlet", reach=0.6)
    (cx, cy, cz), n = h.on_surface((0, 5.82, -0.9))
    mb = h.builder()
    sun(mb, (0, 5.82, cz), (0, 0.1, -1), (0, 1, 0), 0.06, "gold", rays=6, length=0.1, gem="amber")
    h.piece(mb, binding=("bone", "Neck"), name="CircletSun")
