"""
socks.py - builds every Steal a Sock character as a Blender mesh in the concept-art style
(docs/concept/sock_character_sheet.png, bedroom_keyframe.png).

The body is ONE smooth closed surface built ring by ring (no booleans, no subdivision):
inner bottom -> inner wall -> rolled lip (the open mouth of the sock) -> a straight, chunky leg
(about 0.33 of the height wide), a touch wider at the top and pinched a little at the ankle -> a
fan of rings around the instep (spaced by arc length, so the round heel is as finely sampled as
the long soft instep sweep) -> a short foot (heel back -> toe tip ~0.6 of the height, like the
keyframe's clothesline socks) that droops ~17 degrees, stays as thick as the leg and flows from
the instep straight into a fat, round toe whose underside is the lowest point (z = 0); the heel
bulges out behind the ankle. Singles have no foot: below mid-height the leg swells into a sack,
toward the viewer's left like a stubby foot (the sheet's Socktopus: a wide, flat-bottomed sack
lifted ~1 off the floor so its tentacles hang underneath; The Lost Sock: a round bottom on the
floor), while its back and right side stay straight.
Colour regions (cuff band with optional rib strips, stripes, heel patch, toe patch, toe stripe)
are cut into that surface along smooth iso-curves, so patch borders are clean curves instead of
per-face zigzags. The inside of the opening is a darker shade; the inverted-hull outline draws the
ink line along its front edge by itself.

On top go the googly eyes (a squashed white ball facing forward and standing proud of the leg,
inside an even black ink rim whose inner edge shares the ball's vertices, a big pupil and a
glint; no outline hull, so no smeared crescents), the mood mouth / brows / fangs drawn as flat
ink strokes and inked plates that hug the face, and each type's signature features from
sockfeat_a/b/c.py, which only use SockCtx.
Left and right halves are mirror images (foot points -X for L, +X for R); singles (Socktopus,
The Lost Sock) have no foot. Front (eyes) faces -Y. Blender Z-up; z = 0 is the sole / floor.
"""
import colorsys
import math
import bmesh
import bpy
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree
from mathutils.interpolate import poly_3d_calc
import sockkit as K
from sockkit import M, color, hexcol

H = 4.2       # top of the leg (the opening) for a normal sock
RL = 0.7      # leg radius (mid-leg; the leg is 5% wider at the top, 8% narrower at the ankle)
RF = 0.62     # fallback foot "radius" (singles); SockCtx.RF is the real half-thickness of the toe
FOOT = 1.55   # leg axis -> toe tip along x (normal sock; short socks have a shorter foot)
CUFF = 0.34   # cuff band height below the top (short socks: 80%)
SEG = 24      # vertices around every ring of the body
RIBS = SEG // 2   # ribbed cuffs: SEG/2 vertical strips of a mid tone between the ring vertices

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

# id -> colours and look of the shared body.
#   body    base colour                       dark   heel/toe patches
#   accent  second colour (stripes, features)  inner  inside of the opening (default: darker dark)
#   cuff    colour of the top band: "light" (default: a lighter tone with rib grooves, like the
#           keyframe's clothesline socks), "dark" (the character sheet's Argylo / AnkleBiter /
#           Sockhopper / Socktopus), "body" (no band: Tubolino, Sockrates) or "accent"
#   cuff_h  band height (default 0.34, short socks 80%);  ribs  rib strips (default: light cuffs)
#   mouth   False: no mouth line (the sheet's Argylo, Sockhopper, Socktopus); mouth_z is still set
#   stripes [(z0, z1, "accent" | colour name)] rings around the leg, z for a 4.2-tall sock
#           (scaled for short socks; tall socks use their own z)
#   toe_stripe (gap, width, colour) a band that follows the toe patch border (Tubolino)
#   face_drop  eye centre this far below the top (default: the eye rims' tops EYE_GAP under the
#           cuff band, at least 0.8 / short 0.66 below the top);  mood  face drawing (face_pieces)
#   bulb_lift  singles: 0 = round bottom on the floor, 1 = wide flat sack lifted for tentacles
#           (bulb_r: sack radius in RL, default 1.4 / lifted 1.6)
# The six character-sheet socks use colours sampled from docs/concept/sock_character_sheet.png.
SPECS = {
    "Tubolino":    dict(body="#F2F7FC", dark="#C6D7E5", inner="#B6C8D7", accent="#6690DB", cuff="body",
                        stripes=[(3.70, 3.92, "accent"), (3.29, 3.49, "accent")], toe_stripe=(0.17, 0.19, "accent"),
                        face_drop=1.12, mood="sad"),
    "AnkleBiter":  dict(body="#FDAAD2", dark="#F87AAE", inner="#D8588B", accent="#F9D0E0", short=True, mood="fangs",
                        cuff="dark", cuff_h=0.17),
    "CrustyCrew":  dict(body="#D8C08A", dark="#B59B63", accent="#A88A50", mood="flat"),
    "GymGary":     dict(body="#BFE7C4", dark="#8FCB98", accent="#E25555", mood="tired"),
    "Argylo":      dict(body="#A5703E", dark="#623D20", inner="#4A2E18", accent="#5E3A20", extra="#F8C725", mood="smug",
                        cuff="dark", mouth=False),
    "ToeToe":      dict(body="#FF9FC8", dark="#F577AE", accent="#FFD6E8", mood="happy"),
    "Sockrates":   dict(body="#F6EAC4", dark="#D6C896", inner="#C2B283", accent="#D8C79A", mood="calm", cuff="body"),
    "KneeHigh":    dict(body="#6E8FF0", dark="#4A68CF", accent="#FFFFFF", tall=True,
                        stripes=[(5.12, 5.30, "accent"), (4.80, 4.98, "accent")], face_drop=1.15, mood="happy"),
    "Slipperino":  dict(body="#7CCBF2", dark="#4F9FD8", accent="#FFFFFF", mood="happy"),
    "Compressio":  dict(body="#4A4A58", dark="#34343F", accent="#E25555",
                        stripes=[(2.0, 2.2, "accent"), (2.6, 2.8, "accent"), (3.2, 3.4, "accent")], mood="stress"),
    "Sockhopper":  dict(body="#58B558", dark="#3B8541", inner="#2B6E39", accent="#3E8E44", mood="happy",
                        cuff="dark", cuff_h=0.2, mouth=False),
    "DJDryer":     dict(body="#CFC6F2", dark="#A99BE3", accent="#9A8BE0", mood="cool"),
    "Socktopus":   dict(body="#AF73D8", dark="#7E46AD", inner="#65319A", accent="#7E46AD", single=True, mood="happy",
                        cuff="dark", cuff_h=0.22, mouth=False, bulb_lift=1.0),
    "Sockington":  dict(body="#C8CCD6", dark="#9EA5B4", accent="#8E98A8", mood="brave"),
    "Stinkolino":  dict(body="#8AA44C", dark="#687F35", accent="#5E7330", mood="gross"),
    "SockNess":    dict(body="#3F9C78", dark="#2B775A", accent="#7CD0A8", mood="happy"),
    "Shockini":    dict(body="#FFE45C", dark="#F2B93A", accent="#7FD3FF", mood="shock"),
    "Lintlord":    dict(body="#A9AAB4", dark="#878894", accent="#8A8B96", mood="smug"),
    "Zillionaire": dict(body="#F2C14E", dark="#D19A2C", accent="#C9922E", mood="smug"),
    "LostSock":    dict(body="#2C2F4A", dark="#1E2034", inner="#121320", accent="#4A5078", single=True, mood="sad"),
    "PuppetSupreme": dict(body="#F2643C", dark="#C9472A", accent="#FFFFFF", mood="puppet"),
}


def leg_height(spec) -> float:
    if spec.get("tall"):
        return H + 1.6
    if spec.get("short"):
        return H - 1.55
    return H


# ------------------------------------------------------------------ colour helpers
def _rgb(hexstr):
    h = hexstr.lstrip("#")
    return tuple(int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))


def _hex(rgb):
    return "#" + "".join(f"{max(0, min(255, round(c * 255))):02X}" for c in rgb)


def _shade(hexstr, v_mul=0.76, s_add=0.12):
    """A darker, slightly more saturated tone of a colour (heel/toe patches, the opening)."""
    hh, s, v = colorsys.rgb_to_hsv(*_rgb(hexstr))
    return _hex(colorsys.hsv_to_rgb(hh, min(1.0, s * 1.08 + s_add), v * v_mul))


def _tint(hexstr, amount=0.4):
    """A lighter tone (mixed toward white)."""
    return _hex(tuple(c + (1 - c) * amount for c in _rgb(hexstr)))


def _smooth(t):
    t = max(0.0, min(1.0, t))
    return t * t * (3 - 2 * t)


def _lerp(a, b, t):
    return a + (b - a) * t


# ------------------------------------------------------------------ the body shape (R frame: foot +X)
def _catmull(points, samples=12):
    """Centripetal Catmull-Rom through 2D points -> dense polyline (first/last points kept)."""
    pts = [Vector(points[0]) * 2 - Vector(points[1])] + [Vector(p) for p in points] + [Vector(points[-1]) * 2 - Vector(points[-2])]
    out = [Vector(points[0])]
    for i in range(1, len(pts) - 2):
        p0, p1, p2, p3 = pts[i - 1], pts[i], pts[i + 1], pts[i + 2]
        t0 = 0.0
        t1 = t0 + max((p1 - p0).length ** 0.5, 1e-4)
        t2 = t1 + max((p2 - p1).length ** 0.5, 1e-4)
        t3 = t2 + max((p3 - p2).length ** 0.5, 1e-4)
        for k in range(1, samples + 1):
            t = t1 + (t2 - t1) * k / samples
            a1 = p0 * ((t1 - t) / (t1 - t0)) + p1 * ((t - t0) / (t1 - t0))
            a2 = p1 * ((t2 - t) / (t2 - t1)) + p2 * ((t - t1) / (t2 - t1))
            a3 = p2 * ((t3 - t) / (t3 - t2)) + p3 * ((t - t2) / (t3 - t2))
            b1 = a1 * ((t2 - t) / (t2 - t0)) + a2 * ((t - t0) / (t2 - t0))
            b2 = a2 * ((t3 - t) / (t3 - t1)) + a3 * ((t - t1) / (t3 - t1))
            out.append(b1 * ((t2 - t) / (t2 - t1)) + b2 * ((t - t1) / (t2 - t1)))
    return out


