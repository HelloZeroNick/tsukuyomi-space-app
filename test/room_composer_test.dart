import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/features/room/room_composer.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';

import 'support/fakes.dart';

void main() {
  Future<RoomController> mount(
    WidgetTester tester,
    FakeChat chat, {
    bool mobile = false,
  }) async {
    final c = RoomController(
      storage: MemoryStorage(),
      chat: chat,
      site: FakeSite(),
      voice: SilentVoice(),
    );
    await c.initialize();
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: RoomComposer(controller: c, mobile: mobile, onAttach: () {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return c;
  }

  final field = find.byKey(const Key('message-input'));
  TextEditingController input(WidgetTester tester) =>
      tester.widget<TextField>(field).controller!;

  for (final mobile in [false, true]) {
    for (final failure in [false, true]) {
      testWidgets(
        '${failure ? 'failed' : 'cancelled'} send restores the saved composer draft mobile=$mobile',
        (tester) async {
          final chat = FakeChat()..controlled = true;
          final c = await mount(tester, chat, mobile: mobile);
          await tester.enterText(field, '保留未完成的消息');
          await tester.pump();
          await tester.tap(find.byType(FilledButton));
          await tester.pump();
          expect(c.generating, true);
          expect(input(tester).text, isEmpty);
          expect(chat.stream, isNotNull);
          if (failure) {
            chat.stream!.addError(const ApiFailure('fixture API failure'));
            await chat.stream!.close();
          } else {
            c.stop();
          }
          await tester.pumpAndSettle();
          expect(c.generating, false);
          expect(c.turns, isEmpty);
          expect(c.draft, '保留未完成的消息');
          expect(input(tester).text, c.draft);
          expect(input(tester).selection.extentOffset, c.draft.length);
          expect(input(tester).value.composing, TextRange.empty);
          expect(await c.storage.draft(c.scope), c.draft);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  testWidgets('oversized rejected input stays editable with its selection', (
    tester,
  ) async {
    final c = await mount(tester, FakeChat());
    final oversized = List.filled(12001, '超').join();
    await tester.enterText(field, oversized);
    input(tester).selection = const TextSelection.collapsed(offset: 12);
    await tester.pump();
    final value = input(tester).value;
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(c.generating, false);
    expect(c.turns, isEmpty);
    expect(c.error, contains('12000'));
    expect(input(tester).value, value);
    expect(c.draft, oversized);
    expect(tester.widget<TextField>(field).readOnly, false);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('unrelated updates preserve Chinese selection and composing', (
    tester,
  ) async {
    final c = await mount(tester, FakeChat());
    await tester.tap(field);
    const composing = TextEditingValue(
      text: 'nihao',
      selection: TextSelection.collapsed(offset: 3),
      composing: TextRange(start: 0, end: 5),
    );
    tester.testTextInput.updateEditingValue(composing);
    await tester.pump();
    final editable = find.descendant(
      of: field,
      matching: find.byType(EditableText),
    );
    final state = tester.state<EditableTextState>(editable);
    final clients = tester.testTextInput.log
        .where((call) => call.method == 'TextInput.setClient')
        .length;
    c.workspace.status = 'fixture unrelated update';
    c.workspace.changed();
    await tester.pump();
    expect(input(tester).value, composing);
    expect(identical(tester.state<EditableTextState>(editable), state), true);
    expect(
      tester.testTextInput.log
          .where((call) => call.method == 'TextInput.setClient')
          .length,
      clients,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(c.generating, false);
    expect(c.turns, isEmpty);
    expect(input(tester).value.composing, composing.composing);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '你好',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(c.turns.single.user, '你好');
    expect(input(tester).text, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
