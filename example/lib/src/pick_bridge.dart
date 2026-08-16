import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Picks an image through the platform document picker and reads the bytes
/// DIRECTLY from the content URI — no cache copy, no disk write.
///
/// file_picker always writes a cache copy of the picked file (even with
/// withData:true) and only cleans it when asked; some ROM galleries index
/// that directory and show a ghost image in the album. Reading the URI
/// stream in memory makes gallery pollution impossible.
class PickBridge {
  static const MethodChannel _channel = MethodChannel('wam');

  /// Returns (bytes, displayName) or null when cancelled / unsupported.
  static Future<(Uint8List, String)?> pickImage() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return null;
    }
    try {
      final result =
          await _channel.invokeMethod<Map<dynamic, dynamic>>('pickImage');
      if (result == null) return null;
      final bytes = result['bytes'];
      final name = result['name'];
      if (bytes is! Uint8List) return null;
      return (bytes, name is String ? name : 'image');
    } catch (_) {
      return null;
    }
  }
}