def _ray_polyline(o, dvec, poly):
    """Nearest hit (2D) of the ray o + s*dvec with a polyline, or None."""
    best = None
    for a, b in zip(poly, poly[1:]):
        e = b - a
        den = dvec.x * (-e.y) - dvec.y * (-e.x)
        if abs(den) < 1e-12:
            continue
        w = a - o
        s = (w.x * (-e.y) - w.y * (-e.x)) / den
        u = (dvec.x * w.y - dvec.y * w.x) / den
        if s > 1e-6 and -1e-6 <= u <= 1 + 1e-6 and (best is None or s < best):
            best = s
    return None if best is None else o + dvec * best


class _Shape:
    """All body dimensions for one sock, in the R frame (foot +X). 2D profile points are (x, z).

    Side profile (like the keyframe's clothesline socks): the leg runs straight down; its front
    line flows through a long soft instep curve (radius ri, centre Q) into the top of the foot; its
    back line pinches in a little at the ankle and then bulges out into the round heel (hb behind
    the ankle line) and turns into the sole. The foot points down-forward along an axis tilted
    `alpha` below horizontal; it stays as thick as the leg and ends in a fat, round toe cap whose
    underside is the lowest point (z = 0). A short foot has no straight top: the toe cap starts
    where the instep curve ends (cap_len = min(cap, what is left)). Rings between the leg and the
    foot fan out from Q (spaced by the arc length they sweep, see _fan), so the heel is swept by
    long diagonal rings while the instep stays a smooth curve; foot rings are perpendicular to the
    foot axis."""

    def __init__(self, spec, single):
        self.single = single
        self.h = h = leg_height(spec)
        short = bool(spec.get("short"))
        self.fs = fs = 0.86 if short else 1.0         # foot scale
        self.r_top = RL * 1.05                        # outer radius at the opening
        self.r_ank = RL * 0.92                        # radius at the ankle (pinched above the heel)
        self.z_ank = 1.9 * fs                         # leg taper ends here
        self.t = 0.12                                 # lip / wall thickness
        self.depth = 0.5                              # how deep the dark inside goes
        self.cuff_h = spec.get("cuff_h", CUFF * (0.8 if short else 1.0))
        self.cuff_z = h - self.cuff_h
        # foot: short (heel back -> toe tip ~0.6 of the height, like the keyframe's clothesline
        # socks), drooping a little, as thick as the leg, with a long soft instep sweep that flows
        # straight into the fat round toe, and a rounded heel bulging out behind the ankle
        self.alpha = math.radians(17.0 if not short else 12.0)   # foot axis below horizontal
        self.A0 = RL * 0.98                           # foot half-thickness (perpendicular to the axis)
        self.A1 = RL * 0.98                           # half-thickness over the toe (fat, blunt toe)
        self.ri = (0.5 if not short else 0.3) * fs    # instep curve radius (a long soft sweep)
        self.foot_tip = FOOT if not short else 1.12   # x of the toe tip
        self.cap = 0.56 * fs                          # toe cap length along the axis (at most)
        self.cap_p = 2.15                             # toe cap superellipse exponent (higher = blunter)
        self.wf0 = RL * 0.97                          # foot half-width after the instep
        self.wt = RL * 1.03                           # foot half-width at the toe cap
        self.n_foot = 2.3                             # superellipse exponent of foot sections
        self.hb = 0.33 * fs                           # heel bulge behind the ankle line
        self.Rh = 0.56 * fs                           # radius of the round heel
        self.hdip = 0.05 * fs                         # heel underside this far below the sole line
        self.z_a = 1.2                                # axis height at x = 0 (solved below)
        self.tip_y = 0.0
        if single:
            # bulb_lift 0: the round bottom sits on the floor (The Lost Sock); 1: a wide, flat-bottomed
            # sack that ends ~3/4 of the way down so legs/tentacles can hang under it (Socktopus)
            lift = float(spec.get("bulb_lift", 0.0))
            self.lift = lift
            self.z_swell = _lerp(2.5, 2.85, lift)    # the leg starts to swell here (no neck)
            self.z_bulb = _lerp(1.4, 1.75, lift)     # widest point of the round bottom
            self.r_bulb = RL * spec.get("bulb_r", _lerp(1.4, 1.6, lift))
            self.z_bot = _lerp(0.3, 1.0, lift)       # bottom of the body
            # the rim of the bottom (z, radius) where the sides turn under: a profile point below
            self.bottom_ring = (self.z_bot + 0.1, self.r_bulb * (0.9 if lift > 0 else 0.72))
            g = self.r_bulb - self.r_leg(self.z_swell)
            # shift = growth: the back and right lines stay straight; a lifted sack swells mostly
            # toward -X (the viewer's left in the sheet's 3/4 view), a sitting bottom toward the front
            self.lean = Vector((-g * _lerp(0.95, 1.25, lift), -g * _lerp(1.15, 0.7, lift)))
            self.tip = Vector((self.lean.x, self.z_bot))
            self.tip_y = self.lean.y
            # dark patches like the sheet's Socktopus: a big one low on the front-left, one on the right
            rb, lx, ly = self.r_bulb, self.lean.x, self.lean.y
            zs = max(0.75, (self.z_bulb - self.z_bot) / 1.1)
            self.toe_patch = (Vector((lx - rb * 0.5, ly - rb * 0.95, _lerp(self.z_bot, self.z_bulb, 0.5))),
                              Vector((1.0, 0.95, 0.95 * zs)), 0.0)
            ha = math.radians(68.0)                  # on the right side, turned toward the front
            self.heel_patch = (Vector((lx + (rb + 0.15) * math.sin(ha), ly - (rb + 0.15) * math.cos(ha),
                                       self.z_bulb - 0.05)), Vector((0.6, 0.6, 0.7 * zs)), 0.0)
            return
        for _i in range(5):                           # lift the foot until the toe touches z = 0
            self._solve()
            low = min(min((O - u * A).y, (O + u * A).y) for O, u, A, _W, _n, tg in self._foot_rings())
            self.z_a -= low
        self._solve()
        # colour patches (centre, radii, rot about y) in the R frame; y radius 99 = straight through
        tip = self.tip
        self.toe_patch = (Vector((tip.x, 0.0, tip.y)) + Vector((self.ax.x, 0.0, self.ax.y)) * 0.1,
                          Vector((0.86 * fs, 99.0, 0.98 * fs)), -self.alpha)
        # heel patch: a round cap on the heel circle, from high on the back of the ankle round to
        # the underside of the heel (seen from the side it is a big round patch, like the sheet)
        am = math.radians(22.0)
        pc = self.heel_C + Vector((-math.cos(am), math.sin(am))) * (self.Rh * 1.25)
        self.heel_patch = (Vector((pc.x, 0.0, pc.y)), Vector((0.7 * fs, 99.0, 0.98 * fs)), 0.25)

    def _solve(self):
        """Foot lines, instep centre Q and toe tip from the current axis height z_a."""
        al = self.alpha
        self.ax = Vector((math.cos(al), -math.sin(al)))           # foot axis direction
        self.nup = Vector((math.sin(al), math.cos(al)))           # up, perpendicular to the axis
        self.Pa = Vector((0.0, self.z_a))
        self.top_p = self.Pa + self.nup * self.A0
        self.top_d = self.ax.copy()
        self.sole_p = self.Pa - self.nup * self.A0
        self.sole_d = self.ax.copy()
        n_top = Vector((-self.top_d.y, self.top_d.x))
        qx = self.r_ank + self.ri
        qz = self.top_p.y + (self.ri - (qx - self.top_p.x) * n_top.x) / n_top.y
        self.Q = Vector((qx, qz))
        self.t_tip = self.foot_tip / math.cos(al)
        self.t_start = (self.Q - self.Pa).dot(self.ax)
        # the toe cap starts where the instep ends when the foot is short (no straight foot top)
        self.cap_len = max(0.25, min(self.cap, self.t_tip - self.t_start))
        self.t1 = self.t_tip - self.cap_len
        self.tip = self.Pa + self.ax * self.t_tip
        # heel: a circle of radius Rh whose back apex sits hb behind the ankle line; it touches the
        # sole line (dipping hdip below it) and meets the leg's back line below Q
        Rh = self.Rh
        cx = -self.r_ank - self.hb + Rh
        cz = self.sole_p.y + (Rh - (cx - self.sole_p.x) * self.nup.x) / self.nup.y - self.hdip
        self.ph_j = math.acos(max(-1.0, min(1.0, 1.0 - self.hb / Rh)))   # where it meets the leg
        cz -= max(0.0, cz + Rh * math.sin(self.ph_j) - (self.Q.y - 0.09))
        self.heel_C = Vector((cx, cz))
        self.z_bulge = cz                             # height of the heel's back apex
        self.z_h0 = cz + Rh * math.sin(self.ph_j)

    def _sole_at_x(self, x):
        s = (x - self.sole_p.x) / self.sole_d.x
        return self.sole_p + self.sole_d * s

    def A(self, t):
        """Foot half-thickness at axis parameter t: A0 at the instep, swelling to A1 over the toe."""
        f = _smooth((t - self.t_start) / max(self.t1 - self.t_start, 1e-3))
        return _lerp(self.A0, self.A1, f)

    def r_leg(self, z):
        t = _smooth((z - self.z_ank) / max(self.h - self.z_ank, 0.1))
        return _lerp(self.r_ank, self.r_top, t)

    def front_curve(self):
        """Front of the leg -> instep curve -> foot top, as a dense 2D polyline."""
        Q, ri = self.Q, self.ri
        pts = [Vector((self.r_leg(Q.y + 0.6), Q.y + 0.6)), Vector((self.r_ank, Q.y))]
        bt = math.atan2(-self.top_d.y, self.top_d.x)          # top line slope angle
        th_end = math.pi / 2 - bt
        for i in range(1, 25):
            th = th_end * i / 24
            pts.append(Q + Vector((-math.cos(th), -math.sin(th))) * ri)
        pts.append(pts[-1] + self.top_d * 5.0)
        return pts

    def back_curve(self):
        """Back of the leg -> a gentle concave fillet -> the round heel (an arc of the heel circle)
        -> the sole, as a dense 2D polyline (R frame)."""
        C, Rh = self.heel_C, self.Rh
        top = self.Q.y + 0.6
        pts = [(-self.r_leg(top), top), (-self.r_leg(self.Q.y), self.Q.y)]
        for deg in (50, 28, 6, -16, -38, -58):
            a = math.radians(deg)
            pts.append((C.x - Rh * math.cos(a), C.y + Rh * math.sin(a)))
        s0 = self.heel_C - self.nup * Rh
        for dx in (0.4, 0.85, 1.5, 2.6, 4.0):
            pts.append(tuple(self._sole_at_x(s0.x + dx)))
        return _catmull(pts, 10)

    def _foot_rings(self):
        """Foot rings perpendicular to the axis, then the blunt toe cap (tip vertex added later)."""
        out = []
        u = -self.nup
        span = self.t1 - self.t_start
        nfoot = round(span / 0.26) if span > 0.08 else 0
        for i in range(1, nfoot + 1):
            t = _lerp(self.t_start, self.t1, i / nfoot)
            f = _smooth((t - self.t_start) / max(span, 1e-3))
            out.append((self.Pa + self.ax * t, u, self.A(t), _lerp(self.wf0, self.wt, f), self.n_foot, 0))
        p = self.cap_p
        ncap = 7
        for i in range(1, ncap):
            xi = math.sin(i / ncap * math.pi / 2)
            sc = (1 - xi ** p) ** (1 / p)
            t = self.t1 + (self.t_tip - self.t1) * xi
            out.append((self.Pa + self.ax * t, u, self.A1 * sc, self.wt * sc, self.n_foot, 0))
        return out

    def leg_zs(self, z_low):
        """Heights of the outer leg rings from the lip down to z_low: one inside the cuff band, one
        on the band's lower border (so the colour border needs no extra cut), then ~0.42 apart."""
        zc = self.h - self.t / 2
        zs = [zc, _lerp(zc, self.cuff_z, 0.5), self.cuff_z]
        n = max(2, round((self.cuff_z - z_low) / 0.42))
        for i in range(1, n + 1):
            zs.append(_lerp(self.cuff_z, z_low, i / n))
        return zs

    def rings(self):
        """[(O(x,z), u(x,z), A, W, n, tag)] from the inner bottom to the toe; P(phi) = O - u*A*cos + y*W*sin."""
        h, t = self.h, self.t
        U_LEG = Vector((-1.0, 0.0))
        out = []
        # inside of the opening (tag 2) and the rolled lip (tag 1)
        r_in = self.r_top - t
        for z in (h - self.depth, h - self.depth * 0.55):
            out.append((Vector((0, z)), U_LEG, r_in * 0.97, r_in * 0.97, 2.0, 2))
        rc = self.r_top - t / 2
        zc = h - t / 2
        for a in (180, 140, 100, 60, 25):
            ar = math.radians(a)
            rr = rc + (t / 2) * math.cos(ar)
            zz = zc + (t / 2) * math.sin(ar) ** 0.8
            out.append((Vector((0, zz)), U_LEG, rr, rr, 2.0, 2 if a == 180 else 1))
        # outer leg: horizontal rings down to the fan pivot height
        z_low = self.Q.y if not self.single else self.z_swell
        zs = self.leg_zs(z_low)
        for z in zs[:-1]:
            r = self.r_leg(z)
            out.append((Vector((0, z)), U_LEG, r, r, 2.0, 0))
        if self.single:
            return out + self._bulb_rings(z_low)
        # fan around the instep: rays from Q sweep the heel/sole (back) and the instep/foot top (front)
        for th, F, G in self._fan():
            O = (F + G) / 2
            uu = (G - F).normalized()
            A = (G - F).length / 2
            s = _smooth(th / (math.pi / 2 - self.alpha))
            W = _lerp(self.r_ank, self.wf0, s)
            out.append((O, uu, A, W, _lerp(2.0, self.n_foot, s), 0))
        return out + self._foot_rings()

    def _fan(self, nf=15):
        """Rings around the instep: rays from Q at angles th (0 = horizontal toward the heel,
        pi/2 - alpha = straight down the foot's perpendicular). The angles are spaced evenly by the
        arc length they sweep on the heel/sole plus on the instep, so the round heel is as finely
        sampled as the instep. -> [(th, F front point, G back point)]"""
        back, front = self.back_curve(), self.front_curve()
        th_end = math.pi / 2 - self.alpha
        m = 160
        ths = [th_end * i / m for i in range(m + 1)]
        gs = [_ray_polyline(self.Q, Vector((-math.cos(t), -math.sin(t))), back) for t in ths]
        gs[0] = Vector((-self.r_leg(self.Q.y), self.Q.y))
        c0 = self.Pa + self.ax * self.t_start
        gs[-1] = c0 - self.nup * self.A(self.t_start)
        acc = [0.0]
        for i in range(1, m + 1):
            acc.append(acc[-1] + (gs[i] - gs[i - 1]).length + self.ri * 1.6 * (th_end / m))
        out = []
        j = 0
        for k in range(nf + 1):
            target = acc[-1] * k / nf
            while j < m - 1 and acc[j + 1] < target:
                j += 1
            f = (target - acc[j]) / max(acc[j + 1] - acc[j], 1e-9)
            th = _lerp(ths[j], ths[j + 1], min(max(f, 0.0), 1.0))
            dvec = Vector((-math.cos(th), -math.sin(th)))
            F = _ray_polyline(self.Q, dvec, front)
            G = _ray_polyline(self.Q, dvec, back)
            if k == 0:
                th, F, G = 0.0, Vector((self.r_ank, self.Q.y)), gs[0]
            if k == nf:
                th, F, G = th_end, c0 + self.nup * self.A(self.t_start), gs[-1]
            out.append((th, F, G))
        return out

    def _bulb_rings(self, z_low):
        """Singles: below z_swell the leg swells into a round bottom (no foot, no neck: the radius
        only grows) whose centre slides toward the front-left, so the back and right lines stay
        nearly straight and the bulge comes at the viewer like a stubby foot (the sheet's Socktopus)."""
        out = []
        rl, rb, zb, zt = self.r_leg(z_low), self.r_bulb, self.z_bulb, self.z_bot
        if self.lift > 0:
            # a wide sack with a broad, nearly flat bottom (tentacles hang from its rim)
            pts = [(self.r_leg(z_low + 0.3), z_low + 0.3), (rl, z_low), (_lerp(rl, rb, 0.55), z_low - 0.3),
                   (rb * 0.97, zb + 0.28), (rb, zb), (rb * 0.99, _lerp(zb, zt, 0.5)),
                   (self.bottom_ring[1], self.bottom_ring[0]), (rb * 0.55, zt + 0.012), (0.0, zt)]
        else:
            pts = [(self.r_leg(z_low + 0.3), z_low + 0.3), (rl, z_low),
                   (_lerp(rl, rb, 0.55), z_low - 0.36), (rb * 0.985, zb + 0.32), (rb, zb - 0.05),
                   (rb * 0.94, zb - 0.6), (self.bottom_ring[1], self.bottom_ring[0]), (0.0, zt)]
        prof = _catmull(pts, 6)
        # resample by arc length, skip the first point (already a leg ring)
        lens = [0.0]
        for a, b in zip(prof, prof[1:]):
            lens.append(lens[-1] + (b - a).length)
        start = lens[1 * 6]  # the point at z_low
        n = 12 if self.lift > 0 else 11
        for i in range(0, n):
            L = _lerp(start, lens[-1], i / n)
            j = max(k for k in range(len(lens)) if lens[k] <= L)
            j = min(j, len(prof) - 2)
            f = (L - lens[j]) / max(lens[j + 1] - lens[j], 1e-9)
            pnt = prof[j].lerp(prof[j + 1], f)
            # the swelling leans toward the front-left, like a stubby foot pointing at the viewer
            k = _smooth((z_low - pnt.y) / max(z_low - zb, 0.1))
            out.append((Vector((self.lean.x * k, pnt.y)), Vector((-1.0, 0.0)), pnt.x, pnt.x, 2.0, 0, self.lean.y * k))
        return out


