# BootOnJoin — Vencord plugin

Right-click someone → **"Boot When I Join"** and from then on, whenever you end up in the
same voice channel as them, they get disconnected automatically — whether you walked into
their channel or they walked into yours.

## ⚠️ Requires the Move Members permission

Disconnecting another user is a **server-side moderation action**. Discord only lets you do
it in servers where your role has the **Move Members** permission (the same permission that
lets you right-click → Disconnect someone manually). In any server where you don't have it,
this plugin simply does nothing — Discord rejects the request, exactly as it should.

So this is really "automate a disconnect I'm already allowed to do," for servers you
moderate. It is **not** a way to kick people you have no power over.

## What it does

- Right-click a user → **"Boot When I Join"** adds them to your boot list (saved across
  restarts).
- Whenever you share a guild voice channel with someone on the list — you joining theirs,
  or them joining yours — they're disconnected.
- Right-click again → **"Stop Booting On Join"** to remove them.
- A toast confirms each boot (toggleable in settings).

## Settings

| Setting | Default | What it does |
| --- | --- | --- |
| Show toasts | on | Pop a toast when someone is booted (or when a boot fails) |

## How it works

- It watches `VOICE_STATE_UPDATES`. On any voice change it checks whether you're in a guild
  voice channel and whether anyone on your boot list is in that same channel.
- If so — and `PermissionStore.can(MOVE_MEMBERS, channel)` is true — it disconnects them by
  PATCHing their guild member voice state to `channel_id: null` via `RestAPI`
  (`Constants.Endpoints.GUILD_MEMBER`), the same call Discord's own "Disconnect" button makes.
- Just-booted users are debounced for a few seconds so it doesn't spam the API while the
  voice state catches up.
- Group/DM calls aren't guild channels, so they're skipped (there's no force-disconnect
  there).

## Installation

Installed automatically by the shared `vencord-plugins/joinWhenFree/setup.ps1` script along
with the other plugins in this repo — see
[../joinWhenFree/README.md](../joinWhenFree/README.md).

Manual install (any OS): copy this folder into `Vencord/src/userplugins/bootOnJoin`, then
`pnpm build && pnpm inject`, restart Discord, and enable **BootOnJoin** under
Settings → Vencord → Plugins.

## Please use this responsibly

This automates a real moderation power. Booting someone every single time they join a
channel can cross from "moderation" into "harassment" fast. Use it for things like keeping
a disruptive user out of a channel you run — not to torment people. Misusing moderation
tools can get **your** account or server actioned.

## Notes

- Verified against Vencord `1.14.13` (June 2026): builds, type-checks, and lints clean.
  Uses only stable plugin APIs (flux events, stores, REST, context menus) — no patches
  against Discord's minified code.
