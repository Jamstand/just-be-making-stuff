# Ideas backlog — Crack a Geode!

## How to use this file

- The weekly agent reads this before choosing work. It may only pick **Tier A** items; **Tier B** items
  it turns into proposals (with a paste-ready prompt) in its weekly report.
- The agent ticks items off in its PR (`[x] ... — PR YYYY-MM-DD`) and adds new ones with a one-line rationale.
- **Josh:** add anything in plain English under the right tier (or under "Unsorted" if unsure — the agent
  will sort it and explain). Tick/untick freely; a ticked item is never retried. To say "never do this",
  move it to "Rejected" with a short reason.
- Each item: what, where (file), why it matters. Numbers/IDs/prices are always Tier B.
- Last re-checked against the code: Josh's Studio export, commit 85ee357 on the game branch (2026-09-23).

## Tier A — agent may fix

- [ ] **GiftBoost: the chosen recipient is forgotten by any other receipt.** `Monetize.ProcessReceipt` passes
      `giftTarget[player]` to `GrantProduct` and then clears it for EVERY product, not only GiftBoost. If another
      receipt for the same buyer is processed between the GiftBoost prompt and its receipt, the recipient is lost
      and the gift falls back to the first other player. Fix: read and clear `giftTarget` only when
      `key == "GiftBoost"`. Keep the receipt idempotent. *Why:* the buyer picked a player in the Shop's recipient
      list; the gift should go to that player.
- [ ] **`Pickaxe.Refresh` rebuilds the tool on every Power purchase.** Since the 2026-09-23 export, `Econ.Buy`
      ("Power") calls `S.Pickaxe.Refresh`, which always destroys the pickaxe, clones a new one and equips it, even
      though the tier only changes at a few Power levels (`TIERS` in `Pickaxe.luau`). So every upgrade click swaps
      the tool for an identical copy and force-equips it (even if the player had put it away). Fix: skip the
      rebuild when the player's current `Pickaxe` (Backpack or character) already has this tier (e.g. compare its
      `ToolTip`). *Why:* putting the tool away is undone on every upgrade click, and it is needless server work.
- [ ] **Receipts list capped at 50 (`ProcessReceipt` in `Monetize.luau`).** A heavy buyer with >50 products could
      see an evicted `PurchaseId` re-delivered and granted twice. Defensive fix: raise the cap (e.g. 200; a receipt
      id is ~36 chars, well within DataStore limits); it already drops the oldest id first. *Why:* double grants =
      free items.
- [ ] **Dead code / unused locals (lint noise).** `UI.luau` `makePanel` is never called (every panel uses
      `makeScrollPanel`; the export edited `makePanel`, but nothing calls it); unused locals `Players`
      (`Pets.luau`), `Config` (`Stations.luau`, set in `Init`, never read), `state` (`init.client.luau`, set, never
      read); 6 same-line statements (luau-lsp `SameLineStatement`: `Achievements` 1, `Econ` 2, `Monetize` 2,
      `UI` 1). Remove/split them; baseline shrinks. *Why:* less noise = real problems stand out.
