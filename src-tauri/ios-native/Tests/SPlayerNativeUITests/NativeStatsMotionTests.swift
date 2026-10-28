import XCTest

@testable import SPlayerNativeUI

/// 收听统计、播放行为与共享过渡的纯逻辑测试
@MainActor
final class NativeStatsMotionTests: XCTestCase {
  private var calendar: Calendar = {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return value
  }()

  private func date(_ text: String) -> Date {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.date(from: text)!
  }

  private func ms(_ text: String) -> Double { date(text).timeIntervalSince1970 * 1000 }

  private func track(_ id: String, artist: String = "歌手", album: String? = nil) -> NativeTrack {
    NativeTrack(
      id: id, fileName: id + ".flac", title: "歌" + id, artist: artist, durationMs: 180_000,
      album: album, source: "netease")
  }

  private func data(_ plays: [(NativeTrack, String, Double)]) -> NativePlayStatsData {
    var value = NativePlayStatsData()
    for (track, time, listened) in plays {
      value.tracks[track.id] = track
      value.plays.append(NativePlayEvent(key: track.id, startedAt: ms(time), listenedMs: listened))
    }
    return value
  }

  // MARK: - 统计汇总

  func testSummaryUsesMondayWeeksAndStreakFromYesterday() {
    // 2026-10-27 是周二：本周从 10-26 周一开始
    let now = date("2026-10-27 09:00")
    let a = track("a")
    var stats = data([
      (a, "2026-10-26 08:00", 60_000), (a, "2026-10-25 22:00", 120_000),
      (a, "2026-10-24 10:00", 30_000), (a, "2026-10-18 10:00", 10_000),
    ])
    stats.favorites = [
      NativeFavoriteEvent(add: true, at: ms("2026-10-26 09:00")),
      NativeFavoriteEvent(add: false, at: ms("2026-10-26 10:00")),
      NativeFavoriteEvent(add: true, at: ms("2026-10-25 09:00")),
    ]
    let summary = NativeStatsMath.summary(stats, now: now, calendar: calendar)
    XCTAssertEqual(summary.todayListenedMs, 0)
    XCTAssertEqual(summary.weekListenedMs, 60_000)
    XCTAssertEqual(summary.weekPlayCount, 1)
    XCTAssertEqual(summary.lastWeekListenedMs, 150_000)
    XCTAssertEqual(summary.totalPlayCount, 4)
    XCTAssertEqual(summary.weekFavoriteAdds, 1)
    // 今天还没听：从昨天往前数 26、25、24 三天
    XCTAssertEqual(summary.streakDays, 3)
    XCTAssertEqual(
      NativeStatsMath.streak(["2026-10-24"], now: now, calendar: calendar), 0)
  }

  func testRankingsCountPlaysThenRecencyAndSplitArtists() {
    let a = track("a", artist: "甲 / 乙", album: "专辑一")
    let b = track("b", artist: "乙", album: " ")
    let c = track("c", artist: "丙", album: "专辑一")
    let stats = data([
      (a, "2026-10-20 10:00", 9000), (b, "2026-10-21 10:00", 9000),
      (b, "2026-10-22 10:00", 9000), (c, "2026-10-23 10:00", 9000),
      (a, "2026-10-24 10:00", 9000),
    ])
    let songs = NativeStatsMath.topTracks(stats, limit: 10)
    XCTAssertEqual(songs.map(\.track.id), ["a", "b", "c"])
    XCTAssertEqual(songs.map(\.plays), [2, 2, 1])
    let albums = NativeStatsMath.topAlbums(stats, limit: 10)
    XCTAssertEqual(albums.map(\.title), ["专辑一"])
    XCTAssertEqual(albums.first?.plays, 3)
    XCTAssertEqual(albums.first?.track.id, "a")
    let artists = NativeStatsMath.topArtists(stats, limit: 10)
    XCTAssertEqual(artists.map(\.title), ["乙", "甲", "丙"])
    XCTAssertEqual(artists.map(\.plays), [4, 2, 1])
  }

  func testDailyHourlyAndLibraryStats() {
    let a = track("a")
    let stats = data([
      (a, "2026-10-27 08:10", 9000), (a, "2026-10-27 08:50", 9000), (a, "2026-07-01 23:00", 9000),
    ])
    let now = date("2026-10-27 09:00")
    XCTAssertEqual(
      NativeStatsMath.daily(stats, days: 90, now: now, calendar: calendar), ["2026-10-27": 2])
    let hourly = NativeStatsMath.hourly(stats, calendar: calendar)
    XCTAssertEqual(hourly.count, 24)
    XCTAssertEqual(hourly[8], 2)
    XCTAssertEqual(hourly[23], 1)

    let library = NativeStatsMath.library(
      [
        track("1", artist: "甲 / 乙", album: "A"), track("2", artist: "乙", album: "A"),
        NativeTrack(id: "3", fileName: "3.mp3", title: "3", artist: "", durationMs: 60_000),
      ], sizes: ["1": 100, "3": 50])
    XCTAssertEqual(library.trackCount, 3)
    XCTAssertEqual(library.albumCount, 1)
    XCTAssertEqual(library.artistCount, 2)
    XCTAssertEqual(library.totalDurationMs, 420_000)
    XCTAssertEqual(library.totalFileSize, 150)
    XCTAssertEqual(library.codecs.map(\.codec), ["flac", "mp3"])
    XCTAssertTrue(NativeStatsMath.losslessCodecs.contains("flac"))
  }