def _sock_bmesh(shape):
    """Builds the closed ring surface. Face int layer 'tag': 0 outer, 1 lip, 2 inside."""
    bm = bmesh.new()
    tag = bm.faces.layers.int.new("tag")
    rings = shape.rings()
    vrings = []
    for ring_def in rings:
        O, u, A, W, n = ring_def[:5]
        oy = ring_def[6] if len(ring_def) > 6 else 0.0
        ring = []
        for j in range(SEG):
            ph = 2 * math.pi * j / SEG
            c, s = math.cos(ph), math.sin(ph)
            cs = math.copysign(abs(c) ** (2 / n), c)
            ss = math.copysign(abs(s) ** (2 / n), s)
            x = O.x - u.x * A * cs
            z = O.y - u.y * A * cs
            ring.append(bm.verts.new((x, oy + W * ss, z)))
        vrings.append(ring)
    bottom = bm.verts.new((0, 0, shape.h - shape.depth))
    tip = bm.verts.new((shape.tip.x, shape.tip_y, shape.tip.y))
    for j in range(SEG):
        f = bm.faces.new((bottom, vrings[0][j], vrings[0][(j + 1) % SEG]))
        f[tag] = 2
    for k in range(len(vrings) - 1):
        tg = rings[k][5] if rings[k][5] == rings[k + 1][5] else min(rings[k][5], rings[k + 1][5])
        if rings[k][5] == 2 and rings[k + 1][5] == 1:
            tg = 2
        for j in range(SEG):
            j2 = (j + 1) % SEG
            f = bm.faces.new((vrings[k][j], vrings[k + 1][j], vrings[k + 1][j2], vrings[k][j2]))
            f[tag] = tg
    last = vrings[-1]
    for j in range(SEG):
        f = bm.faces.new((last[j], tip, last[(j + 1) % SEG]))
        f[tag] = 0
    return bm


