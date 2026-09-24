# Playability plan — Crack a Geode!

Audited 2026-09-24 against the game branch at commit 9c983c6 (32 Luau files). Seven auditors read the code the
way a player would experience it (first 5 minutes, tap feel, pacing, phone UI, things that break, performance,
clarity). A second reviewer re-checked every finding against the code: 61 findings kept (9 block play, 30 hurt it,
22 polish), 0 refuted. Nothing here was playtested — every prompt tells your local Claude to check the current
Studio version first, because your newer social-feature work is not in this commit.

## How to use this

0. **First, commit your social-feature work** (Audio, Feed, Nameplates, SocialFX, Social, ServerGoals and the UI
   edits) so every prompt below starts from a clean folder.
1. Paste **Prompt 1 → 2 → 3 → 4** into your local Claude, one per session, in order. Playtest in Studio after
   each, then Publish.
2. The **Your decisions** section is economy/design: pick an option, paste its one-line prompt. Do these after
   Prompt 2, one change at a time.
3. Do the **10-minute playtest checklist** yourself after Prompt 3.

Shortcut: instead of copying a prompt, you can tell your local Claude:
`Fetch origin, read docs/PLAYABILITY_PLAN.md from origin/claude/roblox-studio-mcp-sx9h7d, and do Prompt 1 exactly.`

## The short version

- **The game's first instruction doesn't work.** The pickaxe is equipped automatically when you spawn, and while it's in hand, tapping objects in the world does nothing. So the glowing "TAP TO CRACK!" starter geode, the Meteor event, paid Golden Geodes and the Upgrades pedestal all ignore taps. Fix this first.
- **Too many things fail with no message.** A save that won't load, a tap that doesn't count, a locked zone, a zone that just opened: in each case nothing tells the player. They can't tell "broken" from "working", and that's when people quit.
- **Two buying paths are broken, and one server error can switch off a paid feature.** The Warp Nexus buy buttons can't be tapped. The Shop takes Robux for zones the player already has. One unlucky error stops Auto-Crack for everyone on that server.
- **The first minute is cluttered and cramped on phones.** The Daily panel pops up over the tutorial. On phones every panel shrinks to 85%, so buttons end up 34–39 px tall (the rule is at least 44). The longest goal text is about 7 px.
- **The economy runs out in one session.** A free player can Ascend at 7–12 minutes and has seen almost everything by about 35. From minute 10, rewards are worth under 2 seconds of play. These are your numbers to decide.
- **Busy servers will lag on phones**, because every crack's effects are built on the server and sent to every player.

All of this comes from reading the code at commit 9c983c6. Nothing was playtested, so every prompt starts by checking your current Studio version.

## Top 12, in order

1. **The pickaxe blocks the starter geode, the Meteor, Golden Geodes and the pedestal.** A new player taps the glowing "TAP TO CRACK!" geode and gets only a swing and a whoosh. Nobody holding the pickaxe can damage the Meteor, and a paid Golden Geode only opens by itself after 5 minutes. Effort M.
2. **Buying a zone unlock is broken both ways.** The "Unlock now", "2× Coins" and "Lucky" buttons on the Warp Nexus cards do nothing on any device. Meanwhile the Shop still sells an unlock to a player who already has that zone, and keeps their Robux. Effort S.
3. **Save problems are invisible.** A returning player who hits a save hiccup sees 0 Coins, with no "loading" message, for up to 2 minutes. If loading fails, they silently play a fresh profile that never saves. Effort M.
4. **One unlucky error switches Auto-Crack off for the whole server.** If a player leaves while their game-pass check is still running, the Auto-Crack loop crashes, and nobody on that server gets Auto-Crack until the server shuts down. Effort S.
5. **The Daily panel and a Starter Pack toast cover the tutorial in the first 3 seconds.** A brand-new player's first sight is a login-reward panel that hides the CRACK button and the goal card. Effort S.
6. **Buttons and key text are too small on phones.** Every panel shrinks to 85% on phones, so buttons are 34–39 px tall. The longest goal step and the perk names show at about 7 px. Effort S.
7. **Taps fail silently or hit the wrong geode.**
   - A tap on cooldown, out of range, in a locked zone, or on a geode someone else just took looks exactly like a real one.
   - The gold "in reach" outline appears 4 studs before a tap can actually reach.
   - Clicks crack the nearest geode, not the one you clicked.
   - The "NEW" collection callout disappears if that geode is off-screen.

   Effort M.
8. **Every crack tilts the camera down.** Each crack tips the view about 3° down, and the tilt adds up. Holding CRACK or idling with Auto-Crack slowly points the camera at the floor. Effort S.
9. **After the first Rebirth there's no goal, and new zones open with no message.** The goal card disappears for good about 6 minutes in. Frost, Magma and Astral unlock with no message. Effort M.
10. **Rebirth and Ascend wipe progress on one tap with no confirm, and Ascend re-locks Magma.** A player who thinks they're spending 20K loses all their Coins, Power and Luck. After an Ascend, taps in Magma do nothing and nothing says why. Effort S. (your call: whether Magma and the rebirth pets stay unlocked after an Ascend)
11. **The game runs out of goals in the first session.** Magma pays 49× the hub, so a free player finishes almost everything within about 35 minutes. After minute 10, dailies, coin packs, the garden and the Meteor are worth seconds of play, and Power past level 12 and the Auto-Crack pass add almost nothing. Effort M. (your call)
12. **Crack effects are built on the server and sent to every phone.** In a busy server, each crack streams about 20 parts and 20 animations to every player, which causes stutter and lag on low-end phones. Effort M.

