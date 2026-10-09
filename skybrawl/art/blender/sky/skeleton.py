"""
The SkyRig skeleton: where every joint pivots, in rig space (X = the
fighter's right, Y = up, Z = behind, origin between the feet, 1 unit = 1
stud). Pure Python, so the avatar builder (sky/avatar.py), the armature and
the animation solver (anims/core.py) share one set of numbers.

Proportions are a classic blocky Roblox avatar (the R6 silhouette): 1x2x1
legs, a 2x2x1 torso, 1x2x1 arms and a 1.2-stud head, scaled by R6_SCALE so the
top of the head is 6 studs up. Like an R15 "blocky" body, the limbs are split
so elbows and knees bend:
  * shoulders pivot at the top-middle of each arm, half a stud below its top
    (so a hanging arm sits beside the torso and swings straight forward and
    back in the side view);
  * the wrist pivot is the center of the fist, which is also the weapon grip,
    so a turning wrist spins the fist in place;
  * hips sit at the top of the legs, knees halfway to the ankles, and the
    ankle is half a stud above the sole.

Each joint is also a bone of the same name in the skinned mesh: the bone
starts at the joint's pivot and moves the body below it (the joint "Neck"
turns the head, "RightElbow" the forearm).
"""

R6_SCALE = 6.0 / 5.2

HEIGHT = 6.0
HEAD = 1.2 * R6_SCALE  # the classic head is 1.2 R6 studs tall

# Classic layout, in R6 studs before scaling. Right side; the left side
# mirrors x.
_R6 = {
    "Root": (0.0, 2.2, 0.0),
    "Waist": (0.0, 2.5, 0.0),
    "Neck": (0.0, 4.0, 0.0),
    "Shoulder": (1.5, 3.5, 0.0),
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
CHILDREN = {j: [c for c, p in PARENT_JOINT.items() if p == j] for j in PIVOT}

# Where a held weapon's grip sits at rest: the center of the fist.
GRIP = {side: PIVOT[f"{side}Wrist"] for side, _ in SIDES}

# Leg lengths for the foot-planting solver, in the side (YZ) plane.
THIGH = ((PIVOT["RightHip"][1] - PIVOT["RightKnee"][1]) ** 2 + (PIVOT["RightHip"][2] - PIVOT["RightKnee"][2]) ** 2) ** 0.5
SHIN = ((PIVOT["RightKnee"][1] - PIVOT["RightAnkle"][1]) ** 2
        + (PIVOT["RightKnee"][2] - PIVOT["RightAnkle"][2]) ** 2) ** 0.5
ANKLE_HEIGHT = PIVOT["RightAnkle"][1]

# Where each bone points at rest (its tail), for the armature: toward its
# child joint, or a fixed reach for the ends of chains.
_TAIL_REACH = {"Neck": (0.0, 1.0, 0.0), "Wrist": (0.0, -0.3, 0.0), "Ankle": (0.0, 0.0, -0.5)}


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
    arm poses subtract it so "straight down" means straight down. Blocky
    arms hang straight, so this is 0."""
    import math
    sh, el = PIVOT[f"{side}Shoulder"], PIVOT[f"{side}Elbow"]
    return math.degrees(math.atan2(el[0] - sh[0], sh[1] - el[1]))
