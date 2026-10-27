import Foundation

/// 一次播放记录，对应原版 play_history；曲目快照按 id 去重存放
struct NativePlayEvent: Codable, Equatable {
  let key: String
  /// 本次播放开始 unix ms
  let startedAt: Double
  /// 实际收听毫秒（扣掉暂停）
  let listenedMs: Double
}

/// 一次收藏变更，只用于本周新增收藏计数
struct NativeFavoriteEvent: Codable, Equatable {
  let add: Bool
  let at: Double
}

/// 进行中的播放会话；退到后台时落盘，被系统结束后下次启动补记
struct NativePlaySession: Codable, Equatable {
  var track: NativeTrack
  let startedAt: Double
  var listenedMs: Double
  var playingSince: Double?

  /// 截至某时刻的收听时长
  /// @param now - 当前 unix ms
  /// @returns 已收听毫秒
  func listened(at now: Double) -> Double {
    listenedMs + (playingSince.map { max(0, now - $0) } ?? 0)
  }
}

struct NativePlayStatsData: Codable, Equatable {
  var tracks: [String: NativeTrack] = [:]
  var plays: [NativePlayEvent] = []
  var favorites: [NativeFavoriteEvent] = []
  var pending: NativePlaySession?
}

/// 播放统计汇总，字段与原版 PlayStatsSummary 一致
struct NativePlayStatsSummary: Equatable {
  var todayListenedMs = 0.0
  var weekListenedMs = 0.0
  var lastWeekListenedMs = 0.0
  var totalListenedMs = 0.0
  var weekPlayCount = 0
  var totalPlayCount = 0
  var weekFavoriteAdds = 0
  var streakDays = 0
}

/// 榜单项：代表曲目与累计播放次数
struct NativeRankItem: Identifiable, Equatable {
  let id: String
  let title: String
  let track: NativeTrack
  let plays: Int
}

/// 曲库概览，对应原版 LibraryStats
struct NativeLibraryStats: Equatable {
  var trackCount = 0
  var albumCount = 0
  var artistCount = 0
  var totalDurationMs = 0.0
  var totalFileSize: Int64 = 0
  var codecs: [(codec: String, count: Int)] = []

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.trackCount == rhs.trackCount && lhs.albumCount == rhs.albumCount
      && lhs.artistCount == rhs.artistCount && lhs.totalDurationMs == rhs.totalDurationMs
      && lhs.totalFileSize == rhs.totalFileSize && lhs.codecs.map(\.codec) == rhs.codecs.map(\.codec)
      && lhs.codecs.map(\.count) == rhs.codecs.map(\.count)
  }
}

/// 播放统计采集：累计每首歌的实际收听时长，切歌、播完或退到后台时结算，对应原版 core/player/stats.ts
@MainActor
final class NativePlayStats: ObservableObject {
  /// 低于此收听时长不记录
  static let minRecordMs = 5000.0
  /// 收藏变更只用于本周计数，保留两周即可
  static let favoriteRetentionMs = 14 * 86_400_000.0

  /// 记录变化时递增，界面据此重新汇总
  @Published private(set) var revision = 0
  private(set) var data = NativePlayStatsData()
  private var session: NativePlaySession?
  private let url: URL
  private let writer = DispatchQueue(label: "native.play-stats", qos: .utility)
  /// 当前 unix ms；测试中替换为可控时钟
  var clock: () -> Double = { Date().timeIntervalSince1970 * 1000 }
  /// 首页随播放进度频繁重绘，按记录版本与日期缓存汇总
  private var home: (key: String, summary: NativePlayStatsSummary, top: [NativeRankItem])?

  init(root: URL) {
    url = root.appendingPathComponent("play-stats.json")
  }

  /// 读取历史记录，并补记上次被系统结束时未结算的会话
  func load() async {
    let url = url
    let loaded = await Task.detached(priority: .utility) { () -> NativePlayStatsData? in
      guard let raw = try? Data(contentsOf: url) else { return nil }
      return try? JSONDecoder().decode(NativePlayStatsData.self, from: raw)
    }.value
    guard var loaded else { return }
    if let pending = loaded.pending {
      Self.append(pending, listened: pending.listenedMs, to: &loaded)
      loaded.pending = nil
    }
    data = loaded
    revision += 1
    if session != nil { save() }
  }

  /// 曲目身份变化：结算旧会话并为新曲开会话
  /// @param track - 新的当前曲目
  /// @param playing - 是否正在播放
  func trackChanged(_ track: NativeTrack?, playing: Bool) {
    let now = clock()
    finalize(at: now)
    if let track { begin(track, playing: playing, at: now) }
  }

