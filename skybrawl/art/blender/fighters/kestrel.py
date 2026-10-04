"""Kestrel, sky-corsair. Sword + Bow. Fast, nimble duelist."""

from sky.rig import pivot, sides

NAME = "Kestrel"

COLORS = {
    "skin": "#a8683f",
    "skin_dark": "#8a522f",
    "hair": "#c9521f",
    "hair_dark": "#8e3415",
    "eye_white": "#f6f1e7",
    "iris": "#4b2a17",
    "brow": "#5e2410",
    "mouth": "#6a2d22",
    "scar": "#d29a78",
    "teal": "#1f8088",
    "teal_dark": "#145a60",
    "gold": "#e0a93c",
    "cream": "#efe2c2",
    "sash": "#8d1f3e",
    "sash_dark": "#64152c",
    "leather": "#6e4024",
    "leather_dark": "#4a2915",
    "pants": "#3b3c3f",
    "pants_dark": "#2a2b2e",
    "boot": "#c58c4a",
    "boot_dark": "#9b6833",
    "sole": "#4b3021",
    "brass": "#c99e3a",
    "lens": "#86d6dc",
    "black": "#18161a",
}


def head(fb):
    h = fb["Head"]
    # neck, skull, jaw, ears
    h.cylinder((0, 4.55, 0.02), 0.17, 0.45, "skin", segments=10)
    h.sphere((0, 5.18, 0.0), (0.5, 0.6, 0.54), "skin", segments=18, rings=12)
    h.sphere((0, 4.95, -0.08), (0.4, 0.33, 0.42), "skin", segments=16, rings=10)
    for _, s in sides():
        h.sphere((s * 0.5, 5.12, 0.04), (0.07, 0.13, 0.09), "skin", segments=8, rings=6)

    # face: big readable eyes, brows, nose, smirk
    for _, s in sides():
        h.sphere((s * 0.19, 5.13, -0.47), (0.11, 0.09, 0.07), "eye_white", segments=12, rings=8)
        h.sphere((s * 0.175, 5.12, -0.525), (0.068, 0.085, 0.03), "iris", segments=10, rings=6)
        h.sphere((s * 0.15, 5.16, -0.552), (0.022, 0.022, 0.01), "eye_white", segments=6, rings=4)
        h.box((s * 0.2, 5.28, -0.5), (0.22, 0.05, 0.06), "brow", bevel=0.02, rotation=(0, 0, s * -9))
    h.box((-0.22, 5.21, -0.535), (0.03, 0.26, 0.03), "scar", bevel=0.01, rotation=(0, 0, -12))
    h.sphere((0, 5.02, -0.54), (0.05, 0.075, 0.055), "skin", segments=8, rings=6)
    h.box((0, 4.97, -0.575), (0.06, 0.02, 0.02), "skin_dark", bevel=0.008)
    h.box((0.04, 4.88, -0.485), (0.17, 0.028, 0.03), "mouth", bevel=0.01, rotation=(0, 0, 7))

    # hair: shaved sides, swept copper top, fringe over her right temple, back tufts
    hairline = [((0, 5.25, -0.5), (0, 1.0, 0.55))]
    h.sphere((0, 5.18, 0.01), (0.515, 0.615, 0.555), "hair_dark", segments=18, rings=12, clip=hairline)
    top = [((0, 5.42, 0), (0, 1, 0.25))]
    h.sphere((0.03, 5.3, 0.04), (0.56, 0.6, 0.62), "hair", segments=18, rings=12, clip=top)
    h.limb((-0.15, 5.8, -0.2), (0.45, 5.25, -0.47), 0.22, 0.07, "hair")
    h.limb((0.1, 5.74, -0.35), (0.52, 5.0, -0.36), 0.15, 0.04, "hair")
    h.limb((-0.2, 5.8, -0.1), (-0.48, 5.55, -0.32), 0.15, 0.04, "hair")
    for x, y, z, tx, ty, tz in (
        (0.0, 5.78, 0.25, 0.05, 5.5, 0.78),
        (0.25, 5.72, 0.2, 0.42, 5.42, 0.66),
        (-0.22, 5.72, 0.22, -0.36, 5.44, 0.68),
        (0.05, 5.84, 0.05, 0.15, 5.95, 0.58),
    ):
        h.limb((x, y, z), (tx, ty, tz), 0.17, 0.03, "hair")

    # goggles pushed up on the forehead
    h.loft([(0, 5.47, 0.04, 0.545, 0.575), (0, 5.57, 0.04, 0.55, 0.58)], "leather_dark", segments=20,
           caps=(False, False))
    for _, s in sides():
        c = (s * 0.19, 5.6, -0.52)
        h.cylinder(c, 0.14, 0.12, "brass", rotation=(-60, 0, 0), segments=14)
        h.cylinder((c[0], c[1] + 0.05, c[2] - 0.09), 0.105, 0.03, "lens", rotation=(-60, 0, 0), segments=14)
    h.box((0, 5.6, -0.56), (0.12, 0.06, 0.06), "brass", bevel=0.02)


