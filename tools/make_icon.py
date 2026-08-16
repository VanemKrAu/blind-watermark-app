"""生成安卓应用图标：直接渲染 Flutter 内置 Material 图标字体里的 water_drop 字形，
配色与 App 关于页头部图标完全一致（M3 blue seed: primaryContainer #D6E3FF 背景 +
primary #0B57D0 水滴）。输出到 example/android/app/src/main/res/。

用法：python tools/make_icon.py
"""
import os

from PIL import Image, ImageDraw, ImageFont

RES = os.path.normpath(
    os.path.join(os.path.dirname(__file__), "..", "example", "android",
                 "app", "src", "main", "res"))

FONT = os.path.join(os.path.dirname(__file__), "..", "..", ".local", "flutter",
                    "bin", "cache", "artifacts", "material_fonts",
                    "materialicons-regular.otf")
if not os.path.exists(FONT):
    raise SystemExit(f"MaterialIcons 字体不存在: {FONT}")

# M3 blue seed 基线色板（与 About 页 CircleAvatar 一致的水滴色；背景按用户要求为白色）
BG = (255, 255, 255)   # 白色背景
DROP = (11, 87, 208)   # primary #0B57D0
GLYPH = 0xF05A2        # Icons.water_drop
SS = 4                 # 超采样倍数（抗锯齿）


def draw_glyph(size, paint_ratio):
    """透明画布 + 居中的 water_drop 字形。

    先用大字号渲染一次，取实际像素的紧包围盒（Material 图标字体含大量内边距，
    不能用 getbbox 字面尺寸，否则画出来会偏小），再精确缩放到画布 paint_ratio。"""
    ch = chr(GLYPH)
    probe = ImageFont.truetype(FONT, size * 4)
    tmp = Image.new("RGBA", (size * 8, size * 8), (0, 0, 0, 0))
    ImageDraw.Draw(tmp).text((size * 2, size * 2), ch, font=probe, fill=DROP)
    bbox = tmp.getbbox()
    if bbox is None:
        raise SystemExit("glyph render failed")
    glyph = tmp.crop(bbox)
    w = bbox[2] - bbox[0]
    h = bbox[3] - bbox[1]
    target_h = max(1, int(round(size * paint_ratio)))
    target_w = max(1, int(round(w * target_h / h)))
    glyph = glyph.resize((target_w, target_h), Image.LANCZOS)
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    canvas.paste(glyph, ((size - target_w) // 2, (size - target_h) // 2),
                 glyph)
    return canvas


def save(img, rel):
    path = os.path.join(RES, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path)
    print("wrote", os.path.relpath(path, RES))


def main():
    legacy = {"mdpi": 48, "hdpi": 72, "xhdpi": 96,
              "xxhdpi": 144, "xxxhdpi": 192}
    for dens, size in legacy.items():
        bg = Image.new("RGB", (size, size), BG)
        icon = Image.alpha_composite(bg.convert("RGBA"),
                                     draw_glyph(size, 0.42))
        save(icon, os.path.join(f"mipmap-{dens}", "ic_launcher.png"))
        save(icon, os.path.join(f"mipmap-{dens}", "ic_launcher_round.png"))
    # 自适应前景：透明底 + 安全区内字形（66.6% 安全区，绘制高度取 40%，
    # 用户实测小米类泪滴遮罩更小，50%/44% 均被裁切）
    fg = {"mdpi": 108, "hdpi": 162, "xhdpi": 216,
          "xxhdpi": 324, "xxxhdpi": 432}
    for dens, size in fg.items():
        save(draw_glyph(size, 0.40),
             os.path.join(f"mipmap-{dens}", "ic_launcher_foreground.png"))
    # 背景色（自适应图标 <background> 引用）
    colors = os.path.join(RES, "values", "colors.xml")
    os.makedirs(os.path.dirname(colors), exist_ok=True)
    with open(colors, "w", encoding="utf-8") as f:
        f.write('<?xml version="1.0" encoding="utf-8"?>\n'
                '<resources>\n'
                '    <color name="ic_launcher_background">#D6E3FF</color>\n'
                '</resources>\n')
    print("wrote", os.path.relpath(colors, RES))


if __name__ == "__main__":
    main()
