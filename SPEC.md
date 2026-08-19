# SPEC — BlindWatermark App 设计规范

## 目标

安卓应用：选择图片 → 本地离线嵌入盲水印（文本 / Logo 图）→ 保存；可提取验证。
**文本水印默认走 WAM 强鲁棒**（32 位标识码，抗裁剪/旋转/压缩；完整文字仅本机还原），
**可切换经典 DWT**（密码 + 长度即可跨设备还原完整文本，但容量有限、不抗旋转），
**Logo 走 DWT**（完整还原）。算法源自
[guofei9987/blind_watermark](https://github.com/guofei9987/blind_watermark)（MIT）与
[facebookresearch/watermark-anything](https://github.com/facebookresearch/watermark-anything)（MIT），
**与参考库的 bit 级互通不再作为产品约束**（2026-08 决策）。

## 核心约束（不可破坏）

1. **App 内自洽**：嵌入与提取必须使用同一套参数推导（尺寸/块数/种子/长度），
   保存的水印图在 App 内提取结果一致。
2. **内存有界（2026-08-18 修订：取消 DWT 分辨率上限）**：用户决策并真机实测
   （13MP 无闪退）——DWT 任意尺寸原样嵌入/提取，不再降采样：
   - 选图预览只解码小图（长边 ≤1024，秒开）；原始字节保留，嵌入/提取时按需全尺寸解码
   - 超大图嵌入/提取耗时长：嵌入/提取均带进度条明示
   - 12MP 桌面实测峰值 ~1GB，低配机仍有风险（用户已知情接受）
   - 提取页对超限图片跳过 DWT 尝试并明确提示
3. **稳定性**：NDK 构建只用 `-O3`（禁用 -ffast-math/-flto 等破坏 IEEE-754 的
   参数——实测过的 ARM 静默崩溃风险源）；WAM 推理由 FFI 直调 ORT C API，
   单例引擎互斥锁串行化，会话按需懒创建。
4. **相册零污染**：不点「保存到相册」绝不产生相册写入；Android 选图走
   ACTION_GET_CONTENT 流式读内存（零落盘）；`.nomedia` 覆盖内/外部 cache +
   files 目录。
5. **崩溃可诊断**：原生信号（SIGSEGV/SIGABRT/SIGBUS/SIGFPE）+ Java 未捕获异常
   写入 crash.txt，下次启动弹窗展示（可复制）；报告仅在存在真实崩溃文件时弹出。

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
- 密码（passwordWm/passwordImg）嵌入/提取必须一致；提取文本需 bit 长度，提取 Logo 需原始宽高（本机记录自动带入；**他人图片走「手动提取参数」手动输入**）
- **WAM 多尝试提取**：原图 + 居中裁剪 85%/70% 依次尝试，按位解码置信度（mean |bit margin|）择优，提升轻度裁剪/带边框图片的识别率
- **自动提取防误判**：DWT 文本自动提取须通过**记录原文编码校验**（recBitsMatch，容错 ≤2 位——JPEG 轻损实测 1 位错；随机位流/假文本与固定文本编码差异远超容错，数学不可混）；WAM 匹配结果暂存兜底、不阻断 DWT 阶段（优先级 手动 > DWT > WAM > 32 位码）；网格再同步候选 4 种（原图/拉伸/等比填充/内容原大小放回——裁剪攻击用「放回」恢复网格）
- **嵌入记录管理**：记录含时间戳；左滑删除/归档/置顶（QQ 风格）、长按多选批量操作；**归档记录不参与自动提取匹配**；排序（置顶 → ts 倒序 → seq 倒序）确定性，旧记录自动迁移补 seq
- **触觉反馈**：遵循 Android `HapticFeedbackConstants` 语义（长按 medium / 勾选 selection / 删除 heavy / 成功 light）
- **动画**：内容切换只动 transform/opacity；高度变形用 AnimatedSize 单阶段（card-resize 例外）；列表行渲染**确定性可见**（不依赖隐藏页 ticker），入场动画带强制完成兜底；系统减弱动画一律零时长
- **返回键语义**：多选模式下系统返回键优先退出多选（PopScope）

## 回归测试

- `tools/interop/interop_test.py`：29/29（Python↔C++ 双向对拍，**降级为回归测试**）
- `golden_gen.py | golden_test.exe`：numpy RNG 逐位对拍 82/82
- 修改 `src/` 算法或构建参数后建议重跑上述回归

## 范围边界

- 支持输入：PNG/JPEG/WebP/BMP/GIF（HEIC 等经 Flutter 引擎转 PNG）；输出：PNG
- DWT 容量：bit 数 < 图片 4×4 块数（块数 = (h/8)×(w/8)，512×512 图 ≈ 4096 bit）；WAM 容量固定 32 bit（文本→CRC32 标识码，任意文本长度均可容纳）
- WAM 文本水印：嵌入在 256px，输出保持载体原分辨率锐利（delta 放大与锐利原图混合）；提取端统一缩放 256px，**任意图幅可嵌入，可靠提取限载体长边 ≤2048**（更大图信号弱为模型固有极限，建议 DWT）
- 经典 DWT 文本水印（可选方案）：容量 = (载体 w/8)×(h/8) bit 以内，载体分辨率无上限（13MP 真机实测）；记录含 bit 长度与载体尺寸，提取端自动匹配或手动参数（密码+长度）均可
- 不做：可见水印、视频水印、去水印
