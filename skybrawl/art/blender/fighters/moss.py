"""Moss, jungle druid. Scythe + Spear. Balanced.

R6 style: dark dreadlocks tied up high with a vine band and a pink blossom,
glowing green face marks, a big open grin, a leafy green poncho with jagged
leaf edges and leaf shoulder pads (a sprout on one), bare arms with linen
wraps, a rope belt with a seed pouch, olive trousers and leather boots.
"""

import math

from fighters._blocky import (UNIT, band, body, curve, ellipse, eye, front_profile, leaf, line, panel, print_shape,
                              ring, shape, shell, side_panel, star, wrapped)

NAME = "Moss"
UNIT = UNIT

COLORS = {
    "skin": "#7a4a2e",
    "eye": "#1c100a",
    "eye_shine": "#ffffff",
    "mouth": "#3b1611",
    "teeth": "#fbf8ef",
    "tongue": "#d0606a",
    "brow": "#1e130d",
    "glow": "#7df25e",
    "hair": "#2b1d15",
    "hair_light": "#4a3322",
    "vine": "#3f8f2f",
    "leaf": "#66bd3f",
    "leaf_dark": "#4a9a2e",
    "flower": "#ff8cc0",
    "pollen": "#ffe066",
    "poncho": "#5b8c35",
    "poncho_dark": "#426a25",
    "poncho_light": "#7aad4a",
    "wrap": "#dcc18d",
    "wrap_dark": "#b99a66",
    "rope": "#c9a262",
    "trousers": "#6c6c36",
    "trousers_dark": "#52522a",
    "leather": "#a8743f",
    "leather_dark": "#6a4322",
    "sole": "#3a2a1e",
}


def face(fb):
    for s in (-1, 1):
        eye(fb, s * 0.2, 4.66, "eye", ru=0.055, rv=0.095)
        line(fb, curve(s * 0.1, 4.82, s * 0.3, 4.84, -0.04, 6), 0.045, "brow")
        # glowing marks under the eyes
        for du in (0.0, 0.07):
            line(fb, [(s * (0.17 + du), 4.52), (s * (0.17 + du), 4.42)], 0.03, "glow")
    # big open grin: dark mouth, teeth along the top, tongue
    mouth = curve(-0.17, 4.4, 0.17, 4.4, 0.0, 4) + list(reversed(curve(-0.17, 4.4, 0.17, 4.4, 0.16, 10)))
    shape(fb, mouth, "mouth", max_edge=0.03)
    shape(fb, [(-0.15, 4.395), (0.15, 4.395), (0.13, 4.36), (-0.13, 4.36)], "teeth", layer=2, max_edge=0.03)
    shape(fb, ellipse(0.0, 4.3, 0.07, 0.03), "tongue", layer=2, max_edge=0.03)


def hair(fb):
    shell(fb, "hair", grow=0.07, bottom=5.0, back_bottom=4.5)
    ring(fb, "Head", 5.0, 5.08, "vine", radius=0.69)
    # dreadlocks hanging around the sides and back
    for i in range(11):
        a = math.radians(75 + 210 * i / 10)  # around the sides and back
        x, z = 0.66 * math.sin(a), -0.66 * math.cos(a)
        tilt = math.degrees(math.atan2(x, 1.0)) * 0.12
        fb["Head"].box((x, 4.62, z), (0.15, 0.78, 0.15), "hair" if i % 2 else "hair_light", bevel=0.05,
                       rotation=(0, -math.degrees(a), tilt))
    # dreads tied up into a crown on top
    for i in range(7):
        a = 2 * math.pi * i / 7
        fb["Head"].box((0.16 * math.cos(a), 5.48, 0.16 * math.sin(a) + 0.05), (0.15, 0.55, 0.15),
                       "hair" if i % 2 else "hair_light", bevel=0.05,
                       rotation=(math.degrees(math.sin(a)) * 0.45, 0, -math.degrees(math.cos(a)) * 0.45))
    fb["Head"].cylinder((0, 5.27, 0.05), 0.24, 0.14, "vine", segments=16)
    # blossom over the left temple
    wrapped(fb, star(-0.46, 5.08, 0.15, 0.08, 5), "flower", out=0.13, inner=0.06, max_edge=0.03)
    wrapped(fb, ellipse(-0.46, 5.08, 0.045, 0.045), "pollen", out=0.15, inner=0.1, max_edge=0.02)


