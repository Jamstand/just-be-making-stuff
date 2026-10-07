"""
Shared poses: the fighting stance and how each weapon is held.

Everything is authored facing right with the camera on the fighter's right
side; the game mirrors poses (and swaps the weapon hand) when facing left.
So the Right arm is the near, weapon arm, and +X ("out") is toward the camera.
"""

import functools
import os
import re

from .core import (ARM_JOINTS, HAFT, SHIN, SUPPORT, THIGH, P, Pose, arm, clip, dir2d, fk, grip_position, mirror, plant,
                   sink_to_reach, two_hand)

WEAPONS = ["Unarmed", "Sword", "Hammer", "Spear", "Gauntlets", "Scythe", "Bow"]

# Guard styles: how a legend squares up. `stance` adjusts body() per weapon,
# `breathe` is the idle's breath in (crouch and lean added to the stance).
# `guard`, `block`, `tuck` (the jump's), `fall`, `lying`, `sitting` and
# `kneeling` (knocked down and getting up), `roar` and `flex` (the
# awakening's) and `dodge` (the spot dodge's, default the guard) are the fist
# arms ((upper arm angle, out), elbow) for the near (right) and far (left)
# arm. `hammer` (held standing),
# `hammer_run` (running and in the air, default `hammer`) and
# `hammer_block` are hammer holds, see hammer_arms. `support` overrides
# where the far hand grips a spear or scythe haft, (held, blocking) studs
# from the lead fist (default core.SUPPORT, and 0.6 of it to block).
CLASSIC = {
    "stance": {"Hammer": dict(lean=-3, crouch=0.35, lf=-0.6, rf=0.55), "Gauntlets": dict(lean=-10, crouch=0.35),
               "Spear": dict(lf=-0.7, rf=0.55), "Bow": dict(twist=-25)},
    "breathe": {"Hammer": (-0.02, -5), "Gauntlets": (0.15, -2)},
    "guard": (((-70, 0.3), 118), ((-35, -0.2), 98)),
    "block": (((-25, 0.25), 132), ((-15, -0.05), 138)),
    "tuck": (((25, 0.4), 50), ((-10, -0.4), 60)),
    "fall": (((-20, 0.55), 35), ((-30, -0.55), 35)),
    "lying": (((150, 0.9), 20), ((170, -0.9), 35)),
    "sitting": (((-120, 0.6), 10), ((-60, -0.4), 60)),
    "kneeling": (((-110, 0.5), 30), ((-80, -0.4), 50)),
    "roar": (((-150, 0.9), 45), ((-150, -0.9), 45)),
    "flex": (((-60, 1.4), 120), ((-60, -1.4), 120)),
    "hammer": dict(arm=((-72, 0.08), 128), head=(128, -0.1), support=SUPPORT["Hammer"]),
    "hammer_block": dict(arm=((-45, 0.2), 92), head=(88, 0.15), support=SUPPORT["Hammer"] * 0.6),
}
# The classic guard folds the elbows to 118 / 98 degrees and the fist block
# to 132-138, which buries the fists in big shoulder armor (anything past
# ~100 does). "heavy" is a brawler's guard for mech arms that keeps every
# elbow under 95: sunk low and wide, leaning in, chin down, fists forward at
# the chest; the block raises the forearms upright in front of the face
# instead of crossing them. Shoulder armor also tips into the chest when an
# arm swings far out to the side or overhead, so the heavy arms stay closer
# in: the dodge's turn with the twisting chest, a knockdown sprawls with
# the arms down at the sides and getting up pushes off close to the body. Big fists bend little at the wrist, so the
# hammer hangs forward in one hand at rest (the other fist up in the guard)
# and is braced upright in both to block.
_HEAVY_GUARD = (((-62, 0.12), 72), ((-32, 0.0), 74))
_BRAWL = dict(twist=-16, lf=-0.65, rf=0.55, look=-5)
HEAVY = dict(
    CLASSIC,
    stance=dict(CLASSIC["stance"], Unarmed=dict(_BRAWL, lean=-13, crouch=0.48),
                Gauntlets=dict(_BRAWL, lean=-15, crouch=0.5), Hammer=dict(_BRAWL, lean=-10, crouch=0.45)),
    breathe=dict(CLASSIC["breathe"], Unarmed=(0.08, -3), Gauntlets=(0.12, -2), Hammer=(0.08, -3)),
    guard=_HEAVY_GUARD,
    block=(((-15, 0.12), 90), ((-5, 0.0), 88)),
    tuck=(((-25, 0.0), 60), ((-20, -0.15), 60)),
    fall=(((-20, 0.55), 35), ((-30, -0.35), 35)),
    lying=(((20, 0.3), 20), ((40, -0.6), 35)),
    sitting=(((-120, 0.15), 10), ((-60, -0.2), 60)),
    kneeling=(((-110, 0.15), 30), ((-80, -0.2), 50)),
    roar=(((-150, 0.3), 45), ((-150, -0.3), 45)),
    flex=(((-35, 0.6), 90), ((-35, -0.6), 90)),
    dodge=(((-55, 0.4), 78), ((-30, 0.4), 78)),
    hammer=dict(arm=((-95, 0.15), 35), head=(30, 0.1), free=_HEAVY_GUARD[1]),
    hammer_run=dict(arm=((-95, 0.15), 40), head=(40, 0.0)),
    hammer_block=dict(arm=((-25, 0.15), 10), head=(84, 0.1), support=SUPPORT["Hammer"], wide=True),
)
# The classic scythe hold rests the far hand up the haft, in front of the
# neck, right where a scarf wraps it. "ninja" grips the scythe low instead:
# the far hand at the butt, below the lead fist, held and blocking.
NINJA = dict(CLASSIC, support={"Scythe": (-0.66, -0.66)})
STYLES = {"classic": CLASSIC, "heavy": HEAVY, "ninja": NINJA}

