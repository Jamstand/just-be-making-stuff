"""Ingest: scan the input folder, probe clips, generate proxies, sample frames.

Contract
--------
scan(folder, cfg, workdir) -> list[ClipInfo]
    * Find files matching cfg["ingest.extensions"] (non-recursive), sorted.
    * Probe each with ffprobe (JSON output) -> duration/fps/resolution/codec/
      pix_fmt/audio presence.
    * Proxies: per cfg["ingest.proxy.mode"]:
        - "never": no proxies
        - "always": every clip
        - "auto": only clips whose vcodec is in force_codecs or pix_fmt in
          force_pix_fmts (H.265 / 10-bit / 4:2:2 handled gracefully here)
      Proxy: H.264 yuv420p, scaled to proxy.height, crf/preset from cfg,
      audio stripped, written to workdir/proxies/<clip_id>.mp4.
      Skip work when the proxy already exists and is newer than the source.
    * Frames: sample cfg["ingest.frames.per_clip"] stills uniformly across the
      clip duration to workdir/frames/<clip_id>/  (jpg, downscaled to
      frames.max_height). Reuse existing frames when present.
    * Persist the clip list to workdir/clips.json (models.save_json) and
      return it.

probe(path, cfg) -> dict          -- raw ffprobe fields for one file
extract_frames_at(video, times, out_dir, cfg) -> list[Frame]
    -- extract stills at specific timestamps (used by judge/review); one
       ffmpeg invocation per call where practical.

All subprocess calls MUST use argument lists (no shell=True) so paths with
spaces work on Windows. ffmpeg/ffprobe binaries come from cfg["tools.*"].
"""

from __future__ import annotations

from pathlib import Path

from .config import Cfg
from .models import ClipInfo, Frame


def scan(folder: str | Path, cfg: Cfg, workdir: Path) -> list[ClipInfo]:
    """Scan a folder of raw clips: probe, proxy, sample frames, persist clips.json."""
    raise NotImplementedError


def probe(path: str | Path, cfg: Cfg) -> dict:
    """Return ffprobe metadata for one media file."""
    raise NotImplementedError


def extract_frames_at(
    video: str | Path, times: list[float], out_dir: Path, cfg: Cfg
) -> list[Frame]:
    """Extract stills at the given timestamps (seconds) into out_dir."""
    raise NotImplementedError
