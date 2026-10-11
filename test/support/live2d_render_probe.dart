import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:tsukuyomi_live2d/tsukuyomi_live2d.dart';

class _ProbeModel extends Live2DModel {
  _ProbeModel(this.textures, this.meshes, [this.tintProgram]);
  @override
  final ui.FragmentProgram? tintProgram;
  @override
  final List<ui.Image> textures;
  @override
  final List<LiveMesh> meshes;
  @override
  Rect get bounds => const Rect.fromLTRB(0, -10, 10, 0);
  @override
  List<String> get expressions => [];
  @override
  double get updateMilliseconds => 0;
  @override
  void tick(
    double seconds,
    double delta, {
    double mouth = 0,
    double lookX = 0,
    double lookY = 0,
    String expression = 'neutral',
  }) {}
}

/// Pixel expectations work in flutter_tester and in a native GPU probe.
Future<Map<String, List<int>>> probeLive2DOpacity() async {
  final textureRecorder = ui.PictureRecorder();
  Canvas(textureRecorder).drawColor(Colors.white, BlendMode.src);
  final texturePicture = textureRecorder.endRecording();
  final texture = await texturePicture.toImage(8, 8);
  texturePicture.dispose();
  LiveMesh mesh({
    int flags = 4,
    double opacity = .25,
    bool mask = false,
    bool clipped = false,
  }) => LiveMesh(
    positions: Float32List.fromList([0, 0, 10, 0, 10, 10, 0, 10]),
    uvs: Float32List.fromList([0, 0, 1, 0, 1, 1, 0, 1]),
    indices: Uint16List.fromList([0, 1, 2, 0, 2, 3]),
    texture: 0,
    order: mask ? 0 : 1,
    flags: flags,
    visible: !mask,
    opacity: mask ? 0 : opacity,
    masks: clipped ? [0] : [],
    multiply: [1, 1, 1, 1],
    screen: [0, 0, 0, 0],
  );
  final result = <String, List<int>>{};
  try {
    for (final entry in {
      'normal': 4,
      'additive': 5,
      'masked additive': 5,
    }.entries) {
      final clipped = entry.key.startsWith('masked');
      final model = _ProbeModel(
        [texture],
        [
          if (clipped) mesh(mask: true),
          mesh(flags: entry.value, clipped: clipped),
        ],
      );
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)
        ..drawColor(const Color.fromARGB(255, 20, 30, 60), BlendMode.src);
      final painter = Live2DPainter(model);
      painter.paint(canvas, const Size(32, 32));
      final picture = recorder.endRecording();
      final image = await picture.toImage(32, 32);
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      result[entry.key] = List.generate(
        4,
        (i) => bytes.getUint8((16 * 32 + 16) * 4 + i),
      );
      image.dispose();
      picture.dispose();
      painter.dispose();
      model.dispose();
    }
  } finally {
    texture.dispose();
  }
  return result;
}

const expectedLive2DOpacity = <String, List<int>>{
  'normal': [79, 86, 109, 255],
  'additive': [84, 94, 124, 255],
  'masked additive': [84, 94, 124, 255],
};

Future<Map<String, List<List<int>>>> probeLive2DShaderUvs() async {
  final program = await loadLive2DTintProgram();
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final colors = [
    const Color(0x80ff0000),
    Colors.green,
    Colors.blue,
    Colors.yellow,
  ];
  for (var i = 0; i < 4; i++) {
    canvas.drawRect(
      Rect.fromLTWH((i % 2) * 4, (i ~/ 2) * 4, 4, 4),
      Paint()..color = colors[i],
    );
  }
  final picture = recorder.endRecording();
  final texture = await picture.toImage(8, 8);
  picture.dispose();
  final result = <String, List<List<int>>>{};
  try {
    for (final custom in [false, true]) {
      final model = _ProbeModel(
        [texture],
        [
          LiveMesh(
            positions: Float32List.fromList([0, 0, 10, 0, 10, 10, 0, 10]),
            uvs: Float32List.fromList([0, 0, 1, 0, 1, 1, 0, 1]),
            indices: Uint16List.fromList([0, 1, 2, 0, 2, 3]),
            texture: 0,
            order: 0,
            flags: 4,
            visible: true,
            opacity: .5,
            masks: [],
            multiply: custom ? [.999, .999, .999, 1] : [1, 1, 1, 1],
            screen: [0, 0, 0, 0],
          ),
        ],
        program,
      );
      final painter = Live2DPainter(model);
      final recorder = ui.PictureRecorder();
      painter.paint(Canvas(recorder), const Size(32, 32));
      final picture = recorder.endRecording();
      final image = await picture.toImage(32, 32);
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      result[custom ? 'shader' : 'image'] = [
        for (final point in [
          const Offset(8, 8),
          const Offset(24, 8),
          const Offset(8, 24),
          const Offset(24, 24),
        ])
          List.generate(
            4,
            (i) => bytes.getUint8(
              (point.dy.toInt() * 32 + point.dx.toInt()) * 4 + i,
            ),
          ),
      ];
      image.dispose();
      picture.dispose();
      painter.dispose();
      model.dispose();
    }
  } finally {
    texture.dispose();
  }
  return result;
}

