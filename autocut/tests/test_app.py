"""Headless smoke tests for the Streamlit app (streamlit.testing AppTest)."""

from __future__ import annotations

from pathlib import Path

import cv2
import numpy as np
from streamlit.testing.v1 import AppTest

from autocut.models import (
    ClipInfo,
    Frame,
    HeuristicScores,
    JudgeScores,
    ScoredSegment,
    Segment,
    save_json,
)

APP = str(Path(__file__).resolve().parent.parent / "app.py")


def _write_jpg(path: Path) -> str:
    path.parent.mkdir(parents=True, exist_ok=True)
    cv2.imwrite(str(path), np.full((8, 8, 3), 128, np.uint8))
    return str(path)


def _fixture_project(tmp_path: Path) -> Path:
    """A fake analyzed project: clips.json + segments.json + frame files."""
    clips_dir = tmp_path / "clips"
    workdir = clips_dir / "_autocut"
    workdir.mkdir(parents=True)

    clips, segments = [], []
    for c in (1, 2):
        cid = f"c{c:03d}_test"
        frames = [
            Frame(t=t, path=_write_jpg(workdir / "frames" / cid / f"f_{int(t * 1000):08d}.jpg"))
            for t in (1.0, 3.0, 5.0)
        ]
        clips.append(ClipInfo(
            id=cid, path=str(clips_dir / f"DSC{c:04d}.MP4"), duration=8.0, fps=59.94,
            width=3840, height=2160, vcodec="h264", pix_fmt="yuv420p",
            has_audio=False, size_bytes=1, frames=frames,
        ))
        for s in (0, 1):
            seg = Segment(id=f"{cid}_s{s:02d}", clip_id=cid, start=s * 4.0, end=s * 4.0 + 3.5)
            judge = None
            if c == 1 and s == 0:
                judge = JudgeScores(
                    composition=0.8, energy=0.7, hero=0.9, clutter=0.8,
                    shot_type="rolling", subject_x=0.4,
                    rationale="clean rolling shot", model="claude-sonnet-4-6", score=0.8,
                )
            segments.append(ScoredSegment(
                segment=seg,
                heuristic=HeuristicScores(sharpness=0.6, motion=0.5, exposure=0.9,
                                          tilt=1.0, tilt_deg=0.0, motion_raw=1.2, score=0.62),
                judge=judge,
                final=0.7 if judge else 0.62,
            ))

    save_json(clips, workdir / "clips.json")
    save_json(segments, workdir / "segments.json")
    return clips_dir


def test_pages_render_empty():
    at = AppTest.from_file(APP, default_timeout=60)
    at.session_state["project_folder"] = ""
    at.run()
    assert not at.exception

    for page in ("Review", "Settings"):
        at.radio(key="page").set_value(page)
        at.run()
        assert not at.exception, f"{page} page raised with empty state"


def test_review_and_settings_with_fixture(tmp_path):
    clips_dir = _fixture_project(tmp_path)

    at = AppTest.from_file(APP, default_timeout=60)
    at.session_state["project_folder"] = str(clips_dir)
    at.run()
    assert not at.exception

    at.radio(key="page").set_value("Review")
    at.run()
    assert not at.exception
    # page radio + one decision radio per segment
    assert len(at.radio) >= 5
    assert len(at.metric) >= 1

    at.radio(key="page").set_value("Settings")
    at.run()
    assert not at.exception
    # cost tracker renders its metric row for a valid project folder
    assert len(at.metric) >= 4
