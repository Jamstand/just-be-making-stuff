"""
Signature heavies: each legend's three ground heavies with each of their two
weapons ("<Legend>.<Weapon>.<Slot>"). Their hitboxes and motion are in
src/shared/Legends.luau; the poses here are built to match them.
"""

from .bow import draw, release
from .kit import (P, air, arc, attack, fists, ground as G, hold_last, recover, spin, start, wield)
from .core import mirror
from .stances import hold

# Shared shapes ------------------------------------------------------------------


def rising_spin(name, w, blade=(60, 1.6), turns=360, lift=0.9, upper=(40, 1.6), elbow=20):
    """Crouch, then spin upward with the weapon held out (rising motion)."""
    wind = wield(G(lean=-14, twist=-35, crouch=0.9), w, (-140, 0.4), 40, (-160, 0.3))
    up = wield(air(lean=0, legs="tuck", lift=lift), w, upper, elbow, blade)
    attack(name, [start(w), (0.9, wind, "Quad.In")] + spin(1.0, 1.9, up, turns) +
           [(2.2, up, "Quad.Out"), recover(w)])


def low_spin(name, w, turns=360, crouch=0.95, blade=(-15, 2.5), upper=(-15, 2.5), elbow=5):
    wind = wield(G(crouch=0.7, twist=-45, lean=-6), w, (-150, 0.5), 30, (-170, 0.4))
    whirl = wield(G(lean=-12, twist=0, crouch=crouch, lf=-0.7, rf=0.7), w, upper, elbow, blade)
    attack(name, [start(w), (0.9, wind, "Quad.In")] + spin(1.0, 1.95, whirl, turns) +
           [(2.2, whirl, "Quad.Out"), recover(w)])


def lunge(name, w, wind_blade=-170, strike=(-120, -60, 0, 20), dash_lean=-32, reach=1.45, cock=(30, 0),
          elbow=(40, 5)):
    """Big step-in swing: the body drives forward while the weapon sweeps."""
    wind = wield(G(lean=4, twist=-50, crouch=0.55, lf=-0.4, rf=0.8), w, (wind_blade - 30, 0.3), 50, (wind_blade, 0.2))
    k = arc(w, [1.0, 1.08, 1.16, 1.26], list(strike),
            [G(lean=-10, twist=-10, crouch=0.6, lf=-0.8, rf=0.8), G(lean=dash_lean, twist=28, crouch=0.75, lf=-reach, rf=1.05)],
            cock=cock, elbow=elbow, out=0.15)
    attack(name, [start(w), (0.9, wind, "Quad.In")] + k + [hold_last(k, 2.0), recover(w)])


def stab(name, w, wind_body, strike_body, wind=(-130, 110, 2), strike=(-6, 0, 0)):
    a = wield(wind_body, w, (wind[0], 0.12), wind[1], (wind[2], 0))
    b = wield(strike_body, w, (strike[0], 0.06), strike[1], (strike[2], 0))
    attack(name, [start(w), (0.9, a, "Quad.In"), (1.12, b, "Quad.Out"), (2.0, b, "Sine.InOut"), recover(w)])


def overhead(name, w, blades=(170, 120, 60, 0, -40), wind_body=None, strike_body=None, elbow=(100, 15)):
    k = arc(w, [0.9, 1.04, 1.12, 1.2, 1.3], list(blades),
            [wind_body or G(lean=12, twist=-25, crouch=0.2), strike_body or G(lean=-28, twist=10, crouch=0.7, lf=-1.1, rf=0.8)],
            cock=(50, 0), elbow=elbow, out=0.06)
    attack(name, [start(w)] + k + [hold_last(k, 2.0), recover(w)])


def upswing(name, w, blades=(-150, -100, -30, 40, 95), crouch=1.0, rise=-0.2, elbow=(50, 15)):
    k = arc(w, [0.9, 1.05, 1.15, 1.25, 1.35], list(blades),
            [G(lean=-18, twist=-30, crouch=crouch), G(lean=8, twist=15, crouch=rise)], cock=(20, -10), elbow=elbow,
            out=0.06)
    attack(name, [start(w)] + k + [hold_last(k, 2.0), recover(w)])


