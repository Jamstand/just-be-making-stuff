"""Scythe attacks: wide arcs and reaping pulls."""

from .kit import (air, air_end, air_start, arc, attack, ground as G, hold_last, impact, recover, spin, start,
                  wield)

W = "Scythe"

k = arc(W, [0.9, 1.04, 1.16, 1.28], [150, 100, 40, -10],
        [G(lean=6, twist=-20, crouch=0.3), G(lean=-14, twist=10, crouch=0.45, lf=-0.8, rf=0.6)],
        cock=(40, 0), elbow=(70, 20), out=0.06)
attack("Scythe.NLight", [start(W)] + k + [hold_last(k, 2.0), recover(W)])

reach_out = wield(G(lean=-14, twist=10, crouch=0.4, lf=-0.9, rf=0.6), W, (-20, 0.08), 15, (15, 0))
yank = wield(G(lean=8, twist=-30, crouch=0.35, lf=-0.3, rf=0.7), W, (-110, 0.08), 100, (70, 0))
attack("Scythe.SLight", [start(W), (0.85, reach_out, "Quad.In"), (1.15, yank, "Quad.Out"), (2.0, yank, "Sine.InOut"),
                         recover(W)])

k = arc(W, [0.9, 1.04, 1.14, 1.26], [-160, -110, -60, -15],
        [G(lean=-8, twist=-25, crouch=0.6), G(lean=-26, twist=15, crouch=0.95, lf=-1.0, rf=0.7)],
        cock=(25, 0), elbow=(60, 15), out=0.06)
attack("Scythe.DLight", [start(W)] + k + [hold_last(k, 2.0), recover(W)])

whirl = wield(air(legs="tuck"), W, (-10, 2.5), 20, (10, 2.5))
attack("Scythe.NAir", [air_start(W), (0.9, wield(air(legs="tuck"), W, (-120, 0.5), 40, (-150, 0.5)), "Quad.In")] +
       spin(1.0, 1.95, whirl, 360) + [(2.1, whirl, "Quad.Out"), air_end(W)])

k = arc(W, [0.9, 1.04, 1.16, 1.28], [140, 90, 30, -20],
        [air(lean=4, twist=-25, legs="tuck"), air(lean=-12, twist=15, legs="split")], cock=(40, 0), elbow=(70, 15),
        out=0.06)
attack("Scythe.SAir", [air_start(W)] + k + [hold_last(k, 2.0), air_end(W)])

k = arc(W, [0.9, 1.04, 1.16, 1.28], [60, 0, -60, -110], [air(lean=6, legs="knees"), air(lean=-20, legs="down")],
        cock=(30, 0), elbow=(70, 10), out=0.06)
attack("Scythe.DAir", [air_start(W)] + k + [hold_last(k, 2.0), air_end(W)])

k = arc(W, [0.9, 1.04, 1.14, 1.24, 1.34], [-40, 20, 90, 150, -160],
        [G(lean=-14, twist=-20, crouch=0.8), G(lean=10, twist=10, crouch=0.0)], cock=(30, 30), elbow=(60, 20),
        out=0.06)
attack("Scythe.NHeavy", [start(W)] + k + [hold_last(k, 2.0), recover(W)])

raised = wield(G(lean=8, twist=-35, crouch=0.35), W, (120, 0.08), 60, (150, 0))
k = arc(W, [1.0, 1.08, 1.16], [150, 90, 20],
        [G(lean=-6, twist=0, crouch=0.45, lf=-0.8, rf=0.6), G(lean=-24, twist=20, crouch=0.65, lf=-1.3, rf=0.9)],
        cock=(30, 0), elbow=(60, 10), out=0.06)
yank = wield(G(lean=10, twist=-30, crouch=0.45, lf=-0.6, rf=0.8), W, (-115, 0.08), 105, (75, 0))
attack("Scythe.SHeavy", [start(W), (0.9, raised, "Quad.In")] + k + [(1.45, yank, "Quad.Out"), (2.0, yank, "Sine.InOut"),
                                                                   recover(W)])

whirl = wield(G(lean=-10, twist=0, crouch=0.9, lf=-0.6, rf=0.6), W, (-20, 2.5), 10, (-20, 2.5))
attack("Scythe.DHeavy", [start(W), (0.9, wield(G(crouch=0.7, twist=-40), W, (-150, 0.5), 30, (-170, 0.4)), "Quad.In")] +
       spin(1.0, 1.95, whirl, 360) + [(2.2, whirl, "Quad.Out"), recover(W)])

whirl = wield(air(legs="tuck", lift=0.4), W, (40, 2.0), 20, (60, 2.0))
attack("Scythe.Recovery", [air_start(W), (0.9, wield(air(legs="knees"), W, (-120, 0.5), 40, (-150, 0.5)), "Quad.In")] +
       spin(1.0, 1.9, whirl, 360) + [(2.1, whirl, "Quad.Out"), air_end(W)])

k = arc(W, [0.9, 1.0, 1.08, 1.15], [100, 30, -40, -90],
        [air(legs="knees", lift=0.4), air(lean=6, legs="stomp")], cock=(30, 0), elbow=(70, 10), out=0.06)
land = wield(G(lean=-28, crouch=1.0, lf=-0.7, rf=0.7), W, (-60, 0.05), 10, (-85, 0))
attack("Scythe.GroundPound", [air_start(W)] + k + [(1.99, k[-1][1], "Constant")] + impact(W, land))
