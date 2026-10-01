"""
socks.py - builds every Steal a Sock character as a Blender mesh in the concept-art style.

A sock = a smooth bezier tube (leg bending into the foot) + rounded toe + rib cuff + googly eyes
+ a smile, coloured by region (cuff / heel / toe / stripes), plus each type's signature
accessories. Left and right halves are mirror images (foot points -X for L, +X for R); singles
(Socktopus, The Lost Sock) have no foot direction. Front (eyes) faces -Y.
"""
import math
from mathutils import Vector
import sockkit as K
from sockkit import M, color, hexcol

H = 4.2       # top of the leg
RL = 0.85     # leg radius
RF = 0.80     # foot radius
FOOT = 2.6    # leg axis -> toe tip
CUFF = 0.55   # cuff height

C_GOLD = hexcol("gold", "#F2C14E")
C_GOLD2 = hexcol("gold_dark", "#C9922E")
C_PINKMOUTH = hexcol("mouth", "#B5303F")
C_TONGUE = hexcol("tongue", "#F27A93")
C_GREEN = hexcol("leaf", "#5BA84A")
C_GREY = hexcol("beard", "#B9BCC4")
C_RED = hexcol("red", "#D94F4F")
C_SILVER = hexcol("silver", "#CBD2DC")
C_SILVER2 = hexcol("silver_dark", "#8E98A8")
C_MAGENTA = hexcol("magenta", "#E040B8")
C_DARK = hexcol("dark", "#2A2438")
C_CASH = hexcol("cash", "#6CC46A")
C_BLUEBOLT = hexcol("bolt", "#7FD3FF")
C_WICKER = hexcol("wicker", "#C8A064")
C_WICKER2 = hexcol("wicker_dark", "#9C7440")
C_STINK = hexcol("stink", "#9BD45A")
C_INNER = hexcol("sock_inner", "#3A2F4E")

# id -> body colour, accent (cuff/heel/toe), extra colour, stripes [(z0, z1, colour)], extras
SPECS = {
    "Tubolino":    dict(body="#F5F5F2", accent="#5C7FD1", stripes=[(3.25, 3.42, "accent"), (2.95, 3.1, "accent")], mood="sad"),
    "AnkleBiter":  dict(body="#F4A6C6", accent="#F9D0E0", short=True, mood="fangs"),
    "CrustyCrew":  dict(body="#D8C08A", accent="#A88A50", mood="flat"),
    "GymGary":     dict(body="#BFE7C4", accent="#E25555", mood="tired"),
    "Argylo":      dict(body="#8A5A36", accent="#5E3A20", extra="#F2C14E", mood="smug"),
    "ToeToe":      dict(body="#FF9FC8", accent="#FFD6E8", mood="happy"),
    "Sockrates":   dict(body="#EFE3C2", accent="#D8C79A", mood="calm"),
    "KneeHigh":    dict(body="#6E8FF0", accent="#FFFFFF", tall=True, stripes=[(5.4, 5.6, "accent"), (5.0, 5.2, "accent"), (4.6, 4.8, "accent")], mood="happy"),
    "Slipperino":  dict(body="#7CCBF2", accent="#FFFFFF", mood="happy"),
    "Compressio":  dict(body="#4A4A58", accent="#E25555", stripes=[(2.0, 2.2, "accent"), (2.6, 2.8, "accent"), (3.2, 3.4, "accent")], mood="stress"),
    "Sockhopper":  dict(body="#58B95E", accent="#3E8E44", mood="happy"),
    "DJDryer":     dict(body="#CFC6F2", accent="#9A8BE0", mood="cool"),
    "Socktopus":   dict(body="#B45CD6", accent="#D99BF0", single=True, mood="happy"),
    "Sockington":  dict(body="#C8CCD6", accent="#8E98A8", mood="brave"),
    "Stinkolino":  dict(body="#8AA44C", accent="#5E7330", mood="gross"),
    "SockNess":    dict(body="#3F9C78", accent="#7CD0A8", mood="happy"),
    "Shockini":    dict(body="#FFE45C", accent="#7FD3FF", mood="shock"),
    "Lintlord":    dict(body="#A9AAB4", accent="#8A8B96", mood="smug"),
    "Zillionaire": dict(body="#F2C14E", accent="#C9922E", mood="smug"),
    "LostSock":    dict(body="#2C2F4A", accent="#4A5078", single=True, mood="sad"),
    "PuppetSupreme": dict(body="#F2643C", accent="#FFFFFF", mood="puppet"),
}


