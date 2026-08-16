import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blind_watermark/src/blind_watermark_bindings.dart';

import 'pages/about_page.dart';
import 'pages/embed_page.dart';
import 'pages/extract_page.dart';
import 'pages/history_page.dart';

final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Native crash capture (MainActivity + blind_watermark_ffi) writes a report
  // on a previous crash; show it in a Material 3 dialog matching the app UI.
  const MethodChannel('wam').setMethodCallHandler((call) async {
    if (call.method == 'onCrashReport') {
      final report = (call.arguments as String?) ?? '';
      if (report.isNotEmpty) {
        final enriched = _enrichReport(report);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _showCrashReport(enriched);
        });
      }
    }
    return null;
  });
  // Tell the native side the handler is registered (crash report delivery).
  try {
    await const MethodChannel('wam').invokeMethod('dartReady');
  } catch (_) {}
  runApp(const BlindWatermarkApp());
}

/// Resolves a crash PC/LR address to "module (symbol)" via dladdr, called in
/// normal context (the signal handler itself only records raw addresses).
String? _symbolize(int address) {
  try {
    final ptr = BlindWatermarkBindings.instance.bwm_symbolize(address);
    if (ptr.address == 0) return null;
    return ptr.toDartString();
  } catch (_) {
    return null;
  }
}

String _enrichReport(String report) {
  final out = <String>[];
  for (final line in report.split('\n')) {
    final m =
        RegExp(r'^(PC|LR|F\d+)=0x([0-9a-fA-F]+)').firstMatch(line);
    if (m != null) {
      final addr = int.tryParse(m.group(2)!, radix: 16) ?? 0;
      final sym = _symbolize(addr);
      out.add('$line  ->  ${sym ?? '?'}');
    } else {
      out.add(line);
    }
  }
  return out.join('\n');
}

Future<void> _showCrashReport(String report) async {
  final context = _navigatorKey.currentContext;
  if (context == null) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('上次运行发生崩溃'),
      content: SingleChildScrollView(
        child: SelectableText(
          report,
          style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: report));
            if (ctx.mounted) Navigator.of(ctx).pop();
          },
          child: const Text('复制报告'),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
  // The report files are deleted only now (dialog dismissed) — a missed
  // dialog on one launch still shows on the next one.
  try {
    await const MethodChannel('wam').invokeMethod('crashReportShown');
  } catch (_) {}
}

class BlindWatermarkApp extends StatelessWidget {
  const BlindWatermarkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '盲水印',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.dark,
        ),
      ),
      themeMode: ThemeMode.system,
      home: const HomeShell(),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  void _goToExtract() => setState(() => _index = 1);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Both pages stay mounted (state preserved); visibility animates.
      body: Stack(
        children: [
          _PageSlot(
            visible: _index == 0,
            child: EmbedPage(onGoExtract: _goToExtract),
          ),
          _PageSlot(
            visible: _index == 1,
            child: const ExtractPage(),
          ),
          _PageSlot(
            visible: _index == 2,
            child: HistoryPage(active: _index == 2),
          ),
          _PageSlot(
            visible: _index == 3,
            child: const AboutPage(),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.upload_outlined),
            selectedIcon: Icon(Icons.upload),
            label: '嵌入水印',
          ),
          NavigationDestination(
            icon: Icon(Icons.search_outlined),
            selectedIcon: Icon(Icons.search),
            label: '提取水印',
          ),
          NavigationDestination(
            icon: Icon(Icons.history_outlined),
            selectedIcon: Icon(Icons.history),
            label: '嵌入记录',
          ),
          NavigationDestination(
            icon: Icon(Icons.info_outline),
            selectedIcon: Icon(Icons.info),
            label: '关于',
          ),
        ],
      ),
    );
  }
}

class _PageSlot extends StatelessWidget {
  const _PageSlot({required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Motion spec: 纯渐隐渐显（整页 scale 会触发大子树逐帧重光栅化 → 掉帧，
    // 故去掉；RepaintBoundary 让 opacity 只做图层合成，不重绘内容）。
    //   enter: fade-in, easeOutCubic, 220ms
    //   exit:  quick fade-out, easeIn, 130ms
    //   reduced motion: instant swap.
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final duration =
        reduce ? Duration.zero : const Duration(milliseconds: 220);
    final exitDuration =
        reduce ? Duration.zero : const Duration(milliseconds: 130);
    return IgnorePointer(
      ignoring: !visible,
      child: RepaintBoundary(
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: visible ? duration : exitDuration,
          curve: visible ? Curves.easeOutCubic : Curves.easeIn,
          child: TickerMode(
            enabled: visible,
            child: child,
          ),
        ),
      ),
    );
  }
}
