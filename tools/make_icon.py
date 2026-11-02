"""Icona di Lumen in stile Liquid Glass, con varianti per Home chiara, scura e colorata (iOS 18+).

Uso:  python3 tools/make_icon.py   (dalla radice del repository)
"""
import json, math, os
from PIL import Image, ImageDraw, ImageFilter, ImageChops

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "ios/Lumen/Resources/Assets.xcassets/AppIcon.appiconset")
S = 2048  # disegno in supersampling, poi riduco a 1024


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))


def radial(size, center, radius, color, alpha):
    """Macchia di luce sfumata."""
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    cx, cy = center
    d.ellipse([cx - radius, cy - radius, cx + radius, cy + radius], fill=color + (alpha,))
    return layer.filter(ImageFilter.GaussianBlur(radius * 0.45))


def background(variant):
    if variant == "dark":
        base = Image.new("RGBA", (S, S), (8, 6, 16, 255))
        blobs = [((0.25, 0.2), 0.55, (86, 52, 220), 170), ((0.85, 0.85), 0.5, (255, 92, 70), 110),
                 ((0.8, 0.15), 0.35, (40, 160, 255), 90)]
    elif variant == "tinted":
        return Image.new("RGBA", (S, S), (0, 0, 0, 255))
    else:
        base = Image.new("RGBA", (S, S), (0, 0, 0, 255))
        px = base.load()
        top, bottom = (54, 28, 140), (16, 8, 40)
        for y in range(0, S, 2):
            c = lerp(top, bottom, y / S) + (255,)
            for x in range(S):
                px[x, y] = c
                if y + 1 < S:
                    px[x, y + 1] = c
        blobs = [((0.2, 0.15), 0.6, (124, 92, 255), 230), ((0.9, 0.9), 0.55, (255, 107, 70), 200),
                 ((0.85, 0.12), 0.38, (60, 190, 255), 160), ((0.1, 0.95), 0.4, (255, 60, 160), 120)]
    for (fx, fy), fr, col, a in blobs:
        base = Image.alpha_composite(base, radial(S, (fx * S, fy * S), fr * S, col, a))
    return base


def rounded_mask(box, radius):
    m = Image.new("L", (S, S), 0)
    ImageDraw.Draw(m).rounded_rectangle(box, radius=radius, fill=255)
    return m


def play_mask(cx, cy, r, corner):
    """Triangolo 'play' con angoli arrotondati."""
    pts = [(cx - r * 0.55, cy - r * 0.9), (cx - r * 0.55, cy + r * 0.9), (cx + r * 0.95, cy)]
    m = Image.new("L", (S, S), 0)
    ImageDraw.Draw(m).polygon(pts, fill=255)
    m = m.filter(ImageFilter.GaussianBlur(corner))
    return m.point(lambda v: 255 if v > 128 else int(v * 2) if v > 64 else 0)


def glass_panel(img, box, radius, variant):
    """Lastra di vetro: sfocatura dello sfondo, velo chiaro, bordo luminoso e riflesso speculare."""
    mask = rounded_mask(box, radius)
    blurred = img.filter(ImageFilter.GaussianBlur(60))
    veil = Image.new("RGBA", (S, S), (255, 255, 255, 46 if variant != "tinted" else 70))
    panel = Image.alpha_composite(blurred, veil)
    img = Image.composite(panel, img, mask)

    # gradiente verticale interno (più chiaro in alto)
    grad = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    gd = ImageDraw.Draw(grad)
    x0, y0, x1, y1 = box
    for y in range(int(y0), int(y1), 2):
        t = (y - y0) / (y1 - y0)
        gd.line([(x0, y), (x1, y)], fill=(255, 255, 255, int(70 * (1 - t) ** 2)), width=2)
    img = Image.composite(Image.alpha_composite(img, grad), img, mask)

    # bordo: anello luminoso più forte in alto a sinistra
    ring = Image.new("L", (S, S), 0)
    rd = ImageDraw.Draw(ring)
    rd.rounded_rectangle(box, radius=radius, outline=255, width=10)
    ring = ring.filter(ImageFilter.GaussianBlur(2))
    light = Image.new("L", (S, S), 0)
    lp = light.load()
    for y in range(0, S, 4):
        for x in range(0, S, 4):
            v = int(255 * max(0.18, 1 - ((x - x0) + (y - y0)) / ((x1 - x0) + (y1 - y0)) * 1.3))
            for dy in range(4):
                for dx in range(4):
                    lp[x + dx, y + dy] = v
    ring = ImageChops.multiply(ring, light)
    img = Image.composite(Image.new("RGBA", (S, S), (255, 255, 255, 255)), img, ring)

    # riflesso speculare a mezzaluna in alto
    spec = Image.new("L", (S, S), 0)
    sd = ImageDraw.Draw(spec)
    w, h = x1 - x0, y1 - y0
    sd.ellipse([x0 + w * 0.08, y0 - h * 0.35, x1 - w * 0.08, y0 + h * 0.32], fill=110)
    spec = ImageChops.multiply(spec.filter(ImageFilter.GaussianBlur(30)), mask)
    img = Image.composite(Image.new("RGBA", (S, S), (255, 255, 255, 255)), img, spec)
    return img


