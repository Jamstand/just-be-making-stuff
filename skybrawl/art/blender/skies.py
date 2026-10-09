"""
Fallback sky backdrops: one painted-looking 2048x1024 PNG per map, rendered
in Blender from layered flat shapes (an orthographic camera looking at a
stack of 2D cut-outs: a vertical gradient, banded halos, toon clouds and
distant silhouettes). The game uses these when no hand-painted sky exists.

    python art/blender/build.py skies               # all four
    python art/blender/build.py sky VolcanicForge   # just one

Outputs art/export/skies/<MapId>.png. The middle and lower-middle of every
sky is kept calm so fighters read on top of it.
"""

import math
import os
import random

import bpy

from sky import common

W, H = 2048, 1024
PX = 0.01  # pixels -> Blender units
SKY_DIR = os.path.join(common.EXPORT_DIR, "skies")
NAMES = ["SkyShip", "VolcanicForge", "FrozenPeaks", "JungleTemple"]


# Colors -----------------------------------------------------------------------


def _lin(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def srgb(color):
    """'#rrggbb' or an (r, g, b) tuple in 0..1 sRGB."""
    return common.hex_color(color) if isinstance(color, str) else tuple(color[:3])


def mix(a, b, t):
    a, b = srgb(a), srgb(b)
    return tuple(x + (y - x) * t for x, y in zip(a, b))


def rgba(color, alpha=1.0):
    r, g, b = srgb(color)
    return (_lin(r), _lin(g), _lin(b), alpha)


# Canvas -----------------------------------------------------------------------


class Canvas:
    """2D drawing surface in pixel coordinates (x right, y up, 0..2048 x
    0..1024). `layer` orders shapes back to front."""

    def __init__(self, seed):
        common.reset_scene()
        self.rng = random.Random(seed)
        self.count = 0
        self.material = self._material()
        scene = bpy.context.scene
        scene.render.engine = "BLENDER_EEVEE_NEXT"
        scene.eevee.taa_render_samples = 32
        scene.render.resolution_x = W
        scene.render.resolution_y = H
        scene.render.resolution_percentage = 100
        scene.render.film_transparent = False
        scene.render.filter_size = 1.2
        scene.view_settings.view_transform = "Standard"
        scene.view_settings.look = "None"
        world = bpy.data.worlds.new("SkyWorld")
        scene.world = world
        world.use_nodes = True
        world.node_tree.nodes["Background"].inputs["Color"].default_value = (0, 0, 0, 1)
        cam_data = bpy.data.cameras.new("SkyCam")
        cam_data.type = "ORTHO"
        cam_data.ortho_scale = W * PX
        cam_data.clip_start = 0.1
        cam_data.clip_end = 500
        cam = bpy.data.objects.new("SkyCam", cam_data)
        cam.location = (0, -200, 0)
        cam.rotation_euler = (math.radians(90), 0, 0)
        scene.collection.objects.link(cam)
        scene.camera = cam

    @staticmethod
    def _material():
        mat = bpy.data.materials.new("SkyPaint")
        mat.use_nodes = True
        nt = mat.node_tree
        nt.nodes.clear()
        out = nt.nodes.new("ShaderNodeOutputMaterial")
        col = nt.nodes.new("ShaderNodeVertexColor")
        col.layer_name = "Col"
        emit = nt.nodes.new("ShaderNodeEmission")
        clear = nt.nodes.new("ShaderNodeBsdfTransparent")
        mixer = nt.nodes.new("ShaderNodeMixShader")
        nt.links.new(col.outputs["Color"], emit.inputs["Color"])
        nt.links.new(col.outputs["Alpha"], mixer.inputs[0])
        nt.links.new(clear.outputs[0], mixer.inputs[1])
        nt.links.new(emit.outputs[0], mixer.inputs[2])
        nt.links.new(mixer.outputs[0], out.inputs["Surface"])
        if hasattr(mat, "surface_render_method"):
            mat.surface_render_method = "BLENDED"
        else:
            mat.blend_method = "BLEND"
        return mat

    def mesh(self, verts, faces, colors, layer):
        """verts: [(x, y)] pixels; colors: one linear RGBA per vertex."""
        self.count += 1
        depth = -layer * 0.05 - self.count * 1e-5
        mesh = bpy.data.meshes.new(f"Shape{self.count}")
        mesh.from_pydata([((x - W / 2) * PX, 0.0, (y - H / 2) * PX) for x, y in verts], [], faces)
        attr = mesh.color_attributes.new(name="Col", type="FLOAT_COLOR", domain="POINT")
        for i, c in enumerate(colors):
            attr.data[i].color = c
        mesh.materials.append(self.material)
        obj = bpy.data.objects.new(f"Shape{self.count}", mesh)
        obj.location = (0, depth, 0)
        bpy.context.scene.collection.objects.link(obj)
        return obj

    # primitives ------------------------------------------------------------

    def poly(self, pts, color, layer, alpha=1.0):
        c = rgba(color, alpha)
        return self.mesh(pts, [list(range(len(pts)))], [c] * len(pts), layer)

    def vgrad(self, x0, x1, stops, layer):
        """Rectangle with a vertical gradient. stops: [(y, color, alpha)]
        from bottom to top."""
        verts, colors, faces = [], [], []
        for i, (y, color, alpha) in enumerate(stops):
            verts += [(x0, y), (x1, y)]
            colors += [rgba(color, alpha)] * 2
            if i:
                a = 2 * (i - 1)
                faces.append([a, a + 1, a + 3, a + 2])
        return self.mesh(verts, faces, colors, layer)

    def disc(self, cx, cy, r, color, layer, alpha=1.0, segs=48, ry=None):
        ry = r if ry is None else ry
        pts = [(cx + r * math.cos(2 * math.pi * i / segs), cy + ry * math.sin(2 * math.pi * i / segs))
               for i in range(segs)]
        return self.poly(pts, color, layer, alpha)

    def halo(self, cx, cy, r0, r1, color, layer, bands=5, alpha=0.18):
        """Banded (cel) glow: stacked translucent discs."""
        for i in range(bands):
            t = i / max(1, bands - 1)
            self.disc(cx, cy, r1 + (r0 - r1) * t, color, layer + i * 0.01, alpha, segs=72)

    def soft_disc(self, cx, cy, r, color, layer, alpha=0.5, segs=48, ry=None):
        """Disc whose alpha fades to zero at the rim."""
        ry = r if ry is None else ry
        verts = [(cx, cy)] + [(cx + r * math.cos(2 * math.pi * i / segs), cy + ry * math.sin(2 * math.pi * i / segs))
                              for i in range(segs)]
        faces = [[0, 1 + i, 1 + (i + 1) % segs] for i in range(segs)]
        colors = [rgba(color, alpha)] + [rgba(color, 0.0)] * segs
        return self.mesh(verts, faces, colors, layer)

    def band(self, y0, y1, color, layer, alpha=0.4, feather=0.5):
        """Horizontal haze band across the canvas, fading out at both edges."""
        mid0 = y0 + (y1 - y0) * feather * 0.5
        mid1 = y1 - (y1 - y0) * feather * 0.5
        return self.vgrad(-10, W + 10, [(y0, color, 0.0), (mid0, color, alpha), (mid1, color, alpha),
                                        (y1, color, 0.0)], layer)

    def ridge(self, pts, color, layer, alpha=1.0, base=-20):
        """Silhouette from a ridge polyline down past the bottom edge."""
        shape = [(pts[0][0], base)] + list(pts) + [(pts[-1][0], base)]
        return self.poly(shape, color, layer, alpha)

    def ridge_grad(self, pts, top_color, bottom_color, y_bottom, layer, alpha=1.0, bottom_alpha=None):
        """Ridge silhouette that fades to `bottom_color` toward y_bottom."""
        verts, colors, faces = [], [], []
        ba = alpha if bottom_alpha is None else bottom_alpha
        for i, (x, y) in enumerate(pts):
            verts += [(x, y_bottom), (x, y)]
            colors += [rgba(bottom_color, ba), rgba(top_color, alpha)]
            if i:
                a = 2 * (i - 1)
                faces.append([a, a + 2, a + 3, a + 1])
        return self.mesh(verts, faces, colors, layer)

    def cloud(self, cx, cy, w, h, colors, layer, alpha=1.0, bumps=None, flat=True, shade=0.3, light=True,
              flip=False, rim=None):
        """Toon cumulus: a flat-bottomed puff (upper envelope of circles)
        drawn in three tones: shadow base, lit body, highlight cap.
        colors = (shadow, body, highlight). `flip` hangs it upside down
        (bumps pointing down, lit from below)."""
        rng = self.rng
        n = bumps or max(3, int(w / (h * 0.9)))
        circles = []
        for i in range(n):
            t = (i + 0.5) / n
            k = math.sin(t * math.pi)
            r = h * (0.35 + 0.55 * k) * rng.uniform(0.8, 1.15)
            circles.append((cx - w / 2 + w * t + rng.uniform(-0.15, 0.15) * w / n, cy + r * 0.25 * k - r * 0.12 *
                            (1 - k), r))
        poly = self.poly
        if flip:
            def poly(pts, color, lay, a):  # mirror about the cloud's baseline
                return self.poly([(x, 2 * cy - y) for x, y in reversed(pts)], color, lay, a)

        def env(x, grow=0.0, lift=0.0):
            best = None
            for bx, by, r in circles:
                rr = r + grow
                dx = x - bx
                if abs(dx) < rr:
                    y = by + lift + math.sqrt(rr * rr - dx * dx)
                    best = y if best is None or y > best else best
            return best

        def shape(grow, lift, bottom):
            xs = [cx - w / 2 - h + i * (w + 2 * h) / 160 for i in range(161)]
            top = [(x, env(x, grow, lift)) for x in xs]
            top = [(x, y) for x, y in top if y is not None and y > bottom(x) + 1]
            if len(top) < 3:
                return None
            # round the ends off down to the baseline instead of a sheer drop
            (xs0, ys0), (xs1, ys1) = top[0], top[-1]
            d0, d1 = ys0 - bottom(xs0), ys1 - bottom(xs1)
            head = [(xs0 - d0 * 0.8 * math.sin(a), bottom(xs0) + d0 * math.cos(a))
                    for a in [math.pi / 2 * k / 6 for k in range(6, 0, -1)]]
            tail = [(xs1 + d1 * 0.8 * math.sin(a), bottom(xs1) + d1 * math.cos(a))
                    for a in [math.pi / 2 * k / 6 for k in range(1, 7)]]
            pts = head + top + tail
            bot = [(x, bottom(x)) for x, _ in reversed(top[1:-1])][::6]
            return pts + bot

        base = (lambda x: cy - h * 0.05) if flat else (lambda x: cy - h * 0.1 + h * 0.08 * math.sin(x * 0.02))
        if rim:  # (color, offset, layer): a lit edge peeking out past the cloud
            pts = shape(rim[1] * 0.4, rim[1], base)
            if pts:
                poly(pts, rim[0], rim[2], alpha)
        pts = shape(0.0, 0.0, base)
        if pts:
            poly(pts, colors[0], layer, alpha)
        lit_bottom = lambda x: cy + h * shade + h * 0.06 * math.sin(x * 0.035 + cx)
        pts = shape(-h * 0.03, h * 0.02, lit_bottom)
        if pts:
            poly(pts, colors[1], layer + 0.01, alpha)
        if light and len(colors) > 2:
            hi_bottom = lambda x: cy + h * (shade + 0.45) + h * 0.05 * math.sin(x * 0.05 + cy)
            pts = shape(-h * 0.1, h * 0.0, hi_bottom)
            if pts:
                poly(pts, colors[2], layer + 0.02, alpha)

    def streak_cloud(self, cx, cy, w, h, color, layer, alpha=0.6, lit=None, lit_alpha=0.8):
        """Long soft stratus streak: opaque-ish core, feathered top and
        bottom, tapered ends. `lit` adds a glowing underside."""
        n = 36
        verts, colors, faces = [], [], []
        for i in range(n + 1):
            t = i / n
            x = cx - w / 2 + w * t
            k = math.sin(t * math.pi) ** 0.6
            wav = 1 + 0.25 * math.sin(t * 7 + cx * 0.01)
            yc = cy + h * 0.15 * math.sin(t * 4 + cy * 0.01)
            rows = [(yc - h * 0.5 * k, 0.0), (yc - h * 0.15 * k, alpha * k), (yc + h * 0.2 * k * wav, alpha * k),
                    (yc + h * 0.55 * k * wav, 0.0)]
            for y, a in rows:
                verts.append((x, y))
                colors.append(rgba(color, a))
            if i:
                o = 4 * (i - 1)
                for j in range(3):
                    faces.append([o + j, o + 4 + j, o + 5 + j, o + 1 + j])
        self.mesh(verts, faces, colors, layer)
        if lit:
            verts, colors, faces = [], [], []
            for i in range(n + 1):
                t = i / n
                x = cx - w * 0.4 + w * 0.8 * t
                k = math.sin(t * math.pi) ** 0.8
                yc = cy + h * 0.15 * math.sin((0.1 + 0.8 * t) * 4 + cy * 0.01) - h * 0.32 * k
                for y, a in ((yc - h * 0.12 * k, 0.0), (yc, lit_alpha * k), (yc + h * 0.12 * k, 0.0)):
                    verts.append((x, y))
                    colors.append(rgba(lit, a))
                if i:
                    o = 3 * (i - 1)
                    for j in range(2):
                        faces.append([o + j, o + 3 + j, o + 4 + j, o + 1 + j])
            self.mesh(verts, faces, colors, layer + 0.01)

    def crescent(self, cx, cy, r, color, layer, phase=0.45, tilt=-30.0, segs=48):
        """Crescent moon: the outer arc minus an offset inner circle."""
        off = r * phase
        ta = math.radians(tilt)
        ox, oy = math.cos(ta) * off, math.sin(ta) * off
        pts = []
        outer = [(cx + r * math.cos(2 * math.pi * i / segs), cy + r * math.sin(2 * math.pi * i / segs))
                 for i in range(segs)]
        inside = [math.hypot(x - cx - ox, y - cy - oy) < r * 0.96 for x, y in outer]
        start = next(i for i in range(segs) if inside[i] and not inside[(i + 1) % segs])
        i = (start + 1) % segs
        while not inside[i]:
            pts.append(outer[i])
            i = (i + 1) % segs
        a0 = math.atan2(pts[-1][1] - cy - oy, pts[-1][0] - cx - ox)
        a1 = math.atan2(pts[0][1] - cy - oy, pts[0][0] - cx - ox)
        while a1 > a0:
            a1 -= 2 * math.pi
        for k in range(1, 24):
            a = a0 + (a1 - a0) * k / 24
            pts.append((cx + ox + r * 0.96 * math.cos(a), cy + oy + r * 0.96 * math.sin(a)))
        return self.poly(pts, color, layer)

    def rays(self, ox, oy, angles, width, length, color, layer, alpha=0.12):
        """Sunbeams fanning from (ox, oy); angles in degrees (0 = down)."""
        for a in angles:
            ra = math.radians(a)
            dx, dy = math.sin(ra), -math.cos(ra)
            px, py = -dy, dx
            w0, w1 = width * 0.15, width
            verts = [(ox + px * w0, oy + py * w0), (ox - px * w0, oy - py * w0),
                     (ox + dx * length - px * w1, oy + dy * length - py * w1),
                     (ox + dx * length + px * w1, oy + dy * length + py * w1)]
            colors = [rgba(color, alpha), rgba(color, alpha), rgba(color, 0.0), rgba(color, 0.0)]
            self.mesh(verts, [[0, 1, 2, 3]], colors, layer)

    def curtain(self, pts, colors_bottom, color_top, layer, alpha=0.55):
        """Aurora curtain: a strip along `pts` [(x, y_bottom, height)] whose
        color fades from the bottom color to transparent at the top."""
        verts, colors, faces = [], [], []
        m = len(pts)
        for i, (x, y, h) in enumerate(pts):
            cb = colors_bottom[i % len(colors_bottom)]
            verts += [(x, y), (x, y + h * 0.35), (x, y + h)]
            fade = math.sin(i / (m - 1) * math.pi) ** 0.6
            colors += [rgba(cb, alpha * 0.25 * fade), rgba(cb, alpha * fade), rgba(color_top, 0.0)]
            if i:
                a = 3 * (i - 1)
                faces.append([a, a + 3, a + 4, a + 1])
                faces.append([a + 1, a + 4, a + 5, a + 2])
        return self.mesh(verts, faces, colors, layer)

    def stars(self, count, y_min, color, layer, size=(1.4, 3.2), alpha=(0.5, 1.0)):
        rng = self.rng
        for _ in range(count):
            x, y = rng.uniform(0, W), rng.uniform(y_min, H)
            s = rng.uniform(*size)
            if rng.random() < 0.15:
                s *= 1.6
                pts = [(x, y + s * 2.2), (x + s * 0.4, y + s * 0.4), (x + s * 2.2, y), (x + s * 0.4, y - s * 0.4),
                       (x, y - s * 2.2), (x - s * 0.4, y - s * 0.4), (x - s * 2.2, y), (x - s * 0.4, y + s * 0.4)]
                self.poly(pts, color, layer, rng.uniform(*alpha))
            else:
                self.disc(x, y, s, color, layer, rng.uniform(*alpha), segs=8)

    def render(self, path):
        common.ensure_dir(os.path.dirname(path))
        scene = bpy.context.scene
        scene.render.filepath = path
        scene.render.image_settings.file_format = "PNG"
        scene.render.image_settings.color_mode = "RGB"
        bpy.ops.render.render(write_still=True)
        print(f"[sky] {path} ({self.count} shapes)")
        return path


# Shared scenery -----------------------------------------------------------------


def ridge_line(rng, x0, x1, base, peaks, jag=0.0, step=None, peak_index=None):
    """Polyline through `peaks` [(x, height)] with optional jagged detail.
    If `peak_index` is a list, the index of each peak is appended to it."""
    pts = [(x0, base)]
    prev = (x0, base)
    for k, (x, h) in enumerate(peaks + [(x1, 0)]):
        y = base + h
        if jag and step:
            n = max(1, int(abs(x - prev[0]) / step))
            for i in range(1, n):
                t = i / n
                px = prev[0] + (x - prev[0]) * t
                py = prev[1] + (y - prev[1]) * t + rng.uniform(-jag, jag)
                pts.append((px, py))
        pts.append((x, y))
        if peak_index is not None and k < len(peaks):
            peak_index.append(len(pts) - 1)
        prev = (x, y)
    return pts


def floating_isle(c, cx, cy, w, top, rock, rock_dark, layer, rng, trees=None, fall=None):
    """Distant floating island silhouette: grassy cap, faceted rock below,
    a waterfall spilling from its edge."""
    h = w * 0.72
    n = 9
    under = []
    for i in range(1, n):
        t = i / n
        depth = h * (math.sin(t * math.pi) ** 0.75) * (0.72 + 0.2 * rng.random())
        under.append((cx - w / 2 + w * t + rng.uniform(-0.03, 0.03) * w, cy - depth))
    tip = (cx + rng.uniform(-0.1, 0.1) * w, cy - h * 1.02)
    under.insert(n // 2, tip)
    under.sort(key=lambda p: p[0])
    pts = [(cx - w / 2, cy)] + under + [(cx + w / 2, cy)]
    if fall:
        x = cx + w * rng.uniform(0.12, 0.3)
        c.vgrad(x - w * 0.03, x + w * 0.03, [(cy - h * 1.9, fall, 0.0), (cy - h * 0.7, fall, 0.6),
                                               (cy - w * 0.02, fall, 0.85)], layer - 0.01)
    c.poly(pts, rock, layer)
    k = under.index(tip)
    shadow = [(cx + w * 0.08, cy)] + under[k:] + [(cx + w / 2, cy)]
    c.poly(shadow, rock_dark, layer + 0.01)
    cap = [(cx - w / 2 - w * 0.04, cy - w * 0.02), (cx + w / 2 + w * 0.04, cy - w * 0.02),
           (cx + w / 2 - w * 0.02, cy + w * 0.05), (cx - w / 2 + w * 0.02, cy + w * 0.05)]
    c.poly(cap, top, layer + 0.02)
    if trees:
        for i in range(rng.randint(1, 2)):
            tx = cx + rng.uniform(-0.3, 0.25) * w
            r = w * rng.uniform(0.07, 0.1)
            for dx, dy, rr in ((-0.8, 0.5, 0.8), (0.0, 0.9, 1.0), (0.8, 0.5, 0.8)):
                c.disc(tx + dx * r, cy + w * 0.04 + dy * r, r * rr, trees, layer + 0.015, segs=20)


# The four skies -------------------------------------------------------------------


def sky_ship(path):
    """Golden afternoon: warm cumulus banks and drifting floating islands."""
    c = Canvas(101)
    rng = c.rng
    top, bottom = "#5c9ee6", "#ffd6aa"
    c.vgrad(-10, W + 10, [(-10, "#ffc994", 1), (180, bottom, 1), (420, mix(bottom, top, 0.45), 1),
                          (700, mix(bottom, top, 0.82), 1), (H + 10, "#4a8ddc", 1)], 0)
    # low golden sun with a banded halo
    c.halo(1530, 300, 80, 220, "#fff1c4", 1, bands=3, alpha=0.07)
    c.soft_disc(1530, 300, 520, "#ffe9b8", 1.05, alpha=0.25)
    c.disc(1530, 300, 62, "#fff6dc", 1.2, segs=64)
    c.band(150, 330, "#ffe2b8", 1.5, alpha=0.35)
    # far floating islands, hazy blue-lavender
    for cx, cy, w in ((250, 450, 120), (760, 540, 70), (1190, 480, 90), (1830, 580, 110), (1430, 660, 55)):
        floating_isle(c, cx, cy, w, "#c3c8e2", "#aab1d6", "#979ec8", 2, rng, trees="#b4bfdc", fall="#eef2fa")
    # soft high streaks
    for cx, cy, w, h in ((420, 900, 640, 46), (1250, 960, 760, 50), (1850, 870, 460, 36), (900, 820, 380, 28)):
        c.streak_cloud(cx, cy, w, h, "#eef4fc", 3, alpha=0.55)
    # upper cumulus at the corners
    c.cloud(170, 790, 440, 120, ("#c3cbe6", "#f1f1f6", "#ffffff"), 4)
    c.cloud(1920, 820, 480, 130, ("#c3cbe6", "#f1f1f6", "#ffffff"), 4)
    # golden cloud banks along the bottom, three depths
    for cx, cy, w, h, layer, cols in (
            (300, 120, 700, 150, 5, ("#e9b48c", "#ffd9b0", "#fff0d6")),
            (1050, 90, 800, 170, 5, ("#e9b48c", "#ffd9b0", "#fff0d6")),
            (1800, 130, 650, 160, 5, ("#e9b48c", "#ffd9b0", "#fff0d6")),
            (650, 20, 900, 180, 6, ("#d99f7f", "#ffcfa6", "#ffe9cc")),
            (1550, 0, 1000, 190, 6, ("#d99f7f", "#ffcfa6", "#ffe9cc")),
            (100, -40, 500, 160, 7, ("#cf9478", "#f7c19c", "#ffe0c0")),
            (1100, -60, 700, 170, 7, ("#cf9478", "#f7c19c", "#ffe0c0")),
            (2000, -30, 500, 160, 7, ("#cf9478", "#f7c19c", "#ffe0c0"))):
        c.cloud(cx, cy, w, h, cols, layer)
    return c.render(path)


def volcanic_forge(path):
    """Red-orange ash sky over a ring of volcanoes."""
    c = Canvas(202)
    rng = c.rng
    top, bottom = "#3a1b2e", "#e0663a"
    c.vgrad(-10, W + 10, [(-10, "#f07a3a", 1), (140, bottom, 1), (360, "#b8473a", 1), (600, "#7a2c3a", 1),
                          (820, "#4f2134", 1), (H + 10, top, 1)], 0)
    # dim sun through the ash
    c.soft_disc(700, 830, 240, "#ff9a5a", 1, alpha=0.2)
    c.halo(700, 830, 44, 105, "#ffb070", 1.05, bands=3, alpha=0.06)
    c.disc(700, 830, 38, "#ffc58c", 1.2, alpha=0.8, segs=64)
    # heat haze near the horizon
    c.band(80, 300, "#ff9a50", 1.5, alpha=0.25)
    # far volcano range
    far = ridge_line(rng, -20, W + 20, 120, [(160, 70), (330, 150), (420, 120), (560, 200), (640, 185),
                                              (900, 90), (1150, 130), (1400, 80), (1620, 210), (1700, 205),
                                              (1880, 110), (2000, 150)], jag=8, step=40)
    c.ridge(far, "#8a3a3e", 2)

    def plume(cx, base_y, r0, lean, rise, layer):
        """Opaque, billowing smoke column that leans as it rises."""
        n = 18
        for i in range(n):
            t = i / (n - 1)
            r = r0 * (0.7 + t * 1.5) * rng.uniform(0.92, 1.08)
            px = cx + lean * t * t + rng.uniform(-0.15, 0.15) * r
            py = base_y + r0 * 0.6 + rise * t
            c.disc(px, py, r, mix("#4e2438", "#3a1c30", t), layer + i * 0.001, segs=40, ry=r * 0.85)
        # warm glow on the plume's underside, near the crater
        c.soft_disc(cx, base_y + r0 * 1.6, r0 * 2.6, "#ff8a3a", layer + 0.05, alpha=0.35, ry=r0 * 1.8)

    def volcano(cx, base, w, h, crater, body, shade, layer, smoke=None):
        pts = [(cx - w / 2, base), (cx - crater / 2 - w * 0.04, base + h * 0.93), (cx - crater / 2, base + h),
               (cx + crater / 2, base + h), (cx + crater / 2 + w * 0.04, base + h * 0.92), (cx + w / 2, base)]
        if smoke:
            plume(cx, base + h, crater * 0.55, smoke[0], smoke[1], layer - 0.2)
        c.ridge(pts, body, layer)
        c.poly([(cx + crater * 0.1, base + h), (cx + crater / 2, base + h), (cx + crater / 2 + w * 0.04,
                base + h * 0.92), (cx + w / 2, base), (cx + w * 0.12, base)], shade, layer + 0.01)
        c.poly([(cx - crater / 2, base + h), (cx + crater / 2, base + h), (cx + crater * 0.3, base + h + 6),
                (cx - crater * 0.3, base + h + 6)], "#ffb347", layer + 0.02)
        c.soft_disc(cx, base + h + 10, crater * 1.6, "#ff8a3a", layer + 0.015, alpha=0.45, ry=crater * 0.8)
        for k in (-0.2, 0.15):
            x0 = cx + k * crater
            spine = [(x0 + k * w * 0.5 * (i / 5) + rng.uniform(-5, 5), base + h * (1 - (i / 5) * 0.7))
                     for i in range(1, 6)]
            right = [(x + 2 + 3.5 * i / 5, y) for i, (x, y) in enumerate(spine, 1)]
            left = [(x - 2 - 3.5 * i / 5, y) for i, (x, y) in enumerate(spine, 1)]
            c.poly([(x0 - 4, base + h)] + left + list(reversed(right)) + [(x0 + 4, base + h)], "#ff7a2a",
                   layer + 0.02, alpha=0.9)

    volcano(1500, 60, 760, 330, 70, "#5a2636", "#47202f", 3, smoke=(260, 430))
    volcano(380, 40, 560, 230, 50, "#62293a", "#4c2131", 3.5, smoke=(-160, 300))
    # ash ceiling: hanging banded clouds lit orange from below
    for cx, cy, w, h, layer in ((260, 1050, 820, 170, 4), (1000, 1080, 960, 190, 4), (1820, 1040, 800, 170, 4),
                                (620, 1010, 560, 120, 4.4), (1460, 1000, 600, 120, 4.4)):
        c.cloud(cx, cy, w, h, ("#2f1626", "#3e1d33", "#4c243c"), layer, flip=True, shade=0.5, bumps=5,
                rim=("#c45a42", 9, 3.9))
    # near ridge of dark basalt
    near = ridge_line(rng, -20, W + 20, 0, [(120, 90), (260, 60), (420, 110), (700, 40), (1000, 60), (1300, 30),
                                            (1700, 100), (1880, 70), (2000, 120)], jag=10, step=30)
    c.ridge(near, "#3b1c2a", 5)
    # embers drifting up
    for _ in range(70):
        x, y = rng.uniform(0, W), rng.uniform(40, 700)
        c.disc(x, y, rng.uniform(1.5, 3.2), "#ffb347" if rng.random() < 0.6 else "#ff7a2a", 6,
               alpha=rng.uniform(0.5, 0.95), segs=6)
    return c.render(path)


def frozen_peaks(path):
    """Blue twilight: stars, aurora curtains and snowy peaks."""
    c = Canvas(303)
    rng = c.rng
    top, bottom = "#3b4f9a", "#c9d8f5"
    c.vgrad(-10, W + 10, [(-10, "#e2c9df", 1), (110, bottom, 1), (330, "#8fa9de", 1), (560, top, 1),
                          (800, "#27346f", 1), (H + 10, "#171f4c", 1)], 0)
    c.stars(220, 470, "#f4f7ff", 1, alpha=(0.35, 0.95))
    # crescent moon
    c.soft_disc(330, 840, 150, "#c9d6ff", 1.4, alpha=0.16)
    c.disc(330, 840, 58, "#dfe8ff", 1.45, alpha=0.12, segs=64)
    c.crescent(330, 840, 40, "#f3f6ff", 1.6, phase=0.42, tilt=20)
    # aurora curtains
    for k, (y0, amp, h, cols, a) in enumerate(((610, 70, 260, ["#5affc0", "#45f0d0", "#62ffb0"], 0.55),
                                                (700, 50, 220, ["#7d8bff", "#a070ff", "#62e0ff"], 0.42),
                                                (560, 40, 160, ["#68ffd0", "#7affa8"], 0.35))):
        pts = []
        n = 60
        x0, x1 = (-50, W + 50) if k != 2 else (700, 1900)
        for i in range(n + 1):
            t = i / n
            x = x0 + (x1 - x0) * t
            y = y0 + amp * math.sin(t * math.pi * 2.3 + k * 1.7) + 0.3 * amp * math.sin(t * 17 + k)
            pts.append((x, y, h * (0.7 + 0.3 * math.sin(t * 11 + k * 2))))
        c.curtain(pts, cols, "#2c3f86", 2 + k * 0.1, alpha=a)
    # thin high clouds catching the last light
    for cx, cy, w, h in ((1500, 920, 700, 40), (600, 970, 560, 34)):
        c.streak_cloud(cx, cy, w, h, "#5e6fb0", 3, alpha=0.45)
    # far peaks (pale, hazy)
    peaks = []
    far = ridge_line(rng, -20, W + 20, 120, [(140, 170), (300, 120), (480, 250), (640, 160), (820, 210),
                                              (1000, 120), (1180, 280), (1360, 170), (1540, 230), (1720, 140),
                                              (1900, 260), (2040, 180)], jag=7, step=30, peak_index=peaks)
    c.ridge(far, "#9fb3de", 3)
    snow_caps(c, far, peaks, "#e4ecfb", "#c3d0ee", "#8ea3d3", 3.0, depth=0.3, base=120)
    c.band(60, 260, "#d8e4fa", 3.2, alpha=0.5)
    # near peaks, two-tone toon snow
    peaks = []
    near = ridge_line(rng, -20, W + 20, 0, [(200, 300), (420, 170), (620, 260), (860, 110), (1100, 140),
                                            (1320, 90), (1560, 250), (1760, 180), (1960, 320)], jag=10, step=26,
                      peak_index=peaks)
    c.ridge(near, "#6a7fbf", 4)
    snow_caps(c, near, peaks, "#f6f9ff", "#c6d4f2", "#5466a6", 4.0, depth=0.42, base=0)
    c.band(-20, 120, "#e8eefc", 4.5, alpha=0.6)
    return c.render(path)


def snow_caps(c, pts, peaks, lit, shade, rock_shade, layer, depth=0.4, base=0.0):
    """Two-tone toon mountains: a shaded right flank for each summit and a
    snow cap (lit left, shaded right) down to a jagged snow line. `peaks`
    are the ridge's control-point indices (summits and saddles alike)."""
    rng = c.rng
    idx = [0] + list(peaks) + [len(pts) - 1]
    for k in range(1, len(idx) - 1):
        lo, pi, hi = idx[k - 1], idx[k], idx[k + 1]
        x, y = pts[pi]
        if not (y > pts[lo][1] and y > pts[hi][1]):
            continue
        vl = min(range(lo, pi + 1), key=lambda i: pts[i][1])
        vr = min(range(pi, hi + 1), key=lambda i: pts[i][1])
        height = y - max(pts[vl][1], pts[vr][1])
        if height < 40:
            continue
        # shaded right flank down to the saddle
        flank = pts[pi:vr + 1]
        vx = pts[vr][0]
        c.poly(flank + [(vx - (vx - x) * 0.3, base - 20), (x + (vx - x) * 0.04, base - 20)], rock_shade,
               layer + 0.005)
        cut = y - height * depth
        l = pi
        while l > vl and pts[l - 1][1] >= cut:
            l -= 1
        r = pi
        while r < vr and pts[r + 1][1] >= cut:
            r += 1
        lx = _cross(pts[l - 1], pts[l], cut) if l > vl else pts[l][0]
        rx = _cross(pts[r], pts[r + 1], cut) if r < vr else pts[r][0]
        line = []
        steps = 7
        for i in range(steps + 1):
            t = i / steps
            jag = height * 0.07 * (1 if i % 2 else -0.6) * (0 if i in (0, steps) else 1)
            line.append((rx + (lx - rx) * t, cut + jag + rng.uniform(-3, 3)))
        c.poly([(lx, cut)] + pts[l:r + 1] + [(rx, cut)] + line[1:-1], lit, layer + 0.01)
        right = pts[pi:r + 1] + [(rx, cut)] + [p for p in line[1:-1] if p[0] > x + (rx - x) * 0.05]
        right.append((x + (rx - x) * 0.05, cut + height * 0.08))
        if len(right) >= 3:
            c.poly(right, shade, layer + 0.02)


def _cross(a, b, ycut):
    (x0, y0), (x1, y1) = a, b
    if y1 == y0:
        return x0
    return x0 + (x1 - x0) * (ycut - y0) / (y1 - y0)


def jungle_temple(path):
    """Misty teal-green jungle valley with sunbeams and far ziggurats."""
    c = Canvas(404)
    rng = c.rng
    top, bottom = "#2f8f7a", "#f2e6a8"
    c.vgrad(-10, W + 10, [(-10, "#f6ecb4", 1), (200, bottom, 1), (430, "#bfdcaa", 1), (680, "#6fb595", 1),
                          (H + 10, top, 1)], 0)
    # sun glow at the top right and soft beams through the haze
    c.soft_disc(1560, 1000, 520, "#fff3c0", 1, alpha=0.3)
    c.halo(1560, 1000, 80, 200, "#fff6c8", 1.05, bands=3, alpha=0.07)
    c.disc(1560, 1000, 66, "#fffbe4", 1.1, segs=64)
    c.rays(1560, 1060, [-60, -47, -35, -22, -10, 4], 60, 950, "#fff7cf", 1.2, alpha=0.11)
    # misty floating islands with waterfalls
    for cx, cy, w in ((320, 720, 130), (760, 840, 70), (1240, 780, 90), (1880, 660, 110)):
        floating_isle(c, cx, cy, w, "#8fc4a8", "#86b8a2", "#77a894", 2, rng, trees="#7db99b", fall="#eef8f0")
    # puffy clouds high up on the left
    c.cloud(200, 860, 440, 100, ("#a8d4bd", "#d8eedc", "#f1f9ec"), 2.5, alpha=0.95)
    c.cloud(880, 905, 360, 80, ("#a8d4bd", "#d8eedc", "#f1f9ec"), 2.5, alpha=0.9)
    # far ridge with two ziggurats
    far = ridge_line(rng, -20, W + 20, 230, [(200, 60), (420, 30), (650, 90), (900, 40), (1150, 70), (1400, 30),
                                              (1650, 80), (1900, 45)], jag=6, step=40)
    c.ridge(far, "#9ccbae", 3)
    for zx, zy, zw in ((560, 300, 170), (1530, 290, 140)):
        y = zy
        w = zw
        for i in range(5):
            th = zw * 0.11
            c.poly([(zx - w / 2, y), (zx + w / 2, y), (zx + w / 2 - th * 0.3, y + th), (zx - w / 2 + th * 0.3, y + th)],
                   "#9ccbae" if i % 2 else "#a9d4b8", 3.02)
            y += th
            w *= 0.76
        c.poly([(zx - w * 0.35, y), (zx + w * 0.35, y), (zx + w * 0.35, y + zw * 0.12), (zx - w * 0.35, y + zw * 0.12)],
               "#a9d4b8", 3.03)
        c.poly([(zx - zw * 0.06, zy), (zx + zw * 0.06, zy), (zx + zw * 0.04, y), (zx - zw * 0.04, y)], "#b6dcc2", 3.04)
    c.band(200, 340, "#eef5d6", 3.2, alpha=0.6)
    # canopy layers: rounded tree crowns, darker and greener toward us
    for layer, base, size, cols, mist in ((4, 170, (40, 75), ("#7fb99a", "#8cc3a3"), 0.5),
                                          (5, 90, (50, 95), ("#5ea585", "#6bb08d"), 0.45),
                                          (6, 0, (60, 120), ("#3f8a6b", "#4c9775"), 0.0)):
        x = -60
        while x < W + 80:
            r = rng.uniform(*size)
            col = cols[0] if rng.random() < 0.5 else cols[1]
            c.disc(x, base + r * 0.35 + rng.uniform(-10, 18), r, col, layer, segs=36, ry=r * 0.82)
            if rng.random() < 0.3:
                c.disc(x + r * 0.4, base + r * 1.3, r * 0.6, col, layer, segs=28, ry=r * 0.5)
            x += r * 1.25
        c.poly([(-20, -20), (W + 20, -20), (W + 20, base + 20), (-20, base + 20)], cols[0], layer - 0.01)
        if mist:
            c.band(base - 40, base + 110, "#f2f6dc", layer + 0.5, alpha=mist)
    return c.render(path)


BUILDERS = {
    "SkyShip": sky_ship,
    "VolcanicForge": volcanic_forge,
    "FrozenPeaks": frozen_peaks,
    "JungleTemple": jungle_temple,
}


def build_all(names=None):
    out = []
    for name in names or NAMES:
        if name not in BUILDERS:
            raise SystemExit(f"unknown sky {name!r}; use one of: {', '.join(NAMES)}")
        out.append(BUILDERS[name](os.path.join(SKY_DIR, f"{name}.png")))
    return out
