import Foundation

/// Siri 可在选歌前后重建处理器；候选歌曲不能依赖处理器实例存活。
final class SiriSelection {
  private(set) var tracks: [[String: Any]] = []

  func replace(_ values: [[String: Any]]) { tracks = Array(values.prefix(50)) }

  func track(_ identifier: String, queue: [[String: Any]]) -> [String: Any]? {
    (tracks + queue).first { SiriQueue.key($0) == identifier }
  }

  func command(identifier: String?, hasMediaItems: Bool, query: String, artist: String,
    queue: [[String: Any]]) throws -> [String: Any] {
    if let identifier = identifier, !identifier.isEmpty {
      guard let selected = track(identifier, queue: queue) else {
        throw SiriFailure("所选歌曲已失效，请重新搜索，未恢复其他歌曲")
      }
      return ["action": "playTrack", "track": selected]
    }
    if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !artist.isEmpty {
      return ["action": "playQuery", "query": query, "artist": artist]
    }
    guard !hasMediaItems else { throw SiriFailure("没有收到所选歌曲的标识，请重新选择") }
    return ["action": "resume"]
  }
}
