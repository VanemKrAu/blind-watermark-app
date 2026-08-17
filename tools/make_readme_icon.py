"""生成 README 项目图标（SVG）：启动图标同款 —— 淡蓝底 + 尖端朝上的水滴。

从 Flutter SDK 的 MaterialIcons 字体提取 water_drop (0xf05a2) 精确轮廓。
注意：Material water_drop 的尖点在底部（y=469），为让尖端朝上（与启动图标
PIL 渲染一致），把 Y 坐标直接翻转进 path（y' = 512 - y），SVG 只保留
单层正变换（translate+scale）——避免嵌套负缩放 transform，GitHub 的
SVG sanitizer 对简单变换最友好（曾因 scale(1 -1) 嵌套导致渲染失败）。

用法：python tools/make_readme_icon.py
"""
import os
import re

from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.ttLib import TTFont

FONT = os.path.join(os.path.dirname(__file__), "..", "..", ".local", "flutter",
                    "bin", "cache", "artifacts", "material_fonts",
                    "materialicons-regular.otf")
OUT = os.path.join(os.path.dirname(__file__), "..", "docs", "icon.svg")

GLYPH_CODEPOINT = 0xF05A2  # Icons.water_drop
BG = "#D6E3FF"             # M3 blue primaryContainer 淡蓝底
DROP = "#0B57D0"           # M3 primary blue 水滴
VIEW = 512                 # 画布
RATIO = 0.60               # 绘制高度占比


def flip_y(d: str, height: int) -> str:
    """把 SVG path 的 Y 坐标翻转为 y' = height - y（坐标按 (x,y) 成对出现）。"""
    tokens = re.findall(r"[A-Za-z]|-?\d+\.?\d*", d)
    out = []
    idx = 0
    for t in tokens:
        if t[0].isalpha():
            out.append(t)
            idx = 0
        else:
            if idx % 2 == 1:
                out.append(str(height - float(t)))
            else:
                out.append(t)
            idx += 1
    return " ".join(out)


def main():
    font = TTFont(FONT)
    gs = font.getGlyphSet()
    cmap = font.getBestCmap()
    name = cmap[GLYPH_CODEPOINT]
    cs = font["CFF "].cff[0].CharStrings[name]
    pen = SVGPathPen(gs)
    cs.draw(pen)
    d = flip_y(pen.getCommands(), VIEW)

    # 主体 bbox：x 85..427, y 43..469（翻转后不变，中心 256,256）。
    # 缩放以原点为中心：bbox 中心 (256,256) 缩放后到 (256*s, 256*s)，
    # 需平移 256*(1-s) 回到画布中心 —— 注意是 256（bbox 中心），不是 512。
    h0 = 469 - 43  # 426
    s = VIEW * RATIO / h0
    t = (VIEW / 2) * (1 - s)

    svg = (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">\n'
        f'  <rect x="0" y="0" width="512" height="512" fill="{BG}"/>\n'
        f'  <g transform="translate({t:.2f} {t:.2f}) scale({s:.6f})" fill="{DROP}">\n'
        f'    <path d="{d}"/>\n'
        '  </g>\n'
        '</svg>\n'
    )
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(svg)
    print("wrote", os.path.relpath(OUT, os.path.join(os.path.dirname(__file__), "..")))


if __name__ == "__main__":
    main()
