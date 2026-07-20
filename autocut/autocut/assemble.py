"""The editor: match segments to the beat grid, sequence, reframe, render, export.

Contract
--------
build_edl(segments, clips, music, cfg, workdir) -> EDL
    * Target duration: min(cfg["assemble.target_duration_s"], music.duration),
      clamped to cfg["output.min/max_duration_s"].
    * Beat grid: cuts land ON beats. Walk the beat list from t=0; at each cut
      point choose beats-per-shot from the energy curve:
        e = music.energy_at(t); map e linearly from
        (cut.energy_lo -> cut.slow_beats) to (cut.energy_hi -> cut.fast_beats)
      then clamp shot length to [cut.min_shot_s, cut.max_shot_s] by
      adding/removing beats. Faster cutting at high energy. A beatless gap
      longer than max_shot_s (quiet intro the beat tracker skipped) is
      subdivided into equal sub-shots - there are no beats there to hit.
    * Hero shots: when sequencing.hero_on_impact, reserve the shots that start
      nearest each music.impact_point for the highest hero-scoring segments
      (judge.hero when present, else final score).
    * Sequencing rules (all from cfg["assemble.sequencing"]):
        - opening: first shot prefers shot_type in `opening`
        - ending: last shot prefers `ending` type (best hero)
        - avoid_repeat_clip: same source clip not reused within N shots
        - alternate_types: avoid same shot_type back-to-back when possible
      Selection: greedy by final score subject to the constraints; a segment
      is trimmed to the shot length (take the middle of the segment window).
      A segment may be used at most once; constraints relax (alternate_types,
      then avoid_repeat_clip, then reuse) only when candidates run out.
    * Reframe 16:9 -> 9:16: crop_x per event:
        - mode "center": 0.5
        - mode "subject": 0.5 + (judge.subject_x - 0.5) * reframe.max_offset
          when judge scores exist, else 0.5; clamped to [0, 1].
    * Fill EDLEvents with src/rec times (rec contiguous from 0), stamp
      created_at (UTC ISO), persist to workdir/edl.json, return.

render(edl, clips, cfg, out_path) -> Path
    * ffmpeg-only, two passes: (1) each event is cut from its ORIGINAL source
      (not the proxy) with input seeking and encoded at final quality
      (fps/LUT/scale/crop to output.width x output.height using crop_x);
      (2) the parts are concatenated with stream copy and the music bed is
      trimmed to the video length with an audio_fade_s fade-out.
      One decoder at a time keeps memory bounded and skips decoding footage
      outside the cut windows.
    * Optional LUT: cfg["assemble.render.lut"] -> lut3d per part (path
      escaped for filtergraph syntax).
    * H.264 via crf/preset/pix_fmt from cfg, +faststart for social upload.

export_fcpxml(edl, clips, cfg, out_path) -> Path
    * FCPXML 1.9 timeline (importable by DaVinci Resolve): one asset per used
      source clip, one spine with asset-clips using src offsets/durations and
      the output format. All times are rationals frame-aligned to the output
      fps timebase (Resolve rejects non-frame-aligned values).

export_resolve(edl, clips, cfg) -> bool
    * Best effort: import DaVinciResolveScript (env vars RESOLVE_SCRIPT_API /
      standard install paths), build the timeline via the scripting API when
      Resolve is running; return False (with a log line) otherwise. Never
      crash the pipeline over this.
"""

from __future__ import annotations

import logging
import math
import os
import subprocess
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .config import Cfg
from .models import (
    EDL,
    SCHEMA_VERSION,
    ClipInfo,
    EDLEvent,
    MusicAnalysis,
    ScoredSegment,
    save_json,
)

logger = logging.getLogger("autocut.assemble")

# Tie-breaker internals, not style knobs (see style.yaml for the real knobs):
_OPENING_SCORE_RATIO = 0.7    # opening/ending-type candidate must reach 70% of the pool best
_ALTERNATE_SCORE_RATIO = 0.9  # a different-type alternative within 90% justifies skipping
_TYPE_MOTION_HI = 0.6         # heuristic shot_type fallback: motion >= -> "motion"
_TYPE_MOTION_LO = 0.25        # heuristic shot_type fallback: motion <= -> "static"
_MUSIC_TAIL_S = 0.5           # never cut into the last half second of the track
_T_EPS = 1e-6                 # float tolerance for time comparisons


