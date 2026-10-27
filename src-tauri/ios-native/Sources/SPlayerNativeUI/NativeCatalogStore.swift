import Combine
import Foundation

/// 搜索与推荐不随播放进度刷新；新搜索取消旧请求，迟到结果不会覆盖当前页面
@MainActor
final class NativeCatalogStore: ObservableObject {
  @Published var query = ""
  @Published var source = "netease"
  @Published private(set) var results: [NativeTrack] = []
  @Published private(set) var recommendations: [NativeCover] = []
  @Published private(set) var playlist: [NativeTrack] = []
  @Published private(set) var playlistTitle = ""
  /// 当前打开的歌单卡片，详情头部直接沿用卡片封面与简介
  @Published private(set) var playlistCover: NativeCover?
  @Published private(set) var searching = false
  @Published private(set) var loadingHome = false
  @Published private(set) var loadingPlaylist = false
  @Published private(set) var hasMore = false
  @Published var error: String?
  private var searchTask: Task<Void, Never>?
  private var playlistTask: Task<Void, Never>?
  private var searchGeneration = 0
  private var playlistGeneration = 0
  let service: NativeOnlineService

  /// 注入共用平台服务，保持搜索与播放状态分离
  init(service: NativeOnlineService) { self.service = service }

  /// 拉取与新版 Web 首页相同的真实推荐歌单
  func loadHome(refresh: Bool = false) async {
    guard recommendations.isEmpty || refresh, !loadingHome else { return }
    loadingHome = true
    defer { loadingHome = false }
    do {
      let raw = try await service.call(["action": "home"])
      recommendations = try JSONDecoder().decode(
        [NativeCover].self, from: JSONSerialization.data(withJSONObject: raw))
    } catch is CancellationError {} catch { self.error = error.localizedDescription }
  }

  /// 搜索按平台分页，只有当前请求可写入结果
  /// - Parameter more: 是否追加下一页
  func search(more: Bool = false) {
    searchTask?.cancel()
    searchGeneration += 1
    let generation = searchGeneration
    let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !keyword.isEmpty else {
      results = []
      searching = false
      hasMore = false
      return
    }
    let offset = more ? results.count : 0
    if !more {
      results = []
      hasMore = false
    }
    searching = true
    error = nil
    searchTask = Task {
      do {
        let raw =
          try await service.call([
            "action": "search", "source": source, "query": keyword, "offset": offset,
          ]) as? [String: Any] ?? [:]
        guard generation == searchGeneration, !Task.isCancelled else { return }
        let tracks = (raw["items"] as? [[String: Any]] ?? []).compactMap(NativeTrack.online)
        let previous = more ? results : []
        let seen = Set(previous.map(\.id))
        results = previous + tracks.filter { !seen.contains($0.id) }
        hasMore = raw["hasMore"] as? Bool ?? false
      } catch is CancellationError {} catch {
        if generation == searchGeneration { self.error = error.localizedDescription }
      }
      if generation == searchGeneration { searching = false }
    }
  }

  /// 载入完整歌单，切换歌单后丢弃旧请求结果
  func open(_ cover: NativeCover) {
    playlistTask?.cancel()
    playlistGeneration += 1
    let generation = playlistGeneration
    playlistTitle = cover.title
    playlistCover = cover
    playlist = []
    loadingPlaylist = true
    error = nil
    playlistTask = Task {
      defer { if generation == playlistGeneration { loadingPlaylist = false } }
      do {
        let raw =
          try await service.call(["action": "playlist", "id": cover.id]) as? [String: Any] ?? [:]
        guard generation == playlistGeneration, !Task.isCancelled else { return }
        playlist = (raw["tracks"] as? [[String: Any]] ?? []).compactMap(NativeTrack.online)
      } catch is CancellationError {} catch {
        if generation == playlistGeneration { self.error = error.localizedDescription }
      }
    }
  }
}
