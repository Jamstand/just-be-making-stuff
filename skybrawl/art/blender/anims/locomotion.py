"""
Movement clips. "Loco.<State>" is the full-body version; "<Weapon>.<State>"
variants re-pose the arms to carry each weapon. The game looks for
"<Weapon>.<State>" first, then "Loco.<State>".
"""

from .core import P, arm, clip, dir2d, mirror, plant, spin_keys
from .stances import WEAPONS, body, guard_arms, hold, stance


def idle_keys(weapon):
    if weapon == "Gauntlets":
        a = stance(weapon)
        b = stance(weapon, crouch=0.5, lean=-12)
        return [(0, a, "Sine.InOut"), (0.3, b, "Sine.InOut")], 0.6
    a = stance(weapon)
    b = stance(weapon, crouch=0.33, lean=-8)
    return [(0, a, "Sine.InOut"), (0.7, b, "Sine.InOut")], 1.4


def run_body(phase):
    """Run-cycle body without arms. phase A = right leg reaching forward,
    B = passing (lowest point). C, D are the mirrors."""
    if phase == "A":
        return P(off=(0, -0.12, 0), root=(-14, -8, 0), waist=(-4, 10, 0), neck=(16, -2, 0),
                 rhip=(42, 0, 0), rknee=(-14, 0, 0), rank=(6, 0, 0),
                 lhip=(-36, 0, 0), lknee=(-48, 0, 0), lank=(-16, 0, 0))
    return P(off=(0, -0.32, 0), root=(-16, 0, 0), waist=(-4, 0, 0), neck=(18, 0, 0),
             rhip=(4, 0, 0), rknee=(-32, 0, 0), rank=(14, 0, 0),
             lhip=(38, 0, 0), lknee=(-112, 0, 0), lank=(-22, 0, 0))


def run_arms(pose, phase):
    if phase == "A":
        pose = arm(pose, "Right", dir2d(-128, 0.15), 72)
        return arm(pose, "Left", dir2d(-48, -0.15), 85)
    pose = arm(pose, "Right", dir2d(-95, 0.18), 75)
    return arm(pose, "Left", dir2d(-82, -0.18), 75)


def run_keys(weapon):
    a = run_arms(run_body("A"), "A")
    b = run_arms(run_body("B"), "B")
    poses = [a, b, mirror(a), mirror(b)]
    if weapon not in ("Unarmed", "Gauntlets"):
        poses = [hold(weapon, p, "run") for p in poses]
    return [(t, p, "Sine.InOut") for t, p in zip((0, 0.11, 0.22, 0.33), poses)], 0.44


def tuck(weapon, lift=0.0):
    pose = P(off=(0, 0.3 + lift, 0), root=(-6, -6, 0), waist=(-6, 0, 0), neck=(8, 0, 0),
             rhip=(70, 0, 0), rknee=(-100, 0, 0), rank=(-10, 0, 0),
             lhip=(42, 0, 0), lknee=(-78, 0, 0), lank=(-10, 0, 0))
    pose = arm(pose, "Right", dir2d(25, 0.4), 50)
    pose = arm(pose, "Left", dir2d(-10, -0.4), 60)
    if weapon in ("Unarmed", "Gauntlets"):
        return pose
    return hold(weapon, pose, "run")


def fall_pose(weapon, sway=0.0):
    pose = P(off=(0, 0.1, 0), root=(4 + sway, -8, 0), waist=(2, 0, 0), neck=(-4, 0, 0),
             rhip=(18 + sway * 2, 0, 0), rknee=(-34, 0, 0), rank=(-12, 0, 0),
             lhip=(-8 - sway * 2, 0, 0), lknee=(-58, 0, 0), lank=(-20, 0, 0))
    pose = arm(pose, "Right", dir2d(-20 + sway * 3, 0.55), 35)
    pose = arm(pose, "Left", dir2d(-30 - sway * 3, -0.55), 35)
    if weapon in ("Unarmed", "Gauntlets"):
        return pose
    return hold(weapon, pose, "run")


def add_set(weapon, prefix):
    keys, length = idle_keys(weapon)
    clip(f"{prefix}.Idle", keys, loop=True, length=length)
    keys, length = run_keys(weapon)
    clip(f"{prefix}.Run", keys, loop=True, length=length)
    launch = hold(weapon, body(crouch=0.5, lean=-10)) if weapon not in ("Unarmed", "Gauntlets") else guard_arms(body(crouch=0.5, lean=-10))
    clip(f"{prefix}.Jump", [(0, launch, "Quad.Out"), (0.14, tuck(weapon), "Sine.Out"), (0.4, tuck(weapon, -0.1))])
    clip(f"{prefix}.Fall", [(0, fall_pose(weapon, 0), "Sine.InOut"), (0.45, fall_pose(weapon, 3), "Sine.InOut")],
         loop=True, length=0.9)


for _weapon in WEAPONS:
    add_set(_weapon, "Loco" if _weapon == "Unarmed" else _weapon)


# One-shot movement clips (shared by every weapon) ------------------------------

