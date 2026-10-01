"""
props/blocks.py - the Blocks prop (ReplicatedStorage.MapMeshes.Blocks). See props/__init__.py for
the conventions every prop follows.
"""
import math
import sockkit as K
from sockkit import M, hexcol
from props.common import *  # noqa: F401,F403 - shared colours (read-only)

NAME = "Blocks"


def build():
    p = []
    spec = [("S", RED, -3.7, 0.0, 0.14), ("O", YELLOW, -1.25, 0.25, -0.1), ("C", BLOCK_BLUE, 1.25, -0.1, 0.12), ("K", RED, 3.7, 0.2, -0.16)]
    for letter, col, x, y, yaw in spec:
        base = M((x, y, 1.1), rot=(0, 0, yaw))
        p.append(K.rounded_box(col, (2.2, 2.2, 2.2), base, bevel=0.22, segments=3, name="block"))
        # cream panels on the front, both sides and top, each with the letter
        faces = [((0, -1.12, 0), (math.pi / 2, 0, 0)), ((1.12, 0, 0), (math.pi / 2, 0, math.pi / 2)),
                 ((-1.12, 0, 0), (math.pi / 2, 0, -math.pi / 2)), ((0, 0, 1.12), (0, 0, 0))]
        for off, rot in faces:
            panel = base @ M(off, rot=rot)
            p.append(K.rounded_box(CREAM, (1.7, 1.7, 0.08), panel, bevel=0.06, segments=1, outline=False, name="panel"))
            p.append(K.text(col, letter, size=1.35, depth=0.06, mat=panel @ M((0, 0, 0.06)), name="letter"))
    body, outline = K.finish(p, "Blocks", outline_width=0.06)
    return [body, outline] + K.markers("Blocks")
