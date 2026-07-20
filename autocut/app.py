"""AUTOCUT web app - a thin Streamlit view over the autocut modules.

Run with `streamlit run app.py` (or double-click AUTOCUT-WEB.bat on Windows).

Three pages:
  New Cut  - pick footage + song, watch per-stage progress, preview/download
             the reel and inspect the EDL.
  Review   - thumbnail grid of scored segments; keep/reject feedback flows
             through taste.TasteStore and trains the ranker at 30+ examples.
  Settings - edit style presets (saved via config.save_style_overrides) and
             track estimated judge API spend (judge.cache_stats).

ALL business logic lives in the autocut package - this file only renders
widgets, persists uploads to disk, and calls the public module APIs.
"""

from __future__ import annotations

import logging
import re
import shutil
from pathlib import Path
from typing import Any

import streamlit as st

from autocut import cli, config, judge, models, taste
from autocut.config import Cfg

APP_DIR = Path(__file__).resolve().parent
PAGES = ("New Cut", "Review", "Settings")
DECISION_OPTIONS = ("skip", "keep", "reject")
JUDGE_MODELS = ["claude-sonnet-4-6", "claude-opus-4-8", "claude-fable-5"]
LOG_TAIL = 40          # log lines kept visible in the progress panel
GRID_COLS = 4          # Review thumbnail grid width

logger = logging.getLogger("autocut.app")


# ---------------------------------------------------------------------------
# helpers (view-side only: session plumbing, path math, log capture)

def _sanitize_name(name: str) -> str:
    return re.sub(r"[^A-Za-z0-9_-]", "", name.strip().replace(" ", "_")) or "shoot"


def _workdir_of(project_folder: str, cfg: Cfg) -> Path:
    """Workdir path for a project folder WITHOUT creating anything."""
    return Path(project_folder) / str(cfg["workdir_name"])


def _project_ready(project_folder: str, cfg: Cfg) -> bool:
    if not project_folder or not Path(project_folder).is_dir():
        return False
    wd = _workdir_of(project_folder, cfg)
    return (wd / "segments.json").is_file() and (wd / "clips.json").is_file()


class _ListLogHandler(logging.Handler):
    """Collects autocut.* log lines for display in the page."""

    def __init__(self, sink: list[str]):
        super().__init__()
        self.sink = sink
        self.setFormatter(logging.Formatter("%(name)s: %(message)s"))

    def emit(self, record: logging.LogRecord) -> None:
        try:
            self.sink.append(self.format(record))
        except Exception:
            pass


# ---------------------------------------------------------------------------
# sidebar

def _sidebar() -> tuple[str, Cfg]:
    st.sidebar.title("AUTOCUT")
    page = st.sidebar.radio("Page", PAGES, key="page")

    st.sidebar.text_input(
        "Project folder", key="project_folder",
        help="The folder containing your source clips (outputs land in its _autocut subfolder).",
    )

    presets = config.list_style_presets(APP_DIR)
    if presets:
        preset = st.sidebar.selectbox(
            "Style preset",
            [str(p) for p in presets],
            key="style_preset",
            format_func=lambda p: Path(p).stem,
        )
        cfg = config.load_style(preset)
    else:
        cfg = config.load_style(None)

    ffmpeg_ok = shutil.which(str(cfg["tools.ffmpeg"])) is not None
    judge_ok = judge.available(cfg)
    st.sidebar.caption(
        ("ffmpeg found" if ffmpeg_ok else "ffmpeg NOT found - winget install Gyan.FFmpeg")
        + " · "
        + ("AI judge ready" if judge_ok else "no API key - heuristic scoring")
    )
    return page, cfg


# ---------------------------------------------------------------------------
# page: New Cut

def _save_uploads(cfg: Cfg) -> None:
    clips = st.session_state.get("clips_upload") or []
    song = st.session_state.get("song_upload")
    name = _sanitize_name(st.session_state.get("upload_name", "") or "shoot1")
    if not clips:
        st.error("Drop at least one clip first.")
        return
    project = APP_DIR / "projects" / name
    clips_dir = project / "clips"
    clips_dir.mkdir(parents=True, exist_ok=True)
    for up in clips:
        (clips_dir / Path(up.name).name).write_bytes(up.getbuffer())
    if song is not None:
        song_path = project / Path(song.name).name
        song_path.write_bytes(song.getbuffer())
        st.session_state["song_path"] = str(song_path)
    st.session_state["project_folder"] = str(clips_dir)
    st.success(f"Saved {len(clips)} clip(s) to {clips_dir}")
    st.rerun()


