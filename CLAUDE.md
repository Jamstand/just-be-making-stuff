# CLAUDE.md — Crack a Geode! (read this first)

Every Claude Code session in this repo reads this file automatically — local sessions on
Josh's Windows PC (which can talk to Roblox Studio through `.mcp.json`; that entry is
Windows-only, so a Mac session has no Studio bridge until a Mac entry is added) and cloud
sessions (which cannot talk to Studio at all).
Keep it short and true. If you change how the project works, update this file too.

## What this repo is

- One git repo, several unrelated projects, separated by **branch**:
  - `claude/crack-a-geode` — **the game.** Rojo project named `CrackAGeode`
    (`default.project.json`), Luau source in `src/`, layout in `README.md`. Also carries
    `.mcp.json` and `assets/store-art` (added with the 2026-09-23 Studio export).
    Weekly automation targets this branch.
  - `claude/roblox-studio-mcp-sx9h7d` — tooling branch: `.mcp.json` (Roblox Studio MCP
    server, Windows-only), `assets/store-art`, `assets/ui-kit`, and the automation files
    listed below. It also still carries an OLD "Coin Rush" `default.project.json` + `src/`
    — ignore those; they are not the geode game.
  - `main` — older Coin Rush project + misc. Not the game (yet).
- **Which branch is "the game branch"?** `main` if its `default.project.json` `name` is
  `CrackAGeode`; otherwise `claude/crack-a-geode`. Every script uses this rule.
- Automation files: `.gitattributes`, `CLAUDE.md`, `rokit.toml`, `selene.toml`, `.luaurc`,
  `scripts/`, `lint/`, `automation/`, `docs/`, `.github/`. They are copied into the game branch with:
  `git checkout origin/claude/roblox-studio-mcp-sx9h7d -- .gitattributes CLAUDE.md rokit.toml selene.toml .luaurc scripts lint automation docs .github`
  (`.gitattributes` pins the bash scripts to LF line endings; without it a Windows checkout with
  `core.autocrlf=true` writes CRLF and `bash scripts/check.sh` dies with `$'\r': command not found`).
- Human guide: `docs/AUTOMATION.md`. Weekly agent procedure: `automation/PLAYBOOK.md`.
- Josh is a solo, non-expert developer. Prefer the boring, obvious change. Unsure? Propose, don't change.

## Golden rules (never break these)

1. **Server-authoritative everything.** Coins, rolls, unlocks, purchases, cooldowns are decided
   on the server; the client only asks. *Why:* anything the client decides, an exploiter decides.
2. **Never change monetization IDs, prices or `key` names** in `Config.GamePasses` /
   `Config.DevProducts` (`src/shared/Config.luau`) or `unlockPrice` / `unlockProductId` in
   `src/shared/Zones.luau`. *Why:* these are Josh's live business numbers and must match the
   Creator Dashboard. A wrong `id` silently breaks real purchases.
3. **Never change `Config.Version`.** *Why:* it is baked into the DataStore name
   (`"CrackAGeode_v" .. Config.Version` in `Data.Init`). Bumping it resets every player to zero.
4. **Every new saved field needs a default in `DEFAULT` in `Data.luau`** plus a one-line
   migration note in the commit message. *Why:* `fromStored` builds every profile from a copy of
   `DEFAULT`, so a field with no default starts as `nil` for every player. (`fromStored` also keeps
   stored keys that are not in `DEFAULT`, so data written by a newer server survives an older one —
   keep that. Still never remove a field.)
