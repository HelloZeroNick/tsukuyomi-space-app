# HarmonyOS / OpenHarmony 适配

鸿蒙适配单独维护在官方 [`ohos` 分支](https://github.com/redchenk/tsukuyomi-space-app/tree/ohos)，产品功能跟随 `main`。感谢 [HelloZeroNick](https://github.com/HelloZeroNick/tsukuyomi-space-app/tree/ohos) 在 [issue #8](https://github.com/redchenk/tsukuyomi-space-app/issues/8) 贡献的平台工程和插件适配；官方分支保留其提交历史。

原始移植提交现已合入默认分支 `main`，保留 HelloZeroNick 的作者身份，使 GitHub 能将其计入仓库贡献者。README 的贡献者区同时展示作者头像、贡献内容和原 fork 链接。`ohos` 继续用于专用构建；主线默认依赖和启动逻辑保持标准 Flutter 配置。

`main` 继续使用标准 Flutter，鸿蒙依赖只在 `ohos` 构建准备时启用。`main` 每次更新及每六小时执行一次合并检查，成功合并后运行鸿蒙构建；冲突会使 [同步工作流](https://github.com/redchenk/tsukuyomi-space-app/actions/workflows/sync-ohos.yml) 失败，保留远端分支，须人工处理。不会强推或以主线覆盖鸿蒙文件。

## 下载与安装

官方 [GitHub Releases](https://github.com/redchenk/tsukuyomi-space-app/releases) 提供 `tsukuyomi-space-<版本>-<构建号>-ohos-arm64-unsigned.hap`。当前 [0.6.24+31 鸿蒙包](https://github.com/redchenk/tsukuyomi-space-app/releases/download/v0.6.24-beta.1/tsukuyomi-space-0.6.24-31-ohos-arm64-unsigned.hap) 适用于 HarmonyOS 6.0.2 / API 22 及以上 ARM64 设备，下载直接使用 GitHub。

**当前为未签名 HAP，必须自行签名后安装，不能像 APK 一样点击即装。** Release 同时附带 `OHOS-INSTALL.md`（签名安装步骤）、`OHOS-SHA256SUMS.txt`、`OHOS-BUILD-INFO.json` 和 `OHOS-THIRD-PARTY-NOTICES.md`。尚无开发证书的普通用户需要等待签名发行版。应用内暂不支持 HAP 下载后安装，更新需手动获取并使用同一身份签名；不要为更新而卸载已有应用。

后续常规 Release 发布成功后，[鸿蒙发行工作流](https://github.com/redchenk/tsukuyomi-space-app/actions/workflows/ohos-release.yml) 从对应 tag 的固定源码构建，再补上这五个附件；也可手动指定已发布 tag 重试。版本、构建号、HAP 内容与 SHA-256 均需一致，已有同名不同内容的附件会使流程停止，不覆盖其他平台下载。0.6.21 是历史版本补包，实际 HAP 源码与原发行 tag 分别记录在构建来源文件中，原 tag 保持不变。

若需要复用已成功的鸿蒙构建，手动发布时还可填写 `source_run_id`。流程会检查官方 `ohos` 分支、两项成功检查、源码与产物归属、有效期及版本，再下载对应 Actions 产物，不从本机重新上传大文件。

构建方法、固定工具链和验收限制见 [`ohos` 分支的构建说明](https://github.com/redchenk/tsukuyomi-space-app/blob/ohos/tool/ohos/README.md)。当前不承诺商店发布、后台升级安装或所有 HarmonyOS/OpenHarmony 设备兼容；构建成功不代表已完成鸿蒙真机验收。
