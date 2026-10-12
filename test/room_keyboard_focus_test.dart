import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/main.dart';
import 'package:tsukuyomi_space_app/live2d/character_stage.dart';

import 'support/fakes.dart';

void main() {
  testWidgets(
    'IME animation retains the scene viewport and widget with navigation padding',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
      tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 24);
      addTearDown(tester.view.reset);
      final room = RoomController(
        storage: MemoryStorage(),
        chat: FakeChat(),
        site: FakeSite(),
        voice: SilentVoice(),
      );
      await room.initialize();
      addTearDown(room.dispose);
      await tester.pumpWidget(
        TsukuyomiApp(controller: room, loadNative: false),
      );
      await tester.pumpAndSettle();
      final viewport = tester.getRect(
        find.byKey(const Key('room-character-viewport')),
      );
      await tester.tap(find.byKey(const Key('message-input')));
      tester.view.padding = const FakeViewPadding(top: 24);
      tester.view.viewInsets = const FakeViewPadding(bottom: 50);
      await tester.pump();
      final stage = tester.widget<CharacterStage>(find.byType(CharacterStage));
      for (final inset in [100.0, 170.0, 250.0, 330.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          identical(
            tester.widget<CharacterStage>(find.byType(CharacterStage)),
            stage,
          ),
          true,
        );
        expect(
          tester.getRect(find.byKey(const Key('room-character-viewport'))),
          viewport,
        );
      }
      room.workspace.world['city'] = 'updated world';
      room.workspace.changed();
      await tester.pump();
      expect(
        tester
            .widget<CharacterStage>(find.byType(CharacterStage))
            .world['city'],
        'updated world',
      );
      expect(
        identical(
          tester.widget<CharacterStage>(find.byType(CharacterStage)),
          stage,
        ),
        false,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  for (final history in [false, true]) {
    for (final size in [const Size(390, 844), const Size(844, 390)]) {
      testWidgets(
        'Android IME retains its client and Chinese composition: $size history=$history',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final room = RoomController(
            storage: MemoryStorage(),
            chat: FakeChat(),
            site: FakeSite(),
            voice: SilentVoice(),
          );
          await room.initialize();
          if (history) {
            room.turns = [
              ChatTurn(
                id: 'old',
                user: '问题',
                assistant: '回答',
                createdAt: DateTime(2020),
              ),
            ];
          }
          addTearDown(room.dispose);
          await tester.pumpWidget(
            TsukuyomiApp(controller: room, loadNative: false),
          );
          await tester.pumpAndSettle();
          final field = find.byKey(const Key('message-input'));
          final editable = find.descendant(
            of: field,
            matching: find.byType(EditableText),
          );
          await tester.tap(field);
          await tester.pump();
          final before = tester.state<EditableTextState>(editable);
          final focus = tester.widget<TextField>(field).focusNode!;
          const value = TextEditingValue(
            text: 'nihao',
            selection: TextSelection.collapsed(offset: 5),
            composing: TextRange(start: 0, end: 5),
          );
          tester.testTextInput.updateEditingValue(value);
          await tester.pump();
          final clientCalls = tester.testTextInput.log
              .where((call) => call.method == 'TextInput.setClient')
              .length;
          final openHeight = size.height < 500 ? 220.0 : 330.0;
          for (final inset in [
            16.0,
            openHeight / 2,
            openHeight,
            openHeight - 20,
            0.0,
            openHeight,
          ]) {
            tester.view.viewInsets = FakeViewPadding(bottom: inset);
            await tester.pump(const Duration(milliseconds: 32));
            await tester.pump();
            expect(
              identical(tester.state<EditableTextState>(editable), before),
              true,
              reason: 'Insets must not recreate the editor',
            );
            expect(focus.hasFocus, true);
            expect(tester.testTextInput.isVisible, true);
            expect(tester.widget<TextField>(field).controller!.value, value);
            expect(tester.takeException(), isNull);
          }
          expect(
            tester.testTextInput.log
                .where((call) => call.method == 'TextInput.setClient')
                .length,
            clientCalls,
          );
          room.error = 'fixture sync error';
          room.workspace.changed();
          await tester.pump();
          expect(
            identical(tester.state<EditableTextState>(editable), before),
            true,
          );
          expect(focus.hasFocus, true);
          expect(
            tester.widget<TextField>(field).controller!.value.composing,
            value.composing,
          );
          tester.testTextInput.updateEditingValue(
            const TextEditingValue(
              text: '你好',
              selection: TextSelection.collapsed(offset: 2),
            ),
          );
          await tester.pump();
          expect(room.draft, '你好');
          await tester.pumpWidget(const SizedBox.shrink());
        },
        variant: const TargetPlatformVariant({TargetPlatform.android}),
      );
    }
  }
}
