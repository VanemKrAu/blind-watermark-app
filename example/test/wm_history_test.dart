import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_blind_watermark_example/src/wam_codec.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  WmRecord wam(String code, {String text = '测试', int ts = 1000}) => WmRecord(
      kind: 'wam', text: text, code: code, pw: 1, ts: ts);

  test('add 后 active 按时间倒序，最新在前', () async {
    await WmHistory.add(wam('A', ts: 1000));
    await WmHistory.add(wam('B', ts: 2000));
    final list = await WmHistory.active();
    expect(list.map((e) => e.code), ['B', 'A']);
  });

  test('keyOf 去重：同 code 重复 add 只保留最新', () async {
    await WmHistory.add(wam('A', text: '旧', ts: 1000));
    await WmHistory.add(wam('A', text: '新', ts: 2000));
    final list = await WmHistory.active();
    expect(list.length, 1);
    expect(list.first.text, '新');
  });

  test('重新嵌入保留置顶状态，且不改写归档状态', () async {
    await WmHistory.add(wam('A', ts: 1000));
    await WmHistory.updateByKey('wam:A', pinned: true);
    await WmHistory.add(wam('A', text: '重嵌', ts: 2000));
    final list = await WmHistory.active();
    expect(list.length, 1);
    expect(list.first.text, '重嵌');
    expect(list.first.pinned, isTrue); // 置顶保留
    expect(list.first.archived, isFalse);

    // 归档页撤销删除：add 携带 archived=true 应保持归档
    await WmHistory.updateByKey('wam:A', archived: true);
    final archRec = (await WmHistory.archived()).first;
    await WmHistory.add(archRec);
    expect((await WmHistory.archived()).length, 1); // 仍为归档
    expect(await WmHistory.active(), isEmpty);
  });

  test('置顶排序：置顶组在前，组内按时间倒序', () async {
    await WmHistory.add(wam('A', ts: 1000));
    await WmHistory.add(wam('B', ts: 2000));
    await WmHistory.add(wam('C', ts: 3000));
    await WmHistory.updateByKey('wam:A', pinned: true);
    final list = await WmHistory.active();
    expect(list.map((e) => e.code), ['A', 'C', 'B']);
  });

  test('取消置顶回到时间序', () async {
    await WmHistory.add(wam('A', ts: 1000));
    await WmHistory.add(wam('B', ts: 2000));
    await WmHistory.updateByKey('wam:A', pinned: true);
    await WmHistory.updateByKey('wam:A', pinned: false);
    final list = await WmHistory.active();
    expect(list.map((e) => e.code), ['B', 'A']);
  });

  test('归档后 active 不含、archived 含、不参与 matchWam', () async {
    await WmHistory.add(wam('AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', ts: 1000));
    await WmHistory.updateByKey(
        'wam:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', archived: true);
    expect(await WmHistory.active(), isEmpty);
    expect((await WmHistory.archived()).length, 1);
    final match = await WmHistory.matchWam(
        'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'.split('').map((c) => c == 'A' ? 1 : 0).toList(),
        4);
    expect(match, isNull);
  });

  test('未归档记录正常参与 matchWam', () async {
    final code = '10101010101010101010101010101010';
    await WmHistory.add(wam(code, text: '你好', ts: 1000));
    final bits = code.split('').map((c) => c == '1' ? 1 : 0).toList();
    final match = await WmHistory.matchWam(bits, 4);
    expect(match, isNotNull);
    expect(match!.$1.text, '你好');
    expect(match.$2, 0);
  });

  test('removeByKey 删除记录', () async {
    await WmHistory.add(wam('A', ts: 1000));
    await WmHistory.removeByKey('wam:A');
    expect(await WmHistory.active(), isEmpty);
  });

  test('旧记录（无 ts/pinned/archived 字段）兼容反序列化', () async {
    SharedPreferences.setMockInitialValues({
      'wm_history':
          '[{"kind":"wam","text":"旧格式","code":"1111000011110000","pw":1}]',
    });
    final list = await WmHistory.active();
    expect(list.length, 1);
    expect(list.first.ts, 0); // 旧记录 ts=0 → 显示"未知时间"
    expect(list.first.pinned, isFalse);
    expect(list.first.archived, isFalse);
  });

  test('置顶再取消置顶：回到时间倒序位置（复刻页面 _pinInsertIndex 逻辑）', () async {
    // 直接注入真实时间戳（add() 会覆盖 ts 为 now，无法用于排序测试）
    SharedPreferences.setMockInitialValues({
      'wm_history': jsonEncode([
        {'kind': 'wam', 'code': 'A', 'text': 'a', 'pw': 1, 'ts': 3000},
        {'kind': 'wam', 'code': 'B', 'text': 'b', 'pw': 1, 'ts': 2000},
        {'kind': 'wam', 'code': 'C', 'text': 'c', 'pw': 1, 'ts': 1000},
      ]),
    });

    // 页面内逻辑：移除该记录后，按 (置顶在前, ts 倒序, seq 倒序) 计算插入位置
    int insertIndex(List<WmRecord> list, WmRecord rec) {
      bool before(WmRecord a, WmRecord b) =>
          a.ts > b.ts || (a.ts == b.ts && a.seq > b.seq);
      var idx = 0;
      if (rec.pinned) {
        while (idx < list.length && list[idx].pinned && before(list[idx], rec)) {
          idx++;
        }
      } else {
        while (idx < list.length && list[idx].pinned) {
          idx++;
        }
        while (idx < list.length && !list[idx].pinned && before(list[idx], rec)) {
          idx++;
        }
      }
      return idx;
    }

    // 时间倒序：A 最新、C 最旧
    var list = await WmHistory.active();
    expect(list.map((e) => e.code), ['A', 'B', 'C']);

    // 置顶 C（最旧）
    await WmHistory.updateByKey('wam:C', pinned: true);
    list = await WmHistory.active();
    expect(list.map((e) => e.code), ['C', 'A', 'B']);

    // 页面内取消置顶模拟
    final c = list.firstWhere((e) => e.code == 'C');
    final updated = c.copyWith(pinned: false);
    list.removeWhere((e) => e.code == 'C');
    list.insert(insertIndex(list, updated), updated);

    // 页面内结果应回到原位置（末尾）
    expect(list.map((e) => e.code), ['A', 'B', 'C']);
    // 持久化取消置顶后重载，应与页面内一致
    await WmHistory.updateByKey('wam:C', pinned: false);
    final reloaded = await WmHistory.active();
    expect(reloaded.map((e) => e.code), list.map((e) => e.code).toList());
  });

  test('置顶取消置顶：旧记录（ts=0）回到原相对位置（seq 迁移保证确定性）', () async {
    // 旧格式：无 ts/seq 字段（等 ts 场景）
    SharedPreferences.setMockInitialValues({
      'wm_history': jsonEncode([
        {'kind': 'wam', 'code': 'OLD1', 'text': 'o1', 'pw': 1},
        {'kind': 'wam', 'code': 'OLD2', 'text': 'o2', 'pw': 1},
        {'kind': 'wam', 'code': 'OLD3', 'text': 'o3', 'pw': 1},
      ]),
    });

    int insertIndex(List<WmRecord> list, WmRecord rec) {
      bool before(WmRecord a, WmRecord b) =>
          a.ts > b.ts || (a.ts == b.ts && a.seq > b.seq);
      var idx = 0;
      if (rec.pinned) {
        while (idx < list.length && list[idx].pinned && before(list[idx], rec)) {
          idx++;
        }
      } else {
        while (idx < list.length && list[idx].pinned) {
          idx++;
        }
        while (idx < list.length && !list[idx].pinned && before(list[idx], rec)) {
          idx++;
        }
      }
      return idx;
    }

    // seq 迁移：按存储顺序补发 → 顺序确定（OLD1 最旧）
    var list = await WmHistory.active();
    expect(list.map((e) => e.code), ['OLD3', 'OLD2', 'OLD1']);

    // 置顶 OLD2 再取消置顶（页面内模拟）
    await WmHistory.updateByKey('wam:OLD2', pinned: true);
    list = await WmHistory.active();
    expect(list.map((e) => e.code), ['OLD2', 'OLD3', 'OLD1']);
    final c = list.firstWhere((e) => e.code == 'OLD2');
    final updated = c.copyWith(pinned: false);
    list.removeWhere((e) => e.code == 'OLD2');
    list.insert(insertIndex(list, updated), updated);

    // 应回到原相对位置（OLD2 在 OLD3 之后、OLD1 之前）
    expect(list.map((e) => e.code), ['OLD3', 'OLD2', 'OLD1'],
        reason: '旧记录取消置顶应回到原相对位置');
    // 持久化取消置顶后重载，应与页面内一致
    await WmHistory.updateByKey('wam:OLD2', pinned: false);
    final reloaded = await WmHistory.active();
    expect(reloaded.map((e) => e.code), list.map((e) => e.code).toList());
  });
}
