import 'dart:convert';
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

/// DWT 提取分辨率限制（用户决策 2026-08-18）：彻底取消——任意尺寸直接提取
/// （13MP 真机实测嵌入/提取无闪退）。代价：超大图提取耗时长，进度条明示。
const int _dwtMaxLongEdge = 100000;

enum _ExtractType { auto, text, image }

/// 容量硬预筛（零误伤）：文本 bit 数 / Logo 像素数超过载体容量
/// （(cw/8)×(h/8)）的记录在数学上不可能嵌在这张图上 → 跳过。
/// cw/ch 未知（旧记录）或非法时不预筛（放行）；参数无效的记录直接排除。
bool capacityOk(WmRecord rec) {
  if (rec.kind == 'text') {
    final len = rec.len;
    if (len == null || len <= 0) return false; // 无长度无法尝试
    final cw = rec.cw;
    final ch = rec.ch;
    if (cw <= 0 || ch <= 0 || cw > 8192 || ch > 8192) return true;
    return len <= (cw ~/ 8) * (ch ~/ 8);
  }
  if (rec.kind == 'logo') {
    final w = rec.w;
    final h = rec.h;
    if (w == null || h == null || w <= 0 || h <= 0) return false;
    final cw = rec.cw;
    final ch = rec.ch;
    if (cw <= 0 || ch <= 0 || cw > 8192 || ch > 8192) return true;
    return w * h <= (cw ~/ 8) * (ch ~/ 8);
  }
  return true;
}

/// 尺寸匹配排序（零误伤，只调顺序不跳过）：载体尺寸与当前图相同的记录
/// 排最前（最可能命中且仅需原图候选）；组内按时间倒序。
List<WmRecord> rankedBySize(List<WmRecord> recs, (int, int) srcSize) {
  int same(WmRecord r) {
    final cw = r.cw;
    final ch = r.ch;
    if (cw <= 0 || ch <= 0) return 1;
    if (cw == srcSize.$1 && ch == srcSize.$2) return 0;
    return 1;
  }

  final out = List<WmRecord>.from(recs);
  out.sort((a, b) {
    final s = same(a).compareTo(same(b));
    if (s != 0) return s;
    return b.ts.compareTo(a.ts);
  });
  return out;
}

/// DWT Logo 提取的「无信号」判定阈值：raw 位值相对 0.5 的平均偏离度
/// mean|avg-0.5|。实测（1024×768 真实风格图，wmLength 3969）：
///   真 Logo 水印图 ≈ 0.50；无水印图 ≈ 0.11；WAM 水印图 ≈ 0.10。
/// dev < 0.25 视为图上没有该 Logo 水印——防止任意图（WAM 文本水印图/
/// 无水印图）被提取成噪点 Logo 而误判成功（截胡 WAM 结果）。
const double _logoMinDev = 0.25;

/// 记录 [rec] 在 [srcSize] 图片上的「网格再同步」候选数（与 resyncCandidates
/// 的生成逻辑一致：尺寸相同/记录尺寸未知 → 1；否则拉伸+等比填充+原大小
/// 放置 → 4）。用于提取进度条的原子步骤预算。
int candidateCount(WmRecord rec, (int, int) srcSize) {
  final cw = rec.cw;
  final ch = rec.ch;
  if (cw <= 0 || ch <= 0 || cw > 8192 || ch > 8192) return 1;
  if (cw == srcSize.$1 && ch == srcSize.$2) return 1;
  return 4;
}

class _ExtractPageState extends State<ExtractPage> {
  /// 原始选图字节（提取时按需全尺寸解码）。
  Uint8List? _imageRaw;
  /// 预览小图（长边 ≤1024，选图秒开）。
  Uint8List? _imageBytes;
  String? _imageName;

