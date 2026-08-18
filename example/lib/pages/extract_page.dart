import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blind_watermark/flutter_blind_watermark.dart';
import 'package:flutter_blind_watermark/src/blind_watermark_bindings.dart';
import 'package:gal/gal.dart';

import '../src/app_version.dart';
import '../src/haptics.dart';
import '../src/image_utils.dart';
import '../src/page_header.dart';
import '../src/pick_bridge.dart';
import '../src/wam_bridge.dart';
import '../src/wam_codec.dart';

class ExtractPage extends StatefulWidget {
  const ExtractPage({super.key});

  @override
  State<ExtractPage> createState() => _ExtractPageState();
}

/// Must match the embed-page cap: the app never produces watermarked images
/// larger than this, and DWT extraction of larger images would blow up the
/// native memory (~700MB at 12MP) and crash the app.
const int _dwtMaxLongEdge = 1536;

enum _ExtractType { auto, text, image }

class _ExtractPageState extends State<ExtractPage> {
  Uint8List? _imageBytes;
  String? _imageName;

  /// Long edge of the image as picked (before any decode-time downscale).
  /// DWT extraction must run on the exact watermarked size; oversized picks
  /// are skipped with a message instead of being processed at a wrong size.
  int _origLongEdge = 0;

  _ExtractType _extractType = _ExtractType.auto;
  final TextEditingController _passwordController =
      TextEditingController(text: '1');
  final TextEditingController _lenController = TextEditingController();
  final TextEditingController _wController = TextEditingController();
  final TextEditingController _hController = TextEditingController();

  bool _processing = false;
  String? _error;
  String? _statusText;
  String? _resultText;
  String? _resultNote;
  Uint8List? _resultImage;
  String? _wamCode;

  @override
  void dispose() {
    _passwordController.dispose();
    _lenController.dispose();
    _wController.dispose();
    _hController.dispose();
    super.dispose();
  }

  void _clearResult() {
    setState(() {
      _error = null;
      _statusText = null;
      _resultText = null;
      _resultNote = null;
      _resultImage = null;
      _wamCode = null;
    });
  }

