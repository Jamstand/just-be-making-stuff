"""
Battlegrounds clips: the punch chains (M1), blocking, guard-break daze,
ragdoll knockdowns (down, get up, tech), the awakening and each legend's
ultimate.

Chains are three quick hits per weapon ("<Weapon>.Chain1..3"); the fourth
hit is the weapon's NLight, retuned as a launcher. Ultimates are
"<Legend>.Ultimate" whatever the weapon in hand, so they're built around
the body: dashes, leaps and big two-handed swings that read with or without
a weapon.
"""

from .core import HAFT, ROOT_PIVOT, SUPPORT, P, arm, clip, dir2d, spin_keys, two_hand
from .kit import D, air, arc, attack, fists, ground as G, hold_last, move, recover, spin, start, wield
from .locomotion import tuck
from .stances import STYLES, WEAPONS, body, fist_arms, hammer_arms, stance, styled_clip, support

FISTS = ("Unarmed", "Gauntlets")

# Punch chains -------------------------------------------------------------------


def jab_keys(w, wind, hit, t_wind=0.7, t_hit=1.05):
    return [start(w), (t_wind, wind, "Quad.In"), (t_hit, hit, "Quad.Out"), (2.0, hit, "Sine.InOut"), recover(w)]


def fist_chain(w):
    heavy = 1.2 if w == "Gauntlets" else 1.0
    # 1: far-hand jab, shoulder turned in
    wind = fists(G(lean=-6, twist=-18, crouch=0.3), ((-75, 0.3), 120), ((-50, -0.2), 115))
    hit = fists(G(lean=-14 * heavy, twist=-34, crouch=0.35, lf=-0.75, rf=0.5), ((-72, 0.3), 120), ((-3, -0.1), 4))
    attack(f"{w}.Chain1", jab_keys(w, wind, hit))
    # 2: near-hand cross, hips through
    wind = fists(G(lean=-8, twist=-30, crouch=0.35), ((-95, 0.3), 125), ((-20, -0.15), 70))
    hit = fists(G(lean=-18 * heavy, twist=24, crouch=0.4, lf=-0.85, rf=0.55), ((-2, 0.05), 4), ((-78, -0.25), 115))
    attack(f"{w}.Chain2", jab_keys(w, wind, hit))
    # 3: far-hand hook to the body, dipping low
    wind = fists(G(lean=-4, twist=12, crouch=0.45), ((-70, 0.3), 115), ((-120, -0.5), 100))
    hit = fists(G(lean=-20 * heavy, twist=-36, crouch=0.6, lf=-0.9, rf=0.6), ((-75, 0.3), 120), ((-25, 0.35), 85))
    attack(f"{w}.Chain3", jab_keys(w, wind, hit))


def slash_chain(w, cock=(40, 0), elbow=(60, 10), out=0.1, thrust=(-110, 105)):
    """Sword and the two-handers: down-slash, back-slash, thrust."""
    k = arc(w, [0.6, 0.95, 1.08, 1.2], [140, 90, 30, -30],
            [G(lean=4, twist=-22, crouch=0.3), G(lean=-16, twist=16, crouch=0.45, lf=-0.85, rf=0.6)],
            cock=cock, elbow=elbow, out=out)
    attack(f"{w}.Chain1", [start(w)] + k + [hold_last(k, 2.0), recover(w)])
    k = arc(w, [0.6, 0.95, 1.08, 1.2], [(-120, 0.4), (-60, 0.8), (0, 0.8), (50, 0.4)],
            [G(lean=-10, twist=20, crouch=0.45), G(lean=-6, twist=-24, crouch=0.35, lf=-0.7, rf=0.6)],
            cock=(cock[0] * 0.5, 0), elbow=elbow, out=out + 0.05)
    attack(f"{w}.Chain2", [start(w)] + k + [hold_last(k, 2.0), recover(w)])
    a = wield(G(lean=0, twist=-35, crouch=0.4, lf=-0.4, rf=0.6), w, (thrust[0], 0.2 + out), thrust[1], (0, 0))
    b = wield(G(lean=-22, twist=24, crouch=0.5, lf=-1.1, rf=0.8), w, (-5, 0.08), 0, (0, 0), free=((-150, -0.3), 20))
    attack(f"{w}.Chain3", jab_keys(w, a, b))


