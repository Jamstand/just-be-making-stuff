"""
Pose and clip authoring for the SkyRig (no Blender needed in this file).

A pose is a set of joint rotations in rig space, in degrees, as
(pitch, yaw, roll) = CFrame.Angles(x, y, z) on the joint:
    pitch +  arms and legs swing forward/up, elbows bend, the spine leans back,
             the head looks up; knees bend with -pitch, toes lift with +pitch
    yaw   +  twists toward the fighter's left
    roll  +  right arm/leg swings out to the side (left arm/leg: -roll)
plus a root offset (studs, rig space: x right, y up, z behind).

Clips are keyed poses. "Phased" clips (attacks) put keys in move phases:
0..1 is the startup, 1..2 the active frames, 2..3 the recovery, so they
line up with the hitboxes whatever the move's timing. Other clips are in
seconds. Each key's ease shapes the move to the next key, using Roblox
EasingStyle names ("Quad.Out", "Sine.InOut", "Linear", "Constant", ...).
"""

import math

from sky import skeleton

SHORT = {
    "root": "Root", "waist": "Waist", "neck": "Neck",
    "rsh": "RightShoulder", "rel": "RightElbow", "rwr": "RightWrist",
    "lsh": "LeftShoulder", "lel": "LeftElbow", "lwr": "LeftWrist",
    "rhip": "RightHip", "rknee": "RightKnee", "rank": "RightAnkle",
    "lhip": "LeftHip", "lknee": "LeftKnee", "lank": "LeftAnkle",
}
JOINTS = list(SHORT.values())
LEG_JOINTS = ["LeftHip", "LeftKnee", "LeftAnkle", "RightHip", "RightKnee", "RightAnkle"]
ARM_JOINTS = ["LeftShoulder", "LeftElbow", "LeftWrist", "RightShoulder", "RightElbow", "RightWrist"]

ROOT_PIVOT = skeleton.PIVOT["Root"]
HIP = {"Left": skeleton.PIVOT["LeftHip"], "Right": skeleton.PIVOT["RightHip"]}
THIGH = skeleton.THIGH
SHIN = skeleton.SHIN
ANKLE_HEIGHT = skeleton.ANKLE_HEIGHT

EASES = {"Linear", "Constant", "Quad", "Cubic", "Quart", "Quint", "Sine", "Exponential", "Circular"}


class Pose:
    __slots__ = ("rot", "offset")

    def __init__(self, rot=None, offset=(0.0, 0.0, 0.0)):
        self.rot = dict(rot or {})
        self.offset = tuple(offset)

    def copy(self):
        return Pose(self.rot, self.offset)

    def get(self, joint):
        return self.rot.get(joint, (0.0, 0.0, 0.0))

    def __or__(self, other):
        """Merge: `other` overrides joints it sets (and its offset if non-zero)."""
        out = self.copy()
        out.rot.update(other.rot)
        if any(abs(v) > 1e-9 for v in other.offset):
            out.offset = other.offset
        return out

    def only(self, joints):
        return Pose({j: v for j, v in self.rot.items() if j in joints}, self.offset)

    def without(self, joints):
        return Pose({j: v for j, v in self.rot.items() if j not in joints}, self.offset)

    def add(self, **kw):
        """Adds angles on top: add(rsh=(10, 0, 0))."""
        out = self.copy()
        for key, value in kw.items():
            if key == "off":
                out.offset = tuple(a + b for a, b in zip(out.offset, value))
                continue
            joint = SHORT[key]
            out.rot[joint] = tuple(a + b for a, b in zip(out.get(joint), value))
        return out


def P(off=(0.0, 0.0, 0.0), **joints):
    """P(off=(0, -0.3, 0), rsh=(90, 0, 10), rel=(40, 0, 0), ...)"""
    rot = {}
    for key, value in joints.items():
        if key not in SHORT:
            raise KeyError(f"unknown joint {key!r}")
        if isinstance(value, (int, float)):
            value = (value, 0, 0)
        rot[SHORT[key]] = tuple(float(v) for v in value)
    return Pose(rot, off)


REST = P()


def mirror(pose):
    """Swaps left and right."""
    rot = {}
    for joint, (p, y, r) in pose.rot.items():
        if joint.startswith("Left"):
            joint = "Right" + joint[4:]
        elif joint.startswith("Right"):
            joint = "Left" + joint[5:]
        rot[joint] = (p, -y, -r)
    x, y, z = pose.offset
    return Pose(rot, (-x, y, z))


def lerp_pose(a, b, t):
    rot = {}
    for joint in set(a.rot) | set(b.rot):
        pa, pb = a.get(joint), b.get(joint)
        rot[joint] = tuple(x + (y - x) * t for x, y in zip(pa, pb))
    off = tuple(x + (y - x) * t for x, y in zip(a.offset, b.offset))
    return Pose(rot, off)