def leg_height(spec) -> float:
    if spec.get("tall"):
        return H + 1.6
    if spec.get("short"):
        return H - 1.3
    return H


def body_pieces(tid, spec, side):
    """The sock body: leg tube + toe + cuff rim + opening, region-coloured."""
    d = -1.0 if side == "L" else 1.0
    single = side == "S"
    h = leg_height(spec)
    body = hexcol(f"{tid}_body", spec["body"])
    accent = hexcol(f"{tid}_accent", spec["accent"])
    stripes = [(z0 * h / H if not spec.get("tall") else z0, z1 * h / H if not spec.get("tall") else z1,
                accent if c == "accent" else color(c)) for z0, z1, c in spec.get("stripes", [])]

    def region(c: Vector) -> int:
        if c.z > h - CUFF:
            return accent
        for z0, z1, col in stripes:
            if z0 <= c.z <= z1:
                return col
        return body

    pieces = []
    if single:
        pts = [(0, 0, h), (0, 0, h * 0.5), (0, 0, RF)]
        tube = K.tube(body, pts, radius=RL, radii=[1, 1.04, 1.08], res=6, bevel_res=2, face_pal=region, name="leg")
        pieces.append(tube)
        pieces.append(K.sphere(body, RL * 1.08, M((0, 0, RF), scale=(1, 1, 0.85)), seg=16, rings=8, name="bottom"))
    else:
        pts = [(0, 0, h), (0, 0, 1.75), (d * 0.45, 0, RF), (d * (FOOT - RF), 0, RF)]
        tube = K.tube(body, pts, radius=RL, radii=[1, 1, 0.98, 0.95], res=6, bevel_res=2, face_pal=region, name="leg")
        pieces.append(tube)
        # clean rounded toe cap and heel patch in the accent colour (the concept's two-tone sock)
        pieces.append(K.sphere(accent, RF * 1.02, M((d * (FOOT - RF + 0.05), 0, RF), scale=(1.0, 1.0, 0.94)), seg=16, rings=8, name="toe"))
        pieces.append(K.sphere(accent, 0.62, M((-d * 0.42, 0, RF + 0.18), scale=(0.75, 1.06, 0.85)), seg=14, rings=8, name="heel"))
    # cuff: the tube's flat top cap reads as the sock opening (dark), a rib rim around it
    K.recolor_by(tube, lambda c, cur: C_INNER if c.z > h - 0.02 else cur)
    pieces.append(K.torus(accent, RL * 0.98, 0.16, M((0, 0, h)), seg=20, mseg=8, name="rim"))
    return pieces, h, d


