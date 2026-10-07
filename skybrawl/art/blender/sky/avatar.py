"""
Classic blocky avatars: each legend is a Roblox-style character, like the
fighters in battlegrounds games. One smooth blocky body (the R6 silhouette,
split like an R15 "blocky" body so elbows and knees bend) wears its whole
outfit as a printed texture, the way classic Shirts and Pants do, with an
anime face painted on the classic head. Only a few clean accessories (hair,
capes, scarves, mech arms...) are extra meshes, and the build checks that
they don't sink into the body.

A legend script (fighters/<name>.py) defines:

    NAME = "Sol"
    def model(av):        # build accessories, sway chains
    def paint(av, p):     # paint the clothing and face onto the atlas

This module turns that into:
  * a skinned mesh "Body" (rigid weights per body part, short soft hinges at
    the elbows, knees and waist so bends never open a gap; sway bones for
    capes, scarves and long hair);
  * a 1024 texture atlas laid out like a clothing template (front, back,
    sides, top and bottom of every limb, the head as a band around it), with
    a metalness and a roughness map for SurfaceAppearance;
  * an FBX (armature + Body + import markers), the JSON rig data for
    src/shared/FighterRigs.luau, the face as a decal image, and a plastic
    turnaround render plus a face close-up.

Everything is authored in R6 studs (the classic avatar is 5.2 studs tall;
sky/skeleton.py scales it to the 6-stud SkyRig). Rig space: X = the
fighter's right, Y = up, Z = behind (the face looks toward -Z).
"""

import json
import math
import os

import bpy  # before bmesh: the bpy module sets it up
import bmesh
import numpy as np
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree

from . import common, skeleton
from .common import RIG_TO_BLENDER, MeshBuilder, Palette

S = skeleton.R6_SCALE
EXPORT_DIR = os.path.join(common.EXPORT_DIR, "fighters")
PREVIEW_DIR = os.path.join(common.PREVIEW_DIR, "fighters")
TRI_BUDGET = 20000  # Roblox's limit per mesh (tests/art enforces it too)
ATLAS = 1024
SS = 3  # supersampling of the painted atlas

# Body layout (R6 studs) -------------------------------------------------------------

DEPTH = 1.0
BEVEL = 0.055  # the soft plastic edge on every block
HINGE = 0.07  # half-height of the soft band across a bending joint
LIMBS = {  # (x center, width, y0, y1)
    "Torso": (0.0, 2.0, 2.0, 4.0),
    "RightArm": (1.5, 1.0, 2.0, 4.0),
    "LeftArm": (-1.5, 1.0, 2.0, 4.0),
    "RightLeg": (0.5, 1.0, 0.0, 2.0),
    "LeftLeg": (-0.5, 1.0, 0.0, 2.0),
}
HEAD_R = 0.6
HEAD_Y0 = 4.0
HEAD_H = 1.2
HEAD_TOP = HEAD_Y0 + HEAD_H
HEAD_CORNER = 0.26
SHOULDER_Y = 3.5  # arm tops are rounded about the shoulder (side view)
HIP_Y = 2.0

# Where each limb splits between bones, bottom to top: (y, bone below, bone above).
SPLITS = {"Torso": [(2.5, "Root", "Waist")]}
for _side, _ in skeleton.SIDES:
    SPLITS[f"{_side}Arm"] = [(2.45, f"{_side}Wrist", f"{_side}Elbow"), (2.9, f"{_side}Elbow", f"{_side}Shoulder")]
    SPLITS[f"{_side}Leg"] = [(0.5, f"{_side}Ankle", f"{_side}Knee"), (1.25, f"{_side}Knee", f"{_side}Hip")]

PART_OF = {j[0]: j[2] for j in skeleton.JOINTS}  # joint -> the proxy part it moves


# Small math helpers ------------------------------------------------------------------


def hex_rgb(value):
    return np.array(common.hex_color(value), dtype=np.float32)


def mix(a, b, t):
    """Blends two hex colors (t = 0 -> a)."""
    ca, cb = common.hex_color(a), common.hex_color(b)
    return "#" + "".join(f"{int(round((x + (y - x) * t) * 255)):02x}" for x, y in zip(ca, cb))


def shade(color, amount):
    """Darker (amount < 0, toward a cool shadow) or lighter (amount > 0)."""
    if amount < 0:
        return mix(color, "#1a1626", -amount)
    return mix(color, "#fffaf0", amount)


# Atlas painting ------------------------------------------------------------------------


class Rect:
    def __init__(self, x, y, w, h):
        self.x, self.y, self.w, self.h = x, y, w, h


class Atlas:
    """The painted texture: color, metalness and roughness, supersampled.
    Rows run bottom to top (Blender's image convention)."""

    PAD = 4

    def __init__(self, size=ATLAS, ss=SS):
        self.size, self.ss = size, ss
        n = size * ss
        self.color = np.zeros((n, n, 3), dtype=np.float32)
        self.color[:] = hex_rgb("#808080")
        self.metal = np.zeros((n, n), dtype=np.float32)
        self.rough = np.full((n, n), 0.62, dtype=np.float32)
        self.regions = []

    def alloc(self, w, h):
        """Asks for a w x h region (atlas pixels); pack() places them all."""
        rect = Rect(0, 0, int(math.ceil(w)), int(math.ceil(h)))
        self.regions.append(rect)
        return rect

    def _place(self, scale):
        """Shelf-packs every region at `scale`, tallest first, with padding;
        returns whether they all fit."""
        p = self.PAD
        x = y = shelf = 0
        for r in sorted(self.regions, key=lambda r: (-r.h0, -r.w0)):
            r.w, r.h = max(4, int(r.w0 * scale)), max(4, int(r.h0 * scale))
            if x + r.w + 2 * p > self.size:
                y += shelf
                x, shelf = 0, 0
            r.x, r.y = x + p, y + p
            x += r.w + 2 * p
            shelf = max(shelf, r.h + 2 * p)
            if y + r.h + 2 * p > self.size:
                return False
        return True

    def pack(self):
        """Places every region as large as fits (the same scale for all, so
        texel density stays even): a binary search on the scale."""
        for r in self.regions:
            if not hasattr(r, "w0"):
                r.w0, r.h0 = r.w, r.h
        lo, hi = 0.2, 4.0
        for _ in range(24):
            mid = (lo + hi) / 2
            if self._place(mid):
                lo = mid
            else:
                hi = mid
        if not self._place(lo):
            raise ValueError("texture atlas is full")
        self.scale = lo
        return lo

    def bleed(self):
        """Copies each region's edge pixels into its padding, so texture
        filtering never reaches a neighbor's colors."""
        ss, p = self.ss, self.PAD * self.ss
        for r in self.regions:
            x0, y0, x1, y1 = r.x * ss, r.y * ss, (r.x + r.w) * ss, (r.y + r.h) * ss
            for arr in (self.color, self.metal, self.rough):
                arr[y0:y1, max(0, x0 - p):x0] = arr[y0:y1, x0:x0 + 1]
                arr[y0:y1, x1:x1 + p] = arr[y0:y1, x1 - 1:x1]
                arr[max(0, y0 - p):y0, max(0, x0 - p):x1 + p] = arr[y0:y0 + 1, max(0, x0 - p):x1 + p]
                arr[y1:y1 + p, max(0, x0 - p):x1 + p] = arr[y1 - 1:y1, max(0, x0 - p):x1 + p]

    def _image(self, name, data, non_color=False):
        ss = self.ss
        n = self.size
        if data.ndim == 2:
            small = data.reshape(n, ss, n, ss).mean(axis=(1, 3))
            rgba = np.stack([small, small, small, np.ones_like(small)], axis=-1)
        else:
            small = data.reshape(n, ss, n, ss, 3).mean(axis=(1, 3))
            rgba = np.concatenate([small, np.ones((n, n, 1), dtype=np.float32)], axis=-1)
        img = bpy.data.images.new(name, n, n, alpha=False)
        if non_color:
            img.colorspace_settings.name = "Non-Color"
        img.pixels.foreach_set(np.clip(rgba, 0, 1).astype(np.float32).ravel())
        return img

    def save(self, name, directory):
        """The three maps as images, written to `directory` (unless None)."""
        self.bleed()
        out = {}
        for channel, data in (("color", self.color), ("metal", self.metal), ("rough", self.rough)):
            img = self._image(f"{name}_{channel}", data, non_color=channel != "color")
            if directory:
                path = os.path.join(common.ensure_dir(directory), f"{name}_{channel}.png")
                img.filepath_raw = path
                img.file_format = "PNG"
                img.save()
            out[channel] = img
        return out


