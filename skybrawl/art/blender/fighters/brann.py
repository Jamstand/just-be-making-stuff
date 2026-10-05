"""Brann, forge smith. Hammer + Gauntlets. Slow, heavy tank.

R6 style: a red bandana over a bald head, a huge rust-red block beard, a
sleeveless charcoal tunic under a leather smith's apron, bare arms with iron
bracers and soot-dark gloves, tan work trousers and heavy boots. Hearty grin.
"""

from fighters._blocky import (UNIT, band, body, curve, ellipse, eye, front_profile, panel, print_shape, profile,
                              shell, side_panel, strap, wrapped)

NAME = "Brann"
UNIT = UNIT

COLORS = {
    "skin": "#eaa685",
    "skin_dark": "#cf8a6b",
    "beard": "#94401c",
    "beard_dark": "#6a2b12",
    "eye": "#1f1a1c",
    "eye_shine": "#ffffff",
    "mouth": "#4a1812",
    "teeth": "#fbf6ea",
    "bandana": "#cc3229",
    "bandana_dark": "#8e1e1a",
    "dot": "#f4e6d0",
    "tunic": "#3d3e46",
    "tunic_dark": "#2b2b31",
    "apron": "#83502c",
    "apron_dark": "#5e381d",
    "belt": "#4a2c18",
    "iron": "#737a83",
    "iron_dark": "#4a4f57",
    "iron_light": "#aab2ba",
    "glove": "#3a2b22",
    "tan": "#bd9660",
    "tan_dark": "#977444",
    "boot": "#5f3d27",
    "boot_dark": "#402819",
    "sole": "#2c211c",
    "ember": "#ff8a24",
}


def face(fb):
    for u in (-0.2, 0.2):
        eye(fb, u, 4.66, "eye", ru=0.05, rv=0.085)
    # bushy brows, raised in the middle: cheerful
    for s in (-1, 1):
        wrapped(fb, [(s * 0.08, 4.8), (s * 0.34, 4.76), (s * 0.36, 4.83), (s * 0.08, 4.88)], "beard",
                out=0.05, inner=-0.02)
    # big rosy nose: the one non-classic feature, he's earned it
    wrapped(fb, ellipse(0, 4.55, 0.09, 0.075), "skin_dark", out=0.09, inner=-0.02, max_edge=0.03)


def beard(fb):
    # sideburns into a big square beard that hangs onto the chest
    outline = [(-0.62, 4.82), (-0.5, 4.82), (-0.42, 4.5), (-0.24, 4.4), (0.24, 4.4), (0.42, 4.5), (0.5, 4.82),
               (0.62, 4.82), (0.68, 4.2), (0.5, 3.72), (0.2, 3.56), (-0.2, 3.56), (-0.5, 3.72), (-0.68, 4.2)]
    wrapped(fb, outline, "beard", out=0.16, inner=-0.02, max_edge=0.15)
    # darker inner layer under the mustache, and the mustache itself
    wrapped(fb, [(-0.34, 4.47), (0.34, 4.47), (0.3, 4.38), (0.08, 4.4), (0, 4.36), (-0.08, 4.4), (-0.3, 4.38)],
            "beard_dark", out=0.2, inner=0.1)
    wrapped(fb, [(-0.36, 4.5), (-0.1, 4.52), (0, 4.47), (0.1, 4.52), (0.36, 4.5), (0.4, 4.4), (0.2, 4.42),
                 (0, 4.4), (-0.2, 4.42), (-0.4, 4.4)], "beard", out=0.23, inner=0.12)
    # the grin, drawn on the beard's surface
    mouth = curve(-0.2, 4.31, 0.2, 4.31, 0.0, 6) + list(reversed(curve(-0.17, 4.27, 0.17, 4.27, 0.1, 8)))
    wrapped(fb, mouth, "mouth", out=0.172, inner=0.12, max_edge=0.025)
    wrapped(fb, [(-0.17, 4.305), (0.17, 4.305), (0.15, 4.26), (-0.15, 4.26)], "teeth", out=0.178, inner=0.12,
            max_edge=0.025)
    # braid tie at the bottom
    fb["Head"].box((0, 3.7, -0.74), (0.24, 0.12, 0.12), "iron", bevel=0.03)


