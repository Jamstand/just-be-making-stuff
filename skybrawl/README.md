# Skybrawl

A Brawlhalla-style platform fighter for Roblox, played on a 2D plane.
Players pick a legend (or fight as their own avatar), grab the weapons that
drop onto floating islands, and build up damage until a heavy hit launches
someone off the screen. The fighters, weapons, maps, skies and animations
were made in Blender by the scripts in `art/` (see `art/README.md`).

It's a self-contained Rojo project, separate from the Coin Rush project at
the repo root.

## What's in it

**Legends** (pick in the **LEGENDS** screen, and again before every match)
- Sol (caped powerhouse hero, Sword + Hammer), Brann (cyborg brawler with
  mech arms, Hammer + Gauntlets), Vex (shadow ninja, Scythe + Gauntlets),
  Yuki (ice psychic, Spear + Bow), Moss (feral jungle berserker, Scythe +
  Spear), Kestrel (wandering blade master, Sword + Bow), or **My Avatar**
  (your own avatar, any weapon).
- Each legend has Strength / Dexterity / Defense / Speed stats and a
  signature for each of their ground heavies: 36 signatures in all. Weapon
  pickups give legends their own two weapons, alternating like Brawlhalla.
- The legends look like classic Roblox avatars in the battlegrounds style:
  blocky bodies with their outfits printed on like classic clothing, anime
  faces, and a few clean accessories (spiky hair, a cape, mech arms, a
  trailing scarf, floating ice crystals...), each with its own weapon skins.
  Capes, scarves and long hair swing as you move. Turn on **Use my
  avatar's look** to fight as your own avatar with a legend's moves.
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

**Menus** (full screen, in the Brawlhalla style)
- A title screen with six legends, then the main menu: ONLINE PLAY,
  PRACTICE, CUSTOM ROOMS, LEGENDS, STORE, RANKINGS, PROFILE and SETTINGS,
  with your legend in 3D, a FEATURED panel (events and news) and your
  DAILY MISSIONS. Your player card, the party bar and the queue banner
  stay on screen while you browse.
- There is no lobby. You sit in the menus between matches and only have
  a character during a match.
- Every menu works with a keyboard, a mouse, a gamepad or touch. Phones
  get their own layout (see Controls).
- Menu music (set `Config.Music.Menu`) and built-in menu sounds.

**Parties**
- Up to 4 players. Invite anyone on the server from the INVITE screen
  (friends are listed first). An invite lasts 30 s. An invite to a player
  who is in a match waits until they're back in the menus. After a decline
  or an expiry, the same player can't be invited again for 30 s.
- The leader queues, starts bot matches and joins custom rooms for the
  whole party. Any member can cancel a search. A member can still go to
  the Training Room alone.

**Matchmaking** (several arenas run side by side in one server)
- Ranked 1v1 (rating-matched, with a widening search window)
- Ranked 2v2: a duo against a duo, a duo against two solos, or four solos
  in balanced teams
- Free-for-all (up to 4 players; bots fill empty spots after 20 s; a party
  is never split)
