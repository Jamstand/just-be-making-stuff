"""AUTOCUT desktop window - point-and-click front end over `run_cut`.

A deliberately small Tkinter GUI (Tkinter ships with the python.org installer,
no extra dependency): pick a clips folder, pick a song, choose a length, hit
"Make Reel". The pipeline runs on a background thread; log lines from the
autocut.* loggers stream into the window, and the finished reel opens itself.

Launch with `vanscut ui`, or double-click AUTOCUT.bat in the project folder.
"""

from __future__ import annotations

import logging
import os
import queue
import shutil
import subprocess
import sys
import threading
from pathlib import Path
from typing import Any

from . import config
from .config import Cfg

logger = logging.getLogger("autocut.gui")

_POLL_MS = 120


def _set_enabled(widget: Any, enabled: bool) -> None:
    """Enable/disable a ttk widget via state flags.

    ttk's `state` *option* and its state *flags* can desync, so
    `config(state="normal")` does not reliably re-enable a widget created
    disabled - the flag API does.
    """
    widget.state(["!disabled"] if enabled else ["disabled"])


class _QueueLogHandler(logging.Handler):
    """Funnels log records to the UI thread via a thread-safe queue."""

    def __init__(self, q: "queue.Queue[tuple[str, Any]]"):
        super().__init__()
        self._q = q

    def emit(self, record: logging.LogRecord) -> None:
        try:
            self._q.put(("log", self.format(record)))
        except Exception:  # never let logging crash the run
            pass


def _open_path(path: Path) -> None:
    """Open a file/folder in the OS default handler (best effort)."""
    try:
        if sys.platform.startswith("win") and hasattr(os, "startfile"):
            os.startfile(str(path))  # type: ignore[attr-defined]
        elif sys.platform == "darwin":
            subprocess.Popen(["open", str(path)])
        else:
            subprocess.Popen(["xdg-open", str(path)])
    except Exception as exc:
        logger.warning("could not open %s: %s", path, exc)


