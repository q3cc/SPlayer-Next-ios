# 文件夹选择诊断

本次仅增加观测，不改变选择器关闭、授权保存与扫描顺序。必须重新构建并安装 IPA，更新网页资源不能替换 Swift/Rust 埋点。

## 采集

在设置中搜索“日志记录”并开启，然后只操作一次添加文件夹。点击“使用文件夹”后等待至少 20 秒；如果仍停留在系统列表，尝试取消返回，不要连续确认。通过“文件”App 打开 SPlayer（或 SPlayer Next）下的 `logs`，发送本次启动生成的 `.log`。没有取消响应时也可以切换到“文件”App 获取日志，不必先强制退出。

日志开关必须在打开选择器之前开启。前端日志写入现有诊断文件，Swift 使用标准错误即时输出，Rust 使用 `eprintln!`，同样进入现有诊断文件重定向。关闭日志开关恢复标准输出目标，停止文件记录；已经开始的原生请求仍可能向调试控制台输出剩余阶段。

## 判读

同一次选择使用相同的 `id`，统一前缀为 `[folder-trace]`。扫描任务使用独立标识。埋点只记录阶段、数量、耗时和状态，不记录文件名、完整目录或歌曲内容。

| 最后阶段                                                      | 排查位置                                         |
| ------------------------------------------------------------- | ------------------------------------------------ |
| `open-call`，没有 `open-enter`                                | JS 到 Rust 的调用或权限校验                      |
| `swift-dispatch`，没有 `swift-enter`                          | Rust 到 Swift 的分发                             |
| `present-request` / `present-state`，没有 `present-completed` | UIKit 呈现转场                                   |
| `present-completed`，没有 `delegate-selected`                 | 系统尚未向应用交付选择结果；不能据此声称复制卡住 |
| `dismiss-request`，没有 `dismiss-completed`                   | 关闭转场未完成                                   |
| `coordinate-begin`，没有 `coordinate-accessor`                | 文件协调等待                                     |
| `bookmark-save-begin`，没有 `bookmark-save-end`               | 安全书签保存                                     |
| `resolve`，没有 `swift-return`                                | 原生响应或 Rust 反序列化                         |
| `scope-begin`，没有 `open-return`                             | 文件访问范围授权                                 |
| `stat-begin` / `persist-begin`                                | 前端目录校验或持久化                             |
| `read-dir-begin` / `track-read-begin`                         | 后续枚举或曲目读取                               |

15 秒的一次性 `still-pending` 和 `panel-still-present` 只采样等待状态，不取消操作，也不判定超时失败。UIKit 没有向应用暴露系统“使用文件夹”按钮的点击通知，因此没有 `delegate-selected` 时，需结合实际点击时间判断；不会通过私有接口拦截系统按钮。大目录枚举和曲目读取只记录前 10 项以及每 100 项，避免日志过量。

## 验证范围

前端回归验证诊断开关、请求标识透传、取消后释放计时器和原有添加目录行为。Windows 环境不能编译 UIKit 或验证系统面板实际关闭，需本机 Xcode 构建与真机采集。
