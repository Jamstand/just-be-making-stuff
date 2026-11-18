"""Builds the "Brit" rose-gold charm necklace as a Roblox UGC neck accessory.
Outputs: BritNecklace.obj/.mtl, BritNecklace_texture.png
Units = studs. Origin = neck attachment point. Avatar front = -Z, up = +Y.
Needs: pip install numpy pillow shapely fonttools mapbox_earcut
Run:   python3 build_necklace.py [NAME]
"""
import math, sys, os
import numpy as np
import mapbox_earcut as earcut
from PIL import Image, ImageDraw, ImageFilter
from shapely.geometry import Polygon, Point, MultiPolygon, box
from shapely.ops import unary_union
from shapely import affinity
from fontTools.ttLib import TTFont
from fontTools.pens.basePen import BasePen

NAME = sys.argv[1] if len(sys.argv) > 1 else "Brit"
OUT = os.path.dirname(os.path.abspath(__file__))
FONT = "/usr/share/fonts/opentype/inter/Inter-ExtraBold.otf"
TEX = 512

V, VT, VN, F = [], [], [], []

R_GOLD_FACE = (0.00, 0.50, 0.50, 1.00)
R_GOLD_SIDE = (0.00, 0.00, 0.50, 0.50)
R_PINK_FACE = (0.50, 0.50, 1.00, 1.00)
R_PINK_SIDE = (0.50, 0.00, 1.00, 0.50)

def reg(r, a, b):
    a = min(max(a, .02), .98); b = min(max(b, .02), .98)
    return (r[0] + (r[2] - r[0]) * a, r[1] + (r[3] - r[1]) * b)

def tri(ps, ts, ns):
    bv, bt, bn = len(V), len(VT), len(VN)
    V.extend(ps); VT.extend(ts); VN.extend(ns)
    F.append([(bv + i + 1, bt + i + 1, bn + i + 1) for i in range(3)])

def unit(v):
    v = np.asarray(v, float); return v / (np.linalg.norm(v) + 1e-12)

# ---------------- transforms ----------------
class X:
    def __init__(self, pos, tilt=0.0, yaw=0.0):
        cx, sx, cy, sy = math.cos(tilt), math.sin(tilt), math.cos(yaw), math.sin(yaw)
        Rx = np.array([[1, 0, 0], [0, cx, -sx], [0, sx, cx]])
        Ry = np.array([[cy, 0, sy], [0, 1, 0], [-sy, 0, cy]])
        self.R = Ry @ Rx; self.p = np.array(pos, float)
    def pt(self, p): return tuple(self.R @ np.array(p, float) + self.p)
    def n(self, n): return tuple(unit(self.R @ np.array(n, float)))

# ---------------- polygon extrusion with rounded (beveled) edge ----------------
def rings(poly):
    return [np.array(poly.exterior.coords)[:-1]] + [np.array(i.coords)[:-1] for i in poly.interiors]

def ccw(r):
    a = 0.5 * np.sum(r[:, 0] * np.roll(r[:, 1], -1) - np.roll(r[:, 0], -1) * r[:, 1])
    return a > 0