def bow_shot(name, base, angle, pull=1.5, lean_after=4):
    d = draw(base, angle, pull)
    r = release(base.add(root=(lean_after, 0, 0)), angle)
    attack(name, [start("Bow"), (0.75, d, "Linear"), (1.0, d, "Quad.Out"), (1.15, r, "Quad.Out"), (2.0, r, "Sine.InOut"),
                  recover("Bow")])


def flip_back(name, w, finish=None, kick=True):
    """Hop backward through a backflip (Motion hops back), ending in `finish`."""
    tuck = air(lean=0, legs="tuck", lift=0.4)
    tuck = hold(w, fists(tuck, ((60, 0.4), 60), ((60, -0.4), 60)), "run") if w != "Unarmed" else tuck
    flip = air(lean=0, legs="kick" if kick else "tuck", lift=0.5)
    flip = hold(w, fists(flip, ((140, 0.3), 20), ((-60, -0.4), 40)), "run")
    end = finish or tuck
    attack(name, [start(w), (0.9, hold(w, G(crouch=0.8, lean=-6)), "Quad.In")] +
           spin(1.0, 1.7, flip, 360, axis="pitch") + [(1.95, end, "Quad.Out"), (2.4, end, "Sine.InOut"), recover(w)])


# Kestrel: Sword + Bow ---------------------------------------------------------------

rising_spin("Kestrel.Sword.NHeavy", "Sword", blade=(70, 1.4), lift=1.1)
lunge("Kestrel.Sword.SHeavy", "Sword", wind_blade=-170, strike=(-140, -70, -10, 15), dash_lean=-34, reach=1.5)
low_spin("Kestrel.Sword.DHeavy", "Sword", turns=720, crouch=1.05)

bow_shot("Kestrel.Bow.NHeavy", G(twist=-55, lean=12, crouch=0.5, lf=-0.5, rf=0.6), 75)
bow_shot("Kestrel.Bow.SHeavy", G(twist=-70, lean=6, crouch=0.55, lf=-0.95, rf=0.7), 0, pull=1.7, lean_after=8)
flip_back("Kestrel.Bow.DHeavy", "Bow")

# Brann: Hammer + Gauntlets ----------------------------------------------------------

upswing("Brann.Hammer.NHeavy", "Hammer", blades=(-160, -110, -40, 30, 100), crouch=1.15, rise=-0.25)
_charge = wield(G(lean=-36, twist=-15, crouch=0.6, lf=-1.2, rf=1.0), "Hammer", (-30, 0.06), 70, (-5, 0))
_wind = wield(G(lean=0, twist=-40, crouch=0.5, lf=-0.4, rf=0.7), "Hammer", (-120, 0.06), 70, (-160, 0))
attack("Brann.Hammer.SHeavy", [start("Hammer"), (0.9, _wind, "Quad.In"), (1.1, _charge, "Quad.Out"),
                               (1.5, _charge.add(off=(0, 0.06, 0)), "Sine.InOut"), (2.0, _charge, "Sine.InOut"),
                               recover("Hammer")])
overhead("Brann.Hammer.DHeavy", "Hammer", blades=(165, 110, 40, -30, -80),
         wind_body=G(lean=10, crouch=-0.2), strike_body=G(lean=-36, crouch=1.15, lf=-0.8, rf=0.8))

_low = fists(G(lean=-22, twist=-20, crouch=1.0), ((-120, 0.3), 70), ((-120, -0.3), 70))
_mid = fists(G(lean=-6, crouch=0.4), ((-5, 0.2), 40), ((-5, -0.2), 40))
_up = fists(G(lean=8, crouch=-0.25), ((98, 0.15), 10), ((98, -0.15), 10))
attack("Brann.Gauntlets.NHeavy", [start("Gauntlets"), (0.9, _low, "Quad.In"), (1.1, _mid, "Linear"), (1.25, _up, "Quad.Out"),
                                  (2.0, _up, "Sine.InOut"), recover("Gauntlets")])
