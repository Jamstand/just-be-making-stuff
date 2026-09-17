# App test harness

Runs a CSP Lua app without Assetto Corsa: a stub runtime generated from the CSP 0.2.11 Lua SDK
definitions, a static check that rejects any `ac.` / `ui.` / `web.` name the SDK does not have, and
150 simulated frames in five sessions (offline day; online night with 12 cars, rain and music; a
paused replay with the widget server unreachable; a 90x60 window; the Pure script present on disk).

```
pip install lupa
python3 apps/harness/run_app.py apps/lua/JamPureTrafficRadar apps/lua/JamPureConvoy ...
```

`sdk_index.json` is an index of function names, enum keys and struct fields extracted from the SDK
that ships inside the CSP build (`extension/internal/lua-sdk/ac_apps/lib.lua`); regenerate it from a
newer build if an app needs an API that arrived later. The stubs only mimic shapes and return
values, so a PASS means "calls real functions, reads real fields, survives 750 frames", not
"looks right"; check the window in game.
