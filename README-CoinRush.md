# Coin Rush

A small monetized Roblox game laid out as a Rojo project: tiered coin
pickups, dual currency (Coins + Gems), persistent saves, an upgrade shop,
GamePasses, and Robux-purchased gem packs.

## Project layout

```
default.project.json                     Rojo project definition

src/shared/
  GameConfig.luau                        Tunables + product/pass IDs (edit Step 7)

src/server/
  PlayerDataService.server.luau          DataStore I/O, autosave, BindToClose
  UpgradeService.server.luau             Applies upgrades + gamepass perks
  Leaderboard.server.luau                Mirrors Coins/Gems to leaderstats
  CoinService.server.luau                Tiered coins, magnet, multiplier
  ShopService.server.luau                Validates upgrade purchases, daily reward
  MonetizationService.server.luau        ProcessReceipt, gamepass prompts, ownership

src/client/
  CoinClient.client.luau                 Pickup sounds
  HudGui.client.luau                     Coins/Gems pills, Daily Reward, toasts
  ShopGui.client.luau                    Tabbed Upgrades / Gems / Passes UI
```

Server scripts share state via `_G.CoinRush.<name>`; each one waits up to
15 seconds for its dependencies to register before warning.

## Setup checklist

### 1. Install Rojo (CLI + Studio plugin)

The latest release (7.6.1 at time of writing) is fine. Easiest options:

- **Foreman** (recommended): https://github.com/Roblox/foreman#installation
- **Direct download**: https://github.com/rojo-rbx/rojo/releases
- Studio plugin: search "Rojo" in the Toolbox, or run `rojo plugin install`.

Verify: `rojo --version` prints `7.x`.

### 2. Run the project locally

From this directory:

```
rojo serve
```

In Studio:

1. Open a fresh **Baseplate** place.
2. Open the **Rojo** plugin and click **Connect**.
3. `ServerScriptService`, `ReplicatedStorage.Shared`, `StarterGui`, etc.
   will populate.
4. Press **F5** to start a Play Solo session.

You should see a green baseplate, a blue spawn pad, a magenta beacon at
`(12, 4, 0)`, ~40 spinning coins, and the top-left HUD.

### 3. Enable DataStores in Studio

Persistence is off by default in Studio:

**Home -> Game Settings -> Security -> Enable Studio Access to API Services**

Without this, every load/save warns and the player runs with default data
for the session.

### 4. Smoke test

- Walk into a coin: Coins pill bumps, sound plays, coin respawns after 5s.
- A Diamond pickup also increments Gems by 1.
- Click "Daily Reward": +250 coins / +5 gems / toast. Click again: cooldown.
- Walk into the magenta beacon (or press E nearby) to open the shop.
- Buy Speed tier 1 (100 coins). WalkSpeed jumps from 16 to 20 on next
  respawn (or immediately - UpgradeService also applies live).
- Magnet upgrade requires Gems. Tier 1 = 8-stud auto-collect range.
- Gems / Passes tabs show "Not set" until Step 6.

### 5. Publish to Roblox

**File -> Publish to Roblox As...** Create a new experience (set to private
for now). Note the universe/place IDs from the URL.

For subsequent updates: **File -> Save to Roblox**, or `rojo upload` with
an API token.

### 6. Create DeveloperProducts and GamePasses

Open the **Creator Dashboard** at https://create.roblox.com for your
experience.

**Developer Products** (Monetization -> Developer Products -> Create):

| Config key | Display name suggestion | Price (Robux) |
|------------|-------------------------|---------------|
| `Small`    | Small Gem Pack          | 99            |
| `Medium`   | Medium Gem Pack         | 499           |
| `Large`    | Large Gem Pack          | 999           |

**Game Passes** (Monetization -> Passes -> Create):

| Config key    | Display name suggestion | Price (Robux) |
|---------------|-------------------------|---------------|
| `DoubleCoins` | 2x Coins                | 99-199 typical |
| `VIP`         | VIP                     | 199-499 typical |
| `AutoCollect` | Auto Collect Magnet     | 99-299 typical |

Copy each asset's numeric ID from its dashboard URL.

### 7. Paste IDs into GameConfig

Edit `src/shared/GameConfig.luau`:

- `GemProducts.Small.ProductId` / `Medium.ProductId` / `Large.ProductId`
- `GamePasses.DoubleCoins.GamePassId` / `VIP.GamePassId` / `AutoCollect.GamePassId`

Save, re-`rojo serve`, reconnect in Studio, then **republish**.

### 8. Verify a real Robux purchase

Robux purchases **always fail in Studio**. Test in the published place via
the real Roblox client.

1. Join your published place from the Roblox app or website.
2. Open the shop, Gems tab, buy the Small pack.
3. Robux prompt appears. Confirm -> gem balance jumps by 80.
4. Rejoin -> gems persist.
5. Try a GamePass -> perk applies on next character spawn and stays
   applied after rejoining.

If `ProcessReceipt` ever fails to grant gems, Roblox retries on the
player's next join until it succeeds.

## Tuning quick reference

Everything in `src/shared/GameConfig.luau`:

- `CoinCount` - coins on the map at once
- `CoinTiers` - rarity + reward per tier
- `Upgrades.<name>.Tiers` - cost + value progression
- `GemProducts` / `GamePasses` - paste IDs here in Step 7
- `DailyRewardCoins`, `DailyRewardGems`, `DailyCooldownSeconds`

## Known caveats

- Sound asset IDs in `CoinClient.client.luau` are best guesses at public
  assets. If either 404s silently, swap them for known-public IDs from
  the Toolbox.
- ProcessReceipt follows the Roblox-documented grant->save->return
  pattern. In the unlikely case the server crashes after saving but
  before returning, the next retry can double-grant. For production scale,
  add a separate `PurchaseReceipts` DataStore keyed by `PurchaseId`.
- DataStore writes are throttled by Roblox. The 60s autosave + flush on
  PlayerRemoving / BindToClose is safe for tens of players per server.
