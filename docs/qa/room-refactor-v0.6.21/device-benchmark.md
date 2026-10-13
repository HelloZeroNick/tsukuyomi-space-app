# Room 真机性能复测

使用 `integration_test/room_performance_test.dart` 的 profile 构建。测试使用内存会话和内置图片，不请求真实模型接口。负载固定为 2,000 条历史对话、200 条有效 WebP 图片消息、混合 Markdown 和较长回复、240 个流式片段，以及原生 Live2D；每次自动重复三轮。

滚动使用十次跨帧持续拖动，每次维持十八帧，帧间留出真实的 16ms 时间。开始采样前必须确认原生窗口处于前台，并在两秒空闲阶段记录至少十次模型更新；采样过程中失去前台、桌面窗口失去焦点、帧样本少于六十或交互没有让出模型计算都会使测试失败。单独的隐藏场景检查必须记录零次模型更新。

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

将上述设备改为 `-d macos`、Windows 或 Linux 的设备 ID。macOS 自动前置失败时，可以先运行 `flutter run --profile --start-paused`，在窗口实际显示并获得焦点后，通过 `flutter drive --use-existing-app=VM_SERVICE_URL` 连接。无障碍检查应在恢复测试前完成，以免采样过程中改变系统语义开关。

前后比较必须使用同一测试入口、设备、负载、窗口大小、2048 纹理和 `auto` 绘制质量。旧架构复制同一测试入口后，仅增加 `--dart-define=BENCHMARK_INTERACTION_EXPECTED=false`；不要使用改变绘制质量的 `BENCHMARK_BASELINE` 开关。

报告分别记录 UI/Raster P95、超过 16.7ms 的帧数、内存、模型更新次数和计算时间、交互让出时长、图片解码情况及隐藏更新。`model_update_cpu_percent` 是模型计算时间占采样时间的比例，不能解读为显卡占用。`input_ready_ms` 是该固定内存负载从挂载到首次输入可用的时间，不包含正式应用账号校验和网络请求。

本地 Apple 芯片数据只能说明该 macOS 场景；红米 K90、RX 9070 和 RTX 4060 的验收须分别在对应设备上执行。
