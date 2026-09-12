#!/usr/bin/env python3
"""Builds the JamPure Custom Shaders Patch presets from a base export.

The base file (base/Maiven_Ultra_highend_vans.ini) is the Content Manager export
of the "Ultra highend preset (Maiven)" CSP settings shared from acstuff.club/s/GSum.
Everything that is not a graphics-quality knob (NeckFX, chaser camera, gamepad
assist, physics experiments, audio, GUI tweaks, the Pure WeatherFX selection, the
DLSS/FSR upscaler choice) is carried over untouched. On top of that:

  * JamPure_CSP_Ultra    - every quality setting raised to the maximum its CSP
                           documentation allows (see ULTRA below and README).
  * JamPure_CSP_Balanced - the same base with the expensive knobs pulled back.

Run:  python3 build-csp-presets.py
"""
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
BASE = os.path.join(HERE, "base", "Maiven_Ultra_highend_vans.ini")

# (module, section) -> {key: value}; applied in order, later dicts win.
ULTRA = {
    # --- Graphics adjustments -------------------------------------------------
    ("GRAPHICS_ADJUSTMENTS", "LODS"): {
        "CARS_DISTANCE_MULT": "3.2", "TRACK_DISTANCE_MULT": "3.2", "TREES_DISTANCE_MULT": "3.2",
        "COCKPIT_LR_FIX": "0", "DRIVER_LR_FIX": "0", "FORCE_LOD_B": "0",
        "HIDE_DISTANT_DRIVERS": "0", "HIDE_WHEELS_FOR_INTERIOR_VIEW": "0",
        "SKIP_LOADING_FIRST_LOD_FOR_OTHER_CARS": "0", "FALLBACK_LODS": "0",
        "LODLESS_LIMIT": "200", "LIMIT_VISIBLE_CARS": "0",
    },
    ("GRAPHICS_ADJUSTMENTS", "ANTIALIASING"): {"QUALITY": "ULTRA", "FXAA3_GREEN_AS_LUMA": "0"},
    ("GRAPHICS_ADJUSTMENTS", "ANTIALIASING_MSAA"): {"CUSTOM_RESOLVE": "1", "CUSTOM_KERNEL": "1", "CUSTOM_RESOLVE_MIRROR": "1"},
    ("GRAPHICS_ADJUSTMENTS", "COLOR_BUFFER"): {"ACTIVE": "1", "FULL_RESOLUTION": "1"},
    # --- Extra FX -------------------------------------------------------------
    ("EXTRA_FX", "BASIC"): {"ENABLED": "1"},
    ("EXTRA_FX", "TAA"): {"ENABLED": "1"},
    ("EXTRA_FX", "SSLR"): {"ENABLED": "1", "SCALE": "1", "EXTRA_SPECULARS": "1"},
    ("EXTRA_FX", "VOLUMETRIC_LIGHTS"): {"ENABLED": "1", "SCALE": "0.32"},
    ("EXTRA_FX", "FOG_BLUR"): {"ENABLED": "1", "HEATING": "1"},
    ("EXTRA_FX", "SS_LIGHTING"): {"ENABLED": "1", "SCALE": "1", "EMISSIVE": "1"},
    ("EXTRA_FX", "LIGHT_BOUNCE"): {"ENABLED": "1", "CARS": "1"},
    # --- Lighting FX ----------------------------------------------------------
    ("LIGHTING_FX", "SHADOWS"): {
        "ENABLED": "1", "FULL_RESOLUTION": "1", "CARS_SHADOWS": "5", "SPECTATING_CARS_SHADOWS": "5",
        "DETAILED_SHADOWS_FROM_CARS_NEARBY": "4", "CARS_IN_TRACK_SHADOWS": "1",
        "HIGH_QUALITY_HEADLIGHT_SHADOWS": "1",
    },
    ("LIGHTING_FX", "PERFORMANCE"): {
        "CARS_WITH_LIGHTS": "50", "ENABLE_REARVIEWMIRROR_LIGHT": "2", "ENABLE_REFLECTION_LIGHT": "1",
        "ENABLE_TREES_LIGHTING": "1", "DISABLE_MIRRORING": "0", "DISABLE_MIRRORING_FIRSTPERSON": "0",
    },
    # --- Particles FX ---------------------------------------------------------
    ("PARTICLES_FX", "SMOKE"): {
        "QUANTITY_SCALE": "1.2", "USE_DOWNSCALING": "0", "SIMPLIFIED_SHADING": "0",
        "CAST_SHADOWS": "1", "CAST_AMBIENT_SHADOWS": "1", "SHOW_IN_MIRRORS": "1",
    },
    # --- Reflections FX -------------------------------------------------------
    ("REFLECTIONS_FX", "MAIN_CUBEMAP"): {
        "RESOLUTION2": "2048", "USE_64BPP_2": "1", "PREFILTER_CUBEMAP": "1",
        "USE_PROPER_IBL": "1", "USE_INTERIOR_MASK": "1", "REPROJECT_PARTIAL": "1",
    },
    # --- Smart Mirror ---------------------------------------------------------
    ("SMART_MIRROR", "REAL_MIRRORS"): {"ENABLED": "1", "RENDER_PER_FRAME": "0"},
    ("SMART_MIRROR", "CUSTOM_RENDER_DISTANCE"): {"ENABLED": "1", "DISTANCE": "2400"},
    ("SMART_MIRROR", "PERFORMANCE"): {"COMPACT_FORMAT": "0", "SKIP_FRAMES": "0"},
    # --- Smart Shadows (base export leaves all of it at defaults) ------------
    ("SMART_SHADOWS", "BASIC"): {
        "ENABLED": "1", "ANISOTROPY": "1", "OPACITY2": "1", "AUTOMATIC_SPLITS": "1",
        "AUTOMATIC_SPLITS_DISTANCE": "400", "AUTOMATIC_SPLITS_GROUND_DISTANCE": "1",
        "AUTOMATIC_SPLITS_SHARP_INTERIOR": "1",
    },
    ("SMART_SHADOWS", "SMOOTH_CASCADES"): {"ENABLED": "1", "OVERHANG_MULT": "1"},
    ("SMART_SHADOWS", "CUSTOM_SHADOW_MATRICES"): {"ENABLED": "1", "FOURTH_CASCADE": "1", "FOURTH_CASCADE_DISTANCE": "2000"},
    ("SMART_SHADOWS", "LAZIER_UPDATE"): {"LAZIER_UPDATE_INTERIOR": "0", "LAZIER_UPDATE_EXTERIOR": "0"},
    ("SMART_SHADOWS", "NO_CAR_SHADOWS_IN_THIRD_CASCADE"): {"INTERIOR_VIEW": "0", "EXTERIOR_VIEW": "0"},
    # --- Weather FX (Pure selection in [BASIC] is left exactly as exported) ---
    ("WEATHER_FX", "PERFORMANCE"): {
        "DETAILED_CLOUD_SHADOWS": "1", "HIGH_QUALITY_STARS": "1", "EXTRA_CLOUDS_FIDELITY": "1",
        "ADDITIONAL_EFFECTS": "1", "SLOW_REFLECTIONS_UPDATE": "0",
    },
    ("WEATHER_FX", "PP_TWEAKS"): {"FULL_RESOLUTION": "1"},
    ("WEATHER_FX", "STATIC_REFLECTIONS"): {"INCLUDE_EMISSIVES": "1", "OCCASIONALLY_REFRESH": "1"},
    # --- Grass / rain / track / skidmarks ------------------------------------
    ("GRASS_FX", "BASIC"): {"ENABLED": "1", "QUALITY": "4"},
    ("GRASS_FX", "RENDERING"): {"CAST_SHADOWS": "1", "SMOOTHER_BLENDING": "1", "EXTRAFX_PASS": "1"},
    ("RAIN_FX", "VISUAL_TWEAKS"): {"RAIN_MAPS_QUALITY": "0"},
    ("TRACK_ADJUSTMENTS", "MISCELLANEOUS"): {"TREES_RECEIVE_SHADOWS": "1", "SNAP_TYRE_GROOVES_TO_SURFACE": "1"},
    ("SKIDMARKS_FX", "NEW_IMPLEMENTATION"): {"ENABLED": "1", "LIMIT": "800", "ADVANCED_BLENDING": "1"},
    # --- General: CSP's "limit things when there are many cars" switches -----
    ("GENERAL", "OPTIMIZATIONS_CPU"): {"LIMIT_GENERAL": "0", "LIMIT_SHADOWS": "0", "LIMIT_SMOKE": "0"},
    # --- Screenshots ----------------------------------------------------------
    ("NICE_SCREENSHOTS", "WINDOWS_IMAGING_COMPONENT"): {"USE": "1", "QUALITY": "100"},
}

