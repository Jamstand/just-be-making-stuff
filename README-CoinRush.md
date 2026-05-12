# Coin Rush

A small Roblox game: walk around the baseplate and collect glowing gold coins. Each pickup increases your `leaderstats.Coins`, plays a sound, and pulses the on-screen score. Coins respawn at a new random spot a few seconds after being grabbed.

## Project layout

```
default.project.json           Rojo project definition
src/
  shared/GameConfig.luau       Tunables (coin count, value, respawn time, map size)
  server/
    CoinService.server.luau    Spawns, awards, and respawns coins
    Leaderboard.server.luau    Sets up leaderstats.Coins per player
  client/
    CoinClient.client.luau     Plays pickup sound on collect
    ScoreGui.client.luau       HUD with the current coin count
```

## How to run it

1. Install [Rojo](https://rojo.space/) (`rojo` CLI 7+).
2. From this directory: `rojo serve`.
3. Open Roblox Studio, install the Rojo plugin, click **Connect**, then **Play** (F5).

Or build a `.rbxlx` directly:

```
rojo build -o CoinRush.rbxlx
```

and open the file in Studio.

## Tuning

Edit `src/shared/GameConfig.luau`:

- `CoinCount` — coins on the map at once
- `CoinValue` — points per pickup
- `CoinRespawnSeconds` — delay before a collected coin returns
- `MapHalfSize` — coin spawn radius from origin
