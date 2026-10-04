"""
SkyShip background: a sky-port at golden afternoon. A floating harbor town
with a lighthouse and docks on the left, a lighthouse isle on the right, an
airship fleet drifting through the middle sky, towering cumulus on the
horizon over a sea of clouds, and near cloud banks along the bottom.
"""

from vistas import _kit as K

MAP_ID = "SkyShip"
SEED = 7

COLORS = {
    "grass": "#86d36c",
    "grass_dark": "#4f9e5b",
    "rock": "#c29a7c",
    "rock_dark": "#86625a",
    "wall": "#fbeed7",
    "wall_blue": "#d3e5f3",
    "wall_peach": "#f7d0ad",
    "roof_red": "#dc5a40",
    "roof_teal": "#2f9fa0",
    "roof_navy": "#41569a",
    "roof_gold": "#e9b04a",
    "wood": "#b07a50",
    "wood_dark": "#6f4836",
    "stone": "#e0d7c8",
    "white": "#fbf7ef",
    "stripe": "#dc4f43",
    "balloon_red": "#e6654c",
    "balloon_cream": "#f6e6c4",
    "balloon_teal": "#43acaa",
    "balloon_violet": "#8f70c9",
    "sail": "#f8eed8",
    "hull": "#8f5c3f",
    "gold": "#f2c45c",
    "iron": "#4d5268",
    "leaves": "#72c56c",
    "leaves_dark": "#43925a",
    "trunk": "#7c5139",
    "blossom": "#f5a9c3",
    "cloud": "#ffffff",
    "window": "#ffd47e",
    "lamp": "#fff3b8",
    "lantern": "#ffb85e",
    "bird": "#4c5172",
}

LOOK = {
    "dome": [(-0.35, "#f0b08c"), (-0.02, "#ffd79a"), (0.08, "#ffe8b6"), (0.3, "#93d3e8"), (0.8, "#2c74b6")],
    "sun": (-0.56, 0.76),
    "sky_fog_scale": 3.6,
}

ISLE = ("grass", "grass_dark", "rock", "rock_dark")


def scene(v):
    r = K.rng(SEED)
    far(v, r)
    harbor(v, r)
    lighthouse_isle(v, r)
    fleet(v, r)
    haze(v, r)


def far(v, r):
    """Sky layer: a sea of clouds to the horizon, cumulus towers, high streaks
    and the farthest islands."""
    clouds = v.piece("Sky", "Cloud")
    solid = v.piece("Sky", "Solid")
    for _ in range(46):
        d = r.uniform(3500, 24000)
        x = r.uniform(-1.25, 1.25) * d * v.tan_h
        K.cumulus(clouds, (x, -1300 + r.uniform(-200, 120), -d), r.uniform(0.18, 0.32) * v.unit(d) * 0.55, "cloud",
                  r, height=0.7, depth=0.7)
    for u, d, w, h in ((-0.78, 15000, 0.34, 2.4), (-0.5, 19000, 0.22, 1.8), (0.62, 16000, 0.38, 2.7),
                       (0.95, 20000, 0.25, 1.9), (0.12, 22000, 0.18, 1.5)):
        base = v.at(u, -0.3, d)
        K.cumulus(clouds, (base[0], -1400, base[2]), w * v.unit(d), "cloud", r, height=h, depth=0.6, puffs=10)
    for u, sv, d, length in ((0.1, 0.8, 9000, 0.16), (0.42, 0.72, 10000, 0.2), (0.85, 0.86, 8000, 0.12),
                             (-0.05, 0.9, 8500, 0.12), (0.62, 0.95, 9000, 0.1)):
        for k in range(3):
            K.streak(clouds, v.at(u + (k - 1) * length * 0.55 + r.uniform(-0.02, 0.02), sv + r.uniform(-0.03, 0.03),
                                  d), length * r.uniform(0.6, 1.0) * v.unit(d), "cloud")
    for u, sv, d, s in ((0.2, -0.22, 7000, 0.07), (-0.16, -0.25, 10500, 0.06), (0.4, -0.25, 12000, 0.05)):
        c = v.at(u, sv, d)
        top = K.island(solid, c, s * v.unit(d), ISLE, r)
        K.tower(solid, None, (c[0], top, c[2]), s * v.unit(d) * 0.05, s * v.unit(d) * 0.35, "stone", "roof_navy")


