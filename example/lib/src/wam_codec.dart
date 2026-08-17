import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// CRC32 (standard, reflected) -> 32-bit code from arbitrary text.
/// Keeps the 32-bit WAM capacity while letting users type readable text.
class WamCodec {
  static const _poly = 0xEDB88320;

  static int crc32(List<int> bytes) {
    var crc = 0xFFFFFFFF;
    for (final b in bytes) {
      crc ^= b;
      for (var i = 0; i < 8; i++) {
        crc = (crc & 1) != 0 ? (crc >> 1) ^ _poly : crc >> 1;
      }
    }
    return crc ^ 0xFFFFFFFF;
  }

  /// 32 bits (0/1) from a text.
  static List<int> textToBits(String text) {
    final crc = crc32(utf8.encode(text));
    return List<int>.generate(32, (i) => (crc >> (31 - i)) & 1);
  }

  static String bitsToStr(List<int> bits) =>
      bits.map((b) => b > 0 ? '1' : '0').join();

  /// Hamming distance between two bit lists.
  static int hamming(List<int> a, List<int> b) {
    final n = a.length < b.length ? a.length : b.length;
    var d = 0;
    for (var i = 0; i < n; i++) {
      if (a[i] != b[i]) d++;
    }
    return d;
  }
}

/// A record of one embed operation, used to auto-extract without parameters.
class WmRecord {
  final String kind; // 'wam' | 'text' | 'logo'
  final String? text; // user text (wam / text)
  final String? code; // 32-bit code string (wam)
  final int? len; // DWT bit length (text)
  final int? w; // logo width (logo)
  final int? h; // logo height (logo)
  final int pw; // DWT seed derived from the user password
  final int ts; // embed time (ms since epoch); 0 = legacy record (unknown)
  final int seq; // 单调递增序号：排序决胜键（等 ts 时按 seq 倒序，保证确定性）
  final int cw; // 载体（水印图）宽度：提取时用于「还原回原尺寸」再同步网格
  final int ch; // 载体（水印图）高度：提取时用于「还原回原尺寸」再同步网格
  final bool pinned; // pinned to the top of the records list
  final bool archived; // hidden from the main list; not used in matching

  const WmRecord({
    required this.kind,
    this.text,
    this.code,
    this.len,
    this.w,
    this.h,
    this.pw = 1,
    this.ts = 0,
    this.seq = 0,
    this.cw = 0,
    this.ch = 0,
    this.pinned = false,
    this.archived = false,
  });

  Map<String, dynamic> toJson() => {
        'kind': kind,
        if (text != null) 'text': text,
        if (code != null) 'code': code,
        if (len != null) 'len': len,
        if (w != null) 'w': w,
        if (h != null) 'h': h,
        'pw': pw,
        if (ts != 0) 'ts': ts,
        if (seq != 0) 'seq': seq,
        if (cw != 0) 'cw': cw,
        if (ch != 0) 'ch': ch,
        if (pinned) 'pinned': true,
        if (archived) 'archived': true,
      };

  static WmRecord fromJson(Map<String, dynamic> e) => WmRecord(
        kind: e['kind'] as String? ?? 'text',
        text: e['text'] as String?,
        code: e['code'] as String?,
        len: e['len'] as int?,
        w: e['w'] as int?,
        h: e['h'] as int?,
        pw: e['pw'] as int? ?? 1,
        ts: e['ts'] as int? ?? 0,
        seq: e['seq'] as int? ?? 0,
        cw: e['cw'] as int? ?? 0,
        ch: e['ch'] as int? ?? 0,
        pinned: e['pinned'] as bool? ?? false,
        archived: e['archived'] as bool? ?? false,
      );

  WmRecord copyWith({int? ts, int? seq, bool? pinned, bool? archived}) =>
      WmRecord(
        kind: kind,
        text: text,
        code: code,
        len: len,
        w: w,
        h: h,
        pw: pw,
        ts: ts ?? this.ts,
        seq: seq ?? this.seq,
        cw: cw,
        ch: ch,
        pinned: pinned ?? this.pinned,
        archived: archived ?? this.archived,
      );
}

/// Password helper: the user-visible password maps directly to the DWT
/// seeds. Default is 1 (matches the original Python library); users may
/// choose any integer to protect their watermark.
class WmSecurity {
  /// Both DWT seeds from one password value (default 1).
  /// Clamped to a signed 31-bit range: the FFI takes Int32, and negative or
  /// huge seeds would otherwise break the native call.
  static (int, int) seeds(String password) {
    final s = (int.tryParse(password.trim()) ?? 1) & 0x7FFFFFFF;
    return (s, s);
  }
}

/// Local embed history: lets extraction find the right parameters
/// (bit length / logo size / code) automatically, without user input.
class WmHistory {
  static const _key = 'wm_history';

