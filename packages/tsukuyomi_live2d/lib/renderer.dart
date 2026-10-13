import 'dart:typed_data';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'model.dart';

/// Native Flutter triangle renderer. No browser, JavaScript, or platform view.
/// Supports standard Cubism masks, inverted masks, additive/multiply blending,
/// and per-drawable multiply/screen colors. Offscreen part blending is rejected.
class Live2DPainter extends CustomPainter {
  factory Live2DPainter(
    Live2DModel model, {
    bool asynchronousRasterization = false,
  }) => Live2DPainter._(model, _FrameSignal(), asynchronousRasterization);
  Live2DPainter._(this.model, this._ready, this.asynchronousRasterization)
    : super(repaint: asynchronousRasterization ? _ready : model) {
    model.addListener(_modelChanged);
  }
  final Live2DModel model;
  final bool asynchronousRasterization;
  final _FrameSignal _ready;
  int _revision = 0, _recordedRevision = -1, _epoch = 0;
  bool _disposed = false, _enabled = true, _asyncFailed = false;
  Future<void>? _pending;
  _RasterFrame? _frame, _recording;
  (Size, int, double, bool)? _frameStamp, _requestedStamp;
  int recordedFrames = 0, cachedPaints = 0, asyncRasterizations = 0;
  int rasterFailures = 0;
  int lastPreparationMicros = 0, totalPreparationMicros = 0;
  bool get rasterizationPending => _pending != null;
  Future<void> get pendingRasterization => _pending ?? Future<void>.value();

  void _modelChanged() {
    _revision++;
    if (!asynchronousRasterization || _disposed || !_enabled) return;
    if (_asyncFailed) {
      _ready.changed();
    } else if (_requestedStamp != null) {
      _requestAsync(_requestedStamp!.$1);
    }
  }