def extrude(shape, depth, xf, face_r, side_r, bevel=0.0):
    polys = list(shape.geoms) if isinstance(shape, MultiPolygon) else [shape]
    minx, miny, maxx, maxy = shape.bounds
    sw, sh = maxx - minx or 1, maxy - miny or 1
    uvf = lambda x, y: reg(face_r, (x - minx) / sw, (y - miny) / sh)
    for poly in polys:
        inner = poly.buffer(-bevel, join_style=1) if bevel > 0 else poly
        if inner.is_empty: inner = poly; bevel_here = 0
        else: bevel_here = bevel
        inner_polys = list(inner.geoms) if isinstance(inner, MultiPolygon) else [inner]
        # flat front (-Z) and back (+Z) caps on the inset shape
        zf, zb = -depth / 2, depth / 2
        for ip in inner_polys:
            rs = rings(ip)
            pts = np.vstack(rs).astype(np.float64)
            ends = np.cumsum([len(r) for r in rs]).astype(np.uint32)
            idx = earcut.triangulate_float64(pts, ends).reshape(-1, 3)
            for a, b, c in idx:
                P = [pts[a], pts[b], pts[c]]
                cross = (P[1][0]-P[0][0])*(P[2][1]-P[0][1]) - (P[1][1]-P[0][1])*(P[2][0]-P[0][0])
                if cross > 0: P = [P[0], P[2], P[1]]   # make clockwise in xy => faces -Z
                tri([xf.pt((p[0], p[1], zf)) for p in P], [uvf(*p) for p in P], [xf.n((0, 0, -1))] * 3)
                Q = P[::-1]
                tri([xf.pt((p[0], p[1], zb)) for p in Q], [uvf(*p) for p in Q], [xf.n((0, 0, 1))] * 3)
        # side walls: rounded profile from inset front edge -> outer edge -> inset back edge
        prof = [(-depth/2, 0.0), (-depth/2 + bevel_here, 1.0), (depth/2 - bevel_here, 1.0), (depth/2, 0.0)] \
            if bevel_here > 0 else [(-depth/2, 1.0), (depth/2, 1.0)]
        for r_out in rings(poly):
            if not ccw(r_out) == (r_out is rings(poly)[0] and True or ccw(r_out)): pass
            n = len(r_out)
            # outward 2D normals per vertex (averaged)
            orient = 1 if ccw(r_out) else -1
            en = []
            for i in range(n):
                d = r_out[(i+1) % n] - r_out[i]
                en.append(unit((d[1]*orient, -d[0]*orient)))
            vn2 = [unit(en[i-1] + en[i]) for i in range(n)]
            s_len = np.concatenate([[0], np.cumsum(np.linalg.norm(np.diff(np.vstack([r_out, r_out[:1]]), axis=0), axis=1))])
            for i in range(n):
                j = (i + 1) % n
                # sharp corner -> split normals
                sharp_i = np.dot(en[i-1], en[i]) < 0.5
                sharp_j = np.dot(en[i], en[(i+1) % n]) < 0.5
                ni = en[i] if sharp_i else vn2[i]
                nj = en[i] if sharp_j else vn2[j]
                for k in range(len(prof) - 1):
                    (z0, o0), (z1, o1) = prof[k], prof[k+1]
                    def P(base, nn, z, o):
                        q = base + nn * (o - 1) * bevel_here
                        return (q[0], q[1], z)
                    def N(nn, z, o):
                        if bevel_here == 0: return (nn[0], nn[1], 0)
                        zz = z / (depth/2) * (1 - o) * 1.2
                        return tuple(unit((nn[0], nn[1], zz)))
                    a = (P(r_out[i], ni, z0, o0), N(ni, z0, o0))
                    b = (P(r_out[j], nj, z0, o0), N(nj, z0, o0))
                    c = (P(r_out[j], nj, z1, o1), N(nj, z1, o1))
                    d = (P(r_out[i], ni, z1, o1), N(ni, z1, o1))
                    su, sv = s_len[i] / (s_len[-1] or 1), s_len[i+1] / (s_len[-1] or 1)
                    ta, tb = reg(side_r, su, k/(len(prof)-1)), reg(side_r, sv, k/(len(prof)-1))
                    tc, td = reg(side_r, sv, (k+1)/(len(prof)-1)), reg(side_r, su, (k+1)/(len(prof)-1))
                    quad = [(a, ta), (b, tb), (c, tc), (d, td)]
                    # winding: outward = 2D normal; ensure triangle faces outward
                    p0, p1, p2 = np.array(a[0]), np.array(b[0]), np.array(c[0])
                    fn = np.cross(p1 - p0, p2 - p0)
                    if np.dot(fn, (ni[0]+nj[0], ni[1]+nj[1], 0)) < 0: quad = quad[::-1]
                    for t in ((0, 1, 2), (0, 2, 3)):
                        tri([xf.pt(quad[m][0][0]) for m in t], [quad[m][1] for m in t], [xf.n(quad[m][0][1]) for m in t])

