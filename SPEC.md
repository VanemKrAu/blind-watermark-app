# SPEC — 盲水印 App 设计规范

## 目标

安卓应用：选择图片 → 本地离线嵌入盲水印（文本 / Logo 图）→ 保存；可提取验证。
App 内嵌入/提取**自洽闭环**（同一方案打的水印，App 内必定可提取）。算法源自
[guofei9987/blind_watermark](https://github.com/guofei9987/blind_watermark)（MIT），
**与参考库的 bit 级互通不再作为产品约束**（2026-08 决策）。

## 核心约束（不可破坏）

1. **App 内自洽**：嵌入与提取必须使用同一套参数推导（尺寸/块数/种子/长度），
   保存的水印图在 App 内提取结果一致。
2. **内存有界**：任何照片（12-108MP）都不允许以全分辨率帧、大 PNG 或超大
   DWT 工作集出现在内存里：
   - 选图解码即缩码（长边 ≤2048，引擎侧 scaled decode）
   - DWT 载体长边 ≤2048（实测 4000×3000 原生峰值 ~1GB，必被杀）
   - 提取页对超限图片跳过 DWT 尝试并明确提示
3. **稳定性**：NDK 构建只用 `-O3`（禁用 -ffast-math/-flto 等破坏 IEEE-754 的
   参数——实测过的 ARM 静默崩溃风险源）；ONNX 推理单线程串行；executor 懒重建。
4. **相册零污染**：不点「保存到相册」绝不产生相册写入；file_picker 缓存副本
   选图后立即清除；`.nomedia` 覆盖内/外部 cache + files 目录。
5. **崩溃可诊断**：原生信号（SIGSEGV/SIGABRT/SIGBUS/SIGFPE）+ Java 未捕获异常
   写入 crash.txt，下次启动弹窗展示（可复制）。

## 实现参考（算法细节，源自参考库；不再作为互通验收）

- 随机数：numpy `RandomState` = MT19937 + `random_interval`（next_uint32 + mask-rejection，闭区间 [0, max]）+ `rk_double`（53-bit）
- shuffle 结构：水印位 `RandomState(passwordWm).shuffle`；块排列 `random((block_num,16)).argsort(axis=1)`
- 嵌入：YUV（BT.601 浮点，U/V 含 +0.5 偏置）→ Haar DWT → 4×4 块 DCT → SVD → 量化 s0/s1（d1=36, d2=20）→ 逆变换；三通道全嵌；循环嵌入 `i % wm_size`
- 提取：三通道平均 → `passwordWm` 逆打乱 → k-means 二值化（str/bit）
- 字符串编码：`bin(int(utf8.hex(),16))[2:]`（变长 bit，无前导零）

## 设计原则

- Material 3 原生风格（谷歌原生观感），跟随系统深浅色，中文界面
- 全部处理在本地（隐私）；无网络依赖
- 大图处理放后台 Isolate，不阻塞 UI
- 密码（passwordWm/passwordImg）嵌入/提取必须一致；提取文本需 bit 长度，提取 Logo 需原始宽高（本机记录自动带入）

## 回归测试

- `tools/interop/interop_test.py`：29/29（Python↔C++ 双向对拍，**降级为回归测试**）
- `golden_gen.py | golden_test.exe`：numpy RNG 逐位对拍 82/82
- 修改 `src/` 算法或构建参数后建议重跑上述回归

## 范围边界

- 支持输入：PNG/JPEG/WebP/BMP/GIF（HEIC 等经 Flutter 引擎转 PNG）；输出：PNG
- 水印容量：bit 数 < 图片 4×4 块数（块数 = (h/8)×(w/8)，512×512 图 ≈ 4096 bit）
- 不做：可见水印、视频水印、去水印
