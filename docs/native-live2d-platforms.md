# Live2D 原生纹理平台适配

依据「搜索Live2D性能优化」讨论扩展已有 Android GPU 接口。模型、动作参数顺序、实际音频幅度口型、画质预算、单帧限流、交互期间继续动画和 Canvas 回退保持共用；不支持的 Cubism 5.3 高级混合/离屏模型仍在创建时拒绝。

| 平台 | 官方渲染器与 Flutter 交付 | 资源与同步 |
| --- | --- | --- |
| Android | OpenGL ES → SurfaceProducer | 保留已有 EGL 工作线程、窗口 Surface 重建 |
| iOS/macOS | Metal → IOSurface/CVPixelBuffer → FlutterTexture | 共用串行工作队列；最多三个输出缓冲；命令完成后通知 Flutter；Flutter 持有的缓冲不能复用 |
| Windows | D3D11 → DXGI shared handle → GpuSurfaceTexture | 共用工作线程/device；完成查询后交付；三个输出槽，释放回调管理消费期间的所有权 |
| Linux | OpenGL → FlTextureGL | 私有 GDK 共享上下文；加载/图集解码在工作池；有待处理帧时在纹理回调绘制，保存/恢复 Flutter 上下文，跨上下文同步 |
| HarmonyOS | 现有 Native Core + Canvas | 本次不注册 GPU 插件；自动模式说明回退原因；强制 GPU 报错 |

所有新平台通过进程内 `TsGpuApi` 使用 native-assets 中同一份 Cubism。Dart 只在创建时传 API 地址与压缩资源，每帧仍是一批有序参数，不传网格或像素。版本检查避免接口不匹配。Apple 的原生资源库名称与 CocoaPods 插件不同，避免 framework 覆盖导致 FFI 找不到 Core 符号。

Apple/Windows 的正常帧没有 CPU 像素读回；Linux 同样不读回，但它的提交发生在 Flutter 的原生纹理回调中，GPU 同步可能占用 raster 时间，不能将它描述为完全独立的渲染线程。隐藏窗口不消费纹理时，500 ms 内解除待处理帧的背压，不推进隐藏场景。实际性能收益需要同设备 A/B。

图集只在加载时解码、缩放为预乘 alpha 并生成完整 mip 链；图集内存估计包括 mip 层。输出沿用真实 DPR、总像素预算和 4096 最大边长。Apple 使用 BGRA8Unorm 与 Depth32Float，颜色缓冲具备 IOSurface/Metal 兼容属性。GPU 完成计时包含等待，仍不是独立 GPU timer query。

SDK vendor 文件保持原样。构建时对固定 SDK 生成源码：

- Metal 内嵌官方基础 shader，按 device 编译，去掉不支持的高级混合预热，并补齐共享 shader/pipeline 的去重释放。
- D3D11 内嵌官方 FX，保留普通、加算、乘算、正反遮罩，去掉高级混合预热。
- Linux 使用 libepoxy 与 GTK 相同的上下文分派；将官方 GLSL 120 转换为 core profile 的 GLSL 150，使用可复用 VAO/VBO/EBO 代替 client arrays，兼容 GTK 的 core context。掩码与混合算法保持官方实现。
- 源码匹配不符合固定 SDK 结构时构建失败，要求复核 SDK 更新。

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

2026-10-20 本机 macOS Metal 已通过两轮图像探针，检查了导出的角色图像；其余平台的最终构建/运行结果随本次验证补充。物理 iPhone、Windows/Linux 显卡、15 分钟持续运行、后台恢复及同设备 Room A/B 仍需目标设备验证。

## 一手接口

- [Flutter iOS/macOS FlutterTexture](https://api.flutter.dev/ios-embedder/protocol_flutter_texture-p.html)
- [Flutter Windows GPU surface descriptor](https://api.flutter.dev/windows-embedder/struct_flutter_desktop_gpu_surface_descriptor.html)
- [Flutter Linux FlTextureGL](https://api.flutter.dev/linux-embedder/struct___fl_texture_g_l_class.html)
- [Cubism Native Framework](https://github.com/Live2D/CubismNativeFramework)
