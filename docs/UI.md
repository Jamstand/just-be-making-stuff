# Steal a Sock — UI, Shop, Store and Settings

Everything on screen is built by code (no image assets yet). The look follows
`docs/concept/ui_style.png`: cream candy panels with thick plum outlines, coral titles, a gold cash
pill and glossy candy buttons. The motion is "playful yet stylish": panels glide and fade, buttons and
rewards spring with a little overshoot, and big moments get coins, number pops and confetti.

## What's on screen

| Where | What | Module |
| --- | --- | --- |
| Top-left | Cash pill (rolling number, coins fly in when you earn), income, drawer lock, cash waiting on your pad | `HUD.luau` |
| Left column | Drawer · Shop · Store · Sockdex · Settings buttons (red bubbles when something needs you: an affordable upgrade, new Sockdex finds or a claimable milestone, Rare Sock Drops waiting for a slot) | `Menu.luau` |
| Next to the column | Your drawer list (tap a sock for its card) | `HUD.luau` |
| Top-centre | Server Luck timer, server announcements; toasts and big celebration cards sit on their own top layer (`SockHUDTop`) so they show over open menus | `HUD.luau` |
| Bottom-centre | "Carrying ..." banner while you run with a stolen sock | `HUD.luau` |
| Centre (panels) | Item Shop, Store, Sockdex, Settings; sock card pop-up | `ShopUI`, `StoreUI`, `DexUI`, `SettingsUI`, `SockCard` |

The UI kit every screen uses: `Theme.luau` (colours, fonts, candy factories, screen scaling),
`Anim.luau` (all motion), `UISound.luau` (all UI sounds), `ClientSettings.luau` (the player's
settings), `Menu.luau` (the column and the one-panel-at-a-time manager). Sizes are in reference
pixels for a 720 px tall screen; phones scale everything by about 0.72, so buttons stay at least
60 px tall in the code (about 44 px on a phone).

## Item Shop (cash)

Permanent upgrades, five levels each, all numbers in `src/shared/Config/ShopConfig.luau`:

| Upgrade | Gives |
| --- | --- |
| Towel Snap | longer snap reach (12 → 20 studs) and harder knockback |
| Speed Socks | faster walking (+1.5 → +8) and less slowdown while carrying |
| Sturdy Lock | drawer stays slammed longer (+10 → +60 s) and re-locks sooner |
| Coin Magnet | +10 → +50% on every Collect; level 3+ collects by itself while you stand in your drawer |

## Store (Robux) — what Josh needs to do

All in `src/shared/Config/StoreConfig.luau`. **The prices there are proposals.**

| Key | Kind | Proposed price | Does |
| --- | --- | --- | --- |
| `DoubleCash` | Game pass | 199 | income ×2 |
| `VIP` | Game pass | 249 | gold VIP name tag, +10% income |
| `ExtraSlots` | Game pass | 299 | unlocks the padlocked back row of the drawer (+4 slots) |
| `GoldenTowel` | Game pass | 149 | gold towel, +50% snap reach and knockback |
| `CashSmall` / `CashMedium` / `CashLarge` | Product | 29 / 99 / 299 | 5 min / 30 min / 2 h of your income (at least $2.5K / $25K / $250K) |
| `ServerLuck` | Product | 49 | rarer socks from the Dryer for everyone for 15 min (stacks) |
| `RareDrop` | Product | 99 | an Epic-or-better sock flies into your drawer (waits if it's full) |
| `Relock` | Product | 15 | slam your drawer now, no cooldown |

1. In the Creator Dashboard (your game → Monetization), create the 4 passes and 6 developer
   products with the names, prices and icons you want.
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

The game is silent until sound ids are pasted into `UISound.Ids` in
`src/client/StealASockClient/UISound.luau`:

| Name | When it plays |
| --- | --- |
| `click` | any button |
| `hover` | mouse over a button (desktop, very quiet) |
| `open` / `close` | a menu panel opens / closes |
| `tab` | switching tabs |
| `toggle` | a settings switch |
| `buy` | an Item Shop upgrade was bought |
| `coin` | one coin landing in the cash pill (plays a lot: keep it short) |
| `error` | can't afford it / not allowed |
| `success` | a good outcome |
| `confetti` | big celebration (pass unlocked, milestone, rare drop) |
| `newSock` | a new Sockdex entry |
| `whoosh` | banners and toasts sliding in |
| `pop` | small pop-ins (badges, cards) |
| `sell` | a sock was sold |
| `music` | background music loop |

Prompt for the local Claude (Studio open, MCP on):

> Read docs/UI.md, section Sounds. Using the Roblox Studio MCP, search the Creator Store for free,
> short, cartoony UI sounds that fit a cosy night-time bedroom game (soft pops, bubbly clicks, a
> coin clink, a light whoosh, a cheerful jingle for confetti, a gentle error boop) and one calm,
> playful looping music track. Only use sounds that are free and allowed in other experiences. Put
> each asset id into `UISound.Ids` in src/client/StealASockClient/UISound.luau as
> "rbxassetid://<id>", update that ModuleScript's Source in the open place to match, and list the
> ids you chose. Don't publish.
