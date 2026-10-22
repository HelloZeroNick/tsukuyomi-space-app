import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/room/room_help.dart';
import 'package:tsukuyomi_space_app/features/room/room_quick_setup.dart';
import 'package:tsukuyomi_space_app/main.dart';

import 'support/fakes.dart';

void main() {
  testWidgets('guide setup route opens the wizard and returns to Room', (
    tester,
  ) async {
    final controller = RoomController(
      storage: MemoryStorage()..value = const RoomSettings(),
      chat: FakeChat(),
      site: FakeSite(),
      voice: SilentVoice(),
    );
    await controller.initialize();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      TsukuyomiApp(controller: controller, loadNative: false),
    );
    await tester.pumpAndSettle();
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    navigator.pushNamed('/room/settings?setup=1');
    await tester.pumpAndSettle();
    expect(find.text('第一次聊天，跟着这三步就好'), findsOneWidget);
    await tester.ensureVisible(find.text('本机 Ollama').last);
    await tester.tap(find.text('本机 Ollama').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('跳过测试并保存'));
    await tester.pumpAndSettle();
    expect(find.text('第一次聊天，跟着这三步就好'), findsNothing);
    expect(controller.settings.model, isNotEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final width in [390.0, 1280.0]) {
    testWidgets('first setup saves only after review at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final storage = MemoryStorage()
        ..value = const RoomSettings(options: {'memoryEnabled': false});
      final controller = RoomController(
        storage: storage,
        chat: FakeChat(),
        site: FakeSite(),
        voice: SilentVoice(),
      );
      await controller.initialize();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: RoomQuickSetup(controller: controller)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.text('开始分步配置'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('云端 API').last);
      await tester.tap(find.text('云端 API').last);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '下一步'))
            .onPressed,
        isNull,
      );
      final keyField = find.byKey(const Key('setting-apiKey'));
      await tester.ensureVisible(keyField);
      await tester.enterText(keyField, 'first-use-fixture-key');
      await tester.pumpAndSettle();
      expect(storage.value.model, isEmpty);
      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('上一步'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(keyField).controller!.text,
        'first-use-fixture-key',
      );
      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('setup-connection-status')), findsOneWidget);
      await tester.tap(find.text('跳过测试并保存'));
      await tester.pumpAndSettle();
      expect(storage.value.apiKey, 'first-use-fixture-key');
      expect(storage.value.model, isNotEmpty);
      expect(storage.value.flag('memoryEnabled'), isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('discovery works without a model at $width', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final storage = MemoryStorage()..value = const RoomSettings();
      final controller = RoomController(
        storage: storage,
        chat: FakeChat(),
        site: FakeSite(),
        voice: SilentVoice(),
      );
      await controller.initialize();
      addTearDown(controller.dispose);
      String? target;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showRoomHelp(
                  context,
                  controller,
                  onGo: (path) => target = path,
                  onDiary: () => target = 'diary',
                ),
                child: const Text('发现'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('发现'));
      await tester.pumpAndSettle();
      expect(find.text('开始使用与发现功能'), findsOneWidget);
      await tester.ensureVisible(find.text('辉夜快跑'));
      await tester.tap(find.text('辉夜快跑'));
      await tester.pumpAndSettle();
      expect(target, '/game');
      expect(storage.value.model, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }
}
