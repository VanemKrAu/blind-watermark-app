import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../src/app_version.dart';

/// 关于页：应用概览 / 功能说明 / 隐私与安全 / 鲁棒性边界 / 技术栈与致谢 / 开源与许可。
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  Future<void> _open(BuildContext context, String url) async {
    final uri = Uri.parse(url);
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('无法打开链接')));
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('无法打开链接')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 应用概览
          _Header(cs: cs),
          const SizedBox(height: 16),

          // 功能说明
          _Section(
            icon: Icons.auto_awesome,
            title: '功能与用法',
            children: [
              _Bullet(
                '文本水印',
                '默认强鲁棒（WAM）：32 位标识码，抗裁剪 / 旋转 / 压缩，完整文字仅本机还原；可切换经典 DWT：密码 + 长度即可在任意设备还原完整文本。',
              ),
              _Bullet(
                'Logo 水印',
                '使用 DWT 方案，可完整还原 Logo 图片。',
              ),
              _Bullet(
                '提取',
                '本机自动识别；他人图片可在「手动提取参数」输入密码 + 长度 / Logo 尺寸后提取。',
              ),
            ],
          ),
          const SizedBox(height: 12),

          // 隐私与安全
          _Section(
            icon: Icons.security,
            title: '隐私与安全',
            children: [
              const _Bullet(
                '本地离线',
                '所有处理均在设备本地完成，图片不会上传到任何服务器。',
                leading: Icons.check,
              ),
              _Bullet(
                '密码保护',
                '水印密码参与水印随机打乱，他人需同时知道密码与长度 / 尺寸才能还原。',
              ),
              _Bullet(
                '局限',
                '本机记录为明文存储（root 设备可读）；整数密码可被暴力枚举；WAM 文本跨设备仅可见 32 位标识码（完整文字需本机记录，跨设备请改用 DWT 方案）。',
                leading: Icons.info_outline,
              ),
            ],
          ),
          const SizedBox(height: 12),

          // 鲁棒性边界
          _Section(
            icon: Icons.storm,
            title: '鲁棒性边界（实测）',
            children: [
              const Text(
                'WAM 强鲁棒（文本默认方案）可抵抗：',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              const Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  Chip(label: Text('JPEG q50~95')),
                  Chip(label: Text('高斯模糊 3/5/7')),
                  Chip(label: Text('局部涂黑 10%~50%')),
                  Chip(label: Text('亮度 -20%')),
                  Chip(label: Text('缩放 50%')),
                  Chip(label: Text('旋转 5°')),
                  Chip(label: Text('裁剪 75%')),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'DWT（Logo / 经典文本）可抵抗：',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              const Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  Chip(label: Text('JPEG q50~95')),
                  Chip(label: Text('高斯模糊 3')),
                  Chip(label: Text('局部涂黑 10%~50%')),
                  Chip(label: Text('亮度 -20%')),
                  Chip(label: Text('缩放 50%（自动还原）')),
                  Chip(label: Text('裁剪 75%（自动还原）')),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                '以下为技术边界（业界普遍）：',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              const Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  Chip(label: Text('>10° 旋转（DWT）')),
                  Chip(label: Text('裁剪 <50%')),
                  Chip(label: Text('强噪声')),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '注：本表为 1024×768 测试图的实测结果，实际效果随图片内容与攻击强度略有差异。'
                'DWT 高斯模糊 5/7 仅 Logo 可提取（文本位错 23+，信息物理损坏，业界边界）。',
                style: TextStyle(color: cs.outline, fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // 技术栈与致谢
          _Section(
            icon: Icons.code,
            title: '技术栈与致谢',
            children: [
              const _Bullet(
                '技术栈',
                'Flutter UI · C++ FFI 核心算法 · ONNX Runtime 推理（全本地）',
              ),
              const Divider(height: 16),
              const Text('本项目站在以下开源项目之上，特此致谢：',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              _LinkTile(
                'guofei9987/blind_watermark',
                '核心 DWT-DCT-SVD 盲水印算法（MIT）',
                onTap: () =>
                    _open(context, 'https://github.com/guofei9987/blind_watermark'),
              ),
              _LinkTile(
                'facebookresearch/watermark-anything',
                'WAM 强鲁棒水印模型，Meta ICLR 2025（MIT）',
                onTap: () => _open(
                    context,
                    'https://github.com/facebookresearch/watermark-anything'),
              ),
              _LinkTile(
                'JackCaow/flutter_blind_watermark',
                'Flutter FFI 插件工程脚手架（MIT）',
                onTap: () => _open(
                    context,
                    'https://github.com/JackCaow/flutter_blind_watermark'),
              ),
              _LinkTile(
                'Eigen',
                '线性代数库（SVD/DCT），MPL2',
                onTap: () => _open(context, 'https://eigen.tuxfamily.org/'),
              ),
              _LinkTile(
                'stb',
                '图像编解码（PNG/JPEG/BMP/WebP）',
                onTap: () => _open(context, 'https://github.com/nothings/stb'),
              ),
              _LinkTile(
                'ONNX Runtime',
                'WAM 推理引擎（MIT）',
                onTap: () =>
                    _open(context, 'https://github.com/microsoft/onnxruntime'),
              ),
              const SizedBox(height: 8),
              Text(
                '内置模型：WAM embedder（自包含，约 5.2MB）+ extractor int8（约 95MB），'
                '均来自 Meta 官方权重导出，MIT 协议。',
                style: TextStyle(color: cs.outline, fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // 开源与许可
          _Section(
            icon: Icons.description,
            title: '开源与许可',
            children: [
              const Text('本项目以 MIT License 开源：'),
              const SizedBox(height: 4),
              _LinkTile(
                'GitHub 仓库',
                'VanemKrAu/blind-watermark-app',
                onTap: () => _open(
                    context, 'https://github.com/VanemKrAu/blind-watermark-app'),
              ),
              const SizedBox(height: 4),
              Text(
                'THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, '
                'EXPRESS OR IMPLIED.',
                style: TextStyle(color: cs.outline, fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 24),
          AppVersionText(
            style: TextStyle(color: cs.outline, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.cs});

  final ColorScheme cs;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        CircleAvatar(
          radius: 36,
          backgroundColor: cs.primaryContainer,
          child: Icon(Icons.water_drop, size: 40, color: cs.primary),
        ),
        const SizedBox(height: 12),
        Text('BlindWatermark', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 4),
        // 第二行只显示版本号，不重复项目名（prefix 用 'v'）。
        AppVersionText(
          prefix: 'v',
          style: TextStyle(color: cs.outline, fontSize: 12),
        ),
        const SizedBox(height: 12),
        Text(
          '本地离线图片盲水印工具 —— 嵌入不可见水印，无需原图即可提取',
          textAlign: TextAlign.center,
          style: TextStyle(color: cs.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.icon, required this.title, required this.children});

  final IconData icon;
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: cs.primary),
                const SizedBox(width: 8),
                Text(title,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet(this.title, this.body, {this.leading = Icons.chevron_right});

  final String title;
  final String body;
  final IconData leading;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(leading, size: 18, color: cs.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '$title：',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  TextSpan(text: body),
                ],
              ),
              style: TextStyle(color: cs.onSurfaceVariant, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

class _LinkTile extends StatelessWidget {
  const _LinkTile(this.title, this.subtitle, {required this.onTap});

  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(title,
          style: TextStyle(color: cs.primary, fontWeight: FontWeight.w500)),
      subtitle: Text(subtitle, style: TextStyle(fontSize: 12)),
      trailing: Icon(Icons.open_in_new, size: 16, color: cs.outline),
      onTap: onTap,
    );
  }
}