def spear_chain(w="Spear"):
    """Spear: two quick pokes and a low sweeping stab."""
    for name, wind_body, hit_body, height in (
        ("Chain1", G(lean=-2, twist=-25, crouch=0.35), G(lean=-16, twist=10, crouch=0.4, lf=-1.0, rf=0.6), 6),
        ("Chain2", G(lean=0, twist=-30, crouch=0.3), G(lean=-14, twist=18, crouch=0.3, lf=-1.05, rf=0.6), 16),
        ("Chain3", G(lean=-6, twist=-25, crouch=0.55), G(lean=-24, twist=20, crouch=0.75, lf=-1.25, rf=0.8), -12),
    ):
        a = wield(wind_body, w, (-110, 0.12), 90, (height * 0.5, 0))
        b = wield(hit_body, w, (-8 + height * 0.3, 0.06), 6, (height, 0))
        attack(f"{w}.{name}", jab_keys(w, a, b))


def bow_chain(w="Bow"):
    """Bow: bash with the bow, a punch with the free hand, an upswing."""
    a = wield(G(lean=0, twist=-30, crouch=0.35), w, (-100, -0.15), 100, (60, 0))
    b = wield(G(lean=-16, twist=-40, crouch=0.4, lf=-0.85, rf=0.55), w, (-8, -0.1), 10, (80, 0),
              free=((-75, 0.3), 120))
    attack(f"{w}.Chain1", jab_keys(w, a, b))
    a = wield(G(lean=-6, twist=-30, crouch=0.35), w, (-60, -0.15), 60, (40, 0), free=((-100, 0.3), 125))
    b = wield(G(lean=-18, twist=24, crouch=0.4, lf=-0.85, rf=0.55), w, (-80, -0.2), 100, (-20, 0),
              free=((-2, 0.05), 4))
    attack(f"{w}.Chain2", jab_keys(w, a, b))
    k = arc(w, [0.6, 0.95, 1.08, 1.2], [-120, -60, 10, 70],
            [G(lean=-14, twist=-30, crouch=0.6), G(lean=0, twist=-20, crouch=0.2)], cock=(20, 0), elbow=(40, 10),
            out=0.1, free=((-80, 0.3), 115))
    attack(f"{w}.Chain3", [start(w)] + k + [hold_last(k, 2.0), recover(w)])


for _w in FISTS:
    fist_chain(_w)
slash_chain("Sword")
slash_chain("Hammer", cock=(50, 0), elbow=(90, 20), out=0.35, thrust=(-95, 75))
slash_chain("Scythe", cock=(30, 0), elbow=(60, 15), out=0.4, thrust=(-95, 80))
spear_chain()
bow_chain()


# Block -------------------------------------------------------------------------------


def block_pose(weapon, breathe=0.0, style="classic"):
    pose = body(lean=-4 + breathe * 2, crouch=0.42 + breathe * 0.05, twist=-14, lf=-0.6, rf=0.5, look=-6)
    if weapon in FISTS:
        # forearms crossed in front of the face (or, in the heavy guard, raised
        # upright in front of it)
        return fist_arms(pose, STYLES[style]["block"])
    if weapon == "Bow":
        pose = arm(pose, "Left", dir2d(-30, -0.1), 70, weapon=dir2d(88, 0.1))
        return arm(pose, "Right", dir2d(-30, 0.25), 128)
    # the weapon held upright in front, braced with the other hand
    if weapon == "Hammer":
        return hammer_arms(pose, STYLES[style]["hammer_block"])
    pose = arm(pose, "Right", dir2d(-45, 0.2), 92, weapon=dir2d(88, 0.15))
    if weapon in SUPPORT:
        return two_hand(pose, support(weapon, style, block=True), haft=HAFT[weapon])
    return arm(pose, "Left", dir2d(-25, -0.05), 120)


def block_keys(weapon, style="classic"):
    return [(0, block_pose(weapon, 0.0, style), "Sine.InOut"), (0.5, block_pose(weapon, 1.0, style), "Sine.InOut")]


for _w in WEAPONS:
    _prefix = "Loco" if _w == "Unarmed" else _w
    styled_clip(f"{_prefix}.Block", lambda style, w=_w: block_keys(w, style), loop=True, length=1.0)


# Guard broken: dazed --------------------------------------------------------------------


def daze(sway):
    pose = body(lean=10, crouch=0.35, twist=0, lf=-0.25, rf=0.35, waist=(12, 0, sway * 4), look=18)
    pose = pose.add(root=(0, 0, sway * 6), neck=(0, sway * 8, sway * 10))
    pose = arm(pose, "Right", dir2d(-95, 0.45 + sway * 0.1), 25)
    return arm(pose, "Left", dir2d(-85, -0.45 + sway * 0.1), 30)


clip("Loco.Stunned", [(0, daze(-1), "Sine.InOut"), (0.45, daze(1), "Sine.InOut")], loop=True, length=0.9)


# Knockdown, get up, tech ------------------------------------------------------------------

_DOWN_Y = -(ROOT_PIVOT[1] - 0.72)  # root offset that rests the body on the ground, lying flat


