"""Sol, caped powerhouse hero. Sword + Hammer. Balanced, strong.

A classic blocky avatar: spiky golden hair, sharp amber eyes and a cocky
grin. A white hero suit printed with gold trim and an orange sun on the
chest, red gloves and boots, a red belt with a sun buckle, and a long
crimson cape with a gold sun on its back hanging from gold clasps.
"""

import math

from sky import avatar as A
from sky.avatar import Cloth, Hair, anime_brow, anime_eye, anime_mouth, cape_rows, lock, shade, sheet, spike

NAME = "Sol"

SKIN = "#e9b68a"
SUIT = "#ece7dc"
GOLD = "#e8b13a"
RED = "#d23a2a"
ORANGE = "#ff8a1e"
LINE = "#3a3346"
HAIR = "#ffcc33"


def sun(c, x, y, r, color=ORANGE, rays=8, inner=None):
    """A sun emblem: a disc and pointed rays."""
    for k in range(rays):
        a = 2 * math.pi * k / rays + math.pi / rays
        ln = r * (0.75 if k % 2 else 0.55)
        tip = (x + math.cos(a) * (r + ln), y + math.sin(a) * (r + ln))
        left = (x + math.cos(a + 0.42) * r * 0.92, y + math.sin(a + 0.42) * r * 0.92)
        right = (x + math.cos(a - 0.42) * r * 0.92, y + math.sin(a - 0.42) * r * 0.92)
        c.poly([left, tip, right], color)
    c.ellipse(x, y, r, r, color)
    c.ellipse(x, y, r * 0.62, r * 0.62, inner or shade(color, 0.35))


def cape_emblem(c):
    """A gold sun on the back of the cape and a gold edge along its top."""
    sun(c, 0.5, 0.64, 0.12, GOLD, inner=shade(GOLD, 0.3))
    c.rect_(0, 0.965, 1, 1, GOLD)


def face(c, glow=None):
    for side in (1, -1):
        anime_eye(c, side, "#e39a1c", shape="sharp", glow=glow, size=1.05)
        anime_brow(c, side, "#6e4210", y=4.8, angle=0.05, width=0.045, length=0.22, arch=0.02)
    anime_mouth(c, "grin", width=1.0)
    c.stroke([(0.012, 4.47), (0.0, 4.43)], 0.012, shade(SKIN, -0.35), alpha=0.6)  # nose hint


def model(av):
    av.style("hair", Hair(HAIR, shine=0.7, strands=22))
    av.style("cape", Cloth(RED, folds=6, size=(192, 256), emblem=cape_emblem))

    # spiky golden hair: a cap over the top, a mass over the back of the head,
    # a crown of spikes and swept bangs, melted into one and carved off the
    # scalp
    mb = av.builder()
    mb.sphere((0, 5.04, 0.04), (0.7, 0.36, 0.71), "hair", segments=28, rings=14)
    mb.sphere((0, 4.74, 0.16), (0.69, 0.52, 0.6), "hair", segments=28, rings=14)
    crown = [  # (angle around from the front, height, lean up, lean out, length, radius)
        (0, 5.28, 0.9, 0.5, 0.42, 0.16), (35, 5.25, 0.8, 0.7, 0.45, 0.16), (-35, 5.25, 0.8, 0.7, 0.45, 0.16),
        (75, 5.15, 0.55, 1.0, 0.42, 0.15), (-75, 5.15, 0.55, 1.0, 0.42, 0.15),
        (115, 5.05, 0.35, 1.0, 0.45, 0.16), (-115, 5.05, 0.35, 1.0, 0.45, 0.16),
        (150, 5.0, 0.2, 1.0, 0.48, 0.17), (-150, 5.0, 0.2, 1.0, 0.48, 0.17), (180, 4.95, 0.1, 1.0, 0.5, 0.17),
        (150, 4.6, -0.4, 1.0, 0.42, 0.15), (-150, 4.6, -0.4, 1.0, 0.42, 0.15), (180, 4.55, -0.45, 1.0, 0.42, 0.15),
        (0, 5.32, 1.0, -0.15, 0.4, 0.14), (55, 5.3, 1.0, 0.2, 0.36, 0.13), (-55, 5.3, 1.0, 0.2, 0.36, 0.13),
    ]
    for ang, y, up, out, length, radius in crown:
        p, n = av.head_point(ang, min(y, A.HEAD_TOP - 0.02), out=0.04)
        d = n * out + A.Vector((0, up, 0))
        spike(mb, tuple(p), tuple(d), length, radius, "hair", segments=6)
    for sx in (-1, 1):  # sideburns
        top, n = av.head_point(sx * 78, 4.95, out=0.06)
        tip, _ = av.head_point(sx * 74, 4.52, out=0.06)
        lock(mb, [tuple(top), tuple((top + tip) / 2 + n * 0.03), tuple(tip)], 0.11, "hair", segments=6)
    for ang, drop in ((-24, 0.2), (6, 0.26), (30, 0.18)):  # swept bangs, stopping above the brows
        top, n = av.head_point(ang, 5.1, out=0.07)
        tip, _ = av.head_point(ang + 14, 5.1 - drop, out=0.085)
        mid = (top + tip) / 2 + n * 0.05
        lock(mb, [tuple(top), tuple(mid), tuple(tip)], 0.1, "hair", segments=6)
    av.piece(A.melt(mb, voxel=0.022, smooth=4, tris=3600, carve_head=True), bone="Neck", name="Hair")

    # the cape, on a sway chain down the back
    cape = av.sway("Cape", "Waist", [(0, 3.96, 0.6), (0, 3.0, 0.66), (0, 2.0, 0.74), (0, 1.0, 0.82),
                                     (0, 0.5, 0.86)], stiffness=0.26, damping=0.16, limit=70, behind=1)
    mb = av.builder()
    sheet(mb, cape_rows(3.98, 0.5, 0.92, 1.25, 0.58, 0.86, rows=9, cols=9, curve=0.06), 0.06, "cape")
    av.piece(mb, sway=cape, name="Cape")


