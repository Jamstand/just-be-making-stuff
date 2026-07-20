"""Agentic self-critique loop (v2 - working skeleton).

Contract
--------
review_loop(render_path, edl, segments, clips, music, cfg, workdir) -> list[Path]
    * Up to cfg["review.max_iterations"] passes; keep ALL versions
      (render_v1.mp4, edl_v1.json, render_v2.mp4, ...) - never overwrite.
    * Each pass:
        1. Sample cfg["review.frames_per_pass"] stills from the rendered
           output (ingest.extract_frames_at), labeled with their timeline
           timestamp.
        2. Send to the Anthropic API (model: cfg["review.model"] or fall back
           to cfg["judge.model"]) with the style brief and the current EDL as
           JSON: "critique this edit - pacing, clip choice, cut timing - and
           propose specific EDL changes".
        3. Structured critique via a forced `propose_revisions` tool call
           (strict schema): overall_notes plus a list of operations:
             {op: "replace_segment" | "drop_event" | "swap_events" |
              "retime_event", event_idx, replacement_segment_id?,
              other_event_idx?, new_src_in?}
           Same cross-model rules as judge.py: no thinking/temperature
           params, handle stop_reason == "refusal" by stopping the loop.
        4. Apply the operations to the EDL (validating segment ids / indices;
           keep rec times contiguous and beat-aligned - re-snap rec_out to
           the beat grid after edits), re-render via assemble.render.
        5. Stop early when the critique returns no operations.
    * Returns the list of render paths (all versions, newest last).
"""

from __future__ import annotations

from pathlib import Path

from .config import Cfg
from .models import EDL, ClipInfo, MusicAnalysis, ScoredSegment


def review_loop(
    render_path: str | Path,
    edl: EDL,
    segments: list[ScoredSegment],
    clips: list[ClipInfo],
    music: MusicAnalysis,
    cfg: Cfg,
    workdir: Path,
) -> list[Path]:
    """Critique the rendered edit with the API and apply revisions (max N passes)."""
    raise NotImplementedError