def lying(bounce=0.0, style="classic"):
    """Flat on the back, legs out, arms flung wide (stances.CLASSIC["lying"])."""
    pose = P(off=(0, _DOWN_Y + bounce, 0.4), root=(88, 0, 0), waist=(-6, 0, 0), neck=(-10, 12, 0),
             rhip=(14, 0, 6), rknee=(-30, 0, 0), rank=(-20, 0, 0),
             lhip=(30, 0, -4), lknee=(-60, 0, 0), lank=(-10, 0, 0))
    return fist_arms(pose, STYLES[style]["lying"])


def sitting(style="classic"):
    """Propped up on one hand, knees drawn in: halfway up."""
    pose = P(off=(0, -1.4, 0.1), root=(30, -10, 0), waist=(-10, 0, 0), neck=(-14, 8, 0),
             rhip=(90, 0, 0), rknee=(-120, 0, 0), rank=(10, 0, 0),
             lhip=(60, 0, 0), lknee=(-70, 0, 0), lank=(-10, 0, 0))
    return fist_arms(pose, STYLES[style]["sitting"])


def kneeling(style="classic"):
    pose = body(lean=-24, crouch=1.2, twist=-10, lf=-0.7, rf=0.6, look=10)
    return fist_arms(pose, STYLES[style]["kneeling"])


# Knockdowns pass through the guard and the jump tuck, so these are styled
# (a legend with a guard style of its own gets "<Legend>.Loco.GetUp", ...).
styled_clip("Loco.Knockdown", lambda style: [(0, lying(0.35, style), "Quad.In"),
                                             (0.12, lying(-0.05, style), "Quad.Out"),
                                             (0.22, lying(0.08, style), "Quad.In"),
                                             (0.3, lying(0, style), "Sine.InOut"), (0.75, lying(0, style))])
styled_clip("Loco.GetUp", lambda style: [(0, lying(0, style), "Quad.InOut"), (0.12, sitting(style), "Quad.InOut"),
                                         (0.22, kneeling(style), "Quad.Out"), (0.3, stance("Unarmed", style))])


def tech_roll_keys(style="classic"):
    # The ball spins about the hips, so no height keeps it on the ground all
    # the way round: this one hops the soles a little off it to sink the
    # head less.
    ball = tuck("Unarmed", style=style).add(off=(0, -0.4, 0), root=(-20, 0, 0))
    return ([(0, kneeling(style), "Quad.Out")] + spin_keys(0.06, 0.28, ball, ball, -360, axis="pitch", ease="Linear") +
            [(0.36, stance("Unarmed", style), "Quad.Out")])


def tech_keys(style="classic"):
    kip = tuck("Unarmed", 0.3, style).add(root=(-10, 0, 0))
    return [(0, lying(0.2, style), "Quad.Out"), (0.1, sitting(style), "Quad.Out"), (0.2, kip, "Quad.Out"),
            (0.36, stance("Unarmed", style))]


styled_clip("Loco.TechRoll", tech_roll_keys)
styled_clip("Loco.Tech", tech_keys)


# Awakening ------------------------------------------------------------------------------

_GATHER = fists(body(lean=-18, crouch=0.75, twist=0, lf=-0.55, rf=0.55, look=-10), ((-120, 0.55), 95),
                ((-120, -0.55), 95))


def awaken_keys(style="classic"):
    roar = fist_arms(body(lean=14, crouch=0.35, twist=0, lf=-0.65, rf=0.65, look=22), STYLES[style]["roar"])
    flex = fist_arms(body(lean=4, crouch=0.45, twist=0, lf=-0.65, rf=0.65, look=8), STYLES[style]["flex"])
    return [(0, stance("Unarmed", style), "Quad.In"), (0.3, _GATHER, "Sine.InOut"),
            (0.5, _GATHER.add(off=(0, -0.05, 0)), "Quad.Out"), (0.62, roar, "Quad.Out"), (0.9, roar, "Sine.InOut"),
            (1.1, flex)]


styled_clip("Loco.Awaken", awaken_keys)


# Ultimates -----------------------------------------------------------------------------------
# Phased like attacks (0-1 startup, 1-2 active, 2-3 recovery); see Legends.Ultimate.
# Each starts and ends in its legend's guard (kit.move).

W = "Unarmed"