# ---------------- smooth bead ----------------
def bead(c, r, region, lat=5, lon=8, squash=1.0):
    def p(i, j):
        th, ph = math.pi * i / lat, 2 * math.pi * j / lon
        n = (math.sin(th) * math.cos(ph), math.cos(th) * squash, math.sin(th) * math.sin(ph))
        return (c[0] + r * n[0], c[1] + r * n[1], c[2] + r * n[2]), tuple(unit(n)), reg(region, j / lon, 1 - i / lat)
    for i in range(lat):
        for j in range(lon):
            a, b, cc, d = p(i, j), p(i, j+1), p(i+1, j+1), p(i+1, j)
            if i != 0: tri([a[0], cc[0], b[0]], [a[2], cc[2], b[2]], [a[1], cc[1], b[1]])
            if i != lat - 1: tri([a[0], d[0], cc[0]], [a[2], d[2], cc[2]], [a[1], d[1], cc[1]])

# ---------------- shapes (vector, not pixels) ----------------
class FlatPen(BasePen):
    def __init__(self, gs, steps=3):
        super().__init__(gs); self.contours, self.cur, self.steps = [], [], steps
    def _moveTo(self, p): self.cur = [p]
    def _lineTo(self, p): self.cur.append(p)
    def _curveToOne(self, p1, p2, p3):
        p0 = self.cur[-1]
        for k in range(1, self.steps + 1):
            t = k / self.steps; u = 1 - t
            self.cur.append(tuple(u**3*np.array(p0) + 3*u*u*t*np.array(p1) + 3*u*t*t*np.array(p2) + t**3*np.array(p3)))
    def _qCurveToOne(self, p1, p2):
        p0 = self.cur[-1]
        for k in range(1, self.steps + 1):
            t = k / self.steps; u = 1 - t
            self.cur.append(tuple(u*u*np.array(p0) + 2*u*t*np.array(p1) + t*t*np.array(p2)))
    def _closePath(self):
        if len(self.cur) > 2: self.contours.append(self.cur)
        self.cur = []
    _endPath = _closePath

def text_shape(text):
    f = TTFont(FONT); gs = f.getGlyphSet(); cmap = f.getBestCmap(); hmtx = f["hmtx"]
    shapes, x = [], 0
    for ch in text:
        g = cmap[ord(ch)]; pen = FlatPen(gs); gs[g].draw(pen)
        s = Polygon()
        for c in pen.contours:
            s = s.symmetric_difference(Polygon(c).buffer(0))
        shapes.append(affinity.translate(s, x, 0)); x += hmtx[g][0] - 30  # slightly tight tracking
    return unary_union(shapes)

def heart_shape():
    r = 0.27
    return unary_union([Point(-0.22, 0.12).buffer(r, 6), Point(0.22, 0.12).buffer(r, 6),
                        Polygon([(-0.46, 0.02), (0.46, 0.02), (0, -0.48)])]).buffer(0.02, 8).buffer(-0.02, 8)

def paw_shape():
    pad = affinity.scale(Point(0, -0.12).buffer(0.25, 6), 1.05, 0.85)
    toes = [affinity.rotate(affinity.scale(Point(x, y).buffer(0.1, 4), 0.85, 1.1), a, origin=(x, y))
            for x, y, a in [(-0.33, 0.12, 25), (-0.13, 0.30, 8), (0.13, 0.30, -8), (0.33, 0.12, -25)]]
    return unary_union([pad] + toes)

def fit(shape, width=None, height=None):
    minx, miny, maxx, maxy = shape.bounds
    s = (width / (maxx - minx)) if width else (height / (maxy - miny))
    shape = affinity.translate(shape, -(minx + maxx) / 2, -(miny + maxy) / 2)
    return affinity.scale(shape, s, s, origin=(0, 0)).simplify(0.0025)

