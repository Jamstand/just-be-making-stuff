# Gear Speedo

A small in-game dashboard for Assetto Corsa: the gear you're in, road speed,
and an 18-segment RPM bar with shift lights.

![Gear Speedo in each of its states](preview.png)

The gear is the hero — big, centre-left, and it turns red when you should be
pulling the next one. The bar runs green → amber → red as revs climb, then the
whole thing flashes white on the limiter.

## Install

The folder layout here mirrors the Assetto Corsa install directory, so you can
either:

**Drag and drop into Content Manager** — zip up the `apps` and `content`
folders together and drop the `.zip` onto Content Manager's window. It reads
the `apps/` folder at the zip root and installs from there.

**Or copy by hand** — merge these two folders into your AC install root:

```
<AC root>/apps/python/GearSpeedo/...
<AC root>/content/gui/icons/Gear Speedo_ON.png     (sidebar icon)
<AC root>/content/gui/icons/Gear Speedo_OFF.png
```

`<AC root>` is usually
`C:\Program Files (x86)\Steam\steamapps\common\assettocorsa`.

## Turn it on

Two switches, both in Content Manager under
**Settings → Assetto Corsa → Apps**:

1. Tick **Enable Python apps** (this is global — if it's off, no Python app loads).
2. Find **Gear Speedo** in the activated-apps list and tick it.

Then start a session and hover the right edge of the screen to pull out the app
bar. Gear Speedo is in there — click it to place the window, and drag it where
you want.

Both switches just write ini files, so you can set them by hand instead:
`ENABLE_PYTHON=1` under `[PYTHON]` in
`Documents\Assetto Corsa\cfg\gameplay.ini`, and `ACTIVE=1` under
`[GEARSPEEDO]` in `Documents\Assetto Corsa\cfg\python.ini`.

## Settings

Content Manager builds a settings page automatically from `GearSpeedo.ini` —
same place, **Settings → Assetto Corsa → Apps**, then pick Gear Speedo. Or edit
the file directly:

| Setting | Default | What it does |
| --- | --- | --- |
| `SCALE` | `100` | App size, 50–200% |
| `UNITS` | `KMH` | `KMH` or `MPH` |
| `SHOW_SPEED` | `1` | `0` shows just the gear, centred |
| `OPACITY` | `70` | Background opacity, 0–100% |
| `SHIFT_AT` | `95` | Where the shift flash starts, as a share of the rev limit |

Settings are read once when the app loads, so changes apply from the next
session, not mid-drive. Anything missing, malformed or out of range falls back
to the default rather than breaking the app.

## How it finds the rev limit

This is the one interesting bit. The bar needs to know the car's rev limit, and
Assetto Corsa's Python API doesn't expose it — there's no `maxRPM`. Apps
normally read it out of the game's shared memory, but that needs `ctypes`, and
`ctypes` doesn't work in AC's embedded Python unless the app ships its own
compiled `.pyd` binaries for both 32- and 64-bit.

So this app doesn't do that. It works out the limit instead:

- It watches `IsEngineLimiterOn`, which the API *does* expose. The moment the
  limiter cuts in, the current RPM is the rev limit, near enough exactly.
- Until that first bounce off the limiter, it scales the bar to the highest RPM
  it has seen so far plus a little headroom.

In practice the bar is roughly right from the first corner and exactly right
the first time you hit the limiter. It relearns when you change car. The
tradeoff is deliberate: no binaries to ship, nothing to install, and it runs on
both `acs.exe` and `acs_x86.exe` unchanged.

## If it doesn't show up

An AC app that throws an exception doesn't report an error — it just silently
never appears in the sidebar. Check, in order:

1. `Documents\Assetto Corsa\logs\py_log.txt` — tracebacks land here, prefixed
   with the app name. This app also logs `GearSpeedo: loaded` on a good start,
   so if you don't see that line it never got off the ground.
2. `Documents\Assetto Corsa\logs\log.txt` — search for `GearSpeedo`.
3. The in-game console — the **Home** key toggles it.

Common causes: the folder isn't named exactly `GearSpeedo` (AC imports
`apps/python/GearSpeedo/GearSpeedo.py`, and the folder and file names have to
match), or **Enable Python apps** is off.

## Notes

- Written against AC's embedded Python 3.3, so no f-strings and no stdlib
  newer than 3.3.
- Everything is drawn from `on_render`. AC discards `gl*` calls made anywhere
  else, which is the usual reason a HUD draws nothing.
- Gear values from the API are offset by one: `0` is reverse, `1` is neutral,
  `2` is first. `format_gear` handles it.