BALANCED = {
    ("GRAPHICS_ADJUSTMENTS", "FSR"): {"QUALITY_DLSS": "0.67"},
    ("GRAPHICS_ADJUSTMENTS", "LODS"): {
        "CARS_DISTANCE_MULT": "1.5", "TRACK_DISTANCE_MULT": "1.5", "TREES_DISTANCE_MULT": "1.5",
        "COCKPIT_LR_FIX": "1", "LODLESS_LIMIT": "40", "LIMIT_VISIBLE_CARS": "1",
    },
    ("GRAPHICS_ADJUSTMENTS", "ANTIALIASING"): {"QUALITY": "HIGH"},
    ("GRAPHICS_ADJUSTMENTS", "ANTIALIASING_MSAA"): {"CUSTOM_KERNEL": "0"},
    ("EXTRA_FX", "SSLR"): {"TRACING_QUALITY3": "3", "STEPS_SIMPLE": "48", "STEPS_HIZ": "120"},
    ("EXTRA_FX", "MOTION_BLUR"): {"QUALITY_2": "1"},
    ("EXTRA_FX", "VOLUMETRIC_LIGHTS"): {"SCALE": "0.2"},
    ("LIGHTING_FX", "SHADOWS"): {
        "CARS_SHADOWS": "2", "SPECTATING_CARS_SHADOWS": "3",
        "DETAILED_SHADOWS_FROM_CARS_NEARBY": "1", "HIGH_QUALITY_HEADLIGHT_SHADOWS": "0",
    },
    ("LIGHTING_FX", "PERFORMANCE"): {"CARS_WITH_LIGHTS": "10", "ENABLE_REARVIEWMIRROR_LIGHT": "1"},
    ("PARTICLES_FX", "SMOKE"): {"QUANTITY_SCALE": "1"},
    ("REFLECTIONS_FX", "MAIN_CUBEMAP"): {"RESOLUTION2": "1024", "USE_64BPP_2": "0"},
    ("SMART_MIRROR", "REAL_MIRRORS"): {"RENDER_PER_FRAME": "2"},
    ("SMART_MIRROR", "CUSTOM_RENDER_DISTANCE"): {"ENABLED": "0"},
    ("SMART_MIRROR", "PERFORMANCE"): {"COMPACT_FORMAT": "1"},
    ("SMART_SHADOWS", "BASIC"): {"ANISOTROPY": "0", "AUTOMATIC_SPLITS_DISTANCE": "200"},
    ("SMART_SHADOWS", "CUSTOM_SHADOW_MATRICES"): {"FOURTH_CASCADE_DISTANCE": "1500"},
    ("SMART_SHADOWS", "LAZIER_UPDATE"): {"LAZIER_UPDATE_INTERIOR": "1", "LAZIER_UPDATE_EXTERIOR": "1"},
    ("WEATHER_FX", "PERFORMANCE"): {"DETAILED_CLOUD_SHADOWS": "0"},
    ("WEATHER_FX", "PP_TWEAKS"): {"FULL_RESOLUTION": "0"},
    ("GRASS_FX", "BASIC"): {"QUALITY": "2"},
    ("GRASS_FX", "RENDERING"): {"CAST_SHADOWS": "0", "EXTRAFX_PASS": "0"},
    ("RAIN_FX", "VISUAL_TWEAKS"): {"RAIN_MAPS_QUALITY": "1"},
    ("GENERAL", "OPTIMIZATIONS_CPU"): {"LIMIT_GENERAL": "1", "LIMIT_SHADOWS": "1", "LIMIT_SMOKE": "3"},
}


