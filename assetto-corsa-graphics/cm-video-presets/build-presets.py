#!/usr/bin/env python3
"""Regenerates the Content Manager "Video Settings" presets (*.cmpreset).

Content Manager stores a video preset as a JSON object with three INI documents
inside it (video.ini, graphics.ini and oculus.ini), so hand-editing the JSON is
awkward. Edit the dictionaries below instead and run:

    python3 build-presets.py

Resolution is set to 1920x1080 @ 60 Hz because Content Manager needs *some* mode
and that one exists on practically every display. Re-pick your own resolution and
refresh rate in Content Manager > Settings > Video after loading a preset.
"""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
NL = "\r\n"  # Content Manager writes INI files with Windows line endings


def ini(sections):
    out = []
    for name, keys in sections:
        out.append(f"[{name}]")
        out.extend(f"{k}={v}" for k, v in keys)
        out.append("")
    return NL.join(out)


def video(*, aa, aniso, shadows, world_detail, smoke, pp_quality, glare, dof,
          mirror_size, cubemap_size, cubemap_faces, cubemap_distance,
          pp_filter="JamPure_Cinematic"):
    return ini([
        ("VIDEO", [
            ("WIDTH", 1920), ("HEIGHT", 1080), ("REFRESH", 60), ("INDEX", 0),
            ("FULLSCREEN", 1), ("VSYNC", 0),
            ("AASAMPLES", aa), ("ANISOTROPIC", aniso), ("SHADOW_MAP_SIZE", shadows),
            ("FPS_CAP_MS", 0),
        ]),
        ("REFRESH", [("VALUE", 60)]),
        ("CAMERA", [("MODE", "DEFAULT")]),
        ("ASSETTOCORSA", [
            ("HIDE_ARMS", 0), ("HIDE_STEER", 0), ("LOCK_STEER", 0),
            ("WORLD_DETAIL", world_detail),
        ]),
        ("EFFECTS", [
            ("MOTION_BLUR", 0),  # CSP ExtraFX motion blur is used instead
            ("RENDER_SMOKE_IN_MIRROR", 0), ("SMOKE", smoke),
        ]),
        ("POST_PROCESS", [
            ("ENABLED", 1), ("QUALITY", pp_quality), ("FILTER", pp_filter),
            ("GLARE", glare), ("DOF", dof), ("RAYS_OF_GOD", 1),
            ("HEAT_SHIMMER", 1), ("FXAA", 1),
        ]),
        ("SATURATION", [("LEVEL", 100)]),
        ("MIRROR", [("HQ", 1), ("SIZE", mirror_size)]),
        ("CUBEMAP", [
            ("SIZE", cubemap_size), ("FACES_PER_FRAME", cubemap_faces),
            ("FARPLANE", cubemap_distance),
        ]),
    ])


def graphics(*, mip_lod_bias, frame_latency):
    return ini([
        ("DX11", [
            ("ALLOW_UNSUPPORTED_DX10", 0),
            ("MIP_LOD_BIAS", mip_lod_bias),
            ("SKYBOX_REFLECTION_GAIN", 1.0),
            ("MAXIMUM_FRAME_LATENCY", frame_latency),
            ("SHADOW_MAP_BIAS_0", "0.000002"),
            ("SHADOW_MAP_BIAS_1", "0.000015"),
            ("SHADOW_MAP_BIAS_2", "0.0003"),
        ]),
    ])


def oculus(*, pixel_per_display):
    return ini([
        ("SETTINGS", [("PIXEL_PER_DISPLAY", pixel_per_display), ("AUTOSELECT_RIFT_AUDIO_DEVICE", 0)]),
        ("MIRROR_TEXTURE", [("ENABLED", 1)]),
    ])


PRESETS = {
    "JamPure Ultra": dict(
        video=video(aa=4, aniso=16, shadows=4096, world_detail=5, smoke=3,
                    pp_quality=5, glare=5, dof=5,
                    mirror_size=1024, cubemap_size=2048, cubemap_faces=6, cubemap_distance=1000),
        graphics=graphics(mip_lod_bias=-0.5, frame_latency=1),
        oculus=oculus(pixel_per_display=1.3),
    ),
    "JamPure Balanced": dict(
        video=video(aa=2, aniso=16, shadows=2048, world_detail=4, smoke=2,
                    pp_quality=4, glare=4, dof=3,
                    mirror_size=512, cubemap_size=1024, cubemap_faces=3, cubemap_distance=600),
        graphics=graphics(mip_lod_bias=-0.25, frame_latency=1),
        oculus=oculus(pixel_per_display=1.0),
    ),
}


def main():
    for name, parts in PRESETS.items():
        payload = {
            "VideoData": parts["video"],
            "GraphicsData": parts["graphics"],
            "OculusData": parts["oculus"],
        }
        path = os.path.join(HERE, f"{name}.cmpreset")
        with open(path, "w", encoding="utf-8", newline="") as fh:
            json.dump(payload, fh)
        print(f"wrote {path}")


if __name__ == "__main__":
    main()
