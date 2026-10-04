# Skybrawl

A Brawlhalla-style platform fighter for Roblox, played on a 2D plane.
Players use their own avatars, pick up weapons that drop onto floating
islands, and build up damage until a heavy hit launches someone off the
screen.

It's a self-contained Rojo project, separate from the Coin Rush project at
the repo root.

## What's in it

**Fighting**
- Brawlhalla-style damage: hits add damage %, and the higher it gets the
  further you fly. You lose a life (stock) by getting knocked past the
  blast zone at the edge of the screen. Damage shows on your card and
  goes white → yellow → orange → red.
- Full movement kit: ground jump + 2 air jumps, short hops, fast-fall,
  dash, spot dodge, directional air dodge, wall cling + wall jumps, drop
  through soft platforms, and once-per-airtime recovery and ground pound
  attacks.
- Weapon pickups. You start unarmed and weapons fall onto the stage:
  **Sword, Hammer, Spear, Gauntlets, Scythe, Bow**. Each has 11 attacks:
  neutral/side/down lights, neutral/side/down air lights, chargeable
  neutral/side/down heavies, recovery and ground pound. The Bow fires
  arrows, and you can throw any weapon at people.
- 4 arenas: Skyhold Keep, Twin Isles, Ancient Ruins, Duel Rock.
- Bots at 3 difficulties that fight, dodge, grab weapons and recover back
  to the stage.

**Camera** (each player picks their own in Settings, or in the in-match menu)
- Modes: *Frame All* (Brawlhalla-style, zooms to fit everyone),
  *Follow Me*, *Lookahead*, *Duel Focus*, *Fixed Stage*
- Looks: *Flat 2D* (narrow lens, almost no depth), *2.5D*, *Tilted
  2.5D*, *Wide 2.5D*
- Zoom, smoothing and screen shake settings

**Matchmaking** (several arenas run side by side in one server)
- Ranked 1v1 (rating-matched, with a widening search window)
- Ranked 2v2 (four solo players, balanced teams)
- Free-for-all (up to 4 players; bots fill empty spots after a short wait)
- vs Bots (1v1 duel, 3-bot FFA, or 2v2 with a bot teammate)
- Custom rooms. Hosts choose:
  - mode
  - stocks or timed rules
  - map
  - which weapons drop
  - damage multiplier
  - friendly fire
  - bots
  - private (join by code)
  - friends only
  - a skill (rating) range

  The room browser filters by mode, map, rule, open slots, in-match rooms,
  your skill range, friends' rooms, and name search.

**Progression** (saved with DataStores)
- Elo rating for ranked 1v1 and 2v2 (Tin → Bronze → Silver → Gold →
  Platinum → Diamond) with 10 placement matches, and a global top-10
  board in the lobby
- Coins and XP from every match, with levels shown on your nameplate
- Coin shop for weapon colors, trails, KO effects and titles (no Robux)

**Controls**: keyboard, mouse, gamepad and mobile touch. Everything can be
rebound in Settings → Controls.

## Project layout

```
default.project.json            Rojo tree (remotes are declared here)

src/shared/                     ReplicatedStorage.Shared
  Config.luau                   All tuning: physics, combat, queues, rewards, camera, keybinds
  FighterSim.luau               2D movement/attack simulation (client + bots use the same code)
  Weapons.luau                  Weapon + attack data (timings, damage, knockback, hitboxes)
  Maps.luau                     Arena layouts, blast zones, camera bounds
  Combat.luau                   Damage / knockback / hitstun formulas
  Ranks.luau                    Elo, tiers, XP levels
  Cosmetics.luau                Shop items
  WeaponModels.luau             Builds weapon visuals from Parts
  Locomotion.luau               Default Roblox idle/run/jump/fall animations
  Util.luau, Net.luau

src/server/                     ServerScriptService.Server
  Main.server.luau              Boots every service
  Services/
    DataService                 Profiles, saving, settings sanitizing
    ProgressionService          Coins, XP, ratings after each match
    ShopService                 Buy / equip cosmetics
    CharacterService            Collision groups, nameplates, trails
    ArenaService                Builds the lobby + arenas, arena slots
    LeaderboardService          Global ranked board
    MatchService + Match        Match lifecycle, hits, KOs, weapons, projectiles
    BotBrain                    Bot AI
    QueueService                Ranked/FFA/bot queues
    RoomService                 Custom rooms

src/client/                     StarterPlayerScripts.Client
  Main.client.luau
  ClientState.luau
  Controllers/                  Input, Settings, CameraController, MatchClient, Visuals, CharacterAnimator, Sound
  UI/                           LobbyUI, PlayPanel, RoomsPanel, ShopPanel, ProfilePanel,
                                SettingsPanel, MatchHUD, ResultsScreen, MobileControls, Toasts, UIKit

src/character/Animate.client.luau   Empty stub that replaces Roblox's default Animate

tests/                          Lune simulation tests for the shared code
```

## Setup

### 1. Install Rojo

Any Rojo 7.x works. Install it with Foreman/Aftman/Rokit or from
https://github.com/rojo-rbx/rojo/releases, and install the Rojo Studio
plugin.

### 2. Build the place

From this `skybrawl/` folder:

```
rojo build -o Skybrawl.rbxl
```

Open `Skybrawl.rbxl` in Roblox Studio. This is the cleanest start: the
place contains only Skybrawl, with streaming already off.

For live-syncing while you edit, run `rojo serve` and connect with the
plugin. If you serve into a fresh **Baseplate** template instead of the
built file:

- delete the template's `Baseplate` and `SpawnLocation` (the lobby island
  sits at the same height and they'd overlap)
