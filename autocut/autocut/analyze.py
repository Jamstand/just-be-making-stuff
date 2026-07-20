"""Segment detection + heuristic quality scoring (PySceneDetect + OpenCV).

Contract
--------
analyze_clips(clips, cfg, workdir) -> list[ScoredSegment]
    * For each clip: detect internal cuts with PySceneDetect ContentDetector
      (threshold / min_scene_len_s from cfg) on clip.analysis_path.
    * Split scenes longer than cfg["analyze.segment.max_len_s"] into windows;
      drop segments shorter than min_len_s.
    * Score each segment with score_window(); metrics sampled at
      cfg["analyze.metrics.sample_fps"], capped at max_frames per segment:
        - sharpness: variance of Laplacian on grayscale
        - motion: mean dense optical-flow magnitude (Farneback) on frames
          downscaled to flow_width
        - exposure: fraction of pixels crushed below exposure_clip_low or
          blown above exposure_clip_high (score = 1 - clipped_fraction)
        - tilt: dominant near-horizontal Hough line angle -> degrees; score
          1 - min(|deg|, tilt_max_deg)/tilt_max_deg
    * Normalize sharpness and motion by rank across ALL segments of the shoot
      (relative ranking beats absolute thresholds across lenses/light).
    * Composite score = weighted sum with cfg["analyze.weights"]; store both
      raw and normalized values in HeuristicScores; final = heuristic score
      initially (judge/taste blend in later).
    * Persist to workdir/segments.json and return.

score_window(video, start, end, cfg) -> HeuristicScores
    -- raw (un-normalized) metrics for one window; normalization happens in
       analyze_clips across the whole shoot. Set the rank-normalized fields
       equal to raw values here; analyze_clips overwrites them.
"""

from __future__ import annotations

import logging
import math
from pathlib import Path

import cv2
import numpy as np

from .config import Cfg
from .models import ClipInfo, HeuristicScores, ScoredSegment, Segment, save_json

logger = logging.getLogger("autocut.analyze")


# ---------------------------------------------------------------------------
# Scene detection + windowing

def _detect_scenes(path: str, duration: float, cfg: Cfg) -> list[tuple[float, float]]:
    """Scene boundaries in seconds; whole clip as one scene on failure/empty."""
    try:
        from scenedetect import SceneManager, open_video
        from scenedetect.detectors import ContentDetector

        video = open_video(str(path))
        fps = float(video.frame_rate)
        min_scene_frames = max(1, round(float(cfg["analyze.scene.min_scene_len_s"]) * fps))
        sm = SceneManager()
        sm.add_detector(
            ContentDetector(
                threshold=float(cfg["analyze.scene.threshold"]),
                min_scene_len=min_scene_frames,
            )
        )
        sm.detect_scenes(video)
        scenes = sm.get_scene_list()
    except Exception:
        logger.warning("scene detection failed for %s; treating as one scene", path, exc_info=True)
        return [(0.0, float(duration))]
    if not scenes:
        return [(0.0, float(duration))]
    return [(float(s.get_seconds()), float(e.get_seconds())) for s, e in scenes]


def _window_scenes(
    clip_id: str, scenes: list[tuple[float, float]], cfg: Cfg
) -> list[Segment]:
    min_len = float(cfg["analyze.segment.min_len_s"])
    max_len = float(cfg["analyze.segment.max_len_s"])
    segments: list[Segment] = []
    k = 0
    for start, end in scenes:
        length = end - start
        if length <= 0:
            continue
        n = max(1, math.ceil(length / max_len))
        win = length / n
        for i in range(n):
            w_start = start + i * win
            w_end = min(end, w_start + win)
            if w_end - w_start < min_len:
                continue
            segments.append(Segment(id=f"{clip_id}_s{k:02d}", clip_id=clip_id,
                                    start=float(w_start), end=float(w_end)))
            k += 1
    return segments


# ---------------------------------------------------------------------------
# Per-window metrics