- [ ] **Type-checker noise, small and behaviour-neutral only.** `Zones.luau` registry entries lack optional
      fields `isHub` / `prebuilt` in the shared zone type (add them as optional; 4 of the file's 11 findings);
      `Config.luau` strict mismatches (10); `StyleGuide.luau` (74; luau-lsp prints each of its 37 twice) types
      `Instance` too loosely for `MouseButton1Down`, `Visible`, `Scale`, `Enabled`, `ZIndex` etc. (narrow to the
      real class — `GuiButton`, `GuiObject`, `UIScale`, `UIStroke` — where safe), and since the export the type
      checker reads the Bloom/ColorCorrection/DepthOfField effects in its `applyLighting` as `Atmosphere`. In
      `UI.luau` the optional last arguments of `SG.icon` / `SG.gloss` / `SG.close` show up as "Argument count
      mismatch". *Why:* ratchet the baseline down. Skip anything that changes runtime.
- [ ] **`README.md` is stale.** Its Monetization paragraph still says the IDs are placeholders (`0`); they are
      real since commit 608c288 (and `init.server.luau` now warns at startup if any id is `0`). Its layout block also
      lacks the new client modules `PickaxeFX.luau` and `Signposts.luau`, calls the style "Neon Geode"
      (`StyleGuide.Name` is now "Geode Depths") and calls `Pickaxe.luau` rebirth-tier (tiers now follow Power). Fix
      the text only. *Why:* a future session might "restore" zeros.
- [ ] **Remote audit — gaps left after the export.** Pattern to copy: `Purchase` in `Monetize.luau` (`S.Ready`
      gate, `type()` checks on all arguments, per-player debounce cleared on `PlayerRemoving`). Missing today:
      `ClaimDaily` (`Dailies.Init`) — no `S.Ready` gate, no debounce; `EquipPet` (`Pets.Init`) — no `S.Ready` gate,
      no debounce (the `type()` check is inside `Pets.Equip`, but a non-whole number such as `1.5` gets past it
      and errors in `tierUnlocked`); `FusePet` (`CollectPets.Init`) and `ClaimAchievement` (`Achievements.Init`)
      — no debounce; `CrackRequest` (`Geodes.Init`) — no `S.Ready` gate (`TryCrack` re-checks range, cooldown and
      zone unlock). Already complete: `Purchase`, `Buy`, `GetState`, `HarvestGarden`. Add what is missing,
      nothing more. *Why:* remotes are the attack surface.
- [ ] **`Signposts.luau` never forgets a sign.** `track` adds every BillboardGui that appears under
      `workspace.CrackAGeode` or the camera (Golden Geodes, the onboarding starter geode, the pet's name tag each
      time the pet changes), and nothing removes them: a destroyed sign stays in `tracked` and its screen-edge pill
      label is never destroyed. The `RenderStepped` loop also calls `bb:GetDescendants()` for every on-screen sign
      every frame. Fix: drop the entry and destroy its pill once `bb.Parent` is nil; collect each sign's labels
      once in `track`. *Why:* per-frame work that only grows during a long mobile session.

## Tier B — propose only (needs Josh / Studio)

- [ ] **Mobile UI: remaining small touch targets + safe-area check.** The export already moved a lot: on touch the
      side menu is a 2-column grid of 62×56 px icon buttons (a `UIScale` shrinks it on short screens, down to 55%),
      panels sit beside the menu (on narrow screens the menu slides away while a panel is open), the HUD cards
      stack in one `LeftStack`, and `Signposts.luau` stops world labels being cut off at the screen edge. Still
      under 44 px on touch: the panel close buttons (40 px), the gift picker's Cancel (38 px) and the 40 px-tall
      Starter Pack / pet Equip / Fuse buttons; scroll panels can also shrink to 85%, and the side menu at 55% makes
      its buttons about 34×31 px. `UI.luau` never sets the notch/safe-area settings `ScreenInsets` /
      `SafeAreaCompatibility` (it relies on Roblox's defaults). Needs a phone or the Studio device emulator.
      *Why:* most Roblox players are on phones; unreachable buttons = churn.
- [ ] **Pickaxe: two swing animations now overlap.** `Effects.luau` still hooks the tool's `Activated` to its old
      swing (`swingAndCrack` → `swing`, which tweens `Tool.Grip`, the hand-hold offset, and waits ~0.11 s before
      firing `CrackRequest`), while the new `PickaxeFX.luau` rewrites the hand joint (`RightGrip` weld `C1`) every
      frame. `swing` also keeps the FIRST tool's grip for the whole session, but `Pickaxe.Refresh` now scales
      `tool.Grip` per tier. Check in Studio which swing should stay (keep the `CrackRequest` call either way: with
      the pickaxe out, that is how a click cracks). Needs playtesting. *Why:* the core loop must feel good in the
      first 30 seconds.
- [ ] **GiftBoost: what if the chosen recipient left before the receipt arrives?** Today `GrantProduct` falls back to
      the first other player, then to the buyer (the Shop refuses to open the prompt when nobody else is in the
      server). Options: keep that, or always boost the buyer instead; the purchase is already paid by then
      (`NotProcessedYet` is NOT a refund). Josh's call. *Why:* monetization behaviour.
- [ ] **`ProcessReceipt` order changed in the export — confirm the rule.** It now saves the receipt id first
      (`SaveNow`), then grants, then only queues a later save of the grant (`SaveSoon`, a few seconds later) before
      returning `PurchaseGranted`. That removes the old double grant after a failed save, but if the server crashes
      before that later save, or `GrantProduct` errors (the retry then sees the saved receipt and skips the grant),
      the paid item is lost. `CLAUDE.md` rule 5 describes the current order and flags this. Josh decides which order
      is the rule; then the code follows. *Why:* paid items.
- [ ] **Zone drop tables: Void Opal ignores its zone weight.** Since the export `Econ.RollRarity` looks up a zone's
      `dropTable` by `r.name`, but `Zones.luau` keys the tables by rarity `key`. They match for every rarity except
      Void Opal (name "Void Opal", key `VoidOpal`), so every zone still rolls Void Opal at the global weight 0.05
      instead of 0.5–3 in the unlockable zones. The fix is one word (`r.key`), but it changes the odds of the most
      valuable find. Josh's call. *Why:* the deeper biomes promise better odds.
- [x] **Export the current Studio place into `src/`** — done: Josh's Studio export, commit 85ee357 (2026-09-23).
- [x] **DataStore schema policy** (should `fromStored` keep unknown keys?) — decided in that export: it now keeps
      them (see the comment in `fromStored`, `Data.luau`).

- [ ] **Economy / balance pass** (drop rates, pity, rebirth multipliers, `Balance` table, zone prices, starter
      pack contents). Always Josh. *Why:* revenue and retention levers.
- [ ] **New monetized features** (e.g. pet slots, cosmetic pickaxes). Always Josh; the agent may only sketch
      a design with retention/monetization reasoning in "Ideas".
- [ ] **Studio-built world objects the code assumes** (`workspace.CrackAGeode.FX/Nodes/Map/Gardens`,
      `ServerStorage.PickaxeTemplate`; new in the export, with a code fallback:
      `ReplicatedStorage.GeodeMeshes.GeodeShell`, `ReplicatedStorage.PetModels.<pet name>`; referenced by name: the
      MaterialVariant `GeodeRockPBR`): document them or add a startup check that warns when one is missing. The
      Lighting effects no longer have to exist: `StyleGuide.applyLighting` (run at server start) creates
      `GeodeAtmosphere` / `GeodeBloom` / `GeodeColor` / `GeodeDoF` when missing. The warning code is Tier A;
      deciding what to build is Tier B.

## Unsorted (Josh writes here)

- (empty)

## Rejected (do not retry)

- Introducing StyLua or any formatter — would rewrite all 32 files and break hand-aligned tables.
- Adding `--!strict` to non-strict files "for quality" — 1,000+ new findings, no runtime benefit.

## Done

- (the agent moves ticked items here when the PR is merged, keeping the PR date)
- [x] **Export the current Studio place into `src/`** — done by Josh, commit 85ee357 on the game branch (2026-09-23):
      it changed 30 files in `src/` (28 edited, 2 new: the client modules `PickaxeFX.luau` and `Signposts.luau`).
      The lint baseline was regenerated against it.
- [x] **GiftBoost target is ignored server-side** — fixed in the export (85ee357): the Shop opens a recipient picker
      (`pickGiftTarget` in `UI.luau`), the `Purchase` handler checks the target and stores it in `giftTarget`, and
      `ProcessReceipt` passes it to `GrantProduct`, which looks the player up again.
- [x] **`Data.fromStored` drops unknown keys / DataStore schema policy** — decided in the export (85ee357):
      `fromStored` now keeps unknown keys; only `NON_PERSISTED` ones (`testPasses`) are skipped. New fields still
      need a `DEFAULT` entry so older profiles get a value.
- [x] **Pickaxe feel pass** — done in the export (85ee357): new `PickaxeFX.luau` swings the pickaxe the instant you
      press CRACK or click a geode, plays a whoosh, nudges the camera when the server confirms the crack, adds an
      idle sway, animates other players' swings and outlines the nearest crackable geode in gold. `Pickaxe.luau`
      tiers now follow Power (glow, sparkles, a small size step).
- [x] **`BindToClose` / save-on-leave sanity** — nothing to add (checked 2026-09-24 against 85ee357): `retry` in
      `Data.luau` waits longer after each failed try (the wait doubles, capped at about 4 s; 5 tries, 2 during
      shutdown), each failed save or release `warn`s with the player's user id, and `BindToClose` stops waiting
      after 25 s.
