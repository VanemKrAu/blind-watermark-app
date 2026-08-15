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

  const WmRecord({
    required this.kind,
    this.text,
    this.code,
    this.len,
    this.w,
    this.h,
    this.pw = 1,
  });

  Map<String, dynamic> toJson() => {
        'kind': kind,
        if (text != null) 'text': text,
        if (code != null) 'code': code,
        if (len != null) 'len': len,
        if (w != null) 'w': w,
        if (h != null) 'h': h,
        'pw': pw,
      };

  static WmRecord fromJson(Map<String, dynamic> e) => WmRecord(
        kind: e['kind'] as String? ?? 'text',
        text: e['text'] as String?,
        code: e['code'] as String?,
        len: e['len'] as int?,
        w: e['w'] as int?,
        h: e['h'] as int?,
        pw: e['pw'] as int? ?? 1,
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

  static Future<List<WmRecord>> all() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => WmRecord.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> add(WmRecord rec) async {
    final prefs = await SharedPreferences.getInstance();
    final list = await all();
    list.removeWhere((e) =>
        (rec.kind == 'wam' && e.kind == 'wam' && e.code == rec.code) ||
        (rec.kind == 'text' && e.kind == 'text' && e.text == rec.text) ||
        (rec.kind == 'logo' && e.kind == 'logo' && e.w == rec.w && e.h == rec.h));
    list.insert(0, rec);
    if (list.length > 100) list.removeRange(100, list.length);
    await prefs.setString(_key, jsonEncode(list.map((e) => e.toJson()).toList()));
  }

  /// Find the closest WAM record within [maxErrors] bit errors.
  static Future<(WmRecord, int)?> matchWam(List<int> extracted, int maxErrors) async {
    final list = await all();
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
