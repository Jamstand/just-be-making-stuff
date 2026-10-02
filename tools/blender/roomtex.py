"""
roomtex.py - paints the hand-painted textures of the bedroom shell (props/roomshell.py): numpy only,
no Blender needed. Cartoon style - clean shapes, soft painted gradients, no photo noise - in the
palette of docs/concept/bedroom_keyframe.png and Map.luau's C table.

    python tools/blender/roomtex.py            (from the repo root: rewrites the five textures)
    python tools/blender/roomtex.py OUT_DIR    (paints somewhere else, e.g. to compare)

Textures (1024 x 1024 each, written as JPEG to assets/textures/steal-a-sock/, which roomshell.py
embeds in RoomShell.glb):
    RoomFloor.jpg    warm wood planks, 4 boards per tile (40 studs each, like Map's Part planks), seams,
                     end joints with nail dots, grain lines and a few knots          tile = 160 studs
    RoomWalls.jpg    starry-night wallpaper: night-blue paper, two soft darker stripes with pinstripes,
                     small cream stars, crescent moons and twinkles (a half-drop print) tile = 100 studs
    RoomCeiling.jpg  soft mottled dusky-purple plaster with faint trowel swirls       tile = 220 studs
    RoomTrim.jpg     cream-painted wood: the top half is the baseboard's profile, the bottom half the
                     crown moulding's (shading baked per profile band), repeating along the length
                                                                                     tile = 40 studs long
    PlayRug.jpg      an atlas, not a tile: two cream and two coral knitted 20-stud checker cells, the
                     dark-red bound border (knit, a cream running stitch, a twisted-cord roll) and its
                     corner piece; roomshell.py maps every cell and border piece onto its slot

Every tile is seamless (each shape is drawn wrapped round the tile edges; noise is periodic); the
rug atlas pads every slot with 24 px of the same pattern so mip-mapping never bleeds a neighbour in.
"""
import math
import os
import sys

import numpy as np

SIZE = 1024
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
OUT_DIR = os.path.join(REPO, "assets", "textures", "steal-a-sock")
JPEG_QUALITY = 90

# studs per texture repeat (UV 1.0 = this many studs) - roomshell.py maps its UVs with these
FLOOR_TILE = 160.0  # 4 boards of 40 studs
WALL_TILE = 100.0   # divides both wall lengths (1100, 900) and the height (400)
CEIL_TILE = 220.0
TRIM_TILE = 40.0    # along the trim; across, each profile has its own band of the image

# ---------------------------------------------------------------- rug atlas layout (pixels; row 0 = top)
RUG_PPS = 20                 # pixels per stud
RUG_CELL = 20                # studs per checker cell (Map LAYOUT.Tile)
RUG_PAD = 24                 # pattern continued round every slot
RUG_SLOT = RUG_CELL * RUG_PPS + 2 * RUG_PAD   # 448
RUG_CELLS = {"creamA": (0, 0), "coralA": (RUG_SLOT, 0), "creamB": (0, RUG_SLOT), "coralB": (RUG_SLOT, RUG_SLOT)}
RUG_BORDER = 4.0             # border depth (studs): Map's RugEdge is 8 bigger than the rug
RUG_FLAT = 2.8               # flat knitted band; the last 1.2 studs roll down to the floor (the cord)
RUG_STITCH_AT = 1.4          # the cream running stitch, studs from the checker
# straight border piece (20 studs long x 4 deep): x = depth, rows = length
RUG_STRIP = (2 * RUG_SLOT + RUG_PAD, RUG_PAD)                 # top-left of the content (x, row)
# corner piece (4 x 4 studs): x = depth across one side, rows = depth across the other
RUG_CORNER = (RUG_PAD, 2 * RUG_SLOT + RUG_PAD)

# colours (Map.luau C / docs/concept palette)
PLANK1 = (176, 118, 68)
PLANK2 = (190, 130, 78)
WALL = (80, 68, 130)
WALL_STRIPE = (71, 59, 118)
CEILING = (58, 50, 104)
CREAM_PAINT = (242, 230, 205)
RUG_A = (245, 231, 206)
RUG_B = (227, 154, 136)
RUG_EDGE = (150, 84, 70)
STAR_CREAM = (246, 232, 188)


# ---------------------------------------------------------------- trim profiles (shared with roomshell.py)
def _arc(cx, cy, r, a0, a1, n, ry=None):
    ry = r if ry is None else ry
    return [(cx + r * math.cos(math.radians(a0 + (a1 - a0) * i / n)),
             cy + ry * math.sin(math.radians(a0 + (a1 - a0) * i / n))) for i in range(n + 1)]