_lariat = fists(G(lean=-14, twist=0, crouch=0.35, lf=-0.7, rf=0.6), ((-5, 3.0), 0), ((-5, -3.0), 0))
attack("Brann.Gauntlets.SHeavy", [start("Gauntlets"), (0.9, fists(G(twist=-40, crouch=0.45), ((-140, 0.5), 30), ((-30, -0.5), 30)), "Quad.In")] +
       spin(1.0, 1.9, _lariat, 360) + [(2.2, _lariat, "Quad.Out"), recover("Gauntlets")])
_raise = fists(G(lean=4, crouch=0.2, lf=-0.2, rf=0.4) | P(rhip=(80, 0, 0), rknee=(-100, 0, 0)), ((150, 0.2), 30), ((150, -0.2), 30))
_mid = fists(G(lean=-14, crouch=0.6), ((40, 0.2), 10), ((40, -0.2), 10))
_stomp = fists(G(lean=-34, crouch=1.1, lf=-0.7, rf=0.7), ((-70, 0.25), 5), ((-70, -0.25), 5))
attack("Brann.Gauntlets.DHeavy", [start("Gauntlets"), (0.9, _raise, "Quad.In"), (1.05, _mid, "Linear"), (1.15, _stomp, "Quad.Out"),
                                  (2.0, _stomp, "Sine.InOut"), recover("Gauntlets")])

# Yuki: Spear + Bow -------------------------------------------------------------------

stab("Yuki.Spear.NHeavy", "Spear", G(lean=-12, twist=-25, crouch=0.95), air(lean=4, legs="down", lift=0.6),
     wind=(-100, 80, 60), strike=(88, 4, 90))
stab("Yuki.Spear.SHeavy", "Spear", G(lean=2, twist=-55, crouch=0.6, lf=-0.4, rf=0.8),
     G(lean=-34, twist=30, crouch=0.95, lf=-1.6, rf=1.15), wind=(-130, 110, 0), strike=(-12, 0, -2))
low_spin("Yuki.Spear.DHeavy", "Spear", turns=360, crouch=1.1, blade=(0, 3.0), upper=(-20, 1.5), elbow=40)

bow_shot("Yuki.Bow.NHeavy", G(twist=-55, lean=10, crouch=0.45), 70)
bow_shot("Yuki.Bow.SHeavy", G(twist=-65, lean=-4, crouch=0.4, lf=-0.8, rf=0.6), 0, pull=1.6)
_aim = draw(air(twist=-55, lean=-16, legs="knees"), -30)
flip_back("Yuki.Bow.DHeavy", "Bow", finish=_aim, kick=False)

# Moss: Scythe + Spear ------------------------------------------------------------------

rising_spin("Moss.Scythe.NHeavy", "Scythe", blade=(80, 1.8), upper=(70, 1.6), lift=0.8)
_reach = wield(G(lean=-30, twist=20, crouch=0.75, lf=-1.5, rf=1.0), "Scythe", (-10, 0.06), 10, (20, 0))
_yank = wield(G(lean=12, twist=-35, crouch=0.45, lf=-0.5, rf=0.8), "Scythe", (-120, 0.06), 105, (80, 0))
attack("Moss.Scythe.SHeavy", [start("Scythe"), (0.9, wield(G(lean=6, twist=-40, crouch=0.4), "Scythe", (120, 0.06), 60, (150, 0)), "Quad.In"),
                              (1.12, _reach, "Quad.Out"), (1.6, _yank, "Quad.Out"), (2.0, _yank, "Sine.InOut"),
                              recover("Scythe")])
low_spin("Moss.Scythe.DHeavy", "Scythe", turns=360, crouch=1.15, blade=(-25, 2.5))

stab("Moss.Spear.NHeavy", "Spear", G(lean=-10, twist=-25, crouch=0.8), air(lean=-2, legs="split", lift=0.5),
     wind=(-110, 90, 30), strike=(40, 10, 62))
_plant = wield(G(lean=-8, twist=-20, crouch=0.6, lf=-0.9, rf=0.6), "Spear", (-40, 0.06), 30, (-60, 0))
_vault = wield(air(lean=-40, legs="kick", lift=0.9), "Spear", (-60, 0.06), 10, (-80, 0))
attack("Moss.Spear.SHeavy", [start("Spear"), (0.9, _plant, "Quad.In")] +
       spin(1.0, 1.25, _vault, -40, axis="pitch") + [(2.0, _vault.add(root=(-40, 0, 0)), "Sine.InOut"), recover("Spear")])
