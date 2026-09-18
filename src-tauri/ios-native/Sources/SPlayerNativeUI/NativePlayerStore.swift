import Foundation
import Combine

/// 原生播放器展示状态；播放引擎接入后由桥接层更新。
@MainActor
public final class NativePlayerStore: ObservableObject {
    @Published public private(set) var title = "未在播放"
    @Published public private(set) var artist = "选择一首歌曲开始播放"
    @Published public private(set) var isPlaying = false
    @Published public private(set) var progress = 0.0

    public init() {}

    public func togglePlayback() { isPlaying.toggle() }

    public func select(title: String, artist: String) {
        self.title = title
        self.artist = artist
        progress = 0
        isPlaying = true
    }
}