def baseboard_profile():
    """(depth from the wall, height, part) from the floor up to the wall: a 14-stud board with a
    rounded groove and a fat bullnose cap that bulges 2.8 studs out."""
    pts = [((2.4, 0.0), "face"), ((2.4, 9.1), "face")]
    pts += [(p, "groove") for p in _arc(2.4, 9.75, 0.65, -90, -270, 8)[1:]]           # rounded groove
    pts += [(p, "cap") for p in _arc(2.4, 11.8, 0.4, -90, 0, 4, ry=1.4)[1:]]          # cap: swells out
    pts += [(p, "cap") for p in _arc(0.0, 11.8, 2.8, 0, 90, 10, ry=2.2)[1:]]          # and rolls over to the wall
    return [(p[0], p[1], t) for p, t in pts]


def crown_profile(top=400.0):
    """(depth from the wall, height, part) from the wall out along the ceiling: a 10-stud crown - a
    rounded bead at the bottom, a deep cove and a rounded lip against the ceiling (7.2 studs out)."""
    b = top - 10.0
    pts = [((0.0, b), "bead")]
    pts += [(p, "bead") for p in _arc(0.0, b + 1.2, 1.3, -90, 0, 5, ry=1.2)[1:]]       # bead
    pts += [((1.3, b + 1.8), "bead"), ((0.9, b + 2.3), "cove")]
    pts += [(p, "cove") for p in _arc(6.6, b + 2.3, 5.7, 180, 90, 12, ry=6.1)[1:]]     # deep cove
    pts += [(p, "lip") for p in _arc(6.6, b + 9.0, 0.6, -90, 0, 4)[1:]]                # rounded lip
    pts += [((7.2, top), "lip")]
    return [(p[0], p[1], t) for p, t in pts]


def arclen(profile):
    s = [0.0]
    for (x0, y0, _), (x1, y1, _) in zip(profile, profile[1:]):
        s.append(s[-1] + math.hypot(x1 - x0, y1 - y0))
    return s


# trim atlas bands (rows, top to bottom): each profile's arc length is stretched over its band
TRIM_BANDS = {"baseboard": (8, 504), "crown": (520, 1016)}


# ---------------------------------------------------------------- painting helpers
def _rgb(c):
    return np.array(c, dtype=np.float32) / 255.0


def canvas(color, h=SIZE, w=SIZE):
    img = np.empty((h, w, 3), np.float32)
    img[:] = _rgb(color)
    return img


def pnoise(rng, cutoff, size=SIZE, aniso=(1.0, 1.0)):
    """Smooth periodic noise (unit std): white noise low-passed in Fourier space. `cutoff` = cycles per
    tile; `aniso` stretches the spectrum (x, y)."""
    w = rng.standard_normal((size, size))
    f = np.fft.rfft2(w)
    fy = np.fft.fftfreq(size)[:, None] * size * aniso[1]
    fx = np.fft.rfftfreq(size)[None, :] * size * aniso[0]
    f *= np.exp(-(fx ** 2 + fy ** 2) / cutoff ** 2)
    f[0, 0] = 0
    n = np.fft.irfft2(f, s=(size, size))
    return (n / n.std()).astype(np.float32)


def blend(img, iy, ix, cov, color):
    """Blends `color` into img[iy][:, ix] by coverage `cov` (indices may wrap)."""
    sub = img[np.ix_(iy, ix)]
    c = cov[..., None]
    if callable(color):
        col = color(sub)
    else:
        col = _rgb(color) if not isinstance(color, np.ndarray) else color
    img[np.ix_(iy, ix)] = sub * (1 - c) + col * c


def _wrapped(img, ys, xs, cov, color):
    """blend() at indices wrapped round the image; a shape that overlaps itself across the seam (a
    full-height line) keeps the strongest coverage instead of whichever copy was written last."""
    h, w = img.shape[:2]
    uy, iy = np.unique(ys % h, return_inverse=True)
    ux, ix = np.unique(xs % w, return_inverse=True)
    if len(uy) == len(ys) and len(ux) == len(xs):
        blend(img, ys % h, xs % w, cov, color)
        return
    folded = np.zeros((len(uy), len(ux)), np.float32)
    np.maximum.at(folded, (iy[:, None], ix[None, :]), cov)
    blend(img, uy, ux, folded, color)


def stamp(img, cx, cy, rad, inside, color, alpha=1.0, ss=4, wrap=True):
    """Anti-aliased shape (ss x ss supersampled): `inside(X, Y)` -> bool, X/Y in pixels relative to
    (cx, cy), y down. Drawn wrapped round the image edges unless wrap=False (then clipped)."""
    h, w = img.shape[:2]
    x0, x1 = int(math.floor(cx - rad - 1)), int(math.ceil(cx + rad + 1))
    y0, y1 = int(math.floor(cy - rad - 1)), int(math.ceil(cy + rad + 1))
    xs, ys = np.arange(x0, x1), np.arange(y0, y1)
    o = (np.arange(ss) + 0.5) / ss
    X = (xs[None, :, None, None] + o[None, None, None, :]) - cx
    Y = (ys[:, None, None, None] + o[None, None, :, None]) - cy
    X, Y = np.broadcast_arrays(X, Y)
    cov = inside(X, Y).mean(axis=(2, 3)).astype(np.float32) * alpha
    if wrap:
        _wrapped(img, ys, xs, cov, color)
    else:
        my, mx = (ys >= 0) & (ys < h), (xs >= 0) & (xs < w)
        blend(img, ys[my], xs[mx], cov[np.ix_(my, mx)], color)


