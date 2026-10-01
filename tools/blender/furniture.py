"""
furniture.py - the bedroom props for Steal a Sock in the concept-art style.

Names match ReplicatedStorage.MapMeshes (see src/server/StealASockServer/Map.luau):
Dryer, Bed, Nightstand, Lamp, Blocks, Duck, Teddy, Crayons, Basket, Drawer.
Each builder returns a list of Blender objects (textured body, `_Outline`, optional glow part,
markers). Front faces -Y; the origin is the floor centre. Sizes are in "units"; the game fits
every prop into its slot, so only proportions matter.
"""
import math
import sockkit as K
from sockkit import M, hexcol

WOOD = hexcol("wood", "#B77A45")
WOOD_D = hexcol("wood_dark", "#8C5A30")
WOOD_L = hexcol("wood_light", "#D49A5E")
CREAM = hexcol("cream", "#F3E6CC")
BLUE = hexcol("blanket_blue", "#5C7FD1")
RED = hexcol("stripe_red", "#D94F4F")
YELLOW = hexcol("block_yellow", "#F2C14E")
BLOCK_BLUE = hexcol("block_blue", "#4F7FD6")
WHITE = K.WHITE
DRYER_W = hexcol("dryer_white", "#EEF1F6")
DRYER_B = hexcol("dryer_blue", "#6DA5E3")
DRYER_BD = hexcol("dryer_blue_dark", "#3E6FB8")
PORTAL_D = hexcol("portal_dark", "#2B1B5A")
PORTAL_P = hexcol("portal_purple", "#7A3FE0")
PORTAL_L = hexcol("portal_light", "#C9A8FF")
DUCK_Y = hexcol("duck", "#FFD23F")
DUCK_YD = hexcol("duck_dark", "#F2B030")
BEAK = hexcol("beak", "#FF8A2B")
FUR = hexcol("fur", "#9C6233")
FUR_L = hexcol("fur_light", "#D9A877")
LINT = hexcol("lint_grey", "#B8BAC4")
LINT_D = hexcol("lint_grey_dark", "#9497A3")
WICKER = hexcol("wicker", "#C8A064")
WICKER_D = hexcol("wicker_dark", "#9C7440")
GLOBE = hexcol("globe", "#FFE58A")
BLACK = K.BLACK


def dryer():
    p = []
    p.append(K.rounded_box(DRYER_W, (3.4, 3.4, 3.3), M((0, 0, 1.9)), bevel=0.28, segments=3, name="body"))
    p.append(K.rounded_box(DRYER_B, (3.48, 3.48, 0.6), M((0, 0, 3.72)), bevel=0.22, segments=3, name="top"))
    p.append(K.rounded_box(DRYER_B, (3.3, 3.3, 0.32), M((0, 0, 0.16)), bevel=0.1, segments=2, name="kick"))
    fy = -1.7
    # porthole: white outer ring, blue inner ring, spiral galaxy arms over the glowing portal disc
    p.append(K.torus(DRYER_W, 1.18, 0.24, M((0, fy - 0.05, 1.85), rot=(math.pi / 2, 0, 0)), seg=32, mseg=10, name="ring"))
    p.append(K.torus(DRYER_BD, 0.96, 0.09, M((0, fy - 0.1, 1.85), rot=(math.pi / 2, 0, 0)), seg=32, mseg=6, outline=False, name="ring2"))
    for arm in range(3):
        pts = []
        for i in range(9):
            t = i / 8
            a = arm * math.tau / 3 + t * math.pi * 1.6
            r = 0.12 + t * 0.78
            pts.append((math.cos(a) * r, fy - 0.02, 1.85 + math.sin(a) * r))
        p.append(K.tube(PORTAL_L if arm == 0 else PORTAL_P, pts, radius=0.07, radii=[0.6 + 0.6 * (i / 8) for i in range(9)], res=4, bevel_res=1, outline=False, name="arm"))
    p.append(K.sphere(PORTAL_L, 0.16, M((0, fy - 0.05, 1.85)), seg=10, rings=6, outline=False, name="core"))
    # controls on the blue top panel
    p.append(K.cylinder(WHITE, 0.24, 0.16, M((0.35, fy - 0.08, 3.72), rot=(math.pi / 2, 0, 0)), seg=16, name="knob"))
    p.append(K.rounded_box(hexcol("display", "#2A3550"), (0.9, 0.1, 0.32), M((1.05, fy - 0.05, 3.72)), bevel=0.05, segments=1, outline=False, name="display"))
    p.append(K.rounded_box(DRYER_W, (1.0, 0.1, 0.3), M((-1.0, fy - 0.05, 3.72)), bevel=0.06, segments=1, name="tray"))
    p.append(K.rounded_box(DRYER_BD, (0.8, 0.08, 0.18), M((1.1, fy - 0.02, 0.55)), bevel=0.04, segments=1, outline=False, name="filter"))
    body, outline = K.finish(p, "Dryer", outline_width=0.06)
    portal = K.plain_object([K.cylinder(0, 0.94, 0.06, M((0, fy + 0.02, 1.85), rot=(math.pi / 2, 0, 0)), seg=32, smooth=False)], "DryerPortal")
    return [body, outline, portal] + K.markers("Dryer")


