"""Agentic self-critique loop (v2 - working skeleton).

Contract
--------
review_loop(render_path, edl, segments, clips, music, cfg, workdir) -> list[Path]
    * Up to cfg["review.max_iterations"] passes; keep ALL versions
      (edl_v1.json, renders/reel_v2.mp4, edl_v2.json, ...) - never overwrite.
      v1 is the input render.
    * Each pass:
        1. Sample cfg["review.frames_per_pass"] stills from the current render
           (ingest.extract_frames_at), labeled with their timeline timestamp.
        2. Send to the Anthropic API (model: cfg["review.model"] or fall back
           to cfg["judge.model"]) with the style brief and the current EDL as
           JSON: "critique this edit - pacing, clip choice, cut timing - and
           propose specific EDL changes".
        3. Structured critique via a forced `propose_revisions` tool call
           (strict schema): overall_notes plus a list of operations:
             {op: "replace_segment" | "drop_event" | "swap_events" |
              "retime_event", event_idx, replacement_segment_id ("" unused),
              other_event_idx (-1 unused), new_src_in (-1 unused)}
           Same cross-model rules as judge.py: no thinking/temperature
           params, handle stop_reason == "refusal" by stopping the loop.
        4. Apply the operations to the EDL (validating segment ids / indices;
           invalid operations are skipped with a warning), re-pack rec times
           contiguously with slot durations preserved, re-render via
           assemble.render.
        5. Stop early when the critique returns no operations.
    * Returns the list of render paths (all versions, newest last).
"""

from __future__ import annotations

import base64
import json
import logging
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import anthropic
from anthropic import Anthropic

from . import assemble, ingest
from .config import Cfg
from .models import (
    image_media_type as _media_type,
    EDL,
    ClipInfo,
    EDLEvent,
    Frame,
    MusicAnalysis,
    ScoredSegment,
    Segment,
    save_json,
)

logger = logging.getLogger("autocut.review")

# Fixed by the review spec (a replacement segment must cover at least 80% of
# the slot it fills); style.yaml has no key for it.
_MIN_REPLACEMENT_FILL = 0.8

_OPS = ("replace_segment", "drop_event", "swap_events", "retime_event")

_OPERATION: dict[str, Any] = {
    "type": "object",
    "properties": {
        "op": {"type": "string", "enum": list(_OPS)},
        "event_idx": {"type": "integer", "description": "idx of the EDL event to modify"},
        "replacement_segment_id": {
            "type": "string",
            "description": 'segment id for replace_segment; "" when unused',
        },
        "other_event_idx": {
            "type": "integer",
            "description": "second event idx for swap_events; -1 when unused",
        },
        "new_src_in": {
            "type": "number",
            "description": "new clip-relative in-point in seconds for retime_event; -1 when unused",
        },
    },
    "required": [
        "op",
        "event_idx",
        "replacement_segment_id",
        "other_event_idx",
        "new_src_in",
    ],
    "additionalProperties": False,
}

REVISE_TOOL: dict[str, Any] = {
    "name": "propose_revisions",
    "description": "Propose specific EDL revisions after critiquing the rendered edit.",
    "strict": True,
    "input_schema": {
        "type": "object",
        "properties": {
            "overall_notes": {"type": "string", "description": "short overall critique"},
            "operations": {"type": "array", "items": _OPERATION},
        },
        "required": ["overall_notes", "operations"],
        "additionalProperties": False,
    },
}

_INSTRUCTIONS = (
    "\n\n"
    "You are reviewing a rendered cut of this reel. You get the edit decision "
    "list (EDL) as JSON, a list of unused candidate segments, a music summary, "
    "and stills sampled uniformly across the rendered timeline (each labeled "
    "with its timeline timestamp).\n"
    "Critique the edit against the style brief and report revisions with the "
    "propose_revisions tool. Available operations:\n"
    "- replace_segment: swap event_idx's source for replacement_segment_id "
    "(pick from the unused candidates)\n"
    "- drop_event: remove event_idx; later shots shift earlier\n"
    "- swap_events: exchange the sources of event_idx and other_event_idx\n"
    "- retime_event: move event_idx's source in-point to new_src_in seconds "
    "(shot length is preserved)\n"
    'Unused fields must carry their sentinel: replacement_segment_id "", '
    "other_event_idx -1, new_src_in -1.\n"
    "Return an empty operations list if the edit is good."
)

