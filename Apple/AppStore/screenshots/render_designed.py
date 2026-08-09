#!/usr/bin/env python3
"""Render the three launch App Store screenshots from real app captures."""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parent
OUTPUT = ROOT / "designed" / "iphone-6.9"
IPAD_OUTPUT = ROOT / "designed" / "ipad-13"
MAC_OUTPUT = ROOT / "designed" / "mac"
CANVAS = (1320, 2868)
IPHONE_CANVAS = (1284, 2778)
IPAD_CANVAS = (2064, 2752)

CHARCOAL = (31, 29, 27)
IVORY = (255, 252, 244)
BUTTER = (248, 216, 111)
CORAL = (244, 164, 132)
SKY = (194, 222, 247)
BLUE = (64, 129, 194)
FONT_PATH = "/System/Library/Fonts/SFNS.ttf"


def font(size: int, weight: str) -> ImageFont.FreeTypeFont:
    result = ImageFont.truetype(FONT_PATH, size)
    result.set_variation_by_name(weight)
    return result


HEADLINE = font(132, "Bold")
THIRD_HEADLINE = font(114, "Bold")
SUBHEAD = font(51, "Medium")
EYEBROW = font(30, "Bold")
LABEL = font(27, "Bold")
KEY = font(150, "Semibold")


def tracked_text(
    draw: ImageDraw.ImageDraw,
    position: tuple[int, int],
    value: str,
    text_font: ImageFont.FreeTypeFont,
    fill: tuple[int, int, int],
    tracking: int,
) -> None:
    x, y = position
    for character in value:
        draw.text((x, y), character, font=text_font, fill=fill)
        x += round(draw.textlength(character, font=text_font)) + tracking


def canvas(color: tuple[int, int, int], size: tuple[int, int] = CANVAS) -> Image.Image:
    return Image.new("RGBA", size, color + (255,))


def add_copy(
    image: Image.Image,
    eyebrow: str,
    headline: str,
    subhead: str,
    accent: tuple[int, int, int],
    headline_font: ImageFont.FreeTypeFont = HEADLINE,
) -> None:
    draw = ImageDraw.Draw(image)
    tracked_text(draw, (82, 88), eyebrow.upper(), EYEBROW, accent, 6)
    draw.multiline_text(
        (76, 137),
        headline,
        font=headline_font,
        fill=CHARCOAL,
        spacing=-12,
    )
    line_count = headline.count("\n") + 1
    subhead_y = 137 + line_count * (headline_font.size - 2) + 25
    draw.text((82, subhead_y), subhead, font=SUBHEAD, fill=CHARCOAL)
    draw.rounded_rectangle((82, subhead_y + 91, 244, subhead_y + 101), radius=5, fill=accent)


def rounded_capture(source: Image.Image, width: int, radius: int) -> Image.Image:
    height = round(width * source.height / source.width)
    content = source.convert("RGB").resize((width, height), Image.Resampling.LANCZOS)
    mask = Image.new("L", content.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, content.width - 1, content.height - 1), radius=radius, fill=255
    )
    result = Image.new("RGBA", content.size)
    result.paste(content, mask=mask)
    return result


def add_product(
    image: Image.Image,
    source: Image.Image,
    position: tuple[int, int],
    width: int,
    radius: int,
    border: tuple[int, int, int] = CHARCOAL,
    border_width: int = 4,
    shadow_opacity: int = 90,
) -> None:
    product = rounded_capture(source, width, radius)
    x, y = position

    shadow = Image.new("RGBA", image.size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (x - 12, y + 24, x + product.width + 12, y + product.height + 50),
        radius=radius + 18,
        fill=(45, 36, 28, shadow_opacity),
    )
    image.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(34)))

    frame = Image.new("RGBA", (product.width + 28, product.height + 28), (0, 0, 0, 0))
    frame_draw = ImageDraw.Draw(frame)
    frame_draw.rounded_rectangle(
        (0, 0, frame.width - 1, frame.height - 1),
        radius=radius + 14,
        fill=IVORY + (255,),
        outline=border + (230,),
        width=border_width,
    )
    frame.alpha_composite(product, (14, 14))
    image.alpha_composite(frame, (x - 14, y - 14))


def add_label(
    image: Image.Image,
    position: tuple[int, int],
    text: str,
    accent: tuple[int, int, int],
) -> None:
    draw = ImageDraw.Draw(image)
    x, y = position
    width = round(draw.textlength(text, font=LABEL)) + 58
    draw.rounded_rectangle(
        (x, y, x + width, y + 62),
        radius=31,
        fill=IVORY,
        outline=accent,
        width=4,
    )
    draw.text((x + 29, y + 15), text, font=LABEL, fill=CHARCOAL)