  // MARK: - 会话采集

  func testSessionsExcludePausesAndSkipShortPlays() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var now = 1_000_000.0
    let stats = NativePlayStats(root: root)
    stats.clock = { now }
    let a = track("a")
    let b = track("b")
    stats.trackChanged(a, playing: true)
    now += 10_000
    stats.playingChanged(false)
    now += 60_000
    stats.playingChanged(true)
    now += 5_000
    // 单曲循环：每圈各成一条
    stats.trackEnded()
    now += 3_000
    // 不足 5 秒不记录
    stats.trackChanged(b, playing: true)
    now += 4_000
    stats.trackChanged(nil, playing: false)
    XCTAssertEqual(stats.data.plays.map(\.listenedMs), [15_000])
    XCTAssertEqual(stats.data.plays.first?.startedAt, 1_000_000)
    XCTAssertEqual(stats.revision, 1)
  }

  func testPendingSessionIsRecordedOnNextLaunch() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var now = 2_000_000.0
    let first = NativePlayStats(root: root)
    first.clock = { now }
    first.trackChanged(track("a"), playing: true)
    now += 42_000
    first.checkpoint()
    let file = root.appendingPathComponent("play-stats.json")
    for _ in 0..<50 where !FileManager.default.fileExists(atPath: file.path) {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    let second = NativePlayStats(root: root)
    await second.load()
    XCTAssertEqual(second.data.plays.map(\.listenedMs), [42_000])
    XCTAssertNil(second.data.pending)
    XCTAssertEqual(second.data.tracks["a"]?.title, "歌a")
  }

  // MARK: - 播放行为

  func testPlayNowInsertsAfterCurrentWithoutReplacingQueue() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let a = track("a")
    let b = track("b")
    let c = track("c")
    let state = NativePlaybackState(queue: [a, b], currentID: a.id, positionMs: 0)
    try await NativeLibrary(root: root).savePlayback(state)
    let player = NativePlayerStore(root: root)
    await player.loadLibrary()
    player.playNow(c)
    XCTAssertEqual(player.queue.map(\.id), ["a", "c", "b"])
    // 已在队列中的歌曲移动到当前曲目之后，不重复
    player.playNow(b)
    XCTAssertEqual(player.queue.map(\.id), ["a", "b", "c"])
  }

  func testInsertNextKeepsOrderAndSkipsCurrent() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let a = track("a")
    let b = track("b")
    let c = track("c")
    let d = track("d")
    let state = NativePlaybackState(queue: [a, b, c], currentID: a.id, positionMs: 0)
    try await NativeLibrary(root: root).savePlayback(state)
    let player = NativePlayerStore(root: root)
    await player.loadLibrary()
    // 当前曲目不移动；已在队列中的曲目按传入顺序插到当前曲目之后
    XCTAssertEqual(player.insertNext([d, c, a]), 2)
    XCTAssertEqual(player.queue.map(\.id), ["a", "d", "c", "b"])
  }

  // MARK: - 关于与更新

  func testVersionPartsMatchMainRules() {
    XCTAssertEqual(NativeGitHub.versionParts("ios-v2.1.0"), [2, 1, 0, 0, 0])
    XCTAssertEqual(NativeGitHub.versionParts("v2.2.0-beta.3"), [2, 2, 0, -1, 3])
    XCTAssertEqual(NativeGitHub.versionParts("2.2.0-alpha"), [2, 2, 0, -2, 0])
    XCTAssertNil(NativeGitHub.versionParts("android-v5.0.0"))
  }

  func testNewestReleaseSkipsPrereleasesAndReleasesWithoutIPA() {
    func release(_ tag: String, prerelease: Bool = false, ipa: Bool = true) -> [String: Any] {
      [
        "tag_name": tag, "draft": false, "prerelease": prerelease, "body": "说明<!-- splayer-action:{} -->",
        "assets": ipa ? [["name": "SPlayer.ipa", "state": "uploaded", "size": 10]] : [],
      ]
    }
    let releases = [
      release("ios-v2.3.0", ipa: false), release("ios-v2.4.0-beta.1", prerelease: true),
      release("ios-v2.2.0"), release("ios-v2.1.5"),
    ]
    let newest = NativeGitHub.newest(in: releases, current: "2.1.0")
    XCTAssertEqual(newest?.version, "2.2.0")
    XCTAssertEqual(newest?.notes, "说明")
    XCTAssertEqual(
      newest?.page.absoluteString, "https://github.com/q3cc/SPlayer-Next-ios/releases/tag/ios-v2.2.0")
    XCTAssertNil(NativeGitHub.newest(in: releases, current: "2.2.0"))
  }
}
