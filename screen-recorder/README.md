# Recshot

A screen recorder and screenshot tool for Windows 10/11. It records high resolution with your NVIDIA
GPU (NVENC), captures your mic and your computer's sound, and stays light on the CPU.

- **Record** a whole screen, one window (even when other windows cover it), or an area you drag out.
- **Native resolution** at up to 144 fps, encoded on the GPU: NVIDIA NVENC (H.264 / HEVC / AV1),
  AMD AMF or Intel Quick Sync, with CPU x264 as a fallback.
- **Audio**: microphone and computer sound. With both on, the video gets three tracks: a mix of
  both (what players play), computer sound only, and mic only.
- **Webcam bubble** in any corner (circle or rounded box, mirrored or not).
- **Click highlights**: a ring around the pointer each time you click.
- **Pause / resume** with no gap in the file.
- **Replay buffer**: keeps the last 15 s – 5 min in the background. Press a hotkey to save it.
- **Screenshots**: full-resolution PNG, copied to the clipboard. Drag an area or click a screen
  (the screen freezes while you pick), or shoot a single window.
- **Global hotkeys** that work while you're in other apps.

## Getting it

1. Open the repository on GitHub → **Actions** → **Recshot (Windows screen recorder)** → the latest
   green run → download **Recshot-win-x64** under *Artifacts*.
2. Unzip it anywhere, e.g. `C:\Tools\Recshot`. Keep `ffmpeg.exe` next to `Recshot.exe`.
3. Run `Recshot.exe`. The app isn't code-signed, so Windows SmartScreen may warn the first time:
   click **More info → Run anyway**.

Nothing else is needed: the .NET runtime is built into the exe.

## Default hotkeys

| Action | Keys |
| --- | --- |
| Start / stop recording | `Ctrl+Shift+F9` |
| Pause / resume | `Ctrl+Shift+F10` |
| Save replay | `Ctrl+Shift+F11` |
| Screenshot (drag an area or click a screen) | `Ctrl+Shift+F12` |

To change one, click its box in the **Hotkeys** section and press the new combination. If another app
already uses a combination, Recshot says so.

## Files

- Videos and replays: `Videos\Recshot` (MP4, or MKV if you choose it)
- Screenshots: `Pictures\Recshot` (PNG)

Both folders can be changed in the app. While recording, Recshot writes an MKV, so a crash or power
cut still leaves a playable file. When you stop, it's rewrapped into an MP4 in a second or two,
without re-encoding.

## Recommended settings

For most uses: **Native** resolution, **60 fps**, **High** quality, **NVIDIA NVENC · H.264**.

- **HEVC** files are about 40% smaller at the same quality. Use it for long recordings, or for
  screens wider than 4096 pixels, which H.264 can't encode.
- **AV1** files are smaller still. It needs an RTX 40- or 50-series card, and older editors may not open it.
- **Ultra** quality is close to lossless, and files get big.
- If you record games at 120/144 fps, make sure the game isn't using all of your GPU.

## Audio tracks

With both computer sound and microphone on:

1. **Mixed**: both together. This is what normal players play.
2. **Computer sound** only.
3. **Microphone** only.

In Premiere, DaVinci Resolve, Shotcut, Vegas and similar, you can mute or rebalance tracks 2 and 3
separately, for example to turn the game down under your voice. The volume sliders apply live,
even while recording.

## Troubleshooting

- **Recording shows black for a video or streaming site:** DRM-protected video (Netflix etc.)
  blocks capture on purpose.
- **No microphone audio:** Windows Settings → Privacy & security → Microphone → turn on *Let
  desktop apps access your microphone*.
- **Webcam won't start:** close other apps using the camera, and check Privacy & security → Camera.
- **Computer sound is silent:** Recshot records the output device that was the default when
  recording started. If you switched to headphones mid-recording, pick the device in the list.
- **Yellow border around the screen (Windows 10):** that's Windows showing that capture is on.
  Windows 11 lets Recshot hide it.
- **HDR monitors:** captures are SDR. With HDR on, colours can look washed out.
- **"Couldn't record" with an FFmpeg message:** the log has details. It's in
  `%LOCALAPPDATA%\Recshot\logs` (paste that into Explorer's address bar).
- **Check the whole pipeline:** `Recshot.exe --selftest C:\some\folder` records a short test clip,
  a replay and screenshots into that folder, and writes `selftest.log`.

## How it works

```
Windows.Graphics.Capture ─► D3D11 texture ─► Direct2D compose ─► GPU BGRA→NV12 ─► readback ─┐
 (monitor or window)          (crop/scale)    (clicks, webcam)    (video processor)          │ named pipe
                                                                                             ▼
WASAPI loopback (computer sound) ─► clock alignment ─► float PCM ───────── named pipe ─►  ffmpeg.exe
WASAPI capture (microphone)      ─► clock alignment ─► float PCM ───────── named pipe ─►  (NVENC, AAC,
                                                                                         mix, mux)
```

- Video comes out at a constant frame rate locked to the wall clock. A static screen repeats
  frames, so the video stays in sync with the audio.
- Audio packets are placed on the same clock by when they arrived. Loopback sends nothing while
  nothing is playing, so the gaps are filled with silence. Drift between the sound card and the
  system clock is corrected in small steps.
- Recording and the replay buffer share one capture pipeline. The replay buffer encodes 1-second
  MPEG-TS segments in a ring of files in `%TEMP%`. Saving joins the newest ones without re-encoding.

## Building from source

Requires the [.NET 10 SDK](https://dotnet.microsoft.com/download).

```
dotnet publish screen-recorder/Recshot/Recshot.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o dist
```

Then put an `ffmpeg.exe` (e.g. from https://www.gyan.dev/ffmpeg/builds/) next to `Recshot.exe`.

`screen-recorder/Recshot.PipelineTests` checks the FFmpeg command lines, audio timing and replay
saving end to end on any OS with FFmpeg installed: `dotnet run --project screen-recorder/Recshot.PipelineTests`.

## Licences

Recshot's own code is in this repository. The downloadable build includes an FFmpeg build
(GPL, see `FFmpeg-LICENSE.txt`) from gyan.dev or BtbN.
