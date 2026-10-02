"""
props/desk.py - the Desk prop (ReplicatedStorage.MapMeshes.Desk): a chunky kid's desk that stands against a
wall of the bedroom. See props/__init__.py for the conventions every prop follows.

Same furniture language as the wardrobe / dresser / nightstand (docs/concept/bedroom_keyframe.png): warm
orange-brown wood in 2-3 flat tones, flat 45-degree chamfers, chunky block handles on dark ink plates.
- a thick chamfered top that overhangs all round;
- a drawer pedestal on the right (two drawers with block handles, raised side panels, short block feet);
- open on the left: two fat turned round legs (collar rings, bun feet) with a side rail and a low stretcher,
  a front apron across the knee space and a back panel;
- on top: a teal desk lamp (round base, ribbed bendy gooseneck, warm yellow shade, glowing bulb), a globe
  on a stand (tilted, blue sea, green / yellow land, a meridian arc), a red pencil cup with pencils and
  crayons, an open notebook with a crayon scribble (a sun, a house and a sock) and a crayon beside it, a
  yellow ruler, and a striped sock lying by the notebook's corner with its foot dangling over the front edge;
- a star and a heart sticker on the drawer fronts (a kid's desk).

Units: 1 unit = 10 studs. Map.luau fits the prop into 200 x 115 x 100 studs (W x H x D), so the whole thing,
lamp and sock included, is 20.0 x 11.5 x 10.0 units: the desk top is at 8.6 (a kid's desk next to the 30-unit
wardrobe; the DeskChair's seat is at ~5.2 at the same scale). The back is flat (it stands against a wall).
Origin = floor centre, front faces -Y.
"""
import math
import bmesh
from mathutils import Matrix, Vector
import sockkit as K
from sockkit import M, hexcol
from props.dresser import sock, sweep
from props.wardrobe import (tone, chamfer_box, lathe, plate, shape, no_bounce, flat_big_faces)

NAME = "Desk"

# texture classes for tools/blender/texturing.py where the colour names alone guess wrong
MATERIALS = {"desk_lamp": "plastic", "desk_lamp_bulb": "glass", "desk_globe": "plastic", "desk_globe_metal": "metal",
             "desk_crayon": "plastic", "desk_crayon_*_wrap": "paper", "desk_pencil": "paintwood",
             "desk_pencil_wood": "wood", "desk_pencil_lead": "painted", "desk_shadow": "wood"}

# ---- colours
WOOD = hexcol("desk_wood", "#C4633A")
WOOD_L = hexcol("desk_wood_light", "#E8914A")
WOOD_D = hexcol("desk_wood_dark", "#8A3E2A")
PANEL = hexcol("desk_panel", "#B2552F")
SHADOW = hexcol("desk_shadow", "#6E3024")      # back panel seen through the knee space
INK = K.OUTLINE
# lamp
LAMP = hexcol("desk_lamp", "#2FA8A0")
LAMP_L = hexcol("desk_lamp_light", "#55C8BC")
LAMP_D = hexcol("desk_lamp_dark", "#1E7A78")
SHADE = hexcol("desk_lamp_shade", "#FFB238")
SHADE_L = hexcol("desk_lamp_shade_light", "#FFCF6A")
SHADE_D = hexcol("desk_lamp_shade_dark", "#E08A22")
SHADE_IN = hexcol("desk_lamp_shade_inside", "#FFF1C2")
BULB = hexcol("desk_lamp_bulb", "#FFF6D6")
# globe
SEA = hexcol("desk_globe_sea", "#4F9BE8")
SEA_D = hexcol("desk_globe_sea_dark", "#3A78C4")
LAND = hexcol("desk_globe_land", "#6CC46A")
LAND2 = hexcol("desk_globe_land_yellow", "#F2D46A")
METAL = hexcol("desk_globe_metal", "#E8B84A")
METAL_D = hexcol("desk_globe_metal_dark", "#B58428")
STAND = hexcol("desk_globe_stand", "#3F5BB0")
STAND_L = hexcol("desk_globe_stand_light", "#5C7FD1")
# pencil cup, pencils, crayons
CUP = hexcol("desk_cup", "#E0483F")
CUP_L = hexcol("desk_cup_light", "#F06A58")
CUP_D = hexcol("desk_cup_dark", "#A8302E")
CUP_BAND = hexcol("desk_cup_band", "#FFF0D0")
CUP_IN = hexcol("desk_cup_inside", "#4A1A1C")
PENCIL = hexcol("desk_pencil", "#FFC93C")
PENCIL_D = hexcol("desk_pencil_dark", "#E3A21E")
PENCIL_WOOD = hexcol("desk_pencil_wood", "#F5D3A0")
LEAD = hexcol("desk_pencil_lead", "#3A3340")
CRAYONS = [(hexcol("desk_crayon_green", "#46A524"), hexcol("desk_crayon_green_wrap", "#CFD972")),
           (hexcol("desk_crayon_blue", "#3D46B4"), hexcol("desk_crayon_blue_wrap", "#6C80D2")),
           (hexcol("desk_crayon_orange", "#EE7812"), hexcol("desk_crayon_orange_wrap", "#F7D46A")),
           (hexcol("desk_crayon_purple", "#8455C4"), hexcol("desk_crayon_purple_wrap", "#C9A8FF"))]
