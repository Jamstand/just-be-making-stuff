# STEAL A SOCK 🧦

Every sock that ever went missing ended up here. The Great Dryer spits socks onto a moving
clothesline; players buy them, stash them in giant sock drawers, then raid each other's drawers.
Every sock comes as a LEFT and a RIGHT — own both halves and they **pair up** for a huge income
boost. Steal one half and you break someone's pair.

The proven "buy units off a conveyor, earn in your base, steal and defend" loop with an original
theme and one new core mechanic: **Pairs**.

## Rojo layout

`default.project.json` maps the source tree into the DataModel:

| DataModel | Source |
| --- | --- |
| `ReplicatedStorage.Shared` (Folder) | `src/shared/` — `Config/` (5 config ModuleScripts), `Types`, `Util`, `RemoteNames` |
| `ServerScriptService.StealASockServer` (Script + modules) | `src/server/StealASockServer/` |
| `StarterPlayer.StarterPlayerScripts.StealASockClient` (LocalScript + `HUD`, `SockFX`) | `src/client/StealASockClient/` |

The map (a giant's bedroom at night: bed, nightstand lamp, toys, the Great Dryer, clothesline, Lint Trap basket, 8 drawers) is **built by code at startup**
(`Map.luau`), so a blank baseplate is all Studio needs. Every placeholder piece is tagged with
CollectionService (`Sock`, `Base`, `SockSlot`, `CollectPad`, `SlamButton`, `Dryer`, `Clothesline`,
`LintTrap`, `MapFloor`, `MapWall`, `DustBunny`) so real models can replace it later.

## Server modules (init order)

| Module | Job |
| --- | --- |
| `RateLimit` | per-player minimum gap between actions |
| `Data` | ProfileStore (session-locked) profiles + leaderstats |
| `Lighting` | night bedroom lighting: atmosphere, bloom, colour grade |
| `Map` | builds the Giant's Bedroom (bed, lamp, toys, dryer, clothesline, basket, 8 drawers); `Map.Layout` holds every position |
| `Registry` | live socks by uid; rolls rarity/type/side/mutation; income + price formulas |
| `Factory` | sock models from Parts: body + googly eyes + each type's signature features, rarity glows, mutation looks |
| `Base` | drawer assignment, slots, Collect pad, Slam Drawer lock + shutter, profile sync |
| `Pair` | THE HOOK: auto-pairing, Perfect Pairs, thread Beam + PAIRED badge |
| `Income` | the one per-second loop that pays drawers and pushes state to clients |
| `Clothesline` | the Dryer spawner; socks ride the line on one Tween each; Lint Trap despawn |
| `Purchase` | buy validation (distance, state, cash, drawer space) |
| `Steal` | pickup (hold E), carry on head, claim at home, return on death/leave/snap/eject |
| `Towel` | Towel Snap tool: knockback + sock goes home |

`ProfileStore.luau` is vendored from https://github.com/MadStudioRoblox/ProfileStore (MIT, see
`docs/ProfileStore-LICENSE.txt`).

## Phases

1. **Core loop** (this branch): map, drawers, Dryer + Clothesline, buy, income/collect,
   steal/carry/claim, Towel Snap, drawer lock, saving, basic Pairs. See `docs/PHASE1.md`.
2. The hook: Match Radar, RIVAL tags, announcements, mutation looks, Stink, Sockdex.
3. Events, gear, rebirth, leaderboards.
4. Monetization, sounds, tweens/particles, UI polish, balance pass.

Balance lives in `src/shared/Config/*.luau` only. Run `scripts/check.sh` before pushing.
