# SongStatus — Vencord plugin

Show the track from your now-playing feed as your Discord status. Built to plug straight
into this repo's `/now-playing` endpoint (the OBS "Now Playing" widget's Spotify feed).

## Usage

1. Make sure your now-playing server is running (this repo's `server.js` serves
   `http://localhost:3000/now-playing`).
2. Enable the plugin. It polls the endpoint and sets a "Listening to …" activity on your
   profile that updates as the song changes.

## Settings

| Setting | Default | What it does |
| --- | --- | --- |
| Endpoint | `http://localhost:3000/now-playing` | URL of your now-playing JSON feed |
| Poll seconds | 15 | How often to refresh the current song |
| Clear when paused | on | Drop the status when nothing is playing |

It accepts the repo's shape `{ playing, title, artist, album }` (extra fields are ignored).

## Notes

- **Connectivity:** Discord's client must be allowed to reach the endpoint. A local server
  on `localhost` is normally fine; if you point it at a remote URL it must send permissive
  CORS headers, or the fetch is silently skipped (a one-time warning is logged to the
  console).
- This sets a normal activity (like CustomRPC), not the literal Spotify integration, so
  there's no green Spotify bar — it shows as "Listening to {song}".
- Verified against Vencord `1.14.13`: builds, type-checks, lints clean. No code patches.