# notebook
COVER = hexcol("desk_notebook_cover", "#4F7FD6")
COVER_D = hexcol("desk_notebook_cover_dark", "#3A5EAA")
PAGE = hexcol("desk_notebook_page", "#FFF8E8")
PAGE_D = hexcol("desk_notebook_page_edge", "#E6D9BC")
LINE = hexcol("desk_notebook_line", "#A9C4EA")
SCRIB_SUN = hexcol("desk_scribble_sun", "#FFC21E")
SCRIB_RED = hexcol("desk_scribble_red", "#E0483F")
SCRIB_GRN = hexcol("desk_scribble_green", "#46A524")
SCRIB_BLU = hexcol("desk_scribble_blue", "#3D6FD0")
# the sock
SK_BODY = hexcol("desk_sock", "#FFD24A")
SK_STRIPE = hexcol("desk_sock_stripe", "#F27A9E")
SK_ACC = hexcol("desk_sock_accent", "#E05A84")
SK_IN = hexcol("desk_sock_inner", "#3A2F4E")
# ruler and stickers
RULER = hexcol("desk_ruler", "#F2C14E")
RULER_D = hexcol("desk_ruler_dark", "#C9922E")
TICK = hexcol("desk_ruler_tick", "#6A4A1E")
STICKER_Y = hexcol("desk_sticker_star", "#FFD23F")
STICKER_P = hexcol("desk_sticker_heart", "#F27A9E")
STICKER_W = hexcol("desk_sticker_border", "#FFF8E8")

# ---- dimensions (units)
TOP_Z1, TOP_T = 8.6, 0.85
TOP_W = 20.0
TOP_Y0, TOP_Y1 = -4.65, 4.95
BACK_Y = 4.85                   # back plane of the pedestal / back panel
FRONT_Y = -4.1                  # pedestal front
FOOT_H = 0.55
PED_X0, PED_X1 = 3.3, 9.35      # the drawer pedestal (right)
PED_Z0, PED_Z1 = FOOT_H, TOP_Z1 - TOP_T + 0.05
LEG_X = -9.0                    # the open side's legs (left)
LEG_YS = (-3.55, 4.2)
LEG_R = 0.62
APRON_Z0 = 6.9
DRAWERS = [(4.35, 7.35), (1.0, 4.0)]
GAP = 0.06
OUTLINE_W = 0.14                # same ink weight as the Wardrobe / DeskChair at the same scale


