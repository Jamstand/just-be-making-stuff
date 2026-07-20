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
        * Batch cfg["judge.segments_per_request"] segments per API call to
          control cost. Label images "Segment <id>, frame at <t>s".
        * Model: cfg["judge.model"] (default claude-sonnet-4-6, switchable to
          claude-opus-4-8 / claude-fable-5).
          IMPORTANT cross-model rules:
            - do NOT pass a `thinking` parameter (fable-5 rejects explicit
              configs; omitting works correctly on all three models)
            - do NOT pass temperature/top_p/top_k (rejected on opus-4-8/fable-5)
            - check response.stop_reason == "refusal" before reading content;
              on refusal, leave those segments judge=None and continue.
        * Structured output via a forced tool call: define a `score_segments`
          tool with strict=true and an input_schema requiring, per segment:
          {segment_id, composition, energy, hero, clutter (ints 0..10),
           shot_type (enum models.SHOT_TYPES), subject_x (0..1),
           rationale (string)}; call with
          tool_choice={"type": "tool", "name": "score_segments"}.
          Normalize 0..10 -> 0..1 into JudgeScores; judge composite score =
          mean(composition, energy, hero, clutter).
        * System prompt = style brief + scoring instructions, sent as a system
          block with cache_control {"type": "ephemeral"} so batched calls hit
          the prompt cache.
        * Disk cache: workdir/<judge.cache_dir>/<sha256>.json keyed by
          (model, style_brief, segment frame bytes). Skip API calls on hit.
        * Blend: final = (1-w)*heuristic.score + w*judge.score with
          w = cfg["judge.weight"]; segments without judge scores keep
          final = heuristic.score.
        * Persist updated segments to workdir/segments.json and return them.
        * Handle SDK errors with typed exceptions (RateLimitError etc.); the
          SDK already retries 429/5xx twice - on final failure, log and leave
          judge=None rather than crashing the pipeline.
"""

from __future__ import annotations

from pathlib import Path

from .config import Cfg
from .models import ClipInfo, ScoredSegment


def available(cfg: Cfg) -> bool:
    """Whether AI judging is enabled + credentialed for this run."""
    raise NotImplementedError


class Judge:
    def __init__(self, cfg: Cfg, workdir: Path):
        raise NotImplementedError

    def judge(self, clips: list[ClipInfo], segments: list[ScoredSegment]) -> list[ScoredSegment]:
        """Score segments with the AI judge and blend into final scores."""
        raise NotImplementedError