  set renderingEnabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    _epoch++;
    _recordedRevision = -1;
  }

  // Zero keeps the direct path for reference probes. Large native
  // viewports bound only occupied character pixels, preserving blend order.
  int rasterPixelBudget = 0;
  double pixelRatio = 1;
  bool batchMeshes = true;
  final _buffers = <int, _MeshBuffer>{};
  final _batches = <int, _BatchBuffer>{};
  int paintCount = 0, drawCalls = 0, batchedMeshes = 0;
  int _meshFrame = 0;
  int totalDrawCalls = 0, totalBatchedMeshes = 0;
  int get retainedBatchBytes => _batches.values.fold(
    0,
    (sum, b) =>
        sum +
        b.positions.lengthInBytes +
        b.uvs.lengthInBytes +
        b.indices.lengthInBytes,
  );
  List<int> _sorted = [], _orders = [];
  List<int> _flags = [];
  List<List<int>> _groups = [];
  int boundedPasses = 0, downsampledPasses = 0, rasterizedPixels = 0;
  final _imagePaint = Paint()..filterQuality = FilterQuality.low;
  final _layerPaint = Paint();
  final _maskLayerPaint = Paint();
  final _batchPaint = Paint();

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _epoch++;
    model.removeListener(_modelChanged);
    _ready.dispose();
    _frame?.dispose();
    _frame = null;
    for (final buffer in _buffers.values) {
      buffer.vertices?.dispose();
      buffer.tintShader?.dispose();
    }
    _buffers.clear();
    for (final batch in _batches.values) {
      batch.dispose();
    }
    _batches.clear();
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
  Rect _meshBounds(int index) =>
      _buffers.putIfAbsent(index, _MeshBuffer.new).bounds(model.meshes[index]);

  Rect _groupBounds(List<int> group, Size size, double scale) {
    Rect? occupied;
    for (final i in group) {
      final mesh = model.meshes[i];
      if (!mesh.visible || mesh.opacity <= 0 || mesh.indices.isEmpty) continue;
      final rect = _meshBounds(i);
      if (!rect.isEmpty) occupied = occupied?.expandToInclude(rect) ?? rect;
    }
    if (occupied == null) return Rect.zero;
    final origin = Offset(
      size.width / 2 - model.bounds.center.dx * scale,
      size.height / 2 - model.bounds.center.dy * scale,
    );
    return Rect.fromLTRB(
      occupied.left * scale + origin.dx,
      occupied.top * scale + origin.dy,
      occupied.right * scale + origin.dx,
      occupied.bottom * scale + origin.dy,
    ).inflate(2).intersect(Offset.zero & size);
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
    if (_disposed) return;
    paintCount++;
    if (asynchronousRasterization && !_asyncFailed) {
      _paintAsync(canvas, size);
    } else {
      _paintCurrent(canvas, size);
    }
  }

  void _paintAsync(Canvas canvas, Size size) {
    _requestAsync(size);
    final stamp = (size, rasterPixelBudget, pixelRatio, batchMeshes);
    if (_frameStamp == stamp && _frame != null) {
      _frame!.paint(canvas, _imagePaint);
      cachedPaints++;
    }
  }

  void _requestAsync(Size size) {
    final stamp = (size, rasterPixelBudget, pixelRatio, batchMeshes);
    if (_requestedStamp != stamp) {
      _requestedStamp = stamp;
      _recordedRevision = -1;
      _epoch++;
    }
    if (_enabled &&
        _pending == null &&
        (_recordedRevision != _revision || _frameStamp != stamp)) {
      final frame = _RasterFrame();
      final preparation = Stopwatch()..start();
      _recording = frame;
      try {
        // Capture immutable display lists together. Native geometry may change
        // during rasterization; masks and destination blends must keep the same
        // snapshot as the normal groups, never a mixture of two model frames.
        _paintCurrent(null, size);
      } catch (_) {
        frame.dispose();
        rethrow;
      } finally {
        _recording = null;
      }
      _recordedRevision = _revision;
      lastPreparationMicros = preparation.elapsedMicroseconds;
      totalPreparationMicros += lastPreparationMicros;
      recordedFrames++;
      final epoch = _epoch;
      _pending = _rasterize(frame, stamp, epoch);
    }
  }

  Future<void> _rasterize(
    _RasterFrame next,
    (Size, int, double, bool) stamp,
    int epoch,
  ) async {
    // Always cross an async boundary before replacing _pending. At most one
    // model frame is in flight; intermediate model updates coalesce naturally.
    await Future<void>.value();
    try {
      for (final piece in next.pieces) {
        if (piece.crop == null) continue;
        final image = await piece.picture!.toImage(piece.width, piece.height);
        piece.image = image;
        piece.picture!.dispose();
        piece.picture = null;
        asyncRasterizations++;
        if (_disposed || !_enabled || epoch != _epoch) return;
      }
      if (_disposed || !_enabled || epoch != _epoch) return;
      _frame?.dispose();
      _frame = next;
      _frameStamp = stamp;
    } catch (error) {
      rasterFailures++;
      _asyncFailed = true;
      debugPrint('Live2D async rasterization failed: ${error.runtimeType}');
    } finally {
      if (!identical(_frame, next)) next.dispose();
      _pending = null;
      if (!_disposed && _enabled) {
        _ready.changed();
        if (!_asyncFailed &&
            _recordedRevision != _revision &&
            _requestedStamp != null) {
          _requestAsync(_requestedStamp!.$1);
        }
      }
    }
  }

  void _paintCurrent(Canvas? canvas, Size size) {
    final bounds = model.bounds;
    if (bounds.isEmpty || size.isEmpty || model.meshes.isEmpty) return;
    _meshFrame++;
    drawCalls = batchedMeshes = 0;
    final scale =
        .94 * (size.width / bounds.width).clamp(0, size.height / bounds.height);
    boundedPasses = 0;
    downsampledPasses = 0;
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
    for (final group in _groups) {
      // SrcOver is associative, so a normal pass can be composed on transparent
      // pixels first. Add/multiply must still see the real destination beneath.
      // Combining them into one transparent image changes highlights and alpha.
      final candidate =
          rasterPixelBudget > 0 &&
          size.width * size.height * pixelRatio * pixelRatio >
              rasterPixelBudget * 1.2 &&
          _blend(model.meshes[group.first]) == BlendMode.srcOver &&
          group
                  .where(
                    (i) =>
                        model.meshes[i].visible && model.meshes[i].opacity > 0,
                  )
                  .length >=
              12;
      var crop = candidate ? _groupBounds(group, size, scale) : Rect.zero;
      if (candidate) {
        if (crop.isEmpty) continue;
        // Transparent viewport margins consumed most of the old pixel budget.
        // Crop before resampling so facial details receive those pixels instead.
        // Native-density offscreen composition also avoids painting hundreds of
        // overlapping meshes against the full window. It must not resample fine
        // lines merely because the transparent viewport itself is large.
        var ratio = math.min(
          pixelRatio,
          math.sqrt(rasterPixelBudget / (crop.width * crop.height)),
        );
        final occupied = crop;
        late int width, height;
        for (var attempt = 0; ; attempt++) {
          final left = (occupied.left * ratio).floor();
          final top = (occupied.top * ratio).floor();
          final right = (occupied.right * ratio).ceil();
          final bottom = (occupied.bottom * ratio).ceil();
          width = math.max(1, right - left);
          height = math.max(1, bottom - top);
          crop = Rect.fromLTWH(
            left / ratio,
            top / ratio,
            width / ratio,
            height / ratio,
          );
          if (width * height <= rasterPixelBudget) break;
          ratio *= attempt >= 3
              ? .5
              : math.sqrt(rasterPixelBudget / (width * height)) * .999;
        }
        final recorder = ui.PictureRecorder();
        final target = Canvas(recorder)
          ..scale(ratio)
          ..translate(-crop.left, -crop.top);
        _paintGroup(target, size, scale, group);
        final picture = recorder.endRecording();
        if (_recording != null) {
          _recording!.pieces.add(_RasterPiece(picture, crop, width, height));
        } else {
          final image = picture.toImageSync(width, height);
          try {
            canvas!.drawImageRect(
              image,
              Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
              crop,
              _imagePaint,
            );
          } finally {
            image.dispose();
            picture.dispose();
          }
        }
        boundedPasses++;
        if (ratio < pixelRatio * .999) downsampledPasses++;
        rasterizedPixels += width * height;
      } else {
        if (_recording == null) {
          _paintGroup(canvas!, size, scale, group);
        } else {
          final recorder = ui.PictureRecorder();
          _paintGroup(Canvas(recorder), size, scale, group);
          _recording!.pieces.add(
            _RasterPiece(recorder.endRecording(), null, 0, 0),
          );
        }
      }
    }
    // Keep only the current frame's runs: changing visibility/opacity cannot
    // retain an ever-growing collection of alternative vertex buffers.
    _batches.removeWhere((_, batch) {
      if (batch.lastPaint == _meshFrame) return false;
      batch.dispose();
      return true;
    });
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
    for (var cursor = 0; cursor < group.length; cursor++) {
      final i = group[cursor];
      final mesh = model.meshes[i];
      if (!mesh.visible || mesh.opacity <= 0 || mesh.indices.isEmpty) continue;
      final blend = _blend(mesh);
      if (mesh.masks.isEmpty) {
        if (batchMeshes && _batchable(mesh)) {
          var end = cursor + 1, vertices = mesh.positions.length ~/ 2;
          while (end < group.length) {
            final next = model.meshes[group[end]];
            if (!_batchable(next) ||
                next.texture != mesh.texture ||
                next.opacity != mesh.opacity ||
                _blend(next) != blend ||
                vertices + next.positions.length ~/ 2 > 65535) {
              break;
            }
            vertices += next.positions.length ~/ 2;
            end++;
          }
          if (end - cursor > 1) {
            final image = model.textures[mesh.texture];
            final batch = _batches.putIfAbsent(i, _BatchBuffer.new)
              ..lastPaint = _meshFrame;
            final vertices = batch.update(
              model.meshes,
              group,
              cursor,
              end,
              image.width,
              image.height,
            );
            canvas.drawVertices(
              vertices,
              BlendMode.srcOver,
              _batchPaint
                ..isAntiAlias = true
                ..blendMode = blend
                ..color = Colors.white.withValues(alpha: mesh.opacity)
                ..shader = _shaders[mesh.texture],
            );
            drawCalls++;
            totalDrawCalls++;
            batchedMeshes += end - cursor;
            totalBatchedMeshes += end - cursor;
            cursor = end - 1;
            continue;
          }
        }
        _draw(canvas, i, mesh, blend);
      } else {
        final clipBounds = _meshBounds(i).inflate(2 / scale);
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

  bool _batchable(LiveMesh mesh) =>
      mesh.visible &&
      // Some backends apply paint opacity/advanced destination blending to
      // the whole draw, rather than independently to overlapping primitives.
      // Texture alpha remains per fragment; only opaque normal paints batch.
      mesh.opacity == 1 &&
      _blend(mesh) == BlendMode.srcOver &&
      mesh.masks.isEmpty &&
      mesh.indices.isNotEmpty &&
      mesh.positions.isNotEmpty &&
      mesh.texture >= 0 &&
      mesh.texture < model.textures.length &&
      mesh.multiply[0] == 1 &&
      mesh.multiply[1] == 1 &&
      mesh.multiply[2] == 1 &&
      mesh.screen[0] == 0 &&
      mesh.screen[1] == 0 &&
      mesh.screen[2] == 0;

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
    drawCalls++;
    totalDrawCalls++;
  }

  @override
  bool shouldRepaint(covariant Live2DPainter oldDelegate) =>
      oldDelegate.model != model ||
      oldDelegate.asynchronousRasterization != asynchronousRasterization;
}

class _FrameSignal extends ChangeNotifier {
  void changed() => notifyListeners();
}

/// Adjacent identical materials preserve triangle/render order in one draw.
/// Native revisions retain static UV/index data; foreign mutable meshes still
/// compare their contents, matching the individual-mesh path.
class _BatchBuffer {
  int lastPaint = 0, _width = 0, _height = 0;
  Float32List positions = Float32List(0), uvs = Float32List(0);
  Uint16List indices = Uint16List(0);
  List<LiveMesh?> _sources = [];
  List<int?> _revisions = [];
  List<int> _positionCounts = [], _indexCounts = [];
  ui.Vertices? _vertices;
  void dispose() {
    _vertices?.dispose();
    _vertices = null;
  }

  ui.Vertices update(
    List<LiveMesh> meshes,
    List<int> group,
    int start,
    int end,
    int width,
    int height,
  ) {
    var coordinates = 0, triangles = 0;
    var topology = _sources.length != end - start;
    for (var i = start; i < end; i++) {
      final m = meshes[group[i]], slot = i - start;
      coordinates += m.positions.length;
      triangles += m.indices.length;
      if (!topology &&
          (!identical(_sources[slot], m) ||
              _positionCounts[slot] != m.positions.length ||
              _indexCounts[slot] != m.indices.length)) {
        topology = true;
      }
    }
    var changed = _vertices == null || topology;
    if (positions.length != coordinates || indices.length != triangles) {
      positions = Float32List(coordinates);
      uvs = Float32List(coordinates);
      indices = Uint16List(triangles);
      changed = topology = true;
    }
    if (_sources.length != end - start) {
      _sources = List.filled(end - start, null);
      _revisions = List.filled(end - start, null);
      _positionCounts = List.filled(end - start, 0);
      _indexCounts = List.filled(end - start, 0);
    }
    final resizedTexture = _width != width || _height != height;
    var at = 0, indexAt = 0;
    for (var i = start; i < end; i++) {
      final m = meshes[group[i]], slot = i - start;
      final retained =
          !topology && identical(_sources[slot], m) && m.staticTopology;
      if (!retained ||
          m.geometryRevision == null ||
          _revisions[slot] != m.geometryRevision) {
        for (var p = 0; p < m.positions.length; p += 2) {
          final x = m.positions[p], y = -m.positions[p + 1];
          if (positions[at + p] != x || positions[at + p + 1] != y) {
            changed = true;
          }
          positions[at + p] = x;
          positions[at + p + 1] = y;
        }
      }
      if (!retained || resizedTexture) {
        for (var p = 0; p < m.uvs.length; p += 2) {
          final u = m.uvs[p] * width, v = (1 - m.uvs[p + 1]) * height;
          if (uvs[at + p] != u || uvs[at + p + 1] != v) changed = true;
          uvs[at + p] = u;
          uvs[at + p + 1] = v;
        }
      }
      if (!retained) {
        for (var p = 0; p < m.indices.length; p++) {
          final index = m.indices[p] + at ~/ 2;
          if (indices[indexAt + p] != index) changed = true;
          indices[indexAt + p] = index;
        }
      }
      _sources[slot] = m;
      _revisions[slot] = m.geometryRevision;
      _positionCounts[slot] = m.positions.length;
      _indexCounts[slot] = m.indices.length;
      at += m.positions.length;
      indexAt += m.indices.length;
    }
    _width = width;
    _height = height;
    if (changed) {
      _vertices?.dispose();
      _vertices = ui.Vertices.raw(
        ui.VertexMode.triangles,
        positions,
        textureCoordinates: uvs,
        indices: indices,
      );
    }
    return _vertices!;
  }
}

class _RasterFrame {
  final pieces = <_RasterPiece>[];

  void paint(Canvas canvas, Paint paint) {
    for (final piece in pieces) {
      final image = piece.image;
      if (image != null) {
        canvas.drawImageRect(
          image,
          Rect.fromLTWH(0, 0, piece.width.toDouble(), piece.height.toDouble()),
          piece.crop!,
          paint,
        );
      } else if (piece.picture != null) {
        canvas.drawPicture(piece.picture!);
      }
    }
  }

  void dispose() {
    for (final piece in pieces) {
      piece.image?.dispose();
      piece.picture?.dispose();
    }
    pieces.clear();
  }
}

class _RasterPiece {
  _RasterPiece(this.picture, this.crop, this.width, this.height);
  ui.Picture? picture;
  ui.Image? image;
  final Rect? crop;
  final int width, height;
}

class _MeshBuffer {
  LiveMesh? _boundsSource;
  int? _boundsRevision;
  Rect _bounds = Rect.zero;
  Rect bounds(LiveMesh mesh) {
    if (identical(_boundsSource, mesh) &&
        mesh.staticTopology &&
        mesh.geometryRevision != null &&
        _boundsRevision == mesh.geometryRevision) {
      return _bounds;
    }
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
    _boundsSource = mesh;
    _boundsRevision = mesh.geometryRevision;
    return _bounds = mesh.positions.isEmpty
        ? Rect.zero
        : Rect.fromLTRB(left, top, right, bottom);
  }

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
