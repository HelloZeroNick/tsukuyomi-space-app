import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/room/room_page.dart';
import 'package:tsukuyomi_space_app/live2d/character_stage.dart';
import 'package:tsukuyomi_space_app/main.dart';

import 'support/fakes.dart';

void main() {
  for (final width in [390.0, 1280.0]) {
    testWidgets('Room independent updates at $width', (tester) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final room = RoomController(
        storage: MemoryStorage(),
        chat: FakeChat(),
        site: FakeSite(),
        voice: SilentVoice(),
      );
      await room.initialize();
      room.turns = List.generate(
        2000,
        (i) => ChatTurn(
          id: 'partition-$i',
          user: '问题 $i',
          assistant: '回复 $i。第二句。',
          createdAt: DateTime(2020),
        ),
      );
      addTearDown(room.dispose);
      await tester.pumpWidget(
        TsukuyomiApp(controller: room, loadNative: false),
      );
      await tester.pumpAndSettle();
      final counts = <String, int>{};
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        final widget = element.widget;
        if (widget is RoomPage ||
            widget is CharacterStage ||
            widget is CustomScrollView ||
            widget is TextField) {
          final name = widget.runtimeType.toString();
          counts[name] = (counts[name] ?? 0) + 1;
        }
      };
      addTearDown(() => debugOnRebuildDirtyWidget = null);
      for (var i = 0; i < 30; i++) {
        room.workspace.status = 'unrelated update $i';
        room.workspace.changed();
        await tester.pump();
      }
      debugPrint(
        'ROOM_PARTITION ${jsonEncode({'width': width, 'updates': 30, 'rebuilds': counts})}',
      );
      expect(counts['RoomPage'] ?? 0, 0);
      expect(counts['CustomScrollView'] ?? 0, 0);
      expect(counts['TextField'] ?? 0, 0);
      counts.clear();
      for (var i = 0; i < 30; i++) {
        room.syncStatus = 'sync status $i';
        room.workspace.changed();
        await tester.pump();
      }
      expect(counts['RoomPage'] ?? 0, 0);
      expect(counts['CustomScrollView'] ?? 0, 0);
      expect(counts['TextField'] ?? 0, 0);
      if (width > 860) {
        expect(find.text('离线演示 · 仅保存在本机'), findsOneWidget);
      }
      debugOnRebuildDirtyWidget = null;
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('cached Room surfaces follow a live theme change', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final room = RoomController(
      storage: MemoryStorage(),
      chat: FakeChat(),
      site: FakeSite(),
      voice: SilentVoice(),
    );
    await room.initialize();
    addTearDown(room.dispose);
    room.error = 'theme fixture error';
    room.turns = [
      ChatTurn(
        id: 'theme',
        user: '问题',
        assistant: '回复。',
        createdAt: DateTime(2020),
        pending: true,
      ),
    ];
    Widget app(Brightness brightness) => MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: RoomPage(controller: room, loadNative: false),
    );
    await tester.pumpWidget(app(Brightness.light));
    await tester.pumpAndSettle();
    final light = tester
        .widget<Text>(find.text('theme fixture error'))
        .style!
        .color;
    await tester.pumpWidget(app(Brightness.dark));
    await tester.pumpAndSettle();
    final dark = tester
        .widget<Text>(find.text('theme fixture error'))
        .style!
        .color;
    expect(light, const Color(0xff202b46));
    expect(dark, const Color(0xffedf0f7));
    expect(dark, isNot(light));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test(
    'filtered conversation is computed once and invalidated by changes',
    () async {
      final room = RoomController(
        storage: MemoryStorage(),
        chat: FakeChat(),
        site: FakeSite(),
        voice: SilentVoice(),
      );
      await room.initialize();
      addTearDown(room.dispose);
      room.turns = List.generate(
        2000,
        (i) => ChatTurn(
          id: '$i',
          user: 'question',
          assistant: 'answer',
          createdAt: DateTime(2020),
        ),
      );
      await room.startConversation();
      final initial = room.visibleTurns;
      for (var i = 0; i < 100; i++) {
        expect(identical(room.visibleTurns, initial), true);
      }
      final next = ChatTurn(
        id: 'new',
        user: 'next',
        assistant: 'new answer',
        createdAt: DateTime.now(),
      );
      room.turns = [...room.turns, next];
      expect(room.visibleTurns, [next]);
      final appended = room.visibleTurns;
      expect(identical(room.visibleTurns, appended), true);
      room.showSharedConversation({
        'shareKey': 'shared',
        'assistantMessage': 'shared answer',
      });
      expect(room.visibleTurns.single.id, 'shared-shared');
      final shared = room.visibleTurns;
      expect(identical(room.visibleTurns, shared), true);
      room.leaveSharedConversation();
      expect(room.visibleTurns, [next]);
      expect(identical(room.visibleTurns, shared), false);
    },
  );
}