def _cut(bm, fn):
    """Cuts the outer faces (tag 0) along the iso-curve fn(co) = 0 so a colour border is a clean
    curve. Edge splits closer than 4% to a vertex snap to that vertex (no slivers)."""
    tag = bm.faces.layers.int.get("tag")

    def ok(e):
        return all(f[tag] == 0 for f in e.link_faces)

    val = {v: fn(v.co) for v in bm.verts}
    for e in bm.edges:
        if not ok(e):
            continue
        a, b = e.verts
        fa, fb = val[a], val[b]
        if fa * fb < 0:
            t = fa / (fa - fb)
            if t < 0.04:
                val[a] = 0.0
            elif t > 0.96:
                val[b] = 0.0
    for e in list(bm.edges):
        if not ok(e):
            continue
        a, b = e.verts
        fa, fb = val[a], val[b]
        if fa * fb < 0:
            _e, nv = bmesh.utils.edge_split(e, a, fa / (fa - fb))
            val[nv] = 0.0
    for f in list(bm.faces):
        if f[tag] != 0:
            continue
        vs = [l.vert for l in f.loops]
        sg = [0 if val[v] == 0.0 else (1 if val[v] > 0 else -1) for v in vs]
        if 1 not in sg or -1 not in sg:
            continue
        zeros = [i for i, s in enumerate(sg) if s == 0]
        if len(zeros) < 2:
            continue
        # split between the two zero verts that separate the + run from the - run
        n = len(vs)
        best = None
        for ia in range(len(zeros)):
            for ib in range(ia + 1, len(zeros)):
                i, j = zeros[ia], zeros[ib]
                if (j - i) % n in (1, n - 1):
                    continue
                side1 = {sg[k % n] for k in range(i + 1, j)} - {0}
                side2 = {sg[k % n] for k in range(j + 1, i + n)} - {0}
                if len(side1) == 1 and len(side2) == 1 and side1 != side2:
                    best = (vs[i], vs[j])
        if best:
            bmesh.utils.face_split(f, best[0], best[1])
    return bm


def _patch_val(p, patch, grow=0.0):
    """< 0 inside a colour patch: an ellipsoid (centre, radii, rot about +Y in the XZ plane)."""
    c, r, rot = patch
    q = p - c
    cr, sr = math.cos(rot), math.sin(rot)
    lx = q.x * cr + q.z * sr
    lz = -q.x * sr + q.z * cr
    return math.sqrt((lx / (r.x + grow)) ** 2 + (q.y / (r.y + grow)) ** 2 + (lz / (r.z + grow)) ** 2) - 1.0


def _mirror_patch(patch, d):
    c, r, rot = patch
    if d < 0:
        return (Vector((-c.x, c.y, c.z)), r.copy(), -rot)
    return (c.copy(), r.copy(), rot)


