"""Metadata-only tests for autocut.assemble.build_edl - no video files opened."""

from __future__ import annotations

import xml.etree.ElementTree as ET
from pathlib import Path

import pytest

from autocut.assemble import _beats_per_shot, build_edl, export_fcpxml
from autocut.config import load_style
from autocut.models import (
    ClipInfo,
    HeuristicScores,
    JudgeScores,
    MusicAnalysis,
    ScoredSegment,
    Segment,
    load_edl,
)

ROOT = Path(__file__).resolve().parents[1]

_JUDGE_TYPES = ["wide", "rolling", "detail", "interior"]


def _music() -> MusicAnalysis:
    beats = [i * 0.5 for i in range(121)]  # 120 BPM grid over 60 s
    return MusicAnalysis(
        path="music.wav",
        duration=60.0,
        tempo=120.0,
        beats=beats,
        downbeats=[i * 2.0 for i in range(31)],
        energy_t=list(beats),
        energy=[min(1.0, t / 60.0) for t in beats],  # linear ramp 0 -> 1
        impact_points=[16.0, 32.0],
    )


def _clips() -> list[ClipInfo]:
    return [
        ClipInfo(
            id=f"c{i:03d}",
            path=f"/fake/clip{i:03d}.mp4",
            duration=30.0,
            fps=30.0,
            width=3840,
            height=2160,
            vcodec="h264",
            pix_fmt="yuv420p",
            has_audio=False,
            size_bytes=1_000_000,
        )
        for i in range(1, 7)
    ]


def _segments(clips: list[ClipInfo]) -> list[ScoredSegment]:
    """~40 deterministic fake segments, durations 2..6 s, a few judged heroes."""
    segs: list[ScoredSegment] = []
    n = 0
    for ci, clip in enumerate(clips):
        for s in range(7):
            n += 1
            dur = 2.0 + ((ci + s) % 5)
            start = min(s * 4.0, clip.duration - dur)
            seg = Segment(id=f"{clip.id}_s{s:02d}", clip_id=clip.id, start=start, end=start + dur)
            motion = ((n * 13) % 100) / 100.0
            heur = HeuristicScores(
                sharpness=0.6,
                motion=motion,
                exposure=0.8,
                tilt=0.9,
                tilt_deg=1.5,
                motion_raw=motion * 4.0,
                score=0.6,
            )
            judge = None
            if n % 5 == 0:
                judge = JudgeScores(
                    composition=0.7,
                    energy=0.6,
                    hero=0.6 + ((n * 11) % 40) / 100.0,
                    clutter=0.8,
                    shot_type=_JUDGE_TYPES[n % len(_JUDGE_TYPES)],
                    subject_x=0.3 + ((n * 17) % 40) / 100.0,
                    rationale="synthetic",
                    model="test",
                    score=0.7,
                )
            final = 0.30 + ((n * 23) % 60) / 100.0
            segs.append(ScoredSegment(segment=seg, heuristic=heur, judge=judge, final=final))
    return segs


@pytest.fixture(scope="module")
def cfg():
    return load_style(ROOT / "style.yaml")


@pytest.fixture(scope="module")
def built(cfg, tmp_path_factory):
    clips = _clips()
    segments = _segments(clips)
    music = _music()
    workdir = tmp_path_factory.mktemp("workdir")
    edl = build_edl(segments, clips, music, cfg, workdir)
    return edl, segments, clips, music, workdir


def _target(cfg, music: MusicAnalysis) -> float:
    t = min(
        max(float(cfg["assemble.target_duration_s"]), float(cfg["output.min_duration_s"])),
        float(cfg["output.max_duration_s"]),
    )
    return min(t, music.duration - 0.5)


def test_events_contiguous_from_zero(built):
    edl = built[0]
    assert edl.events
    assert edl.events[0].rec_in == pytest.approx(0.0, abs=1e-6)
    for prev, cur in zip(edl.events, edl.events[1:]):
        assert cur.rec_in == pytest.approx(prev.rec_out, abs=1e-6)


