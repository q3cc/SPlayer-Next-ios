import Foundation

struct SiriFailure: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

/// 所有队列修改在主线程执行，版本号阻止旧网页快照覆盖后台切歌。
final class SiriQueue {
  private(set) var revision = 0
  private(set) var tracks: [[String: Any]] = []
  private(set) var currentKey: String?
  var position = 0.0
  var playing = false

  static func key(_ track: [String: Any]) -> String {
    "\(track["source"] as? String ?? "local"):\(track["id"] as? String ?? "")"
  }
  var current: [String: Any]? { tracks.first { Self.key($0) == currentKey } }
  var json: [String: Any] {
    ["revision": revision, "queue": tracks, "currentId": currentKey as Any? ?? NSNull(),
     "position": position, "playing": playing]
  }
  func restore(_ value: [String: Any]) {
    revision = value["revision"] as? Int ?? 0
    tracks = value["queue"] as? [[String: Any]] ?? []
    currentKey = value["currentId"] as? String
    position = value["position"] as? Double ?? 0
    // 冷启动只恢复位置，不能未经用户操作自行播放。
    playing = false
  }
  @discardableResult
  func replace(_ value: [String: Any]) -> Bool {
    guard value["revision"] as? Int == revision else { return false }
    tracks = value["queue"] as? [[String: Any]] ?? []
    currentKey = value["currentId"] as? String
    position = value["position"] as? Double ?? 0
    playing = value["playing"] as? Bool ?? false
    revision += 1
    return true
  }
  func select(_ track: [String: Any], replacing: [[String: Any]]? = nil) {
    if let replacing = replacing { tracks = replacing }
    if !tracks.contains(where: { Self.key($0) == Self.key(track) }) { tracks.append(track) }
    currentKey = Self.key(track)
    position = 0
    revision += 1
  }
  func neighbor(_ direction: Int) throws -> [String: Any] {
    guard !tracks.isEmpty else { throw SiriFailure("播放队列为空，请先选择歌曲") }
    let index = tracks.firstIndex { Self.key($0) == currentKey } ?? 0
    return tracks[(index + direction + tracks.count) % tracks.count]
  }
}
