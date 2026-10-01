"""
props/drawer.py - the Drawer prop (ReplicatedStorage.MapMeshes.Drawer). See props/__init__.py for
the conventions every prop follows.
"""
import math
import sockkit as K
from sockkit import M, hexcol
from props.common import *  # noqa: F401,F403 - shared colours (read-only)

NAME = "Drawer"


def build():
    """Base shell: back + side walls, a LOW front lip (players walk in), handle. No floor."""
    W, D, Hh, T = 5.2, 3.8, 1.0, 0.25
    p = [K.rounded_box(WOOD, (W, T, Hh), M((0, D / 2 - T / 2, Hh / 2)), bevel=0.06, segments=2, name="back"),
         K.rounded_box(WOOD, (T, D, Hh), M((-W / 2 + T / 2, 0, Hh / 2)), bevel=0.06, segments=2, name="left"),
         K.rounded_box(WOOD, (T, D, Hh), M((W / 2 - T / 2, 0, Hh / 2)), bevel=0.06, segments=2, name="right"),
         K.rounded_box(WOOD_D, (W, 0.3, 0.36), M((0, -D / 2 + 0.15, 0.18)), bevel=0.06, segments=2, name="lip"),
         K.rounded_box(WOOD_D, (1.2, 0.22, 0.16), M((0, -D / 2 - 0.08, 0.2)), bevel=0.06, segments=2, name="handle")]
    # lighter rounded caps on the wall tops
    p.append(K.rounded_box(WOOD_L, (W + 0.06, T + 0.08, 0.1), M((0, D / 2 - T / 2, Hh)), bevel=0.04, segments=1, outline=False, name="cap"))
    for x in (-W / 2 + T / 2, W / 2 - T / 2):
        p.append(K.rounded_box(WOOD_L, (T + 0.08, D + 0.06, 0.1), M((x, 0, Hh)), bevel=0.04, segments=1, outline=False, name="cap"))
    body, outline = K.finish(p, "Drawer", outline_width=0.03)
    return [body, outline] + K.markers("Drawer")
