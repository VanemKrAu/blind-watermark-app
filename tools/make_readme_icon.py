"""生成 README 项目图标（SVG）：启动图标同款 —— 白底圆角 + Material water_drop。

从 Flutter SDK 的 MaterialIcons 字体提取 water_drop (0xf05a2) 精确轮廓，
绘制高度约 40%（与启动图标一致），保存为 docs/icon.svg。

用法：python tools/make_readme_icon.py
"""
import os

from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.ttLib import TTFont

FONT = os.path.join(os.path.dirname(__file__), "..", "..", ".local", "flutter",
                    "bin", "cache", "artifacts", "material_fonts",
                    "materialicons-regular.otf")
OUT = os.path.join(os.path.dirname(__file__), "..", "docs", "icon.svg")

GLYPH_CODEPOINT = 0xF05A2  # Icons.water_drop
BG = "#D6E3FF"             # M3 blue primaryContainer 淡蓝底
DROP = "#0B57D0"           # M3 primary blue 水滴
RATIO = 0.60               # 绘制高度占比（README 图标用大一点，用户要求）


def main():
    font = TTFont(FONT)
    gs = font.getGlyphSet()
    cmap = font.getBestCmap()
    name = cmap[GLYPH_CODEPOINT]
    cs = font["CFF "].cff[0].CharStrings[name]
    pen = SVGPathPen(gs)
    cs.draw(pen)
    d = pen.getCommands()

    # 主体 bbox（从 path 实测：x 85..427, y 43..469），中心恰为 (256,256)。
    h0 = 469 - 43  # 426
    s = 512 * RATIO / h0
    t = 256 * (1 - s)

    svg = (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">\n'
        f'  <rect x="0" y="0" width="512" height="512" fill="{BG}"/>\n'
        # 垂直翻转（translate(0 512) scale(1 -1)）：Material water_drop 的
        # 尖点在 y=469（底部），翻转后尖端朝上，符合水滴图标直觉。
        '  <g transform="translate(0 512) scale(1 -1)">\n'
        f'    <g transform="translate({t:.2f} {t:.2f}) scale({s:.6f})" fill="{DROP}">\n'
        f'      <path d="{d}"/>\n'
        '    </g>\n'
        '  </g>\n'
        '</svg>\n'
    )
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(svg)
    print("wrote", os.path.relpath(OUT, os.path.join(os.path.dirname(__file__), "..")))


if __name__ == "__main__":
    main()
