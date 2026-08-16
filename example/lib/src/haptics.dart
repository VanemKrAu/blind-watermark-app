import 'package:flutter/services.dart';

/// 触觉反馈统一入口。
///
/// 语义映射参考 Android `HapticFeedbackConstants` 设计规范：
/// - 长按进入上下文操作（多选） → CONTEXT_CLICK → mediumImpact
/// - 选择/勾选状态变化、全选 → CLOCK_TICK → selectionClick
/// - 归档/取消归档/置顶等轻量状态切换 → lightImpact
/// - 删除（破坏性操作） → heavyImpact
/// - 嵌入/提取/保存成功 → lightImpact
///
/// Flutter 的 HapticFeedback 在 Android 上走系统触觉通道，自动遵循
/// 系统「触摸反馈」设置，无需额外权限。
class Haptics {
  /// 长按进入上下文操作（多选）。
  static Future<void> longPress() => HapticFeedback.mediumImpact();

  /// 勾选 / 取消勾选 / 全选等选择状态变化。
  static Future<void> select() => HapticFeedback.selectionClick();

  /// 置顶 / 取消置顶等轻量切换。
  static Future<void> toggle() => HapticFeedback.lightImpact();

  /// 归档 / 取消归档。
  static Future<void> archive() => HapticFeedback.lightImpact();

  /// 删除（破坏性操作，重震动）。
  static Future<void> delete() => HapticFeedback.heavyImpact();

  /// 任务成功（嵌入 / 提取 / 保存到相册）。
  static Future<void> success() => HapticFeedback.lightImpact();
}