- vs Bots, from PRACTICE: a 1v1 duel, 2v2 (you and your party, with a bot
  teammate if you're alone) or FFA (up to 3 of you against bots)
- Every match starts with **legend select**: 15 seconds to pick a legend
  (or Random), turn your avatar's look on or off, and vote for one of three
  maps. It ends early once everyone has locked in. In ranked, the other
  team's picks stay hidden until the **VS** screen.
- After the match, the results screen offers **QUEUE AGAIN** (online),
  **REMATCH** (bots, and a custom room's host), **BACK TO ROOM** (everyone
  else in a custom room) and **MENU**.
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
  your skill range, friends' rooms, and name search. A room set to a
  "Random" map votes among its mode's maps in legend select.

**Training Room** (PRACTICE → TRAINING ROOM)
- You against a dummy on Duel Rock. The dummy can stand, jump, dodge,
  block or fight back (with a bot level), and it climbs back to the stage
  when you knock it off.
- Frame data for every attack you do, a combo readout (true combo or
  string), hitbox overlays, slow motion (0.5x and 0.25x), a weapon spawner
  (at most 6 drops at a time), a damage setter with "Keep damage after
  KO", and RESET POSITIONS. Change your legend and weapon, and the
  dummy's, at any time.
- Nothing in the training room counts for missions, XP or rating. It has
  its own arenas, so it never holds up matchmaking.

**Progression** (saved with DataStores)
- Elo rating for ranked 1v1 and 2v2 (Tin → Bronze → Silver → Gold →
  Platinum → Diamond) with 10 placement matches
- **Seasons**: at the end of a season every rating is pulled halfway back
  toward 1000, and last season's tiers become a badge on your profile.
- **Rankings**: 1v1 and 2v2 ladders for the season, the global top 100 and
  your friends, plus past seasons.
- **Daily missions**: three a day (they reset at midnight UTC), with one
  free reroll a day. CLAIM pays coins and XP. Missions you finished but
  didn't claim are paid at the reset. Once the reset has passed, the old
  list can't be rerolled or claimed: the server refuses it ("Your missions
  changed. Take another look.") and the new list shows.
- **Events**: timed bonuses (like double XP for one legend) from
  `Config.Events`. They show as featured tiles on the main menu.
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
  Party, Select, Matchmaking,   Pure rules for parties, legend select + map vote, queue matching
  MatchRules                    ...and match setup (bot formats, MVP, room teams)
  Missions, Events, Seasons,    Pure rules for daily missions, events, seasons, the ranked
  Rankings, RankingsView        ...ladders' stored values and the rankings screen's rows
  DummyBrain, FrameData         The training dummy's behaviours, frame data and the combo readout
  Util.luau, Net.luau

src/server/                     ServerScriptService.Server
  Main.server.luau              Boots every service; the one PlayerRemoving handler, which calls each
                                service's onPlayerRemoving in a fixed order
  Services/
    DataService                 Profiles (v2: missions, season stats), saving, settings sanitizing
    ProgressionService          Coins, XP, ratings, events and seasons after each match
    MissionService              Daily missions: progress, claim, reroll, the midnight rollover
    ShopService                 Buy / equip cosmetics
    CharacterService            Collision groups, nameplates, trails, the menus' avatar models
    ArenaService                Builds the arenas, arena slots (match and training pools)
    LeaderboardService          Seasonal ranked boards (global and friends)
    FriendCache                 Each player's friend list, for invites and friends rankings
    PartyService                Parties and invites
    QueueService                Ranked/FFA queues (whole parties), vs Bots
    SelectService               Legend select and the map vote, then the match
    MatchService + Match        Match lifecycle, hits, KOs, weapons, projectiles, results
    BotBrain                    Bot AI
    RoomService                 Custom rooms
    TrainingService             The training room (TrainingRoom: its controls and the dummy)

src/client/                     StarterPlayerScripts.Client
  Main.client.luau
  ClientState.luau              Server state copies and the phase (Title, Menu, Select, Vs, Match, Results)
  Controllers/                  Input, Settings, CameraController, MatchClient, Visuals,
                                FighterAnimator (plays the clips on every fighter), CharacterAnimator, Sound,
                                Controls (Roblox's own controls and chat), Music, TrainingClient
  UI/                           Focus + FocusNav (keyboard/gamepad/touch navigation), Layout (scaling, phones),
                                UIKit + Shapes (the look), LegendView (3D legends in the menus),
                                TitleScreen, MenuShell (screen stack), MainMenu, PlayerCard, QueueBanner,
                                PartyBar, FeaturedPanel, MissionsWidget, Toasts,
                                RoomsPanel, FightersPanel, ShopPanel, ProfilePanel, SettingsPanel,
                                MatchHUD, ResultsScreen, TrainingHUD, MobileControls
    Screens/                    The menu screens (OnlinePlay, Practice, CustomRooms, Legends, Store,
                                Rankings, Profile, Settings, Missions, Invite)
    Match/                      Legend select and the VS splash

src/character/Animate.client.luau   Empty stub that replaces Roblox's default Animate

tests/                          Lune tests (see Tests)
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

There is no lobby. Players stay in the menus between matches, and
characters only load for a match. `Players.CharacterAutoLoads` is off in
the project file, and the `SpawnLocation` is an invisible holding pad where
a match's characters wait (during the VS screen) until they're placed on
the stage.

For live-syncing while you edit, run `rojo serve` and connect with the
plugin. If you serve into a fresh **Baseplate** template instead of the
built file:

- delete the template's `Baseplate` and `SpawnLocation` (the project's
  invisible pad replaces them)
- set **Players → CharacterAutoLoads** to off, and **Workspace →
  StreamingEnabled** to off (Rojo can't always set these over live sync)

### 3. Game settings

In **Home → Game Settings**:

- **Avatar → Avatar Type: R15** (recommended). "My Avatar" fighters are
  animated by the same clips as the legends (so are legends played with
  "Use my avatar's look" on); R6 avatars work, but only move their
  shoulders, hips and head.
- **Security → Enable Studio Access to API Services**, so DataStores
  (profiles, ratings, rankings) work in Studio. Without it you can
  still play, but progress doesn't save and the PROFILE screen says so.
  Rankings then list the players on the server.

### 4. Import the art (optional, but it's the good-looking part)

Follow `art/IMPORTING.md`: import the FBX files from `art/export/` into
three folders in ReplicatedStorage and paste the painted background ids
(three layers per map) into `Config.Art.SkyImages`. The painted skies also
show behind the title screen and the menus. Until then, legends fall back
to your avatar in matches and to a coloured card in the menus, and weapons
and maps to code-built Parts.

Two more uploads are optional:

- **Legend portraits:** upload `art/export/portraits/<Legend>_portrait.png`
  and paste the ids into `Config.Art.Portraits`. Without them the menus
  show a still 3D head.
- **Menu music:** upload a sound and paste its id into `Config.Music.Menu`
  (`""` is silent).

Use **image asset ids**, not decal ids. If an image shows nothing, paste
the id into an ImageLabel's `Image` in Studio: Studio turns a decal id
into the image id, and that number is the one to use.

### 5. Play-test

- **Solo:** press **Play**, press any key on the title screen, then
  **PRACTICE** → **vs Bots** → **START**. You get legend select, the VS
  screen, the match and the results screen. Try REMATCH and MENU.
- **Training:** **PRACTICE** → **TRAINING ROOM**. Leave with LEAVE
  TRAINING in the panel (Tab).
- **Multiplayer:** **Test → Clients and Servers** with 2–4 players.
  Invite each other (X on the main menu, or the party bar's + slots), then
  try ranked queues (Ranked 1v1 needs two players; Ranked 2v2 needs four:
  two duos, a duo and two solos, or four solos), free-for-all, vs Bots as a
  party and custom rooms.
- **Ranked boards:** the test players of Clients and Servers (user ids of 0
  or less) never write to them. **Play** with Studio API access on writes
  under your real user id.

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
| Match menu            | P                   | View      | Menu button     |

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

**Menus**

| Action                     | Keyboard               | Gamepad      | Mouse / touch        |
|----------------------------|------------------------|--------------|----------------------|
| Move focus                 | Arrows or W A S D      | Stick / D-pad | Hover moves focus   |
| Confirm                    | Enter or Space         | A            | Click / tap          |
| Back                       | Backspace              | B            | The BACK hint        |
| Switch tabs                | Q / E                  | LB / RB      | Tap the tab          |
| Switch sub-tabs            | Z / C                  | LT / RT      | Tap the tab          |
| Screen actions             | X, Y                   | X, Y         | The hints            |
| Panel (training)           | Tab                    | View         | The PANEL button     |

- **Escape is not Back.** Roblox always opens its own menu on Escape, so
  Back is Backspace (or B), and every hint bar has a BACK you can click or
  tap. Every hint in a hint bar can be clicked or tapped, except that on
  touch a Confirm hint that only presses the focused item is hidden (tap
  the item itself).
- Hints follow the focus: on ONLINE PLAY, Confirm says FIND MATCH or
  CANCEL SEARCH for the focused card (none on a locked card), and on
  MISSIONS, CLAIM and REROLL show only on a row that can do them.
- On the main menu, X invites and Y changes your legend. On ONLINE PLAY, X
  invites. On RANKINGS, LB / RB switch 1V1 / 2V2, LT / RT switch GLOBAL /
  FRIENDS, Y jumps to you and X shows the next season. On MISSIONS, X
  rerolls. On LEGENDS, Y toggles your avatar's look. On INVITE, Y
  refreshes.
- **Legend select:** Confirm (or a click) locks in, Back unlocks, X locks
  Random, Y toggles your avatar's look, LB / RB (Q / E) move your map vote,
  and a click on a map votes for it. On touch, tap a tile to look at the
  legend and tap it again (or LOCK IN) to lock.
- **Phones:** a safe area under 500 px tall or 900 px wide gets the phone
  layout, with 1.6x text. Screens scroll.
- **Pause:** P, the Menu (P) button, or the gamepad's View button (not in
  the training room, where View opens the panel).

**Training room**

| Action                       | Keyboard | Gamepad |
|------------------------------|----------|---------|
| Open / close the panel       | Tab      | View    |
| Reset positions              | R        | R3      |
| Drop the selected weapon     | V        | L3      |

- While the panel is open, fight input is off. Back closes the panel but
  keeps it on screen; Tab (or View) again hides it. Mouse and touch use the
  PANEL button.
- A hotkey that is also one of your fight keybinds is turned off and its
  hint hidden.
- **Frame data** uses the usual fighting-game convention. STARTUP is the
  frame the hitbox first comes out on (it counts that frame), ACTIVE is how
  many frames it stays out and RECOVERY the frames after that. TOTAL is
  startup − 1 + active + recovery, so Avatar's Sword side light is 7 / 6 /
  12, 24 frames in all. The line under the move name says which frame it
  hits on ("HITS ON FRAME 7"). Frames are 60 fps frames of the match clock,
  so slow motion doesn't change them.

## How a match works

1. **Match found:** a "MATCH FOUND" flash, then **legend select** (15 s;
   it ends 0.75 s after everyone has locked in). Pick a legend or Random
   and vote for one of three maps. The map with the most votes wins (ties,
   and no votes at all, pick at random). A custom room with a fixed map has
   no vote. In ranked, you see the other team's picks only on the VS
   screen.
2. **VS** (3 s) while the arena is built and the characters load.
3. Everyone is placed on the arena; 3-2-1-GO.
4. Hits add damage %. Knockback = `(base + scaling × damage/100) × KnockbackScale`.
   Your card also shows your ultimate meter and your guard.
5. Leaving the blast zone = KO. You lose a stock (or a point in timed
   matches, and whoever hit you last gets one), then respawn above the
   stage with 2 seconds of invulnerability.
6. Last team with stocks wins. Timed matches go to the most points.
   Stock matches also end after 8 minutes (most stocks, then least
   damage).
7. "GAME!", then the results screen: placements, coins, XP, rating
   changes, mission progress and any event bonus. **QUEUE AGAIN** (online)
   or **REMATCH** (bots and custom rooms) starts the next one; only the
   party leader can queue or start a bots rematch, and in a custom room the
   host restarts it (everyone else gets **BACK TO ROOM**). The pressed
   button says WAITING... until the match has let you go. **MENU** goes
   back, and the screen goes back on its own after 20 s. Leaving that way
   while QUEUE AGAIN or a bots REMATCH is waiting still sends it once the
   match lets you go (unless you're already in a queue); a host's room
   REMATCH is cancelled instead.

Bot matches and custom rooms pay reduced rewards, and ranked matches can't
include bots. Quitting a ranked match counts as a loss. So does **dodging**:
leaving a ranked legend select, or the match before the fight starts, costs
you a ranked loss, and everyone else goes back in the queue (they keep
their search time). A player whose party changed meanwhile can't go back
and is told the search was cancelled. A fighter the server couldn't load
isn't a dodger: they go back in the queue with the others and are told so.
A match that fails to start puts its queue players back in their queue
too. In a casual match a bot takes the leaver's place.

## Tuning and extending

Almost everything lives in `src/shared/Config.luau`:

- `Physics`: run speed, jump heights, gravity, dodge/dash timings, wall
  jumps, hitstun movement
- `Combat`: knockback scale, hitstun, hit-stop, chase dodge, gravity
  cancel, charge bonus, respawn timers, and the server's hit-validation
  slack
- `Battle`: chain window, guard meter and break, ragdoll force and
  knockdown/tech timings, ultimate meter gains and the awakening
- `Art`: fighter height, outlines, sky image ids, legend portrait ids
  (`Portraits`), the weapon each legend holds in the menus (`MenuWeapons`)
- `WeaponDrops`: spawn rate, max on stage, throw speed/damage
- `Queue`, `Rooms`, `Bots`, `Ranked`, `Rewards`, `Levels`
- `Party`: party size, invite timers, the re-invite cooldown, request limits
- `Select`: legend select length, the delay after everyone locks, the VS
  length, the number of maps to vote on, action limits
- `Training`: the training map, the dummy, speeds, the damage step, the
  weapon spawner cap and the hotkeys
- `Missions`: missions a day, rerolls (`FreeRerolls` is 1 or 0: the profile
  keeps one reroll flag a day, so more isn't supported), the templates
  (each with a `Short` form for the phone menu), which sources count
  (`Sources`) and the easiest bot that counts (`MinBotDifficulty`)
- `Events` and `EventMaxMult`: timed XP / coin bonuses (UTC dates, an
  optional legend). The best one applies; they don't stack.
- `News`: the main menu's featured tiles (events are added in front)
- `Menu`: the menu backdrop map (`BackdropMap`; `"Random"` picks a random
  map with a painted sky), featured tile timing, the results delay and
  auto-return, the input grace
- `Seasons`: the season list (UTC end dates) and the soft reset
- `Rankings`: the ranked stores, list sizes, refresh and cache times, the
  DataStore budget limits, and how often each player may ask for rankings
  (`RequestsPerSecond`, `RequestBurst`; past that the answer is "Slow
  down.")
- `Music`: the menu music id, volume and fade
- `Camera`: modes and looks (FOV and pitch per look)
- `DefaultKeybinds`, `DefaultSettings`, `Sounds`

**Adding a season:** add it to `Config.Seasons.List` with its end date.
Season ids must only go up. The next season starts when the one before it
ends.

**Adding an event or a news tile:** add an entry to `Config.Events` (with
`Starts` and `Ends`) or `Config.News`. `Screen` and `ScreenParams` make the
tile open a menu screen.

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
timing. A legend can square up in its own guard (Brann's low brawler guard,
Vex's low scythe grip): the player tries `<Legend>.<Weapon>.<State>`, then
`<Weapon>.<State>`, `<Legend>.Loco.<State>` and `Loco.<State>`, and every
attack's recovery settles into the guard the fighter actually uses.

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
checks that bots reach each other and land hits on every map, score KOs,
rarely fall off on their own, block, tech, awaken and use ultimates, and
that Hard beats Easy.

`lune run tests/combos` checks the legends (stats, signatures, Dexterity
timing, weapon alternation) and the combo flow:

- cancels, chase dodges, gravity cancels and hit-stop
- every weapon's punch chain is a true combo at 0% and 140%
- scripted duels that must be true combos at 0% and only strings at 140%

`lune run tests/art` checks the generated art data: a clip for every attack,
signature and movement state, every legend's rig (a classic avatar under the
triangle limit, with no clipping accessories, its maps and face decals) and
weapon skins (and that Brann's built-in fists hide only the gauntlet model),
every map kit's export and every painted background layer.

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
- the legend clip lookup (a legend's own guard first, then the shared clips)
  and recoveries settling into each fighter's own guard

The menus have their own suites. Each one tests the logic in plain
modules, because Lune's fake instances have no events to click:

- `lune run tests/contract`: the remotes and the project file (every remote
  the client calls has exactly one server handler), Config's menu sections,
  the pure rules (parties, legend select, missions, events, seasons, the
  ranked values), the client's state copies and profile v2 (migration,
  season stats, a save that can't be read).
- `lune run tests/matchflow`: matchmaking with parties, parties and
  invites, the queue, legend select and its leavers and dodges, custom
  rooms with parties, and the match changes (match ids, character
  preloads, cancels and requeues before the fight, the training hooks).
- `lune run tests/progression`: rewards with events and seasons, daily
  missions (progress, claim, reroll, the midnight rollover) and the ranked
  boards (season stores, request budgets, the request rate limit, friends,
  the Studio fallbacks).
- `lune run tests/ui`: focus navigation, the layout maths, the slanted
  shapes and the main menu's view models.
- `lune run tests/screens`: the menu screens' view logic (Online Play locks,
  bot formats, rankings pages and rank card, invite rows, the season badge,
  store cards, the missions reset countdown).
- `lune run tests/matchscreens`: legend select, the VS screen and the
  results screen's view logic, and the phase changes on server events.
- `lune run tests/training`: the dummy's behaviours, frame data, the
  training room's controls and TrainingRequest.

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
- **Matchmaking is per server.** Parties, queues and rooms only see
  players on the same server (up to ~30), and the friends rankings show
  friends you have on this server live and the rest from the stored
  boards. Cross-server matchmaking would need MemoryStoreService +
  TeleportService reserved servers.
- **Rankings** show positions only inside the global top 100 (an ordered
  DataStore can't tell you yours beyond that). Friends rankings read at
  most `Rankings.FriendsMax` (50) stored friends.
- **Seasons are edited in Config.** There is no admin tool.
- **Sounds** are built-in placeholder sounds.
- **Back is not on Escape** (Roblox owns Escape); it's Backspace or B.
- **Roblox chat** is collapsed on your first visit to the menu only where
  `SetCore("ChatActive")` is supported. Elsewhere it shows in its default
  top-left spot over the menu until you close it.
- An invite's 30 s countdown starts as soon as the player is free on the
  server, so a player still on the title screen can miss it.
- **Session locking is light.** A server claims a profile when it loads
  it. An older server that still holds the profile can't overwrite it. A
  player rejoining fast waits a few seconds for the old server's final
  save. A profile that failed to load is never saved. A stored profile
  that can't be read loads on defaults and is never saved either; its
  claim stays until it goes stale, so joining another server right after
  waits about 8 s. Results from a profile that isn't saving never reach
  the ranked boards either. For a big game, consider a battle-tested
  library such as ProfileStore.
- With the **Flat 2D** camera look the camera sits far from the stage. On
  the very lowest graphics quality, Roblox may stop drawing distant
  scenery; use 2.5D there.

## Things to check in Studio

The menus were built without Studio, so these engine details still need a
look. The code has a fallback or a note where it could.

**Characters and matches**
- Characters load (`LoadCharacterAsync`) during the 3 s VS screen and wait
  on the invisible pad until they're placed on the stage at "Start".
- The client notices when the server takes its character (`Character =
  nil`, then Destroy): `CharacterRemoving` or the `Character` property
  should fire. The client also waits up to 5 s for its character after
  "Start".
- The menus' avatar models (`ReplicatedStorage.AvatarModels`): the server
  builds them with `GetHumanoidDescriptionFromUserIdAsync` and
  `CreateHumanoidModelFromDescriptionAsync`. Check what they cost to
  replicate, and that a model replaced by the 5 s retry shows in the menus.
- `GetFriendsAsync` paging (and `IsFriendsWithAsync`, used while a friend
  list loads), and `UserService:GetUserInfosByUserIdsAsync` on the server
  (rankings names).

**Rankings**
- What `GetRequestBudgetForRequestType` returns on a live server for
  `OrderedRead`, `OrderedList` and `OrderedWrite`, and for the older
  `GetAsync`, `GetSortedAsync` and `SetIncrementSortedAsync`. With none
  reported, a warning is logged once and a fixed per-minute limit is used.
- Stored values up to about 9e15 save and sort exactly.
- An endless season (`endsAt = math.huge`) survives the RemoteFunction.
- The "unavailable" fallback in an unpublished place and with Studio API
  access off.

**Input**
- Input events come before RenderStepped in the same frame, and a
  `task.defer` from an InputBegan handler runs after every other handler of
  that key press (with both SignalBehavior settings). The menus rely on this
  so the key that opens or closes a screen, the pause menu or the training
  panel isn't also read as a menu press or an attack.
- Tab and the gamepad's View button arrive as not game-processed; R3 and L3
  work as hotkeys; `GetImageForKeyCode` gives gamepad glyph images.
- Gamepad A held down as the results, legend select or an invite appear
  presses nothing for half a second.
- Key rebinding: Enter, Space or A on a slot wait for the next key; B
  cancels a keyboard slot and Backspace clears a gamepad slot.
- Touch: tap-then-tap to lock a legend, scrolling inside the training panel
  over its buttons, and clicks on the training panel that never become
  attacks.
- The engine's own selection stays off, and `SetCore("ChatActive")`
  collapses the chat.

**Look**
- Text: a `UIScale` scales `UIStroke` thickness (if not, flip
  `Layout.STROKE_FOLLOWS_UISCALE`) and scales around the AnchorPoint.
- The special characters (♛ ± ✓ • — – · ◀ ▶) render in Bangers,
  GothamBlack and LuckiestGuy.
- Slanted shapes: the gradients meet at the seams, outlines are clipped
  right, the disabled dim draws over the content.
- 3D views: placeholders inside ViewportFrames render; the title's legend
  pairs, the LEGENDS screen, legend select, VS and results framing match
  the mockups.
- The VS seam and its fade-out, the pop-in animations, the Online Play
  locked band and the "VS" outline.
- Phones: the top bar (`GuiService.TopbarInset`) stays clear on every screen
  (legend select, results, VS, the training panel), touch targets are at
  least 44 px, and 1.6x text never overflows.
- Mission text shrinks to fit (`Layout.bindFitText`): `TextService:GetTextSize`
  measures what the label draws, and the text is fitted again once the label
  has its width.
- On touch, a hint bar closes the gap left by a hidden Confirm hint.
- The training room's hitbox outlines and tags, and the focus ring and glow
  on its panel.
- The built-in menu sounds play.
