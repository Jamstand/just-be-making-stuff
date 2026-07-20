"""vanscut - the AUTOCUT command line.

Commands
--------
vanscut analyze <folder> [--style style.yaml]
    ingest.scan -> analyze.analyze_clips -> (judge when available)
    Prints a ranked segment table; artifacts land in <folder>/_autocut/.

vanscut cut <folder> <song> [--style style.yaml] [--out reel.mp4]
            [--no-judge] [--duration S]
    Full pipeline: ingest -> audio -> analyze -> judge (unless --no-judge or
    unavailable) -> taste blend (when trained) -> build_edl -> render ->
    export FCPXML (+ Resolve API when available).
    Reuses cached stage outputs in the workdir when inputs are unchanged.

vanscut review <folder> [--style style.yaml]
    Runs review.review_loop on the latest render + EDL in the workdir.

vanscut feedback <folder>
    Interactive keep/reject over the latest EDL's events: prints each event
    (clip, time range, score, rationale) and asks [k]eep / [r]eject / [s]kip
    / [q]uit. Feeds taste.TasteStore.log_feedback, then offers train() when
    >= taste.min_examples examples exist.

Implementation notes:
    * argparse subparsers; main(argv=None) -> int exit code.
    * All stage plumbing (what reads/writes which workdir JSON) lives here so
      modules stay pure. Stage outputs: clips.json, music.json, segments.json,
      edl.json, renders under workdir/renders/.
    * Friendly errors: missing ffmpeg -> tell the user how to install it
      (winget install Gyan.FFmpeg on Windows); missing ANTHROPIC_API_KEY with
      judge enabled=always -> clear message.
    * Windows-safe: pathlib everywhere, no shell=True anywhere.
"""

from __future__ import annotations

import argparse
import logging
import os
import re
import shutil
import sys
from pathlib import Path

from . import analyze, assemble, audio, config, ingest, judge, review, taste
from .config import Cfg
from .models import (
    ClipInfo,
    MusicAnalysis,
    ScoredSegment,
    load_clips,
    load_edl,
    load_music,
    load_segments,
    save_json,
)

logger = logging.getLogger("autocut.cli")

# Fixed by the CLI spec (rows shown by `vanscut analyze`); not a style tunable.
_TOP_N = 25

_EDL_V_RE = re.compile(r"^edl_v(\d+)\.json$")
_REEL_RE = re.compile(r"^reel_v(\d+)\.mp4$", re.IGNORECASE)


# ---------------------------------------------------------------------------
# parser / entry point

def _add_common(sp: argparse.ArgumentParser) -> None:
    sp.add_argument("folder", help="folder containing the source clips")
    sp.add_argument("--style", default=None,
                    help="style.yaml to merge over the defaults (default: ./style.yaml if present)")


def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="vanscut",
                                description="AUTOCUT - AI-assisted automatic video editor")
    sub = p.add_subparsers(dest="command", required=True)

    pa = sub.add_parser("analyze", help="scan + score clips, print a ranked segment table")
    _add_common(pa)
    pa.set_defaults(func=_cmd_analyze)

    pc = sub.add_parser("cut", help="full pipeline: analyze, sequence, render, export")
    pc.add_argument("folder", help="folder containing the source clips")
    pc.add_argument("song", help="music track to cut to")
    pc.add_argument("--style", default=None,
                    help="style.yaml to merge over the defaults (default: ./style.yaml if present)")
    pc.add_argument("--out", default=None,
                    help="render output path (default: <workdir>/renders/reel_v1.mp4)")
    pc.add_argument("--duration", type=float, default=None,
                    help="target duration in seconds (overrides assemble.target_duration_s)")
    pc.add_argument("--no-judge", action="store_true", help="skip the AI judge")
    pc.add_argument("--fresh", action="store_true", help="ignore cached stage outputs")
    pc.set_defaults(func=_cmd_cut)

    pr = sub.add_parser("review", help="agentic critique loop on the latest render")
    _add_common(pr)
    pr.set_defaults(func=_cmd_review)

    pf = sub.add_parser("feedback", help="interactive keep/reject feedback for the taste model")
    _add_common(pf)
    pf.set_defaults(func=_cmd_feedback)
    return p


