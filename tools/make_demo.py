"""Genera le grafiche originali del catalogo demo, l'icona e demo_catalog.json.

Uso:  python3 tools/make_demo.py   (dalla radice del repository)
"""
import json, math, os, random
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(ROOT, "ios/Lumen/Resources/Assets.xcassets")
FONT_BOLD = "/usr/share/fonts/truetype/google-fonts/Poppins-Bold.ttf"
FONT_DISPLAY = "/usr/share/fonts/opentype/inter/InterDisplay-Bold.otf"

GTV = "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/"

# id, titolo, tipo, anno, tag, badge, rating, palette (3 colori), motivo, trama
ITEMS = [
    ("sintel", "Sintel", "movie", 2010, ["Fantasy", "Avventura", "Emozionante"], None, "13+",
     ["#1b0f2e", "#8a2be2", "#ffb347"], "rings",
     "Una giovane guerriera attraversa terre ostili per ritrovare il cucciolo di drago che aveva salvato e cresciuto."),
    ("bbb", "Big Buck Bunny", "movie", 2008, ["Animazione", "Commedia", "Per tutti"], None, "T",
     ["#0e2a1a", "#3cb371", "#ffe066"], "dots",
     "Un coniglio gigante e pacifico decide che è ora di dare una lezione ai tre roditori che tormentano il bosco."),
    ("tears", "Tears of Steel", "movie", 2012, ["Fantascienza", "Azione"], "Aggiunto di recente", "13+",
     ["#06141f", "#1e90ff", "#ff4d6d"], "grid",
     "Ad Amsterdam, un gruppo di scienziati tenta di salvare il mondo da robot ostili ricreando un momento del passato."),
    ("elephants", "Elephants Dream", "movie", 2006, ["Fantascienza", "Surreale", "Cupo"], None, "13+",
     ["#1a1208", "#c47f2c", "#5ad1c9"], "stripes",
     "Due personaggi esplorano una macchina infinita e misteriosa, dove nulla è come sembra."),
    ("openmovies", "Open Movie Collection", "series", 2024, ["Antologia", "Animazione", "Creativa"], "Nuova stagione", "13+",
     ["#10101e", "#ff6b35", "#7c5cff"], "waves",
     "I cortometraggi aperti più celebri, raccolti in una serie: dietro ogni episodio un mondo diverso."),
    ("shorts", "Brevi Grandi Schermi", "series", 2023, ["Brevi", "Leggero", "Divertente"], "Nuovi episodi", "T",
     ["#1f0a1a", "#ff3d7f", "#ffd23f"], "dots",
     "Cinque mini episodi da quindici secondi: fuoco, fughe, risate, strade e disastri in cucina."),
    ("garage-subaru", "Fuoristrada, istruzioni per l'uso", "movie", 2019, ["Documentario", "Motori"], None, "T",
     ["#0b1d14", "#7fb069", "#e6e6e6"], "stripes",
     "Una prova su strada e su sterrato per capire come si comporta una station wagon fuori dall'asfalto."),
    ("garage-gti", "La compatta sportiva", "movie", 2019, ["Documentario", "Motori"], None, "T",
     ["#1d0b0b", "#e63946", "#f1faee"], "grid",
     "Una prova completa di una piccola sportiva: motore, guida, abitacolo e prezzo."),
    ("garage-bullrun", "Verso il Bullrun", "movie", 2019, ["Documentario", "Viaggio", "Motori"], "Aggiunto di recente", "T",
     ["#0b0f1d", "#4361ee", "#f72585"], "waves",
     "Il racconto della preparazione e della partenza per un raduno su strada lungo tutto il Paese."),
    ("garage-grand", "Auto con mille dollari", "movie", 2019, ["Documentario", "Motori", "Ironico"], None, "T",
     ["#1d170b", "#f4a261", "#2a9d8f"], "rings",
     "Che auto si riesce davvero a comprare con soli mille dollari? Una sfida tra annunci e officina."),
    ("hls-test", "Segnale di prova HLS", "movie", 2026, ["Test tecnico", "Streaming adattivo"], None, None,
     ["#0d0d0d", "#9e9e9e", "#00e5ff"], "grid",
     "Flusso di test Apple con più qualità: utile per verificare che il player passi da una risoluzione all'altra."),
]

