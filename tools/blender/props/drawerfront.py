"""
props/drawerfront.py - DrawerFront (ReplicatedStorage.MapMeshes.DrawerFront): the full drawer front
that rises when a player slams their drawer. Map.luau welds it to the game's Shutter part, so it
travels with the shutter's tween (hidden under the floor while the drawer is open).

Matches the Drawer shell and the concept's dresser drawers: a bright orange-brown board with a thin
chamfered border, a raised inner panel, a chunky chamfered block handle, light top edges. Studs:
48 x 9 x 1.6 plus the handle (the Map fit box is 48 x 9 x 3.6). Front -Y, origin bottom centre.
"""
import sockkit as K
from sockkit import M
from props.drawer import WOOD_B, WOOD_S, WOOD_T, WOOD_TM

NAME = "DrawerFront"

W, H, T = 48.0, 9.0, 1.6


def _paint(piece, side=WOOD_B):
    piece.face_pal = [WOOD_T if f.normal.z > 0.6 else (WOOD_S if f.normal.z < -0.6 else side) for f in piece.mesh.polygons]
    return piece


def build():
    p = []
    board = K.rounded_box(WOOD_B, (W, T, H), M((0, 0, H / 2)), bevel=0.4, segments=1, name="board")
    p.append(_paint(board))
    # raised inner panel: a slightly lighter-edged slab 0.35 proud of the board, inset 1.6 all round
    panel = K.rounded_box(WOOD_B, (W - 3.2, 0.5, H - 3.2), M((0, -T / 2 - 0.1, H / 2)), bevel=0.3, segments=1, name="panel")
    panel.face_pal = [WOOD_T if f.normal.z > 0.6 else (WOOD_S if f.normal.z < -0.6 else (WOOD_TM if abs(f.normal.x) > 0.6 else WOOD_B)) for f in panel.mesh.polygons]
    p.append(panel)
    # chunky block handle in the middle (like the concept's drawers)
    p.append(_paint(K.rounded_box(WOOD_B, (9.0, 2.2, 3.0), M((0, -T / 2 - 0.35 - 1.0, H / 2)), bevel=0.6, segments=1, name="handle")))
    body, outline = K.finish(p, NAME, outline_width=0.12)
    return [body, outline] + K.markers(NAME)