_CRITIQUE = (
    "critique this edit - pacing, clip choice, cut timing - and propose "
    "specific EDL changes via the tool; return an empty operations list if "
    "the edit is good"
)


# ---------------------------------------------------------------------------
# prompt assembly

def _edl_summary(edl: EDL) -> str:
    rows = [
        {
            "idx": ev.idx,
            "clip_id": ev.clip_id,
            "src_in": round(ev.src_in, 2),
            "src_out": round(ev.src_out, 2),
            "rec_in": round(ev.rec_in, 2),
            "rec_out": round(ev.rec_out, 2),
            "shot_type": ev.shot_type,
            "score": round(ev.score, 3),
            "rationale": ev.rationale,
        }
        for ev in edl.events
    ]
    return json.dumps(rows, separators=(",", ":"))


def _candidate_summary(edl: EDL, segments: list[ScoredSegment]) -> str:
    used = {ev.segment_id for ev in edl.events}
    rows = [
        {
            "id": ss.segment.id,
            "clip_id": ss.segment.clip_id,
            "dur": round(ss.segment.duration, 2),
            "shot_type": ss.judge.shot_type if ss.judge else "unknown",
            "score": round(ss.final, 3),
        }
        for ss in sorted(segments, key=lambda s: s.final, reverse=True)
        if ss.segment.id not in used
    ]
    return json.dumps(rows, separators=(",", ":"))


def _music_summary(music: MusicAnalysis) -> str:
    impacts = ", ".join(f"{float(t):.2f}" for t in music.impact_points)
    return (
        f"Music: {music.tempo:.1f} BPM, {music.duration:.1f}s long; "
        f"impact points at [{impacts}]s."
    )


def _user_blocks(
    edl: EDL,
    segments: list[ScoredSegment],
    music: MusicAnalysis,
    frames: list[Frame],
) -> list[dict[str, Any]]:
    text = (
        "Current EDL (one event per cut):\n" + _edl_summary(edl)
        + "\n\nUnused candidate segments (for replace_segment):\n"
        + _candidate_summary(edl, segments)
        + "\n\n" + _music_summary(music)
        + "\n\n" + _CRITIQUE
    )
    blocks: list[dict[str, Any]] = [{"type": "text", "text": text}]
    for frame in frames:
        try:
            raw = Path(frame.path).read_bytes()
        except OSError as exc:
            logger.warning("Cannot read review frame %s: %s; skipping it", frame.path, exc)
            continue
        blocks.append({"type": "text", "text": f"t={frame.t:.2f}s (timeline)"})
        blocks.append({
            "type": "image",
            "source": {
                "type": "base64",
                "media_type": _media_type(frame.path),
                "data": base64.b64encode(raw).decode(),
            },
        })
    return blocks


# ---------------------------------------------------------------------------
# EDL surgery

def _copy_edl(edl: EDL) -> EDL:
    return EDL.from_dict(edl.to_dict())


def _slot_len(ev: EDLEvent) -> float:
    return ev.rec_out - ev.rec_in


def _trim_to_slot(seg: Segment, slot: float, clip: ClipInfo | None) -> tuple[float, float]:
    """Center a slot-length src window on the segment middle, clamped."""
    mid = (seg.start + seg.end) / 2.0
    src_in = min(max(mid - slot / 2.0, seg.start), max(seg.start, seg.end - slot))
    if clip is not None:
        src_in = max(0.0, min(src_in, max(0.0, clip.duration - slot)))
    return float(src_in), float(src_in + slot)


def _crop_x_for(ss: ScoredSegment, cfg: Cfg) -> float:
    # Mirror assemble's reframe rule so replaced content is re-centered.
    if str(cfg["assemble.reframe.mode"]) == "subject" and ss.judge is not None:
        offset = float(cfg["assemble.reframe.max_offset"])
        crop = 0.5 + (float(ss.judge.subject_x) - 0.5) * offset
    else:
        crop = 0.5  # frame center
    return float(min(1.0, max(0.0, crop)))


_SWAP_FIELDS = (
    "segment_id",
    "clip_id",
    "clip_path",
    "shot_type",
    "is_hero",
    "crop_x",
    "score",
    "rationale",
)


