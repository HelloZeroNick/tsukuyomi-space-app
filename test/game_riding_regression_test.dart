import 'dart:ui' as ui;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/features/game/kaguya_assets.dart';
import 'package:tsukuyomi_space_app/features/game/kaguya_runtime.dart';

import 'game_native_test.dart' show shippedRuntime, frames;
import 'support/kaguya_riding_probe.dart';

void main() {
  test('sky clones cover the stage during five scrolling speeds and wraps', () {
    final vm = shippedRuntime();
    addTearDown(vm.dispose);
    final result = probeKaguyaSkyContinuity(vm);
    expect(result['gaps'], 0);
    expect(result['checked_frames'], greaterThanOrEqualTo(1400));
    expect(result['wraps'], greaterThanOrEqualTo(10));
  });
  test('native shared high-dismount fixture verifies all character models', () {
    final vm = shippedRuntime();
    addTearDown(vm.dispose);
    expect((probeKaguyaHighDismount(vm)['models'] as List).length, 3);
  });
  for (final character in [1, 2, 4]) {
    test(
      'high dismount lands and resumes model $character running animation',
      () {
        final vm = shippedRuntime();
        addTearDown(vm.dispose);
        vm.restart();
        vm.startGame();
        void step() {
          vm.setVariableByName('心情值', 1000);
          vm.advance(1 / 30);
        }

        for (var i = 0; i < 150; i++) {
          step();
        }
        vm.broadcast('黑1');
        vm.setVariableByName('分数', 510);
        for (
          var i = 0;
          i < 120 && KaguyaRuntime.number(vm.variableByName('辉夜是否消失')) != 1;
          i++
        ) {
          step();
        }
        expect(KaguyaRuntime.number(vm.variableByName('辉夜是否消失')), 1);
        vm.setVariableByName('辉夜模型', character);
        vm.key('up arrow', true);
        for (var i = 0; i < 45; i++) {
          step();
        }
        vm.key('up arrow', false);
        final ship = vm.sprites.firstWhere((s) => s.name == 'feichua');
        expect(ship.y, inInclusiveRange(64, 70));
        final player = vm.sprites.firstWhere((s) => s.name == '辉夜');
        for (var i = 0; i < 400; i++) {
          step();
        }
        expect(KaguyaRuntime.number(vm.variableByName('辉夜是否消失')), 0);
        expect(KaguyaRuntime.number(vm.variableByName('跳起？')), 0);
        expect(ship.visible, false);
        expect(player.y, inInclusiveRange(-36, -30));
        final costumes = <String>{};
        for (var i = 0; i < 45; i++) {
          step();
          costumes.add('${player.currentCostume['name']}');
        }
        expect(
          costumes.length,
          greaterThan(1),
          reason: 'The running animation must advance.',
        );
        expect(costumes, isNot(contains(character == 1 ? '17' : '47')));
        expect(
          vm.executionState.where(
            (t) => t['sprite'] == '辉夜' && t['hat'] == 'ET',
          ),
          isEmpty,
        );
        expect(vm.failure, isNull);
      },
    );
  }

  test('120 Hz host only publishes the original 30 Hz simulation frames', () {
    final vm = shippedRuntime();
    addTearDown(vm.dispose);
    vm.restart();
    var paints = 0;
    vm.addListener(() => paints++);
    for (var i = 0; i < 120; i++) {
      vm.advance(1 / 120);
    }
    expect(paints, 30);
  });
  test(
    'three complete collision-triggered rides, pause, dismount and restart',
    () {
      final vm = shippedRuntime();
      addTearDown(vm.dispose);
      expect(exerciseKaguyaRiding(vm).toList(), hasLength(19));
      expect(vm.failure, isNull);
      expect(vm.unknownOpcodes, isEmpty);
    },
  );

  test('restart restores sprite-local state, physics and fractional clock', () {
    final vm = shippedRuntime();
    addTearDown(vm.dispose);
    vm.restart();
    vm.startGame();
    frames(vm, 150);
    final ship = vm.sprites.firstWhere((s) => s.name == 'feichua');
    ship.text = 'stale text';
    ship.stretchX = 40;
    ship.x = 77;
    vm.gravityX = 3;
    vm.gravityY = 2;
    vm.physics.gravity(3, 2);
    vm.boxed = false;
    vm.physics.setStage(false);
    vm.physics.enable(ship);
    vm.advance(1 / 60);
    vm.key('up arrow', true);
    vm.tapKey('space');
    vm.mouseDown = true;
    var notifications = 0;
    vm.addListener(() => notifications++);
    vm.restart();
    expect(notifications, 1, reason: 'No partial reset may be published.');
    expect(ship.text, isEmpty);
    expect(ship.stretchX, 100);
    expect(ship.x, 0);
    expect(ship.physics, false);
    expect(vm.physics.world.gravity.x, 0);
    expect(vm.physics.world.gravity.y, -10);
    expect(vm.boxed, true);
    expect(vm.keys, isEmpty);
    expect(vm.mouseDown, false);
    expect(vm.cloneCount, 0);
    expect(vm.time, 0);
    vm.advance(1 / 60);
    expect(vm.time, 0, reason: 'The preceding half-frame must not carry over.');
  });

  testWidgets('a riding script failure cannot stop the Flutter frame clock', (
    tester,
  ) async {
    final vm = shippedRuntime();
    addTearDown(vm.dispose);
    vm.restart();
    vm.startGame();
    frames(vm, 150);
    vm.broadcast('黑1');
    vm.setVariableByName('分数', 510);
    var failSound = true, stoppedSounds = 0, ticks = 0;
    vm.onStopSounds = () => stoppedSounds++;
    vm.onSound = (sprite, _, _) {
      if (sprite.name == 'feichuan' && failSound) {
        throw StateError('injected native callback failure at mount');
      }
    };
    final ticker = Ticker((_) {
      ticks++;
      vm.setVariableByName('心情值', 1000);
      vm.advance(1 / 30);
    })..start();
    addTearDown(ticker.dispose);
    for (var i = 0; i < 120 && vm.failure == null; i++) {
      await tester.pump(const Duration(milliseconds: 34));
    }
    expect(tester.takeException(), isNull);
    expect(vm.failure?.error, isA<StateError>());
    expect(vm.failure?.sprite, 'feichuan');
    expect(vm.paused, true);
    expect(vm.running, false);
    expect(stoppedSounds, 1);
    final before = ticks;
    await tester.pump(const Duration(milliseconds: 34));
    expect(ticks, greaterThan(before));
    failSound = false;
    vm.restart();
    expect(vm.failure, isNull);
    expect(vm.paused, false);
    expect(vm.running, true);
    final resetTime = vm.time;
    await tester.pump(const Duration(milliseconds: 34));
    expect(vm.time, greaterThan(resetTime));
    expect(tester.takeException(), isNull);
    ticker.stop();
  });

  test('runtime reporter guard handles a graph changed after validation', () {
    final vm = shippedRuntime();
    addTearDown(vm.dispose);
    vm.restart();
    final ship = vm.sprites.firstWhere((s) => s.name == 'feichua');
    final condition = ship.blocks['tsukuyomi-flight-up-in-bounds'] as Map;
    final inputs = condition['inputs'] as Map;
    final original = inputs['OPERAND1'];
    inputs['OPERAND1'] = [2, 'tsukuyomi-flight-up-in-bounds'];
    vm.broadcast('辉夜消失');
    expect(() => frames(vm, 12), returnsNormally);
    expect(vm.failure?.error, isA<FormatException>());
    expect(vm.paused, true);
    inputs['OPERAND1'] = original;
    vm.restart();
    vm.broadcast('辉夜消失');
    frames(vm, 12);
    expect(vm.failure, isNull);
    expect(vm.running, true);
  });

  testWidgets(
    'restart first paint matches a fresh opening after every riding stage',
    (tester) async {
      late KaguyaAssets assets;
      await tester.runAsync(() async => assets = await KaguyaAssets.load());
      final vm = assets.runtime(random: math.Random(7));
      addTearDown(vm.dispose);
      addTearDown(assets.dispose);
      await tester.runAsync(() async {
        final result = await probeKaguyaRidingPixels(vm, assets);
        expect(result['phases'], 19);
        expect(result['restart_different_bytes'], List.filled(9, 0));
      });
      await tester.pumpWidget(
        MaterialApp(
          home: CustomPaint(
            size: const ui.Size(480, 360),
            painter: KaguyaPainter(vm, assets),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