## Paste-ready prompts

Paste them in order, one per session, and wait for each to finish. Each one ends with its own tests.

### Prompt 1: Nothing breaks, nothing gets stuck

```text
Read CLAUDE.md first. My newer social-feature work (Audio, Feed, Nameplates, SocialFX, Social, ServerGoals + UI/server edits) is in Studio and NOT committed. Before each item, compare it with the CURRENT scripts in the open Studio place; if it is already fixed or the code has moved, skip it and tell me. If the working folder has uncommitted changes, ask me before committing so my social work gets its own commit.
If rojo / luau-lsp / selene are missing, install them first (docs/AUTOMATION.md section 5) so scripts/check.sh can run.
Goal: nothing breaks, nothing gets stuck. Golden rules: don't touch IDs, prices, keys, Config.Version, Config.Balance or drop tables; don't reorder ProcessReceipt; the server decides everything; remotes validate and refuse while not S.Ready; no formatter, tabs, double quotes. Match the game's existing emoji style in any new UI text.

1. The auto-equipped pickaxe blocks ClickDetectors, so the Starter Geode, Golden Geode, Meteor and pedestal ignore taps. Make the CrackRequest handler (Geodes.Init) the one "hit what's in front of me" path. Keep every existing ClickDetector.
 - First line of the handler: if not S.Ready then return end.
 - Starter first: Onboarding stores starterOf[player] = { pos, crack }; add Onboarding.TryStarter(player) that cracks it if within 26 studs (crack already guards `opened`; clear the entry on crack and PlayerRemoving).
 - Golden next: Geodes keeps a LIST per player (a bought one and a streak one can exist together). Open the nearest unopened one within 40 studs; openGolden removes only its own entry; clear the list on PlayerRemoving.
 - Then the existing nearest-node scan (ClickRange). Then the Meteor: move the ClickDetector body (65-stud check, 0.1 s tap gap, Damage(player, 1)) into Meteor.Tap(player), used by both paths. From CrackRequest, tap the meteor only if it is active AND (no node was in range OR (meteor.Position - hrp.Position).Magnitude - 6.5 < bestDist). Otherwise crack the node, so the hub ring still works during a meteor.
 - Name the starter/golden ball "Rock" AND set model:SetAttribute("OwnerId", player.UserId); PickaxeFX's outline must skip any model whose OwnerId is set and is not the local player.
 - Onboarding step 3 text: "Tap Upgrades (right side) and buy Power" (keep the pickaxe icon).
2. Make save trouble visible (Data.luau). player:SetAttribute("DataState", ...): "loading" at join; "ok" only when the session lock is owned, set AFTER cache[player] = profile; "failed" when acquire falls back to DEFAULT; "offline" in the `if not usable then` branch.
 - Client: a small "Loading your save..." chip while loading; outside Studio, a red strip "Your progress can't be saved right now - please rejoin later" for failed or offline.
 - Spawn the Starter Geode and fire StarterPopup only when DataState is "ok" (or in Studio). When DataState turns "ok" late, re-run the pickaxe hand-out, starter and daily popup that timed out (Pickaxe gives up after 10 s today); Pickaxe.Refresh returns early while the template is missing.
 - Purchase remote: outside Studio, if DataState isn't "ok", return { ok = false, err = "Your save isn't loaded yet - try again in a minute" } before opening a prompt.
 - Data.Init: if the startup probe fails (not the permanent Studio-access error), retry it every 60 s in a task.spawn and set usable = true on success, for NEW joiners only. Never re-run onAdded or set sessionOwned for players already in the server.
3. Loops that can't die. Monetize.Owns: after the pcall use `local c = ownsCache[player]; if c then c[key] = owns end`. Wrap the per-player body of the Geodes Auto-Crack loop, the Onboarding checker loop, the Shards proximity loop and the Buffs Golden Hour push loops (plus any while-true loop in my new modules) in pcall + warn.
4. No stranded geodes. In Geodes.TryCrack move BOTH setNodeShown(node, false) and the task.delay(NodeRespawn, Respawn) to right after node.alive = false, and delete them from their old spots. Add `if not S then return end` to CollectPets.Grant and MaybeVIP. Pickaxe.Init: wait for ServerStorage.PickaxeTemplate inside a task.spawn with a loud warn after 10 s, so it can never hold S.Ready false.
5. Zone-unlock buying. NexusFX buildCard/buildUpsell: keep the anchor part, but set bb.Adornee = anchor, bb.Active = true, bb.ResetOnSpawn = false, bb.Parent = LocalPlayer.PlayerGui; size the card rows in Scale so phones don't clip the Unlock button. Signposts.track: use `bb.Adornee or bb.Parent`, and also watch PlayerGui BillboardGuis that have an Adornee. Purchase remote: refuse Unlock_<zone> with "Already unlocked!" when the zone is unlocked (Zones.IsUnlocked + StatsFor) or in zonesPurchased. Shop: show those cards as "UNLOCKED" and not buyable - don't hide them.
6. Econ setup: create the Gems leaderstat as a NumberValue (an IntValue overflows around 9.2e18). Config.Fmt: after computing i, add `if n / 1000 ^ i >= 999.95 and i < #suffix then i += 1 end`.
Test (Play Solo, plus Device Emulator iPhone SE landscape):
 - Pickaxe out: tap the Starter Geode, and separately press CRACK beside it -> the "RARE Emerald" banner; TestHook "profile" shows cracks = 1.
 - Add a Studio-only TestHook action "meteorSpawn" -> S.Meteor.Spawn(). Next to the meteor, hold CRACK -> HP drops. Beside a ring geode -> the geode cracks and HP doesn't move.
 - TestHook "product" "GoldenGeode" -> walk to it, press CRACK -> it opens.
 - Temporarily put error("loop test") in the Auto-Crack body -> a yellow warning every tick, loop survives. Remove it; TestHook "pass" "AutoCrack" still auto-cracks.
 - Set a player's DataState to "failed" from the server command bar (Studio check bypassed temporarily) -> the red strip shows; "loading" -> the chip shows.
 - At the Nexus, click and tap "2x Coins", "Lucky" and "Unlock now" -> a purchase prompt. After TestHook "product" "Unlock_Frost", the Shop card reads UNLOCKED and the remote refuses.
 - Rename PickaxeTemplate -> the server still reaches Ready with a warning, geodes crack and respawn. Rename it back. Command bar: Config.Fmt(999950) -> "1.0M".
