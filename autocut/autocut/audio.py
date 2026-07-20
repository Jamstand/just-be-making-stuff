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

import logging
from pathlib import Path

import librosa
import numpy as np

from .config import Cfg
from .models import MusicAnalysis, save_json

logger = logging.getLogger("autocut.audio")

# Cap on stored energy-curve samples so music.json stays small.
# (No corresponding key exists in style.yaml.)
_MAX_ENERGY_POINTS = 2000


def analyze(song: str | Path, cfg: Cfg, out_json: str | Path | None = None) -> MusicAnalysis:
    """Analyze the music track: beats, downbeats, energy curve, impact points."""
    song = Path(song)
    sr_cfg = int(cfg["audio.sample_rate"])
    hop = int(cfg["audio.hop_length"])

    logger.info("Loading %s at %d Hz", song.name, sr_cfg)
    y, sr = librosa.load(str(song), sr=sr_cfg, mono=True)
    duration = float(len(y) / sr)

    tempo_raw, beat_frames = librosa.beat.beat_track(
        y=y,
        sr=sr,
        hop_length=hop,
        start_bpm=float(cfg["audio.start_bpm"]),
        tightness=float(cfg["audio.tightness"]),
    )
    tempo = float(np.atleast_1d(tempo_raw)[0])
    beats_arr = librosa.frames_to_time(beat_frames, sr=sr, hop_length=hop)

    onset_env = librosa.onset.onset_strength(y=y, sr=sr, hop_length=hop)

    downbeats_arr = _downbeats(beats_arr, beat_frames, onset_env)
    energy_t, energy = _energy_curve(y, sr, hop, cfg)
    impacts = _impact_points(onset_env, beats_arr, sr, hop, cfg)

    logger.info(
        "%.1fs analyzed: tempo %.1f BPM, %d beats, %d downbeats, %d impact points",
        duration,
        tempo,
        len(beats_arr),
        len(downbeats_arr),
        len(impacts),
    )

    result = MusicAnalysis(
        path=str(song),
        duration=duration,
        tempo=tempo,
        beats=[float(b) for b in beats_arr],
        downbeats=[float(b) for b in downbeats_arr],
        energy_t=[float(t) for t in energy_t],
        energy=[float(e) for e in energy],
        impact_points=impacts,
    )
    if out_json is not None:
        save_json(result, out_json)
        logger.info("Wrote %s", out_json)
    return result


def _downbeats(
    beats: np.ndarray, beat_frames: np.ndarray, onset_env: np.ndarray
) -> np.ndarray:
    """Bar starts: the 4-beat phase whose beats carry the most onset strength."""
    if len(beats) == 0 or len(onset_env) == 0:
        return beats[:0]
    frames = np.clip(np.asarray(beat_frames), 0, len(onset_env) - 1)
    totals = [float(onset_env[frames[phase::4]].sum()) for phase in range(4)]
    best = int(np.argmax(totals))
    return beats[best::4]


def _energy_curve(
    y: np.ndarray, sr: int, hop: int, cfg: Cfg
) -> tuple[np.ndarray, np.ndarray]:
    rms = librosa.feature.rms(y=y, hop_length=hop)[0]
    win = max(1, round(float(cfg["audio.energy_smooth_s"]) * sr / hop))
    smoothed = np.convolve(rms, np.ones(win) / win, mode="same")
    peak = float(smoothed.max()) if smoothed.size else 0.0
    energy = smoothed / peak if peak > 0.0 else np.zeros_like(smoothed)
    energy_t = librosa.frames_to_time(np.arange(len(rms)), sr=sr, hop_length=hop)
    if len(energy) > _MAX_ENERGY_POINTS:
        stride = int(np.ceil(len(energy) / _MAX_ENERGY_POINTS))
        energy = energy[::stride]
        energy_t = energy_t[::stride]
    return energy_t, energy


def _impact_points(
    onset_env: np.ndarray, beats: np.ndarray, sr: int, hop: int, cfg: Cfg
) -> list[float]:
    if len(onset_env) == 0 or len(beats) == 0:
        return []
    percentile = float(cfg["audio.impact.percentile"])
    min_gap = float(cfg["audio.impact.min_gap_s"])
    max_points = int(cfg["audio.impact.max_points"])

    threshold = float(np.percentile(onset_env, percentile))
    candidates = np.where(onset_env >= threshold)[0]
    if candidates.size == 0:
        return []
    strongest_first = candidates[np.argsort(onset_env[candidates])[::-1]]
    times = librosa.frames_to_time(strongest_first, sr=sr, hop_length=hop)

    # Snap before spacing so min_gap holds on the final (beat-aligned) points.
    chosen: list[float] = []
    used_beats: set[int] = set()
    for t in times:
        j = int(np.argmin(np.abs(beats - t)))
        if j in used_beats:
            continue
        snapped = float(beats[j])
        if any(abs(snapped - c) < min_gap for c in chosen):
            continue
        used_beats.add(j)
        chosen.append(snapped)
        if len(chosen) >= max_points:
            break
    chosen.sort()
    return chosen
