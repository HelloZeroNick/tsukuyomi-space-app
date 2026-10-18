import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:tsukuyomi_live2d/tsukuyomi_live2d.dart';

/// Owns the single clock/model/painter shared by the embedded and full scene.
class Live2DSceneController {
  // Keep a real detail tier. Downscaling every atlas to 2K permanently loses
  // hair/eye detail before the renderer sees it, even on high-density phones.
  static int textureLimitFor(String quality) => switch (quality) {
    'economy' => 2048,
    'full' => 4096,
    _ => 3072,
  };
  static int rasterBudgetFor(String quality, {required bool mobile}) =>
      switch (quality) {
        'full' => 0, // Native device density; no intermediate downsampling.
        'economy' => mobile ? 225000 : 450000,
        _ => 2000000,
      };
  Live2DSceneController({
    required TickerProvider vsync,
    required this.mobile,
    required this.onTick,
  }) {
    ticker = vsync.createTicker(_tick);
    SchedulerBinding.instance.addTimingsCallback(_timings);
  }
  final bool mobile;
  final void Function(double seconds, double delta) onTick;
  late final Ticker ticker;
  Live2DModel? model;
  Live2DPainter? painter;
  Duration? _last;
  int? _nextFrame;
  int _lastFps = 0, _frameLimit = 0;
  String _quality = 'auto';
  double _pixelRatio = 1;
  double _seconds = 0;
  int _slow = 0, _good = 0;
  double _refreshRate = 60;
  bool _active = false, _interacting = false;
  int _modelFrames = 0, _interactionTransitions = 0, _backpressureYields = 0;

  /// Interaction keeps animation alive. Native GPU work stays on its worker;
  /// Canvas temporarily caps cadence while preserving the selected resolution.
  bool get active => _active;
  bool get interacting => _interacting;
  bool get running => _active && model != null;
  int get modelFrames => _modelFrames;
  int get interactionTransitions => _interactionTransitions;
  int get backpressureYields => _backpressureYields;
  double get activeSeconds => _seconds;
  int get effectiveRasterBudget => rasterBudgetFor(_quality, mobile: mobile);

  int get _targetFps => math.min(
    _frameLimit == 0 ? (_quality == 'economy' ? 30 : 60) : _frameLimit,
    _refreshRate.round(),
  );

  int get fps {
    final limit = _interacting && model is! GpuLive2DModel
        ? math.min(_targetFps, 30)
        : _targetFps;
    return _slow >= 12 ? math.min(limit, _targetFps > 30 ? 30 : 20) : limit;
  }

  void configure({
    String quality = 'auto',
    int frameLimit = 0,
    double? pixelRatio,
    double? refreshRate,
  }) {
    final nextLimit = const [30, 60].contains(frameLimit) ? frameLimit : 0;
    if (_quality != quality || _frameLimit != nextLimit) {
      _slow = _good = 0;
    }
    _quality = quality;
    if (pixelRatio != null && pixelRatio.isFinite && pixelRatio > 0) {
      _pixelRatio = pixelRatio;
    }
    _frameLimit = nextLimit;
    if (refreshRate != null && refreshRate.isFinite && refreshRate > 0) {
      _refreshRate = refreshRate.clamp(30, 240);
    }
    painter
      ?..pixelRatio = _pixelRatio
      ..rasterPixelBudget = effectiveRasterBudget;
  }

  void attach(Live2DModel value) {
    ticker.stop();
    _resetClock();
    painter?.dispose();
    model?.dispose();
    model = value;
    painter = value is GpuLive2DModel
        ? null
        : Live2DPainter(value, asynchronousRasterization: true);
    painter?.renderingEnabled = _active;
    configure(quality: _quality, frameLimit: _frameLimit);
    _syncClock();
  }

  set active(bool value) {
    if (_active == value) return;
    _active = value;
    painter?.renderingEnabled = value;
    _slow = _good = 0;
    _syncClock();
  }

  set interacting(bool value) {
    if (_interacting == value) return;
    _interacting = value;
    if (value && _active) _interactionTransitions++;
    // Do not stop/reset the clock: repeated gestures and typing must not starve
    // the next frame or stall queued actions and speech mouth parameters.
  }

  void _resetClock() {
    _last = null;
    _nextFrame = null;
    _lastFps = 0;
  }

  void _syncClock() {
    _resetClock();
    if (running) {
      ticker.start();
    } else {
      ticker.stop();
    }
  }

  void _tick(Duration elapsed) {
    if (!running) return;
    // The GPU is still preparing the previous coherent snapshot. Updating
    // Cubism again would consume UI time for geometry that cannot be displayed.
    if (painter?.rasterizationPending == true ||
        (model is GpuLive2DModel && (model as GpuLive2DModel).framePending)) {
      _backpressureYields++;
      return;
    }
    if (_last == null) {
      _last = elapsed;
      _nextFrame = elapsed.inMicroseconds + (1000000 / fps).round();
      _lastFps = fps;
      return;
    }
    final now = elapsed.inMicroseconds, interval = (1000000 / fps).round();
    if (_lastFps != fps) {
      _nextFrame = _last!.inMicroseconds + interval;
      _lastFps = fps;
    }
    if (now < _nextFrame! - 1000) return;
    final micros = (elapsed - _last!).inMicroseconds;
    _last = elapsed;
    _nextFrame = _nextFrame! + interval;
    if (_nextFrame! <= now) {
      _nextFrame =
          _nextFrame! + ((now - _nextFrame!) ~/ interval + 1) * interval;
    }
    final delta = (micros / 1000000).clamp(0.0, .05);
    _seconds += delta;
    _modelFrames++;
    onTick(_seconds, delta);
  }

  void _timings(List<FrameTiming> timings) {
    // Chat/IME build costs must not permanently throttle the model. In-flight
    // backpressure still bounds native/Canvas work during these interactions.
    if (!running || _interacting) return;
    for (final frame in timings) {
      // Judge the requested animation cadence, not a 120/144Hz display's
      // shorter UI budget. Pressure lowers cadence, never silently blurs the
      // selected quality. Include snapshot latency: toImage work can fall
      // outside Flutter's visible-frame raster timings.
      final snapshotWork = model is GpuLive2DModel
          ? ((model as GpuLive2DModel).frameMilliseconds * 1000).round()
          : (model!.updateMilliseconds * 1000).round() +
                (painter?.lastPreparationMicros ?? 0) +
                (painter?.lastRasterizationMicros ?? 0);
      final work = math.max(
        snapshotWork,
        math.max(
          frame.buildDuration.inMicroseconds,
          frame.rasterDuration.inMicroseconds,
        ),
      );
      final budget = 1000000 / _targetFps;
      if (work > budget * 1.1) {
        _slow = (_slow + 1).clamp(0, 12);
        _good = 0;
      } else if (work < budget * .7) {
        if (_slow < 12) _slow = 0;
        if (++_good >= 240) {
          _slow = 0;
          _good = 0;
        }
      } else {
        if (_slow < 12) _slow = 0;
        _good = 0;
      }
    }
  }

  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_timings);
    ticker.dispose();
    painter?.dispose();
    model?.dispose();
    model = null;
  }
}
