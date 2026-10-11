import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tsukuyomi_live2d/tsukuyomi_live2d.dart';
import 'package:tsukuyomi_space_app/features/game/kaguya_audio.dart';
import 'package:tsukuyomi_space_app/features/game/kaguya_assets.dart';
import 'package:tsukuyomi_space_app/live2d/live2d_scene_controller.dart';

import 'package:tsukuyomi_space_app/core/app_update_installer.dart';

import '../test/support/live2d_render_probe.dart';
import '../test/support/kaguya_riding_probe.dart';

// Run this release entrypoint on devices, not only with the host test runner.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    if (Platform.isAndroid) {
      const updates = MethodChannel('space.tsukuyomi/app_update');
      final abis = await updates.invokeListMethod<String>('supportedAbis');
      if (abis == null || abis.isEmpty) {
        throw StateError('Missing native update ABI');
      }
      final installed = await InstalledApp.load();
      final cache = await getApplicationCacheDirectory();
      final outside = await File('${cache.path}/outside-update.apk')
          .writeAsString('not an APK');
      final root = await Directory('${cache.path}/tsukuyomi-updates').create();
      final invalid = await File('${root.path}/invalid.apk')
          .writeAsString('not an APK');
      try {
        for (final (path, expected) in [
          (outside.path, 'storage'),
          (invalid.path, 'package'),
        ]) {
          try {
            await updates.invokeMethod('install', {'path': path});
            throw StateError('Unsafe update was not blocked');
          } on PlatformException catch (e) {
            if (e.code != expected) rethrow;
          }
        }
      } finally {
        await outside.delete();
        await invalid.delete();
      }
      // ignore: avoid_print
      print(
        'TSUKUYOMI_UPDATE_OK abis=$abis platform=${installed.platform.name} version=${installed.version.value} private-cache=$cache',
      );
    }
    final model = await loadLive2D(
      maxTextureSize: Live2DSceneController.textureLimitFor('auto'),
    );
    if (model.meshes.length < 10 || model.textures.isEmpty) {
      throw StateError('Cubism returned an empty model');
    }
    final painter = Live2DPainter(model)
      ..rasterPixelBudget = Live2DSceneController.rasterBudgetFor(
        'auto',
        mobile: true,
      )
      ..pixelRatio = WidgetsBinding
          .instance
          .platformDispatcher
          .views
          .first
          .devicePixelRatio;
    runApp(
      MaterialApp(
        home: Scaffold(
          body: CustomPaint(painter: painter, size: const Size(390, 800)),
        ),
      ),
    );
    if (Platform.isAndroid || Platform.isIOS) {
      final music = KaguyaPlayerVoice(), effect = KaguyaPlayerVoice();
      try {
        await music
            .playAsset('game/e799e693821d6133a07ef791ed2b1616.wav', 0)
            .timeout(const Duration(seconds: 20));
        await effect
            .playAsset('game/9ff5abe1a6e774272a0be10461f4f1a4.wav', 0)
            .timeout(const Duration(seconds: 20));
        await Future<void>.delayed(const Duration(milliseconds: 350));
        if (!music.playing) throw StateError('An effect interrupted game BGM');
        await music.pause();
        await music.resume();
        if (!music.playing) throw StateError('Game BGM did not resume');
        // ignore: avoid_print
        print('TSUKUYOMI_GAME_AUDIO_OK BGM+SFX mixed, pause/resume verified');
      } finally {
        await effect.dispose();
        await music.dispose();
      }
    }
    await Future<void>.delayed(const Duration(seconds: 2));
    final bounded = await probeLive2DBoundedPasses();
    final uvs = await probeLive2DShaderUvs();
    final detail = await probeLive2DCroppedDetail();
    if (detail['different_bytes'] != 0 ||
        detail['after'][3] != 0 ||
        model.textures.any((t) => t.width != 3072 || t.height != 3072)) {
      throw StateError('Native character detail mismatch: $detail');
    }
    // ignore: avoid_print
    print(
      'TSUKUYOMI_LIVE2D_DETAIL_OK 3072px atlases, narrow viewport detail and deformed crop verified',
    );
    for (var pixel = 0; pixel < 4; pixel++) {
      for (var channel = 0; channel < 4; channel++) {
        if ((uvs['shader']![pixel][channel] - uvs['image']![pixel][channel])
                .abs() >
            2) {
          throw StateError('Native shader UV/alpha mismatch: $uvs');
        }
      }
    }
    for (final entry in bounded.entries) {
      final value = entry.value as Map;
      if (value['passes'] < 1 ||
          List.generate(
            4,
            (i) => (value['direct'][i] - value['bounded'][i]).abs() > 2,
          ).any((v) => v)) {
        throw StateError(
          'Native bounded rendering mismatch: ${entry.key} $value',
        );
      }
      if (entry.key == 'tint' &&
          List.generate(
            4,
            (i) => (value['bounded'][i] - [50, 74, 73, 255][i]).abs() > 2,
          ).any((v) => v)) {
        throw StateError(
          'Native tint did not match its expected colors: $value',
        );
      }
    }
    // ignore: avoid_print
    print(
      'TSUKUYOMI_LIVE2D_RENDER_OK bounded masks/tints/destination blends verified',
    );
    final gameAssets = await KaguyaAssets.load();
    final game = gameAssets.runtime(random: math.Random(7));
    try {
      final result = await probeKaguyaRidingPixels(game, gameAssets);
      // ignore: avoid_print
      print('TSUKUYOMI_GAME_RIDING_OK $result');
    } finally {
      game.dispose();
      gameAssets.dispose();
    }
    final frames = <FrameTiming>[];
    void record(List<FrameTiming> batch) => frames.addAll(batch);
    SchedulerBinding.instance.addTimingsCallback(record);
    for (var i = 0; i < 120; i++) {
      model.tick(i / 30, 1 / 30, mouth: (i % 30) / 30);
      await Future<void>.delayed(const Duration(milliseconds: 34));
    }
    SchedulerBinding.instance.removeTimingsCallback(record);
    double p95(Iterable<int> data) {
      final sorted = data.toList()..sort();
      return sorted.isEmpty
          ? 0
          : sorted[((sorted.length - 1) * .95).round()] / 1000;
    }

    // Emulator timing is diagnostic; real phone performance requires a profile
    // run on that device, not a threshold inferred from CI hardware.
    // ignore: avoid_print
    print(
      'TSUKUYOMI_LIVE2D_TIMINGS frames=${frames.length} ui_p95_ms=${p95(frames.map((f) => f.buildDuration.inMicroseconds))} raster_p95_ms=${p95(frames.map((f) => f.rasterDuration.inMicroseconds))} bounded_passes=${painter.boundedPasses} pixels=${painter.rasterizedPixels}',
    );
    // ignore: avoid_print
    print(
      'TSUKUYOMI_LIVE2D_OK meshes=${model.meshes.length} textures=${model.textures.length}',
    );
  } catch (e, st) {
    // ignore: avoid_print
    print('TSUKUYOMI_LIVE2D_FAILED $e\n$st');
    exit(1);
  }
}
