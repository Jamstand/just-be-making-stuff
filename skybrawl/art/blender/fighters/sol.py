"""Sol, sun knight. Sword + Hammer. Sturdy armored all-rounder.

R6 style: short black curls under a gold circlet set with a sun, white plate
armor with gold trim, big rounded pauldrons crowned with gold sun rays, a
crimson tabard with a golden sun, a cream cape, and white greaves and
gauntlets. A heroic grin.
"""

import math

from fighters._blocky import (UNIT, band, body, curve, ellipse, eye, front_profile, line, panel, print_shape, ring,
                              shape, shell, star, strap)

NAME = "Sol"
UNIT = UNIT

COLORS = {
    "skin": "#7a4a2e",
    "eye": "#2a1606",
    "eye_shine": "#ffffff",
    "mouth": "#3a1410",
    "teeth": "#fbf6ea",
    "brow": "#1d1718",
    "hair": "#1d1718",
    "hair_hi": "#3a2f30",
    "plate": "#eef0f4",
    "plate_shade": "#c9ced9",
    "gold": "#e6b23a",
    "gold_light": "#ffd96e",
    "sun": "#fff1b0",
    "crimson": "#b01c31",
    "crimson_dark": "#7c1022",
    "cape": "#f3ead6",
    "cape_dark": "#d9ccb0",
    "under": "#3b3646",
    "leather": "#6b4226",
    "sole": "#2e2622",
}


def face(fb):
    for s in (-1, 1):
        eye(fb, s * 0.2, 4.64, "eye", ru=0.055, rv=0.095)
        # determined brows, angled down toward the middle
        line(fb, [(s * 0.08, 4.79), (s * 0.32, 4.84)], 0.05, "brow")
    # heroic grin
    mouth = curve(-0.18, 4.42, 0.18, 4.42, 0.02, 6) + list(reversed(curve(-0.16, 4.4, 0.16, 4.4, 0.12, 10)))
    shape(fb, mouth, "mouth", max_edge=0.03)
    shape(fb, curve(-0.15, 4.405, 0.15, 4.405, 0.02, 6) + list(reversed(curve(-0.14, 4.37, 0.14, 4.37, 0.04, 6))),
          "teeth", layer=2, max_edge=0.03)


def head_gear(fb):
    shell(fb, "hair", grow=0.06, bottom=5.0, back_bottom=4.5)
    for i in range(14):  # curls
        a = 2 * math.pi * i / 14
        r = 0.4 if i % 2 else 0.18
        fb["Head"].sphere((r * math.cos(a), 5.29, r * math.sin(a) + 0.05), (0.15, 0.1, 0.15), "hair_hi",
                          segments=10, rings=6)
    for i in range(9):  # curls around the back
        a = math.radians(70 + 220 * i / 8)
        fb["Head"].sphere((0.67 * math.sin(a), 4.85, -0.67 * math.cos(a)), (0.12, 0.13, 0.12), "hair",
                          segments=10, rings=6)
    # gold circlet with a sun on the brow
    ring(fb, "Head", 5.0, 5.1, "gold", radius=0.68)
    fb["Head"].prism(star(0, 0, 0.2, 0.1, 8), 0.06, "gold", center=(0, 5.1, -0.71))
    fb["Head"].cylinder((0, 5.1, -0.74), 0.09, 0.06, "sun", rotation=(90, 0, 0), segments=16)


