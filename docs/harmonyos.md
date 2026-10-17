# HarmonyOS / OpenHarmony 适配

鸿蒙适配单独维护在官方 [`ohos` 分支](https://github.com/redchenk/tsukuyomi-space-app/tree/ohos)，产品功能跟随 `main`。感谢 [HelloZeroNick](https://github.com/HelloZeroNick/tsukuyomi-space-app/tree/ohos) 在 [issue #8](https://github.com/redchenk/tsukuyomi-space-app/issues/8) 贡献的平台工程和插件适配；官方分支保留其提交历史。

`main` 继续使用标准 Flutter，鸿蒙依赖只在 `ohos` 构建准备时启用。`main` 每次更新及每六小时执行一次合并检查，成功合并后运行鸿蒙构建；冲突会使 [同步工作流](https://github.com/redchenk/tsukuyomi-space-app/actions/workflows/sync-ohos.yml) 失败，保留远端分支，须人工处理。不会强推或以主线覆盖鸿蒙文件。

构建方法、固定工具链和验收限制见 [`ohos` 分支的构建说明](https://github.com/redchenk/tsukuyomi-space-app/blob/ohos/tool/ohos/README.md)。尚未提供官方签名 HAP；未签名构建产物需要使用自己的开发证书签名后安装。当前不承诺商店发布、后台升级安装或所有 HarmonyOS/OpenHarmony 设备兼容。
