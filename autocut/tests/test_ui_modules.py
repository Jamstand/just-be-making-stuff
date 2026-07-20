"""Unit tests for the module APIs added for the web UI (no streamlit here)."""

from __future__ import annotations

import json
from pathlib import Path

import cv2
import numpy as np
import yaml

from autocut import config, judge, taste
from autocut.models import ClipInfo, Frame, HeuristicScores, ScoredSegment, Segment


def _write_jpg(path: Path) -> str:
    path.parent.mkdir(parents=True, exist_ok=True)
    cv2.imwrite(str(path), np.zeros((8, 8, 3), np.uint8))
    return str(path)


def _fake_clip(cid: str, frame_paths: list[tuple[float, str]], duration: float = 8.0) -> ClipInfo:
    return ClipInfo(
        id=cid, path=f"/nonexistent/{cid}.mp4", duration=duration, fps=30.0,
        width=3840, height=2160, vcodec="h264", pix_fmt="yuv420p",
        has_audio=False, size_bytes=1,
        frames=[Frame(t=t, path=p) for t, p in frame_paths],
    )


def _fake_segment(sid: str, cid: str, start: float, end: float, final: float) -> ScoredSegment:
    return ScoredSegment(
        segment=Segment(id=sid, clip_id=cid, start=start, end=end),
        heuristic=HeuristicScores(sharpness=0.5, motion=0.5, exposure=0.9,
                                  tilt=1.0, tilt_deg=0.0, motion_raw=1.0, score=final),
        judge=None,
        final=final,
    )


# ---------------------------------------------------------------------------
def test_save_style_overrides_roundtrip(tmp_path):
    target = tmp_path / "styles" / "custom.yaml"
    config.save_style_overrides(target, {
        "judge.model": "claude-opus-4-8",
        "assemble.cut.min_shot_s": 0.7,
        "assemble.render.lut": None,
    })
    raw = yaml.safe_load(target.read_text(encoding="utf-8"))
    assert raw["judge"]["model"] == "claude-opus-4-8"
    assert raw["assemble"]["cut"]["min_shot_s"] == 0.7
    assert raw["assemble"]["render"]["lut"] is None

    cfg = config.load_style(target)
    assert cfg["judge.model"] == "claude-opus-4-8"
    assert cfg["assemble.cut.min_shot_s"] == 0.7
    # untouched defaults survive the merge
    assert cfg["assemble.cut.max_shot_s"] == 4.0
    assert cfg["output.width"] == 1080

    # a second save updates in place without clobbering earlier siblings
    config.save_style_overrides(target, {"assemble.cut.max_shot_s": 3.0})
    cfg2 = config.load_style(target)
    assert cfg2["assemble.cut.min_shot_s"] == 0.7
    assert cfg2["assemble.cut.max_shot_s"] == 3.0


def test_list_style_presets(tmp_path):
    (tmp_path / "style.yaml").write_text("output: {}\n", encoding="utf-8")
    styles = tmp_path / "styles"
    styles.mkdir()
    (styles / "b.yaml").write_text("{}\n", encoding="utf-8")
    (styles / "a.yaml").write_text("{}\n", encoding="utf-8")
    (styles / "notes.txt").write_text("not yaml", encoding="utf-8")

    presets = config.list_style_presets(tmp_path)
    assert [p.name for p in presets] == ["style.yaml", "a.yaml", "b.yaml"]
    assert config.list_style_presets(tmp_path / "empty") == []


