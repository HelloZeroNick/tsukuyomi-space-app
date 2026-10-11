import 'dart:ui' as ui;

Future<ui.FragmentProgram>? _tintProgram;

Future<ui.FragmentProgram> loadLive2DTintProgram() => _tintProgram ??=
    ui.FragmentProgram.fromAsset('assets/shaders/live2d_tint.frag');
