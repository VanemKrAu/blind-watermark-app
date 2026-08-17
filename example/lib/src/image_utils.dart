import 'dart:typed_data';
import 'dart:ui' as ui;

/// Decodes any image bytes (PNG/JPEG/WebP/HEIC/GIF...) and re-encodes to PNG.
///
/// The native C++ core uses stb_image which supports PNG/JPEG/BMP/WebP but
/// not HEIC/AVIF etc. Re-encoding through the Flutter engine makes the input
/// format-agnostic and lossless (PNG), which is safe for blind watermarking.
Future<Uint8List?> decodeToPng(Uint8List bytes) async {
  final r = await decodeToPngScaled(bytes, maxDim: 0x7FFFFFFF);
  return r?.$1;
}

/// Decodes any image bytes and re-encodes to PNG, downscaling so the long
/// edge is <= [maxDim] (never upscales).
///
/// Returns `(pngBytes, originalWidth, originalHeight)` or null on failure.
///
/// Downscaling happens at decode time (engine-side scaled decode), so a
/// 12-108MP camera photo never materializes as a full-resolution frame or a
/// multi-tens-of-MB PNG in app memory — both would otherwise push the process
/// past the phone's memory budget and get it killed (the original crash).
Future<(Uint8List, int, int)?> decodeToPngScaled(Uint8List bytes,
    {int maxDim = 2048}) async {
  // Read the intrinsic size cheaply (header parse). If the descriptor path
  // is unavailable for this format, fall back to a plain full decode.
  int? w;
  int? h;
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    try {
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      try {
        w = descriptor.width;
        h = descriptor.height;
      } finally {
        descriptor.dispose();
      }
    } finally {
      buffer.dispose();
    }
  } catch (_) {
    w = null;
    h = null;
  }

  Future<(Uint8List, int, int)?> plainDecode() async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      try {
        final frame = await codec.getNextFrame();
        final image = frame.image;
        try {
          final data =
              await image.toByteData(format: ui.ImageByteFormat.png);
          if (data == null) return null;
          return (data.buffer.asUint8List(), image.width, image.height);
        } finally {
          image.dispose();
        }
      } finally {
        codec.dispose();
      }
    } catch (_) {
      return null;
    }
  }

  if (w == null || h == null || w <= 0 || h <= 0) {
    return plainDecode();
  }
  final longEdge = w > h ? w : h;
  if (longEdge <= maxDim) {
    return plainDecode();
  }
  try {
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: (w * maxDim / longEdge).round(),
      targetHeight: (h * maxDim / longEdge).round(),
    );
    try {
      final frame = await codec.getNextFrame();
      final image = frame.image;
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) return null;
        // Original dimensions, so callers can distinguish "downscaled" from
        // "unchanged" (e.g. the DWT extraction size guard).
        return (data.buffer.asUint8List(), w, h);
      } finally {
        image.dispose();
      }
    } finally {
      codec.dispose();
    }
  } catch (_) {
    return null;
  }
}

/// Returns (width, height) of an image, or null on failure.
Future<(int, int)?> imageSize(Uint8List bytes) async {
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final size = (image.width, image.height);
      image.dispose();
      return size;
    } finally {
      codec.dispose();
    }
  } catch (_) {
    return null;
  }
}

/// Center-crops [bytes] to [fraction] (0..1) of its own size and re-encodes
/// to PNG. Used by the WAM multi-attempt extraction (crop variants mimic a
/// "slightly cropped" image and can rescue borderline decodes).
Future<Uint8List?> centerCropPng(Uint8List bytes, double fraction) async {
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      final frame = await codec.getNextFrame();
      final image = frame.image;
      try {
        final w = image.width;
        final h = image.height;
        final cw = (w * fraction).round();
        final ch = (h * fraction).round();
        final src = ui.Rect.fromLTWH(
            (w - cw) / 2, (h - ch) / 2, cw.toDouble(), ch.toDouble());
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        canvas.drawImageRect(image, src, ui.Rect.fromLTWH(0, 0, cw.toDouble(), ch.toDouble()), ui.Paint()..filterQuality = ui.FilterQuality.medium);
        final picture = recorder.endRecording();
        final out = await picture.toImage(cw, ch);
        try {
          final data = await out.toByteData(format: ui.ImageByteFormat.png);
          return data?.buffer.asUint8List();
        } finally {
          out.dispose();
        }
      } finally {
        image.dispose();
      }
    } finally {
      codec.dispose();
    }
  } catch (_) {
    return null;
  }
}

