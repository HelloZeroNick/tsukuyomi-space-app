import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

import 'legacy_shaders.dart';

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
    final gpu = enabled && os == OS.android;
    final generatedIncludes = <String>[];
    if (gpu) {
      // Embed the pinned SDK's GLES shaders in the native library. They must
      // not depend on a working directory or an Android asset path at runtime.
      final shaders = Directory.fromUri(
        sdk.resolve('Framework/src/Rendering/OpenGL/Shaders/StandardES/'),
      );
      final header = File.fromUri(
        input.outputDirectory.resolve('gpu_shaders.h'),
      );
      final source = StringBuffer(
        '#include <cstring>\n#include <string>\n'
        'static const char* ts_shader(const std::string& name) {\n',
      );
      final files = shaders.listSync().whereType<File>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final file in files) {
        if (!file.path.endsWith('.frag') && !file.path.endsWith('.vert')) {
          continue;
        }
        final content = file.readAsStringSync();
        source.writeln(
          'if (name == "${file.uri.pathSegments.last}") return R"TS_SHADER($content)TS_SHADER";',
        );
        output.dependencies.add(file.uri);
      }
      source.writeln('return nullptr; }');
      await header.writeAsString(source.toString());
      generatedIncludes.add(header.parent.path);
      output.dependencies.add(input.packageRoot.resolve('src/android_gpu.inc'));
    }
    if (enabled) {
      final framework = Directory.fromUri(sdk.resolve('Framework/src/'));
      for (final file
          in framework.listSync(recursive: true).whereType<File>()) {
        if (file.path.endsWith('.cpp') &&
            (!file.uri.path.contains('/Rendering/') ||
                file.uri.path.endsWith('/csmBlendMode.cpp') ||
                (gpu &&
                    (file.uri.path.contains('/Rendering/OpenGL/') ||
                        file.uri.path.endsWith(
                          '/Rendering/CubismRenderer.cpp',
                        )))) &&
            !file.uri.path.endsWith('/CubismUserModel.cpp')) {
          if (gpu && file.uri.path.endsWith('/CubismShader_OpenGLES2.cpp')) {
            final specialized = File.fromUri(
              input.outputDirectory.resolve('CubismShader_Legacy.cpp'),
            );
            await specialized.writeAsString(
              legacyShaderSource(file.readAsStringSync()),
            );
            generatedIncludes.add(file.parent.path);
            output.dependencies.add(file.uri);
            output.dependencies.add(
              input.packageRoot.resolve('hook/legacy_shaders.dart'),
            );
            sources.add(specialized.path);
          } else {
            sources.add(file.path);
          }
        }
      }
      output.dependencies.add(sdk.resolve(core));
    }
    final builder = CBuilder.library(
      name: input.packageName,
      assetName: 'bindings.dart',
      sources: sources,
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
              ...generatedIncludes,
            ]
          : [],
      defines: {
        'TS_HAS_CUBISM': enabled ? '1' : '0',
        if (gpu) 'CSM_TARGET_ANDROID_ES2': '1',
      },
      flags: os == OS.windows
          ? ['/std:c++17', '/MD']
          : [
              '-std=c++17',
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
        if (gpu) ...['EGL', 'GLESv2', 'android', 'jnigraphics'],
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