def paint(av, p):
    # skin first, then the suit
    p.head.fill(SKIN)
    for limb in p.limbs.values():
        limb.fill(SUIT)
    t = p.torso
    # chest: soft muscle shading and a gold collar line
    f = t.front
    f.stroke([(-0.75, 3.38), (-0.35, 3.3), (0.0, 3.36)], 0.05, shade(SUIT, -0.18), alpha=0.7)
    f.stroke([(0.75, 3.38), (0.35, 3.3), (0.0, 3.36)], 0.05, shade(SUIT, -0.18), alpha=0.7)
    for y in (3.0, 2.78):
        for sx in (-1, 1):
            f.stroke([(sx * 0.08, y), (sx * 0.32, y + 0.02)], 0.035, shade(SUIT, -0.14), alpha=0.6)
    f.stroke([(0, 2.62), (0, 3.25)], 0.03, shade(SUIT, -0.14), alpha=0.5)
    f.poly([(-0.42, 4.0), (0.0, 3.62), (0.42, 4.0), (0.3, 4.0), (0.0, 3.74), (-0.3, 4.0)], GOLD)
    f.poly([(-0.3, 4.0), (0.0, 3.74), (0.3, 4.0)], SKIN)
    sun(f, 0.0, 3.2, 0.2)
    for sx in (-1, 1):  # clasps
        f.ellipse(sx * 0.72, 3.88, 0.1, 0.1, GOLD)
        f.ellipse(sx * 0.72, 3.88, 0.05, 0.05, shade(GOLD, 0.4))
    # gold side seams
    for side in (t.right, t.left):
        side.rect_(-0.06, 2.0, 0.06, 4.0, GOLD)
    # top of the shoulders: gold straps toward the cape
    for sx in (-1, 1):
        t.top.rect_(sx * 0.72 - 0.08, -0.5, sx * 0.72 + 0.08, 0.5, GOLD)
    # belt with a sun buckle
    t.band(2.08, 2.38, RED)
    t.band(2.08, 2.12, shade(RED, -0.3))
    t.band(2.34, 2.38, shade(RED, 0.25))
    sun(t.front, 0.0, 2.23, 0.11, GOLD, inner=shade(GOLD, 0.35))
    t.back.stroke([(-0.6, 3.6), (0.6, 3.6)], 0.04, shade(SUIT, -0.15), alpha=0.6)

    for arm in p.arms():
        arm.band(2.0, 2.45, RED)  # gloves
        arm.band(2.42, 2.54, GOLD)
        arm.band(2.0, 2.06, shade(RED, -0.25))
        o = arm.outer
        o.rect_(-0.07, 2.54, 0.07, 4.0, GOLD)  # stripe down the outer arm
        for fc in arm.sides:
            fc.stroke([(-0.5, 2.9), (0.5, 2.9)], 0.03, shade(SUIT, -0.15), alpha=0.5)  # elbow crease
        for fc in (arm.front, arm.back):  # sleeve folds
            fc.stroke([(-0.3, 3.15), (0.1, 3.05), (0.35, 3.12)], 0.035, shade(SUIT, -0.16), alpha=0.6)
            fc.stroke([(-0.25, 2.7), (0.2, 2.62)], 0.03, shade(SUIT, -0.14), alpha=0.5)
        arm.bottom.fill(shade(RED, -0.1))
    for leg in p.legs():
        leg.band(0.0, 0.78, RED)  # boots
        leg.band(0.72, 0.84, GOLD)
        leg.band(0.0, 0.1, shade(RED, -0.4))
        leg.outer.rect_(-0.07, 0.84, 0.07, 2.0, GOLD)
        for fc in leg.sides:
            fc.stroke([(-0.5, 1.25), (0.5, 1.25)], 0.03, shade(SUIT, -0.15), alpha=0.5)  # knee crease
        leg.front.stroke([(-0.25, 1.05), (0.25, 1.05)], 0.05, shade(SUIT, -0.1), alpha=0.6)
        for fc in (leg.front, leg.back):  # trouser folds
            fc.stroke([(-0.3, 1.55), (0.05, 1.45), (0.3, 1.5)], 0.035, shade(SUIT, -0.15), alpha=0.55)
            fc.stroke([(-0.2, 1.85), (0.25, 1.78)], 0.03, shade(SUIT, -0.12), alpha=0.45)
        leg.bottom.fill(shade(RED, -0.45))
    # head: hair color under the hairdo, sideburns, the face
    p.head.top.fill(HAIR)  # under the hairdo
    face(p.head.band)
