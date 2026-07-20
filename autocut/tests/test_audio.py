"""Tests for autocut.audio.analyze on a synthetic 120 BPM click track."""

from __future__ import annotations

import numpy as np
import soundfile as sf

from autocut.audio import analyze
from autocut.config import load_style
from autocut.models import load_music

SR = 22050
DURATION_S = 30.0
BPM = 120.0


def _click_track() -> np.ndarray:
    """Decaying sine bursts (kick-like) every beat, louder in the second half."""
    n = int(SR * DURATION_S)
    y = np.zeros(n, dtype=np.float64)
    beat_period = 60.0 / BPM
    burst_n = int(0.06 * SR)
    bt = np.arange(burst_n) / SR
    burst = np.sin(2 * np.pi * 150.0 * bt) * np.exp(-bt / 0.015)
    for start in np.arange(0.0, DURATION_S, beat_period):
        i = int(round(start * SR))
        # Keep the halves close enough that beat_track's trim keeps the quiet half.
        amp = 0.9 if start >= DURATION_S / 2 else 0.5
        j = min(i + burst_n, n)
        y[i:j] += amp * burst[: j - i]
    return y.astype(np.float32)


def test_analyze_click_track(tmp_path):
    wav = tmp_path / "click.wav"
    sf.write(str(wav), _click_track(), SR)
    cfg = load_style(None)
    out_json = tmp_path / "music.json"

    ma = analyze(wav, cfg, out_json=out_json)

    assert abs(ma.duration - DURATION_S) < 0.1

    # 120 BPM with half/double-time tolerance.
    assert (55 < ma.tempo < 65) or (115 < ma.tempo < 125) or (235 < ma.tempo < 245)

    assert len(ma.beats) >= 40
    gaps = np.diff(ma.beats)
    assert abs(float(np.median(gaps)) - 0.5) <= 0.06

    assert len(ma.energy) == len(ma.energy_t)
    assert all(0.0 <= e <= 1.0 for e in ma.energy)

    beats = np.asarray(ma.beats)
    assert ma.impact_points, "expected at least one impact point"
    for p in ma.impact_points:
        assert float(np.min(np.abs(beats - p))) < 1e-6

    min_gap = float(cfg["audio.impact.min_gap_s"])
    pts = ma.impact_points
    assert pts == sorted(pts)
    assert all(b - a >= min_gap - 1e-6 for a, b in zip(pts, pts[1:]))
    assert len(pts) <= int(cfg["audio.impact.max_points"])

    # Round-trips through JSON (plain Python floats only).
    ma2 = load_music(out_json)
    assert ma2.tempo == ma.tempo
    assert ma2.beats == ma.beats
    assert ma2.impact_points == ma.impact_points
