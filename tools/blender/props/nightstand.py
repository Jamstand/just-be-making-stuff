"""
props/nightstand.py - the Nightstand prop (ReplicatedStorage.MapMeshes.Nightstand). See props/__init__.py for
the conventions every prop follows.
"""
import math
import sockkit as K
from sockkit import M, hexcol
from props.common import *  # noqa: F401,F403 - shared colours (read-only)

NAME = "Nightstand"


def build():
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
