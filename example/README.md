# 盲水印 App（example）

本目录为盲水印安卓 App 的完整应用工程（Flutter + FFI 插件）。

## 功能

- **嵌入**：选图 → 输入文本 / Logo →（可选密码）→ 输出打水印的图片
  - 文本水印一律走 **WAM 强鲁棒**（抗裁剪/旋转/压缩，任意图幅，输出保持原分辨率锐利）
  - Logo 水印走 **DWT**（完整还原）
- **提取**：选图 → 全自动识别（本机历史匹配）；他人图片可在「手动提取参数」输入密码 + 长度 / Logo 尺寸
- **关于**：应用概览、隐私与安全、鲁棒性边界、技术栈致谢与开源许可
- 全部本地离线，图片不上传；模型已内置

## 构建

```bash
flutter pub get
flutter build apk --release
# 输出: build/app/outputs/flutter-apk/app-release.apk（约 161MB）
```

模型文件位于 `assets/onnx/`（wam_embedder.onnx 自包含 + wam_extractor_int8.onnx），已在 pubspec 显式声明。

## 页面结构

```
lib/
├─ main.dart            # 入口：崩溃报告弹窗 + 3 tab（嵌入/提取/关于）
├─ pages/
│  ├─ embed_page.dart   # 嵌入页
│  ├─ extract_page.dart # 提取页（含手动提取参数）
│  └─ about_page.dart   # 关于页
└─ src/
   ├─ app_version.dart  # 动态版本号（package_info_plus）
   ├─ image_utils.dart  # 引擎侧缩码解码 / 降采样
   ├─ pick_bridge.dart  # Android 零磁盘选图
   ├─ wam_bridge.dart   # WAM FFI 绑定（isolate 直调）
   └─ wam_codec.dart    # CRC32 / 历史记录 / 密码种子
```
