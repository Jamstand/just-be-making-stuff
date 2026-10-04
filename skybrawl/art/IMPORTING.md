# Importing the art into Roblox Studio

The game runs without any of this: fighters fall back to your Roblox
avatar, weapons and maps to code-built Parts, and skies to gradients. The
steps below swap in the Blender art. You only do them once per asset (and
again if you rebuild an asset).

Everything you import goes into **three folders in ReplicatedStorage**, and
the names matter:

| Folder (in ReplicatedStorage) | Files to import                  | Name each model     |
|-------------------------------|----------------------------------|---------------------|
| `FighterModels`               | `art/export/fighters/*.fbx` (6)  | `Kestrel`, `Brann`, `Yuki`, `Moss`, `Vex`, `Sol` |
| `WeaponMeshes`                | `art/export/weapons/*.fbx` (18)  | the file name: `Sword`, `KestrelSword`, `BrannHammer`, ... |
| `MapModels`                   | `art/export/maps/*.fbx` (4)      | `SkyShip`, `VolcanicForge`, `FrozenPeaks`, `JungleTemple` |

Animations need no importing: they're data in `src/shared/AnimationData`,
which Rojo already syncs.

## 1. Open the place and create the folders

1. Build and open the place as in the main README (or open the place you
   already play-test in).
2. In the Explorer, right-click **ReplicatedStorage** > Insert Object >
   **Folder**, three times. Name them `FighterModels`, `WeaponMeshes` and
   `MapModels`.

## 2. Import the FBX files

1. Click **Import 3D** (Home or Model tab; File > Import 3D also works) and
   pick one or more `.fbx` files from one of the `art/export/...` folders.
   You can select several files at once.
2. In the import window, for each file:
   - **Rig type: No rig.** These are plain models. The game builds the
     joints itself, so don't let Studio rig them.
   - **Merge meshes: off.** Every part has to stay a separate MeshPart
     (`Head`, `LeftUpperArm`, ..., `Body`/`Glow`, map pieces).
   - Keep the three `Marker_` meshes in the import. They look like tiny
     cubes and should not be deleted.
   - Leave textures on. Each file carries one small palette image.
   - Scale and orientation don't matter: the game reads the markers and
     undoes whatever the importer did.
3. Click **Import**. Studio uploads the meshes and textures to your account
   and drops a Model into the Workspace.
4. Drag each imported Model into its folder from the table above and rename
   it exactly as shown. The importer usually names it after the file
   already.

Check that a fighter model contains 15 MeshParts named like R15 body parts
plus `Marker_Origin`, `Marker_Up` and `Marker_Front`. A weapon should contain
`Body` (plus `Glow` for the glowing skins) and the markers. A map kit should
contain its pieces (`Stage`, `Platforms`, `SceneryNear`, ...) and the markers.

## 3. Upload the background images

Each map's background has three painted layers, drawn far behind the stage
back to front. They slide at different speeds as the camera moves, which gives
the background its depth:

| Layer | File | What it is |
|---|---|---|
| `Sky` | `art/export/skies/painted/<MapId>_Sky.png` | the far sky, opaque |
| `Landmarks` | `art/export/skies/painted/<MapId>_Landmarks.png` | the map's distant vista, transparent PNG |
| `Haze` | `art/export/skies/painted/<MapId>_Haze.png` | near clouds and haze, transparent PNG |

`art/previews/vistas/<MapId>_blend.jpg` shows each map's three layers stacked
the way the game first shows them.

1. Open **View > Asset Manager**, click **Bulk Import** and select the
   twelve PNGs in `art/export/skies/painted/`. (The older single-image skies
   in `art/export/skies/<MapId>.png` also still work, as a `Sky` layer on
   their own.)
2. Right-click each uploaded image > **Copy Asset ID**.
3. Paste the ids into `src/shared/Config.luau`, under
   `Config.Art.SkyImages` (just the number, or `rbxassetid://123`). A layer
   you leave `""` is skipped:

```lua
SkyImages = {
	SkyShip = { Sky = "1234567890", Landmarks = "...", Haze = "..." },
	VolcanicForge = { Sky = "...", Landmarks = "...", Haze = "..." },
	FrozenPeaks = { Sky = "...", Landmarks = "...", Haze = "..." },
	JungleTemple = { Sky = "...", Landmarks = "...", Haze = "..." },
},
```

The layers' depth and scroll speed are in `Config.Art.SkyLayers`. The nearer
layers are drawn a little larger than the screen so they can slide (the
`Haze` layer shows roughly its middle 75% until the camera pans). The
paintings are rendered with that extra border built in, so panning reveals
more of the scene. If you change a layer's `Parallax`, change it in
`art/blender/sky/vista.py` (`PARALLAX`) too and re-render the backgrounds
(`tests/art` checks that the two match).

## 4. Keep the imports

The imported models live in your place file, not in this repo. To keep them:

- **Save the place** (File > Save to Roblox, or Save to File) and keep
  working in that copy. Sync code changes with `rojo serve` and the Rojo
  Studio plugin. `default.project.json` tells Rojo to leave anything it
  doesn't manage in ReplicatedStorage alone, so the three art folders stay.
- **Or, if you rebuild the place from scratch with `rojo build`:**
  right-click each of the three folders > **Save to File** and save them as
  `skybrawl/assets/FighterModels.rbxm`, `WeaponMeshes.rbxm` and
  `MapModels.rbxm`. Then add them to the ReplicatedStorage section of
  `default.project.json`, and every build will include them:

```json
"FighterModels": { "$path": "assets/FighterModels.rbxm" },
"WeaponMeshes": { "$path": "assets/WeaponMeshes.rbxm" },
"MapModels": { "$path": "assets/MapModels.rbxm" },
```

## 5. Check it worked

Play-test (Test > Play, or 2 players with Test > Clients and Servers):

- **Fighters panel:** the lobby menu's FIGHTERS panel shows each legend
  turning in a 3D preview, playing its idle animation. "3D model not
  imported yet" means `FighterModels.<Name>` is missing or misnamed.
- **Matches:** your legend replaces your avatar, has a dark outline, and
  holds its own weapon skins.
- **Maps:** Sky-Ship Deck, Volcanic Forge, Frozen Peaks and Jungle Temple
  use the kits and their painted skies.

The Output window explains any problem it finds, for example:

```
[LegendRig] can't use FighterModels.Kestrel: missing part LeftHand
[LegendRig] Kestrel's imported head is 2.3 studs from where the export put it
```

The second warning usually means the markers were deleted or the meshes
were merged.

## Re-exporting after changing the art

Run the Blender build again (see `art/README.md`), then re-import only the
files that changed and replace the old models. `FighterRigs.luau`,
`WeaponMeshes.luau` and `AnimationData` are regenerated by the build and
picked up by Rojo automatically.