def polyline(img, pts, width, color, alpha=1.0, wrap=True, alphas=None):
    """Anti-aliased round-capped stroke through `pts` [(x, y)...] (pixels). `alphas` = per point."""
    h, w = img.shape[:2]
    pts = np.asarray(pts, np.float32)
    r = width / 2
    xmin, ymin = np.floor(pts.min(0) - r - 2).astype(int)
    xmax, ymax = np.ceil(pts.max(0) + r + 2).astype(int)
    xs, ys = np.arange(xmin, xmax), np.arange(ymin, ymax)
    cov = np.zeros((len(ys), len(xs)), np.float32)
    al = np.ones(len(pts), np.float32) if alphas is None else np.asarray(alphas, np.float32)
    for i in range(len(pts) - 1):
        (ax, ay), (bx, by) = pts[i], pts[i + 1]
        sx0, sx1 = int(min(ax, bx) - r - 2) - xmin, int(max(ax, bx) + r + 3) - xmin
        sy0, sy1 = int(min(ay, by) - r - 2) - ymin, int(max(ay, by) + r + 3) - ymin
        X = xs[sx0:sx1][None, :] + 0.5
        Y = ys[sy0:sy1][:, None] + 0.5
        dx, dy = bx - ax, by - ay
        ll = dx * dx + dy * dy
        t = np.clip(((X - ax) * dx + (Y - ay) * dy) / ll, 0, 1) if ll > 0 else np.zeros_like(X + Y)
        d = np.hypot(X - (ax + t * dx), Y - (ay + t * dy))
        a = al[i] + (al[i + 1] - al[i]) * t
        c = np.clip(r - d + 0.5, 0, 1) * a
        cov[sy0:sy1, sx0:sx1] = np.maximum(cov[sy0:sy1, sx0:sx1], c)
    cov *= alpha
    if wrap:
        _wrapped(img, ys, xs, cov, color)
    else:
        my, mx = (ys >= 0) & (ys < h), (xs >= 0) & (xs < w)
        blend(img, ys[my], xs[mx], cov[np.ix_(my, mx)], color)


def star5(r, rf=0.45, rot=0.0, round_r=0.0):
    """inside-test for a point-up 5-point star of outer radius r (iq's sdStar5), corners rounded."""
    k1x, k1y = 0.809016994375, -0.587785252292
    k2x, k2y = -k1x, k1y
    rr = r - round_r
    c, s = math.cos(rot), math.sin(rot)

    def inside(X, Y):
        px = X * c + Y * s
        py = -(-X * s + Y * c)  # y up
        px = np.abs(px)
        d = np.maximum(k1x * px + k1y * py, 0)
        px, py = px - 2 * d * k1x, py - 2 * d * k1y
        d = np.maximum(k2x * px + k2y * py, 0)
        px, py = px - 2 * d * k2x, py - 2 * d * k2y
        px = np.abs(px)
        py = py - rr
        bax, bay = rf * (-k1y), rf * k1x - 1
        h = np.clip((px * bax + py * bay) / (bax * bax + bay * bay), 0, rr)
        dist = np.hypot(px - bax * h, py - bay * h) * np.sign(py * bax - px * bay)
        return dist < round_r
    return inside


def crescent(r, bite=0.78, off=(0.42, -0.30), rot=0.0):
    """inside-test for a crescent moon: a disc of radius r minus a disc of radius bite*r offset by
    off*r (x right, y down), so it opens toward the offset."""
    ox, oy = off[0] * r, off[1] * r
    rb = bite * r
    c, s = math.cos(rot), math.sin(rot)

    def inside(X, Y):
        px, py = X * c + Y * s, -X * s + Y * c
        return (px * px + py * py < r * r) & ((px - ox) ** 2 + (py - oy) ** 2 > rb * rb)
    return inside


def sparkle(r, thin=0.55):
    """inside-test for a soft 4-point twinkle (an astroid-like star)."""
    p = thin

    def inside(X, Y):
        return (np.abs(X) / r) ** p + (np.abs(Y) / r) ** p < 1.0
    return inside


def disc(r):
    return lambda X, Y: X * X + Y * Y < r * r


def ellipse(rx, ry, rot=0.0):
    c, s = math.cos(rot), math.sin(rot)

    def inside(X, Y):
        px, py = X * c + Y * s, -X * s + Y * c
        return (px / rx) ** 2 + (py / ry) ** 2 < 1.0
    return inside


def shade(k):
    """colour function for blend(): multiplies what is there by k (darker < 1 < lighter)."""
    return lambda sub: np.clip(sub * k, 0, 1)


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)


