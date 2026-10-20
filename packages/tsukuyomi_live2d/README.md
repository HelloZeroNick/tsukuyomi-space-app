# tsukuyomi_live2d

A native Cubism model/physics adapter, official GPU renderers and Canvas fallback.

The FFI ABI is maintained in `src/bridge.cpp` and `lib/bindings.dart`. Flutter's
native-assets build hook compiles the C++ adapter and links the local official
Core static library. GPU plugins share this native asset through `src/gpu_api.h`.
Android uses GLES/SurfaceProducer, Apple uses Metal/IOSurface pixel buffers,
Windows uses D3D11 shared surfaces, and Linux uses OpenGL/FlTextureGL.

Canvas models remain owned by the Flutter UI isolate. GPU models are owned by
the platform rendering path. A process-wide recursive mutex serializes Cubism
allocator, model and renderer access during transitions. Dispose models to free
native resources. CPU pixel readback is restricted to explicit QA snapshots.

Run the root project's `tool/setup_live2d.py` to prepare the SDK and model. When
the selected SDK/platform ABI is absent, the library reports `nativeAvailable=0`;
the app displays a clearly labelled illustration preview. Changing SDK availability
requires `flutter clean` before rebuilding.

Build selection covers macOS arm64/x64, Android, iOS, Windows x86/x64 and Linux
x64. See the root `docs/native-live2d-platforms.md` for current validation and
remaining device acceptance. HarmonyOS retains Canvas. Windows arm64 and Linux arm64 use the unavailable path
because this SDK package does not include matching Core libraries. Web uses the
Dart unavailable adapter.

Cubism Core/Framework code and binaries are not committed. None of the paths
implements Cubism 5.3 advanced/offscreen blending,
which is rejected at load time instead of silently misrendering.
