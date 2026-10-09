# Importing the art into Roblox Studio

The game runs without any of this: fighters fall back to your Roblox
avatar in matches and to a coloured card in the menus, weapons and maps to
code-built Parts, and skies to gradients. The steps below swap in the
Blender art. You only do them once per asset (and again if you rebuild an
asset).

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
   - **Rig type:**
     - **Fighters: Custom.** Each fighter is one skinned mesh on a skeleton
       (`SkyRig`). Custom keeps the bones and their names (`Root`, `Waist`,
       `Neck`, `RightShoulder`, ..., and sway bones such as `Cape1`), which
       the game drives. Not R15: that would rename them.
     - **Weapons and maps: No rig.** These are plain models.
   - **Fighters: Keep Zero Influence Bones: on** (under Rig General). Every
     joint needs its bone, even one that no vertex happens to follow.
   - **Merge meshes: off.** Every part has to stay its own MeshPart (the
     fighter's `Body`, weapon `Body`/`Glow`, map pieces) apart from the
     markers.
   - Keep the three `Marker_` meshes in the import. They look like tiny
     cubes and should not be deleted.
   - Leave textures on. A fighter carries three painted maps (color,
     metalness, roughness) that become a SurfaceAppearance on its `Body`;
     weapons and maps carry one small palette image.
   - Scale and orientation don't matter: the game reads the markers and
     undoes whatever the importer did.
3. Click **Import**. Studio uploads the meshes and textures to your account
   and drops a Model into the Workspace.
4. Drag each imported Model into its folder from the table above and rename
   it exactly as shown. The importer usually names it after the file
   already. The importer may add a Humanoid or AnimationController to a
   fighter; leave it, the game ignores it.

Check what each model contains:

- **A fighter:** a MeshPart `Body` with the bones inside it (`Root` >
  `Waist` > `Neck`, the arms and legs, and the legend's sway bones), plus
  `Marker_Origin`, `Marker_Up` and `Marker_Front`. If `Body` looks plain
  grey in Studio, its SurfaceAppearance is missing: upload
  `<Name>_color.png`, `<Name>_metal.png` and `<Name>_rough.png` from
  `art/export/fighters/` with the Asset Manager, add a SurfaceAppearance to
  `Body` and set its ColorMap, MetalnessMap and RoughnessMap to them.
- **A weapon:** `Body` (plus `Glow` for the glowing skins) and the markers.
- **A map kit:** its pieces (`Stage`, `Platforms`, `SceneryNear`, ...) and
  the markers.

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

## 4. Upload the legend portraits (optional)

The menus show each legend's face in small places: the Online Play cards,
the party bar, legend select's slots, the results rows. Without portraits
they use a still 3D head, which is fine. Images look sharper and cost less:

1. In the **Asset Manager**, **Bulk Import** the six
   `art/export/portraits/<Legend>_portrait.png` files (512x512
   head-and-shoulders renders).
2. Copy each image's id and paste it into `Config.Art.Portraits`:

```lua
Portraits = { Kestrel = "1234567890", Brann = "...", Yuki = "...", Moss = "...", Vex = "...", Sol = "..." },
```

The painted skies from step 3 also show behind the title screen and the
menus (the map in `Config.Menu.BackdropMap`, or a random one with sky
images when it's `"Random"`).

The menu music works the same way: upload a sound and paste its id into
`Config.Music.Menu` (`""` keeps the menus silent).

**Use image asset ids, not decal ids** (this goes for the skies too). A
decal id set from a script shows nothing. If an image stays blank, paste
the id into an ImageLabel's `Image` property in Studio: Studio turns a
decal id into the image id, and that number is the one to use.

## 5. Keep the imports

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

## 6. Check it worked

There is no lobby, so you check the art in the menus and in a match.
Play-test (Test > Play, or 2 players with Test > Clients and Servers):

- **Title screen:** six legends stand in front of the painted sky, playing
  their idle animations. A coloured card in a legend's place means
  `FighterModels.<Name>` is missing or misnamed.
- **Main menu:** your legend stands in the middle in 3D, holding its
  weapon, in front of the painted sky.
- **LEGENDS screen:** each legend turns in a 3D preview as you move over
  the tiles. With portraits uploaded, the tiles and the Online Play cards
  show them; without, a still 3D head.
- **Legend select and VS:** PRACTICE > vs Bots > START. The slots show
  portraits (or heads), the big preview shows the legend you're on, and
  the VS screen shows every fighter.
- **Matches:** your legend (a classic blocky avatar with its printed outfit
  and anime face) replaces your avatar and holds its own weapon skins. Capes,
  scarves, ponytails and long hair swing on their sway bones. Brann squares
  up in his own low guard, and shows no gauntlet model over his mech fists
  (his knuckles glow when he holds gauntlets). With "Use my
  avatar's look" on (LEGENDS screen, legend select or Settings), you keep
  your own avatar and only borrow the legend's moves.
- **Maps:** Sky-Ship Deck, Volcanic Forge, Frozen Peaks and Jungle Temple
  use the kits and their painted skies.
- **Results:** your legend stands in 3D on the results screen.
- **Training room:** PRACTICE > TRAINING ROOM. The dummy is Brann on Duel
  Rock; change its legend in the panel to see the others.

The Output window explains any problem it finds, for example:

```
[LegendRig] FighterModels.Kestrel has no bones: re-import it with Rig type Custom (see art/IMPORTING.md)
[LegendRig] can't use FighterModels.Kestrel: missing bone LeftKnee
```

The first means the fighter was imported with No rig. The second usually
means Keep Zero Influence Bones was off.

## Re-exporting after changing the art

Run the Blender build again (see `art/README.md`), then re-import only the
files that changed and replace the old models. `FighterRigs.luau`,
`WeaponMeshes.luau` and `AnimationData` are regenerated by the build and
picked up by Rojo automatically.

When the skeleton changes (as it did when the legends became classic
blocky avatars), re-import **all six** fighter FBX files together with the
new `FighterRigs.luau` and `AnimationData`: a model from the old skeleton on
the new joints would be pulled apart. Delete the old fighter models first.
The weapons were refit to the blocky fists at the same time (the gauntlets
now wrap over the fist, and Kestrel's and Brann's skins were redesigned), so
re-import the weapon FBX files too.