def face_pieces(spec, h, d):
    """Googly eyes, pupils, mouth and brows on the front (-Y) of the leg."""
    mood = spec.get("mood", "happy")
    ey = h * 0.70 if not spec.get("tall") else h - 1.55
    out = []
    eye_r = 0.36
    for ex in (-0.37, 0.37):
        y = -math.sqrt(max(RL * RL - ex * ex, 0.01)) + 0.1
        out.append(K.sphere(K.WHITE, eye_r, M((ex, y, ey)), seg=14, rings=8, name="eye"))
        look = 0.07 * (d if d else 1)
        out.append(K.sphere(K.BLACK, 0.17, M((ex + look, y - 0.27, ey - 0.03)), seg=10, rings=6, outline=False, name="pupil"))
        out.append(K.sphere(K.WHITE, 0.05, M((ex + look + 0.05, y - 0.42, ey + 0.05)), seg=6, rings=4, outline=False, name="glint"))

    def on_surface(x, z, lift=0.02):
        return (x, -math.sqrt(max(RL * RL - x * x, 0.01)) - lift, z)

    my = ey - 0.62
    if mood in ("happy", "smug", "calm", "brave", "cool"):
        sag = 0.14 if mood == "happy" else 0.08
        pts = [on_surface(-0.26, my + sag * 0.6), on_surface(0, my - sag * 0.4), on_surface(0.26, my + sag * 0.6)]
        if mood == "smug":
            pts = [on_surface(-0.24, my), on_surface(0.02, my - 0.06), on_surface(0.27, my + 0.12)]
        out.append(K.tube(K.BLACK, pts, radius=0.05, res=6, bevel_res=1, outline=False, name="mouth"))
    elif mood in ("sad", "tired"):
        pts = [on_surface(-0.22, my - 0.08), on_surface(0, my + 0.04), on_surface(0.22, my - 0.08)]
        out.append(K.tube(K.BLACK, pts, radius=0.05, res=6, bevel_res=1, outline=False, name="mouth"))
    elif mood in ("stress", "shock"):
        out.append(K.sphere(C_PINKMOUTH, 0.17, M(on_surface(0, my, -0.02), scale=(1, 0.5, 1.2)), seg=10, rings=6, name="mouth"))
    elif mood == "fangs":
        pts = [on_surface(-0.28, my + 0.08), on_surface(0, my - 0.07), on_surface(0.28, my + 0.08)]
        out.append(K.tube(K.BLACK, pts, radius=0.05, res=6, bevel_res=1, outline=False, name="mouth"))
        for fx in (-0.13, 0.13):
            out.append(K.cylinder(K.WHITE, 0.09, 0.26, M(on_surface(fx, my - 0.15, 0.0), rot=(0, 0, 0)), seg=8, radius2=0.01, name="fang"))
    elif mood == "flat":
        out.append(K.tube(K.BLACK, [on_surface(-0.2, my), on_surface(0.2, my)], radius=0.05, res=2, bevel_res=1, outline=False, name="mouth"))
    elif mood == "gross":
        pts = [on_surface(-0.26, my - 0.05), on_surface(-0.08, my + 0.05), on_surface(0.1, my - 0.05), on_surface(0.27, my + 0.04)]
        out.append(K.tube(K.BLACK, pts, radius=0.05, res=6, bevel_res=1, outline=False, name="mouth"))
        out.append(K.sphere(C_TONGUE, 0.11, M(on_surface(0.12, my - 0.12, 0.0), scale=(1, 0.6, 1.3)), seg=8, rings=5, outline=False, name="tongue"))
    # brows
    if mood in ("sad", "stress", "tired"):
        tilt = 0.45 if mood == "sad" else -0.45
        for bx in (-0.37, 0.37):
            s = 1 if bx > 0 else -1
            out.append(K.rounded_box(K.BLACK, (0.42, 0.1, 0.09), M(on_surface(bx, ey + 0.48, 0.05), rot=(0, -tilt * s, 0)), bevel=0.04, segments=1, outline=False, name="brow"))
    return out, ey


# ---------------------------------------------------------------- signature features
def feat_argylo(tid, spec, h, d, ey):
    gold = hexcol(f"{tid}_extra", spec["extra"])
    out = []
    for i, (x, z) in enumerate([(-0.42, 2.55), (0.42, 2.55), (0.0, 1.95), (-0.42, 1.35), (0.42, 1.35), (0.0, 3.15)]):
        y = -math.sqrt(max(RL * RL - x * x, 0.01)) + 0.02
        ang = math.atan2(x, RL)
        out.append(K.rounded_box(gold if i % 2 == 0 else color(f"{tid}_accent"), (0.42, 0.08, 0.42),
                                 M((x, y, z), rot=(0, math.pi / 4, -ang)), bevel=0.03, segments=1, outline=False, name="diamond"))
    # monocle on the viewer-right eye + chain
    ex, ey_ = 0.37, ey
    y = -math.sqrt(RL * RL - ex * ex) + 0.1 - 0.32
    out.append(K.torus(C_GOLD, 0.40, 0.065, M((ex, y, ey_), rot=(math.pi / 2, 0, 0)), seg=20, mseg=6, name="monocle"))
    out.append(K.tube(C_GOLD, [(ex + 0.35, y + 0.05, ey_ - 0.2), (0.9, -0.3, ey_ - 0.8), (0.86, -0.15, ey_ - 1.4)], radius=0.035, res=6, bevel_res=1, outline=False, name="chain"))
    return out