# ---------------------------------------------------------------- desk
def _pedestal():
    out = []
    w, d = PED_X1 - PED_X0, BACK_Y - FRONT_Y
    xc, yc = (PED_X0 + PED_X1) / 2, (BACK_Y + FRONT_Y) / 2
    body = K.rounded_box(WOOD, (w, d, PED_Z1 - PED_Z0), M((xc, yc, (PED_Z0 + PED_Z1) / 2)), bevel=0.14, segments=2,
                         name="pedestal")
    out.append(flat_big_faces(tone(body, WOOD, WOOD_L, WOOD_D), 0.5))
    # raised panels on both sides
    for sx in (PED_X0, PED_X1):
        p = chamfer_box(PANEL, (0.22, d - 1.2, PED_Z1 - PED_Z0 - 1.3), M((sx, yc, (PED_Z0 + PED_Z1) / 2 - 0.1)), 0.09,
                        "side_panel")
        out.append(tone(p, PANEL, WOOD_L, WOOD_D))
    # feet
    fw = 1.1
    for x in (PED_X0 + 0.2 + fw / 2, PED_X1 - 0.2 - fw / 2):
        for y in (FRONT_Y + 0.2 + fw / 2, BACK_Y - 0.2 - fw / 2):
            out.append(tone(chamfer_box(WOOD, (fw, fw, FOOT_H + 0.12), M((x, y, (FOOT_H + 0.12) / 2)), 0.12, "foot",
                                        taper=(0.82, 0.82)), WOOD, WOOD_L, WOOD_D))
    # two drawers with block handles
    dw = w - 0.8
    ft = 0.36
    for z0, z1 in DRAWERS:
        zc, h = (z0 + z1) / 2, z1 - z0
        out.append(plate((dw + 2 * GAP, 0.1, h + 2 * GAP), M((xc, FRONT_Y - 0.02, zc)), name="drawer_gap"))
        board = chamfer_box(WOOD, (dw, ft, h), M((xc, FRONT_Y - 0.04 - ft / 2, zc)), 0.18, "drawer")
        out.append(tone(board, WOOD, WOOD_L, WOOD_D))
        yf = FRONT_Y - 0.04 - ft
        hw, hh, hd = 1.55, 0.7, 0.45
        out.append(plate((hw + 0.14, 0.08, hh + 0.14), M((xc, yf - 0.02, zc + 0.15)), name="handle_gap"))
        out.append(tone(chamfer_box(WOOD, (hw, hd + 0.06, hh), M((xc, yf - 0.04 - hd / 2, zc + 0.15)), 0.15, "handle"),
                        WOOD, WOOD_L, WOOD_D))
    return out


def _leg(x, y):
    """A fat turned leg: bun foot, slightly tapered shaft, a collar ring under the apron."""
    r = LEG_R
    z1 = PED_Z1
    prof = [(0, 0), (r * 0.78, 0), (r * 0.98, 0.12), (r * 1.02, 0.32), (r * 0.86, 0.55), (r * 0.74, 0.7),
            (r * 0.8, 2.0), (r * 0.9, APRON_Z0 - 0.75), (r * 1.12, APRON_Z0 - 0.62), (r * 1.12, APRON_Z0 - 0.36),
            (r * 0.95, APRON_Z0 - 0.24), (r * 0.95, z1), (0, z1)]
    p = lathe(WOOD, prof, M((x, y, 0)), seg=12, name="leg")
    return tone(p, WOOD, WOOD_L, WOOD_D, up=0.55, down=-0.55)


def _frame():
    """Legs, aprons, stretcher and the back panel on the open (left) side."""
    out = [_leg(LEG_X, y) for y in LEG_YS]
    t = 0.5
    # front apron across the knee space (into the left leg and the pedestal)
    x0, x1 = LEG_X, PED_X0 + 0.1
    yf = LEG_YS[0]
    ap = chamfer_box(WOOD, (x1 - x0, t, PED_Z1 - APRON_Z0), M(((x0 + x1) / 2, yf, (APRON_Z0 + PED_Z1) / 2)), 0.1, "apron")
    out.append(tone(ap, WOOD, WOOD_L, WOOD_D))
    # side apron between the legs
    sa = chamfer_box(WOOD, (t, LEG_YS[1] - LEG_YS[0], PED_Z1 - APRON_Z0),
                     M((LEG_X, (LEG_YS[0] + LEG_YS[1]) / 2, (APRON_Z0 + PED_Z1) / 2)), 0.1, "side_apron")
    out.append(tone(sa, WOOD, WOOD_L, WOOD_D))
    # low stretcher between the legs
    st = K.cylinder(WOOD, 0.22, LEG_YS[1] - LEG_YS[0], M((LEG_X, (LEG_YS[0] + LEG_YS[1]) / 2, 1.45), (math.pi / 2, 0, 0)),
                    seg=8, name="stretcher")
    out.append(tone(st, WOOD, WOOD_L, WOOD_D, up=0.5, down=-0.5))
    # back panel (between the back leg and the pedestal), in shadow under the top
    bz0 = 3.6
    bp = chamfer_box(SHADOW, (PED_X0 - LEG_X, 0.4, PED_Z1 - bz0), M(((LEG_X + PED_X0) / 2, BACK_Y - 0.2, (bz0 + PED_Z1) / 2)),
                     0.1, "back_panel")
    out.append(tone(bp, SHADOW, SHADOW, WOOD_D))
    return out


