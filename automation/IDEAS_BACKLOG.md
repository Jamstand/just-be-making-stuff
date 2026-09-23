# Ideas backlog — Crack a Geode!

## How to use this file

- The weekly agent reads this before choosing work. It may only pick **Tier A** items; **Tier B** items
  it turns into proposals (with a paste-ready prompt) in its weekly report.
- The agent ticks items off in its PR (`[x] ... — PR YYYY-MM-DD`) and adds new ones with a one-line rationale.
- **Josh:** add anything in plain English under the right tier (or under "Unsorted" if unsure — the agent
  will sort it and explain). Tick/untick freely; a ticked item is never retried. To say "never do this",
  move it to "Rejected" with a short reason.
- Each item: what, where (file), why it matters. Numbers/IDs/prices are always Tier B.

## Tier A — agent may fix

- [ ] **GiftBoost target is ignored server-side.** `Monetize.ProcessReceipt` calls `GrantProduct(player, key)`
      with no gift target, while the client (`UI.luau` ~423-429) picks the first other player. Fix the plumbing:
      remember the requested target when the purchase is prompted (server side, per player), validate it is still
      in the server inside `ProcessReceipt`, pass it as the third `GrantProduct` argument. Keep the receipt
      idempotent. *Why:* a paid product that does not do what the buyer intended = refunds and lost trust.
      (What to do when the target left is Tier B — see below; until decided, fall back to today's behaviour.)
- [ ] **`Data.fromStored` silently drops unknown keys.** Any saved field without a `DEFAULT` entry is lost on
      load. Tier A part: `warn()` once per session per dropped key (name + player) so schema drift is visible in
      the output/logs, and add a comment on `DEFAULT` pointing at rule 4 in `CLAUDE.md`. *Why:* silent data loss.
- [ ] **Receipts list capped at 50 (`Monetize.luau`).** A heavy buyer with >50 products could see an evicted
      `PurchaseId` re-delivered and granted twice. Defensive fix: raise the cap (e.g. 200; a receipt id is ~36
      chars, well within DataStore limits) and/or evict oldest-first explicitly. *Why:* double grants = free items.
- [ ] **Dead code / unused locals (lint noise).** `UI.luau` `makePanel` is never called; unused locals
      `Players` (`Pets.luau`), `Config` (`Stations.luau`), `state` (`init.client.luau`); 5 same-line statements
      (`multiple_statements`). Remove/split them; baseline shrinks. *Why:* less noise = real problems stand out.
- [ ] **Type-checker noise, small and behaviour-neutral only.** `Zones.luau` registry entries lack optional
      fields `isHub` / `prebuilt` in the shared zone type (add them as optional, 13 findings); `Config.luau` strict
      mismatches (10); `StyleGuide.luau` types `Instance` too loosely for `MouseButton1Down` etc. (8; narrow to
      `GuiButton`/`TextButton` where safe). *Why:* ratchet the baseline down. Skip anything that changes runtime.
- [ ] **`README.md` says monetization IDs are placeholders (`0`).** They are real since commit 608c288. Fix the
      Monetization paragraph (text only). *Why:* a future session might "restore" zeros.
- [ ] **Remote audit.** Confirm every RemoteFunction/RemoteEvent handler has `S.Ready` gate, `type()` checks on
      all arguments, and a per-player debounce cleared on `PlayerRemoving` (pattern: `Purchase` in `Monetize.luau`).
      Add what is missing, nothing more. *Why:* remotes are the attack surface.
- [ ] **`BindToClose` / save-on-leave sanity.** Read `Data.luau` and confirm `UpdateAsync` retries have a bounded
      backoff and that a failed save is logged with the player id. Add logging only if missing. *Why:* silent save
      failures are the #1 "I lost my stuff" complaint.

## Tier B — propose only (needs Josh / Studio)

- [ ] **Mobile UI: touch targets under 44 px, no safe-area insets, HUD near notches.** Needs `UI.luau` /
      `StyleGuide.luau` changes checked on a phone or the Studio device emulator. *Why:* most Roblox players are on
      phones; unreachable buttons = churn.
- [ ] **Pickaxe feel is clunky** (swing timing, hit feedback, camera punch in `Effects.luau` / `Pickaxe.luau`).
      Needs playtesting. *Why:* the core loop must feel good in the first 30 seconds.
- [ ] **GiftBoost: what if there is no other player / the target left?** Options: self-boost, refuse the purchase
      before prompting, or refund (`NotProcessedYet` is NOT a refund). Josh's call. *Why:* monetization behaviour.
- [ ] **Export the current Studio place into `src/`** (game branch is ~1 month behind Studio). Local session with
      the Roblox Studio MCP; then re-baseline (`scripts/check.sh --update`). *Why:* every automated change is only
      as good as the repo it is built on.
- [ ] **DataStore schema policy:** should `fromStored` preserve unknown keys (forward-compat) instead of dropping
      them? Trade-off: unbounded growth vs. safety. *Why:* one-way door for player data.
- [ ] **Economy / balance pass** (drop rates, pity, rebirth multipliers, `Balance` table, zone prices, starter
      pack contents). Always Josh. *Why:* revenue and retention levers.
- [ ] **New monetized features** (e.g. pet slots, cosmetic pickaxes). Always Josh; the agent may only sketch
      a design with retention/monetization reasoning in "Ideas".
- [ ] **Studio-built world objects the code assumes** (`workspace.CrackAGeode.FX/Nodes/Map/Gardens`, Lighting
      effects): document them or add a startup check that warns when one is missing. The warning code is Tier A;
      deciding what to build is Tier B.

## Unsorted (Josh writes here)

- (empty)

## Rejected (do not retry)

- Introducing StyLua or any formatter — would rewrite all 30 files and break hand-aligned tables.
- Adding `--!strict` to non-strict files "for quality" — 1,000+ new findings, no runtime benefit.

## Done

- (empty — the agent moves ticked items here when the PR is merged, keeping the PR date)
