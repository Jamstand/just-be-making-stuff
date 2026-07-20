"""Shared data models for the AUTOCUT pipeline.

These dataclasses are the contract between modules:

    ingest.scan()        -> list[ClipInfo]
    audio.analyze()      -> MusicAnalysis
    analyze.analyze_clips() -> list[ScoredSegment]   (heuristic scores only)
    judge.Judge.judge()  -> list[ScoredSegment]      (judge scores + final blend)
    assemble.build_edl() -> EDL
    review.review_loop() -> revised EDLs + renders

Everything serializes to plain JSON via to_dict()/from_dict() so each stage
can be cached on disk in the workdir and inspected by hand.
"""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1

# Known shot types (judge classifies each segment as one of these; heuristic
# fallback uses motion magnitude). Sequencing rules in style.yaml refer to
# these names.
SHOT_TYPES = ("wide", "rolling", "detail", "motion", "interior", "hero", "static", "other")


# ---------------------------------------------------------------------------
@dataclass
class Frame:
    """A sampled still from a clip. t is seconds from clip start."""
    t: float
    path: str


@dataclass
class ClipInfo:
    """One source clip discovered by ingest."""
    id: str                 # stable id, e.g. "c001_DSC0001"
    path: str               # absolute path to the original file
    duration: float         # seconds
    fps: float
    width: int
    height: int
    vcodec: str             # e.g. "h264", "hevc"
    pix_fmt: str            # e.g. "yuv420p", "yuv422p10le"
    has_audio: bool
    size_bytes: int
    proxy_path: str | None = None   # transcoded proxy, if one was generated
    frames: list[Frame] = field(default_factory=list)

    @property
    def analysis_path(self) -> str:
        """Path analysis/rendering readers should open (proxy when present)."""
        return self.proxy_path or self.path

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "ClipInfo":
        d = dict(d)
        d["frames"] = [Frame(**f) for f in d.get("frames", [])]
        return cls(**d)


# ---------------------------------------------------------------------------
@dataclass
class MusicAnalysis:
    """Beat grid + energy curve for the music track (audio.analyze output)."""
    path: str
    duration: float
    tempo: float                      # BPM
    beats: list[float]                # beat timestamps, seconds
    downbeats: list[float]            # estimated bar starts, seconds
    energy_t: list[float]             # timestamps for the energy curve
    energy: list[float]               # normalized 0..1 energy values
    impact_points: list[float]        # suggested drop/transition timestamps

    def energy_at(self, t: float) -> float:
        """Linear-interpolated energy at time t (clamped to the curve)."""
        if not self.energy:
            return 0.5
        if t <= self.energy_t[0]:
            return self.energy[0]
        if t >= self.energy_t[-1]:
            return self.energy[-1]
        # binary search
        lo, hi = 0, len(self.energy_t) - 1
        while hi - lo > 1:
            mid = (lo + hi) // 2
            if self.energy_t[mid] <= t:
                lo = mid
            else:
                hi = mid
        t0, t1 = self.energy_t[lo], self.energy_t[hi]
        if t1 <= t0:
            return self.energy[lo]
        w = (t - t0) / (t1 - t0)
        return self.energy[lo] * (1 - w) + self.energy[hi] * w

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "MusicAnalysis":
        return cls(**d)


# ---------------------------------------------------------------------------
@dataclass
class Segment:
    """A candidate slice of a source clip. start/end are clip-relative seconds."""
    id: str                 # e.g. "c001_s03"
    clip_id: str
    start: float
    end: float

    @property
    def duration(self) -> float:
        return self.end - self.start


@dataclass
class HeuristicScores:
    """OpenCV metrics for a segment, each normalized 0..1 (1 = good)."""
    sharpness: float
    motion: float           # motion magnitude, rank-normalized across the shoot
    exposure: float         # 1 = well exposed, 0 = heavily clipped
    tilt: float             # 1 = level horizon, 0 = tilt >= analyze.tilt_max_deg
    tilt_deg: float         # raw estimated tilt in degrees (signed)
    motion_raw: float       # raw mean optical-flow magnitude (px/frame, at flow_width)
    score: float            # weighted composite 0..1


@dataclass
class JudgeScores:
    """AI judge scores for a segment, each normalized 0..1 (1 = good)."""
    composition: float
    energy: float
    hero: float             # hero-shot potential
    clutter: float          # 1 = clean background, 0 = cluttered
    shot_type: str          # one of SHOT_TYPES
    subject_x: float        # horizontal subject center, 0=left .. 1=right
    rationale: str          # one-line reason
    model: str              # model id that produced the scores
    score: float            # composite 0..1


@dataclass
class ScoredSegment:
    """A segment with all available scores. `final` is the blended ranking score."""
    segment: Segment
    heuristic: HeuristicScores
    judge: JudgeScores | None = None
    taste: float | None = None      # taste-model score 0..1, when trained
    final: float = 0.0

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "ScoredSegment":
        return cls(
            segment=Segment(**d["segment"]),
            heuristic=HeuristicScores(**d["heuristic"]),
            judge=JudgeScores(**d["judge"]) if d.get("judge") else None,
            taste=d.get("taste"),
            final=d.get("final", 0.0),
        )


# ---------------------------------------------------------------------------
@dataclass
class EDLEvent:
    """One cut in the timeline. src_* are clip-relative, rec_* timeline-relative."""
    idx: int
    segment_id: str
    clip_id: str
    clip_path: str          # original source path (for NLE export)
    src_in: float
    src_out: float
    rec_in: float
    rec_out: float
    shot_type: str
    is_hero: bool
    crop_x: float           # 0..1 horizontal crop center used for 9:16 reframe
    score: float
    rationale: str = ""


@dataclass
class EDL:
    """Edit decision list - the reviewable output of assemble.build_edl()."""
    version: int
    music_path: str
    style_source: str | None
    target_duration: float
    output: dict[str, Any]          # width/height/fps used
    events: list[EDLEvent]
    created_at: str = ""            # ISO timestamp, stamped by the caller

    @property
    def duration(self) -> float:
        return self.events[-1].rec_out if self.events else 0.0

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "EDL":
        d = dict(d)
        d["events"] = [EDLEvent(**e) for e in d.get("events", [])]
        return cls(**d)


# ---------------------------------------------------------------------------
# JSON helpers - every pipeline stage persists through these.

def save_json(obj: Any, path: str | Path) -> Path:
    """Serialize a dataclass (or list of them) with to_dict()/asdict to JSON."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(obj, list):
        payload: Any = [o.to_dict() if hasattr(o, "to_dict") else asdict(o) for o in obj]
    elif hasattr(obj, "to_dict"):
        payload = obj.to_dict()
    else:
        payload = obj
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2)
    return path


def load_json(path: str | Path) -> Any:
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def load_clips(path: str | Path) -> list[ClipInfo]:
    return [ClipInfo.from_dict(d) for d in load_json(path)]


def load_segments(path: str | Path) -> list[ScoredSegment]:
    return [ScoredSegment.from_dict(d) for d in load_json(path)]


def load_music(path: str | Path) -> MusicAnalysis:
    return MusicAnalysis.from_dict(load_json(path))


def load_edl(path: str | Path) -> EDL:
    return EDL.from_dict(load_json(path))
