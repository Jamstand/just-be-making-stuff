"""
sockfeat_b.py - signature features for KneeHigh, Slipperino, Compressio, Sockhopper, DJDryer, Socktopus, Sockington.

Each feature builder takes the SockCtx `c` built by socks.py (body shape, eye/mouth positions,
surface helpers, colours) and returns a list of sockkit Pieces added on top of the shared body.
Only rely on SockCtx fields - never hard-code body dimensions - so the body can be reshaped without
breaking the features. Colour names must be prefixed with the type id (first registration wins).
"""
import math
from mathutils import Vector  # noqa: F401
import sockkit as K
from sockkit import M, color, hexcol  # noqa: F401
from socks import (C_BLUEBOLT, C_CASH, C_DARK, C_GOLD, C_GOLD2, C_GREEN, C_GREY, C_MAGENTA,  # noqa: F401
                   C_PINKMOUTH, C_RED, C_SILVER, C_SILVER2, C_STINK, C_TONGUE, C_WICKER, C_WICKER2)



def feat_kneehigh(c):
    return []


def feat_slipperino(c):
    tid, spec, h, d, ey = c.tid, c.spec, c.h, c.d, c.ey
    RL, RF, FOOT = c.RL, c.RF, c.FOOT
    out = []
    for i in range(5):
        x = d * (0.2 + i * 0.42)
        for y in (-0.3, 0.3):
            out.append(K.sphere(K.WHITE, 0.12, M((x, y, RF - RF * 0.93), scale=(1, 1, 0.5)), seg=8, rings=4, outline=False, name="grip"))
    return out


def feat_compressio(c):
    return []


def feat_sockhopper(c):
    tid, spec, h, d, ey = c.tid, c.spec, c.h, c.d, c.ey
    RL, RF, FOOT = c.RL, c.RF, c.FOOT
    red = C_RED
    out = [K.cylinder(red, 0.12, h + 2.4, M((0, 0.2, (h + 2.4) / 2 - 1.6)), seg=10, name="pole"),
           K.rounded_box(red, (1.6, 0.6, 0.18), M((0, 0.2, -0.9)), bevel=0.06, segments=2, name="pegs"),
           K.cylinder(C_DARK, 0.2, 0.7, M((0, 0.2, -1.95)), seg=10, name="spring"),
           K.cylinder(C_DARK, 0.11, 2.2, M((0, -0.2, h + 0.85), rot=(0, math.pi / 2, 0)), seg=10, name="handle")]
    return out


def feat_djdryer(c):
    tid, spec, h, d, ey = c.tid, c.spec, c.h, c.d, c.ey
    RL, RF, FOOT = c.RL, c.RF, c.FOOT
    out = [K.tube(C_DARK, [(-RL - 0.1, 0, ey + 0.2), (0, 0, h + 0.55), (RL + 0.1, 0, ey + 0.2)], radius=0.11, res=8, bevel_res=1, name="band")]
    for x in (-RL - 0.08, RL + 0.08):
        out.append(K.cylinder(C_MAGENTA, 0.38, 0.34, M((x, 0, ey + 0.05), rot=(0, math.pi / 2, 0)), seg=16, name="cup"))
    out.append(K.rounded_box(C_DARK, (1.25, 0.18, 0.34), M((0, -RL - 0.2, ey + 0.02)), bevel=0.08, segments=2, name="shades"))
    return out


def feat_socktopus(c):
    tid, spec, h, d, ey = c.tid, c.spec, c.h, c.d, c.ey
    RL, RF, FOOT = c.RL, c.RF, c.FOOT
    body = color(f"{tid}_body")
    acc = color(f"{tid}_accent")
    out = []
    for i in range(8):
        a = i / 8 * math.tau + 0.2
        r0, r1, r2 = 0.6, 1.4, 2.0
        pts = [(math.cos(a) * r0, math.sin(a) * r0, 0.7), (math.cos(a) * r1, math.sin(a) * r1, 0.35),
               (math.cos(a + 0.35) * r2, math.sin(a + 0.35) * r2, 0.3)]
        out.append(K.tube(body, pts, radius=0.32, radii=[1, 0.85, 0.6], res=6, bevel_res=2, name="tentacle"))
        out.append(K.sphere(acc, 0.2, M((math.cos(a + 0.35) * r2, math.sin(a + 0.35) * r2, 0.3)), seg=8, rings=5, name="tip"))
    return out


def feat_sockington(c):
    tid, spec, h, d, ey = c.tid, c.spec, c.h, c.d, c.ey
    RL, RF, FOOT = c.RL, c.RF, c.FOOT
    foil, foil2 = C_SILVER, C_SILVER2
    out = [K.cylinder(foil, RL * 1.08, 0.9, M((0, 0, h + 0.2)), seg=18, name="helmet"),
           K.sphere(foil, RL * 1.07, M((0, 0, h + 0.62), scale=(1, 1, 0.55)), seg=18, rings=8, name="dome"),
           K.rounded_box(foil2, (0.16, 0.2, 0.9), M((0, -RL - 0.08, h + 0.25)), bevel=0.05, segments=1, name="noseguard"),
           K.sphere(C_RED, 0.3, M((0, 0.1, h + 1.25), scale=(0.6, 1.6, 1.3)), seg=10, rings=6, name="plume"),
           K.rounded_box(foil, (1.5, 0.25, 1.2), M((0, -RL + 0.02, 1.6)), bevel=0.12, segments=2, name="breastplate")]
    return out



# Per-type tweaks merged over socks.SPECS (colours, mood, tall/short, ...). Never change `single`.
SPEC_OVERRIDES = {}

FEATURES = {
    "KneeHigh": feat_kneehigh,
    "Slipperino": feat_slipperino,
    "Compressio": feat_compressio,
    "Sockhopper": feat_sockhopper,
    "DJDryer": feat_djdryer,
    "Socktopus": feat_socktopus,
    "Sockington": feat_sockington,
}