low_spin("Moss.Spear.DHeavy", "Spear", turns=720, crouch=1.0, blade=(-5, 3.0), upper=(-25, 1.5), elbow=40)

# Vex: Scythe + Gauntlets ---------------------------------------------------------------

_k = arc("Scythe", [0.9, 1.02, 1.12, 1.22, 1.32, 1.42], [-40, 30, 100, 160, -140, -80],
         [G(lean=-14, twist=-20, crouch=0.8), G(lean=8, twist=10, crouch=0.1)], cock=(30, 30), elbow=(60, 20), out=0.06)
attack("Vex.Scythe.NHeavy", [start("Scythe")] + _k + [hold_last(_k, 2.0), recover("Scythe")])
lunge("Vex.Scythe.SHeavy", "Scythe", wind_blade=170, strike=(150, 90, 20, -20), dash_lean=-38, reach=1.65, cock=(30, 0),
      elbow=(60, 10))
low_spin("Vex.Scythe.DHeavy", "Scythe", turns=-360, crouch=1.1, blade=(-20, 2.5))

_claw = fists(air(lean=4, legs="tuck", lift=0.7), ((100, 0.3), 15), ((-60, -0.4), 60))
attack("Vex.Gauntlets.NHeavy", [start("Gauntlets"), (0.9, fists(G(lean=-20, twist=-30, crouch=0.95), ((-125, 0.3), 60), ((-30, -0.2), 90)), "Quad.In")] +
       spin(1.0, 1.7, _claw, 360) + [(2.2, _claw, "Quad.Out"), recover("Gauntlets")])
_dash = fists(G(lean=-38, twist=30, crouch=0.75, lf=-1.6, rf=1.15), ((-4, 0.05), 0), ((-150, -0.3), 25))
attack("Vex.Gauntlets.SHeavy", [start("Gauntlets"), (0.9, fists(G(lean=4, twist=-55, crouch=0.55, lf=-0.4, rf=0.8), ((-150, 0.2), 110), ((-15, -0.2), 55)), "Quad.In"),
                                (1.1, _dash, "Quad.Out"), (2.0, _dash, "Sine.InOut"), recover("Gauntlets")])
_burst = fists(G(lean=-24, crouch=1.1, lf=-0.8, rf=0.8), ((-30, 2.5), 10), ((-30, -2.5), 10))
attack("Vex.Gauntlets.DHeavy", [start("Gauntlets"), (0.9, fists(G(lean=-10, crouch=0.95), ((-100, 0.3), 120), ((-100, -0.3), 120)), "Quad.In"),
                                (1.1, _burst, "Quad.Out"), (2.0, _burst, "Sine.InOut"), recover("Gauntlets")])

# Sol: Sword + Hammer -------------------------------------------------------------------

upswing("Sol.Sword.NHeavy", "Sword", blades=(-150, -95, -25, 45, 95), crouch=1.0, rise=-0.25, elbow=(40, 10))
stab("Sol.Sword.SHeavy", "Sword", G(lean=2, twist=-55, crouch=0.55, lf=-0.4, rf=0.75),
     G(lean=-30, twist=30, crouch=0.8, lf=-1.5, rf=1.1), wind=(-135, 110, 5), strike=(-3, 0, 0))
low_spin("Sol.Sword.DHeavy", "Sword", turns=360, crouch=0.55, blade=(10, 2.5), upper=(5, 2.5))

upswing("Sol.Hammer.NHeavy", "Hammer", blades=(-160, -90, 0, 80, 130), crouch=1.05, rise=-0.2, elbow=(70, 20))
overhead("Sol.Hammer.SHeavy", "Hammer", blades=(175, 125, 60, 0, -35),
         wind_body=G(lean=14, twist=-25, crouch=0.15), strike_body=G(lean=-30, twist=10, crouch=0.75, lf=-1.3, rf=0.9))
overhead("Sol.Hammer.DHeavy", "Hammer", blades=(160, 100, 30, -40, -78),
         wind_body=G(lean=10, crouch=0.25), strike_body=G(lean=-34, crouch=1.1, lf=-0.8, rf=0.8))

__all__ = ["mirror"]
