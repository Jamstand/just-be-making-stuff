"""
props/lamp.py - the Lamp prop (ReplicatedStorage.MapMeshes.Lamp). See props/__init__.py for
the conventions every prop follows.
"""
import math
import sockkit as K
from sockkit import M, hexcol
from props.common import *  # noqa: F401,F403 - shared colours (read-only)

NAME = "Lamp"


def build():
    p = [K.cylinder(WOOD_D, 1.05, 0.35, M((0, 0, 0.18)), seg=20, name="base"),
         K.cylinder(WOOD, 0.32, 1.1, M((0, 0, 0.9)), seg=12, name="neck"),
         K.cylinder(WOOD_D, 0.62, 0.4, M((0, 0, 1.55)), seg=16, name="collar")]
    glow_shape = K.sphere(GLOBE, 1.45, M((0, 0, 3.0)), seg=24, rings=14, name="globe")
    body, outline = K.finish(p, "Lamp", outline_width=0.05, outline_only=[glow_shape])
    glow = K.plain_object([K.sphere(0, 1.45, M((0, 0, 3.0)), seg=24, rings=14)], "LampGlow")
    return [body, outline, glow] + K.markers("Lamp")