def bed():
    p = []
    W, D = 29.0, 8.6
    # frame + legs
    p.append(K.rounded_box(WOOD, (W, D, 1.4), M((0, 0, 1.5)), bevel=0.3, segments=3, name="frame"))
    # posts with ball finials (head posts at the back, taller)
    for x in (-W / 2 + 0.6, W / 2 - 0.6):
        for y, hgt in ((D / 2 - 0.6, 8.6), (-D / 2 + 0.6, 5.6)):
            p.append(K.cylinder(WOOD, 0.62, hgt, M((x, y, hgt / 2)), seg=16, name="post"))
            p.append(K.sphere(WOOD_L, 0.95, M((x, y, hgt + 0.7)), seg=16, rings=10, name="finial"))
            p.append(K.torus(WOOD_D, 0.62, 0.16, M((x, y, hgt - 0.3)), seg=16, mseg=6, outline=False, name="ring"))
    # headboard: rounded panel + slats
    p.append(K.rounded_box(WOOD, (W - 1.4, 0.5, 2.0), M((0, D / 2 - 0.6, 7.2)), bevel=0.22, segments=3, name="headtop"))
    for i in range(7):
        x = -W / 2 + 3.0 + i * (W - 6.0) / 6
        p.append(K.cylinder(WOOD_D, 0.28, 4.4, M((x, D / 2 - 0.6, 4.2)), seg=10, name="slat"))
    p.append(K.rounded_box(WOOD, (W - 1.4, 0.5, 1.6), M((0, -D / 2 + 0.6, 3.4)), bevel=0.2, segments=3, name="footrail"))
    # mattress, blanket with red stripes, pillows
    p.append(K.rounded_box(WHITE, (W - 1.6, D - 1.2, 1.7), M((0, 0, 3.05)), bevel=0.55, segments=4, name="mattress"))
    p.append(K.rounded_box(BLUE, (W - 1.8, D - 3.0, 0.55), M((0, -1.0, 4.05)), bevel=0.25, segments=3, name="blanket"))
    p.append(K.rounded_box(BLUE, (W - 1.8, 0.45, 2.4), M((0, -D / 2 + 0.95, 3.0)), bevel=0.2, segments=3, name="drape"))
    for k in range(4):
        y = -3.0 + k * 1.15
        p.append(K.rounded_box(RED, (W - 1.75, 0.42, 0.58), M((0, y, 4.06)), bevel=0.12, segments=2, outline=False, name="stripe"))
    for k in range(3):
        z = 2.2 + k * 0.7
        p.append(K.rounded_box(RED, (W - 1.75, 0.5, 0.3), M((0, -D / 2 + 0.92, z)), bevel=0.08, segments=2, outline=False, name="dstripe"))
    for x in (-6.5, 6.5):
        p.append(K.rounded_box(WHITE, (6.2, 2.6, 1.4), M((x, D / 2 - 2.1, 4.4), rot=(0.25, 0, 0)), bevel=0.6, segments=4, name="pillow"))
    body, outline = K.finish(p, "Bed", outline_width=0.12)
    return [body, outline] + K.markers("Bed")