_T = tuck("Unarmed", 0.2)
clip("Loco.AirJump", spin_keys(0, 0.3, _T, _T, -360, axis="pitch", ease="Linear") + [(0.42, tuck("Unarmed"))])

_LAND = guard_arms(body(crouch=0.65, lean=-14, lf=-0.55, rf=0.5))
clip("Loco.Land", [(0, _LAND, "Quad.Out"), (0.14, stance("Unarmed"))])

_DASH = plant(P(off=(0, -0.5, 0), root=(-28, -10, 0), waist=(-6, 6, 0), neck=(30, 0, 0)), lfoot=0.9, rfoot=-0.95)
_DASH = arm(arm(_DASH, "Right", dir2d(-150, 0.25), 20), "Left", dir2d(-155, -0.25), 20)
clip("Loco.Dash", [(0, _DASH, "Quad.Out"), (0.18, _DASH)])

_EVADE = guard_arms(body(crouch=0.55, lean=12, twist=-45, lf=-0.2, rf=0.75, look=-6))
_EVADE = P(off=(0, -0.55, 0.4)) | _EVADE
clip("Loco.Dodge", [(0, stance("Unarmed"), "Quad.Out"), (0.07, _EVADE, "Sine.InOut"), (0.28, _EVADE.add(off=(0, 0.05, 0)), "Quad.InOut"),
                    (0.36, stance("Unarmed"))])

_AIRSPOT = tuck("Unarmed").add(root=(0, -40, 0))
clip("Loco.AirSpot", [(0, fall_pose("Unarmed"), "Quad.Out"), (0.06, _AIRSPOT, "Sine.InOut"), (0.36, fall_pose("Unarmed"))])

_ROLL = tuck("Unarmed", 0.1)
clip("Loco.AirDodge", spin_keys(0, 0.22, _ROLL, _ROLL, -360, axis="pitch", ease="Linear") + [(0.3, fall_pose("Unarmed"))])

_CHASE = plant(P(off=(0, 0.1, 0), root=(-32, -14, 0), waist=(-8, 6, 0), neck=(34, 0, 0)), lfoot=0.6, rfoot=-0.5,
               lheight=0.6, rheight=0.2)
_CHASE = arm(arm(_CHASE, "Right", dir2d(-140, 0.3), 30), "Left", dir2d(-150, -0.3), 30)
clip("Loco.Chase", [(0, _CHASE, "Quad.Out"), (0.12, _CHASE)])

_HURT = P(off=(0, 0.1, 0.25), root=(26, 10, 0), waist=(10, 0, 0), neck=(18, 0, 0),
          rhip=(30, 0, 0), rknee=(-60, 0, 0), lhip=(-6, 0, 0), lknee=(-30, 0, 0))
_HURT = arm(arm(_HURT, "Right", dir2d(-15, 0.6), 40), "Left", dir2d(-5, -0.6), 30)
clip("Loco.Hurt", [(0, _HURT.add(root=(12, 0, 0)), "Quad.Out"), (0.08, _HURT, "Sine.InOut"), (0.3, _HURT.add(root=(-6, 0, 0)))])

_CURL = P(off=(0, 0.2, 0), root=(10, 0, 0), waist=(-20, 0, 0), neck=(-10, 0, 0),
          rhip=(80, 0, 0), rknee=(-110, 0, 0), lhip=(60, 0, 0), lknee=(-100, 0, 0))
_CURL = arm(arm(_CURL, "Right", dir2d(-10, 0.5), 80), "Left", dir2d(0, -0.5), 80)
clip("Loco.Tumble", spin_keys(0, 0.45, _CURL, _CURL, 360, axis="pitch", ease="Linear"), loop=True, length=0.45)

_WALL = P(off=(0, -0.2, 0.25), root=(8, -20, 0), waist=(4, 0, 0), neck=(0, 10, 0),
          rhip=(55, 0, 0), rknee=(-90, 0, 0), rank=(10, 0, 0), lhip=(20, 0, 0), lknee=(-50, 0, 0))
_WALL = arm(arm(_WALL, "Right", dir2d(-150, 0.5), 15), "Left", dir2d(-40, -0.4), 60)
clip("Loco.WallSlide", [(0, _WALL, "Sine.InOut"), (0.4, _WALL.add(off=(0, 0.06, 0)), "Sine.InOut")], loop=True, length=0.8)

_THROW_UP = arm(body(lean=6, twist=-30, crouch=0.2), "Right", dir2d(150, 0.3), 70)
_THROW_UP = arm(_THROW_UP, "Left", dir2d(-20, -0.3), 20)
_THROW = arm(body(lean=-16, twist=20, crouch=0.35, lf=-0.75, rf=0.5), "Right", dir2d(-10, 0.2), 5)
_THROW = arm(_THROW, "Left", dir2d(-120, -0.3), 30)
clip("Loco.Throw", [(0, stance("Unarmed"), "Quad.Out"), (0.07, _THROW_UP, "Quad.In"), (0.13, _THROW, "Quad.Out"),
                    (0.3, stance("Unarmed"))])
