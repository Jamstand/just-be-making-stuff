"""
Movement clips. "Loco.<State>" is the full-body version; "<Weapon>.<State>"
variants re-pose the arms to carry each weapon. Legends with a guard style
of their own (stances.LEGEND_STYLES) also get "<Legend>.<Weapon>.<State>"
and "<Legend>.Loco.<State>" where the style changes the clip. The game
looks for "<Legend>.<Weapon>.<State>", "<Weapon>.<State>",
"<Legend>.Loco.<State>", then "Loco.<State>" (one-shot clips such as
"Loco.Land": "<Legend>.<Name>", then "<Name>").
"""

from .core import P, arm, clip, dir2d, mirror, plant, smooth_loop_keys, spin_keys
from .stances import STYLES, WEAPONS, body, breath, fist_arms, guard_arms, hold, stance, stance_body, styled_clip

FISTS = ("Unarmed", "Gauntlets")
IDLE_LENGTH = {"Gauntlets": 0.6}  # gauntlets bounce on the balls of the feet; the rest breathe over 1.4s
RUN_LENGTH = 0.44


def idle_keys(weapon, style="classic"):
    a = stance(weapon, style)
    b = stance(weapon, style, **breath(weapon, style))
    return [(0, a, "Sine.InOut"), (IDLE_LENGTH.get(weapon, 1.4) / 2, b, "Sine.InOut")]


def run_body(phase):
    """Run-cycle body without arms. phase A = right leg reaching forward,
    B = passing (lowest point). C, D are the mirrors."""
    if phase == "A":
        return P(off=(0, -0.02, 0), root=(-14, -8, 0), waist=(-4, 10, 0), neck=(16, -2, 0),
                 rhip=(42, 0, 0), rknee=(-14, 0, 0), rank=(6, 0, 0),
                 lhip=(-36, 0, 0), lknee=(-48, 0, 0), lank=(-16, 0, 0))
    return P(off=(0, -0.22, 0), root=(-16, 0, 0), waist=(-4, 0, 0), neck=(18, 0, 0),
             rhip=(4, 0, 0), rknee=(-32, 0, 0), rank=(14, 0, 0),
             lhip=(38, 0, 0), lknee=(-112, 0, 0), lank=(-22, 0, 0))


def run_arms(pose, phase):
    if phase == "A":
        pose = arm(pose, "Right", dir2d(-128, 0.15), 72)
        return arm(pose, "Left", dir2d(-48, -0.15), 85)
    pose = arm(pose, "Right", dir2d(-95, 0.18), 75)
    return arm(pose, "Left", dir2d(-82, -0.18), 75)


def run_keys(weapon, style="classic"):
    a = run_arms(run_body("A"), "A")
    b = run_arms(run_body("B"), "B")
    poses = [a, b, mirror(a), mirror(b)]
    if weapon not in FISTS:
        poses = [hold(weapon, p, "run", style) for p in poses]
    # a spline through the four poses, so the legs never pause at one
    return smooth_loop_keys(poses, RUN_LENGTH, steps=16)


def tuck(weapon, lift=0.0, style="classic"):
    pose = P(off=(0, 0.3 + lift, 0), root=(-6, -6, 0), waist=(-6, 0, 0), neck=(8, 0, 0),
             rhip=(70, 0, 0), rknee=(-100, 0, 0), rank=(-10, 0, 0),
             lhip=(42, 0, 0), lknee=(-78, 0, 0), lank=(-10, 0, 0))
    pose = fist_arms(pose, STYLES[style]["tuck"])
    if weapon in FISTS:
        return pose
    return hold(weapon, pose, "run", style)


def fall_pose(weapon, sway=0.0, style="classic"):
    pose = P(off=(0, 0.1, 0), root=(4 + sway, -8, 0), waist=(2, 0, 0), neck=(-4, 0, 0),
             rhip=(18 + sway * 2, 0, 0), rknee=(-34, 0, 0), rank=(-12, 0, 0),
             lhip=(-8 - sway * 2, 0, 0), lknee=(-58, 0, 0), lank=(-20, 0, 0))
    ((right, rout), relbow), ((left, lout), lelbow) = STYLES[style]["fall"]
    pose = arm(pose, "Right", dir2d(right + sway * 3, rout), relbow)
    pose = arm(pose, "Left", dir2d(left - sway * 3, lout), lelbow)
    if weapon in FISTS:
        return pose
    return hold(weapon, pose, "run", style)


