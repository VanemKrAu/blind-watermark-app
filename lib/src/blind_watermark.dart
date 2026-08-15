import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'blind_watermark_bindings.dart';

/// Exception thrown when a watermark operation fails
class BlindWatermarkException implements Exception {
  final int code;
  final String message;

  BlindWatermarkException(this.code, this.message);

  @override
  String toString() => 'BlindWatermarkException($code): $message';
}

/// Configuration for BlindWatermark operations
class BlindWatermarkConfig {
  final int passwordWm;
  final int passwordImg;
  final double d1;
  final double d2;

  const BlindWatermarkConfig({
    this.passwordWm = 1,
    this.passwordImg = 1,
    this.d1 = 36.0,
    this.d2 = 20.0,
  });
}

/// Blind watermark embedding and extraction
///
/// Uses DWT-DCT-SVD algorithm for robust watermarking that survives
/// various attacks like compression, cropping, rotation, etc.
///
/// Provides both synchronous and asynchronous APIs:
/// - Sync methods: Run on the main thread, simple to use
/// - Async methods: Run in a separate isolate, non-blocking
class BlindWatermark {
  final BlindWatermarkBindings _bindings;
  final BlindWatermarkConfig _config;
  BWMHandle? _handle;
  int? _watermarkBitLength;

  /// Create a new BlindWatermark instance
  ///
  /// [passwordWm] - Password for watermark encryption (default: 1)
  /// [passwordImg] - Password for image processing (default: 1)
  /// [d1] - Embedding strength for first singular value (default: 36.0)
  ///        Lower values = better image quality, less robust watermark
  ///        Recommended range: 10-50
  /// [d2] - Embedding strength for second singular value (default: 20.0)
  ///        Recommended range: 5-30
  ///
  /// For better image quality with acceptable robustness, try d1=15, d2=10
  /// For maximum robustness (more visual artifacts), use d1=50, d2=30
  BlindWatermark({
    int passwordWm = 1,
    int passwordImg = 1,
    double d1 = 36.0,
    double d2 = 20.0,
  })  : _bindings = BlindWatermarkBindings.instance,
        _config = BlindWatermarkConfig(
          passwordWm: passwordWm,
          passwordImg: passwordImg,
          d1: d1,
          d2: d2,
        ) {
    _handle = _bindings.bwm_create_with_strength(passwordWm, passwordImg, d1, d2);
    if (_handle == nullptr) {
      throw BlindWatermarkException(-1, 'Failed to create BlindWatermark instance');
    }
  }

  /// Get the configuration for this instance
  BlindWatermarkConfig get config => _config;

  /// Check result and throw exception if failed
  void _checkResult(int result) {
    if (result != BWMResult.ok) {
      final msgPtr = _bindings.bwm_get_error_message(result);
      final message = msgPtr.toDartString();
      String detail = '';
      if (_handle != null && _handle != nullptr) {
        final lastPtr = _bindings.bwm_get_last_error(_handle!);
        if (lastPtr != nullptr && lastPtr.address != 0) {
          detail = '：${lastPtr.toDartString()}';
        }
      }
      throw BlindWatermarkException(result, '$message$detail');
    }
  }

  /// Ensure handle is valid
  void _ensureHandle() {
    if (_handle == null || _handle == nullptr) {
      throw BlindWatermarkException(-1, 'BlindWatermark instance has been disposed');
    }
  }

  // ============================================================
  // SYNCHRONOUS API
  // ============================================================

  /// Read image from file (sync)
  void readImageFile(String filename) {
    _ensureHandle();
    final filenamePtr = filename.toNativeUtf8();
    try {
      final result = _bindings.bwm_read_image(_handle!, filenamePtr);
      _checkResult(result);
    } finally {
      malloc.free(filenamePtr);
    }
  }

  /// Read image from bytes (sync)
  ///
  /// Supports: PNG, JPEG, WebP, BMP, GIF
  void readImageBytes(Uint8List imageData) {
    _ensureHandle();
    final dataPtr = malloc<Uint8>(imageData.length);
    try {
      dataPtr.asTypedList(imageData.length).setAll(0, imageData);
      final result = _bindings.bwm_read_image_buffer(_handle!, dataPtr, imageData.length);
      _checkResult(result);
    } finally {
      malloc.free(dataPtr);
    }
  }

