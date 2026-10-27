import CoreGraphics
import Foundation

/// 小窗歌词颜色，按 0–255 存储，与 Tauri 插件的 LyricColor 一致
struct NativePiPColor: Equatable {
  var r: Double
  var g: Double
  var b: Double
  var a: Double = 1

  /// 解析 #RRGGBB / #RRGGBBAA
  init?(hex: String) {
    var value = hex.trimmingCharacters(in: .whitespaces)
    if value.hasPrefix("#") { value.removeFirst() }
    guard value.count == 6 || value.count == 8, let number = UInt64(value, radix: 16) else {
      return nil
    }
    let full = value.count == 6 ? number << 8 | 0xFF : number
    r = Double(full >> 24 & 0xFF)
    g = Double(full >> 16 & 0xFF)
    b = Double(full >> 8 & 0xFF)
    a = Double(full & 0xFF) / 255
  }
  init(r: Double, g: Double, b: Double, a: Double = 1) {
    self.r = r
    self.g = g
    self.b = b
    self.a = a
  }
  var hex: String {
    String(format: "#%02X%02X%02X%02X", Int(r), Int(g), Int(b), Int((a * 255).rounded()))
  }
  var cgColor: CGColor { CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a) }
}

struct NativePiPStyle: Equatable {
  var frameRate: Double
  var fontSize: Double
  var playedColor: NativePiPColor
  var unplayedColor: NativePiPColor
}

struct NativePiPWord: Equatable {
  let text: String
  let start: Double
  let end: Double
}

struct NativePiPRow: Equatable {
  let start: Double
  let end: Double
  let rows: [String]
  let primary: Int
  let nextPreview: Bool
  let words: [NativePiPWord]
}

/// 小窗设置，默认值与 iOS 版“桌面歌词”设置一致：20 FPS、单行、显示翻译、24 号字
struct NativePiPOptions: Equatable {
  static let frameRates: [Double] = [5, 10, 15, 20, 30, 60]
  var frameRate = 20.0
  var doubleLine = false
  var showTranslation = true
  var fontSize = 24.0
  var playedColor = "#FE7971FF"
  var unplayedColor = "#FFFFFFFF"

  static func current(_ defaults: UserDefaults = .standard) -> NativePiPOptions {
    var value = NativePiPOptions()
    value.frameRate = defaults.object(forKey: "native.pip.frameRate") as? Double ?? value.frameRate
    value.doubleLine = defaults.object(forKey: "native.pip.doubleLine") as? Bool ?? value.doubleLine
    value.showTranslation =
      defaults.object(forKey: "native.pip.showTranslation") as? Bool ?? value.showTranslation
    value.fontSize = defaults.object(forKey: "native.pip.fontSize") as? Double ?? value.fontSize
    value.playedColor = defaults.string(forKey: "native.pip.playedColor") ?? value.playedColor
    value.unplayedColor = defaults.string(forKey: "native.pip.unplayedColor") ?? value.unplayedColor
    return value
  }

  var style: NativePiPStyle {
    NativePiPStyle(
      frameRate: Self.frameRates.contains(frameRate) ? frameRate : 60,
      fontSize: max(16, min(40, fontSize)),
      playedColor: NativePiPColor(hex: playedColor) ?? NativePiPColor(r: 254, g: 121, b: 113),
      unplayedColor: NativePiPColor(hex: unplayedColor) ?? NativePiPColor(r: 255, g: 255, b: 255))
  }
}

/// 小窗内容；与 src/mobile/lyricPip.ts 的 pipContent 规则一致
struct NativePiPContent: Equatable {
  var title: String
  var artist: String
  var cover: String?
  var offset: Double
  var style: NativePiPStyle
  var lines: [NativePiPRow]

  static func make(
    title: String, artist: String, cover: String?, offset: Double, lyrics: [NativeLyricLine],
    options: NativePiPOptions
  ) -> NativePiPContent {
    let base = lyrics.filter { $0.isBackground != true }.map { line in
      (
        start: line.timeMs, end: line.endMs, text: line.text.trimmingCharacters(in: .whitespaces),
        translation: line.translation, roman: line.romanization ?? "",
        // 只有首字有真实时长时才逐字扫亮，与桌面歌词 hasRealWordTiming 一致
        words: line.words.count > 1 && line.words[0].endMs > line.words[0].startMs
          ? line.words.map { NativePiPWord(text: $0.text, start: $0.startMs, end: $0.endMs) } : []
      )
    }.filter { !$0.text.isEmpty }.sorted { $0.start < $1.start }
    let rows = base.enumerated().map { index, line -> NativePiPRow in
      let extras =
        options.showTranslation
        ? [line.roman, line.translation].map { $0.trimmingCharacters(in: .whitespaces) }
          .filter { !$0.isEmpty } : []
      let next = index + 1 < base.count ? base[index + 1].text : nil
      var rows = [line.text]
      if !extras.isEmpty {
        rows += extras
      } else if options.doubleLine, let next {
        rows.append(next)
      }
      return NativePiPRow(
        start: line.start, end: line.end, rows: rows, primary: 0,
        nextPreview: options.doubleLine && extras.isEmpty && next != nil, words: line.words)
    }
    return NativePiPContent(
      title: title, artist: artist, cover: cover, offset: offset, style: options.style,
      lines: rows)
  }
}

/// 对齐 shared/utils/lyricSync 和桌面端滚动规则；后台不依赖界面计时器
enum NativePiPTimeline {
  static func frameInterval(_ rate: Double?) -> Double {
    let value = rate ?? 60
    return 1 / (value.isFinite ? max(5, min(60, value)) : 60)
  }

  /// 二分查找最近开始的行；与上一行重叠时保持上一行
  static func primary(_ lines: [NativePiPRow], at time: Double) -> NativePiPRow? {
    var lo = 0
    var hi = lines.count - 1
    var latest = -1
    while lo <= hi {
      let mid = (lo + hi) / 2
      if lines[mid].start <= time {
        latest = mid
        lo = mid + 1
      } else {
        hi = mid - 1
      }
    }
    guard latest >= 0 else { return nil }
    if time < lines[latest].end && latest > 0 && time < lines[latest - 1].end {
      return lines[latest - 1]
    }
    return lines[latest]
  }

  static func sweep(_ word: NativePiPWord, lineStart: Double, time: Double) -> Double {
    let duration = abs(word.end - word.start)
    let start = max(lineStart, word.start - min(80, (duration == 0 ? 1 : duration) * 0.3))
    return max(0, min(1, (time - start) / max(1, word.end - start)))
  }

  static func scroll(time: Double, start: Double, end: Double, distance: Double) -> Double {
    let duration = max(1200, end - start)
    let motion = max(1, duration - min(2000, duration * 0.2))
    let progress = max(0, min(1, (time - start) / motion))
    return -max(0, distance) * max(0, (progress - 0.3) / 0.7)
  }
}