class AutocutApp:
    def __init__(self, root: Any, style_path: str | None):
        import tkinter as tk
        from tkinter import ttk

        self.tk = tk
        self.root = root
        self.style_path = style_path
        self.queue: "queue.Queue[tuple[str, Any]]" = queue.Queue()
        self.result: dict[str, Any] | None = None
        self._running = False

        root.title("AUTOCUT - car reel maker")
        root.geometry("760x560")
        root.minsize(640, 480)

        self.clips_var = tk.StringVar()
        self.song_var = tk.StringVar()
        self.duration_var = tk.IntVar(value=self._default_duration())
        self.judge_var = tk.BooleanVar(value=self._has_api_key())
        self.fresh_var = tk.BooleanVar(value=False)

        pad = {"padx": 8, "pady": 6}
        frm = ttk.Frame(root, padding=12)
        frm.pack(fill="both", expand=True)
        frm.columnconfigure(1, weight=1)

        ttk.Label(frm, text="Clips folder").grid(row=0, column=0, sticky="w", **pad)
        ttk.Entry(frm, textvariable=self.clips_var).grid(row=0, column=1, sticky="ew", **pad)
        ttk.Button(frm, text="Browse...", command=self._pick_clips).grid(row=0, column=2, **pad)

        ttk.Label(frm, text="Song").grid(row=1, column=0, sticky="w", **pad)
        ttk.Entry(frm, textvariable=self.song_var).grid(row=1, column=1, sticky="ew", **pad)
        ttk.Button(frm, text="Browse...", command=self._pick_song).grid(row=1, column=2, **pad)

        opts = ttk.Frame(frm)
        opts.grid(row=2, column=0, columnspan=3, sticky="w", **pad)
        ttk.Label(opts, text="Length (sec)").pack(side="left")
        tk.Spinbox(opts, from_=5, to=90, width=5, textvariable=self.duration_var).pack(side="left", padx=(4, 16))
        ttk.Checkbutton(opts, text="Use AI judge (needs API key)",
                        variable=self.judge_var).pack(side="left", padx=(0, 16))
        ttk.Checkbutton(opts, text="Re-scan from scratch",
                        variable=self.fresh_var).pack(side="left")

        self.make_btn = ttk.Button(frm, text="Make Reel", command=self._start)
        self.make_btn.grid(row=3, column=0, columnspan=3, sticky="ew", **pad)

        self.log = tk.Text(frm, height=16, wrap="word", state="disabled",
                           background="#111", foreground="#ddd", font=("Consolas", 9))
        self.log.grid(row=4, column=0, columnspan=3, sticky="nsew", **pad)
        frm.rowconfigure(4, weight=1)

        self.status = ttk.Label(frm, text=self._initial_status(), anchor="w")
        self.status.grid(row=5, column=0, columnspan=3, sticky="ew", **pad)

        actions = ttk.Frame(frm)
        actions.grid(row=6, column=0, columnspan=3, sticky="w", **pad)
        self.open_reel_btn = ttk.Button(actions, text="Open reel", state="disabled",
                                        command=self._open_reel)
        self.open_reel_btn.pack(side="left", padx=(0, 8))
        self.open_folder_btn = ttk.Button(actions, text="Open output folder", state="disabled",
                                          command=self._open_folder)
        self.open_folder_btn.pack(side="left")

        self.root.after(_POLL_MS, self._drain)

    # -- config helpers -----------------------------------------------------
    def _load_cfg(self) -> Cfg:
        return config.load_style(self.style_path)

    def _default_duration(self) -> int:
        try:
            return int(float(self._load_cfg()["assemble.target_duration_s"]))
        except Exception:
            return 30

    @staticmethod
    def _has_api_key() -> bool:
        return bool(os.environ.get("ANTHROPIC_API_KEY") or os.environ.get("ANTHROPIC_AUTH_TOKEN"))

    def _initial_status(self) -> str:
        cfg = self._load_cfg()
        ffmpeg = str(cfg["tools.ffmpeg"])
        ffprobe = str(cfg["tools.ffprobe"])
        missing = [t for t in (ffmpeg, ffprobe) if shutil.which(t) is None]
        if missing:
            return ("ffmpeg not found - install it (winget install Gyan.FFmpeg) "
                    "and reopen this window.")
        key = "AI judge available" if self._has_api_key() else "no API key - heuristic scoring"
        return f"Ready. ffmpeg found. {key}."

    # -- pickers ------------------------------------------------------------
    def _pick_clips(self) -> None:
        from tkinter import filedialog
        d = filedialog.askdirectory(title="Choose the folder with your clips")
        if d:
            self.clips_var.set(d)

    def _pick_song(self) -> None:
        from tkinter import filedialog
        f = filedialog.askopenfilename(
            title="Choose a music track",
            filetypes=[("Audio", "*.mp3 *.wav *.m4a *.aac *.flac"), ("All files", "*.*")],
        )
        if f:
            self.song_var.set(f)

    # -- run ----------------------------------------------------------------
    def _start(self) -> None:
        from tkinter import messagebox
        if self._running:
            return
        clips = self.clips_var.get().strip()
        song = self.song_var.get().strip()
        if not clips or not Path(clips).is_dir():
            messagebox.showerror("AUTOCUT", "Pick a valid clips folder first.")
            return
        if not song or not Path(song).is_file():
            messagebox.showerror("AUTOCUT", "Pick a valid song file first.")
            return

        cfg = self._load_cfg()
        if shutil.which(str(cfg["tools.ffmpeg"])) is None:
            messagebox.showerror(
                "AUTOCUT",
                "ffmpeg is not installed or not on PATH.\n\n"
                "Install it with:  winget install Gyan.FFmpeg\n"
                "then close and reopen this window.",
            )
            return

        data = cfg.raw()
        data["assemble"]["target_duration_s"] = float(self.duration_var.get())
        cfg = Cfg(data, source=cfg.source)

        self._running = True
        self.result = None
        _set_enabled(self.make_btn, False)
        self.make_btn.config(text="Working...")
        _set_enabled(self.open_reel_btn, False)
        _set_enabled(self.open_folder_btn, False)
        self.status.config(text="Working... this can take a while on 4K footage.")
        self._clear_log()

        t = threading.Thread(
            target=self._worker,
            args=(clips, song, cfg, self.judge_var.get(), self.fresh_var.get()),
            daemon=True,
        )
        t.start()

    def _worker(self, clips: str, song: str, cfg: Cfg, use_judge: bool, fresh: bool) -> None:
        from . import cli  # imported here to avoid a circular import at module load
        handler = _QueueLogHandler(self.queue)
        handler.setFormatter(logging.Formatter("%(name)s: %(message)s"))
        root_logger = logging.getLogger("autocut")
        root_logger.addHandler(handler)
        try:
            result = cli.run_cut(clips, song, cfg, use_judge=use_judge, fresh=fresh)
            self.queue.put(("done", result))
        except Exception as exc:  # surface any failure in the window
            logger.exception("cut failed")
            self.queue.put(("error", str(exc)))
        finally:
            root_logger.removeHandler(handler)

    # -- UI-thread queue drain ---------------------------------------------
    def _drain(self) -> None:
        try:
            while True:
                kind, payload = self.queue.get_nowait()
                if kind == "log":
                    self._append_log(str(payload))
                elif kind == "done":
                    self._on_done(payload)
                elif kind == "error":
                    self._on_error(str(payload))
        except queue.Empty:
            pass
        self.root.after(_POLL_MS, self._drain)

    def _on_done(self, result: dict[str, Any]) -> None:
        self.result = result
        self._running = False
        _set_enabled(self.make_btn, True)
        self.make_btn.config(text="Make Reel")
        _set_enabled(self.open_reel_btn, True)
        _set_enabled(self.open_folder_btn, True)
        self.status.config(
            text="Done: {:.1f}s reel, {} cuts -> {}".format(
                result["duration"], result["events"], Path(result["render_path"]).name)
        )
        self._append_log("\nDone. Opening the reel...")
        _open_path(Path(result["render_path"]))

    def _on_error(self, message: str) -> None:
        from tkinter import messagebox
        self._running = False
        _set_enabled(self.make_btn, True)
        self.make_btn.config(text="Make Reel")
        self.status.config(text="Failed: " + message)
        messagebox.showerror("AUTOCUT - it failed", message)

    def _open_reel(self) -> None:
        if self.result:
            _open_path(Path(self.result["render_path"]))

    def _open_folder(self) -> None:
        if self.result:
            _open_path(Path(self.result["render_path"]).parent)

    # -- log widget ---------------------------------------------------------
    def _clear_log(self) -> None:
        self.log.config(state="normal")
        self.log.delete("1.0", "end")
        self.log.config(state="disabled")

    def _append_log(self, line: str) -> None:
        self.log.config(state="normal")
        self.log.insert("end", line + "\n")
        self.log.see("end")
        self.log.config(state="disabled")


def launch(style_path: str | None = None) -> int:
    """Open the desktop window. Returns a process exit code."""
    try:
        import tkinter as tk
    except Exception:
        print(
            "The desktop UI needs Tkinter, which is missing from this Python.\n"
            "On Windows, reinstall Python from python.org (Tkinter is included).\n"
            "On Linux: sudo apt install python3-tk.\n"
            "Meanwhile you can still use the command line: vanscut cut <folder> <song>",
            file=sys.stderr,
        )
        return 2
    root = tk.Tk()
    AutocutApp(root, style_path)
    root.mainloop()
    return 0
