"""
props/duck.py - the Duck prop (ReplicatedStorage.MapMeshes.Duck). See props/__init__.py for
the conventions every prop follows.
"""
import math
import sockkit as K
from sockkit import M, hexcol
from props.common import *  # noqa: F401,F403 - shared colours (read-only)

NAME = "Duck"


def build():
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
