import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blind_watermark/flutter_blind_watermark.dart';
import 'package:gal/gal.dart';

import '../src/image_utils.dart';
import '../src/wam_bridge.dart';
import '../src/wam_codec.dart';
import '../src/wam_download.dart';

class ExtractPage extends StatefulWidget {
  const ExtractPage({super.key});

  @override
  State<ExtractPage> createState() => _ExtractPageState();
}

class _ExtractPageState extends State<ExtractPage> {
  Uint8List? _imageBytes;
  String? _imageName;

  bool _processing = false;
  String? _error;
  String? _statusText;
  String? _resultText;
  String? _resultNote;
  Uint8List? _resultImage;
  String? _wamCode;

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _pickImage() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    final raw = await File(file.path ?? '').readAsBytes();
    final png = await decodeToPng(raw);
    if (png == null) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('无法读取该图片格式')));
      }
      return;
    }
    setState(() {
      _imageBytes = png;
      _imageName = file.name;
      _error = null;
      _statusText = null;
      _resultText = null;
      _resultNote = null;
      _resultImage = null;
      _wamCode = null;
    });
  }

  Future<void> _extract() async {
    if (_imageBytes == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先选择图片')));
      return;
    }

    setState(() {
      _processing = true;
      _error = null;
      _statusText = '正在识别…';
      _resultText = null;
      _resultNote = null;
      _resultImage = null;
      _wamCode = null;
    });

    try {
      final bytes = _imageBytes!;
      final history = await WmHistory.all();
      var found = false;

      // 1) Strong-robust (WAM): no parameters needed.
      if (WamBridge.isSupported) {
        if (!mounted) return;
        final ready = await ensureWamModels(context);
        if (!ready) {
          if (mounted) {
            setState(() => _error = '强鲁棒模式需要下载模型后才能使用');
          }
          return;
        }
        if (mounted) setState(() => _statusText = '正在识别强鲁棒水印…');
        final bits = await WamBridge.extract(bytes);
        final code = WamCodec.bitsToStr(bits);
        final match = await WmHistory.matchWam(bits, 4);
        if (match != null) {
          found = true;
          if (mounted) {
            setState(() {
              _wamCode = code;
              _resultText = match.$1.text ?? '';
              _resultNote = '强鲁棒水印 · 匹配到本机记录（${match.$2} 位差异）';
            });
          }
        }
      }

      // 2) DWT text: try the most recent text records (skip if none).
      if (!found && history.any((e) => e.kind == 'text')) {
        if (mounted) setState(() => _statusText = '正在尝试文本水印…');
        final textRecs = history.where((e) => e.kind == 'text').take(10);
        for (final rec in textRecs) {
          final len = rec.len;
          if (len == null || len <= 0) continue;
          final result = await compute(
            _extractTextIsolate,
            (bytes, len, rec.pw),
          );
          if (result != null && result.isNotEmpty) {
            found = true;
            if (mounted) {
              setState(() {
                _resultText = result;
                _resultNote = '文本水印 · 自动匹配长度 $len';
              });
            }
            break;
          }
        }
      }

      // 3) DWT logo: try the most recent logo records (skip if none).
      if (!found && history.any((e) => e.kind == 'logo')) {
        if (mounted) setState(() => _statusText = '正在尝试 Logo 水印…');
        final logoRecs = history.where((e) => e.kind == 'logo').take(5);
        for (final rec in logoRecs) {
          final w = rec.w;
          final h = rec.h;
          if (w == null || h == null || w <= 0 || h <= 0) continue;
          final result = await compute(
            _extractLogoIsolate,
            (bytes, w, h, rec.pw),
          );
          if (result != null) {
            found = true;
            if (mounted) {
              setState(() {
                _resultImage = result;
                _resultNote = 'Logo 水印 · 自动匹配尺寸 ${w}x$h';
              });
            }
            break;
          }
        }
      }

      if (!found && mounted) {
        setState(() {
          _resultNote =
              '未检测到可识别的本机水印。水印参数（密码/长度）保存在嵌入时的那台设备上，请在同一设备提取；强鲁棒标识可在其他设备上识别出 32 位码';
          _resultText = '';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '提取失败：$e');
    } finally {
      if (mounted) {
        setState(() {
          _processing = false;
          _statusText = null;
        });
      }
    }
  }

  Future<void> _saveResult() async {
    if (_resultImage == null) return;
    final bytes = _resultImage!;
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        if (!await Gal.hasAccess()) {
          await Gal.requestAccess();
        }
        final name =
            'extracted_logo_${DateTime.now().millisecondsSinceEpoch}.png';
        await Gal.putImageBytes(bytes, name: name);
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('已保存到相册')));
        }
      } else {
        final out = await FilePicker.platform.saveFile(
          dialogTitle: '保存提取的水印图片',
          fileName: 'extracted_logo.png',
          type: FileType.image,
        );
        if (out != null) {
          await File(out).writeAsBytes(bytes);
          if (mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text('已保存到 $out')));
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('保存失败：$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: _pickImage,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AspectRatio(
                      aspectRatio: 4 / 3,
                      child: _imageBytes != null
                          ? Image.memory(_imageBytes!, fit: BoxFit.contain)
                          : ColoredBox(
                              color: colorScheme.surfaceContainerHighest,
                              child: Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.search,
                                        size: 48,
                                        color: colorScheme.onSurfaceVariant),
                                    const SizedBox(height: 8),
                                    Text('点击选择需要验证的图片',
                                        style: TextStyle(
                                            color:
                                                colorScheme.onSurfaceVariant)),
                                  ],
                                ),
                              ),
                            ),
                    ),
                    if (_imageName != null)
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(_imageName!,
                            style: TextStyle(
                                color: colorScheme.onSurfaceVariant,
                                fontSize: 12)),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            Text(
              '无需任何参数：自动识别强鲁棒水印 / 文本水印 / Logo 水印',
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 16),

            FilledButton.icon(
              onPressed: _processing ? null : _extract,
              icon: _processing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.manage_search),
              label: Text(_processing ? '正在提取…' : '提取水印'),
            ),
            if (_statusText != null) ...[
              const SizedBox(height: 8),
              Text(
                _statusText!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
            ],
            const SizedBox(height: 16),

            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeIn,
              transitionBuilder: (child, animation) =>
                  FadeTransition(opacity: animation, child: child),
              child: _error != null
                  ? Card(
                      key: ValueKey('error_${_error.hashCode}'),
                      color: colorScheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Expanded(
                                  child: Text('提取失败',
                                      style: TextStyle(
                                          fontWeight: FontWeight.bold)),
                                ),
                                IconButton(
                                  tooltip: '复制错误信息',
                                  onPressed: () {
                                    Clipboard.setData(
                                        ClipboardData(text: _error!));
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                          content: Text('错误信息已复制')),
                                    );
                                  },
                                  icon: const Icon(Icons.copy, size: 18),
                                ),
                              ],
                            ),
                            SelectableText(_error!),
                          ],
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),

            AnimatedSwitcher(
              duration: const Duration(milliseconds: 280),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeIn,
              transitionBuilder: (child, animation) =>
                  FadeTransition(opacity: animation, child: child),
              child: (_resultText != null || _resultNote != null)
                  ? Card(
                      key: ValueKey(
                          'result_${(_resultText ?? '')}_${(_resultNote ?? '')}'),
                      color: colorScheme.secondaryContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (_resultText != null &&
                                _resultText!.isNotEmpty) ...[
                              const Text('提取结果：',
                                  style: TextStyle(
                                      fontWeight: FontWeight.bold)),
                              const SizedBox(height: 8),
                              SelectableText(
                                _resultText!,
                                style: const TextStyle(fontSize: 18),
                              ),
                              const SizedBox(height: 8),
                            ],
                            if (_wamCode != null)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: SelectableText(
                                  '标识：$_wamCode',
                                  style: const TextStyle(
                                      fontSize: 14, letterSpacing: 1),
                                ),
                              ),
                            if (_resultNote != null)
                              Text(
                                _resultNote!,
                                style: TextStyle(
                                  color:
                                      _resultText == null || _resultText!.isEmpty
                                          ? colorScheme.error
                                          : colorScheme.onSurfaceVariant,
                                  fontSize: 12,
                                ),
                              ),
                          ],
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),

            AnimatedSwitcher(
              duration: const Duration(milliseconds: 280),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeIn,
              transitionBuilder: (child, animation) =>
                  FadeTransition(opacity: animation, child: child),
              child: _resultImage != null
                  ? Column(
                      key: const ValueKey('result_img'),
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Card(
                          clipBehavior: Clip.antiAlias,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              AspectRatio(
                                aspectRatio: 1,
                                child: Image.memory(_resultImage!,
                                    fit: BoxFit.contain),
                              ),
                              Padding(
                                padding: const EdgeInsets.all(8),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text('提取的 Logo',
                                        style: TextStyle(
                                            color: colorScheme
                                                .onSurfaceVariant,
                                            fontSize: 12)),
                                    const SizedBox(height: 4),
                                    Text('若为随机噪点则说明未检测到 Logo 水印',
                                        style: TextStyle(
                                            color: colorScheme.outline,
                                            fontSize: 11)),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: _saveResult,
                          icon: const Icon(Icons.download_outlined),
                          label: Text(Platform.isAndroid || Platform.isIOS
                              ? '保存到相册'
                              : '保存 Logo'),
                        ),
                      ],
                    )
                  : const SizedBox.shrink(),
            ),
            const SizedBox(height: 24),
            Text(
              '盲水印 v1.1.0',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colorScheme.outline,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// DWT text extract in a background isolate (top-level, AOT-safe).
/// Returns null when nothing readable was recovered.
String? _extractTextIsolate((Uint8List, int, int) args) {
  final (bytes, len, pw) = args;
  final bwm =
      BlindWatermark(passwordWm: pw, passwordImg: pw, d1: 36.0, d2: 20.0);
  try {
    final text = bwm.extractStringFromBytes(bytes, len);
    if (text.trim().isEmpty || text.contains('\uFFFD')) return null;
    return text;
  } catch (_) {
    return null;
  } finally {
    bwm.dispose();
  }
}

/// DWT logo extract in a background isolate (top-level, AOT-safe).
Uint8List? _extractLogoIsolate((Uint8List, int, int, int) args) {
  final (bytes, w, h, pw) = args;
  final bwm =
      BlindWatermark(passwordWm: pw, passwordImg: pw, d1: 36.0, d2: 20.0);
  try {
    return bwm.extractImageFromBytes(bytes, h, w);
  } catch (_) {
    return null;
  } finally {
    bwm.dispose();
  }
}


