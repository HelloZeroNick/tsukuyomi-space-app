# 移动端 Live2D 清晰度与帧率修正

2026-10-18，基于 `79aae01` 的 Canvas 路径验证，改动纳入 0.6.22。Android 默认路径另见 [原生 GPU 渲染](native-live2d-gpu.md)；以下 M5 数据仅适用于 Canvas。用户提供的第二张图为 App 实机截图；静态截图可见边缘锯齿，不能据此测量动画帧率。

## 代码中的差异与修正

原生端原先将所有画质档的纹理限制为 2048；手机自动档每个普通合成段只有 450,000 像素，并会在连续 Raster 超过显示器刷新间隔时进一步减半。120Hz 屏幕因而会按 8.33ms 判断一个默认只更新 30fps 的角色，导致画质下降。网页端的 Room 帧调度以 60fps 为目标。

| 档位 | 纹理边长上限 | 普通合成段像素上限 | 自动帧率目标 |
| --- | ---: | ---: | ---: |
| 自动 | 3072 | 2,000,000 | 60fps |
| 细节优先 | 4096 | 不降采样，按设备像素直接绘制 | 60fps |
| 省电 | 2048 | 手机 225,000 / 桌面 450,000 | 30fps |

2,000,000 是每段上限，不是整帧总量。用户明确选择的 30/60fps 继续作为上限，实际目标还受屏幕刷新率限制。负载连续超标时降低动画帧率，保持所选画质；持续恢复后再提高帧率。判断包含 UI/Raster、模型更新、快照录制和异步快照延迟，后者是墙钟时间，不是 GPU 利用率。59.94Hz 按约 60Hz 调度。

仍保留聊天拖动、输入期间的模型暂停、单帧异步背压、隐藏/后台/最小化暂停，以及嵌入/全屏共用模型。没有更改模型素材、动作、网页端代码或聊天布局。

## 原生图像验证

macOS 27.0.1 / Apple M5 / Flutter 3.47.5 Profile，Impeller MetalSDF。使用同一原始姿态和原始 4096 纹理参考，比较改变前后的自动档；没有锐化图片。手机尺寸为 585×760 逻辑像素、DPR 3，输出 1755×2280。

| 场景 | 平均 RGBA 像素误差：修改前 → 修改后 |
| --- | ---: |
| 手机尺寸 | 2.3722 → 1.1633 |
| 桌面尺寸 | 2.1997 → 0.8342 |
| 全屏尺寸 | 2.2023 → 0.8261 |

误差只统计参考 alpha≥128 的角色像素，四通道值范围 0–255。手机误差降低约 51%，不等于主观清晰度提高 51%，也不是 Android 真机截图或网页画面逐像素对齐。

原始数据：[修改前](qa/live2d-mobile-parity-20261018/sharpness-before.json)、[修改后](qa/live2d-mobile-parity-20261018/sharpness-after.json)。本地原图位于 `artifacts/live2d-mobile-parity/{before,after}/`。自动档两张 RGBA 纹理从 32MiB 增至 72MiB，细节优先为 128MiB，均不含其他模型/GPU/应用内存。手机场景每帧普通合成图总像素从 1,050,503 增至 2,595,221，不宣称画质提升同时降低 GPU 或内存负载。

## Room 原生负载检查

使用现有 2,000 轮聊天、200 张有效 WebP、长 Markdown、流式回复及拖动负载，Mac 原生窗口内显示手机布局，角色视口 585×714.6、DPR 2，连续完成三轮。应用真实获得焦点，未在采样期间操作 UI；driver 退出码 0，全部断言通过。

| 轮次 | UI P95 | Raster P95 | 超过 16.7ms 的帧 | 空闲 2 秒模型更新 | 隐藏模型更新 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 | 1.952ms | 13.407ms | 7 | 121 | 0 |
| 2 | 1.848ms | 13.428ms | 4 | 121 | 0 |
| 3 | 1.948ms | 13.497ms | 4 | 121 | 0 |

三轮均完成十次交互暂停，舞台组件和视口没有改变，图片无解码错误。仍有少量超预算帧；本次未进行相同负载的性能基线复跑，不宣称性能提升百分比。这是 Mac 的手机布局检查，使用 macOS 渲染后端和平台策略，不能替代 Android 的 DPR 3、Impeller/Vulkan 和真机功耗测试。

数据：[通过的三轮](qa/live2d-mobile-parity-20261018/performance-after.json)。[第一次尝试](qa/live2d-mobile-parity-20261018/performance-attempt-1.json)因测试中途启用无障碍导致收尾 SemanticsHandle 检查失败，仅保留为诊断，不计入通过结果；复跑先启动暂停的测试应用、前置并读取无障碍状态，再连接 driver 恢复执行。

## 回归与真机边界

针对 Live2D、Room 交互、设置、聊天滚动和输入法的回归累计 110 项通过、1 项既有测试跳过，真实 Cubism 检查启用。覆盖高刷新率不降低画质、持续负载降频/恢复、异步快照负载、59.94/60/90/120/144Hz 调度、原始/高清纹理解码、遮罩/染色/混合/眨眼，以及隐藏和交互暂停。当前自动档 DPR 3 的异步快照与同步参考逐通道最大差为 0，没有失败或额外缓存重绘。

当前工作区未连接 Android/iOS 手机，没有构建、安装或发布新 APK。帧率目标调整与桌面检查不能证明红米 K90 已稳定 60fps，仍需要真机测量持续动画、发热、功耗及聊天时的响应。

复测入口：

```sh
flutter run --profile -d macos -t tool/verify_live2d_sharpness.dart --dart-define=CLARITY_LABEL=mobile-parity-after
flutter test --dart-define=RUN_CUBISM_TESTS=true test/live2d_scene_controller_test.dart test/live2d_async_frame_test.dart test/live2d_renderer_test.dart test/live2d_native_test.dart test/live2d_blink_test.dart
flutter drive --profile -d DEVICE_ID --driver=test_driver/performance_driver.dart --target=integration_test/room_performance_test.dart --dart-define=BENCHMARK_CHAT_SCROLL=true --dart-define=BENCHMARK_LABEL=live2d-device-after
```

使用独立测试设备/测试用户，保留个人安装和聊天数据。设备复测需记录型号、系统、刷新率、画质、帧率设置和源码版本；详见 [Room 测试流程](qa/room-refactor-v0.6.21/device-benchmark.md)。该旧流程中的固定 2048 仅属于当时的基线，测试本次候选应使用表中的当前设置。
