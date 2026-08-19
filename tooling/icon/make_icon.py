"""Generate the PencilLoop app icon.

A paragraph of faint text with a graphite pencil loop circling one passage:
what the app is for, and the loop the app is named after. No logo, no
lettering, no gradient tricks - the icon follows docs/01's rule that the
interest comes from the content, not from decoration.

Drawn at 4x and downsampled, which is how the pencil edge gets its softness.
"""
import math
from PIL import Image, ImageDraw, ImageFilter

S = 4096          # supersampled canvas
OUT = 1024
PAPER_TOP = (252, 250, 246)
PAPER_BOT = (243, 239, 232)
RULE = (203, 199, 191)     # the faint text lines
GRAPHITE = (58, 58, 60)    # .label-ish, the pencil

img = Image.new("RGB", (S, S), PAPER_TOP)
d = ImageDraw.Draw(img)

# Paper: a barely-there vertical gradient so the square is not flat white.
for y in range(S):
    t = y / (S - 1)
    d.line([(0, y), (S, y)],
           fill=tuple(round(a + (b - a) * t) for a, b in zip(PAPER_TOP, PAPER_BOT)))

# The paragraph. Line lengths vary the way real text does, and the block is
# optically centred rather than mathematically centred.
margin = S * 0.185
line_h = S * 0.0255
gap = S * 0.0655
top = S * 0.2905          # 7 lines, optically centred in the square
widths = [1.00, 0.95, 0.99, 0.92, 0.97, 0.90, 0.55]
for i, w in enumerate(widths):
    y = top + i * gap
    x1 = margin + (S - 2 * margin) * w
    d.rounded_rectangle([margin, y, x1, y + line_h], radius=line_h / 2, fill=RULE)

# The pencil loop, circling the middle of the paragraph. A real one is not an
# ellipse: it wobbles, it is drawn faster on the long sides, and it overshoots
# where it closes. All three are here.
# Around three lines in the middle of the block, starting and ending inside
# the text column: a passage somebody marked, not the whole paragraph.
cx, cy = S * 0.472, S * 0.502
rx, ry = S * 0.234, S * 0.129
start, end = -0.30, 2 * math.pi + 0.42      # overshoot past the start point

pts = []
steps = 1600
for i in range(steps + 1):
    a = start + (end - start) * i / steps
    # Two out-of-phase wobbles: a slow one for the overall shape, a fast one
    # for the tremor of a hand.
    wob = 1 + 0.021 * math.sin(a * 2.0 + 1.15) + 0.009 * math.sin(a * 7.0 + 2.4)
    pts.append((cx + rx * wob * math.cos(a), cy + ry * wob * math.sin(a)))

# Stroke on its own layer so it can be softened without touching the paper.
stroke = Image.new("L", (S, S), 0)
sd = ImageDraw.Draw(stroke)
n = len(pts)
for i, (x, y) in enumerate(pts):
    t = i / (n - 1)
    # Pencil pressure: light entering, full through the body, tapering out.
    if t < 0.06:
        p = t / 0.06
    elif t > 0.90:
        p = max(0.0, (1 - t) / 0.10)
    else:
        p = 1.0
    p = p ** 0.7
    r = (S * 0.0030) + (S * 0.0048) * p
    if r <= 0:
        continue
    sd.ellipse([x - r, y - r, x + r, y + r], fill=int(215 * (0.55 + 0.45 * p)))

stroke = stroke.filter(ImageFilter.GaussianBlur(S * 0.0011))
img.paste(Image.new("RGB", (S, S), GRAPHITE), (0, 0), stroke)

icon = img.resize((OUT, OUT), Image.LANCZOS)
icon.save("AppIcon-1024.png", "PNG", optimize=True)
print("wrote AppIcon-1024.png", icon.size)