def torso(fb):
    up = fb["UpperTorso"]
    # cream wrap shirt underneath, then the cropped teal jacket
    up.loft([(0, 3.0, 0, 0.5, 0.33), (0, 3.4, 0, 0.53, 0.35), (0, 3.9, 0, 0.6, 0.38), (0, 4.3, 0, 0.6, 0.35)],
            "cream", power=2.4)
    up.loft([(0, 3.3, 0, 0.55, 0.39), (0, 3.7, 0, 0.58, 0.4), (0, 4.0, 0, 0.64, 0.42), (0, 4.28, 0, 0.66, 0.4),
             (0, 4.44, 0, 0.5, 0.31)], "teal", power=2.4, segments=16)
    # open front: cream V with gold piping on the lapels
    up.prism([(-0.27, 4.4), (0.25, 4.4), (0.04, 3.3), (-0.04, 3.3)], 0.08, "cream", center=(0, 0, -0.41))
    for s in (-1, 1):
        up.prism([(s * 0.25, 4.42), (s * 0.31, 4.42), (s * 0.07, 3.28), (s * 0.02, 3.28)], 0.06, "gold",
                 center=(0, 0, -0.445))
    # hem piping, back yoke piping
    up.loft([(0, 3.27, 0, 0.565, 0.405), (0, 3.33, 0, 0.57, 0.41)], "gold", power=2.4, segments=16)
    up.prism([(-0.55, 4.05), (-0.2, 3.92), (0, 3.98), (0.2, 3.92), (0.55, 4.05), (0.55, 4.1), (0.2, 3.97),
              (0, 4.03), (-0.2, 3.97), (-0.55, 4.1)], 0.04, "gold", center=(0, 0, 0.425))
    # high collar, open at the front, gold rim
    front_cut = [((0, 0, -0.16), (0, 0, 1))]
    up.loft([(0, 4.3, 0.02, 0.36, 0.31), (0, 4.55, 0.03, 0.38, 0.33), (0, 4.74, 0.05, 0.42, 0.36)], "teal",
            segments=18, caps=(False, False), clip=front_cut)
    up.torus((0, 4.74, 0.05), 0.4, 0.03, "gold", segments=20, scale=(1.05, 0.9), clip=front_cut)
    # chest strap from her left shoulder to right hip, brass compass
    up.box((0.02, 3.86, -0.45), (1.3, 0.13, 0.05), "leather", bevel=0.015, rotation=(0, 0, -44))
    up.box((0.02, 3.86, 0.435), (1.3, 0.13, 0.05), "leather", bevel=0.015, rotation=(0, 0, 44))
    up.cylinder((-0.31, 4.0, -0.48), 0.12, 0.06, "brass", rotation=(90, 0, 0), segments=14)
    up.cylinder((-0.31, 4.0, -0.515), 0.085, 0.02, "cream", rotation=(90, 0, 0), segments=14)
    up.box((-0.31, 4.0, -0.53), (0.02, 0.12, 0.01), "sash", bevel=0)

    low = fb["LowerTorso"]
    low.loft([(0, 2.3, 0, 0.6, 0.41), (0, 2.6, 0, 0.63, 0.43), (0, 2.85, 0, 0.58, 0.4), (0, 3.15, 0, 0.51, 0.36)],
             "pants", power=2.3, segments=16)
    low.loft([(0, 3.05, 0, 0.515, 0.365), (0, 3.32, 0, 0.53, 0.37)], "cream", power=2.3, segments=16)
    # sash, belt and buckle, knotted tails over the right hip
    low.loft([(0, 2.78, 0, 0.64, 0.45), (0, 2.95, 0, 0.65, 0.46), (0, 3.12, 0, 0.58, 0.42)], "sash", power=2.5,
             segments=18)
    low.loft([(0, 2.86, 0, 0.665, 0.475), (0, 2.96, 0, 0.665, 0.475)], "leather", power=2.5, segments=18)
    low.box((0, 2.91, -0.48), (0.2, 0.15, 0.05), "gold", bevel=0.02)
    low.box((0, 2.91, -0.5), (0.11, 0.07, 0.03), "leather", bevel=0.01)
    low.sphere((0.36, 2.86, -0.44), (0.14, 0.12, 0.1), "sash_dark", segments=10, rings=7)
    low.prism([(-0.09, 0), (0.09, 0), (0.12, -0.62), (0.0, -0.56), (-0.07, -0.66)], 0.05, "sash",
              center=(0.3, 2.82, -0.47), rotation=(0, 0, 6))
    low.prism([(-0.08, 0), (0.08, 0), (0.1, -0.5), (0.0, -0.44), (-0.06, -0.52)], 0.05, "sash_dark",
              center=(0.45, 2.8, -0.45), rotation=(0, 0, -10))