# ---------------------------------------------------------------- floor: warm wood planks
def paint_floor(seed=11):
    rng = np.random.default_rng(seed)
    img = canvas(PLANK1)
    bw = SIZE // 4  # 256 px = 40 studs per board
    yy = np.arange(SIZE, dtype=np.float32)[:, None] + 0.5
    xx = np.arange(SIZE, dtype=np.float32)[None, :] + 0.5
    # end joints per board (rows): staggered so no two line up; most boards run the whole 160 studs
    joints = [[170], [640], [380, 900], [60]]
    bases = [PLANK1, PLANK2, (171, 113, 64), (194, 134, 81)]
    for b in range(4):
        x0 = b * bw
        cols = slice(x0, x0 + bw)
        js = sorted(joints[b])
        seg_ids = np.searchsorted(js, yy[:, 0]) % len(js)  # rows past the last joint wrap into segment 0
        base = _rgb(bases[b])
        lx = (xx[0, cols] - x0) / bw  # 0..1 across the board
        # painted sheen: a soft lighter streak a third of the way across, darker toward the seams
        across = 1.0 + 0.045 * np.exp(-((lx - 0.36) / 0.16) ** 2) - 0.05 * np.exp(-(lx / 0.05) ** 2) \
            - 0.07 * np.exp(-((1 - lx) / 0.06) ** 2)
        for k in range(len(js)):
            tint = 1.0 + rng.uniform(-0.045, 0.045)
            warm = np.array([1.0 + rng.uniform(-0.02, 0.02), 1.0, 1.0 - rng.uniform(-0.02, 0.03)], np.float32)
            rows = seg_ids == k
            start = js[k - 1]
            length = (js[k] - js[k - 1]) % SIZE or SIZE
            t = ((yy[rows, 0] - start) % SIZE) / length  # 0..1 along the segment
            # soft tonal drift along the board (whole cosine cycles per tile -> seamless)
            y = yy[rows, 0]
            along = 1.0 + 0.03 * np.cos(math.tau * (t - rng.uniform(0, 1))) \
                + 0.015 * np.cos(math.tau * (rng.integers(2, 4) * y / SIZE + rng.uniform(0, 1)))
            col = base * warm * tint
            img[rows, cols] = col[None, None, :] * (along[:, None] * across[None, :])[..., None]
    # grain: long wavy strokes along each board (periodic in y), bending round the knots
    knots = [(b * bw + bw * fx, fy, rx, ry) for b, fx, fy, rx, ry in
             ((0, 0.62, 330, 9, 17), (1, 0.30, 820, 7, 13), (2, 0.70, 250, 10, 19), (3, 0.40, 610, 8, 15),
              (2, 0.28, 660, 6, 11))]
    for b in range(4):
        x0 = b * bw
        n_lines = 7
        for i in range(n_lines):
            cx = x0 + bw * (0.1 + 0.8 * (i + rng.uniform(-0.3, 0.3)) / (n_lines - 1))
            k1, k2 = rng.integers(1, 3), rng.integers(3, 6)
            a1, a2 = rng.uniform(4, 9), rng.uniform(1.5, 3.5)
            p1, p2 = rng.uniform(0, math.tau, 2)
            ys = np.arange(0, SIZE + 8, 8, dtype=np.float32)
            xs = cx + a1 * np.sin(math.tau * k1 * ys / SIZE + p1) + a2 * np.sin(math.tau * k2 * ys / SIZE + p2)
            for kx, ky, rx, ry in knots:
                if x0 <= kx < x0 + bw:
                    dy = (ys - ky + SIZE / 2) % SIZE - SIZE / 2
                    side = np.sign(xs - kx + 1e-3)
                    gap = np.abs(xs - kx)
                    push = (rx * 2.6) * np.exp(-(dy / (ry * 2.8)) ** 2) * np.exp(-(gap / (rx * 3.5)) ** 2)
                    xs = xs + side * push
            xs = np.clip(xs, x0 + 6, x0 + bw - 6)
            # broken strokes: alpha fades in and out along the line (integer cycles -> seamless)
            m, ph = rng.integers(2, 5), rng.uniform(0, math.tau)
            al = np.clip(0.15 + 0.85 * (0.5 + 0.5 * np.sin(math.tau * m * ys / SIZE + ph)) ** 0.7, 0, 1)
            polyline(img, np.stack([xs, ys], 1), rng.uniform(2.2, 3.6), shade(0.80), alpha=0.75, alphas=al)
            # paired thin light line beside some grain lines (painted highlight)
            if i % 2 == 0:
                polyline(img, np.stack([xs + 4.5, ys], 1), 1.6, shade(1.09), alpha=0.6, alphas=al)
    # knots: dark ellipse, lighter ring, dark rim
    for kx, ky, rx, ry in knots:
        stamp(img, kx, ky, ry * 2.2, ellipse(rx * 2.0, ry * 2.0), shade(0.9), alpha=0.8)
        stamp(img, kx, ky, ry * 1.6, ellipse(rx * 1.35, ry * 1.35), shade(1.06), alpha=0.8)
        stamp(img, kx, ky, ry * 1.2, ellipse(rx, ry), (120, 72, 38), alpha=0.95)
        stamp(img, kx - rx * 0.2, ky - ry * 0.25, ry * 0.7, ellipse(rx * 0.45, ry * 0.45), (96, 56, 30), alpha=0.9)
    # board seams (vertical, wrapped at x = 0) with a bevel: dark line, soft shadow right, highlight left
    for b in range(4):
        x = b * bw
        polyline(img, [(x + 3.5, -10), (x + 3.5, SIZE + 10)], 5.0, shade(0.86), alpha=0.7)
        polyline(img, [(x - 2.5, -10), (x - 2.5, SIZE + 10)], 2.0, shade(1.12), alpha=0.8)
        polyline(img, [(x, -10), (x, SIZE + 10)], 3.2, (74, 44, 26), alpha=0.95)
    # end joints across each board + two nail dots either side
    for b in range(4):
        x0 = b * bw
        for j in joints[b]:
            polyline(img, [(x0 + 2, j + 3), (x0 + bw - 2, j + 3)], 4.0, shade(0.88), alpha=0.7)
            polyline(img, [(x0 + 2, j - 2.2), (x0 + bw - 2, j - 2.2)], 1.8, shade(1.12), alpha=0.7)
            polyline(img, [(x0 + 1.5, j), (x0 + bw - 1.5, j)], 3.0, (74, 44, 26), alpha=0.95)
            for fx in (0.2, 0.8):
                for dy in (-11, 11):
                    stamp(img, x0 + bw * fx, j + dy, 5, disc(3.2), (88, 54, 32), alpha=0.85)
                    stamp(img, x0 + bw * fx - 0.8, j + dy - 0.8, 3, disc(1.2), shade(1.25), alpha=0.6)
    return np.clip(img, 0, 1)


