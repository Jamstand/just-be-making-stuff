"""Bow attacks: the bow is in the far (left) hand, the near hand draws."""

from .core import _add, _scale, grip_position, reach, weapon_direction
from .kit import (P, D, air, air_end, air_start, arc, arm, attack, fists, ground as G, hold_last, impact, recover,
                  spin, start, wield)
from .stances import hold

W = "Bow"


def draw(base, angle, pull=1.45):
    pose = arm(base, "Left", D((angle, -0.05)), 0, weapon=D(angle))
    grip = grip_position(pose, "Left")
    w = weapon_direction(pose, "Left")
    target = _add(_add(grip, _scale(w, -pull)), (0.35, 0.05, 0.0))
    return reach(pose, "Right", target)


def release(base, angle):
    return draw(base, angle, pull=1.95)


def shot(name, base, angle, air_move=False, pull=1.45):
    begin, end = (air_start(W), air_end(W)) if air_move else (start(W), recover(W))
    d = draw(base, angle, pull)
    r = release(base.add(root=(4, 0, 0)), angle)
    attack(name, [begin, (0.75, d, "Linear"), (1.0, d, "Quad.Out"), (1.15, r, "Quad.Out"), (2.0, r, "Sine.InOut"), end])


shot("Bow.NLight", G(twist=-55, lean=4, crouch=0.3), 60)
shot("Bow.SLight", G(twist=-55, lean=-2, crouch=0.3, lf=-0.7, rf=0.5), 0)
shot("Bow.NAir", air(twist=-55, legs="spread"), 15, air_move=True)
shot("Bow.SAir", air(twist=-55, lean=-4, legs="split"), 0, air_move=True)
shot("Bow.DAir", air(twist=-55, lean=-14, legs="knees"), -50, air_move=True)
shot("Bow.SHeavy", G(twist=-65, lean=8, crouch=0.45, lf=-0.8, rf=0.6), 0, pull=1.6)

lean_back = hold(W, G(lean=8, twist=-10, crouch=0.35, lf=-0.15, rf=0.45))
chamber = lean_back | P(rhip=(55, 0, 0), rknee=(-95, 0, 0), rank=(0, 0, 0))
kick = hold(W, G(lean=14, twist=-5, crouch=0.45, lf=0.0, rf=0.45)) | P(rhip=(78, 0, 0), rknee=(-4, 0, 0),
                                                                     rank=(-20, 0, 0))
attack("Bow.DLight", [start(W), (0.8, chamber, "Quad.In"), (1.15, kick, "Quad.Out"), (2.0, kick, "Sine.InOut"),
                      recover(W)])

k = arc(W, [0.9, 1.04, 1.16, 1.28], [-120, -40, 40, 100],
        [G(lean=-14, twist=-25, crouch=0.8), G(lean=6, twist=10, crouch=-0.1)], cock=(20, -10), elbow=(30, 10),
        out=-0.2)
attack("Bow.NHeavy", [start(W)] + k + [hold_last(k, 2.0), recover(W)])

whirl = wield(G(lean=-10, twist=0, crouch=0.9, lf=-0.6, rf=0.6), W, (-10, -2.5), 0, (-10, -2.5))
attack("Bow.DHeavy", [start(W), (0.9, wield(G(crouch=0.7, twist=-30), W, (-150, -0.4), 30, (-160, -0.3)), "Quad.In")] +
       spin(1.0, 1.9, whirl, 360) + [(2.2, whirl, "Quad.Out"), recover(W)])

tuck = hold(W, fists(air(legs="tuck", lift=0.3), ((60, 0.4), 60), ((60, -0.4), 60)), "run")
flip = hold(W, fists(air(legs="kick", lift=0.4), ((140, 0.3), 20), ((-60, -0.4), 40)), "run")
attack("Bow.Recovery", [air_start(W), (0.9, tuck, "Quad.In")] + spin(1.0, 1.8, flip, -360, axis="pitch") +
       [(2.2, tuck, "Sine.InOut"), air_end(W)])

up = hold(W, fists(air(legs="knees", lift=0.4), ((150, 0.3), 30), ((50, -0.3), 30)), "run")
dive = hold(W, fists(air(lean=6, legs="stomp"), ((120, 0.4), 20), ((60, -0.4), 20)), "run")
land = hold(W, fists(G(lean=-20, crouch=0.95, lf=-0.6, rf=0.6), ((-80, 0.6), 30), ((-80, -0.6), 30)))
attack("Bow.GroundPound", [air_start(W), (0.45, hold(W, fists(air(legs="tuck"), ((60, 0.4), 40), ((40, -0.4), 40)), "run"), "Linear"),
                           (0.9, up, "Quad.In"), (1.12, dive, "Quad.Out"), (1.99, dive, "Constant")] + impact(W, land))
