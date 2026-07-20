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

import json
import logging
import time
from pathlib import Path
from typing import Any

import numpy as np

from .config import Cfg
from .models import EDL, ClipInfo, Frame, ScoredSegment, Segment, load_clips

logger = logging.getLogger("autocut.taste")

# Optimizer internals for the numpy logistic ranker - not style knobs.
_TRAIN_STEPS = 500
_TRAIN_LR = 0.1
_TRAIN_L2 = 1e-3
_SIGMOID_CLIP = 60.0  # exp() overflow guard


def _sigmoid(z: np.ndarray | float) -> Any:
    return 1.0 / (1.0 + np.exp(-np.clip(z, -_SIGMOID_CLIP, _SIGMOID_CLIP)))


def _frames_in_window(frames: list[Frame], lo: float, hi: float) -> list[str]:
    """Frame paths with t inside [lo, hi]; fallback: single nearest frame."""
    inside = [f.path for f in frames if lo <= f.t <= hi]
    if inside:
        return inside
    if not frames:
        return []
    mid = (lo + hi) / 2.0
    return [min(frames, key=lambda f: abs(f.t - mid)).path]


def frames_for_segment(clips: list[ClipInfo], segment: Segment) -> list[str]:
    """Sampled-frame paths representing a segment (thumbnails, embeddings)."""
    clip = next((c for c in clips if c.id == segment.clip_id), None)
    if clip is None:
        return []
    return _frames_in_window(clip.frames, float(segment.start), float(segment.end))


