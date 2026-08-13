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
| `ReplicatedStorage.Zones` | `src/shared/Zones.luau` |
| `ReplicatedStorage.StyleGuide` | `src/shared/StyleGuide.luau` |
| `ServerScriptService.CrackAGeodeServer` | `src/server/CrackAGeodeServer/` |
| `StarterPlayer.StarterPlayerScripts.CrackAGeodeClient` | `src/client/CrackAGeodeClient/` |

A directory containing an `init.server.luau` / `init.client.luau` becomes a
`Script` / `LocalScript` with the sibling `.luau` files as child `ModuleScript`s.

```
src/
  shared/
    Config.luau                 -- single tuning surface (rarities, balance, passes, products, formulas)
    Zones.luau                  -- data-driven biome registry: typed unlocks, drop tables, pets, prices
    StyleGuide.luau             -- Neon Geode shared style: palette, fonts, UI factories, world/lighting
  server/
    CrackAGeodeServer/
      init.server.luau          -- bootstrap: builds Remotes, requires + Inits every service in order
      Data.luau                 -- session-locked, retry-backed DataStore persistence
      Econ.luau                 -- rolls, gems, upgrades, rebirth/ascension, collection index, snapshots
      Geodes.luau               -- the core crack loop, FX, respawn, Auto-Crack, Golden Geodes
      Regions.luau              -- builds each zone's arena + the Warp Nexus from Zones data
      Decor.luau                -- hub environment detail (crystal clusters, stalagmites, veins, dust)
      Stations.luau             -- station legibility: bright boards, color identity, crater beacon
      Shards.luau               -- 5 hidden shards feeding the Sunken Grotto explorer gate
      CollectPets.luau          -- per-zone collectible pets: fusion, Golden/Rainbow variants, VIP pets
      Achievements.luau         -- tiered achievements board with reward claims
      Garden.luau               -- offline-growth Geode Garden
      Buffs.luau                -- Lucky Boosts, server gift luck, Golden Hour, VIP daily
      Meteor.luau               -- server-wide Meteor Geode event + Supernova payout
      Monetize.luau             -- game passes + dev products (incl. zone skip-unlocks) via MarketplaceService
      Boards.luau               -- rare-find feed / leaderboards
      Pickaxe.luau              -- rebirth-tier pickaxe tool
      Onboarding.luau           -- first-60-seconds guided flow
      Dailies.luau              -- login streak ladder + rotating daily quests
      Pets.luau                 -- rebirth-tier companion pets
  client/
    CrackAGeodeClient/
      init.client.luau          -- bootstrap: wires remotes to the UI / Effects / Orbit / FX modules
      UI.luau                   -- procedural HUD + all panels (Upgrades/Shop/Index/Daily/Pets/Awards)
      Effects.luau              -- crack juice, camera punch, pickaxe swing, music
      Orbit.luau                -- orbiting trophy shards from the collection bitmask
      RegionFX.luau             -- per-zone client lighting/atmosphere theming as you travel
      NexusFX.luau              -- Warp Nexus zone-teasing cards: progress, price, VIP pet, pass upsell
      PetView.luau              -- renders the equipped pet as a hovering companion
      Quality.luau              -- mobile performance scaler
```

## Zones (data-driven biomes)

`src/shared/Zones.luau` is the single source of truth for every biome. Each zone is
pure data — a typed unlock condition (`cracks` / `rebirths` / `shards` / `indexPct`),
a coin multiplier, drop tables, an exclusive collectible pet, a prestige VIP pet, a
theme + lighting mood, and a Robux `unlockPrice`. The server engine spawns, themes,
gates, and prices a zone entirely from this data, so **adding a zone = one entry here
plus decoration**. Every paid shortcut (a zone skip-unlock product, the VIP pet) is
also fully earnable by playing.

## Monetization

Game-pass and developer-product IDs in `src/shared/Config.luau` are placeholders
(`0`). While they are `0` or the place is unpublished, purchases run in Studio test
mode through the same grant paths a real receipt uses. Publish the place, create the
passes/products on the Creator Dashboard, and paste the real IDs into `Config` to go
live.