STREAMS = {
    "sintel": "https://bitdash-a.akamaihd.net/content/sintel/hls/playlist.m3u8",
    "bbb": "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8",
    "tears": "https://demo.unified-streaming.com/k8s/features/stable/video/tears-of-steel/tears-of-steel.ism/.m3u8",
    "elephants": GTV + "ElephantsDream.mp4",
    "garage-subaru": GTV + "SubaruOutbackOnStreetAndDirt.mp4",
    "garage-gti": GTV + "VolkswagenGTIReview.mp4",
    "garage-bullrun": GTV + "WeAreGoingOnBullrun.mp4",
    "garage-grand": GTV + "WhatCarCanYouGetForAGrand.mp4",
    "hls-test": "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8",
}
FALLBACK_MP4 = {
    "sintel": GTV + "Sintel.mp4",
    "bbb": GTV + "BigBuckBunny.mp4",
    "tears": GTV + "TearsOfSteel.mp4",
}
DURATIONS = {"sintel": 888, "bbb": 596, "tears": 734, "elephants": 653, "garage-subaru": 594,
             "garage-gti": 287, "garage-bullrun": 47, "garage-grand": 181, "hls-test": 1800}


def hex2rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def art(size, palette, motif, seed):
    w, h = size
    c0, c1, c2 = [hex2rgb(x) for x in palette]
    img = Image.new("RGB", size, c0)
    px = img.load()
    for y in range(h):
        for x in range(0, w):
            t = (y / h) * 0.75 + (x / w) * 0.25
            px[x, y] = lerp(c1, c0, min(1, t * 1.15))
    rnd = random.Random(seed)
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    s = min(w, h)
    if motif == "rings":
        cx, cy = w * rnd.uniform(0.35, 0.65), h * 0.38
        for i in range(9, 0, -1):
            r = s * 0.07 * i
            col = c2 + (int(28 + 12 * (9 - i)),)
            d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=col, width=max(2, s // 90))
        d.ellipse([cx - s * .12, cy - s * .12, cx + s * .12, cy + s * .12], fill=c2 + (230,))
    elif motif == "dots":
        for _ in range(70):
            r = rnd.uniform(s * .01, s * .07)
            x, y = rnd.uniform(0, w), rnd.uniform(0, h * .75)
            d.ellipse([x - r, y - r, x + r, y + r], fill=(c2 if rnd.random() > .4 else c1) + (rnd.randint(70, 210),))
    elif motif == "grid":
        step = s // 9
        for i in range(-2, w // step + 3):
            d.line([(i * step, 0), (i * step + h * .35, h)], fill=c2 + (60,), width=2)
        for j in range(0, h // step + 1):
            d.line([(0, j * step), (w, j * step)], fill=c1 + (70,), width=1)
        d.rectangle([w * .18, h * .16, w * .82, h * .52], outline=c2 + (220,), width=max(3, s // 70))
    elif motif == "stripes":
        for i in range(14):
            x = rnd.uniform(-w * .2, w)
            bw = rnd.uniform(s * .02, s * .12)
            d.polygon([(x, 0), (x + bw, 0), (x + bw + h * .4, h), (x + h * .4, h)],
                      fill=(c2 if i % 3 == 0 else c1) + (rnd.randint(50, 150),))
    elif motif == "waves":
        for k in range(12):
            pts = []
            base = h * (0.12 + k * 0.05)
            amp = s * rnd.uniform(.02, .06)
            ph = rnd.uniform(0, 6.28)
            for x in range(0, w + 10, 8):
                pts.append((x, base + amp * math.sin(x / w * 6.28 * 1.5 + ph)))
            d.line(pts, fill=(c2 if k % 2 else c1) + (170,), width=max(2, s // 80))
    layer = layer.filter(ImageFilter.GaussianBlur(0.6))
    img = Image.alpha_composite(img.convert("RGBA"), layer)
    # vignettatura in basso per leggere il titolo
    shade = Image.new("RGBA", size, (0, 0, 0, 0))
    sd = ImageDraw.Draw(shade)
    for y in range(h):
        t = max(0, (y / h - 0.45) / 0.55)
        sd.line([(0, y), (w, y)], fill=(0, 0, 0, int(220 * t ** 1.4)))
    return Image.alpha_composite(img, shade)


def fit_font(draw, text, path, max_w, start):
    size = start
    while size > 10:
        f = ImageFont.truetype(path, size)
        if draw.textlength(text, font=f) <= max_w:
            return f
        size -= 2
    return ImageFont.truetype(path, 10)


def wrap_title(draw, title, path, max_w, start):
    words = title.upper().split()
    lines = [title.upper()]
    if len(words) > 1:
        f = ImageFont.truetype(path, start)
        if draw.textlength(title.upper(), font=f) > max_w:
            mid = max(1, len(words) // 2)
            lines = [" ".join(words[:mid]), " ".join(words[mid:])]
    font = min((fit_font(draw, l, path, max_w, start) for l in lines), key=lambda f: f.size)
    return lines, font


def title_on(img, title, kind, accent, wide):
    d = ImageDraw.Draw(img)
    w, h = img.size
    max_w = w * (0.55 if wide else 0.86)
    lines, font = wrap_title(d, title, FONT_DISPLAY, max_w, int(h * (0.13 if wide else 0.095)))
    lh = font.size * 1.02
    y = h * (0.62 if wide else 0.70) - (len(lines) - 1) * lh
    for line in lines:
        tw = d.textlength(line, font=font)
        x = w * 0.06 if wide else (w - tw) / 2
        d.text((x + 2, y + 3), line, font=font, fill=(0, 0, 0, 160))
        d.text((x, y), line, font=font, fill=(255, 255, 255, 255))
        y += lh
    if kind == "series":
        small = ImageFont.truetype(FONT_BOLD, int(h * (0.045 if wide else 0.032)))
        label = "S E R I E"
        tw = d.textlength(label, font=small)
        x = w * 0.06 if wide else (w - tw) / 2
        d.text((x, y + h * 0.01), label, font=small, fill=hex2rgb(accent) + (255,))
    return img


def save_imageset(name, img):
    folder = os.path.join(ASSETS, f"{name}.imageset")
    os.makedirs(folder, exist_ok=True)
    img.convert("RGB").save(os.path.join(folder, f"{name}.jpg"), quality=84, optimize=True)
    with open(os.path.join(folder, "Contents.json"), "w") as f:
        json.dump({"images": [{"idiom": "universal", "filename": f"{name}.jpg"}],
                   "info": {"version": 1, "author": "xcode"}}, f, indent=2)


def make_icon():
    s = 1024
    img = art((s, s), ["#140b2e", "#7c5cff", "#ffffff"], "rings", 7).convert("RGBA")
    d = ImageDraw.Draw(img)
    f = ImageFont.truetype(FONT_DISPLAY, 620)
    tw = d.textlength("L", font=f)
    d.text(((s - tw) / 2 + 8, 150 + 10), "L", font=f, fill=(0, 0, 0, 120))
    d.text(((s - tw) / 2, 150), "L", font=f, fill=(255, 255, 255, 255))
    folder = os.path.join(ASSETS, "AppIcon.appiconset")
    os.makedirs(folder, exist_ok=True)
    img.convert("RGB").save(os.path.join(folder, "icon-1024.png"))
    with open(os.path.join(folder, "Contents.json"), "w") as fp:
        json.dump({"images": [{"filename": "icon-1024.png", "idiom": "universal", "platform": "ios",
                               "size": "1024x1024"}], "info": {"version": 1, "author": "xcode"}}, fp, indent=2)


def main():
    os.makedirs(ASSETS, exist_ok=True)
    with open(os.path.join(ASSETS, "Contents.json"), "w") as f:
        json.dump({"info": {"version": 1, "author": "xcode"}}, f, indent=2)
    acc = os.path.join(ASSETS, "AccentColor.colorset")
    os.makedirs(acc, exist_ok=True)
    with open(os.path.join(acc, "Contents.json"), "w") as f:
        json.dump({"colors": [{"idiom": "universal", "color": {"color-space": "srgb", "components": {
            "red": "0.486", "green": "0.361", "blue": "1.000", "alpha": "1.000"}}}],
            "info": {"version": 1, "author": "xcode"}}, f, indent=2)
    make_icon()

    save_imageset("hero-sintel", art((720, 1030), ITEMS[0][7], ITEMS[0][8], 42))
    items = {}
    for i, (iid, title, kind, year, tags, badge, rating, pal, motif, overview) in enumerate(ITEMS):
        poster = title_on(art((480, 720), pal, motif, i), title, kind, pal[2], wide=False)
        backdrop = title_on(art((960, 540), pal, motif, i + 100), title, kind, pal[2], wide=True)
        save_imageset(f"poster-{iid}", poster)
        save_imageset(f"backdrop-{iid}", backdrop)
        item = {"id": iid, "title": title, "kind": kind, "year": year, "tags": tags,
                "poster": f"bundle://poster-{iid}", "backdrop": f"bundle://backdrop-{iid}",
                "overview": overview}
        if badge: item["badge"] = badge
        if rating: item["rating"] = rating
        items[iid] = item

    def it(iid, **extra):
        d = dict(items[iid]); d.update(extra); return d

    top = ["sintel", "openmovies", "tears", "bbb", "shorts", "elephants", "garage-bullrun", "garage-gti", "garage-grand", "garage-subaru"]
    home = {
        "hero": it("sintel", poster="bundle://hero-sintel"),
        "sections": [
            {"id": "nuovi", "title": "Altri titoli da guardare", "style": "poster",
             "items": [it(x) for x in ["openmovies", "tears", "shorts", "bbb", "garage-bullrun", "elephants"]]},
            {"id": "top10", "title": "La Top 10 di oggi", "style": "top10",
             "items": [it(x, rank=n + 1) for n, x in enumerate(top)]},
            {"id": "animazione", "title": "Animazione e fantasy", "style": "poster",
             "items": [it(x) for x in ["sintel", "bbb", "elephants", "openmovies", "shorts"]]},
            {"id": "esclusivi", "title": f"Solo su Lumen", "style": "large",
             "items": [it(x) for x in ["openmovies", "tears", "shorts", "sintel"]]},
            {"id": "motori", "title": "Documentari a motori", "style": "wide",
             "items": [it(x) for x in ["garage-bullrun", "garage-gti", "garage-grand", "garage-subaru"]]},
            {"id": "scifi", "title": "Fantascienza e mondi possibili", "style": "poster",
             "items": [it(x) for x in ["tears", "elephants", "hls-test", "sintel", "openmovies"]]},
            {"id": "test", "title": "Per sviluppatori: test dello streaming", "style": "wide",
             "items": [it("hls-test"), it("bbb"), it("tears")]},
        ],
    }

    def ep(eid, n, title, overview, dur, still):
        return {"id": eid, "number": n, "title": title, "overview": overview, "duration": dur,
                "still": f"bundle://backdrop-{still}"}

    details = {}
    for iid, item in items.items():
        if item["kind"] == "movie":
            details[iid] = {"item": item, "duration": DURATIONS.get(iid), "cast": ["Blender Foundation"] if iid in ("sintel", "bbb", "tears", "elephants") else []}
    details["openmovies"] = {"item": items["openmovies"], "cast": ["Blender Foundation", "Blender Studio"], "seasons": [
        {"id": "om-s1", "number": 1, "episodes": [
            ep("om-1-1", 1, "Il sogno dell'elefante", "Una macchina infinita e due esploratori che non la vedono allo stesso modo.", 653, "elephants"),
            ep("om-1-2", 2, "Il coniglio gigante", "La vendetta più gentile del bosco.", 596, "bbb")]},
        {"id": "om-s2", "number": 2, "episodes": [
            ep("om-2-1", 1, "La ragazza e il drago", "Un viaggio lungo una vita per ritrovare un amico.", 888, "sintel"),
            ep("om-2-2", 2, "Lacrime d'acciaio", "Robot, Amsterdam e una seconda possibilità.", 734, "tears")]},
    ]}
    details["shorts"] = {"item": items["shorts"], "cast": [], "seasons": [
        {"id": "sh-s1", "number": 1, "episodes": [
            ep("sh-1", 1, "Fiamme", "Quindici secondi di fuoco.", 15, "shorts"),
            ep("sh-2", 2, "Fughe", "Una fuga in pieno stile action.", 15, "shorts"),
            ep("sh-3", 3, "Risate", "Il divertimento in formato tascabile.", 60, "shorts"),
            ep("sh-4", 4, "In strada", "Un giro in auto, senza fretta.", 15, "shorts"),
            ep("sh-5", 5, "Disastri", "Quando in cucina qualcosa va storto.", 15, "shorts")]},
    ]}

    streams = {k: [{"url": v, "quality": "Auto"}] for k, v in STREAMS.items()}
    for k, v in FALLBACK_MP4.items():
        streams[k].append({"url": v, "quality": "MP4"})
    ep_streams = {"om-1-1": STREAMS["elephants"], "om-1-2": STREAMS["bbb"], "om-2-1": STREAMS["sintel"],
                  "om-2-2": STREAMS["tears"], "sh-1": GTV + "ForBiggerBlazes.mp4", "sh-2": GTV + "ForBiggerEscapes.mp4",
                  "sh-3": GTV + "ForBiggerFun.mp4", "sh-4": GTV + "ForBiggerJoyrides.mp4", "sh-5": GTV + "ForBiggerMeltdowns.mp4"}
    for k, v in ep_streams.items():
        streams[k] = [{"url": v, "quality": "Auto"}]

    clips = [
        {"id": "c1", "item": it("shorts", title="Brevi Grandi Schermi: Fiamme"), "video": GTV + "ForBiggerBlazes.mp4"},
        {"id": "c2", "item": it("bbb"), "video": GTV + "BigBuckBunny.mp4"},
        {"id": "c3", "item": it("shorts", title="Brevi Grandi Schermi: Fughe"), "video": GTV + "ForBiggerEscapes.mp4"},
        {"id": "c4", "item": it("sintel"), "video": GTV + "Sintel.mp4"},
        {"id": "c5", "item": it("shorts", title="Brevi Grandi Schermi: Risate"), "video": GTV + "ForBiggerFun.mp4"},
        {"id": "c6", "item": it("tears"), "video": GTV + "TearsOfSteel.mp4"},
        {"id": "c7", "item": it("garage-gti"), "video": GTV + "VolkswagenGTIReview.mp4"},
    ]
    # Le clip della serie devono aprire la scheda della serie: id invariato, titolo della clip.
    for c in clips:
        if c["item"]["id"] == "shorts":
            c["item"]["overview"] = items["shorts"]["overview"]

    catalog = {"home": home, "details": details, "streams": streams, "clips": clips}
    out = os.path.join(ROOT, "ios/Lumen/Resources/demo_catalog.json")
    with open(out, "w") as f:
        json.dump(catalog, f, ensure_ascii=False, indent=1)
    print("ok", out, len(items), "titoli")


if __name__ == "__main__":
    main()
