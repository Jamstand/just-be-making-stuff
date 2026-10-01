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


class SockCtx:
    """What feature builders (sockfeat_*.py) may rely on. body_pieces()/face_pieces() fill it in.

    Axes: Blender Z-up; the leg axis is the Z axis at x = y = 0; the FACE (eyes) is on the -Y side;
    the foot points along +X for "R" (d = +1), -X for "L" (d = -1); singles ("S", d = 0) have no
    foot direction. z = 0 is the floor / bottom of the foot.
    """

    def __init__(self, tid, spec, side):
        self.tid, self.spec, self.side = tid, spec, side
        self.d = -1.0 if side == "L" else (1.0 if side == "R" else 0.0)
        self.h = leg_height(spec)          # z of the top of the leg (the opening)
        self.RL, self.RF, self.FOOT = RL, RF, FOOT  # leg radius, foot radius, axis -> toe tip (x)
        self.cuff_z = self.h - CUFF        # where the cuff band starts
        self.ey = 0.0                      # eye centre height (set by face_pieces)
        self.eyes = []                     # [(x, y, z)] eye-ball centres (set by face_pieces)
        self.eye_r = 0.0
        self.mouth_z = 0.0
        self.body = hexcol(f"{tid}_body", spec["body"])
        self.accent = hexcol(f"{tid}_accent", spec["accent"])

    def extra(self, key="extra"):
        """Palette index of an extra spec colour (e.g. spec['extra'])."""
        return hexcol(f"{self.tid}_{key}", self.spec[key])

    def radius_at(self, z):
        """Leg radius at height z (above the foot)."""
        return self.RL

    def around(self, angle, z, lift=0.0):
        """Point on the leg surface at height z; angle 0 = the face (-Y), +pi/2 = +X, pi = back."""
        r = self.radius_at(z) + lift
        return (math.sin(angle) * r, -math.cos(angle) * r, z)

    def front(self, x, z, lift=0.0):
        """Point on the face side (-Y) of the leg at sideways offset x and height z."""
        r = self.radius_at(z)
        return (x, -math.sqrt(max(r * r - x * x, 0.01)) - lift, z)


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


# which sockfeat_* module owns each type's signature features
FEATURE_MODULE = {
    "Tubolino": "sockfeat_a", "AnkleBiter": "sockfeat_a", "CrustyCrew": "sockfeat_a", "GymGary": "sockfeat_a",
    "Argylo": "sockfeat_a", "ToeToe": "sockfeat_a", "Sockrates": "sockfeat_a",
    "KneeHigh": "sockfeat_b", "Slipperino": "sockfeat_b", "Compressio": "sockfeat_b", "Sockhopper": "sockfeat_b",
    "DJDryer": "sockfeat_b", "Socktopus": "sockfeat_b", "Sockington": "sockfeat_b",
    "Stinkolino": "sockfeat_c", "SockNess": "sockfeat_c", "Shockini": "sockfeat_c", "Lintlord": "sockfeat_c",
    "Zillionaire": "sockfeat_c", "LostSock": "sockfeat_c", "PuppetSupreme": "sockfeat_c",
}


def feature_module(tid: str):
    """The owning sockfeat_* module (imported lazily: those modules import this one)."""
    import importlib
    return importlib.import_module(FEATURE_MODULE[tid])


def spec_for(tid: str) -> dict:
    """SPECS[tid] with the owning feature module's SPEC_OVERRIDES[tid] merged on top, so a feature
    module can retune its own types' colours/flags without editing this file."""
    spec = dict(SPECS[tid])
    spec.update(getattr(feature_module(tid), "SPEC_OVERRIDES", {}).get(tid, {}))
    return spec


def build_sock(tid: str, side: str):
    spec = spec_for(tid)
    c = SockCtx(tid, spec, side)
    pieces, h, d = body_pieces(tid, spec, side)
    face, ey = face_pieces(spec, h, d)
    c.ey = ey
    c.mouth_z = ey - 0.62
    c.eye_r = 0.36
    c.eyes = [(ex, -math.sqrt(max(RL * RL - ex * ex, 0.01)) + 0.1, ey) for ex in (-0.37, 0.37)]
    pieces += face
    pieces += feature_module(tid).FEATURES[tid](c)
    name = tid if side == "S" else f"{tid}_{side}"
    body, outline = K.finish(pieces, name, outline_width=0.055)
    return [body, outline] + K.markers(name, pin=(0, 0, h + 0.1))
