"""
props/teddy.py - the Teddy prop (ReplicatedStorage.MapMeshes.Teddy). See props/__init__.py for
the conventions every prop follows.
"""
import math
import sockkit as K
from sockkit import M, hexcol
from props.common import *  # noqa: F401,F403 - shared colours (read-only)

NAME = "Teddy"


def build():
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