class Canvas:
    """One face of the body (or an accessory swatch) on the atlas, drawn in
    its own coordinates (a, b): u = au * a + bu and v = av * b + bv map them
    to the face's region (0..1 each way). Shapes are clipped to the region.

    Colors are hex strings; `alpha` blends; `clip` is an optional polygon
    (in the same coordinates) that masks the shape."""

    def __init__(self, atlas, rect, au, bu, av, bv, name=""):
        self.atlas, self.rect = atlas, rect
        self.au, self.bu, self.av, self.bv = au, bu, av, bv
        self.name = name

    # coordinates
    def px(self, a, b):
        """Face coordinates -> supersampled pixel coordinates (x, row)."""
        ss = self.atlas.ss
        u = self.au * a + self.bu
        v = self.av * b + self.bv
        return ((self.rect.x + u * self.rect.w) * ss, (self.rect.y + v * self.rect.h) * ss)

    def uv(self, a, b):
        u = self.au * a + self.bu
        v = self.av * b + self.bv
        return ((self.rect.x + u * self.rect.w) / self.atlas.size, (self.rect.y + v * self.rect.h) / self.atlas.size)

    def unit(self):
        """Supersampled pixels per face unit."""
        return abs(self.au) * self.rect.w * self.atlas.ss

    def bounds(self):
        """(a0, b0, a1, b1) of the whole face, in its own coordinates."""
        a0, a1 = sorted(((0 - self.bu) / self.au, (1 - self.bu) / self.au))
        b0, b1 = sorted(((0 - self.bv) / self.av, (1 - self.bv) / self.av))
        return a0, b0, a1, b1

    # rasterizing
    def _window(self, xs, ys, grow=0.0):
        ss = self.atlas.ss
        r = self.rect
        x0 = max(int(math.floor(min(xs) - grow)), r.x * ss)
        x1 = min(int(math.ceil(max(xs) + grow)) + 1, (r.x + r.w) * ss)
        y0 = max(int(math.floor(min(ys) - grow)), r.y * ss)
        y1 = min(int(math.ceil(max(ys) + grow)) + 1, (r.y + r.h) * ss)
        if x1 <= x0 or y1 <= y0:
            return None
        X, Y = np.meshgrid(np.arange(x0, x1) + 0.5, np.arange(y0, y1) + 0.5)
        return (x0, x1, y0, y1, X, Y)

    def _poly_mask(self, pts_px, X, Y):
        inside = np.zeros(X.shape, dtype=bool)
        n = len(pts_px)
        for i in range(n):
            (x1, y1), (x2, y2) = pts_px[i], pts_px[(i + 1) % n]
            if y1 == y2:
                continue
            cond = ((y1 > Y) != (y2 > Y)) & (X < (x2 - x1) * (Y - y1) / (y2 - y1) + x1)
            inside ^= cond
        return inside

    def _put(self, win, mask, color=None, alpha=1.0, clip=None, metal=None, rough=None, blend="normal"):
        x0, x1, y0, y1, X, Y = win
        if clip is not None:
            mask = mask & self._poly_mask([self.px(a, b) for a, b in clip], X, Y)
        a = mask.astype(np.float32) * alpha
        if color is not None:
            tgt = self.atlas.color[y0:y1, x0:x1]
            c = hex_rgb(color) if isinstance(color, str) else color
            if blend == "multiply":
                c = tgt * c
            elif blend == "screen":
                c = 1 - (1 - tgt) * (1 - c)
            tgt[:] = tgt * (1 - a[..., None]) + c * a[..., None]
        if metal is not None:
            m = self.atlas.metal[y0:y1, x0:x1]
            m[:] = m * (1 - a) + metal * a
        if rough is not None:
            g = self.atlas.rough[y0:y1, x0:x1]
            g[:] = g * (1 - a) + rough * a

    def fill(self, color, metal=None, rough=None):
        a0, b0, a1, b1 = self.bounds()
        self.rect_(a0, b0, a1, b1, color, metal=metal, rough=rough)

    def rect_(self, a0, b0, a1, b1, color, alpha=1.0, clip=None, metal=None, rough=None, blend="normal"):
        self.poly([(a0, b0), (a1, b0), (a1, b1), (a0, b1)], color, alpha, clip, metal, rough, blend)

    def poly(self, pts, color, alpha=1.0, clip=None, metal=None, rough=None, blend="normal"):
        pp = [self.px(a, b) for a, b in pts]
        win = self._window([p[0] for p in pp], [p[1] for p in pp])
        if win:
            self._put(win, self._poly_mask(pp, win[4], win[5]), color, alpha, clip, metal, rough, blend)

    def ellipse(self, ca, cb, ra, rb, color, rotation=0.0, alpha=1.0, clip=None, metal=None, rough=None,
                blend="normal"):
        cx, cy = self.px(ca, cb)
        k = self.unit()
        rx, ry = ra * k, rb * abs(self.av) * self.rect.h * self.atlas.ss
        rmax = max(rx, ry)
        win = self._window([cx - rmax, cx + rmax], [cy - rmax, cy + rmax])
        if not win:
            return
        X, Y = win[4], win[5]
        # rotation is counter-clockwise in face coordinates; flip if the map mirrors
        sign = 1 if (self.au > 0) == (self.av > 0) else -1
        c, s = math.cos(math.radians(rotation * sign)), math.sin(math.radians(rotation * sign))
        dx, dy = X - cx, Y - cy
        u = (dx * c + dy * s) / max(rx, 1e-6)
        v = (-dx * s + dy * c) / max(ry, 1e-6)
        self._put(win, u * u + v * v <= 1.0, color, alpha, clip, metal, rough, blend)

    def stroke(self, pts, width, color, alpha=1.0, taper=None, clip=None, metal=None, rough=None, blend="normal"):
        """A polyline `width` face units wide with round ends; `taper` =
        (start, end) width factors."""
        pp = [self.px(a, b) for a, b in pts]
        k = self.unit()
        w0 = width * k * (taper[0] if taper else 1.0)
        w1 = width * k * (taper[1] if taper else 1.0)
        grow = max(w0, w1)
        win = self._window([p[0] for p in pp], [p[1] for p in pp], grow)
        if not win:
            return
        X, Y = win[4], win[5]
        mask = np.zeros(X.shape, dtype=bool)
        seg_len = [math.dist(p, q) for p, q in zip(pp, pp[1:])]
        total = sum(seg_len) or 1.0
        run = 0.0
        for (x1, y1), (x2, y2), ln in zip(pp, pp[1:], seg_len):
            dx, dy = x2 - x1, y2 - y1
            ll = dx * dx + dy * dy or 1e-9
            t = np.clip(((X - x1) * dx + (Y - y1) * dy) / ll, 0, 1)
            d2 = (X - x1 - t * dx) ** 2 + (Y - y1 - t * dy) ** 2
            f = (run + t * ln) / total
            w = w0 + (w1 - w0) * f
            mask |= d2 <= (w / 2) ** 2
            run += ln
        self._put(win, mask, color, alpha, clip, metal, rough, blend)

    def gradient(self, p0, p1, c0, c1, alpha=1.0, clip=None):
        """Linear gradient from color c0 at p0 to c1 at p1 (face coordinates),
        over the whole face (or `clip`)."""
        a0, b0, a1, b1 = self.bounds()
        pp = [self.px(a, b) for a, b in ((a0, b0), (a1, b0), (a1, b1), (a0, b1))]
        win = self._window([p[0] for p in pp], [p[1] for p in pp])
        if not win:
            return
        x0, x1, y0, y1, X, Y = win
        (sx, sy), (ex, ey) = self.px(*p0), self.px(*p1)
        dx, dy = ex - sx, ey - sy
        t = np.clip(((X - sx) * dx + (Y - sy) * dy) / (dx * dx + dy * dy or 1e-9), 0, 1)
        col = hex_rgb(c0)[None, None, :] * (1 - t[..., None]) + hex_rgb(c1)[None, None, :] * t[..., None]
        mask = np.ones(X.shape, dtype=bool)
        if clip is not None:
            mask &= self._poly_mask([self.px(a, b) for a, b in clip], X, Y)
        a = mask.astype(np.float32) * alpha
        tgt = self.atlas.color[y0:y1, x0:x1]
        tgt[:] = tgt * (1 - a[..., None]) + col * a[..., None]

    def edges(self, width=0.12, strength=0.22, sides=(True, True, True, True)):
        """Soft shadow along the face's edges (left, bottom, right, top in
        face coordinates): the painted occlusion classic clothing has."""
        a0, b0, a1, b1 = self.bounds()
        pp = [self.px(a, b) for a, b in ((a0, b0), (a1, b1))]
        win = self._window([pp[0][0], pp[1][0]], [pp[0][1], pp[1][1]])
        if not win:
            return
        x0, x1, y0, y1, X, Y = win
        k = width * self.unit()
        xa, xb = sorted((pp[0][0], pp[1][0]))
        ya, yb = sorted((pp[0][1], pp[1][1]))
        dist = np.full(X.shape, 1e9, dtype=np.float32)
        # map face sides to pixel sides (the map may mirror)
        left, bottom, right, top = sides
        if self.au < 0:
            left, right = right, left
        if self.av < 0:
            bottom, top = top, bottom
        if left:
            dist = np.minimum(dist, X - xa)
        if right:
            dist = np.minimum(dist, xb - X)
        if bottom:
            dist = np.minimum(dist, Y - ya)
        if top:
            dist = np.minimum(dist, yb - Y)
        f = np.clip(1 - dist / max(k, 1e-6), 0, 1) ** 2 * strength
        tgt = self.atlas.color[y0:y1, x0:x1]
        tgt[:] = tgt * (1 - f[..., None]) + tgt * hex_rgb("#2a2438")[None, None, :] * f[..., None]

    def material(self, metal=None, rough=None, clip=None):
        a0, b0, a1, b1 = self.bounds()
        self.rect_(a0, b0, a1, b1, None, clip=clip, metal=metal, rough=rough)


# The body's faces on the atlas -------------------------------------------------------------

BODY_DENSITY = 96  # atlas pixels per R6 stud on the body
CAP_DENSITY = 48  # tops and bottoms are rarely seen
FACE_DENSITY = 260  # the front of the head (the face) gets the most
FACE_SPAN = 78.75  # degrees either side of the front: a vertex ring angle of the 32-sided head


