#!/usr/bin/env python3
"""Generates the DutyPing app icon and in-app logo.

Everything is drawn at 4x and downsampled, which is cheaper than fighting
PIL's lack of antialiased primitives. Run from the project root:

    python3 tools/make_icon.py
"""
from pathlib import Path
from PIL import Image, ImageDraw

SS = 4  # supersampling factor
ROOT = Path(__file__).resolve().parent.parent
ICONSET = ROOT / "Sources/Assets.xcassets/AppIcon.appiconset"
LOGOSET = ROOT / "Sources/Assets.xcassets/Logo.imageset"

INDIGO = (92, 107, 242)
VIOLET = (140, 115, 250)
WHITE = (255, 255, 255)


def gradient(size):
    """Diagonal indigo to violet, matching Theme.gradient in the app."""
    base = Image.new("RGB", (size, size))
    pixels = base.load()
    for y in range(size):
        for x in range(size):
            t = (x + y) / (2 * size - 2)
            pixels[x, y] = tuple(
                round(INDIGO[i] + (VIOLET[i] - INDIGO[i]) * t) for i in range(3)
            )
    return base


def draw_mark(img, size):
    """A clock face with ping waves radiating from it."""
    d = ImageDraw.Draw(img, "RGBA")
    # Offset down-left so the waves have room to breathe without touching the
    # corner, which reads as clipped rather than radiating.
    cx = size * 0.435
    cy = size * 0.565
    r = size * 0.235
    stroke = size * 0.052

    # Ping waves, fading outward, confined to the upper-right quadrant so the
    # clock stays the dominant shape.
    for scale, alpha in ((1.42, 155), (1.72, 100), (2.02, 58)):
        rr = r * scale
        d.arc(
            [cx - rr, cy - rr, cx + rr, cy + rr],
            start=-68, end=-22,
            fill=WHITE + (alpha,),
            width=round(stroke * 0.72),
        )

    # Clock face.
    d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=WHITE, width=round(stroke))

    # Hands: roughly 10:10, the flattering watch-advert pose.
    d.line([cx, cy, cx, cy - r * 0.58], fill=WHITE, width=round(stroke * 0.88))
    d.line([cx, cy, cx + r * 0.46, cy + r * 0.30], fill=WHITE, width=round(stroke * 0.88))
    d.ellipse(
        [cx - stroke * 0.42, cy - stroke * 0.42, cx + stroke * 0.42, cy + stroke * 0.42],
        fill=WHITE,
    )


def render(size, rounded=False):
    big = size * SS
    img = gradient(big).convert("RGBA")
    draw_mark(img, big)

    if rounded:
        # Only the in-app logo needs its own corners; iOS masks the app icon.
        mask = Image.new("L", (big, big), 0)
        ImageDraw.Draw(mask).rounded_rectangle(
            [0, 0, big - 1, big - 1], radius=big * 0.225, fill=255
        )
        img.putalpha(mask)

    return img.resize((size, size), Image.LANCZOS)


def write_json(path, body):
    path.write_text(body)


def main():
    ICONSET.mkdir(parents=True, exist_ok=True)
    LOGOSET.mkdir(parents=True, exist_ok=True)

    # App icon must be opaque with no alpha channel or the App Store tooling
    # and some iOS versions reject it.
    render(1024).convert("RGB").save(ICONSET / "icon-1024.png")

    write_json(ICONSET / "Contents.json", """{
  "images" : [
    {
      "filename" : "icon-1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
""")

    for scale in (1, 2, 3):
        render(180 * scale, rounded=True).save(LOGOSET / f"logo@{scale}x.png")

    write_json(LOGOSET / "Contents.json", """{
  "images" : [
    { "filename" : "logo@1x.png", "idiom" : "universal", "scale" : "1x" },
    { "filename" : "logo@2x.png", "idiom" : "universal", "scale" : "2x" },
    { "filename" : "logo@3x.png", "idiom" : "universal", "scale" : "3x" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
""")

    write_json(ROOT / "Sources/Assets.xcassets/Contents.json", """{
  "info" : { "author" : "xcode", "version" : 1 }
}
""")

    print("wrote icon + logo assets")


if __name__ == "__main__":
    main()
