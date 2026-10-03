# Steal a Sock — UI, Shop, Store and Settings

Everything on screen is built by code (no image assets yet). The look follows
`docs/concept/ui_style.png`: cream candy panels with thick plum outlines, coral titles, a gold cash
pill and glossy candy buttons. The motion is "playful yet stylish": panels glide and fade, buttons and
rewards spring with a little overshoot, and big moments get coins, number pops and confetti.

## What's on screen

| Where | What | Module |
| --- | --- | --- |
| Top-left | Cash pill (rolling number, coins fly in when you earn), income, drawer lock, cash waiting on your pad | `HUD.luau` |
| Left column | Drawer · Shop · Store · Sockdex · Settings buttons (red bubbles when something needs you: an affordable upgrade or item, new Sockdex finds or a claimable milestone, Rare Sock Drops waiting for a slot) | `Menu.luau` |
| Next to the column | Your drawer list (tap a sock for its card) | `HUD.luau` |
| Top-centre | Server Luck timer, server announcements; toasts and big celebration cards sit on their own top layer (`SockHUDTop`) so they show over open menus | `HUD.luau` |
| Bottom-centre | The item bar: your towel + 3 items (replaces Roblox's hotbar) | `ItemBar.luau` |
| Just above the item bar | "Carrying ..." banner while you run with a stolen sock | `HUD.luau` |
| Centre (panels) | Item Shop (Upgrades and Items tabs), Store, Sockdex, Settings; sock card pop-up; the item bar's slot picker | `ShopUI`, `StoreUI`, `DexUI`, `SettingsUI`, `SockCard` |

The UI kit every screen uses: `Theme.luau` (colours, fonts, candy factories, screen scaling),
`Anim.luau` (all motion), `UISound.luau` (all UI sounds), `ClientSettings.luau` (the player's
settings), `Menu.luau` (the column and the one-panel-at-a-time manager). Sizes are in reference
pixels for a 720 px tall screen; phones scale everything by about 0.72, so buttons stay at least
60 px tall in the code (about 44 px on a phone; the Item Shop's and the item bar's use 62+ so they
clear 44 px). Item pictures: `ItemIcon.luau`.

## Item bar

The candy bar along the bottom of the screen replaces Roblox's own hotbar (`ItemBar.luau` hides it).
First the **towel** slot - the biggest, because on phones it is the main button - showing your
towel's current look, then the **3 items** you picked in the Item Shop.

- **Use:** tap / click a slot, or press **1-4** (**Q** also snaps the towel). **Hold** the towel slot
  (or Q / 1 / Y) to keep cracking it: one snap per cooldown until you let go. A gamepad uses **Y**
  (towel) and the **d-pad** left / up / right (items). Key hints show on keyboards and gamepads,
  not on touch screens; hovering a slot with the mouse shows its name.
- **Cooldown:** a dark sweep clears clockwise with the seconds left; when the item is ready again
  the slot pops (with a little sound for cooldowns of 2 s or more - not the towel's quick one).
  Tapping a slot that is cooling down does nothing.
- **Active** (gliding, hiding under the basket, a peel or duck out): the slot glows and pulses.
- **Held** (the tool in your hand): the slot rises with a white rim.
- **Not allowed** (the gameplay side says why in a toast): the slot shakes with a red rim and the
  error sound.
- **Empty slot:** a "+" that opens the Item Shop on its Items tab.
- When your loadout changes the new items pop in with sparkles and their names; a new towel look
  sparkles in too.

Icons are the items' 3D models (`ReplicatedStorage.ItemMeshes`, from `tools/blender/items`) in
little viewports (`ItemIcon.luau`); until a model is imported the item's emoji shows (the towel: a
drawn towel in its look's colours), and the picture switches over by itself when the model
arrives. Under the hood the bar talks to `ItemClient.luau` (using items, cooldowns, effects); if
that module is missing or broken the bar still works and asks the server directly. If the bar
itself can't load, Roblox's hotbar stays, so the towel still works.

**Where it sits** (`ItemBarLayout.luau`, shared with the HUD): bottom-centre. On touch screens its
slots never get smaller than 44 px (whatever the UI size setting), and when the centred bar would
reach the jump button (bottom-right) it is lifted above it - that happens on portrait phones. If it
would then run under the left menu column it shrinks a little, or moves right of the column. The
"Carrying..." banner always sits just above the bar, and the drawer list stops above it.

| Screen | Bar (real px) | Slots (towel / item) |
| --- | --- | --- |
| Phone landscape 844 x 390 | 243 x 68, 7 px from the bottom | 60 / 49 px |
| Phone portrait 390 x 844 | 357 x 99, lifted 128 px (above the jump button) | 89 / 72 px |
| Tablet 1024 x 768 | 333 x 93 | 83 / 67 px |
| Desktop 1920 x 1080 | 372 x 103 | 92 / 75 px |

## Item Shop (cash)

Two tabs under your cash: **Upgrades** and **Items** (the highlight springs across, like the
Store's tabs). A red dot on a tab means there's something there you can afford.

### Upgrades

Permanent upgrades, five levels each, all numbers in `src/shared/Config/ShopConfig.luau`:

| Upgrade | Gives |
| --- | --- |
| Towel Snap | longer snap reach (12 → 20 studs) and harder knockback |
| Speed Socks | faster walking (+1.5 → +8) and less slowdown while carrying |
| Sturdy Lock | drawer stays slammed longer (+10 → +60 s) and re-locks sooner |
| Coin Magnet | +10 → +50% on every Collect; level 3+ collects by itself while you stand in your drawer |

The Towel Snap card also shows the **towel look** its next level brings (Plain Blue → Candy
Stripe → Beach → Fluffy Spa → Sports → Champion; with the Royal Towel pass it shows Royal).

### Items

One card per item (`src/shared/Config/ItemConfig.luau`; the towel isn't sold, everyone has it):
its 3D model, name, what it does and its cooldown.

- **Locked:** a green **cash** button (the price; grey and "Need $X more" when you can't afford it)
  and a purple **Robux** shortcut (the item's one-time developer product, `Item_<Key>` in
  `StoreConfig.luau`; the price shown comes from there). A new item goes into an empty bar slot by
  itself, and the big "NEW ITEM!" card pops up with the item springing in and confetti.
- **Unlocked:** **Add to bar** / **In bar ✓** opens a picker of the 3 bar slots: tap a slot to put
  the item there (an item already in that slot swaps places), or **Take it out of the bar**.

## Store (Robux) — what Josh needs to do

All in `src/shared/Config/StoreConfig.luau`. **The prices there are proposals.**

| Key | Kind | Proposed price | Does |
| --- | --- | --- | --- |
| `DoubleCash` | Game pass | 199 | income ×2 |
| `VIP` | Game pass | 249 | gold VIP name tag, +10% income |
| `ExtraSlots` | Game pass | 299 | unlocks the padlocked back row of the drawer (+4 slots) |
| `GoldenTowel` | Game pass | 149 | the Royal Towel (purple and gold, a stitched crown), +50% snap reach and knockback |
| `CashSmall` / `CashMedium` / `CashLarge` | Product | 29 / 99 / 299 | 5 min / 30 min / 2 h of your income (at least $2.5K / $25K / $250K) |
| `ServerLuck` | Product | 49 | rarer socks from the Dryer for everyone for 15 min (stacks) |
| `RareDrop` | Product | 99 | an Epic-or-better sock flies into your drawer (waits if it's full) |
| `Relock` | Product | 15 | slam your drawer now, no cooldown |
| `Item_SlipperDash` ... `Item_LaundryBasket` | Product | 49-149 | unlock one item for good (sold on the Item Shop's Items cards, not on the Store's tabs) |

1. In the Creator Dashboard (your game → Monetization), create the 4 passes and the 14 developer
   products (6 boosts + 8 item unlocks) with the names, prices and icons you want.
2. Paste each **id** into `StoreConfig.luau` and set **price** to the same Robux number (the UI shows
   it). Don't rename the keys.
3. Until an id is filled in, buying it in **Studio** is simulated (it's granted straight away so you
   can test); a live server never gives away an id-0 item. The server prints a warning listing the
   ids that are still 0.

## Sockdex

Every sock type you've owned is in the book. The first time you get a type you're paid a reward
by rarity, and filling 25 / 50 / 75 / 100% of the book unlocks a reward you claim by tapping it
(`src/shared/Config/DexConfig.luau`).

## Selling

Tap a sock in your drawer list to open its card; **Sell** pays half its clothesline price
(`EconomyConfig.SellBack`). It asks you to tap twice so a rare can't be sold by accident.

## Settings

Music, Sound effects, UI size, Reduce motion, Pop-up messages, Server announcements, Sock name tags
(All / Mine / Off), Low graphics, Hide others' effects. They are saved with the player's data and
follow them to any device (`src/shared/Config/SettingsConfig.luau`).

## Sounds

Every UI sound is one of Roblox's own (creator "Roblox", marked public domain and free to use in any
experience), from the "Roblox GUI - ..." and "Roblox_UI_..." packs in the Creator Store. The ids live
in `UISound.Ids` in `src/client/StealASockClient/UISound.luau`; swap any for another audio id, or set
it to `""` to silence it. Players set the volumes in Settings (Music, Sound effects).

| Name | When it plays | Sound (id) |
| --- | --- | --- |
| `click` | any button | Roblox GUI - Select (17208396156) |
| `hover` | mouse over a button (desktop, very quiet) | Roblox GUI - Hover 01 (17208339919) |
| `open` / `close` | a menu panel opens / closes | Roblox_UI_Sweep (15675046931) / Roblox GUI - Back (17208186900) |
| `tab` | switching tabs | Roblox GUI - Tab (17208408337) |
| `toggle` | a settings switch | Roblox_UI_Small_Click (15675032796) |
| `buy` | an Item Shop upgrade or item was bought | Roblox GUI - Purchase (17208380755) |
| `coin` | one coin landing in the cash pill (spaced at least 0.07 s apart) | Roblox GUI - Pickup (17208319162) |
| `error` | can't afford it / not allowed (also an item bar slot that says no) | Roblox GUI - Negative (17208353912) |
| `success` | a good outcome | Roblox GUI - Notification High (17208361335) |
| `confetti` | big celebration (pass or item unlocked, milestone, rare drop) | Roblox_UI_Indicator (15675085146) |
| `newSock` | a new Sockdex entry | Roblox GUI - Aura (17208327798) |
| `whoosh` | banners and toasts sliding in, the item bar arriving | Roblox_UI_Whoosh_02 (15675028888) |
| `pop` | small pop-ins (badges, cards); an item bar slot ready again or a new item in the bar | Roblox GUI - Bubble (17208204604) |
| `sell` | a sock was sold | CoinTransfer_01 (127645268874265) |
| `music` | background music loop (starts once the saved Music volume is known) | Roblox_UI_Loop_Calm_Music (15675069601) |

All sounds are preloaded when the game starts, so the first click isn't silent.
