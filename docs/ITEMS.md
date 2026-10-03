# Items — the Towel Snap and the eight bar items

Everyone has the **Towel Snap** in slot 1 of the item bar. The eight other items are unlocked for
good with cash (Item Shop → Items) or straight away with Robux (one developer product per item), and
a player carries the towel plus up to `ItemConfig.LoadoutSize` (3) of them. The **server decides
everything** (cooldowns on its own clock, who gets hit, who slips, who is slowed); each client only
asks, predicts its own use for feel, and plays the effects.

| File | What it is |
| --- | --- |
| `src/shared/Config/ItemConfig.luau` | every item: key, name, price, cooldown, model, and all the tuning numbers (source of truth) |
| `src/server/StealASockServer/Items/init.luau` | the item bar on the server: unlocks, loadout, tools, the `UseItem` / `BuyItem` / `SetLoadout` remotes, cooldowns, speed, knockback, stun, grace |
| `src/server/StealASockServer/Items/Rules.luau` | what each item does, and the world objects it leaves (peels, ducks, clouds, bubbles, baskets, canopies) |
| `src/server/StealASockServer/Items/Looks.luau` | every item's model: from `ReplicatedStorage.ItemMeshes`, or a Part build while that model isn't imported |
| `src/server/StealASockServer/Towel.luau` | the Towel Snap: who it hits, the towel's look per level |
| `src/client/StealASockClient/ItemClient.luau` | the bar's engine (the API `ItemBar` uses), prediction, your own dash and glide |
| `src/client/StealASockClient/ItemFX.luau` | everything you see and hear: bursts, the sock-home arc, bubbles, slips, quacks, sounds |
| `src/client/StealASockClient/ItemRig.luau` | procedural character animation (swing, throw, place, spray, zap, dash, slip, tumble, float, glide, sleepy, static) and the towel's whip |

Other server modules hook in: `Steal.ApplySpeed` multiplies WalkSpeed by `Items.SpeedMult`;
`Steal.TryPickup` / `Claim` / `Return` call `Items.OnCarryChanged` (it pops you out of the basket);
`Upgrades` re-skins the towel on a Towel Snap level; `Monetize.GrantProduct` unlocks items bought
with Robux; `Income.Push` puts `items`, `loadout` and `towelLook` in the StateView.

## The Towel Snap

- **Who it hits:** the nearest **thief** (someone carrying a sock) inside the cone in front of you
  (`TowelCone` = 60° either side, reach = the Towel Snap upgrade, x1.5 with the Royal Towel). With no
  thief in reach, the nearest **other player** in the cone gets a real push: `ShoveMult` (half) of a
  thief's knockback, no stun.
- **A thief:** full knockback + `TowelStunSeconds` stun + a somersault, and the stolen sock flies
  home on an arc (`Steal.Return(…, "snapped")` + the `sockhome` effect). The socks nearby still
  flinch (`S.FX("snap")`).
- **Hold to keep cracking:** a tap is one snap; **holding** the towel slot, **Q** / **1**, gamepad
  **Y**, or the mouse / a finger in the world keeps snapping, one snap each time the 1 s cooldown is
  ready (`ItemClient.Press` / `Release`; `UseItem`'s `held` flag tells every other client to play
  the swings as one loop). Letting go stops it; so does the window losing focus or respawning.
