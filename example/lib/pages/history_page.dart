import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_slidable/flutter_slidable.dart';

import '../src/haptics.dart';
import '../src/page_header.dart';
import '../src/wam_codec.dart';

bool _reduceMotion(BuildContext c) =>
    MediaQuery.maybeOf(c)?.disableAnimations ?? false;

const _enterCurve = Cubic(0.22, 1.0, 0.36, 1.0);

/// 嵌入记录页（底部导航第 3 个 tab）：
/// 主列表展示未归档记录（置顶组在前，按时间倒序）；
/// 每行左滑出现 QQ 风格三按钮：删除（红）/ 归档（橙）/ 置顶（蓝）；
/// **长按进入多选**：勾选多条后可批量归档/删除（删除带撤销）；
/// 列表底部为「已归档」入口，点击进入二级页面。
///
/// 动画（ui-animation 规范，全部基于确定性渲染，绝不依赖隐藏页 ticker）：
/// - [active] 变为 true（tab 被看到）时触发错峰入场（Interval 曲线逐行淡入上滑），
///   带 400ms 强制完成兜底——任何情况下行都必然可见
/// - 归档/删除：行淡出 200ms 后移除；置顶：原位淡出 → 目标位淡入
/// - 多选：操作栏顶部滑入、勾选图标缩放淡入、选中底色渐变
/// - 触觉：长按 mediumImpact、勾选 selectionClick、归档 lightImpact、
///   删除 heavyImpact、置顶 lightImpact
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key, this.active = false});

  /// 当前 tab 是否可见（由 HomeShell 传入；可见时播放列表入场动画）。
  final bool active;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage>
    with SingleTickerProviderStateMixin {
  List<WmRecord> _records = [];
  int _archivedCount = 0;
  bool _loading = true;
  bool _selectionMode = false;
  final Set<String> _selected = {};
  /// 正在淡出的记录 key。
  final Set<String> _removing = {};
  /// 刚置顶/取消置顶移动到位、需要淡入的记录 key。
  String? _enteringKey;

  /// 页面入场控制器（错峰 Interval 曲线）。
  late final AnimationController _entrance;

  @override
  void initState() {
    super.initState();
    _entrance = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 360));
    _reload();
  }

  @override
  void didUpdateWidget(HistoryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 每次进入本 tab（active 变 true）都重新加载记录——否则显示的是
    // App 启动时的旧数据，刚嵌入的新记录看不到（需重启才刷新）。
    if (!oldWidget.active && widget.active) {
      _reload();
      _playEntrance();
    }
  }

  void _playEntrance() {
    final reduce = _reduceMotion(context);
    if (reduce) {
      _entrance.value = 1;
      return;
    }
    _entrance.value = 0;
    _entrance.forward();
    // 兜底：无论 ticker 是否被静音/暂停，行都必然可见。
    Future.delayed(const Duration(milliseconds: 420), () {
      if (mounted && !_entrance.isCompleted) {
        _entrance.value = 1;
      }
    });
  }

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final recs = await WmHistory.active();
    final arch = await WmHistory.archived();
    if (!mounted) return;
    setState(() {
      _records = recs;
      _archivedCount = arch.length;
      _loading = false;
      _selectionMode = false;
      _selected.clear();
      _removing.clear();
      _enteringKey = null;
    });
  }

  void _enterSelection(WmRecord r) {
    Haptics.longPress();
    setState(() {
      _selectionMode = true;
      _selected.add(WmHistory.keyOf(r));
    });
  }

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selected.clear();
    });
  }

  void _toggleSelect(WmRecord r) {
    Haptics.select();
    final k = WmHistory.keyOf(r);
    setState(() {
      if (!_selected.remove(k)) _selected.add(k);
    });
  }

  void _toggleSelectAll() {
    Haptics.select();
    setState(() {
      if (_selected.length == _records.length) {
        _selected.clear();
      } else {
        _selected.addAll(_records.map(WmHistory.keyOf));
      }
    });
  }

  /// 淡出 [keys] 对应行（200ms），随后从列表移除并刷新计数。
  Future<void> _removeRowsAnimated(Set<String> keys) async {
    final reduce = _reduceMotion(context);
    if (!reduce) {
      setState(() => _removing.addAll(keys));
      await Future.delayed(const Duration(milliseconds: 200));
    }
    if (!mounted) return;
    setState(() {
      _records.removeWhere((r) => keys.contains(WmHistory.keyOf(r)));
      _removing.removeAll(keys);
    });
  }

  Future<void> _batchArchive() async {
    final keys = Set<String>.from(_selected);
    for (final k in keys) {
      await WmHistory.updateByKey(k, archived: true);
    }
    Haptics.archive();
    _exitSelection();
    await _removeRowsAnimated(keys);
    final arch = await WmHistory.archived();
    if (mounted) setState(() => _archivedCount = arch.length);
    _snack('已归档 ${keys.length} 条');
  }

  Future<void> _batchDelete() async {
    final keys = Set<String>.from(_selected);
    final removed =
        _records.where((r) => keys.contains(WmHistory.keyOf(r))).toList();
    for (final k in keys) {
      await WmHistory.removeByKey(k);
    }
    Haptics.delete();
    _exitSelection();
    await _removeRowsAnimated(keys);
    _snack('已删除 ${keys.length} 条', action: SnackBarAction(
      label: '撤销',
      onPressed: () async {
        for (final r in removed) {
          await WmHistory.add(r);
        }
        _reload();
      },
    ));
  }

  void _snack(String msg, {SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), action: action, duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _archiveOne(WmRecord r) async {
    await WmHistory.updateByKey(WmHistory.keyOf(r), archived: true);
    Haptics.archive();
    await _removeRowsAnimated({WmHistory.keyOf(r)});
    final arch = await WmHistory.archived();
    if (mounted) setState(() => _archivedCount = arch.length);
  }

  /// 置顶/取消置顶：行原位淡出 → 重排后目标位淡入（移动感）。
  Future<void> _togglePin(WmRecord r) async {
    Haptics.toggle();
    final key = WmHistory.keyOf(r);
    final updated = r.copyWith(pinned: !r.pinned);
    await WmHistory.updateByKey(key, pinned: updated.pinned);
    if (!mounted) return;
    final reduce = _reduceMotion(context);
    if (!reduce) {
      setState(() => _removing.add(key));
      await Future.delayed(const Duration(milliseconds: 180));
    }
    if (!mounted) return;
    setState(() {
      _records.removeWhere((e) => WmHistory.keyOf(e) == key);
      final newIdx = _pinInsertIndex(updated);
      _records.insert(newIdx, updated);
      _removing.remove(key);
      _enteringKey = key;
    });
    if (!reduce) {
      await Future.delayed(const Duration(milliseconds: 260));
      if (mounted) setState(() => _enteringKey = null);
    }
  }

  /// a 是否应排在 rec 之前（ts 倒序，等 ts 按 seq 倒序 —— 与存储排序一致）。
  bool _before(WmRecord a, WmRecord b) =>
      a.ts > b.ts || (a.ts == b.ts && a.seq > b.seq);

  /// 计算 [rec]（已带新 pinned 状态）应插入的排序位置。
  int _pinInsertIndex(WmRecord rec) {
    var idx = 0;
    if (rec.pinned) {
      // 置顶组：按 (ts, seq) 倒序
      while (idx < _records.length &&
          _records[idx].pinned &&
          _before(_records[idx], rec)) {
        idx++;
      }
    } else {
      // 普通组：越过全部置顶，再按 (ts, seq) 倒序
      while (idx < _records.length && _records[idx].pinned) {
        idx++;
      }
      while (idx < _records.length &&
          !_records[idx].pinned &&
          _before(_records[idx], rec)) {
        idx++;
      }
    }
    return idx;
  }

  Future<void> _deleteOne(WmRecord r) async {
    await WmHistory.removeByKey(WmHistory.keyOf(r));
    Haptics.delete();
    await _removeRowsAnimated({WmHistory.keyOf(r)});
  }

  Future<void> _openArchived() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const _ArchivedPage()),
    );
    _reload();
  }

  /// 单行渲染：入场错峰（Interval）+ 移除淡出 + 置顶目标位淡入。
  Widget _buildRow(int index, WmRecord r) {
    final key = WmHistory.keyOf(r);
    final n = _records.length;
    final curve = CurvedAnimation(
      parent: _entrance,
      curve: Interval(
        n <= 1 ? 0 : index / n,
        n <= 1 ? 1 : (index + 1) / n,
        curve: _enterCurve,
      ),
    );
    Widget row = _RecordTile(
      rec: r,
      selectionMode: _selectionMode,
      selected: _selected.contains(key),
      onTap: _selectionMode ? () => _toggleSelect(r) : null,
      onLongPress: () => _enterSelection(r),
      onPin: () => _togglePin(r),
      onArchive: () => _archiveOne(r),
      onDelete: () => _deleteOne(r),
    );
    if (_removing.contains(key)) {
      row = TweenAnimationBuilder<double>(
        tween: Tween(begin: 1, end: 0),
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeIn,
        builder: (_, v, child) => Opacity(opacity: v, child: child),
        child: row,
      );
    } else if (key == _enteringKey) {
      row = TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 220),
        curve: _enterCurve,
        builder: (_, v, child) => Opacity(opacity: v, child: child),
        child: row,
      );
    }
    return FadeTransition(
      opacity: curve,
      child: SlideTransition(
        position:
            Tween(begin: const Offset(0, 0.06), end: Offset.zero).animate(curve),
        child: row,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final reduce = _reduceMotion(context);
    // 多选模式下系统返回键优先退出多选（而非退出 App）。
    return PopScope(
      canPop: !_selectionMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selectionMode) _exitSelection();
      },
      child: SafeArea(
        // 下拉刷新：重新加载本机记录（含刚嵌入的）。
        child: RefreshIndicator(
          onRefresh: _reload,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(16),
            children: [
          // 标题行 ⇄ 多选操作栏（从顶部滑入 + 淡入）
          AnimatedSwitcher(
            duration:
                reduce ? Duration.zero : const Duration(milliseconds: 220),
            switchInCurve: _enterCurve,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position:
                    Tween(begin: const Offset(0, -0.25), end: Offset.zero)
                        .animate(animation),
                child: child,
              ),
            ),
            child: _selectionMode
                ? _SelectionBar(
                    key: const ValueKey('selbar'),
                    count: _selected.length,
                    total: _records.length,
                    onClose: _exitSelection,
                    onToggleAll: _toggleSelectAll,
                    onArchive: _batchArchive,
                    onDelete: _batchDelete,
                  )
                : PageHeader(
                    key: const ValueKey('header'),
                    icon: Icons.history,
                    title: '嵌入记录',
                    subtitle:
                        '共 ${_records.length} 条 · 置顶在前，最新在前 · 长按可多选',
                  ),
          ),
          const SizedBox(height: 12),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_records.isEmpty && !_selectionMode)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    Icon(Icons.history, size: 40, color: cs.outline),
                    const SizedBox(height: 8),
                    Text(
                      '暂无嵌入记录\n嵌入水印后会自动保存在这里',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            )
          else
            for (var i = 0; i < _records.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _buildRow(i, _records[i]),
              ),
          const SizedBox(height: 8),
          // 已归档入口（置底；多选时隐藏）
          AnimatedSwitcher(
            duration:
                reduce ? Duration.zero : const Duration(milliseconds: 200),
            child: _selectionMode
                ? const SizedBox.shrink()
                : Card(
                    key: const ValueKey('arch-entry'),
                    margin: EdgeInsets.zero,
                    child: ListTile(
                      leading: Icon(Icons.archive_outlined,
                          color: cs.onSurfaceVariant),
                      title: const Text('已归档'),
                      trailing: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 150),
                        child: Text(
                          '$_archivedCount 条 ›',
                          key: ValueKey(_archivedCount),
                          style: TextStyle(
                              color: cs.onSurfaceVariant, fontSize: 13),
                        ),
                      ),
                      onTap: _openArchived,
                    ),
                  ),
          ),
        ],
        ),
        ),
      ),
    );
  }
}