# ---------------------------------------------------------------------------
# build_edl

def _beats_per_shot(e: float, cfg: Cfg) -> int:
    """Beats per shot for energy e: linear (energy_lo->slow) .. (energy_hi->fast)."""
    lo = float(cfg["assemble.cut.energy_lo"])
    hi = float(cfg["assemble.cut.energy_hi"])
    slow = int(cfg["assemble.cut.slow_beats"])
    fast = int(cfg["assemble.cut.fast_beats"])
    if hi <= lo:
        bps = fast if float(e) >= hi else slow
    else:
        w = min(1.0, max(0.0, (float(e) - lo) / (hi - lo)))
        bps = round(slow + (fast - slow) * w)
    return max(min(slow, fast), min(max(slow, fast), int(bps)))


def _build_slots(music: MusicAnalysis, target: float, cfg: Cfg) -> list[tuple[float, float]]:
    """Cut the timeline [0, target] into shot slots whose boundaries are beats."""
    beats = sorted({round(float(b), 9) for b in music.beats if float(b) >= 0.0})
    if target <= 0.0 or len(beats) < 2:
        return []
    # The timeline starts at 0 even when the first beat lands later.
    grid = ([0.0] + beats) if beats[0] > _T_EPS else beats
    min_shot = float(cfg["assemble.cut.min_shot_s"])
    max_shot = float(cfg["assemble.cut.max_shot_s"])

    slots: list[tuple[float, float]] = []
    i = 0
    last = len(grid) - 1
    while i < last and grid[i] < target - _T_EPS:
        t = grid[i]
        j = max(i + 1, min(i + _beats_per_shot(music.energy_at(t), cfg), last))
        while grid[j] - t < min_shot - _T_EPS and j < last:
            j += 1
        # Never shrink below one beat.
        while grid[j] - t > max_shot + _T_EPS and j > i + 1:
            j -= 1
        end = min(grid[j], float(target))  # final trim: allowed off-beat cut
        if end - t > max_shot + _T_EPS:
            # A single beatless gap (e.g. a quiet intro the beat tracker
            # skipped): no beats inside to align to, so subdivide into equal
            # sub-shots no longer than max_shot_s.
            parts = math.ceil((end - t) / max_shot)
            step = (end - t) / parts
            for p in range(parts):
                slots.append((t + p * step, min(t + (p + 1) * step, end)))
        else:
            slots.append((t, end))
        if grid[j] >= target - _T_EPS:
            break
        i = j
    return slots


def _shot_type(ss: ScoredSegment) -> str:
    if ss.judge is not None and ss.judge.shot_type:
        return str(ss.judge.shot_type)
    m = float(ss.heuristic.motion)
    if m >= _TYPE_MOTION_HI:
        return "motion"
    if m <= _TYPE_MOTION_LO:
        return "static"
    return "other"


def _hero_score(ss: ScoredSegment) -> float:
    return float(ss.judge.hero) if ss.judge is not None else float(ss.final)


def _crop_x(ss: ScoredSegment, mode: str, max_offset: float) -> float:
    x = 0.5
    if mode == "subject" and ss.judge is not None:
        x = 0.5 + (float(ss.judge.subject_x) - 0.5) * max_offset
    return float(min(1.0, max(0.0, x)))


