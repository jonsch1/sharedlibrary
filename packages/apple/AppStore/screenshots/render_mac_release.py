"""Frame unmodified release-app captures for the Mac App Store."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).parent / "macos-1.0.3"
FONT = "/System/Library/Fonts/SFNS.ttf"

def font(size, weight):
    result = ImageFont.truetype(FONT, size)
    result.set_variation_by_name(weight)
    return result

slides = [
    ("01-library", "A home for your curiosity.", "Save the interesting. Find it again.", (246, 242, 232)),
    ("02-reader", "Get the point. Go deeper.", "Move from a quick summary to the full story.", (233, 242, 240)),
    ("03-capture", "Good ideas start anywhere.", "Bring links, text, and files into your library.", (243, 236, 228)),
]

for name, title, subtitle, color in slides:
    canvas = Image.new("RGB", (2880, 1800), color)
    draw = ImageDraw.Draw(canvas)
    draw.text((180, 48), "READBRIEFLY  /  FOR MAC", font=font(30, "Semibold"), fill=(83, 100, 89))
    draw.text((172, 100), title, font=font(112, "Bold"), fill=(29, 42, 36))
    draw.text((180, 238), subtitle, font=font(43, "Regular"), fill=(73, 86, 78))
    source = Image.open(ROOT / "raw" / f"{name}.png").convert("RGB")
    source.thumbnail((2520, 1420), Image.Resampling.LANCZOS)
    x, y = (2880-source.width)//2, 330
    if name == "03-capture":
        source = source.resize((1620, round(source.height * 1620 / source.width)), Image.Resampling.LANCZOS)
        x, y = 1080, 390
        draw.text((180, 600), "ONE PLACE FOR", font=font(30, "Semibold"), fill=(83, 100, 89))
        draw.multiline_text((180, 675), "Public links\nPasted text\nPDFs & text files", font=font(62, "Semibold"), fill=(29, 42, 36), spacing=48)
    shadow = Image.new("RGBA", canvas.size)
    ImageDraw.Draw(shadow).rounded_rectangle((x, y+14, x+source.width, y+source.height+14), radius=26, fill=(25, 40, 30, 65))
    canvas = Image.alpha_composite(canvas.convert("RGBA"), shadow.filter(ImageFilter.GaussianBlur(28)))
    mask = Image.new("L", source.size)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, source.width-1, source.height-1), radius=22, fill=255)
    canvas.paste(source, (x,y), mask)
    canvas.convert("RGB").save(ROOT / f"{name}.png")