# ---------------------------------------------------------------- walls: starry-night wallpaper
def paint_walls(seed=7):
    rng = np.random.default_rng(seed)
    img = canvas(WALL)
    xx = np.arange(SIZE, dtype=np.float32)[None, :] + 0.5
    # a whisper of paper: very soft periodic mottling
    img *= (1 + 0.018 * pnoise(rng, 4.0) + 0.008 * pnoise(rng, 12.0))[..., None]
    # two soft darker stripes per tile (centred at x = 256, 768; 19 studs wide) with pinstripes
    for cx in (256, 768):
        d = np.abs(xx - cx)
        band = np.clip(96 - d + 0.5, 0, 1)
        img *= 1 - band[..., None] * (1 - _rgb(WALL_STRIPE) / _rgb(WALL))
        for side in (-1, 1):
            polyline(img, [(cx + side * 108, -10), (cx + side * 108, SIZE + 10)], 2.6, (100, 88, 156), alpha=0.55)
        # a quiet chain of dots and little diamonds down the stripe (the "damask" hint)
        for k in range(8):
            y = k * 128 + 64
            stamp(img, cx, y, 9, ellipse(4.5, 8.0), (96, 84, 150), alpha=0.5)
            stamp(img, cx, y + 64, 5, disc(3.0), (96, 84, 150), alpha=0.45)
    # the print: half-drop columns at x = 512 and x = 0 (between the stripes)
    major = [(512, 128, "star", -0.12), (512, 640, "moon", 0.0), (0, 384, "moon", 0.25), (0, 896, "star", 0.15)]
    for x, y, kind, rot in major:
        if kind == "star":
            stamp(img, x, y, 44, star5(40, rf=0.46, rot=rot, round_r=5.5), STAR_CREAM, alpha=0.72)
        else:
            stamp(img, x, y, 44, crescent(38, bite=0.80, off=(0.40, -0.30), rot=rot), STAR_CREAM, alpha=0.72)
    for x, y, r in ((512, 384, 15), (0, 640, 15), (0, 128, 12), (512, 896, 12)):
        stamp(img, x, y, r + 2, sparkle(r), STAR_CREAM, alpha=0.55)
    for x, y in ((420, 250), (604, 512), (92, 760), (-92, 0), (404, 790), (620, 1000), (96, 260), (-110, 520)):
        stamp(img, x, y, 6, disc(4.0), STAR_CREAM, alpha=0.45)
    return np.clip(img, 0, 1)


