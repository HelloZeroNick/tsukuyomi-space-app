import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

import 'legacy_shaders.dart';
import 'platform_shaders.dart';

/// Clang target triple per architecture for OpenHarmony/HarmonyOS.
const Map<String, String> _ohosTriples = {
  'arm64': 'aarch64-linux-ohos',
  'arm': 'armv7-linux-ohos',
  'x64': 'x86_64-linux-ohos',
};

/// The OHOS Flutter tool forwards `targetOS: OS.linux` to package hooks (the
/// hosted `code_assets` does not know OHOS yet), while still handing over the
/// OHOS clang from DevEco Studio. Detect that case from the compiler path so
/// the Linux build path is not used by accident.
Directory? _ohosNativeRoot(CCompilerConfig? cCompiler) {
  final compiler = cCompiler?.compiler;
  if (compiler == null) return null;
  final dir = File.fromUri(compiler).parent;
  final path = dir.path.replaceAll('\\', '/').toLowerCase();
  if (!path.contains('openharmony') && !path.contains('harmonyos')) {
    return null;
  }
  // <native>/llvm/bin -> <native>
  final native = dir.parent.parent;
  final sysroot = Directory('${native.path}${Platform.pathSeparator}sysroot');
  return sysroot.existsSync() ? native : null;
}

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final sdk = input.packageRoot.resolve('vendor/cubism/');
    final config = input.config.code;
    final os = config.targetOS;
    final arch = config.targetArchitecture.toString();
    final ohosRoot = os == OS.linux ? _ohosNativeRoot(config.cCompiler) : null;
    final ohos = ohosRoot != null;
    final ohosTriple = ohos ? _ohosTriples[arch] : null;
    String? core;
    if (ohos) {
      // The official SDK ships the HarmonyOS core under Core/lib/harmonyos/
      // (see Live2D/CubismNativeSamples: proj.harmonyos.cmake), so that path is
      // canonical. `lib/ohos` is still accepted for a hand-rolled port.
      final abi = {
        'arm64': 'arm64-v8a',
        'arm': 'armeabi-v7a',
        'x64': 'x86_64',
      }[arch];
      if (abi != null) {
        final canonical = 'Core/lib/harmonyos/$abi/libLive2DCubismCore.a';
        core = [canonical, 'Core/lib/ohos/$abi/libLive2DCubismCore.a']
            .firstWhere(
              (candidate) => File.fromUri(sdk.resolve(candidate)).existsSync(),
              orElse: () => canonical,
            );
      }
    } else if (os == OS.macOS) {
      core =
          'Core/lib/macos/${arch == 'x64' ? 'x86_64' : arch}/libLive2DCubismCore.a';
    } else if (os == OS.linux && arch == 'x64') {
      core = 'Core/lib/linux/x86_64/libLive2DCubismCore.a';
    } else if (os == OS.android) {
      final abi = {
        'arm64': 'arm64-v8a',
        'arm': 'armeabi-v7a',
        'x64': 'x86_64',
        'ia32': 'x86',
      }[arch];
      if (abi != null) core = 'Core/lib/android/$abi/libLive2DCubismCore.a';
    } else if (os == OS.iOS) {
      final simulator = config.iOS.targetSdk == IOSSdk.iPhoneSimulator;
      final cpu = arch == 'x64' ? 'x86_64' : arch;
      core =
          'Core/lib/ios/Release-${simulator ? 'iphonesimulator-$cpu' : 'iphoneos'}/libLive2DCubismCore.a';
    }
    if (os == OS.windows && ['x64', 'ia32'].contains(arch)) {
      core =
          'Core/lib/windows/${arch == 'x64' ? 'x86_64' : 'x86'}/143/Live2DCubismCore_MD.lib';
    }
    final enabled =
        core != null && File.fromUri(sdk.resolve(core)).existsSync();
    final requireCore = File.fromUri(sdk.resolve('REQUIRE_CORE'));
    if (!enabled && requireCore.existsSync()) {
      throw StateError('Release requires Cubism Core for $os/$arch: $core');
    }
    if (requireCore.existsSync()) output.dependencies.add(requireCore.uri);
    final sources = <String>['src/bridge.cpp', 'src/audio_envelope.cpp'];
    final metal = enabled && (os == OS.macOS || os == OS.iOS);
    final d3d = enabled && os == OS.windows;
    final linuxGl = enabled && os == OS.linux && !ohos;
    final gl = enabled && (os == OS.android || linuxGl);
    final gpu = metal || d3d || gl;
    final generatedIncludes = <String>[];
    if (gl || d3d) {
      // Embed the pinned SDK's GLES shaders in the native library. They must
      // not depend on a working directory or an Android asset path at runtime.
      final shaders = Directory.fromUri(
        sdk.resolve(
          d3d
              ? 'Framework/src/Rendering/D3D11/Shaders/'
              : 'Framework/src/Rendering/OpenGL/Shaders/StandardES/',
        ),
      );
      final header = File.fromUri(
        input.outputDirectory.resolve('gpu_shaders.h'),
      );
      final source = StringBuffer(
        '#include <cstring>\n#include <string>\n'
        'static const char* ts_shader(const std::string& name) {\n',
      );
      source.writeln(
        'const auto base = name.substr(name.find_last_of("/\\\\") + 1);',
      );
      final files = shaders.listSync().whereType<File>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final file in files) {
        if (!file.path.endsWith('.frag') &&
            !file.path.endsWith('.vert') &&
            !file.path.endsWith('.fx')) {
          continue;
        }
        var content = file.readAsStringSync();
        final literal = d3d
            ? shaderLiteral(content)
            : 'R"TS_SHADER($content)TS_SHADER"';
        source.writeln(
          'if (base == "${file.uri.pathSegments.last}") return $literal;',
        );
        output.dependencies.add(file.uri);
      }
      source.writeln('return nullptr; }');
      await header.writeAsString(source.toString());
      generatedIncludes.add(header.parent.path);
    }
    if (metal) {
      final dir = sdk.resolve('Framework/src/Rendering/Metal/Shaders/');
      final shader = File.fromUri(dir.resolve('MetalShaders.metal'));
      final types = File.fromUri(dir.resolve('MetalShaderTypes.h'));
      final content = replaceOnce(
        shader.readAsStringSync(),
        '#include "MetalShaderTypes.h"',
        types.readAsStringSync(),
      );
      final header = File.fromUri(
        input.outputDirectory.resolve('gpu_metal_shader.h'),
      );
      await header.writeAsString(
        'static const char* ts_metal_source = R"TS_METAL($content)TS_METAL";\n',
      );
      generatedIncludes.add(header.parent.path);
      output.dependencies.addAll([shader.uri, types.uri]);
    }
    if (gpu) {
      output.dependencies.addAll([
        input.packageRoot.resolve('src/android_gpu.inc'),
        input.packageRoot.resolve('src/desktop_gpu.inc'),
        input.packageRoot.resolve('src/gpu_api.h'),
        input.packageRoot.resolve('src/gpu_gl_stream.h'),
        input.packageRoot.resolve('src/GL/glew.h'),
        input.packageRoot.resolve('hook/platform_shaders.dart'),
      ]);
    }
    if (enabled) {
      final framework = Directory.fromUri(sdk.resolve('Framework/src/'));
      for (final file
          in framework.listSync(recursive: true).whereType<File>()) {
        if ((file.path.endsWith('.cpp') ||
                (metal && file.path.endsWith('.mm'))) &&
            (!file.uri.path.contains('/Rendering/') ||
                file.uri.path.endsWith('/csmBlendMode.cpp') ||
                (gpu &&
                    ((gl && file.uri.path.contains('/Rendering/OpenGL/')) ||
                        (metal &&
                            file.uri.path.contains('/Rendering/Metal/')) ||
                        (d3d && file.uri.path.contains('/Rendering/D3D11/')) ||
                        file.uri.path.endsWith(
                          '/Rendering/CubismRenderer.cpp',
                        )))) &&
            !file.uri.path.endsWith('/CubismUserModel.cpp')) {
          if (gl && file.uri.path.endsWith('/CubismShader_OpenGLES2.cpp')) {
            final specialized = File.fromUri(
              input.outputDirectory.resolve('CubismShader_Legacy.cpp'),
            );
            await specialized.writeAsString(
              linuxGl
                  ? streamGlSource(
                      legacyShaderSource(file.readAsStringSync()),
                      shader: true,
                    )
                  : legacyShaderSource(file.readAsStringSync()),
            );
            generatedIncludes.add(file.parent.path);
            output.dependencies.add(file.uri);
            output.dependencies.add(
              input.packageRoot.resolve('hook/legacy_shaders.dart'),
            );
            sources.add(specialized.path);
          } else if ((metal &&
                  file.uri.path.endsWith('/CubismShader_Metal.mm')) ||
              (d3d && file.uri.path.endsWith('/CubismShader_D3D11.cpp'))) {
            final specialized = File.fromUri(
              input.outputDirectory.resolve(
                metal ? 'CubismShader_Metal.mm' : 'CubismShader_D3D11.cpp',
              ),
            );
            await specialized.writeAsString(
              metal
                  ? metalShaderSource(file.readAsStringSync())
                  : d3dShaderSource(file.readAsStringSync()),
            );
            generatedIncludes.add(file.parent.path);
            output.dependencies.add(file.uri);
            sources.add(specialized.path);
          } else if (linuxGl &&
              file.uri.path.endsWith('/CubismRenderer_OpenGLES2.cpp')) {
            final generated = File.fromUri(
              input.outputDirectory.resolve('CubismRenderer_CoreGL.cpp'),
            );
            await generated.writeAsString(
              streamGlSource(file.readAsStringSync(), shader: false),
            );
            generatedIncludes.add(file.parent.path);
            output.dependencies.add(file.uri);
            sources.add(generated.path);
          } else {
            sources.add(file.path);
          }
        }
      }
      output.dependencies.add(sdk.resolve(core));
    }
    // MSVC is launched through cmd.exe by native_toolchain_c. The Framework's
    // absolute source paths exceed cmd's 8191-character limit on CI checkouts.
    // Keep each translation unit, but move source arguments into a response file.
    String? sourceResponse;
    if (os == OS.windows) {
      final sourceUris = sources
          .map((source) => input.packageRoot.resolveUri(Uri.file(source)))
          .toList();
      final response = File.fromUri(
        input.outputDirectory.resolve('cubism_sources.rsp'),
      );
      await response.writeAsString(
        sourceUris.map((uri) => '"${uri.toFilePath()}"').join('\n'),
      );
      output.dependencies.addAll(sourceUris);
      sourceResponse = response.path;
    }
    final builder = CBuilder.library(
      // CocoaPods also creates tsukuyomi_live2d.framework. Native assets must
      // have a distinct install name or Flutter can resolve FFI into the plugin.
      name: metal ? 'tsukuyomi_cubism_core' : input.packageName,
      assetName: 'bindings.dart',
      sources: sourceResponse == null ? sources : [],
      language: Language.cpp,
      cppLinkStdLib: os == OS.windows
          ? null
          : (os == OS.android || ohos
                ? 'c++_static'
                : (os == OS.linux ? 'stdc++' : 'c++')),
      includes: enabled
          ? [
              sdk.resolve('Core/include').toFilePath(),
              sdk.resolve('Framework/src').toFilePath(),
              input.packageRoot.resolve('src').toFilePath(),
              ...generatedIncludes,
            ]
          : [],
      defines: {
        'TS_HAS_CUBISM': enabled ? '1' : '0',
        if (gpu) 'TS_GPU': '1',
        if (metal) 'TS_GPU_METAL': '1',
        if (d3d) 'TS_GPU_D3D11': '1',
        if (d3d) 'NOMINMAX': '1',
        if (gl && os == OS.android) 'CSM_TARGET_ANDROID_ES2': '1',
        if (linuxGl) 'CSM_TARGET_LINUX_GL': '1',
      },
      flags: os == OS.windows
          ? ['/std:c++17', '/MD', '/EHsc', '/utf-8', '@$sourceResponse']
          : [
              '-std=c++17',
              if (metal) ...[
                '-x',
                'objective-c++',
                '-fno-objc-arc',
                '-framework',
                'Foundation',
                '-framework',
                'Metal',
                '-framework',
                'MetalKit',
              ],
              if (os == OS.android) '-Wl,--no-undefined',
              // The OHOS toolchain is a cross compiler: without an explicit
              // target it falls back to the host triple and cannot find the
              // OHOS C++ headers.
              if (ohosTriple != null) '--target=$ohosTriple',
              if (ohos)
                '--sysroot=${ohosRoot.path}${Platform.pathSeparator}sysroot',
            ],
      libraries: [
        if (enabled)
          os == OS.windows ? 'Live2DCubismCore_MD' : 'Live2DCubismCore',
        // PCM decoding needs libm even in development builds without Cubism.
        if (os == OS.android) ...['m', 'log'],
        if (gl && os == OS.android) ...[
          'EGL',
          'GLESv2',
          'android',
          'jnigraphics',
        ],
        if (linuxGl) ...['epoxy', 'GL'],
        if (d3d) ...['d3d11', 'd3dcompiler', 'dxgi'],
      ],
      libraryDirectories: enabled
          ? [sdk.resolve(core).resolve('.').toFilePath()]
          : [],
    );
    await builder.run(
      input: input,
      output: output,
      logger: Logger('cubism')
        ..onRecord.listen((r) => stdout.writeln(r.message)),
    );
  });
}
