#!/usr/bin/env python3
"""Generate the Homework Scanner launcher icon and Android adaptive layers.

The mark is intentionally simple: a cream notebook page framed by scan corners,
with an amber completion check. It shares the app's green/cream palette and is
distinct from the default Flutter icon.
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
RES = ROOT / "android" / "app" / "src" / "main" / "res"

GREEN_TOP = (38, 92, 75)
GREEN_BOTTOM = (48, 115, 94)
PAGE = (251, 252, 247)
PAGE_EDGE = (225, 233, 224)
FOLD = (230, 238, 228)
INK = (30, 78, 62)
LINE = (177, 198, 185)
AMBER = (224, 158, 45)
WHITE = (255, 255, 255)


def gradient(size: int) -> Image.Image:
    image = Image.new("RGB", (size, size), GREEN_TOP)
    pixels = image.load()
    for y in range(size):
        t = y / max(1, size - 1)
        color = tuple(
            round(GREEN_TOP[i] * (1 - t) + GREEN_BOTTOM[i] * t) for i in range(3)
        )
        for x in range(size):
            pixels[x, y] = color
    return image


def draw_mark(size: int, *, background: bool) -> Image.Image:
    """Draw the page mark at `size`. When background is false, keep alpha."""
    scale = size / 2048.0
    image = Image.new(
        "RGBA",
        (size, size),
        (0, 0, 0, 0) if not background else (0, 0, 0, 255),
    )
    if background:
        base = gradient(size).convert("RGBA")
        mask = Image.new("L", (size, size), 0)
        ImageDraw.Draw(mask).rounded_rectangle(
            (0, 0, size - 1, size - 1), radius=round(390 * scale), fill=255
        )
        image.paste(base, (0, 0), mask)

    draw = ImageDraw.Draw(image)

    def box(values: tuple[float, float, float, float]) -> tuple[int, int, int, int]:
        return tuple(round(v * scale) for v in values)

    # The adaptive foreground must stay inside the 66/108 safe zone.
    if background:
        page = (286, 172, 1338, 1724)
        radius = 58
    else:
        page = (500, 430, 1530, 1590)
        radius = 50
    left, top, right, bottom = page
    draw.rounded_rectangle(
        box(page),
        radius=round(radius * scale),
        fill=PAGE,
        outline=PAGE_EDGE,
        width=max(1, round(8 * scale)),
    )

    # Scan brackets on the page.
    inset = 62
    arm = 150
    width = max(2, round(22 * scale))
    corners = [
        (left + inset, top + inset, 1, 1),
        (right - inset, top + inset, -1, 1),
        (left + inset, bottom - inset, 1, -1),
        (right - inset, bottom - inset, -1, -1),
    ]
    for x, y, sx, sy in corners:
        draw.line(
            [
                (round(x * scale), round(y * scale)),
                (
                    round((x + sx * arm) * scale),
                    round(y * scale),
                ),
            ],
            fill=INK,
            width=width,
        )
        draw.line(
            [
                (round(x * scale), round(y * scale)),
                (
                    round(x * scale),
                    round((y + sy * arm) * scale),
                ),
            ],
            fill=INK,
            width=width,
        )

    # Notebook lines. Kept low-contrast so they read as paper, not text.
    line_left = left + 190
    line_right = right - 190
    line_width = max(1, round(17 * scale))
    for index, fraction in enumerate((0.46, 0.57, 0.68, 0.79)):
        y = top + (bottom - top) * fraction
        end = line_right if index != 3 else line_left + (line_right - line_left) * 0.68
        draw.line(
            [(round(line_left * scale), round(y * scale)), (round(end * scale), round(y * scale))],
            fill=LINE,
            width=line_width,
        )

    # Amber check badge.
    if background:
        cx, cy, circle = 1276, 1660, 252
    else:
        cx, cy, circle = 1440, 1480, 190
    draw.ellipse(
        box((cx - circle, cy - circle, cx + circle, cy + circle)),
        fill=AMBER,
        outline=PAGE,
        width=max(2, round(18 * scale)),
    )
    check_width = max(3, round(34 * scale))
    draw.line(
        [
            (round((cx - 108) * scale), round((cy + 6) * scale)),
            (round((cx - 28) * scale), round((cy + 84) * scale)),
            (round((cx + 122) * scale), round((cy - 92) * scale)),
        ],
        fill=WHITE,
        width=check_width,
        joint="curve",
    )
    return image


def main() -> None:
    legacy_sizes = {
        "mipmap-mdpi": 48,
        "mipmap-hdpi": 72,
        "mipmap-xhdpi": 96,
        "mipmap-xxhdpi": 144,
        "mipmap-xxxhdpi": 192,
    }
    foreground_sizes = {
        "mipmap-mdpi": 108,
        "mipmap-hdpi": 162,
        "mipmap-xhdpi": 216,
        "mipmap-xxhdpi": 324,
        "mipmap-xxxhdpi": 432,
    }
    for folder, size in legacy_sizes.items():
        out = RES / folder / "ic_launcher.png"
        out.parent.mkdir(parents=True, exist_ok=True)
        draw_mark(size, background=True).save(out, optimize=True)
    for folder, size in foreground_sizes.items():
        out = RES / folder / "ic_launcher_foreground.png"
        out.parent.mkdir(parents=True, exist_ok=True)
        draw_mark(size, background=False).save(out, optimize=True)
    draw_mark(512, background=True).save(ROOT / "docs" / "app_icon_preview.png", optimize=True)
    print("wrote launcher icons to", RES)


if __name__ == "__main__":
    main()