def _preflight(cfg: Cfg) -> bool:
    missing = [tool for tool in (str(cfg["tools.ffmpeg"]), str(cfg["tools.ffprobe"]))
               if shutil.which(tool) is None]
    if not missing:
        return True
    print("Required tool(s) not found on PATH: {}".format(", ".join(missing)))
    print("Install ffmpeg - Windows: winget install Gyan.FFmpeg | Linux: apt install ffmpeg")
    return False


def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    args = _build_parser().parse_args(argv)
    try:
        cfg = config.load_style(args.style)
        duration = getattr(args, "duration", None)
        if duration is not None:
            data = cfg.raw()
            data["assemble"]["target_duration_s"] = float(duration)
            cfg = Cfg(data, source=cfg.source)
        if not _preflight(cfg):
            return 2
        return int(args.func(args, cfg))
    except Exception as exc:
        logger.exception("%s failed: %s", args.command, exc)
        return 1


# ---------------------------------------------------------------------------
# stage caching

def _cached_clips(workdir: Path, fresh: bool) -> list[ClipInfo] | None:
    path = workdir / "clips.json"
    if fresh or not path.is_file():
        return None
    try:
        clips = load_clips(path)
    except Exception as exc:
        logger.warning("ignoring unreadable %s (%s)", path, exc)
        return None
    if not all(Path(c.path).is_file() for c in clips):
        logger.info("cached clips.json references missing files; rescanning")
        return None
    logger.info("using cached clips.json (%d clip(s))", len(clips))
    return clips


def _cached_music(workdir: Path, song: Path, fresh: bool) -> MusicAnalysis | None:
    path = workdir / "music.json"
    if fresh or not path.is_file():
        return None
    try:
        music = load_music(path)
    except Exception as exc:
        logger.warning("ignoring unreadable %s (%s)", path, exc)
        return None
    if music.path != str(song):
        return None
    logger.info("using cached music.json")
    return music


def _cached_segments(workdir: Path) -> list[ScoredSegment] | None:
    path = workdir / "segments.json"
    if not path.is_file():
        return None
    try:
        segments = load_segments(path)
    except Exception as exc:
        logger.warning("ignoring unreadable %s (%s)", path, exc)
        return None
    logger.info("using cached segments.json (%d segment(s))", len(segments))
    return segments


# ---------------------------------------------------------------------------
# shared stages

def _run_judge(clips: list[ClipInfo], segments: list[ScoredSegment],
               cfg: Cfg, workdir: Path) -> None:
    """Judge in place; failures degrade to heuristic-only scoring."""
    if not judge.available(cfg):
        logger.info("AI judge disabled or no API key; using heuristic scores only")
        return
    has_key = bool(os.environ.get("ANTHROPIC_API_KEY") or os.environ.get("ANTHROPIC_AUTH_TOKEN"))
    if str(cfg["judge.enabled"]).strip().lower() == "always" and not has_key:
        logger.warning("judge.enabled=always but neither ANTHROPIC_API_KEY nor "
                       "ANTHROPIC_AUTH_TOKEN is set; the judge will likely fail")
    try:
        judge.Judge(cfg, workdir).judge(clips, segments)
    except Exception as exc:
        logger.warning("AI judge failed (%s); continuing with heuristic scores only", exc)


def _blend_taste(segments: list[ScoredSegment], clips: list[ClipInfo],
                 cfg: Cfg, workdir: Path) -> None:
    try:
        store = taste.TasteStore(cfg, workdir)
        if not store.ready:
            return
        scores = store.predict(segments, clips)
    except Exception as exc:
        logger.warning("taste model unavailable (%s); skipping taste blend", exc)
        return
    if not scores:
        return
    tw = float(cfg["taste.weight"])
    for ss in segments:
        sid = ss.segment.id
        if sid in scores:
            ss.taste = float(scores[sid])
        ss.final = float((1.0 - tw) * float(ss.final) + tw * float(scores.get(sid, ss.final)))
    save_json(segments, workdir / "segments.json")
    logger.info("blended taste scores (weight %.2f) into %d segment(s)", tw, len(scores))


