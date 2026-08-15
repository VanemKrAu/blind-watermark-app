import 'package:flutter/material.dart';

import 'wam_bridge.dart';
import 'wam_config.dart';

/// Shows a dialog prompting the user to download the WAM models (release
/// builds do not bundle them). Returns true when the models are ready.
Future<bool> ensureWamModels(BuildContext context) async {
  if (await WamBridge.modelReady()) return true;

  if (!context.mounted) return false;
  final download = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: const Text('需要下载水印模型'),
      content: Text(
        '强鲁棒水印需要下载模型（共约 ${WamConfig.embedderSizeMb + WamConfig.extractorSizeMb} MB，'
        '来源：Meta Watermark Anything，MIT 协议，一次下载永久可用）。是否现在下载？',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('下载'),
        ),
      ],
    ),
  );
  if (download != true) return false;

  // Download with progress.
  if (!context.mounted) return false;
  var progress = 0.0;
  final done = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('正在下载模型…'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(value: progress == 0 ? null : progress),
            const SizedBox(height: 12),
            Text('${(progress * 100).toStringAsFixed(0)}%'),
            const SizedBox(height: 4),
            const Text(
              '下载完成后自动就绪，无需重启',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    ),
  );

  try {
    await WamBridge.downloadModels((done, total) {
      if (total > 0) {
        progress = done / total;
      }
    });
  } catch (e) {
    if (context.mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('模型下载失败：$e')));
    }
    return false;
  }
  if (context.mounted) {
    Navigator.pop(context);
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('模型已就绪')));
  }
  return true;
}
