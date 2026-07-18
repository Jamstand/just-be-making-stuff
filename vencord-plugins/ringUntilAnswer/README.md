# RingUntilAnswer — Vencord plugin

Auto-redial for Discord. Right-click someone and **keep ringing them until they pick up** —
then it stops the instant they join the call.

## What it does

- Right-click a user (in a DM, the members list, friends list, anywhere) →
  **"Call Until They Answer"**, or run **`/calluntil @user`** from anywhere.
- It starts a DM call and re-rings them on a set interval until they join.
- The **moment they answer**, the redial stops and you get a toast + optional desktop
  notification (handy if you've tabbed away).
- To stop early: right-click them again → **"Stop Calling"**, or run **`/stopcalling`**.
- It gives up on its own after a configurable number of rings (or minutes), so you can't
  accidentally ring someone forever.

### Smart behaviour

- **Only ring while they're online** — pauses if they go offline/invisible, and if they're
  offline when you start it **waits and begins the moment they come online**.
- **Respects Do Not Disturb** (optional) — pauses while they're on DND.
- **Quiet hours** (optional) — never rings during a window you set (your local time).
- **Backs off when they reply** — if they start typing in the DM, it stops (they're clearly
  responding).
- **Stops if you hang up** — leaving the call yourself ends the redial.
- **Live progress** — a periodic toast shows the current attempt count.
- **Auto-message on give-up** (optional) — DM a note like "ping me when free" when it stops
  without an answer.

## Settings

| Setting | Default | What it does |
| --- | --- | --- |
| Ring interval | 30 s | How often it re-rings while waiting. Goes as low as **3 s** — shorter rings faster but can hit Discord's rate limits |
| Max attempts | 15 | Give up after this many rings if there's no answer |
| Give up after (minutes) | 0 (off) | Also stop this many minutes after ringing starts |
| Ring forever | off | Ignore both limits and keep ringing until they answer or you hit Stop |
| Only when online | on | Pause while they're offline/invisible; wait for them to come online |
| Skip Do Not Disturb | off | Pause while they're on DND |
| Stop when they type | on | Stop if they start replying in the DM |
| Stop when I leave | on | Stop if you hang up the call yourself |
| Quiet hours | off | Never ring during the start→end window (local time) |
| Give-up message | *(blank)* | Optionally DM this when it gives up without an answer |
| Show progress | on | Periodic toast with the current attempt count |
| Desktop notification | on | OS notification when they answer (or when it gives up) |

## Installation

This plugin lives alongside **JoinWhenFree** in this repo, and the
`vencord-plugins/joinWhenFree/setup.ps1` installer copies **both** plugins into Vencord
automatically. See [../joinWhenFree/README.md](../joinWhenFree/README.md) for the full
Windows quick-start.

Manual install (any OS) — copy this folder into Vencord's `src/userplugins`:

```
Vencord/src/userplugins/ringUntilAnswer/index.tsx
```

Then `pnpm build && pnpm inject`, restart Discord, and enable **RingUntilAnswer** under
Settings → Vencord → Plugins.

## How it works

- The first ring uses `selectVoiceChannel(dmChannelId)` — the same internal action as
  clicking the call button — which starts the DM call and rings the recipient.
- While you stay connected, each subsequent attempt calls `ring(dmChannelId)` to ring
  them again.
- "They answered" is detected from `VoiceStateStore` — the plugin watches
  `VOICE_STATE_UPDATES` and checks whether the target's voice channel is now your DM call,
  so it reacts the instant they join rather than on the next tick.
- Stopping (manually, on success, or on giving up) clears the loop and calls
  `stopRinging` to cancel any outstanding ring.

## Please use this responsibly

This is **auto-redial for reaching your own contacts** — like hitting redial on a phone
when you need to get hold of a friend. It is **not** a tool for pestering people:

- There's a hard attempt cap by default, and the smart defaults (online-only, stop-on-typing,
  quiet hours) exist specifically to keep it from being obnoxious.
- Hammering Discord's ring endpoint with a very short interval (or ringing people who don't
  want your calls) can get **your** account rate-limited or actioned, and is just rude.
- If someone declines or doesn't want to talk, take the hint and hit **Stop Calling**.

## Notes

- Verified against Vencord `1.14.13` (June 2026): builds, type-checks, and lints clean.
  Uses only stable plugin APIs (flux events, stores, context menus) — no patches against
  Discord's minified code.
- Works for 1:1 DMs. Bots can't be called, so the menu item is hidden for them.