def _choose(
    cands: list[ScoredSegment],
    k: int,
    n_slots: int,
    opening: list[str],
    ending: str,
    use_alternate: bool,
    prev_type: str | None,
) -> ScoredSegment:
    """Pick from cands (already sorted by .final desc) applying soft preferences."""
    best = cands[0]
    if k == 0 and opening:
        pref = next((c for c in cands if _shot_type(c) in opening), None)
        if pref is not None and float(pref.final) >= _OPENING_SCORE_RATIO * float(best.final):
            return pref
    if k == n_slots - 1 and ending and ending != "hero":
        pref = next((c for c in cands if _shot_type(c) == ending), None)
        if pref is not None and float(pref.final) >= _OPENING_SCORE_RATIO * float(best.final):
            return pref
    if use_alternate and prev_type is not None:
        for i, c in enumerate(cands):
            if _shot_type(c) != prev_type:
                return c
            alt = next((a for a in cands[i + 1:] if _shot_type(a) != prev_type), None)
            if alt is None or float(alt.final) < _ALTERNATE_SCORE_RATIO * float(c.final):
                return c
    return best


def _assign(
    slots: list[tuple[float, float]],
    pool: list[ScoredSegment],
    music: MusicAnalysis,
    cfg: Cfg,
    clip_by_id: dict[str, ClipInfo],
) -> tuple[dict[int, ScoredSegment], set[int]]:
    """Map slot index -> segment. Returns (assignment, hero-slot indices)."""
    n = len(slots)
    assigned: dict[int, ScoredSegment] = {}
    hero_marked: set[int] = set()
    if n == 0:
        return assigned, hero_marked
    if not pool:
        raise ValueError("no scored segments to assemble")

    avoid_n = int(cfg["assemble.sequencing.avoid_repeat_clip"])
    alternate = bool(cfg["assemble.sequencing.alternate_types"])
    opening = [str(t) for t in (cfg["assemble.sequencing.opening"] or [])]
    ending_raw = cfg["assemble.sequencing.ending"]
    ending = str(ending_raw) if ending_raw else ""
    used: set[str] = set()

    def clip_ok(k: int, clip_id: str) -> bool:
        return all(
            ss.segment.clip_id != clip_id
            for j, ss in assigned.items()
            if abs(j - k) <= avoid_n
        )

    def fits(ss: ScoredSegment, k: int) -> bool:
        return ss.segment.duration >= (slots[k][1] - slots[k][0]) - _T_EPS

    # Hero slots: the last slot when ending on a hero, then the slot starting
    # nearest each impact point. Assigned first, best hero score first.
    hero_slots: list[int] = []
    if ending == "hero":
        hero_slots.append(n - 1)
    if bool(cfg["assemble.sequencing.hero_on_impact"]):
        for p in music.impact_points:
            k = min(range(n), key=lambda i: abs(slots[i][0] - float(p)))
            if k not in hero_slots:
                hero_slots.append(k)

    hero_pool = sorted(pool, key=_hero_score, reverse=True)
    for k in hero_slots:
        cand = next(
            (c for c in hero_pool
             if c.segment.id not in used and fits(c, k) and clip_ok(k, c.segment.clip_id)),
            None,
        )
        if cand is None:
            logger.warning("hero slot %d: relaxing avoid_repeat_clip", k)
            cand = next(
                (c for c in hero_pool if c.segment.id not in used and fits(c, k)), None
            )
        if cand is None:
            logger.warning("hero slot %d: no fitting candidate, will fill greedily", k)
            continue
        assigned[k] = cand
        used.add(cand.segment.id)
        hero_marked.add(k)

    for k in range(n):
        if k in assigned:
            continue
        slot_len = slots[k][1] - slots[k][0]

        def candidates(allow_repeat: bool, allow_reuse: bool) -> list[ScoredSegment]:
            return [
                c for c in pool
                if (allow_reuse or c.segment.id not in used)
                and c.segment.duration >= slot_len - _T_EPS
                and (allow_repeat or clip_ok(k, c.segment.clip_id))
            ]

        use_alternate = alternate
        cands = candidates(False, False)
        if not cands:
            if use_alternate:
                # alternate_types is a pick-time softener; dropping it first per spec.
                use_alternate = False
                logger.warning("slot %d: relaxing alternate_types", k)
            logger.warning("slot %d: relaxing avoid_repeat_clip", k)
            cands = candidates(True, False)
        if not cands:
            logger.warning("slot %d: allowing segment reuse", k)
            cands = candidates(True, True)
        if not cands:
            # Last resort: no single segment covers the slot, but a source
            # clip might - the trim step extends past segment bounds into the
            # clip when needed.
            logger.warning("slot %d: extending segments into their source clips", k)
            cands = [
                c for c in pool
                if (clip := clip_by_id.get(c.segment.clip_id)) is not None
                and float(clip.duration) >= slot_len - _T_EPS
            ]
        if not cands:
            raise RuntimeError(
                f"no segment or source clip is long enough for slot {k} "
                f"({slot_len:.2f}s) even after relaxing all constraints"
            )

        prev_type = _shot_type(assigned[k - 1]) if (k - 1) in assigned else None
        chosen = _choose(cands, k, n, opening, ending, use_alternate, prev_type)
        assigned[k] = chosen
        used.add(chosen.segment.id)

    return assigned, hero_marked


