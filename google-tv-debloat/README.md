# Google TV Debloater

Turns off preinstalled apps and background extras on a Chromecast with Google TV
or Google TV Streamer, and optionally swaps the ad-filled home screen for a clean
one. Runs from a Windows PC on the same Wi-Fi as the TV.

Nothing is permanently deleted. Apps are disabled for your user only, the tool
has an undo option, and a factory reset restores the TV completely.

## Before you start (on the TV)

1. **Settings > System > About**, scroll to **Android TV OS build** and press OK
   on it 7 times until it says you are a developer.
2. **Settings > System > Developer options**, turn on **USB debugging**.
3. **Settings > Network & Internet >** your Wi-Fi network, and note the
   **IP address** (looks like `192.168.1.50`).

## Run it (on the PC)

1. Put `Debloat-GoogleTV.ps1`, `Run-Debloat.bat` and `GlassHome.apk` in the same folder.
2. Double-click **Run-Debloat.bat**.
3. If ADB is not installed, the tool offers to download it from Google.
4. Type the TV's IP address.
5. The TV shows **Allow USB debugging?** Tick *Always allow from this computer*
   and choose **Allow**.

## Menu

| Option | What it does |
| --- | --- |
| 1. Debloat | Asks about each preinstalled streaming app, turns off a batch of safe Google extras, then asks about a few optional ones that cost a feature (screensaver, voice search). The stock home screen stays. |
| 2. Replace the home screen | Installs Projectivy Launcher from the Play Store, then turns off the Google TV home screen, which is where the ads and recommendation rows live. It checks the new home screen works and rolls back by itself if it does not. |
| 3. Undo | Turns everything back on, home screen first. |
| 4. Save package list | Writes `tv-packages.txt` listing every package on the TV. |
| 5. Install Glass Home | Installs or updates `GlassHome.apk` (the custom home screen in this folder), lets it read your apps' continue-watching lists, shows it to you, then offers to turn off the Google TV home screen so the Home button opens Glass Home. Rolls back by itself if it does not come up. |
| 6. Install SmartTube | Downloads SmartTube, a third-party open-source YouTube app without ads, from its developer's GitHub page and installs it. Using it goes against YouTube's terms of service. The normal YouTube app stays installed. |
| 7. Set YouTube API key | Sends a YouTube Data API key to Glass Home so its video rows work, so you do not have to type it with the remote. |
| 8. Install Disney+ and Hulu | Opens the Play Store page for each official app on the TV. Glass Home adds them to Favorites the first time it sees them. |
| 9. Snappier | Halves (or turns off, or restores) Android's system animations so apps and menus open faster. |
| 10. Block ads and trackers | Points the TV's Private DNS at AdGuard DNS, which blocks many ads and trackers in every app. Does not remove ads that are part of the video stream. Checks the TV is still online and switches itself back off if not. Choice 2 turns it off. |
| 11. Screensaver | Makes the Glass Home screensaver (drifting gradient and a clock that moves each minute) the TV's screensaver, previews it, or puts the previous one back. |
| 12. Your own media | Opens the Play Store page for VLC, Jellyfin or Plex and prints the setup steps for the one you pick. |

To preview without changing anything:

```
Run-Debloat.bat -DryRun
```

## Glass Home (custom home screen)

`GlassHome.apk` is a small home-screen app built for this TV. `glass-home/mockup.png`
is a design mockup of it, not a photo of the real app.

- **Background:** dark, with soft colours that drift slowly. The top-bar button
  cycles Midnight, Ember, Ocean, Forest, Graphite and Pure Dark. **Motion** turns
  the drift on or off.
- **Top bar:** clock and date, plus buttons for All Apps, Settings and Wi-Fi.
- **Favorites row:** your main apps. The focused one grows and shows its name.
- **Recent row:** apps you opened from Glass Home, newest first. Hidden until you
  have opened something.
- **Recommended on YouTube:** the recommendations that a YouTube app on the TV
  (SmartTube or the official one) publishes for whoever is signed in to it. If no
  app publishes any, this row shows *Trending on YouTube* instead, which needs
  the YouTube API key (option 7).
- **From channels you watch:** new uploads from channels whose videos you opened
  from Glass Home. Needs the YouTube API key; shows popular music until there is
  some history.
- **Continue watching:** what Disney+, Hulu and your other apps report you are
  part-way through, newest first, with a progress bar. Pressing OK resumes that
  exact title in its app. Apps decide what they report, so some may list nothing.
- **Moving around:** Down moves through the rows; Back returns to the top. A row
  with nothing to show yet has a message card you can move onto, which says what
  it needs.
- **All Apps:** every app on the TV in a grid. Back closes it.
- **Hold OK on any app** for: add to or remove from favorites, move left or
  right, app info, uninstall.

### Getting a YouTube API key (free)

1. Go to <https://console.cloud.google.com> and sign in with a Google account.
2. Create a project (any name).
3. **APIs & Services > Library**, search **YouTube Data API v3**, press **Enable**.
4. **APIs & Services > Credentials > Create credentials > API key**.
5. Copy the key (it starts with `AIza`), run the tool and choose **7**.

Treat the key like a password: do not post it anywhere public.

### Permission for the two "from your apps" rows

*Recommended on YouTube* and *Continue watching* read lists that other apps
publish to Android TV, the same lists the Google home screen shows. Option 5
grants Glass Home the permission for that (`READ_TV_LISTINGS`). If it could not,
the Continue watching row shows a card: press OK on it to allow it on the TV.

The source is in `glass-home/`. To rebuild it you need a JDK and the Android SDK:
`ANDROID_HOME=/path/to/sdk glass-home/build.sh`.

## What it never touches

Casting (`mediashell`), the phone remote service, Play Store, Play services and
YouTube.

## If something goes wrong

- Run the tool again and choose **3. Undo**.
- If the PC cannot connect any more, a factory reset from
  **Settings > System > About > Factory reset** restores everything. On a
  Chromecast you can also hold the button on the back of the device.
- Keep USB debugging turned on while the home screen is replaced, so undo
  always works.
