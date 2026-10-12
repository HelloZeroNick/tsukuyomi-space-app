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

Future<Uint8List> _batchPixels(Live2DPainter painter, Size size) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)
    ..drawColor(const Color(0xff263453), BlendMode.src);
  painter.paint(canvas, size);
  final picture = recorder.endRecording();
  final image = await picture.toImage(size.width.toInt(), size.height.toInt());
  try {
    return Uint8List.fromList(
      (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer
          .asUint8List(),
    );
  } finally {
    image.dispose();
    picture.dispose();
  }
}

/// Covers overlap with texture alpha, destination blends, masking, tint,
/// mutable geometry/UVs, render order and cache release, on native engines too.
Future<Map<String, dynamic>> probeLive2DBatching() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  for (var x = 0; x < 16; x++) {
    canvas.drawRect(
      Rect.fromLTWH(x.toDouble(), 0, 1, 16),
      Paint()..color = Color.fromARGB(80 + x * 10, x * 15, 220 - x * 10, 160),
    );
  }
  final picture = recorder.endRecording();
  final texture = await picture.toImage(16, 16);
  picture.dispose();
  LiveMesh mesh(int i, {int flags = 4, List<int> masks = const []}) => LiveMesh(
    positions: Float32List.fromList([0, 0, 10, 0, 10, 10, 0, 10]),
    uvs: Float32List.fromList([0, 0, 1, 0, 1, 1, 0, 1]),
    indices: Uint16List.fromList([0, 1, 2, 0, 2, 3]),
    texture: 0,
    order: i,
    flags: flags,
    visible: i != 0,
    opacity: i == 0 ? 0 : .75,
    masks: List.of(masks),
    multiply: [1, 1, 1, 1],
    screen: [0, 0, 0, 0],
    staticTopology: i != 4,
    geometryRevision: i != 4 ? 0 : null,
  );
  final meshes = [
    mesh(0),
    for (var i = 1; i < 15; i++) mesh(i),
    mesh(15, masks: [0]),
    mesh(16),
    mesh(17, flags: 5),
    mesh(18, flags: 5),
    mesh(19, flags: 6),
    mesh(20, flags: 6),
  ];
  meshes[16].multiply[0] = .7;
  final model = _ProbeModel([texture], meshes);
  final direct = Live2DPainter(model)..batchMeshes = false;
  final batched = Live2DPainter(model);
  var maxDelta = 0, changedBytes = 0;
  Uint8List? initial;
  final runs = <Map<String, int>>[];
  try {
    for (var phase = 0; phase < 7; phase++) {
      if (phase == 1) {
        for (final m in meshes.skip(1).take(6)) {
          m.positions[0] += 2;
          if (m.geometryRevision != null) {
            m.geometryRevision = m.geometryRevision! + 1;
          }
        }
      }
      if (phase == 2) meshes[4].uvs[0] = .5;
      if (phase == 3) {
        for (final m in meshes.skip(1).take(14)) {
          m.opacity = .25;
        }
        meshes[2].visible = false;
      }
      if (phase == 4) meshes[9].masks.add(0);
      if (phase == 5) {
        for (final m in meshes.skip(1).take(14)) {
          m.order = 15 - m.order;
        }
      }
      if (phase == 6) {
        for (final m in meshes) {
          m.visible = false;
        }
      }
      for (final budget in [0, 4096]) {
        direct.rasterPixelBudget = batched.rasterPixelBudget = budget;
        final a = await _batchPixels(direct, const Size(128, 128));
        final b = await _batchPixels(batched, const Size(128, 128));
        for (var i = 0; i < a.length; i++) {
          final difference = (a[i] - b[i]).abs();
          if (difference > maxDelta) maxDelta = difference;
          if (initial != null && initial[i] != b[i]) changedBytes++;
        }
        initial ??= b;
        runs.add({
          'phase': phase,
          'budget': budget,
          'direct_calls': direct.drawCalls,
          'batch_calls': batched.drawCalls,
          'batched_meshes': batched.batchedMeshes,
          'retained_bytes': batched.retainedBatchBytes,
        });
      }
    }
    return {
      'max_channel_delta': maxDelta,
      'changed_bytes': changedBytes,
      'runs': runs,
    };
  } finally {
    direct.dispose();
    batched.dispose();
    model.dispose();
    texture.dispose();
  }
}