# ---------------------------------------------------------------- ceiling: soft mottled plaster
def paint_ceiling(seed=5):
    rng = np.random.default_rng(seed)
    img = canvas(CEILING)
    n1 = pnoise(rng, 3.0)
    n2 = pnoise(rng, 7.0)
    n3 = pnoise(rng, 16.0)
    # painted blotches: soft-edged steps rather than raw noise
    v = 0.6 * n1 + 0.4 * n2
    steps = 0.5 * smoothstep(-0.35, 0.05, v) + 0.5 * smoothstep(0.45, 0.85, v)
    lum = 1.0 + 0.085 * (steps - 0.45) + 0.012 * n3
    hue = pnoise(rng, 2.5)
    tint = np.stack([1 + 0.025 * hue, 1 - 0.01 * hue, 1 - 0.02 * hue], -1)
    img *= lum[..., None] * tint
    # faint trowel swirls: soft lighter arcs
    for _ in range(26):
        cx, cy = rng.uniform(0, SIZE, 2)
        r = rng.uniform(60, 170)
        a0 = rng.uniform(0, math.tau)
        a1 = a0 + rng.uniform(0.8, 1.8)
        a = np.linspace(a0, a1, 40)
        pts = np.stack([cx + r * np.cos(a), cy + r * 0.8 * np.sin(a)], 1)
        al = np.sin(np.linspace(0, math.pi, 40)) ** 1.5
        polyline(img, pts, rng.uniform(8, 18), shade(1.07), alpha=0.35, alphas=al)
    return np.clip(img, 0, 1)


# ---------------------------------------------------------------- trim: cream-painted wood, per-profile bands
def _band_rows(profile, band):
    """-> (arc position along the profile per row of the band, part tag per row, arc lengths)."""
    s = arclen(profile)
    r0, r1 = band
    rows = np.arange(r0, r1) + 0.5
    st = (rows - r0) / (r1 - r0) * s[-1]
    idx = np.clip(np.searchsorted(s, st) - 1, 0, len(profile) - 2)
    tags = [profile[i][2] if profile[i][2] == profile[i + 1][2] else profile[i + 1][2] for i in idx]
    return st, tags, s


def paint_trim(seed=3):
    rng = np.random.default_rng(seed)
    img = canvas(CREAM_PAINT)
    # brush strokes along the length: long soft streaks (smooth along x, periodic)
    streak = pnoise(rng, 70.0, aniso=(25.0, 1.0))
    img *= (1 + 0.012 * streak)[..., None]
    warm_dark = np.array([0.90, 0.86, 0.80], np.float32)  # painted shade: warmer, not grey
    lift = np.array([1.03, 1.03, 1.02], np.float32)
    # tone per profile part: 0 = deepest painted shade, 0.5 = plain paint, 1 = lifted highlight
    tones = {"face": 0.5, "groove": 0.0, "cap": 0.8, "bead": 0.8, "cove": 0.2, "lip": 0.8}
    for name, profile in (("baseboard", baseboard_profile()), ("crown", crown_profile())):
        r0, r1 = TRIM_BANDS[name]
        st, tags, s = _band_rows(profile, (r0, r1))
        t = np.array([tones[g] for g in tags], np.float32)
        # soften the tag steps (a painted gradient, not a hard edge)
        ker = np.exp(-np.linspace(-2, 2, 15) ** 2)
        t = np.convolve(np.pad(t, 7, mode="edge"), ker / ker.sum(), mode="valid")
        k = np.where(t[:, None] < 0.5, warm_dark[None, :] + (1 - warm_dark[None, :]) * (t[:, None] / 0.5),
                     1 + (lift[None, :] - 1) * ((t[:, None] - 0.5) / 0.5))
        # baked contact shadow where the trim meets the floor / wall / ceiling
        px_per = (r1 - r0) / s[-1]
        k = k * (1 - 0.10 * np.exp(-(st * px_per) / 10.0))[:, None]            # floor / wall contact
        k = k * (1 - 0.08 * np.exp(-((s[-1] - st) * px_per) / 10.0))[:, None]  # wall / ceiling contact
        img[r0:r1] *= k[:, None, :]
        # thin painted ink lines where the profile changes (groove edges, cove edges)
        for i in range(1, len(profile)):
            if profile[i][2] != profile[i - 1][2]:
                y = r0 + s[i - 1] * px_per
                polyline(img, [(-10, y), (SIZE + 10, y)], 2.4, (150, 120, 92), alpha=0.55)
    # a few very faint wood-grain ghosts under the paint
    for _ in range(14):
        y0 = rng.uniform(0, SIZE)
        k1 = rng.integers(1, 3)
        xs = np.arange(-8, SIZE + 16, 8, dtype=np.float32)
        ys = y0 + rng.uniform(3, 8) * np.sin(math.tau * k1 * xs / SIZE + rng.uniform(0, math.tau))
        polyline(img, np.stack([xs, ys], 1), rng.uniform(1.5, 3.0), shade(0.95), alpha=0.5)
    # keep the band gaps flat (nothing samples them, but mip-maps do)
    img[:TRIM_BANDS["baseboard"][0]] = img[TRIM_BANDS["baseboard"][0]]
    img[TRIM_BANDS["baseboard"][1]:TRIM_BANDS["crown"][0]] = img[TRIM_BANDS["baseboard"][1] - 1]
    img[TRIM_BANDS["crown"][1]:] = img[TRIM_BANDS["crown"][1] - 1]
    return np.clip(img, 0, 1)


