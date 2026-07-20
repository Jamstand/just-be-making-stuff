# AUTOCUT

AI-assisted automatic video editor for car content. Feed it a folder of raw
clips (Sony a6700, 4K 59.94 H.264/H.265) plus one music track; get back a
rough-cut vertical reel (1080x1920, 15-45s) cut to the beat from the best
segments of your footage, plus a JSON EDL and a Resolve-importable FCPXML
timeline for finishing the cut by hand.

```
raw clips + song
      |
   ingest.py    scan folder, ffprobe metadata, proxies for H.265/10-bit/4:2:2,
      |         sampled stills per clip
   audio.py     librosa: beats, downbeats, energy curve, impact points
      |
   analyze.py   PySceneDetect internal cuts; OpenCV sharpness / motion /
      |         exposure / horizon tilt -> heuristic segment scores
   judge.py     Anthropic API: frames + style brief -> composition / energy /
      |         hero potential / clutter + shot type + subject position
   taste.py     (stub) preference memory: learns from your keep/reject feedback
      |
   assemble.py  cuts land on beats, hero shots on impacts, shot length follows
      |         the energy curve; sequencing rules; subject-aware 9:16 crop;
      |         ffmpeg render + optional LUT; EDL JSON + FCPXML export
   review.py    (v2 skeleton) self-critique loop: sample the render, ask the
                API for EDL revisions, re-render, max 2 iterations
```

Everything tunable — cut pacing, scoring weights, the style brief the AI
judges against, LUT path, codecs — lives in `style.yaml`. No magic numbers in
code.

## Setup (Windows)

1. **Python 3.11+** — https://www.python.org/downloads/ (check "Add to PATH")
2. **ffmpeg** — `winget install Gyan.FFmpeg` (or `choco install ffmpeg`),
   then reopen the terminal so `ffmpeg`/`ffprobe` are on PATH.
3. Install AUTOCUT:

   ```powershell
   cd autocut
   python -m venv .venv
   .venv\Scripts\activate
   pip install -e .
   ```

4. **Anthropic API key** (for the AI judge — optional but the whole point):

   ```powershell
   setx ANTHROPIC_API_KEY "sk-ant-..."
   ```

   Reopen the terminal. Without a key the pipeline still works as a pure
   beat-cut using the heuristic scores (`judge.enabled: auto`).

Linux/macOS: same, with `source .venv/bin/activate` and `export ANTHROPIC_API_KEY=...`.

## Use

```powershell
# score a folder of clips (writes <folder>\_autocut\)
vanscut analyze D:\shoots\gt3\clips

# the actual thing: rough-cut reel, cut to the beat
vanscut cut D:\shoots\gt3\clips D:\music\song.mp3 --out gt3_reel.mp4

# options
vanscut cut <folder> <song> --style my_style.yaml --duration 30 --no-judge

# self-critique loop on the latest render (v2 skeleton)
vanscut review D:\shoots\gt3\clips

# teach it your taste: keep/reject each cut in the latest EDL
vanscut feedback D:\shoots\gt3\clips
```

Outputs land in `<folder>/_autocut/`:

| artifact | what |
|---|---|
| `clips.json` | probed clip metadata |
| `proxies/` | H.264 proxies for clips OpenCV can't decode (H.265, 10-bit, 4:2:2) |
| `frames/` | sampled stills (judge + taste input) |
| `music.json` | beats, downbeats, energy curve, impact points |
| `segments.json` | every candidate segment with heuristic + judge scores |
| `edl.json` | the edit decision list — review this |
| `renders/reel_v1.mp4` | the rough cut (all review iterations kept) |
| `reel.fcpxml` | import into DaVinci Resolve to finish manually |

## Configuring the judge model

In `style.yaml`:

```yaml
judge:
  model: claude-sonnet-4-6   # default; or claude-opus-4-8 / claude-fable-5
```

Frames are batched (`segments_per_request`) and responses cached on disk
(`_autocut/judge_cache/`), so re-runs after tweaking cut settings cost zero
API calls.

## Test without real footage

```powershell
python scripts/make_test_media.py testdata
vanscut cut testdata\clips testdata\song.wav
```

generates synthetic 4K clips + a 120 BPM beat track and runs end-to-end.

## Development order / status

- [x] project skeleton + module interfaces
- [x] audio.py — beat/energy analysis
- [x] ingest.py — probe, proxies, frame sampling
- [x] analyze.py — scenes + heuristic scores
- [x] assemble.py — beat-cut, render, EDL, FCPXML  *(dumb beat-cut works end-to-end)*
- [x] judge.py — AI scoring, batched + cached
- [x] review.py — critique-loop skeleton
- [ ] taste.py — interfaces wired; ranker activates at 30+ feedback examples
