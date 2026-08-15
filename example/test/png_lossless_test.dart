import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_blind_watermark_example/src/image_utils.dart';

// Verifies that decodeToPng (Flutter-engine re-encode) is pixel-lossless,
// because the app re-encodes the picked image before handing it to C++.
void main() {
  test('decodeToPng is lossless for PNG input', () async {
    final dir = Directory.current;
    final src = File('${dir.path}/test_embedded.png');
    if (!src.existsSync()) {
      // Generate a test image through the engine instead.
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawColor(const Color(0xFF336699), BlendMode.src);
      final picture = recorder.endRecording();
      final img = await picture.toImage(64, 64);
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      final generated = data!.buffer.asUint8List();
      await src.writeAsBytes(generated);
    }
    final original = await src.readAsBytes();
    final reencoded = await decodeToPng(original);
    expect(reencoded, isNotNull);

    // Decode both and compare raw pixels.
    Future<Uint8List> rawPixels(Uint8List bytes) async {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final img = frame.image;
      final d = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      img.dispose();
      codec.dispose();
      return d!.buffer.asUint8List();
    }

    final a = await rawPixels(original);
    final b = await rawPixels(reencoded!);
    expect(a.length, b.length, reason: 'dimension/format changed');
    var diffs = 0;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) diffs++;
    }
    expect(diffs, 0, reason: '$diffs pixels differ after re-encode');
  });
}