Finish: export to src/, run scripts/check.sh (must pass; the baseline must not grow), then commit with a clear message per logical change, and push to claude/crack-a-geode (this is my own local work - CLAUDE.md rule 11 is about the weekly cloud agent, not me).
```

### Prompt 2: First 5 minutes + clarity

```text
Read CLAUDE.md first. My newer social-feature work (Audio, Feed, Nameplates, SocialFX, Social, ServerGoals + UI edits) is in Studio and NOT committed. Before each item, compare it with the CURRENT scripts in the open Studio place; skip anything already fixed and tell me. If Prompt 1's CrackRequest/Onboarding changes aren't in yet, tell me before editing those functions.
Goal: a clear first 5 minutes and always a next goal. Golden rules: no ID/price/key/Config.Version/Balance/drop-table changes; don't reorder ProcessReceipt; server-authoritative; no new saved fields; no formatter; touch targets >= 44 px. Match the game's existing emoji style in new text; use whatever currency word the rest of the UI uses.

1. Daily popup: Dailies onJoin auto-opens only when (p.cracks or 0) > 0. For new players, Onboarding.Check (capture `before = p.onboardStep or 0` at the top) fires DailyPopup once when the step goes from < 2 to >= 2 and a reward is claimable. After a successful CLAIM (refs.dailyClaim), close the panel with UI.TogglePanel(nil). Don't change the Starter Pack popup timing (that's my decision).
2. Starter Geodes: up to 5 slots 8 studs apart (a second row 8 studs further back if needed), tracked in a slotUsed table that is freed on crack/leave; check the spots against the real spawn area. Put the "TAP TO CRACK!" BillboardGui in the owner's PlayerGui (Adornee = rock, ResetOnSpawn = false) and call bb:Destroy() in crack and on PlayerRemoving. Leave the starter up even if step 1 was done on a ring geode, so the owner still gets their Emerald.
3. Goal card text: Onboarding step 4 -> "Save up and Rebirth (Upgrades button)". Show the numbers in a small right-aligned label above the progress bar instead of appending them. goalText: TextWrapped, height 34, card height 72 on touch, MinTextSize 12. Index header -> "N/28 collected - full row = +10% Luck", with the mutation legend on its own 18 px label.
4. Goal card after the tutorial (client-only, from the snapshot): in UI.Update's else-branch show (a) the first locked zone in Config.Zones.list (skip the shards gate until at least 1 shard is found): zone.icon .. " " .. Zones.UnlockText(zone), with Zones.Progress pct/label on the bar; (b) if a zone opened this session and they haven't warped yet: "<zone> is open - step on its portal at the Warp Nexus"; (c) otherwise "Rebirth N+1 -> <snap.pets.nextName>" with gems / rebirthCost on the bar. During the tutorial show "Step x/4".
5. Zone-open moment: after each crack, Rebirth and new Index find, the server compares which zones are unlocked before vs after and sends that player ONE banner, e.g. "Frost Hollow unlocked! Head to the Warp Nexus" (once per zone per session). Relabel the Index per-zone line: "Per-zone finds (Astral gate uses the total above): ...".
6. Locked-zone feedback: where Geodes.TryCrack returns for a locked zone, send an Announce warn "<zone> is locked - <Progress text> (<label>). Use the return portal to go home." At most once per 5 s per player (Auto-Crack calls it every 0.2 s); clear the table on PlayerRemoving.
7. Rebirth/Ascend: Rebirth sub-text "x<RebirthMultBase> income forever - resets <currency>, Power & Luck" (+ " - unlocks <nextName>" when pets.nextReq == rebirths + 1). The Ascend sub-text lists everything it actually resets (read Econ.Buy "Ascend", Pets, Zones.StatsFor). Rebirth button: "REBIRTH (need 20.0K)" while short, "REBIRTH" + check mark when affordable. Two-tap confirm in buyAction for Rebirth and Ascend: the first tap shows "Tap again to reset" for 3 s.
8. Perks: two-line cards (name + perk.desc), 2 columns, about 200x56, with the same two-tap confirm ("Spend 1 Ascension Shard?"). Grey out AutoRadius with "(needs Auto-Crack pass)" when snap.passes.AutoCrack is false. Header: "Perks - Ascension Shards: N".
9. Garden side button: use the "geodeOpen" icon instead of "gem", and show a plant emoji + Config.Fmt(value) (or "FULL!") instead of a bare number.
10. Pets panel: add a "ZONE VIP PETS" section from cp.vip (emoji + name, +bonus%, "owned" or "locked: VIP perk or rare drop in <zone>"); base the header on cp.bonus > 0, not #cp.pets > 0.
11. Robux purchase confirmation: in ProcessReceipt keep the order EXACTLY; store GrantProduct's message and, just before returning PurchaseGranted, pcall a FireClient Announce with it to that player. Skip GoldenGeode, GiftBoost and Unlock_* (they already announce).
Test in the Device Emulator (iPhone SE landscape and an 800x360 Android):
 - Fresh profile: no Daily panel at join, goal card and CRACK visible. After 5 cracks the Daily panel opens once; CLAIM closes it. Step 4 text reads at 12 px or more.
 - TestHook "addGems" 60000 -> Upgrades: one Rebirth tap shows the confirm and resets nothing; a second tap rebirths, and the goal card moves on to the next zone.
 - Repeat addGems + "buy" "Rebirth" to Rebirth 3 -> the Magma unlocked banner appears once.
 - 15 x (addGems 1e12, buy "Rebirth"), then Ascend with two taps. Standing in Magma, tap -> the lock message (if Magma still re-locks). Perks show descriptions, and one tap doesn't spend.
 - TestHook "grantVip" "Cavern" -> the Crystal Monarch row shows as owned.
 - Test tab, 2 clients -> each sees only their own starter label.
 - A cheap real product on a live test server -> the confirmation banner.
