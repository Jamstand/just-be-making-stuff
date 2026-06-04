# Vencord plugins

Custom [Vencord](https://vencord.dev) userplugins. All of them build cleanly and pass
Vencord's own `tsc` + ESLint, and use only stable plugin APIs (flux events, stores, context
menus) — no patches against Discord's minified code.

| Plugin | What it does |
| --- | --- |
| [JoinWhenFree](joinWhenFree/) | When a voice channel is full, wait and auto-join the moment a spot opens |
| [RingUntilAnswer](ringUntilAnswer/) | Right-click someone → keep ringing them in DMs until they pick up |
| [BootOnJoin](bootOnJoin/) | Auto-disconnect chosen users from voice when you share a channel (needs Move Members) |
| [FollowVC](followVc/) | Auto-join whatever voice channel a chosen person hops into |
| [AutoRejoin](autoRejoin/) | Pin a voice channel and snap back into it if you're disconnected/booted |
| [VoiceJoinAlert](voiceJoinAlert/) | Get notified when chosen people join voice or come online |
| [SongStatus](songStatus/) | Show your now-playing track (this repo's `/now-playing` feed) as your Discord status |

## Install (Windows, easy)

The `joinWhenFree/setup.ps1` script installs **every** plugin in this folder at once.

```powershell
cd ~\jbms-plugin
git pull
cd vencord-plugins\joinWhenFree
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

Press **Enter** at the Discord-install prompt, then reload Discord (**Ctrl+R**) and enable
the plugins you want under **Settings → Vencord → Plugins**. Full walkthrough (prerequisites,
manual/any-OS install) in [joinWhenFree/README.md](joinWhenFree/README.md).

## A note on the "voice power" ones

`BootOnJoin`, `RingUntilAnswer`, and `FollowVC` can shade into annoying-or-worse if pointed
at people who don't want it. They only do things Discord already permits (e.g. BootOnJoin
needs the Move Members permission), but please use them on friends / channels you run, not
to harass anyone — misuse is the kind of thing that gets *your* account actioned.
