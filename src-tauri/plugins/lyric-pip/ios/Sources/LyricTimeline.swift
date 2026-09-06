import Foundation

struct TimedWord: Decodable, Equatable {
  let text: String
  let start: Double
  let end: Double
}

struct LyricRow: Decodable {
  let start: Double
  let end: Double
  let rows: [String]
  let primary: Int
  let nextPreview: Bool?
  let words: [TimedWord]
}

/// 对齐 shared/utils/lyricSync 和桌面端滚动规则；后台不依赖网页计时器。
enum LyricTimeline {
  static func frameInterval(_ rate: Double?) -> Double {
    let value = rate ?? 20
    return 1 / (value.isFinite ? max(5, min(60, value)) : 20)
  }

  static func primary(_ lines: [LyricRow], at time: Double) -> LyricRow? {
    var lo = 0
    var hi = lines.count - 1
    var latest = -1
    while lo <= hi {
      let mid = (lo + hi) / 2
      if lines[mid].start <= time { latest = mid; lo = mid + 1 }
      else { hi = mid - 1 }
    }
    guard latest >= 0 else { return nil }
    if time < lines[latest].end && latest > 0 && time < lines[latest - 1].end {
      return lines[latest - 1]
    }
    return lines[latest]
  }

  static func sweep(_ word: TimedWord, lineStart: Double, time: Double) -> Double {
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
