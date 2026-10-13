# Room 真机性能复测

使用 `integration_test/room_performance_test.dart` 的 profile 构建。测试使用内存会话和内置图片，不请求真实模型接口。负载固定为 2,000 条历史对话、200 条有效 WebP 图片消息、混合 Markdown 和较长回复、240 个流式片段，以及原生 Live2D；每次自动重复三轮。

滚动使用十次跨帧持续拖动，每次维持十八帧，帧间额外留出至少 16ms 真实时间；实际拖动时长还包括等待原生帧的时间。开始采样前必须确认原生窗口处于前台，并在两秒空闲阶段记录至少十次模型更新；采样过程中失去前台、桌面窗口失去焦点、帧样本少于六十或交互没有让出模型计算都会使测试失败。单独的隐藏场景检查必须记录零次模型更新。

## Android

在独立测试设备或测试用户中连接 USB 调试，然后用 `flutter devices` 查出设备 ID。profile 包使用开发签名；已有正式包出现签名冲突时，应换测试用户或设备，保留原有安装和数据。

```sh
flutter drive --profile -d DEVICE_ID \
  --driver=test_driver/performance_driver.dart \
  --target=integration_test/room_performance_test.dart \
  --dart-define=BENCHMARK_CHAT_SCROLL=true \
  --dart-define=BENCHMARK_LABEL=k90-room-after
```

结果写入 `artifacts/performance/room-k90-room-after.json`。记录设备型号、系统版本、应用源码版本和屏幕刷新率，用相同设置复测。测试必须保持屏幕解锁、应用在前台，期间停止其他性能测试。

可增加 `--device-user=TEST_USER_ID` 指定已有的 Android 测试用户。不要删除个人用户中已安装的应用来绕过签名错误。

键盘和中文组合输入的布局复测使用同一入口，追加以下参数。它模拟键盘高度和输入客户端，不能替代实际 Android 输入法的手工验收。

```sh
--dart-define=BENCHMARK_MOBILE_LAYOUT=true \
--dart-define=BENCHMARK_IME=true \
--dart-define=BENCHMARK_ASSERT_IME=true
```

## 桌面

将上述设备改为 `-d macos`、Windows 或 Linux 的设备 ID。macOS 自动前置失败时，可以先运行 `flutter run --profile --start-paused`，在原生 `Window → Bring All to Front` 菜单前置窗口、确认其实际获得焦点后，通过 `flutter drive --use-existing-app=VM_SERVICE_URL` 连接。只对窗口执行 `Raise` 可能仍保持应用未激活。无障碍检查应在恢复测试前完成，以免采样过程中改变系统语义开关。

前后比较必须使用同一测试入口、设备、负载、窗口大小、2048 纹理和 `auto` 绘制质量。旧架构复制同一测试入口后，仅增加 `--dart-define=BENCHMARK_INTERACTION_EXPECTED=false`；不要使用改变绘制质量的 `BENCHMARK_BASELINE` 开关。

报告分别记录 UI/Raster P95、超过 16.7ms 的帧数、内存、模型更新次数和计算时间、交互让出时长、图片解码情况及隐藏更新。`model_update_cpu_percent` 是模型计算时间占采样时间的比例，不能解读为显卡占用。`input_ready_ms` 是该固定内存负载从挂载到首次输入可用的时间，不包含正式应用账号校验和网络请求。

本地 Apple 芯片数据只能说明该 macOS 场景；红米 K90、RX 9070 和 RTX 4060 的验收须分别在对应设备上执行。

## 本次已完成的 macOS 对比

基线 `1757f5e` 与最终候选使用字节相同的测试入口，在 Apple M5、16GB、macOS 27.0.1、1280×820 / DPR 2 的实际原生窗口中分别完成三轮。两次 driver 均退出为 0；前台、空闲动画、流式状态、有效帧数量和隐藏模型更新断言全部通过。两者都使用 2048 纹理、`auto` 质量和 600,000 绘制像素预算，没有靠降低画质建立对比。

下表是三轮中位数；完整逐轮值在 [native-before.json](native-before.json)、[native-after.json](native-after.json) 和 [native-comparison.json](native-comparison.json)。

| 指标 | 基线 | 候选 |
| --- | ---: | ---: |
| UI P95 | 3.498ms | 2.376ms |
| Raster P95 | 6.996ms | 8.236ms |
| 模型更新次数 | 775 | 228 |
| 模型计算时间占采样时间 | 3.309% | 1.003% |
| Live2D 绘制提交次数 | 205,802 | 64,602 |
| 采样结束 RSS | 258.8MiB | 266.8MiB |
| 导航检查后 RSS | 251.7MiB | 267.8MiB |

UI P95 下降约 32.1%，持续聊天交互期间的模型更新次数减少约 70.6%。候选每轮十次交互累计暂停约 8.99 秒，保留缓存角色画面；空闲阶段两秒内仍更新 113–117 次，没有把模型永久关闭。六轮都未记录超过 16.7ms 的 UI 或 Raster 帧，隐藏场景模型更新均为 0。

Raster P95 有上升，RSS 也没有下降，因此本次数据不支持“Raster 更快”或“内存更少”的结论。三轮重复导航也不能替代长时间真机内存验证。此前失败或负载不完整的尝试单独保留在 [native-benchmark-attempts.json](native-benchmark-attempts.json)，没有混入本次有效对比。
