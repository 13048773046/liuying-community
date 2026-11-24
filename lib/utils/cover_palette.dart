/// 从应用图标提取主色，作为详情页封面背景。
///
/// 直接移植流萤音乐 `CoverPalette.swift` / `ColorPalette.kt` 的 v17.1
/// “肉眼感取色”管线：长边降到 96px、过滤近黑与低饱和像素、60° 色相桶
/// 亮度加权投票、植被绿/蓝色环境色规则、亮度锚定，最后输出柔和主色。
/// 只把“歌曲封面”换成了“应用图标”，算法本身保持一致。
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../api/client.dart';

class CoverPalette {
  static final Map<String, Color> _cache = {};
  static const int _cacheMax = 600;

  /// 同步读取缓存，供页面首帧直接使用，避免先闪一次兜底色。
  static Color? cached(String id, String url) {
    if (url.trim().isEmpty) return null;
    return _cache['$id|$url'];
  }

  /// 下载图标并取色。失败返回 null，由页面回退平台色。
  static Future<Color?> colorFor(String id, String url) async {
    if (url.trim().isEmpty) return null;
    final key = '$id|$url';
    final hit = _cache[key];
    if (hit != null) return hit;

    final bytes = await _download(url);
    if (bytes == null) return null;
    final image = await _decode(bytes);
    if (image == null) return null;

    ui.Image? small;
    try {
      small = await _downsample(image, 96);
      final extracted = await _extract(small);
      // 黑白/灰调图标没有可靠彩色主色，给中性深灰而不是硬套平台绿。
      final color = extracted ?? const Color(0xFF4D4D4D);
      if (_cache.length >= _cacheMax) _cache.clear();
      _cache[key] = color;
      return color;
    } catch (_) {
      return null;
    } finally {
      if (!identical(small, image)) small?.dispose();
      image.dispose();
    }
  }

  /// 同色相三档渐变：顶部提亮空气感 / 中部本色 / 底部加深。
  /// 色相与饱和度保真，只调亮度，避免用黑色叠加把颜色弄脏。
  static ({Color top, Color mid, Color bottom}) gradientShades(Color base) {
    final hsl = _rgbToHsl(base.r, base.g, base.b);
    Color shade(double l) {
      final rgb = _hslToRgb(hsl.h, hsl.s, l);
      return Color.fromARGB(
        (base.a * 255).round(),
        (rgb.r * 255).round(),
        (rgb.g * 255).round(),
        (rgb.b * 255).round(),
      );
    }

    return (top: shade(0.62), mid: shade(0.50), bottom: shade(0.30));
  }

