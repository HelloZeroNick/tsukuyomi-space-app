import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tsukuyomi_live2d/tsukuyomi_live2d.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/main.dart';
import 'package:tsukuyomi_space_app/live2d/live2d_scene_controller.dart';
import 'package:tsukuyomi_space_app/live2d/character_stage.dart';
import 'package:window_manager/window_manager.dart';

import '../test/support/fakes.dart';

bool get desktopBenchmark =>
    Platform.isMacOS || Platform.isWindows || Platform.isLinux;

Future<void> focusBenchmarkWindow() async {
  if (!desktopBenchmark) {
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      throw StateError('Native mobile benchmark is not in the foreground');
    }
    return;
  }
  for (var attempt = 0; attempt < 150; attempt++) {
    await windowManager.show();
    await windowManager.focus();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (await windowManager.isFocused() &&
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      return;
    }
  }
  throw StateError('Native benchmark window could not obtain focus');
}

Future<void> expectForeground() async {
  expect(WidgetsBinding.instance.lifecycleState, AppLifecycleState.resumed);
  if (desktopBenchmark) expect(await windowManager.isFocused(), true);
}

class _ForegroundGuard extends WidgetsBindingObserver with WindowListener {
  bool interrupted = false;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) interrupted = true;
  }

  @override
  void onWindowBlur() => interrupted = true;
  @override
  void onWindowMinimize() => interrupted = true;
}

