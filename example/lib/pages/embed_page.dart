import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blind_watermark/flutter_blind_watermark.dart';
import 'package:gal/gal.dart';

import '../src/image_utils.dart';
import '../src/pick_bridge.dart';
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

/// Max long edge for DWT embedding. The DWT-DCT-SVD pipeline holds ~2.5x the
/// image as YUV double matrices: a 12MP photo peaks at ~1GB native memory and
/// kills the app (LMK) on phones. 1536 keeps the peak around ~110MB — safe
/// even on low-RAM devices — while staying sharp enough for sharing.
/// Extraction is unaffected: the block grid derives from the image's own
/// size, and the saved watermarked image keeps this size.
const int _dwtMaxLongEdge = 1536;

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

  /// Picks an image file, reading bytes straight into memory.
  ///
  /// On Android the platform picker reads the content URI directly (no cache
  /// copy — ROM galleries can never index a transient file); elsewhere falls
  /// back to file_picker (withData).
  Future<(Uint8List, String)?> _pickImageRaw() async {
    if (Platform.isAndroid) {
      return await PickBridge.pickImage();
    }
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;
    final file = result.files.first;
    final raw = file.bytes;
    if (raw == null) return null;
    return (raw, file.name);
  }

  Future<void> _pickImage() async {
    final picked = await _pickImageRaw();
    if (picked == null) return;
    final rawBytes = picked.$1;
    final rawName = picked.$2;
    // Decode with an engine-side scaled decode: camera photos (12-108MP)
    // never materialize at full resolution in app memory — that alone could
    // get the process killed before embedding even starts. Images at or
    // below the DWT cap are kept unchanged.
    final scaled =
        await decodeToPngScaled(rawBytes, maxDim: _dwtMaxLongEdge);
    if (scaled == null) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('无法读取该图片格式')));
      }
      return;
    }
    setState(() {
      _imageBytes = scaled.$1;
      _imageName = rawName;
      _resultBytes = null;
      _wmBitLength = null;
      _wamCode = null;
      _methodNote = null;
      _error = null;
    });
  }

  Future<void> _pickLogo() async {
    final picked = await _pickImageRaw();
    if (picked == null) return;
    // Re-encode through the Flutter engine: the native side (stb_image)
    // cannot decode HEIC/AVIF logos.
    final png = await decodeToPng(picked.$1);
    if (png == null) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('无法读取该 Logo 图片格式')));
      }
      return;
    }
    setState(() {
      _logoBytes = png;
      _logoName = picked.$2;
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
        final logoSize = await imageSize(logoBytes);
        final size = await imageSize(bytes);
        if (size == null || logoSize == null) {
          throw Exception('图片解析失败');
        }
        // Downscale huge carriers before DWT: the native pipeline holds
        // ~2.5x the image as YUV doubles (12MP photo ≈ 1GB peak) and gets
        // killed by the OS on phones.
        final (carrier, cw, ch) = await _fitDwtCarrier(bytes, size);
        final capacity = (cw ~/ 8) * (ch ~/ 8) - 1;
        final need = logoSize.$1 * logoSize.$2;
        if (need > capacity) {
          throw Exception('Logo 过大：图片最多容纳约 $capacity bit，Logo 需 $need bit。请缩小 Logo 或换更大的图片。');
        }
        // The native side loads the logo from a file path; write a temp copy.
        final tmp = File(
            '${Directory.systemTemp.path}/bwm_logo_${DateTime.now().millisecondsSinceEpoch}.png');
        await tmp.writeAsBytes(logoBytes, flush: true);
        try {
          final result = await compute(
            _embedLogoIsolate,
            (carrier, tmp.path, pwWm, pwImg),
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
              _methodNote = 'Logo 水印（尺寸已适配）';
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
        // WAM is preferred for small images; if it's not applicable, its
        // models are missing, or inference fails at runtime (e.g. broken
        // model files), fall back to DWT with the same text instead of
        // erroring out.
        var wamUnavailable = false;
        if (useWam && await ensureWamModels(context)) {
          try {
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
          } catch (_) {
            wamUnavailable = true;
          }
        } else {
          wamUnavailable = useWam;
        }
        if (!useWam || wamUnavailable) {
          // Long text on large image: DWT keeps full resolution.
          // Capacity check first: text bits must fit the 4x4 block grid.
          final size = await imageSize(bytes);
          var carrier = bytes;
          if (size != null) {
            final (fit, cw, ch) = await _fitDwtCarrier(bytes, size);
            carrier = fit;
            final capacity = (cw ~/ 8) * (ch ~/ 8) - 1;
            final bitLen = utf8.encode(text).length * 8;
            if (bitLen > capacity) {
              throw Exception(
                  '水印超出容量：图片最多容纳约 $capacity bit，当前文本约需 $bitLen bit。请缩短文本或换更大的图片。');
            }
          }
          final result = await compute(
            _embedTextIsolate,
            (carrier, text, pwWm, pwImg),
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
              _methodNote = wamUnavailable
                  ? '文本水印（强鲁棒不可用，已自动回退）'
                  : '文本水印（尺寸已适配）';
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

  /// Returns (carrierBytes, width, height) for DWT embedding: downscales
  /// [bytes] so its long edge <= [_dwtMaxLongEdge] (never upscales).
  Future<(Uint8List, int, int)> _fitDwtCarrier(
      Uint8List bytes, (int, int) size) async {
    final longEdge = size.$1 > size.$2 ? size.$1 : size.$2;
    if (longEdge <= _dwtMaxLongEdge) return (bytes, size.$1, size.$2);
    final scaled = await downscalePng(bytes, _dwtMaxLongEdge);
    if (scaled == null) throw Exception('图片缩放失败');
    return scaled;
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
              '无需选择方案：小图自动使用强鲁棒水印（抗裁剪/旋转/压缩），大图与 Logo 自动适配尺寸（超大图先缩至 2048px 内以保证稳定）',
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
              '盲水印 v1.1.9',
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