def feat_tubolino(tid, spec, h, d, ey):
    return []


def feat_anklebiter(tid, spec, h, d, ey):
    return []


def feat_crusty(tid, spec, h, d, ey):
    crust = hexcol("crust", "#9C7B45")
    out = []
    for i in range(9):
        a = i * 2.3
        z = 1.0 + (i % 4) * 0.55
        out.append(K.sphere(crust, 0.13 + (i % 3) * 0.04, M((math.cos(a) * RL * 0.98, math.sin(a) * RL * 0.98, z)), seg=8, rings=5, outline=False, name="crust"))
    return out


def feat_gymgary(tid, spec, h, d, ey):
    band = color(f"{tid}_accent")
    out = [K.torus(band, RL * 1.02, 0.24, M((0, 0, h - 0.55)), seg=20, mseg=8, name="sweatband"),
           K.torus(K.WHITE, RL * 1.06, 0.07, M((0, 0, h - 0.55)), seg=20, mseg=6, outline=False, name="bandstripe")]
    drop = hexcol("sweat", "#8CCBFF")
    for x, z in ((-0.62, ey + 0.35), (0.7, ey + 0.15)):
        y = -math.sqrt(max(RL * RL - x * x, 0.01))
        out.append(K.sphere(drop, 0.11, M((x, y - 0.02, z), scale=(1, 1, 1.5)), seg=8, rings=5, name="drop"))
    return out


def feat_toetoe(tid, spec, h, d, ey):
    out = []
    acc = color(f"{tid}_accent")
    for i in range(5):
        y = -0.56 + i * 0.28
        r = 0.2 if i in (0, 4) else 0.24
        out.append(K.sphere(acc, r, M((d * (FOOT - 0.05), y, RF + 0.05 + (0.06 if i == 2 else 0))), seg=10, rings=6, name="toe"))
    return out


def feat_sockrates(tid, spec, h, d, ey):
    out = []
    my = ey - 0.65
    beard = K.sphere(C_GREY, 0.62, M((0, -RL * 0.7, my - 0.25), scale=(1.15, 0.55, 1.1)), seg=14, rings=8, name="beard")
    out.append(beard)
    out.append(K.tube(C_GREY, [(-0.4, -RL - 0.12, my + 0.12), (0, -RL - 0.2, my + 0.02), (0.4, -RL - 0.12, my + 0.12)], radius=0.09, res=6, bevel_res=1, name="moustache"))
    # toga sash
    out.append(K.tube(K.WHITE, [(-RL - 0.05, -0.2, h - 1.1), (-0.3, -RL - 0.05, 1.6), (RL * 0.6, -0.5, 0.9), (RL + 0.05, 0.2, 0.7)], radius=0.22, res=8, bevel_res=2, name="toga"))
    # laurel wreath
    for i in range(10):
        a = i / 10 * math.tau
        if abs(math.sin(a) + 1) < 0.25:
            continue
        out.append(K.sphere(C_GREEN, 0.18, M((math.cos(a) * (RL + 0.05), math.sin(a) * (RL + 0.05), h - 0.15), rot=(0, 0, a), scale=(1.6, 0.6, 0.8)), seg=8, rings=5, name="leaf"))
    return out


def feat_slipperino(tid, spec, h, d, ey):
    out = []
    for i in range(5):
        x = d * (0.2 + i * 0.42)
        for y in (-0.3, 0.3):
            out.append(K.sphere(K.WHITE, 0.12, M((x, y, RF - RF * 0.93), scale=(1, 1, 0.5)), seg=8, rings=4, outline=False, name="grip"))
    return out