def _unwrap(values):
    """Shifts angles by whole turns so consecutive values never differ by
    more than half a turn."""
    out = [values[0]]
    for v in values[1:]:
        prev = out[-1]
        while v - prev > 180:
            v -= 360
        while v - prev < -180:
            v += 360
        out.append(v)
    return out


def catmull_loop(values, steps):
    """Periodic Catmull-Rom spline through `values` (one per key, evenly
    spaced around the loop), sampled `steps` times over one loop."""
    n = len(values)
    out = []
    for s in range(steps):
        u = s * n / steps
        k = int(u)
        t = u - k
        p0, p1, p2, p3 = (values[(k - 1) % n], values[k % n], values[(k + 1) % n], values[(k + 2) % n])
        out.append(0.5 * (2 * p1 + (p2 - p0) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t
                          + (3 * p1 - p0 - 3 * p2 + p3) * t * t * t))
    return out


def smooth_loop_keys(poses, length, steps=16, ease="Linear"):
    """Keys for a cycle that flows through `poses` (evenly spaced over
    `length`) without slowing at any of them: a periodic spline through every
    joint angle and the root offset, sampled `steps` times. Eased keys at the
    poses themselves would stall there (an In/Out ease has zero speed at
    both ends), which reads as a hitch in a run."""
    joints = set()
    for p in poses:
        joints |= set(p.rot)
    sampled = [Pose({}, (0.0, 0.0, 0.0)) for _ in range(steps)]
    for joint in sorted(joints):
        channels = [catmull_loop(_unwrap([p.get(joint)[axis] for p in poses]), steps) for axis in range(3)]
        for s in range(steps):
            sampled[s].rot[joint] = (channels[0][s], channels[1][s], channels[2][s])
    channels = [catmull_loop([p.offset[axis] for p in poses], steps) for axis in range(3)]
    for s in range(steps):
        sampled[s].offset = (channels[0][s], channels[1][s], channels[2][s])
    return [(length * s / steps, pose, ease) for s, pose in enumerate(sampled)]


# Leg IK ------------------------------------------------------------------------


def _rot_x(deg, y, z):
    a = math.radians(deg)
    return y * math.cos(a) - z * math.sin(a), y * math.sin(a) + z * math.cos(a)


def plant(pose, lfoot=0.0, rfoot=0.0, lheight=0.0, rheight=0.0, toe=0.0):
    """Solves both legs so the ankles reach the given spots, in the side
    plane: `lfoot`/`rfoot` are the feet's z (negative = in front), `*height`
    lifts a foot off the ground. Feet stay flat unless `toe` tilts them. Uses
    the pose's root offset and root pitch."""
    out = pose.copy()
    root_pitch = pose.get("Root")[0]
    ox, oy, oz = pose.offset
    for side, fz, fh in (("Left", lfoot, lheight), ("Right", rfoot, rheight)):
        hx, hy, hz = HIP[side]
        ry, rz = _rot_x(root_pitch, hy - ROOT_PIVOT[1], hz - ROOT_PIVOT[2])
        hip_y = ROOT_PIVOT[1] + oy + ry
        hip_z = ROOT_PIVOT[2] + oz + rz
        dy = (ANKLE_HEIGHT + fh) - hip_y
        dz = fz - hip_z
        dist = math.hypot(dy, dz)
        reach = THIGH + SHIN - 1e-4
        phi = math.atan2(-dz, -dy)  # angle of hip->ankle from straight down
        if dist >= reach:
            thigh = phi
            knee = 0.0
        else:
            alpha = math.acos(max(-1.0, min(1.0, (THIGH ** 2 + dist ** 2 - SHIN ** 2) / (2 * THIGH * dist))))
            beta = math.acos(max(-1.0, min(1.0, (THIGH ** 2 + SHIN ** 2 - dist ** 2) / (2 * THIGH * SHIN))))
            thigh = phi + alpha
            knee = -(math.pi - beta)
        shin_world = thigh + knee
        # pitch here is about rig +X, while phi grows toward -Z (forward): same sign
        hip_pitch = math.degrees(thigh) - root_pitch
        out.rot[f"{side}Hip"] = (hip_pitch, 0.0, 0.0)
        out.rot[f"{side}Knee"] = (math.degrees(knee), 0.0, 0.0)
        out.rot[f"{side}Ankle"] = (-math.degrees(shin_world) + toe, 0.0, 0.0)
    return out


# Clips --------------------------------------------------------------------------


