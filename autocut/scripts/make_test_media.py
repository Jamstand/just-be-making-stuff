"""Generate synthetic test media for exercising the AUTOCUT pipeline.

Creates:
    <target_dir>/clips/DSC0XXXX.MP4   - distinct 4K H.264 test clips (testsrc2
                                        variants: hue shifts, SMPTE bars, a dark
                                        clip, a moving box) plus one HEVC 10-bit
                                        4:2:2 clip when the local ffmpeg can
                                        encode it (exercises the proxy path)
    <target_dir>/song.wav             - 44.1 kHz mono float32 kick/hat pattern
                                        with a quiet first quarter so the energy
                                        curve has a ramp and a clear drop

Standalone on purpose: numpy + soundfile + stdlib only, no autocut imports.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np
import soundfile as sf

SIZE = "3840x2160"
RATE = "60000/1001"
SAMPLE_RATE = 44100

H264_ARGS = ["-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-pix_fmt", "yuv420p"]
HEVC_ARGS = ["-c:v", "libx265", "-preset", "ultrafast", "-crf", "28", "-pix_fmt", "yuv422p10le"]


def _clip_recipe(i: int, seconds: float) -> tuple[str, str | None]:
    """(lavfi source, optional -vf chain) for clip #i (1-based)."""
    testsrc = f"testsrc2=size={SIZE}:rate={RATE}:duration={seconds}"
    if i == 1:
        return f"smptebars=size={SIZE}:rate={RATE}:duration={seconds}", None
    if i == 2:
        return testsrc, "eq=brightness=-0.35"
    if i == 3:
        return testsrc, "drawbox=x='mod(t*400,iw-400)':y=ih/3:w=400:h=400:color=red@0.8:t=fill"
    return testsrc, f"hue=h={(i * 47) % 360}"


def _ffmpeg_cmd(source: str, vf: str | None, codec_args: list[str], dst: Path) -> list[str]:
    cmd = ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
           "-f", "lavfi", "-i", source]
    if vf:
        cmd += ["-vf", vf]
    return cmd + codec_args + [str(dst)]


def _make_clips(clips_dir: Path, count: int, seconds: float) -> list[Path]:
    created: list[Path] = []
    for i in range(1, count + 1):
        dst = clips_dir / f"DSC0{i:04d}.MP4"
        source, vf = _clip_recipe(i, seconds)
        print(f"encoding {dst.name} (h264) ...")
        result = subprocess.run(_ffmpeg_cmd(source, vf, H264_ARGS, dst))
        if result.returncode != 0:
            raise SystemExit(f"ffmpeg failed encoding {dst}")
        created.append(dst)

    dst = clips_dir / f"DSC0{count + 1:04d}.MP4"
    source, vf = _clip_recipe(count + 1, seconds)
    print(f"encoding {dst.name} (hevc 10-bit 4:2:2) ...")
    result = subprocess.run(_ffmpeg_cmd(source, vf, HEVC_ARGS, dst), capture_output=True)
    if result.returncode != 0:
        print("skipping HEVC test clip")
        dst.unlink(missing_ok=True)
    else:
        created.append(dst)
    return created


def _add(y: np.ndarray, burst: np.ndarray, start: int) -> None:
    if start >= len(y) or start < 0:
        return
    end = min(len(y), start + len(burst))
    y[start:end] += burst[: end - start]


def _make_song(path: Path, seconds: float, bpm: float) -> Path:
    sr = SAMPLE_RATE
    n = int(round(seconds * sr))
    y = np.zeros(n, dtype=np.float64)
    beat = 60.0 / bpm

    # Kick: exp-decaying sine sweeping 70 -> 50 Hz on every beat.
    kick_len = int(0.30 * sr)
    tk = np.arange(kick_len) / sr
    freq = 70.0 - 20.0 * np.clip(tk / 0.30, 0.0, 1.0)
    kick = np.sin(2.0 * np.pi * np.cumsum(freq) / sr) * np.exp(-tk / 0.09)

    # Hats: short noise bursts on the offbeats.
    hat_len = int(0.03 * sr)
    hat_env = np.exp(-(np.arange(hat_len) / sr) / 0.008)
    rng = np.random.default_rng(0)

    t = 0.0
    while t < seconds:
        _add(y, kick, int(t * sr))
        _add(y, rng.standard_normal(hat_len) * hat_env * 0.25, int((t + beat / 2.0) * sr))
        t += beat

    # Quiet first quarter -> energy ramp and a clear drop for impact detection.
    tx = np.arange(n) / sr
    y *= np.where(tx < seconds / 4.0, 0.3, 1.0)

    peak = float(np.max(np.abs(y))) or 1.0
    sf.write(str(path), (0.9 * y / peak).astype(np.float32), sr, subtype="FLOAT")
    return path


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Generate synthetic AUTOCUT test media")
    ap.add_argument("target_dir", help="output folder (created if missing)")
    ap.add_argument("--clips", type=int, default=6, help="number of H.264 clips (default 6)")
    ap.add_argument("--seconds", type=float, default=8.0, help="length of each clip (default 8)")
    ap.add_argument("--song-seconds", type=float, default=40.0, help="song length (default 40)")
    ap.add_argument("--bpm", type=float, default=120.0, help="song tempo (default 120)")
    args = ap.parse_args(argv)

    if shutil.which("ffmpeg") is None:
        print("ffmpeg not found on PATH "
              "(Windows: winget install Gyan.FFmpeg | Linux: apt install ffmpeg)")
        return 2

    target = Path(args.target_dir)
    clips_dir = target / "clips"
    clips_dir.mkdir(parents=True, exist_ok=True)

    created = _make_clips(clips_dir, args.clips, args.seconds)
    created.append(_make_song(target / "song.wav", args.song_seconds, args.bpm))

    print("created:")
    for p in created:
        print(f"  {p}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