def feat_sockhopper(tid, spec, h, d, ey):
    red = C_RED
    out = [K.cylinder(red, 0.12, h + 2.4, M((0, 0.2, (h + 2.4) / 2 - 1.6)), seg=10, name="pole"),
           K.rounded_box(red, (1.6, 0.6, 0.18), M((0, 0.2, -0.9)), bevel=0.06, segments=2, name="pegs"),
           K.cylinder(C_DARK, 0.2, 0.7, M((0, 0.2, -1.95)), seg=10, name="spring"),
           K.cylinder(C_DARK, 0.11, 2.2, M((0, -0.2, h + 0.85), rot=(0, math.pi / 2, 0)), seg=10, name="handle")]
    return out


def feat_djdryer(tid, spec, h, d, ey):
    out = [K.tube(C_DARK, [(-RL - 0.1, 0, ey + 0.2), (0, 0, h + 0.55), (RL + 0.1, 0, ey + 0.2)], radius=0.11, res=8, bevel_res=1, name="band")]
    for x in (-RL - 0.08, RL + 0.08):
        out.append(K.cylinder(C_MAGENTA, 0.38, 0.34, M((x, 0, ey + 0.05), rot=(0, math.pi / 2, 0)), seg=16, name="cup"))
    out.append(K.rounded_box(C_DARK, (1.25, 0.18, 0.34), M((0, -RL - 0.2, ey + 0.02)), bevel=0.08, segments=2, name="shades"))
    return out


def feat_socktopus(tid, spec, h, d, ey):
    body = color(f"{tid}_body")
    acc = color(f"{tid}_accent")
    out = []
    for i in range(8):
        a = i / 8 * math.tau + 0.2
        r0, r1, r2 = 0.6, 1.4, 2.0
        pts = [(math.cos(a) * r0, math.sin(a) * r0, 0.7), (math.cos(a) * r1, math.sin(a) * r1, 0.35),
               (math.cos(a + 0.35) * r2, math.sin(a + 0.35) * r2, 0.3)]
        out.append(K.tube(body, pts, radius=0.32, radii=[1, 0.85, 0.6], res=6, bevel_res=2, name="tentacle"))
        out.append(K.sphere(acc, 0.2, M((math.cos(a + 0.35) * r2, math.sin(a + 0.35) * r2, 0.3)), seg=8, rings=5, name="tip"))
    return out


def feat_sockington(tid, spec, h, d, ey):
    foil, foil2 = C_SILVER, C_SILVER2
    out = [K.cylinder(foil, RL * 1.08, 0.9, M((0, 0, h + 0.2)), seg=18, name="helmet"),
           K.sphere(foil, RL * 1.07, M((0, 0, h + 0.62), scale=(1, 1, 0.55)), seg=18, rings=8, name="dome"),
           K.rounded_box(foil2, (0.16, 0.2, 0.9), M((0, -RL - 0.08, h + 0.25)), bevel=0.05, segments=1, name="noseguard"),
           K.sphere(C_RED, 0.3, M((0, 0.1, h + 1.25), scale=(0.6, 1.6, 1.3)), seg=10, rings=6, name="plume"),
           K.rounded_box(foil, (1.5, 0.25, 1.2), M((0, -RL + 0.02, 1.6)), bevel=0.12, segments=2, name="breastplate")]
    return out


def feat_stinkolino(tid, spec, h, d, ey):
    out = []
    for i, x in enumerate((-0.5, 0.15, 0.7)):
        z0 = h + 0.25
        pts = [(x, 0, z0), (x + 0.25, -0.1, z0 + 0.5), (x - 0.15, -0.1, z0 + 1.0), (x + 0.2, 0, z0 + 1.5)]
        out.append(K.tube(C_STINK, pts, radius=0.09, res=6, bevel_res=1, name="stink"))
    for i in range(4):
        a = i * 1.7
        out.append(K.sphere(C_DARK, 0.1, M((math.cos(a) * 1.4, math.sin(a) * 1.4, h - 0.6 + i * 0.4)), seg=6, rings=4, outline=False, name="fly"))
    return out