def _top():
    slab = chamfer_box(WOOD, (TOP_W, TOP_Y1 - TOP_Y0, TOP_T), M((0, (TOP_Y0 + TOP_Y1) / 2, TOP_Z1 - TOP_T / 2)), 0.24,
                       "top")
    return [tone(slab, WOOD, WOOD_L, WOOD_D)]


# ---------------------------------------------------------------- lamp
def _lamp(cx, cy):
    """Teal desk lamp: round chamfered base, a ribbed bendy gooseneck, a warm yellow shade tipped toward the
    notebook, a glowing bulb inside."""
    out = []
    z0 = TOP_Z1
    base = lathe(LAMP, [(0, 0), (1.05, 0), (1.05, 0.2), (0.82, 0.42), (0.3, 0.46), (0, 0.46)], M((cx, cy, z0)), seg=16,
                 name="lamp_base")
    out.append(tone(base, LAMP, LAMP_L, LAMP_D, up=0.45))
    # a knob on the base
    out.append(K.sphere(SHADE, 0.18, M((cx + 0.55, cy - 0.45, z0 + 0.42), scale=(1, 1, 0.7)), seg=8, rings=4,
                        name="lamp_knob"))
    # gooseneck: up from the base, arcing forward and over toward the front-right
    tip = Vector((cx + 1.45, cy - 1.55, z0 + 2.45))
    ctrl = [(cx, cy, z0 + 0.3), (cx, cy + 0.05, z0 + 1.2), (cx + 0.15, cy - 0.2, z0 + 2.25),
            (cx + 0.75, cy - 0.85, z0 + 2.75), tuple(tip)]
    hints = [(0, -1, 0), (0, -1, 0), (0, -1, 0.3), (0, -0.4, 1), (0, -0.4, 1)]
    me, info, L = sweep(ctrl, hints, 0.16, 0.16, step=0.13, sides=8, tip=False, squash=2.0)
    pal = []
    for kind, r, k, d, hw in info:
        pal.append(LAMP_D if kind == "cap" else (LAMP_L if r % 2 == 0 else LAMP))
    arm = K.Piece(me, pal, outline=True, smooth=True, name="gooseneck")
    out.append(arm)
    # shade: a cone opening down / forward, from the gooseneck tip
    axis = Vector((0.45, -0.55, -1.0)).normalized()
    rot = axis.to_track_quat("Z", "Y").to_matrix().to_4x4()   # local +Z along the axis (toward the mouth)
    sl = 1.0
    c = tip + axis * (sl / 2 - 0.05)
    shade = K.cylinder(SHADE, 0.38, sl, Matrix.Translation(c) @ rot, seg=16, radius2=0.95, name="shade")
    # outside: lit top half, darker underside; the end caps: top one shade, mouth = bright inside
    pal = []
    for f in shade.mesh.polygons:
        if len(f.vertices) > 4:
            pal.append(SHADE_IN if (Vector(f.center) - c).dot(axis) > 0 else SHADE)
        else:
            pal.append(SHADE_L if f.normal.z > 0.35 else (SHADE_D if f.normal.z < -0.35 else SHADE))
    shade.face_pal = pal
    out.append(shade)
    # a rolled rim round the mouth and the bulb peeking out
    rim = K.torus(SHADE, 0.93, 0.07, Matrix.Translation(tip + axis * (sl - 0.02)) @ rot, seg=16, mseg=4, name="shade_rim")
    out.append(tone(rim, SHADE, SHADE_L, SHADE_D, up=0.3, down=-0.3))
    out.append(K.sphere(BULB, 0.42, Matrix.Translation(tip + axis * (sl - 0.15)) @ rot, seg=10, rings=6, outline=False,
                        name="bulb"))
    out.append(K.sphere(LAMP, 0.22, Matrix.Translation(tip), seg=8, rings=5, name="lamp_joint"))
    return out