def build_edl(
    segments: list[ScoredSegment],
    clips: list[ClipInfo],
    music: MusicAnalysis,
    cfg: Cfg,
    workdir: Path,
) -> EDL:
    """Sequence the best segments onto the beat grid; persist + return the EDL."""
    target = min(
        max(float(cfg["assemble.target_duration_s"]), float(cfg["output.min_duration_s"])),
        float(cfg["output.max_duration_s"]),
    )
    target = min(target, float(music.duration) - _MUSIC_TAIL_S)

    slots = _build_slots(music, target, cfg)
    if not slots:
        logger.warning("no cut slots produced (beats=%d, target=%.2fs)", len(music.beats), target)

    pool = sorted(segments, key=lambda s: float(s.final), reverse=True)
    clip_by_id = {c.id: c for c in clips}
    assigned, hero_marked = (
        _assign(slots, pool, music, cfg, clip_by_id) if slots else ({}, set())
    )

    mode = str(cfg["assemble.reframe.mode"])
    max_offset = float(cfg["assemble.reframe.max_offset"])

    events: list[EDLEvent] = []
    for k, (rec_in, rec_out) in enumerate(slots):
        ss = assigned[k]
        seg = ss.segment
        shot = rec_out - rec_in
        clip = clip_by_id.get(seg.clip_id)
        src_in = seg.start + (seg.duration - shot) / 2.0
        if shot <= seg.duration + _T_EPS:
            src_in = min(max(src_in, seg.start), max(seg.start, seg.end - shot))
        else:
            # Segment shorter than the slot: extend into the source clip.
            clip_end = float(clip.duration) if clip else seg.end
            src_in = min(max(src_in, 0.0), max(0.0, clip_end - shot))
        events.append(
            EDLEvent(
                idx=k,
                segment_id=str(seg.id),
                clip_id=str(seg.clip_id),
                clip_path=str(clip.path) if clip else "",
                src_in=float(src_in),
                src_out=float(src_in + shot),
                rec_in=float(rec_in),
                rec_out=float(rec_out),
                shot_type=_shot_type(ss),
                is_hero=k in hero_marked,
                crop_x=_crop_x(ss, mode, max_offset),
                score=float(ss.final),
                rationale=str(ss.judge.rationale) if ss.judge is not None else "",
            )
        )

    edl = EDL(
        version=SCHEMA_VERSION,
        music_path=str(music.path),
        style_source=str(cfg.source) if cfg.source else None,
        target_duration=float(target),
        output={
            "width": int(cfg["output.width"]),
            "height": int(cfg["output.height"]),
            "fps": float(cfg["output.fps"]),
        },
        events=events,
        created_at=datetime.now(timezone.utc).isoformat(),
    )
    out_json = Path(workdir) / "edl.json"
    save_json(edl, out_json)
    logger.info(
        "EDL: %d shots, %.2fs of %.2fs target, %d hero -> %s",
        len(events), edl.duration, target, len(hero_marked), out_json,
    )
    return edl


# ---------------------------------------------------------------------------
# render

def _round_even(v: float) -> int:
    return max(2, int(round(v / 2.0)) * 2)