Future<Map<String, dynamic>> probeNativeLive2DBatching(
  Live2DModel model,
) async {
  final direct = Live2DPainter(model)..batchMeshes = false;
  final batched = Live2DPainter(model);
  var maxDelta = 0;
  final runs = <Map<String, int>>[];
  try {
    for (var frame = 0; frame < 3; frame++) {
      model.tick(
        frame * .4,
        1 / 30,
        mouth: frame * .4,
        expression: frame == 1 ? 'happy' : 'neutral',
      );
      final a = await _batchPixels(direct, const Size(240, 320));
      final b = await _batchPixels(batched, const Size(240, 320));
      for (var i = 0; i < a.length; i++) {
        final difference = (a[i] - b[i]).abs();
        if (difference > maxDelta) maxDelta = difference;
      }
      runs.add({
        'direct_calls': direct.drawCalls,
        'batch_calls': batched.drawCalls,
        'batched_meshes': batched.batchedMeshes,
        'retained_bytes': batched.retainedBatchBytes,
      });
    }
    return {'max_channel_delta': maxDelta, 'runs': runs};
  } finally {
    direct.dispose();
    batched.dispose();
  }
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

Future<Map<String, int>> probeLive2DBatchIndexLimit() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawColor(Colors.white, BlendMode.src);
  final picture = recorder.endRecording();
  final texture = await picture.toImage(2, 2);
  picture.dispose();
  final meshes = [
    for (var i = 0; i < 3; i++)
      LiveMesh(
        positions: Float32List(44000)..setRange(0, 6, [0, 0, 10, 0, 0, 10]),
        uvs: Float32List(44000),
        indices: Uint16List.fromList([0, 1, 2]),
        texture: 0,
        order: i,
        flags: 4,
        visible: true,
        opacity: 1,
        masks: [],
        multiply: [1, 1, 1, 1],
        screen: [0, 0, 0, 0],
        staticTopology: true,
        geometryRevision: 0,
      ),
  ];
  final model = _ProbeModel([texture], meshes);
  final direct = Live2DPainter(model)..batchMeshes = false;
  final batched = Live2DPainter(model);
  try {
    final a = await _batchPixels(direct, const Size(32, 32));
    final b = await _batchPixels(batched, const Size(32, 32));
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) difference++;
    }
    return {
      'different_bytes': difference,
      'direct_calls': direct.drawCalls,
      'batch_calls': batched.drawCalls,
      'batched_meshes': batched.batchedMeshes,
    };
  } finally {
    direct.dispose();
    batched.dispose();
    model.dispose();
    texture.dispose();
  }
}

const expectedLive2DOpacity = <String, List<int>>{
  'normal': [79, 86, 109, 255],
  'additive': [84, 94, 124, 255],
  'masked additive': [84, 94, 124, 255],
};

/// A narrow character in a wide viewport should retain native detail: empty
/// margins must not force the atlas stripes through a low-resolution image.
Future<Map<String, dynamic>> probeLive2DCroppedDetail() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  for (var x = 0; x < 256; x++) {
    canvas.drawRect(
      Rect.fromLTWH(x.toDouble(), 0, 1, 256),
      Paint()..color = x % 8 < 4 ? Colors.black : Colors.white,
    );
  }
  final picture = recorder.endRecording();
  final texture = await picture.toImage(256, 256);
  picture.dispose();
  final meshes = [
    for (var i = 0; i < 12; i++)
      LiveMesh(
        positions: Float32List.fromList([0, 0, 10, 0, 10, 10, 0, 10]),
        uvs: Float32List.fromList([0, 0, 1, 0, 1, 1, 0, 1]),
        indices: Uint16List.fromList([0, 1, 2, 0, 2, 3]),
        texture: 0,
        order: i,
        flags: 4,
        visible: true,
        opacity: 1,
        masks: [],
        multiply: [1, 1, 1, 1],
        screen: [0, 0, 0, 0],
        staticTopology: true,
        geometryRevision: 0,
      ),
  ];
  final model = _ProbeModel([texture], meshes);
  final images = <Uint8List>[];
  final painter = Live2DPainter(model)..pixelRatio = 3;
  final passes = <int>[];
  try {
    for (final budget in [0, 150000]) {
      painter.rasterPixelBudget = budget;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)..scale(3);
      painter.paint(canvas, const Size(512, 128));
      passes.add(painter.boundedPasses);
      final picture = recorder.endRecording();
      final image = await picture.toImage(1536, 384);
      images.add(
        (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer
            .asUint8List(),
      );
      image.dispose();
      picture.dispose();
    }
    var different = 0;
    for (var i = 0; i < images.first.length; i++) {
      if (images.first[i] != images.last[i]) different++;
    }
    // Exercise cache invalidation with retained mutable native geometry.
    painter.rasterPixelBudget = 4096;
    final colors = <List<int>>[];
    for (var moved = 0; moved < 2; moved++) {
      for (final mesh in meshes) {
        if (moved != 0) {
          for (var i = 0; i < mesh.positions.length; i += 2) {
            mesh.positions[i] += 6;
          }
          mesh.geometryRevision = 1;
        }
      }
      final recorder = ui.PictureRecorder();
      painter.paint(Canvas(recorder), const Size(128, 128));
      final picture = recorder.endRecording();
      final image = await picture.toImage(128, 128);
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      colors.add([
        for (var c = 0; c < 4; c++) bytes.getUint8((64 * 128 + 32) * 4 + c),
      ]);
      image.dispose();
      picture.dispose();
    }
    return {
      'different_bytes': different,
      'passes': passes,
      'before': colors.first,
      'after': colors.last,
    };
  } finally {
    painter.dispose();
    model.dispose();
    texture.dispose();
  }
}

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
