# Crack a Geode!

A mobile-optimized, monetized crystal-cavern RNG collector for Roblox. Tap geodes
in the cavern to crack them open for gems, chase rare crystals and mutations, grow
an offline Geode Garden, join server-wide Meteor Geode events, rebirth for
compounding multipliers and exclusive pets, and climb a daily-quest / streak ladder.

## Rojo layout

This project syncs with [Rojo](https://rojo.space/). `default.project.json` maps
the source tree into the Roblox DataModel:

| DataModel location | Source |
| --- | --- |
| `ReplicatedStorage.Config` | `src/shared/Config.luau` |
| `ServerScriptService.CrackAGeodeServer` | `src/server/CrackAGeodeServer/` |
| `StarterPlayer.StarterPlayerScripts.CrackAGeodeClient` | `src/client/CrackAGeodeClient/` |

A directory containing an `init.server.luau` / `init.client.luau` becomes a
`Script` / `LocalScript` with the sibling `.luau` files as child `ModuleScript`s.

```
src/
  shared/
    Config.luau                 -- single tuning surface (rarities, balance, passes, products, formulas)
  server/
    CrackAGeodeServer/
      init.server.luau          -- bootstrap: builds Remotes, requires + Inits every service in order
      Data.luau                 -- session-locked, retry-backed DataStore persistence
      Econ.luau                 -- rolls, gems, upgrades, rebirth/ascension, collection index, snapshots
      Geodes.luau               -- the core crack loop, FX, respawn, Auto-Crack, Golden Geodes
      Garden.luau               -- offline-growth Geode Garden
      Buffs.luau                -- Lucky Boosts, server gift luck, Golden Hour, VIP daily
      Meteor.luau               -- server-wide Meteor Geode event + Supernova payout
      Monetize.luau             -- game passes + dev products via MarketplaceService
      Boards.luau               -- rare-find feed / leaderboards
      Pickaxe.luau              -- rebirth-tier pickaxe tool
      Onboarding.luau           -- first-60-seconds guided flow
      Dailies.luau              -- login streak ladder + rotating daily quests
      Pets.luau                 -- rebirth-tier companion pets
  client/
    CrackAGeodeClient/
      init.client.luau          -- bootstrap: wires remotes to the UI / Effects / Orbit modules
      UI.luau                   -- procedural HUD + all panels (Upgrades / Shop / Index / Daily / Pets)
      Effects.luau              -- crack juice, camera punch, pickaxe swing, music
      Orbit.luau                -- orbiting trophy shards from the collection bitmask
      PetView.luau              -- renders the equipped pet as a hovering companion
      Quality.luau              -- mobile performance scaler
```

## Monetization

Game-pass and developer-product IDs in `src/shared/Config.luau` are placeholders
(`0`). While they are `0` or the place is unpublished, purchases run in Studio test
mode through the same grant paths a real receipt uses. Publish the place, create the
passes/products on the Creator Dashboard, and paste the real IDs into `Config` to go
live.
