"""
sockfeat_a.py - signature features for Tubolino, AnkleBiter, CrustyCrew, GymGary, Argylo, ToeToe, Sockrates.

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



def feat_tubolino(c):
    tid, spec, h, d, ey = c.tid, c.spec, c.h, c.d, c.ey
    RL, RF, FOOT = c.RL, c.RF, c.FOOT
    return []


def feat_anklebiter(c):
    tid, spec, h, d, ey = c.tid, c.spec, c.h, c.d, c.ey
    RL, RF, FOOT = c.RL, c.RF, c.FOOT
    return []


def feat_crusty(c):
    tid, spec, h, d, ey = c.tid, c.spec, c.h, c.d, c.ey
    RL, RF, FOOT = c.RL, c.RF, c.FOOT
    crust = hexcol("crust", "#9C7B45")
    out = []
    for i in range(9):
        a = i * 2.3
        z = 1.0 + (i % 4) * 0.55
        out.append(K.sphere(crust, 0.13 + (i % 3) * 0.04, M((math.cos(a) * RL * 0.98, math.sin(a) * RL * 0.98, z)), seg=8, rings=5, outline=False, name="crust"))
    return out


def feat_gymgary(c):
    tid, spec, h, d, ey = c.tid, c.spec, c.h, c.d, c.ey
    RL, RF, FOOT = c.RL, c.RF, c.FOOT
    band = color(f"{tid}_accent")
    out = [K.torus(band, RL * 1.02, 0.24, M((0, 0, h - 0.55)), seg=20, mseg=8, name="sweatband"),
           K.torus(K.WHITE, RL * 1.06, 0.07, M((0, 0, h - 0.55)), seg=20, mseg=6, outline=False, name="bandstripe")]
    drop = hexcol("sweat", "#8CCBFF")
    for x, z in ((-0.62, ey + 0.35), (0.7, ey + 0.15)):
        y = -math.sqrt(max(RL * RL - x * x, 0.01))
        out.append(K.sphere(drop, 0.11, M((x, y - 0.02, z), scale=(1, 1, 1.5)), seg=8, rings=5, name="drop"))
    return out


def feat_argylo(c):
    tid, spec, h, d, ey = c.tid, c.spec, c.h, c.d, c.ey
    RL, RF, FOOT = c.RL, c.RF, c.FOOT
    gold = hexcol(f"{tid}_extra", spec["extra"])
    out = []
    for i, (x, z) in enumerate([(-0.42, 2.55), (0.42, 2.55), (0.0, 1.95), (-0.42, 1.35), (0.42, 1.35), (0.0, 3.15)]):
        y = -math.sqrt(max(RL * RL - x * x, 0.01)) + 0.02
        ang = math.atan2(x, RL)
        out.append(K.rounded_box(gold if i % 2 == 0 else color(f"{tid}_accent"), (0.42, 0.08, 0.42),
                                 M((x, y, z), rot=(0, math.pi / 4, -ang)), bevel=0.03, segments=1, outline=False, name="diamond"))
    # monocle on the viewer-right eye + chain
    ex, ey_ = 0.37, ey
    y = -math.sqrt(RL * RL - ex * ex) + 0.1 - 0.32
    out.append(K.torus(C_GOLD, 0.40, 0.065, M((ex, y, ey_), rot=(math.pi / 2, 0, 0)), seg=20, mseg=6, name="monocle"))
    out.append(K.tube(C_GOLD, [(ex + 0.35, y + 0.05, ey_ - 0.2), (0.9, -0.3, ey_ - 0.8), (0.86, -0.15, ey_ - 1.4)], radius=0.035, res=6, bevel_res=1, outline=False, name="chain"))
    return out


def feat_toetoe(c):
    tid, spec, h, d, ey = c.tid, c.spec, c.h, c.d, c.ey
    RL, RF, FOOT = c.RL, c.RF, c.FOOT
    out = []
    acc = color(f"{tid}_accent")
    for i in range(5):
        y = -0.56 + i * 0.28
        r = 0.2 if i in (0, 4) else 0.24
        out.append(K.sphere(acc, r, M((d * (FOOT - 0.05), y, RF + 0.05 + (0.06 if i == 2 else 0))), seg=10, rings=6, name="toe"))
    return out


def feat_sockrates(c):
    tid, spec, h, d, ey = c.tid, c.spec, c.h, c.d, c.ey
    RL, RF, FOOT = c.RL, c.RF, c.FOOT
    out = []
    my = ey - 0.65
    beard = K.sphere(C_GREY, 0.62, M((0, -RL * 0.7, my - 0.25), scale=(1.15, 0.55, 1.1)), seg=14, rings=8, name="beard")
    out.append(beard)
    out.append(K.tube(C_GREY, [(-0.4, -RL - 0.12, my + 0.12), (0, -RL - 0.2, my + 0.02), (0.4, -RL - 0.12, my + 0.12)], radius=0.09, res=6, bevel_res=1, name="moustache"))
    # toga sash
    out.append(K.tube(K.WHITE, [(-RL - 0.05, -0.2, h - 1.1), (-0.3, -RL - 0.05, 1.6), (RL * 0.6, -0.5, 0.9), (RL + 0.05, 0.2, 0.7)], radius=0.22, res=8, bevel_res=2, name="toga"))
    # laurel wreath
    for i in range(10):
        a = i / 10 * math.tau
        if abs(math.sin(a) + 1) < 0.25:
            continue
        out.append(K.sphere(C_GREEN, 0.18, M((math.cos(a) * (RL + 0.05), math.sin(a) * (RL + 0.05), h - 0.15), rot=(0, 0, a), scale=(1.6, 0.6, 0.8)), seg=8, rings=5, name="leaf"))
    return out



# Per-type tweaks merged over socks.SPECS (colours, mood, tall/short, ...). Never change `single`.
SPEC_OVERRIDES = {}

FEATURES = {
    "Tubolino": feat_tubolino,
    "AnkleBiter": feat_anklebiter,
    "CrustyCrew": feat_crusty,
    "GymGary": feat_gymgary,
    "Argylo": feat_argylo,
    "ToeToe": feat_toetoe,
    "Sockrates": feat_sockrates,
}