def parse(path):
    """Returns (ordered list of (module, section)), {(module, section): [(key, value), ...]}."""
    order, data, cur = [], {}, None
    for raw in open(path, encoding="utf-8"):
        line = raw.rstrip("\r\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        m = re.match(r"^\[([A-Z0-9_]+):(.+)\]$", line)
        if m:
            cur = (m.group(1), m.group(2))
            if cur not in data:
                order.append(cur)
                data[cur] = []
            continue
        if line.startswith("[CONFIGURATION]"):
            cur = None
            continue
        m = re.match(r"^([A-Za-z0-9_]+)=(.*)$", line)
        if m and cur is not None:
            data[cur].append((m.group(1), m.group(2)))
    return order, data


def clean(order, data):
    """Drop Content Manager UI metadata that has no business in a preset."""
    out_order, out = [], {}
    for key in order:
        module, section = key
        if section == "ℹ" or section.startswith("__"):
            continue
        keep = [(k, v) for k, v in data[key] if not k.startswith("__")]
        if not keep:
            continue
        out_order.append(key)
        out[key] = keep
    return out_order, out


def apply(order, data, overrides):
    order, data = list(order), {k: list(v) for k, v in data.items()}
    for key, kv in overrides.items():
        if key not in data:
            order.append(key)
            data[key] = []
        existing = {k: i for i, (k, _) in enumerate(data[key])}
        for k, v in kv.items():
            if k in existing:
                data[key][existing[k]] = (k, v)
            else:
                data[key].append((k, v))
                existing[k] = len(data[key]) - 1
    return order, data


def render(order, data):
    modules = []
    for module, _ in order:
        if module not in modules:
            modules.append(module)
    lines = ["[CONFIGURATION]", "VERSION=1", "AFFECTED_SECTIONS=" + ",".join(modules), ""]
    for key in order:
        lines.append("[%s:%s]" % key)
        lines.extend("%s=%s" % kv for kv in data[key])
        lines.append("")
    return "\n".join(lines)


def diff(a, b):
    """Human-readable list of keys that differ between two parsed presets."""
    rows = []
    for key in sorted(set(a) | set(b)):
        da, db = dict(a.get(key, [])), dict(b.get(key, []))
        for k in sorted(set(da) | set(db)):
            if da.get(k) != db.get(k):
                rows.append("%s:%s %s: %s -> %s" % (key[0], key[1], k, da.get(k, "(default)"), db.get(k, "(default)")))
    return rows


def main():
    order, data = clean(*parse(BASE))
    ultra = apply(order, data, ULTRA)
    balanced = apply(*ultra, BALANCED)
    for name, preset in (("JamPure_CSP_Ultra", ultra), ("JamPure_CSP_Balanced", balanced)):
        path = os.path.join(HERE, name + ".ini")
        with open(path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(render(*preset))
        print("wrote %s (%d blocks)" % (os.path.basename(path), len(preset[0])))
    print("\nUltra vs base (%d changes):" % len(diff(data, ultra[1])))
    for row in diff(data, ultra[1]):
        print("  " + row)
    print("\nBalanced vs Ultra (%d changes):" % len(diff(ultra[1], balanced[1])))
    for row in diff(ultra[1], balanced[1]):
        print("  " + row)


if __name__ == "__main__":
    main()
