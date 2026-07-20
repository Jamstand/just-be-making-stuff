"""Beat detection and energy analysis for the music track (librosa).

Contract
--------
analyze(song, cfg, out_json=None) -> MusicAnalysis
    * Load audio at cfg["audio.sample_rate"], mono.
    * Beat tracking: librosa.beat.beat_track with start_bpm/tightness from cfg;
      convert beat frames to seconds with the configured hop_length.
    * Downbeats: estimate bar starts (every 4th beat aligned to the strongest
      beat phase is acceptable for v1).
    * Energy curve: RMS energy, smoothed over cfg["audio.energy_smooth_s"],
      normalized to 0..1, sampled on the hop grid (energy_t timestamps).
    * Impact points: local peaks of onset strength above the
      cfg["audio.impact.percentile"] percentile, at least
      cfg["audio.impact.min_gap_s"] apart, capped at max_points, snapped to
      the nearest beat.
    * If out_json is given, persist via models.save_json().
"""

from __future__ import annotations

from pathlib import Path

from .config import Cfg
from .models import MusicAnalysis


def analyze(song: str | Path, cfg: Cfg, out_json: str | Path | None = None) -> MusicAnalysis:
    """Analyze the music track: beats, downbeats, energy curve, impact points."""
    raise NotImplementedError
