/// Specialize the pinned Cubism 5-r.5 GLES renderer for our supported models.
/// bridge.cpp rejects IsBlendModeEnabled/offscreen models before Initialize.
/// Preserve official legacy normal/add/multiply, masks and inverted masks;
/// omit only the four advanced-blend compilation/uniform-discovery blocks.
/// Generate into the build directory; never modify the licensed SDK checkout.
String legacyShaderSource(String source) {
  const start = 'void CubismShader_OpenGLES2::GenerateShaders()';
  const end = 'void CubismShader_OpenGLES2::SetupShaderProgramForDrawable(';
  final begin = source.indexOf(start), finish = source.indexOf(end);
  if (begin < 0 || finish <= begin) {
    throw StateError('Unsupported Cubism shader source; review SDK update');
  }
  var body = source.substring(begin, finish);
  final blocks = RegExp(r'\{\s*csmUint32 offset = ShaderNames_NormalAtop;')
      .allMatches(body)
      .toList();
  if (blocks.length != 4) {
    throw StateError('Expected four Cubism advanced shader blocks');
  }
  for (final match in blocks.reversed) {
    var depth = 0, close = match.start;
    for (; close < body.length; close++) {
      if (body[close] == '{') depth++;
      if (body[close] == '}' && --depth == 0) break;
    }
    if (close == body.length ||
        !body.substring(match.start, close).contains('ColorBlendMode_Count')) {
      throw StateError('Unrecognized Cubism advanced shader block');
    }
    body = body.replaceRange(
      match.start,
      close + 1,
      '// Advanced blend models are rejected by ts_create; no warmup needed.',
    );
  }
  return source.substring(0, begin) + body + source.substring(finish);
}