def _run_pipeline(cfg: Cfg) -> None:
    folder = Path(st.session_state["project_folder"])
    song = Path(st.session_state["song_path"])
    if not folder.is_dir():
        st.error(f"Not a folder: {folder or '(empty)'} - set the project folder in the sidebar.")
        return
    if not song.is_file():
        st.error(f"Song not found: {song or '(empty)'}")
        return

    data = cfg.raw()
    data["assemble"]["target_duration_s"] = float(st.session_state["duration_s"])
    run_cfg = Cfg(data, source=cfg.source)

    stage_cols = st.columns(len(cli.CUT_STAGES))
    stage_slots = {name: col.empty() for name, col in zip(cli.CUT_STAGES, stage_cols)}
    log_slot = st.empty()
    log_lines: list[str] = []

    def paint(active: str | None) -> None:
        reached = active in cli.CUT_STAGES
        for name in cli.CUT_STAGES:
            if active == "done" or (reached and cli.CUT_STAGES.index(name) < cli.CUT_STAGES.index(active)):
                stage_slots[name].markdown(f"✅ {name}")
            elif name == active:
                stage_slots[name].markdown(f"⏳ **{name}**")
            else:
                stage_slots[name].markdown(f"· {name}")
        log_slot.code("\n".join(log_lines[-LOG_TAIL:]) or "starting...", language=None)

    handler = _ListLogHandler(log_lines)
    root_logger = logging.getLogger("autocut")
    root_logger.addHandler(handler)
    paint(None)
    try:
        result = cli.run_cut(
            folder, song, run_cfg,
            use_judge=bool(st.session_state["use_judge"]),
            fresh=bool(st.session_state["fresh"]),
            on_stage=paint,
        )
    except Exception as exc:
        paint(None)
        st.error(f"Cut failed: {exc}")
        with st.expander("Full log"):
            st.code("\n".join(log_lines) or "(no log output)", language=None)
        return
    finally:
        root_logger.removeHandler(handler)

    paint("done")
    st.session_state["last_result"] = {
        "render_path": str(result["render_path"]),
        "fcpxml_path": str(result["fcpxml_path"]) if result["fcpxml_path"] else None,
        "duration": float(result["duration"]),
        "events": int(result["events"]),
        "workdir": str(result["workdir"]),
    }


def _show_result() -> None:
    result = st.session_state.get("last_result")
    if not result:
        return
    render = Path(result["render_path"])
    if not render.is_file():
        st.info("Previous render is gone from disk - make a new cut.")
        return

    st.success(f"Reel ready: {result['duration']:.1f}s, {result['events']} cuts")
    st.video(str(render))

    dl_cols = st.columns(3)
    dl_cols[0].download_button(
        "Download reel", data=render.read_bytes(), file_name=render.name, mime="video/mp4"
    )
    fcpxml = Path(result["fcpxml_path"]) if result.get("fcpxml_path") else None
    if fcpxml and fcpxml.is_file():
        dl_cols[1].download_button(
            "Download FCPXML (Resolve)", data=fcpxml.read_bytes(),
            file_name=fcpxml.name, mime="application/xml",
        )

    edl_path = Path(result["workdir"]) / "edl.json"
    if edl_path.is_file():
        with st.expander("Open EDL"):
            edl = models.load_edl(edl_path)
            st.dataframe(
                [
                    {
                        "idx": e.idx, "clip": e.clip_id,
                        "src_in": round(e.src_in, 2), "src_out": round(e.src_out, 2),
                        "rec_in": round(e.rec_in, 2), "rec_out": round(e.rec_out, 2),
                        "type": e.shot_type, "hero": e.is_hero,
                        "score": round(e.score, 3), "rationale": e.rationale,
                    }
                    for e in edl.events
                ],
                width="stretch",
            )
            st.json(edl.to_dict(), expanded=False)


def _page_new_cut(cfg: Cfg) -> None:
    st.header("New Cut")

    with st.expander("Add footage (drag & drop)", expanded=not st.session_state["project_folder"]):
        st.file_uploader(
            "Clips", key="clips_upload", accept_multiple_files=True,
            type=["mp4", "mov", "m4v", "mxf"],
        )
        st.file_uploader(
            "Music track", key="song_upload",
            type=["mp3", "wav", "m4a", "aac", "flac"],
        )
        st.text_input("Project name", key="upload_name")
        if st.button("Save uploads as project", key="save_uploads_btn"):
            _save_uploads(cfg)
        st.caption(
            "Tip: for big 4K files it is faster to skip uploading and point the "
            "sidebar's project folder straight at the folder on your disk."
        )

    st.text_input("Song file", key="song_path", help="Path to the music track (mp3/wav/...)")
    opt_cols = st.columns(3)
    opt_cols[0].number_input(
        "Length (seconds)", key="duration_s", min_value=5, max_value=90,
    )
    opt_cols[1].checkbox("Use AI judge", key="use_judge")
    opt_cols[2].checkbox("Re-scan from scratch", key="fresh")

    if st.button("Cut", key="cut_btn", type="primary"):
        _run_pipeline(cfg)

    _show_result()


