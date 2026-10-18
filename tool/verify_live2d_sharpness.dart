// Native GPU still-image comparison, not a physical mobile performance test.
// flutter run --profile -d macos -t tool/verify_live2d_sharpness.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:tsukuyomi_live2d/tsukuyomi_live2d.dart';
import 'package:tsukuyomi_space_app/live2d/live2d_scene_controller.dart';

import '../test/support/live2d_render_probe.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('Checking character detail…'))),
    ),
  );
  const label = String.fromEnvironment('CLARITY_LABEL', defaultValue: 'after');
  final output = Directory(
    '${Directory.systemTemp.path}/tsukuyomi-sharpness-$label',
  );
  await output.create(recursive: true);
  final captures = <Map<String, dynamic>>[];
  final models = <Live2DModel>[];
  var passed = false;
  try {
    final detail = await probeLive2DCroppedDetail();
    final auto = await loadLive2D(
      maxTextureSize: const bool.hasEnvironment('CLARITY_TEXTURE_SIZE')
          ? const int.fromEnvironment('CLARITY_TEXTURE_SIZE')
          : Live2DSceneController.textureLimitFor('auto'),
    );
    models.add(auto);
    final full = await loadLive2D(
      maxTextureSize:
          0, // Original-size reference, bypassing every texture cap.
    );
    models.add(full);
    final economy = await loadLive2D(
      maxTextureSize: Live2DSceneController.textureLimitFor('economy'),
    );
    models.add(economy);
    for (final scenario in [
      (name: 'mobile', size: const Size(585, 760), dpr: 3.0, mobile: true),
      (name: 'desktop', size: const Size(730, 685), dpr: 2.0, mobile: false),
      (
        name: 'fullscreen',
        size: const Size(2074, 929),
        dpr: 2.0,
        mobile: false,
      ),
    ]) {
      Uint8List? reference;
      for (final mode in ['full', 'auto', 'economy']) {
        final model = switch (mode) {
          'full' => full,
          'economy' => economy,
          _ => auto,
        };
        final painter = Live2DPainter(model)
          ..pixelRatio = scenario.dpr
          ..rasterPixelBudget =
              mode == 'auto' &&
                  scenario.mobile &&
                  const bool.hasEnvironment('CLARITY_MOBILE_BUDGET')
              ? const int.fromEnvironment('CLARITY_MOBILE_BUDGET')
              : mode == 'full'
              ? 0
              : Live2DSceneController.rasterBudgetFor(
                  mode,
                  mobile: scenario.mobile,
                );
        try {
          final recorder = ui.PictureRecorder();
          painter.paint(Canvas(recorder)..scale(scenario.dpr), scenario.size);
          final picture = recorder.endRecording();
          final image = await picture.toImage(
            (scenario.size.width * scenario.dpr).round(),
            (scenario.size.height * scenario.dpr).round(),
          );
          picture.dispose();
          try {
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!.buffer.asUint8List();
            if (mode == 'full') reference = bytes;
            var error = 0, samples = 0;
            // Include alpha differences and only the actual reference character.
            for (var i = 0; i < bytes.length; i += 4) {
              if (reference![i + 3] < 128) continue;
              for (var channel = 0; channel < 4; channel++) {
                error += (reference[i + channel] - bytes[i + channel]).abs();
                samples++;
              }
            }
            final png = (await image.toByteData(
              format: ui.ImageByteFormat.png,
            ))!;
            await File('${output.path}/${scenario.name}-$mode.png')
                .writeAsBytes(png.buffer.asUint8List());
            captures.add({
              'scenario': scenario.name,
              'mode': mode,
              'viewport': {
                'width': scenario.size.width,
                'height': scenario.size.height,
                'dpr': scenario.dpr,
              },
              'mean_absolute_rgba_error_to_original': error / samples,
              'bounded_passes': painter.boundedPasses,
              'downsampled_passes': painter.downsampledPasses,
              'rasterized_pixels': painter.rasterizedPixels,
              'pixel_budget': painter.rasterPixelBudget,
              'decoded_rgba_bytes': model.textures.fold<int>(
                0,
                (sum, t) => sum + t.width * t.height * 4,
              ),
            });
          } finally {
            image.dispose();
          }
        } finally {
          painter.dispose();
        }
      }
    }
    final asyncNative = await probeNativeLive2DAsync(
      auto,
      rasterPixelBudget: Live2DSceneController.rasterBudgetFor(
        'auto',
        mobile: true,
      ),
      pixelRatio: 3,
    );
    passed =
        detail['different_bytes'] == 0 &&
        detail['after'][3] == 0 &&
        asyncNative['max_channel_delta'] <= 2 &&
        asyncNative['raster_failures'] == 0;
    await File('${output.path}/results.json').writeAsString(
      '${const JsonEncoder.withIndent('  ').convert({'label': label, 'passed': passed, 'detail_probe': detail, 'async_native': asyncNative, 'captures': captures})}\n',
    );
  } finally {
    for (final model in models) {
      model.dispose();
    }
  }
  // ignore: avoid_print
  print('TSUKUYOMI_SHARPNESS_${passed ? 'OK' : 'FAILED'} ${output.path}');
  runApp(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SelectableText(
            'Character detail: ${passed ? 'PASS' : 'FAIL'}\n${output.path}',
          ),
        ),
      ),
    ),
  );
}
