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

import sys


def main(argv: list[str] | None = None) -> int:
    raise NotImplementedError


if __name__ == "__main__":
    sys.exit(main())
