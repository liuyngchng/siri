#!/usr/bin/env python3
"""Generate iOS app icon (1024x1024) from the Android vector drawable design.

The Android icon is designed for a 108dp viewport with a 72dp diameter circular
safe zone. For iOS, the icon fills a rounded square, so the central graphic is
scaled up to ~75% of the canvas width.
"""

from PIL import Image, ImageDraw
import math

SIZE = 1024
CENTER = SIZE / 2  # 512

# iOS squircle safe zone: about 80% of canvas
# We'll fit the circular artwork within a diameter of ~780px
# Android original: bars fit in 72dp diameter circle in 108dp viewport
# Ratio: 72/108 = 0.667. For iOS, we use ~0.75 of canvas for the artwork.
ART_SCALE = SIZE / 108 * 1.15  # ~10.9, vs ~9.48 without boost

# --- Colors (from Android XML) ---
BG_START = (0x1A, 0x1A, 0x2E)
BG_END = (0x16, 0x21, 0x3E)
INNER_GLOW = (0x3A, 0x3A, 0x5E, 255)
OUTER_RING = (255, 255, 255, 0x33)

BAR_COLORS = [
    (0x7D, 0xD3, 0xFC, 255),  # #7DD3FC cyan
    (0x81, 0xC9, 0xF8, 255),
    (0x8C, 0xB5, 0xF2, 255),
    (0x9A, 0x9F, 0xE8, 255),
    (0xA4, 0x8E, 0xDF, 255),  # center peak
    (0xA4, 0x8E, 0xDF, 255),
    (0xA4, 0x8E, 0xDF, 255),
    (0xA7, 0x8B, 0xFA, 255),
    (0xB0, 0x84, 0xF2, 255),
    (0xB9, 0x7D, 0xE8, 255),  # purple
]

DOT_COLOR = (0xA7, 0x8B, 0xFA, 255)

# Bar definitions in 108dp viewport coordinates
BARS = [
    (34, 48, 60, 3.0),
    (40, 43, 65, 3.0),
    (46, 37, 71, 3.0),
    (52, 32, 76, 3.0),
    (54, 28, 80, 3.0),   # center peak
    (58, 35, 73, 3.0),
    (62, 40, 68, 3.0),
    (66, 45, 63, 3.0),
    (72, 49, 59, 3.0),
    (76, 52, 56, 2.5),
]

DOT = (54, 85, 2.0)
OUTER_RING_SPEC = (54, 54, 36, 2.0)
INNER_GLOW_SPEC = (54, 54, 44, 1.0)


def sc(dp_val):
    """Convert 108dp coordinate to 1024px, centered and scaled for iOS."""
    return (dp_val - 54) * ART_SCALE + CENTER


def draw_gradient_background(draw, width, height):
    """Fill canvas with diagonal linear gradient."""
    for y in range(height):
        t = y / height
        r = int(BG_START[0] + (BG_END[0] - BG_START[0]) * t)
        g = int(BG_START[1] + (BG_END[1] - BG_START[1]) * t)
        b = int(BG_START[2] + (BG_END[2] - BG_START[2]) * t)
        draw.line([(0, y), (width, y)], fill=(r, g, b))


def draw_ring(draw, cx, cy, radius_dp, stroke_dp, color):
    """Draw a stroked circle."""
    r = radius_dp * ART_SCALE
    sw = max(2, int(stroke_dp * ART_SCALE))
    cx_s = sc(cx)
    cy_s = sc(cy)
    for i in range(sw):
        rr = r - sw / 2 + i
        draw.ellipse([cx_s - rr, cy_s - rr, cx_s + rr, cy_s + rr], outline=color)


def draw_bar(draw, cx_dp, top_dp, bot_dp, sw_dp, color):
    """Draw a vertical bar with round caps."""
    cx_s = sc(cx_dp)
    top_s = sc(top_dp)
    bot_s = sc(bot_dp)
    sw_s = max(2, int(sw_dp * ART_SCALE))

    draw.line([(cx_s, top_s), (cx_s, bot_s)], fill=color, width=sw_s)

    # Round caps
    cap_r = sw_s / 2
    for cy_v in (top_s, bot_s):
        draw.ellipse(
            [cx_s - cap_r, cy_v - cap_r, cx_s + cap_r, cy_v + cap_r],
            fill=color,
        )


def draw_dot(draw, cx_dp, cy_dp, r_dp, color):
    """Draw a filled circle."""
    cx_s = sc(cx_dp)
    cy_s = sc(cy_dp)
    r_s = max(4, int(r_dp * ART_SCALE))
    draw.ellipse([cx_s - r_s, cy_s - r_s, cx_s + r_s, cy_s + r_s], fill=color)


def main():
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    print("Drawing gradient background...")
    draw_gradient_background(draw, SIZE, SIZE)

    print("Drawing inner glow ring...")
    draw_ring(draw, *INNER_GLOW_SPEC[:3], INNER_GLOW_SPEC[3], INNER_GLOW)

    print("Drawing outer ring...")
    draw_ring(draw, *OUTER_RING_SPEC[:3], OUTER_RING_SPEC[3], OUTER_RING)

    print("Drawing waveform bars...")
    for (bar, color) in zip(BARS, BAR_COLORS):
        draw_bar(draw, bar[0], bar[1], bar[2], bar[3], color)

    print("Drawing center dot...")
    draw_dot(draw, *DOT, DOT_COLOR)

    output_path = "/Users/richard/workspace/siri/ios/SiriApp/Assets.xcassets/AppIcon.appiconset/Icon-1024.png"
    img.save(output_path, "PNG")
    print(f"Saved: {output_path} ({SIZE}x{SIZE})")


if __name__ == "__main__":
    main()
