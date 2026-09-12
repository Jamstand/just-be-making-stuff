# JamPure – graphics preset pack for Assetto Corsa (Content Manager + CSP + Pure)

A complete "drop it in and drive" graphics setup for Assetto Corsa in the style of
the popular Pure-based packs (Mvision, PureLIFE, Iceage and friends): a filmic
post-processing filter with an in-game tweak panel, a Pure config, Custom Shaders
Patch presets and Content Manager video presets, in two performance tiers.

Everything here is original work. It is *inspired by* the look of Maiven's Mvision
pack but shares no files with it and is not affiliated with Maiven, Peter Boese
(Pure) or the CSP team.

## What is in the box

| Folder | File(s) | Goes to | Loaded from |
| --- | --- | --- | --- |
| `ppfilters/` | `JamPure_Cinematic.ini`, `JamPure_Natural.ini` | `assettocorsa\system\cfg\ppfilters\` | CM > Settings > Video > Post-processing filter |
| `ppfilters/Pure scripts/` | `JamPure_Cinematic.lua` | `assettocorsa\system\cfg\ppfilters\Pure scripts\` | Automatic while the Cinematic filter is active |
| `pure-config/` | `JamPure_pure_config.ini` | `assettocorsa\extension\config-ext\Pure\` | In game: Pure Config app > Main > Load |
| `csp-presets/` | `JamPure_CSP_Ultra.ini`, `JamPure_CSP_Balanced.ini` | `%LOCALAPPDATA%\AcTools Content Manager\Presets\Custom Shaders Patch\` | CM > Settings > Custom Shaders Patch > presets button (top right) |
| `cm-video-presets/` | `JamPure Ultra.cmpreset`, `JamPure Balanced.cmpreset` | `%LOCALAPPDATA%\AcTools Content Manager\Presets\Video Settings\` | CM > Settings > Video > presets button (top right) |

`Install-JamPure.ps1` copies all of the above to the right places for you.

## Requirements

- Assetto Corsa with [Content Manager](https://acstuff.club/app/)
- [Custom Shaders Patch](https://acstuff.club/patch/) 0.2.x (0.2.3 preview or newer recommended; ExtraFX, GrassFX and the weather features the presets enable need it)
- [Pure](https://peterboese.gumroad.com/l/pure) 0.2xx or newer, in either **Pure LCS** or **Pure Gamma** mode. The filters work with both; LCS is the current recommendation.
- Ultra tier: roughly RTX 3070 / RX 6800 or better at 1440p. Balanced tier: GTX 1660 / RX 5600 class at 1080p.

## Install

### Option A – paste-and-go (nothing to download first)

Open PowerShell (Start menu > type `powershell` > Enter) and paste this whole block:

```powershell
[Net.ServicePointManager]::SecurityProtocol = 'Tls12'
$zip = "$env:TEMP\jampure.zip"; $dir = "$env:TEMP\jampure"
Invoke-WebRequest 'https://github.com/Jamstand/just-be-making-stuff/archive/refs/heads/claude/amazing-johnson-clvxu2.zip' -OutFile $zip
Expand-Archive $zip -DestinationPath $dir -Force
Get-ChildItem $dir -Recurse -File | Unblock-File
powershell -ExecutionPolicy Bypass -File "$dir\just-be-making-stuff-claude-amazing-johnson-clvxu2\assetto-corsa-graphics\Install-JamPure.ps1"
```

It downloads this branch as a ZIP, unpacks it to your temp folder and runs the
installer. The installer finds Assetto Corsa through Steam, copies every file to
its destination and prints what it did.

### Option B – installer from a downloaded copy

Download the ZIP from GitHub (green *Code* button > *Download ZIP*), extract it,
then run the installer **from inside the `assetto-corsa-graphics` folder**:

```powershell
cd "$env:USERPROFILE\Downloads\just-be-making-stuff-claude-amazing-johnson-clvxu2\assetto-corsa-graphics"
powershell -ExecutionPolicy Bypass -File .\Install-JamPure.ps1
```

Running it from any other folder gives "The argument '.\Install-JamPure.ps1' to
the -File parameter does not exist". Add `-WhatIf` to preview, or
`-AcRoot "D:\Games\assettocorsa"` if the game is somewhere unusual.

### Option C – by hand

1. Copy `ppfilters\JamPure_Cinematic.ini` and `ppfilters\JamPure_Natural.ini` to `assettocorsa\system\cfg\ppfilters\` (or drag the .ini onto the Content Manager window).
2. Copy `ppfilters\Pure scripts\JamPure_Cinematic.lua` to `assettocorsa\system\cfg\ppfilters\Pure scripts\` (create the folder if it does not exist).
3. Copy `pure-config\JamPure_pure_config.ini` to `assettocorsa\extension\config-ext\Pure\`.
4. Copy `csp-presets\*.ini` to `%LOCALAPPDATA%\AcTools Content Manager\Presets\Custom Shaders Patch\` (or drag them onto Content Manager).
5. Copy `cm-video-presets\*.cmpreset` to `%LOCALAPPDATA%\AcTools Content Manager\Presets\Video Settings\`.

### Then, in Content Manager

1. **Settings > Custom Shaders Patch > WeatherFX**: make sure it is enabled and the weather style is *Pure LCS* (or *Pure Gamma*). The CSP presets deliberately leave WeatherFX alone, so whatever you had stays.
2. **Settings > Custom Shaders Patch**: presets button (top right) > *JamPure_CSP_Ultra* or *JamPure_CSP_Balanced*.
3. **Settings > Video**: presets button > *JamPure Ultra* or *JamPure Balanced*. Then **re-select your resolution and refresh rate** – the preset ships with 1920x1080 @ 60 Hz because it has to contain something that exists on every screen.
4. **Settings > Video > Post-processing**: filter should now read *JamPure_Cinematic*. Switch to *JamPure_Natural* any time.

### In game

- Open the **Pure Config** app > *Main* tab > *Load* > `JamPure_pure_config.ini`.
- While `JamPure_Cinematic` is the active filter, Pure Config also shows the script's sliders (colour profile, glare profile, exposure adaption and so on). Pure remembers your changes.

## The two looks

**JamPure_Cinematic** – ACES tonemapping, mild filmic contrast, warm white balance,
teal-lifted shadows, soft bloom with light anamorphic streaks and ghosting, warm
sunrays, gentle chromatic aberration, lens distortion and vignette, and a replay-friendly
depth of field. This is the "Maiven-style" look and the one the script drives.

**JamPure_Natural** – sensitometric tonemapping, neutral white balance, restrained
bloom, no ghosting, no chromatic aberration, no distortion, near-zero vignette,
shallower DOF. Built for racing and for people who find the cinematic effects distracting.

### Script panel (Cinematic only)

| Control | What it does |
| --- | --- |
| Color profile 0–4 | 0 Cinematic, 1 Natural, 2 Vivid, 3 Vintage (sepia + faded film, Filmic tonemap), 4 Dashcam (cool, contrasty, sensitometric) |
| Warmth | Shifts white balance by up to ±600 K on top of the profile |
| Saturation / Contrast | Multipliers on the filter's values |
| Teal shadows | Strength of the blue-green shadow lift in the Cinematic profile |
| Film fade | Multiplier on the profile's "washed film" amount |
| Tonemap override | −1 uses the profile's curve; 0–14 forces a CSP tonemap function (2 Sensitometric, 7 ACES, 8 Uchimura, 10 Lottes, 11 Uncharted, 13 Filmic) |
| Glare profile 0–3 | Subtle / default / strong / max – scales the bloom and star thresholds |
| Night glare boost | Extra bloom on lights once the sun is down |
| Night brightness lift | Small brightness increase at night so unlit corners stay readable |
| Godrays length | Multiplier; also follows Pure's cloud-cover modulation |
| Exposure adaption (+ interior / exterior) | Pure's cubemap-based exposure estimate, blended in with separate strength for cockpit and outside cameras |
| Spectrum adaption / VAO adaption | Pure's overcast compensation features |

## Tuning cheat-sheet

Edit the `.ini` files with a text editor, Content Manager's PP filter editor
(Content tab > PP filters) or CSP's in-game post-processing editor. The script
re-reads the filter values on load, so ini edits and the slider panel stack.

| Want to… | Change |
| --- | --- |
| Brighter / darker overall | `[AUTO_EXPOSURE] TARGET` (0.25–0.45 is the sane range), then `[TONEMAPPING] GAMMA` |
| Less blown-out sky | `[TONEMAPPING] FUNCTION=8` (Uchimura) or lower `TARGET` |
| More / less bloom on lights | `[GLARE] THRESHOLD` (lower = more), `SHAPE_BLOOM_LUMINANCE` |
| Kill the lens flare streaks | `[GLARE] ANAMORPHIC=0`, `GHOST=0` |
| Longer / shorter sunrays | `[GODRAYS] LENGTH`, `GLARE_RATIO` |
| No blur in cockpit | `[DOF] APERTURE_F_NUMBER=16` or set DOF quality to *Off* in Video settings |
| Cooler / warmer image | `[COLOR] WHITE_BALANCE` (higher = warmer) |
| Sharper image | CSP preset `[GRAPHICS_ADJUSTMENTS:ANTIALIASING] FFXCAS_SHARPNESS` |
| Different clouds | Pure config `clouds2D.quality` (skydome resolution) and `clouds2D.crossfade_time`; the Clouds tab in Pure Config switches between skydomes and 3D clouds |
| Stronger ambient occlusion | Pure config `vao.amount`; CSP preset `[EXTRA_FX:HBAO] RADIUS` |
| Night city glow | Pure config `nlp.level`, `nlp.density` |
| Wind / rain volume | Pure config `sound.*` |

## Ultra vs Balanced

| Setting | Ultra | Balanced |
| --- | --- | --- |
| MSAA / anisotropic | 4x / 16x | 2x / 16x |
| Shadow map | 4096 | 2048 |
| World detail / smoke | Max / 3 | High / 2 |
| Post-processing / glare / DOF quality | 5 / 5 / 5 | 4 / 4 / 3 |
| Mirrors / cubemap | 1024 HQ / 2048, 6 faces, 1000 m | 512 HQ / 1024, 3 faces, 600 m |
| CSP ExtraFX | SSGI, SSLR high, HBAO, volumetric lights, fog blur, motion blur | SSLR low, HBAO, volumetric lights, motion blur |
| GrassFX | Quality 4 with shadows | Quality 2, no shadows |
| Car shadows from headlights | 3 cars, HQ | 1 car |
| FSR upscaling | Off | On (0.77 scale, sharpen 0.85) |
| Texture LOD bias / frame latency | −0.5 / 1 | −0.25 / 1 |

Both presets turn Kunos motion blur off (CSP's ExtraFX blur replaces it) and leave
VSync off; cap frames in your driver or with `FPS_CAP_MS` if you need it.

## Troubleshooting

- **Everything is far too bright or dark.** The Pure config was written against
  Pure's "multiplier = 1" scale. Open Pure Config, note what *Restore defaults* gives
  you for `light.daylight_multiplier`, and if it is not around 1 on your version,
  reload the defaults and only copy the cloud / VAO / night / sound lines from
  `JamPure_pure_config.ini`.
- **The filter is missing from the list.** Restart Content Manager after copying
  files; it caches the ppfilters folder.
- **No slider panel in Pure Config.** The Lua file must sit in `system\cfg\ppfilters\Pure scripts\`
  and be named exactly like the filter (`JamPure_Cinematic.lua`). CSP's *Lua Debug*
  app shows script errors if a Pure or CSP version changed an API.
- **Washed-out look.** That is usually Pure Gamma; switch the weather style to Pure LCS,
  or lower `[TONEMAPPING] GAMMA` to 1.0.
- **HDR display.** These filters target SDR (`[EXT_DXGI_HDR] SUPPORTED=0`). For HDR
  output use Pure's own HDR filter or edit the tonemapping section.
- **Pink or black screen.** ExtraFX needs a recent CSP; load the Balanced CSP preset
  or disable ExtraFX in Content Manager.

## Regenerating the video presets

Content Manager stores video presets as JSON with three INI documents inside.
`cm-video-presets/build-presets.py` holds the readable version; edit it and run
`python3 build-presets.py` to rewrite both `.cmpreset` files.

## Credits

Pure by Peter Boese, Custom Shaders Patch by x4fab and the CSP team, Content Manager
by x4fab. File formats were cross-checked against Content Manager's open source
(gro-ove/actools), the CSP Lua SDK and the openly published Iceage filter pack.
