"""
sockfeat_c.py - signature features for Stinkolino, SockNess, Shockini, Lintlord, Zillionaire, LostSock, PuppetSupreme.

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



def feat_stinkolino(c):
    tid, spec, h, d, ey = c.tid, c.spec, c.h, c.d, c.ey
    RL, RF, FOOT = c.RL, c.RF, c.FOOT
    out = []
    for i, x in enumerate((-0.5, 0.15, 0.7)):
        z0 = h + 0.25
        pts = [(x, 0, z0), (x + 0.25, -0.1, z0 + 0.5), (x - 0.15, -0.1, z0 + 1.0), (x + 0.2, 0, z0 + 1.5)]
        out.append(K.tube(C_STINK, pts, radius=0.09, res=6, bevel_res=1, name="stink"))
    for i in range(4):
        a = i * 1.7
        out.append(K.sphere(C_DARK, 0.1, M((math.cos(a) * 1.4, math.sin(a) * 1.4, h - 0.6 + i * 0.4)), seg=6, rings=4, outline=False, name="fly"))
    return out


def feat_sockness(c):
    tid, spec, h, d, ey = c.tid, c.spec, c.h, c.d, c.ey
    RL, RF, FOOT = c.RL, c.RF, c.FOOT
    body = color(f"{tid}_body")
    acc = color(f"{tid}_accent")
    out = [K.tube(body, [(0, 0, h - 0.2), (0.3, 0, h + 1.2), (0.1, -0.2, h + 2.4), (0.6, -0.6, h + 2.9)], radius=0.45, radii=[1, 0.85, 0.75, 0.72], res=8, bevel_res=2, name="neck"),
           K.sphere(body, 0.7, M((0.75, -0.75, h + 3.05), scale=(1.15, 1.25, 0.85)), seg=14, rings=8, name="head")]
    for x in (0.45, 1.05):
        out.append(K.sphere(K.WHITE, 0.2, M((x, -1.35, h + 3.25)), seg=10, rings=6, name="eye2"))
        out.append(K.sphere(K.BLACK, 0.1, M((x, -1.5, h + 3.25)), seg=8, rings=5, outline=False, name="pupil2"))
    for i in range(4):
        out.append(K.cylinder(acc, 0.12, 0.35, M((0.2, 0.38, h + 0.3 + i * 0.6), rot=(0.3, 0, 0)), seg=6, radius2=0.01, name="spine"))
    # laundry basket around the bottom
    # laundry basket around the bottom - big enough to hide the foot
    bx = d * 0.85
    out.append(K.cylinder(C_WICKER, 2.0, 1.9, M((bx, 0, 0.8)), seg=24, name="basket"))
    for i in range(14):
        a = i / 14 * math.tau
        out.append(K.rounded_box(C_WICKER2, (0.2, 0.12, 1.7), M((bx + math.cos(a) * 2.03, math.sin(a) * 2.03, 0.85), rot=(0, 0, a)), bevel=0.04, segments=1, outline=False, name="slat"))
    out.append(K.torus(C_WICKER2, 2.03, 0.15, M((bx, 0, 1.75)), seg=24, mseg=6, name="basketrim"))
    return out


def feat_shockini(c):
    tid, spec, h, d, ey = c.tid, c.spec, c.h, c.d, c.ey
    RL, RF, FOOT = c.RL, c.RF, c.FOOT
    out = []
    for i in range(7):
        a = i / 7 * math.tau
        out.append(K.cylinder(C_BLUEBOLT, 0.12, 0.8, M((math.cos(a) * 0.55, math.sin(a) * 0.55, h + 0.35), rot=(math.sin(a) * 0.5, -math.cos(a) * 0.5, 0)), seg=6, radius2=0.02, name="fuzz"))
    for x, z, s in ((-RL - 0.05, 2.2, 1), (RL + 0.05, 2.8, -1)):
        pts = [(x, -0.2, z + 0.6), (x - 0.2 * s, -0.25, z + 0.15), (x + 0.15 * s, -0.25, z), (x - 0.1 * s, -0.25, z - 0.55)]
        out.append(K.tube(C_BLUEBOLT, pts, radius=0.09, res=2, bevel_res=1, name="bolt"))
    return out


def feat_lintlord(c):
    tid, spec, h, d, ey = c.tid, c.spec, c.h, c.d, c.ey
    RL, RF, FOOT = c.RL, c.RF, c.FOOT
    lint = hexcol("lint", "#C2C3CC")
    out = []
    for i in range(14):
        a = i * 2.39
        z = 0.6 + (i % 7) * 0.5
        out.append(K.sphere(lint, 0.25 + (i % 3) * 0.06, M((math.cos(a) * RL * 0.9, math.sin(a) * RL * 0.9, z)), seg=8, rings=5, outline=False, name="fluff"))
    out.append(K.cylinder(C_GOLD, RL * 1.05, 0.35, M((0, 0, h + 0.15)), seg=18, name="crown"))
    for i in range(6):
        a = i / 6 * math.tau
        out.append(K.cylinder(C_GOLD, 0.2, 0.75, M((math.cos(a) * RL * 0.9, math.sin(a) * RL * 0.9, h + 0.65)), seg=6, radius2=0.03, name="spike"))
        out.append(K.sphere(C_RED, 0.1, M((math.cos(a) * RL * 1.06, math.sin(a) * RL * 1.06, h + 0.2)), seg=6, rings=4, outline=False, name="gem"))
    return out


def feat_zillionaire(c):
    tid, spec, h, d, ey = c.tid, c.spec, c.h, c.d, c.ey
    RL, RF, FOOT = c.RL, c.RF, c.FOOT
    out = [K.cylinder(C_DARK, 1.35, 0.14, M((0, 0, h + 0.1)), seg=20, name="brim"),
           K.cylinder(C_DARK, 0.85, 1.5, M((0, 0, h + 0.9)), seg=18, name="hat"),
           K.cylinder(C_GOLD2, 0.87, 0.28, M((0, 0, h + 0.38)), seg=18, outline=False, name="hatband")]
    ex = 0.37
    y = -math.sqrt(RL * RL - ex * ex) + 0.1 - 0.32
    out.append(K.torus(C_GOLD, 0.4, 0.065, M((ex, y, ey), rot=(math.pi / 2, 0, 0)), seg=20, mseg=6, name="monocle"))
    for i, (x, z, r) in enumerate(((-1.3, 2.4, 0.4), (1.25, 3.0, -0.3), (-1.0, 3.6, 0.9))):
        out.append(K.rounded_box(C_CASH, (0.8, 0.06, 0.4), M((x, -0.4, z), rot=(0.3, r, 0.2)), bevel=0.03, segments=1, name="bill"))
    for i in range(3):
        out.append(K.torus(K.WHITE if i else C_GOLD2, RL * 1.01, 0.04, M((0, 0, 1.4 + i * 0.7)), seg=20, mseg=4, outline=False, name="thread"))
    return out


def feat_lost(c):
    tid, spec, h, d, ey = c.tid, c.spec, c.h, c.d, c.ey
    RL, RF, FOOT = c.RL, c.RF, c.FOOT
    q = hexcol("ghost", "#B9BCFF")
    return [K.text(q, "?", size=1.4, depth=0.18, mat=M((0, -0.1, h + 1.1), rot=(math.pi / 2, 0, 0)), outline=True, name="question")]


def feat_puppet(c):
    tid, spec, h, d, ey = c.tid, c.spec, c.h, c.d, c.ey
    RL, RF, FOOT = c.RL, c.RF, c.FOOT
    out = [K.sphere(C_PINKMOUTH, 0.55, M((0, -RL * 0.72, ey - 0.85), scale=(1.15, 0.5, 0.75)), seg=14, rings=8, name="mouth"),
           K.rounded_box(K.WHITE, (0.9, 0.12, 0.12), M((0, -RL - 0.12, ey - 0.62)), bevel=0.04, segments=1, outline=False, name="teeth"),
           K.sphere(C_TONGUE, 0.3, M((0, -RL - 0.05, ey - 1.05), scale=(1, 0.5, 0.5)), seg=10, rings=6, outline=False, name="tongue")]
    hair = hexcol("hair", "#FF9F2E")
    for i in range(5):
        a = (i - 2) * 0.45
        out.append(K.sphere(hair, 0.32, M((math.sin(a) * 0.5, 0.1, h + 0.25 + math.cos(a) * 0.15), scale=(0.7, 0.7, 1.3)), seg=8, rings=5, name="hair"))
    return out



# Per-type tweaks merged over socks.SPECS (colours, mood, tall/short, ...). Never change `single`.
SPEC_OVERRIDES = {}

FEATURES = {
    "Stinkolino": feat_stinkolino,
    "SockNess": feat_sockness,
    "Shockini": feat_shockini,
    "Lintlord": feat_lintlord,
    "Zillionaire": feat_zillionaire,
    "LostSock": feat_lost,
    "PuppetSupreme": feat_puppet,
}