class Clip:
    def __init__(self, name, keys, phased=False, loop=False, length=None):
        self.name = name
        self.phased = phased
        self.loop = loop
        norm = []
        for key in keys:
            t, pose = key[0], key[1]
            ease = key[2] if len(key) > 2 else "Quad.Out"
            style = ease.split(".")[0]
            if style not in EASES:
                raise ValueError(f"{name}: unknown ease {ease!r}")
            norm.append((float(t), pose, ease))
        norm.sort(key=lambda k: k[0])
        # keep the arms out of the body (hands stay on their weapons), unless
        # that would make a joint whip round between keys
        cleaned = []
        for i, (t, pose, ease) in enumerate(norm):
            cand = clear_body(clear_hands(pose))
            near = [n for n in ((cleaned[-1][1] if cleaned else None), (norm[i + 1][1] if i + 1 < len(norm) else None))
                    if n is not None]
            ok = all(_max_turn(cand, n) < 145.0 or _max_turn(cand, n) <= _max_turn(pose, n) + 1.0 for n in near)
            cleaned.append((t, cand if ok else pose, ease))
        norm = cleaned
        self.keys = norm
        self.length = float(length if length is not None else (3.0 if phased else norm[-1][0]))
        if loop and norm[-1][0] < self.length - 1e-6:
            # close the loop on the first pose
            self.keys.append((self.length, norm[0][1], norm[0][2]))
        authored = {t for t, _, _ in self.keys}
        self.keys = split_big_turns(self.keys)
        # in-betweens added for big turns get cleared too, unless that would
        # make a joint flip round between them and their neighbors
        keys = list(self.keys)
        for i, (t, pose, ease) in enumerate(keys):
            if t in authored:
                continue
            cleared = clear_body(clear_hands(pose))
            near = [keys[j][1] for j in (i - 1, i + 1) if 0 <= j < len(keys)]
            if all(_max_turn(cleared, n) < 150.0 for n in near):
                keys[i] = (t, cleared, ease)
        self.keys = keys


CLIPS = {}


def clip(name, keys, phased=False, loop=False, length=None):
    if name in CLIPS:
        raise ValueError(f"duplicate clip {name}")
    c = Clip(name, keys, phased, loop, length)
    CLIPS[name] = c
    return c


def attack(name, keys):
    """A phased clip (0-1 startup, 1-2 active, 2-3 recovery)."""
    return clip(name, keys, phased=True)


def spin_keys(t0, t1, pose0, pose1, degrees, axis="yaw", steps=None, ease="Linear"):
    """Keys that turn the root `degrees` (any amount) between two times."""
    steps = steps or max(2, int(math.ceil(abs(degrees) / 120.0)))
    keys = []
    idx = 0 if axis == "pitch" else 1
    for i in range(steps + 1):
        a = i / steps
        pose = lerp_pose(pose0, pose1, a)
        p = list(pose.get("Root"))
        p[idx] += degrees * a
        pose.rot["Root"] = tuple(p)
        keys.append((t0 + (t1 - t0) * a, pose, ease))
    return keys


# Arm and weapon aiming ---------------------------------------------------------
# Directions are in rig space. dir2d(angle) is a direction in the side plane
# (the plane the camera sees): 0 = straight ahead, 90 = up, 180 = behind,
# -90 = down. `out` leans it toward the camera side (+X, the right side).


def _m_rot(deg):
    p, y, r = (math.radians(d) for d in deg)
    cx, sx, cy, sy, cz, sz = math.cos(p), math.sin(p), math.cos(y), math.sin(y), math.cos(r), math.sin(r)
    rx = ((1, 0, 0), (0, cx, -sx), (0, sx, cx))
    ry = ((cy, 0, sy), (0, 1, 0), (-sy, 0, cy))
    rz = ((cz, -sz, 0), (sz, cz, 0), (0, 0, 1))
    return _m_mul(_m_mul(rx, ry), rz)


def _m_mul(a, b):
    return tuple(tuple(sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)) for i in range(3))


def _m_t(a):
    return tuple(tuple(a[j][i] for j in range(3)) for i in range(3))


def _m_apply(a, v):
    return tuple(sum(a[i][k] * v[k] for k in range(3)) for i in range(3))


def _norm(v):
    length = math.sqrt(sum(c * c for c in v)) or 1.0
    return tuple(c / length for c in v)


def dir2d(angle, out=0.0):
    a = math.radians(angle)
    return _norm((out, math.sin(a), -math.cos(a)))


def _chain(pose, joints):
    m = ((1, 0, 0), (0, 1, 0), (0, 0, 1))
    for joint in joints:
        m = _m_mul(m, _m_rot(pose.get(joint)))
    return m


def arm(pose, side, upper, elbow=0.0, weapon=None, twist=0.0):
    """Points `side`'s upper arm along `upper` (a direction, or an angle for
    dir2d), bends the elbow forward by `elbow` degrees, and if `weapon` is
    given turns the wrist so the held weapon (its +Y) points that way."""
    out = pose.copy()
    if isinstance(upper, (int, float)):
        upper = dir2d(upper)
    if isinstance(weapon, (int, float)):
        weapon = dir2d(weapon)
    parent = _chain(out, ["Root", "Waist"])
    d = _m_apply(_m_t(parent), _norm(upper))
    # Rx(p) * Ry(twist) * Rz(r) applied to the hanging arm (0, -1, 0)
    r = math.degrees(math.asin(max(-1.0, min(1.0, d[0]))))
    p = math.degrees(math.atan2(-d[2], -d[1])) if abs(d[0]) < 0.9999 else 0.0
    # the upper arm already hangs out by its rest slant; Rz is applied first,
    # so taking it off the roll makes the arm point along `upper`
    out.rot[f"{side}Shoulder"] = (p, twist, r - skeleton.arm_slant(side))
    out.rot[f"{side}Elbow"] = (float(elbow), 0.0, 0.0)
    if weapon is not None:
        out = aim(out, side, weapon)
    return out