  Future<void> _pickImage() async {
    // Android: platform picker reads the content URI directly into memory —
    // no cache copy that ROM galleries might index. Other platforms fall
    // back to file_picker (withData).
    (Uint8List, String)? picked;
    if (Platform.isAndroid) {
      picked = await PickBridge.pickImage();
    } else {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;
      final raw = file.bytes;
      if (raw == null) return;
      picked = (raw, file.name);
    }
    if (picked == null) return;
    final rawBytes = picked.$1;
    final rawName = picked.$2;
    // Engine-side scaled decode: never hold a full-resolution camera photo
    // in memory; the WAM path downsizes internally anyway and oversized DWT
    // picks are skipped via the recorded original size.
    final scaled =
        await decodeToPngScaled(rawBytes, maxDim: _dwtMaxLongEdge);
    if (scaled == null) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('无法读取该图片格式')));
      }
      return;
    }
    final origLongEdge = scaled.$2 > scaled.$3 ? scaled.$2 : scaled.$3;
    setState(() {
      _imageBytes = scaled.$1;
      _imageName = rawName;
      _origLongEdge = origLongEdge;
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

    // Manual parameters (used for images embedded on another device).
    final pw = WmSecurity.seeds(_passwordController.text).$1;
    final manualLen = int.tryParse(_lenController.text.trim());
    final manualW = int.tryParse(_wController.text.trim());
    final manualH = int.tryParse(_hController.text.trim());
    if (_extractType == _ExtractType.text &&
        (manualLen == null || manualLen <= 0)) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请输入水印长度（bit）')));
      return;
    }
    if (_extractType == _ExtractType.image &&
        (manualW == null || manualW <= 0 || manualH == null || manualH <= 0)) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请输入 Logo 宽和高')));
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
      // 图片尺寸缓存：供还原候选生成复用（避免每个记录重复解码）。
      final bytesSize = await imageSize(bytes);
      final history = await WmHistory.active();
      var found = false;
      var wamUnavailable = false;
      var dwtSkippedBig = false;
      String? wamCodeOnly;

      // DWT extraction derives its block grid from the image's own size, so
      // it must run on the exact watermarked image; and a 12MP image peaks at
      // ~700MB native memory in the double-precision pipeline — killed by the
      // OS. The app never produces watermarked images larger than 1536px, so
      // skipping oversized picks is safe.
      if (_origLongEdge > _dwtMaxLongEdge) {
        dwtSkippedBig = true;
      }
      final canDwt = !dwtSkippedBig;

      // 0) Manual DWT (explicit user intent, e.g. an image embedded on another
      // device): the user provides the exact password + length / logo size.
      if (!found && canDwt && _extractType != _ExtractType.auto) {
        if (_extractType == _ExtractType.text &&
            manualLen != null && manualLen > 0) {
          if (mounted) {
            setState(() => _statusText = '正在按手动参数提取文本水印…');
          }
          final result =
              await compute(_extractTextIsolate, (bytes, manualLen, pw));
          if (result != null && result.isNotEmpty) {
            found = true;
            if (mounted) {
              setState(() {
                _resultText = result;
                _resultNote = '文本水印 · 手动参数（长度 $manualLen）';
              });
            }
          }
        } else if (_extractType == _ExtractType.image &&
            manualW != null && manualH != null && manualW > 0 && manualH > 0) {
          if (mounted) {
            setState(() => _statusText = '正在按手动参数提取 Logo 水印…');
          }
          final result =
              await compute(_extractLogoIsolate, (bytes, manualW, manualH, pw));
          if (result != null) {
            found = true;
            if (mounted) {
              setState(() {
                _resultImage = result;
                _resultNote = 'Logo 水印 · 手动参数（${manualW}x$manualH）';
              });
            }
          }
        }
      }

      // 1) Strong-robust (WAM): no parameters needed. The models are bundled
      // in the APK and extracted by the host app on demand; getModelsDir()
      // returns null only if the models are missing (corrupted install).
      if (!found && WamBridge.isSupported) {
        final modelsDir = await WamBridge.getModelsDir();
        if (modelsDir == null) {
          // Models missing (corrupted install): skip WAM, still try DWT.
          wamUnavailable = true;
          if (mounted) {
            setState(() => _statusText = '强鲁棒模型不可用，跳过强鲁棒检测…');
          }
        } else {
          if (mounted) setState(() => _statusText = '正在识别强鲁棒水印…');
          // Multi-attempt extraction: try the original plus center-crop
          // variants (85% / 70%) and keep the result with the highest mask
          // confidence. This rescues mildly cropped / border-added images
          // that a single full-image pass would miss. Each attempt takes
          // ~0.3s; three attempts stay well under the progress feel.
          final attempts = <(Uint8List, double)>[
            for (final f in const [1.0, 0.85, 0.7])
              if (f == 1.0)
                (bytes, 0.0)
              else
                (await centerCropPng(bytes, f) ?? bytes, 0.0),
          ];
          List<int>? bestBits;
          var bestConf = -1.0;
          var attemptsOk = 0;
          for (final (cand, _) in attempts) {
            final (ok, bits, conf) =
                await compute(wamExtractIsolate, (cand, modelsDir));
            if (ok) {
              attemptsOk++;
              if (conf > bestConf) {
                bestConf = conf;
                bestBits = bits;
              }
            }
          }
          if (attemptsOk > 0 && bestBits != null) {
            final code = WamCodec.bitsToStr(bestBits);
            final match = await WmHistory.matchWam(bestBits, 4);
            if (match != null) {
              found = true;
              if (mounted) {
                setState(() {
                  _wamCode = code;
                  _resultText = match.$1.text ?? '';
                  _resultNote = '强鲁棒水印 · 匹配到本机记录（${match.$2} 位差异）';
                });
              }
            } else {
              // Code readable on any device, but text recovery needs the
              // embedder's local history — keep it to show if nothing else
              // matches.
              wamCodeOnly = code;
            }
          }
          // NOTE: 解码失败不置 wamUnavailable —— 模型存在且正常，只是图片
          // 未检测到水印（此前误标导致提示「模型不可用」，语义错误）。
        }
      }

      // 2) DWT text: try the most recent text records (skip if none).
      // 每个记录按记录中的载体尺寸生成「网格再同步」候选（原图/拉伸/填充），
      // 对齐参考库攻击演示的还原步骤——缩放/裁剪后的图可救回。
      if (!found &&
          !dwtSkippedBig &&
          history.any((e) => e.kind == 'text')) {
        if (mounted) setState(() => _statusText = '正在尝试文本水印…');
        final textRecs =
            history.where((e) => e.kind == 'text').take(10).toList();
        for (var i = 0; i < textRecs.length && !found; i++) {
          final rec = textRecs[i];
          if (mounted && textRecs.length > 1) {
            setState(() =>
                _statusText = '正在尝试文本水印（${i + 1}/${textRecs.length}）…');
          }
          final len = rec.len;
          if (len == null || len <= 0) continue;
          final candidates = await resyncCandidates(bytes, rec.cw, rec.ch,
              srcW: bytesSize?.$1, srcH: bytesSize?.$2);
          for (final cand in candidates) {
            final result = await compute(
              _extractTextIsolate,
              (cand, len, rec.pw),
            );
            if (result != null && result.isNotEmpty) {
              found = true;
              if (mounted) {
                setState(() {
                  _resultText = result;
                  _resultNote = candidates.length > 1
                      ? '文本水印 · 自动匹配长度 $len（已还原尺寸 ${rec.cw}x${rec.ch}）'
                      : '文本水印 · 自动匹配长度 $len';
                });
              }
              break;
            }
          }
          if (found) break;
        }
      }

      // 3) DWT logo: try the most recent logo records (skip if none).
      // 同样尝试还原候选，并用「raw 位值相对 0.5 的偏离度」择优：
      // 正确还原候选信号对齐、偏离大，错误候选网格错位、偏离小。
      // （绝对真假判定不可靠——错误密码/长度提取同样呈混合图案，故只做
      // 候选相对择优，最终展示由用户目视确认，与参考库演示一致。）
      if (!found &&
          !dwtSkippedBig &&
          history.any((e) => e.kind == 'logo')) {
        if (mounted) setState(() => _statusText = '正在尝试 Logo 水印…');
        final logoRecs =
            history.where((e) => e.kind == 'logo').take(5).toList();
        for (var i = 0; i < logoRecs.length && !found; i++) {
          final rec = logoRecs[i];
          if (mounted && logoRecs.length > 1) {
            setState(() =>
                _statusText = '正在尝试 Logo 水印（${i + 1}/${logoRecs.length}）…');
          }
          final w = rec.w;
          final h = rec.h;
          if (w == null || h == null || w <= 0 || h <= 0) continue;
          final candidates = await resyncCandidates(bytes, rec.cw, rec.ch,
              srcW: bytesSize?.$1, srcH: bytesSize?.$2);
          Uint8List? bestResult;
          var bestDev = 0.0;
          var restored = false;
          for (var ci = 0; ci < candidates.length; ci++) {
            final cand = candidates[ci];
            final result = await compute(
              _extractLogoIsolate,
              (cand, w, h, rec.pw),
            );
            if (result == null) continue;
            final dev = await compute(
                _dwtRawDevIsolate, (cand, w * h, rec.pw));
            if (dev > bestDev) {
              bestDev = dev;
              bestResult = result;
              restored = ci > 0;
            }
          }
          if (bestResult != null) {
            found = true;
            if (mounted) {
              setState(() {
                _resultImage = bestResult;
                _resultNote = restored
                    ? 'Logo 水印 · 自动匹配尺寸 ${w}x$h（已还原尺寸 ${rec.cw}x${rec.ch}）'
                    : 'Logo 水印 · 自动匹配尺寸 ${w}x$h';
              });
            }
            break;
          }
        }
      }

      if (found) Haptics.success();

      if (!found && mounted) {
        if (wamCodeOnly != null) {
          setState(() {
            _wamCode = wamCodeOnly;
            _resultText = '';
            _resultNote = '强鲁棒水印：仅识别出 32 位标识码，本机没有对应的文本记录。'
                '请与嵌入方核对标识码；文本/Logo 水印需嵌入方提供密码与长度（或 Logo 尺寸），'
                '在「手动提取参数」中填写。';
          });
        } else {
          setState(() {
            _resultNote = dwtSkippedBig
                ? '图片尺寸过大：文本/Logo 水印需在嵌入时的同尺寸图片上提取，且超大图在本设备上无法安全处理。请使用嵌入后保存的图片（≤1536px）；强鲁棒水印不受此限制。'
                : wamUnavailable
                    ? '强鲁棒模型不可用（安装包可能不完整），且未检测到可识别的本机文本/Logo 水印。若这是他人嵌入的图片，请向嵌入方获取密码与长度/尺寸后在「手动提取参数」中填写。'
                    : '未检测到可识别的本机水印。若这是他人嵌入的图片，请向嵌入方获取密码与长度/尺寸后在「手动提取参数」中填写；强鲁棒标识可在其他设备上识别出 32 位码';
            _resultText = '';
          });
        }
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
          Haptics.success();
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
            const PageHeader(icon: Icons.manage_search, title: '提取水印'),
            const SizedBox(height: 16),
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
              '默认全自动识别本机水印；如需提取他人图片，请在下方按嵌入方提供的参数手动填写',
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 8),

            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('手动提取参数（可选）'),
              subtitle: const Text('密码与长度/尺寸需与嵌入时一致'),
              childrenPadding: const EdgeInsets.only(top: 8, bottom: 8),
              children: [
                SegmentedButton<_ExtractType>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: _ExtractType.auto,
                      icon: Icon(Icons.auto_awesome),
                      label: Text('自动'),
                    ),
                    ButtonSegment(
                      value: _ExtractType.text,
                      icon: Icon(Icons.text_fields),
                      label: Text('文本'),
                    ),
                    ButtonSegment(
                      value: _ExtractType.image,
                      icon: Icon(Icons.image_outlined),
                      label: Text('Logo'),
                    ),
                  ],
                  selected: {_extractType},
                  onSelectionChanged: (s) {
                    setState(() => _extractType = s.first);
                    _clearResult();
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _passwordController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '水印密码',
                    hintText: '与嵌入时一致，默认 1',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                // 与嵌入页同款动画：AnimatedSize 单阶段高度变形（自动→文本/Logo
                // 平滑展开，顶对齐）+ 纯渐隐渐显（无左右滑动）；退场子项保持自然高度
                AnimatedSize(
                  duration: const Duration(milliseconds: 200),
                  curve: Cubic(0.22, 1.0, 0.36, 1.0),
                  alignment: Alignment.topCenter,
                  clipBehavior: Clip.hardEdge,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    switchInCurve: Cubic(0.22, 1.0, 0.36, 1.0),
                    switchOutCurve: Curves.easeIn,
                    layoutBuilder: (currentChild, previousChildren) {
                      if (currentChild == null) {
                        return const SizedBox.shrink();
                      }
                      return Stack(
                        fit: StackFit.loose,
                        alignment: Alignment.topCenter,
                        children: [
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
                      key: ValueKey(_extractType),
                      child: _extractType == _ExtractType.auto
                          ? const SizedBox.shrink()
                          : _extractType == _ExtractType.text
                              ? TextField(
                                  controller: _lenController,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(
                                    labelText: '水印长度（bit）',
                                    hintText: '嵌入结果会显示长度，如 119',
                                    border: OutlineInputBorder(),
                                  ),
                                )
                              : Row(
                                  children: [
                                    Expanded(
                                      child: TextField(
                                        controller: _wController,
                                        keyboardType: TextInputType.number,
                                        decoration: const InputDecoration(
                                          labelText: 'Logo 宽',
                                          hintText: '嵌入时 Logo 尺寸',
                                          border: OutlineInputBorder(),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: TextField(
                                        controller: _hController,
                                        keyboardType: TextInputType.number,
                                        decoration: const InputDecoration(
                                          labelText: 'Logo 高',
                                          hintText: '嵌入时 Logo 尺寸',
                                          border: OutlineInputBorder(),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                    ),
                  ),
                ),
              ],
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
              // 分步状态提示：文字切换淡入淡出（不跳动）
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeIn,
                transitionBuilder: (child, animation) =>
                    FadeTransition(opacity: animation, child: child),
                child: Text(
                  _statusText!,
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

/// DWT 原始位值（二值化前）相对 0.5 的平均偏离度 mean|avg-0.5|。
/// 用于 Logo「网格再同步」候选的择优：正确还原候选信号对齐、偏离大，
/// 错误候选网格错位、偏离小（实测 0.31 vs 0.24）。
double _dwtRawDevIsolate((Uint8List, int, int) args) {
  final (bytes, wmLength, pw) = args;
  final b = BlindWatermarkBindings.instance;
  final handle = b.bwm_create(pw, pw);
  if (handle.address == 0) return 0;
  try {
    final pngPtr = malloc<Uint8>(bytes.length);
    final dev = malloc<Float>();
    try {
      pngPtr.asTypedList(bytes.length).setAll(0, bytes);
      final rc = b.bwm_extract_raw_deviation(
          handle, pngPtr, bytes.length, wmLength, dev);
      if (rc != 0) return 0;
      return dev.value.toDouble();
    } finally {
      malloc.free(pngPtr);
      malloc.free(dev);
    }
  } finally {
    b.bwm_destroy(handle);
  }
}



