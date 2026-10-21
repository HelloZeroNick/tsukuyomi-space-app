# v0.6.25-beta.1 发行验证

[公开 Release](https://github.com/redchenk/tsukuyomi-space-app/releases/tag/v0.6.25-beta.1)，版本 `0.6.25+32`。16 个公开附件已逐个下载，全部与 GitHub 摘要、`SHA256SUMS.txt` 和 `OHOS-SHA256SUMS.txt` 匹配；完整记录见 [release-validation.json](release-validation.json)。

- 标准五平台 tag 为 `82466e82dde88e1c4be8c9712d99892e6499106b`；发行回归 1015 项通过、19 项跳过，五平台发行、包内运行时、Android 原生探针通过。main 基础构建与独立桌面 Agent 检查也通过。
- 鸿蒙使用 `7e7d08721c45ce8be49406c7e191dd54bf58ebf5` 的成功官方构建，993 项通过、41 项跳过。相对 tag 仅补充鸿蒙产品层 `useNormalizedOHMUrl` 与 Linux Agent CI 头文件依赖，业务源码相同；补包保留实际构建提交与 tag 提交，未修改 tag。
- 下载的 Android 两种 APK 证书均匹配开放平台登记的 MD5；真实 Cubism、GPU JNI 与原生依赖校验通过。macOS 为 arm64 / x86_64 通用包，深度签名验证通过；三个桌面平台的 Agent 文件与包内清单逐一匹配。
- iOS 与鸿蒙包为未签名发行包，需要自行签名安装。模拟器回归不代表真机性能或支付宝实际拉起和到账验收。

本次没有部署配套主站移动支付修改、配置移动应用私钥或启用支付渠道，也没有发生真实资金操作。移动支付仍依赖配套主站部署、支付宝产品权限与服务端配置。
