"""
build_all.py - regenerates every Steal a Sock mesh from code and exports GLB files for Studio.

    python -m pip install bpy==4.5.14 pillow (Python 3.11; Blender as a Python module)
    python tools/blender/build_all.py        (from the repo root; ~20 min with the texture bake)
    python tools/blender/build_all.py --no-bake      (flat palette colours only: quick)
    python tools/blender/build_all.py --no-render    (skip the preview sheets)
    python tools/blender/build_all.py --sheets-only  (just re-render the sheets from the GLBs on disk)
    python tools/blender/build_all.py --only Bed,Argylo_L --no-render   (re-export just those)
    python tools/blender/build_all.py --only Towel_Plain,BananaPeel --no-render   (items too)
    python tools/blender/build_all.py --rig-config   (just regenerate src/shared/Config/SockRigConfig.luau)
    python tools/blender/build_all.py --no-rig       (socks without their skeleton: the old static GLBs)

Outputs
    assets/meshes/steal-a-sock/socks/<TypeId>_L.glb, <TypeId>_R.glb, <TypeId>.glb (singles)
    assets/meshes/steal-a-sock/socks/Clothespin.glb   (the pin every hanging sock wears)
    assets/meshes/steal-a-sock/map/<Name>.glb   (Dryer, Bed, Nightstand, Lamp, Blocks, Duck, Teddy,
                                                 Crayons, Basket, Drawer, Window, Bookshelf, Picture)
    assets/meshes/steal-a-sock/items/<Name>.glb  (the item bar's towels and items: items/ package,
                                                 ReplicatedStorage.ItemMeshes)
    assets/meshes/steal-a-sock/palette.png      (the shared colour palette every mesh samples)
    docs/concept/renders/socks.jpg, furniture.jpg, items.jpg  (preview sheets; --no-render skips)
    src/shared/Config/SockRigConfig.luau        (the sock skeletons' bones, for the game's animation code)

Each GLB holds the textured body, a separate `<Name>_Outline` inverted hull (the game turns its
shadows off), optional glow parts (`LampGlow`, `DryerPortal`, `MoonGlow`) and tiny marker parts
(`_Base`, `_Unit`, `_Pin`) the game uses to scale, orient and hang the model. Every body (and the
textured spin parts) gets its own hand-painted JPEG texture baked by texturing.py; outlines, glow
parts and markers keep the flat palette. Every sock GLB also carries a skeleton (rigging.py: one
armature `<Name>_Rig`, one glTF skin shared by the body and the outline). See docs/ART_PIPELINE.md.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))

import bpy  # noqa: E402
import sockkit as K  # noqa: E402
import socks  # noqa: E402
import props  # noqa: E402
import items  # noqa: E402
import texturing  # noqa: E402
import rigging  # noqa: E402

BUILDERS, EXPORT_DIR = props.load_all()
ITEMS, ITEM_MODULE = items.load_all()
OUT = os.path.join(REPO, "assets", "meshes", "steal-a-sock")
SOCK_OUT = os.path.join(OUT, "socks")
MAP_OUT = os.path.join(OUT, "map")
ITEM_OUT = os.path.join(OUT, "items")
RENDERS = os.path.join(REPO, "docs", "concept", "renders")
PALETTE = os.path.join(OUT, "palette.png")
RIG_CONFIG = os.path.join(REPO, "src", "shared", "Config", "SockRigConfig.luau")
MARKERS = ("_Base", "_Unit", "_Pin", "_Grip", "_Tip")   # tiny marker parts the game reads and hides


def sock_jobs():
    jobs = []
    for tid, spec in socks.SPECS.items():
        sides = ["S"] if spec.get("single") else ["L", "R"]
        for side in sides:
            jobs.append((tid, side))
    return jobs


def fresh_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    if os.path.exists(PALETTE):
        img = bpy.data.images.load(PALETTE)
        K.set_palette_image(img)


def _materials(fn):
    """The prop module's optional MATERIALS hints for texturing.py."""
    return getattr(sys.modules.get(fn.__module__), "MATERIALS", None)


def _texture_size(fn):
    """The prop module's optional TEXTURE_SIZE (pixels) for its baked texture, else automatic."""
    return getattr(sys.modules.get(fn.__module__), "TEXTURE_SIZE", None)


def _tex_note(tex):
    return " ".join(f"{n}:{r}px" if r else f"{n}:flat" for n, r, _ in tex) if tex else "-"


