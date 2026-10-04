"""Hammer attacks: two-handed, huge wind-ups."""

from .kit import (air, air_end, air_start, arc, attack, ground as G, hold_last, impact, recover, spin, start,
                  wield)

W = "Hammer"

k = arc(W, [0.9, 1.05, 1.15, 1.25], [150, 100, 40, -20],
        [G(lean=8, twist=-20, crouch=0.25), G(lean=-16, twist=8, crouch=0.5, lf=-0.8, rf=0.6)],
        cock=(50, -10), elbow=(90, 20), out=0.05)
attack("Hammer.NLight", [start(W)] + k + [hold_last(k, 2.0), recover(W)])

k = arc(W, [0.9, 1.04, 1.14, 1.26], [(170, 0.3), (120, 1.0), (50, 1.0), (0, 0.2)],
        [G(lean=4, twist=-40, crouch=0.35), G(lean=-14, twist=30, crouch=0.45, lf=-0.9, rf=0.6)],
        cock=(30, 0), elbow=(70, 20), out=0.05)
attack("Hammer.SLight", [start(W)] + k + [hold_last(k, 2.0), recover(W)])

k = arc(W, [0.9, 1.04, 1.14, 1.26], [-160, -110, -60, -15],
        [G(lean=-8, twist=-25, crouch=0.6), G(lean=-26, twist=15, crouch=0.95, lf=-1.0, rf=0.7)],
        cock=(25, 0), elbow=(60, 15), out=0.05)
attack("Hammer.DLight", [start(W)] + k + [hold_last(k, 2.0), recover(W)])

whirl = wield(air(lean=0, legs="tuck"), W, (-10, 2.5), 10, (-10, 2.5))
attack("Hammer.NAir", [air_start(W), (0.9, wield(air(legs="tuck"), W, (-120, 0.5), 40, (-150, 0.5)), "Quad.In")] +
       spin(1.0, 1.9, whirl, 360) + [(2.1, whirl, "Quad.Out"), air_end(W)])

k = arc(W, [0.9, 1.04, 1.16, 1.28], [140, 90, 30, -20],
        [air(lean=6, twist=-25, legs="tuck"), air(lean=-14, twist=15, legs="split")], cock=(40, 0), elbow=(80, 15),
        out=0.05)
attack("Hammer.SAir", [air_start(W)] + k + [hold_last(k, 2.0), air_end(W)])

k = arc(W, [0.9, 1.02, 1.12, 1.22, 1.32], [120, 60, 0, -60, -100],
        [air(lean=12, legs="knees"), air(lean=-25, legs="down")], cock=(40, 0), elbow=(80, 10), out=0.05)
attack("Hammer.DAir", [air_start(W)] + k + [hold_last(k, 2.0), air_end(W)])

k = arc(W, [0.9, 1.05, 1.15, 1.25, 1.35], [-150, -100, -30, 40, 95],
        [G(lean=-18, twist=-30, crouch=1.0), G(lean=8, twist=15, crouch=-0.15)], cock=(20, -10), elbow=(60, 20),
        out=0.05)
attack("Hammer.NHeavy", [start(W)] + k + [hold_last(k, 2.0), recover(W)])

k = arc(W, [0.9, 1.04, 1.12, 1.2, 1.3], [170, 120, 60, 0, -35],
        [G(lean=12, twist=-25, crouch=0.2), G(lean=-28, twist=10, crouch=0.65, lf=-1.1, rf=0.8)],
        cock=(50, 0), elbow=(100, 15), out=0.05)
attack("Hammer.SHeavy", [start(W)] + k + [hold_last(k, 2.0), recover(W)])

k = arc(W, [0.9, 1.04, 1.12, 1.2, 1.3], [160, 100, 30, -40, -75],
        [G(lean=10, crouch=0.3), G(lean=-32, crouch=1.05, lf=-0.8, rf=0.8)], cock=(50, 0), elbow=(100, 10),
        out=0.05)
attack("Hammer.DHeavy", [start(W)] + k + [hold_last(k, 2.0), recover(W)])

whirl = wield(air(legs="tuck", lift=0.4), W, (-10, 2.5), 10, (20, 2.5))
attack("Hammer.Recovery", [air_start(W), (0.9, wield(air(legs="knees"), W, (-120, 0.5), 40, (-150, 0.5)), "Quad.In")] +
       spin(1.0, 1.9, whirl, 360) + [(2.1, whirl, "Quad.Out"), air_end(W)])

k = arc(W, [0.9, 1.0, 1.08, 1.15], [100, 30, -40, -90],
        [air(legs="knees", lift=0.4), air(lean=6, legs="stomp")], cock=(30, 0), elbow=(80, 10), out=0.05)
land = wield(G(lean=-30, crouch=1.05, lf=-0.7, rf=0.7), W, (-60, 0.05), 10, (-85, 0))
attack("Hammer.GroundPound", [air_start(W)] + k + [(1.99, k[-1][1], "Constant")] + impact(W, land))
