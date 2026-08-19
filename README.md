<h1 align="center">BlindWatermark App</h1>

<p align="center">
  <img src="docs/icon.svg" width="256" height="256" alt="BlindWatermark" />
</p>

基于 DWT-DCT-SVD + WAM 的图片盲水印工具：**嵌入水印无需原图即可提取**（盲水印）。
安卓 App（Flutter + C++ FFI），核心算法源自 [guofei9987/blind_watermark](https://github.com/guofei9987/blind_watermark)（MIT），App 内嵌入/提取自洽闭环。

## 目录结构

```
blind-watermark-app/
├─ src/            C++ 核心（算法 + 随机数 + 图像 I/O）
│  ├─ numpy_rng.*        # MT19937 复刻 numpy RandomState（与参考实现一致）
│  ├─ watermark_core.*   # DWT-DCT-SVD 嵌入/提取（源自参考算法，App 内自洽）
│  ├─ dct.* / dwt.*      # 正交 DCT-II / Haar 小波
│  ├─ color_convert.*    # YUV 转换（复刻 cv2 浮点路径，含 +0.5 偏置）
│  ├─ image_io.*         # PNG/JPEG/BMP/WebP 编解码（stb_image）
│  └─ blind_watermark_ffi.*  # C ABI 接口（Dart FFI 调用）+ 原生崩溃捕获
├─ lib/            Dart 层（FFI 绑定 + 嵌入/提取 API）
├─ example/        安卓 App（Material 3 原生风格，中文界面，4 tab）
│  └─ lib/pages/   embed_page.dart（嵌入）/ extract_page.dart（提取）/
│                  history_page.dart（嵌入记录）/ about_page.dart（关于）
├─ android/ ios/ windows/  平台工程
└─ tools/interop/  算法回归测试（Python↔C++ 双向对拍，非强制互通约束）
```

## 功能

- **嵌入**：选图 → 输入文本或 Logo 图 → （可选密码）→ 输出打水印的图
- **提取**：选图 → 自动识别（零参数）→ 还原文本 / Logo / 强鲁棒标识；他人图片可用「手动提取参数」；WAM 多尝试提取（原图/85%/70% 裁剪按置信度择优）
- **嵌入记录**：本机全部记录（32 位码可复制/时间戳/密码）——左滑删除/归档/置顶（QQ 风格），长按多选批量操作，归档收纳至二级页且不参与自动匹配
- **触觉反馈**：长按/勾选/归档/删除/成功均有对应震动（Android HapticFeedbackConstants 规范）
- 单一入口：嵌入 = 选图 + 输入 + 一个按钮；提取 = 选图 + 一个按钮
- **方案策略**：文本水印默认用强鲁棒方案（WAM，抗裁剪/旋转/压缩，输出保持原分辨率锐利），**可切换经典 DWT**（密码 + 长度即可跨设备还原完整文本，但容量有限、不抗旋转）；Logo 水印用 DWT（完整还原，**分辨率无上限**，超大图耗时长有进度条）
- 全部本地离线处理，图片不上传；模型已内置在安装包内，开箱即用

## 致谢与参考的开源项目

本项目站在以下优秀开源项目之上，特此致谢：

| 项目 | 用途 | 协议 |
|---|---|---|
| [guofei9987/blind_watermark](https://github.com/guofei9987/blind_watermark) | 核心 DWT-DCT-SVD 盲水印算法（算法源自该项目） | MIT |
| [JackCaow/flutter_blind_watermark](https://github.com/JackCaow/flutter_blind_watermark) | Flutter FFI 插件工程脚手架（Eigen/stb_image 集成） | MIT |
| [facebookresearch/watermark-anything](https://github.com/facebookresearch/watermark-anything) | WAM 强鲁棒水印模型（Meta，ICLR 2025） | MIT |
| [Eigen](https://eigen.tuxfamily.org/) | 线性代数库（SVD/DCT） | MPL2 |
| [stb](https://github.com/nothings/stb) | 图像编解码（PNG/JPEG/BMP/WebP） | Public Domain/MIT |
| [ONNX Runtime](https://github.com/microsoft/onnxruntime) | WAM 推理（C++ FFI 直调 C API，无 Java/JNI 层） | MIT |
| [Flutter](https://flutter.dev/) | 跨平台 UI 框架 | BSD-3 |

WAM 模型（ONNX，含 int8 量化版）已内置在安装包内。注意：`VanemKrAu/blind-watermark-models` Release 里的 embedder 缺外部数据文件（不可直接用）；App 现用自包含 embedder，由 `tools/wam/export_embedder_selfcontained.py` 从 Meta 官方 checkpoint 导出。

## 构建

环境：Flutter SDK + Android SDK（NDK 25.1 + CMake），详见 `E:\WorkSpace\.local\env.ps1`（环境变量定向 E 盘）。
模型（`example/assets/onnx/`，自包含 embedder + int8 extractor）放入后：

```bash
flutter build apk --release
# 输出: example/build/app/outputs/flutter-apk/app-release.apk（约 125MB，模型内置；仅 arm64-v8a）
```

## 算法回归测试

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

（互通测试已降级为**回归测试**：与参考库的 bit 级一致不再是产品约束，测试仅用于防止算法改动引入回归。）

## 使用提示

- **单一入口**：嵌入 = 选图 + 输入文本/Logo + 一个按钮；提取 = 选图 + 一个按钮（全自动，零参数）；文本方案可在「强鲁棒（WAM）」与「经典（DWT）」间切换
- **方案策略**：文本水印默认强鲁棒（WAM，任意图幅可嵌入、输出原分辨率锐利，抗裁剪/旋转/压缩），可切换经典 DWT（跨设备可还原完整文本，但容量有限、不抗旋转）；Logo 用 DWT（分辨率无上限，超大图耗时较长）
- 提取依赖**本机嵌入记录**（最近 100 条）：本机自动还原完整文本 / Logo；**他人图片**可在「手动提取参数」输入密码 + 长度（文本）或 Logo 尺寸（图片）；强鲁棒标识可在任何设备识别出 32 位码
- **记录管理**：「嵌入记录」tab 可左滑删除/归档/置顶、长按多选批量操作；**归档记录不参与自动提取匹配**；系统返回键在多选时优先退出多选

## 安全模型

- **密码**：嵌入时「高级选项」可设置水印密码（默认 1）。密码参与水印的随机打乱，**提取方必须使用相同密码**才能还原
- **本机自动**：密码/长度等参数保存在本机嵌入记录中，本机提取无需手动输入
- **他人拿到图片**：不知道密码 + 不知道长度/尺寸 → 无法还原文本/Logo 水印；强鲁棒（WAM）文本水印在任何设备只能看到一串 32 位标识码（完整文字仅嵌入设备本机可还原）；若嵌入时选择经典 DWT 方案，则提供密码 + 长度即可在任何设备还原完整文本
- **局限（如实说明）**：① DWT 密码是整数种子，短密码可被暴力枚举（建议设较复杂的数字）② 本地记录为明文存储（root 设备可读）③ 跨设备提取需要同一套参数（本机记录不跨设备，可用「手动提取参数」补足）

## 鲁棒性（实测，1024×768 测试图）

| 攻击 | DWT（Logo / 经典文本） | WAM 强鲁棒（文本） |
|---|---|---|
| JPEG 压缩 q50~q95 | ✅ 完美 | ✅ 完美（q70 起个别位错，靠历史匹配容忍） |
| 高斯模糊 3 | ✅ | ✅ |
| 高斯模糊 5/7 | ✅ Logo / ❌ 文本（实测位错 23/41，信息物理损坏） | ✅ |
| 局部涂黑 10%~50% | ✅ | ✅ |
| 亮度 -20% | ✅ | ✅ |
| 缩放 50% | ✅（自动还原回原尺寸后） | ✅ |
| 旋转 5° | ❌ | ✅（局部水印模式） |
| 裁剪（保留 75%） | ✅（内容原大小放回画布后，实测 0 错） | ✅（局部水印模式） |
| 裁剪 50% 以下 / 强噪声 | ❌ | ❌（技术边界，业界普遍） |

注 1：DWT 的缩放/裁剪抵抗依赖提取端的「网格再同步」（缩放用拉伸、裁剪用内容原大小放回画布，App 自动尝试全部还原方式，与参考库攻击演示一致）；旋转是 DWT 的数学硬伤（参考库 README 的 45° 演示为挑选案例，实测还原后仍失败）。高斯模糊 5+ 对文本水印为物理损坏（位错 23+/200，参考库同样无法还原），Logo 不受影响。
注 2：WAM 文本水印**任意图幅可嵌入**（嵌入在 256px、输出保持载体原分辨率锐利），提取端统一缩放 256px；**可靠提取限载体长边 ≤2048**（1024 实测 conf 6.3、1426×1014 实测 conf 3.4，阈值 2.0）；长边 >2048（如 13MP 照片）信号弱提取失败——这是 WAM 模型固有极限（参考库实测同样 conf ~1.6），此类大图请改用经典 DWT 方案。