  /// Composite identity of a record (dedupe / update / delete key).
  static String keyOf(WmRecord r) {
    if (r.kind == 'wam') return 'wam:${r.code}';
    if (r.kind == 'text') return 'text:${r.text}';
    return 'logo:${r.w}x${r.h}';
  }

  static Future<List<WmRecord>> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    List<WmRecord> list;
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      list = decoded
          .map((e) => WmRecord.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      return [];
    }
    // 一次性迁移：旧记录（无 seq 字段）按存储顺序补发递增 seq，
    // 使排序完全确定（旧记录 ts=0，此前等 ts 排序不稳定导致置顶回位错乱）。
    var maxSeq = 0;
    for (final r in list) {
      if (r.seq > maxSeq) maxSeq = r.seq;
    }
    var next = maxSeq + 1;
    var migrated = false;
    for (var i = 0; i < list.length; i++) {
      if (list[i].seq == 0) {
        list[i] = list[i].copyWith(seq: next++);
        migrated = true;
      }
    }
    if (migrated) await _save(prefs, list);
    return list;
  }

  static Future<void> _save(SharedPreferences prefs, List<WmRecord> list) async {
    await prefs.setString(
        _key, jsonEncode(list.map((e) => e.toJson()).toList()));
  }

  /// All records, sorted: pinned first, then time desc (tie: seq desc —
  /// fully deterministic; legacy records keep their stored order).
  static Future<List<WmRecord>> all() async {
    final list = await _load();
    list.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      final t = b.ts.compareTo(a.ts);
      if (t != 0) return t;
      return b.seq.compareTo(a.seq);
    });
    return list;
  }

  /// Non-archived records (the main list; what auto-extraction uses).
  static Future<List<WmRecord>> active() async =>
      (await all()).where((e) => !e.archived).toList();

  /// Archived records only (the archive sub-page).
  static Future<List<WmRecord>> archived() async =>
      (await all()).where((e) => e.archived).toList();

  static Future<void> add(WmRecord rec) async {
    final prefs = await SharedPreferences.getInstance();
    final list = await _load();
    // 重新嵌入同一水印时保留旧记录的置顶/归档状态（dedupe 不丢用户偏好）。
    bool existingPinned = false;
    bool existingArchived = false;
    for (final e in list) {
      if (keyOf(e) == keyOf(rec)) {
        existingPinned = e.pinned;
        existingArchived = e.archived;
        break;
      }
    }
    list.removeWhere((e) => keyOf(e) == keyOf(rec));
    var maxSeq = 0;
    for (final e in list) {
      if (e.seq > maxSeq) maxSeq = e.seq;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    list.insert(
        0,
        WmRecord(
          kind: rec.kind,
          text: rec.text,
          code: rec.code,
          len: rec.len,
          w: rec.w,
          h: rec.h,
          pw: rec.pw,
          ts: now,
          // 撤销删除等恢复场景沿用原 seq（保持原排序位置）；新记录分配递增 seq。
          seq: rec.seq != 0 ? rec.seq : maxSeq + 1,
          cw: rec.cw,
          ch: rec.ch,
          pinned: rec.pinned || existingPinned,
          archived: rec.archived || existingArchived,
        ));
    if (list.length > 100) list.removeRange(100, list.length);
    await _save(prefs, list);
  }

  /// Update pin/archive state of the record identified by [key].
  static Future<void> updateByKey(String key,
      {bool? pinned, bool? archived}) async {
    final prefs = await SharedPreferences.getInstance();
    final list = await _load();
    for (var i = 0; i < list.length; i++) {
      if (keyOf(list[i]) == key) {
        list[i] = list[i].copyWith(
            pinned: pinned ?? list[i].pinned,
            archived: archived ?? list[i].archived);
      }
    }
    await _save(prefs, list);
  }

  static Future<void> removeByKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final list = await _load();
    list.removeWhere((e) => keyOf(e) == key);
    await _save(prefs, list);
  }

  /// Find the closest WAM record within [maxErrors] bit errors.
  /// Archived records are excluded (they no longer auto-match).
  static Future<(WmRecord, int)?> matchWam(
      List<int> extracted, int maxErrors) async {
    final list = await active();
    WmRecord? best;
    var bestD = maxErrors + 1;
    for (final e in list.where((e) => e.kind == 'wam' && e.code != null)) {
      final bits = e.code!.split('').map((c) => c == '1' ? 1 : 0).toList();
      if (bits.length != extracted.length) continue;
      final d = WamCodec.hamming(bits, extracted);
      if (d < bestD) {
        bestD = d;
        best = e;
      }
    }
    if (best == null) return null;
    return (best, bestD);
  }
}
