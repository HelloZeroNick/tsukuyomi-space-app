import 'dart:async';

import 'package:flutter/foundation.dart';

/// A single interaction bus shared with the scene clock. Ballistic scrolling,
/// typing bursts and changing IME insets inform cadence without pausing animation.
class RoomInteraction extends ValueNotifier<bool> {
  RoomInteraction() : super(false);
  bool _scrolling = false, _typing = false, _keyboard = false;
  Timer? _typingTimer, _keyboardTimer;

  void scrolling(bool active) {
    _scrolling = active;
    _update();
  }

  void typing() {
    _typingTimer?.cancel();
    _typing = true;
    _update();
    _typingTimer = Timer(const Duration(milliseconds: 120), () {
      _typing = false;
      _update();
    });
  }

  void keyboardTransition() {
    _keyboardTimer?.cancel();
    _keyboard = true;
    _update();
    _keyboardTimer = Timer(const Duration(milliseconds: 180), () {
      _keyboard = false;
      _update();
    });
  }

  void _update() => value = _scrolling || _typing || _keyboard;

  @override
  void dispose() {
    _typingTimer?.cancel();
    _keyboardTimer?.cancel();
    super.dispose();
  }
}
