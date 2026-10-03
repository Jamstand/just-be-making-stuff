"""
items/bubbleblaster.py - the BubbleBlaster item (ReplicatedStorage.ItemMeshes.BubbleBlaster): a chunky
toy bubble gun in bright plastic. See items/__init__.py for the conventions.

A fat sky-blue barrel (one lathe: a round rear cap with a yellow pump knob, a waist ring, then a
taper to the nozzle) pointing FRONT (-Y), a big pink bubble-wand ring at the muzzle held coaxially by
three thin spokes, a see-through soap tank on top (purple soap in the lower half, a liquid line and a
couple of bubbles in it, a yellow screw cap), a yellow pistol handle raked back with grip ribs, a
trigger inside a trigger guard, and white bubble stickers on both sides. Tones are cut along the
surface normal like the props; the glossy plastic gets a painted highlight from the bake.

1 unit = 1 stud: ~2.0 long, ~1.75 tall (handle foot to tank cap). Origin = the floor under it (the handle's foot rests on
z = 0); `_Grip` = the middle of the handle (the fist; the barrel points forward out of it), `_Tip` =
the centre of the wand ring (where the bubble comes out).
"""
import math
from mathutils import Matrix, Vector
import sockkit as K
from sockkit import M, hexcol
import items
from props.toycar import _lathe, _patch
from items.staticballoon import bvh_of, no_bounce, tone

NAME = "BubbleBlaster"

MATERIALS = {"bubbleblaster_body": "plastic", "bubbleblaster_accent": "plastic", "bubbleblaster_ring": "plastic",
             "bubbleblaster_tank": "glass", "bubbleblaster_soap": "glass", "bubbleblaster_sticker": "decal",
             "bubbleblaster_rib": "plastic"}


def _colours():
    """Registers this item's palette colours. Called by build(), not at import: build_all.py imports
    every item module before it builds the socks, so colours registered at import would take palette
    cells ahead of the socks' (items must come last, see items/__init__.py)."""
    global BODY, ACCENT, RING, TANK, SOAP, STICKER, HOLE
    BODY = (hexcol("bubbleblaster_body_light", "#86E3FF"), hexcol("bubbleblaster_body", "#35B6EE"),
            hexcol("bubbleblaster_body_dark", "#1F7FC4"))
    ACCENT = (hexcol("bubbleblaster_accent_light", "#FFE56B"), hexcol("bubbleblaster_accent", "#FFC22E"),
              hexcol("bubbleblaster_accent_dark", "#E3891A"))
    RING = (hexcol("bubbleblaster_ring_light", "#FF9DCD"), hexcol("bubbleblaster_ring", "#FF5AA5"),
            hexcol("bubbleblaster_ring_dark", "#CF3881"))
    TANK = (hexcol("bubbleblaster_tank_light", "#EEFBFF"), hexcol("bubbleblaster_tank", "#C2EEFF"),
            hexcol("bubbleblaster_tank_dark", "#90CDEA"))
    SOAP = (hexcol("bubbleblaster_soap_light", "#E3B2FF"), hexcol("bubbleblaster_soap", "#B978EE"),
            hexcol("bubbleblaster_soap_dark", "#8C4FCB"))
    STICKER = hexcol("bubbleblaster_sticker", "#FFFFFF")
    HOLE = hexcol("bubbleblaster_hole", "#24304E")


OUTLINE_W = 0.04
CUTS = (-0.4, 0.62)            # normal z: shade / base / lit
AXIS_Z = 1.0                   # barrel axis height
R_BODY = 0.27                  # barrel radius
RING_Y = -1.02                 # wand ring centre (y)
RING_R, RING_T = 0.36, 0.072   # wand ring radius, tube radius
TANK_Y, TANK_R, TANK_H = 0.14, 0.19, 0.4
HANDLE_Y, HANDLE_RAKE = 0.36, 0.26   # handle centre (y at the barrel) and its backward lean (rad)
GRIP = Vector((0.0, 0.43, 0.45))
TIP = Vector((0.0, RING_Y, AXIS_Z))


def _col(cols):
    return lambda tag, n: tone(cols, n.z, CUTS)


