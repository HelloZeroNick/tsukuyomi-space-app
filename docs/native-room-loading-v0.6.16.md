# Live2D 加载期间移除立绘兜底

0.6.16+22 / v0.6.16-beta.1。

Room 和全屏舞台加载模型时使用空的角色区域，保留房间背景及简短加载状态。成功后直接显示原生画布，没有静态角色图、图片交叉淡入或 Access 动画。失败时显示状态与重试入口，聊天仍可使用。Hub 的正常插图和头像保持原用途。

加载与失败状态使用中文、日语、英语。沿用所有画质档2048纹理、手机／桌面自动绘制预算450,000／600,000、待机画布单独重绘、鼠标追踪关闭及隐藏暂停。

## 检查

本地45项Room与场景回归通过，静态分析、格式检查通过。新增模型延迟时的移动／桌面背景、无兜底图片、加载完成和全屏布局检查；失败后重试，以及模型仍在加载或加载失败时完成聊天的检查。真实Cubism和五平台验证继续使用原有发布流程。

## 性能用例校正

补查发现旧1×1 PNG的IDAT校验错误，v0.6.13至v0.6.15的200条图片fixture实际显示失败占位；相关表格仅代表此占位消息负载，不能作为实际图片解码负载证据。纹理尺寸、原生渲染、消息、流式回复和隐藏更新计数仍来自对应真实采样。

`integration_test/room_performance_test.dart`现使用内置有效WebP头像素材，先通过Flutter解码验证，记录宽、高及编码字节，滚动后检查可见图片没有失败占位。基线模式使用当前UI、3072纹理及900,000绘制预算模拟上版默认绘制参数；本版使用2048及600,000，双方各三轮。Android真机与9070／4060未连接，本机采样不能证明其实际帧率和GPU占用。

```sh
flutter test test/live2d_scene_controller_test.dart test/room_widget_test.dart test/room_first_and_menu_test.dart
flutter drive --profile -d macos --driver=test_driver/performance_driver.dart --target=integration_test/room_performance_test.dart --dart-define=BENCHMARK_LABEL=valid-images-before --dart-define=BENCHMARK_BASELINE=true --dart-define=BENCHMARK_TEXTURE_SIZE=3072
flutter drive --profile -d macos --driver=test_driver/performance_driver.dart --target=integration_test/room_performance_test.dart --dart-define=BENCHMARK_LABEL=valid-images-after
```

完整有效图片对比、CI与发布附件校验记录在完成后补充。
