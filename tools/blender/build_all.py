"""
build_all.py - regenerates every Steal a Sock mesh from code and exports GLB files for Studio.

    python -m pip install bpy==4.5.14        (Python 3.11; Blender as a Python module)
    python tools/blender/build_all.py        (from the repo root)

Outputs
    assets/meshes/steal-a-sock/socks/<TypeId>_L.glb, <TypeId>_R.glb, <TypeId>.glb (singles)
    assets/meshes/steal-a-sock/socks/Clothespin.glb   (the pin every hanging sock wears)
    assets/meshes/steal-a-sock/map/<Name>.glb   (Dryer, Bed, Nightstand, Lamp, Blocks, Duck, Teddy,
                                                 Crayons, Basket, Drawer, Window, Bookshelf, Picture)
    assets/meshes/steal-a-sock/palette.png      (the shared colour palette every mesh samples)
    docs/concept/renders/socks.jpg, furniture.jpg  (preview sheets; pass --no-render to skip)

Each GLB holds the textured body, a separate `<Name>_Outline` inverted hull (the game turns its
shadows off), optional glow parts (`LampGlow`, `DryerPortal`, `MoonGlow`) and tiny marker parts
(`_Base`, `_Unit`, `_Pin`) the game uses to scale, orient and hang the model. See
docs/ART_PIPELINE.md.
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

BUILDERS, EXPORT_DIR = props.load_all()
OUT = os.path.join(REPO, "assets", "meshes", "steal-a-sock")
SOCK_OUT = os.path.join(OUT, "socks")
MAP_OUT = os.path.join(OUT, "map")
RENDERS = os.path.join(REPO, "docs", "concept", "renders")
PALETTE = os.path.join(OUT, "palette.png")


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


def main(render=True):
    os.makedirs(SOCK_OUT, exist_ok=True)
    os.makedirs(MAP_OUT, exist_ok=True)
    os.makedirs(RENDERS, exist_ok=True)

    # pass 1: build everything once so every colour is registered, then write the palette
    bpy.ops.wm.read_factory_settings(use_empty=True)
    for tid, side in sock_jobs():
        socks.build_sock(tid, side)
    for fn in BUILDERS.values():
        fn()
    K.write_palette(PALETTE)
    print(f"palette: {len(K.PALETTE)} colours -> {PALETTE}")

    # pass 2: one clean scene per asset -> exact object names -> one GLB each
    report = []
    for tid, side in sock_jobs():
        fresh_scene()
        objs = socks.build_sock(tid, side)
        name = objs[0].name
        path = os.path.join(SOCK_OUT, name + ".glb")
        K.export_glb(objs, path)
        tris = sum(K.tri_count(o) for o in objs[:2])
        report.append((name, tris, os.path.getsize(path)))
    for name, fn in BUILDERS.items():
        fresh_scene()
        objs = fn()
        path = os.path.join(SOCK_OUT if EXPORT_DIR[name] == "socks" else MAP_OUT, name + ".glb")
        K.export_glb(objs, path)
        tris = sum(K.tri_count(o) for o in objs if not o.name.endswith(("_Base", "_Unit", "_Pin")))
        report.append((name, tris, os.path.getsize(path)))
    for name, tris, size in report:
        print(f"{name:22s} {tris:6d} tris  {size / 1024:7.1f} KB")

    if render:
        render_sheets()


def render_sheets():
    fresh_scene()
    objs = []
    ids = list(socks.SPECS)
    for i, tid in enumerate(ids):
        side = "S" if socks.SPECS[tid].get("single") else "R"
        built = socks.build_sock(tid, side)
        for o in built:
            o.location.x += (i % 7) * 6.5
            o.location.z += -(i // 7) * 10.0
        objs += [o for o in built if not o.hide_render]
    K.render_preview(objs, os.path.join(RENDERS, "socks.jpg"), res=1400, angle=-0.3, elev=0.12)

    fresh_scene()
    objs = []
    x = 0.0
    for name, fn in BUILDERS.items():
        built = [o for o in fn() if not o.hide_render]
        xs = [(o.matrix_world @ v.co).x for o in built for v in o.data.vertices]
        span = max(xs) - min(xs)
        s = 9.0 / max(span, 1e-3) if span > 9.0 else 1.0  # big props shrink to fit a 9-unit cell
        for o in built:
            o.scale = (s, s, s)
            o.location = (x - min(xs) * s, 0, 0)
        x += span * s + 1.5
        objs += built
    K.render_preview(objs, os.path.join(RENDERS, "furniture.jpg"), res=1400, angle=-0.45, elev=0.35)


if __name__ == "__main__":
    main(render="--no-render" not in sys.argv)
