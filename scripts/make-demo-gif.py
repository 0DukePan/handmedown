#!/usr/bin/env python3
"""Generate docs/demo.gif from a real `hand demo` run.

    python scripts/make-demo-gif.py

The frames are rendered from the tool's own stdout, not from text written by hand, so the picture
cannot show behaviour the tool does not have. Two things are sanitised before rendering, both for
determinism rather than for looks: the temporary work directory (varies every run) and the transcript's
own title line (the window chrome already says which command this is).

Requires Pillow. Uses a system monospace font; see FONT_CANDIDATES.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

REPO = Path(__file__).resolve().parent.parent
AGENT = REPO / "agent"
OUTPUT = REPO / "docs" / "demo.gif"

# Deliberately modest: this image sits at the top of the README and has to load on a phone.
WIDTH = 880
MARGIN = 26
LINE_HEIGHT = 22
FONT_SIZE = 15
CHROME_HEIGHT = 42

BUDGET_BYTES = 1_500_000

FONT_CANDIDATES = [
    Path(r"C:\Windows\Fonts\consola.ttf"),
    Path(r"C:\Windows\Fonts\lucon.ttf"),
    Path(r"C:\Windows\Fonts\cour.ttf"),
    Path("/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"),
    Path("/System/Library/Fonts/Menlo.ttc"),
]

BACKGROUND = (15, 17, 21)
FOREGROUND = (220, 223, 228)
DIM = (125, 133, 144)
GREEN = (63, 185, 80)
CYAN = (88, 166, 255)
YELLOW = (210, 153, 34)
RED = (248, 81, 73)

# Where to cut the transcript into frames. Each marker produces one frame showing everything up to and
# including that line; the last frame always shows the whole transcript.
FRAME_MARKERS = [
    "plan",
    "[ 2]",
    "interrupted after",
    "[ 2] take-01",
    "done in",
    "verdict",
    "PASS  the",
]


def font() -> ImageFont.FreeTypeFont:
    for candidate in FONT_CANDIDATES:
        if candidate.exists():
            return ImageFont.truetype(str(candidate), FONT_SIZE)
    raise SystemExit("no monospace font found; add one to FONT_CANDIDATES")


def run_demo() -> str:
    binary = AGENT / ("hand.exe" if sys.platform == "win32" else "hand")
    if not binary.exists():
        raise SystemExit(f"{binary} is missing; run scripts/tasks.ps1 build first")

    completed = subprocess.run(
        [str(binary), "demo", "--inputs", "10", "--stop-after", "4"],
        capture_output=True,
        text=True,
        cwd=REPO,
    )
    if completed.returncode != 0:
        raise SystemExit(
            f"hand demo failed ({completed.returncode}):\n{completed.stdout}\n{completed.stderr}"
        )
    if completed.stdout.count("PASS") < 2:
        raise SystemExit("hand demo did not report a full verdict; refusing to render a GIF")

    return sanitise(completed.stdout)


def sanitise(text: str) -> str:
    # The work directory is a fresh temp path on every run. Left in, the GIF would change on every
    # regeneration for no reason, and the diff would be noise instead of a review.
    text = re.sub(r"(workdir\s+)\S+", r"\1<workdir>", text)
    text = re.sub(r"(journal on disk[^:]*: )\S+", r"\1<workdir>/journal/demo-shard.jsonl", text)
    return text


def colour_for(line: str) -> tuple[int, int, int]:
    stripped = line.strip()
    if stripped.startswith("PASS"):
        return GREEN
    if stripped.startswith("FAIL"):
        return RED
    if stripped.startswith("interrupted") or stripped.startswith("done in"):
        return CYAN
    if stripped.startswith("verdict") or stripped.startswith("run "):
        return FOREGROUND
    if "skip" in stripped:
        return YELLOW
    if stripped.startswith("["):
        return FOREGROUND
    return DIM


def render(lines: list[str], height: int, current: int | None = None) -> Image.Image:
    image = Image.new("RGB", (WIDTH, height), BACKGROUND)
    draw = ImageDraw.Draw(image)
    face = font()

    # A two-pixel accent strip and a label: enough to read as a terminal without pretending to be a
    # screenshot of a particular one.
    draw.rectangle([0, 0, WIDTH, 3], fill=(36, 42, 51))
    draw.text((MARGIN, 14), "handmedown  .  hand demo", font=face, fill=DIM)

    y = CHROME_HEIGHT
    for index, line in enumerate(lines):
        if y + LINE_HEIGHT > height - MARGIN // 2:
            break
        fill = FOREGROUND if (current is not None and index == current) else colour_for(line)
        draw.text((MARGIN, y), line[:118], font=face, fill=fill)
        y += LINE_HEIGHT
    return image


def build_frames(transcript: str) -> list[tuple[Image.Image, int]]:
    lines = transcript.splitlines()
    while lines and lines[0].strip() == "hand demo":
        lines.pop(0)
    while lines and not lines[-1].strip():
        lines.pop()

    ends: list[int] = []
    for marker in FRAME_MARKERS:
        floor = ends[-1] if ends else -1
        for index, line in enumerate(lines):
            if marker in line and index > floor:
                ends.append(index)
                break

    # Always finish on the complete transcript, so the last frame is the whole story.
    if not ends or ends[-1] != len(lines) - 1:
        ends.append(len(lines) - 1)

    ends = sorted(set(ends))
    visible_counts = [min(end + 1, len(lines)) for end in ends]

    # One canvas size for every frame (a GIF cannot mix sizes), sized to the tallest frame so there is
    # no dead space under the shortest one.
    height = CHROME_HEIGHT + max(visible_counts) * LINE_HEIGHT + MARGIN // 2

    frames: list[tuple[Image.Image, int]] = []
    for end in ends:
        image = render(lines[: end + 1], height, current=end)
        frames.append((image, 1100))

    # Hold the verdict long enough to read it, then loop.
    image, _ = frames[-1]
    frames[-1] = (image, 3200)
    return frames


def main() -> None:
    transcript = run_demo()
    frames = build_frames(transcript)
    if len(frames) < 4:
        raise SystemExit(f"only {len(frames)} frames; the transcript may have changed shape")

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    images = [frame for frame, _ in frames]
    durations = [duration for _, duration in frames]

    images[0].save(
        OUTPUT,
        save_all=True,
        append_images=images[1:],
        duration=durations,
        loop=0,
        optimize=True,
        disposal=2,
    )

    size = OUTPUT.stat().st_size
    print(
        f"wrote {OUTPUT.relative_to(REPO)} "
        f"({len(images)} frames, {images[0].size[0]}x{images[0].size[1]}, {size / 1024:.0f} KB)"
    )
    if size > BUDGET_BYTES:
        raise SystemExit(f"GIF is {size} bytes, over the {BUDGET_BYTES} byte budget")


if __name__ == "__main__":
    main()