def aim(pose, side, weapon):
    """Turns the wrist so a weapon held in `side`'s hand points along `weapon`."""
    out = pose.copy()
    if isinstance(weapon, (int, float)):
        weapon = dir2d(weapon)
    parent = _chain(out, ["Root", "Waist", f"{side}Shoulder", f"{side}Elbow"])
    w = _m_apply(_m_t(parent), _norm(weapon))
    # Rx(a) * Ry(b) applied to the rest weapon direction (0, 0, -1)
    b = math.degrees(math.asin(max(-1.0, min(1.0, -w[0]))))
    a = math.degrees(math.atan2(w[1], -w[2]))
    out.rot[f"{side}Wrist"] = (a, b, 0.0)
    return out


def _turn(a, b):
    rel = _m_mul(_m_t(_m_rot(a)), _m_rot(b))
    trace = rel[0][0] + rel[1][1] + rel[2][2]
    return math.degrees(math.acos(max(-1.0, min(1.0, (trace - 1) / 2))))


def _wrap(d):
    return (d + 180.0) % 360.0 - 180.0


def _euler_mid(p0, p1):
    rot = {}
    for joint in set(p0.rot) | set(p1.rot):
        a, b = p0.get(joint), p1.get(joint)
        rot[joint] = tuple(x + _wrap(y - x) * 0.5 for x, y in zip(a, b))
    return Pose(rot, tuple((x + y) / 2 for x, y in zip(p0.offset, p1.offset)))


def split_big_turns(keys, limit=150.0, depth=3):
    """Inserts midpoint keys wherever a joint turns more than `limit` degrees
    between two keys, so the game's shortest-path interpolation can't flip
    the wrong way round."""
    out = [keys[0]]
    for (t0, p0, e0), (t1, p1, e1) in zip(keys, keys[1:]):
        if e0 != "Constant" and depth > 0 and any(_turn(p0.get(j), p1.get(j)) > limit for j in set(p0.rot) | set(p1.rot)):
            mid = (0.5 * (t0 + t1), _euler_mid(p0, p1), "Linear")
            first = split_big_turns([(t0, p0, e0), mid], limit, depth - 1)
            second = split_big_turns([mid, (t1, p1, e1)], limit, depth - 1)
            out[-1] = first[0]
            out += first[1:] + second[1:]
        else:
            out.append((t1, p1, e1))
    return out


def _max_turn(p0, p1):
    """The largest angle any joint turns between two poses (degrees)."""
    worst = 0.0
    for joint in set(p0.rot) | set(p1.rot):
        rel = _m_mul(_m_t(_m_rot(p0.get(joint))), _m_rot(p1.get(joint)))
        trace = rel[0][0] + rel[1][1] + rel[2][2]
        worst = max(worst, math.degrees(math.acos(max(-1.0, min(1.0, (trace - 1) / 2)))))
    return worst


def check_clip(c, limit=170.0, overlap=0.08):
    """Warns about keys a joint would have to turn the short way round
    (anything near 180 degrees between two keys interpolates unpredictably)
    and keys that sink an arm into the torso."""
    problems = []
    for (t0, p0, ease), (t1, p1, _) in zip(c.keys, c.keys[1:]):
        if ease == "Constant":
            continue
        for joint in set(p0.rot) | set(p1.rot):
            a, b = _m_rot(p0.get(joint)), _m_rot(p1.get(joint))
            rel = _m_mul(_m_t(a), b)
            trace = rel[0][0] + rel[1][1] + rel[2][2]
            angle = math.degrees(math.acos(max(-1.0, min(1.0, (trace - 1) / 2))))
            if angle > limit:
                problems.append(f"{c.name}: {joint} turns {angle:.0f} deg between t={t0} and t={t1}")
    for t, pose, _ in c.keys:
        depth, what = body_overlap(pose)
        if depth > overlap:
            problems.append(f"{c.name}: {what} at t={t} ({depth:.2f} deep)")
    return problems


# The torso the arms must stay out of: ellipsoids (center, radii) in the
# frame of the joint that carries them, roomy enough for coats and armor.
TORSO = [("Waist", (0.0, 4.2, 0.02), (0.66, 0.66, 0.5)), ("Root", (0.0, 3.36, 0.03), (0.58, 0.42, 0.44))]
ARM_RADIUS = 0.13  # elbow, forearm and fist, roughly


