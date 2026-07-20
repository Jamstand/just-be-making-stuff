"""Preference memory - learns my taste from keep/reject feedback (v1 stub).

The interfaces are wired now; the ranker becomes real once 30+ examples exist.

Contract
--------
class TasteStore(cfg, workdir)
    * Storage under workdir/<taste.dir>/:
        feedback.jsonl   - one line per decision:
                           {segment_id, clip_id, start, end, frame_paths,
                            kept: bool, ts}
        embeddings.npz   - CLIP embeddings keyed by segment_id (when computed)
        model.json       - trained ranker weights (logistic regression over
                           CLIP embedding, plain numpy - no sklearn dep)
    log_feedback(edl, decisions, segments) -> int
        * decisions: {event_idx: bool} from `vanscut feedback`; resolve each
          event to its segment + representative frame paths and append to
          feedback.jsonl. Returns total examples on disk.
    embed_pending() -> int
        * Compute CLIP embeddings (open_clip, cfg["taste.clip_model"]) for
          feedback rows that don't have one yet. torch/open_clip are OPTIONAL
          deps: import lazily and raise a helpful "pip install autocut[taste]"
          RuntimeError when missing.
    train() -> dict
        * Requires >= cfg["taste.min_examples"] examples; fits a lightweight
          logistic-regression ranker on kept vs rejected embeddings (numpy
          gradient descent is fine); saves model.json; returns metrics.
    ready -> bool         - model.json exists
    predict(segments, clips) -> dict[str, float] | None
        * When trained: embed each segment's representative frame, return
          {segment_id: probability_kept}; else None.
    Blending (done by the caller/cli): when ready,
        final = (1 - taste.weight) * final + taste.weight * taste_score
"""

from __future__ import annotations

from pathlib import Path

from .config import Cfg
from .models import EDL, ClipInfo, ScoredSegment


class TasteStore:
    def __init__(self, cfg: Cfg, workdir: Path):
        raise NotImplementedError

    def log_feedback(
        self, edl: EDL, decisions: dict[int, bool], segments: list[ScoredSegment]
    ) -> int:
        """Append keep/reject decisions to the feedback log. Returns total count."""
        raise NotImplementedError

    def embed_pending(self) -> int:
        """Compute CLIP embeddings for feedback rows that lack them."""
        raise NotImplementedError

    def train(self) -> dict:
        """Fit the ranker once enough examples exist."""
        raise NotImplementedError

    @property
    def ready(self) -> bool:
        raise NotImplementedError

    def predict(
        self, segments: list[ScoredSegment], clips: list[ClipInfo]
    ) -> dict[str, float] | None:
        """Score segments with the trained ranker (segment_id -> 0..1)."""
        raise NotImplementedError
