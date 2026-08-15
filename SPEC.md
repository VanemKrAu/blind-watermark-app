# SPEC — 盲水印 App 设计规范

## 目标

安卓应用：上传/选择图片 → 本地离线嵌入盲水印（文本 / Logo 图）→ 保存；可提取验证。
与 Python 库 guofei9987/blind_watermark **互通**（双向可提取）。

## 核心约束（不可破坏）

1. **算法 bit 级兼容**：`src/` 下 C++ 实现必须与 Python 版 `blind_watermark` 逐 bit 对齐：
   - 随机数：numpy `RandomState` = MT19937 + `random_interval`（next_uint32 + mask-rejection，闭区间 [0, max]）+ `rk_double`（53-bit）
   - shuffle 结构：水印位 `RandomState(passwordWm).shuffle`；块排列 `random((block_num,16)).argsort(axis=1)`
   - 嵌入：YUV（BT.601 浮点，U/V 含 +0.5 偏置）→ Haar DWT → 4×4 块 DCT → SVD → 量化 s0/s1（d1=36, d2=20）→ 逆变换；三通道全嵌；循环嵌入 `i % wm_size`
   - 提取：三通道平均 → `passwordWm` 逆打乱 → k-means 二值化（str/bit）
   - 字符串编码：`bin(int(utf8.hex(),16))[2:]`（变长 bit，无前导零）
2. **互通验收标准**：`tools/interop/interop_test.py` 必须 29/29 全过（双向 × 文本/图片/bit × 密码组 × JPEG q95/q80）
3. **RNG 验收标准**：`golden_gen.py` 对拍必须全过（rand/shuffle/argsort 与 numpy 逐位一致）
4. 修改上述任一环节后，必须重跑全部互通测试

## 设计原则

- Material 3 原生风格（谷歌原生观感），跟随系统深浅色，中文界面
- 全部处理在本地（隐私）；无网络依赖
- 大图处理放后台 Isolate，不阻塞 UI
- 密码（passwordWm/passwordImg）嵌入/提取必须一致；提取文本需 bit 长度，提取 Logo 需原始宽高

## 范围边界

- 支持输入：PNG/JPEG/WebP/BMP/GIF；输出：PNG/JPEG/WebP
- 水印容量：bit 数 < 图片 4×4 块数（块数 = (h/8)×(w/8)，512×512 图 ≈ 4096 bit）
- 不做：可见水印、视频水印、去水印
