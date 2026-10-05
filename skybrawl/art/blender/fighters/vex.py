"""Vex, shadow rogue. Scythe + Gauntlets. Fast glass cannon.

R6 style: a deep-purple pointed hood and capelet, a dark scarf mask over the
lower face, narrow glowing violet eyes under a black fringe with a violet
streak, a black vest with crossed straps and silver buckles, a short
tattered cloak, wrapped forearms, charcoal trousers with knee guards and
black boots with silver toe caps.
"""

from fighters._blocky import (UNIT, band, body, ellipse, front_profile, line, panel, profile, shape, shell, side_panel,
                              strap, wrapped)

NAME = "Vex"
UNIT = UNIT

COLORS = {
    "skin": "#f2dfd6",
    "eye": "#c27aff",
    "eye_core": "#7b2fd6",
    "eye_shine": "#ffffff",
    "brow": "#17121e",
    "hair": "#1c1924",
    "streak": "#a85eff",
    "hood": "#5a328f",
    "hood_dark": "#3b1f5e",
    "cloak": "#4a2672",
    "lining": "#1b1027",
    "scarf": "#2c2836",
    "scarf_dark": "#1e1b26",
    "shirt": "#353140",
    "vest": "#26232d",
    "strap": "#4b4358",
    "silver": "#d0d4de",
    "wrap": "#433d50",
    "wrap_dark": "#2a2632",
    "pants": "#474a55",
    "guard": "#2e2b36",
    "glove": "#1f1c25",
    "boot": "#25222b",
    "sole": "#121116",
}


def face(fb):
    for s in (-1, 1):
        # narrow eyes, angled down toward the nose: focused
        slit = [(s * 0.09, 4.6), (s * 0.31, 4.66), (s * 0.31, 4.59), (s * 0.12, 4.53)]
        shape(fb, slit, "eye", max_edge=0.03)
        shape(fb, ellipse(s * 0.2, 4.6, 0.032, 0.032), "eye_core", layer=2, max_edge=0.02)
        line(fb, [(s * 0.07, 4.69), (s * 0.33, 4.78)], 0.045, "brow")
    # scarf mask over nose and mouth, wrapping round to the back
    wrapped(fb, [(-1.88, 4.0), (1.88, 4.0), (1.88, 4.5), (0.0, 4.52), (-1.88, 4.5)], "scarf", out=0.05, inner=-0.03,
            max_edge=0.12)
    wrapped(fb, [(-1.88, 4.45), (1.88, 4.45), (1.88, 4.53), (0.0, 4.55), (-1.88, 4.53)], "scarf_dark", out=0.06,
            inner=0.0, max_edge=0.12)


def hood(fb):
    # black fringe with a violet streak, under the hood
    wrapped(fb, [(-0.5, 5.1), (0.5, 5.1), (0.46, 4.82), (0.3, 4.9), (0.16, 4.78), (0.0, 4.88), (-0.16, 4.76),
                 (-0.32, 4.88), (-0.5, 4.8)], "hair", out=0.07, inner=0.0)
    wrapped(fb, [(0.12, 5.05), (0.24, 5.05), (0.2, 4.84), (0.13, 4.92)], "streak", out=0.075, inner=0.02,
            max_edge=0.03)
    # the hood: a cap over the top and back, sides down to the jaw, a point at the back
    shell(fb, "hood", grow=0.12, bottom=5.06, back_bottom=3.95, top_grow=0.14)
    for s in (-1, 1):
        wrapped(fb, [(s * 0.44, 5.12), (s * 1.3, 5.12), (s * 1.3, 3.95), (s * 0.5, 3.95), (s * 0.4, 4.4)], "hood",
                out=0.1, inner=0.02)
        wrapped(fb, [(s * 0.42, 5.0), (s * 0.48, 5.0), (s * 0.44, 4.4), (s * 0.52, 3.97), (s * 0.46, 3.97),
                     (s * 0.36, 4.4)], "lining", out=0.11, inner=0.02, max_edge=0.04)
    profile(fb, "Head", [(0.3, 5.3), (0.85, 5.1), (1.15, 4.7), (0.7, 4.75)], -0.2, 0.2, "hood", bevel=0.04)
    # capelet over the shoulders, jagged edge
    up = "UpperTorso"
    fb[up].box((0, 3.97, 0), (2.12, 0.22, 1.12), "hood", bevel=0.04)
    hem = [(-1.06, 3.9), (1.06, 3.9), (1.06, 3.6), (0.8, 3.44), (0.6, 3.62), (0.3, 3.4), (0.0, 3.6), (-0.3, 3.4),
           (-0.6, 3.62), (-0.8, 3.44), (-1.06, 3.6)]
    front_profile(fb, up, hem, -0.56, 0.56, "hood", bevel=0.01)


def outfit(fb):
    up, low = "UpperTorso", "LowerTorso"
    # crossed straps with a silver buckle where they meet
    strap(fb, up, (-0.9, 3.45), (0.9, 2.55), 0.16, "strap", layer=2)
    strap(fb, up, (0.9, 3.45), (-0.9, 2.55), 0.16, "strap", layer=3)
    fb[up].cylinder((0, 3.0, -0.58), 0.12, 0.06, "silver", rotation=(90, 0, 0), segments=16)
    # tattered short cloak on the back
    tatters = [(-1.0, 3.9), (1.0, 3.9), (1.04, 2.4), (0.8, 2.12), (0.6, 2.36), (0.34, 2.02), (0.12, 2.3),
               (-0.1, 1.98), (-0.34, 2.28), (-0.58, 2.04), (-0.8, 2.34), (-1.04, 2.2)]
    fb[up].prism(tatters, 0.06, "cloak", center=(0, 0, 0.6), bevel=0.01)
    # belt, silver buckle, knife at the hip
    band(fb, low, 2.24, 2.38, "strap", layer=2)
    panel(fb, low, -0.1, 2.22, 0.1, 2.4, "silver", layer=4)
    fb[low].box((-0.72, 2.0, -0.42), (0.14, 0.5, 0.14), "vest", bevel=0.03, rotation=(0, 0, -12))
    fb[low].box((-0.68, 2.3, -0.42), (0.18, 0.08, 0.18), "silver", bevel=0.02)
    for side, s in (("Left", -1), ("Right", 1)):
        lo = f"{side}LowerArm"
        for y in (2.55, 2.75):
            band(fb, lo, y - 0.04, y + 0.04, "wrap_dark")
        band(fb, f"{side}UpperArm", 2.9, 2.98, "strap")
        # knee guards, boots, silver toe caps
        panel(fb, f"{side}LowerLeg", s * 0.5 - 0.3, 0.98, s * 0.5 + 0.3, 1.24, "guard", layer=2)
        panel(fb, f"{side}LowerLeg", s * 0.5 - 0.06, 1.08, s * 0.5 + 0.06, 1.16, "silver", layer=3)
        side_panel(fb, f"{side}UpperLeg", -0.2, 1.45, 0.2, 1.8, "guard")
        band(fb, f"{side}LowerLeg", 0.5, 0.86, "boot", grow=0.02)
        band(fb, f"{side}LowerLeg", 0.82, 0.88, "strap", grow=0.03)
        ft = f"{side}Foot"
        band(fb, ft, 0.0, 0.1, "sole")
        panel(fb, ft, s * 0.5 - 0.42, 0.1, s * 0.5 + 0.42, 0.3, "silver")


def model(fb):
    body(fb, skin="skin", shirt="vest", pants="pants", shoes="boot", sleeves="shirt", forearms="wrap", hands="glove",
         belt="vest", shins="pants")
    face(fb)
    hood(fb)
    outfit(fb)