  /// Set string watermark (sync)
  ///
  /// The string will be converted to bits using UTF-8 encoding
  void setWatermarkString(String text) {
    _ensureHandle();
    final textPtr = text.toNativeUtf8();
    try {
      final result = _bindings.bwm_read_watermark_string(_handle!, textPtr);
      _checkResult(result);
      _watermarkBitLength = _bindings.bwm_get_watermark_size(_handle!);
    } finally {
      malloc.free(textPtr);
    }
  }

  /// Set image watermark from file (sync)
  ///
  /// The image will be binarized (thresholded at 128)
  void setWatermarkImageFile(String filename) {
    _ensureHandle();
    final filenamePtr = filename.toNativeUtf8();
    try {
      final result = _bindings.bwm_read_watermark_image(_handle!, filenamePtr);
      _checkResult(result);
      _watermarkBitLength = _bindings.bwm_get_watermark_size(_handle!);
    } finally {
      malloc.free(filenamePtr);
    }
  }

  /// Set bit array watermark (sync)
  void setWatermarkBits(List<bool> bits) {
    _ensureHandle();
    final bitsPtr = malloc<Uint8>(bits.length);
    try {
      for (int i = 0; i < bits.length; i++) {
        bitsPtr[i] = bits[i] ? 1 : 0;
      }
      final result = _bindings.bwm_read_watermark_bits(_handle!, bitsPtr, bits.length);
      _checkResult(result);
      _watermarkBitLength = bits.length;
    } finally {
      malloc.free(bitsPtr);
    }
  }

  /// Get watermark bit length
  int get watermarkBitLength => _watermarkBitLength ?? 0;

  /// Embed watermark and save to file (sync)
  void embedToFile(String outputFilename) {
    _ensureHandle();
    final filenamePtr = outputFilename.toNativeUtf8();
    try {
      final result = _bindings.bwm_embed(_handle!, filenamePtr);
      _checkResult(result);
    } finally {
      malloc.free(filenamePtr);
    }
  }

  /// Embed watermark and return as bytes (sync)
  ///
  /// [format] - Output format: "png", "jpg", or "webp" (default: "png")
  Uint8List embedToBytes({String format = 'png'}) {
    _ensureHandle();
    final outDataPtr = malloc<Pointer<Uint8>>();
    final outLengthPtr = malloc<Size>();
    final formatPtr = format.toNativeUtf8();

    try {
      final result = _bindings.bwm_embed_to_buffer(_handle!, outDataPtr, outLengthPtr, formatPtr);
      _checkResult(result);

      final length = outLengthPtr.value;
      final data = Uint8List.fromList(outDataPtr.value.asTypedList(length));

      _bindings.bwm_free_buffer(outDataPtr.value.cast());

      return data;
    } finally {
      malloc.free(outDataPtr);
      malloc.free(outLengthPtr);
      malloc.free(formatPtr);
    }
  }

  /// Extract string watermark from file (sync)
  ///
  /// [filename] - Input image file
  /// [wmLength] - Expected watermark bit length (from embedding)
  String extractStringFromFile(String filename, int wmLength) {
    _ensureHandle();
    final filenamePtr = filename.toNativeUtf8();
    final outTextPtr = malloc<Pointer<Utf8>>();

    try {
      final result = _bindings.bwm_extract_string(_handle!, filenamePtr, wmLength, outTextPtr);
      _checkResult(result);

      final textPtr = outTextPtr.value;
      int len = 0;
      while (textPtr.cast<Uint8>()[len] != 0) {
        len++;
      }
      final bytes = textPtr.cast<Uint8>().asTypedList(len);
      final text = utf8.decode(bytes, allowMalformed: true);
      _bindings.bwm_free_string(outTextPtr.value);

      return text;
    } finally {
      malloc.free(filenamePtr);
      malloc.free(outTextPtr);
    }
  }

