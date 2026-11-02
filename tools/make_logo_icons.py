"""Crea le icone dell'app dalle proposte di logo (tools/assets/logo-proposals.jpg).

Opzione 2 = icona principale; opzioni 1, 3, 4 = icone alternative selezionabili dall'utente.
Uso:  python3 tools/make_logo_icons.py
"""
import json, os
from PIL import Image, ImageDraw, ImageFilter, ImageEnhance

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "tools/assets/logo-proposals.jpg")
ASSETS = os.path.join(ROOT, "ios/Lumen/Resources/Assets.xcassets")

# Riquadri dei simboli nell'immagine originale (coordinate su base 1998 px di larghezza)
BOXES = {1: (330, 215, 760, 460), 2: (1340, 215, 1720, 465), 3: (380, 690, 720, 935), 4: (1330, 665, 1700, 935)}


def background(color_a, color_b):
    s = 1024
    bg = Image.new("RGB", (s, s))
    px = bg.load()
    for y in range(s):
        for x in range(s):
            t = min(1, ((x / s) * 0.4 + (y / s) * 0.6))
            px[x, y] = tuple(int(color_a[i] + (color_b[i] - color_a[i]) * t) for i in range(3))
    return bg


def icon(src, box):
    f = src.width / 1998
    crop = src.crop(tuple(int(v * f) for v in box))
    # colore di fondo campionato dagli angoli del ritaglio
    corners = [crop.getpixel((2, 2)), crop.getpixel((crop.width - 3, 2)),
               crop.getpixel((2, crop.height - 3)), crop.getpixel((crop.width - 3, crop.height - 3))]
    base = tuple(sum(c[i] for c in corners) // 4 for i in range(3))
    bg = background(tuple(min(255, v + 10) for v in base), tuple(max(0, v - 8) for v in base))

    target = 860
    scale = target / max(crop.width, crop.height)
    mark = crop.resize((int(crop.width * scale), int(crop.height * scale)), Image.LANCZOS)
    mark = mark.filter(ImageFilter.UnsharpMask(radius=2, percent=60, threshold=2))
    mark = ImageEnhance.Color(mark).enhance(1.08)

    # maschera sfumata ai bordi per fondere il ritaglio con lo sfondo
    mask = Image.new("L", mark.size, 0)
    feather = 40
    ImageDraw.Draw(mask).rounded_rectangle([feather, feather, mark.width - feather, mark.height - feather],
                                           radius=feather, fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(feather / 2))
    x = (1024 - mark.width) // 2
    y = (1024 - mark.height) // 2
    bg.paste(mark, (x, y), mask)
    return bg


def write_iconset(name, img, extra_variants=False):
    folder = os.path.join(ASSETS, f"{name}.appiconset")
    os.makedirs(folder, exist_ok=True)
    for f in os.listdir(folder):
        os.remove(os.path.join(folder, f))
    img.save(os.path.join(folder, "icon-1024.png"))
    images = [{"filename": "icon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}]
    if extra_variants:
        img.save(os.path.join(folder, "icon-1024-dark.png"))
        img.convert("L").convert("RGB").save(os.path.join(folder, "icon-1024-tinted.png"))
        images += [
            {"appearances": [{"appearance": "luminosity", "value": "dark"}], "filename": "icon-1024-dark.png",
             "idiom": "universal", "platform": "ios", "size": "1024x1024"},
            {"appearances": [{"appearance": "luminosity", "value": "tinted"}], "filename": "icon-1024-tinted.png",
             "idiom": "universal", "platform": "ios", "size": "1024x1024"},
        ]
    with open(os.path.join(folder, "Contents.json"), "w") as fp:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, fp, indent=2)


def write_preview(name, img):
    folder = os.path.join(ASSETS, f"{name}.imageset")
    os.makedirs(folder, exist_ok=True)
    img.resize((360, 360), Image.LANCZOS).save(os.path.join(folder, f"{name}.png"))
    with open(os.path.join(folder, "Contents.json"), "w") as fp:
        json.dump({"images": [{"idiom": "universal", "filename": f"{name}.png"}],
                   "info": {"author": "xcode", "version": 1}}, fp, indent=2)


def main():
    src = Image.open(SRC).convert("RGB")
    for n, box in BOXES.items():
        img = icon(src, box)
        if n == 2:
            write_iconset("AppIcon", img, extra_variants=True)
        else:
            write_iconset(f"AppIcon-Opzione{n}", img)
        write_preview(f"IconPreview-{n}", img)
    print("ok")


if __name__ == "__main__":
    main()
