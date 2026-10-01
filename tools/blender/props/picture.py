"""
props/picture.py - the Picture prop. PLACEHOLDER - to be modelled from the concept art.
"""
import math
import sockkit as K
from sockkit import M, hexcol
from props.common import *  # noqa: F401,F403 - shared colours (read-only)

NAME = "Picture"
EXPORT_DIR = "map"


def build():
    p = [K.rounded_box(WOOD, (1, 1, 1), M((0, 0, 0.5)), bevel=0.1, segments=2, name="placeholder")]
    body, outline = K.finish(p, NAME, outline_width=0.03)
    return [body, outline] + K.markers(NAME)
