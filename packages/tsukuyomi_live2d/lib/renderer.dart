import 'dart:typed_data';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'model.dart';

/// Native Flutter triangle renderer. No browser, JavaScript, or platform view.
/// Supports standard Cubism masks, inverted masks, additive/multiply blending,
/// and per-drawable multiply/screen colors. Offscreen part blending is rejected.
class Live2DPainter extends CustomPainter {
  Live2DPainter(this.model) : super(repaint: model);
  final Live2DModel model;
  // Zero keeps the direct path (probes and full-resolution mode). Large native
  // viewports bound the normal-compositing passes, preserving blend order.
  int rasterPixelBudget = 0;
  double pixelRatio = 1;
  final _buffers = <int, _MeshBuffer>{};
  List<int> _sorted = [], _orders = [];
  List<int> _flags = [];
  List<List<int>> _groups = [];
  int boundedPasses = 0, rasterizedPixels = 0;
  final _imagePaint = Paint()..filterQuality = FilterQuality.low;
  final _layerPaint = Paint();
  final _maskLayerPaint = Paint();

  void dispose() {
    for (final buffer in _buffers.values) {
      buffer.vertices?.dispose();
      buffer.tintShader?.dispose();
    }
    _buffers.clear();
    for (final shader in _shaders) {
      shader.dispose();
    }
  }

  late final _shaders = [
    for (final image in model.textures)
      ImageShader(
        image,
        TileMode.clamp,
        TileMode.clamp,
        _identity,
        filterQuality: FilterQuality.low,
      ),
  ];
  // A full-character saveLayer for each eyelash/eye mesh is extremely costly.
  // Clip to the actual drawable while retaining a pixel gutter for filtering.
  Rect _meshBounds(LiveMesh mesh, double scale) {
    var left = double.infinity,
        top = double.infinity,
        right = -double.infinity,
        bottom = -double.infinity;
    for (var i = 0; i < mesh.positions.length; i += 2) {
      final x = mesh.positions[i], y = -mesh.positions[i + 1];
      left = math.min(left, x);
      right = math.max(right, x);
      top = math.min(top, y);
      bottom = math.max(bottom, y);
    }
    return Rect.fromLTRB(left, top, right, bottom).inflate(2 / scale);
  }

