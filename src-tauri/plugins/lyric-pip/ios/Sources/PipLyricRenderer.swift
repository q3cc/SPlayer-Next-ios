import UIKit

/// 只缓存当前三行及退场三行的排版，逐帧不重复测量整句与词宽。
final class PipLyricRenderer {
  private struct Row {
    let text: NSAttributedString
    let highlighted: NSAttributedString
    let width: CGFloat
    let height: CGFloat
    let y: CGFloat
    let wordEdges: [(CGFloat, CGFloat)]
  }
  private var rows: [Row] = []
  private var previous: [Row] = []
  private var texts: [String] = []
  private var words: [TimedWord] = []
  private var style: LyricStyle?
  private var start = -Double.infinity
  private var activatedAt = 0.0
  private var transitionAt = -Double.infinity
  var isAnimating: Bool { ProcessInfo.processInfo.systemUptime - transitionAt < 0.4 }

  func reset() {
    rows = []; previous = []; texts = []; words = []; style = nil
    start = -.infinity; transitionAt = -.infinity
  }

  func draw(context: CGContext, text: [String], line: LyricRow?, style: LyricStyle,
    time: Double, animated: Bool) {
    let now = ProcessInfo.processInfo.systemUptime
    let lineStart = line?.start ?? -1
    if texts != text || self.style != style || start != lineStart || words != (line?.words ?? []) {
      previous = rows
      let sameLine = start == lineStart && texts == text
      if !sameLine { activatedAt = max(line?.start ?? time, time) }
      transitionAt = animated && !rows.isEmpty && !sameLine ? now : -.infinity
      texts = text
      words = line?.words ?? []
      self.style = style
      start = lineStart
      let count = min(3, text.count)
      let fontSize = min(CGFloat(style.fontSize),
        (140 - CGFloat(max(0, count - 1)) * 6) / (1.35 + CGFloat(max(0, count - 1)) * 1.08))
      let heights = text.prefix(3).indices.map { index in
        fontSize * (index == 0 ? 1.35 : 1.08)
      }
      let total = heights.reduce(0, +) + CGFloat(max(0, heights.count - 1)) * 6
      var y = (160 - total) / 2
      rows = text.prefix(3).enumerated().map { index, value in
        let font = UIFont.systemFont(ofSize: fontSize * (index == 0 ? 1 : 0.8),
          weight: index == 0 ? .semibold : .regular)
        let unplayed = index == 0 && (line?.words.isEmpty ?? true)
          ? style.playedColor.uiColor : style.unplayedColor.uiColor
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: unplayed]
        let string = NSAttributedString(string: value, attributes: attributes)
        let highlighted = NSAttributedString(string: value,
          attributes: [.font: font, .foregroundColor: style.playedColor.uiColor])
        var prefix = ""
        let edges: [(CGFloat, CGFloat)] = index == 0 ? (line?.words ?? []).map { word in
          let before = (String(prefix.drop(while: { $0.isWhitespace })) as NSString).size(withAttributes: attributes).width
          prefix += word.text
          let after = (String(prefix.drop(while: { $0.isWhitespace })) as NSString).size(withAttributes: attributes).width
          return (before, after)
        } : []
        defer { y += heights[index] + 6 }
        return Row(text: string, highlighted: highlighted, width: string.size().width,
          height: heights[index], y: y, wordEdges: edges)
      }
    }
    let transition = min(1, max(0, (now - transitionAt) / 0.4))
    let eased = CGFloat(1 - pow(1 - transition, 3))
    context.saveGState()
    context.clip(to: CGRect(x: 152, y: 10, width: 464, height: 140))
    if transition < 1 {
      context.setAlpha(1 - eased)
      for row in previous {
        row.text.draw(at: CGPoint(x: 152, y: row.y - 16 * eased))
      }
    } else { previous = [] }
    context.setAlpha(eased)
    for (index, row) in rows.enumerated() {
      // 下一句只预告开头；当前句及译文按同一时间轴滚动到末尾。
      let isNext = index > 0 && line?.nextPreview == true
      let end = line?.end ?? time
      let offset = line == nil || isNext ? 0 : LyricTimeline.scroll(time: time,
        start: activatedAt, end: end, distance: Double(row.width - 464))
      let point = CGPoint(x: 152 + CGFloat(offset), y: row.y + 16 * (1 - eased))
      row.text.draw(at: point)
      if index == 0, let line = line {
        context.saveGState()
        context.beginPath()
        var hasHighlight = false
        for (wordIndex, word) in line.words.enumerated() where wordIndex < row.wordEdges.count {
          let progress = LyricTimeline.sweep(word, lineStart: line.start, time: time)
          if progress <= 0 { continue }
          let (left, right) = row.wordEdges[wordIndex]
          context.addRect(CGRect(x: point.x + left, y: point.y,
            width: (right - left) * CGFloat(progress), height: row.height))
          hasHighlight = true
        }
        if hasHighlight { context.clip(); row.highlighted.draw(at: point) }
        context.restoreGState()
      }
    }
    context.restoreGState()
  }
}
