"""Builds the "Brit" rose-gold charm necklace as a Roblox UGC neck accessory.
Outputs: BritNecklace.obj, BritNecklace.mtl, BritNecklace_texture.png, preview.png
Units are studs. Origin = neck attachment point. Front of avatar = -Z, up = +Y.
Run: python3 build_necklace.py [NAME]
"""
import math, sys, os
import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageFilter

NAME = sys.argv[1] if len(sys.argv) > 1 else "Brit"
OUT = os.path.dirname(os.path.abspath(__file__))
FONT = "/usr/share/fonts/opentype/inter/Inter-ExtraBold.otf"
TEX = 512

verts, uvs, faces = [], [], []   # faces: list of (vi,ti) triples

# ---- UV regions in the atlas (u0,v0,u1,v1), v measured from bottom ----
R_GOLD_FACE = (0.00, 0.50, 0.50, 1.00)
R_GOLD_SIDE = (0.00, 0.00, 0.50, 0.50)
R_PINK_FACE = (0.50, 0.50, 1.00, 1.00)
R_PINK_SIDE = (0.50, 0.00, 1.00, 0.50)

def add_tri(p, t):
    base_v, base_t = len(verts), len(uvs)
    verts.extend(p); uvs.extend(t)
    faces.append([(base_v + i + 1, base_t + i + 1) for i in range(3)])

def reg(r, a, b):
    a = min(max(a, 0.02), 0.98); b = min(max(b, 0.02), 0.98)
    return (r[0] + (r[2] - r[0]) * a, r[1] + (r[3] - r[1]) * b)

# ---------------- extrude a 2D bitmap into a solid ----------------
def greedy_rects(m):
    m = m.copy(); h, w = m.shape; out = []
    for y in range(h):
        x = 0
        while x < w:
            if not m[y, x]: x += 1; continue
            x1 = x
            while x1 < w and m[y, x1]: x1 += 1
            y1 = y + 1
            while y1 < h and m[y1, x:x1].all(): y1 += 1
            m[y:y1, x:x1] = False
            out.append((x, y, x1, y1)); x = x1
    return out

def extrude(mask, px, depth, xform, face_r, side_r):
    """mask[row, col] bool, row 0 = top. xform maps local (x,y,z)->world."""
    h, w = mask.shape
    def L(cx, cy, z):  # pixel corner -> local, centered
        return ((cx - w / 2) * px, (h / 2 - cy) * px, z)
    zf, zb = -depth / 2, depth / 2  # front is -Z
    for (x0, y0, x1, y1) in greedy_rects(mask):
        q = [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]
        uv = [reg(face_r, cx / w, 1 - cy / h) for cx, cy in q]
        F = [xform(*L(cx, cy, zf)) for cx, cy in q]
        B = [xform(*L(cx, cy, zb)) for cx, cy in q]
        # front (facing -Z): order so normal points -Z
        add_tri([F[0], F[1], F[2]], [uv[0], uv[1], uv[2]])
        add_tri([F[0], F[2], F[3]], [uv[0], uv[2], uv[3]])
        add_tri([B[0], B[2], B[1]], [uv[0], uv[2], uv[1]])
        add_tri([B[0], B[3], B[2]], [uv[0], uv[3], uv[2]])
    pad = np.pad(mask, 1)
    def wall(a, b):  # a,b pixel corners, wall from front to back
        s = (a[0] / w + a[1] / h) % 1
        t = [reg(side_r, s, 0.1), reg(side_r, s + 0.05, 0.1), reg(side_r, s + 0.05, 0.9), reg(side_r, s, 0.9)]
        P = [xform(*L(*a, zf)), xform(*L(*b, zf)), xform(*L(*b, zb)), xform(*L(*a, zb))]
        add_tri([P[0], P[1], P[2]], [t[0], t[1], t[2]])
        add_tri([P[0], P[2], P[3]], [t[0], t[2], t[3]])
    # horizontal edges (merged runs)
    for y in range(h + 1):
        for side in (0, 1):
            x = 0
            while x < w:
                up, dn = pad[y, x + 1], pad[y + 1, x + 1]
                edge = (dn and not up) if side == 0 else (up and not dn)
                if not edge: x += 1; continue
                x1 = x
                while x1 < w and ((pad[y + 1, x1 + 1] and not pad[y, x1 + 1]) if side == 0 else (pad[y, x1 + 1] and not pad[y + 1, x1 + 1])):
                    x1 += 1
                if side == 0: wall((x1, y), (x, y))   # top edge
                else: wall((x, y), (x1, y))           # bottom edge
                x = x1
    for x in range(w + 1):
        for side in (0, 1):
            y = 0
            while y < h:
                lf, rt = pad[y + 1, x], pad[y + 1, x + 1]
                edge = (rt and not lf) if side == 0 else (lf and not rt)
                if not edge: y += 1; continue
                y1 = y
                while y1 < h and ((pad[y1 + 1, x + 1] and not pad[y1 + 1, x]) if side == 0 else (pad[y1 + 1, x] and not pad[y1 + 1, x + 1])):
                    y1 += 1
                if side == 0: wall((x, y), (x, y1))   # left edge
                else: wall((x, y1), (x, y))           # right edge
                y = y1