# ---------------- chain path ----------------
# Roblox torso: neck attachment sits on the top face, chest face is the plane z = -0.5.
# The chain lies on the shoulders behind/around the neck, then drapes down the chest in a U.
CHEST_Z = -0.535          # just in front of the chest face
U_W, U_D = 0.46, 0.50     # half-width and depth of the U on the chest
def u_pt(s):              # s in [-1, 1] across the chest; s=0 is the bottom (pendant)
    return (U_W * s, -U_D * (1 - s * s) ** 0.9, CHEST_Z)
path = [u_pt(-1 + 2 * i / 40) for i in range(41)]
path.append((U_W, 0.035, -0.49))                                  # over the top edge
a0 = math.asin(U_W / 0.56)
for i in range(31):                                               # around the back of the neck
    a = a0 + (2 * math.pi - 2 * a0) * i / 30
    path.append((0.56 * math.sin(a), 0.035, -0.06 - 0.40 * math.cos(a)))
path.append((-U_W, 0.035, -0.49))
path.append(path[0])
P = np.array(path)
seg = np.linalg.norm(np.diff(P, axis=0), axis=1); cum = np.concatenate([[0], np.cumsum(seg)])
def along(d):
    d %= cum[-1]; i = min(np.searchsorted(cum, d) - 1, len(seg) - 1); i = max(i, 0)
    f = (d - cum[i]) / seg[i]; return tuple(P[i] * (1 - f) + P[i + 1] * f)
bottom_d = cum[20]
SPACING = 0.085
nb = int(cum[-1] / SPACING)
for k in range(nb):
    d = bottom_d + (k + 0.5) * cum[-1] / nb
    pt = along(d)
    if abs(pt[0]) < 0.035 and pt[1] < -0.4: continue              # gap for the pendant bail
    on_chest = pt[2] < -0.52
    if k % 2 == 0: bead(pt, 0.036, R_GOLD_FACE, lat=4, lon=7 if on_chest else 5)
    else:          bead(pt, 0.022, R_GOLD_FACE, lat=3, lon=5)

front = u_pt(0)

# name plate: pink pill with raised rose gold letters (mirrored in X so it reads correctly from the front)
txt = affinity.scale(fit(text_shape(NAME), width=0.40), -1, 1, origin=(0, 0))
tb = txt.bounds
pw, ph = (tb[2] - tb[0]) + 0.09, (tb[3] - tb[1]) + 0.07
plate = box(-pw/2, -ph/2, pw/2, ph/2).buffer(-ph*0.45).buffer(ph*0.45, 6)
cy = front[1] - ph / 2 - 0.03
extrude(plate, 0.035, X((0, cy, CHEST_Z - 0.005)), R_PINK_FACE, R_PINK_SIDE, bevel=0.008)
extrude(txt, 0.025, X((0, cy, CHEST_Z - 0.03)), R_GOLD_FACE, R_GOLD_SIDE, bevel=0.004)
bead((0, front[1] - 0.01, CHEST_Z - 0.01), 0.028, R_GOLD_FACE, lat=4, lon=6, squash=1.4)   # bail

# charms hang straight down on the chest
heart = fit(heart_shape(), width=0.15)
paw = fit(paw_shape(), width=0.105)
disc = Point(0, 0).buffer(0.075, 8)
for s_, kind in [(-0.86, "heart"), (-0.58, "paw"), (0.58, "paw"), (0.86, "heart")]:
    p = u_pt(s_); hang = 0.09
    if kind == "heart":
        extrude(heart, 0.04, X((p[0], p[1] - hang, CHEST_Z - 0.01)), R_PINK_FACE, R_PINK_SIDE, bevel=0.01)
    else:
        extrude(disc, 0.022, X((p[0], p[1] - hang, CHEST_Z - 0.005)), R_GOLD_FACE, R_GOLD_SIDE, bevel=0.005)
        extrude(paw, 0.016, X((p[0], p[1] - hang, CHEST_Z - 0.024)), R_PINK_FACE, R_PINK_SIDE)
    bead((p[0], p[1] - 0.012, CHEST_Z - 0.008), 0.02, R_GOLD_FACE, lat=3, lon=5, squash=1.3)  # jump ring

