import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/desktop_window.dart';

void main() {
  test(
    'fullscreen serializes clicks, follows native state and survives errors',
    () async {
      bool native = false, fail = false;
      final pending = Completer<void>();
      var calls = 0;
      final controller = DesktopWindowController(
        supported: true,
        read: () async => native,
        set: (value) async {
          calls++;
          if (fail) throw StateError('window unavailable');
          if (calls == 1) await pending.future;
          native = value;
        },
      );
      addTearDown(controller.dispose);
      final first = controller.toggle();
      await controller.toggle();
      expect(calls, 1);
      pending.complete();
      await first;
      expect(controller.fullscreen, true);
      fail = true;
      await controller.toggle();
      expect(controller.fullscreen, true);
      expect(controller.error, isNotEmpty);
      fail = false;
      await controller.toggle();
      expect(controller.fullscreen, false);
      expect(controller.error, isEmpty);
      controller.onWindowEnterFullScreen();
      expect(controller.fullscreen, true);
      controller.onWindowLeaveFullScreen();
      expect(controller.fullscreen, false);
    },
  );

  testWidgets('desktop button, F11 and Escape control the same window', (
    tester,
  ) async {
    var native = false;
    final window = DesktopWindowController(
      supported: true,
      read: () async => native,
      set: (value) async => native = value,
    );
    addTearDown(window.dispose);
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => DesktopWindowScope(
          controller: window,
          child: DesktopWindowShortcuts(controller: window, child: child!),
        ),
        home: Scaffold(
          body: Focus(
            focusNode: focus,
            autofocus: true,
            child: const DesktopFullscreenButton(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('desktop-fullscreen')));
    await tester.pumpAndSettle();
    expect(native, true);
    focus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(native, false);
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pumpAndSettle();
    expect(native, true);
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pumpAndSettle();
    expect(native, false);
  });

  testWidgets('mobile does not display or invoke desktop window APIs', (
    tester,
  ) async {
    final window = DesktopWindowController(
      supported: false,
      read: () async => throw StateError('must not read window'),
      set: (_) async => throw StateError('must not set window'),
    );
    addTearDown(window.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: DesktopWindowScope(
          controller: window,
          child: const DesktopFullscreenButton(),
        ),
      ),
    );
    expect(find.byKey(const Key('desktop-fullscreen')), findsNothing);
    await window.toggle();
    await window.refresh();
    expect(window.error, isEmpty);
  });
}
