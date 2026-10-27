import AVFoundation
import CoreGraphics
import XCTest

@testable import SPlayerNativeUI

@MainActor
final class NativeRootViewTests: XCTestCase {
  /// 运行原始 AMLL 预设，验证原生桥接的顶点、索引和纹理均有效
  func testOriginalAMLLMeshAndTexture() throws {
    var pixels = [UInt8](repeating: 255, count: 32 * 32 * 4)
    let context = CGContext(
      data: &pixels, width: 32, height: 32, bitsPerComponent: 8,
      bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let mesh = try NativeFluidMesh.make(image: context.makeImage()!, preset: 0)
    XCTAssertGreaterThan(mesh.vertices.count, 10000)
    XCTAssertEqual(mesh.vertices.count % 7, 0)
    XCTAssertTrue(mesh.vertices.allSatisfy(\.isFinite))
    XCTAssertLessThan(Int(mesh.indices.max()!), mesh.vertices.count / 7)
    XCTAssertEqual(mesh.pixels.count, 4096)
    XCTAssertEqual(Array(mesh.pixels.prefix(4)), [161, 161, 161, 255])
  }

  /// 120Hz 信号驱动低频脉冲，静音不伪造节拍，采样只能消费一次
  func testSpectrumUsesRealLowFrequencySamples() throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2048)!
    buffer.frameLength = 2048
    let analyzer = NativeAudioSpectrum()
    analyzer.prepare(format.streamDescription.pointee)
    for i in 0..<2048 {
      let sample = Float(sin(2 * .pi * 120 * Double(i) / 48000)) * 0.8
      buffer.floatChannelData![0][i] = sample
      buffer.floatChannelData![1][i] = sample
    }
    analyzer.push(buffer.mutableAudioBufferList, frames: 2048)
    let frame = try XCTUnwrap(analyzer.consume())
    XCTAssertEqual(frame[0].count, 128)
    XCTAssertGreaterThan(NativeAudioSpectrum.pulse(frame), 0.5)
    XCTAssertNil(analyzer.consume())
    XCTAssertEqual(
      NativeAudioSpectrum.pulse([
        [Float](repeating: 0, count: 128), [Float](repeating: 0, count: 128),
      ]), 0)
  }

  /// 原生解码器实际播放 PCM，状态、进度与暂停均由音频回调提供
  func testStreamingEnginePlaysLocalPCM() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".wav")
    defer { try? FileManager.default.removeItem(at: file) }
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000 * 5)!
    buffer.frameLength = 48000 * 5
    for i in 0..<Int(buffer.frameLength) {
      let value = Float(sin(2 * .pi * 120 * Double(i) / 48000)) * 0.02
      buffer.floatChannelData![0][i] = value
      buffer.floatChannelData![1][i] = value
    }
    do {
      let output = try AVAudioFile(forWriting: file, settings: format.settings)
      try output.write(from: buffer)
    }
    let engine = NativeAudioEngine()
    defer { engine.stop() }
    var message: String?
    engine.onError = { message = $0 }
    engine.volume = 0
    engine.load(file)
    for _ in 0..<50 {
      if engine.playing || message != nil { break }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    XCTAssertNil(message)
    XCTAssertTrue(engine.playing, message ?? "未进入播放态")
    try await Task.sleep(nanoseconds: 400_000_000)
    XCTAssertGreaterThan(engine.position, 100)
    engine.pause()
    XCTAssertFalse(engine.playing)
  }

  /// 同一音频节点的独立变调和 EQ 实际改变 PCM，而不只改变界面数值
  func testPitchAndEqualizerProcessAudio() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".wav")
    defer { try? FileManager.default.removeItem(at: file) }
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000 * 8)!
    buffer.frameLength = 48000 * 8
    for i in 0..<Int(buffer.frameLength) {
      let value = Float(sin(2 * .pi * 250 * Double(i) / 48000)) * 0.03
      buffer.floatChannelData![0][i] = value
      buffer.floatChannelData![1][i] = value
    }
    do {
      let output = try AVAudioFile(forWriting: file, settings: format.settings)
      try output.write(from: buffer)
    }
    let engine = NativeAudioEngine()
    defer { engine.stop() }
    engine.volume = 0
    engine.load(file)
    for _ in 0..<50 {
      if engine.playing { break }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    XCTAssertTrue(engine.playing)
    let spectrum = NativeAudioSpectrum()
    engine.setAnalysis(spectrum)
    try await Task.sleep(nanoseconds: 500_000_000)
    let before = try XCTUnwrap(spectrum.consume()?.first)
    engine.pitch = 12
    try await Task.sleep(nanoseconds: 700_000_000)
    let shifted = try XCTUnwrap(spectrum.consume()?.first)
    let beforeBin = try XCTUnwrap(before.indices.max { before[$0] < before[$1] })
    let afterBin = try XCTUnwrap(shifted.indices.max { shifted[$0] < shifted[$1] })
    // 一倍频差为 128 * log(2) / log(25) ≈ 27.56 个对数频段
    XCTAssertEqual(Double(afterBin - beforeBin), 27.56, accuracy: 3)
    engine.pitch = 0
    engine.eqEnabled = true
    engine.preamp = -12
    try await Task.sleep(nanoseconds: 700_000_000)
    let quieter = try XCTUnwrap(spectrum.consume()?.first)
    XCTAssertLessThan(quieter.max()!, before.max()! - 0.12)
  }

  /// 旧版无来源字段的快照仍可恢复，新增来源与队列一起持久化
  func testPlaybackContextCompatibility() throws {
    let old = Data(#"{"queue":[],"positionMs":0,"favorites":[],"history":[]}"#.utf8)
    XCTAssertNil(try JSONDecoder().decode(NativePlaybackState.self, from: old).playbackContext)
    let value = NativePlaybackState(playbackContext: "收藏歌单")
    let saved = try JSONEncoder().encode(value)
    XCTAssertEqual(
      try JSONDecoder().decode(NativePlaybackState.self, from: saved).playbackContext, "收藏歌单")
  }

  /// AB 仅接受递增的端点，取消定时会清除等待整曲结束的状态
  func testABAndSleepControls() {
    let store = NativePlayerStore(
      root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    store.pointA = 1000
    store.pointB = 2000
    store.abEnabled = true
    XCTAssertTrue(store.validAB)
    store.pointB = 500
    XCTAssertFalse(store.abEnabled)
    store.setSleepTimer(minutes: 10)
    XCTAssertNotNil(store.sleepDeadline)
    store.setSleepTimer(minutes: nil)
    XCTAssertNil(store.sleepDeadline)
    XCTAssertFalse(store.waitingForSongEnd)
    store.setSleepTimer(minutes: -1)
    XCTAssertNil(store.sleepDeadline)
    XCTAssertEqual(NativeEqualizer.presets.count, 9)
    XCTAssertTrue(
      NativeEqualizer.presets.allSatisfy {
        $0.count == 10 && $0.allSatisfy { (-15...15).contains($0) }
      })
  }

  /// 中性封面采用原版回退色，不给灰色封面虚构彩色背景
  func testCoverColorUsesOriginalNeutralFallback() throws {
    var pixels = [UInt8](repeating: 255, count: 64 * 64 * 4)
    let context = CGContext(
      data: &pixels, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let result = try NativeCoverColors.extract(context.makeImage()!)
    XCTAssertEqual(result.base, NativeCoverColors().base)
    XCTAssertEqual(result.foreground, NativeCoverColors().foreground)
  }

  /// 复制选项沿用 Next 的行顺序、翻译、罗马音与署名格式
  func testCopyLyricFilters() {
    let line = NativeLyricLine(
      id: 0, timeMs: 0, text: "你好", translation: "Hello", romanization: "ni hao")
    let background = NativeLyricLine(id: 1, timeMs: 0, text: "和声", isBackground: true)
    var options = NativeCopyLyricsOptions()
    XCTAssertEqual(
      options.text(lines: [line, background], selected: [0, 1], title: "歌名", artistName: "歌手"),
      "你好\nHello\nni hao\n——《歌名》 - 歌手")
    options.translation = false
    options.romanization = false
    options.emptyLine = true
    options.artist = false
    XCTAssertEqual(
      options.text(lines: [line], selected: [0], title: "歌名", artistName: "歌手"), "你好\n\n——《歌名》")
    XCTAssertEqual(NativeLyricSpring.presets.first?.mass, 0.9)
  }

  /// Next iOS 响度补偿在静音时不放大噪声，开启后使用受峰值限制的缓慢增益
  func testSharedNormalizationGain() throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24000)!
    buffer.frameLength = 24000
    let analysis = AudioAnalysis()
    analysis.configure(spectrum: false, normalize: true)
    for i in 0..<24000 {
      buffer.floatChannelData![0][i] = 0
      buffer.floatChannelData![1][i] = 0
    }
    analysis.process(buffer)
    XCTAssertEqual(try XCTUnwrap(analysis.consume()).gain, 1)
    for i in 0..<24000 {
      let sample = Float(sin(2 * .pi * 250 * Double(i) / 48000)) * 0.02
      buffer.floatChannelData![0][i] = sample
      buffer.floatChannelData![1][i] = sample
    }
    analysis.process(buffer)
    XCTAssertEqual(try XCTUnwrap(analysis.consume()).gain, 1.16, accuracy: 0.001)
    analysis.configure(spectrum: false, normalize: false)
    analysis.process(buffer)
    XCTAssertNil(analysis.consume())
  }

  /// 前奏和已知句尾间奏显示引导，开唱、无歌词及未知句尾不显示
  func testInterludeFollowsRealTimestamps() {
    let first = NativeLyricLine(id: 0, timeMs: 10000, text: "第一句", endMs: 12000)
    let second = NativeLyricLine(id: 1, timeMs: 20000, text: "第二句", endMs: 22000)
    XCTAssertEqual(NativeLyricInterlude.current(lines: [first, second], time: 0)?.endMs, 10000)
    XCTAssertNil(NativeLyricInterlude.current(lines: [first, second], time: 10000))
    XCTAssertEqual(NativeLyricInterlude.current(lines: [first, second], time: 12000)?.nextID, 1)
    XCTAssertNil(NativeLyricInterlude.current(lines: [first, second], time: 20000))
    XCTAssertNil(NativeLyricInterlude.current(lines: [], time: 0))
    let lrc = NativeLyricLine(id: 0, timeMs: 10000, text: "没有句尾")
    XCTAssertNil(NativeLyricInterlude.current(lines: [lrc, second], time: 15000))
  }

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