# ---------------------------------------------------------------- globe
def _patch(center, r0, wob, rad, mat, pal, n=14):
    """A soft continent: a thin curved patch on a sphere of radius `rad` (origin at the sphere centre, placed by
    mat) round direction `center`, angular radius r0 with a wobbly outline (wob = two wave amplitudes + phase)."""
    c = Vector(center).normalized()
    u = c.orthogonal().normalized()
    v = c.cross(u)
    a1, a2, ph = wob
    bm = bmesh.new()
    mid, outer = [], []
    for k in range(n):
        t = k / n * math.tau
        r = r0 * (1 + a1 * math.sin(3 * t + ph) + a2 * math.sin(2 * t + 2 * ph))
        dirn = u * math.cos(t) + v * math.sin(t)
        outer.append(bm.verts.new((c * math.cos(r) + dirn * math.sin(r)) * rad))
        mid.append(bm.verts.new((c * math.cos(r / 2) + dirn * math.sin(r / 2)) * rad))
    ctr = bm.verts.new(c * rad)
    for k in range(n):
        k2 = (k + 1) % n
        bm.faces.new((ctr, mid[k], mid[k2]))
        bm.faces.new((mid[k], outer[k], outer[k2], mid[k2]))
    bm.normal_update()
    for f in bm.faces:
        if f.normal.dot(f.calc_center_median()) < 0:
            f.normal_flip()
    bmesh.ops.transform(bm, matrix=mat, verts=bm.verts)
    return K.Piece(K._bm_to_mesh(bm, "land"), pal, outline=False, smooth=True, name="land")


def _globe(cx, cy):
    out = []
    z0 = TOP_Z1
    base = lathe(STAND, [(0, 0), (0.9, 0), (0.9, 0.16), (0.6, 0.36), (0.2, 0.42), (0.17, 0.55), (0, 0.55)],
                 M((cx, cy, z0)), seg=14, name="globe_base")
    out.append(tone(base, STAND, STAND_L, STAND, up=0.45))
    R = 1.02
    gc = Vector((cx, cy, z0 + 0.55 + 0.12 + R))
    tilt = Matrix.Rotation(math.radians(23), 4, "Y") @ Matrix.Rotation(-0.4, 4, "Z")
    g = K.sphere(SEA, R, Matrix.Translation(gc) @ tilt, seg=18, rings=10, name="globe")
    out.append(tone(g, SEA, SEA, SEA_D, up=2, down=-0.55))
    # land: soft rounded continents (thin patches hugging the ball) and two ice caps, in the globe's own frame
    m = Matrix.Translation(gc) @ tilt
    for d, r0, wob, col in (((0.6, -0.75, 0.3), 0.5, (0.22, 0.12, 0.4), LAND), ((-0.15, -0.95, -0.45), 0.34, (0.2, 0.15, 2.0), LAND2),
                            ((0.95, 0.2, -0.35), 0.38, (0.25, 0.1, 1.1), LAND), ((-0.75, -0.25, 0.5), 0.42, (0.2, 0.18, 2.6), LAND2),
                            ((-0.5, 0.8, -0.1), 0.48, (0.22, 0.12, 0.9), LAND), ((0.3, 0.6, 0.72), 0.3, (0.18, 0.1, 1.7), LAND2),
                            ((0, 0, 1), 0.3, (0.0, 0.0, 0.0), K.WHITE), ((0, 0, -1), 0.3, (0.0, 0.0, 0.0), K.WHITE)):
        out.append(_patch(d, r0, wob, R + 0.012, m, col))
    # the meridian: a half ring round the globe in the tilt plane, holding it at both poles
    rr = R + 0.14
    axis = (tilt.to_3x3() @ Vector((0, 0, 1))).normalized()
    side = (tilt.to_3x3() @ Vector((1, 0, 0))).normalized()
    pts = [gc + (axis * math.cos(a) + side * math.sin(a)) * rr for a in (math.radians(v) for v in range(-180, 1, 30))]
    pts = [gc - axis * rr - Vector((0, 0, 0.02))] + pts[1:]
    arc = K.tube(METAL, [tuple(p) for p in pts], radius=0.075, res=3, bevel_res=0, name="meridian")
    out.append(tone(arc, METAL, METAL, METAL_D, up=0.3, down=-0.3))
    for s in (-1, 1):
        out.append(K.sphere(METAL, 0.12, Matrix.Translation(gc + axis * s * (R + 0.05)), seg=8, rings=4, name="pivot"))
    # the stem from the base up to the bottom of the meridian
    bottom = gc - axis * rr
    out.append(K.cylinder(METAL, 0.09, bottom.z - (z0 + 0.5), M((cx + (bottom.x - cx) / 2, cy + (bottom.y - cy) / 2,
                                                                  (bottom.z + z0 + 0.5) / 2)), seg=8, name="stem"))
    return out


