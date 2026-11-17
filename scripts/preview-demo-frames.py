#!/usr/bin/env python3
"""Render the demo GIF's frames as individual PNGs, for eyeballing the result.

    python scripts/preview-demo-frames.py <output-dir>

Not part of the build: this exists so the person regenerating the GIF can look at the frames instead of
trusting a byte count.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

# The generator's filename has a hyphen, so it cannot be imported by name; load it by path instead.
_spec = importlib.util.spec_from_file_location(
    "make_demo_gif", Path(__file__).resolve().parent / "make-demo-gif.py"
)
gif = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gif)


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: preview-demo-frames.py <output-dir>")

    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)

    transcript = gif.run_demo()
    frames = gif.build_frames(transcript)
    for index, (image, duration) in enumerate(frames):
        path = out / f"frame-{index:02d}.png"
        image.save(path)
        print(f"{path}  {image.size[0]}x{image.size[1]}  {duration}ms")


if __name__ == "__main__":
    main()