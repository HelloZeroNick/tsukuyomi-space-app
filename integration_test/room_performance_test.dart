import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tsukuyomi_live2d/tsukuyomi_live2d.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/main.dart';
import 'package:tsukuyomi_space_app/live2d/live2d_scene_controller.dart';
import 'package:window_manager/window_manager.dart';

import '../test/support/fakes.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('Room 2000 messages, image, stream and native Live2D benchmark', (
    tester,
  ) async {
    await windowManager.ensureInitialized();
    await windowManager.setFullScreen(false);
    await windowManager.setSize(const Size(1280, 820));
    await windowManager.show();
    await windowManager.focus();
    final runs = <Map<String, dynamic>>[];
    for (var repetition = 0; repetition < 3; repetition++) {
      final started = Stopwatch()..start();
      final frames = <FrameTiming>[];
      void timings(List<FrameTiming> batch) => frames.addAll(batch);
      SchedulerBinding.instance.addTimingsCallback(timings);
      final storage = MemoryStorage()
        ..value = const RoomSettings(
          demo: false,
          model: 'benchmark',
          options: {
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
          assistant: '回复 $i · 使用同样的消息长度比较帧耗时。\n\n第二段说明与第一段组成完整的对话。',
          createdAt: DateTime(2026, 9, 29).add(Duration(seconds: i)),
          image: i % 10 == 0
              ? {
                  'dataUrl': 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLttAAAAABJRU5ErkJggg==',
                }
              : null,
        ),
      );
      // Scope names changed with old revisions; seed after reading its value.
      storage.histories[scope] = history;
      await room.initialize();
      room.turns = history;
      var ticks = 0;
      var modelCpuMs = 0.0;
      Live2DModel? model;
      await tester.pumpWidget(
        TsukuyomiApp(
          key: ValueKey(repetition),
          controller: room,
          initialPath: '/room',
          modelLoader: () async {
            model = await loadLive2D(
              maxTextureSize:
                  const bool.hasEnvironment('BENCHMARK_TEXTURE_SIZE')
                  ? const int.fromEnvironment('BENCHMARK_TEXTURE_SIZE')
                  : Live2DSceneController.textureLimitFor('auto'),
            );
            model!.addListener(() {
              ticks++;
              modelCpuMs += model!.updateMilliseconds;
            });
            return model!;
          },
        ),
      );
      await tester.pump();
      final inputMs = started.elapsedMilliseconds;
      for (var i = 0; model == null && i < 200; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }
      expect(model, isNotNull);
      await tester.pump(const Duration(seconds: 1));
      frames.clear();
      ticks = 0;
      modelCpuMs = 0;
      final sample = Stopwatch()..start();
      final sending = room.send('并行流式性能测试');
      for (var i = 0; chat.stream == null && i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(chat.stream, isNotNull);
      final list = find
          .descendant(
            of: find.byKey(const Key('desktop-workspace')),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Scrollable &&
                  widget.axisDirection == AxisDirection.down,
            ),
          )
          .first;
      for (var step = 0; step < 240; step++) {
        chat.stream!.add('片段 $step，');
        if (step % 6 == 0) await tester.drag(list, const Offset(0, 180));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await chat.stream!.close();
      await sending;
      await tester.pump(const Duration(seconds: 1));
      sample.stop();
      final recordedTicks = ticks;
      expect(
        recordedTicks,
        greaterThan(120),
        reason: 'Benchmark must run with a visible, actively updating model',
      );
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
      expect(await windowManager.isFocused(), true);
      final boundedPasses = painter.boundedPasses;
      final downsampledPasses = painter.downsampledPasses;
      final boundedPixels = painter.rasterizedPixels;
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
      SchedulerBinding.instance.removeTimingsCallback(timings);
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
    }
    binding.reportData = {
      'label': const String.fromEnvironment(
        'BENCHMARK_LABEL',
        defaultValue: 'after',
      ),
      'scene': '1280x820 native macOS; 2000 turns, 200 image messages, streamed fragments, Live2D, three runs',
      'runs': runs,
    };
  }, timeout: const Timeout(Duration(minutes: 10)));
}
