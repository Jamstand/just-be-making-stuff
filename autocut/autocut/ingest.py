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

import json
import logging
import re
import subprocess
from pathlib import Path

from .config import Cfg
from .models import ClipInfo, Frame, save_json

logger = logging.getLogger("autocut.ingest")


def scan(folder: str | Path, cfg: Cfg, workdir: Path) -> list[ClipInfo]:
    """Scan a folder of raw clips: probe, proxy, sample frames, persist clips.json."""
    folder = Path(folder)
    workdir = Path(workdir)
    extensions = {str(e).lower() for e in cfg["ingest.extensions"]}
    workdir_resolved = workdir.resolve()

    candidates: list[Path] = []
    for path in sorted(folder.iterdir(), key=lambda p: p.name):
        if not path.is_file() or path.suffix.lower() not in extensions:
            continue
        resolved = path.resolve()
        if resolved == workdir_resolved or workdir_resolved in resolved.parents:
            continue
        candidates.append(path)

    logger.info("Scanning %s: %d candidate clip(s)", folder, len(candidates))

    clips: list[ClipInfo] = []
    for i, path in enumerate(candidates, start=1):
        clip_id = f"c{i:03d}_{_sanitize(path.stem)}"
        info = _probe_clip(clip_id, path, cfg)
        _maybe_proxy(info, cfg, workdir)
        _sample_frames(info, cfg, workdir)
        logger.info(
            "%s <- %s: %.2fs %dx%d @ %.2f fps %s/%s audio=%s proxy=%s frames=%d",
            info.id, path.name, info.duration, info.width, info.height,
            info.fps, info.vcodec, info.pix_fmt, info.has_audio,
            "yes" if info.proxy_path else "no", len(info.frames),
        )
        clips.append(info)

    save_json(clips, workdir / "clips.json")
    logger.info("Wrote %s (%d clips)", workdir / "clips.json", len(clips))
    return clips


def probe(path: str | Path, cfg: Cfg) -> dict:
    """Return ffprobe metadata for one media file."""
    path = Path(path)
    cmd = [
        str(cfg["tools.ffprobe"]), "-v", "error",
        "-print_format", "json",
        "-show_format", "-show_streams",
        str(path),
    ]
    result = _run(cmd, f"probing {path}")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"ffprobe produced invalid JSON for {path}: {exc}") from exc


def extract_frames_at(
    video: str | Path, times: list[float], out_dir: Path, cfg: Cfg
) -> list[Frame]:
    """Extract stills at the given timestamps (seconds) into out_dir."""
    out_dir = Path(out_dir)
    frames: list[Frame] = []
    for t in sorted(float(t) for t in times):
        dst = out_dir / _frame_name(t, cfg)
        _extract_frame(video, t, dst, cfg)
        frames.append(Frame(t=t, path=str(dst)))
    return frames


# ---------------------------------------------------------------------------

def _run(cmd: list[str], what: str) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    except OSError as exc:
        raise RuntimeError(f"{cmd[0]} failed while {what}: {exc}") from exc
    if result.returncode != 0:
        detail = result.stderr.strip() or f"exit code {result.returncode}"
        raise RuntimeError(f"{cmd[0]} failed while {what}: {detail}")
    return result


def _sanitize(stem: str) -> str:
    return re.sub(r"[^A-Za-z0-9_-]", "", stem) or "clip"


def _parse_rate(value: object) -> float | None:
    """Parse an ffprobe rate like '60000/1001', '30', or '29.97'."""
    if value in (None, ""):
        return None
    text = str(value)
    try:
        if "/" in text:
            num_s, _, den_s = text.partition("/")
            num, den = float(num_s), float(den_s)
            if den == 0:
                return None
            rate = num / den
        else:
            rate = float(text)
    except ValueError:
        return None
    return rate if rate > 0 else None


def _parse_float(value: object) -> float | None:
    if value in (None, ""):
        return None
    try:
        return float(str(value))
    except ValueError:
        return None


