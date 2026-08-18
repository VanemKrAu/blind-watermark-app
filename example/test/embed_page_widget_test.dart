import 'package:flutter/material.dart';
import 'package:flutter_blind_watermark_example/pages/embed_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpEmbed(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: EmbedPage())));
    await tester.pumpAndSettle();
  }

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('文本模式默认强鲁棒（WAM），方案选择器可见', (tester) async {
    await pumpEmbed(tester);
    expect(find.text('强鲁棒（WAM）'), findsOneWidget);
    expect(find.text('经典（DWT）'), findsOneWidget);
    expect(
      find.textContaining('强鲁棒（默认）：任意图幅、抗裁剪/旋转/压缩'),
      findsOneWidget,
    );
  });

  testWidgets('切换到经典 DWT 后说明文案与选择状态变化', (tester) async {
    await pumpEmbed(tester);
    await tapVisible(tester, find.text('经典（DWT）'));
    expect(
      find.textContaining('经典 DWT：密码 + 长度即可在任何设备还原完整文本'),
      findsOneWidget,
    );
  });

  testWidgets('切回强鲁棒后说明文案恢复', (tester) async {
    await pumpEmbed(tester);
    await tapVisible(tester, find.text('经典（DWT）'));
    await tapVisible(tester, find.text('强鲁棒（WAM）'));
    expect(
      find.textContaining('强鲁棒（默认）：任意图幅、抗裁剪/旋转/压缩'),
      findsOneWidget,
    );
  });

  testWidgets('Logo 模式不显示方案选择器', (tester) async {
    await pumpEmbed(tester);
    await tapVisible(tester, find.text('Logo'));
    expect(find.text('强鲁棒（WAM）'), findsNothing);
    expect(find.text('经典（DWT）'), findsNothing);
  });

  testWidgets('窄屏（360dp）无溢出异常', (tester) async {
    tester.view.physicalSize = const Size(360 * 3, 800 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await pumpEmbed(tester);
    expect(tester.takeException(), isNull);
    await tapVisible(tester, find.text('经典（DWT）'));
    expect(tester.takeException(), isNull);
  });
}