  /// Extract string watermark from bytes (sync)
  String extractStringFromBytes(Uint8List imageData, int wmLength) {
    _ensureHandle();
    final dataPtr = malloc<Uint8>(imageData.length);
    final outTextPtr = malloc<Pointer<Utf8>>();

    try {
      dataPtr.asTypedList(imageData.length).setAll(0, imageData);
      final result = _bindings.bwm_extract_string_buffer(
          _handle!, dataPtr, imageData.length, wmLength, outTextPtr);
      _checkResult(result);

      final textPtr = outTextPtr.value;
      int len = 0;
      while (textPtr.cast<Uint8>()[len] != 0) {
        len++;
      }
      final bytes = textPtr.cast<Uint8>().asTypedList(len);
      final text = utf8.decode(bytes, allowMalformed: true);
      _bindings.bwm_free_string(outTextPtr.value);

      return text;
    } finally {
      malloc.free(dataPtr);
      malloc.free(outTextPtr);
    }
  }

  /// Extract image watermark from file (sync)
  void extractImageToFile(String inputFilename, int wmHeight, int wmWidth, String outputFilename) {
    _ensureHandle();
    final inputPtr = inputFilename.toNativeUtf8();
    final outputPtr = outputFilename.toNativeUtf8();

    try {
      final result = _bindings.bwm_extract_image(_handle!, inputPtr, wmHeight, wmWidth, outputPtr);
      _checkResult(result);
    } finally {
      malloc.free(inputPtr);
      malloc.free(outputPtr);
    }
  }

  /// Extract image watermark from bytes (sync)
  ///
  /// Returns the extracted watermark as PNG bytes
  Uint8List extractImageFromBytes(Uint8List imageData, int wmHeight, int wmWidth) {
    _ensureHandle();
    final dataPtr = malloc<Uint8>(imageData.length);
    final outDataPtr = malloc<Pointer<Uint8>>();
    final outLengthPtr = malloc<Size>();

    try {
      dataPtr.asTypedList(imageData.length).setAll(0, imageData);
      final result = _bindings.bwm_extract_image_buffer(
          _handle!, dataPtr, imageData.length, wmHeight, wmWidth, outDataPtr, outLengthPtr);
      _checkResult(result);

      final length = outLengthPtr.value;
      final data = Uint8List.fromList(outDataPtr.value.asTypedList(length));
      _bindings.bwm_free_buffer(outDataPtr.value.cast());

      return data;
    } finally {
      malloc.free(dataPtr);
      malloc.free(outDataPtr);
      malloc.free(outLengthPtr);
    }
  }

  /// Extract bit array watermark from file (sync)
  List<bool> extractBitsFromFile(String filename, int wmLength) {
    _ensureHandle();
    final filenamePtr = filename.toNativeUtf8();
    final outBitsPtr = malloc<Pointer<Uint8>>();

    try {
      final result = _bindings.bwm_extract_bits(_handle!, filenamePtr, wmLength, outBitsPtr);
      _checkResult(result);

      final bits = List<bool>.generate(wmLength, (i) => outBitsPtr.value[i] != 0);
      _bindings.bwm_free_buffer(outBitsPtr.value.cast());

      return bits;
    } finally {
      malloc.free(filenamePtr);
      malloc.free(outBitsPtr);
    }
  }

  /// Extract bit array watermark from bytes (sync)
  List<bool> extractBitsFromBytes(Uint8List imageData, int wmLength) {
    _ensureHandle();
    final dataPtr = malloc<Uint8>(imageData.length);
    final outBitsPtr = malloc<Pointer<Uint8>>();

    try {
      dataPtr.asTypedList(imageData.length).setAll(0, imageData);
      final result = _bindings.bwm_extract_bits_buffer(
          _handle!, dataPtr, imageData.length, wmLength, outBitsPtr);
      _checkResult(result);

      final bits = List<bool>.generate(wmLength, (i) => outBitsPtr.value[i] != 0);
      _bindings.bwm_free_buffer(outBitsPtr.value.cast());

      return bits;
    } finally {
      malloc.free(dataPtr);
      malloc.free(outBitsPtr);
    }
  }

