# Live2D 原生纹理平台适配

依据「搜索Live2D性能优化」讨论扩展已有 Android GPU 接口。模型、动作参数顺序、实际音频幅度口型、画质预算、单帧限流、交互期间继续动画和 Canvas 回退保持共用；不支持的 Cubism 5.3 高级混合/离屏模型仍在创建时拒绝。

| 平台 | 官方渲染器与 Flutter 交付 | 资源与同步 |
| --- | --- | --- |
| Android | OpenGL ES → SurfaceProducer | 保留已有 EGL 工作线程、窗口 Surface 重建 |
| iOS/macOS | Metal → IOSurface/CVPixelBuffer → FlutterTexture | 共用串行工作队列；最多三个输出缓冲；命令完成后通知 Flutter；Flutter 持有的缓冲不能复用 |
| Windows | D3D11 → DXGI shared handle → GpuSurfaceTexture | 共用工作线程/device；复用私有渲染目标；GPU 拷贝到不可变共享帧，完成查询后交付 |
| Linux x64 | OpenGL ES / EGL → FlTextureGL | 模型初始化在工作池；首个纹理回调创建与 Flutter 共享的 EGL 上下文并上传图集；后续回调计算、绘制并恢复 Flutter 上下文 |
| HarmonyOS | 现有 Native Core + Canvas | 本次不注册 GPU 插件；自动模式说明回退原因；强制 GPU 报错 |

所有新平台通过进程内 `TsGpuApi` 使用 native-assets 中同一份 Cubism。Dart 只在创建时传 API 地址与模型/图集资源，每帧仍是一批有序参数，不传网格或像素。版本检查避免接口不匹配。Apple 的原生资源库名称与 CocoaPods 插件不同，避免 framework 覆盖导致 FFI 找不到 Core 符号。

Apple/Windows 的正常帧没有 CPU 像素读回；Linux 插件也不读回，但它的提交发生在 Flutter 的原生纹理回调中，GPU 同步可能占用 raster 时间，不能将它描述为完全独立的渲染线程。隐藏窗口不消费纹理时，500 ms 内解除待处理帧的背压，不推进隐藏场景。Flutter 3.47.5 的 X11 窗口合成本身包含 CPU 拷贝，Wayland 使用 EGLImage；插件不能将 X11 的完整显示链路宣称为零拷贝。实际性能收益需要同设备 A/B。

Windows 的 registrar 释放回调仅表示完成纹理导入，后续仍可能读取描述信息和采样纹理。因此描述信息保留到下次回调，已交付的共享纹理不覆写；每帧额外创建共享呈现纹理并做 GPU 拷贝。私有 Cubism 渲染目标只在 resize 时重建。这项分配成本是当前适配的性能限制，不能宣称 Windows 已实现全程复用或零拷贝。

图集只在加载时解码、缩放为预乘 alpha 并生成完整 mip 链；Windows/Linux 使用 Flutter 自带解码器一次性解码并上传，避免依赖系统额外安装 WebP codec；图集内存估计包括 mip 层。输出沿用真实 DPR、总像素预算和 4096 最大边长。Apple 使用 BGRA8Unorm 与 Depth32Float，颜色缓冲具备 IOSurface/Metal 兼容属性。GPU 完成计时包含等待，仍不是独立 GPU timer query。

SDK vendor 文件保持原样。构建时对固定 SDK 生成源码：

- Metal 内嵌官方基础 shader，按 device 编译，去掉不支持的高级混合预热，并补齐共享 shader/pipeline 的去重释放。
- D3D11 内嵌官方 FX，保留普通、加算、乘算、正反遮罩，去掉高级混合预热。
- Linux 对齐固定 Flutter 3.47.5 的 EGL/OpenGL ES embedder，使用官方 StandardES shader。libepoxy 分派到当前上下文，使用可复用 VBO/EBO（ES 3 上另有 VAO），不依赖 GTK 的 GLX 纹理共享。掩码与混合算法保持官方实现。
- 源码匹配不符合固定 SDK 结构时构建失败，要求复核 SDK 更新。

Linux 在 Dart 尚未提交尺寸时交付透明首帧，避免空纹理导入阻断后续刷新。正常绘制恢复 Flutter 的 EGL 上下文；诊断读回和销毁还会保存并恢复平台线程的 EGL API 与 GTK GLX 绑定。`populate` 失败时始终提供 `GError`，符合固定 embedder 的错误处理约定。

## 验证

`tool/probe_native_gpu.dart` 强制请求 GPU，回退不能算通过。复用 Android 探针检查 409 个网格、3K 图集、透明边角、半透明/亮色发丝、眨眼和口型像素变化、横竖输出、隐藏暂停、交互帧提交，以及两轮销毁后重建。`snapshot` 只供显式 QA，生产帧不调用。输出 PNG 与 `metrics.json`；只有全部通过才写出 metrics。