  static final _identity = Float64List.fromList([
    1,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    1,
  ]);

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = model.bounds;
    if (bounds.isEmpty || size.isEmpty || model.meshes.isEmpty) return;
    final scale =
        .94 * (size.width / bounds.width).clamp(0, size.height / bounds.height);
    boundedPasses = 0;
    rasterizedPixels = 0;
    if (_orders.length != model.meshes.length) {
      for (final buffer in _buffers.values) {
        buffer.vertices?.dispose();
        buffer.tintShader?.dispose();
      }
      _buffers.clear();
      _orders = List.filled(model.meshes.length, -1);
      _flags = List.filled(model.meshes.length, -1);
      _sorted = List.generate(model.meshes.length, (i) => i);
    }
    var orderChanged = false;
    for (var i = 0; i < _orders.length; i++) {
      if (_orders[i] != model.meshes[i].order) {
        _orders[i] = model.meshes[i].order;
        orderChanged = true;
      }
      if (_flags[i] != model.meshes[i].flags) {
        _flags[i] = model.meshes[i].flags;
        orderChanged = true;
      }
    }
    if (orderChanged || _groups.isEmpty) {
      _sorted.sort((a, b) {
        final order = _orders[a].compareTo(_orders[b]);
        return order == 0 ? a.compareTo(b) : order;
      });
      _groups = [];
      for (final index in _sorted) {
        if (_groups.isEmpty ||
            _blend(model.meshes[_groups.last.last]) !=
                _blend(model.meshes[index])) {
          _groups.add([]);
        }
        _groups.last.add(index);
      }
    }
    final pixels = size.width * size.height * pixelRatio * pixelRatio;
    final bounded = rasterPixelBudget > 0 && pixels > rasterPixelBudget * 1.2;
    for (final group in _groups) {
      // SrcOver is associative, so a normal pass can be composed on transparent
      // pixels first. Add/multiply must still see the real destination beneath.
      // Combining them into one transparent image changes highlights and alpha.
      final useImage =
          bounded &&
          _blend(model.meshes[group.first]) == BlendMode.srcOver &&
          group
                  .where(
                    (i) =>
                        model.meshes[i].visible && model.meshes[i].opacity > 0,
                  )
                  .length >=
              12;
      if (useImage) {
        final ratio = math.sqrt(rasterPixelBudget / (size.width * size.height));
        final width = math.max(1, (size.width * ratio).floor());
        final height = math.max(1, (size.height * ratio).floor());
        final recorder = ui.PictureRecorder();
        final target = Canvas(recorder)
          ..scale(width / size.width, height / size.height);
        _paintGroup(target, size, scale, group);
        final picture = recorder.endRecording();
        final image = picture.toImageSync(width, height);
        try {
          canvas.drawImageRect(
            image,
            Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
            Offset.zero & size,
            _imagePaint,
          );
        } finally {
          image.dispose();
          picture.dispose();
        }
        boundedPasses++;
        rasterizedPixels += width * height;
      } else {
        _paintGroup(canvas, size, scale, group);
      }
    }
  }

  BlendMode _blend(LiveMesh mesh) => mesh.flags & 1 != 0
      ? BlendMode.plus
      : mesh.flags & 2 != 0
      ? BlendMode.multiply
      : BlendMode.srcOver;

  void _paintGroup(Canvas canvas, Size size, double scale, List<int> group) {
    final bounds = model.bounds;
    canvas.save();
    canvas.translate(
      size.width / 2 - bounds.center.dx * scale,
      size.height / 2 - bounds.center.dy * scale,
    );
    canvas.scale(scale);
    for (final i in group) {
      final mesh = model.meshes[i];
      if (!mesh.visible || mesh.opacity <= 0 || mesh.indices.isEmpty) continue;
      final blend = _blend(mesh);
      if (mesh.masks.isEmpty) {
        _draw(canvas, i, mesh, blend);
      } else {
        final clipBounds = _meshBounds(mesh, scale);
        canvas.save();
        canvas.clipRect(clipBounds);
        canvas.saveLayer(clipBounds, _layerPaint..blendMode = blend);
        _draw(canvas, i, mesh, BlendMode.srcOver);
        canvas.saveLayer(
          clipBounds,
          _maskLayerPaint
            ..blendMode = (mesh.flags & 8 != 0
                ? BlendMode.dstOut
                : BlendMode.dstIn),
        );
        for (final mask in mesh.masks) {
          if (mask >= 0 && mask < model.meshes.length) {
            _draw(
              canvas,
              mask,
              model.meshes[mask],
              BlendMode.srcOver,
              mask: true,
            );
          }
        }
        canvas.restore();
        canvas.restore();
        canvas.restore();
      }
    }
    canvas.restore();
  }

  void _draw(
    Canvas canvas,
    int index,
    LiveMesh mesh,
    BlendMode blend, {
    bool mask = false,
  }) {
    if (mesh.texture < 0 ||
        mesh.texture >= model.textures.length ||
        mesh.positions.isEmpty) {
      return;
    }
    final image = model.textures[mesh.texture];
    final buffer = _buffers.putIfAbsent(index, _MeshBuffer.new);
    final vertices = buffer.update(mesh, image.width, image.height);
    final paint = (mask ? buffer.maskPaint : buffer.paint)
      ..isAntiAlias = true
      ..blendMode = blend
      ..color = Colors.white.withValues(alpha: mask ? 1 : mesh.opacity)
      ..shader = _shaders[mesh.texture]
      ..colorFilter = null;
    final m = mesh.multiply, s = mesh.screen;
    // A mask only contributes texture alpha; tinting it white is unnecessary.
    if (!mask &&
        (m[0] != 1 ||
            m[1] != 1 ||
            m[2] != 1 ||
            s[0] != 0 ||
            s[1] != 0 ||
            s[2] != 0)) {
      if (model.tintProgram != null) {
        paint.shader = buffer.shaderTint(model.tintProgram!, image, m, s);
      } else {
        paint.colorFilter = buffer.tint(m, s);
      }
    }
    canvas.drawVertices(vertices, BlendMode.srcOver, paint);
  }

  @override
  bool shouldRepaint(covariant Live2DPainter oldDelegate) =>
      oldDelegate.model != model;
}