# ---------------------------------------------------------------------------
def test_judge_cache_stats(tmp_path):
    cfg = config.load_style(None)
    cache = tmp_path / str(cfg["judge.cache_dir"])
    cache.mkdir(parents=True)
    for i in range(3):
        (cache / f"{'ab' * 8}{i}.json").write_text("{}", encoding="utf-8")

    rows = [
        {"model": "claude-sonnet-4-6", "segments": 4, "input_tokens": 10_000,
         "output_tokens": 1_000, "cache_creation_input_tokens": 2_000,
         "cache_read_input_tokens": 8_000},
        {"model": "claude-sonnet-4-6", "segments": 2, "input_tokens": 5_000,
         "output_tokens": 500, "cache_creation_input_tokens": 0,
         "cache_read_input_tokens": 10_000},
        {"model": "weird-model", "segments": 1, "input_tokens": 100,
         "output_tokens": 10, "cache_creation_input_tokens": 0,
         "cache_read_input_tokens": 0},
    ]
    with open(cache / "usage.jsonl", "w", encoding="utf-8") as fh:
        for row in rows:
            fh.write(json.dumps(row) + "\n")

    stats = judge.cache_stats(cfg, tmp_path)
    assert stats["cached_segments"] == 3
    assert stats["api_calls"] == 3
    assert stats["segments_scored"] == 7
    assert stats["input_tokens"] == 15_100
    assert stats["output_tokens"] == 1_510
    assert stats["cache_read_input_tokens"] == 18_000
    assert stats["cache_creation_input_tokens"] == 2_000
    assert stats["unknown_models"] == ["weird-model"]

    expected = 0.0
    for row in rows[:2]:
        expected += (
            row["input_tokens"] * 3.0
            + row["cache_read_input_tokens"] * 3.0 * 0.1
            + row["cache_creation_input_tokens"] * 3.0 * 1.25
            + row["output_tokens"] * 15.0
        ) / 1_000_000.0
    assert stats["est_cost_usd"] == round(expected, 4)

    # empty workdir -> zeroed stats, no crash
    empty = judge.cache_stats(cfg, tmp_path / "nope")
    assert empty["cached_segments"] == 0 and empty["est_cost_usd"] == 0.0


# ---------------------------------------------------------------------------
def test_taste_segment_feedback(tmp_path):
    cfg = config.load_style(None)
    workdir = tmp_path / "_autocut"
    workdir.mkdir()

    f1 = _write_jpg(workdir / "frames" / "c001" / "f_1.jpg")
    f2 = _write_jpg(workdir / "frames" / "c001" / "f_2.jpg")
    f3 = _write_jpg(workdir / "frames" / "c002" / "f_1.jpg")
    clips = [
        _fake_clip("c001", [(1.0, f1), (3.0, f2)]),
        _fake_clip("c002", [(2.0, f3)]),
    ]
    segments = [
        _fake_segment("c001_s00", "c001", 0.5, 3.5, 0.8),
        _fake_segment("c001_s01", "c001", 4.0, 7.0, 0.6),
        _fake_segment("c002_s00", "c002", 1.0, 4.0, 0.4),
    ]

    store = taste.TasteStore(cfg, workdir)
    assert store.example_count() == 0

    total = store.log_segment_feedback(
        {"c001_s00": True, "c002_s00": False}, segments, clips
    )
    assert total == 2
    assert store.example_count() == 2
    assert store.decisions() == {"c001_s00": True, "c002_s00": False}

    rows = [json.loads(l) for l in
            (workdir / str(cfg["taste.dir"]) / "feedback.jsonl").read_text().splitlines()]
    assert all(row["frame_paths"] for row in rows)

    # flipping a decision keeps the distinct count but changes the latest value
    store.log_segment_feedback({"c002_s00": True}, segments, clips)
    assert store.example_count() == 2
    assert store.decisions()["c002_s00"] is True

    # unknown segment ids are ignored, not crashed on
    assert store.log_segment_feedback({"nope": True}, segments, clips) == 2


def test_frames_for_segment(tmp_path):
    f1 = _write_jpg(tmp_path / "f1.jpg")
    f2 = _write_jpg(tmp_path / "f2.jpg")
    clips = [_fake_clip("c001", [(1.0, f1), (5.0, f2)])]

    seg_in = Segment(id="s", clip_id="c001", start=0.5, end=1.5)
    assert taste.frames_for_segment(clips, seg_in) == [f1]

    # no frame inside the window -> nearest frame fallback
    seg_out = Segment(id="s2", clip_id="c001", start=2.0, end=3.0)
    assert taste.frames_for_segment(clips, seg_out) == [f1]

    seg_unknown = Segment(id="s3", clip_id="cXXX", start=0.0, end=1.0)
    assert taste.frames_for_segment(clips, seg_unknown) == []
