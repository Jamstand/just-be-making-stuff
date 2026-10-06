"""Yuki, frost ranger. Spear + Bow. Agile, precise.

From the approved concept (art/concepts/Yuki_v1.jpg): snow-white hair pulled
into a high ponytail with an ice-crystal clip, side-swept bangs, calm
ice-blue eyes. A quilted pale-blue coat with white piping, open over a navy
tunic with silver frog clasps, its skirt flaring to mid-thigh; a big white
fur collar; a short white capelet on her back with fur trim and a snowflake;
a royal-blue sash with a snowflake buckle and a long hanging tail; navy
gloves with silver vambraces and fur cuffs; navy leggings with knee guards;
white fur-topped boots with navy straps and chunky navy soles; a leather
quiver on her back.
"""

import math

from mathutils import Matrix, Vector

from sky.hero import Sway, Where, smoothstep, surface_frame

NAME = "Yuki"
HERO = True

COLORS = {
    "skin": ("#f2c9b1", "skin"),
    "hair": ("#eef2f7", "hair"),
    "coat": ("#a8cdef", "quilt"),
    "trim": ("#eef4fa", "cloth"),
    "navy": ("#1f2f66", "cloth"),
    "sash": ("#2c50b8", "cloth"),
    "fur": ("#f3f5f8", "fur"),
    "cape": ("#eef3f8", "cloth"),
    "ice": ("#6fb6ff", "gem"),
    "silver": ("#c4cbd4", "metal"),
    "glove": ("#25336b", "leather"),
    "knee": ("#3d4f7c", "plate"),
    "boot": ("#e8ecf1", "leather"),
    "sole": ("#22305e", "leather"),
    "leather": ("#5a3a28", "leather"),
    "fletch": ("#5c9be0", "cloth"),
}

BODY = {"shoulders": 0.88, "chest": 0.95, "bust": 0.6, "waist": 0.74, "hips": 1.05, "arms": 0.8, "legs": 0.94,
        "neck": 0.84, "jaw": 0.84}

SWAYS = [
    Sway("Ponytail", "Neck", [(0, 6.08, 0.4), (0, 5.86, 0.66), (0, 5.46, 0.76), (0, 5.04, 0.72)], stiffness=0.22,
         damping=0.14, limit=80, behind=1),
    Sway("SashTail", "Root", [(0, 3.56, -0.44), (0, 3.08, -0.47), (0, 2.6, -0.46)], stiffness=0.3, damping=0.2,
         limit=65, behind=-1),
]


def snowflake(mb, center, normal, up, size, color, depth=0.02):
    """Six crystal spokes with side ticks, lying on a surface."""
    rot = surface_frame(normal, up)
    c = Vector(center) + Vector(normal).normalized() * depth * 0.5
    for k in range(6):
        r = rot @ Matrix.Rotation(math.radians(60 * k), 3, "Y")
        mb.box(tuple(c + r @ Vector((0, 0, size * 0.5))), (size * 0.16, depth, size), color, rotation=r, bevel=0)
        for t in (0.62,):
            for d in (-1, 1):
                rt = r @ Matrix.Rotation(math.radians(d * 45), 3, "Y")
                p = c + r @ Vector((0, 0, size * t)) + rt @ Vector((0, 0, size * 0.12))
                mb.box(tuple(p), (size * 0.1, depth, size * 0.26), color, rotation=rt, bevel=0)


def face(h):
    def extras(c, cx, ey):
        for s in (-1, 1):
            c.ellipse(cx + s * 0.21, ey - 0.14, 0.08, 0.045, "#e88a8a", alpha=0.3)
    h.face(eyes="#5aa6ea", brows="#7f8c9c", lips="#c26d72", mouth="neutral", lashes=True, extras=extras)