def _cover_geometry(cw: int, ch: int, out_w: int, out_h: int, crop_x: float) -> tuple[int, int, int, int]:
    """Scale-to-cover geometry: returns (scale_w, scale_h, crop_x_px, crop_y_px)."""
    sh = out_h
    sw = _round_even(cw * out_h / ch)
    if sw < out_w:
        sw = out_w
        sh = max(out_h, _round_even(ch * out_w / cw))
        x = 0
        y = (sh - out_h) // 2
    else:
        y = 0
        x = min(max(int(round(crop_x * sw - out_w / 2.0)), 0), sw - out_w)
    return sw, sh, x, y


def _escape_filter_path(path: str) -> str:
    """Escape a filename for use inside an ffmpeg filtergraph option value."""
    return path.replace("\\", "/").replace(":", "\\:").replace(",", "\\,")


def _run_ffmpeg(cmd: list[str], what: str) -> None:
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        tail = (proc.stderr or "").strip()[-2000:]
        raise RuntimeError(f"ffmpeg {what} failed (exit {proc.returncode}):\n{tail}")


def render(edl: EDL, clips: list[ClipInfo], cfg: Cfg, out_path: str | Path) -> Path:
    """Render the EDL with ffmpeg: 1080x1920 H.264 + music bed (+ optional LUT).

    Two passes keep decode work and memory bounded (one 4K decoder at a time,
    input seeking instead of decoding whole sources): every event is cut and
    encoded at final quality as an intermediate part, then the parts are
    concatenated with stream copy while the music bed is trimmed, faded and
    encoded once.
    """
    out_path = Path(out_path)
    if not edl.events:
        raise ValueError("EDL has no events to render")

    out_w = int(cfg["output.width"])
    out_h = int(cfg["output.height"])
    fps = float(cfg["output.fps"])
    ffmpeg = str(cfg["tools.ffmpeg"])
    pix_fmt = str(cfg["assemble.render.pix_fmt"])
    clip_by_id = {c.id: c for c in clips}

    lut = cfg["assemble.render.lut"]
    lut_step = f"lut3d={_escape_filter_path(str(lut))}," if lut else ""
    fps_s = f"{fps:g}"

    out_path.parent.mkdir(parents=True, exist_ok=True)
    parts_dir = out_path.parent / f"{out_path.stem}_parts"
    parts_dir.mkdir(parents=True, exist_ok=True)

    dur = float(edl.duration)
    logger.info("rendering %d cuts (%.2fs) -> %s", len(edl.events), dur, out_path)

    part_paths: list[Path] = []
    for ev in edl.events:
        clip = clip_by_id.get(ev.clip_id)
        if clip is None:
            raise KeyError(f"EDL event {ev.idx} references unknown clip {ev.clip_id!r}")
        sw, sh, x, y = _cover_geometry(clip.width, clip.height, out_w, out_h, ev.crop_x)
        vf = (
            f"fps={fps_s},{lut_step}scale={sw}:{sh},"
            f"crop={out_w}:{out_h}:{x}:{y},format={pix_fmt}"
        )
        part = parts_dir / f"part_{ev.idx:03d}.mp4"
        _run_ffmpeg(
            [
                ffmpeg, "-y", "-v", "error",
                "-ss", f"{ev.src_in:.6f}",
                "-i", str(ev.clip_path),
                "-t", f"{ev.src_out - ev.src_in:.6f}",
                "-an",
                "-vf", vf,
                "-c:v", str(cfg["assemble.render.vcodec"]),
                "-crf", str(cfg["assemble.render.crf"]),
                "-preset", str(cfg["assemble.render.preset"]),
                # One shared timescale so the concat pass can stream-copy.
                "-video_track_timescale", "90000",
                str(part),
            ],
            f"cut {ev.idx} ({Path(ev.clip_path).name})",
        )
        part_paths.append(part)
        logger.info("  cut %d/%d done", ev.idx + 1, len(edl.events))

    concat_list = parts_dir / "concat.txt"
    concat_list.write_text(
        "".join("file '{}'\n".format(p.resolve().as_posix().replace("'", r"'\''"))
                for p in part_paths),
        encoding="utf-8",
    )

    fade = float(cfg["assemble.render.audio_fade_s"])
    fade_start = max(0.0, dur - fade)
    _run_ffmpeg(
        [
            ffmpeg, "-y", "-v", "error",
            "-f", "concat", "-safe", "0", "-i", str(concat_list),
            "-i", str(edl.music_path),
            "-filter_complex",
            f"[1:a]atrim=0:{dur:.6f},afade=t=out:st={fade_start:.6f}:d={fade:.6f}[aout]",
            "-map", "0:v:0", "-map", "[aout]",
            "-c:v", "copy",
            "-c:a", "aac", "-b:a", str(cfg["assemble.render.audio_bitrate"]),
            "-movflags", "+faststart",
            str(out_path),
        ],
        "concat",
    )
    logger.info("render complete: %s", out_path)
    return out_path


