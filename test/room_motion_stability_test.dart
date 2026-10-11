import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_live2d/tsukuyomi_live2d.dart';
import 'package:tsukuyomi_space_app/live2d/character_stage.dart';
import 'package:tsukuyomi_space_app/live2d/room_animation.dart';

import 'support/fakes.dart';

void main() {
  testWidgets(
    'PC Room background pixels and layout remain fixed during every motion',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 960);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final model = await tester.runAsync(loadLive2D);
      expect(model, isNotNull);
      final animation = RoomAnimation();
      addTearDown(animation.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CharacterStage(
              voice: SilentVoice(),
              animation: animation,
              modelLoader: () async => model!,
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      final backdrop = find.byKey(const Key('room-backdrop'));
      final character = find.byKey(const Key('room-character-viewport'));
      final fixedBackdrop = tester.getRect(backdrop),
          fixedCharacter = tester.getRect(character);
      Future<Uint8List> pixels() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(backdrop);
        final image = await tester.runAsync(() => boundary.toImage());
        try {
          final bytes = await tester.runAsync(() => image!.toByteData());
          return Uint8List.fromList(bytes!.buffer.asUint8List());
        } finally {
          image!.dispose();
        }
      }

      final before = await pixels();
      for (final action in [
        'Nod',
        'Shake head',
        'Lean in',
        'Lean left',
        'Lean right',
        'Sway',
        'Bounce',
        'Emphasis',
      ]) {
        await tester.tap(find.byTooltip('动作'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text(action));
        await tester.pump();
        for (var frame = 0; frame < 20; frame++) {
          await tester.pump(const Duration(milliseconds: 32));
        }
        expect(animation.current, isNotNull, reason: action);
        expect(tester.getRect(backdrop), fixedBackdrop, reason: action);
        expect(tester.getRect(character), fixedCharacter, reason: action);
        expect(await pixels(), before, reason: '$action moved the background');
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
    skip: !const bool.fromEnvironment('RUN_CUBISM_TESTS'),
  );
}