  _ExtractType _extractType = _ExtractType.auto;
  final TextEditingController _passwordController =
      TextEditingController(text: '1');
  final TextEditingController _lenController = TextEditingController();
  final TextEditingController _wController = TextEditingController();
  final TextEditingController _hController = TextEditingController();

  bool _processing = false;
  String? _error;
  String? _statusText;
  /// 提取进度 0~1（null = 不确定阶段，如解码/单次手动提取）。
  double? _progress;
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
    // 预览只解码小图（长边 ≤1024，秒开）；原始字节保留，提取时按需解码
    // 全尺寸工作图（WAM 内部缩 256，DWT 需嵌入时的同尺寸）。
    final scaled = await decodeToPngScaled(rawBytes, maxDim: 1024);
    if (scaled == null) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('无法读取该图片格式')));
      }
      return;
    }
    setState(() {
      _imageRaw = rawBytes;
      _imageBytes = scaled.$1;
      _imageName = rawName;
      _error = null;
      _statusText = null;
      _progress = null;
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
      final history = await WmHistory.active();
      // 提取工作图：按需全尺寸解码（限制已取消，DWT 需嵌入时的同尺寸）。
      final raw = _imageRaw ?? _imageBytes!;
      final decoded = await decodeToPngScaled(raw, maxDim: _dwtMaxLongEdge);
      if (decoded == null) {
        if (mounted) {
          setState(() {
            _processing = false;
            _error = '图片解码失败';
          });
        }
        return;
      }
      final bytes = decoded.$1;
      // 图片尺寸缓存：供还原候选生成复用（避免每个记录重复解码）。
      final bytesSize = (decoded.$2, decoded.$3);
      var found = false;
      var wamUnavailable = false;
      String? wamCodeOnly;
      // 手动模式单次提取：不确定进度；auto 模式按「原子步骤」显示确定进度。
      // 原子步骤 = 解码 1 + WAM 每次尝试 + 每个 DWT 还原候选（text/logo）。
      // 候选数按记录载体尺寸与图片尺寸的关系预算（与 resyncCandidates 一致），
      // 使进度条在每次 compute 后平滑推进，不在阶段末尾跳变。
      final useSteps = _extractType == _ExtractType.auto;
      var done = 0;
      var total = 1; // 解码
      if (useSteps) {
        if (WamBridge.isSupported) total += 3; // WAM 三次尝试
        for (final e in history
            .where((e) => e.kind == 'text' && capacityOk(e))
            .take(10)) {
          total += candidateCount(e, bytesSize);
        }
        for (final e in history
            .where((e) => e.kind == 'logo' && capacityOk(e))
            .take(5)) {
          total += candidateCount(e, bytesSize);
        }
      }
      void bump() {
        if (!useSteps || !mounted) return;
        setState(() => _progress = done / total);
      }

      done = 1; // 解码完成
      bump();

      // 0) Manual DWT (explicit user intent, e.g. an image embedded on another
      // device): the user provides the exact password + length / logo size.
      if (!found && _extractType != _ExtractType.auto) {
        if (_extractType == _ExtractType.text &&
            manualLen != null && manualLen > 0) {
          if (mounted) {
            setState(() => _statusText = '正在按手动参数提取文本水印…');
          }
          // 手动提取：用户主动提供参数，直接展示提取结果（仅过滤空/\uFFFD）。
          final (text, _) =
              await compute(_extractTextIsolate, (bytes, manualLen, pw));
          if (text != null) {
            found = true;
            if (mounted) {
              setState(() {
                _resultText = text;
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
          if (useSteps) {
            done += 3; // WAM 步骤视为已消耗（跳过）
            bump();
          }
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
            if (useSteps) {
              done++;
              bump();
            }
          }
          if (attemptsOk > 0 && bestBits != null) {
            if (bestConf < 2.0) {
              // 置信度过低 = 图上没有 WAM 水印（实测：水印图 ~8.0 vs
              // 无水印 ~0.0）。不产出 32 位码，避免 DWT 水印图被误判为
              // 「仅识别出标识码」而掩盖后续 DWT 提取结果。
            } else {
              final code = WamCodec.bitsToStr(bestBits);
              final match = await WmHistory.matchWam(bestBits, 4);
              if (match != null) {
                // WAM 命中（conf ≥ 2 且记录 ≤4 位错）是强信号，直接展示——
                // 不再暂存等 DWT 兜底：否则 DWT Logo 阶段会用图上的真 Logo
                // 信号（dev ~0.5）截胡 WAM 文本，出现「WAM 文本识别不出来、
                // 反而识别成 Logo」的假象。安全性：DWT 图/无痕图 conf 实测
                // < 1（阈值 2.0），不会误命中；WAM 匹配需 32 位码 ≤4 位错。
                final rec = match.$1;
                final hitText = rec.text;
                found = true;
                if (mounted) {
                  setState(() {
                    _wamCode = code;
                    if (hitText != null && hitText.isNotEmpty) {
                      _resultText = hitText;
                      _resultNote = '强鲁棒文本水印 · 自动识别';
                    } else {
                      _resultText = null;
                      _resultNote = '强鲁棒水印 · 已识别 32 位标识码';
                    }
                  });
                }
              } else {
                // Code readable on any device, but text recovery needs the
                // embedder's local history — keep it to show if nothing else
                // matches.
                wamCodeOnly = code;
              }
            }
          }
          // NOTE: 解码失败不置 wamUnavailable —— 模型存在且正常，只是图片
          // 未检测到水印（此前误标导致提示「模型不可用」，语义错误）。
        }
      }

      // 2) DWT text: try the most recent text records (skip if none).
      // 每个记录按记录中的载体尺寸生成「网格再同步」候选（原图/拉伸/填充），
      // 对齐参考库攻击演示的还原步骤——缩放/裁剪后的图可救回。
      if (!found && history.any((e) => e.kind == 'text')) {
        if (mounted) setState(() => _statusText = '正在尝试文本水印…');
        // 先容量预筛再截断（避免无效记录挤掉有效记录），尺寸匹配的排最前。
        final textRecs = rankedBySize(
            history
                .where((e) => e.kind == 'text' && capacityOk(e))
                .take(10)
                .toList(),
            bytesSize);
        if (textRecs.isEmpty) {
          if (mounted) {
            setState(() => _statusText = '本机文本记录均不匹配该图片尺寸/容量…');
          }
        }
        for (var i = 0; i < textRecs.length && !found; i++) {
          final rec = textRecs[i];
          if (mounted && textRecs.length > 1) {
            setState(() =>
                _statusText = '正在尝试文本水印（${i + 1}/${textRecs.length}）…');
          }
          final len = rec.len;
          if (len == null || len <= 0) continue;
          final candidates = await resyncCandidates(bytes, rec.cw, rec.ch,
              srcW: bytesSize.$1, srcH: bytesSize.$2);
          for (final cand in candidates) {
            final (text, bits) = await compute(
              _extractTextIsolate,
              (cand, len, rec.pw),
            );
            if (useSteps) {
              done++;
              bump();
            }
            // 以记录原文为基准校验（容错 2 位）：随机位流与固定文本编码
            // 差异必远大于 2 —— 假文本无法通过；轻损（JPEG q70 1 bit 错）
            // 真文本可通过。无原文的旧记录跳过（无法验证）。
            final recText = rec.text;
            if (bits != null &&
                recText != null &&
                recText.isNotEmpty &&
                recBitsMatch(recText, bits)) {
              found = true;
              if (mounted) {
                setState(() {
                  _resultText = text ?? recText;
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
      if (!found && history.any((e) => e.kind == 'logo')) {
        if (mounted) setState(() => _statusText = '正在尝试 Logo 水印…');
        // 同文本：先容量预筛再截断，尺寸匹配的排最前。
        final logoRecs = rankedBySize(
            history
                .where((e) => e.kind == 'logo' && capacityOk(e))
                .take(5)
                .toList(),
            bytesSize);
        if (logoRecs.isEmpty) {
          if (mounted) {
            setState(() => _statusText = '本机 Logo 记录均不匹配该图片尺寸/容量…');
          }
        }
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
              srcW: bytesSize.$1, srcH: bytesSize.$2);
          Uint8List? bestResult;
          var bestDev = 0.0;
          var restored = false;
          for (var ci = 0; ci < candidates.length; ci++) {
            final cand = candidates[ci];
            final result = await compute(
              _extractLogoIsolate,
              (cand, w, h, rec.pw),
            );
            if (result != null) {
              final dev = await compute(
                  _dwtRawDevIsolate, (cand, w * h, rec.pw));
              // 无信号判定：dev 低于阈值视为图上没有该 Logo 水印
              // （实测真水印 ~0.50 vs 无水印/WAM 图 ~0.10-0.12）。
              if (dev >= _logoMinDev && dev > bestDev) {
                bestDev = dev;
                bestResult = result;
                restored = ci > 0;
              }
            }
            if (useSteps) {
              done++;
              bump();
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
            _resultNote = wamUnavailable
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
          _progress = null;
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
              const SizedBox(height: 12),
              // 提取进度：auto 模式按步骤确定进度，但用 TweenAnimationBuilder
              // 插值动画把「跳到下一格」平滑为「连续过渡」，观感如下载进度条；
              // 解码/手动模式为不确定进度（连续流动）。
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: _progress ?? 0),
                duration: const Duration(milliseconds: 350),
                curve: Curves.easeOutCubic,
                builder: (context, value, _) => LinearProgressIndicator(
                  value: _progress == null ? null : value,
                  minHeight: 4,
                ),
              ),
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
/// Returns (text, rawBits) or (null, null) when nothing readable was
/// recovered; [rawBits] 供循环一致性校验（拒绝假文本/乱码）。
(String?, List<int>?) _extractTextIsolate((Uint8List, int, int) args) {
  final (bytes, len, pw) = args;
  final bwm =
      BlindWatermark(passwordWm: pw, passwordImg: pw, d1: 36.0, d2: 20.0);
  try {
    final text = bwm.extractStringFromBytes(bytes, len);
    if (text.trim().isEmpty || text.contains('\uFFFD')) return (null, null);
    final bits =
        bwm.extractBitsFromBytes(bytes, len).map((b) => b ? 1 : 0).toList();
    return (text, bits);
  } catch (_) {
    return (null, null);
  } finally {
    bwm.dispose();
  }
}

/// 记录原文重编码校验（数学严格）：提取的原始 bit 流与「记录原文按嵌入
/// 编码（utf8 → hex → bin 去前导零，与 C++ setWatermarkString 一致）生成
/// 的 bit 流」汉明距离 ≤ [tolerance] 才判为该记录的水印。
///
/// 容错 2 位：JPEG 压缩等轻损下真文本实测最多 1 bit 错（q70 中文）；随机
/// 位流（假文本/他人图）与固定文本编码的差异远大于 2（概率 ~2^-n，数学
/// 上不可混）。以记录原文为基准而非「提取出的文本」——提取文本重编码对
/// 随机位流有 15/16 的假一致反例（首 4 bit 非全 0 时 bitsToText 可逆）。
bool recBitsMatch(String recText, List<int> rawBits, {int tolerance = 2}) {
  final hex = utf8
      .encode(recText)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  final recBits = BigInt.parse(hex, radix: 16)
      .toRadixString(2)
      .split('')
      .map((c) => c == '1' ? 1 : 0)
      .toList();
  if (recBits.length != rawBits.length) return false;
  var d = 0;
  for (var i = 0; i < recBits.length; i++) {
    if (recBits[i] != rawBits[i]) d++;
  }
  return d <= tolerance;
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



