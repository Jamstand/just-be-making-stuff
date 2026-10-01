"""
props/basket.py - the Basket prop (ReplicatedStorage.MapMeshes.Basket). See props/__init__.py for
the conventions every prop follows.
"""
import math
import sockkit as K
from sockkit import M, hexcol
from props.common import *  # noqa: F401,F403 - shared colours (read-only)

NAME = "Basket"


def build():
    p = [K.cylinder(WICKER, 1.55, 2.0, M((0, 0, 1.0)), seg=24, radius2=1.75, name="tub")]
    for i in range(16):
        a = i / 16 * math.tau
        p.append(K.rounded_box(WICKER_D, (0.22, 0.12, 1.85), M((math.cos(a) * 1.65, math.sin(a) * 1.65, 1.0), rot=(0, -0.1, a)), bevel=0.04, segments=1, outline=False, name="slat"))
    p.append(K.torus(WICKER_D, 1.78, 0.18, M((0, 0, 2.0)), seg=24, mseg=8, name="rim"))
    for x in (-1.8, 1.8):
        p.append(K.torus(WICKER_D, 0.45, 0.12, M((x, 0, 1.95), rot=(math.pi / 2, 0, math.pi / 2)), seg=14, mseg=6, name="handle"))
    for i, (x, y, z, r) in enumerate(((0, 0, 2.2, 1.25), (0.8, 0.5, 2.6, 0.75), (-0.7, -0.4, 2.7, 0.8), (0.2, -0.8, 2.9, 0.65), (-0.3, 0.7, 3.0, 0.6))):
        p.append(K.sphere(LINT if i % 2 == 0 else LINT_D, r, M((x, y, z)), seg=14, rings=8, name="lint"))
    body, outline = K.finish(p, "Basket", outline_width=0.05)
    return [body, outline] + K.markers("Basket")
