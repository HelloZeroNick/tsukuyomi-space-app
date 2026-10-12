# Live2D 加载期间移除立绘兜底

0.6.16+22 / v0.6.16-beta.1。

Room 和全屏舞台加载模型时使用空的角色区域，保留房间背景及简短加载状态。成功后直接显示原生画布，没有静态角色图、图片交叉淡入或 Access 动画。失败时显示状态与重试入口，聊天仍可使用。Hub 的正常插图和头像保持原用途。

加载与失败状态使用中文、日语、英语。沿用所有画质档2048纹理、手机／桌面自动绘制预算450,000／600,000、待机画布单独重绘、鼠标追踪关闭及隐藏暂停。

## 检查

本地完整回归851项通过、34项可选检查跳过，45项Room与场景检查及8项真实Cubism／背景动作检查通过，静态分析、格式检查通过。新增模型延迟时的移动／桌面背景、无兜底图片、加载完成和全屏布局检查；失败后重试，以及模型仍在加载或加载失败时完成聊天的检查。真实Cubism和五平台验证继续使用原有发布流程。

## 性能用例校正

补查发现旧1×1 PNG的IDAT校验错误，v0.6.13至v0.6.15的200条图片fixture实际显示失败占位；相关表格仅代表此占位消息负载，不能作为实际图片解码负载证据。纹理尺寸、原生渲染、消息、流式回复和隐藏更新计数仍来自对应真实采样。

`integration_test/room_performance_test.dart`现使用内置有效WebP头像素材，先通过Flutter解码验证，记录宽、高及编码字节，滚动后检查可见图片没有失败占位。基线模式使用当前UI、3072纹理及900,000绘制预算模拟上版默认绘制参数；本版使用2048及600,000，双方各三轮。Android真机与9070／4060未连接，本机采样不能证明其实际帧率和GPU占用。

```sh
flutter test test/live2d_scene_controller_test.dart test/room_widget_test.dart test/room_first_and_menu_test.dart
flutter drive --profile -d macos --driver=test_driver/performance_driver.dart --target=integration_test/room_performance_test.dart --dart-define=BENCHMARK_LABEL=valid-images-before --dart-define=BENCHMARK_BASELINE=true --dart-define=BENCHMARK_TEXTURE_SIZE=3072
flutter drive --profile -d macos --driver=test_driver/performance_driver.dart --target=integration_test/room_performance_test.dart --dart-define=BENCHMARK_LABEL=valid-images-after
```

## 有效图片同机复测

Apple M5 / 16GiB / macOS27.0.1、Flutter3.47.5 Profile，窗口1280×820，角色视口760.855×571.04、DPR2；2,000条消息、200条有效内置WebP图片消息（1440×1800，182,610字节）及240段流式回复和滚动。先验证Flutter能解码素材，采样后检查可见图片失败占位为0。基线保持本版UI、使用3072／900,000绘制参数，随后使用本版2048／600,000；各三轮。

| 轮次 | UI P95 前 → 后(ms) | Raster P95 前 → 后(ms) | 超过16.7ms帧 前 → 后 | RSS 前 → 后(MiB) |
| --- | --- | --- | --- | --- |
| 1 | 9.015 → 8.832 | 7.995 → 7.438 | 3 → 0 | 239.9 → 226.2 |
| 2 | 8.634 → 9.041 | 7.750 → 7.273 | 2 → 0 | 202.3 → 242.3 |
| 3 | 9.210 → 8.842 | 8.222 → 7.326 | 0 → 2 | 212.4 → 226.7 |

本版UI / Raster P95均值8.905 / 7.346ms；各轮都在16.7ms预算内，仍可能出现个别超预算帧。这是本机有限采样，不等同于Android或9070／4060的帧率。纹理RGBA8数据72 → 32MiB，整个进程RSS不能按此比例解释。双方各轮隐藏更新均为0，模型实际更新约540次／轮。

[有效图片基线](qa/room-loading-v0.6.16/room-valid-images-before.json)、[本版](qa/room-loading-v0.6.16/room-valid-images-after.json)。

## 发布验证

[发布CI](https://github.com/redchenk/tsukuyomi-space-app/actions/runs/38230225656)全部9个任务通过，完整回归866项通过、19项可选检查跳过；Windows、macOS、Linux、Android和未签名iOS构建通过。三桌面打包后的Agent检查各110项通过，所有安装包检查419个资源和两个编译着色器。Android原生探针验证2048纹理、409个绘制网格、遮罩与混合、音频及骑乘重开；它运行在CI模拟器上，不作为手机帧率证据。

`v0.6.16-beta.1`指向源码提交`4743fa8e23983cbce58afa8154639cf2300d33ad`。应用更新服务已使用旧版0.6.15、Android arm64及预览渠道配置，实际检测本版、从GitHub下载155,256,892字节APK并完成SHA-256校验；此检查在本机Flutter测试中进行，没有执行安装。

全部11个发布附件合计2,207,790,483字节已实际下载，GitHub官方摘要及`SHA256SUMS.txt`全部一致。

[CI记录](qa/room-loading-v0.6.16/ci-validation.json)、[发布附件校验](qa/room-loading-v0.6.16/release-validation.json)、[实际更新下载记录](qa/room-loading-v0.6.16/updater-live-validation.json)。Android真机、9070／4060实际帧率和安装体验仍需对应设备验证；iOS安装需要自行签名。
