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
| 5. Install Glass Home | Installs `GlassHome.apk` (the custom home screen in this folder), shows it to you, then offers to turn off the Google TV home screen so the Home button opens Glass Home. Rolls back by itself if it does not come up. |

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
- **All Apps:** every app on the TV in a grid. Back closes it.
- **Hold OK on any app** for: add to or remove from favorites, move left or
  right, app info, uninstall.

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
