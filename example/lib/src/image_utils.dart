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