class Limb:
    """The six painted faces of one blocky limb (or the torso). Face
    coordinates are body coordinates: front and back use (x, y) with x
    measured from the limb's center (the fighter's right is +x on both),
    sides use (z, y) (front is -z), top and bottom use (x, z)."""

    def __init__(self, atlas, name):
        cx, w, y0, y1 = LIMBS[name]
        self.name, self.cx, self.w, self.y0, self.y1 = name, cx, w, y0, y1
        d = DEPTH
        h = y1 - y0
        D, C = BODY_DENSITY, CAP_DENSITY
        hw, hd = w / 2, d / 2
        # u = au * a + bu, v = av * b + bv
        self.front = Canvas(atlas, atlas.alloc(w * D, h * D), -1 / w, 0.5, 1 / h, -y0 / h, f"{name}.front")
        self.back = Canvas(atlas, atlas.alloc(w * D, h * D), 1 / w, 0.5, 1 / h, -y0 / h, f"{name}.back")
        self.right = Canvas(atlas, atlas.alloc(d * D, h * D), -1 / d, 0.5, 1 / h, -y0 / h, f"{name}.right")
        self.left = Canvas(atlas, atlas.alloc(d * D, h * D), 1 / d, 0.5, 1 / h, -y0 / h, f"{name}.left")
        self.top = Canvas(atlas, atlas.alloc(w * C, d * C), 1 / w, 0.5, -1 / d, 0.5, f"{name}.top")
        self.bottom = Canvas(atlas, atlas.alloc(w * C, d * C), -1 / w, 0.5, -1 / d, 0.5, f"{name}.bottom")
        self.hw, self.hd = hw, hd

    @property
    def sides(self):
        return [self.front, self.right, self.back, self.left]

    @property
    def faces(self):
        return [self.front, self.back, self.right, self.left, self.top, self.bottom]

    @property
    def outer(self):
        """The side facing away from the body (arms and legs)."""
        return self.right if self.cx > 0 else self.left

    @property
    def inner(self):
        return self.left if self.cx > 0 else self.right

    def fill(self, color, metal=None, rough=None):
        for f in self.faces:
            f.fill(color, metal, rough)

    def band(self, y0, y1, color, alpha=1.0, metal=None, rough=None):
        """A stripe all the way around between two heights."""
        for f in self.sides:
            a0, _, a1, _ = f.bounds()
            f.rect_(a0, y0, a1, y1, color, alpha, metal=metal, rough=rough)

    def canvas_for(self, normal):
        """The face a (local) normal belongs to."""
        ax = max(range(3), key=lambda i: abs(normal[i]))
        if ax == 0:
            return self.right if normal[0] > 0 else self.left
        if ax == 1:
            return self.top if normal[1] > 0 else self.bottom
        return self.back if normal[2] > 0 else self.front

    def coords(self, canvas, p):
        """Face coordinates of a point on the limb."""
        x, y, z = p
        if canvas in (self.front, self.back):
            return (x - self.cx, y)
        if canvas in (self.right, self.left):
            return (z, y)
        return (x - self.cx, z)


class _Both:
    """Draws on several canvases at once (they share coordinates); other
    attributes come from the first."""

    def __init__(self, *canvases):
        self._canvases = canvases

    def __getattr__(self, name):
        first = getattr(self._canvases[0], name)
        if not callable(first):
            return first

        def call(*args, **kw):
            out = [getattr(c, name)(*args, **kw) for c in self._canvases]
            return out[0]
        return call


class HeadFaces:
    """The classic head: a band all the way around (coordinates (s, y): s is
    the distance around the surface from the front center, the fighter's
    right positive) and round caps on top and bottom ((x, z)). The front of
    the band, where the face goes, has its own sharper region; `band` draws
    on both."""

    def __init__(self, atlas):
        circ = 2 * math.pi * HEAD_R
        self.around = Canvas(atlas, atlas.alloc(circ * BODY_DENSITY, HEAD_H * BODY_DENSITY), -1 / circ, 0.5,
                             1 / HEAD_H, -HEAD_Y0 / HEAD_H, "Head.band")
        span = 2 * math.radians(FACE_SPAN) * HEAD_R
        self.face = Canvas(atlas, atlas.alloc(span * FACE_DENSITY, HEAD_H * FACE_DENSITY), -1 / span, 0.5,
                           1 / HEAD_H, -HEAD_Y0 / HEAD_H, "Head.face")
        self.band = _Both(self.around, self.face)
        d = 2 * HEAD_R
        self.top = Canvas(atlas, atlas.alloc(d * BODY_DENSITY, d * BODY_DENSITY), 1 / d, 0.5, -1 / d, 0.5, "Head.top")
        self.bottom = Canvas(atlas, atlas.alloc(d * CAP_DENSITY, d * CAP_DENSITY), -1 / d, 0.5, -1 / d, 0.5,
                             "Head.bottom")
        self.front = self.band  # the face is drawn on the band around s = 0

    def band_canvas(self, angle):
        """The canvas a head face at `angle` (radians from the front) maps to."""
        return self.face if abs(math.degrees(angle)) < FACE_SPAN else self.around

    def fill(self, color):
        for f in (self.around, self.face, self.top, self.bottom):
            f.fill(color)


class Painter:
    """Everything a legend paints: p.torso, p.arm("Right"), p.leg("Left"),
    p.head, p.swatch("Hair")."""

    def __init__(self, atlas, swatches):
        self.atlas = atlas
        self.limbs = {name: Limb(atlas, name) for name in LIMBS}
        self.head = HeadFaces(atlas)
        self.swatches = swatches

    @property
    def torso(self):
        return self.limbs["Torso"]

    def arm(self, side):
        return self.limbs[f"{side}Arm"]

    def leg(self, side):
        return self.limbs[f"{side}Leg"]

    def arms(self):
        return [self.arm("Right"), self.arm("Left")]

    def legs(self):
        return [self.leg("Right"), self.leg("Left")]

    def swatch(self, key):
        return self.swatches[key]

    def finish(self, edge=0.12, strength=0.26):
        """The shading pass over all clothing faces."""
        for limb in self.limbs.values():
            for f in limb.sides:
                f.edges(edge, strength)
            for f in (limb.top, limb.bottom):
                f.edges(edge * 0.7, strength * 0.6)


# Anime faces ---------------------------------------------------------------------------------


EYE_Y = 4.6
EYE_X = 0.24


def _arc(cx, cy, rx, ry, a0, a1, n=12):
    return [(cx + rx * math.cos(math.radians(a)), cy + ry * math.sin(math.radians(a)))
            for a in np.linspace(a0, a1, n)]


def anime_eye(c, side, iris, shape="sharp", glow=None, size=1.0, lash="#16121c", white="#fbfaf7", y=EYE_Y,
              x=EYE_X, look=0.0, pupil="#120e18"):
    """One anime eye on the head band. side = +1 (the fighter's right) or -1.
    shape: sharp (narrow, angled), round (big and open), narrow (half-lidded),
    fierce (sharp with a heavy lid)."""
    s = side
    cx = s * x
    w = 0.15 * size
    h = {"round": 0.13, "sharp": 0.1, "narrow": 0.065, "fierce": 0.085}[shape] * size
    tilt = {"round": 0.0, "sharp": 0.035, "narrow": 0.02, "fierce": 0.05}[shape]
    # eye white: top lid arcs higher at the outer side for sharp shapes
    inner, outer = cx - s * w, cx + s * w
    top = []
    bot = []
    for i in range(13):
        t = i / 12
        xx = inner + (outer - inner) * t
        bump = math.sin(math.pi * t)
        top.append((xx, y + h * bump ** 0.7 + tilt * (t - 0.5)))
        bot.append((xx, y - h * 0.8 * bump ** 1.2 + tilt * 0.4 * (t - 0.5)))
    white_shape = top + bot[::-1]
    c.poly(white_shape, white)
    # iris and pupil, clipped to the eye white
    ix = cx + s * 0.012 + look
    iy = y + 0.004
    ir = 0.075 * size
    color = glow or iris
    c.ellipse(ix, iy, ir, ir * 1.28, shade(color, -0.35), clip=white_shape)
    c.ellipse(ix, iy - ir * 0.25, ir * 0.82, ir * 0.95, color, clip=white_shape)
    c.ellipse(ix, iy - ir * 0.55, ir * 0.55, ir * 0.42, shade(color, 0.35), clip=white_shape)
    if glow:
        c.ellipse(ix, iy, ir * 0.22, ir * 0.7, "#ffffff", clip=white_shape)
    else:
        c.ellipse(ix, iy + ir * 0.05, ir * 0.38, ir * 0.55, pupil, clip=white_shape)
    # highlights
    c.ellipse(ix - s * ir * 0.35, iy + ir * 0.45, ir * 0.3, ir * 0.24, "#ffffff", clip=white_shape)
    c.ellipse(ix + s * ir * 0.35, iy - ir * 0.5, ir * 0.13, ir * 0.1, "#ffffff", alpha=0.85, clip=white_shape)
    # upper lash line, thicker toward the outer corner with a flick
    lid = [(px_, py_ + 0.004) for px_, py_ in top]
    flick = [(outer + s * 0.045, top[-1][1] + 0.012 + tilt * 0.5)]
    heavy = 0.034 if shape in ("sharp", "fierce") else 0.03
    c.stroke(lid + flick, heavy * size, lash, taper=(0.45, 1.15))
    if shape == "fierce":
        c.stroke([(inner, top[0][1] + 0.012), (outer, top[-1][1] + 0.03)], 0.03 * size, lash)
    # lower lash hint
    c.stroke(bot[7:12], 0.012 * size, lash, alpha=0.75, taper=(0.3, 1.0))
    return white_shape


def anime_brow(c, side, color, y=4.83, x=EYE_X, angle=0.0, width=0.025, length=0.2, arch=0.015):
    """angle > 0 lifts the outer end (a fierce or angry V), < 0 drops it
    (worried, sad)."""
    s = side
    inner = (s * (x - length * 0.55), y - angle * 0.5)
    outer = (s * (x + length * 0.5), y + angle * 0.5)
    mid = ((inner[0] + outer[0]) / 2, (inner[1] + outer[1]) / 2 + arch)
    c.stroke([inner, mid, outer], width, color, taper=(1.2, 0.45))


