import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:tsukuyomi_space_app/features/game/kaguya_assets.dart';
import 'package:tsukuyomi_space_app/features/game/kaguya_runtime.dart';

void _require(bool value, String message) {
  if (!value) throw StateError('Kaguya riding regression: $message');
}

void _frames(KaguyaRuntime vm, int count) {
  for (var i = 0; i < count; i++) {
    // Keep this offline fixture alive through random obstacles. No score API
    // or GameSession is created; the actual collision and ride scripts run.
    vm.setVariableByName('心情值', 1000);
    vm.advance(1 / 30);
    _require(vm.failure == null && vm.running, 'simulation stopped');
  }
}

void _resetReady(KaguyaRuntime vm) {
  _require(
    vm.failure == null && vm.running && !vm.paused,
    'restart did not recover',
  );
  _require(
    vm.cloneCount == 0 && vm.keys.isEmpty && !vm.mouseDown,
    'stale run state',
  );
  _require(vm.time == 0 && vm.score == 0, 'clock/score did not reset');
  _require(
    vm.sprites.firstWhere((s) => s.name == '开始游戏').visible,
    'start screen missing',
  );
  _require(
    !vm.sprites.firstWhere((s) => s.name == 'feichua').visible,
    'rider remained visible',
  );
  for (final name in ['攻击判定上', '攻击判定下', '碰撞上', '受伤碰撞', '飞船碰撞']) {
    final sensor = vm.sprites.firstWhere((s) => s.name == name);
    _require(
      (sensor.effects['ghost'] ?? 0) >= 100,
      '$name exposed on the first paint',
    );
  }
}

void _mount(KaguyaRuntime vm) {
  vm.startGame();
  _frames(vm, 150);
  vm.broadcast('黑1');
  // Advance ordinary stage progression to the real ship's spawn threshold,
  // then wait for its pixel-mask collision to initiate the 300-point ride.
  vm.setVariableByName('分数', 510);
  for (
    var i = 0;
    i < 120 && KaguyaRuntime.number(vm.variableByName('辉夜是否消失')) != 1;
    i++
  ) {
    _frames(vm, 1);
  }
  _require(
    KaguyaRuntime.number(vm.variableByName('辉夜是否消失')) == 1,
    'ship collision did not mount',
  );
  _require(vm.score >= 810, 'ship collision did not award points');
  _frames(vm, 6);
  _require(
    vm.sprites.firstWhere((s) => s.name == 'feichua').visible,
    'mounted rider missing',
  );
}

Map<String, dynamic> probeKaguyaHighDismount(KaguyaRuntime vm) {
  final models = <Map<String, dynamic>>[];
  for (final character in [1, 2, 4]) {
    vm.restart();
    _mount(vm);
    vm.setVariableByName('辉夜模型', character);
    vm.key('up arrow', true);
    _frames(vm, 45);
    vm.key('up arrow', false);
    final ship = vm.sprites.firstWhere((s) => s.name == 'feichua');
    _require(ship.y >= 64 && ship.y <= 70, 'high return fixture');
    _frames(vm, 420);
    final player = vm.sprites.firstWhere((s) => s.name == '辉夜');
    _require(
      KaguyaRuntime.number(vm.variableByName('辉夜是否消失')) == 0 &&
          !ship.visible &&
          player.visible,
      'high return did not finish',
    );
    _require(
      KaguyaRuntime.number(vm.variableByName('跳起？')) == 0 &&
          player.y >= -36 &&
          player.y <= -30,
      'high return did not land',
    );
    final costumes = <String>{};
    for (var i = 0; i < 45; i++) {
      _frames(vm, 1);
      costumes.add('${player.currentCostume['name']}');
    }
    _require(
      costumes.length > 1 && !costumes.contains(character == 1 ? '17' : '47'),
      'running animation did not resume',
    );
    _require(
      !vm.executionState.any((s) => s['sprite'] == '辉夜' && s['hat'] == 'ET'),
      'stale return animation hat',
    );
    models.add({
      'model': character,
      'y': player.y,
      'running_costumes': costumes.toList()..sort(),
    });
  }
  return {'models': models};
}

