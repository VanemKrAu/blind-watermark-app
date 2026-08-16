import 'dart:typed_data';
import 'dart:ui' as ui;

/// Decodes any image bytes (PNG/JPEG/WebP/HEIC/GIF...) and re-encodes to PNG.
///
/// The native C++ core uses stb_image which supports PNG/JPEG/BMP/WebP but
/// not HEIC/AVIF etc. Re-encoding through the Flutter engine makes the input
/// format-agnostic and lossless (PNG), which is safe for blind watermarking.
Future<Uint8List?> decodeToPng(Uint8List bytes) async {
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      final frame = await codec.getNextFrame();
      final image = frame.image;
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) return null;
        return data.buffer.asUint8List();
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
