import CoreGraphics
import ImageIO
import XCTest

@testable import SPlayerNativeUI

/// 歌词海报、分语言字体、下载与歌词小窗的纯逻辑测试
final class NativeParityFeatureTests: XCTestCase {
  // MARK: - 分语言字体

  func testLanguageDetectionPrefersKanaAndHangul() {
    XCTAssertEqual(NativeLyricLanguage.detect("夜に駆ける"), .japanese)
    XCTAssertEqual(NativeLyricLanguage.detect("봄날"), .korean)
    XCTAssertEqual(NativeLyricLanguage.detect("春风十里"), .chinese)
    XCTAssertEqual(NativeLyricLanguage.detect("Hello"), .latin)
    XCTAssertNil(NativeLyricLanguage.detect("♪ 123"))
  }

  func testFontFallsBackFromLanguageToLyricToSystem() {
    let specific: [NativeLyricLanguage: String] = [.japanese: "Hiragino Sans", .chinese: ""]
    XCTAssertEqual(
      NativeLyricFonts.family(for: .japanese, lyric: "Avenir", specific: specific), "Hiragino Sans")
    XCTAssertEqual(NativeLyricFonts.family(for: .chinese, lyric: "Avenir", specific: specific), "Avenir")
    XCTAssertNil(NativeLyricFonts.family(for: .korean, lyric: "", specific: specific))
  }

  func testLyricLineDecodesLanguage() throws {
    let data = Data(#"[{"id":0,"timeMs":0,"endMs":1,"text":"夜","translation":"","words":[],"language":"ja"}]"#.utf8)
    let lines = try JSONDecoder().decode([NativeLyricLine].self, from: data)
    XCTAssertEqual(lines.first?.language, "ja")
  }

  // MARK: - 歌词海报

  func testPosterHeightMatchesNextLayout() {
    // 64 + 72 + 44 + 48 + 26 + 16 + 30
    XCTAssertEqual(NativeLyricPoster.height(for: [NativeLyricPosterLine(text: "你好")]), 300)
    // 第二块：30 间距 + 48 主行 + 8 + 34 翻译 + 8 + 32 音译
    let two = NativeLyricPoster.height(for: [
      NativeLyricPosterLine(text: "你好"),
      NativeLyricPosterLine(text: "世界", translation: "World", romaji: "shi jie"),
    ])
    XCTAssertEqual(two, 300 + 30 + 48 + 8 + 34 + 8 + 32)
  }

  func testPosterRendersAtTripleScaleAndDownsamplesLongPosters() throws {
    let data = try XCTUnwrap(
      NativeLyricPoster.render(
        title: "测试", artist: "歌手", lines: [NativeLyricPosterLine(text: "你好", duet: true)],
        cover: nil))
    let image = try XCTUnwrap(
      CGImageSourceCreateImageAtIndex(
        try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil)), 0, nil))
    XCTAssertEqual(image.width, 2160)
    XCTAssertEqual(image.height, 900)
    let long = (0..<400).map { NativeLyricPosterLine(text: "第 \($0) 行歌词") }
    let large = try XCTUnwrap(
      NativeLyricPoster.render(title: "长", artist: "", lines: long, cover: nil))
    let source = try XCTUnwrap(CGImageSourceCreateWithData(large as CFData, nil))
    let properties = try XCTUnwrap(
      CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    XCTAssertLessThanOrEqual(properties[kCGImagePropertyPixelHeight] as? Int ?? .max, 16000)
  }

  func testPosterFileNameMatchesNextAndStripsSeparators() {
    XCTAssertEqual(
      NativeLyricPoster.fileName(title: "A/B", artist: "C"), "A_B - C - 歌词分享.png")
  }

  // MARK: - 下载与标签

  func testSniffDetectsContainers() {
    XCTAssertEqual(NativeAudioTagger.sniff(Data("fLaC".utf8)), "flac")
    XCTAssertEqual(NativeAudioTagger.sniff(Data("ID3\u{3}".utf8)), "mp3")
    XCTAssertEqual(NativeAudioTagger.sniff(Data([0xFF, 0xFB, 0x90, 0x00])), "mp3")
    XCTAssertEqual(NativeAudioTagger.sniff(Data([0, 0, 0, 0x20]) + Data("ftypM4A ".utf8)), "m4a")
  }

  func testID3ReplacesExistingTagAndKeepsAudio() throws {
    let audio = Data([0xFF, 0xFB, 0x90, 0x00, 1, 2, 3])
    let tags = NativeAudioTags(title: "标题", artist: "歌手", album: "专辑", cover: Data([0xFF, 0xD8]), lyrics: "[00:01.00]歌")
    let first = try NativeAudioTagger.id3(audio, tags: tags)
    XCTAssertTrue(first.starts(with: Data("ID3".utf8) + Data([3, 0, 0])))
    for frame in ["TIT2", "TPE1", "TALB", "APIC", "USLT"] {
      XCTAssertNotNil(first.range(of: Data(frame.utf8)), frame)
    }
    XCTAssertTrue(first.suffix(audio.count) == audio)
    // 重复写入不叠加旧标签
    let second = try NativeAudioTagger.id3(first, tags: tags)
    XCTAssertEqual(second, first)
  }

