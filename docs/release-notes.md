0.6.24+31 / v0.6.24-beta.1：Live2D 原生 GPU 渲染扩展至 Apple、Windows 和 Linux。

- iOS / macOS 使用 Cubism Metal 渲染，通过 IOSurface / CVPixelBuffer 交给 Flutter Texture；透明合成、普通与反向遮罩、眨眼、表情和实时口型沿用现有模型逻辑。
- Windows 使用 Cubism D3D11 与 DXGI 共享纹理；Linux x64 使用与 Flutter 共享的 EGL / OpenGL ES 上下文，修复首帧交付、GTK 上下文恢复、尺寸变化和资源销毁。
- 自动模式优先使用原生 GPU，初始化或绘制失败会回退兼容 Canvas；设置中仍可手动选择。Android 保留已有 SurfaceProducer 原生管线，HarmonyOS 按平台能力继续使用 Native Core + Canvas。
- 保留 3K 图集、实际屏幕密度、输出像素预算与单帧限流；聊天滑动和输入期间继续动画，页面隐藏、后台和手动暂停时停止更新。
- 新增跨平台图像探针和 CI，检查透明边角、发丝、表情口型、横竖尺寸、交互提交及两轮销毁重建，并保存实际桌面合成截图。

macOS 与 iOS 模拟器 Metal、Windows WARP、Linux Mesa 图像探针，以及 iOS arm64 无签名构建和 Android 原生回归均已通过。Windows 仍有每帧 GPU 拷贝，Linux X11 完整合成链路仍有 CPU 拷贝；这些功能验证不代表真机帧率、功耗、温度或 15 分钟持续运行验收。

普通 Android 手机选择 **arm64-v8a**。iOS IPA 和 HarmonyOS HAP 未签名，需自行签名安装；鸿蒙附件由独立发行流程追加。平台接口、复现命令与验收边界见[适配记录](https://github.com/redchenk/tsukuyomi-space-app/blob/main/docs/native-live2d-platforms.md)。
