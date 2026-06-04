# RingUntilAnswer — Vencord plugin

Auto-redial for Discord. Right-click someone and **keep ringing them until they pick up** —
then it stops the instant they join the call.

## What it does

- Right-click a user (in a DM, the members list, friends list, anywhere) →
  **"Call Until They Answer"**.
- It starts a DM call and re-rings them on a set interval until they join.
- The **moment they answer**, the redial stops and you get a toast + optional desktop
  notification (handy if you've tabbed away).
- To stop early: right-click them again → **"Stop Calling"**.
- It gives up on its own after a configurable number of rings, so you can't accidentally
  ring someone forever.

## Settings

| Setting | Default | What it does |
| --- | --- | --- |
| Ring interval | 30 s | How often it re-rings while waiting. Goes as low as **3 s** — shorter rings faster but can hit Discord's rate limits |
| Max attempts | 15 | Give up after this many rings if there's no answer |
| Ring forever | off | Ignore Max Attempts and keep ringing until they answer or you hit Stop |
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

- The minimum interval is 15 seconds and there's a hard attempt cap on purpose.
- Hammering Discord's ring endpoint faster (or ringing people who don't want your calls)
  can get **your** account rate-limited or actioned, and is just rude.
- If someone declines or doesn't want to talk, take the hint and hit **Stop Calling**.

## Notes

- Verified against Vencord `1.14.13` (June 2026): builds, type-checks, and lints clean.
  Uses only stable plugin APIs (flux events, stores, context menus) — no patches against
  Discord's minified code.
- Works for 1:1 DMs. Bots can't be called, so the menu item is hidden for them.