/// 多选操作栏：关闭 / 已选 N 条 / 全选 / 批量操作（默认归档橙 / 删除红；
/// [archiveMode] 下为取消归档绿）。
class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    super.key,
    required this.count,
    required this.total,
    required this.onClose,
    required this.onToggleAll,
    required this.onArchive,
    required this.onDelete,
    this.archiveMode = false,
  });

  final int count;
  final int total;
  final bool archiveMode;
  final VoidCallback onClose;
  final VoidCallback onToggleAll;
  final VoidCallback onArchive;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final allSelected = count == total && total > 0;
    return Material(
      color: cs.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          children: [
            IconButton(
              tooltip: '退出多选',
              icon: const Icon(Icons.close),
              onPressed: onClose,
            ),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 150),
              child: Text('已选 $count 条',
                  key: ValueKey(count),
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            const Spacer(),
            IconButton(
              tooltip: allSelected ? '取消全选' : '全选',
              icon: Icon(allSelected ? Icons.deselect : Icons.select_all),
              onPressed: onToggleAll,
            ),
            IconButton(
              tooltip: archiveMode ? '取消归档选中' : '归档选中',
              icon: Icon(
                archiveMode ? Icons.unarchive_outlined : Icons.archive_outlined,
                color: archiveMode
                    ? const Color(0xFF43A047)
                    : const Color(0xFFFB8C00),
              ),
              onPressed: count == 0 ? null : onArchive,
            ),
            IconButton(
              tooltip: '删除选中',
              icon: const Icon(Icons.delete_outline,
                  color: Color(0xFFE53935)),
              onPressed: count == 0 ? null : onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

/// 单条记录行：左滑三按钮（删除红/归档橙/置顶蓝，QQ 风格）；
/// 长按进入多选（勾选图标弹出、选中底色渐变）；多选时禁用滑动。
class _RecordTile extends StatelessWidget {
  const _RecordTile({
    required this.rec,
    required this.selectionMode,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    required this.onPin,
    required this.onArchive,
    required this.onDelete,
    this.dimmed = false,
    this.archivedMode = false,
  });

  final WmRecord rec;
  final bool selectionMode;
  final bool selected;
  final bool dimmed;
  /// 归档页模式：左滑只显示「取消归档（绿）/ 删除（红）」两个按钮。
  final bool archivedMode;
  final VoidCallback? onTap;
  final VoidCallback onLongPress;
  final VoidCallback onPin;
  final VoidCallback onArchive;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final reduce = _reduceMotion(context);
    final dur = reduce ? Duration.zero : const Duration(milliseconds: 180);

    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // 勾选图标槽位：宽度随多选状态平滑变化，图标缩放淡入
        AnimatedContainer(
          duration: dur,
          curve: Curves.easeOutCubic,
          width: selectionMode ? 36 : 0,
          child: AnimatedSwitcher(
            duration: dur,
            transitionBuilder: (child, animation) => ScaleTransition(
              scale: Tween(begin: 0.7, end: 1.0).animate(animation),
              child: FadeTransition(opacity: animation, child: child),
            ),
            child: selectionMode
                ? Icon(
                    selected
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    key: ValueKey(selected),
                    size: 22,
                    color: selected ? cs.primary : cs.outlineVariant,
                  )
                : const SizedBox.shrink(),
          ),
        ),
        Expanded(child: _RecordCard(rec: rec, dimmed: dimmed)),
      ],
    );

    // 选中底色渐变
    final surface = AnimatedContainer(
      duration: dur,
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: selected
            ? cs.primaryContainer.withValues(alpha: 0.45)
            : cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: row,
    );

    if (selectionMode) {
      return InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: surface,
      );
    }
    return GestureDetector(
      onLongPress: onLongPress,
      child: Slidable(
        key: ValueKey(WmHistory.keyOf(rec)),
        endActionPane: ActionPane(
          motion: const DrawerMotion(),
          extentRatio: archivedMode ? 0.5 : 0.72,
          children: archivedMode
              ? [
                  // 归档页：取消归档（绿）/ 删除（红）
                  SlidableAction(
                    onPressed: (_) => onArchive(),
                    backgroundColor: const Color(0xFF43A047),
                    foregroundColor: Colors.white,
                    icon: Icons.unarchive_outlined,
                    label: '取消归档',
                  ),
                  SlidableAction(
                    onPressed: (_) => onDelete(),
                    backgroundColor: const Color(0xFFE53935),
                    foregroundColor: Colors.white,
                    icon: Icons.delete_outline,
                    label: '删除',
                  ),
                ]
              : [
                  // 主列表：置顶（蓝）/ 归档（橙）/ 删除（红）
                  SlidableAction(
                    onPressed: (_) => onPin(),
                    backgroundColor: const Color(0xFF1E88E5),
                    foregroundColor: Colors.white,
                    icon: rec.pinned ? Icons.push_pin_outlined : Icons.push_pin,
                    label: rec.pinned ? '取消置顶' : '置顶',
                  ),
                  SlidableAction(
                    onPressed: (_) => onArchive(),
                    backgroundColor: const Color(0xFFFB8C00),
                    foregroundColor: Colors.white,
                    icon: Icons.archive_outlined,
                    label: '归档',
                  ),
                  SlidableAction(
                    onPressed: (_) => onDelete(),
                    backgroundColor: const Color(0xFFE53935),
                    foregroundColor: Colors.white,
                    icon: Icons.delete_outline,
                    label: '删除',
                  ),
                ],
        ),
        child: surface,
      ),
    );
  }
}