/// 直接拉伸 [bytes] 到 (w, h)，返回 PNG。
Future<Uint8List?> resizePngTo(Uint8List bytes, int w, int h) async {
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      final frame = await codec.getNextFrame();
      final image = frame.image;
      try {
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        canvas.drawImageRect(
          image,
          ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
          ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
          ui.Paint()..filterQuality = ui.FilterQuality.medium,
        );
        final picture = recorder.endRecording();
        final out = await picture.toImage(w, h);
        try {
          final data = await out.toByteData(format: ui.ImageByteFormat.png);
          return data?.buffer.asUint8List();
        } finally {
          out.dispose();
        }
      } finally {
        image.dispose();
      }
    } finally {
      codec.dispose();
    }
  } catch (_) {
    return null;
  }
}

/// 保持宽高比、居中（黑边）填充到 (w, h)，返回 PNG。
Future<Uint8List?> padPngTo(Uint8List bytes, int w, int h) async {
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      final frame = await codec.getNextFrame();
      final image = frame.image;
      try {
        final iw = image.width.toDouble();
        final ih = image.height.toDouble();
        final scale = (w / iw) < (h / ih) ? w / iw : h / ih;
        final dw = iw * scale;
        final dh = ih * scale;
        final dx = (w - dw) / 2;
        final dy = (h - dh) / 2;
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        canvas.drawRect(
            ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
            ui.Paint()..color = const ui.Color(0xFF000000));
        canvas.drawImageRect(
          image,
          ui.Rect.fromLTWH(0, 0, iw, ih),
          ui.Rect.fromLTWH(dx, dy, dw, dh),
          ui.Paint()..filterQuality = ui.FilterQuality.medium,
        );
        final picture = recorder.endRecording();
        final out = await picture.toImage(w, h);
        try {
          final data = await out.toByteData(format: ui.ImageByteFormat.png);
          return data?.buffer.asUint8List();
        } finally {
          out.dispose();
        }
      } finally {
        image.dispose();
      }
    } finally {
      codec.dispose();
    }
  } catch (_) {
    return null;
  }
}

/// DWT「网格再同步」候选集（参考库攻击演示的还原/填补步骤）：
/// [原图, 直接拉伸到记录尺寸, 居中填充到记录尺寸]。
/// 尺寸与记录一致或 [cw]/[ch] 未知时只返回原图。
/// [srcW]/[srcH] 可传入已知的原图尺寸（避免重复解码），缺省时内部探测。
Future<List<Uint8List>> resyncCandidates(Uint8List bytes, int cw, int ch,
    {int? srcW, int? srcH}) async {
  // 防御：记录可能被篡改/损坏，非法尺寸直接退回原图（避免超大分配 OOM）。
  if (cw <= 0 || ch <= 0 || cw > 8192 || ch > 8192) return [bytes];
  var w = srcW;
  var h = srcH;
  if (w == null || h == null || h <= 0) {
    final size = await imageSize(bytes);
    if (size == null) return [bytes];
    w = size.$1;
    h = size.$2;
  }
  if (w == cw && h == ch) return [bytes];
  final stretched = await resizePngTo(bytes, cw, ch);
  final padded = await padPngTo(bytes, cw, ch);
  return [
    bytes,
    if (stretched != null) stretched,
    if (padded != null) padded,
  ];
}

/// Downscales [bytes] so that its long edge is <= [maxDim].
///
/// Never upscales: images already within [maxDim] are returned unchanged
/// (same bytes, no re-encode). Returns `(pngBytes, width, height)` or null
/// on failure.
///
/// Used before DWT embedding: the DWT-DCT-SVD pipeline holds ~2.5x the
/// YUV double matrices in memory (12MP photo ≈ 1GB native peak), which
/// reliably kills the app on phones. Extraction is unaffected because the
/// watermark block grid derives from the image's own dimensions, and the
/// saved watermarked image keeps the downscaled size.
Future<(Uint8List, int, int)?> downscalePng(Uint8List bytes, int maxDim) async {
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      final frame = await codec.getNextFrame();
      final image = frame.image;
      try {
        final w = image.width;
        final h = image.height;
        final longEdge = w > h ? w : h;
        if (longEdge <= maxDim) {
          return (bytes, w, h);
        }
        final scale = maxDim / longEdge;
        final tw = (w * scale).round();
        final th = (h * scale).round();
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        canvas.drawImageRect(
          image,
          ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
          ui.Rect.fromLTWH(0, 0, tw.toDouble(), th.toDouble()),
          ui.Paint()..filterQuality = ui.FilterQuality.medium,
        );
        final picture = recorder.endRecording();
        final out = await picture.toImage(tw, th);
        try {
          final data = await out.toByteData(format: ui.ImageByteFormat.png);
          return data == null ? null : (data.buffer.asUint8List(), tw, th);
        } finally {
          out.dispose();
        }
      } finally {
        image.dispose();
      }
    } finally {
      codec.dispose();
    }
  } catch (_) {
    return null;
  }
}