def harbor(v, r):
    """The sky-port town on the left, with satellite islands."""
    solid = v.piece("Landmarks", "Solid")
    glow = v.piece("Landmarks", "Glow")
    clouds = v.piece("Landmarks", "Cloud")
    d = 1500
    c = v.at(-0.62, -0.26, d)
    s = 0.36 * v.unit(d)
    top = K.island(solid, c, s, ISLE, r, segments=13)
    x, _, z = c
    # houses, back to front
    spots = [(-0.3, -0.18, "wall", "roof_red"), (-0.12, -0.25, "wall_blue", "roof_navy"),
             (0.08, -0.22, "wall_peach", "roof_teal"), (0.22, -0.12, "wall", "roof_gold"),
             (-0.22, 0.02, "wall_peach", "roof_navy"), (-0.02, -0.02, "wall", "roof_red"),
             (0.16, 0.08, "wall_blue", "roof_red"), (-0.34, 0.12, "wall", "roof_teal"),
             (0.02, 0.18, "wall_peach", "roof_gold")]
    for fx, fz, wall, roof in spots:
        w = s * r.uniform(0.075, 0.1)
        K.house(solid, glow, (x + fx * s, top, z + fz * s), w, w * r.uniform(0.75, 1.15), w * 0.9, wall, roof,
                chimney="stone" if r.random() < 0.4 else None)
    K.tower(solid, glow, (x - 0.1 * s, top, z - 0.3 * s), s * 0.045, s * 0.36, "stone", "roof_navy", band="gold")
    K.tower(solid, glow, (x + 0.3 * s, top, z - 0.2 * s), s * 0.035, s * 0.24, "wall", "roof_red", band="gold")
    beacon = K.lighthouse(solid, glow, (x + 0.38 * s, top, z + 0.05 * s), s * 0.55)
    for fx in (-0.42, 0.06):
        K.pennant(solid, (x + fx * s, top + s * 0.2, z + 0.25 * s), s * 0.06, "roof_red")
    for fx in (-0.4, 0.3):
        K.tree(solid, (x + fx * s, top, z + 0.3 * s), s * 0.22, r)
    # dock with a moored airship
    dock_y = top - s * 0.03
    K.dock(solid, glow, (x + 0.47 * s, dock_y, z + 0.1 * s), s * 0.36, s * 0.07)
    K.airship(solid, glow, (x + 0.72 * s, dock_y + s * 0.13, z - 0.05 * s), s * 0.5, "balloon_cream", "stripe",
              facing=-1)
    # cloud skirt under the island
    for fx, fy in ((-0.3, -0.62), (0.1, -0.7), (0.4, -0.55)):
        K.cumulus(clouds, (x + fx * s, c[1] + fy * s, z + 0.1 * s), s * 0.42, "cloud", r, height=0.6)
    # satellite islands
    for u, sv, dd, frac, extra in ((-0.92, 0.04, 1900, 0.13, "tree"), (-0.36, -0.52, 1250, 0.09, "house"),
                                   (-0.8, 0.36, 3600, 0.06, "tower"), (-1.12, -0.3, 1700, 0.12, "tree")):
        cc = v.at(u, sv, dd)
        ss = frac * v.unit(dd)
        tt = K.island(solid, cc, ss, ISLE, r)
        if extra == "tree":
            K.tree(solid, (cc[0] - 0.1 * ss, tt, cc[2]), ss * 0.5, r, leaves="blossom")
            K.tree(solid, (cc[0] + 0.15 * ss, tt, cc[2] + 0.1 * ss), ss * 0.4, r)
        elif extra == "house":
            K.house(solid, glow, (cc[0], tt, cc[2]), ss * 0.25, ss * 0.22, ss * 0.22, "wall", "roof_teal")
        else:
            K.tower(solid, glow, (cc[0], tt, cc[2]), ss * 0.08, ss * 0.6, "stone", "roof_red", band="gold")
    return beacon