- set **Workspace → StreamingEnabled** to off (Rojo can't always set it
  over live sync)

### 3. Game settings

In **Home → Game Settings**:

- **Avatar → Avatar Type: R15** (recommended). R6 works, but attack poses
  are tuned for R15.
- **Security → Enable Studio Access to API Services**, so DataStores
  (profiles, ratings, leaderboard) work in Studio. Without it you can
  still play, but progress doesn't save and the Profile tab says so.

### 4. Play-test

- **Solo:** press **Play**, open **PLAY** → **vs Bots** → **Start**.
- **Multiplayer:** **Test → Clients and Servers** with 2–4 players to try
  ranked queues, free-for-all and custom rooms. Ranked 1v1 needs two
  players in the queue.

The lobby kiosks (PLAY / CUSTOM ROOMS / SHOP) open the same panels as the
bottom menu.

### 5. Publish

**File → Publish to Roblox**, then enable API services for the published
experience too. Nothing else is required: there are no Robux products yet.

## Controls

| Action                | Keyboard            | Gamepad   | Mobile          |
|-----------------------|---------------------|-----------|-----------------|
| Move / aim            | A D (W S aim)       | Stick / D-pad | Joystick    |
| Jump                  | Space (W with tap jump) | A     | JUMP            |
| Light attack          | J or left click     | X         | LIGHT           |
| Heavy attack (hold to charge on the ground) | K or right click | B | HEAVY |
| Dodge / dash          | L or Left Shift     | RT / LT   | DODGE           |
| Throw / pick up weapon| H                   | Y         | THROW           |
| Match menu            | P                   |           | Menu button     |

- Direction + attack picks the move: neutral, side or down (and up
  counts as neutral).
- In the air, heavy is your **recovery**, and down + heavy is a
  **ground pound**. Each can be used once per jump; getting hit gives
  them back.
- Dodge with a direction on the ground is a dash. In the air it's a
  directional dodge, once per airtime.
- Tap down on a wooden platform to drop through it. Hold down in the air
  to fast-fall.
- Light attack also picks up a weapon you're standing on.

## How a match works

1. Everyone is placed on the arena; 3-2-1-GO.
2. Hits add damage %. Knockback = `(base + scaling × damage/100) × KnockbackScale`.
3. Leaving the blast zone = KO. You lose a stock (or a point in timed
   matches, and whoever hit you last gets one), then respawn above the
   stage with 2 seconds of invulnerability.
4. Last team with stocks wins. Timed matches go to the most points.
   Stock matches also end after 8 minutes (most stocks, then least
   damage).
5. A results screen shows placements, coins, XP and rating changes, then
   everyone returns to the lobby (or to their custom room).

Bot matches and custom rooms pay reduced rewards, and ranked matches can't
include bots. Quitting a ranked match counts as a loss.

## Tuning and extending

Almost everything lives in `src/shared/Config.luau`:

- `Physics`: run speed, jump heights, gravity, dodge/dash timings, wall
  jumps, hitstun movement
- `Combat`: knockback scale, hitstun, charge bonus, respawn timers, and the
  server's hit-validation slack
- `WeaponDrops`: spawn rate, max on stage, throw speed/damage
- `Queue`, `Rooms`, `Bots`, `Ranked`, `Rewards`, `Levels`
- `Camera`: modes and looks (FOV and pitch per look)
- `DefaultKeybinds`, `DefaultSettings`, `Sounds`

**Adding a weapon:** add an entry to `Weapons.List` with all 11 slots,
add its id to `Weapons.Order`, and add a shape builder to `SHAPES` in
`WeaponModels.luau`.

**Adding a map:** add an entry to `Maps.List` (platforms, 4 spawns,
respawn points, weapon spawn points, blast zone, camera bounds, sky
colors), add it to `Maps.Order`, and add it to the pools in
`Config.Queue.MapPools`. The arena is built from that data automatically.

**Adding a cosmetic:** add an item to `Cosmetics.luau`. It shows up in
the shop automatically.

**Sounds** use built-in engine sounds. Swap the ids in `Config.Sounds`
for your own uploads.

**Animations:** walking/jumping use Roblox's default animations. Attack
poses are procedural (`Visuals.luau` → `POSES`) so no uploads are needed.
To use real animations, upload them and play them where `Visuals.onAttack`
is called.

## Tests

The shared gameplay code runs outside Roblox under [Lune](https://lune-org.github.io/docs):

```
lune run tests/run
```

The tests cover:

- jump heights and soft platforms
- wall cling, recovery back to the stage, dodges and dashes
- attack windows, charging, projectiles
- Elo, levels and map sanity checks
- the KO percent of each weapon's side heavy against a defender that
  tries to recover (hammer about 115%, sword about 140%, fists about 175%)

Re-run them after changing physics or knockback numbers.

## Known limitations

- **Movement is client-authoritative**, like default Roblox characters.
  The server validates hits (timing, range, invulnerability, teams), but a
  modified client could still move faster than allowed. Add server-side
  speed checks before scaling up.
- **Matchmaking is per server.** Queues and rooms only see players on the
  same server (up to ~30). Cross-server matchmaking would need
  MemoryStoreService + TeleportService reserved servers.
- **No DataStore session locking.** Saves use `UpdateAsync` with retries,
  and a profile that failed to load is never saved. Joining a second
  server while the first is still saving could lose the last few seconds
  of progress.
- With the **Flat 2D** camera look the camera sits far from the stage. On
  the very lowest graphics quality, Roblox may stop drawing distant
  scenery; use 2.5D there.
