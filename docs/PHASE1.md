# Phase 1 — Core loop

Map blockout, drawer assignment, Dryer + Clothesline, buy, income/collect, steal/carry/claim,
Towel Snap, drawer lock, saving, basic Pairs (bonus + thread beam). Built and linted in the cloud
(`rojo build` ok, `luau-lsp` clean on our code); **not playtested** — that is your job below.

## Explorer hierarchy (what the local Claude creates in a blank place)

```
ReplicatedStorage
└─ Shared                      (Folder)
   ├─ Config                   (Folder)
   │  ├─ EconomyConfig         (ModuleScript)  src/shared/Config/EconomyConfig.luau
   │  ├─ RarityConfig          (ModuleScript)  src/shared/Config/RarityConfig.luau
   │  ├─ MutationConfig        (ModuleScript)  src/shared/Config/MutationConfig.luau
   │  ├─ SockConfig            (ModuleScript)  src/shared/Config/SockConfig.luau
   │  └─ EventConfig           (ModuleScript)  src/shared/Config/EventConfig.luau
   ├─ Types                    (ModuleScript)  src/shared/Types.luau
   ├─ Util                     (ModuleScript)  src/shared/Util.luau
   └─ RemoteNames              (ModuleScript)  src/shared/RemoteNames.luau
ServerScriptService
└─ StealASockServer            (Script)        src/server/StealASockServer/init.server.luau
   ├─ RateLimit  Data  Map  Registry  Factory  Base  Pair  Income
   │  Clothesline  Purchase  Steal  Towel      (ModuleScripts, one per .luau file)
   └─ ProfileStore             (ModuleScript)  vendored, MIT
StarterPlayer
└─ StarterPlayerScripts
   └─ StealASockClient         (LocalScript)   src/client/StealASockClient/init.client.luau
      └─ HUD                   (ModuleScript)  src/client/StealASockClient/HUD.luau
```

Created at runtime by the server: `ReplicatedStorage.Remotes` (State, Toast, Announce, Carry) and
`workspace.StealASock` (Map, Bases, Line, Drawer, Carried folders). Nothing else is needed in the
place — delete the default Baseplate and SpawnLocation.

## Loading it into Studio (paste into your local Claude, Studio open, MCP on)

```text
Read CLAUDE.md. I have a NEW blank place open in Studio called "Steal a Sock" with the MCP toggle on. Load the Phase 1 code into it: in this repo folder run `git fetch origin` then `git checkout claude/steal-a-sock`, then recreate the tree from docs/PHASE1.md in the open place EXACTLY: ReplicatedStorage.Shared (Folder) with a Config Folder holding ModuleScripts EconomyConfig, RarityConfig, MutationConfig, SockConfig, EventConfig (from src/shared/Config/*.luau) plus ModuleScripts Types, Util, RemoteNames; ServerScriptService.StealASockServer as a Script whose Source is src/server/StealASockServer/init.server.luau, with one child ModuleScript per other .luau file in that folder (named after the file: RateLimit, Data, Map, Registry, Factory, Base, Pair, Income, Clothesline, Purchase, Steal, Towel, ProfileStore); StarterPlayer.StarterPlayerScripts.StealASockClient as a LocalScript from init.client.luau with the child ModuleScript HUD. Copy every file's contents into Source unchanged (keep tabs; when setting Source from Luau wrap the text in a long-bracket level the file doesn't contain). Delete the default Baseplate part and SpawnLocation. Then read back each Source and compare its length to the file; fix any mismatch. Don't publish. Finally list what you created and tell me to press Play.
```

## How to test

**Play Solo (Home → Play).** In order:

1. Output shows `[StealASock] server ready` and `[ProfileStore]: Roblox API services available` (or
   `unavailable - data will not be saved`; see Known issues #1). You spawn in front of a drawer whose
   sign has your name. HUD top-left shows `$100`.
2. Walk to the clothesline. Socks hang from clothespins and slide toward the Lint Trap; each shows a
   prompt like `Buy $60 ($3.0/s)`. Buy a Common → it hops into slot 1, the drawer panel lists it,
   `+$X/s` starts counting and the Collect pad's `$` label grows.
3. Step on the green Collect pad → `+$N collected` toast, cash goes up, pad resets to `$0`.
4. Buy the other half of the same type (wait for it on the line) → a thread beam joins the two,
   `PAIRED` badges appear, both rows in the drawer say PAIRED and income jumps x2.5 each.
   (Cheat for testing: in the server command bar, `game.Players.LocalPlayer` is nil in Play Solo —
   use the Client/Server toggle then `game.ServerScriptService.StealASockServer` modules aren't
   reachable from the bar; instead lower prices in `EconomyConfig`/`RarityConfig` temporarily.)
5. Press the red SLAM button in the back-left corner → the front shutter rises, HUD says
   `🔒 LOCKED 60s`, you can still walk through it (you own it). After 60 s it drops, then
   `Slam ready in 20s`.
6. Stop, Play again → your socks and cash are back (only if API services are enabled, see below).

**2-player local server (Test tab → Clients and Servers → Players: 2 → Start).** Two Studio
windows open (Player1, Player2) plus the server window.

7. Each player gets a different drawer and sign. Buy a sock as Player1.
8. As Player2, walk into Player1's drawer, face the sock, hold E (or the prompt button on touch) for
   1.5 s → the sock rides on your head, you walk slower, the red carry banner shows, Player1 gets a
   red toast. Player1's drawer panel drops the sock and the pair (if any) breaks.
9. Walk Player2 back to Player2's drawer → `Kept ...` toast, the sock hops into a slot, Player2's
   income rises.
10. Repeat the steal, but this time Player1 equips **Towel Snap** (Backpack, key 1), faces Player2
    within ~10 studs and clicks → Player2 is knocked back and frozen for 0.6 s, the sock flies back
    to Player1's slot, both get toasts.
11. Repeat the steal; while Player2 is inside Player1's drawer, Player1 hits SLAM → Player2 is pushed
    out the front, drops the sock, and cannot walk back in through the shutter; the Steal prompt on
    a locked drawer says `That drawer is slammed shut!`.
12. Repeat the steal; close Player2's window while carrying → the sock returns to Player1's slot.
    Then steal again and close Player1's window while Player2 carries → Player2's sock vanishes with a
    toast; rejoin Player1 (restart the test) → the sock is back in Player1's saved drawer.
13. Fill a drawer (8 socks) → the 9th purchase says `Your drawer is full!`; a thief carrying a sock
    home to a full drawer gets `Your drawer is full! Make room to keep this sock.` every 3 s.

**Phone check:** Test tab → Device → iPhone SE. The DRAWER toggle (56 px) is top-right, the carry
banner bottom-centre; nothing sits under the jump button. Prompts show as tap buttons.

## Known issues / limits (Phase 1)

1. **Saving in Studio** needs Game Settings → Security → *Enable Studio Access to API Services*;
   otherwise ProfileStore prints `Roblox API services unavailable - data will not be saved` and uses a
   mock store (fine for testing, nothing persists between Plays).
2. **Max players = 8** must be set in Game Settings (there are exactly 8 drawers; a 9th player is
   kicked with a message).
3. **Not playtested by me.** The cloud session can only build and lint. Expect small tuning on
   positions (sock height on slots, clothesline height, prompt distances) — all in `Map.Layout` /
   `EconomyConfig`.
4. **Knockback** uses a `LinearVelocity` on a client-owned character; if a client ignores it the stun
   and the sock return still happen (those are server-side).
5. **No anti-cheat for WalkSpeed.** Carry slowdown is a server-set WalkSpeed; an exploiter can reset
   it. Phase 4 can add a server speed sanity check.
6. **Mutations** are rolled and priced (x1.25 … x10) with a colour/material look only; particle looks,
   Stink accrual, Match Radar, RIVAL tags and the Sockdex are Phase 2.
7. **Sounds** are silent (`SockConfig.sound = ""`) until asset ids are added in Phase 4.
8. If a victim fills their drawer while a thief carries their sock and the steal then fails, the sock
   has no slot to return to: it stays in the victim's save and reappears next join.
9. The Steal prompt exists on every drawer sock; it is hidden locally for the owner and the server
   rejects owner steals — so it is safe, just visible to exploiters.
10. Socks bought while your drawer is slammed hop in through the shutter (intended).