def nightstand():
    p = []
    p.append(K.rounded_box(WOOD, (6.6, 6.4, 6.6), M((0, 0, 4.1)), bevel=0.35, segments=3, name="body"))
    p.append(K.rounded_box(WOOD_D, (7.3, 7.0, 0.55), M((0, 0, 7.6)), bevel=0.22, segments=3, name="top"))
    for z in (5.75, 2.75):
        p.append(K.rounded_box(WOOD_L, (5.6, 0.35, 2.4), M((0, -3.22, z)), bevel=0.22, segments=3, name="drawer"))
        p.append(K.rounded_box(WOOD_D, (1.7, 0.5, 0.55), M((0, -3.5, z)), bevel=0.2, segments=2, name="handle"))
    for x in (-2.8, 2.8):
        for y in (-2.7, 2.7):
            p.append(K.cylinder(WOOD_D, 0.42, 0.8, M((x, y, 0.4)), seg=12, name="leg"))
    body, outline = K.finish(p, "Nightstand", outline_width=0.08)
    return [body, outline] + K.markers("Nightstand")


def lamp():
    p = [K.cylinder(WOOD_D, 1.05, 0.35, M((0, 0, 0.18)), seg=20, name="base"),
         K.cylinder(WOOD, 0.32, 1.1, M((0, 0, 0.9)), seg=12, name="neck"),
         K.cylinder(WOOD_D, 0.62, 0.4, M((0, 0, 1.55)), seg=16, name="collar")]
    glow_shape = K.sphere(GLOBE, 1.45, M((0, 0, 3.0)), seg=24, rings=14, name="globe")
    body, outline = K.finish(p, "Lamp", outline_width=0.05, outline_only=[glow_shape])
    glow = K.plain_object([K.sphere(0, 1.45, M((0, 0, 3.0)), seg=24, rings=14)], "LampGlow")
    return [body, outline, glow] + K.markers("Lamp")


def blocks():
    p = []
    spec = [("S", RED, -3.7, 0.0, 0.14), ("O", YELLOW, -1.25, 0.25, -0.1), ("C", BLOCK_BLUE, 1.25, -0.1, 0.12), ("K", RED, 3.7, 0.2, -0.16)]
    for letter, col, x, y, yaw in spec:
        base = M((x, y, 1.1), rot=(0, 0, yaw))
        p.append(K.rounded_box(col, (2.2, 2.2, 2.2), base, bevel=0.22, segments=3, name="block"))
        # cream panels on the front, both sides and top, each with the letter
        faces = [((0, -1.12, 0), (math.pi / 2, 0, 0)), ((1.12, 0, 0), (math.pi / 2, 0, math.pi / 2)),
                 ((-1.12, 0, 0), (math.pi / 2, 0, -math.pi / 2)), ((0, 0, 1.12), (0, 0, 0))]
        for off, rot in faces:
            panel = base @ M(off, rot=rot)
            p.append(K.rounded_box(CREAM, (1.7, 1.7, 0.08), panel, bevel=0.06, segments=1, outline=False, name="panel"))
            p.append(K.text(col, letter, size=1.35, depth=0.06, mat=panel @ M((0, 0, 0.06)), name="letter"))
    body, outline = K.finish(p, "Blocks", outline_width=0.06)
    return [body, outline] + K.markers("Blocks")


