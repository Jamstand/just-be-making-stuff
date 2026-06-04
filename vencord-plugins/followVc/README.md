# FollowVC — Vencord plugin

Pick a person and automatically join whatever voice channel they hop into.

## Usage

- Right-click a user → **"Follow Into Voice"**. Whenever they move to a (server) voice
  channel you can join, you're pulled in with them.
- Right-click again → **"Stop Following Into Voice"**.
- Only one person is followed at a time (you can only be in one call).

## Settings

| Setting | Default | What it does |
| --- | --- | --- |
| Leave when they leave | off | Disconnect yourself when they leave voice |
| Show toasts | on | Toast when you follow them into a channel |

## Notes

- Follows into **server** voice channels you have Connect permission for; it can't follow
  into private DM/group calls.
- Verified against Vencord `1.14.13`: builds, type-checks, lints clean. No code patches.
- Be a decent human about it — following someone around servers they don't share with you
  on purpose is creepy. Use it to hang out with friends, not to corner people.
