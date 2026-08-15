import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Canvas, FilterQuality, Paint, Rect;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'wam_config.dart';

/// Bridge to the Android ONNX Runtime WAM (Watermark Anything) models.
///
/// WAM: Meta ICLR 2025, MIT. 32-bit message, robust to crop/rotation/JPEG.
/// embed: image -> 256px -> model -> watermarked 256px PNG
/// extract: image -> 256px -> model -> 32 decoded bits
class WamBridge {
  static const MethodChannel _channel = MethodChannel('wam');

  static bool get isSupported =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.android);

  /// True when both models are available (downloaded or bundled in assets).
  static Future<bool> modelReady() async {
    if (!isSupported) return false;
    return await _channel.invokeMethod<bool>('modelReady') ?? false;
  }

  /// Re-read model files after a download completed.
  static Future<void> reloadModels() async {
    await _channel.invokeMethod<void>('reloadModels');
  }

  /// Download dir for the models (application support dir/onnx).
  static Future<Directory> _modelDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/onnx');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Downloads both models with progress reporting.
  /// [onProgress] receives (downloadedBytes, totalBytes) per file.
  static Future<void> downloadModels(
      void Function(int done, int total) onProgress) async {
    final dir = await _modelDir();
    await _downloadFile(
      WamConfig.embedderUrl(),
      '${dir.path}/${WamConfig.embedderFile}',
      onProgress,
    );
    await _downloadFile(
      WamConfig.extractorUrl(),
      '${dir.path}/${WamConfig.extractorFile}',
      onProgress,
    );
    await reloadModels();
  }

  static Future<void> _downloadFile(
    String url,
    String dest,
    void Function(int done, int total) onProgress,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    try {
      final req = await client.getUrl(Uri.parse(url));
      final resp = await req.close();
      if (resp.statusCode != 200) {
        throw Exception('下载失败（HTTP ${resp.statusCode}）：$url');
      }
      final total = resp.contentLength;
      final file = File(dest);
      final sink = file.openWrite();
      var done = 0;
      await for (final chunk in resp) {
        sink.add(chunk);
        done += chunk.length;
        if (total > 0) onProgress(done, total);
      }
      await sink.close();
    } finally {
      client.close(force: true);
    }
  }

  /// Watermark an image with a 32-bit message.
  /// Returns a 256x256 PNG.
  static Future<Uint8List> embed(
      Uint8List imageBytes, List<int> bits) async {
    final result = await _channel.invokeMethod<Uint8List>('embed', {
      'img': imageBytes,
      'bits': bits.map((b) => b > 0 ? 1.0 : 0.0).toList(),
    });
    if (result == null) {
      throw Exception('WAM embed returned null');
    }
    return result;
  }

  /// Decode a 32-bit message from an image.
  static Future<List<int>> extract(Uint8List imageBytes) async {
    final result = await _channel.invokeMethod<List<dynamic>>(
        'extract', {'img': imageBytes});
    if (result == null) {
      throw Exception('WAM extract returned null');
    }
    return result.map((e) => (e as num).toInt()).toList();
  }

  /// Downscale an image to fit within [maxDim] (keeps aspect ratio),
  /// returns PNG bytes. Used before WAM embed (256 input).
  static Future<Uint8List?> resizePng(Uint8List bytes, int maxDim) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final img = frame.image;
      final w = img.width;
      final h = img.height;
      final scale = maxDim / (w > h ? w : h);
      final tw = (w * scale).round();
      final th = (h * scale).round();
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawImageRect(
        img,
        Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
        Rect.fromLTWH(0, 0, tw.toDouble(), th.toDouble()),
        Paint()..filterQuality = FilterQuality.medium,
      );
      final picture = recorder.endRecording();
      final out = await picture.toImage(tw, th);
      final data =
          await out.toByteData(format: ui.ImageByteFormat.png);
      img.dispose();
      out.dispose();
      codec.dispose();
      return data?.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }

  /// Upscale a 256x256 PNG to [targetW]x[targetH].
  static Future<Uint8List?> upscalePng(
      Uint8List bytes, int targetW, int targetH) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final img = frame.image;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawImageRect(
        img,
        Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        Rect.fromLTWH(
            0, 0, targetW.toDouble(), targetH.toDouble()),
        Paint()..filterQuality = FilterQuality.medium,
      );
      final picture = recorder.endRecording();
      final out = await picture.toImage(targetW, targetH);
      final data =
          await out.toByteData(format: ui.ImageByteFormat.png);
      img.dispose();
      out.dispose();
      codec.dispose();
      return data?.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }
}
