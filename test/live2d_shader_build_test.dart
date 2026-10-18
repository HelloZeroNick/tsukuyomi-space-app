import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../packages/tsukuyomi_live2d/hook/legacy_shaders.dart';

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
}