5. **`ProcessReceipt` stays idempotent and never returns `PurchaseGranted` before a real save**
   (`Monetize.luau`). Current order (changed in Josh's 2026-09-23 Studio export): look for the
   `PurchaseId` in `p.receipts` → record receipt → `Data.SaveNow` (if it fails, remove the receipt
   mark and return `NotProcessedYet`) → `GrantProduct` → `Data.SaveSoon` → `PurchaseGranted`.
   *Why:* Roblox re-delivers receipts; the saved receipt mark is what stops double grants. Known
   trade-off: the grant itself is not on disk until the next save (the `SaveSoon` lands several
   seconds later), so a server crash before that save, or a Luau error inside `GrantProduct`, can
   lose a paid item. Changing this order is Josh's call — propose, don't change.
6. **Every remote handler validates arguments, refuses while `not S.Ready`, and rate-limits per
   player.** *Why:* remotes are the attack surface.
7. **Mobile first.** Touch targets >= 44 px (StyleGuide's own bar: buttons >= 60 px tall), respect
   the top inset (`GuiService:GetGuiInset()`), works in landscape and portrait.
8. **No formatter, ever** (no StyLua, no "format on save"). Tabs, double quotes, and keep the
   hand-aligned tables in `Config.luau` / `Zones.luau` aligned. *Why:* a formatter would rewrite all
   32 `src/` files and destroy the aligned tables — an unreviewable diff.
9. **Run `scripts/check.sh` before every push.** It must pass. Same gate as CI and the weekly agent.
10. **Cloud sessions cannot see Studio.** The live game changes only when Josh publishes from Roblox
    Studio. Never assume `src/` equals the live place (see "How code moves").
11. **Automation never deletes files, never force-pushes, never pushes to `main` or the game branch,
    never merges its own PR and never writes to the repo through the GitHub API.** Humans merge.

## Code layout map (game branch)

Rojo mapping (`default.project.json`):

| DataModel | Source |
| --- | --- |
| `ReplicatedStorage.Config` / `.Zones` / `.StyleGuide` | `src/shared/{Config,Zones,StyleGuide}.luau` — **`--!strict`** (the only strict files) |
| `ServerScriptService.CrackAGeodeServer` (Script + 18 ModuleScript children) | `src/server/CrackAGeodeServer/` |
| `StarterPlayer.StarterPlayerScripts.CrackAGeodeClient` (LocalScript + 9 modules) | `src/client/CrackAGeodeClient/` |

Everything outside `src/shared` has no `--!` directive (default nonstrict). Leave it that way.

- **Shared:** `Config` = single tuning surface (passes, products, rarities, mutations, perks,
  `Balance`, formulas, `Fmt`); `Zones` = data-driven biome registry (Cavern, Frost, Sunken, Magma,
  Astral; typed unlocks `always|cracks|rebirths|shards|indexPct`, `IsUnlocked`, `StatsFor`,
  `Progress`; per-zone `dropTable` odds — used since the 2026-09-23 export: `Geodes.TryCrack` passes
  them to `Econ.RollRarity`); `StyleGuide` = palette, fonts, UI factories, world look and
  `applyLighting`.
- **Server** (`init.server.luau` builds `ReplicatedStorage.Remotes`, requires every module, calls
  `Init(S)` in dependency order, runs `StyleGuide.applyLighting`, then sets `S.Ready = true`):
  `Data` (session-locked DataStore, `UpdateAsync` only, `BindToClose` flush; `DEFAULT`, `SaveSoon`,
  `SaveNow`, `WaitFor`, `Cache`) · `Buffs` (Lucky Boost, server gift luck, Golden Hour) ·
  `Econ` (rolls + pity, `AwardGems`/`AwardRaw`, `Buy`, `Snapshot`, `Push`) · `Geodes` (crack loop:
  `TryCrack`, `CrackFX`, Auto-Crack, `SpawnGolden`) · `Regions` (zone arenas + Warp Nexus) ·
  `Decor` · `Stations` · `Shards` · `CollectPets` · `Achievements` · `Garden` · `Meteor` ·
  `Monetize` (passes, products, `ProcessReceipt`) · `Boards` · `Pickaxe` · `Onboarding` ·
  `Dailies` · `Pets`.
- **Client** (`init.client.luau` wires remotes to modules): `UI` (~1,440 lines, procedural HUD +
  panels), `Effects`, `Orbit`, `RegionFX`, `NexusFX`, `PetView`, `PickaxeFX` (cosmetic only: plays
  the pickaxe swing, with a whoosh sound, the moment you tap/click, a small camera nudge when the
  server confirms the crack, and other players' swings; also gold-outlines the nearest geode in
  reach), `Signposts` (a station sign that would be cut off at the screen edge is swapped for an
  on-screen label pinned just inside the edge), `Quality` (mobile perf scaler: shadows and depth of
  field off, bloom/haze capped, only the 16 nearest lights kept on — re-checked every 3 s, crack
  flashes under `FX` exempt — and particle rates cut to 45%).
- **Remotes** (all under `ReplicatedStorage.Remotes`):
  RemoteEvents `Announce, CrackFX, StatsChanged, MeteorState, OrbitSync, GoldenHour, StreakShow,
  CrackRequest, DailyPopup, StarterPopup`; RemoteFunctions `GetState, Buy` (Econ), `Purchase`
  (Monetize), `HarvestGarden` (Garden), `ClaimDaily` (Dailies), `EquipPet` (Pets), `FusePet`
  (CollectPets), `ClaimAchievement` (Achievements). `CrackRequest` is handled in Geodes.
- **Saved profile fields** (`DEFAULT` in `Data.luau`): `gems totalGems power luck rebirths
  totalRebirths ascensions shards perks indexMask cracks bestRarity pityRuby pityStar lastHarvest
  lastLogout savedEarnRate streakDay lastStreakDate rewardClaimedDate questDate questProgress
  questClaimed questSetDone boostUntil streakLuckUntil lastVIPBoostDate equippedPet zoneShards
  foundShards petInv zoneIndex achClaimed zonesPurchased zoneVipPets zoneCracked firstJoinRecorded
  starterPackBought onboardStep onboardDone testPasses receipts`. `testPasses` is never persisted
  (`NON_PERSISTED`). New in the 2026-09-23 export: `totalRebirths` (lifetime rebirths, not reset by
  Ascend) and `zoneCracked` (first crack per zone, for the VIP-pass zone pet).
- **Built in Studio, NOT in git:** the hub cavern geometry, `workspace.CrackAGeode` with its `FX`,
  `Nodes`, `Map` (`UpgradePedestal`, `AscensionAltar`) and `Gardens` folders,
  `ServerStorage.PickaxeTemplate` (the Tool `Pickaxe` clones; `Pickaxe.Init` waits for it forever,
  so without it the server never finishes starting) and the `GeodeRockPBR` MaterialVariant (a
  custom rock material in MaterialService, set by name in `Geodes` and `Regions`). Code assumes
  they exist. The Lighting effects `GeodeAtmosphere`, `GeodeBloom`, `GeodeColor` and
  `GeodeDoF` (depth of field, new) are now made by code: the server runs `StyleGuide.applyLighting`
  at startup, which reuses or creates them; `Meteor`, `Buffs`, `RegionFX` and `Quality` find them
  by name.
- Known issues and ideas live in `automation/IDEAS_BACKLOG.md` — check it before "discovering" a bug.

## How code moves between Studio and git

- **Live game = whatever Josh last published from Roblox Studio.** Git never touches it.
- **Local session** (Josh's machine, `.mcp.json` → Roblox Studio MCP): can read/write the open
  place — insert/replace Scripts, run code, and **export** the place's scripts into `src/` (Rojo
  layout above) or **import** `src/` into the place. This is the only bridge.
- **Cloud session** (weekly agent, claude.ai/code): git + static tools + GitHub only. It cannot open
  Studio, playtest, see art, or publish. It must treat `src/` as possibly stale: if the last commit
  that touched `src/` on the game branch (`git log -1 -- src default.project.json`) is older than
  ~3 weeks, say so loudly and keep changes minimal. (A merged report or automation commit does
  not make `src/` fresher.)
- Getting a branch into Studio: `scripts/apply-improvements.ps1` (Windows) or
  `scripts/apply-improvements.sh` (Mac/Linux — the Studio hand-off needs a Mac entry in `.mcp.json`
  first, see docs/AUTOMATION.md §4) — merges the branch locally, then launches a local Claude
  session that applies `src/` to the open place via the MCP and runs the Studio-only `TestHook`
  (`ServerStorage.TestHook`, a BindableFunction created by `init.server.luau` only in Studio;
  actions include `profile`, `crack`, `snapshot`, `addGems`, `buy`, `pass`, `product`, `harvest`,
  `golden`, `zoneUnlocked`). Then Josh playtests and publishes.
- Studio test mode: while an item's `id == 0` **or** `game.GameId == 0`, and only inside Studio
  (`testMode` in `Monetize.luau`), purchases are simulated through the same `GrantProduct` /
  `OnPassGranted` paths a real receipt uses. `README.md` still says IDs are placeholders — they are
  real now (commit 608c288); don't "fix" the IDs back to 0. Since the 2026-09-23 export the server
  `warn`s at startup if any `Config.GamePasses` / `Config.DevProducts` id is 0.

## Before you push

- `scripts/check.sh` — gate (rojo build, luau-lsp ratchet vs `lint/baseline.luau-lsp.txt`, selene).
  `scripts/check.sh --report` prints everything and does not fail on findings (a broken build or a
  selene error-level lint still fails);
  `scripts/check.sh --update` rewrites the baseline (only when a fix legitimately restructures
  code — say why in the commit). The baseline should shrink or stay, never grow.
- No formatter. Tabs. Double quotes. Keep aligned tables aligned. Match the surrounding style.
- Don't add `--!strict` to a file that isn't already strict; don't remove it from one that is.
- New saved field → add to `DEFAULT` in `Data.luau` + migration note. Never remove a field.
- Type-checker noise (UI `refs` table, Zones optional fields, StyleGuide `Instance` typing) is
  known and baselined — fix it only when the fix is small, obvious, and behaviour-neutral.

## Monetization rules

- `Config.GamePasses` keys: `DoubleGems, AutoCrack, DoubleLuck, VIP`. `Config.DevProducts` keys:
  `LuckyBoost, GiftBoost, InstantRegrow, GoldenGeode, CoinsSmall, CoinsMedium, CoinsLarge,
  StarterPack`, plus one auto-derived `Unlock_<ZoneKey>` per zone with an `unlockPrice`.
  IDs, prices, keys, `coins` amounts and `unlockPrice` are **Josh's decisions** — text/`desc` edits
  are fine, numbers are not.
- `Monetize.GrantProduct(player, key, targetUserId)` is the **one** grant path for products (Studio
  test purchases and real receipts both call it). It returns a toast string. One-time products must
  stay self-guarding (`StarterPack` checks `starterPackBought`; `Unlock_*` checks `zonesPurchased`).
  `GiftBoost`: the `Purchase` remote checks the chosen recipient when it opens the prompt and keeps
  it in `giftTarget[player]`; `ProcessReceipt` passes it to `GrantProduct`.
- `Monetize.OnPassGranted(player, key)` is the one grant path for passes: clears `ownsCache`,
  announces, `Econ.Push`, `Data.SaveSoon`. `Monetize.Owns` caches per player until then (a failed
  Marketplace lookup is not cached).
- `ProcessReceipt` (rule 5) also returns `NotProcessedYet` when `Data.IsUsable()` is false — keep that.
- Everything paid must stay earnable by playing (zones via their gate, VIP pets via rare drops).
- A live server must never self-grant: `testMode` requires `RunService:IsStudio()`. Don't loosen it.

## Remote rules

- Pattern to copy (see `Purchase` in `Monetize.luau` or `Buy` in `Econ.luau`):
  `if not S.Ready then return { ok = false, err = "Starting up…" } end` → `type()` checks on every
  argument (`{ ok = false, err = "Bad request" }`) → per-player debounce table (`os.clock()`
  gap; existing gaps: Purchase 0.5 s, Buy 0.1 s, HarvestGarden 0.3 s, CrackRequest 0.05 s), cleared
  on `PlayerRemoving` → do the work server-side.
- Never trust client numbers for gameplay: re-check range, cooldown, ownership, unlock state on the
  server (`Geodes.TryCrack` re-validates all of these even for the mobile `CrackRequest` button).
- Return small tables `{ ok = true/false, err = "...", msg = "..." }`; never `error()` at a client.
- New remotes: add the name to the lists in `init.server.luau`, wire the client in
  `init.client.luau`, validate as above.

## Mobile-first UI rules (`UI.luau`, `StyleGuide.luau`)

- `UI.IsTouch` / `IS_TOUCH` = `TouchEnabled and not MouseEnabled`; size touch UI from it.
- Touch targets >= 44 px on the short side; prefer the StyleGuide's >= 60 px tall buttons.
- Respect `GuiService:GetGuiInset()` (top bar) and keep HUD away from screen edges/notches; test
  landscape AND portrait; nothing under the Roblox top-left menu button.
- Scroll panels (full-size content that scrolls) beat scaled panels (which shrink buttons).
- Keep `Quality.luau` behaviour: fewer lights/particles on mobile, never gameplay differences.
- UI feel/layout changes need eyes in Studio — propose them for the local session rather than
  landing them blind from the cloud.

## Weekly agent (cloud) — pointer + boundaries

- Follow `automation/PLAYBOOK.md` exactly; the schedule sends `automation/TRIGGER_PROMPT.md`.
- Branch `claude/auto-improve-YYYY-MM-DD` from the game branch → small TIER A fixes only → verify
  with `scripts/check.sh` → report in `automation/reports/YYYY-MM-DD.md` → PR to the game branch.
- A cloud session must NOT: touch `.mcp.json`, `assets/`, monetization numbers, `Config.Version`,
  `Config.Balance`, `Config.Rarities` / `Config.Mutations` weights or the Zones drop tables; delete
  files; force-push; push to `main`/game branch; merge its own PR or write through the GitHub API
  (`push_files`, `create_or_update_file`, ...); invent features needing art or Studio work;
  claim it tested gameplay (it can't). Anything TIER B (economy, prices, balance, new monetized
  features, visuals, schema removals) goes in the report as a proposal with a paste-ready prompt.

## Commit message style

- Imperative, first line <= 72 chars, name the module: `Dailies: debounce the ClaimDaily
  remote`, `Data: add zoneVipPets default (migration: new field, defaults to {})`,
  `check.sh: skip selene when the API dump is unreachable`.
- Body: what changed, why, how verified (`scripts/check.sh` result, TestHook actions run).
- One logical change per commit. Never mix a baseline update with unrelated code.