# ------------------------------------------------------------------ the feature contract
class SockCtx:
    """Everything feature builders (sockfeat_*.py) may rely on. Filled in by body_pieces() and
    face_pieces(); every number here is measured from (or used to build) the real mesh.

    Axes: Blender Z-up; the leg axis is the Z axis at x = y = 0; the FACE (eyes) is on the -Y side;
    the foot points along +X for "R" (d = +1), -X for "L" (d = -1); singles ("S", d = 0) have no
    foot. z = 0 is the floor / the sole. The game hangs the sock from `_Pin` at (0, 0, h + 0.1).
    A feature may set c.base_z (the floor point, when something reaches below z = 0 - Sockhopper's
    pogo tip) and c.pin_z (the clothespin grip, when something covers the top - Sockington's helm);
    build_sock writes them into the `_Base` / `_Pin` markers.
    L and R are exact mirror images (x -> -x): pick anything asymmetric by d (e.g. x = d * 0.3 is
    on the toe side, x = -d * 0.3 on the heel side; for singles use 1 instead of d).

    Identity / colours (palette indices)
        tid, spec, side, d
        body, accent         spec colours;  extra(key) -> palette index of spec[key]
        body_dark            heel/toe patches (a darker shade of the body)
        body_light           a lighter tone of the body (the default cuff band)
        body_deep            the inside of the opening
        cuff                 palette index the cuff band actually uses (spec["cuff"]: "light" by
                             default, "body" = no band, "dark", "accent"); ribs: the band has
                             RIBS vertical rib strips in cuff_rib, a tone between the band and
                             the body (spec["ribs"], default: light cuffs)
    Leg (a straight tube, 5% wider at the top, pinched 8% at the ankle)
        h                    z of the top of the leg (the rim of the opening)
        RL                   nominal leg radius (mid-leg); radius_at(z) is the exact value
        top_r, open_r, lip_t outer radius at the rim, radius of the hole, wall (lip) thickness
        open_depth           how far the dark inside goes down (z = h - open_depth)
        cuff_z, cuff_h       bottom of the cuff band and its height (cuff_z = h - cuff_h)
        instep_z             z where the front line of the leg starts to bend into the foot
                             (singles: where the leg starts to swell)
    Foot (footed socks: a short foot, heel back -> toe tip ~0.6 of the height, pointing
    down-forward along foot_axis, foot_alpha (~17 deg) below horizontal; as thick as the leg, a
    long soft instep sweep flowing into a fat round toe whose underside is the lowest point,
    z = 0; the heel underside floats heel_floor_z (~0.4) above the floor. A sock that must stand
    flat on a surface can be pitched by ~foot_alpha / 2 about the toe; hanging from _Pin it droops
    like the keyframe's clothesline socks)
        RF                   half-thickness of the foot over the toe (perpendicular to the axis)
        FOOT                 |x| of the toe tip (0 for singles);  toe_tip  Vector, the very tip
        sole_z               z of the floor under the toe (0.0)
        foot_alpha           droop of the foot axis below horizontal (radians)
        foot_axis            (start, end) Vectors: where the foot's centre line crosses the leg axis
                             -> the toe tip;  foot_dir  unit Vector along it (toward the toe)
        foot_r, foot_w       half thickness (perpendicular to the axis) and half width over the toe
        foot_top(x)          z of the top of the foot at signed x (for |x| beyond the leg)
        sole(x, y=0, lift=0) -> (point, normal) on the underside at signed x (cast straight up
                             from below): the real sole / heel underside / toe bottom, or None
        heel_floor_z         z of the lowest point of the heel's underside
        heel_c, heel_dir     a point inside the round heel and the unit direction its bulge faces
                             (back and down, ~35 deg below horizontal)
        heel_radii           Vector((along heel_dir, sideways +-Y, straight down)): EXACT distances
                             from heel_c to the outer surface in those three directions (ray cast)
        heel_r               min(heel_radii): a ball of this radius at heel_c stays inside the heel
                             and touches the surface in its tightest direction
        toe_c, toe_dir       a point inside the toe end (on the foot axis) and the foot direction
        toe_radii            Vector((along toe_dir, sideways +-Y, perpendicular to the axis toward
                             the sole)): EXACT distances to the outer surface;  toe_r = min(toe_radii)
        heel_patch, toe_patch  (centre Vector, radii Vector, rot) of the colour patches: ellipsoids
                             turned by rot about +Y (y radius 99 = straight through the foot);
                             in_heel(p) / in_toe(p) say whether a point is on a patch.
        heel_point, toe_point  (point, normal) on the surface in the middle of each dark patch
    Singles (Socktopus, The Lost Sock): FOOT = 0, foot_axis is a point; toe_* is the big dark patch
    low on the front-left of the swollen bottom (toe_dir points at it), heel_* the one on its right.
        bulb_lift            0: the round bottom sits on the floor; 1: a wide, flat-bottomed sack
                             ending ~1 above the floor so legs / tentacles can hang under it
        bulb_c, bulb_r       centre (Vector, at the widest height bulb_c.z) and radius of the sack
        bottom_z             z of the lowest point of the body (the middle of the bottom)
        bottom_ring          (centre Vector, radius): the rim of the bottom, 0.1 above bottom_z,
                             where the sides turn under (hang tentacles from here)
        bottom_point(angle, frac=0.7, lift=0) -> (point, normal) on the underside, frac of the way
                             from the sack's axis to bottom_ring in direction angle (0 = face -Y,
                             +pi/2 = +X); the normal points down/out
    Face (set by face_pieces, always equal to what it built)
        ey, eye_r            eye centre height, WHITE eyeball radius; eyeballs are squashed to
                             eye_flat along their outward direction; they face nearly straight
                             forward (-Y) and stand proud of the leg, so the toe-side eye hangs past
                             the leg's outline in a 3/4 view (like the sheet)
        eye_rim_r            outer radius of the black ink rim around each white (eye_r + 0.05);
                             the two rims just meet, so the eyes are 2 * eye_r + 0.05 apart and
                             the pair spans ~0.85 of the leg's width; the rim tops sit ~0.14 under
                             cuff_z (spec face_drop overrides)
        eyes, eye_n          [(x, y, z)] eyeball centres (viewer-left first), [Vector] outward dirs
        eye_mats             [Matrix] unit sphere -> white eyeball (local +Z out, +X right, +Y up),
                             BEFORE the wrap: each built eye is bent a little around the leg (every
                             point pulled back along -eye_n by a share of how far the leg falls
                             away under it; the share grows toward the rim)
        eye_wrap             [fn] eye_wrap[i](p) -> p bent the same way; T @ q gives a point on the
                             unbent ball, eye_wrap[i](T @ q) the point on the built eye
        pupils               [(x, y, z)] pupil centres on the (built) eyeball surface
        mouth_z, brow_z      height of the mouth line / the brows (mouth_z is set even when the
                             spec has mouth=False and no mouth is drawn)
        face_point(x, z, lift=0) -> (point, normal) on the front (-Y), riding over the eyes:
                             use it for things drawn on the face (moustaches, monocles, masks)
    Surface helpers (exact: ray casts against the outer body mesh)
        surface(angle, z, lift=0)  -> (point, normal) on the leg; angle 0 = face (-Y), +pi/2 = +X,
                                      pi = back. point is lifted `lift` along the normal. Use it to
                                      place decals (stripes, diamonds, armour) on the real surface.
        decal_matrix(angle, z, lift=0.01, spin=0.0) -> Matrix: local -Y = outward normal,
                                      local +X = around the leg (toward +angle), local +Z = up the
                                      surface; spin turns the decal about the normal. Use it as
                                      `mat` for flat pieces whose thin axis is local Y (diamonds,
                                      badges, armour plates). Offset stacked decals by >= 0.01.
        ray(origin, direction)     -> (point, normal) of the first outer-body hit, or None
        radius_at(z, angle=0.0)    leg radius at height z in that direction
        around(angle, z, lift=0)   point at radius_at(z, angle) + lift, horizontally from the axis
        front(x, z, lift=0)        point on the face side (-Y) at sideways x, pushed lift toward -Y
    """

    def __init__(self, tid, spec, side):
        self.tid, self.spec, self.side = tid, spec, side
        self.d = -1.0 if side == "L" else (1.0 if side == "R" else 0.0)
        self.h = leg_height(spec)
        self.shape = _Shape(spec, side == "S")
        sh = self.shape
        self.RL, self.RF = RL, RF
        self.FOOT = sh.foot_tip if side != "S" else 0.0
        self.top_r, self.lip_t = sh.r_top, sh.t
        self.open_r = sh.r_top - sh.t
        self.open_depth = sh.depth
        self.cuff_z, self.cuff_h = sh.cuff_z, sh.cuff_h
        self.instep_z = sh.Q.y if side != "S" else sh.z_swell
        self.foot_alpha = sh.alpha if side != "S" else 0.0
        self.bulb_lift = getattr(sh, "lift", 0.0)
        self.sole_z = 0.0
        self.body = hexcol(f"{tid}_body", spec["body"])
        self.accent = hexcol(f"{tid}_accent", spec["accent"])
        dark = spec.get("dark") or _shade(spec["body"])
        self.body_dark = hexcol(f"{tid}_dark", dark)
        self.body_light = hexcol(f"{tid}_light", spec.get("light") or _tint(spec["body"], 0.45))
        self.body_deep = hexcol(f"{tid}_inner", spec.get("inner") or _shade(dark, 0.84, 0.05))
        cuff = spec.get("cuff", "light")
        self.cuff = {"dark": self.body_dark, "body": self.body, "light": self.body_light,
                     "accent": self.accent}.get(cuff, self.body_light)
        self.ribs = bool(spec.get("ribs", cuff == "light"))
        cuff_hex = {"dark": dark, "body": spec["body"], "accent": spec["accent"]}.get(
            cuff, spec.get("light") or _tint(spec["body"], 0.45))
        self.cuff_rib = hexcol(f"{tid}_rib", _hex(tuple(_lerp(x, y, 0.4) for x, y in zip(_rgb(cuff_hex), _rgb(spec["body"])))))
        d = self.d
        if side != "S":
            self.toe_tip = Vector((d * sh.tip.x, 0.0, sh.tip.y))
            self.foot_r, self.foot_w = sh.A1, sh.wt
            self.foot_axis = (Vector((0.0, 0.0, sh.Pa.y)), self.toe_tip.copy())
            self.foot_dir = Vector((d * sh.ax.x, 0.0, sh.ax.y))
            self.RF = sh.A1
            tc = sh.Pa + sh.ax * (sh.t_tip - sh.A1 * 0.95)
            self.toe_c = Vector((d * tc.x, 0.0, tc.y))
            self.toe_dir = self.foot_dir.copy()
            self._toe_down = Vector((d * -sh.nup.x, 0.0, -sh.nup.y))
            hc = sh.heel_C
            self.heel_c = Vector((d * hc.x, 0.0, hc.y))
            hd = math.radians(35.0)
            self.heel_dir = Vector((-d * math.cos(hd), 0.0, -math.sin(hd)))
        else:
            self.toe_tip = Vector((sh.tip.x, sh.tip_y, sh.z_bot))
            self.foot_r = self.foot_w = 0.0
            self.foot_axis = (self.toe_tip.copy(), self.toe_tip.copy())
            self.foot_dir = Vector((0.0, 0.0, -1.0))
            self.toe_c = Vector((sh.lean.x * 0.6, sh.lean.y * 0.6, sh.z_bulb - 0.1))
            tp = sh.toe_patch[0]
            self.toe_dir = Vector((tp.x - self.toe_c.x, tp.y - self.toe_c.y, 0.0)).normalized()
            self._toe_down = Vector((0.0, 0.0, -1.0))
            self.heel_c = Vector((sh.lean.x * 0.6, sh.lean.y * 0.6, sh.z_bulb))
            hp = sh.heel_patch[0]
            self.heel_dir = Vector((hp.x - self.heel_c.x, hp.y - self.heel_c.y, 0.0)).normalized()
            self.bulb_c = Vector((sh.lean.x, sh.lean.y, sh.z_bulb))
            self.bulb_r = sh.r_bulb
            self.bottom_z = sh.z_bot
            bz, br = sh.bottom_ring
            self.bottom_ring = (Vector((sh.lean.x, sh.lean.y, bz)), br)
        # rough values until body_pieces() measures them on the mesh
        self.toe_radii = Vector((sh.A1, sh.wt, sh.A1)) if side != "S" else Vector((0.8, 0.8, 0.8))
        self.heel_radii = Vector((0.4, 0.5, 0.4))
        self.toe_r, self.heel_r = min(self.toe_radii), min(self.heel_radii)
        self.toe_patch = _mirror_patch(sh.toe_patch, d)
        self.heel_patch = _mirror_patch(sh.heel_patch, d)
        self.heel_point = self.toe_point = None     # measured on the mesh by body_pieces()
        self.heel_floor_z = 0.0
        # face (face_pieces fills these in)
        self.ey = 0.0
        self.eyes, self.eye_n, self.pupils, self.eye_mats, self.eye_wrap = [], [], [], [], []
        self.eye_r = self.eye_rim_r = 0.0
        self.eye_flat = EYE_FLAT
        self.mouth_z = 0.0
        self.brow_z = 0.0
        self._bvh = None
        self._eye_solids = []

    # -- colours
    def extra(self, key="extra"):
        """Palette index of an extra spec colour (e.g. spec['extra'])."""
        return hexcol(f"{self.tid}_{key}", self.spec[key])

    # -- patches
    def in_toe(self, p):
        return _patch_val(Vector(p), self.toe_patch) < 0

    def in_heel(self, p):
        return _patch_val(Vector(p), self.heel_patch) < 0

    def _measure_ends(self):
        """Exact heel / toe radii by ray casts from their centres (called once the BVH exists)."""
        def dist(o, dvec):
            hit = self.ray(o, dvec)
            return (hit[0] - Vector(o)).length if hit else 0.0

        side_y = lambda o: min(dist(o, (0.0, 1.0, 0.0)), dist(o, (0.0, -1.0, 0.0)))  # noqa: E731
        self.heel_radii = Vector((dist(self.heel_c, self.heel_dir), side_y(self.heel_c),
                                  dist(self.heel_c, (0.0, 0.0, -1.0))))
        self.toe_radii = Vector((dist(self.toe_c, self.toe_dir), side_y(self.toe_c),
                                 dist(self.toe_c, self._toe_down)))
        self.heel_r, self.toe_r = min(self.heel_radii), min(self.toe_radii)
        self.heel_floor_z = self.heel_c.z - self.heel_radii.z
        for key, c_in, patch in (("heel_point", self.heel_c, self.heel_patch), ("toe_point", self.toe_c, self.toe_patch)):
            dvec = patch[0] - Vector(c_in)
            dvec.y *= 0.0 if self.d else 1.0
            setattr(self, key, self.ray(c_in, dvec) if dvec.length > 1e-6 else None)

    # -- surface
    def sole(self, x, y=0.0, lift=0.0):
        """(point, normal) on the underside of the foot at signed x (cast straight up from below
        the floor), lifted `lift` along the normal; None where there is no foot."""
        hit = self.ray((x, y, -1.0), (0.0, 0.0, 1.0))
        if hit is None:
            return None
        p, n = hit
        return p + n * lift, n

    def bottom_point(self, angle, frac=0.7, lift=0.0):
        """Singles: (point, normal) on the underside of the sack, `frac` of the way from its axis to
        bottom_ring in direction angle (0 = face -Y, +pi/2 = +X), lifted `lift` along the normal."""
        cen, rad = self.bottom_ring if self.side == "S" else (Vector((0.0, 0.0, 0.0)), self.RL)
        q = cen + Vector((math.sin(angle), -math.cos(angle), 0.0)) * (rad * frac)
        hit = self.ray((q.x, q.y, cen.z + 0.8), (0.0, 0.0, -1.0))
        if hit is None:
            return Vector((q.x, q.y, cen.z - 0.1)), Vector((0.0, 0.0, -1.0))
        p, n = hit
        return p + n * lift, n
    def ray(self, origin, direction):
        loc, nrm, i, _dist = self._bvh.ray_cast(Vector(origin), Vector(direction).normalized())
        if loc is None:
            return None
        # smooth normal: the hit face's vertex normals blended like Blender's own interpolation
        poly = self._polys[i]
        ws = poly_3d_calc([self._verts[vi] for vi in poly], loc)
        n = Vector((0.0, 0.0, 0.0))
        for vi, w in zip(poly, ws):
            n += self._vnormals[vi] * w
        if n.length < 1e-6 or n.dot(nrm) < 0.3:
            n = nrm
        return loc, n.normalized()

    def surface(self, angle, z, lift=0.0):
        z = min(z, self.h - self.lip_t * 0.6)
        dvec = Vector((math.sin(angle), -math.cos(angle), 0.0))
        hit = self.ray((0.0, 0.0, z), dvec)
        if hit is None:
            r = self.RL
            p = Vector((dvec.x * r, dvec.y * r, z))
            return p + dvec * lift, dvec.copy()
        p, n = hit
        return p + n * lift, n

    def decal_matrix(self, angle, z, lift=0.01, spin=0.0):
        p, n = self.surface(angle, z, lift)
        out = n.normalized()
        tang = Vector((math.cos(angle), math.sin(angle), 0.0))  # d(point)/d(angle) direction
        tang = (tang - out * tang.dot(out)).normalized()
        up = tang.cross(-out).normalized()  # local axes X = tang, Y = -out, Z = X x Y (up)
        rot = Matrix((tang, -out, up)).transposed().to_4x4()
        return Matrix.Translation(p) @ rot @ Matrix.Rotation(spin, 4, "Y")

    def radius_at(self, z, angle=0.0):
        """Leg radius at height z (exact, measured on the mesh) in direction `angle`."""
        p, _n = self.surface(angle, z)
        return math.hypot(p.x, p.y)

    def around(self, angle, z, lift=0.0):
        """Point on the leg surface at height z; angle 0 = the face (-Y), +pi/2 = +X, pi = back."""
        r = self.radius_at(z, angle) + lift
        return (math.sin(angle) * r, -math.cos(angle) * r, z)

    def front(self, x, z, lift=0.0):
        """Point on the face side (-Y) of the leg at sideways offset x and height z."""
        z = min(z, self.h - self.lip_t * 0.6)
        hit = self.ray((x, 0.0, z), (0.0, -1.0, 0.0))
        if hit is None:
            r = self.RL
            return (x, -math.sqrt(max(r * r - x * x, 0.01)) - lift, z)
        p, _n = hit
        return (p.x, p.y - lift, p.z)

    def foot_top(self, x):
        """z of the top of the foot at signed x (cast straight down; meant for |x| beyond the leg)."""
        hit = self.ray((x, 0.0, self.h + 2.0), (0.0, 0.0, -1.0))
        return hit[0].z if hit else 0.0

    def face_point(self, x, z, lift=0.0):
        """(point, normal) on the front (-Y) at sideways x and height z, riding over the eyeballs
        and their ink rims where they stand in front of the leg; lifted `lift` along the normal."""
        hit = self.ray((x, 0.0, z), (0.0, -1.0, 0.0))
        if hit is None:
            p, n = Vector(self.front(x, z)), Vector((0.0, -1.0, 0.0))
        else:
            p, n = hit
        o = Vector((x, 0.0, z))
        for T, Ti, Tn, wrap in self._eye_solids:
            lo = Ti @ o
            dv = Ti.to_3x3() @ Vector((0.0, -1.0, 0.0))
            qa, qb, qc = dv.dot(dv), 2 * lo.dot(dv), lo.dot(lo) - 1.0
            disc = qb * qb - 4 * qa * qc
            if disc <= 0:
                continue
            q = lo + dv * ((-qb + math.sqrt(disc)) / (2 * qa))
            w = wrap(T @ q)
            if w.y < p.y:
                p, n = w, (Tn @ q).normalized()
        return p + n * lift, n


