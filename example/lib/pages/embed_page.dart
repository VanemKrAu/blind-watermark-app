import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blind_watermark/flutter_blind_watermark.dart';
import 'package:gal/gal.dart';

import '../src/app_version.dart';
import '../src/haptics.dart';
import '../src/image_utils.dart';
import '../src/page_header.dart';
import '../src/pick_bridge.dart';
import '../src/wam_bridge.dart';
import '../src/wam_codec.dart';

class EmbedPage extends StatefulWidget {
  const EmbedPage({super.key, this.onGoExtract});

  /// Called when the user taps "去验证" after a successful embed,
  /// switching the app to the extract tab.
  final VoidCallback? onGoExtract;

  @override
  State<EmbedPage> createState() => _EmbedPageState();
}

enum _InputType { text, image }

/// 文本水印的嵌入方案：WAM 强鲁棒（默认）或经典 DWT。
enum _TextScheme { wam, dwt }

/// DWT 嵌入分辨率限制（用户决策 2026-08-18）：彻底取消——图片多大就原尺寸
/// 嵌入（13MP 真机实测无闪退）。代价：超大图嵌入耗时长，进度条明示。
const int _dwtMaxLongEdge = 100000;

class _EmbedPageState extends State<EmbedPage> {
  /// 原始选图字节（不解码常驻，嵌入时按需解码全尺寸）。
  Uint8List? _imageRaw;
  /// 预览/处理小图（长边 ≤1024，选图秒开；WAM 可直接用）。
  Uint8List? _imageBytes;
  Uint8List? _resultBytes;
  String? _imageName;
  int? _wmBitLength;
  String? _wamCode;
  String? _methodNote;

  _InputType _inputType = _InputType.text;
  _TextScheme _textScheme = _TextScheme.wam;
  final TextEditingController _textController = TextEditingController();
  final TextEditingController _passwordController =
      TextEditingController(text: '1');
  Uint8List? _logoBytes;
  String? _logoName;

