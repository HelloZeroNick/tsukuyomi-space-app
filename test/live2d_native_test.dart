import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_live2d/tsukuyomi_live2d.dart';
import 'package:tsukuyomi_space_app/live2d/live2d_scene_controller.dart';

import 'support/live2d_render_probe.dart';

void main() {
  testWidgets(
    'real model async snapshots match reference and reuse cached paints',
    (tester) async {
      final model = (await tester.runAsync(
        () => loadLive2D(
          maxTextureSize: Live2DSceneController.textureLimitFor('auto'),
        ),
      ))!;
      try {
        final result = (await tester.runAsync(
          () => probeNativeLive2DAsync(
            model,
            rasterPixelBudget: Live2DSceneController.rasterBudgetFor(
              'auto',
              mobile: true,
            ),
            pixelRatio: 3,
          ),
        ))!;
        expect(result['max_channel_delta'], lessThanOrEqualTo(2));
        expect(result['raster_failures'], 0);
        for (final timing
            in (result['cache_record_timings'] as List).cast<Map>()) {
          expect(timing['extra_model_records'], 0);
          expect(timing['extra_rasterizations'], 0);
        }
        await tester.runAsync(() async {
          final output = File('artifacts/performance/live2d-async-pixels.json');
          await output.parent.create(recursive: true);
          await output.writeAsString(
            '${const JsonEncoder.withIndent('  ').convert(result)}\n',
          );
        });
      } finally {
        model.dispose();
      }
    },
    skip: !const bool.fromEnvironment('RUN_CUBISM_TESTS'),
  );
  testWidgets('real Cubism model deforms and renders with native physics', (
    tester,
  ) async {
    final model = await tester.runAsync(() => loadLive2D());
    expect(model, isNotNull);
    final scene = model!;
    try {
      expect(scene.meshes.length, greaterThan(100));
      expect(
        scene.textures.every((t) => t.width <= 2048 && t.height <= 2048),
        true,
      );
      final before = scene.meshes.expand((m) => m.positions).toList();
      final meshes = List.of(scene.meshes);
      final revisions = scene.meshes.map((m) => m.geometryRevision).toList();
      scene.tick(1, 1 / 60, mouth: .8, lookX: .6, expression: 'smile');
      for (var i = 0; i < meshes.length; i++) {
        expect(identical(scene.meshes[i], meshes[i]), true);
      }
      expect(
        scene.meshes.map((m) => m.geometryRevision).toList(),
        isNot(equals(revisions)),
      );
      expect(
        scene.meshes.expand((m) => m.positions).toList(),
        isNot(equals(before)),
      );
      final batching = (await tester.runAsync(
        () => probeNativeLive2DBatching(scene),
      ))!;
      expect(batching['max_channel_delta'], lessThanOrEqualTo(2));
      for (final run in (batching['runs'] as List).cast<Map>()) {
        expect(run['batch_calls'], lessThan(run['direct_calls'] as int));
        expect(run['batched_meshes'], greaterThan(0));
      }
      await tester.runAsync(() async {
        final output = File('artifacts/performance/live2d-batch-pixels.json');
        await output.parent.create(recursive: true);
        await output.writeAsString(
          '${const JsonEncoder.withIndent('  ').convert(batching)}\n',
        );
      });
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawColor(const Color(0xff13192b), BlendMode.src);
        final painter = Live2DPainter(scene)
          ..pixelRatio = 2
          ..rasterPixelBudget = 450000;
        painter.paint(canvas, const Size(720, 960));
        expect(painter.boundedPasses, greaterThan(0));
        final picture = recorder.endRecording();
        final image = await picture.toImage(720, 960);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final output = File('artifacts/native-live2d.png');
        await output.parent.create(recursive: true);
        await output.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
        picture.dispose();
        painter.dispose();
      });
    } finally {
      scene.dispose();
    }
  }, skip: !const bool.fromEnvironment('RUN_CUBISM_TESTS'));
  testWidgets('detail priority decodes original 4096 textures', (tester) async {
    final model = (await tester.runAsync(
      () => loadLive2D(
        maxTextureSize: Live2DSceneController.textureLimitFor('full'),
      ),
    ))!;
    try {
      expect(
        model.textures.every((t) => t.width == 4096 && t.height == 4096),
        true,
      );
    } finally {
      model.dispose();
    }
  }, skip: !const bool.fromEnvironment('RUN_CUBISM_TESTS'));
  testWidgets(
    'default character quality uses 3K atlases and 72 MiB on both platforms',
    (tester) async {
      final model = (await tester.runAsync(
        () => loadLive2D(
          maxTextureSize: Live2DSceneController.textureLimitFor('auto'),
        ),
      ))!;
      try {
        expect(
          model.textures.every((t) => t.width == 3072 && t.height == 3072),
          true,
        );
        expect(
          model.textures.fold<int>(
            0,
            (total, t) => total + t.width * t.height * 4,
          ),
          72 * 1024 * 1024,
        );
      } finally {
        model.dispose();
      }
    },
    skip: !const bool.fromEnvironment('RUN_CUBISM_TESTS'),
  );
}