Map<String, dynamic> probeKaguyaSkyContinuity(KaguyaRuntime vm) {
  var checked = 0, wraps = 0;
  for (final speed in [7, 8, 11, 18, 24]) {
    vm.restart();
    vm.startGame();
    _frames(vm, 150);
    vm.broadcast('黑1');
    int? previous;
    for (var i = 0; i < 300; i++) {
      vm.setVariableByName('背景速度（我跑步速度', speed);
      _frames(vm, 1);
      final skies = vm.drawOrder
          .where((s) => s.name == 'sky' && s.visible && !s.deleted)
          .toList();
      if (skies.isEmpty) continue;
      final id = skies.last.cloneId;
      if (previous != null && previous != id) wraps++;
      previous = id;
      for (final x in [-239.0, 0.0, 239.0]) {
        _require(
          skies.any((s) => s.bounds.contains(ui.Offset(x, 160))),
          'sky gap at speed=$speed frame=$i x=$x',
        );
      }
      _require(
        vm.drawOrder.map((s) => s.layer).toSet().length == vm.drawOrder.length,
        'duplicate drawable order',
      );
      checked++;
    }
  }
  _require(checked >= 1400 && wraps >= 10, 'sky fixture did not wrap');
  return {
    'checked_frames': checked,
    'wraps': wraps,
    'gaps': 0,
    'speeds': [7, 8, 11, 18, 24],
  };
}

/// Shared by flutter_tester and the actual Android Release/native GPU probe.
/// Yields at paints needed to catch transparent collision costumes.
Iterable<String> exerciseKaguyaRiding(KaguyaRuntime vm) sync* {
  vm.restart();
  _resetReady(vm);
  yield 'opening';
  for (var run = 0; run < 3; run++) {
    _mount(vm);
    final ship = vm.sprites.firstWhere((s) => s.name == 'feichua');
    final before = ship.y;
    vm.key('up arrow', true);
    _frames(vm, 45);
    vm.key('up arrow', false);
    _require(ship.y > before && ship.y <= 70, 'up movement');
    vm.key('down arrow', true);
    _frames(vm, 90);
    vm.key('down arrow', false);
    _require(ship.y < before && ship.y >= -114, 'down movement');
    yield 'riding-$run';
    vm.togglePause();
    final stopped = vm.time;
    for (var i = 0; i < 30; i++) {
      vm.advance(1 / 30);
    }
    _require(vm.time == stopped, 'paused ride kept moving');
    vm.togglePause();
    final score = vm.score;
    _frames(vm, 180);
    _require(vm.score >= score, 'ride score went backwards');
    for (var i = 0; i < 45 && (ship.effects['brightness'] ?? 0) != 10; i++) {
      _frames(vm, 1);
    }
    _require(ship.effects['brightness'] == 10, 'dismount flash did not run');
    yield 'flashing-$run';
    _frames(vm, 90);
    _require(
      KaguyaRuntime.number(vm.variableByName('辉夜是否消失')) == 0 && !ship.visible,
      'ride did not finish',
    );
    _require(
      KaguyaRuntime.number(vm.variableByName('可以操作吗')) == 1,
      'ordinary controls did not return',
    );
    _require(
      vm.sprites.firstWhere((s) => s.name == '辉夜').visible,
      'Kaguya did not return',
    );
    yield 'dismounted-$run';
    vm.restart();
    _resetReady(vm);
    yield 'restart-after-dismount-$run';
    _mount(vm);
    vm.key('up arrow', true);
    vm.togglePause();
    vm.restart();
    _resetReady(vm);
    yield 'restart-during-riding-$run';
    // Ensure another run reaches the same collision, then exercise source
    // game-over scripts without retaining that run's sprites or waits.
    _mount(vm);
    vm.setVariableByName('心情值', 0);
    for (var i = 0; i < 180; i++) {
      vm.advance(1 / 30);
    }
    _require(
      vm.sprites.firstWhere((s) => s.name == '游戏结束').visible,
      'death while riding did not finish',
    );
    vm.restart();
    _resetReady(vm);
    yield 'restart-after-death-$run';
  }
}

Future<Map<String, dynamic>> probeKaguyaRidingPixels(
  KaguyaRuntime vm,
  KaguyaAssets assets,
) async {
  Uint8List? opening;
  final differences = <int>[];
  var phases = 0;
  for (final phase in exerciseKaguyaRiding(vm)) {
    final recorder = ui.PictureRecorder();
    KaguyaPainter(vm, assets).paint(Canvas(recorder), const Size(480, 360));
    final picture = recorder.endRecording();
    final image = await picture.toImage(480, 360);
    try {
      final pixels = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!.buffer.asUint8List();
      if (phase == 'opening') opening = Uint8List.fromList(pixels);
      if (phase.startsWith('restart-')) {
        var changed = 0;
        for (var i = 0; i < pixels.length; i++) {
          if (pixels[i] != opening![i]) changed++;
        }
        differences.add(changed);
        _require(changed == 0, '$phase changed $changed opening bytes');
      }
      _require(pixels.toSet().length > 30, '$phase drew an empty image');
      phases++;
    } finally {
      image.dispose();
      picture.dispose();
    }
  }
  return {'phases': phases, 'restart_different_bytes': differences};
}