# ---------------- write OBJ/MTL ----------------
with open(os.path.join(OUT, "BritNecklace.mtl"), "w") as f:
    f.write("newmtl Necklace\nKd 1 1 1\nmap_Kd BritNecklace_texture.png\n")
with open(os.path.join(OUT, "BritNecklace.obj"), "w") as f:
    f.write(f"# {NAME} rose gold charm necklace - Roblox neck accessory, units = studs, front = -Z\n")
    f.write("mtllib BritNecklace.mtl\no BritNecklace\n")
    for v in V: f.write("v %.5f %.5f %.5f\n" % v)
    for t in VT: f.write("vt %.5f %.5f\n" % t)
    for n in VN: f.write("vn %.4f %.4f %.4f\n" % n)
    f.write("usemtl Necklace\ns 1\n")
    for fc in F: f.write("f " + " ".join(f"{a}/{b}/{c}" for a, b, c in fc) + "\n")

# ---------------- texture ----------------
rng = np.random.default_rng(7)
half = TEX // 2
yy, xx = np.mgrid[0:half, 0:half] / half
def metal(base, hi, lo, streak=True):
    g = 0.82 + 0.18 * np.sin((xx * 0.7 + yy) * 7.0)
    c = lo + (base - lo) * g[..., None]
    if streak:
        band = np.exp(-((xx - yy - 0.15) ** 2) / 0.006) + 0.5 * np.exp(-((xx - yy + 0.35) ** 2) / 0.002)
        c = c + (hi - c) * np.clip(band, 0, 1)[..., None] * 0.85
    return np.clip(c, 0, 255).astype(np.uint8)
RG, RGH, RGL = np.array([232, 168, 148.]), np.array([255, 236, 226.]), np.array([176, 108, 94.])
PK, PKH, PKL = np.array([255, 138, 186.]), np.array([255, 228, 242.]), np.array([214, 82, 142.])
atlas = np.zeros((TEX, TEX, 3), np.uint8)
atlas[:half, :half] = metal(RG, RGH, RGL)
atlas[half:, :half] = metal(RG * .9, RGH * .92, RGL * .85, False)
atlas[:half, half:] = metal(PK, PKH, PKL)
atlas[half:, half:] = metal(PK * .92, PKH * .92, PKL * .9, False)
img = Image.fromarray(atlas)
spark = Image.new("RGBA", img.size, (0, 0, 0, 0)); d = ImageDraw.Draw(spark)
def sparkle(x, y, r):
    for (w, a) in ((1.0, 255),):
        d.polygon([(x, y - r), (x + r * .18, y), (x, y + r), (x - r * .18, y)], fill=(255, 255, 255, a))
        d.polygon([(x - r, y), (x, y + r * .18), (x + r, y), (x, y - r * .18)], fill=(255, 255, 255, a))
    d.ellipse((x - r * .25, y - r * .25, x + r * .25, y + r * .25), fill=(255, 255, 255, 255))
for _ in range(45):
    x, y = rng.integers(10, TEX - 10), rng.integers(10, half - 10)   # sparkles only on the faces
    sparkle(int(x), int(y), int(rng.integers(4, 10)))
glow = spark.filter(ImageFilter.GaussianBlur(3))
img = Image.alpha_composite(Image.alpha_composite(img.convert("RGBA"), glow), spark).convert("RGB")
img.save(os.path.join(OUT, "BritNecklace_texture.png"))
print(f"triangles={len(F)} vertices={len(V)}")