def body_pieces(c: SockCtx):
    """The sock body as one region-coloured Piece; also builds c's surface BVH and measures the
    heel / toe radii on it."""
    sh, spec, h = c.shape, c.spec, c.h
    bm = _sock_bmesh(sh)
    scale = h / H if not spec.get("tall") else 1.0
    stripes = []
    for z0, z1, col in spec.get("stripes", []):
        pal = c.accent if col == "accent" else color(col)
        stripes.append((z0 * scale, z1 * scale, pal))
    # colour borders, cut as smooth curves into the outer surface
    _cut(bm, lambda p: p.z - c.cuff_z)
    for z0, z1, _p in stripes:
        _cut(bm, lambda p, z0=z0: p.z - z0)
        _cut(bm, lambda p, z1=z1: p.z - z1)

    toe_stripe = spec.get("toe_stripe") if not sh.single else None
    _cut(bm, lambda p: _patch_val(p, sh.toe_patch))
    _cut(bm, lambda p: _patch_val(p, sh.heel_patch))
    if toe_stripe:
        g, w, _col = toe_stripe
        _cut(bm, lambda p: _patch_val(p, sh.toe_patch, g))
        _cut(bm, lambda p: _patch_val(p, sh.toe_patch, g + w))
    tstripe_pal = None
    if toe_stripe:
        tstripe_pal = c.accent if toe_stripe[2] == "accent" else color(toe_stripe[2])

    tag = bm.faces.layers.int.get("tag")

    def region(f):
        if f[tag] == 2:
            return c.body_deep
        if f[tag] == 1:
            return c.cuff
        p = f.calc_center_median()
        if p.z > c.cuff_z:
            if c.ribs and int(math.floor((math.atan2(p.y, p.x) % math.tau) / (math.tau / SEG))) % 2:
                return c.cuff_rib
            return c.cuff
        for z0, z1, pal in stripes:
            if z0 <= p.z <= z1:
                return pal
        if _patch_val(p, sh.toe_patch) < 0 or _patch_val(p, sh.heel_patch) < 0:
            return c.body_dark
        if toe_stripe and _patch_val(p, sh.toe_patch, toe_stripe[0] + toe_stripe[1]) < 0 < _patch_val(p, sh.toe_patch, toe_stripe[0]):
            return tstripe_pal
        return c.body

    pals = [region(f) for f in bm.faces]
    outer = [f[tag] == 0 for f in bm.faces]
    if c.d < 0:  # left sock: mirror
        for v in bm.verts:
            v.co.x = -v.co.x
        bmesh.ops.reverse_faces(bm, faces=bm.faces)
    bm.normal_update()
    verts = [v.co.copy() for v in bm.verts]
    for i, v in enumerate(bm.verts):
        v.index = i
    polys = [[v.index for v in f.verts] for f, o in zip(bm.faces, outer) if o]
    c._bvh = BVHTree.FromPolygons(verts, polys)
    c._verts, c._polys = verts, polys
    c._vnormals = [v.normal.copy() for v in bm.verts]
    c._measure_ends()
    me = bpy.data.meshes.new("sockbody")
    bm.to_mesh(me)
    bm.free()
    return [K.Piece(me, pals, outline=True, smooth=True, name="body")]


# ------------------------------------------------------------------ face
EYE_R = 0.27      # white eyeball radius (the ink rim adds EYE_RIM around it)
EYE_RIM = 0.05    # the black ink rim reaches this far past the white ball's radius
EYE_FLAT = 0.55   # eyeballs are squashed along their outward direction (googly, not ping-pong)
EYE_POP = 0.04    # eyeball centre this far in front of the leg surface (bulges ~0.2)
EYE_TURN = 1.35   # how far the eyes turn from the leg's normal toward the viewer (-Y): both
                  # eyes face nearly straight forward, like two balls stuck on the front
EYE_WRAP = 0.4    # how much of the leg's fall-off under the eye's outer half bends the eye back
EYE_SEG = 24      # vertices around an eye: the white and its ink rim share this phase
EYE_GAP = 0.14    # default gap between the cuff band and the top of the eye rims
INK = 0.032       # half width of drawn ink lines (mouths); brows use 0.04


def _cap(pal, axis, ang, mat, lift=0.012, seg=16, rings=3, outline=False, name="cap"):
    """A decal cap on a (squashed) sphere: the points of the unit sphere within `ang` radians of
    `axis`, moved by `mat` (e.g. an eyeball's unit-sphere matrix) and then lifted `lift` world
    units along the surface normal, so it never z-fights the ball. Pupils, glints, eyelids."""
    radius = 1.0
    axis = Vector(axis).normalized()
    ref = Vector((0, 0, 1)) if abs(axis.z) < 0.9 else Vector((1, 0, 0))
    e1 = axis.cross(ref).normalized()
    e2 = axis.cross(e1).normalized()
    bm = bmesh.new()
    top = bm.verts.new(axis * radius)
    prev = None
    for r in range(1, rings + 1):
        a = ang * r / rings
        ring = []
        for j in range(seg):
            ph = 2 * math.pi * j / seg
            dvec = axis * math.cos(a) + (e1 * math.cos(ph) + e2 * math.sin(ph)) * math.sin(a)
            ring.append(bm.verts.new(dvec * radius))
        if prev is None:
            for j in range(seg):
                bm.faces.new((top, ring[j], ring[(j + 1) % seg]))
        else:
            for j in range(seg):
                bm.faces.new((prev[j], ring[j], ring[(j + 1) % seg], prev[(j + 1) % seg]))
        prev = ring
    bm.normal_update()
    bm.faces.ensure_lookup_table()
    if bm.faces[0].normal.dot(bm.faces[0].calc_center_median()) < 0:  # face away from the centre
        bmesh.ops.reverse_faces(bm, faces=bm.faces)
    nmat = mat.to_3x3().inverted().transposed()
    for v in bm.verts:
        n = (nmat @ v.co).normalized()
        v.co = mat @ v.co + n * lift
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    return K.Piece(me, pal, outline, True, name)


def _eye_matrix(ctr, n, r, flat):
    """Unit sphere -> eyeball: centre ctr, local +Z = n (outward), +X = right, +Y = up."""
    x = Vector((0, 0, 1)).cross(n).normalized()
    y = n.cross(x).normalized()
    rot = Matrix((x, y, n)).transposed().to_4x4()
    return Matrix.Translation(ctr) @ rot @ Matrix.Diagonal(Vector((r, r, r * flat, 1.0)))


def _eye_white(mat, r, r0, seg=EYE_SEG, name="eye"):
    """The white eyeball: a squashed ball (`mat` maps the unit sphere onto it, local +Z out) built
    ring by ring so that one ring lies exactly at radius r0 (the inner edge of the ink rim) with
    the rim's vertex phase: the white/black border is then the rim's own clean edge, never a
    saw-tooth of crossing facets. The back half is flattened (hidden inside the rim / the leg)."""
    th0 = math.asin(min(r0 / r, 0.999))
    ths = [th0 * k / 3 for k in range(1, 4)] + [math.pi / 2]   # past th0: under the rim
    bm = bmesh.new()
    top = bm.verts.new((0.0, 0.0, 1.0))
    rings = []
    for th in ths:
        z = math.cos(th) * (0.5 if th > math.pi / 2 else 1.0)
        rings.append([bm.verts.new((math.sin(th) * math.cos(2 * math.pi * k / seg),
                                    math.sin(th) * math.sin(2 * math.pi * k / seg), z)) for k in range(seg)])
    bot = bm.verts.new((0.0, 0.0, -0.5))
    for k in range(seg):
        k2 = (k + 1) % seg
        bm.faces.new((top, rings[0][k], rings[0][k2]))
        bm.faces.new((bot, rings[-1][k2], rings[-1][k]))
    for ra, rb in zip(rings, rings[1:]):
        for k in range(seg):
            k2 = (k + 1) % seg
            bm.faces.new((ra[k], rb[k], rb[k2], ra[k2]))
    for v in bm.verts:
        v.co = mat @ v.co
    bm.normal_update()
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    return K.Piece(me, K.WHITE, False, True, name)


