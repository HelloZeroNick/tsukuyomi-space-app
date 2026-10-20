import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../packages/tsukuyomi_live2d/hook/legacy_shaders.dart';
import '../packages/tsukuyomi_live2d/hook/platform_shaders.dart';

void main() {
  final shader = File(
    'packages/tsukuyomi_live2d/vendor/cubism/Framework/src/Rendering/OpenGL/CubismShader_OpenGLES2.cpp',
  );
  test(
    'specialized SDK keeps legacy shaders and drops advanced warmup only',
    () {
      final original = shader.readAsStringSync();
      final specialized = legacyShaderSource(original);
      final start = original.indexOf(
        'void CubismShader_OpenGLES2::GenerateShaders()',
      );
      const end = 'void CubismShader_OpenGLES2::SetupShaderProgramForDrawable(';
      expect(specialized.substring(0, start), original.substring(0, start));
      expect(
        specialized.substring(specialized.indexOf(end)),
        original.substring(original.indexOf(end)),
      );
      expect(specialized, isNot(contains('i < ColorBlendMode_Count')));
      // Three platform branches each retain exactly 8 official programs; alias
      // assignments still share these across legacy additive/multiply blending.
      final programs = RegExp(r'ShaderProgram = LoadShaderProgramFromFile\(');
      expect(programs.allMatches(specialized).length, 24);
      for (final mode in [
        'AddMaskedInverted',
        'MultMaskedPremultipliedAlpha',
      ]) {
        expect(
          specialized,
          contains('_shaderSets[ShaderNames_$mode]->ShaderProgram ='),
        );
      }
      expect(
        specialized,
        contains('FragShaderSrcMaskInvertedPremultipliedAlpha.frag'),
      );
      expect(() => legacyShaderSource(specialized), throwsStateError);
      expect(
        () => legacyShaderSource(
          original.replaceAll('ShaderNames_NormalAtop;', 'Unexpected;'),
        ),
        throwsStateError,
      );
    },
    skip: !shader.existsSync() ? 'Cubism SDK fixture is not installed' : false,
  );
  test(
    'Metal specialization embeds legacy shaders and releases shared objects',
    () {
      final file = File(
        'packages/tsukuyomi_live2d/vendor/cubism/Framework/src/Rendering/Metal/CubismShader_Metal.mm',
      );
      if (!file.existsSync()) return;
      final result = metalShaderSource(file.readAsStringSync());
      final generate = result.substring(
        result.indexOf('void CubismShader_Metal::GenerateShaders'),
        result.indexOf('void CubismShader_Metal::GenerateBlendShader'),
      );
      expect(generate, contains('newLibraryWithSource:'));
      expect(generate, isNot(contains('GenerateBlendShader(')));
      expect(
        generate,
        contains('ShaderNames_NormalMaskedInvertedPremultipliedAlpha'),
      );
      expect(result, contains('std::set<ShaderProgram*>'));
      expect(() => metalShaderSource(result), throwsStateError);
    },
  );
  test('Linux core profile keeps every drawable and uses VBO indices', () {
    if (!shader.existsSync()) return;
    final result = coreGlSource(
      legacyShaderSource(shader.readAsStringSync()),
      shader: true,
    );
    expect(result, isNot(contains('glVertexAttribPointer(')));
    expect(RegExp(r'ts_gl_vertex\(').allMatches(result).length, 6);
    expect(result, contains('model.GetDrawableVertexCount(index)'));
    final renderer = File(
      'packages/tsukuyomi_live2d/vendor/cubism/Framework/src/Rendering/OpenGL/CubismRenderer_OpenGLES2.cpp',
    );
    final drawing = coreGlSource(renderer.readAsStringSync(), shader: false);
    expect(RegExp(r'ts_gl_indices\(').allMatches(drawing).length, 4);
    expect(drawing, isNot(contains('glDrawElements(')));
    for (final file in Directory(
      '${shader.parent.path}/Shaders/Standard',
    ).listSync().whereType<File>()) {
      if (!file.path.endsWith('.vert') && !file.path.endsWith('.frag'))
        continue;
      final source = coreGlShader(
        file.readAsStringSync(),
        vertex: file.path.endsWith('.vert'),
      );
      expect(source, isNot(contains('#version 120')));
      expect(source, isNot(contains('gl_FragColor')));
    }
  });
  test(
    'D3D11 retains old normal additive multiply and inverted mask variants',
    () {
      final file = File(
        'packages/tsukuyomi_live2d/vendor/cubism/Framework/src/Rendering/D3D11/CubismShader_D3D11.cpp',
      );
      if (!file.existsSync()) return;
      final result = d3dShaderSource(file.readAsStringSync());
      expect(result, contains('CSM_SET_SHADER_52(Add)'));
      expect(result, contains('CSM_SET_SHADER_52(Mult)'));
      expect(result, contains('PixelMaskedInvertedPremult)'));
      expect(result, isNot(contains('CSM_SET_SHADER_53(Normal, Out)')));
      expect(() => d3dShaderSource(result), throwsStateError);
    },
  );
}