def jump_keys(weapon, style="classic"):
    launch = body(crouch=0.5, lean=-10)
    launch = guard_arms(launch, style=style) if weapon in FISTS else hold(weapon, launch, style=style)
    return [(0, launch, "Quad.Out"), (0.14, tuck(weapon, style=style), "Sine.Out"),
            (0.4, tuck(weapon, -0.1, style))]


def add_set(weapon, prefix):
    # styled_clip also makes "<Legend>.<prefix>.<State>" where a legend's
    # guard style changes the clip (Brann's heavy guard: Idle, Jump, Fall, ...)
    styled_clip(f"{prefix}.Idle", lambda style: idle_keys(weapon, style), loop=True,
                length=IDLE_LENGTH.get(weapon, 1.4))
    styled_clip(f"{prefix}.Run", lambda style: run_keys(weapon, style), loop=True, length=RUN_LENGTH)
    styled_clip(f"{prefix}.Jump", lambda style: jump_keys(weapon, style))
    styled_clip(f"{prefix}.Fall", lambda style: [(0, fall_pose(weapon, 0, style), "Sine.InOut"),
                                                 (0.45, fall_pose(weapon, 3, style), "Sine.InOut")],
                loop=True, length=0.9)


for _weapon in WEAPONS:
    add_set(_weapon, "Loco" if _weapon == "Unarmed" else _weapon)


# One-shot movement clips (shared by every weapon). The ones that pass
# through the guard, the tuck or the fall are styled (see add_set).


def air_jump_keys(style="classic"):
    t = tuck("Unarmed", 0.2, style)
    return spin_keys(0, 0.3, t, t, -360, axis="pitch", ease="Linear") + [(0.42, tuck("Unarmed", style=style))]


styled_clip("Loco.AirJump", air_jump_keys)


def land_keys(style="classic"):
    """Lands squatting deeper and wider than the stance it settles into (so a
    low, heavy stance lands heavier)."""
    kw = stance_body("Unarmed", style)
    kw.update(crouch=kw["crouch"] + 0.4, lean=kw["lean"] - 8, lf=kw["lf"] - 0.05, rf=kw["rf"] + 0.05)
    return [(0, guard_arms(body(**kw), style=style), "Quad.Out"), (0.14, stance("Unarmed", style))]


styled_clip("Loco.Land", land_keys)

_DASH = plant(P(off=(0, -0.5, 0), root=(-28, -10, 0), waist=(-6, 6, 0), neck=(30, 0, 0)), lfoot=0.9, rfoot=-0.95)
_DASH = arm(arm(_DASH, "Right", dir2d(-150, 0.25), 20), "Left", dir2d(-155, -0.25), 20)
clip("Loco.Dash", [(0, _DASH, "Quad.Out"), (0.18, _DASH)])


def dodge_keys(style="classic"):
    arms = STYLES[style].get("dodge", STYLES[style]["guard"])
    evade = fist_arms(body(crouch=0.55, lean=12, twist=-45, lf=-0.2, rf=0.75, look=-6), arms)
    evade = P(off=(0, -0.55, 0.4)) | evade
    return [(0, stance("Unarmed", style), "Quad.Out"), (0.07, evade, "Sine.InOut"),
            (0.28, evade.add(off=(0, 0.05, 0)), "Quad.InOut"), (0.36, stance("Unarmed", style))]


styled_clip("Loco.Dodge", dodge_keys)


def air_spot_keys(style="classic"):
    fall = fall_pose("Unarmed", style=style)
    turned = tuck("Unarmed", style=style).add(root=(0, -40, 0))
    return [(0, fall, "Quad.Out"), (0.06, turned, "Sine.InOut"), (0.36, fall)]


styled_clip("Loco.AirSpot", air_spot_keys)


def air_dodge_keys(style="classic"):
    roll = tuck("Unarmed", 0.1, style)
    return (spin_keys(0, 0.22, roll, roll, -360, axis="pitch", ease="Linear") +
            [(0.3, fall_pose("Unarmed", style=style))])


styled_clip("Loco.AirDodge", air_dodge_keys)

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
styled_clip("Loco.Throw", lambda style: [(0, stance("Unarmed", style), "Quad.Out"), (0.07, _THROW_UP, "Quad.In"),
                                         (0.13, _THROW, "Quad.Out"), (0.3, stance("Unarmed", style))])