def write_rig_config(bodies):
    """SockRigConfig.luau from the planned skeleton of every sock body (one entry per type; per
    side only if the halves ever differ)."""
    tables, order = {}, []
    for tid in socks.SPECS:
        per_side = {b.name: rigging.bone_table(rigging.plan(b)) for b in bodies
                    if b.name == tid or b.name.startswith(tid + "_")}
        sides = list(per_side.values())
        if all(t == sides[0] for t in sides):
            tables[tid] = sides[0]
            order.append(tid)
        else:
            for name in sorted(per_side):
                tables[name] = per_side[name]
                order.append(name)
    rigging.write_luau_config(RIG_CONFIG, tables, order)
    print(f"rig config: {len(order)} entries -> {RIG_CONFIG}")


def main(render=True, bake=True, only=None, rig=True):
    """only: GLB names to (re)export, e.g. {"Bed", "Argylo_L"} (the palette is still written from
    everything, so the other GLBs stay valid); None = all. rig: give every sock its skeleton."""
    os.makedirs(SOCK_OUT, exist_ok=True)
    os.makedirs(MAP_OUT, exist_ok=True)
    os.makedirs(ITEM_OUT, exist_ok=True)
    os.makedirs(RENDERS, exist_ok=True)

    # pass 1: build everything once so every colour is registered, then write the palette (and the
    # rig config, which needs every sock)
    # (socks.LATE types last, after the props: every older colour keeps its palette cell)
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bodies = [socks.build_sock(tid, side)[0] for tid, side in sock_jobs() if tid not in socks.LATE]
    for fn in BUILDERS.values():
        fn()
    bodies += [socks.build_sock(tid, side)[0] for tid, side in sock_jobs() if tid in socks.LATE]
    for fn in ITEMS.values():   # the items last of all (same reason)
        fn()
    K.write_palette(PALETTE)
    print(f"palette: {len(K.PALETTE)} colours -> {PALETTE}")
    if rig:
        write_rig_config(bodies)

    # pass 2: one clean scene per asset -> exact object names -> one GLB each
    report = []
    for tid, side in sock_jobs():
        if only and (f"{tid}_{side}" if side != "S" else tid) not in only:
            continue
        fresh_scene()
        objs = socks.build_sock(tid, side)
        name = objs[0].name
        mats = getattr(socks.feature_module(tid), "MATERIALS", None)   # optional texture hints
        tex = texturing.bake(objs, name, materials=mats, sock_id=tid, sock_side=side) if bake else None
        arm = [rigging.rig_sock(objs)[0]] if rig else []   # after the bake: bones + weights only
        path = os.path.join(SOCK_OUT, name + ".glb")
        K.export_glb(objs + arm, path)
        tris = sum(K.tri_count(o) for o in objs[:2])
        report.append((name, tris, os.path.getsize(path), _tex_note(tex)))
    for name, fn in BUILDERS.items():
        if only and name not in only:
            continue
        fresh_scene()
        objs = fn()
        tex = texturing.bake(objs, name, materials=_materials(fn), res=_texture_size(fn)) if bake else None
        path = os.path.join(SOCK_OUT if EXPORT_DIR[name] == "socks" else MAP_OUT, name + ".glb")
        K.export_glb(objs, path)
        tris = sum(K.tri_count(o) for o in objs if not o.name.endswith(MARKERS))
        report.append((name, tris, os.path.getsize(path), _tex_note(tex)))
    for name, fn in ITEMS.items():
        if only and name not in only:
            continue
        fresh_scene()
        objs = fn()
        mod = ITEM_MODULE[name]
        tex = texturing.bake(objs, name, materials=getattr(mod, "MATERIALS", None),
                             res=getattr(mod, "TEXTURE_SIZE", None)) if bake else None
        arm = mod.rig(name, objs) if rig and hasattr(mod, "rig") else None   # after the bake
        path = os.path.join(ITEM_OUT, name + ".glb")
        K.export_glb(objs + ([arm] if arm else []), path)
        tris = sum(K.tri_count(o) for o in objs if not o.name.endswith(MARKERS))
        report.append((name, tris, os.path.getsize(path), _tex_note(tex)))
    total = 0
    for name, tris, size, note in report:
        total += size
        print(f"{name:22s} {tris:6d} tris  {size / 1024:7.1f} KB  {note}")
    print(f"{len(report)} GLBs, {total / 1024 / 1024:.1f} MB")

    if render:
        render_sheets(from_glb=bake)


def _import_glb(path):
    """The exported GLB back in the scene (so the sheets show the baked textures without re-baking);
    markers hidden like the game does."""
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=path)
    objs = [o for o in bpy.data.objects if o not in before and o.type == "MESH"]
    for o in objs:
        o.hide_render = o.name.endswith(MARKERS)
        if o.name.endswith("_Outline") or o.name == "FanBlades":
            o.visible_shadow = False
            o.visible_diffuse = False
    return objs