# ---------------- low-poly bead ----------------
def bead(c, r, region):
    lat, lon = 4, 6
    pts = [[(c[0] + r * math.sin(math.pi * i / lat) * math.cos(2 * math.pi * j / lon),
             c[1] + r * math.cos(math.pi * i / lat),
             c[2] + r * math.sin(math.pi * i / lat) * math.sin(2 * math.pi * j / lon))
            for j in range(lon + 1)] for i in range(lat + 1)]
    tx = lambda i, j: reg(region, j / lon, 1 - i / lat)
    for i in range(lat):
        for j in range(lon):
            a, b, cc, d = pts[i][j], pts[i][j + 1], pts[i + 1][j + 1], pts[i + 1][j]
            ta, tb, tc, td = tx(i, j), tx(i, j + 1), tx(i + 1, j + 1), tx(i + 1, j)
            if i != 0: add_tri([a, cc, b], [ta, tc, tb])
            if i != lat - 1: add_tri([a, d, cc], [ta, td, tc])

# ---------------- 2D masks ----------------
def text_mask(text, h_px=26):
    f = ImageFont.truetype(FONT, int(h_px * 1.35))
    bb = f.getbbox(text)
    W, H = bb[2] - bb[0] + 8, bb[3] - bb[1] + 6
    im = Image.new("L", (W, H), 0); d = ImageDraw.Draw(im)
    d.text((4 - bb[0], 3 - bb[1]), text, font=f, fill=255)
    return np.array(im) > 128

