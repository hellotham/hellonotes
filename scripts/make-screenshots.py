#!/usr/bin/env python3
"""
Composite the marketing screenshot frames used by the website.

Input  : raw window captures (screencapture -R of the HelloNotes window)
Output : website/src/assets/screens/{light,dark}_0N.png

Each frame is the brand gradient, a caption, and the window shot with rounded
corners and a soft drop shadow — the same treatment in both appearances, so the
only thing that changes between the light and dark sets is the app itself.

Capturing the raw input is a manual step; see docs/website.md § Screenshots.
Needs Pillow:  python3 -m venv venv && ./venv/bin/pip install Pillow

    ./venv/bin/python scripts/make-screenshots.py <raw-dir> <out-dir>
"""

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

# Canvas
W, H = 2560, 1600

# The site's brand gradient (global.css @utility brand-gradient), 115°.
STOPS = [(0.00, (0x7C, 0x3A, 0xED)), (0.55, (0xEC, 0x48, 0x99)), (1.00, (0xF5, 0x9E, 0x0B))]
ANGLE_DEG = 115

CAPTION_FONT = "/System/Library/Fonts/SFNSRounded.ttf"
CAPTION_FALLBACK = "/System/Library/Fonts/Supplemental/Arial Rounded Bold.ttf"
CAPTION_SIZE = 68
CAPTION_TOP = 74

# Window plate
PLATE_TOP = 250
PLATE_MARGIN_X = 150
CORNER_RADIUS = 26
SHADOW_BLUR = 40
SHADOW_OFFSET = 26
SHADOW_ALPHA = 115

SCENES = [
    ("01", "Your notes. Your files. Local and private."),
    ("02", "LaTeX maths & Mermaid diagrams, inline"),
    ("03", "Callouts, properties & rich Markdown"),
    ("04", "See how your thinking connects"),
    ("05", "Ask your library — answers with citations"),
]


def _sample(stops, t):
    """Colour at position t (0..1) along the stop list."""
    t = min(1.0, max(0.0, t))
    for i in range(len(stops) - 1):
        p0, c0 = stops[i]
        p1, c1 = stops[i + 1]
        if t <= p1 or i == len(stops) - 2:
            f = 0.0 if p1 == p0 else (t - p0) / (p1 - p0)
            f = min(1.0, max(0.0, f))
            return tuple(round(a + (b - a) * f) for a, b in zip(c0, c1))
    return stops[-1][1]


def gradient(size, angle_deg, stops):
    """
    Linear gradient following the CSS convention: 0deg points up and angles run
    clockwise, so 115deg runs from the top-left down towards the bottom-right.
    The gradient line passes through the centre of the box and its length is the
    projection of the box onto that line — get either wrong and the first stop
    (the violet) falls outside the canvas and never appears.

    Built by rendering a 1-D ramp and projecting it, which is ~500x faster than
    evaluating the interpolation per pixel.
    """
    import math

    w, h = size
    rad = math.radians(angle_deg - 90)
    dx, dy = math.cos(rad), math.sin(rad)
    length = abs(w * dx) + abs(h * dy)
    cx, cy = w / 2, h / 2

    # A 1-D ramp along the gradient line, then one lookup per pixel via a
    # separable projection: t(x,y) = tx(x) + ty(y), so build both axes once.
    steps = 1024
    ramp = [_sample(stops, i / (steps - 1)) for i in range(steps)]
    tx = [((x - cx) * dx) / length for x in range(w)]
    ty = [((y - cy) * dy) / length + 0.5 for y in range(h)]

    img = Image.new("RGB", size)
    px = img.load()
    for y in range(h):
        base = ty[y]
        for x in range(w):
            i = int((base + tx[x]) * (steps - 1))
            px[x, y] = ramp[0 if i < 0 else steps - 1 if i >= steps else i]
    return img


def rounded_mask(size, radius):
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size[0] - 1, size[1] - 1], radius, fill=255)
    return mask


