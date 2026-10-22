# v0.6.27-beta.1 下载分发验收

版本 `0.6.27+34`，发行标签指向 `0002da723611b0058d8d3353b765b0ddcbbc6a1c`。App 从 `https://downloads.yachiyo.hk/releases.json` 检查更新，安装包和校验清单仅从同域的版本路径获取。原有下载、取消、SHA-256 校验及安装确认继续保留。0.6.26 及以前的客户端必须先升级一次。

- [标准发布](https://github.com/redchenk/tsukuyomi-space-app/actions/runs/39791897860)完成：静态分析通过，1,025 项完整回归通过、19 项跳过；三种桌面系统各通过 124 项窗口和渲染回归。Android 原生模拟器验证包含 `TSUKUYOMI_UPDATE_OK` 与 `TSUKUYOMI_LIVE2D_OK`。
- [鸿蒙同源码构建](https://github.com/redchenk/tsukuyomi-space-app/actions/runs/39791790371)成功。第二次执行用于恢复被后续 CI 配置提交取消的原构建。
- [鸿蒙补包](https://github.com/redchenk/tsukuyomi-space-app/actions/runs/39797329502)复用已验证的产物。GitHub 曾返回整体成功、子任务仍运行的不同步状态，首次来源校验拒绝发布；状态一致后重试通过，未放宽来源验证。
- [基础包自动分发](https://github.com/redchenk/tsukuyomi-space-app/actions/runs/39797660034)已在北京服务器完成切换；[鸿蒙补包后的自动分发](https://github.com/redchenk/tsukuyomi-space-app/actions/runs/39798886023)使用相同受限接收服务。
- 使用空的临时缓存实际执行 App 检查、下载和再次校验，取得 `tsukuyomi-space-0.6.27-ios-arm64-unsigned.ipa`，大小 128212746 字节，SHA-256 为 `a091cbc857a81305fa4987b543a5a8b6efaf5905517474350e95dbf9f9cbcbc6`。

分发使用独立受限 SSH 账号，不提供交互式 shell 或转发。每次传输先验证全部文件，再原子切换目录；失败保留当前版本，成功后删除旧版本。网站和 App 不需要访问 GitHub API 来检查版本。GitHub 保留历史 Release。

两次自动分发均已成功。GitHub 的 16 个公开附件与北京站的 16 个文件均已实际下载，大小、SHA-256 及两份校验清单完全一致；公开 HTTP Range 下载也通过。详见 [Release 验证](release-validation.json)、[北京站验证](mirror-validation.json)和[自动同步回执](distribution-full-validation.json)。北京目录仅有当前一个版本，占约 2.3 GiB，临时接收目录已移除，旧版安装包返回 404。原有 1,372 个项目和配置文件哈希、两个原有容器的身份、进程与启动时间未变。

国内站与海外站均已部署 `33f54ab` 的下载页面和最新备用信息；线上 390px、1280px 浏览器检查中，六个平台均为 v0.6.27 的北京下载链接，无横向溢出。网站缓存最长约五分钟；已经打开旧页的访问者需要重新检查更新。

这里只记录 CI、公开文件和网络下载证据，未执行真机安装验收。iOS IPA 与 HarmonyOS HAP 仍未签名，需要自行签名。
