# Lead notes (authoritative additions to plan.md)

## A. Bug the audit missed — Ascension re-locks pets and strands onboarding
Observed in a live Studio play test on a profile that has ascended: `p.rebirths` is reset to 0 by `Econ.Buy("Ascend")`, so
- every rebirth pet re-locks (`Pets.tierUnlocked` compares `p.rebirths` to `t.req`) and the Pets panel says "Next: Rock Sprite at Rebirth 1 (you're at Rebirth 0)" while the HUD shows a ×65 multiplier;
- the onboarding step 4 (`done = rebirths >= 1`) can never complete, so the NEXT GOAL card is stuck at "Save Gems, then Recrystallize (20.0K/20.0K)" forever.
Pets are advertised as "+N% Gems forever", so unlocks must be permanent.

**Fix (server owner, Phase 1, part of SV-7):**
- `Econ.LifetimeRebirths(p)` = `math.max(p.totalRebirths or 0, p.rebirths or 0, (p.ascensions or 0) * Config.Balance.AscensionAtRebirth)` (the last term migrates profiles that ascended before `totalRebirths` existed).
- `Pets.tierUnlocked`, `Pets.Snapshot` (`nextReq/nextName` and a new field `lifetimeRebirths`), `Onboarding` step 4 `done`, and `Achievements.statsFor.rebirths` all use it.
- Add `lifetimeRebirths:int` to `Econ.Snapshot` (per-push, one integer).
**clientUI (UI-7):** the Pets header reads `snap.pets.lifetimeRebirths` (fallback `snap.rebirths`) and says "Lifetime Rebirths N" and, when `snap.ascensions > 0`, "· Ascension N". Never show "you're at Rebirth 0" to an ascended player.

## B. Decisions on the plan's open questions (§9) — do not ask again, implement these
1. Daily auto-open: returning players (`p.onboardDone == true`, not first session) DO get the Daily panel auto-opened 3 s after join when a reward is claimable (`DailyPopup` → `UI.ShowPanel("Daily")` when `UI.AnyPanelOpen() == false`). First-session players never get an auto-open (glow + toast only), exactly as the plan says.
2. Server-goal tuning: accept the plan values.
3. Leaderboard identity: username fallback via `GetNameFromUserIdAsync` is fine; no companion key.
4. "Gifter" at 3 gifts; no other titles this pass.
5. Touch rail: 3×3 grid top-right as planned.
6. `UI.luau` stays ONE file unless it exceeds 3,000 lines; only then may it become `UI/init.luau` + at most three children. Prefer one file.
7. Music default 22.
8. Golden bystander hint: keep.
9. New icons: emoji fallbacks; keep `Icons.players/board/sprout = 0`.
10. Voice/party/teleport/trading/codes: excluded, confirmed.

## C. Currency
"Gems 💎" everywhere player-facing (plan §7). Internal keys unchanged. (The Creator Dashboard product names still say "Coin …"; the human will rename them — do not touch ids.)

## D. Working rules for every implementer
- No Roblox Studio MCP tools at all. The lead pushes to Studio and play-tests afterwards.
- Read `plan.md` in full (it is ~540 lines; read it in chunks) before editing. The CONTRACT (§3) is authoritative; if you must deviate, record it in your result's `contractDeviations` with the reason.
- Keep the game bootable at every step: no half-migrated call sites, no references to functions that do not exist yet in YOUR owner scope. If you depend on something another owner delivers (a remote, a snapshot field, a UI hook), code defensively (nil-check, `FindFirstChild`, `WaitForChild(name, 5)`) exactly as the plan's partial-landing matrix (§6) requires.
- Keep `--!strict` files parseable; Luau, not Lua 5.4 (no `goto`, no integer division `//` needed, `+=` and `continue` are fine).
- Preserve the Studio `TestHook` in init.server and add the new actions the plan lists.
- Tabs for indentation, existing comment-banner style, StyleGuide factories for all UI.
