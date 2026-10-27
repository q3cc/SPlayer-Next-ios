import Foundation

/// 当前曲目的毫秒偏移按歌曲标识保存，最多保留 256 个非零设置
struct NativeLyricOffsets: Codable {
  struct Entry: Codable {
    let id: String
    let value: Double
  }
  var entries: [Entry] = []
  static func load() -> Self {
    guard let data = UserDefaults.standard.data(forKey: "native.lyric.offsets"),
      let value = try? JSONDecoder().decode(Self.self, from: data)
    else { return Self() }
    return Self(
      entries: Array(
        value.entries.filter { $0.value.isFinite && abs($0.value) <= 10000 }.suffix(256)))
  }
  func value(for id: String) -> Double { entries.last { $0.id == id }?.value ?? 0 }
  /// 编辑移动到末尾，归零移除记录，旧记录按顺序淘汰
  mutating func set(_ value: Double, for id: String) {
    entries.removeAll { $0.id == id }
    if value != 0 { entries.append(Entry(id: id, value: value)) }
    entries = Array(entries.suffix(256))
    if let data = try? JSONEncoder().encode(self) {
      UserDefaults.standard.set(data, forKey: "native.lyric.offsets")
    }
  }
}
