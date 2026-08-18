import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' hide Size;
import 'package:flutter_blind_watermark/src/blind_watermark_bindings.dart';

/// WAM embed in a background isolate (top-level, AOT-safe).
Uint8List wamEmbedIsolate((Uint8List, List<int>, String) args) {
  final (png, bits, modelsDir) = args;
  WamBridge.setModelsDir(modelsDir);
  return WamBridge.embedSync(png, bits);
}

/// WAM extract in a background isolate; returns (ok, bits, confidence).
/// confidence = mean |bit margin| (higher = more reliable decode), used to
/// pick the best result among multiple extraction attempts.
(bool, List<int>, double) wamExtractIsolate((Uint8List, String) args) {
  final (png, modelsDir) = args;
  WamBridge.setModelsDir(modelsDir);
  try {
    final (bits, conf) = WamBridge.extractSync(png);
    return (true, bits, conf);
  } catch (_) {
    return (false, const [], 0.0);
  }
}

///
/// The previous implementation used the ai.onnxruntime Java/JNI bridge, which
/// aborts with SIGABRT inside sess.run on Android 16 (ART JNI fatal). The ORT
/// C core was verified locally with the exact same models and shapes; calling
/// it from Dart FFI removes the failing Java/JNI layer entirely.
class WamBridge {
  static bool get isSupported =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.android);

  static const int _errCap = 512;

  /// Directory with the bundled model files, extracted by the host app
  /// (Kotlin filesDir/models). Null when unavailable.
  static Future<String?> getModelsDir() async {
    if (!isSupported) return null;
    try {
      return await const MethodChannel('wam').invokeMethod<String>('modelDir');
    } catch (_) {
      return null;
    }
  }

  /// Sets the directory containing wam_embedder.onnx / wam_extractor_int8.onnx
  /// (extracted by the host app). Must be called in the isolate that runs the
  /// inference.
  static void setModelsDir(String dir) {
    final b = BlindWatermarkBindings.instance;
    final p = dir.toNativeUtf8();
    try {
      b.bwm_wam_set_models_dir(p);
    } finally {
      malloc.free(p);
    }
  }

  /// Watermark [pngBytes] (any size — the native side stretches to 256) with
  /// a 32-bit message. Returns the watermarked PNG at the carrier's original
  /// resolution (sharp full-res output).
  static Uint8List embedSync(Uint8List pngBytes, List<int> bits) {
    final b = BlindWatermarkBindings.instance;
    final pngPtr = malloc<Uint8>(pngBytes.length);
    try {
      pngPtr.asTypedList(pngBytes.length).setAll(0, pngBytes);
      final msg = malloc<Float>(32);
      try {
        for (var i = 0; i < 32; i++) {
          msg[i] = i < bits.length && bits[i] > 0 ? 1.0 : 0.0;
        }
        final outPtr = malloc<Pointer<Uint8>>();
        final outLen = malloc<Size>();
        final err = malloc<Uint8>(_errCap).cast<Utf8>();
        try {
          final rc = b.bwm_wam_embed(
              pngPtr, pngBytes.length, msg, outPtr, outLen, err, _errCap);
          if (rc != 0) {
            throw Exception('WAM embed failed: ${err.toDartString()}');
          }
          final len = outLen.value;
          final data = Uint8List.fromList(outPtr.value.asTypedList(len));
          b.bwm_free_buffer(outPtr.value.cast());
          return data;
        } finally {
          malloc.free(outPtr);
          malloc.free(outLen);
          malloc.free(err);
        }
      } finally {
        malloc.free(msg);
      }
    } finally {
      malloc.free(pngPtr);
    }
  }

  /// Decodes the 32-bit message from [pngBytes]; returns (bits, confidence).
  static (List<int>, double) extractSync(Uint8List pngBytes) {
    final b = BlindWatermarkBindings.instance;
    final pngPtr = malloc<Uint8>(pngBytes.length);
    try {
      pngPtr.asTypedList(pngBytes.length).setAll(0, pngBytes);
      final bits = malloc<Uint8>(32);
      final conf = malloc<Float>();
      final err = malloc<Uint8>(_errCap).cast<Utf8>();
      try {
        final rc = b.bwm_wam_extract(
            pngPtr, pngBytes.length, bits, conf, err, _errCap);
        if (rc != 0) {
          throw Exception('WAM extract failed: ${err.toDartString()}');
        }
        return (
          List<int>.generate(32, (i) => bits[i] != 0 ? 1 : 0),
          conf.value.toDouble(),
        );
      } finally {
        malloc.free(bits);
        malloc.free(conf);
        malloc.free(err);
      }
    } finally {
      malloc.free(pngPtr);
    }
  }
}