/// 已归档二级页：置灰列表，左滑两按钮（取消归档绿/删除红）；
/// 长按多选可批量取消归档/删除。
class _ArchivedPage extends StatefulWidget {
  const _ArchivedPage();

  @override
  State<_ArchivedPage> createState() => _ArchivedPageState();
}

class _ArchivedPageState extends State<_ArchivedPage>
    with SingleTickerProviderStateMixin {
  List<WmRecord> _records = [];
  bool _loading = true;
  bool _selectionMode = false;
  final Set<String> _selected = {};
  final Set<String> _removing = {};

  late final AnimationController _entrance;

  @override
  void initState() {
    super.initState();
    // 二级页 push 后立即可见，直接播放入场。
    _entrance = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 360));
    _entrance.forward();
    Future.delayed(const Duration(milliseconds: 420), () {
      if (mounted && !_entrance.isCompleted) {
        _entrance.value = 1;
      }
    });
    _reload();
  }

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final recs = await WmHistory.archived();
    if (!mounted) return;
    setState(() {
      _records = recs;
      _loading = false;
      _selectionMode = false;
      _selected.clear();
      _removing.clear();
    });
  }

  void _enterSelection(WmRecord r) {
    Haptics.longPress();
    setState(() {
      _selectionMode = true;
      _selected.add(WmHistory.keyOf(r));
    });
  }

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selected.clear();
    });
  }

  void _toggleSelect(WmRecord r) {
    Haptics.select();
    final k = WmHistory.keyOf(r);
    setState(() {
      if (!_selected.remove(k)) _selected.add(k);
    });
  }

  void _toggleSelectAll() {
    Haptics.select();
    setState(() {
      if (_selected.length == _records.length) {
        _selected.clear();
      } else {
        _selected.addAll(_records.map(WmHistory.keyOf));
      }
    });
  }

  Future<void> _removeRowsAnimated(Set<String> keys) async {
    final reduce = _reduceMotion(context);
    if (!reduce) {
      setState(() => _removing.addAll(keys));
      await Future.delayed(const Duration(milliseconds: 200));
    }
    if (!mounted) return;
    setState(() {
      _records.removeWhere((r) => keys.contains(WmHistory.keyOf(r)));
      _removing.removeAll(keys);
    });
  }

  Future<void> _batchRestore() async {
    final keys = Set<String>.from(_selected);
    for (final k in keys) {
      await WmHistory.updateByKey(k, archived: false);
    }
    Haptics.archive();
    _exitSelection();
    await _removeRowsAnimated(keys);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('已取消归档 ${keys.length} 条'),
            duration: const Duration(seconds: 2)),
      );
    }
  }

  Future<void> _batchDelete() async {
    final keys = Set<String>.from(_selected);
    final removed = _records
        .where((r) => keys.contains(WmHistory.keyOf(r)))
        .toList();
    for (final k in keys) {
      await WmHistory.removeByKey(k);
    }
    Haptics.delete();
    _exitSelection();
    await _removeRowsAnimated(keys);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已删除 ${keys.length} 条'),
          duration: const Duration(seconds: 2),
          action: SnackBarAction(
            label: '撤销',
            onPressed: () async {
              for (final r in removed) {
                await WmHistory.add(r);
              }
              _reload();
            },
          ),
        ),
      );
    }
  }

  Future<void> _restoreOne(WmRecord r) async {
    await WmHistory.updateByKey(WmHistory.keyOf(r), archived: false);
    Haptics.archive();
    await _removeRowsAnimated({WmHistory.keyOf(r)});
  }

  Future<void> _deleteOne(WmRecord r) async {
    await WmHistory.removeByKey(WmHistory.keyOf(r));
    Haptics.delete();
    await _removeRowsAnimated({WmHistory.keyOf(r)});
  }

  Widget _buildRow(int index, WmRecord r) {
    final key = WmHistory.keyOf(r);
    final n = _records.length;
    final curve = CurvedAnimation(
      parent: _entrance,
      curve: Interval(
        n <= 1 ? 0 : index / n,
        n <= 1 ? 1 : (index + 1) / n,
        curve: _enterCurve,
      ),
    );
    Widget row = _RecordTile(
      rec: r,
      selectionMode: _selectionMode,
      selected: _selected.contains(key),
      dimmed: true,
      archivedMode: true,
      onTap: _selectionMode ? () => _toggleSelect(r) : null,
      onLongPress: () => _enterSelection(r),
      onPin: () {},
      onArchive: () => _restoreOne(r),
      onDelete: () => _deleteOne(r),
    );
    if (_removing.contains(key)) {
      row = TweenAnimationBuilder<double>(
        tween: Tween(begin: 1, end: 0),
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeIn,
        builder: (_, v, child) => Opacity(opacity: v, child: child),
        child: row,
      );
    }
    return FadeTransition(
      opacity: curve,
      child: SlideTransition(
        position:
            Tween(begin: const Offset(0, 0.06), end: Offset.zero).animate(curve),
        child: row,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final reduce = _reduceMotion(context);
    // 多选模式下系统返回键优先退出多选；AppBar 返回键同步变为关闭键。
    return PopScope(
      canPop: !_selectionMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selectionMode) _exitSelection();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('已归档'),
          automaticallyImplyLeading: !_selectionMode,
          leading: _selectionMode
              ? IconButton(
                  tooltip: '退出多选',
                  icon: const Icon(Icons.close),
                  onPressed: _exitSelection,
                )
              : null,
        ),
        body: SafeArea(
          child: RefreshIndicator(
            onRefresh: _reload,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              children: [
            AnimatedSwitcher(
              duration:
                  reduce ? Duration.zero : const Duration(milliseconds: 220),
              switchInCurve: _enterCurve,
              switchOutCurve: Curves.easeIn,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween(begin: const Offset(0, -0.25), end: Offset.zero)
                      .animate(animation),
                  child: child,
                ),
              ),
              child: _selectionMode
                  ? _SelectionBar(
                      key: const ValueKey('selbar'),
                      count: _selected.length,
                      total: _records.length,
                      archiveMode: true,
                      onClose: _exitSelection,
                      onToggleAll: _toggleSelectAll,
                      onArchive: _batchRestore,
                      onDelete: _batchDelete,
                    )
                  : Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '已归档记录不参与自动提取匹配 · 长按可多选',
                        key: const ValueKey('hint'),
                        style:
                            TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                      ),
                    ),
            ),
            const SizedBox(height: 12),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_records.isEmpty)
              Padding(
                padding: const EdgeInsets.all(32),
                child: Center(
                  child: Text('暂无已归档记录',
                      style: TextStyle(color: cs.onSurfaceVariant)),
                ),
              )
            else
              for (var i = 0; i < _records.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _buildRow(i, _records[i]),
                ),
          ],
        ),
        ),
        ),
      ),
    );
  }
}