/// Compare bounded passes on a real destination with the direct reference.
/// Fillers force a normal group into the optimized path without covering the
/// sampled pixel. Special blends between groups must see the real background.
Future<Map<String, dynamic>> probeLive2DBoundedPasses() async {
  final program = await loadLive2DTintProgram();
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawColor(Colors.white, BlendMode.src);
  final picture = recorder.endRecording();
  final texture = await picture.toImage(8, 8);
  picture.dispose();
  LiveMesh mesh(
    int order, {
    int flags = 4,
    bool mask = false,
    bool clipped = false,
    bool filler = false,
    bool tint = false,
  }) => LiveMesh(
    positions: Float32List.fromList(
      filler ? [30, 0, 40, 0, 40, 10, 30, 10] : [0, 0, 10, 0, 10, 10, 0, 10],
    ),
    uvs: Float32List.fromList([0, 0, 1, 0, 1, 1, 0, 1]),
    indices: Uint16List.fromList([0, 1, 2, 0, 2, 3]),
    texture: 0,
    order: order,
    flags: flags,
    visible: !mask,
    opacity: mask ? 0 : .25,
    masks: clipped ? [0] : [],
    multiply: tint ? [.5, .8, .3, 1] : [1, 1, 1, 1],
    screen: tint ? [.1, 0, .2, 0] : [0, 0, 0, 0],
  );
  final results = <String, dynamic>{};
  try {
    for (final name in [
      'normal',
      'masked',
      'inverted',
      'tint',
      'additive',
      'multiply',
    ]) {
      final clipped = name == 'masked' || name == 'inverted';
      final model = _ProbeModel(
        [texture],
        [
          mesh(0, mask: true),
          for (var i = 1; i <= 12; i++) mesh(i, filler: true),
          mesh(
            13,
            clipped: clipped,
            flags: name == 'inverted' ? 12 : 4,
            tint: name == 'tint',
          ),
          if (name == 'additive' || name == 'multiply') ...[
            mesh(14, flags: name == 'additive' ? 5 : 6, tint: true),
            for (var i = 15; i <= 26; i++) mesh(i, filler: true),
            mesh(27, tint: true),
          ],
        ],
        program,
      );
      final pixels = <List<int>>[];
      var passes = 0, rasterPixels = 0;
      for (final bounded in [false, true]) {
        final painter = Live2DPainter(model)
          ..pixelRatio = 2
          ..rasterPixelBudget = bounded ? 4096 : 0;
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder)
          ..drawColor(const Color.fromARGB(255, 20, 30, 60), BlendMode.src);
        painter.paint(canvas, const Size(128, 128));
        final picture = recorder.endRecording();
        final image = await picture.toImage(128, 128);
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        pixels.add(
          List.generate(4, (i) => bytes.getUint8((64 * 128 + 64) * 4 + i)),
        );
        passes = painter.boundedPasses;
        rasterPixels = painter.rasterizedPixels;
        image.dispose();
        picture.dispose();
        painter.dispose();
      }
      results[name] = {
        'direct': pixels.first,
        'bounded': pixels.last,
        'passes': passes,
        'pixels': rasterPixels,
      };
      model.dispose();
    }
  } finally {
    texture.dispose();
  }
  return results;
}
