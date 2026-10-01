"""
props/crayons.py - the Crayons prop (ReplicatedStorage.MapMeshes.Crayons). See props/__init__.py for
the conventions every prop follows.
"""
import math
import sockkit as K
from sockkit import M, hexcol
from props.common import *  # noqa: F401,F403 - shared colours (read-only)

NAME = "Crayons"


def build():
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