- **Feel (every client):** an overhead crack on every use, hit or miss — the arm takes the towel up
  and back over the shoulder and lashes it down in front, the towel curls back, unrolls and cracks
  at the tip (its `Seg1…Seg6` bones, or the Part towel's `Seg1…Seg6` motors), with a whoosh. While
  held, the arm lifts the towel straight back over the shoulder after each crack, so the next crack
  starts from up there: one continuous back-and-forth loop. Holding the towel between swings, the
  arm rests lower and the towel hangs and sways. On a hit, at the moment of the crack: a crack
  sound, a comic **SNAP!** (BOP! for a shove) with stars and a shockwave ring, and a tiny screen shake
  for the snapper (off with Reduce motion). Your own swing starts the instant you press (prediction);
  everyone else sees it when the server says so.
- **Look:** by Towel Snap level, `ItemConfig.TowelLooks[level + 1]`: Plain → Striped → Beach → Spa
  → Sports → Champion. The Golden Towel pass shows `Royal`. The tool re-skins in your hand the moment
  the level or the pass changes (`Towel.Refresh` → `Items.RefreshTowel`).
- The **aim** sent with `UseItem` is where you clicked / tapped in the world (or where you face when
  you use the bar); it only turns the cone.

## Every item

| Item | What it does (server) | Numbers (`ItemConfig`) |
| --- | --- | --- |
| **Slipper Dash** | Your client dashes you forward along the floor (a short `LinearVelocity`); the server approves and times it and everyone sees a trail + dust (`dash`). Shorter while carrying a sock. | `Dash = { distance, seconds, carryMult }` |
| **Banana Peel** | Drops a peel on the floor behind you. One per player (a new one replaces the old), gone after `lifetime` or after someone slips. The **owner never slips**. The next other player over it slips: tumble, `slipSeconds` stun, a carried sock goes home, out of a basket, a glide ends. | `Banana = { lifetime, slipSeconds, radius }` |
| **Bubble Blaster** | Fires a bubble the server flies (`speed`, `range`); it pops on the first player or wall. A **thief** inside floats up `floatHeight` for `floatSeconds` (can't walk) and the sock goes home; anyone else bounces off (`bounceMult` of a thief's knockback). | `Bubble = { speed, range, radius, floatSeconds, floatHeight, bounceMult }` |
| **Rubber Duck Alarm** | Only inside **your own** drawer; one per player; gone when you leave (or place another). When another player walks in it quacks for everyone (at most every `quackGap`), you get a toast and see them glow red for `highlightSeconds` (only you). | `Duck = { quackGap, highlightSeconds }` |
| **Softener Cloud** | Sprays a cloud `distance` in front of you, `radius` wide, for `lifetime`. Everyone else inside is slow and sleepy (`slowMult`; thieves `thiefSlowMult`); the owner is immune. Speed comes back the moment you leave it or it fades. | `Softener = { distance, radius, lifetime, slowMult, thiefSlowMult }` |
| **Static Balloon** | ZAP: everyone else within `radius` hops back (a towel shove), hair on end for `hairSeconds`; thieves also drop the sock home; hiders pop out of baskets. | `Balloon = { radius, hairSeconds }` |
| **Laundry Basket** | Hide under it for up to `maxSeconds`, shuffling at `speedMult`. Others see only the basket: your body, face, accessories, held tool, name tag, VIP tag and a carried sock are hidden and put back **exactly** when you pop out. Use it again to pop out. Using any other item, being snapped, zapped or slipping, or picking up / keeping / dropping a sock pops you out. The cooldown starts when you pop out. | `Basket = { maxSeconds, speedMult }` |
| **Dryer-Sheet Glider** | Only in the air (jump off something): a dryer-sheet canopy over your head; your client falls at `fallSpeed` and flies forward at `forwardSpeed`, steering with the move keys / thumbstick. Landing ends it (the client tells the server; the server also notices by itself). `maxSeconds` at most. A knock or a slip ends it. The cooldown starts when it ends. | `Glider = { fallSpeed, forwardSpeed, maxSeconds }` |

**Fairness:** nothing can stun-lock anyone — after any push or stun a player can't be pushed,
stunned or slip again for `ShoveGrace` seconds after it ends (a thief can still be snapped: that's
the point of the towel, and they can't be a thief again that fast). You can't use items while
stunned or floating. Your own peel, cloud and zap never affect you. Everything a player has going
(basket, glide, bubble, stun, slowness) ends when they die or respawn; their peel, duck, clouds and
bubbles go when they leave; server shutdown pops everyone out. Per-player tables are cleared on
`PlayerRemoving`.

## Saved data and what the clients read

- `profile.Data.items` — `{ [key] = true }` (the towel is everyone's, never stored).
  `profile.Data.loadout` — exactly `LoadoutSize` strings, `""` = empty slot (no gaps). Both have
  defaults in `Data.luau`'s TEMPLATE (migration: new fields; old profiles get `{}` and
  `{ "", "", "" }`). A bad saved loadout is cleaned on read (unknown, locked or repeated keys → `""`).
- Player attributes: `CD_<key>` = server time that item is ready again; `Active_<key>` = a glide,
  basket, duck or peel is out.
- Character attributes: `Item` (held key), `Gliding`, `InBasket`, `Encased`, `StunUntil`,
  `HairUpUntil`, `SoftenedUntil` (server times).
- World objects in `workspace.StealASock.Items`: `BananaPeel_<UserId>`, `AlarmDuck_<UserId>`,
  `SoftenerCloud_<UserId>`, `Basket_<UserId>` (on a `BasketJoint` motor each client wobbles),
  `Glider_<UserId>`, `Bubble_<UserId>`.

## Remotes

Every handler: refuses while starting up, checks every argument's type, rate-limits per player,
answers a `Types.Result`, never errors at a client. Refusals of `UseItem` are toasted (at most one a
second; the bar only shakes); the Item Shop shows `BuyItem` / `SetLoadout` errors itself.

| Remote | Arguments | Rules |
| --- | --- | --- |
| `UseItem` | `key`, `aim?` (horizontal, finite, non-zero), `held?` (boolean: the towel button is held down) | the towel, or unlocked AND in the bar; not cooling down (server clock); not stunned / floating; 0.12 s per item. Answers `{ ok, err?, cooldownUntil? }`. A second use ends a glide / pops the basket. |
| `BuyItem` | `key` | not the towel, not already unlocked, enough cash (`Data.TrySpend`); celebrates `"item" { key, display }`; fills the first empty bar slot. 0.25 s. |
| `SetLoadout` | `{ keys }` | at most `LoadoutSize` entries at indices 1…LoadoutSize, strings only, `""` allowed, unlocked, no repeats, no towel. 0.25 s. Items leaving the bar stop (glide, basket). |
| `StorePurchase("product", "Item_<Key>")` | (Monetize) | refused when that item is already unlocked; the grant (`Monetize.GrantProduct`) calls `Items.Unlock` (a second grant just says "already unlocked" — never an error, so a re-delivered receipt can't loop). |

`ItemFX` (server → clients, `(kind, data)`; all players unless noted): `swing { player, key, look,
hit }`, `snap { position, by, target, thief, look }`, `tumble { player, dir, seconds, soft? }`,
`sockhome { from, to, color, uid }`, `use { player, key, position?, out? }`, `dash { player }`,
`slip { player, position, seconds }`, `bubble { id, from, dir, speed, range, by }`,
`bubblepop { id, position }`, `encase { player, seconds }`, `quack { position, owner }`,
`intruder { player, seconds }` (the duck's owner only), `spray { player, position, radius, seconds }`,
`zap { player, position, radius }`.

## ItemClient (the bar's engine — the contract with ItemBar)

```lua
ItemClient.Use(key)                 -- hold it and use it now: local prediction + UseItem; nothing while cooling down
ItemClient.Hold(key?)               -- hold that item's tool (nil = put it away); a click / tap in the world then uses it
ItemClient.Held(): string?
ItemClient.CooldownUntil(key): number   -- server time it's ready again (0 = ready)
ItemClient.CooldownLength(key): number  -- seconds of that cooldown (for the ring)
ItemClient.IsActive(key): boolean       -- Glider gliding, Basket hiding, a Duck or Peel out
ItemClient.Changed: RBXScriptSignal     -- (key) cooldown / active / held changed (also when a cooldown ends)
ItemClient.Failed: RBXScriptSignal      -- (key, err) the server said no (it also toasts why)
ItemClient.Init()                       -- runs on require; calling it again does nothing
```

Requiring it starts `ItemFX` (and `ItemRig`). A use is predicted at once (cooldown, swing, pose,
whoosh, the dash) and corrected by the server's answer; a refused use rolls the cooldown back and
fires `Failed`.

## Animation (ItemRig)

Poses are written into the characters' `Motor6D.Transform` on `RunService.Stepped`, which runs after
the Animator each frame, so they lie on top of the default Animate script (walk, idle, toolnone) and
never fight it; when a move ends the Animator's pose is back (if no animation drives a joint, the
pose it had is put back). Moves are rotations in the character's own axes about each joint, so R15
and R6 share them (R6 has no elbows or waist). The tumble spins the visual body about the root joint
— the physics root never turns. Other players' characters are animated on every client; beyond 160
studs the moves are skipped. A held towel droops and sways within 70 studs.

The **towel whip** bends `Seg1…Seg6` about one axis in the handle's space (tip down = positive, with
a little sideways sweep): it curls back for `WIND` (0.12 s), unrolls from the handle to the tip and
cracks ~0.22 s in, wobbles and settles into the droop (or, held, curls back over the shoulder again
with the arm for the next crack). On the Blender towel (a flat cloth) `Seg1` is the end gathered in the fist, so it stays nearly rigid, and
every joint is kept inside 45° (75° for `Seg5` / `Seg6`); the cloth itself bends cleanly to ~120°
across it but only ~20° sideways.

## Models (`ReplicatedStorage.ItemMeshes`, from `tools/blender/items`)

| Name | Used as | If it's missing |
| --- | --- | --- |
| `Towel_Plain` … `Towel_Champion`, `Towel_Royal` | the towel in your hand (by look): a flat bath towel held at one end, with NO outline mesh (a painted ink edge, plus a Highlight outline on the nearest 6 held towels, 3 with Low graphics) | a flat Part towel in the look's colours, with Motor6D segments that whip the same way |
| `DashSlippers`, `BananaPeel`, `BubbleBlaster`, `AlarmDuck`, `SoftenerBottle`, `StaticBalloon`, `DryerSheet`, `LaundryBasket` | the held tools (the basket at 0.32 scale) | Part builds of each |
| `BananaPeel`, `AlarmDuck`, `SoftenerPuff`, `DryerSheet`, `LaundryBasket` | the world objects (peel, duck, cloud puffs, canopy, basket over a hider) | Part builds |

Conventions: 1 unit = 1 stud, front = +Z after `MeshTemplate.Prepare`, `<Name>_Grip` = where the
right hand holds it (the tool's invisible Handle sits exactly there, and every tool uses the same
`Grip = CFrame.Angles(0, math.pi, 0)` so the front points forward out of the fist), `<Name>_Tip` =
where effects come out (a `Tip` attachment in the Handle), `<Name>_Base` = the floor point of placed
items, `<Name>_Glow` parts become Neon. Markers are hidden; outline parts cast no shadow; an imported
`Animator` / `AnimationController` is removed (it would overwrite the towel's bones). The server
prints `[Items] N item model(s) found in ReplicatedStorage.ItemMeshes` on start.

**Why the towels are flat and have no outline mesh.** The first towels were rolled, twisted
towels: long smooth tapering rods with a rounded folded end. Roblox's automatic mesh check removed
one of their black outline hulls (`Towel_Striped_Outline`, seen on its own as a bare silhouette)
as "Sexual Content". The towels were rebuilt as flat, square-ended cloth with no rods, balls or
tassels, and without the separate outline mesh. Keep it that way: no item should upload a bare
rod- or tube-shaped silhouette. Never re-upload the old towel meshes.

## Sounds

All Roblox's own audio (creator "Roblox", id 1), each checked `IsPublicDomain = true` on
`economy.roblox.com/v2/assets/<id>/details` on 2026-10-03. Positional (8–70 studs), at most 10 a
second, volume x the **Sound effects** setting. Change any id in `ItemFX.Sounds` (`""` = silent).
Nobody has listened to them in the game yet — give them a listen in Studio.

| Name | Id | Roblox asset | Used for |
| --- | --- | --- | --- |
| swing | 12222200 | swoosh.wav | every towel swing |
| crack | 12222140 | snap.wav | a towel hit on a thief (at the crack) |
| bop | 12222046 | hit.wav (raised) | a towel shove |
| boing | 12222124 | Short spring sound.wav | tumbling, slipping |
| whooshSoft | 15675024286 | Roblox_UI_Whoosh_01 | the sock flies home, the glider opens |
| pop | 15675055424 | Roblox_UI_Cute_Pop | the sock lands home, bubbles pop, popping out of the basket |
| thunk | 12222054 | Kerplunk.wav | a peel / duck / basket set down |
| splat | 12222152 | splat.wav | slipping on a peel |
| blow | 17208204604 | Roblox GUI - Bubble (lowered) | blowing a bubble |
| blub | 17208204604 | Roblox GUI - Bubble (low) | a thief caught in a bubble |
| quack | 79205036324023 | BirdHello_01 (lowered a little) | the duck's squeaky "quack" (no Roblox-made duck exists; a squeaky-toy chirp) |
| alarm | 12221990 | electronicpingshort.wav | your duck saw someone (only you, not positional) |
| spray | 17208402198 | Roblox GUI - Spraypaint | the softener spray |
| zap | 16480558943 | Audio/Roblox_Pinball_Joystick_Buzz_Release_01 | the static balloon (a short buzz) |
| dash | 15675012262 | Roblox_UI_Whoosh_04 | Slipper Dash |
| glideLoop | 15675021174 | Roblox_UI_Loop_Air_Whooshes | wind while you glide (quiet loop, only you) |

## Settings

**Reduce motion**: no screen shake, no somersaults (a wobble instead), a smaller slip and basket
wobble. **Low graphics**: half the particles. **Hide others' effects**: no bursts, puffs, bubbles or
trails from other players farther than 30 studs (the sock-home arc and your own effects always show).
**Sound effects**: every item sound.

## Tuning knobs

- Everything gameplay is in `ItemConfig` (cash prices and Robux prices are Josh's call).
- Towel reach / knockback / stun: `EconomyConfig` (`TowelRange`, `TowelKnockback`, `TowelKnockUp`,
  `TowelStunSeconds`), `ShopConfig` (Towel Snap levels), `StoreConfig.GoldenTowelMult`.
- `Items/init.luau`: `USE_GAP` (0.12 s per item), `MENU_GAP`, `TICK` (0.1 s rule checks).
- `Items/Rules.luau`: `CANOPY_Y` (glider canopy height), `BUBBLE_BODY`, `FLOAT_RISE`, `CLOUD_FADE`,
  `SOFT_LINGER`, `GLIDE_LAND`.
- `Items/Looks.luau`: `GRIP` (how every item sits in the hand), `CARRY_BASKET`, the Part towels'
  colours (`TOWELS`).
- `ItemRig.luau`: `WIND`, `DROOP`, `SWING_AXIS` (flip its sign if the towel whips the wrong way),
  `BONE_WEIGHT` / `BONE_LIMIT`, every move's keyframes, `RANGE`.
- `ItemFX.luau`: `ItemFX.Sounds`, `CRACK_T` (when the burst lands after a swing), `LOOK_COLORS`,
  `SOUND_RANGE`, `HIDE_OTHERS_RANGE`.

## Tested headless

A mock of the Roblox API runs the real server modules (`Items`, `Looks`, `Rules`, `Towel`, `Steal`,
`Upgrades`, `Monetize`, `Data`, `Income`, `RateLimit`, `MeshTemplate`) and the real client modules
(`ItemClient`, `ItemFX`, `ItemRig`) outside Studio: every remote's validation, buying / loadout /
Robux unlock idempotency (incl. a re-delivered receipt), every item's rules, cleanup on death,
respawn, leaving and shutdown, and the animations on R15 and R6 rigs (joints back exactly afterwards,
the Blender towel inside its clean range). That proves the logic, not the look: everything below
still needs eyes in Studio.

## Studio checklist

1. **Sync** `src/` (Rojo or the MCP). Press Play: Output shows no `[Items]` errors; you have the
   towel (Part towel if the Blender towels aren't imported yet).
2. **Two players** (Test → Clients and Servers, 2 players). Steal a sock with one, snap them with the
   other: swing + whoosh, the crack lands with SNAP!, the thief somersaults, the sock arcs home, a
   tiny shake for the snapper. Snap a non-thief: BOP!, a push, no stun.
3. **The towel in the hand**: points forward out of the fist (if it points backward or up, change
   `GRIP` in `Items/Looks.luau`), droops a little at rest, curls back over the shoulder and cracks
   forward-down (if the whip bends the wrong way, flip `SWING_AXIS` in `ItemRig.luau`). Buy Towel
   Snap levels: Plain → Striped → … → Champion; buy the Golden Towel (test purchase): Royal.
4. **Each item** (unlock with cash or the Studio test purchase, put it in the bar): dash (distance
   feels right?), peel (the other player slips, you don't), bubble (a thief floats up, a non-thief
   bounces), duck (only in your drawer; quacks and the intruder glows red only on your screen),
   cloud (the other player is slow, you aren't), balloon (hops back, spiky hair), basket (only the
   basket shows; everything comes back exactly when you pop out — check name tags and the VIP tag),
   glider (jump off the bed or the nightstand: the canopy sits over the head, you sink slowly and fly
   forward; it ends on landing).
5. **R6**: switch the place to R6 (Game Settings → Avatar) and check the swing, tumble and glide.
6. **Phone** (Device emulator): taps on the bar use items; a tap in the world swings the held towel.
7. **Settings**: Reduce motion (no shake / somersault), Low graphics, Hide others' effects.
8. **Sounds**: give each a listen; swap any that don't fit in `ItemFX.Sounds`.
9. Leave with a peel, duck and cloud out (the other client sees them vanish); die in the basket
   (you respawn visible).

## Paste-ready prompt for Josh's local Claude (Studio open, MCP connected)

```text
Apply the item bar to the open place and test it. The code is in src/ (Rojo layout); docs/ITEMS.md
explains every item. 1) Sync src/server/StealASockServer (Items folder with Looks and Rules, Towel,
Steal, Upgrades, Monetize, Data, Income, init.server), src/client/StealASockClient (ItemClient,
ItemFX, ItemRig and the UI agent's ItemBar files) and src/shared into the place. 2) If
assets/meshes/steal-a-sock/items/*.glb have been imported, make sure they sit in
ReplicatedStorage.ItemMeshes with their exact names (Towel_Plain … Towel_Royal, DashSlippers,
BananaPeel, BubbleBlaster, AlarmDuck, SoftenerBottle, SoftenerPuff, DryerSheet, LaundryBasket,
StaticBalloon). 3) Play with 2 players (Clients and Servers) and go through the "Studio checklist" in
docs/ITEMS.md; read Output for [Items] / [ItemFX] / [ItemRig] warnings. 4) Things to look at closely
and fix if wrong: the towel's orientation in the hand (GRIP in Items/Looks.luau), the whip direction
(SWING_AXIS in ItemRig.luau: flip the sign if it curls the wrong way), the glider canopy height
(CANOPY_Y in Items/Rules.luau), the basket sitting on the floor over the hider, and that every sound
fits. Don't change prices, ids or keys. Report what you changed and anything that still looks off.
```
