# LX 音源兼容验证

## 固定样本与结果

本次使用 [pdone/lx-music-source](https://github.com/pdone/lx-music-source/tree/489a2e36ecb8b7c4a58ae45d8a1918c0c0591da1) 的固定提交 `489a2e36ecb8b7c4a58ae45d8a1918c0c0591da1`，参考 [LX Music Desktop](https://github.com/lyswhut/lx-music-desktop/tree/ad95d5091c9ed689fa72b5e5c849df65f5a679ce) 的自定义音源协议。

逐文件 SHA-256、能力声明及原始审计结果见同目录 `lx-sources-audit.json`。第三方脚本不进入应用、代码仓库或自动化测试夹具。

| 脚本             | 导入 | 断网初始化             | 本次范围内声明的平台         | 解析检查                                 |
| ---------------- | ---- | ---------------------- | ---------------------------- | ---------------------------------------- |
| SixYin 六音      | 成功 | 超时，初始化请求被阻止 | 初始化未完成，无法确认       | 未执行                                   |
| Huibq            | 成功 | 完成                   | 网易云、QQ、酷狗             | 请求进入宿主，断网拒绝                   |
| Flower 野花      | 成功 | 完成                   | 网易云、QQ、酷狗，仅普通音质 | 请求进入宿主，断网拒绝                   |
| LX 独家音源      | 成功 | 完成                   | 网易云、QQ、酷狗             | 请求进入宿主，断网拒绝                   |
| ChangQing 长青   | 成功 | 完成                   | 网易云、QQ、酷狗             | 返回 URL，未验证可播放性                 |
| HuanYin 幻音     | 成功 | 完成                   | 网易云、QQ                   | 返回 URL，未验证可播放性                 |
| ikun             | 成功 | 完成                   | 网易云                       | 请求进入宿主，断网拒绝                   |
| Grass 野草       | 成功 | 完成                   | 无，仅声明酷我               | 未执行                                   |
| JuheApi 聚合 API | 成功 | 超时，初始化请求被阻止 | 初始化未完成，无法确认       | 未执行                                   |
| QDY 全豆要       | 成功 | 完成                   | 网易云、QQ、酷狗             | 多路请求被拒绝后返回 URL，未验证可播放性 |

这些结果证明的是脚本解析和离线运行情况，不是第三方服务在线可用性。SixYin、JuheApi 的超时不能据此判定为协议不兼容；返回 URL 也不能视为真实歌曲解析成功。审计使用虚拟歌曲标识，没有访问或下载歌曲。

## 隔离运行方式

审计入口为 `scripts/lx-source-audit.ts`。使用 esbuild 按 Node ESM 格式打包该入口及共享运行时，然后仅将打包产物和下载的固定版本脚本映射到一次性沙箱。

本次环境为 Linux bubblewrap：`--unshare-all --die-with-parent --new-session`，仅只读映射系统运行库与样本目录，独立 `/tmp`，清空环境变量。沙箱内设置 `LX_AUDIT_SANDBOX=1`，运行 Node，堆上限 128 MiB；每个脚本进程由外部 `timeout 35` 限时。一次最多运行三个沙箱。

宿主网络请求全部拒绝，不打印脚本日志、密钥、完整请求或返回链接。加载等待使用应用原有 10 秒上限，解析使用原有 20 秒上限。不要将 `node:vm` 或环境变量检查当成安全边界，也不要直接在有用户数据与凭据的开发进程中运行原始脚本。

CI 中使用自行编写的最小复现，覆盖 Huibq/ikun 的分组日志、JuheApi 的异步初始化、QDY 的 `24bit` 音质别名；不下载或运行实时变化的第三方脚本。

## 本地回归验证

- 共享运行时、移动端导入与生命周期、音源回退顺序、管理界面：42 个 Vitest 测试通过。
- 歌曲字段归一化：5 个 Node 测试通过。
- Node 与 Web 类型检查、修改文件的 ESLint / Prettier 检查通过。
- iOS 与 Android 前端构建及分包检查通过；未构建或运行原生安装包。

常规依赖环境下可复现自动化检查：

```bash
pnpm exec vitest run --config vitest.config.ts src/mobile/plugins src/services/audioSource.spec.ts src/components/settings/custom/PluginManagement.spec.ts
pnpm exec tsx --test electron/main/plugins/lx-shim.test.ts
pnpm typecheck
pnpm mobile:build
pnpm mobile:build:android
```

## 真机验收清单

当前执行环境没有 Xcode、iOS 设备或 Android adb，以下项目仍需在设备上完成，不能用离线审计替代：

- iPhone/iPad 与 Android 分别导入本地脚本和 HTTPS 直链，确认加载状态、重启恢复、禁用及卸载。
- 使用可用且允许测试的音源与歌曲验证播放、切歌、已开始播放后进入后台继续播放；Siri 后台执行自定义脚本不在范围内。
- 分别记录无插件、一个插件、两个插件的稳定内存与线程数；反复启用/禁用后确认 Worker 和在途请求释放，内存不随轮次持续增长。iOS 使用 Xcode Instruments，Android 使用系统内存分析工具。
- 记录真实请求失败原因，区分宿主错误、网络失败、服务限流与缺少有效密钥；不得通过修改鉴权来掩盖失败。
