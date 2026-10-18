import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_live2d/tsukuyomi_live2d.dart';
import 'package:tsukuyomi_space_app/core/desktop_window.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/live2d/character_stage.dart';
import 'package:tsukuyomi_space_app/live2d/live2d_scene_controller.dart';
import 'package:tsukuyomi_space_app/live2d/room_animation.dart';

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
  final gazes = <Offset>[];
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
    gazes.add(Offset(lookX, lookY));
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  void reportFrames({
    required int rasterMicros,
    int buildMicros = 1000,
    int count = 8,
  }) {
    WidgetsBinding.instance.platformDispatcher.onReportTimings!(
      List.generate(
        count,
        (_) => ui.FrameTiming(
          vsyncStart: 0,
          buildStart: 0,
          buildFinish: buildMicros,
          rasterStart: buildMicros,
          rasterFinish: buildMicros + rasterMicros,
          rasterFinishWallTime: buildMicros + rasterMicros,
        ),
      ),
    );
  }

  for (final quality in ['auto', 'full', 'economy']) {
    test('120Hz does not silently blur the selected quality: $quality', () {
      final scene = Live2DSceneController(
        vsync: _Clock(),
        mobile: true,
        onTick: (_, _) {},
      );
      addTearDown(scene.dispose);
      scene.configure(quality: quality, refreshRate: 120);
      scene.attach(_Model());
      scene.active = true;
      final base = scene.effectiveRasterBudget;
      final target = quality == 'economy' ? 30 : 60;
      // 12ms is slow for a 120Hz UI, but meets a 60fps animation budget.
      reportFrames(rasterMicros: 12000, count: 240);
      expect(scene.effectiveRasterBudget, base);
      expect(scene.painter!.rasterPixelBudget, base);
      expect(scene.fps, target);
      reportFrames(rasterMicros: 40000, count: 12);
      expect(scene.fps, quality == 'economy' ? 20 : 30);
      expect(scene.effectiveRasterBudget, base);
      scene.interacting = true;
      reportFrames(rasterMicros: 1000, count: 400);
      expect(scene.fps, quality == 'economy' ? 20 : 30);
      scene.interacting = false;
      reportFrames(rasterMicros: 1000, count: 240);
      expect(scene.fps, target);
      expect(scene.effectiveRasterBudget, base);
    });
  }
  test('isolated spikes do not accumulate into permanent throttling', () {
    final scene = Live2DSceneController(
      vsync: _Clock(),
      mobile: true,
      onTick: (_, _) {},
    )..attach(_Model());
    addTearDown(scene.dispose);
    scene.active = true;
    for (var i = 0; i < 30; i++) {
      reportFrames(rasterMicros: 40000, count: 1);
      reportFrames(rasterMicros: 12000, count: 1);
    }
    expect(scene.fps, 60);
    scene.configure(frameLimit: 30, refreshRate: 120);
    reportFrames(rasterMicros: 24000, count: 30);
    expect(scene.fps, 30);
    expect(scene.effectiveRasterBudget, 2000000);
  });
  test(
    'slow offscreen snapshots throttle even when visible frames are cheap',
    () {
      final scene = Live2DSceneController(
        vsync: _Clock(),
        mobile: true,
        onTick: (_, _) {},
      )..attach(_Model());
      addTearDown(scene.dispose);
      scene.active = true;
      scene.painter!.lastRasterizationMicros = 40000;
      reportFrames(rasterMicros: 1000, count: 12);
      expect(scene.fps, 30);
      expect(scene.effectiveRasterBudget, 2000000);
      scene.painter!.lastRasterizationMicros = 4000;
      reportFrames(rasterMicros: 1000, count: 240);
      expect(scene.fps, 60);
    },
  );
  test('desktop compositing retains the configured quality budget', () {
    final scene = Live2DSceneController(
      vsync: _Clock(),
      mobile: false,
      onTick: (_, _) {},
    );
    addTearDown(scene.dispose);
    scene.configure(refreshRate: 144);
    scene.attach(_Model());
    scene.active = true;
    reportFrames(rasterMicros: 40000, count: 30);
    expect(scene.effectiveRasterBudget, 2000000);
    expect(scene.painter!.rasterPixelBudget, 2000000);
    expect(scene.fps, 30);
  });
  for (final mobile in [true, false]) {
    testWidgets(
      'loading has no poster before the native ${mobile ? 'mobile' : 'desktop'} model is ready',
      (tester) async {
        final pending = Completer<Live2DModel>();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CharacterStage(
                mobile: mobile,
                voice: SilentVoice(),
                modelLoader: () => pending.future,
              ),
            ),
          ),
        );
        await tester.pump();
        Finder poster() => find.byWidgetPredicate(
          (w) =>
              w is Image &&
              w.image is AssetImage &&
              (w.image as AssetImage).assetName ==
                  'assets/images/yachiyo-hub-stand.png',
        );
        expect(poster(), findsNothing);
        expect(find.byKey(const Key('room-character-pending')), findsOneWidget);
        expect(find.byKey(const Key('room-backdrop')), findsOneWidget);
        final viewport = tester.getRect(
          find.byKey(const Key('room-character-viewport')),
        );
        if (!mobile) {
          await tester.tap(find.byTooltip('全屏角色舞台'));
          await tester.pump(const Duration(seconds: 1));
          expect(poster(), findsNothing);
        }
        pending.complete(_Model());
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 34));
        expect(find.byKey(const Key('room-character-pending')), findsNothing);
        expect(
          find.byWidgetPredicate(
            (w) => w is CustomPaint && w.painter is Live2DPainter,
          ),
          findsOneWidget,
        );
        expect(poster(), findsNothing);
        if (!mobile) {
          await tester.tap(find.byTooltip('退出全屏舞台'));
          await tester.pump();
          await tester.pump(const Duration(seconds: 1));
          await tester.pump();
        }
        expect(
          tester.getRect(find.byKey(const Key('room-character-viewport'))),
          viewport,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
    testWidgets(
      'failed ${mobile ? 'mobile' : 'desktop'} model retries without a poster',
      (tester) async {
        final pending = Completer<Live2DModel>();
        var attempts = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CharacterStage(
                mobile: mobile,
                voice: SilentVoice(),
                modelLoader: () =>
                    ++attempts == 1 ? pending.future : Future.value(_Model()),
              ),
            ),
          ),
        );
        await tester.pump();
        pending.completeError(StateError('fixture load failure'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('room-character-pending')), findsOneWidget);
        await tester.tap(find.byKey(const Key('live2d-retry')));
        await tester.pump();
        expect(attempts, 2);
        expect(find.byKey(const Key('room-character-pending')), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets(
    'idle model updates keep transforms stable; actions still move the character',
    (tester) async {
      final model = _Model(), animation = RoomAnimation();
      addTearDown(animation.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CharacterStage(
              voice: SilentVoice(),
              animation: animation,
              modelLoader: () async => model,
            ),
          ),
        ),
      );
      await tester.pump();
      final paint = find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is Live2DPainter,
      );
      final transforms = find.ancestor(
        of: paint,
        matching: find.byType(Transform),
      );
      final idle = tester.widgetList<Transform>(transforms).toList();
      expect(idle, hasLength(3));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 34));
      }
      expect(model.ticks, greaterThan(3));
      final afterIdle = tester.widgetList<Transform>(transforms).toList();
      for (var i = 0; i < idle.length; i++) {
        expect(identical(idle[i], afterIdle[i]), true);
      }
      animation.enqueue({'motion': 'nod', 'durationMs': 1000});
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 34));
      }
      expect(animation.y, isNot(0));
      expect(
        tester
            .widgetList<Transform>(transforms)
            .map((w) => w.transform.storage.toList()),
        isNot(equals(idle.map((w) => w.transform.storage.toList()))),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  test('detail priority preserves native density while auto stays bounded', () {
    expect(Live2DSceneController.textureLimitFor('economy'), 2048);
    expect(Live2DSceneController.textureLimitFor('full'), 4096);
    for (final quality in ['auto', 'unknown']) {
      expect(Live2DSceneController.textureLimitFor(quality), 3072);
    }
    for (final mobile in [true, false]) {
      expect(Live2DSceneController.rasterBudgetFor('full', mobile: mobile), 0);
      expect(
        Live2DSceneController.rasterBudgetFor('auto', mobile: mobile),
        2000000,
      );
      expect(
        Live2DSceneController.rasterBudgetFor('economy', mobile: mobile),
        mobile ? 225000 : 450000,
      );
    }
  });
  for (final refresh in [59.94, 60, 90, 120, 144]) {
    for (final mobile in [false, true]) {
      test('clock keeps 60 fps on $refresh Hz display (mobile=$mobile)', () {
        final clock = _Clock(), deltas = <double>[];
        final scene = Live2DSceneController(
          vsync: clock,
          mobile: mobile,
          onTick: (_, delta) => deltas.add(delta),
        );
        addTearDown(scene.dispose);
        scene.attach(_Model());
        scene.active = true;
        for (var i = 0; i <= refresh * 2; i++) {
          clock.frame(Duration(microseconds: (i * 1000000 / refresh).round()));
        }
        expect(deltas.length, closeTo(120, 2));
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

  test('interaction yields stop model work without invalidating its cache', () {
    final clock = _Clock(), deltas = <double>[];
    final scene = Live2DSceneController(
      vsync: clock,
      mobile: true,
      onTick: (_, delta) => deltas.add(delta),
    );
    addTearDown(scene.dispose);
    scene.attach(_Model());
    scene.active = true;
    clock.frame(Duration.zero);
    clock.frame(const Duration(milliseconds: 34));
    expect(scene.modelFrames, 1);
    final painter = scene.painter;
    scene.interacting = true;
    expect(scene.running, false);
    expect(scene.ticker.isActive, false);
    // A late display callback and unrelated frame timings cannot advance the
    // paused model or reduce its sharpness while chat owns the frame budget.
    for (var i = 0; i < 240; i++) {
      clock.frame(Duration(milliseconds: 34 + i * 16));
    }
    reportFrames(rasterMicros: 40000, count: 240);
    expect(scene.modelFrames, 1);
    expect(scene.effectiveRasterBudget, 2000000);
    expect(scene.interactionYields, 1);
    expect(scene.activeSeconds, .034);
    scene.interacting = false;
    expect(scene.running, true);
    expect(scene.painter, same(painter));
    clock.frame(const Duration(hours: 1));
    clock.frame(const Duration(hours: 1, milliseconds: 34));
    expect(deltas, [.034, .034]);
    expect(scene.activeSeconds, .068);
    // Repeated typing bursts preserve one model, painter and the selected texture quality.
    for (var i = 0; i < 100; i++) {
      scene.interacting = true;
      scene.interacting = false;
    }
    expect(scene.interactionYields, 101);
    expect(scene.painter, same(painter));
    expect(Live2DSceneController.textureLimitFor('auto'), 3072);
  });

  test('load and visibility preserve interaction ownership of the clock', () {
    final scene = Live2DSceneController(
      vsync: _Clock(),
      mobile: false,
      onTick: (_, _) {},
    );
    addTearDown(scene.dispose);
    scene.interacting = true;
    scene.active = true;
    scene.attach(_Model());
    expect(scene.ticker.isActive, false);
    scene.active = false;
    scene.interacting = false;
    expect(scene.ticker.isActive, false);
    scene.active = true;
    expect(scene.ticker.isActive, true);
    scene.attach(_Model());
    expect(scene.ticker.isActive, true);
  });

  testWidgets(
    'Room activity pauses without a stage rebuild, and queued actions resume',
    (tester) async {
      final model = _Model(), animation = RoomAnimation();
      final activity = ValueNotifier(false);
      addTearDown(animation.dispose);
      addTearDown(activity.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CharacterStage(
              voice: SilentVoice(),
              animation: animation,
              interacting: activity,
              modelLoader: () async => model,
            ),
          ),
        ),
      );
      await tester.pump();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 34));
      }
      expect(model.ticks, greaterThan(0));
      final paint = find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is Live2DPainter,
      );
      final before = tester.widget<CustomPaint>(paint);
      final ticks = model.ticks;
      activity.value = true;
      animation.enqueue({'motion': 'nod', 'durationMs': 1000});
      await tester.pump(const Duration(seconds: 20));
      expect(model.ticks, ticks);
      expect(animation.queue, hasLength(1));
      expect(tester.widget<CustomPaint>(paint), same(before));
      activity.value = false;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 34));
      await tester.pump(const Duration(milliseconds: 34));
      expect(model.ticks, greaterThan(ticks));
      expect(animation.current, isNotNull);
      expect(animation.elapsed, lessThan(150));
      await tester.pumpWidget(const SizedBox());
      // The disposed stage must have detached from the external activity bus.
      activity.value = true;
      expect(tester.takeException(), isNull);
    },
  );

  for (final mobile in [true, false]) {
    testWidgets(
      'pointer does not steer ${mobile ? 'mobile' : 'desktop'} character, including fullscreen',
      (tester) async {
        tester.view.devicePixelRatio = mobile ? 3 : 2;
        tester.view.physicalSize = mobile
            ? const Size(1170, 2532)
            : const Size(2560, 1640);
        addTearDown(tester.view.reset);
        final model = _Model();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CharacterStage(
                mobile: mobile,
                voice: SilentVoice(),
                modelLoader: () async => model,
                settings: const RoomSettings(),
              ),
            ),
          ),
        );
        await tester.pump();
        final mouse = await tester.createGesture(
          kind: ui.PointerDeviceKind.mouse,
        );
        await mouse.addPointer();
        Future<void> hover() async {
          final rect = tester.getRect(
            find.byKey(const Key('room-character-viewport')).last,
          );
          await mouse.moveTo(rect.topLeft + const Offset(20, 20));
          await tester.pump(const Duration(milliseconds: 34));
          await mouse.moveTo(rect.bottomRight - const Offset(20, 20));
          await tester.pump(const Duration(milliseconds: 34));
        }

        await hover();
        if (!mobile) {
          await tester.tap(find.byTooltip('全屏角色舞台'));
          await tester.pump(const Duration(milliseconds: 400));
        }
        await hover();
        expect(model.gazes.length, greaterThan(3));
        expect(model.gazes.every((gaze) => gaze == Offset.zero), true);
        await mouse.removePointer();
        if (!mobile) {
          await tester.tap(find.byTooltip('退出全屏舞台'));
          await tester.pump(const Duration(milliseconds: 400));
        }
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({
        mobile ? TargetPlatform.android : TargetPlatform.windows,
      }),
    );
  }

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
