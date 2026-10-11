import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/features/game/kaguya_assets.dart';
import 'package:tsukuyomi_space_app/features/game/game_page.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';

import 'game_native_test.dart' show GameApi;
import 'support/fakes.dart';

void main() {
  testWidgets(
    'game page shows a recoverable failure and its restart button resumes frames',
    (tester) async {
      final controller = RoomController(
        storage: MemoryStorage(),
        site: GameApi(),
        chat: FakeChat(),
        voice: SilentVoice(),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await tester.pumpWidget(
        MaterialApp(
          home: GamePage(controller: controller, onGo: (_) {}),
        ),
      );
      KaguyaPainter? painter;
      for (var attempt = 0; attempt < 80 && painter == null; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)),
        );
        await tester.pump(const Duration(milliseconds: 34));
        painter = tester
            .widgetList<CustomPaint>(find.byType(CustomPaint))
            .map((w) => w.painter)
            .whereType<KaguyaPainter>()
            .firstOrNull;
      }
      expect(painter, isNotNull);
      final runtime = painter!.runtime;
      runtime.onSound = (_, _, _) =>
          throw StateError('injected game page failure');
      runtime.broadcast('音乐');
      for (var frame = 0; frame < 15 && runtime.failure == null; frame++) {
        await tester.pump(const Duration(milliseconds: 34));
      }
      await tester.pump();
      expect(find.text('游戏运行异常，请重开这一局'), findsOneWidget);
      expect(runtime.failure, isNotNull);
      runtime.onSound = (_, _, _) {};
      await tester.tap(find.widgetWithText(OutlinedButton, '重开'));
      await tester.pump();
      expect(find.text('游戏运行异常，请重开这一局'), findsNothing);
      expect(runtime.failure, isNull);
      final before = runtime.time;
      await tester.pump(const Duration(milliseconds: 100));
      expect(runtime.time, greaterThan(before));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