def model(h):
    h.body(garment_tris=3000)
    face(h)
    # navy tunic and leggings, painted on
    h.tint(lambda p: Where(p).kind in ("torso", "leg"), "navy")
    # quilted coat, open down the front, sleeves to the forearm
    def coat(p):
        w = Where(p)
        if w.kind == "arm":
            return w.s < 1.45
        if w.kind != "torso" or not (3.5 <= p[1] <= 4.94):
            return False
        return not (p[2] < -0.1 and abs(p[0]) < 0.13)
    h.garment(coat, "coat", gap=0.05, thickness=0.045, hem="trim", hem_radius=0.025, name="Coat")
    h.band((0, 3.62, 0.02), (0, 1, 0), 0.22, "sash", thickness=0.05, name="Sash")
    h.skirt(3.56, 2.68, "coat", gap=0.025, thickness=0.04, flare=0.14, arc=(24, 336), hem="trim", name="CoatSkirt")
    # frog clasps down the tunic, the snowflake buckle and the sash tail
    mb = h.builder()
    for y in (4.62, 4.36, 4.1, 3.86):
        (fx, fy, fz), n = h.on_surface((0, y, -0.9))
        mb.box((0, y, fz - 0.02), (0.22, 0.04, 0.035), "silver", bevel=0.01, segments=1)
        for s in (-1, 1):
            mb.box((s * 0.12, y, fz - 0.02), (0.05, 0.05, 0.04), "silver", bevel=0)
    (bx, by, bz), n = h.on_surface((0, 3.62, -0.9))
    snowflake(mb, (0, 3.62, bz), (0, 0, -1), (0, 1, 0), 0.13, "silver", depth=0.03)
    h.piece(mb, name="Clasps")
    tail = SWAYS[1]
    h.ribbon([(0, 3.56, bz - 0.02), (0.01, 3.08, -0.47), (0.0, 2.62, -0.46)], (0, 0, -1), 0.2, "sash",
             thickness=0.025, binding=("sway", tail), name="SashTail")
    mb = h.builder()
    snowflake(mb, (0.0, 2.86, -0.49), (0, 0, -1), (0, 1, 0), 0.09, "trim", depth=0.012)
    h.piece(mb, binding=("sway", tail), name="TailFlake")
    capelet(h)
    # gloves with silver vambraces and fur cuffs
    h.hands(palm="glove", fingers="glove", cuff="silver")
    for side, s in (("Left", -1), ("Right", 1)):
        el, wr = (s * 1.04, 3.74, 0.04), (s * 1.13, 2.98, 0.04)
        mid = lambda t: (el[0] + (wr[0] - el[0]) * t, el[1] + (wr[1] - el[1]) * t, 0.04)
        h.band(mid(0.86), (s * 0.09, -0.76, 0), 0.16, "silver", thickness=0.03, name="Vambrace")
        cx, cy, cz = mid(0.66)
        ring = [(cx + 0.27 * math.cos(a), cy + s * 0.03 * math.cos(a), cz + 0.27 * math.sin(a))
                for a in (2 * math.pi * k / 10 for k in range(10))]
        h.fur(ring, 0.075, "fur", tris=260, name="CuffFur")
    # knee guards
    mb = h.builder()
    for s in (-1, 1):
        (kx, ky, kz), n = h.on_surface((s * 0.35, 1.84, -0.6))
        mb.sphere((kx, ky, kz + 0.02), (0.15, 0.19, 0.07), "knee", segments=10, rings=6)
    h.piece(mb, name="KneeGuards")
    # white boots: fur tops, navy straps with silver buckles, chunky navy soles
    h.boots("boot", "sole", top=1.3, toe="sole", width=1.06, gap=0.05)
    for s in (-1, 1):
        x = s * 0.37
        ring = [(x + 0.29 * math.cos(a), 1.32, 0.02 + 0.29 * math.sin(a)) for a in (2 * math.pi * k / 10 for k in range(10))]
        h.fur(ring, 0.09, "fur", tris=320, name="BootFur")
        for y in (0.98, 0.7):
            h.band((x, y, 0.0), (0, 1, 0), 0.07, "navy", thickness=0.03, name="BootStrap")
            mb = h.builder()
            mb.box((x + s * 0.23, y, -0.08), (0.04, 0.09, 0.1), "silver", bevel=0.012, segments=1)
            h.piece(mb, name="Buckle")
    quiver(h)
    hair(h)


def capelet(h):
    # a short white capelet on her back and shoulders, trimmed in fur, with a snowflake
    h.skirt(5.02, 4.22, "cape", gap=0.03, thickness=0.035, flare=0.06, arc=(104, 256), hem="fur", hem_radius=0.05,
            hem_sides=6, name="Capelet", binding=("bone", "Waist"), reach=0.98, rows=6, count=24)
    (cx, cy, cz), n = h.on_surface((0, 4.55, 0.9))
    mb = h.builder()
    snowflake(mb, (cx, cy, cz), n, (0, 1, 0), 0.16, "sash", depth=0.012)
    h.piece(mb, binding=("bone", "Waist"), name="CapeFlake")
    # the fur collar: a thick ruff around the neck, opening at the front
    path = [(-0.2, 4.62, -0.38), (-0.36, 4.86, -0.2), (-0.42, 4.98, 0.04), (-0.26, 5.04, 0.28), (0.0, 5.06, 0.34),
            (0.26, 5.04, 0.28), (0.42, 4.98, 0.04), (0.36, 4.86, -0.2), (0.2, 4.62, -0.38)]
    h.fur(path, 0.12, "fur", tris=700, name="Collar", closed=False, binding=("bone", "Waist"))


