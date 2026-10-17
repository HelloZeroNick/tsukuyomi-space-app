# Room 绘制、流式解码与 Claude PR 验证

0.6.19+25 / v0.6.19-beta.1。目标设备为红米K90／骁龙8至尊版；目前未连接该真机。

## 绘制开销

相邻、无遮罩、同纹理、普通混合、透明度为1且不需要染色的网格合并成一个顶点批次，严格保留原绘制顺序。带遮罩、染色、半透明或目的混合的网格沿用各自绘制路径；纹理自身的alpha保持原样。Android原生检查曾捕捉到半透明／目的混合批次的像素差（最大27），因此收紧合并条件，没有放宽像素检查。批次复用UV、索引和未变化的几何；动态几何／UV、可见性、透明度和绘制顺序变化会更新缓存，未使用的批次在本帧释放。合并前限制16位索引范围，超过范围拆分绘制。纹理仍为2048，帧率及自适应合成预算规则保持原设置。

[Flutter drawVertices](https://api.flutter.dev/flutter/dart-ui/Canvas/drawVertices.html)和[Vertices.raw](https://api.flutter.dev/flutter/dart-ui/Vertices/Vertices.raw.html)规定三角形绘制、纹理坐标及16位索引。本次没有改动原有遮罩、目标混合及着色器路径。

真实Cubism模型、不同表情和口型的三个参考状态：绘制调用为455→226、455→441、455→226，逐通道像素差均为0。收益随材质状态变化，不能将典型状态约50%的调用减少解释为GPU占用或整页帧率改善50%。批次保留的Dart顶点数据分别为441,172、88,538、441,172字节，未计入GPU副本。

9项绘制检查通过，覆盖纹理透明度与重叠、正常／加法／乘法混合、遮罩、染色、变形、非原生可变UV、排序、缓存释放和16位索引边界；原生模型仍使用两张2048纹理（32MiB RGBA8）。[像素与调用记录](qa/render-stream-v0.6.19/live2d-batch-pixels.json)。

## 流式解码

之前文本、工具参数和私有续接内容每接收一个片段，就对累计字符串重新拼接／UTF-8编码检查。改为StringBuffer和新增片段的字节计数，完成时输出普通字符串；保留原上限，并正确处理被JSON片段拆开的UTF-16代理对。私有思考与签名仍只用于协议续接，界面只显示既有状态信息。

同一Flutter tester JIT进程在macOS上预热后交替执行，三轮输出、工具调用和续接内容逐项相同。这里只测解码，排除HTTP、UI与GPU，不是Android帧率数据。参考代码为PR合并后、优化前的`2c48adcb23b74ff374ad01b4b66f239490d7d765`。

| 负载 | 轮次 | 优化前(ms) | 优化后(ms) |
| --- | --- | --- | --- |
| 3,000段中文文本 | 1 | 1182.931 | 413.749 |
| 3,000段中文文本 | 2 | 1569.225 | 443.689 |
| 3,000段中文文本 | 3 | 1255.536 | 330.897 |
| 1,126段工具参数 | 1 | 257.556 | 129.245 |
| 1,126段工具参数 | 2 | 358.792 | 117.173 |
| 1,126段工具参数 | 3 | 666.951 | 241.109 |

[对比数据](qa/render-stream-v0.6.19/model-stream-buffer-comparison.json)、[采样代码](qa/render-stream-v0.6.19/decoder_benchmark_test.dart.txt)。采样代码旁的参考模块通过`git show`取得上述提交的`lib/core/model_protocol.dart`，仅将相对models导入改为package导入后执行；没有模型服务请求或工具执行。

## PR与验收范围

[PR #7](https://github.com/HelloZeroNick/tsukuyomi-space-app/pull/7)与当前main无冲突合并，保留作者提交。复核[Claude迁移规则](https://platform.claude.com/docs/en/models/opus-5-5/migration-guide)、[工作区规则](https://platform.claude.com/docs/en/manage-claude/workspaces)及[服务端回退协议](https://platform.claude.com/docs/en/build-with-claude/refusals-and-fallback)，覆盖采样参数、工作区头、模型目录、回退、拒绝／截断和最终工具轮次。首次完整回归887项通过、34项可选检查跳过，一项原有大SVG压力用例超过30秒；后续针对性64项全部通过，包括该SVG用例、四类协议、Claude、字符边界、安全上限和输入法。没有使用真实Anthropic密钥进行付费联调。

2,000条聊天／图片／流式回复／Live2D的本机原生Profile采样三次因窗口前台／焦点条件不满足被丢弃；嵌套签名修复后仍不能满足焦点检查。保留模型活跃、窗口焦点及隐藏更新检查，不记录或宣传无效UI／Raster数据。尚不能保证K90的实际流畅度，需要用发布包进行真机复测。

[Android专项CI](https://github.com/HelloZeroNick/tsukuyomi-space-app/actions/runs/38277802756)已通过：修正版的合成用例和真实模型像素差均为0，三个模型状态的调用从455降到226、226、329；系统输入法三次开合保持编辑器和舞台尺寸稳定，2048细节、目标混合、游戏音频与骑乘全部通过。该环境使用SwiftShader模拟器，帧耗时仅作诊断，不能用作K90帧率验收。[Android日志摘要](qa/render-stream-v0.6.19/android-focused-validation.json)。

Android发布探针新增合并绘制的像素及调用检查，并保留系统输入法三次开合、2048细节、游戏音频与骑乘检查；失败会阻止发布。最终[发布CI](https://github.com/HelloZeroNick/tsukuyomi-space-app/actions/runs/38278977949)的9个任务全部成功：完整回归907项通过、19项跳过，五平台构建完成；macOS、Windows、Linux各117项窗口／更新检查及113项打包Agent检查通过。iOS附件未签名，需要自行签名。PR #7已远程合并，开放PR为0，仓库分支仅main。

[v0.6.19-beta.1](https://github.com/HelloZeroNick/tsukuyomi-space-app/releases/tag/v0.6.19-beta.1)绑定源码`d8be2c83ef0f389ad3450a1e35e9e1775f5788c1`，发布说明仅包含本次更新。11个附件共2,208,576,547字节已实际下载，全部与GitHub官方摘要及SHA256SUMS一致。生产AppUpdateService以旧版0.6.18和Android arm64配置成功检测、下载并验证0.6.19的155,256,892字节APK；未在物理手机安装。[CI记录](qa/render-stream-v0.6.19/ci-validation.json)、[附件记录](qa/render-stream-v0.6.19/release-validation.json)、[更新记录](qa/render-stream-v0.6.19/updater-validation.json)、[本地记录](qa/render-stream-v0.6.19/local-validation.json)。