# ---------------------------------------------------------------------------
# FCPXML export

def _fps_rational(fps: float) -> tuple[int, int]:
    """frameDuration numerator/denominator for the output timebase."""
    for ntsc, pair in ((29.97, (1001, 30000)), (59.94, (1001, 60000)), (23.976, (1001, 24000))):
        if abs(fps - ntsc) < 0.005:
            return pair
    return 100, round(fps * 100)


def export_fcpxml(edl: EDL, clips: list[ClipInfo], cfg: Cfg, out_path: str | Path) -> Path:
    """Export a Resolve-importable FCPXML 1.9 timeline."""
    out_path = Path(out_path)
    out_w = int(cfg["output.width"])
    out_h = int(cfg["output.height"])
    num, den = _fps_rational(float(cfg["output.fps"]))

    def frames(t: float) -> int:
        return round(float(t) * den / num)

    def rat(f: int) -> str:
        return "0s" if f == 0 else f"{f * num}/{den}s"

    root = ET.Element("fcpxml", {"version": "1.9"})
    resources = ET.SubElement(root, "resources")
    ET.SubElement(resources, "format", {
        "id": "r0",
        "name": "FFVideoFormat",
        "width": str(out_w),
        "height": str(out_h),
        "frameDuration": f"{num}/{den}s",
    })

    clip_by_id = {c.id: c for c in clips}
    asset_of: dict[str, str] = {}
    for ev in edl.events:
        if ev.clip_id in asset_of:
            continue
        aid = f"a{len(asset_of) + 1}"
        clip = clip_by_id.get(ev.clip_id)
        src_dur = float(clip.duration) if clip else max(
            e.src_out for e in edl.events if e.clip_id == ev.clip_id
        )
        p = Path(ev.clip_path)
        try:
            uri = p.resolve().as_uri()
        except ValueError:
            uri = p.as_posix()
        ET.SubElement(resources, "asset", {
            "id": aid,
            "name": p.stem,
            "src": uri,
            "hasVideo": "1",
            "start": "0s",
            "duration": rat(max(1, frames(src_dur))),
        })
        asset_of[ev.clip_id] = aid

    library = ET.SubElement(root, "library")
    event_el = ET.SubElement(library, "event", {"name": "AUTOCUT"})
    project = ET.SubElement(event_el, "project", {"name": out_path.stem or "AUTOCUT"})
    sequence = ET.SubElement(project, "sequence", {
        "format": "r0",
        "duration": rat(frames(edl.duration)),
        "tcStart": "0s",
        "tcFormat": "NDF",
    })
    spine = ET.SubElement(sequence, "spine")
    for ev in edl.events:
        f_in, f_out = frames(ev.rec_in), frames(ev.rec_out)
        ET.SubElement(spine, "asset-clip", {
            "ref": asset_of[ev.clip_id],
            "offset": rat(f_in),
            "start": rat(frames(ev.src_in)),
            "duration": rat(max(1, f_out - f_in)),
            "name": Path(ev.clip_path).stem,
        })

    tree = ET.ElementTree(root)
    ET.indent(tree)
    body = ET.tostring(root, encoding="unicode")
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE fcpxml>\n' + body + "\n",
        encoding="utf-8",
    )
    logger.info("FCPXML exported: %s (%d clips)", out_path, len(edl.events))
    return out_path


