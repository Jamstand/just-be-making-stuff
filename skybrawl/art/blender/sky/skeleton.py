"""
The SkyRig skeleton: where every joint pivots, in rig space (X = the
fighter's right, Y = up, Z = behind, origin between the feet, 1 unit = 1
stud). Pure Python, so the mesh builder (sky/rig.py) and the animation
solver (anims/core.py) share one set of numbers.

Proportions are classic Roblox R6: 1x2x1 legs, a 2x2x1 torso, 1x2x1 arms and
a 1.2-stud head, scaled by R6_SCALE so the top of the head is 6 studs up. The
limbs are split so elbows and knees bend:
  * shoulders pivot on the torso's edge, half a stud below the top of the arm
    (where an R6 shoulder Motor6D sits), so arms swing around the torso;
  * the wrist pivot is the center of the fist, which is also the weapon grip,
    so a turning wrist spins the fist in place;
  * hips sit at the top of the legs, knees halfway to the ankles, and the
    ankle is half a stud above the sole.
"""

R6_SCALE = 6.0 / 5.2

# Classic R6 layout, in R6 studs before scaling. Right side; the left side
# mirrors x.
_R6 = {
    "Root": (0.0, 2.2, 0.0),
    "Waist": (0.0, 2.5, 0.0),
    "Neck": (0.0, 4.0, 0.0),
    "Shoulder": (1.0, 3.5, 0.0),
    "Elbow": (1.5, 2.9, 0.0),
    "Wrist": (1.5, 2.2, 0.0),
    "Hip": (0.5, 2.0, 0.0),
    "Knee": (0.5, 1.25, 0.0),
    "Ankle": (0.5, 0.5, 0.0),
}


def r6(x, y=None, z=None):
    """R6 studs -> rig units: r6(1.5) for a length, r6(x, y, z) for a point."""
    if y is None:
        return round(x * R6_SCALE, 4)
    return (round(x * R6_SCALE, 4), round(y * R6_SCALE, 4), round((z or 0.0) * R6_SCALE, 4))


SIDES = (("Left", -1), ("Right", 1))

# (joint, part0, part1). Parents come before children. "RigRoot" is an
# invisible part the game welds to the HumanoidRootPart.
_CHAIN = [("Root", "RigRoot", "LowerTorso"), ("Waist", "LowerTorso", "UpperTorso"), ("Neck", "UpperTorso", "Head")]
for _side, _ in SIDES:
    _CHAIN += [
        (f"{_side}Shoulder", "UpperTorso", f"{_side}UpperArm"),
        (f"{_side}Elbow", f"{_side}UpperArm", f"{_side}LowerArm"),
        (f"{_side}Wrist", f"{_side}LowerArm", f"{_side}Hand"),
        (f"{_side}Hip", "LowerTorso", f"{_side}UpperLeg"),
        (f"{_side}Knee", f"{_side}UpperLeg", f"{_side}LowerLeg"),
        (f"{_side}Ankle", f"{_side}LowerLeg", f"{_side}Foot"),
    ]


def _r6_pivot(joint):
    for side, s in SIDES:
        if joint.startswith(side):
            x, y, z = _R6[joint[len(side):]]
            return (s * x, y, z)
    return _R6[joint]


R6_PIVOT = {joint: _r6_pivot(joint) for joint, _, _ in _CHAIN}  # in R6 studs
PIVOT = {joint: r6(*R6_PIVOT[joint]) for joint, _, _ in _CHAIN}
JOINTS = [(joint, part0, part1, PIVOT[joint]) for joint, part0, part1 in _CHAIN]
PARENT_JOINT = {}
for _joint, _part0, _ in _CHAIN:
    PARENT_JOINT[_joint] = next((j for j, _, p1 in _CHAIN if p1 == _part0), None)

# Where a held weapon's grip sits at rest: the center of the fist.
GRIP = {side: PIVOT[f"{side}Wrist"] for side, _ in SIDES}

# Leg lengths for the foot-planting solver (the legs are straight up and down).
THIGH = PIVOT["RightHip"][1] - PIVOT["RightKnee"][1]
SHIN = PIVOT["RightKnee"][1] - PIVOT["RightAnkle"][1]
ANKLE_HEIGHT = PIVOT["RightAnkle"][1]
