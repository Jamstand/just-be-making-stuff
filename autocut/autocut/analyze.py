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

from pathlib import Path

from .config import Cfg
from .models import ClipInfo, HeuristicScores, ScoredSegment


def analyze_clips(clips: list[ClipInfo], cfg: Cfg, workdir: Path) -> list[ScoredSegment]:
    """Detect segments in all clips and score them heuristically."""
    raise NotImplementedError


def score_window(video: str | Path, start: float, end: float, cfg: Cfg) -> HeuristicScores:
    """Compute raw sharpness/motion/exposure/tilt metrics for one window."""
    raise NotImplementedError