# Legends with a style of their own: styled_clip gives them "<Legend>.<Clip>"
# versions of the clips their style changes, which the game plays instead.
LEGEND_STYLES = {"Brann": "heavy", "Vex": "ninja"}


def style_of(name):
    """The guard style of the legend a clip name starts with ("Brann.Hammer.NHeavy")."""
    return LEGEND_STYLES.get(name.split(".")[0], "classic")

# Where the default stance plants the feet (z, negative = in front).
LEAD_FOOT = -0.5
BACK_FOOT = 0.45

# Crouch depths were authored for the heroic body's 2.98-stud legs; body()
# scales them to the blocky legs so the knees bend as much as authored.
CROUCH_SCALE = (THIGH + SHIN) / 2.98


def body(lean=-6.0, crouch=0.25, twist=-12.0, lf=LEAD_FOOT, rf=BACK_FOOT, waist=(-3.0, 0.0, 0.0), look=0.0, lh=0.0,
         rh=0.0):
    """Root, spine, head and planted legs. `lean` < 0 leans forward, `twist`
    < 0 opens the chest to the camera, lf/rf are the feet's z (negative = in
    front), `crouch` drops the hips (see CROUCH_SCALE). A stance wider than
    the legs reach crouches a little lower (core.sink_to_reach), unless the
    body is rising (crouch < 0)."""
    crouch *= CROUCH_SCALE
    wp, wy, wr = waist
    pose = P(off=(0, -crouch, 0), root=(lean, twist, 0), waist=(wp, wy + twist * 0.4, wr),
             neck=(-lean - wp + look, -twist * 1.3 - wy, 0))
    if crouch >= 0 and not (lh or rh):
        pose.offset = (0.0, -crouch - sink_to_reach(pose, lf, rf), 0.0)
    return plant(pose, lfoot=lf, rfoot=rf, lheight=lh, rheight=rh)


def fist_arms(pose, arms, high=0.0):
    """Sets both arms from ((upper angle, out), elbow) for the near and far
    arm; `high` raises both upper arms."""
    for side, ((angle, out), elbow) in zip(("Right", "Left"), arms):
        pose = arm(pose, side, dir2d(angle + high, out), elbow)
    return pose


def guard_arms(pose, high=0.0, style="classic"):
    return fist_arms(pose, STYLES[style]["guard"], high)


def hammer_arms(pose, spec):
    """The hammer in the near hand, the upper arm along `arm` ((angle, out),
    elbow) and the head aimed at `head` (angle, out). Two-handed, the far
    hand grips the haft `support` studs from the lead fist (negative =
    toward the butt), and `wide` keeps it in front of its own shoulder
    instead of reaching across the chest (side-on it still grips the haft):
    big fists reaching across sink into it. One-handed (no `support`), the
    far arm is set from `free` ((angle, out), elbow), or left as it is."""
    (angle, out), elbow = spec["arm"]
    pose = arm(pose, "Right", dir2d(angle, out), elbow, weapon=dir2d(*spec["head"]))
    if spec.get("support") is None:
        if "free" not in spec:
            return pose
        (angle, out), elbow = spec["free"]
        return arm(pose, "Left", dir2d(angle, out), elbow)
    offset = (0.0, 0.0, 0.0)
    if spec.get("wide"):
        offset = (fk(pose, "LeftShoulder")[0][0] - grip_position(pose, "Right")[0], 0.0, 0.0)
    return two_hand(pose, spec["support"], haft=HAFT["Hammer"], offset=offset)