# ---------------------------------------------------------------- rug: knitted checker atlas
def _knit(u, v, sw, sh):
    """Knit stocking stitch at stud coords (u across the columns, v along the rows; arrays):
    -> (dome 0..1 = yarn height, twist 0..1 = ply crease). Columns sw wide, rows sh tall."""
    best = np.zeros_like(u)
    twist = np.zeros_like(u)
    ci = np.floor(u / sw)
    ri = np.floor(v / sh)
    lean = math.atan2(sw * 0.40, sh)
    a, b = sh * 0.66, sw * 0.255
    for dj in (-1, 0, 1):
        cy = (ri + dj + 0.5) * sh
        for leg in (-1, 1):
            cx = (ci + 0.5) * sw + leg * sw * 0.22
            ang = -leg * lean
            ca, sa = math.cos(ang), math.sin(ang)
            px, py = u - cx, v - cy
            qx, qy = px * ca - py * sa, px * sa + py * ca  # qy along the leg
            r2 = (qx / b) ** 2 + (qy / a) ** 2
            dome = np.sqrt(np.clip(1 - r2, 0, 1))
            tw = 0.5 + 0.5 * np.cos(math.tau * (qy + qx * 0.9 * leg) / (sh * 0.5))
            take = dome > best
            best = np.where(take, dome, best)
            twist = np.where(take, tw, twist)
    return best, twist


def _yarn(base, dome, twist, depth=0.22, ply=0.06):
    base = _rgb(base)
    k = (1 - depth) + depth * (0.35 + 0.65 * dome ** 0.6) + 0.05 * dome
    k = k * (1 - ply * twist * (dome > 0.05))
    return base[None, None, :] * k[..., None]


def paint_rug(seed=9):
    rng = np.random.default_rng(seed)
    img = canvas(RUG_EDGE)
    pps = RUG_PPS
    sw, sh = 2.5, 2.0  # stitch: 8 columns x 10 rows per 20-stud cell
    # checker cells: two variants each (slightly different tone + soft mottling)
    cell_px = RUG_CELL * pps
    for key, (sx, sy) in RUG_CELLS.items():
        base = RUG_A if key.startswith("cream") else RUG_B
        var = 1.0 + (0.0 if key.endswith("A") else rng.uniform(-0.03, -0.015))
        ys = (np.arange(RUG_SLOT, dtype=np.float32) + 0.5 - RUG_PAD) / pps   # studs from the cell edge
        xs = (np.arange(RUG_SLOT, dtype=np.float32) + 0.5 - RUG_PAD) / pps
        V, U = np.meshgrid(ys, xs, indexing="ij")
        dome, tw = _knit(U, V, sw, sh)
        col = _yarn(tuple(int(c * var) for c in base), dome, tw)
        mott = pnoise(rng, 5.0)[:RUG_SLOT, :RUG_SLOT]
        col *= (1 + 0.025 * mott)[..., None]
        # puffy cell: a touch darker toward its edges (inside the 20-stud cell)
        e = np.minimum(np.minimum(U, RUG_CELL - U), np.minimum(V, RUG_CELL - V))
        col *= (1 - 0.06 * np.exp(-np.clip(e, 0, None) / 0.9))[..., None]
        img[sy:sy + RUG_SLOT, sx:sx + RUG_SLOT] = col
    # border strip: x = depth from the checker (0..4 studs), rows = along the side (20 studs)
    sx, sy = RUG_STRIP
    xs = (np.arange(-RUG_PAD, RUG_BORDER * pps + RUG_PAD, dtype=np.float32) + 0.5) / pps
    ys = (np.arange(-RUG_PAD, cell_px + RUG_PAD, dtype=np.float32) + 0.5) / pps
    V, U = np.meshgrid(ys, xs, indexing="ij")
    img[sy - RUG_PAD:sy - RUG_PAD + V.shape[0], sx - RUG_PAD:sx - RUG_PAD + V.shape[1]] = _border(U, V)
    # corner piece: x = depth across the north/south side, rows = depth across the east/west side
    cx, cy = RUG_CORNER
    xs = (np.arange(-RUG_PAD, RUG_BORDER * pps + RUG_PAD, dtype=np.float32) + 0.5) / pps
    V, U = np.meshgrid(xs, xs, indexing="ij")
    img[cy - RUG_PAD:cy - RUG_PAD + V.shape[0], cx - RUG_PAD:cx - RUG_PAD + V.shape[1]] = _border_corner(U, V)
    return np.clip(img, 0, 1)


