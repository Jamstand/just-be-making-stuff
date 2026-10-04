# Items — the Towel Snap and the eight bar items

Everyone has the **Towel Snap** in slot 1 of the item bar. The eight other items are unlocked for
good with cash (Item Shop → Items) or straight away with Robux (one developer product per item), and
a player carries the towel plus up to `ItemConfig.LoadoutSize` (3) of them. Every unlocked item can be
**upgraded 3 times** with cash (Item Shop → Items → Upgrade); the third level turns it **golden**. The
**server decides everything** (cooldowns on its own clock, who gets hit, who slips, who is slowed,
every twist); each client only asks, predicts its own use for feel, and plays the effects.

| File | What it is |
| --- | --- |
| `src/shared/Config/ItemConfig.luau` | every item: key, name, price, cooldown, model, and all the tuning numbers (source of truth) |
| `src/server/StealASockServer/Items/init.luau` | the item bar on the server: unlocks, upgrade levels, loadout, tools, the `UseItem` / `BuyItem` / `SetLoadout` / `UpgradeItem` remotes, cooldowns, speed, knockback, shoves, slides, stun, grace, big moments |
| `src/server/StealASockServer/Items/Rules.luau` | what each item does (with its twist), and the world objects it leaves (peels, guard ducks, clouds, bubbles, baskets, canopies); golden re-skins of live objects |
| `src/server/StealASockServer/Items/Looks.luau` | every item's model: from `ReplicatedStorage.ItemMeshes` (`<model>_Gold` when golden), or a Part build while that model isn't imported; the gold re-colour |
| `src/server/StealASockServer/Towel.luau` | the Towel Snap: who it hits, the held combo finisher, the towel's look per level |
| `src/client/StealASockClient/ItemClient.luau` | the bar's engine (the API `ItemBar` uses): press / release per item, prediction, the balloon's charge, your own dash, air dash, glide and slam |
| `src/client/StealASockClient/ItemFX.luau` | everything you see and hear: bursts, the towel's crack per look, every twist's effect, the sock-home arc, bubbles, slips, honks, sounds |
| `src/client/StealASockClient/ItemRig.luau` | procedural character animation (every item's move with anticipation and follow-through, the combo finisher, tumbles, naps, slams, pounces …) and the towel's whip |
| `src/client/StealASockClient/ItemAim.luau` | the towel's aim assist (touch / gamepad) and the reach arc on the floor |
| `src/client/StealASockClient/ItemBones.luau` | the item models' moving parts (their bones) and the golden sparkle auras |
| `src/client/StealASockClient/ItemMoments.luau` | the big moments on your screen: hit-stop, slow-motion feel, FOV punch, blur / colour pulse |

Other server modules hook in: `Steal.ApplySpeed` multiplies WalkSpeed by `Items.SpeedMult`;
`Steal.TryPickup` / `Claim` / `Return` call `Items.OnCarryChanged` (it pops you out of the basket);
`Upgrades` re-skins the towel on a Towel Snap level; `Monetize.GrantProduct` unlocks items bought
with Robux; `Income.Push` puts `items`, `loadout`, `towelLook`, `itemLevels` and `towelReach` (studs:
the Towel Snap level x the Golden Towel, for the client's aim assist and reach arc) in the StateView.

## The Towel Snap

- **Who it hits:** the nearest **thief** (someone carrying a sock) inside the cone in front of you
  (`TowelCone` = 60° either side, reach = the Towel Snap upgrade, x1.5 with the Royal Towel). With no
  thief in reach, the nearest **other player** in the cone gets a real push: `ShoveMult` (half) of a
  thief's knockback, no stun.
- **A thief:** full knockback + `TowelStunSeconds` stun + a somersault, and the stolen sock flies
  home on an arc (`Steal.Return(…, "snapped")` + the `sockhome` effect). The socks nearby still
  flinch (`S.FX("snap")`).
- **Out and away:** a **tap** on the towel slot, **Q** / **1** or gamepad **Y** takes the towel out
  of your backpack (its slot glows while it's in your hand); another tap puts it away
  (`ItemClient.Press` / `Release` let go within `TAP_MAX`, 0.22 s). A tap in the world with the
  towel in hand (`Tool.Activated`) is one snap.
- **Hold to keep cracking:** **holding** the towel slot, **Q** / **1**, gamepad **Y** (past
  `TAP_MAX`), or the mouse / a finger in the world (at once) keeps snapping, one snap each time the
  1 s cooldown is ready; the first snap of a hold is a tap (`UseItem` held = false), the rest say
  `held = true`, which tells every other client to play the swings as one loop. Letting go stops
  it; so does the window losing focus or respawning.
- **Feel (every client):** an overhead crack on every use, hit or miss — the arm takes the towel up
  and back over the shoulder (it hangs down your back) and lashes it forward to about shoulder
  height, the towel curls back, unrolls from the hand out and comes straight out in front of you
  exactly at the crack (its `Seg1…Seg6` bones, or the Part towel's `Seg1…Seg6` motors), with a
  whoosh. While held, the arm lifts the towel back over the shoulder after each crack (a quick back
  cast), so the next crack starts from up there: one continuous back-and-forth loop. Holding the
  towel between swings, the arm rests lower and the towel hangs and sways. The towel's tip never
  goes into the floor under you (R6's arms, small avatars). On a hit, at the moment of the crack: a crack
  sound, a comic **SNAP!** (BOP! for a shove) with stars and a shockwave ring, and a tiny screen shake
  for the snapper (off with Reduce motion). Your own swing starts the instant you press (prediction);
  everyone else sees it when the server says so.
- **Look:** by Towel Snap level, `ItemConfig.TowelLooks[level + 1]`: Plain → Striped → Beach → Spa
  → Sports → Champion. The Golden Towel pass shows `Royal`. The tool re-skins in your hand the moment
  the level or the pass changes (`Towel.Refresh` → `Items.RefreshTowel`).
- The **aim** sent with `UseItem` is where you clicked / tapped in the world (or where you face when
  you use the bar); it only turns the cone.
- **Combo finisher (server, `Items.TowelCombo`):** every press's first snap is a tap (`UseItem`
  held = false) and starts the count at 1; the held snaps after it (held = true), each within
  `TowelCombo.window` (1.6 s) of the last, count up 2, 3, 1, 2, 3 …; every `TowelCombo.count`-th is a
  **finisher** (so the 3rd crack of a hold): a wider cone (`TowelCombo.cone`, a cos(): about 81°
  either side) and `TowelCombo.knockMult` x the knockback (and knock-up), on a thief or a shove.
  Tapping never builds a combo; a refused use doesn't count (on the server, or in your client's
  prediction). The `swing` FX
  carries `combo` (1..count) and `finisher`; `snap` carries `finisher`. A finisher hit is a big moment
  (`moment` "finisher", strength 1 on a thief, 0.7 on a shove); a plain snap on a thief is one too
  ("snap", 0.5).

## Every item

Every number is read **at the owner's upgrade level**: `Items.Stat(player, key, name)` =
`ItemConfig.Stat(key, level, name)` (cooldowns too). "A towel shove" below = the user's Towel Snap
knockback x `ShoveMult` (`Items.ShoveSpeed`); every push uses `Items.Shove` (it respects ShoveGrace).

| Item | What it does (server), with its twist | Numbers (`ItemConfig`) |
| --- | --- | --- |
| **Slipper Dash** | Your client dashes you forward along the floor (a short `LinearVelocity`); the server approves and times it and everyone sees a trail + dust (`dash`). Shorter while carrying a sock. **Dash bump:** while the dash lasts (`seconds`, + 0.15 s for lag, checked every Heartbeat) anyone within `bumpRadius` of you is bumped once: `bumpMult` x a towel shove (ShoveGrace respected), out of a basket, and a thief drops the sock home (`bump`). **Air dash:** after a dash, `airDashes` more are allowed while you're in the air within 1.2 s, even though the cooldown is running (it isn't restarted). | `Dash = { distance, seconds, carryMult, bumpRadius, bumpMult, airDashes }` |
| **Banana Peel** | Drops a peel on the floor behind you; up to `peels` out at once (the oldest goes), each gone after `lifetime` or after someone slips on it. The **owner never slips**. The next other player over it slips: `slipSeconds` stun, a carried sock goes home, out of a basket, a glide ends. **Peel bowling:** the slipper slides `bowlDistance` studs on the way they were going (the server puts a 0.55 s floor `LinearVelocity` on them; a wall stops it short; `bowl`); anyone within `bowlRadius` of a slide stumbles (tumble + `stumbleSeconds` stun, out of a basket / glide, a thief drops the sock) and slides on too, `chain` levels deep (the slipper is level 1; the last level bowls nobody). Each player once per chain, never the peel's owner, never inside ShoveGrace. A chain of 2+ is a big moment. | `Banana = { lifetime, slipSeconds, radius, peels, bowlDistance, bowlRadius, stumbleSeconds, chain }` |
| **Bubble Blaster** | Fires `shots` bubbles the server flies (`speed`, `range`), fanned out 12° apart. A bubble that hits a wall / furniture **bounces** (reflected, `bounces` times; `bubblebounce`), then pops on the next. It pops on the first player it reaches: a **thief** inside floats up `floatHeight` for `floatSeconds` (can't walk) and the sock goes home (a big moment); anyone else bounces off (`bounceMult` of a thief's knockback). **Every pop splashes:** everyone else within `splashRadius` gets `splashMult` x a towel shove away from it (never the owner). **Homing** (0..1) steers each bubble toward the nearest thief ahead; a bubble that has turned 10° sends its new path (`bubblebounce` with `steer = true`). | `Bubble = { speed, range, radius, floatSeconds, floatHeight, bounceMult, bounces, splashRadius, splashMult, shots, homing }` |
| **Rubber Duck Alarm** | Only inside **your own** drawer; up to `ducks` per player (the oldest goes); gone when you leave. When another player walks in it quacks for everyone (at most every `quackGap`), you get a toast and see them glow red for `highlightSeconds` (only you). **Guard duck:** it waddles toward the nearest intruder inside your drawer at `chaseSpeed`, stopping just short, and back to its spot (facing the opening) when nobody's there. It is one unanchored assembly the server owns (an `ItemRoot` part with an `AlignPosition` "DuckWaddle" and an `AlignOrientation` "DuckTurn"), so it moves smoothly on every client. Within `honkRange` it **honks** every `honkGap` s (`honk`): the intruder slows to `honkSlow` for `honkSeconds`; a thief is revealed to you through walls for `revealSeconds` (`reveal`, you only; two ducks honking together reveal once). `honkStun` > 0 (golden): a thief is stunned that long and the sock goes home, at most once per intruder per `stunGap` s (a big moment). | `Duck = { quackGap, highlightSeconds, ducks, chaseSpeed, honkRange, honkGap, honkSlow, honkSeconds, revealSeconds, honkStun, stunGap }` |
| **Softener Cloud** | Sprays a cloud `distance` in front of you that lasts `lifetime`. **It drifts** the way you aimed at `driftSpeed` (stopping short of walls) and **grows** from `radius` to `growRadius` over its life (its puffs are tweened on the server). Everyone else inside is slow and sleepy (`slowMult`; thieves `thiefSlowMult`); the owner is immune. Speed comes back the moment you leave it or it fades. **Nap:** a thief inside for `napAfter` s in a row (leaving starts it over) nods off: `napSeconds` stun, the sock goes home, character attribute `Napping` (`nap`, a big moment). | `Softener = { distance, radius, lifetime, slowMult, thiefSlowMult, driftSpeed, growRadius, napAfter, napSeconds }` |
| **Static Balloon** | **Hold to rub it** (a press: character attribute `ChargeStart`, no cooldown yet), **let go to ZAP** with charge = elapsed / `chargeSeconds` (0..1); held on, it zaps by itself at full charge `chargeSeconds` + 2 s after the start. The radius grows `radius` → `chargeRadius` and the push 1x → `chargeMult` x a towel shove with the charge: everyone else in range hops back, hair on end for `hairSeconds`; thieves drop the sock home (`zapStun` > 0: and are stunned); hiders pop out. `chainJumps` > 0 (golden): the arc jumps on to that many more players just outside (each within 10 studs of the edge or of someone already zapped, nearest first). A full-charge zap that hits a thief is a big moment. Stunned / floating at the release: no zap, the charge is dropped. The cooldown starts at the zap. | `Balloon = { radius, hairSeconds, chargeSeconds, chargeRadius, chargeMult, chainJumps, zapStun }` |
| **Laundry Basket** | Hide under it for up to `maxSeconds`, shuffling at `speedMult`. Others see only the basket: your body, face, accessories, held tool, name tag, VIP tag and a carried sock are hidden and put back **exactly** when you pop out. **Pounce:** popping out yourself (a press while hidden) makes everyone else within `pounceRadius` jump back (`pounceMult` x a towel shove; `pounce`); `pounceDrop` = 1: thieves drop the sock (a big moment). Every other pop-out is quiet: using any other item, being snapped, zapped, bumped, bowled or slipping, picking up / keeping / dropping a sock, running out of time. The cooldown starts when you pop out. | `Basket = { maxSeconds, speedMult, pounceRadius, pounceMult, pounceDrop }` |
| **Dryer-Sheet Glider** | **From any jump** (whenever you're in the air: rising, or no floor within 0.35 studs under your feet): a dryer-sheet canopy over your head; your client falls at `fallSpeed` and flies forward at `forwardSpeed`, steering with the move keys / thumbstick. Landing ends it (the client tells the server with held = false; the server also notices by itself). `maxSeconds` at most. A knock or a slip ends it. **Glide slam:** a second press mid-glide: your client drives you down at `slamSpeed`; when you land (the client's held = false, or the server sees it, or 0.6 s after the press) a shockwave at your feet (`slam`) shoves everyone else within `slamRadius` (`slamMult` x a towel shove; nobody far below a slam that lands in mid-air); `slamStun` > 0 (golden) also stuns thieves and drops their sock (a big moment). The cooldown starts when it ends. | `Glider = { fallSpeed, forwardSpeed, maxSeconds, slamSpeed, slamRadius, slamMult, slamStun }` |

**Fairness:** nothing can stun-lock anyone — after any push or stun a player can't be pushed,
stunned or slip again for `ShoveGrace` seconds after it ends (a thief can still be snapped: that's
the point of the towel, and they can't be a thief again that fast). Every twist checks it, and keeps
its own guard where it could chain: each player is bumped once per dash and bowled once per chain,
a golden duck stuns an intruder at most once per `stunGap`, a nap needs `napAfter` s in the cloud
again. You can't use items while stunned or floating. Your own peel, bowling chain, bubbles, duck,
cloud, zap, slam and pounce never affect you. Everything a player has going (basket, glide, slam,
charge, dash, slide, bubble, stun, nap, slowness) ends when they die or respawn; their peels, ducks,
clouds and bubbles go when they leave (and they're taken out of everyone else's tables); server
shutdown pops everyone out, drops every charge and clears every world object. Per-player tables are
cleared on `PlayerRemoving`.

## Upgrades and golden items

- `ItemConfig.Levels[key]`: 3 levels per item, each with a cash `price`, a one-line `desc` and the
  numbers it changes (`set`, cumulative). `ItemConfig.Stat(key, level, name)` reads a number at a
  level; `ItemConfig.IsGold(level)` = level >= `MaxLevel` (3). Prices are proposals (Josh's call).
- `UpgradeItem(key)` (Items.luau): unlocked, below the last level, `Data.TrySpend(next level's
  price)` → `profile.Data.itemLevels[key]` = level + 1 → player attribute `Lv_<key>`, the tool and
  every live world object of that item re-skin (`Items.RefreshItem` → `Rules.Restyle`: live objects
  also take the new level's numbers), FX `upgrade { player, key, level, gold }` to everyone,
  Celebrate `"itemUpgrade" { key, display, level, gold }`, a State push. Answers
  `{ ok, level, msg }`; errors (`Already golden!`, `Not enough cash`, …) aren't toasted (the Items
  tab shows them).
- **Golden** (level 3): the tool and the world objects use `<model>_Gold` from ItemMeshes. While that
  model isn't imported, the regular model gets a **gold re-colour** (every visible part gold metal,
  darker where it was dark; a painted mesh loses its texture and SurfaceAppearance; `_Glow` parts,
  `_Outline` and markers stay as they are; attribute `GoldTint` on the model), or the Part build does.
  Tools and world objects carry attributes `Level` and `Gold` (true when golden). The towel has no
  item level (its look follows the Towel Snap upgrade).
- Player attributes `Lv_<key>` = the level of every unlocked item (set on join, unlock and upgrade);
  the clients read numbers with `ItemConfig.Stat(key, Lv_<key>, name)`.

## `UseItem`'s `held`, per item (the client sends, the server interprets)

| Item | `held = true` | `held = false` | `held = nil` (old clients, `Use`) |
| --- | --- | --- | --- |
| Towel | a later snap of a held loop: counts the combo up | a tap / a press's first snap: the combo starts at 1 | a tap |
| Static Balloon | start rubbing it (`ChargeStart`); again while rubbing: nothing | zap now with the charge (nothing charging: ok, nothing) | zap at once (with any charge there is) |
| Glider | a press: start a glide (any jump), or SLAM while gliding | "I landed": a slam lands, else a quiet stop (also when it already ended) | start, or end the glide (the old toggle) |
| Laundry Basket | hide, or pop out **with a pounce** while hidden | nothing | as true |
| Slipper Dash | a dash (an air dash while the cooldown runs) | nothing | as true |
| everything else | use it once | nothing | use it once |

A release (`held = false`, not the towel) has its own rate limit (`useItem:<key>:up`), so a quick tap
(a press and a release within 0.12 s) works.

## Big moments

`moment { kind, position, by: Player?, targets: { Player }, strength: 0..1 }` to everyone (ItemFX
plays the hit-stop / slow-motion / shake for `by` and the targets, the burst for everyone else).
A towel snap's messages (`swing`, `snap`, `sockhome`, `tumble`, `moment`) all arrive as the swing
starts; each client holds the victim's tumble, their sock's arc home and the moment until that
towel's crack (`CRACK_T` / `CRACK_FINISHER` after the swing began on that screen), the way `snap`'s
burst already waited. The server's knockback itself is not delayed (it pushes at once).

| `kind` | When | strength |
| --- | --- | --- |
| `finisher` | a towel combo finisher hits (target: who it hit) | 1 on a thief, 0.7 on a shove |
| `snap` | a plain towel snap on a thief | 0.5 |
| `bubble` | a bubble catches a thief | 0.6 |
| `nap` | a thief nods off in a cloud (`by` = the cloud's owner) | 0.6 |
| `slam` | a golden slam hits anyone (targets: everyone it hit) | 0.8 |
| `honk` | a golden duck's honk stuns a thief (`by` = the duck's owner) | 0.7 |
| `zap` | a full-charge zap hits a thief (targets: the thieves) | 0.9 |
| `bowl` | a peel bowling chain reaches 2 players (once per chain; `by` = the peel's owner) | 0.6 |
| `pounce` | a pounce makes a thief drop the sock (targets: those thieves) | 0.7 |

## Saved data and what the clients read

- `profile.Data.items` — `{ [key] = true }` (the towel is everyone's, never stored).
  `profile.Data.loadout` — exactly `LoadoutSize` strings, `""` = empty slot (no gaps).
  `profile.Data.itemLevels` — `{ [key] = 1..MaxLevel }` (absent = 0). All three have defaults in
  `Data.luau`'s TEMPLATE (migration: new fields; old profiles get `{}`, `{ "", "", "" }` and `{}`).
  A bad saved loadout is cleaned on read (unknown, locked or repeated keys → `""`); a bad saved level
  reads as 0 (not a number, or a locked item) or is clamped to 0..MaxLevel.
- Player attributes: `CD_<key>` = server time that item is ready again; `Active_<key>` = a glide,
  basket, duck or peel is out; `Lv_<key>` = the upgrade level of every unlocked item.
- Character attributes: `Item` (held key), `Gliding`, `InBasket`, `Encased`, `StunUntil`,
  `HairUpUntil`, `SoftenedUntil`, `ChargeStart` (rubbing the Static Balloon since), `Napping` (asleep
  in a cloud until) (server times).
- Tool and world-object attributes: `Level`, `Gold` (true at the golden level), `GoldTint` on a model
  re-coloured gold (no `<model>_Gold` imported yet).
- World objects in `workspace.StealASock.Items` (all with `OwnerId` where they have an owner):
  `BananaPeel_<UserId>` (one per peel: two can share the name), `AlarmDuck_<UserId>` (one per duck:
  an unanchored assembly on its `ItemRoot`, see the guard duck), `SoftenerCloud_<UserId>`,
  `Basket_<UserId>` (on a `BasketJoint` motor each client wobbles), `Glider_<UserId>`,
  `Bubble_<UserId>`.

## Remotes

Every handler: refuses while starting up, checks every argument's type, rate-limits per player,
answers a `Types.Result`, never errors at a client. Refusals of `UseItem` are toasted (at most one a
second; the bar only shakes); the Item Shop shows `BuyItem` / `SetLoadout` errors itself.

| Remote | Arguments | Rules |
| --- | --- | --- |
| `UseItem` | `key`, `aim?` (horizontal, finite, non-zero), `held?` (boolean, per item: see the `held` table) | the towel, or unlocked AND in the bar; not cooling down (server clock; an air dash is the exception); not stunned / floating; 0.12 s per item (releases counted apart). Answers `{ ok, err?, cooldownUntil?, msg? }` (`cooldownUntil` 0 = ready / not started yet). A press while gliding slams, while hidden pounces. |
| `BuyItem` | `key` | not the towel, not already unlocked, enough cash (`Data.TrySpend`); celebrates `"item" { key, display }`; fills the first empty bar slot. 0.25 s. |
| `SetLoadout` | `{ keys }` | at most `LoadoutSize` entries at indices 1…LoadoutSize, strings only, `""` allowed, unlocked, no repeats, no towel. 0.25 s. Items leaving the bar stop (glide, basket, a balloon charge). |
| `UpgradeItem` | `key` | an item with levels (not the towel), unlocked, below `MaxLevel`, enough cash for the next level (`Data.TrySpend`). 0.25 s. Answers `{ ok, err?, level?, msg? }` (not toasted). |
| `StorePurchase("product", "Item_<Key>")` | (Monetize) | refused when that item is already unlocked; the grant (`Monetize.GrantProduct`) calls `Items.Unlock` (a second grant just says "already unlocked" — never an error, so a re-delivered receipt can't loop). |

`ItemFX` (server → clients, `(kind, data)`; all players unless noted): `swing { player, key, look,
hit, held, combo, finisher }`, `snap { position, by, target, thief, look, finisher }`,
`tumble { player, dir, seconds, soft? }`, `sockhome { thief, from, to, color, uid }`,
`use { player, key, position?, out? }`, `dash { player }`, `bump { player, target, position }`,
`slip { player, position, seconds }`, `bowl { player, from, to }`,
`bubble { id, from, dir, speed, range, by, bounces }`, `bubblebounce { id, position, dir, steer? }`
(`steer = true`: a homing turn, not a wall), `bubblepop { id, position, splash }`,
`encase { player, seconds }`, `quack { position, owner }`, `intruder { player, seconds }` (the duck's
owner only), `honk { duck, position, target }`, `reveal { target, seconds }` (the duck's owner
only), `spray { player, position, radius, seconds, dir, driftSpeed, to, growRadius }`,
`nap { player, seconds }`, `slam { player, position, radius, gold }`, `pounce { player, position,
radius }`, `zap { player, position, radius, charge, chain }` (`chain` = the players the golden arc
jumped to), `moment { kind, position, by, targets, strength }` (see Big moments),
`upgrade { player, key, level, gold }`.

## ItemClient (the bar's engine — the contract with ItemBar)

```lua
ItemClient.Press(key, source?)      -- a button / key / click goes down (source tells holds apart: a KeyCode,
ItemClient.Release(key, source?)    --   a touch's InputObject, "mouse", "tool" = a click in the world); per item below
ItemClient.Use(key)                 -- a quick press + release (the towel: one tap-snap, which resets its combo)
ItemClient.Hold(key?)               -- hold that item's tool (nil = put it away); a click / tap in the world then presses it
ItemClient.Held(): string?
ItemClient.CooldownUntil(key): number   -- server time it's ready again (0 = ready)
ItemClient.CooldownLength(key): number  -- seconds of that cooldown at the item's level (for the ring)
ItemClient.IsActive(key): boolean       -- Glider gliding, Basket hiding, a Duck or Peel out, the Balloon charging
ItemClient.Charge(key): number          -- 0..1 while the Static Balloon charges, else 0 (the bar's charge ring)
ItemClient.Level(key): number           -- the item's upgrade level (player attribute Lv_<key>; 0 = none)
ItemClient.Changed: RBXScriptSignal     -- (key) cooldown / active / held / charge start or end / Lv_ changed (also when a cooldown ends)
ItemClient.Failed: RBXScriptSignal      -- (key, err) the server said no (it also toasts why)
ItemClient.SetState(state)              -- the StateView (init.client passes it; the towel's reach for the aim help)
ItemClient.Init()                       -- runs on require; calling it again does nothing
```

Requiring it starts `ItemFX` (and `ItemRig`, `ItemBones`, `ItemMoments`) and `ItemAim`. A use is
predicted at once (cooldown, swing, pose, whoosh, the dash, the charge) and corrected by the
server's answer; a refused use rolls the cooldown back and fires `Failed`. **A press that does
nothing** (cooling down, already busy, the balloon already charging, a slam already on its way) **is
silent**: no remote call, no `Failed` — so the bar can always send `Press`. Every number (dash
distance, glide speeds, slam speed, charge time, cooldowns) is read at your level with
`ItemConfig.Stat(key, Lv_<key>, name)`.

**Press / release per item** (what `UseItem`'s `held` carries — see the table above):

| Item | Press | Release |
| --- | --- | --- |
| Towel | the slot / a key: the towel comes out at once; let go within `TAP_MAX` (0.22 s) and that was a tap (out - or, if it was already out, put away on the release), held longer it starts the loop: a snap (a tap, `held = false`) and one every cooldown while any source holds it (`held = true`, the combo); your predicted swing is the finisher on every 3rd crack of a hold. A click in the world (`"tool"`) starts the loop at once. Stunned or in a bubble: no swing (the bar shakes once per press); held, it cracks the moment you can | a tap: toggled; a hold: the loop ends when every source let go |
| Static Balloon | starts rubbing it (`held = true`): `Charge` rises 0 → 1 over `chargeSeconds` (from the character's `ChargeStart` once the server answers), the rubbing pose, crackles | zaps now (`held = false`) with the charge; a release before the press's answer is queued and sent right after it. If the server zaps by itself (full + 2 s) the charge just ends (no release is sent) |
| Glider | in the air: glide (`held = true`); gliding: **SLAM** (`held = true`) — you're driven down at `slamSpeed` with a dive pose | — (landing sends `held = false`, which also lands a slam at once) |
| Slipper Dash | a dash; within 1.2 s of a dash and in the air, `airDashes` more although the cooldown runs | — |
| Laundry Basket | hide; hidden: pop out with a pounce (`held = true`, the pounce pose at once) | — |
| everything else | use it once | — |

**Towel aim (ItemAim).** On touch screens and gamepads (the press's source: a touch InputObject or a
gamepad KeyCode; for a click in the world or `Use`, the last input type) a snap turns you to the
nearest target in reach — a thief first, else the nearest other player — within
`ItemConfig.TowelAssistCone` of where you face (or tapped), and sends that as `aim`. Mouse and
keyboard aim where you face / click. The reach is the State's `towelReach` (else the Towel Snap
level's reach from `ShopConfig` x `StoreConfig.GoldenTowelMult` with the Golden Towel). While you
hold the towel (every platform) a faint dotted arc on the floor in front of you shows the cone
(`TowelCone`) and the reach: red while a thief is inside, wider and gold when your next held crack is
the finisher (`TowelCombo.cone`), and it pulses bright on the finisher crack. It's 19 pooled flat
Neon parts in your camera (only you see it), moved every frame, on the floor under you (one raycast).

## Animation (ItemRig)

Poses are written into the characters' `Motor6D.Transform` on `RunService.Stepped`, which runs after
the Animator each frame, so they lie on top of the default Animate script (walk, idle, toolnone) and
never fight it; when a move ends the Animator's pose is back (if no animation drives a joint, the
pose it had is put back). Moves are rotations in the character's own axes about each joint, so R15
and R6 share them (R6 has no elbows or waist). The tumble spins the visual body about the root joint
— the physics root never turns. Other players' characters are animated on every client; beyond 160
studs the moves are skipped. A held towel droops and sways within 70 studs; every client starts
animating someone's towel as soon as `Item_Towel` is in their character (or their `Item` attribute
says Towel).

The **towel whip** bends `Seg1…Seg6` about one axis in the handle's space (tip down = positive, with
a little sideways sweep): it curls back for `WIND` (0.12 s), unrolls from the handle to the tip (each
segment over half the lash, a beat after the one before) so the tip comes straight exactly at the
crack (`CRACK` 0.22 s, `CRACK_F` 0.32 s for the finisher), wobbles and settles into the droop (or,
held, flies back over the shoulder with the arm for the next crack, `LIFT_TIME`). **Floor guard:**
every frame the towel's tip height is worked out from the handle and the bends; if it would come
within `FLOOR_GAP` (0.5 studs) of the floor under the character's feet, the bends are straightened
toward the hand's line just enough, and if even a straight towel would reach the floor, its far end
curls up off it. On the Blender towel (a flat cloth) `Seg1` is the end gathered in the fist, so it stays nearly rigid, and
every joint is kept inside 45° (75° for `Seg5` / `Seg6`); the cloth itself bends cleanly to ~120°
across it but only ~20° sideways.

**Items v2 moves.** Every item move has an anticipation (a small wind-up the other way) and a
follow-through (an overshoot that settles): `place` lifts the arm before reaching down, `shoot` pulls
back before the recoil, `spray` squeezes before pumping, `zap` crouches before thrusting the balloon up
(higher with more charge), `dash` leans back for a blink before lunging and skids at the end. New:
`charge` (persistent: rubbing the balloon on your head, faster and buzzier as it charges), `dive` (the
slam on the way down: tucked, arms up) and `land` (the slam's squat), `pounce` (crouch, spring out of
the basket with the arms up), `bowl` (bowled over by a sliding peel-slipper: sliding on your bottom,
arms windmilling), `startle` (honked at), `cheer` (an item upgraded: held up high), `nap` (nodding off).
The **combo finisher** is the swing with `{ finisher = true }`: a wind-up over the shoulder with the
shoulders turned away to the right and a lean back (`WIND_F` 0.2 s), a lash across the body with a
twist through the waist and hips to the left, cracking a little left of straight ahead at `CRACK_F`
(0.32 s), a held follow-through; the towel curls back deeper and cracks with a
bigger wobble. The rigs run on their own clock: big moments freeze it for the hit-stop and slow it
for the slow-motion feel (`ItemRig.SetTimeScale`, only on that screen, only the look).

## Client: effects, moving parts and big moments (Items v2)

*(The client agent's part of this doc: `ItemFX`, `ItemBones`, `ItemMoments`, `ItemAim`.)*

**What each FX kind looks like** (every one also runs on R6, with or without the Blender models):

| Kind | On every client |
| --- | --- |
| `swing` (+ `combo`, `finisher`) | the swing (the finisher swing on `finisher`), a whoosh (lower for the finisher), the look's crack effect at the towel's tip as it cracks; a finisher that missed still bursts **SUPER SNAP!** with a ring. Your own echo only keeps the predicted combo in step. |
| `snap` (+ `finisher`) | the bigger crack: SNAP! / BOP! (**SUPER SNAP!** on a finisher, bigger), a ring shockwave on the floor, cloth fibres in the look's colour; the finisher's stinger. A thief snap by you: a 0.06 s hit-stop and a little FOV kick. |
| per look (`look`) | Plain water droplets, Striped red / blue streamer ribbons, Beach a sand spray, Spa soap bubbles that float up and pop, Sports confetti, Champion gold stars, Royal tiny 👑 crowns + gold sparkles and a gold sparkle trail on every swing (any look gets a streak on the finisher) |
| `bump` | BUMP! (gold for golden slippers), a puff and a small ring; the bumped player's camera shakes |
| `bowl` | the slipper slides on their bottom (`bowl` move), dust along the slide, the peel's flaps flop, BOWLED! where it stops |
| `bubble` (same `id` again = a path update), `bubblebounce` | the bubble flies on from the bounce point (a squash and a soft click; `steer = true`: a homing turn, quietly); a golden blaster's bubbles are tinted gold |
| `bubblepop` (+ `splash`) | pop, sparkles; with a splash: a soapy ring of that radius and droplets |
| `honk` | HONK!, two sound-wave rings, the duck's siren blinks, its bill opens and its head turns to the target (bones); the target jumps (`startle`) |
| `reveal` (owner only) | the thief glows yellow through walls for `seconds` (one Highlight, shared with the intruder glow), SPOTTED! |
| `nap` / `Napping` | the `nap` move, Zzz over the head, a lilac puff, a sleepy chime |
| `slam` | rings of the slam radius (gold when `gold`), dust in a circle, SLAM!, the `land` squat; shakes everyone inside the radius |
| `pounce` | the `pounce` move (yours is predicted), a ring of the radius, POUNCE! |
| `zap` (+ `charge`, `radius`, `chain`) | a ring as wide as the zap, more sparks and a bigger ZAP! with the charge (MEGA ZAP! when full), crackling lightning arcs hopping to each `chain` player; others' balloons stop being rubbed |
| `ChargeStart` | others: the rubbing pose, crackling sparks around the balloon, a rising charge sound, the balloon's bones jiggle and lift with the charge |
| `moment` | everyone: a gold starburst and ring at `position`. `by` and the targets: the big moment (below) |
| `upgrade` | that player cheers with the item up; LEVEL n! sparkles, or GOLDEN! with a gold ring and lots of gold stars at level 3 |

**Big moments (ItemMoments).** On the screens of `by` and each target only: a hit-stop (the item
animations freeze ~0.1 s, the effects nearly), then ~0.6 s of slow motion (the camera's FieldOfView
punches in up to 9° and eases back, our own `ItemMomentBlur` / `ItemMomentColor` effects in Lighting
pulse, the item effects and animations run at ~0.35–0.4x and catch up), a deep whoosh and a strong
shake (stronger for the victim). **Reduce motion**: none of that — a quick soft brightness flash.
The FieldOfView is put back exactly afterwards; if something else changes it meanwhile, that wins.
Nothing touches anyone's physics.

**Moving parts (ItemBones).** The item models' bones (the Blender kit's skeletons; `Root` is the
grip / floor point and never moves) are animated by name through `Bone.Transform` (local, nothing
replicates) for items within 80 studs:

| Model (+ `_Gold`) | Bones it moves |
| --- | --- |
| `BananaPeel` | `Stem`, `Flap1` … `Flap4` |
| `BubbleBlaster` | `Trigger`, `Ring`, `Tank` |
| `AlarmDuck` | `Body`, `Head` (child of Body), `Bill` (child of Head), `Tail` |
| `SoftenerBottle` | `Trigger` |
| `DashSlippers` | `Ribbon`, `SlipperL`, `SlipperR`, `WingL`, `WingR` |
| `DryerSheet` | `Canopy`, `Corner1` … `Corner4` |
| `LaundryBasket` | `Top` |
| `StaticBalloon` | `String1` … `String3`, `Balloon` |

In short: the peel's flaps flop when it
lands or is slipped on and quiver at rest (in the hand they dangle); the blaster's trigger pulls and
its ring spins and wobbles on each shot, the soap tank sloshes; the guard duck waddles while it moves
(Body rocks and bobs), turns its Head to the intruder, opens its Bill on honks and quacks, waggles its
Tail; the softener's trigger pumps while spraying; the slippers swing and their heel wings flap on a
dash; the glider's canopy ripples and its corners flap; the basket's Top squashes and stretches as
the hider shuffles (and bounces on a pounce while it still exists); the balloon's string sways and the
balloon bobs, lifting and jiggling as it charges, with a recoil on the zap. Moves are given in the
model's axes (or along each bone: "bend" lifts a bone's tip) and converted per bone once, so a bone's
roll doesn't matter. `_Gold` models share the bones. **No bones** (the Part builds, models not
imported yet): no moving parts, everything else works.

**Golden auras.** A golden tool in a hand (attribute `Gold`, or `Level` ≥ 3, or the holder's
`Lv_<key>`) and a golden world object get a soft gold sparkle aura: one ParticleEmitter each, made
once (`ItemGoldAura`, kept on the Handle / model), on only within 80 studs, 16 at most, half the rate
with Low graphics, off while the holder hides in the basket or the sheet is up as a canopy. Effects of
golden items are tinted gold (dash trail, bump, bubbles, spray, slam, pounce, zap, honk).

**Performance.** Everything is pooled: bursts (6), floor rings (12), lightning arcs (6 x 6 parts),
soap bubbles and crowns (24), one emitter per particle kind, three voices per sound name; nothing
is made per frame (the arc and the bones only move what exists). Other players' effects farther
than 30 studs are hidden with Hide others' effects. One Highlight per revealed / intruding player
(owner only) — the socks and towels keep the rest of Roblox's 31.

## Models (`ReplicatedStorage.ItemMeshes`, from `tools/blender/items`)

| Name | Used as | If it's missing |
| --- | --- | --- |
| `Towel_Plain` … `Towel_Champion`, `Towel_Royal` | the towel in your hand (by look): a flat bath towel held at one end, with NO outline mesh (a painted ink edge, plus a Highlight outline on the nearest 6 held towels, 3 with Low graphics) | a flat Part towel in the look's colours, with Motor6D segments that whip the same way |
| `DashSlippers`, `BananaPeel`, `BubbleBlaster`, `AlarmDuck`, `SoftenerBottle`, `StaticBalloon`, `DryerSheet`, `LaundryBasket` | the held tools (the basket at 0.32 scale) | Part builds of each |
| `BananaPeel`, `AlarmDuck`, `SoftenerPuff`, `DryerSheet`, `LaundryBasket` | the world objects (peel, duck, cloud puffs, canopy, basket over a hider) | Part builds |
| `<Name>_Gold` of each non-towel model above (markers `<Name>_Gold_Base` …, `AlarmDuck_Gold_Glow`) | the golden (level 3) tools and world objects | the regular model (or Part build) re-coloured gold |

The server never anchors, moves or removes a model's bones (each client animates them); the guard
duck is welded to an invisible `ItemRoot` and moved by its `AlignPosition`.

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
`economy.roblox.com/v2/assets/<id>/details` on 2026-10-03 (the Items v2 ones, from `slam` down, on
2026-10-04). Positional (8–70 studs, three voices per sound), at most 10 a
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
| slam | 16480557599 | Audio/Roblox_Pinball_Joystick_Slam_01 | the glide slam's shockwave |
| bump | 16480574637 | Audio/Roblox_Pinball_Bumper_Full_01 | a dash bump |
| slide | 16480576404 | Audio/Roblox_Pinball_Ball_Plastic_Slide_01 | bowled over, sliding along |
| charge | 16480578169 | Audio/Roblox_Pinball_8Bit_Riser_01 | rubbing the Static Balloon (a quiet riser) |
| honk | 99631809815420 | BirdHello_02 (lowered) | the guard duck's honk |
| sparkle | 17208327798 | Roblox GUI - Aura | an item upgraded / turned golden |
| nap | 15675081158 | Roblox_UI_Cute_Goodbye (lowered) | a thief nods off in a cloud |
| whooshDeep | 15675028888 | Roblox_UI_Whoosh_02 (low) | a big moment's slow-motion whoosh (only you, not positional) |
| bounce | 16480568821 | Audio/Roblox_Pinball_Bumper_Soft_Click_01 | a bubble bounces off a wall |
| stinger | 15675043410 | Roblox_UI_Tonal_Stinger | the towel's combo finisher (SUPER SNAP!) |

## Settings

**Reduce motion**: no screen shake, no somersaults (a wobble instead), a smaller slip, bowl and basket
wobble, no FOV kick on a snap, and big moments are a quick soft flash (no hit-stop, slow motion, FOV,
blur or shake). **Low graphics**: half the particles, half the soap bubbles / crowns, half-rate
golden auras. **Hide others' effects**: no bursts, puffs, bubbles, cracks, rings or trails from other
players farther than 30 studs (the sock-home arc and your own effects always show).
**Sound effects**: every item sound.

## Tuning knobs

- Everything gameplay is in `ItemConfig` (cash prices and Robux prices are Josh's call).
- Towel reach / knockback / stun: `EconomyConfig` (`TowelRange`, `TowelKnockback`, `TowelKnockUp`,
  `TowelStunSeconds`), `ShopConfig` (Towel Snap levels), `StoreConfig.GoldenTowelMult`.
- Upgrade levels: `ItemConfig.Levels` (prices are Josh's call), `MaxLevel`; the combo:
  `ItemConfig.TowelCombo`.
- `Items/init.luau`: `USE_GAP` (0.12 s per item), `MENU_GAP`, `TICK` (0.1 s rule checks).
- `Items/Rules.luau`: `CANOPY_Y` (glider canopy height), `BUBBLE_BODY`, `FLOAT_RISE`, `CLOUD_FADE`,
  `SOFT_LINGER`, `GLIDE_LAND`, `AIR_EPS` (how high counts as "in the air"), `AIR_DASH_WINDOW` (1.2 s),
  `DASH_SLACK`, `SLIDE_SECONDS` (peel bowling slide), `BUBBLE_FAN` (12°), `HOMING_TURN`,
  `STEER_UPDATE`, `DUCK_STOP` (how close a duck gets), `SLAM_WAIT` (0.6 s), `AUTO_ZAP` (2 s),
  `CHAIN_HOP` (10 studs a golden arc jumps).
- `Items/Looks.luau`: `GRIP` (how every item sits in the hand), `CARRY_BASKET`, the Part towels'
  colours (`TOWELS`), the gold re-colour (`GOLD_DARK`, `GOLD_LIGHT`, `GOLD_SHINE`).
- `ItemRig.luau`: `WIND`, `CRACK`, `LIFT`, `LIFT_TIME`, `DROOP`, `FLOOR_GAP`, `SWING_AXIS` (flip its
  sign if the towel whips the wrong way), `BONE_WEIGHT` / `BONE_LIMIT`, every move's keyframes (the
  swing: `SWING_UP` / `SWING_DOWN` / `SWING_FOLLOW`; the finisher: `FIN_UP` / `FIN_DOWN` /
  `FIN_FOLLOW`, `WIND_F`, `CRACK_F`, `LIFT_F`), `RANGE`. The swing poses go on top of Roblox's
  tool-hold arm (level, in front): a crack arm more than a little below level puts the towel into
  the floor, and an `x` past ~2.4 on a wind-up throws the arm down your back.
- `ItemFX.luau`: `ItemFX.Sounds`, `CRACK_T` / `CRACK_FINISHER` (when the burst lands after a swing),
  `LOOK_COLORS`, `GOLD`, `SOUND_RANGE`, `HIDE_OTHERS_RANGE`, `PROP_RANGE`, `RINGS_MAX`, `FLOATIES_MAX`.
- `ItemAim.luau`: the reach arc (`EDGE` / `SIDE` dashes, `FAINT`, `PULSE`, its colours).
- `ItemMoments.luau`: `HIT_STOP`, `SLOW`, `RIG_SLOW`, `FX_SLOW`, `FOV_PUNCH`, `BLUR`, `FLASH`, `KICK`.
- `ItemBones.luau`: each model's moves (`MOVES`), `RANGE`, `AURA_MAX`, `AURA_RATE`.

## Tested headless

A mock of the Roblox API runs the real server modules (`Items`, `Looks`, `Rules`, `Towel`, `Steal`,
`Upgrades`, `Monetize`, `Data`, `Income`, `RateLimit`, `MeshTemplate`) and the real client modules
(`ItemClient`, `ItemFX`, `ItemRig`) outside Studio: every remote's validation, buying / loadout /
Robux unlock idempotency (incl. a re-delivered receipt), `UpgradeItem` (validation, prices, levels
1–3, the golden re-skin of tools and of every kind of live world object, `Lv_` / `Level` / `Gold`,
Celebrate, imported `_Gold` models and the gold re-colour), every number read at its level, every
item's rules and twist (bumps and air dashes, bowling chains and their depth, bounces / splashes /
fans / homing, the guard duck's chase, honks, reveal and golden stun, cloud drift / growth / naps,
slams, pounces, charged and chained zaps), the towel combo, every big moment, cleanup on death,
respawn, leaving and shutdown, and the animations on R15 and R6 rigs (joints back exactly afterwards,
the Blender towel inside its clean range). That proves the logic, not the look: everything below
still needs eyes in Studio (the duck's waddle physics, slides, server tweens, the gold re-colour).

Client (Items v2, `scratchpad/itemtest-c`: `python3 gen.py && ./luau run_client.luau`, 414 checks)
also runs `ItemAim`, `ItemBones` and `ItemMoments`: every press / release (the balloon's charge 0 → 1,
an early release, the server's own zap, a refused press, `Use`; glide, slam and the landing `false`;
air dashes; the basket's pounce press; silence while cooling down), `Charge` / `Level`, the aim assist
(the right target, only on touch / gamepad, reach from the State), the reach arc (shown / red / gold
/ pulse / gone), the finisher swing, every look's crack, every new FX kind with good and bad data on
R15 and R6 around boned and bone-less models, the big moments (only `by` / targets, FOV and blur back
exactly, a stronger shake for the victim, Reduce motion = a flash), the moving parts and golden auras,
and no live instance growth over repeated rounds of every effect; the towel's wiring: a snap's
tumble, sock arc and big moment waiting for the crack (others' and your own), taps going as taps,
a refused snap not counted, no swing while stunned or in a bubble (held: it cracks when you can);
the towel slot: a tap takes the towel out (no snap, `IsActive`, Changed) and another puts it away,
`Use` toggles, a press held past `TAP_MAX` snaps (the first as a tap) and keeps snapping, and the
towel stays out after a hold.

**Towel motion** (a kinematics sim, `scratchpad/towelsim`: `./gen.sh && ../itemtest-c/luau run.luau`,
116 checks): the real `ItemRig` drives an R15 and an R6 stand-in (Roblox's joint offsets, the
Animator's tool-hold arm written before each Stepped) holding the Blender towel (the bones exactly
as in `Towel_Plain.glb`) and the Part towel, at 60 fps; the engine's sums (`Part0 * C0 * Transform *
C1:Inverse()`, the grip, bone chains) place everything, and it checks where the hand and the towel's
tip are: hanging in front at rest, up and over the shoulder in the wind-up, straight out in front at
the crack, back over the shoulder between held cracks, the finisher's twist cracking in front,
settling back after a tap, never into the floor, no jumps away from the crack, and a press during
the cooldown leaves the towel hanging (the arm is down too).
A towel with a second skeleton (an outline hull) must move exactly like one.
`render_frames.py` (Blender) renders the frames with the real skinned towel, side and 3/4 views.

## Studio checklist

1. **Sync** `src/` (Rojo or the MCP). Press Play: Output shows no `[Items]` errors; tap the towel
   slot (or 1 / Q): the towel comes out and the slot glows; tap again: it goes away (Part towel if
   the Blender towels aren't imported yet).
2. **Two players** (Test → Clients and Servers, 2 players). Steal a sock with one, snap them with the
   other: swing + whoosh, the crack lands with SNAP!, the thief somersaults, the sock arcs home, a
   tiny shake for the snapper. Snap a non-thief: BOP!, a push, no stun.
3. **The towel in the hand**: points forward out of the fist (if it points backward or up, change
   `GRIP` in `Items/Looks.luau`), the arm rests a little lower than level and the towel hangs from
   the hand the moment you equip it (before any swing), the swing goes up and back over the shoulder
   and cracks straight out in front of you at about chest height, never into the floor (if the whip
   bends the wrong way, flip `SWING_AXIS` in `ItemRig.luau`). Hold it: crack, back over the
   shoulder, crack … and every 3rd is the finisher, twisting across to the front-left. Buy Towel
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
10. **Upgrades and twists** (give yourself cash, two players): upgrade an item 3 times with a peel /
    duck / cloud / basket / canopy out — it turns golden in place (a gold re-colour until the
    `_Gold` models are imported). Dash into the other player (they're bumped; a thief drops the
    sock), dash again in the air. Slip them on a peel with a third player in the way (they bowl over).
    Bounce a bubble off a wall; with three bubbles, see the fan. Walk into the duck's drawer: it
    should **waddle smoothly** after you (not stutter or sink; it's server physics on an
    `AlignPosition`), honk and slow you. Stand in a cloud with a sock until you nod off; the cloud
    drifts and grows. Glide from a plain jump, press again to slam. Pop out of the basket next to
    someone (pounce). Hold the balloon for 2 s and let go (a bigger zap); hold it 4 s (it zaps by
    itself). Hold the towel on someone at the edge of your cone: every 3rd crack reaches them.
11. **Client feel (Items v2)**: hold the towel: the faint arc on the floor (red with a thief inside,
    gold before the 3rd held crack, a pulse on it); the finisher's big swing and SUPER SNAP!; each
    towel look's crack (Plain … Royal; Royal's gold trail and crowns). On a phone (Device emulator)
    and with a gamepad, snaps turn to the nearest thief in reach. A big moment (finisher hit, bubble
    catch, golden slam …): the short freeze and slow motion feel good, not sickening, for the snapper
    and the victim; with Reduce motion only a flash. Charge the balloon (its rub pose and crackles,
    the bar's ring), slam, air dash, pounce. When the Blender models with bones are in: the moving
    parts read right (if a part bends the wrong way, flip that move's sign in `ItemBones.MOVES`), and
    the `_Gold` ones sparkle.

## Paste-ready prompt for Josh's local Claude (Studio open, MCP connected)

```text
Apply the item bar to the open place and test it. The code is in src/ (Rojo layout); docs/ITEMS.md
explains every item. 1) Sync src/server/StealASockServer (Items folder with Looks and Rules, Towel,
Steal, Upgrades, Monetize, Data, Income, init.server), src/client/StealASockClient (ItemClient,
ItemFX, ItemRig, ItemAim, ItemBones, ItemMoments and the UI agent's ItemBar files) and src/shared into the place. 2) Import
assets/meshes/steal-a-sock/items/*.glb (File → Import 3D, untick Merge Meshes, keep the rig / pick
Custom if a Rig Type is shown) and put them in ReplicatedStorage.ItemMeshes with their exact names,
replacing any older model of the same name: Towel_Plain … Towel_Royal, DashSlippers, BananaPeel,
BubbleBlaster, AlarmDuck, SoftenerBottle, SoftenerPuff, DryerSheet, LaundryBasket, StaticBalloon,
and the golden twins <Name>_Gold of the nine non-towel ones (DashSlippers_Gold … StaticBalloon_Gold).
Each rigged model should keep its Bones (e.g. AlarmDuck: Root, Body, Head, Bill, Tail). 3) Play with 2 players (Clients and Servers) and go through the "Studio checklist" in
docs/ITEMS.md; read Output for [Items] / [ItemFX] / [ItemRig] warnings. 4) Things to look at closely
and fix if wrong: the towel's orientation in the hand (GRIP in Items/Looks.luau), the whip direction
(SWING_AXIS in ItemRig.luau: flip the sign if it curls the wrong way), the glider canopy height
(CANOPY_Y in Items/Rules.luau), the basket sitting on the floor over the hider, and that every sound
fits. Don't change prices, ids or keys. Report what you changed and anything that still looks off.
```