# Kestrel, Final Draw: a crouched draw at the hip, then a dash straight through.
_draw = fists(G(lean=-26, twist=-55, crouch=0.9, lf=-0.9, rf=0.7, look=-8), ((-150, -0.5), 60), ((-130, -0.3), 90))
_cut = fists(G(lean=-34, twist=35, crouch=0.85, lf=-1.6, rf=1.1), ((-10, 1.0), 0), ((-160, -0.4), 20))
_after = fists(G(lean=-10, twist=60, crouch=0.6, lf=-1.0, rf=0.8, look=20), ((-170, 0.9), 10), ((-110, -0.4), 40))
move("Kestrel.Ultimate", W, [(0.6, _draw, "Quad.In"), (0.95, _draw.add(off=(0, -0.05, 0)), "Constant"),
                             (1.1, _cut, "Quad.Out"), (1.7, _after, "Sine.Out"), (2.2, _after, "Sine.InOut")])

# Brann, Overdrive Cannon: the arm cocks way back, then a rocket punch.
_cock = fists(G(lean=6, twist=-60, crouch=0.75, lf=-0.5, rf=0.9), ((-160, 0.3), 120), ((-10, -0.3), 40))
_blast = fists(G(lean=-36, twist=35, crouch=0.8, lf=-1.7, rf=1.2), ((-2, 0.05), 0), ((-150, -0.3), 25))
move("Brann.Ultimate", W, [(0.85, _cock, "Quad.In"), (1.08, _blast, "Quad.Out"),
                           (2.0, _blast.add(off=(0, 0.05, 0)), "Sine.InOut")])

# Yuki, Absolute Zero: rises, gathers the cold to her chest, bursts outward.
_gather = fists(air(lean=-10, legs="knees", lift=0.8), ((-100, 0.6), 130), ((-100, -0.6), 130))
_burst = fists(air(lean=6, legs="spread", lift=1.0), ((40, 1.6), 5), ((40, -1.6), 5))
move("Yuki.Ultimate", W, [(0.5, _gather, "Sine.InOut"), (0.95, _gather.add(off=(0, 0.2, 0)), "Quad.In"),
                          (1.08, _burst, "Quad.Out"), (2.0, _burst, "Sine.InOut")])

# Moss, Rampage: a feral pounce, claws high, slamming down on landing.
_crouch = fists(G(lean=-40, twist=0, crouch=1.2, lf=-0.7, rf=0.7, look=-20), ((-150, 0.5), 50), ((-150, -0.5), 50))
_pounce = fists(air(lean=-30, legs="tuck", lift=0.6), ((130, 0.5), 50), ((130, -0.5), 50))
_maul = fists(air(lean=-46, legs="kick", lift=0.3), ((-60, 0.4), 30), ((-60, -0.4), 30))
move("Moss.Ultimate", W, [(0.8, _crouch, "Quad.In"), (1.0, _pounce, "Quad.Out"), (1.45, _maul, "Quad.In"),
                          (2.0, _maul, "Sine.InOut")])

# Vex, Thousand Shadows: dashes through, spinning slash after slash.
_low = fists(G(lean=-30, twist=-40, crouch=0.95, lf=-1.0, rf=0.8), ((-140, 0.4), 40), ((-40, -0.4), 60))
_whirl = fists(G(lean=-26, twist=0, crouch=0.8, lf=-0.9, rf=0.9), ((-10, 2.5), 5), ((-10, -2.5), 5))
move("Vex.Ultimate", W, [(0.85, _low, "Quad.In")] + spin(1.0, 1.9, _whirl, 1080) + [(2.15, _whirl, "Quad.Out")])

# Sol, Zenith Smash: both fists raised overhead, a hop, and a hammer-fist smash.
_raise = fists(G(lean=10, twist=-10, crouch=0.1, lf=-0.4, rf=0.5, look=14), ((160, 0.2), 25), ((160, -0.2), 25))
_smash = fists(G(lean=-40, twist=0, crouch=1.2, lf=-1.0, rf=0.8), ((-70, 0.15), 5), ((-70, -0.15), 5))
move("Sol.Ultimate", W, [(0.5, _raise.add(off=(0, 0.3, 0)), "Quad.Out"), (0.95, _raise.add(off=(0, 0.4, 0)), "Quad.In"),
                         (1.1, _smash, "Quad.Out"), (2.0, _smash.add(off=(0, -0.05, 0)), "Sine.InOut")])

# Avatar, Limit Break: a crouch and a huge rising uppercut.
_coil = fists(G(lean=-24, twist=-40, crouch=1.1, lf=-0.7, rf=0.7), ((-130, 0.3), 70), ((-30, -0.2), 95))
_rise = fists(air(lean=10, twist=25, legs="spread", lift=0.8), ((100, 0.1), 8), ((-110, -0.3), 50))
move("Avatar.Ultimate", W, [(0.85, _coil, "Quad.In"), (1.1, _rise, "Quad.Out"), (2.0, _rise, "Sine.InOut")])

__all__ = ["D"]
