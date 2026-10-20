import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tsukuyomi_live2d/tsukuyomi_live2d.dart';
import 'package:tsukuyomi_space_app/live2d/live2d_scene_controller.dart';

class _ProbeClock implements TickerProvider {
  late TickerCallback frame;
  @override
  Ticker createTicker(TickerCallback onTick) {
    frame = onTick;
    return Ticker(onTick);
  }
}

/// Device/CI correctness probe. Software-emulator timings are not performance
/// acceptance. Explicit readback is confined to this probe, never animation.
Future<void> probeAndroidGpu() async {
  final directory = Directory(
    const String.fromEnvironment('NATIVE_GPU_QA_DIR').isNotEmpty
        ? const String.fromEnvironment('NATIVE_GPU_QA_DIR')
        : '${(Platform.isAndroid ? await getExternalStorageDirectory() : await getApplicationSupportDirectory())!.path}/live2d-gpu-qa',
  );
  await directory.create(recursive: true);
  final results = <Map<String, Object>>[];
  Future<Uint8List> capture(GpuLive2DModel model, String name) async {
    final bottomUp = await model.snapshotForTesting();
    final width = model.actualWidth, height = model.actualHeight;
    if (bottomUp.length != width * height * 4) {
      throw StateError('Incomplete GPU frame');
    }
    final pixels = Uint8List(bottomUp.length);
    for (var y = 0; y < height; y++) {
      pixels.setRange(
        y * width * 4,
        (y + 1) * width * 4,
        bottomUp,
        (height - 1 - y) * width * 4,
      );
    }
    var opaque = 0, partial = 0, transparent = 0, hair = 0;
    for (var i = 0; i < pixels.length; i += 4) {
      if (pixels[i + 3] == 0) {
        transparent++;
      } else if (pixels[i + 3] > 240) {
        opaque++;
        if (pixels[i] > 190 && pixels[i + 1] > 190 && pixels[i + 2] > 190) {
          hair++;
        }
      } else {
        partial++;
      }
    }
    final total = width * height;
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      width,
      height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    final image = await completer.future;
    try {
      final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      await File('${directory.path}/$name.png').writeAsBytes(
        png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
      );
    } finally {
      image.dispose();
    }
    if (opaque < total * .03 ||
        transparent < total * .1 ||
        partial < 100 ||
        hair < 100) {
      throw StateError(
        'Invalid GPU alpha/detail: opaque=$opaque transparent=$transparent partial=$partial hair=$hair',
      );
    }
    for (final offset in [
      0,
      (width - 1) * 4,
      (height - 1) * width * 4,
      pixels.length - 4,
    ]) {
      if (pixels[offset + 3] != 0) {
        throw StateError('GPU background is not transparent');
      }
    }
    results.add({
      'pose': name,
      'width': width,
      'height': height,
      'opaque': opaque,
      'partial': partial,
      'transparent': transparent,
      'hair': hair,
      'update_ms': model.updateMilliseconds,
      'submit_ms': model.submitMilliseconds,
      'present_ms': model.presentMilliseconds,
      'roundtrip_ms': model.frameMilliseconds,
    });
    return pixels;
  }

  for (var cycle = 0; cycle < 2; cycle++) {
    final startup = Stopwatch()..start();
    final gpu = await loadLive2D(
      renderer: 'gpu',
      maxTextureSize: 3072,
    ) as GpuLive2DModel;
    try {
      if (Platform.isAndroid && gpu.loadMetrics['shader_source_loads'] != 16) {
        throw StateError(
          'Expected 8 official programs, got ${gpu.loadMetrics}',
        );
      }
      if (gpu.meshCount != 409 || gpu.atlasBytes != 100663280) {
        throw StateError(
          'GPU loaded unexpected model: meshes=${gpu.meshCount}, atlasBytes=${gpu.atlasBytes}',
        );
      }
      runApp(
        MaterialApp(
          home: ColoredBox(
            color: const Color(0xffb7d8d0),
            child: Live2DGpuView(model: gpu, quality: 'auto'),
          ),
        ),
      );
      await WidgetsBinding.instance.endOfFrame;
      await gpu.settled;
      results.add({
        'cycle': cycle,
        'startup': {
          ...gpu.loadMetrics,
          'first_frame_ms': startup.elapsedMicroseconds / 1000,
        },
      });
      // ignore: avoid_print
      print('TSUKUYOMI_GPU_STARTUP cycle=$cycle ${jsonEncode(results.last)}');
      gpu.configureSurface(const Size(390, 800), 2, 'auto');
      await gpu.settled;
      gpu.tick(0, 0);
      await gpu.settled;
      final neutral = await capture(gpu, 'cycle-$cycle-neutral');
      gpu.parameterOverrides = {'ParamEyeLOpen': 0, 'ParamEyeROpen': 0};
      gpu.tick(0, 0, mouth: 1);
      await gpu.settled;
      final expression = await capture(gpu, 'cycle-$cycle-blink-mouth');
      var changed = 0;
      for (var i = 0; i < neutral.length; i++) {
        if ((neutral[i] - expression[i]).abs() > 8) changed++;
      }
      if (changed < 200) {
        throw StateError('GPU pose/voice parameters did not change pixels');
      }
      final frozen = gpu.submittedFrames;
      await Future<void>.delayed(const Duration(milliseconds: 120));
      if (gpu.submittedFrames != frozen) {
        throw StateError('GPU updated while its clock was paused');
      }
      gpu.parameterOverrides = {};
      gpu.configureSurface(const Size(800, 390), 2, 'auto');
      await gpu.settled;
      await capture(gpu, 'cycle-$cycle-landscape');
      // Exercise a different Surface with the same scene and GL resources.
      if (Platform.isAndroid) {
        await const MethodChannel('space.tsukuyomi/live2d_gpu')
            .invokeMethod<void>('recreateSurfaceForTesting', {
              'id': gpu.textureId,
            });
      } else {
        gpu.configureSurface(const Size(390, 800), 2, 'auto');
        await gpu.settled;
      }
      gpu.tick(.1, .016);
      await gpu.settled;
      await capture(gpu, 'cycle-$cycle-recreated-surface');
      if (gpu.failure != null) throw StateError(gpu.failure!);
      // Exercise the production scheduler against real GLES frames while the
      // same activity flag used by Room scrolling stays true throughout.
      final clock = _ProbeClock();
      final controller = Live2DSceneController(
        vsync: clock,
        mobile: true,
        onTick: (seconds, delta) => gpu.tick(seconds, delta),
      );
      controller.attach(gpu);
      controller.active = true;
      controller.interacting = true;
      controller.ticker.stop(); // Drive deterministic timestamps below.
      final beforeInteraction = gpu.submittedFrames;
      for (var frame = 0; frame < 6; frame++) {
        clock.frame(Duration(milliseconds: frame * 34));
        await gpu.settled;
      }
      final interactionFrames = gpu.submittedFrames - beforeInteraction;
      controller.active = false;
      final beforeHidden = gpu.submittedFrames;
      clock.frame(const Duration(seconds: 2));
      await gpu.settled;
      controller.model =
          null; // Keep the probe's model for the remaining checks.
      controller.dispose();
      if (interactionFrames < 4 || gpu.submittedFrames != beforeHidden) {
        throw StateError('GPU interaction/visibility scheduling regression');
      }
      results.add({'cycle': cycle, 'interaction_frames': interactionFrames});
      if (cycle == 1) {
        // Give the CI harness a window to capture Flutter's actual composition.
        gpu.configureSurface(const Size(390, 800), 2, 'auto');
        await gpu.settled;
        // ignore: avoid_print
        print('TSUKUYOMI_GPU_CAPTURE_READY');
        await Future<void>.delayed(const Duration(seconds: 5));
      }
    } finally {
      runApp(const MaterialApp(home: SizedBox.shrink()));
      await WidgetsBinding.instance.endOfFrame;
      gpu.dispose();
    }
  }
  await File('${directory.path}/metrics.json')
      .writeAsString(const JsonEncoder.withIndent('  ').convert(results));
  // ignore: avoid_print
  print(
    'TSUKUYOMI_LIVE2D_GPU_OK direct_surface=true cycles=2 transparent=true pose=true resize=true recreated_surface=${Platform.isAndroid} platform=${Platform.operatingSystem} output=${directory.path}',
  );
}
