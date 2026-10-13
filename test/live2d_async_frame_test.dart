import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_live2d/tsukuyomi_live2d.dart';
import 'package:tsukuyomi_space_app/live2d/live2d_scene_controller.dart';

class _Clock implements TickerProvider {
  late TickerCallback frame;
  @override
  Ticker createTicker(TickerCallback onTick) {
    frame = onTick;
    return Ticker(onTick);
  }
}

class _Model extends Live2DModel {
  _Model(this.textures);
  @override
  final List<ui.Image> textures;
  @override
  final meshes = List.generate(
    12,
    (i) => LiveMesh(
      positions: Float32List.fromList([0, 0, 10, 0, 10, 10, 0, 10]),
      uvs: Float32List.fromList([0, 0, 1, 0, 1, 1, 0, 1]),
      indices: Uint16List.fromList([0, 1, 2, 0, 2, 3]),
      texture: 0,
      order: i,
      flags: 4,
      visible: true,
      opacity: 1,
      masks: [],
      multiply: [1, 1, 1, 1],
      screen: [0, 0, 0, 0],
      staticTopology: true,
      geometryRevision: 0,
    ),
  );
  @override
  Rect get bounds => const Rect.fromLTRB(0, -10, 10, 0);
  @override
  List<String> get expressions => [];
  @override
  double get updateMilliseconds => 0;
  @override
  void tick(
    double seconds,
    double delta, {
    double mouth = 0,
    double lookX = 0,
    double lookY = 0,
    String expression = 'neutral',
  }) {
    for (final mesh in meshes) {
      mesh.positions[0] = seconds;
      mesh.geometryRevision = mesh.geometryRevision! + 1;
    }
    notifyListeners();
  }
}

void paint(Live2DPainter painter, [Size size = const Size(128, 128)]) {
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), size);
  recorder.endRecording().dispose();
}

Future<void> settle(Live2DPainter painter) async {
  // A completed frame may start one coalesced successor automatically.
  for (var i = 0; i < 3; i++) {
    await painter.pendingRasterization;
  }
}

