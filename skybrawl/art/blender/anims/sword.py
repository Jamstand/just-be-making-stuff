"""Sword attacks."""

from .kit import (air, air_end, air_start, arc, attack, ground as G, hold_last, impact, recover, spin, start,
                  wield)

W = "Sword"

k = arc(W, [0.85, 1.05, 1.2, 1.35], [-110, -40, 30, 95],
        [G(lean=-12, twist=-22, crouch=0.4), G(lean=2, twist=14, crouch=0.2)], cock=(20, -10), elbow=(30, 20))
attack("Sword.NLight", [start(W)] + k + [hold_last(k, 2.0), recover(W)])

a = wield(G(lean=0, twist=-35, crouch=0.35, lf=-0.4, rf=0.6), W, (-110, 0.25), 100, (0, 0))
b = wield(G(lean=-18, twist=25, crouch=0.45, lf=-1.0, rf=0.8), W, (-4, 0.1), 0, (0, 0), free=((-150, -0.3), 20))
attack("Sword.SLight", [start(W), (0.85, a, "Quad.In"), (1.12, b, "Quad.Out"), (2.0, b, "Sine.InOut"), recover(W)])

k = arc(W, [0.85, 1.0, 1.12, 1.25], [-170, -125, -70, -20],
        [G(lean=-10, twist=-25, crouch=0.6, lf=-0.5, rf=0.6), G(lean=-28, twist=18, crouch=1.0, lf=-1.3, rf=0.9)],
        cock=(25, 0), elbow=(30, 5), out=0.3)
attack("Sword.DLight", [start(W)] + k + [hold_last(k, 2.0), recover(W)])

k = arc(W, [0.85, 1.0, 1.12, 1.24, 1.36], [-150, 150, 95, 45, 0],
        [air(lean=10, legs="tuck"), air(lean=-12, legs="spread")], cock=(40, 0), elbow=(30, 10))
attack("Sword.NAir", [air_start(W)] + k + [hold_last(k, 2.0), air_end(W)])

k = arc(W, [0.85, 1.02, 1.14, 1.26], [150, 100, 40, -15],
        [air(lean=4, twist=-25, legs="tuck"), air(lean=-12, twist=20, legs="split")], cock=(50, 0), elbow=(40, 5))
attack("Sword.SAir", [air_start(W)] + k + [hold_last(k, 2.0), air_end(W)])

k = arc(W, [0.85, 1.0, 1.15], [160, 60, -50], [air(lean=8, legs="knees"), air(lean=-40, legs="back")],
        cock=(40, -5), elbow=(60, 0), out=0.15)
attack("Sword.DAir", [air_start(W)] + k + [hold_last(k, 2.0), air_end(W)])

k = arc(W, [0.9, 1.05, 1.15, 1.25, 1.35], [-140, -90, -20, 50, 95],
        [G(lean=-16, twist=-28, crouch=0.95, lf=-0.6, rf=0.6), G(lean=8, twist=15, crouch=-0.2, lf=-0.4, rf=0.35)],
        cock=(20, -5), elbow=(40, 10))
attack("Sword.NHeavy", [start(W)] + k + [hold_last(k, 2.0), recover(W)])

a = wield(G(lean=2, twist=-50, crouch=0.5, lf=-0.4, rf=0.7), W, (-130, 0.2), 110, (5, 0), free=((-10, -0.3), 30))
b = wield(G(lean=-26, twist=30, crouch=0.7, lf=-1.35, rf=1.0), W, (-2, 0.05), 0, (0, 0), free=((-150, -0.3), 20))
attack("Sword.SHeavy", [start(W), (0.9, a, "Quad.In"), (1.12, b, "Quad.Out"), (2.0, b, "Sine.InOut"), recover(W)])

wind = wield(G(lean=-6, twist=-40, crouch=0.7), W, (-150, 0.6), 30, (-170, 0.4))
whirl = wield(G(lean=-10, twist=0, crouch=0.85, lf=-0.6, rf=0.6), W, (-5, 2.5), 0, (-5, 2.5))
attack("Sword.DHeavy", [start(W), (0.9, wind, "Quad.In")] + spin(1.0, 1.9, whirl, 360) + [(2.2, whirl, "Quad.Out"),
                                                                                       recover(W)])

wind = wield(air(legs="knees"), W, (-60, 0.3), 40, (-20, 0.2))
flip = wield(air(lean=0, legs="tuck", lift=0.4), W, (100, 0.2), 20, (120, 0.1))
attack("Sword.Recovery", [air_start(W), (0.9, wind, "Quad.In")] + spin(1.0, 1.8, flip, -360, axis="pitch") +
       [(2.2, flip, "Sine.InOut"), air_end(W)])

k = arc(W, [0.9, 1.0, 1.06, 1.12], [150, 60, -20, -90],
        [air(legs="knees", lift=0.4), air(lean=4, legs="stomp")], cock=(20, 0), elbow=(60, 0), out=0.1)
land = wield(G(lean=-25, crouch=1.0, lf=-0.7, rf=0.6), W, (-70, 0.2), 0, (-88, 0))
attack("Sword.GroundPound", [air_start(W)] + k + [(1.99, k[-1][1], "Constant")] + impact(W, land))