```sh
flutter run -d macos -t tool/probe_native_gpu.dart \
  --dart-define=NATIVE_GPU_QA_DIR=artifacts/native-gpu/macos
flutter run -d linux -t tool/probe_native_gpu.dart \
  --dart-define=NATIVE_GPU_QA_DIR=artifacts/native-gpu/linux
flutter run -d windows -t tool/probe_native_gpu.dart \
  --dart-define=NATIVE_GPU_QA_DIR=artifacts/native-gpu/windows
flutter run -d <iOS设备或模拟器ID> -t tool/probe_native_gpu.dart
```

`.github/workflows/native-gpu-platforms.yml` 编译 iOS 无签名设备包，并运行 Linux Mesa / Windows WARP 图像验证。WARP 只通过显式测试环境变量 `TSUKUYOMI_GPU_QA_WARP=1` 启用；普通应用不自动切换软件 D3D。CI 软件 GPU 验证只证明功能，不能代表真实设备的帧率、功耗或温度。

2026-10-20 验证记录：

| 验证环境 | 结果 |
| --- | --- |
| macOS / 本机 Metal | 两轮图像探针通过，人工检查导出的角色图像 |
| iPhone 18 Pro / iOS 27 模拟器 | 两轮 Metal 图像探针通过，人工检查透明与方向 |
| iOS arm64 / CI 设备构建 | `flutter build ios --release --no-codesign` 通过；产物未签名 |
| Windows 2022 / D3D11 WARP | 两轮图像探针通过，并检查实际 Flutter 合成截图 |
| Linux x64 / Mesa llvmpipe / X11 | 两轮图像探针通过，并检查实际 Flutter 合成截图 |
| Android 35 x86_64 / SwiftShader | 现有 mobile-native 流程通过，包括 GPU 两轮重建与 Room 回归 |
| 本机 Dart / Native Core | 全套测试 947 通过、40 跳过；额外启用实际 Cubism 的测试通过；最新 GPU/Shader 专项 15 项通过；静态分析无问题 |

探针的逐帧计时包含调试模式、同步与软件 GPU 开销，不用于跨设备性能比较。物理 iPhone、Windows/Linux 显卡、15 分钟持续运行、系统后台恢复及同设备 Room A/B 仍需目标设备验证。Linux 同一 Flutter engine 可共享 SDK shader 资源；多个独立 engine 同时请求 GPU 时，后者会明确报错并由自动模式回退 Canvas，避免跨 EGL share group 误用资源。

中立姿态的 macOS/iOS 模拟器 RGBA 像素一致；Windows/Linux 与 Metal 的角色 alpha 边界一致，逐通道全图平均绝对差均小于 0.5/255。该检查验证方向、构图与基本颜色一致性，不代替所有动作、遮罩模型和真实显卡的验收。

CI 记录：[新平台构建与图像探针](https://github.com/redchenk/tsukuyomi-space-app/actions/runs/39409888614)（实现提交 `1d9b39a`）、[Android 原生/Room 回归](https://github.com/redchenk/tsukuyomi-space-app/actions/runs/39404470002)。本机图像与指标保存在忽略的 `artifacts/native-gpu/` 下；CI 附件包括 PNG、`metrics.json`、日志和桌面合成截图。

## 一手接口

- [Flutter iOS/macOS FlutterTexture](https://api.flutter.dev/ios-embedder/protocol_flutter_texture-p.html)
- [Flutter Windows GPU surface descriptor](https://api.flutter.dev/windows-embedder/struct_flutter_desktop_gpu_surface_descriptor.html)
- [Flutter Linux FlTextureGL](https://api.flutter.dev/linux-embedder/struct___fl_texture_g_l_class.html)
- [Cubism Native Framework](https://github.com/Live2D/CubismNativeFramework)
- [固定 Flutter 3.47.5 EGL 管理](https://github.com/flutter/flutter/blob/6a19cca56475dbfba1478ee68d7bd0c2ef891da1/engine/src/flutter/shell/platform/linux/fl_opengl_manager.cc)
- [固定 Flutter 3.47.5 X11/Wayland 合成差异](https://github.com/flutter/flutter/blob/6a19cca56475dbfba1478ee68d7bd0c2ef891da1/engine/src/flutter/shell/platform/linux/fl_view_renderer.cc)
- [固定 Flutter 3.47.5 纹理未就绪时的错误处理](https://github.com/flutter/flutter/blob/6a19cca56475dbfba1478ee68d7bd0c2ef891da1/engine/src/flutter/shell/platform/linux/fl_engine.cc#L433-L471)
