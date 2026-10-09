"""Spear attacks: long pokes, the front hand slides along the shaft."""

from .kit import (air, air_end, air_start, arc, attack, ground as G, hold_last, impact, recover, spin, start,
                  wield)

W = "Spear"


def poke(name, a, b, air_move=False):
    begin, end = (air_start(W), air_end(W)) if air_move else (start(W), recover(W))
    attack(name, [begin, (0.85, a, "Quad.In"), (1.12, b, "Quad.Out"), (2.0, b, "Sine.InOut"), end])


poke("Spear.NLight", wield(G(lean=-4, twist=-25, crouch=0.35), W, (-110, 0.1), 90, (30, 0)),
     wield(G(lean=-4, twist=15, crouch=0.2), W, (20, 0.1), 20, (60, 0)))
poke("Spear.SLight", wield(G(lean=0, twist=-35, crouch=0.35), W, (-115, 0.1), 100, (2, 0)),
     wield(G(lean=-16, twist=25, crouch=0.4, lf=-1.0, rf=0.75), W, (-15, 0.05), 10, (0, 0)))
poke("Spear.DLight", wield(G(lean=-10, twist=-30, crouch=0.8), W, (-120, 0.1), 90, (-10, 0)),
     wield(G(lean=-25, twist=20, crouch=1.0, lf=-1.1, rf=0.8), W, (-40, 0.05), 5, (-12, 0)))

whirl = wield(air(legs="tuck"), W, (-20, 1.5), 50, (0, 3.0))
attack("Spear.NAir", [air_start(W), (0.9, wield(air(legs="tuck"), W, (-100, 0.3), 80, (-20, 1.0)), "Quad.In")] +
       spin(1.0, 1.9, whirl, 360) + [(2.1, whirl, "Quad.Out"), air_end(W)])

poke("Spear.SAir", wield(air(lean=4, twist=-25, legs="tuck"), W, (-115, 0.1), 100, (0, 0)),
     wield(air(lean=-10, twist=20, legs="split"), W, (-12, 0.05), 10, (0, 0)), air_move=True)

k = arc(W, [0.9, 1.02, 1.12], [90, 0, -90], [air(lean=4, legs="knees", lift=0.4), air(lean=0, legs="split")],
        cock=(10, 0), elbow=(80, 10), out=0.08)
attack("Spear.DAir", [air_start(W)] + k + [hold_last(k, 2.0), air_end(W)])

poke("Spear.NHeavy", wield(G(lean=-10, twist=-25, crouch=0.8), W, (-100, 0.1), 70, (60, 0)),
     wield(G(lean=6, twist=10, crouch=-0.2), W, (85, 0.05), 5, (90, 0)))
poke("Spear.SHeavy", wield(G(lean=2, twist=-50, crouch=0.5, lf=-0.4, rf=0.7), W, (-130, 0.1), 110, (2, 0)),
     wield(G(lean=-26, twist=30, crouch=0.7, lf=-1.35, rf=1.0), W, (-8, 0.05), 0, (0, 0)))
poke("Spear.DHeavy", wield(G(lean=-12, twist=-30, crouch=0.7), W, (-120, 0.1), 100, (-5, 0)),
     wield(G(lean=-32, twist=20, crouch=1.1, lf=-1.3, rf=1.0), W, (-25, 0.05), 0, (-5, 0)))
poke("Spear.Recovery", wield(air(legs="knees"), W, (-100, 0.1), 90, (50, 0)),
     wield(air(lean=5, legs="down", lift=0.4), W, (70, 0.05), 5, (75, 0)), air_move=True)

k = arc(W, [0.9, 1.02, 1.12], [90, 0, -90], [air(legs="knees", lift=0.4), air(lean=4, legs="stomp")],
        cock=(10, 0), elbow=(80, 10), out=0.08)
land = wield(G(lean=-25, crouch=1.0, lf=-0.7, rf=0.6), W, (-70, 0.05), 10, (-88, 0))
attack("Spear.GroundPound", [air_start(W)] + k + [(1.99, k[-1][1], "Constant")] + impact(W, land))
