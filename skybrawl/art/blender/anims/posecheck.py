"""
Posed clipping check for the legends: poses each legend's accessories and
body blocks in every key of the clips it plays (locomotion, Unarmed, its two
weapons and its own "<Legend>.*" clips, which replace the shared clips they
are named after: signature moves, Brann's guard) and reports where an
accessory cuts into a limb, or two accessories cut into each other, further
than they do at rest.

    python art/blender/build.py fighters posecheck [names] [--attacks]

By default only the clips that loop on screen (idles, runs, blocks, jumps,
dodges) are checked; --attacks adds the attack clips, where a support hand
brushing hair for a frame is usually fine. Sway pieces (capes, tails,
dreads) are left out: in game they hang on springs and are pushed off the
body.

Each line names the accessory, what it cuts into, the worst key (clip@time),
how many vertices are inside and how deep (R6 studs), and in how many keys.
Accessory pairs report the extra triangles that intersect (depth "-").
"""

import importlib

import numpy as np
from mathutils.bvhtree import BVHTree

from sky import avatar as A
from sky import skeleton

from . import core
from .stances import legend_weapons

S = skeleton.R6_SCALE
DEEP = 0.08  # R6 studs inside a limb counts as clipping
REPORT_DEPTH = 0.1  # report a limb hit this deep...
REPORT_VERTS = 12  # ...or this many vertices inside
REPORT_TRIS = 10  # extra intersecting triangles between two accessories

# Body blocks (name, joint, x center, width, y0, y1) in R6 studs, split at
# the joints like the avatar builder's SPLITS.
SEGMENTS = [("LowerTorso", "Root", 0.0, 2.0, 2.0, 2.5), ("UpperTorso", "Waist", 0.0, 2.0, 2.5, 4.0)]
for _side, _s in skeleton.SIDES:
    SEGMENTS += [
        (f"{_side}Hand", f"{_side}Wrist", _s * 1.5, 1.0, 2.0, 2.45),
        (f"{_side}LowerArm", f"{_side}Elbow", _s * 1.5, 1.0, 2.45, 2.9),
        (f"{_side}UpperArm", f"{_side}Shoulder", _s * 1.5, 1.0, 2.9, 4.0),
        (f"{_side}Foot", f"{_side}Ankle", _s * 0.5, 1.0, 0.0, 0.5),
        (f"{_side}LowerLeg", f"{_side}Knee", _s * 0.5, 1.0, 0.5, 1.25),
        (f"{_side}UpperLeg", f"{_side}Hip", _s * 0.5, 1.0, 1.25, 2.0),
    ]
LIMB_OF = {name: ("Torso" if name.endswith("Torso") else
                  next(side + ("Arm" if ("Arm" in name or "Hand" in name) else "Leg")
                       for side, _ in skeleton.SIDES if name.startswith(side)))
           for name, *_ in SEGMENTS}


def _sd_box(q, cx, w, y0, y1):
    c = np.array([cx, (y0 + y1) / 2, 0.0])
    h = np.array([w / 2, (y1 - y0) / 2, A.DEPTH / 2])
    d = np.abs(q - c) - h + A.BEVEL
    return np.linalg.norm(np.maximum(d, 0.0), axis=1) + np.minimum(d.max(axis=1), 0.0) - A.BEVEL


def _sd_head(q):
    return np.array([A.head_sdf(tuple(p)) for p in q])


def _frames(pose):
    out = {}
    for joint in skeleton.PIVOT:
        pos, rot = core.fk(pose, joint)
        out[joint] = (np.array(pos), np.array(rot), np.array(skeleton.PIVOT[joint]))
    return out


def _to_world(pts, joint, fr):
    """Rest-pose points (R6 studs) carried by `joint` -> posed rig space."""
    pos, rot, piv = fr[joint]
    return pos + (pts * S - piv) @ rot.T


def _to_rest(world, joint, fr):
    """Posed rig-space points -> `joint`'s rest frame (R6 studs)."""
    pos, rot, piv = fr[joint]
    return (piv + (world - pos) @ rot) / S