def _apply_operations(
    events: list[EDLEvent],
    operations: list[Any],
    seg_by_id: dict[str, ScoredSegment],
    clip_by_id: dict[str, ClipInfo],
    cfg: Cfg,
) -> int:
    """Apply proposed operations in order; skip invalid ones. Returns the count applied."""
    applied = 0
    for raw in operations:
        if not isinstance(raw, dict):
            logger.warning("Review: ignoring malformed operation %r", raw)
            continue
        name = str(raw.get("op", ""))
        try:
            event_idx = int(raw.get("event_idx", -1))
            other_idx = int(raw.get("other_event_idx", -1))
            new_src_in = float(raw.get("new_src_in", -1.0))
        except (TypeError, ValueError):
            logger.warning("Review: ignoring operation with non-numeric fields: %r", raw)
            continue
        replacement_id = str(raw.get("replacement_segment_id") or "")

        by_idx = {ev.idx: ev for ev in events}
        ev = by_idx.get(event_idx)
        if ev is None:
            logger.warning("Review: %s references unknown event idx %d; skipped", name, event_idx)
            continue

        if name == "drop_event":
            events.remove(ev)
            applied += 1

        elif name == "swap_events":
            other = by_idx.get(other_idx)
            if other is None or other is ev:
                logger.warning(
                    "Review: swap_events(%d, %d) has no valid partner; skipped",
                    event_idx, other_idx,
                )
                continue
            if ev.segment_id not in seg_by_id or other.segment_id not in seg_by_id:
                logger.warning(
                    "Review: swap_events(%d, %d) references unknown segment(s); skipped",
                    event_idx, other_idx,
                )
                continue
            for field_name in _SWAP_FIELDS:
                a, b = getattr(ev, field_name), getattr(other, field_name)
                setattr(ev, field_name, b)
                setattr(other, field_name, a)
            for event in (ev, other):
                seg = seg_by_id[event.segment_id].segment
                clip = clip_by_id.get(event.clip_id)
                event.src_in, event.src_out = _trim_to_slot(seg, _slot_len(event), clip)
            applied += 1

        elif name == "replace_segment":
            ss = seg_by_id.get(replacement_id) if replacement_id else None
            if ss is None:
                logger.warning(
                    "Review: replace_segment on event %d references unknown segment %r; skipped",
                    event_idx, replacement_id,
                )
                continue
            slot = _slot_len(ev)
            if ss.segment.duration < _MIN_REPLACEMENT_FILL * slot:
                logger.warning(
                    "Review: segment %s (%.2fs) too short for %.2fs slot on event %d; skipped",
                    replacement_id, ss.segment.duration, slot, event_idx,
                )
                continue
            clip = clip_by_id.get(ss.segment.clip_id)
            if clip is None:
                logger.warning(
                    "Review: segment %s references unknown clip %s; skipped",
                    replacement_id, ss.segment.clip_id,
                )
                continue
            ev.segment_id = ss.segment.id
            ev.clip_id = clip.id
            ev.clip_path = clip.path
            ev.src_in, ev.src_out = _trim_to_slot(ss.segment, slot, clip)
            if ss.judge is not None:
                ev.shot_type = ss.judge.shot_type
                ev.rationale = ss.judge.rationale
            ev.crop_x = _crop_x_for(ss, cfg)
            ev.score = float(ss.final)
            applied += 1

        elif name == "retime_event":
            if new_src_in < 0:
                logger.warning(
                    "Review: retime_event on event %d without new_src_in; skipped", event_idx
                )
                continue
            ss = seg_by_id.get(ev.segment_id)
            if ss is None:
                logger.warning(
                    "Review: retime_event on event %d references unknown segment %s; skipped",
                    event_idx, ev.segment_id,
                )
                continue
            slot = _slot_len(ev)
            seg = ss.segment
            src_in = min(max(new_src_in, seg.start), max(seg.start, seg.end - slot))
            ev.src_in = float(src_in)
            ev.src_out = float(src_in + slot)
            applied += 1

        else:
            logger.warning("Review: unknown operation %r; skipped", name)

    return applied