# ---------------------------------------------------------------- pencil cup
def _pencil(base, d, length, name="pencil"):
    """A yellow hexagonal pencil standing tip-up from `base` along direction d: faceted body, sharpened wood
    cone and a graphite point."""
    out = []
    rot = Vector(d).normalized().to_track_quat("Z", "Y").to_matrix().to_4x4()
    m = Matrix.Translation(Vector(base)) @ rot
    r = 0.14
    body = K.cylinder(PENCIL, r, length, m @ M((0, 0, length / 2)), seg=6, name=name)
    body.face_pal = [PENCIL_D if (i % 2) else PENCIL for i in range(len(body.mesh.polygons))]
    body.smooth = False
    out.append(body)
    cone = K.cylinder(PENCIL_WOOD, r, 0.34, m @ M((0, 0, length + 0.17)), seg=6, radius2=0.04, name=name + "_tip")
    cone.smooth = False
    out.append(cone)
    out.append(K.cylinder(LEAD, 0.05, 0.08, m @ M((0, 0, length + 0.36)), seg=6, radius2=0.012, outline=False,
                          name=name + "_lead"))
    return out


def _crayon(base, d, length, cols, name="crayon"):
    out = []
    wax, wrap = cols
    rot = Vector(d).normalized().to_track_quat("Z", "Y").to_matrix().to_4x4()
    m = Matrix.Translation(Vector(base)) @ rot
    r = 0.17
    out.append(K.cylinder(wax, r, length, m @ M((0, 0, length / 2)), seg=8, name=name))
    out.append(K.cylinder(wrap, r + 0.025, length * 0.5, m @ M((0, 0, length * 0.45)), seg=8, outline=False,
                          name=name + "_wrap"))
    out.append(K.cylinder(wax, r * 0.9, 0.35, m @ M((0, 0, length + 0.17)), seg=8, radius2=0.06, name=name + "_tip"))
    return out


def _pencil_cup(cx, cy):
    out = []
    z0 = TOP_Z1
    h, r = 1.4, 0.72
    cup = lathe(CUP, [(0, 0), (r - 0.04, 0), (r, 0.06), (r + 0.04, h), (r - 0.1, h), (r - 0.12, 0.25), (0, 0.25)],
                M((cx, cy, z0)), seg=14, name="cup")
    pal = []
    for f in cup.mesh.polygons:
        c = Vector(f.center)
        inside = (c.xy - Vector((cx, cy))).length < r - 0.05 and f.normal.z > -0.5
        pal.append(CUP_IN if inside else (CUP_L if f.normal.z > 0.6 else (CUP_D if f.normal.z < -0.6 else CUP)))
    cup.face_pal = pal
    out.append(cup)
    band = K.cylinder(CUP_BAND, r + 0.045, 0.22, M((cx, cy, z0 + h * 0.55)), seg=14, outline=False, cap=False,
                      radius2=r + 0.05, name="cup_band")
    out.append(band)
    zb = z0 + 0.3
    out += _pencil((cx - 0.15, cy - 0.1, zb), (-0.35, -0.15, 1), 1.75, "pencil")
    out += _pencil((cx + 0.15, cy + 0.15, zb), (0.25, 0.3, 1), 1.95, "pencil")
    out += _crayon((cx + 0.2, cy - 0.2, zb), (0.4, -0.35, 1), 1.35, CRAYONS[0])
    out += _crayon((cx - 0.2, cy + 0.2, zb), (-0.3, 0.35, 1), 1.5, CRAYONS[1])
    out += _crayon((cx + 0.02, cy - 0.28, zb), (0.05, -0.45, 1), 1.2, CRAYONS[2])
    return out


# ---------------------------------------------------------------- notebook
def _ribbon(pal, pts, width, mat, name="scribble"):
    """A flat strip along the 2D polyline pts (page-local x, y) at local z = 0, placed by mat; no outline."""
    bm = bmesh.new()
    pts = [Vector((x, y)) for x, y in pts]
    left, right = [], []
    for i, p in enumerate(pts):
        a = pts[max(i - 1, 0)]
        b = pts[min(i + 1, len(pts) - 1)]
        t = (b - a).normalized()
        n = Vector((-t.y, t.x)) * (width / 2)
        left.append(bm.verts.new((p.x + n.x, p.y + n.y, 0)))
        right.append(bm.verts.new((p.x - n.x, p.y - n.y, 0)))
    for i in range(len(pts) - 1):
        f = bm.faces.new((right[i], right[i + 1], left[i + 1], left[i]))
        if f.normal.z < 0:
            f.normal_flip()
    bmesh.ops.transform(bm, matrix=mat, verts=bm.verts)
    return K.Piece(K._bm_to_mesh(bm, name), pal, outline=False, smooth=False, name=name)