# How each weapon is held, as a function that sets the arms on a body pose.
def hold(weapon, pose, variant="idle", style="classic"):
    if weapon == "Unarmed":
        return guard_arms(pose, style=style)
    if weapon == "Gauntlets":
        return guard_arms(pose, high=8, style=style)
    if weapon == "Sword":
        if variant == "run":  # free arm keeps swinging
            return arm(pose, "Right", dir2d(-120, 0.3), 25, weapon=dir2d(-160, 0.1))
        pose = arm(pose, "Right", dir2d(-55, 0.32), 62, weapon=dir2d(52, 0.1))
        return arm(pose, "Left", dir2d(-108, -0.3), 28)
    if weapon == "Hammer":
        held = STYLES[style]
        if variant == "run":
            return hammer_arms(pose, held.get("hammer_run", held["hammer"]))
        return hammer_arms(pose, held["hammer"])
    if weapon == "Spear":
        if variant == "run":
            return arm(pose, "Right", dir2d(-95, 0.28), 40, weapon=dir2d(-168))
        pose = arm(pose, "Right", dir2d(-100, 0.12), 78, weapon=dir2d(8))
        return two_hand(pose, support(weapon, style), haft=HAFT["Spear"])
    if weapon == "Scythe":
        if variant == "run":
            return arm(pose, "Right", dir2d(-118, 0.3), 30, weapon=dir2d(-150))
        pose = arm(pose, "Right", dir2d(-80, 0.1), 62, weapon=dir2d(112))
        return two_hand(pose, support(weapon, style), haft=HAFT["Scythe"])
    if weapon == "Bow":
        if variant == "run":
            return arm(pose, "Left", dir2d(-75, -0.15), 30, weapon=dir2d(-40))
        pose = arm(pose, "Left", dir2d(-62, -0.12), 22, weapon=dir2d(-25))
        return arm(pose, "Right", dir2d(-82, 0.28), 62)
    raise KeyError(weapon)


def support(weapon, style="classic", block=False):
    """Where the far hand grips `weapon`'s haft in `style` (see CLASSIC)."""
    held, blocking = STYLES[style].get("support", {}).get(weapon, (SUPPORT[weapon], SUPPORT[weapon] * 0.6))
    return blocking if block else held


def stance_body(weapon, style="classic"):
    """body() arguments for `weapon`'s stance."""
    return dict(dict(lean=-6, crouch=0.25, lf=LEAD_FOOT, rf=BACK_FOOT), **STYLES[style]["stance"].get(weapon, {}))


def stance(weapon, style="classic", **body_kw):
    return hold(weapon, body(**dict(stance_body(weapon, style), **body_kw)), style=style)


def breath(weapon, style="classic"):
    """The stance breathing in: body() arguments for the idle's other key."""
    kw = stance_body(weapon, style)
    crouch, lean = STYLES[style]["breathe"].get(weapon, (0.08, -2))
    return dict(crouch=kw["crouch"] + crouch, lean=kw["lean"] + lean)


def _same_keys(a, b):
    if len(a) != len(b):
        return False
    for (ta, pa, *ea), (tb, pb, *eb) in zip(a, b):
        if abs(ta - tb) > 1e-9 or ea != eb:
            return False
        if any(abs(x - y) > 1e-6 for x, y in zip(pa.offset, pb.offset)):
            return False
        for joint in set(pa.rot) | set(pb.rot):
            if any(abs(x - y) > 1e-6 for x, y in zip(pa.get(joint), pb.get(joint))):
                return False
    return True


@functools.cache
def legend_weapons():
    """{legend id: (weapon, weapon)} from src/shared/Legends.luau."""
    path = os.path.join(os.path.dirname(__file__), "..", "..", "..", "src", "shared", "Legends.luau")
    text = open(path).read()
    out = {}
    for m in re.finditer(r'Id = "(\w+)".*?Weapons = (\{[^}]*\}|nil)', text, re.S):
        out[m.group(1)] = tuple(re.findall(r'"(\w+)"', m.group(2)))
    return out


def styled_clip(name, build, **kw):
    """Registers `name` with the keys build("classic") returns, and
    "<Legend>.<name>" with build(style) for each legend in LEGEND_STYLES
    whose style changes them (the game tries "<Legend>.<name>" first, so
    only the clips that differ are made). A weapon's clips ("Hammer.Idle")
    are only restyled for the legends that carry it: a weapon picked up
    off-legend keeps the shared holds."""
    keys = build("classic")
    clip(name, keys, **kw)
    weapon = name.split(".")[0]
    carried = legend_weapons()
    for legend, style in LEGEND_STYLES.items():
        if weapon in WEAPONS and weapon not in carried.get(legend, ()):
            continue
        own = build(style)
        if not _same_keys(own, keys):
            clip(f"{legend}.{name}", own, **kw)


def arms_of(pose):
    return pose.only(ARM_JOINTS)


def with_arms(base, arms):
    """`base` with its arm joints replaced by those in `arms` (keeps base's offset)."""
    out = base.without(ARM_JOINTS)
    out.rot.update(arms.only(ARM_JOINTS).rot)
    return out


__all__ = ["WEAPONS", "STYLES", "LEGEND_STYLES", "style_of", "legend_weapons", "body", "fist_arms", "guard_arms",
           "hammer_arms", "hold", "support", "stance", "stance_body", "breath", "styled_clip", "arms_of", "with_arms",
           "Pose", "mirror"]
