# 原生 GPU 渲染

Android 使用 **Cubism Native OpenGL ES Renderer → RGBA 渲染纹理 → EGL window surface → Flutter SurfaceProducer → Texture**。iOS/macOS 新增 Metal，Windows 新增 D3D11，Linux 新增 OpenGL 外部纹理。HarmonyOS 按参考文档保留 Canvas，待对应 embedder 单独适配。可以在「房间设置 → 角色 → 角色渲染方式」选择兼容渲染，进行同设备 A/B 对比。

跨平台实现、验证与限制见 [剩余平台适配](native-live2d-platforms.md)。下文的 SurfaceProducer、EGL 和 Android 探针细节专指 Android。

## 数据与线程

- `Live2DGpu.kt` 注册 Flutter 外部纹理。一个进程共享一条 `Tsukuyomi-Cubism-GPU` 线程和一个 EGL context，适配 Cubism 的全局 shader 缓存。
- `.moc3`、物理配置和压缩图集只在加载时交给原生。图集在工作线程解码、按档位缩放并上传 GPU，随后释放 CPU bitmap。
- 按官方 renderer 的 mipmap 采样要求，在上传时生成完整 mip 链；旧 GLES2 缺少完整 NPOT 支持时使用向下取整的二次幂图集尺寸。两张 3K RGBA 图集连同 mip 链约占 96 MiB，状态和基准中的图集估算包含这些层级，不包含输出纹理、窗口缓冲及驱动额外内存。
- Dart 保留已有动画、表情和音频幅度的控制逻辑，每帧按原顺序提交一批参数（基础姿态 → 表情 → 动作覆盖 → 实际音频口型）。物理、Cubism 求值、遮罩和全部 ArtMesh 绘制都在原生线程执行。
- GPU 路径不调用 `ts_meshes`，不创建 Dart 网格或 Flutter `Vertices`，不调用 `Picture.toImage`。生产帧不使用 `glReadPixels`；该接口只供显式测试截图使用。
- 场景复用一个 RGBA 输出纹理和 FBO，仅在尺寸变化时重新分配。绘制完成后用 GPU 全屏拷贝提交到窗口 Surface；测试读取保留的输出纹理，避免读取已交换的窗口缓冲。
- 普通遮罩使用官方预处理，mask buffer 为 512 × 512，未启用高精度遮罩。继续拒绝目前应用未支持的 Cubism 5.3 离屏/高级混合模型，避免改变资源兼容范围。
- 资源和原生模型生命周期受同一锁保护，Canvas 回退与 GPU 场景短暂共存时不并发访问 Cubism 的全局状态。

## 启动加载

0.6.23 并行读取独立的 moc、物理、图集和表情资源，全部就绪后才创建原生场景。构建 hook 对固定 SDK 生成专用源码，移除目前不支持的高级混合模式预编译/变量查询块；保留官方普通、加算、乘算、遮罩与反向遮罩。原来每次冷建 context 会编译 482 个 SDK 程序，现在为 8 个（不含应用的输出拷贝程序）。高级混合/离屏模型仍在 renderer 初始化之前被拒绝，未扩展兼容范围，也未降低图集或输出分辨率。

SDK vendor 保持不变，生成源码仅存在于构建目录；SDK 结构变化导致匹配不符时构建失败，需重新审查。测试检查遗留 shader 和别名保留，Android 探针检查实际读取 16 份 shader 源码（8 对）、完整像素、重新创建与滚动时的帧提交。角色状态显示模型加载时间；探针另外记录资源读取、原生初始化、图集解码/上传和首帧墙钟时间。这些计时用于定位耗时，模拟器结果不能代表手机加载速度。

## 清晰度与帧任务

| 档位 | 图集最大边长 | GPU 输出总像素上限 | 默认动画目标 |
| --- | ---: | ---: | ---: |
| 自动 | 3072 | 4,000,000 | 60 fps |
| 省电 | 2048 | 1,000,000 | 30 fps |
| 细节优先 | 4096 | 8,000,000 | 60 fps |

输出先使用实际设备 DPR，再受总像素上限、4096 最大边长和 GPU 实际上限约束。计算为：

`有效 DPR = min(设备 DPR, sqrt(像素预算 / 逻辑面积), 最大边长 / 最长逻辑边)`

例如 390 × 800、DPR 3、自动档输出 1170 × 2400，没有额外降采样。角色仍按当前可见布局尺寸绘制，并保持与原 Canvas 相同的居中和 94% 适配比例。外部平移、缩放和旋转继续由 Flutter 合成。

