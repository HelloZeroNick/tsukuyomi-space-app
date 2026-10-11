import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_live2d/tsukuyomi_live2d.dart';
import 'package:tsukuyomi_space_app/core/desktop_window.dart';
import 'package:tsukuyomi_space_app/live2d/character_stage.dart';
import 'package:tsukuyomi_space_app/live2d/live2d_scene_controller.dart';

import 'support/fakes.dart';

class _Clock implements TickerProvider {
  late TickerCallback frame;
  @override
  Ticker createTicker(TickerCallback onTick) {
    frame = onTick;
    return Ticker(onTick);
  }
}

class _Model extends Live2DModel {
  int ticks = 0;
  @override
  List<ui.Image> get textures => [];
  @override
  List<LiveMesh> get meshes => [];
  @override
  Rect get bounds => const Rect.fromLTWH(0, 0, 1, 1);
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
    ticks++;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final refresh in [60, 90, 120, 144]) {
    for (final mobile in [false, true]) {
      test('clock keeps ${mobile ? 30 : 60} fps on $refresh Hz display', () {
        final clock = _Clock(), deltas = <double>[];
        final scene = Live2DSceneController(
          vsync: clock,
          mobile: mobile,
          onTick: (_, delta) => deltas.add(delta),
        );
        addTearDown(scene.dispose);
        for (var i = 0; i <= refresh * 2; i++) {
          clock.frame(Duration(microseconds: (i * 1000000 / refresh).round()));
        }
        expect(deltas.length, closeTo(mobile ? 60 : 120, 2));
        expect(deltas.every((v) => v > 0 && v <= .05), true);
      });
    }
  }

  test('quality, frame limit and pixel ratio survive loading and resume', () {
    final clock = _Clock(), deltas = <double>[];
    final scene = Live2DSceneController(
      vsync: clock,
      mobile: false,
      onTick: (_, delta) => deltas.add(delta),
    );
    addTearDown(scene.dispose);
    scene.configure(quality: 'economy', frameLimit: 30, pixelRatio: 2);
    scene.attach(_Model());
    expect(scene.painter!.rasterPixelBudget, 450000);
    expect(scene.painter!.pixelRatio, 2);
    expect(scene.fps, 30);
    scene.active = true;
    clock.frame(Duration.zero);
    clock.frame(const Duration(milliseconds: 34));
    scene.active = false;
    scene.active = true;
    clock.frame(const Duration(hours: 1));
    clock.frame(const Duration(hours: 1, milliseconds: 34));
    expect(deltas, [.034, .034]);
    scene.configure(quality: 'full');
    expect(scene.painter!.rasterPixelBudget, 0);
  });

  testWidgets('desktop minimization suspends the Room model and restores it', (
    tester,
  ) async {
    final window = DesktopWindowController(
      supported: true,
      read: () async => false,
      set: (_) async {},
    );
    addTearDown(window.dispose);
    final model = _Model();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DesktopWindowScope(
            controller: window,
            child: CharacterStage(
              voice: SilentVoice(),
              modelLoader: () async => model,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 17));
    }
    expect(model.ticks, greaterThan(0));
    window.onWindowMinimize();
    await tester.pump();
    final before = model.ticks;
    await tester.pump(const Duration(seconds: 30));
    expect(model.ticks, before);
    window.onWindowRestore();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 34));
    expect(model.ticks, greaterThan(before));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
