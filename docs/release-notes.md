0.6.19+25 / v0.6.19-beta.1：减少 Room 绘制和流式解码开销，加入 Claude 协议支持。

- 合并相邻且材质一致的 Live2D 网格，减少绘制调用；保留遮罩、透明度、染色、绘制顺序及2048纹理，鼠标追踪保持关闭。
- 流式文本、工具参数和私有续接内容改为增量累计与大小检查，避免每个片段重复扫描整段内容；保留中文与表情字符边界、原有安全上限及取消行为。
- 合入 Claude API 支持 PR #7，统一聊天、Agent、向导和模型目录的工作区、参数、回退及拒绝处理。
- 增加像素一致性、网格索引边界和 Android 原生绘制检查。K90真机的帧率仍需复测；详细数据见[验证记录](https://github.com/redchenk/tsukuyomi-space-app/blob/main/docs/native-render-stream-v0.6.19.md)。

应用更新开启预览渠道后下载，普通 Android 手机选择 arm64-v8a。iOS包仍需自签。
