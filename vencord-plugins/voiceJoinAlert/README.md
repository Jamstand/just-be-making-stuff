# VoiceJoinAlert — Vencord plugin

Get a notification when chosen people join a voice channel (or come online), so you know
when to hop in.

## Usage

- Right-click a user → **"Alert When They Join Voice"**.
- When they join a voice channel, you get a toast + desktop notification telling you who
  and where.
- Right-click again → **"Stop Alerting"**.

## Settings

| Setting | Default | What it does |
| --- | --- | --- |
| Alert on voice | on | Notify when a watched person joins voice |
| Alert on online | off | Also notify when they come online (from offline) |
| Desktop notification | on | Use an OS notification, not just an in-app toast |

## How it works

- Watches `VOICE_STATE_UPDATES` for a watched user with no previous channel (a fresh join)
  and reads the channel/guild name from the stores.
- For online alerts, it compares each watched user's `PresenceStore` status on
  `PRESENCE_UPDATES` and fires when they go offline → online.
- The watch list is saved across restarts.

## Notes

- Verified against Vencord `1.14.13`: builds, type-checks, lints clean. No code patches.
