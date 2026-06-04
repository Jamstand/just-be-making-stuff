# AutoRejoin — Vencord plugin

Pin a voice channel and snap right back into it if you ever get disconnected or booted.
The natural counter to BootOnJoin.

## Usage

- Right-click a voice channel → **"Stay Connected (Auto-Rejoin)"**. While pinned, if you
  end up out of that channel for any reason, you're rejoined automatically.
- To actually leave, right-click → **"Stop Staying Connected"** first (otherwise it'll just
  pull you back — that's the whole point).

## Settings

| Setting | Default | What it does |
| --- | --- | --- |
| Max tries | 5 | How many rejoins in a row before giving up (e.g. if you got banned from the channel or it's full) |
| Show toasts | on | Toast when you get auto-rejoined |

## How it works

- It remembers your pinned channel (saved across restarts). On any `VOICE_STATE_UPDATES`,
  if you're not in it, it rejoins via `selectVoiceChannel` after a short debounce.
- The attempt counter resets every minute, so one bad streak (full/banned) disables it
  temporarily rather than looping forever.

## Notes

- Works for server voice channels.
- Verified against Vencord `1.14.13`: builds, type-checks, lints clean. No code patches.