def arm_points(pose, side):
    """Rig-space points along `side`'s arm that must clear the body: the
    elbow, mid forearm, wrist and fist."""
    el, _ = fk(pose, f"{side}Elbow")
    wr, _ = fk(pose, f"{side}Wrist")
    return [("elbow", el), ("forearm", _scale(_add(el, wr), 0.5)), ("wrist", wr), ("fist", grip_position(pose, side))]


def body_overlap(pose):
    """The deepest an arm point sinks into the torso (0 = clear, 1 = at the
    center), with what and where."""
    worst = (0.0, None)
    for joint, center, radii in TORSO:
        pos, rot = fk(pose, joint)
        origin = _add(pos, _m_apply(rot, _sub(center, PIVOTS[joint])))
        inv = _m_t(rot)
        for side in ("Left", "Right"):
            for what, p in arm_points(pose, side):
                q = _m_apply(inv, _sub(p, origin))
                d = math.sqrt(sum((q[i] / (radii[i] + ARM_RADIUS)) ** 2 for i in range(3)))
                if 1.0 - d > worst[0]:
                    worst = (1.0 - d, f"{side} {what} in the {'chest' if joint == 'Waist' else 'hips'}")
    return worst


def _side_overlap(pose, side, skip_fist=True):
    worst = 0.0
    for joint, center, radii in TORSO:
        pos, rot = fk(pose, joint)
        origin = _add(pos, _m_apply(rot, _sub(center, PIVOTS[joint])))
        inv = _m_t(rot)
        for what, p in arm_points(pose, side):
            if skip_fist and what == "fist":
                continue
            q = _m_apply(inv, _sub(p, origin))
            d = math.sqrt(sum((q[i] / (radii[i] + ARM_RADIUS)) ** 2 for i in range(3)))
            worst = max(worst, 1.0 - d)
    return worst


def swing_elbow(pose, side, angle):
    """Swings `side`'s elbow `angle` degrees around the shoulder-to-wrist
    line: the hand (and anything it holds) stays exactly where it was."""
    sh_pos, sh_rot = fk(pose, f"{side}Shoulder")
    el_pos, el_rot = fk(pose, f"{side}Elbow")
    wr_pos, wr_rot = fk(pose, f"{side}Wrist")
    axis = _sub(wr_pos, sh_pos)
    if _dot(axis, axis) < 1e-6:
        return pose
    turn = _rot_axis(_norm(axis), math.radians(angle))
    parent = _m_mul(_chain(pose, ["Root", "Waist"]), _I3)
    out = pose.copy()
    new_sh = _m_mul(turn, sh_rot)
    out.rot[f"{side}Shoulder"] = _euler_xyz(_m_mul(_m_t(parent), new_sh))
    new_el = _m_mul(turn, el_rot)
    out.rot[f"{side}Wrist"] = _euler_xyz(_m_mul(_m_t(new_el), wr_rot))
    return out


def _push_out(pose, p):
    """The smallest move (along the torso's surface normal) that takes the
    point p out of the torso."""
    worst = None
    frames = []
    for joint, center, radii in TORSO:
        pos, rot = fk(pose, joint)
        origin = _add(pos, _m_apply(rot, _sub(center, PIVOTS[joint])))
        frames.append((origin, rot, tuple(r + ARM_RADIUS for r in radii)))

    def depth(q_world):
        best = (0.0, None)
        for origin, rot, radii in frames:
            q = _m_apply(_m_t(rot), _sub(q_world, origin))
            d = 1.0 - math.sqrt(sum((q[i] / radii[i]) ** 2 for i in range(3)))
            if d > best[0]:
                best = (d, (origin, rot, radii, q))
        return best

    d0, info = depth(p)
    if d0 <= 0.0:
        return (0.0, 0.0, 0.0)
    origin, rot, radii, q = info
    n = tuple(q[i] / (radii[i] ** 2) for i in range(3))
    n = _norm(n) if _dot(n, n) > 1e-9 else (0.0, 0.0, -1.0)
    n = _m_apply(rot, n)
    lo, hi = 0.0, 1.6
    for _ in range(20):
        mid = (lo + hi) / 2
        if depth(_add(p, _scale(n, mid)))[0] > 0.0:
            lo = mid
        else:
            hi = mid
    return _scale(n, hi + 0.02)


def move_hand(pose, side, delta):
    """Slides `side`'s fist by `delta` (rig space) without turning it: the
    arm re-solves and the wrist keeps the hand's world orientation."""
    _, hand = fk(pose, f"{side}Wrist")
    target = _add(grip_position(pose, side), delta)
    out = pose
    aim_at = target
    for _ in range(6):
        out = reach(out, side, aim_at)
        _, el_rot = fk(out, f"{side}Elbow")
        out.rot[f"{side}Wrist"] = _euler_xyz(_m_mul(_m_t(el_rot), hand))
        err = _sub(grip_position(out, side), target)
        if _dot(err, err) < 1e-6:
            break
        aim_at = _sub(aim_at, err)
    return out