def duck():
    p = [K.sphere(DUCK_Y, 1.9, M((0, 0.1, 1.45), scale=(1.0, 1.28, 0.78)), seg=24, rings=14, name="body"),
         K.sphere(DUCK_Y, 0.8, M((0, 2.1, 2.05), rot=(0.6, 0, 0), scale=(0.6, 0.9, 0.6)), seg=14, rings=8, name="tail"),
         K.sphere(DUCK_Y, 1.25, M((0, -0.95, 3.3)), seg=22, rings=12, name="head"),
         K.sphere(BEAK, 0.72, M((0, -2.05, 3.05), scale=(1.05, 1.1, 0.42)), seg=16, rings=8, name="beak")]
    for x in (-1.72, 1.72):
        p.append(K.sphere(DUCK_YD, 0.9, M((x, 0.2, 1.75), scale=(0.35, 1.0, 0.62)), seg=14, rings=8, name="wing"))
    for x in (-0.55, 0.55):
        p.append(K.sphere(BLACK, 0.2, M((x, -1.95, 3.7)), seg=10, rings=6, outline=False, name="eye"))
        p.append(K.sphere(WHITE, 0.06, M((x + 0.06, -2.12, 3.78)), seg=6, rings=4, outline=False, name="glint"))
    body, outline = K.finish(p, "Duck", outline_width=0.07)
    return [body, outline] + K.markers("Duck")


def teddy():
    p = [K.sphere(FUR, 1.55, M((0, 0, 1.7), scale=(1.0, 0.9, 1.1)), seg=20, rings=12, name="body"),
         K.sphere(FUR_L, 1.0, M((0, -0.75, 1.65), scale=(0.95, 0.5, 1.0)), seg=16, rings=10, outline=False, name="belly"),
         K.sphere(FUR, 1.3, M((0, 0, 4.0)), seg=20, rings=12, name="head"),
         K.sphere(FUR_L, 0.58, M((0, -1.08, 3.75), scale=(1.0, 0.75, 0.78)), seg=14, rings=8, name="snout"),
         K.sphere(BLACK, 0.22, M((0, -1.52, 3.92), scale=(1.2, 0.8, 0.9)), seg=10, rings=6, outline=False, name="nose")]
    for x in (-0.48, 0.48):
        p.append(K.sphere(BLACK, 0.16, M((x, -1.12, 4.32)), seg=10, rings=6, outline=False, name="eye"))
    for x in (-1.0, 1.0):
        p.append(K.sphere(FUR, 0.52, M((x, 0.05, 5.05)), seg=14, rings=8, name="ear"))
        p.append(K.sphere(FUR_L, 0.3, M((x, -0.25, 5.05), scale=(1, 0.5, 1)), seg=10, rings=6, outline=False, name="earin"))
        p.append(K.sphere(FUR, 0.55, M((x * 1.45, -0.35, 2.25), rot=(0.3, x * 0.3, 0), scale=(0.8, 0.8, 1.45)), seg=14, rings=8, name="arm"))
        p.append(K.sphere(FUR, 0.62, M((x * 0.8, -1.15, 0.6), scale=(0.9, 1.5, 0.8)), seg=14, rings=8, name="leg"))
        p.append(K.cylinder(FUR_L, 0.42, 0.1, M((x * 0.8, -2.05, 0.62), rot=(math.pi / 2, 0, 0)), seg=14, outline=False, name="pad"))
    body, outline = K.finish(p, "Teddy", outline_width=0.07)
    return [body, outline] + K.markers("Teddy")


def crayons():
    p = []
    spec = [(hexcol("crayon_blue", "#3E63C9"), (-1.5, -1.6), 0.25), (hexcol("crayon_green", "#44A84A"), (0.6, 0.4), -0.35),
            (hexcol("crayon_orange", "#F28A2E"), (1.6, 2.0), 0.15)]
    for col, (x, y), yaw in spec:
        base = M((x, y, 0.45), rot=(0, 0, yaw))
        p.append(K.cylinder(col, 0.45, 5.0, base @ M(rot=(0, math.pi / 2, 0)), seg=16, name="crayon"))
        p.append(K.cylinder(col, 0.45, 1.0, base @ M((3.0, 0, 0), rot=(0, math.pi / 2, 0)), seg=16, radius2=0.08, name="tip"))
        p.append(K.cylinder(WHITE, 0.47, 3.0, base @ M((-0.3, 0, 0), rot=(0, math.pi / 2, 0)), seg=16, outline=False, name="paper"))
        for dx in (-1.6, 1.0):
            p.append(K.cylinder(BLACK, 0.48, 0.12, base @ M((dx, 0, 0), rot=(0, math.pi / 2, 0)), seg=16, outline=False, name="band"))
        p.append(K.sphere(col, 0.3, base @ M((-0.3, 0, 0.45), scale=(1.6, 0.9, 0.2)), seg=12, rings=6, outline=False, name="logo"))
    body, outline = K.finish(p, "Crayons", outline_width=0.05)
    return [body, outline] + K.markers("Crayons")


