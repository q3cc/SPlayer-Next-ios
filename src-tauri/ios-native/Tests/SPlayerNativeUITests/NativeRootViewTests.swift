import XCTest

@testable import SPlayerNativeUI

@MainActor
final class NativeRootViewTests: XCTestCase {
  /// 原生逐字模型保留共享解析器输出的毫秒与翻译
  func testTimedLyricsDecodeWithoutLosingWords() throws {
    let data = Data(
      #"{"id":0,"timeMs":1200,"endMs":2200,"text":"你好","translation":"Hello","words":[{"text":"你","startMs":1200,"endMs":1600},{"text":"好","startMs":1600,"endMs":2200}]}"#
        .utf8)
    let line = try JSONDecoder().decode(NativeLyricLine.self, from: data)
    XCTAssertEqual(line.timeMs, 1200)
    XCTAssertEqual(line.endMs, 2200)
    XCTAssertEqual(line.translation, "Hello")
    XCTAssertEqual(line.words.map(\.text), ["你", "好"])
    XCTAssertEqual(line.words.last?.endMs, 2200)
  }

  /// 歌单与推荐收藏重建存储后仍保留，不依赖内存状态
  func testCollectionsPersistAcrossLibraryInstances() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let track = NativeTrack(
      id: "netease:1", fileName: "", title: "测试", artist: "歌手", durationMs: 120000,
      source: "netease")
    let playlist = NativePlaylist(id: "test", name: "我的歌单", tracks: [track])
    try await NativeLibrary(root: root).savePlaylists([playlist])
    let loaded = try await NativeLibrary(root: root).loadPlaylists()
    XCTAssertEqual(loaded, [playlist])
  }

  func testEmptyPlayerDoesNotPretendToPlay() {
    let store = NativePlayerStore()
    store.togglePlayback()
    XCTAssertNil(store.current)
    XCTAssertFalse(store.isPlaying)
    XCTAssertEqual(store.progress, 0)
  }

  func testMissingFileDoesNotChangeCurrentTrack() {
    let store = NativePlayerStore(
      root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let track = NativeTrack(
      id: UUID(), fileName: "missing.wav", title: "Missing", artist: "Test", durationMs: 1000)
    store.play(track)
    XCTAssertNil(store.current)
    XCTAssertNotNil(store.error)
    XCTAssertFalse(store.isPlaying)
  }

  func testLyricsUseMillisecondsAndMultipleTimestamps() {
    let lines = NativeLyricLine.parse("[00:02.50][01:01.001]第二句\n[00:00.1]第一句\n[ar:歌手]")
    XCTAssertEqual(lines.map(\.text), ["第一句", "第二句", "第二句"])
    XCTAssertEqual(lines.map(\.timeMs), [100, 2500, 61001])
  }

  func testRestoredQueueKeepsPositionWithoutAutoplay() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let track = NativeTrack(
      id: "netease:1", fileName: "", title: "测试", artist: "歌手", durationMs: 120000,
      source: "netease")
    let state = NativePlaybackState(
      queue: [track], currentID: track.id, positionMs: 32000, favorites: [track], history: [track])
    try await NativeLibrary(root: root).savePlayback(state)
    let player = NativePlayerStore(root: root)
    await player.loadLibrary()
    player.setInterfaceActive(true)
    try await Task.sleep(nanoseconds: 600_000_000)
    XCTAssertEqual(player.positionMs, 32000)
    XCTAssertEqual(player.current, track)
    XCTAssertEqual(player.favoriteTracks, [track])
    XCTAssertFalse(player.isPlaying)
  }

  func testCancellationBeforeRuntimeStartsDoesNotExecuteRequest() async throws {
    let runtime = SiriRuntime(
      resourceDirectory: URL(fileURLWithPath: "/nonexistent-test-resources"))
    runtime.cancel()
    do {
      _ = try await runtime.run(["action": "search"], storage: [:])
      XCTFail("取消后不得启动")
    } catch { XCTAssertTrue(error is CancellationError) }
  }

  func testOnlineLyricFilenameCannotContainDirectorySeparators() {
    let track = NativeTrack(
      id: "plugin:test:../../escape", fileName: "", title: "测试", artist: "", durationMs: 0)
    XCTAssertFalse(track.lyricFileName.contains("/"))
  }

  func testLibraryImportPersistsAndPreservesOriginal() async throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let source = temporary.appendingPathComponent("test.wav")
    var data = Data()
    func word(_ value: UInt32, bytes: Int) {
      for offset in 0..<bytes { data.append(UInt8(truncatingIfNeeded: value >> (offset * 8))) }
    }
    data.append(Data("RIFF".utf8))
    word(1636, bytes: 4)
    data.append(Data("WAVEfmt ".utf8))
    word(16, bytes: 4)
    word(1, bytes: 2)
    word(1, bytes: 2)
    word(8000, bytes: 4)
    word(16000, bytes: 4)
    word(2, bytes: 2)
    word(16, bytes: 2)
    data.append(Data("data".utf8))
    word(1600, bytes: 4)
    data.append(Data(repeating: 0, count: 1600))
    try data.write(to: source)
    let root = temporary.appendingPathComponent("library")
    let library = NativeLibrary(root: root)
    let track = try await library.importFile(source)
    let loaded = try await NativeLibrary(root: root).load()
    XCTAssertEqual(loaded, [track])
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    try await library.remove(track)
    let empty = try await library.load()
    XCTAssertTrue(empty.isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
  }
}
