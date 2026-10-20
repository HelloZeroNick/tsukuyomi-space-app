/// Generated specializations of the pinned 5-r.5 SDK. Never edit vendor files.
/// Models using advanced/offscreen blending are rejected in ts_create.
String replaceOnce(String source, String before, String after) {
  if (before.allMatches(source).length != 1) {
    throw StateError('Cubism source changed; review shader specialization');
  }
  return source.replaceFirst(before, after);
}

String metalShaderSource(String source) {
  const begin = '    // 5.3以降\n    // ブレンドモードの組み合わせ分作成';
  const end = '    // サンプラーの初期化';
  final start = source.indexOf(begin), finish = source.indexOf(end);
  if (start < 0 || finish <= start) {
    throw StateError('Unsupported Cubism Metal shader source');
  }
  source = source.replaceRange(start, finish, '');
  source = replaceOnce(
    source,
    'id<MTLLibrary> shaderLib = [device newLibraryWithURL:libraryURL error:nil];',
    'id<MTLLibrary> shaderLib = [device newLibraryWithSource:'
        '[NSString stringWithUTF8String:ts_metal_source] options:nil error:nil];',
  );
  // Fail through the native ABI instead of allowing a nil pipeline to crash.
  source = replaceOnce(
    source,
    'NSLog(@" ERROR: Couldnt create a default shader library");',
    'throw std::runtime_error("Cannot compile Cubism Metal shaders");',
  );
  source = replaceOnce(
    source,
    '    InitializeSampler(device, _anisotropy, true);',
    '    [shaderLib release];\n'
        '    InitializeSampler(device, _anisotropy, true);',
  );
  source = replaceOnce(
    source,
    '''CubismShader_Metal::~CubismShader_Metal()
{
    ReleaseSampler();
}''',
    '''CubismShader_Metal::~CubismShader_Metal()
{
    ReleaseSampler();
    std::set<ShaderProgram*> programs;
    std::set<id> objects;
    for (csmInt32 i = 0; i < _shaderSets.GetSize(); ++i) {
        auto* s = _shaderSets[i];
        if (s->ShaderProgram) programs.insert(s->ShaderProgram);
        if (s->RenderPipelineState) objects.insert(s->RenderPipelineState);
        if (s->DepthStencilState) objects.insert(s->DepthStencilState);
        CSM_DELETE(s);
    }
    for (auto* p : programs) {
        [p->vertexFunction release]; [p->fragmentFunction release]; delete p;
    }
    for (id object : objects) [object release];
    _shaderSets.Clear();
}''',
  );
  return '#include "gpu_metal_shader.h"\n#include <stdexcept>\n#include <set>\n$source';
}

String d3dShaderSource(String source) {
  const begin = '        // 5.3以降 normal';
  const end = '#undef CSM_SET_BLEND_OVERLAP_SHADER';
  final start = source.indexOf(begin), finish = source.indexOf(end);
  if (start < 0 || finish <= start) {
    throw StateError('Unsupported Cubism D3D11 shader source');
  }
  return source.replaceRange(start, finish, '');
}

String coreGlShader(String source, {required bool vertex}) {
  // Shared blend helper snippets have no version directive or entry point.
  if (!source.contains('#version')) return source;
  source = replaceOnce(source, '#version 120', '#version 150');
  source = source.replaceAll('attribute ', 'in ');
  source = source.replaceAll('varying ', vertex ? 'out ' : 'in ');
  source = source.replaceAll('texture2D(', 'texture(');
  if (!vertex) {
    source = source.replaceFirst(
      '#version 150',
      '#version 150\nout vec4 ts_fragColor;',
    );
    source = source.replaceAll('gl_FragColor', 'ts_fragColor');
  }
  return source;
}

String coreGlSource(String source, {required bool shader}) {
  if (shader) {
    const start = 'void CubismShader_OpenGLES2::ReleaseShaderProgram()';
    const end = 'void CubismShader_OpenGLES2::ReleaseInvalidShaderProgram()';
    final begin = source.indexOf(start), finish = source.indexOf(end);
    if (begin < 0 || finish <= begin) throw StateError('GL cleanup changed');
    source = source.replaceRange(begin, finish, '''$start
{
    std::set<GLuint> programs;
    for (csmUint32 i = 0; i < _shaderSets.GetSize(); ++i) {
        if (_shaderSets[i]->ShaderProgram) programs.insert(_shaderSets[i]->ShaderProgram);
        CSM_DELETE(_shaderSets[i]);
    }
    _shaderSets.Clear();
    for (GLuint program : programs) glDeleteProgram(program);
}

''');
    final pattern = RegExp(
      r'glVertexAttribPointer\((shaderSet->\w+), 2, GL_FLOAT, GL_FALSE, sizeof\(csmFloat32\) \* 2, (\w+)\);',
    );
    final matches = pattern.allMatches(source).toList();
    if (matches.length != 6) throw StateError('Cubism GL vertex API changed');
    source = source.replaceAllMapped(pattern, (m) {
      final array = m[2]!;
      final count = array == 'vertexArray' || array == 'uvArray'
          ? 'model.GetDrawableVertexCount(index)'
          : '4';
      return 'ts_gl_vertex(${m[1]}, $count, $array);';
    });
  } else {
    final pattern = RegExp(
      r'glDrawElements\(GL_TRIANGLES, (.*?), GL_UNSIGNED_SHORT, (\w+)\);',
    );
    if (pattern.allMatches(source).length != 4) {
      throw StateError('Cubism GL index API changed');
    }
    source = source.replaceAllMapped(
      pattern,
      (m) => 'ts_gl_indices(${m[1]}, ${m[2]});',
    );
  }
  return '#include "gpu_gl_stream.h"\n#include <set>\n$source';
}