def _probe_clip(clip_id: str, path: Path, cfg: Cfg) -> ClipInfo:
    meta = probe(path, cfg)
    streams = meta.get("streams", [])
    video = next((s for s in streams if s.get("codec_type") == "video"), None)
    if video is None:
        raise RuntimeError(f"No video stream found in {path}")

    fps = _parse_rate(video.get("avg_frame_rate")) or _parse_rate(video.get("r_frame_rate"))
    if fps is None:
        raise RuntimeError(f"Could not determine frame rate of {path}")

    duration = _parse_float(meta.get("format", {}).get("duration"))
    if duration is None:
        duration = _parse_float(video.get("duration"))
    if duration is None:
        raise RuntimeError(f"Could not determine duration of {path}")

    return ClipInfo(
        id=clip_id,
        path=str(path.resolve()),
        duration=float(duration),
        fps=float(fps),
        width=int(video.get("width", 0)),
        height=int(video.get("height", 0)),
        vcodec=str(video.get("codec_name", "")),
        pix_fmt=str(video.get("pix_fmt", "")),
        has_audio=any(s.get("codec_type") == "audio" for s in streams),
        size_bytes=int(path.stat().st_size),
    )


def _needs_proxy(info: ClipInfo, cfg: Cfg) -> bool:
    mode = str(cfg["ingest.proxy.mode"]).lower()
    if mode == "never":
        return False
    if mode == "always":
        return True
    force_codecs = {str(c).lower() for c in cfg["ingest.proxy.force_codecs"]}
    force_pix_fmts = {str(f).lower() for f in cfg["ingest.proxy.force_pix_fmts"]}
    return info.vcodec.lower() in force_codecs or info.pix_fmt.lower() in force_pix_fmts


def _maybe_proxy(info: ClipInfo, cfg: Cfg, workdir: Path) -> None:
    if not _needs_proxy(info, cfg):
        return
    src = Path(info.path)
    dst = workdir / "proxies" / f"{info.id}.mp4"
    if dst.exists() and dst.stat().st_mtime > src.stat().st_mtime:
        info.proxy_path = str(dst)
        return
    dst.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        str(cfg["tools.ffmpeg"]), "-y", "-v", "error",
        "-i", str(src),
        "-map", "0:v:0", "-an",
        "-vf", f"scale=-2:{int(cfg['ingest.proxy.height'])}",
        "-c:v", str(cfg["ingest.proxy.vcodec"]),
        "-crf", str(cfg["ingest.proxy.crf"]),
        "-preset", str(cfg["ingest.proxy.preset"]),
        "-pix_fmt", "yuv420p",
        "-movflags", "+faststart",
        str(dst),
    ]
    logger.info("Generating proxy for %s -> %s", info.id, dst)
    _run(cmd, f"generating proxy for {src}")
    info.proxy_path = str(dst)


def _frame_name(t: float, cfg: Cfg) -> str:
    ext = str(cfg["ingest.frames.format"]).lstrip(".")
    return f"f_{int(round(t * 1000)):08d}.{ext}"


def _extract_frame(video: str | Path, t: float, dst: Path, cfg: Cfg) -> None:
    if dst.exists():
        return
    dst.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        str(cfg["tools.ffmpeg"]), "-y", "-v", "error",
        "-ss", f"{t:.3f}",
        "-i", str(video),
        "-frames:v", "1",
        "-q:v", str(cfg["ingest.frames.quality"]),
        "-vf", f"scale=-2:'min({int(cfg['ingest.frames.max_height'])},ih)'",
        str(dst),
    ]
    _run(cmd, f"extracting frame at {t:.3f}s from {video}")


def _sample_frames(info: ClipInfo, cfg: Cfg, workdir: Path) -> None:
    n = int(cfg["ingest.frames.per_clip"])
    if n <= 0:
        info.frames = []
        return
    out_dir = workdir / "frames" / info.id
    frames: list[Frame] = []
    for k in range(n):
        t = (k + 0.5) * info.duration / n
        dst = out_dir / _frame_name(t, cfg)
        _extract_frame(info.analysis_path, t, dst, cfg)
        frames.append(Frame(t=float(t), path=str(dst)))
    info.frames = frames
