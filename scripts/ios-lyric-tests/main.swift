import Foundation

let lines = [
  LyricRow(start: 1000, end: 4000, rows: ["第一句"], primary: 0, nextPreview: false, words: []),
  LyricRow(start: 3000, end: 6000, rows: ["第二句"], primary: 0, nextPreview: false, words: []),
  LyricRow(start: 8000, end: 10000, rows: ["第三句"], primary: 0, nextPreview: false, words: [])
]
precondition(LyricTimeline.primary([], at: 0) == nil)
precondition(LyricTimeline.primary(lines, at: 999) == nil)
precondition(LyricTimeline.primary(lines, at: 3000)?.start == 1000, "重叠时不能提前切走主行")
precondition(LyricTimeline.primary(lines, at: 4000)?.start == 3000)
precondition(LyricTimeline.primary(lines, at: 7000)?.start == 3000)
precondition(LyricTimeline.primary(lines, at: 9000)?.start == 8000)
precondition(LyricTimeline.primary(lines, at: 2000)?.start == 1000, "向后拖动应恢复之前的歌词")
let word = TimedWord(text: "你好", start: 1500, end: 2000)
precondition(LyricTimeline.sweep(word, lineStart: 1000, time: 1400) == 0)
precondition(LyricTimeline.sweep(word, lineStart: 1000, time: 1460) > 0, "逐字应提前最多 80ms 起亮")
precondition(LyricTimeline.sweep(word, lineStart: 1500, time: 1490) == 0, "提前量不能越过行首")
precondition(LyricTimeline.sweep(word, lineStart: 1000, time: 2100) == 1)
precondition(LyricTimeline.scroll(time: 2000, start: 1000, end: 6000, distance: 200) == 0)
precondition(abs(LyricTimeline.scroll(time: 3600, start: 1000, end: 6000, distance: 200) + 100) < 0.001)
precondition(LyricTimeline.scroll(time: 6000, start: 1000, end: 6000, distance: 200) == -200)
precondition(LyricTimeline.scroll(time: 6000, start: 1000, end: 6000, distance: -20) == 0)
precondition(LyricTimeline.frameInterval(nil) == 1.0 / 60)
precondition(LyricTimeline.frameInterval(5) == 0.2)
precondition(LyricTimeline.frameInterval(60) == 1.0 / 60)
precondition(LyricTimeline.frameInterval(120) == 1.0 / 60)
precondition(LyricTimeline.frameInterval(.nan) == 1.0 / 60)
print("PASS: 20 项原生歌词选行、逐字、滚动与帧率检查")
