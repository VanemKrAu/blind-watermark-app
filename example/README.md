# BlindWatermark App（example）

本目录为 BlindWatermark 安卓 App 的完整应用工程（Flutter + FFI 插件）。

## 功能

- **嵌入**：选图 → 输入文本 / Logo →（可选密码）→ 输出打水印的图片
  - 文本水印默认走 **WAM 强鲁棒**（抗裁剪/旋转/压缩，任意图幅可嵌入、输出保持原分辨率锐利；可靠提取限长边 ≤2048），**可切换经典 DWT**（密码 + 长度即可跨设备还原完整文本，但容量有限、不抗旋转）
  - Logo 水印走 **DWT**（完整还原）
- **提取**：选图 → 全自动识别（本机历史匹配，多尝试提取）；他人图片可在「手动提取参数」输入密码 + 长度 / Logo 尺寸
- **嵌入记录**：本机全部记录（左滑删除/归档/置顶、长按多选、归档二级页、时间戳）
- **关于**：应用概览、隐私与安全、鲁棒性边界、技术栈致谢与开源许可
- 全部本地离线，图片不上传；模型已内置；支持触觉反馈

## 构建

```bash
flutter pub get
flutter build apk --release
# 输出: build/app/outputs/flutter-apk/app-release.apk（约 125MB，模型内置；仅 arm64-v8a）
```

模型文件位于 `assets/onnx/`（wam_embedder.onnx 自包含 + wam_extractor_int8.onnx），已在 pubspec 显式声明。

## 页面结构

```
lib/
├─ main.dart            # 入口：崩溃报告弹窗 + 4 tab（嵌入/提取/嵌入记录/关于）
├─ pages/
│  ├─ embed_page.dart   # 嵌入页
│  ├─ extract_page.dart # 提取页（手动提取参数 + 多尝试提取）
│  ├─ history_page.dart # 嵌入记录页（左滑操作/多选/归档二级页）
│  └─ about_page.dart   # 关于页
└─ src/
   ├─ app_version.dart  # 动态版本号（package_info_plus）
   ├─ page_header.dart  # 统一页头（logo 图标块 + 大标题）
   ├─ haptics.dart      # 触觉反馈（HapticFeedbackConstants 语义映射）
   ├─ image_utils.dart  # 引擎侧缩码解码 / 降采样 / 居中裁剪
   ├─ pick_bridge.dart  # Android 零磁盘选图
   ├─ wam_bridge.dart   # WAM FFI 绑定（isolate 直调 + 置信度）
   └─ wam_codec.dart    # CRC32 / 记录管理（ts/pinned/archived/seq）/ 密码种子
```