  // ============================================================
  // ASYNCHRONOUS API (Isolate-based)
  // ============================================================

  /// Embed string watermark into image bytes asynchronously
  ///
  /// [imageData] - Source image bytes (PNG, JPEG, WebP, BMP, GIF)
  /// [watermarkText] - Text to embed
  /// [format] - Output format: "png", "jpg", or "webp" (default: "png")
  ///
  /// Returns a record containing the embedded image bytes and watermark bit length
  Future<({Uint8List imageBytes, int wmBitLength})> embedStringAsync(
    Uint8List imageData,
    String watermarkText, {
    String format = 'png',
  }) async {
    // Capture config values as local variables for isolate
    final passwordWm = _config.passwordWm;
    final passwordImg = _config.passwordImg;
    final d1 = _config.d1;
    final d2 = _config.d2;

    return Isolate.run(() {
      final bwm = BlindWatermark(
        passwordWm: passwordWm,
        passwordImg: passwordImg,
        d1: d1,
        d2: d2,
      );
      try {
        bwm.readImageBytes(imageData);
        bwm.setWatermarkString(watermarkText);
        final result = bwm.embedToBytes(format: format);
        return (imageBytes: result, wmBitLength: bwm.watermarkBitLength);
      } finally {
        bwm.dispose();
      }
    });
  }

  /// Embed bit array watermark into image bytes asynchronously
  ///
  /// [imageData] - Source image bytes (PNG, JPEG, WebP, BMP, GIF)
  /// [bits] - Bit array to embed
  /// [format] - Output format: "png", "jpg", or "webp" (default: "png")
  Future<Uint8List> embedBitsAsync(
    Uint8List imageData,
    List<bool> bits, {
    String format = 'png',
  }) async {
    // Capture config values as local variables for isolate
    final passwordWm = _config.passwordWm;
    final passwordImg = _config.passwordImg;
    final d1 = _config.d1;
    final d2 = _config.d2;

    return Isolate.run(() {
      final bwm = BlindWatermark(
        passwordWm: passwordWm,
        passwordImg: passwordImg,
        d1: d1,
        d2: d2,
      );
      try {
        bwm.readImageBytes(imageData);
        bwm.setWatermarkBits(bits);
        return bwm.embedToBytes(format: format);
      } finally {
        bwm.dispose();
      }
    });
  }

  /// Extract string watermark from image bytes asynchronously
  ///
  /// [imageData] - Image bytes containing watermark
  /// [wmLength] - Expected watermark bit length (from embedding)
  Future<String> extractStringAsync(Uint8List imageData, int wmLength) async {
    // Capture config values as local variables for isolate
    final passwordWm = _config.passwordWm;
    final passwordImg = _config.passwordImg;
    final d1 = _config.d1;
    final d2 = _config.d2;

    return Isolate.run(() {
      final bwm = BlindWatermark(
        passwordWm: passwordWm,
        passwordImg: passwordImg,
        d1: d1,
        d2: d2,
      );
      try {
        return bwm.extractStringFromBytes(imageData, wmLength);
      } finally {
        bwm.dispose();
      }
    });
  }

  /// Extract bit array watermark from image bytes asynchronously
  ///
  /// [imageData] - Image bytes containing watermark
  /// [wmLength] - Expected watermark bit length
  Future<List<bool>> extractBitsAsync(Uint8List imageData, int wmLength) async {
    // Capture config values as local variables for isolate
    final passwordWm = _config.passwordWm;
    final passwordImg = _config.passwordImg;
    final d1 = _config.d1;
    final d2 = _config.d2;

    return Isolate.run(() {
      final bwm = BlindWatermark(
        passwordWm: passwordWm,
        passwordImg: passwordImg,
        d1: d1,
        d2: d2,
      );
      try {
        return bwm.extractBitsFromBytes(imageData, wmLength);
      } finally {
        bwm.dispose();
      }
    });
  }