def anime_mouth(c, kind, color="#3a1c1c", y=4.3, width=1.0, teeth="#ffffff", inside="#5a1e24"):
    w = 0.1 * width
    if kind == "line":
        c.stroke([(-w, y), (w, y)], 0.016, color)
    elif kind == "smirk":
        c.stroke([(w * 0.9, y - 0.006), (0, y - 0.004), (-w * 1.05, y + 0.03)], 0.018, color, taper=(0.6, 1.0))
    elif kind == "smile":
        c.stroke(_arc(0, y + 0.05, w, 0.06, 200, 340), 0.018, color)
    elif kind in ("grin", "fangs", "roar"):
        open_h = {"grin": 0.07, "fangs": 0.08, "roar": 0.12}[kind]
        pts = [(-w * 1.15, y + 0.02)] + _arc(0, y + 0.02, w * 1.15, open_h, 180, 360, 14)[1:]
        c.poly(pts, inside)
        c.poly([(-w * 1.1, y + 0.02), (w * 1.1, y + 0.02), (w * 0.9, y - 0.012), (-w * 0.9, y - 0.012)], teeth,
               clip=pts)
        if kind in ("fangs", "roar"):
            for sx in (-1, 1):
                c.poly([(sx * w * 0.55, y + 0.02), (sx * w * 0.8, y + 0.02), (sx * w * 0.66, y - 0.045)], teeth)
        c.stroke(pts + [pts[0]], 0.014, color)
    elif kind == "frown":
        c.stroke(_arc(0, y - 0.05, w, 0.05, 20, 160), 0.018, color)
    elif kind == "open":
        c.ellipse(0, y, w * 0.5, 0.05, inside)
        c.stroke(_arc(0, y, w * 0.5, 0.05, 0, 360, 20), 0.014, color)


def face_decal(name, draw, px=512):
    """Paints the face alone, on a transparent background, as a decal image:
    drawn once over black and once over white, the difference gives alpha."""
    span = 1.0  # studs across the decal
    out = []
    for bg in ("#000000", "#ffffff"):
        atlas = Atlas(size=px, ss=2)
        atlas.color[:] = hex_rgb(bg)
        c = Canvas(atlas, Rect(0, 0, px, px), -1 / span, 0.5, 1 / span, 0.62 - EYE_Y / span)
        draw(c)
        n = px
        out.append(atlas.color.reshape(n, 2, n, 2, 3).mean(axis=(1, 3)))
    black, white = out
    alpha = np.clip(1.0 - (white - black).mean(axis=-1, keepdims=True), 0.0, 1.0)
    color = np.where(alpha > 1e-3, black / np.maximum(alpha, 1e-3), 0.0)
    rgba = np.concatenate([np.clip(color, 0, 1), alpha], axis=-1)
    img = bpy.data.images.new(name, px, px, alpha=True)
    img.pixels.foreach_set(rgba.astype(np.float32).ravel())
    path = os.path.join(common.ensure_dir(os.path.join(EXPORT_DIR, "decals")), f"{name}.png")
    img.filepath_raw = path
    img.file_format = "PNG"
    img.save()
    return path


# Accessory styles (painted swatches) --------------------------------------------------------------


class Style:
    """How an accessory's swatch is painted, and how its faces map onto it:
    projection "wrap" (around a vertical axis: hair, helmets, rings),
    "front" (u across x, v up: capes, masks, panels) or "side" (u across z)."""

    projection = "wrap"
    size = (128, 128)
    metal = 0.0
    rough = 0.6

    def __init__(self, color, projection=None, size=None, metal=None, rough=None, light=0.14, dark=-0.22):
        self.color = color
        self.light, self.dark = light, dark
        if projection:
            self.projection = projection
        if size:
            self.size = size
        if metal is not None:
            self.metal = metal
        if rough is not None:
            self.rough = rough

    def paint(self, c):
        """c: a Canvas over the swatch in (u, v) 0..1 coordinates."""
        c.gradient((0.5, 0.0), (0.5, 1.0), shade(self.color, self.dark), shade(self.color, self.light))
        c.material(self.metal, self.rough)


class Flat(Style):
    def paint(self, c):
        c.fill(self.color, self.metal, self.rough)


class Hair(Style):
    """Anime hair: a gradient, a bright shine band near the top and fine
    darker strands."""

    size = (256, 128)

    def __init__(self, color, shine=0.72, strands=18, shine_color=None, **kw):
        super().__init__(color, **kw)
        self.shine, self.strands = shine, strands
        self.shine_color = shine_color

    def paint(self, c):
        c.gradient((0.5, 0.0), (0.5, 1.0), shade(self.color, -0.3), shade(self.color, 0.1))
        rng = np.random.default_rng(len(self.color) * 7 + int(self.shine * 100))
        for _ in range(self.strands):
            x = rng.uniform(0, 1)
            c.stroke([(x, 0.0), (x + rng.uniform(-0.03, 0.03), rng.uniform(0.45, 0.95))], 0.012,
                     shade(self.color, -0.38), alpha=0.6, taper=(1.0, 0.2))
        if self.shine:
            pts = []
            for i in range(25):
                u = i / 24
                pts.append((u, self.shine + 0.035 * math.sin(u * math.pi * 16)))
            band = pts + [(u, v - 0.07) for u, v in reversed(pts)]
            c.poly(band, self.shine_color or shade(self.color, 0.45), alpha=0.85)
        c.material(0.0, 0.55)


class Cloth(Style):
    """Fabric: a gradient with soft vertical folds."""

    projection = "front"

    def __init__(self, color, folds=5, emblem=None, **kw):
        super().__init__(color, **kw)
        self.folds = folds
        self.emblem = emblem

    def paint(self, c):
        c.gradient((0.5, 0.0), (0.5, 1.0), shade(self.color, -0.2), shade(self.color, 0.08))
        rng = np.random.default_rng(self.folds * 13 + len(self.color))
        for i in range(self.folds):
            x = (i + 0.5) / self.folds + rng.uniform(-0.05, 0.05)
            c.stroke([(x, 0.02), (x + rng.uniform(-0.04, 0.04), 0.85)], 0.04, shade(self.color, -0.25), alpha=0.45,
                     taper=(1.4, 0.2))
            c.stroke([(x + 0.03, 0.05), (x + 0.03, 0.7)], 0.015, shade(self.color, 0.25), alpha=0.35,
                     taper=(1.0, 0.1))
        if self.emblem:
            self.emblem(c)
        c.material(self.metal, self.rough)


class Metal(Style):
    """Brushed metal: banded light and dark with a sharp glint."""

    metal = 0.75
    rough = 0.35

    def paint(self, c):
        c.gradient((0.5, 0.0), (0.5, 1.0), shade(self.color, -0.3), shade(self.color, 0.25))
        for v, w, a in ((0.62, 0.03, 0.8), (0.3, 0.06, 0.25), (0.82, 0.015, 0.6)):
            c.rect_(0, v - w / 2, 1, v + w / 2, shade(self.color, 0.55), alpha=a)
        c.material(self.metal, self.rough)


class Glow(Style):
    """Bright and smooth: crystals, lenses, energy."""

    rough = 0.15

    def paint(self, c):
        c.gradient((0.5, 0.0), (0.5, 1.0), self.color, shade(self.color, 0.6))
        c.material(self.metal, self.rough)


class Fur(Style):
    size = (128, 128)

    def paint(self, c):
        c.gradient((0.5, 0.0), (0.5, 1.0), shade(self.color, -0.25), shade(self.color, 0.1))
        rng = np.random.default_rng(31)
        for _ in range(40):
            x, y = rng.uniform(0, 1), rng.uniform(0, 1)
            c.stroke([(x, y), (x + rng.uniform(-0.04, 0.04), y - rng.uniform(0.1, 0.25))], 0.02,
                     shade(self.color, rng.uniform(-0.35, 0.25)), alpha=0.7, taper=(1.0, 0.1))
        c.material(0.0, 0.85)


# Geometry ------------------------------------------------------------------------------------------


def _rrect(hw, hd, r, seg=3):
    """Rounded rectangle outline in the XZ plane, starting at the front
    middle and going toward +x."""
    r = max(0.002, min(r, hw - 0.001, hd - 0.001))
    pts = []
    corners = ((hw - r, -hd + r, -90.0), (hw - r, hd - r, 0.0), (-hw + r, hd - r, 90.0), (-hw + r, -hd + r, 180.0))
    for cx, cz, a0 in corners:
        for k in range(seg + 1):
            a = math.radians(a0 + 90.0 * k / seg)
            pts.append((cx + r * math.cos(a), cz + r * math.sin(a)))
    return pts


def _loft_rings(bm, rings, cap_bottom=True, cap_top=True):
    """rings: lists of Vector, same length. Quads between consecutive rings,
    n-gon caps."""
    made = [[bm.verts.new(p) for p in ring] for ring in rings]
    n = len(rings[0])
    for r0, r1 in zip(made, made[1:]):
        for i in range(n):
            j = (i + 1) % n
            bm.faces.new((r0[i], r0[j], r1[j], r1[i]))
    if cap_bottom:
        bm.faces.new(list(reversed(made[0])))
    if cap_top:
        bm.faces.new(made[-1])
    return made


def _limb_levels(name):
    """Heights (and inset, depth override) of the rings that make a limb:
    rounded bottom, hinge loops, rounded or domed top."""
    cx, w, y0, y1 = LIMBS[name]
    b = BEVEL
    levels = []
    steps = 4
    for k in range(steps + 1):  # bottom bevel
        a = math.pi / 2 * k / steps
        levels.append((y0 + b - b * math.cos(a), b - b * math.sin(a), None))
    for y, _, _ in SPLITS.get(name, []):
        for dy in (-HINGE, 0.0, HINGE):
            levels.append((y + dy, 0.0, None))
    if name.endswith("Arm"):
        # the top is a half cylinder about the shoulder axis (side view), so a
        # swinging arm never pokes a corner up
        levels.append((SHOULDER_Y, 0.0, None))
        steps = 10
        r = y1 - SHOULDER_Y
        for k in range(1, steps + 1):
            a = math.pi / 2 * k / steps
            y = SHOULDER_Y + r * math.sin(a)
            depth = max(0.004, r * math.cos(a))
            levels.append((min(y, y1 - 0.002), 0.0, depth))
    else:
        for k in range(steps + 1):  # top bevel
            a = math.pi / 2 * k / steps
            levels.append((y1 - b + b * math.sin(a), b - b * math.cos(a), None))
    levels.sort(key=lambda t: t[0])
    out = []
    for lv in levels:
        if out and abs(lv[0] - out[-1][0]) < 1e-4:
            continue
        out.append(lv)
    return out