def _eye_rim(c, ctr, ex, ey_, n, r, a, R, wrap, seg=EYE_SEG, name="eyerim"):
    """The ink ring of a googly eye: a rounded black bead whose inner edge sits exactly on the
    white ball's ring at r0 = r - 0.028 (same vertices, lifted 0.003), reaching R in the eye's
    equator plane. The bead is bent with `wrap` (the eye's wrap function) right here; then a short
    skirt runs from its outer edge the shortest way onto the leg (ray-cast mostly toward the leg
    axis) and 0.03 into it, so the eye never floats, has no gap, and its side shows only a thin
    ink band from any angle."""
    r0 = r - 0.028
    z0 = a * math.sqrt(max(1.0 - r0 * r0 / (r * r), 0.0))
    prof = [(r0, z0 + 0.003), (_lerp(r0, R, 0.32), z0 + 0.012), (_lerp(r0, R, 0.72), z0 * 0.62), (R, 0.0)]
    bm = bmesh.new()
    rings = [[] for _p in prof] + [[]]
    for k in range(seg):
        ph = 2 * math.pi * k / seg
        dvec = ex * math.cos(ph) + ey_ * math.sin(ph)
        for i, (rho, z) in enumerate(prof):
            rings[i].append(bm.verts.new(wrap(ctr + dvec * rho + n * z)))
        e = wrap(ctr + dvec * R)
        inward = Vector((-e.x, -e.y, 0.0)).normalized()
        dv = (inward * 0.75 - n * 0.25).normalized()
        hit = c.ray(e, dv)
        base = hit[0] + dv * 0.03 if hit and (hit[0] - e).length < 0.6 else e - n * 0.12
        rings[-1].append(bm.verts.new(base))
    ref = ctr - n * 0.25
    for r0_, r1_ in zip(rings, rings[1:]):
        for k in range(seg):
            k2 = (k + 1) % seg
            f = bm.faces.new((r0_[k], r1_[k], r1_[k2], r0_[k2]))
            f.normal_update()
            if f.normal.dot(f.calc_center_median() - ref) < 0:
                f.normal_flip()
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    return K.Piece(me, K.BLACK, False, True, name)


def _eye_wrap_fn(c, ctr, ex, ey_, n, R, amount=EYE_WRAP):
    """p -> p pulled back along -n by `amount` of how far the leg surface falls away (below the
    eye's equator plane) under p, compared with under the eye's centre: bends a googly eye a
    little around the leg (amount 1 would make it a sticker; 0.25 keeps it a forward-facing ball
    whose outer edge stands proud of the leg, like the sheet's eyes)."""
    def drop(u, v):
        e = ctr + ex * u + ey_ * v
        hit = c.ray(e + n * 0.4, -n)
        return (hit[0] - e).dot(-n) if hit else None

    d0 = drop(0.0, 0.0) or 0.0
    cache = {}

    def fn(p):
        q = Vector(p) - ctr
        u, v = q.dot(ex), q.dot(ey_)
        rho = math.hypot(u, v)
        if rho > R:
            u, v = u * R / rho, v * R / rho
        key = (round(u, 3), round(v, 3))
        if key not in cache:
            dd = drop(u, v)
            f = amount * (0.6 + 0.8 * min(rho / R, 1.0) ** 2)    # bends the rim more than the middle
            cache[key] = 0.0 if dd is None else max(dd - d0, 0.0) * f
        return Vector(p) - n * cache[key]
    return fn


def _wrap_pieces(pieces, fn):
    for pc in pieces:
        for v in pc.mesh.vertices:
            v.co = fn(v.co)
        pc.mesh.update()


