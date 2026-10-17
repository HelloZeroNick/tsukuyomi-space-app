# 官方鸿蒙分支构建

本目录及 `ohos/` 接收自 [HelloZeroNick 的移植](https://github.com/HelloZeroNick/tsukuyomi-space-app/tree/ohos)，贡献提交保留在 Git 历史。官方业务代码及更新链接沿用 `redchenk/tsukuyomi-space-app`，不会重写历史发行证明。

## 工具链

- CPF-Flutter `oh-3.44.9-dev`，固定提交 `3ffe70c6280cc6ddf613bffa59dd70611f238f7e`，Dart 3.12.2。
- HarmonyOS 工具链安装包 `26.0.0.821`（实测内置编译 SDK `26.0.0.105` / API 26）；当前工程最低版本 `6.0.2(22)`，只构建 ARM64。构建来源文件的 `sdk` 字段记录安装包版本，HAP 的 `module.json` 记录实际编译 SDK。
- JDK 17、SDK 自带的 Node、ohpm、Hvigor；真机调试须有 DevEco Studio/hdc 和开发证书。
- `dependency_overrides.json` 把 41 个 Git 插件及子包固定到贡献者 lockfile 对应的提交；不跟随可变的插件分支。

建议使用独立 checkout，不与标准 Flutter 共享 `.dart_tool`、插件生成文件和构建目录：

```sh
git clone --branch ohos https://github.com/redchenk/tsukuyomi-space-app.git tsukuyomi-space-ohos
cd tsukuyomi-space-ohos
# 按 CPF-Flutter 文档安装上述 SDK，确保 flutter 指向固定版本。
python3 tool/release/prepare_assets.py
python3 tool/ohos/prepare.py
GIT_LFS_SKIP_SMUDGE=1 flutter pub get
flutter analyze --no-pub
python3 tool/ohos/build.py
```

`prepare.py` 仅为此构建启用鸿蒙插件和 Dart 3.12.2 下限，并从主线 `pubspec.yaml` 写入 HAP 版本。运行后不要把临时 manifest、lockfile 和 storage 兼容修改提交回来；丢弃此独立 checkout 即可恢复。标准 Flutter 的回归在准备前执行。

Live2D 从经 SHA-256 校验的官方 Cubism SDK 和模型编译，不使用贡献者预编译 `.so`。缺少 Core 时构建失败。HAP 包检查要求模型、纹理、AOT、Flutter、Live2D 库和依赖许可完整。`dist/ohos/` 输出未签名 HAP、SHA256SUMS、构建来源和第三方说明。

## 分支同步

主线的 `sync-ohos.yml` 在 `main` 更新及每六小时自动合并至 `ohos`，禁止强推；成功后显式触发 `ohos.yml`，避免 GitHub Actions bot 推送不触发后续工作流的问题。合并冲突时终止且不修改远端，维护者解决后重新运行构建。版本号跟随主线，鸿蒙插件升级单独审核。

## 验收边界

2026-10-17 官方首次验证已完成：标准 Flutter 930 项通过、40 项按条件跳过，7 项鸿蒙构建准备/同步测试通过；鸿蒙 SDK 下静态检查及 Release HAP 构建通过。[下载本次未签名 HAP 构建产物](https://github.com/redchenk/tsukuyomi-space-app/actions/runs/39042094556/artifacts/12104807242)（可能需要登录 GitHub，CI 产物保留 14 天）。包内 Live2D 库经检查为 ARM64，包含 55 个 Cubism 导出符号，模型与纹理完整。校验记录见 [docs/qa/ohos](../../docs/qa/ohos/README.md)。

- 当前官方产物为未签名 HAP，需要自行签名后安装；不会把它作为可直接安装的正式 Release 上传。应用内升级沿用官方仓库，但尚无 HAP 安装协议；鸿蒙用户需从构建页手动获取版本。
- 不含桌面 OpenCode/Codex 运行时；QQ 快捷授权暂未接入鸿蒙回调，使用密码或邮箱验证码登录。
- 存储适配沿用贡献者的 `flutter_secure_storage_ohos 1.0.0`，其 ArkTS 实现使用应用沙箱内的加密 preferences，并非 HUKS 硬件密钥。不能把此版本描述为硬件密钥保护；后续切换 HUKS 需设计既有数据迁移并做真机验证。
- 贡献者报告的真机运行与截图属于贡献者证据。官方 CI 的包检查不能替代 HarmonyOS 真机上的输入法、音频、登录、后台恢复、文件选择、游戏与 Live2D 性能验收。