def make(variant):
    img = background(variant)

    # fasci di luce che escono dalla lente (il "lumen")
    if variant != "tinted":
        beams = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        bd = ImageDraw.Draw(beams)
        for i, (ang, w, a) in enumerate([(-28, 120, 60), (-8, 70, 45), (14, 160, 55), (33, 90, 40)]):
            r = math.radians(ang)
            cx, cy = S * 0.5, S * 0.52
            far = S * 1.2
            dx, dy = math.cos(r) * far, math.sin(r) * far
            nx, ny = -math.sin(r) * w, math.cos(r) * w
            bd.polygon([(cx, cy), (cx + dx + nx, cy + dy + ny), (cx + dx - nx, cy + dy - ny)],
                       fill=(255, 230, 255, a))
        img = Image.alpha_composite(img, beams.filter(ImageFilter.GaussianBlur(40)))

    # ombra morbida sotto la lastra
    box = (S * 0.2, S * 0.22, S * 0.8, S * 0.78)
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((box[0], box[1] + 60, box[2], box[3] + 60), radius=S * 0.17,
                                             fill=(0, 0, 0, 150 if variant != "tinted" else 0))
    img = Image.alpha_composite(img, shadow.filter(ImageFilter.GaussianBlur(70)))

    img = glass_panel(img, box, S * 0.17, variant)

    # simbolo play luminoso al centro
    cx, cy, r = S * 0.515, S * 0.5, S * 0.17
    pm = play_mask(cx, cy, r, 22)
    glow = pm.filter(ImageFilter.GaussianBlur(50))
    if variant == "tinted":
        fill_top, fill_bottom, glow_col = (255, 255, 255), (200, 200, 200), (255, 255, 255)
    else:
        fill_top, fill_bottom, glow_col = (255, 255, 255), (255, 196, 170), (255, 150, 120)
    img = Image.composite(Image.new("RGBA", (S, S), glow_col + (255,)), img,
                          glow.point(lambda v: int(v * 0.55)))
    fill = Image.new("RGBA", (S, S))
    fd = ImageDraw.Draw(fill)
    for y in range(S):
        t = min(1, max(0, (y - (cy - r)) / (2 * r)))
        fd.line([(0, y), (S, y)], fill=lerp(fill_top, fill_bottom, t) + (255,))
    img = Image.composite(fill, img, pm)

    out = img.convert("RGB").resize((1024, 1024), Image.LANCZOS)
    if variant == "tinted":
        out = out.convert("L").convert("RGB")
    return out


def main():
    os.makedirs(OUT, exist_ok=True)
    for f in os.listdir(OUT):
        if f.endswith(".png"):
            os.remove(os.path.join(OUT, f))
    files = {"any": "icon-1024.png", "dark": "icon-1024-dark.png", "tinted": "icon-1024-tinted.png"}
    for variant, name in files.items():
        make("light" if variant == "any" else variant).save(os.path.join(OUT, name))
    images = [
        {"filename": files["any"], "idiom": "universal", "platform": "ios", "size": "1024x1024"},
        {"appearances": [{"appearance": "luminosity", "value": "dark"}], "filename": files["dark"],
         "idiom": "universal", "platform": "ios", "size": "1024x1024"},
        {"appearances": [{"appearance": "luminosity", "value": "tinted"}], "filename": files["tinted"],
         "idiom": "universal", "platform": "ios", "size": "1024x1024"},
    ]
    with open(os.path.join(OUT, "Contents.json"), "w") as fp:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, fp, indent=2)
    print("Icone generate in", OUT)


if __name__ == "__main__":
    main()