def arms(fb):
    for side, s in sides():
        ua = fb[f"{side}UpperArm"]
        sh = pivot(f"{side}Shoulder")
        el = pivot(f"{side}Elbow")
        ua.sphere((s * 0.98, 4.12, 0), (0.28, 0.28, 0.3), "teal", segments=14, rings=9)
        ua.limb((sh[0], sh[1] - 0.05, 0), (el[0], el[1] + 0.05, 0), 0.24, 0.225, "teal")

        la = fb[f"{side}LowerArm"]
        wr = pivot(f"{side}Wrist")
        la.limb(el, (s * 1.24, 3.05, 0), 0.23, 0.235, "teal")
        la.loft([(s * 1.24, 3.0, 0, 0.255, 0.255), (s * 1.245, 3.08, 0, 0.26, 0.26)], "gold", segments=14)
        la.loft([(s * 1.245, 2.6, 0, 0.21, 0.21), (s * 1.255, 2.8, 0, 0.235, 0.235),
                 (s * 1.24, 3.02, 0, 0.255, 0.255)], "leather", segments=14)
        for y in (2.72, 2.9):
            la.loft([(s * 1.25, y - 0.03, 0, 0.245, 0.245), (s * 1.25, y + 0.03, 0, 0.25, 0.25)],
                    "leather_dark", segments=14)

        hand = fb[f"{side}Hand"]
        hand.box((wr[0] + s * 0.04, 2.33, -0.02), (0.32, 0.44, 0.38), "skin", bevel=0.11, segments=2)
        hand.box((wr[0] + s * 0.05, 2.17, -0.1), (0.3, 0.16, 0.26), "skin", bevel=0.07)
        hand.limb((wr[0] - s * 0.1, 2.46, -0.15), (wr[0] - s * 0.13, 2.27, -0.23), 0.075, 0.065, "skin",
                  segments=8)


def legs(fb):
    for side, s in sides():
        hip = pivot(f"{side}Hip")
        ul = fb[f"{side}UpperLeg"]
        ul.loft([(hip[0], 2.62, 0, 0.33, 0.35), (s * 0.54, 2.1, 0, 0.35, 0.36), (s * 0.53, 1.55, 0, 0.3, 0.32)],
                "pants", segments=14)
        # cargo pocket with flap on the outer thigh
        ul.box((s * 0.87, 1.98, -0.02), (0.1, 0.42, 0.4), "pants_dark", bevel=0.03)
        ul.box((s * 0.9, 2.18, -0.02), (0.08, 0.1, 0.42), "pants", bevel=0.02)

        ll = fb[f"{side}LowerLeg"]
        ll.loft([(s * 0.52, 1.58, 0, 0.3, 0.32), (s * 0.52, 1.32, 0, 0.335, 0.355), (s * 0.52, 1.16, 0, 0.325, 0.345),
                 (s * 0.52, 1.08, 0, 0.26, 0.28)], "pants", segments=14)
        ll.loft([(s * 0.52, 0.42, 0.02, 0.22, 0.25), (s * 0.52, 0.8, 0.0, 0.23, 0.26),
                 (s * 0.52, 1.05, 0.0, 0.25, 0.27)], "boot", segments=14)
        ll.loft([(s * 0.52, 0.94, 0, 0.28, 0.3), (s * 0.52, 1.16, 0, 0.3, 0.32)], "boot", segments=14,
                caps=(True, False))
        ll.loft([(s * 0.52, 1.12, 0, 0.27, 0.29), (s * 0.52, 1.165, 0, 0.27, 0.29)], "boot_dark", segments=14)
        for y in (0.6, 0.82):
            ll.loft([(s * 0.52, y - 0.045, 0.0, 0.24, 0.27), (s * 0.52, y + 0.045, 0.0, 0.245, 0.275)],
                    "leather", segments=14)
            ll.box((s * 0.77, y, -0.02), (0.05, 0.12, 0.12), "brass", bevel=0.015)

        ft = fb[f"{side}Foot"]
        ft.box((s * 0.52, 0.27, -0.1), (0.44, 0.46, 0.8), "boot", bevel=0.15, segments=2, taper=(0.9, 0.75))
        ft.box((s * 0.52, 0.18, -0.38), (0.42, 0.3, 0.32), "boot_dark", bevel=0.12, segments=2)
        ft.box((s * 0.52, 0.05, -0.12), (0.47, 0.1, 0.88), "sole", bevel=0.04)
        ft.box((s * 0.52, 0.42, 0.0), (0.46, 0.08, 0.5), "leather", bevel=0.02)


def model(fb):
    head(fb)
    torso(fb)
    arms(fb)
    legs(fb)
