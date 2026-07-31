# RingSquad — Vencord plugin

Ring **several people at once**. The multi-person companion to
[RingUntilAnswer](../ringUntilAnswer/README.md).

## Two modes

Pick one in **Settings → Vencord → RingSquad → Mode**:

- **Group blast** — finds (or optionally creates) a group DM with exactly the people in your
  squad, starts one call, and rings everyone **at the same time**. It keeps re-ringing only
  the people who haven't joined yet. Discord caps group DMs at 10, so this handles up to
  **you + 9**.
- **Round-robin** — rings people **one at a time** in normal 1:1 DMs, rolling to the next
  after a few seconds, looping until someone picks up. No group chat is created.

Both modes stop the instant someone joins, re-ring until answered, and give up after a
configurable number of rounds (or never, with "Ring forever").

## Building a squad

- Right-click any user → **"Add to Ring Squad"** / **"Remove from Ring Squad"**. Your
  working squad is saved across restarts.
- Save/reuse named squads with the commands below.

## Commands

| Command | What it does |
| --- | --- |
| `/ringsquad [name]` | Ring your working squad, or a saved squad by name |
| `/stopsquad` | Stop ringing |
| `/squad` | Show your working squad and saved squads |
| `/squad-save <name>` | Save the working squad under a name |
| `/squad-load <name>` | Load a saved squad into the working squad |
| `/squad-clear` | Empty the working squad |

## Settings

| Setting | Default | What it does |
| --- | --- | --- |
| Mode | Group blast | Group blast vs round-robin |
| Re-ring interval | 20 s | Group: how often to re-ring people who haven't joined |
| Rollover | 15 s | Round-robin: time on each person before moving on |
| Max rounds | 10 | Give up after this many rounds (unless "Ring forever") |
| Ring forever | off | Keep going until someone answers or you stop |
| Stop on first answer | off | Group: stop as soon as one person joins (off = wait for everyone) |
| Only when online | on | Round-robin: skip people who are currently offline |
| Create group DM if missing | off | Group: create a new group DM if no exact match exists |
| Show progress | on | Periodic progress toasts |
| Desktop notification | on | Notify when someone answers or it gives up |

## How it works

- **Group DM lookup** reuses an existing group DM whose members exactly match your squad
  (`ChannelStore.getSortedPrivateChannels()` filtered by `isGroupDM()` + `recipients`).
  Only if none exists **and** you've enabled it does it create one via
  `POST /users/@me/channels`.
- **Ringing** uses the same call actions as RingUntilAnswer; `ring(channelId)` re-rings only
  the recipients who aren't connected yet, so people who already joined aren't pestered.
- "Answered" is read from `VoiceStateStore` on every `VOICE_STATE_UPDATES`.

## Please use this responsibly

Blasting a call at a whole group (or cycling through your entire friends list) is a lot more
intrusive than a single call. Use it to round up friends who *want* to hang out — not to
spam. And note the **group-create** option makes a real, persistent group chat everyone can
see, which is why it's off by default.

## Notes

- Verified against Vencord `1.14.x`: type-checks, lints, and builds clean. Uses only stable
  plugin APIs (flux, stores, REST, commands, context menus) — no code patches.
- Like RingUntilAnswer, the underlying call/ring behavior needs a live in-Discord test.
