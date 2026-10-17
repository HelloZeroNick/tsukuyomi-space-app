# 官方鸿蒙分支验收（2026-10-17）

接收 [issue #8](https://github.com/redchenk/tsukuyomi-space-app/issues/8) 的移植，源码 `5dd51d6d07c64d4c0cbefaf82bc9968d8b0222ec`，包含主线 `ff2dae92201bb43c83712fd74d8721b78a982ff7`。文档后的提交只记录验收，不修改已验证的程序代码。

- [鸿蒙流水线 39042094556](https://github.com/redchenk/tsukuyomi-space-app/actions/runs/39042094556)：完整 Flutter 回归 930 通过、40 条件跳过；7 项准备、签名提示识别与分支同步测试通过；标准 Flutter 和 CPF-Flutter 静态检查通过；Release HAP 构建和包检查通过。
- [主线流水线 39040171964](https://github.com/redchenk/tsukuyomi-space-app/actions/runs/39040171964)：Web、Windows、macOS、Linux、Android 构建通过。修复了更新安装器无条件导入 `dart:ffi` 导致 Web 无法编译的问题。
- [同步流水线 39040171963](https://github.com/redchenk/tsukuyomi-space-app/actions/runs/39040171963)：自动合入主线修复，产生 `8e8a28d`，随后显式触发鸿蒙构建。另有测试确认合并冲突不修改远端、脏工作区不执行、重复同步不产生提交。

已实际下载 [HAP 构建产物](https://github.com/redchenk/tsukuyomi-space-app/actions/runs/39042094556/artifacts/12104807242)，核对 GitHub artifact 摘要、SHA256SUMS 和 build-info。HAP 为 Release 模式，版本 `0.6.21+28`，包名 `space.tsukuyomi.tsukuyomi_space_app`，148,781,359 字节。

```text
9f696972f993ec2c16d94d4e42c2c9bb1ae3fd1e62501c304360497c9ada8d6c  tsukuyomi-space-0.6.21-28-ohos-arm64-unsigned.hap
```

包内 `libapp.so`、`libflutter.so` 和 `libtsukuyomi_live2d.so` 均为 ARM64 ELF。Live2D 库包含 10 个项目 ABI 导出和 55 个 Cubism 导出，动态依赖为 HarmonyOS 的 `libc.so`，无 GLIBC 依赖。模型、纹理、Flutter 许可文件完整。机器可读证据见 [validation.json](validation.json)。

首次 HAP 尝试因构建脚本未识别中文的缺少签名提示而失败，未接受或发布该次产物。补齐识别后，仍要求新生成的完整 unsigned HAP 通过检查才放行；没有使用无条件忽略构建错误。定位插件采用实际包名作为直接依赖，确保选择正确实现。

**尚未验收**：无 HarmonyOS 真机或签名材料，未进行安装、输入法、登录、音频、定位、文件选择、游戏与 Live2D 性能验收。此 HAP 需要自行签名，并未作为可直接安装的正式 Release 发布。QQ 回调、桌面 Agent、HAP 应用内安装以及存储适配的边界见 [构建说明](../../../tool/ohos/README.md)。