def _barrel():
    """Rear cap (+Y) to the nozzle (-Y): local +X of the lathe = world -Y."""
    rot = M((0, 0, AXIS_Z), rot=(0, 0, -math.pi / 2))
    R = R_BODY
    prof = [(-0.78, 0.0, "b"), (-0.775, 0.12, "b"), (-0.745, 0.2, "b"), (-0.69, 0.25, "b"), (-0.6, R, "b"),
            (0.12, R, "b"), (0.3, R * 0.97, "b"), (0.44, R * 0.84, "b"), (0.56, 0.16, "b"), (0.7, 0.13, "b"),
            (0.82, 0.13, "b"), (0.82, 0.0, None)]
    barrel = _lathe(prof, 24, rot, _col(BODY), "barrel")
    # a yellow waist band, the pump knob on the back and the nozzle collar
    band = _lathe([(-0.1, 0.0, "a"), (-0.1, R + 0.025, "a"), (-0.06, R + 0.04, "a"), (0.06, R + 0.04, "a"),
                   (0.1, R + 0.025, "a"), (0.1, 0.0, None)], 24, rot, _col(ACCENT), "band")
    knob = _lathe([(-0.94, 0.0, "a"), (-0.93, 0.07, "a"), (-0.89, 0.11, "a"), (-0.82, 0.12, "a"), (-0.74, 0.12, "a"),
                   (-0.74, 0.0, None)], 18, rot, _col(ACCENT), "knob")
    collar = _lathe([(0.76, 0.0, "a"), (0.76, 0.165, "a"), (0.8, 0.18, "a"), (0.9, 0.18, "a"), (0.92, 0.15, "a"),
                     (0.92, 0.1, "h"), (0.9, 0.0, None)], 20, rot,
                    lambda tag, n: HOLE if tag == "h" else tone(ACCENT, n.z, CUTS), "collar")
    return [barrel, band, knob, collar]


def _wand():
    """The big pink ring at the muzzle and the three spokes holding it on the collar."""
    m = M((0, RING_Y, AXIS_Z), rot=(math.pi / 2, 0, 0))
    ring = K.torus(RING[1], RING_R, RING_T, m, seg=32, mseg=10, name="ring")
    K.recolor_by(ring, lambda c, cur: tone(RING, (c - Vector((0, RING_Y, AXIS_Z))).normalized().z * 0.9, CUTS))
    out = [ring]
    y0, y1 = -0.84, RING_Y
    for k in range(3):
        a = math.radians(90 + 120 * k)
        d = Vector((math.cos(a), 0, math.sin(a)))
        p0 = Vector((0, y0, AXIS_Z)) + d * 0.16
        p1 = Vector((0, y1, AXIS_Z)) + d * (RING_R - 0.02)
        ax = (p1 - p0)
        mat = Matrix.Translation((p0 + p1) / 2) @ ax.to_track_quat("Z", "Y").to_matrix().to_4x4()
        out.append(K.cylinder(RING[2], 0.028, ax.length, mat, seg=6, name="spoke"))
    return out


def _tank():
    """A see-through soap bottle on top: glass above, purple soap below, a screw cap."""
    z0 = AXIS_Z + R_BODY - 0.06
    zl = z0 + TANK_H * 0.55       # soap level
    zt = z0 + TANK_H
    rot = M((0, TANK_Y, 0), rot=(0, -math.pi / 2, 0))   # lathe +X -> world +Z

    def col(tag, n):
        if tag == "soap":
            return tone(SOAP, n.z, CUTS)
        if tag == "line":
            return SOAP[0]
        return tone(TANK, n.z, CUTS)
    r = TANK_R
    bottle = _lathe([(z0 - 0.04, 0.0, "soap"), (z0 - 0.04, r * 0.82, "soap"), (z0 + 0.02, r, "soap"), (zl - 0.012, r, "line"),
                     (zl + 0.012, r, "glass"), (zt - 0.07, r, "glass"), (zt - 0.02, r * 0.8, "glass"),
                     (zt, r * 0.62, "glass"), (zt, 0.0, None)], 22, rot, col, "tank")
    cap = _lathe([(zt - 0.03, 0.0, "a"), (zt - 0.03, r * 0.72, "a"), (zt + 0.09, r * 0.72, "a"), (zt + 0.11, r * 0.6, "a"),
                  (zt + 0.11, 0.0, None)], 18, rot, _col(ACCENT), "cap")
    # little bubbles floating in the soap, on the side facing out front-left
    bubbles = []
    for (a, z, rr) in ((-2.2, zl - 0.07, 0.03), (-1.75, zl - 0.12, 0.022), (-2.55, zl - 0.15, 0.018)):
        c = Vector((math.cos(a) * (r + 0.003), TANK_Y + math.sin(a) * (r + 0.003), z))
        n = Vector((math.cos(a), math.sin(a), 0))
        mat = Matrix.Translation(c) @ n.to_track_quat("Z", "Y").to_matrix().to_4x4()
        bubbles.append(K.cylinder(SOAP[0], rr, 0.006, mat, seg=8, outline=False, name="soap_bubble"))
    return [bottle, cap] + bubbles