class _MeshBuffer {
  Float32List positions = Float32List(0), uvs = Float32List(0);
  Uint16List indices = Uint16List(0);
  ui.Vertices? vertices;
  Float32List sourceUvs = Float32List(0);
  int textureWidth = 0, textureHeight = 0;
  int? geometryRevision;
  LiveMesh? source;
  final paint = Paint(), maskPaint = Paint();
  ui.FragmentShader? tintShader;
  Shader shaderTint(
    ui.FragmentProgram program,
    ui.Image image,
    List<double> m,
    List<double> s,
  ) {
    final first = tintShader == null;
    final shader = tintShader ??= program.fragmentShader();
    if (first) {
      shader
        ..setFloat(0, image.width.toDouble())
        ..setFloat(1, image.height.toDouble())
        ..setImageSampler(0, image);
    }
    for (var i = 0; i < 3; i++) {
      if (first || _tintValues[i] != m[i]) shader.setFloat(i + 2, m[i]);
      if (first || _tintValues[i + 3] != s[i]) shader.setFloat(i + 5, s[i]);
      _tintValues[i] = m[i];
      _tintValues[i + 3] = s[i];
    }
    return shader;
  }

  final _tintValues = List<double>.filled(6, double.nan);
  ColorFilter? _tint;
  ColorFilter tint(List<double> m, List<double> s) {
    var changed = _tint == null;
    for (var i = 0; i < 3; i++) {
      if (_tintValues[i] != m[i] || _tintValues[i + 3] != s[i]) changed = true;
      _tintValues[i] = m[i];
      _tintValues[i + 3] = s[i];
    }
    if (changed) {
      _tint = ColorFilter.matrix([
        m[0] * (1 - s[0]),
        0,
        0,
        0,
        s[0] * 255,
        0,
        m[1] * (1 - s[1]),
        0,
        0,
        s[1] * 255,
        0,
        0,
        m[2] * (1 - s[2]),
        0,
        s[2] * 255,
        0,
        0,
        0,
        1,
        0,
      ]);
    }
    return _tint!;
  }

  ui.Vertices update(LiveMesh mesh, int width, int height) {
    var changed = vertices == null;
    if (positions.length != mesh.positions.length ||
        uvs.length != mesh.uvs.length ||
        indices.length != mesh.indices.length) {
      positions = Float32List(mesh.positions.length);
      uvs = Float32List(mesh.uvs.length);
      indices = Uint16List(mesh.indices.length);
      changed = true;
    }
    final retained = identical(source, mesh) && mesh.staticTopology;
    final geometryChanged =
        !retained ||
        mesh.geometryRevision == null ||
        geometryRevision != mesh.geometryRevision;
    if (changed || geometryChanged) {
      for (var i = 0; i < positions.length; i += 2) {
        final x = mesh.positions[i], y = -mesh.positions[i + 1];
        if (positions[i] != x || positions[i + 1] != y) changed = true;
        positions[i] = x;
        positions[i + 1] = y;
      }
    }
    if (sourceUvs.length != mesh.uvs.length) {
      sourceUvs = Float32List(mesh.uvs.length);
      changed = true;
    }
    var uvChanged = textureWidth != width || textureHeight != height;
    if (!retained) {
      for (var i = 0; i < sourceUvs.length; i++) {
        if (sourceUvs[i] != mesh.uvs[i]) uvChanged = true;
        sourceUvs[i] = mesh.uvs[i];
      }
    }
    if (uvChanged) {
      changed = true;
      textureWidth = width;
      textureHeight = height;
      for (var i = 0; i < uvs.length; i += 2) {
        uvs[i] = mesh.uvs[i] * width;
        uvs[i + 1] = (1 - mesh.uvs[i + 1]) * height;
      }
    }
    if (!retained) {
      for (var i = 0; i < indices.length; i++) {
        if (indices[i] != mesh.indices[i]) changed = true;
        indices[i] = mesh.indices[i];
      }
    }
    if (changed) {
      vertices?.dispose();
      vertices = ui.Vertices.raw(
        ui.VertexMode.triangles,
        positions,
        textureCoordinates: uvs,
        indices: indices,
      );
    }
    source = mesh;
    geometryRevision = mesh.geometryRevision;
    return vertices!;
  }
}
