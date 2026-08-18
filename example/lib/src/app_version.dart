import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// App version read once from the package and cached. Returns e.g. "1.1.16 (19)"
/// (versionName + buildNumber) or '' if unavailable (e.g. in widget tests).
Future<String> _loadVersion() async {
  try {
    final info = await PackageInfo.fromPlatform();
    final v = info.version.trim();
    final b = info.buildNumber.trim();
    if (v.isEmpty) return '';
    return b.isNotEmpty && b != '0' ? '$v ($b)' : v;
  } catch (_) {
    return '';
  }
}

final Future<String> _versionFuture = _loadVersion();

/// Shows the app version from package info (not hardcoded).
class AppVersionText extends StatelessWidget {
  const AppVersionText({super.key, this.style, this.prefix = 'BlindWatermark v'});

  final TextStyle? style;
  final String prefix;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _versionFuture,
      builder: (context, snap) {
        final v = snap.data ?? '';
        return Text(
          v.isEmpty ? '' : '$prefix$v',
          textAlign: TextAlign.center,
          style: style,
        );
      },
    );
  }
}