def quiver(h):
    a, b = Vector((-0.3, 3.72, 0.56)), Vector((0.34, 4.84, 0.6))
    mb = h.builder()
    mb.limb(tuple(a), tuple(b), 0.11, 0.12, "leather", segments=10, caps=False)
    mb.cylinder(tuple(a), 0.11, 0.02, "leather", rotation=Vector((0, 1, 0)).rotation_difference(b - a).to_matrix(),
                segments=10)
    for t in (0.12, 0.92):
        c = a.lerp(b, t)
        mb.cylinder(tuple(c), 0.13, 0.05, "silver", rotation=Vector((0, 1, 0)).rotation_difference(b - a).to_matrix(),
                    segments=10)
    d = (b - a).normalized()
    for k, (ox, oz) in enumerate(((-0.04, -0.03), (0.04, 0.0), (0.0, 0.05), (-0.05, 0.05))):
        tip = b + d * (0.24 + 0.04 * (k % 2)) + Vector((ox, 0, oz))
        mb.cylinder(tuple(b.lerp(tip, 0.5) + Vector((ox, 0, oz))), 0.012, 0.3, "leather",
                    rotation=Vector((0, 1, 0)).rotation_difference(d).to_matrix(), segments=4)
        for ang in (0, 90):
            r = Vector((0, 1, 0)).rotation_difference(d).to_matrix() @ Matrix.Rotation(math.radians(ang), 3, "Y")
            mb.box(tuple(tip - d * 0.05), (0.07, 0.12, 0.008), "fletch", rotation=r, bevel=0)
    h.piece(mb, binding=("bone", "Waist"), name="Quiver")
    h.strap([(0.42, 4.92, -0.05), (0.12, 4.42, -0.5), (-0.3, 3.9, -0.46), (-0.5, 3.74, 0.0), (-0.32, 3.72, 0.5)],
            0.09, "leather", thickness=0.025, offset=0.01, name="QuiverStrap")


def hair(h):
    def ear(p):
        return ((abs(p[0]) - 0.34) / 0.09) ** 2 + ((p[1] - 5.48) / 0.15) ** 2 + ((p[2] - 0.06) / 0.11) ** 2 < 1
    # pulled back smooth from a high forehead toward the ponytail
    h.garment(lambda p: Where(p).kind == "head" and p[1] > 5.78 - 0.32 * smoothstep(-0.25, 0.2, p[2]) and not ear(p),
              "hair", gap=0.035, thickness=0.04, smooth=4, name="HairCap")
    for x in (-0.18, -0.06, 0.06, 0.18):  # combed strands sweeping back
        h.lock([(x, 5.96, -0.3), (x * 1.2, 6.08, -0.05), (x * 0.8, 6.08, 0.2), (x * 0.3, 6.04, 0.36)], 0.16, 0.06,
               "hair", name="Strand", sides=5, taper=0.5)
    # side-swept bangs over her right brow and a lock framing each cheek
    h.lock([(-0.12, 6.02, -0.26), (0.1, 5.9, -0.38), (0.28, 5.72, -0.36), (0.36, 5.48, -0.24)], 0.22, 0.08, "hair",
           name="Bangs", sides=6)
    for s in (-1, 1):
        h.lock([(s * 0.3, 5.86, -0.18), (s * 0.38, 5.56, -0.22), (s * 0.36, 5.24, -0.16)], 0.12, 0.07, "hair",
               name="FaceLock", sides=6)
    # the high ponytail: a silver tie, an ice clip, three springy locks
    pony = SWAYS[0]
    mb = h.builder()
    mb.torus((0, 6.06, 0.38), 0.09, 0.03, "silver", rotation=(-35, 0, 0), segments=12, sides=5)
    snowflake(mb, (0.12, 6.1, 0.3), (0.6, 0.4, -0.2), (0, 1, 0), 0.12, "ice", depth=0.03)
    h.piece(mb, binding=("bone", "Neck"), name="HairTie")
    for dx, dz, w in ((0.0, 0.0, 0.3), (-0.07, -0.04, 0.2), (0.07, -0.03, 0.2)):
        pts = [(x + dx * (i / 3), y, z + dz * (i / 3)) for i, (x, y, z) in enumerate(pony.points)]
        pts[0] = (0, 6.06, 0.36)
        h.lock(pts, w, w * 0.75, "hair", binding=("sway", pony), name="Ponytail", sides=7, taper=0.1)