def poncho(fb):
    up = "UpperTorso"
    # jagged leaf hem over the hips, front and back
    hem = [(-1.06, 2.75), (1.06, 2.75), (1.06, 2.42), (0.86, 2.26), (0.64, 2.44), (0.42, 2.2), (0.2, 2.42),
           (0.0, 2.18), (-0.2, 2.42), (-0.42, 2.2), (-0.64, 2.44), (-0.86, 2.26), (-1.06, 2.42)]
    front_profile(fb, up, hem, -0.56, 0.56, "poncho", bevel=0.01)
    # leaf collar
    for x in (-0.5, -0.25, 0.0, 0.25, 0.5):
        print_shape(fb, up, leaf((x, 4.0), (x * 1.15, 3.62), 0.26), "poncho_light", layer=2)
    for x in (-0.6, -0.2, 0.2, 0.6):
        print_shape(fb, up, leaf((x, 2.8), (x + 0.05, 3.25), 0.22), "poncho_dark", layer=2)
        print_shape(fb, up, leaf((x, 2.8), (x - 0.05, 3.25), 0.22), "poncho_dark", face="back", layer=2)
    # leaf shoulder pads, a sprout on the left one
    for side, s in (("Left", -1), ("Right", 1)):
        arm = f"{side}UpperArm"
        fb[arm].box((s * 1.5, 3.92, 0), (1.12, 0.2, 1.12), "poncho_dark", bevel=0.04)
        front_profile(fb, arm, [(s * 0.94, 3.9), (s * 2.06, 3.9), (s * 2.08, 3.6), (s * 1.86, 3.42), (s * 1.66, 3.6),
                                (s * 1.42, 3.4), (s * 1.2, 3.6), (s * 0.94, 3.45)], -0.57, 0.57, "poncho", bevel=0.01)
    arm = "LeftUpperArm"
    fb[arm].cylinder((-1.45, 4.18, 0.0), 0.04, 0.3, "vine", segments=8)
    for s in (-1, 1):
        fb[arm].prism(leaf((0, 0), (s * 0.3, 0.12), 0.14), 0.04, "leaf", center=(-1.45, 4.3, 0.0))
    # rope belt with a seed pouch
    low = "LowerTorso"
    band(fb, low, 2.3, 2.4, "rope", layer=2)
    fb[low].box((-0.25, 2.34, -0.56), (0.14, 0.14, 0.1), "rope", bevel=0.04)
    fb[low].box((0.72, 2.12, -0.56), (0.34, 0.36, 0.16), "leather", bevel=0.06)
    fb[low].box((0.72, 2.3, -0.58), (0.36, 0.06, 0.18), "leather_dark", bevel=0.02)


def limbs(fb):
    for side, s in (("Left", -1), ("Right", 1)):
        lo = f"{side}LowerArm"
        for y in (2.52, 2.66, 2.8):
            band(fb, lo, y - 0.05, y + 0.05, "wrap" if y != 2.66 else "wrap_dark", grow=0.025)
        up = f"{side}UpperLeg"
        side_panel(fb, up, -0.25, 1.35, 0.2, 1.7, "trousers_dark")
        panel(fb, f"{side}LowerLeg", s * 0.5 - 0.25, 1.0, s * 0.5 + 0.2, 1.2, "trousers_dark")
        lo_leg = f"{side}LowerLeg"
        band(fb, lo_leg, 0.5, 0.62, "wrap", grow=0.03)
        ft = f"{side}Foot"
        band(fb, ft, 0.0, 0.1, "sole")
        band(fb, ft, 0.36, 0.44, "leather_dark")


def model(fb):
    body(fb, skin="skin", shirt="poncho", pants="trousers", shoes="leather", sleeves="skin", forearms="skin",
         belt="trousers", shins="trousers")
    face(fb)
    hair(fb)
    poncho(fb)
    limbs(fb)
