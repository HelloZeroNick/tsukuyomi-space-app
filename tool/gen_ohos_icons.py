# -*- coding: utf-8 -*-
"""Generate OHOS icons.

- App icons: single-layer full-bleed square (system masks corners).
- Start-window icon: solid background + centered icon with rounded corners.
"""
import os
from PIL import Image, ImageDraw

ROOT = r"D:\github\tsukuyomi-space-app"
SRC = os.path.join(ROOT, "assets", "branding", "app-icon.png")

src = Image.open(SRC).convert("RGB")

# --- App icons: full-bleed square, no rounded corners (system masks) ---
app_targets = [
    (os.path.join(ROOT, "ohos", "AppScope", "resources", "base", "media", "app_icon.png"), 1024),
    (os.path.join(ROOT, "ohos", "entry", "src", "main", "resources", "base", "media", "icon.png"), 512),
]
for path, size in app_targets:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    src.resize((size, size), Image.LANCZOS).save(path, "PNG")
    print("wrote", path, size)

# --- Start-window icon: transparent bg, centered icon with rounded corners ---
size = 256
radius = int(size * 0.2237)  # HarmonyOS-style corner radius
img = src.resize((size, size), Image.LANCZOS).convert("RGBA")
mask = Image.new("L", (size, size), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
img.putalpha(mask)
out = os.path.join(ROOT, "ohos", "entry", "src", "main", "resources", "base", "media", "icon_startwindow.png")
img.save(out, "PNG")
print("wrote", out, size, "radius", radius)