def _print_table(segments: list[ScoredSegment]) -> None:
    rows = sorted(segments, key=lambda s: float(s.final), reverse=True)[:_TOP_N]
    fmt = "{:<18} {:<14} {:>13} {:>6} {:>6} {:>6} {:<9} {}"
    print()
    print(fmt.format("SEGMENT", "CLIP", "RANGE", "HEUR", "JUDGE", "FINAL", "TYPE", "RATIONALE"))
    for ss in rows:
        seg = ss.segment
        j = ss.judge
        print(fmt.format(
            seg.id,
            seg.clip_id,
            "{:.2f}-{:.2f}".format(seg.start, seg.end),
            "{:.2f}".format(ss.heuristic.score),
            "{:.2f}".format(j.score) if j else "-",
            "{:.2f}".format(ss.final),
            j.shot_type if j else "-",
            j.rationale[:60] if j else "",
        ))


# ---------------------------------------------------------------------------
# commands

def _cmd_analyze(args: argparse.Namespace, cfg: Cfg) -> int:
    folder = Path(args.folder)
    if not folder.is_dir():
        logger.error("not a folder: %s", folder)
        return 1
    workdir = config.workdir_for(folder, cfg)

    clips = _cached_clips(workdir, fresh=False)
    clips_cached = clips is not None
    if clips is None:
        clips = ingest.scan(folder, cfg, workdir)
    if not clips:
        logger.error("no clips found in %s", folder)
        return 1

    segments = _cached_segments(workdir) if clips_cached else None
    if segments is None:
        segments = analyze.analyze_clips(clips, cfg, workdir)
    if not segments:
        logger.error("no usable segments found")
        return 1

    _run_judge(clips, segments, cfg, workdir)
    _print_table(segments)
    return 0


def _cmd_cut(args: argparse.Namespace, cfg: Cfg) -> int:
    folder = Path(args.folder)
    if not folder.is_dir():
        logger.error("not a folder: %s", folder)
        return 1
    song = Path(args.song)
    if not song.is_file():
        logger.error("song not found: %s", song)
        return 1
    song = song.resolve()
    workdir = config.workdir_for(folder, cfg)

    clips = _cached_clips(workdir, args.fresh)
    clips_cached = clips is not None
    if clips is None:
        clips = ingest.scan(folder, cfg, workdir)
    if not clips:
        logger.error("no clips found in %s", folder)
        return 1

    music = _cached_music(workdir, song, args.fresh)
    if music is None:
        music = audio.analyze(song, cfg, workdir / "music.json")

    segments = _cached_segments(workdir) if clips_cached else None
    if segments is None:
        segments = analyze.analyze_clips(clips, cfg, workdir)
    if not segments:
        logger.error("no usable segments found")
        return 1

    if args.no_judge:
        logger.info("--no-judge: skipping AI judge")
    else:
        _run_judge(clips, segments, cfg, workdir)

    _blend_taste(segments, clips, cfg, workdir)

    edl = assemble.build_edl(segments, clips, music, cfg, workdir)
    out = Path(args.out) if args.out else workdir / "renders" / "reel_v1.mp4"
    out.parent.mkdir(parents=True, exist_ok=True)
    render_path = Path(assemble.render(edl, clips, cfg, out))

    fcpxml_path: Path | None = None
    if cfg["assemble.export.fcpxml"]:
        fcpxml_path = Path(assemble.export_fcpxml(edl, clips, cfg,
                                                  render_path.with_suffix(".fcpxml")))
    if str(cfg["assemble.export.resolve_api"]).strip().lower() != "never":
        assemble.export_resolve(edl, clips, cfg)

    print()
    print("Cut complete.")
    print("  duration : {:.2f}s ({} cut(s))".format(edl.duration, len(edl.events)))
    print("  render   : {}".format(render_path))
    print("  fcpxml   : {}".format(fcpxml_path if fcpxml_path else "(disabled)"))
    return 0


def _highest(paths: list[Path], pattern: re.Pattern[str]) -> Path | None:
    matched = [(int(m.group(1)), p) for p in paths if (m := pattern.match(p.name))]
    return max(matched)[1] if matched else None