def _sample_times(start: float, end: float, cfg: Cfg) -> list[float]:
    sample_fps = float(cfg["analyze.metrics.sample_fps"])
    max_frames = int(cfg["analyze.metrics.max_frames"])
    duration = end - start
    times = [start + i / sample_fps for i in range(int(duration * sample_fps))
             if start + i / sample_fps < end]
    if len(times) > max_frames:
        idx = np.unique(np.linspace(0, len(times) - 1, max_frames).round().astype(int))
        times = [times[i] for i in idx]
    if len(times) < 2:
        times = [start, start + duration / 2.0] if duration > 0 else [start]
    return times


def _grab_gray_frames(video: str, times: list[float]) -> list[np.ndarray]:
    cap = cv2.VideoCapture(video)
    frames: list[np.ndarray] = []
    try:
        if not cap.isOpened():
            return frames
        for t in times:
            cap.set(cv2.CAP_PROP_POS_MSEC, t * 1000.0)
            ok, frame = cap.read()
            if ok and frame is not None:
                frames.append(cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY))
    finally:
        cap.release()
    return frames


def _mean_flow_magnitude(grays: list[np.ndarray], cfg: Cfg) -> float:
    if len(grays) < 2:
        return 0.0
    flow_width = int(cfg["analyze.metrics.flow_width"])
    small = []
    for g in grays:
        h = max(1, round(g.shape[0] * flow_width / g.shape[1]))
        small.append(cv2.resize(g, (flow_width, h), interpolation=cv2.INTER_AREA))
    mags: list[float] = []
    for prev, cur in zip(small, small[1:]):
        if prev.shape != cur.shape:
            continue
        flow = cv2.calcOpticalFlowFarneback(prev, cur, None, 0.5, 3, 15, 3, 5, 1.2, 0)
        mag, _ = cv2.cartToPolar(flow[..., 0], flow[..., 1])
        mags.append(float(mag.mean()))
    return float(np.mean(mags)) if mags else 0.0


def _exposure_score(grays: list[np.ndarray], cfg: Cfg) -> float:
    lo = float(cfg["analyze.metrics.exposure_clip_low"])
    hi = float(cfg["analyze.metrics.exposure_clip_high"])
    scores = []
    for g in grays:
        v = g.astype(np.float64) / 255.0
        clipped = float(np.mean(v <= lo)) + float(np.mean(v >= hi))
        scores.append(min(1.0, max(0.0, 1.0 - clipped)))
    return float(np.mean(scores)) if scores else 0.0


def _tilt_degrees(grays: list[np.ndarray]) -> float:
    """Length-weighted median signed angle (deg) of near-horizontal lines."""
    angles: list[float] = []
    weights: list[float] = []
    for g in grays:
        med = float(np.median(g))
        edges = cv2.Canny(g, 0.66 * med, 1.33 * med)
        w = g.shape[1]
        # Hough parameters derived from frame geometry, not style knobs.
        lines = cv2.HoughLinesP(
            edges, 1, np.pi / 180.0, threshold=int(0.1 * w),
            minLineLength=0.25 * w, maxLineGap=0.02 * w,
        )
        if lines is None:
            continue
        for x1, y1, x2, y2 in lines.reshape(-1, 4):
            dx, dy = float(x2 - x1), float(y2 - y1)
            length = math.hypot(dx, dy)
            if length == 0:
                continue
            ang = math.degrees(math.atan2(dy, dx))
            if ang > 90.0:
                ang -= 180.0
            elif ang < -90.0:
                ang += 180.0
            if abs(ang) <= 30.0:
                angles.append(ang)
                weights.append(length)
    if not angles:
        return 0.0
    order = np.argsort(angles)
    cum = np.cumsum(np.asarray(weights, dtype=float)[order])
    idx = int(np.searchsorted(cum, cum[-1] / 2.0))
    return float(angles[int(order[min(idx, len(order) - 1)])])


