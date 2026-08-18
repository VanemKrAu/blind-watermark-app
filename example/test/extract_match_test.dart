import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_blind_watermark_example/pages/extract_page.dart';
import 'package:flutter_blind_watermark_example/src/wam_codec.dart';

void main() {
  WmRecord text(int len, {int cw = 512, int ch = 512, int ts = 1000}) =>
      WmRecord(kind: 'text', text: 't', len: len, pw: 1, cw: cw, ch: ch, ts: ts);

  WmRecord logo(int w, int h, {int cw = 512, int ch = 512, int ts = 1000}) =>
      WmRecord(kind: 'logo', w: w, h: h, pw: 1, cw: cw, ch: ch, ts: ts);

  group('capacityOk 容量硬预筛（零误伤）', () {
    test('文本 bit 数在容量内 → 可试', () {
      // 512×512 → cap 4096
      expect(capacityOk(text(4096)), isTrue);
      expect(capacityOk(text(3000)), isTrue);
    });

    test('文本 bit 数超容量 → 数学上不可能，跳过', () {
      expect(capacityOk(text(4097)), isFalse);
      expect(capacityOk(text(8000)), isFalse);
    });

    test('Logo 像素数超容量 → 跳过', () {
      expect(capacityOk(logo(64, 64)), isTrue); // 4096 ≤ 4096
      expect(capacityOk(logo(70, 70)), isFalse); // 4900 > 4096
    });

    test('参数无效（无长度/尺寸）→ 跳过', () {
      expect(capacityOk(WmRecord(kind: 'text', text: 't')), isFalse);
      expect(capacityOk(WmRecord(kind: 'logo')), isFalse);
    });

    test('载体尺寸未知（旧记录 cw/ch=0）→ 不预筛，放行', () {
      expect(capacityOk(text(10000, cw: 0, ch: 0)), isTrue);
      expect(capacityOk(logo(200, 200, cw: 0, ch: 0)), isTrue);
    });

    test('载体尺寸非法（>8192）→ 不预筛，放行（防篡改防御在 resync 侧）', () {
      expect(capacityOk(text(99999, cw: 9000, ch: 9000)), isTrue);
    });
  });

  group('rankedBySize 尺寸匹配排序（零误伤，只调顺序）', () {
    const src = (512, 512);

    test('尺寸相同排最前，组内时间倒序', () {
      final recs = rankedBySize([
        text(100, cw: 800, ch: 600, ts: 3000), // 不同尺寸，较新
        text(100, cw: 512, ch: 512, ts: 1000), // 相同尺寸，较旧
        text(100, cw: 512, ch: 512, ts: 2000), // 相同尺寸，较新
        text(100, cw: 640, ch: 480, ts: 500), // 不同尺寸，较旧
      ], src);
      expect(recs.map((e) => e.ts), [2000, 1000, 3000, 500]);
    });

    test('尺寸未知记录与不同尺寸同组，不误伤', () {
      final recs = rankedBySize([
        text(100, cw: 0, ch: 0, ts: 4000),
        text(100, cw: 512, ch: 512, ts: 1000),
      ], src);
      expect(recs.first.ts, 1000); // 尺寸相同仍优先
      expect(recs.length, 2); // 未知尺寸记录保留，不被丢弃
    });

    test('排序不改动记录集合（无跳过）', () {
      final recs = [text(100, cw: 800, ch: 600), text(100, cw: 512, ch: 512)];
      final out = rankedBySize(recs, src);
      expect(out.length, recs.length);
      expect(out.toSet(), recs.toSet());
    });
  });

  group('recBitsMatch 记录原文校验（容错 2 位，拒绝假文本）', () {
    List<int> encode(String text) {
      final hex = utf8
          .encode(text)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      return BigInt.parse(hex, radix: 16)
          .toRadixString(2)
          .split('')
          .map((c) => c == '1' ? 1 : 0)
          .toList();
    }

    test('真文本：提取 bit 与记录原文编码一致 → 通过', () {
      final bits = encode('Hello DWT 2026 test');
      expect(recBitsMatch('Hello DWT 2026 test', bits), isTrue);
      final cn = encode('盲水印DWT闭环测试-2026');
      expect(recBitsMatch('盲水印DWT闭环测试-2026', cn), isTrue);
    });

    test('容错：JPEG 轻损 1~2 bit 错 → 通过', () {
      final bits = encode('Hello DWT 2026 test');
      bits[5] ^= 1;
      expect(recBitsMatch('Hello DWT 2026 test', bits), isTrue);
      bits[30] ^= 1;
      expect(recBitsMatch('Hello DWT 2026 test', bits), isTrue);
    });

    test('3 bit 错 → 拒绝（超出容错）', () {
      final bits = encode('Hello DWT 2026 test');
      bits[5] ^= 1;
      bits[30] ^= 1;
      bits[60] ^= 1;
      expect(recBitsMatch('Hello DWT 2026 test', bits), isFalse);
    });

    test('假文本：随机位流与固定文本编码差异巨大 → 拒绝', () {
      final recBits = encode('Hello DWT 2026 test');
      final random = List<int>.generate(recBits.length, (i) => i % 3 == 0 ? 1 : 0);
      expect(recBitsMatch('Hello DWT 2026 test', random), isFalse);
    });

    test('另一段文本的编码 → 拒绝', () {
      final bits = encode('另一个完全不同的文本内容');
      expect(recBitsMatch('Hello DWT 2026 test', bits), isFalse);
    });

    test('长度不同 → 拒绝', () {
      final bits = encode('short');
      expect(recBitsMatch('Hello DWT 2026 test', bits), isFalse);
    });
  });
}
