# v0.6.26-beta.1 发布验收

本版完成首次配置向导、常驻帮助与功能发现入口，以及连接测试、角色加载和操作状态反馈。保留已有 Room 性能和对话行为实现。

- Release：[v0.6.26-beta.1](https://github.com/redchenk/tsukuyomi-space-app/releases/tag/v0.6.26-beta.1)
- 源码及标签：`4d7a03beec5aebf56afeecc06859de75896ddaf3`，版本 `0.6.26+33`。
- [标准平台流水线](https://github.com/redchenk/tsukuyomi-space-app/actions/runs/39769649096)通过。完整回归 1,025 项通过、19 项跳过，静态分析通过；每个桌面平台另通过 124 项窗口/渲染回归及 113 项随包 Agent 测试。Android 原生模拟器日志包含 `TSUKUYOMI_LIVE2D_OK meshes=409 textures=2`。
- Linux 首次构建在 Ubuntu Azure 镜像站下载依赖时持续缓慢；保留其他平台产物，仅重试 Linux 及后续发布任务，同一源码第二次执行通过。
- 鸿蒙复用[相同源码的成功构建](https://github.com/redchenk/tsukuyomi-space-app/actions/runs/39769671787)，经[补充发布流程](https://github.com/redchenk/tsukuyomi-space-app/actions/runs/39775404042)校验来源后发布，没有重复构建。
- 全部 16 个公开附件均已下载，文件大小、GitHub SHA-256 和两份校验清单一致；APK、IPA、ZIP、HAP 通过归档完整性检查，桌面归档含运行时清单和许可证。HAP 为 `0.6.26+33`、非 debug，来源与发行标签一致。
- 安装说明包含首次配置步骤及各平台签名/运行库要求。逐附件摘要见 [release-validation.json](release-validation.json)。

网站对应优化已部署到 [国内站](https://yachiyo.hk)和[海外站](https://tsukuyomi-space.com)：前端提交 `16688f0`，直接访问舞台路由修复 `3f3a405`。461 项前端测试、14 项浏览器场景通过；每站 176 个公开构建资源的 SHA-256 匹配，并在 390px 视口验证了首次配置和功能发现入口。

以上是 CI、安装包及线上浏览器证据，不代表外部付费模型质量或真实手机性能验收。iOS IPA 和 HarmonyOS HAP 仍未签名，需要自行签名；macOS、Windows 的分发签名限制以 Release 安装说明为准。