def test_internal_boundaries_on_beats(built):
    edl, _, _, music, _ = built
    for ev in edl.events[:-1]:
        assert min(abs(b - ev.rec_out) for b in music.beats) <= 1e-6


def test_shot_lengths_within_bounds(built, cfg):
    edl = built[0]
    lo = float(cfg["assemble.cut.min_shot_s"])
    hi = float(cfg["assemble.cut.max_shot_s"])
    for ev in edl.events[:-1]:
        shot = ev.rec_out - ev.rec_in
        assert lo - 1e-6 <= shot <= hi + 1e-6
    last = edl.events[-1]
    assert last.rec_out - last.rec_in <= hi + 1e-6  # may be trimmed short of min


def test_no_clip_repeat_within_window(built, cfg):
    edl = built[0]
    window = int(cfg["assemble.sequencing.avoid_repeat_clip"])
    for i, ev in enumerate(edl.events):
        for j in range(i + 1, min(i + window + 1, len(edl.events))):
            assert edl.events[j].clip_id != ev.clip_id, f"clip repeat at events {i}->{j}"


def test_src_window_inside_segment(built):
    edl, segments, *_ = built
    by_id = {s.segment.id: s.segment for s in segments}
    for ev in edl.events:
        seg = by_id[ev.segment_id]
        assert seg.start - 1e-6 <= ev.src_in
        assert ev.src_out <= seg.end + 1e-6
        assert ev.src_out - ev.src_in == pytest.approx(ev.rec_out - ev.rec_in, abs=1e-6)


def test_segments_used_at_most_once(built):
    ids = [ev.segment_id for ev in built[0].events]
    assert len(ids) == len(set(ids))


def test_duration_at_most_target(built, cfg):
    edl, _, _, music, _ = built
    target = _target(cfg, music)
    assert edl.duration <= target + 1e-6
    assert edl.target_duration == pytest.approx(target)


def test_crop_x_in_range(built):
    for ev in built[0].events:
        assert 0.0 <= ev.crop_x <= 1.0


def test_hero_placement(built, cfg):
    edl = built[0]
    if bool(cfg["assemble.sequencing.hero_on_impact"]):
        assert any(ev.is_hero for ev in edl.events)
    if str(cfg["assemble.sequencing.ending"]) == "hero":
        assert edl.events[-1].is_hero


def test_edl_persisted_and_roundtrips(built):
    edl, *_, workdir = built
    path = workdir / "edl.json"
    assert path.is_file()
    edl2 = load_edl(path)
    assert len(edl2.events) == len(edl.events)
    assert edl2.duration == pytest.approx(edl.duration)
    assert edl2.version == edl.version
    assert edl2.created_at == edl.created_at


def test_beats_per_shot_monotonic(cfg):
    values = [_beats_per_shot(e / 100.0, cfg) for e in range(101)]
    # Higher energy never yields MORE beats per shot (faster cutting at drops).
    assert all(a >= b for a, b in zip(values, values[1:]))
    assert values[0] == int(cfg["assemble.cut.slow_beats"])
    assert values[-1] == int(cfg["assemble.cut.fast_beats"])


def test_export_fcpxml_structure(built, cfg, tmp_path):
    edl, _, clips, _, _ = built
    out = export_fcpxml(edl, clips, cfg, tmp_path / "timeline.fcpxml")
    root = ET.parse(out).getroot()
    assert root.tag == "fcpxml"
    assert root.get("version") == "1.9"
    fmt = root.find("resources/format")
    assert fmt is not None
    assert fmt.get("width") == str(int(cfg["output.width"]))
    assert fmt.get("height") == str(int(cfg["output.height"]))
    spine = root.find(".//spine")
    assert spine is not None
    assert len(list(spine)) == len(edl.events)
    used_clip_ids = {ev.clip_id for ev in edl.events}
    assert len(root.findall("resources/asset")) == len(used_clip_ids)