  static Future<Uint8List?> _download(String url) async {
    try {
      final res = await ApiClient.httpClient
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) return null;
      return res.bodyBytes;
    } catch (_) {
      return null;
    }
  }

  static Future<ui.Image?> _decode(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      codec.dispose();
      return image;
    } catch (_) {
      return null;
    }
  }

  static Future<ui.Image> _downsample(ui.Image src, int maxSide) async {
    final w = src.width;
    final h = src.height;
    final longSide = math.max(w, h);
    if (longSide <= maxSide) return src;

    final scale = maxSide / longSide;
    final tw = math.max(1, (w * scale).round());
    final th = math.max(1, (h * scale).round());
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImageRect(
      src,
      ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      ui.Rect.fromLTWH(0, 0, tw.toDouble(), th.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.medium,
    );
    final picture = recorder.endRecording();
    final out = await picture.toImage(tw, th);
    picture.dispose();
    return out;
  }

  static Future<Color?> _extract(ui.Image image) async {
    final w = image.width;
    final h = image.height;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return null;
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );

    final buckets = List.generate(6, (_) => _Bucket());
    var bgL = 0.0;
    var bgN = 0;
    var col = 0;
    var sSum = 0.0;
    var gCnt = 0;
    var gHS = 0.0;
    var gSS = 0.0;
    var gLS = 0.0;
    var bCnt = 0;
    var bHS = 0.0;
    var bSS = 0.0;

    for (var i = 0; i + 3 < bytes.length; i += 4) {
      final a = bytes[i + 3];
      if (a <= 128) continue;
      final r = bytes[i] / 255.0;
      final g = bytes[i + 1] / 255.0;
      final b = bytes[i + 2] / 255.0;
      final maxC = math.max(r, math.max(g, b));
      final minC = math.min(r, math.min(g, b));
      final chroma = maxC - minC;
      final lum = (maxC + minC) / 2.0;

      if (lum <= 0.10 || chroma == 0) {
        bgL += lum;
        bgN++;
        continue;
      }
      final sv = chroma / maxC;
      if (sv <= 0.06) {
        bgL += lum;
        bgN++;
        continue;
      }

      final hsl = _rgbToHsl(r, g, b);
      final hue = hsl.h;
      final deg = hue * 360.0;
      col++;
      sSum += sv;
      final wi = 1.0 + 3.0 * lum;
      final bi = (hue * 6.0).floor() % 6;
      buckets[bi].count++;
      buckets[bi].wSum += wi;
      buckets[bi].hWSum += wi * hue;
      buckets[bi].sWSum += wi * sv;
      buckets[bi].lWSum += wi * lum;
      buckets[bi].plainLSum += lum;
      if (deg >= 60.0 && deg < 180.0) {
        gCnt++;
        gHS += hue;
        gSS += sv;
        gLS += lum;
      } else if (deg >= 180.0 && deg < 300.0) {
        bCnt++;
        bHS += hue;
        bSS += sv;
      }
    }

    final total = w * h;
    if (col < 6) return null;
    final cover = col.toDouble() / total.toDouble();
    final avgS = sSum / col;

    // 灰判定：彩色覆盖过少，或低覆盖 + 低饱和 + 色调高度统一。
    if (cover < 0.15) return null;
    if (cover < 0.30 && avgS < 0.18) {
      final mainCount = buckets.map((b) => b.count).reduce(math.max);
      if (mainCount.toDouble() / col.toDouble() >= 0.85) return null;
    }

    // 主体桶 = 亮度加权最大的 60° 桶。
    var mainIndex = 0;
    for (var i = 1; i < 6; i++) {
      if (buckets[i].wSum > buckets[mainIndex].wSum) mainIndex = i;
    }
    final main = buckets[mainIndex];
    final mh = main.hWSum / main.wSum;
    final ms = math.max(main.sWSum / main.wSum, 0.10);
    final ml = main.lWSum / main.wSum;

    final envN = col - main.count;
    var envLS = 0.0;
    for (var i = 0; i < 6; i++) {
      if (i != mainIndex) envLS += buckets[i].plainLSum;
    }
    final envL = envN > 0 ? envLS / envN.toDouble() : ml;

    var hue = mh;
    var sat = ms;
    var greenUsed = false;

    // 植被绿：绿系占比高或饱和度高，且亮度足够。
    if (gCnt > 0) {
      final gs = gSS / gCnt.toDouble();
      final gl = gLS / gCnt.toDouble();
      final gShare = gCnt.toDouble() / col.toDouble();
      if ((gShare >= 0.25 || gs >= 0.30) && gl >= 0.18) {
        hue = gHS / gCnt.toDouble();
        sat = math.max(gs, 0.10);
        greenUsed = true;
      }
    }

    // 蓝色：主体是低饱和暖色，且环境蓝占比和饱和度都显著。
    if (!greenUsed) {
      final warmSkin = mh * 360.0 < 75.0 || mh * 360.0 > 330.0;
      if (bCnt > 0 &&
          warmSkin &&
          ms <= 0.35 &&
          envN >= 0.12 * col.toDouble() &&
          envL >= 0.20) {
        final bShare = bCnt.toDouble() / col.toDouble();
        final bs = bSS / bCnt.toDouble();
        if (bShare >= 0.30 && bs >= 0.35) {
          hue = bHS / bCnt.toDouble();
          sat = math.max(bs, 0.10);
        }
      }
    }

    // 亮度锚定：主体×0.6 + 背景×0.4，钳制到 [0.30, 0.80]。
    final bgAvg = bgN > 0 ? bgL / bgN.toDouble() : ml;
    final ll = math.max(0.30, math.min(0.80, ml * 0.6 + bgAvg * 0.4));
    final rgb = _hslToRgb(hue, sat, ll);
    return Color.fromARGB(
      255,
      (rgb.r * 255).round(),
      (rgb.g * 255).round(),
      (rgb.b * 255).round(),
    );
  }

  static ({double h, double s, double l}) _rgbToHsl(
    double r,
    double g,
    double b,
  ) {
    final maxV = math.max(r, math.max(g, b));
    final minV = math.min(r, math.min(g, b));
    final l = (maxV + minV) / 2.0;
    if (maxV == minV) return (h: 0, s: 0, l: l);
    final d = maxV - minV;
    final s = l > 0.5 ? d / (2.0 - maxV - minV) : d / (maxV + minV);
    var h = 0.0;
    if (maxV == r) {
      h = ((g - b) / d + (g < b ? 6 : 0)) / 6.0;
    } else if (maxV == g) {
      h = ((b - r) / d + 2) / 6.0;
    } else {
      h = ((r - g) / d + 4) / 6.0;
    }
    return (h: h, s: s, l: l);
  }

  static ({double r, double g, double b}) _hslToRgb(
    double h,
    double s,
    double l,
  ) {
    if (s == 0) return (r: l, g: l, b: l);
    final q = l < 0.5 ? l * (1 + s) : l + s - l * s;
    final p = 2 * l - q;
    double channel(double t0) {
      var t = t0;
      if (t < 0) t += 1;
      if (t > 1) t -= 1;
      if (t < 1.0 / 6.0) return p + (q - p) * 6 * t;
      if (t < 1.0 / 2.0) return q;
      if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6;
      return p;
    }

    return (
      r: channel(h + 1.0 / 3.0),
      g: channel(h),
      b: channel(h - 1.0 / 3.0),
    );
  }
}

class _Bucket {
  int count = 0;
  double wSum = 0;
  double hWSum = 0;
  double sWSum = 0;
  double lWSum = 0;
  double plainLSum = 0;
}