def _notebook(cx, cy, rz):
    """An open notebook: blue cover, two cream page blocks tipped up a little from the spine, ruled lines on the
    left page, a crayon drawing on the right one (sun, house, a sock), and a crayon lying beside it."""
    out = []
    z0 = TOP_Z1
    m = M((cx, cy, z0), (0, 0, rz))
    pw, ph = 2.65, 3.5            # one page
    cover = chamfer_box(COVER, (2 * pw + 0.35, ph + 0.3, 0.1), m @ M((0, 0, 0.05)), 0.03, "cover")
    out.append(tone(cover, COVER, COVER, COVER_D, up=0.5, down=-0.5))
    pages = []
    for s in (-1, 1):
        tilt = M((s * 0.06, 0, 0.1), (0, -s * math.radians(4), 0))
        pm = m @ tilt @ M((s * pw / 2, 0, 0.11))
        page = chamfer_box(PAGE, (pw, ph, 0.22), pm, 0.05, "pages")
        out.append(tone(page, PAGE, PAGE, PAGE_D, up=0.5, down=-2))
        pages.append(pm @ M((0, 0, 0.115)))
    lp, rp = pages
    # ruled lines on the left page
    for k in range(7):
        y = ph / 2 - 0.55 - k * 0.42
        out.append(_ribbon(LINE, [(-pw / 2 + 0.3, y), (pw / 2 - 0.25, y)], 0.05, lp, name="ruled"))
    # a crayon scribble on the right page: sun with rays, a house with a door, a red sock, green grass - bold
    # strokes, as a kid draws with a fat crayon
    sw = 0.13
    sun = [(math.cos(a) * 0.36 + 0.62, math.sin(a) * 0.36 + 1.02) for a in (i / 10 * math.tau for i in range(11))]
    out.append(_ribbon(SCRIB_SUN, sun, sw, rp, name="sun"))
    for k in range(7):
        a = k / 7 * math.tau + 0.3
        out.append(_ribbon(SCRIB_SUN, [(0.62 + math.cos(a) * 0.52, 1.02 + math.sin(a) * 0.52),
                                       (0.62 + math.cos(a) * 0.78, 1.02 + math.sin(a) * 0.78)], sw * 0.85, rp, name="ray"))
    house = [(-1.0, -0.95), (-1.0, 0.1), (-0.5, 0.7), (0.0, 0.1), (0.0, -0.95), (-1.0, -0.95), (-1.0, 0.1), (0.0, 0.1)]
    out.append(_ribbon(SCRIB_BLU, house, sw, rp, name="house"))
    out.append(_ribbon(SCRIB_RED, [(-0.62, -0.95), (-0.62, -0.42), (-0.36, -0.42), (-0.36, -0.95)], sw * 0.85, rp,
                       name="door"))
    sock_line = [(0.42, 0.42), (0.47, -0.35), (0.55, -0.68), (0.9, -0.82), (1.05, -0.62), (0.82, -0.45), (0.8, 0.42),
                 (0.42, 0.42)]
    out.append(_ribbon(SCRIB_RED, sock_line, sw, rp, name="sock_doodle"))
    grass = [(-1.15 + 0.2 * k, -1.2 + (0.18 if k % 2 else 0.0)) for k in range(12)]
    out.append(_ribbon(SCRIB_GRN, grass, sw, rp, name="grass"))
    # a red crayon lying beside the notebook
    cm = m @ M((pw + 0.6, -0.4, 0.2), (0, math.pi / 2, 0.5))
    out.append(K.cylinder(SCRIB_RED, 0.19, 1.6, cm, seg=8, name="loose_crayon"))
    out.append(K.cylinder(CRAYONS[3][1], 0.215, 0.8, cm @ M((0, 0, -0.1)), seg=8, outline=False, name="loose_wrap"))
    out.append(K.cylinder(SCRIB_RED, 0.17, 0.36, cm @ M((0, 0, 0.98)), seg=8, radius2=0.06, name="loose_tip"))
    return out


# ---------------------------------------------------------------- ruler, stickers
def _ruler(cx, cy, rz):
    out = []
    m = M((cx, cy, TOP_Z1 + 0.05), (0, 0, rz))
    w, d = 3.8, 0.75
    r = chamfer_box(RULER, (w, d, 0.1), m, 0.03, "ruler")
    out.append(tone(r, RULER, RULER, RULER_D, up=0.5, down=-0.5))
    top = m @ M((0, 0, 0.055))
    for k in range(13):
        x = -w / 2 + 0.25 + k * (w - 0.5) / 12
        ln = 0.3 if k % 4 == 0 else 0.16
        out.append(_ribbon(TICK, [(x, d / 2 - 0.06), (x, d / 2 - 0.06 - ln)], 0.045, top, name="tick"))
    return out