def clear_hands(pose, tolerance=0.03):
    """Moves fists out of the torso (re-solving the arm); a hand gripping
    the same weapon nearby moves with it, so two-handed holds stay put."""
    out = pose
    for _ in range(2):
        moved = False
        for side in ("Left", "Right"):
            other = "Left" if side == "Right" else "Right"
            g = grip_position(out, side)
            wr, _ = fk(out, f"{side}Wrist")
            push = max((_push_out(out, g), _push_out(out, wr)), key=lambda v: _dot(v, v))
            if math.sqrt(_dot(push, push)) < tolerance:
                continue
            og = grip_position(out, other)
            together = _dist(g, og) < 1.8
            out = move_hand(out, side, push)
            if together:
                out = move_hand(out, other, push)
            moved = True
        if not moved:
            break
    return out


def clear_body(pose, tolerance=0.02):
    """Keeps elbows and forearms out of the torso by swinging the elbows
    out (hands stay put, so two-handed grips hold)."""
    out = pose
    for side in ("Left", "Right"):
        base = _side_overlap(out, side)
        if base <= tolerance:
            continue
        best = (base, 0.0, out)
        for angle in range(-120, 121, 8):
            if angle == 0:
                continue
            cand = swing_elbow(out, side, angle)
            score = _side_overlap(cand, side) + abs(angle) * 0.0004
            if score < best[0]:
                best = (score, angle, cand)
        out = best[2]
    return out


# Forward kinematics and arm IK -------------------------------------------------

PIVOTS = skeleton.PIVOT
PARENT = skeleton.PARENT_JOINT
GRIP = skeleton.GRIP
_I3 = ((1, 0, 0), (0, 1, 0), (0, 0, 1))


def _sub(a, b):
    return tuple(x - y for x, y in zip(a, b))


def _add(a, b):
    return tuple(x + y for x, y in zip(a, b))


def _scale(a, k):
    return tuple(x * k for x in a)


def _dot(a, b):
    return sum(x * y for x, y in zip(a, b))


def _dist(a, b):
    return math.sqrt(sum((x - y) ** 2 for x, y in zip(a, b)))


def _cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def fk(pose, joint):
    """World (rig space) position and rotation of a joint's pivot frame."""
    parent = PARENT[joint]
    if parent is None:
        return _add(PIVOTS[joint], pose.offset), _m_rot(pose.get(joint))
    ppos, prot = fk(pose, parent)
    pos = _add(ppos, _m_apply(prot, _sub(PIVOTS[joint], PIVOTS[parent])))
    return pos, _m_mul(prot, _m_rot(pose.get(joint)))


def grip_position(pose, side):
    pos, rot = fk(pose, f"{side}Wrist")
    return _add(pos, _m_apply(rot, _sub(GRIP[side], PIVOTS[f"{side}Wrist"])))


def weapon_direction(pose, side):
    _, rot = fk(pose, f"{side}Wrist")
    return _m_apply(rot, (0.0, 0.0, -1.0))


def _euler_xyz(m):
    """Matrix -> (pitch, yaw, roll) degrees with m = Rx * Ry * Rz."""
    b = math.asin(max(-1.0, min(1.0, m[0][2])))
    if abs(m[0][2]) < 0.9999:
        a = math.atan2(-m[1][2], m[2][2])
        c = math.atan2(-m[0][1], m[0][0])
    else:
        a = math.atan2(m[2][1], m[1][1])
        c = 0.0
    return (math.degrees(a), math.degrees(b), math.degrees(c))


def _rot_axis(axis, angle):
    """Rotation matrix about a unit axis (radians)."""
    x, y, z = axis
    c, s = math.cos(angle), math.sin(angle)
    k = 1 - c
    return ((c + x * x * k, x * y * k - z * s, x * z * k + y * s),
            (y * x * k + z * s, c + y * y * k, y * z * k - x * s),
            (z * x * k - y * s, z * y * k + x * s, c + z * z * k))


def _rot_between(a, b):
    """Smallest rotation turning unit vector a onto unit vector b."""
    v = _cross(a, b)
    sin_ = math.sqrt(_dot(v, v))
    cos_ = _dot(a, b)
    if sin_ < 1e-9:
        if cos_ > 0:
            return _I3
        return _rot_axis(_norm(_cross(a, (1, 0, 0) if abs(a[0]) < 0.9 else (0, 1, 0))), math.pi)
    return _rot_axis(_scale(v, 1 / sin_), math.atan2(sin_, cos_))


def _arm_bones(side):
    """Rest vectors (shoulder frame): shoulder pivot -> elbow, elbow -> grip.
    The arms hang slightly out from the body at rest, so the first one
    slants outward."""
    elbow = PIVOTS[f"{side}Elbow"]
    return _sub(elbow, PIVOTS[f"{side}Shoulder"]), _sub(GRIP[side], elbow)