  /// Extract image watermark from image bytes asynchronously
  ///
  /// [imageData] - Image bytes containing watermark
  /// [wmHeight] - Watermark image height
  /// [wmWidth] - Watermark image width
  ///
  /// Returns the extracted watermark as PNG bytes
  Future<Uint8List> extractImageAsync(
    Uint8List imageData,
    int wmHeight,
    int wmWidth,
  ) async {
    // Capture config values as local variables for isolate
    final passwordWm = _config.passwordWm;
    final passwordImg = _config.passwordImg;
    final d1 = _config.d1;
    final d2 = _config.d2;

    return Isolate.run(() {
      final bwm = BlindWatermark(
        passwordWm: passwordWm,
        passwordImg: passwordImg,
        d1: d1,
        d2: d2,
      );
      try {
        return bwm.extractImageFromBytes(imageData, wmHeight, wmWidth);
      } finally {
        bwm.dispose();
      }
    });
  }

  // ============================================================
  // STATIC UTILITIES
  // ============================================================

  /// Get library version
  static String get version {
    final bindings = BlindWatermarkBindings.instance;
    return bindings.bwm_get_version().toDartString();
  }

  /// Dispose the instance and release resources
  void dispose() {
    if (_handle != null && _handle != nullptr) {
      _bindings.bwm_destroy(_handle!);
      _handle = null;
    }
  }
}

// ============================================================
// CONVENIENCE FUNCTIONS (Static one-shot operations)
// ============================================================

/// Embed a string watermark into an image (one-shot, sync)
///
/// This is a convenience function for simple use cases.
/// For multiple operations, create a [BlindWatermark] instance instead.
({Uint8List imageBytes, int wmBitLength}) embedStringWatermark(
  Uint8List imageData,
  String watermarkText, {
  String format = 'png',
  int passwordWm = 1,
  int passwordImg = 1,
  double d1 = 36.0,
  double d2 = 20.0,
}) {
  final bwm = BlindWatermark(
    passwordWm: passwordWm,
    passwordImg: passwordImg,
    d1: d1,
    d2: d2,
  );
  try {
    bwm.readImageBytes(imageData);
    bwm.setWatermarkString(watermarkText);
    final result = bwm.embedToBytes(format: format);
    return (imageBytes: result, wmBitLength: bwm.watermarkBitLength);
  } finally {
    bwm.dispose();
  }
}

/// Extract a string watermark from an image (one-shot, sync)
///
/// This is a convenience function for simple use cases.
/// For multiple operations, create a [BlindWatermark] instance instead.
String extractStringWatermark(
  Uint8List imageData,
  int wmLength, {
  int passwordWm = 1,
  int passwordImg = 1,
  double d1 = 36.0,
  double d2 = 20.0,
}) {
  final bwm = BlindWatermark(
    passwordWm: passwordWm,
    passwordImg: passwordImg,
    d1: d1,
    d2: d2,
  );
  try {
    return bwm.extractStringFromBytes(imageData, wmLength);
  } finally {
    bwm.dispose();
  }
}

/// Embed a string watermark into an image (one-shot, async)
///
/// This is a convenience function for simple use cases.
/// Runs in a separate isolate to avoid blocking the main thread.
Future<({Uint8List imageBytes, int wmBitLength})> embedStringWatermarkAsync(
  Uint8List imageData,
  String watermarkText, {
  String format = 'png',
  int passwordWm = 1,
  int passwordImg = 1,
  double d1 = 36.0,
  double d2 = 20.0,
}) async {
  return Isolate.run(() {
    return embedStringWatermark(
      imageData,
      watermarkText,
      format: format,
      passwordWm: passwordWm,
      passwordImg: passwordImg,
      d1: d1,
      d2: d2,
    );
  });
}

/// Extract a string watermark from an image (one-shot, async)
///
/// This is a convenience function for simple use cases.
/// Runs in a separate isolate to avoid blocking the main thread.
Future<String> extractStringWatermarkAsync(
  Uint8List imageData,
  int wmLength, {
  int passwordWm = 1,
  int passwordImg = 1,
  double d1 = 36.0,
  double d2 = 20.0,
}) async {
  return Isolate.run(() {
    return extractStringWatermark(
      imageData,
      wmLength,
      passwordWm: passwordWm,
      passwordImg: passwordImg,
      d1: d1,
      d2: d2,
    );
  });
}