def lighthouse_isle(v, r):
    solid = v.piece("Landmarks", "Solid")
    glow = v.piece("Landmarks", "Glow")
    clouds = v.piece("Landmarks", "Cloud")
    d = 2000
    c = v.at(0.66, -0.16, d)
    s = 0.2 * v.unit(d)
    top = K.island(solid, c, s, ISLE, r)
    x, _, z = c
    K.lighthouse(solid, glow, (x + 0.08 * s, top, z), s * 0.95, stripes=("white", "roof_navy"), cap="roof_navy")
    K.house(solid, glow, (x - 0.22 * s, top, z + 0.12 * s), s * 0.16, s * 0.14, s * 0.15, "wall_blue", "roof_red")
    K.tree(solid, (x + 0.3 * s, top, z + 0.18 * s), s * 0.3, r)
    K.cumulus(clouds, (x, c[1] - 0.6 * s, z + 0.1 * s), s * 0.6, "cloud", r, height=0.6)
    cc = v.at(0.4, -0.34, 1750)
    ss = 0.07 * v.unit(1750)
    tt = K.island(solid, cc, ss, ISLE, r)
    K.tree(solid, (cc[0], tt, cc[2]), ss * 0.55, r, leaves="blossom")
    K.bridge(solid, (cc[0] + ss * 0.45, tt + ss * 0.02, cc[2]), (x - 0.42 * s, top + s * 0.01, z + 0.05 * s))
    far_isle = v.at(1.08, 0.1, 2600)
    fs = 0.1 * v.unit(2600)
    ft = K.island(solid, far_isle, fs, ISLE, r)
    K.tower(solid, glow, (far_isle[0], ft, far_isle[2]), fs * 0.07, fs * 0.5, "wall", "roof_teal", band="gold")


def fleet(v, r):
    solid = v.piece("Landmarks", "Solid")
    glow = v.piece("Landmarks", "Glow")
    for u, sv, d, frac, balloon, facing in ((0.28, 0.42, 1150, 0.2, "balloon_red", -1),
                                             (-0.2, 0.58, 2300, 0.12, "balloon_teal", 1),
                                             (0.04, 0.2, 3600, 0.08, "balloon_cream", -1),
                                             (0.6, 0.66, 3000, 0.1, "balloon_violet", -1),
                                             (-0.5, 0.33, 2900, 0.09, "balloon_red", 1),
                                             (1.05, 0.45, 2500, 0.1, "balloon_teal", -1)):
        K.airship(solid, glow, v.at(u, sv, d), frac * v.unit(d), balloon, "stripe" if balloon != "balloon_red"
                  else "balloon_cream", facing=facing)
    K.flock(solid, v.at(0.12, 0.08, 900), 2.2, r, count=5)
    K.flock(solid, v.at(-0.3, 0.7, 1400), 3.0, r, count=3)


def haze(v, r):
    """Near cloud banks along the bottom and in the lower corners."""
    clouds = v.piece("Haze", "Cloud")
    us = [-1.32, -1.08, -0.84, -0.6, -0.34, -0.08, 0.2, 0.46, 0.72, 0.96, 1.2, 1.4]
    vs = [-0.62, -0.74, -0.86, -0.96, -1.04, -1.08, -1.06, -1.02, -0.92, -0.8, -0.68, -0.58]
    K.cloud_row(clouds, v, us, vs, 700, 0.2, "cloud", r, height=0.75)
    K.cloud_row(clouds, v, [u + 0.12 for u in us[:-1]], [sv - 0.1 for sv in vs[:-1]], 560, 0.17, "cloud", r,
                height=0.7)
    for u, sv, d, w in ((-1.3, 0.88, 900, 0.22), (1.32, 0.94, 1000, 0.2)):
        K.cumulus(clouds, v.at(u, sv, d), w * v.unit(d), "cloud", r, height=0.6)