def feat_sockness(tid, spec, h, d, ey):
    body = color(f"{tid}_body")
    acc = color(f"{tid}_accent")
    out = [K.tube(body, [(0, 0, h - 0.2), (0.3, 0, h + 1.2), (0.1, -0.2, h + 2.4), (0.6, -0.6, h + 2.9)], radius=0.45, radii=[1, 0.85, 0.75, 0.72], res=8, bevel_res=2, name="neck"),
           K.sphere(body, 0.7, M((0.75, -0.75, h + 3.05), scale=(1.15, 1.25, 0.85)), seg=14, rings=8, name="head")]
    for x in (0.45, 1.05):
        out.append(K.sphere(K.WHITE, 0.2, M((x, -1.35, h + 3.25)), seg=10, rings=6, name="eye2"))
        out.append(K.sphere(K.BLACK, 0.1, M((x, -1.5, h + 3.25)), seg=8, rings=5, outline=False, name="pupil2"))
    for i in range(4):
        out.append(K.cylinder(acc, 0.12, 0.35, M((0.2, 0.38, h + 0.3 + i * 0.6), rot=(0.3, 0, 0)), seg=6, radius2=0.01, name="spine"))
    # laundry basket around the bottom
    # laundry basket around the bottom - big enough to hide the foot
    bx = d * 0.85
    out.append(K.cylinder(C_WICKER, 2.0, 1.9, M((bx, 0, 0.8)), seg=24, name="basket"))
    for i in range(14):
        a = i / 14 * math.tau
        out.append(K.rounded_box(C_WICKER2, (0.2, 0.12, 1.7), M((bx + math.cos(a) * 2.03, math.sin(a) * 2.03, 0.85), rot=(0, 0, a)), bevel=0.04, segments=1, outline=False, name="slat"))
    out.append(K.torus(C_WICKER2, 2.03, 0.15, M((bx, 0, 1.75)), seg=24, mseg=6, name="basketrim"))
    return out


def feat_shockini(tid, spec, h, d, ey):
    out = []
    for i in range(7):
        a = i / 7 * math.tau
        out.append(K.cylinder(C_BLUEBOLT, 0.12, 0.8, M((math.cos(a) * 0.55, math.sin(a) * 0.55, h + 0.35), rot=(math.sin(a) * 0.5, -math.cos(a) * 0.5, 0)), seg=6, radius2=0.02, name="fuzz"))
    for x, z, s in ((-RL - 0.05, 2.2, 1), (RL + 0.05, 2.8, -1)):
        pts = [(x, -0.2, z + 0.6), (x - 0.2 * s, -0.25, z + 0.15), (x + 0.15 * s, -0.25, z), (x - 0.1 * s, -0.25, z - 0.55)]
        out.append(K.tube(C_BLUEBOLT, pts, radius=0.09, res=2, bevel_res=1, name="bolt"))
    return out


def feat_lintlord(tid, spec, h, d, ey):
    lint = hexcol("lint", "#C2C3CC")
    out = []
    for i in range(14):
        a = i * 2.39
        z = 0.6 + (i % 7) * 0.5
        out.append(K.sphere(lint, 0.25 + (i % 3) * 0.06, M((math.cos(a) * RL * 0.9, math.sin(a) * RL * 0.9, z)), seg=8, rings=5, outline=False, name="fluff"))
    out.append(K.cylinder(C_GOLD, RL * 1.05, 0.35, M((0, 0, h + 0.15)), seg=18, name="crown"))
    for i in range(6):
        a = i / 6 * math.tau
        out.append(K.cylinder(C_GOLD, 0.2, 0.75, M((math.cos(a) * RL * 0.9, math.sin(a) * RL * 0.9, h + 0.65)), seg=6, radius2=0.03, name="spike"))
        out.append(K.sphere(C_RED, 0.1, M((math.cos(a) * RL * 1.06, math.sin(a) * RL * 1.06, h + 0.2)), seg=6, rings=4, outline=False, name="gem"))
    return out


