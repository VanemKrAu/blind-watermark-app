import 'package:flutter/material.dart';

import 'pages/embed_page.dart';
import 'pages/extract_page.dart';

void main() {
  runApp(const BlindWatermarkApp());
}

class BlindWatermarkApp extends StatelessWidget {
  const BlindWatermarkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '盲水印',
      debugShowCheckedModeBanner: false,
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
    // Motion spec (Material 3 fade-through):
    //   enter:  fade-in + scale 0.96->1, easeOutCubic, 280ms
    //   exit:   quick fade-out, easeIn, 150ms
    //   reduced motion: instant swap.
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final duration =
        reduce ? Duration.zero : const Duration(milliseconds: 280);
    final exitDuration =
        reduce ? Duration.zero : const Duration(milliseconds: 150);
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: visible ? duration : exitDuration,
        curve: visible ? Curves.easeOutCubic : Curves.easeIn,
        child: AnimatedScale(
          scale: visible ? 1 : 0.96,
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
