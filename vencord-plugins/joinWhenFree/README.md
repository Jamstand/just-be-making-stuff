# JoinWhenFree — Vencord plugin

Tired of clicking a voice channel and getting hit with this?

> **Channel is full**
> Sorry, this channel has the max number of people!

This plugin waits in line for you. The moment someone leaves, **you're in.**

## What it does

- When you click a **full voice channel** (the same click that normally just shows the
  "Channel is full" popup), the plugin starts watching that channel for you.
- The instant someone leaves, it **automatically connects you** to the call.
- You get a toast in Discord and (optionally) a desktop notification, so it works even
  if you're alt-tabbed into a game while waiting.
- If someone else snipes the spot in the same instant, it keeps waiting for the next one.
- You can also arm/cancel it manually:
  **right-click a full voice channel → "Join When a Spot Opens"** / **"Stop Waiting for Spot"**.

## Installation

Custom plugins ("userplugins") can't be installed from Discord's settings UI — they require
building Vencord from source. It only takes a few minutes:

### 1. Get the tools

- [Node.js 18+](https://nodejs.org)
- pnpm — after installing Node, run: `corepack enable` (or `npm i -g pnpm`)
- [Git](https://git-scm.com)

### 2. Clone Vencord

```bash
git clone https://github.com/Vendicated/Vencord
cd Vencord
pnpm install --frozen-lockfile
```

### 3. Add this plugin

Copy this folder into Vencord's `src/userplugins` directory so you end up with:

```
Vencord/src/userplugins/joinWhenFree/index.tsx
```

For example (from the root of this repo):

```bash
mkdir -p path/to/Vencord/src/userplugins
cp -r vencord-plugins/joinWhenFree path/to/Vencord/src/userplugins/joinWhenFree
```

### 4. Build and inject

```bash
pnpm build
pnpm inject
```

Pick your Discord installation when prompted, then **fully restart Discord**
(quit it from the tray, not just close the window).

> Using [Vesktop](https://github.com/Vencord/Vesktop) instead of the official client?
> Skip `pnpm inject` and instead point Vesktop at your build:
> Vesktop Settings → Vencord Location → select your `Vencord/dist` folder.

### 5. Enable it

Discord → User Settings → Vencord → Plugins → enable **JoinWhenFree**.

## Usage

1. Click the full voice channel like you normally would.
2. The "Channel is full" popup appears as usual — but now you'll also see a toast:
   *"Waiting for a spot in #channel — you'll join automatically."*
3. Go do something else. When someone leaves, you're connected automatically.

To cancel: right-click the channel → **Stop Waiting for Spot**.

## Settings

| Setting | Default | What it does |
| --- | --- | --- |
| Auto-watch on full click | on | Clicking a full voice channel automatically starts waiting |
| Desktop notification | on | Show an OS notification when you get connected |
| Cancel on manual join | on | Stop waiting if you join some other voice channel yourself |
| Give up after | 30 min | Stop waiting after this many minutes (0 = wait forever) |

## How it works

- While watching a channel, the plugin listens to Discord's `VOICE_STATE_UPDATES`
  flux events (the same events that update the member list under each voice channel).
- On every update it compares the number of connected users (`VoiceStateStore`)
  against the channel's user limit.
- When there's room, it joins using the same internal action Discord runs when you
  click a channel (`selectVoiceChannel`), then verifies with the server-confirmed
  voice states that you actually got the spot. If another waiting user got there
  first, the plugin keeps waiting.
- Clicking a full channel is detected via `CHANNEL_SELECT` + a fullness/permission
  check (matching the exact conditions under which Discord shows the "Channel is
  full" popup), so no fragile patches to Discord's minified code are needed.

## Notes

- Verified against Vencord `1.14.13` (June 2026): builds cleanly, passes Vencord's
  `tsc` type check and ESLint config. Only uses stable plugin APIs (flux events,
  stores, context menus) — no patches against Discord's minified code, so Discord
  updates shouldn't break it.
- Joining is as fast as your client hears about the voice state change — usually
  well under a second after someone leaves.
- Users with the **Move Members** permission never see "Channel is full" (Discord
  lets them join anyway), so the plugin stays out of their way.
- Like all client mods, Vencord is technically against Discord's ToS. It's widely
  used and there are no known bans for simply running it, but use at your own risk.

## Updating Vencord later

```bash
cd Vencord
git pull
pnpm install --frozen-lockfile
pnpm build
```

Your `src/userplugins` folder is left untouched by updates — just rebuild.
