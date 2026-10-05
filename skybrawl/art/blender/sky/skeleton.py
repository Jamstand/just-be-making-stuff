"""
The SkyRig skeleton: where every joint pivots, in rig space (X = the
fighter's right, Y = up, Z = behind, origin between the feet, 1 unit = 1
stud). Pure Python, so the body builder (sky/hero.py), the armature and the
animation solver (anims/core.py) share one set of numbers.

Heroic stylized proportions, about 6.5 heads tall: broad shoulders, long
legs, slightly oversized hands and feet. Every legend shares this build, so
every animation fits every legend. The arms hang a little out from the
body at rest (broad lats), so arm poses subtract that rest slant.

Each joint is also a bone of the same name in the skinned mesh: the bone
starts at the joint's pivot and moves the body below it (the joint "Neck"
turns the head, "RightElbow" the forearm). The weapon grip is the center of
the fist, just below the wrist.
"""

HEIGHT = 6.0
HEAD = HEIGHT / 6.5  # one "head" of height

# Right side; the left side mirrors x.
_PIVOTS = {
    "Root": (0.0, 3.2, 0.0),
    "Waist": (0.0, 3.62, 0.02),
    "Neck": (0.0, 4.88, 0.04),
    "Shoulder": (0.86, 4.56, 0.04),
    "Elbow": (1.08, 3.6, 0.04),
    "Wrist": (1.17, 2.8, 0.04),
    "Hip": (0.34, 3.0, 0.0),
    "Knee": (0.355, 1.64, 0.0),
    "Ankle": (0.37, 0.32, 0.0),
}
_GRIP = (1.19, 2.6, -0.02)  # the center of the fist

SIDES = (("Left", -1), ("Right", 1))

# (joint, part0, part1). Parents come before children. "RigRoot" is an
# invisible part the game welds to the HumanoidRootPart; the part names are
# the invisible proxy parts the game animates (and holds weapons with).
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


def _pivot(joint):
    for side, s in SIDES:
        if joint.startswith(side):
            x, y, z = _PIVOTS[joint[len(side):]]
            return (round(s * x, 4), y, z)
    return _PIVOTS[joint]


PIVOT = {joint: _pivot(joint) for joint, _, _ in _CHAIN}
JOINTS = [(joint, part0, part1, PIVOT[joint]) for joint, part0, part1 in _CHAIN]
PARENT_JOINT = {}
for _joint, _part0, _ in _CHAIN:
    PARENT_JOINT[_joint] = next((j for j, _, p1 in _CHAIN if p1 == _part0), None)
CHILDREN = {j: [c for c, p in PARENT_JOINT.items() if p == j] for j in PIVOT}

# Where a held weapon's grip sits at rest: the center of the fist.
GRIP = {side: (round(s * _GRIP[0], 4), _GRIP[1], _GRIP[2]) for side, s in SIDES}

# Leg lengths for the foot-planting solver, in the side (YZ) plane.
THIGH = ((PIVOT["RightHip"][1] - PIVOT["RightKnee"][1]) ** 2 + (PIVOT["RightHip"][2] - PIVOT["RightKnee"][2]) ** 2) ** 0.5
SHIN = ((PIVOT["RightKnee"][1] - PIVOT["RightAnkle"][1]) ** 2
        + (PIVOT["RightKnee"][2] - PIVOT["RightAnkle"][2]) ** 2) ** 0.5
ANKLE_HEIGHT = PIVOT["RightAnkle"][1]

# Where each bone points at rest (its tail), for the armature: toward its
# child joint, or a fixed reach for the ends of chains.
_TAIL_REACH = {"Neck": (0.0, 1.0, 0.0), "Wrist": (0.0, -0.35, -0.08), "Ankle": (0.0, -0.1, -0.6)}


def tail(joint):
    kids = [c for c in CHILDREN[joint] if not c.endswith("Hip") or joint == "Root"]
    if joint == "Root":
        return PIVOT["Waist"]
    if joint == "Waist":
        return PIVOT["Neck"]
    if kids:
        return PIVOT[kids[0]]
    for key, (dx, dy, dz) in _TAIL_REACH.items():
        if joint.endswith(key):
            x, y, z = PIVOT[joint]
            return (x + dx, y + dy, z + dz)
    raise KeyError(joint)


def arm_slant(side):
    """Rest roll (degrees about Z) of the upper arm away from straight down:
    arm poses subtract it so "straight down" means straight down."""
    import math
    sh, el = PIVOT[f"{side}Shoulder"], PIVOT[f"{side}Elbow"]
    return math.degrees(math.atan2(el[0] - sh[0], sh[1] - el[1]))