  /// 播放态变化：在同一会话内累计或暂停计时；暂停时落盘便于后台被结束后补记
  /// @param playing - 是否正在播放
  func playingChanged(_ playing: Bool) {
    guard var current = session else { return }
    let now = clock()
    if playing {
      if current.playingSince == nil { current.playingSince = now }
    } else {
      current.listenedMs = current.listened(at: now)
      current.playingSince = nil
    }
    session = current
    if !playing { save() }
  }

  /// 歌曲自然播完：结算后为同一首开新会话，单曲循环每圈各成一条记录
  func trackEnded() {
    guard let track = session?.track else { return }
    let now = clock()
    finalize(at: now)
    begin(track, playing: true, at: now)
  }

  /// 首页头部统计与“继续聆听”曲目
  /// @returns 汇总与最常播放的 6 首
  func homeSnapshot() -> (summary: NativePlayStatsSummary, top: [NativeRankItem]) {
    let now = Date()
    let key = "\(revision):" + NativeStatsMath.dayKey(now, calendar: .current)
    if let home, home.key == key { return (home.summary, home.top) }
    let value = (
      NativeStatsMath.summary(data, now: now, calendar: .current),
      NativeStatsMath.topTracks(data, limit: 6)
    )
    home = (key, value.0, value.1)
    return value
  }

  /// 退到后台时保存进行中的会话
  func checkpoint() { save() }

  /// 记录收藏变更
  /// @param add - 收藏或取消收藏
  func recordFavorite(add: Bool) {
    let now = clock()
    data.favorites.removeAll { now - $0.at > Self.favoriteRetentionMs }
    data.favorites.append(NativeFavoriteEvent(add: add, at: now))
    revision += 1
    save()
  }

  private func begin(_ track: NativeTrack, playing: Bool, at now: Double) {
    session = NativePlaySession(
      track: track, startedAt: now, listenedMs: 0, playingSince: playing ? now : nil)
  }

  private func finalize(at now: Double) {
    guard let current = session else { return }
    session = nil
    if Self.append(current, listened: current.listened(at: now), to: &data) {
      revision += 1
      save()
    }
  }

  /// 收听达到阈值才写入
  /// @returns 是否写入了记录
  @discardableResult
  private static func append(
    _ session: NativePlaySession, listened: Double, to data: inout NativePlayStatsData
  ) -> Bool {
    guard listened >= minRecordMs else { return false }
    data.tracks[session.track.id] = session.track
    data.plays.append(
      NativePlayEvent(key: session.track.id, startedAt: session.startedAt, listenedMs: listened))
    return true
  }

  /// 进行中的会话一并写入，系统结束应用后下次启动按已收听时长补记
  private func save() {
    var snapshot = data
    if var current = session {
      current.listenedMs = current.listened(at: clock())
      current.playingSince = nil
      snapshot.pending = current
    }
    guard let raw = try? JSONEncoder().encode(snapshot) else { return }
    let url = url
    writer.async { try? raw.write(to: url, options: .atomic) }
  }
}