def score_window(video: str | Path, start: float, end: float, cfg: Cfg) -> HeuristicScores:
    """Compute raw sharpness/motion/exposure/tilt metrics for one window."""
    times = _sample_times(float(start), float(end), cfg)
    grays = _grab_gray_frames(str(video), times)
    if not grays:
        logger.warning("no decodable frames in %s [%.2f-%.2f]; zeroing metrics",
                       video, start, end)
        return HeuristicScores(sharpness=0.0, motion=0.0, exposure=0.0, tilt=0.0,
                               tilt_deg=0.0, motion_raw=0.0, score=0.0)

    sharpness = float(np.mean([cv2.Laplacian(g, cv2.CV_64F).var() for g in grays]))
    motion_raw = _mean_flow_magnitude(grays, cfg)
    exposure = _exposure_score(grays, cfg)
    tilt_deg = _tilt_degrees(grays)
    tilt_max = float(cfg["analyze.tilt_max_deg"])
    tilt = 1.0 - min(abs(tilt_deg), tilt_max) / tilt_max

    # sharpness/motion hold raw values here; analyze_clips rank-normalizes
    # them across the shoot and recomputes score.
    return HeuristicScores(
        sharpness=sharpness,
        motion=motion_raw,
        exposure=exposure,
        tilt=float(tilt),
        tilt_deg=tilt_deg,
        motion_raw=motion_raw,
        score=0.0,
    )


# ---------------------------------------------------------------------------
# Shoot-wide normalization + orchestration

def _rank_normalize(values: list[float]) -> list[float]:
    """Average-rank / (n-1), ties share their mean rank; n == 1 -> 1.0."""
    n = len(values)
    if n == 0:
        return []
    if n == 1:
        return [1.0]
    arr = np.asarray(values, dtype=float)
    order = np.argsort(arr, kind="mergesort")
    ranks = np.empty(n, dtype=float)
    i = 0
    while i < n:
        j = i
        while j + 1 < n and arr[order[j + 1]] == arr[order[i]]:
            j += 1
        ranks[order[i:j + 1]] = (i + j) / 2.0
        i = j + 1
    return [float(r / (n - 1)) for r in ranks]


def _composite(h: HeuristicScores, cfg: Cfg) -> float:
    weights = cfg.section("analyze.weights")
    parts = {"sharpness": h.sharpness, "motion": h.motion,
             "exposure": h.exposure, "tilt": h.tilt}
    total_w = sum(float(w) for w in weights.values())
    if total_w <= 0:
        return 0.0
    return float(sum(float(weights[k]) * parts[k] for k in weights) / total_w)


def analyze_clips(clips: list[ClipInfo], cfg: Cfg, workdir: Path) -> list[ScoredSegment]:
    """Detect segments in all clips and score them heuristically."""
    scored: list[ScoredSegment] = []
    undecodable: list[bool] = []
    for i, clip in enumerate(clips, start=1):
        logger.info("analyzing clip %d/%d: %s", i, len(clips), clip.id)
        scenes = _detect_scenes(clip.analysis_path, clip.duration, cfg)
        segments = _window_scenes(clip.id, scenes, cfg)
        logger.info("  %d scene(s) -> %d segment(s)", len(scenes), len(segments))
        for seg in segments:
            h = score_window(clip.analysis_path, seg.start, seg.end, cfg)
            # decoded frames always yield tilt > 0 or exposure > 0; all-zero
            # metrics mean the window produced no frames at all.
            undecodable.append(h.exposure == 0.0 and h.tilt == 0.0
                               and h.sharpness == 0.0 and h.motion_raw == 0.0)
            scored.append(ScoredSegment(segment=seg, heuristic=h,
                                        judge=None, taste=None, final=0.0))

    if scored:
        for field, values in (
            ("sharpness", _rank_normalize([s.heuristic.sharpness for s in scored])),
            ("motion", _rank_normalize([s.heuristic.motion for s in scored])),
        ):
            for s, v in zip(scored, values):
                setattr(s.heuristic, field, v)
        for s, dead in zip(scored, undecodable):
            s.heuristic.score = 0.0 if dead else _composite(s.heuristic, cfg)
            s.final = s.heuristic.score

    out = save_json(scored, Path(workdir) / "segments.json")
    logger.info("scored %d segments -> %s", len(scored), out)
    return scored