  bool _processing = false;
  String? _error;
  String? _statusText;

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
    // 预览只解码小图（长边 ≤1024）：全分辨率解码+PNG 重编码要好几秒，
    // 预览框无需那么大；原始字节保留，嵌入时按需解码（_decodeWork）。
    final preview =
        await decodeToPngScaled(rawBytes, maxDim: 1024);
    if (preview == null) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('无法读取该图片格式')));
      }
      return;
    }
    setState(() {
      _imageRaw = rawBytes;
      _imageBytes = preview.$1;
      _imageName = rawName;
      _resultBytes = null;
      _wmBitLength = null;
      _wamCode = null;
      _methodNote = null;
      _error = null;
    });
  }

  /// 嵌入工作图：按需全尺寸解码（长边 ≤[_dwtMaxLongEdge]），供 WAM/DWT 使用。
  Future<Uint8List> _decodeWork() async {
    final raw = _imageRaw ?? _imageBytes!;
    final scaled = await decodeToPngScaled(raw, maxDim: _dwtMaxLongEdge);
    if (scaled == null) throw Exception('图片解码失败');
    return scaled.$1;
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
      _statusText = '正在解码图片…';
      _resultBytes = null;
      _wmBitLength = null;
      _wamCode = null;
      _methodNote = null;
    });

    try {
      // 全尺寸工作图：仅在嵌入时解码（选图预览已用小图，秒开）。
      final bytes = await _decodeWork();
      if (mounted) {
        setState(() =>
            _statusText = '正在嵌入水印…（图片较大可能需要较长时间）');
      }
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
            cw: cw,
            ch: ch,
          ));
          if (mounted) {
            setState(() {
              _resultBytes = result;
              _methodNote = 'Logo 水印 ${logoSize.$1}x${logoSize.$2}（DWT，完整还原）';
            });
          }
        } finally {
          try {
            if (await tmp.exists()) await tmp.delete();
          } catch (_) {}
        }
      } else {
        final text = _textController.text.trim();
        if (_textScheme == _TextScheme.dwt) {
          // 经典 DWT（用户主动选择）：密码+长度可在任意设备还原完整文本，
          // 但容量有限、不抗几何攻击（旋转尤其弱）、分辨率无上限。
          await _embedTextDwt(bytes, text, pwWm, pwImg, explicit: true);
        } else {
          // Text watermark: default strong-robust (WAM) scheme, regardless of
          // image size — the native side now embeds at 256px and reconstructs a
          // sharp full-resolution output (upscaled delta blended with the sharp
          // carrier). Survives crop/rotation/compression. On another device only
          // the 32-bit code is visible (text recovery needs this device's
          // history). Falls back to DWT text if the models are missing or
          // inference fails at runtime.
          var wamUnavailable = false;
          try {
            final modelsDir = await WamBridge.getModelsDir();
            if (modelsDir == null) throw Exception('模型目录不可用');
            final bits = WamCodec.textToBits(text);
            final code = WamCodec.bitsToStr(bits);
            final result =
                await compute(wamEmbedIsolate, (bytes, bits, modelsDir));
            // 载体尺寸（水印图尺寸）：供提取时「还原回原尺寸」再同步网格。
            final (carrierW, carrierH) = (await imageSize(result)) ?? (0, 0);
            await WmHistory.add(WmRecord(
              kind: 'wam',
              text: text,
              code: code,
              pw: pwWm,
              cw: carrierW,
              ch: carrierH,
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
          if (wamUnavailable) {
            // Fallback: DWT text (legacy scheme / model missing).
            await _embedTextDwt(bytes, text, pwWm, pwImg);
          }
        }
      }

      if (mounted) {
        Haptics.success();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('水印已嵌入')),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = '嵌入失败：$e');
    } finally {
      if (mounted) {
        setState(() {
          _processing = false;
          _statusText = null;
        });
      }
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

  /// 经典 DWT 文本嵌入：容量预校验 + isolate 嵌入（分辨率无上限）。
  /// 记录 kind='text'（含载体尺寸 cw/ch，提取时启用「网格再同步」还原）。
  /// [bytes] 为嵌入工作图（全尺寸解码后，≤[_dwtMaxLongEdge]）。
  /// [explicit] 表示用户主动选择 DWT（而非 WAM 失败回退），用于文案区分。
  Future<void> _embedTextDwt(Uint8List bytes, String text, int pwWm, int pwImg,
      {bool explicit = false}) async {
    final size = await imageSize(bytes);
    var carrier = bytes;
    var cw = size?.$1 ?? 0;
    var ch = size?.$2 ?? 0;
    if (size != null) {
      final (fit, fitCw, fitCh) = await _fitDwtCarrier(bytes, size);
      carrier = fit;
      cw = fitCw;
      ch = fitCh;
      final capacity = (cw ~/ 8) * (ch ~/ 8) - 1;
      final bitLen = utf8.encode(text).length * 8;
      if (bitLen > capacity) {
        throw Exception(explicit
            ? '水印超出容量：图片最多容纳约 $capacity bit，当前文本约需 $bitLen bit。请缩短文本、换更大的图片，或改用强鲁棒方案。'
            : '水印超出容量：图片最多容纳约 $capacity bit，当前文本约需 $bitLen bit。请缩短文本或换更大的图片。');
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
      cw: cw,
      ch: ch,
    ));
    if (mounted) {
      setState(() {
        _resultBytes = result.$1;
        _wmBitLength = result.$2;
        _methodNote = explicit
            ? '经典文本水印（DWT，密码 + 长度可跨设备提取完整文本）'
            : '文本水印（强鲁棒不可用，已自动回退经典 DWT）';
      });
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
          Haptics.success();
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
            const PageHeader(icon: Icons.upload, title: '嵌入水印'),
            const SizedBox(height: 16),
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

            _ModeSwitcher(
              inputType: _inputType,
              textController: _textController,
              logoBytes: _logoBytes,
              logoName: _logoName,
              onPickLogo: _pickLogo,
            ),
            const SizedBox(height: 8),

            if (_inputType == _InputType.text) ...[
              SegmentedButton<_TextScheme>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: _TextScheme.wam,
                    icon: Icon(Icons.bolt),
                    label: Text('强鲁棒（WAM）'),
                  ),
                  ButtonSegment(
                    value: _TextScheme.dwt,
                    icon: Icon(Icons.water_drop_outlined),
                    label: Text('经典（DWT）'),
                  ),
                ],
                selected: {_textScheme},
                onSelectionChanged: (s) {
                  setState(() => _textScheme = s.first);
                  _clearResult();
                },
              ),
              const SizedBox(height: 6),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeIn,
                transitionBuilder: (child, animation) =>
                    FadeTransition(opacity: animation, child: child),
                child: Text(
                  _textScheme == _TextScheme.wam
                      ? '强鲁棒（默认）：任意图幅、抗裁剪/旋转/压缩；其他设备仅见 32 位标识码'
                      : '经典 DWT：密码 + 长度即可在任何设备还原完整文本；不抗旋转、分辨率无上限、容量受图片限制',
                  key: ValueKey(_textScheme),
                  style: TextStyle(
                    color: colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],

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
            if (_processing) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(minHeight: 4),
              const SizedBox(height: 8),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeIn,
                transitionBuilder: (child, animation) =>
                    FadeTransition(opacity: animation, child: child),
                child: Text(
                  _statusText ?? '正在处理…',
                  key: ValueKey(_statusText),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
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
                                            '强鲁棒 32 位码',
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
                                    if (_wamCode != null) ...[
                                      const SizedBox(height: 4),
                                      SelectableText(
                                        '标识码：$_wamCode',
                                        style: TextStyle(
                                            color:
                                                colorScheme.onSurfaceVariant,
                                            fontSize: 12,
                                            letterSpacing: 1),
                                      ),
                                      Text(
                                        '对方在其他设备提取时可见此 32 位码，可用它验证水印归属',
                                        style: TextStyle(
                                            color: colorScheme.outline,
                                            fontSize: 11),
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
            AppVersionText(
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

/// 文本输入框 ⇄ Logo 选择框切换动画（ui-animation 规范）：
/// - 内容切换**纯渐隐渐显**（与底部 tab 观感一致，无左右滑动）；
///   退场快速淡出（easeIn），入场用进入曲线（Cubic(0.22,1,0.36,1)）——不对称时序
/// - 高度用 AnimatedSize 做「受控容器缩放」过渡（card-resize 例外）：Stack 只按
///   当前子项定尺寸，切换瞬间从旧高平滑收缩/展开到新高（200ms，顶对齐），
///   下方内容随高度变化优雅移动；退场子项用 Positioned(左/右/顶) 保持自然高度
///   不被拉伸（此前 Positioned.fill 压扁内容是卡顿观感根源）
/// - 文本（56~80px 自然高度）与 Logo（64px）高度无需一致；系统减弱动画时零时长
class _ModeSwitcher extends StatelessWidget {
  const _ModeSwitcher({
    required this.inputType,
    required this.textController,
    required this.logoBytes,
    required this.logoName,
    required this.onPickLogo,
  });

  final _InputType inputType;
  final TextEditingController textController;
  final Uint8List? logoBytes;
  final String? logoName;
  final VoidCallback onPickLogo;

  static const _duration = Duration(milliseconds: 200);
  static const _enterCurve = Cubic(0.22, 1.0, 0.36, 1.0);

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final duration = reduce ? Duration.zero : _duration;
    final curve = reduce ? Curves.linear : _enterCurve;
    return AnimatedSize(
      duration: duration,
      curve: curve,
      alignment: Alignment.topCenter,
      clipBehavior: Clip.hardEdge,
      child: AnimatedSwitcher(
        duration: duration,
        switchInCurve: curve,
        switchOutCurve: reduce ? Curves.linear : Curves.easeIn,
        layoutBuilder: (currentChild, previousChildren) {
          if (currentChild == null) return const SizedBox.shrink();
          return Stack(
            fit: StackFit.loose,
            alignment: Alignment.topCenter,
            children: [
              // 退场子项：宽度对齐、高度保持自然（不参与 Stack 尺寸，不被拉伸）
              for (final c in previousChildren)
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  child: IgnorePointer(child: c),
                ),
              currentChild,
            ],
          );
        },
        transitionBuilder: (child, animation) =>
            FadeTransition(opacity: animation, child: child),
        child: SizedBox(
          key: ValueKey(inputType),
          child: inputType == _InputType.text
              ? TextField(
                  controller: textController,
                  minLines: 1,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: '水印内容',
                    hintText: '输入要隐藏的文本（如作者名、链接）',
                    border: OutlineInputBorder(),
                    alignLabelWithHint: true,
                  ),
                )
              : _LogoPicker(
                  logoBytes: logoBytes,
                  logoName: logoName,
                  onPick: onPickLogo,
                ),
        ),
      ),
    );
  }
}

/// Logo 选择区：固定 64px 高的带边框点击区（视觉重量与单行输入框相当），
/// 内容为紧凑横向单元整体居中（避免上下紧巴/左右大留白）；
/// 未选择时 图标+文案，已选择时 缩略图预览+文件名。
class _LogoPicker extends StatelessWidget {
  const _LogoPicker({
    required this.logoBytes,
    required this.logoName,
    required this.onPick,
  });

  final Uint8List? logoBytes;
  final String? logoName;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 64,
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(12),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onPick,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Center(
              child: logoBytes == null
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.add_photo_alternate_outlined,
                            size: 20, color: colorScheme.primary),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            '点击选择 Logo 图片',
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: colorScheme.onSurfaceVariant,
                                fontSize: 14),
                          ),
                        ),
                      ],
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: Image.memory(logoBytes!,
                              width: 40, height: 40, fit: BoxFit.cover),
                        ),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text(
                            logoName ?? 'Logo 已选择',
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: colorScheme.onSurfaceVariant,
                                fontSize: 14),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}





