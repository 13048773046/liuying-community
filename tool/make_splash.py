# -*- coding: utf-8 -*-
"""生成品牌启动图（Android 各密度 + iOS LaunchImage），透明底，黑底由原生配置提供。

CI 与本地共用：字体路径自动探测，字面index按 family 名自动定位，
保证同一脚本在不同机器上产出同一套像素。
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOGO = os.path.join(ROOT, "assets", "logo.png")
NAME = "流萤社区"
SLOGAN = "让每一份热爱，如流萤般点亮夜晚"

BLACK_CANDIDATES = [
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Black.ttc",
    "/usr/share/fonts/opentype/noto/NotoSansCJKsc-Black.otf",
    "/usr/share/fonts/truetype/noto/NotoSansCJK-Black.ttc",
]
MED_CANDIDATES = [
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Medium.ttc",
    "/usr/share/fonts/opentype/noto/NotoSansCJKsc-Medium.otf",
    "/usr/share/fonts/truetype/noto/NotoSansCJK-Medium.ttc",
]

# Flutter 逻辑像素基准
LOGO_PX, GAP1, NAME_PX, NAME_TRACK, GAP2, SLO_PX, SLO_TRACK = 92, 24, 28, 2, 8, 12, 1.2
WHITE = (255, 255, 255, 255)
SLO_COLOR = (255, 255, 255, 0x73)  # 45% 白


def find_font(candidates):
    for p in candidates:
        if os.path.exists(p):
            return p
    sys.exit("font not found, tried: %s" % candidates)


def sc_index(path):
    """返回简体中文字面（Noto Sans CJK SC）在集合中的序号，失败回退 2。"""
    try:
        from fontTools.ttLib import TTCollection

        coll = TTCollection(path, lazy=True)
        for i, font in enumerate(coll.fonts):
            for rec in font["name"].names:
                if rec.nameID == 1:
                    try:
                        family = rec.toUnicode()
                    except Exception:
                        continue
                    if family.replace(" ", "").lower().endswith("sc"):
                        return i
    except Exception as e:  # pragma: no cover
        print("font index probe failed: %r, fallback 2" % (e,))
    return 2


def char_w(draw, ch, font):
    bb = draw.textbbox((0, 0), ch, font=font)
    return bb[2] - bb[0]


def spaced_width(draw, text, font, track):
    return sum(char_w(draw, ch, font) for ch in text) + track * (len(text) - 1)


def draw_spaced(draw, x, y, text, font, fill, track):
    cx = x
    for ch in text:
        draw.text((cx, y), ch, font=font, fill=fill)
        cx += char_w(draw, ch, font) + track


def build(scale, out_path, f_black, f_med, idx):
    s = scale
    logo_px = round(LOGO_PX * s)
    gap1 = round(GAP1 * s)
    name_px = round(NAME_PX * s)
    name_track = NAME_TRACK * s
    gap2 = round(GAP2 * s)
    slo_px = round(SLO_PX * s)
    slo_track = SLO_TRACK * s

    f_name = ImageFont.truetype(f_black, name_px, index=idx)
    f_slo = ImageFont.truetype(f_med, slo_px, index=idx)

    tmp = Image.new("RGBA", (10, 10))
    d = ImageDraw.Draw(tmp)
    name_w = spaced_width(d, NAME, f_name, name_track)
    slo_w = spaced_width(d, SLOGAN, f_slo, slo_track)
    name_h = sum(f_name.getmetrics())
    slo_h = sum(f_slo.getmetrics())

    W = max(logo_px, round(name_w), round(slo_w))
    H = logo_px + gap1 + name_h + gap2 + slo_h

    canvas = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(canvas)

    # Logo（自带圆角深黑底、无光晕），水平居中
    logo = Image.open(LOGO).convert("RGBA").resize((logo_px, logo_px), Image.LANCZOS)
    canvas.paste(logo, ((W - logo_px) // 2, 0), logo)

    # 名称
    y = logo_px + gap1
    draw_spaced(draw, round((W - name_w) / 2), y, NAME, f_name, WHITE, name_track)

    # 标语
    y2 = y + name_h + gap2
    draw_spaced(draw, round((W - slo_w) / 2), y2, SLOGAN, f_slo, SLO_COLOR, slo_track)

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    canvas.save(out_path)
    return W, H


def main():
    f_black = find_font(BLACK_CANDIDATES)
    f_med = find_font(MED_CANDIDATES)
    idx = sc_index(f_black)
    print("font: %s | %s | SC index=%d" % (f_black, f_med, idx))

    res = os.path.join(ROOT, "android", "app", "src", "main", "res")
    droid = [
        (1.0, "drawable-mdpi"), (1.5, "drawable-hdpi"), (2.0, "drawable-xhdpi"),
        (3.0, "drawable-xxhdpi"), (4.0, "drawable-xxxhdpi"),
    ]
    for scale, d in droid:
        w, h = build(scale, os.path.join(res, d, "splash_brand.png"), f_black, f_med, idx)
        print("Android %s (%.1fx): %dx%d" % (d, scale, w, h))

    ios_set = os.path.join(ROOT, "ios", "Runner", "Assets.xcassets", "LaunchImage.imageset")
    for scale, fn in [(1.0, "LaunchImage.png"), (2.0, "LaunchImage@2x.png"),
                      (3.0, "LaunchImage@3x.png")]:
        w, h = build(scale, os.path.join(ios_set, fn), f_black, f_med, idx)
        print("iOS %s (%.1fx): %dx%d" % (fn, scale, w, h))


if __name__ == "__main__":
    main()
