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
| `ppfilters/pure_scripts/` | `JamPure_Cinematic.lua` | `assettocorsa\system\cfg\ppfilters\pure_scripts\` (Pure Gamma) and `...\ppfilters\purelcs_scripts\` (Pure LCS) | Automatic while the Cinematic filter is active |
| `pure-config/` | `JamPure_pure_config.ini` | `assettocorsa\extension\config-ext\Pure\` | In game: Pure Config app > Main > Load |
| `csp-presets/` | `JamPure_CSP_Ultra.ini`, `JamPure_CSP_Balanced.ini` (built from `base/Maiven_Ultra_highend_vans.ini`) | `%LOCALAPPDATA%\AcTools Content Manager\Presets\Custom Shaders Patch\` | CM > Settings > Custom Shaders Patch > presets button (top right) |
| `cm-video-presets/` | `JamPure Ultra.cmpreset`, `JamPure Balanced.cmpreset` | `%LOCALAPPDATA%\AcTools Content Manager\Presets\Video Settings\` | CM > Settings > Video > presets button (top right) |
| `apps/lua/` | eight `JamPure*` folders (manifest.ini + .lua each) | `assettocorsa\apps\lua\<App>\` | In game: apps sidebar on the right edge, click the app to open it |

`Install-JamPure.ps1` copies all of the above to the right places for you.

## Requirements

- Assetto Corsa with [Content Manager](https://acstuff.club/app/)
- [Custom Shaders Patch](https://acstuff.club/patch/) 0.2.x (0.2.3 preview or newer recommended; ExtraFX, GrassFX and the weather features the presets enable need it)
- [Pure](https://peterboese.gumroad.com/l/pure) 0.2xx or newer, in either **Pure LCS** or **Pure Gamma** mode. The filters work with both; LCS is the current recommendation. (Weather style `pure` in Content Manager is Pure Gamma, `pure lcs` is Pure LCS.)
- CSP > Graphics adjustments > **Scriptable filters** enabled with implementation `pure`. Pure installs this and every Pure script, including this pack's, runs through it. The Maiven CSP export has it on.
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
2. Copy `ppfilters\pure_scripts\JamPure_Cinematic.lua` to `assettocorsa\system\cfg\ppfilters\pure_scripts\` (Pure Gamma) **and** to `assettocorsa\system\cfg\ppfilters\purelcs_scripts\` (Pure LCS). Create the folders if they do not exist; the names are exactly those, with underscores. Pure only looks in the folder that matches the active weather style.
3. Copy `pure-config\JamPure_pure_config.ini` to `assettocorsa\extension\config-ext\Pure\`.
4. Copy `csp-presets\*.ini` to `%LOCALAPPDATA%\AcTools Content Manager\Presets\Custom Shaders Patch\` (or drag them onto Content Manager).
5. Copy `cm-video-presets\*.cmpreset` to `%LOCALAPPDATA%\AcTools Content Manager\Presets\Video Settings\`.

### Then, in Content Manager

1. **Settings > Custom Shaders Patch > WeatherFX**: make sure it is enabled and the weather style is *Pure*. The CSP presets carry the WeatherFX selection over from the Maiven export (`IMPLEMENTATION=pure`, controller `pureCtrl static`), so nothing changes there.
2. **Settings > Custom Shaders Patch**: presets button (top right) > *JamPure_CSP_Ultra* or *JamPure_CSP_Balanced*.
3. **Settings > Video**: presets button > *JamPure Ultra* or *JamPure Balanced*. Then **re-select your resolution and refresh rate** – the preset ships with 1920x1080 @ 60 Hz because it has to contain something that exists on every screen.
4. **Settings > Video > Post-processing**: filter should now read *JamPure_Cinematic*. Switch to *JamPure_Natural* any time.

### In game

- Open the **Pure Config** app > *Main* tab > *Load* > `JamPure_pure_config.ini`.
- While `JamPure_Cinematic` is the active filter, Pure Config also shows the script's sliders (colour profile, glare profile, exposure adaption and so on). Pure remembers your changes.

## The two looks

**JamPure_Cinematic** – ACES tonemapping, mild filmic contrast, warm white balance,
teal-lifted shadows, soft bloom with light anamorphic streaks and ghosting, warm
sunrays, gentle chromatic aberration, a light vignette, and a replay-friendly depth of
field (lens distortion is in the file but switched off). This is the "Maiven-style" look and the one the script drives.

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
| Tonemap override | −1 uses the profile's curve; 0–16 forces a CSP tonemap function (2 Sensitometric, 7 ACES, 8 Uchimura, 10 Lottes, 11 Uncharted, 13 Filmic, 16 AgX on recent CSP builds) |
| Glare profile 0–3 | Subtle / default / strong / max – scales the bloom and star thresholds |
| Night glare boost | Extra bloom on lights once the sun is down |
| Night brightness lift | Small brightness increase at night so unlit corners stay readable |
| Godrays length | Multiplier; also follows Pure's cloud-cover modulation |
| Exposure target day / night | What Pure's cubemap estimate aims for (1.4 / 2.6 by default, the range current Pure filters use); raise for a brighter image |
| Exposure gain | Multiplier on top of the estimate; the quickest single slider if the image is too dark or bright |
| Brightness | Plain post-processing brightness multiplier, works even with exposure adaption off |
| Exposure adaption (+ interior / exterior) | Pure's cubemap-based exposure estimate, blended in with separate strength for cockpit and outside cameras |
| Spectrum adaption / VAO adaption | Pure's overcast compensation features, 0 to 1 |

## Editing the look live, with the game running

There are four places to change things while you drive, from quickest to deepest:

1. **The "Post Process Filter" app** (CSP's filter selector, the small window in the top
   left in your screenshot). The arrows switch filters and the *Exposure* row is a live
   exposure multiplier, so nudging it is the fastest fix for a too-dark or too-bright
   scene. The small arrow next to the filter name opens a menu with CSP's own filter
   editor, which exposes every section of the `.ini` (tonemapping, colour, glare,
   sunrays, DOF, vignette, distortion) with sliders and saves back to the file in
   `system\cfg\ppfilters`. Content Manager's own PP-filter page says the same: with CSP
   you create and edit filters in-game and see changes live.
2. **Pure Config app > the script section** (Cinematic filter only): the sliders described
   below, including *Exposure gain* and *Brightness*, which are pure multipliers on top of
   whatever the filter and Pure compute. Pure remembers them.
3. **Pure PP app** (ships with Pure): live control over the active filter's general,
   tonemapping and "spice" values, independent of this pack.
4. **Content Manager > Content > PP filters > Edit**: the same sections as the in-game
   editor, with the full ini visible, for editing while AC is closed.

Whatever you save from the in-game editor overwrites `JamPure_Cinematic.ini`, so keep a
copy of the shipped one if you want to compare. The script's own sliders are saved by
Pure to `extension\config-ext\Pure\JamPure_Cinematic_ScriptSettings.ini`; the Pure PP
File tab shows that as "Settings loaded". Two Pure-specific habits worth knowing: after
switching filters with the selector app, restart the session, otherwise the exposure can
stay wrong until you do; and Pure Config's PP tab has an "export PPfilter related config"
button that writes the current Pure Config next to the script as `pure_scripts\JamPure_Cinematic.ini`,
which Pure then applies automatically whenever this filter is active. This pack does not
ship one on purpose, so your own Pure Config stays in charge.

### Version 1.1 changes after first in-game feedback

- **Lens distortion is now off.** It was drawing black rounded corners at the screen edges.
- **Brighter by default.** The filter's auto-exposure target moved from 0.32 to 0.38 and
  the vignette softened from 0.12 to 0.07.
- New live sliders: *Exposure gain* and *Brightness*.

### Version 1.2: the script was never being loaded

The Pure PP app reported "The current PP-filter has no Pure Script! Script loaded:
default_script.lua". Pure's scripting documentation and its changelog (since Pure 0.14)
say a script is loaded when it sits in `system\cfg\ppfilters\pure_scripts\` (underscore)
and carries the same name as the selected filter; Pure LCS reads `purelcs_scripts\`
instead. Every current public filter pack ships its scripts there. Versions 1.0 and 1.1
of this pack installed the script into a "Pure scripts" folder that Pure ignores, so Pure
fell back to `default_script.lua`, which is documented behaviour since Pure 0.59. With no script, none of the exposure handling
ran, hence the dark image. 1.2 fixes the folder (the installer also deletes the stale
copy) and, while at it, rewrites the exposure part to match what current Pure filters do:

- Pure's cubemap-based exposure with an explicit **day / night target** (1.4 / 2.6),
  iris limits 0.05 to 0.8 and 2 s / 4 s adaption, all exposed as sliders, instead of a
  derived multiplier.
- The script talks to the current `pure.*` API (`pure.script.ui`, `pure.exposure.cbe`,
  `pure.mod`, `pure.pp`) and falls back to the older `__SCRIPT__*` / `PURE__*` names.
- Spectrum and VAO adaption are 0 to 1 sliders now, as in current Pure.
- Requirements the exposure part shares with every cubemap-driven filter: reflections
  rendering frequency in AC video settings must not be *static* (the video presets use
  six faces per frame), and CSP > Reflections FX > "Use proper physically-based sampling"
  must be on (the Maiven export has it on).

## In-game HUD apps

Eight CSP Lua apps, written against the CSP 0.2.11 SDK definitions and checked by a
harness that runs each one for 150 frames in five simulated sessions (offline day, an online
night with 12 cars, rain and music, a paused replay with the widget server unreachable, a tiny
window, and one with the Pure script present on disk). Open them from the apps sidebar in
game; every app has a settings page (the gear icon on its title bar) and remembers its
settings between sessions.

| App | What it shows | Needs |
| --- | --- | --- |
| **Traffic Radar** | Cars around you as dots on a radar that keeps your heading up, coloured by closing speed, with distance and closing speed on the nearest car ahead and behind. | nothing |
| **Convoy** | Everyone in the session sorted by distance, with a direction arrow, speed and a "with you / close / dropped" status. Works offline with AI too. | nothing |
| **Stream Ticker** | Twitch follows, subs, cheers and tips in a corner of the game: newest event large, the last few below, plus viewers and followers. | widget server |
| **Telemetry Out** | Pushes speed, gear, rpm, fuel, laps and car name to the widget server a few times per second and shows the send status. | widget server |
| **Now Playing** | The current track from Windows' media session, or from the server's Spotify proxy as fallback, with a live progress bar. | optional: widget server |
| **Filter Doctor** | Active PP filter, whether its Pure script exists for Gamma and for LCS, exposure and multiplier with nudge buttons, time of day, sun angle, weather and render flags. | nothing |
| **Frame Time** | Frame-time graph with fps, average, 1 % low and worst frame, plus car count, VRAM, MSAA, FSR, LCS and detail level. | nothing |
| **Cruise Cluster** | Road-car dash: big speed, gear, rpm bar with red zone, fuel with estimated range, trip and odometer, beam, indicator, hazard, handbrake, ABS and TC lights, clock. | nothing |

### The widget server side

Three of the apps talk to the Node widget server in this repository (`server.js`, the one
that already feeds the OBS overlays). Start it with `npm start` on the gaming PC and leave
the apps' *base URL* setting at `http://localhost:3000`. This pack added to the server:

- `GET /widget-events/recent?since=<seq>`: the last 50 Twitch events with sequence numbers,
  which the Stream Ticker polls (the in-game Lua runtime can't hold an SSE stream open).
- `POST /ac/telemetry` and `GET /ac/telemetry`: the Telemetry Out app posts here; the server
  stores the latest snapshot and re-broadcasts it as the SSE event `ac`.
- `public/widgets/AC_Telemetry.html`: a new OBS browser-source widget showing speed, gear,
  rpm, fuel and lap times live. It dims itself when data stops and only shows demo numbers
  before any real data has ever arrived. Listed on the widgets directory page.

CSP allows a script at most two web requests in flight; the apps keep one and back off when
the server is down, so leaving them open without the server running costs nothing.

### Notes per app

- **Traffic Radar** ignores disconnected cars and cars CSP hides labels for. Range, dot size,
  AI inclusion and driver names (online) are settings.
- **Stream Ticker** has a "test event" button in its settings to check placement without
  waiting for a real follow.
- **Filter Doctor** rechecks the script files every 2 s, not every frame, and shows the exact
  path it expects when a script is missing. The +/- buttons drive the same exposure
  multiplier as the Post Process Filter app's slider.
- **Frame Time** samples the real frame time, so it keeps measuring while paused.
- **Cruise Cluster** estimates range from your own consumption over the last few kilometres;
  it shows "range --" until it has driven enough to know.

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

## The CSP presets and the Maiven "Ultra highend" export

Both CSP presets are generated from `csp-presets/base/Maiven_Ultra_highend_vans.ini`,
the Content Manager export of the *Ultra highend preset (Maiven)* settings
(`acstuff.club/s/GSum`). Everything that is not a graphics-quality knob is carried
over byte for byte: NeckFX (Realistic NeckFX script, G-force tilt), kirbycam chaser
camera, gamepad assist, physics experiments, audio, GUI tweaks, the DLSS/upscaler
selection and, importantly, the Pure WeatherFX selection.

The export was checked key by key against the CSP 0.2.11 config definitions and the
CSP documentation for every setting's range. It targets a newer preview build than
0.2.11 (112 keys, mostly the DLSS/XeSS/FSR3 upscaler options and RainFX, only exist
in previews), so the presets need that preview build too.

**What was already at maximum in the Maiven export:** ExtraFX on with High motion
blur, Hi-Z SSLR at 600 steps (the docs' own ceiling is 250), HBAO+ at full opacity,
2048 cubemap with physically based sampling, prefiltering and reprojection, local
cubemaps for cars and tracks, refracting headlights, headlight shadows in high
quality, dynamic lights in the rear mirror with sun shadows, full-resolution smoke
with shadows, Real Mirrors, rain maps at High, windscreen reflections, sparks and
debris limits, full-resolution colour buffer, doublesided shadows, DLSS at 100 %
render scale (that is DLAA: native resolution with the AI anti-aliasing only).

**What the Ultra preset raises, and why:**

| Setting | Maiven export | Ultra | CSP documentation |
| --- | --- | --- | --- |
| LOD distance multipliers (cars / track / trees) | 1.0 | 3.2 | range 0.2 to 3.2; trees need a restart |
| Limit visible cars | on | off | "disabling will negatively affect FPS"; first thing to turn back on if a full grid stutters |
| LOD-less car limit | 40 | 200 | range 2 to 200 |
| Low-res cockpits for other cars in first person | on | off | detail vs. Maiven's "less distracting" choice |
| Post-AA quality (FXAA 3.11) | High | Ultra | Medium / High / Ultra; only matters when the upscaler is off |
| MSAA custom resolve kernel | off | on | "improves quality further, slightly reduces performance" |
| Volumetric headlights resolution | 0.20 (default) | 0.32 | range 0.08 to 0.32 |
| Cars casting dynamic shadows (driving / spectating) | 2 / 3 (default) | 5 / 5 | range 0 to 5 |
| Detailed shadows from nearby cars | 1 (default) | 4 | range 0 to 4 |
| Cars casting dynamic lights | 10 (default) | 50 | range 0 to 50 |
| Smoke quantity limit | 1.0 | 1.2 | range 0.1 to 1.2 |
| Cubemap colour depth | 32 bpp | 64 bpp | hidden option, higher precision reflections |
| Real Mirrors refresh | 2 per frame | everything every frame | "update everything is 0" |
| Mirror render distance | 800 m (default) | 2400 m | range 400 to 2400 |
| Mirror colour precision | reduced (0.2.11 default) | full | `COMPACT_FORMAT=0` |
| Shadow distance / fourth cascade | 200 m / 1500 m (default) | 400 m / 2000 m | ranges 50 to 400 and 1000 to 2000 |
| Shadow anisotropic filtering | off (default) | on | new in 0.2.11 |
| Cascade overhang | 0.95 | 1.0 | "increase to make transition sharper, increasing effective resolution" |
| Lazier shadow-map update | on (default) | off | all three shadow maps every frame |
| Cloud shadow resolution | normal | detailed | `DETAILED_CLOUD_SHADOWS=1` |
| Post-processing resolution | adaptive (default) | full | `[WEATHER_FX:PP_TWEAKS] FULL_RESOLUTION=1` |
| GrassFX quality | High (3) | Very high (4) | 0 to 4 |
| Trees receive shadows | off (default) | on | fine with TAA/DLAA |
| Skidmarks | 200 bits, plain blending | 800 bits, advanced blending | range up to 800 |
| "Limit things with many cars" (general, shadows, smoke) | on | off | CSP's automatic quality reductions for big grids |
| Screenshot JPEG quality | 99 | 100 | |

**Deliberately left alone:** `CARS_LIT_MULT=0.4` and `TILT_MIP_BIAS=-2.5` (Maiven's
look), sparks and debris spawn rates (quantity, not quality), `STEPS_HIZ=600`, the
ghost/anamorphic glare being allowed in first-person view (`NO_ANAMORPHIC_GLARE=0`,
`NO_GHOST_GLARE=0`, which is what lets the Cinematic filter's flares show in cockpit
view), the obsolete SSGI (the docs mark it "obsolete and incorrect"), and the
upscaler method.

**How this interacts with the rest of the pack:** the video presets keep post-processing
and FXAA enabled, which CSP requires for the upscaler and its anti-aliasing hook, and
keep Kunos motion blur off, which ExtraFX requires. The Balanced CSP preset also drops
DLSS to its 67 % "Quality" step; if you use a different upscaler method, change the
matching `QUALITY_*` key in `build-csp-presets.py` and rerun it.

To tweak anything, edit the override tables in `csp-presets/build-csp-presets.py` and
run it; it prints the full list of changes against the base export.

## Ultra vs Balanced

| Setting | Ultra | Balanced |
| --- | --- | --- |
| MSAA / anisotropic | 4x / 16x | 2x / 16x |
| Shadow map | 4096 | 2048 |
| World detail / smoke | Max / 3 | High / 2 |
| Post-processing / glare / DOF quality | 5 / 5 / 5 | 4 / 4 / 3 |
| Mirrors / cubemap | 1024 HQ / 2048, 6 faces, 1000 m | 512 HQ / 1024, 3 faces, 600 m |
| CSP ExtraFX | SSLR Hi-Z 600 steps, HBAO+, volumetric lights at max res, fog blur, High motion blur | SSLR Simple 120 steps, HBAO+, volumetric lights default res, Medium motion blur |
| GrassFX | Very high with shadows and ExtraFX pass | Medium, no shadows |
| Car shadows from headlights | 5 cars, HQ, 4 detailed | 2 cars, standard |
| Upscaler | Maiven export as is (DLSS at 100 % = DLAA) | DLSS at 67 % (Quality) |
| Cubemap / mirrors | 2048 64 bpp, mirrors every frame, 2400 m | 1024 32 bpp, 2 mirrors per frame, 800 m |
| Shadows | 400 m automatic splits, 2000 m fourth cascade, every map every frame | 200 m, 1500 m, lazier update |
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
- **Pure PP says "The current PP-filter has no Pure Script" / no slider panel.** The Lua file
  must sit in `system\cfg\ppfilters\pure_scripts\` for Pure Gamma or `purelcs_scripts\` for
  Pure LCS (underscores, not spaces) and be named exactly like the filter
  (`JamPure_Cinematic.lua`). Pack versions before 1.2 installed it into a "Pure scripts"
  folder, which Pure ignores; rerun the installer, it copies to both folders and removes the
  stale one. Dropping the filter onto Content Manager installs only the `.ini`, never the
  script, which is the other common way to end up here.
- **Pure Config warns "This PPfilter might only be compatible with Pure Gamma!"** Pure LCS is
  active but only the Gamma folder has the script; copy it to `purelcs_scripts\` as well. CSP's *Lua Debug*
  app shows script errors if a Pure or CSP version changed an API.
- **Washed-out look.** That is usually Pure Gamma; switch the weather style to Pure LCS,
  or lower `[TONEMAPPING] GAMMA` to 1.0.
- **HDR display.** These filters target SDR (`[EXT_DXGI_HDR] SUPPORTED=0`). For HDR
  output use Pure's own HDR filter or edit the tonemapping section.
- **Pink or black screen.** ExtraFX needs a recent CSP; load the Balanced CSP preset
  or disable ExtraFX in Content Manager.
- **Full grids stutter with the Ultra CSP preset.** Turn *Limit visible cars* back on
  (Graphics adjustments > LODs) and drop the LOD multipliers to 2.0; those two are the
  costly ones in large fields.
- **Want the exact Maiven settings back.** `csp-presets/base/Maiven_Ultra_highend_vans.ini`
  is the untouched export; drop it onto Content Manager.

## Regenerating the video presets

Content Manager stores video presets as JSON with three INI documents inside.
`cm-video-presets/build-presets.py` holds the readable version; edit it and run
`python3 build-presets.py` to rewrite both `.cmpreset` files.

## Credits

Pure by Peter Boese, Custom Shaders Patch by x4fab and the CSP team, Content Manager
by x4fab. File formats were cross-checked against Content Manager's open source
(gro-ove/actools), the CSP Lua SDK and the openly published Iceage filter pack.