def _shoulder_to_grip(side, bend):
    """Shoulder-frame vector from the shoulder pivot to the grip, elbow bent `bend` degrees."""
    upper, fore = _arm_bones(side)
    return _add(upper, _m_apply(_m_rot((bend, 0.0, 0.0)), fore))


MAX_ELBOW = 160.0


def _bend_for(side, dist):
    """Elbow bend that puts the grip `dist` from the shoulder pivot (clamped)."""
    lo, hi = 0.0, MAX_ELBOW  # the distance shrinks as the elbow bends
    for _ in range(40):
        mid = (lo + hi) / 2
        v = _shoulder_to_grip(side, mid)
        if math.sqrt(_dot(v, v)) > dist:
            lo = mid
        else:
            hi = mid
    return (lo + hi) / 2


def reach(pose, side, target, pole=None, weapon=None):
    """Two-bone IK: puts `side`'s grip (center of the fist) on `target`.
    `pole` is the direction the elbow should point (default: down and out).
    Out of reach, the arm points straight at the target."""
    out = pose.copy()
    s = 1 if side == "Right" else -1
    sh_pos, _ = fk(out, f"{side}Shoulder")
    _, chest = fk(out, "Waist")
    to = _m_apply(_m_t(chest), _sub(target, sh_pos))  # in the chest frame
    dist = math.sqrt(_dot(to, to))
    if dist < 1e-6:
        return out
    bend = _bend_for(side, dist)
    v = _shoulder_to_grip(side, bend)
    d = _norm(to)
    rot = _rot_between(_norm(v), d)
    # swivel about the shoulder->target line so the elbow points at the pole
    pole_c = _norm(_m_apply(_m_t(chest), pole) if pole else (s * 0.6, -1.0, 0.35))
    upper, _ = _arm_bones(side)
    elbow = _m_apply(rot, upper)
    e = _sub(elbow, _scale(d, _dot(elbow, d)))
    p = _sub(pole_c, _scale(d, _dot(pole_c, d)))
    if math.sqrt(_dot(e, e)) > 1e-6 and math.sqrt(_dot(p, p)) > 1e-6:
        phi = math.atan2(_dot(d, _cross(e, p)), _dot(e, p))
        rot = _m_mul(_rot_axis(d, phi), rot)
    out.rot[f"{side}Shoulder"] = _euler_xyz(rot)
    out.rot[f"{side}Elbow"] = (bend, 0.0, 0.0)
    if dist < ARM_REACH:
        out = _refine_reach(out, side, target)
    if weapon is not None:
        out = aim(out, side, weapon)
    return out


def _solve(a, b):
    """Gaussian elimination for a small square system."""
    n = len(b)
    m = [list(row) + [b[i]] for i, row in enumerate(a)]
    for col in range(n):
        piv = max(range(col, n), key=lambda r: abs(m[r][col]))
        m[col], m[piv] = m[piv], m[col]
        if abs(m[col][col]) < 1e-12:
            return [0.0] * n
        for r in range(n):
            if r != col:
                k = m[r][col] / m[col][col]
                for c in range(col, n + 1):
                    m[r][c] -= k * m[col][c]
    return [m[i][n] / m[i][i] for i in range(n)]


def _refine_reach(pose, side, target, iterations=40):
    """Damped least squares on (shoulder pitch/yaw/roll, elbow) so the grip
    lands exactly on the target despite the rig's slightly angled bones."""
    sh, el = f"{side}Shoulder", f"{side}Elbow"
    x = list(pose.get(sh)) + [pose.get(el)[0]]
    start = list(x)

    def grip(params):
        pose.rot[sh] = tuple(params[:3])
        pose.rot[el] = (max(0.0, min(160.0, params[3])), 0.0, 0.0)
        return grip_position(pose, side)

    for _ in range(iterations):
        g = grip(x)
        res = _sub(g, target)
        if math.sqrt(_dot(res, res)) < 1e-3:
            break
        jac = []
        for i in range(4):
            x2 = list(x)
            x2[i] += 0.5
            g2 = grip(x2)
            jac.append([(g2[k] - g[k]) / 0.5 for k in range(3)])
        lam = 2e-5
        jtj = [[sum(jac[i][k] * jac[j][k] for k in range(3)) + (lam if i == j else 0.0) for j in range(4)]
               for i in range(4)]
        # weak pull back toward the analytic solution keeps the elbow on its side
        jtr = [sum(jac[i][k] * res[k] for k in range(3)) + 1e-6 * (x[i] - start[i]) for i in range(4)]
        dx = _solve(jtj, [-v for v in jtr])
        x = [xi + max(-20.0, min(20.0, d)) for xi, d in zip(x, dx)]
    grip(x)
    return pose


ARM_REACH = _dist(_shoulder_to_grip("Right", 0.0), (0.0, 0.0, 0.0))  # elbow straight
_SLIDE_PENALTY = 0.3  # per stud the support hand slides from where it would like to be
_CENTER_PENALTY = 0.05  # for keeping the hands off the body's midline
_NEAR_SIDE = 0.25  # the hands' meeting point sits this far toward the camera (+X)
_DRAW_PENALTY = 0.5  # per stud the lead hand draws in toward the body