def _leg_dome(bm, name):
    """Under the torso: a rounded top on each leg about the hip axis, so a
    leg swinging forward or back never shows a corner. Hidden at rest."""
    cx, w, y0, y1 = LIMBS[name]
    r = 0.47
    rings = []
    steps = 8
    for k in range(steps + 1):
        a = math.pi / 2 * k / steps
        y = HIP_Y - 0.06 + (r + 0.06) * math.sin(a) if k else HIP_Y - 0.06
        depth = max(0.004, r * math.cos(a)) if k else r
        rings.append([Vector((cx + x, min(y, HIP_Y + r - 0.003), z)) for x, z in _rrect(r, depth, 0.03, 2)])
    return _loft_rings(bm, rings)


def _block(bm, name, layer, tag):
    cx, w, y0, y1 = LIMBS[name]
    hw, hd = w / 2, DEPTH / 2
    rings = []
    for y, inset, depth in _limb_levels(name):
        d = depth if depth is not None else hd - inset
        rings.append([Vector((cx + x, y, z)) for x, z in _rrect(hw - inset, d, BEVEL - inset if depth is None else
                                                                    min(BEVEL, depth), 3)])
    before = set(bm.faces)
    _loft_rings(bm, rings)
    for f in set(bm.faces) - before:
        f[layer] = tag


def _head(bm, layer, tag, segments=32):
    """The classic head: a cylinder with well-rounded top and bottom. Rings
    start at the back (so the texture seam is behind the head)."""
    rings = []
    corner = HEAD_CORNER
    steps = 7

    def ring(y, r):
        return [Vector((r * math.sin(math.pi + 2 * math.pi * i / segments), y,
                        -r * math.cos(math.pi + 2 * math.pi * i / segments))) for i in range(segments)]

    for k in range(steps + 1):
        a = math.pi / 2 * k / steps
        rings.append(ring(HEAD_Y0 + corner - corner * math.cos(a), HEAD_R - corner + corner * math.sin(a)))
    for y in np.linspace(HEAD_Y0 + corner, HEAD_TOP - corner, 6)[1:-1]:
        rings.append(ring(float(y), HEAD_R))
    for k in range(steps + 1):
        a = math.pi / 2 * k / steps
        rings.append(ring(HEAD_TOP - corner + corner * math.sin(a), HEAD_R - corner + corner * math.cos(a)))
    before = set(bm.faces)
    made = [[bm.verts.new(p) for p in r] for r in rings]
    for r0, r1 in zip(made, made[1:]):
        for i in range(segments):
            j = (i + 1) % segments
            bm.faces.new((r0[i], r0[j], r1[j], r1[i]))
    # caps: a center vertex fan keeps the poles clean
    for rr, y, rev in ((made[0], rings[0][0].y, True), (made[-1], rings[-1][0].y, False)):
        c = bm.verts.new((0.0, y, 0.0))
        for i in range(segments):
            j = (i + 1) % segments
            bm.faces.new((c, rr[j], rr[i]) if rev else (c, rr[i], rr[j]))
    for f in set(bm.faces) - before:
        f[layer] = tag


# Accessory shapes (all in R6 studs; `style` is a style key) -------------------------------


def spike(mb, base, direction, length, radius, style, segments=5):
    """A cone from `base` along `direction` (anime hair spikes, horns)."""
    d = Vector(direction).normalized()
    rot = Vector((0, 1, 0)).rotation_difference(d).to_matrix()
    center = Vector(base) + d * (length / 2)
    mb.cylinder(tuple(center), radius, length, style, rotation=rot, segments=segments, radius_top=0.0, smooth=False)