void main() {
  testWidgets('interaction yields model work and retains the completed frame', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(Colors.white, BlendMode.src);
      final picture = recorder.endRecording();
      final texture = await picture.toImage(16, 16);
      picture.dispose();
      final model = _Model([texture]), clock = _Clock();
      final scene = Live2DSceneController(
        vsync: clock,
        mobile: true,
        onTick: (seconds, delta) => model.tick(seconds, delta),
      )..attach(model);
      final painter = scene.painter!..rasterPixelBudget = 4096;
      scene.active = true;
      try {
        paint(painter);
        await settle(painter);
        final recorded = painter.recordedFrames;
        final completed = painter.completedFrames;
        final discarded = painter.discardedFrames;
        final cached = painter.cachedPaints;
        scene.interacting = true;
        for (var i = 0; i < 60; i++) {
          clock.frame(Duration(milliseconds: 100 + i * 17));
          paint(painter);
        }
        await settle(painter);
        expect(painter.recordedFrames, recorded);
        expect(painter.completedFrames, completed);
        expect(painter.discardedFrames, discarded);
        expect(painter.cachedPaints, cached + 60);
        scene.interacting = false;
        clock.frame(const Duration(hours: 3));
        clock.frame(const Duration(hours: 3, milliseconds: 34));
        await settle(painter);
        expect(painter.recordedFrames, recorded + 1);
        expect(painter.completedFrames, completed + 1);
        expect(painter.discardedFrames, discarded);
      } finally {
        final pending = painter.pendingRasterization;
        scene.dispose();
        await pending;
        texture.dispose();
      }
    });
  });
  testWidgets(
    'paused visible scene refreshes its frozen pixels after fullscreen resize',
    (tester) async {
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawColor(Colors.white, BlendMode.src);
        final picture = recorder.endRecording();
        final texture = await picture.toImage(16, 16);
        picture.dispose();
        final model = _Model([texture]);
        final painter = Live2DPainter(model, asynchronousRasterization: true)
          ..rasterPixelBudget = 4096;
        Future<int> alpha(Size size) async {
          paint(painter, size);
          await settle(painter);
          // A visible repaint can replace an invalidated pending viewport.
          paint(painter, size);
          await settle(painter);
          final recorder = ui.PictureRecorder();
          painter.paint(Canvas(recorder), size);
          final picture = recorder.endRecording();
          final image = await picture.toImage(
            size.width.toInt(),
            size.height.toInt(),
          );
          try {
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!;
            final index =
                ((size.height ~/ 2) * size.width.toInt() + size.width ~/ 2) * 4;
            return bytes.getUint8(index + 3);
          } finally {
            image.dispose();
            picture.dispose();
          }
        }

        try {
          expect(await alpha(const Size(128, 128)), 255);
          painter.renderingEnabled = false;
          expect(await alpha(const Size(256, 128)), 255);
          final recorded = painter.recordedFrames;
          for (var i = 0; i < 60; i++) {
            paint(painter, const Size(256, 128));
          }
          expect(painter.recordedFrames, recorded);
          expect(painter.rasterFailures, 0);
        } finally {
          painter.dispose();
          model.dispose();
          texture.dispose();
        }
      });
    },
  );

  testWidgets(
    'pausing before initial raster completes still presents one static frame',
    (tester) async {
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawColor(Colors.white, BlendMode.src);
        final picture = recorder.endRecording();
        final texture = await picture.toImage(16, 16);
        picture.dispose();
        final model = _Model([texture]);
        final painter = Live2DPainter(model, asynchronousRasterization: true)
          ..rasterPixelBudget = 4096;
        try {
          paint(painter);
          painter.renderingEnabled = false;
          await settle(painter);
          paint(painter, const Size(256, 128));
          await settle(painter);
          final cached = painter.cachedPaints;
          paint(painter, const Size(256, 128));
          expect(painter.cachedPaints, cached + 1);
          expect(painter.rasterFailures, 0);
        } finally {
          painter.dispose();
          model.dispose();
          texture.dispose();
        }
      });
    },
  );

  testWidgets(
    'scene waits for pending raster work and resumes without a time jump',
    (tester) async {
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawColor(Colors.white, BlendMode.src);
        final picture = recorder.endRecording();
        final texture = await picture.toImage(16, 16);
        picture.dispose();
        final clock = _Clock(), deltas = <double>[];
        final model = _Model([texture]);
        final scene = Live2DSceneController(
          vsync: clock,
          mobile: true,
          onTick: (seconds, delta) {
            deltas.add(delta);
            model.tick(seconds, delta);
          },
        )..attach(model);
        final painter = scene.painter!..rasterPixelBudget = 4096;
        scene.active = true;
        try {
          paint(painter);
          clock.frame(Duration.zero);
          clock.frame(const Duration(milliseconds: 34));
          expect(deltas, isEmpty);
          await settle(painter);
          clock.frame(const Duration(milliseconds: 67));
          clock.frame(const Duration(milliseconds: 101));
          clock.frame(const Duration(milliseconds: 135));
          expect(deltas, [.034]);
          await settle(painter);
          scene.active = false;
          scene.active = true;
          clock.frame(const Duration(hours: 3));
          clock.frame(const Duration(hours: 3, milliseconds: 34));
          expect(deltas, [.034, .034]);
        } finally {
          final pending = painter.pendingRasterization;
          scene.dispose();
          await pending;
          texture.dispose();
        }
      });
    },
  );
  testWidgets(
    'async pipeline coalesces updates, reuses paints and cancels stale work',
    (tester) async {
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawColor(Colors.white, BlendMode.src);
        final picture = recorder.endRecording();
        final texture = await picture.toImage(16, 16);
        picture.dispose();
        final model = _Model([texture]);
        final painter = Live2DPainter(model, asynchronousRasterization: true)
          ..rasterPixelBudget = 4096;
        try {
          paint(painter);
          await settle(painter);
          expect(painter.recordedFrames, 1);
          expect(painter.asyncRasterizations, 1);
          expect(painter.completedFrames, 1);
          expect(painter.discardedFrames, 0);
          expect(painter.lastRasterizationMicros, greaterThan(0));
          for (var i = 0; i < 120; i++) {
            paint(painter);
          }
          expect(painter.cachedPaints, 120);
          expect(painter.recordedFrames, 1);
          expect(painter.asyncRasterizations, 1);
          for (var i = 0; i < 60; i++) {
            model.tick(i / 60, 1 / 60);
          }
          expect(painter.recordedFrames, 2);
          await settle(painter);
          expect(painter.recordedFrames, 3);
          expect(painter.completedFrames, 3);
          painter.renderingEnabled = false;
          model.tick(2, 1 / 30);
          await settle(painter);
          expect(painter.recordedFrames, 3);
          painter.renderingEnabled = true;
          paint(painter);
          await settle(painter);
          expect(painter.recordedFrames, 4);
          model.tick(3, 1 / 30);
          // Resize invalidates that in-flight frame, and queues only the latest size.
          paint(painter, const Size(256, 128));
          await settle(painter);
          final records = painter.recordedFrames;
          paint(painter, const Size(256, 128));
          expect(painter.recordedFrames, records);
          model.tick(4, 1 / 30);
          final pending = painter.pendingRasterization;
          painter.dispose();
          await pending;
          expect(painter.rasterFailures, 0);
        } finally {
          painter.dispose();
          model.dispose();
          texture.dispose();
        }
      });
    },
  );
}
