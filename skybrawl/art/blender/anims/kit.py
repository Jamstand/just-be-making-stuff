"""
Building blocks for attack clips: bodies (grounded or airborne), wielding a
weapon (with the support hand on two-handed hafts), and multi-key arcs so
big swings travel the right way round instead of taking a shortcut.

Angles for arms and weapons are side-plane angles (see core.dir2d): 0 =
straight ahead, 90 = up, 180 = behind, -90 = down. A tuple (angle, out)
leans the direction toward the camera side.
"""

from .core import HAFT, SUPPORT, P, aim, arm, attack, dir2d, lerp_pose, mirror, plant, spin_keys, two_hand
from .stances import body, stance, style_of

WEAPON_ARM = {"Bow": "Left"}


def D(spec):
    """(angle, out) or angle -> direction."""
    if isinstance(spec, tuple):
        return dir2d(*spec)
    return dir2d(spec)


def ground(**kw):
    return body(**kw)


LEGS = {
    "tuck": (70, -100, 42, -78),
    "kick": (92, -4, 30, -95),
    "lowkick": (60, -6, 20, -80),
    "dangle": (18, -34, -8, -58),
    "spread": (42, -20, -38, -40),
    "down": (6, -8, -4, -14),
    "stomp": (-6, -4, 10, -22),
    "knees": (95, -120, 85, -115),
    "split": (70, -10, -60, -20),
    "back": (-30, -60, -10, -80),
}


def air(lean=0.0, twist=-8.0, legs="dangle", lift=0.2, waist=(0.0, 0.0, 0.0), look=0.0, z=0.0):
    rh, rk, lh, lk = LEGS[legs] if isinstance(legs, str) else legs
    wp, wy, wr = waist
    return P(off=(0, lift, z), root=(lean, twist, 0), waist=(wp, wy + twist * 0.4, wr),
             neck=(-lean - wp + look, -twist * 1.2 - wy, 0),
             rhip=(rh, 0, 0), rknee=(rk, 0, 0), rank=(-10, 0, 0),
             lhip=(lh, 0, 0), lknee=(lk, 0, 0), lank=(-10, 0, 0))


def wield(pose, weapon, upper, elbow, blade, support=True, free=None):
    """Weapon arm aims the weapon; two-handers get the other hand on the haft,
    one-handers can set the free arm with free=(upper, elbow)."""
    side = WEAPON_ARM.get(weapon, "Right")
    other = "Left" if side == "Right" else "Right"
    pose = arm(pose, side, D(upper), elbow, weapon=D(blade))
    if support and weapon in SUPPORT:
        pose = two_hand(pose, SUPPORT[weapon], lead=side, support=other, haft=HAFT[weapon])
    elif free is not None:
        pose = arm(pose, other, D(free[0]), free[1])
    elif weapon not in SUPPORT:
        pose = arm(pose, other, D((-115, -0.35 if other == "Left" else 0.35)), 30)
    return pose


def fists(pose, right, left):
    """right/left = (upper, elbow)."""
    pose = arm(pose, "Right", D(right[0]), right[1])
    return arm(pose, "Left", D(left[0]), left[1])


def lerp(a, b, t):
    return a + (b - a) * t


def arc(weapon, times, blades, bodies, cock=(60.0, 0.0), elbow=(40.0, 10.0), out=0.25, eases=None,
        support=True, free=None):
    """Keys along a swing: the blade passes through each angle in `blades` at
    each time in `times`, the arm leading it by `cock` degrees (from first to
    last) with the elbow easing from elbow[0] to elbow[1]. `bodies` is two
    poses (blended along the swing) or one per key."""
    keys = []
    n = len(times)
    for i, (t, blade) in enumerate(zip(times, blades)):
        a = i / max(1, n - 1)
        if len(bodies) == n:
            b = bodies[i]
        else:
            b = lerp_pose(bodies[0], bodies[-1], a)
        c = lerp(cock[0], cock[1], a)
        e = lerp(elbow[0], elbow[1], a)
        o = out if not isinstance(out, (list, tuple)) else lerp(out[0], out[1], a)
        if isinstance(blade, tuple):  # (angle, out): the swing passes the camera side
            angle, bout = blade
            pose = wield(b, weapon, (angle - c, max(o, bout * 0.8)), e, (angle, bout), support=support, free=free)
        else:
            pose = wield(b, weapon, (blade - c, o), e, (blade, o * 0.3), support=support, free=free)
        ease = (eases[i] if eases else ("Quad.In" if i == 0 else "Linear" if i < n - 1 else "Quad.Out"))
        keys.append((t, pose, ease))
    return keys


def hold_last(keys, t, ease="Sine.InOut"):
    """Keeps the last key's pose until `t` (end of the active frames)."""
    return (t, keys[-1][1], ease)


def thrust(weapon, pose_from, pose_to, upper=(-100.0, 0.0), elbow=(100.0, 0.0), blade=(0.0, 0.0), out=0.2,
           support=True, free=None):
    """Two poses: the weapon arm drawn back, then fully extended."""
    a = wield(pose_from, weapon, (upper[0], out), elbow[0], (blade[0], 0.0), support=support, free=free)
    b = wield(pose_to, weapon, (upper[1], out), elbow[1], (blade[1], 0.0), support=support, free=free)
    return a, b


def recover(weapon, t=3.0, style="classic"):
    """Back to the stance (a legend's own guard style for its own moves; the
    game eases shared moves into whatever stance the fighter is in)."""
    return (t, stance(weapon, style), "Quad.InOut")


def start(weapon, style="classic"):
    return (0.0, stance(weapon, style), "Quad.Out")


def move(name, weapon, keys):
    """Registers the move `name`: from the stance, through `keys` and back.
    The stance is in the guard style of the legend the move belongs to
    (Brann squares up in his own; see stances.LEGEND_STYLES)."""
    style = style_of(name)
    return attack(name, [start(weapon, style)] + keys + [recover(weapon, style=style)])


def air_start(weapon):
    pose = air()
    from .stances import hold

    if weapon in ("Unarmed", "Gauntlets"):
        pose = fists(pose, ((-20, 0.55), 35), ((-30, -0.55), 35))
    else:
        pose = hold(weapon, fists(pose, ((-20, 0.55), 35), ((-30, -0.55), 35)), "run")
    return (0.0, pose, "Quad.Out")


def air_end(weapon, t=3.0):
    k = air_start(weapon)
    return (t, k[1], "Quad.InOut")


def impact(weapon, pose, t_land=2.0):
    """Ground pound ending: snaps to `pose` on landing (phase 2), holds, recovers."""
    return [(t_land, pose, "Quad.Out"), (t_land + 0.4, pose, "Sine.InOut"), recover(weapon)]


def spin(t0, t1, pose, degrees, axis="yaw"):
    return spin_keys(t0, t1, pose, pose, degrees, axis=axis)


__all__ = [
    "P", "D", "aim", "arm", "attack", "dir2d", "lerp_pose", "mirror", "plant", "spin_keys", "two_hand",
    "body", "stance", "ground", "air", "wield", "fists", "arc", "thrust", "recover", "start", "move",
    "air_start", "air_end", "spin", "SUPPORT", "LEGS", "hold_last", "impact",
]
