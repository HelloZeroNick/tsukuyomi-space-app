import 'dart:io';

import 'package:flutter/widgets.dart';

import 'probe_android_gpu.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await probeAndroidGpu();
    // Let queued native disposal finish before terminating the QA process.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(0);
  } catch (error, stack) {
    // ignore: avoid_print
    print('TSUKUYOMI_LIVE2D_GPU_FAILED $error\n$stack');
    exit(1);
  }
}