def _ink(pts, nrms, radius=INK, flat=0.5, seg=6, samples=4, pal=None, taper=1.0, name="ink"):
    """A drawn ink line through 3D points: a tube with an elliptical cross-section (`radius`
    across the surface, radius * flat along the surface normal, so it reads as a flat stroke and
    never stands off the face) and rounded ends. nrms are the surface normals at pts. taper < 1
    makes a brush stroke: full radius in the middle, `taper` * radius at both ends."""
    pal = K.BLACK if pal is None else pal
    P = _catmull([Vector(p) for p in pts], samples)
    N = _catmull([Vector(n) for n in nrms], samples)
    m = len(P)
    rads = [radius * _lerp(taper, 1.0, math.sin(math.pi * i / max(m - 1, 1)) ** 0.7) for i in range(m)]
    T = [(P[min(i + 1, m - 1)] - P[max(i - 1, 0)]).normalized() for i in range(m)]
    bm = bmesh.new()

    def ring(ctr, t, nn, rad):
        nn = (nn - t * nn.dot(t)).normalized()
        b = t.cross(nn)
        out = []
        for k in range(seg):
            a = 2 * math.pi * k / seg
            out.append(bm.verts.new(ctr + b * (rad * math.cos(a)) + nn * (rad * flat * math.sin(a))))
        return out

    r0, r1 = rads[0], rads[-1]
    rings_ = [ring(P[0] - T[0] * r0 * 0.6, T[0], N[0], r0 * 0.78)]
    rings_ += [ring(P[i], T[i], N[i], rads[i]) for i in range(m)]
    rings_.append(ring(P[-1] + T[-1] * r1 * 0.6, T[-1], N[-1], r1 * 0.78))
    tip0 = bm.verts.new(P[0] - T[0] * r0 * 0.95)
    tip1 = bm.verts.new(P[-1] + T[-1] * r1 * 0.95)
    for k in range(seg):
        k2 = (k + 1) % seg
        bm.faces.new((tip0, rings_[0][k2], rings_[0][k]))
        bm.faces.new((tip1, rings_[-1][k], rings_[-1][k2]))
    for ra, rb in zip(rings_, rings_[1:]):
        for k in range(seg):
            k2 = (k + 1) % seg
            bm.faces.new((ra[k], rb[k], rb[k2], ra[k2]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    return K.Piece(me, pal, False, True, name)


def _stroke(pts, radius=INK, name="stroke"):
    """Old helper kept for compatibility: an ink line facing -Y through 3D points."""
    return [_ink(pts, [(0.0, -1.0, 0.0)] * len(pts), radius, name=name)]


def _plate(face_point, us, top, bot, lift, pal, depth=0.03, name="plate"):
    """A thin plate conforming to the face between the curves z = top(u) and z = bot(u)
    (u = sideways x): front at `lift` along the surface normal, back `depth` behind it. Fangs,
    open mouths, tongues - flat colour shapes drawn on the face, no outline hull."""
    bm = bmesh.new()
    cols = []
    for u in us:
        zt, zb = top(u), bot(u)
        if zt - zb < 0.004:
            zt, zb = zt + 0.002, zb - 0.002
        col = []
        for z in (zt, zb):
            p, n = face_point(u, z, 0.0)
            col.append((bm.verts.new(p + n * lift), bm.verts.new(p + n * (lift - depth))))
        cols.append(col)
    for a, b in zip(cols, cols[1:]):
        (at, atb), (ab, abb) = a
        (bt, btb), (bb, bbb) = b
        bm.faces.new((at, ab, bb, bt))        # front
        bm.faces.new((atb, btb, bbb, abb))    # back
        bm.faces.new((at, bt, btb, atb))      # top wall
        bm.faces.new((ab, abb, bbb, bb))      # bottom wall
    for col, flip in ((cols[0], False), (cols[-1], True)):
        (t, tb), (b, bb_) = col
        bm.faces.new((t, tb, bb_, b) if not flip else (t, b, bb_, tb))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    return K.Piece(me, pal, False, True, name)


def _inked(face_point, shape, pal, border=0.03, lift=0.026, n=9, name="plate"):
    """A colour plate with an even ink border. shape(g) -> (x0, x1, top(u), bot(u)) is the outline
    grown by g on every side; the black plate is shape(border), the colour plate shape(0) sits
    0.012 in front of it."""
    out = []
    for g, lf, pl, nm, k in ((border, lift - 0.012, K.BLACK, name + "_ink", n + 2), (0.0, lift, pal, name, n)):
        x0, x1, top, bot = shape(g)
        out.append(_plate(face_point, [_lerp(x0, x1, i / (k - 1)) for i in range(k)], top, bot, lf, pl, name=nm))
    return out


def face_pieces(c: SockCtx):
    """Googly eyes (a white ball in an even black ink rim, bent around the leg; big pupil, glint),
    the mood mouth / fangs / tongue and brows on the front (-Y) of the leg. Writes the eye / mouth bookkeeping into c (so features always
    line up with what is built here)."""
    spec, h, d = c.spec, c.h, c.d
    dd = d if d else 1.0
    mood = spec.get("mood", "happy")
    short = bool(spec.get("short"))
    eye_r = EYE_R * (0.97 if short else 1.0)
    rim_r = eye_r + EYE_RIM
    flat = EYE_FLAT
    a = eye_r * flat
    # eyes high on the leg: the rim tops sit EYE_GAP under the cuff band (never higher than
    # 0.8 / 0.66 below the top), close together, facing forward
    drop = spec.get("face_drop", max(0.66 if short else 0.8, c.shape.cuff_h + EYE_GAP + rim_r))
    ey = h - drop
    half = eye_r + EYE_RIM / 2           # rims just meet: centres 2 * eye_r + EYE_RIM apart
    out = []
    eyes, normals, pupils, mats, solids, wraps = [], [], [], [], [], []
    look = Vector((0.26 * d, -0.46, 1.0)).normalized()   # local (right, up, out): down + toward the toe
    for s in (-1, 1):
        ex = s * half * 0.9
        for _i in range(5):
            hit = c.ray((ex, 0.0, ey), (0.0, -1.0, 0.0))
            p, n = hit if hit else (Vector(c.front(ex, ey)), Vector((0, -1, 0)))
            n = Vector((n.x, n.y, 0.0)).normalized()
            n = (n + Vector((0.0, -EYE_TURN, 0.0))).normalized()   # turned toward the viewer
            ctr = p + n * EYE_POP
            ex += s * half - ctr.x
        T = _eye_matrix(ctr, n, eye_r, flat)
        Tr = _eye_matrix(ctr, n, rim_r, 0.05 / rim_r)       # proxy of the rim bead (face_point)
        mats.append(T)
        eyes.append(tuple(ctr))
        normals.append(n)
        xa = Vector((0, 0, 1)).cross(n).normalized()
        ya = n.cross(xa).normalized()
        wrap = _eye_wrap_fn(c, ctr, xa, ya, n, rim_r)
        for M_ in (T, Tr):
            solids.append((M_, M_.inverted(), M_.to_3x3().inverted().transposed(), wrap))
        eye_parts = [_eye_white(T, eye_r, eye_r - 0.028)]
        rim = _eye_rim(c, ctr, xa, ya, n, eye_r, a, rim_r, wrap)    # bent by wrap already
        pupils.append(tuple(wrap(T @ look)))
        eye_parts.append(_cap(K.BLACK, look, math.radians(36), T, lift=0.012, seg=20, rings=2, name="pupil"))
        gdir = (look + Vector((-0.3, 0.36, 0.0))).normalized()
        eye_parts.append(_cap(K.WHITE, gdir, math.radians(9), T, lift=0.024, seg=10, rings=1, name="glint"))
        _wrap_pieces(eye_parts, wrap)
        wraps.append(wrap)
        out += eye_parts + [rim]
    c.ey, c.eye_r, c.eye_rim_r, c.eye_flat = ey, eye_r, rim_r, flat
    c.eyes, c.eye_n, c.pupils, c.eye_mats = eyes, normals, pupils, mats
    c._eye_solids = solids
    c.eye_wrap = wraps
    fp = c.face_point

    my = ey - rim_r - (0.2 if not short else 0.17)
    c.mouth_z = my
    c.brow_z = ey + rim_r + 0.06

    def line(xs, zs, radius=INK, lift=0.012):
        hits = [fp(x, my + z, lift) for x, z in zip(xs, zs)]
        return _ink([p for p, _n in hits], [n for _p, n in hits], radius, name="mouth")

    def oval(cx, cz, hw, hh, sq=2.0):
        """shape(g) of an oval (superellipse exponent sq) centred at (cx, cz)."""
        def shape(g):
            w, hgt = hw + g, hh + g
            f = lambda u: hgt * max(1 - abs((u - cx) / w) ** sq, 0.0) ** (1 / sq)  # noqa: E731
            return cx - w, cx + w, (lambda u: cz + f(u)), (lambda u: cz - f(u))
        return shape

    if spec.get("mouth", True) and mood != "puppet":
        if mood in ("happy", "calm", "brave"):
            w = {"happy": 0.2, "calm": 0.16, "brave": 0.23}[mood]
            sag = {"happy": 0.09, "calm": 0.05, "brave": 0.07}[mood]
            xs = [-w, -w * 0.5, 0.0, w * 0.5, w]
            out.append(line(xs, [sag * ((x / w) ** 2) - sag * 0.4 for x in xs]))
        elif mood in ("smug", "cool"):
            sgn = (1 if mood == "smug" else -1) * dd     # smug: the smirk rises toward the toe
            out.append(line([sgn * x for x in (-0.18, -0.06, 0.06, 0.17, 0.24)], [0.0, -0.03, -0.02, 0.03, 0.085]))
        elif mood == "sad":
            w = 0.22
            xs = [-w, -w * 0.5, 0.0, w * 0.5, w]
            out.append(line(xs, [-0.1 * ((x / w) ** 2) + 0.05 for x in xs]))
        elif mood == "tired":
            out.append(line([-0.17, -0.06, 0.06, 0.17], [0.0, 0.025, -0.015, 0.01]))
        elif mood == "stress":
            xs = [-0.22, -0.15, -0.075, 0.0, 0.075, 0.15, 0.22]
            out.append(line(xs, [0.035 if i % 2 else -0.035 for i in range(len(xs))], radius=0.028))
        elif mood == "shock":
            out += _inked(fp, oval(0.0, my + 0.01, 0.12, 0.16), C_PINKMOUTH, border=0.035, n=11, name="mouth")
        elif mood == "fangs":
            # a wide grin under both eyes showing a dark crescent and two broad white fangs
            # hanging from it (AnkleBiter)
            w = 0.5

            def grin(x):
                return my + 0.1 * ((x / w) ** 2) - 0.04

            xs = [-w, -w * 0.5, 0.0, w * 0.5, w]
            out.append(line(xs, [grin(x) - my for x in xs]))
            mo = 0.4
            out.append(_plate(fp, [_lerp(-mo, mo, i / 10) for i in range(11)], grin,
                              lambda u: grin(u) - 0.12 * math.sqrt(max(1 - (u / mo) ** 2, 0.0)),
                              0.006, c.body_deep, name="mouthin"))
            for fx in (-0.3 * dd, 0.26 * dd):
                z0 = grin(fx) - INK * 0.7

                def fang(g, fx=fx, z0=z0):
                    fw, fl = 0.1 + g, 0.29 + 1.7 * g
                    return (fx - fw, fx + fw, (lambda u: z0 + g * 0.6),
                            (lambda u: z0 - fl * (1 - min(abs(u - fx) / fw, 1.0) ** 1.3)))
                out += _inked(fp, fang, K.WHITE, border=0.026, lift=0.03, n=9, name="fang")
        elif mood == "flat":
            out.append(line([-0.18, 0.0, 0.18], [0.0, 0.0, 0.0]))
        elif mood == "gross":
            out.append(line([-0.22, -0.11, 0.0, 0.11, 0.22], [-0.025, 0.035, -0.025, 0.035, -0.015]))
            tx = 0.07 * dd

            def tongue(g):
                tw, tl = 0.075 + g, 0.16 + g
                return (tx - tw, tx + tw, (lambda u: my - 0.01 + g * 0.5),
                        (lambda u: my - 0.01 - tl * max(1 - abs((u - tx) / tw) ** 3, 0.0) ** 0.5))
            out += _inked(fp, tongue, C_TONGUE, border=0.03, n=9, name="tongue")
    # brows: short, thick brush strokes over each eye (tapered ends), riding over the eyes
    if mood in ("sad", "stress", "tired", "brave", "shock"):
        for i, s in enumerate((-1, 1)):
            ctr = Vector(eyes[i])
            bx = ctr.x
            top = ctr.z + eye_r
            if mood in ("sad", "stress"):
                # worried: outer end low on the rim, inner end raised, a soft arch (the sheet's Tubolino)
                pts = [(bx + s * 0.29, top - 0.01), (bx + s * 0.12, top + 0.09), (bx - s * 0.02, top + 0.15),
                       (bx - s * 0.13, top + 0.18)]
            elif mood == "tired":
                pts = [(bx + s * 0.24, top + 0.04), (bx, top + 0.085), (bx - s * 0.2, top + 0.06)]
            elif mood == "brave":
                pts = [(bx + s * 0.24, top + 0.15), (bx, top + 0.09), (bx - s * 0.2, top + 0.01)]
            else:  # shock: high, round
                pts = [(bx + s * 0.23, top + 0.13), (bx, top + 0.21), (bx - s * 0.21, top + 0.14)]
            hits = [fp(x, z, 0.012) for x, z in pts]
            out.append(_ink([p for p, _n in hits], [n for _p, n in hits], 0.05, taper=0.45, name="brow"))
    # heavy lids: a body-coloured cap over the top of each eye with an ink line along its edge
    if mood == "tired":
        lid_ax = Vector((0.0, 0.8, 0.6)).normalized()
        ang = math.radians(62)
        e1 = Vector((1.0, 0.0, 0.0))
        e2 = lid_ax.cross(e1).normalized()
        for T, wrap in zip(mats, wraps):
            lid = _cap(c.body, lid_ax, ang, T, lift=0.036, seg=14, rings=3, name="lid")  # over the glint
            Tn = T.to_3x3().inverted().transposed()
            pts, nrms = [], []
            for k in range(5):
                ph = math.pi * (1.0 + k / 4)          # the lower half of the lid's edge circle
                q = lid_ax * math.cos(ang) + (e1 * math.cos(ph) + e2 * math.sin(ph)) * math.sin(ang)
                nn = (Tn @ q).normalized()
                pts.append(T @ q + nn * 0.04)
                nrms.append(nn)
            lids = [lid, _ink(pts, nrms, 0.03, samples=3, name="lidline")]
            _wrap_pieces(lids, wrap)
            out += lids
    return out


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


CTX: dict[str, SockCtx] = {}  # sock name -> the SockCtx it was built from (rigging.py places bones with it)


def build_sock(tid: str, side: str):
    spec = spec_for(tid)
    c = SockCtx(tid, spec, side)
    pieces = body_pieces(c)
    n_body = len(pieces)
    pieces += face_pieces(c)
    c.face_range = (n_body, len(pieces))   # piece indices of the shared face (eyes, mouth, brows)
    pieces += feature_module(tid).FEATURES[tid](c)
    name = tid if side == "S" else f"{tid}_{side}"
    CTX[name] = c
    body, outline = K.finish(pieces, name, outline_width=0.06)
    # features may move the floor point (c.base_z: Sockhopper's pogo tip stands on the floor) or
    # the clothespin grip (c.pin_z: above Sockington's helm); the game reads both from the markers
    base_z = getattr(c, "base_z", 0.0)
    pin_z = getattr(c, "pin_z", c.h + 0.1)
    return [body, outline] + K.markers(name, pin=(0, 0, pin_z), base_z=base_z)