def add_keycap(image: Image.Image, position: tuple[int, int], value: str) -> None:
    x, y = position
    size = 330
    shadow = Image.new("RGBA", image.size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (x, y + 22, x + size, y + size + 22),
        radius=72,
        fill=(67, 40, 29, 80),
    )
    image.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(22)))

    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle(
        (x, y, x + size, y + size),
        radius=72,
        fill=IVORY,
        outline=CHARCOAL,
        width=5,
    )
    bounds = draw.textbbox((0, 0), value, font=KEY)
    text_width = bounds[2] - bounds[0]
    text_height = bounds[3] - bounds[1]
    draw.text(
        (x + (size - text_width) / 2, y + (size - text_height) / 2 - bounds[1]),
        value,
        font=KEY,
        fill=CHARCOAL,
    )


def save(image: Image.Image, filename: str, output: Path = OUTPUT) -> None:
    output.mkdir(parents=True, exist_ok=True)
    if output == OUTPUT:
        image = image.resize(IPHONE_CANVAS, Image.Resampling.LANCZOS)
    image.convert("RGB").save(output / filename, format="PNG", optimize=True)


def main() -> None:
    iphone_library = Image.open(OUTPUT / "raw-library.png")
    concise = Image.open(OUTPUT / "raw-reader-concise.png")
    detailed = Image.open(OUTPUT / "raw-reader.png")
    mac_library = Image.open(MAC_OUTPUT / "raw-library.png")

    first = canvas(BUTTER)
    add_copy(
        first,
        "Mac + iPhone",
        "Your library.\nEverywhere.",
        "Save on Mac. Read on iPhone.",
        (153, 101, 0),
    )
    add_product(first, mac_library, (80, 700), 1160, 32, border=(138, 91, 0))
    add_product(first, iphone_library, (660, 1150), 600, 70, border=(138, 91, 0), border_width=5)
    save(first, "01-mac-and-iphone.png")

    second = canvas(CORAL)
    add_copy(
        second,
        "Mac shortcut",
        "Save anything.\nPress ⌘G.",
        "Capture from anywhere on your Mac.",
        (143, 53, 31),
    )
    add_product(second, mac_library, (45, 725), 1230, 34, border=(143, 53, 31))
    add_keycap(second, (275, 1590), "⌘")
    add_keycap(second, (715, 1590), "G")
    save(second, "02-mac-shortcut.png")

    third = canvas(SKY)
    add_copy(
        third,
        "Reading depth",
        "Read and listen\nat the depth\nthat fits.",
        "Concise, detailed, source—or audio.",
        BLUE,
        headline_font=THIRD_HEADLINE,
    )
    add_label(third, (72, 825), "CONCISE", BLUE)
    add_label(third, (818, 825), "DETAILED", (95, 86, 171))
    add_product(third, concise, (-15, 915), 670, 75, border=BLUE)
    add_product(third, detailed, (665, 915), 670, 75, border=(95, 86, 171))
    save(third, "03-reading-depth.png")

    ipad_first = canvas(BUTTER, IPAD_CANVAS)
    add_copy(
        ipad_first,
        "Mac + iPad",
        "Your library. Everywhere.",
        "Save on Mac. Read on iPad.",
        (153, 101, 0),
    )
    add_product(ipad_first, mac_library, (102, 670), 1860, 40, border=(138, 91, 0))
    add_product(
        ipad_first,
        iphone_library,
        (1270, 1110),
        680,
        76,
        border=(138, 91, 0),
        border_width=5,
    )
    save(ipad_first, "01-mac-and-ipad.png", IPAD_OUTPUT)

    ipad_second = canvas(CORAL, IPAD_CANVAS)
    add_copy(
        ipad_second,
        "Mac shortcut",
        "Save anything. Press ⌘G.",
        "Capture from anywhere on your Mac.",
        (143, 53, 31),
    )
    add_product(ipad_second, mac_library, (90, 690), 1884, 42, border=(143, 53, 31))
    add_keycap(ipad_second, (525, 1870), "⌘")
    add_keycap(ipad_second, (1209, 1870), "G")
    save(ipad_second, "02-mac-shortcut.png", IPAD_OUTPUT)

    ipad_third = canvas(SKY, IPAD_CANVAS)
    add_copy(
        ipad_third,
        "Reading depth",
        "Read and listen at the depth that fits.",
        "Concise, detailed, source—or audio.",
        BLUE,
        headline_font=THIRD_HEADLINE,
    )
    add_label(ipad_third, (104, 770), "CONCISE", BLUE)
    add_label(ipad_third, (1110, 770), "DETAILED", (95, 86, 171))
    add_product(ipad_third, concise, (82, 860), 850, 82, border=BLUE)
    add_product(ipad_third, detailed, (1080, 860), 850, 82, border=(95, 86, 171))
    save(ipad_third, "03-reading-depth.png", IPAD_OUTPUT)


if __name__ == "__main__":
    main()
