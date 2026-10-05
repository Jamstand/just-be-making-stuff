"""
Shared poses: the fighting stance and how each weapon is held.

Everything is authored facing right with the camera on the fighter's right
side; the game mirrors poses (and swaps the weapon hand) when facing left.
So the Right arm is the near, weapon arm, and +X ("out") is toward the camera.
"""

from .core import ARM_JOINTS, HAFT, SUPPORT, P, Pose, arm, dir2d, mirror, plant, two_hand

WEAPONS = ["Unarmed", "Sword", "Hammer", "Spear", "Gauntlets", "Scythe", "Bow"]


def body(lean=-6.0, crouch=0.25, twist=-12.0, lf=-0.5, rf=0.45, waist=(-3.0, 0.0, 0.0), look=0.0, lh=0.0, rh=0.0):
    """Root, spine, head and planted legs. `lean` < 0 leans forward, `twist`
    < 0 opens the chest to the camera, lf/rf are the feet's z (negative = in
    front)."""
    wp, wy, wr = waist
    pose = P(off=(0, -crouch, 0), root=(lean, twist, 0), waist=(wp, wy + twist * 0.4, wr),
             neck=(-lean - wp + look, -twist * 1.3 - wy, 0))
    return plant(pose, lfoot=lf, rfoot=rf, lheight=lh, rheight=rh)


def guard_arms(pose, high=0.0):
    pose = arm(pose, "Right", dir2d(-70 + high, 0.3), 118)
    return arm(pose, "Left", dir2d(-35 + high, -0.2), 98)


# How each weapon is held, as a function that sets the arms on a body pose.
def hold(weapon, pose, variant="idle"):
    if weapon == "Unarmed":
        return guard_arms(pose)
    if weapon == "Gauntlets":
        return guard_arms(pose, high=8)
    if weapon == "Sword":
        if variant == "run":  # free arm keeps swinging
            return arm(pose, "Right", dir2d(-120, 0.3), 25, weapon=dir2d(-160, 0.1))
        pose = arm(pose, "Right", dir2d(-55, 0.32), 62, weapon=dir2d(52, 0.1))
        return arm(pose, "Left", dir2d(-108, -0.3), 28)
    if weapon == "Hammer":
        pose = arm(pose, "Right", dir2d(-72, 0.08), 128, weapon=dir2d(128, -0.1))
        return two_hand(pose, SUPPORT["Hammer"], haft=HAFT["Hammer"])
    if weapon == "Spear":
        if variant == "run":
            return arm(pose, "Right", dir2d(-95, 0.28), 40, weapon=dir2d(-168))
        pose = arm(pose, "Right", dir2d(-100, 0.12), 78, weapon=dir2d(8))
        return two_hand(pose, SUPPORT["Spear"], haft=HAFT["Spear"])
    if weapon == "Scythe":
        if variant == "run":
            return arm(pose, "Right", dir2d(-118, 0.3), 30, weapon=dir2d(-150))
        pose = arm(pose, "Right", dir2d(-80, 0.1), 62, weapon=dir2d(112))
        return two_hand(pose, SUPPORT["Scythe"], haft=HAFT["Scythe"])
    if weapon == "Bow":
        if variant == "run":
            return arm(pose, "Left", dir2d(-75, -0.15), 30, weapon=dir2d(-40))
        pose = arm(pose, "Left", dir2d(-62, -0.12), 22, weapon=dir2d(-25))
        return arm(pose, "Right", dir2d(-82, 0.28), 62)
    raise KeyError(weapon)


def stance(weapon, **body_kw):
    kw = dict(lean=-6, crouch=0.25)
    if weapon == "Hammer":
        kw.update(lean=-3, crouch=0.35, lf=-0.6, rf=0.55)
    elif weapon == "Gauntlets":
        kw.update(lean=-10, crouch=0.35)
    elif weapon == "Spear":
        kw.update(lf=-0.7, rf=0.55)
    elif weapon == "Bow":
        kw.update(twist=-25)
    kw.update(body_kw)
    return hold(weapon, body(**kw))


def arms_of(pose):
    return pose.only(ARM_JOINTS)


def with_arms(base, arms):
    """`base` with its arm joints replaced by those in `arms` (keeps base's offset)."""
    out = base.without(ARM_JOINTS)
    out.rot.update(arms.only(ARM_JOINTS).rot)
    return out


__all__ = ["WEAPONS", "body", "guard_arms", "hold", "stance", "arms_of", "with_arms", "Pose", "mirror"]