def _stickers():
    """A star sticker on the top drawer, a heart on the bottom one (a kid's desk!): white-bordered, flat."""
    out = []
    xc = (PED_X0 + PED_X1) / 2
    yf = FRONT_Y - 0.04 - 0.36       # drawer front face
    rot = Matrix.Rotation(math.pi / 2, 4, "X")
    star = []
    for i in range(10):
        a = math.pi / 2 + i / 10 * math.tau
        r = 0.5 if i % 2 == 0 else 0.22
        star.append((r * math.cos(a), r * math.sin(a)))
    zc = (DRAWERS[0][0] + DRAWERS[0][1]) / 2 - 0.75
    m = Matrix.Translation((xc - 1.75, yf - 0.02, zc)) @ Matrix.Rotation(0.25, 4, "Y") @ rot
    out.append(shape(STICKER_W, [star], 0.04, 0.0, m @ Matrix.Diagonal((1.3, 1.3, 1, 1)), name="sticker_back",
                     bevel_res=0, outline=False))
    out.append(shape(STICKER_Y, [star], 0.04, 0.0, m @ Matrix.Translation((0, 0, 0.02)), name="sticker", bevel_res=0,
                     outline=False))
    heart = []
    for i in range(20):
        t = i / 20 * math.tau
        heart.append((0.026 * 16 * math.sin(t) ** 3,
                      0.026 * (13 * math.cos(t) - 5 * math.cos(2 * t) - 2 * math.cos(3 * t) - math.cos(4 * t))))
    zc = (DRAWERS[1][0] + DRAWERS[1][1]) / 2 - 0.65
    m = Matrix.Translation((xc + 1.8, yf - 0.02, zc)) @ Matrix.Rotation(-0.2, 4, "Y") @ rot
    out.append(shape(STICKER_W, [heart], 0.04, 0.0, m @ Matrix.Diagonal((1.3, 1.3, 1, 1)), name="sticker_back",
                     bevel_res=0, outline=False))
    out.append(shape(STICKER_P, [heart], 0.04, 0.0, m @ Matrix.Translation((0, 0, 0.02)), name="sticker", bevel_res=0,
                     outline=False))
    return out


# ---------------------------------------------------------------- sock
def _sock():
    """A yellow sock with pink stripes lying across the notebook's corner, its foot dangling over the front edge."""
    t = 0.13
    top = TOP_Z1
    x = 2.15
    yo = TOP_Y0 - t - 0.02          # just in front of the slab's front face
    UP, FRONT = (0, 0, 1), (0, -1, 0)
    ctrl = [(x - 1.25, -2.15, top + 0.3 + t), (x - 0.6, -2.85, top + t + 0.12), (x - 0.05, -3.6, top + t + 0.02),
            (x + 0.1, TOP_Y0 + 0.25, top + t + 0.02), (x + 0.12, TOP_Y0 - 0.05, top - 0.02),
            (x + 0.12, yo, top - 0.7), (x + 0.1, yo - 0.03, top - 1.35), (x - 0.25, yo - 0.08, top - 1.8),
            (x - 0.85, yo - 0.08, top - 1.85)]
    hints = [UP, UP, UP, UP, (0, -1, 0.6), FRONT, FRONT, FRONT, FRONT]
    return [sock(ctrl, hints, dict(body=SK_BODY, stripe=SK_STRIPE, accent=SK_ACC, inner=SK_IN), heel=6, stripe=0.3,
                 step=0.2, name="sock")]


# ---------------------------------------------------------------- build
def build():
    p = _top()
    p += _pedestal()
    p += _frame()
    p += _lamp(-7.6, 2.6)
    p += _globe(6.6, 2.4)
    p += _pencil_cup(3.4, 3.1)
    p += _notebook(-1.6, -1.2, -0.12)
    p += _ruler(-5.6, -3.0, 0.22)
    p += _stickers()
    p += _sock()
    body, outline = K.finish(p, NAME, outline_width=OUTLINE_W)
    no_bounce(outline)
    return [body, outline] + K.markers(NAME)
