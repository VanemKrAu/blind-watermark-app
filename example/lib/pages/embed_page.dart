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

class EmbedPage extends StatefulWidget {
  const EmbedPage({super.key, this.onGoExtract});

  /// Called when the user taps "去验证" after a successful embed,
  /// switching the app to the extract tab.
  final VoidCallback? onGoExtract;

  @override
  State<EmbedPage> createState() => _EmbedPageState();
}

enum _InputType { text, image }

class _EmbedPageState extends State<EmbedPage> {
  Uint8List? _imageBytes;
  Uint8List? _resultBytes;
  String? _imageName;
  int? _wmBitLength;
  String? _wamCode;
  String? _methodNote;

  _InputType _inputType = _InputType.text;
  final TextEditingController _textController = TextEditingController();
  final TextEditingController _passwordController =
      TextEditingController(text: '1');
  Uint8List? _logoBytes;
  String? _logoName;

  bool _processing = false;
  String? _error;

  @override
  void dispose() {
    _textController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    final path = file.path;
    final raw = path != null ? await File(path).readAsBytes() : file.bytes;
    if (raw == null) return;
    // file_picker copies the picked photo into the app cache dir; some ROM
    // galleries index that directory, so photos appear in the gallery out
    // of nowhere. Delete the cache copy right away.
    if (path != null) {
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
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
      _resultBytes = null;
      _wmBitLength = null;
      _wamCode = null;
      _methodNote = null;
      _error = null;
    });
  }

  Future<void> _pickLogo() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    final path = file.path;
    final bytes = path != null ? await File(path).readAsBytes() : file.bytes;
    if (bytes == null) return;
    if (path != null) {
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    setState(() {

      _logoBytes = bytes;
      _logoName = file.name;
      _resultBytes = null;
      _wmBitLength = null;
      _wamCode = null;
      _methodNote = null;
    });
  }

  void _clearResult() {
    setState(() {
      _resultBytes = null;
      _wmBitLength = null;
      _wamCode = null;
      _methodNote = null;
    });
  }

  /// Whether the WAM (strong-robust) scheme should be used for this image:
  /// only for small-ish photos (long edge <= 1024) — WAM embeds at 256px and
  /// upscales back, which would blur large images. Large images use DWT.
  Future<bool> _useWam(Uint8List bytes) async {
    if (!WamBridge.isSupported) return false;
    final size = await imageSize(bytes);
    if (size == null) return false;
    final longEdge = size.$1 > size.$2 ? size.$1 : size.$2;
    return longEdge <= 1024;
  }

  Future<void> _embed() async {
    if (_imageBytes == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先选择图片')));
      return;
    }
    if (_inputType == _InputType.text && _textController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请输入水印文本')));
      return;
    }
    if (_inputType == _InputType.image && _logoBytes == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请选择水印 Logo 图片')));
      return;
    }

    setState(() {
      _processing = true;
      _error = null;
      _resultBytes = null;
      _wmBitLength = null;
      _wamCode = null;
      _methodNote = null;
    });

    try {
      final bytes = _imageBytes!;
      final inputType = _inputType;
      // Security: derive DWT seeds from the user password.
      final (pwWm, pwImg) = WmSecurity.seeds(_passwordController.text);

      if (inputType == _InputType.image) {
        // Logo watermark: always DWT (keeps full resolution).
        final logoBytes = _logoBytes!;
        // The native side loads the logo from a file path; write a temp copy.
        final tmp = File(
            '${Directory.systemTemp.path}/bwm_logo_${DateTime.now().millisecondsSinceEpoch}.png');
        await tmp.writeAsBytes(logoBytes, flush: true);
        try {
          final logoSize = await imageSize(logoBytes);
          final size = await imageSize(bytes);
          if (size == null || logoSize == null) {
            throw Exception('图片解析失败');
          }
          final capacity = (size.$1 ~/ 8) * (size.$2 ~/ 8) - 1;
          final need = logoSize.$1 * logoSize.$2;
          if (need > capacity) {
            throw Exception('Logo 过大：图片最多容纳约 $capacity bit，Logo 需 $need bit。请缩小 Logo 或换更大的图片。');
          }
          final result = await compute(
            _embedLogoIsolate,
            (bytes, tmp.path, pwWm, pwImg),
          );
          await WmHistory.add(WmRecord(
            kind: 'logo',
            w: logoSize.$1,
            h: logoSize.$2,
            pw: pwWm,
          ));
          if (mounted) {
            setState(() {
              _resultBytes = result;
              _methodNote = 'Logo 水印（保持画质）';
            });
          }
        } finally {
          try {
            if (await tmp.exists()) await tmp.delete();
          } catch (_) {}
        }
      } else {
        final text = _textController.text.trim();
        final useWam = await _useWam(bytes);

        if (useWam) {
          if (!mounted) return;
          final ready = await ensureWamModels(context);
          if (!ready) {
            if (mounted) {
              setState(() => _error = '强鲁棒模式需要下载模型后才能使用');
            }
            return;
          }
          // Strong-robust short code (survives crop/rotation/compression).
          final bits = WamCodec.textToBits(text);
          final code = WamCodec.bitsToStr(bits);
          final small = await WamBridge.resizePng(bytes, 256);
          if (small == null) throw Exception('图片缩放失败');
          final wm256 = await WamBridge.embed(small, bits);
          final size = await imageSize(bytes);
          final result = (size != null)
              ? await WamBridge.upscalePng(wm256, size.$1, size.$2) ?? wm256
              : wm256;
          await WmHistory.add(WmRecord(
            kind: 'wam',
            text: text,
            code: code,
            pw: pwWm,
          ));
          if (mounted) {
            setState(() {
              _resultBytes = result;
              _wamCode = code;
              _methodNote = '强鲁棒水印（抗裁剪/旋转/压缩）';
            });
          }
        } else {
          // Long text on large image: DWT keeps full resolution.
          final result = await compute(
            _embedTextIsolate,
            (bytes, text, pwWm, pwImg),
          );
          await WmHistory.add(WmRecord(
            kind: 'text',
            text: text,
            len: result.$2,
            pw: pwWm,
          ));
          if (mounted) {
            setState(() {
              _resultBytes = result.$1;
              _wmBitLength = result.$2;
              _methodNote = '文本水印（保持画质）';
            });
          }
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('水印已嵌入')),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = '嵌入失败：$e');
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<void> _saveResult() async {
    if (_resultBytes == null) return;
    final bytes = _resultBytes!;
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        // Android 9 and below need explicit storage permission; gal handles
        // the request flow, but we must gate on it first.
        if (!await Gal.hasAccess()) {
          await Gal.requestAccess();
        }
        final name =
            'watermarked_${DateTime.now().millisecondsSinceEpoch}.png';
        await Gal.putImageBytes(bytes, name: name);
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('已保存到相册')));
        }
      } else {
        final out = await FilePicker.platform.saveFile(
          dialogTitle: '保存打水印后的图片',
          fileName: 'watermarked.png',
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
            _ImagePickerCard(
              bytes: _imageBytes,
              name: _imageName,
              onPick: _pickImage,
              placeholder: '点击选择需要保护的图片',
            ),
            const SizedBox(height: 16),

            SegmentedButton<_InputType>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: _InputType.text,
                  icon: Icon(Icons.text_fields),
                  label: Text('文本'),
                ),
                ButtonSegment(
                  value: _InputType.image,
                  icon: Icon(Icons.image_outlined),
                  label: Text('Logo'),
                ),
              ],
              selected: {_inputType},
              onSelectionChanged: (s) {
                setState(() => _inputType = s.first);
                _clearResult();
              },
            ),
            const SizedBox(height: 16),

            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeIn,
              transitionBuilder: (child, animation) =>
                  FadeTransition(opacity: animation, child: child),
              child: SizedBox(
                key: ValueKey(_inputType),
                height: 96,
                child: _inputType == _InputType.text
                    ? TextField(
                        controller: _textController,
                        maxLines: 2,
                        decoration: const InputDecoration(
                          labelText: '水印内容',
                          hintText: '输入要隐藏的文本（如作者名、链接）',
                          border: OutlineInputBorder(),
                          alignLabelWithHint: true,
                        ),
                      )
                    : OutlinedButton.icon(
                        onPressed: _pickLogo,
                        icon: const Icon(Icons.add_photo_alternate_outlined),
                        label: Text(_logoBytes == null
                            ? '选择 Logo 图片'
                            : 'Logo: $_logoName'),
                      ),
              ),
            ),
            const SizedBox(height: 8),

            Text(
              '无需选择方案：小图自动使用强鲁棒水印（抗裁剪/旋转/压缩），大图与 Logo 自动保持原画质',
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 8),

            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('高级选项（可选）'),
              subtitle: const Text('密码用于保护水印，提取需与本机记录一致'),
              childrenPadding: const EdgeInsets.only(top: 16, bottom: 8),
              children: [
                TextField(
                  controller: _passwordController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '水印密码',
                    hintText: '默认 1，可自定义（建议设置）',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            FilledButton.icon(
              onPressed: _processing ? null : _embed,
              icon: _processing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.water_drop),
              label: Text(_processing ? '正在嵌入…' : '嵌入水印'),
            ),
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
                                  child: Text('嵌入失败',
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
              child: _resultBytes != null
                  ? Column(
                      key: const ValueKey('result'),
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Card(
                          clipBehavior: Clip.antiAlias,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              AspectRatio(
                                aspectRatio: 1,
                                child: Image.memory(_resultBytes!,
                                    fit: BoxFit.contain),
                              ),
                              Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        const Icon(Icons.check_circle,
                                            size: 18, color: Colors.green),
                                        const SizedBox(width: 6),
                                        const Text('嵌入完成',
                                            style: TextStyle(
                                                fontWeight:
                                                    FontWeight.bold)),
                                        const Spacer(),
                                        if (_wamCode != null)
                                          Text(
                                            '标识 ${_wamCode!.substring(0, 8)}…',
                                            style: TextStyle(
                                              color: colorScheme.primary,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          )
                                        else if (_wmBitLength != null)
                                          Text(
                                            '长度 $_wmBitLength bit',
                                            style: TextStyle(
                                              color: colorScheme.primary,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                      ],
                                    ),
                                    if (_methodNote != null) ...[
                                      const SizedBox(height: 4),
                                      Text(
                                        _methodNote!,
                                        style: TextStyle(
                                            color:
                                                colorScheme.onSurfaceVariant,
                                            fontSize: 12),
                                      ),
                                    ],
                                    const SizedBox(height: 4),
                                    Text(
                                      '提取页选择同一张图片即可自动识别',
                                      style: TextStyle(
                                          color:
                                              colorScheme.onSurfaceVariant,
                                          fontSize: 12),
                                    ),
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
                              : '保存图片'),
                        ),
                        if (widget.onGoExtract != null) ...[
                          const SizedBox(height: 8),
                          FilledButton.tonalIcon(
                            onPressed: widget.onGoExtract,
                            icon: const Icon(Icons.manage_search),
                            label: const Text('去验证水印'),
                          ),
                        ],
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

/// DWT text embed in a background isolate (top-level, AOT-safe).
(Uint8List, int) _embedTextIsolate((Uint8List, String, int, int) args) {
  final (bytes, text, pwWm, pwImg) = args;
  final bwm = BlindWatermark(passwordWm: pwWm, passwordImg: pwImg, d1: 36.0, d2: 20.0);
  try {
    bwm.readImageBytes(bytes);
    bwm.setWatermarkString(text);
    final out = bwm.embedToBytes(format: 'png');
    return (out, bwm.watermarkBitLength);
  } finally {
    bwm.dispose();
  }
}

/// DWT logo embed in a background isolate (top-level, AOT-safe).
Uint8List _embedLogoIsolate((Uint8List, String, int, int) args) {
  final (bytes, logoPath, pwWm, pwImg) = args;
  final bwm = BlindWatermark(passwordWm: pwWm, passwordImg: pwImg, d1: 36.0, d2: 20.0);
  try {
    bwm.readImageBytes(bytes);
    bwm.setWatermarkImageFile(logoPath);
    return bwm.embedToBytes(format: 'png');
  } finally {
    bwm.dispose();
  }
}

class _ImagePickerCard extends StatelessWidget {
  const _ImagePickerCard({
    required this.bytes,
    required this.onPick,
    required this.placeholder,
    this.name,
  });

  final Uint8List? bytes;
  final String? name;
  final String placeholder;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPick,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 4 / 3,
              child: bytes != null
                  ? Image.memory(bytes!, fit: BoxFit.contain)
                  : ColoredBox(
                      color: colorScheme.surfaceContainerHighest,
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.add_photo_alternate_outlined,
                                size: 48,
                                color: colorScheme.onSurfaceVariant),
                            const SizedBox(height: 8),
                            Text(placeholder,
                                style: TextStyle(
                                    color: colorScheme.onSurfaceVariant)),
                          ],
                        ),
                      ),
                    ),
            ),
            if (name != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(name!,
                    style: TextStyle(
                        color: colorScheme.onSurfaceVariant, fontSize: 12)),
              ),
          ],
        ),
      ),
    );
  }
}