void main() {
  const ime = bool.fromEnvironment('BENCHMARK_IME');
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('Room 2000 messages, image, stream and native Live2D benchmark', (
    tester,
  ) async {
    if (ime) binding.testTextInput.register();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Text('Preparing image workload…')),
      ),
    );
    await tester.pump();
    await tester.runAsync(() async {
      if (!desktopBenchmark) return;
      await windowManager.ensureInitialized();
      await windowManager.setFullScreen(false);
      await windowManager.setSize(
        const bool.fromEnvironment('BENCHMARK_MOBILE_LAYOUT')
            ? const Size(1280, 900)
            : const Size(1280, 820),
      );
    });
    final imageData = (await tester.runAsync(
      () => rootBundle.load('assets/images/yachiyo-portrait.webp'),
    ))!;
    final imageBytes = imageData.buffer.asUint8List(
      imageData.offsetInBytes,
      imageData.lengthInBytes,
    );
    final image = (await tester.runAsync(
      () => instantiateImageCodec(imageBytes),
    ))!;
    final decoded = (await tester.runAsync(image.getNextFrame))!.image;
    final imageWidth = decoded.width, imageHeight = decoded.height;
    decoded.dispose();
    image.dispose();
    final imageUrl = 'data:image/webp;base64,${base64Encode(imageBytes)}';
    final runs = <Map<String, dynamic>>[];
    for (var repetition = 0; repetition < 3; repetition++) {
      await tester.runAsync(focusBenchmarkWindow);
      final started = Stopwatch()..start();
      final frames = <FrameTiming>[];
      void timings(List<FrameTiming> batch) => frames.addAll(batch);
      SchedulerBinding.instance.addTimingsCallback(timings);
      final storage = MemoryStorage()
        ..value = const RoomSettings(
          demo: false,
          model: 'benchmark',
          options: {
            if (bool.fromEnvironment('BENCHMARK_BASELINE'))
              'live2dRenderQuality': 'full',
            'siteFeedEnabled': false,
            'knowledgeEnabled': false,
            'memoryEnabled': false,
          },
        );
      final chat = FakeChat()..controlled = true;
      final room = RoomController(
        storage: storage,
        chat: chat,
        site: FakeSite(),
        voice: SilentVoice(),
      );
      final scope = '${endpointUri(storage.value.siteUrl).origin}:guest';
      final history = List.generate(
        2000,
        (i) => ChatTurn(
          id: 'benchmark-$i',
          user: '消息 $i · 这是一段用于复现滚动负载的中文问题。',
          assistant: const bool.fromEnvironment('BENCHMARK_CHAT_SCROLL')
              ? i % 5 == 0
                    ? '## 回复 $i\n\n**滚动测试**，保留文字选区、链接和代码格式。\n\n'
                          '${List.generate(6, (j) => '### 第$j段\n\n这里是较长的中文解释，滚动中不应测量文章目录。[网站](https://yachiyo.hk)\n\n').join()}'
                          '```dart\nfinal message = $i;\n```'
                    : '回复 $i · ${List.filled(8, '这是一段完整的中文解释，保留原来的聊天分句。查看 https://yachiyo.hk/room 和 3.14 等内容。').join()}'
              : '回复 $i · 使用同样的消息长度比较帧耗时。\n\n第二段说明与第一段组成完整的对话。',
          createdAt: DateTime(2026, 9, 29).add(Duration(seconds: i)),
          image: i % 10 == 0 ? {'dataUrl': imageUrl} : null,
        ),
      );
      // Scope names changed with old revisions; seed after reading its value.
      storage.histories[scope] = history;
      await room.initialize();
      room.turns = history;
      var ticks = 0;
      var modelCpuMs = 0.0;
      Live2DModel? model;
      final app = TsukuyomiApp(
        key: ValueKey(repetition),
        controller: room,
        initialPath: '/room',
        modelLoader: () async {
          model = await loadLive2D(
            maxTextureSize: const bool.hasEnvironment('BENCHMARK_TEXTURE_SIZE')
                ? const int.fromEnvironment('BENCHMARK_TEXTURE_SIZE')
                : Live2DSceneController.textureLimitFor('auto'),
          );
          model!.addListener(() {
            ticks++;
            modelCpuMs += model!.updateMilliseconds;
          });
          return model!;
        },
      );
      final keyboard = ValueNotifier<double>(0);
      await tester.pumpWidget(
        const bool.fromEnvironment('BENCHMARK_MOBILE_LAYOUT')
            ? Center(
                child: SizedBox(
                  width: 390,
                  height: 844,
                  child: ValueListenableBuilder<double>(
                    valueListenable: keyboard,
                    child: app,
                    builder: (context, inset, child) => MediaQuery(
                      data: MediaQueryData(
                        size: const Size(390, 844),
                        devicePixelRatio: tester.view.devicePixelRatio,
                        padding: EdgeInsets.only(
                          bottom: ime && inset == 0 ? 24 : 0,
                        ),
                        viewPadding: EdgeInsets.only(bottom: ime ? 24 : 0),
                        viewInsets: EdgeInsets.only(bottom: inset),
                      ),
                      child: child!,
                    ),
                  ),
                ),
              )
            : app,
      );
      await tester.pump();
      final inputMs = started.elapsedMilliseconds;
      for (var i = 0; model == null && i < 200; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }
      expect(model, isNotNull);
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(focusBenchmarkWindow);
      await expectForeground();
      // Prove the visible native model is actually animating before testing
      // input-priority scheduling. Interaction phases deliberately freeze its
      // clock; their lower tick count is no longer mistaken for a hidden app.
      final idleTickStart = ticks;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 2)),
      );
      await tester.pump();
      final idleTicks = ticks - idleTickStart;
      expect(
        idleTicks,
        greaterThanOrEqualTo(10),
        reason: 'Native idle scene must animate in the foreground',
      );
      await expectForeground();
      final measuredPainter = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<Live2DPainter>()
          .single;
      measuredPainter.batchMeshes = !const bool.fromEnvironment(
        'BENCHMARK_NO_BATCH',
      );
      final paintStart = measuredPainter.paintCount;
      final drawStart = measuredPainter.totalDrawCalls;
      final batchStart = measuredPainter.totalBatchedMeshes;
      frames.clear();
      ticks = 0;
      modelCpuMs = 0;
      final foreground = _ForegroundGuard();
      binding.addObserver(foreground);
      if (desktopBenchmark) windowManager.addListener(foreground);
      void removeForegroundGuard() {
        binding.removeObserver(foreground);
        if (desktopBenchmark) windowManager.removeListener(foreground);
      }

      addTearDown(removeForegroundGuard);
      final sample = Stopwatch()..start();
      final expectsInteraction = const bool.fromEnvironment(
        'BENCHMARK_INTERACTION_EXPECTED',
        defaultValue: true,
      );
      ValueListenable<bool>? activity;
      try {
        // The exact same workload can be copied to the pre-refactor checkout.
        // Its stage has no activity bus; this dynamic lookup changes only the
        // diagnostics, never its rendering or model scheduling behavior.
        activity =
            (tester.widget<CharacterStage>(
                  find.byType(CharacterStage),
                ) as dynamic).interacting
                as ValueListenable<bool>?;
      } on NoSuchMethodError {
        expect(expectsInteraction, false);
      }
      if (expectsInteraction) expect(activity, isNotNull);
      var yieldTransitions = 0, yieldedMicros = 0;
      int? yieldStarted;
      void activityChanged() {
        if (activity!.value) {
          yieldTransitions++;
          yieldStarted = sample.elapsedMicroseconds;
        } else if (yieldStarted != null) {
          yieldedMicros += sample.elapsedMicroseconds - yieldStarted!;
          yieldStarted = null;
        }
      }

      activity?.addListener(activityChanged);
      if (activity?.value == true) activityChanged();
      final sending = ime ? Future<void>.value() : room.send('并行流式性能测试');
      var editorReplacements = 0,
          stageRebuilds = 0,
          viewportChanges = 0,
          composingResets = 0;
      if (ime) {
        final input = find.byKey(const Key('message-input'));
        final editable = find.descendant(
          of: input,
          matching: find.byType(EditableText),
        );
        await tester.tap(input);
        await tester.pump();
        await tester.runAsync(focusBenchmarkWindow);
        await expectForeground();
        var editor = tester.state(editable);
        Widget? previousStage;
        Rect? previousViewport;
        for (var step = 0; step < 120; step++) {
          if (step % 12 == 0) {
            await tester.runAsync(focusBenchmarkWindow);
          }
          keyboard.value = const [
            0.0,
            40.0,
            90.0,
            160.0,
            240.0,
            330.0,
            280.0,
            210.0,
            140.0,
            70.0,
            30.0,
            0.0,
          ][step % 12];
          if (step % 12 == 4 || step % 12 == 9) {
            room.error = step % 12 == 4 ? 'fixture sync status' : '';
            room.workspace.changed();
          }
          await tester.pump(const Duration(milliseconds: 32));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 32)),
          );
          final current = tester.state(editable);
          if (!identical(current, editor)) editorReplacements++;
          editor = current;
          final field = tester.widget<TextField>(input);
          if (step > 0 && !field.controller!.value.composing.isValid) {
            composingResets++;
          }
          field.focusNode!.requestFocus();
          tester.testTextInput.updateEditingValue(
            TextEditingValue(
              text: '中文输入 $step',
              selection: TextSelection.collapsed(offset: '中文输入 $step'.length),
              composing: TextRange(start: 0, end: '中文输入 $step'.length),
            ),
          );
          await room.saveComposerDraft(field.controller!.text);
          final stage = tester.widget(find.byType(CharacterStage));
          final viewport = tester.getRect(
            find.byKey(const Key('room-character-viewport')),
          );
          if (previousStage != null && !identical(stage, previousStage)) {
            stageRebuilds++;
          }
          if (previousViewport != null && previousViewport != viewport) {
            viewportChanges++;
          }
          previousStage = stage;
          previousViewport = viewport;
        }
        if (const bool.fromEnvironment('BENCHMARK_ASSERT_IME')) {
          expect(editorReplacements, 0);
          expect(viewportChanges, 0);
          expect(composingResets, 0);
        }
        await tester.runAsync(focusBenchmarkWindow);
      }
      if (!ime) {
        for (var i = 0; chat.stream == null && i < 100; i++) {
          await tester.pump(const Duration(milliseconds: 10));
        }
        expect(chat.stream, isNotNull);
        final list = find
            .descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable),
            )
            .first;
        final scrollRect = tester.getRect(list);
        // Keep the whole gesture inside the transcript. A centre-origin drag
        // can finish over the composer/Stop button on a compact window.
        final dragStart = Offset(
          scrollRect.left + 8,
          scrollRect.top + scrollRect.height * .15,
        );
        final dragStep = (scrollRect.height * .6 / 18).clamp(
          4.0,
          const bool.fromEnvironment('BENCHMARK_CHAT_SCROLL') ? 20.0 : 10.0,
        );
        TestGesture? heldDrag;
        for (var step = 0; step < 240; step++) {
          expect(
            foreground.interrupted,
            false,
            reason: 'Native foreground was lost at stream step $step',
          );
          expect(room.generating, true, reason: 'stream step $step');
          expect(chat.stream!.isClosed, false, reason: 'stream step $step');
          chat.stream!.add('片段 $step，');
          // Hold ten real drags across display frames. tester.drag alone sends
          // its events synchronously and leaves almost no wall-time during
          // which the scene scheduler can yield to the user's gesture.
          if (step % 24 == 0) {
            heldDrag = await tester.startGesture(dragStart);
          }
          if (step % 24 < 18) {
            await heldDrag!.moveBy(Offset(0, dragStep));
          } else if (step % 24 == 18) {
            await heldDrag!.up();
            heldDrag = null;
          }
          await tester.pump(const Duration(milliseconds: 16));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 16)),
          );
        }
        await chat.stream!.close();
      }
      await sending;
      await tester.pump(const Duration(seconds: 1));
      // FrameTiming delivery is batched. Flush the measured visible phase and
      // stop collecting before the separate hidden-scene/navigation check.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      SchedulerBinding.instance.removeTimingsCallback(timings);
      activity?.removeListener(activityChanged);
      if (yieldStarted != null) {
        yieldedMicros += sample.elapsedMicroseconds - yieldStarted!;
      }
      sample.stop();
      removeForegroundGuard();
      expect(
        foreground.interrupted,
        false,
        reason: 'Backgrounded or unfocused samples cannot certify performance',
      );
      expect(
        frames.length,
        greaterThanOrEqualTo(60),
        reason: 'A real frame population is required for a P95 sample',
      );
      final recordedTicks = ticks;
      if (ime) {
        // ignore: avoid_print
        print(
          'IME_SAMPLE ticks=$recordedTicks elapsed_ms=${sample.elapsedMilliseconds} lifecycle=${WidgetsBinding.instance.lifecycleState} focus=${desktopBenchmark ? await windowManager.isFocused() : "mobile foreground"} replacements=$editorReplacements viewport_changes=$viewportChanges',
        );
      }
      expect(
        find.text('图片暂不可用'),
        findsNothing,
        reason: 'Image load failures must not silently turn the workload into placeholders',
      );
      if (expectsInteraction) {
        expect(
          yieldTransitions,
          greaterThan(0),
          reason: 'Scrolling or typing must yield native model work',
        );
        expect(yieldedMicros, greaterThan(500000));
      }
      final recordedModelMs = modelCpuMs;
      final painters = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<Live2DPainter>()
          .toList();
      expect(painters, hasLength(1));
      final painter = painters.single;
      final viewport = tester.getSize(
        find.byWidgetPredicate((w) => w is CustomPaint && w.painter == painter),
      );
      await expectForeground();
      final boundedPasses = painter.boundedPasses;
      final downsampledPasses = painter.downsampledPasses;
      final boundedPixels = painter.rasterizedPixels;
      final sampledPaints = painter.paintCount - paintStart;
      final sampledDraws = painter.totalDrawCalls - drawStart;
      final sampledBatches = painter.totalBatchedMeshes - batchStart;
      final retainedBatchBytes = painter.retainedBatchBytes;
      final rssBefore = ProcessInfo.currentRss;
      // Cover Room with another route and verify its model clock stops.
      Navigator.of(tester.element(find.byType(Scaffold).first)).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('hidden scene')),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final hiddenStart = ticks;
      await tester.pump(const Duration(seconds: 1));
      final hiddenTicks = ticks - hiddenStart;
      expect(hiddenTicks, 0);
      Navigator.of(tester.element(find.text('hidden scene'))).pop();
      await tester.pump(const Duration(milliseconds: 400));
      final ui =
          frames.map((f) => f.buildDuration.inMicroseconds / 1000).toList()
            ..sort();
      final raster =
          frames.map((f) => f.rasterDuration.inMicroseconds / 1000).toList()
            ..sort();
      double p95(List<double> values) =>
          values.isEmpty ? 0 : values[((values.length - 1) * .95).round()];
      final run = <String, dynamic>{
        'run': repetition + 1,
        'native_platform': Platform.operatingSystem,
        'idle_model_ticks_2_seconds': idleTicks,
        'interaction_yield_transitions': yieldTransitions,
        'interaction_yield_wall_ms': yieldedMicros / 1000,
        'interaction_priority_expected': expectsInteraction,
        'scroll_gestures': ime ? 0 : 10,
        'held_drag_frames_per_gesture': ime ? 0 : 18,
        'chat_scroll_workload': const bool.fromEnvironment(
          'BENCHMARK_CHAT_SCROLL',
        ),
        'mobile_layout': const bool.fromEnvironment('BENCHMARK_MOBILE_LAYOUT'),
        'simulated_ime': ime,
        'editor_replacements': editorReplacements,
        'stage_widget_changes': stageRebuilds,
        'viewport_changes': viewportChanges,
        'composing_resets': composingResets,
        'image_fixture': {
          'asset': 'assets/images/yachiyo-portrait.webp',
          'width': imageWidth,
          'height': imageHeight,
          'encoded_bytes': imageBytes.length,
          'messages': 200,
          'visible_decode_errors': 0,
        },
        'viewport': {
          'width': viewport.width,
          'height': viewport.height,
          'dpr': tester.view.devicePixelRatio,
        },
        'input_ready_ms': inputMs,
        'frames': frames.length,
        'ui_p95_ms': p95(ui),
        'raster_p95_ms': p95(raster),
        'frames_over_16_7_ms': frames
            .where(
              (f) =>
                  f.buildDuration.inMicroseconds > 16667 ||
                  f.rasterDuration.inMicroseconds > 16667,
            )
            .length,
        'rss_bytes': rssBefore,
        'rss_after_navigation_bytes': ProcessInfo.currentRss,
        'model_ticks': recordedTicks,
        'model_update_cpu_percent':
            recordedModelMs / sample.elapsedMilliseconds * 100,
        'model_update_mean_ms': recordedTicks == 0
            ? 0
            : recordedModelMs / recordedTicks,
        'live2d_bounded_passes': boundedPasses,
        'live2d_downsampled_passes': downsampledPasses,
        'live2d_rasterized_pixels': boundedPixels,
        'live2d_pixel_budget': painter.rasterPixelBudget,
        'live2d_mesh_batching': painter.batchMeshes,
        'live2d_paints': sampledPaints,
        'live2d_draw_calls': sampledDraws,
        'live2d_batched_meshes': sampledBatches,
        'live2d_retained_batch_bytes': retainedBatchBytes,
        'live2d_texture_rgba_bytes': model!.textures.fold<int>(
          0,
          (sum, image) => sum + image.width * image.height * 4,
        ),
        'hidden_model_ticks': hiddenTicks,
      };
      runs.add(run);
      // Driver captures this machine-readable evidence, including baseline runs.
      // ignore: avoid_print
      print('ROOM_BENCHMARK ${jsonEncode(run)}');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 200));
      room.dispose();
      await tester.pump(const Duration(milliseconds: 500));
      keyboard.dispose();
    }
    binding.reportData = {
      'label': const String.fromEnvironment(
        'BENCHMARK_LABEL',
        defaultValue: 'after',
      ),
      'scene':
          '${const bool.fromEnvironment('BENCHMARK_MOBILE_LAYOUT') ? '390x844 mobile layout' : 'native viewport'} native ${Platform.operatingSystem}; 2000 turns, 200 valid bundled portrait image messages, ${ime ? "simulated keyboard insets and typing" : "streamed fragments"}, Live2D, three runs; mixed Markdown/long replies=${const bool.fromEnvironment('BENCHMARK_CHAT_SCROLL')}',
      'runs': runs,
    };
  }, timeout: const Timeout(Duration(minutes: 10)));
}