SHEET_SKIP = {"RoomShell"}  # the room's own floor / walls / ceiling: no prop-sized cell can frame it


def render_sheets(from_glb=False):
    """Preview sheets of every sock and prop: rebuilt from the scripts, or (from_glb) the exported
    GLBs read back in, textures and all."""
    fresh_scene()
    objs = []
    ids = list(socks.SPECS)
    for i, tid in enumerate(ids):
        side = "S" if socks.SPECS[tid].get("single") else "R"
        built = _import_glb(os.path.join(SOCK_OUT, f"{tid}_{side}.glb" if side != "S" else f"{tid}.glb")) \
            if from_glb else socks.build_sock(tid, side)
        for o in built:
            o.location.x += (i % 7) * 6.5
            o.location.z += -(i // 7) * 10.0
        objs += [o for o in built if not o.hide_render]
    K.render_preview(objs, os.path.join(RENDERS, "socks.jpg"), res=1400, angle=-0.3, elev=0.12)

    fresh_scene()
    objs = []
    # 5-column grid, each prop scaled to fill a 9 x 8 cell (sizes vary wildly in model units)
    sheet = [(n, f) for n, f in BUILDERS.items() if n not in SHEET_SKIP]
    for i, (name, fn) in enumerate(sheet):
        path = os.path.join(SOCK_OUT if EXPORT_DIR[name] == "socks" else MAP_OUT, name + ".glb")
        built = [o for o in (_import_glb(path) if from_glb else fn()) if not o.hide_render]
        ws = [o.matrix_world @ v.co for o in built for v in o.data.vertices]
        lo = [min(w[k] for w in ws) for k in range(3)]
        hi = [max(w[k] for w in ws) for k in range(3)]
        s = min(9.0 / max(hi[0] - lo[0], 1e-3), 8.0 / max(hi[2] - lo[2], 1e-3))
        cx = (lo[0] + hi[0]) / 2
        for o in built:
            o.scale = (s, s, s)
            o.location = ((i % 5) * 11.0 - cx * s, 0, -(i // 5) * 10.5 - lo[2] * s)
        objs += built
    K.render_preview(objs, os.path.join(RENDERS, "furniture.jpg"), res=1400, angle=-0.3, elev=0.12)

    if ITEMS:
        fresh_scene()
        objs = []
        for i, (name, fn) in enumerate(ITEMS.items()):     # same 5-column grid as the furniture
            built = [o for o in (_import_glb(os.path.join(ITEM_OUT, name + ".glb")) if from_glb else fn())
                     if not o.hide_render]
            ws = [o.matrix_world @ v.co for o in built for v in o.data.vertices]
            if not ws:
                continue
            lo = [min(w[k] for w in ws) for k in range(3)]
            hi = [max(w[k] for w in ws) for k in range(3)]
            s = min(9.0 / max(hi[0] - lo[0], 1e-3), 8.0 / max(hi[2] - lo[2], 1e-3))
            cx = (lo[0] + hi[0]) / 2
            for o in built:
                o.scale = (s, s, s)
                o.location = ((i % 5) * 11.0 - cx * s, 0, -(i // 5) * 10.5 - lo[2] * s)
            objs += built
        if objs:
            K.render_preview(objs, os.path.join(RENDERS, "items.jpg"), res=1400, angle=-0.3, elev=0.12)


if __name__ == "__main__":
    if "--rig-config" in sys.argv:   # just the generated Luau skeleton table (builds every sock once)
        bpy.ops.wm.read_factory_settings(use_empty=True)
        write_rig_config([socks.build_sock(tid, side)[0] for tid, side in sock_jobs()])
    elif "--sheets-only" in sys.argv:  # re-render the preview sheets from the GLBs already exported
        bpy.ops.wm.read_factory_settings(use_empty=True)
        for tid, side in sock_jobs():
            if tid not in socks.LATE:
                socks.build_sock(tid, side)
        for fn in BUILDERS.values():
            fn()
        for tid, side in sock_jobs():
            if tid in socks.LATE:
                socks.build_sock(tid, side)
        for fn in ITEMS.values():
            fn()
        render_sheets(from_glb="--no-bake" not in sys.argv)
    else:
        pick = sys.argv[sys.argv.index("--only") + 1].split(",") if "--only" in sys.argv else None
        main(render="--no-render" not in sys.argv and not pick, bake="--no-bake" not in sys.argv,
             only=set(pick) if pick else None, rig="--no-rig" not in sys.argv)
