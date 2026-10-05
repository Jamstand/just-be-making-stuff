"""Kestrel, sky-corsair. Sword + Bow. Fast, nimble duelist.

R6 style: copper swept hair with flight goggles pushed up, a cropped teal
corsair jacket with gold piping over a cream shirt, a leather bandolier with
a brass compass, a wine-red sash, charcoal cargo trousers and tan flight
boots. Confident smirk, a little scar over her left brow.
"""

from fighters._blocky import (UNIT, band, body, curve, eye, line, panel, profile, print_shape, ring, shell, side_panel,
                              strap, wrapped)

NAME = "Kestrel"
UNIT = UNIT

COLORS = {
    "skin": "#b0703f",
    "hair": "#d0581f",
    "hair_dark": "#953a16",
    "eye": "#1d1512",
    "eye_shine": "#ffffff",
    "mouth": "#3a1a14",
    "brow": "#6a2a12",
    "scar": "#e0ad8a",
    "teal": "#1f8a92",
    "teal_dark": "#156168",
    "gold": "#e8b244",
    "cream": "#f1e5c6",
    "sash": "#9a2244",
    "sash_dark": "#6c1730",
    "leather": "#74452a",
    "leather_dark": "#4d2d18",
    "pants": "#3d3f44",
    "pants_dark": "#2b2c30",
    "boot": "#cc9150",
    "boot_dark": "#9d6a35",
    "sole": "#4b3021",
    "brass": "#d1a43e",
    "lens": "#8fe0e6",
}


def face(fb):
    for u in (-0.2, 0.2):
        eye(fb, u, 4.63, "eye")
    # her left brow cocked up, the right one level: a confident look
    line(fb, curve(-0.31, 4.83, -0.1, 4.8, -0.03), 0.045, "brow")
    line(fb, curve(0.1, 4.79, 0.31, 4.77, -0.015), 0.045, "brow")
    # smirk: flat on her left, curling up on her right
    line(fb, [(-0.13, 4.38), (-0.02, 4.365), (0.08, 4.37), (0.15, 4.395), (0.19, 4.43)], 0.04, "mouth")
    line(fb, [(-0.36, 4.86), (-0.28, 4.68)], 0.03, "scar", layer=2)


def hair(fb):
    shell(fb, "hair", grow=0.07, bottom=4.98, back_bottom=4.32)
    # swept fringe over her right temple, a lock on the left
    wrapped(fb, [(-0.42, 5.12), (0.05, 5.16), (0.5, 5.1), (0.66, 4.84), (0.52, 4.9), (0.44, 4.72), (0.34, 4.9),
                 (0.16, 4.94), (-0.1, 4.98), (-0.42, 4.98)], "hair", out=0.13, inner=0.0)
    wrapped(fb, [(-0.66, 5.0), (-0.48, 5.02), (-0.5, 4.7), (-0.64, 4.62)], "hair", out=0.11, inner=0.0)
    # tufts swept back over the crown
    profile(fb, "Head", [(-0.35, 5.2), (0.15, 5.42), (0.6, 5.36), (0.2, 5.22)], -0.24, 0.12, "hair")
    profile(fb, "Head", [(-0.1, 5.22), (0.4, 5.38), (0.75, 5.2), (0.4, 5.1)], 0.1, 0.4, "hair_dark")
    profile(fb, "Head", [(0.1, 5.0), (0.62, 5.12), (0.8, 4.86), (0.5, 4.8)], -0.3, 0.3, "hair")


def goggles(fb):
    ring(fb, "Head", 5.02, 5.12, "leather_dark", radius=0.69)
    for x in (-0.21, 0.21):
        fb["Head"].cylinder((x, 5.14, -0.68), 0.16, 0.14, "brass", rotation=(68, 0, 0), segments=18)
        fb["Head"].cylinder((x, 5.15, -0.72), 0.12, 0.08, "lens", rotation=(68, 0, 0), segments=18)
    fb["Head"].box((0, 5.12, -0.72), (0.14, 0.07, 0.08), "brass", bevel=0.02)


