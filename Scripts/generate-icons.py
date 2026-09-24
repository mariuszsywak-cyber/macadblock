"""Generuje całą rodzinę ikon MacAdBlock z jednego znaku: tarcza z ptaszkiem.

Uruchomienie: python3 Scripts/generate-icons.py
Wymaga tylko biblioteki Pillow. Powstają:
  Resources/Assets.xcassets/AppIcon.appiconset/*.png        (ikona aplikacji, 16-1024 px)
  Resources/Assets.xcassets/MacAdBlockShield.imageset/*.png (odznaka w interfejsie aplikacji)
  Resources/Assets.xcassets/MenuBarShield.imageset/*.png    (glif szablonowy, zapas dla paska menu)
  Sources/SafariWebExtension/Resources/icons/extension-icon-*.png (lista rozszerzeń Safari)
  Sources/SafariWebExtension/Resources/icons/toolbar-icon-*.png   (glif w pasku Safari)
Pasek menu aplikacji korzysta z SF Symbols, więc nie wymaga własnego pliku.
"""
from PIL import Image, ImageDraw, ImageFilter
import os

SS = 4  # nadpróbkowanie

# --- paleta zgodna z SentinelTheme w aplikacji ---
TILE_TOP = (28, 36, 33)
TILE_BOTTOM = (7, 12, 11)
SHIELD_TOP = (108, 243, 193)
SHIELD_BOTTOM = (18, 168, 118)
CHECK = (255, 255, 255)


def bezier(points, steps=64):
    """Próbkuje krzywą Beziera dowolnego stopnia."""
    result = []
    n = len(points) - 1
    for step in range(steps + 1):
        t = step / steps
        x = y = 0.0
        for index, (px, py) in enumerate(points):
            binom = 1
            for k in range(index):
                binom = binom * (n - k) // (k + 1)
            weight = binom * (t ** index) * ((1 - t) ** (n - index))
            x += px * weight
            y += py * weight
        result.append((x, y))
    return result


def shield_path(box):
    """Tarcza w układzie 0..100 x 0..110, przeskalowana do (x, y, w, h)."""
    x0, y0, w, h = box
    raw = []
    raw += bezier([(4, 24), (18, 8), (50, 3)], 40)          # górna lewa krzywa
    raw += bezier([(50, 3), (82, 8), (96, 24)], 40)          # górna prawa krzywa
    raw += [(96, 24), (96, 57)]                              # prawy bok
    raw += bezier([(96, 57), (94, 88), (50, 107)], 50)       # prawy spad do czubka
    raw += bezier([(50, 107), (6, 88), (4, 57)], 50)         # lewy spad
    raw += [(4, 57), (4, 24)]
    return [(x0 + px / 100 * w, y0 + py / 110 * h) for px, py in raw]


def superellipse(box, exponent=5.0, steps=400):
    """Kwadrat o zaokrąglonych bokach w stylu macOS (superelipsa)."""
    x0, y0, w, h = box
    cx, cy, rx, ry = x0 + w / 2, y0 + h / 2, w / 2, h / 2
    points = []
    for step in range(steps):
        angle = 2 * 3.141592653589793 * step / steps
        ct, st = __import__("math").cos(angle), __import__("math").sin(angle)
        px = cx + rx * (abs(ct) ** (2 / exponent)) * (1 if ct >= 0 else -1)
        py = cy + ry * (abs(st) ** (2 / exponent)) * (1 if st >= 0 else -1)
        points.append((px, py))
    return points


def vertical_gradient(size, top, bottom):
    base = Image.linear_gradient("L").resize((size, size), Image.LANCZOS)
    gradient = Image.new("RGB", (size, size))
    gradient.paste(Image.new("RGB", (size, size), top), (0, 0))
    gradient.paste(Image.new("RGB", (size, size), bottom), (0, 0), base)
    return gradient


def check_polyline(box):
    x0, y0, w, h = box
    points = [(29, 56), (44.5, 71), (72, 38)]
    return [(x0 + px / 100 * w, y0 + py / 110 * h) for px, py in points]