只允许一帧原生任务在途。完成前的动画 tick 被限流，连续 resize 合并到最后尺寸；聊天滚动和输入时继续推进动画，原生 GPU 保持所选帧率目标；Canvas 在交互时最高 30 fps。隐藏页面、后台、最小化和手动暂停仍停止更新。持续负载只降低动画目标帧率，不再悄悄降低所选画质。音频口型读取实际播放幅度，不用渲染帧数推进音频。

## 生命周期与回退

SurfaceProducer 的 Surface 在每次提交时重新取得；尺寸改变、后台清理后产生新 Surface 时重新绑定 EGL，保留模型和纹理。释放场景先在工作线程删除 renderer、图集、窗口 surface 和模型，再释放 Flutter texture。重复打开或 Activity 重建共用同一原生工作线程。

加载失败或 EGL/绘制失败会改用 Canvas，并在角色状态中显示回退原因。设置中也可主动选择兼容渲染。全屏和嵌入场景共用同一个模型和纹理，不新建第二套角色。

## 验证与边界

- `test/live2d_gpu_test.dart` 检查密度与输出预算、参数顺序、任务限流、resize 合并、错误通知和销毁后的迟到回调。
- `tool/probe_android_gpu.dart` 在真正的 Android embedder 中使用发布构建的 Cubism/GLES 渲染：检查 409 个网格与 3K 图集、透明背景、发丝亮色像素、眼睛闭合和口型变化、横竖输出、暂停、Surface 更换，以及销毁后重新创建。显式读回图像保存到 CI 附件，同时保存 Flutter 实际合成截图。
- `tool/verify_mobile_live2d.dart` 同时保留 Canvas 像素回归及 Room IME/滚动验证。`mobile-native.yml` 使用软件渲染 Android 模拟器，因此只能证明构建和功能，不能证明骁龙 GPU 帧率、功耗或温度。
- 角色状态中的更新、绘制提交和帧往返都是 CPU/提交计时，不是 GPU 执行时间。尚未接入 GPU timer query。
- [此前 Canvas 清晰度验证](native-live2d-mobile-parity.md) 的 M5 数据仅适用于 Canvas 路径，不能作为 Android 原生 GPU 的性能收益。
- Redmi K90 的同设备 A/B、15 分钟持续运行、温度/内存以及后台恢复实机验收仍需在设备上完成。新平台的验证不能替代这项验收。

## 一手参考

- [Flutter Android SurfaceProducer 迁移说明](https://docs.flutter.dev/release/breaking-changes/android-surface-plugins)
- [Flutter SurfaceProducer 生命周期接口](https://api.flutter.dev/javadoc/io/flutter/view/TextureRegistry.SurfaceProducer.html)
- [Live2D 官方 Native Samples](https://github.com/Live2D/CubismNativeSamples)
- [Live2D 官方 Native Framework](https://github.com/Live2D/CubismNativeFramework)

SDK 与 shader 来自现有校验固定版本 `CubismSdkForNative-5-r.5`。构建 hook 将 SDK 内 StandardES shader 嵌入原生库，避免运行时文件路径依赖；SDK 源文件仍由已存在的许可获取流程准备，不提交 vendor 目录。

## 同设备 Room A/B

在相同电量模式、亮度、刷新率、画质和环境温度下，依次运行以下命令。输出包含 UI/Raster P95、原生更新和提交耗时、帧往返 P95、进程 RSS、输出 DPR、交互期间完成帧数及隐藏页更新次数。`gpu` 模式失败会直接报错，不能偷偷回退后标记为 GPU 数据。

```sh
flutter drive --profile -d <Android设备ID> --driver test_driver/performance_driver.dart --target integration_test/room_performance_test.dart --dart-define=BENCHMARK_CHAT_SCROLL=true --dart-define=BENCHMARK_RENDERER=canvas --dart-define=BENCHMARK_LABEL=k90-canvas
flutter drive --profile -d <Android设备ID> --driver test_driver/performance_driver.dart --target integration_test/room_performance_test.dart --dart-define=BENCHMARK_CHAT_SCROLL=true --dart-define=BENCHMARK_RENDERER=gpu --dart-define=BENCHMARK_LABEL=k90-gpu
```

这两个短基准不能替代 15 分钟持续运行或实际说话/唱歌验收；温度、电池消耗、GPU 执行时间需另外采集。
