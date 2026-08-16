# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.16] - 2026-08-16

### Added
- 新增「关于」页（底部导航第 3 个 tab）：应用概览、功能与用法、隐私与安全、鲁棒性边界、技术栈与致谢（可点击开源链接）、MIT 许可与 GitHub 仓库
- 页面底部版本号改为动态读取（package_info_plus），不再硬编码

## [1.1.15] - 2026-08-16

### Changed
- **文本水印一律走 WAM 强鲁棒方案**（任意图幅，抗裁剪/旋转/压缩；其他设备仅可见 32 位标识码，完整文字仅本机还原）
- WAM 嵌入输出改为**载体原分辨率锐利图**（256px 嵌入 → 残差 delta 放大与锐利原图混合 + JND 衰减），大图不再模糊
- 提取页新增「手动提取参数」：密码 + 类型（自动/文本/Logo）+ 长度或 Logo 尺寸，用于提取他人图片；WAM 提取到码但无本机记录时也展示 32 位码

### Added
- 嵌入结果展示 Logo 尺寸与完整 32 位标识码（可复制，供跨设备核验）

## [1.1.14] - 2026-08-16

### Fixed
- 修复 WAM 嵌入输出噪点图：ONNX 只导出 embedder 残差 delta，现补 blend（scaling 1.0/2.0）+ JND 感知衰减，输出为正常水印图

## [1.1.13] - 2026-08-16

### Changed
- ONNX 推理迁移为 FFI 直调 ORT C API（wam_ort.cpp），移除 Java/JNI 桥接层，根治 Android 16 上 sess.run SIGABRT 崩溃
- 选图改 ACTION_GET_CONTENT 流式读内存，根治相册污染；DWT 载体上限收紧至 1536px

## [1.1.4] - 2026-08-16

### Changed
- 移除 NDK 激进编译参数（-ffast-math/-flto，ARM 静默崩溃风险源）；DWT 嵌入改 in-place 省内存

### Added
- 原生信号（SIGSEGV/SIGABRT/SIGBUS/SIGFPE）+ Java 异常崩溃捕获，下次启动弹窗展示可复制报告

## [1.1.2] - 2026-08-16

### Changed
- 选图即引擎侧缩码解码（decodeToPngScaled），内存全程有界，大图不再被杀进程

## [1.1.1] - 2026-08-16

### Changed
- DWT 载体降采样至 2048px 内（防大图内存爆炸）；补 armeabi-v7a ABI；WAM 模型缺失自动回退 DWT

## [1.1.0] - 2026-08-16

### Added
- 单入口重构：自动选方案（小图 WAM / 大图与 Logo DWT）、全自动提取（历史记录匹配）
- 集成 WAM 强鲁棒水印（Meta ICLR 2025，ONNX int8 95MB）
- 密码机制（默认 1，参与 DWT 随机打乱）与安全模型文档
- 发布体系：模型内置单版 APK，源码开源（GitHub: VanemKrAu/blind-watermark-app）

## [1.0.1] - 2026-08-16

### Fixed
- 修复 Isolate 闭包捕获导致嵌入失败（改用 compute 顶层函数）

## [0.0.2] - 2024-12-23

### Changed
- Added pub.dev topics for better discoverability (watermark, image-processing, steganography, ffi, security)

## [0.0.1] - 2024-12-23

### Added
- Initial release of Flutter Blind Watermark plugin
- DWT-DCT-SVD based invisible watermarking algorithm
- Support for text, binary, and image watermarks
- Synchronous API for simple use cases
- Asynchronous API with Dart isolates for non-blocking UI
- Support for PNG, JPEG, WebP, BMP, and GIF input formats
- Output support for PNG, JPEG, and WebP formats
- Android platform support via FFI
- iOS platform support via FFI
- Configurable embedding strength parameters (d1, d2)
- Password-based watermark encryption
- Comprehensive example application
