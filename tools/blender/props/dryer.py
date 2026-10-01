"""
props/dryer.py - the Dryer prop (ReplicatedStorage.MapMeshes.Dryer). See props/__init__.py for
the conventions every prop follows.
"""
import math
import sockkit as K
from sockkit import M, hexcol
from props.common import *  # noqa: F401,F403 - shared colours (read-only)

NAME = "Dryer"


def build():
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