/// 统计汇总的纯计算，与原版 playStats.ts 的 SQL 口径一致；时区按本地日历
enum NativeStatsMath {
  /// 本地日期 key：YYYY-MM-DD
  static func dayKey(_ date: Date, calendar: Calendar) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }

  /// 本周一 00:00；与原版一致按周一起算，不随系统首日设置变化
  static func weekStart(_ now: Date, calendar: Calendar) -> Date {
    let today = calendar.startOfDay(for: now)
    let fromMonday = (calendar.component(.weekday, from: now) + 5) % 7
    return calendar.date(byAdding: .day, value: -fromMonday, to: today) ?? today
  }

  /// 从有播放的日期集合算连续收听天数；今天还没听则从昨天起算
  static func streak(_ days: Set<String>, now: Date, calendar: Calendar) -> Int {
    var cursor = calendar.startOfDay(for: now)
    if !days.contains(dayKey(cursor, calendar: calendar)) {
      cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
    }
    var count = 0
    while days.contains(dayKey(cursor, calendar: calendar)) {
      count += 1
      cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
    }
    return count
  }

  static func summary(_ data: NativePlayStatsData, now: Date, calendar: Calendar)
    -> NativePlayStatsSummary
  {
    let day = calendar.startOfDay(for: now).timeIntervalSince1970 * 1000
    let week = weekStart(now, calendar: calendar).timeIntervalSince1970 * 1000
    let lastWeek = week - 7 * 86_400_000
    var result = NativePlayStatsSummary()
    var days = Set<String>()
    for play in data.plays {
      result.totalListenedMs += play.listenedMs
      result.totalPlayCount += 1
      if play.startedAt >= day { result.todayListenedMs += play.listenedMs }
      if play.startedAt >= week {
        result.weekListenedMs += play.listenedMs
        result.weekPlayCount += 1
      } else if play.startedAt >= lastWeek {
        result.lastWeekListenedMs += play.listenedMs
      }
      days.insert(dayKey(Date(timeIntervalSince1970: play.startedAt / 1000), calendar: calendar))
    }
    result.weekFavoriteAdds = data.favorites.filter { $0.add && $0.at >= week }.count
    result.streakDays = streak(days, now: now, calendar: calendar)
    return result
  }

  /// 按分组统计次数，同次数按最近播放排序
  /// @param keys - 一条播放记录贡献的分组；歌手榜一首歌可贡献多位歌手
  private static func rank(
    _ data: NativePlayStatsData, limit: Int,
    keys: (NativeTrack) -> [(key: String, title: String)]
  ) -> [NativeRankItem] {
    var groups: [String: (title: String, track: NativeTrack, plays: Int, last: Double)] = [:]
    for play in data.plays {
      guard let track = data.tracks[play.key] else { continue }
      for (key, title) in keys(track) {
        var group = groups[key] ?? (title, track, 0, 0)
        group.plays += 1
        if play.startedAt >= group.last {
          group.last = play.startedAt
          group.track = track
        }
        groups[key] = group
      }
    }
    return groups.sorted { a, b in
      a.value.plays != b.value.plays ? a.value.plays > b.value.plays : a.value.last > b.value.last
    }.prefix(limit).map {
      NativeRankItem(id: $0.key, title: $0.value.title, track: $0.value.track, plays: $0.value.plays)
    }
  }

  static func topTracks(_ data: NativePlayStatsData, limit: Int) -> [NativeRankItem] {
    rank(data, limit: limit) { [($0.id, $0.title)] }
  }

  static func topAlbums(_ data: NativePlayStatsData, limit: Int) -> [NativeRankItem] {
    rank(data, limit: limit) { track in
      let album = (track.album ?? "").trimmingCharacters(in: .whitespaces)
      return album.isEmpty ? [] : [((track.source ?? "local") + ":" + album, album)]
    }
  }

  /// 在线曲目的歌手以“ / ”拼接，按此拆回单个歌手
  static func topArtists(_ data: NativePlayStatsData, limit: Int) -> [NativeRankItem] {
    rank(data, limit: limit) { track in
      track.artist.components(separatedBy: " / ").map {
        $0.trimmingCharacters(in: .whitespaces)
      }.filter { !$0.isEmpty }.map { ((track.source ?? "local") + ":" + $0.lowercased(), $0) }
    }
  }

  /// 最近 N 天（含今天）每天的播放次数
  static func daily(_ data: NativePlayStatsData, days: Int, now: Date, calendar: Calendar)
    -> [String: Int]
  {
    let start = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now))
    let from = (start ?? now).timeIntervalSince1970 * 1000
    var result: [String: Int] = [:]
    for play in data.plays where play.startedAt >= from {
      result[dayKey(Date(timeIntervalSince1970: play.startedAt / 1000), calendar: calendar), default: 0] += 1
    }
    return result
  }

  /// 本地时区 0-23 点各自的累计播放次数
  static func hourly(_ data: NativePlayStatsData, calendar: Calendar) -> [Int] {
    var result = Array(repeating: 0, count: 24)
    for play in data.plays {
      result[calendar.component(.hour, from: Date(timeIntervalSince1970: play.startedAt / 1000))] += 1
    }
    return result
  }

  /// 无损编码，与原版 utils/quality.ts 一致
  static let losslessCodecs: Set<String> = ["flac", "alac", "ape", "wav", "aiff", "wavpack", "tta"]

  /// 曲库概览；格式按扩展名统计，文件大小由调用方读取后传入
  /// @param tracks - 曲库曲目
  /// @param sizes - 每首曲目的文件字节数
  static func library(_ tracks: [NativeTrack], sizes: [String: Int64]) -> NativeLibraryStats {
    var codecs: [String: Int] = [:]
    for track in tracks {
      let ext = (track.fileName as NSString).pathExtension.lowercased()
      codecs[ext == "wv" ? "wavpack" : ext == "aif" ? "aiff" : ext, default: 0] += 1
    }
    return NativeLibraryStats(
      trackCount: tracks.count,
      albumCount: Set(tracks.compactMap { $0.album?.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }).count,
      artistCount: Set(tracks.flatMap { $0.artist.components(separatedBy: " / ") }
        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }).count,
      totalDurationMs: tracks.reduce(0) { $0 + $1.durationMs },
      totalFileSize: sizes.values.reduce(0, +),
      codecs: codecs.filter { !$0.key.isEmpty }.sorted { $0.value > $1.value }.map { ($0.key, $0.value) })
  }
}
