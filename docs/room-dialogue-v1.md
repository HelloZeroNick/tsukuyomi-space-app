# 八千代对话行为与连续状态

2026-10-21。

普通聊天在 `LlmClient` 组合提示时加入 `RoomDialogue.plan()` 的表达引导；显式覆盖提示与 JSON 工具任务保持原行为。网站与原生 App 使用相同策略数据，不增加模型请求或数据库。

`lib/core/room_dialogue.dart` 从已完成的 `ChatTurn` 重建状态，不维护第二套可漂移的持久对象。生成失败、停止、编辑和重生成继续遵循控制器原有的提交与替换规则。跨设备状态以同步后的账号聊天为来源；未同步时使用本机已有记录。

策略文本、正则和版本来自网站的 `shared/room-dialogue-policy.json`，编译到 `RoomReference.data.dialoguePolicy`。历史原文与模型生成的任意标签不会直接拼入行为指令。日记人设不参与聊天规划。

```sh
node tool/sync_room_reference.mjs ../tsukuyomi-space
node tool/sync_room_dialogue.mjs ../tsukuyomi-space
flutter analyze
flutter test test/room_dialogue_test.dart test/room_context_test.dart test/room_parity_test.dart test/room_controller_test.dart
```

共享 30 组行为场景，其中 15 组有至少五轮上下文；逐项比较 JS 与 Dart 的完整结果。补充验证 URL/代码疑问号、技术失败问题、云端无 opener 标签的开场白，以及参考资料与动态指令的预算隔离。

完整设计、预算、有限语义信号的边界及真实模型盲评方法见网站仓库 `docs/room-dialogue-engine.md`。自动测试与受控模型传输只证明工程行为，不替代实际模型语言质量或真机体验验收。

本次验证：Flutter 全量 979 项通过、40 项按原条件跳过，最终相关复核 83 项通过，静态分析无问题。macOS Debug 构建成功，已确认包内含策略版本和引导文字。没有执行线上发布、真实模型 A/B 或真机安装验收。