class Fit:
    def __init__(self, module):
        av = A.Avatar(module)
        module.model(av)
        self.name = av.name
        self.pieces = []
        for pc in av.pieces:
            if pc.bind[0] != "bone" or not pc.mb.bm.verts:
                continue
            bm = pc.mb.bm
            verts = np.array([tuple(v.co) for v in bm.verts])
            tris = [[v.index for v in f.verts] for f in bm.faces]
            self.pieces.append((pc.name, pc.bind[1], verts, tris, set(pc.encases)))
        rest = _frames(core.REST)
        self.base = {k: d < -DEEP for k, d in self._depths(rest).items()}
        self.pairs = [(i, j) for i in range(len(self.pieces)) for j in range(i + 1, len(self.pieces))
                      if self.pieces[i][1] != self.pieces[j][1]]
        trees = self._trees(rest)
        self.base_pairs = {p: len(trees[p[0]].overlap(trees[p[1]])) for p in self.pairs}

    def _depths(self, fr):
        out = {}
        for name, joint, verts, _, encases in self.pieces:
            world = _to_world(verts, joint, fr)
            for seg, sj, cx, w, y0, y1 in SEGMENTS:
                if sj != joint and LIMB_OF[seg] not in encases:
                    out[(name, seg)] = _sd_box(_to_rest(world, sj, fr), cx, w, y0, y1)
            if joint != "Neck" and "Head" not in encases:
                out[(name, "Head")] = _sd_head(_to_rest(world, "Neck", fr))
        return out

    def _trees(self, fr):
        return [BVHTree.FromPolygons([tuple(p) for p in _to_world(v, j, fr)], t) for _, j, v, t, _ in self.pieces]

    def run(self, keys):
        """keys: [(clip name, time, pose)]. Returns {(piece, what): [verts or
        tris, depth, worst key, keys]}."""
        worst = {}

        def note(k, amount, depth, where):
            w = worst.setdefault(k, [0, 0.0, "", 0])
            w[3] += 1
            if amount * max(depth, 0.05) > w[0] * max(w[1], 0.05):
                w[0], w[1], w[2] = amount, depth, where

        for clip, t, pose in keys:
            fr = _frames(pose)
            where = f"{clip}@{t:g}"
            for k, d in self._depths(fr).items():
                new = (d < -DEEP) & ~self.base[k]
                if new.any():
                    note(k, int(new.sum()), float(-d[new].min()), where)
            if self.pairs:
                trees = self._trees(fr)
                for i, j in self.pairs:
                    extra = len(trees[i].overlap(trees[j])) - self.base_pairs[(i, j)]
                    if extra > REPORT_TRIS:
                        note((self.pieces[i][0], self.pieces[j][0]), extra, 0.0, where)
        return {k: w for k, w in worst.items()
                if (w[1] == 0.0) or w[1] >= REPORT_DEPTH or w[0] >= REPORT_VERTS}


def clips_for(clips, legend, weapons, attacks=False):
    """The clips `legend` plays: the game tries "<Legend>.<Name>" before the
    shared "<Name>", so a shared clip with a legend version is skipped."""
    groups = ("Loco", "Unarmed") + tuple(weapons)
    shared = {n for n in clips if n.split(".")[0] in groups and f"{legend}.{n}" not in clips}
    return {n: c for n, c in clips.items()
            if (n in shared or n.startswith(legend + ".")) and (attacks or not c.phased)}


def check(names, attacks=False):
    """Prints the posed clipping report for the named fighter scripts and
    returns {legend: findings}."""
    import anims

    clips = anims.load_clips()
    weapons = legend_weapons()
    out = {}
    for name in names:
        module = importlib.import_module(f"fighters.{name}")
        fit = Fit(module)
        mine = clips_for(clips, fit.name, weapons.get(fit.name, ()), attacks)
        keys = [(n, t, pose) for n, c in sorted(mine.items()) for t, pose, _ in c.keys]
        found = fit.run(keys)
        out[fit.name] = found
        print(f"== {fit.name}: {len(keys)} keys in {len(mine)} clips; accessories {[p[0] for p in fit.pieces]}")
        if not found:
            print("   clean")
        for (piece, what), (amount, depth, where, count) in sorted(found.items(),
                                                                  key=lambda kv: -kv[1][0] * max(kv[1][1], 0.05)):
            unit = "verts" if depth else "tris "
            deep = f"{depth:.2f}" if depth else "  - "
            print(f"   {piece:>14s} into {what:<14s} {amount:5d} {unit} {deep} deep at {where:<30s} ({count} keys)")
    return out