def draw_check(canvas, box, color, width_ratio=0.105):
    draw = ImageDraw.Draw(canvas)
    points = check_polyline(box)
    width = max(2, int(box[2] * width_ratio))
    draw.line(points, fill=color, width=width, joint="curve")
    for point in points:  # zaokrąglone końce
        radius = width / 2
        draw.ellipse([point[0] - radius, point[1] - radius, point[0] + radius, point[1] + radius], fill=color)


def tile_icon(size):
    """Ikona kafelkowa: grafitowy kwadrat, mietowa tarcza, biały ptaszek."""
    canvas_size = size * SS
    canvas = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))

    tile_box = (0, 0, canvas_size, canvas_size)
    tile_mask = Image.new("L", (canvas_size, canvas_size), 0)
    ImageDraw.Draw(tile_mask).polygon(superellipse(tile_box), fill=255)
    tile = vertical_gradient(canvas_size, TILE_TOP, TILE_BOTTOM)
    canvas.paste(tile, (0, 0), tile_mask)

    # delikatna obwódka światła u góry kafelka
    edge = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    ImageDraw.Draw(edge).polygon(superellipse(tile_box), outline=(255, 255, 255, 38), width=max(1, canvas_size // 160))
    canvas.alpha_composite(edge)

    shield_w = canvas_size * 0.60
    shield_h = shield_w * 1.10
    shield_box = ((canvas_size - shield_w) / 2, canvas_size * 0.175, shield_w, shield_h)

    # miękki cień pod tarczą
    shadow = Image.new("L", (canvas_size, canvas_size), 0)
    ImageDraw.Draw(shadow).polygon(
        [(x, y + canvas_size * 0.022) for x, y in shield_path(shield_box)], fill=120
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(canvas_size * 0.018))
    canvas.alpha_composite(Image.merge("RGBA", (
        Image.new("L", (canvas_size, canvas_size), 0),
        Image.new("L", (canvas_size, canvas_size), 0),
        Image.new("L", (canvas_size, canvas_size), 0),
        shadow,
    )))

    shield_mask = Image.new("L", (canvas_size, canvas_size), 0)
    ImageDraw.Draw(shield_mask).polygon(shield_path(shield_box), fill=255)
    canvas.paste(vertical_gradient(canvas_size, SHIELD_TOP, SHIELD_BOTTOM), (0, 0), shield_mask)

    draw_check(canvas, shield_box, CHECK)
    return canvas.resize((size, size), Image.LANCZOS)


def tile_app_icon(size):
    """Ikona aplikacji. macOS nie wypełnia całego kwadratu: kafelek jest wcięty i ma cień.
    Przy 16-32 px cień i drobny ptaszek zamieniają się w szarą plamę, więc małe rozmiary
    dostają mniejsze wcięcie, większą tarczę i grubszy ptaszek — tak jak robi to Apple."""
    small = size <= 32
    medium = 32 < size <= 64
    inset = 0.045 if small else (0.075 if medium else 0.10)
    shield_scale = 0.74 if small else (0.66 if medium else 0.60)
    check_ratio = 0.155 if small else (0.125 if medium else 0.105)

    canvas_size = size * (SS * 2 if small else SS)
    canvas = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    pad = canvas_size * inset
    tile_box = (pad, pad, canvas_size - 2 * pad, canvas_size - 2 * pad)
    tile_points = superellipse(tile_box)

    if not small:
        shadow = Image.new("L", (canvas_size, canvas_size), 0)
        ImageDraw.Draw(shadow).polygon(
            [(x, y + canvas_size * 0.018) for x, y in tile_points], fill=110
        )
        shadow = shadow.filter(ImageFilter.GaussianBlur(canvas_size * 0.016))
        canvas.alpha_composite(Image.merge("RGBA", (
            Image.new("L", (canvas_size, canvas_size), 0),
            Image.new("L", (canvas_size, canvas_size), 0),
            Image.new("L", (canvas_size, canvas_size), 0),
            shadow,
        )))

    tile_mask = Image.new("L", (canvas_size, canvas_size), 0)
    ImageDraw.Draw(tile_mask).polygon(tile_points, fill=255)
    canvas.paste(vertical_gradient(canvas_size, TILE_TOP, TILE_BOTTOM), (0, 0), tile_mask)

    if not small:
        edge = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
        ImageDraw.Draw(edge).polygon(tile_points, outline=(255, 255, 255, 40), width=max(1, canvas_size // 170))
        canvas.alpha_composite(edge)

    shield_w = tile_box[2] * shield_scale
    shield_h = shield_w * 1.10
    shield_box = (
        (canvas_size - shield_w) / 2,
        tile_box[1] + (tile_box[3] - shield_h) / 2,
        shield_w,
        shield_h,
    )
    shield_mask = Image.new("L", (canvas_size, canvas_size), 0)
    ImageDraw.Draw(shield_mask).polygon(shield_path(shield_box), fill=255)
    canvas.paste(vertical_gradient(canvas_size, SHIELD_TOP, SHIELD_BOTTOM), (0, 0), shield_mask)
    draw_check(canvas, shield_box, CHECK, width_ratio=check_ratio)
    return canvas.resize((size, size), Image.LANCZOS)


# Odznaka w interfejsie aplikacji: sama tarcza, bez kafelka. Gradient jest ciemniejszy niż
# w kafelku, bo biały ptaszek musi mieć kontrast również na jasnym tle okna.
BADGE_TOP = (79, 224, 168)
BADGE_BOTTOM = (14, 146, 104)


def app_icon(size):
    """Ikona aplikacji bez kafelka: sama tarcza, spójna z odznaką w interfejsie.
    Cień i ciemna, półprzezroczysta krawędź zapewniają czytelność na jasnym i ciemnym Docku."""
    small = size <= 32
    canvas_size = size * (SS * 2 if small else SS)
    canvas = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    pad = canvas_size * (0.07 if small else 0.10)
    shield_h = canvas_size - 2 * pad
    shield_w = shield_h / 1.10
    box = ((canvas_size - shield_w) / 2, pad, shield_w, shield_h)
    points = shield_path(box)

    if not small:
        shadow = Image.new("L", (canvas_size, canvas_size), 0)
        ImageDraw.Draw(shadow).polygon([(x, y + canvas_size * 0.02) for x, y in points], fill=130)
        shadow = shadow.filter(ImageFilter.GaussianBlur(canvas_size * 0.018))
        zero = Image.new("L", (canvas_size, canvas_size), 0)
        canvas.alpha_composite(Image.merge("RGBA", (zero, zero, zero, shadow)))

    mask = Image.new("L", (canvas_size, canvas_size), 0)
    ImageDraw.Draw(mask).polygon(points, fill=255)
    canvas.paste(vertical_gradient(canvas_size, BADGE_TOP, BADGE_BOTTOM), (0, 0), mask)
    edge = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    ImageDraw.Draw(edge).polygon(points, outline=(0, 60, 40, 90), width=max(1, canvas_size // 150))
    canvas.alpha_composite(edge)
    draw_check(canvas, box, CHECK, width_ratio=0.15 if small else 0.115)
    return canvas.resize((size, size), Image.LANCZOS)




def badge_icon(size):
    canvas_size = size * SS
    canvas = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    pad = canvas_size * 0.04
    shield_h = canvas_size - 2 * pad
    shield_w = shield_h / 1.10
    box = ((canvas_size - shield_w) / 2, pad, shield_w, shield_h)

    mask = Image.new("L", (canvas_size, canvas_size), 0)
    ImageDraw.Draw(mask).polygon(shield_path(box), fill=255)
    canvas.paste(vertical_gradient(canvas_size, BADGE_TOP, BADGE_BOTTOM), (0, 0), mask)
    draw_check(canvas, box, CHECK, width_ratio=0.115)
    return canvas.resize((size, size), Image.LANCZOS)


def glyph_icon(size, padding_ratio=None, check_ratio=None):
    """Ikona jednobarwna: czarna tarcza z wyciętym ptaszkiem (do szablonów macOS i Safari).

    Przy 16-19 px cienki ptaszek zanika po zmniejszeniu, dlatego małe rozmiary dostają
    grubszy ptaszek i mniejszy margines — inaczej glif zamienia się w szarą plamę.
    """
    small = size < 24
    padding_ratio = padding_ratio if padding_ratio is not None else (0.02 if small else 0.06)
    check_ratio = check_ratio if check_ratio is not None else (0.185 if small else 0.125)
    canvas_size = size * SS * (2 if small else 1)
    canvas = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    padding = canvas_size * padding_ratio
    shield_h = canvas_size - 2 * padding
    shield_w = shield_h / 1.10
    box = ((canvas_size - shield_w) / 2, padding, shield_w, shield_h)

    ImageDraw.Draw(canvas).polygon(shield_path(box), fill=(0, 0, 0, 255))
    # ptaszek wycinamy z kształtu, żeby szablon zachował czytelność po zabarwieniu
    knockout = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    draw_check(knockout, box, (0, 0, 0, 255), width_ratio=check_ratio)
    alpha = canvas.getchannel("A")
    alpha.paste(Image.new("L", (canvas_size, canvas_size), 0), (0, 0), knockout.getchannel("A"))
    canvas.putalpha(alpha)
    return canvas.resize((size, size), Image.LANCZOS)


# Domyślnie zapisuje prosto do zasobów projektu; pierwszy argument zmienia katalog docelowy.
import sys

project = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
icons_dir = os.path.join(project, "Sources/SafariWebExtension/Resources/icons")
menu_dir = os.path.join(project, "Resources/Assets.xcassets/MenuBarShield.imageset")
appicon_dir = os.path.join(project, "Resources/Assets.xcassets/AppIcon.appiconset")
badge_dir = os.path.join(project, "Resources/Assets.xcassets/MacAdBlockShield.imageset")
for directory in (icons_dir, menu_dir, appicon_dir, badge_dir):
    os.makedirs(directory, exist_ok=True)

# Lista rozszerzeń w Ustawieniach Safari pokazuje tę ikonę na białym/jasnym tle obok innych
# rozszerzeń — używamy tego samego renderu co ikona aplikacji (sama tarcza, bez kafelka),
# żeby wyglądały spójnie; wcześniej tile_icon() rysował ciemny/czarny kafelek w tle.
for size in (48, 64, 96, 128, 256, 512):
    app_icon(size).save(f"{icons_dir}/extension-icon-{size}.png")
for size in (16, 19, 32, 38):
    glyph_icon(size).save(f"{icons_dir}/toolbar-icon-{size}.png")
for size, name in ((18, "menubar-shield.png"), (36, "menubar-shield@2x.png"), (54, "menubar-shield@3x.png")):
    glyph_icon(size, padding_ratio=0.04, check_ratio=0.16 if size < 24 else 0.13).save(f"{menu_dir}/{name}")




# Ikona aplikacji: jeden plik na każdy rozmiar z Contents.json.
app_targets = {
    16: ["icon_16x16.png"],
    32: ["icon_16x16@2x.png", "icon_32x32.png"],
    64: ["icon_32x32@2x.png"],
    128: ["icon_128x128.png"],
    256: ["icon_128x128@2x.png", "icon_256x256.png"],
    512: ["icon_256x256@2x.png", "icon_512x512.png"],
    1024: ["icon_512x512@2x.png"],
}
for size, names in app_targets.items():
    image = app_icon(size)
    for name in names:
        image.save(os.path.join(appicon_dir, name))

# Odznaka w interfejsie (zestaw MacAdBlockShield). Pulpit pokazuje ją na 72 pt, więc 1x ma 96 px,
# a 2x — 192 px; wcześniejsze 32/64 px były rozciągane i rozmyte.
badge_icon(96).save(os.path.join(badge_dir, "MacAdBlockShield.png"))
badge_icon(192).save(os.path.join(badge_dir, "MacAdBlockShield@2x.png"))
print("zapisano ikony w:", appicon_dir, badge_dir, icons_dir, menu_dir)