# ---------------------------------------------------------------------------
# DaVinci Resolve scripting export

def _resolve_module() -> Any | None:
    """Import DaVinciResolveScript from env vars / standard install locations."""
    module_dirs: list[str] = []
    env_api = os.environ.get("RESOLVE_SCRIPT_API")
    if env_api:
        module_dirs.append(str(Path(env_api) / "Modules"))
    program_data = os.environ.get("PROGRAMDATA", "C:\\ProgramData")
    module_dirs += [
        str(Path(program_data) / "Blackmagic Design" / "DaVinci Resolve"
            / "Support" / "Developer" / "Scripting" / "Modules"),
        "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting/Modules",
        "/opt/resolve/Developer/Scripting/Modules",
    ]
    for d in module_dirs:
        if d not in sys.path:
            sys.path.append(d)
    if not os.environ.get("RESOLVE_SCRIPT_LIB"):
        for lib in (
            "C:\\Program Files\\Blackmagic Design\\DaVinci Resolve\\fusionscript.dll",
            "/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/Fusion/fusionscript.so",
            "/opt/resolve/libs/Fusion/fusionscript.so",
        ):
            if Path(lib).is_file():
                os.environ["RESOLVE_SCRIPT_LIB"] = lib
                break
    try:
        import DaVinciResolveScript as dvr  # type: ignore[import-not-found]
        return dvr
    except Exception:
        return None


def export_resolve(edl: EDL, clips: list[ClipInfo], cfg: Cfg) -> bool:
    """Build the timeline via DaVinci Resolve's scripting API when available."""
    mode = str(cfg["assemble.export.resolve_api"]).lower()
    if mode in ("never", "false", "off", "none"):
        logger.info("Resolve export disabled (assemble.export.resolve_api=%s)", mode)
        return False
    try:
        dvr = _resolve_module()
        if dvr is None:
            logger.info("DaVinciResolveScript not importable; skipping Resolve export")
            return False
        resolve = dvr.scriptapp("Resolve")
        if resolve is None:
            logger.info("DaVinci Resolve is not running; skipping Resolve export")
            return False
        pm = resolve.GetProjectManager()
        project = pm.CreateProject("AUTOCUT") or pm.GetCurrentProject()
        if project is None:
            logger.warning("Resolve: could not create or open a project")
            return False
        media_pool = project.GetMediaPool()

        paths: list[str] = []
        for ev in edl.events:
            if ev.clip_path not in paths:
                paths.append(ev.clip_path)
        items = media_pool.ImportMedia(paths) or []
        by_path: dict[str, Any] = {}
        for item in items:
            try:
                by_path[str(Path(str(item.GetClipProperty("File Path"))))] = item
            except Exception:
                pass
        if len(items) == len(paths):
            for p, item in zip(paths, items):
                by_path.setdefault(str(Path(p)), item)

        clip_by_id = {c.id: c for c in clips}
        infos: list[dict[str, Any]] = []
        for ev in edl.events:
            item = by_path.get(str(Path(ev.clip_path)))
            if item is None:
                logger.warning("Resolve: media pool item missing for %s", ev.clip_path)
                return False
            clip = clip_by_id.get(ev.clip_id)
            fps = float(clip.fps) if clip else float(cfg["output.fps"])
            start_f = int(round(ev.src_in * fps))
            infos.append({
                "mediaPoolItem": item,
                "startFrame": start_f,
                "endFrame": max(start_f + 1, int(round(ev.src_out * fps))),
            })
        media_pool.CreateEmptyTimeline("AUTOCUT")
        if not media_pool.AppendToTimeline(infos):
            logger.warning("Resolve: AppendToTimeline failed")
            return False
        logger.info("Resolve: timeline built with %d clips", len(infos))
        return True
    except Exception as exc:
        logger.warning("Resolve export failed: %s", exc)
        return False