def _repack(events: list[EDLEvent]) -> None:
    """Re-number and re-pack rec times contiguously from 0.

    Limitation: slot durations are preserved verbatim, so the cut spacing still
    follows the beat grid the slots were originally built on - but after a
    drop_event, every later cut shifts earlier by the dropped slot's length and
    is NOT re-snapped to the nearest music beat.
    """
    t = 0.0
    for i, ev in enumerate(events):
        slot = _slot_len(ev)
        ev.idx = i
        ev.rec_in = float(t)
        ev.rec_out = float(t + slot)
        t = ev.rec_out


# ---------------------------------------------------------------------------

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
    workdir = Path(workdir)
    renders: list[Path] = [Path(render_path)]

    model = str(cfg["review.model"] or cfg["judge.model"])
    max_iterations = int(cfg["review.max_iterations"])
    frames_per_pass = int(cfg["review.frames_per_pass"])
    max_tokens = int(cfg["review.max_tokens"])

    current = _copy_edl(edl)
    if not current.events:
        logger.warning("Review: EDL has no events; nothing to critique")
        return renders
    save_json(current, workdir / "edl_v1.json")

    seg_by_id = {ss.segment.id: ss for ss in segments}
    clip_by_id = {c.id: c for c in clips}
    system_prompt = str(cfg["judge.style_brief"]) + _INSTRUCTIONS
    client = Anthropic()

    for iteration in range(1, max_iterations + 1):
        logger.info("Review pass %d/%d on %s with %s", iteration, max_iterations, renders[-1], model)

        duration = current.duration
        times = [duration * (i + 0.5) / frames_per_pass for i in range(frames_per_pass)]
        frames_dir = workdir / "review_frames" / f"v{iteration}"
        try:
            frames = ingest.extract_frames_at(renders[-1], times, frames_dir, cfg)
        except (OSError, RuntimeError) as exc:
            logger.error("Review: frame extraction failed: %s; stopping", exc)
            return renders

        blocks = _user_blocks(current, segments, music, frames)

        try:
            resp = client.messages.create(
                model=model,
                max_tokens=max_tokens,
                system=[{
                    "type": "text",
                    "text": system_prompt,
                    "cache_control": {"type": "ephemeral"},
                }],
                tools=[REVISE_TOOL],
                tool_choice={"type": "tool", "name": "propose_revisions"},
                messages=[{"role": "user", "content": blocks}],
            )
        except anthropic.APIStatusError as exc:
            logger.error("Review API error %s: %s; stopping", exc.status_code, exc.message)
            return renders
        except anthropic.APIConnectionError as exc:
            logger.error("Review connection error: %s; stopping", exc)
            return renders

        if resp.stop_reason == "refusal":
            logger.warning("Review model refused pass %d; stopping", iteration)
            return renders

        data: Any = None
        for block in resp.content:
            if block.type == "tool_use" and block.name == "propose_revisions":
                data = block.input
                break
        if not isinstance(data, dict):
            logger.warning("Review response contained no propose_revisions call; stopping")
            return renders

        notes = str(data.get("overall_notes", "")).strip()
        if notes:
            logger.info("Review notes (pass %d): %s", iteration, notes)

        operations = data.get("operations") or []
        if not operations:
            logger.info("Review pass %d proposed no changes; accepting the edit", iteration)
            return renders

        applied = _apply_operations(current.events, operations, seg_by_id, clip_by_id, cfg)
        if applied == 0:
            logger.warning(
                "Review pass %d: all %d proposed operation(s) were invalid; stopping",
                iteration, len(operations),
            )
            return renders
        if not current.events:
            logger.warning("Review pass %d dropped every event; stopping", iteration)
            return renders

        _repack(current.events)
        current.created_at = datetime.now(timezone.utc).isoformat()

        n = iteration + 1
        save_json(current, workdir / f"edl_v{n}.json")
        out_path = workdir / "renders" / f"reel_v{n}.mp4"
        out_path.parent.mkdir(parents=True, exist_ok=True)
        try:
            rendered = assemble.render(current, clips, cfg, out_path)
        except (OSError, RuntimeError) as exc:
            logger.error("Review: render of v%d failed: %s; stopping", n, exc)
            return renders
        renders.append(Path(rendered))
        logger.info(
            "Review pass %d: applied %d/%d operation(s) -> %s",
            iteration, applied, len(operations), rendered,
        )

    return renders
