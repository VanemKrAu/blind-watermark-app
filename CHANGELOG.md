# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.35] - 2026-08-18

### Changed
- **提取鲁棒性实测矩阵**（16 项攻击 bit 级实测）：JPEG q50~q95 / 涂黑 / 亮度 / 缩放全部 0~1 bit 错（容错 2 全覆盖）；WAM 实测旋转 5° 2 bit 错（matchWam 容错 4 内正常匹配）
- **修复裁剪攻击 resync 方法错误**：原「拉伸/等比缩放」还原会让裁剪图网格错位（实测 106 bit 错）→ 新增「内容原大小放回原画布」（`placePngCentered`，实测 0 bit 错），还原候选集 3 → 4
- README 鲁棒性表按实测修正：高斯模糊 5/7 分列（Logo ✅ / 文本 ❌ 位错 23+ 物理损坏）

## [1.1.34] - 2026-08-18

### Changed
- **自动提取文本校验重构为「记录原文校验」**（`recBitsMatch`，数学严格）：以记录里嵌入时的原文编码为基准比对提取 bit，容错 ≤2 位（JPEG q70 实测 1 bit 错可通过）——随机位流/假文本与固定文本编码差异远超容错（概率 ~2⁻ⁿ），杜绝误判
- 手动参数提取直接展示结果（用户主动，仅过滤空/乱码符）

## [1.1.33] - 2026-08-18

### Fixed
- **修复 Logo 自动提取被假文本截胡**：文本提取曾把 Logo 水印图的乱码误判为文本（截断 Logo 阶段）→ 提取校验 + WAM 匹配改为暂存兜底（不再阻断 DWT 阶段，优先级：手动 > DWT > WAM > 32 位码）

## [1.1.32] - 2026-08-18

### Changed
- **提取进度条平滑化**：步骤间用插值动画（350ms easeOutCubic）连续过渡，观感与下载进度条一致，不再阶梯跳变

## [1.1.31] - 2026-08-18

### Changed
- **DWT 提取智能预筛**（零误伤）：
  - 容量硬预筛：文本 bit / Logo 像素数超过载体容量的记录在数学上不可能嵌入该图，直接跳过
  - 尺寸匹配排序：载体尺寸与当前图相同的记录优先尝试（通常首条即中）
  - 先过滤再截断；无可试记录时明确提示

## [1.1.30] - 2026-08-18

### Changed
- **提取进度条原子步骤化**：WAM 每次尝试、每个还原候选完成均推进进度（此前阶段末尾整块跳变）；修复嵌入页过时文案（"超 4000px"→ 分辨率无上限）

## [1.1.29] - 2026-08-18

### Changed
- **取消嵌入/提取的分辨率限制**（用户决策，13MP 真机实测无闪退）：DWT 任意尺寸原样嵌入/提取，不再降采样；超大图耗时较长，**嵌入与提取均新增进度条**（提取按 WAM 尝试/DWT 记录步骤显示确定进度，解码与手动提取为不确定进度），选图预览仍秒开（预览小图分离）

## [1.1.28] - 2026-08-18

### Changed
- 修复选图预览慢：预览只解码小图（长边 ≤1024），原始字节按需全尺寸解码
- 修复 DWT 自动提取被跳过：提取上限放宽（13MP 竖拍不再误判"图片过大"）；WAM 置信度过低（无 WAM 水印）不再产出 32 位码干扰 DWT 提取

## [1.1.27] - 2026-08-18

### Changed
- **DWT 大图上限放宽 1536 → 4000**：13MP 照片（3120×4160）真机实测可嵌入无闪退，手机拍照不再降采样；选图解码同步放宽，仅超 4000px 才自动缩放（低配机仍建议保守）

## [1.1.25] - 2026-08-18

### Changed
- **App 名改英文 BlindWatermark**：安卓启动器显示名、关于页标题、系统任务名、页面底部版本号前缀、README 标题、APK 文件名统一为英文（界面正文中文保留）

## [1.1.24] - 2026-08-18

### Changed
- 删除嵌入页冗余说明文案（方案选择器下方已有动态说明）

## [1.1.23] - 2026-08-18

### Added
- **文本水印可自由选择算法**：嵌入页文本模式新增方案切换（强鲁棒 WAM / 经典 DWT），默认强鲁棒保持原行为
  - 经典 DWT：密码 + 长度即可在任意设备还原完整文本（跨设备可用），代价是容量有限（载体 4×4 块数以内）、不抗旋转、大图自动缩至 1536px
  - DWT 文本记录新增载体尺寸（cw/ch），提取端自动启用「网格再同步」还原，缩放/裁剪后的图更易救回

### Changed
- 关于页「功能与用法 / 局限 / 鲁棒性边界」按 WAM / DWT 两方案分列，不再混用

## [1.1.20] - 2026-08-17

### Added
- **DWT 提取网格再同步**：嵌入时记录载体尺寸，提取时自动尝试「拉伸/填补回原尺寸」后再提取（对齐参考库攻击演示的还原步骤）——缩放/裁剪后的水印图（文本/Logo）显著提升可提取率

### Changed
- 记录新增载体尺寸（cw/ch），旧记录自动兼容

## [1.1.19] - 2026-08-17

### Added
- 底部新增「**嵌入记录**」tab：查看本机全部嵌入记录（32 位标识码可复制、内容、时间戳、密码）
- 记录**左滑操作**（QQ 风格）：删除（红）/ 归档（橙）/ 置顶（蓝）；归档记录自动收纳至**二级页面**（入口在列表底部，可取消归档/删除）
- **长按多选**：批量归档/删除（删除可撤销）；多选时系统返回键优先退出多选
- **触觉反馈**：长按/勾选/归档/删除/成功均有对应震动（遵循 Android HapticFeedbackConstants 规范）
- 三页统一页头（logo 图标块 + 大标题）；列表错峰入场、置顶移动、行移除等动画

### Changed
- **多尝试提取**：WAM 提取依次尝试原图 + 居中裁剪 85%/70%，按位解码置信度（mean |bit margin|）择优——轻度裁剪/带边框图片更易救回
- 记录排序确定性：新增 `seq` 序号（置顶 → 时间 → seq），旧记录自动迁移，取消置顶必回原位

### Fixed
- 修复「上次运行发生崩溃」假弹窗（仅存在真实崩溃文件时弹出）
- 修复嵌入记录列表空白（确定性渲染，不再依赖隐藏页 ticker）
- 修复置顶后取消置顶不回原位；提取解码失败不再误报「模型不可用」

## [1.1.18] - 2026-08-16

### Changed
- 文本⇄Logo 切换动画改为**纯渐隐渐显**（移除左右滑动，与底部 tab 观感一致；高度仍平滑伸缩，下方内容不跳变）；提取页手动参数区同步

## [1.1.17] - 2026-08-16

### Fixed
- 修复「上次运行发生崩溃」假弹窗：设备信息被无条件拼入报告导致每次启动都判为有崩溃报告；现仅在存在真实崩溃文件时弹窗
- Logo 选择框比例调整（64px 高、横向紧凑内容）；文本⇄Logo 切换动画重做（退场不拉伸、高度单阶段平滑变形、方向性滑动），提取页手动参数区同款动画
- 启动图标水滴缩小至 40%（适配各机型遮罩，白底）— 修复部分机型裁切

### Changed
- **仅适配 64 位（arm64-v8a）**，移除 armeabi-v7a：APK 从 161.7MB 降至 **125.2MB**；32 位设备（2017 年前机型）不再支持

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
