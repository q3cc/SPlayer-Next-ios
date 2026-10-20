# SPlayer 的 FLAC 精确跳转修复

来源：https://github.com/dimitris-c/AudioStreaming

固定版本：`4b8bae96c2e624aa64f6e0ac361ee76a3374a641`，与替换前 Swift Package 引用一致。
原始 MIT 许可保留在 `LICENSE`，未修改的上游源码及测试保持原样。

## 本地差异

- `FlacSeekTable.swift`：流式读取 STREAMINFO / SEEKTABLE；跳过封面和其他标签，最多保留 4096 个定位点。
- `AudioEntry.swift`：FLAC 总时长使用 STREAMINFO 的真实采样数。
- `AudioFileStreamProcessor.swift`：FLAC 跳到目标之前的定位点，再解码并丢弃差额 PCM，避免把压缩字节比例当作时间。缺少 SEEKTABLE 时从首帧解码到目标，可能需要较长缓冲，但不再播放错误位置。其他编码仍走上游逻辑。

不会缓存完整 PCM 或新增磁盘音频缓存；跳转时临时 PCM 缓冲最多为 4096 个输出帧。切歌重置定位表，取消或再次跳转打断旧的预解码。

## 验证

```sh
swiftc src-tauri/vendor/AudioStreaming/AudioStreaming/Streaming/AudioPlayer/Processors/FlacSeekTable.swift scripts/ios-seek-tests/main.swift -o /tmp/splayer-seek-tests
/tmp/splayer-seek-tests
```

可额外传入本地 FLAC 路径检查真实元数据。CI 的 iOS 打包流程会运行以上检查，并编译包含 Core Audio 丢帧处理的完整原生播放器。仍需在 iPad 上验证连续跳转、暂停后跳转与系统进度条。
