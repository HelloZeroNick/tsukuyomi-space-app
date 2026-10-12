import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:tsukuyomi_live2d/tsukuyomi_live2d.dart';

/// Owns the single clock/model/painter shared by the embedded and full scene.
class Live2DSceneController {
  // Apply the cap even to an existing full-quality preference. Two RGBA8
  // atlases occupy 32 MiB instead of 72/128 MiB at 3072/4096 pixels.
  static int textureLimitFor(String quality) => 2048;
  static int rasterBudgetFor(String quality, {required bool mobile}) =>
      switch (quality) {
        'full' => 900000,
        'economy' => mobile ? 225000 : 450000,
        _ => mobile ? 450000 : 600000,
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
  int _rasterSlow = 0, _rasterGood = 0, _budgetStep = 0;
  double _refreshRate = 60;
  bool _active = false;
  int get effectiveRasterBudget {
    final base = rasterBudgetFor(_quality, mobile: mobile);
    return mobile ? (base * const [1.0, .75, .5][_budgetStep]).round() : base;
  }

  int get fps {
    final limit = _frameLimit == 0 ? (mobile ? 30 : 60) : _frameLimit;
    return _slow >= 12 ? math.min(limit, mobile ? 20 : 30) : limit;
  }

  void configure({
    String quality = 'auto',
    int frameLimit = 0,
    double? pixelRatio,
    double? refreshRate,
  }) {
    if (_quality != quality) {
      _budgetStep = _rasterSlow = _rasterGood = 0;
    }
    _quality = quality;
    if (pixelRatio != null && pixelRatio.isFinite && pixelRatio > 0) {
      _pixelRatio = pixelRatio;
    }
    _frameLimit = const [30, 60].contains(frameLimit) ? frameLimit : 0;
    if (refreshRate != null && refreshRate.isFinite && refreshRate > 0) {
      _refreshRate = refreshRate.clamp(30, 240);
    }
    painter
      ?..pixelRatio = _pixelRatio
      ..rasterPixelBudget = effectiveRasterBudget;
  }

  void attach(Live2DModel value) {
    painter?.dispose();
    model?.dispose();
    model = value;
    painter = Live2DPainter(value);
    configure(quality: _quality, frameLimit: _frameLimit);
  }

  set active(bool value) {
    if (_active == value) return;
    _active = value;
    _last = null;
    _nextFrame = null;
    _rasterSlow = _rasterGood = 0;
    if (value && model != null) {
      ticker.start();
    } else {
      ticker.stop();
    }
  }

  void _tick(Duration elapsed) {
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
    onTick(_seconds, delta);
  }

  void _timings(List<FrameTiming> timings) {
    if (!_active) return;
    for (final frame in timings) {
      if (mobile) {
        // Chat/IME animations use the display cadence even while the model is
        // capped at 30fps. Reduce compositing work, keeping both atlases at 2K.
        final budget = 1000000 / _refreshRate;
        final raster = frame.rasterDuration.inMicroseconds;
        if (raster > budget * 1.1) {
          _rasterGood = 0;
          if (++_rasterSlow >= 8) {
            _rasterSlow = 0;
            _budgetStep = math.min(2, _budgetStep + 1);
            painter?.rasterPixelBudget = effectiveRasterBudget;
          }
        } else if (raster < budget * .7) {
          if (++_rasterGood >= 180) {
            _rasterGood = _rasterSlow = 0;
            _budgetStep = math.max(0, _budgetStep - 1);
            painter?.rasterPixelBudget = effectiveRasterBudget;
          }
        } else {
          _rasterGood = 0;
        }
      }
      final work = math.max(
        frame.buildDuration.inMicroseconds,
        frame.rasterDuration.inMicroseconds,
      );
      if (work > (mobile ? 33333 : 16667)) {
        _slow = (_slow + 1).clamp(0, 12);
        _good = 0;
      } else if (work < (mobile ? 24000 : 12000)) {
        if (++_good >= 240) {
          _slow = 0;
          _good = 0;
        }
      } else {
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
