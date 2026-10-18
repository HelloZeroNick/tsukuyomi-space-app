# Android 原生 GPU 渲染

这一版在 Android 默认使用 **Cubism Native OpenGL ES Renderer → EGL window surface → Flutter SurfaceProducer → Texture**。iOS、macOS、Windows、Linux 和 HarmonyOS 继续使用 Canvas 渲染。可以在「房间设置 → 角色 → 角色渲染方式」选择兼容渲染，进行同设备 A/B 对比。

## 数据与线程

- `Live2DGpu.kt` 注册 Flutter 外部纹理。一个进程共享一条 `Tsukuyomi-Cubism-GPU` 线程和一个 EGL context，适配 Cubism 的全局 shader 缓存。
- `.moc3`、物理配置和压缩图集只在加载时交给原生。图集在工作线程解码、按档位缩放并上传 GPU，随后释放 CPU bitmap。
- Dart 保留已有动画、表情和音频幅度的控制逻辑，每帧按原顺序提交一批参数（基础姿态 → 表情 → 动作覆盖 → 实际音频口型）。物理、Cubism 求值、遮罩和全部 ArtMesh 绘制都在原生线程执行。
- GPU 路径不调用 `ts_meshes`，不创建 Dart 网格或 Flutter `Vertices`，不调用 `Picture.toImage`。生产帧不使用 `glReadPixels`；该接口只供显式测试截图使用。
- 普通遮罩使用官方预处理，mask buffer 为 512 × 512，未启用高精度遮罩。继续拒绝目前应用未支持的 Cubism 5.3 离屏/高级混合模型，避免改变资源兼容范围。
- 资源和原生模型生命周期受同一锁保护，Canvas 回退与 GPU 场景短暂共存时不并发访问 Cubism 的全局状态。

## 清晰度与帧任务

| 档位 | 图集最大边长 | GPU 输出总像素上限 | 默认动画目标 |
| --- | ---: | ---: | ---: |
| 自动 | 3072 | 4,000,000 | 60 fps |
| 省电 | 2048 | 1,000,000 | 30 fps |
| 细节优先 | 4096 | 8,000,000 | 60 fps |

输出先使用实际设备 DPR，再受总像素上限、4096 最大边长和 GPU 实际上限约束。计算为：

`有效 DPR = min(设备 DPR, sqrt(像素预算 / 逻辑面积), 最大边长 / 最长逻辑边)`

例如 390 × 800、DPR 3、自动档输出 1170 × 2400，没有额外降采样。角色仍按当前可见布局尺寸绘制，并保持与原 Canvas 相同的居中和 94% 适配比例。外部平移、缩放和旋转继续由 Flutter 合成。

只允许一帧原生任务在途。完成前的动画 tick 被限流，连续 resize 合并到最后尺寸；聊天滚动、输入、隐藏页面、后台和最小化继续复用上一帧。持续负载只降低动画目标帧率，不再悄悄降低所选画质。音频口型读取实际播放幅度，不用渲染帧数推进音频。

## 生命周期与回退

SurfaceProducer 的 Surface 在每次提交时重新取得；尺寸改变、后台清理后产生新 Surface 时重新绑定 EGL，保留模型和纹理。释放场景先在工作线程删除 renderer、图集、窗口 surface 和模型，再释放 Flutter texture。重复打开或 Activity 重建共用同一原生工作线程。

加载失败或 EGL/绘制失败会改用 Canvas，并在角色状态中显示回退原因。设置中也可主动选择兼容渲染。全屏和嵌入场景共用同一个模型和纹理，不新建第二套角色。

## 验证与边界

- `test/live2d_gpu_test.dart` 检查密度与输出预算、参数顺序、任务限流、resize 合并、错误通知和销毁后的迟到回调。
- `tool/probe_android_gpu.dart` 在真正的 Android embedder 中使用发布构建的 Cubism/GLES 渲染：检查 409 个网格与 3K 图集、透明背景、发丝亮色像素、眼睛闭合和口型变化、横竖输出、暂停、Surface 更换，以及销毁后重新创建。显式读回图像保存到 CI 附件，同时保存 Flutter 实际合成截图。
- `tool/verify_mobile_live2d.dart` 同时保留 Canvas 像素回归及 Room IME/滚动验证。`mobile-native.yml` 使用软件渲染 Android 模拟器，因此只能证明构建和功能，不能证明骁龙 GPU 帧率、功耗或温度。
- 角色状态中的更新、绘制提交和帧往返都是 CPU/提交计时，不是 GPU 执行时间。尚未接入 GPU timer query。
- [此前 Canvas 清晰度验证](native-live2d-mobile-parity.md) 的 M5 数据仅适用于 Canvas 路径，不能作为 Android 原生 GPU 的性能收益。
- Redmi K90 的同设备 A/B、15 分钟持续运行、温度/内存以及后台恢复实机验收仍需在设备上完成。此阶段没有移植 Metal/D3D/Linux/OHOS 的 GPU renderer。

## 一手参考

- [Flutter Android SurfaceProducer 迁移说明](https://docs.flutter.dev/release/breaking-changes/android-surface-plugins)
- [Flutter SurfaceProducer 生命周期接口](https://api.flutter.dev/javadoc/io/flutter/view/TextureRegistry.SurfaceProducer.html)
- [Live2D 官方 Native Samples](https://github.com/Live2D/CubismNativeSamples)
- [Live2D 官方 Native Framework](https://github.com/Live2D/CubismNativeFramework)

SDK 与 shader 来自现有校验固定版本 `CubismSdkForNative-5-r.5`。构建 hook 将 SDK 内 StandardES shader 嵌入原生库，避免运行时文件路径依赖；SDK 源文件仍由已存在的许可获取流程准备，不提交 vendor 目录。

## 同设备 Room A/B

在相同电量模式、亮度、刷新率、画质和环境温度下，依次运行以下命令。输出包含 UI/Raster P95、原生更新和提交耗时、帧往返 P95、进程 RSS、输出 DPR、交互暂停及隐藏页更新次数。`gpu` 模式失败会直接报错，不能偷偷回退后标记为 GPU 数据。

```sh
flutter drive --profile -d <Android设备ID> --driver test_driver/performance_driver.dart --target integration_test/room_performance_test.dart --dart-define=BENCHMARK_CHAT_SCROLL=true --dart-define=BENCHMARK_RENDERER=canvas --dart-define=BENCHMARK_LABEL=k90-canvas
flutter drive --profile -d <Android设备ID> --driver test_driver/performance_driver.dart --target integration_test/room_performance_test.dart --dart-define=BENCHMARK_CHAT_SCROLL=true --dart-define=BENCHMARK_RENDERER=gpu --dart-define=BENCHMARK_LABEL=k90-gpu
```

这两个短基准不能替代 15 分钟持续运行或实际说话/唱歌验收；温度、电池消耗、GPU 执行时间需另外采集。