def lock(mb, points, radius, style, segments=6, tip=0.0):
    """A tube through `points` tapering from `radius` to `tip` (curved
    spikes, bangs, tails, tendrils); spheres round the bends."""
    pts = [Vector(p) for p in points]
    total = sum((b - a).length for a, b in zip(pts, pts[1:])) or 1.0
    run = 0.0
    for a, b in zip(pts, pts[1:]):
        seg = b - a
        r0 = radius + (tip - radius) * run / total
        run += seg.length
        r1 = radius + (tip - radius) * run / total
        rot = Vector((0, 1, 0)).rotation_difference(seg.normalized()).to_matrix()
        mb.cylinder(tuple((a + b) / 2), r0, seg.length, style, rotation=rot, segments=segments, radius_top=r1,
                    smooth=True)
        if r1 > 0.01 and b is not pts[-1]:
            mb.sphere(tuple(b), r1, style, segments=segments, rings=max(4, segments // 2 + 1))


def shell(mb, style, a0, a1, bottom, top, r_in=HEAD_R + 0.02, r_out=HEAD_R + 0.08, steps=24, rows=6):
    """A curved shell around the head between angles a0..a1 (degrees from
    the front, toward the fighter's right) from height bottom(angle) to
    `top`: the back and sides of a hairdo, a hood, a collar."""
    verts, faces = [], []

    def idx(i, j, k):
        return (i * (rows + 1) + j) * 2 + k

    for i in range(steps + 1):
        a = math.radians(a0 + (a1 - a0) * i / steps)
        yb = bottom(math.degrees(a)) if callable(bottom) else bottom
        for j in range(rows + 1):
            y = yb + (top - yb) * j / rows
            for r in (r_in, r_out):
                verts.append((r * math.sin(a), y, -r * math.cos(a)))
    for i in range(steps):
        for j in range(rows):
            faces.append((idx(i, j, 1), idx(i + 1, j, 1), idx(i + 1, j + 1, 1), idx(i, j + 1, 1)))
            faces.append((idx(i, j, 0), idx(i, j + 1, 0), idx(i + 1, j + 1, 0), idx(i + 1, j, 0)))
    for i in range(steps):  # bottom and top rims
        faces.append((idx(i, 0, 0), idx(i + 1, 0, 0), idx(i + 1, 0, 1), idx(i, 0, 1)))
        faces.append((idx(i, rows, 1), idx(i + 1, rows, 1), idx(i + 1, rows, 0), idx(i, rows, 0)))
    for i in (0, steps):  # side rims
        for j in range(rows):
            f = (idx(i, j, 0), idx(i, j, 1), idx(i, j + 1, 1), idx(i, j + 1, 0))
            faces.append(f if i == 0 else tuple(reversed(f)))
    mb.polys(verts, faces, style, smooth=True)


def sheet(mb, rows, thickness, style):
    """A cloth sheet through a grid of points (rows top to bottom, each row
    left to right as seen from behind), given thickness: capes, scarves,
    tabards, coat tails."""
    import itertools

    grid = [[Vector(p) for p in row] for row in rows]
    nr, nc = len(grid), len(grid[0])

    def normal(i, j):
        a = grid[min(i + 1, nr - 1)][j] - grid[max(i - 1, 0)][j]
        b = grid[i][min(j + 1, nc - 1)] - grid[i][max(j - 1, 0)]
        n = b.cross(a)
        return n.normalized() if n.length > 1e-9 else Vector((0, 0, 1))

    verts, faces = [], []
    for i, j in itertools.product(range(nr), range(nc)):
        n = normal(i, j) * thickness / 2
        verts.append(tuple(grid[i][j] + n))
        verts.append(tuple(grid[i][j] - n))

    def idx(i, j, k):
        return (i * nc + j) * 2 + k

    for i in range(nr - 1):
        for j in range(nc - 1):
            faces.append((idx(i, j, 0), idx(i + 1, j, 0), idx(i + 1, j + 1, 0), idx(i, j + 1, 0)))
            faces.append((idx(i, j, 1), idx(i, j + 1, 1), idx(i + 1, j + 1, 1), idx(i + 1, j, 1)))
    for i in range(nr - 1):
        faces.append((idx(i, 0, 1), idx(i + 1, 0, 1), idx(i + 1, 0, 0), idx(i, 0, 0)))
        faces.append((idx(i, nc - 1, 0), idx(i + 1, nc - 1, 0), idx(i + 1, nc - 1, 1), idx(i, nc - 1, 1)))
    for j in range(nc - 1):
        faces.append((idx(0, j, 0), idx(0, j + 1, 0), idx(0, j + 1, 1), idx(0, j, 1)))
        faces.append((idx(nr - 1, j, 1), idx(nr - 1, j + 1, 1), idx(nr - 1, j + 1, 0), idx(nr - 1, j, 0)))
    mb.polys(verts, faces, style, smooth=True)


def cape_rows(top_y, bottom_y, top_half, bottom_half, top_z, bottom_z, rows=7, cols=7, curve=0.12, hem=None):
    """Grid rows for a cape hanging behind the back: it widens and falls
    away from the body toward the hem; `curve` wraps its edges forward;
    `hem` is an optional function (u in 0..1 across) -> extra drop at the
    bottom (a ragged or pointed hem)."""
    out = []
    for i in range(rows):
        t = i / (rows - 1)
        y = top_y + (bottom_y - top_y) * t
        half = top_half + (bottom_half - top_half) * t ** 1.3
        z = top_z + (bottom_z - top_z) * t ** 0.8
        row = []
        for j in range(cols):
            u = j / (cols - 1)
            x = half * (2 * u - 1)
            zz = z - curve * (2 * u - 1) ** 2 * (0.3 + 0.7 * t)
            yy = y - (hem(u) if hem and i == rows - 1 else 0.0)
            row.append((x, yy, zz))
        out.append(row)
    return out


# Body signed distance (rest pose), for the accessory clipping check -----------------------------


def _sd_box(p, cx, cy, cz, hx, hy, hz, r=0.0):
    q = (abs(p[0] - cx) - hx + r, abs(p[1] - cy) - hy + r, abs(p[2] - cz) - hz + r)
    outside = math.sqrt(sum(max(v, 0.0) ** 2 for v in q))
    return outside + min(max(q), 0.0) - r


def body_sdf(p, skip=()):
    """Signed distance (R6 studs) from p to the rest-pose body; negative
    inside. `skip` leaves out limbs (an accessory that encases them)."""
    best = 1e9
    for name, (cx, w, y0, y1) in LIMBS.items():
        if name in skip:
            continue
        best = min(best, _sd_box(p, cx, (y0 + y1) / 2, 0.0, w / 2, (y1 - y0) / 2, DEPTH / 2, BEVEL))
    if "Head" not in skip:
        best = min(best, head_sdf(p))
    return best


# An accessory surface closer than this to the body and facing the same way
# flickers against it in game (z-fighting); a sliver (square studs) is
# allowed where a piece meets the body edge-on.
FLAT_GAP = 0.008
FLAT_LIMIT = 0.004


def _sdf_normal(p, skip=(), e=0.004):
    """The body's outward normal near p (the gradient of body_sdf)."""
    g = Vector([body_sdf((p[0] + d[0] * e, p[1] + d[1] * e, p[2] + d[2] * e), skip)
                - body_sdf((p[0] - d[0] * e, p[1] - d[1] * e, p[2] - d[2] * e), skip)
                for d in ((1, 0, 0), (0, 1, 0), (0, 0, 1))])
    return g.normalized() if g.length > 1e-6 else g


def head_sdf(p):
    """Signed distance to the classic head (a rounded cylinder)."""
    dxz = math.hypot(p[0], p[2]) - (HEAD_R - HEAD_CORNER)
    dy = abs(p[1] - (HEAD_Y0 + HEAD_H / 2)) - (HEAD_H / 2 - HEAD_CORNER)
    return math.hypot(max(dxz, 0.0), max(dy, 0.0)) + min(max(dxz, dy), 0.0) - HEAD_CORNER


# The avatar ------------------------------------------------------------------------------------------


class Piece:
    def __init__(self, name, mb, bind, sink, encases, check=True):
        self.name, self.mb, self.bind, self.sink, self.encases, self.check = name, mb, bind, sink, encases, check


class Sway:
    """A chain of sway bones (capes, scarves, long hair): `points` in R6
    studs from the attach point down; one bone per segment, named <name>1,
    <name>2, ... The game swings them with springs."""

    def __init__(self, name, parent, points, stiffness=0.35, damping=0.18, limit=60.0, behind=None):
        self.name, self.parent = name, parent
        self.points = [tuple(p) for p in points]
        self.stiffness, self.damping, self.limit, self.behind = stiffness, damping, limit, behind

    @property
    def bones(self):
        return [f"{self.name}{i + 1}" for i in range(len(self.points) - 1)]

    def rig_points(self):
        return [tuple(round(c * S, 3) for c in p) for p in self.points]


class Avatar:
    """What a legend script builds on: styles for accessory swatches, pieces
    (accessory meshes bound to a bone or sway chain), sway chains."""

    def __init__(self, module):
        self.module = module
        self.name = module.NAME
        self.styles = {}
        self.pieces = []
        self.sways = []
        self.warnings = []

    def style(self, key, style):
        self.styles[key] = style
        return key

    def builder(self):
        """A MeshBuilder in R6 studs; colors are style keys."""
        return MeshBuilder("piece", _StylePalette(self), space=Matrix.Identity(3))

    def piece(self, mb, bone=None, sway=None, name="Piece", sink=0.05, encases=(), check=True):
        """Adds built geometry, bound rigidly to `bone` or swinging on `sway`.
        `sink` is how far it may dip into the body; `encases` lists limbs it
        is meant to cover (mech arms) and may sit inside."""
        if not (bone or sway):
            raise ValueError(f"{name}: give a bone or a sway chain")
        self.pieces.append(Piece(name, mb, ("sway", sway) if sway else ("bone", bone), sink, encases, check))

    def sway(self, *args, **kw):
        s = Sway(*args, **kw)
        self.sways.append(s)
        return s

    # head helpers ---------------------------------------------------------------

    @staticmethod
    def head_point(angle, y, out=0.0):
        """A point on the head surface: angle in degrees around from the front
        (positive toward the fighter's right), height y, pushed `out`."""
        r = HEAD_R
        top = HEAD_TOP - HEAD_CORNER
        bottom = HEAD_Y0 + HEAD_CORNER
        if y > top:
            a = math.asin(min(1.0, (y - top) / HEAD_CORNER))
            r = HEAD_R - HEAD_CORNER + HEAD_CORNER * math.cos(a)
        elif y < bottom:
            a = math.asin(min(1.0, (bottom - y) / HEAD_CORNER))
            r = HEAD_R - HEAD_CORNER + HEAD_CORNER * math.cos(a)
        th = math.radians(angle)
        n = Vector((math.sin(th), 0.0, -math.cos(th)))
        if y > top:
            a = math.asin(min(1.0, (y - top) / HEAD_CORNER))
            n = (n * math.cos(a) + Vector((0, 1, 0)) * math.sin(a)).normalized()
        p = Vector((r * math.sin(th), y, -r * math.cos(th))) + n * out
        return p, n


class _StylePalette(Palette):
    """A palette whose keys are the avatar's style keys (the swatch image
    itself is never used)."""

    def __init__(self, avatar):
        self.name = avatar.name
        self.colors = {k: "#ffffff" for k in avatar.styles}
        self.index = {key: i for i, key in enumerate(self.colors)}
        self.material = None
        self.image = None


# Skinning, armature, export ------------------------------------------------------------------------


def body_bone(limb, p):
    """Rigid weights for a body vertex: its bone, or a 50/50 blend on a
    hinge loop."""
    if limb == "Head":
        return {"Neck": 1.0}
    y = p[1]
    for split, below, above in SPLITS[limb]:
        if abs(y - split) < 1e-4:
            return {below: 0.5, above: 0.5}
    if limb.endswith("Leg") and y >= HIP_Y - 0.065:
        return {f"{limb[:-3]}Hip": 1.0}
    bone = None
    for split, below, above in SPLITS[limb]:
        bone = below if y < split else above
        if y < split:
            return {below: 1.0}
    return {bone: 1.0}


def _project(p, a, b):
    p, a, b = Vector(p), Vector(a), Vector(b)
    ab = b - a
    t = (p - a).dot(ab) / max(ab.length_squared, 1e-9)
    tc = max(0.0, min(1.0, t))
    return t * ab.length, (p - (a + ab * tc)).length


def sway_weights(p, sway, root_share=0.15):
    """Blend down the chain by the nearest segment, with a little of the
    parent bone at the top."""
    best = None
    for i, (a, b) in enumerate(zip(sway.points, sway.points[1:])):
        t, d = _project(p, a, b)
        if best is None or d < best[1]:
            best = (i, d, t, (Vector(b) - Vector(a)).length)
    i, _, t, length = best
    frac = max(0.0, min(1.0, t / length))
    bones = sway.bones
    w = {bones[i]: 1.0}
    if i == 0:
        w[sway.parent] = root_share * (1 - frac)
    if i + 1 < len(bones) and frac > 0.6:
        w[bones[i + 1]] = (frac - 0.6) / 0.4 * 0.5
    if i > 0 and frac < 0.4:
        w[bones[i - 1]] = (0.4 - frac) / 0.4 * 0.5
    total = sum(w.values())
    return {k: v / total for k, v in w.items()}


def build_armature(name, sways, collection):
    arm_data = bpy.data.armatures.new(name)
    arm = bpy.data.objects.new(name, arm_data)
    collection.objects.link(arm)
    bpy.context.view_layer.objects.active = arm
    for o in bpy.context.view_layer.objects:
        o.select_set(o is arm)
    bpy.ops.object.mode_set(mode="EDIT")
    eb = arm_data.edit_bones
    for joint, _, _, pivot in skeleton.JOINTS:
        b = eb.new(joint)
        b.head = RIG_TO_BLENDER @ Vector(pivot)
        b.tail = RIG_TO_BLENDER @ Vector(skeleton.tail(joint))
        b.roll = 0.0
    for joint, _, _, _ in skeleton.JOINTS:
        parent = skeleton.PARENT_JOINT[joint]
        if parent:
            eb[joint].parent = eb[parent]
            eb[joint].use_connect = False
    for sw in sways:
        prev = sw.parent
        pts = sw.rig_points()
        for bone, (a, b_) in zip(sw.bones, zip(pts, pts[1:])):
            e = eb.new(bone)
            e.head = RIG_TO_BLENDER @ Vector(a)
            e.tail = RIG_TO_BLENDER @ Vector(b_)
            e.parent = eb[prev]
            e.use_connect = prev != sw.parent
            prev = bone
    bpy.ops.object.mode_set(mode="OBJECT")
    arm.data.display_type = "STICK"
    return arm


def triangles(obj):
    return sum(len(p.vertices) - 2 for p in obj.data.polygons)


def apply_modifiers(obj):
    dg = bpy.context.evaluated_depsgraph_get()
    me = bpy.data.meshes.new_from_object(obj.evaluated_get(dg))
    old = obj.data
    obj.modifiers.clear()
    obj.data = me
    bpy.data.meshes.remove(old)
    return obj


def melt(mb, voxel=0.022, smooth=3, tris=None, carve_head=False):
    """Remeshes a builder's pieces into one smooth surface (hair, manes),
    optionally carved out where it would be inside the head (so a hairdo
    built from overlapping blobs ends cleanly on the scalp) and decimated.
    Returns a new builder holding the result."""
    bm = mb.bm
    mesh = bpy.data.meshes.new("melt")
    bm.to_mesh(mesh)
    obj = bpy.data.objects.new("melt", mesh)
    bpy.context.scene.collection.objects.link(obj)
    m = obj.modifiers.new("Remesh", "REMESH")
    m.mode = "VOXEL"
    m.voxel_size = voxel
    m.adaptivity = 0.0
    if smooth:
        sm = obj.modifiers.new("Smooth", "LAPLACIANSMOOTH")
        sm.iterations = smooth
        sm.lambda_factor = 0.5
        sm.use_volume_preserve = True
        sm.use_normalized = True
    apply_modifiers(obj)
    if tris and triangles(obj) > tris:
        d = obj.modifiers.new("Decimate", "DECIMATE")
        d.ratio = tris / triangles(obj)
        d.use_collapse_triangulate = True
        apply_modifiers(obj)
    if carve_head:
        # drop everything more than a hair's width inside the scalp; the open
        # edge left behind is hidden inside the head
        cb = bmesh.new()
        cb.from_mesh(obj.data)
        bmesh.ops.delete(cb, geom=[v for v in cb.verts if head_sdf(tuple(v.co)) < -0.012], context="VERTS")
        cb.to_mesh(obj.data)
        cb.free()
    # the dominant style of the source becomes the style of the result
    layer = bm.faces.layers.int.get("color")
    counts = {}
    for f in bm.faces:
        counts[f[layer]] = counts.get(f[layer], 0) + 1
    style = max(counts, key=counts.get) if counts else 0
    out = MeshBuilder(mb.name, mb.palette, space=Matrix.Identity(3))
    out.bm.from_mesh(obj.data)
    lay = out.bm.faces.layers.int.get("color") or out.bm.faces.layers.int.new("color")
    for f in out.bm.faces:
        f[lay] = style
    out.color_layer = lay
    data = obj.data
    bpy.data.objects.remove(obj)
    bpy.data.meshes.remove(data)
    return out


def _face_center(face):
    return sum((v.co for v in face.verts), Vector()) / len(face.verts)


class Build:
    """One avatar build: body mesh + pieces -> UVs, weights, atlas."""

    def __init__(self, avatar, preview=False):
        self.av = avatar
        self.atlas = Atlas()
        self.painter = None
        self.preview = preview  # sway pieces ride their parent bone (no sway bones)

    def body_bmesh(self):
        bm = bmesh.new()
        layer = bm.faces.layers.int.new("limb")
        tags = {name: i for i, name in enumerate(list(LIMBS) + ["Head"])}
        for name in LIMBS:
            _block(bm, name, layer, tags[name])
            if name.endswith("Leg"):
                before = set(bm.faces)
                _leg_dome(bm, name)
                for f in set(bm.faces) - before:
                    f[layer] = tags[name]
        _head(bm, layer, tags["Head"])
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
        return bm, layer, {i: n for n, i in tags.items()}

    def _alloc_swatches(self):
        swatches = {}
        for key, st in self.av.styles.items():
            w, h = st.size
            rect = self.atlas.alloc(w, h)
            c = Canvas(self.atlas, rect, 1.0, 0.0, 1.0, 0.0, f"swatch.{key}")
            swatches[key] = c
        return swatches

    def run(self):
        av = self.av
        av.module.model(av)
        swatches = self._alloc_swatches()
        self.painter = Painter(self.atlas, swatches)
        self.atlas.pack()
        for key, st in av.styles.items():
            st.paint(swatches[key])
        av.module.paint(av, self.painter)
        self.painter.finish()

        objs = []
        # body
        bm, layer, limb_of = self.body_bmesh()
        uv = bm.loops.layers.uv.new("UVMap")
        for f in bm.faces:
            limb = limb_of[f[layer]]
            n = f.normal
            if limb == "Head":
                if abs(n.y) > 0.72:
                    canvas = self.painter.head.top if n.y > 0 else self.painter.head.bottom
                    for loop in f.loops:
                        p = loop.vert.co
                        loop[uv].uv = canvas.uv(p.x, p.z)
                else:
                    center = _face_center(f)
                    th_c = math.atan2(center.x, -center.z)
                    for loop in f.loops:
                        p = loop.vert.co
                        th = math.atan2(p.x, -p.z)
                        if th - th_c > math.pi:
                            th -= 2 * math.pi
                        elif th_c - th > math.pi:
                            th += 2 * math.pi
                        loop[uv].uv = self.painter.head.band_canvas(th_c).uv(th * HEAD_R, p.y)
            else:
                lb = self.painter.limbs[limb]
                canvas = lb.canvas_for(n)
                for loop in f.loops:
                    a, b = lb.coords(canvas, loop.vert.co)
                    loop[uv].uv = canvas.uv(a, b)
        weights = []
        for v in bm.verts:
            f = v.link_faces[0]
            weights.append(body_bone(limb_of[f[layer]], v.co))
        body = self._object(bm, "AvatarBody", weights)
        objs.append(body)
        self.body_boxes = self._body_boxes(body, weights)

        # pieces
        pieces = [pc for pc in av.pieces if pc.mb.bm.faces]
        for pc in pieces:
            bmesh.ops.recalc_face_normals(pc.mb.bm, faces=pc.mb.bm.faces)
            self._check(pc)
        self._check_pairs([pc for pc in pieces if pc.check])
        for pc in pieces:
            bm = pc.mb.bm
            self._piece_uvs(bm, pc.mb.palette)
            if pc.bind[0] == "bone":
                w = [{pc.bind[1]: 1.0} for _ in bm.verts]
            elif self.preview:
                w = [{pc.bind[1].parent: 1.0} for _ in bm.verts]
            else:
                w = [sway_weights(tuple(v.co), pc.bind[1]) for v in bm.verts]
            obj = self._object(bm, pc.name, w)
            objs.append(obj)
        return objs

    def _check(self, pc):
        """Warns when an accessory sinks into the body (beyond its allowance)
        or lies flat on it (z-fighting)."""
        if not pc.check:
            return
        skip = set(pc.encases)
        bm = pc.mb.bm
        bm.normal_update()
        deep = 0
        worst = 0.0
        for v in bm.verts:
            d = body_sdf(tuple(v.co), skip)
            if d < -pc.sink:
                deep += 1
                worst = min(worst, d)
        flat = 0.0  # area on the body's surface and facing the same way
        for f in bm.faces:
            c = f.calc_center_median()
            if abs(body_sdf(tuple(c), skip)) < FLAT_GAP and f.normal.dot(_sdf_normal(c, skip)) > 0.95:
                flat += f.calc_area()
        if deep:
            self.av.warnings.append(f"{pc.name}: {deep} vertices sink up to {-worst:.2f} studs into the body")
        if flat > FLAT_LIMIT:
            self.av.warnings.append(f"{pc.name}: {flat:.3f} square studs lie flat on the body (z-fighting); lift "
                                    f"them at least {FLAT_GAP} studs off it")

    def _check_pairs(self, pieces):
        """Warns when two accessories lie flat on each other (z-fighting).
        Pieces may sink into each other (a lock rooted in the hair, a tail in
        a scarf); only coincident surfaces flicker."""
        trees = [BVHTree.FromBMesh(pc.mb.bm) for pc in pieces]
        for a in pieces:
            for b, tree in zip(pieces, trees):
                if a is b:
                    continue
                area = 0.0
                for f in a.mb.bm.faces:
                    c = f.calc_center_median()
                    hit = tree.find_nearest(c, FLAT_GAP)
                    if hit[0] is not None and abs(f.normal.dot(hit[1])) > 0.95:
                        area += f.calc_area()
                if area > FLAT_LIMIT:
                    self.av.warnings.append(f"{a.name}: {area:.3f} square studs lie flat on {b.name} (z-fighting); "
                                            f"lift them at least {FLAT_GAP} studs off it")

    def _piece_uvs(self, bm, palette):
        layer = bm.faces.layers.int.get("color")
        keys = list(palette.colors)
        uv = bm.loops.layers.uv.get("UVMap") or bm.loops.layers.uv.new("UVMap")
        # extents per style
        ext = {}
        for f in bm.faces:
            k = keys[f[layer]]
            e = ext.setdefault(k, [Vector((1e9, 1e9, 1e9)), Vector((-1e9, -1e9, -1e9)), Vector(), 0])
            for v in f.verts:
                for i in range(3):
                    e[0][i] = min(e[0][i], v.co[i])
                    e[1][i] = max(e[1][i], v.co[i])
                e[2] += v.co
                e[3] += 1
        for f in bm.faces:
            k = keys[f[layer]]
            st = self.av.styles[k]
            canvas = self.painter.swatches[k]
            lo, hi, total, count = ext[k]
            center = total / max(count, 1)
            hy = max(hi.y - lo.y, 1e-4)
            fc = _face_center(f)
            th_c = math.atan2(fc.x - center.x, -(fc.z - center.z))
            for loop in f.loops:
                p = loop.vert.co
                v = (p.y - lo.y) / hy
                if st.projection == "front":
                    u = (hi.x - p.x) / max(hi.x - lo.x, 1e-4)
                elif st.projection == "side":
                    u = (hi.z - p.z) / max(hi.z - lo.z, 1e-4)
                else:
                    th = math.atan2(p.x - center.x, -(p.z - center.z))
                    if th - th_c > math.pi:
                        th -= 2 * math.pi
                    elif th_c - th > math.pi:
                        th += 2 * math.pi
                    u = 0.5 - th / (2 * math.pi)
                u = min(max(u, 0.0), 1.0)
                v = min(max(v, 0.0), 1.0)
                loop[uv].uv = canvas.uv(u, v)

    def _object(self, bm, name, weights):
        """bmesh in R6 studs -> a Blender object in rig scale with weights."""
        mesh = bpy.data.meshes.new(name)
        bm.verts.ensure_lookup_table()
        bmesh.ops.transform(bm, matrix=(RIG_TO_BLENDER * S).to_4x4(), verts=bm.verts)
        bm.to_mesh(mesh)
        bm.free()
        obj = bpy.data.objects.new(name, mesh)
        bpy.context.scene.collection.objects.link(obj)
        groups = {}
        for i, w in enumerate(weights):
            for bone, val in w.items():
                g = groups.get(bone)
                if g is None:
                    g = groups[bone] = obj.vertex_groups.new(name=bone)
                g.add([i], val, "REPLACE")
        return obj

    def _body_boxes(self, body, weights):
        """Rig-space boxes of the body vertices each joint moves most (the
        game's invisible proxy parts)."""
        lo, hi = {}, {}
        to_rig = RIG_TO_BLENDER.transposed()
        for v, w in zip(body.data.vertices, weights):
            joint = max(w, key=w.get)
            part = PART_OF.get(joint)
            if part is None:
                continue
            p = to_rig @ v.co
            a = lo.setdefault(part, [math.inf] * 3)
            b = hi.setdefault(part, [-math.inf] * 3)
            for i in range(3):
                a[i] = min(a[i], p[i])
                b[i] = max(b[i], p[i])
        return {part: {"center": [round((lo[part][i] + hi[part][i]) / 2, 3) for i in range(3)],
                       "size": [round(max(0.05, hi[part][i] - lo[part][i]), 3) for i in range(3)]} for part in lo}


def _join(objects, name):
    bpy.ops.object.select_all(action="DESELECT")
    for o in objects:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objects[0]
    bpy.ops.object.join()
    obj = bpy.context.view_layer.objects.active
    obj.name = name
    obj.data.name = name
    return obj


def _material(name, maps):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    bsdf = nt.nodes.get("Principled BSDF")
    for channel, sock in (("color", "Base Color"), ("metal", "Metallic"), ("rough", "Roughness")):
        t = nt.nodes.new("ShaderNodeTexImage")
        t.image = maps[channel]
        nt.links.new(t.outputs["Color"], bsdf.inputs[sock])
    for key in ("Specular IOR Level", "Specular"):
        if key in bsdf.inputs:
            bsdf.inputs[key].default_value = 0.4
            break
    return m


def assemble(module, preview=False):
    """Builds the avatar into one skinned, painted object on its armature.
    Returns (avatar, build, body, armature, maps). `preview` builds into the
    current scene without saving the textures."""
    if not preview:
        common.reset_scene()
    av = Avatar(module)
    b = Build(av, preview)
    objs = b.run()
    body = _join(objs, "Body")
    for p in body.data.polygons:
        p.use_smooth = False
    # smooth shading inside curved pieces, crisp block edges
    try:
        body.data.set_sharp_from_angle(angle=math.radians(38))
        for p in body.data.polygons:
            p.use_smooth = True
    except AttributeError:
        pass
    bpy.ops.object.select_all(action="DESELECT")
    body.select_set(True)
    bpy.context.view_layer.objects.active = body
    bpy.ops.object.vertex_group_limit_total(limit=4)
    bpy.ops.object.vertex_group_normalize_all(lock_active=False)
    maps = b.atlas.save(av.name, None if preview else EXPORT_DIR)
    mat = _material(av.name, maps)
    body.data.materials.clear()
    body.data.materials.append(mat)
    col = bpy.context.scene.collection
    arm = build_armature("SkyRig", [] if preview else av.sways, col)
    body.parent = arm
    mod = body.modifiers.new("Armature", "ARMATURE")
    mod.object = arm
    return av, b, body, arm, maps


def export(av, b, body, arm):
    markers = common.add_markers(RIG_TO_BLENDER, bpy.context.scene.collection)
    path = os.path.join(common.ensure_dir(EXPORT_DIR), f"{av.name}.fbx")
    bpy.ops.object.select_all(action="DESELECT")
    for o in [arm, body] + markers:
        o.select_set(True)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.export_scene.fbx(
        filepath=path,
        use_selection=True,
        object_types={"ARMATURE", "MESH"},
        apply_unit_scale=True,
        apply_scale_options="FBX_SCALE_UNITS",
        mesh_smooth_type="FACE",
        use_mesh_modifiers=False,
        add_leaf_bones=False,
        primary_bone_axis="Y",
        secondary_bone_axis="X",
        use_armature_deform_only=True,
        armature_nodetype="NULL",
        bake_anim=False,
        path_mode="COPY",
        embed_textures=True,
        axis_forward="Z",
        axis_up="Y",
    )
    to_rig = RIG_TO_BLENDER.transposed()
    info = {
        "name": av.name,
        "style": "classic",
        "height": round(max((to_rig @ v.co).y for v in body.data.vertices), 3),
        "triangles": triangles(body),
        "parts": b.body_boxes,
        "clipping": av.warnings,
        "sways": [{"name": s.name, "parent": s.parent, "points": [list(p) for p in s.rig_points()],
                   "stiffness": s.stiffness, "damping": s.damping, "limit": s.limit, "behind": s.behind}
                  for s in av.sways],
    }
    with open(os.path.join(EXPORT_DIR, f"{av.name}.json"), "w") as f:
        json.dump(info, f, indent=1, sort_keys=True)
    for o in markers:
        bpy.data.objects.remove(o)
    print(f"[{av.name}] {path} ({info['triangles']} triangles, height {info['height']})")
    if info["triangles"] > TRI_BUDGET:
        print(f"[{av.name}] WARNING {info['triangles']} triangles is over the {TRI_BUDGET} budget")
    for w in av.warnings:
        print(f"[{av.name}] WARNING {w}")
    return info


# Previews ------------------------------------------------------------------------------------------


def _preview_scene(path, w, h):
    common.setup_preview_render(path, w, h, background=(0.78, 0.82, 0.88))
    scene = bpy.context.scene
    scene.eevee.taa_render_samples = 32
    world = scene.world
    world.node_tree.nodes.get("Background").inputs["Strength"].default_value = 1.15
    for o in scene.objects:
        if o.type == "LIGHT":
            o.data.energy = 2.6
    fill = bpy.data.lights.new("Fill", "SUN")
    fill.energy = 0.8
    fo = bpy.data.objects.new("Fill", fill)
    fo.rotation_euler = (math.radians(60), 0, math.radians(150))
    scene.collection.objects.link(fo)
    return scene


def render_turnaround(av, body, arm, path, size=(2000, 760), spacing=3.4):
    """Front / 3-4 / side / back in Roblox plastic."""
    col = bpy.data.collections.new("Avatar")
    bpy.context.scene.collection.children.link(col)
    for o in (body, arm):
        for c in o.users_collection:
            c.objects.unlink(o)
        col.objects.link(o)
    layer = bpy.context.view_layer.layer_collection.children[col.name]
    layer.exclude = True
    angles = (0, 40, 90, 180)
    for i, ang in enumerate(angles):
        inst = bpy.data.objects.new(f"View{i}", None)
        inst.instance_type = "COLLECTION"
        inst.instance_collection = col
        inst.location = (i * spacing, 0, 0)
        inst.rotation_euler = (0, 0, math.radians(ang))
        bpy.context.scene.collection.objects.link(inst)
    w, h = size
    _preview_scene(path, w, h)
    width = len(angles) * spacing
    ortho = max(width, 7.0 * w / h)
    cx = (len(angles) - 1) * spacing / 2
    common.ortho_camera("PreviewCam", (cx, -40, 3.1), (cx, 0, 3.1), ortho)
    out = common.render(path)
    # face close-up
    cam = bpy.context.scene.camera
    cam.location = (0, -40, (HEAD_Y0 + HEAD_H * 0.5) * S)
    cam.data.ortho_scale = 2.6
    bpy.context.scene.render.resolution_x = 700
    bpy.context.scene.render.resolution_y = 700
    common.render(os.path.join(os.path.dirname(path), f"{av.name}_face.png"))
    return out


def render_lineup(names, path=None, spacing=5.4):
    """All the exported fighters side by side, turned three-quarters toward
    the camera, from their FBX files."""
    common.reset_scene()
    placed = 0
    for name in names:
        fbx = os.path.join(EXPORT_DIR, f"{name}.fbx")
        if not os.path.exists(fbx):
            continue
        before = set(bpy.context.scene.objects)
        bpy.ops.import_scene.fbx(filepath=fbx)
        new = [o for o in bpy.context.scene.objects if o not in before]
        root = next((o for o in new if o.type == "ARMATURE"), None)
        for o in new:
            if o.name.startswith("Marker_"):
                bpy.data.objects.remove(o)
        if root:
            root.location = (placed * spacing, 0, 0)
            root.rotation_euler = (root.rotation_euler[0], root.rotation_euler[1], math.radians(-25))
        placed += 1
    path = path or os.path.join(PREVIEW_DIR, "lineup.png")
    w, h = 3200, 900
    _preview_scene(path, w, h)
    cx = (placed - 1) * spacing / 2
    common.ortho_camera("LineupCam", (cx, -40, 3.2), (cx, 0, 3.2), max(placed * spacing, 7.2 * w / h))
    return common.render(path)


def preview_body(module):
    """The avatar's skinned body (painted) for animation contact sheets,
    built into the current scene; sway pieces ride their parent bones."""
    av, b, body, arm, maps = assemble(module, preview=True)
    body.parent = None
    body.modifiers.clear()
    bpy.data.objects.remove(arm)
    return body


def build(module, preview=True):
    """Runs a legend script (fighters/<name>.py with model(av) and
    paint(av, p))."""
    av, b, body, arm, maps = assemble(module)
    info = export(av, b, body, arm)
    face = getattr(module, "face", None)
    if face:
        face_decal(f"{av.name}_face", face)
    if preview:
        render_turnaround(av, body, arm, os.path.join(PREVIEW_DIR, f"{av.name}.png"))
    return info