def jacket(fb):
    up = "UpperTorso"
    # open front: cream shirt V with gold piping
    print_shape(fb, up, [(-0.5, 4.0), (0.5, 4.0), (0.06, 3.0), (-0.06, 3.0)], "cream")
    for s in (-1, 1):
        strap(fb, up, (s * 0.5, 4.0), (s * 0.05, 3.0), 0.07, "gold", layer=2)
    band(fb, up, 2.5, 2.6, "gold")
    # high collar, open at the front
    fb[up].box((0, 4.1, 0.28), (1.2, 0.24, 0.5), "teal", bevel=0.03)
    for s in (-1, 1):
        fb[up].box((s * 0.52, 4.1, -0.12), (0.16, 0.24, 0.6), "teal", bevel=0.03)
    fb[up].box((0, 4.23, 0.28), (1.24, 0.04, 0.54), "gold", bevel=0.01)
    # bandolier from her left shoulder to her right hip, with a brass compass
    strap(fb, up, (-0.9, 3.95), (0.95, 2.6), 0.2, "leather", layer=3)
    strap(fb, up, (-0.9, 3.95), (0.95, 2.6), 0.2, "leather", face="back", layer=3)
    fb[up].cylinder((-0.35, 3.52, -0.6), 0.16, 0.08, "brass", rotation=(90, 0, 0), segments=18)
    fb[up].cylinder((-0.35, 3.52, -0.63), 0.11, 0.04, "cream", rotation=(90, 0, 0), segments=18)
    fb[up].box((-0.35, 3.54, -0.655), (0.025, 0.14, 0.01), "sash_dark", bevel=0)
    # gold yoke piping on the back
    strap(fb, up, (-1.0, 3.6), (0.0, 3.45), 0.06, "gold", face="back")
    strap(fb, up, (0.0, 3.45), (1.0, 3.6), 0.06, "gold", face="back")
    for side in ("Left", "Right"):
        arm = f"{side}UpperArm"
        band(fb, arm, 2.9, 2.98, "gold")
        lo = f"{side}LowerArm"
        for y in (2.55, 2.75):
            band(fb, lo, y - 0.04, y + 0.04, "leather_dark")
        band(fb, lo, 2.84, 2.9, "gold")


def belt(fb):
    low = "LowerTorso"
    band(fb, low, 2.17, 2.33, "leather", layer=2)
    panel(fb, low, -0.14, 2.15, 0.14, 2.35, "gold", layer=4)
    panel(fb, low, -0.07, 2.2, 0.07, 2.3, "leather", layer=5)
    # sash knot and tails over her right hip
    fb[low].box((0.62, 2.25, -0.56), (0.26, 0.24, 0.14), "sash_dark", bevel=0.05)
    fb[low].box((0.6, 1.98, -0.55), (0.16, 0.42, 0.06), "sash", bevel=0.02, rotation=(0, 0, 8))
    fb[low].box((0.76, 2.02, -0.53), (0.14, 0.34, 0.06), "sash_dark", bevel=0.02, rotation=(0, 0, -12))


def legs(fb):
    for side, s in (("Left", -1), ("Right", 1)):
        up = f"{side}UpperLeg"
        side_panel(fb, up, -0.28, 1.4, 0.24, 1.8, "pants_dark")
        side_panel(fb, up, -0.3, 1.74, 0.26, 1.84, "pants", layer=2)
        lo = f"{side}LowerLeg"
        band(fb, lo, 1.12, 1.25, "boot_dark")
        band(fb, lo, 0.78, 0.86, "leather")
        side_panel(fb, lo, -0.1, 0.76, 0.1, 0.88, "brass", layer=3)
        ft = f"{side}Foot"
        band(fb, ft, 0.0, 0.1, "sole")
        panel(fb, ft, s * 0.5 - 0.46, 0.1, s * 0.5 + 0.46, 0.36, "boot_dark")


def model(fb):
    body(fb, skin="skin", shirt="teal", pants="pants", shoes="boot", sleeves="teal", forearms="leather",
         belt="sash", shins="boot")
    face(fb)
    hair(fb)
    goggles(fb)
    jacket(fb)
    belt(fb)
    legs(fb)