def load_font(size):
    for path in (CAPTION_FONT, CAPTION_FALLBACK):
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default()


def compose(shot_path, caption, out_path, bg):
    canvas = bg.convert("RGBA")

    # Caption, centred.
    draw = ImageDraw.Draw(canvas)
    font = load_font(CAPTION_SIZE)
    tw = draw.textbbox((0, 0), caption, font=font)[2]
    draw.text(((W - tw) / 2, CAPTION_TOP), caption, font=font, fill=(255, 255, 255, 255))

    # Window plate: scale to fit the area below the caption.
    shot = Image.open(shot_path).convert("RGBA")
    avail_w = W - 2 * PLATE_MARGIN_X
    avail_h = H - PLATE_TOP - 120
    scale = min(avail_w / shot.width, avail_h / shot.height)
    pw, ph = round(shot.width * scale), round(shot.height * scale)
    shot = shot.resize((pw, ph), Image.LANCZOS)
    shot.putalpha(rounded_mask((pw, ph), CORNER_RADIUS))

    px = (W - pw) // 2
    py = PLATE_TOP + (avail_h - ph) // 2

    # Soft drop shadow behind the plate. Inset horizontally and pushed down, so
    # the blur reads as light from above rather than haloing every edge.
    inset = SHADOW_BLUR // 2
    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        [px + inset, py + SHADOW_OFFSET, px + pw - inset, py + ph + SHADOW_OFFSET],
        CORNER_RADIUS,
        fill=(0, 0, 0, SHADOW_ALPHA),
    )
    canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(SHADOW_BLUR)))
    canvas.alpha_composite(shot, (px, py))

    canvas.convert("RGB").save(out_path, "PNG", optimize=True)
    return out_path


# --- Open Graph card -------------------------------------------------------
#
# Social crawlers want one stable, unhashed URL, so this writes straight to
# website/public/assets/og.png rather than going through astro:assets.

OG_W, OG_H = 1200, 630


def make_og(icon_path, out_path):
    bg = gradient((OG_W, OG_H), ANGLE_DEG, STOPS)
    canvas = bg.convert("RGBA")
    draw = ImageDraw.Draw(canvas)

    icon = Image.open(icon_path).convert("RGBA").resize((188, 188), Image.LANCZOS)
    canvas.alpha_composite(icon, ((OG_W - 188) // 2, 92))

    title = load_font(84)
    tag = load_font(35)
    for text, font, y in (
        ("HelloNotes", title, 310),
        ("A private, local-first Markdown", tag, 424),
        ("knowledge base for your Mac", tag, 476),
    ):
        w = draw.textbbox((0, 0), text, font=font)[2]
        draw.text(((OG_W - w) / 2, y), text, font=font, fill=(255, 255, 255, 255))

    foot = load_font(26)
    label = "hellotham.com/hellonotes"
    w = draw.textbbox((0, 0), label, font=foot)[2]
    draw.text(((OG_W - w) / 2, 548), label, font=foot, fill=(255, 255, 255, 205))

    canvas.convert("RGB").save(out_path, "PNG", optimize=True)
    return out_path


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    raw, out = Path(sys.argv[1]), Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)

    bg = gradient((W, H), ANGLE_DEG, STOPS)

    for mode in ("light", "dark"):
        for num, caption in SCENES:
            src = raw / f"{mode}_{int(num)}.png"
            if not src.exists():
                print(f"  ! missing {src}")
                continue
            dst = out / f"{mode}_{num}.png"
            compose(src, caption, dst, bg)
            kb = dst.stat().st_size // 1024
            print(f"  {dst.name}  {kb} KB")

    icon = Path("website/public/assets/icon.png")
    if icon.exists():
        og = make_og(icon, Path("website/public/assets/og.png"))
        print(f"  {og}  {og.stat().st_size // 1024} KB")


if __name__ == "__main__":
    main()
