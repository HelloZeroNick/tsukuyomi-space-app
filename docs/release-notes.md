0.6.22+29 / v0.6.22-beta.1：Android Live2D 原生 GPU 渲染与清晰度修正。

- Android 默认使用 Cubism 官方 OpenGL ES 渲染器与 Flutter 外部纹理。模型求值、物理、遮罩和绘制在原生工作线程执行，避免逐帧将全部网格交给 Flutter Canvas；表情、动作和音频口型保持原有控制顺序。
- 自动档图集提升至 3072，细节优先为 4096，省电为 2048。GPU 输出优先使用实际屏幕 DPR，自动档上限 400 万像素，细节优先 800 万像素；高刷新率屏幕不再触发隐式画质降级。
- 默认动画目标调整为 60 fps（省电 30）；持续负载时降低帧率，保持所选画质。继续在滚动、输入、隐藏和后台期间暂停更新，最多保留一帧原生任务在途。
- 新增「角色渲染方式」开关，可切回兼容渲染；加载或绘制失败时自动回退。角色状态显示实际渲染路径、输出尺寸与有效 DPR。
- 其他平台继续使用 Canvas，并应用纹理清晰度、合成像素预算和帧率判断修正。iOS/macOS Metal、Windows/Linux 和鸿蒙 GPU 移植尚未包含。

普通 Android 手机选择 **arm64-v8a**。安装后在房间的角色状态中确认显示 `Cubism GPU · OpenGL ES`；可切换兼容渲染进行同设备比较。Android 模拟器验证不代表红米 K90 的帧率、温度或续航，15 分钟真机 A/B 仍待验收。iOS 包需自签；鸿蒙补包由独立流程追加，未签名 HAP 需自行签名。

实现、分辨率策略与验证边界见[原生 GPU 说明](https://github.com/redchenk/tsukuyomi-space-app/blob/main/docs/native-live2d-gpu.md)和[Canvas 清晰度记录](https://github.com/redchenk/tsukuyomi-space-app/blob/main/docs/native-live2d-mobile-parity.md)。
