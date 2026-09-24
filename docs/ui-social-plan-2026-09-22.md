# Crack a Geode! — UI Quality + Player-Base Interaction: Final Implementation Plan

Repo root: `C:\Users\jameg\just-be-making-stuff` (Rojo layout; the Studio place was synced byte-exact to it). Nothing in this document is implemented yet; it is the contract and work breakdown for three implementation owners plus one Phase-0 "shared" owner.

## 0. Provenance and the decisions that resolve the judge findings

**Base proposal:** *Social Cavern: presence-first UI and player-interaction plan*. Combined judge score 124 (80 + 44) versus Polish-First 122 (82 + 40) and Retention Loop 114 (75 + 39); two of three judges named it the winner, and it is the only proposal that covers every explicit goal-B item in the brief (global OrderedDataStore boards with own rank, profiles, feed, nameplates, replicated pets, server goals, cheers, join greetings, chat tags, Meteor shares). Polish-First is a near tie, so its engineering choices are grafted wherever a judge flagged a Social-Cavern hazard.

**Grafted from Polish-First (ship-safe):**
1. `personal = true` flag on every `Announce` sent with `FireClient`, set by `Social.Tell`, and distinct kinds for the collisions (`locked`, `meteorPayout`, `garden`, `shard`, `unlock`). Routing is flag-first, so the onboarding `rare`, CollectPets `pet` and Achievements `ach` personal messages can never be dropped (all three judges flagged this).
2. Back-compat rule: a payload with a legacy `color` Color3 and no flags renders as a headline banner, so nothing is silently lost while the server migration is in flight.
3. Server-created `SoundService.GeodeMusic` / `GeodeSFX` SoundGroups; server Sounds set `.SoundGroup`; a client `Audio.luau` routes local sounds. No client `DescendantAdded` re-parenting hack.
4. `UI.Init(config, remotes, deps?)` with `deps.quality` injected by init.client and a fallback to the existing touch heuristic, so UI.luau never requires a clientModules file and never sees `nil` for IsTouch.
5. `UI.CrackReadyAt()` as the single client cooldown mirror, consumed by `PickaxeFX.SetCooldownSource(fn)`.
6. One `player.AttributeChanged` connection per player (not one per attribute) in Nameplates and the Players panel, coalesced 0.5 s rebuilds.
7. The rail slide-away tween in `_ApplyOpenState` (UI.luau:344-350) must be rewritten together with the rail's new resting anchor (otherwise the rail snaps to mid-right after the first close).
8. Scrim must be `Active`/visible only while a panel is open, ZIndex 19 (below panels at 20).
9. Panel-content polish (perk rows with `Config.Perks.desc`, Index header no longer hidden under the 44 px strip, Daily ladder past/today/future states) folded into the clientUI packages — cheap and directly serves "read instantly".
10. Keep the `PetView.luau` filename (evolved in place); no rename churn in init.client or Rojo.
11. `Buffs.AddServerGift(byName, opts?)` with an optional `{kind, text}` override so ServerGoals produces exactly one broadcast.
12. `JumpButton`-aware rail clearance (read `PlayerGui.TouchGui.TouchControlFrame.JumpButton` when present, else reserve 100 px).
13. Music default 22 (today's `0.22` volume), not 100.

**Grafted from Retention Loop:**
1. Permanent objective tracker priority chain on the GoalCard: onboarding step → claimable daily reward → closest-to-complete daily quest → rebirth progress ≥ 50 % → next achievement tier → next pet unlock; tap opens the relevant panel.
2. GeodeHUD layout attributes `PanelOpen`, `LeftStackBottom`, `CentreBandLeft`, `CentreBandRight` as the only cross-module layout contract (Feed/Effects never read UI frames).
3. Server-goal targets scaled by online count with a floor, a 15 min window, a 60 s rest and a "Goal missed" feed row, so a solo server still completes goals and server-luck uptime stays within what gifts already allow.
4. `RegionFX.OnChanged -> UI.SetZone(key)` for an instant HUD zone line (the server `region` toast stays the welcome message; no duplicate client toast).
5. `serverGoalMine` as a plain int in the per-crack snapshot.
6. ±10 step buttons beside the Music/SFX sliders; settings applied once from the first GetState before the first sound.
7. Players-panel empty-state copy and text-first rows with thumbnails filling in.
8. Leaderboard footer 'Top 50+ — keep cracking!' and physical-board header line 'GLOBAL' / 'THIS SERVER'.

**Dropped or changed from Social Cavern because judges marked it infeasible or hazardous:**
- `S.Guard` on `GetState` no longer returns `{ok=false}`; it keeps Econ's cached-snapshot path and rejects with `nil` (init.client checks `snap and snap.gems ~= nil`).
- Client-side SoundGroup assignment via `workspace.DescendantAdded` — replaced by item 3 above.
- `Social.SyncPresence` reads `snap.passes.VIP` (already computed by Econ.Snapshot) instead of calling `Monetize.Owns` again; compare-before-set is mandatory.
- Fixed-size goals with a 30 s cooldown — replaced by scaled goals with window/rest.
- Toast signature stays `UI.Toast(text, kind?, action?)` (text first); Retention Loop's `(kind, text)` inversion is rejected.
- `Premium` is read from `Player.MembershipType` on the client (it replicates); no server attribute.
- Meteor bar and banners are laid out inside a computed centre band; they fall into the LeftStack only when the band is narrower than 240 px (one rule for all viewports).
- OrderedDataStore values are floored and clamped to `2^53 - 1` before `SetAsync`.
- `settings`, `feed` and `serverGoal` are GetState-only; the per-crack push grows by ~12 numbers, no tables of tables.
- UI.luau is allowed to become a Rojo folder-module (`UI/init.luau` + `UI/*.luau`) under the same clientUI ownership if it exceeds ~2,500 lines; nothing else changes for other owners (`script:WaitForChild("UI")` still resolves).

**Explicitly excluded (unchanged from all three proposals):** trading or any player-to-player value transfer; gem rewards for goals, cheers, Premium or group membership; free text anywhere (all strings are server-built from DisplayNames + fixed emoji, so no TextService filtering); server-built Motor6D pets; the snapshot core/panels split (O37); EquipPet by tier key (O45); a separate Board rail button (boards live as tabs in Players); runtime HUD re-layout on `LastInputTypeChanged`; codes, party/teleport, voice, server browser.

---

## 1. Goals

**A. UI quality.** Every panel (Upgrades, Shop, Index, Daily, Pets, Awards) and the HUD read instantly on a phone and on desktop; every visual comes from StyleGuide tokens; every action has feedback (toasts readable over any scene, claimable glows, affordable/disabled/pending states, error toasts); standard affordances (tap-outside + Escape + gamepad B close, one panel at a time, Settings panel with Music/SFX/Reduce FX/Social pings/Hide feed); touch targets ≥ 48 px; a single currency name.

**B. Player-base interaction.** Other players are visible and worth a tap: nameplates (rebirth tier, equipped pet, VIP crown, Premium star, 'Gifter' title), pets everyone can see, a Players panel (online list with Gift / Cheer / Profile + Global / This-server / Friends leaderboards with own rank), a live activity feed seeded with the last 30 events, rotating cooperative server goals paying only the existing server-luck buff, cheer reactions over players, join greetings, rebirth-tier chat tags, Meteor helper counts / contribution shares / results card. Everything meant to be seen by others replicates through server-set Player attributes or throttled server broadcasts.

**C. Robustness.** Every C→S handler goes through one validator (`S.Guard`); wiring bugs from the audit are fixed (OrbitSync on load, GetState retry, Pickaxe timeout, nil-S guards, watchdog, EquipPet NaN, FusePet variant, GiftBoost target, DailyPopup over onboarding, single swing owner, FX layering); Studio without DataStore access degrades to session data with exactly one warning and zero errors; no new per-frame work scales with player count.

---

## 2. Ownership and file map (disjoint by file)

| Owner | Owns (may edit) | Never edits |
|---|---|---|
| **shared** (Phase 0 only, executed by the server owner before anyone branches) | `src/shared/Config.luau`, `src/shared/StyleGuide.luau` | `src/shared/Zones.luau` (untouched by this plan) |
| **server** | everything under `src/server/CrackAGeodeServer/` incl. `init.server.luau`, new `Social.luau`, new `ServerGoals.luau` | any client or shared file after Phase 0 |
| **clientUI** | `src/client/CrackAGeodeClient/UI.luau` only (optionally as the folder-module `UI/init.luau` + `UI/*.luau`) | every other client file |
| **clientModules** | every other file under `src/client/CrackAGeodeClient/`: `init.client.luau`, `Effects.luau`, `Orbit.luau`, `PetView.luau`, `Quality.luau`, `Signposts.luau`, `RegionFX.luau`, `NexusFX.luau`, `PickaxeFX.luau`, new `Nameplates.luau`, `Feed.luau`, `SocialFX.luau`, `Audio.luau` | `UI.luau` |

Cross-owner data flows ONLY through: remotes, replicated Player attributes, snapshot fields, `UI.On*` hook fields assigned in init.client, the four `GeodeHUD` attributes, and instance names listed in §3.12. Shared is frozen after Phase 0; a later token need is requested from the shared owner, never self-served.

---

## 3. THE CONTRACT

### 3.1 Shared tokens (land first)

**Config.luau additions (SH-2):**
```lua
Config.Currency = { name = "Gems", icon = "💎" }
function Config.Cur(n) return Config.Fmt(n) .. " " .. Config.Currency.icon end   -- "12.3K 💎"

Config.Social = {
  Reactions = { "👏", "🔥", "💎", "🎉", "👋", "💜" },   -- Cheer idx 1..6 (wire value = index)
  CheerGap = 2, CheerBurst = 6, CheerBurstWindow = 30,  -- per sender
  CheerTargetCap = 3, CheerTargetWindow = 10,           -- per target (display cap)
  FeedRing = 30, JoinCoalesce = 3, LeaveMinSession = 20,
  ProfileGap = 1, ProfileCache = 5,
  LeaderboardRefresh = 75, LeaderboardWriteGap = 60, LeaderboardTop = 50,
  SettingsGap = 2,
  SettingsDefault = { music = 22, sfx = 100, reduceFx = false, socialPings = true, hideFeed = false },
  GifterTitleAt = 3,                                    -- giftsGiven >= 3 -> Title "Gifter"
  Goals = {
    { key = "cracks",   icon = "⛏️", event = "crack",   goal = 500, goalMin = 150, label = "Crack %d geodes together" },
    { key = "rares",    icon = "⭐", event = "rare",    goal = 10,  goalMin = 3,   label = "Find %d Rare+ crystals together" },
    { key = "rebirths", icon = "🔄", event = "rebirth", goal = 3,   goalMin = 1,   label = "%d Rebirths together" },
  },
  GoalWindow = 900, GoalRest = 60,                      -- seconds
  -- Announce routing for BROADCASTS (personal messages are flag-routed, see 3.5)
  KindRoute = {
    warn = "headline", meteor = "headline", golden = "headline", goal = "headline",
    rare = "feed", rebirth = "feed", ascend = "feed", pet = "feed", pass = "feed", zone = "feed",
    zoneFirst = "feed", join = "feed", leave = "feed", cheer = "feed", gift = "feed", mvp = "feed",
    unlock = "feed", quest = "feed",
    -- personal-only kinds listed for colour lookup; they arrive with personal=true
    vip = "toast", onboard = "toast", daily = "toast", ach = "toast", giftReceived = "toast",
    region = "toast", locked = "toast", meteorPayout = "toast", garden = "toast", shard = "toast",
    welcome = "toast", info = "toast", error = "toast", ok = "toast",
  },
}
```
Display-string renames in Config (no numeric change): `2× Coins`→`2× Gems`; `DOUBLE all Coin income`→`DOUBLE all Gem income`; `Daily Coin bonus`→`Daily Gem bonus`; `Coin Pouch/Sack/Vault`→`Gem Pouch/Sack/Vault` with `+12,500 Gems` etc.; StarterPack `40,000 Gems + …`; zone product desc `(×N Gems)`; comment `-- coin packs`→`-- gem packs`. Internal keys `CoinsSmall|CoinsMedium|CoinsLarge`, the `coins =` field and `DoubleGems` are unchanged.

**StyleGuide.luau additions (SH-1, additive; the only edited existing value is `Size.CloseBtnTouch` 46→48):**
```lua
Color.Warn = C(255,180,120); Color.Info = C(150,205,255); Color.GoldSoft = C(255,222,130)
Color.OwnedFill = C(60,90,70); Color.TodayFill = C(58,108,78); Color.GreenDim = C(60,160,90); Color.Scrim = Color.Bg0
Size.CloseBtnTouch = 48; Size.RowHDesk = 56; Size.ToastH = 44; Size.ToastHTouch = 48; Size.Badge = 18; Size.Chip = 26
SG.KindColor = { warn=Warn, meteor=Warn, golden=Gold, goal=Green, rare=Text, rebirth=Violet, ascend=Gold, pet=Cyan,
  pass=Gold, zone=Cyan, zoneFirst=Cyan, join=TextDim, leave=TextDim, cheer=Magenta, gift=Green, giftReceived=Green,
  mvp=Gold, ach=Gold, vip=Gold, onboard=Green, daily=Gold, quest=Info, region=Cyan, locked=Warn, meteorPayout=Gold,
  garden=Green, shard=Cyan, unlock=Cyan, welcome=Green, info=Info, error=Red, ok=Green }
SG.kindColor(kind, colorRGB?) -> Color3      -- colorRGB {r,g,b} wins, else KindColor[kind], else Color.Text
SG.Type = { Display={font=Font.Display,min=16,max=28}, Heading={Font.Heading,13,18}, Body={Font.Body,12,14},
            Caption={Font.Body,11,12}, Number={Font.Number,14,26} }  -- min +1 on touch
SG.text(role, props, parent) -> TextLabel     -- TextScaled + UITextSizeConstraint(min,max) + stroke 0.7 + TextTruncate
SG.row(props, parent) -> Frame                -- Bg2 @0.1, corner md, default height Size.RowH
SG.setRole(btn, role)                         -- retints fill/stroke/text (+Gloss/shade if present) from SG.Button[role]
SG.setEnabled(btn, on)                        -- Active, BackgroundTransparency 0.5 / TextDim / stroke+gloss hidden when off
SG.badge(parent, text) -> TextLabel           -- 18 px Red count pill, top-right, hidden when text == ""
SG.chip(text, color, props, parent) -> TextLabel
SG.Tier(rebirths, ascensions) -> Color3       -- ascensions>0 -> Gold; rebirths<5 Violet, <15 Cyan, else Gold
SG.TierHex(rebirths, ascensions) -> "#RRGGBB" -- for chat tags
Icons.players = 0; Icons.board = 0; Icons.sprout = 0   -- emoji fallbacks 👥 🏆 🌱 (no new uploads)
```
Every existing StyleGuide function keeps its signature; NexusFX and UI compile unchanged before their own packages land.

### 3.2 Replicated Player attributes (server-set only; clients read via `GetAttribute` / `AttributeChanged`; never trusted for value)

| Attribute | Type | Written by | Meaning |
|---|---|---|---|
| `Rebirths` | number | `Social.SyncPresence` (end of `Econ.Push`) | `p.rebirths` |
| `Ascensions` | number | same | `p.ascensions` |
| `PetName` | string | same, from `snap.pets.active` | `""` = none |
| `PetEmoji` | string | same | |
| `PetColor` | Color3 | same (`Color3.fromRGB(unpack(active.color))`) | |
| `IsVIP` | boolean | same, from `snap.passes.VIP` (exists today; `Monetize.applyVIPVisuals` also sets it) | |
| `Title` | string | same | `"Gifter"` when `p.giftsGiven >= Config.Social.GifterTitleAt`, else `""` |
| `Zone` | string | `Social.SetZone` from `Regions.Warp` (immediate) and the Regions 1 Hz loop (nearest `Config.Regions` centre in XZ, write on change) | zone key `Cavern|Frost|Sunken|Magma|Astral` |

All writes compare-before-set. Consumers: Nameplates, PetView (others' pets), Players panel, chat tags, HUD zone line fallback. Premium comes from `Player.MembershipType` on the client. The server VIPTag BillboardGui is no longer created (Nameplates draws the crown); the VIP aura particle stays.

### 3.3 New remotes (all created in `init.server.luau` in Phase 0; every C→S handler bound through `S.Guard`)

| Remote | Class | Direction / signature | Validation & limits | Payload |
|---|---|---|---|---|
| `Cheer` | RemoteEvent | C→S `FireServer(targetUserId:int, idx:int)` | `S.Guard{gap=Config.Social.CheerGap, args={"userId","int"}}`; target online and ≠ sender; `1 <= idx <= #Config.Social.Reactions`; sender ≤ CheerBurst per CheerBurstWindow; per-target display cap CheerTargetCap per CheerTargetWindow (excess dropped silently) | S→all `FireAllClients({ fromUserId:int, toUserId:int, idx:int, t:int })`; cosmetic counters `p.cheersGiven` / target `p.cheersReceived`; `Social.Broadcast("cheer", {text="👏 A cheered B", userId=from, feedOnly=true})` |
| `ServerGoal` | RemoteEvent | S→all only, ≤ 1 Hz, only when dirty | — | `{ key, icon, label, progress:int, goal:int, active:boolean, rewardText:string, endsAt:int?, completedAt:int?, missed:boolean? }` |
| `SetSettings` | RemoteEvent | C→S `FireServer(settings:table)` | `S.Guard{gap=Config.Social.SettingsGap, args={"table"}}`; whitelist keys `music,sfx` (number, not NaN, floored, clamped 0..100) and `reduceFx,socialPings,hideFeed` (boolean); unknown keys dropped; stored in `p.settings`; `Data.SaveSoon`; no push back | — |
| `GetProfile` | RemoteFunction | C→S `InvokeServer(targetUserId:int)` | `S.Guard{gap=Config.Social.ProfileGap, args={"userId"}}`; target must be in `Data.Cache` (online); 5 s per-target cache | `{ ok=true, userId, name=DisplayName, rebirths, ascensions, totalGems, bestRarity:int, indexPct:number(0..1), petsOwned:int, achTiers:int, isVIP, zone, cheersReceived, giftsGiven, title, rank={gems:int?, rebirths:int?} }` or `{ok=false, err}`. **Forbidden:** gems balance, receipts, testPasses, boostUntil, quest state, settings. |
| `GetLeaderboard` | RemoteFunction | C→S `InvokeServer(kind:"gems"|"rebirths")` | `S.Guard{gap=1, args={"string"}}`; kind whitelisted | `{ ok, kind, rows={{userId,name,value}} (≤50), myRank:int?, myValue:int, global:boolean, updatedAt:int }`; `global=false` + session rows from `Data.Cache` whenever `Data.IsUsable()` is false |

**`S.Guard` / `S.IsUserId` (init.server, Phase 0):**
```lua
S.IsUserId(x) -> type(x)=="number" and x==x and x==math.floor(x) and x>0 and x<2^53
S.Guard(remote, {
  gap = 0.25,                 -- per-player min seconds between accepted calls
  args = { "string", ... },   -- per position: "string"|"number"|"int"|"userId"|"table"|"boolean"; suffix "?" = optional
  reject = "table",           -- RemoteFunction reply on rejection: "table" -> {ok=false, err=...} | "nil" -> nil (GetState only)
  fn = function(player, ...) end,
})
```
Order of checks: `S.Ready` (`"Starting up…"`) → arg types (`"Bad request"`, numbers also `x==x`) → per-player `os.clock` gap (`"Slow down!"`) → `pcall(fn)` (warn + `"Something went wrong"`). RemoteEvents drop silently. Per-player state cleared on `PlayerRemoving`. Applied to: `GetState` (reject="nil", gap 0 — Econ's own 0.5 s cache stays), `Buy` (0.1, {"string"}), `Purchase` (0.5, {"string","string","userId?"}), `HarvestGarden` (0.3), `ClaimDaily` (0.25), `EquipPet` (0.25, {"int"}), `FusePet` (0.25, {"string","int"}), `ClaimAchievement` (0.25, {"string"}), plus the new `Cheer`, `SetSettings`, `GetProfile`, `GetLeaderboard`. The client treats `"Slow down!"` as a silent no-op.

### 3.4 Existing remotes — changed payloads

- **`MeteorState`** (S→all): `{phase="warning", t=30}` (exists) · `{phase="impact"}` · `{phase="active", hp, maxHp, helpers:int, shares={[tostring(userId)]=pct:int}}` flushed ≤ 4 Hz by a dirty flag in the existing 0.25 s loop (phase changes fire immediately; `Meteor.Damage` only mutates state) · `{phase="boom", results={{userId,name,pct,gained}} (≤5, desc), mvpUserId}` · `{phase="dead", nextAt:int}`.
- **`GoldenHour`** unchanged `{active, remaining?}`; client derives `goldenUntil = serverNow + remaining` and also reads `snap.goldenUntil`.
- **`GetState`** returns `Econ.Snapshot(player)` PLUS GetState-only fields `feed` (≤30 × `{kind,text,colorRGB?,userId?,t}`, oldest first), `settings` (`p.settings` merged over `Config.Social.SettingsDefault`), `serverGoal` (the ServerGoal payload shape + `mine:int`). Rejection returns `nil`; the client retries up to 3× with 1 s backoff and treats a result as a snapshot only if `snap.gems ~= nil`.
- **`OrbitSync`** additionally `FireAllClients({userId, mask=p.indexMask, best=p.bestRarity})` from `Econ.setup` after the profile loads.
- **`DailyPopup`** fires only when `p.onboardDone or p.cracks > 0`. **`StarterPopup`** fires when `p.onboardStep >= 2` or 120 s after join, whichever first (poll every 5 s), and only if still offered.
- **`Purchase("product","GiftBoost",targetUserId)`** unchanged path; `targetUserId` validated with `S.IsUserId` inside `pcall`; if the stored recipient left before the receipt lands, the personal boost goes to the BUYER with `Social.Tell(buyer,"info","X left before the gift landed — boost applied to you")` (never a random player); on success `Social.Tell(target,"giftReceived",{text="🎁 X gifted you a 5-min Lucky Boost!", userId=buyer})`, `buyer.giftsGiven += 1`, `Social.Broadcast("gift", …)`.
- **`EquipPet(i)`** keeps the row index but rejects NaN/fractional (`"int"`). **`FusePet(zoneKey, variant)`** rejects non-integer variant.

### 3.5 `Announce` payload and routing (the one that must not misroute)

Wire shape (S→C, both `FireClient` and `FireAllClients`):
```lua
{ kind:string, text:string, colorRGB?:{r,g,b}, userId?:int, personal?:boolean, feedOnly?:boolean, priority?:int, t?:int }
```
Server rules (SV-2): `Social.Tell(player, kind, textOrPayload, extra?)` is the ONLY personal path and always sets `personal=true` and `userId=player.UserId`; `Social.Broadcast(kind, payload)` is the ONLY `FireAllClients` path (token bucket + ring buffer). Any Color3 passed is converted to `colorRGB`; no Color3 travels on the wire after SV-2.

Kind renames at the call sites: Regions locked gate `warn`→`locked`; Meteor personal payout `meteor`→`meteorPayout`; Meteor MVP `meteor`→`mvp`; Buffs Golden warn stays `warn`, Golden start `golden`; Garden `garden`; Shards `shard` (personal) / `unlock` (broadcast); Onboarding `onboard`; Achievements `ach`; Dailies `daily` (personal) / `quest` (personal per-quest, broadcast all-quests).

Client routing (`UI.Banner(data)`, UI-2) — evaluated in this order:
1. `data.personal == true` → **toast** (kind → role: `error|locked` → `warn`/`err`; `giftReceived|welcome|info` may carry an action; everything else `ok`/`gold`/`info` per `SG.KindColor`).
2. `data.feedOnly == true` → ignored by UI (Feed owns it).
3. `route = Config.Social.KindRoute[data.kind]`: `headline` → top banner stack (≤3, ClipsDescendants, 3.5 s, dedupe identical text within 5 s); `feed` → UI shows a toast ONLY when `data.userId == LocalPlayer.UserId` (own milestone), otherwise ignored (Feed renders it); `toast` → toast.
4. No route and no flags (legacy payload, possibly with `color` Color3) → **headline** (nothing is ever dropped).

Colour precedence everywhere: `colorRGB` > legacy `color` Color3 > `SG.KindColor[kind]` > `Color.Text`.
Toast actions by kind: `welcome` → "Say hi 👋" opens Players; `giftReceived` (userId = giver) → "Thank 💜" = `UI.OnCheer(userId, 6)`; `info` with `userId` → "Cheer 👏" = `UI.OnCheer(userId, 1)`; `daily` from `UI.DailyReady()` → "Open" = `UI.TogglePanel("Daily")`.
Feed (`Feed.Push(data)`, CM-4) records every payload whose route is `feed` or `headline`, plus rows it builds from `Cheer` events; it ignores `personal` payloads.

### 3.6 `Econ.Snapshot` additions (existing fields are unchanged; all new fields are optional to the client)

Per-push (StatsChanged, keep tiny): `online:int`, `serverGoalMine:int`, `serverLuckUntil:int`, `goldenUntil:int` (0 when inactive), `nextMeteorAt:int`, `nextGoldenAt:int`, `myRank={gems:int?, rebirths:int?}` (map lookup in Boards' cache, no I/O), `social={giftsGiven,cheersGiven,cheersReceived}`. All timestamps are server `os.time()`; the existing `now` becomes load-bearing: client `clockOffset = snap.now - os.time()`.
GetState-only: `feed`, `settings`, `serverGoal` (§3.4).

### 3.7 `Data.luau` DEFAULT additions (Data.luau:52-69)

`giftsGiven = 0, cheersGiven = 0, cheersReceived = 0, zonesVisited = {}, settings = {}`. No DataStore schema change (the loader default-fills old profiles). Leaderboard write timestamps and all rate-limit state are in-memory only.

### 3.8 Server internal API and Init order

New Init order in `init.server.luau`: `Data, Buffs, Econ, Social, ServerGoals, Geodes, Regions, Decor, Stations, Garden, Monetize, Meteor, Boards, Pickaxe, Onboarding, Dailies, Pets, Shards, CollectPets, Achievements`. (ServerGoals before Geodes because node ClickDetectors are live from `Geodes.Init` and are not gated on `S.Ready`; `ServerGoals.Event` additionally guards its module-local `S` because `if S.ServerGoals then` is always true once required.) Before any Init: create `SoundService.GeodeMusic` and `SoundService.GeodeSFX` SoundGroups; create the five new Remote instances; define `S.IsUserId` / `S.Guard`.

```lua
-- Social.luau
Social.Init(S)
Social.SyncPresence(player, snap)            -- called at the end of Econ.Push; compare-before-set on the 7 attributes
Social.SetZone(player, key)                  -- Regions.Warp + 1 Hz loop
Social.Broadcast(kind, payload)              -- payload = { text, colorRGB?, userId?, feedOnly?, priority? }; token bucket per kind
                                             -- (rare 5/10 s, cheer 10/10 s, join 3/10 s, leave 3/10 s, zoneFirst 5/10 s, default 10/10 s),
                                             -- overflow coalesced every 10 s ("⭐ +3 more rare finds"), appended to the 30-entry ring, FireAllClients
Social.Tell(player, kind, textOrPayload, extra?)  -- FireClient with personal=true, userId=player.UserId
Social.Recent() -> ring (oldest first)
Social.Cheer(player, targetUserId, idx)      -- bound to Remotes.Cheer via S.Guard
Social.Profile(player, targetUserId)         -- bound to Remotes.GetProfile via S.Guard
Social.Settings(player, tbl)                 -- bound to Remotes.SetSettings via S.Guard
Social.OnJoin(player) / Social.OnLeave(player)  -- join/welcome/leave broadcasts + coalescing
-- ServerGoals.luau
ServerGoals.Init(S)
ServerGoals.Event(player, event:"crack"|"rare"|"rebirth", n)   -- no-op when module S unset
ServerGoals.State(player) -> ServerGoal payload + mine
ServerGoals.Mine(player) -> int
-- Boards.luau
Boards.Get(player, kind) -> GetLeaderboard reply; Boards.MyRank(player) -> {gems?, rebirths?}; Boards.Feed(...) unchanged
-- Buffs.luau
Buffs.AddServerGift(byName, opts?)   -- opts = { kind?, text? }; default kind "gift"; one Social.Broadcast; schedules task.delay(duration+0.5, pushAll)
Buffs.ServerLuckUntil() / Buffs.GoldenUntil() / Buffs.NextGoldenAt()
-- Meteor.luau
Meteor.NextAt()
```
Hook points (one line each, server owner): `Geodes.TryCrack` after `RegisterFind` → `ServerGoals.Event(player,"crack",1)` and `"rare"` when `rarityIdx >= 5`; `Onboarding` starter crack → `"crack"`; `Econ.Buy("Rebirth")` → `"rebirth"`; end of `Econ.Push` → `Social.SyncPresence(player, snap)`; `Regions.Warp` success → `Social.SetZone` + `zonesVisited`/`zoneFirst`; `Econ.setup` after profile load → `OrbitSync` broadcast + `Social.OnJoin`.
TestHook new actions: `cheer(idx)`, `goal(n)`, `goalComplete`, `lb(kind)`, `presence`, `feed`, `settings(tbl)`, `meteorState` (last 10 payload timestamps).

### 3.9 `UI.luau` public surface

Unchanged: `UI.Update(snap)`, `UI.OnCrack(data)`, `UI.Meteor(data)`, `UI.GoldenHour(data)`, `UI.Streak(data)`, `UI.TogglePanel(name|nil)`, `UI.ShowPanel(name)`, `UI.IsTouch`, `UI.OnCrackInput` (assignable hook).
Changed: `UI.Init(config, remotes, deps?)` — `deps = { quality = Quality }`; UI reads `deps.quality.IsTouch` and `deps.quality.Tier` when present, else `UserInputService.TouchEnabled and not MouseEnabled`. `UI.Toast(text, kind?, action?)` — `kind ∈ "ok"|"err"|"info"|"warn"|"gold"`; a Color3 second argument is still accepted and mapped to `info`; `action = { label, fn }`. `UI.Banner(data)` becomes the router of §3.5 (`UI.Announce` is an alias).
New: `UI.ServerGoal(data)`, `UI.OnCheerReceived(data)` (toast '👏 X cheered you!' with 'Cheer back'), `UI.OpenProfile(userId)`, `UI.AnyPanelOpen() -> boolean`, `UI.Modal(spec)` (`spec = { title, body:string|builder(frame), buttons = {{ text, role, fn, hold?:boolean }} }`, registered in `panels` so scrim/Escape/one-open apply), `UI.Confirm(spec)`, `UI.CrackReadyAt() -> os.clock()`, `UI.SetZone(zoneKey)`, `UI.DailyReady()`, `UI.StarterReady()`, `UI.GetSettings() -> table`.
Panel names in `panels`: `Upgrades, Shop, Index, Daily, Pets, Achievements, Players, Settings` (+ reserved `Modal`).
Hooks UI CALLS (assigned only by init.client, all nil-checked): `UI.OnCrackInput()`, `UI.OnCheer(targetUserId, idx)`, `UI.OnSettingsChanged(settings)`.
UI calls remotes only through `UI._invoke(remote, ...)` (pcall + `type(res)=="table"` + per-button pending) and looks up the new remotes with `Remotes:FindFirstChild` so the panels open against an older server.

### 3.10 Client module surfaces (clientModules)

- `Quality`: `IsTouch`, `IsMobile` (alias), `Tier` (0..2; auto 1 touch / 2 desktop), `ReduceFX`, `Settings` (table), `Changed` (BindableEvent.Event, arg = field name), `ApplySettings(tbl)`, `Init()`. Flags are set synchronously at require time.
- `Audio`: `Init(Config)`, `Play(id, volume?, speed?, parent?)` (SFX in GeodeSFX), `Apply({music, sfx})` (group Volume = n/100).
- `Nameplates`: `Init(Quality)`, `OnTap = function(userId) end`.
- `PetView` (evolved, same file): `Init(Quality)`, `Set(active)` (local pet immediate feedback; others attribute-driven).
- `Feed`: `Init(Config, Quality)`, `Push(data)`, `PushCheer(data)`, `Seed(list)`, `SetHidden(bool)`, `OnTapUser = function(userId) end`.
- `SocialFX`: `Init(Config, Quality)`, `Send(targetUserId, idx)`, `OnCheer(data)`, `SetEnabled(bool)`.
- `Orbit`: `Init(Config, Quality)`, `Sync(data)`.
- `Signposts`: `Init(Quality)`; skips any BillboardGui with attribute `Signpost == false`.
- `PickaxeFX`: existing `Init/Swing/OnCrack` + `SetCooldownSource(fn)`.
- `RegionFX`: `Init(config)`, `Set(key)`, `OnChanged = function(zoneKey) end`.
- `Effects`: `Init(config)`, `Crack`, `Meteor` (distance-scaled), `ApplyReduceFX(bool)`.
- `NexusFX`: unchanged API; copy + roles updated.

### 3.11 `init.client.luau` wiring (clientModules)

Order: `Quality` (sync flags) → `UI.Init(Config, Remotes, { quality = Quality })` → `Audio.Init(Config)` → `Effects.Init(Config)` → `Orbit.Init(Config, Quality)` → `PetView.Init(Quality)` → `RegionFX.Init(Config)` → `NexusFX.Init()` → `Signposts.Init(Quality)` → `PickaxeFX.Init()` → `Nameplates.Init(Quality)` → `Feed.Init(Config, Quality)` → `SocialFX.Init(Config, Quality)` → `task.spawn(Quality.Init)`.
Hooks: `UI.OnCrackInput = PickaxeFX.Swing`; `PickaxeFX.SetCooldownSource(UI.CrackReadyAt)`; `UI.OnCheer = SocialFX.Send`; `UI.OnSettingsChanged = function(s) Quality.ApplySettings(s); Audio.Apply(s); Feed.SetHidden(s.hideFeed); SocialFX.SetEnabled(s.socialPings); Effects.ApplyReduceFX(s.reduceFx) end`; `Nameplates.OnTap = UI.OpenProfile`; `Feed.OnTapUser = UI.OpenProfile`; `RegionFX.OnChanged = UI.SetZone`.
Remotes: `StatsChanged` → `UI.Update`, `PetView.Set(snap.pets and snap.pets.active)`, `NexusFX.Update`; `GetState` (retry 3×, 1 s backoff, accept only `snap.gems ~= nil`) → the same plus `Feed.Seed(snap.feed)`, `UI.ServerGoal(snap.serverGoal)`, and once: `UI.OnSettingsChanged(snap.settings)`; `Announce` → `Feed.Push(data)` then `UI.Banner(data)`; `Cheer` → `SocialFX.OnCheer`, `Feed.PushCheer`, and `UI.OnCheerReceived` when `toUserId == LocalPlayer.UserId`; `ServerGoal` → `UI.ServerGoal`; `MeteorState` → `UI.Meteor`, `Effects.Meteor`; `GoldenHour` → `UI.GoldenHour`; `StreakShow` → `UI.Streak`; `OrbitSync` → `Orbit.Sync`; `CrackFX` → `Effects.Crack`, `PickaxeFX.OnCrack`, `UI.OnCrack`; `DailyPopup` → `UI.DailyReady()`; `StarterPopup` → `UI.StarterReady()`. New remotes fetched with `Remotes:WaitForChild(name, 5)`; nil → warn and skip. The unused `state` local is deleted. Chat: `OnIncomingMessage` prefixes `[R12]` (colour `SG.TierHex`) or `[A2]` before the existing `[VIP]`; numbers only.

### 3.12 Instance names and GeodeHUD attributes (cross-module layout contract)

- ScreenGuis: `GeodeHUD` (DisplayOrder 10, UI), `GeodeFeed` (9, Feed), `SignpostGui` (9, Signposts), `GeodeFXWorld` (5, Effects floating text) and `GeodeFXOverlay` (50, Effects flashes).
- `GeodeHUD` attributes written by UI (`_RefreshPanels` / `_ApplyOpenState`): `PanelOpen:boolean`, `LeftStackBottom:number` (px, gui-relative), `CentreBandLeft:number`, `CentreBandRight:number`. Feed positions itself from these and listens to `GetAttributeChangedSignal`; Effects skips floating text while `PanelOpen`.
- Any BillboardGui created by a client module carries attribute `Signpost = false`; client pets live under a client-created `workspace.GeodePets` folder (outside `CrackAGeode` and the camera, so Signposts and Quality's light cull ignore them).

### 3.13 Validation invariants for every C→S path

`S.Ready`; `type()` on every arg and `x == x` on numbers; integers via `math.floor(x) == x`; enums whitelisted (Cheer idx, Buy action, board kind, settings keys); per-player `os.clock` limiter; `PlayerRemoving` cleanup; the invoking player is the only actor — a client-supplied userId only selects a cosmetic target or a Robux-prompt recipient validated server-side; nothing a client sends grants value; no free text on the wire (so no TextService filtering — if free text is ever added, `FilterStringAsync` is mandatory).

---

## 4. WORK PACKAGES

### 4.1 shared (Phase 0; executed by the server owner before branching)

**SH-1 — StyleGuide semantic extension** — `src/shared/StyleGuide.luau`
Everything in §3.1 (colours, sizes, `KindColor`, `kindColor`, `Type` roles + `text`, `row`, `setRole`, `setEnabled`, `badge`, `chip`, `Tier`, `TierHex`, icon keys). Document each new name in the file header.
Acceptance: `--!strict` clean on server and client; NexusFX and UI run unchanged; every name in §3.1 exists; `Size.CloseBtnTouch == 48` is the only changed existing value.

**SH-2 — Config currency token, Gems copy, `Config.Social`** — `src/shared/Config.luau`
`Config.Currency`, `Config.Cur`, the display-string renames, `Config.Social` exactly as §3.1. No value in `Config.Balance`, `GamePasses`, `DevProducts` changes.
Acceptance: `grep -rni coin src/shared` hits only the keys `CoinsSmall|CoinsMedium|CoinsLarge`, the `coins =` fields and no player-visible string; both server and client read reactions/goals/routes from `Config.Social` (no duplicated literals anywhere in the repo).

### 4.2 server

**SV-1 — Remote shell + `S.Guard` + existing validation fixes** (Phase 0 for the shell, then the rest first among server items)
Files: `init.server.luau`, `Econ.luau`, `Monetize.luau`, `Garden.luau`, `Dailies.luau`, `Pets.luau`, `CollectPets.luau`, `Achievements.luau`.
- init.server: add `Cheer, ServerGoal, SetSettings` to the RemoteEvent list and `GetProfile, GetLeaderboard` to the RemoteFunction list; create `SoundService.GeodeMusic` / `GeodeSFX`; add `Social`, `ServerGoals` to the require list and the Init order of §3.8 (guarded so a missing module only warns); define `S.IsUserId`, `S.Guard` (§3.3); `task.delay(15)` watchdog warning if `S.Ready` is still false.
- Route all eight existing RemoteFunctions through `S.Guard` with the gaps of §3.3: `Econ.luau:311-338` (GetState reject="nil", Buy), `Monetize.luau:157-215` (Purchase; GiftBoost target via `S.IsUserId` in pcall), `Garden.luau:174`, `Dailies.luau:203-205` (adds the missing Ready guard), `Pets.luau:127-129` (Ready guard; `Pets.Equip` rejects NaN/fractional at 114-117), `CollectPets.luau:196-200` (variant integer), `Achievements.luau:90-94`.
Acceptance: `EquipPet(0/0)`, `EquipPet(1.5)`, `FusePet("Frost", 1.5)`, `Purchase("product","GiftBoost",1e300)` all return `{ok=false}` with no error in Output; `GetState` spam still returns the cached snapshot and never a table without `gems`; the five new Remote instances and two SoundGroups exist before `S.Ready`; TestHook `profile/crack/buy/product/harvest/meteorDamage/golden/snapshot/claimAch` still work; hold-to-crack UX unchanged (Buy gap 0.1).

**SV-2 — `Social.luau` core: presence attributes, Broadcast/Tell, feed ring, Announce migration**
Files: new `Social.luau`, `init.server.luau`, `Econ.luau`, `Data.luau`, `Regions.luau`, `Monetize.luau`, `Geodes.luau`, `Buffs.luau`, `Pets.luau`, `CollectPets.luau`, `Dailies.luau`, `Shards.luau`, `Garden.luau`, `Onboarding.luau`, `Achievements.luau`, `Meteor.luau`.
- Presence (§3.2): `Social.SyncPresence(player, snap)` at the end of `Econ.Push` (Econ.luau:275-280), compare-before-set; `Social.SetZone` from `Regions.Warp` (Regions.luau:186-208) and a 1 Hz nearest-centre loop (same rule as RegionFX); `Monetize.applyVIPVisuals` (Monetize.luau:53-90) stops building the `VIPTag` billboard, keeps `IsVIP` + aura.
- Broadcast/Tell/ring (§3.5, §3.8). Migrate every Announce call site (Achievements:78, Buffs:23/58/86/95, CollectPets:45/75/155, Dailies:98/131/144, Econ:193/205, Garden:85, Geodes:213/466/487, Meteor:91/101/213, Monetize:96/164, Onboarding:61/71/154, Pets:70, Regions:192/203, Shards:46/52) to `Social.Tell` / `Social.Broadcast` with the kinds of §3.5 and `colorRGB` tables.
- Data DEFAULT additions (§3.7). Snapshot: `online`, `social` (§3.6). GetState attaches `feed` and `settings`.
Acceptance: with two Studio clients, B's attributes appear on A within one Push of a rebirth/equip/warp and never rewrite when unchanged (verify via `AttributeChanged` count); 30 rare finds in 10 s deliver ≤5 `rare` rows + 1 coalesced row; `GetState().feed` has ≤30 entries; no Announce payload carries a Color3 (`grep -n "color = Color3" src/server` returns nothing under Announce sites); every personal message carries `personal=true` and `userId`; the onboarding "Your first crystal" and CollectPets "pet found" messages still toast on the current client.

**SV-3 — Cheer, GetProfile, SetSettings handlers; join/leave/zoneFirst; gift recipient notice + no silent re-target; Golden bystander hint**
Files: `Social.luau`, `Regions.luau`, `Monetize.luau`, `Geodes.luau`, `Econ.luau`.
- Bind `Cheer`, `GetProfile`, `SetSettings` via `S.Guard` with the rules of §3.3 (profile allow-list only; rank from `Boards.MyRank(target)` when SV-4 has landed, else nil).
- Join: on profile ready `Broadcast("join", {text="👋 X joined · Rebirth N", userId, feedOnly=true})` coalescing > `JoinCoalesce` per 10 s, and `Tell(player,"welcome","Welcome! N miners online — say hi 👋")` when `online > 1`. Leave: `Broadcast("leave", feedOnly)` unless session < `LeaveMinSession`.
- zoneFirst: in `Regions.Warp` on success, if `not p.zonesVisited[key]` then set + `SaveSoon` + `Broadcast("zoneFirst", {text=icon.." X reached "..name.." for the first time!", userId})`.
- GiftBoost (Monetize.luau:109-124): recipient-gone → boost to BUYER + `Tell(buyer,"info",…)`; success → `Tell(target,"giftReceived",…)`, `buyer.giftsGiven += 1`, `Broadcast("gift", …)`; Title `"Gifter"` refreshes on the next Push.
- Golden bystander (Geodes.luau:455 `openGolden`): a non-owner click → `Tell(clicker,"info",{text="That's X's Golden Geode — cheer them on! 👏", userId=owner})`, rate-limited 1 per 10 s per clicker.
- Snapshot: `settings` merged over `Config.Social.SettingsDefault` (GetState-only).
Acceptance: 7 cheers in 2 s from one client → exactly 1 `Cheer` broadcast, 7th-in-30 s dropped silently; `GetProfile` on self or an offline id → `{ok=false}`; the reply never contains `gems`, `receipts`, `testPasses`, `boostUntil` or quest fields (assert by key list); `SetSettings({music=0/0})` leaves settings unchanged; a joiner sees one welcome toast and others see one feed row; gifting a player who leaves mid-prompt never names a third player.

**SV-4 — Persistent global leaderboards (OrderedDataStore) + hardened physical boards**
Files: `Boards.luau`, `init.server.luau`, `Econ.luau`.
- Stores `CrackAGeode_LB_gems_v<Config.Version>` (value `totalGems`) and `CrackAGeode_LB_rebirths_v<Version>` (value `totalRebirths`); values floored and clamped to `2^53-1`; writes per player at most once per `LeaderboardWriteGap` and on `PlayerRemoving`, only when changed, pcall'd, gated on `S.Data.IsUsable()`.
- Reads every `LeaderboardRefresh` s per kind: `GetSortedAsync(false, LeaderboardTop)` → cache `{rows, byUser, updatedAt}`; names = DisplayName when online else `Players:GetNameFromUserIdAsync` (pcall, cached per userId, fallback "Miner").
- `Boards.Get(player, kind)`, `Boards.MyRank(player)` (§3.8); bind `GetLeaderboard` via `S.Guard`; `Econ.Snapshot.myRank`.
- Physical `TopGems`/`TopRebirths` walls mirror the cache top 8 with a header line `GLOBAL` / `THIS SERVER`; `setList` uses `FindFirstChild("List")` (Boards.luau:10-16) and the refresh loop body is pcall'd so one missing gui cannot kill all boards. TestHook `lb(kind)`.
Acceptance: Studio without DS → `GetLeaderboard` returns `global=false` + session rows and exactly one `[Data]` warning; with DS, two servers converge on the same top rows within ~75 s; no rank error ever reaches a client; DataStore requests stay ≤ N/60 s writes + 2 reads/75 s.

**SV-5 — `ServerGoals.luau`: rotating co-op goals, luck-only reward, `ServerGoal` remote**
Files: new `ServerGoals.luau`, `init.server.luau`, `Geodes.luau`, `Econ.luau`, `Onboarding.luau`, `Buffs.luau`.
- Goals rotate round-robin through `Config.Social.Goals`; on start `target = math.max(goalMin, math.ceil(goal * math.clamp(online/5, 0.4, 2)))`, `endsAt = now + GoalWindow`; `Event()` adds to progress and the per-player `contrib` map (in-memory) when the event matches; completion → `Buffs.AddServerGift("the whole server", {kind="goal", text="🎯 SERVER GOAL COMPLETE — "..rewardText.."!"})` (the existing +10 % server luck for `ServerLuckDuration`; the ONLY reward), then `GoalRest` s idle, then the next goal; expiry → feed row "Goal missed — new goal in 60 s" (`Broadcast("goal", {…, feedOnly=true})`) and the same rest. `rewardText = string.format("+%d%% Server Luck for %d min", ServerLuckPerGift*100, ServerLuckDuration/60)`.
- Broadcast: 1 s ticker fires `ServerGoal:FireAllClients(state)` only when dirty; `ServerGoals.State(player)` for GetState; `serverGoalMine` per push. Hooks per §3.8. `Buffs.AddServerGift` gains the `opts` override and the expiry `pushAll`. TestHook `goal(n)` / `goalComplete`.
Acceptance: 40 cracks/s across 3 clients produce ≤1 `ServerGoal` event/s; completion grants exactly one `AddServerGift` and no gems (assert `p.gems` unchanged); a solo server's `cracks` goal starts at 150 (floor); a joiner's `GetState().serverGoal` shows the live goal; after expiry the next goal starts 60 s later.

**SV-6 — Meteor 4 Hz batching with shares and results; Buffs timers; next-event clocks**
Files: `Meteor.luau`, `Buffs.luau`, `Econ.luau`.
- `Meteor.Damage` (171-185) only mutates hp/contrib and sets `dirty`; the 0.25 s loop (222-224) flushes the `active` payload of §3.4; `supernova` sends `boom` with `results` (≤5) + `mvpUserId` and `Broadcast("mvp", …)`; `fizzle` sends `dead` with `nextAt`; `Meteor.NextAt()` tracked by the cycle loop. Server sounds (Geodes.luau:37-46, Meteor.luau:18-26, Onboarding) set `.SoundGroup = SoundService.GeodeSFX`.
- Buffs: `serverLuckUntil` tracking, `ServerLuckUntil()`, `GoldenUntil()`, `NextGoldenAt()`; `AddServerGift` schedules `task.delay(duration + 0.5, pushAll)`.
- Snapshot: `serverLuckUntil, goldenUntil, nextMeteorAt, nextGoldenAt`.
Acceptance: with 3 clients tapping the meteor, ≤4 `MeteorState` events/s (TestHook `meteorState`); `shares` sums to ≤100; the Server Luck chip disappears on an idle client within 1 s of expiry with no client action; the SFX slider (CM-6) attenuates a crack sound.

**SV-7 — Bootstrap hardening, first-run gating, OrbitSync on load, TestHook social actions**
Files: `Econ.luau`, `Pickaxe.luau`, `CollectPets.luau`, `Achievements.luau`, `Dailies.luau`, `Monetize.luau`, `init.server.luau`.
- `Econ.setup` (282-297): after profile load `OrbitSync:FireAllClients({userId, mask, best})` and `Social.OnJoin(player)`.
- `Pickaxe.Init` (85): `ServerStorage:WaitForChild("PickaxeTemplate", 5)` with warn + skip; `CollectPets.Snapshot` (166) and `Achievements.State` (42) return nil when their module `S` is unset.
- `Dailies.onJoin` (186-195): fire `DailyPopup` only when `p.onboardDone or p.cracks > 0`; `Monetize.trackFirstSession` (293-311): `StarterPopup` when `p.onboardStep >= 2` or 120 s.
- TestHook: `cheer, goal, goalComplete, lb, presence, feed, settings, meteorState`.
Acceptance: deleting `PickaxeTemplate` in Studio still prints "Server started" with one warning and `S.Ready == true`; a fresh profile never receives `DailyPopup` before its first crack; a second Studio client sees the first client's orbit ring within 1 s of joining; every TestHook action returns a table or boolean, never errors.

**SV-8 — Server currency copy**
Files: `Monetize.luau`, `Buffs.luau`.
`Monetize.luau:139` → `"💰 +" .. Config.Cur(amt) .. "!"`; `:149` → `"⭐ Starter Pack unlocked — Gems + exclusive Starter Sprite pet!"`; `Buffs.luau:57` comment and `:60` → `"👑 VIP daily bonus: +5,000 Gems & a free Lucky Boost!"`.
Acceptance: `grep -rni coin src/server` hits only `CoinsSmall|CoinsMedium|CoinsLarge`, `item.coins` and comments.

### 4.3 clientUI (`UI.luau` only)

**UI-1 — Panel factory on `SG.panel`, 48 px targets, scrim + Escape/ButtonB, `UI.Modal`, 9-button rail clear of the jump button, layout attributes**
- Rebuild `makeScrollPanel` (196-244) on `SG.panel` with a 52 px title strip (`SG.text("Display")` title, a balance slot on the right filled by UI-3, close hit-frame 48×48 on touch / 40 desktop using `Size.CloseBtnTouch/CloseBtn`); delete `makePanel` (147-190) and the dead `"scale"` branch in `_RefreshPanels` (319-322); `HEADER_ICONS` (133-137) gains `📅→gift`, `👥→players`, `⚙️→gear`.
- Replace every fixed `Size` literal in the six build* functions with tokens: stat rows `SG.row` at `RowH` (64 touch / `RowHDesk` 56), action buttons ≥ `BtnH` 52 / `BtnHTouch` 60 (Power/Luck/Rebirth/Ascend 377/410/429; pet EQUIP 120×52/60; FUSE 112×52/60; Daily CLAIM 704; Starter GET IT; shop buy 110→120×52/60; Awards CLAIM 128×52/60); perk cells 447 become full-width rows (UI-7). All body labels via `SG.text` roles; acceptance grep target: 0 hits for `Enum.Font.` and ≤5 for `Color3.fromRGB` (rarity/pet colours only).
- `_RefreshPanels` (276-326): touch FitScale floor 1.0 (`s = min(1, (regionW-16)/p.w)`; extra height scrolls); desktop upscale to 1.3 when `availH >= 1000`; width `min(SG.Size.PanelW, regionW-16)`; compute and write `GeodeHUD` attributes `LeftStackBottom`, `CentreBandLeft = leftStack.AbsoluteSize.X + 20`, `CentreBandRight = availW - menuW - 8`; banners (1167-1172) and the meteor bar (1206-1212) are sized inside the band via `UISizeConstraint` (min 240); when the band is < 240 px they are reparented into the LeftStack (LayoutOrder 4 banners, 5 meteor) at `cardW`.
- Rail (1040-1102): `count = #sideOrder`; touch = 3×3 grid anchored `(1,0)` at `(1,-10,0,8)`, rendered height clamped to `availH - 8 - jumpReserve` where `jumpReserve` = JumpButton height + 16 when `PlayerGui.TouchGui.TouchControlFrame.JumpButton` exists, else 100; never scale a button below 48 px (hide the label text first); desktop stays one column with the existing 2-column fallback; `_ApplyOpenState` (344-350) slide-away uses the new resting position; add `Players` (icon `players`) and `Settings` (icon `gear`) buttons.
- Scrim TextButton `Name="Scrim"`, ZIndex 19, `SG.Color.Scrim` @0.45, `Text=""`, `AutoButtonColor=false`, visible/`Active` only while `anyOpen`, `Activated → UI.TogglePanel(nil)`; `UserInputService.InputBegan` Escape / Gamepad ButtonB → `UI.TogglePanel(nil)`; `_ApplyOpenState` sets `gui:SetAttribute("PanelOpen", anyOpen)` and keeps the gem card visible on desktop (hides chips/GoalCard only; hides the whole LeftStack only in overlay mode). `UI.AnyPanelOpen()`, `UI.Modal(spec)` (§3.9; `hold=true` renders a 0.8 s hold-to-confirm fill on touch), `UI.Confirm(spec)`.
Acceptance: at 568×320, 812×375, 844×390 with IS_TOUCH every TextButton inside a panel or the rail has `AbsoluteSize ≥ 48×48` and the rail's bottom ≤ `H - jumpReserve`; Escape, gamepad B, tap-outside and × all close any panel or modal; only one panel is ever visible; world ClickDetector taps behind an open panel are swallowed; no TextLabel in GeodeHUD renders below 12 px (13 on touch); 1024×768 and 1920×1080 desktop layouts unchanged except the two new rail buttons; the rail returns to its resting position after a panel closes in overlay mode.

**UI-2 — Toast lane with roles, Announce router, `UI._invoke`, true button states**
- `UI.Toast(text, kind?, action?)` (58-75 replaced): bottom-centre lane anchored `(0.5,1)` at `y = H-140` (touch, above CrackWrap) / `H-90` (desktop, above the hotbar); UIListLayout bottom-up, max 3 visible with FIFO eviction; each toast a Bg1 pill @0.15 + `SG.stroke` + `SG.text("Body")`, height `ToastH/ToastHTouch`, width `UDim2.new(0.9,0,0,h)` with `UISizeConstraint` 240..520, colour `SG.kindColor`; life 2.6 s; dedupe identical text within 1 s; `"Slow down!"` swallowed; `action` renders a ≥48 px tappable pill.
- `UI.Banner(data)` router exactly as §3.5 (`UI.Announce` alias); headline stack ≤3 with ClipsDescendants, Bg1 background so it reads over Frost/Void scenes, 3.5 s, dedupe 5 s.
- `UI._invoke(remote, ...)` (pcall + `type(res)=="table"`; on failure `UI.Toast("Something went wrong","err")` and return `{ok=false}`) and `UI._bindInvoke(btn, fn)` (per-button pending → `SG.setEnabled(btn,false)` until return); route all nine `InvokeServer` sites (460, 467, 539, 568, 710, 811, 846, 934, 1102).
- States: buttons built with `SG.button(text, role)` and driven by `SG.setRole`/`SG.setEnabled` in every refresh; affordable/claimable → `buy` (TextInk on Green), premium purchases → `premium`, unaffordable → `ghost` + `setEnabled(false)` + sub-line `"Need "..Config.Cur(diff).." more"`; status-only rows (`✅ OWNED`, `✅ EQUIPPED`, `✓ DONE`, `Tier N`, `Need 3`, `✅ Claimed — back tomorrow!`) become label chips with no handler; delete the Init retrofit pass (1387-1402) and every `AutoButtonColor` write (grep target: no `mk("TextButton"` outside the scrim/rail; only `SG.button`).
Acceptance: two toasts fired in the same frame stack without overlap and never cover the CRACK button at 812×375; 20 simultaneous rare announces produce ≤3 banners and 0 toasts (unless own); a legacy `{text, color=Color3}` payload still shows as a headline; a personal `rare`/`pet`/`ach` payload always toasts; a server error in EquipPet shows one `err` toast and re-enables the button; double-tapping CLAIM/EQUIP/FUSE never shows "Slow down!"; no handler invokes the server from a disabled control; every affordable button reads dark ink on green.

**UI-3 — Balance strip, Rebirth/Ascend confirm, Garden button fix, rail glow + count badges, first-run sequencing**
- Every panel title strip shows `"You have "..Config.Cur(snap.gems)` (`SG.text("Number")`, right-aligned before ×) updated in `UI.Update`.
- Rebirth/Ascend (461-472) open `UI.Confirm`: title `"🔄 Rebirth N?"` / `"🌌 Ascend?"`, body listing resets (Gems, Power Lv, Luck Lv[, Rebirths]) and gains (`×1.5 income compounding` / `×2.5 base + 1 Shard`), buttons Cancel (`ghost`) + Confirm (`danger`, `hold=true` on touch), Confirm disabled until affordable.
- Garden rail button (1099-1102, 1253): iconKey `sprout`, label stays "Garden", value as `SG.badge` (`Fmt(gardenValue)` or `"FULL!"`), `setEnabled(false)` while `gardenValue == 0`, glow when overgrown.
- Rail badges/glows: Pets glows when any collectible count ≥3 or a stronger unlocked pet is unequipped; Upgrades glows when Power or Luck is affordable; count badges on Daily (claimable + done-unclaimed quests), Awards (claimable tiers), Players (unread feed events since last open, capped "9+").
- `UI.DailyReady()`: glow Daily + toast "🎁 Daily reward ready" with action "Open"; `UI.StarterReady()`: gold toast with action "Shop"; never auto-open a panel in the first session.
Acceptance: opening Upgrades on a phone still shows the balance; a single tap can no longer trigger Rebirth or Ascend; a new player sees a 🌱 "Garden" button with a "0" badge, not a 💎 "0"; no modal opens automatically in the first 30 s of a fresh profile.

**UI-4 — Players panel (Online tab) with Gift / Cheer / Profile, profile modal, cheer strip; deletes `pickGiftTarget`**
- Panel `Players` ("👥 PLAYERS") with a tab bar `[Online | Top Gems | Top Rebirths]` (UI-5 fills the last two). Online tab: one `SG.row` per `Players:GetPlayers()` (56 touch / 52 desktop): avatar (`GetUserThumbnailAsync` HeadShot 48 in pcall, emoji fallback, text-first), DisplayName + tier pill `R12` coloured by `SG.Tier` (+ `A2` when >0), zone icon from the `Zone` attribute via `Config.Zones.Get(key).icon`, pet `PetEmoji PetName`, 👑 when `IsVIP`, ⭐ when `MembershipType == Premium`, `Title` when non-empty, "You" marker; actions ≥48 px: 🎁 Gift (`UI.Confirm` "Gift a 5-min Lucky Boost to X · R$ 25" → `UI._invoke(Remotes.Purchase,"product","GiftBoost",userId)`), 👏 Cheer (6-emoji strip from `Config.Social.Reactions`; tap → `UI.OnCheer(userId, idx)`; strip disabled `CheerGap` s after use), 👤 Profile (`UI.OpenProfile`). Sort: same zone first, then Rebirths desc. Empty state: "You're the first one here — the feed fills up as miners arrive."
- Rebuild is event-driven: `PlayerAdded/Removing` + ONE `player.AttributeChanged` connection per player mark dirty; 0.5 s coalesced rebuild runs only while visible (and on open); connections cleaned on removing; no polling.
- `UI.OpenProfile(userId)`: `UI._invoke(Remotes.GetProfile, userId)` → `UI.Modal` with name, tier, totalGems (`Config.Cur`), bestRarity name/colour, indexPct bar, petsOwned, achTiers, cheersReceived, giftsGiven, zone, rank, Cheer + Gift buttons. `UI.OnCheerReceived(data)`: toast "👏 X cheered you!" with "Cheer back" → `UI.OnCheer(fromUserId, idx)`. Delete `pickGiftTarget` (79-126); the Shop's Gift card opens the Players panel with an info toast.
Acceptance: rows ≥56 px on touch; with 3 Studio clients the list updates within 1 s of a rebirth/equip/warp with zero timers running while the panel is closed (verify no Heartbeat/loop in the microprofiler); gifting never sends a userId the player did not tap; with an old server (no `GetProfile`) Profile shows one "Something went wrong" toast and the panel stays usable.

**UI-5 — Leaderboard tabs (Global / This server / Friends) with own rank inside Players**
- Tabs `Top Gems` / `Top Rebirths` call `UI._invoke(Remotes.GetLeaderboard, kind)` on open and at most once per 30 s per tab (client cache); render ≤50 pooled `SG.row`s (rank, name, `Config.Cur(value)` or `"🔄 N"`), highlight self, sticky footer `"You: #12 · 1.2M 💎"` or `"Top 50+ — keep cracking!"` + myValue; header pill `"Global · updated 1m ago"` when `global`, else `"This server"` with hint "Global boards appear once published"; `Friends` toggle filters rows via `LocalPlayer:IsFriendsWith(userId)` (pcall, cached per session), empty state "Add friends to see them here"; tapping an online player's row opens `UI.OpenProfile`.
Acceptance: Studio without DS renders session rows labelled "This server"; with DS ≤50 global rows + own-rank footer; an idle open tab issues ≤1 `GetLeaderboard` per 30 s per kind.

**UI-6 — HUD dynamics: server clock, chips, ServerGoal chip, Meteor co-op bar, objective tracker, zone line, churn fixes, CRACK cooldown**
- On every `UI.Update`: `clockOffset = snap.now - os.time()`; all countdowns use `serverNow = os.time() + clockOffset`. Chips (1030-1034; sized to `cardW`): Boost, Streak, `"🌟 GOLDEN HOUR 1:42"` (`snap.goldenUntil`), `"🎁 Server Luck +20% · 1:10"` (`snap.serverLuckUntil`), next-event chip `"☄️ Meteor in 4:10"` / `"🌤️ Golden Hour in 12:00"` showing the sooner of `nextMeteorAt`/`nextGoldenAt` when < 5 min, Grotto shards.
- ServerGoal chip under the buff chips (`UI.ServerGoal(data)`; `snap.serverGoalMine` for "you: N"): icon + label, bar, countdown from `endsAt`, pulses on completion, tap → toast with `rewardText`.
- Meteor (`UI.Meteor`, 1304-1324): `warning` = live 30→0 countdown from `t`; `active` = HP bar + "N helpers" + top-3 mini share bars from `shares` (names via `Players:GetPlayerByUserId`) + "You: X%"; `boom` = 4 s results card (own row highlighted, Cheer action on the MVP); `dead` = "Meteor sank — next in M:SS" from `nextAt` for 4 s; on touch the bar is a single 44 px row while `active`.
- HUD card: line 2 `"≈123 💎/s · ×1.5 income"`, line 3 `"Luck ×1.24 · Crack every 1.6 s"`, line 4 `"Rebirth 3 · ❄️ Frost Hollow ×3"` from `snap.rebirths` + `UI.SetZone(key)` (fallback: `Zone` attribute) + `Config.Zones.Get(key).multiplier`; touch card grows to 300×112. A 36 px "+" pill (buy role, ≥48 px hit wrapper) on the gem card opens the Shop.
- GoalCard (1178-1203) becomes the permanent tracker with the priority chain of §0 (onboarding → claimable reward → closest quest → rebirth ≥50 % → next achievement tier → next pet); tap opens the relevant panel; computed in the refresh path, not per frame.
- Churn: `refs.gems.Text` written only when the rounded value changes; dt-based lerp; chips rebuilt at 4 Hz and only on text change; per-panel dirty flags so `UI.Update` refreshes only visible panels (and on open) while rail glow/badge logic still runs every push.
- CRACK (1112-1163): `UI.CrackReadyAt()`; own `CrackFX` sets `crackReadyAt = os.clock() + snap.cooldown`, a press sets a 0.25 s provisional lock; hold loop spawned on `MouseButton1Down` and exited on Up/Leave, firing `CrackRequest` + `UI.OnCrackInput()` only when `os.clock() >= crackReadyAt` (poll 0.06 s); stroke tweens Cyan→Gold, a 4 px bar refills over the cooldown, Back-ease pulse when ready.
Acceptance: chip countdowns agree with the server within 1 s regardless of client clock skew; with 3 clients tapping, the Meteor bar shows helpers and shares; a 10 s CRACK hold sends ≤ `ceil(10/cooldown)+2` CrackRequests; steady-state UI Heartbeat ≤0.05 ms/frame; the tracker shows a daily quest after onboarding and opens Daily on tap; chips hide cleanly when the new snapshot fields are nil (old server).

**UI-7 — Panel content polish + copy pass (Gems everywhere, outcome toasts, names, Shop hygiene, Index, perks, Daily ladder)**
- Copy: `"GEMS & POWER-UPS"` (591); pet subs `"+N% Gems"` (865); collectible header `"Active bonus: +N% Gems"` (881); counts as pills `"Normal 0 · Golden 3 · Rainbow 0"`; `"Fuse 3 → Golden"` / `"Fuse 3 → Rainbow"`; `"🔒 Rebirth 5"` never `"🔒 R5"`; "Rebirth" is the noun with "Recrystallize" as flavour sub-text; `(x1 base)` hidden until ascensions > 0; outcome toasts (`"Power Lv 4 → crack every 1.5 s"`, `"Luck Lv 3 → ×1.24"`); panel titles match rail labels (`🏅 AWARDS`, `🐾 PETS`, `📖 INDEX`); the 45 s "2× Coins pass would've made that" toast (1292-1300) moves to a once-per-session line on the Shop's DoubleGems card as "2× Gems".
- Shop: skip `prod.zoneUnlock` or render a `ZONES` section with `✅ UNLOCKED` from `snap.zonesPurchased`; footer (595) → "Purchases support the game — thank you! 💜".
- Upgrades: perk cells (447) → full-width `SG.row`s with icon, name, `Config.Perks[i].desc`, button `"Unlock · 1 Shard"` or an "Owned" chip.
- Index: content starts at y ≥ 52 (620-624 currently hides under the strip); legend as a column-header row (⬜ ✨ 💟 🌟); rarity names `SG.text("Heading")` capped 18 px; per-zone completion (644-646) as five labelled mini bars.
- Daily: past days GreenDim with ✓, today `TodayFill`, future dimmed; "Day N" via Caption role (≥12 px); hint "Miss a day and the streak restarts".
Acceptance: `grep -i coin src/client/CrackAGeodeClient/UI.luau` returns nothing; no "R5"-style abbreviation remains; the four "Unlock …" cards no longer appear under power-ups; perk descriptions are visible before spending; Index header and legend fully visible at 812×375.

**UI-8 — Settings panel**
- Panel `Settings` ("⚙️ SETTINGS"): Music and SFX sliders 0..100 (48 px thumb, drag via InputBegan/InputChanged on the track, ±10 step buttons ≥48 px), toggles Reduce FX / Social pings / Hide activity feed, Reset, read-only "Device: Touch/Desktop · Quality tier N". Initial values from `snap.settings` (GetState) merged over `Config.Social.SettingsDefault`; `UI.GetSettings()`.
- On change: `UI.OnSettingsChanged(settings)` immediately, then `Remotes.SetSettings:FireServer(settings)` debounced 2 s trailing (matches the server gap); the first GetState seeds the panel and calls `OnSettingsChanged` once.
Acceptance: dragging Music changes the playlist volume within a frame with no server round-trip; toggling Reduce FX at runtime stops screen shake and cheer bursts without rejoin; settings survive a rejoin when DataStores are usable; with an old server (no `SetSettings`) the panel still opens and applies for the session.

### 4.4 clientModules (new modules + every non-UI client file)

**CM-1 — Quality as the single device/quality/settings bus; Audio module; Orbit cull; Signposts throttle + exclusion**
Files: `Quality.luau`, new `Audio.luau`, `Orbit.luau`, `Signposts.luau`, `Effects.luau`.
- Quality (§3.10): flags at require time; `ApplySettings` validates, stores, fires `Changed`; `Init` keeps the mobile lighting tune (no longer returns early before the flag setup).
- Audio: `Init` finds `SoundService.GeodeMusic/GeodeSFX` (`FindFirstChild`, then `WaitForChild(name, 3)`, then create local fallbacks); moves the playlist out of `Effects.startMusic` (Sound.Volume 1, group volume = music/100, default 22); `Play` creates SFX in GeodeSFX; `Effects.playLocal` and the PickaxeFX whoosh route through it.
- Orbit: `Init(Config, Quality)`; loop on Heartbeat; >120 studs parked once; 40-120 studs at 15 Hz; missing character parked once (not rewritten per frame); `MAX_ORBIT` 4/6/12 by tier with a total animated-part cap 24/48; rebuild on `Quality.Changed`.
- Signposts: `Init(Quality)`; cache label lists at `track()` (no `GetDescendants` per frame); 20 Hz loop (10 Hz beyond 0.55·MaxDistance); early-out on `dist > MaxDistance`; write transparency only on >0.02 change; skip any BillboardGui with attribute `Signpost == false`; `EDGE_TOP = GuiService:GetGuiInset().Y + 8`.
Acceptance: toggling Reduce FX changes the orbit part cap live; Signposts ≤0.15 ms/frame with 25 entries; Orbit ≤0.1 ms with 30 players at spawn (microprofiler); music volume follows `Quality.Settings.music`; a server Sound with `SoundGroup=GeodeSFX` is attenuated by the SFX slider.

**CM-2 — Nameplates module + rebirth/ascension chat tags**
Files: new `Nameplates.luau`, `init.client.luau`.
- For every other player (and own, hidden by default) one BillboardGui `Nameplate` on Head (`Size (4.2,0,1.1,0)`, `StudsOffset (0,2.1,0)`, `AlwaysOnTop=false`, `MaxDistance` 45/70/100 by tier, attribute `Signpost=false`) with a Bg1 pill: line 1 `"{👑 }{DisplayName} · R{Rebirths}{ · A{Ascensions}}"` coloured by `SG.Tier`, `⭐` when Premium, `Title` when non-empty; line 2 `"{PetEmoji} {PetName}"` (hidden when empty). `Humanoid.DisplayDistanceType = None`; hides any legacy `VIPTag`. Rebuilt only from ONE `player.AttributeChanged` connection per player and `CharacterAdded` — zero per-frame Luau. Tapping the plate (TextButton) → `Nameplates.OnTap(userId)`.
- Chat tags in init.client `OnIncomingMessage`: prefix `[R12]` (colour `SG.TierHex`) or `[A2]` before the existing gold `[VIP]`; numbers only.
Acceptance: two Studio clients read each other's `👑 Name · R12` / `🐉 Emerald Drake` and see it change within 1 s of rebirth/equip; the microprofiler shows no Nameplates work between attribute changes; Signposts never tracks a nameplate; a player with no pet shows no pet line; old server (no attributes) → name only.

**CM-3 — PetView: attribute-driven pets visible to everyone**
Files: `PetView.luau`, `init.client.luau`.
- Same file, evolved: the golem builder (template under `ReplicatedStorage.PetModels` or the procedural crystal golem) is keyed by `{name, emoji, color}`; models parent to a client-created `workspace.GeodePets` folder. For every Player watch `PetName/PetEmoji/PetColor` (via `AttributeChanged`) and rebuild that player's golem on change (destroy when `PetName == ""`). Local player keeps the current RenderStepped hover/bob (PointLight, particles, name billboard MaxDistance 60, `Signpost=false`); `PetView.Set(active)` remains for immediate local feedback. Others: one Heartbeat connection with a 15 Hz accumulator; each tick pick the nearest N characters within 100 studs (N = 4/8/12 by tier), lerp their golem origins with the same bob, park everything else (parent nil); no PointLight for others; particle rate 0 beyond 40 studs; name billboard MaxDistance 40. Cleanup on `PlayerRemoving`. Rebuild caps on `Quality.Changed`.
Acceptance: two Studio clients see each other's pet with tag; equipping a different pet swaps it on the other client within 1 s; no RenderStepped work for non-local pets; non-local animated parts ≤ N×13; a client whose server sends no attributes still renders its own pet from the snapshot.

**CM-4 — Feed module (persistent activity column, seeded from GetState, chat mirror)**
Files: new `Feed.luau`, `init.client.luau`.
- ScreenGui `GeodeFeed` (DisplayOrder 9, ResetOnSpawn false). `Push(data)` records payloads whose `KindRoute` is `feed` or `headline` (ignores `personal`); `PushCheer({fromUserId,toUserId,idx})` builds "👏 A cheered B"; `Seed(list)` from `snap.feed`; 30-entry ring `{kind,text,colorRGB,userId,t}`; `OnTapUser(userId)` for rows with a userId.
- Rendering: dirty flag + 0.5 s coalescing rebuild; desktop = bottom-left column (anchor (0,1) at (12,-12)) of 3/5/6 rows by tier, `SG.text("Body")` rows on Bg1 pills, fading after 20 s; touch = directly under the HUD stack at `GeodeHUD.LeftStackBottom + 8`, showing as many rows as fit above `H-170` (usually 0-2), otherwise a single `"📣 3 new"` pill; tapping the pill/column opens a 30-row scroll overlay (ZIndex 30, tap-outside closes). Hidden while `GeodeHUD.PanelOpen` or `Quality.Settings.hideFeed` (listens to `GetAttributeChangedSignal` / `Quality.Changed`). Each accepted row is mirrored to `TextChatService.TextChannels.RBXSystem:DisplaySystemMessage(text)` in pcall.
Acceptance: a joiner sees the last ≤30 server events immediately; 20 events in one second cause ≤2 rebuilds; the column never overlaps the CRACK button, joystick, HUD stack or side menu at 812×375 and 568×320; nothing runs per frame; `personal` payloads never appear in the feed.

**CM-5 — SocialFX: cheer reactions over players**
Files: new `SocialFX.luau`, `init.client.luau`.
- `Send(targetUserId, idx)`: client debounce `Config.Social.CheerGap`, then `Remotes.Cheer:FireServer(targetUserId, idx)` (never self-target). `OnCheer(data)`: skip when `Quality.ReduceFX`, `socialPings == false`, sender in the blocked list (`StarterGui:GetCore("GetBlockedUserIds")` or `LocalPlayer:GetBlockedUserIdsAsync` in pcall, cached at init), or target character > 120 studs away; else take one of 8 pooled BillboardGuis (`Signpost=false`), parent to the target Head above the nameplate, show `Config.Social.Reactions[idx]` with a 1.6 s pop-rise-fade (`SG.Motion.pop`), `Emit(12)` on a pooled ParticleEmitter at the target HRP; when the target is the local player, a brief screen sparkle (no shake). `SetEnabled(bool)`.
Acceptance: 20 simultaneous cheers never allocate beyond the pool; nothing renders under Reduce FX or with Social pings off; a cheer from a blocked user is invisible; a self-cheer never leaves the client.

**CM-6 — init.client wiring + client fixes (GetState retry, single swing owner, cooldown-gated swings, FX layering, distance-scaled Meteor FX, RegionFX hook, NexusFX copy)**
Files: `init.client.luau`, `Effects.luau`, `PickaxeFX.luau`, `RegionFX.luau`, `NexusFX.luau`.
- init.client exactly as §3.11.
- Effects: delete `swing`/`watchPickaxe` animation (23-62) and the `task.spawn(swing)` at Effects.Crack (keep `Tool.Activated → CrackRequest`); fix the stale header comment; split the ScreenGui into `GeodeFXWorld` (5: floating text, skipped while `GeodeHUD.PanelOpen`) and `GeodeFXOverlay` (50: flashes); `ApplyReduceFX` disables shake/flash/fovPunch; `Effects.Meteor` scales shake/flash by HRP distance to the crater (full <60 studs, zero >150) and shows `UI.Toast("☄️ Meteor at the crater — warp home","info")` once per cycle when far; all local sounds through `Audio.Play`.
- PickaxeFX: single `RightGrip` weld owner; `SetCooldownSource(fn)`; `startSwing` for the local character early-returns while `os.clock() < fn()` so the hold loop and clicks play at most one swing + whoosh per real crack.
- RegionFX: `OnChanged(key)` hook fired from `Set` and the 0.25 s loop on key change.
- NexusFX: `"×N Coins"` → `"×N Gems"`; `"💰 2× Coins"` → `"💰 2× Gems"`; `"💎 Unlock now"` → `"🛒 Unlock now · R$ N"` with role `premium`; toasts via `UI.Toast(text, "ok"|"err")`; header comment fixed.
Acceptance: a client whose first GetState returns nil still receives rings, feed and settings within 3 s; one CRACK press produces one swing and one whoosh per cooldown; floating "+N 💎" text never draws over an open panel; a player in Astral Void gets no white-out from the Meteor; `grep -i coin src/client` returns nothing; with an older server (no new remotes) the client boots with zero errors and warns once per missing remote.

---

## 5. Sequencing, checkpoints and compatibility rules

**Phase 0 — contract freeze (½ day, serial):** SH-1, SH-2, and the SV-1 *shell* (five Remote instances, two SoundGroups, `S.Guard`/`S.IsUserId`, Init-order entries guarded for missing modules). One commit; then the three implementation owners branch and never touch each other's files.

**Phase 1 — foundations (parallel):**
- server: SV-1 (Guard on every handler + validation fixes) → SV-2 (Social core + Announce migration) → SV-7 (hardening, first-run gating, OrbitSync on load, TestHook) → SV-8 (copy).
- clientUI: UI-1 → UI-2 → UI-3 → UI-7. These fix the first-minute findings without any server change.
- clientModules: CM-1 (Quality/Audio/Orbit/Signposts) → CM-6 (init.client wiring, swing owner, layering, retry) → CM-2 (Nameplates + chat tags).

**Checkpoint A** (two Studio clients + one stale build pairing): every panel closes via ×/scrim/Escape/B; balance visible in every panel; Rebirth needs a confirm; every panel/rail TextButton ≥48 px at 812×375 touch; plates show R/pet; feed rows arrive from live Announces; personal onboarding/pet/ach messages toast; `grep -rni coin src` clean except internal keys/comments; deleting PickaxeTemplate still boots; late joiner's ring visible; TestHook works; zero errors in Output. Pair old client + new server AND new client + old server: zero errors.

**Phase 2 — social spine (parallel):**
- server: SV-3 (Cheer/GetProfile/SetSettings, join/leave/zoneFirst, gift notice) → SV-5 (ServerGoals) → SV-6 (Meteor batching, timers) → SV-4 (OrderedDataStore boards).
- clientUI: UI-4 (Players panel) → UI-6 (HUD dynamics) → UI-5 (leaderboard tabs) → UI-8 (Settings).
- clientModules: CM-4 (Feed) → CM-5 (SocialFX) → CM-3 (PetView replicated pets; last because it is the most expensive to test).

**Checkpoint B** (three Studio clients): cheer shows over the target and in the feed with limits honoured (7th in 30 s dropped); goal chip advances and completes into a server-luck chip on all clients (TestHook `goalComplete`); Meteor bar shows helpers/shares at ≤4 events/s; Players panel gifts only the tapped player; leaderboard shows "This server" in Studio; pets visible cross-client within 1 s of equip; Music/SFX sliders attenuate client and server sounds; chips count down on server time; performance budgets (§6) verified in the microprofiler.

**Merge order at each phase:** server first (remotes/attributes exist before consumers), clientModules second (init.client wiring), clientUI last.

**Disjointness rules:** callbacks (`UI.OnCheer`, `UI.OnSettingsChanged`, `Nameplates.OnTap`, `Feed.OnTapUser`, `RegionFX.OnChanged`, `PickaxeFX.SetCooldownSource`) are assigned only in init.client; UI.luau never requires a new client module (Quality arrives via `deps`); Feed/Effects read UI layout only through the four `GeodeHUD` attributes; all server broadcasters call `Social.*` after SV-2 and never `Remotes.Announce` directly; snapshot additions are appended, never renamed; `EquipPet` keeps its index argument.

---

## 6. Degrade rules and performance invariants

**DataStores unusable (Studio, unpublished):** exactly one `[Data] DataStores unavailable` warning; `GetLeaderboard` returns `global=false` + session rows and the physical boards say `THIS SERVER`; settings, cheer/gift counters and `zonesVisited` are session-only; presence, feed, cheers, goals, Meteor and every panel (including Players and Settings) work unchanged; zero errors. `ProcessReceipt` behaviour is unchanged (never acknowledges without a durable save).

**Partial landing matrix:** server item not landed → attributes nil (plates/rows show names only), remotes missing (client warns once and skips wiring; `_invoke` shows one "Something went wrong" toast when a panel action needs them), snapshot fields nil (chips hidden, tracker falls back to onboarding/quests). Client item not landed → server broadcasts are harmless; legacy `UI.Banner` shows them as before because every payload still carries `text` and `kind`.

**Performance invariants (verified at Checkpoint B):** no new RenderStepped work for other players (plates event-driven; other pets nearest-N on Heartbeat 15 Hz; Orbit on Heartbeat with cull; Signposts 20 Hz with cached labels; Feed and Players panel rebuild on events with 0.5 s coalescing); UI Heartbeat ≤0.05 ms steady; server fan-out per kind token-bucketed; `MeteorState` ≤4/s; `ServerGoal` ≤1/s; `SyncPresence` is 7 compares per Push; OrderedDataStore traffic ≤ N writes/60 s + 2 reads/75 s per server.

---

## 7. Currency naming decision

**Decision: the currency is "Gems" with the 💎 icon, everywhere a player can read it.** "Coins"/"Coin" never appears in player-facing text. Rules:
1. Amounts use `Config.Cur(n)` (→ `"12.3K 💎"`); existing `Config.Fmt(n) .. " 💎"` patterns are equivalent and may stay.
2. "Gems" is a proper noun (capital G) in prose: "2× Gems", "+15% Gems", "Gem Pouch", "Daily Gem bonus", "DOUBLE all Gem income".
3. Internal identifiers are NOT renamed: pass key `DoubleGems`, product keys `CoinsSmall|CoinsMedium|CoinsLarge`, the `coins =` field, `Monetize.GrantProduct`'s branch, receipts.
4. Acceptance across the repo: `grep -rni coin src` hits only those identifiers, `item.coins`, and code comments.

Where each owner applies it: **shared** (SH-2) — Config.luau:16, 19, 29 (comment), 30-32, 36, 138; **server** (SV-8) — Monetize.luau:139, 149; Buffs.luau:57 (comment), 60; **clientUI** (UI-7) — UI.luau:591, 865, 881, 1292-1299; **clientModules** (CM-6) — NexusFX.luau:3 (comment), 57, 90 (comment), 115.

---

## 8. Studio playtest plan (after Checkpoint B; Test → Local Server with 3 players, plus one solo Play at 812×375 device emulation)

| # | Do | Expect |
|---|---|---|
| 1 | Start the 3-player local server; open Output | Exactly one `[Data] DataStores unavailable` warning, zero errors, "Server started" line, no "TestHook" errors |
| 2 | On client A open each rail button in turn (Daily, Pets, Shop, Upgrades, Index, Awards, Garden, Players, Settings) | One panel at a time; balance strip "You have N 💎" in every title strip; every button ≥48 px in the device emulator; Garden shows 🌱 with a "0" badge and is disabled |
| 3 | With Upgrades open press Escape, then reopen and tap the dark scrim, then × | All three close it; the rail returns to its resting spot; the CRACK button reappears |
| 4 | TestHook `addGems 50000`, tap Rebirth | Confirm modal listing resets/gains; Cancel does nothing; Confirm (hold on touch) rebirths; toast "Power Lv…"-style outcome copy elsewhere; B and C see A's nameplate flip to `R1` and a feed row "🔄 A Recrystallized!" |
| 5 | On A equip Rock Sprite in Pets | A's golem appears for A immediately and for B/C within 1 s with the "🪨 Rock Sprite" tag; A's nameplate line 2 updates |
| 6 | On B open Players → Online, tap 👏 on A's row, pick 🔥 | 🔥 pops over A's head on all clients; A gets "👏 B cheered you!" with "Cheer back"; feed row "👏 B cheered A"; B's strip is disabled for 2 s; spam 7 taps → only the allowed ones fire, no toasts |
| 7 | On B tap 👤 Profile on A | Modal with tier, total Gems, best crystal, index %, pets, awards, cheers, zone, rank; no gems balance field |
| 8 | On C tap 🎁 Gift on A (Studio test mode) | Confirm modal names A; A gets "🎁 C gifted you…" with "Thank 💜"; everyone gets the server-luck chip and a feed row; C's `giftsGiven` = 1 (TestHook `profile`) |
| 9 | TestHook `goal 140`, then crack 10+ geodes across clients | Goal chip advances on all clients at ≤1 update/s; "you: N" differs per client; TestHook `goalComplete` → completion banner, server-luck chip appears on every client, `p.gems` unchanged |
| 10 | Set `workspace:SetAttribute("MeteorInterval", 40)`, wait for the warning, then all three clients tap the meteor | Chip "☄️ Meteor in 0:30" counts down; bar shows the 30→0 warning; during `active` the bar shows "3 helpers", share bars and "You: X%"; MeteorState ≤4/s (TestHook `meteorState`); results card after the boom with Cheer on the MVP |
| 11 | On A open Players → Top Gems | Rows labelled "This server"; footer "You: #k"; Friends toggle shows the empty state |
| 12 | On A open Settings, drag Music to 0, toggle Reduce FX | Music mutes instantly; cheer bursts and Meteor shake stop; rejoin (live only) restores values |
| 13 | On A warp to Frost Hollow via the Nexus | HUD line "Rebirth N · ❄️ Frost Hollow ×3"; feed row "❄️ A reached Frost Hollow for the first time!"; B/C see A's Zone in the Players panel within 1 s; toast "❄️ Welcome to Frost Hollow!" |
| 14 | Delete `ServerStorage.PickaxeTemplate`, restart | One warning, server still ready, HUD works |
| 15 | Fresh profile (TestHook `profile` shows `cracks 0`): join | No Daily panel auto-opens; Daily rail button glows only after the first crack; Starter toast arrives after step 2 |
| 16 | Hold CRACK for 10 s next to a node (touch emulator) | ≤ `ceil(10/cooldown)+2` requests (count `CrackFX` events); one swing + whoosh per crack; cooldown ring refills |
| 17 | Microprofiler idle at spawn with 3 players | UI Heartbeat ≤0.05 ms; no Nameplates/Feed frames between events; Orbit/Signposts within budget |
| 18 | Pair a stale client build with the new server (and vice versa) | Zero errors; missing features simply dark; legacy Announce still banners |

---

## 9. Open questions for the human

1. **DailyPopup behaviour for returning players:** this plan never auto-opens the Daily panel (glow + "Open" toast). Do you want returning players (not first session) to still get the auto-open?
2. **Server-goal tuning:** base goals 500/10/3 with online scaling, a 15 min window and 60 s rest — acceptable luck uptime? (Worst case on a busy server: one +10 % luck buff per ~3 min.)
3. **Leaderboard identity:** offline players on the global boards show their username (`GetNameFromUserIdAsync`), not DisplayName. OK, or should we persist DisplayName in a companion key (extra DataStore traffic)?
4. **"Gifter" title threshold (3 gifts) and whether more cosmetic titles are wanted** (e.g. "Pioneer" for first Astral visit).
5. **Rail layout on touch:** 3×3 grid top-right (9 buttons) changes muscle memory from today's vertical-centre 2×4. Confirm.
6. **UI.luau growth:** may the clientUI owner convert `UI.luau` into a Rojo folder-module (`UI/init.luau` + `UI/Panels*.luau`) if it passes ~2,500 lines? Ownership does not change.
7. **Music default:** 22 (matches today's 0.22). Confirm you do not want louder music by default.
8. **Golden bystander hint** (tap another player's Golden Geode → "cheer them on") — keep or drop? Low value, one extra rate-limited FireClient path.
9. **Store art / icons:** `players`, `board`, `sprout` icons use emoji fallbacks. Upload real icons later or keep emoji?
10. **Voice/party/teleport features** were excluded; confirm nothing there is expected in this pass.