def feat_zillionaire(tid, spec, h, d, ey):
    out = [K.cylinder(C_DARK, 1.35, 0.14, M((0, 0, h + 0.1)), seg=20, name="brim"),
           K.cylinder(C_DARK, 0.85, 1.5, M((0, 0, h + 0.9)), seg=18, name="hat"),
           K.cylinder(C_GOLD2, 0.87, 0.28, M((0, 0, h + 0.38)), seg=18, outline=False, name="hatband")]
    ex = 0.37
    y = -math.sqrt(RL * RL - ex * ex) + 0.1 - 0.32
    out.append(K.torus(C_GOLD, 0.4, 0.065, M((ex, y, ey), rot=(math.pi / 2, 0, 0)), seg=20, mseg=6, name="monocle"))
    for i, (x, z, r) in enumerate(((-1.3, 2.4, 0.4), (1.25, 3.0, -0.3), (-1.0, 3.6, 0.9))):
        out.append(K.rounded_box(C_CASH, (0.8, 0.06, 0.4), M((x, -0.4, z), rot=(0.3, r, 0.2)), bevel=0.03, segments=1, name="bill"))
    for i in range(3):
        out.append(K.torus(K.WHITE if i else C_GOLD2, RL * 1.01, 0.04, M((0, 0, 1.4 + i * 0.7)), seg=20, mseg=4, outline=False, name="thread"))
    return out


def feat_lost(tid, spec, h, d, ey):
    q = hexcol("ghost", "#B9BCFF")
    return [K.text(q, "?", size=1.4, depth=0.18, mat=M((0, -0.1, h + 1.1), rot=(math.pi / 2, 0, 0)), outline=True, name="question")]


def feat_puppet(tid, spec, h, d, ey):
    out = [K.sphere(C_PINKMOUTH, 0.55, M((0, -RL * 0.72, ey - 0.85), scale=(1.15, 0.5, 0.75)), seg=14, rings=8, name="mouth"),
           K.rounded_box(K.WHITE, (0.9, 0.12, 0.12), M((0, -RL - 0.12, ey - 0.62)), bevel=0.04, segments=1, outline=False, name="teeth"),
           K.sphere(C_TONGUE, 0.3, M((0, -RL - 0.05, ey - 1.05), scale=(1, 0.5, 0.5)), seg=10, rings=6, outline=False, name="tongue")]
    hair = hexcol("hair", "#FF9F2E")
    for i in range(5):
        a = (i - 2) * 0.45
        out.append(K.sphere(hair, 0.32, M((math.sin(a) * 0.5, 0.1, h + 0.25 + math.cos(a) * 0.15), scale=(0.7, 0.7, 1.3)), seg=8, rings=5, name="hair"))
    return out


FEATURES = {
    "Tubolino": feat_tubolino, "AnkleBiter": feat_anklebiter, "CrustyCrew": feat_crusty, "GymGary": feat_gymgary,
    "Argylo": feat_argylo, "ToeToe": feat_toetoe, "Sockrates": feat_sockrates, "KneeHigh": lambda *a: [],
    "Slipperino": feat_slipperino, "Compressio": lambda *a: [], "Sockhopper": feat_sockhopper, "DJDryer": feat_djdryer,
    "Socktopus": feat_socktopus, "Sockington": feat_sockington, "Stinkolino": feat_stinkolino, "SockNess": feat_sockness,
    "Shockini": feat_shockini, "Lintlord": feat_lintlord, "Zillionaire": feat_zillionaire, "LostSock": feat_lost,
    "PuppetSupreme": feat_puppet,
}


def build_sock(tid: str, side: str):
    spec = SPECS[tid]
    pieces, h, d = body_pieces(tid, spec, side)
    face, ey = face_pieces(spec, h, d)
    pieces += face
    pieces += FEATURES[tid](tid, spec, h, d, ey)
    name = tid if side == "S" else f"{tid}_{side}"
    body, outline = K.finish(pieces, name, outline_width=0.055)
    return [body, outline] + K.markers(name, pin=(0, 0, h + 0.1))