def _handle():
    """A pistol grip raked back, with three ribs down its front for the fingers."""
    h = 0.92
    top = Vector((0, HANDLE_Y, AXIS_Z - 0.08))
    d = Vector((0, math.sin(HANDLE_RAKE), -math.cos(HANDLE_RAKE)))   # down the handle
    c = top + d * (h / 2)
    m = M(c, rot=(HANDLE_RAKE, 0, 0))
    grip = K.rounded_box(ACCENT[1], (0.22, 0.3, h), m, bevel=0.1, segments=3, name="handle")
    K.recolor_by(grip, lambda q, cur: ACCENT[0] if q.x < -0.09 else (ACCENT[2] if q.x > 0.09 else ACCENT[1]))
    ribs = []
    front = Vector((0, -math.cos(HANDLE_RAKE), -math.sin(HANDLE_RAKE)))   # the handle's front face normal
    for k in range(3):
        q = top + d * (0.34 + 0.15 * k) + front * 0.135
        mat = Matrix.Translation(q) @ Matrix.Rotation(math.pi / 2, 4, "Y")
        ribs.append(K.cylinder(ACCENT[2], 0.035, 0.2, mat, seg=8, name="rib"))
    # the foot: a little flared pad at the bottom (the model stands on it)
    foot_c = top + d * (h - 0.02)
    ribs.append(K.rounded_box(ACCENT[2], (0.26, 0.36, 0.08), M(foot_c, rot=(HANDLE_RAKE, 0, 0)), bevel=0.035, segments=2,
                              name="foot"))
    return [grip] + ribs


def _trigger():
    out = []
    # trigger: a curved hook under the barrel in front of the handle
    pts = [(0, 0.1, AXIS_Z - 0.2), (0, 0.03, AXIS_Z - 0.33), (0, 0.06, AXIS_Z - 0.44), (0, 0.13, AXIS_Z - 0.47)]
    out.append(K.tube(ACCENT[1], pts, radius=0.05, radii=[1.0, 1.0, 0.9, 0.7], res=4, bevel_res=2, name="trigger"))
    # trigger guard: from the barrel's belly round under the trigger into the handle's front
    g = [(0, -0.2, AXIS_Z - 0.22), (0, -0.21, AXIS_Z - 0.48), (0, -0.04, AXIS_Z - 0.6), (0, 0.22, AXIS_Z - 0.6),
         (0, 0.4, AXIS_Z - 0.58)]
    out.append(K.tube(BODY[2], g, radius=0.04, res=5, bevel_res=2, name="guard"))
    return out


def _stickers(bvh):
    """White bubble stickers on both sides of the barrel: rings with a glint."""
    out = []
    for s in (-1, 1):
        along = Vector((-s, 0, 0))
        du = Vector((0, s, 0))
        dv = Vector((0, 0, 1))
        for (y, z, r) in ((0.32, AXIS_Z + 0.03, 0.1), (0.08, AXIS_Z - 0.07, 0.065), (-0.06, AXIS_Z + 0.09, 0.045)):
            o = Vector((s * 0.3, y, z))

            def circ(rad):
                return lambda rr, t: (rad * rr * math.cos(t), rad * rr * math.sin(t))
            out.append(_patch(bvh, o, along, du, dv, circ(r), 0.006, STICKER, "sticker", rings=1, seg=18, inner=0.74))
    return out


def build():
    _colours()
    barrel = _barrel()
    bvh = bvh_of(barrel[:1])
    p = barrel + _wand() + _tank() + _handle() + _trigger() + _stickers(bvh)
    low = min(v.co.z for pc in p for v in pc.mesh.vertices)   # stand the handle's foot on the floor
    for pc in p:
        pc.mesh.transform(Matrix.Translation((0, 0, -low)))
    body, outline = K.finish(p, NAME, outline_width=OUTLINE_W)
    no_bounce(outline)
    up = Vector((0, 0, -low))
    return [body, outline] + K.markers(NAME) + [items.grip(NAME, GRIP + up), K.marker(NAME + "_Tip", TIP + up)]


BUILDERS = {NAME: build}
