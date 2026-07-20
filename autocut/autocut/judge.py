"""AI clip scoring via the Anthropic API.

Sends sampled frames per segment plus the style brief (cfg["judge.style_brief"])
and gets back structured scores + a one-line rationale per segment.

Contract
--------
available(cfg) -> bool
    * cfg["judge.enabled"]: "never" -> False; "always" -> True (raise a clear
      error later if no key); "auto" -> True iff ANTHROPIC_API_KEY is set (or
      another SDK credential source resolves).

class Judge(cfg, workdir)
    judge(clips, segments) -> list[ScoredSegment]
        * For each segment pick up to cfg["judge.frames_per_segment"] stills
          from the pre-sampled clip frames whose timestamp falls inside the
          segment (fall back to ingest.extract_frames_at for uncovered
          segments).
        * Batch cfg["judge.segments_per_request"] segments per API call.
        * Model: cfg["judge.model"]. Cross-model rules: no `thinking`,
          no temperature/top_p/top_k; check stop_reason == "refusal" and leave
          those segments judge=None.
        * Structured output via a forced strict `score_segments` tool call;
          ints 0..10 are normalized to 0..1 in JudgeScores; judge composite
          score = mean(composition, energy, hero, clutter).
        * System prompt = style brief + scoring rubric, cached via
          cache_control {"type": "ephemeral"} (byte-stable across calls).
        * Disk cache: workdir/<judge.cache_dir>/<sha256>.json keyed by
          (model, style_brief, segment id, frame bytes). Skip API calls on hit.
        * Blend: final = (1-w)*heuristic.score + w*judge.score with
          w = cfg["judge.weight"]; segments without judge scores keep
          final = heuristic.score.
        * Persist updated segments to workdir/segments.json and return them.
        * SDK errors (the SDK already retries 429/5xx) are logged and the
          batch skipped rather than crashing the pipeline.
"""

from __future__ import annotations

import base64
import hashlib
import json
import logging
import os
from dataclasses import asdict
from pathlib import Path
from typing import Any

import anthropic
from anthropic import Anthropic

from . import ingest
from .config import Cfg
from .models import image_media_type as _media_type
from .models import SHOT_TYPES, ClipInfo, Frame, JudgeScores, ScoredSegment, save_json

logger = logging.getLogger("autocut.judge")

_SHOT_TYPE_DEFS: dict[str, str] = {
    "wide": "establishing shot showing the subject in its environment",
    "rolling": "subject in motion: rolling shot, tracking shot, pan, fly-by",
    "detail": "close-up detail: wheel, badge, headlight, reflection, texture",
    "motion": "strong camera or subject motion that is not clearly a rolling shot",
    "interior": "cabin or interior shot",
    "hero": "dramatic beauty shot with standout light and composition",
    "static": "locked-off static shot of the stationary subject",
    "other": "anything that fits none of the above",
}

_RUBRIC = (
    "\n\n"
    "Score each segment on four axes, each an integer 0-10 (10 = excellent, 0 = unusable):\n"
    "- composition: framing, balance, leading lines, clarity of the subject\n"
    "- energy: sense of speed, motion and visual excitement\n"
    "- hero: potential as a standout hero shot (drama, light, impact)\n"
    "- clutter: background cleanliness (10 = clean background, 0 = badly cluttered)\n"
    "subject_x: horizontal center of the main subject, 0 = left edge, 1 = right edge.\n"
    "shot_type: classify each segment as exactly one of:\n"
    + "".join(f"- {name}: {_SHOT_TYPE_DEFS.get(name, '')}\n" for name in SHOT_TYPES)
    + "rationale: one short line explaining the scores."
)

_ITEM: dict[str, Any] = {
    "type": "object",
    "properties": {
        "segment_id": {"type": "string", "description": "Id of the segment being scored"},
        "composition": {"type": "integer", "description": "Composition quality, 0-10"},
        "energy": {"type": "integer", "description": "Motion/visual energy, 0-10"},
        "hero": {"type": "integer", "description": "Hero-shot potential, 0-10"},
        "clutter": {"type": "integer", "description": "Background cleanliness, 0-10 (10 = clean)"},
        "shot_type": {"type": "string", "enum": list(SHOT_TYPES)},
        "subject_x": {"type": "number", "description": "horizontal subject center 0=left 1=right"},
        "rationale": {"type": "string", "description": "one line"},
    },
    "required": [
        "segment_id",
        "composition",
        "energy",
        "hero",
        "clutter",
        "shot_type",
        "subject_x",
        "rationale",
    ],
    "additionalProperties": False,
}

SCORE_TOOL: dict[str, Any] = {
    "name": "score_segments",
    "description": "Report structured quality scores for every listed video segment.",
    "strict": True,
    "input_schema": {
        "type": "object",
        "properties": {"segments": {"type": "array", "items": _ITEM}},
        "required": ["segments"],
        "additionalProperties": False,
    },
}


