"""Generate the thermaLab app icon: a hot mug with steam as a thermal image.

Writes, into the directory given as argument:
  icon.png             1024x1024 full icon (legacy launchers, README)
  icon_background.png  1024x1024 thermal scene (adaptive icon background)
  icon_foreground.png  1024x1024 crosshair on transparency (adaptive foreground)
"""
import math
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

N = 1024
out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)

y, x = np.mgrid[0:N, 0:N].astype(np.float32) / N  # 0..1

# Cool background with a gentle gradient (warmer towards the bottom).
field = 0.06 + 0.16 * y + 0.04 * np.sin(x * 3.1 + 0.6) + 0.03 * np.cos(y * 5.0 + x * 2.0)

# Table surface warmed by the mug.
field += 0.10 * np.exp(-((y - 0.80) / 0.06) ** 2) * np.exp(-((x - 0.47) / 0.30) ** 2)


def rounded_rect(cx, cy, w, h, r):
    dx = np.maximum(np.abs(x - cx) - (w / 2 - r), 0)
    dy = np.maximum(np.abs(y - cy) - (h / 2 - r), 0)
    return np.sqrt(dx * dx + dy * dy) <= r


# Mug body: hot, a little hotter towards the liquid at the top.
body = rounded_rect(0.45, 0.60, 0.32, 0.34, 0.05)
field = np.where(body, 0.78 + 0.14 * (0.77 - y) / 0.34, field)
# Handle: a ring on the right side.
ring = np.abs(np.sqrt(((x - 0.635) / 0.075) ** 2 + ((y - 0.60) / 0.095) ** 2) - 1.0) < 0.28
field = np.where(ring & (x > 0.6), np.maximum(field, 0.66), field)
# Liquid surface: hottest.
liquid = (np.abs(y - 0.44) < 0.022) & (np.abs(x - 0.45) < 0.14)
field = np.where(liquid, 1.0, field)

# Steam: three wavy plumes fading upwards.
for offset, phase in ((-0.09, 0.0), (0.0, 2.2), (0.09, 4.1)):
    centre = 0.45 + offset + 0.014 * np.sin(y * 24 + phase)
    width = 0.016 + 0.02 * (0.42 - y)
    strength = np.clip((0.42 - y) / 0.25, 0, 1) * np.clip((y - 0.10) / 0.12, 0, 1)
    plume = np.exp(-((x - centre) / np.maximum(width, 0.01)) ** 2) * strength
    field = np.maximum(field, 0.25 + 0.45 * plume * (y < 0.42))

# Thermal cameras are a little soft.
img = Image.fromarray(np.clip(field * 255, 0, 255).astype(np.uint8), "L")
img = img.filter(ImageFilter.GaussianBlur(9))
field = np.asarray(img).astype(np.float32) / 255

# Iron palette, same stops as lib/render/palette.dart.
stops = [
    (0.00, (0x00, 0x00, 0x00)),
    (0.15, (0x20, 0x00, 0x8C)),
    (0.35, (0x8C, 0x00, 0xA0)),
    (0.55, (0xD7, 0x26, 0x2E)),
    (0.75, (0xF6, 0x8C, 0x0C)),
    (0.90, (0xFC, 0xD8, 0x36)),
    (1.00, (0xFF, 0xFF, 0xFF)),
]
pos = np.array([s[0] for s in stops])
# A little sensor grain.
rng = np.random.default_rng(7)
grain = Image.fromarray(np.clip(rng.normal(128, 40, (N // 4, N // 4)), 0, 255).astype(np.uint8), "L")
grain = np.asarray(grain.resize((N, N), Image.BILINEAR)).astype(np.float32) / 255 - 0.5
field = np.clip(field + 0.025 * grain, 0, 1)
rgb = np.zeros((N, N, 3), np.float32)
for ch in range(3):
    rgb[..., ch] = np.interp(field, pos, [s[1][ch] for s in stops])
background = Image.fromarray(rgb.astype(np.uint8), "RGB")
background.save(out / "icon_background.png")

# Crosshair with a dark outline, as drawn on the measurement view.
fg = Image.new("RGBA", (N, N), (0, 0, 0, 0))
d = ImageDraw.Draw(fg)
cx, cy, r = int(0.45 * N), int(0.60 * N), int(0.085 * N)
for width, colour in ((34, (0, 0, 0, 120)), (14, (255, 255, 255, 255))):
    d.line((cx - r, cy, cx + r, cy), fill=colour, width=width)
    d.line((cx, cy - r, cx, cy + r), fill=colour, width=width)
fg.save(out / "icon_foreground.png")

full = background.convert("RGBA")
full.alpha_composite(fg)
full.save(out / "icon.png")
print("written to", out)