  func testFlacReplacesCommentsAndPictureButKeepsOtherFields() throws {
    let streamInfo = [UInt8](repeating: 7, count: 34)
    var comment = Data([4, 0, 0, 0]) + Data("test".utf8) + Data([2, 0, 0, 0])
    for item in ["GENRE=Pop", "TITLE=Old"] {
      comment.append(contentsOf: [UInt8(item.utf8.count), 0, 0, 0])
      comment.append(Data(item.utf8))
    }
    var source = Data("fLaC".utf8)
    source.append(contentsOf: [0x00, 0, 0, 34] + streamInfo)
    source.append(contentsOf: [0x84, 0, 0, UInt8(comment.count)])
    source.append(comment)
    source.append(contentsOf: [0xFF, 0xF8, 1, 2])
    let output = try NativeAudioTagger.flac(
      source, tags: NativeAudioTags(title: "新标题", artist: "歌手", cover: Data([0xFF, 0xD8])))
    let bytes = [UInt8](output)
    var offset = 4
    var types: [UInt8] = []
    var comments: [String] = []
    var last = false
    while !last {
      last = bytes[offset] & 0x80 != 0
      let type = bytes[offset] & 0x7F
      let length = Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
      if type == 4 {
        comments = NativeAudioTagger.vorbisComments(Array(bytes[(offset + 4)..<(offset + 4 + length)]))
      }
      types.append(type)
      offset += 4 + length
    }
    XCTAssertEqual(types, [0, 4, 6])
    XCTAssertEqual(Array(bytes[offset...]), [0xFF, 0xF8, 1, 2])
    XCTAssertEqual(comments, ["GENRE=Pop", "TITLE=新标题", "ARTIST=歌手"])
  }

  func testDownloadPathFollowsTemplateAndFolderScheme() {
    let track = NativeTrack(
      id: "netease:1", fileName: "", title: "晴/天", artist: "周杰伦", durationMs: 0, album: "叶惠美",
      source: "netease")
    var options = NativeDownloadOptions()
    XCTAssertEqual(options.relativePath(for: track), "周杰伦 - 晴_天")
    options.fileTemplate = "{title}"
    options.folderScheme = "artist-album"
    XCTAssertEqual(options.relativePath(for: track), "周杰伦/叶惠美/晴_天")
    XCTAssertEqual(NativeDownloadOptions.sanitize("  ..  "), "未知")
  }

  func testDownloadFormatFallbacks() {
    XCTAssertEqual(NativeDownloadStore.format(mime: "audio/x-flac"), "flac")
    XCTAssertEqual(NativeDownloadStore.format(path: "MP3"), "mp3")
    XCTAssertNil(NativeDownloadStore.format(path: "php"))
  }

  // MARK: - 歌词小窗

  private func line(
    _ id: Int, _ start: Double, _ end: Double, _ text: String, translation: String = "",
    words: [NativeLyricWord] = [], background: Bool = false
  ) -> NativeLyricLine {
    var line = NativeLyricLine(id: id, timeMs: start, text: text)
    line.endMs = end
    line.translation = translation
    line.words = words
    line.isBackground = background
    return line
  }

  func testPiPContentMatchesMobileRules() {
    let lyrics = [
      line(
        0, 0, 1000, "你好", translation: "Hello",
        words: [
          NativeLyricWord(text: "你", startMs: 0, endMs: 500),
          NativeLyricWord(text: "好", startMs: 500, endMs: 1000),
        ]),
      line(1, 500, 900, "和声", background: true),
      line(2, 1000, 2000, "世界"),
      line(3, 2000, 3000, "  "),
    ]
    var options = NativePiPOptions()
    let single = NativePiPContent.make(
      title: "", artist: "", cover: nil, offset: 0, lyrics: lyrics, options: options)
    XCTAssertEqual(single.lines.map(\.rows), [["你好", "Hello"], ["世界"]])
    XCTAssertEqual(single.lines[0].words.count, 2)
    XCTAssertTrue(single.lines[1].words.isEmpty)
    options.doubleLine = true
    options.showTranslation = false
    let double = NativePiPContent.make(
      title: "", artist: "", cover: nil, offset: 0, lyrics: lyrics, options: options)
    XCTAssertEqual(double.lines.map(\.rows), [["你好", "世界"], ["世界"]])
    XCTAssertEqual(double.lines.map(\.nextPreview), [true, false])
  }

  func testPiPTimelineKeepsOverlappingPreviousLine() {
    let rows = [
      NativePiPRow(start: 0, end: 2000, rows: ["a"], primary: 0, nextPreview: false, words: []),
      NativePiPRow(start: 1000, end: 3000, rows: ["b"], primary: 0, nextPreview: false, words: []),
    ]
    XCTAssertEqual(NativePiPTimeline.primary(rows, at: 1500)?.rows, ["a"])
    XCTAssertEqual(NativePiPTimeline.primary(rows, at: 2500)?.rows, ["b"])
    XCTAssertNil(NativePiPTimeline.primary(rows, at: -1))
    XCTAssertEqual(NativePiPTimeline.frameInterval(20), 0.05, accuracy: 1e-9)
  }

  func testPiPColorHexRoundTrip() throws {
    let color = try XCTUnwrap(NativePiPColor(hex: "#FE7971"))
    XCTAssertEqual(color, NativePiPColor(r: 254, g: 121, b: 113, a: 1))
    XCTAssertEqual(color.hex, "#FE7971FF")
    XCTAssertNil(NativePiPColor(hex: "red"))
    XCTAssertEqual(NativePiPOptions().style.frameRate, 20)
  }
}
