# Art pipeline — from concept art to the game

The game is code-built from Parts so it always runs, but every hero piece can be replaced by a
real mesh **without touching the code**: drop a model into one of two folders in
`ReplicatedStorage` and the builders use it. Concept art to match lives in `docs/concept/`.

## Where meshes go

| Folder | Name the model exactly | What happens |
| --- | --- | --- |
| `ReplicatedStorage.SockMeshes` | the type id from `SockConfig` (`Argylo`, `Sockrates`, `Socktopus`, …) or `Argylo_L` / `Argylo_R` for different halves | `Factory` uses it as the sock body: scaled to the standard sock height, invisible root added, rarity glow + mutation look + label + all game hooks still apply. A small L/R tag is added when one mesh serves both halves. |
| `ReplicatedStorage.MapMeshes` | `Bed`, `Nightstand`, `Lamp`, `Dryer`, `Basket`, `Duck`, `Teddy`, `Blocks`, `Crayons`, `Drawer` | `Map` places it instead of the Part version, scaled to fit its slot, bottom on the floor. `Dryer` keeps the spinning portal light; `Drawer` becomes the shell of all 8 bases (walls stay for collision, invisible). |

Both folders are created empty on the first Play. A model can be a `Model` or a single `MeshPart`.
Face direction: socks face **+Z** (the eyes); the dryer's porthole faces the clothesline, which the
builder handles by rotating the template so its **front (+Z)** points down the line.

The server prints `[Factory] N sock mesh template(s)` / `[Map] N mesh template(s)` in Output on
start so you can see what was picked up.

## Three ways to get meshes

### 1. Roblox Mesh Generator (inside Studio, free, no import step)
Studio → Assistant panel (or the Mesh Generator beta in the Create tab). Describe one object at a
time, e.g.
> a chunky cartoon sock character standing up in an L shape, brown argyle pattern with yellow
> diamonds, big round googly eyes, a gold monocle, low-poly toy style, thick soft shapes
Generate, pick the best, then rename it `Argylo` and drag it into `ReplicatedStorage.SockMeshes`.
Use `docs/concept/sock_character_sheet.png` and `bedroom_keyframe.png` as the reference image
where the tool accepts one.

### 2. Image-to-3D services (Meshy, Tripo, Higgsfield 3D)
Give the service one clean picture of one object (crop it from the character sheet, or ask
Higgsfield for a single-sock image on a plain background). Export **GLB or FBX** with textures.
In Studio: File → Import 3D → pick the files (multi-select works) → Import. Each arrives in
Workspace as a MeshPart/Model with its texture. Rename and move it into the right folder, or paste
this into your local Claude:

```text
Several imported meshes are sitting in Workspace (from File > Import 3D). Move each one into ReplicatedStorage.SockMeshes or ReplicatedStorage.MapMeshes and rename it to the exact name docs/ART_PIPELINE.md lists (sock type ids from src/shared/Config/SockConfig.luau; furniture names Bed, Nightstand, Lamp, Dryer, Basket, Duck, Teddy, Blocks, Crayons, Drawer). Make sure each Model has a PrimaryPart, its parts are Anchored, CanCollide false for socks, and that the sock meshes face +Z (rotate the model if the eyes face another way). Then press Play for me... actually don't: list what you moved and tell me to press Play.
```

Higgsfield (connected to the cloud Claude) has `sam_3_3d` (lifts one object out of a picture),
Meshy `image_to_3d` and Tripo `image_to_3d`; the cloud session can run them and commit the GLBs to
`assets/meshes/` in this branch so they download with `git pull`. Daily generation limits apply.

### 3. Creator Store models (fastest for furniture)
Your local Claude can insert free models by search. Paste:

```text
Read docs/ART_PIPELINE.md. Using the Roblox Studio MCP insert tool, find free low-poly cartoon models on the Creator Store for: a bed, a nightstand, a table lamp, a rubber duck, a teddy bear, letter blocks, crayons, a laundry basket, a washing machine or dryer, and an open dresser drawer. Prefer one consistent chunky low-poly toy style that matches docs/concept/bedroom_keyframe.png. Put each into ReplicatedStorage.MapMeshes with the exact names Bed, Nightstand, Lamp, Duck, Teddy, Blocks, Crayons, Basket, Dryer, Drawer (one drawer model - the game clones it). Make sure each is a Model with a PrimaryPart, anchored, no scripts inside (delete any Script/LocalScript you find), and that the dryer's door faces +Z. Skip anything that has scripts you can't remove. List what you inserted with the asset ids, then tell me to press Play.
```

**Always delete scripts inside free models** — the local Claude is told to, but check the Output
for anything unexpected on the first Play.

## Checking the result

1. Play. Output shows the template counts.
2. Socks with meshes should hang at the same height as Part socks and sit on the slot cushions.
   If a mesh is off-centre, its pivot is wrong: in Studio select the model → Pivot → Reset.
3. If a furniture piece is too big/small, it was fitted to the slot size in `Map.luau`
   (`placeTemplate(name, floorCF, fitSize)`) — adjust the fit size there.
4. Run `scripts/check.sh` before pushing (no code changes are needed for meshes, but keep the habit).

## Style rules (from `docs/concept/`)

- Chunky, rounded, low-poly; thick dark outlines read well at Roblox scale — bake them into the
  texture, don't rely on edge shaders.
- Palette: warm wood `#B07A46`, cream `#F3E6CC`, coral `#E8A08C`, blanket blue `#5C7FD1`, red
  stripe `#D94F4F`, lamp yellow `#FFE58A`, night wall `#3E3A6E`, portal purple `#7A3FE0`.
- Every sock: big white googly eyes, one signature accessory, one accent stripe. Left and right
  halves are mirror images; a single mesh serving both is fine (the game tags L/R).
