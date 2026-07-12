#!/usr/bin/env python3
"""Compose raw simulator captures into App Store marketing panels.

Layout: navy brand gradient, bold white caption, rounded-corner screenshot
with a hairline border and soft shadow. Output is exactly the ASC slot size
(iPhone 6.9" 1320x2868, iPad 13" 2064x2752).
Run from marketing/screenshots/:  python3 compose_panels.py
"""

from PIL import Image, ImageDraw, ImageFilter, ImageFont

NAVY_TOP = (14, 26, 54)
NAVY_BOT = (30, 58, 102)
TEAL = (38, 158, 163)

FONT_CANDIDATES = [
    "/System/Library/Fonts/SF-Pro-Display-Bold.otf",
    "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
]


def load_font(size):
    import os
    # Prefer the SF/Helvetica look; HelveticaNeue.ttc bold face if present.
    ttc = "/System/Library/Fonts/HelveticaNeue.ttc"
    if os.path.exists(ttc):
        for idx in range(0, 14):
            try:
                f = ImageFont.truetype(ttc, size, index=idx)
                name = " ".join(f.getname())
                if "Bold" in name and "Italic" not in name and "Condensed" not in name:
                    return f
            except Exception:
                break
    for path in FONT_CANDIDATES:
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    raise RuntimeError("no usable bold font found")


def gradient(w, h):
    img = Image.new("RGB", (w, h))
    px = img.load()
    for y in range(h):
        t = y / (h - 1)
        r = int(NAVY_TOP[0] + (NAVY_BOT[0] - NAVY_TOP[0]) * t)
        g = int(NAVY_TOP[1] + (NAVY_BOT[1] - NAVY_TOP[1]) * t)
        b = int(NAVY_TOP[2] + (NAVY_BOT[2] - NAVY_TOP[2]) * t)
        for x in range(w):
            px[x, y] = (r, g, b)
    return img


def wrap(draw, text, font, max_width):
    words = text.split()
    lines, cur = [], ""
    for word in words:
        trial = (cur + " " + word).strip()
        if draw.textlength(trial, font=font) <= max_width:
            cur = trial
        else:
            if cur:
                lines.append(cur)
            cur = word
    if cur:
        lines.append(cur)
    return lines


def rounded(img, radius):
    mask = Image.new("L", img.size, 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle([0, 0, img.size[0] - 1, img.size[1] - 1], radius=radius, fill=255)
    out = Image.new("RGBA", img.size)
    out.paste(img, (0, 0), mask)
    return out


def compose(raw_path, caption, out_path, W, H, font_size, shot_w, shot_top_min):
    canvas = gradient(W, H).convert("RGBA")
    draw = ImageDraw.Draw(canvas)
    font = load_font(font_size)

    # Caption
    lines = wrap(draw, caption, font, int(W * 0.86))
    line_h = int(font_size * 1.18)
    y = int(H * 0.045)
    for line in lines:
        tw = draw.textlength(line, font=font)
        draw.text(((W - tw) / 2, y), line, font=font, fill=(255, 255, 255, 255))
        y += line_h
    # Teal underline accent
    accent_w = 160
    draw.rounded_rectangle([(W - accent_w) / 2, y + 18, (W + accent_w) / 2, y + 30], radius=6, fill=TEAL + (255,))

    shot_top = max(y + 90, shot_top_min)

    # Screenshot
    shot = Image.open(raw_path).convert("RGB")
    shot_h = int(shot_w * shot.size[1] / shot.size[0])
    max_h = H - shot_top - int(H * 0.028)
    if shot_h > max_h:
        shot_h = max_h
        shot_w2 = int(shot_h * shot.size[0] / shot.size[1])
    else:
        shot_w2 = shot_w
    shot = shot.resize((shot_w2, shot_h), Image.LANCZOS)
    radius = int(shot_w2 * 0.055)
    shot_r = rounded(shot, radius)

    x = (W - shot_w2) // 2

    # Soft shadow
    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle([x - 6, shot_top + 14, x + shot_w2 + 6, shot_top + shot_h + 34], radius=radius + 8, fill=(0, 0, 0, 140))
    shadow = shadow.filter(ImageFilter.GaussianBlur(28))
    canvas = Image.alpha_composite(canvas, shadow)

    canvas.paste(shot_r, (x, shot_top), shot_r)
    # Hairline border
    d2 = ImageDraw.Draw(canvas)
    d2.rounded_rectangle([x, shot_top, x + shot_w2 - 1, shot_top + shot_h - 1], radius=radius, outline=(255, 255, 255, 64), width=3)

    canvas.convert("RGB").save(out_path, "PNG")
    print(f"{out_path}  {W}x{H}")


IPHONE = dict(W=1320, H=2868, font_size=76, shot_w=1064, shot_top_min=430)
IPAD = dict(W=2064, H=2752, font_size=88, shot_w=1560, shot_top_min=420)

jobs = [
    ("raw-iphone/pdf-floorplan.png", "Scan a room and auto-generate a dimensioned floor plan", "final-iphone/01-floorplan.png", IPHONE),
    ("raw-iphone/pdf-p1.png", "Deliver a clean, professional report clients trust", "final-iphone/02-report-cover.png", IPHONE),
    ("raw-iphone/pdf-defects.png", "Severity-rated defects, summarized for your client", "final-iphone/03-defect-summary.png", IPHONE),
    ("raw-iphone/pdf-thermal.png", "Import drone and thermal imagery into your findings", "final-iphone/04-thermal.png", IPHONE),
    ("raw-iphone/roomscan3d.png", "Capture any room in 3D with measured dimensions", "final-iphone/05-room-3d.png", IPHONE),
    ("raw-iphone/dashboard.png", "Every inspection organized in one workspace", "final-iphone/06-dashboard.png", IPHONE),
    ("raw-iphone/annotation.png", "Circle and mark up defects right on the photo", "final-iphone/07-annotation.png", IPHONE),
    ("raw-iphone/paywall.png", "Start free — 3 full inspections, upgrade anytime", "final-iphone/08-paywall.png", IPHONE),
    ("raw-iphone/welcome.png", "The future of inspections is here", "final-iphone/09-welcome.png", IPHONE),
    ("raw-ipad/inspection-split.png", "Built for iPad — your whole inspection in one view", "final-ipad/01-split-view.png", IPAD),
    ("raw-ipad/pdf-floorplan.png", "Scan a room and auto-generate a dimensioned floor plan", "final-ipad/02-floorplan.png", IPAD),
    ("raw-ipad/pdf-defects.png", "Severity-rated defects, summarized for your client", "final-ipad/03-defect-summary.png", IPAD),
    ("raw-ipad/pdf-thermal.png", "Import drone and thermal imagery into your findings", "final-ipad/04-thermal.png", IPAD),
    ("raw-ipad/roomscan3d.png", "Capture any room in 3D with measured dimensions", "final-ipad/05-room-3d.png", IPAD),
    ("raw-ipad/dashboard.png", "Every inspection organized in one workspace", "final-ipad/06-dashboard.png", IPAD),
    ("raw-ipad/welcome.png", "The future of inspections is here", "final-ipad/07-welcome.png", IPAD),
]

import os
os.makedirs("final-iphone", exist_ok=True)
os.makedirs("final-ipad", exist_ok=True)
for raw, cap, out, spec in jobs:
    compose(raw, cap, out, **spec)
print("done")
