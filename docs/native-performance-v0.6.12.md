# 原生性能对比 · 0.6.12+18

2026-10-11；Apple M5、16GiB、macOS 27.0.1，Flutter 3.47.5 Profile；原生 1280×820 窗口、实际内容区 1280×797、DPR 2。优化前为 `8de7456`（已含本轮窗口/游戏修复），优化后为本轮性能修改。两个阶段各三轮，测量期间不并行运行编译、全量回归或其他性能场景。

## 场景和边界

Room：2,000 条中文问答、其中 200 条图片消息、240 个流式片段，并行拖动聊天和真实 409 网格 Cubism。图片是同一张 1×1 PNG 测试数据，覆盖图片消息路径，不能替代大量真实照片的解码/显存验收。加载完成的实际模型必须持续更新，隐藏页面必须零更新；不满足则拒绝该次结果。

Hub：实际大厅、三张内容卡片、96×54 像素作品、三条留言；12 次 500px/2200px·s⁻¹ 的交替指针惯性滑动，同时每 32ms 发送工作区状态变化。

这里的 Raster 时长是 Flutter FrameTiming，不是显卡利用率；`Picture.toImageSync` 的部分 GPU 工作可能异步执行。模型 CPU 指标仅覆盖模型更新及网格读取，不能当作进程总 CPU。Android 模拟器和 9070/4060 真机另列验收，未以 Mac 数据替代。

## Room

| 轮次 | UI P95 前 → 后(ms) | Raster P95 前 → 后(ms) | 超过16.7ms帧 前 → 后 | RSS 前 → 后(MiB) |
| --- | --- | --- | --- | --- |
| 1 | 10.121 → 9.274 | 9.941 → 6.373 | 1 → 0 | 373.8 → 379.9 |
| 2 | 10.405 → 9.053 | 9.790 → 6.860 | 0 → 0 | 389.6 → 381.5 |
| 3 | 8.763 → 9.220 | 11.964 → 6.812 | 2 → 0 | 391.3 → 403.3 |

三轮 Raster P95 均值 10.565 → 6.682ms，下降 36.8%。这是最终代码（包含染色着色器修复）在本机受控场景的结果。

优化后三轮模型均更新 542 次；旧第三轮曾自适应降频，故 CPU 百分比不能直接平均比较。模型单次更新约 0.576 → 0.526ms，变化较小。按实际解码尺寸计算的 RGBA8 数据量为32MiB，原两张4096²合计128MiB；这不是进程总内存或独立显存仪表的读数。4个普通混合段的离屏图像每帧合计3,595,796像素，单段预算900,000；此数量不包含直接绘制的特殊混合和遮罩过绘。

可输入时间：79 / 56 / 55ms（内存配置fixture至首次输入框绘制，不覆盖真实磁盘、系统密钥环、联网登录或模型服务延迟）。隐藏期间三轮角色更新均为0。导航后RSS：382.0 / 397.9 / 402.2MiB；这是有限三轮的观测，不能据此宣称长期无泄漏或总内存下降。

## Hub

| 轮次 | UI P95 前 → 后(ms) | Raster P95 前 → 后(ms) | 超过16.7ms帧 前 → 后 | RSS 前 → 后(MiB) |
| --- | --- | --- | --- | --- |
| 1 | 2.215 → 2.198 | 4.647 → 4.397 | 0 → 0 | 199.3 → 200.8 |
| 2 | 2.213 → 2.061 | 4.814 → 4.464 | 0 → 0 | 221.3 → 200.0 |
| 3 | 2.195 → 2.029 | 4.784 → 4.380 | 0 → 0 | 220.2 → 202.0 |

三轮 Raster P95 均值 4.748 → 4.414ms，下降 7.0%。这是本机受控场景的结果。

三轮完整惯性滑动没有超过16.7ms的帧；每轮约472次工作区通知没有更换像素预览。冷启动的样本只有16–19帧，第一轮优化后UI P95为20.246ms，高于原9.163ms，不能据此宣称冷启动改善。暖态滑动改善有限；原本已在预算内。

## 长文章组件补测

最终代码的 ArticleBody Markdown 组件在原生前台窗口中补测三轮：窗口1280×820，实际内容1280×788，DPR 2。60个标题、600段中文/英文正文、20个代码块、20张表格、20张1×1测试图片；每16ms改变滚动位置，共180步。

| 轮次 | UI P95(ms) | Raster P95(ms) | 超过16.7ms帧 |
| --- | --- | --- | --- |
| 1 | 0.252 | 0.674 | 0 |
| 2 | 0.250 | 0.584 | 0 |
| 3 | 0.235 | 0.572 | 0 |

这是组件暖态滚动检查，没有优化前对比，不包含整站导航、首次排版、联网加载或真实大图片解码；程序改变位置也不能替代 Hub 的指针惯性测试。窗口必须处于前台，每轮必须采集至少100帧，否则测试拒绝结果。[原始数据](qa/native-pc-game-v0.6.12/performance/article-after.json)。

## 复测

```sh
flutter drive --profile -d macos --driver=test_driver/performance_driver.dart --target=integration_test/room_performance_test.dart --dart-define=BENCHMARK_LABEL=local
flutter drive --profile -d macos --driver=test_driver/hub_performance_driver.dart --target=integration_test/hub_scroll_performance_test.dart --dart-define=BENCHMARK_LABEL=local --dart-define=BENCHMARK_BUSY=true
flutter drive --profile -d macos --driver=test_driver/article_performance_driver.dart --target=integration_test/article_scroll_performance_test.dart --dart-define=BENCHMARK_LABEL=local
flutter run --profile -d macos --target=tool/verify_live2d_rendering.dart
```

原始数据见 [Room优化前](qa/native-pc-game-v0.6.12/performance/room-before.json)、[优化后](qa/native-pc-game-v0.6.12/performance/room-after.json)、[Hub优化前](qa/native-pc-game-v0.6.12/performance/hub-before.json)、[优化后](qa/native-pc-game-v0.6.12/performance/hub-after.json)。

## 对应设备验收

用户报告的 Android 手机以及9070、4060显卡未连接到本工作区。需在相同设备、窗口、驱动和场景各跑三次，记录整机/进程GPU、真实图片负载、发热及长时间内存，再确认设备问题已消除。发布CI提供原生Android渲染/音频/更新探针和五平台构建，不代替这些物理设备结论。

本次Android CI采用软件渲染：120次模型更新仅采集到5个实际绘制帧，Raster P95为606.205ms，未达到30fps预算；此探针仅确认功能与像素结果。该模拟器尺寸没有触发真实模型的大视口降采样，合成用例另行覆盖了有界绘制路径；不能以它证明高DPR手机的实际性能。