def bandana(fb):
    shell(fb, "bandana", grow=0.05, bottom=4.97, back_bottom=4.78)
    for u, v in ((-0.36, 5.12), (0.05, 5.18), (0.4, 5.08), (-0.1, 5.06), (0.25, 5.02)):
        wrapped(fb, ellipse(u, v, 0.035, 0.035), "dot", out=0.065, inner=0.03, max_edge=0.02)
    # knot and tails at the back
    fb["Head"].box((0, 4.98, 0.72), (0.26, 0.22, 0.16), "bandana_dark", bevel=0.05)
    profile(fb, "Head", [(0.7, 4.95), (0.86, 4.92), (1.0, 4.52), (0.9, 4.48)], -0.14, -0.02, "bandana")
    profile(fb, "Head", [(0.72, 4.94), (0.82, 4.9), (1.12, 4.62), (1.02, 4.56)], 0.02, 0.14, "bandana_dark")


def apron(fb):
    up, low = "UpperTorso", "LowerTorso"
    print_shape(fb, up, [(-0.8, 2.5), (0.8, 2.5), (0.8, 3.3), (0.5, 3.45), (0.45, 3.85), (-0.45, 3.85),
                         (-0.5, 3.45), (-0.8, 3.3)], "apron", bevel=0.01)
    for s in (-1, 1):
        strap(fb, up, (s * 0.38, 3.82), (s * 0.62, 4.02), 0.14, "apron_dark", layer=2)
    # straps crossing on the back
    strap(fb, up, (-0.85, 2.6), (0.75, 4.0), 0.16, "apron_dark", face="back")
    strap(fb, up, (0.85, 2.6), (-0.75, 4.0), 0.16, "apron_dark", face="back")
    # chest pocket with a pair of tongs
    panel(fb, up, 0.12, 2.85, 0.55, 3.2, "apron_dark", layer=2)
    fb[up].box((0.25, 3.3, -0.56), (0.05, 0.42, 0.04), "iron_dark", bevel=0.01, rotation=(0, 0, 6))
    fb[up].box((0.36, 3.3, -0.56), (0.05, 0.42, 0.04), "iron_dark", bevel=0.01, rotation=(0, 0, -6))
    # apron skirt over the hips, belt with an iron buckle
    panel(fb, low, -0.8, 2.0, 0.8, 2.5, "apron")
    band(fb, low, 2.3, 2.44, "belt", layer=2)
    panel(fb, low, -0.12, 2.27, 0.12, 2.47, "iron", layer=4)
    front_profile(fb, low, [(-0.78, 2.1), (0.78, 2.1), (0.74, 1.5), (0.4, 1.46), (0.0, 1.5), (-0.4, 1.46),
                            (-0.74, 1.5)], -0.58, -0.53, "apron", bevel=0.01)
    front_profile(fb, low, [(-0.74, 1.6), (0.74, 1.6), (0.74, 1.55), (-0.74, 1.55)], -0.6, -0.57, "apron_dark",
                  bevel=0.0)


def arms(fb):
    for side, s in (("Left", -1), ("Right", 1)):
        # tunic edge over the shoulder
        fb[f"{side}UpperArm"].box((s * 1.5, 3.92, 0), (1.04, 0.16, 1.04), "tunic", bevel=0.03)
        lo = f"{side}LowerArm"
        band(fb, lo, 2.47, 2.88, "iron", grow=0.03)
        for y in (2.55, 2.8):
            band(fb, lo, y - 0.03, y + 0.03, "iron_dark", grow=0.045)
        side_panel(fb, lo, -0.15, 2.6, 0.15, 2.75, "ember", layer=3)


def legs(fb):
    for side, s in (("Left", -1), ("Right", 1)):
        up = f"{side}UpperLeg"
        panel(fb, up, s * 0.5 - 0.3, 1.3, s * 0.5 + 0.2, 1.6, "tan_dark")
        lo = f"{side}LowerLeg"
        band(fb, lo, 1.05, 1.25, "boot_dark", grow=0.04)
        band(fb, lo, 0.75, 0.83, "belt")
        ft = f"{side}Foot"
        band(fb, ft, 0.0, 0.12, "sole")
        panel(fb, ft, s * 0.5 - 0.46, 0.12, s * 0.5 + 0.46, 0.4, "boot_dark")


def model(fb):
    body(fb, skin="skin", shirt="tunic", pants="tan", shoes="boot", sleeves="skin", forearms="skin",
         hands="glove", belt="tunic_dark", shins="boot")
    face(fb)
    beard(fb)
    bandana(fb)
    apron(fb)
    arms(fb)
    legs(fb)
