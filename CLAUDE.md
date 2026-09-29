# CLAUDE.md — Steal a Sock 🧦 (read this first)

This branch (`claude/steal-a-sock`) is a separate game from Crack a Geode. Same repo, different
branch, its own `default.project.json` (project name `StealASock`). `README.md` has the module map;
`docs/PHASE1.md` has the Explorer hierarchy, test plan and known issues for the current phase.

## Rules

1. **Server-authoritative everything.** Purchases, income, pickup, carry, claim, locks are decided
   on the server. Clients only receive `State`/`Toast`/`Announce`/`Carry`. Phase 1 has NO
   client→server remotes on purpose (ProximityPrompts, a touch pad and a Tool do the asking);
   any remote added later must validate distance, ownership, lock state and cooldowns and go
   through `RateLimit.Check`. Never trust client prices, positions or WalkSpeed.
2. **Numbers live in config only:** `EconomyConfig`, `RarityConfig`, `MutationConfig`,
   `SockConfig`, `EventConfig`. Balancing must never require touching logic.
3. **Saving:** ProfileStore, key `p_<UserId>`, store `StealASock_v1`. Profile.Data shape is
   `TEMPLATE` in `Data.luau`. New fields need a default there. Arrays must have no gaps.
   Socks leave the server with their owner; a sock a thief is carrying stays in the owner's save
   until it is claimed (`Base.SyncToProfile` writes slots + `away`).
4. **One loop per concern, none per sock:** `Income.Tick` (1 s), `Steal.Tick` (Heartbeat),
   the Dryer spawner, the drum spin. Clothesline movement is one Tween per sock.
5. **Placeholder art from Parts**, tagged with CollectionService. Don't add asset ids you haven't
   verified; `SockConfig.sound = ""` means silent.
6. **Modern Luau:** `task.*`, type annotations where practical, no deprecated APIs
   (`BodyVelocity`, `wait`, `spawn`). Tabs, double quotes, no formatter.
7. **Mobile-first UI:** touch targets >= 44 px, nothing under the jump button (bottom-right).
8. Run `bash scripts/check.sh` before every push (rojo build + luau-lsp ratchet + selene in CI).
   The 39 baselined findings in `ProfileStore.luau` are the vendored library's, not ours.

## How code gets into Studio

Josh's local Claude Code session (Windows, `.mcp.json` → Roblox Studio MCP) creates the instances
listed in `docs/PHASE1.md` in a blank place and sets each `Source` from `src/`. The map builds
itself on Play. Cloud sessions cannot see Studio; they build and lint only.

## Phase plan

1 Core loop (done here) → 2 The hook (Match Radar, RIVAL tags, Stink, Sockdex, mutation looks)
→ 3 Events, gear, rebirth, leaderboards → 4 Monetization, sounds, particles, polish, balance.
Stop after each phase for a playtest.