def basket():
    p = [K.cylinder(WICKER, 1.55, 2.0, M((0, 0, 1.0)), seg=24, radius2=1.75, name="tub")]
    for i in range(16):
        a = i / 16 * math.tau
        p.append(K.rounded_box(WICKER_D, (0.22, 0.12, 1.85), M((math.cos(a) * 1.65, math.sin(a) * 1.65, 1.0), rot=(0, -0.1, a)), bevel=0.04, segments=1, outline=False, name="slat"))
    p.append(K.torus(WICKER_D, 1.78, 0.18, M((0, 0, 2.0)), seg=24, mseg=8, name="rim"))
    for x in (-1.8, 1.8):
        p.append(K.torus(WICKER_D, 0.45, 0.12, M((x, 0, 1.95), rot=(math.pi / 2, 0, math.pi / 2)), seg=14, mseg=6, name="handle"))
    for i, (x, y, z, r) in enumerate(((0, 0, 2.2, 1.25), (0.8, 0.5, 2.6, 0.75), (-0.7, -0.4, 2.7, 0.8), (0.2, -0.8, 2.9, 0.65), (-0.3, 0.7, 3.0, 0.6))):
        p.append(K.sphere(LINT if i % 2 == 0 else LINT_D, r, M((x, y, z)), seg=14, rings=8, name="lint"))
    body, outline = K.finish(p, "Basket", outline_width=0.05)
    return [body, outline] + K.markers("Basket")


def drawer():
    """Base shell: back + side walls, a LOW front lip (players walk in), handle. No floor."""
    W, D, Hh, T = 5.2, 3.8, 1.0, 0.25
    p = [K.rounded_box(WOOD, (W, T, Hh), M((0, D / 2 - T / 2, Hh / 2)), bevel=0.06, segments=2, name="back"),
         K.rounded_box(WOOD, (T, D, Hh), M((-W / 2 + T / 2, 0, Hh / 2)), bevel=0.06, segments=2, name="left"),
         K.rounded_box(WOOD, (T, D, Hh), M((W / 2 - T / 2, 0, Hh / 2)), bevel=0.06, segments=2, name="right"),
         K.rounded_box(WOOD_D, (W, 0.3, 0.36), M((0, -D / 2 + 0.15, 0.18)), bevel=0.06, segments=2, name="lip"),
         K.rounded_box(WOOD_D, (1.2, 0.22, 0.16), M((0, -D / 2 - 0.08, 0.2)), bevel=0.06, segments=2, name="handle")]
    # lighter rounded caps on the wall tops
    p.append(K.rounded_box(WOOD_L, (W + 0.06, T + 0.08, 0.1), M((0, D / 2 - T / 2, Hh)), bevel=0.04, segments=1, outline=False, name="cap"))
    for x in (-W / 2 + T / 2, W / 2 - T / 2):
        p.append(K.rounded_box(WOOD_L, (T + 0.08, D + 0.06, 0.1), M((x, 0, Hh)), bevel=0.04, segments=1, outline=False, name="cap"))
    body, outline = K.finish(p, "Drawer", outline_width=0.03)
    return [body, outline] + K.markers("Drawer")


BUILDERS = {"Dryer": dryer, "Bed": bed, "Nightstand": nightstand, "Lamp": lamp, "Blocks": blocks,
            "Duck": duck, "Teddy": teddy, "Crayons": crayons, "Basket": basket, "Drawer": drawer}
