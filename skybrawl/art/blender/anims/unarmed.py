"""Unarmed attacks: punches and kicks."""

from .kit import LEGS, air, air_end, air_start, attack, fists, ground, plant, recover, spin, start, P

W = "Unarmed"


def guard(pose, high=0.0):
    return fists(pose, ((-70 + high, 0.3), 118), ((-35 + high, -0.2), 98))


def fist_moves(w, speed=1.0):
    """Shared by Unarmed and Gauntlets (gauntlets hit faster and harder)."""
    g = guard

    # NLight: straight punch with the near hand
    chamber = fists(ground(lean=-4, twist=-32, crouch=0.3), ((-82, 0.3), 128), ((-40, -0.2), 100))
    jab = fists(ground(lean=-14, twist=20, crouch=0.3, lf=-0.7, rf=0.5), ((-2, 0.05), 4), ((-80, -0.25), 115))
    attack(f"{w}.NLight", [start(w), (0.9, chamber, "Quad.In"), (1.15, jab, "Quad.Out"),
                           (2.0, jab.add(root=(3, -4, 0)), "Sine.InOut"), recover(w)])

    # SLight: lunging punch
    coil = fists(ground(lean=0, twist=-40, crouch=0.4, lf=-0.4, rf=0.6), ((-110, 0.3), 120), ((-20, -0.2), 80))
    lunge = fists(ground(lean=-22, twist=28, crouch=0.5, lf=-1.1, rf=0.85), ((-6, 0.05), 0), ((-130, -0.3), 40))
    attack(f"{w}.SLight", [start(w), (0.85, coil, "Quad.In"), (1.15, lunge, "Quad.Out"),
                           (2.0, lunge.add(off=(0, 0.05, 0)), "Sine.InOut"), recover(w)])

    # DLight: low punch (gauntlets) / low kick (unarmed)
    if w == "Gauntlets":
        crouch = fists(ground(lean=-10, twist=-30, crouch=0.8, lf=-0.6, rf=0.6), ((-100, 0.3), 110), ((-45, -0.2), 100))
        low = fists(ground(lean=-30, twist=25, crouch=1.0, lf=-1.0, rf=0.7), ((-40, 0.05), 5), ((-110, -0.3), 60))
        attack(f"{w}.DLight", [start(w), (0.9, crouch, "Quad.In"), (1.15, low, "Quad.Out"),
                               (2.0, low, "Sine.InOut"), recover(w)])
    else:
        lean_back = g(ground(lean=8, twist=-10, crouch=0.35, lf=-0.15, rf=0.45))
        chamber = lean_back | P(rhip=(55, 0, 0), rknee=(-95, 0, 0), rank=(0, 0, 0))
        kick = g(ground(lean=14, twist=-5, crouch=0.45, lf=0.0, rf=0.45)) | P(rhip=(78, 0, 0), rknee=(-4, 0, 0),
                                                                          rank=(-20, 0, 0))
        attack(f"{w}.DLight", [start(w), (0.8, chamber, "Quad.In"), (1.15, kick, "Quad.Out"),
                               (2.0, kick, "Sine.InOut"), recover(w)])

    # NAir: rising uppercut
    low = fists(air(lean=-6, legs="tuck"), ((-115, 0.3), 80), ((-40, -0.3), 90))
    up = fists(air(lean=8, legs="spread", lift=0.35), ((100, 0.15), 15), ((-100, -0.3), 60))
    attack(f"{w}.NAir", [air_start(w), (0.9, low, "Quad.In"), (1.2, up, "Quad.Out"), (2.0, up, "Sine.InOut"),
                         air_end(w)])

    # SAir: flying punch (gauntlets) / flying kick (unarmed)
    if w == "Gauntlets":
        coil = fists(air(lean=0, twist=-35, legs="tuck"), ((-115, 0.3), 120), ((-20, -0.2), 80))
        hit = fists(air(lean=-14, twist=25, legs="spread"), ((-5, 0.05), 0), ((-130, -0.3), 40))
    else:
        coil = fists(air(lean=-4, legs="knees"), ((-40, 0.4), 80), ((-30, -0.4), 80))
        hit = fists(air(lean=20, legs="kick"), ((-150, 0.4), 30), ((-120, -0.4), 30))
    attack(f"{w}.SAir", [air_start(w), (0.9, coil, "Quad.In"), (1.15, hit, "Quad.Out"), (2.0, hit, "Sine.InOut"),
                         air_end(w)])

    # DAir: stomp (unarmed) / double-fist hammer (gauntlets)
    if w == "Gauntlets":
        raise_ = fists(air(lean=6, legs="tuck", lift=0.3), ((160, 0.15), 40), ((160, -0.15), 40))
        smash = fists(air(lean=-24, legs="back"), ((-80, 0.12), 5), ((-80, -0.12), 5))
        attack(f"{w}.DAir", [air_start(w), (0.6, fists(air(lean=4, legs="tuck"), ((110, 0.2), 50), ((110, -0.2), 50)), "Linear"),
                             (0.95, raise_, "Quad.In"), (1.2, smash, "Quad.Out"), (2.0, smash, "Sine.InOut"), air_end(w)])
    else:
        knees = fists(air(lean=0, legs="knees", lift=0.4), ((40, 0.5), 40), ((40, -0.5), 40))
        stomp = fists(air(lean=4, legs="stomp"), ((60, 0.6), 20), ((60, -0.6), 20))
        attack(f"{w}.DAir", [air_start(w), (0.9, knees, "Quad.In"), (1.15, stomp, "Quad.Out"),
                             (2.0, stomp, "Sine.InOut"), air_end(w)])

    # NHeavy: charged uppercut
    crouch = fists(ground(lean=-20, twist=-34, crouch=0.95, lf=-0.6, rf=0.65), ((-125, 0.3), 60), ((-30, -0.2), 90))
    rise = fists(ground(lean=6, twist=22, crouch=-0.25, lf=-0.35, rf=0.3), ((96, 0.1), 12), ((-110, -0.3), 50))
    mid = fists(ground(lean=-6, twist=0, crouch=0.4, lf=-0.5, rf=0.5), ((-5, 0.2), 40), ((-80, -0.3), 70))
    attack(f"{w}.NHeavy", [start(w), (0.9, crouch, "Quad.In"), (1.1, mid, "Linear"), (1.25, rise, "Quad.Out"),
                           (2.0, rise, "Sine.InOut"), recover(w)])

    # SHeavy: wound-up lunge punch
    wind = fists(ground(lean=2, twist=-50, crouch=0.45, lf=-0.4, rf=0.65), ((-145, 0.2), 110), ((-15, -0.2), 55))
    blast = fists(ground(lean=-24, twist=32, crouch=0.6, lf=-1.25, rf=0.95), ((-4, 0.05), 0), ((-135, -0.3), 40))
    attack(f"{w}.SHeavy", [start(w), (0.9, wind, "Quad.In"), (1.15, blast, "Quad.Out"),
                           (2.0, blast.add(root=(2, 0, 0)), "Sine.InOut"), recover(w)])

    # DHeavy: low spin (sweep kick for unarmed, double ground slam for gauntlets)
    if w == "Gauntlets":
        up = fists(ground(lean=8, twist=-10, crouch=0.3), ((165, 0.15), 30), ((165, -0.15), 30))
        slam = fists(ground(lean=-38, twist=0, crouch=1.15, lf=-0.8, rf=0.8), ((-70, 0.15), 5), ((-70, -0.15), 5))
        attack(f"{w}.DHeavy", [start(w), (0.5, fists(ground(lean=4, crouch=0.4), ((90, 0.2), 60), ((90, -0.2), 60)), "Linear"),
                               (0.9, up, "Quad.In"),
                               (1.05, fists(ground(lean=-15, crouch=0.7), ((40, 0.15), 10), ((40, -0.15), 10)), "Linear"),
                               (1.15, slam, "Quad.Out"), (2.0, slam, "Sine.InOut"), recover(w)])
    else:
        sweep = fists(P(off=(0, -1.15, 0), root=(-20, 0, 0), neck=(20, 0, 0),
                        rhip=(80, 0, 40), rknee=(-5, 0, 0), lhip=(95, 0, -10), lknee=(-140, 0, 0), lank=(30, 0, 0)),
                      ((-95, 0.5), 15), ((-95, -0.5), 15))
        attack(f"{w}.DHeavy", [start(w), (0.9, sweep, "Quad.In")] + spin(1.0, 1.9, sweep, 360) +
               [(2.2, sweep, "Quad.Out"), recover(w)])

    # Recovery: rising flip kick
    tuck = fists(air(lean=0, legs="tuck", lift=0.3), ((60, 0.4), 60), ((60, -0.4), 60))
    flip = fists(air(lean=0, legs="kick", lift=0.4), ((140, 0.3), 20), ((-60, -0.4), 40))
    attack(f"{w}.Recovery", [air_start(w), (0.9, tuck, "Quad.In")] + spin(1.0, 1.8, flip, -360, axis="pitch") +
           [(2.2, tuck, "Sine.InOut"), air_end(w)])

    # GroundPound: dive down, impact crouch on landing
    up = fists(air(lean=0, legs="knees", lift=0.4), ((150, 0.3), 30), ((150, -0.3), 30))
    dive = fists(air(lean=6, legs="stomp"), ((120, 0.4), 20), ((120, -0.4), 20))
    impact = fists(ground(lean=-20, crouch=0.95, lf=-0.6, rf=0.6), ((-80, 0.6), 30), ((-80, -0.6), 30))
    attack(f"{w}.GroundPound", [air_start(w),
                                (0.45, fists(air(lean=0, legs="tuck", lift=0.3), ((50, 0.4), 40), ((50, -0.4), 40)), "Linear"),
                                (0.9, up, "Quad.In"), (1.12, dive, "Quad.Out"), (1.99, dive, "Constant"),
                                (2.0, impact, "Quad.Out"), (2.4, impact, "Sine.InOut"), recover(w)])


fist_moves(W)