def plate_mask(tm, pad=2):
    # pink rounded backing plate so the letters (and the dot on the i) are one solid piece
    h, w = tm.shape
    im = Image.new("L", (w + 2 * pad, h + 2 * pad), 0); d = ImageDraw.Draw(im)
    d.rounded_rectangle((0, 0, w + 2 * pad - 1, h + 2 * pad - 1), radius=(h + 2 * pad) // 3, fill=255)
    return np.array(im) > 128

def heart_mask(s=22):
    im = Image.new("L", (s, s), 0); d = ImageDraw.Draw(im)
    r = s * 0.27
    d.ellipse((s * 0.06, s * 0.1, s * 0.06 + 2 * r, s * 0.1 + 2 * r), fill=255)
    d.ellipse((s * 0.94 - 2 * r, s * 0.1, s * 0.94, s * 0.1 + 2 * r), fill=255)
    d.polygon([(s * 0.08, s * 0.42), (s * 0.92, s * 0.42), (s * 0.5, s * 0.95)], fill=255)
    return np.array(im) > 128

def paw_mask(s=22):
    im = Image.new("L", (s, s), 0); d = ImageDraw.Draw(im)
    d.ellipse((s * 0.22, s * 0.45, s * 0.78, s * 0.95), fill=255)          # main pad
    for cx, cy, r in [(0.15, 0.40, 0.11), (0.37, 0.18, 0.12), (0.63, 0.18, 0.12), (0.85, 0.40, 0.11)]:
        d.ellipse((s * (cx - r), s * (cy - r), s * (cx + r), s * (cy + r)), fill=255)
    m = np.array(im) > 128
    # thin bridges so toes stay attached to the pad (one solid charm)
    m[int(s * .3):int(s * .55), int(s * .2):int(s * .8)] |= False
    return m

def paw_with_frame(s=22):
    # paw cut out of a round pink disc reads much better at avatar size and stays one piece
    im = Image.new("L", (s, s), 0); d = ImageDraw.Draw(im)
    d.ellipse((0, 0, s - 1, s - 1), fill=255)
    disc = np.array(im) > 128
    return disc, paw_mask(s)

# ---------------- transforms ----------------
def make_xform(pos, tilt_x=0.0, yaw=0.0):
    cx, sx = math.cos(tilt_x), math.sin(tilt_x)
    cy, sy = math.cos(yaw), math.sin(yaw)
    def f(x, y, z):
        y, z = y * cx - z * sx, y * sx + z * cx          # tilt so it lies on the chest
        x, z = x * cy + z * sy, -x * sy + z * cy          # yaw around neck
        return (x + pos[0], y + pos[1], z + pos[2])
    return f

# ---------------- chain path ----------------
RX, RZ, DROOP, TOPY = 0.62, 0.48, 0.55, 0.0
def chain_pt(t):  # t=0 front center
    return (RX * math.sin(t), TOPY - DROOP * (1 + math.cos(t)) / 2 * (1 + math.cos(t)) / 2, -RZ * math.cos(t))

N_BEADS = 34
for k in range(N_BEADS):
    t = 2 * math.pi * k / N_BEADS
    if abs(((t + math.pi) % (2 * math.pi)) - math.pi) < 0.10: continue  # gap where nameplate bail sits
    bead(chain_pt(t), 0.045, R_GOLD_SIDE if k % 2 else R_GOLD_FACE)

TILT = math.radians(18)
# nameplate
front = chain_pt(0)
tm = text_mask(NAME)
px = 0.46 / tm.shape[1] if tm.shape[1] > 0 else 0.02
px = min(px, 0.011)
pm = plate_mask(tm)
plate_h = pm.shape[0] * px
ctr = (0, front[1] - plate_h / 2 - 0.01, front[2] - 0.02)
extrude(pm, px, 0.035, make_xform((ctr[0], ctr[1], ctr[2] + 0.01), TILT), R_PINK_FACE, R_PINK_SIDE)
extrude(tm, px, 0.03, make_xform((ctr[0], ctr[1] + 0.003, ctr[2] - 0.025), TILT), R_GOLD_FACE, R_GOLD_SIDE)
bead((0, front[1] + 0.005, front[2] - 0.02), 0.05, R_GOLD_FACE)  # bail

# charms: heart, paw, (name), paw, heart
disc, paw = paw_with_frame()
for t, kind in [(-0.95, "heart"), (-0.55, "paw"), (0.55, "paw"), (0.95, "heart")]:
    p = chain_pt(t); yaw = -t * 0.9
    size = 0.17
    if kind == "heart":
        m = heart_mask(); q = size / m.shape[1]
        extrude(m, q, 0.05, make_xform((p[0], p[1] - size / 2 - 0.04, p[2] - 0.01), TILT, yaw), R_PINK_FACE, R_PINK_SIDE)
    else:
        q = size / disc.shape[1]
        extrude(disc, q, 0.03, make_xform((p[0], p[1] - size / 2 - 0.04, p[2] + 0.005), TILT, yaw), R_GOLD_FACE, R_GOLD_SIDE)
        extrude(paw, q, 0.03, make_xform((p[0], p[1] - size / 2 - 0.04, p[2] - 0.022), TILT, yaw), R_PINK_FACE, R_PINK_SIDE)
    bead((p[0], p[1] - 0.02, p[2]), 0.035, R_GOLD_FACE)  # jump ring

# ---------------- write OBJ/MTL ----------------
with open(os.path.join(OUT, "BritNecklace.mtl"), "w") as f:
    f.write("newmtl Necklace\nKd 1 1 1\nmap_Kd BritNecklace_texture.png\n")
with open(os.path.join(OUT, "BritNecklace.obj"), "w") as f:
    f.write(f"# {NAME} rose gold charm necklace - neck accessory, units = studs\nmtllib BritNecklace.mtl\no BritNecklace\n")
    for v in verts: f.write("v %.5f %.5f %.5f\n" % v)
    for t in uvs: f.write("vt %.5f %.5f\n" % t)
    f.write("usemtl Necklace\n")
    for fc in faces: f.write("f " + " ".join(f"{a}/{b}" for a, b in fc) + "\n")

# ---------------- texture: rose gold + pink with baked shine & sparkles ----------------
rng = np.random.default_rng(7)
yy, xx = np.mgrid[0:TEX // 2, 0:TEX // 2] / (TEX // 2)
def metal(base, hi, lo, shine=True):
    g = 0.5 + 0.5 * np.sin((xx + yy) * 9.0)
    band = np.exp(-((xx - yy - 0.1) ** 2) / 0.01) if shine else 0
    c = lo + (base - lo) * g[..., None] + (hi - base) * (np.clip(band, 0, 1)[..., None] * 0.9)
    return np.clip(c, 0, 255).astype(np.uint8)
RG, RGH, RGL = np.array([225, 158, 138.]), np.array([255, 232, 220.]), np.array([168, 100, 88.])
PK, PKH, PKL = np.array([255, 128, 178.]), np.array([255, 225, 240.]), np.array([205, 70, 130.])
atlas = np.zeros((TEX, TEX, 3), np.uint8)
atlas[:TEX // 2, :TEX // 2] = metal(RG, RGH, RGL)           # top-left = gold face (v 0.5-1)
atlas[TEX // 2:, :TEX // 2] = metal(RG * .85, RGH * .9, RGL * .8, False)  # gold sides
atlas[:TEX // 2, TEX // 2:] = metal(PK, PKH, PKL)
atlas[TEX // 2:, TEX // 2:] = metal(PK * .88, PKH * .9, PKL * .85, False)
img = Image.fromarray(atlas); d = ImageDraw.Draw(img)
def sparkle(x, y, r):
    d.polygon([(x, y - r), (x + r * .22, y), (x, y + r), (x - r * .22, y)], fill=(255, 255, 255))
    d.polygon([(x - r, y), (x, y + r * .22), (x + r, y), (x, y - r * .22)], fill=(255, 255, 255))
for _ in range(60):
    x, y = rng.integers(8, TEX - 8), rng.integers(8, TEX - 8)
    sparkle(x, y, int(rng.integers(3, 9)))
glow = img.filter(ImageFilter.GaussianBlur(2))
img = Image.blend(img, glow, 0.25)
img.save(os.path.join(OUT, "BritNecklace_texture.png"))

# ---------------- preview render (simple flat-shaded rasterizer) ----------------
tex = np.array(img)
W = H = 900; S = 520
canvas = Image.new("RGB", (W, H), (34, 30, 44)); cd = ImageDraw.Draw(canvas)
# neck/shoulder silhouette for context
cd.ellipse((W/2 - 0.55*S, H/2 - 0.75*S, W/2 + 0.55*S, H/2 + 0.05*S), fill=(70, 62, 86))
cd.rectangle((W/2 - 0.42*S, H/2 - 0.9*S, W/2 + 0.42*S, H/2 - 0.3*S), fill=(70, 62, 86))
light = np.array([0.3, 0.6, -0.75]); light /= np.linalg.norm(light)
V = np.array(verts); T = np.array(uvs)
def view(p):  # slight top-down 3/4 view from the front (-Z)
    x, y, z = p; a = math.radians(-12)
    y, z = y * math.cos(a) - z * math.sin(a), y * math.sin(a) + z * math.cos(a)
    return x, y, z
tris = []
for fc in faces:
    P = [view(V[a - 1]) for a, _ in fc]
    n = np.cross(np.subtract(P[1], P[0]), np.subtract(P[2], P[0]))
    if n[2] > 0: continue  # back-facing (camera looks +Z)
    nn = n / (np.linalg.norm(n) + 1e-9)
    uv = np.mean([T[b - 1] for _, b in fc], axis=0)
    col = tex[int((1 - uv[1]) * (TEX - 1)), int(uv[0] * (TEX - 1))].astype(float)
    sh = 0.45 + 0.75 * max(0, -np.dot(nn, -light * np.array([1, 1, 1])) * -1 if False else max(0, np.dot(-nn, -light)))
    tris.append((np.mean([q[2] for q in P]), [(W/2 + q[0]*S, H/2 - (q[1]+0.3)*S) for q in P], tuple(np.clip(col*sh, 0, 255).astype(int))))
for _, pts, c in sorted(tris, key=lambda t: -t[0]):
    cd.polygon(pts, fill=c)
canvas.save(os.path.join(OUT, "preview.png"))
print(f"vertices={len(verts)} triangles={len(faces)}")