def armor(fb):
    up, low = "UpperTorso", "LowerTorso"
    # breastplate: gold-edged V and a sun emblem
    for s in (-1, 1):
        strap(fb, up, (s * 0.95, 3.95), (0.0, 3.25), 0.08, "gold", layer=2)
    print_shape(fb, up, star(0, 2.95, 0.3, 0.14, 8), "gold", layer=2)
    print_shape(fb, up, ellipse(0, 2.95, 0.12, 0.12), "sun", layer=3)
    band(fb, up, 2.5, 2.6, "gold")
    panel(fb, up, -0.6, 3.75, 0.6, 3.95, "plate_shade")
    # cape from the shoulders to mid-thigh, sun on the back
    cape = [(-1.0, 4.0), (1.0, 4.0), (1.08, 1.7), (0.0, 1.62), (-1.08, 1.7)]
    fb[up].prism(cape, 0.06, "cape", center=(0, 0, 0.6), bevel=0.01)
    fb[up].prism([(-1.08, 1.84), (1.08, 1.84), (1.08, 1.7), (0.0, 1.62), (-1.08, 1.7)], 0.07, "cape_dark",
                 center=(0, 0, 0.6))
    fb[up].prism(star(0, 3.05, 0.34, 0.16, 8), 0.04, "gold", center=(0, 0, 0.645))
    # belt and crimson tabard
    band(fb, low, 2.25, 2.4, "gold", layer=2)
    front_profile(fb, low, [(-0.42, 2.4), (0.42, 2.4), (0.42, 1.62), (0.0, 1.48), (-0.42, 1.62)], -0.57, -0.53,
                  "crimson", bevel=0.01)
    fb[low].prism(star(0, 1.98, 0.18, 0.08, 8), 0.02, "gold", center=(0, 0, -0.58))
    front_profile(fb, low, [(-0.42, 2.4), (0.42, 2.4), (0.42, 1.62), (0.0, 1.48), (-0.42, 1.62)], 0.53, 0.57,
                  "crimson_dark", bevel=0.01)


def pauldrons(fb):
    for side, s in (("Left", -1), ("Right", 1)):
        arm = f"{side}UpperArm"
        x = s * 1.5
        fb[arm].loft([(x, 3.35, 0, 0.66, 0.62), (x, 3.75, 0, 0.68, 0.64), (x, 4.08, 0, 0.56, 0.52),
                      (x, 4.18, 0, 0.3, 0.28)], "plate", power=2.8, segments=24)
        fb[arm].loft([(x, 3.3, 0, 0.68, 0.64), (x, 3.42, 0, 0.69, 0.65)], "gold", power=2.8, segments=24)
        # sun-ray spikes fanning out of the top, seen from the front and the side
        for k, (rz, rx, length) in enumerate(((50, 0, 0.36), (16, -40, 0.4), (16, 40, 0.4), (4, 0, 0.52))):
            rz, rx = math.radians(-s * rz), math.radians(rx)
            d = (-math.sin(rz), math.cos(rz) * math.cos(rx), math.cos(rz) * math.sin(rx))
            base = (x + d[0] * 0.32, 3.98 + d[1] * 0.12, d[2] * 0.32)
            center = tuple(b + c * length / 2 for b, c in zip(base, d))
            fb[arm].cone(center, 0.1, length, "gold_light" if k == 3 else "gold",
                         rotation=(math.degrees(rx), 0, math.degrees(rz)), segments=4)
        lo = f"{side}LowerArm"
        band(fb, lo, 2.82, 2.9, "gold")
        band(fb, f"{side}Hand", 2.36, 2.45, "gold", grow=0.025)


def legs(fb):
    for side, s in (("Left", -1), ("Right", 1)):
        up = f"{side}UpperLeg"
        panel(fb, up, s * 0.5 - 0.38, 1.3, s * 0.5 + 0.38, 1.9, "plate")
        panel(fb, up, s * 0.5 - 0.38, 1.3, s * 0.5 + 0.38, 1.36, "gold", layer=2)
        lo = f"{side}LowerLeg"
        band(fb, lo, 1.12, 1.25, "gold")
        panel(fb, lo, s * 0.5 - 0.1, 0.62, s * 0.5 + 0.1, 1.08, "plate_shade")
        ft = f"{side}Foot"
        band(fb, ft, 0.0, 0.1, "sole")
        band(fb, ft, 0.4, 0.48, "gold")


def model(fb):
    body(fb, skin="skin", shirt="plate", pants="under", shoes="plate", sleeves="plate", forearms="plate",
         hands="plate", belt="under", shins="plate")
    face(fb)
    head_gear(fb)
    armor(fb)
    pauldrons(fb)
    legs(fb)