def _border(depth, along):
    """Border texture at (depth from the checker, position along the side) in studs."""
    sw, sh = RUG_FLAT / 2, 1.25  # two stitch columns across the flat band, 16 rows per 20 studs
    dome, tw = _knit(depth, along, sw, sh)
    col = _yarn(RUG_EDGE, dome, tw, depth=0.30)
    # the roll: a twisted cord (diagonal stripes, 25 per 20 studs) darkening toward the floor
    roll = np.clip((depth - RUG_FLAT) / (RUG_BORDER - RUG_FLAT), 0, 1)
    cord = 0.5 + 0.5 * np.cos(math.tau * (along + depth * 0.9) / 0.8)
    cord_col = _rgb(RUG_EDGE)[None, None, :] * ((0.92 - 0.22 * roll ** 1.5) * (0.88 + 0.16 * cord ** 0.7))[..., None]
    m = smoothstep(RUG_FLAT - 0.06, RUG_FLAT + 0.06, depth)[..., None]
    col = col * (1 - m) + cord_col * m
    # cream running stitch down the middle of the flat band: rounded 1-stud dashes every 5/3 studs
    period = 20 / 12
    a = (along + 0.33) % period - 0.5
    dist = np.hypot(np.maximum(np.abs(a) - 0.33, 0), depth - RUG_STITCH_AT)
    return _stitch(col, dist)


def _stitch(col, dist, r=0.17):
    """Paints the cream running stitch where `dist` (studs from its centre line) < r, anti-aliased."""
    cov = np.clip((r - dist) * RUG_PPS + 0.5, 0, 1)[..., None]
    thread = _rgb(RUG_A)[None, None, :] * (0.97 - 0.10 * np.clip(dist / r, 0, 1) ** 2)[..., None]
    return col * (1 - cov) + thread * cov


def _border_corner(dx, dz):
    """Corner piece: dx/dz = depth past the checker's corner along each axis (studs)."""
    n_side = dz >= dx  # the half that continues the north/south side (its depth is dz)
    a = _border(dz, dx)
    b = _border(dx, dz)
    col = np.where(n_side[..., None], a, b)
    # the running stitch turns the corner: an L at depth RUG_STITCH_AT on both axes (its dashes stop
    # short of the corner, so the corner itself gets one clean L-shaped stitch)
    k = RUG_STITCH_AT
    arm_x = np.hypot(np.maximum(np.maximum(dx - k, 0.15 - dx), 0), dz - k)  # along dz = k, dx in [0.15, k]
    arm_z = np.hypot(np.maximum(np.maximum(dz - k, 0.15 - dz), 0), dx - k)
    inner = (dx < k + 0.4) & (dz < k + 0.4)
    col_l = _stitch(col, np.minimum(arm_x, arm_z))
    return np.where(inner[..., None], col_l, col)


# ---------------------------------------------------------------- output
TEXTURES = {
    "RoomFloor": paint_floor,
    "RoomWalls": paint_walls,
    "RoomCeiling": paint_ceiling,
    "RoomTrim": paint_trim,
    "PlayRug": paint_rug,
}


def save(arr, path, quality=JPEG_QUALITY):
    """Writes a float RGB array (row 0 = top) as JPEG/PNG, with Pillow if present, else with Blender."""
    data = (np.clip(arr, 0, 1) * 255 + 0.5).astype(np.uint8)
    try:
        from PIL import Image
        im = Image.fromarray(data, "RGB")
        if path.lower().endswith((".jpg", ".jpeg")):
            im.save(path, quality=quality, subsampling=0, optimize=True)
        else:
            im.save(path, optimize=True)
        return path
    except ImportError:
        import bpy
        h, w = data.shape[:2]
        img = bpy.data.images.new(os.path.basename(path), w, h, alpha=False)
        rgba = np.concatenate([data[::-1], np.full((h, w, 1), 255, np.uint8)], -1)
        img.pixels.foreach_set((rgba.astype(np.float32) / 255).ravel())
        img.filepath_raw = path
        img.file_format = "JPEG" if path.lower().endswith((".jpg", ".jpeg")) else "PNG"
        img.save(filepath=path, quality=quality)
        bpy.data.images.remove(img)
        return path


def paint_all(out_dir=OUT_DIR, names=None):
    os.makedirs(out_dir, exist_ok=True)
    paths = {}
    for name, fn in TEXTURES.items():
        if names and name not in names:
            continue
        paths[name] = save(fn(), os.path.join(out_dir, name + ".jpg"))
        print(f"painted {paths[name]} ({os.path.getsize(paths[name]) / 1024:.0f} KB)")
    return paths


def texture_paths(out_dir=OUT_DIR):
    """name -> path of each texture; paints the missing ones first (into out_dir)."""
    missing = [n for n in TEXTURES if not os.path.exists(os.path.join(out_dir, n + ".jpg"))]
    if missing:
        paint_all(out_dir, missing)
    return {n: os.path.join(out_dir, n + ".jpg") for n in TEXTURES}


if __name__ == "__main__":
    paint_all(sys.argv[1] if len(sys.argv) > 1 else OUT_DIR)
