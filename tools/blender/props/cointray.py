"""
props/cointray.py - CollectTray (ReplicatedStorage.MapMeshes.CollectTray): a gold tray framing each
drawer's green Collect pad, with little stacks of gold coins on its back corners. Map.luau puts it
round the CollectPad part (which keeps its glow, text and Touched hit-box).

A U of gold rims (back + sides; the pad sits against the drawer's front board, so the board is the
tray's front) with a "$" medallion facing the pad and coin stacks on the corners. Studs: 13 x 6.6 x
~2.4, the opening 10.2 x 5.2 fits the 10 x 5 pad. Origin = the pad's centre on the floor, front -Y
(toward the drawer's open front).
"""
import math

import sockkit as K
from sockkit import M, hexcol

NAME = "CollectTray"

GOLD = hexcol("tray_gold", "#F2C14E")
GOLD_T = hexcol("tray_gold_top", "#FFE08A")
GOLD_D = hexcol("tray_gold_dark", "#B98426")
COIN_EDGE = hexcol("tray_coin_edge", "#D9A23A")

OX, OY = 6.5, 4.0     # outer half sizes
IX, IY = 5.1, 2.6     # opening half sizes
RIM_H = 0.9


def _tone(piece, base=GOLD):
    piece.face_pal = [GOLD_T if f.normal.z > 0.6 else (GOLD_D if f.normal.z < -0.5 else base) for f in piece.mesh.polygons]
    return piece


def _coin_stack(x, y, n, seed):
    out = []
    for i in range(n):
        jx = 0.08 * math.sin(seed * 3.1 + i * 1.7)
        jy = 0.08 * math.cos(seed * 2.3 + i * 2.1)
        coin = K.cylinder(GOLD, 0.72, 0.24, M((x + jx, y + jy, RIM_H + 0.12 + i * 0.25)), seg=16, name="coin")
        coin.face_pal = [GOLD_T if f.normal.z > 0.6 else (GOLD_D if f.normal.z < -0.6 else COIN_EDGE) for f in coin.mesh.polygons]
        out.append(coin)
    return out


def build():
    p = []
    bw, bd = (OX - IX), (OY - IY)
    # U of rim bars: back full width, sides from the pad's front edge back to it - rounded, one tone ramp
    yb = IY + bd / 2
    p.append(_tone(K.rounded_box(GOLD, (OX * 2, bd, RIM_H), M((0, yb, RIM_H / 2)), bevel=0.18, segments=2, name="rim_b")))
    for sx in (-1, 1):
        p.append(_tone(K.rounded_box(GOLD, (bw, IY * 2 + bd / 2, RIM_H), M((sx * (IX + bw / 2), bd / 4, RIM_H / 2)), bevel=0.18, segments=2, name="rim_s")))
    # a raised "$" medallion on the back rim, facing the pad (and the player walking in)
    mz = 0.62  # medallion centre: high enough that it never dips under the floor
    p.append(_tone(K.cylinder(GOLD, 0.55, 0.18, M((0, IY - 0.02, mz), rot=(math.pi / 2, 0, 0)), seg=20, name="medal")))
    p.append(K.text(GOLD_D, "$", size=0.72, depth=0.05, mat=M((0, IY - 0.14, mz - 0.24), rot=(math.pi / 2, 0, 0)), name="dollar"))
    # coin stacks on the back corners and on the front end of the left rim
    p += _coin_stack(-(OX - 0.55), yb - 0.05, 5, 1)
    p += _coin_stack(OX - 0.6, yb - 0.1, 3, 2)
    p += _coin_stack(-(OX - 0.6), -IY + 0.7, 2, 3)
    body, outline = K.finish(p, NAME, outline_width=0.06)
    return [body, outline] + K.markers(NAME)
