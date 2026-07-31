# Vencord plugins

Custom [Vencord](https://vencord.dev) userplugins. All of them build cleanly and pass
Vencord's own `tsc` + ESLint, and use only stable plugin APIs (flux events, stores, context
menus) — no patches against Discord's minified code.

**Voice / calls**

| Plugin | What it does |
| --- | --- |
| [JoinWhenFree](joinWhenFree/) | When a voice channel is full, wait and auto-join the moment a spot opens |
| [RingUntilAnswer](ringUntilAnswer/) | Right-click someone → keep ringing them in DMs until they pick up |
| [RingSquad](ringSquad/) | Ring several people at once — group blast or round-robin — until someone answers |
| [BootOnJoin](bootOnJoin/) | Auto-disconnect chosen users from voice when you share a channel (needs Move Members) |
| [FollowVC](followVc/) | Auto-join whatever voice channel a chosen person hops into |
| [AutoRejoin](autoRejoin/) | Pin a voice channel and snap back into it if you're disconnected/booted |
| [SoloChannel](soloChannel/) | Lock a voice channel to 1 person while you're in it (needs Manage Channels) |
| [DeafenGuard](deafenGuard/) | Auto-deafen or mute yourself the moment you join a call |
| [VoiceActivityFeed](voiceActivityFeed/) | Running log of who joined/left/moved voice (viewable in settings) |
| [CallRoster](callRoster/) | Right-click a voice channel to copy a list of everyone in the call |

**Notifications / awareness**

| Plugin | What it does |
| --- | --- |
| [VoiceJoinAlert](voiceJoinAlert/) | Get notified when chosen people join voice or come online |
| [KeywordAlerts](keywordAlerts/) | Notify whenever a word/phrase you watch for is said anywhere |
| [ModQueuePings](modQueuePings/) | Alert when a chosen role (e.g. @Moderators) is pinged or a report keyword appears |
| [FriendOnlineDigest](friendOnlineDigest/) | `/online` lists which friends are online; optional periodic digest |
| [TypingPeek](typingPeek/) | Heads-up when someone types in a channel you're not looking at |

**Chat / productivity**

| Plugin | What it does |
| --- | --- |
| [ScheduledMessages](scheduledMessages/) | `/schedule` a message to send later; `/scheduled` lists pending |
| [QuickReplies](quickReplies/) | Save snippets and fire them with `/qr <name>` |
| [AutoThreadReplies](autoThreadReplies/) | Auto-start a thread on each message you post in chosen channels |
| [MessageTranslate](messageTranslate/) | Right-click a message → Translate (private result) |
| [ReminderFromMessage](reminderFromMessage/) | Right-click a message → Remind Me → get a notification later |
| [ClipDropper](clipDropper/) | `/clip <url> [caption]` to drop a Twitch/YouTube clip cleanly |

**Streamer / appearance**

| Plugin | What it does |
| --- | --- |
| [SongStatus](songStatus/) | Show your now-playing track (this repo's `/now-playing` feed) as your Discord status |
| [NowPlayingButton](nowPlayingButton/) | Like SongStatus, plus a clickable profile button to the track |
| [SubGoalStatus](subGoalStatus/) | Poll a counts endpoint (subs/followers) and show it as your status |
| [GoLiveAnnouncer](goLiveAnnouncer/) | Auto-post to a channel when you start a Go Live stream |
| [StatusRotator](statusRotator/) | Cycle your status through a list of messages on a timer |
| [ColorCodedUsers](colorCodedUsers/) | Tint specific people's avatars so they stand out |

> Only run **one** activity-setting plugin at a time (SongStatus / NowPlayingButton / SubGoalStatus / StatusRotator all set your Discord activity).

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