def available(cfg: Cfg) -> bool:
    """Whether AI judging is enabled + credentialed for this run."""
    enabled = cfg["judge.enabled"]
    if isinstance(enabled, bool):
        return enabled
    mode = str(enabled).strip().lower()
    if mode == "never":
        return False
    if mode == "always":
        return True
    return bool(os.environ.get("ANTHROPIC_API_KEY") or os.environ.get("ANTHROPIC_AUTH_TOKEN"))


def _clamp10(value: Any) -> int:
    return max(0, min(10, int(value)))


def _pick_even(frames: list[Frame], n: int) -> list[Frame]:
    """Up to n frames spread evenly across the list (first/middle/last)."""
    if n <= 0 or not frames:
        return []
    if len(frames) <= n:
        return list(frames)
    if n == 1:
        return [frames[len(frames) // 2]]
    idxs = sorted({round(i * (len(frames) - 1) / (n - 1)) for i in range(n)})
    return [frames[i] for i in idxs]


class Judge:
    def __init__(self, cfg: Cfg, workdir: Path):
        self.cfg = cfg
        self.workdir = Path(workdir)
        self.model = str(cfg["judge.model"])
        self.max_tokens = int(cfg["judge.max_tokens"])
        self.frames_per_segment = int(cfg["judge.frames_per_segment"])
        self.segments_per_request = int(cfg["judge.segments_per_request"])
        self.weight = float(cfg["judge.weight"])
        self.style_brief = str(cfg["judge.style_brief"])
        self.cache_dir = self.workdir / str(cfg["judge.cache_dir"])
        self.system_prompt = self.style_brief + _RUBRIC
        self._brief_sha = hashlib.sha256(self.style_brief.encode("utf-8")).hexdigest()
        self._client: Anthropic | None = None

    # -- public API ---------------------------------------------------------

    def judge(self, clips: list[ClipInfo], segments: list[ScoredSegment]) -> list[ScoredSegment]:
        """Score segments with the AI judge and blend into final scores."""
        clip_by_id = {c.id: c for c in clips}
        pending: list[tuple[ScoredSegment, list[Frame], str]] = []
        hits = 0

        for ss in segments:
            clip = clip_by_id.get(ss.segment.clip_id)
            if clip is None:
                logger.warning(
                    "Segment %s references unknown clip %s; skipping judge",
                    ss.segment.id, ss.segment.clip_id,
                )
                continue
            frames = self._frames_for(ss, clip)
            if not frames:
                continue
            try:
                key = self._cache_key(ss.segment.id, frames)
            except OSError as exc:
                logger.warning("Cannot hash frames for segment %s: %s", ss.segment.id, exc)
                continue
            cached = self._cache_load(key)
            if cached is not None:
                ss.judge = cached
                hits += 1
            else:
                pending.append((ss, frames, key))

        logger.info(
            "Judge: %d segment(s) from cache, %d to score with %s",
            hits, len(pending), self.model,
        )

        for start in range(0, len(pending), self.segments_per_request):
            batch = pending[start : start + self.segments_per_request]
            logger.info(
                "Judging batch %d/%d (%d segment(s))",
                start // self.segments_per_request + 1,
                (len(pending) + self.segments_per_request - 1) // self.segments_per_request,
                len(batch),
            )
            self._judge_batch(batch)

        for ss in segments:
            if ss.judge is not None:
                ss.final = float(
                    (1.0 - self.weight) * ss.heuristic.score + self.weight * ss.judge.score
                )
            else:
                ss.final = float(ss.heuristic.score)

        out = save_json(segments, self.workdir / "segments.json")
        logger.info("Judge: wrote %d segment(s) to %s", len(segments), out)
        return segments

    # -- frame selection ----------------------------------------------------

    def _frames_for(self, ss: ScoredSegment, clip: ClipInfo) -> list[Frame]:
        seg = ss.segment
        inside = sorted(
            (f for f in clip.frames if seg.start <= f.t <= seg.end), key=lambda f: f.t
        )
        if inside:
            return _pick_even(inside, self.frames_per_segment)
        midpoint = (seg.start + seg.end) / 2.0
        out_dir = self.workdir / "frames" / clip.id
        try:
            return ingest.extract_frames_at(
                Path(clip.analysis_path), [midpoint], out_dir, self.cfg
            )
        except (OSError, RuntimeError) as exc:
            logger.warning("Frame extraction failed for segment %s: %s", seg.id, exc)
            return []

    # -- disk cache ---------------------------------------------------------

    def _cache_key(self, segment_id: str, frames: list[Frame]) -> str:
        h = hashlib.sha256()
        h.update(self.model.encode("utf-8"))
        h.update(self._brief_sha.encode("ascii"))
        h.update(segment_id.encode("utf-8"))
        for frame in frames:
            digest = hashlib.sha256(Path(frame.path).read_bytes()).hexdigest()
            h.update(digest.encode("ascii"))
        return h.hexdigest()

    def _cache_load(self, key: str) -> JudgeScores | None:
        path = self.cache_dir / f"{key}.json"
        if not path.is_file():
            return None
        try:
            return JudgeScores(**json.loads(path.read_text(encoding="utf-8")))
        except (OSError, TypeError, ValueError) as exc:
            logger.warning("Ignoring unreadable judge cache %s: %s", path, exc)
            return None

    def _cache_store(self, key: str, scores: JudgeScores) -> None:
        try:
            self.cache_dir.mkdir(parents=True, exist_ok=True)
            path = self.cache_dir / f"{key}.json"
            path.write_text(json.dumps(asdict(scores), indent=2), encoding="utf-8")
        except OSError as exc:
            logger.warning("Could not write judge cache entry %s: %s", key, exc)

    # -- API calls ----------------------------------------------------------

    def _get_client(self) -> Anthropic:
        if self._client is None:
            self._client = Anthropic()
        return self._client

    def _judge_batch(self, batch: list[tuple[ScoredSegment, list[Frame], str]]) -> None:
        blocks: list[dict[str, Any]] = []
        for ss, frames, _key in batch:
            seg = ss.segment
            times = ", ".join(f"{f.t:.2f}" for f in frames)
            blocks.append({
                "type": "text",
                "text": (
                    f"Segment {seg.id}: {len(frames)} frames at {times}s, "
                    f"source clip {seg.clip_id}"
                ),
            })
            for frame in frames:
                try:
                    raw = Path(frame.path).read_bytes()
                except OSError as exc:
                    logger.warning("Cannot read frame %s: %s; skipping batch", frame.path, exc)
                    return
                blocks.append({
                    "type": "image",
                    "source": {
                        "type": "base64",
                        "media_type": _media_type(frame.path),
                        "data": base64.b64encode(raw).decode(),
                    },
                })
        listed = ", ".join(ss.segment.id for ss, _f, _k in batch)
        blocks.append({
            "type": "text",
            "text": (
                f"Score every listed segment ({listed}). "
                "Return exactly one entry per segment_id."
            ),
        })

        try:
            resp = self._get_client().messages.create(
                model=self.model,
                max_tokens=self.max_tokens,
                system=[{
                    "type": "text",
                    "text": self.system_prompt,
                    "cache_control": {"type": "ephemeral"},
                }],
                tools=[SCORE_TOOL],
                tool_choice={"type": "tool", "name": "score_segments"},
                messages=[{"role": "user", "content": blocks}],
            )
        except anthropic.APIStatusError as exc:
            logger.error(
                "Judge API error %s: %s; skipping batch of %d segment(s)",
                exc.status_code, exc.message, len(batch),
            )
            return
        except anthropic.APIConnectionError as exc:
            logger.error(
                "Judge connection error: %s; skipping batch of %d segment(s)", exc, len(batch)
            )
            return

        if resp.stop_reason == "refusal":
            logger.warning(
                "Judge refused a batch of %d segment(s); leaving them unjudged", len(batch)
            )
            return

        data: Any = None
        for block in resp.content:
            if block.type == "tool_use" and block.name == "score_segments":
                data = block.input
                break
        if not isinstance(data, dict):
            logger.warning("Judge response contained no score_segments call; skipping batch")
            return

        entries: dict[str, dict[str, Any]] = {}
        for entry in data.get("segments", []):
            if isinstance(entry, dict) and "segment_id" in entry:
                entries[str(entry["segment_id"])] = entry

        for ss, _frames, key in batch:
            entry = entries.get(ss.segment.id)
            if entry is None:
                logger.warning("Judge returned no entry for segment %s", ss.segment.id)
                continue
            scores = self._parse_entry(entry)
            if scores is None:
                continue
            ss.judge = scores
            self._cache_store(key, scores)

    def _parse_entry(self, entry: dict[str, Any]) -> JudgeScores | None:
        try:
            composition = _clamp10(entry["composition"])
            energy = _clamp10(entry["energy"])
            hero = _clamp10(entry["hero"])
            clutter = _clamp10(entry["clutter"])
            subject_x = min(1.0, max(0.0, float(entry["subject_x"])))
            shot_type = str(entry["shot_type"])
            rationale = str(entry.get("rationale", ""))
        except (KeyError, TypeError, ValueError) as exc:
            logger.warning("Malformed judge entry %r: %s", entry, exc)
            return None
        if shot_type not in SHOT_TYPES:
            shot_type = "other"
        return JudgeScores(
            composition=composition / 10.0,
            energy=energy / 10.0,
            hero=hero / 10.0,
            clutter=clutter / 10.0,
            shot_type=shot_type,
            subject_x=subject_x,
            rationale=rationale,
            model=self.model,
            score=(composition + energy + hero + clutter) / 4.0 / 10.0,
        )
