# Coin Rush

A monetized Roblox coin-collection game with dual currency, persistent saves, an upgrade shop, GamePasses, and Robux-purchased DeveloperProducts.

## Gameplay

- Walk around the map and collect floating coin tiers (Bronze, Silver, Gold, Diamond). Higher tiers are rarer; Diamonds also drop Gems.
- Coins respawn 5 seconds after pickup.
- Touch the magenta beacon near spawn (or press `E`) to open the shop.
- Claim a daily reward (coins + gems) once every ~22 hours.

## Currencies

| Currency | Earned by                            | Spent on                         |
|----------|--------------------------------------|----------------------------------|
| Coins    | All coin pickups                     | Speed, Jump upgrades             |
| Gems     | Diamond pickups, daily, Robux        | Multiplier, Magnet upgrades      |

## Upgrades (server-validated)

| Upgrade        | Effect                          | Currency | Max tier |
|----------------|---------------------------------|----------|----------|
| Speed Boost    | +4 walk speed per tier          | Coins    | 5        |
| Jump Boost     | +10 jump power per tier         | Coins    | 5        |
| Coin Multiplier| +50% coin value per tier        | Gems     | 5        |
| Coin Magnet    | +10 stud pickup radius per tier | Gems     | 3        |

## Robux monetization

Two patterns are wired in:

1. **Developer Products** (consumable) → grant Gems. `MarketplaceService.ProcessReceipt` credits Gems exactly once per receipt id.
2. **GamePasses** (one-time, permanent) → DoubleCoins, VIP (trail + 1.5x), AutoCollect (always-on magnet).

### Setup checklist

After publishing the place to Roblox:

1. Open the creator dashboard for your experience.
2. **Monetization → Developer Products**: create three products (Small / Medium / Large gem packs). Copy each product's asset id into `src/shared/GameConfig.luau` under `GemProducts[*].ProductId`.
3. **Monetization → Passes**: create three passes (DoubleCoins / VIP / AutoCollect). Copy each pass id into `GameConfig.GamePasses[*].GamePassId`.
4. Save and republish.

Until the IDs are filled in, the in-game buttons stay disabled and show "Not set".

## Project layout

```
default.project.json
src/
  shared/
    GameConfig.luau          Tunables, product/pass ids, upgrade caps
    ShopCatalog.luau         Display strings + tier costs
  server/
    PlayerDataService.server.luau   DataStore load/save + autosave + BindToClose
    Leaderboard.server.luau         Mirrors Coins/Gems on leaderstats
    CoinService.server.luau         Tiered coin spawn, Touched + magnet pickup
    UpgradeService.server.luau      Applies Speed/Jump/Magnet/Multiplier + VIP trail
    ShopService.server.luau         Validates upgrade purchases (coins/gems)
    MonetizationService.server.luau MarketplaceService: products + gamepasses
    DailyRewardService.server.luau  Daily coin+gem grant
  client/
    HudGui.client.luau              Coins/Gems pills, daily button, toast notifications
    ShopGui.client.luau             Tabbed shop UI (Upgrades / Gems / Passes)
    CoinClient.client.luau          Pickup sounds (rare-tier variant)
    MagnetClient.client.luau        Placeholder for future client VFX
```

## How to run it

1. Install [Rojo](https://rojo.space/) 7+.
2. From this directory: `rojo serve`.
3. Open Roblox Studio with the Rojo plugin, **Connect**, then press **Play (F5)**.

Build a standalone file:

```
rojo build -o CoinRush.rbxlx
```

## Important Roblox-side notes

- **DataStores only work in published places**, not local Studio sessions. To test persistence: in Studio, **Game Settings → Security → Enable Studio Access to API Services**.
- **Robux purchases never succeed in Studio test** — they always fail/cancel. To verify, publish to a private place and test in the real Roblox client.
- `ProcessReceipt` is required for DeveloperProducts. Returning anything other than `PurchaseGranted` will cause Roblox to retry on next session — that's the design (so a crash mid-grant doesn't lose the player's Robux).
