# Blind Watermark App（盲水印）

基于 DWT-DCT-SVD 算法的图片盲水印工具：**嵌入水印无需原图即可提取**（盲水印）。
安卓 App（Flutter + C++ FFI），核心算法与 Python 库 [guofei9987/blind_watermark](https://github.com/guofei9987/blind_watermark) **bit 级互通**——两边打的水印互相可提取。

## 目录结构

```
blind-watermark-app/
├─ src/            C++ 核心（算法 + 随机数 + 图像 I/O）
│  ├─ numpy_rng.*        # MT19937 精确复刻 numpy RandomState（互通关键）
│  ├─ watermark_core.*   # DWT-DCT-SVD 嵌入/提取（与 Python 版逐 bit 对齐）
│  ├─ dct.* / dwt.*      # 正交 DCT-II / Haar 小波
│  ├─ color_convert.*    # YUV 转换（复刻 cv2 浮点路径，含 +0.5 偏置）
│  ├─ image_io.*         # PNG/JPEG/BMP/WebP 编解码（stb_image）
│  └─ blind_watermark_ffi.*  # C ABI 接口（Dart FFI 调用）
├─ lib/            Dart 层（FFI 绑定 + 嵌入/提取 API）
├─ example/        安卓 App（Material 3 原生风格，中文界面）
│  └─ lib/pages/   embed_page.dart（嵌入）/ extract_page.dart（提取）
├─ android/ ios/ windows/  平台工程
└─ tools/interop/  互通测试工具（Python↔C++ 双向对拍）
```

## 功能

- **嵌入**：选图 → 输入文本或 Logo 图 → （可选密码）→ 输出打水印的图
- **提取**：选图 → 输入水印长度（bit）或 Logo 尺寸 → 还原文本 / Logo 图
- 水印对 JPEG 压缩、裁剪等攻击鲁棒；三通道冗余 + 循环嵌入 + k-means 二值化
- 全部本地离线处理，图片不上传

## 致谢与参考的开源项目

本项目站在以下优秀开源项目之上，特此致谢：

| 项目 | 用途 | 协议 |
|---|---|---|
| [guofei9987/blind_watermark](https://github.com/guofei9987/blind_watermark) | 核心 DWT-DCT-SVD 盲水印算法（C++ 实现与其 bit 级互通） | MIT |
| [JackCaow/flutter_blind_watermark](https://github.com/JackCaow/flutter_blind_watermark) | Flutter FFI 插件工程脚手架（Eigen/stb_image 集成） | MIT |
| [facebookresearch/watermark-anything](https://github.com/facebookresearch/watermark-anything) | WAM 强鲁棒水印模型（Meta，ICLR 2025） | MIT |
| [Eigen](https://eigen.tuxfamily.org/) | 线性代数库（SVD/DCT） | MPL2 |
| [stb](https://github.com/nothings/stb) | 图像编解码（PNG/JPEG/BMP/WebP） | Public Domain/MIT |
| [ONNX Runtime](https://github.com/microsoft/onnxruntime) | Android 端模型推理 | MIT |
| [Flutter](https://flutter.dev/) | 跨平台 UI 框架 | BSD-3 |

WAM 模型（ONNX，含 int8 量化版）托管于 [VanemKrAu/blind-watermark-models](https://github.com/VanemKrAu/blind-watermark-models)，发布版 App 首次使用强鲁棒模式时自动下载。

## 构建

环境：Flutter SDK + Android SDK（NDK 25.1 + CMake），详见 `E:\WorkSpace\.local\env.ps1`（环境变量定向 E 盘）。

```bash
# 发布版（不含模型，约 35MB；强鲁棒模式首次使用时在线下载模型）
flutter build apk --release

# 测试版（内置模型，约 130MB，开箱即用）：
# 先把模型复制进 example/assets/onnx/（wam_embedder.onnx + wam_extractor_int8.onnx，
# 从 blind-watermark-models Release 下载），再执行上面的构建命令
# 输出: example/build/app/outputs/flutter-apk/app-release.apk

# 运行（真机/模拟器，热重载）
flutter run
```

## 互通测试

```bash
cd tools/interop
python interop_test.py   # 需本机 Python + blind_watermark 库
# 输出: 29 checks, 0 failures（双向 × 文本/图片/bit × 3 组密码 × JPEG 压缩）
python golden_gen.py | golden_test.exe   # numpy RNG 逐位对拍：82/82
```

`bwm_cli.cpp` 编译命令（MinGW）：
```
g++ -std=c++17 -O2 bwm_cli.cpp ../../src/{numpy_rng,watermark_core,dct,dwt,color_convert,image_io}.cpp \
  -I ../../src -I ../../third_party -I ../../third_party/Eigen -o bwm_cli.exe
```

## 使用提示

- **单一入口**：嵌入 = 选图 + 输入文本/Logo + 一个按钮；提取 = 选图 + 一个按钮（全自动，零参数）
- **自动选方案**：小图（长边 ≤1024）用强鲁棒方案（WAM，抗裁剪/旋转/压缩）；大图与 Logo 用 DWT（保持画质）
- 提取依赖**本机嵌入记录**（最近 100 条）：请在嵌入水印的同一台设备上提取；强鲁棒标识可在任何设备识别出 32 位码

## 安全模型

- **密码**：嵌入时「高级选项」可设置水印密码（默认 1，与原 Python 库互通）。密码参与水印的随机打乱，**提取方必须使用相同密码**才能还原
- **本机自动**：密码/长度等参数保存在本机嵌入记录中，本机提取无需手动输入
- **他人拿到图片**：不知道密码 + 不知道长度/尺寸 → 无法还原文本/Logo 水印；强鲁棒模式只能看到一串 32 位标识码（无本机记录时无意义）
- **局限（如实说明）**：① DWT 密码是整数种子，短密码可被暴力枚举（建议设较复杂的数字）② 本地记录为明文存储（root 设备可读）③ 跨设备提取需要同一套参数（本机记录不跨设备）

## 鲁棒性（实测，1024×768 测试图）

| 攻击 | DWT 文本/Logo | WAM 强鲁棒 |
|---|---|---|
| JPEG 压缩 q50~q95 | ✅ 完美 | ✅ 完美（q70 起个别位错，靠历史匹配容忍） |
| 高斯模糊 3/5/7 | ✅ | ✅ |
| 局部涂黑 10%~50% | ✅ | ✅ |
| 亮度 -20% | ✅ | ✅ |
| 缩放 50% | ❌ | ✅ |
| 旋转 5° | ❌ | ✅（局部水印模式） |
| 裁剪（保留 75%） | ❌ | ✅（局部水印模式） |
| 裁剪 50% 以下 / 强噪声 | ❌ | ❌（技术边界，业界普遍） |
