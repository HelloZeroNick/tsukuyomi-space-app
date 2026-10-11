import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

/// Window state belongs to the app, so navigation never recreates the window.
class DesktopWindowController extends ChangeNotifier with WindowListener {
  DesktopWindowController({
    required this.supported,
    required this.read,
    required this.set,
  });

  final bool supported;
  final Future<bool> Function() read;
  final Future<void> Function(bool) set;
  bool fullscreen = false, busy = false, _disposed = false;
  String error = '';
  bool _nativeListener = false;

  static Future<DesktopWindowController> create() async {
    final supported =
        !kIsWeb &&
        const {
          TargetPlatform.windows,
          TargetPlatform.macOS,
          TargetPlatform.linux,
        }.contains(defaultTargetPlatform);
    final controller = DesktopWindowController(
      supported: supported,
      read: windowManager.isFullScreen,
      set: windowManager.setFullScreen,
    );
    if (supported) {
      try {
        await windowManager.ensureInitialized();
        windowManager.addListener(controller);
        controller._nativeListener = true;
        await controller.refresh();
      } catch (_) {
        controller.error = '窗口全屏暂不可用，请重试';
      }
    }
    return controller;
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> refresh() async {
    if (!supported || _disposed) return;
    try {
      final value = await read();
      if (!_disposed && value != fullscreen) {
        fullscreen = value;
        _changed();
      }
    } catch (_) {}
  }

  Future<void> toggle() => setFullscreen(!fullscreen);
  Future<void> setFullscreen(bool value) async {
    if (!supported || _disposed || busy || value == fullscreen) return;
    busy = true;
    error = '';
    _changed();
    try {
      await set(value);
      if (!_disposed) fullscreen = await read();
    } catch (_) {
      if (!_disposed) error = '窗口全屏暂不可用，请重试';
    } finally {
      busy = false;
      _changed();
    }
  }

  @override
  void onWindowEnterFullScreen() {
    fullscreen = true;
    _changed();
  }

  @override
  void onWindowLeaveFullScreen() {
    fullscreen = false;
    _changed();
  }

  @override
  void onWindowFocus() => refresh();

  @override
  void dispose() {
    _disposed = true;
    if (_nativeListener) windowManager.removeListener(this);
    super.dispose();
  }
}

class DesktopWindowScope extends InheritedWidget {
  const DesktopWindowScope({
    super.key,
    required this.controller,
    required super.child,
  });
  final DesktopWindowController? controller;
  static DesktopWindowController? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<DesktopWindowScope>()?.controller;
  @override
  bool updateShouldNotify(DesktopWindowScope oldWidget) =>
      controller != oldWidget.controller;
}

class DesktopWindowShortcuts extends StatelessWidget {
  const DesktopWindowShortcuts({
    super.key,
    required this.controller,
    required this.child,
  });
  final DesktopWindowController? controller;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final window = controller;
    if (window == null || !window.supported) return child;
    return ListenableBuilder(
      listenable: window,
      child: child,
      builder: (context, child) => CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.f11): window.toggle,
          const SingleActivator(
            LogicalKeyboardKey.keyF,
            meta: true,
            control: true,
          ): window.toggle,
          if (window.fullscreen)
            const SingleActivator(LogicalKeyboardKey.escape): () =>
                window.setFullscreen(false),
        },
        child: child!,
      ),
    );
  }
}

String desktopFullscreenLabel(BuildContext context, [bool exit = false]) =>
    switch (Localizations.localeOf(context).languageCode) {
      'en' => exit ? 'Exit fullscreen' : 'Fullscreen window',
      'ja' => exit ? '全画面を終了' : 'ウィンドウを全画面表示',
      _ => exit ? '退出窗口全屏' : '窗口全屏',
    };

Future<void> toggleDesktopFullscreen(BuildContext context) async {
  final window = DesktopWindowScope.maybeOf(context);
  if (window == null) return;
  await window.toggle();
  if (context.mounted && window.error.isNotEmpty) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(switch (Localizations.localeOf(context).languageCode) {
          'en' => 'Fullscreen is unavailable. Please try again.',
          'ja' => '全画面表示を利用できません。もう一度お試しください。',
          _ => window.error,
        }),
      ),
    );
  }
}

class DesktopFullscreenButton extends StatelessWidget {
  const DesktopFullscreenButton({super.key});
  @override
  Widget build(BuildContext context) {
    final window = DesktopWindowScope.maybeOf(context);
    if (window == null || !window.supported) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: window,
      builder: (context, _) => IconButton(
        key: const Key('desktop-fullscreen'),
        tooltip: '${desktopFullscreenLabel(context, window.fullscreen)} · F11',
        onPressed: window.busy ? null : () => toggleDesktopFullscreen(context),
        icon: Icon(
          window.fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
        ),
      ),
    );
  }
}