# ---------------------------------------------------------------------------
# page: Review

def _page_review(cfg: Cfg) -> None:
    st.header("Review segments")
    project = st.session_state["project_folder"]
    if not _project_ready(project, cfg):
        st.info("No analyzed footage yet - run a cut (or `vanscut analyze`) on a project folder first.")
        return

    workdir = _workdir_of(project, cfg)
    segments = models.load_segments(workdir / "segments.json")
    clips = models.load_clips(workdir / "clips.json")
    store = taste.TasteStore(cfg, workdir)
    prior = store.decisions()
    min_examples = int(cfg["taste.min_examples"])
    count = store.example_count()

    head = st.columns([1, 1, 2])
    head[0].metric(
        "Logged examples", count,
        help=f"The taste ranker activates at {min_examples} examples.",
    )
    if head[1].button(
        "Train ranker", key="train_btn", disabled=count < min_examples,
        help=f"Needs {min_examples}+ logged examples.",
    ):
        try:
            embedded = store.embed_pending()
            metrics = store.train()
        except RuntimeError as exc:
            st.error(str(exc))
        else:
            st.success(f"Trained on {metrics.get('n', '?')} examples "
                       f"(train acc {metrics.get('acc', 0):.2f}; {embedded} newly embedded)")
    if store.ready:
        head[2].caption("Ranker is trained - its scores blend into future cuts "
                        f"(weight {float(cfg['taste.weight']):.2f}).")

    with st.form(key="review_form"):
        ordered = sorted(segments, key=lambda s: float(s.final), reverse=True)
        for row_start in range(0, len(ordered), GRID_COLS):
            cols = st.columns(GRID_COLS)
            for col, ss in zip(cols, ordered[row_start:row_start + GRID_COLS]):
                seg = ss.segment
                with col:
                    frames = taste.frames_for_segment(clips, seg)
                    mid = frames[len(frames) // 2] if frames else None
                    if mid and Path(mid).is_file():
                        st.image(mid, width="stretch")
                    else:
                        st.caption("no frame")
                    st.caption(f"**{seg.id}** · {seg.clip_id} {seg.start:.1f}-{seg.end:.1f}s")
                    j = ss.judge
                    st.caption(
                        f"heur {ss.heuristic.score:.2f} | judge "
                        f"{j.score:.2f}" if j else
                        f"heur {ss.heuristic.score:.2f} | judge -"
                    )
                    st.caption(f"final {ss.final:.2f}" + (f" · {j.shot_type}" if j else ""))
                    if j and j.rationale:
                        st.caption(j.rationale)
                    default = 0
                    if seg.id in prior:
                        default = 1 if prior[seg.id] else 2
                    st.radio(
                        "decision", DECISION_OPTIONS, index=default,
                        key=f"decision_{seg.id}", horizontal=True,
                        label_visibility="collapsed",
                    )
        submitted = st.form_submit_button("Log decisions")

    if submitted:
        decisions = {}
        for ss in segments:
            choice = st.session_state.get(f"decision_{ss.segment.id}")
            if choice == "keep":
                decisions[ss.segment.id] = True
            elif choice == "reject":
                decisions[ss.segment.id] = False
        if not decisions:
            st.info("Nothing to log - set some segments to keep or reject first.")
        else:
            total = store.log_segment_feedback(decisions, segments, clips)
            st.success(f"Logged {len(decisions)} decision(s) - {total} examples on disk.")
            st.rerun()


# ---------------------------------------------------------------------------
# page: Settings

def _page_settings(cfg: Cfg) -> None:
    st.header("Settings")
    preset = st.session_state.get("style_preset", "")
    preset_path = Path(preset) if preset else None
    in_styles = preset_path is not None and preset_path.parent.name == "styles"
    st.caption(
        f"Editing values from preset **{preset_path.stem if preset_path else 'defaults'}**. "
        "Saving writes a preset file under styles/ (the commented style.yaml is never overwritten)."
    )

    models_list = list(JUDGE_MODELS)
    current_model = str(cfg["judge.model"])
    if current_model not in models_list:
        models_list.insert(0, current_model)
    enabled_options = ["auto", "always", "never"]
    current_enabled = str(cfg["judge.enabled"]).strip().lower()
    if current_enabled not in enabled_options:
        current_enabled = "auto"

    with st.form(key="settings_form"):
        st.subheader("AI judge")
        j1, j2, j3 = st.columns(3)
        j1.selectbox("Model", models_list,
                     index=models_list.index(current_model), key="set_model")
        j2.slider("Judge weight", 0.0, 1.0, float(cfg["judge.weight"]), key="set_judge_weight")
        j3.selectbox("Enabled", enabled_options,
                     index=enabled_options.index(current_enabled), key="set_judge_enabled")
        st.text_area("Style brief (what the judge optimizes for)",
                     value=str(cfg["judge.style_brief"]), height=220, key="set_brief")

        st.subheader("Look & pacing")
        st.text_input("LUT path (.cube, optional)",
                      value=str(cfg["assemble.render.lut"] or ""), key="set_lut")
        p1, p2, p3 = st.columns(3)
        p1.number_input("Target duration (s)", min_value=5.0, max_value=90.0,
                        value=float(cfg["assemble.target_duration_s"]), key="set_duration")
        p2.number_input("Min shot (s)", min_value=0.1, max_value=10.0,
                        value=float(cfg["assemble.cut.min_shot_s"]), key="set_min_shot")
        p3.number_input("Max shot (s)", min_value=0.5, max_value=15.0,
                        value=float(cfg["assemble.cut.max_shot_s"]), key="set_max_shot")
        b1, b2, b3, b4 = st.columns(4)
        b1.number_input("Slow beats/shot", min_value=1, max_value=16,
                        value=int(cfg["assemble.cut.slow_beats"]), key="set_slow_beats")
        b2.number_input("Fast beats/shot", min_value=1, max_value=16,
                        value=int(cfg["assemble.cut.fast_beats"]), key="set_fast_beats")
        b3.slider("Energy low", 0.0, 1.0, float(cfg["assemble.cut.energy_lo"]), key="set_energy_lo")
        b4.slider("Energy high", 0.0, 1.0, float(cfg["assemble.cut.energy_hi"]), key="set_energy_hi")

        st.text_input(
            "Save as preset",
            value=(preset_path.stem if (preset_path and in_styles) else "custom"),
            key="save_as_name",
        )
        saved = st.form_submit_button("Save preset")

    if saved:
        target = APP_DIR / "styles" / f"{_sanitize_name(st.session_state['save_as_name'])}.yaml"
        lut = st.session_state["set_lut"].strip()
        updates: dict[str, Any] = {
            "judge.model": st.session_state["set_model"],
            "judge.weight": float(st.session_state["set_judge_weight"]),
            "judge.enabled": st.session_state["set_judge_enabled"],
            "judge.style_brief": st.session_state["set_brief"],
            "assemble.render.lut": lut or None,
            "assemble.target_duration_s": float(st.session_state["set_duration"]),
            "assemble.cut.min_shot_s": float(st.session_state["set_min_shot"]),
            "assemble.cut.max_shot_s": float(st.session_state["set_max_shot"]),
            "assemble.cut.slow_beats": int(st.session_state["set_slow_beats"]),
            "assemble.cut.fast_beats": int(st.session_state["set_fast_beats"]),
            "assemble.cut.energy_lo": float(st.session_state["set_energy_lo"]),
            "assemble.cut.energy_hi": float(st.session_state["set_energy_hi"]),
        }
        config.save_style_overrides(target, updates)
        st.success(f"Saved {target.name} - pick it in the sidebar's style preset dropdown.")

    st.divider()
    st.subheader("API cost tracker")
    project = st.session_state["project_folder"]
    if not project or not Path(project).is_dir():
        st.info("Set a project folder in the sidebar to see its judge spend.")
        return
    stats = judge.cache_stats(cfg, _workdir_of(project, cfg))
    m = st.columns(4)
    m[0].metric("Cached segments", stats["cached_segments"],
                help="Scored results reused for free on re-runs.")
    m[1].metric("API calls", stats["api_calls"])
    m[2].metric("Segments scored", stats["segments_scored"])
    m[3].metric("Est. cost (USD)", f"${stats['est_cost_usd']:.2f}")
    st.caption(
        f"Tokens - in: {stats['input_tokens']:,} · out: {stats['output_tokens']:,} · "
        f"cache read: {stats['cache_read_input_tokens']:,} · "
        f"cache write: {stats['cache_creation_input_tokens']:,}. "
        "Estimated from public per-MTok prices; cache hits cost $0."
    )
    if stats["unknown_models"]:
        st.caption("Excluded from the estimate (unknown pricing): "
                   + ", ".join(stats["unknown_models"]))


# ---------------------------------------------------------------------------

def main() -> None:
    st.set_page_config(page_title="AUTOCUT", layout="wide")
    st.session_state.setdefault("project_folder", "")
    st.session_state.setdefault("song_path", "")
    st.session_state.setdefault("upload_name", "shoot1")

    page, cfg = _sidebar()

    st.session_state.setdefault("duration_s", int(float(cfg["assemble.target_duration_s"])))
    st.session_state.setdefault("use_judge", judge.available(cfg))
    st.session_state.setdefault("fresh", False)

    if page == "New Cut":
        _page_new_cut(cfg)
    elif page == "Review":
        _page_review(cfg)
    else:
        _page_settings(cfg)


main()
