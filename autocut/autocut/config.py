"""Configuration loading for AUTOCUT.

All tunables live in style.yaml. This module loads the user's style file,
deep-merges it over the packaged defaults (default_style.yaml), and exposes
dotted-path access so call sites read like: cfg["assemble.cut.min_shot_s"].
"""

from __future__ import annotations

import copy
from importlib import resources
from pathlib import Path
from typing import Any

import yaml

_MISSING = object()


class Cfg:
    """Read-only view over the merged config dict with dotted-path access."""

    def __init__(self, data: dict[str, Any], source: Path | None = None):
        self._data = data
        self.source = source  # path of the user style file, if any

    def __getitem__(self, dotted: str) -> Any:
        value = self.get(dotted, _MISSING)
        if value is _MISSING:
            raise KeyError(f"Missing config key: {dotted!r} (check style.yaml)")
        return value

    def get(self, dotted: str, default: Any = None) -> Any:
        node: Any = self._data
        for part in dotted.split("."):
            if not isinstance(node, dict) or part not in node:
                return default
            node = node[part]
        return node

    def section(self, dotted: str) -> dict[str, Any]:
        value = self[dotted]
        if not isinstance(value, dict):
            raise KeyError(f"Config key {dotted!r} is not a section")
        return value

    def raw(self) -> dict[str, Any]:
        return copy.deepcopy(self._data)


def _deep_merge(base: dict, override: dict) -> dict:
    out = dict(base)
    for key, value in override.items():
        if key in out and isinstance(out[key], dict) and isinstance(value, dict):
            out[key] = _deep_merge(out[key], value)
        else:
            out[key] = value
    return out


def _load_defaults() -> dict[str, Any]:
    # importlib.resources first; fall back to a __file__-relative path, which
    # also survives the package being shadowed by a same-named directory.
    try:
        ref = resources.files("autocut").joinpath("default_style.yaml")
        with ref.open("r", encoding="utf-8") as fh:
            return yaml.safe_load(fh) or {}
    except (FileNotFoundError, ModuleNotFoundError):
        local = Path(__file__).with_name("default_style.yaml")
        with open(local, "r", encoding="utf-8") as fh:
            return yaml.safe_load(fh) or {}


def load_style(path: str | Path | None = None) -> Cfg:
    """Load style config.

    Search order when *path* is None: ./style.yaml, else packaged defaults only.
    """
    defaults = _load_defaults()
    user_path: Path | None = None
    if path is not None:
        user_path = Path(path)
        if not user_path.is_file():
            raise FileNotFoundError(f"Style file not found: {user_path}")
    else:
        candidate = Path("style.yaml")
        if candidate.is_file():
            user_path = candidate

    merged = defaults
    if user_path is not None:
        with open(user_path, "r", encoding="utf-8") as fh:
            user = yaml.safe_load(fh) or {}
        if not isinstance(user, dict):
            raise ValueError(f"{user_path} must contain a YAML mapping")
        merged = _deep_merge(defaults, user)
    return Cfg(merged, source=user_path)


def workdir_for(input_folder: str | Path, cfg: Cfg) -> Path:
    """Return (and create) the working directory for an input folder."""
    folder = Path(input_folder)
    wd = folder / str(cfg["workdir_name"])
    wd.mkdir(parents=True, exist_ok=True)
    return wd


def list_style_presets(base_dir: str | Path) -> list[Path]:
    """Style preset files: <base>/style.yaml plus <base>/styles/*.yaml."""
    base = Path(base_dir)
    presets: list[Path] = []
    root = base / "style.yaml"
    if root.is_file():
        presets.append(root)
    styles = base / "styles"
    if styles.is_dir():
        presets.extend(sorted(p for p in styles.glob("*.yaml") if p.is_file()))
    return presets


def save_style_overrides(path: str | Path, updates: dict[str, Any]) -> Path:
    """Write dotted-key overrides into a user style file (created if missing).

    Only the named file changes - packaged defaults are never touched, and
    load_style() still deep-merges the file over them. Note: the file is
    rewritten with yaml.safe_dump, so hand-written comments in it are lost -
    prefer dedicated preset files (styles/*.yaml) over the commented root
    style.yaml as a save target.
    """
    path = Path(path)
    data: dict[str, Any] = {}
    if path.is_file():
        with open(path, "r", encoding="utf-8") as fh:
            loaded = yaml.safe_load(fh) or {}
        if not isinstance(loaded, dict):
            raise ValueError(f"{path} must contain a YAML mapping")
        data = loaded

    for dotted, value in updates.items():
        node = data
        parts = str(dotted).split(".")
        for part in parts[:-1]:
            nxt = node.get(part)
            if not isinstance(nxt, dict):
                nxt = {}
                node[part] = nxt
            node = nxt
        node[parts[-1]] = value

    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        yaml.safe_dump(data, fh, sort_keys=False, allow_unicode=True)
    return path
