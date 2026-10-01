"""
props/bed.py - the Bed prop (ReplicatedStorage.MapMeshes.Bed). See props/__init__.py for
the conventions every prop follows.
"""
import math
import sockkit as K
from sockkit import M, hexcol
from props.common import *  # noqa: F401,F403 - shared colours (read-only)

NAME = "Bed"


def build():
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