Finish: export to src/, run scripts/check.sh (must pass), then commit with a clear message per logical change, and push to claude/crack-a-geode (this is my own local work - CLAUDE.md rule 11 is about the weekly cloud agent, not me).
```

### Prompt 3: Tap feel + mobile controls

```text
Read CLAUDE.md first. My newer social-feature work (Audio, Feed, Nameplates, SocialFX, Social, ServerGoals + UI edits) is in Studio and NOT committed. Before each item, compare it with the CURRENT scripts in the open Studio place; skip anything already fixed and tell me. Prompt 1 changed the CrackRequest handler - build on it, don't undo it.
Goal: every tap feels instant and honest, and the HUD fits phones. Golden rules: the server still decides every crack; validate anything the client sends; no Balance/price changes; no formatter; touch targets >= 44 px; mobile first.

1. Camera drift: in PickaxeFX's render step, replace the cam.CFrame rotation nudge with a kick that doesn't add up: Humanoid.CameraOffset = Vector3.new(0, -0.3 * nudge, 0) while nudge > 0.01, then Vector3.zero. Check my SocialFX (and any other file) for the same `cam.CFrame = cam.CFrame * CFrame.Angles(...)` pattern.
2. Honest reach: PickaxeFX outline range = Config.Balance.ClickRange (drop "+ 4" and "or 24"), and skip geodes in zones that are locked for me.
3. Cooldown on the button: from my own CrackFX events, set UI.CrackReadyAt = os.clock() + snap.cooldown ONLY when data.nodeId is present (the starter and golden don't start the cooldown). Show it on the CRACK button (fill or dim until ready). While CRACK is held, don't start a new swing before the last one finishes and don't swing while cooling down (keep sending the remote when unsure - the server decides).
4. Nothing in reach: add PickaxeFX.HasTarget(); if it's false, CRACK shows "Walk up to a glowing geode!" at most every 3 s and still sends the remote.
5. Tap what you touch: Effects' Tool.Activated path (swingAndCrack) calls PickaxeFX.Swing first (wire it in init.client.luau like UI.OnCrackInput), then FireServer, passing the node id when the tap/mouse target is a ring geode's Rock. Also pulse the targeted geode's highlight (FillTransparency 0.92 -> 0.6 -> 0.92) so the tap feels answered before the server replies. Remove task.spawn(swing) from Effects.Crack and delete the old swing/originalGrip/Effects.Swing if nothing else uses them (grep).
   Server: CrackRequest uses that optional id only if type(id) == "number", nodes[id] exists and is alive, and it is within ClickRange (NOT TryCrack's +8); otherwise it falls back to the nearest-geode scan.
6. NEW callout: also show "NEW: <gem>" as a UI.Toast from the CrackFX handler in init.client.luau when it's my crack and data.newEntry is set (the floating text is dropped when the geode is off-screen).
7. Auto-Crack chip in LeftStack when snap.passes.AutoCrack: "Auto-Crack ON", or "Auto-Crack: stand closer" when no live geode is within the server loop's reach (8, +4 with the AutoRadius perk, + Rock.Size.X / 2). Keep that formula in one clearly named place that matches Geodes' Auto-Crack loop.
8. Panels on phones (UI._RefreshPanels): `local fitH = IS_TOUCH and 1 or capH / p.h` then `local s = math.clamp(math.min(fitH, (regionW - 16) / p.w), 0.85, 1)`. On touch only: close buttons 46, the 40 px buttons 48 (Starter card 92 -> 104 tall), gift-picker Cancel 48, and the gift card height capped at gui.AbsoluteSize.Y - 24.
9. Jump button and banners (ship both together): reserve room for Roblox's jump button - `local reserve = IS_TOUCH and 108 or 20` in the side-menu scale, and move the menu up (e.g. UDim2.new(1, -10, 0.5, -44)) in BOTH positions in _ApplyOpenState. Move banners and the meteor bar into their own ScreenGui (ScreenInsets = TopbarSafeInsets, DisplayOrder above GeodeHUD). Keep at most 3 banners (destroy the oldest using a LayoutOrder counter), "rare" banners live 2.5 s, ClipsDescendants = true.
10. Notch: in Signposts.Init and Effects.Init set gui.ScreenInsets = Enum.ScreenInsets.None. In Signposts, on touch use EDGE_X = 52 on both sides and EDGE_BOTTOM = 28 in the clamps.
Test in the Device Emulator: iPhone SE, iPhone 14 Pro (both landscape directions), an 800x360 Android and an iPad.
 - In each, open every panel and run this in the Client command bar; it should print nothing:
   for _,b in ipairs(game.Players.LocalPlayer.PlayerGui.GeodeHUD:GetDescendants()) do if b:IsA("GuiButton") and b.Visible and b.AbsoluteSize.Y > 0 and b.AbsoluteSize.Y < 44 then print(b:GetFullName(), b.AbsoluteSize) end end
 - TestHook "pass" "AutoCrack", stand by a geode, don't touch the camera for 60 s -> the view stays level and a small kick still shows; the chip says ON.
 - Walk toward a geode from 25 studs -> the outline appears at the same step CRACK starts working. Press CRACK at spawn -> the walk-up hint. Hold CRACK at Power 0 -> one clean swing per crack.
 - Tap the farther of two geodes -> that one cracks. Crack with a fresh profile facing away -> the NEW toast still shows.
 - Tap the jump button's upper-left edge -> you jump. Fire 8 banners (loop TestHook "golden") -> at most 3, coin counter readable.
 - iPhone 14 Pro: an edge sign pill is fully visible, and "+N" rises from the cracked geode.
Finish: export to src/, run scripts/check.sh (must pass), then commit with a clear message per logical change, and push to claude/crack-a-geode (this is my own local work - CLAUDE.md rule 11 is about the weekly cloud agent, not me).
```

### Prompt 4: Performance

```text
Read CLAUDE.md first. My newer social-feature work (Audio, Feed, Nameplates, SocialFX, Social, ServerGoals) is in Studio and NOT committed and may add its own effects or crack sounds. Before each item, compare it with the CURRENT scripts in the open Studio place; skip anything already fixed and tell me.
Goal: busy servers stay smooth on phones. Only cosmetics move to the client; the server still rolls, pays, and hides/respawns geodes. Golden rules apply; no Balance/price changes; no formatter.

1. Crack burst on the client. Add Effects.CrackBurst(data), a port of Geodes.CrackFX (shells, lenses, shards, core, flash light, particle burst, crack/rare sounds). Parent everything to a client-only folder (under workspace.CurrentCamera or a LocalFX folder); set CanQuery/CanTouch/CastShadow = false on every part; play sounds from an Attachment at data.pos. Call it from Effects.Crack, and return early if data.pos is more than 250 studs from the camera. Add Quality.BurstScale (0.5 on mobile, 1 otherwise): on mobile use 3 + rarity shards, half the Emit count, and a PointLight only for my own cracks or rarity >= 5.
   Server: add size to all three CrackFX payloads (Geodes.TryCrack, the Golden Geode open, the Onboarding starter), then remove the three server calls to Geodes.CrackFX. Keep setNodeShown. Grep my new modules for other callers of Geodes.CrackFX or duplicate crack sounds first.
2. Fewer full-state pushes. Add Econ.PushSoon(player): push now if the last push was more than 1.0 s ago; otherwise queue ONE task.delay push at the end of the window so the final state always arrives. Clear the tables on PlayerRemoving. Use it only for the per-crack pushes (Geodes crack and golden, Onboarding starter, CollectPets.Grant, Dailies.Event). Buy, purchases and claims keep the immediate Econ.Push.
3. Meteor. In Meteor.Damage, send HP at most every 0.15 s, with a trailing task.delay send so the bar never sticks, and always send when hp <= 0. Replace the 40 server-side physics chunks in the supernova with a { phase = "boom", pos = pos } state; spawn the chunks in the client's meteor handler under workspace.CurrentCamera with CanQuery/CanTouch = false (20 on mobile).
4. Pickaxe FX. PickaxeFX.OnCrack: ignore other players whose HumanoidRootPart is more than 80 studs from the camera. When another player's swing ends, set weld.C1 = base once and drop the entry. Effects.watchPickaxe: keep a weak-keyed `hooked` table so Tool.Activated is connected once per Tool (at both connect sites).
Test:
 - Studio Test tab -> Clients and Servers, 3 players. TestHook "pass" "AutoCrack" for Player1 at the ring. On Player2, watch the burst (it should look the same as before) and note Shift+F3 "Received" KB/s before vs after.
 - Warp Player2 to Frost -> hub bursts no longer arrive.
 - Hold CRACK for 20 s -> the coin counter keeps up and ends matching TestHook "snapshot".
 - Meteor (TestHook "meteorSpawn" from Prompt 1): the HP bar moves smoothly and ends at 0; chunks fly and don't block taps.
 - Toggle the pickaxe 5 times, then click once -> exactly one CrackRequest (temporary print).
 - Play Solo in the iPhone SE emulator with Ctrl+F6 MicroProfiler while Auto-Crack runs; compare frame time before and after.
Finish: export to src/, run scripts/check.sh (must pass), then commit with a clear message per logical change, and push to claude/crack-a-geode (this is my own local work - CLAUDE.md rule 11 is about the weekly cloud agent, not me).
```

## Your decisions (economy & design)

Decisions 2 to 6 affect each other. Make them in one sitting, change one number at a time, and play 15 minutes after each change. Do Prompt 4 before lowering the geode respawn time. Ship Prompt 2's locked-zone message before any change that re-locks a zone.

### 1. Should Magma and the rebirth pets stay unlocked after Ascend?
**Problem:** Ascend sets Rebirths back to 0, so Magma Depths (unlocked at Rebirth 3) and every rebirth pet (advertised as "+X% forever") lock again.

**Options:**
- **A (the auditors' recommendation):** keep Magma open by making the gate use lifetime rebirths. The Nexus card also needs `totalRebirths` in the snapshot, or it will still show Magma as locked.
- **B:** also keep the rebirth pets. The pet unlock banners must then not re-announce pets the player already has.
- **C:** keep the reset, and rely on Prompt 2's confirm, "what resets" text and lock message.

A and B make climbing back after an Ascend faster, so decide them together with #4.

```text
Read CLAUDE.md and compare with the current scripts first. My decision: rebirth gates use lifetime rebirths. In Zones.StatsFor use rebirths = math.max(profile.totalRebirths or 0, profile.rebirths or 0); add totalRebirths = p.totalRebirths to Econ.Snapshot so NexusFX agrees; ALSO (delete this sentence if I only want Magma) use the same max in Pets tierUnlocked and Pets.Snapshot's nextReq loop, and make Pets.OnRebirth announce only when totalRebirths first reaches a tier; update the Ascend sub-text to match. Test: 15 x TestHook (addGems 1e12, buy "Rebirth"), buy "Ascend", then zoneUnlocked "Magma" -> true and the Nexus card says UNLOCKED. Export to src/, run scripts/check.sh (Zones.luau is --!strict), commit, push to claude/crack-a-geode (this is my own local work - CLAUDE.md rule 11 is about the weekly cloud agent, not me).
```

### 2. Crack speed tops out at about 1 per second
**Problem:** At most 2 geodes are ever in reach, and each takes 2 s to come back. So from Power 12 on, cracking caps at about 1 per second: Power 13–26 costs about 172K coins and buys nothing, and the HUD's "~X/s" and the garden income are overstated by up to 2.5×.

**Options:**
- **A:** respawn time `NodeRespawn` 2 → 0.8, or 1.0 if a geode reappearing mid-burst looks wrong. This raises top income up to 2.5×.
- **B:** cap Power at the level where cooldown reaches 1.0 s and show "MAX". The pickaxe look tiers at 14/18/24 would need to move into the 0–12 range.
- **C:** past the cooldown floor, Power adds coins per crack instead of speed.
- **D:** each player sees their own geodes. This is the standard simulator answer but a big change.

Whichever you pick, make the displayed rate honest: `ev / max(Cooldown(power), NodeRespawn / 2)`. That also lowers garden income.

```text
Read CLAUDE.md and compare with the current scripts first. My decision: set Config.Balance.NodeRespawn from 2 to 0.8, and in Econ.RecomputeRate divide by math.max(Config.Cooldown(p.power), Config.Balance.NodeRespawn / 2) so the HUD rate is honest. Test: TestHook addGems 300000, buy "Power" x26, stand between two hub geodes, hold CRACK 20 s, compare "snapshot".cracks before/after (about 20 before, 45-50 after); watch phone FPS with 3 clients. Export to src/, run scripts/check.sh, commit, push to claude/crack-a-geode (this is my own local work - CLAUDE.md rule 11 is about the weekly cloud agent, not me).
```

### 3. The Auto-Crack pass is slower than tapping
**Problem:** Auto-Crack only reaches about 11 studs from a geode's centre (tapping reaches 16). Parked by one geode, it cracks about 0.45 per second at any Power level, which is slower than tapping by hand.

**Option:** raise the base radius from 8 to 14. That gives about 17 studs of reach, enough to hit both neighbouring geodes from the right spot, and the Wide Auto-Crack perk still adds 4. Optionally, target the nearest live geode. Prompt 3's Auto-Crack status chip must use the same number.

```text
Read CLAUDE.md and compare with the current scripts first. My decision: in the Geodes Auto-Crack loop change `local radius = 8 +` to 14 (perk still +4) and pick the nearest alive node in reach instead of the first pairs() hit; update the Auto-Crack chip's reach formula to match. Test: TestHook pass "AutoCrack", addGems then buy "Power" x12, stand touching a hub geode on the side facing its neighbour, compare "snapshot".cracks over 60 s (about 28 before, about 60 after). Export to src/, run scripts/check.sh, commit, push to claude/crack-a-geode (this is my own local work - CLAUDE.md rule 11 is about the weekly cloud agent, not me).
```

### 4. Rebirths go too fast once Magma opens
**Problem:** Magma pays about 49× the hub. Each rebirth costs ×1.72 more while income only rises ×1.5, so after Rebirth 3 each rebirth takes 10–20 seconds. Ascend comes at 7–12 min and Astral at 24–35 min.

**Options:**
- **Gentler, the safer first step:** `RebirthCostGrowth` 1.72 → 2.4. Ascend at about 34 min.
- **Stronger:** 2.8, plus moving Magma to Rebirth 5. Ascend at about 55 min.

**Caveats:**
- Existing players' next rebirth costs jump (at Rebirth 10, 4.5M becomes about 592M with 2.8), so announce the change.
- With the Rebirth 5 gate, players at Rebirth 3–4 who didn't buy Magma lose it until Rebirth 5.

```text
Read CLAUDE.md and compare with the current scripts first. My decision: change Config.Balance.RebirthCostGrowth from 1.72 to 2.4 (nothing else in Balance) and update the pacing comment beside it. Test: TestHook addGems + buy "Rebirth" to walk the ladder; the rebirth button still reads cleanly at big costs on the iPhone SE emulator. Export to src/, run scripts/check.sh, commit ("Config: slow rebirth cost growth to 2.4 (Josh's decision)"), push to claude/crack-a-geode (this is my own local work - CLAUDE.md rule 11 is about the weekly cloud agent, not me).
```

### 5. The garden and the Meteor pay hub-level coins
**Problem:** Both pay from a hub-only earn rate. Once you farm Frost or Magma, the overnight garden jackpot is worth about 26 seconds of play, a solo Meteor pays less than one Magma crack, and the HUD's "~X/s" shows about 1/49 of your real Magma income.

**Option:** compute the earn rate from the player's best unlocked zone (its drop table and value multiplier) and the real crack rate, `min(1/Cooldown, 2/NodeRespawn)`. Expose it as a nil-safe `Econ.EarnRate`. Pay the Meteor 60 s × earn rate × scale. This also makes Instant Regrow (29 R$) worth more.

```text
Read CLAUDE.md and compare with the current scripts first. My decision: in Econ.RecomputeRate compute EV from the player's best unlocked zone (highest valueMult where Config.Zones.IsUnlocked(z, StatsFor(p))), using its dropTable looked up by rarity key, times valueMult, times math.min(1 / Config.Cooldown(p.power), 2 / Config.Balance.NodeRespawn); add a nil-safe Econ.EarnRate(player) returning p and p.savedEarnRate or 0; in the Meteor supernova pay S.Econ.AwardRaw(player, 60 * rate * scale) with a nil-safe profile lookup. Test: reach Rebirth 3 via TestHook, crack Magma, "snapshot".rate is about 49x a fresh hub profile; product "InstantRegrow" then "harvest" is about rate x 1296. Export to src/, run scripts/check.sh, commit, push to claude/crack-a-geode (this is my own local work - CLAUDE.md rule 11 is about the weekly cloud agent, not me).
```

### 6. Fixed rewards become worthless after minute 10
**Problem:** Dailies, quests, achievements, the VIP bonus and the Coin Pouch/Sack/Vault pay fixed amounts. At minute 10 the Day-7 reward is 0.08 s of play, and the 399 R$ Coin Vault is about 2 s, which invites refund requests and bad reviews.

**Option:** pay whichever is bigger, today's amount or a number of seconds of the player's own earnings. Proposed seconds:

| Reward | Seconds of earnings |
| --- | --- |
| Dailies | 60 to 3,600 along the 7-day ladder |
| Quests | about 200 for today's 2,500 reward |
| Achievements | 120 / 900 / 3,600 |
| VIP daily bonus | 600 |
| Coin packs | 15 min / 90 min / 8 h, with today's amounts as the minimum |

Leave the Starter Pack and the zone unlocks alone. `EarnRate` must never error inside `GrantProduct`, or a paid item is lost. Do #5 first.

```text
Read CLAUDE.md and compare with the current scripts first. My decision: pay math.max(flat, seconds * Econ.EarnRate(player)) in Dailies.Claim (60 s rising to 3600 s by day 7), the Dailies quest payout (flat / 12.5 seconds), Achievements.Claim (120 / 900 / 3600 s by tier), Buffs VIP daily (600 s) and the CoinsSmall/Medium/Large branch of GrantProduct (15 min / 90 min / 8 h, current coins as floors; desc like "15 minutes of Coins (min 12,500)"); EarnRate must be nil-safe and never error; don't touch StarterPack, Unlock_*, IDs or prices; Dailies.State shows the scaled values. Test: TestHook addGems + buy "Rebirth" x5, crack in Frost, then product "CoinsSmall" and claim a daily; each toast is about "snapshot".rate x the chosen seconds. Export to src/, run scripts/check.sh, commit, push to claude/crack-a-geode (this is my own local work - CLAUDE.md rule 11 is about the weekly cloud agent, not me).
```

### 7. The game asks for money in the first 10 seconds
**Problem:** A new player gets a Starter Pack toast 3 seconds after joining, and a "2× Coins pass would've made that 300!" toast on their very first rare crack.

**Option:**
- Show the 2× upsell only after the tutorial is done or after 30 cracks.
- Show the Starter Pack toast once goal step 2 is reached (check every second, for up to about 3 minutes) instead of after 3 seconds.

The offer stays first-session-only, and the Shop button keeps its glow.

```text
Read CLAUDE.md and compare with the current scripts first. My decision: in UI.OnCrack add `and (snap.cracks or 0) >= 30` to the 2x Coins upsell condition; in Monetize trackFirstSession replace task.wait(3) with a 1 s poll (up to 180 s, stop if the player leaves) until (p.onboardStep or 0) >= 2, then fire StarterPopup if StarterOffered. Test: fresh profile, no toast before 5 cracks, no upsell on the first Emerald. Export to src/, run scripts/check.sh, commit, push to claude/crack-a-geode (this is my own local work - CLAUDE.md rule 11 is about the weekly cloud agent, not me).
```

### 8. One currency with two names
**Problem:** The same currency is "Gems" with a gem icon in the upgrades, quests, errors and player list, but "Coins" in the Shop, the passes, the zone cards and the Pets panel.

**Options:**
- **"Coins":** matches the pass and product names already on your Creator Dashboard. Change display text only.
- **"Gems" everywhere:** then rename the passes and products on the Dashboard to match.

Either way, never rename code keys (`gems`, `DoubleGems`, `TopGems`). Renaming the player-list column is optional, and if you do it, `syncLeaderstats` must change in the same commit.

```text
Read CLAUDE.md and compare with the current scripts first. My decision: the player-facing currency is "Coins". Change display strings only (Onboarding step texts, Dailies descs, Econ error strings, Meteor/Garden/Pets banners, the gem-icon suffixes in UI/Achievements/Dailies, and the Nexus button to "Unlock now - R$ <price>"); never rename keys (gems, DoubleGems, TopGems) or change numbers; leave the leaderstat name alone. Test: grep src/ AND my new social modules for player-facing "Gems", then play 2 minutes in Studio and read every banner. Export to src/, run scripts/check.sh, commit, push to claude/crack-a-geode (this is my own local work - CLAUDE.md rule 11 is about the weekly cloud agent, not me).
```

### 9. The Sunken Grotto shard hunt gives no hints
**Problem:** Nothing says the 5 shards are in the Crystal Cavern near the outer walls. The shard counter only appears after the first find, and shards you've already collected keep glowing, so you can't tell which are left.

**Option:**
- Add "in the Crystal Cavern" to the unlock text.
- Show the shard counter from 0/5.
- Send `foundShards` to the client and hide the shards you've already collected.

The trade-off is that the code's design note says shards are meant to be found by exploring.

```text
Read CLAUDE.md and compare with the current scripts first. My decision: Sunken's UnlockText becomes "Find 5 hidden shards in the Crystal Cavern"; show the HUD shard chip from 0/5 (not only 1-4); add foundShards to Econ.Snapshot and on the client hide collected shards (LocalTransparencyModifier = 1, disable their light/emitter) using snap.foundShards["s" .. id]. Test: collect 2 shards via walking; they vanish for me only; chip reads 2/5. Export to src/, run scripts/check.sh (Zones.luau is --!strict), commit, push to claude/crack-a-geode (this is my own local work - CLAUDE.md rule 11 is about the weekly cloud agent, not me).
```

### 10. Void Opal ignores the zone drop tables (found earlier)
**Problem:** `Econ.RollRarity` looks up zone odds by the rarity's display name ("Void Opal"), but the zone tables use
the key `VoidOpal`, so every zone rolls Void Opal at the base 0.05 instead of the 0.5–3 set for deeper zones.

**Option:** the one-word fix below makes Void Opal 10–60× more common in the unlockable zones (the intended design).

```text
Read CLAUDE.md and compare with the current scripts first. My decision: in Econ.RollRarity change dropTable[r.name] to dropTable[r.key] so zone drop tables apply to Void Opal. Change nothing else. Test: crack 200 times in Astral Void with TestHook and check the rarity counts. Run scripts/check.sh, export to src/, commit, push to claude/crack-a-geode (this is my own local work - CLAUDE.md rule 11 is about the weekly cloud agent, not me).
```

### 11. A paid item can be lost if the server crashes mid-purchase (found earlier)
**Problem:** `ProcessReceipt` saves "this purchase was handled" first, gives the item, and only saves the item a few
seconds later. A crash in that window, or an error inside `GrantProduct`, means the player paid and got nothing,
and Roblox won't retry.

**Option:** save the item and the purchase record together.

```text
Read CLAUDE.md and compare with the current scripts first. My decision: in Monetize ProcessReceipt give the product first (GrantProduct wrapped in pcall; if it errors, return NotProcessedYet), then record the receipt id, then SaveNow. If SaveNow fails, keep the receipt id in memory and return NotProcessedYet, so the item and receipt save together on the next save and a repeat of this receipt in the same session doesn't grant twice. Don't change prices or IDs. Update CLAUDE.md golden rule 5 to describe the new order. Test a purchase with TestHook "product". Run scripts/check.sh, export to src/, commit, push to claude/crack-a-geode (this is my own local work - CLAUDE.md rule 11 is about the weekly cloud agent, not me).
```

## Playtest checklist (10 minutes, do this yourself)

- [ ] On a real phone with a fresh alt account: can you get your first crack within 10 seconds without reading anything? Does the first Emerald feel special?
- [ ] In the Studio emulator (iPhone SE landscape and a 360-tall Android): can you read the goal card, and hit every panel button with your thumb on the first try?
- [ ] Portrait: check whether portrait is turned on at all (StarterGui ScreenOrientation). If it is, does CRACK cover the jump button, and are toasts cut off? Decide on landscape-only or both.
- [ ] Hold CRACK for 60 seconds: do the swing and whoosh feel good or get annoying? Does the camera stay level?
- [ ] Tap while out of range, on cooldown and in a locked zone: do you understand why nothing happened each time?
- [ ] Meteor event with 2 or more people (Team Test or friends): is it exciting, does the HP bar move, and is the payout worth the walk?
- [ ] Your first Rebirth: do you know what you'll lose before you tap, and does the reward feel worth it?
- [ ] At minutes 10–15: is there still something you want to do next, or does it feel "finished"?
- [ ] In a server with 5 or more people, on your phone at the geode ring: any stutter or lag?
- [ ] Buy the cheapest real product on a live test: did the game clearly confirm what you got?
- [ ] After 5 minutes, are the crack, rare-find and whoosh sounds tiring? Is the overall volume right?
- [ ] Can you find the Warp Nexus without being told, and can you read the zone cards from a few steps away on your phone?

## Not worth doing yet

- **Bigger celebrations for Ruby, Starstone and Celestial finds.** Fun, but it's visual work that needs your eyes in Studio, and it matters much less than taps that work. Come back to it after Prompts 1–3.
- **Moving the ~36 decorative pulsing loops (portals, markers, shards) to the client.** It's a steady background cost, but far smaller than the crack bursts. Measure again after Prompt 4, and only do it if the network stats (Shift+F3) still show heavy traffic.
- **Hiding far-away orbiting trophies, and speeding up Quality's 3-second rescans.** Each costs well under a millisecond per frame. Players won't notice.
- **Sending static pet and achievement names only once instead of on every crack.** It saves data but rewires how the UI gets its information, right where your uncommitted social UI edits live. The push throttle in Prompt 4 covers the worst of it.
- **Per-player geodes (every player sees their own ring).** A big rework. Decide the economy numbers first; lowering the respawn time may be enough.
