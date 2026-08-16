import 'package:flutter/material.dart';

import 'wam_bridge.dart';

/// The WAM models are bundled in the APK, so the strong-robust mode is always
/// ready. Kept as a guard: returns false only if the models are somehow
/// missing (e.g. a corrupted install).
Future<bool> ensureWamModels(BuildContext context) async {
  return WamBridge.modelReady();
}
