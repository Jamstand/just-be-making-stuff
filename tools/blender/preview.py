"""
preview.py - render ONE asset (or a few) quickly, optionally next to a concept-art crop.

    python tools/blender/preview.py sock:Argylo                 (right sock, front view)
    python tools/blender/preview.py sock:Argylo:L --views front,three
    python tools/blender/preview.py socks:Tubolino,Argylo,Sockhopper
    python tools/blender/preview.py prop:Bed --views three,front,top --compare crop.png
    python tools/blender/preview.py props:all

Options
    --out PATH      output image (default: <scratch>/previews/<target>.png)
    --res N         pixels per view (default 560)
    --views LIST    comma list of: front (camera at -Y), three (3/4 from front-left, default),
                    threer (3/4 from front-right), side (+X), back, top, low (worm's eye)
                    or angle/elev pairs like 0.3/0.2 (radians)
    --compare PNG   also writes <out>_vs.png: the crop on the left, the render on the right
    --samples N     Cycles samples (default 20)
    --glb DIR       also export the target (single sock:/prop: targets) to DIR/<name>.glb exactly as
                    build_all.py would, to prove it exports (never writes into the repo)

Prints triangle counts per exported object. Uses the same build code as build_all.py, so what you
see is what gets exported (outline hull drawn the way Roblox draws it: back faces hidden).
"""
import argparse
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import bpy  # noqa: E402
import sockkit as K  # noqa: E402
# socks / props are imported lazily, only the asset being previewed: a half-edited module of another
# asset can't break this preview.

VIEWS = {"front": (0.0, 0.08), "three": (-0.6, 0.3), "threer": (0.6, 0.3), "side": (1.5708, 0.08),
         "back": (3.1416, 0.15), "top": (0.0, 1.35), "low": (-0.4, -0.05)}
DEFAULT_OUT = os.path.join(os.environ.get("PREVIEW_DIR", tempfile.gettempdir()), "previews")


def build(target):
    kind, _, rest = target.partition(":")
    objs = []
    if kind in ("sock", "socks"):
        import socks
    if kind in ("prop", "props"):
        import props
    if kind == "sock":
        tid, _, side = rest.partition(":")
        side = side or ("S" if socks.SPECS[tid].get("single") else "R")
        objs = socks.build_sock(tid, side)
    elif kind == "socks":
        ids = list(socks.SPECS) if rest == "all" else rest.split(",")
        for i, tid in enumerate(ids):
            side = "S" if socks.SPECS[tid].get("single") else "R"
            built = socks.build_sock(tid, side)
            for o in built:
                o.location.x += (i % 7) * 6.5
                o.location.z += -(i // 7) * 10.0
            objs += built
    elif kind == "prop":
        objs = props.load(rest).build()
    elif kind == "props":
        names = props.MODULE_NAMES if rest == "all" else rest.split(",")
        x = 0.0
        for name in names:
            built = props.load(name).build()
            xs = [(o.matrix_world @ v.co).x for o in built if not o.hide_render for v in o.data.vertices]
            w = (max(xs) - min(xs)) if xs else 1
            for o in built:
                o.location.x += x - min(xs)
            x += w * 1.15
            objs += built
    else:
        raise SystemExit("target must be sock:<id>[:L|R], socks:<a,b,..|all>, prop:<Name>, props:<a,b|all>")
    return objs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("target")
    ap.add_argument("--out")
    ap.add_argument("--res", type=int, default=560)
    ap.add_argument("--views", default="three")
    ap.add_argument("--compare")
    ap.add_argument("--samples", type=int, default=20)
    ap.add_argument("--glb")
    a = ap.parse_args()
    os.makedirs(DEFAULT_OUT, exist_ok=True)
    out = a.out or os.path.join(DEFAULT_OUT, a.target.replace(":", "_").replace(",", "+") + ".png")

    bpy.ops.wm.read_factory_settings(use_empty=True)
    objs = build(a.target)
    for o in objs:
        if not o.hide_render:
            print(f"{o.name:28s} {K.tri_count(o):6d} tris")
    pal = os.path.join(tempfile.gettempdir(), f"palette_preview_{os.getpid()}.png")
    img = K.write_palette(pal)
    K.set_palette_image(img)
    visible = [o for o in objs if not o.hide_render]
    if a.glb:
        os.makedirs(a.glb, exist_ok=True)
        path = os.path.join(a.glb, objs[0].name + ".glb")
        K.export_glb(objs, path)
        print(f"exported {path} ({os.path.getsize(path) / 1024:.1f} KB): " + ", ".join(o.name for o in objs))

    from PIL import Image
    tiles = []
    for i, v in enumerate(a.views.split(",")):
        ang, elev = VIEWS[v] if v in VIEWS else map(float, v.split("/"))
        path = out + f".view{i}.png"
        K.render_preview(visible, path, res=a.res, angle=ang, elev=elev, samples=a.samples)
        tiles.append(Image.open(path).convert("RGB"))
    sheet = Image.new("RGB", (sum(t.width for t in tiles), max(t.height for t in tiles)))
    x = 0
    for t in tiles:
        sheet.paste(t, (x, 0))
        x += t.width
    sheet.save(out)
    for i in range(len(tiles)):
        os.remove(out + f".view{i}.png")
    print("wrote", out)
    if a.compare:
        ref = Image.open(a.compare).convert("RGB")
        s = sheet.height / ref.height
        ref = ref.resize((max(1, int(ref.width * s)), sheet.height))
        vs = Image.new("RGB", (ref.width + 12 + sheet.width, sheet.height), (20, 20, 20))
        vs.paste(ref, (0, 0))
        vs.paste(sheet, (ref.width + 12, 0))
        vs_path = os.path.splitext(out)[0] + "_vs.png"
        vs.save(vs_path)
        print("wrote", vs_path)


if __name__ == "__main__":
    main()