/// 记录卡片：徽章 + 内容 + 32 位码（可复制）+ 时间 + 密码。
class _RecordCard extends StatelessWidget {
  const _RecordCard({required this.rec, this.dimmed = false});

  final WmRecord rec;
  final bool dimmed;

  String _fmtTs(int ts) {
    if (ts <= 0) return '未知时间';
    final dt = DateTime.fromMillisecondsSinceEpoch(ts);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}';
  }

  (String, Color) _badge(ColorScheme cs) {
    switch (rec.kind) {
      case 'wam':
        return ('强鲁棒', cs.primaryContainer);
      case 'text':
        return ('文本', cs.tertiaryContainer);
      default:
        return ('Logo', cs.secondaryContainer);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (badge, badgeBg) = _badge(cs);
    final op = dimmed ? 0.55 : 1.0;
    return Opacity(
      opacity: op,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: badgeBg,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(badge,
                      style: TextStyle(
                          fontSize: 11,
                          color: cs.onPrimaryContainer,
                          fontWeight: FontWeight.w600)),
                ),
                if (rec.pinned) ...[
                  const SizedBox(width: 6),
                  Icon(Icons.push_pin, size: 14, color: cs.primary),
                ],
                const Spacer(),
                Text(_fmtTs(rec.ts),
                    style:
                        TextStyle(color: cs.onSurfaceVariant, fontSize: 11)),
              ],
            ),
            const SizedBox(height: 6),
            if (rec.text != null && rec.text!.isNotEmpty) ...[
              Text(rec.text!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 15)),
              const SizedBox(height: 2),
            ],
            if (rec.kind == 'wam' && rec.code != null)
              Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      '标识码：${rec.code}',
                      style: const TextStyle(
                          fontSize: 12,
                          letterSpacing: 1,
                          fontFamily: 'monospace'),
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: '复制标识码',
                    icon: const Icon(Icons.copy, size: 16),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: rec.code!));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text('标识码已复制'),
                            duration: Duration(seconds: 1)),
                      );
                    },
                  ),
                ],
              )
            else if (rec.kind == 'text' && rec.len != null)
              Text('长度 ${rec.len} bit',
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12))
            else if (rec.kind == 'logo' && rec.w != null && rec.h != null)
              Text('Logo 尺寸 ${rec.w}×${rec.h}',
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
            Text('密码 ${rec.pw}',
                style: TextStyle(color: cs.outline, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}
