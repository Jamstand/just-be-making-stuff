# Skybrawl

A Brawlhalla-style platform fighter for Roblox, played on a 2D plane.
Players pick a legend (or fight as their own avatar), grab the weapons that
drop onto floating islands, and build up damage until a heavy hit launches
someone off the screen. The fighters, weapons, maps, skies and animations
were made in Blender by the scripts in `art/` (see `art/README.md`).

It's a self-contained Rojo project, separate from the Coin Rush project at
the repo root.

## What's in it

**Legends** (pick in the lobby's FIGHTERS panel)
- Kestrel (sky-corsair, Sword + Bow), Brann (forge smith, Hammer +
  Gauntlets), Yuki (frost ranger, Spear + Bow), Moss (jungle druid,
  Scythe + Spear), Vex (shadow rogue, Scythe + Gauntlets), Sol (sun knight,
  Sword + Hammer), or **My Avatar** (your own avatar, any weapon).
- Each legend has Strength / Dexterity / Defense / Speed stats and a
  signature for each of their ground heavies: 36 signatures in all. Weapon
  pickups give legends their own two weapons, alternating like Brawlhalla.
- Stylized hero legends (a mix of platform-fighter appeal and gritty
  fighting-game costume design): smooth skinned bodies with painted
  textures, metal that shines, swinging capes, braids and aprons, and a
  thin dark outline, each with its own weapon skins.
  Every move is animated, and the animations are mirrored when you face
  left so your weapon stays on the camera's side.

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
  **Sword, Hammer, Spear, Gauntlets, Scythe, Bow**. Each has 14 attacks:
  a four-hit chain on neutral light (three quick hits, then a launcher),
  side/down lights, neutral/side/down air lights, chargeable
  neutral/side/down heavies, recovery and ground pound. The Bow fires
  arrows, and you can throw any weapon at people.
- **Battlegrounds combat** on top of that:
  - *Punch chains:* mash light for a quick 3-hit chain into a launching
    finisher (M1s, like in battlegrounds games).
  - *Block:* hold block to catch hits from the front. Blocked hits drain
    a guard meter (heavies drain more); when it runs out the guard breaks
    and you're dazed and wide open. The guard refills when you stop
    blocking.
  - *Ragdoll knockdowns:* strong hits send you tumbling limp. Over the
    stage you stay limp until you land and get knocked down (invulnerable
    until you're back up; press anything to get up early), unless you
    press dodge just before landing to tech-roll up. Jump to break out of
    a ragdoll; off the stage you get control back to recover.
  - *Ultimate:* fighting (and getting hit) fills an ultimate meter. Full,
    press Ultimate to **awaken**: everyone freezes for a camera cut-in,
    then for 20 seconds you have an aura, 15% more damage and 10% more
    speed, and one cinematic, unblockable **ultimate move** (each legend
    has their own: Final Draw, Overdrive Cannon, Absolute Zero, Rampage,
    Thousand Shadows, Zenith Smash, Limit Break).
  - *Effects:* impact flashes, black-and-white impact frames, debris,
    craters, smoke, speed lines and awakening auras, with a Full /
    Reduced / Off setting.
- **Combo flow**: hit-stop on every hit, chase dodges (after you land a
  hit, your dodge is a quick, invulnerability-free burst that ignores the
  cooldown), jump and chase-dodge cancels out of light attacks that hit,
  gravity cancels (an air spot dodge lets you use ground lights in the air),
  and a combo counter that tells true combos from strings. True combos work
  at low damage and turn into strings as damage climbs.
- 8 arenas. Four have Blender-made kits and painted skies: Sky-Ship Deck,
  Volcanic Forge, Frozen Peaks and Jungle Temple. The four classic ones are
  Skyhold Keep, Twin Isles, Ancient Ruins and Duel Rock.
- Bots at 3 difficulties that fight, dodge, block, tech, awaken, use
  their ultimates, grab weapons and recover back to the stage.

**Camera** (each player picks their own in Settings, or in the in-match menu)
- Modes: *Frame All* (Brawlhalla-style, zooms to fit everyone),
  *Follow Me*, *Lookahead*, *Duel Focus*, *Fixed Stage*
- Looks: *Flat 2D* (narrow lens, almost no depth), *2.5D*, *Tilted
  2.5D*, *Wide 2.5D*
- Zoom, smoothing and screen shake settings, plus battle effects (Full /
  Reduced / Off) and ultimate camera cut-ins

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

art/                            Blender scripts that make all the art (art/README.md),
  export/                       ...their output, to import into Studio (art/IMPORTING.md)
  previews/                     ...and renders of every model, map and animation

src/shared/                     ReplicatedStorage.Shared
  Config.luau                   All tuning: physics, combat, queues, rewards, camera, keybinds
  FighterSim.luau               2D movement/attack simulation (client + bots use the same code)
  Weapons.luau                  Weapon + attack data (timings, damage, knockback, hitboxes)
  Legends.luau                  The roster: stats, weapons, signature heavies
  LegendRig.luau                Turns imported fighter meshes into a jointed rig on a character
  Markers.luau                  Reads the import markers that undo Studio's scale/rotation
  AnimationData/                GENERATED: every animation clip, keyed in Blender
  FighterRigs.luau              GENERATED: the shared skeleton + each fighter's parts
  WeaponMeshes.luau             GENERATED: weapon mesh list, trail points
  Maps.luau                     Arena layouts, blast zones, camera bounds
  Combat.luau                   Damage / knockback / hitstun formulas
  Ranks.luau                    Elo, tiers, XP levels
  Cosmetics.luau                Shop items
  WeaponModels.luau             Weapon visuals: imported meshes, or Parts as a fallback
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
  Controllers/                  Input, Settings, CameraController, MatchClient, Visuals,
                                FighterAnimator (plays the clips on every fighter), CharacterAnimator, Sound
  UI/                           LobbyUI, PlayPanel, RoomsPanel, FightersPanel, ShopPanel, ProfilePanel,
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

- **Avatar → Avatar Type: R15** (recommended). "My Avatar" fighters are
  animated by the same clips as the legends; R6 avatars work, but only
  move their shoulders, hips and head.
- **Security → Enable Studio Access to API Services**, so DataStores
  (profiles, ratings, leaderboard) work in Studio. Without it you can
  still play, but progress doesn't save and the Profile tab says so.

### 4. Import the art (optional, but it's the good-looking part)

Follow `art/IMPORTING.md`: import the FBX files from `art/export/` into
three folders in ReplicatedStorage and paste the painted background ids
(three layers per map) into `Config.Art.SkyImages`. Until then, legends fall back to your avatar,
and weapons and maps to code-built Parts.

### 5. Play-test

- **Solo:** press **Play**, open **PLAY** → **vs Bots** → **Start**.
- **Multiplayer:** **Test → Clients and Servers** with 2–4 players to try
  ranked queues, free-for-all and custom rooms. Ranked 1v1 needs two
  players in the queue.

The lobby kiosks (PLAY / CUSTOM ROOMS / SHOP) open the same panels as the
bottom menu.

### 6. Publish

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
| Block (hold)          | F                   | LB        | BLOCK           |
| Awaken / ultimate     | G                   | RB        | ULT             |
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
- **Chains:** neutral light on the ground starts the punch chain; keep
  pressing light (within half a second) for hits 2 and 3, and the fourth
  is the launcher. Each chain hit can be cancelled into the next once it
  has hit.
- **Block** only on the ground, and only covers your front. You can't
  block ultimates.
- **Tech:** press dodge just before you land from a ragdoll to roll back
  up (hold a direction to roll that way).
- **Ultimate:** when the ULT bar on your card is full, press it once to
  awaken, and again while awakened for your ultimate move.
- **Combos:** when a light attack hits, you can cancel the end of it with a
  jump, or with dodge for a chase dodge (point the stick where your target
  went). After an air spot dodge (dodge with no direction), a light attack
  uses your ground moves in the air: a gravity cancel. The counter on the
  left of the screen says TRUE COMBO when the target never got out of
  hitstun.

## How a match works

1. Everyone is placed on the arena; 3-2-1-GO.
2. Hits add damage %. Knockback = `(base + scaling × damage/100) × KnockbackScale`.
   Your card also shows your ultimate meter and your guard.
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
- `Combat`: knockback scale, hitstun, hit-stop, chase dodge, gravity
  cancel, charge bonus, respawn timers, and the server's hit-validation
  slack
- `Battle`: chain window, guard meter and break, ragdoll force and
  knockdown/tech timings, ultimate meter gains and the awakening
- `Art`: fighter height, outlines, sky image ids
- `WeaponDrops`: spawn rate, max on stage, throw speed/damage
- `Queue`, `Rooms`, `Bots`, `Ranked`, `Rewards`, `Levels`
- `Camera`: modes and looks (FOV and pitch per look)
- `DefaultKeybinds`, `DefaultSettings`, `Sounds`

**Adding a weapon:** add an entry to `Weapons.List` with its 11 attack
slots and a `Chain` spec for the punch chain,
add its id to `Weapons.Order`, and add a shape builder to `SHAPES` in
`WeaponModels.luau`.

**Adding a map:** add an entry to `Maps.List` (platforms, 4 spawns,
respawn points, weapon spawn points, blast zone, camera bounds, sky
colors), add it to `Maps.Order`, and add it to the pools in
`Config.Queue.MapPools`. The arena is built from that data automatically.
For a Blender kit, add `art/blender/maps/<name>.py` (see `sky/mapkit.py`)
with the same rectangles and set the map's `Kit`.

**Changing a legend:** stats, weapons and signatures are in `Legends.luau`.
Their models are `art/blender/fighters/<name>.py` and their animations are
in `art/blender/anims/`. After editing those, rebuild with Blender and
re-import (see `art/README.md`).

**Adding a cosmetic:** add an item to `Cosmetics.luau`. It shows up in
the shop automatically.

**Sounds** use built-in engine sounds. Swap the ids in `Config.Sounds`
for your own uploads.

**Animations** are made in Blender (`art/blender/anims/`) and exported as
data (`src/shared/AnimationData/`). Every client plays them with
`FighterAnimator`, so nothing is uploaded. Attacks are keyed in move
phases, so they stay in sync with the hitboxes when you retune a move's
timing.

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
- punch chains, blocking and guard breaks, ragdoll knockdowns, techs and
  jumping out of a ragdoll, awakening and the ultimate move

`lune run tests/bots` runs headless bot-vs-bot fights on every map. It
checks that bots land hits, score KOs, rarely fall off on their own, that
they block, tech, awaken and use ultimates, and that Hard beats Easy.

`lune run tests/combos` checks the legends (stats, signatures, Dexterity
timing, weapon alternation) and the combo flow:

- cancels, chase dodges, gravity cancels and hit-stop
- every weapon's punch chain is a true combo at 0% and 140%
- scripted duels that must be true combos at 0% and only strings at 140%

`lune run tests/art` checks the generated art data: a clip for every attack,
signature and movement state, every legend's rig and weapon skins, every map
kit's export and every painted background layer.

`lune run tests/anims` drives the real animation player (FighterAnimator) on a
fake rig, frame by frame at 60 fps:

- every movement loop (idle, run at each speed, jump, fall, wall slide) for
  every weapon and both facings, with no pops, stalls or seam jumps
- crossfades between movement states, dodges and dashes
- every attack of every legend and weapon, plain, charged, landed and cut
  short, with no joint turning faster than about 55 degrees a frame (blends
  can add a little; the test allows 72)
- hurt, tumble, ragdoll, knockdown, get-up, techs, guard-break daze,
  awakening, block and every legend's ultimate
- air jump, landing and throw, hit-stop, mirroring when facing
  left, the weapon changing hands, other players' movement, avatars and menu
  previews

`lune run tests/combo_search [Weapon] [damage]` lists every true combo the
current frame data allows. Use it when you change hitstun, knockback or
timings.

Re-run them after changing physics, knockback or bot numbers. Format with
[StyLua](https://github.com/JohnnyMorganz/StyLua) (`stylua src tests`;
config in `stylua.toml`). It needs a build with Luau support: the release
binaries have it, but `cargo install stylua` needs `--features luau`, or it
skips `.luau` files.

## Known limitations

- **Movement is client-authoritative**, like default Roblox characters.
  The server checks the rest:
  - hits (timing, range, invulnerability, teams)
  - attack and dodge pacing
  - charge values
  - pickups and throws

  A modified client could still move faster than allowed, so add
  server-side speed checks before scaling up.
- **Matchmaking is per server.** Queues and rooms only see players on the
  same server (up to ~30). Cross-server matchmaking would need
  MemoryStoreService + TeleportService reserved servers.
- **Session locking is light.** A server claims a profile when it loads
  it. An older server that still holds the profile can't overwrite it. A
  player rejoining fast waits a few seconds for the old server's final
  save. A profile that failed to load is never saved. For a big game,
  consider a battle-tested library such as ProfileStore.
- With the **Flat 2D** camera look the camera sits far from the stage. On
  the very lowest graphics quality, Roblox may stop drawing distant
  scenery; use 2.5D there.