def _line_reach(origin, w, center, radius):
    """Range of t where origin + w * t (w unit) is within `radius` of `center`."""
    rel = _sub(origin, center)
    b = _dot(w, rel)
    disc = b * b - (_dot(rel, rel) - radius * radius)
    if disc < 0:
        return None
    root = math.sqrt(disc)
    return -b - root, -b + root


def _pick_t(origin, w, shoulder, ranges, prefer, radius):
    """Spot on the line closest to `prefer` within `ranges` the shoulder can
    reach; failing that, the spot in `ranges` nearest the shoulder. Returns
    (t, how far out of reach)."""
    span = _line_reach(origin, w, shoulder, radius)
    best = None
    for lo, hi in ranges:
        if span and span[0] <= hi and span[1] >= lo:
            t = min(max(prefer, max(lo, span[0])), min(hi, span[1]))
            cand = (abs(t - prefer), 0.0, t)
        else:
            t = min(max(-_dot(w, _sub(origin, shoulder)), lo), hi)
            excess = _dist(_add(origin, _scale(w, t)), shoulder) - radius
            cand = (abs(t - prefer), excess, t)
        if best is None or (cand[1], cand[0]) < (best[1], best[0]):
            best = cand
    return best[2], best[1]


def hands_together(pose, lead, ranges, prefer, offset=(0.0, 0.0, 0.0), support=None, weapon=None):
    """After `lead`'s hand is placed (by arm or reach), puts the other hand at
    lead grip + offset + t * the lead's weapon direction, for the t in
    `ranges` ([(lo, hi), ...]) nearest `prefer` that it can reach (hands
    slide along a haft). Shoulders are wide for the arms' length, so when
    that isn't enough both hands also slide along rig X toward the body's
    midline (X is depth to the side-on game camera, so the silhouette stays)
    and, as a last resort, the lead hand draws in toward the body. `weapon`
    aims the other wrist along the weapon."""
    other = support or ("Left" if lead == "Right" else "Right")
    grip = grip_position(pose, lead)
    w = weapon_direction(pose, lead)
    lead_sh, _ = fk(pose, f"{lead}Shoulder")
    other_sh, _ = fk(pose, f"{other}Shoulder")
    radius = ARM_REACH * 0.98
    shift = (lead_sh[0] + other_sh[0]) / 2 + _NEAR_SIDE - (2 * grip[0] + offset[0] + w[0] * prefer) / 2
    inward = _sub(other_sh, grip)
    inward = _norm((0.0, inward[1], inward[2]))
    best = None
    for draw in (0.0, 0.2, 0.4, 0.6, 0.8, 1.0):
        for f in (1.0, 0.75, 0.5, 0.25, 0.0):
            move = _add((shift * f, 0.0, 0.0), _scale(inward, draw))
            lead_at = _add(grip, move)
            lead_excess = max(0.0, _dist(lead_at, lead_sh) - radius) if (f or draw) else 0.0
            t, excess = _pick_t(_add(lead_at, offset), w, other_sh, ranges, prefer, radius)
            cost = (lead_excess + excess + _SLIDE_PENALTY * abs(t - prefer) + _CENTER_PENALTY * (1.0 - f)
                    + _DRAW_PENALTY * draw)
            if best is None or cost < best[0] - 1e-3:
                best = (cost, lead_at, t)
    _, lead_at, t = best
    out = pose
    if _dist(lead_at, grip) > 1e-6:
        elbow, _ = fk(pose, f"{lead}Elbow")
        pole = _sub(elbow, _scale(_add(lead_sh, grip), 0.5))
        out = reach(pose, lead, lead_at, pole=pole if _dist(pole, (0, 0, 0)) > 0.05 else None, weapon=w)
    target = _add(_add(lead_at, offset), _scale(w, t))
    return reach(out, other, target, weapon=w if weapon else None)


# Two-handed weapons: where the support hand likes to be (studs along the
# weapon from the lead grip, negative = toward the butt) and where it may slide
# to, clear of the lead fist and the weapon's head and butt.
SUPPORT = {"Hammer": -0.64, "Spear": 1.25, "Scythe": 0.95}
HAFT = {
    "Hammer": [(-0.66, -0.62), (0.62, 2.3)],
    "Spear": [(-0.85, -0.62), (0.62, 3.2)],
    "Scythe": [(-0.7, -0.62), (0.62, 2.3)],
}


def two_hand(pose, separation, lead="Right", support=None, haft=None):
    """After `lead` holds the weapon, puts the other hand on the haft, ideally
    `separation` studs along the weapon (negative = toward the butt)."""
    ranges = haft or [(min(separation, 0.0) - 1.0, max(separation, 0.0) + 1.0)]
    return hands_together(pose, lead, ranges, separation, support=support, weapon=True)
