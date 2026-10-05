"""Yuki, frost ranger. Spear + Bow. Quick and precise.

R6 style: snow-white hair with a high ponytail and a snowflake clip, a fluffy
fur collar, a quilted ice-blue coat with a navy front and a blue sash, a
short white cape, a quiver on her back, navy gloves and leggings, and
fur-topped white boots. Gentle smile, rosy cheeks.
"""

import math

from fighters._blocky import (UNIT, band, body, curve, ellipse, eye, front_profile, line, panel, print_shape,
                              profile, shape, shell, star, strap, wrapped)

NAME = "Yuki"
UNIT = UNIT

COLORS = {
    "skin": "#f5d9c8",
    "blush": "#f4a8a6",
    "eye": "#24324f",
    "eye_shine": "#ffffff",
    "lash": "#2a3550",
    "mouth": "#b85c6c",
    "brow": "#9aa6be",
    "hair": "#eef2f8",
    "hair_dark": "#c6d0e2",
    "coat": "#a9d3ef",
    "coat_dark": "#86b8de",
    "navy": "#26346a",
    "navy_dark": "#19244b",
    "sash": "#3d78c2",
    "fur": "#fbf8f1",
    "fur_dark": "#dfd8cb",
    "cape": "#eef2f8",
    "silver": "#c8d3e0",
    "crystal": "#8eeaff",
    "leather": "#7a5236",
    "leather_dark": "#553722",
    "fletch": "#5fa8dd",
    "boot": "#dbe4ef",
    "boot_dark": "#b2c1d4",
    "sole": "#3a4562",
}


def face(fb):
    for s in (-1, 1):
        eye(fb, s * 0.2, 4.62, "eye", ru=0.06, rv=0.1)
        # lashes flicking out at the outer corners
        line(fb, [(s * 0.24, 4.7), (s * 0.31, 4.75)], 0.03, "lash")
        line(fb, curve(s * 0.1, 4.79, s * 0.3, 4.8, -0.03, 6), 0.035, "brow")
        shape(fb, ellipse(s * 0.33, 4.48, 0.08, 0.045), "blush")
    line(fb, curve(-0.1, 4.4, 0.1, 4.4, 0.05, 8), 0.04, "mouth")


def hair(fb):
    shell(fb, "hair", grow=0.07, bottom=4.98, back_bottom=4.45)
    # side-swept bangs and locks framing the face
    wrapped(fb, [(-0.5, 5.12), (0.5, 5.14), (0.56, 4.94), (0.36, 4.98), (0.2, 4.86), (0.06, 4.98), (-0.12, 4.9),
                 (-0.3, 4.98), (-0.5, 4.92)], "hair", out=0.13, inner=0.0)
    for s in (-1, 1):
        wrapped(fb, [(s * 0.5, 5.02), (s * 0.66, 5.02), (s * 0.66, 4.3), (s * 0.58, 4.2), (s * 0.52, 4.5)], "hair",
                out=0.12, inner=0.0)
        wrapped(fb, [(s * 0.58, 4.6), (s * 0.66, 4.6), (s * 0.66, 4.3), (s * 0.6, 4.24)], "hair_dark", out=0.125,
                inner=0.05)
    # high ponytail with a navy tie
    fb["Head"].box((0, 5.12, 0.66), (0.3, 0.24, 0.2), "navy", bevel=0.05)
    profile(fb, "Head", [(0.66, 5.24), (0.95, 5.22), (1.1, 4.8), (1.04, 4.2), (0.86, 3.8), (0.78, 4.1), (0.84, 4.6),
                         (0.7, 5.0)], -0.2, 0.2, "hair", bevel=0.04)
    profile(fb, "Head", [(0.8, 4.3), (0.98, 4.25), (0.9, 3.9), (0.84, 3.95)], -0.12, 0.12, "hair_dark")
    # snowflake clip over her left ear
    wrapped(fb, star(-0.58, 5.0, 0.12, 0.05, 6), "crystal", out=0.12, inner=0.06, max_edge=0.03)


def coat(fb):
    up, low = "UpperTorso", "LowerTorso"
    # navy front placket with silver toggles, quilting lines
    panel(fb, up, -0.16, 2.5, 0.16, 3.9, "navy")
    for y in (2.8, 3.15, 3.5):
        panel(fb, up, -0.07, y - 0.05, 0.07, y + 0.05, "silver", layer=2)
    for y in (2.95, 3.35):
        for x0, x1 in ((-1.0, -0.2), (0.2, 1.0)):
            panel(fb, up, x0, y - 0.025, x1, y + 0.025, "coat_dark")
    for y in (2.95, 3.35):
        panel(fb, up, -1.0, y - 0.025, 1.0, y + 0.025, "coat_dark", face="back")
    # fur collar
    fb[up].loft([(0, 3.86, 0, 0.82, 0.6), (0, 4.0, 0, 0.86, 0.64), (0, 4.14, 0, 0.78, 0.58)], "fur", power=2.6,
                segments=20)
    for i in range(10):
        a = 2 * math.pi * i / 10
        fb[up].sphere((0.82 * math.cos(a), 4.0, 0.62 * math.sin(a)), (0.16, 0.13, 0.14), "fur", segments=10,
                      rings=6)
    # short cape on the back, under the collar
    front_profile(fb, up, [(-0.95, 3.95), (0.95, 3.95), (1.0, 2.55), (0.5, 2.62), (0.0, 2.5), (-0.5, 2.62),
                           (-1.0, 2.55)], 0.54, 0.6, "cape", bevel=0.01)
    # quiver across the back, arrows over her right shoulder
    fb[up].cylinder((0.25, 3.2, 0.78), 0.2, 1.3, "leather", rotation=(0, 0, -28), segments=14)
    fb[up].cylinder((0.25, 3.2, 0.78), 0.215, 0.12, "leather_dark", rotation=(0, 0, -28), segments=14)
    for dx, dz in ((0.0, 0.0), (0.08, 0.08), (-0.06, 0.07)):
        fb[up].box((0.6 + dx, 4.0, 0.76 + dz), (0.06, 0.32, 0.12), "fletch", bevel=0.01, rotation=(0, 0, -28))
    strap(fb, up, (-0.9, 3.95), (0.95, 2.6), 0.14, "leather", layer=3)
    # sash with a snowflake emblem
    band(fb, low, 2.18, 2.38, "navy_dark", layer=2)
    print_shape(fb, low, star(0, 2.28, 0.15, 0.06, 6), "silver", layer=4)
    for side in ("Left", "Right"):
        for y in (3.1, 3.4):
            band(fb, f"{side}UpperArm", y - 0.025, y + 0.025, "coat_dark")
        band(fb, f"{side}LowerArm", 2.45, 2.6, "fur", grow=0.05)


def legs(fb):
    for side, s in (("Left", -1), ("Right", 1)):
        lo = f"{side}LowerLeg"
        band(fb, lo, 1.02, 1.25, "fur", grow=0.06)
        band(fb, lo, 0.7, 0.76, "boot_dark")
        ft = f"{side}Foot"
        band(fb, ft, 0.0, 0.1, "sole")
        panel(fb, ft, s * 0.5 - 0.46, 0.1, s * 0.5 + 0.46, 0.3, "boot_dark")


def model(fb):
    body(fb, skin="skin", shirt="coat", pants="navy", shoes="boot", sleeves="coat", forearms="coat", hands="navy",
         belt="sash", shins="boot")
    face(fb)
    hair(fb)
    coat(fb)
    legs(fb)