class TasteStore:
    def __init__(self, cfg: Cfg, workdir: Path):
        self.cfg = cfg
        self.workdir = Path(workdir)
        self.dir = self.workdir / str(cfg["taste.dir"])
        self.feedback_path = self.dir / "feedback.jsonl"
        self.embeddings_path = self.dir / "embeddings.npz"
        self.model_path = self.dir / "model.json"
        self._backend: tuple[Any, Any, Any] | None = None  # (torch, model, preprocess)

    # -- storage ------------------------------------------------------------
    def _ensure_dir(self) -> None:
        self.dir.mkdir(parents=True, exist_ok=True)

    def _read_feedback(self) -> list[dict[str, Any]]:
        if not self.feedback_path.is_file():
            return []
        rows: list[dict[str, Any]] = []
        with open(self.feedback_path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line:
                    rows.append(json.loads(line))
        return rows

    def _latest_by_segment(self) -> dict[str, dict[str, Any]]:
        """Feedback rows deduped by segment_id - later lines win."""
        latest: dict[str, dict[str, Any]] = {}
        for row in self._read_feedback():
            latest[row["segment_id"]] = row
        return latest

    def _load_embeddings(self) -> dict[str, np.ndarray]:
        if not self.embeddings_path.is_file():
            return {}
        with np.load(self.embeddings_path) as data:
            return {key: np.asarray(data[key]) for key in data.files}

    def _save_embeddings(self, embeddings: dict[str, np.ndarray]) -> None:
        self._ensure_dir()
        np.savez_compressed(self.embeddings_path, **embeddings)

    # -- CLIP backend (optional dependency) ---------------------------------
    def _clip(self) -> tuple[Any, Any, Any]:
        if self._backend is None:
            try:
                import torch
                import open_clip
            except ImportError as exc:
                raise RuntimeError(
                    "taste features need: pip install 'autocut[taste]'"
                ) from exc
            model_name = str(self.cfg["taste.clip_model"])
            pretrained = str(self.cfg["taste.clip_pretrained"])
            logger.info("loading CLIP model %s (%s)", model_name, pretrained)
            model, _, preprocess = open_clip.create_model_and_transforms(
                model_name, pretrained=pretrained
            )
            model.eval()
            self._backend = (torch, model, preprocess)
        return self._backend

    def _embed_paths(self, paths: list[str]) -> np.ndarray | None:
        """Mean-pooled, L2-normalized CLIP embedding of the given images."""
        from PIL import Image

        torch, model, preprocess = self._clip()
        tensors = []
        for p in paths:
            fp = Path(p)
            if not fp.is_file():
                logger.warning("frame missing on disk: %s", fp)
                continue
            with Image.open(fp) as im:
                tensors.append(preprocess(im.convert("RGB")))
        if not tensors:
            return None
        with torch.no_grad():
            feats = model.encode_image(torch.stack(tensors))
        vec = feats.float().mean(dim=0).cpu().numpy().astype(np.float64)
        norm = float(np.linalg.norm(vec))
        if norm > 0.0:
            vec = vec / norm
        return vec.astype(np.float32)

    # -- public API ---------------------------------------------------------
    def log_feedback(
        self, edl: EDL, decisions: dict[int, bool], segments: list[ScoredSegment]
    ) -> int:
        """Append keep/reject decisions to the feedback log. Returns total count."""
        events = {e.idx: e for e in edl.events}
        seg_by_id = {s.segment.id: s.segment for s in segments}
        frames_by_clip = self._load_clip_frames()

        rows: list[dict[str, Any]] = []
        for idx in sorted(decisions):
            event = events.get(idx)
            if event is None:
                logger.warning("feedback for unknown EDL event idx=%d ignored", idx)
                continue
            seg = seg_by_id.get(event.segment_id)
            start = float(seg.start) if seg else float(event.src_in)
            end = float(seg.end) if seg else float(event.src_out)
            frame_paths = _frames_in_window(
                frames_by_clip.get(event.clip_id, []),
                float(event.src_in),
                float(event.src_out),
            )
            if not frame_paths:
                logger.warning("no sampled frames found for %s", event.segment_id)
            rows.append(
                {
                    "segment_id": event.segment_id,
                    "clip_id": event.clip_id,
                    "start": start,
                    "end": end,
                    "frame_paths": frame_paths,
                    "kept": bool(decisions[idx]),
                    "ts": time.time(),
                }
            )

        if rows:
            self._ensure_dir()
            with open(self.feedback_path, "a", encoding="utf-8") as fh:
                for row in rows:
                    fh.write(json.dumps(row) + "\n")
        total = len(self._read_feedback())
        logger.info("logged %d feedback rows (%d total on disk)", len(rows), total)
        return total

    def log_segment_feedback(
        self,
        decisions: dict[str, bool],
        segments: list[ScoredSegment],
        clips: list[ClipInfo],
    ) -> int:
        """Append keep/reject decisions keyed by segment id (no EDL involved).

        Same row schema as log_feedback; used by UIs that review the whole
        scored-segment pool rather than one cut's events. Returns
        example_count() after the append.
        """
        seg_by_id = {s.segment.id: s.segment for s in segments}
        frames_by_clip = {c.id: c.frames for c in clips}

        rows: list[dict[str, Any]] = []
        for sid in sorted(decisions):
            seg = seg_by_id.get(sid)
            if seg is None:
                logger.warning("feedback for unknown segment %s ignored", sid)
                continue
            frame_paths = _frames_in_window(
                frames_by_clip.get(seg.clip_id, []), float(seg.start), float(seg.end)
            )
            if not frame_paths:
                logger.warning("no sampled frames found for %s", sid)
            rows.append(
                {
                    "segment_id": seg.id,
                    "clip_id": seg.clip_id,
                    "start": float(seg.start),
                    "end": float(seg.end),
                    "frame_paths": frame_paths,
                    "kept": bool(decisions[sid]),
                    "ts": time.time(),
                }
            )

        if rows:
            self._ensure_dir()
            with open(self.feedback_path, "a", encoding="utf-8") as fh:
                for row in rows:
                    fh.write(json.dumps(row) + "\n")
        total = self.example_count()
        logger.info("logged %d segment decision(s) (%d distinct examples)", len(rows), total)
        return total

    def example_count(self) -> int:
        """Distinct segments with a logged decision (what train() can use)."""
        return len(self._latest_by_segment())

    def decisions(self) -> dict[str, bool]:
        """Latest keep/reject decision per segment_id."""
        return {sid: bool(row.get("kept", False))
                for sid, row in self._latest_by_segment().items()}

    def _load_clip_frames(self) -> dict[str, list[Frame]]:
        # log_feedback's signature carries no ClipInfo, so frame paths come
        # from the ingest cache in the workdir.
        clips_json = self.workdir / "clips.json"
        if not clips_json.is_file():
            logger.warning(
                "%s not found; feedback rows will have no frame paths", clips_json
            )
            return {}
        return {c.id: c.frames for c in load_clips(clips_json)}

    def embed_pending(self) -> int:
        """Compute CLIP embeddings for feedback rows that lack them."""
        latest = self._latest_by_segment()
        if not latest:
            logger.info("no feedback logged yet; nothing to embed")
            return 0
        embeddings = self._load_embeddings()
        pending = {sid: row for sid, row in latest.items() if sid not in embeddings}
        if not pending:
            logger.info("all %d feedback rows already embedded", len(latest))
            return 0

        self._clip()  # surface the missing-dependency error before any work
        new = 0
        for sid, row in pending.items():
            vec = self._embed_paths([str(p) for p in row.get("frame_paths", [])])
            if vec is None:
                logger.warning("no readable frames for %s; skipped", sid)
                continue
            embeddings[sid] = vec
            new += 1
        if new:
            self._save_embeddings(embeddings)
        logger.info("embedded %d new rows (%d total cached)", new, len(embeddings))
        return new

    def train(self) -> dict:
        """Fit the ranker once enough examples exist."""
        latest = self._latest_by_segment()
        embeddings = self._load_embeddings()
        ids = [sid for sid in latest if sid in embeddings]
        min_examples = int(self.cfg["taste.min_examples"])
        if len(ids) < min_examples:
            raise RuntimeError(
                f"taste ranker needs >= {min_examples} embedded examples, "
                f"have {len(ids)} (log more feedback / run embed_pending)"
            )

        x = np.stack([embeddings[sid] for sid in ids]).astype(np.float64)
        y = np.array([1.0 if latest[sid]["kept"] else 0.0 for sid in ids])
        n, dim = x.shape
        w = np.zeros(dim)
        b = 0.0
        for _ in range(_TRAIN_STEPS):
            err = _sigmoid(x @ w + b) - y
            w -= _TRAIN_LR * (x.T @ err / n + _TRAIN_L2 * w)
            b -= _TRAIN_LR * float(err.mean())

        pred = _sigmoid(x @ w + b)
        acc = float(np.mean((pred >= 0.5) == (y >= 0.5)))
        model = {
            "w": [float(v) for v in w],
            "b": float(b),
            "n": int(n),
            "acc": acc,
        }
        self._ensure_dir()
        with open(self.model_path, "w", encoding="utf-8") as fh:
            json.dump(model, fh)
        logger.info("trained taste ranker on %d examples (train acc %.3f)", n, acc)
        return model

    @property
    def ready(self) -> bool:
        return self.model_path.is_file()

    def predict(
        self, segments: list[ScoredSegment], clips: list[ClipInfo]
    ) -> dict[str, float] | None:
        """Score segments with the trained ranker (segment_id -> 0..1)."""
        if not self.ready:
            logger.warning("taste model not trained yet; predict() unavailable")
            return None
        with open(self.model_path, "r", encoding="utf-8") as fh:
            model = json.load(fh)
        w = np.asarray(model["w"], dtype=np.float64)
        b = float(model["b"])

        cached = self._load_embeddings()
        frames_by_clip = {c.id: c.frames for c in clips}
        vecs: dict[str, np.ndarray] = {}
        missing: list[ScoredSegment] = []
        for scored in segments:
            sid = scored.segment.id
            if sid in cached:
                vecs[sid] = cached[sid]
            else:
                missing.append(scored)

        if missing:
            try:
                self._clip()
            except RuntimeError:
                logger.warning(
                    "open_clip unavailable (pip install 'autocut[taste]'); "
                    "scoring only %d cached of %d segments",
                    len(vecs),
                    len(segments),
                )
                missing = []
            for scored in missing:
                seg = scored.segment
                paths = _frames_in_window(
                    frames_by_clip.get(seg.clip_id, []), float(seg.start), float(seg.end)
                )
                vec = self._embed_paths(paths)
                if vec is None:
                    logger.warning("segment %s has no embeddable frames", seg.id)
                    continue
                vecs[seg.id] = vec

        if not vecs:
            logger.warning("no embeddable segments; taste predict returns None")
            return None
        return {
            sid: float(_sigmoid(float(np.dot(w, vec.astype(np.float64))) + b))
            for sid, vec in vecs.items()
        }