def _cmd_review(args: argparse.Namespace, cfg: Cfg) -> int:
    folder = Path(args.folder)
    if not folder.is_dir():
        logger.error("not a folder: %s", folder)
        return 1
    workdir = config.workdir_for(folder, cfg)

    # Prefer the latest reviewed EDL so a second pass continues from it
    # (edl_v<n>.json pairs with renders/reel_v<n>.mp4; edl.json is v1).
    edl_path: Path | None = _highest(sorted(workdir.glob("edl_v*.json")), _EDL_V_RE)
    if edl_path is None and (workdir / "edl.json").is_file():
        edl_path = workdir / "edl.json"
    if edl_path is None:
        logger.error("no EDL in %s; run `vanscut cut` first", workdir)
        return 1

    missing = [p.name for p in (workdir / "clips.json", workdir / "segments.json",
                                workdir / "music.json") if not p.is_file()]
    if missing:
        logger.error("missing %s in %s; run `vanscut cut` first", ", ".join(missing), workdir)
        return 1

    renders_dir = workdir / "renders"
    render_path = (_highest(sorted(renders_dir.glob("reel_v*.mp4")), _REEL_RE)
                   if renders_dir.is_dir() else None)
    if render_path is None:
        logger.error("no render in %s; run `vanscut cut` first", renders_dir)
        return 1

    edl = load_edl(edl_path)
    clips = load_clips(workdir / "clips.json")
    segments = load_segments(workdir / "segments.json")
    music = load_music(workdir / "music.json")

    outputs = review.review_loop(render_path, edl, segments, clips, music, cfg, workdir)
    print("Review outputs:")
    for p in outputs:
        print("  {}".format(p))
    return 0


def _cmd_feedback(args: argparse.Namespace, cfg: Cfg) -> int:
    folder = Path(args.folder)
    if not folder.is_dir():
        logger.error("not a folder: %s", folder)
        return 1
    workdir = config.workdir_for(folder, cfg)

    missing = [p.name for p in (workdir / "edl.json", workdir / "segments.json",
                                workdir / "clips.json") if not p.is_file()]
    if missing:
        logger.error("missing %s in %s; run `vanscut cut` first", ", ".join(missing), workdir)
        return 1

    edl = load_edl(workdir / "edl.json")
    segments = load_segments(workdir / "segments.json")
    clips = load_clips(workdir / "clips.json")
    clip_by_id = {c.id: c for c in clips}
    if not edl.events:
        logger.error("EDL has no events; nothing to rate")
        return 1

    decisions: dict[int, bool] = {}
    print("Rate each cut - [k]eep / [r]eject / [s]kip / [q]uit")
    try:
        for ev in edl.events:
            clip = clip_by_id.get(ev.clip_id)
            name = Path(clip.path).name if clip else ev.clip_id
            print()
            print("[{}] {}  {:.2f}-{:.2f}s  score {:.2f}  {}".format(
                ev.idx, name, ev.src_in, ev.src_out, ev.score, ev.rationale))
            while True:
                choice = input("[k]eep / [r]eject / [s]kip / [q]uit: ").strip().lower()[:1]
                if choice in ("k", "r", "s", "q"):
                    break
            if choice == "q":
                break
            if choice == "k":
                decisions[ev.idx] = True
            elif choice == "r":
                decisions[ev.idx] = False
    except (KeyboardInterrupt, EOFError):
        print()
        logger.info("input closed; keeping the decisions collected so far")

    store = taste.TasteStore(cfg, workdir)
    total = store.log_feedback(edl, decisions, segments)
    print("Logged {} decision(s); {} feedback example(s) on disk.".format(len(decisions), total))

    if total >= int(cfg["taste.min_examples"]):
        try:
            answer = input("train now? [y/N]: ").strip().lower()
        except (KeyboardInterrupt, EOFError):
            answer = ""
        if answer.startswith("y"):
            try:
                embedded = store.embed_pending()
                logger.info("embedded %d new example(s)", embedded)
                metrics = store.train()
                print("Taste model trained: {}".format(metrics))
            except RuntimeError as exc:
                print(str(exc))
    return 0


if __name__ == "__main__":
    sys.exit(main())
